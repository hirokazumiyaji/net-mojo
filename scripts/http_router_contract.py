"""One request table for the HTTP/1.1, HTTP/2 and HTTP/3 router fixtures."""

CASES = [
    ("GET", "/router/items/42", b"", 200, b"42", []),
    ("GET", "/router/items/fixed", b"", 200, b"literal", []),
    ("GET", "/router/items/a%2Fb?x=1", b"", 200, b"a%2Fb", [("x-query", "x=1")]),
    ("HEAD", "/router/items/42", b"", 200, b"", [("content-length", "2")]),
    ("DELETE", "/router/items/42", b"", 405, b"method not allowed", [("allow", "GET, HEAD")]),
    ("GET", "/router/static/a/b", b"", 200, b"a/b", []),
    ("GET", "/router/static/", b"", 200, b"", []),
    ("GET", "/router/missing", b"", 404, b"not found", []),
    ("POST", "/router/echo", b"a\x00b", 200, b"a\x00b", []),
    ("GET", "/router/echo", b"", 405, b"method not allowed", [("allow", "POST")]),
]


def check(case, status, body, headers):
    method, path, _, expected_status, expected_body, expected_headers = case
    assert status == expected_status, (method, path, status)
    assert body == expected_body, (method, path, body)
    for name, value in expected_headers:
        assert [v for n, v in headers if n.lower() == name] == [value], (path, headers)
