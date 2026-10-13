"""Bounded buffered response writer for `net.http`.

The handler mutates the writer; the server sends after the handler
returns. The writer never touches the socket and never waits.
The connection owns the encoded bytes until the send completes, so
handler-local values must be copied in (which `write` does) instead
of borrowed into a send queue.

The synchronous HTTP/1 writer owns its body capacity in the shared budget;
standalone writers enforce their body length limit. Direct body edits are
reconciled separately and do not have the supported writes' growth guarantee.
HTTP/1 response Headers reserve known array/raw value growth and retained
capacity; direct public Headers replacement is admitted after allocation.
"""

from net.error import NetError, NetErrorKind

from ._detach import (
    ResponseSender,
    _DetachTarget,
    _DETACH_HTTP1,
    _cancel_detach_state,
    _create_detach_state,
)
from ._offload import HandlerJob, OffloadError, WorkerPool
from ._control import ServerControl
from ._buffer import SharedBufferBudget, _CapacityTicket, _reserve_capacity
from ._hijack import (
    HijackSender,
    _create_hijack_state,
    _cancel_hijack_state,
    _release_hijack_state,
)
from .headers import Headers, _trailer_forbidden
from .request import Request, RequestBodyReceiver
from ._body_pipe import _BodyPipe


@fieldwise_init
struct RequestBodyEndpoints(Movable):
    """Owned input and output endpoints for one detached request."""

    var receiver: RequestBodyReceiver
    var sender: ResponseSender


@fieldwise_init
struct _HijackContext(Movable):
    var is_connect: Bool
    var is_http11: Bool
    var control: ServerControl
    var date: String
    var max_headers: Int
    var max_bytes: Int


struct ResponseWriter(Movable, Sized):
    """Owned response under construction."""

    var status: Int
    var headers: Headers
    var trailers: Headers
    var body: List[Byte]
    var should_close: Bool
    var _limit: Int
    var _detached: Bool
    var _detach_state_addr: Int
    var _hijack_state_addr: Int
    var _hijack_context: Optional[_HijackContext]
    var _target: _DetachTarget
    var _wakeup_fd: Int32
    var _queue_limit: Int
    var _body_budget: Optional[SharedBufferBudget]
    var _mailbox_budget: Optional[SharedBufferBudget]
    var _body_capacity_reserved: Int
    var _request_body_pipe: Optional[_BodyPipe]

    def __init__(
        out self,
        body_limit: Int,
        slot: Int = -1,
        generation: UInt64 = 0,
        wakeup_fd: Int32 = -1,
        queue_limit: Int = 1048576,
    ):
        self.status = 200
        self.headers = Headers()
        self.trailers = Headers()
        self.body = List[Byte]()
        self.should_close = False
        self._limit = body_limit
        self._detached = False
        self._detach_state_addr = 0
        self._hijack_state_addr = 0
        self._hijack_context = None
        self._target = _DetachTarget.http1(slot, generation)
        # Note on _wakeup_fd: raw descriptor borrowed from Server._wakeup_channel.
        # The channel owns descriptor lifecycle; DetachState.cancelled guards
        # against late signaling if Server deinitializes.
        self._wakeup_fd = wakeup_fd
        self._queue_limit = queue_limit
        self._body_budget = None
        self._mailbox_budget = None
        self._body_capacity_reserved = 0
        self._request_body_pipe = None

    def __init__(out self, *, deinit move: Self):
        self.status = move.status
        self.headers = move.headers^
        self.trailers = move.trailers^
        self.body = move.body^
        self.should_close = move.should_close
        self._limit = move._limit
        self._detached = move._detached
        self._detach_state_addr = move._detach_state_addr
        self._hijack_state_addr = move._hijack_state_addr
        self._hijack_context = move._hijack_context^
        self._target = move._target^
        self._wakeup_fd = move._wakeup_fd
        self._queue_limit = move._queue_limit
        self._body_budget = move._body_budget^
        self._mailbox_budget = move._mailbox_budget^
        self._body_capacity_reserved = move._body_capacity_reserved
        self._request_body_pipe = move._request_body_pipe^

    def __deinit__(deinit self):
        self._cancel_hijack()
        self._drop_body()

    def _set_body_budget(mut self, var budget: SharedBufferBudget):
        _ = self.headers._adopt_capacity_budget(Optional(budget.copy()))
        _ = self.trailers._adopt_capacity_budget(Optional(budget.copy()))
        self._mailbox_budget = budget.copy()
        self._body_budget = budget^

    def _set_mailbox_budget(mut self, var budget: SharedBufferBudget):
        self._mailbox_budget = budget^

    def _set_request_body_pipe(mut self, var pipe: Optional[_BodyPipe]):
        self._request_body_pipe = pipe^

    def _drop_headers(mut self):
        self.headers = Headers()
        self.trailers = Headers()

    def _reconcile_body_budget(mut self) -> Bool:
        var capacity = self.body.capacity()
        var difference = capacity - self._body_capacity_reserved
        if difference >= 0:
            if not self._body_budget.value().try_reserve(difference):
                return False
        else:
            self._body_budget.value().release(-difference)
        self._body_capacity_reserved = capacity
        return True

    def _drop_body(mut self):
        self.body = List[Byte]()
        if self._body_budget:
            self._body_budget.value().release(self._body_capacity_reserved)
        self._body_capacity_reserved = 0

    def _set_detach_target(mut self, var target: _DetachTarget):
        self._target = target^

    def _set_hijack_context(mut self, var context: _HijackContext):
        self._hijack_context = context^

    def is_hijacked(self) -> Bool:
        return self._hijack_state_addr != 0

    def _cancel_hijack(mut self):
        if self.is_hijacked():
            var addr = self._take_hijack_state()
            _cancel_hijack_state(addr)
            _release_hijack_state(addr, from_sender=False)

    def _take_hijack_state(mut self) -> Int:
        var addr = self._hijack_state_addr
        self._hijack_state_addr = 0
        return addr

    def _check_hijack(self) raises NetError:
        if self._detached or self._detach_state_addr != 0 or self.is_hijacked():
            raise NetError(
                NetErrorKind.invalid_state(),
                "hijack",
                None,
                "response already transferred",
            )
        if self._target.protocol != _DETACH_HTTP1 or not self._hijack_context:
            raise NetError(
                NetErrorKind.unsupported(),
                "hijack",
                None,
                "hijack requires an HTTP/1.1 server writer",
            )
        if not self._hijack_context.value().is_http11:
            raise NetError(
                NetErrorKind.unsupported(),
                "hijack",
                None,
                "hijack requires HTTP/1.1",
            )
        if self._hijack_context.value().control.is_shutdown_requested():
            raise NetError(
                NetErrorKind.closed(), "hijack", None, "server is shutting down"
            )
        if (
            self._request_body_pipe
            and not self._request_body_pipe.value()._can_hijack()
        ):
            raise NetError(
                NetErrorKind.invalid_state(),
                "hijack",
                None,
                "request body requires consumed EOF with no active receiver",
            )
        if len(self.body) != 0 or len(self.trailers) != 0:
            raise NetError(
                NetErrorKind.invalid_state(),
                "hijack",
                None,
                "response content already buffered",
            )

    def hijack(mut self) raises NetError -> HijackSender:
        """Transfers raw ownership after the handler returns; receive it on a worker.
        """
        self._check_hijack()
        self._hijack_state_addr = _create_hijack_state(
            self._target.slot,
            self._target.generation,
            self._wakeup_fd,
            budget=self._mailbox_budget.copy(),
        )
        return HijackSender(self._hijack_state_addr)

    def switch_protocols(
        mut self, var headers: Headers, status: Int = 101
    ) raises NetError -> HijackSender:
        """Flushes switching headers before a worker receives raw ownership."""
        from ._encoder import _encode_response_budgeted

        self._check_hijack()
        ref context = self._hijack_context.value()
        if (context.is_connect and not (200 <= status < 300)) or (
            not context.is_connect and status != 101
        ):
            raise NetError(
                NetErrorKind.invalid_argument(),
                "switch protocols",
                None,
                "CONNECT requires 2xx and Upgrade requires 101",
            )
        if not context.is_connect:
            var upgrade = headers.get_first("upgrade")
            var has_upgrade = False
            for index in range(len(headers)):
                if headers._lower_names[index] == "connection":
                    for token in headers.value_at(index).split(","):
                        if token.strip().lower() == "upgrade":
                            has_upgrade = True
            if (
                not has_upgrade
                or not upgrade
                or upgrade.value().strip().byte_length() == 0
            ):
                raise NetError(
                    NetErrorKind.invalid_argument(),
                    "switch protocols",
                    None,
                    "101 requires Connection Upgrade and an Upgrade protocol",
                )
        var response = ResponseWriter(0)
        response.status = status
        response.headers = headers^
        if not response.headers._adopt_capacity_budget(
            self._mailbox_budget.copy()
        ):
            raise NetError(
                NetErrorKind.invalid_argument(),
                "switch protocols",
                None,
                "switch headers exceed buffer budget",
            )
        var wire = _encode_response_budgeted(
            response,
            False,
            context.date,
            context.max_headers,
            context.max_bytes,
            self._mailbox_budget.value(),
            switching=True,
        )
        var ticket = _CapacityTicket(
            self._mailbox_budget.copy(), wire.capacity()
        )
        self._hijack_state_addr = _create_hijack_state(
            self._target.slot,
            self._target.generation,
            self._wakeup_fd,
            budget=self._mailbox_budget.copy(),
            pending_response=wire^,
            response_ticket=ticket^,
        )
        return HijackSender(self._hijack_state_addr)

    def is_detached(self) -> Bool:
        return self._detached

    def _cancel_detach(mut self):
        if self._detach_state_addr != 0:
            _cancel_detach_state(self._detach_state_addr)
            self._detach_state_addr = 0

    def set_detach_state(mut self, addr: Int):
        self._detach_state_addr = addr

    def detach_with_body(
        mut self, request: Request
    ) raises NetError -> RequestBodyEndpoints:
        """Transfers both streaming endpoints to an owned worker context."""
        var body = request.body_reader()
        var receiver = body.detach()
        var sender = self.detach()
        return RequestBodyEndpoints(receiver^, sender^)

    def detach(mut self) raises NetError -> ResponseSender:
        """Detaches the response from the synchronous handler flow.

        Returns a `ResponseSender` that can be transferred across threads to
        complete or stream the response asynchronously.
        Once detached, the handler must not write further data directly to `ResponseWriter`.
        """
        if self._detached or self.is_hijacked():
            raise NetError(
                NetErrorKind.invalid_state(),
                "detach",
                None,
                "response already detached",
            )
        if self._detach_state_addr != 0:
            self._detached = True
            return ResponseSender(self._detach_state_addr)
        var addr = _create_detach_state(
            slot=self._target.slot,
            generation=self._target.generation,
            protocol=self._target.protocol,
            stream_id=self._target.stream_id,
            wakeup_fd=self._wakeup_fd,
            queue_limit=self._queue_limit,
            budget=self._mailbox_budget.copy(),
        )
        self._detach_state_addr = addr
        self._detached = True
        return ResponseSender(addr)

    def offload[
        J: HandlerJob
    ](mut self, mut pool: WorkerPool, var job: J) raises OffloadError -> Bool:
        """Transfers this response and an owned job to a bounded worker pool."""
        var sender = self.detach()
        return pool.submit(sender^, job^)

    def __len__(self) -> Int:
        return len(self.body)

    def set_status(mut self, status: Int):
        self.status = status

    def set_should_close(mut self, should_close: Bool):
        self.should_close = should_close

    def body_limit(self) -> Int:
        return self._limit

    def write[
        origin: ImmOrigin
    ](mut self, data: Span[Byte, origin]) raises NetError:
        if self.is_hijacked():
            raise NetError(
                NetErrorKind.invalid_state(),
                "write response body",
                None,
                "response already hijacked",
            )
        if len(self.body) + len(data) > self._limit:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "write response body",
                None,
                "response body exceeds limit",
            )
        if self._body_budget:
            var reservation = 0
            if not self._reconcile_body_budget() or not _reserve_capacity(
                self.body,
                self._body_budget.value(),
                len(self.body) + len(data),
                reservation,
            ):
                raise NetError(
                    NetErrorKind.invalid_argument(),
                    "write response body",
                    None,
                    "response body capacity exceeds budget",
                )
            self._body_capacity_reserved = self.body.capacity()
        else:
            self.body.reserve(len(self.body) + len(data))
        self.body.extend(data)

    def write_string(mut self, data: StringSlice) raises NetError:
        self.write(data.as_bytes())

    def add_trailer(
        mut self, var name: String, var value: String
    ) raises NetError:
        """Appends a response trailer after validating the name against
        the RFC 9110 §6.5.1 trailer deny-list; the underlying Headers
        store rejects CR/LF/NUL and non-token name bytes."""
        if self.is_hijacked():
            raise NetError(
                NetErrorKind.invalid_state(),
                "add trailer",
                None,
                "response already hijacked",
            )
        if _trailer_forbidden(name):
            raise NetError(
                NetErrorKind.invalid_argument(),
                "add trailer",
                None,
                "trailer modifies framing, routing, or payload processing",
            )
        self.trailers.add(name^, value^)


def has_body_for_status(status: Int, is_head: Bool) -> Bool:
    """Reports whether the encoder may emit response content bytes.

    HEAD never emits content, and 1xx / 204 / 205 / 304 never do either,
    regardless of any buffered bytes (RFC 9110: none of them allow
    content). HTTP/1 still frames 205 with Content-Length: 0 so clients
    can delimit the empty message body on keep-alive connections.
    """
    if is_head:
        return False
    if status >= 100 and status <= 199:
        return False
    if status == 204 or status == 205 or status == 304:
        return False
    return True


def maybe_inject_alt_svc(
    mut writer: ResponseWriter, alt_svc: StringSlice
) raises:
    """Adds `Alt-Svc` when configured and the handler did not set it.

    Callers restrict this to HTTPS (TLS) responses. An empty `alt_svc`
    leaves the response unchanged so UDP-unavailable deployments can
    serve HTTPS without advertising HTTP/3.
    """
    if alt_svc.byte_length() == 0:
        return
    if writer.headers._first_lower_index("alt-svc") >= 0:
        return
    writer.headers.add(String("Alt-Svc"), String(alt_svc))
