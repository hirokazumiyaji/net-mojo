use std::collections::{BTreeSet, HashMap, HashSet, VecDeque};
use std::ffi::{CStr, c_char};
use std::fs::File;
use std::io::{self, Read};
use std::net::SocketAddr;
use std::ptr;
use std::slice;
use std::time::{Duration, Instant};

use quiche::h3::NameValue;
use quiche::{Connection, ConnectionId, RecvInfo, SendInfo};

/// Whether provider quiche configs enable TLS early data (0-RTT).
///
/// Quiche only exposes [`quiche::Config::enable_early_data`] as an opt-in.
/// First-ship HTTP/3 keeps 0-RTT off: never call that API on provider configs.
const PROVIDER_ENABLE_EARLY_DATA: bool = false;

/// Keep early data / 0-RTT disabled on a quiche config.
///
/// Quiche 0.29 has no `disable_early_data` or `set_enable_early_data(false)`.
/// Early data stays off unless [`quiche::Config::enable_early_data`] is called;
/// this helper is the explicit policy call site. Do not call `enable_early_data`
/// while [`PROVIDER_ENABLE_EARLY_DATA`] is false.
fn disable_quic_early_data(_config: &mut quiche::Config) {
    assert!(
        !PROVIDER_ENABLE_EARLY_DATA,
        "provider must not enable quiche early data / 0-RTT"
    );
    // Intentionally do not call Config::enable_early_data().
}

/// Apply shared provider transport settings (including explicit 0-RTT disable).
fn apply_provider_quic_transport_settings(config: &mut quiche::Config) {
    disable_quic_early_data(config);
    config.set_initial_max_data(10_000_000);
    config.set_initial_max_stream_data_bidi_local(1_000_000);
    config.set_initial_max_stream_data_bidi_remote(1_000_000);
    config.set_initial_max_stream_data_uni(1_000_000);
    config.set_initial_max_streams_bidi(100);
    config.set_initial_max_streams_uni(3);
    config.set_max_idle_timeout(60_000);
}

pub struct NetQuicServerConfig {
    _inner: Option<quiche::Config>,
}

pub struct NetQuicServer {
    _inner: QuicServer,
}

#[unsafe(no_mangle)]
pub extern "C" fn net_quic_provider_version() -> *const c_char {
    c"0.29.3".as_ptr()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_config_new(
    certificate_path: *const c_char,
    private_key_path: *const c_char,
) -> *mut NetQuicServerConfig {
    if certificate_path.is_null() || private_key_path.is_null() {
        return ptr::null_mut();
    }

    let certificate_path = unsafe { CStr::from_ptr(certificate_path) };
    let private_key_path = unsafe { CStr::from_ptr(private_key_path) };
    let Some(certificate_path) = certificate_path.to_str().ok() else {
        return ptr::null_mut();
    };
    let Some(private_key_path) = private_key_path.to_str().ok() else {
        return ptr::null_mut();
    };

    let Ok(mut config) = quiche::Config::new(quiche::PROTOCOL_VERSION) else {
        return ptr::null_mut();
    };
    if config
        .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
        .is_err()
        || config
            .load_cert_chain_from_pem_file(certificate_path)
            .is_err()
        || config
            .load_priv_key_from_pem_file(private_key_path)
            .is_err()
    {
        return ptr::null_mut();
    }
    apply_provider_quic_transport_settings(&mut config);

    Box::into_raw(Box::new(NetQuicServerConfig {
        _inner: Some(config),
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_config_free(config: *mut NetQuicServerConfig) {
    if !config.is_null() {
        drop(unsafe { Box::from_raw(config) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_new(
    config: *mut NetQuicServerConfig,
) -> *mut NetQuicServer {
    if config.is_null() {
        return ptr::null_mut();
    }
    let Some(config) = (unsafe { (*config)._inner.take() }) else {
        return ptr::null_mut();
    };
    let Ok(server) = QuicServer::new(config) else {
        return ptr::null_mut();
    };
    Box::into_raw(Box::new(NetQuicServer { _inner: server }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_free(server: *mut NetQuicServer) {
    if !server.is_null() {
        drop(unsafe { Box::from_raw(server) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_set_connection_limit(
    server: *mut NetQuicServer,
    limit: usize,
) -> i32 {
    if server.is_null() {
        return -1;
    }
    unsafe { &mut *server }._inner.max_connections = limit;
    1
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_set_transport_memory_limit(
    server: *mut NetQuicServer,
    limit: usize,
) -> i32 {
    if server.is_null() {
        return -1;
    }
    unsafe { &mut *server }._inner.max_transport_memory_bytes = limit;
    1
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_transport_memory_bytes(
    server: *const NetQuicServer,
) -> usize {
    if server.is_null() {
        return 0;
    }
    unsafe { &*server }._inner.estimated_transport_memory_bytes()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_set_request_limits(
    server: *mut NetQuicServer,
    max_body_bytes: usize,
    max_headers_bytes: usize,
    max_headers_count: usize,
    max_trailer_bytes: usize,
    max_trailer_count: usize,
) -> i32 {
    if server.is_null() {
        return -1;
    }
    let inner = &mut unsafe { &mut *server }._inner;
    inner.max_request_body_bytes = max_body_bytes;
    inner.max_request_headers_bytes = max_headers_bytes;
    inner.max_request_headers_count = max_headers_count;
    inner.max_request_trailer_bytes = max_trailer_bytes;
    inner.max_request_trailer_count = max_trailer_count;
    let field_section = max_headers_bytes.max(max_trailer_bytes) as u64;
    inner.http3_config.set_max_field_section_size(field_section);
    1
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_set_response_limits(
    server: *mut NetQuicServer,
    max_body_bytes: usize,
    max_headers_bytes: usize,
    max_headers_count: usize,
) -> i32 {
    if server.is_null() {
        return -1;
    }
    let inner = &mut unsafe { &mut *server }._inner;
    inner.max_response_body_bytes = max_body_bytes;
    inner.max_response_headers_bytes = max_headers_bytes;
    inner.max_response_headers_count = max_headers_count;
    1
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_set_stream_deadlines(
    server: *mut NetQuicServer,
    header_deadline_ns: u64,
    body_deadline_ns: u64,
    idle_timeout_ns: u64,
    write_deadline_ns: u64,
) -> i32 {
    if server.is_null() {
        return -1;
    }
    let inner = &mut unsafe { &mut *server }._inner;
    inner.header_deadline = Duration::from_nanos(header_deadline_ns);
    inner.body_deadline = Duration::from_nanos(body_deadline_ns);
    inner.idle_timeout = Duration::from_nanos(idle_timeout_ns);
    inner.write_deadline = Duration::from_nanos(write_deadline_ns);
    let idle_ms = u64::try_from(inner.idle_timeout.as_millis()).unwrap_or(u64::MAX);
    inner.config.set_max_idle_timeout(idle_ms);
    1
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_begin_shutdown(server: *mut NetQuicServer) -> i32 {
    if server.is_null() {
        return -1;
    }
    match unsafe { &mut *server }._inner.begin_shutdown() {
        Ok(()) => 1,
        Err(_) => -1,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_finish_shutdown(server: *mut NetQuicServer) -> i32 {
    if server.is_null() {
        return -1;
    }
    match unsafe { &mut *server }._inner.finish_shutdown() {
        Ok(()) => 1,
        Err(_) => -1,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_close_connections(server: *mut NetQuicServer) -> i32 {
    if server.is_null() {
        return -1;
    }
    match unsafe { &mut *server }._inner.close_connections() {
        Ok(()) => 1,
        Err(_) => -1,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_shutdown_complete(server: *const NetQuicServer) -> i32 {
    if server.is_null() {
        return 0;
    }
    i32::from(unsafe { &*server }._inner.shutdown_complete())
}

unsafe fn socket_address(address: *const c_char) -> Option<SocketAddr> {
    let address = unsafe { CStr::from_ptr(address) }.to_str().ok()?;
    address.parse().ok()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_recv(
    server: *mut NetQuicServer,
    packet: *mut u8,
    packet_length: usize,
    local_address: *const c_char,
    remote_address: *const c_char,
) -> i32 {
    if server.is_null() || packet.is_null() || packet_length == 0 {
        return -1;
    }
    if local_address.is_null() || remote_address.is_null() {
        return -1;
    }
    let Some(local_address) = (unsafe { socket_address(local_address) }) else {
        return -1;
    };
    let Some(remote_address) = (unsafe { socket_address(remote_address) }) else {
        return -1;
    };
    let packet = unsafe { slice::from_raw_parts_mut(packet, packet_length) };
    match unsafe { &mut *server }
        ._inner
        .recv_datagram(packet, local_address, remote_address)
    {
        Ok(()) => 1,
        Err(QuicServerError::Quiche(
            quiche::Error::Done
            | quiche::Error::BufferTooShort
            | quiche::Error::UnknownVersion
            | quiche::Error::InvalidPacket,
        )) => 0,
        // Protocol errors on one connection must not stop the whole server.
        Err(QuicServerError::Quiche(_) | QuicServerError::Http3(_)) => 0,
        Err(QuicServerError::Io(_)) => -1,
    }
}

fn pacing_delay_ns(at: Instant, now: Instant) -> u64 {
    u64::try_from(at.saturating_duration_since(now).as_nanos()).unwrap_or(u64::MAX)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_send(
    server: *mut NetQuicServer,
    packet: *mut u8,
    packet_capacity: usize,
    remote_address: *mut c_char,
    address_capacity: usize,
    send_delay_ns: *mut u64,
) -> i32 {
    if server.is_null()
        || packet.is_null()
        || packet_capacity == 0
        || remote_address.is_null()
        || address_capacity < 64
        || send_delay_ns.is_null()
    {
        return -1;
    }
    unsafe { *send_delay_ns = 0 };
    let packet = unsafe { slice::from_raw_parts_mut(packet, packet_capacity) };
    let (length, info) = match (unsafe { &mut *server })._inner.send(packet) {
        Ok(Some(packet)) => packet,
        Ok(None) => return 0,
        Err(_) => return -1,
    };
    let address = info.to.to_string();
    let address_bytes = address.as_bytes();
    if address_bytes.len() + 1 > address_capacity {
        return -1;
    }
    unsafe {
        ptr::copy_nonoverlapping(
            address_bytes.as_ptr(),
            remote_address.cast::<u8>(),
            address_bytes.len(),
        );
        *remote_address.add(address_bytes.len()) = 0;
        *send_delay_ns = pacing_delay_ns(info.at, Instant::now());
    }
    i32::try_from(length).unwrap_or(-1)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_timeout_micros(server: *const NetQuicServer) -> u64 {
    if server.is_null() {
        return u64::MAX;
    }
    unsafe { &*server }
        ._inner
        .timeout()
        .map(|timeout| u64::try_from(timeout.as_micros()).unwrap_or(u64::MAX - 1))
        .unwrap_or(u64::MAX)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_on_timeout(server: *mut NetQuicServer) {
    if !server.is_null() {
        unsafe { &mut *server }._inner.on_timeout();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_next_request(
    server: *mut NetQuicServer,
    output: *mut u8,
    output_capacity: usize,
) -> i32 {
    if server.is_null() {
        return -1;
    }
    let server = unsafe { &mut *server };
    let Some(request) = server._inner.requests.front() else {
        return 0;
    };
    let mut record = Vec::new();
    append_u64(&mut record, request.id);
    append_u64(&mut record, request.stream_id);
    append_bytes(&mut record, &request.method);
    append_bytes(&mut record, &request.target);
    append_bytes(&mut record, &request.scheme);
    append_bytes(&mut record, &request.authority);
    append_u32(&mut record, request.headers.len() as u32);
    for (name, value) in &request.headers {
        append_bytes(&mut record, name);
        append_bytes(&mut record, value);
    }
    append_u32(&mut record, request.trailers.len() as u32);
    for (name, value) in &request.trailers {
        append_bytes(&mut record, name);
        append_bytes(&mut record, value);
    }
    append_bytes(&mut record, &request.body);
    if output.is_null() || output_capacity < record.len() {
        return -i32::try_from(record.len()).unwrap_or(i32::MAX);
    }
    unsafe { ptr::copy_nonoverlapping(record.as_ptr(), output, record.len()) };
    if let Some(request) = server._inner.requests.pop_front() {
        server._inner.buffered_request_bytes = server
            ._inner
            .buffered_request_bytes
            .saturating_sub(completed_request_retained_bytes(&request));
    }
    i32::try_from(record.len()).unwrap_or(-1)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_respond(
    server: *mut NetQuicServer,
    request_id: u64,
    status: u32,
    header_data: *const u8,
    header_length: usize,
    body_data: *const u8,
    body_length: usize,
) -> i32 {
    if server.is_null() || !(100..=599).contains(&status) {
        return -1;
    }
    let inner = &mut unsafe { &mut *server }._inner;
    if header_length > inner.max_response_headers_bytes
        || body_length > inner.max_response_body_bytes
        || (header_length > 0 && header_data.is_null())
        || (body_length > 0 && body_data.is_null())
    {
        return -1;
    }
    let header_bytes = if header_length == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(header_data, header_length) }
    };
    let mut offset = 0usize;
    let Some(header_count) = read_u32(header_bytes, &mut offset) else {
        return -1;
    };
    if header_count as usize > inner.max_response_headers_count {
        return -1;
    }
    let mut headers = Vec::with_capacity(header_count as usize);
    for _ in 0..header_count {
        let Some(name) = read_bytes(header_bytes, &mut offset) else {
            return -1;
        };
        let Some(value) = read_bytes(header_bytes, &mut offset) else {
            return -1;
        };
        headers.push((name, value));
    }
    if offset != header_length {
        return -1;
    }
    let body = if body_length == 0 {
        Vec::new()
    } else {
        unsafe { slice::from_raw_parts(body_data, body_length) }.to_vec()
    };
    i32::from(inner.enqueue_response(
        request_id,
        status as u16,
        headers,
        body,
    ))
}

fn read_u32(data: &[u8], offset: &mut usize) -> Option<u32> {
    let value = data.get(*offset..*offset + 4)?;
    *offset += 4;
    Some(u32::from_be_bytes(value.try_into().ok()?))
}

fn read_bytes(data: &[u8], offset: &mut usize) -> Option<Vec<u8>> {
    let length = read_u32(data, offset)? as usize;
    let value = data.get(*offset..*offset + length)?.to_vec();
    *offset += length;
    Some(value)
}

fn append_u32(output: &mut Vec<u8>, value: u32) {
    output.extend_from_slice(&value.to_be_bytes());
}

fn append_u64(output: &mut Vec<u8>, value: u64) {
    output.extend_from_slice(&value.to_be_bytes());
}

fn append_bytes(output: &mut Vec<u8>, value: &[u8]) {
    append_u32(output, value.len() as u32);
    output.extend_from_slice(value);
}

fn reserve_bytes(used: &mut usize, amount: usize, limit: usize) -> bool {
    let Some(next) = used.checked_add(amount) else {
        return false;
    };
    if next > limit {
        return false;
    }
    *used = next;
    true
}

fn field_pair_bytes(fields: &[(Vec<u8>, Vec<u8>)]) -> usize {
    fields
        .iter()
        .map(|(name, value)| name.len() + value.len())
        .sum()
}

fn pending_request_retained_bytes(request: &PendingRequest) -> usize {
    request.method.len()
        + request.target.len()
        + request.scheme.len()
        + request.authority.len()
        + field_pair_bytes(&request.headers)
        + field_pair_bytes(&request.trailers)
        + request.body.len()
}

fn completed_request_retained_bytes(request: &CompletedRequest) -> usize {
    request.method.len()
        + request.target.len()
        + request.scheme.len()
        + request.authority.len()
        + field_pair_bytes(&request.headers)
        + field_pair_bytes(&request.trailers)
        + request.body.len()
}

fn release_pending_request_bytes(used: &mut usize, request: &PendingRequest) {
    *used = used.saturating_sub(request.retained_bytes);
}

fn append_request_body(
    request: &mut PendingRequest,
    bytes: &[u8],
    buffered_bytes: &mut usize,
    limit: usize,
    max_body_bytes: usize,
) -> bool {
    if request.body.len() + bytes.len() > max_body_bytes
        || !reserve_bytes(buffered_bytes, bytes.len(), limit)
    {
        return false;
    }
    request.body.extend_from_slice(bytes);
    request.retained_bytes = request.retained_bytes.saturating_add(bytes.len());
    true
}

fn reserve_response_bytes(used: &mut usize, amount: usize) -> bool {
    reserve_bytes(used, amount, MAX_HTTP3_BUFFERED_RESPONSE_BYTES)
}

fn normalize_http3_response_header_name(name: &[u8]) -> Option<Vec<u8>> {
    if name.is_empty() || name.starts_with(b":") {
        return None;
    }
    let mut lower = Vec::with_capacity(name.len());
    for &byte in name {
        if !is_http_tchar(byte) {
            return None;
        }
        lower.push(byte.to_ascii_lowercase());
    }
    match lower.as_slice() {
        b"connection"
        | b"proxy-connection"
        | b"keep-alive"
        | b"transfer-encoding"
        | b"upgrade"
        | b"te" => None,
        _ => Some(lower),
    }
}

fn is_http_tchar(byte: u8) -> bool {
    matches!(
        byte,
        b'!'
            | b'#'
            | b'$'
            | b'%'
            | b'&'
            | b'\''
            | b'*'
            | b'+'
            | b'-'
            | b'.'
            | b'^'
            | b'_'
            | b'`'
            | b'|'
            | b'~'
            | b'0'..=b'9'
            | b'a'..=b'z'
            | b'A'..=b'Z'
    )
}

fn is_valid_http_field_name(name: &[u8]) -> bool {
    !name.is_empty()
        && !name.starts_with(b":")
        && name
            .iter()
            .copied()
            .all(|byte| is_http_tchar(byte) && !byte.is_ascii_uppercase())
}

fn is_valid_http_field_value(value: &[u8]) -> bool {
    value.iter().copied().all(|byte| {
        byte == b'\t' || (byte >= 0x20 && byte != 0x7f)
    })
}

fn content_length_matches_body(headers: &[(Vec<u8>, Vec<u8>)], body_len: usize) -> bool {
    let mut expected: Option<usize> = None;
    for (name, value) in headers {
        if !name.eq_ignore_ascii_case(b"content-length") {
            continue;
        }
        if value.is_empty() || !value.iter().all(u8::is_ascii_digit) {
            return false;
        }
        let Ok(text) = std::str::from_utf8(value) else {
            return false;
        };
        let Ok(parsed) = text.parse::<usize>() else {
            return false;
        };
        match expected {
            Some(existing) if existing != parsed => return false,
            Some(_) => {}
            None => expected = Some(parsed),
        }
    }
    expected.map_or(true, |length| length == body_len)
}

fn is_valid_http_method(method: &[u8]) -> bool {
    !method.is_empty() && method.iter().copied().all(is_http_tchar)
}

fn is_valid_http_scheme(scheme: &[u8]) -> bool {
    let Some((first, rest)) = scheme.split_first() else {
        return false;
    };
    if !first.is_ascii_alphabetic() {
        return false;
    }
    rest.iter().copied().all(|byte| {
        byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'-' | b'.')
    })
}

fn is_valid_http_path(path: &[u8]) -> bool {
    if path.is_empty() {
        return false;
    }
    if path[0] != b'/' && path != b"*" {
        return false;
    }
    path.iter().copied().all(|byte| byte > 0x20 && byte < 0x7f && byte != b'#')
}

fn is_valid_port(port: &[u8]) -> bool {
    if port.is_empty() || port.len() > 5 || !port.iter().all(u8::is_ascii_digit) {
        return false;
    }
    let Ok(text) = std::str::from_utf8(port) else {
        return false;
    };
    let Ok(value) = text.parse::<u32>() else {
        return false;
    };
    value <= 65535
}

fn is_reg_name(hostname: &[u8]) -> bool {
    if hostname.is_empty() {
        return false;
    }
    let mut i = 0;
    while i < hostname.len() {
        let byte = hostname[i];
        if byte == b'%' {
            if i + 2 >= hostname.len()
                || !hostname[i + 1].is_ascii_hexdigit()
                || !hostname[i + 2].is_ascii_hexdigit()
            {
                return false;
            }
            i += 3;
            continue;
        }
        if !(byte.is_ascii_alphanumeric()
            || matches!(
                byte,
                b'-' | b'.' | b'_' | b'~' | b'!' | b'$' | b'&' | b'\'' | b'(' | b')'
                    | b'*' | b'+' | b',' | b';' | b'='
            ))
        {
            return false;
        }
        i += 1;
    }
    true
}

fn is_bracket_inner_valid(inner: &[u8]) -> bool {
    !inner.is_empty()
        && inner.iter().copied().all(|byte| {
            byte.is_ascii_hexdigit()
                || matches!(byte, b':' | b'.' | b'%' | b'-' | b'_' | b'~')
                || byte.is_ascii_alphabetic()
        })
}

fn is_valid_http_authority(authority: &[u8]) -> bool {
    if authority.is_empty() {
        return false;
    }
    if authority.iter().any(|byte| {
        *byte <= 0x20
            || *byte == 0x7f
            || matches!(*byte, b'/' | b'?' | b'#' | b'\r' | b'\n')
    }) {
        return false;
    }
    if authority[0] == b'[' {
        let Some(close) = authority.iter().position(|byte| *byte == b']') else {
            return false;
        };
        if close == 0 || !is_bracket_inner_valid(&authority[1..close]) {
            return false;
        }
        if close + 1 == authority.len() {
            return true;
        }
        return authority.get(close + 1) == Some(&b':')
            && is_valid_port(&authority[close + 2..]);
    }
    if authority.iter().any(|byte| matches!(*byte, b'[' | b']' | b'@')) {
        return false;
    }
    let colon_positions: Vec<usize> = authority
        .iter()
        .enumerate()
        .filter_map(|(index, byte)| (*byte == b':').then_some(index))
        .collect();
    if colon_positions.len() > 1 {
        return false;
    }
    if let Some(&colon) = colon_positions.first() {
        if colon == 0 || colon + 1 >= authority.len() {
            return false;
        }
        if authority[..colon].contains(&b'%') {
            return false;
        }
        if !is_valid_port(&authority[colon + 1..]) {
            return false;
        }
        return is_reg_name(&authority[..colon]);
    }
    is_reg_name(authority)
}

fn authority_equals_ignore_ascii_case(left: &[u8], right: &[u8]) -> bool {
    left.eq_ignore_ascii_case(right)
}

#[derive(Default)]
struct SendReadyQueue {
    entries: VecDeque<Vec<u8>>,
    queued: HashSet<Vec<u8>>,
}

impl SendReadyQueue {
    fn push(&mut self, key: &[u8]) {
        if self.queued.insert(key.to_vec()) {
            self.entries.push_back(key.to_vec());
        }
    }

    fn pop(&mut self) -> Option<Vec<u8>> {
        let key = self.entries.pop_front()?;
        self.queued.remove(&key);
        Some(key)
    }

    fn remove(&mut self, key: &[u8]) {
        self.queued.remove(key);
        self.entries.retain(|entry| entry.as_slice() != key);
    }
}

pub struct QuicServer {
    config: quiche::Config,
    http3_config: quiche::h3::Config,
    connections: HashMap<Vec<u8>, QuicConnection>,
    send_ready: SendReadyQueue,
    transport_timeouts: BTreeSet<(Instant, Vec<u8>)>,
    request_timeouts: BTreeSet<(Instant, Vec<u8>, u64)>,
    response_timeouts: BTreeSet<(Instant, Vec<u8>, u64)>,
    idle_timeouts: BTreeSet<(Instant, Vec<u8>)>,
    routes: HashMap<Vec<u8>, Vec<u8>>,
    requests: VecDeque<CompletedRequest>,
    request_routes: HashMap<u64, (Vec<u8>, u64)>,
    next_request_id: u64,
    random: File,
    max_connections: usize,
    max_transport_memory_bytes: usize,
    max_request_body_bytes: usize,
    max_request_headers_bytes: usize,
    max_request_headers_count: usize,
    max_request_trailer_bytes: usize,
    max_request_trailer_count: usize,
    max_response_body_bytes: usize,
    max_response_headers_bytes: usize,
    max_response_headers_count: usize,
    header_deadline: Duration,
    body_deadline: Duration,
    idle_timeout: Duration,
    write_deadline: Duration,
    buffered_request_bytes: usize,
    buffered_response_bytes: usize,
    shutdown: ShutdownState,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum ShutdownState {
    Active,
    Draining,
    Finishing,
    Closing,
}

struct QuicConnection {
    transport: Connection,
    transport_deadline_at: Option<Instant>,
    indexed_idle_deadline_at: Option<Instant>,
    http3: Option<quiche::h3::Connection>,
    requests: HashMap<u64, PendingRequest>,
    /// Deadlines for request streams that have become readable but have not
    /// yet emitted a completed `Headers` event (incomplete QPACK sections).
    header_deadlines: HashMap<u64, Instant>,
    indexed_request_deadlines: HashMap<u64, Instant>,
    responses: HashMap<u64, PendingResponse>,
    goaway_sent: bool,
    final_goaway_sent: bool,
    last_request_stream_id: Option<u64>,
    final_goaway_last_stream_id: Option<u64>,
    idle_deadline_at: Option<Instant>,
}

const MAX_HTTP3_REQUEST_STREAM_ID: u64 = (1 << 62) - 4;
const MAX_HTTP3_BUFFERED_REQUEST_BYTES: usize = 64 * 1024 * 1024;
const MAX_HTTP3_REQUEST_BODY_BYTES: usize = 1024 * 1024;
const MAX_HTTP3_BUFFERED_RESPONSE_BYTES: usize = 64 * 1024 * 1024;
/// Soft per-connection estimate for quiche transport heap/state (handshake,
/// packet buffers, TLS session). Quiche's `stats()` does not report
/// allocator-backed memory, so admission uses `connections.len() *` this
/// constant instead of an exact RSS probe. This is an admission heuristic,
/// not a hard RSS guarantee: a connection with a large in-flight window can
/// transiently exceed it, which is why application request/response bytes
/// are capped separately at 64 MiB aggregates and operators should keep
/// headroom in `quic_max_transport_memory_bytes`. Measured per-connection
/// RSS calibration remains follow-up work per the remaining-design spec.
const ESTIMATED_QUIC_TRANSPORT_BYTES_PER_CONNECTION: usize = 256 * 1024;
/// Default soft cap (10,000 × 256 KiB = 2,621,440,000) so `max_connections`
/// remains the primary gate unless operators lower
/// `quic_max_transport_memory_bytes`.
const DEFAULT_MAX_QUIC_TRANSPORT_MEMORY_BYTES: usize =
    10_000 * ESTIMATED_QUIC_TRANSPORT_BYTES_PER_CONNECTION;
const H3_EXCESSIVE_LOAD: u64 = 0x107;
// RFC 9114 assigns 0x105 to H3_FRAME_UNEXPECTED and 0x10b to H3_REQUEST_REJECTED.
const H3_FRAME_UNEXPECTED: u64 = 0x105;
const H3_REQUEST_REJECTED: u64 = 0x10b;
const H3_GENERAL_PROTOCOL_ERROR: u64 = 0x101;

struct PendingResponse {
    request_id: u64,
    headers: Vec<quiche::h3::Header>,
    body: Vec<u8>,
    headers_sent: bool,
    body_offset: usize,
    buffered_bytes: usize,
    write_deadline_at: Instant,
}

#[derive(Default)]
struct PendingRequest {
    method: Vec<u8>,
    target: Vec<u8>,
    scheme: Vec<u8>,
    authority: Vec<u8>,
    headers: Vec<(Vec<u8>, Vec<u8>)>,
    trailers: Vec<(Vec<u8>, Vec<u8>)>,
    header_bytes: usize,
    header_count: usize,
    trailer_bytes: usize,
    trailer_count: usize,
    body: Vec<u8>,
    /// Bytes currently charged to `buffered_request_bytes`.
    retained_bytes: usize,
    headers_deadline_at: Option<Instant>,
    body_deadline_at: Option<Instant>,
    idle_deadline_at: Option<Instant>,
}

pub struct CompletedRequest {
    pub id: u64,
    pub stream_id: u64,
    pub method: Vec<u8>,
    pub target: Vec<u8>,
    pub scheme: Vec<u8>,
    pub authority: Vec<u8>,
    pub headers: Vec<(Vec<u8>, Vec<u8>)>,
    pub trailers: Vec<(Vec<u8>, Vec<u8>)>,
    pub body: Vec<u8>,
}

#[derive(Debug)]
pub enum QuicServerError {
    Io(io::Error),
    Quiche(quiche::Error),
    Http3(quiche::h3::Error),
}

impl From<io::Error> for QuicServerError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<quiche::Error> for QuicServerError {
    fn from(error: quiche::Error) -> Self {
        Self::Quiche(error)
    }
}

impl From<quiche::h3::Error> for QuicServerError {
    fn from(error: quiche::h3::Error) -> Self {
        Self::Http3(error)
    }
}

impl QuicServer {
    pub fn new(config: quiche::Config) -> io::Result<Self> {
        let mut http3_config = quiche::h3::Config::new().unwrap();
        http3_config.set_max_field_section_size(32_768);
        http3_config.set_qpack_max_table_capacity(0);
        http3_config.set_qpack_blocked_streams(0);
        Ok(Self {
            config,
            http3_config,
            connections: HashMap::new(),
            send_ready: SendReadyQueue::default(),
            transport_timeouts: BTreeSet::new(),
            request_timeouts: BTreeSet::new(),
            response_timeouts: BTreeSet::new(),
            idle_timeouts: BTreeSet::new(),
            routes: HashMap::new(),
            requests: VecDeque::new(),
            request_routes: HashMap::new(),
            next_request_id: 1,
            random: File::open("/dev/urandom")?,
            max_connections: 10_000,
            max_transport_memory_bytes: DEFAULT_MAX_QUIC_TRANSPORT_MEMORY_BYTES,
            max_request_body_bytes: MAX_HTTP3_REQUEST_BODY_BYTES,
            max_request_headers_bytes: 32_768,
            max_request_headers_count: 100,
            max_request_trailer_bytes: 8_192,
            max_request_trailer_count: 32,
            max_response_body_bytes: MAX_HTTP3_REQUEST_BODY_BYTES,
            max_response_headers_bytes: 32_768,
            max_response_headers_count: 100,
            header_deadline: Duration::from_secs(5),
            body_deadline: Duration::from_secs(30),
            idle_timeout: Duration::from_secs(60),
            write_deadline: Duration::from_secs(30),
            buffered_request_bytes: 0,
            buffered_response_bytes: 0,
            shutdown: ShutdownState::Active,
        })
    }

    pub fn begin_shutdown(&mut self) -> Result<(), QuicServerError> {
        if self.shutdown < ShutdownState::Draining {
            self.shutdown = ShutdownState::Draining;
        }
        self.drive_goaways()
    }

    pub fn finish_shutdown(&mut self) -> Result<(), QuicServerError> {
        if self.shutdown < ShutdownState::Finishing {
            self.shutdown = ShutdownState::Finishing;
        }
        self.drive_goaways()?;
        self.drive_final_goaways()
    }

    fn drive_final_goaways(&mut self) -> Result<(), QuicServerError> {
        for (connection_key, connection) in self.connections.iter_mut() {
            if connection.final_goaway_sent {
                continue;
            }
            let Some(http3) = connection.http3.as_mut() else {
                continue;
            };
            // RFC 9114 §5.2: streams with the GOAWAY ID or greater are rejected.
            // Advertise the first rejected client request stream (N+4), or 0
            // when no request streams were accepted.
            let goaway_id = match connection.last_request_stream_id {
                Some(last) => last.saturating_add(4),
                None => 0,
            };
            match http3.send_goaway(&mut connection.transport, goaway_id) {
                Ok(()) => {
                    self.send_ready.push(connection_key);
                    connection.final_goaway_sent = true;
                    connection.final_goaway_last_stream_id = Some(goaway_id);
                }
                Err(quiche::h3::Error::StreamBlocked | quiche::h3::Error::Done) => (),
                Err(error) => return Err(error.into()),
            }
        }
        Ok(())
    }

    pub fn close_connections(&mut self) -> Result<(), QuicServerError> {
        if self.shutdown < ShutdownState::Finishing {
            return Err(quiche::Error::Done.into());
        }
        self.drive_goaways()?;
        self.drive_final_goaways()?;
        self.shutdown = ShutdownState::Closing;
        let mut first_error = None;
        let mut timeouts = Vec::new();
        for (connection_key, connection) in self.connections.iter_mut() {
            if connection.transport.is_closed() || connection.transport.is_draining() {
                continue;
            }
            self.send_ready.push(connection_key);
            if let Err(error) = connection.transport.close(true, 0x100, b"") {
                first_error.get_or_insert(error);
            }
            timeouts.push((
                connection_key.clone(),
                connection.transport.timeout_instant(),
            ));
        }
        for (key, deadline) in timeouts {
            self.set_transport_timeout(&key, deadline);
        }
        first_error.map_or(Ok(()), |error| Err(error.into()))
    }

    pub fn shutdown_complete(&self) -> bool {
        self.connections.is_empty()
    }

    pub fn estimated_transport_memory_bytes(&self) -> usize {
        self.connections
            .len()
            .saturating_mul(ESTIMATED_QUIC_TRANSPORT_BYTES_PER_CONNECTION)
    }

    fn would_exceed_transport_memory_budget(&self) -> bool {
        self.estimated_transport_memory_bytes()
            .saturating_add(ESTIMATED_QUIC_TRANSPORT_BYTES_PER_CONNECTION)
            > self.max_transport_memory_bytes
    }

    pub fn recv_datagram(
        &mut self,
        packet: &mut [u8],
        local: SocketAddr,
        remote: SocketAddr,
    ) -> Result<(), QuicServerError> {
        let header = quiche::Header::from_slice(packet, 16)?;
        let destination_id = header.dcid.as_ref().to_vec();
        let key = match self.routes.get(&destination_id) {
            Some(key) => key.clone(),
            None if header.ty == quiche::Type::Initial => {
                if self.shutdown >= ShutdownState::Draining {
                    return Err(quiche::Error::Done.into());
                }
                if self.connections.len() >= self.max_connections {
                    return Err(quiche::Error::Done.into());
                }
                if self.would_exceed_transport_memory_budget() {
                    return Err(quiche::Error::Done.into());
                }
                let mut source_id = [0; 16];
                self.random.read_exact(&mut source_id)?;
                let source_id = ConnectionId::from_ref(&source_id);
                let connection = quiche::accept(&source_id, None, local, remote, &mut self.config)?;
                let key = source_id.as_ref().to_vec();
                self.routes.insert(destination_id, key.clone());
                self.routes.insert(key.clone(), key.clone());
                self.connections.insert(
                    key.clone(),
                    QuicConnection {
                        transport: connection,
                        transport_deadline_at: None,
                        indexed_idle_deadline_at: None,
                        http3: None,
                        requests: HashMap::new(),
                        header_deadlines: HashMap::new(),
                        indexed_request_deadlines: HashMap::new(),
                        responses: HashMap::new(),
                        goaway_sent: false,
                        final_goaway_sent: false,
                        last_request_stream_id: None,
                        final_goaway_last_stream_id: None,
                        idle_deadline_at: Some(Instant::now() + self.idle_timeout),
                    },
                );
                key
            }
            None => return Err(quiche::Error::Done.into()),
        };

        self.send_ready.push(&key);
        let received = self.connections.get_mut(&key).unwrap().transport.recv(
            packet,
            RecvInfo {
                from: remote,
                to: local,
            },
        );
        self.refresh_transport_timeout(&key);
        self.refresh_idle_timeout(&key);
        received?;
        let http3_error = {
            let connection = self.connections.get_mut(&key).unwrap();
            connection.idle_deadline_at = Some(Instant::now() + self.idle_timeout);
            if connection.transport.is_established() && connection.http3.is_none() {
                match quiche::h3::Connection::with_transport(
                    &mut connection.transport,
                    &self.http3_config,
                ) {
                    Ok(http3) => {
                        connection.http3 = Some(http3);
                        None
                    }
                    Err(quiche::h3::Error::InternalError | quiche::h3::Error::Done) => None,
                    Err(error) => Some(error),
                }
            } else {
                None
            }
        };
        self.refresh_idle_timeout(&key);
        if let Some(error) = http3_error {
            return Err(error.into());
        }

        let mut cancelled_requests = Vec::new();
        let mut touched = HashSet::new();
        let completed = {
            let connection = self.connections.get_mut(&key).unwrap();
            match Self::poll_http3(
                connection,
                &mut self.buffered_request_bytes,
                &mut self.buffered_response_bytes,
                &mut cancelled_requests,
                &mut touched,
                self.max_request_body_bytes,
                self.max_request_headers_bytes,
                self.max_request_headers_count,
                self.max_request_trailer_bytes,
                self.max_request_trailer_count,
                self.header_deadline,
                self.body_deadline,
                self.idle_timeout,
            ) {
                Ok(completed) => Some(completed),
                Err(_) => {
                    let _ = connection.transport.close(
                        true,
                        H3_GENERAL_PROTOCOL_ERROR,
                        b"http/3 protocol error",
                    );
                    None
                }
            }
        };
        self.refresh_transport_timeout(&key);
        for stream_id in touched {
            self.refresh_request_timeout(&key, stream_id);
        }
        for (request_id, stream_id, deadline) in cancelled_requests {
            self.response_timeouts
                .remove(&(deadline, key.clone(), stream_id));
            self.request_routes.remove(&request_id);
        }
        self.refresh_idle_timeout(&key);
        let Some(completed) = completed else {
            // CONNECTION_CLOSE is queued; keep the connection until send/drain
            // emits it and quiche reports the transport closed.
            return Ok(());
        };
        let source_ids: Vec<Vec<u8>> = self
            .connections
            .get(&key)
            .map(|connection| {
                connection
                    .transport
                    .source_ids()
                    .map(|source_id| source_id.as_ref().to_vec())
                    .collect()
            })
            .unwrap_or_default();
        for source_id in source_ids {
            self.routes.insert(source_id, key.clone());
        }
        for request in completed {
            let id = self.next_request_id;
            self.next_request_id = self.next_request_id.wrapping_add(1).max(1);
            self.request_routes
                .insert(id, (key.clone(), request.stream_id));
            self.requests.push_back(CompletedRequest {
                id,
                stream_id: request.stream_id,
                method: request.method,
                target: request.target,
                scheme: request.scheme,
                authority: request.authority,
                headers: request.headers,
                trailers: request.trailers,
                body: request.body,
            });
        }
        self.reap_closed_connection(&key);
        Ok(())
    }

    fn drive_goaways(&mut self) -> Result<(), QuicServerError> {
        if self.shutdown < ShutdownState::Draining {
            return Ok(());
        }
        for (connection_key, connection) in self.connections.iter_mut() {
            if connection.goaway_sent {
                continue;
            }
            let Some(http3) = connection.http3.as_mut() else {
                continue;
            };
            match http3.send_goaway(&mut connection.transport, MAX_HTTP3_REQUEST_STREAM_ID) {
                Ok(()) => {
                    connection.goaway_sent = true;
                    self.send_ready.push(connection_key);
                }
                Err(quiche::h3::Error::StreamBlocked | quiche::h3::Error::Done) => (),
                Err(error) => return Err(error.into()),
            }
        }
        Ok(())
    }

    fn reap_closed_connection(&mut self, connection_key: &[u8]) {
        if !self
            .connections
            .get(connection_key)
            .is_some_and(|connection| connection.transport.is_closed())
        {
            return;
        }
        self.force_drop_connection(connection_key);
    }

    fn force_drop_connection(&mut self, connection_key: &[u8]) {
        let Some(connection) = self.connections.remove(connection_key) else {
            return;
        };
        self.send_ready.remove(connection_key);
        if let Some(deadline) = connection.transport_deadline_at {
            self.transport_timeouts
                .remove(&(deadline, connection_key.to_vec()));
        }
        for (stream_id, deadline) in &connection.indexed_request_deadlines {
            self.request_timeouts
                .remove(&(*deadline, connection_key.to_vec(), *stream_id));
        }
        if let Some(deadline) = connection.indexed_idle_deadline_at {
            self.idle_timeouts
                .remove(&(deadline, connection_key.to_vec()));
        }
        for (stream_id, response) in &connection.responses {
            self.response_timeouts.remove(&(
                response.write_deadline_at,
                connection_key.to_vec(),
                *stream_id,
            ));
        }
        let in_flight_bytes: usize = connection
            .requests
            .values()
            .map(|request| request.retained_bytes)
            .sum();
        self.buffered_request_bytes -= in_flight_bytes;
        let response_bytes: usize = connection
            .responses
            .values()
            .map(|response| response.buffered_bytes)
            .sum();
        self.buffered_response_bytes -= response_bytes;
        self.routes
            .retain(|_, owner_key| owner_key.as_slice() != connection_key);
        let request_ids: Vec<u64> = self
            .request_routes
            .iter()
            .filter_map(|(request_id, (owner_key, _))| {
                (owner_key.as_slice() == connection_key).then_some(*request_id)
            })
            .collect();
        self.request_routes
            .retain(|_, (owner_key, _)| owner_key.as_slice() != connection_key);
        let queued_bytes: usize = self
            .requests
            .iter()
            .filter(|request| request_ids.contains(&request.id))
            .map(completed_request_retained_bytes)
            .sum();
        self.buffered_request_bytes -= queued_bytes;
        self.requests
            .retain(|request| !request_ids.contains(&request.id));
    }

    fn poll_http3(
        connection: &mut QuicConnection,
        buffered_request_bytes: &mut usize,
        buffered_response_bytes: &mut usize,
        cancelled_requests: &mut Vec<(u64, u64, Instant)>,
        touched: &mut HashSet<u64>,
        max_request_body_bytes: usize,
        max_request_headers_bytes: usize,
        max_request_headers_count: usize,
        max_request_trailer_bytes: usize,
        max_request_trailer_count: usize,
        header_deadline: Duration,
        body_deadline: Duration,
        idle_timeout: Duration,
    ) -> Result<Vec<CompletedRequest>, QuicServerError> {
        let mut completed = Vec::new();
        if connection.http3.is_none() {
            return Ok(completed);
        }
        Self::arm_header_deadlines(connection, header_deadline, touched);
        let http3 = connection.http3.as_mut().unwrap();
        loop {
            match http3.poll(&mut connection.transport) {
                Ok((stream_id, quiche::h3::Event::Headers { list, .. })) => {
                    touched.insert(stream_id);
                    connection.header_deadlines.remove(&stream_id);
                    if connection
                        .final_goaway_last_stream_id
                        .is_some_and(|last| stream_id >= last)
                    {
                        http3.cancel_request(
                            &mut connection.transport,
                            stream_id,
                            H3_REQUEST_REJECTED,
                        )?;
                        continue;
                    }
                    if let Some(request) = connection.requests.get_mut(&stream_id) {
                        let mut invalid = false;
                        for header in list {
                            request.trailer_count += 1;
                            request.trailer_bytes += header.name().len() + header.value().len();
                            let name = header.name();
                            let value = header.value();
                            if request.trailer_count > max_request_trailer_count
                                || request.trailer_bytes > max_request_trailer_bytes
                                || name.starts_with(b":")
                                || !is_valid_http_field_name(name)
                                || !is_valid_http_field_value(value)
                                || matches!(
                                    name,
                                    b"connection"
                                        | b"content-length"
                                        | b"host"
                                        | b"keep-alive"
                                        | b"proxy-connection"
                                        | b"te"
                                        | b"transfer-encoding"
                                        | b"upgrade"
                                )
                            {
                                invalid = true;
                            }
                            request
                                .trailers
                                .push((name.to_vec(), value.to_vec()));
                        }
                        if invalid {
                            let code = if request.trailer_bytes > max_request_trailer_bytes {
                                0x107
                            } else {
                                0x10e
                            };
                            http3.cancel_request(
                                &mut connection.transport,
                                stream_id,
                                code,
                            )?;
                            if let Some(rejected) = connection.requests.remove(&stream_id) {
                                release_pending_request_bytes(buffered_request_bytes, &rejected);
                            }
                        } else {
                            let new_retained = pending_request_retained_bytes(request);
                            if new_retained > request.retained_bytes {
                                let delta = new_retained - request.retained_bytes;
                                if !reserve_bytes(
                                    buffered_request_bytes,
                                    delta,
                                    MAX_HTTP3_BUFFERED_REQUEST_BYTES,
                                ) {
                                    http3.cancel_request(
                                        &mut connection.transport,
                                        stream_id,
                                        H3_EXCESSIVE_LOAD,
                                    )?;
                                    if let Some(rejected) =
                                        connection.requests.remove(&stream_id)
                                    {
                                        release_pending_request_bytes(
                                            buffered_request_bytes,
                                            &rejected,
                                        );
                                    }
                                    continue;
                                }
                                request.retained_bytes = new_retained;
                            }
                            let now = Instant::now();
                            request.idle_deadline_at = Some(now + idle_timeout);
                        }
                        continue;
                    }
                    let mut request = PendingRequest::default();
                    let mut seen_pseudo_headers = 0u8;
                    let mut regular_header_seen = false;
                    let mut header_bytes = 0usize;
                    let mut header_count = 0usize;
                    let mut invalid = false;
                    let mut host: Option<Vec<u8>> = None;
                    for header in list {
                        header_count += 1;
                        header_bytes += header.name().len() + header.value().len();
                        if header_count > max_request_headers_count
                            || header_bytes > max_request_headers_bytes
                        {
                            invalid = true;
                        }
                        match header.name() {
                            b":method" => {
                                if regular_header_seen || seen_pseudo_headers & 1 != 0 {
                                    invalid = true;
                                }
                                seen_pseudo_headers |= 1;
                                if !is_valid_http_method(header.value()) {
                                    invalid = true;
                                }
                                request.method = header.value().to_vec();
                            }
                            b":path" => {
                                if regular_header_seen || seen_pseudo_headers & 2 != 0 {
                                    invalid = true;
                                }
                                seen_pseudo_headers |= 2;
                                if !is_valid_http_path(header.value()) {
                                    invalid = true;
                                }
                                request.target = header.value().to_vec();
                            }
                            b":scheme" => {
                                if regular_header_seen || seen_pseudo_headers & 4 != 0 {
                                    invalid = true;
                                }
                                seen_pseudo_headers |= 4;
                                if !is_valid_http_scheme(header.value()) {
                                    invalid = true;
                                }
                                request.scheme = header.value().to_vec();
                            }
                            b":authority" => {
                                if regular_header_seen || seen_pseudo_headers & 8 != 0 {
                                    invalid = true;
                                }
                                seen_pseudo_headers |= 8;
                                if !is_valid_http_authority(header.value()) {
                                    invalid = true;
                                }
                                request.authority = header.value().to_vec()
                            }
                            b":protocol" => invalid = true,
                            name if name.starts_with(b":") => invalid = true,
                            name => {
                                regular_header_seen = true;
                                if !is_valid_http_field_name(name)
                                    || !is_valid_http_field_value(header.value())
                                    || matches!(
                                        name,
                                        b"connection"
                                            | b"keep-alive"
                                            | b"proxy-connection"
                                            | b"transfer-encoding"
                                            | b"upgrade"
                                    )
                                    || (name == b"te" && header.value() != b"trailers")
                                {
                                    invalid = true;
                                }
                                if name == b"host" {
                                    if host.is_some() || !is_valid_http_authority(header.value())
                                    {
                                        invalid = true;
                                    } else {
                                        host = Some(header.value().to_vec());
                                    }
                                }
                                request
                                    .headers
                                    .push((name.to_vec(), header.value().to_vec()));
                            }
                        }
                    }
                    request.header_bytes = header_bytes;
                    request.header_count = header_count;
                    if let Some(host_value) = host.as_ref() {
                        if !authority_equals_ignore_ascii_case(
                            &request.authority,
                            host_value,
                        ) {
                            invalid = true;
                        }
                    }
                    if invalid
                        || seen_pseudo_headers != 15
                        || request.method == b"CONNECT"
                        || request.method.is_empty()
                        || request.target.is_empty()
                        || request.scheme.is_empty()
                        || request.authority.is_empty()
                    {
                        let code = if header_bytes > max_request_headers_bytes {
                            0x107
                        } else {
                            0x10e
                        };
                        http3.cancel_request(
                            &mut connection.transport,
                            stream_id,
                            code,
                        )?;
                        continue;
                    }
                    let now = Instant::now();
                    // Headers are already complete when quiche emits this event,
                    // so arm the body deadline immediately for incomplete requests.
                    request.body_deadline_at = Some(now + body_deadline);
                    request.idle_deadline_at = Some(now + idle_timeout);
                    let retained = pending_request_retained_bytes(&request);
                    if !reserve_bytes(
                        buffered_request_bytes,
                        retained,
                        MAX_HTTP3_BUFFERED_REQUEST_BYTES,
                    ) {
                        http3.cancel_request(
                            &mut connection.transport,
                            stream_id,
                            H3_EXCESSIVE_LOAD,
                        )?;
                        continue;
                    }
                    request.retained_bytes = retained;
                    connection.last_request_stream_id = Some(
                        connection
                            .last_request_stream_id
                            .map_or(stream_id, |last| last.max(stream_id)),
                    );
                    connection.requests.insert(stream_id, request);
                }
                Ok((stream_id, quiche::h3::Event::Data)) => {
                    touched.insert(stream_id);
                    if connection
                        .final_goaway_last_stream_id
                        .is_some_and(|last| stream_id >= last)
                    {
                        continue;
                    }
                    let Some(request) = connection.requests.get_mut(&stream_id) else {
                        http3.cancel_request(
                            &mut connection.transport,
                            stream_id,
                            H3_FRAME_UNEXPECTED,
                        )?;
                        continue;
                    };
                    let now = Instant::now();
                    request.idle_deadline_at = Some(now + idle_timeout);
                    let mut body = [0; 16 * 1024];
                    loop {
                        match http3.recv_body(&mut connection.transport, stream_id, &mut body) {
                            Ok(length) => {
                                if !append_request_body(
                                    request,
                                    &body[..length],
                                    buffered_request_bytes,
                                    MAX_HTTP3_BUFFERED_REQUEST_BYTES,
                                    max_request_body_bytes,
                                ) {
                                    http3.cancel_request(
                                        &mut connection.transport,
                                        stream_id,
                                        H3_EXCESSIVE_LOAD,
                                    )?;
                                    if let Some(rejected) = connection.requests.remove(&stream_id) {
                                        release_pending_request_bytes(
                                            buffered_request_bytes,
                                            &rejected,
                                        );
                                    }
                                    break;
                                }
                            }
                            Err(quiche::h3::Error::Done) => break,
                            Err(quiche::h3::Error::TransportError(quiche::Error::StreamReset(error))) => {
                                http3.cancel_request(
                                    &mut connection.transport,
                                    stream_id,
                                    error,
                                )?;
                                if let Some(reset) = connection.requests.remove(&stream_id) {
                                    release_pending_request_bytes(buffered_request_bytes, &reset);
                                }
                                connection.header_deadlines.remove(&stream_id);
                                break;
                            }
                            Err(error) => return Err(error.into()),
                        }
                    }
                }
                Ok((stream_id, quiche::h3::Event::Finished)) => {
                    touched.insert(stream_id);
                    connection.header_deadlines.remove(&stream_id);
                    if let Some(request) = connection.requests.remove(&stream_id) {
                        if !content_length_matches_body(&request.headers, request.body.len()) {
                            release_pending_request_bytes(buffered_request_bytes, &request);
                            http3.cancel_request(
                                &mut connection.transport,
                                stream_id,
                                H3_GENERAL_PROTOCOL_ERROR,
                            )?;
                            continue;
                        }
                        completed.push(CompletedRequest {
                            id: 0,
                            stream_id,
                            method: request.method,
                            target: request.target,
                            scheme: request.scheme,
                            authority: request.authority,
                            headers: request.headers,
                            trailers: request.trailers,
                            body: request.body,
                        });
                    }
                }
                Ok((stream_id, quiche::h3::Event::Reset(error))) => {
                    touched.insert(stream_id);
                    connection.header_deadlines.remove(&stream_id);
                    http3.cancel_request(
                        &mut connection.transport,
                        stream_id,
                        error,
                    )?;
                    if let Some(reset) = connection.requests.remove(&stream_id) {
                        release_pending_request_bytes(buffered_request_bytes, &reset);
                    }
                    if let Some(reset) = connection.responses.remove(&stream_id) {
                        *buffered_response_bytes -= reset.buffered_bytes;
                        cancelled_requests.push((
                            reset.request_id,
                            stream_id,
                            reset.write_deadline_at,
                        ));
                    }
                }
                Ok(_) => (),
                Err(quiche::h3::Error::Done) => break,
                Err(error) => return Err(error.into()),
            }
        }
        Ok(completed)
    }

    pub fn next_request(&mut self) -> Option<CompletedRequest> {
        let request = self.requests.pop_front()?;
        self.buffered_request_bytes = self
            .buffered_request_bytes
            .saturating_sub(completed_request_retained_bytes(&request));
        Some(request)
    }

    fn enqueue_response(
        &mut self,
        request_id: u64,
        status: u16,
        headers: Vec<(Vec<u8>, Vec<u8>)>,
        body: Vec<u8>,
    ) -> bool {
        let Some((connection_key, stream_id)) = self.request_routes.get(&request_id).cloned()
        else {
            return false;
        };
        if !self.connections.contains_key(&connection_key) {
            return false;
        }
        if self.connections[&connection_key]
            .responses
            .contains_key(&stream_id)
        {
            return false;
        }
        self.send_ready.push(&connection_key);
        let status_value = status.to_string();
        let buffered_bytes = body.len()
            + b":status".len()
            + status_value.len()
            + headers
                .iter()
                .map(|(name, value)| name.len() + value.len())
                .sum::<usize>();
        if !reserve_response_bytes(&mut self.buffered_response_bytes, buffered_bytes) {
            let connection = self.connections.get_mut(&connection_key).unwrap();
            cancel_http3_request(connection, stream_id, H3_EXCESSIVE_LOAD);
            self.request_routes.remove(&request_id);
            return true;
        }
        let mut response_headers = Vec::with_capacity(headers.len() + 1);
        response_headers.push(quiche::h3::Header::new(b":status", status_value.as_bytes()));
        for (name, value) in headers {
            let Some(normalized) = normalize_http3_response_header_name(&name) else {
                self.buffered_response_bytes -= buffered_bytes;
                let connection = self.connections.get_mut(&connection_key).unwrap();
                cancel_http3_request(connection, stream_id, H3_GENERAL_PROTOCOL_ERROR);
                self.request_routes.remove(&request_id);
                return true;
            };
            response_headers.push(quiche::h3::Header::new(&normalized, &value));
        }
        let connection = self.connections.get_mut(&connection_key).unwrap();
        connection.responses.insert(
            stream_id,
            PendingResponse {
                request_id,
                headers: response_headers,
                body,
                headers_sent: false,
                body_offset: 0,
                buffered_bytes,
                write_deadline_at: Instant::now() + self.write_deadline,
            },
        );
        self.index_response_timeout(&connection_key, stream_id);
        self.refresh_idle_timeout(&connection_key);
        true
    }

    fn drive_responses(&mut self) -> Result<(), QuicServerError> {
        self.expire_responses();
        let mut completed = Vec::new();
        for (connection_key, connection) in self.connections.iter_mut() {
            let stream_ids: Vec<u64> = connection.responses.keys().copied().collect();
            for stream_id in stream_ids {
                let response = connection.responses.get_mut(&stream_id).unwrap();
                let Some(http3) = connection.http3.as_mut() else {
                    continue;
                };
                if !response.headers_sent {
                    match http3.send_response(
                        &mut connection.transport,
                        stream_id,
                        &response.headers,
                        response.body.is_empty(),
                    ) {
                        Ok(()) => {
                            response.headers_sent = true;
                            self.send_ready.push(connection_key);
                        }
                        Err(quiche::h3::Error::TransportError(quiche::Error::StreamStopped(_))) => {
                            self.send_ready.push(connection_key);
                            completed.push((
                                connection_key.clone(),
                                stream_id,
                                response.request_id,
                            ));
                            continue;
                        }
                        Err(quiche::h3::Error::Done | quiche::h3::Error::StreamBlocked) => continue,
                        Err(error) => return Err(error.into()),
                    }
                }
                if response.body.is_empty() {
                    completed.push((connection_key.clone(), stream_id, response.request_id));
                    continue;
                }
                match http3.send_body(
                    &mut connection.transport,
                    stream_id,
                    &response.body[response.body_offset..],
                    true,
                ) {
                    Ok(written) => {
                        if written > 0 {
                            self.send_ready.push(connection_key);
                        }
                        response.body_offset += written;
                        if response.body_offset == response.body.len() {
                            completed.push((
                                connection_key.clone(),
                                stream_id,
                                response.request_id,
                            ));
                        }
                    }
                    Err(quiche::h3::Error::TransportError(quiche::Error::StreamStopped(_))) => {
                        self.send_ready.push(connection_key);
                        completed.push((connection_key.clone(), stream_id, response.request_id));
                    }
                    Err(quiche::h3::Error::Done | quiche::h3::Error::StreamBlocked) => (),
                    Err(error) => return Err(error.into()),
                }
            }
        }
        for (connection_key, stream_id, request_id) in completed {
            self.remove_response_timeout(&connection_key, stream_id);
            let response = self
                .connections
                .get_mut(&connection_key)
                .unwrap()
                .responses
                .remove(&stream_id)
                .unwrap();
            self.buffered_response_bytes -= response.buffered_bytes;
            self.request_routes.remove(&request_id);
            self.refresh_idle_timeout(&connection_key);
        }
        Ok(())
    }

    pub fn send(
        &mut self,
        packet: &mut [u8],
    ) -> Result<Option<(usize, SendInfo)>, QuicServerError> {
        if self.shutdown < ShutdownState::Closing {
            self.drive_goaways()?;
            if self.shutdown >= ShutdownState::Finishing {
                self.drive_final_goaways()?;
            }
            self.drive_responses()?;
        }
        while let Some(key) = self.send_ready.pop() {
            let result = self
                .connections
                .get_mut(&key)
                .unwrap()
                .transport
                .send(packet);
            self.refresh_transport_timeout(&key);
            match result {
                Ok((length, info)) => {
                    self.send_ready.push(&key);
                    return Ok(Some((length, info)));
                }
                Err(quiche::Error::Done) => self.reap_closed_connection(&key),
                Err(error) => {
                    self.send_ready.push(&key);
                    return Err(error.into());
                }
            }
        }
        Ok(None)
    }

    fn refresh_idle_timeout(&mut self, key: &[u8]) {
        let connection = self.connections.get_mut(key).unwrap();
        let deadline = if connection.requests.is_empty()
            && connection.header_deadlines.is_empty()
            && connection.responses.is_empty()
        {
            connection.idle_deadline_at
        } else {
            None
        };
        if connection.indexed_idle_deadline_at == deadline {
            return;
        }
        if let Some(previous) = connection.indexed_idle_deadline_at.take() {
            self.idle_timeouts.remove(&(previous, key.to_vec()));
        }
        connection.indexed_idle_deadline_at = deadline;
        if let Some(deadline) = deadline {
            self.idle_timeouts.insert((deadline, key.to_vec()));
        }
    }

    fn index_response_timeout(&mut self, key: &[u8], stream_id: u64) {
        let deadline = self.connections[key].responses[&stream_id].write_deadline_at;
        self.response_timeouts
            .insert((deadline, key.to_vec(), stream_id));
    }

    fn remove_response_timeout(&mut self, key: &[u8], stream_id: u64) {
        let deadline = self.connections[key].responses[&stream_id].write_deadline_at;
        self.response_timeouts
            .remove(&(deadline, key.to_vec(), stream_id));
    }

    fn expire_responses(&mut self) {
        let now = Instant::now();
        while self
            .response_timeouts
            .first()
            .is_some_and(|(deadline, _, _)| *deadline <= now)
        {
            let (_, key, stream_id) = self.response_timeouts.pop_first().unwrap();
            let connection = self.connections.get_mut(&key).unwrap();
            let response = connection.responses.remove(&stream_id).unwrap();
            self.buffered_response_bytes -= response.buffered_bytes;
            self.request_routes.remove(&response.request_id);
            self.send_ready.push(&key);
            cancel_http3_request(connection, stream_id, H3_REQUEST_REJECTED);
            self.refresh_transport_timeout(&key);
            self.refresh_idle_timeout(&key);
        }
    }

    fn refresh_request_timeout(&mut self, key: &[u8], stream_id: u64) {
        let connection = self.connections.get_mut(key).unwrap();
        let deadline = connection
            .requests
            .get(&stream_id)
            .and_then(|request| {
                [
                    request.headers_deadline_at,
                    request.body_deadline_at,
                    request.idle_deadline_at,
                ]
                .into_iter()
                .flatten()
                .min()
            })
            .or_else(|| connection.header_deadlines.get(&stream_id).copied());
        if connection
            .indexed_request_deadlines
            .get(&stream_id)
            .copied()
            == deadline
        {
            return;
        }
        if let Some(previous) = connection.indexed_request_deadlines.remove(&stream_id) {
            self.request_timeouts
                .remove(&(previous, key.to_vec(), stream_id));
        }
        if let Some(deadline) = deadline {
            connection
                .indexed_request_deadlines
                .insert(stream_id, deadline);
            self.request_timeouts
                .insert((deadline, key.to_vec(), stream_id));
        }
    }

    fn take_due_request_timeout(&mut self, now: Instant) -> Option<(Vec<u8>, u64)> {
        if self.request_timeouts.first()?.0 > now {
            return None;
        }
        let (_, key, stream_id) = self.request_timeouts.pop_first().unwrap();
        self.connections
            .get_mut(&key)
            .unwrap()
            .indexed_request_deadlines
            .remove(&stream_id);
        Some((key, stream_id))
    }

    fn set_transport_timeout(&mut self, key: &[u8], deadline: Option<Instant>) {
        let connection = self.connections.get_mut(key).unwrap();
        if connection.transport_deadline_at == deadline {
            return;
        }
        if let Some(previous) = connection.transport_deadline_at.take() {
            self.transport_timeouts.remove(&(previous, key.to_vec()));
        }
        connection.transport_deadline_at = deadline;
        if let Some(deadline) = deadline {
            self.transport_timeouts.insert((deadline, key.to_vec()));
        }
    }

    fn refresh_transport_timeout(&mut self, key: &[u8]) {
        let deadline = self.connections[key].transport.timeout_instant();
        self.set_transport_timeout(key, deadline);
    }

    fn take_due_transport_timeout(&mut self, now: Instant) -> Option<Vec<u8>> {
        if self.transport_timeouts.first()?.0 > now {
            return None;
        }
        let (_, key) = self.transport_timeouts.pop_first().unwrap();
        self.connections
            .get_mut(&key)
            .unwrap()
            .transport_deadline_at = None;
        Some(key)
    }

    pub fn timeout(&self) -> Option<Duration> {
        let now = Instant::now();
        let request_timeout = self
            .request_timeouts
            .first()
            .map(|(deadline, _, _)| deadline.saturating_duration_since(now));
        let response_timeout = self
            .response_timeouts
            .first()
            .map(|(deadline, _, _)| deadline.saturating_duration_since(now));
        let connection_idle_timeout = self
            .idle_timeouts
            .first()
            .map(|(deadline, _)| deadline.saturating_duration_since(now));
        let stream_timeout = [request_timeout, response_timeout, connection_idle_timeout]
            .into_iter()
            .flatten()
            .min();
        let transport_timeout = self
            .transport_timeouts
            .first()
            .map(|(deadline, _)| deadline.saturating_duration_since(now));
        match (stream_timeout, transport_timeout) {
            (Some(left), Some(right)) => Some(left.min(right)),
            (Some(timeout), None) | (None, Some(timeout)) => Some(timeout),
            (None, None) => None,
        }
    }

    pub fn on_timeout(&mut self) {
        self.expire_incomplete_requests();
        self.expire_idle_connections();
        let _ = self.drive_responses();
        let mut closed = Vec::new();
        let now = Instant::now();
        while let Some(key) = self.take_due_transport_timeout(now) {
            self.connections
                .get_mut(&key)
                .unwrap()
                .transport
                .on_timeout();
            self.send_ready.push(&key);
            self.refresh_transport_timeout(&key);
        }
        for (connection_key, connection) in &self.connections {
            if connection.transport.is_closed() {
                closed.push(connection_key.clone());
            }
        }
        for connection_key in closed {
            self.reap_closed_connection(&connection_key);
        }
    }

    fn expire_incomplete_requests(&mut self) {
        let now = Instant::now();
        while let Some((key, stream_id)) = self.take_due_request_timeout(now) {
            self.send_ready.push(&key);
            let connection = self.connections.get_mut(&key).unwrap();
            connection.header_deadlines.remove(&stream_id);
            if let Some(rejected) = connection.requests.remove(&stream_id) {
                release_pending_request_bytes(&mut self.buffered_request_bytes, &rejected);
            }
            cancel_http3_request(connection, stream_id, H3_REQUEST_REJECTED);
            self.refresh_transport_timeout(&key);
            self.refresh_idle_timeout(&key);
        }
    }

    fn expire_idle_connections(&mut self) {
        let now = Instant::now();
        while self
            .idle_timeouts
            .first()
            .is_some_and(|(deadline, _)| *deadline <= now)
        {
            let (_, key) = self.idle_timeouts.pop_first().unwrap();
            let connection = self.connections.get_mut(&key).unwrap();
            connection.indexed_idle_deadline_at = None;
            let _ = connection.transport.close(true, 0x00, b"idle timeout");
            self.force_drop_connection(&key);
        }
    }

    fn arm_header_deadlines(
        connection: &mut QuicConnection,
        header_deadline: Duration,
        touched: &mut HashSet<u64>,
    ) {
        let now = Instant::now();
        let readable: Vec<u64> = connection.transport.readable().collect();
        for stream_id in readable {
            // Client-initiated bidirectional streams carry HTTP/3 requests.
            if stream_id % 4 != 0 {
                continue;
            }
            if connection.requests.contains_key(&stream_id) {
                continue;
            }
            if let std::collections::hash_map::Entry::Vacant(entry) =
                connection.header_deadlines.entry(stream_id)
            {
                entry.insert(now + header_deadline);
                touched.insert(stream_id);
            }
        }
    }
}

fn cancel_http3_request(connection: &mut QuicConnection, stream_id: u64, error_code: u64) {
    if connection
        .http3
        .as_mut()
        .unwrap()
        .cancel_request(&mut connection.transport, stream_id, error_code)
        .is_err()
    {
        let _ = connection.transport.close(
            true,
            H3_GENERAL_PROTOCOL_ERROR,
            b"request cancellation failed",
        );
    }
}

#[cfg(test)]
mod allocation_probe {
    use std::alloc::{GlobalAlloc, Layout, System};
    use std::cell::Cell;
    thread_local! { static LIVE: Cell<isize> = const { Cell::new(0) }; }
    struct Counting;
    #[global_allocator]
    static ALLOCATOR: Counting = Counting;
    fn account(delta: isize) {
        let _ = LIVE.try_with(|live| live.set(live.get() + delta));
    }
    unsafe impl GlobalAlloc for Counting {
        unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
            let ptr = unsafe { System.alloc(layout) };
            if !ptr.is_null() {
                account(layout.size() as isize);
            }
            ptr
        }
        unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
            account(-(layout.size() as isize));
            unsafe { System.dealloc(ptr, layout) };
        }
        unsafe fn realloc(&self, ptr: *mut u8, old: Layout, size: usize) -> *mut u8 {
            let new_ptr = unsafe { System.realloc(ptr, old, size) };
            if !new_ptr.is_null() {
                account(size as isize - old.size() as isize);
            }
            new_ptr
        }
    }
    pub fn live() -> isize {
        LIVE.with(Cell::get)
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::{CStr, CString, c_char};
    use std::net::UdpSocket;
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};
    use std::time::Duration;

    use quiche::{ConnectionId, Header, RecvInfo};

    use super::{
        MAX_HTTP3_BUFFERED_RESPONSE_BYTES, MAX_HTTP3_REQUEST_BODY_BYTES, NetQuicServerConfig,
        PendingRequest, append_bytes, append_request_body, append_u32,
        completed_request_retained_bytes, net_quic_server_free, net_quic_server_new,
        reserve_response_bytes,
    };
    use quiche::h3::NameValue;

    fn insert_idle_transports(server: &mut super::QuicServer, count: u16) {
        let local: SocketAddr = "127.0.0.1:4433".parse().unwrap();
        for index in 0..count {
            let key = index.to_be_bytes().repeat(8);
            let remote = SocketAddr::new(local.ip(), 20000 + index);
            let transport = quiche::accept(
                &ConnectionId::from_ref(&key),
                None,
                local,
                remote,
                &mut server.config,
            )
            .unwrap();
            server.connections.insert(
                key,
                super::QuicConnection {
                    transport,
                    transport_deadline_at: None,
                    indexed_idle_deadline_at: None,
                    http3: None,
                    requests: Default::default(),
                    header_deadlines: Default::default(),
                    indexed_request_deadlines: Default::default(),
                    responses: Default::default(),
                    goaway_sent: false,
                    final_goaway_sent: false,
                    last_request_stream_id: None,
                    final_goaway_last_stream_id: None,
                    idle_deadline_at: None,
                },
            );
        }
    }

    fn request_timer_peer() -> (
        super::QuicServer,
        quiche::Connection,
        quiche::h3::Connection,
        SocketAddr,
        SocketAddr,
    ) {
        let mut server = super::QuicServer::new(stress_server_config()).unwrap();
        let local: SocketAddr = "127.0.0.1:4433".parse().unwrap();
        let remote: SocketAddr = "127.0.0.1:30400".parse().unwrap();
        let mut client = quiche::connect(
            Some("localhost"),
            &ConnectionId::from_ref(&[0x97; 16]),
            remote,
            local,
            &mut stress_client_config(),
        )
        .unwrap();
        establish_http3_in_memory(
            &mut client,
            &mut server,
            &mut [0; 65535],
            local,
            remote,
            false,
        );
        let h3 = quiche::h3::Connection::with_transport(
            &mut client,
            &quiche::h3::Config::new().unwrap(),
        )
        .unwrap();
        (server, client, h3, local, remote)
    }

    #[test]
    fn stop_sending_cancels_blocked_response_without_aborting_siblings_or_reuse() {
        for started in [false, true] {
            let (mut server, mut client, mut h3, local, remote) = request_timer_peer();
            let mut packet = [0; 65535];
            let headers = [
                quiche::h3::Header::new(b":method", b"GET"),
                quiche::h3::Header::new(b":scheme", b"https"),
                quiche::h3::Header::new(b":authority", b"localhost"),
                quiche::h3::Header::new(b":path", b"/stop"),
            ];
            let cancelled_id = h3.send_request(&mut client, &headers, true).unwrap();
            for _ in 0..32 {
                pump_in_memory(
                    &mut client,
                    &mut server,
                    &mut packet,
                    local,
                    remote,
                    false,
                    false,
                );
            }
            let request = server.next_request().unwrap();
            assert_eq!(request.stream_id, cancelled_id);
            assert!(server.enqueue_response(request.id, 200, Vec::new(), vec![42; 2_000_000]));
            if started {
                server.drive_responses().unwrap();
            }
            let key = server.connections.keys().next().unwrap().clone();
            let response = &server.connections[&key].responses[&cancelled_id];
            assert_eq!(response.headers_sent, started);
            if started {
                assert!(response.body_offset > 0 && response.body_offset < response.body.len());
            } else {
                assert_eq!(response.body_offset, 0);
            }
            client
                .stream_shutdown(cancelled_id, quiche::Shutdown::Read, 0x10c)
                .unwrap();
            for datagram in collect_client_datagrams(&mut client, &mut packet) {
                deliver_client_datagram(&mut server, &datagram, local, remote);
            }
            let result = server.drive_responses();
            assert!(
                result.is_ok(),
                "peer STOP_SENDING must cancel only its response: {result:?}"
            );
            assert!(server.connections[&key].responses.is_empty());
            assert!(server.response_timeouts.is_empty());
            assert_eq!(server.buffered_response_bytes, 0);
            assert!(!server.request_routes.contains_key(&request.id));
            assert!(server.connections[&key].transport.local_error().is_none());
            for _ in 0..2 {
                let id = h3.send_request(&mut client, &headers, true).unwrap();
                for _ in 0..32 {
                    pump_in_memory(
                        &mut client,
                        &mut server,
                        &mut packet,
                        local,
                        remote,
                        false,
                        false,
                    );
                }
                let request = server.next_request().unwrap();
                assert_eq!(request.stream_id, id);
                assert!(server.enqueue_response(request.id, 200, Vec::new(), b"alive".to_vec()));
                let mut body = Vec::new();
                let mut finished = false;
                for _ in 0..64 {
                    pump_in_memory(
                        &mut client,
                        &mut server,
                        &mut packet,
                        local,
                        remote,
                        false,
                        false,
                    );
                    loop {
                        match h3.poll(&mut client) {
                            Ok((stream_id, quiche::h3::Event::Data)) if stream_id == id => {
                                let mut chunk = [0; 64];
                                while let Ok(length) = h3.recv_body(&mut client, id, &mut chunk) {
                                    body.extend_from_slice(&chunk[..length]);
                                }
                            }
                            Ok((stream_id, quiche::h3::Event::Finished)) if stream_id == id => {
                                finished = true
                            }
                            Ok(_) => (),
                            Err(quiche::h3::Error::Done) => break,
                            Err(error) => panic!("sibling response failed: {error:?}"),
                        }
                    }
                    if finished {
                        break;
                    }
                }
                assert!(finished);
                assert_eq!(body, b"alive");
                assert_eq!(server.connections.len(), 1);
                assert!(server.response_timeouts.is_empty());
            }
        }
    }

    #[test]
    fn busy_request_disarms_expired_idle_until_request_phase_clears() {
        let (mut server, mut client, mut h3, local, remote) = request_timer_peer();
        let mut packet = [0; 65535];
        let headers = [
            quiche::h3::Header::new(b":method", b"POST"),
            quiche::h3::Header::new(b":scheme", b"https"),
            quiche::h3::Header::new(b":authority", b"localhost"),
            quiche::h3::Header::new(b":path", b"/idle"),
        ];
        let id = h3.send_request(&mut client, &headers, false).unwrap();
        h3.send_body(&mut client, id, b"busy", false).unwrap();
        for _ in 0..32 {
            pump_in_memory(
                &mut client,
                &mut server,
                &mut packet,
                local,
                remote,
                false,
                false,
            );
        }
        let key = server.connections.keys().next().unwrap().clone();
        let now = std::time::Instant::now();
        server.connections.get_mut(&key).unwrap().idle_deadline_at = Some(now);
        server
            .connections
            .get_mut(&key)
            .unwrap()
            .requests
            .get_mut(&id)
            .unwrap()
            .body_deadline_at = Some(now + Duration::from_secs(2));
        server.refresh_request_timeout(&key, id);
        server.refresh_idle_timeout(&key);
        server.set_transport_timeout(&key, None);
        assert!(
            server.timeout().unwrap() > Duration::ZERO,
            "busy requests must wait for their active phase, not expired connection idle"
        );
        assert!(server.idle_timeouts.is_empty());
        server.expire_idle_connections();
        assert!(server.connections.contains_key(&key));
        server
            .connections
            .get_mut(&key)
            .unwrap()
            .requests
            .get_mut(&id)
            .unwrap()
            .body_deadline_at = Some(now);
        server.refresh_request_timeout(&key, id);
        server.expire_incomplete_requests();
        assert_eq!(server.idle_timeouts.first().unwrap().0, now);
        assert_eq!(server.timeout(), Some(Duration::ZERO));
        server.expire_idle_connections();
        assert!(server.connections.is_empty());
        assert!(server.idle_timeouts.is_empty());
        assert!(server.request_timeouts.is_empty());
        assert_eq!(server.buffered_request_bytes, 0);
    }

    #[test]
    fn busy_response_disarms_expired_idle_and_expiry_releases_budget() {
        let (mut server, mut client, mut h3, local, remote) = request_timer_peer();
        let mut packet = [0; 65535];
        let headers = [
            quiche::h3::Header::new(b":method", b"GET"),
            quiche::h3::Header::new(b":scheme", b"https"),
            quiche::h3::Header::new(b":authority", b"localhost"),
            quiche::h3::Header::new(b":path", b"/idle"),
        ];
        h3.send_request(&mut client, &headers, true).unwrap();
        for _ in 0..32 {
            pump_in_memory(
                &mut client,
                &mut server,
                &mut packet,
                local,
                remote,
                false,
                false,
            );
        }
        let request = server.next_request().unwrap();
        let key = server.connections.keys().next().unwrap().clone();
        assert!(server.enqueue_response(request.id, 200, Vec::new(), vec![42; 2_000_000]));
        server.drive_responses().unwrap();
        assert_eq!(server.connections[&key].responses.len(), 1);
        let now = std::time::Instant::now();
        server.connections.get_mut(&key).unwrap().idle_deadline_at = Some(now);
        server.refresh_idle_timeout(&key);
        server.set_transport_timeout(&key, None);
        assert!(
            server.timeout().unwrap() > Duration::ZERO,
            "busy responses must wait for their write deadline"
        );
        let id = request.stream_id;
        for _ in 0..1000 {
            server.index_response_timeout(&key, id);
        }
        assert_eq!(server.response_timeouts.len(), 1);
        assert!(server.idle_timeouts.is_empty());
        server.remove_response_timeout(&key, id);
        server
            .connections
            .get_mut(&key)
            .unwrap()
            .responses
            .get_mut(&id)
            .unwrap()
            .write_deadline_at = now;
        server.index_response_timeout(&key, id);
        server.drive_responses().unwrap();
        assert!(server.response_timeouts.is_empty());
        assert_eq!(server.buffered_response_bytes, 0);
        assert!(!server.request_routes.contains_key(&request.id));
        assert_eq!(server.idle_timeouts.first().unwrap().0, now);
        assert_eq!(server.timeout(), Some(Duration::ZERO));
        server.expire_idle_connections();
        assert!(server.connections.is_empty());
    }

    #[test]
    fn response_completion_and_terminal_drop_remove_write_deadlines() {
        for mode in 0..2 {
            let (mut server, mut client, mut h3, local, remote) = request_timer_peer();
            let mut packet = [0; 65535];
            let headers = [
                quiche::h3::Header::new(b":method", b"GET"),
                quiche::h3::Header::new(b":scheme", b"https"),
                quiche::h3::Header::new(b":authority", b"localhost"),
                quiche::h3::Header::new(b":path", b"/idle"),
            ];
            h3.send_request(&mut client, &headers, true).unwrap();
            for _ in 0..32 {
                pump_in_memory(
                    &mut client,
                    &mut server,
                    &mut packet,
                    local,
                    remote,
                    false,
                    false,
                );
            }
            let request = server.next_request().unwrap();
            let key = server.connections.keys().next().unwrap().clone();
            assert!(server.enqueue_response(
                request.id,
                200,
                Vec::new(),
                if mode == 0 {
                    vec![42; 4]
                } else {
                    vec![42; 2_000_000]
                }
            ));
            let retained = server.buffered_response_bytes;
            let original_deadline = server.response_timeouts.first().unwrap().0;
            let mut provider = super::NetQuicServer { _inner: server };
            let headers = [0u8; 4];
            let body = b"duplicate";
            assert_eq!(
                unsafe {
                    super::net_quic_server_respond(
                        &mut provider,
                        request.id,
                        200,
                        headers.as_ptr(),
                        headers.len(),
                        body.as_ptr(),
                        body.len(),
                    )
                },
                0
            );
            server = provider._inner;
            assert_eq!(server.buffered_response_bytes, retained);
            assert_eq!(server.response_timeouts.len(), 1);
            assert_eq!(
                server.response_timeouts.first().unwrap().0,
                original_deadline
            );
            if mode == 0 {
                server.drive_responses().unwrap();
            } else {
                server.force_drop_connection(&key);
            }
            assert!(server.response_timeouts.is_empty());
            assert_eq!(server.buffered_response_bytes, 0);
            assert!(!server.request_routes.contains_key(&request.id));
        }
    }

    #[test]
    fn idle_index_replaces_deadlines_disarms_and_allows_key_reuse() {
        let mut server = super::QuicServer::new(stress_server_config()).unwrap();
        insert_idle_transports(&mut server, 128);
        let key = [0; 16];
        let now = std::time::Instant::now();
        for key in server.connections.keys().cloned().collect::<Vec<_>>() {
            server.connections.get_mut(&key).unwrap().idle_deadline_at =
                Some(now + Duration::from_secs(16));
            server.refresh_idle_timeout(&key);
        }
        assert_eq!(server.idle_timeouts.len(), 128);
        for tick in 0..1000 {
            server
                .connections
                .get_mut(&key[..])
                .unwrap()
                .idle_deadline_at = Some(now + Duration::from_secs(8) + Duration::from_nanos(tick));
            server.refresh_idle_timeout(&key);
        }
        assert_eq!(server.idle_timeouts.len(), 128);
        server
            .connections
            .get_mut(&key[..])
            .unwrap()
            .idle_deadline_at = Some(now + Duration::from_secs(20));
        server.refresh_idle_timeout(&key);
        assert_ne!(server.idle_timeouts.first().unwrap().1, key);
        server
            .connections
            .get_mut(&key[..])
            .unwrap()
            .idle_deadline_at = Some(now + Duration::from_secs(1));
        server.refresh_idle_timeout(&key);
        assert_eq!(server.idle_timeouts.first().unwrap().1, key);
        server
            .connections
            .get_mut(&key[..])
            .unwrap()
            .idle_deadline_at = None;
        server.refresh_idle_timeout(&key);
        assert_eq!(server.idle_timeouts.len(), 127);
        server.force_drop_connection(&key);
        insert_idle_transports(&mut server, 1);
        server
            .connections
            .get_mut(&key[..])
            .unwrap()
            .idle_deadline_at = Some(now);
        server.refresh_idle_timeout(&key);
        server.expire_idle_connections();
        assert_eq!(server.connections.len(), 127);
        assert_eq!(server.idle_timeouts.len(), 127);
        assert!(!server.connections.contains_key(&key[..]));
    }

    #[test]
    fn request_phase_deadlines_replace_rearm_disarm_and_drop_without_stale_entries() {
        let mut server = super::QuicServer::new(stress_server_config()).unwrap();
        insert_idle_transports(&mut server, 1);
        let key = [0; 16];
        let now = std::time::Instant::now();
        server
            .connections
            .get_mut(&key[..])
            .unwrap()
            .requests
            .insert(0, PendingRequest::default());
        for tick in 0..1000 {
            server
                .connections
                .get_mut(&key[..])
                .unwrap()
                .requests
                .get_mut(&0)
                .unwrap()
                .body_deadline_at =
                Some(now + Duration::from_secs(12) + Duration::from_nanos(tick));
            server.refresh_request_timeout(&key, 0);
        }
        server
            .connections
            .get_mut(&key[..])
            .unwrap()
            .header_deadlines
            .insert(4, now + Duration::from_secs(8));
        server.refresh_request_timeout(&key, 4);
        assert_eq!(server.request_timeouts.len(), 2);
        assert_eq!(server.request_timeouts.first().unwrap().2, 4);
        server
            .connections
            .get_mut(&key[..])
            .unwrap()
            .requests
            .get_mut(&0)
            .unwrap()
            .idle_deadline_at = Some(now + Duration::from_secs(2));
        server.refresh_request_timeout(&key, 0);
        assert_eq!(server.request_timeouts.first().unwrap().2, 0);
        server
            .connections
            .get_mut(&key[..])
            .unwrap()
            .requests
            .remove(&0);
        server.refresh_request_timeout(&key, 0);
        assert_eq!(server.request_timeouts.len(), 1);
        server.force_drop_connection(&key);
        assert!(server.request_timeouts.is_empty());
        insert_idle_transports(&mut server, 1);
        server
            .connections
            .get_mut(&key[..])
            .unwrap()
            .header_deadlines
            .insert(4, now + Duration::from_secs(10));
        server.refresh_request_timeout(&key, 4);
        assert_eq!(
            server.request_timeouts.first().unwrap().0,
            now + Duration::from_secs(10)
        );
        server
            .connections
            .get_mut(&key[..])
            .unwrap()
            .header_deadlines
            .insert(4, now);
        server
            .connections
            .get_mut(&key[..])
            .unwrap()
            .idle_deadline_at = None;
        server.refresh_request_timeout(&key, 4);
        server.set_transport_timeout(&key, None);
        assert_eq!(server.timeout(), Some(Duration::ZERO));
        assert_eq!(
            server.take_due_request_timeout(now),
            Some((key.to_vec(), 4))
        );
        assert!(server.request_timeouts.is_empty());
        assert!(
            server.connections[&key[..]]
                .indexed_request_deadlines
                .is_empty()
        );
    }

    #[test]
    fn peer_reset_clears_incomplete_header_deadline() {
        let (mut server, mut client, mut h3, local, remote) = request_timer_peer();
        let mut packet = [0; 65535];
        let padding = vec![b'x'; 6_000];
        let headers = [
            quiche::h3::Header::new(b":method", b"POST"),
            quiche::h3::Header::new(b":scheme", b"https"),
            quiche::h3::Header::new(b":authority", b"localhost"),
            quiche::h3::Header::new(b":path", b"/phase"),
            quiche::h3::Header::new(b"x-padding", &padding),
        ];
        let id = h3.send_request(&mut client, &headers, false).unwrap();
        for _ in 0..8 {
            let (length, _) = client.send(&mut packet).unwrap();
            deliver_client_datagram(&mut server, &packet[..length], local, remote);
            if server
                .connections
                .values()
                .next()
                .unwrap()
                .header_deadlines
                .contains_key(&id)
            {
                break;
            }
            flush_server_to_client(&mut client, &mut server, &mut packet, remote);
        }
        assert!(
            server
                .connections
                .values()
                .next()
                .unwrap()
                .header_deadlines
                .contains_key(&id)
        );
        assert!(server.idle_timeouts.is_empty());
        client
            .stream_shutdown(id, quiche::Shutdown::Write, 0x10c)
            .unwrap();
        for _ in 0..32 {
            pump_in_memory(
                &mut client,
                &mut server,
                &mut packet,
                local,
                remote,
                false,
                false,
            );
        }
        assert!(
            !server
                .connections
                .values()
                .next()
                .unwrap()
                .header_deadlines
                .contains_key(&id)
        );
        assert!(server.request_timeouts.is_empty());
        assert_eq!(server.idle_timeouts.len(), 1);
        assert!(
            server
                .connections
                .values()
                .next()
                .unwrap()
                .indexed_request_deadlines
                .is_empty()
        );
        assert_eq!(server.buffered_request_bytes, 0);
    }

    #[test]
    fn protocol_error_keeps_touched_header_deadline_indexed_until_connection_drop() {
        let (mut server, mut client, _h3, local, remote) = request_timer_peer();
        let mut packet = [0; 65535];
        client.stream_send(0, &[0, 1, 42], false).unwrap();
        for datagram in collect_client_datagrams(&mut client, &mut packet) {
            deliver_client_datagram(&mut server, &datagram, local, remote);
        }
        let key = server.connections.keys().next().unwrap().clone();
        assert!(server.connections[&key].transport.local_error().is_some());
        assert!(server.connections[&key].header_deadlines.contains_key(&0));
        assert_eq!(server.request_timeouts.len(), 1);
        server.force_drop_connection(&key);
        assert!(server.request_timeouts.is_empty());
        assert_eq!(server.buffered_request_bytes, 0);
    }

    #[test]
    fn actual_request_completion_error_and_expiration_clear_deadline_and_budget() {
        for mode in 0..3 {
            let (mut server, mut client, mut h3, local, remote) = request_timer_peer();
            let mut packet = [0; 65535];
            let headers = [
                quiche::h3::Header::new(b":method", b"POST"),
                quiche::h3::Header::new(b":scheme", b"https"),
                quiche::h3::Header::new(b":authority", b"localhost"),
                quiche::h3::Header::new(b":path", b"/phase"),
                quiche::h3::Header::new(b"content-length", b"8"),
            ];
            let id = h3.send_request(&mut client, &headers, false).unwrap();
            h3.send_body(&mut client, id, b"ping", false).unwrap();
            for _ in 0..32 {
                pump_in_memory(
                    &mut client,
                    &mut server,
                    &mut packet,
                    local,
                    remote,
                    false,
                    false,
                );
            }
            let key = server.connections.keys().next().unwrap().clone();
            assert!(server.buffered_request_bytes > 0);
            assert_eq!(server.request_timeouts.len(), 1);
            if mode == 2 {
                server
                    .connections
                    .get_mut(&key)
                    .unwrap()
                    .requests
                    .get_mut(&id)
                    .unwrap()
                    .body_deadline_at = Some(std::time::Instant::now());
                server.refresh_request_timeout(&key, id);
                server.expire_incomplete_requests();
            } else {
                h3.send_body(&mut client, id, if mode == 0 { b"pong" } else { b"" }, true)
                    .unwrap();
                for _ in 0..32 {
                    pump_in_memory(
                        &mut client,
                        &mut server,
                        &mut packet,
                        local,
                        remote,
                        false,
                        false,
                    );
                }
                if mode == 0 {
                    assert_eq!(server.next_request().unwrap().body, b"pingpong");
                } else {
                    assert!(server.next_request().is_none());
                }
            }
            assert!(server.connections[&key].requests.is_empty());
            assert!(
                server.connections[&key]
                    .indexed_request_deadlines
                    .is_empty()
            );
            assert!(server.request_timeouts.is_empty());
            assert_eq!(server.buffered_request_bytes, 0);
        }
    }

    #[test]
    fn transport_timer_query_reads_index_and_preserves_application_priority() {
        let mut server = super::QuicServer::new(stress_server_config()).unwrap();
        insert_idle_transports(&mut server, 1);
        let key = [0; 16];
        let now = std::time::Instant::now();
        server.set_transport_timeout(&key, Some(now + Duration::from_secs(10)));
        server
            .connections
            .get_mut(&key[..])
            .unwrap()
            .idle_deadline_at = Some(now);
        server.refresh_idle_timeout(&key);
        assert_eq!(server.timeout(), Some(Duration::ZERO));
        server
            .connections
            .get_mut(&key[..])
            .unwrap()
            .idle_deadline_at = None;
        server.refresh_idle_timeout(&key);
        server.set_transport_timeout(&key, Some(now));
        assert_eq!(server.timeout(), Some(Duration::ZERO));
        server.set_transport_timeout(&key, None);
        assert_eq!(server.timeout(), None);
    }

    #[test]
    fn transport_timer_rearms_replace_increase_decrease_and_disarm() {
        let mut server = super::QuicServer::new(stress_server_config()).unwrap();
        insert_idle_transports(&mut server, 2);
        let first = [0; 16];
        let second = 1u16.to_be_bytes().repeat(8);
        let now = std::time::Instant::now();
        server.set_transport_timeout(&first, Some(now + Duration::from_secs(4)));
        server.set_transport_timeout(&second, Some(now + Duration::from_secs(8)));
        for tick in 0..1000 {
            server.set_transport_timeout(
                &first,
                Some(now + Duration::from_secs(12) + Duration::from_nanos(tick)),
            );
        }
        assert_eq!(server.transport_timeouts.len(), 2);
        assert_eq!(
            server.take_due_transport_timeout(now + Duration::from_secs(7)),
            None
        );
        assert_eq!(
            server.take_due_transport_timeout(now + Duration::from_secs(8)),
            Some(second)
        );
        server.set_transport_timeout(&first, Some(now + Duration::from_secs(2)));
        assert_eq!(
            server.take_due_transport_timeout(now + Duration::from_secs(2)),
            Some(first.to_vec())
        );
        assert!(server.transport_timeouts.is_empty());
        server.set_transport_timeout(&first, Some(now + Duration::from_secs(3)));
        server.set_transport_timeout(&first, None);
        assert!(server.transport_timeouts.is_empty());
        assert_eq!(server.connections[&first[..]].transport_deadline_at, None);
    }

    #[test]
    fn terminal_transport_timer_removal_allows_connection_key_reuse() {
        let mut server = super::QuicServer::new(stress_server_config()).unwrap();
        insert_idle_transports(&mut server, 1);
        let key = [0; 16];
        let now = std::time::Instant::now();
        server.set_transport_timeout(&key, Some(now + Duration::from_secs(5)));
        assert_eq!(server.transport_timeouts.len(), 1);
        server.force_drop_connection(&key);
        assert!(server.transport_timeouts.is_empty());
        insert_idle_transports(&mut server, 1);
        server.set_transport_timeout(&key, Some(now + Duration::from_secs(10)));
        assert_eq!(
            server.take_due_transport_timeout(now + Duration::from_secs(5)),
            None
        );
        assert_eq!(
            server.take_due_transport_timeout(now + Duration::from_secs(10)),
            Some(key.to_vec())
        );
        assert!(server.transport_timeouts.is_empty());
    }

    #[test]
    fn send_ready_marks_deduplicate_rotate_and_allow_removed_key_reuse() {
        let mut ready = super::SendReadyQueue::default();
        for _ in 0..1000 {
            ready.push(b"first");
            ready.push(b"second");
        }
        assert_eq!(ready.entries.len(), 2);
        assert_eq!(ready.pop().unwrap(), b"first");
        ready.push(b"first");
        assert_eq!(ready.pop().unwrap(), b"second");
        ready.push(b"second");
        ready.remove(b"first");
        assert_eq!(ready.pop().unwrap(), b"second");
        assert!(ready.pop().is_none());
        ready.push(b"first");
        assert_eq!(ready.pop().unwrap(), b"first");
        assert!(ready.queued.is_empty());
    }

    #[test]
    fn send_failure_retains_work_until_terminal_drop_and_key_reuse() {
        let mut server = super::QuicServer::new(stress_server_config()).unwrap();
        insert_idle_transports(&mut server, 128);
        let key = [0; 16];
        server.send_ready.push(&key);
        assert!(matches!(
            server.send(&mut []),
            Err(super::QuicServerError::Quiche(
                quiche::Error::BufferTooShort
            ))
        ));
        assert_eq!(server.send_ready.entries.len(), 1);
        server.force_drop_connection(&key);
        assert_eq!(server.connections.len(), 127);
        assert!(server.send_ready.entries.is_empty());
        assert!(server.send(&mut []).unwrap().is_none());
        insert_idle_transports(&mut server, 1);
        server.send_ready.push(&key);
        assert!(matches!(
            server.send(&mut []),
            Err(super::QuicServerError::Quiche(
                quiche::Error::BufferTooShort
            ))
        ));
        assert!(server.send(&mut [0; 65535]).unwrap().is_none());
        assert!(server.send_ready.entries.is_empty());
        assert!(server.send_ready.queued.is_empty());
    }

    #[test]
    fn send_skips_idle_transports_instead_of_attempting_every_connection() {
        let mut server = super::QuicServer::new(stress_server_config()).unwrap();
        insert_idle_transports(&mut server, 128);
        assert_eq!(server.connections.len(), 128);
        assert!(server.send(&mut []).unwrap().is_none());
    }

    #[test]
    fn send_rotates_one_packet_between_active_response_connections() {
        let mut server = super::QuicServer::new(stress_server_config()).unwrap();
        let local: SocketAddr = "127.0.0.1:4433".parse().unwrap();
        let mut packet = [0; 65535];
        let mut request_ids = Vec::new();
        for index in 0..2u8 {
            let remote = SocketAddr::new(local.ip(), 30000 + u16::from(index));
            let mut client = quiche::connect(
                Some("localhost"),
                &ConnectionId::from_ref(&[0x80 + index; 16]),
                remote,
                local,
                &mut stress_client_config(),
            )
            .unwrap();
            establish_http3_in_memory(&mut client, &mut server, &mut packet, local, remote, false);
            let request = complete_post_request_in_memory(
                &mut client,
                &mut server,
                &mut packet,
                local,
                remote,
                false,
                false,
            );
            request_ids.push(request.id);
        }
        for request_id in request_ids {
            assert!(server.enqueue_response(request_id, 200, Vec::new(), vec![42; 65536]));
        }
        let first = server.send(&mut packet).unwrap().unwrap().1.to;
        let second = server.send(&mut packet).unwrap().unwrap().1.to;
        assert_ne!(
            first, second,
            "one active connection must not monopolize packet sends"
        );
    }

    #[test]
    fn pacing_delay_preserves_future_send_and_saturates_past_send() {
        let now = std::time::Instant::now();
        let future = now + std::time::Duration::from_millis(4);
        assert_eq!(super::pacing_delay_ns(future, now), 4_000_000);
        assert_eq!(super::pacing_delay_ns(now, future), 0);
        assert_eq!(super::pacing_delay_ns(now, now), 0);
        let far_future = now + std::time::Duration::from_secs(20_000_000_000);
        assert_eq!(super::pacing_delay_ns(far_future, now), u64::MAX);
    }

    #[test]
    fn request_memory_budget_rejects_aggregate_overflow_without_changing_usage() {
        let mut used = 0;
        let mut first = PendingRequest::default();
        assert!(append_request_body(
            &mut first,
            b"123456",
            &mut used,
            10,
            MAX_HTTP3_REQUEST_BODY_BYTES
        ));
        assert_eq!(used, 6);
        let mut second = PendingRequest::default();
        assert!(append_request_body(
            &mut second,
            b"abcd",
            &mut used,
            10,
            MAX_HTTP3_REQUEST_BODY_BYTES
        ));
        assert_eq!(used, 10);
        let mut third = PendingRequest::default();
        assert!(!append_request_body(
            &mut third,
            b"x",
            &mut used,
            10,
            MAX_HTTP3_REQUEST_BODY_BYTES
        ));
        assert_eq!(used, 10);
        assert!(third.body.is_empty());
    }

    #[test]
    fn response_queue_budget_rejects_aggregate_overflow_without_changing_usage() {
        let mut used = MAX_HTTP3_BUFFERED_RESPONSE_BYTES - 6;
        assert!(reserve_response_bytes(&mut used, 6));
        assert_eq!(used, MAX_HTTP3_BUFFERED_RESPONSE_BYTES);
        assert!(!reserve_response_bytes(&mut used, 1));
        assert_eq!(used, MAX_HTTP3_BUFFERED_RESPONSE_BYTES);
    }

    #[test]
    fn provider_quic_config_keeps_early_data_disabled_on_session_resume() {
        assert!(
            !super::PROVIDER_ENABLE_EARLY_DATA,
            "provider must ship with 0-RTT / early data disabled"
        );

        let certificate_path = std::env::var("NET_HTTP_TEST_CERT").unwrap();
        let private_key_path = std::env::var("NET_HTTP_TEST_KEY").unwrap();

        // Share one ticket-encryption key so the resume server can decrypt
        // the ticket issued by the first server; otherwise resumption fails
        // before the early-data policy is evaluated.
        const TEST_TICKET_KEY: [u8; 48] = [0x0A; 48];

        let mut server_config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        server_config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        server_config
            .load_cert_chain_from_pem_file(&certificate_path)
            .unwrap();
        server_config
            .load_priv_key_from_pem_file(&private_key_path)
            .unwrap();
        super::apply_provider_quic_transport_settings(&mut server_config);
        // Issue an early-data-capable ticket: the first handshake uses a
        // server (and client) with early data enabled so the resumed
        // Initial can actually offer 0-RTT. The server under test below
        // uses production settings (disabled) to verify rejection.
        server_config.set_ticket_key(&TEST_TICKET_KEY).unwrap();
        server_config.enable_early_data();

        let mut client_config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        client_config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        client_config.verify_peer(false);
        super::apply_provider_quic_transport_settings(&mut client_config);
        client_config.enable_early_data();

        let client_address = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 54321);
        let server_address = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 4433);
        let mut packet = [0; 65535];

        // Initial handshake to obtain a session ticket.
        let client_scid = [0x31; 16];
        let server_scid = [0x52; 16];
        let mut client = quiche::connect(
            Some("localhost"),
            &ConnectionId::from_ref(&client_scid),
            client_address,
            server_address,
            &mut client_config,
        )
        .unwrap();
        let (initial_length, _) = client.send(&mut packet).unwrap();
        let original_dcid = Header::from_slice(&mut packet[..initial_length], 16)
            .unwrap()
            .dcid
            .as_ref()
            .to_vec();
        let mut server = quiche::accept(
            &ConnectionId::from_ref(&server_scid),
            Some(&ConnectionId::from_ref(&original_dcid)),
            server_address,
            client_address,
            &mut server_config,
        )
        .unwrap();
        server
            .recv(
                &mut packet[..initial_length],
                RecvInfo {
                    from: client_address,
                    to: server_address,
                },
            )
            .unwrap();

        for _ in 0..16 {
            while let Ok((length, _)) = server.send(&mut packet) {
                client
                    .recv(
                        &mut packet[..length],
                        RecvInfo {
                            from: server_address,
                            to: client_address,
                        },
                    )
                    .unwrap();
            }
            while let Ok((length, _)) = client.send(&mut packet) {
                server
                    .recv(
                        &mut packet[..length],
                        RecvInfo {
                            from: client_address,
                            to: server_address,
                        },
                    )
                    .unwrap();
            }
            if client.is_established() && server.is_established() && client.session().is_some() {
                break;
            }
        }
        assert!(client.is_established());
        assert!(server.is_established());
        assert!(!client.is_in_early_data());
        assert!(!server.is_in_early_data());

        let session = client
            .session()
            .expect("session ticket after handshake")
            .to_vec();

        // Resuming client offers 0-RTT; production server must reject it.
        // Only the server under test uses provider settings (early data
        // disabled). The resuming client enables early data so the Initial
        // actually contains a 0-RTT offer.
        let mut resume_server_config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        resume_server_config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        resume_server_config
            .load_cert_chain_from_pem_file(&certificate_path)
            .unwrap();
        resume_server_config
            .load_priv_key_from_pem_file(&private_key_path)
            .unwrap();
        super::apply_provider_quic_transport_settings(&mut resume_server_config);
        resume_server_config
            .set_ticket_key(&TEST_TICKET_KEY)
            .unwrap();

        let mut resume_client_config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        resume_client_config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        resume_client_config.verify_peer(false);
        resume_client_config.set_initial_max_data(10_000_000);
        resume_client_config.set_initial_max_stream_data_bidi_local(1_000_000);
        resume_client_config.set_initial_max_stream_data_bidi_remote(1_000_000);
        resume_client_config.set_initial_max_stream_data_uni(1_000_000);
        resume_client_config.set_initial_max_streams_bidi(100);
        resume_client_config.set_initial_max_streams_uni(3);
        resume_client_config.set_max_idle_timeout(60_000);
        resume_client_config.enable_early_data();

        let resume_client_scid = [0x33; 16];
        let resume_server_scid = [0x54; 16];
        let mut resume_client = quiche::connect(
            Some("localhost"),
            &ConnectionId::from_ref(&resume_client_scid),
            client_address,
            server_address,
            &mut resume_client_config,
        )
        .unwrap();
        resume_client.set_session(&session).unwrap();
        let (resume_initial_length, _) = resume_client.send(&mut packet).unwrap();
        assert!(
            resume_client.is_in_early_data(),
            "resuming client must offer 0-RTT so the server can reject it"
        );

        let resume_dcid = Header::from_slice(&mut packet[..resume_initial_length], 16)
            .unwrap()
            .dcid
            .as_ref()
            .to_vec();
        let mut resume_server = quiche::accept(
            &ConnectionId::from_ref(&resume_server_scid),
            Some(&ConnectionId::from_ref(&resume_dcid)),
            server_address,
            client_address,
            &mut resume_server_config,
        )
        .unwrap();
        resume_server
            .recv(
                &mut packet[..resume_initial_length],
                RecvInfo {
                    from: client_address,
                    to: server_address,
                },
            )
            .unwrap();
        assert!(
            !resume_server.is_in_early_data(),
            "provider server configs must not accept 0-RTT early data"
        );
    }

    #[test]
    fn completes_http3_tls_handshake_over_quic_packets() {
        let certificate_path = std::env::var("NET_HTTP_TEST_CERT").unwrap();
        let private_key_path = std::env::var("NET_HTTP_TEST_KEY").unwrap();
        let mut server_config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        server_config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        server_config
            .load_cert_chain_from_pem_file(&certificate_path)
            .unwrap();
        server_config
            .load_priv_key_from_pem_file(&private_key_path)
            .unwrap();
        server_config.set_initial_max_data(10_000_000);
        server_config.set_initial_max_stream_data_bidi_local(1_000_000);
        server_config.set_initial_max_stream_data_bidi_remote(1_000_000);
        server_config.set_initial_max_stream_data_uni(1_000_000);
        server_config.set_initial_max_streams_bidi(100);
        server_config.set_initial_max_streams_uni(3);

        let mut client_config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        client_config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        client_config.verify_peer(false);
        client_config.set_initial_max_data(10_000_000);
        client_config.set_initial_max_stream_data_bidi_local(1_000_000);
        client_config.set_initial_max_stream_data_bidi_remote(1_000_000);
        client_config.set_initial_max_stream_data_uni(1_000_000);
        client_config.set_initial_max_streams_bidi(100);
        client_config.set_initial_max_streams_uni(3);

        let client_address = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 54321);
        let server_address = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 4433);
        let client_scid = [0x31; 16];
        let server_scid = [0x52; 16];
        let mut client = quiche::connect(
            Some("localhost"),
            &ConnectionId::from_ref(&client_scid),
            client_address,
            server_address,
            &mut client_config,
        )
        .unwrap();

        let mut packet = [0; 65535];
        let (initial_length, _) = client.send(&mut packet).unwrap();
        let original_dcid = Header::from_slice(&mut packet[..initial_length], 16)
            .unwrap()
            .dcid
            .as_ref()
            .to_vec();
        let mut server = quiche::accept(
            &ConnectionId::from_ref(&server_scid),
            Some(&ConnectionId::from_ref(&original_dcid)),
            server_address,
            client_address,
            &mut server_config,
        )
        .unwrap();
        server
            .recv(
                &mut packet[..initial_length],
                RecvInfo {
                    from: client_address,
                    to: server_address,
                },
            )
            .unwrap();

        for _ in 0..8 {
            while let Ok((length, _)) = server.send(&mut packet) {
                client
                    .recv(
                        &mut packet[..length],
                        RecvInfo {
                            from: server_address,
                            to: client_address,
                        },
                    )
                    .unwrap();
            }
            while let Ok((length, _)) = client.send(&mut packet) {
                server
                    .recv(
                        &mut packet[..length],
                        RecvInfo {
                            from: client_address,
                            to: server_address,
                        },
                    )
                    .unwrap();
            }
            if client.is_established() && server.is_established() {
                break;
            }
        }

        assert!(client.is_established());
        assert!(server.is_established());
        assert_eq!(client.application_proto(), b"h3");
        assert_eq!(server.application_proto(), b"h3");
    }

    #[test]
    fn drives_server_handshake_through_udp_datagrams() {
        let certificate_path = std::env::var("NET_HTTP_TEST_CERT").unwrap();
        let private_key_path = std::env::var("NET_HTTP_TEST_KEY").unwrap();
        let mut server_config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        server_config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        server_config
            .load_cert_chain_from_pem_file(&certificate_path)
            .unwrap();
        server_config
            .load_priv_key_from_pem_file(&private_key_path)
            .unwrap();
        server_config.set_initial_max_data(10_000_000);
        server_config.set_initial_max_stream_data_bidi_local(1_000_000);
        server_config.set_initial_max_stream_data_bidi_remote(1_000_000);
        server_config.set_initial_max_stream_data_uni(1_000_000);
        server_config.set_initial_max_streams_bidi(100);
        server_config.set_initial_max_streams_uni(3);

        let mut client_config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        client_config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        client_config.verify_peer(false);
        client_config.set_initial_max_data(10_000_000);
        client_config.set_initial_max_stream_data_bidi_local(1_000_000);
        client_config.set_initial_max_stream_data_bidi_remote(1_000_000);
        client_config.set_initial_max_stream_data_uni(1_000_000);
        client_config.set_initial_max_streams_bidi(100);
        client_config.set_initial_max_streams_uni(3);

        let server_socket = UdpSocket::bind("127.0.0.1:0").unwrap();
        let client_socket = UdpSocket::bind("127.0.0.1:0").unwrap();
        server_socket
            .set_read_timeout(Some(Duration::from_millis(100)))
            .unwrap();
        client_socket
            .set_read_timeout(Some(Duration::from_millis(100)))
            .unwrap();
        let server_address = server_socket.local_addr().unwrap();
        let client_address = client_socket.local_addr().unwrap();
        let client_scid = [0x31; 16];
        let mut client = quiche::connect(
            Some("localhost"),
            &ConnectionId::from_ref(&client_scid),
            client_address,
            server_address,
            &mut client_config,
        )
        .unwrap();
        let config = Box::into_raw(Box::new(NetQuicServerConfig {
            _inner: Some(server_config),
        }));
        let server = unsafe { net_quic_server_new(config) };
        assert!(!server.is_null());
        assert_eq!(
            unsafe { super::net_quic_server_shutdown_complete(std::ptr::null()) },
            0
        );
        assert_eq!(
            unsafe { super::net_quic_server_close_connections(server) },
            -1
        );
        let mut packet = [0; 65535];
        let mut dropped_server_packet = false;

        for _ in 0..40 {
            if client.timeout().is_some_and(|timeout| timeout.is_zero()) {
                client.on_timeout();
            }
            if unsafe { super::net_quic_server_timeout_micros(server) } == 0 {
                unsafe { super::net_quic_server_on_timeout(server) };
            }
            while let Ok((length, _)) = client.send(&mut packet) {
                client_socket
                    .send_to(&packet[..length], server_address)
                    .unwrap();
            }
            loop {
                let Ok((length, peer)) = server_socket.recv_from(&mut packet) else {
                    break;
                };
                let local = CString::new(server_address.to_string()).unwrap();
                let remote = CString::new(peer.to_string()).unwrap();
                let status = unsafe {
                    super::net_quic_server_recv(
                        server,
                        packet.as_mut_ptr(),
                        length,
                        local.as_ptr(),
                        remote.as_ptr(),
                    )
                };
                assert_eq!(status, 1);
            }
            loop {
                let mut destination = [0 as c_char; 64];
                let mut send_delay_ns = u64::MAX;
                let length = unsafe {
                    super::net_quic_server_send(
                        server,
                        packet.as_mut_ptr(),
                        packet.len(),
                        destination.as_mut_ptr(),
                        destination.len(),
                        &mut send_delay_ns,
                    )
                };
                if length <= 0 {
                    break;
                }
                assert_ne!(send_delay_ns, u64::MAX);
                std::thread::sleep(Duration::from_nanos(send_delay_ns));
                if !dropped_server_packet {
                    dropped_server_packet = true;
                    continue;
                }
                let destination = unsafe { CStr::from_ptr(destination.as_ptr()) }
                    .to_str()
                    .unwrap()
                    .parse::<SocketAddr>()
                    .unwrap();
                server_socket
                    .send_to(&packet[..length as usize], destination)
                    .unwrap();
            }
            loop {
                let Ok((length, peer)) = client_socket.recv_from(&mut packet) else {
                    break;
                };
                client
                    .recv(
                        &mut packet[..length],
                        RecvInfo {
                            from: peer,
                            to: client_address,
                        },
                    )
                    .unwrap();
            }
            if client.is_established() {
                break;
            }
        }

        assert!(client.is_established());
        assert!(dropped_server_packet);
        assert_eq!(client.application_proto(), b"h3");
        let mut client_h3 = quiche::h3::Connection::with_transport(
            &mut client,
            &quiche::h3::Config::new().unwrap(),
        )
        .unwrap();
        let request_headers = [
            quiche::h3::Header::new(b":method", b"POST"),
            quiche::h3::Header::new(b":scheme", b"https"),
            quiche::h3::Header::new(b":authority", b"localhost"),
            quiche::h3::Header::new(b":path", b"/items?q=1"),
            quiche::h3::Header::new(b"x-test", b"provider"),
            quiche::h3::Header::new(b"x-test", b"duplicate"),
            quiche::h3::Header::new(b"content-length", b"7"),
        ];
        let request_stream_id = client_h3
            .send_request(&mut client, &request_headers, false)
            .unwrap();
        assert_eq!(
            client_h3
                .send_body(&mut client, request_stream_id, b"payload", true)
                .unwrap(),
            7
        );
        for _ in 0..20 {
            while let Ok((length, _)) = client.send(&mut packet) {
                client_socket
                    .send_to(&packet[..length], server_address)
                    .unwrap();
            }
            loop {
                let Ok((length, peer)) = server_socket.recv_from(&mut packet) else {
                    break;
                };
                let local = CString::new(server_address.to_string()).unwrap();
                let remote = CString::new(peer.to_string()).unwrap();
                assert_eq!(
                    unsafe {
                        super::net_quic_server_recv(
                            server,
                            packet.as_mut_ptr(),
                            length,
                            local.as_ptr(),
                            remote.as_ptr(),
                        )
                    },
                    1
                );
            }
            loop {
                let mut destination = [0 as c_char; 64];
                let mut send_delay_ns = u64::MAX;
                let length = unsafe {
                    super::net_quic_server_send(
                        server,
                        packet.as_mut_ptr(),
                        packet.len(),
                        destination.as_mut_ptr(),
                        destination.len(),
                        &mut send_delay_ns,
                    )
                };
                if length <= 0 {
                    break;
                }
                assert_ne!(send_delay_ns, u64::MAX);
                std::thread::sleep(Duration::from_nanos(send_delay_ns));
                let destination = unsafe { CStr::from_ptr(destination.as_ptr()) }
                    .to_str()
                    .unwrap()
                    .parse::<SocketAddr>()
                    .unwrap();
                server_socket
                    .send_to(&packet[..length as usize], destination)
                    .unwrap();
            }
            loop {
                let Ok((length, peer)) = client_socket.recv_from(&mut packet) else {
                    break;
                };
                client
                    .recv(
                        &mut packet[..length],
                        RecvInfo {
                            from: peer,
                            to: client_address,
                        },
                    )
                    .unwrap();
                while client_h3.poll(&mut client).is_ok() {}
            }
            if unsafe { &*server }._inner.requests.len() > 0 {
                break;
            }
        }
        let server_state = unsafe { &mut *server };
        assert!(
            server_state
                ._inner
                .connections
                .values()
                .all(|connection| { connection.http3.is_some() })
        );
        let request = server_state._inner.requests.front().unwrap();
        assert_eq!(request.stream_id, request_stream_id);
        assert_eq!(request.method, b"POST");
        assert_eq!(request.target, b"/items?q=1");
        assert_eq!(request.scheme, b"https");
        assert_eq!(request.authority, b"localhost");
        assert_eq!(
            request.headers,
            vec![
                (b"x-test".to_vec(), b"provider".to_vec()),
                (b"x-test".to_vec(), b"duplicate".to_vec()),
                (b"content-length".to_vec(), b"7".to_vec()),
            ]
        );
        assert_eq!(request.body, b"payload");
        assert_eq!(
            server_state._inner.buffered_request_bytes,
            completed_request_retained_bytes(request)
        );
        let mut request_record = vec![0; 1_200_000];
        let request_record_length = unsafe {
            super::net_quic_server_next_request(
                server,
                request_record.as_mut_ptr(),
                request_record.len(),
            )
        };
        assert!(request_record_length > 0);
        assert_eq!(server_state._inner.buffered_request_bytes, 0);
        assert!(
            request_record[..request_record_length as usize]
                .windows(b"/items?q=1".len())
                .any(|window| window == b"/items?q=1")
        );
        assert_eq!(
            unsafe {
                super::net_quic_server_next_request(
                    server,
                    request_record.as_mut_ptr(),
                    request_record.len(),
                )
            },
            0
        );
        let request_id = u64::from_be_bytes(request_record[0..8].try_into().unwrap());
        let mut response_headers = Vec::new();
        append_u32(&mut response_headers, 1);
        append_bytes(&mut response_headers, b"content-type");
        append_bytes(&mut response_headers, b"text/plain");
        let response_body = b"hello";
        assert_eq!(
            unsafe {
                super::net_quic_server_respond(
                    server,
                    request_id,
                    200,
                    response_headers.as_ptr(),
                    response_headers.len(),
                    response_body.as_ptr(),
                    response_body.len(),
                )
            },
            1
        );
        assert_eq!(
            server_state._inner.buffered_response_bytes,
            response_body.len()
                + b":status".len()
                + 3
                + b"content-type".len()
                + b"text/plain".len()
        );
        let mut received_status = None;
        let mut received_body = Vec::new();
        for _ in 0..10 {
            loop {
                let mut destination = [0 as c_char; 64];
                let mut send_delay_ns = u64::MAX;
                let length = unsafe {
                    super::net_quic_server_send(
                        server,
                        packet.as_mut_ptr(),
                        packet.len(),
                        destination.as_mut_ptr(),
                        destination.len(),
                        &mut send_delay_ns,
                    )
                };
                if length <= 0 {
                    break;
                }
                assert_ne!(send_delay_ns, u64::MAX);
                std::thread::sleep(Duration::from_nanos(send_delay_ns));
                let destination = unsafe { CStr::from_ptr(destination.as_ptr()) }
                    .to_str()
                    .unwrap()
                    .parse::<SocketAddr>()
                    .unwrap();
                server_socket
                    .send_to(&packet[..length as usize], destination)
                    .unwrap();
            }
            loop {
                let Ok((length, peer)) = client_socket.recv_from(&mut packet) else {
                    break;
                };
                client
                    .recv(
                        &mut packet[..length],
                        RecvInfo {
                            from: peer,
                            to: client_address,
                        },
                    )
                    .unwrap();
                loop {
                    match client_h3.poll(&mut client) {
                        Ok((_, quiche::h3::Event::Headers { list, .. })) => {
                            for header in list {
                                if header.name() == b":status" {
                                    received_status = Some(header.value().to_vec());
                                }
                            }
                        }
                        Ok((stream_id, quiche::h3::Event::Data)) => {
                            let mut body = [0; 1024];
                            while let Ok(length) =
                                client_h3.recv_body(&mut client, stream_id, &mut body)
                            {
                                received_body.extend_from_slice(&body[..length]);
                            }
                        }
                        Ok(_) => (),
                        Err(quiche::h3::Error::Done) => break,
                        Err(error) => panic!("HTTP/3 client poll failed: {error:?}"),
                    }
                }
            }
            if received_body == response_body {
                break;
            }
        }
        assert_eq!(received_status.as_deref(), Some(&b"200"[..]));
        assert_eq!(received_body, response_body);
        assert_eq!(server_state._inner.buffered_response_bytes, 0);
        assert_ne!(
            unsafe { super::net_quic_server_timeout_micros(server) },
            u64::MAX
        );

        let pending_headers = [
            quiche::h3::Header::new(b":method", b"GET"),
            quiche::h3::Header::new(b":scheme", b"https"),
            quiche::h3::Header::new(b":authority", b"localhost"),
            quiche::h3::Header::new(b":path", b"/pending"),
        ];
        client_h3
            .send_request(&mut client, &pending_headers, true)
            .unwrap();
        while let Ok((length, _)) = client.send(&mut packet) {
            client_socket
                .send_to(&packet[..length], server_address)
                .unwrap();
        }
        loop {
            let (length, peer) = server_socket.recv_from(&mut packet).unwrap();
            let local = CString::new(server_address.to_string()).unwrap();
            let remote = CString::new(peer.to_string()).unwrap();
            assert_eq!(
                unsafe {
                    super::net_quic_server_recv(
                        server,
                        packet.as_mut_ptr(),
                        length,
                        local.as_ptr(),
                        remote.as_ptr(),
                    )
                },
                1
            );
            if unsafe { &*server }._inner.requests.len() > 0 {
                break;
            }
        }

        assert_eq!(unsafe { super::net_quic_server_begin_shutdown(server) }, 1);
        let mut received_goaway = false;
        for _ in 0..20 {
            loop {
                let mut destination = [0 as c_char; 64];
                let mut send_delay_ns = u64::MAX;
                let length = unsafe {
                    super::net_quic_server_send(
                        server,
                        packet.as_mut_ptr(),
                        packet.len(),
                        destination.as_mut_ptr(),
                        destination.len(),
                        &mut send_delay_ns,
                    )
                };
                if length <= 0 {
                    break;
                }
                assert_ne!(send_delay_ns, u64::MAX);
                std::thread::sleep(Duration::from_nanos(send_delay_ns));
                let destination = unsafe { CStr::from_ptr(destination.as_ptr()) }
                    .to_str()
                    .unwrap()
                    .parse::<SocketAddr>()
                    .unwrap();
                server_socket
                    .send_to(&packet[..length as usize], destination)
                    .unwrap();
            }
            if let Ok((length, peer)) = client_socket.recv_from(&mut packet) {
                client
                    .recv(
                        &mut packet[..length],
                        RecvInfo {
                            from: peer,
                            to: client_address,
                        },
                    )
                    .unwrap();
                loop {
                    match client_h3.poll(&mut client) {
                        Ok((_, quiche::h3::Event::GoAway)) => {
                            received_goaway = true;
                            break;
                        }
                        Ok(_) => (),
                        Err(quiche::h3::Error::Done) => break,
                        Err(error) => panic!("HTTP/3 client poll failed: {error:?}"),
                    }
                }
            }
            if received_goaway {
                break;
            }
        }
        assert!(received_goaway);

        let connection_key = {
            let server_state = unsafe { &mut *server };
            assert_eq!(server_state._inner.requests.len(), 1);
            assert!(server_state._inner.request_routes.len() > 0);
            server_state._inner.routes.values().next().unwrap().clone()
        };

        client.close(true, 0, b"test complete").unwrap();
        while let Ok((length, _)) = client.send(&mut packet) {
            client_socket
                .send_to(&packet[..length], server_address)
                .unwrap();
        }
        let (length, peer) = server_socket.recv_from(&mut packet).unwrap();
        let local = CString::new(server_address.to_string()).unwrap();
        let remote = CString::new(peer.to_string()).unwrap();
        assert_eq!(
            unsafe {
                super::net_quic_server_recv(
                    server,
                    packet.as_mut_ptr(),
                    length,
                    local.as_ptr(),
                    remote.as_ptr(),
                )
            },
            1
        );

        for _ in 0..400 {
            let timeout = unsafe { super::net_quic_server_timeout_micros(server) };
            if timeout == 0 {
                unsafe { super::net_quic_server_on_timeout(server) };
            }
            if !unsafe { &*server }
                ._inner
                .connections
                .contains_key(&connection_key)
            {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        let server_state = unsafe { &mut *server };
        assert!(server_state._inner.connections.is_empty());
        assert!(server_state._inner.routes.is_empty());
        assert!(server_state._inner.request_routes.is_empty());
        assert!(server_state._inner.requests.is_empty());
        unsafe {
            net_quic_server_free(server);
            super::net_quic_server_config_free(config);
        }
    }

    #[test]
    fn refuses_new_quic_connections_at_the_configured_limit() {
        let certificate_path = std::env::var("NET_HTTP_TEST_CERT").unwrap();
        let private_key_path = std::env::var("NET_HTTP_TEST_KEY").unwrap();
        let mut server_config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        server_config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        server_config
            .load_cert_chain_from_pem_file(&certificate_path)
            .unwrap();
        server_config
            .load_priv_key_from_pem_file(&private_key_path)
            .unwrap();
        let mut server = super::QuicServer::new(server_config).unwrap();
        server.max_connections = 1;

        let local = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 4433);
        let mut packet = [0; 65535];
        let mut first_config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        first_config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        first_config.verify_peer(false);
        let first_address = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 54321);
        let first_scid = [0x61; 16];
        let mut first_client = quiche::connect(
            Some("localhost"),
            &ConnectionId::from_ref(&first_scid),
            first_address,
            local,
            &mut first_config,
        )
        .unwrap();
        let (first_length, _) = first_client.send(&mut packet).unwrap();
        let first_dcid = Header::from_slice(&mut packet[..first_length], 16)
            .unwrap()
            .dcid
            .as_ref()
            .to_vec();
        server
            .recv_datagram(&mut packet[..first_length], local, first_address)
            .unwrap();
        assert_eq!(server.connections.len(), 1);
        assert!(server.routes.contains_key(&first_dcid));

        let mut second_config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        second_config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        second_config.verify_peer(false);
        let second_address = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 54322);
        let second_scid = [0x62; 16];
        let mut second_client = quiche::connect(
            Some("localhost"),
            &ConnectionId::from_ref(&second_scid),
            second_address,
            local,
            &mut second_config,
        )
        .unwrap();
        let (second_length, _) = second_client.send(&mut packet).unwrap();
        let second_dcid = Header::from_slice(&mut packet[..second_length], 16)
            .unwrap()
            .dcid
            .as_ref()
            .to_vec();
        assert!(matches!(
            server.recv_datagram(&mut packet[..second_length], local, second_address),
            Err(super::QuicServerError::Quiche(quiche::Error::Done))
        ));
        assert_eq!(server.connections.len(), 1);
        assert!(!server.routes.contains_key(&second_dcid));
    }

    fn stress_server_config() -> quiche::Config {
        let certificate_path = std::env::var("NET_HTTP_TEST_CERT").unwrap();
        let private_key_path = std::env::var("NET_HTTP_TEST_KEY").unwrap();
        let mut server_config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        server_config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        server_config
            .load_cert_chain_from_pem_file(&certificate_path)
            .unwrap();
        server_config
            .load_priv_key_from_pem_file(&private_key_path)
            .unwrap();
        super::apply_provider_quic_transport_settings(&mut server_config);
        server_config
    }

    fn stress_client_config() -> quiche::Config {
        let mut client_config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        client_config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        client_config.verify_peer(false);
        super::apply_provider_quic_transport_settings(&mut client_config);
        client_config
    }

    fn collect_client_datagrams(
        client: &mut quiche::Connection,
        packet: &mut [u8],
    ) -> Vec<Vec<u8>> {
        let mut datagrams = Vec::new();
        while let Ok((length, _)) = client.send(packet) {
            datagrams.push(packet[..length].to_vec());
        }
        datagrams
    }

    fn deliver_client_datagram(
        server: &mut super::QuicServer,
        datagram: &[u8],
        local: SocketAddr,
        remote: SocketAddr,
    ) {
        let mut packet = datagram.to_vec();
        match server.recv_datagram(&mut packet, local, remote) {
            Ok(()) => {}
            // Duplicate / out-of-order packets may be ignored by quiche.
            Err(super::QuicServerError::Quiche(quiche::Error::Done)) => {}
            Err(error) => panic!("unexpected recv_datagram error: {error:?}"),
        }
    }

    fn flush_server_to_client(
        client: &mut quiche::Connection,
        server: &mut super::QuicServer,
        packet: &mut [u8],
        client_address: SocketAddr,
    ) {
        while let Ok(Some((length, info))) = server.send(packet) {
            let _ = client.recv(
                &mut packet[..length],
                RecvInfo {
                    from: info.from,
                    to: client_address,
                },
            );
        }
    }

    fn drive_timeouts(client: &mut quiche::Connection, server: &mut super::QuicServer) {
        if client.timeout().is_some_and(|timeout| timeout.is_zero()) {
            client.on_timeout();
        }
        if server.timeout().is_some_and(|timeout| timeout.is_zero()) {
            server.on_timeout();
        }
    }

    fn pump_in_memory(
        client: &mut quiche::Connection,
        server: &mut super::QuicServer,
        packet: &mut [u8],
        local: SocketAddr,
        remote: SocketAddr,
        reorder_first_pair: bool,
        duplicate: bool,
    ) {
        drive_timeouts(client, server);
        let mut datagrams = collect_client_datagrams(client, packet);
        if reorder_first_pair && datagrams.len() >= 2 {
            datagrams.swap(0, 1);
        }
        for datagram in &datagrams {
            deliver_client_datagram(server, datagram, local, remote);
            if duplicate {
                deliver_client_datagram(server, datagram, local, remote);
            }
        }
        flush_server_to_client(client, server, packet, remote);
    }

    fn establish_http3_in_memory(
        client: &mut quiche::Connection,
        server: &mut super::QuicServer,
        packet: &mut [u8],
        local: SocketAddr,
        remote: SocketAddr,
        reorder_handshake: bool,
    ) {
        // Handshake phase exercises packet-loss recovery: single-datagram
        // lockstep flights cannot be swapped in-round, and holding one
        // across rounds deadlocks the handshake, so drop the first server
        // flight once to force timeout-driven recovery. Real reorder
        // evidence comes from the 1-RTT large-body swap below.
        let mut dropped_once = false;
        for _ in 0..64 {
            drive_timeouts(client, server);
            let datagrams = collect_client_datagrams(client, packet);
            for datagram in &datagrams {
                deliver_client_datagram(server, datagram, local, remote);
            }
            if reorder_handshake {
                // Drop the first server flight once; timeouts must recover.
                // Swap in-round when a flight spans several datagrams.
                let mut cur = Vec::new();
                while let Ok(Some((length, _))) = server.send(packet) {
                    cur.push(packet[..length].to_vec());
                }
                if !dropped_once && !cur.is_empty() {
                    dropped_once = true;
                    // Hold one datagram back to force retransmit timers;
                    // deliver the rest (if any) out of order.
                    if cur.len() >= 2 {
                        cur.swap(0, 1);
                    }
                    cur.remove(0);
                } else if cur.len() >= 2 {
                    cur.swap(0, 1);
                }
                for datagram in &cur {
                    let mut owned = datagram.clone();
                    let _ = client.recv(
                        &mut owned,
                        RecvInfo {
                            from: local,
                            to: remote,
                        },
                    );
                }
            } else {
                flush_server_to_client(client, server, packet, remote);
            }
            if client.is_established()
                && server
                    .connections
                    .values()
                    .any(|connection| connection.transport.is_established())
            {
                break;
            }
            // Loss/reorder recovery is timer-driven; advance when quiche asks.
            if let Some(timeout) = client.timeout().filter(|timeout| !timeout.is_zero()) {
                std::thread::sleep(timeout.min(Duration::from_millis(25)));
            } else if let Some(timeout) = server.timeout().filter(|timeout| !timeout.is_zero()) {
                std::thread::sleep(timeout.min(Duration::from_millis(25)));
            }
        }
        if reorder_handshake {
            assert!(
                dropped_once,
                "reorder test never dropped a handshake flight"
            );
        }
        assert!(
            client.is_established(),
            "client failed to establish under stress"
        );
    }

    fn complete_post_request_in_memory(
        client: &mut quiche::Connection,
        server: &mut super::QuicServer,
        packet: &mut [u8],
        local: SocketAddr,
        remote: SocketAddr,
        duplicate_request_datagrams: bool,
        reorder_request_datagrams: bool,
    ) -> super::CompletedRequest {
        let mut client_h3 = quiche::h3::Connection::with_transport(
            client,
            &quiche::h3::Config::new().unwrap(),
        )
        .unwrap();
        // Reorder case needs multiple datagrams per round to actually swap;
        // use a larger body so 1-RTT data spans several QUIC datagrams.
        let body: Vec<u8> = if reorder_request_datagrams {
            vec![0x41; 32 * 1024]
        } else {
            b"ping".to_vec()
        };
        let content_length = body.len().to_string();
        let request_headers = [
            quiche::h3::Header::new(b":method", b"POST"),
            quiche::h3::Header::new(b":scheme", b"https"),
            quiche::h3::Header::new(b":authority", b"localhost"),
            quiche::h3::Header::new(b":path", b"/stress"),
            quiche::h3::Header::new(b"content-length", content_length.as_bytes()),
        ];
        let stream_id = client_h3
            .send_request(client, &request_headers, false)
            .unwrap();
        let mut sent = 0;
        // Send what fits now; remainder is streamed inside the pump loop
        // as flow control opens (large reorder body would otherwise hit
        // Done immediately).
        while sent < body.len() {
            let end = (sent + 4096).min(body.len());
            let fin = end == body.len();
            match client_h3.send_body(client, stream_id, &body[sent..end], fin) {
                Ok(wrote) => {
                    sent += wrote;
                    if wrote == 0 || fin {
                        break;
                    }
                }
                Err(quiche::h3::Error::Done) => break,
                Err(e) => panic!("unexpected send_body error: {e:?}"),
            }
        }

        let mut swapped = false;
        let mut carry: Option<Vec<u8>> = None;
        for _ in 0..64 {
            drive_timeouts(client, server);
            // Stream remaining request body as credit allows.
            while sent < body.len() {
                let end = (sent + 4096).min(body.len());
                let fin = end == body.len();
                match client_h3.send_body(client, stream_id, &body[sent..end], fin)
                {
                    Ok(wrote) => {
                        sent += wrote;
                        if wrote == 0 {
                            break;
                        }
                        if fin && sent >= body.len() {
                            break;
                        }
                    }
                    Err(quiche::h3::Error::Done) => break,
                    Err(e) => panic!("unexpected send_body error: {e:?}"),
                }
            }
            let mut datagrams = collect_client_datagrams(client, packet);
            if let Some(stashed) = carry.take() {
                datagrams.insert(0, stashed);
            }
            if reorder_request_datagrams {
                if datagrams.len() >= 2 {
                    datagrams.swap(0, 1);
                    swapped = true;
                } else if datagrams.len() == 1 {
                    carry = datagrams.pop();
                }
            }
            for datagram in &datagrams {
                deliver_client_datagram(server, datagram, local, remote);
                if duplicate_request_datagrams {
                    deliver_client_datagram(server, datagram, local, remote);
                }
            }
            flush_server_to_client(client, server, packet, remote);
            while client_h3.poll(client).is_ok() {}
            if !server.requests.is_empty() {
                break;
            }
            if let Some(timeout) = client.timeout().filter(|timeout| !timeout.is_zero()) {
                std::thread::sleep(timeout.min(Duration::from_millis(25)));
            } else if let Some(timeout) = server.timeout().filter(|timeout| !timeout.is_zero()) {
                std::thread::sleep(timeout.min(Duration::from_millis(25)));
            }
        }
        if let Some(stashed) = carry.take() {
            deliver_client_datagram(server, &stashed, local, remote);
            for _ in 0..16 {
                drive_timeouts(client, server);
                for datagram in collect_client_datagrams(client, packet) {
                    deliver_client_datagram(server, &datagram, local, remote);
                }
                flush_server_to_client(client, server, packet, remote);
                if !server.requests.is_empty() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        if reorder_request_datagrams {
            assert!(
                swapped,
                "reorder test never swapped 1-RTT datagrams"
            );
        }

        server
            .next_request()
            .expect("HTTP/3 request should complete under packet stress")
    }

    enum Cancellation {
        PeerReset,
        IncompleteDataReset,
        BodyTimeout,
    }

    struct H3ResetFixture {
        server: super::QuicServer,
        client: quiche::Connection,
        http3: quiche::h3::Connection,
        packet: [u8; 65535],
        local: SocketAddr,
        remote: SocketAddr,
    }

    impl H3ResetFixture {
        fn new() -> Self {
            let mut server = super::QuicServer::new(stress_server_config()).unwrap();
            let local = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 4433);
            let remote = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 54321);
            let mut config = stress_client_config();
            let mut client = quiche::connect(
                Some("localhost"),
                &ConnectionId::from_ref(&[0x73; 16]),
                remote,
                local,
                &mut config,
            )
            .unwrap();
            let mut packet = [0; 65535];
            establish_http3_in_memory(&mut client, &mut server, &mut packet, local, remote, false);
            let http3 = quiche::h3::Connection::with_transport(
                &mut client,
                &quiche::h3::Config::new().unwrap(),
            )
            .unwrap();
            Self {
                server,
                client,
                http3,
                packet,
                local,
                remote,
            }
        }

        fn pump_until(&mut self, ready: impl Fn(&super::QuicServer) -> bool) {
            for _ in 0..64 {
                pump_in_memory(
                    &mut self.client,
                    &mut self.server,
                    &mut self.packet,
                    self.local,
                    self.remote,
                    false,
                    false,
                );
                while self.http3.poll(&mut self.client).is_ok() {}
                if ready(&self.server) {
                    return;
                }
                std::thread::sleep(Duration::from_millis(2));
            }
            panic!("HTTP/3 fixture did not reach the expected request state");
        }

        fn headers(padding: &[u8]) -> [quiche::h3::Header; 6] {
            [
                quiche::h3::Header::new(b":method", b"POST"),
                quiche::h3::Header::new(b":scheme", b"https"),
                quiche::h3::Header::new(b":authority", b"localhost"),
                quiche::h3::Header::new(b":path", b"/echo"),
                quiche::h3::Header::new(b"content-length", b"8"),
                quiche::h3::Header::new(b"x-retained", padding),
            ]
        }

        fn churn(&mut self, cycles: usize, padding_bytes: usize, method: Cancellation) {
            let padding = vec![b'x'; padding_bytes];
            let headers = Self::headers(&padding);
            for _ in 0..cycles {
                let id = self
                    .http3
                    .send_request(&mut self.client, &headers, false)
                    .expect("cancelled streams must return credit for new requests");
                match method {
                    Cancellation::IncompleteDataReset => {
                        self.client.stream_send(id, b"\x00\x08ping", false).unwrap();
                    }
                    _ => {
                        self.http3
                            .send_body(&mut self.client, id, b"ping", false)
                            .unwrap();
                    }
                }
                self.pump_until(|server| {
                    server
                        .connections
                        .values()
                        .any(|c| c.requests.get(&id).is_some_and(|r| r.body == b"ping"))
                });
                match method {
                    Cancellation::BodyTimeout => {
                        let connection = self.server.connections.values_mut().next().unwrap();
                        connection.requests.get_mut(&id).unwrap().body_deadline_at =
                            Some(std::time::Instant::now());
                        let key = self.server.connections.keys().next().unwrap().clone();
                        self.server.refresh_request_timeout(&key, id);
                        self.server.expire_incomplete_requests();
                    }
                    _ => {
                        self.client
                            .stream_shutdown(id, quiche::Shutdown::Write, 0x10c)
                            .unwrap();
                    }
                }
                self.pump_until(|server| {
                    server
                        .connections
                        .values()
                        .all(|c| !c.requests.contains_key(&id))
                });
                assert_eq!(self.server.connections.len(), 1);
                assert_eq!(self.server.buffered_request_bytes, 0);
                assert!(self.server.requests.is_empty());
            }
        }

        fn probe(&mut self) {
            let id = self
                .http3
                .send_request(&mut self.client, &Self::headers(&[]), false)
                .expect("a full request must remain usable after cancellation churn");
            self.http3
                .send_body(&mut self.client, id, b"complete", true)
                .unwrap();
            self.pump_until(|server| !server.requests.is_empty());
            assert_eq!(self.server.next_request().unwrap().body, b"complete");
        }

        fn complete_requests(&mut self, cycles: usize) {
            let mut last_id = 0;
            for _ in 0..cycles {
                let id = self
                    .http3
                    .send_request(&mut self.client, &Self::headers(&[]), false)
                    .unwrap();
                self.http3
                    .send_body(&mut self.client, id, b"complete", true)
                    .unwrap();
                self.pump_until(|server| !server.requests.is_empty());
                let request = self.server.next_request().unwrap();
                assert_eq!(request.body, b"complete");
                assert!(self.server.enqueue_response(
                    request.id,
                    200,
                    Vec::new(),
                    b"response".to_vec()
                ));
                self.pump_until(|server| {
                    server.connections.values().all(|c| c.responses.is_empty())
                });
                let mut body = [0; 8];
                assert_eq!(self.http3.recv_body(&mut self.client, id, &mut body), Ok(8));
                assert_eq!(&body, b"response");
                while self.http3.poll(&mut self.client).is_ok() {}
                assert_eq!(self.server.buffered_request_bytes, 0);
                assert_eq!(self.server.buffered_response_bytes, 0);
                last_id = id;
            }
            self.pump_until(|server| {
                server
                    .connections
                    .values()
                    .all(|c| c.transport.stream_closed(last_id))
            });
        }

        fn retained_transport_bytes(&mut self) -> isize {
            let key = self.server.connections.keys().next().unwrap().clone();
            let mut connection = self.server.connections.remove(&key).unwrap();
            drop(connection.http3.take());
            let before_drop = super::allocation_probe::live();
            drop(connection.transport);
            before_drop - super::allocation_probe::live()
        }

        fn retained_engine_bytes(&mut self) -> isize {
            let http3 = self
                .server
                .connections
                .values_mut()
                .next()
                .unwrap()
                .http3
                .take()
                .unwrap();
            let before_drop = super::allocation_probe::live();
            drop(http3);
            before_drop - super::allocation_probe::live()
        }
    }

    fn transport_retention_after_churn(cycles: usize, reset: bool) -> isize {
        let mut fixture = H3ResetFixture::new();
        if reset {
            fixture.churn(cycles, 0, Cancellation::PeerReset);
        } else {
            fixture.complete_requests(cycles);
        }
        fixture.probe();
        fixture.retained_transport_bytes()
    }

    fn assert_transport_retention_stable(reset: bool) {
        let after_10k = transport_retention_after_churn(10_000, reset);
        let after_50k = transport_retention_after_churn(50_000, reset);
        eprintln!(
            "server transport Rust allocations reset={reset}: 10000={after_10k} bytes, 50000={after_50k} bytes"
        );
        assert!(
            after_50k <= after_10k + 64 * 1024,
            "collected streams retained growing transport allocations: {after_10k} -> {after_50k} bytes"
        );
    }

    #[test]
    fn collected_reset_streams_keep_transport_allocations_stable() {
        assert_transport_retention_stable(true);
    }

    #[test]
    fn collected_completed_streams_keep_transport_allocations_stable() {
        assert_transport_retention_stable(false);
    }

    fn unknown_uni_retained_bytes(cycles: usize, fin: bool) -> isize {
        let mut server =
            super::QuicServer::new(stress_server_config()).unwrap();
        let local = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 4433);
        let remote = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 54321);
        let mut config = stress_client_config();
        let mut client = quiche::connect(
            Some("localhost"),
            &ConnectionId::from_ref(&[0x73; 16]),
            remote,
            local,
            &mut config,
        )
        .unwrap();
        let mut packet = [0; 65535];
        establish_http3_in_memory(
            &mut client,
            &mut server,
            &mut packet,
            local,
            remote,
            false,
        );
        client.stream_send(2, b"\x00\x04\x00", false).unwrap();
        for _ in 0..4 {
            pump_in_memory(
                &mut client,
                &mut server,
                &mut packet,
                local,
                remote,
                false,
                false,
            );
        }
        assert_eq!(client.peer_streams_left_uni(), 2);
        for index in 1..=cycles {
            let id = 2 + (index as u64) * 4;
            client.stream_send(id, b"\x21hello", fin).unwrap();
            let mut returned = false;
            for _ in 0..64 {
                pump_in_memory(
                    &mut client,
                    &mut server,
                    &mut packet,
                    local,
                    remote,
                    false,
                    false,
                );
                if client.peer_streams_left_uni() == 2 {
                    returned = true;
                    break;
                }
                std::thread::sleep(Duration::from_millis(2));
            }
            assert!(
                returned,
                "unknown uni {id} failed to return MAX_STREAMS credit"
            );
            assert_eq!(server.connections.len(), 1);
            assert_eq!(server.buffered_request_bytes, 0);
        }
        assert_eq!(client.peer_streams_left_uni(), 2);
        client
            .stream_send(
                0,
                b"\x01\x10\x00\x00\xd1\xd7\xc1\x50\x09localhost",
                true,
            )
            .unwrap();
        for _ in 0..64 {
            pump_in_memory(
                &mut client,
                &mut server,
                &mut packet,
                local,
                remote,
                false,
                false,
            );
            if !server.requests.is_empty() {
                break;
            }
        }
        let request = server
            .next_request()
            .expect("valid static-QPACK request must remain usable");
        assert_eq!(request.method, b"GET");
        assert_eq!(request.authority, b"localhost");
        assert_eq!(request.target, b"/");
        let http3 = server
            .connections
            .values_mut()
            .next()
            .unwrap()
            .http3
            .take()
            .unwrap();
        let before = super::allocation_probe::live();
        drop(http3);
        let retained = before - super::allocation_probe::live();
        eprintln!("unknown uni churn={cycles} fin={fin} retained server H3 Rust bytes={retained} remaining_uni_credit=2 valid_GET_after_churn=true");
        retained
    }

    #[test]
    fn unknown_fin_streams_return_credit_and_release_h3_state() {
        let retained = unknown_uni_retained_bytes(10_000, true);
        assert!(
            retained < 64 * 1024,
            "retained unknown FIN stream state: {retained}"
        );
    }

    #[test]
    fn unknown_reset_streams_return_credit_and_release_h3_state() {
        let retained = unknown_uni_retained_bytes(10_000, false);
        assert!(
            retained < 64 * 1024,
            "retained unknown reset stream state: {retained}"
        );
    }

    #[test]
    fn cancelled_request_streams_return_bidirectional_credit() {
        let mut fixture = H3ResetFixture::new();
        fixture.churn(105, 0, Cancellation::PeerReset);
        fixture.probe();
    }

    #[test]
    fn cancellation_churn_releases_http3_engine_allocations() {
        let mut fixture = H3ResetFixture::new();
        fixture.churn(10_000, 4096, Cancellation::PeerReset);
        let retained = fixture.retained_engine_bytes();
        eprintln!("10000 cancellations: retained server H3 Rust allocations {retained} bytes");
        assert!(
            retained <= 64 * 1024,
            "HTTP/3 state retained {retained} bytes after cancelled requests"
        );
    }

    #[test]
    fn reset_during_incomplete_data_frame_keeps_connection_usable() {
        let mut fixture = H3ResetFixture::new();
        fixture.churn(1, 0, Cancellation::IncompleteDataReset);
        fixture.probe();
    }

    #[test]
    fn body_timeout_releases_http3_engine_allocations() {
        let mut fixture = H3ResetFixture::new();
        fixture.churn(1000, 4096, Cancellation::BodyTimeout);
        let retained = fixture.retained_engine_bytes();
        assert!(
            retained <= 64 * 1024,
            "HTTP/3 state retained {retained} bytes after body timeouts"
        );
    }

    #[test]
    fn incomplete_field_section_timeout_releases_http3_engine_allocations() {
        let mut fixture = H3ResetFixture::new();
        for index in 1..=1000 {
            let id = index * 4;
            fixture
                .client
                .stream_send(id, b"\x01\x40\x80\x00", false)
                .unwrap();
            fixture.pump_until(|server| {
                server
                    .connections
                    .values()
                    .any(|c| c.header_deadlines.contains_key(&id))
            });
            let connection = fixture.server.connections.values_mut().next().unwrap();
            connection
                .header_deadlines
                .insert(id, std::time::Instant::now());
            let key = fixture.server.connections.keys().next().unwrap().clone();
            fixture.server.refresh_request_timeout(&key, id);
            fixture.server.expire_incomplete_requests();
            fixture.pump_until(|server| {
                server
                    .connections
                    .values()
                    .all(|c| !c.header_deadlines.contains_key(&id))
            });
            assert_eq!(fixture.server.buffered_request_bytes, 0);
        }
        fixture.probe();
        let retained = fixture.retained_engine_bytes();
        assert!(
            retained <= 64 * 1024,
            "HTTP/3 state retained {retained} bytes after partial field timeouts"
        );
    }
    #[test]
    fn response_timeout_releases_http3_engine_allocations() {
        let mut fixture = H3ResetFixture::new();
        let headers = H3ResetFixture::headers(&vec![b'x'; 4096]);
        for _ in 0..1000 {
            let id = fixture
                .http3
                .send_request(&mut fixture.client, &headers, false)
                .unwrap();
            fixture
                .http3
                .send_body(&mut fixture.client, id, b"complete", true)
                .unwrap();
            fixture.pump_until(|server| !server.requests.is_empty());
            let request = fixture.server.next_request().unwrap();
            assert!(
                fixture
                    .server
                    .enqueue_response(request.id, 200, Vec::new(), vec![0; 32])
            );
            let key = fixture.server.connections.keys().next().unwrap().clone();
            fixture.server.remove_response_timeout(&key, id);
            fixture
                .server
                .connections
                .get_mut(&key)
                .unwrap()
                .responses
                .get_mut(&id)
                .unwrap()
                .write_deadline_at = std::time::Instant::now();
            fixture.server.index_response_timeout(&key, id);
            fixture.server.expire_responses();
            fixture.pump_until(|server| {
                server
                    .connections
                    .values()
                    .all(|c| !c.responses.contains_key(&id))
            });
            assert_eq!(fixture.server.buffered_response_bytes, 0);
            assert_eq!(fixture.server.buffered_request_bytes, 0);
        }
        fixture.probe();
        let retained = fixture.retained_engine_bytes();
        assert!(
            retained <= 64 * 1024,
            "HTTP/3 state retained {retained} bytes after response timeouts"
        );
    }

    #[test]
    fn cancellation_api_is_idempotent_and_preserves_critical_streams() {
        let mut fixture = H3ResetFixture::new();
        fixture.churn(1, 0, Cancellation::PeerReset);
        let connection = fixture.server.connections.values_mut().next().unwrap();
        let http3 = connection.http3.as_mut().unwrap();
        assert_eq!(
            http3.cancel_request(&mut connection.transport, 0, 0x10c),
            Ok(())
        );
        assert_eq!(
            http3.cancel_request(&mut connection.transport, 0, 0x10c),
            Ok(())
        );
        assert_eq!(
            http3.cancel_request(&mut connection.transport, 2, 0x10c),
            Err(quiche::h3::Error::FrameUnexpected)
        );
        assert_eq!(
            http3.cancel_request(&mut connection.transport, 4, 0x10c),
            Err(quiche::h3::Error::TransportError(
                quiche::Error::InvalidStreamState(4)
            ))
        );
        fixture.probe();
    }

    #[test]
    fn tolerates_duplicate_client_datagrams_and_completes_request() {
        let mut server = super::QuicServer::new(stress_server_config()).unwrap();
        let local = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 4433);
        let remote = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 54321);
        let mut client_config = stress_client_config();
        let client_scid = [0x71; 16];
        let mut client = quiche::connect(
            Some("localhost"),
            &ConnectionId::from_ref(&client_scid),
            remote,
            local,
            &mut client_config,
        )
        .unwrap();
        let mut packet = [0; 65535];

        establish_http3_in_memory(&mut client, &mut server, &mut packet, local, remote, false);
        assert!(client.is_established());

        let request = complete_post_request_in_memory(
            &mut client,
            &mut server,
            &mut packet,
            local,
            remote,
            true,
            false,
        );
        assert_eq!(request.method, b"POST");
        assert_eq!(request.target, b"/stress");
        assert_eq!(request.body, b"ping");
        assert!(!server.routes.is_empty());
        assert_eq!(server.connections.len(), 1);
    }

    #[test]
    fn recovers_from_reordered_handshake_datagrams_via_timeouts() {
        let mut server = super::QuicServer::new(stress_server_config()).unwrap();
        let local = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 4433);
        let remote = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 54322);
        let mut client_config = stress_client_config();
        let client_scid = [0x72; 16];
        let mut client = quiche::connect(
            Some("localhost"),
            &ConnectionId::from_ref(&client_scid),
            remote,
            local,
            &mut client_config,
        )
        .unwrap();
        let mut packet = [0; 65535];

        // Deliver the first flight normally so the server accepts the connection,
        // then swap subsequent consecutive client datagrams and let timers recover.
        pump_in_memory(
            &mut client,
            &mut server,
            &mut packet,
            local,
            remote,
            false,
            false,
        );
        establish_http3_in_memory(&mut client, &mut server, &mut packet, local, remote, true);
        assert!(client.is_established());
        assert!(
            server
                .connections
                .values()
                .any(|connection| connection.transport.is_established())
        );

        let request = complete_post_request_in_memory(
            &mut client,
            &mut server,
            &mut packet,
            local,
            remote,
            false,
            true,
        );
        assert_eq!(request.body.len(), 32 * 1024);
        assert!(request.body.iter().all(|b| *b == 0x41));
    }

    #[test]
    fn nat_rebinding_continues_or_cleans_cid_routes() {
        let mut server = super::QuicServer::new(stress_server_config()).unwrap();
        // Keep idle short so the timeout path finishes quickly when migration fails.
        server.idle_timeout = Duration::from_millis(150);
        server.config.set_max_idle_timeout(150);
        let local = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 4433);
        let original_remote = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 54323);
        let rebound_remote = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 54324);
        let mut client_config = stress_client_config();
        client_config.set_max_idle_timeout(150);
        let client_scid = [0x73; 16];
        let mut client = quiche::connect(
            Some("localhost"),
            &ConnectionId::from_ref(&client_scid),
            original_remote,
            local,
            &mut client_config,
        )
        .unwrap();
        let mut packet = [0; 65535];

        establish_http3_in_memory(
            &mut client,
            &mut server,
            &mut packet,
            local,
            original_remote,
            false,
        );
        assert_eq!(server.connections.len(), 1);
        let route_count_before = server.routes.len();
        assert!(route_count_before > 0);

        // Mid-connection NAT rebinding: same CIDs, new observed UDP source address.
        let mut continued = false;
        let mut client_h3 = quiche::h3::Connection::with_transport(
            &mut client,
            &quiche::h3::Config::new().unwrap(),
        )
        .unwrap();
        let request_headers = [
            quiche::h3::Header::new(b":method", b"GET"),
            quiche::h3::Header::new(b":scheme", b"https"),
            quiche::h3::Header::new(b":authority", b"localhost"),
            quiche::h3::Header::new(b":path", b"/rebind"),
        ];
        let _ = client_h3
            .send_request(&mut client, &request_headers, true)
            .unwrap();

        for _ in 0..48 {
            drive_timeouts(&mut client, &mut server);
            let datagrams = collect_client_datagrams(&mut client, &mut packet);
            for datagram in &datagrams {
                deliver_client_datagram(&mut server, datagram, local, rebound_remote);
            }
            // Only rebound-directed return traffic is usable. Packets still
            // addressed to the obsolete address are dropped (as a real NAT
            // would: that path is gone), which lets a non-migrating server
            // reach the documented timeout/cleanup branch instead of
            // failing the assertion immediately. Clients see their known
            // local (original_remote) because a quiche client discards
            // packets for an unknown local address.
            let mut server_sent_to_rebound = false;
            while let Ok(Some((length, info))) = server.send(&mut packet) {
                if info.to != rebound_remote {
                    // Obsolete destination: unreachable after rebinding.
                    continue;
                }
                server_sent_to_rebound = true;
                let _ = client.recv(
                    &mut packet[..length],
                    RecvInfo {
                        from: info.from,
                        to: original_remote,
                    },
                );
            }
            while client_h3.poll(&mut client).is_ok() {}
            if let Some(request) = server.next_request() {
                assert_eq!(request.target, b"/rebind");
                assert!(
                    client.is_established(),
                    "client must stay established after NAT rebinding"
                );
                if !server_sent_to_rebound {
                    // Server keeps using the pre-rebinding path: this is
                    // not a usable migration, so skip the response phase
                    // and let the cleanup assertions run below.
                    continue;
                }
                // Complete an application response on the rebound path.
                // Requiring response-generated datagrams to the rebound
                // address (not just ACKs/PATH_CHALLENGE) before declaring
                // the connection usable.
                assert!(
                    server.enqueue_response(
                        request.id,
                        200,
                        Vec::new(),
                        b"rebound-ok".to_vec()
                    ),
                    "server must enqueue rebound response"
                );
                let mut response_bytes_to_rebound = 0;
                let mut got_status_200 = false;
                let mut response_body = Vec::new();
                for _ in 0..48 {
                    drive_timeouts(&mut client, &mut server);
                    for datagram in collect_client_datagrams(&mut client, &mut packet) {
                        deliver_client_datagram(&mut server, &datagram, local, rebound_remote);
                    }
                    while let Ok(Some((length, info))) = server.send(&mut packet) {
                        if info.to != rebound_remote {
                            continue;
                        }
                        response_bytes_to_rebound += length;
                        // Feed the client's known local (see above) so path
                        // frames are processed and PATH_RESPONSE is emitted.
                        let _ = client.recv(
                            &mut packet[..length],
                            RecvInfo {
                                from: info.from,
                                to: original_remote,
                            },
                        );
                    }
                    // Drain client H3 events, consuming response bytes via
                    // recv_body: poll() only reports Data readability, so an
                    // unconsumed body would be reported again on the next
                    // poll instead of reaching Done.
                    loop {
                        match client_h3.poll(&mut client) {
                            Ok((id, quiche::h3::Event::Headers { list, .. })) => {
                                for header in list {
                                    if header.name() == b":status"
                                        && header.value() == b"200"
                                    {
                                        got_status_200 = true;
                                    }
                                }
                            }
                            Ok((id, quiche::h3::Event::Data)) => {
                                let mut buf = [0; 1024];
                                while let Ok(n) =
                                    client_h3.recv_body(&mut client, id, &mut buf)
                                {
                                    response_body.extend_from_slice(&buf[..n]);
                                }
                            }
                            Ok(_) => (),
                            Err(quiche::h3::Error::Done) => break,
                            Err(e) => panic!("rebound response poll failed: {e:?}"),
                        }
                    }
                    if got_status_200 && response_body == b"rebound-ok" {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(10));
                }
                // Migration is only "continued" when the application
                // response actually arrived on the rebound path; otherwise
                // fall through to the cleanup assertions below.
                if response_bytes_to_rebound > 0
                    && got_status_200
                    && response_body == b"rebound-ok"
                {
                    continued = true;
                    break;
                }
            }
            if server.connections.is_empty() {
                break;
            }
            if let Some(timeout) = client.timeout().filter(|timeout| !timeout.is_zero()) {
                std::thread::sleep(timeout.min(Duration::from_millis(40)));
            } else if let Some(timeout) = server.timeout().filter(|timeout| !timeout.is_zero()) {
                std::thread::sleep(timeout.min(Duration::from_millis(40)));
            } else {
                std::thread::sleep(Duration::from_millis(20));
            }
        }

        if continued {
            // Path accepted: the rebound request completed and the client
            // received the response on the rebound path, proving the
            // connection is routed and usable. The tight 150ms idle budget
            // in this test may retire the connection right after serving,
            // so the close handshake below must handle both cases.
            client.close(true, 0, b"done").ok();
            for _ in 0..32 {
                drive_timeouts(&mut client, &mut server);
                for datagram in collect_client_datagrams(&mut client, &mut packet) {
                    deliver_client_datagram(&mut server, &datagram, local, rebound_remote);
                }
                while let Ok(Some((length, info))) = server.send(&mut packet) {
                    let _ = client.recv(
                        &mut packet[..length],
                        RecvInfo {
                            from: info.from,
                            to: rebound_remote,
                        },
                    );
                }
                if server.connections.is_empty() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        } else {
            // No full path migration: idle / loss timers must drop CID routes.
            for _ in 0..40 {
                drive_timeouts(&mut client, &mut server);
                let _ = flush_server_to_client(&mut client, &mut server, &mut packet, original_remote);
                if server.connections.is_empty() && server.routes.is_empty() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(25));
            }
        }

        assert!(
            server.connections.is_empty(),
            "NAT rebinding must not leak connections"
        );
        assert!(
            server.routes.is_empty(),
            "NAT rebinding must not leak CID routes"
        );
        assert!(server.request_routes.is_empty());
        assert!(server.requests.is_empty());
    }

    #[test]
    fn refuses_new_quic_connections_when_transport_memory_budget_is_exhausted() {
        let certificate_path = std::env::var("NET_HTTP_TEST_CERT").unwrap();
        let private_key_path = std::env::var("NET_HTTP_TEST_KEY").unwrap();
        let mut server_config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        server_config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        server_config
            .load_cert_chain_from_pem_file(&certificate_path)
            .unwrap();
        server_config
            .load_priv_key_from_pem_file(&private_key_path)
            .unwrap();
        let mut server = super::QuicServer::new(server_config).unwrap();
        // Soft estimate: one connection fills the budget; a second Initial is refused.
        server.max_transport_memory_bytes = super::ESTIMATED_QUIC_TRANSPORT_BYTES_PER_CONNECTION;

        let local = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 4433);
        let mut packet = [0; 65535];
        let mut first_config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        first_config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        first_config.verify_peer(false);
        let first_address = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 54421);
        let first_scid = [0x71; 16];
        let mut first_client = quiche::connect(
            Some("localhost"),
            &ConnectionId::from_ref(&first_scid),
            first_address,
            local,
            &mut first_config,
        )
        .unwrap();
        let (first_length, _) = first_client.send(&mut packet).unwrap();
        server
            .recv_datagram(&mut packet[..first_length], local, first_address)
            .unwrap();
        assert_eq!(server.connections.len(), 1);
        assert_eq!(
            server.estimated_transport_memory_bytes(),
            super::ESTIMATED_QUIC_TRANSPORT_BYTES_PER_CONNECTION
        );

        let mut second_config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        second_config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        second_config.verify_peer(false);
        let second_address = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 54422);
        let second_scid = [0x72; 16];
        let mut second_client = quiche::connect(
            Some("localhost"),
            &ConnectionId::from_ref(&second_scid),
            second_address,
            local,
            &mut second_config,
        )
        .unwrap();
        let (second_length, _) = second_client.send(&mut packet).unwrap();
        let second_dcid = Header::from_slice(&mut packet[..second_length], 16)
            .unwrap()
            .dcid
            .as_ref()
            .to_vec();
        assert!(matches!(
            server.recv_datagram(&mut packet[..second_length], local, second_address),
            Err(super::QuicServerError::Quiche(quiche::Error::Done))
        ));
        assert_eq!(server.connections.len(), 1);
        assert!(!server.routes.contains_key(&second_dcid));
        assert_eq!(
            server.estimated_transport_memory_bytes(),
            super::ESTIMATED_QUIC_TRANSPORT_BYTES_PER_CONNECTION
        );

        let keys: Vec<Vec<u8>> = server.connections.keys().cloned().collect();
        for key in keys {
            server.force_drop_connection(&key);
        }
        assert!(server.connections.is_empty());
        assert!(server.routes.is_empty());
        assert!(server.request_routes.is_empty());
        assert_eq!(server.estimated_transport_memory_bytes(), 0);

        // After close, the budget frees and a new Initial is admitted.
        let mut retry_config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        retry_config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        retry_config.verify_peer(false);
        let retry_address = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 54423);
        let retry_scid = [0x73; 16];
        let mut retry_client = quiche::connect(
            Some("localhost"),
            &ConnectionId::from_ref(&retry_scid),
            retry_address,
            local,
            &mut retry_config,
        )
        .unwrap();
        let (retry_length, _) = retry_client.send(&mut packet).unwrap();
        server
            .recv_datagram(&mut packet[..retry_length], local, retry_address)
            .unwrap();
        assert_eq!(server.connections.len(), 1);
        assert_eq!(
            server.estimated_transport_memory_bytes(),
            super::ESTIMATED_QUIC_TRANSPORT_BYTES_PER_CONNECTION
        );
    }

    #[test]
    fn routes_http3_request_through_mojo_server_handler() {
        use std::collections::HashMap;
        use std::io::{BufRead, BufReader, ErrorKind};
        use std::net::UdpSocket;
        use std::process::{Command, Stdio};
        use std::time::Duration;

        let mut fixture = Command::new("mojo")
            .current_dir("../../..")
            .args([
                "run",
                "--Werror",
                "-I",
                ".",
                "tests/http3_server_fixture.mojo",
            ])
            // This test serves exactly 2 POSTs; the shared fixture defaults
            // to 5 (aioquic script) and would otherwise wait forever.
            .env("HTTP3_FIXTURE_EXPECT", "2")
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("start Mojo HTTP/3 fixture");
        let mut ready = String::new();
        BufReader::new(fixture.stdout.take().unwrap())
            .read_line(&mut ready)
            .expect("read Mojo HTTP/3 fixture address");
        let server_address: SocketAddr = ready
            .strip_prefix("READY ")
            .unwrap()
            .trim()
            .parse()
            .unwrap();

        let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
        socket
            .set_read_timeout(Some(Duration::from_millis(5)))
            .unwrap();
        let client_address = socket.local_addr().unwrap();
        let client_scid = [0x21; 16];
        let mut client_config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        client_config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        client_config.verify_peer(false);
        client_config.set_initial_max_data(10_000_000);
        client_config.set_initial_max_stream_data_bidi_local(1_000_000);
        client_config.set_initial_max_stream_data_bidi_remote(1_000_000);
        client_config.set_initial_max_stream_data_uni(1_000_000);
        client_config.set_initial_max_streams_bidi(100);
        client_config.set_initial_max_streams_uni(3);
        let mut client = quiche::connect(
            Some("localhost"),
            &ConnectionId::from_ref(&client_scid),
            client_address,
            server_address,
            &mut client_config,
        )
        .unwrap();

        let mut packet = [0; 65535];
        for _ in 0..400 {
            while let Ok((length, _)) = client.send(&mut packet) {
                socket.send_to(&packet[..length], server_address).unwrap();
            }
            match socket.recv_from(&mut packet) {
                Ok((length, peer)) => {
                    client
                        .recv(
                            &mut packet[..length],
                            RecvInfo {
                                from: peer,
                                to: client_address,
                            },
                        )
                        .unwrap();
                }
                Err(error)
                    if error.kind() == ErrorKind::WouldBlock
                        || error.kind() == ErrorKind::TimedOut =>
                {
                    ()
                }
                Err(error) => panic!("HTTP/3 client receive failed: {error}"),
            }
            if client.is_established() {
                break;
            }
        }
        assert!(client.is_established());
        assert_eq!(client.application_proto(), b"h3");

        let mut client_h3 = quiche::h3::Connection::with_transport(
            &mut client,
            &quiche::h3::Config::new().unwrap(),
        )
        .unwrap();
        let request_headers = [
            quiche::h3::Header::new(b":method", b"POST"),
            quiche::h3::Header::new(b":scheme", b"https"),
            quiche::h3::Header::new(b":authority", b"localhost"),
            quiche::h3::Header::new(b":path", b"/echo?source=quic"),
            quiche::h3::Header::new(b"content-length", b"4"),
        ];
        let first_stream_id = client_h3
            .send_request(&mut client, &request_headers, false)
            .unwrap();
        assert_eq!(
            client_h3
                .send_body(&mut client, first_stream_id, b"data", false)
                .unwrap(),
            4
        );
        client_h3
            .send_additional_headers(
                &mut client,
                first_stream_id,
                &[quiche::h3::Header::new(b"x-check", b"done")],
                true,
                true,
            )
            .unwrap();
        let second_stream_id = client_h3
            .send_request(&mut client, &request_headers, false)
            .unwrap();
        assert_eq!(
            client_h3
                .send_body(&mut client, second_stream_id, b"data", true)
                .unwrap(),
            4
        );

        let mut statuses = HashMap::new();
        let mut response_bodies = HashMap::<u64, Vec<u8>>::new();
        for _ in 0..400 {
            while let Ok((length, _)) = client.send(&mut packet) {
                socket.send_to(&packet[..length], server_address).unwrap();
            }
            loop {
                match socket.recv_from(&mut packet) {
                    Ok((length, peer)) => {
                        client
                            .recv(
                                &mut packet[..length],
                                RecvInfo {
                                    from: peer,
                                    to: client_address,
                                },
                            )
                            .unwrap();
                    }
                    Err(error)
                        if error.kind() == ErrorKind::WouldBlock
                            || error.kind() == ErrorKind::TimedOut =>
                    {
                        break;
                    }
                    Err(error) => panic!("HTTP/3 client receive failed: {error}"),
                }
            }
            loop {
                match client_h3.poll(&mut client) {
                    Ok((id, quiche::h3::Event::Headers { list, .. })) => {
                        for header in list {
                            if header.name() == b":status" {
                                statuses.insert(id, header.value().to_vec());
                            }
                        }
                    }
                    Ok((id, quiche::h3::Event::Data)) => {
                        let mut body = [0; 1024];
                        while let Ok(length) = client_h3.recv_body(&mut client, id, &mut body) {
                            response_bodies
                                .entry(id)
                                .or_default()
                                .extend_from_slice(&body[..length]);
                        }
                    }
                    Ok(_) => (),
                    Err(quiche::h3::Error::Done) => break,
                    Err(error) => panic!("HTTP/3 response poll failed: {error:?}"),
                }
            }
            if response_bodies.len() == 2 {
                break;
            }
        }

        assert_eq!(statuses.get(&first_stream_id), Some(&b"200".to_vec()));
        assert_eq!(statuses.get(&second_stream_id), Some(&b"200".to_vec()));
        assert_eq!(response_bodies[&first_stream_id], b"handled:data:done");
        assert_eq!(response_bodies[&second_stream_id], b"handled:data");
        assert!(fixture.wait().unwrap().success());
    }
}
