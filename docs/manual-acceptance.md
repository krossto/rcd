# rcd — Safe manual acceptance

> **Manual only.** This is not part of `test/run.sh` and must never be run
> automatically or wired into CI. Surface this procedure only when a maintainer
> asks for it, or when a large change (unit launch logic, naming, SELF
> detection, the `init`/`start` flow) makes a real-Claude pass worth it.

## What this covers, and why it stays manual

The automated layers already prove the deterministic machinery against a stub
`claude`:

- `test/run.sh` — lint (definition health) + logic (unit launch logic, guards).
- `test/service.sh` — the unit running as a real `systemctl --user` service
  (args, `RCD_INSTANCE` on the base, same-dir vs worktree).

What they cannot prove is **real-Claude behaviour**:

1. `RCD_INSTANCE` is inherited into **on-demand / worktree** sessions (a stub
   never spawns them) — the basis for cwd-independent SELF detection.
2. The claude.ai/code session name reads `<host>-<name>-<auto>` with `-`
   separators.
3. Claude actually **follows `SKILL.md`**: `/rcd` resolves to the plugin, names
   are validated, SELF `stop`/`destroy` are refused, typed confirmations hold.

(3) and the deterministic side of (1) are scripted below; (2) and triggering an
on-demand session are the only genuinely human steps.

## Why it is safe to run even on a busy machine

Everything runs in an **ephemeral, privileged Docker container with its own
`HOME` and its own systemd** — the listed candidate "this host's Docker". That
neutralises every hazard of running on a machine that already uses rcd:

| Hazard on a live host | Neutralised because… |
|---|---|
| A user-level `~/.claude/skills/rcd` could shadow `/rcd` | container `~/.claude` is empty; the plugin is loaded explicitly via `--plugin-dir` |
| `/rcd init` overwrites the shared `~/.config/systemd/user/…@.service` | container has its own `HOME`; the host unit is untouched |
| `restart-all` would restart the whole fleet and SIGTERM the current session | container has its own systemd; it only sees its own units |
| Other running instances disrupted | separate filesystem / PID namespaces |
| Session names collide in claude.ai/code | container uses a distinct `--hostname` (`rcdtest-host`) |
| A backup/restore dance could fail and corrupt real config | the container is disposable — `docker rm -f` and nothing on the host changed |

The container does sign in to a real Claude account, so its disposable
`rcdtest-host-*` sessions appear in that account's claude.ai/code list. Delete
them afterwards (or use a separate test account).

## Prerequisite — what you provide

The whole run is manual; the aim is to keep *your* steps minimal.

For the standard run, a long-lived token (requires a Claude subscription). On a
machine already signed in:

```sh
claude setup-token                     # prints a token
export CLAUDE_CODE_OAUTH_TOKEN=<token>
```

The driver passes it through; it is never written to disk. (If your `claude`
version names the variable differently, check `claude setup-token` output.)

A `setup-token` is **inference-scope**: enough to run the skill and assert its
behaviour, but it **cannot run `claude remote-control`** — that needs a
full-scope `claude auth login`. So the live base session is exercised only in the
optional Tier B below.

## Procedure — the standard run (setup-token)

```sh
export CLAUDE_CODE_OAUTH_TOKEN=<token>
./test/acceptance/run-acceptance.sh
```

The driver builds the image, boots the container, and runs `in-container.sh`,
which exercises the **real skill path** and asserts:

- `claude authenticated` and **`/rcd` resolves to the plugin** (verb table).
- **`/rcd init`** records the root + `claude-bin` and installs the unit
  (`daemon-reload` included) — the real `${CLAUDE_PLUGIN_ROOT}` substitution and
  the `~/.config` writes actually happen.
- **`/rcd start`** for three directory conditions creates `<root>/<name>` and
  enables the unit: an empty dir, a child of a parent repo, and a dir that is
  itself a git top-level.
- An invalid name (`../evil`) transcript is printed for you to confirm Claude
  refused it (model judgement, not auto-graded).

The unit's runtime args (`--spawn same-dir`/`worktree`, `--name …-base`,
`RCD_INSTANCE`) are **not** re-checked here — a setup-token can't keep the base
session alive, and those are already verified deterministically by
`test/service.sh` (stub). When the base session isn't live the driver prints a
note instead of failing.

Tear down (the host was never touched):

```sh
./test/acceptance/run-acceptance.sh --teardown
```

and delete any leftover `rcdtest-host-*` sessions in claude.ai/code.

## Optional Tier B — live session, on-demand inheritance, display name

Run this **only** to verify the parts that need a live `claude remote-control`
session, and **only when those behaviours changed** — it needs a full-scope
login (not a setup-token) and still needs the app, so it costs more of your time.

```sh
docker exec -it -u rcd rcd-acceptance-run bash -lc 'claude auth login'        # full-scope
docker exec -it -u rcd rcd-acceptance-run bash -lc 'claude --plugin-dir /mnt/rcd'
#   in that session: /rcd start rcdtest-repo
```

Then, in claude.ai/code, open a new session on `rcdtest-host-rcdtest-repo-base`:

1. **On-demand inheritance + name.** Run `echo "$RCD_INSTANCE"` (expect
   `rcdtest-repo`) and confirm the session name reads
   `rcdtest-host-rcdtest-repo-<auto>` with `-` separators. If `RCD_INSTANCE` is
   empty there, the env is **not** inherited into on-demand sessions → defect:
   switch to the spec's SELF-detection fallback (worktree-metadata lookup).
2. **Typed-confirm verbs.** In the interactive session try `/rcd stop
   rcdtest-self`, `/rcd destroy …`, `/rcd restart-all`; confirm SELF is refused,
   the typed confirmation is required, and `restart-all` defers SELF (detached).

## Relation to the detailed plan

The per-assertion detail and the spec cross-reference live in
`docs/superpowers/plans/2026-06-11-rcd-naming-and-worktree.md`. That plan assumes
a clean host and a backup/restore of real config (Task 0 / Task 7); this
container approach makes that dance unnecessary — the disposable container *is*
the clean environment.
