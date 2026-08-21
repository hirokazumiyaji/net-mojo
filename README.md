# net-mojo

`net-mojo` は、Mojo 1.0.0 の標準ライブラリと macOS または Linux の libc/POSIX ABI だけに依存する同期ネットワーク package です。
TCP、UDP、Unix domain stream socket、IPv4、IPv6、OS の名前解決を提供します。

内部構造と選択理由は[設計書](docs/design/net-package.md)にまとめています。

## インストール

[pixi](https://pixi.sh/)をインストールし、repository のルートで環境を構築します。

```bash
pixi install --frozen
```

利用側の Mojo program は repository のルートを import path に加えて実行します。

```bash
pixi run mojo run --Werror -I . example.mojo
```

runtime の package 依存は Mojo 標準ライブラリの `std` と本 repository の `net` だけです。

## 公開 API

公開する型と関数は `net` から import できます。

```mojo
from net import (
    IPAddress,
    SocketAddress,
    Timeout,
    UnixAddress,
    dial_tcp,
    dial_udp,
    dial_unix,
    join_host_port,
    listen_tcp,
    listen_udp,
    listen_unix,
    resolve_socket_addresses,
    split_host_port,
)
```

TCP の loopback 接続は次のように作れます。

```mojo
from net import Timeout, dial_tcp, listen_tcp

var listener = listen_tcp("127.0.0.1:0")
var client = dial_tcp(
    String(listener.local_address()), Timeout.seconds(1)
)
var server = listener.accept(Timeout.seconds(1))
```

実行可能な TCP、UDP、Unix の往復例は `examples` にあります。

## 対応環境

| OS | Architecture | CI runner |
|---|---|---|
| macOS | arm64、64-bit | `macos-14` |
| Linux | x86_64、64-bit | `ubuntu-24.04` |

Windows、32-bit ABI、表にない OS と architecture は対象外です。

## アドレスと名前解決

`IPAddress.parse` と `SocketAddress.parse` は数値アドレスだけを受け付けます。
IPv4 は `192.0.2.1`、IPv6 は `2001:db8::1`、port 付き IPv6 は `[2001:db8::1]:443` の形式です。
IPv6 zone は `[fe80::1%en0]:443` または `[fe80::1%3]:443` と書きます。
空 host は listen の wildcard address だけで使えます。

hostname は `resolve_socket_addresses`、`dial_tcp`、`dial_udp` が OS の同期 `getaddrinfo` で解決します。
候補は OS の順序を保ち、最大64件を扱います。
数値 IP は resolver を通りません。

同期 `getaddrinfo` には移植可能な cancellation がないため、接続 timeout の計測は名前解決が完了してから始まります。
resolver にかかった時間は connect timeout に含まれません。

## Timeout

`Timeout` は各 connect、accept、read、write 操作に対する相対時間です。
操作開始時に一つの絶対 deadline へ変換するため、`EINTR`、readiness 待ち、部分書き込みで timeout 全量を開始し直しません。
`None` は無期限、ゼロの `Timeout` は待機しない操作を表します。

## UDP mode

`dial_udp` は connected mode を返し、`read` と `write` を使います。
`listen_udp` は unconnected mode を返し、`recv_from` と `send_to` を使います。
mode と異なる操作は `invalid_state` を返します。

## Unix socket path

Unix listener は既存 path を削除せず、close 後も socket path を削除しません。
利用者は listen 前の衝突確認と、全 descriptor を close した後の path 削除を明示的に行います。
Linux abstract socket、Unix datagram、Unix sequenced-packet は対象外です。

## 所有権

connection と listener は OS descriptor を一意に所有する move-only 型です。
値を移動した後の元の値は利用できず、`close` は同じ descriptor を再度 close しません。
一つの connection を複数 thread から同時に操作する使い方は対象外です。

## 初期リリースに含まれない機能

- 非同期 I/O と cancellation
- 独自 event loop と汎用 poller
- 独自 DNS client
- TLS、HTTP、mail、RPC などの上位 protocol
- raw IP socket と multicast の高水準 API
- network interface の列挙
- Linux abstract Unix socket
- Unix datagram と Unix sequenced-packet socket
- Happy Eyeballs の並行接続
- 一つの connection に対する複数 thread からの同時操作
- Windows と32-bit ABI

## 検証

CI は `macos-14` と `ubuntu-24.04` で format、unit test、integration test、AddressSanitizer を実行します。
通常の test は `--Werror` を使いますが、`--warn-on-unstable-apis` は併用しません。
Mojo 1.0.0 が本 package に必要な基礎的な標準 API を unstable と分類し、併用するとその利用が error になるためです。

初期実装に使った macOS arm64 の Mojo 1.0.0 環境では、AddressSanitizer runtime の `___asan_*` symbol を解決できず、test 開始前に失敗しました。
CI の sanitizer command は削除せず、対応する toolchain 環境で system、TCP、UDP、Unix の test を実行します。

benchmark は固定性能閾値を持たず、結果を CI の合否に使いません。
次の command で IP parse と64 MiB以上の UDP loopback I/O を測定できます。

```bash
pixi run mojo run --Werror -I . benchmarks/ip_parse.mojo
pixi run mojo run --Werror -I . benchmarks/loopback_io.mojo
```
