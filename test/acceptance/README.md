# test/acceptance — MANUAL acceptance harness (not CI)

> **Manual only. Never run automatically and never wire into `test/run.sh` or CI.**
> Use it only when explicitly requested, or when a large change makes a
> real-Claude acceptance pass worth it. The CI-safe automated layers are
> `test/run.sh` (lint + logic) and `test/service.sh` (stub-claude systemd).

This harness runs the plugin against a **real `claude`** inside a privileged
systemd Docker container, so it covers what the stub cannot: that Claude
actually follows `SKILL.md`, that `/rcd` resolves to the plugin, and (with a
human) that `RCD_INSTANCE` is inherited into on-demand/worktree sessions and the
claude.ai/code session name uses the `-` separator.

Everything stays inside an ephemeral container — the host's units, skills and
running instances are never touched.

## Files

| File | Role |
|---|---|
| `Dockerfile` | Ubuntu + systemd (PID 1) + Node 20 + real `claude` CLI |
| `run-acceptance.sh` | Host driver: build, boot, run checks, leave container up; `--teardown` to remove |
| `in-container.sh` | Runs as the `rcd` user: drives `claude -p --plugin-dir` and asserts systemd state |

## Run

See **`docs/manual-acceptance.md`** for the full procedure and the two
human-only checks. In short:

```sh
claude setup-token                 # on an authed machine; requires a subscription
export CLAUDE_CODE_OAUTH_TOKEN=<token>
./test/acceptance/run-acceptance.sh
# ... do the two human checks it prints ...
./test/acceptance/run-acceptance.sh --teardown
```
