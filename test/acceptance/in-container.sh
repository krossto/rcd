#!/bin/sh
# Runs as the `rcd` user INSIDE the acceptance container (invoked by
# test/acceptance/run-acceptance.sh). Drives the REAL skill path with
# `claude -p --plugin-dir`, then asserts the resulting systemd state.
#
# MANUAL acceptance only — never run by CI. The deterministic systemd machinery
# here is the same as the (proven) test/service.sh harness; the difference is a
# REAL claude executes the skill instead of a stub, so this also covers "does
# Claude actually follow SKILL.md / does the plugin load in Claude Code".
set -u
PLUGIN=/mnt/rcd
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
pass=0; fail=0
ok(){   pass=$((pass+1)); printf '  PASS %s\n' "$1"; }
ng(){   fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
note(){ printf '  -- %s\n' "$1"; }

# Deliberately do NOT import CLAUDE_CODE_OAUTH_TOKEN into the user manager: a
# setup-token is inference-only and cannot run `claude remote-control` anyway (so
# the base session is soft-noted below), and leaving it in the manager's
# environment would shadow a later full `claude auth login` during the `live`
# checks — `claude` prefers the env token and would keep refusing Remote Control.

# Permissions mirror what a consenting user grants — NO --dangerously-skip-permissions:
#   --permission-mode acceptEdits : auto-approve file writes + mkdir/touch/mv/cp
#   --add-dir "$HOME"             : let the skill write rcd's config under ~/.config
#                                   (writes outside the cwd are sandboxed off otherwise)
#   --add-dir "$PLUGIN"           : let `cp` read the plugin's bundled unit template
#   --allowedTools "<comma list>" : the non-filesystem commands the skill runs
# The prompt comes FIRST so the variadic --allowedTools/--add-dir can't swallow it,
# and the allow-list is ONE comma-separated value (an unquoted space-separated list
# would word-split, e.g. "Bash(systemctl --user *)" into several argv tokens).
ALLOW='Bash(systemctl --user *),Bash(systemd-run --user *),Bash(journalctl --user *),Bash(loginctl enable-linger *),Bash(mkdir *),Bash(cp *),Bash(cat *),Bash(test *),Bash(basename *),Bash(command -v *),Bash(pwd *),Bash(pwd),Bash(printf *)'
rcd(){ # headless `/rcd <args>` in the current directory
  claude -p "/rcd $*" --plugin-dir "$PLUGIN" --permission-mode acceptEdits \
    --add-dir "$HOME" --add-dir "$PLUGIN" --allowedTools "$ALLOW" 2>&1
}

# --- auth + plugin load (the core "works in Claude Code" signals) ---
claude auth status >/dev/null 2>&1 && ok "claude authenticated" \
  || ng "claude not authenticated (is CLAUDE_CODE_OAUTH_TOKEN valid?)"
out="$(claude -p --plugin-dir "$PLUGIN" "/rcd" 2>&1)"
echo "$out" | grep -qiE 'init|start|restart-all' \
  && ok "/rcd resolves to the plugin (verb table printed)" \
  || { ng "/rcd did not resolve to the plugin"; echo "$out" | sed 's/^/      /'; }

# --- init (real skill path) ---
# Root lives UNDER $HOME so it shares the workspace opened by --add-dir "$HOME";
# a /tmp dir would be outside it and the skill's writes would be sandboxed off.
ROOT="$HOME/rcdtest-root"; rm -rf "$ROOT"; mkdir -p "$ROOT"; cd "$ROOT" || exit 1
rcd init >/tmp/acc-init.log 2>&1
[ "$(cat "$HOME/.config/rcd/root" 2>/dev/null)" = "$ROOT" ] \
  && ok "init recorded root=$ROOT" || ng "init root ($(cat "$HOME/.config/rcd/root" 2>/dev/null))"
[ -f "$HOME/.config/systemd/user/claude-remote-control@.service" ] \
  && ok "init installed the unit" || ng "init did not install the unit"

# --- start the three directory conditions ---
# `/rcd start <name>` should create <root>/<name> and enable the unit (hard
# asserts below). The unit then execs the REAL `claude remote-control` base
# session; with a `setup-token` (inference scope) that can't reach the relay, so
# the session won't stay live and the runtime --spawn/--name/RCD_INSTANCE checks
# need a full `claude auth login` token. Those runtime args are already covered
# deterministically by test/service.sh (stub), so when the base session isn't
# live we soft-report instead of failing. Each unit is disabled afterwards to
# stop the real-claude auto-restart loop from burning tokens.
assert_inst(){ # $1=name $2=expected --spawn
  inst="$1"; spawn="$2"; svc="claude-remote-control@$inst.service"
  [ -d "$ROOT/$inst" ]                        && ok "$inst: instance dir created" || ng "$inst: dir not created"
  systemctl --user is-enabled "$svc" >/dev/null 2>&1 && ok "$inst: unit enabled"  || ng "$inst: unit not enabled"
  pid="$(systemctl --user show -p MainPID --value "$svc" 2>/dev/null)"
  if [ -n "$pid" ] && [ "$pid" != 0 ]; then
    argv="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    echo "$argv" | grep -q -- "--spawn $spawn"                  && ok "$inst: --spawn $spawn"      || ng "$inst: spawn ($argv)"
    echo "$argv" | grep -q -- "--name rcdtest-host-$inst-base"  && ok "$inst: --name"             || ng "$inst: name ($argv)"
    grep -qz "RCD_INSTANCE=$inst" "/proc/$pid/environ" 2>/dev/null && ok "$inst: RCD_INSTANCE on base" || ng "$inst: RCD_INSTANCE missing"
  else
    note "$inst: base session not live — needs a full \`claude auth login\` token (setup-token can't run remote-control); runtime args covered by test/service.sh"
  fi
  systemctl --user disable --now "$svc" >/dev/null 2>&1 || true
}
rcd start rcdtest-plain >/tmp/acc-rcdtest-plain.log 2>&1
assert_inst rcdtest-plain same-dir
git -C "$ROOT" init -q; mkdir -p "$ROOT/rcdtest-child"          # child inside a parent repo
rcd start rcdtest-child >/tmp/acc-rcdtest-child.log 2>&1
assert_inst rcdtest-child same-dir
rm -rf "$ROOT/.git"
mkdir -p "$ROOT/rcdtest-repo"; git -C "$ROOT/rcdtest-repo" init -q   # dir is itself a git top
rcd start rcdtest-repo >/tmp/acc-rcdtest-repo.log 2>&1
assert_inst rcdtest-repo worktree

# --- model-judgment checks: print transcripts for a human to eyeball ---
echo; note "review these (Claude's judgement — read, don't auto-grade):"
note "invalid name '../evil' — expect a refusal showing the name rule, no systemctl:"
rcd start ../evil | sed 's/^/      /'
note "typed-confirm verbs (destroy / restart-all) and SELF refusal need a TTY;"
note "run them interactively per docs/manual-acceptance.md."

echo
echo "acceptance(auto): $pass passed, $fail failed"
echo "(test units disabled after each check; live-session / on-demand checks need a full login — see host output)"
[ "$fail" -eq 0 ]
