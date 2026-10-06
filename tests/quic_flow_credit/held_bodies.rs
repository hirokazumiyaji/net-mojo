#[cfg(test)]
mod http3_independent_control_credit {
    use super::*;
    use crate as quiche;
    use crate::h3::NameValue;
    use std::collections::{BTreeMap, BTreeSet};
    use std::time::{Duration, Instant};
    include!("http3_flow_credit_settings.rs");

    struct Harness {
        pipe: test_utils::Pipe,
        client: h3::Connection,
        server: h3::Connection,
        budget: ReceiveBudget,
        headers: BTreeSet<u64>,
        bodies: BTreeMap<u64, Vec<u8>>,
        priority_seen: bool,
        finished: BTreeSet<u64>,
        response_headers: BTreeSet<u64>,
        response_bodies: BTreeMap<u64, Vec<u8>>,
        response_finished: BTreeSet<u64>,
        abandoned: Option<u64>,
        response_abandoned: bool,
    }
    impl Harness {
        fn new(lazy_qpack: bool) -> Self {
            let mut server_config = Config::new(PROTOCOL_VERSION).unwrap();
            apply_provider_quic_transport_settings(&mut server_config);
            server_config
                .set_application_protos(h3::APPLICATION_PROTOCOL)
                .unwrap();
            server_config
                .load_cert_chain_from_pem_file("examples/cert.crt")
                .unwrap();
            server_config
                .load_priv_key_from_pem_file("examples/cert.key")
                .unwrap();
            let budget = ReceiveBudget::new(default_receive_limits());
            server_config.set_receive_budget(budget.clone());
            let mut client_config = Config::new(PROTOCOL_VERSION).unwrap();
            client_config.set_initial_max_data(10_000_000);
            client_config.set_max_connection_window(24 * 1024 * 1024);
            client_config.set_max_stream_window(16 * 1024 * 1024);
            client_config.set_initial_max_stream_data_bidi_local(1_000_000);
            client_config.set_initial_max_stream_data_bidi_remote(1_000_000);
            client_config.set_initial_max_stream_data_uni(1_000_000);
            client_config.set_initial_max_streams_bidi(100);
            client_config.set_initial_max_streams_uni(3);
            client_config.set_max_idle_timeout(60_000);
            client_config
                .set_application_protos(h3::APPLICATION_PROTOCOL)
                .unwrap();
            client_config.verify_peer(false);
            let mut pipe = test_utils::Pipe::with_client_and_server_config(
                &mut client_config,
                &mut server_config,
            )
            .unwrap();
            pipe.handshake().unwrap();
            let mut h3config = h3::Config::new().unwrap();
            h3config.set_max_field_section_size(32_768);
            h3config.set_qpack_max_table_capacity(0);
            h3config.set_qpack_blocked_streams(0);
            let client = if lazy_qpack {
                h3::independent_control_credit_peer::control_only(&mut pipe.client, &h3config)
            } else {
                h3::Connection::with_transport(&mut pipe.client, &h3config).unwrap()
            };
            let server = h3::Connection::with_transport(&mut pipe.server, &h3config).unwrap();
            Self {
                pipe,
                client,
                server,
                budget,
                headers: BTreeSet::new(),
                bodies: BTreeMap::new(),
                priority_seen: false,
                finished: BTreeSet::new(),
                response_headers: BTreeSet::new(),
                response_bodies: BTreeMap::new(),
                response_finished: BTreeSet::new(),
                abandoned: None,
                response_abandoned: false,
            }
        }
        fn poll(&mut self, read_bodies: bool) {
            loop {
                match self.server.poll(&mut self.pipe.server) {
                    Ok((id, h3::Event::Headers { list, .. })) => {
                        assert!(list.iter().any(|h| h.name() == b":method"));
                        self.headers.insert(id);
                    }
                    Ok((id, h3::Event::PriorityUpdate)) => {
                        assert_eq!(
                            self.server.take_last_priority_update(id),
                            Ok(b"u=5".to_vec())
                        );
                        self.priority_seen = true;
                    }
                    Ok((id, h3::Event::Finished)) => {
                        self.finished.insert(id);
                    }
                    Ok((_, h3::Event::Data)) => (),
                    Err(h3::Error::Done) => break,
                    e => panic!("unexpected H3 server event {e:?}"),
                }
            }
            if read_bodies {
                for id in self.headers.clone() {
                    let mut buf = [0; 16384];
                    loop {
                        match self.server.recv_body(&mut self.pipe.server, id, &mut buf) {
                            Ok(n) => self
                                .bodies
                                .entry(id)
                                .or_default()
                                .extend_from_slice(&buf[..n]),
                            Err(h3::Error::Done) => break,
                            e => panic!("body read {id}: {e:?}"),
                        }
                    }
                }
            }
            loop {
                match self.client.poll(&mut self.pipe.client) {
                    Ok((id, h3::Event::Headers { list, .. })) => {
                        assert!(list
                            .iter()
                            .any(|h| h.name() == b":status" && h.value() == b"200"));
                        self.response_headers.insert(id);
                    }
                    Ok((id, h3::Event::Finished)) => {
                        self.response_finished.insert(id);
                    }
                    Ok((_, h3::Event::Data)) => (),
                    Err(h3::Error::Done) => break,
                    e => panic!("unexpected H3 client event {e:?}"),
                }
            }
            for id in self.response_headers.clone() {
                let mut buf = [0; 16384];
                loop {
                    match self.client.recv_body(&mut self.pipe.client, id, &mut buf) {
                        Ok(n) => self
                            .response_bodies
                            .entry(id)
                            .or_default()
                            .extend_from_slice(&buf[..n]),
                        Err(h3::Error::Done) => break,
                        e => panic!("client body {id}: {e:?}"),
                    }
                }
            }
        }
        fn drive(&mut self, read_bodies: bool) -> bool {
            let mut progress = false;
            for _ in 0..32 {
                let mut packet = [0; 65535];
                match self.pipe.client.send(&mut packet) {
                    Ok((n, info)) => {
                        std::thread::sleep(info.at.saturating_duration_since(Instant::now()));
                        let frames = test_utils::decode_pkt(
                            &mut self.pipe.server,
                            &mut packet[..n].to_vec(),
                        )
                        .unwrap();
                        if frames.iter().any(|f| {
                            matches!(
                                f,
                                frame::Frame::StopSending {
                                    stream_id: 0,
                                    error_code: 0x10c
                                }
                            )
                        }) {
                            self.response_abandoned = true;
                        }
                        assert!(matches!(
                            self.pipe.server_recv(&mut packet[..n]),
                            Ok(_) | Err(Error::Done)
                        ));
                        progress = true;
                    }
                    Err(Error::Done) => break,
                    e => panic!("client send {e:?}"),
                }
            }
            for _ in 0..32 {
                let mut packet = [0; 65535];
                match self.pipe.server.send(&mut packet) {
                    Ok((n, info)) => {
                        std::thread::sleep(info.at.saturating_duration_since(Instant::now()));
                        assert!(matches!(
                            self.pipe.client_recv(&mut packet[..n]),
                            Ok(_) | Err(Error::Done)
                        ));
                        progress = true;
                    }
                    Err(Error::Done) => break,
                    e => panic!("server send {e:?}"),
                }
            }
            self.poll(read_bodies);
            for c in [&mut self.pipe.client, &mut self.pipe.server] {
                if c.timeout() == Some(Duration::ZERO) {
                    c.on_timeout();
                    progress = true;
                }
            }
            assert!(!self.pipe.client.is_closed());
            assert!(!self.pipe.server.is_closed());
            if !progress {
                std::thread::sleep(Duration::from_millis(1));
            }
            progress
        }
    }
    fn verify_held_bodies(lazy_qpack: bool) {
        let mut h = Harness::new(lazy_qpack);
        let started = Instant::now();
        for _ in 0..40 {
            h.drive(false);
        }
        if lazy_qpack {
            let abandoned = h
                .client
                .send_request(
                    &mut h.pipe.client,
                    &[
                        h3::Header::new(b":method", b"GET"),
                        h3::Header::new(b":scheme", b"https"),
                        h3::Header::new(b":authority", b"localhost"),
                        h3::Header::new(b":path", b"/abandoned"),
                    ],
                    true,
                )
                .unwrap();
            assert_eq!(abandoned, 0);
            while !h.headers.contains(&abandoned) {
                assert!(started.elapsed() < Duration::from_secs(20));
                h.drive(false);
            }
            h.server
                .send_response(
                    &mut h.pipe.server,
                    abandoned,
                    &[h3::Header::new(b":status", b"200")],
                    false,
                )
                .unwrap();
            assert_eq!(
                h.server
                    .send_body(&mut h.pipe.server, abandoned, b"unfinished", false),
                Ok(10)
            );
            while h.response_bodies.get(&abandoned).map(Vec::len) != Some(10) {
                assert!(started.elapsed() < Duration::from_secs(20));
                h.drive(false);
            }
            h.abandoned = Some(abandoned);
            h.client
                .cancel_request(&mut h.pipe.client, abandoned, 0x10c)
                .unwrap();
            while !h.response_abandoned {
                assert!(started.elapsed() < Duration::from_secs(20));
                h.drive(false);
            }
            h.server
                .cancel_request(&mut h.pipe.server, abandoned, 0x10c)
                .unwrap();
            h.headers.remove(&abandoned);
            while h.budget.usage().request != ReceiveLimit::default() {
                assert!(started.elapsed() < Duration::from_secs(20));
                h.drive(false);
            }
            h.response_headers.remove(&abandoned);
            h.response_bodies.remove(&abandoned);
            assert_eq!(h.budget.usage().request, ReceiveLimit::default());
        }
        let body = vec![b'x'; 1 << 20];
        let request_headers = [
            h3::Header::new(b":method", b"POST"),
            h3::Header::new(b":scheme", b"https"),
            h3::Header::new(b":authority", b"localhost"),
            h3::Header::new(b":path", b"/echo"),
            h3::Header::new(b"content-length", b"1048576"),
        ];
        let mut sent = BTreeMap::new();
        for _ in 0..11 {
            let id = h
                .client
                .send_request(&mut h.pipe.client, &request_headers, false)
                .unwrap();
            sent.insert(id, 0usize);
        }
        while h.headers.len() != 11 {
            assert!(started.elapsed() < Duration::from_secs(20));
            h.drive(false);
        }
        let priority_required = 9u64;
        let mut turn = 0usize;
        loop {
            let connection_blocked =
                h.pipe.client.max_tx_data - h.pipe.client.tx_data < priority_required;
            let streams_blocked = sent
                .keys()
                .all(|id| h.pipe.client.streams.get(*id).unwrap().send.cap().unwrap() < 3);
            if (connection_blocked || streams_blocked)
                && h.pipe.server.rx_data == h.pipe.client.tx_data
            {
                break;
            }
            assert!(
                started.elapsed() < Duration::from_secs(60),
                "saturation timeout tx={} max={} rx={}",
                h.pipe.client.tx_data,
                h.pipe.client.max_tx_data,
                h.pipe.server.rx_data
            );
            let mut ids: Vec<_> = sent.keys().copied().collect();
            let count = ids.len();
            ids.rotate_left(turn % count);
            turn += 1;
            for id in ids {
                let written = sent.get_mut(&id).unwrap();
                if *written == body.len() {
                    continue;
                }
                let capacity = h.pipe.client.stream_capacity(id).unwrap();
                if capacity < 3 {
                    continue;
                }
                let mut want = (capacity - 2).min(16384).min(body.len() - *written);
                while want + 1 + octets::varint_len(want as u64) > capacity {
                    want -= 1;
                }
                let end = *written + want;
                match h.client.send_body(
                    &mut h.pipe.client,
                    id,
                    &body[*written..end],
                    end == body.len(),
                ) {
                    Ok(n) => *written += n,
                    Err(h3::Error::Done) | Err(h3::Error::StreamBlocked) => (),
                    e => panic!("client body {e:?}"),
                }
            }
            h.drive(false);
        }
        let control = 2;
        let stream_allowance = h
            .pipe
            .client
            .streams
            .get(control)
            .unwrap()
            .send
            .cap()
            .unwrap();
        let congestion_allowance = h
            .pipe
            .client
            .paths
            .get_active()
            .unwrap()
            .recovery
            .cwnd_available();
        let usage = h.budget.usage();
        println!("SATURATED rx={} max_data={} consumed={} window={} tx={} max_tx={} control_stream_remaining={} cwnd_remaining={} connection_remaining={} priority_required={} partial_body_sizes={:?} request={:?} control={:?} crypto={:?}",h.pipe.server.rx_data,h.pipe.server.max_rx_data(),h.pipe.server.flow_control.consumed(),h.pipe.server.flow_control.window(),h.pipe.client.tx_data,h.pipe.client.max_tx_data,stream_allowance,congestion_allowance,h.pipe.client.max_tx_data-h.pipe.client.tx_data,priority_required,sent,usage.request,usage.control,usage.crypto);

        assert!(h.pipe.server.flow_control.consumed() < 5_000_000);
        assert!(stream_allowance > 20);
        assert!(congestion_allowance > 20);
        assert!(sent.values().all(|n| *n > 0 && *n < body.len()));

        assert_eq!(h.pipe.client.stats().lost, 0);
        assert_eq!(h.pipe.server.stats().lost, 0);
        let priority = h3::Priority::new(5, false);
        assert_eq!(
            h.client.send_priority_update_for_request(
                &mut h.pipe.client,
                *sent.keys().next().unwrap(),
                &priority
            ),
            Ok(())
        );
        while !h.priority_seen {
            assert!(started.elapsed() < Duration::from_secs(60));
            h.drive(false);
        }
        if lazy_qpack {
            h3::independent_control_credit_peer::open_after_abandoned_response(
                &mut h.client,
                &mut h.pipe.client,
                h.abandoned.unwrap(),
            );
            while !h3::independent_control_credit_peer::assert_parsed(&h.server, &h.pipe.server) {
                assert!(started.elapsed() < Duration::from_secs(60));
                h.drive(false);
            }
            println!("QPACK_PROGRESS encoder_type2=1 decoder_type3_plus_cancellation=2 decoder_instruction_bytes=1 abandoned_response=0 held_body_reads=0");
        }
        assert!(h.bodies.is_empty());
        assert_eq!(h.budget.usage().request, usage.request);
        assert_eq!(h.pipe.server.max_rx_data(), 2 * 103 * 16 * 1024 * 1024);
        while sent.values().any(|n| *n != body.len())
            || h.bodies.values().filter(|b| b.len() == body.len()).count() != 11
            || !h.priority_seen
        {
            assert!(
                started.elapsed() < Duration::from_secs(90),
                "release timeout sent={sent:?} body_lengths={:?} priority={}",
                h.bodies
                    .iter()
                    .map(|(id, b)| (*id, b.len()))
                    .collect::<Vec<_>>(),
                h.priority_seen
            );
            for (id, written) in sent.iter_mut() {
                if *written == body.len() {
                    continue;
                }
                let end = (*written + 16384).min(body.len());
                match h.client.send_body(
                    &mut h.pipe.client,
                    *id,
                    &body[*written..end],
                    end == body.len(),
                ) {
                    Ok(n) => *written += n,
                    Err(h3::Error::Done) | Err(h3::Error::StreamBlocked) => (),
                    e => panic!("resume body {e:?}"),
                }
            }
            h.drive(true);
        }
        for got in h.bodies.values() {
            assert_eq!(got, &body);
        }
        println!(
            "RELEASED exact_bodies={} priority_seen={} rx={} consumed={} elapsed_ms={}",
            h.bodies.len(),
            h.priority_seen,
            h.pipe.server.rx_data,
            h.pipe.server.flow_control.consumed(),
            started.elapsed().as_millis()
        );
        let mut responses = BTreeMap::new();
        for id in sent.keys() {
            h.server
                .send_response(
                    &mut h.pipe.server,
                    *id,
                    &[h3::Header::new(b":status", b"200")],
                    false,
                )
                .unwrap();
            responses.insert(*id, 0usize);
        }
        while h.response_finished.len() < 11 {
            assert!(started.elapsed() < Duration::from_secs(90));
            for (id, written) in responses.iter_mut() {
                if *written == body.len() {
                    continue;
                }
                let end = (*written + 16384).min(body.len());
                match h.server.send_body(
                    &mut h.pipe.server,
                    *id,
                    &body[*written..end],
                    end == body.len(),
                ) {
                    Ok(n) => *written += n,
                    Err(h3::Error::Done) | Err(h3::Error::StreamBlocked) => (),
                    e => panic!("echo send {e:?}"),
                }
            }
            h.drive(true);
        }
        for id in sent.keys() {
            assert_eq!(h.response_bodies.get(id), Some(&body));
        }
        let reuse = h
            .client
            .send_request(
                &mut h.pipe.client,
                &[
                    h3::Header::new(b":method", b"GET"),
                    h3::Header::new(b":scheme", b"https"),
                    h3::Header::new(b":authority", b"localhost"),
                    h3::Header::new(b":path", b"/fixed"),
                ],
                true,
            )
            .unwrap();
        while !h.headers.contains(&reuse) {
            assert!(started.elapsed() < Duration::from_secs(90));
            h.drive(true);
        }
        h.server
            .send_response(
                &mut h.pipe.server,
                reuse,
                &[h3::Header::new(b":status", b"200")],
                false,
            )
            .unwrap();
        assert_eq!(
            h.server
                .send_body(&mut h.pipe.server, reuse, &[b'a'; 64], true),
            Ok(64)
        );
        while !h.response_finished.contains(&reuse) {
            assert!(started.elapsed() < Duration::from_secs(90));
            h.drive(true);
        }
        assert_eq!(h.response_bodies.get(&reuse), Some(&vec![b'a'; 64]));
        println!("COMPLETED exact_echoes=11 reuse_id={reuse} reuse_bytes=64 client_sent={} client_recv={} client_lost={} server_sent={} server_recv={} server_lost={} elapsed_ms={} receive_usage={:?}",h.pipe.client.stats().sent,h.pipe.client.stats().recv,h.pipe.client.stats().lost,h.pipe.server.stats().sent,h.pipe.server.stats().recv,h.pipe.server.stats().lost,started.elapsed().as_millis(),h.budget.usage());
        drop(h.client);
        drop(h.server);
        drop(h.pipe);
        assert_eq!(h.budget.usage(), ReceiveUsage::default());
    }
    #[test]
    fn held_request_bodies_preserve_control_progress_and_full_echoes() {
        verify_held_bodies(false);
    }
    #[test]
    fn held_request_bodies_preserve_lazy_qpack_types_and_cancellation() {
        verify_held_bodies(true);
    }
}
