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
