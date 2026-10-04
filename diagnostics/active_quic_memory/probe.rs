#[cfg(test)]
mod active_receive_allocation_diagnostic {
    use super::*;
    use std::alloc::{GlobalAlloc, Layout, System};
    use std::cell::Cell;
    use crate::range_buf::RangeBuf;
    use crate::stream::RecvBuf;

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
            if !ptr.is_null() { account(layout.size() as isize); }
            ptr
        }
        unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
            account(-(layout.size() as isize));
            unsafe { System.dealloc(ptr, layout) };
        }
        unsafe fn realloc(&self, ptr: *mut u8, old: Layout, size: usize) -> *mut u8 {
            let ptr = unsafe { System.realloc(ptr, old, size) };
            if !ptr.is_null() { account(size as isize - old.size() as isize); }
            ptr
        }
    }
    fn dropped_bytes<T>(value: T) -> isize {
        let before = LIVE.with(Cell::get);
        drop(value);
        before - LIVE.with(Cell::get)
    }

    const BODY: usize = 16 * 1024;
    const CHUNK: usize = 1024;
    #[derive(Clone, Copy, Debug)]
    enum Pattern { Contiguous, Sparse, Overlap }
    const PATTERNS: [Pattern; 3] = [Pattern::Contiguous, Pattern::Sparse, Pattern::Overlap];
    fn fragments(pattern: Pattern, mut write: impl FnMut(usize, &[u8], bool)) {
        let bytes = [b'b'; CHUNK];
        match pattern {
            Pattern::Contiguous => {
                let mut off = 1;
                while off < BODY {
                    let len = CHUNK.min(BODY - off);
                    write(off, &bytes[..len], false);
                    off += len;
                }
            },
            Pattern::Sparse => {
                for off in 1..BODY { write(off, &bytes[..1], false); }
            },
            Pattern::Overlap => {
                for off in 1..=BODY - CHUNK {
                    write(off, &bytes, false);
                }
            },
        }
    }
    fn expected(pattern: Pattern) -> (usize, usize, usize) {
        let nodes = match pattern {
            Pattern::Contiguous => (BODY - 1).div_ceil(CHUNK),
            Pattern::Sparse => BODY - 1,
            Pattern::Overlap => BODY - CHUNK,
        };
        let backing = if matches!(pattern, Pattern::Overlap) { nodes * CHUNK } else { BODY - 1 };
        (nodes, BODY - 1, backing)
    }

    #[test]
    fn low_level_equal_credit_different_retained_backing() {
        for pattern in PATTERNS {
            let mut recv = RecvBuf::new(1_000_000, 1_000_000, 16 * 1024 * 1024);
            fragments(pattern, |off, bytes, fin| recv.write(RangeBuf::from(bytes, off as u64, fin)).unwrap());
            assert_eq!(recv.max_off(), BODY as u64);
            assert_eq!(recv.diagnostic_retained(), expected(pattern));
            let retained = recv.diagnostic_retained();
            let dropped = dropped_bytes(recv);
            println!("LOW pattern={pattern:?} state=held nodes={} unique_body={} backing={} rust_drop={dropped}", retained.0, retained.1, retained.2);

            let mut recv = RecvBuf::new(1_000_000, 1_000_000, 16 * 1024 * 1024);
            fragments(pattern, |off, bytes, fin| recv.write(RangeBuf::from(bytes, off as u64, fin)).unwrap());
            recv.write(RangeBuf::from(b"b", 0, false)).unwrap();
            recv.write(RangeBuf::from(b"", BODY as u64, true)).unwrap();
            let mut body = [0; BODY];
            assert_eq!(recv.emit(&mut body), Ok((BODY, true)));
            assert_eq!(body, [b'b'; BODY]);
            assert_eq!(recv.diagnostic_retained(), (0, 0, 0));
            println!("LOW pattern={pattern:?} state=read nodes=0 unique_body=0 backing=0 rust_drop={}", dropped_bytes(recv));

            let mut recv = RecvBuf::new(1_000_000, 1_000_000, 16 * 1024 * 1024);
            fragments(pattern, |off, bytes, fin| recv.write(RangeBuf::from(bytes, off as u64, fin)).unwrap());
            recv.reset(0x10c, BODY as u64).unwrap();
            assert_eq!(recv.emit(&mut [0; 1]), Err(Error::StreamReset(0x10c)));
            assert_eq!(recv.diagnostic_retained(), (0, 0, 0));
            println!("LOW pattern={pattern:?} state=reset nodes=0 unique_body=0 backing=0 rust_drop={}", dropped_bytes(recv));
        }
    }

    fn configured_pipe() -> test_utils::Pipe {
        let mut config = test_utils::Pipe::default_config("reno").unwrap();
        config.set_application_protos(h3::APPLICATION_PROTOCOL).unwrap();
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
        let written = test_utils::encode_pkt(&mut pipe.client, Type::Short, &[frame], &mut packet).unwrap();
        // Receiver allocation is the subject; fabricated packets have no sender ACK history.
        pipe.server_recv(&mut packet[..written]).unwrap();
    }
    fn recv_summary(pipe: &test_utils::Pipe) -> (usize, usize, usize) {
        pipe.server.streams.get(0).map_or((0, 0, 0), |stream| stream.recv.diagnostic_retained())
    }

    #[derive(Clone, Copy, Debug)]
    enum End { Held, Read, Reset }
    fn authenticated_case(pattern: Pattern, end: End) -> isize {
        let mut pipe = configured_pipe();
        let mut h3_config = h3::Config::new().unwrap();
        h3_config.set_qpack_max_table_capacity(0);
        h3_config.set_qpack_blocked_streams(0);
        let mut client_h3 = h3::Connection::with_transport(&mut pipe.client, &h3_config).unwrap();
        let mut server_h3 = h3::Connection::with_transport(&mut pipe.server, &h3_config).unwrap();
        let headers = [
            h3::Header::new(b":method", b"POST"),
            h3::Header::new(b":scheme", b"https"),
            h3::Header::new(b":authority", b"quic.tech"),
            h3::Header::new(b":path", b"/"),
            h3::Header::new(b"content-length", b"16384"),
        ];
        assert_eq!(client_h3.send_request(&mut pipe.client, &headers, false), Ok(0));
        let mut data_header = [0; 16];
        let mut octets = octets::OctetsMut::with_slice(&mut data_header);
        octets.put_varint(0).unwrap();
        octets.put_varint(BODY as u64).unwrap();
        let prefix_len = octets.off();
        pipe.client.stream_send(0, &data_header[..prefix_len], false).unwrap();
        pipe.advance().unwrap();
        assert!(matches!(server_h3.poll(&mut pipe.server), Ok((0, h3::Event::Headers { .. }))));
        assert!(server_h3.peer_settings_raw().is_some());
        assert!(matches!(server_h3.poll(&mut pipe.server), Err(h3::Error::Done) | Ok((0, h3::Event::Data))));
        let base = pipe.server.streams.get(0).unwrap().recv.max_off();
        assert_eq!(pipe.server.stream_recv(0, &mut [0; 1]), Err(Error::Done));
        fragments(pattern, |off, bytes, fin| inject(&mut pipe, frame::Frame::Stream {
            stream_id: 0, data: RangeBuf::from(bytes, base + off as u64, fin),
        }));
        assert_eq!(recv_summary(&pipe), expected(pattern));
        assert_eq!(pipe.server.streams.get(0).unwrap().recv.max_off(), base + BODY as u64);
        assert_eq!(pipe.server.stream_recv(0, &mut [0; 1]), Err(Error::Done));
        match end {
            End::Held => (),
            End::Read => {
                inject(&mut pipe, frame::Frame::Stream { stream_id: 0, data: RangeBuf::from(b"b", base, false) });
                inject(&mut pipe, frame::Frame::Stream { stream_id: 0, data: RangeBuf::from(b"", base + BODY as u64, true) });
                let mut body = [0; BODY];
                let mut read = 0;
                while read < BODY {
                    match server_h3.poll(&mut pipe.server) {
                        Ok((0, h3::Event::Data)) | Err(h3::Error::Done) => (),
                        event => panic!("unexpected body event {event:?}"),
                    }
                    read += server_h3.recv_body(&mut pipe.server, 0, &mut body[read..]).unwrap();
                }
                assert_eq!(body, [b'b'; BODY]);
                assert_eq!(server_h3.poll(&mut pipe.server), Ok((0, h3::Event::Finished)));
                assert_eq!(recv_summary(&pipe), (0, 0, 0));
            },
            End::Reset => {
                inject(&mut pipe, frame::Frame::ResetStream { stream_id: 0, error_code: 0x10c, final_size: base + BODY as u64 });
                assert_eq!(server_h3.poll(&mut pipe.server), Ok((0, h3::Event::Reset(0x10c))));
                server_h3.cancel_request(&mut pipe.server, 0, 0x10c).unwrap();
                assert_eq!(recv_summary(&pipe), (0, 0, 0));
            },
        }
        let retained = recv_summary(&pipe);
        drop(server_h3);
        let test_utils::Pipe { client, server } = pipe;
        let dropped = dropped_bytes(server);
        println!("PACKET pattern={pattern:?} state={end:?} nodes={} unique_body={} backing={} server_transport_rust_drop={dropped}", retained.0, retained.1, retained.2);
        drop(client_h3);
        drop(client);
        dropped
    }

    #[test]
    fn authenticated_equal_body_credit_and_read_reset_release() {
        let mut held = Vec::new();
        for pattern in PATTERNS {
            held.push(authenticated_case(pattern, End::Held));
            let read = authenticated_case(pattern, End::Read);
            let reset = authenticated_case(pattern, End::Reset);
            assert!(read < *held.last().unwrap());
            assert!(reset < *held.last().unwrap());
        }
        assert!(held[1] > held[0]);
        assert!(held[2] > held[1]);
    }
}
