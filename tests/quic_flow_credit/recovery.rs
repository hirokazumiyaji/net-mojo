#[cfg(test)]
mod http3_independent_control_credit_recovery {
    use super::*;
    use std::time::{Duration, Instant};

    const S: u64 = 4096;
    const R: u64 = (2 + 1) * S;
    const C: u64 = 2 * R;

    struct Harness {
        pipe: test_utils::Pipe,
        budget: ReceiveBudget,
        held: Vec<Vec<u8>>,
        withhold_max_data: bool,
        observed_stream_update: bool,
    }

    impl Harness {
        fn new() -> Self {
            let mut config = test_utils::Pipe::default_config("cubic").unwrap();
            config.set_initial_max_data(C);
            config.set_max_connection_window(C);
            config.set_max_stream_window(S);
            config.set_initial_max_stream_data_bidi_local(S);
            config.set_initial_max_stream_data_bidi_remote(S);
            config.set_initial_max_stream_data_uni(S);
            config.set_initial_max_streams_bidi(2);
            config.set_initial_max_streams_uni(1);
            let budget = ReceiveBudget::new(ReceiveLimits {
                request: ReceiveLimit {
                    backing_bytes: 64 * 1024,
                    slots: 256,
                },
                control: ReceiveLimit {
                    backing_bytes: 64 * 1024,
                    slots: 256,
                },
                crypto: ReceiveLimit {
                    backing_bytes: 1024 * 1024,
                    slots: 1024,
                },
            });
            config.set_receive_budget(budget.clone());
            let mut pipe = test_utils::Pipe::with_config(&mut config).unwrap();
            pipe.handshake().unwrap();
            let mut h = Self {
                pipe,
                budget,
                held: Vec::new(),
                withhold_max_data: false,
                observed_stream_update: false,
            };
            h.until(|h| h.pipe.client.stats().recv > 0);
            h
        }

        fn pump(&mut self) {
            for _ in 0..16 {
                let mut packet = [0; 65535];
                match self.pipe.client.send(&mut packet) {
                    Ok((n, info)) => {
                        std::thread::sleep(info.at.saturating_duration_since(Instant::now()));
                        assert!(matches!(
                            self.pipe.server_recv(&mut packet[..n]),
                            Ok(_) | Err(Error::Done)
                        ));
                    }
                    Err(Error::Done) => break,
                    e => panic!("client packet: {e:?}"),
                }
            }
            for _ in 0..16 {
                let mut packet = [0; 65535];
                match self.pipe.server.send(&mut packet) {
                    Ok((n, info)) => {
                        std::thread::sleep(info.at.saturating_duration_since(Instant::now()));
                        let frames = test_utils::decode_pkt(
                            &mut self.pipe.client,
                            &mut packet[..n].to_vec(),
                        )
                        .unwrap();
                        let max_data = frames.iter().find_map(|f| match f {
                            frame::Frame::MaxData { max } => Some(*max),
                            _ => None,
                        });
                        if self.withhold_max_data && max_data.is_some() {
                            println!("WITHHELD genuine_packet_bytes={n} max_data={max_data:?} frames={frames:?}");
                            self.held.push(packet[..n].to_vec());
                        } else {
                            if frames.iter().any(|f| {
                                matches!(f, frame::Frame::MaxStreamData { stream_id: 2, .. })
                            }) {
                                self.observed_stream_update = true;
                            }
                            assert!(matches!(
                                self.pipe.client_recv(&mut packet[..n]),
                                Ok(_) | Err(Error::Done)
                            ));
                        }
                    }
                    Err(Error::Done) => break,
                    e => panic!("server packet: {e:?}"),
                }
            }
            for conn in [&mut self.pipe.client, &mut self.pipe.server] {
                if conn.timeout() == Some(Duration::ZERO) {
                    conn.on_timeout();
                }
                assert!(!conn.is_closed());
            }
            std::thread::sleep(Duration::from_millis(1));
        }

        fn until(&mut self, condition: impl Fn(&Self) -> bool) {
            let started = Instant::now();
            while !condition(self) {
                assert!(started.elapsed() < Duration::from_secs(3));
                self.pump();
            }
        }

        fn send(&mut self, id: u64, n: usize, fin: bool) {
            assert_eq!(self.pipe.client.stream_send(id, &vec![b'b'; n], fin), Ok(n));
            let expected = self.pipe.client.tx_data;
            self.until(|h| h.pipe.server.rx_data == expected);
        }

        fn read(&mut self, id: u64, n: usize, fin: bool) {
            let mut buf = [0; 8192];
            assert_eq!(self.pipe.server.stream_recv(id, &mut buf), Ok((n, fin)));
            assert_eq!(&buf[..n], vec![b'b'; n]);
        }

        fn blocked_old_peer_limit(&mut self) {
            self.send(0, S as usize, true);
            self.read(0, S as usize, true);
            assert_eq!(self.pipe.server.stream_send(0, b"", true), Ok(0));
            self.until(|h| h.pipe.client.stream_readable(0));
            assert_eq!(self.pipe.client.stream_recv(0, &mut [0; 1]), Ok((0, true)));
            self.until(|h| h.pipe.client.peer_streams_left_bidi() == 2);
            self.send(4, S as usize, false);
            self.send(8, S as usize, false);
            for _ in 0..2 {
                self.send(2, S as usize, false);
                self.read(2, S as usize, false);
                self.until(|h| {
                    h.pipe.client.streams.get(2).unwrap().send.cap().unwrap() == S as usize
                });
            }
            assert_eq!(self.pipe.server.flow_control.consumed(), R);
            assert_eq!(self.pipe.server.max_rx_data(), C);
            assert!(!self.pipe.server.flow_control.should_update_max_data());
            self.withhold_max_data = true;
            self.observed_stream_update = false;
            self.send(2, 1, false);
            self.read(2, 1, false);
            self.until(|h| !h.held.is_empty());
            assert_eq!(self.pipe.server.max_rx_data(), R + 1 + C);
            assert_eq!(self.pipe.client.max_tx_data, C);
            self.send(2, S as usize - 1, false);
            self.read(2, S as usize - 1, false);
            self.until(|h| h.observed_stream_update);
            assert_eq!(self.pipe.client.tx_data, C);
            assert_eq!(
                self.pipe.client.streams.get(2).unwrap().send.cap().unwrap(),
                S as usize
            );
            assert_eq!(
                self.pipe.client.stream_send(2, b"c", false),
                Err(Error::Done)
            );
            assert_eq!(
                self.pipe.server.rx_data - self.pipe.server.flow_control.consumed(),
                2 * S
            );
            println!("OLD_LIMIT_BLOCKED max_tx={} tx={} uni_allowance={} held_request_exposure={} consumed={} committed_max={} held_packets={}", self.pipe.client.max_tx_data, self.pipe.client.tx_data, self.pipe.client.streams.get(2).unwrap().send.cap().unwrap(), 2 * S, self.pipe.server.flow_control.consumed(), self.pipe.server.max_rx_data(), self.held.len());
        }

        fn control_and_replacement(mut self) {
            assert_eq!(self.pipe.client.stream_send(2, b"c", false), Ok(1));
            self.until(|h| h.pipe.server.stream_readable(2));
            assert_eq!(self.pipe.server.stream_recv(2, &mut [0; 1]), Ok((1, false)));
            assert_eq!(
                self.pipe.server.rx_data - self.pipe.server.flow_control.consumed(),
                2 * S
            );
            let consumed = self.pipe.server.flow_control.consumed();
            assert_eq!(
                self.pipe.client.stream_shutdown(4, Shutdown::Write, 77),
                Ok(())
            );
            self.until(|h| h.pipe.server.flow_control.consumed() == consumed + S);
            assert_eq!(
                self.pipe.server.stream_recv(4, &mut [0; 1]),
                Err(Error::StreamReset(77))
            );
            assert_eq!(self.pipe.server.stream_send(4, b"", true), Ok(0));
            self.until(|h| h.pipe.client.stream_readable(4));
            assert_eq!(self.pipe.client.stream_recv(4, &mut [0; 1]), Ok((0, true)));
            self.until(|h| h.pipe.client.peer_streams_left_bidi() == 1);
            self.send(12, S as usize, false);
            assert_eq!(
                self.pipe.server.rx_data - self.pipe.server.flow_control.consumed(),
                2 * S
            );
            assert_eq!(self.pipe.client.stream_send(2, b"d", false), Ok(1));
            self.until(|h| h.pipe.server.stream_readable(2));
            assert_eq!(self.pipe.server.stream_recv(2, &mut [0; 1]), Ok((1, false)));
            println!("REPLACED reset_stream=4 replacement=12 held_request_exposure={} control_progress=2 lost={}", 2 * S, self.pipe.server.stats().lost);
            let budget = self.budget.clone();
            drop(self.pipe);
            assert_eq!(budget.usage(), ReceiveUsage::default());
        }
    }

    #[test]
    fn reordered_max_data_restores_control_after_half_boundary_and_replacement() {
        let mut h = Harness::new();
        h.blocked_old_peer_limit();
        h.withhold_max_data = false;
        let mut packet = h.held.remove(0);
        assert!(matches!(
            h.pipe.client_recv(&mut packet),
            Ok(_) | Err(Error::Done)
        ));
        assert_eq!(h.pipe.client.max_tx_data, R + 1 + C);
        h.control_and_replacement();
    }

    #[test]
    fn lost_max_data_recovers_from_genuine_ping_acks_without_request_reads() {
        let mut h = Harness::new();
        h.blocked_old_peer_limit();
        let lost_before = h.pipe.server.stats().lost;
        h.held.clear();
        h.withhold_max_data = false;
        for _ in 0..4 {
            h.pipe.server.send_ack_eliciting().unwrap();
            for _ in 0..3 {
                h.pump();
            }
        }
        h.until(|h| h.pipe.client.max_tx_data > C);
        assert!(h.pipe.server.stats().lost > lost_before);
        assert_eq!(
            h.pipe.server.rx_data - h.pipe.server.flow_control.consumed(),
            2 * S
        );
        println!(
            "RECOVERED max_tx={} genuine_ack_loss_delta={}",
            h.pipe.client.max_tx_data,
            h.pipe.server.stats().lost - lost_before
        );
        h.control_and_replacement();
    }
}
