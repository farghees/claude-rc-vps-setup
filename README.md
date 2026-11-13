# claude-rc-vps-setup

Run Claude Code Remote Control (`claude remote-control`) on a Linux VPS 24/7. It uses a systemd
user unit that starts a detached tmux session, and linger so it comes back after a reboot without
anyone logging in. Your VPS then shows up at claude.ai/code and in the Claude mobile app.

This is an agent skill. It can be installed with `npx skills` and used by Claude Code, or run
directly as a shell script.

> **Not affiliated with Anthropic. Use at your own risk.** The scripts change systemd user
> configuration, enable linger (which needs sudo), and edit nothing else, but read them before running.

## Requirements

- Linux with systemd and a user manager (mainstream distros)
- Claude Code with the native installer (binary at `~/.local/bin/claude`), version with the
  `remote-control` subcommand
- Logged in with a claude.ai account that has a subscription (an API key is not enough)
- `tmux` (e.g. `sudo apt install tmux`)
- A working directory that Claude has already trusted
- sudo, once, to enable linger

## Install

**1. Via the skills CLI**

```bash
npx skills add farghees/claude-rc-vps-setup
```

Then ask Claude: "set up Remote Control on this VPS".

**2. Manually**

```bash
git clone https://github.com/farghees/claude-rc-vps-setup
mkdir -p ~/.claude/skills && cp -r claude-rc-vps-setup/skills/claude-rc-vps-setup ~/.claude/skills/
```

**3. Run the script directly**

```bash
bash ~/.claude/skills/claude-rc-vps-setup/scripts/install.sh --name my-vps
```

`--name` is the label shown on claude.ai/code (default: hostname). `--workdir <dir>` sets the
working directory (default: `$HOME`).

## First-time consent (once)

The first run stops at `Enable Remote Control? (y/n)`. It must be answered in a real terminal:

```bash
tmux attach -t rc     # type y, press Enter
# detach with Ctrl-b then d   (do NOT press Ctrl-c, that stops the session)
```

## Environment gotcha: telemetry opt-outs

`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` and `DISABLE_TELEMETRY` make `remote-control` exit with
an error. Remove them from `~/.claude/settings.json` (`env` block) and from your shell profile.
The unit clears them for its own process only, and `install.sh` refuses to continue while they
are in `settings.json`.

## Verify

```bash
systemctl --user status claude-rc
systemctl --user is-enabled claude-rc
loginctl show-user "$USER" -p Linger        # Linger=yes
tmux ls
tmux attach -r -t rc                        # read-only view; detach with Ctrl-b, then d
```

Then look for the session name at https://claude.ai/code.

## Uninstall

```bash
bash ~/.claude/skills/claude-rc-vps-setup/scripts/uninstall.sh                  # keeps linger
bash ~/.claude/skills/claude-rc-vps-setup/scripts/uninstall.sh --disable-linger # also disables linger
```

Claude Code and `~/.claude` are not touched.

## Repository layout

```
skills/claude-rc-vps-setup/
  SKILL.md                  skill instructions, troubleshooting table
  scripts/install.sh        prerequisites, linger, writes unit, starts it
  scripts/uninstall.sh      stops, disables and removes the unit
  templates/claude-rc.service
```

More detail and troubleshooting are in `skills/claude-rc-vps-setup/SKILL.md`.

## License

MIT. See [LICENSE](LICENSE).
