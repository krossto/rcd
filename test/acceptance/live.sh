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
