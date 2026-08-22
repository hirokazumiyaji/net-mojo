# net-mojo

`net-mojo` is a synchronous networking package for Mojo 1.0.0.
It provides IPv4 and IPv6 addresses, OS name resolution, TCP, UDP, and Unix stream sockets.
The runtime depends on Mojo `std` and the documented libc/POSIX ABI only.

The design rationale is documented in [docs/design/net-package.md](docs/design/net-package.md).

## Supported Platforms

| OS | Architecture | CI runner |
| --- | --- | --- |
| macOS | arm64, 64-bit | `macos-14` |
| Linux | x86_64, 64-bit | `ubuntu-24.04` |

Windows, 32-bit ABIs, and unlisted targets are outside the supported matrix.

## Installation

Install [pixi](https://pixi.sh/), then create the pinned environment from the repository root:

```bash
pixi install --frozen
```

Run a Mojo program with the repository on the import path:

```bash
pixi run mojo run --Werror -I . examples/tcp_echo.mojo
```

## Public API

Import public types and functions from `net`:

```mojo
from net import (
    IPAddress, SocketAddress, Timeout,
    dial_tcp, dial_udp, dial_unix,
    listen_tcp, listen_udp, listen_unix,
    resolve_socket_addresses,
)
```

Numeric addresses use `192.0.2.1`, `2001:db8::1`, and `[2001:db8::1]:443` forms.
IPv6 zones use `[fe80::1%en0]:443` or `[fe80::1%3]:443`.
Hostnames are resolved by synchronous OS `getaddrinfo`; resolver time is outside the connect timeout.
The resolver preserves OS candidate order and processes at most 64 candidates.

Each operation converts its relative timeout to one absolute deadline.
`None` means no deadline, while zero means do not wait after the first immediate attempt.
TCP and Unix stream reads may be partial, and `write_all` loops until all bytes are written or an error occurs.
`dial_udp` returns connected mode for `read` and `write`; `listen_udp` returns unconnected mode for `recv_from` and `send_to`.
Connections and listeners own their descriptors through move-only types.

Unix socket paths are never removed by the library.
Callers must remove a path after closing all descriptors.

## Examples, Benchmarks, and Tests

Examples are loopback-only and self-check their payloads:

```bash
pixi run mojo run --Werror -I . examples/tcp_echo.mojo
pixi run mojo run --Werror -I . examples/udp_echo.mojo
pixi run mojo run --Werror -I . examples/unix_echo.mojo
```

Run the whole test suite with `pixi run test`, or a focused module with `pixi run test-tcp` and the analogous `test-core`, `test-ip`, `test-address`, `test-sys`, `test-udp`, and `test-unix` tasks.
Run benchmarks with `pixi run mojo run --Werror -I . benchmarks/ip_parse.mojo` and `benchmarks/loopback_io.mojo`.
Benchmarks report measurements and do not define pass or fail thresholds.

## Development and CI

Format source with `pixi run mojo format net tests examples benchmarks`.
CI runs the complete warning-clean suite on both supported runners and keeps separate AddressSanitizer steps.
Mojo 1.0.0 marks foundational standard APIs unstable, so CI uses `--Werror` without `--warn-on-unstable-apis`.
The local macOS arm64 toolchain may fail to resolve `___asan_*` runtime symbols before sanitizer tests start.

The initial release excludes asynchronous I/O, cancellation, a custom DNS client, TLS, raw IP and multicast APIs, Linux abstract Unix sockets, Unix datagram sockets, Happy Eyeballs, Windows, and 32-bit ABIs.

## 日本語

`net-mojo` は Mojo 1.0.0 用の同期ネットワーク package です。
IPv4、IPv6、OS の名前解決、TCP、UDP、Unix stream socket を提供します。
runtime 依存は Mojo の `std` と文書化した libc/POSIX ABI だけです。

対応環境は macOS arm64 と Linux x86_64 です。
Windows、32-bit ABI、表にない target は対象外です。

環境は `pixi install --frozen` で構築します。
test は全体を `pixi run test`、個別を `pixi run test-tcp` のように実行します。
examples は loopback だけを使い、benchmarks は閾値を持たない測定プログラムです。

hostname は OS の同期 `getaddrinfo` で解決されます。
名前解決の時間は connect timeout に含まれません。
各操作は一つの絶対 deadline を使い、partial read、`write_all`、UDP の connected mode と unconnected mode を明確に区別します。

Unix socket の path は library が削除しません。
全 descriptor を close した後の削除は利用側が行います。
詳細な設計理由は [docs/design/net-package.md](docs/design/net-package.md) を参照してください。
