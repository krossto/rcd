# Tests

Tests for the rcd plugin, organised by **how much they can be automated**, which
in turn reflects **what each layer can verify**.

Two things are being checked, and they need different machinery:

1. **Deterministic machinery** — the unit's launch logic, the skill/plugin
   definition, the systemd wiring. This is verified against a **stub `claude`**
   (`test/stub-claude`), so it needs no real Claude, no auth, and no network. It
   is fully automatable.
2. **Real-Claude behaviour** — whether the actual Claude, reading `SKILL.md`,
   follows it; whether the plugin loads and `/rcd` resolves; and the live
   `claude remote-control` runtime. This needs a real Claude (and, for the
   deepest checks, a logged-in account and the app), so it cannot go in CI and is
   run by hand.

All real-Claude layers run inside an **ephemeral, privileged systemd Docker
container** with its own `HOME`. The host's units, skills, and running instances
are never touched.

## Overview

| Layer | Automation | Verifies | Run it when |
|---|---|---|---|
| `lint` | **Full** (CI) | The skill/plugin **definition** is well-formed: frontmatter, `allowed-tools` covers the commands used, the unit's inline shell parses, `RCD_INSTANCE` is wired, bundled paths use the substitutable `${CLAUDE_PLUGIN_ROOT}` form. | Every change. |
| `logic` | **Full** (CI) | The unit's **launch logic** in isolation: the worktree-vs-same-dir decision, the `--name` / session-name prefix, and the not-initialised / missing-claude guards. | Every change. |
| `service` | **Full** (needs Docker) | The unit actually **runs as a `systemctl --user` service**: correct args and `RCD_INSTANCE` on the base process, for both same-dir and worktree directories. | Every change, where Docker is available. |
| `acceptance` (Tier A) | **Semi** (author runs) | The real Claude **follows `SKILL.md`**: the plugin loads, `/rcd` resolves, `init` records config and installs the unit, `start` creates the instance dir and enables the unit, and invalid names are refused. | The skill prose, the plugin packaging, or the `claude` CLI changed (see below). |
| `acceptance` (Tier B) | **Manual** (author runs) | The **live `claude remote-control` runtime** the stub cannot reach: `RCD_INSTANCE` inheritance into on-demand/worktree sessions, the claude.ai/code session-name format, and SELF-refusal / typed confirmations in a live session. | Establishing a baseline, or the unit's identity/naming wiring or the external `claude`/claude.ai behaviour changed (see below). |

## Fully automatic — continuous tests

Hermetic (stub `claude`); these are your continuous safety net.

```sh
./test/run.sh        # lint + logic — no Docker, no network, CI-safe
./test/service.sh    # service — builds a systemd Docker container, runs there
```

`lint` optionally runs the external linters `skill-tools` and `claudelint` when
installed (or with `RCD_LINT_EXTERNAL=1`); they fetch npm packages, so they are
opt-in and off by default.

## Semi-automatic — acceptance Tier A

**Purpose:** confirm that the real Claude, reading `SKILL.md`, does the right
thing — the part the deterministic layers cannot judge (they check structure,
not whether Claude follows the prose). A `setup-token` (inference scope) is
enough for this tier.

```sh
claude setup-token                 # requires a Claude subscription
export CLAUDE_CODE_OAUTH_TOKEN=<token>
./test/acceptance/run-acceptance.sh
./test/acceptance/run-acceptance.sh --teardown   # when done
```

Most checks are machine-graded; a few model-judgement items (e.g. how an invalid
name is refused) are **printed for you to read** rather than auto-graded.

**Run it when:**

- `SKILL.md` prose changes (verb procedures, the name rule, how bundled files are
  referenced) — wording can change Claude's behaviour even when `lint` passes.
- Plugin packaging changes (`plugin.json` / `marketplace.json`, directory layout,
  skill name, where the unit lives) — this affects loading and `/rcd` resolution.
- The `claude` CLI is upgraded across a major or behaviour-affecting version.

## Manual — acceptance Tier B

**Purpose:** verify the live `claude remote-control` behaviour that no stub can
reproduce. This needs a **full `claude auth login`** (not a `setup-token`) and
the claude.ai/code app, because it exercises the relay and spawned sessions.

Run the standard Tier A flow first, then, in the container:

```sh
docker exec -it -u rcd rcd-acceptance-run bash -lc 'claude auth login'
docker exec -it -u rcd rcd-acceptance-run bash -lc 'claude --plugin-dir /mnt/rcd'
#   then in that session: /rcd start <name>
```

From claude.ai/code, open a session on the instance and confirm: `RCD_INSTANCE`
is inherited into the on-demand/worktree session (the basis for self-detection),
the session name has the expected `-`-separated format, and SELF `stop`/`destroy`
/`restart-all` behave as specified.

**Run it when:**

- Establishing a baseline before relying on these behaviours.
- The unit's identity/naming/spawn wiring changes (`RCD_INSTANCE`, `--name`,
  the session-name prefix, `--spawn`).
- You suspect the `claude` CLI or claude.ai changed remote-control env
  inheritance or session-name rendering, or the self-detection / naming contract
  changed.

## Notes

- **Acceptance is manual by design** — never wire it into CI or run it
  automatically. It needs credentials and (for Tier B) human judgement.
- **Findings graduate.** A failure first caught by acceptance should, where
  possible, become a `lint`/`logic` check, so the same class of bug is caught
  automatically next time and the manual surface shrinks.
