# agswt

*[English](README.md)*

> 日本語版。正は [README.md](README.md)（英語）— 内容がずれた場合は英語版に従う。

個人が持つ複数のアカウントを、プロフィール化して管理する。

`agswt` は、一人の人間が所有する複数のアカウントを **profile** という単位にして、
その周辺の道具立てを提供する skill — profile の作成、ディレクトリごとの
アカウント割り当て、既存作業の profile 間移動、そして全プラン横断の消費量
レポート（**いまサインインしていないアカウントも含む**）。

複数のアカウントを持つことについての公式の見解は、下段の
[Anthropic の規約に対してどこに立っているか](#anthropic-の規約に対してどこに立っているか)
を参照。

対応は **Claude Code** と **Codex**。profile・ディレクトリ束縛・消費量レポートは
両方をカバーする。既存履歴の移動は Claude のみ（Codex はスレッド履歴を
データベースに持つ — [`codex-notes.md`](skills/agswt/references/codex-notes.md) 参照）。

## インストール

```bash
npx skills add fujibee/agswt
```

## 使い方

agswt は CLI ではなく skill — エージェントに普通の言葉で頼んで動かす:

1. **「`work/acme` という profile を作って」** エージェントがディレクトリを準備する。
   この時点ではサインインしない — それは最後に自然に来る。
2. **「`~/code/acme` 以下でこれを使いたい」** エージェントが direnv を確認し
   （無ければ2行の導入手順を出す）、親 `.envrc` への連結も含めて正しい `.envrc` を
   書き、束縛を両側で実測する。既存プロジェクトの履歴の移行もここ — 全部ただの
   ファイル操作で、credential は関与しない。
3. **そのディレクトリで `claude` を起動する。**ここで1回だけサインインを求められる —
   このブラウザ OAuth が本物のサインインで、あなたにしかできない。
   （先に CLI でサインインしてもこの画面は消えない — 実測済み — ので、
   この流れでは最初からやらない。）Codex の profile は代わりに CLI でサインインする:
   `CODEX_HOME=<dir> codex login`。
4. **完了。**以後、その下はすべてそのアカウントで動く。残量はいつでも `report`。
   「見るためだけ」のアカウントだけが例外で、起動が来ないので CLI サインインで
   入れておく。

profile 名は入れ子にできる: `work/acme`、`clients/x` — 名前の `/` がそのまま
グループになり、report にも構造が出る。名前は2つのツールで共有される:
**「`work/acme` の Codex profile も作って」**で同じ名前に Codex 側の半分ができ、
ディレクトリを束縛すると `CLAUDE_CONFIG_DIR` の隣に `CODEX_HOME` も書かれる。

## なぜ

目的は2つ — **プロジェクトによって違うアカウントを使いたい**、そして
**複数サブスクリプションの残量を知りたい**。両方に効くモデルはこう:
**アカウントはプロファイルにアサインする**。そして**ディレクトリをプロファイルに
結びつける** — その下のプロジェクトは全部そのプロファイルを使うことになる。
アサインの実体はサインインそのものなので、切り替えもサインインし直すだけ:
そのプロファイルで動いているどれか1つの Claude Code で別アカウントにログイン
すれば、結びついたディレクトリは全部付いてくる。
残量を読むだけで使わない「見るためだけのプロファイル」も作れる。

その下の仕組み: どちらのツールも config ディレクトリ1つにつき、ログイン済みアカウントをちょうど1つ持つ。
選択は Claude Code が `CLAUDE_CONFIG_DIR`（既定 `~/.claude`）、Codex が `CODEX_HOME`
（既定 `~/.codex`）。分離の仕組みはこれが全部で、
コンテナも VM も、切り替えのためのサインアウトも要らない。実際に面倒なのは
その周辺 — どのファイル群が「アカウント」を構成するのか、コピーしたプロジェクトが
なぜ履歴を半分失うのか、完全に健全なアカウントがなぜ「サインアウト済み」と
報告されるのか。

profile の置き場所は既定で **`~/.claude_profiles`**（Claude）と
**`~/.codex_profiles`**（Codex）。別の場所に置くなら環境変数
`AGSWT_PROFILES_ROOT` と `AGSWT_CODEX_PROFILES_ROOT` — 全スクリプトが同じ変数を
読むので、場所の変更は1箇所で効くか、まったく効かないかのどちらかしかない。

`agswt` はその知識を、文書化して実行可能にしたもの。

## できること

| 操作 | 内容 | 対象 |
|---|---|---|
| `create-profile` | 新しい profile を作り、サインインコマンドを表示して**止まる** | Claude, Codex |
| `verify` | profile が本当にサインイン済みか、誰としてかを確認する | Claude, Codex |
| `migrate-workspace` | 1プロジェクトのデータを profile 間で移動 | Claude |
| `wire-direnv` | `.envrc` でディレクトリと profile を結びつける | 両方同時 |
| `rename-workspace` | ディレクトリ移動に保存済み slug を追従させる | Claude |
| `doctor` | 既知の故障モードを点検 | Claude, Codex |
| `report` | 全 profile の消費量レポート | Claude, Codex |

## 知っていることの一例

- サインインは OAuth フローで、人間が要る。skill は準備を整え、コマンドを表示して
  **止まる** — profile が ready であるかのような偽装はしない。
- 消費量は `claude` バイナリに聞く（`claude -p "/usage"`）。Keychain から OAuth
  トークンを取り出すことは**しない**。Anthropic はこの credential を Claude Code
  自身に限定しており、スクリプトがそれを持てば「サブスク credential を使う
  サードパーティツール」になる — そしてバイナリはコストゼロ・モデル呼び出しなしで
  答えてくれる。
- macOS のログイン keychain がロックされていると、全 credential 読み取りが
  `errSecInteractionNotAllowed` で失敗し、何も表示せず、**全アカウントが
  サインアウト済みに見える** — 別ウィンドウで正常に動いているものも含めて。
- `claude auth status` はトークンを読むだけで更新しない。更新は API に実際に
  届く呼び出しでだけ起こる。
- MCP サーバは2つのスコープにある。user スコープだけコピーすると、プロジェクト
  ごとのサーバが黙って全部落ちる。
- セッションのサイドカーディレクトリは transcript の隣にあり `*.jsonl` ではない
  ので、glob は必ず取りこぼす。
- `settings.json` は絶対に symlink にしない: temp-file-and-rename で書き換えられる
  ため、リンクが実ファイルに置き換わる。
- Codex の消費量も同じ流儀で読む — 無改変の `codex` バイナリ（その app server に
  stdio で）に聞く。`auth.json` は開かず、セッションログの rate limit スナップショットも
  漁らない: リセットを1回使うと、それ以前のスナップショットは全部嘘になる。
- `codex login status` は「ログイン済みか否か」しか言わず、誰としてかは言わない。
  Codex profile の背後のアカウントも app server から取る。

症状と対処を含む完全な一覧は
[`skills/agswt/references/traps.md`](skills/agswt/references/traps.md)。

## Anthropic の規約に対してどこに立っているか

サブスクリプション credential の周りに多アカウントの道具を作るなら、この問いには
明示的に答えるべきなので、答える。agswt は Anthropic 自身の文書が引く線の内側に
収まるよう設計されている。我々は Anthropic ではなく、これは適合判定ではない —
以下の引用は 2026-08-22 時点の文書からの逐語で、すべてリンクしてあるので
自分で読んでほしい。（引用は原文の英語のまま。証拠性のため訳さない。）

**credential を持つのは Claude Code だけ。**
[Claude Code documentation](https://code.claude.com/docs/en/legal-and-compliance)
は、開発者は "may not collect, store, or intermediate Claude.ai credentials or
session tokens"（Claude.ai の credential やセッショントークンを収集・保存・仲介
してはならない）と定める。agswt はどれもしない: トークンを読まず、保存せず、
コピーせず、送信しない。消費量の読み取りはすべて、無改変の Claude Code バイナリが
実行する `claude -p "/usage"` であり、OAuth credential に触れるプロセスは
バイナリだけ。[`/usage` はビルトインコマンド](https://code.claude.com/docs/en/commands)で、
コストゼロ・モデル呼び出しなしで答える。

**サインインは Anthropic 自身のフローで完結する。**同じページは
"sign-in to a Claude account must complete through Anthropic's own flow"
（サインインは Anthropic 自身のフローで完結しなければならない）と定め、同時に
"an end user from signing in to the unmodified Claude Code binary with their own
Claude subscription"（エンドユーザーが自分のサブスクで無改変バイナリにサインイン
すること）は妨げられないと明言している。agswt は profile ディレクトリを準備して
止まる。サインインは `claude` 自身で行う。ログインフローの実装もラップもしない。

**自分のアカウントの、自分の使用量。**
[Consumer Terms](https://www.anthropic.com/legal/consumer-terms) はアカウントの
共有や他者への提供を禁じる。agswt が読むのは、サインインした本人の、本人の
アカウントに含まれる使用量。再提供・転売・仲介はなく、アカウントの共有もない。

**文書化された仕組みで、しかも文書化された用途。**config ディレクトリ1つにつき
ログイン1つ、選択は `CLAUDE_CONFIG_DIR` — これは Claude Code 自身のモデルであり、
[環境変数リファレンス](https://code.claude.com/docs/en/env-vars)はこの使い方を
名指しで挙げている: "Useful for running multiple accounts side by side: for
example, `alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work claude'`"
（複数アカウントの並行運用に有用）。agswt はその周りに帳簿を付けるだけで、
それ以上ではない。

agswt が意図的に**そうでない**もの、2つ:

- **使用量を増やす道具ではない。**文書は、公表されている limit は
  "assume ordinary, individual usage"（通常の個人利用を前提とする）と述べている。
  agswt が与えるのは*可視性* — どのアカウントにどれだけ残っているか、limit に
  不意打ちされないために — と、ディレクトリごとのきれいな分離。どのプランが
  何を与えるかは何も変えない。
- **複数アカウントが是認されているという主張ではない。**Consumer Terms には
  一人が持てるアカウント数を制限する条項はない — ただし**沈黙は許可ではない**。
  そして [Usage Policy](https://www.anthropic.com/legal/aup) は、BAN 逃れの
  ための別アカウント使用を禁じている。Claude Code チームのメンバーは
  「"it'"'"'s not against terms of service to have multiple MAX accounts"
  （複数の MAX アカウントを持つこと自体は規約違反ではない）」と
  [公に述べており](https://x.com/trq212/status/2024230184287949207)、線を越える
  のは「トークンの転売のような使い方」だとしている。これは執行がどこを向いて
  いるかを知る手がかりにはなる — ただし**スタッフのポストは規約そのものではない**。
  この節が依拠するのは上記の文書であって、このポストではない。agswt は一人の
  人間が自分自身のアカウントを運用するためのものであり、それ以外ではない。

規約は変わるし、Anthropic は予告なく制限を執行する権利を留保している。この節は
上記日付時点の文書の記述であり、依拠するなら必ずリンク先を読むこと。

**OpenAI の規約に対しても同じ。**Codex 側も同じ原則で作ってある: 無改変の `codex`
バイナリが自分の credential を読み、agswt はそれを通してサインインした本人の
アカウントを読む。Codex のリードは[公に](https://x.com/thsottiaux/status/2090675027670978569)
（2026-08-21）、許されないのは "converting a subscription into api traffic — often
shared with several users"（サブスクを、しばしば複数人で共有される API トラフィックに
変換すること）だと述べている。agswt は何も再提供しない。OpenAI の消費者規約は
rate limit の回避も禁じているが、agswt はどのプランが何を与えるかを変えない。
詳細は [`codex-notes.md`](skills/agswt/references/codex-notes.md)。

## 代替ツール

`CLAUDE_CONFIG_DIR` によるプロファイル切替は小さなジャンルで、少なくとも10本ある。
[claude-code-profiles](https://github.com/quinnjr/claude-code-profiles)（最多スター）、
[claude-profile-manager](https://github.com/JakubKontra/claude-profile-manager)
（思想が最も近い: direnv によるプロジェクト単位の紐づけ）、
[cprof](https://github.com/dcotelo/cprof)（同じ発想を同じ言葉で）など。
切替だけが要るなら、どれでも用は足りる。

調べた範囲で agswt が異なるのは:

- **使用量レポートが credential に一切触れない。**残量を出す既存ツールは OAuth
  credential を自前で読むか差し替える設計。agswt は無改変の `claude` バイナリに
  聞くだけ。上の規約の節が、この差が効く理由。
- **Codex も同じレポートに載る。**同じ profile 名、同じ `.envrc`、2つのサブスクを
  1つの表で。
- **履歴を運ぶ。**`migrate-workspace` は既存プロジェクトの transcript・memory・
  MCP 2スコープ・sidecar を、カテゴリ別の件数検証つきで profile 間移動する。
  切替ツールは「次からの作業」の行き先を決めるだけで、「今まで」を運ぶものは
  見当たらなかった。
- **CLI ではなく skill。**エージェントが実行する手順とスクリプトの形で配る
  （`npx skills add`）。罠はコードの隣に文書化してある。

## 要件

- macOS または Linux
- Claude Code と/または Codex（消費量レポートは codex-cli 0.153 以降 — app server の
  `account/rateLimits/read` が要る）
- 任意: ディレクトリごとの自動切り替えに `direnv`、アカウントごとに GitHub
  identity を固定するなら `gh`

## ライセンス

MIT
