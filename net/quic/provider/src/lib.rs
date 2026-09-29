use std::collections::{HashMap, VecDeque};
use std::ffi::{CStr, c_char};
use std::fs::File;
use std::io::{self, Read};
use std::net::SocketAddr;
use std::ptr;
use std::slice;
use std::time::Duration;

use quiche::h3::NameValue;
use quiche::{Connection, ConnectionId, RecvInfo, SendInfo};

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
    config.set_initial_max_data(10_000_000);
    config.set_initial_max_stream_data_bidi_local(1_000_000);
    config.set_initial_max_stream_data_bidi_remote(1_000_000);
    config.set_initial_max_stream_data_uni(1_000_000);
    config.set_initial_max_streams_bidi(100);
    config.set_initial_max_streams_uni(3);

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

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_send(
    server: *mut NetQuicServer,
    packet: *mut u8,
    packet_capacity: usize,
    remote_address: *mut c_char,
    address_capacity: usize,
) -> i32 {
    if server.is_null()
        || packet.is_null()
        || packet_capacity == 0
        || remote_address.is_null()
        || address_capacity < 64
    {
        return -1;
    }
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
        server._inner.buffered_request_bytes -= request.body.len();
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
    if server.is_null()
        || !(100..=599).contains(&status)
        || header_length > 32_768
        || body_length > 1024 * 1024
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
    if header_count > 100 {
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
    i32::from(unsafe { &mut *server }._inner.enqueue_response(
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

fn append_request_body(
    request: &mut PendingRequest,
    bytes: &[u8],
    buffered_bytes: &mut usize,
    limit: usize,
) -> bool {
    if request.body.len() + bytes.len() > MAX_HTTP3_REQUEST_BODY_BYTES
        || !reserve_bytes(buffered_bytes, bytes.len(), limit)
    {
        return false;
    }
    request.body.extend_from_slice(bytes);
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
    !name.is_empty() && !name.starts_with(b":") && name.iter().copied().all(is_http_tchar)
}

fn is_valid_http_field_value(value: &[u8]) -> bool {
    value.iter().copied().all(|byte| {
        byte == b'\t' || (byte >= 0x20 && byte != 0x7f)
    })
}

pub struct QuicServer {
    config: quiche::Config,
    http3_config: quiche::h3::Config,
    connections: HashMap<Vec<u8>, QuicConnection>,
    routes: HashMap<Vec<u8>, Vec<u8>>,
    requests: VecDeque<CompletedRequest>,
    request_routes: HashMap<u64, (Vec<u8>, u64)>,
    next_request_id: u64,
    random: File,
    max_connections: usize,
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
    http3: Option<quiche::h3::Connection>,
    requests: HashMap<u64, PendingRequest>,
    responses: HashMap<u64, PendingResponse>,
    goaway_sent: bool,
    final_goaway_sent: bool,
    last_request_stream_id: Option<u64>,
    final_goaway_last_stream_id: Option<u64>,
}

const MAX_HTTP3_REQUEST_STREAM_ID: u64 = (1 << 62) - 4;
const MAX_HTTP3_BUFFERED_REQUEST_BYTES: usize = 64 * 1024 * 1024;
const MAX_HTTP3_REQUEST_BODY_BYTES: usize = 1024 * 1024;
const MAX_HTTP3_BUFFERED_RESPONSE_BYTES: usize = 64 * 1024 * 1024;
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
    body: Vec<u8>,
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
        Ok(Self {
            config,
            http3_config,
            connections: HashMap::new(),
            routes: HashMap::new(),
            requests: VecDeque::new(),
            request_routes: HashMap::new(),
            next_request_id: 1,
            random: File::open("/dev/urandom")?,
            max_connections: 10_000,
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
        for connection in self.connections.values_mut() {
            if connection.final_goaway_sent {
                continue;
            }
            let Some(http3) = connection.http3.as_mut() else {
                continue;
            };
            let last_stream_id = connection.last_request_stream_id.unwrap_or(0);
            match http3.send_goaway(&mut connection.transport, last_stream_id) {
                Ok(()) => {
                    connection.final_goaway_sent = true;
                    connection.final_goaway_last_stream_id = Some(last_stream_id);
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
        for connection in self.connections.values_mut() {
            if connection.transport.is_closed() || connection.transport.is_draining() {
                continue;
            }
            if let Err(error) = connection.transport.close(true, 0x100, b"") {
                first_error.get_or_insert(error);
            }
        }
        first_error.map_or(Ok(()), |error| Err(error.into()))
    }

    pub fn shutdown_complete(&self) -> bool {
        self.connections.is_empty()
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
                        http3: None,
                        requests: HashMap::new(),
                        responses: HashMap::new(),
                        goaway_sent: false,
                        final_goaway_sent: false,
                        last_request_stream_id: None,
                        final_goaway_last_stream_id: None,
                    },
                );
                key
            }
            None => return Err(quiche::Error::Done.into()),
        };

        {
            let connection = self.connections.get_mut(&key).unwrap();
            connection.transport.recv(
                packet,
                RecvInfo {
                    from: remote,
                    to: local,
                },
            )?;
            if connection.transport.is_established() && connection.http3.is_none() {
                match quiche::h3::Connection::with_transport(
                    &mut connection.transport,
                    &self.http3_config,
                ) {
                    Ok(http3) => connection.http3 = Some(http3),
                    Err(quiche::h3::Error::InternalError | quiche::h3::Error::Done) => (),
                    Err(error) => return Err(error.into()),
                }
            }
        }

        let mut cancelled_requests = Vec::new();
        let completed = {
            let connection = self.connections.get_mut(&key).unwrap();
            match Self::poll_http3(
                connection,
                &mut self.buffered_request_bytes,
                &mut self.buffered_response_bytes,
                &mut cancelled_requests,
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
        let Some(completed) = completed else {
            self.force_drop_connection(&key);
            return Ok(());
        };
        for request_id in cancelled_requests {
            self.request_routes.remove(&request_id);
        }
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
        for connection in self.connections.values_mut() {
            if connection.goaway_sent {
                continue;
            }
            let Some(http3) = connection.http3.as_mut() else {
                continue;
            };
            match http3.send_goaway(&mut connection.transport, MAX_HTTP3_REQUEST_STREAM_ID) {
                Ok(()) => connection.goaway_sent = true,
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
        let in_flight_bytes: usize = connection
            .requests
            .values()
            .map(|request| request.body.len())
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
            .map(|request| request.body.len())
            .sum();
        self.buffered_request_bytes -= queued_bytes;
        self.requests
            .retain(|request| !request_ids.contains(&request.id));
    }

    fn poll_http3(
        connection: &mut QuicConnection,
        buffered_request_bytes: &mut usize,
        buffered_response_bytes: &mut usize,
        cancelled_requests: &mut Vec<u64>,
    ) -> Result<Vec<CompletedRequest>, QuicServerError> {
        let mut completed = Vec::new();
        let Some(http3) = connection.http3.as_mut() else {
            return Ok(completed);
        };
        loop {
            match http3.poll(&mut connection.transport) {
                Ok((stream_id, quiche::h3::Event::Headers { list, .. })) => {
                    if connection
                        .final_goaway_last_stream_id
                        .is_some_and(|last| stream_id > last)
                    {
                        let _ = connection.transport.stream_shutdown(
                            stream_id,
                            quiche::Shutdown::Read,
                            H3_REQUEST_REJECTED,
                        );
                        let _ = connection.transport.stream_shutdown(
                            stream_id,
                            quiche::Shutdown::Write,
                            H3_REQUEST_REJECTED,
                        );
                        continue;
                    }
                    if let Some(request) = connection.requests.get_mut(&stream_id) {
                        let mut invalid = false;
                        for header in list {
                            request.header_count += 1;
                            request.header_bytes += header.name().len() + header.value().len();
                            let name = header.name();
                            let value = header.value();
                            if request.header_count > 100
                                || request.header_bytes > 32_768
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
                            let code = if request.header_bytes > 32_768 {
                                0x107
                            } else {
                                0x10e
                            };
                            let _ = connection.transport.stream_shutdown(
                                stream_id,
                                quiche::Shutdown::Read,
                                code,
                            );
                            if let Some(rejected) = connection.requests.remove(&stream_id) {
                                *buffered_request_bytes -= rejected.body.len();
                            }
                        }
                        continue;
                    }
                    let mut request = PendingRequest::default();
                    let mut seen_pseudo_headers = 0u8;
                    let mut regular_header_seen = false;
                    let mut header_bytes = 0usize;
                    let mut header_count = 0usize;
                    let mut invalid = false;
                    for header in list {
                        header_count += 1;
                        header_bytes += header.name().len() + header.value().len();
                        if header_count > 100 || header_bytes > 32_768 {
                            invalid = true;
                        }
                        match header.name() {
                            b":method" => {
                                if regular_header_seen || seen_pseudo_headers & 1 != 0 {
                                    invalid = true;
                                }
                                seen_pseudo_headers |= 1;
                                request.method = header.value().to_vec();
                            }
                            b":path" => {
                                if regular_header_seen || seen_pseudo_headers & 2 != 0 {
                                    invalid = true;
                                }
                                seen_pseudo_headers |= 2;
                                request.target = header.value().to_vec();
                            }
                            b":scheme" => {
                                if regular_header_seen || seen_pseudo_headers & 4 != 0 {
                                    invalid = true;
                                }
                                seen_pseudo_headers |= 4;
                                request.scheme = header.value().to_vec();
                            }
                            b":authority" => {
                                if regular_header_seen || seen_pseudo_headers & 8 != 0 {
                                    invalid = true;
                                }
                                seen_pseudo_headers |= 8;
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
                                request
                                    .headers
                                    .push((name.to_vec(), header.value().to_vec()));
                            }
                        }
                    }
                    request.header_bytes = header_bytes;
                    request.header_count = header_count;
                    if invalid
                        || seen_pseudo_headers != 15
                        || request.method == b"CONNECT"
                        || request.method.is_empty()
                        || request.target.is_empty()
                        || request.scheme.is_empty()
                        || request.authority.is_empty()
                    {
                        let code = if header_bytes > 32_768 { 0x107 } else { 0x10e };
                        let _ = connection.transport.stream_shutdown(
                            stream_id,
                            quiche::Shutdown::Read,
                            code,
                        );
                        continue;
                    }
                    connection.last_request_stream_id = Some(
                        connection
                            .last_request_stream_id
                            .map_or(stream_id, |last| last.max(stream_id)),
                    );
                    connection.requests.insert(stream_id, request);
                }
                Ok((stream_id, quiche::h3::Event::Data)) => {
                    if connection
                        .final_goaway_last_stream_id
                        .is_some_and(|last| stream_id > last)
                    {
                        continue;
                    }
                    let Some(request) = connection.requests.get_mut(&stream_id) else {
                        let _ = connection.transport.stream_shutdown(
                            stream_id,
                            quiche::Shutdown::Read,
                            H3_FRAME_UNEXPECTED,
                        );
                        let _ = connection.transport.stream_shutdown(
                            stream_id,
                            quiche::Shutdown::Write,
                            H3_FRAME_UNEXPECTED,
                        );
                        continue;
                    };
                    let mut body = [0; 16 * 1024];
                    loop {
                        match http3.recv_body(&mut connection.transport, stream_id, &mut body) {
                            Ok(length) => {
                                if !append_request_body(
                                    request,
                                    &body[..length],
                                    buffered_request_bytes,
                                    MAX_HTTP3_BUFFERED_REQUEST_BYTES,
                                ) {
                                    let _ = connection.transport.stream_shutdown(
                                        stream_id,
                                        quiche::Shutdown::Read,
                                        H3_EXCESSIVE_LOAD,
                                    );
                                    if let Some(rejected) = connection.requests.remove(&stream_id) {
                                        *buffered_request_bytes -= rejected.body.len();
                                    }
                                    break;
                                }
                            }
                            Err(quiche::h3::Error::Done) => break,
                            Err(error) => return Err(error.into()),
                        }
                    }
                }
                Ok((stream_id, quiche::h3::Event::Finished)) => {
                    if let Some(request) = connection.requests.remove(&stream_id) {
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
                Ok((stream_id, quiche::h3::Event::Reset(_))) => {
                    if let Some(reset) = connection.requests.remove(&stream_id) {
                        *buffered_request_bytes -= reset.body.len();
                    }
                    if let Some(reset) = connection.responses.remove(&stream_id) {
                        *buffered_response_bytes -= reset.buffered_bytes;
                        cancelled_requests.push(reset.request_id);
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
        self.buffered_request_bytes -= request.body.len();
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
            let _ = connection.transport.stream_shutdown(
                stream_id,
                quiche::Shutdown::Write,
                H3_EXCESSIVE_LOAD,
            );
            self.request_routes.remove(&request_id);
            return true;
        }
        let mut response_headers = Vec::with_capacity(headers.len() + 1);
        response_headers.push(quiche::h3::Header::new(b":status", status_value.as_bytes()));
        for (name, value) in headers {
            let Some(normalized) = normalize_http3_response_header_name(&name) else {
                self.buffered_response_bytes -= buffered_bytes;
                let connection = self.connections.get_mut(&connection_key).unwrap();
                let _ = connection.transport.stream_shutdown(
                    stream_id,
                    quiche::Shutdown::Write,
                    H3_GENERAL_PROTOCOL_ERROR,
                );
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
            },
        );
        true
    }

    fn drive_responses(&mut self) -> Result<(), QuicServerError> {
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
                        Ok(()) => response.headers_sent = true,
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
                        response.body_offset += written;
                        if response.body_offset == response.body.len() {
                            completed.push((
                                connection_key.clone(),
                                stream_id,
                                response.request_id,
                            ));
                        }
                    }
                    Err(quiche::h3::Error::Done | quiche::h3::Error::StreamBlocked) => (),
                    Err(error) => return Err(error.into()),
                }
            }
        }
        for (connection_key, stream_id, request_id) in completed {
            let response = self
                .connections
                .get_mut(&connection_key)
                .unwrap()
                .responses
                .remove(&stream_id)
                .unwrap();
            self.buffered_response_bytes -= response.buffered_bytes;
            self.request_routes.remove(&request_id);
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
        for connection in self.connections.values_mut() {
            match connection.transport.send(packet) {
                Ok((length, info)) => return Ok(Some((length, info))),
                Err(quiche::Error::Done) => {}
                Err(error) => return Err(error.into()),
            }
        }
        Ok(None)
    }

    pub fn timeout(&self) -> Option<Duration> {
        self.connections
            .values()
            .filter_map(|connection| connection.transport.timeout())
            .min()
    }

    pub fn on_timeout(&mut self) {
        let mut closed = Vec::new();
        for connection in self.connections.values_mut() {
            if connection
                .transport
                .timeout()
                .is_some_and(|timeout| timeout.is_zero())
            {
                connection.transport.on_timeout();
            }
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
}

#[cfg(test)]
mod tests {
    use std::ffi::{CStr, CString, c_char};
    use std::net::UdpSocket;
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};
    use std::time::Duration;

    use quiche::{ConnectionId, Header, RecvInfo};

    use super::{
        MAX_HTTP3_BUFFERED_RESPONSE_BYTES, NetQuicServerConfig, PendingRequest, append_bytes,
        append_request_body, append_u32, net_quic_server_free, net_quic_server_new,
        reserve_response_bytes,
    };
    use quiche::h3::NameValue;

    #[test]
    fn request_memory_budget_rejects_aggregate_overflow_without_changing_usage() {
        let mut used = 0;
        let mut first = PendingRequest::default();
        assert!(append_request_body(&mut first, b"123456", &mut used, 10));
        assert_eq!(used, 6);
        let mut second = PendingRequest::default();
        assert!(append_request_body(&mut second, b"abcd", &mut used, 10));
        assert_eq!(used, 10);
        let mut third = PendingRequest::default();
        assert!(!append_request_body(&mut third, b"x", &mut used, 10));
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
                let length = unsafe {
                    super::net_quic_server_send(
                        server,
                        packet.as_mut_ptr(),
                        packet.len(),
                        destination.as_mut_ptr(),
                        destination.len(),
                    )
                };
                if length <= 0 {
                    break;
                }
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
                let length = unsafe {
                    super::net_quic_server_send(
                        server,
                        packet.as_mut_ptr(),
                        packet.len(),
                        destination.as_mut_ptr(),
                        destination.len(),
                    )
                };
                if length <= 0 {
                    break;
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
            request.body.len()
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
                let length = unsafe {
                    super::net_quic_server_send(
                        server,
                        packet.as_mut_ptr(),
                        packet.len(),
                        destination.as_mut_ptr(),
                        destination.len(),
                    )
                };
                if length <= 0 {
                    break;
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
                let length = unsafe {
                    super::net_quic_server_send(
                        server,
                        packet.as_mut_ptr(),
                        packet.len(),
                        destination.as_mut_ptr(),
                        destination.len(),
                    )
                };
                if length <= 0 {
                    break;
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
