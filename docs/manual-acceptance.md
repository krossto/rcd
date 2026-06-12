# rcd — Manual acceptance (units `skill` / `guards` / `live`)

> Manual only — never run automatically or in CI. Surface this only when a
> change warrants a real-Claude pass (see each unit's "Run when"). The automated
> safety net is `test/run.sh` (lint + logic) and `test/service.sh` (stub).

All three units run a **real Claude Code inside an ephemeral, privileged systemd
Docker container** with its own `HOME`; the host's units/skills/instances are
never touched. Each unit is self-contained — it builds the image, boots its own
container, and tears it down (`<script> --teardown`). There is no ordering or
shared state between units.

## `skill` — headless, machine-judged

Verifies the plugin loads, `/rcd` resolves, and Claude follows `SKILL.md`
(`init` records config + installs the unit, `start` creates the dir + enables the
unit, invalid names are refused). A `setup-token` (inference scope) is enough.

```sh
claude setup-token                 # requires a Claude subscription
export CLAUDE_CODE_OAUTH_TOKEN=<token>
./test/acceptance/skill.sh
./test/acceptance/skill.sh --teardown
```

Expected: `skill: N passed, 0 failed`.

**Run when:** `SKILL.md` prose / plugin packaging / the `claude` CLI changed.

## `guards` — interactive, human-judged

Verifies the destructive-verb protections that need a TTY: typed confirmations
(`destroy` / `restart-all`) and SELF refusal. Uses stub-backed fixture units so
SELF detection is reliable. Needs a full `claude auth login`: the interactive TUI
cannot authenticate from a setup-token (only headless `-p` can), so it runs the
normal login onboarding. No app / no remote-control is used here.

```sh
./test/acceptance/guards.sh        # opens an interactive Claude; choose full `claude auth login`
                                   # in onboarding, then follow the printed checklist
./test/acceptance/guards.sh --teardown
```

**Run when:** the `SKILL.md` confirmation / SELF-detection / self-protection logic changed.

## `live` — app + full login, human-judged

Verifies the live remote-control behaviour: the instance name (`RCD_INSTANCE`) is
inherited into a relay-spawned on-demand/worktree session, and the claude.ai/code
session-name format. Needs a full `claude auth login` (a setup-token cannot run
remote-control) and the app.

```sh
./test/acceptance/live.sh          # step 1 login+trust, step 2 start, step 3 app checks
./test/acceptance/live.sh --teardown
```

The script pre-accepts the one-time `claude remote-control` "Enable Remote
Control?" consent in step 2 (the systemd unit has no TTY to answer it). In real
use the same applies: the first `/rcd start` on a machine needs that consent
accepted once — see the first-run note in `skills/rcd/SKILL.md` (`start`).

> **Leaves an un-removable claude.ai environment (platform limitation).** Each
> `live` run registers a Remote Control environment (`rcdtest-host-rcdtest-live`)
> with the claude.ai relay. `--teardown` removes the local container but **cannot**
> deregister that environment — claude.ai currently has **no way to delete stale
> Remote Control environments** (no web/app button, no CLI, no documented
> auto-expiry; tracked in claude-code issue #50884). So every `live` run leaves one
> dead `rcdtest-host-*` entry in your environment list that you cannot remove. Run
> `live` sparingly (see **Run when** below), not in a loop.

**Run when:** establishing a baseline; the unit's identity/naming/spawn wiring
changed; or you suspect `claude`/claude.ai changed remote-control env inheritance
or the session-name format.

## Notes

- These units are manual by design and need credentials — never wire them into CI.
- Findings should graduate into `lint`/`logic` checks where possible, shrinking
  the manual surface.
- `RCD_ACCEPTANCE_MODEL` (optional) drives the in-container Claude with a lighter
  model for cheaper/faster runs, e.g. `RCD_ACCEPTANCE_MODEL=haiku ./test/acceptance/skill.sh`
  (also `sonnet`, or a full model id). Unset uses the account default. Lighter
  models follow `SKILL.md` less reliably — prefer them for quick smoke runs and
  the default model for the canonical pass.
