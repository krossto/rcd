# RCD 実装・受け入れ検証プラン

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** rcd プラグインの新設計（instances directory ＋ 自己完結 unit ＋ `/rcd init`/`start` ＋ repo 最上位限定 worktree ＋ SELF 検出）を、実機で end-to-end に検証する。

**Architecture:** プラグインは静的 unit `units/claude-remote-control@.service` を同梱。`/rcd init` が claude 絶対パスと root を `~/.config/rcd/` に記録し unit を `~/.config/systemd/user/` へインストール。unit は `Environment=RCD_INSTANCE=%i` を設定し、root/claude-bin を読んで `<root>/<name>` へ cd、git 最上位なら `--spawn worktree`。

**Tech Stack:** POSIX sh, systemd user units, claude CLI (`remote-control`)。

## 検証用プレースホルダ / 規約

| | 意味 |
|---|---|
| `<hostname>` | `hostname` の出力（systemd `%H`） |
| `TESTROOT` | 検証専用の使い捨て root（`mktemp -d`） |
| `BAK` | 実ユーザー設定の退避先 `~/.config/rcd.testbak` |

> **検証は実ユーザーの `~/.config/rcd/*` と installed unit を一時的に書き換える。** Task 0 で必ず退避し、最終 Task で復元する（trap は Bash 呼び出しを跨がないため、退避先は固定パスにして明示復元する）。インスタンス名は使い捨ての `rcdtest-*`。SELF と同名は使わない。

---

## Task 0: 実設定の退避と Red ベースライン（F3）

- [ ] **Step 1: 既存設定とユニットを退避（冪等・既存退避を保護）**

Run:
```bash
B=~/.config/rcd.testbak
[ -e "$B" ] && { echo "ABORT: $B already exists; resolve leftover test state first"; exit 1; }
mkdir -p "$B"
for f in root claude-bin; do [ -f ~/.config/rcd/$f ] && cp -a ~/.config/rcd/$f "$B/$f"; done
if [ -f ~/.config/systemd/user/claude-remote-control@.service ]; then
  cp -a ~/.config/systemd/user/claude-remote-control@.service "$B/unit"
else
  : > "$B/no-original-unit"   # マーカー: 元々 unit が無かった → Task 7 で test-installed unit を削除
fi
ls -1 "$B"; echo BACKED_UP
```
Expected: `BACKED_UP`。既に `$B` があれば中断（前回検証の残骸を先に片付ける）。

- [ ] **Step 2: 同梱物の存在と CLI フラグ**

Run: `test -f units/claude-remote-control@.service && grep -q 'RCD_INSTANCE=%i' units/claude-remote-control@.service && claude remote-control --help 2>&1 | grep -q -- '--remote-control-session-name-prefix' && echo OK`
Expected: `OK`

> 未初期化ガードの検証は **unit インストール後でないと成立しない**（Red を unit 直起動で書くと、unit 未導入環境では起動自体が無くガードを確認できない）。よって未初期化ガードは Task 1（init）でユニット導入後の Task 5 Step 3 で、実 `/rcd start` 経路として確認する。

---

## Task 1: `/rcd init` の検証（実コマンド経路, F1）

- [ ] **Step 1: 検証 root を作って `/rcd init` を実行**

そのディレクトリで `/rcd init`（スキル）を実行する:
```bash
TESTROOT=$(mktemp -d); echo "$TESTROOT" > /tmp/rcdtest-root
cd "$TESTROOT"
```
→ ここで `/rcd init` を呼ぶ。

- [ ] **Step 2: Green（記録とインストール）**

Run:
```bash
TESTROOT=$(cat /tmp/rcdtest-root)
echo "root: $(cat ~/.config/rcd/root)  [期待 $TESTROOT]"
echo "claude-bin: $(cat ~/.config/rcd/claude-bin)  [期待 $(command -v claude)]"
test -f ~/.config/systemd/user/claude-remote-control@.service && echo "unit installed"
systemctl --user show -p ExecStart --value claude-remote-control@rcdtest-plain.service | grep -q 'remote-control-session-name-prefix' && echo "specifiers resolve"
```
Expected: root=`$TESTROOT`、claude-bin=claude の絶対パス、`unit installed`、`specifiers resolve`。

---

## Task 2: 非 git → same-dir

- [ ] **Step 1: `/rcd start rcdtest-plain`（空ディレクトリ）**

`/rcd start rcdtest-plain` を実行（`<TESTROOT>/rcdtest-plain` が作られ起動）。

- [ ] **Step 2: 実プロセス引数で確認**

Run:
```bash
pid=$(systemctl --user show -p MainPID --value claude-remote-control@rcdtest-plain.service)
tr '\0' ' ' < /proc/$pid/cmdline; echo
```
Expected: `--name <hostname>-rcdtest-plain-base` / `--remote-control-session-name-prefix <hostname>-rcdtest-plain` / **`--spawn same-dir`**

- [ ] **Step 3: 後片付け**

Run: `systemctl --user disable --now claude-remote-control@rcdtest-plain.service; echo CLEANED`

---

## Task 3: 親リポジトリ配下 → same-dir（F2・重要）

`<root>/<name>` が「親リポジトリの作業ツリー内にあるだけ」で**それ自身は最上位でない**場合に worktree へ暴発しないこと。

- [ ] **Step 1: root 自体を git リポジトリにして子インスタンスを起動**

Run:
```bash
TESTROOT=$(cat /tmp/rcdtest-root); git -C "$TESTROOT" init -q
mkdir -p "$TESTROOT/rcdtest-child"
systemctl --user enable --now claude-remote-control@rcdtest-child.service && echo STARTED
```
Expected: `STARTED`（`rcdtest-child` は親 `TESTROOT` リポの配下だが最上位ではない）

- [ ] **Step 2: same-dir であること**

Run:
```bash
pid=$(systemctl --user show -p MainPID --value claude-remote-control@rcdtest-child.service)
tr '\0' ' ' < /proc/$pid/cmdline; echo
```
Expected: **`--spawn same-dir`**（親リポを巻き込まない）

- [ ] **Step 3: 後片付け**

Run: `systemctl --user disable --now claude-remote-control@rcdtest-child.service; rm -rf "$(cat /tmp/rcdtest-root)/.git" "$(cat /tmp/rcdtest-root)/rcdtest-child"; echo CLEANED`

---

## Task 4: ディレクトリ自身が git 最上位 → worktree

- [ ] **Step 1: `<root>/<name>` 自体を git 最上位にして起動**

Run:
```bash
TESTROOT=$(cat /tmp/rcdtest-root); d="$TESTROOT/rcdtest-repo"; mkdir -p "$d"; git -C "$d" init -q
systemctl --user enable --now claude-remote-control@rcdtest-repo.service && echo STARTED
```

- [ ] **Step 2: worktree であること**

Run:
```bash
pid=$(systemctl --user show -p MainPID --value claude-remote-control@rcdtest-repo.service)
tr '\0' ' ' < /proc/$pid/cmdline; echo
```
Expected: **`--spawn worktree`** ／ `--name <hostname>-rcdtest-repo-base`

- [ ] **Step 3: オンデマンド worktree セッションで RCD_INSTANCE 継承と session 名を確認（手動・spec F2/F5）**

このインスタンスでオンデマンドセッションを1つ作り（worktree モード）、その**セッション内**で:
- `echo "$RCD_INSTANCE"` が `rcdtest-repo` を返す（＝worktree/on-demand に env が継承され、SELF 検出が cwd 非依存で成立する根拠）。**継承しない場合**は spec の SELF 検出フォールバック設計（worktree メタデータからの逆引き）へ切替が必要 = defect。
- claude.ai/code 上の表示名が `<hostname>-rcdtest-repo-<自動名>`（`-` 区切り）であること（spec の確定仕様）。区切りが入らなければ defect として unit/spec を修正。

- [ ] **Step 4: 後片付け**

Run: `systemctl --user disable --now claude-remote-control@rcdtest-repo.service; rm -rf "$(cat /tmp/rcdtest-root)/rcdtest-repo"; echo CLEANED`

---

## Task 5: 冪等性と名前検証

- [ ] **Step 1: start 二度実行で冪等**

`/rcd start rcdtest-plain` を2回 → 2回目も成功し `active`。後片付けで disable。

- [ ] **Step 2: 不正な名前は拒否（F1）**

`/rcd start ../evil` / `/rcd start a b` / `/rcd start foo@bar` を実行 → いずれも**ルール提示で拒否**され systemctl は実行されないこと。

- [ ] **Step 3: 未初期化ガード（実 `/rcd start` 経路）**

unit 導入済み・`root` を一時退避した状態で `/rcd start rcdtest-plain` を実行:
```bash
mv ~/.config/rcd/root ~/.config/rcd/root.tmp
# → ここで /rcd start rcdtest-plain を実行
```
Expected: スキルが「run `/rcd init` first」で停止し、`systemctl` を**実行しない**こと。確認後 `mv ~/.config/rcd/root.tmp ~/.config/rcd/root` で復帰。

---

## Task 6: SELF 安全性（具体化, F4／実名衝突回避）

> 実インスタンス名 `hq` は使わない（README/spec の慣習 `hq` と衝突し、利用者の実 `hq` を壊しうる）。テスト専用の `rcdtest-self` を起動し、その session 内（`$RCD_INSTANCE=rcdtest-self`）から実行する。

- [ ] **Step 1: SELF 検出が env 由来か**

`rcdtest-self` session 内で `echo "$RCD_INSTANCE"` が `rcdtest-self` を返すこと（cwd に依存しない根拠）。

- [ ] **Step 2: stop/destroy SELF の拒否**

`/rcd stop rcdtest-self` および `/rcd destroy rcdtest-self` を実行。
Expected: いずれも拒否＋「別インスタンスから実行せよ」。直後に `systemctl --user is-active claude-remote-control@rcdtest-self.service` が `active`。

- [ ] **Step 3: restart-all の SELF 後回し（他あり）**

`rcdtest-self` と別テストインスタンス（例 `rcdtest-plain`）を起動した状態で `/rcd restart-all`（確認文字列 `restart-all`）。
Expected: 別インスタンスは即時 restart され `active`。SELF は `systemd-run --user --on-active=5 ... claude-remote-control@rcdtest-self.service` で予約され ~5s 後ドロップ→自動復帰。

- [ ] **Step 4: restart-all の SELF 単独（他なし, spec F4）**

`rcdtest-self` のみが稼働の状態で `/rcd restart-all`。
Expected: 「他に対象なし」と報告し `systemctl restart` を呼ばず、SELF の detached restart のみを予約すること。

---

## Task 7: 後片付け（実設定の復元, F3）

- [ ] **Step 1: テストインスタンスと TESTROOT を削除**

Run: `for n in rcdtest-plain rcdtest-child rcdtest-repo rcdtest-self; do systemctl --user disable --now claude-remote-control@$n.service 2>/dev/null; done; rm -rf "$(cat /tmp/rcdtest-root)"; echo CLEANED`

- [ ] **Step 2: 退避した実設定を復元（元々無かったものは削除）**

Run:
```bash
B=~/.config/rcd.testbak
[ -f "$B/root" ] && cp -a "$B/root" ~/.config/rcd/root || rm -f ~/.config/rcd/root
[ -f "$B/claude-bin" ] && cp -a "$B/claude-bin" ~/.config/rcd/claude-bin || rm -f ~/.config/rcd/claude-bin
if [ -f "$B/unit" ]; then
  cp -a "$B/unit" ~/.config/systemd/user/claude-remote-control@.service
elif [ -f "$B/no-original-unit" ]; then
  rm -f ~/.config/systemd/user/claude-remote-control@.service   # 元々無かった test-installed unit を削除
fi
systemctl --user daemon-reload
rm -rf "$B" /tmp/rcdtest-root; echo RESTORED
```
Expected: `RESTORED`（検証前の状態に戻る。元々 unit/root が無ければ削除されて無い状態に戻る）

---

## Self-Review（spec 突き合わせ）

- spec「instances directory / `/rcd init`」→ Task 1（実 init 経路で root・claude-bin・unit を検証）。
- spec「命名スキーム」→ Task 2/4 の `/proc/cmdline` + Task 4 Step3（区切り実確認, F5）。
- spec「worktree（repo 最上位限定）」→ Task 2（空=same-dir）/ Task 3（親リポ配下=same-dir, F2）/ Task 4（最上位=worktree）。
- spec「name 検証」→ Task 5 Step2。
- spec「SELF 検出（RCD_INSTANCE 優先）」→ Task 6（拒否・env 由来確認）。
- spec「restart-all 手順」→ Task 6 Step2。
- spec「自己完結 unit / 未初期化ガード」→ Task 0 Step3。
- 検証環境保護 → Task 0（退避）/ Task 7（復元）。
