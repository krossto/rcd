---
name: rcd
description: Manage per-project systemd user instances of `claude-remote-control@.service`. Verbs (start/stop/destroy/list/logs/restart-all) wrap `systemctl --user` and `journalctl --user`. Use when starting, stopping, inspecting, or destroying a per-project remote-control service on this VPS, or when restarting every instance after a `claude` CLI auto-update. Includes self-protection when run from inside the fleet (e.g. the `hq` control instance).
argument-hint: <verb> [project-name]
disable-model-invocation: true
allowed-tools: Bash(systemctl --user enable *) Bash(systemctl --user start *) Bash(systemctl --user stop *) Bash(systemctl --user restart *) Bash(systemctl --user disable *) Bash(systemctl --user status *) Bash(systemctl --user list-units *) Bash(systemd-run --user *) Bash(journalctl --user *) Bash(mkdir -p *) Bash(basename *) Bash(pwd)
---

# rcd — Claude Remote-Control Daemon Lifecycle

User input: `$ARGUMENTS`

Manages systemd user instances of `claude-remote-control@.service`.

- Template unit: `~/.config/systemd/user/claude-remote-control@.service`
- Workspace root: `/home/krossto/workspace/<name>` (one dir per instance)
- Each instance shows up in claude.ai/code as `<hostname>-<name>`
- `hq` is the convention for the always-on **control instance** — a dedicated remote-control instance you connect to (from the phone app) to run `/rcd` and manage the rest of the fleet. It is an ordinary instance; nothing reserves the name. Create it once with `/rcd start hq`.

## Self-instance detection (run this FIRST for every invocation)

This skill is often run *from inside* a fleet instance (e.g. `hq`). Operating on your own unit can kill the session you are running in. Before dispatching any verb, determine the **current instance**:

1. `basename "$PWD"` → candidate name (matches the template's `WorkingDirectory=/home/krossto/workspace/%i`).
2. Confirm it is a live unit: it appears in `systemctl --user list-units 'claude-remote-control@*' --no-pager --plain --no-legend`.
3. If both hold, **SELF = that name**. Otherwise **SELF = none** (e.g. a local non-remote session) and self-protection below is inert — proceed normally.

Refer to SELF in `stop`, `destroy`, and `restart-all`.

## Dispatch

Parse `$ARGUMENTS` as `<verb> [<name>]`.

- No verb: print the verb table below and stop.
- Unknown verb: print the table and note which one was unrecognized.
- Verb requires `<name>` but none given: ask the user. Do not guess.

**Confirmation for destructive verbs (`destroy`, `restart-all`) is an in-skill typed confirmation, not a permission prompt.** The workspace allow-list grants `Bash(systemctl *)`, and the session runs in `auto` mode with `skipAutoPermissionPrompt: true`, so a permission prompt will likely **not** appear — especially over remote/mobile. Do not rely on it. Require the user to type the exact confirmation string defined per-verb below before executing. No typed match → abort. Do not work around the typed confirmation.

## Verbs

| Verb | Effect | Args | Destructive |
|---|---|---|---|
| `start` | Create workspace dir if missing, enable + start (idempotent, also resumes from `stop`) | `<name>` | no |
| `stop` | Stop unit, keeps it enabled (auto-starts on next boot). Refuses SELF. | `<name>` | no |
| `destroy` | Disable + stop (full removal). Workspace dir preserved. Refuses SELF; typed confirm. | `<name>` | **yes** |
| `list` | Show all `claude-remote-control@*` units | — | no |
| `logs` | Last 50 journal lines for one instance | `<name>` | no |
| `restart-all` | Restart every `claude-remote-control@*` (after `claude` CLI update). Typed confirm; SELF restarted last/detached. | — | **yes** |

## Per-verb procedures

### `start <name>`

1. `mkdir -p /home/krossto/workspace/<name>`
2. `systemctl --user enable --now claude-remote-control@<name>.service`
3. `systemctl --user status claude-remote-control@<name>.service --no-pager | head -15`
4. Report running/failed. If failed, suggest `/rcd logs <name>`.

### `stop <name>`

1. **Self-guard:** if `<name>` == SELF, **refuse**. Stopping your own unit ends this session and (because `stop` is a clean stop, not a crash) `Restart=always` does **not** bring it back — it stays down until next boot or a manual `/rcd start`. Tell the user to run this from a different instance.
2. `systemctl --user stop claude-remote-control@<name>.service`
3. Brief status check. Tell the user the unit is still enabled — `/rcd start <name>` resumes; `/rcd destroy <name>` removes fully.

### `destroy <name>`

1. **Self-guard:** if `<name>` == SELF, **refuse**. `destroy` disables + stops your own unit = full self-termination with no auto-recovery. Tell the user to run it from another instance (e.g. from `hq`, or from any other instance to destroy `hq`).
2. **Typed confirmation:** ask the user to type the instance name `<name>` exactly. Mention the workspace dir `/home/krossto/workspace/<name>` is preserved. Proceed only on an exact match; on mismatch or empty input, abort.
3. `systemctl --user disable --now claude-remote-control@<name>.service`
4. Verify with `systemctl --user list-units 'claude-remote-control@<name>.service' --all --no-pager`.

### `list`

`systemctl --user list-units 'claude-remote-control@*' --all --no-pager`

If no units, say so plainly. Otherwise relay output as-is.

### `logs <name>`

`journalctl --user -u claude-remote-control@<name>.service -n 50 --no-pager`

Do not use `-f`. If live logs requested, tell the user to run that command with `-f` in a shell.

### `restart-all`

Use after `claude` CLI auto-updates — running instances and child `ccd-cli` processes hold stale install paths. Restarting your own unit (SELF) mid-command would SIGTERM this session before verification, so SELF is restarted **last, detached**.

1. List live units: `systemctl --user list-units 'claude-remote-control@*' --no-pager --plain --no-legend`. Show the full set (SELF included) to the user.
2. **Typed confirmation:** ask the user to type `restart-all` exactly. Proceed only on an exact match; otherwise abort.
3. **If SELF == none** (local non-remote session): restart everything directly — `systemctl --user restart 'claude-remote-control@*'` — then re-list to verify. Done.
4. **If SELF is set:** restart every unit **except** SELF in one call: `systemctl --user restart <unit-a> <unit-b> …` (omit `claude-remote-control@<SELF>.service`).
5. Re-list and verify the others are `active`. Report the result **now**, while the session is still alive.
6. Schedule SELF's restart detached so it fires after this command returns:
   `systemd-run --user --on-active=5 --timer-property=AccuracySec=1s systemctl --user restart claude-remote-control@<SELF>.service`
7. Tell the user: SELF (e.g. `hq`) will drop in ~5s and auto-reconnect (`Restart=always` + the app reconnects). Verification of SELF must be done after reconnect or from another instance.

## Notes

- All commands run as the current user (no `sudo`). Template is user-level + linger.
- **Self-protection is non-negotiable.** Compute SELF first (see top). `stop SELF` / `destroy SELF` are refused; `restart-all` excludes SELF and restarts it detached. Do not "improve" by including SELF — `Restart=always` only covers crashes, not clean stops, and a glob restart kills the session before verification. To act on the current instance, run `/rcd` from a *different* instance.
- Never `kill`/`pkill` a foreground `claude remote-control` from `pgrep` — it may be the session you are running inside.
- This skill does NOT install or modify the template unit. If it's missing, point the user at `/home/krossto/.config/systemd/user/claude-remote-control@.service` and stop.

## Red flags — STOP

- About to run `systemctl --user restart 'claude-remote-control@*'` from inside a fleet instance → the glob includes SELF. Use the SELF-excluding `restart-all` procedure instead.
- About to `disable`/`stop` a unit whose name == SELF → refuse; tell the user to run it from another instance.
- Skipping the typed confirmation because "no prompt appeared / auto mode / the user already said yes" → the typed confirmation IS the confirmation. Require it.
