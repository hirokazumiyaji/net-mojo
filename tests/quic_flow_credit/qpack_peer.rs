#[cfg(test)]
pub(crate) mod independent_control_credit_peer {
    use super::*;
    pub fn control_only(conn: &mut crate::Connection, config: &Config) -> Connection {
        let mut h3 = Connection::new(config, false, false).unwrap();
        h3.send_settings(conn).unwrap();
        h3
    }
    pub fn open_after_abandoned_response(h3: &mut Connection, conn: &mut crate::Connection, abandoned: u64) {
        assert_eq!(abandoned, 0);
        h3.open_qpack_encoder_stream(conn).unwrap();
        h3.open_qpack_decoder_stream(conn).unwrap();
        let decoder = h3.local_qpack_streams.decoder_stream_id.unwrap();
        assert_eq!(conn.stream_send(decoder, &[0x40], false), Ok(1));
    }
    pub fn assert_parsed(h3: &Connection, conn: &crate::Connection) -> bool {
        if h3.peer_qpack_streams.encoder_stream_id.is_none() || h3.peer_qpack_streams.decoder_stream_id.is_none() { return false; }
        assert_eq!(h3.peer_qpack_streams.encoder_stream_id, Some(6));
        assert_eq!(h3.peer_qpack_streams.decoder_stream_id, Some(10));
        let encoder = conn.streams.get(6).unwrap();
        let decoder = conn.streams.get(10).unwrap();
        if decoder.recv.off_front() != 2 { return false; }
        assert_eq!(encoder.recv.off_front(), 1);
        assert_eq!(h3.peer_qpack_streams.encoder_stream_bytes, 0);
        assert_eq!(h3.peer_qpack_streams.decoder_stream_bytes, 1);
        true
    }
}
