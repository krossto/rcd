# Systemd-enabled image to run the rcd unit as a real `systemctl --user` service,
# hermetically (against the stub `claude`). Driven by test/service.sh, which runs
# it as a privileged container so systemd can be PID 1. Build context = repo root.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# systemd (PID 1) + a per-user session manager (dbus-user-session) + git, which
# the unit's inline ExecStart calls. Strip the default units we don't need so the
# container boots fast and quietly.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus dbus-user-session git ca-certificates \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && find /etc/systemd/system /lib/systemd/system/*.target.wants \
      -name '*.wants' -prune -o -type l -print -delete 2>/dev/null; true

# Unprivileged user that owns the --user service (fixed uid so the host driver
# can address /run/user/<uid>). ubuntu:24.04 ships a default user at uid 1000;
# drop it so `rcd` can take that uid.
RUN userdel -r ubuntu 2>/dev/null; useradd --create-home --uid 1000 --shell /bin/bash rcd

# Payload: the shipped unit, the stub claude, and the in-container test driver.
COPY units/claude-remote-control@.service /opt/rcd/claude-remote-control@.service
COPY test/stub-claude                     /home/rcd/bin/stub-claude
COPY test/service/run-in-container.sh     /home/rcd/run-in-container.sh
RUN chmod +x /home/rcd/bin/stub-claude /home/rcd/run-in-container.sh \
 && chown -R rcd:rcd /home/rcd

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
