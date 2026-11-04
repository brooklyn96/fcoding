#!/bin/sh
# start.sh <command...>: runs the command with GH_TOKEN taken alone from the secrets env file (FCODE_SECRETS_ENV, default
# /run/instabox/secrets/env; on the Oracle VM a tmpfiles link to ~/.config/fcode/secrets.env), the file a login shell sources.
# The one loader for both the fcoding service (install.sh's ExecStart) and every harness session server.mjs starts (CONTRACT A3).
# The file is sourced in a subshell that hands back GH_TOKEN only: no other variable reaches the command, nothing is printed or
# written to disk, and the token is never an argument. A GH_TOKEN already set wins; no file or no token: the command runs without it.
f=${FCODE_SECRETS_ENV:-/run/instabox/secrets/env}
if [ -z "${GH_TOKEN:-}" ] && [ -r "$f" ]; then
  t=$(. "$f" >/dev/null 2>&1; printf '%s' "${GH_TOKEN:-}")
  if [ -n "$t" ]; then GH_TOKEN=$t; export GH_TOKEN; fi
  unset t
fi
exec "$@"
