from std.sys import argv
from net.http import Client, ClientConfig, ClientTLSConfig, ClientRequest


def main() raises:
    var args = argv()
    if len(args) != 5:
        raise Error("expected URL, CA bundle, SNI override, insecure flag")
    var config = ClientConfig.default()
    var tls = ClientTLSConfig.default()
    if args[2] != "-":
        tls.ca_bundle_path = String(args[2])
    if args[3] != "-":
        tls.sni_override = String(args[3])
    tls.insecure_skip_verify = args[4] == "true"
    config.tls = tls^
    var client = Client(config^)
    try:
        var response = client.do(ClientRequest.get(String(args[1])))
        var body = response.read_all()
        print(String(from_utf8_lossy=body))
    except error:
        print("ERROR", Int(error.kind))
    client.close()
