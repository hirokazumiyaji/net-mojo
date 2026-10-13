from net.http import Client, ClientConfig, ClientRequest
from examples._http_client_loopback import _LoopbackHTTPServer


def main() raises:
    var server = _LoopbackHTTPServer("hello over HTTP")
    var client = Client(ClientConfig.default())
    var response = client.do(ClientRequest.get(server.url + "/hello"))
    print("GET", response.status, String(from_utf8_lossy=response.read_all()))
    var request = ClientRequest.post_bytes(
        server.url + "/echo", List[Byte]("submitted bytes".as_bytes())
    )
    var posted = client.do(request^)
    print("POST", posted.status, String(from_utf8_lossy=posted.read_all()))
    client.close()
    var count = server.finish()
    if count != 2:
        raise Error("HTTP client example did not complete both requests")
