use net_quic_provider::*;
use std::ffi::CString;

pub const MAX_INPUT: usize = 8192;
pub const MAX_DATAGRAMS: usize = 32;

pub fn datagrams(mut input: &[u8]) -> impl Iterator<Item = &[u8]> {
    std::iter::from_fn(move || {
        if input.len() < 2 {
            return None;
        }
        let length = usize::from(u16::from_be_bytes([input[0], input[1]]));
        input = &input[2..];
        let length = length.min(input.len());
        let (packet, rest) = input.split_at(length);
        input = rest;
        Some(packet)
    })
    .take(MAX_DATAGRAMS)
}

pub fn receive(input: &[u8], certificate: &CString, key: &CString) -> usize {
    assert!(input.len() <= MAX_INPUT);
    let mut accepted = 0;
    unsafe {
        let config = net_quic_server_config_new(certificate.as_ptr(), key.as_ptr());
        assert!(
            !config.is_null(),
            "cannot load generated QUIC test certificate"
        );
        let server = net_quic_server_new(config);
        net_quic_server_config_free(config);
        assert!(!server.is_null());
        assert_eq!(net_quic_server_set_connection_limit(server, 4), 1);
        assert_eq!(
            net_quic_server_set_transport_memory_limit(server, 2 * 1024 * 1024),
            1
        );
        for packet in datagrams(input) {
            let mut packet = packet.to_vec();
            let status = net_quic_server_recv(
                server,
                packet.as_mut_ptr(),
                packet.len(),
                c"127.0.0.1:4433".as_ptr(),
                c"127.0.0.1:4444".as_ptr(),
            );
            assert!((-1..=1).contains(&status));
            accepted += usize::from(status == 1);
        }
        net_quic_server_free(server);
    }
    accepted
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn framing_preserves_binary_packets_and_truncated_tail() {
        let input = [0, 3, 0, 255, 128, 0, 0, 0, 9, 192, 1];
        assert_eq!(
            datagrams(&input).collect::<Vec<_>>(),
            vec![&[0, 255, 128][..], &[][..], &[192, 1][..]]
        );
        assert_eq!(datagrams(&[0]).count(), 0);
    }

    #[test]
    fn framing_caps_datagram_count() {
        assert_eq!(datagrams(&[0; MAX_INPUT]).count(), MAX_DATAGRAMS);
    }

    #[test]
    fn accepts_a_real_initial_packet_through_provider_abi() {
        let certificate = CString::new(std::env::var("NET_HTTP_TEST_CERT").unwrap()).unwrap();
        let key = CString::new(std::env::var("NET_HTTP_TEST_KEY").unwrap()).unwrap();
        let mut config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        config.verify_peer(false);
        let mut client = quiche::connect(
            Some("localhost"),
            &quiche::ConnectionId::from_ref(&[0x31; 16]),
            "127.0.0.1:4444".parse().unwrap(),
            "127.0.0.1:4433".parse().unwrap(),
            &mut config,
        )
        .unwrap();
        let mut packet = [0; 1500];
        let (length, _) = client.send(&mut packet).unwrap();
        let mut input = (length as u16).to_be_bytes().to_vec();
        input.extend_from_slice(&packet[..length]);
        assert_eq!(receive(&input, &certificate, &key), 1);
    }

    #[test]
    fn malformed_headers_are_normal_provider_rejections() {
        let certificate = CString::new(std::env::var("NET_HTTP_TEST_CERT").unwrap()).unwrap();
        let key = CString::new(std::env::var("NET_HTTP_TEST_KEY").unwrap()).unwrap();
        receive(
            &[0, 0, 0, 1, 192, 0, 5, 192, 0, 0, 0, 1],
            &certificate,
            &key,
        );
    }
}
