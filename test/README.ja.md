# テスト

*[English](README.md) | 日本語*

rcd プラグインのテスト群。**どこまで自動化できるか**で分類してあり、それは各層が
何を検証できるかに従う。決定的な機構（unit の起動ロジック、skill/plugin 定義、
systemd 配線）は**スタブ `claude`**（`test/stub-claude`）で検証し、認証もネットも
不要なので完全自動。**実 Claude** が `SKILL.md` を辿るか、プラグインがロードされるか、
`claude remote-control` のライブ実行時挙動が動くか、は実 Claude が要るため手で実行する。

実 Claude を使う層はすべて、専用 `HOME` を持つ**使い捨ての privileged systemd
Docker コンテナ**内で完結し、ホストの unit・skill・インスタンスには触れない。

## 概観

| 層 | 自動化 | 検証する内容 |
|---|---|---|
| `lint` | 全自動（CI） | skill/plugin の**定義**: frontmatter、`allowed-tools` の網羅、unit のインラインシェルが解析可能で `RCD_INSTANCE` を配線、同梱パスが `${CLAUDE_PLUGIN_ROOT}` 形式。 |
| `logic` | 全自動（CI） | unit の**起動ロジック**を単体で: worktree か same-dir、`--name` / セッション名 prefix、未初期化・claude 欠落ガード。 |
| `service` | 全自動（要 Docker） | unit が **`systemctl --user` サービスとして起動**: 基底プロセスの引数と `RCD_INSTANCE`、same-dir と worktree。 |
| `skill` | 手動（機械判定） | 実 Claude が **`SKILL.md` を辿る**: プラグインのロード、`/rcd` 解決、`init` が設定記録＋unit 導入、`start` が dir 作成＋unit enable、不正名の拒否。 |
| `guards` | 手動 | TTY が必要な**破壊動詞の保護**: typed confirm（`destroy` / `restart-all`）と SELF 拒否を、スタブ固定 unit に対して検証。 |
| `live` | 手動 | スタブでは届かない **`claude remote-control` のライブ実行時挙動**: on-demand/worktree セッションへの `RCD_INSTANCE` 継承（G4）とセッション名形式（G5）。 |

3つの受け入れ単位（`skill` / `guards` / `live`）はそれぞれ `test/acceptance/`
内の独立したスクリプトで実行する。各単位はイメージをビルドし、自分のコンテナを起動して
tear down する — 共有状態も実行順序の依存もない。手順の詳細は
`docs/manual-acceptance.md` を参照。

## 全自動

hermetic（スタブ `claude`）。毎回の変更で実行する継続的な安全網。

```sh
./test/run.sh        # lint + logic — Docker・ネット不要、CI-safe
./test/service.sh    # service — systemd Docker コンテナをビルド（要 Docker）
```

`lint` は外部リンタ `skill-tools` / `claudelint` がある場合（または
`RCD_LINT_EXTERNAL=1`）に併せて走る。npm を取得するためオプトイン。

## 手動 — `skill`（機械判定）

`setup-token`（inference スコープ）で足りる。

```sh
claude setup-token                 # Claude サブスクリプションが必要
export CLAUDE_CODE_OAUTH_TOKEN=<token>
./test/acceptance/skill.sh
./test/acceptance/skill.sh --teardown
```

期待値: `skill: N passed, 0 failed`。一部のモデル判断項目（例: 不正名をどう拒否するか）
は自動採点せず読んで確認する用に出力される。

**走らせるとき:** `SKILL.md` の文面（手順・名前ルール・同梱ファイル参照）が変わった、
梱包（`plugin.json` / `marketplace.json`、構成、skill 名、unit 位置）が変わった、
`claude` CLI をメジャー級／挙動に影響する版へ更新した。

## 手動 — `guards`

**full `claude auth login`** が必要。対話 TUI は setup-token では認証できず
（headless `-p` のみ可）、通常のログイン onboarding に入る。スクリプトが対話 Claude
セッションを開くので、onboarding でフルログインを選び、表示されるチェックリストに従う。

```sh
./test/acceptance/guards.sh        # onboarding で full `claude auth login` を選ぶ
./test/acceptance/guards.sh --teardown
```

**走らせるとき:** `SKILL.md` の confirm / SELF 検出 / 自己保護ロジックが変わった。

## 手動 — `live`

**full `claude auth login`**（`setup-token` では `claude remote-control` を起動
できない）と claude.ai/code アプリが必要。スクリプトがログイン・インスタンス起動・
アプリでの確認を案内する。詳細な手順は `docs/manual-acceptance.md` を参照。

```sh
./test/acceptance/live.sh
./test/acceptance/live.sh --teardown
```

**走らせるとき:** ベースライン確立、unit の識別/命名/spawn 配線（`RCD_INSTANCE`、
`--name`、セッション名 prefix、`--spawn`）が変わった、または `claude` / claude.ai が
remote-control の env 継承やセッション名描画を変えた疑いがあるとき。

## 補足

- `skill`・`guards`・`live` は設計上、手動 — CI に組み込まない。
- 発見は昇格させる: 受け入れ単位で最初に捕えた失敗は、可能なら `lint` / `logic`
  の検査に移し、手動の面を縮小する。
