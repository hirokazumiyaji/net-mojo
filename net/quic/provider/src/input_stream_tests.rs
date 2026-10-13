fn input_stream_server() -> super::QuicServer {
    let mut server = super::QuicServer::new(stress_server_config()).unwrap();
    assert!(server.set_request_streaming(true));
    server
}

fn input_stream_post(peer: &mut ReceiveBudgetPeer, length: Option<usize>) -> u64 {
    let mut headers = vec![
        quiche::h3::Header::new(b":method", b"POST"),
        quiche::h3::Header::new(b":scheme", b"https"),
        quiche::h3::Header::new(b":authority", b"localhost"),
        quiche::h3::Header::new(b":path", b"/input"),
    ];
    if let Some(length) = length {
        headers.push(quiche::h3::Header::new(
            b"content-length",
            length.to_string().as_bytes(),
        ));
    }
    peer.http3.send_request(&mut peer.client, &headers, false).unwrap()
}

fn input_stream_send(peer: &mut ReceiveBudgetPeer, stream: u64, bytes: &[u8], fin: bool) -> Result<usize, quiche::h3::Error> {
    peer.http3.send_body(&mut peer.client, stream, bytes, fin)
}

fn input_stream_send_trailers(peer: &mut ReceiveBudgetPeer, stream: u64) {
    peer.http3.send_additional_headers(&mut peer.client, stream,
        &[quiche::h3::Header::new(b"x-input-end", b"yes")], true, true).unwrap();
}

fn input_stream_pump(server: &mut super::QuicServer, peers: &mut [ReceiveBudgetPeer]) {
    for _ in 0..8 {
        send_pool_pump(server, peers);
    }
}

#[test]
fn provider_input_stream_head_precedes_data_and_partial_consumption() {
    let mut server = input_stream_server();
    server.max_request_body_bytes = 4;
    let mut peers = vec![ReceiveBudgetPeer::new(&mut server, 91)];
    let stream = input_stream_post(&mut peers[0], Some(8));
    input_stream_pump(&mut server, &mut peers);
    let head = server.next_request().unwrap();
    assert_eq!(head.stream_id, stream);
    assert_eq!(head.method, b"POST");
    assert!(head.body.is_empty() && head.trailers.is_empty());
    assert!(!server.set_request_streaming(false));
    let mut bytes = [0; 16];
    assert_eq!(server.read_body(head.id, &mut bytes), -1);
    assert_eq!(input_stream_send(&mut peers[0], stream, b"abcdefgh", true), Ok(8));
    input_stream_pump(&mut server, &mut peers);
    assert_eq!(server.read_body(head.id, &mut bytes[..3]), 3);
    assert_eq!(&bytes[..3], b"abc");
    assert_eq!(server.read_body(head.id, &mut bytes), 1);
    assert_eq!(bytes[0], b'd');
    assert_eq!(server.read_body(head.id, &mut bytes), -1);
    assert!(!server.consume_body(head.id, 5));
    assert!(server.consume_body(head.id, 2));
    assert_eq!(server.read_body(head.id, &mut bytes), 2);
    assert_eq!(&bytes[..2], b"ef");
    assert!(server.consume_body(head.id, 4));
    assert_eq!(server.read_body(head.id, &mut bytes), 2);
    assert_eq!(&bytes[..2], b"gh");
    assert_eq!(server.read_body(head.id, &mut bytes), 0);
    assert!(server.consume_body(head.id, 2));
    assert!(server.release_body(head.id, false));
    assert_eq!(server.read_body(head.id, &mut bytes), -2);
    assert_eq!(server.buffered_request_bytes, 0);
    assert!(server.input_routes.is_empty());
}

#[test]
fn provider_input_stream_survives_response_fin_and_preserves_trailers() {
    let mut server = input_stream_server();
    let mut peers = vec![ReceiveBudgetPeer::new(&mut server, 92)];
    let stream = input_stream_post(&mut peers[0], Some(6));
    input_stream_pump(&mut server, &mut peers);
    let head = server.next_request().unwrap();
    assert!(server.enqueue_response(head.id, 200, Vec::new(), Vec::new(), Vec::new()));
    input_stream_pump(&mut server, &mut peers);
    assert!(!server.request_routes.contains_key(&head.id));
    assert!(server.input_routes.contains_key(&head.id));
    assert_eq!(input_stream_send(&mut peers[0], stream, b"abcdef", false), Ok(6));
    input_stream_send_trailers(&mut peers[0], stream);
    input_stream_pump(&mut server, &mut peers);
    let mut bytes = [0; 16];
    assert_eq!(server.read_body(head.id, &mut bytes), 6);
    assert_eq!(&bytes[..6], b"abcdef");
    assert_eq!(server.read_body(head.id, &mut bytes), 0);
    let (key, id) = server.input_routes[&head.id].clone();
    assert_eq!(server.connections[&key].requests[&id].trailers,
        vec![(b"x-input-end".to_vec(), b"yes".to_vec())]);
    assert!(server.release_body(head.id, false));
    assert_eq!(server.buffered_request_bytes, 0);
    assert!(server.input_routes.is_empty());
}

#[test]
fn provider_input_stream_receive_credit_waits_for_consumption() {
    for (stream_window, connection_window) in [(512, 8192), (4096, 1024)] {
        let mut config = stress_server_config();
        config.set_initial_max_data(connection_window);
        config.set_initial_max_stream_data_bidi_remote(stream_window);
        config.set_max_connection_window(connection_window);
        config.set_max_stream_window(stream_window);
        let mut server = super::QuicServer::new(config).unwrap();
        assert!(server.set_request_streaming(true));
        let mut peers = vec![ReceiveBudgetPeer::new(&mut server, 93)];
        let stream = input_stream_post(&mut peers[0], None);
        input_stream_pump(&mut server, &mut peers);
        let head = server.next_request().unwrap();
        let mut sent = 0;
        let mut read = 0;
        let mut buffer = [0; 512];
        for _ in 0..32 {
            match input_stream_send(&mut peers[0], stream, &[b'x'; 256], false) {
                Ok(bytes) => sent += bytes,
                Err(quiche::h3::Error::Done) => (),
                other => panic!("unexpected DATA send {other:?}"),
            }
            input_stream_pump(&mut server, &mut peers);
            loop {
                let count = server.read_body(head.id, &mut buffer);
                if count == -1 { break; }
                assert!(count > 0);
                read += count as usize;
            }
        }
        assert!(read > 0 && read == sent);
        assert_eq!(peers[0].client.stream_capacity(stream).unwrap(), 0);
        let held = sent;
        for _ in 0..8 { input_stream_pump(&mut server, &mut peers); }
        assert_eq!(peers[0].client.stream_capacity(stream).unwrap(), 0);
        assert!(server.consume_body(head.id, held));
        input_stream_pump(&mut server, &mut peers);
        assert!(peers[0].client.stream_capacity(stream).unwrap() > 0);
        assert!(server.release_body(head.id, true));
        assert_eq!(server.buffered_request_bytes, 0);
    }
}

#[test]
fn provider_input_stream_reset_timeout_and_discard_refund() {
    for terminal in 0..3 {
        let mut server = input_stream_server();
        let mut peers = vec![ReceiveBudgetPeer::new(&mut server, 94)];
        let stream = input_stream_post(&mut peers[0], None);
        input_stream_pump(&mut server, &mut peers);
        let head = server.next_request().unwrap();
        assert_eq!(input_stream_send(&mut peers[0], stream, b"held", false), Ok(4));
        input_stream_pump(&mut server, &mut peers);
        let mut bytes = [0; 16];
        assert_eq!(server.read_body(head.id, &mut bytes), 4);
        match terminal {
            0 => {
                peers[0].client.stream_shutdown(stream, quiche::Shutdown::Write, 0x10c).unwrap();
                input_stream_pump(&mut server, &mut peers);
            }
            1 => {
                let (key, stream_id) = server.input_routes[&head.id].clone();
                server.connections.get_mut(&key).unwrap().requests.get_mut(&stream_id).unwrap().body_deadline_at = Some(Instant::now());
                server.refresh_request_timeout(&key, stream_id);
                server.on_timeout();
                input_stream_pump(&mut server, &mut peers);
            }
            _ => { assert!(server.release_body(head.id, false)); }
        }
        assert_eq!(server.read_body(head.id, &mut bytes), -2);
        assert!(server.input_routes.is_empty());
        assert_eq!(server.buffered_request_bytes, 0);
        let sibling_stream = send_pool_get(&mut peers[0], b"/sibling");
        input_stream_pump(&mut server, &mut peers);
        let sibling = server.next_request().unwrap();
        assert_eq!(sibling.stream_id, sibling_stream);
        assert!(server.release_body(sibling.id, false));
        assert!(server.enqueue_response(sibling.id, 200, Vec::new(), Vec::new(), Vec::new()));
        input_stream_pump(&mut server, &mut peers);
        assert_eq!(server.buffered_request_bytes, 0);
    }
}

#[test]
fn provider_input_stream_stop_sending_cancels_reader() {
    let mut server = input_stream_server();
    let mut peers = vec![ReceiveBudgetPeer::new(&mut server, 95)];
    let stream = input_stream_post(&mut peers[0], None);
    input_stream_pump(&mut server, &mut peers);
    let head = server.next_request().unwrap();
    assert!(server.start_response(head.id, 200, Vec::new()));
    input_stream_pump(&mut server, &mut peers);
    peers[0].client.stream_shutdown(stream, quiche::Shutdown::Read, 0x10c).unwrap();
    input_stream_pump(&mut server, &mut peers);
    assert_eq!(server.stream_capacity(head.id), -1);
    assert_eq!(server.read_body(head.id, &mut [0; 16]), -2);
    assert_eq!(server.buffered_request_bytes, 0);
    assert!(server.input_routes.is_empty());
}

#[test]
fn provider_input_stream_ffi_head_retry_body_and_trailer_records() {
    let mut inner = input_stream_server();
    let mut peers = vec![ReceiveBudgetPeer::new(&mut inner, 96)];
    let stream = input_stream_post(&mut peers[0], Some(4));
    input_stream_pump(&mut inner, &mut peers);
    let id = inner.requests.front().unwrap().id;
    let mut server = super::NetQuicServer { _inner: inner };
    let needed = unsafe { super::net_quic_server_next_request_head(&mut server, std::ptr::null_mut(), 0) };
    assert!(needed < -4);
    let mut head = vec![0; (-needed) as usize];
    assert_eq!(unsafe { super::net_quic_server_next_request_head(&mut server, head.as_mut_ptr(), head.len() - 1) }, needed);
    assert_eq!(unsafe { super::net_quic_server_next_request_head(&mut server, head.as_mut_ptr(), head.len()) }, -needed);
    assert_eq!(u64::from_be_bytes(head[..8].try_into().unwrap()), id);
    assert_eq!(input_stream_send(&mut peers[0], stream, b"data", false), Ok(4));
    input_stream_send_trailers(&mut peers[0], stream);
    input_stream_pump(&mut server._inner, &mut peers);
    let mut body = [0; 16];
    assert_eq!(unsafe { super::net_quic_server_body_trailers(&mut server, id, body.as_mut_ptr(), body.len()) }, -1);
    assert_eq!(unsafe { super::net_quic_server_read_body(&mut server, id, body.as_mut_ptr(), body.len()) }, 4);
    assert_eq!(&body[..4], b"data");
    assert_eq!(unsafe { super::net_quic_server_read_body(&mut server, id, body.as_mut_ptr(), body.len()) }, 0);
    assert_eq!(unsafe { super::net_quic_server_consume_body(&mut server, id, 5) }, -1);
    assert_eq!(unsafe { super::net_quic_server_consume_body(&mut server, id, 4) }, 1);
    let needed = unsafe { super::net_quic_server_body_trailers(&mut server, id, std::ptr::null_mut(), 0) };
    let mut record = vec![0; (-needed) as usize];
    assert_eq!(unsafe { super::net_quic_server_body_trailers(&mut server, id, record.as_mut_ptr(), record.len() - 1) }, needed);
    assert_eq!(unsafe { super::net_quic_server_body_trailers(&mut server, id, record.as_mut_ptr(), record.len()) }, -needed);
    assert_eq!(&record[..4], &1u32.to_be_bytes());
    assert_eq!(&record[4..8], &11u32.to_be_bytes());
    assert_eq!(&record[8..19], b"x-input-end");
    assert_eq!(&record[19..23], &3u32.to_be_bytes());
    assert_eq!(&record[23..], b"yes");
    assert_eq!(unsafe { super::net_quic_server_release_body(&mut server, id, 0) }, 1);
    assert_eq!(server._inner.buffered_request_bytes, 0);
}

#[test]
fn provider_input_stream_trailer_failure_retires_pending_output() {
    let mut server = input_stream_server();
    let mut peers = vec![ReceiveBudgetPeer::new(&mut server, 97)];
    let stream = input_stream_post(&mut peers[0], None);
    input_stream_pump(&mut server, &mut peers);
    let head = server.next_request().unwrap();
    assert!(server.start_response(head.id, 200, Vec::new()));
    assert_eq!(input_stream_send(&mut peers[0], stream, b"data", false), Ok(4));
    input_stream_pump(&mut server, &mut peers);
    let mut bytes = [0; 16];
    assert_eq!(server.read_body(head.id, &mut bytes), 4);
    let peer = &mut peers[0];
    peer.http3.send_additional_headers(&mut peer.client, stream,
        &[quiche::h3::Header::new(b"content-length", b"4")], true, true).unwrap();
    input_stream_pump(&mut server, &mut peers);
    assert_eq!(server.read_body(head.id, &mut bytes), -2);
    assert!(server.input_routes.is_empty() && server.request_routes.is_empty());
    assert!(server.connections.values().all(|connection| connection.responses.is_empty()));
    assert_eq!(server.buffered_request_bytes, 0);
}

#[test]
fn provider_input_stream_timeout_retires_pending_output() {
    let mut server = input_stream_server();
    let mut peers = vec![ReceiveBudgetPeer::new(&mut server, 98)];
    input_stream_post(&mut peers[0], None);
    input_stream_pump(&mut server, &mut peers);
    let head = server.next_request().unwrap();
    assert!(server.start_response(head.id, 200, Vec::new()));
    let (key, stream_id) = server.input_routes[&head.id].clone();
    server.connections.get_mut(&key).unwrap().requests.get_mut(&stream_id).unwrap().body_deadline_at = Some(Instant::now());
    server.refresh_request_timeout(&key, stream_id);
    server.on_timeout();
    input_stream_pump(&mut server, &mut peers);
    assert_eq!(server.read_body(head.id, &mut [0; 8]), -2);
    assert!(server.input_routes.is_empty() && server.request_routes.is_empty());
    assert!(server.connections[&key].responses.is_empty());
    assert_eq!(server.buffered_request_bytes, 0);
}

#[test]
fn provider_input_stream_regression_buffered_data_frames_are_readable() {
    let mut server = input_stream_server();
    let mut peers = vec![ReceiveBudgetPeer::new(&mut server, 99)];
    let stream = input_stream_post(&mut peers[0], Some(8));
    input_stream_pump(&mut server, &mut peers);
    let head = server.next_request().unwrap();
    assert_eq!(input_stream_send(&mut peers[0], stream, b"abcd", false), Ok(4));
    assert_eq!(input_stream_send(&mut peers[0], stream, b"efgh", true), Ok(4));
    input_stream_pump(&mut server, &mut peers);
    let mut bytes = [0; 16];
    assert_eq!(server.read_body(head.id, &mut bytes), 4);
    assert_eq!(&bytes[..4], b"abcd");
    assert_eq!(server.read_body(head.id, &mut bytes), 4);
    assert_eq!(&bytes[..4], b"efgh");
    assert_eq!(server.read_body(head.id, &mut bytes), 0);
    assert!(server.release_body(head.id, false));
    assert_eq!(server.buffered_request_bytes, 0);
}

#[test]
fn provider_input_stream_regression_head_and_protocol_error_refund() {
    let mut server = input_stream_server();
    let mut peers = vec![ReceiveBudgetPeer::new(&mut server, 100)];
    let stream = input_stream_post(&mut peers[0], None);
    assert_eq!(peers[0].client.stream_send(stream, &[0x04, 0x00], true), Ok(2));
    input_stream_pump(&mut server, &mut peers);
    assert_eq!(server.buffered_request_bytes, 0);
    assert!(server.requests.is_empty() && server.input_routes.is_empty());
}

#[test]
fn provider_input_stream_rejects_invalid_content_length_before_delivery() {
    let mut server = input_stream_server();
    let mut peers = vec![ReceiveBudgetPeer::new(&mut server, 101)];
    for values in [vec![b"bad".as_slice()], vec![b"4".as_slice(), b"5".as_slice()]] {
        let peer = &mut peers[0];
        let mut headers = vec![
            quiche::h3::Header::new(b":method", b"POST"),
            quiche::h3::Header::new(b":scheme", b"https"),
            quiche::h3::Header::new(b":authority", b"localhost"),
            quiche::h3::Header::new(b":path", b"/invalid-length"),
        ];
        for value in values {
            headers.push(quiche::h3::Header::new(b"content-length", value));
        }
        peer.http3.send_request(&mut peer.client, &headers, false).unwrap();
        input_stream_pump(&mut server, &mut peers);
        assert!(server.next_request().is_none());
        assert!(server.input_routes.is_empty());
        assert_eq!(server.buffered_request_bytes, 0);
    }
    input_stream_post(&mut peers[0], Some(4));
    input_stream_pump(&mut server, &mut peers);
    let head = server.next_request().unwrap();
    assert!(server.release_body(head.id, false));
    assert_eq!(server.buffered_request_bytes, 0);
}

#[test]
fn provider_input_stream_regression_read_driven_cancel_is_send_ready() {
    let mut server = input_stream_server();
    let mut peers = vec![ReceiveBudgetPeer::new(&mut server, 110)];
    let stream = input_stream_post(&mut peers[0], None);
    input_stream_pump(&mut server, &mut peers);
    let head = server.next_request().unwrap();
    assert!(server.enqueue_response(head.id, 200, Vec::new(), Vec::new(), Vec::new()));
    input_stream_pump(&mut server, &mut peers);
    assert!(!server.request_routes.contains_key(&head.id));
    assert_eq!(peers[0].client.stream_send(stream, &[0, 4, b'd', b'a', b't', b'a', 4, 0], true), Ok(8));
    input_stream_pump(&mut server, &mut peers);
    let (key, _) = server.input_routes[&head.id].clone();
    assert!(server.send_ready.entries.is_empty());
    assert_eq!(server.read_body(head.id, &mut [0; 16]), 4);
    assert_eq!(server.read_body(head.id, &mut [0; 16]), -2);
    assert!(server.connections[&key].transport.local_error().is_some());
    assert!(server.send_ready.entries.contains(&key), "cancel queued by read must schedule transport output");
    assert!(server.send(&mut [0; 65535]).unwrap().is_some());
}

#[test]
fn provider_input_stream_regression_empty_data_before_buffered_payload() {
    let mut server = input_stream_server();
    let mut peers = vec![ReceiveBudgetPeer::new(&mut server, 111)];
    let stream = input_stream_post(&mut peers[0], Some(4));
    input_stream_pump(&mut server, &mut peers);
    let head = server.next_request().unwrap();
    assert_eq!(peers[0].client.stream_send(stream, &[0, 0, 0, 0, 0, 4, b'd', b'a', b't', b'a'], true), Ok(10));
    input_stream_pump(&mut server, &mut peers);
    let mut buffer = [0; 16];
    assert_eq!(server.read_body(head.id, &mut buffer), 4, "empty DATA must not hide buffered payload");
}

#[test]
fn provider_input_stream_regression_stop_sending_cancels_without_output_accessor() {
    let mut server = input_stream_server();
    let mut peers = vec![ReceiveBudgetPeer::new(&mut server, 112)];
    let stream = input_stream_post(&mut peers[0], None);
    input_stream_pump(&mut server, &mut peers);
    let head = server.next_request().unwrap();
    assert!(server.start_response(head.id, 200, Vec::new()));
    input_stream_pump(&mut server, &mut peers);
    peers[0].client.stream_shutdown(stream, quiche::Shutdown::Read, 0x10c).unwrap();
    input_stream_pump(&mut server, &mut peers);
    assert_eq!(server.read_body(head.id, &mut [0; 16]), -2);
}

#[test]
fn provider_input_stream_unread_payload_stays_in_bounded_receive_pool() {
    let mut config = stress_server_config();
    config.set_initial_max_stream_data_bidi_remote(1024);
    config.set_max_stream_window(1024);
    let mut server = super::QuicServer::new(config).unwrap();
    assert!(server.set_request_streaming(true));
    let mut limits = receive_budget_limits();
    limits.request = quiche::ReceiveLimit { backing_bytes: 8192, slots: 64 };
    assert!(server.set_receive_limits(limits));
    let mut peers = vec![ReceiveBudgetPeer::new(&mut server, 113)];
    let stream = input_stream_post(&mut peers[0], None);
    input_stream_pump(&mut server, &mut peers);
    let head = server.next_request().unwrap();
    let metadata_bytes = server.buffered_request_bytes;
    let mut sent = 0;
    for _ in 0..32 {
        match input_stream_send(&mut peers[0], stream, &[b'x'; 256], false) {
            Ok(bytes) => sent += bytes,
            Err(quiche::h3::Error::Done) => (),
            other => panic!("unexpected DATA send {other:?}"),
        }
        input_stream_pump(&mut server, &mut peers);
        let usage = server.receive_budget.usage().request;
        assert!(usage.backing_bytes <= limits.request.backing_bytes);
        assert!(usage.slots <= limits.request.slots);
        assert_eq!(server.buffered_request_bytes, metadata_bytes);
        let (key, stream_id) = &server.input_routes[&head.id];
        assert!(server.connections[key].requests[stream_id].body.is_empty());
    }
    assert!(sent > 0);
    assert_eq!(peers[0].client.stream_capacity(stream).unwrap(), 0);
    assert!(server.receive_budget.usage().request.backing_bytes > 0);
    let sibling_stream = send_pool_get(&mut peers[0], b"/sibling");
    input_stream_pump(&mut server, &mut peers);
    let sibling = server.next_request().unwrap();
    assert_eq!(sibling.stream_id, sibling_stream);
    assert!(server.release_body(sibling.id, false));
    assert!(server.enqueue_response(sibling.id, 200, Vec::new(), Vec::new(), Vec::new()));
    input_stream_pump(&mut server, &mut peers);
    assert!(server.release_body(head.id, true));
    input_stream_pump(&mut server, &mut peers);
    assert_eq!(server.receive_budget.usage().request.backing_bytes, 0);
    assert_eq!(server.buffered_request_bytes, 0);
}

#[test]
fn provider_input_empty_probe_observes_eof_and_reset_without_consumption() {
    let mut server = input_stream_server();
    server.max_request_body_bytes = 4;
    let mut peers = vec![ReceiveBudgetPeer::new(&mut server, 114)];
    let stream = input_stream_post(&mut peers[0], Some(4));
    input_stream_pump(&mut server, &mut peers);
    let head = server.next_request().unwrap();
    let mut output = [0; 4];
    assert_eq!(unsafe { super::net_quic_server_read_body(std::ptr::null_mut(), head.id, output.as_mut_ptr(), 0) }, -3);
    assert_eq!(input_stream_send(&mut peers[0], stream, b"data", false), Ok(4));
    input_stream_send_trailers(&mut peers[0], stream);
    input_stream_pump(&mut server, &mut peers);
    assert_eq!(server.read_body(head.id, &mut output), 4);
    let mut wrapped = super::NetQuicServer { _inner: server };
    assert_eq!(unsafe { super::net_quic_server_read_body(&mut wrapped, head.id, output.as_mut_ptr(), 0) }, 0);
    let mut server = wrapped._inner;
    let (key, id) = server.input_routes[&head.id].clone();
    assert_eq!(server.connections[&key].requests[&id].unconsumed, 4);
    assert_eq!(server.connections[&key].requests[&id].trailers,
        vec![(b"x-input-end".to_vec(), b"yes".to_vec())]);
    assert!(server.consume_body(head.id, 4));
    assert!(server.release_body(head.id, false));
    assert_eq!(server.read_body(head.id, &mut output[..0]), -2);
}
