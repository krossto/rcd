#!/usr/bin/env bash
# Unit `guards` — interactive, full login (spec §4 guards). Sets up two stub-backed
# units (rcdtest-self, rcdtest-victim) so SELF detection and the destroy confirm
# path can be exercised, then opens an interactive Claude for you to drive /rcd.
# MANUAL acceptance only. Requires docker + a full `claude auth login`: the
# interactive TUI cannot authenticate from a setup-token (only headless `-p` can),
# so it runs the normal login onboarding. No app / no remote-control is used here.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
C=rcd-acc-guards
PLUGIN=/mnt/rcd
rcd_need_docker
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
next. Complete onboarding: choose a full \`claude auth login\` (the interactive
TUI cannot authenticate from a setup-token) and accept the folder-trust prompt.
Then run these and confirm:

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
# XDG_RUNTIME_DIR is required so the skill's `systemctl --user` finds the user bus.
# No token is injected: the interactive session authenticates via the full login
# completed in onboarding.
docker exec -it -u rcd -e RCD_INSTANCE=rcdtest-self -e RCD_ACCEPTANCE_MODEL "$C" \
  bash -lc 'export XDG_RUNTIME_DIR=/run/user/1000; cd ~/rcdtest-root && claude --plugin-dir /mnt/rcd ${RCD_ACCEPTANCE_MODEL:+--model "$RCD_ACCEPTANCE_MODEL"}'
