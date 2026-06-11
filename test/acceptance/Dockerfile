# Real-claude variant of the systemd test image — for MANUAL acceptance only
# (see docs/manual-acceptance.md). NOT used by test/run.sh or any CI flow, and
# never run automatically.
#
# Boots systemd as PID 1 (privileged container) so the rcd unit runs as a real
# `systemctl --user` service, and ships a real `claude` CLI so acceptance can
# exercise the actual skill path — Claude following SKILL.md — which the stub
# used by test/service.sh deliberately cannot.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# systemd (PID 1) + a per-user session manager + git (the unit's ExecStart calls
# it) + Node 20 (claude-code's runtime) + the claude CLI itself.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus dbus-user-session git ca-certificates curl \
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g @anthropic-ai/claude-code \
 && apt-get purge -y curl && apt-get autoremove -y \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && find /etc/systemd/system /lib/systemd/system/*.target.wants \
      -name '*.wants' -prune -o -type l -print -delete 2>/dev/null; true

# Unprivileged user that owns the --user service and runs claude. ubuntu:24.04
# ships a default user at uid 1000; drop it so `rcd` can take that uid.
RUN userdel -r ubuntu 2>/dev/null; useradd --create-home --uid 1000 --shell /bin/bash rcd

# The plugin under test is mounted read-only at /mnt/rcd at run time (see
# test/acceptance/run-acceptance.sh), so the image never bakes in plugin code.
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
