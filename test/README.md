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
| `live` | Manual | The **live `claude remote-control` runtime** a stub can't reach: `RCD_INSTANCE` inheritance into on-demand/worktree sessions, the session-name format, and live SELF-refusal / typed confirmations. |

`skill` and `live` are the two modes of the acceptance harness
(`test/acceptance/`): one run does the `skill` checks automatically and leaves
the `live` checks for you.

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
./test/acceptance/run-acceptance.sh
```

The run leaves the container `rcd-acceptance-run` **running** so `live` can reuse
it; tear down only when fully done — skip this if you'll run `live` next, which
ends with the same teardown:

```sh
./test/acceptance/run-acceptance.sh --teardown
```

A few model-judgement items (e.g. how an invalid name is refused) are printed for
you to read rather than auto-graded.

**Run when:** `SKILL.md` prose changes (procedures, the name rule, bundled-file
references); plugin packaging changes (`plugin.json` / `marketplace.json`,
layout, skill name, unit location); or the `claude` CLI is upgraded across a
major / behaviour-affecting version.

## Manual — `live`

Needs a **full `claude auth login`** (a `setup-token` can't run
`claude remote-control`) and the claude.ai/code app.

Run the `docker exec` lines from your **host shell** — the same terminal as
`run-acceptance.sh`, which left `rcd-acceptance-run` running; each runs inside
that container as user `rcd` (uid 1000), so you don't enter it. Do a `skill` pass
first and don't tear down before finishing.

1. Log in with a full-scope token (follow the printed URL / device prompts):

   ```sh
   docker exec -it -u rcd rcd-acceptance-run claude auth login
   ```

2. Start an instance whose directory is a git top-level (so on-demand sessions
   use a worktree) and confirm the base session came up:

   ```sh
   docker exec -it -u rcd rcd-acceptance-run bash -lc '
     export XDG_RUNTIME_DIR=/run/user/1000
     mkdir -p ~/rcdtest-root/rcdtest-live && git -C ~/rcdtest-root/rcdtest-live init -q
     systemctl --user enable --now claude-remote-control@rcdtest-live.service
     sleep 3; systemctl --user is-active claude-remote-control@rcdtest-live.service'
   ```

   Expect `active`; if it stays `activating` (restart loop), the login didn't
   take — redo step 1.

3. In claude.ai/code, open a **new** session on `rcdtest-host-rcdtest-live-base`
   (this spawns an on-demand worktree session) and in it check:

   - `echo "$RCD_INSTANCE"` prints `rcdtest-live` — the env is inherited into
     on-demand/worktree sessions (the basis for self-detection); empty = defect.
   - the session name reads `rcdtest-host-rcdtest-live-<auto>` (`-` separated).
   - `/rcd stop rcdtest-live` and `/rcd destroy rcdtest-live` both **refuse** (you
     are SELF); `/rcd restart-all` defers SELF (a detached restart).

4. Tear down, then delete the leftover `rcdtest-host-*` sessions in claude.ai/code:

   ```sh
   ./test/acceptance/run-acceptance.sh --teardown
   ```

**Run when:** establishing a baseline; the unit's identity/naming/spawn wiring
changes (`RCD_INSTANCE`, `--name`, session-name prefix, `--spawn`); or you suspect
`claude` / claude.ai changed remote-control env inheritance or session-name
rendering.

## Notes

- `skill` and `live` are manual by design — never wire them into CI.
- Findings graduate: a failure first caught by `skill` / `live` should become a
  `lint` / `logic` check where possible, shrinking the manual surface.
