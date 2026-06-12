---
name: rcd
description: Manage per-name Claude Code remote-control instances as systemd user services. Verbs (init/start/stop/destroy/list/logs/restart-all) wrap `systemctl --user` and `journalctl --user`. Use when setting up rcd for the first time (`init`), starting/stopping/inspecting/destroying an instance, or restarting every instance after a `claude` CLI auto-update. Includes self-protection when run from inside an instance (e.g. the `hq` control instance).
argument-hint: <verb> [name]
disable-model-invocation: true
allowed-tools: Bash(systemctl --user *) Bash(systemd-run --user *) Bash(journalctl --user *) Bash(loginctl enable-linger *) Bash(mkdir -p *) Bash(cp *) Bash(printf *) Bash(cat *) Bash(test *) Bash(basename *) Bash(command -v *) Bash(pwd *) Bash(pwd)
---

# rcd — Claude Remote-Control Instance Lifecycle

User input: `$ARGUMENTS`

Manages systemd user instances of `claude-remote-control@.service`.

- Template unit (installed by `init`): `~/.config/systemd/user/claude-remote-control@.service`
- **Instances directory** (the "root"): recorded by `init` in `~/.config/rcd/root`. Each instance lives at `<root>/<name>`.
- Each instance's base session shows up in claude.ai/code as `<hostname>-<name>-base`; its on-demand sessions are prefixed `<hostname>-<name>-`.
- If `<root>/<name>` is itself a git repository top-level, on-demand sessions are isolated in git worktrees; otherwise they share the directory.
- `hq` (headquarters) is a common convention for an always-on **control instance** — one you connect to (e.g. from the phone app) to run `/rcd` and manage the others. It is an ordinary instance; nothing reserves the name. It is optional.

## Self-instance detection (run this FIRST for every invocation)

This skill is often run *from inside* an instance (e.g. `hq`). Operating on your own unit can kill the session you are running in. Before dispatching any verb, determine the **current instance**:

1. **Primary — environment:** read `$RCD_INSTANCE`. The unit sets `Environment=RCD_INSTANCE=%i`, which is inherited by the base session **and its on-demand/worktree sessions**, so this is reliable regardless of the working directory. If set and non-empty, candidate = `$RCD_INSTANCE`.
2. **Fallback — cwd:** only if `$RCD_INSTANCE` is empty (e.g. an instance started before this env was added), candidate = `basename "$PWD"`. Note this fallback is wrong inside a worktree/on-demand session, so prefer the env.
3. Confirm the candidate is a live unit: it appears in `systemctl --user list-units 'claude-remote-control@*' --no-pager --plain --no-legend`.
4. If confirmed, **SELF = that name**. Otherwise **SELF = none** (e.g. a local non-remote session) and self-protection below is inert — proceed normally.

Refer to SELF in `stop`, `destroy`, and `restart-all`.

## Dispatch

Parse `$ARGUMENTS` as `<verb> [<name>]`.

- No verb: print the verb table below and stop.
- Unknown verb: print the table and note which one was unrecognized.
- Verb requires `<name>` but none given: ask the user. Do not guess.
- **The name is a single token.** Treat the whole argument after the verb as one `<name>`. If more than one whitespace-separated token follows the verb (e.g. `start a b`), the intended name contains whitespace and is therefore invalid — refuse and show the rule. Never split it into several instances, and never silently use only the first token.
- **Validate `<name>` before any `systemctl`/`mkdir`:** it must match `^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$` and not be `.` / `..` / end in `.service`. The name becomes a directory, a systemd instance, and a session-name prefix, so reject `/`, whitespace, `@`, `%`, and leading-dot names. On a non-matching name, refuse and show the rule. Do not escape or "fix" it.

**Confirmation for destructive verbs (`destroy`, `restart-all`) is an in-skill typed confirmation, not a permission prompt.** The workspace allow-list grants `Bash(systemctl --user *)`, and the session may run in `auto` mode, so a permission prompt will likely **not** appear — especially over remote/mobile. Do not rely on it. Require the user to type the exact confirmation string defined per-verb below before executing. No typed match → abort. Do not work around the typed confirmation.

## Verbs

| Verb | Effect | Args | Destructive |
|---|---|---|---|
| `init` | One-time setup: record the current directory as the instances directory, install the template unit, `daemon-reload`. Re-runnable. | — | no |
| `start` | Create `<root>/<name>` if missing, enable + start (idempotent, also resumes from `stop`) | `<name>` | no |
| `stop` | Stop unit, keeps it enabled (auto-starts on next boot). Refuses SELF. | `<name>` | no |
| `destroy` | Disable + stop (full removal). Directory preserved. Refuses SELF; typed confirm. | `<name>` | **yes** |
| `list` | Show all `claude-remote-control@*` units | — | no |
| `logs` | Last 50 journal lines for one instance | `<name>` | no |
| `restart-all` | Restart every `claude-remote-control@*` (after `claude` CLI update). Typed confirm; SELF restarted last/detached. | — | **yes** |

## Per-verb procedures

### `init`

Sets up rcd. **Run from the directory you want as the instances directory** — every instance will live in a subdirectory of it.

1. **Locate claude:** `bin=$(command -v claude)`. If empty, or `bin` is not an absolute path (`case "$bin" in /*) ;; *) reject ;; esac`), or `test -x "$bin"` fails, stop and tell the user `claude` must be installed and on PATH (the unit cannot find it otherwise). Only when all three hold, record it: `mkdir -p ~/.config/rcd && printf '%s\n' "$bin" > ~/.config/rcd/claude-bin`. The unit `exec`s this recorded absolute path (and refuses to start if it is missing/non-executable), so rcd does not depend on a guessed PATH.
2. Resolve the root: `pwd` (use `pwd -P` value as the absolute path).
3. **If already initialized** (`~/.config/rcd/root` exists) **and the recorded root differs from the current directory:** show the old root and warn that changing it repoints where *all* existing instances look for their working directory. Require the user to type `change-root` exactly to proceed; otherwise keep the old root (still (re)install the unit and refresh `claude-bin` below).
4. Record the root: write the absolute current directory into `~/.config/rcd/root` (single line). Use: `pwd -P > ~/.config/rcd/root`.
5. Install the template unit (current plugin version): `mkdir -p ~/.config/systemd/user && cp "${CLAUDE_PLUGIN_ROOT}/units/claude-remote-control@.service" ~/.config/systemd/user/claude-remote-control@.service`. (`${CLAUDE_PLUGIN_ROOT}` is the plugin's install dir; Claude Code substitutes the braced form inline — do not write it unbraced.)
6. `systemctl --user daemon-reload`.
7. Report: the recorded root, the resolved claude path, that the unit is installed, and that `/rcd start <name>` is now usable. Mention (optional) `loginctl enable-linger "$USER"` to keep instances running after logout, and that after a plugin **or** claude update re-running `/rcd init` refreshes the unit and the recorded claude path.

### `start <name>`

1. **Require init:** if `~/.config/rcd/root` is missing, tell the user to run `/rcd init` first and stop.
2. Compute and create the directory: `root=$(cat ~/.config/rcd/root)`, then `mkdir -p "$root/<name>"`.
3. `systemctl --user enable --now claude-remote-control@<name>.service`.
4. `systemctl --user status claude-remote-control@<name>.service --no-pager | head -15`.
5. Report running/failed and the directory (`<root>/<name>`). Note whether it will use worktrees (the directory is a git repo top-level) or same-dir. If failed, suggest `/rcd logs <name>`.
6. **First-run note (trust + remote-control consent):** The unit launches `claude remote-control` non-interactively (systemd, no TTY), so it cannot answer two first-run prompts and will fail to start until both are satisfied: (a) the **workspace-trust** dialog for a newly created instance directory (per directory), and (b) the one-time **"Enable Remote Control?"** consent (per machine). Tell the user, before the first `/rcd start <name>`: in `<root>/<name>`, run an interactive `claude` once and accept the folder-trust prompt; and run `claude remote-control` once, answer `y` to "Enable Remote Control?", then press Ctrl+C to stop it. After that, `/rcd start <name>` works — the consent is remembered machine-wide, so further new instances only need the per-directory trust step.

### `stop <name>`

1. **Self-guard:** if `<name>` == SELF, **refuse**. Stopping your own unit ends this session and (because `stop` is a clean stop, not a crash) `Restart=always` does **not** bring it back — it stays down until next boot or a manual `/rcd start`. Tell the user to run this from a different instance.
2. `systemctl --user stop claude-remote-control@<name>.service`.
3. Brief status check. Tell the user the unit is still enabled — `/rcd start <name>` resumes; `/rcd destroy <name>` removes fully.

### `destroy <name>`

1. **Self-guard:** if `<name>` == SELF, **refuse**. `destroy` disables + stops your own unit = full self-termination with no auto-recovery. Tell the user to run it from another instance.
2. **Typed confirmation:** ask the user to type the instance name `<name>` exactly. Mention the directory `<root>/<name>` is preserved. Proceed only on an exact match; on mismatch or empty input, abort.
3. `systemctl --user disable --now claude-remote-control@<name>.service`.
4. Verify with `systemctl --user list-units 'claude-remote-control@<name>.service' --all --no-pager`.

### `list`

`systemctl --user list-units 'claude-remote-control@*' --all --no-pager`

If no units, say so plainly. Otherwise relay output as-is.

### `logs <name>`

`journalctl --user -u claude-remote-control@<name>.service -n 50 --no-pager`

Do not use `-f`. If live logs requested, tell the user to run that command with `-f` in a shell.

### `restart-all`

Use after `claude` CLI auto-updates — running instances hold stale install paths. Restarting your own unit (SELF) mid-command would SIGTERM this session before verification, so SELF is restarted **last, detached**.

1. List live units: `systemctl --user list-units 'claude-remote-control@*' --no-pager --plain --no-legend`. Show the full set (SELF included) to the user.
2. **Typed confirmation:** ask the user to type `restart-all` exactly. Proceed only on an exact match; otherwise abort.
3. **If SELF == none** (local non-remote session): restart everything directly — `systemctl --user restart 'claude-remote-control@*'` — then re-list to verify. Done.
4. **If SELF is set:** restart every unit **except** SELF in one call: `systemctl --user restart <unit-a> <unit-b> …` (omit `claude-remote-control@<SELF>.service`). **If SELF is the only unit** (the others list is empty), skip this restart call entirely and go straight to step 6.
5. Re-list and verify the others are `active` (skip if there were no others). Report the result **now**, while the session is still alive.
6. Schedule SELF's restart detached so it fires after this command returns:
   `systemd-run --user --on-active=5 --timer-property=AccuracySec=1s systemctl --user restart claude-remote-control@<SELF>.service`
7. Tell the user: SELF (e.g. `hq`) will drop in ~5s and auto-reconnect (`Restart=always` + the app reconnects). Verification of SELF must be done after reconnect or from another instance.

## Notes

- All commands run as the current user (no `sudo`). The unit is user-level; enable linger to persist instances across logout.
- The instances directory (root) lives in `~/.config/rcd/root` and is shared by all instances. Change it only via `/rcd init` (typed `change-root`).
- **Self-protection is non-negotiable.** Compute SELF first (see top). `stop SELF` / `destroy SELF` are refused; `restart-all` excludes SELF and restarts it detached. Do not "improve" by including SELF — `Restart=always` only covers crashes, not clean stops, and a glob restart kills the session before verification. To act on the current instance, run `/rcd` from a *different* instance.
- Never `kill`/`pkill` a foreground `claude remote-control` from `pgrep` — it may be the session you are running inside.
- The template unit is installed by `/rcd init`. After a plugin update, re-run `/rcd init` to refresh it.

## Red flags — STOP

- About to run `systemctl --user restart 'claude-remote-control@*'` from inside an instance → the glob includes SELF. Use the SELF-excluding `restart-all` procedure instead.
- About to `disable`/`stop` a unit whose name == SELF → refuse; tell the user to run it from another instance.
- About to `start` while `~/.config/rcd/root` is missing → tell the user to run `/rcd init` first.
- About to create or act on more than one instance from a single `/rcd <verb>` because multiple tokens followed the verb (e.g. `start a b`) → refuse; a name is one token, and `a b` contains whitespace so it is invalid.
- Skipping the typed confirmation because "no prompt appeared / auto mode / the user already said yes" → the typed confirmation IS the confirmation. Require it.
