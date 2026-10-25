#!/usr/bin/env bash
# fcode-update: keep omp, claude, codex, opencode and cmd (Command Code) up to date.
# Usage: fcode-update [tool ...]   (default: all five)
# - a tool whose process is running right now is skipped and retried next run
# - one log line per tool: ~/.local/state/fcode-update/log (last 500 lines)
# - status.json {tool:{from,to,at,result,error}} next to it, written atomically
# - one run at a time (flock); every command has a timeout; no credentials touched
set -u
export PATH="$HOME/.local/bin:$HOME/.bun/bin:/usr/local/bin:/usr/bin:/bin"
export LC_ALL=C NO_UPDATE_NOTIFIER=1 npm_config_update_notifier=false

STATE="${FCODE_UPDATE_STATE:-$HOME/.local/state/fcode-update}"
LOG="$STATE/log"
STATUS="$STATE/status.json"
ALL="omp claude codex opencode cmd"
TOOLS="${*:-$ALL}"

mkdir -p "$STATE"
for t in $TOOLS; do
  case " $ALL " in *" $t "*) ;; *) echo "fcode-update: unknown tool '$t' (valid: $ALL)" >&2; exit 2 ;; esac
done

exec 9>"$STATE/lock"
flock -n 9 || { echo "fcode-update: another run is active, exiting"; exit 0; }

# every external command: timeout, and without the lock fd so a leftover child cannot hold the lock
x() { local t=$1; shift; timeout -k 10 "$t" "$@" 9>&-; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
oneline() { tr '\n\r\t' '   ' | tr -s ' ' | cut -c1-300; }

NM=$(x 30 npm root -g 2>/dev/null) || NM=/usr/local/lib/node_modules
[ -n "$NM" ] || NM=/usr/local/lib/node_modules

pkg_of() {
  case $1 in
    claude) echo @anthropic-ai/claude-code ;;
    codex) echo @openai/codex ;;
    opencode) echo @opencode/cli ;;
    cmd) echo command-code ;;
  esac
}

# record tool from to result [error]  -> log line + atomic status.json
record() {
  local tool=$1 from=$2 to=$3 result=$4 err at old tmp
  err=$(printf %s "${5:-}" | oneline)
  at=$(now)
  printf '%s %s %s -> %s %s%s\n' "$at" "$tool" "${from:-?}" "${to:-?}" "$result" "${err:+ ($err)}" >>"$LOG"
  tail -n 500 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  old=$(jq -c . "$STATUS" 2>/dev/null) || old='{}'
  tmp=$(mktemp "$STATE/status.XXXXXX") || return
  printf '%s' "$old" | jq --arg t "$tool" --arg f "$from" --arg to "$to" --arg at "$at" --arg r "$result" --arg e "$err" \
    '.[$t] = {from:$f, to:$to, at:$at, result:$r, error:(if $e == "" then null else $e end)}' >"$tmp" \
    && chmod 644 "$tmp" && mv "$tmp" "$STATUS" || rm -f "$tmp"
}

installed() {
  case $1 in
    omp) x 30 omp --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*' | head -1 ;;
    *) x 30 node -p 'require(process.argv[1]).version' "$NM/$(pkg_of "$1")/package.json" 2>/dev/null ;;
  esac
}

# latest <tool> <installed>: prints the latest version ("newer" = omp says an update exists, version unknown)
latest() {
  local out
  case $1 in
    omp)
      out=$(x 60 omp update --check 2>&1 </dev/null) || { echo "$out"; return 1; }
      if printf %s "$out" | grep -qi 'up to date'; then echo "$2"; return 0; fi
      printf %s "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | grep -vxF "$2" | sort -V | tail -1 | grep . || echo newer
      ;;
    *)
      out=$(x 60 npm view "$(pkg_of "$1")" version 2>&1 </dev/null) || { echo "$out"; return 1; }
      printf %s "$out" | tail -1
      ;;
  esac
}

# newer <installed> <latest>: true when latest is a real upgrade (never downgrades)
newer() {
  [ "$1" != "$2" ] || return 1
  [ "$2" = newer ] && return 0
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]
}

# busy <tool>: true when the tool is running right now (exact process name or its install path)
busy() {
  local n f
  case $1 in
    omp) n='omp'; f='' ;;
    claude) n='claude|claude\.exe'; f="$NM/@anthropic-ai/claude-code/" ;;
    codex) n='codex|codex\.js'; f="$NM/@openai/codex/|(^| )/usr/local/bin/codex( |\$)" ;;
    opencode) n='opencode|opencode\.exe'; f="$NM/@opencode/cli/|(^| )/usr/local/bin/opencode( |\$)" ;;
    cmd) n=''; f="$NM/command-code/|(^| )/usr/local/bin/cmd( |\$)" ;;
  esac
  { [ -n "$n" ] && pgrep -x "$n" >/dev/null; } || { [ -n "$f" ] && pgrep -f "$f" >/dev/null; }
}

# do_update <tool> <target>: runs the update and prints its output
do_update() {
  case $1 in
    omp) x 600 omp update 2>&1 </dev/null ;;
    *) sudo -n -H timeout -k 15 1200 npm install -g "$(pkg_of "$1")@$2" --no-audit --no-fund --no-progress --loglevel=error 2>&1 </dev/null 9>&- ;;
  esac
}

failed=0
update_tool() {
  local t=$1 cur lat out new
  cur=$(installed "$t")
  [ -n "$cur" ] || { record "$t" "" "" failed "cannot read installed version"; failed=1; return; }
  lat=$(latest "$t" "$cur") || { record "$t" "$cur" "" failed "latest lookup failed: $lat"; failed=1; return; }
  [ -n "$lat" ] || { record "$t" "$cur" "" failed "empty latest version"; failed=1; return; }
  if ! newer "$cur" "$lat"; then record "$t" "$cur" "$cur" current; return; fi
  if busy "$t"; then record "$t" "$cur" "$lat" skipped_busy; return; fi
  out=$(do_update "$t" "$lat") || { record "$t" "$cur" "$lat" failed "update failed: $(printf %s "$out" | tail -3)"; failed=1; return; }
  new=$(installed "$t")
  if [ -z "$new" ] || [ "$new" = "$cur" ] || { [ "$lat" != newer ] && [ "$new" != "$lat" ]; }; then
    record "$t" "$cur" "${new:-}" failed "version after update is '${new:-unreadable}', expected '$lat'"; failed=1; return
  fi
  record "$t" "$cur" "$new" updated
}

for t in $TOOLS; do update_tool "$t"; done
exit $failed
