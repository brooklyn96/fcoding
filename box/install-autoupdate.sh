#!/usr/bin/env bash
# Install the coding-harness auto-update timer for the current user. Safe to re-run.
#   1. fcode-update.sh   -> ~/.local/bin/fcode-update
#   2. fcode-update.service + .timer -> ~/.config/systemd/user, timer enabled
#   3. turns off the built-in self-updaters of Command Code and OpenCode (and claude if not already off)
#      (they run as this user and cannot write to the root-owned npm prefix)
set -euo pipefail

D=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
UNITS="$HOME/.config/systemd/user"

command -v jq >/dev/null || sudo -n apt-get install -y jq >/dev/null
command -v flock >/dev/null || { echo "install-autoupdate: flock is missing (util-linux)" >&2; exit 1; }
sudo -n true 2>/dev/null || { echo "install-autoupdate: passwordless sudo is needed for 'sudo npm install -g'" >&2; exit 1; }

# put <src> <dst> <mode>: copy when different; sets CHANGED=1 when it did
CHANGED=0
put() {
  if [ -f "$2" ] && cmp -s "$1" "$2"; then return; fi
  install -D -m "$3" "$1" "$2"; CHANGED=1; echo "installed $2"
}

# json_set <file> <jq filter>: edit plain JSON in place, only when the result differs
json_set() {
  local f=$1 filter=$2 tmp
  mkdir -p "$(dirname "$f")"
  [ -s "$f" ] || echo '{}' >"$f"
  tmp=$(mktemp "$f.XXXXXX")
  if jq "$filter" "$f" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    if cmp -s "$tmp" "$f"; then rm -f "$tmp"; else chmod --reference="$f" "$tmp"; mv "$tmp" "$f"; echo "updated $f"; fi
  else
    rm -f "$tmp"; echo "warning: $f is not plain JSON, left untouched" >&2
  fi
}

put "$D/fcode-update.sh" "$HOME/.local/bin/fcode-update" 755
put "$D/fcode-update.service" "$UNITS/fcode-update.service" 644
put "$D/fcode-update.timer" "$UNITS/fcode-update.timer" 644
mkdir -p "$HOME/.local/state/fcode-update"

# built-in self-updaters off (our timer does the updating)
# claude: skipped when the box already sets it system-wide (instabox image: /etc/claude-code/managed-settings.json)
grep -qs DISABLE_AUTOUPDATER /etc/claude-code/managed-settings.json \
  || json_set "$HOME/.claude/settings.json" '.env.DISABLE_AUTOUPDATER = "1"'
json_set "$HOME/.commandcode/updates.json" '.autoUpdate = false'
json_set "$HOME/.config/opencode/opencode.json" '.autoupdate = false'

# the user manager must keep running without a login
[ "$(loginctl show-user "$(id -u)" -p Linger --value 2>/dev/null)" = yes ] || sudo -n loginctl enable-linger "$USER"

systemctl --user daemon-reload
systemctl --user enable --now fcode-update.timer
[ "$CHANGED" = 0 ] || systemctl --user restart fcode-update.timer
systemctl --user list-timers fcode-update.timer --no-pager
