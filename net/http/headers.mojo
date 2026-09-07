"""Case-insensitive multi-value headers for `net.http`.

Lookup never joins values with commas: callers use `get_first` for a
single value or `get_all` to enumerate duplicates in arrival order.
Names are stored as received; comparison lowercases both sides.
"""

from net.error import NetError, NetErrorKind


def _reject_injection(value: StringSlice, operation: String) raises NetError:
    var bytes = value.as_bytes()
    for i in range(len(bytes)):
        if bytes[i] == Byte(ord("\r")) or bytes[i] == Byte(ord("\n")):
            raise NetError(
                NetErrorKind.invalid_argument(),
                operation,
                None,
                "header value contains CR or LF",
            )


struct Headers(Movable, Sized):
    """Owned header list. The server owns it for the handler call."""

    var _names: List[String]
    var _values: List[String]

    def __init__(out self):
        self._names = List[String]()
        self._values = List[String]()

    def __len__(self) -> Int:
        return len(self._names)

    def add(mut self, var name: String, var value: String) raises NetError:
        if name.byte_length() == 0:
            raise NetError(
                NetErrorKind.invalid_argument(),
                "add header",
                None,
                "header name is empty",
            )
        _reject_injection(name, "add header")
        _reject_injection(value, "add header")
        self._names.append(name^)
        self._values.append(value^)

    def clear(mut self):
        self._names.clear()
        self._values.clear()

    def get_first(self, name: StringSlice) -> Optional[String]:
        var needle = String(name).lower()
        for i in range(len(self._names)):
            if self._names[i].lower() == needle:
                return self._values[i].copy()
        return None

    def get_all(self, name: StringSlice) -> List[String]:
        var out = List[String]()
        var needle = String(name).lower()
        for i in range(len(self._names)):
            if self._names[i].lower() == needle:
                out.append(self._values[i].copy())
        return out^

    def count(self, name: StringSlice) -> Int:
        var needle = String(name).lower()
        var found = 0
        for i in range(len(self._names)):
            if self._names[i].lower() == needle:
                found += 1
        return found

    def name_at(self, index: Int) -> String:
        return self._names[index].copy()

    def value_at(self, index: Int) -> String:
        return self._values[index].copy()
