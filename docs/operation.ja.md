# 運用

[English](operation.md) | 日本語

Detchi のビルド、起動、停止、見守り方です。

## 目次

- [ビルド](#ビルド)
- [コマンド](#コマンド)
- [起動](#起動)
- [停止](#停止)
- [設定の変更と更新](#設定の変更と更新)
- [ログ](#ログ)
- [動いているかの確認](#動いているかの確認)
- [Detchi が書くもの](#detchi-が書くもの)
- [コンテナで動かす](#コンテナで動かす)
- [クラッシュダンプ](#クラッシュダンプ)

## ビルド

Detchi はソースのタグで配布し、escript(1つのファイル `detchi`)にビルドして使います。

```sh
git clone https://github.com/jolly-jive/detchi.git
cd detchi
git checkout <タグ>
mix deps.get
MIX_ENV=prod mix escript.build   # ./detchi ができる
```

- ビルドには Elixir 1.19 以上と Erlang/OTP 28 以上が要ります。
- 動かすには Erlang/OTP 28 以上が要ります。escript は ERTS を含まず、先頭の行が `#! /usr/bin/env escript` なので、`escript` が `PATH` にあること。
- Detchi が動くのは Linux だけです。

## コマンド

| コマンド | |
| --- | --- |
| `detchi run` | サービスとして動き、止められるまで測定を記録します。 |
| `detchi check-config` | 設定ファイルを検査して終わります([設定](configuration.ja.md#設定の検査)を参照)。 |
| `detchi check-config --fingerprints` | 機器ごとの設定のフィンガープリントも出します。 |
| `detchi --version` | 版を出します。 |
| `detchi --help` | 使い方を出します。 |

設定ファイルは `$DETCHI_CONFIG`、なければ `/etc/detchi/detchi.yml` です。

| 終了コード | |
| --- | --- |
| 0 | 成功。`detchi run` では、SIGTERM か SIGHUP で止まったとき。 |
| 1 | 誤り。設定に誤りがある、`detchi run` が起動できなかった、など。 |
| 2 | 使い方の誤り(知らないコマンドや選択肢)。 |

## 起動

`detchi run` は次のことをします。

1. 設定ファイルを読んで検査します。誤りがあれば標準エラー出力に出して、終了コード 1 で終わります。警告はログに出します。
2. ICMP の測定に要る ICMP のソケットを開けるか確かめます。開けなければ理由を標準エラー出力に出して、終了コード 1 で終わります。`net.ipv4.ping_group_range` が、動かすユーザーのグループを含む必要があります。
3. Erlang の SNMP のマネージャーのファイルを `<一時ディレクトリ>/detchi-<OS の pid>/` に書き出します。止まるときに消します。一時ディレクトリは、`TMPDIR`、`TEMP`、`TMP`、`/tmp`、最後の手段としてカレントディレクトリのうち、最初に書けるものです。どれも書けなければ、終了コード 1 で終わります。
4. 各機器のファイルに `start` の行を書き、測り始めます。

測定の最初の回は、起動してからその測定の `interval` の間に、名前から決まる位相の時刻に来ます([設定](configuration.ja.md#probes)を参照)。

起動のときに引けないホスト名があっても、起動は止めません([設定](configuration.ja.md#host-と-family)を参照)。

## 停止

Detchi は **SIGTERM**(`kill`、`docker stop`、`systemctl stop`)か SIGHUP で止めてください。どちらを受けても、Detchi は次のことをします。

- 応答を待っている要求は待たずに打ち切り、その行は書きません。`docker stop` の 10 秒に収まるようにするためです。
- 各機器のファイルに `stop` の行を書きます。打ち切った要求の数が `abandoned` に入ります。
- ファイルを閉じて、終了コード 0 で終わります。

SIGHUP で設定を読み直すことはありません。SIGTERM と同じく、Detchi を止めます。

SIGINT(端末での Ctrl-C)では、**`stop` の行を書かずに**その場で止まります。終了コードは 130 です。記録の上では、Detchi が落ちたのと同じに見えます。Erlang の VM は、SIGINT を Detchi に扱わせません。

## 設定の変更と更新

Detchi が設定を読むのは、起動のときだけです。変えるときは:

1. ファイルを書き換えます。
2. `detchi check-config` を動かします。誤りがあると、Detchi は起動しません。
3. Detchi を再起動します。

再起動は、記録に `stop` と `start` の行として残ります。間隔が 60 秒なら、再起動で欠けるのは1回分ほどです。

版を更新するときは、新しいタグをビルドして、同じように再起動します。先に、新しい版の `detchi check-config` で設定を検査してください。新しい版で検査が増えることがあります。また、設定を変えなくても、新しい版で設定のフィンガープリントが変わることがあります([設定](configuration.ja.md#設定を変えるとき)を参照)。

## ログ

Detchi はログを標準出力に出します。1つのメッセージが1行で、時刻とレベルが付きます。

```
00:05:48.543 [error] core1: dropping lines: cannot write /var/lib/detchi/core1/core1-2026-10-28.jsonl (eacces)
00:05:53.921 [notice] SIGTERM received - shutting down
```

ログに出るもの:

- 起動のときの、設定の警告。
- 書けなかった行(`dropping lines`)と、また書けるようになったこと(`writing again`)。
- 圧縮や削除ができなかった記録のファイル(後でやり直します)。
- 測定の `internal` のエラーの詳しいこと。

書けなくても Detchi は動き続けます。ディスクが空けば、そのまま続けられるようにするためです。気づくには、ログか記録(下)を見てください。

資格情報は、ログに出ません。

## 動いているかの確認

Detchi は失敗も含めて測定ごとに1行書くので、ファイルが最近書かれている機器は、測られています。

これを確かめるコマンド `detchi status` を予定していますが、まだありません。それまでは、機器のいちばん新しいファイルの更新時刻を見てください。

```sh
ls -lt --time-style=full-iso /var/lib/detchi/core1 | head -3
```

0 時の直後は、前日のファイルのほうが今日のファイルより新しいことがあります。新しい2つを見てください。

## Detchi が書くもの

| 場所 | 書くもの |
| --- | --- |
| `data_dir` | 記録。umask によらず、ディレクトリは 0755、ファイルは 0644 で作ります。ほかのユーザーが読んでダウンロードできるようにするためです。 |
| 一時ディレクトリ | SNMP のマネージャーのファイル(数 KB)。SIGTERM か SIGHUP で止まるときに消します。ほかのシグナル(SIGINT など)で止まると、ディレクトリが残ります。 |
| 標準出力 | ログ。 |
| 標準エラー出力 | `detchi run` を起動のときに止めた誤りと、誤りがあるときの `detchi check-config` の出力。 |

ほかには何も書きません。PID ファイルも作らず、頼まれない限りクラッシュダンプも書きません([クラッシュダンプ](#クラッシュダンプ)を参照)。

Detchi に権限は要りません。root も、ケーパビリティも、setuid も要りません。設定ファイルを動かすユーザーが読めること、`data_dir` に書けることが要ります。

## コンテナで動かす

Detchi は、次の設定のコンテナで動きます。

- **Erlang/OTP 28 以上のイメージ**(`erlang:28-alpine` など)。escript は、多段のビルドの前の段でビルドして写します。
- **`TZ`**。ファイルの日付と `ts` のオフセットに使います。Alpine には `tzdata` のパッケージが要ります。
- **`data_dir` のボリューム**。記録の置き場所です。
- **`read_only: true`** でも動きます。SNMP のマネージャーのファイルのために、`/tmp`(か `TMPDIR`)を tmpfs にしてください。
- **`security_opt: no-new-privileges:true`** でも動きます。Detchi は setuid もファイルのケーパビリティも使いません。
- **root 以外のユーザー**で動きます。Docker の既定の `net.ipv4.ping_group_range` は、どのグループにも ICMP のソケットを許しています。
- **`restart: unless-stopped`** なら、落ちても起動し直します。再起動の前に `detchi check-config` を動かしてください。設定に誤りがあると、コンテナは何も測らないまま起動し直しを繰り返します。
- `docker stop` は SIGTERM を送ります。Detchi はその 10 秒の間に止まります。
- ログは標準出力にあります。`docker logs` や `docker compose logs` で見られます。
- Detchi は要求を送り出すだけです。ほかから接続を受けるポートは開きません。SNMP のマネージャーは、OS が選んだ UDP のポートで応答を受けます。

## クラッシュダンプ

Erlang の VM が落ちると、クラッシュダンプ(`erl_crash.dump`)を書くことがあります。Detchi は、既定でこれを止めています。ダンプにはプロセスのメモリが入り、設定の SNMP の community も入るためです。

落ちた原因を調べるためにダンプが要るときは、起動のときに2つの変数を設定してください。

```sh
ERL_CRASH_DUMP=/var/tmp/detchi.dump ERL_CRASH_DUMP_SECONDS=60 detchi run
```

- `ERL_CRASH_DUMP` は書き出す場所です。`ERL_CRASH_DUMP_SECONDS` は書き出しにかけてよい秒数で、`0`(Detchi の既定)なら書きません。
- ダンプの大きさは数 MB です。書けて、消えない場所に置いてください。tmpfs は、コンテナが止まると消えます。
- **ダンプには資格情報が入ります。** 調べ終わったら消し、そのまま人に渡さないでください。

ダンプがなくても、止まった理由は、止まる直前のログに出ます(`Kernel pid terminated ...` など)。
