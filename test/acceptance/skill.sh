#!/usr/bin/env bash
# Unit `skill` — headless, setup-token, machine-judged (spec §4 skill).
# MANUAL acceptance only; never run by CI. Requires docker + CLAUDE_CODE_OAUTH_TOKEN.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
C=rcd-acc-skill
TOK=CLAUDE_CODE_OAUTH_TOKEN
PLUGIN=/mnt/rcd
# Optional: drive the in-container Claude with a lighter/cheaper model.
#   RCD_ACCEPTANCE_MODEL=haiku|sonnet|<full-id>   (unset = account default)
MODEL_FLAG=""; [ -n "${RCD_ACCEPTANCE_MODEL:-}" ] && MODEL_FLAG="--model ${RCD_ACCEPTANCE_MODEL}"
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
cjq(){ docker exec -i "$C" jq "$@"; }   # jq runs INSIDE the container (host needs no jq)
rcd(){ # headless `/rcd <args>` in dir $1, remaining args = verb...
  local dir="$1"; shift
  ex bash -lc "export XDG_RUNTIME_DIR=/run/user/1000; cd '$dir'; \
    claude -p \"/rcd $*\" --plugin-dir $PLUGIN $MODEL_FLAG --permission-mode acceptEdits \
    --add-dir \"\$HOME\" --add-dir $PLUGIN --allowedTools '$ALLOW'" 2>&1
}

# #1 load + /rcd resolution via system/init (spec §4 skill signal, §6 / research memo)
init_json="$(ex bash -lc "claude -p '/rcd' --plugin-dir $PLUGIN $MODEL_FLAG --bare --output-format stream-json --verbose 2>/dev/null | head -1")"
echo "$init_json" | cjq -e '(.plugins // [] | map(.name) | index("rcd")) and ((.plugin_errors // []) | length == 0)' >/dev/null 2>&1 \
  && ok "plugin 'rcd' loaded (system/init.plugins, no plugin_errors)" \
  || { ng "plugin not loaded per system/init"; echo "$init_json" | head -c 400; }
echo "$init_json" | cjq -e '[.slash_commands[]? | select(type == "string")] | any(. == "rcd" or endswith(":rcd"))' >/dev/null 2>&1 \
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
assert_start rcdtest-repo 'mkdir -p ~/rcdtest-root/rcdtest-repo; git -C ~/rcdtest-root/rcdtest-repo init -q; git -C ~/rcdtest-root/rcdtest-repo -c user.email=t@t -c user.name=t commit --allow-empty -q -m init'

# #4 invalid name: NO side-effect, including path traversal outside root (spec §4 #4, F1/F6)
snap(){ ex bash -lc 'export XDG_RUNTIME_DIR=/run/user/1000; systemctl --user list-unit-files "claude-remote-control@*" --no-legend 2>/dev/null | sort; echo --root--; find ~/rcdtest-root -mindepth 1 -maxdepth 1 -printf "%f\n" 2>/dev/null | sort; echo --home--; ls -1a ~ 2>/dev/null | sort'; }
before="$(snap)"
for bad in '../evil' 'a b' 'foo@bar' '.hidden' 'a%b' 'x.service'; do rcd '/home/rcd/rcdtest-root' start "$bad" >/tmp/skill-bad.log 2>&1 || true; done
after="$(snap)"
{ [ "$before" = "$after" ] && ! ex bash -lc 'test -e ~/evil'; } \
  && ok "invalid names: no new unit/dir, no traversal (~/evil absent, side-effects unchanged)" \
  || { ng "invalid name produced a side-effect"; diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/      /'; ex bash -lc 'test -e ~/evil && echo "      LEAK: ~/evil exists"' || true; }

echo
echo "skill: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
