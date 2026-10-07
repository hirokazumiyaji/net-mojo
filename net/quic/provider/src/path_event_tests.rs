fn nat_event_pump(
    server: &mut super::QuicServer,
    peer: &mut ReceiveBudgetPeer,
    wire_remote: SocketAddr,
) {
    let local: SocketAddr = "127.0.0.1:4433".parse().unwrap();
    let second: SocketAddr = "127.0.0.1:56002".parse().unwrap();
    let mut packet = [0; 65_535];
    drive_timeouts(&mut peer.client, server);
    loop {
        let length = match peer.client.send(&mut packet) {
            Ok((length, _)) => length,
            Err(quiche::Error::Done) => break,
            Err(error) => panic!("client send fixture failed: {error:?}"),
        };
        match server.recv_datagram(&mut packet[..length], local, wire_remote) {
            Ok(()) | Err(super::QuicServerError::Quiche(quiche::Error::Done)) => (),
            Err(error) => panic!("NAT datagram failed: {error:?}"),
        }
    }
    loop {
        match server.send(&mut packet) {
            Ok(Some((length, info))) => {
                assert_eq!(info.from, local);
                assert!(info.to == second || info.to == peer.remote);
                match peer.client.recv(
                    &mut packet[..length],
                    RecvInfo {
                        from: info.from,
                        to: peer.remote,
                    },
                ) {
                    Ok(_) | Err(quiche::Error::Done) => (),
                    Err(error) => panic!("NAT return datagram failed: {error:?}"),
                }
            }
            Ok(None) => break,
            Err(error) => panic!("provider send failed: {error:?}"),
        }
    }
}

fn nat_event_wait<F: Fn(&super::QuicServer, &ReceiveBudgetPeer) -> bool>(
    server: &mut super::QuicServer,
    peer: &mut ReceiveBudgetPeer,
    wire_remote: SocketAddr,
    ready: F,
) {
    let until = std::time::Instant::now() + Duration::from_secs(3);
    loop {
        nat_event_pump(server, peer, wire_remote);
        if ready(server, peer) {
            return;
        }
        assert!(
            std::time::Instant::now() < until,
            "NAT fixture premise timed out at {wire_remote}"
        );
        std::thread::sleep(Duration::from_millis(2));
    }
}

fn nat_event_read(
    peer: &mut ReceiveBudgetPeer,
    stream: u64,
    body: &mut Vec<u8>,
    status: &mut bool,
) -> bool {
    let mut finished = false;
    loop {
        match peer.http3.poll(&mut peer.client) {
            Ok((id, quiche::h3::Event::Headers { list, .. })) if id == stream => {
                assert!(
                    list.iter()
                        .any(|h| h.name() == b":status" && h.value() == b"200")
                );
                *status = true;
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

#[test]
fn provider_path_notifications_do_not_accumulate_across_validated_nat_rebinding() {
    let mut server = super::QuicServer::new(stress_server_config()).unwrap();
    let mut peer = ReceiveBudgetPeer::new(&mut server, 0xdb);
    let original_cid = peer.client.source_id().as_ref().to_vec();
    let destination_cid = peer.client.destination_id().as_ref().to_vec();
    let local: SocketAddr = "127.0.0.1:4433".parse().unwrap();
    let second: SocketAddr = "127.0.0.1:56002".parse().unwrap();
    let key = server.routes[&destination_cid].clone();
    peer.open_body(128);
    nat_event_wait(&mut server, &mut peer, second, |server, _| {
        server.connections[&key]
            .transport
            .is_path_validated(local, second)
            == Ok(true)
    });
    let mut last = second;
    for cycle in 0..64 {
        last = if cycle % 2 == 0 { peer.remote } else { second };
        assert_eq!(
            peer.client.stream_send(peer.request_stream, b"x", false),
            Ok(1)
        );
        nat_event_wait(&mut server, &mut peer, last, |server, peer| {
            let connection = &server.connections[&key];
            connection
                .requests
                .get(&peer.request_stream)
                .is_some_and(|request| request.body.len() == cycle + 1)
                && connection
                    .transport
                    .path_stats()
                    .any(|path| path.active && path.peer_addr == last)
        });
        assert_eq!(peer.client.source_id().as_ref(), original_cid.as_slice());
        assert_eq!(
            peer.client.destination_id().as_ref(),
            destination_cid.as_slice()
        );
        let transport = &server.connections[&key].transport;
        let stats: Vec<_> = transport.path_stats().collect();
        assert_eq!(stats.len(), 2);
        assert_eq!(stats.iter().filter(|path| path.active).count(), 1);
        assert_eq!(transport.is_path_validated(local, peer.remote), Ok(true));
        assert_eq!(transport.is_path_validated(local, second), Ok(true));
        assert!(transport.local_error().is_none());
    }
    assert_eq!(
        peer.client
            .stream_send(peer.request_stream, &[b'x'; 64], true),
        Ok(64)
    );
    nat_event_wait(&mut server, &mut peer, last, |server, _| {
        !server.requests.is_empty()
    });
    let request = server.next_request().unwrap();
    assert_eq!(request.stream_id, peer.request_stream);
    assert_eq!(request.body, vec![b'x'; 128]);
    assert!(server.enqueue_response(request.id, 200, Vec::new(), b"alive".to_vec(), Vec::new()));
    let mut body = Vec::new();
    let mut status = false;
    let mut finished = false;
    let until = std::time::Instant::now() + Duration::from_secs(3);
    while !finished {
        nat_event_pump(&mut server, &mut peer, last);
        finished |= nat_event_read(&mut peer, request.stream_id, &mut body, &mut status);
        assert!(
            finished || std::time::Instant::now() < until,
            "NAT response fixture timed out"
        );
        if !finished {
            std::thread::sleep(Duration::from_millis(2));
        }
    }
    assert!(status);
    assert_eq!(body, b"alive");
    assert!(peer.client.peer_error().is_none());
    assert_eq!(server.connections.len(), 1);
    let transport = &mut server.connections.get_mut(&key).unwrap().transport;
    let mut pending = Vec::new();
    while let Some(event) = transport.path_event_next() {
        pending.push(event);
    }
    let migrated = pending
        .iter()
        .filter(|event| matches!(event, quiche::PathEvent::PeerMigrated(..)))
        .count();
    eprintln!(
        "PROVIDER_NAT_EVENTS paths={} switches=64 retained_events={} peer_migrated={} events={pending:?}",
        transport.path_stats().count(),
        pending.len(),
        migrated
    );
    drop(peer);
    drop(server);
    assert!(
        pending.is_empty(),
        "provider must consume unused native notifications after affected transport operations"
    );
}
