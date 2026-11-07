#!/bin/sh
# start.sh [-v] <command...>: runs the command with GH_TOKEN taken alone from the secrets env file (FCODE_SECRETS_ENV, default
# /run/instabox/secrets/env; on the Oracle VM a tmpfiles link to ~/.config/fcode/secrets.env), the file a login shell sources.
# The one loader for the fcoding service (install.sh's ExecStart, which passes -v), every harness session server.mjs starts and
# fcode-git-sync (CONTRACT A3). The file is read ONCE, as DATA (head | awk; never sourced or run), and the whole file must pass a
# strict grammar or there is no token (fail closed). The grammar guarantees that the token is the file's own last GH_TOKEN line
# and that a shell sourcing the file (bash, interactive or not, or dash) ends the source with that same GH_TOKEN (a CRLF file excepted, below):
# - a regular file only (FIFO, directory: refused), at most 65536 bytes (the read stops at 65537: one byte more = no token);
# - one trailing CR per line is dropped (a CRLF file gives the intended token; a shell keeps every CR: in the value, or as a
#   command named CR after a blank or on an empty line); then every line holds only tab, 0x20-0x7E and 0x80-0xFF (NUL, other
#   control bytes, DEL, a CR elsewhere: not accepted, comments included);
# - a line that is blank or `#...` after spaces/tabs is skipped; every other line is `[export<blanks>]NAME=VALUE` with spaces/tabs
#   only around it, NAME [A-Za-z_][A-Za-z0-9_]* but never OPTIND, HISTCMD, MAILCHECK, RANDOM, SRANDOM or SECONDS (bash evaluates
#   an assignment to those as arithmetic, MAILCHECK in an interactive shell, which can assign other variables or run commands;
#   dash rejects OPTIND), VALUE '...' (no ') | "..." (no " \ $ `) | bare [A-Za-z0-9_./:@%+,=~^-] and bytes 0x80-0xFF only. So
#   multiline values, heredocs, unbalanced quotes, expansions, `;` `|` `&` and every command mean no token;
# - then the last GH_TOKEN line, its quotes removed, must be 1-255 of [A-Za-z0-9_];
# - head or awk missing, failing or killed: no token (never a partial read).
# Inherited GH_TOKEN and GITHUB_TOKEN are always dropped, so a rotated token reaches the next start. Nothing is written; without -v
# nothing is printed; with -v one stderr line `fcoding start.sh: secrets file <path>: <status>` (ok | missing | not-a-file |
# unreadable | too-big | line-N | no-GH_TOKEN | bad-GH_TOKEN | error), never a value. No other variable is taken, and the token is
# never an argument. No file or no token: the command runs without it. set +x: an inherited xtrace (SHELLOPTS) must never trace the token.
set +x
v=; [ "${1-}" = -v ] && { v=1; shift; }
f=${FCODE_SECRETS_ENV:-/run/instabox/secrets/env}
unset GH_TOKEN GITHUB_TOKEN
st=missing; t=
[ ! -e "$f" ] || st=not-a-file
if [ -f "$f" ]; then
  st=unreadable
  if [ -r "$f" ]; then
    out=$({ { head -c 65537 "$f" </dev/null; printf '\nH%s\n' "$?"; } | LC_ALL=C awk -v q="'" '
      function chk(s,  c, body, name, val) {
        sub(/\r$/, "", s)
        if (s !~ /^[\t -~\200-\377]*$/) return 0
        if (s ~ /^[ \t]*(#.*)?$/) return 1
        if (!match(s, /^[ \t]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/)) return 0
        name = substr(s, 1, RLENGTH - 1); sub(/^[ \t]*(export[ \t]+)?/, "", name)
        if (name ~ /^(OPTIND|HISTCMD|MAILCHECK|RANDOM|SRANDOM|SECONDS)$/) return 0
        val = substr(s, RLENGTH + 1); sub(/[ \t]+$/, "", val)
        c = substr(val, 1, 1); body = val
        if (c == q || c == "\"") {
          if (length(val) < 2 || substr(val, length(val), 1) != c) return 0
          body = substr(val, 2, length(val) - 2)
          if (index(body, c) || (c == "\"" && body ~ /[\\$`]/)) return 0
        } else if (val !~ /^[-A-Za-z0-9_.\/:@%+,=~^\200-\377]*$/) return 0
        if (name == "GH_TOKEN") { tok = body; seen = 1 }
        return 1
      }
      NR > 1 { n += length(prev) + 1; if (!bad && !chk(prev)) bad = NR - 1 }
      { prev = $0 }
      END {
        if (prev != "H0") st = "error"
        else if (n - 1 > 65536) st = "too-big"; else if (bad) st = "line-" bad; else if (!seen) st = "no-GH_TOKEN"
        else if (tok == "" || length(tok) > 255 || tok !~ /^[A-Za-z0-9_]+$/) st = "bad-GH_TOKEN"; else st = "ok"
        printf "%s %s\n", st, (st == "ok" ? tok : "")
      }'; } 2>/dev/null)
    rc=$?
    st=${out%% *}; t=${out#* }
    [ "$rc" = 0 ] && [ -n "$st" ] || st=error
    [ "$st" = ok ] && [ -n "$t" ] && { GH_TOKEN=$t; export GH_TOKEN; }
  fi
fi
[ -z "$v" ] || printf 'fcoding start.sh: secrets file %s: %s\n' "$f" "$st" >&2
unset v f st t out rc
exec "$@"
