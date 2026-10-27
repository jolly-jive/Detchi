# 設定

[English](configuration.md) | 日本語

Detchi は YAML のファイルを1つ読みます。場所は `$DETCHI_CONFIG`、設定されていなければ `/etc/detchi/detchi.yml` です。

## 目次

- [例](#例)
- [設定の検査](#設定の検査)
- [トップレベル](#トップレベル)
- [defaults](#defaults)
- [credentials](#credentials)
- [targets](#targets)
- [probes](#probes)
- [名前](#名前)
- [時間](#時間)
- [アンカーによる測定の使い回し](#アンカーによる測定の使い回し)
- [設定を変えるとき](#設定を変えるとき)
- [資格情報の扱い](#資格情報の扱い)

## 例

```yaml
data_dir: /var/lib/detchi
retention_days: 1827
compression: gzip            # gzip | zstd
resolve_interval: 5m

defaults:                    # 測定で省略したときの値
  interval: 60s
  timeout: 1s                # ICMP、TCP、UDP
  snmp_timeout: 5s           # SNMP

credentials:
  campus-v2c: { version: v2c, community: "..." }

targets:
  - name: core1
    host: 192.0.2.1          # IP アドレスかホスト名
    family: auto             # auto | ipv4 | ipv6
    snmp:
      credential: campus-v2c
      port: 161
    probes:
      - name: ping
        protocol: icmp
      - name: ssh
        protocol: tcp
        port: 22
      - name: dns
        protocol: udp
        service: dns         # dns | ntp | quic
      - name: if-uplink
        protocol: snmp
        interval: 300s
        oids:                # 1回の要求で取る
          - "1.3.6.1.2.1.1.3.0"           # sysUpTime.0
          - "1.3.6.1.2.1.31.1.1.1.6.1"    # ifHCInOctets.1
          - "1.3.6.1.2.1.31.1.1.1.10.1"   # ifHCOutOctets.1
```

## 設定の検査

設定ファイルは厳しく検査します。次のときは起動しません。

- 知らないキーがある(綴りの誤りで測定が黙って抜け、何年も気づかれない、ということを防ぐため)。
- 同じマッピングに同じキーが2つある。
- ファイルに YAML の文書が2つ以上ある。
- 値の型が誤っている(`1.3` と書いた OID は文字列でなく数値になる。単位のない時間、など)。
- 必須のキーがない。空にできないリストが空。

誤りは最初の1つで止めず、ファイルの中のすべてを `<ファイル>:<行>:<桁>: error: <位置>: <エラーメッセージ>` の形で出します。

```
$ detchi check-config
/etc/detchi/detchi.yml:7:19: error: targets[0].probes[0].interval: must be a positive duration with a unit (ms, s, m, h), such as "60s"
/etc/detchi/detchi.yml:8:9: error: targets[0].probes[1]: missing key "port"
/etc/detchi/detchi.yml:10:9: error: targets[0].probes[1]: unknown key
/etc/detchi/detchi.yml: 3 errors
```

エラーメッセージには、ファイルの文字列を一切引きません。知らないキーの名前も出しません。置き間違えた資格情報がキーの名前に入ることがあるためです(`:` の後の空白を落とした `community:secret` は、1つのキーになります)。何が誤りかは、行と桁の場所を見てください。

`detchi check-config` が読むのは設定ファイルだけです。ホスト名は引かず、`data_dir` があるか、書けるかも見ません。

| 結果 | 出力 | 終了コード |
| --- | --- | --- |
| 誤りがない | 警告と `<ファイル>: ok (N targets, M probes)` を標準出力に | 0 |
| 誤りがある | 誤りと `<ファイル>: N errors` を標準エラー出力に | 1 |
| 使い方の誤り | 使い方を標準エラー出力に | 2 |

警告では止まりません。`detchi run` も、起動のときに同じ警告をログに出します。

`detchi check-config --fingerprints` は、機器ごとに設定のフィンガープリントと、フィンガープリントのもとになる正規化した JSON も出します([設定を変えるとき](#設定を変えるとき)を参照)。

## トップレベル

| キー | 既定 | |
| --- | --- | --- |
| `data_dir` | `/var/lib/detchi` | 記録の置き場所。絶対パス。 |
| `retention_days` | `1827`(5 年) | 今日の前の何日分を残すか。正の整数。`1` なら今日と昨日が残ります。 |
| `compression` | `gzip` | 過ぎた日のファイルの圧縮の方式。`gzip` か `zstd`。 |
| `resolve_interval` | `5m` | ホスト名を引き直す間隔。[時間](#時間)の形。 |
| `defaults` | | [defaults](#defaults) を参照。 |
| `credentials` | | [credentials](#credentials) を参照。 |
| `targets` | (必須) | 測る機器。空にはできません。 |

トップレベルでは、`x-` で始まるキーを無視します。YAML のアンカーを置くためです([アンカーによる測定の使い回し](#アンカーによる測定の使い回し)を参照)。

`gzip` のファイルは、たいていの環境で `zcat` や `zgrep` で読めます。`zstd` のファイルを読むには、読む側に `zstd` コマンド(`zstdcat`、`zstdgrep`)が要ります。`compression` を変えても、圧縮済みのファイルは圧縮し直しません。`retention_days` を過ぎるまで残ります。

## defaults

測定で省略したときの値です。

| キー | 既定 | 適用する測定 |
| --- | --- | --- |
| `interval` | `60s` | すべて |
| `timeout` | `1s` | ICMP、TCP、UDP |
| `snmp_timeout` | `5s` | SNMP |

`timeout` は SNMP には適用しません。1か所で `timeout` を書いて、SNMP まで黙って短くなることを防ぐためです。測定に書いた `timeout` は、どのプロトコルでもそれが勝ちます。

## credentials

名前を付けた SNMP の資格情報です。機器の `snmp.credential` から名前で参照します。

```yaml
credentials:
  campus-v2c: { version: v2c, community: "..." }
```

| キー | |
| --- | --- |
| `version` | `v2c`。`v3` にはまだ対応しておらず、誤りになります。 |
| `community` | community の文字列。空でない文字列。 |

名前は[名前の規則](#名前)に従います。

## targets

1つの機器が1つの target で、記録のディレクトリも機器ごとに分かれます。

| キー | 既定 | |
| --- | --- | --- |
| `name` | (必須) | 機器の名前。記録とファイル名に使います。[名前の規則](#名前)に従い、機器の間で重ならないこと。 |
| `host` | (必須) | IP アドレスかホスト名。 |
| `family` | `auto` | `auto`、`ipv4`、`ipv6`。 |
| `snmp` | | 機器の SNMP の設定。SNMP の測定がある機器では必須。 |
| `probes` | (必須) | 測るもの。空にはできません。 |

`name` を `host` で代用しないのは、アドレスが変わっても記録の名前が変わらないようにするためです。

### host と family

- IP アドレスを書いたときは、`family` と合うこと(`family: ipv6` に IPv4 のアドレスは誤り)。ゾーンを付けた IPv6 のアドレス(`fe80::1%eth0`)は受け付けません。
- ホスト名を書いたとき、`family: auto` は A を引き、A がないときだけ AAAA を引きます。`ipv4` と `ipv6` は、A だけ、AAAA だけを引きます。
  - A をほかの理由(タイムアウトなど)で引けなかったときは、AAAA に行きません。DNS が一時詰まっただけで、機器が IPv6 に移らないようにするためです。
- ホスト名は `resolve_interval` ごとに引き直します。引き直しに失敗したら、前のアドレスで測り続けます。失敗とアドレスの変化は記録に書きます。
  - 名前に複数のアドレスがあるときは、今使っているアドレスが答えに残っている限り、それを使い続けます。
  - 起動のときに引けなかったホスト名があっても、起動は止めません。10 秒、20 秒、40 秒…と、`resolve_interval` まで間隔を延ばしながら引き直します。
- 名前はホストの普通の方法(`/etc/hosts` と DNS)で引きます。TTL には従いません。

### snmp

| キー | 既定 | |
| --- | --- | --- |
| `credential` | (必須) | `credentials` の名前。 |
| `port` | `161` | エージェントの UDP のポート。 |

資格情報は、測定ごとではなく機器ごとに指定します。SNMP の測定がない機器に `snmp` を書いてもかまいません。

## probes

どの測定にもあるキー:

| キー | 既定 | |
| --- | --- | --- |
| `name` | (必須) | [名前の規則](#名前)に従い、機器の中で重ならないこと。 |
| `protocol` | (必須) | `icmp`、`tcp`、`udp`、`snmp`。 |
| `interval` | `defaults.interval` | 測る間隔。 |
| `timeout` | `defaults.timeout`(SNMP は `defaults.snmp_timeout`) | 応答を待つ時間。`interval` より短いこと。 |

ほかのプロトコルのキー(ICMP の測定の `port` など)は、知らないキーになります。

測る時刻は、機器と測定の名前から決まる位相で、間隔の中に散らばります。すべての測定が同時に始まらないようにするためです。位相は再起動しても変わりません。起動してから最初に測るまで、最大でその測定の `interval` かかります。

### icmp

ICMP Echo(ping)です。ほかのキーはありません。

Detchi は権限の要らない ICMP のソケットを使うので、`net.ipv4.ping_group_range` が、動かすユーザーのグループを含む必要があります。Docker の既定の値で動きます。`detchi run` は起動のときにこれを確かめ、要るソケットを開けなければ起動しません。

### tcp

TCP コネクションを確立するまでの時間です。接続したらすぐに閉じ、何も送りません。

| キー | |
| --- | --- |
| `port` | (必須)ポート。1 から 65535。 |

- 接続するたびにログを書くサービスがあります。たとえば sshd は `Connection closed by ... [preauth]` のような行を書き、`60s` なら1日に 1440 行になります。fail2ban のような仕組みや、機器のログインの失敗の数え方に引っかかることもあります。
- `timeout` を長くすると(Linux の最初の SYN の再送までの 1 秒を超えると)、RTT に SYN の再送が入ることがあります。

### udp

サーバーが確実に答える要求を1つ送ります。機器から UDP の応答が何か返れば成功で、中身は確かめません。

| キー | 既定 | |
| --- | --- | --- |
| `service` | (必須) | `dns`、`ntp`、`quic`。 |
| `port` | `53` / `123` / `443` | ポート。既定は `service` から決まります。 |

| `service` | 送る要求 |
| --- | --- |
| `dns` | `. SOA` の問い合わせ。再帰なし(RD=0)、EDNS なし。 |
| `ntp` | NTPv4 のクライアントの要求(mode 3)。 |
| `quic` | 予約された版の Initial。サーバーは Version Negotiation を返します。 |

`service: ntp` で `interval` が 8 秒より短いと、警告が出ます。公開の NTP サーバーは、短い間隔の問い合わせを不正なアクセスと判断し、制限したり捨てたりします。自分で運用していないサーバーに、短い間隔で問い合わせないでください。

### snmp

SNMP の get を1回行います。1回の要求で、すべての OID を1つの PDU の varbind に入れます。

| キー | |
| --- | --- |
| `oids` | (必須)OID を数値の文字列で(`"1.3.6.1.2.1.1.3.0"`)。空にはできません。MIB の名前は受け付けません。 |

- 機器に `snmp` が要ります。
- 再送しません。ロスが記録に表れるようにするためです。
- 値は生のまま記録します。カウンターを速度に直すことはしません。
- `sysUpTime.0`(`1.3.6.1.2.1.1.3.0`)を、カウンターと同じ要求に入れることを勧めます。エージェントの再起動が分かり、2つの値の間の正確な時間が出せます。約 497 日で一周します。
- 64 ビットのカウンター(`ifHCInOctets` など)を勧めます。32 ビットの `ifInOctets` は、1Gbps で約 34 秒で一周します。
- エージェントが受け付けられるより大きい要求は、エージェントが応答せずに捨てるので、`tooBig` ではなく `timeout` として記録されます。OID の多い測定がいつも `timeout` になるなら、分けてください。
- エージェントがいない、ポートが閉じている、community が誤っている、のどれも同じく `timeout` になります。

## 名前

機器、測定、資格情報の名前は `^[a-z0-9][a-z0-9._-]{0,62}$` に合うこと。

- 英小文字、数字、`.`、`_`、`-` で、1 から 63 文字。
- 先頭は `.`、`_`、`-` 以外。

機器の名前は、ディレクトリとファイルの名前に使います。英小文字だけにしているのは、記録を Windows や macOS にダウンロードしたとき、大文字と小文字だけが違う名前がぶつからないようにするためです。IPv4 アドレスやホスト名は名前にできますが、IPv6 アドレスはできません(`:` は Windows のファイル名に使えません)。

## 時間

正の整数に単位を付けて書きます。単位は `ms`、`s`、`m`、`h`(`500ms`、`60s`、`5m`、`1h`)。単位のない数値は誤りです。ミリ秒と秒の取り違えを防ぐためです。`60s` と `1m` は同じです。

## アンカーによる測定の使い回し

Detchi 自身にはひな形の仕組みはありません。YAML のアンカー(`&名前` で名前を付け、`*名前` で参照する)を使い、アンカーは `x-` で始まるトップレベルのキーに置きます。

```yaml
x-switch-probes: &switch
  - { name: ping, protocol: icmp }
  - { name: ssh,  protocol: tcp, port: 22 }

targets:
  - { name: sw1, host: 192.0.2.11, probes: *switch }
  - { name: sw2, host: 192.0.2.12, probes: *switch }
```

- アンカーを付けるリストやマッピングは、上の例のように block の形で書いてください(`&switch` の次の行から要素を書く)。Detchi の YAML のパーサーは、flow の形の集まり(`&switch [...]`、`&switch {...}`)に付けたアンカーを、集まりでなく最初の要素に付けてしまうので、Detchi は誤りにします。flow の集まりの中の要素に付けたアンカー(`[&a 1]`)は問題ありません。
- マージキー(`<<: *名前`)には対応していません。`<<` は知らないキーになります。
- アンカーを付けたものの中の誤りは、使った回数だけ、アンカーの位置で出ます。

## 設定を変えるとき

設定を変えたら、Detchi を再起動してください(プロセスかコンテナを起動し直す)。Detchi はファイルを読み直しません。SIGHUP でも読み直しません。再起動の前に `detchi check-config` を動かしてください。ファイルに誤りがあると Detchi は起動せず、`restart: unless-stopped` のコンテナでは、何も測らないまま起動し直しを繰り返します。

再起動の間の空白は、記録の `stop` と `start` の行で分かります。`start` の行には、その機器の設定のフィンガープリント(`config_hash`)が入るので、設定がいつ変わったかを記録から追えます。

- フィンガープリントの範囲は、その機器の定義だけです。省略した値は既定値で埋めます。含むのは `name`、`host`、`family`、`snmp`(`port` と、資格情報の `version`)、`probes`。資格情報、資格情報の名前、引いたアドレス、トップレベルのキーは含みません。
- 測定を並べ替えても、`60s` を `1m` と書き換えても変わりません。`oids` の並べ替えでは変わります。
- Detchi の版が上がって既定値やキーが変わると、設定を変えなくてもフィンガープリントが変わることがあります。どちらで変わったかは、`start` の行の `version` で分かります。
- 何が変わったかは、2つの設定の `detchi check-config --fingerprints` の出力を比べてください。どの行も機器の名前で始まるので、`diff` や `grep` が使えます。

## 資格情報の扱い

設定ファイルには、SNMP の community が平文で入ります。

- Detchi は、それを記録、エラーメッセージ、ログのどこにも出しません。
- 設定ファイルを人に見せると、資格情報も見せることになります。機器の定義を人に見せるときは、`detchi check-config --fingerprints` の出力を使ってください。資格情報は入りません。
- 設定ファイルは、Detchi を動かすユーザーだけが読めるようにしてください。
