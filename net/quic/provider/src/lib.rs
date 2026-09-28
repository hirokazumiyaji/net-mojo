use std::ffi::{CStr, c_char};
use std::ptr;

pub struct NetQuicServerConfig {
    _inner: quiche::Config,
}

#[unsafe(no_mangle)]
pub extern "C" fn net_quic_provider_version() -> *const c_char {
    c"0.29.3".as_ptr()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_config_new(
    certificate_path: *const c_char,
    private_key_path: *const c_char,
) -> *mut NetQuicServerConfig {
    if certificate_path.is_null() || private_key_path.is_null() {
        return ptr::null_mut();
    }

    let certificate_path = unsafe { CStr::from_ptr(certificate_path) };
    let private_key_path = unsafe { CStr::from_ptr(private_key_path) };
    let Some(certificate_path) = certificate_path.to_str().ok() else {
        return ptr::null_mut();
    };
    let Some(private_key_path) = private_key_path.to_str().ok() else {
        return ptr::null_mut();
    };

    let Ok(mut config) = quiche::Config::new(quiche::PROTOCOL_VERSION) else {
        return ptr::null_mut();
    };
    if config
        .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
        .is_err()
        || config
            .load_cert_chain_from_pem_file(certificate_path)
            .is_err()
        || config
            .load_priv_key_from_pem_file(private_key_path)
            .is_err()
    {
        return ptr::null_mut();
    }

    Box::into_raw(Box::new(NetQuicServerConfig { _inner: config }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_config_free(config: *mut NetQuicServerConfig) {
    if !config.is_null() {
        drop(unsafe { Box::from_raw(config) });
    }
}

#[cfg(test)]
mod tests {
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};

    use quiche::{ConnectionId, Header, RecvInfo};

    #[test]
    fn completes_http3_tls_handshake_over_quic_packets() {
        let certificate_path = std::env::var("NET_HTTP_TEST_CERT").unwrap();
        let private_key_path = std::env::var("NET_HTTP_TEST_KEY").unwrap();
        let mut server_config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        server_config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        server_config
            .load_cert_chain_from_pem_file(&certificate_path)
            .unwrap();
        server_config
            .load_priv_key_from_pem_file(&private_key_path)
            .unwrap();

        let mut client_config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
        client_config
            .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
            .unwrap();
        client_config.verify_peer(false);

        let client_address = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 54321);
        let server_address = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 4433);
        let client_scid = [0x31; 16];
        let server_scid = [0x52; 16];
        let mut client = quiche::connect(
            Some("localhost"),
            &ConnectionId::from_ref(&client_scid),
            client_address,
            server_address,
            &mut client_config,
        )
        .unwrap();

        let mut packet = [0; 65535];
        let (initial_length, _) = client.send(&mut packet).unwrap();
        let original_dcid = Header::from_slice(&mut packet[..initial_length], 16)
            .unwrap()
            .dcid
            .as_ref()
            .to_vec();
        let mut server = quiche::accept(
            &ConnectionId::from_ref(&server_scid),
            Some(&ConnectionId::from_ref(&original_dcid)),
            server_address,
            client_address,
            &mut server_config,
        )
        .unwrap();
        server
            .recv(
                &mut packet[..initial_length],
                RecvInfo {
                    from: client_address,
                    to: server_address,
                },
            )
            .unwrap();

        for _ in 0..8 {
            while let Ok((length, _)) = server.send(&mut packet) {
                client
                    .recv(
                        &mut packet[..length],
                        RecvInfo {
                            from: server_address,
                            to: client_address,
                        },
                    )
                    .unwrap();
            }
            while let Ok((length, _)) = client.send(&mut packet) {
                server
                    .recv(
                        &mut packet[..length],
                        RecvInfo {
                            from: client_address,
                            to: server_address,
                        },
                    )
                    .unwrap();
            }
            if client.is_established() && server.is_established() {
                break;
            }
        }

        assert!(client.is_established());
        assert!(server.is_established());
        assert_eq!(client.application_proto(), b"h3");
        assert_eq!(server.application_proto(), b"h3");
    }
}
