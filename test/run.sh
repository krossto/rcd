#!/usr/bin/env bash
# CI-safe test set: lint + logic. No real Claude, no Docker, no network.
# (The `service` integration test needs a privileged systemd container — run it
#  separately with test/service.sh.)
set -uo pipefail
cd "$(dirname "$0")/.."
rc=0
echo "== lint =="    ; bash test/lint.sh  || rc=1
echo "== logic =="   ; bash test/logic.sh || rc=1
echo
[ "$rc" -eq 0 ] && echo "ALL GREEN (lint + logic)" || echo "FAILURES — see above"
exit "$rc"
