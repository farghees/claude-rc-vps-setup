#!/usr/bin/env bash
# Install Claude Code Remote Control as a systemd user service running in tmux session "rc"
# on its own tmux socket ("claude-rc", so it never shares a tmux server with other sessions).
# Idempotent: safe to re-run. Overwrites the unit (keeping a timestamped backup if it changed).
#
# Usage:
#   install.sh [--name <rc-name>] [--workdir <dir>]
#     --name     name shown on claude.ai/code (default: $(hostname))
#     --workdir  directory the session runs in (default: $HOME); must be trusted by claude
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../templates/claude-rc.service"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/claude-rc.service"
ME="${USER:-$(id -un)}"

RC_NAME="$(hostname)"
WORKDIR="$HOME"

say()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name)    RC_NAME="${2:?--name needs a value}"; shift 2 ;;
    --workdir) WORKDIR="${2:?--workdir needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# ---------- 1. Prerequisites ----------
say "Checking prerequisites"
[ "$(uname -s)" = Linux ] || die "Linux with systemd is required."
command -v systemctl >/dev/null 2>&1 || die "systemd not found."
systemctl --user show-environment >/dev/null 2>&1 \
  || die "systemd user manager not reachable. Over SSH try: export XDG_RUNTIME_DIR=/run/user/\$(id -u)"

TMUX_BIN="$(command -v tmux 2>/dev/null || true)"
[ -n "$TMUX_BIN" ] || die "tmux is not installed. Install it (e.g. sudo apt install tmux) and re-run."

CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
[ -n "$CLAUDE_BIN" ] || CLAUDE_BIN="$HOME/.local/bin/claude"   # native installer default
[ -x "$CLAUDE_BIN" ] || die "claude not found. Install Claude Code first, log in, then re-run."
# Keep the stable launcher path (e.g. ~/.local/bin/claude). Do NOT resolve symlinks: the launcher
# points at a versioned binary under ~/.local/share/claude/versions/, which is removed on auto-update.
case "$CLAUDE_BIN" in
  /*) ;;
  *) CLAUDE_BIN="$(pwd)/$CLAUDE_BIN" ;;
esac

[[ "$RC_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "--name may only contain letters, digits, '.', '_' and '-'."
[ -d "$WORKDIR" ] || die "--workdir does not exist: $WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd)"

echo "tmux:   $TMUX_BIN"
echo "claude: $CLAUDE_BIN ($("$CLAUDE_BIN" --version 2>/dev/null || echo unknown version))"
echo "name:   $RC_NAME"
echo "dir:    $WORKDIR"

"$CLAUDE_BIN" remote-control --help >/dev/null 2>&1 \
  || die "this Claude Code has no 'remote-control' subcommand. Update Claude Code and re-run."

# Login: Remote Control needs a claude.ai account with a subscription (API-key login is not enough).
if "$CLAUDE_BIN" auth status 2>/dev/null | grep -qi 'loggedIn.*true'; then
  echo "login:  ok"
else
  warn "could not confirm a claude.ai login. Run 'claude auth status'; if not logged in, run 'claude' and use /login."
fi

# Telemetry opt-outs in settings.json cannot be cleared by the unit (it only clears its own process).
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && grep -Eq '"(DISABLE_TELEMETRY|CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC)"' "$SETTINGS"; then
  die "$SETTINGS sets DISABLE_TELEMETRY or CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC in its env block. Remove those keys, then re-run. Remote Control will not start while they are set."
fi
for rc in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile"; do
  if [ -f "$rc" ] && grep -Eq 'DISABLE_TELEMETRY|CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC' "$rc"; then
    warn "$rc exports a telemetry opt-out. The unit clears it for its own process, but remove it if you run 'claude remote-control' by hand."
  fi
done

# Trust: a folder must be trusted before remote-control will run there (best-effort check).
TRUSTED="$(python3 - "$WORKDIR" <<'PY' 2>/dev/null || echo unknown
import json, os, sys
try:
    d = json.load(open(os.path.expanduser("~/.claude.json")))
    print("yes" if d.get("projects", {}).get(sys.argv[1], {}).get("hasTrustDialogAccepted") else "no")
except Exception:
    print("unknown")
PY
)"
if [ "$TRUSTED" = no ]; then
  warn "$WORKDIR is not trusted yet. Run: cd '$WORKDIR' && claude   (accept the trust prompt, then exit with /exit)"
fi

# ---------- 2. Linger (starts the user manager at boot, without a login) ----------
say "Checking linger"
if [ "$(loginctl show-user "$ME" -p Linger --value 2>/dev/null || echo no)" = yes ]; then
  echo "linger: already enabled for $ME"
else
  sudo loginctl enable-linger "$ME" || die "could not enable linger (needs sudo). Run: sudo loginctl enable-linger $ME"
  echo "linger: enabled for $ME"
fi

# ---------- 3. Write unit ----------
say "Writing unit $UNIT"
mkdir -p "$UNIT_DIR"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
sed -e "s|__TMUX__|$TMUX_BIN|g" \
    -e "s|__CLAUDE__|$CLAUDE_BIN|g" \
    -e "s|__WORKDIR__|$WORKDIR|g" \
    -e "s|__RC_NAME__|$RC_NAME|g" \
    "$TEMPLATE" > "$TMP"
if [ -f "$UNIT" ] && ! cmp -s "$TMP" "$UNIT"; then
  cp "$UNIT" "$UNIT.bak-$(date +%Y%m%d%H%M%S)"
  echo "existing unit differed; backed up to $UNIT.bak-*"
fi
install -m 0644 "$TMP" "$UNIT"

# ---------- 4. Enable and start ----------
say "Enabling and (re)starting claude-rc"
systemctl --user daemon-reload
systemctl --user enable claude-rc.service
systemctl --user restart claude-rc.service
sleep 6

# ---------- 5. Check the session and the first-run consent ----------
say "Checking session"
if tmux -L claude-rc has-session -t rc 2>/dev/null; then
  PANE="$(tmux -L claude-rc capture-pane -p -t rc 2>/dev/null || true)"
  if grep -qi 'y/n' <<<"$PANE"; then
    cat <<EOF
Remote Control is waiting for first-time consent ("Enable Remote Control? (y/n)").
This must be answered at a real terminal; piping 'y' in does not work. Do this once:
  tmux -L claude-rc attach -t rc      # type y, press Enter
  then detach with:      Ctrl-b, then d   (do NOT press Ctrl-c: that stops the session)
EOF
  elif grep -qi 'connected' <<<"$PANE"; then
    echo "Remote Control is connected."
  else
    echo "Session 'rc' is running. Last lines of the pane:"
    tail -n 8 <<<"$PANE"
  fi
else
  warn "tmux session 'rc' not found on socket claude-rc. Check: systemctl --user status claude-rc ; journalctl --user -u claude-rc -n 50"
fi

say "Verify later"
cat <<EOF
  systemctl --user status claude-rc
  loginctl show-user $ME -p Linger
  tmux -L claude-rc ls
  tmux -L claude-rc attach -r -t rc   # read-only view; detach with Ctrl-b, then d
  Then look for '$RC_NAME' at https://claude.ai/code
EOF
