"""Case-insensitive multi-value headers for `net.http`.

Lookup never joins values with commas: callers use `get_first` for a
single value or `get_all` to enumerate duplicates in arrival order.
Names are stored as received alongside a cached lowercase copy, so
lookups compare without allocating per entry.
"""

from net.error import NetError, NetErrorKind


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


def _reject_bad_name(name: StringSlice, operation: String) raises NetError:
    var bytes = name.as_bytes()
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


def _reject_bad_value(value: StringSlice, operation: String) raises NetError:
    var bytes = value.as_bytes()
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


struct Headers(Movable, Sized):
    """Owned header list. The server owns it for the handler call."""

    var _names: List[String]
    var _values: List[String]
    var _lower_names: List[String]

    def __init__(out self):
        self._names = List[String]()
        self._values = List[String]()
        self._lower_names = List[String]()

    def __len__(self) -> Int:
        return len(self._names)

    def add(mut self, var name: String, var value: String) raises NetError:
        _reject_bad_name(name, "add header")
        _reject_bad_value(value, "add header")
        var lowered = name.lower()
        self._names.append(name^)
        self._values.append(value^)
        self._lower_names.append(lowered^)

    def clear(mut self):
        self._names.clear()
        self._values.clear()
        self._lower_names.clear()

    def get_first(self, name: StringSlice) -> Optional[String]:
        var needle = String(name).lower()
        for i in range(len(self._lower_names)):
            if self._lower_names[i] == needle:
                return self._values[i].copy()
        return None

    def get_all(self, name: StringSlice) -> List[String]:
        var out = List[String]()
        var needle = String(name).lower()
        for i in range(len(self._lower_names)):
            if self._lower_names[i] == needle:
                out.append(self._values[i].copy())
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
        return self._values[index].copy()
