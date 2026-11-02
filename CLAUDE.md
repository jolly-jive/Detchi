# CLAUDE.md

Detchi は、ネットワークのメトリックス(ICMP / TCP / UDP の RTT と SNMP の値)を収集して記録するだけのサービス。Elixir/OTP で書き、Linux だけを対象にする。設計の背景、決まったこと、未決定事項は `docs/basic-design.md` を参照。

## 文書

- README と利用者向けの文書は、`<名前>.md`(英語)と `<名前>.ja.md`(日本語)の対にする。片方を直したらもう片方も直すこと。
- `docs/basic-design.md` は日本語だけ。
- コードのコメントは英語で書く。
- README には、NexPinger と同じくアイスクリームの要求を含める(文面は NexPinger の README に合わせる)。
- 文書(`.md`)の書き換えは Edit / Write で行う。シェル経由(ヒアドキュメント、`sed`、スクリプト)では書き換えない。Markdown の逆引用符(`` `...` ``)や `$(...)` がシェルに展開され、文中の例示のコマンドが実行されうるため(以前、実際に起きた)。

## 作業の進め方

- 返事は日本語。コード、コミットメッセージ、プルリクエストの本文は英語。
- 定型の git 操作(コミット、push、ブランチの作成と切り替え、マージ後の片付け)は、コマンドを示すだけにして、実行はユーザーが行う。
- リポジトリの作成、プルリクエスト、Release はユーザーがウェブ画面で行う(このホストに `gh` CLI はない)。
- コミットの作者は Koitohan、NexPinger と同じく `Cayenne Ryo <7951074+jolly-jive@users.noreply.github.com>`。リポジトリごとに `git config user.name "Cayenne Ryo"` と `git config user.email 7951074+jolly-jive@users.noreply.github.com` を設定する(グローバルの設定は別の名前なので、そのままでは使わない)。

## 参照

- Koitohan:https://github.com/jolly-jive/Koitohan
  - `CLAUDE.md`:構成と、守っている方針の詳細。
  - `docs/basic-design.md`:Detchi に関わる節は、Detchi の `docs/basic-design.md` 9.7 節にまとめてある。
- NexPinger:https://github.com/jolly-jive/nexpinger
