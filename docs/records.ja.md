# 記録

[English](records.md) | 日本語

Detchi は、1回の測定を JSON の1行として、機器ごと、日ごとのファイルに書きます。この文書では、ファイルと行の形と、その読み方を説明します。

## 目次

- [ファイル](#ファイル)
- [行](#行)
- [測定の行](#測定の行)
- [エラー](#エラー)
- [SNMP の値](#snmp-の値)
- [出来事の行](#出来事の行)
- [結果の意味](#結果の意味)
- [記録の読み方](#記録の読み方)

## ファイル

```
<data_dir>/<target>/<target>-YYYY-MM-DD.jsonl      今日の分
<data_dir>/<target>/<target>-YYYY-MM-DD.jsonl.gz   過ぎた日の分(zstd なら .jsonl.zst)
```

- 記録のファイルは、日次でローテーションします。機器ごとにディレクトリが1つ、日ごとにファイルが1つです。ファイル名にも機器の名前が入るので、1つだけダウンロードしても何のファイルか分かります。
- 日付は、環境変数 `TZ` による `ts` のローカルの日付です。行はいつも、その `ts` の日付のファイルに書きます。
- 0 時を過ぎた直後には、0 時の直前に送った要求の結果がまだ届くことがあります。前日のファイルは、その機器のいちばん長い `timeout` に 10 秒を足した間だけ開いておき、それから閉じて圧縮します。
- 圧縮したファイルには、元の `.jsonl` の更新時刻(つまり最後の行を書いた時刻)を写します。
- ファイルは、ファイル名の日付で、今日の前の `retention_days` 日分を残し、それより古いものを消します。設定から外した機器のファイルも対象です。Detchi は、起動のときと、その後 24 時間ごとに `data_dir` を走査します。
- Detchi が触るのは、上の形の名前のファイルだけです。`data_dir` に置いたほかのファイルには触りません。
- 切り替え、圧縮、削除は Detchi 自身が行います。logrotate は使わないでください。

量の目安:100 項目を 60 秒ごとに測り、1行を約 150 バイトとすると、1日に約 20MB、gzip でその 1/10 ほどです。

## 行

ファイルは [JSON Lines](https://jsonlines.org/) です。1行に JSON のオブジェクトが1つ入ります。行は2種類あります。

- **測定の行**(`protocol` がある):測定1回につき1行。失敗も含みます。タイムアウトも1行になるので、ロスとデータの欠けを区別できます。
- **出来事の行**(`event` がある):Detchi 自身に起きたこと(起動、停止など)。各機器のファイルに書きます。

```json
{"v":1,"ts":"2026-10-23T21:00:00.000000+09:00","target":"core1","event":"start","version":"0.1.0","config_hash":"sha256:0b3e44d9...","addr":"192.0.2.1"}
{"v":1,"ts":"2026-10-23T21:00:00.123456+09:00","target":"core1","probe":"ping","protocol":"icmp","addr":"192.0.2.1","status":"ok","rtt_us":1234}
{"v":1,"ts":"2026-10-23T21:01:00.123456+09:00","target":"core1","probe":"ping","protocol":"icmp","addr":"192.0.2.1","status":"timeout","timeout_ms":1000}
```

どの行にもある項目:

| キー | |
| --- | --- |
| `v` | スキーマの版。整数。いまは `1`。 |
| `ts` | 測定の行では、測定を始めた時刻(要求を送った時刻)。出来事の行では、出来事の時刻。 |
| `target` | 機器の名前。 |

- `ts` はローカル時刻の RFC 3339 で、マイクロ秒まで(いつも 6 桁)、オフセットは数字で書きます(いつも数字。`Z` ではなく `+00:00`)。
- キーの順序は決まっています。`v`、`ts`、`target`、次に `probe` か `event`、…と続き、プロトコルのオブジェクト(`udp`、`snmp`)が最後です。
- `v` が上がるのは、キーの意味や型を変えたとき、キーを消したときだけです。キーを足しても `v` は変わりません。記録を読む道具は、知らないキーを無視してください。
- 資格情報は、行に入りません。

## 測定の行

| キー | |
| --- | --- |
| `probe` | 測定の名前。 |
| `protocol` | `icmp`、`tcp`、`udp`、`snmp`。 |
| `addr` | 要求を送った IP アドレス。ホスト名を一度も引けていなければ書きません。IPv6 は RFC 5952 の形(英小文字、ゼロを省略)。 |
| `port` | ポート。TCP、UDP、SNMP。 |
| `status` | `ok`、`timeout`、`unreachable`、`refused`、`error`。 |
| `rtt_us` | 往復の時間。マイクロ秒。ネットワークから応答が返ったときだけ(下を参照)。 |
| `timeout_ms` | `timeout` のとき、待った時間。 |
| `error` | `unreachable`、`refused`、`error` のとき、その理由。[エラー](#エラー)を参照。 |
| `udp` | UDP だけ。`{"service": "dns"}` など、送った要求。 |
| `snmp` | SNMP だけ。`version`、`op`(`get`)、エージェントが誤りなく答えたときは `varbinds`。[SNMP の値](#snmp-の値)を参照。 |

`rtt_us` は、ネットワークから何か返ってきたときに書きます。応答、TCP の RST、ほかのホストからの ICMP の誤り、SNMP の `errorStatus` です。Detchi のホスト自身が作った誤り(自分のアドレスからの ICMP の誤り。ARP が引けなかったときなど)と、`errno` による `unreachable` には書きません。その時間は往復の時間ではないためです。

例:

```json
{"v":1,"ts":"2026-10-23T21:00:00.130000+09:00","target":"core1","probe":"dns","protocol":"udp","addr":"192.0.2.1","port":53,"status":"ok","rtt_us":2345,"udp":{"service":"dns"}}
{"v":1,"ts":"2026-10-23T21:00:00.135000+09:00","target":"core1","probe":"ssh","protocol":"tcp","addr":"192.0.2.1","port":22,"status":"refused","rtt_us":456,"error":{"reason":"errno","errno":"econnrefused"}}
{"v":1,"ts":"2026-10-23T21:00:00.137000+09:00","target":"core1","probe":"ntp","protocol":"udp","addr":"192.0.2.1","port":123,"status":"refused","rtt_us":95,"error":{"reason":"icmp","type":3,"code":3,"from":"192.0.2.1"},"udp":{"service":"ntp"}}
{"v":1,"ts":"2026-10-23T21:00:00.140000+09:00","target":"core1","probe":"sys","protocol":"snmp","addr":"192.0.2.1","port":161,"status":"timeout","timeout_ms":5000,"snmp":{"version":"v2c","op":"get"}}
{"v":1,"ts":"2026-10-23T21:00:00.865900+09:00","target":"nowhere","probe":"ping","protocol":"icmp","status":"error","error":{"reason":"resolve","errno":"nxdomain"}}
```

## エラー

`error` は、`reason` と、その `reason` ごとのキーを持つオブジェクトです。決まった語と数値だけが入り、自由な文は入りません。

| `reason` | 場面 | キー | `status` |
| --- | --- | --- | --- |
| `errno` | ICMP の詳しいことがない、ソケットの誤り(TCP の RST、手元に経路がない、など) | `errno` | `refused`、`unreachable` |
| `icmp` | ICMP、TCP、UDP の測定に ICMP の誤りが返った | `type`、`code`、`from` | `refused`(Port Unreachable)、`unreachable`(それ以外) |
| `snmp` | SNMP の応答の `errorStatus` が 0 でない | `error_status`、`error_index` | `error` |
| `snmp_report` | SNMPv3 の report PDU が返った(v3 用。v3 にはまだ対応していません) | `oid` | `error` |
| `resolve` | ホスト名を一度も引けていない | `errno` | `error` |
| `internal` | Detchi が想定していない失敗。詳しいことは Detchi のログにあります。 | | `error` |

```json
"error":{"reason":"errno","errno":"ehostunreach"}
"error":{"reason":"icmp","type":11,"code":0,"from":"192.0.2.254"}
"error":{"reason":"snmp","error_status":"genErr","error_index":2}
"error":{"reason":"resolve","errno":"nxdomain"}
"error":{"reason":"internal"}
```

- `errno` は、Erlang が付けた誤りの名前です(`econnrefused`、`ehostunreach`、`enetunreach`、`nxdomain` など)。
- `icmp` の `type` と `code` は、ICMP のメッセージの番号です。ICMPv4 と ICMPv6 で番号の振り方が違う(Time Exceeded は ICMPv4 で 11、ICMPv6 で 3)ので、`addr` で読み分けてください。Port Unreachable は、ICMPv4 で type 3 code 3、ICMPv6 で type 1 code 4 です。
- `icmp` の `from` は、ICMP の誤りを返してきたアドレスです。宛先、途中のルーター、ファイアウォール、Detchi のホスト自身のどれもありえます。
- `snmp` の `error_status` は RFC 3416 の名前(`tooBig`、`genErr` など)です。`error_index` は 1 から数え、設定の `oids` の順を指します。0 はどの varbind も指しません。この行には `varbinds` がありません。

## SNMP の値

`varbinds` はリストで、設定の `oids` の順に並びます。

```json
"snmp":{"version":"v2c","op":"get","varbinds":[
  {"oid":"1.3.6.1.2.1.1.3.0","type":"TimeTicks","value":123456},
  {"oid":"1.3.6.1.2.1.31.1.1.1.1.1","type":"OctetString","value":"Gi0/1"},
  {"oid":"1.3.6.1.2.1.2.2.1.6.1","type":"OctetString","hex":"001122aabbcc"},
  {"oid":"1.3.6.1.2.1.31.1.1.1.6.1","type":"Counter64","value":18446744073709551615},
  {"oid":"1.3.6.1.2.1.31.1.1.1.6.99","type":"noSuchInstance"}]}
```

(読みやすいように改行してありますが、ファイルの中では1行です。)

| `type` | 値 |
| --- | --- |
| `Integer`、`Counter32`、`Gauge32`、`TimeTicks`、`Counter64` | `value`:数値。`Integer` は負の数もあります。 |
| `OctetString` | 正しい UTF-8 で、タブ、LF、CR のほかに制御文字がなければ、`value` に文字列で。そうでなければ `hex`。 |
| `ObjectIdentifier` | `value`:点で区切った文字列。 |
| `IpAddress` | `value`:点で区切った文字列。4 バイトでなければ `hex`。 |
| `Opaque` | いつも `hex`。 |
| `Null` | 値はありません。 |
| `noSuchObject`、`noSuchInstance`、`endOfMibView` | 値はありません。行の `status` は `ok` のままです。 |

- `hex` は英小文字の16進で、区切りを入れません。文字列かバイト列かは、キーの名前(`value` か `hex`)で分かります。MAC アドレスや、末尾に NUL の付いた文字列は `hex` になります。
- 値は生のままです。カウンターを速度に直すことも、一周やエージェントの再起動の扱いもしません。再起動を見つけるには、同じ測定に `sysUpTime.0` を入れてください([設定](configuration.ja.md#snmp-1)を参照)。
- `Counter64` は、文字列ではなく JSON の数値で書きます。jq 1.7 以上は、大きな数値をそのまま通すときと比べるときは正確に扱いますが、計算には double を使うので、正確なのは 2^53 までです。バイトのカウンターが 2^53 に届くのは、100Gbps で約 8 日、10Gbps で約 83 日、1Gbps で約 2.3 年です。差分の誤差は 2^64 の近くでも最大 2048 で、速度の計算にはまず効きません。正確な値が要るとき(等しいかの判定、一周の判定)は、Python のような任意精度の整数を持つ言語で扱ってください。

## 出来事の行

| `event` | キー | いつ書くか |
| --- | --- | --- |
| `start` | `version`、`config_hash`、`addr` | Detchi が起動したとき。 |
| `file_opened` | `version`、`config_hash`、`addr` | 日付が替わって新しいファイルを開いたとき(起動のときは `start` を書くので、書きません)。 |
| `stop` | `abandoned` | SIGTERM か SIGHUP で止まるとき。`abandoned` は、結果を待たずに打ち切った要求の数。 |
| `dropped` | `count`、`first_ts`、`last_ts` | 行を書けなかった(ディスクが一杯など)のが、書けるようになったとき。`ts` が `first_ts` から `last_ts` までの `count` 行が欠けています。 |
| `resolve_failed` | `host`、`error`、`addr` | ホスト名を引けなかったとき。`addr` は使い続けているアドレスで、一度も引けていなければ書きません。 |
| `addr_changed` | `host`、`old`、`new` | ホスト名のアドレスが変わったとき。初めて引けたときは `old` を書きません。 |
| `clock_stepped` | `offset_us` | 壁時計(wall clock。Linux の `CLOCK_REALTIME`)が 1 秒以上跳んだとき。正なら進み、負なら戻り。たとえば、Detchi の起動の後で chrony が時刻を合わせたとき。 |

```json
{"v":1,"ts":"2026-10-23T21:00:00.325614+09:00","target":"nowhere","event":"start","version":"0.1.0","config_hash":"sha256:8d11395f..."}
{"v":1,"ts":"2026-10-23T21:00:00.326895+09:00","target":"nowhere","event":"resolve_failed","host":"no-such-host.example","error":{"reason":"resolve","errno":"nxdomain"}}
{"v":1,"ts":"2026-10-23T21:05:00.000000+09:00","target":"core1","event":"addr_changed","host":"core1.example","old":"192.0.2.1","new":"192.0.2.9"}
{"v":1,"ts":"2026-10-23T22:00:03.926169+09:00","target":"core1","event":"stop","abandoned":1}
```

- `version` は Detchi の版です。`config_hash` は、その機器の設定のフィンガープリントです([設定](configuration.ja.md#設定を変えるとき)を参照)。
- どのファイルも `start` か `file_opened` で始まるので、どの版の Detchi が、どの設定で書いたかが、ファイル1つだけで分かります。
- 記録の空白の読み方:
  - `stop` の後に `start`:その間、Detchi は止まっていた(再起動した)。
  - 前に `stop` のない `start`:Detchi が落ちたか、ホストの電源が切れた。その間、Detchi は動いていなかった。
  - `dropped`:Detchi は動いていたが、書けなかった。
  - 設定から外した機器は、最後の行が `stop` になります。
- `resolve_failed` は、引けなかったたびに書きます。`resolve_interval` が既定の `5m` なら、DNS が1日止まると 288 行になります。

## 結果の意味

### ICMP

- Echo Reply が返れば `ok`。
- ルーターや宛先が ICMP の誤りを返せば、`icmp` のエラーで `unreachable` か `refused`。
- 同じネットワークの中で ARP が引けないときは、約 3 秒後にカーネル自身が Host Unreachable を作り、`from` は Detchi のホストになります。`timeout` が既定の 1 秒なら、先に `timeout` の行になります。

### TCP

- 接続が確立すれば(SYN-ACK が返れば)`ok`。`rtt_us` は接続するまでの時間です。
- RST が返れば、`errno` が `econnrefused` で `refused`。RST には `from` がないので、宛先とファイアウォールのどちらが返したかは分かりません。
- 途中の機器が宛先の代わりに答えることがあります。SYN プロキシやロードバランサーが SYN-ACK を、ファイアウォールが RST を返すことがあります。
- `timeout` が 1 秒を超えると、カーネルが送り直した SYN が `rtt_us` に入ることがあります。1 秒(や 3 秒、7 秒…)を少し超えた `rtt_us` は、たぶんそれです。

### UDP

- 宛先から UDP の応答が何か返れば `ok`。中身は確かめないので、DNS の NXDOMAIN や NTP の Kiss-o'-Death も `ok` です。
- Port Unreachable が返れば、`icmp` のエラーで `refused`。ファイアウォール(iptables の `REJECT` など)が返すこともあります。誰が返したかは `from` で分かります。
- `rtt_us` には、サーバーが答えるまでの時間が入ります。

### SNMP

- `status` は `ok`、`timeout`、`error` だけです。
- エージェントがいない、ポートが閉じている、community が誤っている、のどれも `timeout` になります。SNMP では ICMP の誤りが見えないためです。
- エージェントが受け付けられるより大きい要求は、エージェントが捨てるので、`tooBig` ではなく `timeout` になります。
- 再送しないので、`timeout` の1行が、失われた要求1つです。
- `rtt_us` には、Erlang の SNMP のマネージャーの中の時間が入ります(ループバックで約 0.3〜1.1ms。ICMP は 0.15ms)。

### どのプロトコルでも

- 行は、`ts` の順ではなく、結果が届いた順に書きます。タイムアウトの行は、後に送った要求の結果より後になります。
- `ts` は壁時計から、`rtt_us` は単調な時計(monotonic clock。Linux の `CLOCK_MONOTONIC`)から取ります。壁時計が跳ぶと(`clock_stepped` を参照)`ts` はずれますが、`rtt_us` はずれません。
- Detchi のホストが重いとき(負荷のかかった Raspberry Pi など)は、Detchi が応答を扱うまでの遅れが `rtt_us` に入ります。

## 記録の読み方

例では [jq](https://jqlang.org/) 1.7 を使います。圧縮したファイルは `zcat`(か `zstdcat`)で読めます。

測定の行だけ:

```sh
jq -c 'select(.protocol)' core1-2026-10-23.jsonl
```

出来事の行だけ:

```sh
jq -c 'select(.event)' core1-2026-10-23.jsonl
```

1つの測定の RTT をミリ秒で、CSV に:

```sh
jq -r 'select(.probe == "ping" and .status == "ok") | [.ts, .rtt_us / 1000] | @csv' core1-2026-10-23.jsonl
```

1つの測定の `status` ごとの行の数を、圧縮した1か月分のファイルから:

```sh
zcat core1/core1-2026-10-*.jsonl.gz | jq -s 'map(select(.probe == "ping")) | group_by(.status) | map({status: .[0].status, n: length})'
```

`ts` の順に並べる:

```sh
jq -sc 'sort_by(.ts)[]' core1-2026-10-23.jsonl
```

`ts` を文字列のまま並べて正しいのは、オフセットが変わらない間だけです。夏時間の切り替えをまたぐときは、先に時刻を変換してください。
