fn proposed_send_limits() -> quiche::SendLimits {
    quiche::SendLimits {
        request: quiche::SendLimit {
            backing_bytes: 512,
            slots: 128,
        },
        control: quiche::SendLimit {
            backing_bytes: 65_536,
            slots: 256,
        },
        crypto: quiche::SendLimit {
            backing_bytes: 65_536,
            slots: 256,
        },
    }
}

fn current_api_send_server(
    limits: quiche::SendLimits,
    grease: bool,
) -> (super::QuicServer, quiche::SendBudget) {
    let mut config = stress_server_config();
    config.grease(grease);
    let mut server = super::QuicServer::new(config).unwrap();
    let budget = quiche::SendBudget::new(limits);
    server.config.set_send_budget(budget.clone());
    (server, budget)
}

fn send_pool_pump(server: &mut super::QuicServer, peers: &mut [ReceiveBudgetPeer]) {
    let local: SocketAddr = "127.0.0.1:4433".parse().unwrap();
    let mut packet = [0; 65_535];
    for peer in peers.iter_mut() {
        drive_timeouts(&mut peer.client, server);
        for mut datagram in collect_client_datagrams(&mut peer.client, &mut packet) {
            match server.recv_datagram(&mut datagram, local, peer.remote) {
                Ok(()) | Err(super::QuicServerError::Quiche(quiche::Error::Done)) => (),
                Err(error) => panic!("unexpected provider receive: {error:?}"),
            }
        }
    }
    loop {
        match server.send(&mut packet) {
            Ok(Some((length, info))) => {
                let peer = peers.iter_mut().find(|p| p.remote == info.to).unwrap();
                match peer.client.recv(
                    &mut packet[..length],
                    RecvInfo {
                        from: info.from,
                        to: info.to,
                    },
                ) {
                    Ok(_) | Err(quiche::Error::Done) => (),
                    Err(error) => panic!("unexpected peer receive: {error:?}"),
                }
            }
            Ok(None) => break,
            Err(error) => panic!("send quota must be connection-local: {error:?}"),
        }
    }
}

fn send_pool_get(peer: &mut ReceiveBudgetPeer, path: &[u8]) -> u64 {
    peer.http3
        .send_request(
            &mut peer.client,
            &[
                quiche::h3::Header::new(b":method", b"GET"),
                quiche::h3::Header::new(b":scheme", b"https"),
                quiche::h3::Header::new(b":authority", b"localhost"),
                quiche::h3::Header::new(b":path", path),
            ],
            true,
        )
        .unwrap()
}

fn send_pool_read(peer: &mut ReceiveBudgetPeer, stream: u64, body: &mut Vec<u8>) -> bool {
    let mut finished = false;
    loop {
        match peer.http3.poll(&mut peer.client) {
            Ok((id, quiche::h3::Event::Headers { list, .. })) if id == stream => {
                assert!(
                    list.iter()
                        .any(|h| h.name() == b":status" && h.value() == b"200")
                );
            }
            Ok((id, quiche::h3::Event::Data)) if id == stream => {
                let mut bytes = [0; 1_024];
                loop {
                    match peer.http3.recv_body(&mut peer.client, id, &mut bytes) {
                        Ok(length) => body.extend_from_slice(&bytes[..length]),
                        Err(quiche::h3::Error::Done) => break,
                        Err(error) => panic!("unexpected body receive: {error:?}"),
                    }
                }
            }
            Ok((id, quiche::h3::Event::Finished)) if id == stream => finished = true,
            Ok(_) => (),
            Err(quiche::h3::Error::Done) => break,
            Err(error) => panic!("unexpected HTTP/3 poll: {error:?}"),
        }
    }
    finished
}

fn assert_no_owned_provider_state(server: &super::QuicServer, key: &[u8]) {
    assert!(server.routes.values().all(|owner| owner.as_slice() != key));
    assert!(
        server
            .request_routes
            .values()
            .all(|(owner, _)| owner.as_slice() != key)
    );
    assert!(
        server
            .transport_timeouts
            .iter()
            .all(|(_, owner)| owner.as_slice() != key)
    );
    assert!(
        server
            .request_timeouts
            .iter()
            .all(|(_, owner, _)| owner.as_slice() != key)
    );
    assert!(
        server
            .response_timeouts
            .iter()
            .all(|(_, owner, _)| owner.as_slice() != key)
    );
    assert!(
        server
            .idle_timeouts
            .iter()
            .all(|(_, owner)| owner.as_slice() != key)
    );
    for queue in [
        &server.send_ready,
        &server.response_ready,
        &server.goaway_ready,
    ] {
        assert!(!queue.queued.contains(key));
        assert!(queue.entries.iter().all(|owner| owner.as_slice() != key));
    }
}

fn provider_send_whole_copy_quota_case(headers_fail: bool) {
    let (mut server, budget) = current_api_send_server(proposed_send_limits(), false);
    let mut peers = [
        ReceiveBudgetPeer::new(&mut server, 0xd1),
        ReceiveBudgetPeer::new(&mut server, 0xd2),
    ];
    let original_sibling_cid = peers[1].client.source_id().as_ref().to_vec();
    let target_stream = send_pool_get(&mut peers[0], b"/too-large");
    for _ in 0..8 {
        send_pool_pump(&mut server, &mut peers);
    }
    let target = server.next_request().unwrap();
    assert_eq!(target.stream_id, target_stream);
    let key = server.request_routes[&target.id].0.clone();
    let awaiting_stream = send_pool_get(&mut peers[0], b"/delivered-awaiting-response");
    for _ in 0..8 {
        send_pool_pump(&mut server, &mut peers);
    }
    let awaiting = server.next_request().unwrap();
    assert_eq!(awaiting.stream_id, awaiting_stream);
    let queued_stream = send_pool_get(&mut peers[0], b"/queued");
    peers[0].open_body(128);
    let peer = &mut peers[0];
    peer.client
        .stream_send(peer.request_stream, b"ping", false)
        .unwrap();
    for _ in 0..8 {
        send_pool_pump(&mut server, &mut peers);
    }
    assert_eq!(server.requests.front().unwrap().stream_id, queued_stream);
    assert!(
        server.connections[&key]
            .requests
            .values()
            .any(|request| request.body == b"ping")
    );
    let (headers, body) = if headers_fail {
        (vec![(b"x-large".to_vec(), vec![b'x'; 8_192])], Vec::new())
    } else {
        (Vec::new(), vec![b'x'; 8_192])
    };
    assert!(server.enqueue_response(target.id, 200, headers, body));
    let control_before = budget.usage().control;
    let result = server.drive_responses();
    eprintln!(
        "PROVIDER_COPY_QUOTA headers={headers_fail} result={result:?} usage={:?}",
        budget.usage()
    );
    assert!(
        result.is_ok(),
        "only the target connection may terminate: {result:?}"
    );
    assert_eq!(budget.usage().control, control_before);
    assert!(budget.usage().request.backing_bytes < 512);
    let connection = &server.connections[&key];
    assert_eq!(
        connection
            .transport
            .local_error()
            .map(|e| (e.is_app, e.error_code)),
        Some((false, 1))
    );
    assert!(connection.requests.is_empty() && connection.responses.is_empty());
    assert!(
        connection.header_deadlines.is_empty() && connection.indexed_request_deadlines.is_empty()
    );
    assert!(connection.request_route_ids.is_empty());
    assert!(server.requests.is_empty());
    assert_eq!(server.buffered_request_bytes, 0);
    assert_eq!(server.buffered_response_bytes, 0);
    assert!(server.send_ready.queued.contains(&key));
    assert!(!server.response_ready.queued.contains(&key));
    assert!(!server.goaway_ready.queued.contains(&key));
    assert!(
        server
            .request_timeouts
            .iter()
            .all(|(_, owner, _)| owner != &key)
    );
    assert!(
        server
            .response_timeouts
            .iter()
            .all(|(_, owner, _)| owner != &key)
    );
    assert!(server.idle_timeouts.iter().all(|(_, owner)| owner != &key));
    for _ in 0..2 {
        let stream = send_pool_get(&mut peers[1], b"/original-sibling");
        for _ in 0..8 {
            send_pool_pump(&mut server, &mut peers);
        }
        let request = server.next_request().unwrap();
        assert_eq!(request.stream_id, stream);
        assert!(server.enqueue_response(request.id, 200, Vec::new(), b"alive".to_vec()));
        let mut body = Vec::new();
        let mut finished = false;
        for _ in 0..32 {
            send_pool_pump(&mut server, &mut peers);
            finished |= send_pool_read(&mut peers[1], stream, &mut body);
            if finished {
                break;
            }
        }
        assert!(finished);
        assert_eq!(body, b"alive");
        assert_eq!(
            peers[1].client.source_id().as_ref(),
            original_sibling_cid.as_slice()
        );
        assert!(peers[1].client.peer_error().is_none());
    }
    assert_eq!(
        peers[0]
            .client
            .peer_error()
            .map(|e| (e.is_app, e.error_code)),
        Some((false, 1))
    );
    let until = std::time::Instant::now() + Duration::from_secs(3);
    while server.connections.contains_key(&key) && std::time::Instant::now() < until {
        send_pool_pump(&mut server, &mut peers);
        let wait = server.timeout().unwrap().min(Duration::from_millis(5));
        std::thread::sleep(wait);
        server.on_timeout();
    }
    assert!(!server.connections.contains_key(&key));
    assert_no_owned_provider_state(&server, &key);
    assert_eq!(server.connections.len(), 1);
    drop(server);
    assert_eq!(budget.usage(), quiche::SendUsage::default());
}

#[test]
fn provider_send_body_copy_quota_keeps_original_sibling() {
    provider_send_whole_copy_quota_case(false);
}

#[test]
fn provider_send_header_copy_quota_keeps_original_sibling() {
    provider_send_whole_copy_quota_case(true);
}

fn current_api_send_raw_peer(sequence: u8) -> (quiche::Connection, SocketAddr, SocketAddr) {
    let local: SocketAddr = "127.0.0.1:4433".parse().unwrap();
    let remote: SocketAddr = format!("127.0.0.1:{}", 55_000 + sequence as u16)
        .parse()
        .unwrap();
    let mut config = stress_client_config();
    config.set_initial_max_streams_uni(8);
    let client = quiche::connect(
        Some("localhost"),
        &ConnectionId::from_ref(&[sequence; 16]),
        remote,
        local,
        &mut config,
    )
    .unwrap();
    (client, local, remote)
}

fn provider_send_h3_quota_case(bytes: usize, slots: usize, grease: bool) {
    let mut limits = proposed_send_limits();
    limits.control = quiche::SendLimit {
        backing_bytes: bytes,
        slots,
    };
    let (mut server, budget) = current_api_send_server(limits, grease);
    let (mut client, local, remote) = current_api_send_raw_peer(0xd3);
    let mut packet = [0; 65_535];
    let mut receive_errors = Vec::new();
    let until = std::time::Instant::now() + Duration::from_secs(3);
    while client.peer_error().is_none() && std::time::Instant::now() < until {
        for mut datagram in collect_client_datagrams(&mut client, &mut packet) {
            if let Err(error) = server.recv_datagram(&mut datagram, local, remote) {
                if !matches!(error, super::QuicServerError::Quiche(quiche::Error::Done)) {
                    receive_errors.push(format!("{error:?}"));
                }
            }
        }
        loop {
            match server.send(&mut packet) {
                Ok(Some((length, info))) => {
                    let _ = client.recv(
                        &mut packet[..length],
                        RecvInfo {
                            from: info.from,
                            to: info.to,
                        },
                    );
                }
                Ok(None) => break,
                Err(error) => panic!("constructor quota escaped send: {error:?}"),
            }
        }
        drive_timeouts(&mut client, &mut server);
        std::thread::sleep(Duration::from_millis(2));
    }
    eprintln!(
        "PROVIDER_H3_QUOTA bytes={bytes} slots={slots} errors={receive_errors:?} usage={:?}",
        budget.usage()
    );
    assert!(receive_errors.is_empty());
    assert_eq!(
        client.peer_error().map(|e| (e.is_app, e.error_code)),
        Some((false, 1))
    );
    for connection in server.connections.values() {
        assert!(connection.http3.is_none());
        assert!(connection.requests.is_empty() && connection.responses.is_empty());
    }
    drop(server);
    assert_eq!(budget.usage(), quiche::SendUsage::default());
}

#[test]
fn provider_send_h3_settings_partial_prefix_quota_is_local() {
    provider_send_h3_quota_case(1, 64, false);
}

#[test]
fn provider_send_h3_qpack_encoder_quota_is_local() {
    provider_send_h3_quota_case(65_536, 6, false);
}

#[test]
fn provider_send_h3_qpack_decoder_quota_is_local() {
    provider_send_h3_quota_case(65_536, 12, false);
}

#[test]
fn provider_send_h3_grease_stream_quota_is_local() {
    provider_send_h3_quota_case(65_536, 22, true);
}

#[test]
fn provider_send_crypto_accept_denial_refunds_and_keeps_admission_mutable() {
    let mut limits = proposed_send_limits();
    limits.crypto.slots = 4;
    let (mut server, budget) = current_api_send_server(limits, false);
    let (mut client, local, remote) = current_api_send_raw_peer(0xd4);
    let mut datagrams = collect_client_datagrams(&mut client, &mut [0; 65_535]);
    assert!(!datagrams.is_empty());
    for datagram in &mut datagrams {
        let result = server.recv_datagram(datagram, local, remote);
        eprintln!(
            "PROVIDER_SEND_ACCEPT_QUOTA result={result:?} usage={:?}",
            budget.usage()
        );
        assert!(matches!(
            result,
            Err(super::QuicServerError::Quiche(quiche::Error::Done))
        ));
    }
    assert!(server.connections.is_empty() && server.routes.is_empty());
    assert!(!server.receive_budget_locked);
    assert_eq!(budget.usage(), quiche::SendUsage::default());
}

#[test]
fn provider_send_quota_drops_connection_when_close_cannot_be_queued() {
    let (mut server, budget) = current_api_send_server(proposed_send_limits(), false);
    let mut peer = ReceiveBudgetPeer::new(&mut server, 0xd5);
    let stream = send_pool_get(&mut peer, b"/close-failure");
    send_pool_pump(&mut server, std::slice::from_mut(&mut peer));
    let request = server.next_request().unwrap();
    assert_eq!(request.stream_id, stream);
    let key = server.request_routes[&request.id].0.clone();
    assert!(server.enqueue_response(request.id, 200, Vec::new(), vec![b'x'; 4_096]));
    assert!(server.connections[&key].transport.local_error().is_none());

    peer.client.close(false, 0x1, b"peer close").unwrap();
    let local: SocketAddr = "127.0.0.1:4433".parse().unwrap();
    let mut packet = [0; 65_535];
    for mut datagram in collect_client_datagrams(&mut peer.client, &mut packet) {
        match server.recv_datagram(&mut datagram, local, peer.remote) {
            Ok(()) | Err(super::QuicServerError::Quiche(quiche::Error::Done)) => (),
            Err(error) => panic!("unexpected peer close: {error:?}"),
        }
    }
    assert!(server.connections[&key].transport.is_draining());
    assert!(server.connections[&key].transport.local_error().is_none());
    assert!(!server.connections[&key].responses.is_empty());

    server.terminate_send_quota(&key);
    assert!(!server.connections.contains_key(&key));
    assert_eq!(server.buffered_response_bytes, 0);
    assert_eq!(budget.usage(), quiche::SendUsage::default());
    assert_no_owned_provider_state(&server, &key);
}

#[test]
fn provider_send_initial_crypto_callback_denial_is_local_and_refunds() {
    let mut limits = proposed_send_limits();
    limits.crypto.backing_bytes = 0;
    let (mut server, budget) = current_api_send_server(limits, false);
    let (mut client, local, remote) = current_api_send_raw_peer(0xd5);
    let packets = collect_client_datagrams(&mut client, &mut [0; 65_535]);
    assert!(!packets.is_empty());
    for mut packet in packets {
        let result = server.recv_datagram(&mut packet, local, remote);
        eprintln!(
            "PROVIDER_SEND_INITIAL_QUOTA result={result:?} usage={:?}",
            budget.usage()
        );
        assert!(result.is_ok());
    }
    assert_eq!(server.connections.len(), 1);
    let key = server.connections.keys().next().unwrap().clone();
    let connection = &server.connections[&key];
    eprintln!(
        "PROVIDER_INITIAL_CLOSING recv={} closed={} local={:?} timeout={:?}",
        connection.transport.stats().recv,
        connection.transport.is_closed(),
        connection
            .transport
            .local_error()
            .map(|error| (error.is_app, error.error_code)),
        server.timeout()
    );
    assert_eq!(
        connection
            .transport
            .local_error()
            .map(|error| (error.is_app, error.error_code)),
        Some((false, 1))
    );
    assert!(!connection.transport.is_closed());
    assert!(connection.http3.is_none());
    assert!(connection.requests.is_empty() && connection.responses.is_empty());
    assert!(
        connection.header_deadlines.is_empty() && connection.indexed_request_deadlines.is_empty()
    );
    assert!(connection.request_route_ids.is_empty());
    assert!(server.requests.is_empty() && server.request_routes.is_empty());
    assert_eq!(server.buffered_request_bytes, 0);
    assert_eq!(server.buffered_response_bytes, 0);
    assert!(server.send_ready.queued.contains(&key));
    assert!(!server.response_ready.queued.contains(&key));
    assert!(!server.goaway_ready.queued.contains(&key));
    let mut packet = [0; 65_535];
    let mut sent = 0;
    while let Some((length, info)) = server.send(&mut packet).unwrap() {
        sent += 1;
        match client.recv(
            &mut packet[..length],
            RecvInfo {
                from: info.from,
                to: info.to,
            },
        ) {
            Ok(_) | Err(quiche::Error::Done) => (),
            Err(error) => panic!("Initial close receive: {error:?}"),
        }
    }
    assert!(sent > 0);
    eprintln!(
        "PROVIDER_INITIAL_CLOSE_WIRE packets={sent} peer={:?}",
        client
            .peer_error()
            .map(|error| (error.is_app, error.error_code))
    );
    assert_eq!(
        client
            .peer_error()
            .map(|error| (error.is_app, error.error_code)),
        Some((false, 1))
    );
    assert!(server.connections[&key].transport.is_draining());
    let until = std::time::Instant::now() + Duration::from_secs(10);
    while server.connections.contains_key(&key) && std::time::Instant::now() < until {
        std::thread::sleep(server.timeout().unwrap().min(Duration::from_millis(5)));
        server.on_timeout();
    }
    assert!(server.connections.is_empty() && server.routes.is_empty());
    assert_no_owned_provider_state(&server, &key);

    assert_eq!(budget.usage(), quiche::SendUsage::default());
}

#[test]
fn provider_send_final_goaway_quota_does_not_abort_shutdown() {
    let mut limits = proposed_send_limits();
    limits.control = quiche::SendLimit {
        backing_bytes: 12,
        slots: 64,
    };
    let (mut server, budget) = current_api_send_server(limits, false);
    server.http3_config.set_max_field_section_size(64);
    let mut peer = ReceiveBudgetPeer::new(&mut server, 0xd6);
    let until = std::time::Instant::now() + Duration::from_secs(3);
    while budget.usage().control.backing_bytes != 0 && std::time::Instant::now() < until {
        send_pool_pump(&mut server, std::slice::from_mut(&mut peer));
        std::thread::sleep(Duration::from_millis(2));
    }
    assert_eq!(budget.usage().control.backing_bytes, 0);
    assert!(server.begin_shutdown().is_ok());
    assert_eq!(budget.usage().control.backing_bytes, 10);
    let result = server.finish_shutdown();
    eprintln!(
        "PROVIDER_FINAL_GOAWAY_QUOTA result={result:?} usage={:?}",
        budget.usage()
    );
    assert!(result.is_ok());
    assert_eq!(
        server
            .connections
            .values()
            .next()
            .unwrap()
            .transport
            .local_error()
            .map(|e| (e.is_app, e.error_code)),
        Some((false, 1))
    );
    assert!(server.goaway_ready.entries.is_empty());
    assert!(server.close_connections().is_ok());
    send_pool_pump(&mut server, std::slice::from_mut(&mut peer));
    assert_eq!(
        peer.client.peer_error().map(|e| (e.is_app, e.error_code)),
        Some((false, 1))
    );
    drop(server);
    assert_eq!(budget.usage(), quiche::SendUsage::default());
}

#[test]
fn provider_send_real_packet_loss_quota_still_emits_close_and_serves_sibling() {
    let mut limits = proposed_send_limits();
    limits.request.backing_bytes = 6_144;
    let (mut server, budget) = current_api_send_server(limits, false);
    let mut peers = [
        ReceiveBudgetPeer::new(&mut server, 0xd7),
        ReceiveBudgetPeer::new(&mut server, 0xd8),
    ];
    let until = std::time::Instant::now() + Duration::from_secs(3);
    while (budget.usage().control.backing_bytes != 0 || budget.usage().crypto.backing_bytes != 0)
        && std::time::Instant::now() < until
    {
        send_pool_pump(&mut server, &mut peers);
        std::thread::sleep(Duration::from_millis(2));
    }
    assert_eq!(budget.usage().control.backing_bytes, 0);
    assert_eq!(budget.usage().crypto.backing_bytes, 0);
    let stream = send_pool_get(&mut peers[0], b"/loss");
    for _ in 0..8 {
        send_pool_pump(&mut server, &mut peers);
    }
    let request = server.next_request().unwrap();
    assert_eq!(request.stream_id, stream);
    let key = server.request_routes[&request.id].0.clone();
    assert!(server.enqueue_response(request.id, 200, Vec::new(), vec![b'x'; 4_096]));
    server.drive_responses().unwrap();
    assert_eq!(server.buffered_response_bytes, 0);
    assert!(budget.usage().request.backing_bytes >= 4_096);
    let mut packet = [0; 1_200];
    let mut target_packets = 0;
    loop {
        match server.send(&mut packet) {
            Ok(Some((length, info))) => {
                let index = peers.iter().position(|p| p.remote == info.to).unwrap();
                if index == 0 {
                    target_packets += 1;
                    if target_packets == 1 {
                        continue;
                    }
                }
                let _ = peers[index].client.recv(
                    &mut packet[..length],
                    RecvInfo {
                        from: info.from,
                        to: info.to,
                    },
                );
            }
            Ok(None) => break,
            Err(error) => panic!("quota before the deliberate loss: {error:?}"),
        }
    }
    assert!(
        target_packets >= 4,
        "packet-threshold loss fixture needs higher authenticated packets"
    );
    let local: SocketAddr = "127.0.0.1:4433".parse().unwrap();
    for mut datagram in collect_client_datagrams(&mut peers[0].client, &mut [0; 65_535]) {
        assert!(
            server
                .recv_datagram(&mut datagram, local, peers[0].remote)
                .is_ok()
        );
    }
    let mut escaped = None;
    for _ in 0..16 {
        match server.send(&mut packet) {
            Ok(Some((length, info))) => {
                let index = peers.iter().position(|p| p.remote == info.to).unwrap();
                let _ = peers[index].client.recv(
                    &mut packet[..length],
                    RecvInfo {
                        from: info.from,
                        to: info.to,
                    },
                );
            }
            Ok(None) => (),
            Err(error) => {
                escaped = Some(error);
                break;
            }
        }
        if server.connections[&key].transport.local_error().is_some() {
            break;
        }
    }
    eprintln!(
        "PROVIDER_LOSS_QUOTA packets={target_packets} lost={} escaped={escaped:?} usage={:?}",
        server.connections[&key].transport.stats().lost,
        budget.usage()
    );
    assert!(server.connections[&key].transport.stats().lost > 0);
    assert!(
        escaped.is_none(),
        "transport send quota must queue local close: {escaped:?}"
    );
    assert_eq!(
        server.connections[&key]
            .transport
            .local_error()
            .map(|e| (e.is_app, e.error_code)),
        Some((false, 1))
    );
    assert!(budget.usage().request.backing_bytes <= 6_144);
    let sibling_stream = send_pool_get(&mut peers[1], b"/after-loss");
    for _ in 0..8 {
        send_pool_pump(&mut server, &mut peers);
    }
    let sibling = server.next_request().unwrap();
    assert_eq!(sibling.stream_id, sibling_stream);
    assert!(server.enqueue_response(sibling.id, 200, Vec::new(), b"alive".to_vec()));
    let mut body = Vec::new();
    let mut finished = false;
    for _ in 0..32 {
        send_pool_pump(&mut server, &mut peers);
        finished |= send_pool_read(&mut peers[1], sibling_stream, &mut body);
        if finished {
            break;
        }
    }
    assert!(finished);
    assert_eq!(body, b"alive");
    assert!(peers[1].client.peer_error().is_none());
    assert_eq!(
        peers[0]
            .client
            .peer_error()
            .map(|e| (e.is_app, e.error_code)),
        Some((false, 1))
    );
    drop(server);
    assert_eq!(budget.usage(), quiche::SendUsage::default());
}

#[test]
fn provider_send_policy_keeps_ordinary_alpn_tls_error_classification() {
    let (mut server, budget) = current_api_send_server(proposed_send_limits(), false);
    server
        .config
        .set_application_protos(&[b"different"])
        .unwrap();
    let (mut client, local, remote) = current_api_send_raw_peer(0xd9);
    let mut tls_fail = false;
    for mut packet in collect_client_datagrams(&mut client, &mut [0; 65_535]) {
        match server.recv_datagram(&mut packet, local, remote) {
            Err(super::QuicServerError::Quiche(quiche::Error::TlsFail)) => tls_fail = true,
            Ok(()) | Err(super::QuicServerError::Quiche(quiche::Error::Done)) => (),
            Err(error) => panic!("ordinary ALPN failure changed classification: {error:?}"),
        }
    }
    assert!(tls_fail);
    drop(server);
    assert_eq!(budget.usage(), quiche::SendUsage::default());
}

#[test]
fn provider_send_policy_keeps_generic_h3_critical_done_application_close() {
    let (mut server, budget) = current_api_send_server(proposed_send_limits(), false);
    let local: SocketAddr = "127.0.0.1:4433".parse().unwrap();
    let remote: SocketAddr = "127.0.0.1:55210".parse().unwrap();
    let mut config = stress_client_config();
    config.set_initial_max_data(0);
    let mut client = quiche::connect(
        Some("localhost"),
        &ConnectionId::from_ref(&[0xda; 16]),
        remote,
        local,
        &mut config,
    )
    .unwrap();
    let mut packet = [0; 65_535];
    let until = std::time::Instant::now() + Duration::from_secs(3);
    while client.peer_error().is_none() && std::time::Instant::now() < until {
        for mut datagram in collect_client_datagrams(&mut client, &mut packet) {
            match server.recv_datagram(&mut datagram, local, remote) {
                Ok(()) | Err(super::QuicServerError::Quiche(quiche::Error::Done)) => (),
                Err(error) => panic!("critical Done classification changed: {error:?}"),
            }
        }
        loop {
            match server.send(&mut packet) {
                Ok(Some((length, info))) => {
                    let _ = client.recv(
                        &mut packet[..length],
                        RecvInfo {
                            from: info.from,
                            to: info.to,
                        },
                    );
                }
                Ok(None) => break,
                Err(error) => panic!("generic H3 close must remain sendable: {error:?}"),
            }
        }
        drive_timeouts(&mut client, &mut server);
        std::thread::sleep(Duration::from_millis(2));
    }
    let expected = (true, quiche::h3::WireErrorCode::InternalError as u64);
    let local_errors: Vec<_> = server
        .connections
        .values()
        .map(|connection| {
            connection
                .transport
                .local_error()
                .map(|error| (error.is_app, error.error_code))
        })
        .collect();
    eprintln!(
        "PROVIDER_GENERIC_H3_DONE peer={:?} local={local_errors:?}",
        client
            .peer_error()
            .map(|error| (error.is_app, error.error_code))
    );
    assert_eq!(local_errors, vec![Some(expected)]);
    assert_eq!(
        client.peer_error().map(|e| (e.is_app, e.error_code)),
        Some(expected)
    );
    drop(server);
    assert_eq!(budget.usage(), quiche::SendUsage::default());
}

fn public_send_close(
    server: &mut super::QuicServer,
    client: &mut quiche::Connection,
    local: SocketAddr,
    remote: SocketAddr,
) {
    let mut packet = [0; 65_535];
    let until = std::time::Instant::now() + Duration::from_secs(10);
    while client.peer_error().is_none() && std::time::Instant::now() < until {
        for mut datagram in collect_client_datagrams(client, &mut packet) {
            match server.recv_datagram(&mut datagram, local, remote) {
                Ok(()) | Err(super::QuicServerError::Quiche(quiche::Error::Done)) => (),
                Err(error) => panic!("public send limit receive: {error:?}"),
            }
        }
        while let Some((length, info)) = server.send(&mut packet).unwrap() {
            match client.recv(
                &mut packet[..length],
                RecvInfo {
                    from: info.from,
                    to: info.to,
                },
            ) {
                Ok(_) | Err(quiche::Error::Done) => (),
                Err(error) => panic!("public send limit close: {error:?}"),
            }
        }
        drive_timeouts(client, server);
        std::thread::sleep(Duration::from_millis(2));
    }
    assert_eq!(
        client
            .peer_error()
            .map(|error| (error.is_app, error.error_code)),
        Some((false, 1))
    );
}

fn public_send_request_zero(slots: bool) {
    let mut server = super::QuicServer::new(stress_server_config()).unwrap();
    let mut limits = super::default_send_limits();
    if slots {
        limits.request.slots = 0;
    } else {
        limits.request.backing_bytes = 0;
    }
    assert!(server.set_send_limits(limits));
    let mut peer = ReceiveBudgetPeer::new(&mut server, 0xe1);
    let id = send_pool_get(&mut peer, b"/public-zero");
    for _ in 0..8 {
        send_pool_pump(&mut server, std::slice::from_mut(&mut peer));
    }
    if slots {
        assert!(server.next_request().is_none());
    } else {
        let request = server.next_request().unwrap();
        assert_eq!(request.stream_id, id);
        assert!(server.enqueue_response(request.id, 200, Vec::new(), b"alive".to_vec()));
        server.drive_responses().unwrap();
    }
    public_send_close(
        &mut server,
        &mut peer.client,
        "127.0.0.1:4433".parse().unwrap(),
        peer.remote,
    );
    assert!(!server.set_send_limits(super::default_send_limits()));
    assert!(!server.set_receive_limits(super::default_receive_limits()));
}

#[test]
fn provider_send_public_request_zero_bytes_propagates() {
    public_send_request_zero(false);
}
#[test]
fn provider_send_public_request_zero_slots_propagates() {
    public_send_request_zero(true);
}

fn public_send_control_zero(slots: bool) {
    let mut server = super::QuicServer::new(stress_server_config()).unwrap();
    let mut limits = super::default_send_limits();
    if slots {
        limits.control.slots = 0;
    } else {
        limits.control.backing_bytes = 0;
    }
    assert!(server.set_send_limits(limits));
    let (mut client, local, remote) = current_api_send_raw_peer(0xe3);
    public_send_close(&mut server, &mut client, local, remote);
    assert!(
        server
            .connections
            .values()
            .all(|connection| connection.http3.is_none())
    );
    assert!(!server.set_send_limits(super::default_send_limits()));
}
#[test]
fn provider_send_public_control_zero_bytes_propagates() {
    public_send_control_zero(false);
}
#[test]
fn provider_send_public_control_zero_slots_propagates() {
    public_send_control_zero(true);
}

#[test]
fn provider_send_public_crypto_zero_bytes_closes_and_stays_locked_after_drop() {
    let mut server = super::QuicServer::new(stress_server_config()).unwrap();
    let mut limits = super::default_send_limits();
    limits.crypto.backing_bytes = 0;
    assert!(server.set_send_limits(limits));
    let (mut client, local, remote) = current_api_send_raw_peer(0xe5);
    public_send_close(&mut server, &mut client, local, remote);
    let key = server.connections.keys().next().unwrap().clone();
    let until = std::time::Instant::now() + Duration::from_secs(10);
    while server.connections.contains_key(&key) && std::time::Instant::now() < until {
        std::thread::sleep(server.timeout().unwrap().min(Duration::from_millis(5)));
        server.on_timeout();
    }
    assert!(server.connections.is_empty());
    assert_no_owned_provider_state(&server, &key);
    assert!(!server.set_send_limits(super::default_send_limits()));
    assert!(!server.set_receive_limits(super::default_receive_limits()));
}

#[test]
fn provider_send_public_crypto_zero_slots_restore_original_initial_and_sibling() {
    let mut server = super::QuicServer::new(stress_server_config()).unwrap();
    let mut limits = super::default_send_limits();
    limits.crypto.slots = 0;
    assert!(server.set_send_limits(limits));
    let (mut client, local, remote) = current_api_send_raw_peer(0xe6);
    let original_cid = client.source_id().as_ref().to_vec();
    let packets = collect_client_datagrams(&mut client, &mut [0; 65_535]);
    assert!(!packets.is_empty());
    for mut packet in packets.clone() {
        assert!(matches!(
            server.recv_datagram(&mut packet, local, remote),
            Err(super::QuicServerError::Quiche(quiche::Error::Done))
        ));
    }
    assert!(server.connections.is_empty() && server.routes.is_empty());
    assert!(server.set_send_limits(super::default_send_limits()));
    assert!(server.set_receive_limits(super::default_receive_limits()));
    for mut packet in packets {
        server.recv_datagram(&mut packet, local, remote).unwrap();
    }
    assert_eq!(server.connections.len(), 1);
    assert!(!server.set_send_limits(super::default_send_limits()));
    assert!(!server.set_receive_limits(super::default_receive_limits()));
    establish_http3_in_memory(
        &mut client,
        &mut server,
        &mut [0; 65_535],
        local,
        remote,
        false,
    );
    let http3 =
        quiche::h3::Connection::with_transport(&mut client, &quiche::h3::Config::new().unwrap())
            .unwrap();
    let mut original = ReceiveBudgetPeer {
        client,
        http3,
        remote,
        request_stream: 0,
    };
    for _ in 0..8 {
        send_pool_pump(&mut server, std::slice::from_mut(&mut original));
    }
    let sibling = ReceiveBudgetPeer::new(&mut server, 0xe7);
    let mut peers = [original, sibling];
    for index in 0..2 {
        let stream = send_pool_get(&mut peers[index], b"/restored");
        for _ in 0..8 {
            send_pool_pump(&mut server, &mut peers);
        }
        let request = server.next_request().unwrap();
        assert_eq!(request.stream_id, stream);
        assert!(server.enqueue_response(request.id, 200, Vec::new(), b"alive".to_vec()));
        let mut body = Vec::new();
        let mut finished = false;
        for _ in 0..32 {
            send_pool_pump(&mut server, &mut peers);
            finished |= send_pool_read(&mut peers[index], stream, &mut body);
            if finished {
                break;
            }
        }
        assert!(finished);
        assert_eq!(body, b"alive");
        assert!(peers[index].client.peer_error().is_none());
    }
    assert_eq!(
        peers[0].client.source_id().as_ref(),
        original_cid.as_slice()
    );
}
