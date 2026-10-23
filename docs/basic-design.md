# Detchi 基本設計書

## 1. 目的

ネットワークのメトリックスを**収集して記録するだけ**のサービス。Linux の上で常に動き続け、ネットワーク機器の RTT と SNMP の値を測って、そのまま記録に残す。

Koitohan(Raspberry Pi で動く、ネットワーク機器向けの小さな管理サーバ)に組み込むことを想定して作るが、Koitohan には依存しない汎用のものにする(9 節)。

### 1.1 名称

「でっち(丁稚)」。Koitohan は大阪の商家の末娘(「小いとはん」)から取った名前で、同じ商家の住人として「Koitohan と Detchi」と並べる。

丁稚奉公は厳しいものだったが、商人としての修行の場でもあり、手代、番頭、暖簾分けというキャリアパスもあった。厳しい面だけを見るのではなく、そちらの意味を込めている。いまは RTT と SNMP を書き留めるだけの丁稚だが、gNMI や NETCONF を覚えて育っていく余地がある。

綴りはヘボン式の `Detchi`。英語の `tch` はいつも /tʃ/ と読まれるので、英語話者にも「デッチ」と読める。訓令式の `Decchi` は一度選んだが、英語では `cc` が /ks/ や「デッキ」と読まれうるので改めた。README には「でっち(丁稚)」と添える。Hex.pm に同名のパッケージはない(2026-10-22 時点)。

名前の候補として、ほかに Daifukucho(大福帳。お金の印象が強いので見送り)、Tomegaki(留書)、Goyokiki(御用聞き。機器から送ってくる方式を足すと合わなくなる)、NexRecorder などを検討した。

### 1.2 NexPinger との関係

[NexPinger](https://github.com/jolly-jive/nexpinger)(同じ作者の Elixir 製 CUI。ICMP / TCP / UDP で多数のホストを監視する)を参考にする。ただし用途が違う。

- NexPinger:一時的なトラブルシューティングのための道具。宛先はその場で決まる。
- Detchi:常に測り続けて記録を残すもの。

NexPinger とは**コードを共有しない**(ライブラリ化も、Hex.pm への登録もしない)。

- NexPinger は Windows に対応する必要があるが、Detchi は Linux だけでよい。
- 必要な部分は写して、Linux だけを前提に素直に書く。

## 2. 範囲

- 測るもの
  - ICMP / TCP / UDP の RTT
  - SNMP の値
  - gNMI と NETCONF は今後の検討項目。
- 機能は**収集、記録、圧縮、データのダウンロード**だけ。
- 警告、整形、統計処理、可視化、チャートはサポートしない。必要なら、データをダウンロードして、Detchi とは別の仕組みで行ってもらう。

## 3. 実装

- Elixir/OTP で書く。対象は Linux だけ。
- 要求する OTP は **28 以上**(zstd のため。6.3 節)。
- SNMP は OTP 標準の `snmp` アプリケーション(マネージャーの `snmpm`)を使う見込み。v1、v2c、v3 に対応しており、外部の依存が要らない。API に癖があるので、最初に小さく試す価値がある。

## 4. 測り方(RTT)

- UDP は NexPinger に準じる。つまり、**確実に応答が期待できる UDP ポートだけ**を対象にする(NexPinger は DNS、NTP、QUIC の要求を送り、何か返ってくるかで測っている)。
- コードは共有しないので、定義は仕様として本書に書き、「NexPinger の vX.Y.Z の動作に合わせた」と明記する。揃える定義は次の3つ。
  - 送る要求の中身
  - 成功の条件
  - RTT の起点と終点
- ICMP は、権限の要らない ICMP のソケット(datagram socket)を使う。Docker の既定の `net.ipv4.ping_group_range` で動く。

## 5. SNMP

- 値は**生の数値の OID**で記録する。MIB の名前は使わない(MIB ファイルの管理を抱えないため)。
- カウンターは生の値で残す。差分や bps への換算は、使う側に任せる。
- `sysUpTime.0` は Detchi が自動では足さない。サンプルの設定と文書で、任意の項目として勧める。
  - 役割は、機器の再起動(エージェントの再初期化)の検出と、正確な間隔の算出。
  - `sysUpTime.0` は、カウンターと**同じ要求**(1つの PDU の複数の varbind)に入れる。往復は1回で済む。GetBulk では `non-repeaters` に置ける。1つの要求に入りきらずに分けるときは、分けた要求ごとに入れる。
  - そのため、設定の単位は「1回の要求で取る OID の組」にしておくのが自然。
  - 注意:`sysUpTime` は TimeTicks(1/100 秒単位、32 ビット)なので、約 497 日で一周する。
- 64 ビットのカウンター(`ifHC*`)を勧めることを文書に書く。32 ビットの `ifInOctets` は 1Gbps だと 30 秒あまりで一周する。
  - 参考:NMS 製品の扱いは大きく3通り。
    - 減ったらリセットとみなす(Prometheus の `rate()`、Zabbix)。
    - 一周とみなし、上限ではじく(RRDtool の COUNTER)。
    - sysUpTime で再起動を見る(Cacti)。
  - 標準の仕組みとして、RFC 2863 の `ifCounterDiscontinuityTime` もある。
- 版は v2c と v3 の両方に対応する。v3 は後回しでもよい。
  - v3 の注意:`snmpm` の USM は、パスフレーズではなく、機器の engine ID で局所化した鍵を受け取る。パスフレーズを書いてもらい、engine ID を取得してから鍵に変換することになる。

## 6. 記録

### 6.1 形式

- 形式は **JSON Lines**。
- 1回の測定を1行で、そのまま書く(集約しない。RRD のように丸める形式は「統計処理」にあたるので使わない)。
- **失敗も1行として残す**(タイムアウトなど)。残さないと、ロスとデータの欠落が区別できない。
- 時刻は **RFC 3339(タイムゾーンのオフセット付き)**。
  - 行に付ける時刻は**要求を送った時刻**に揃える(RTT と SNMP で同じ意味にするため)。
  - マイクロ秒まで書く(同じ機器への測定が同じ秒に重なっても、順序が分かるように)。

#### スキーマ(たたき台)

行は、測定の行と、Detchi 自身の出来事の行の2種類。測定の行には `protocol` があり、出来事の行には `event` がある。どちらがあるかで見分ける。

例(SNMP の行は読みやすいように改行してあるが、実際は1行):

```json
{"v":1,"ts":"2026-10-23T21:00:00.123456+09:00","target":"core1","probe":"ping","protocol":"icmp","addr":"192.0.2.1","status":"ok","rtt_us":1234}
{"v":1,"ts":"2026-10-23T21:01:00.120001+09:00","target":"core1","probe":"ping","protocol":"icmp","addr":"192.0.2.1","status":"timeout","timeout_ms":1000}
{"v":1,"ts":"2026-10-23T21:00:00.130000+09:00","target":"core1","probe":"dns","protocol":"udp","addr":"192.0.2.1","port":53,"status":"ok","rtt_us":2345}
{"v":1,"ts":"2026-10-23T21:00:00.140000+09:00","target":"core1","probe":"if-uplink","protocol":"snmp","addr":"192.0.2.1","status":"ok","rtt_us":5678,
 "snmp":{"version":"v2c","op":"get","varbinds":[
   {"oid":"1.3.6.1.2.1.1.3.0","type":"TimeTicks","value":123456},
   {"oid":"1.3.6.1.2.1.31.1.1.1.1.1","type":"OctetString","value":"Gi0/1"},
   {"oid":"1.3.6.1.2.1.31.1.1.1.6.1","type":"Counter64","value":18446744073709551615}]}}
{"v":1,"ts":"2026-10-23T21:00:00.000000+09:00","target":"core1","event":"start"}
```

共通の項目:

| 項目 | 内容 |
| --- | --- |
| `v` | スキーマの版(整数)。 |
| `ts` | 測定の行では要求を送った時刻。出来事の行では出来事の時刻。 |
| `target` | 機器の名前(設定で付ける名前。形は未決)。 |

測定の行の項目:

| 項目 | 内容 |
| --- | --- |
| `probe` | 設定に付けた測定の名前。 |
| `protocol` | `icmp`、`tcp`、`udp`、`snmp`。将来は `gnmi`、`netconf` も入る。 |
| `addr` | 実際に送った宛先の IP アドレス(名前ではない。DNS の答えが変わっても、何を測ったかが分かるように)。 |
| `port` | TCP、UDP の宛先のポート。 |
| `status` | `ok`、`timeout`、`unreachable`、`refused`、`error` のどれか。 |
| `error` | `status` が `ok` でないときの理由(SNMP の `errorStatus` と `errorIndex`、ICMP の Destination Unreachable の種類など。形は未決)。 |
| `rtt_us` | 要求を送ってから応答を受けるまでの時間。マイクロ秒の整数。SNMP の行にも付ける。 |
| `timeout_ms` | `status` が `timeout` のときの、待った時間。 |

- プロトコルに固有の項目は、プロトコルの名前の下に入れ子にする(例の `"snmp":{...}`)。将来 gNMI や NETCONF の項目が増えても、共通の項目とぶつからない。ただし `port` のように RTT で共通に使うものは、入れ子にしない。
- SNMP の値(`varbinds`)
  - OID をキーにしたオブジェクトではなく、配列にする。要求した順序が残り、GetBulk や walk で同じ形を使える。
  - `type` には SNMP の型(`Integer`、`OctetString`、`ObjectIdentifier`、`IpAddress`、`Counter32`、`Gauge32`、`TimeTicks`、`Opaque`、`Counter64`)を書く。`noSuchObject`、`noSuchInstance`、`endOfMibView` の例外もここに書き、`value` は書かない。例外があっても、要求全体の `status` は `ok` のまま。
  - OctetString は、UTF-8 として読めて印字できるものは `value` に文字列で書く。そうでないもの(MAC アドレスなど)は `hex` に16進で書く。どちらで書いたかは項目の名前で分かる。
  - **Counter64 も数値で書く**(文字列にしない)。
    - jq 1.7 以上は数値を書かれたとおりに保つので、そのまま出力する(`select` で絞る、など)ときと、比べるときは正確。文字列にしても、jq で計算するには `tonumber` が要り、精度は同じように落ちるので、利点がない。
    - 計算すると double(IEEE 754)になり、2^53 を超えた部分の精度は落ちる。jq 1.7 で確かめた例:`18446744073709551615 - 1` は `18446744073709552000`、`9007199254740993 - 9007199254740992` は `0`。
    - バイトのカウンターが 2^53 に届くのは、100Gbps で流し続けて約 8 日、10Gbps で約 83 日、1Gbps で約 2.3 年。ただし差分の誤差は、2^64 の近くでも1回あたり最大 2048 なので、レートの計算にはまず効かない。等しいかの判定や一周の判定のように正確さが要るときは、Python などの任意精度の言語で扱う。これを利用者向けの文書に書く。
- 資格情報に当たるもの(community、v3 のユーザーや鍵)は行に入れない。資格情報のプロファイルの名前も入れない(要らないので)。

出来事の行:

- Detchi 自身の出来事も、**各機器のファイル**に1行として書く。
  - 行が途切れたとき、Detchi が止まっていたのか、ドロップしたのかを区別できるように。
  - 1日分のファイルだけで、空白の理由が分かる。
  - 背圧によるドロップは機器ごとの書き込みで起きるので、その機器のファイルに書くのが自然。
- Detchi 全体の出来事(起動など)は、機器の数だけ書くことになるが、1日に数行なので量は問題にならない。
- クラッシュや電源断では、止まったことを書けない。起動の行があれば、その前の空白は Detchi が動いていなかったと読める。
- どの機器にも属さない出来事(設定の誤りで起動できない、など)は、記録ではなく標準出力のログに書く。
- 測定の行だけを扱うときは、jq なら `select(.protocol)` で絞る。これを利用者向けの文書に書く。
- 出来事の種類の候補:`start`(起動)、`stop`(正常な停止)、`dropped`(ドロップした件数と期間)、`file_opened`(日の切り替わり。Detchi の版や設定の情報を添える)、`target_removed`(設定から外された)。細部は未決。

### 6.2 ファイルの切り替え

- 機器ごとに1日1ファイル。
- 切り替え、前日分の圧縮、保持期間を過ぎたものの削除は、**Detchi 自身が行う**(logrotate は使わない)。
  - 日付入りのファイル名で直接書くので、名前の変更や開き直しの合図が要らない。
  - Koitohan の側で、`sudo` による logrotate の設定の配置という手作業が増えない。

### 6.3 圧縮

- 既定は **gzip**。
  - Erlang 標準の `:zlib` で書ける。
  - Koitohan の利用者作業用コンテナにある `zgrep` で、ログと同じように中身を見られる。
  - ダウンロードした先でもまず読める。
- **zstd もオプションで選べる**。
  - OTP 28 から stdlib に `zstd` モジュールがある。OTP 29.0.1 で `zstd:compress/1` と `zstd:decompress/1` の往復、ストリーム用の `context` / `stream` / `finish` があることを確かめた。
  - どちらの方法で作ったファイルも、zstd コマンド(v1.5.5)の `zstdcat`、`zstdgrep`、`zstd -t` で読めることを確かめた(10 万行のストリーム圧縮を含む)。
  - ストリームの API は、`zstd:stream/2` が `{continue, Out}`、`zstd:finish/2` が `{done, Out}` を返す。`Out` は iodata で、途中は空のこともある。
  - 中身を見るには、読む側に `zstd` コマンド(`zstdcat`、`zstdgrep`)が要る。Koitohan の利用者作業用コンテナに入れるかは、Koitohan の側で判断する。

### 6.4 保持

- 保持期間は設定できるようにする。既定は **1827 日**(5 年。365 × 5 + 閏日 2 日。参考:Koitohan のログは 1096 日)。
- 量の目安:100 項目を 60 秒ごとに測り、1行を約 150 バイトとすると、1日に約 20MB。gzip で 1/10 程度になるとして、1年で 1GB に届かない。

## 7. 設定ファイルと資格情報

- 設定ファイルは Detchi 専用に作る(Koitohan の FreeRADIUS の `clients.conf` とは定義内容が合わない)。
- SNMP の資格情報は**設定ファイルに直接書く**。
  - 理由:community や v3 の資格情報は、機器の側に設定した値に合わせて書くもので、Koitohan が生成するパスワード(`secrets/`)とは性格が違う。`clients.conf` の共有シークレットと同じ扱いにする。
  - `secrets/` に分ける案は、生成物でない値が `make secrets` の前提と混ざるので採らなかった。
- **名前付きの資格情報(プロファイル)**を定義し、機器からは名前で参照する。形式は未定。たとえば次のような形。

  ```yaml
  credentials:
    campus-v2c: { version: v2c, community: "..." }
    core-v3:    { version: v3, user: "...", auth: sha256, auth_pass: "...", priv: aes128, priv_pass: "..." }
  targets:
    - host: 192.0.2.1
      snmp: { credential: campus-v2c, oids: [...] }
  ```

- 資格情報を、記録(JSON Lines)、エラーのメッセージ、ログのどこにも出さない。テストで確かめる。
- 設定ファイルを人に見せると資格情報も漏れることを、文書に注意として書く。

## 8. 配布、文書、ライセンス

- 配布の形は、当面**ソースのタグ**。利用する側(Koitohan など)の Dockerfile が、多段のビルドでタグからビルドする。
- 文書
  - README と利用者向けの文書は、`<名前>.md`(英語)と `<名前>.ja.md`(日本語)の対にする(Koitohan と同じ)。
  - 本書(基本設計書)は日本語だけ(Koitohan の `docs/basic-design.md` と同じ)。
  - コードのコメントは英語。
- ライセンスは **Apache License 2.0**(Koitohan、NexPinger と同じ)。README には NexPinger と同じく、アイスクリームの要求を含める。

## 9. Koitohan との関係

Detchi は Koitohan に依存しない**汎用**のものにする。Koitohan 固有の制限(行き先の絞り込みなど)は、Koitohan の側のイメージで足す。

Koitohan は、Detchi がリリースされたら組み込む予定で、組み込みは Koitohan のリポジトリで行う。Detchi の側では、次のことを満たしておくと組み込みやすい(Koitohan の CLAUDE.md と `docs/basic-design.md` の方針から)。どれも Koitohan に限らず、コンテナとして素直な性質でもある。

### 9.1 コンテナとして

- Koitohan はタグで固定して取り込む(FreeRADIUS のイメージを `FROM` のタグで固定しているのと同じ)。
- Raspberry Pi 5(aarch64)で動くこと。ベースは Alpine が Koitohan のほかのイメージと揃う。
- Koitohan は全コンテナに次の設定を付けている。これらの下で動くこと。
  - `read_only: true`(ルートファイルシステムは読み取り専用。書くのは tmpfs と記録の置き場所だけ)
  - `security_opt: no-new-privileges:true`(setuid やファイルケーパビリティに頼らない)
  - 環境変数 `TZ`(Alpine なら `tzdata` が要る)
- root 以外で動く。Koitohan は、root で起動して自分で降格する形をとっている。
  - 設定ファイル(資格情報を含む、0600)は、root のうちに tmpfs へ写してから降格する形が Koitohan の流儀(OpenLDAP、OpenSSH の証明書と同じ)。
- ログは標準出力へ(`docker compose logs` で見る)。
- 致命的な誤り(設定の誤りなど)では理由を出して止まる。Koitohan は `restart: unless-stopped` で起動し直させる。

### 9.2 記録の置き場所と見せ方

- 記録は Koitohan の利用者作業用コンテナ(OpenSSH)に読み取り専用でマウントし、ユーザーが `scp` / `sftp` でダウンロードする。
  - **すべてのロール**(`admin`、`operator`、`readonly`)に見せる。`readonly` は状態を見るロールで、同じ値は機器の `show` でも見られる。ログ(`/logs/Hosts`)と同じ扱い。文書に「収集したものはすべてのロールが読める」と書く。
  - ユーザーは LDAP の uid(10000 以降)で入るので、ディレクトリは 0755、ファイルは 0644 で作ること(Koitohan の syslog-ng の `dir-perm` と同じ理由)。
- Docker ホストのユーザーが uid 1000 であることを、Koitohan はほかでも前提にしている(syslog-ng の `PUID`)。記録を書く uid も揃えると扱いやすい。
- バックアップ(Koitohan の `bin/backup.sh`)には、記録は入れない見込み(ログを入れないのと同じ)。設定ファイルは入れる(`clients.conf` と同じ)。

### 9.3 ネットワーク

- Detchi は、Koitohan で初めて**Koitohan から機器へ出ていく**サービスになる(ほかは機器から届くのを受ける)。
- Koitohan の側で、Detchi のコンテナをほかのコンテナのネットワーク(FreeRADIUS などのデフォルトのネットワーク、OpenLDAP の `openssh` のネットワーク)に入れず、行き先を `DEVICE_NETWORKS` に絞る予定。
  - 絞り方は Koitohan の FreeRADIUS や tftpd-hpa と同じく、Koitohan の側で `entrypoint.sh` を足したイメージ(`koitohan/detchi`)を作り、nftables で入れることになる見込み。

### 9.4 任意のサービスとして

- Koitohan の chrony と同じく、Compose の profile で有効にするかを選べるようにする予定。

### 9.5 稼働の確認

- Koitohan の `bin/check_services.sh` は、各サービスを**コンテナの中から、そのコンテナにあるコマンドで**実際に使ってみて判定する。
- Detchi のイメージに、状態を問い合わせる手段があると組み込みやすい。たとえば「動いていて、最後に記録を書いた時刻」を返すコマンド。ただし、警告はしない範囲で。

### 9.6 テスト

- Koitohan のスモークテストでは、問い合わせ先として snmpd のコンテナを立て、Detchi が記録することを確かめることになる。
- 資格情報がログに出ていないことも、Koitohan の側で確かめる(OpenLDAP の管理者のパスワードと同じ確認)。

### 9.7 Koitohan の側の参照先

Koitohan の `docs/basic-design.md` のうち、Detchi に関わる節。

- 3.6 節:chrony。任意のサービスの前例。
- 7.8 節:NexPinger を利用者作業用コンテナに載せる案(保留)。
- 8 節:ネットワーク、接続元の制限、バックアップと復元、稼働の確認。

## 10. 未決定事項

- 設定ファイルの形式(NexPinger は YAML)と、項目の詳細(間隔、タイムアウト、対象の書き方)。
- スキーマの細部(6.1 節のたたき台の残り)。
  - 出来事の種類と、それぞれの項目。
  - `error` の形。
  - `target` の名前の形(ファイルの名前と合わせて決める)。
- ファイルの名前と並び(たとえば `<機器>/<機器>-YYYY-MM-DD.jsonl`)。機器の名前を何で表すか。
- 設定を変えたときの反映の方法(再起動か、再読み込みか)。
- 状態の問い合わせの手段(9.5 節)。
- 将来、配布をコンテナイメージにも広げるか(置き場所と CI が要る。Koitohan は GitHub Actions を Public 化まで保留している)。
- SNMP のインデックスと実体の対応が変わることへの対処。
  - 長期間記録すると、設定や構成の変更で、インデックス(`ifIndex` など)が指すインターフェースが変わることがある。そうなると、同じ OID の値が途中から別のインターフェースのものになる。
  - 起こる場面の例
    - 機器の再起動。RFC 2863 は、`ifIndex` を再初期化の前後で保つことを「できれば」としか求めていない。保つかどうかは機器の設定による(Cisco IOS の `snmp-server ifindex persist` など)。
    - モジュールの抜き差し。
    - 論理インターフェース(VLAN、ポートチャネル、トンネル)の作成と削除。
    - OS の更新。
  - 対処の案(未検討)
    - 値と同じ要求に、`ifName`、`ifDescr`、`ifAlias` などの識別の OID を入れることを勧める(`sysUpTime.0` と同じ扱い。5 節)。Detchi は生の値を記録するだけで、対応付けは使う側に任せる。
    - インデックスの表(たとえば `ifName` の列)を、ファイルの始めや一定の間隔で記録する。
    - 設定で、OID の数値ではなく名前(`ifName` の値など)でインターフェースを指定し、Detchi が引き直す。ただし、記録したものを解釈しないという方針(2 節、5 節)から外れる。
  - インターフェース以外の表(ENTITY-MIB の `entPhysicalIndex` など)にも同じ問題がある。
  - 参考:NMS 製品などの扱い(2026-10-23 に各製品の文書で確認)。大きく分けて、番号を名前で引き直すものと、識別の値も一緒に記録するものがある。
    - 番号を名前で引き直す
      - Zabbix(7.4)の動的インデックス:`<値の OID>["index","<インデックスの基の OID>","<探す文字列>"]` の形で、たとえば `ifDescr` の値が一致する行の番号を使う。表を walk してキャッシュし、以後は見つけた番号がまだ合っているかだけを確かめ、変わっていたら表を walk し直す([文書](https://www.zabbix.com/documentation/current/en/manual/config/items/itemtypes/snmp/dynamicindex))。
      - MRTG:対象の番号の代わりに、`#`(ifName)、`\`(ifDescr)、`!`(MAC アドレス)、`/`(IP アドレス)、`%`(ifType)で書ける。文書は ifName での指定を、スイッチのインターフェースを指す「唯一まともな方法」と呼んでいる。MAC アドレスの場合は、そのセッションの始めに番号を引くと書いてある([文書](https://oss.oetiker.ch/mrtg/doc/mrtg-reference.en.html))。
      - Cacti:データクエリーごとに再インデックスの方法を選ぶ。sysUpTime が戻ったとき(Uptime Goes Backwards)、インデックスの数が変わったとき(Index Count Changed)、すべての項目を確かめる(Verify All Fields)の3つ。行を見分ける項目は、一意で空でない列から Cacti が選ぶ(`index_order` で順を指定できる)([データクエリー](https://docs.cacti.net/Data-Queries.md)、[CLI](https://docs.cacti.net/Command-Line-Scripts.md))。
    - 番号で記録し、名前は付け足すだけ
      - Zabbix(7.4)の LLD:公式の汎用テンプレートは、項目のキーを `net.if.in[ifInOctets.{#SNMPINDEX}]` のように番号で作る。番号が変わると、古い項目は「もう見つからない」になり、設定に従って無効化、削除される。履歴は新しい番号の項目に分かれる([LLD](https://www.zabbix.com/documentation/current/en/manual/discovery/low_level_discovery)、[テンプレート](https://github.com/zabbix/zabbix/blob/release/7.4/templates/net/generic_snmp/README.md))。
      - Prometheus の snmp_exporter:既定の `if_mib` モジュールは、`ifIndex` から `ifAlias`、`ifDescr`、`ifName` を引いてラベルに足す。`ifIndex` のラベルは残すので、番号が変わると別の系列になる。`drop_source_indexes` で元の番号のラベルを外すこともできる([generator](https://github.com/prometheus/snmp_exporter/blob/main/generator/README.md))。
    - どの値で見分けるかを選ばせる
      - LibreNMS:ポートの関連付けの方法(port association mode)を `ifIndex`(既定)、`ifName`、`ifDescr`、`ifAlias` から機器ごとに選べる。全体の既定は `default_port_association_mode`。ただし公式の文書は見つからず、コミュニティの投稿と Issue による。選んだ値が機器に無いと、ポーリングのたびに新しいポートができる不具合の報告がある([フォーラム](https://community.librenms.org/t/port-association-mode/8518)、[Issue #17088](https://github.com/librenms/librenms/issues/17088))。
    - 名前も変わる機器がある(LibreNMS のフォーラムに、QNAP で ifName も変わった例)。どの方法も万能ではない。
