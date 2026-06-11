#!/bin/sh
# Runs as the `rcd` user inside the systemd container (see test/service.sh).
# Performs the deterministic part of `/rcd init` (record root + claude-bin,
# install the unit), starts the unit as a `--user` service for each directory
# condition, and asserts the launched stub got the right args and RCD_INSTANCE.
set -u
fail=0
ok(){ printf '  PASS %s\n' "$1"; }
ng(){ fail=1; printf '  FAIL %s\n' "$1"; }

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
UNIT=claude-remote-control@.service
REC="$HOME/.rcd-stub-record"   # stub's default record path (unit doesn't override it)

# Wait for the per-user systemd manager (started by `loginctl enable-linger`).
i=0; while [ "$i" -lt 60 ]; do
  systemctl --user show-environment >/dev/null 2>&1 && break
  i=$((i+1)); sleep 0.5
done
systemctl --user show-environment >/dev/null 2>&1 \
  || { echo "  user systemd manager not available"; exit 1; }

# Deterministic `/rcd init`: record root + claude path, install the unit.
mkdir -p "$HOME/.config/rcd" "$HOME/.config/systemd/user" "$HOME/insroot"
printf '%s\n' "$HOME/insroot"        > "$HOME/.config/rcd/root"
printf '%s\n' "$HOME/bin/stub-claude" > "$HOME/.config/rcd/claude-bin"
cp "/opt/rcd/$UNIT" "$HOME/.config/systemd/user/$UNIT"
systemctl --user daemon-reload

start_active(){ # $1=instance -> 0 if the service reaches active
  svc="claude-remote-control@$1.service"
  systemctl --user reset-failed "$svc" 2>/dev/null || true
  systemctl --user start "$svc" 2>/dev/null || true
  i=0; while [ "$i" -lt 40 ]; do
    [ "$(systemctl --user is-active "$svc" 2>/dev/null)" = active ] && return 0
    i=$((i+1)); sleep 0.25
  done
  return 1
}

assert_inst(){ # $1=instance  $2=expected --spawn mode
  inst="$1"; spawn="$2"; svc="claude-remote-control@$inst.service"
  rm -f "$REC"
  if start_active "$inst"; then ok "service active: $inst"; else
    ng "service did not become active: $inst"
    systemctl --user status "$svc" --no-pager -l 2>&1 | sed 's/^/      /'
    return
  fi
  i=0; while [ "$i" -lt 40 ]; do [ -s "$REC" ] && break; i=$((i+1)); sleep 0.25; done
  argv="$(sed -n 's/^ARGV: //p' "$REC" 2>/dev/null)"
  cwd="$(sed -n 's/^CWD: //p' "$REC" 2>/dev/null)"
  rcdinst="$(sed -n 's/^RCD_INSTANCE: //p' "$REC" 2>/dev/null)"
  echo "$argv" | grep -q -- "--spawn $spawn"  && ok "$inst: --spawn $spawn"  || ng "$inst: spawn ($argv)"
  echo "$argv" | grep -q -- "--name .*-$inst-base" && ok "$inst: --name *-$inst-base" || ng "$inst: name ($argv)"
  echo "$argv" | grep -q -- "--remote-control-session-name-prefix .*-$inst" \
      && ok "$inst: session-name-prefix" || ng "$inst: prefix ($argv)"
  [ "$rcdinst" = "$inst" ]      && ok "$inst: RCD_INSTANCE inherited from unit" || ng "$inst: RCD_INSTANCE ($rcdinst)"
  echo "$cwd" | grep -q "/insroot/$inst$" && ok "$inst: cwd is <root>/<name>" || ng "$inst: cwd ($cwd)"
  systemctl --user stop "$svc" 2>/dev/null || true
}

# A) plain instance directory -> same-dir
assert_inst rcdtest-svc same-dir

# B) instance directory that is itself a git top-level -> worktree
mkdir -p "$HOME/insroot/rcdtest-wt"
git -C "$HOME/insroot/rcdtest-wt" init -q
assert_inst rcdtest-wt worktree

echo "service(in-container): $([ "$fail" -eq 0 ] && echo OK || echo FAILED)"
exit "$fail"
