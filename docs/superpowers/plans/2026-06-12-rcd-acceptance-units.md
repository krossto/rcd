# RCD 受け入れ単位（skill / guards / live）実装プラン

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** spec `docs/superpowers/specs/2026-06-12-rcd-acceptance-units-design.md` に従い、実 Claude を要する受け入れ検証を独立実行できる3単位 `skill`/`guards`/`live` として `test/acceptance/` に再構築し、ドキュメントと SKILL.md 注記を更新する。

**Architecture:** 全単位は「専用 HOME を持つ使い捨て privileged systemd Docker コンテナ内の実 Claude Code」を共有環境とし、差は経路（headless `-p` / 対話TTY / アプリ）と認証（inference / full login）だけ。共有の `Dockerfile`＋`lib.sh` を土台に、各単位スクリプトが**自前でコンテナ起動〜teardown まで完結**（単位間依存なし）。`skill` は機械判定で自動、`guards`/`live` はセットアップ＋対話/アプリの人手チェック。

**Tech Stack:** POSIX/bash シェル、Docker、systemd user units、`claude` CLI（`-p`/`--output-format stream-json`/`--plugin-dir`/`auth login`）、`jq`、`test/stub-claude`。

---

## ファイル構成

| ファイル | 役割 |
|---|---|
| `test/acceptance/Dockerfile` | 実 claude＋systemd の共有イメージ（全単位共通） |
| `test/acceptance/lib.sh` | 共有ヘルパ（イメージ build、コンテナ boot/待機/teardown）。各単位が source |
| `test/acceptance/skill.sh` | 単位 `skill`（headless・inference・機械判定） |
| `test/acceptance/guards.sh` | 単位 `guards`（対話・inference・人）。stub フィクスチャ準備＋対話起動＋チェックリスト |
| `test/acceptance/live.sh` | 単位 `live`（アプリ・full login・人）。login＋trust＋base 起動＋アプリ手順 |
| `test/acceptance/README.md` | 手動専用・3単位の入口（短い） |
| `docs/manual-acceptance.md` | 3単位の独立手順（再生成） |
| `test/README.md` / `test/README.ja.md` | 受け入れ節を新単位名・新モデルへ更新 |
| `skills/rcd/SKILL.md` | `start` に初回ワークスペース信頼の注記を追加 |

`test/stub-claude`（既存）を `guards` のフィクスチャ用 claude-bin として再利用（新規スタブは作らない）。`test/run.sh`・`lint.sh`・`logic.sh`・`service.sh` は変更しない。

---

## Task 1: 共有イメージ Dockerfile

**Files:**
- Create: `test/acceptance/Dockerfile`

- [ ] **Step 1: Dockerfile を作成**

```dockerfile
# Real-claude + systemd image shared by all acceptance units (skill/guards/live).
# MANUAL acceptance only — not used by test/run.sh or CI. Boots systemd as PID 1
# (privileged container) and ships a real claude CLI so a real Claude Code runs
# in the container. The plugin under test is mounted read-only at /mnt/rcd.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus dbus-user-session git jq ca-certificates curl \
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g @anthropic-ai/claude-code \
 && apt-get purge -y curl && apt-get autoremove -y \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && find /etc/systemd/system /lib/systemd/system/*.target.wants \
      -name '*.wants' -prune -o -type l -print -delete 2>/dev/null; true
# ubuntu:24.04 ships a default uid-1000 user; drop it so rcd can take uid 1000.
RUN userdel -r ubuntu 2>/dev/null; useradd --create-home --uid 1000 --shell /bin/bash rcd
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
```

- [ ] **Step 2: 構文確認**

Run: `docker build -q -f test/acceptance/Dockerfile -t rcd-acceptance test/acceptance >/dev/null && echo OK`
Expected: `OK`（初回は Node＋claude 取得で数分）。

- [ ] **Step 3: Commit**

```bash
git add test/acceptance/Dockerfile
git commit -m "rcd(acceptance): shared real-claude systemd image"
```

---

## Task 2: 共有ヘルパ lib.sh

**Files:**
- Create: `test/acceptance/lib.sh`

- [ ] **Step 1: lib.sh を作成**

```bash
#!/usr/bin/env bash
# Shared helpers for the acceptance units. Each unit is self-contained: it builds
# the image, boots its OWN container, and tears it down — no cross-unit state.
set -uo pipefail
ACC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$ACC_DIR/../.." && pwd)"
IMG=rcd-acceptance

rcd_need_docker(){ command -v docker >/dev/null 2>&1 || { echo "acceptance: need docker"; exit 1; }; }

rcd_build(){
  echo "== building image (first run pulls Node + claude) =="
  docker build -q -f "$ACC_DIR/Dockerfile" -t "$IMG" "$ACC_DIR" >/dev/null \
    || { echo "acceptance: image build failed"; exit 1; }
}

# rcd_boot <container-name> [extra docker run args...]
rcd_boot(){
  local c="$1"; shift
  docker rm -f "$c" >/dev/null 2>&1 || true
  echo "== booting container $c (hostname rcdtest-host) =="
  docker run -d --name "$c" --hostname rcdtest-host \
    --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock -v "$REPO":/mnt/rcd:ro "$@" \
    "$IMG" >/dev/null || { echo "acceptance: container failed to start"; exit 1; }
  local i
  for i in $(seq 1 60); do
    case "$(docker exec "$c" systemctl is-system-running 2>/dev/null || true)" in
      running|degraded) break;; esac
    sleep 0.5
  done
  case "$(docker exec "$c" systemctl is-system-running 2>/dev/null || true)" in
    running|degraded) ;;
    *) echo "acceptance: systemd did not boot in $c"
       docker exec "$c" systemctl --no-pager status 2>&1 | sed 's/^/  /' | head -20
       exit 1;;
  esac
  docker exec "$c" loginctl enable-linger rcd >/dev/null 2>&1 || true
  for i in $(seq 1 60); do
    docker exec "$c" test -S /run/user/1000/bus 2>/dev/null && break
    sleep 0.5
  done
  docker exec "$c" test -S /run/user/1000/bus 2>/dev/null \
    || { echo "acceptance: user bus not up in $c"
         docker exec "$c" loginctl user-status rcd 2>&1 | sed 's/^/  /' | head -20
         exit 1; }
}

rcd_teardown(){ docker rm -f "$1" >/dev/null 2>&1 || true; }
```

- [ ] **Step 2: 構文確認**

Run: `bash -n test/acceptance/lib.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add test/acceptance/lib.sh
git commit -m "rcd(acceptance): shared boot/teardown helpers"
```

---

## Task 3: 単位 `skill`（headless・機械判定）

**Files:**
- Create: `test/acceptance/skill.sh`

検証（spec §4 skill）: #1 ロード/`/rcd` 解決を `system/init` の構造化シグナルで、#2 init、#3 start×3（dir 作成＋enable）、#4 不正名を副作用差分で。

- [ ] **Step 1: skill.sh を作成**

```bash
#!/usr/bin/env bash
# Unit `skill` — headless, setup-token, machine-judged (spec §4 skill).
# MANUAL acceptance only; never run by CI. Requires docker + CLAUDE_CODE_OAUTH_TOKEN.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
C=rcd-acc-skill
TOK=CLAUDE_CODE_OAUTH_TOKEN
PLUGIN=/mnt/rcd
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  PASS %s\n' "$1"; }
ng(){ fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

rcd_need_docker
[ -n "${!TOK:-}" ] || { cat <<EOF
$TOK is not set. On a machine signed in to Claude (subscription):
    claude setup-token
    export $TOK=<token>
    $0
EOF
exit 1; }

[ "${1:-}" = "--teardown" ] && { rcd_teardown "$C"; echo "skill: container removed"; exit 0; }

rcd_build
rcd_boot "$C"
trap 'rcd_teardown "$C"' EXIT

# headless /rcd helper. Permissions mirror a consenting user (spec §6-5):
ALLOW='Bash(systemctl --user *),Bash(systemd-run --user *),Bash(journalctl --user *),Bash(loginctl enable-linger *),Bash(mkdir *),Bash(cp *),Bash(cat *),Bash(test *),Bash(basename *),Bash(command -v *),Bash(pwd *),Bash(pwd),Bash(printf *)'
ex(){ docker exec -u rcd -e "$TOK=${!TOK}" "$C" "$@"; }
rcd(){ # headless `/rcd <args>` in dir $1, remaining args = verb...
  local dir="$1"; shift
  ex bash -lc "export XDG_RUNTIME_DIR=/run/user/1000; cd '$dir'; \
    claude -p \"/rcd $*\" --plugin-dir $PLUGIN --permission-mode acceptEdits \
    --add-dir \"\$HOME\" --add-dir $PLUGIN --allowedTools '$ALLOW'" 2>&1
}

# #1 load + /rcd resolution via system/init (spec §4 skill signal, §6 / research memo)
init_json="$(ex bash -lc "claude -p '/rcd' --plugin-dir $PLUGIN --bare --output-format stream-json --verbose 2>/dev/null | head -1")"
echo "$init_json" | jq -e '(.plugins // [] | map(.name) | index("rcd")) and ((.plugin_errors // []) | length == 0)' >/dev/null 2>&1 \
  && ok "plugin 'rcd' loaded (system/init.plugins, no plugin_errors)" \
  || { ng "plugin not loaded per system/init"; echo "$init_json" | head -c 400; }
echo "$init_json" | jq -e '(.slash_commands // []) | any(. == "rcd" or (endswith(":rcd")))' >/dev/null 2>&1 \
  && ok "/rcd present in system/init.slash_commands" \
  || ng "/rcd not in slash_commands"

# #2 init in a root UNDER \$HOME (so it shares the --add-dir \$HOME workspace)
ex bash -lc 'rm -rf ~/rcdtest-root; mkdir -p ~/rcdtest-root' >/dev/null
rcd '/home/rcd/rcdtest-root' init >/tmp/skill-init.log 2>&1 || true
[ "$(ex bash -lc 'cat ~/.config/rcd/root 2>/dev/null')" = /home/rcd/rcdtest-root ] \
  && ok "init recorded root" || ng "init root ($(ex bash -lc 'cat ~/.config/rcd/root 2>/dev/null'))"
ex bash -lc 'test -f ~/.config/systemd/user/claude-remote-control@.service' \
  && ok "init installed the unit" || ng "init did not install the unit"

# #3 start ×3 directory conditions: assert dir created + unit enabled (not liveness)
assert_start(){ # $1=name $2=setup-cmd(creates dir condition)
  local n="$1" setup="$2"
  ex bash -lc "$setup" >/dev/null 2>&1 || true
  rcd '/home/rcd/rcdtest-root' start "$n" >/tmp/skill-$n.log 2>&1 || true
  ex bash -lc "test -d ~/rcdtest-root/$n" && ok "$n: instance dir created" || ng "$n: dir not created"
  ex bash -lc "export XDG_RUNTIME_DIR=/run/user/1000; systemctl --user is-enabled claude-remote-control@$n.service >/dev/null 2>&1" \
    && ok "$n: unit enabled" || ng "$n: unit not enabled"
  ex bash -lc "export XDG_RUNTIME_DIR=/run/user/1000; systemctl --user disable --now claude-remote-control@$n.service >/dev/null 2>&1" || true
}
assert_start rcdtest-plain ':'
assert_start rcdtest-child 'git -C ~/rcdtest-root init -q; mkdir -p ~/rcdtest-root/rcdtest-child'
ex bash -lc 'rm -rf ~/rcdtest-root/.git' >/dev/null 2>&1 || true
assert_start rcdtest-repo 'mkdir -p ~/rcdtest-root/rcdtest-repo; git -C ~/rcdtest-root/rcdtest-repo init -q'

# #4 invalid name: NO side-effect, including path traversal outside root (spec §4 #4, F1/F6)
snap(){ ex bash -lc 'export XDG_RUNTIME_DIR=/run/user/1000; systemctl --user list-unit-files "claude-remote-control@*" --no-legend 2>/dev/null | sort; echo --root--; find ~/rcdtest-root -mindepth 1 -maxdepth 1 -printf "%f\n" 2>/dev/null | sort; echo --home--; ls -1a ~ 2>/dev/null | sort'; }
before="$(snap)"
for bad in '../evil' 'a b' 'foo@bar'; do rcd '/home/rcd/rcdtest-root' start "$bad" >/tmp/skill-bad.log 2>&1 || true; done
after="$(snap)"
{ [ "$before" = "$after" ] && ! ex bash -lc 'test -e ~/evil'; } \
  && ok "invalid names: no new unit/dir, no traversal (~/evil absent, side-effects unchanged)" \
  || { ng "invalid name produced a side-effect"; diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/      /'; ex bash -lc 'test -e ~/evil && echo "      LEAK: ~/evil exists"' || true; }

echo
echo "skill: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: 実行ビット付与＋構文確認**

Run: `chmod +x test/acceptance/skill.sh && bash -n test/acceptance/skill.sh && test -x test/acceptance/skill.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: 実行検証（要トークン・人）**

Run: `export CLAUDE_CODE_OAUTH_TOKEN=<setup-token>; ./test/acceptance/skill.sh`
Expected: 末尾 `skill: N passed, 0 failed`（全 PASS）。失敗時は該当 `/tmp/skill-*.log` を確認し、`jq` のフィールド経路（`.plugins`/`.plugin_errors`/`.slash_commands`）が実 `system/init` と一致するか確認して調整。完了後 `./test/acceptance/skill.sh --teardown`。

- [ ] **Step 4: Commit**

```bash
git add test/acceptance/skill.sh
git commit -m "rcd(acceptance): skill unit (headless, system/init + side-effect asserts)"
```

---

## Task 4: 単位 `guards`（対話・人）

**Files:**
- Create: `test/acceptance/guards.sh`

検証（spec §4 guards）: #5 typed-confirm（非 SELF `rcdtest-victim` で）、#6 SELF 拒否（`rcdtest-self`）。SELF 検出を成立させるため対象 unit を **stub claude-bin** で active・listed にする（spec §6-7）。

- [ ] **Step 1: guards.sh を作成**

```bash
#!/usr/bin/env bash
# Unit `guards` — interactive, setup-token (spec §4 guards). Sets up two stub-backed
# units (rcdtest-self, rcdtest-victim) so SELF detection and the destroy confirm
# path can be exercised, then opens an interactive Claude for you to drive /rcd.
# MANUAL acceptance only. Requires docker + CLAUDE_CODE_OAUTH_TOKEN (setup-token);
# the interactive Claude authenticates via that inference token (no full login),
# keeping guards in the inference tier. remote-control is NOT used here.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
C=rcd-acc-guards
TOK=CLAUDE_CODE_OAUTH_TOKEN
PLUGIN=/mnt/rcd
rcd_need_docker
[ -n "${!TOK:-}" ] || { echo "$TOK not set — run 'claude setup-token' and 'export $TOK=<token>'"; exit 1; }
[ "${1:-}" = "--teardown" ] && { rcd_teardown "$C"; echo "guards: container removed"; exit 0; }
rcd_build
rcd_boot "$C"

# Fixture: init, then point claude-bin at the always-alive stub so the units are
# reliably active/listed regardless of auth (spec §4 guards, §6-7).
docker exec -u rcd "$C" bash -lc '
  set -e
  export XDG_RUNTIME_DIR=/run/user/1000
  mkdir -p ~/.config/rcd ~/.config/systemd/user ~/rcdtest-root
  printf "%s\n" /home/rcd/rcdtest-root > ~/.config/rcd/root
  printf "%s\n" /mnt/rcd/test/stub-claude > ~/.config/rcd/claude-bin   # stub = stays alive
  cp /mnt/rcd/units/claude-remote-control@.service ~/.config/systemd/user/
  systemctl --user daemon-reload
  for n in rcdtest-self rcdtest-victim; do
    mkdir -p ~/rcdtest-root/$n
    systemctl --user reset-failed claude-remote-control@$n.service 2>/dev/null || true
    systemctl --user enable --now claude-remote-control@$n.service
  done
  sleep 2
  echo "fixture units:"; systemctl --user list-units "claude-remote-control@*" --no-legend --plain --no-pager
'

cat <<EOF

== guards: interactive checks (no app, no remote-control) ==
A real interactive Claude Code (plugin loaded, RCD_INSTANCE=rcdtest-self) opens
next. Authentication is supplied by CLAUDE_CODE_OAUTH_TOKEN — do NOT run a full
\`claude auth login\` for this unit (that is only for \`live\`). First launch may
ask for theme and folder trust; complete those. Then run these and confirm:

  /rcd                         -> prints the verb table
  /rcd start ../evil           -> refused with the name rule (no systemctl)
  /rcd stop rcdtest-self       -> REFUSED before any confirmation (you are SELF)
  /rcd destroy rcdtest-self    -> REFUSED before any confirmation (you are SELF)
  /rcd destroy rcdtest-victim  -> asks you to type the name; wrong/empty ABORTS
                                  (rcdtest-victim stays active), exact name removes it
  /rcd restart-all             -> asks you to type 'restart-all'; others restart,
                                  SELF (rcdtest-self) is deferred (detached)

Type /exit when done, then tear down:  $0 --teardown
EOF
# XDG_RUNTIME_DIR is required so the skill's `systemctl --user` finds the user bus;
# the setup-token is passed so the session authenticates via inference (no login).
docker exec -it -u rcd -e "$TOK=${!TOK}" -e RCD_INSTANCE=rcdtest-self "$C" \
  bash -lc 'export XDG_RUNTIME_DIR=/run/user/1000; cd ~/rcdtest-root && claude --plugin-dir /mnt/rcd'
```

- [ ] **Step 2: 実行ビット付与＋構文確認**

Run: `chmod +x test/acceptance/guards.sh && bash -n test/acceptance/guards.sh && test -x test/acceptance/guards.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: 実行検証（対話・人）**

Run: `export CLAUDE_CODE_OAUTH_TOKEN=<setup-token>; ./test/acceptance/guards.sh`（初回は theme/trust のみのオンボーディング＝認証はトークンで充足。表示された6項目を対話で確認）。終了後 `./test/acceptance/guards.sh --teardown`。
Expected: SELF の stop/destroy が確認前に拒否、`rcdtest-victim` の destroy が誤/空入力で残存・正確入力で削除、restart-all が SELF 後回し。

- [ ] **Step 4: Commit**

```bash
git add test/acceptance/guards.sh
git commit -m "rcd(acceptance): guards unit (stub fixtures + interactive typed-confirm/SELF)"
```

---

## Task 5: 単位 `live`（アプリ・full login・人）

**Files:**
- Create: `test/acceptance/live.sh`

検証（spec §4 live）: #8 G4 `RCD_INSTANCE` 継承、#9 G5 表示名。前提（full login→trust→base 起動）を内包。

- [ ] **Step 1: live.sh を作成**

```bash
#!/usr/bin/env bash
# Unit `live` — app + full login (spec §4 live). Brings up a live remote-control
# base session, then guides the human through the app-only G4/G5 checks.
# MANUAL acceptance only. Requires docker + a full `claude auth login` (a
# setup-token cannot run remote-control).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
C=rcd-acc-live
PLUGIN=/mnt/rcd
rcd_need_docker
[ "${1:-}" = "--teardown" ] && { rcd_teardown "$C"; echo "live: container removed"; exit 0; }
rcd_build
rcd_boot "$C"

# Step 1: full login + workspace trust, in one interactive launch (onboarding
# accepts folder trust). The instance dir must be trusted because the systemd
# service cannot show the trust dialog (spec §6-3, §8-1).
cat <<EOF

== live step 1/3: full login + trust the instance dir ==
An interactive Claude opens in ~/rcdtest-root/rcdtest-live. Complete onboarding:
choose 'claude auth login' (full scope, NOT a setup-token), and accept the
folder-trust prompt. Then type /exit.
EOF
docker exec -it -u rcd "$C" bash -lc '
  export XDG_RUNTIME_DIR=/run/user/1000
  mkdir -p ~/rcdtest-root/rcdtest-live && git -C ~/rcdtest-root/rcdtest-live init -q
  cd ~/rcdtest-root/rcdtest-live && claude --plugin-dir /mnt/rcd'

# Step 2: init (records real claude-bin) + start the live base session.
echo "== live step 2/3: start the base session =="
docker exec -u rcd "$C" bash -lc '
  set -e
  export XDG_RUNTIME_DIR=/run/user/1000
  systemctl --user unset-environment CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true  # never shadow the login
  mkdir -p ~/.config/rcd ~/.config/systemd/user
  printf "%s\n" /home/rcd/rcdtest-root > ~/.config/rcd/root
  command -v claude > ~/.config/rcd/claude-bin
  cp /mnt/rcd/units/claude-remote-control@.service ~/.config/systemd/user/
  systemctl --user daemon-reload
  systemctl --user reset-failed claude-remote-control@rcdtest-live.service 2>/dev/null || true
  systemctl --user enable --now claude-remote-control@rcdtest-live.service
  sleep 4
  echo -n "base session is-active: "; systemctl --user is-active claude-remote-control@rcdtest-live.service'

cat <<EOF

== live step 3/3: app checks (G4 / G5) ==
If is-active above is NOT 'active', the login/trust did not take — re-run step 1.
Otherwise, in claude.ai/code (web or phone app), open a NEW session on the
instance shown as 'rcdtest-host-rcdtest-live-base' (this spawns an on-demand
worktree session via the relay), and in THAT session confirm:

  echo "\$RCD_INSTANCE"   -> prints rcdtest-live   (G4: inherited into on-demand;
                            the basis for self-detection; empty = defect)
  session display name    -> rcdtest-host-rcdtest-live-<auto>  ('-' separated) (G5)

When done:  $0 --teardown
and delete the leftover 'rcdtest-host-*' sessions in claude.ai/code.
EOF
```

- [ ] **Step 2: 実行ビット付与＋構文確認**

Run: `chmod +x test/acceptance/live.sh && bash -n test/acceptance/live.sh && test -x test/acceptance/live.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: 実行検証（アプリ・人・要 full login）**

Run: `./test/acceptance/live.sh`（手順1でフルログイン＋信頼、手順2で `active` 確認、手順3でアプリから G4/G5）。終了後 `./test/acceptance/live.sh --teardown` ＋ アプリのセッション削除。
Expected: `is-active: active`、on-demand で `RCD_INSTANCE=rcdtest-live`、表示名が `-` 区切り。

- [ ] **Step 4: Commit**

```bash
git add test/acceptance/live.sh
git commit -m "rcd(acceptance): live unit (full login + trust + app G4/G5 guide)"
```

---

## Task 6: test/acceptance/README.md

**Files:**
- Create: `test/acceptance/README.md`

- [ ] **Step 1: README を作成**

```markdown
# test/acceptance — MANUAL acceptance units (not CI)

> Manual only. Never run automatically or wire into `test/run.sh` / CI. The
> automated layers are `test/run.sh` (lint + logic) and `test/service.sh`
> (stub-claude systemd). See `docs/manual-acceptance.md` for the full procedure.

Each unit is **self-contained** (builds the image, boots its own container, tears
it down) and runs a real Claude Code inside a privileged systemd Docker container
with its own `HOME`; the host is never touched.

| Unit | Run | Needs | Verifies |
|---|---|---|---|
| `skill` | `./test/acceptance/skill.sh` | docker + `CLAUDE_CODE_OAUTH_TOKEN` (setup-token) | plugin loads, `/rcd` resolves, `init`/`start` follow SKILL.md, invalid names refused (machine-judged) |
| `guards` | `./test/acceptance/guards.sh` | docker + `CLAUDE_CODE_OAUTH_TOKEN` (setup-token) | typed confirmations + SELF refusal (interactive) |
| `live` | `./test/acceptance/live.sh` | docker + full `claude auth login` + app | `RCD_INSTANCE` inheritance into on-demand sessions, session-name format |

Each script accepts `--teardown` to remove its container.
```

- [ ] **Step 2: Commit**

```bash
git add test/acceptance/README.md
git commit -m "rcd(acceptance): README for the three units"
```

---

## Task 7: docs/manual-acceptance.md（再生成）

**Files:**
- Create: `docs/manual-acceptance.md`

- [ ] **Step 1: ランブックを作成**

````markdown
# rcd — Manual acceptance (units `skill` / `guards` / `live`)

> Manual only — never run automatically or in CI. Surface this only when a
> change warrants a real-Claude pass (see each unit's "Run when"). The automated
> safety net is `test/run.sh` (lint + logic) and `test/service.sh` (stub).

All three units run a **real Claude Code inside an ephemeral, privileged systemd
Docker container** with its own `HOME`; the host's units/skills/instances are
never touched. Each unit is self-contained — it builds the image, boots its own
container, and tears it down (`<script> --teardown`). There is no ordering or
shared state between units.

## `skill` — headless, machine-judged

Verifies the plugin loads, `/rcd` resolves, and Claude follows `SKILL.md`
(`init` records config + installs the unit, `start` creates the dir + enables the
unit, invalid names are refused). A `setup-token` (inference scope) is enough.

```sh
claude setup-token                 # requires a Claude subscription
export CLAUDE_CODE_OAUTH_TOKEN=<token>
./test/acceptance/skill.sh
./test/acceptance/skill.sh --teardown
```

Expected: `skill: N passed, 0 failed`.

**Run when:** `SKILL.md` prose / plugin packaging / the `claude` CLI changed.

## `guards` — interactive, human-judged

Verifies the destructive-verb protections that need a TTY: typed confirmations
(`destroy` / `restart-all`) and SELF refusal. Uses stub-backed fixture units so
SELF detection is reliable. A `setup-token` (inference) is enough — the
interactive Claude authenticates via it; no remote-control / app / full login.

```sh
claude setup-token                 # requires a Claude subscription
export CLAUDE_CODE_OAUTH_TOKEN=<token>
./test/acceptance/guards.sh        # opens an interactive Claude; follow the printed checklist
./test/acceptance/guards.sh --teardown
```

**Run when:** the `SKILL.md` confirmation / SELF-detection / self-protection logic changed.

## `live` — app + full login, human-judged

Verifies the live remote-control behaviour: `RCD_INSTANCE` inheritance into a
relay-spawned on-demand/worktree session (G4) and the claude.ai/code session-name
format (G5). Needs a full `claude auth login` (a setup-token cannot run
remote-control) and the app.

```sh
./test/acceptance/live.sh          # step 1 login+trust, step 2 start, step 3 app checks
./test/acceptance/live.sh --teardown
```

**Run when:** establishing a baseline; the unit's identity/naming/spawn wiring
changed; or you suspect `claude`/claude.ai changed remote-control env inheritance
or the session-name format.

## Notes

- These units are manual by design and need credentials — never wire them into CI.
- Findings should graduate into `lint`/`logic` checks where possible, shrinking
  the manual surface.
````

- [ ] **Step 2: Commit**

```bash
git add docs/manual-acceptance.md
git commit -m "rcd: manual-acceptance runbook for skill/guards/live"
```

---

## Task 8: test/README.md と test/README.ja.md の受け入れ節更新

**Files:**
- Modify: `test/README.md`
- Modify: `test/README.ja.md`

現状の `skill`/`live` 2モード記述を、独立3単位（`skill`/`guards`/`live`）＋「各単位が自前でコンテナを起動・teardown する（単位間依存なし）」モデルに合わせる。

- [ ] **Step 1: `test/README.md` の概観表を3単位へ更新**

`skill` 行を「`./test/acceptance/skill.sh`（headless・setup-token・機械判定）」、新たに `guards` 行（対話・typed-confirm/SELF）、`live` 行（アプリ・full login・G4/G5）に。実行は各単位スクリプト（`docs/manual-acceptance.md` 参照）と明記し、「同じコンテナを再利用／teardown 順序」の旧記述を削除（各単位独立）。`skill`/`guards`/`live` の節を `docs/manual-acceptance.md` の各節に対応させ、重複は最小化（詳細はランブックへ委譲）。

- [ ] **Step 2: `test/README.ja.md` を同内容で更新**

- [ ] **Step 3: 整合確認**

Run: `for f in test/README.md test/README.ja.md; do n=$(grep -c '^```' "$f"); echo "$f fences=$n"; done; grep -rn "Tier\|rcd-acceptance-run" test/README.md test/README.ja.md || echo "(no stale Tier / old container name)"`
Expected: fences が各偶数、`Tier`・旧コンテナ名 `rcd-acceptance-run` の残存なし。

- [ ] **Step 4: Commit**

```bash
git add test/README.md test/README.ja.md
git commit -m "rcd: point test READMEs at the three acceptance units"
```

---

## Task 9: SKILL.md に初回ワークスペース信頼の注記（spec §8-1）

**Files:**
- Modify: `skills/rcd/SKILL.md`（`### start <name>` 手順）

- [ ] **Step 1: `start` 手順に注記を追加**

`### start <name>` の Report 文（手順5）の後に、次の注記を1行追加する:

```markdown
6. **First-run note:** A newly created instance directory may be untrusted by Claude Code. Because the unit launches `claude remote-control` non-interactively (systemd), it cannot answer the workspace-trust dialog and will fail to start until the directory is trusted. Tell the user: the first time an instance is started, open that directory once with an interactive `claude` (in `<root>/<name>`) and accept the trust prompt, then `/rcd start <name>` again.
```

- [ ] **Step 2: lint が緑のまま確認**

Run: `./test/run.sh >/dev/null 2>&1 && echo OK`
Expected: `OK`（allowed-tools 等に影響しない散文追加）。

- [ ] **Step 3: Commit**

```bash
git add skills/rcd/SKILL.md
git commit -m "rcd: note first-run workspace trust for /rcd start"
```

---

## Self-Review（spec 突き合わせ）

- spec §4 `skill`（#1–#4）→ Task 3（`system/init` シグナル #1、init #2、start×3 #3、不正名 差分 #4）。
- spec §4 `guards`（#5/#6、2フィクスチャ）→ Task 4（stub の `rcdtest-self`/`rcdtest-victim`、対話チェックリスト）。
- spec §4 `live`（#8/#9、前提内包）→ Task 5（login+trust→base 起動→アプリ G4/G5）。
- spec §5 独立性 → 各単位スクリプトが `rcd_boot`/`rcd_teardown` で自前完結、固有コンテナ名（`rcd-acc-skill`/`-guards`/`-live`）。
- spec §6-2 トークン非汚染 → Task 5 step2 で `unset-environment`、`skill` は import しない。
- spec §6-3/§8-1 信頼 → Task 9（SKILL.md 注記）＋ Task 5（live で trust）。
- spec §6-4 `--plugin-dir` → `guards`/`skill` の対話・headless は `--plugin-dir`、`live` の G4/G5 は `/rcd` 非依存。
- spec §6-5 権限 → Task 3 の `ALLOW`＋`acceptEdits`＋2× `--add-dir`。
- spec §6-7 SELF フィクスチャ → Task 4 が stub で active・listed を担保。
- spec §9 出力物 → Task 1–9 で網羅（Dockerfile/lib/3単位/README/manual-acceptance/test README/SKILL 注記）。
- Placeholder スキャン: TODO/TBD・未定義参照なし（各スクリプトは完全な内容、`jq` フィールドは実行検証で確認と明記）。
- 型/名称整合: コンテナ名・unit 名・`ALLOW`・`rcd_boot`/`rcd_teardown`・`rcdtest-self`/`rcdtest-victim`/`rcdtest-live` は全タスクで一貫。
