# RCD 設計: instances directory・命名スキーム・worktree 自動判定

- 日付: 2026-06-11
- 対象: rcd プラグイン（Claude Code リモートコントロールのライフサイクル管理）
- ステータス: 設計合意済み

> 公開配布前提。環境依存値はプレースホルダ（`<hostname>`, `<name>`, `<root>` 等）で記す。

## 背景

Claude Code リモートコントロールは、1 つのディレクトリで常駐し複数セッションを受け付ける（`--capacity` 既定 32）。rcd は、これを**名前ごとの systemd ユーザーサービス** `claude-remote-control@<name>.service` として起動・停止・撤去するスラッシュコマンド `/rcd` を提供する。

不特定多数の利用者に配布するため、以下を満たす:

- 利用者の環境（ユーザー名・ホスト名・ディレクトリ構成・claude のインストール先）に依存しない。
- 初回セットアップが最小手順。手書きの unit 編集を要しない。

## 確定した設計

### instances directory（root）

- 各インスタンスは `<root>/<name>` に置かれる。`<root>` は固定の `~/workspace` ではなく、**利用者が `/rcd init` を実行したディレクトリ**。
- `init` は root の絶対パスを `~/.config/rcd/root` に記録する。これが root の**単一の出所**。
- `/rcd start <name>` は `<root>/<name>` が無ければ作成、あれば再利用し、その中で大元の Claude Code を起動する。

### 命名スキーム

| 種別 | オプション | 結果 |
|---|---|---|
| 大元（事前作成）セッション | `--name %H-%i-base` | `<hostname>-<name>-base` |
| オンデマンド各セッション | `--remote-control-session-name-prefix %H-%i` | `<hostname>-<name>-<自動名>` |

- 大元の固定 token は **`base`**。一覧上で大元が一目で判別できる。
- オンデマンド名の区切り：prefix には `%H-%i`（末尾 `-` なし）を渡す。CLI は prefix と `<自動名>` の間に `-` を挿入する（既定の prefix=hostname が `<hostname>-<自動名>` を生むのと同じ挙動）ため、結果は `<hostname>-<name>-<自動名>` で確定とする。受け入れ検証（plan Task 4 Step 3）で実 session 名により確認する（不一致なら defect として修正）。

### worktree の自動判定

- `<root>/<name>` が **それ自身 git リポジトリの最上位**（`git -C <dir> rev-parse --show-toplevel` == `<dir>`）**かつ HEAD コミットを持つ**時のみ `--spawn worktree`（`git worktree add` は HEAD コミット必須のため）。
- 空ディレクトリ・非 git・**コミット0の空リポ**、あるいは単に親リポジトリの作業ツリー内にあるだけの場合は **`--spawn same-dir`**（親リポジトリを巻き込まない）。
- worktree 隔離したいプロジェクトは、そのディレクトリ内で `git clone` する、または `git init` ＋初回コミットする。spawn mode はサービス起動時に評価されるため、初回コミット後はサービスを再起動して切り替える。

### 自己完結 unit（同梱・案A）

systemd は固定の探索ディレクトリ（`~/.config/systemd/user/` 等）からしか unit を読まず、プラグインの設置パスはバージョン固定で更新ごとに変わる。よって:

- プラグインは**環境非依存の静的 unit** を `units/claude-remote-control@.service` として同梱する。
- git 判定ロジックは **unit の `ExecStart` にインライン**で持つ（外部ヘルパースクリプト・`~/.local/bin` へのコピー・プラグインパス参照を排除）。
- unit は root を `~/.config/rcd/root`、claude の絶対パスを `~/.config/rcd/claude-bin` から読み、`<root>/%i` へ `cd` して claude を起動する。`%h`/`%i`/`%H` は systemd 指定子。
- **claude のインストール先非依存**のため、PATH を当て推量せず `init` が記録した絶対パスを `exec` する（PATH には `git` とシェルがあれば足りる）。`init` は `command -v claude` の結果が**絶対パスかつ `test -x` を満たす**場合のみ `claude-bin` に保存し、unit は `claude-bin` が無い/空/実行不可なら `claude` へフォールバックせず**明確に失敗**する（`rcd: claude path missing; run /rcd init`）。
- **インスタンス識別子の伝搬**：unit は `Environment=RCD_INSTANCE=%i` を設定する。これは大元セッションと**その worktree/on-demand 子セッション**に継承され、SELF 検出（後述）が作業ディレクトリに依存せず成立する根拠となる。
- `init` がこの unit を `~/.config/systemd/user/` へ**コピー**してインストールする（systemd の作法。プラグイン/claude 更新後は `init` 再実行で更新）。

unit の中核（`ExecStart`、抜粋）:

```sh
root=$(cat "$HOME/.config/rcd/root"); [ -n "$root" ] || exit 1
bin=$(cat "$HOME/.config/rcd/claude-bin"); [ -x "$bin" ] || { echo "rcd: claude path missing; run /rcd init" >&2; exit 1; }
dir="$root/<name>"; mkdir -p "$dir"; cd "$dir" || exit 1
if [ "$(git rev-parse --show-toplevel 2>/dev/null)" = "$(pwd -P)" ] && git rev-parse --verify -q HEAD >/dev/null 2>&1; then spawn=worktree; else spawn=same-dir; fi
exec "$bin" remote-control \
  --name "<hostname>-<name>-base" \
  --remote-control-session-name-prefix "<hostname>-<name>" \
  --permission-mode acceptEdits --spawn "$spawn"
```

### Instance name（`<name>`）の検証

`<name>` はディレクトリ名・systemd インスタンス名・session 名プレフィックスに直結するため、`init`/`start`/`stop`/`destroy`/`logs` は systemctl 実行前に検証する:

- 許可: `^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$`
- 拒否: `.` / `..` / 先頭ドット / `.service` で終わる名 / `/`・空白・`@`・`%`
- 非適合は拒否しルールを提示（エスケープや自動補正はしない）。

### `/rcd init`

1. claude を特定：`command -v claude`。無ければ停止し PATH に置くよう案内。絶対パスを `~/.config/rcd/claude-bin` に記録（unit はこれを `exec`）。
2. 実行ディレクトリを root として `~/.config/rcd/root` に記録（既存と異なる場合は `change-root` のタイプ確認）。
3. 同梱 unit を `~/.config/systemd/user/` にコピー。
4. `systemctl --user daemon-reload`。
5. 任意で linger の案内（ログアウト後も常駐させたい場合）。プラグイン/claude 更新後は `init` 再実行で unit と claude パスを更新。

### 制御インスタンス `hq`（任意）

複数インスタンスを束ねる「拠点」を1つ持つと便利、という慣習。`hq`（headquarters）はその例で、予約名ではない。

## 安全性

### SELF 検出

- `/rcd` をインスタンス内（例 `hq`）から実行しても、自分自身を `stop`/`destroy` して接続を切る事故を防ぐ。
- 検出は **`$RCD_INSTANCE`（unit が設定、子セッションに継承）を一次根拠**とし、未設定時のみ `basename "$PWD"` にフォールバック。worktree/on-demand セッションでは cwd が `<name>` と一致しないため、env を優先する（cwd 単独では破綻する）。
- **継承の検証は必須**：git 最上位インスタンスで on-demand worktree セッションを作り、その中で `echo "$RCD_INSTANCE"` が元インスタンス名を返すことを受け入れ検証で確認する（plan Task 4 / Task 6）。万一 CLI が env を継承しない場合のフォールバックは、worktree のメタデータ（`git -C "$PWD" rev-parse --git-common-dir` から元チェックアウトを逆引き）→ その basename、と定める。

### `restart-all`（SELF を含む再起動の手順）

claude CLI 更新後などに全インスタンスを再起動する。SELF を同期 restart すると検証前に session が落ちるため:

1. タイプ確認 `restart-all`。
2. **SELF 以外**を一括 restart し、`active` を検証（session 生存中に報告）。**SELF 以外が空（SELF が唯一の unit）なら restart 呼び出しを skip** し、その旨を報告して 3 へ。
3. **SELF は最後に detached**：`systemd-run --user --on-active=5 --timer-property=AccuracySec=1s systemctl --user restart claude-remote-control@<SELF>.service`。~5s 後にドロップ→自動復帰。
4. SELF==none（ローカル非リモート）なら全体を直接 restart。

skill の `allowed-tools` に `Bash(systemd-run --user *)` が必要。

### 確認

- `destroy` / `restart-all` はタイプ確認必須。

## 動作環境 / 依存

- Linux（systemd ユーザーサービス）
- `claude` CLI（`claude remote-control` 対応版）
- macOS / Windows 非対応（systemd 依存）

## スコープ外

- `--capacity` / `--permission-mode`(acceptEdits) の変更
- worktree の保存先・命名などアプリ内部挙動のカスタマイズ
- macOS/Windows 等 systemd 以外のバックエンド
