# Worktree empty-repo → same-dir fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `claude-remote-control@.service` choose `--spawn worktree` only when the instance dir is a git top-level **with a resolvable HEAD commit** (else `--spawn same-dir`), so an empty `git init`-ed repo no longer breaks on-demand session spawning.

**Architecture:** The spawn mode is decided by an inline `if` in the unit's `ExecStart`. Add a `git rev-parse --verify -q HEAD` conjunct to the existing git-top-level test. Drive the change with `test/logic.sh` (deterministic, runs the unit's inline shell against a stub), keep `test/service/run-in-container.sh` (Docker) consistent, and update the user-facing wording.

**Tech Stack:** POSIX/bash shell, systemd user unit, git, the existing `test/stub-claude`, `test/logic.sh` / `test/service.sh` harness.

Spec: `docs/superpowers/specs/2026-06-12-rcd-worktree-empty-repo-fallback.md`.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `units/claude-remote-control@.service` | spawn-mode decision (ExecStart inline shell) | add HEAD check to the worktree predicate |
| `test/logic.sh` | deterministic argv assertions | committed-repo fixture for #1; new empty-repo→same-dir case |
| `test/service/run-in-container.sh` | Docker/systemd integration assertions | seed an initial commit for the `rcdtest-wt` worktree fixture |
| `skills/rcd/SKILL.md` | user-facing behavior prose | worktree requires a commit; mode fixed at start |
| `README.md` | public behavior prose | same wording correction |
| `docs/superpowers/specs/2026-06-11-rcd-naming-and-worktree-design.md` | historical design spec | align worktree-eligibility wording + embedded example |

---

## Task 1: Unit predicate + logic/service tests (TDD)

**Files:**
- Modify: `test/logic.sh` (cases #1 and a new empty-repo case)
- Modify: `units/claude-remote-control@.service` (ExecStart predicate)
- Modify: `test/service/run-in-container.sh` (worktree fixture)

- [ ] **Step 1: Update `test/logic.sh` case #1 to a committed repo, and add a failing empty-repo case**

In `test/logic.sh`, replace case #1 (the block starting `# 1) instance dir is itself a git repo top -> worktree`, currently lines ~37-42) with this — it seeds a commit so the repo is worktree-eligible, then adds a new empty-repo case that expects `same-dir`:

```bash
# 1) instance dir is a git repo top WITH a commit -> worktree
h="$(mktemp -d)"; setup "$h"; mkdir -p "$h/insroot/repo-top"; git -C "$h/insroot/repo-top" init -q
git -C "$h/insroot/repo-top" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
rc="$(launch repo-top "$h")"; a="$(argv "$h")"
[ "$rc" = 0 ] && echo "$a" | grep -q -- '--spawn worktree' && ok "git-top(committed) -> --spawn worktree" || ng "git-top -> worktree (rc=$rc argv=$a)"
echo "$a" | grep -q -- "--name $HOST-repo-top-base" && ok "git-top -> --name $HOST-repo-top-base" || ng "git-top naming ($a)"
echo "$a" | grep -q -- "--remote-control-session-name-prefix $HOST-repo-top" && ok "git-top -> prefix" || ng "git-top prefix ($a)"

# 1b) git top-level but NO commits (empty repo) -> same-dir (worktree add needs HEAD)
h="$(mktemp -d)"; setup "$h"; mkdir -p "$h/insroot/empty-repo"; git -C "$h/insroot/empty-repo" init -q
rc="$(launch empty-repo "$h")"; a="$(argv "$h")"
[ "$rc" = 0 ] && echo "$a" | grep -q -- '--spawn same-dir' && ok "empty-git -> --spawn same-dir" || ng "empty-git -> same-dir (rc=$rc argv=$a)"
```

- [ ] **Step 2: Run logic to confirm the new empty-repo case FAILS (RED)**

Run: `./test/logic.sh`
Expected: a `FAIL empty-git -> same-dir ...` line (the current unit still emits `--spawn worktree` for an empty repo), and overall `logic: ... 1 failed`. (Case #1 with a committed repo still passes — a committed repo is still a git top-level.)

- [ ] **Step 3: Add the HEAD check to the unit predicate**

In `units/claude-remote-control@.service`, in the single `ExecStart=` line, replace exactly:

```
if [ "$$(git rev-parse --show-toplevel 2>/dev/null)" = "$$(pwd -P)" ]; then spawn=worktree; else spawn=same-dir; fi
```

with:

```
if [ "$$(git rev-parse --show-toplevel 2>/dev/null)" = "$$(pwd -P)" ] && git rev-parse --verify -q HEAD >/dev/null 2>&1; then spawn=worktree; else spawn=same-dir; fi
```

(Only that substring changes; the rest of the `ExecStart` line is untouched. `$$` is systemd's literal-`$` escape; the added `git rev-parse` has no `$`, so no escaping is needed there.)

- [ ] **Step 3b: Update the unit comment above ExecStart to match the new predicate**

The comment block just above `ExecStart=` still describes the old rule. Replace these two lines (currently lines ~15-16):

```
# If that directory is itself a git repository top-level, on-demand sessions are
# isolated in git worktrees; otherwise they share the directory. No external
```

with:

```
# If that directory is a git repository top-level with a resolvable HEAD commit,
# on-demand sessions are isolated in git worktrees; otherwise (non-git, a parent
# repo's subdir, or a repo with no commits yet) they share the directory. No external
```

(Keep the following `# helper script. (...)` line unchanged.)

- [ ] **Step 4: Seed a commit for the service worktree fixture**

In `test/service/run-in-container.sh`, replace the case B block (currently lines ~65-68):

```sh
# B) instance directory that is itself a git top-level -> worktree
mkdir -p "$HOME/insroot/rcdtest-wt"
git -C "$HOME/insroot/rcdtest-wt" init -q
assert_inst rcdtest-wt worktree
```

with (adds an initial commit so the repo is worktree-eligible under the new predicate):

```sh
# B) instance directory that is a git top-level WITH a commit -> worktree
mkdir -p "$HOME/insroot/rcdtest-wt"
git -C "$HOME/insroot/rcdtest-wt" init -q
git -C "$HOME/insroot/rcdtest-wt" -c user.email=rcd@local -c user.name=rcd commit --allow-empty -q -m "rcd service fixture: worktree base"
assert_inst rcdtest-wt worktree
```

- [ ] **Step 5: Run the automated suite to confirm GREEN**

Run: `./test/run.sh`
Expected: ends with `ALL GREEN (lint + logic)`. Specifically logic now shows `PASS git-top(committed) -> --spawn worktree`, `PASS empty-git -> --spawn same-dir`, and the existing `PASS child-of-repo -> --spawn same-dir` / `PASS non-git -> --spawn same-dir`. lint stays green (the unit inline shell still parses; allowed-tools unaffected).

- [ ] **Step 6: (Docker env) Run the service integration test**

Run (only on a Docker-capable host — e.g. the WSL2 test box, not the production machine): `./test/service.sh`
Expected: `service(in-container): OK`, with `rcdtest-wt: --spawn worktree` (now worktree-eligible via the seeded commit) and `rcdtest-svc: --spawn same-dir`.
If no Docker is available in this environment, skip and note it; logic (Step 5) already covers the argv decision for both branches.

- [ ] **Step 7: Commit**

```bash
git add units/claude-remote-control@.service test/logic.sh test/service/run-in-container.sh
git commit -m "rcd: spawn worktree only when the repo has a HEAD commit (empty repo -> same-dir)"
```

---

## Task 2: User-facing wording (SKILL.md, README, design spec)

**Files:**
- Modify: `skills/rcd/SKILL.md` (worktree behavior line + `start` Report note)
- Modify: `README.md` (Naming and worktrees)
- Modify: `docs/superpowers/specs/2026-06-11-rcd-naming-and-worktree-design.md` (worktree judgment bullets + embedded example)

- [ ] **Step 1: Update `skills/rcd/SKILL.md`**

Replace this line (the bullet describing worktrees near the top, currently line 18):

```markdown
- If `<root>/<name>` is itself a git repository top-level, on-demand sessions are isolated in git worktrees; otherwise they share the directory.
```

with:

```markdown
- If `<root>/<name>` is a git repository top-level **with at least one commit**, on-demand sessions are isolated in git worktrees; otherwise (non-git, a subdirectory of a parent repo, or a repo with no commits yet) they share the directory (same-dir). The mode is decided when the unit starts, so to move a running instance from same-dir to worktree after its first commit, restart it (`/rcd stop <name>` then `/rcd start <name>`, or `/rcd restart-all`).
```

Then replace the `start` Report note (currently line 76):

```markdown
5. Report running/failed and the directory (`<root>/<name>`). Note whether it will use worktrees (the directory is a git repo top-level) or same-dir. If failed, suggest `/rcd logs <name>`.
```

with:

```markdown
5. Report running/failed and the directory (`<root>/<name>`). Note whether it will use worktrees (the directory is a git repo top-level **with a commit**) or same-dir. If failed, suggest `/rcd logs <name>`.
```

- [ ] **Step 2: Update `README.md`**

Replace the worktrees bullet (the block under `## Naming and worktrees`, currently lines ~74-77):

```markdown
- If `<root>/<name>` is **itself a git repository top-level**, on-demand sessions
  are isolated in their own **git worktrees**. Empty or non-git directories are
  not forced into worktree mode — `git init` / `git clone` inside the directory to
  enable it.
```

with:

```markdown
- If `<root>/<name>` is **a git repository top-level with at least one commit**,
  on-demand sessions are isolated in their own **git worktrees**. Non-git
  directories — or a freshly `git init`-ed repo with no commits yet — use same-dir.
  Use `git clone`, or `git init` plus an initial commit, to enable worktree mode.
  The mode is fixed when the instance starts; restart it after the first commit to
  switch.
```

- [ ] **Step 3: Update the 2026-06-11 design spec**

In `docs/superpowers/specs/2026-06-11-rcd-naming-and-worktree-design.md`, under `### worktree の自動判定`, replace these three bullets (currently lines ~38-40):

```markdown
- `<root>/<name>` が **それ自身 git リポジトリの最上位**（`git -C <dir> rev-parse --show-toplevel` == `<dir>`）の時のみ `--spawn worktree`。
- 空ディレクトリや非 git、あるいは単に親リポジトリの作業ツリー内にあるだけの場合は **`--spawn same-dir`**（親リポジトリを巻き込まない）。
- worktree 隔離したいプロジェクトは、そのディレクトリ内で `git init` / `git clone` する。
```

with:

```markdown
- `<root>/<name>` が **それ自身 git リポジトリの最上位**（`git -C <dir> rev-parse --show-toplevel` == `<dir>`）**かつ HEAD コミットを持つ**時のみ `--spawn worktree`（`git worktree add` は HEAD コミット必須のため）。
- 空ディレクトリ・非 git・**コミット0の空リポ**、あるいは単に親リポジトリの作業ツリー内にあるだけの場合は **`--spawn same-dir`**（親リポジトリを巻き込まない）。
- worktree 隔離したいプロジェクトは、そのディレクトリ内で `git clone` する、または `git init` ＋初回コミットする。spawn mode はサービス起動時に評価されるため、初回コミット後はサービスを再起動して切り替える。
```

Then update the embedded example line (currently line ~59):

```
if [ "$(git rev-parse --show-toplevel 2>/dev/null)" = "$(pwd -P)" ]; then spawn=worktree; else spawn=same-dir; fi
```

to:

```
if [ "$(git rev-parse --show-toplevel 2>/dev/null)" = "$(pwd -P)" ] && git rev-parse --verify -q HEAD >/dev/null 2>&1; then spawn=worktree; else spawn=same-dir; fi
```

- [ ] **Step 2.5: Verify lint stays green**

Run: `./test/run.sh`
Expected: `ALL GREEN (lint + logic)` (prose-only changes; no impact on lint checks).

- [ ] **Step 4: Commit**

```bash
git add skills/rcd/SKILL.md README.md docs/superpowers/specs/2026-06-11-rcd-naming-and-worktree-design.md
git commit -m "rcd: document that worktree mode needs a committed repo (else same-dir)"
```

---

## Self-Review (against the spec)

- spec §4 設計（HEAD 必須の判定）→ Task 1 Step 3（unit predicate）。
- spec §5 出力物: unit → T1S3、logic.sh → T1S1、service test → T1S4、SKILL.md → T2S1、README.md → T2S2、旧 spec → T2S3。全て被覆。
- spec §6.4（再起動が必要）→ T2S1 / T2S2 の文言に反映。
- spec §7 検証: logic（T1S5）＋ service（T1S6, Docker）。
- Placeholder スキャン: 各ステップに実コード／実コマンド／期待出力あり。TODO/TBD 無し。
- 型/名称整合: `git rev-parse --verify -q HEAD` の述語、`empty-repo`/`repo-top`/`rcdtest-wt` フィクスチャ名、commit メッセージは全タスクで一貫。
