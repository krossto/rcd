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
