---
name: claude-rc-vps-setup
description: Set up Claude Code Remote Control (claude remote-control) on a Linux VPS so it runs 24/7 and survives reboots, using a systemd user unit and a detached tmux session. Use when the user asks to set up or keep Claude Code Remote Control running on a VPS, "RC with tmux and systemd", "make claude remote-control survive reboot", "control my VPS Claude from claude.ai/code or the phone app", or when a Remote Control session on a server has dropped or will not start.
---

# Claude Code Remote Control on a VPS (tmux + systemd user unit)

This sets up `claude remote-control` as a service on a Linux VPS. The session then shows up at
claude.ai/code and in the Claude mobile app, and it comes back after a reboot without anyone logging in.

Everything below was verified on a working host with Claude Code 2.1.322 and tmux 3.2a.
Anything that was not re-tested is marked as such.

## Prerequisites

1. Linux with systemd and a user manager (any mainstream distro).
2. Claude Code installed, native installer preferred, so the binary is at `~/.local/bin/claude`.
   Check: `command -v claude && claude --version`. Version must include the `remote-control` subcommand
   (`claude remote-control --help`).
3. Logged in with a **claude.ai account that has a subscription**. An API-key login is not enough.
   Check: `claude auth status`.
4. `tmux` installed (e.g. `sudo apt install tmux` on Debian-based systems).
5. A working directory that Claude has already trusted (see step 2 below).
6. Sudo access once, to enable linger.

## Quick path

```bash
# 1. Make sure no telemetry opt-outs are in settings (see "Environment gotchas")
# 2. Trust the working directory once (accept the prompt, then /exit)
cd ~ && claude
# 3. Install
bash ~/.claude/skills/claude-rc-vps-setup/scripts/install.sh --name <rc-name>
# 4. First-time consent (only once): attach, type y, Enter, detach with Ctrl-b then d
tmux -L claude-rc attach -t rc
```

`--name` is the label shown on claude.ai/code. It defaults to the hostname. `--workdir <dir>` picks
a different working directory (default `$HOME`).

**Why `-L claude-rc`:** the session runs on its own tmux socket, not the user's default tmux server.
Every tmux command for this session must carry `-L claude-rc`, or it will look at the wrong server.

## Upgrading from the default-socket version

Earlier versions of this unit ran `tmux new -d -s rc` on the default tmux server. Upgrade like this:

1. Re-run `bash ~/.claude/skills/claude-rc-vps-setup/scripts/install.sh --name <rc-name>`. It rewrites
   the unit (the old unit is backed up) and restarts it on the `claude-rc` socket.
2. If an old `rc` session is still on the default server, remove it, but only if it is the Remote
   Control one. Check first with `tmux ls` and `tmux capture-pane -p -t rc | tail -n 5`, then run
   `tmux kill-session -t rc`.

The dedicated socket and the boot network wait were added after the reference host was verified.
They have not yet been tested on a live host, so run the reboot test in the verification section.

## What gets installed

| Piece | Location | Purpose |
|---|---|---|
| systemd user unit | `~/.config/systemd/user/claude-rc.service` | Starts and stops the session, enabled at boot |
| detached tmux session | dedicated tmux server on socket `claude-rc`, session name `rc` | Keeps `claude remote-control` running with no terminal |
| linger | `loginctl enable-linger $USER` | User manager (and so the unit) starts at boot, no login needed |

The unit's `ExecStart` is essentially:

```
ExecStartPre  wait up to 60s for DNS (api.anthropic.com), always continues
ExecStartPre  tmux -L claude-rc kill-server        (clears an old server on that socket)
ExecStart     tmux -L claude-rc new -d -s rc "env -u DISABLE_TELEMETRY -u CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC <claude> remote-control --name <rc-name>"
ExecStop      tmux -L claude-rc kill-server
```

`templates/claude-rc.service` is the template. `scripts/install.sh` fills in the absolute paths
for tmux and claude, the working directory and the name, so nothing is hardcoded to a user.

## Step by step (manual equivalent of install.sh)

1. **Check the environment.** Remove `DISABLE_TELEMETRY` and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`
   from the `env` block of `~/.claude/settings.json` and from shell profiles. See the gotchas below.
2. **Trust the directory.** `cd <workdir> && claude`, accept the trust prompt, then `/exit`.
3. **Write the unit.** Copy `templates/claude-rc.service` to `~/.config/systemd/user/claude-rc.service`,
   replacing `__TMUX__`, `__CLAUDE__`, `__WORKDIR__` and `__RC_NAME__` with absolute paths and the name.
   Get the paths with `command -v tmux` and `readlink -f "$(command -v claude)"`.
4. **Enable linger.** `sudo loginctl enable-linger "$USER"`. Check with `loginctl show-user "$USER" -p Linger`
   (should print `Linger=yes`).
5. **Start.** `systemctl --user daemon-reload && systemctl --user enable --now claude-rc.service`.
6. **Answer the first-run consent** (step 4 in the quick path). The unit's session stops at
   `Enable Remote Control? (y/n)` until someone answers it. Use `tmux -L claude-rc attach -t rc`.
7. **Verify** (next section).

## First-run consent

The first run prints `Enable Remote Control? (y/n)`. It has to be answered at a real terminal:

- `tmux -L claude-rc attach -t rc`, type `y`, press Enter.
- Detach with **Ctrl-b, then d**. Do **not** press Ctrl-c. That stops the session.

Piping `y` into the command does not work: the feature-flag check runs before the prompt, so the
piped input never gets there and the command exits. Redirecting stdin from `/dev/null` also
stops at the prompt.

On the reference host, the session reconnected after a reboot with no prompt recorded, so consent
appears to be one-time. Re-check after your own reboot test.

## Environment gotchas

These are the two blockers that were actually hit:

- **`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`** set in the environment makes `remote-control` exit
  with status 1: "requires feature-flag evaluation, which is disabled because ... is set".
- **`DISABLE_TELEMETRY`** does the same. It was found exported in the shell, and it was also present in
  `~/.claude/settings.json` `env`.

What to do:

- Remove both keys from `~/.claude/settings.json` `env`. **The unit cannot clear these.** It only clears
  them for its own `claude` process (`env -u`), and settings.json is read by Claude itself.
  `install.sh` refuses to continue while they are in settings.json.
- Remove them from `~/.bashrc`, `~/.profile` or `~/.bash_profile` too, if you also run Remote Control by hand.
- Do **not** remove the other keys (e.g. `API_TIMEOUT_MS`, `DISABLE_ERROR_REPORTING`). They were left in
  place on the reference host and did not block the start.
- Why the unit still uses `env -u`: a tmux server that is already running passes its own global
  environment to new sessions, not the unit's. The `env -u` inside the command covers that case.

## Verification

```bash
systemctl --user status claude-rc               # active (exited or running) with no failure
systemctl --user is-enabled claude-rc           # enabled
loginctl show-user "$USER" -p Linger            # Linger=yes
tmux -L claude-rc ls                            # rc: 1 windows (...)
tmux -L claude-rc attach -r -t rc               # read-only view; detach with Ctrl-b, then d
```

Then open claude.ai/code (or the Claude app, Code tab). The session should be listed under the name you
chose. For a full test, reboot the VPS, reconnect, and check again. `-r` on `attach` is read-only,
so a stray keypress cannot reach the session.

Logs: the tmux pane is the log.

```bash
tmux -L claude-rc capture-pane -p -t rc | tail -n 40   # last lines without attaching
journalctl --user -u claude-rc -n 50           # systemd side (start/stop events)
```

## Day-to-day commands

| Task | Command |
|---|---|
| Restart the session | `systemctl --user restart claude-rc` |
| Stop it | `systemctl --user stop claude-rc` |
| Start it | `systemctl --user start claude-rc` |
| Disable at boot | `systemctl --user disable claude-rc` |
| Change the name or directory | re-run `install.sh --name ... --workdir ...` (it backs up the old unit) |
| Update Claude Code | update it, then `systemctl --user restart claude-rc` |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `remote-control` exits 1: "requires feature-flag evaluation ... CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC is set" | Opt-out present in env or settings.json | Remove it from `settings.json` `env` and from shell profiles; restart the unit |
| Same message naming `DISABLE_TELEMETRY` | Same, for the other key | Same fix. Run `grep -rn DISABLE_TELEMETRY ~/.claude/settings.json ~/.bashrc ~/.profile` |
| Session stuck at `Enable Remote Control? (y/n)` | First-run consent not answered | `tmux -L claude-rc attach -t rc`, type `y`, Enter, then Ctrl-b d |
| `y` piped in does nothing; process exits | The feature-flag check runs first; the piped input never reaches the prompt | Answer at a real terminal (above) |
| "must be logged in with a Claude account that has a subscription" | Logged in with an API key, or not logged in | `claude auth status`; run `claude`, then `/login` with the claude.ai account |
| Session asks to trust the folder and does nothing | Working directory not trusted | `cd <workdir> && claude`, accept, `/exit`; then restart the unit |
| Service active, but nothing at claude.ai/code | Consent not given, or `remote-control` exited inside tmux | `tmux -L claude-rc ls`; if `rc` is missing, `journalctl --user -u claude-rc -n 50`; check the pane |
| Session gone after reboot | Linger not enabled, so the user manager does not start at boot | `sudo loginctl enable-linger "$USER"`; check `loginctl show-user "$USER" -p Linger` |
| `Failed to connect to bus` for `systemctl --user` over SSH | No `XDG_RUNTIME_DIR` in the SSH session | `export XDG_RUNTIME_DIR=/run/user/$(id -u)` |
| `claude: command not found` in the unit's logs | Unit used a bare `claude`, or the path changed after an update | Re-run `install.sh` so the absolute path is rewritten |
| `duplicate session: rc` when starting | A manual `rc` session already exists on the `claude-rc` socket | The unit's `ExecStartPre` kills that server. To clear it by hand: `tmux -L claude-rc kill-server` |
| Session drops when the VPS is idle or suspended | The VPS is asleep or offline | Use an always-on VPS. Remote Control runs locally: when this machine stops, the session stops |
| Unit shows `active` after claude crashed | `Restart=no`: tmux closes when claude exits, and systemd may still report the unit as active | Check `tmux -L claude-rc ls` and the `rc` pane. Not tested on another host; switching to `Restart=on-failure` is an untested option |
| Claude asks for input in an unexpected folder | The directory was not the one you meant | Set `WorkingDirectory` with `install.sh --workdir <dir>` |
| unit shows `inactive` but Remote Control is running / systemd lost track | The session was started on the shared default tmux server. `new -d` joined that server and exited, so systemd lost the process | Use the dedicated socket: re-run `install.sh` (it writes `-L claude-rc`), then check with `tmux -L claude-rc ls` |
| fails at boot, works when restarted manually | Network (DNS) not ready when the unit started | The `ExecStartPre` wait loop covers this (up to 60s). If it still fails, check `journalctl --user -u claude-rc -b` for DNS errors |
| `claude` not found from cron, scripts or other non-interactive shells | Non-interactive shells skip `~/.bashrc`, so the PATH change from the installer is missing | Use the absolute path, `~/.local/bin/claude`, in cron jobs and scripts |

## Uninstall

```bash
bash ~/.claude/skills/claude-rc-vps-setup/scripts/uninstall.sh                  # keeps linger
bash ~/.claude/skills/claude-rc-vps-setup/scripts/uninstall.sh --disable-linger # also turns linger off (affects all user services)
```

This stops the session, disables and removes the unit, and resets the failed state. Claude Code itself
and `~/.claude` are not touched.

## Files in this skill

- `scripts/install.sh`: prerequisite checks, linger, writes the unit from the template, enables and
  starts it, checks the consent state, prints verification commands. Idempotent. Run with `--help`.
- `scripts/uninstall.sh`: reverses the install.
- `templates/claude-rc.service`: the unit template (placeholders `__TMUX__`, `__CLAUDE__`, `__WORKDIR__`, `__RC_NAME__`).
