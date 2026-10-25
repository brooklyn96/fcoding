#!/usr/bin/env bash
# fcode-update: keep omp, claude, codex, opencode and cmd (Command Code) up to date.
# Usage: fcode-update [tool ...]   (default: all five)
# - a tool whose process is running right now is skipped and retried next run
# - one log line per tool: ~/.local/state/fcode-update/log (last 500 lines)
# - status.json {tool:{from,to,at,result,error}} next to it, written atomically
# - one run at a time (flock); every command has a timeout; no credentials touched
# Sourcing this file only defines the functions (used by the tests).
set -u
export PATH="$HOME/.local/bin:$HOME/.bun/bin:/usr/local/bin:/usr/bin:/bin"
export LC_ALL=C NO_UPDATE_NOTIFIER=1 npm_config_update_notifier=false

STATE="${FCODE_UPDATE_STATE:-$HOME/.local/state/fcode-update}"
LOG="$STATE/log"
STATUS="$STATE/status.json"
ALL="omp claude codex opencode cmd"
NM="${FCODE_UPDATE_NM:-}" # npm global root (override only for tests)

# every external command: timeout, and without the lock fd so a leftover child cannot hold the lock
x() { local t=$1; shift; timeout -k 10 "$t" "$@" 9>&-; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
oneline() { tr '\n\r\t' '   ' | tr -s ' ' | cut -c1-300; }
semver_ok() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; }

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

# latest <tool> <installed>: prints the latest version ("newer" = omp says an update exists, version unknown).
# The value comes from stdout only; on failure the (stderr) text is printed and the return code is 1.
latest() {
  local out err rc
  case $1 in
    omp)
      out=$(x 60 omp update --check 2>&1 </dev/null) || { echo "$out"; return 1; }
      if printf %s "$out" | grep -qi 'up to date'; then echo "$2"; return 0; fi
      printf %s "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | grep -vxF "$2" | sort -V | tail -1 | grep . || echo newer
      ;;
    *)
      err=$(mktemp "$STATE/err.XXXXXX") || return 1
      out=$(x 60 npm view "$(pkg_of "$1")" version 2>"$err" </dev/null); rc=$?
      if [ $rc -ne 0 ]; then cat "$err"; rm -f "$err"; return 1; fi
      rm -f "$err"
      printf %s "$out" | tail -1
      ;;
  esac
}

# newer <installed> <latest>: true when latest is a real upgrade (never downgrades).
# A pre-release (X-beta.1) is older than its own release (X).
newer() {
  local cb=${1%%-*} lb=${2%%-*} cp= lp=
  [ "$2" = newer ] && return 0
  [ "$1" != "$2" ] || return 1
  [[ $1 == *-* ]] && cp=${1#*-}
  [[ $2 == *-* ]] && lp=${2#*-}
  if [ "$cb" != "$lb" ]; then
    [ "$(printf '%s\n%s\n' "$cb" "$lb" | sort -V | tail -1)" = "$lb" ]
    return
  fi
  [ -z "$lp" ] && return 0 # same base: latest is the release, installed is a pre-release
  [ -z "$cp" ] && return 1 # installed is the release, latest is a pre-release
  [ "$(printf '%s\n%s\n' "$cp" "$lp" | sort -V | tail -1)" = "$lp" ]
}

# busy <tool>: true when a process is running from the tool's install path. Works for every bin name:
# a native binary is matched by /proc/<pid>/exe, a node script by the resolved path of its arguments.
# opencode's detached background service ("serve --service") is not a client and is not counted.
busy() {
  local root d pid exe arg r i svc a=()
  case $1 in
    omp) root=$(readlink -f "$(command -v omp)" 2>/dev/null) ;;
    *) root="$NM/$(pkg_of "$1")" ;;
  esac
  [ -n "$root" ] || return 1
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    [ "$pid" = "$$" ] && continue
    exe=$(readlink "$d/exe" 2>/dev/null) || continue
    mapfile -d '' -t a <"$d/cmdline" 2>/dev/null || continue
    case $exe in
      "$root" | "$root"/*) ;;
      */node | */nodejs | */bun)
        r=
        for arg in "${a[@]:1:3}"; do
          [[ $arg == -* ]] && continue
          [[ $arg == /* ]] || arg="$(readlink "$d/cwd" 2>/dev/null)/$arg"
          r=$(readlink -f "$arg" 2>/dev/null)
          case $r in "$root"/*) break ;; esac
          r=
        done
        [ -n "$r" ] || continue
        ;;
      *) continue ;;
    esac
    if [ "$1" = opencode ]; then
      svc=0
      for ((i = 0; i + 1 < ${#a[@]}; i++)); do
        [ "${a[i]}" = serve ] && [ "${a[i + 1]}" = --service ] && svc=1
      done
      [ $svc = 1 ] && continue
    fi
    return 0
  done
  return 1
}

# opencode keeps one shared background service; "status" prints its URL while it runs
oc_service_running() { x 30 opencode service status 2>/dev/null </dev/null | grep -q '^http'; }

# do_update <tool> <target>: runs the update and prints its output
do_update() {
  case $1 in
    omp) x 600 omp update 2>&1 </dev/null ;;
    *) sudo -n -H timeout -k 15 600 npm install -g "$(pkg_of "$1")@$2" --no-audit --no-fund --no-progress --loglevel=error 2>&1 </dev/null 9>&- ;;
  esac
}

failed=0
update_tool() {
  local t=$1 cur lat out new rc svc=0
  cur=$(installed "$t")
  semver_ok "$cur" || { record "$t" "" "" failed "cannot read installed version"; failed=1; return; }
  lat=$(latest "$t" "$cur") || { record "$t" "$cur" "" failed "latest lookup failed: $lat"; failed=1; return; }
  if [ "$lat" != newer ] && ! semver_ok "$lat"; then record "$t" "$cur" "" failed "invalid latest version '$lat'"; failed=1; return; fi
  if ! newer "$cur" "$lat"; then record "$t" "$cur" "$cur" current; return; fi
  if busy "$t"; then record "$t" "$cur" "$lat" skipped_busy; return; fi
  # no client is running: stop the idle opencode service so it restarts on the new version
  if [ "$t" = opencode ] && oc_service_running; then svc=1; x 60 opencode service stop >/dev/null 2>&1 </dev/null; fi
  out=$(do_update "$t" "$lat"); rc=$?
  [ $svc = 1 ] && x 60 opencode service start >/dev/null 2>&1 </dev/null
  [ $rc -eq 0 ] || { record "$t" "$cur" "$lat" failed "update failed: $(printf %s "$out" | tail -3)"; failed=1; return; }
  new=$(installed "$t")
  if [ -z "$new" ] || [ "$new" = "$cur" ] || { [ "$lat" != newer ] && [ "$new" != "$lat" ]; }; then
    record "$t" "$cur" "${new:-}" failed "version after update is '${new:-unreadable}', expected '$lat'"; failed=1; return
  fi
  record "$t" "$cur" "$new" updated
}

main() {
  local TOOLS="${*:-$ALL}" t
  mkdir -p "$STATE"
  for t in $TOOLS; do
    case " $ALL " in *" $t "*) ;; *) echo "fcode-update: unknown tool '$t' (valid: $ALL)" >&2; exit 2 ;; esac
  done

  exec 9>"$STATE/lock"
  flock -n 9 || { echo "fcode-update: another run is active, exiting"; exit 0; }

  [ -n "$NM" ] || NM=$(x 30 npm root -g 2>/dev/null) || NM=
  [ -n "$NM" ] || NM=/usr/local/lib/node_modules

  for t in $TOOLS; do update_tool "$t"; done
  exit $failed
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
