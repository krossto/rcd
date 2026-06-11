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

## Prerequisite — the one thing you provide

A long-lived auth token (requires a Claude subscription). On a machine already
signed in:

```sh
claude setup-token            # prints a token
export CLAUDE_CODE_OAUTH_TOKEN=<that token>
```

The driver passes it through; it is never written to disk. (If your `claude`
version names the variable differently, check `claude setup-token` output.)

## Procedure (one command + two human checks)

```sh
export CLAUDE_CODE_OAUTH_TOKEN=<token>
./test/acceptance/run-acceptance.sh
```

The driver builds the image, boots the container, and runs `in-container.sh`,
which exercises the **real skill path** and asserts the result:

- `claude authenticated` and **`/rcd` resolves to the plugin** (verb table).
- `/rcd init` records the root and installs the unit.
- `/rcd start` for three directory conditions, checked against each unit's real
  `/proc/<pid>/cmdline` and `environ`:
  - empty dir → `--spawn same-dir`
  - child of a parent repo → `--spawn same-dir` (does not engulf the parent)
  - dir that is itself a git top-level → `--spawn worktree`
  - correct `--name rcdtest-host-<name>-base` and `RCD_INSTANCE=<name>` on the base
- An invalid name (`../evil`) transcript is printed for you to confirm Claude
  refused it (model judgement, not auto-graded).

Then do the two human-only checks the driver prints:

1. **On-demand inheritance + name (gaps #1, #2).** In claude.ai/code, open a new
   session on `rcdtest-host-rcdtest-repo-base`; in it run `echo "$RCD_INSTANCE"`
   (expect `rcdtest-repo`) and confirm the session name is
   `rcdtest-host-rcdtest-repo-<auto>` with `-` separators. If `RCD_INSTANCE` is
   empty there, the env is **not** inherited into on-demand sessions → that is a
   defect: switch to the spec's SELF-detection fallback (worktree-metadata
   lookup).
2. **Typed-confirm verbs (optional, needs a TTY).**
   ```sh
   docker exec -it -u rcd rcd-acceptance-run bash -lc 'claude --plugin-dir /mnt/rcd'
   ```
   Then try `/rcd stop rcdtest-self`, `/rcd destroy …`, `/rcd restart-all` and
   confirm SELF is refused, the typed confirmation is required, and `restart-all`
   defers SELF (detached).

Tear down (the host was never touched):

```sh
./test/acceptance/run-acceptance.sh --teardown
```

and delete the leftover `rcdtest-host-*` sessions in claude.ai/code.

## Relation to the detailed plan

The per-assertion detail and the spec cross-reference live in
`docs/superpowers/plans/2026-06-11-rcd-naming-and-worktree.md`. That plan assumes
a clean host and a backup/restore of real config (Task 0 / Task 7); this
container approach makes that dance unnecessary — the disposable container *is*
the clean environment.
