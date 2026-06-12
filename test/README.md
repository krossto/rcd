# Tests

*English | [日本語](README.ja.md)*

Tests for the rcd plugin, grouped by how far each can be automated — which
follows from what it can verify. The deterministic machinery (unit launch logic,
skill/plugin definition, systemd wiring) is checked against a **stub `claude`**
(`test/stub-claude`) with no auth or network, so it is fully automated. Checking
that the **real Claude** follows `SKILL.md`, that the plugin loads, and that the
live `claude remote-control` runtime works needs a real Claude, so it is run by
hand.

Every real-Claude layer runs in an **ephemeral, privileged systemd Docker
container** with its own `HOME`; the host's units, skills, and instances are
never touched.

## Overview

| Layer | Automation | Verifies |
|---|---|---|
| `lint` | Full (CI) | The skill/plugin **definition**: frontmatter, `allowed-tools` coverage, the unit's inline shell parses and wires `RCD_INSTANCE`, bundled paths use `${CLAUDE_PLUGIN_ROOT}`. |
| `logic` | Full (CI) | The unit's **launch logic** in isolation: worktree-vs-same-dir, `--name` / session-name prefix, and the uninitialised / missing-claude guards. |
| `service` | Full (Docker) | The unit **runs as a `systemctl --user` service**: correct args and `RCD_INSTANCE` on the base process, for same-dir and worktree. |
| `skill` | Semi | The real Claude **follows `SKILL.md`**: plugin loads, `/rcd` resolves, `init` records config + installs the unit, `start` creates the dir + enables the unit, invalid names refused. |
| `guards` | Manual | **Destructive-verb protections** that need a TTY: typed confirmations (`destroy` / `restart-all`) and SELF refusal, against stub-backed fixture units. |
| `live` | Manual | The **live `claude remote-control` runtime** a stub can't reach: `RCD_INSTANCE` inheritance into on-demand/worktree sessions (G4), and the session-name format (G5). |

The three acceptance units (`skill` / `guards` / `live`) are each run via their
own script in `test/acceptance/`. Each unit builds the image, boots its own
container, and tears it down — they are fully independent with no shared state
or ordering. See `docs/manual-acceptance.md` for the full procedure.

## Fully automatic

Hermetic (stub `claude`); run on every change — the continuous safety net.

```sh
./test/run.sh        # lint + logic — no Docker, no network, CI-safe
./test/service.sh    # service — builds a systemd Docker container (needs Docker)
```

`lint` also runs the external linters `skill-tools` and `claudelint` when present
(or with `RCD_LINT_EXTERNAL=1`); they fetch npm packages, so they are opt-in.

## Semi-automatic — `skill`

A `setup-token` (inference scope) is enough.

```sh
claude setup-token                 # requires a Claude subscription
export CLAUDE_CODE_OAUTH_TOKEN=<token>
./test/acceptance/skill.sh
./test/acceptance/skill.sh --teardown
```

Expected: `skill: N passed, 0 failed`. A few model-judgement items (e.g. how an
invalid name is refused) are printed for you to read rather than auto-graded.

**Run when:** `SKILL.md` prose changes (procedures, the name rule, bundled-file
references); plugin packaging changes (`plugin.json` / `marketplace.json`,
layout, skill name, unit location); or the `claude` CLI is upgraded across a
major / behaviour-affecting version.

## Manual — `guards`

A `setup-token` (inference scope) is enough. The script opens an interactive
Claude session; follow the printed checklist.

```sh
claude setup-token                 # requires a Claude subscription
export CLAUDE_CODE_OAUTH_TOKEN=<token>
./test/acceptance/guards.sh
./test/acceptance/guards.sh --teardown
```

**Run when:** the `SKILL.md` confirmation / SELF-detection / self-protection
logic changed.

## Manual — `live`

Needs a **full `claude auth login`** (a `setup-token` can't run
`claude remote-control`) and the claude.ai/code app. The script guides you
through login, starting the instance, and the app checks. See
`docs/manual-acceptance.md` for the full step-by-step procedure.

```sh
./test/acceptance/live.sh
./test/acceptance/live.sh --teardown
```

**Run when:** establishing a baseline; the unit's identity/naming/spawn wiring
changes (`RCD_INSTANCE`, `--name`, session-name prefix, `--spawn`); or you suspect
`claude` / claude.ai changed remote-control env inheritance or session-name
rendering.

## Notes

- `skill`, `guards`, and `live` are manual by design — never wire them into CI.
- Findings graduate: a failure first caught by an acceptance unit should become a
  `lint` / `logic` check where possible, shrinking the manual surface.
