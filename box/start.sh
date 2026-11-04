#!/bin/sh
# start.sh <command...>: runs the command with GH_TOKEN taken alone from the secrets env file (FCODE_SECRETS_ENV, default
# /run/instabox/secrets/env; on the Oracle VM a tmpfiles link to ~/.config/fcode/secrets.env), the file a login shell sources.
# The one loader for the fcoding service (install.sh's ExecStart), every harness session server.mjs starts and fcode-git-sync (CONTRACT A3).
# The file is read as DATA, never sourced or run, and the whole file must pass a strict grammar or there is no token (fail closed):
# - a regular file only (a FIFO is refused), at most 65536 bytes (one byte more: no token), no NUL byte; CRs are dropped first;
# - every line that is not blank or a comment (# after optional spaces) is `[export ]NAME=VALUE` with optional spaces around it,
#   NAME [A-Za-z_][A-Za-z0-9_]*, VALUE '...' (no ') | "..." (no " \ $ `) | bare (no ' " space \ $ ` #). So multiline values,
#   heredocs, unbalanced quotes, expansions and commands all mean no token.
# - then the last GH_TOKEN line, its quotes stripped, must be 1-255 of [A-Za-z0-9_].
# An inherited GH_TOKEN is always dropped, so a rotated token reaches the next start. Nothing is printed or written, no other variable
# is taken, and the token is never an argument. No file or no token: the command runs without it.
f=${FCODE_SECRETS_ENV:-/run/instabox/secrets/env}
unset GH_TOKEN
r() { head -c 65537 "$f" </dev/null 2>/dev/null; }
R='^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=('\''[^'\'']*'\''|"[^"\$`]*"|[^'\''"[:space:]\$`#]*)[[:space:]]*$'
if [ -f "$f" ] && [ -r "$f" ]; then
  n=$(r | wc -c | tr -d ' ')
  if [ "$n" -le 65536 ] && [ "$(r | tr -d '\000' | wc -c | tr -d ' ')" = "$n" ] &&
    ! r | tr -d '\r' | grep -Ev '^[[:space:]]*(#.*)?$' | grep -Eqv "$R"; then
    t=$(r | tr -d '\r' | sed -n -E '/^[[:space:]]*(export[[:space:]]+)?GH_TOKEN=/{s///;s/[[:space:]]+$//;p;}' | tail -n 1)
    case $t in
      \"*\") t=${t#\"}; t=${t%\"} ;;
      \'*\') t=${t#\'}; t=${t%\'} ;;
    esac
    case $t in
      '' | *[!A-Za-z0-9_]*) ;;
      *) if [ "${#t}" -le 255 ]; then GH_TOKEN=$t; export GH_TOKEN; fi ;;
    esac
  fi
fi
unset -f r
unset f n t R
exec "$@"
