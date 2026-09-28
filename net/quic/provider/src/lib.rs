use std::collections::HashMap;
use std::ffi::{CStr, c_char};
use std::fs::File;
use std::io::{self, Read};
use std::net::SocketAddr;
use std::ptr;
use std::time::Duration;

use quiche::{Connection, ConnectionId, RecvInfo, SendInfo};

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

pub struct QuicServer {
    config: quiche::Config,
    connections: HashMap<Vec<u8>, Connection>,
    routes: HashMap<Vec<u8>, Vec<u8>>,
    random: File,
}

#[derive(Debug)]
pub enum QuicServerError {
    Io(io::Error),
    Quiche(quiche::Error),
}

impl From<io::Error> for QuicServerError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<quiche::Error> for QuicServerError {
    fn from(error: quiche::Error) -> Self {
        Self::Quiche(error)
    }
}

impl QuicServer {
    pub fn new(config: quiche::Config) -> io::Result<Self> {
        Ok(Self {
            config,
            connections: HashMap::new(),
            routes: HashMap::new(),
            random: File::open("/dev/urandom")?,
        })
    }

    pub fn recv_datagram(
        &mut self,
        packet: &mut [u8],
        local: SocketAddr,
        remote: SocketAddr,
    ) -> Result<(), QuicServerError> {
        let header = quiche::Header::from_slice(packet, 16)?;
        let destination_id = header.dcid.as_ref().to_vec();
        let key = match self.routes.get(&destination_id) {
            Some(key) => key.clone(),
            None if header.ty == quiche::Type::Initial => {
                let mut source_id = [0; 16];
                self.random.read_exact(&mut source_id)?;
                let source_id = ConnectionId::from_ref(&source_id);
                let connection = quiche::accept(
                    &source_id,
                    Some(&header.dcid),
                    local,
                    remote,
                    &mut self.config,
                )?;
                let key = source_id.as_ref().to_vec();
                self.routes.insert(destination_id, key.clone());
                self.routes.insert(key.clone(), key.clone());
                self.connections.insert(key.clone(), connection);
                key
            }
            None => return Err(quiche::Error::Done.into()),
        };

        let connection = self.connections.get_mut(&key).unwrap();
        connection.recv(
            packet,
            RecvInfo {
                from: remote,
                to: local,
            },
        )?;
        let source_ids: Vec<Vec<u8>> = connection
            .source_ids()
            .map(|source_id| source_id.as_ref().to_vec())
            .collect();
        for source_id in source_ids {
            self.routes.insert(source_id, key.clone());
        }
        Ok(())
    }

    pub fn send(
        &mut self,
        packet: &mut [u8],
    ) -> Result<Option<(usize, SendInfo)>, QuicServerError> {
        for connection in self.connections.values_mut() {
            match connection.send(packet) {
                Ok((length, info)) => return Ok(Some((length, info))),
                Err(quiche::Error::Done) => {}
                Err(error) => return Err(error.into()),
            }
        }
        Ok(None)
    }

    pub fn timeout(&self) -> Option<Duration> {
        self.connections
            .values()
            .filter_map(Connection::timeout)
            .min()
    }

    pub fn on_timeout(&mut self) {
        for connection in self.connections.values_mut() {
            if connection
                .timeout()
                .is_some_and(|timeout| timeout.is_zero())
            {
                connection.on_timeout();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::net::UdpSocket;
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};
    use std::time::Duration;

    use quiche::{ConnectionId, Header, RecvInfo};

    use super::QuicServer;

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

    #[test]
    fn drives_server_handshake_through_udp_datagrams() {
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

        let server_socket = UdpSocket::bind("127.0.0.1:0").unwrap();
        let client_socket = UdpSocket::bind("127.0.0.1:0").unwrap();
        server_socket
            .set_read_timeout(Some(Duration::from_millis(100)))
            .unwrap();
        client_socket
            .set_read_timeout(Some(Duration::from_millis(100)))
            .unwrap();
        let server_address = server_socket.local_addr().unwrap();
        let client_address = client_socket.local_addr().unwrap();
        let client_scid = [0x31; 16];
        let mut client = quiche::connect(
            Some("localhost"),
            &ConnectionId::from_ref(&client_scid),
            client_address,
            server_address,
            &mut client_config,
        )
        .unwrap();
        let mut server = QuicServer::new(server_config).unwrap();
        let mut packet = [0; 65535];

        for _ in 0..8 {
            while let Ok((length, _)) = client.send(&mut packet) {
                client_socket
                    .send_to(&packet[..length], server_address)
                    .unwrap();
            }
            if let Ok((length, peer)) = server_socket.recv_from(&mut packet) {
                server
                    .recv_datagram(&mut packet[..length], server_address, peer)
                    .unwrap();
            }
            while let Some((length, info)) = server.send(&mut packet).unwrap() {
                server_socket.send_to(&packet[..length], info.to).unwrap();
            }
            if let Ok((length, peer)) = client_socket.recv_from(&mut packet) {
                client
                    .recv(
                        &mut packet[..length],
                        RecvInfo {
                            from: peer,
                            to: client_address,
                        },
                    )
                    .unwrap();
            }
            if client.is_established() {
                break;
            }
        }

        assert!(client.is_established());
        assert_eq!(client.application_proto(), b"h3");
        assert!(server.timeout().is_some());
    }
}
