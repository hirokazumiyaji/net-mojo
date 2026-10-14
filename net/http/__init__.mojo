"""`net.http` origin-server and routing API.

Import from here, not from `net`:

```mojo
from net.http import (
    Handler, Headers, HttpError, HttpVersion, MiddlewareFn, Request, RequestBody, ResponseWriter,
    RouteHandler, ServeMux, Server, ServerConfig, ServerControl, has_body_for_status,
    apply_middleware, maybe_inject_alt_svc, split_path_query,
)
```
"""

from ._offload import HandlerJob, OffloadError, WorkerPool, WorkerPoolConfig

from .switch import HijackedConn
from ._hijack import HijackSender
from .client import Client
from .client_config import ClientConfig, ClientTLSConfig, RedirectPolicy
from .client_request import ClientRequest, ClientRequestBody
from .client_response import Response, ResponseBody
from .client_error import ClientError
from ._filesystem import FileSystem
from .fileserver import (
    FileETagMode,
    FileServer,
    FileServerConfig,
    file_server,
    serve_file,
)
from .compression import CompressionConfig, negotiate_encoding
from .config import ServerConfig
from .error import HttpError, _status_reason
from .handler import Handler, HandlerFactory, DefaultHandlerFactory
from .headers import Headers
from .middleware import (
    LogSink,
    LoggingHandler,
    MiddlewareFn,
    RecoverHandler,
    StdoutLogSink,
    TimeoutHandler,
    apply_middleware,
)
from .request import (
    HttpVersion,
    Request,
    RequestBody,
    RequestBodyReceiver,
    split_path_query,
)
from .response import (
    RequestBodyEndpoints,
    ResponseSender,
    ResponseWriter,
    has_body_for_status,
    maybe_inject_alt_svc,
)
from .router import Pattern, RouteHandler, ServeMux
from .server import (
    Server,
    ServerControl,
    listen_and_serve,
    listen_and_serve_with_control,
)

from .pool import ServerPool, listen_and_serve_pool
