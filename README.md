# rcd

`/rcd` — a Claude Code slash command that manages per-name **remote-control instances** as systemd user services. Each instance is an always-on Claude Code you can connect to (e.g. from the phone/web app) for a given project.

## Requirements

- Linux (uses systemd user services)
- `claude` CLI with `claude remote-control` support

> macOS / Windows are not supported (systemd-specific).

## Quick start

```text
# 1. In the directory where you want your instances to live, start Claude Code
#    and install the plugin.
cd ~/agents
claude
> /plugin            # install rcd from the marketplace

# 2. One-time setup. Records this directory and installs the systemd unit.
> /rcd init

# 3. Start an instance by name.
> /rcd start my-project
```

`my-project` now runs as a service. Its working directory is `~/agents/my-project`
(created if absent, reused if present), and it appears in the app as
`<hostname>-my-project-base`.

## Concepts

- **Instances directory (root)** — the directory you run `/rcd init` in. Every
  instance lives in a subdirectory of it: `<root>/<name>`.
- **Instance** — a named, always-on remote-control service
  (`claude-remote-control@<name>`). Its base session is `<hostname>-<name>-base`;
  on-demand sessions are prefixed `<hostname>-<name>-`.
- **`hq` (optional)** — a common convention: keep one instance named `hq`
  (headquarters) as a control console you connect to and manage the others from.
  It is just an ordinary instance; the name is not reserved.

## What `/rcd init` does

No hand-editing of config files is needed. `init`:

- locates `claude` (`command -v claude`) and records its absolute path, so the
  service does not depend on a guessed PATH,
- records the current directory as the instances directory (`~/.config/rcd/root`),
- installs the systemd template unit into `~/.config/systemd/user/`,
- runs `systemctl --user daemon-reload`.

To keep instances running after you log out, enable lingering once:
`loginctl enable-linger "$USER"`. After updating the plugin or `claude`, re-run
`/rcd init` to refresh the installed unit and recorded paths.

## Commands

`/rcd start` requires a name. `<root>/<name>` is created if missing, reused if present.

| Command | Effect |
|---|---|
| `/rcd init`          | One-time setup (record root, install unit, reload) |
| `/rcd start <name>`  | Start (and enable) the instance at `<root>/<name>` (idempotent) |
| `/rcd stop <name>`   | Stop it (stays enabled; auto-starts next boot). Refuses the current instance |
| `/rcd destroy <name>`| Remove it fully (directory kept). Requires typed confirmation |
| `/rcd list`          | List all instances |
| `/rcd logs <name>`   | Recent journal lines for one instance |
| `/rcd restart-all`   | Restart every instance (e.g. after a `claude` CLI update). Typed confirmation |

## Naming and worktrees

- The base session is `<hostname>-<name>-base`, so it is easy to spot in the list.
- If `<root>/<name>` is **itself a git repository top-level**, on-demand sessions
  are isolated in their own **git worktrees**. Empty or non-git directories are
  not forced into worktree mode — `git init` / `git clone` inside the directory to
  enable it.

## Safety

- Running `/rcd` from inside an instance (e.g. `hq`) will not let you stop or
  destroy that same instance and cut your own connection — operate on the current
  instance from a different one.
- `destroy` and `restart-all` require typing an exact confirmation string.
