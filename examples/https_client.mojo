from net.http import Client, ClientConfig, ClientRequest, ClientTLSConfig
from net.tls import TLSContext
from examples._http_client_loopback import _LoopbackHTTPServer


def main() raises:
    var context = TLSContext.server(
        "build/tls/libnet_tls",
        "build/tls/test-cert.pem",
        "build/tls/test-key.pem",
        "http/1.1",
    )
    var server = _LoopbackHTTPServer("hello over HTTPS", context^)
    var config = ClientConfig.default()
    var tls = ClientTLSConfig.default()
    tls.ca_bundle_path = "build/tls/test-cert.pem"
    config.tls = tls^
    var client = Client(config^)
    var response = client.do(ClientRequest.get(server.url + "/hello"))
    print("GET", response.status, String(from_utf8_lossy=response.read_all()))
    client.close()
    var count = server.finish()
    if count != 1:
        raise Error("HTTPS client example did not complete its request")
