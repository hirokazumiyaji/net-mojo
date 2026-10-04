from std.ffi import c_int, external_call
from std.testing import assert_equal, assert_false, assert_true, TestSuite
from std.time import perf_counter_ns, sleep

from net import Timeout, dial_tcp, listen_tcp
from net._actor import PthreadMutex
from net._reactor import Reactor
from net.http import (
    Handler,
    Request,
    ResponseWriter,
    Server,
    ServerConfig,
    ServerControl,
    listen_and_serve_with_control,
)
from tests.support import _join_thread, _socket_pair


struct _Handler(Handler):
    def __init__(out self):
        pass

    def handle(mut self, request: Request, mut writer: ResponseWriter) raises:
        writer.write_string("ok")


@fieldwise_init
struct _ServeContext(Movable):
    var server: Server
    var control: ServerControl
    var failed: Bool
    var ready_mutex: PthreadMutex
    var address: String


def _serve_context(mut context: _ServeContext) raises:
    var handler = _Handler()
    var control = context.control.copy()
    var listener = listen_tcp("127.0.0.1:0")
    context.ready_mutex.lock()
    context.address = String(listener.local_address())
    context.ready_mutex.unlock()
    context.server.serve_with_control(listener^, handler, control)


def _serve_entry(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var context = arg.unsafe_bitcast[_ServeContext]()
    try:
        _serve_context(context[])
    except:
        context[].failed = True
    return arg


def _spawn_serve(mut context: _ServeContext) raises -> UInt64:
    var thread: UInt64 = 0
    var result = external_call["pthread_create", c_int](
        Pointer(to=thread),
        Optional[Pointer[Byte, MutUntrackedOrigin]](None),
        _serve_entry,
        Pointer(to=context).unsafe_bitcast[Byte](),
    )
    assert_equal(Int(result), 0)
    return thread


def test_control_copies_share_shutdown_request() raises:
    var control = ServerControl()
    var copied = control.copy()
    copied.request_shutdown()
    assert_true(control.is_shutdown_requested())
    control.request_shutdown()
    assert_true(copied.is_shutdown_requested())


def test_external_control_stops_running_serve() raises:
    var control = ServerControl()
    var context = _ServeContext(
        Server(ServerConfig.default()),
        control.copy(),
        False,
        PthreadMutex(),
        String(""),
    )
    var thread = _spawn_serve(context)
    var address = String("")
    for _ in range(1000):
        context.ready_mutex.lock()
        address = context.address.copy()
        context.ready_mutex.unlock()
        if address.byte_length() > 0:
            break
        sleep(0.001)
    var served = False
    try:
        var client = dial_tcp(address, Timeout.seconds(2))
        var request = String("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        client.write_all(request.as_bytes(), Timeout.seconds(2))
        var response = List[Byte](length=256, fill=0)
        var count = client.read(Span[mut=True](response), Timeout.seconds(2))
        served = count >= 12 and response[9] == Byte(ord("2"))
        client.close()
    except:
        pass
    control.request_shutdown()
    control.request_shutdown()
    _join_thread(thread)
    context.ready_mutex.destroy()
    assert_true(served)
    assert_false(context.failed)
    assert_equal(context.server.active_connections(), 0)
    assert_true(context.control.is_shutdown_requested())
    control.request_shutdown()


def _control_after_server_drop() raises -> Tuple[ServerControl, Int32]:
    var server = Server(ServerConfig.default())
    var fd = server.control._read_fd()
    return (server.control.copy(), fd)


def test_control_survives_server_drop_and_never_signals_reused_fds() raises:
    var returned = _control_after_server_drop()
    var control = returned[0].copy()
    var retired_fd = returned[1]
    assert_true(control.is_shutdown_requested())
    var pair = _socket_pair()
    assert_true(
        pair.first.raw() == retired_fd or pair.second.raw() == retired_fd
    )
    for _ in range(100):
        control.request_shutdown()
    var reactor = Reactor()
    _ = reactor.register(pair.first.raw())
    _ = reactor.register(pair.second.raw())
    var events = reactor.wait(Timeout.nanoseconds(0))
    assert_equal(len(events), 0)
    pair.first.close()
    pair.second.close()


def _copy_from_temporary() raises -> ServerControl:
    var control = ServerControl()
    return control.copy()


def test_control_copy_survives_original_handle_drop() raises:
    var control = _copy_from_temporary()
    assert_false(control.is_shutdown_requested())
    control.request_shutdown()
    assert_true(control.is_shutdown_requested())


def test_serve_error_marks_external_control_exited() raises:
    var server = Server(ServerConfig.default())
    server.add_listener(listen_tcp("127.0.0.1:0"))
    var control = ServerControl()
    var handler = _Handler()
    var failed = False
    var listener = listen_tcp("127.0.0.1:0")
    try:
        server.serve_with_control(listener^, handler, control)
    except:
        failed = True
    assert_true(failed)
    assert_true(control.is_shutdown_requested())
    control.request_shutdown()


@fieldwise_init
struct _ShutdownContext(Movable):
    var control: ServerControl
    var wait_before_request: Bool


def _request_entry(
    arg: Pointer[Byte, MutUntrackedOrigin]
) -> Pointer[Byte, MutUntrackedOrigin]:
    var context = arg.unsafe_bitcast[_ShutdownContext]()
    if context[].wait_before_request:
        sleep(0.02)
    for _ in range(100):
        context[].control.request_shutdown()
    return arg


def _spawn_request(mut context: _ShutdownContext) raises -> UInt64:
    var thread: UInt64 = 0
    var result = external_call["pthread_create", c_int](
        Pointer(to=thread),
        Optional[Pointer[Byte, MutUntrackedOrigin]](None),
        _request_entry,
        Pointer(to=context).unsafe_bitcast[Byte](),
    )
    assert_equal(Int(result), 0)
    return thread


def test_control_wakes_blocked_reactor_and_notification_drains() raises:
    var control = ServerControl()
    var reactor = Reactor()
    var token = reactor.register(control._read_fd())
    var context = _ShutdownContext(control.copy(), True)
    var thread = _spawn_request(context)
    var started = perf_counter_ns()
    var events = reactor.wait(Timeout.seconds(2))
    var elapsed = perf_counter_ns() - started
    _join_thread(thread)
    assert_true(context.control.is_shutdown_requested())
    assert_equal(len(events), 1)
    assert_true(events[0].token == token)
    assert_true(elapsed < 500_000_000)
    control._drain()
    events = reactor.wait(Timeout.nanoseconds(0))
    assert_equal(len(events), 0)
    _ = reactor.remove(token)
    control.mark_exited()


def test_requests_racing_exit_do_not_signal_reused_descriptors() raises:
    var control = ServerControl()
    var context = _ShutdownContext(control.copy(), False)
    var thread = _spawn_request(context)
    control.mark_exited()
    var pair = _socket_pair()
    _join_thread(thread)
    assert_true(context.control.is_shutdown_requested())
    var reactor = Reactor()
    _ = reactor.register(pair.first.raw())
    _ = reactor.register(pair.second.raw())
    var events = reactor.wait(Timeout.nanoseconds(0))
    assert_equal(len(events), 0)
    pair.first.close()
    pair.second.close()


def test_bind_error_marks_external_control_exited() raises:
    var control = ServerControl()
    var handler = _Handler()
    var failed = False
    try:
        listen_and_serve_with_control(
            "invalid-address", ServerConfig.default(), handler, control
        )
    except:
        failed = True
    assert_true(failed)
    assert_true(control.is_shutdown_requested())
    control.request_shutdown()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
