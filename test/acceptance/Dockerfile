# Real-claude + systemd image shared by all acceptance units (skill/guards/live).
# MANUAL acceptance only — not used by test/run.sh or CI. Boots systemd as PID 1
# (privileged container) and ships a real claude CLI so a real Claude Code runs
# in the container. The plugin under test is mounted read-only at /mnt/rcd.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus dbus-user-session git jq ca-certificates curl \
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g @anthropic-ai/claude-code \
 && apt-get purge -y curl && apt-get autoremove -y \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && find /etc/systemd/system /lib/systemd/system/*.target.wants \
      -name '*.wants' -prune -o -type l -print -delete 2>/dev/null; true
# ubuntu:24.04 ships a default uid-1000 user; drop it so rcd can take uid 1000.
RUN userdel -r ubuntu 2>/dev/null; useradd --create-home --uid 1000 --shell /bin/bash rcd
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
