#!/usr/bin/env bash
# Host driver for MANUAL acceptance of the rcd plugin (see docs/manual-acceptance.md).
#
# Builds + boots a privileged systemd container running a REAL claude, mounts the
# plugin read-only, and runs the in-container acceptance checks. Everything stays
# inside the container, so the host's units / skills / running fleet are never
# touched.
#
# NOT part of test/run.sh or any CI flow. Never run automatically — invoke only
# on request, or when a large change makes a real-Claude acceptance pass worth it.
#
# Requires: docker, and a Claude auth token exported as CLAUDE_CODE_OAUTH_TOKEN.
set -uo pipefail
cd "$(dirname "$0")/../.."          # repo root

IMG=rcd-acceptance
CNAME=rcd-acceptance-run
TOKEN_VAR=CLAUDE_CODE_OAUTH_TOKEN

command -v docker >/dev/null 2>&1 || { echo "acceptance: need docker"; exit 1; }
if [ -z "${!TOKEN_VAR:-}" ]; then
  cat <<EOF
acceptance: $TOKEN_VAR is not set.
On a machine already signed in to Claude (requires a Claude subscription):
    claude setup-token          # prints a long-lived token
then:
    export $TOKEN_VAR=<that token>
    $0
(If your claude version names the variable differently, see \`claude setup-token\`.)
EOF
  exit 1
fi

cleanup_only=${1:-}
if [ "$cleanup_only" = "--teardown" ]; then
  docker rm -f "$CNAME" >/dev/null 2>&1 || true
  echo "acceptance: container removed. Now delete leftover 'rcdtest-host-*' sessions in claude.ai/code."
  exit 0
fi

echo "== building real-claude systemd image (first run pulls Node + claude) =="
docker build -q -f test/acceptance/Dockerfile -t "$IMG" test/acceptance >/dev/null \
  || { echo "acceptance: image build failed"; exit 1; }

docker rm -f "$CNAME" >/dev/null 2>&1 || true
echo "== booting container (hostname rcdtest-host) =="
docker run -d --name "$CNAME" --hostname rcdtest-host \
  --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock \
  -v "$PWD":/mnt/rcd:ro \
  -e "$TOKEN_VAR=${!TOKEN_VAR}" \
  "$IMG" >/dev/null || { echo "acceptance: container failed to start"; exit 1; }

# wait for systemd (PID 1) to boot, then the per-user manager + session bus
for i in $(seq 1 60); do
  case "$(docker exec "$CNAME" systemctl is-system-running 2>/dev/null || true)" in
    running|degraded) break;; esac
  sleep 0.5
done
docker exec "$CNAME" loginctl enable-linger rcd >/dev/null 2>&1 || true
for i in $(seq 1 60); do
  docker exec "$CNAME" test -S /run/user/1000/bus 2>/dev/null && break
  sleep 0.5
done

echo "== in-container acceptance =="
docker exec -u rcd -e "$TOKEN_VAR=${!TOKEN_VAR}" "$CNAME" /mnt/rcd/test/acceptance/in-container.sh
rc=$?

cat <<EOF

== container left running for the two human-only checks ==
1) On-demand/worktree RCD_INSTANCE + session-name separator (the parts no stub
   can cover): in claude.ai/code (web or phone app), open a NEW session on the
   instance shown as 'rcdtest-host-rcdtest-repo-base'. In that session run:
       echo "\$RCD_INSTANCE"        # expect: rcdtest-repo
   and confirm its display name reads  rcdtest-host-rcdtest-repo-<auto>  ('-' separated).
2) Optionally exercise the typed-confirm verbs interactively:
       docker exec -it -u rcd $CNAME bash -lc 'claude --plugin-dir /mnt/rcd'
   then try  /rcd stop rcdtest-self ,  /rcd destroy ... ,  /rcd restart-all .
3) Tear down when done (the host was never touched):
       $0 --teardown
   and delete the 'rcdtest-host-*' sessions left in claude.ai/code.
EOF
exit "$rc"
