import subprocess
import sys

from http_router_contract import CASES, check
from test_http_app_contract import FIXTURE, H1Client, H2Client, _shutdown, _wait_ready


def main():
    proc = subprocess.Popen(FIXTURE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        port = _wait_ready(proc)
        for client_type in (H1Client, H2Client):
            client = client_type(port)
            try:
                for case in CASES:
                    method, path, body, *_ = case
                    response = client.request(method, path, body=body)
                    if client_type is H2Client:
                        assert response.reset_code is None, (path, response.reset_code)
                        assert response.stream_ended, path
                    headers = [(name, value) for name, _ in case[5]
                               for value in response.header_values(name)]
                    check(case, response.status, response.body, headers)
            finally:
                client.close()
        _shutdown(port)
        assert proc.wait(timeout=15) == 0, proc.stderr.read()
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        sys.stderr.write(proc.stderr.read())
    print("Shared router contract passed on HTTP/1.1 and HTTP/2")


if __name__ == "__main__":
    main()
