#!/usr/bin/env bash
# Install fcoding ON the box. Run from the folder that holds server.mjs. Idempotent.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP=/data/home/fcoding
CFG=/data/home/.fcoding
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

command -v node >/dev/null || { echo "node not found (need Node 22)" >&2; exit 1; }
command -v tmux >/dev/null || echo "warning: tmux not found; install it before using fcoding" >&2

mkdir -p "$APP"
[ "$SRC" = "$APP" ] || install -m 644 "$SRC/server.mjs" "$APP/server.mjs"

mkdir -p "$CFG"
chmod 700 "$CFG"
[ ! -f "$CFG/config.json" ] || chmod 600 "$CFG/config.json"
rm -f "$CFG/sessions.json" # older versions stored logins on disk; logins now live in memory only

# KillMode=process: the tmux server (and every harness session) is started by this service;
# restarting or crashing the service must not take it down. StartLimitIntervalSec=0: always restart.
# PATH for the harnesses is set by server.mjs itself (~/.local/bin, ~/.bun/bin, system dirs).
mkdir -p "$UNIT_DIR"
cat > "$UNIT_DIR/fcoding.service" <<UNIT
[Unit]
Description=fcoding (tmux harness chat server)
After=network.target
StartLimitIntervalSec=0

[Service]
Environment=LANG=C.UTF-8
Environment=PC_CONFIG_DIR=$CFG
ExecStart=$(command -v node) $APP/server.mjs
KillMode=process
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
UNIT

loginctl enable-linger "$(id -un)" 2>/dev/null || true
systemctl --user daemon-reload
systemctl --user enable fcoding.service
# without a valid config.json the server refuses to start: start it after --set-password
if [ -f "$CFG/config.json" ]; then systemctl --user restart fcoding.service; fi

cat <<MSG

fcoding installed (port 7681).
Set the login password (the server picks one and prints it ONCE):
  PC_CONFIG_DIR=$CFG node $APP/server.mjs --set-password </dev/null
Or choose your own without leaving it in shell history:
  read -rs PW; printf '%s\n' "\$PW" | PC_CONFIG_DIR=$CFG node $APP/server.mjs --set-password; unset PW
Then (first install only): systemctl --user restart fcoding
A running server picks a new password up by itself (all old logins are dropped).
Projects: edit $CFG/config.json ("projects": {"name": "/abs/dir"}); the server reloads it by itself.
Any restart of the service logs every device out (logins live in memory only).
Publish:  instabox port publish <box> 7681
MSG
