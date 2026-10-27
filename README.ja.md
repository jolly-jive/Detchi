# Detchi

[English](README.md) | 日本語

ネットワークのメトリックス(ICMP / TCP / UDP の RTT と、SNMP の値)を、収集して記録するだけのサービスです。Linux の上で動き続けてネットワーク機器を測り、測ったものを JSON Lines のファイルに書きます。

警告、チャート、統計の計算はしません。記録をダウンロードして、別の仕組みで行ってください。

Elixir/OTP で書いています。[Koitohan](#koitohan)(Raspberry Pi で動く、ネットワーク機器向けの小さな管理サーバ)に組み込むために作っていますが、Koitohan には依存しません。

*Detchi は開発中で、まだリリースはありません。*

## 名前

「でっち(丁稚)」。大阪の商家の丁稚です。Koitohan は商家の末娘(「小いとはん」)から取った名前なので、同じ商家の住人として並べました。丁稚奉公は厳しいものでしたが、手代、番頭、暖簾分けへと続く、商人としての修行の場でもありました。いまは RTT と SNMP を書き留めるだけですが、gNMI や NETCONF を覚えて育っていく余地があります。

## 機能(現時点)

- ICMP Echo、TCP の接続、UDP(DNS、NTP、QUIC)の RTT。
- SNMP v2c の get。v3 にはまだ対応していません。
- 設定ファイルは YAML で1つだけ。厳しく確かめます。知らないキー、重なったキー、型の誤りがあれば、起動のときに行と桁を示して止まります。
- 資格情報は、記録、エラーのメッセージ、ログのどこにも出しません。
- 測る時刻は、名前から決まる位相で間隔の中に散らばり、再起動しても変わりません。
- ホスト名は一定の間隔で引き直します。引き直しに失敗したら、前のアドレスで測り続けます。
- 記録のファイルは機器ごと、日ごと(`TZ` によるローカルの日付)。日が終わったら gzip か zstd で圧縮し、`retention_days` を過ぎたら消します。
- `start` と `stop` の行、機器ごとの設定の指紋、壁時計が跳んだことを示す行を書くので、記録の欠けや設定の変化を記録から読めます。

## 動かすのに要るもの

- Linux。
- Erlang/OTP 28 以上(zstd に OTP 28 が要ります)。escript は ERTS を含みません。
- ビルドには Elixir 1.19 以上。
- ICMP には、`net.ipv4.ping_group_range` が動かすユーザーのグループを含むこと(権限の要らない ICMP のソケットを使います)。Docker の既定の値で動きます。

## ビルドと実行

```sh
mix deps.get
MIX_ENV=prod mix escript.build   # ./detchi ができる
```

```sh
./detchi check-config            # 設定ファイルを確かめる
./detchi run                     # サービスとして動かす
```

設定ファイルは `$DETCHI_CONFIG`、なければ `/etc/detchi/detchi.yml` です。短い例:

```yaml
data_dir: /var/lib/detchi
compression: gzip

credentials:
  campus-v2c: { version: v2c, community: "..." }

targets:
  - name: core1
    host: 192.0.2.1
    snmp:
      credential: campus-v2c
    probes:
      - { name: ping, protocol: icmp }
      - { name: ssh,  protocol: tcp, port: 22 }
      - { name: sysuptime, protocol: snmp, interval: 300s, oids: ["1.3.6.1.2.1.1.3.0"] }
```

設定を変えたら、Detchi を再起動してください。SIGHUP では読み直しません。

## 文書

- [基本設計書](docs/basic-design.md)(日本語だけ):設計の背景、決まったこと、未決定事項。

## Koitohan

Koitohan は、同じ作者のネットワーク機器向けの小さな管理サーバです(まだ公開していません)。Detchi は汎用のサービスとして作り、Koitohan に固有のことは Koitohan の側で足します。

## ライセンス

Copyright 2026 Cayenne Ryo

[Apache License 2.0](LICENSE) で公開しています。[NOTICE](NOTICE) も参照してください。

## アイスクリーム

Detchi が役に立ったら、アイスクリームを奢ってください。🍦

*これはお願いであって、ライセンスの条件ではありません。Detchi は Apache-2.0 で、追加の条件はありません。*
