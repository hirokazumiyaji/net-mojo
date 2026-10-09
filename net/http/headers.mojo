"""Case-insensitive multi-value headers for `net.http`.

Lookup never joins values with commas: callers use `get_first` for a
single value or `get_all` to enumerate duplicates in arrival order.
Names are stored as received alongside a cached lowercase copy, so
lookups compare without allocating per entry.

Values are stored as raw wire bytes and preserved exactly, including
legal `obs-text` bytes that have no UTF-8 decoding. String accessors
decode lossily for convenience; framing paths must use the byte
accessors so an encoded message round-trips byte-identically.

HTTP/1 response ownership charges the three List arrays and raw value capacities.
Clear retains the arrays' charge and drops internal references before refunding.
Stored name references conservatively charge public capacity plus refcount prefix
per reference, including inline/static/shared storage. Incoming caller storage is
admitted after allocation; escaped caller copies, lookup scratch and request/parser
admission remain separate.
"""

from net.error import NetError, NetErrorKind
from std.sys import size_of
from ._buffer import SharedBufferBudget, _CapacityTicket, _reserve_capacity


def _grow_header_array[
    T: Movable
](
    mut values: List[T],
    mut ticket: _CapacityTicket,
    needed: Int,
    mut reservation: Int,
):
    if needed > values.capacity():
        var old_bytes = values.capacity() * size_of[T]()
        _ = _reserve_capacity(
            values, ticket.budget.value(), needed, reservation
        )
        ticket.amount -= old_bytes


def _is_tchar(byte: Byte) -> Bool:
    if (
        (byte >= Byte(ord("A")) and byte <= Byte(ord("Z")))
        or (byte >= Byte(ord("a")) and byte <= Byte(ord("z")))
        or (byte >= Byte(ord("0")) and byte <= Byte(ord("9")))
    ):
        return True
    if (
        byte == Byte(ord("!"))
        or byte == Byte(ord("#"))
        or byte == Byte(ord("$"))
        or byte == Byte(ord("%"))
        or byte == Byte(ord("&"))
        or byte == Byte(ord("'"))
        or byte == Byte(ord("*"))
        or byte == Byte(ord("+"))
        or byte == Byte(ord("-"))
        or byte == Byte(ord("."))
        or byte == Byte(ord("^"))
        or byte == Byte(ord("_"))
        or byte == Byte(ord("`"))
        or byte == Byte(ord("|"))
        or byte == Byte(ord("~"))
    ):
        return True
    return False


def _parse_decimal(data: StringSlice, max_value: Int) -> Int:
    var bytes = data.as_bytes()
    if len(bytes) == 0:
        return -1
    var value = 0
    for i in range(len(bytes)):
        var byte = bytes[i]
        if byte < Byte(ord("0")) or byte > Byte(ord("9")):
            return -1
        var digit = Int(byte - Byte(ord("0")))
        if value > (max_value - digit) // 10:
            return -1
        value = value * 10 + digit
    return value


def _reject_bad_name[
    origin: Origin
](name: Span[Byte, origin], operation: String) raises NetError:
    var bytes = name
    if len(bytes) == 0:
        raise NetError(
            NetErrorKind.invalid_argument(),
            operation,
            None,
            "header name is empty",
        )
    for i in range(len(bytes)):
        if not _is_tchar(bytes[i]):
            raise NetError(
                NetErrorKind.invalid_argument(),
                operation,
                None,
                "header name is not a valid token",
            )


def _check_value_bytes[
    origin: Origin
](bytes: Span[Byte, origin], operation: String) raises NetError:
    for i in range(len(bytes)):
        var byte = bytes[i]
        if byte == Byte(ord("\r")) or byte == Byte(ord("\n")):
            raise NetError(
                NetErrorKind.invalid_argument(),
                operation,
                None,
                "header value contains CR or LF",
            )
        if byte == Byte(0) or (Int(byte) < 32 and byte != Byte(ord("\t"))):
            raise NetError(
                NetErrorKind.invalid_argument(),
                operation,
                None,
                "header value contains disallowed control byte",
            )
        if Int(byte) == 127:
            raise NetError(
                NetErrorKind.invalid_argument(),
                operation,
                None,
                "header value contains disallowed control byte",
            )


def _reject_bad_value(value: StringSlice, operation: String) raises NetError:
    _check_value_bytes(value.as_bytes(), operation)


def _trailer_forbidden(name: StringSlice) -> Bool:
    # RFC 9110 §6.5.1 and RFC 9112 §6.5.1 forbid trailers that change
    # framing, routing, authentication, or payload processing.
    var lowered = String(name).lower()
    return (
        lowered == "content-length"
        or lowered == "transfer-encoding"
        or lowered == "te"
        or lowered == "trailer"
        or lowered == "host"
        or lowered == "expect"
        or lowered == "connection"
        or lowered == "keep-alive"
        or lowered == "upgrade"
        or lowered == "authorization"
        or lowered == "www-authenticate"
        or lowered == "proxy-authenticate"
        or lowered == "proxy-authorization"
        or lowered == "content-encoding"
        or lowered == "content-type"
        or lowered == "content-range"
        or lowered == "cache-control"
        or lowered == "vary"
        or lowered == "set-cookie"
        or lowered == "age"
        or lowered == "expires"
        or lowered == "pragma"
        or lowered == "location"
        or lowered == "retry-after"
        or lowered == "allow"
        or lowered == "etag"
        or lowered == "last-modified"
        or lowered == "content-disposition"
    )


struct Headers(Movable, Sized):
    """Owned header list. The server owns it for the handler call."""

    var _names: List[String]
    var _values: List[List[Byte]]
    var _lower_names: List[String]
    var _capacity_ticket: _CapacityTicket

    def __init__(out self):
        self._names = List[String]()
        self._values = List[List[Byte]]()
        self._lower_names = List[String]()
        self._capacity_ticket = _CapacityTicket()

    def __init__(out self, *, deinit move: Self):
        self._names = move._names^
        self._values = move._values^
        self._lower_names = move._lower_names^
        self._capacity_ticket = move._capacity_ticket^

    def __deinit__(deinit self):
        _ = self._names^
        _ = self._values^
        _ = self._lower_names^
        self._capacity_ticket.release()

    def _string_reference_capacity(self) -> Int:
        var capacity = 0
        for name in self._names:
            capacity += name.capacity_bytes() + String.REF_COUNT_SIZE
        for name in self._lower_names:
            capacity += name.capacity_bytes() + String.REF_COUNT_SIZE
        return capacity

    def _known_capacity(self) -> Int:
        var capacity = (
            self._names.capacity() * size_of[String]()
            + self._lower_names.capacity() * size_of[String]()
            + self._values.capacity() * size_of[List[Byte]]()
        )
        for value in self._values:
            capacity += value.capacity()
        return capacity + self._string_reference_capacity()

    def _adopt_capacity_budget(
        mut self, var budget: Optional[SharedBufferBudget]
    ) -> Bool:
        if not budget:
            return True
        if (
            self._capacity_ticket.budget
            and self._capacity_ticket.budget.value()._shares_storage(
                budget.value()
            )
        ):
            return True
        var capacity = self._known_capacity()
        if not budget.value().try_reserve(capacity):
            return False
        self._capacity_ticket.release()
        self._capacity_ticket = _CapacityTicket(budget^, capacity)
        return True

    def _prepare_append(
        mut self, value_length: Int, reference_capacity: Int
    ) raises NetError:
        if not self._capacity_ticket.budget:
            return
        var needed = len(self) + 1
        var reservation = 0
        if needed > self._names.capacity():
            reservation += (
                max(needed, self._names.capacity() * 2) * size_of[String]()
            )
        if needed > self._lower_names.capacity():
            reservation += (
                max(needed, self._lower_names.capacity() * 2)
                * size_of[String]()
            )
        if needed > self._values.capacity():
            reservation += (
                max(needed, self._values.capacity() * 2) * size_of[List[Byte]]()
            )
        var admission = reservation + value_length + reference_capacity
        if not self._capacity_ticket.budget.value().try_reserve(admission):
            raise NetError(
                NetErrorKind.invalid_argument(),
                "add header",
                None,
                "header backing capacity exceeds budget",
            )
        self._capacity_ticket.amount += admission
        _grow_header_array(
            self._names, self._capacity_ticket, needed, reservation
        )
        _grow_header_array(
            self._lower_names, self._capacity_ticket, needed, reservation
        )
        _grow_header_array(
            self._values, self._capacity_ticket, needed, reservation
        )

    def __len__(self) -> Int:
        return len(self._names)

    def _append_validated[
        origin: ImmOrigin
    ](mut self, var name: String, value: Span[Byte, origin]) raises NetError:
        var name_length = name.byte_length()
        var lower_capacity = String.INLINE_CAPACITY
        if name_length > String.INLINE_CAPACITY:
            lower_capacity = ((name_length + 7) // 8) * 8
        self._prepare_append(
            len(value),
            name.capacity_bytes() + lower_capacity + 2 * String.REF_COUNT_SIZE,
        )
        var raw = List[Byte](capacity=len(value))
        raw.extend(value)
        var lowered = String(capacity_bytes=name_length)
        lowered.resize(name_length)
        var lower_bytes = lowered.unsafe_as_bytes_mut()
        var name_bytes = name.as_bytes()
        for i in range(name_length):
            var byte = name_bytes[i]
            if Byte(ord("A")) <= byte and byte <= Byte(ord("Z")):
                byte += Byte(ord("a") - ord("A"))
            lower_bytes[i] = byte
        self._names.append(name^)
        self._values.append(raw^)
        self._lower_names.append(lowered^)

    def add(mut self, var name: String, var value: String) raises NetError:
        _reject_bad_name(name.as_bytes(), "add header")
        _reject_bad_value(value, "add header")
        var bytes = value.as_bytes()
        self._append_validated(name^, bytes)

    def add_bytes[
        origin: ImmOrigin
    ](mut self, var name: String, value: Span[Byte, origin]) raises NetError:
        _reject_bad_name(name.as_bytes(), "add header")
        _check_value_bytes(value, "add header")
        self._append_validated(name^, value)

    def clear(mut self):
        var released_capacity = self._string_reference_capacity()
        for value in self._values:
            released_capacity += value.capacity()
        self._names.clear()
        self._values.clear()
        self._lower_names.clear()
        if self._capacity_ticket.budget:
            self._capacity_ticket.budget.value().release(released_capacity)
            self._capacity_ticket.amount -= released_capacity

    def get_first(self, name: StringSlice) -> Optional[String]:
        var needle = String(name).lower()
        for i in range(len(self._lower_names)):
            if self._lower_names[i] == needle:
                return String(from_utf8_lossy=Span(self._values[i]))
        return None

    def _first_lower_index(self, lower_name: StringSlice) -> Int:
        for i in range(len(self._lower_names)):
            if self._lower_names[i] == lower_name:
                return i
        return -1

    def get_all(self, name: StringSlice) -> List[String]:
        var out = List[String]()
        var needle = String(name).lower()
        for i in range(len(self._lower_names)):
            if self._lower_names[i] == needle:
                out.append(String(from_utf8_lossy=Span(self._values[i])))
        return out^

    def count(self, name: StringSlice) -> Int:
        var needle = String(name).lower()
        var found = 0
        for i in range(len(self._lower_names)):
            if self._lower_names[i] == needle:
                found += 1
        return found

    def name_at(self, index: Int) -> String:
        return self._names[index].copy()

    def value_at(self, index: Int) -> String:
        return String(from_utf8_lossy=Span(self._values[index]))

    def value_bytes_at(self, index: Int) -> List[Byte]:
        return List[Byte](Span(self._values[index]))

    def _value_bytes_span(
        self, index: Int
    ) -> Span[Byte, origin_of(self._values[index])]:
        return Span(self._values[index])

    def value_byte_length(self, index: Int) -> Int:
        return len(self._values[index])
