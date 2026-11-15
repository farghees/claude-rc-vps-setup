#!/usr/bin/env bash
# Remove the Claude Remote Control service installed by install.sh.
# Leaves Claude Code, its login and ~/.claude untouched.
#
# Usage: uninstall.sh [--disable-linger]
#   --disable-linger  also turn off linger for this user (needs sudo; affects ALL user services)
set -euo pipefail

UNIT="$HOME/.config/systemd/user/claude-rc.service"
ME="${USER:-$(id -un)}"
DISABLE_LINGER=0
case "${1:-}" in
  --disable-linger) DISABLE_LINGER=1 ;;
  "" ) ;;
  -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

echo "==> Stopping and disabling claude-rc"
systemctl --user disable --now claude-rc.service 2>/dev/null || true
tmux -L claude-rc kill-server 2>/dev/null || true

echo "==> Removing unit"
rm -f "$UNIT"
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user reset-failed claude-rc.service 2>/dev/null || true

if [ "$DISABLE_LINGER" = 1 ]; then
  echo "==> Disabling linger for $ME"
  sudo loginctl disable-linger "$ME"
else
  echo "Linger left enabled (other user services may rely on it). Use --disable-linger to turn it off."
fi

echo "Done. Verify: systemctl --user status claude-rc  (should report 'could not be found')"
