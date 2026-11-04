#!/bin/sh
# start.sh <command...>: runs the command with GH_TOKEN taken alone from the secrets env file (FCODE_SECRETS_ENV, default
# /run/instabox/secrets/env; on the Oracle VM a tmpfiles link to ~/.config/fcode/secrets.env), the file a login shell sources.
# The one loader for both the fcoding service (install.sh's ExecStart) and every harness session server.mjs starts (CONTRACT A3).
# The file is read as DATA, never sourced or run: a regular file only (a FIFO is refused), at most 64 KiB, the last
# `[export ]GH_TOKEN=` line, one pair of surrounding quotes stripped, and the value must be 1-255 of [A-Za-z0-9_]; anything else
# is no token. An inherited GH_TOKEN is always dropped, so a rotated token reaches the next start. Nothing is printed or written,
# no other variable is taken, and the token is never an argument. No file or no token: the command runs without it.
f=${FCODE_SECRETS_ENV:-/run/instabox/secrets/env}
unset GH_TOKEN
if [ -f "$f" ] && [ -r "$f" ]; then
  t=$(head -c 65536 "$f" </dev/null 2>/dev/null | sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?GH_TOKEN=//p' 2>/dev/null | tail -n 1 | tr -d '\r')
  case $t in
    \"*\") t=${t#\"}; t=${t%\"} ;;
    \'*\') t=${t#\'}; t=${t%\'} ;;
  esac
  case $t in
    '' | *[!A-Za-z0-9_]*) ;;
    *) if [ "${#t}" -le 255 ]; then GH_TOKEN=$t; export GH_TOKEN; fi ;;
  esac
  unset t
fi
unset f
exec "$@"
