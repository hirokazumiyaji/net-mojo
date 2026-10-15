# 実用化ロードマップと受け入れ証拠

2026年10月14日時点の Issue226–239 の機能、検証、公開と残る受け入れ条件を記録する。
閉じた [PR241](https://github.com/hirokazumiyaji/net-mojo/pull/241) の SECURITY、互換性方針、deprecation 提案は対象外であり、Issue226/239 の対応項目も完了扱いにしない。
v0.2 は要求された機能と品質の確認後に扱う。

実装、コードレビュー、ローカル検証、PR公開、公開 head の CI 成功は別の状態である。
短い smoke や schedule の定義だけでは、夜間運転、週次運転、継続稼働の条件は満たさない。

## Issue と PR の対応

| Issue | 対象 | PR | 状態 |
|---|---|---|---|
| [226](https://github.com/hirokazumiyaji/net-mojo/issues/226) | 配布と dogfood | [240](https://github.com/hirokazumiyaji/net-mojo/pull/240)、[242](https://github.com/hirokazumiyaji/net-mojo/pull/242)、[243](https://github.com/hirokazumiyaji/net-mojo/pull/243) | 配布基盤と smoke は確認済み。実際の配布と7日稼働は未確認。 |
| [227](https://github.com/hirokazumiyaji/net-mojo/issues/227) | fuzz、適合性、縮小と再実行 | [244](https://github.com/hirokazumiyaji/net-mojo/pull/244)–[253](https://github.com/hirokazumiyaji/net-mojo/pull/253) | 実装、レビュー、ローカル検証済み。公開済み、修正後の CI 待ち。 |
| [228](https://github.com/hirokazumiyaji/net-mojo/issues/228) | property tests | [254](https://github.com/hirokazumiyaji/net-mojo/pull/254)–[259](https://github.com/hirokazumiyaji/net-mojo/pull/259) | 実装、レビュー、ローカル検証済み。公開済み、修正後の CI 待ち。 |
| [229](https://github.com/hirokazumiyaji/net-mojo/issues/229) | ServerPool | [260](https://github.com/hirokazumiyaji/net-mojo/pull/260)–[263](https://github.com/hirokazumiyaji/net-mojo/pull/263) | 実装、レビュー、ローカル検証済み。公開済み、修正後の CI 待ち。 |
| [230](https://github.com/hirokazumiyaji/net-mojo/issues/230) | HTTP/1・HTTP/2・HTTP/3 入力 streaming | [279](https://github.com/hirokazumiyaji/net-mojo/pull/279)–[289](https://github.com/hirokazumiyaji/net-mojo/pull/289)、[293](https://github.com/hirokazumiyaji/net-mojo/pull/293) | 実装、レビュー、ローカル検証済み。公開済み、修正後の CI 待ち。 |
| [231](https://github.com/hirokazumiyaji/net-mojo/issues/231) | router と middleware | [264](https://github.com/hirokazumiyaji/net-mojo/pull/264)–[269](https://github.com/hirokazumiyaji/net-mojo/pull/269) | 実装、レビュー、ローカル検証済み。公開済み、修正後の CI 待ち。 |
| [232](https://github.com/hirokazumiyaji/net-mojo/issues/232) | HTTP/2・HTTP/3 detach | [270](https://github.com/hirokazumiyaji/net-mojo/pull/270)–[278](https://github.com/hirokazumiyaji/net-mojo/pull/278) | 実装、レビュー、ローカル検証済み。公開済み、修正後の CI 待ち。 |
| [233](https://github.com/hirokazumiyaji/net-mojo/issues/233) | WorkerPool と offload | [290](https://github.com/hirokazumiyaji/net-mojo/pull/290)–[292](https://github.com/hirokazumiyaji/net-mojo/pull/292)（関連293） | 実装、レビュー、ローカル検証済み。公開済み、修正後の CI 待ち。 |
| [234](https://github.com/hirokazumiyaji/net-mojo/issues/234) | 同期 HTTP/1.1 client | [304](https://github.com/hirokazumiyaji/net-mojo/pull/304)–[307](https://github.com/hirokazumiyaji/net-mojo/pull/307) | 実装、レビュー、ローカル検証済み。公開済み、修正後の CI 待ち。 |
| [235](https://github.com/hirokazumiyaji/net-mojo/issues/235) | CONNECT・Upgrade・hijack | [299](https://github.com/hirokazumiyaji/net-mojo/pull/299)–[303](https://github.com/hirokazumiyaji/net-mojo/pull/303) | 実装、レビュー、ローカル検証済み。公開済み、修正後の CI 待ち。 |
| [236](https://github.com/hirokazumiyaji/net-mojo/issues/236) | WebSocket | [312](https://github.com/hirokazumiyaji/net-mojo/pull/312)–[316](https://github.com/hirokazumiyaji/net-mojo/pull/316) | 実装、レビュー、ローカル検証済み。公開済み、修正後の CI 待ち。 |
| [237](https://github.com/hirokazumiyaji/net-mojo/issues/237) | FileServer と metadata | [317](https://github.com/hirokazumiyaji/net-mojo/pull/317)–[320](https://github.com/hirokazumiyaji/net-mojo/pull/320) | 実装、レビュー、ローカル検証済み。公開済み、修正後の CI 待ち。 |
| [238](https://github.com/hirokazumiyaji/net-mojo/issues/238) | optional gzip | [321](https://github.com/hirokazumiyaji/net-mojo/pull/321)、[322](https://github.com/hirokazumiyaji/net-mojo/pull/322)、[323](https://github.com/hirokazumiyaji/net-mojo/pull/323)、[324](https://github.com/hirokazumiyaji/net-mojo/pull/324) | 実装、レビュー、ローカル検証済み。公開済み、最新 CI 待ち。 |
| [239](https://github.com/hirokazumiyaji/net-mojo/issues/239) | 受け入れ証拠の索引 | 本書 | 各受け入れ条件と確認済みの証拠を記録する。 |

FileServer と gzip の共通検証は [325](https://github.com/hirokazumiyaji/net-mojo/pull/325) に対応する。
各 PR 本文に、その変更の対象 head、検証内容と結果を記録する。

## ローカル検証の範囲

全機能候補 `fc971ed` は、2026年10月14日の macOS arm64 で通常49 task・930 tests、逐次 sanitizer36 task・865 tests が成功し、全範囲のコードレビューに指摘が残っていない。
候補 `a8222e9` に追加した CI 修正5ファイルのレビューも指摘なしであり、再構成候補 `c3b6e60` は lockfile を含む全 tracked file がそれと一致する。
全機能候補 `fc971ed` の全範囲レビューと、修正5ファイルのレビューをこの一致で対応付ける。

最終検証は119項目を対象とし、source と Darwin dependency が一致する116件の成功証拠を再利用し、HPACK ASan、offload 通常・ASanの3件を再検証した。
119件を最終 commit で新たに実行したという意味ではない。
元の記録は118成功と HPACK の期待値 assertion 1件の失敗であり、失敗を含む122回の実行記録を保持している。

CI で確認した6種の失敗は、Linux の glibc リンク、Go の postflight fixture、format、offload の mutex、offload の8-byte leak、HPACK の期待値である。
修正は ABI floor とテスト fixture に限定され、production Mojo/C の動作変更はない。
Linux の glibc/sysroot floor は2.34とし、各 slice の環境構成、他 package の version、macOS package 選択を維持した locked/frozen 検証が成功した。
Go は全 suite と race detector、offload は Linux arm64 の23 testsを通常・ASan各10回、macOS ASanで23 testsが成功した。
修正済み HPACK は macOS arm64 と Linux arm64 で通常・ASan各69 testsが成功した。
これらの修正検証は同日の修正候補に対する結果であり、GitHub Actions の成功と分けて扱う。

FileServer は HTTP/1・HTTP/2・HTTP/3 で各1 GiBを通常・ASanの計6回配信し、同じ SHA256 と buffer budget の解放を確認した。
WebSocket は WS/WSS、圧縮なしの Autobahn300 cases、既存 fuzz harness での再実行を確認した。
gzip は buffered/streaming と HTTP/1・HTTP/2・HTTP/3 の wire 検証を確認し、identity quality と ETag OWS のレビュー指摘も修正済みである。

公開済み74 PR（実装と検証基盤）の現在の head の CI は未確認であり、更新後の実行結果を待つ。
本書の PR はこの74件に含めない。
[通常 CI](../../.github/workflows/ci.yml) の workflow ごとに、公開 head に一致する最新 run と attempt を確認する。
旧 head の成功や cancelled run を完了証拠に使わず、checkout 基盤障害、ツールチェーン失敗、テスト失敗をログから区別する。

## 外部運転と管理権限で残る証拠

### 夜間 fuzz と週次 property tests

Issue227 は Linux x86_64 と aarch64 で各 target が30分走った夜間 run と適合性検証の証拠を要求する。
[夜間 parser replay](../../.github/workflows/fuzz-nightly.yml)、[QUIC receive](../../.github/workflows/fuzz-quic.yml)、[HTTP/2 conformance](../../.github/workflows/http2-conformance.yml) の run URL、head、platform、duration と artifact を記録する。
縮小、修正、通常回帰へ昇格した同じ fixture を実際の夜間 run でも再確認する条件は未確認である。
固定 marker による reducer unit test と短いローカル batch は、縮小ツールの検証として記録する。

Issue228 の [週次 property tests](../../.github/workflows/proptest-deep.yml) は5000 examplesと可変seedの実行記録が必要である。
ローカルでは9 program・5000 examples・2 seedsと縮小後の replay を確認したが、週次 run、CI の `Reproduce with:` と `Settings(replay=...)` の記録、branch protection/ruleset の required check 設定は未確認である。
property tests の対象 platform は macOS arm64 と Linux x86_64 である。

同日の scheduled run 一覧では実行記録を確認できていない。
schedule は default branch 上で有効になるため、定義の存在と実際の run を区別する。
確認には次の read-only command を使える。

```sh
gh run list --repo hirokazumiyaji/net-mojo --event schedule --limit 100 \
  --json databaseId,headSha,workflowName,status,conclusion,url
```

### 7日間の dogfood 稼働

Issue226 のサービスと HTTP/metrics smoke は確認済みである。
1 VMで再起動なしに7日以上稼働した記録は未確認であり、開始・終了時刻、対象 commit、VM の識別情報、再起動回数、uptime と metrics の期間を記録する。

### Prefix 配布と release 成果

ローカル conda build と [publish workflow](../../.github/workflows/publish.yml) は確認済みである。
Prefix channel の管理権限、`PREFIX_CHANNEL` と `PREFIX_API_KEY` の設定、3 platform の実際の upload、clean environmentでの `pixi add net -c <channel>` は未確認である。
secret の値は証拠に含めず、設定名と権限所有者、実行結果を記録する。

要求された機能と品質の確認後に、version、3 platform artifact/checksum、GitHub Release 本文・添付と Prefix install の結果を記録する。
実際の nightly/weekly run、7日稼働、管理者設定と配布の証拠がそろうまで、対応する受け入れ条件は未完了として残す。
