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
rm -f "$CFG/sessions.json" # older versions stored logins on disk
# first install: a config with a random cookie secret (devices are paired with fcode-pair, there is no password)
if [ ! -f "$CFG/config.json" ]; then
  (umask 077; node -e '
    const c = { cookieSecret: require("crypto").randomBytes(32).toString("base64"), projects: {}, port: 7681 };
    require("fs").writeFileSync(process.argv[1], JSON.stringify(c, null, 2), { mode: 0o600 });' "$CFG/config.json")
fi
chmod 600 "$CFG/config.json"
# older installs: drop the obsolete passwordHash; every other field (the cookieSecret too) stays. No-op when absent.
strip_password_hash() { # strip_password_hash CONFIG_FILE  (tmp file, full write, fsync, rename; mode 600; the original is kept on any error)
  node -e '
    const fs = require("fs"), f = process.argv[1], tmp = f + ".tmp";
    let c;
    try { c = JSON.parse(fs.readFileSync(f, "utf8")); if (!c || typeof c !== "object" || Array.isArray(c)) throw 0; }
    catch { console.error("config.json không hợp lệ, không sửa"); process.exit(1); }
    if (!Object.hasOwn(c, "passwordHash")) process.exit(0);
    delete c.passwordHash;
    try {
      fs.rmSync(tmp, { force: true });
      const fd = fs.openSync(tmp, "wx", 0o600);
      try { fs.writeFileSync(fd, Buffer.from(JSON.stringify(c, null, 2))); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
      fs.renameSync(tmp, f);
    } catch (e) { fs.rmSync(tmp, { force: true }); console.error("không sửa được config.json: " + (e.code || "lỗi")); process.exit(1); }' "$1"
}
strip_password_hash "$CFG/config.json"
[ ! -f "$CFG/devices.json" ] || chmod 600 "$CFG/devices.json"

# fcode-pair [device name]: prints a one-time 6-digit code for the app (needs the running server)
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/fcode-pair" <<WRAP
#!/bin/sh
exec env PC_CONFIG_DIR="$CFG" "$(command -v node)" "$APP/server.mjs" --pair "\$*"
WRAP
chmod 755 "$HOME/.local/bin/fcode-pair"

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
systemctl --user restart fcoding.service

cat <<MSG

fcoding installed and running (port 7681).
Pair a phone (no password): run on the box
  fcode-pair "iPhone"
and type the 6-digit code into the app within 120 s. Running it again replaces the code.
Paired devices:   PC_CONFIG_DIR=$CFG node $APP/server.mjs --devices
Revoke a device:  PC_CONFIG_DIR=$CFG node $APP/server.mjs --revoke <id>     (or --revoke all)
Projects: edit $CFG/config.json ("projects": {"name": "/abs/dir"}); the server reloads it by itself.
Paired devices survive restarts. Changing cookieSecret in config.json unpairs every device.
Publish:  instabox port publish <box> 7681
MSG
