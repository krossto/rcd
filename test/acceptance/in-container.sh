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

# Propagate the auth token to services started by the user manager, so the real
# `claude remote-control` base sessions can authenticate (the unit itself does
# not carry the token).
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && \
  systemctl --user import-environment CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true

# Pre-approve exactly the skill's declared allowed-tools so headless `-p` runs
# its systemctl/mkdir/etc. without prompts — NO --dangerously-skip-permissions.
# Passed as a SINGLE quoted --settings JSON value: --allowedTools is variadic, so
# an unquoted space-separated list word-splits (e.g. "Bash(systemctl --user *)"
# becomes several argv tokens), the variadic stops at the first `--…` token, and
# the "/rcd …" prompt gets swallowed — Claude then exits without running anything.
SETTINGS='{"permissions":{"allow":["Bash(systemctl --user *)","Bash(systemd-run --user *)","Bash(journalctl --user *)","Bash(loginctl enable-linger *)","Bash(mkdir -p *)","Bash(cp *)","Bash(cat *)","Bash(test *)","Bash(basename *)","Bash(command -v *)","Bash(pwd *)","Bash(pwd)"]}}'
rcd(){ # headless `/rcd <args>` in the current directory
  claude -p --plugin-dir "$PLUGIN" --permission-mode acceptEdits --settings "$SETTINGS" "/rcd $*" 2>&1
}

# --- auth + plugin load (the core "works in Claude Code" signals) ---
claude auth status >/dev/null 2>&1 && ok "claude authenticated" \
  || ng "claude not authenticated (is CLAUDE_CODE_OAUTH_TOKEN valid?)"
out="$(claude -p --plugin-dir "$PLUGIN" "/rcd" 2>&1)"
echo "$out" | grep -qiE 'init|start|restart-all' \
  && ok "/rcd resolves to the plugin (verb table printed)" \
  || { ng "/rcd did not resolve to the plugin"; echo "$out" | sed 's/^/      /'; }

# --- init (real skill path) ---
ROOT="$(mktemp -d)"; cd "$ROOT" || exit 1
rcd init >/tmp/acc-init.log 2>&1
[ "$(cat "$HOME/.config/rcd/root" 2>/dev/null)" = "$ROOT" ] \
  && ok "init recorded root=$ROOT" || ng "init root ($(cat "$HOME/.config/rcd/root" 2>/dev/null))"
[ -f "$HOME/.config/systemd/user/claude-remote-control@.service" ] \
  && ok "init installed the unit" || ng "init did not install the unit"

# --- start the three directory conditions; assert each unit's real argv/env ---
assert_inst(){ # $1=name $2=expected --spawn
  pid="$(systemctl --user show -p MainPID --value "claude-remote-control@$1.service" 2>/dev/null)"
  { [ -n "$pid" ] && [ "$pid" != 0 ]; } || { ng "$1: no live MainPID (see /tmp/acc-$1.log)"; return; }
  argv="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
  echo "$argv" | grep -q -- "--spawn $2"                    && ok "$1: --spawn $2"           || ng "$1: spawn ($argv)"
  echo "$argv" | grep -q -- "--name rcdtest-host-$1-base"   && ok "$1: --name"              || ng "$1: name ($argv)"
  grep -qz "RCD_INSTANCE=$1" "/proc/$pid/environ" 2>/dev/null && ok "$1: RCD_INSTANCE on base" || ng "$1: RCD_INSTANCE missing"
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
echo "services left running for the human-only checks (see host script output)."
[ "$fail" -eq 0 ]
