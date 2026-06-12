#!/usr/bin/env bash
# service: verify the shipped unit actually runs as a `systemctl --user` service
# with the right args and RCD_INSTANCE, inside a privileged systemd Docker
# container. Hermetic: it runs against the stub `claude`, so no real Claude,
# auth, or network is needed (beyond the one-time image build).
#
# Not part of the CI-safe set (test/run.sh) because it needs Docker and a
# privileged container (systemd as PID 1). Run it directly:  ./test/service.sh
set -uo pipefail
cd "$(dirname "$0")/.."

if ! command -v docker >/dev/null 2>&1; then
  echo "service: SKIP (docker not available)"; exit 0
fi

IMG=rcd-service-test
CNAME=rcd-service-test-run
cleanup(){ docker rm -f "$CNAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

echo "== building systemd image =="
docker build -q -f test/service/Dockerfile -t "$IMG" . >/dev/null \
  || { echo "service: image build failed"; exit 1; }

echo "== booting systemd container =="
docker run -d --name "$CNAME" --hostname rcdhost \
  --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock \
  "$IMG" >/dev/null \
  || { echo "service: container failed to start"; exit 1; }

# Wait for systemd (PID 1) to finish booting.
i=0; while [ "$i" -lt 60 ]; do
  state="$(docker exec "$CNAME" systemctl is-system-running 2>/dev/null || true)"
  case "$state" in running|degraded) break;; esac
  i=$((i+1)); sleep 0.5
done
case "$(docker exec "$CNAME" systemctl is-system-running 2>/dev/null || true)" in
  running|degraded) ;;
  *) echo "service: systemd did not boot in container"
     docker exec "$CNAME" systemctl --no-pager status 2>&1 | sed 's/^/  /' || true
     exit 1;;
esac

# Bring up the per-user manager for the test user and wait for its session bus.
docker exec "$CNAME" loginctl enable-linger rcd >/dev/null 2>&1 || true
i=0; while [ "$i" -lt 60 ]; do
  docker exec "$CNAME" test -S /run/user/1000/bus 2>/dev/null && break
  i=$((i+1)); sleep 0.5
done

echo "== in-container service checks =="
docker exec -u rcd "$CNAME" /home/rcd/run-in-container.sh
rc=$?

[ "$rc" -eq 0 ] && echo "service: OK" || echo "service: FAILED"
exit "$rc"
