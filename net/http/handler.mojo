"""Handler contract shared by HTTP/1.1, HTTP/2, and HTTP/3.

The handler runs synchronously on the single event-loop thread. It
borrows the request and mutates the response writer, both valid only
for the call. Blocking I/O or long CPU work stalls every connection
on the loop; offload is future work.

Prefer a concrete handler type chosen at compile time
(`Server.serve[MyHandler]`) over a type-erased callback so the
compiler can specialize the call. Branch on `method`/`path` inside
the handler and return 404 for unhandled paths.
"""

from .request import Request
from .response import ResponseWriter


trait Handler(Movable):
    def handle(mut self, req: Request, mut writer: ResponseWriter) raises:
        ...
