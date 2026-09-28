use std::collections::HashMap;
use std::ffi::{CStr, c_char};
use std::fs::File;
use std::io::{self, Read};
use std::net::SocketAddr;
use std::ptr;
use std::slice;
use std::time::Duration;

use quiche::{Connection, ConnectionId, RecvInfo, SendInfo};

pub struct NetQuicServerConfig {
    _inner: Option<quiche::Config>,
}

pub struct NetQuicServer {
    _inner: QuicServer,
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

    Box::into_raw(Box::new(NetQuicServerConfig {
        _inner: Some(config),
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_config_free(config: *mut NetQuicServerConfig) {
    if !config.is_null() {
        drop(unsafe { Box::from_raw(config) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_new(
    config: *mut NetQuicServerConfig,
) -> *mut NetQuicServer {
    if config.is_null() {
        return ptr::null_mut();
    }
    let Some(config) = (unsafe { (*config)._inner.take() }) else {
        return ptr::null_mut();
    };
    let Ok(server) = QuicServer::new(config) else {
        return ptr::null_mut();
    };
    Box::into_raw(Box::new(NetQuicServer { _inner: server }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_free(server: *mut NetQuicServer) {
    if !server.is_null() {
        drop(unsafe { Box::from_raw(server) });
    }
}

unsafe fn socket_address(address: *const c_char) -> Option<SocketAddr> {
    let address = unsafe { CStr::from_ptr(address) }.to_str().ok()?;
    address.parse().ok()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_recv(
    server: *mut NetQuicServer,
    packet: *mut u8,
    packet_length: usize,
    local_address: *const c_char,
    remote_address: *const c_char,
) -> i32 {
    if server.is_null() || packet.is_null() || packet_length == 0 {
        return -1;
    }
    if local_address.is_null() || remote_address.is_null() {
        return -1;
    }
    let Some(local_address) = (unsafe { socket_address(local_address) }) else {
        return -1;
    };
    let Some(remote_address) = (unsafe { socket_address(remote_address) }) else {
        return -1;
    };
    let packet = unsafe { slice::from_raw_parts_mut(packet, packet_length) };
    match unsafe { &mut *server }
        ._inner
        .recv_datagram(packet, local_address, remote_address)
    {
        Ok(()) => 1,
        Err(QuicServerError::Quiche(quiche::Error::Done)) => 0,
        Err(_) => -1,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_send(
    server: *mut NetQuicServer,
    packet: *mut u8,
    packet_capacity: usize,
    remote_address: *mut c_char,
    address_capacity: usize,
) -> i32 {
    if server.is_null()
        || packet.is_null()
        || packet_capacity == 0
        || remote_address.is_null()
        || address_capacity < 64
    {
        return -1;
    }
    let packet = unsafe { slice::from_raw_parts_mut(packet, packet_capacity) };
    let (length, info) = match (unsafe { &mut *server })._inner.send(packet) {
        Ok(Some(packet)) => packet,
        Ok(None) => return 0,
        Err(_) => return -1,
    };
    let address = info.to.to_string();
    let address_bytes = address.as_bytes();
    if address_bytes.len() + 1 > address_capacity {
        return -1;
    }
    unsafe {
        ptr::copy_nonoverlapping(
            address_bytes.as_ptr(),
            remote_address.cast::<u8>(),
            address_bytes.len(),
        );
        *remote_address.add(address_bytes.len()) = 0;
    }
    i32::try_from(length).unwrap_or(-1)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_timeout_micros(server: *const NetQuicServer) -> u64 {
    if server.is_null() {
        return u64::MAX;
    }
    unsafe { &*server }
        ._inner
        .timeout()
        .map(|timeout| u64::try_from(timeout.as_micros()).unwrap_or(u64::MAX - 1))
        .unwrap_or(u64::MAX)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn net_quic_server_on_timeout(server: *mut NetQuicServer) {
    if !server.is_null() {
        unsafe { &mut *server }._inner.on_timeout();
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
    use std::ffi::{CStr, CString, c_char};
    use std::net::UdpSocket;
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};
    use std::time::Duration;

    use quiche::{ConnectionId, Header, RecvInfo};

    use super::{NetQuicServerConfig, net_quic_server_free, net_quic_server_new};

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
        let config = Box::into_raw(Box::new(NetQuicServerConfig {
            _inner: Some(server_config),
        }));
        let server = unsafe { net_quic_server_new(config) };
        assert!(!server.is_null());
        let mut packet = [0; 65535];

        for _ in 0..8 {
            while let Ok((length, _)) = client.send(&mut packet) {
                client_socket
                    .send_to(&packet[..length], server_address)
                    .unwrap();
            }
            if let Ok((length, peer)) = server_socket.recv_from(&mut packet) {
                let local = CString::new(server_address.to_string()).unwrap();
                let remote = CString::new(peer.to_string()).unwrap();
                let status = unsafe {
                    super::net_quic_server_recv(
                        server,
                        packet.as_mut_ptr(),
                        length,
                        local.as_ptr(),
                        remote.as_ptr(),
                    )
                };
                assert_eq!(status, 1);
            }
            loop {
                let mut destination = [0 as c_char; 64];
                let length = unsafe {
                    super::net_quic_server_send(
                        server,
                        packet.as_mut_ptr(),
                        packet.len(),
                        destination.as_mut_ptr(),
                        destination.len(),
                    )
                };
                if length <= 0 {
                    break;
                }
                let destination = unsafe { CStr::from_ptr(destination.as_ptr()) }
                    .to_str()
                    .unwrap()
                    .parse::<SocketAddr>()
                    .unwrap();
                server_socket
                    .send_to(&packet[..length as usize], destination)
                    .unwrap();
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
        assert_ne!(
            unsafe { super::net_quic_server_timeout_micros(server) },
            u64::MAX
        );
        unsafe {
            net_quic_server_free(server);
            super::net_quic_server_config_free(config);
        }
    }
}
