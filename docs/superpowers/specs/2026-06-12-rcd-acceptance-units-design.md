# RCD 受け入れ検証の単位設計 — `skill` / `guards` / `live`

- 日付: 2026-06-12
- スコープ: rcd プラグインの **実 Claude を要する受け入れ検証**を、独立して実行できる単位に再設計する。**自動層（lint/logic/service）は対象外**（既存・継続稼働）。公開作業（remote/PR）も対象外。
- 関連: 既存設計 `docs/superpowers/specs/2026-06-11-rcd-naming-and-worktree-design.md`（命名/worktree。本書は別トピック）。本書の受け入れ方式は、旧 `docs/superpowers/plans/2026-06-11-rcd-naming-and-worktree.md` の Task0–7（ホスト直・退避/復元の手動受け入れ）を**置換**する。

---

## 1. 目的

`lint`/`logic`/`service` はスタブ `claude` で「定義の健全性」と「unit 起動機構」を決定的に検証する。だが**実 Claude が `SKILL.md` を辿るか／プラグインがロードされ `/rcd` が解決するか／ライブ `claude remote-control` の実行時挙動**は、実 Claude（一部はログイン済みアカウントとアプリ）を要し、自動層では届かない。これを **独立実行できる3単位**に整理し、各単位の「何を検証するか・どこで動くか・いつ走らせるか」を一意に定める。

## 2. 前提（対象外の自動層）

| 層 | 検証 | 備考 |
|---|---|---|
| `lint` | 定義の健全性（frontmatter、allowed-tools 網羅、unit インラインシェル解析、`RCD_INSTANCE` 配線、同梱パスが `${CLAUDE_PLUGIN_ROOT}`） | CI 可、依存ゼロ |
| `logic` | unit 起動ロジック単体（worktree/same-dir 判定、命名、ガード） | スタブ |
| `service` | unit が実 `systemctl --user` サービスとして起動（引数・base の `RCD_INSTANCE`、same-dir/worktree） | スタブ・要 Docker |

実行時 argv（`--spawn`/`--name`/`RCD_INSTANCE` on base）は `service` が決定的に保証済み。本設計はこれらを再検証しない。

## 3. 基本モデル（環境は一様、差は「経路」と「認証」だけ）

本スコープの全検証は、**専用 `HOME` を持つ使い捨ての privileged systemd Docker コンテナ内の「実 Claude Code」**に対して行う（ホストの unit/skill/インスタンスには触れない）。各検証の違いは次の2軸に集約される:

- **アクセス経路**: headless `claude -p` ／ `docker exec` 対話 TTY ／ claude.ai/code アプリ（リレー）。
- **認証スコープ**: inference（`setup-token`）／ full（`claude auth login`）。

「skill 環境 vs live 環境」ではなく、**同一環境**を経路と認証で使い分ける、と捉える。

## 4. 単位の定義

各表＝1単位。`いつ` は頻度ではなく変更ケース。

### 単位 `skill`（headless・inference・機械判定）
実 Claude が `SKILL.md` を辿る、自動化された確認。

| # | 検証項目 | 経路 | 認証 | 判定 |
|---|---|---|---|---|
| 1 | プラグインがロード／`/rcd` 解決 | headless | inference | 機械 |
| 2 | `init` が SKILL 通り（root/claude-bin 記録＋unit 導入＋daemon-reload） | headless | inference | 機械 |
| 3 | `start` が SKILL 通り（`<root>/<name>` 作成＋unit enable） | headless | inference | 機械 |
| 4 | 不正名の拒否（`../evil` 等） | headless | inference | 機械（副作用で判定） |

- **判定シグナル（#1）**: free-form テキストの grep ではなく `claude -p --output-format stream-json` の `system/init` から判定する — `plugins` に rcd が含まれ関連 `plugin_errors` が空であることでロードを、`slash_commands`（または同等の構造化イベント）で `/rcd` 解決を確認する。
- **判定方法（#4）**: 拒否文言は advisory に留め、**副作用の差分で機械判定**する — 不正名（`../evil`・`a b`・`foo@bar` 等）の試行は **#3 の正当 `start` より前のサブケースで行う**か、各試行の直前に unit 一覧と `<root>` の状態を記録し、試行後に**変化していない**ことをアサートする（新規 unit が enable/start されず、対応する dir も作られない）。#3 で既に enable 済みの unit を巻き込まないようスコープする。
- **いつ**: `SKILL.md` の文面（手順・名前ルール・同梱ファイル参照）変更時／プラグイン梱包（`plugin.json`・`marketplace.json`・構成・skill 名・unit 位置）変更時／`claude` CLI のメジャー級更新時。

### 単位 `guards`（対話 TTY・full login・人判定）
破壊的 verb の保護。headless では出来ない対話確認。**当初は inference（setup-token）で対話を駆動する設計だったが、実測（2026-06-12, claude 2.1.175）で対話 TUI は setup-token では認証できず（headless `-p` のみ inference 可）、通常のログイン onboarding に入ることが判明したため full login に変更**。認証方式が変わっただけで、検証対象（typed-confirm / SELF 拒否）は認証と独立。

| # | 検証項目 | 経路 | 認証 | 判定 |
|---|---|---|---|---|
| 5 | typed-confirm（`destroy`/`restart-all` の確認入力） | 対話 TTY | full login | 人 |
| 6 | SELF 拒否（`stop`/`destroy` SELF の拒否、`restart-all` の SELF 後回し） | 対話 TTY | full login | 人 |

- **フィクスチャ（2 unit）**: skill の SELF 確認は `systemctl --user list-units 'claude-remote-control@*'`（`--all` 無し）で候補 unit の存在を確かめるため、対象 unit が **active・listed** である必要がある。inference の実 claude では `claude remote-control` が起動できず unit が不安定（flap/failed）になるので、**`guards` の対象 unit はスタブ `claude-bin`（`test/stub-claude`）で起動して確実に active・listed にする**（`init` 後に `~/.config/rcd/claude-bin` をスタブへ差し替え）。`/rcd` を叩く対話セッションのみ実 claude を `--plugin-dir` で使う。SELF 拒否と destroy の確認経路は別 unit が要るため2つ用意する:
  - **`rcdtest-self`**（active・スタブ／対話セッションに `RCD_INSTANCE=rcdtest-self`）: #6 の SELF 拒否（`/rcd stop|destroy rcdtest-self` が**確認入力の前に**拒否）と `restart-all` の SELF 後回しを確認。
  - **`rcdtest-victim`**（active・スタブ・非 SELF）: #5 の **destroy の typed-confirm 経路**を確認（SELF だと確認前に拒否され #5 を確認できない）。誤り/空の確認入力では `rcdtest-victim` が enabled・active のまま、**正確な確認入力でのみ** disable/stop されることをアサート。
- **skill 本体の SELF 確認コマンド（`--all` 無し）は変更しない**（テスト都合で本体設計を歪めない）。
- **いつ**: `SKILL.md` の確認手順・SELF 検出/自己保護ロジック変更時。

### 単位 `live`（アプリ＋リレー・full login・人判定）
スタブでは届かないライブ remote-control の実行時挙動。

| # | 検証項目 | 経路 | 認証 | 判定 |
|---|---|---|---|---|
| 8 | リレーが spawn する on-demand/worktree セッションへの `RCD_INSTANCE` 継承 | アプリ（リレー） | full | 人 |
| 9 | claude.ai/code のセッション表示名形式 `<host>-<name>-<auto>`（`-` 区切り） | アプリ＋UI | full | 人(UI) |

- 旧 #7「ライブ基底セッションが接続」は独立項目ではなく、本単位の**前提セットアップ**（full login → dir 信頼 → base 起動）として内包する。
- #8/#9 の確認自体は **`/rcd` を使わない**（on-demand セッション内で `echo "$RCD_INSTANCE"` と表示名の目視）。
- **いつ**: ベースライン確立時／unit の識別・命名・spawn 配線（`RCD_INSTANCE`/`--name`/session-name-prefix/`--spawn`）変更時／`claude`・claude.ai が remote-control の env 継承やセッション名描画を変えた疑いのあるとき。

## 5. 独立性の原則（必須要件）

**各単位はそれ単体で実行でき、他単位の結果・準備に依存しない。** 各単位が自前で「コンテナ起動 → 必要な `init`／enable／ログイン／信頼」までを行う。これにより「`skill` を先に走らせる」「teardown するな」といった単位間依存・順序制約を排除する（旧構成はこの依存で混乱した）。teardown は各単位の最後に閉じる。

## 6. 設計が従うべき確定事実（本検証で判明）

1. **`setup-token`（`CLAUDE_CODE_OAUTH_TOKEN`）は inference 専用かつ headless `-p` のみで有効**。`claude remote-control` を起動できず、さらに**対話 TUI は setup-token で認証できない**（実測 2026-06-12, claude 2.1.175。対話起動すると通常のログイン onboarding に入る）。よって inference で足りるのは `skill`（headless `-p`）のみで、`guards`（対話 TTY）と `live`（remote-control＋アプリ）は full `claude auth login` を要する。
2. **`CLAUDE_CODE_OAUTH_TOKEN` を systemd ユーザーマネージャ環境に残さない**こと。残すと `claude` がディスクの full login より env トークンを優先し、remote-control が拒否され続ける（`live` の前提では設定しない／必要なら `unset-environment`）。
3. **ワークスペース信頼**: systemd 起動の remote-control は信頼ダイアログを出せないため、**新規インスタンス dir は事前に信頼**しておく必要がある（その dir で一度対話 `claude` を起動して承認）。これは実利用の**初回 `/rcd start <name>` にも当てはまる**（→ §8 で扱い）。
4. **コンテナではプラグインを `--plugin-dir` でロード**（`~/.claude` へ install しない）。unit の ExecStart は `--plugin-dir` を渡さないため、**unit が起こす base/on-demand セッションには `/rcd` が無い**。帰結:
   - `guards` の `/rcd` 駆動は **`docker exec` 対話＋`--plugin-dir`** で行う（アプリ接続の制御インスタンス経由は**コンテナでは不可**）。
   - `live` のアプリ確認（#8/#9）は `/rcd` 非依存なので、プラグイン不在の on-demand セッションでも成立する。
5. **`skill` の headless 権限構成**（実証済み）: `--permission-mode acceptEdits` ＋ `--add-dir "$HOME"`（`~/.config` 書込）＋ `--add-dir "<plugin>"`（同梱 unit 読取）＋ カンマ区切り単一 `--allowedTools`、インスタンス root を `$HOME` 配下、プロンプトを先頭に置く。`--dangerously-skip-permissions` は不使用。
6. 同梱パスは `${CLAUDE_PLUGIN_ROOT}`（波括弧）必須。波括弧なしは置換されない（既に修正済み・`lint` が回帰ガード）。
7. **SELF 検出は `systemctl --user list-units`（`--all` 無し）で候補 unit を確認**するため、検証では対象 unit が active・listed であることが要件（→ §4 `guards` のスタブフィクスチャ）。enable のみ（inactive）や flap/failed では確実な根拠にならない。

## 7. 非目標

- 公開（remote/PR）。
- `live`（アプリ確認 #8/#9）の自動化 — リレー＋アプリ＋人の目視が本質的に必要。
- コンテナへのプラグインのグローバル install（`--plugin-dir` を用いる）。
- プラグイン実行時設計の変更（§8 の信頼注記を除く）。
- `skill` を CI に載せる配線（自動層は lint/logic で担保。`skill` は認証を要する半自動）。

## 8. 決定事項（Codex round1 を受けて確定）

1. **ワークスペース信頼**: §6-3 の (a) を採用 — `SKILL.md` の `start` 手順に「新規インスタンスは初回、その dir を一度対話 `claude` で開いて信頼してから起動する」注記を追加する（systemd 起動の remote-control はダイアログを出せないため）。`live` の前提であり、実利用の初回 `/rcd start` にも要る。
2. **`skill` は headless 自動のまま**据える（安い回帰ネット・実バグ捕捉実績）。対話へは寄せない。
3. **`guards` の SELF フィクスチャ**: §4 `guards` 記載のとおり、スタブ `claude-bin` で対象 unit を active・listed にして用意する（plan で手順化）。`RCD_INSTANCE` 付与のみでは不十分（§6-7）。

## 9. 出力物（plan が定義・実装するもの）

- `test/acceptance/` を **3単位が独立実行できる構成**に再生成（命名は `skill`/`guards`/`live`）。
- `docs/manual-acceptance.md` を A/B/C（`skill`/`guards`/`live`）の独立手順として再生成。
- `test/README.md`・`test/README.ja.md` の受け入れ節を新単位名・新モデルに更新。
- `skills/rcd/SKILL.md` の `start` に初回ワークスペース信頼の注記を追加（§8-1 で確定）。

## Self-Review（軸との突き合わせ）

- 「環境一様・経路＋認証で分割」（§3）→ 単位は経路（headless/対話/アプリ）と認証（inference/full）で一意に割り付く（§4）。
- 独立性（§5）→ 旧構成の単位間依存・teardown 順序の混乱を解消。
- 確定事実（§6）→ 各単位の前提・制約として反映済み（特に 1/2/3/4 が `guards`/`live` の経路と認証を決定）。
- `service` との重複回避（§2）→ 実行時 argv は再検証せず、`live` は app 固有の確認（#8/#9）に限定。
