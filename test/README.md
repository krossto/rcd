# Tests

*English | [日本語](README.ja.md)*

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
| `skill` | **Semi** | The real Claude **follows `SKILL.md`**: the plugin loads, `/rcd` resolves, `init` records config and installs the unit, `start` creates the instance dir and enables the unit, and invalid names are refused. | The skill prose, the plugin packaging, or the `claude` CLI changed (see below). |
| `live` | **Manual** | The **live `claude remote-control` runtime** the stub cannot reach: `RCD_INSTANCE` inheritance into on-demand/worktree sessions, the claude.ai/code session-name format, and SELF-refusal / typed confirmations in a live session. | Establishing a baseline, or the unit's identity/naming wiring or the external `claude`/claude.ai behaviour changed (see below). |

`skill` and `live` are the two modes of the acceptance harness
(`test/acceptance/`): the same run drives the `skill` checks automatically and
leaves the `live` checks for you to perform.

## Fully automatic — continuous tests

Hermetic (stub `claude`); these are your continuous safety net.

```sh
./test/run.sh        # lint + logic — no Docker, no network, CI-safe
./test/service.sh    # service — builds a systemd Docker container, runs there
```

`lint` optionally runs the external linters `skill-tools` and `claudelint` when
installed (or with `RCD_LINT_EXTERNAL=1`); they fetch npm packages, so they are
opt-in and off by default.

## Semi-automatic — `skill`

**Purpose:** confirm that the real Claude, reading `SKILL.md`, does the right
thing — the part the deterministic layers cannot judge (they check structure,
not whether Claude follows the prose). A `setup-token` (inference scope) is
enough for this.

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

## Manual — `live`

**Purpose:** verify the live `claude remote-control` behaviour that no stub can
reproduce. It needs a **full `claude auth login`** (a `setup-token` is
inference-only and cannot run `claude remote-control`) plus the claude.ai/code
app, because it exercises the relay and the sessions it spawns.

**Procedure.** Run the `docker exec` lines below from your **host shell** — the
same terminal you ran `./test/acceptance/run-acceptance.sh` in (that script
leaves the container `rcd-acceptance-run` running). `docker exec` runs each
command *inside* that container as the `rcd` user (uid 1000); you do not enter
the container yourself. The rcd config recorded by the prior `skill` run is
reused.

1. Log in with a full-scope token, following the printed URL / device prompts:

   ```sh
   docker exec -it -u rcd rcd-acceptance-run claude auth login
   ```

2. Start an instance whose directory is a git top-level (so on-demand sessions
   use a worktree) and confirm the base session actually came up:

   ```sh
   docker exec -it -u rcd rcd-acceptance-run bash -lc '
     export XDG_RUNTIME_DIR=/run/user/1000
     mkdir -p ~/rcdtest-root/rcdtest-live && git -C ~/rcdtest-root/rcdtest-live init -q
     systemctl --user enable --now claude-remote-control@rcdtest-live.service
     sleep 3; systemctl --user is-active claude-remote-control@rcdtest-live.service'
   ```

   Expect `active`. If it stays `activating` (auto-restart loop), the login did
   not take — redo step 1.

3. In claude.ai/code (web or app), find the base session
   `rcdtest-host-rcdtest-live-base` and open a **new** session on that instance.
   This is what spawns an on-demand (worktree) session.

4. In that on-demand session, check the two things the stub cannot:

   - `echo "$RCD_INSTANCE"` must print `rcdtest-live`. This confirms the env is
     inherited into on-demand/worktree sessions — the basis for self-detection.
     If it is empty, the env is **not** inherited → defect.
   - The session's display name reads `rcdtest-host-rcdtest-live-<auto>`, with
     `-` separators.

5. Still in that on-demand session, exercise self-protection:

   - `/rcd stop rcdtest-live` and `/rcd destroy rcdtest-live` must both **refuse**
     (you are inside SELF).
   - `/rcd restart-all` restarts the others but defers SELF (a detached restart).

6. Tear down and remove the disposable sessions:

   ```sh
   ./test/acceptance/run-acceptance.sh --teardown
   ```

   then delete the leftover `rcdtest-host-*` sessions in claude.ai/code.

**Run it when:**

- Establishing a baseline before relying on these behaviours.
- The unit's identity/naming/spawn wiring changes (`RCD_INSTANCE`, `--name`,
  the session-name prefix, `--spawn`).
- You suspect the `claude` CLI or claude.ai changed remote-control env
  inheritance or session-name rendering, or the self-detection / naming contract
  changed.

## Notes

- **`skill` and `live` are manual by design** — never wire them into CI or run
  them automatically. They need credentials and (for `live`) human judgement.
- **Findings graduate.** A failure first caught by `skill` or `live` should,
  where possible, become a `lint` / `logic` check, so the same class of bug is
  caught automatically next time and the manual surface shrinks.
