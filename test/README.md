# test

Tests for the rcd plugin. The automated layers use a **stub `claude`**
(`test/stub-claude`) — no real Claude install or auth is needed, so they are
hermetic and CI-friendly. They verify the deterministic machinery (the unit's
launch logic and the skill definition); they do **not** verify how Claude
follows `SKILL.md` — that is the manual acceptance step (see bottom).

## Layers

| Script | Verifies | Real Claude | Infra |
|---|---|---|---|
| `lint.sh` | The **skill/plugin definition** is well-formed: frontmatter, `allowed-tools` covers the commands the procedures use, the unit's inline shell parses, `RCD_INSTANCE` wiring is present. | no | none |
| `logic.sh` | The unit's **launch logic** in isolation: for each directory condition it picks the right `--spawn` (worktree only when the dir is itself a git top-level) and builds the right `--name` / `--remote-control-session-name-prefix`, and the uninitialized / missing-claude guards fire. | no (stub) | none |
| `service.sh` | The unit actually **runs as a systemd user service**: it starts under `systemctl --user`, the launched process gets the right args, and `RCD_INSTANCE` is set in its environment. | no (stub) | Docker (privileged, systemd) |

## Run

```sh
./test/run.sh        # CI-safe: lint + logic (no network, no Docker)
./test/service.sh    # integration: builds a systemd Docker container, runs there
```

`lint.sh` optionally runs the external linters `skill-tools` and `claudelint`
when they are installed (or `RCD_LINT_EXTERNAL=1`). They fetch npm packages, so
they are opt-in; the default lint is fully local.

## Not covered here — manual acceptance

How Claude, following `SKILL.md`, actually drives `/rcd init` / `/rcd start`, and
real-claude runtime behaviour (on-demand worktree sessions, `RCD_INSTANCE`
inheritance into them, the session-name separator in claude.ai/code) require a
real Claude in a clean Linux+systemd environment. Run that once via the
acceptance plan: `docs/superpowers/plans/2026-06-11-rcd-naming-and-worktree.md`.
