"""Serve a directory: pixi run example-http-fileserver ./public."""

from std.sys import argv

from net.http import ServeMux, ServerConfig, file_server, listen_and_serve


def main() raises:
    var arguments = argv()
    if len(arguments) != 2:
        raise Error("usage: http_fileserver <directory>")
    var mux = ServeMux()
    mux.handle("GET /static/{path...}", file_server(arguments[1]))
    print("Serving /static/ at http://127.0.0.1:8080")
    listen_and_serve("127.0.0.1:8080", ServerConfig.default(), mux)
