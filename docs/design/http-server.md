# [Roadmap] net.http に高性能な HTTP/1.1・HTTP/2・HTTP/3 サーバーを実装する

## 目的

Go の `net/http` を参考に、Mojo から小さな API サーバーを書ける `net.http` を追加する。
最終目標は HTTP/1.1、HTTP/2、HTTP/3 の実装と相互運用性の検証。HTTP/1.1 は最初のマイルストーンであり、HTTP/2 と HTTP/3 は本 Issue の必須スコープに含める。
Phase 0〜5 で HTTP/1.1、Phase 6〜7 で TLS と HTTP/2、Phase 8〜9 で QUIC と HTTP/3、Phase 10 で全体を検証する。
小さいレスポンスのスループット、p99 レイテンシ、多数の keep-alive 接続での CPU とメモリ使用量を評価する。
これは設計案と実装ロードマップであり、性能は未計測。Go と同等以上の性能を達成したという意味ではない。

## 現状と配置

調査基点: `6512d41`。関連: #19（多重化と cancellation）、#20（socket options）、#26（並行利用テスト）。

- `net/tcp.mojo` に `try_accept`、`try_read`、`try_write`、`raw_fd` がある。
- `net/poll.mojo` は `poll(2)` と全登録走査を使う。登録削除で index がずれ、監視イベントの変更 API がない。
- `net._sys.common` は `NetError` と `_Deadline` に依存する。HTTP 追加のために独立ライブラリ化する必要はない。
- `TCPConn` の所有者は一つ。イベント通知用 fd は借用であり、登録解除から close まで所有者を生存させる必要がある。
- `accept` は明示的に `TCP_NODELAY` を設定するが、`try_accept` と `accept_with_address` は同じ設定処理を通らない。継承任せにせず、各経路の実効設定を検証する。

同じリポジトリと配布物に `net/http/` を追加する。
利用側は `from net.http import ...` とし、`net/__init__.mojo` への HTTP 型の再 export は行わない。
HTTP/1.1 と HTTP/2 の依存方向は `net.http → TCP / TLS / readiness → net._sys`、HTTP/3 は `net.http → QUIC（TLS 1.3 統合）→ UDP / readiness → net._sys` とする。
HTTP parser はソケットに依存させず、HTTP 固有の意味づけは `_sys` に入れない。

## 選択肢と推奨

| 方式 | 利点 | 負担 | 判断 |
| --- | --- | --- | --- |
| 接続ごとの OS thread | 同期 handler と body reader を実装しやすい | idle 接続でも thread を保持し、多数接続で負担が増える | 今回の主方式にしない |
| 非ブロッキング I/O と接続状態機械 | 現在の TCP API を使え、少数 thread で多数接続を管理できる | buffer 寿命、partial I/O、公平性の設計が必要 | 推奨 |
| async runtime または外部 HTTP engine | より広い実行モデルや既存 parser を利用できる | runtime、FFI、配布の追加設計が必要 | 初版対象外 |

初版は一つの event loop を持つサーバーとし、handler はその loop 上で同期実行する。
Go の API の役割分担を参考にするが、goroutine と同じ実行特性は約束しない。
blocking I/O や長時間 CPU 処理を handler に入れると同じ loop の接続を止めるため、用途と制約を API ドキュメントに明記する。
マルチコア利用と重い handler の offload は後続段階とし、thread 間で接続所有者を共有する設計は持ち込まない。
参照: [Go net/http](https://pkg.go.dev/net/http)。

## 初版の公開 API と所有権

以下は責務を定める API 案。Mojo の具体的な signature と borrow 制約は Phase 0 の compile probe で固定する。

| 型または操作 | 契約 |
| --- | --- |
| `Request` | method、request target、version、headers、body を参照する。request target の path と query は分離し、暗黙の percent decoding はしない |
| `Headers` | 大文字小文字を区別しない検索と重複値の列挙。すべてを一律にカンマ結合しない |
| `ResponseWriter` | status と headers を設定し、上限付きの response buffer に body を書く。socket を直接待たず、handler 終了後に server が送信する |
| `Handler` | request を借用し、response writer を変更する。コンパイル時に handler 型を選べる構成を優先する |
| `ServerConfig` | 接続数、byte 上限、各 deadline、公平性の処理量上限を保持する |
| `Server.serve` | listener の所有権を受け取り、handler を使用して loop を実行する |
| `listen_and_serve` | bind と serve の便利関数 |
| `ServerControl.request_shutdown` | thread 間では停止要求だけを安全に渡す。wakeup fd で loop を起こし、socket の操作は owner が実行する |

request の views と response writer は handler 呼び出し中だけ有効とする。
受信 buffer は呼び出し中に移動、拡張、再利用しない。保持したい値は明示的にコピーする。
response は送信完了まで接続が所有する。短命な handler の値を送信待ち queue に借用しない。
初版では request body 全体を上限付きで受信してから handler を呼ぶ。
request streaming、response streaming、`Flush`、汎用 router、middleware framework は初版に含めない。
handler は method/path で分岐できる。未処理 path の例は 404 を返す。

## 最終形から逆算する共通境界

`Request`、`Headers`、`Handler`、`ResponseWriter` は HTTP semantics を共有し、wire format と接続状態機械を HTTP/1.1、HTTP/2、HTTP/3 ごとに分ける。
Phase 0 から method、scheme、authority、path/query、trailers を表現できる契約を定める。HTTP/2 と HTTP/3 の pseudo-header は protocol adapter で変換し、一般 header と混ぜない。
HTTP/1.1 の request line、chunked encoding、接続一つにつき一 request という制約は共通 handler に持ち込まない。
Phase 1 の `_parser` と `_encoder` は HTTP/1.1 専用とし、HTTP/2 と HTTP/3 はそれぞれ `_http2/` と `_http3/` に配置する。
stream の状態と connection の状態を分け、request と response の buffer 寿命は stream owner に結び付ける。初版の HTTP/1.1 では一接続に active request が一つとなる。
HTTP/2 と HTTP/3 では stream 単位の deadline、cancel、flow control、budget と connection 全体の上限を併用する。一 stream の送信待ちで connection 全体の読み取りを止めず、制御 frame と他 stream を処理する。
HTTP/1.1 の close に相当する処理を一律に connection close へ変換しない。stream error、connection error、GOAWAY と drain を adapter ごとに定義する。
初版の bounded buffered handler を各 protocol で利用可能にし、streaming API は別の追加設計とする。wire 上の stream 多重化と CPU 上の handler 並列実行は区別する。

## HTTP/1.1 マイルストーンの対象範囲

HTTP/1.1 の平文 origin server を対象にする。TLS は前段で終端できる構成とする。
HTTP/2 と HTTP/3、および server 自身の TLS 終端は後続の必須 Phase で実装する。
HTTP/1.0、HTTP client、WebSocket、CONNECT tunnel、Upgrade、multipart の高水準 API、body 圧縮、静的ファイル配信は本 Issue の対象外とする。

- incremental parser を実装し、任意の byte 境界で分割された入力、複数 request の同時到着、binary body を扱う。
- request line と header は CRLF を厳密に扱い、不正 token、改行注入、obs-fold、Host の欠落／重複／不正値を拒否する。
- origin-form と absolute-form を扱い、absolute-form の authority を Host に優先する。`OPTIONS *` を扱う。CONNECT と Upgrade は切替を行わず、明示的なエラーにする。
- `Content-Length` と chunked request を扱う。Transfer-Encoding と Content-Length の併存、矛盾する長さ、不正 chunk、overflow を拒否して close する。重複 Content-Length は同値でも拒否する保守的方針を仕様化する。
- chunk extension と trailer は別の byte／件数上限で検証する。trailer を header に混ぜず別に保持し、framing や routing を変更させない。
- `Expect: 100-continue` は header 検証と既知の body 上限判定後に 100 を送信して受信を継続する。他の expectation は 417 と close。
- keep-alive と `Connection: close` を扱う。pipelining は一接続一 request ずつ処理し、response の順序を保存する。次 request を無制限に queue に積まない。
- HEAD、204、304 など body を送らない response の規則を encoder に集約する。通常の buffer response は確定した Content-Length を付ける。Date を生成し、response header の改行注入を拒否する。
- 不正構文は 400、body 超過は 413、request target 超過は 414、header 超過は 431、非対応 HTTP version は 505 とする。安全に response を送れない状態は close のみとする。
- EOF が完全な request の後なら response を送って close できる。未完の request を成功として処理しない。

framing と接続管理の基準は [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html)、method と status の意味は [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html) とする。
実装時に上記方針を節番号付き conformance table と wire-level fixture に対応付ける。

## HTTP/1.1 の実行モデルと共通 readiness 基盤

接続状態は header 受信 → body 受信 → handler → response 送信 → 次 request または close。
100 応答などの中間送信状態も明示する。

- server が connection table と buffer を所有する。stable slot と generation を event token に使い、close 後の古い通知を fd 再利用先に適用しない。
- socket I/O は `try_*` を使う。would-block の `NetErrorKind.timeout()` は待機再登録に変換し、server 自身の deadline 満了と区別する。
- writable 監視は送信残があるときだけ有効にする。partial write の offset を保持し、送信待ち中は追加 request の受信を抑える。
- 一巡の accept 数、接続ごとの byte 数と request 数を制限する。残ったユーザー空間の入力は runnable queue に戻し、次の kernel readiness がなくても処理を再開する。
- response と header buffer は容量上限内で再利用する。文字列化、header hash map、request ごとのコピーを増やす前に計測する。
- SIMD parser、`writev`、`sendfile`、edge-triggered I/O、共有 pool は baseline 計測後に必要なものだけ採用する。

多数接続向けに `net/_reactor.mojo` と `net/_sys/readiness.mojo` を追加する案とする。
HTTP 内部から利用する reactor は stable token、interest 更新、ready event batch を提供する。
現行 `Poller` の index と重複 fd の公開契約を無理に変更しない。新層は当面 internal とし、二つの公開 API を維持する負担を避ける。
検証用 poll 実装を先に作り、最終版は Linux で epoll、macOS で kqueue をコンパイル時選択する。runtime fallback は設けない。
poll 実装は比較用 commit または benchmark 専用とし、最終 production path に残さない。
最初は level-triggered を採用する。ABI は各 target の size だけでなく offset、alignment、event token の往復もテストする。
参照: [epoll](https://man7.org/linux/man-pages/man7/epoll.7.html)、[Apple kqueue](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/kqueue.2.html)。

## HTTP/1.1 のリソース上限と停止

初期値の提案。性能試験には実際の設定値を必ず記録する。

| 設定 | 初期値 |
| --- | --- |
| 同時接続上限 | 10,000 |
| request line | 8 KiB |
| header 総量／件数 | 32 KiB／100 |
| decoded request body | 1 MiB |
| chunk metadata 総量（extension を含む） | 64 KiB / request |
| trailer 総量／件数 | 8 KiB／32 |
| response body | 1 MiB |
| response header 総量／件数 | 32 KiB／100 |
| server 全体の buffer 容量 budget | 256 MiB |
| header／body／write deadline | 5 秒／30 秒／30 秒 |
| idle keep-alive timeout | 60 秒 |
| graceful shutdown 猶予 | 30 秒 |
| 一巡の accept／接続ごとの処理量 | 64 接続／64 KiB または 16 requests |

buffer の初期確保は小さくし、実確保容量と保持中の再利用容量を全体 budget に計上する。
ResponseWriter の拡張前にも容量差分を budget から予約する。上限超過や確保失敗は handler error として処理し、使用していない予約は解放する。
一接続の上限だけでなく、同時 body 受信と slow reader が全体 budget を超えないよう admission を制限する。
budget を予約できない request は受信を継続せず、可能なら 503 と close。エラー応答用に小さい固定容量を確保する。
接続上限に達したら listener の受け入れを一時停止し、空きができたら再開する。

deadline は単調時計による絶対時刻とし、byte を一つ受信するたびに延長しない。
indexed min-heap などで一接続一 deadline を更新し、期限確認のために毎回全接続を走査しない。
停止要求は accept を止め、idle 接続を閉じ、開始済み request の response を猶予内で送って閉じる。
期限に達したら owner が残った接続を解除して close する。完了済みまたは pipeline 内の次 request は新規処理しない。
handler の同期実行自体は強制中断できないため、停止期限も handler が制御を返すことを前提とする。
control handle は server より長く生存できる。共有 control state が wakeup 資源と終了状態の寿命を管理し、終了後の要求は何もせず成功する。
停止要求は冪等とし、通知と wakeup fd の破棄を同期して、close 済みまたは再利用済みの fd に書き込まない。通知が既に保留なら再通知は不要とする。

## 実装計画

各 Phase をレビュー可能な PR として実施する。実装前に失敗する契約テストを用意し、実装後に対象テストと既存回帰テストを通す。
依存順は Phase 0 → Phase 1 と Phase 2 → Phase 3 → Phase 4 → Phase 5 → Phase 6 → Phase 7 → Phase 8 → Phase 9 → Phase 10。
Phase 6〜9 はそれぞれ実装前に詳細仕様と PR 単位の計画を作成するが、設計だけで完了にはしない。対応する protocol を実装して検証することが必須。

### Phase 0: API と計測条件を固定する

- [ ] `docs/design/http-server.md` に API の実 signature、borrow 寿命、エラー契約、HTTP conformance table を記録する。
- [ ] HTTP/2 と HTTP/3 の pseudo-header mapping、stream 所有権、connection と stream の分離を確認し、HTTP/1.1 固有の前提が共通 API に漏れていないことをレビューする。
- [ ] `tests/test_http_api.mojo` に handler trait、借用 Request、buffer 所有権、control handle の最小 compile probe を作る。対応 Mojo で成立しない API はこの段階で修正する。
- [ ] `benchmarks/http_go/main.go` と `benchmarks/http/README.md` に Go baseline と測定条件を用意し、バージョン、CPU 制限、最適化設定を固定する。
- [ ] baseline の出力を検証し、比較に使う request／response bytes と handler 処理を一致させる。

完了条件: API のコンパイル確認、計測手順、対象機能と非対応機能がレビュー可能。

### Phase 1: ソケット非依存の HTTP codec

- [ ] `net/http/{__init__,request,headers,response,error,_parser,_encoder}.mojo` を追加する。
- [ ] `tests/test_http_parser.mojo` に全 byte 境界での分割、連結、binary body、chunked、Host、CL/TE、overflow、上限超過の table-driven tests を追加する。
- [ ] `tests/test_http_response.mojo` で HEAD、204、304、Date、重複 headers、response injection、長さ整合性を確認する。
- [ ] `benchmarks/http_parse.mojo` で parser の時間と入力サイズ別の結果を記録する。

完了条件: socket なしで任意の入力分割でも同じ結果と consumed byte 数を返す。次 request の bytes を body と誤認しない。

### Phase 2: reactor と TCP の前提を整える

- [ ] `net/_reactor.mojo` に register／modify／remove／wait と stable token を実装する。Phase 3 の baseline 用には poll を使用する。
- [ ] `net/tcp.mojo` の三つの accept 経路について、`tests/test_tcp.mojo` で TCP_NODELAY の実効値を getsockopt で確認し、必要な統一を行う。
- [ ] `tests/test_reactor.mojo` に interest 変更、idle 時の待機、read/write 同時通知、fd 再利用、古い generation、EINTR、解除と close の tests を追加する。

完了条件: socket の単一所有を保ち、未送信データがない接続で writable busy loop が発生しない。

### Phase 3: HTTP server と上限付き接続管理

- [ ] `net/http/{server,handler,_connection,_buffer,_deadline}.mojo` に状態機械、buffer budget、公平性、deadline、shutdown control を実装する。
- [ ] `tests/test_http_server.mojo` に keep-alive、pipeline 順序、100-continue、partial I/O、EOF、slow reader、slow header/body、budget 超過、handler error、停止中の接続を追加する。
- [ ] control の重複要求、serve 完了後の要求、server エラー終了との競合、ResponseWriter 拡張時の全体 budget 超過をテストする。
- [ ] handler error は未送信 response を破棄して 500 と close とし、別接続の loop は継続する。エラー詳細は response に漏らさない。
- [ ] `examples/http_hello.mojo` と `examples/http_json.mojo` を追加し、raw TCP client と Go HTTP client で応答を確認する。
- [ ] poll 版 server の性能とメモリ使用量を保存する。

完了条件: 一つの slow client が他の接続を待たせず、上限が実測とテストで守られ、停止後に fd と buffer が残らない。

### Phase 4: epoll／kqueue と性能検証

- [ ] `net/_sys/{readiness,linux,darwin}.mojo` に OS event queue の bindings と ABI checks を追加する。HTTP に libc 直接呼び出しを追加しない。
- [ ] reactor の内部を epoll／kqueue に変更し、ready batch のみを処理する。deadline と connection 管理も全登録走査を避ける。
- [ ] Phase 2 と Phase 3 の同じ契約テストを両 OS で通す。kqueue の EOF と未読データ、epoll の packed ABI、queue fd のリークを検証する。
- [ ] `benchmarks/http_server.mojo` と `benchmarks/http/README.md` に poll 版との差分、Go 比較、CPU profile、メモリ測定を保存する。
- [ ] ボトルネックに対応する最適化だけを追加し、前後の測定を残す。

完了条件: 多数の idle 接続時に active event の処理が全接続数に比例する走査を含まず、下記の測定表と目標との差が示される。

### Phase 5: CI、配布、利用ドキュメント

- [ ] `pixi.toml` に `test-http-api`、`test-http-parser`、`test-http-response`、`test-reactor`、`test-http-server`、`benchmark-http-parse`、`benchmark-http-server` を追加する。
- [ ] `.github/workflows/ci.yml` の macOS arm64、Linux x86_64、Linux aarch64 で warning-clean tests と package smoke を実行する。
- [ ] `tests/package_smoke.mojo` に配布 artifact からの `net.http` import と codec の利用確認を追加する。
- [ ] parser の malformed corpus、seed を記録する randomized fragmentation tests、対応環境での sanitizer と長時間の fd／RSS leak tests を整備する。
- [ ] `README.md`、`CHANGELOG.md`、`docs/design/net-package.md` に使い方、制限、ownership、性能再現手順を反映する。

完了条件: `pixi run test`、`pixi run package`、`pixi run test-package` と HTTP integration tests が各 target で成功する。
性能の閾値は共有 CI の合否判定に使わない。

### Phase 6: TLS と ALPN の実装

- [ ] `docs/design/http-tls.md` で TLS provider を比較し、Mojo FFI、対応 OS、ライセンス、配布、更新方針、QUIC handshake API の有無を検証して採用する provider を固定する。
- [ ] `net/tls/` に非ブロッキング handshake、暗号化 I/O、証明書設定、ALPN、close を実装し、reactor の read/write interest と連携する。暗号 primitive を独自実装しない。
- [ ] core `net` は既存の std/libc 依存を維持する。HTTPS と QUIC 用の依存を明示した build/package 構成を作り、暗黙の平文 downgrade を行わない。
- [ ] `tests/test_tls.mojo` と `examples/https_hello.mojo` で handshake 分割、handshake timeout、不正 handshake、ALPN の選択、shutdown、fd／buffer 解放を確認する。テスト専用証明書を使用する。

完了条件: HTTPS の HTTP/1.1 が動作し、Phase 7 の HTTP/2 adapter を選べる ALPN 接続契約が成立する。QUIC では TLS record I/O を流用せず handshake 統合用 API を利用できることを確認する。

### Phase 7: HTTP/2 の実装

- [ ] `docs/design/http2-server.md`、`net/http/_http2/`、`tests/test_http2.mojo` を追加する。TLS 上の ALPN `h2` を標準の入口とする。
- [ ] connection preface、SETTINGS、frame parser、stream 状態機械、HPACK、pseudo-header 検証を実装し、既存 handler に接続する。
- [ ] connection と stream の flow control、WINDOW_UPDATE、RST_STREAM、PING、GOAWAY、trailer、公平な送信 scheduling を実装する。server push は提供しない。
- [ ] 同時 stream 数、展開後 header、圧縮 table、control frame 処理量、stream 作成／reset 頻度に上限を設ける。body 全受信待ちでも receive window を適切に更新し、初期 window より大きい body が deadlock しないようにする。
- [ ] 異常 frame、CONTINUATION、window 枯渇、reset storm、一 stream の停止と別 stream の進行、GOAWAY 中の drain をテストする。HTTP/1.1 と同じアプリケーション契約テストを実行する。
- [ ] `examples/http2_hello.mojo` と独立した HTTP/2 client で TLS 相互運用を検証し、CI と配布 smoke に追加する。

完了条件: 一 TLS 接続の複数 stream を処理し、flow control、cancel、上限、graceful shutdown を検証できる。
仕様: [HTTP/2 RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html)。

### Phase 8: QUIC transport の導入と実装

- [ ] `docs/design/quic-transport.md` で既存 QUIC engine の利用と transport 自作を比較する。初期案は保守される既存 engine を FFI で利用し、対応 OS、TLS 統合、ライセンス、更新頻度、メモリ管理、性能を検証して固定する。HTTP/3 の提供は engine 自作を前提にしない。
- [ ] `net/quic/` と `tests/test_quic.mojo` を追加し、UDP 入出力、connection ID、timer、pacing、TLS 1.3 handshake、stream 入出力と終了を reactor に統合する。
- [ ] loss recovery、congestion control、address validation、anti-amplification は採用 engine の実装を利用し、アプリ側で必要な timer と送信処理を漏れなく駆動する。
- [ ] stream／connection flow control、cancel、idle timeout、close と draining、NAT rebinding、パケット損失／重複／並べ替えをテストする。初回提供では 0-RTT を無効にする。
- [ ] engine 内部の送受信、再送、reassembly、暗号状態のメモリも budget に含め、接続数だけでは制限できない消費を測定する。

完了条件: 独立実装と QUIC 接続を確立して複数 stream を交換でき、loss と timeout を含めた終了後に資源が残らない。
仕様: [QUIC RFC 9000](https://www.rfc-editor.org/rfc/rfc9000.html)。TLS 統合と loss recovery は RFC 9001 と RFC 9002 に対応する採用 engine の適合範囲を検証する。

### Phase 9: HTTP/3 の実装

- [ ] `docs/design/http3-server.md`、`net/http/_http3/`、`tests/test_http3.mojo` を追加し、QUIC 上の ALPN `h3` で同じ handler を利用する。
- [ ] control stream、SETTINGS、request stream の HEADERS／DATA、QPACK encoder／decoder stream、pseudo-header と trailer を実装する。採用 QUIC engine に HTTP/3 機能がある場合はそれを利用し、重複実装を避ける。
- [ ] QPACK table と blocked stream 上限、stream cancel、connection error、GOAWAY、drain を実装する。server push は提供しない。
- [ ] control／QPACK stream に必要な credit を確保し、request の flow control によって制御処理が deadlock しないことを検証する。
- [ ] HTTPS 側の Alt-Svc 広告と HTTP/3 endpoint 設定を追加し、TCP 側と UDP 側で同じ origin を扱う。UDP を利用できない環境でも HTTPS endpoint を独立して提供できるようにする。
- [ ] `examples/http3_hello.mojo`、独立した HTTP/3 client、protocol を明示確認する integration test を追加する。HTTPS 側に接続しただけの結果を HTTP/3 成功として扱わない。

完了条件: 同じアプリを HTTP/3 で利用でき、QPACK blocking、複数 stream、cancel、loss、shutdown を含む相互運用試験が通る。
仕様: [HTTP/3 RFC 9114](https://www.rfc-editor.org/rfc/rfc9114.html)、[QPACK RFC 9204](https://www.rfc-editor.org/rfc/rfc9204.html)。

### Phase 10: 三つの protocol の性能、CI、配布を検証する

- [ ] macOS arm64、Linux x86_64、Linux aarch64 で HTTP/1.1、HTTP/2、HTTP/3 の共通 handler tests、protocol tests、TLS／QUIC provider を含む package smoke を通す。
- [ ] `benchmarks/http/README.md` に protocol 別の baseline、暗号化設定、接続数、同時 stream 数、handshake 有無、RTT、loss、CPU とメモリ消費を記録する。
- [ ] HTTP/2 は同じ TLS 条件の Go HTTP/2 server、HTTP/3 はバージョン固定した独立 HTTP/3 server を baseline にする。HTTP/1.1 の平文数値や Go 標準 HTTP/3 の存在を前提に比較しない。
- [ ] 多重化では connection 数と stream 数を独立して変え、slow stream、cancel、RTT と loss を含めて throughput と p99 を測定する。各 Phase の開始時に数値目標を記録し、結果を見てから達成基準を変更しない。
- [ ] 同一 host／port 番号の TCP HTTPS と UDP HTTP/3 の運用例、protocol 選択、証明書、上限、shutdown、依存更新をドキュメント化する。

完了条件: 三つの protocol を実際に提供し、相互運用、resource bounds、再現可能な性能結果と配布方法が揃う。

## HTTP/1.1 の性能の測り方と暫定目標

Go baseline は同一 handler、同一 HTTP 機能、同じ keep-alive、payload、接続数、ソケット設定、ログ無効で比較する。
まず server 側を 1 core 相当に揃え、Go は `GOMAXPROCS=1` とする。負荷生成側には別の CPU または別ホストを使う。
本番測定は最適化済み実行ファイルで行い、コンパイルと起動時間は測定区間から除外する。

| シナリオ | 条件 |
| --- | --- |
| 小さい固定 response | GET、64 B body、接続数 1／64／1,024 |
| 小さい API response | 1 KiB JSON、Go と同じ構築処理 |
| request body | POST、1 KiB／64 KiB、Content-Length と chunked |
| 多数 idle 接続 | 10,000 keep-alive、うち 100 接続を active にする |
| 接続 churn | keep-alive 無効、accept／close を継続する |
| slow client | slow header、slow body、slow reader を通常 client と混在させる |

warmup 10 秒、測定 30 秒を最低 5 回実行する。
req/s、bytes/s、p50／p95／p99、エラー率、CPU、RSS、fd 数を記録する。
allocation と syscall 数は使用可能な profiler とその overhead を明記した別測定にする。
飽和 throughput と、固定到着率での latency を分ける。後者では coordinated omission を避ける負荷生成器を使い、client 自身の飽和も確認する。

暫定の開発目標は、小さい固定 response の接続数 64 と 1,024 で Go baseline の 90% 以上の throughput、共通の非飽和負荷で p99 が Go の 1.2 倍以内。
これは未検証の目標値であり、Phase 0 で測定機を固定する。未達の場合は結果と profile を示して課題を残し、機能を削って数値だけを合わせない。
10,000 接続の測定では成功した接続数を確認し、OS の fd 上限と全体 buffer budget を併記する。
30 分の soak test で fd の単調増加がなく、RSS が設定 budget と connection metadata に基づく範囲で安定することも確認する。

## 初版完了後の拡張

streaming body と backpressure 対応 writer、複数 loop の worker model、重い handler の bounded offload queue は本ロードマップの必須 protocol 対応とは別の追加設計とする。
特に multicore は worker ごとの listener／接続所有、handoff、wakeup、shutdown、handler 状態の共有可否を定めてから実装する。
これらを提供するまでは「Go の net/http と同じ並行実行モデル」や「汎用 production HTTP stack」とは表現しない。

## Issue の完了条件

- [ ] Phase 0〜10 の実装成果物とテスト結果が揃う。HTTP/1.1 完了のみでは本 Issue を close しない。
- [ ] 共通 handler で HTTP/1.1、HTTP/2、HTTP/3 の request／response を処理できる。
- [ ] server 自身の TLS／ALPN と QUIC が動作し、HTTP/2 と HTTP/3 を独立 client で検証できる。
- [ ] HTTP 適合範囲、非対応機能、handler の制約が公開ドキュメントに明記される。
- [ ] correctness と resource bounds を満たす。
- [ ] 性能比較を再現でき、暫定目標の達成／未達と後続課題が記録される。

## Phase 0 固定事項（実装済み）

Phase 0 では API の実 signature、borrow 寿命、エラー契約、conformance table、
HTTP/2・HTTP/3 を見据えた共通境界、計測条件を固定した。
`Server.serve` の loop 本体は Phase 3、codec は Phase 1、reactor は Phase 2 で実装する。

### 実 signature

利用側は `from net.http import ...` とする。`net/__init__.mojo` への再 export は行わない。

```mojo
# net/http/headers.mojo
struct Headers(Movable, Sized):
    def __init__(out self)
    def add(mut self, var name: String, var value: String) raises NetError
    def clear(mut self)
    def get_first(self, name: StringSlice) -> Optional[String]
    def get_all(self, name: StringSlice) -> List[String]
    def count(self, name: StringSlice) -> Int
    def name_at(self, index: Int) -> String
    def value_at(self, index: Int) -> String

# net/http/request.mojo
struct HttpVersion(Copyable, Equatable, Writable):
    def http10() -> Self
    def http11() -> Self
    def is_supported(self) -> Bool

struct Request(Movable):
    var method: String
    var target: String
    var path: String
    var query: String
    var scheme: String
    var authority: String
    var version: HttpVersion
    var headers: Headers
    var trailers: Headers
    var body: List[Byte]

def split_path_query(target: StringSlice) -> Tuple[String, String]

# net/http/response.mojo
struct ResponseWriter(Movable, Sized):
    def __init__(out self, body_limit: Int)
    def set_status(mut self, status: Int)
    def set_should_close(mut self, should_close: Bool)
    def body_limit(self) -> Int
    def write[origin: ImmOrigin](mut self, data: Span[Byte, origin]) raises NetError
    def write_string(mut self, data: StringSlice) raises NetError

def has_body_for_status(status: Int, is_head: Bool) -> Bool

# net/http/handler.mojo
trait Handler(Movable):
    def handle(mut self, req: Request, mut writer: ResponseWriter) raises: ...

# net/http/error.mojo
struct HttpError(Copyable, Movable, Writable):
    var status: Int
    var message: String
    var should_close: Bool
    # bad_request / payload_too_large / uri_too_long / header_too_large /
    # version_not_supported / expectation_failed / internal / unavailable

# net/http/config.mojo
struct ServerConfig(Copyable, Movable):
    var max_connections: Int              # 10,000
    var max_request_line: Int             # 8 KiB
    var max_headers_bytes: Int            # 32 KiB
    var max_headers_count: Int            # 100
    var max_body_bytes: Int               # 1 MiB
    var max_chunk_metadata: Int           # 64 KiB
    var max_trailer_bytes: Int            # 8 KiB
    var max_trailer_count: Int            # 32
    var max_response_body: Int            # 1 MiB
    var max_response_headers_bytes: Int   # 32 KiB
    var max_response_headers_count: Int   # 100
    var total_buffer_budget: Int          # 256 MiB
    var header_deadline: Timeout          # 5 s
    var body_deadline: Timeout            # 30 s
    var write_deadline: Timeout           # 30 s
    var idle_timeout: Timeout             # 60 s
    var shutdown_grace: Timeout           # 30 s
    var max_accept_per_tick: Int          # 64
    var max_bytes_per_tick: Int           # 64 KiB
    var max_requests_per_tick: Int        # 16
    @staticmethod
    def default() raises -> Self

# net/http/server.mojo
struct ServerControl(Movable):
    def __init__(out self)
    def request_shutdown(mut self)
    def is_shutdown_requested(self) -> Bool
    def mark_exited(mut self)

struct Server(Movable):
    def __init__(out self, var config: ServerConfig)
    def is_shutdown_requested(self) -> Bool
    def request_shutdown(mut self)
    def serve[H: Handler](mut self, var listener: TCPListener, mut handler: H) raises

def listen_and_serve[H: Handler](
    address: StringSlice, var config: ServerConfig, mut handler: H
) raises
```

`serve` と `listen_and_serve` は Phase 0 では signature 固定のみで `not implemented`
を返す。compile probe は `tests/test_http_api.mojo`（14 tests）で handler trait、
借用 Request、buffer 所有権、control handle を確認する。

### borrow 寿命

| 値 | 所有者 | 有効期間 |
| --- | --- | --- |
| 受信 buffer と `Request` の各 view | server の connection table | handler 呼び出し中のみ。呼び出し中の移動・拡張・再利用なし。保持はコピーで行う |
| `ResponseWriter` と `body` | connection（送信完了まで） | handler 終了後に server が送信。handler の短命値を借用して queue に積まない |
| `TCPConn` / `TCPListener` | 単一 owner | `raw_fd()` は借用。登録解除から close まで owner を生存させる。thread 間は fd 番号のみを渡す |
| `ServerControl` | 共有 control state（wakeup 資源と終了状態の寿命を管理） | server より長生き可。終了後の要求は no-op。冪等。通知と wakeup fd 破棄を同期し、close 済み fd に書かない |

初版は bounded buffered のみ。request body 全体を上限付きで受信してから handler を呼ぶ。
request streaming、response streaming、`Flush`、router、middleware は含めない。

### エラー契約

transport 失敗は `NetError`、HTTP 失敗は `HttpError(status, should_close)`。
`handler` の raise と response budget 超過は未送信 response を破棄して 500 と close、
詳細は response に漏らさない。budget 予約不可は 503 と close（小さい固定の error 応答容量を確保）。

| 状態 | status | 備考 |
| --- | --- | --- |
| 不正構文・token・改行注入・obs-fold・Host 欠落/重複/不正・CL/TE 併存・矛盾長・不正 chunk・overflow・trailer 誤用 | 400 | 安全に送れない状態は close のみ |
| decoded body 超過・chunk metadata 超過 | 413 | header 妥当後の body 超過 |
| request target 超過 | 414 | - |
| request line 超過（target 外）・header 総量/件数超過・trailer 総量/件数超過 | 431 | - |
| 非対応 version | 505 | - |
| 未知の `Expect` | 417 と close | `100-continue` のみ継続（header 検証と body 上限判定後に 100） |
| handler error・response 拡張時の budget 超過 | 500 と close | 別接続の loop は継続 |
| 全体 budget 予約不可 | 503 と close | - |

### HTTP conformance table（RFC 9112 対応付け）

| # | 方針 | RFC 9112 節 | fixture / test（予定） |
| --- | --- | --- | --- |
| C1 | 任意 byte 境界分割・連結・binary body・複数 request 同時到着 | §2.1, §5, §6 | `test_http_parser`: 全境界分割 table |
| C2 | request line・header は CRLF 厳密、不正 token・注入・obs-fold 拒否 | §2.2, §5.1, §5.2, §5.5 | malformed corpus + 400 |
| C3 | Host 欠落/重複/不正を拒否 | §3.2 | Host table |
| C4 | origin-form・absolute-form（authority を Host に優先）・`OPTIONS *` | §3.1, §3.2 | target-form table |
| C5 | CONNECT・Upgrade は切替せず明示 error | §3.1, §7.2 相当 | 400/505 側に整理 |
| C6 | Content-Length・chunked、併存・矛盾・不正 chunk・overflow を拒否して close。重複 CL は同値でも拒否 | §6.1–§6.3 | CL/TE table + overflow |
| C7 | chunk extension・trailer は別上限で検証、header に混入せず framing/routing 不変 | §7.1 | trailer 分離 test |
| C8 | `Expect: 100-continue` は検証後に 100、その他は 417 と close | §10.1.1 | 100-continue test |
| C9 | keep-alive・`Connection: close`。pipelining は一接続一 request ずつ順序保存、無制限 queue なし | §7.3, §9.3 | keep-alive・pipeline 順序 |
| C10 | HEAD・204・304 の body 規則は encoder 集約。通常は確定 Content-Length。Date 生成。response 注入拒否 | §6.4, §5.3 相当 | `test_http_response` |
| C11 | EOF が完全 request の後なら送って close、未完は成功扱いしない | §9.6 | EOF test |

method・status の意味は RFC 9110 による。Phase 1 で節番号付き table と wire fixture に対応付ける。

### HTTP/2・HTTP/3 を見据えた共通境界（確認済み）

- `Request`・`Headers`・`Handler`・`ResponseWriter` は semantics 共有、wire と状態機械は分離。
  Phase 1 の `_parser`・`_encoder` は HTTP/1.1 専用、H2 は `_http2/`、H3 は `_http3/`。
- `scheme`・`authority`・`path`・`query`・`trailers` を Phase 0 から表現。
  H2/H3 pseudo-header（`:method`・`:scheme`・`:authority`・`:path`）は adapter で変換し一般 header に混ぜない。
- request line・chunked・一接続一 request の制約を共通 handler に持ち込まない。
- stream 状態と connection 状態を分離、buffer 寿命は stream owner に結合。H1 初版は一接続一 active request。
- H2/H3 は stream 単位の deadline・cancel・flow control・budget と connection 上限を併用。
  一 stream の送信待ちで全体読み取りを止めず、制御 frame と他 stream を処理する。
- H1 の close を一律 connection close に変換しない。stream error・connection error・GOAWAY・drain は adapter ごとに定義。
- bounded buffered handler を各 protocol で再利用、streaming は別設計。wire 多重化と CPU 並列実行は区別する。

### 計測条件（固定）

`benchmarks/http/README.md` と `benchmarks/http_go/main.go` に固定。
Go `go1.26.4`、`/fixed` 64 B・`/json` 1024 B・`/echo` 上限 1 MiB を検証済み。
`GOMAXPROCS=1`、別 CPU/別 host 負荷、warmup 10 s・測定 30 s x 5 回、req/s・p50/p95/p99・CPU・RSS・fd を記録。
暫定目標は 64/1024 接続で Go の 90% throughput、非飽和 p99 1.2 倍以内（未検証）。
