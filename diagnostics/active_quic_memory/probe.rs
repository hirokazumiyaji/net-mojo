#[cfg(test)]
mod active_receive_allocation_diagnostic {
    use super::*;
    use crate::range_buf::RangeBuf;
    use crate::receive_budget::ReceiveClass;
    use crate::stream::RecvBuf;
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
            let ptr = unsafe { System.realloc(ptr, old, size) };
            if !ptr.is_null() {
                account(size as isize - old.size() as isize);
            }
            ptr
        }
    }
    fn dropped_bytes<T>(value: T) -> isize {
        let before = LIVE.with(Cell::get);
        drop(value);
        before - LIVE.with(Cell::get)
    }

    const SIZES: [usize; 3] = [4 * 1024, 16 * 1024, 64 * 1024];
    const CHUNK: usize = 1024;
    #[derive(Clone, Copy, Debug)]
    enum Pattern {
        Contiguous,
        Sparse,
        Overlap,
    }
    const PATTERNS: [Pattern; 3] = [Pattern::Contiguous, Pattern::Sparse, Pattern::Overlap];
    fn fragments(pattern: Pattern, body_len: usize, mut write: impl FnMut(usize, &[u8], bool)) {
        let bytes = [b'b'; CHUNK];
        match pattern {
            Pattern::Contiguous => {
                let mut off = 1;
                while off < body_len {
                    let len = CHUNK.min(body_len - off);
                    write(off, &bytes[..len], false);
                    off += len;
                }
            }
            Pattern::Sparse => {
                for off in 1..body_len {
                    write(off, &bytes[..1], false);
                }
            }
            Pattern::Overlap => {
                for off in 1..=body_len - CHUNK {
                    write(off, &bytes, false);
                }
            }
        }
    }
    fn expected(pattern: Pattern, body_len: usize) -> (usize, usize, usize) {
        let nodes = match pattern {
            Pattern::Contiguous => (body_len - 1).div_ceil(CHUNK),
            Pattern::Sparse => body_len - 1,
            Pattern::Overlap => body_len - CHUNK,
        };
        let backing = body_len - 1;
        (nodes, body_len - 1, backing)
    }

    #[test]
    fn low_level_equal_credit_different_retained_backing() {
        for body_len in SIZES {
            for pattern in PATTERNS {
                let mut recv = RecvBuf::new(
                    1_000_000,
                    1_000_000,
                    16 * 1024 * 1024,
                    ReceiveBudget::default(),
                    ReceiveClass::Request,
                )
                .unwrap();
                fragments(pattern, body_len, |off, bytes, fin| {
                    recv.write(RangeBuf::from(bytes, off as u64, fin)).unwrap()
                });
                assert_eq!(recv.max_off(), body_len as u64);
                assert_eq!(recv.diagnostic_retained(), expected(pattern, body_len));
                let retained = recv.diagnostic_retained();
                let dropped = dropped_bytes(recv);
                println!("LOW size={body_len} pattern={pattern:?} state=held nodes={} unique_body={} backing={} rust_drop={dropped}", retained.0, retained.1, retained.2);

                let mut recv = RecvBuf::new(
                    1_000_000,
                    1_000_000,
                    16 * 1024 * 1024,
                    ReceiveBudget::default(),
                    ReceiveClass::Request,
                )
                .unwrap();
                fragments(pattern, body_len, |off, bytes, fin| {
                    recv.write(RangeBuf::from(bytes, off as u64, fin)).unwrap()
                });
                recv.write(RangeBuf::from(b"b", 0, false)).unwrap();
                recv.write(RangeBuf::from(b"", body_len as u64, true))
                    .unwrap();
                let mut body = vec![0; body_len];
                assert_eq!(recv.emit(&mut body), Ok((body_len, true)));
                assert_eq!(body, vec![b'b'; body_len]);
                assert_eq!(recv.diagnostic_retained(), (0, 0, 0));
                println!("LOW size={body_len} pattern={pattern:?} state=read nodes=0 unique_body=0 backing=0 rust_drop={}", dropped_bytes(recv));

                let mut recv = RecvBuf::new(
                    1_000_000,
                    1_000_000,
                    16 * 1024 * 1024,
                    ReceiveBudget::default(),
                    ReceiveClass::Request,
                )
                .unwrap();
                fragments(pattern, body_len, |off, bytes, fin| {
                    recv.write(RangeBuf::from(bytes, off as u64, fin)).unwrap()
                });
                recv.reset(0x10c, body_len as u64).unwrap();
                assert_eq!(recv.emit(&mut [0; 1]), Err(Error::StreamReset(0x10c)));
                assert_eq!(recv.diagnostic_retained(), (0, 0, 0));
                println!("LOW size={body_len} pattern={pattern:?} state=reset nodes=0 unique_body=0 backing=0 rust_drop={}", dropped_bytes(recv));
            }
        }
    }

    fn configured_pipe() -> test_utils::Pipe {
        let mut config = test_utils::Pipe::default_config("reno").unwrap();
        config
            .set_application_protos(h3::APPLICATION_PROTOCOL)
            .unwrap();
        config.set_initial_max_data(10_000_000);
        config.set_initial_max_stream_data_bidi_local(1_000_000);
        config.set_initial_max_stream_data_bidi_remote(1_000_000);
        config.set_initial_max_stream_data_uni(1_000_000);
        config.set_initial_max_streams_bidi(100);
        config.set_initial_max_streams_uni(3);
        let mut pipe = test_utils::Pipe::with_config(&mut config).unwrap();
        pipe.handshake().unwrap();
        pipe.advance().unwrap();
        pipe
    }

    fn inject(pipe: &mut test_utils::Pipe, frame: frame::Frame) {
        let mut packet = [0; 2048];
        let written =
            test_utils::encode_pkt(&mut pipe.client, Type::Short, &[frame], &mut packet).unwrap();
        // Receiver allocation is the subject; fabricated packets have no sender ACK history.
        pipe.server_recv(&mut packet[..written]).unwrap();
    }
    fn recv_summary(pipe: &test_utils::Pipe, id: u64) -> (usize, usize, usize) {
        pipe.server
            .streams
            .get(id)
            .map_or((0, 0, 0), |stream| stream.recv.diagnostic_retained())
    }

    fn start_requests(
        body_lens: &[usize],
    ) -> (
        test_utils::Pipe,
        h3::Connection,
        h3::Connection,
        Vec<(u64, u64, usize)>,
    ) {
        let mut pipe = configured_pipe();
        let mut h3_config = h3::Config::new().unwrap();
        h3_config.set_qpack_max_table_capacity(0);
        h3_config.set_qpack_blocked_streams(0);
        let mut client_h3 = h3::Connection::with_transport(&mut pipe.client, &h3_config).unwrap();
        let mut server_h3 = h3::Connection::with_transport(&mut pipe.server, &h3_config).unwrap();
        let mut ids = Vec::new();
        for &body_len in body_lens {
            let content_length = body_len.to_string();
            let headers = [
                h3::Header::new(b":method", b"POST"),
                h3::Header::new(b":scheme", b"https"),
                h3::Header::new(b":authority", b"quic.tech"),
                h3::Header::new(b":path", b"/"),
                h3::Header::new(b"content-length", content_length.as_bytes()),
            ];
            let id = client_h3
                .send_request(&mut pipe.client, &headers, false)
                .unwrap();
            let mut data_header = [0; 16];
            let mut octets = octets::OctetsMut::with_slice(&mut data_header);
            octets.put_varint(0).unwrap();
            octets.put_varint(body_len as u64).unwrap();
            let prefix_len = octets.off();
            pipe.client
                .stream_send(id, &data_header[..prefix_len], false)
                .unwrap();
            ids.push(id);
        }
        pipe.advance().unwrap();
        let mut observed = std::collections::HashSet::new();
        loop {
            match server_h3.poll(&mut pipe.server) {
                Ok((id, h3::Event::Headers { .. })) => {
                    assert!(ids.contains(&id));
                    assert!(observed.insert(id));
                }
                Ok((id, h3::Event::Data)) => assert!(ids.contains(&id)),
                Err(h3::Error::Done) => break,
                event => panic!("unexpected initial event {event:?}"),
            }
        }
        assert_eq!(observed.len(), ids.len());
        assert!(server_h3.peer_settings_raw().is_some());
        let requests = ids
            .into_iter()
            .zip(body_lens)
            .map(|(id, &size)| {
                let base = pipe.server.streams.get(id).unwrap().recv.max_off();
                assert_eq!(pipe.server.stream_recv(id, &mut [0; 1]), Err(Error::Done));
                (id, base, size)
            })
            .collect();
        (pipe, client_h3, server_h3, requests)
    }

    fn receive_body(
        pipe: &mut test_utils::Pipe,
        http3: &mut h3::Connection,
        id: u64,
        base: u64,
        size: usize,
    ) {
        inject(
            pipe,
            frame::Frame::Stream {
                stream_id: id,
                data: RangeBuf::from(b"b", base, false),
            },
        );
        inject(
            pipe,
            frame::Frame::Stream {
                stream_id: id,
                data: RangeBuf::from(b"", base + size as u64, true),
            },
        );
        let mut body = vec![0; size];
        let mut read = 0;
        while read < size {
            match http3.poll(&mut pipe.server) {
                Ok((event_id, h3::Event::Data)) if event_id == id => (),
                Err(h3::Error::Done) => (),
                event => panic!("unexpected body event {event:?}"),
            }
            read += http3
                .recv_body(&mut pipe.server, id, &mut body[read..])
                .unwrap();
        }
        assert_eq!(body, vec![b'b'; size]);
        assert_eq!(http3.poll(&mut pipe.server), Ok((id, h3::Event::Finished)));
    }

    #[derive(Clone, Copy, Debug)]
    enum End {
        Held,
        Read,
        Reset,
    }
    fn authenticated_case(pattern: Pattern, end: End, body_len: usize) -> isize {
        let (mut pipe, client_h3, mut server_h3, requests) = start_requests(&[body_len]);
        let base = requests[0].1;
        fragments(pattern, body_len, |off, bytes, fin| {
            inject(
                &mut pipe,
                frame::Frame::Stream {
                    stream_id: 0,
                    data: RangeBuf::from(bytes, base + off as u64, fin),
                },
            )
        });
        assert_eq!(recv_summary(&pipe, 0), expected(pattern, body_len));
        assert_eq!(
            pipe.server.streams.get(0).unwrap().recv.max_off(),
            base + body_len as u64
        );
        assert_eq!(pipe.server.stream_recv(0, &mut [0; 1]), Err(Error::Done));
        match end {
            End::Held => (),
            End::Read => {
                receive_body(&mut pipe, &mut server_h3, 0, base, body_len);
                assert_eq!(recv_summary(&pipe, 0), (0, 0, 0));
            }
            End::Reset => {
                inject(
                    &mut pipe,
                    frame::Frame::ResetStream {
                        stream_id: 0,
                        error_code: 0x10c,
                        final_size: base + body_len as u64,
                    },
                );
                assert_eq!(
                    server_h3.poll(&mut pipe.server),
                    Ok((0, h3::Event::Reset(0x10c)))
                );
                server_h3
                    .cancel_request(&mut pipe.server, 0, 0x10c)
                    .unwrap();
                assert_eq!(recv_summary(&pipe, 0), (0, 0, 0));
            }
        }
        let retained = recv_summary(&pipe, 0);
        drop(server_h3);
        let test_utils::Pipe { client, server } = pipe;
        let dropped = dropped_bytes(server);
        println!("PACKET size={body_len} pattern={pattern:?} state={end:?} nodes={} unique_body={} backing={} server_transport_rust_drop={dropped}", retained.0, retained.1, retained.2);
        drop(client_h3);
        drop(client);
        dropped
    }

    #[test]
    fn authenticated_equal_body_credit_and_read_reset_release() {
        for body_len in SIZES {
            let mut held = Vec::new();
            for pattern in PATTERNS {
                held.push(authenticated_case(pattern, End::Held, body_len));
                let read = authenticated_case(pattern, End::Read, body_len);
                let reset = authenticated_case(pattern, End::Reset, body_len);
                assert!(read < *held.last().unwrap());
                assert!(reset < *held.last().unwrap());
            }
            assert!(held[1] > held[0]);
            assert!(held[2] < held[1]);
        }
    }

    fn parts(recv: &RecvBuf) -> (usize, usize, usize, usize) {
        let (positive, terminal) = recv.diagnostic_slots();
        let (_, bytes, backing) = recv.diagnostic_retained();
        assert!(positive <= bytes);
        assert!(terminal <= 1);
        assert!(bytes <= backing);
        (positive, terminal, bytes, backing)
    }

    #[test]
    fn island_partial_duplicate_drain_and_terminal_conservation() {
        let mut recv = RecvBuf::new(
            100,
            100,
            100,
            ReceiveBudget::default(),
            ReceiveClass::Request,
        )
        .unwrap();
        assert_eq!(parts(&recv), (0, 0, 0, 0));
        recv.write(RangeBuf::from(b"cd", 2, false)).unwrap();
        recv.write(RangeBuf::from(b"gh", 6, false)).unwrap();
        recv.write(RangeBuf::from(b"kl", 10, false)).unwrap();
        assert_eq!(parts(&recv), (3, 0, 6, 6));
        recv.write(RangeBuf::from(b"abcdefghijklmn", 0, false))
            .unwrap();
        assert_eq!(parts(&recv), (7, 0, 14, 14));
        recv.write(RangeBuf::from(b"abcdefghijklmn", 0, false))
            .unwrap();
        assert_eq!(parts(&recv), (7, 0, 14, 14));
        let mut prefix = [0; 3];
        assert_eq!(recv.emit(&mut prefix), Ok((3, false)));
        assert_eq!(&prefix, b"abc");
        assert_eq!(parts(&recv), (6, 0, 11, 12));
        recv.write(RangeBuf::from(b"abcd", 0, false)).unwrap();
        assert_eq!(parts(&recv), (6, 0, 11, 12));
        assert_eq!(recv.shutdown(), Ok(11));
        assert_eq!(parts(&recv), (0, 0, 0, 0));
        recv.write(RangeBuf::from(b"op", 14, true)).unwrap();
        assert_eq!(recv.max_off(), 16);
        assert_eq!(parts(&recv), (0, 0, 0, 0));
        println!("CONSERVATION islands_positive=3 novel_slots=4 duplicate_delta=0 partial_positive=6 partial_view=11 partial_backing=12 drained=0");

        let mut terminal = RecvBuf::new(
            100,
            100,
            100,
            ReceiveBudget::default(),
            ReceiveClass::Request,
        )
        .unwrap();
        terminal.write(RangeBuf::from(b"", 5, true)).unwrap();
        assert_eq!(parts(&terminal), (0, 1, 0, 0));
        terminal.write(RangeBuf::from(b"", 5, true)).unwrap();
        assert_eq!(parts(&terminal), (0, 1, 0, 0));
        println!(
            "TERMINAL state=fin positive=0 terminal=1 view=0 backing=0 rust_drop={}",
            dropped_bytes(terminal)
        );

        let mut reset = RecvBuf::new(
            100,
            100,
            100,
            ReceiveBudget::default(),
            ReceiveClass::Request,
        )
        .unwrap();
        reset.write(RangeBuf::from(b"cd", 2, false)).unwrap();
        assert_eq!(parts(&reset), (1, 0, 2, 2));
        reset.reset(0x10c, 5).unwrap();
        assert_eq!(parts(&reset), (0, 1, 0, 0));
        println!("TERMINAL state=reset_marker positive=0 terminal=1 view=0 backing=0");
        assert_eq!(reset.emit(&mut [0; 1]), Err(Error::StreamReset(0x10c)));
        assert_eq!(parts(&reset), (0, 0, 0, 0));
        println!(
            "TERMINAL state=delivered positive=0 terminal=0 view=0 backing=0 rust_drop={}",
            dropped_bytes(reset)
        );
    }

    #[test]
    fn partial_front_backing_and_empty_container_are_distinct() {
        for state in ["partial", "read", "reset"] {
            let mut recv = RecvBuf::new(
                10_000,
                10_000,
                10_000,
                ReceiveBudget::default(),
                ReceiveClass::Request,
            )
            .unwrap();
            recv.write(RangeBuf::from(&[b'b'; CHUNK], 0, true)).unwrap();
            let mut prefix = [0; CHUNK - 1];
            assert_eq!(recv.emit(&mut prefix), Ok((CHUNK - 1, false)));
            assert_eq!(prefix, [b'b'; CHUNK - 1]);
            assert_eq!(parts(&recv), (1, 0, 1, CHUNK));
            match state {
                "partial" => (),
                "read" => {
                    let mut byte = [0; 1];
                    assert_eq!(recv.emit(&mut byte), Ok((1, true)));
                    assert_eq!(&byte, b"b");
                    assert_eq!(parts(&recv), (0, 0, 0, 0));
                }
                "reset" => {
                    recv.reset(0x10c, CHUNK as u64).unwrap();
                    assert_eq!(parts(&recv), (0, 0, 0, 0));
                }
                _ => unreachable!(),
            }
            let snapshot = parts(&recv);
            println!(
                "PARTIAL state={state} positive={} terminal={} view={} backing={} rust_drop={}",
                snapshot.0,
                snapshot.1,
                snapshot.2,
                snapshot.3,
                dropped_bytes(recv)
            );
        }
    }

    fn aggregate_case(phase: usize) {
        let (mut pipe, mut client_h3, mut server_h3, requests) =
            start_requests(&[16 * 1024, 4 * 1024]);
        for &(id, base, size) in &requests {
            fragments(Pattern::Sparse, size, |off, bytes, fin| {
                inject(
                    &mut pipe,
                    frame::Frame::Stream {
                        stream_id: id,
                        data: RangeBuf::from(bytes, base + off as u64, fin),
                    },
                )
            });
            assert_eq!(recv_summary(&pipe, id), expected(Pattern::Sparse, size));
            assert_eq!(
                pipe.server.streams.get(id).unwrap().recv.max_off(),
                base + size as u64
            );
            assert_eq!(pipe.server.stream_recv(id, &mut [0; 1]), Err(Error::Done));
        }
        let aggregate = |pipe: &test_utils::Pipe| -> (usize, usize, usize) {
            requests
                .iter()
                .map(|&(id, _, _)| recv_summary(pipe, id))
                .fold((0, 0, 0), |sum, current| {
                    (sum.0 + current.0, sum.1 + current.1, sum.2 + current.2)
                })
        };
        assert_eq!(aggregate(&pipe), (20_478, 20_478, 20_478));
        if phase >= 1 {
            let (id, base, size) = requests[0];
            receive_body(&mut pipe, &mut server_h3, id, base, size);
            assert_eq!(aggregate(&pipe), (4095, 4095, 4095));
        }
        if phase >= 2 {
            let (id, base, size) = requests[1];
            inject(
                &mut pipe,
                frame::Frame::ResetStream {
                    stream_id: id,
                    error_code: 0x10c,
                    final_size: base + size as u64,
                },
            );
            assert_eq!(
                server_h3.poll(&mut pipe.server),
                Ok((id, h3::Event::Reset(0x10c)))
            );
            server_h3
                .cancel_request(&mut pipe.server, id, 0x10c)
                .unwrap();
            assert_eq!(aggregate(&pipe), (0, 0, 0));
            let headers = [
                h3::Header::new(b":method", b"GET"),
                h3::Header::new(b":scheme", b"https"),
                h3::Header::new(b":authority", b"quic.tech"),
                h3::Header::new(b":path", b"/"),
            ];
            let next = client_h3
                .send_request(&mut pipe.client, &headers, true)
                .unwrap();
            assert_eq!(next, 8);
            let flight = test_utils::emit_flight(&mut pipe.client).unwrap();
            test_utils::process_flight(&mut pipe.server, flight).unwrap();
            assert!(matches!(
                server_h3.poll(&mut pipe.server),
                Ok((8, h3::Event::Headers { .. }))
            ));
            assert_eq!(
                server_h3.poll(&mut pipe.server),
                Ok((8, h3::Event::Finished))
            );
            server_h3
                .cancel_request(&mut pipe.server, next, 0x10c)
                .unwrap();
            println!("AGGREGATE next_request=8 headers_and_finished=true");
        }
        let retained = aggregate(&pipe);
        drop(server_h3);
        let test_utils::Pipe { client, server } = pipe;
        println!("AGGREGATE phase={phase} nodes={} unique_body={} backing={} server_transport_rust_drop={}", retained.0, retained.1, retained.2, dropped_bytes(server));
        drop(client_h3);
        drop(client);
    }

    #[test]
    fn two_held_requests_account_and_release_independently() {
        for phase in 0..=2 {
            aggregate_case(phase);
        }
    }
}
