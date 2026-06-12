# test/acceptance — MANUAL acceptance units (not CI)

> Manual only. Never run automatically or wire into `test/run.sh` / CI. The
> automated layers are `test/run.sh` (lint + logic) and `test/service.sh`
> (stub-claude systemd). See `docs/manual-acceptance.md` for the full procedure.

Each unit is **self-contained** (builds the image, boots its own container, tears
it down) and runs a real Claude Code inside a privileged systemd Docker container
with its own `HOME`; the host is never touched.

| Unit | Run | Needs | Verifies |
|---|---|---|---|
| `skill` | `./test/acceptance/skill.sh` | docker + `CLAUDE_CODE_OAUTH_TOKEN` (setup-token) | plugin loads, `/rcd` resolves, `init`/`start` follow SKILL.md, invalid names refused (machine-judged) |
| `guards` | `./test/acceptance/guards.sh` | docker + `CLAUDE_CODE_OAUTH_TOKEN` (setup-token) | typed confirmations + SELF refusal (interactive) |
| `live` | `./test/acceptance/live.sh` | docker + full `claude auth login` + app | `RCD_INSTANCE` inheritance into on-demand sessions, session-name format |

Each script accepts `--teardown` to remove its container.

Set `RCD_ACCEPTANCE_MODEL` to drive the in-container Claude with a lighter/cheaper
model (e.g. `RCD_ACCEPTANCE_MODEL=haiku ./test/acceptance/skill.sh`, or `sonnet`,
or a full model id). Unset uses the account default. A lighter model follows
`SKILL.md` less reliably, so use it for quick smoke runs and the default for the
canonical pass.
