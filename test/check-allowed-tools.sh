#!/usr/bin/env bash
# lint check: every external command the skill's procedures invoke must be
# covered by a matching Bash(...) entry in the frontmatter `allowed-tools`.
# Catches the class of regression where a command is used in the body but not
# permitted (e.g. dropping `systemd-run` from allowed-tools).
set -uo pipefail
skill="${1:-skills/rcd/SKILL.md}"

allowed="$(grep -m1 '^allowed-tools:' "$skill" || true)"
[ -n "$allowed" ] || { echo "FAIL: no allowed-tools line in $skill"; exit 1; }
# body = everything after the closing frontmatter ---
body="$(awk 'NR>1 && $0=="---"{f=1;next} f' "$skill")"

fail=0
# Commands the skill is expected to run. If the body uses one, allowed-tools
# must grant it (matched by the command's leading binary token).
for cmd in 'systemctl --user' 'systemd-run --user' 'journalctl --user' \
           'loginctl' 'mkdir -p' 'cp ' 'printf ' 'cat ' 'command -v' 'pwd' 'test '; do
  printf '%s' "$body" | grep -qF "$cmd" || continue          # not used → skip
  bin="${cmd%% *}"
  if ! printf '%s' "$allowed" | grep -qE "Bash\(${bin}( |\))"; then
    echo "FAIL: body uses '${cmd}…' but allowed-tools has no Bash(${bin} …) entry"
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then echo "OK: allowed-tools covers the commands used in the body"; else exit 1; fi
