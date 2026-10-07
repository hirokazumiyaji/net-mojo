use std::time::Instant;
#[test]
fn provider_receive_default_bounds_locally_created_bidi_metadata() {
    let mut server = super::QuicServer::new(stress_server_config()).unwrap();
    let local: SocketAddr = "127.0.0.1:4433".parse().unwrap();
    let remote: SocketAddr = "127.0.0.1:54401".parse().unwrap();
    let mut config = stress_client_config();
    config.set_initial_max_streams_bidi(32_769);
    let mut client = quiche::connect(
        Some("localhost"),
        &ConnectionId::from_ref(&[0xb1; 16]),
        remote,
        local,
        &mut config,
    )
    .unwrap();
    let mut packet = [0; 65_535];
    establish_http3_in_memory(&mut client, &mut server, &mut packet, local, remote, false);
    let transport = &mut server.connections.values_mut().next().unwrap().transport;
    for sequence in 0..32_768 {
        assert_eq!(transport.stream_send(1 + sequence * 4, b"", false), Ok(0));
    }
    assert_eq!(
        transport.stream_send(1 + 32_768 * 4, b"", false),
        Err(quiche::Error::ReceiveBufferExceeded)
    );
}

struct ReceiveBudgetPeer {
    client: quiche::Connection,
    http3: quiche::h3::Connection,
    remote: SocketAddr,
    request_stream: u64,
}

impl ReceiveBudgetPeer {
    fn new(server: &mut super::QuicServer, sequence: u8) -> Self {
        let local: SocketAddr = "127.0.0.1:4433".parse().unwrap();
        let remote: SocketAddr = format!("127.0.0.1:{}", 54_500 + sequence as u16)
            .parse()
            .unwrap();
        let mut config = stress_client_config();
        let mut client = quiche::connect(
            Some("localhost"),
            &ConnectionId::from_ref(&[sequence; 16]),
            remote,
            local,
            &mut config,
        )
        .unwrap();
        establish_http3_in_memory(&mut client, server, &mut [0; 65535], local, remote, false);
        let http3 = quiche::h3::Connection::with_transport(
            &mut client,
            &quiche::h3::Config::new().unwrap(),
        )
        .unwrap();
        Self {
            client,
            http3,
            remote,
            request_stream: 0,
        }
    }

    fn open_body(&mut self, length: usize) {
        let content_length = length.to_string();
        self.request_stream = self
            .http3
            .send_request(
                &mut self.client,
                &[
                    quiche::h3::Header::new(b":method", b"POST"),
                    quiche::h3::Header::new(b":scheme", b"https"),
                    quiche::h3::Header::new(b":authority", b"localhost"),
                    quiche::h3::Header::new(b":path", b"/echo"),
                    quiche::h3::Header::new(b"content-length", content_length.as_bytes()),
                ],
                false,
            )
            .unwrap();
        let prefix = if length == 128 {
            vec![0, 0x40, 0x80]
        } else {
            vec![0, 2]
        };
        assert_eq!(
            self.client.stream_send(self.request_stream, &prefix, false),
            Ok(prefix.len())
        );
    }

    fn body_packets(&mut self, bytes: &[u8], fin: bool) -> Vec<Vec<u8>> {
        assert_eq!(
            self.client.stream_send(self.request_stream, bytes, fin),
            Ok(bytes.len())
        );
        let packets = collect_client_datagrams(&mut self.client, &mut [0; 65535]);
        assert!(!packets.is_empty());
        packets
    }
}

fn receive_budget_limits() -> quiche::ReceiveLimits {
    quiche::ReceiveLimits {
        request: quiche::ReceiveLimit {
            backing_bytes: 64,
            slots: 6,
        },
        control: quiche::ReceiveLimit {
            backing_bytes: 4096,
            slots: 32,
        },
        crypto: quiche::ReceiveLimit {
            backing_bytes: 16384,
            slots: 64,
        },
    }
}

fn receive_budget_pump(server: &mut super::QuicServer, peers: &mut [ReceiveBudgetPeer]) {
    let local: SocketAddr = "127.0.0.1:4433".parse().unwrap();
    let mut packet = [0; 65535];
    for peer in peers.iter_mut() {
        for datagram in collect_client_datagrams(&mut peer.client, &mut packet) {
            deliver_client_datagram(server, &datagram, local, peer.remote);
        }
    }
    while let Ok(Some((length, info))) = server.send(&mut packet) {
        let peer = peers
            .iter_mut()
            .find(|peer| peer.remote == info.to)
            .unwrap();
        let _ = peer.client.recv(
            &mut packet[..length],
            RecvInfo {
                from: info.from,
                to: info.to,
            },
        );
    }
    for peer in peers.iter_mut() {
        while peer.http3.poll(&mut peer.client).is_ok() {}
    }
}

#[test]
fn provider_receive_two_clients_share_cap_and_close_refunds() {
    let mut server = super::QuicServer::new(stress_server_config()).unwrap();
    assert!(server.set_receive_limits(receive_budget_limits()));
    let mut peers = [
        ReceiveBudgetPeer::new(&mut server, 0xb2),
        ReceiveBudgetPeer::new(&mut server, 0xb3),
    ];
    for (index, peer) in peers.iter_mut().enumerate() {
        peer.open_body(if index == 0 { 128 } else { 2 });
    }
    for _ in 0..8 {
        receive_budget_pump(&mut server, &mut peers);
    }
    assert_eq!(server.connections.len(), 2);
    assert_eq!(
        server.receive_budget.usage().request,
        quiche::ReceiveLimit {
            backing_bytes: 0,
            slots: 4
        }
    );
    let _missing_a = peers[0].body_packets(b"g", false);
    let local: SocketAddr = "127.0.0.1:4433".parse().unwrap();
    for packet in peers[0].body_packets(&[b'a'; 64], false) {
        deliver_client_datagram(&mut server, &packet, local, peers[0].remote);
    }
    assert_eq!(
        server.receive_budget.usage().request,
        quiche::ReceiveLimit {
            backing_bytes: 64,
            slots: 5
        }
    );
    let _missing_b = peers[1].body_packets(b"g", false);
    let key_b = server.routes[peers[1].client.destination_id().as_ref()].clone();
    for mut packet in peers[1].body_packets(b"b", true) {
        assert!(matches!(
            server.recv_datagram(&mut packet, local, peers[1].remote),
            Err(super::QuicServerError::Quiche(
                quiche::Error::ReceiveBufferExceeded
            ))
        ));
    }
    assert_eq!(
        server.receive_budget.usage().request,
        quiche::ReceiveLimit {
            backing_bytes: 64,
            slots: 5
        }
    );
    assert_eq!(
        server.connections[&key_b]
            .transport
            .local_error()
            .unwrap()
            .error_code,
        1
    );
    assert!(server.send_ready.entries.contains(&key_b));
    assert!(server.connections[&key_b].transport_deadline_at.is_some());
    assert!(server.connections[&key_b].responses.is_empty());
    assert!(!server.set_receive_limits(super::default_receive_limits()));

    peers[0]
        .http3
        .send_priority_update_for_request(
            &mut peers[0].client,
            peers[0].request_stream,
            &quiche::h3::Priority::new(0, false),
        )
        .unwrap();
    receive_budget_pump(&mut server, &mut peers);
    assert_eq!(server.receive_budget.usage().request.backing_bytes, 64);
    peers[0]
        .client
        .stream_shutdown(peers[0].request_stream, quiche::Shutdown::Write, 0x10c)
        .unwrap();
    for _ in 0..8 {
        receive_budget_pump(&mut server, &mut peers);
    }
    assert_eq!(server.receive_budget.usage().request.backing_bytes, 0);
    assert!(server
        .connections
        .contains_key(&server.routes[peers[0].client.destination_id().as_ref()]));
    let id = peers[0]
        .http3
        .send_request(
            &mut peers[0].client,
            &[
                quiche::h3::Header::new(b":method", b"GET"),
                quiche::h3::Header::new(b":scheme", b"https"),
                quiche::h3::Header::new(b":authority", b"localhost"),
                quiche::h3::Header::new(b":path", b"/after-budget"),
            ],
            true,
        )
        .unwrap();
    assert!(id > peers[0].request_stream);
    for _ in 0..8 {
        receive_budget_pump(&mut server, &mut peers);
    }
    let completed = server.next_request().unwrap();
    assert_eq!(completed.stream_id, id);
    assert!(completed.body.is_empty());
    assert!(server.enqueue_response(completed.id, 200, Vec::new(), b"alive".to_vec(), Vec::new()));
    for _ in 0..8 {
        receive_budget_pump(&mut server, &mut peers);
    }
    let deadline = Instant::now() + Duration::from_secs(3);
    while server.connections.contains_key(&key_b) && Instant::now() < deadline {
        std::thread::sleep(server.timeout().unwrap().min(Duration::from_millis(5)));
        server.on_timeout();
        receive_budget_pump(&mut server, &mut peers);
    }
    assert!(!server.connections.contains_key(&key_b));
    assert!(server.routes.values().all(|key| key != &key_b));
    assert!(server.request_routes.values().all(|(key, _)| key != &key_b));
    assert!(server
        .request_timeouts
        .iter()
        .all(|(_, key, _)| key != &key_b));
    assert!(server
        .response_timeouts
        .iter()
        .all(|(_, key, _)| key != &key_b));
    assert!(server
        .transport_timeouts
        .iter()
        .all(|(_, key)| key != &key_b));
    assert_eq!(server.connections.len(), 1);
    assert_eq!(server.buffered_request_bytes, 0);
    assert_eq!(
        server.receive_budget.usage().request,
        quiche::ReceiveLimit {
            backing_bytes: 0,
            slots: 0
        }
    );
    let mut next = ReceiveBudgetPeer::new(&mut server, 0xb4);
    next.open_body(128);
    for _ in 0..8 {
        receive_budget_pump(&mut server, std::slice::from_mut(&mut next));
    }
    let _missing = next.body_packets(b"g", false);
    for packet in next.body_packets(&[b'n'; 64], false) {
        deliver_client_datagram(&mut server, &packet, local, next.remote);
    }
    assert_eq!(
        server.receive_budget.usage().request,
        quiche::ReceiveLimit {
            backing_bytes: 64,
            slots: 3
        }
    );
    let budget = server.receive_budget.clone();
    drop(server);
    assert_eq!(budget.usage(), quiche::ReceiveUsage::default());
}

#[test]
fn provider_receive_accept_failure_refunds_and_does_not_freeze() {
    let mut server = super::QuicServer::new(stress_server_config()).unwrap();
    let mut limits = receive_budget_limits();
    limits.crypto.slots = 4;
    assert!(server.set_receive_limits(limits));
    let local: SocketAddr = "127.0.0.1:4433".parse().unwrap();
    let remote: SocketAddr = "127.0.0.1:54600".parse().unwrap();
    let mut config = stress_client_config();
    let mut client = quiche::connect(
        Some("localhost"),
        &ConnectionId::from_ref(&[0xc1; 16]),
        remote,
        local,
        &mut config,
    )
    .unwrap();
    let packets = collect_client_datagrams(&mut client, &mut [0; 65535]);
    assert!(!packets.is_empty());
    for mut packet in packets.clone() {
        assert!(matches!(
            server.recv_datagram(&mut packet, local, remote),
            Err(super::QuicServerError::Quiche(
                quiche::Error::CryptoBufferExceeded
            ))
        ));
    }
    assert!(server.connections.is_empty());
    assert!(server.routes.is_empty());
    assert_eq!(
        server.receive_budget.usage(),
        quiche::ReceiveUsage::default()
    );
    assert!(server.set_receive_limits(receive_budget_limits()));
    for packet in packets {
        deliver_client_datagram(&mut server, &packet, local, remote);
    }
    assert_eq!(server.connections.len(), 1);
    assert!(!server.set_receive_limits(super::default_receive_limits()));
    establish_http3_in_memory(
        &mut client,
        &mut server,
        &mut [0; 65535],
        local,
        remote,
        false,
    );
    server.finish_shutdown().unwrap();
    server.close_connections().unwrap();
    let key = server.connections.keys().next().unwrap().clone();
    let deadline = Instant::now() + Duration::from_secs(3);
    let mut packet = [0; 65535];
    while !server.connections.is_empty() && Instant::now() < deadline {
        while server
            .send(&mut packet)
            .is_ok_and(|packet| packet.is_some())
        {}
        std::thread::sleep(server.timeout().unwrap().min(Duration::from_millis(5)));
        server.on_timeout();
    }
    assert!(!server.connections.contains_key(&key));
    assert_eq!(
        server.receive_budget.usage(),
        quiche::ReceiveUsage::default()
    );
    assert!(!server.set_receive_limits(super::default_receive_limits()));
}

#[test]
fn provider_receive_local_h3_constructor_exhaustion_queues_close() {
    let mut server = super::QuicServer::new(stress_server_config()).unwrap();
    let mut limits = receive_budget_limits();
    limits.control.slots = 1;
    assert!(server.set_receive_limits(limits));
    let local: SocketAddr = "127.0.0.1:4433".parse().unwrap();
    let remote: SocketAddr = "127.0.0.1:54601".parse().unwrap();
    let mut config = stress_client_config();
    let mut client = quiche::connect(
        Some("localhost"),
        &ConnectionId::from_ref(&[0xc2; 16]),
        remote,
        local,
        &mut config,
    )
    .unwrap();
    let mut packet = [0; 65535];
    let mut exhausted = false;
    for _ in 0..32 {
        for mut datagram in collect_client_datagrams(&mut client, &mut packet) {
            match server.recv_datagram(&mut datagram, local, remote) {
                Ok(()) | Err(super::QuicServerError::Quiche(quiche::Error::Done)) => {}
                Err(super::QuicServerError::Http3(quiche::h3::Error::TransportError(
                    quiche::Error::ReceiveBufferExceeded,
                ))) => exhausted = true,
                Err(error) => panic!("unexpected constructor error: {error:?}"),
            }
        }
        if exhausted {
            break;
        }
        flush_server_to_client(&mut client, &mut server, &mut packet, remote);
    }
    assert!(exhausted);
    let connection = server.connections.values().next().unwrap();
    assert_eq!(
        connection
            .transport
            .local_error()
            .map(|error| (error.is_app, error.error_code)),
        Some((true, 0xff))
    );
    assert!(server
        .send_ready
        .entries
        .contains(server.connections.keys().next().unwrap()));
    flush_server_to_client(&mut client, &mut server, &mut packet, remote);
    assert_eq!(
        client
            .peer_error()
            .map(|error| (error.is_app, error.error_code)),
        Some((true, 0xff))
    );
    let deadline = Instant::now() + Duration::from_secs(3);
    while !server.connections.is_empty() && Instant::now() < deadline {
        std::thread::sleep(server.timeout().unwrap().min(Duration::from_millis(5)));
        server.on_timeout();
        while server
            .send(&mut packet)
            .is_ok_and(|packet| packet.is_some())
        {}
    }
    assert!(server.connections.is_empty());
    assert!(server.routes.is_empty());
    assert_eq!(
        server.receive_budget.usage(),
        quiche::ReceiveUsage::default()
    );
}

#[test]
fn provider_receive_crypto_initial_backing_rejection_reaps_and_freezes() {
    let mut server = super::QuicServer::new(stress_server_config()).unwrap();
    let mut limits = receive_budget_limits();
    limits.crypto.backing_bytes = 0;
    assert!(server.set_receive_limits(limits));
    let local: SocketAddr = "127.0.0.1:4433".parse().unwrap();
    let remote: SocketAddr = "127.0.0.1:54701".parse().unwrap();
    let mut config = stress_client_config();
    let mut client = quiche::connect(
        Some("localhost"),
        &ConnectionId::from_ref(&[0xc3; 16]),
        remote,
        local,
        &mut config,
    )
    .unwrap();
    let packets = collect_client_datagrams(&mut client, &mut [0; 65535]);
    assert!(!packets.is_empty());
    for mut packet in packets {
        assert!(matches!(
            server.recv_datagram(&mut packet, local, remote),
            Err(super::QuicServerError::Quiche(
                quiche::Error::CryptoBufferExceeded
            ))
        ));
    }
    assert!(server.connections.is_empty());
    assert!(server.routes.is_empty());
    assert!(server.transport_timeouts.is_empty());
    assert_eq!(
        server.receive_budget.usage(),
        quiche::ReceiveUsage::default()
    );
    assert!(!server.set_receive_limits(receive_budget_limits()));
    assert!(server.send(&mut [0; 65535]).unwrap().is_none());
}

#[test]
fn provider_receive_tls_progresses_with_full_request_pool() {
    let mut server = super::QuicServer::new(stress_server_config()).unwrap();
    assert!(server.set_receive_limits(receive_budget_limits()));
    let mut first = ReceiveBudgetPeer::new(&mut server, 0xc4);
    first.open_body(128);
    for _ in 0..8 {
        receive_budget_pump(&mut server, std::slice::from_mut(&mut first));
    }
    let _missing = first.body_packets(b"g", false);
    let local: SocketAddr = "127.0.0.1:4433".parse().unwrap();
    for packet in first.body_packets(&[b'a'; 64], false) {
        deliver_client_datagram(&mut server, &packet, local, first.remote);
    }
    assert_eq!(server.receive_budget.usage().request.backing_bytes, 64);
    let before = server.receive_budget.usage().crypto.slots;
    let second = ReceiveBudgetPeer::new(&mut server, 0xc5);
    assert!(second.client.is_established());
    assert!(second.client.peer_error().is_none());
    assert_eq!(server.receive_budget.usage().request.backing_bytes, 64);
    assert_eq!(server.receive_budget.usage().crypto.slots, before + 6);
    let budget = server.receive_budget.clone();
    drop(server);
    assert_eq!(budget.usage(), quiche::ReceiveUsage::default());
}
