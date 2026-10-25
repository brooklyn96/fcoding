#!/usr/bin/env bash
# fcode-update: keep omp, claude and codex up to date.
# Usage: fcode-update [tool ...]                (default: all three)
#        fcode-update --rollback <tool> <version>   switch back (atomic, logged) and hold updates for the tool
#        fcode-update --resume <tool>                allow updates again
#
# npm tools (claude, codex) are never modified in place. Every version is installed into
# its own prefix, /opt/fcode-tools/<tool>/<version>, verified there, and only then made current by one
# atomic symlink switch: /opt/fcode-tools/<tool>/current -> <version>. /usr/local/bin/<bin> point at
# <tool>/current/bin/<bin>. A running process keeps the directory it started from, so no "is it busy"
# check is needed. omp replaces its own binary by atomic rename (new inode), so it needs none either.
#
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
ALL="omp claude codex"
ROOT="${FCODE_TOOLS_ROOT:-/opt/fcode-tools}" # versioned installs
BINDIR="${FCODE_BINDIR:-/usr/local/bin}"      # where the bin symlinks live
NM="${FCODE_UPDATE_NM:-}"                     # old global npm root (migration source), set in main

# every external command: timeout, and without the lock fd so a leftover child cannot hold the lock
x() { local t=$1; shift; timeout -k 10 "$t" "$@" 9>&-; }
# priv <dir> cmd...: run directly when <dir> is writable, else through sudo
priv() { local d=$1; shift; if [ -w "$d" ]; then "$@"; else sudo -n -H "$@"; fi 9>&-; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
oneline() { tr '\n\r\t' '   ' | tr -s ' ' | cut -c1-300; }
# strict semver; also guarantees a version is a safe single path component
semver_ok() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; }

pkg_of() {
  case $1 in
    claude) echo @anthropic-ai/claude-code ;;
    codex) echo @openai/codex ;;
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
note() { printf '%s %s\n' "$(now)" "$*" >>"$LOG"; echo "fcode-update: $*"; }

pkg_version() { x 30 node -p 'require(process.argv[1]).version' "$1" 2>/dev/null; }
# the version the tool currently runs from: <root>/<tool>/current, or the old global install
cur_ver() { pkg_version "$ROOT/$1/current/lib/node_modules/$(pkg_of "$1")/package.json"; }
legacy_ver() { pkg_version "$NM/$(pkg_of "$1")/package.json"; }

installed() {
  case $1 in
    omp) x 30 omp --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*' | head -1 ;;
    *) cur_ver "$1" ;;
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

# ---- versioned install, atomic switch ----------------------------------------------------------

# verify <dir> <tool> <version>: the installed bin runs and reports the expected version
verify() {
  local out re=${3//./[.]}
  out=$(x 30 "$1/bin/$2" --version 2>&1 </dev/null) || return 1
  # the version as a whole token; "v" may be glued to it
  printf %s "$out" | grep -Eq "(^|[^0-9.])v?${re}([^0-9A-Za-z.-]|$)"
}

# boot_id: the monotonic clock (uptime) restarts at 0 on every boot, so times are always "boot_id + uptime"
boot_id() { cat /proc/sys/kernel/random/boot_id; }

# install_version <tool> <version>: make <root>/<tool>/<version> exist and be sound. An existing dir is never
# deleted or replaced here (a live process may run from it). A new one is installed with npm (as this user, no
# sudo) into a temp dir next to it, verified there, and renamed into place.
install_version() {
  local t=$1 v=$2 d="$ROOT/$1/$2" tmp="$ROOT/$1/.new.$2.$$" cache out free rc
  if [ -d "$d" ]; then
    verify "$d" "$t" "$v" && return 0
    # exists but broken: set it aside only when it is neither current nor possibly in use
    if [ "$(readlink "$ROOT/$t/current" 2>/dev/null)" = "$v" ] || ver_busy "$t" "$v"; then
      echo "$d fails '$t --version' but is current or in use; left alone"; return 1
    fi
    mv -T "$d" "$ROOT/$t/.bad.$v.$$" || { echo "cannot set $d aside"; return 1; }
  fi
  mkdir -p "$ROOT/$t"
  free=$(df -Pk "$ROOT" | awk 'NR==2{print $4}')
  [ "${free:-0}" -ge "${FCODE_MIN_FREE_KB:-2097152}" ] || { echo "less than $(( ${FCODE_MIN_FREE_KB:-2097152} / 1048576 )) GB free on $ROOT"; return 1; }
  rm -rf "$tmp"; mkdir -p "$tmp" && cache=$(mktemp -d "$ROOT/$t/.npmcache.XXXXXX") || { echo "cannot create temp dirs in $ROOT/$t"; return 1; }
  out=$(x 600 npm install -g --prefix "$tmp" --cache "$cache" --no-audit --no-fund --no-progress --loglevel=error "$(pkg_of "$t")@$v" 2>&1 </dev/null); rc=$?
  rm -rf "$cache"
  [ $rc -eq 0 ] || { rm -rf "$tmp"; echo "npm install failed: $(printf %s "$out" | tail -3)"; return 1; }
  verify "$tmp" "$t" "$v" || { rm -rf "$tmp"; echo "verify failed: $t --version does not report $v"; return 1; }
  mv -T "$tmp" "$d" || { rm -rf "$tmp"; echo "cannot move $tmp to $d"; return 1; }
  verify "$d" "$t" "$v" || { rm -rf "$d"; echo "verify failed after move: $t --version does not report $v"; return 1; } # ours, nobody uses it yet
}

# flip <tool> <version>: atomic switch of <root>/<tool>/current (rename of a temp symlink over it).
# The activation log <root>/<tool>/activations gets "version boot_id uptime" (before the switch, so a process
# started in between is covered by the offsets in pinned_versions).
flip() {
  local tmp="$ROOT/$1/.current.$$"
  printf '%s %s %s\n' "$2" "$(boot_id)" "$(cut -d' ' -f1 /proc/uptime)" >>"$ROOT/$1/activations" \
    && ln -s "$2" "$tmp" && mv -T "$tmp" "$ROOT/$1/current" || { rm -f "$tmp"; echo "cannot switch $1 to $2"; return 1; }
}

# seed_log <tool>: an install made before the activation log existed counts as active since boot
seed_log() {
  local cur
  cur=$(readlink "$ROOT/$1/current") || return 0
  awk -v v="$cur" '$1 == v {f = 1} END {exit !f}' "$ROOT/$1/activations" 2>/dev/null || printf '%s %s 0
' "$cur" "$(boot_id)" >>"$ROOT/$1/activations"
}

# bin_names <tool>: the bin names of the current package
bin_names() {
  jq -r 'if (.bin|type)=="object" then (.bin|keys[]) elif (.bin|type)=="string" then (.name|split("/")|last) else empty end' \
    "$ROOT/$1/current/lib/node_modules/$(pkg_of "$1")/package.json" 2>/dev/null
}

# ensure_links <tool>: BINDIR/<bin> -> <root>/<tool>/current/bin/<bin> (each replaced by an atomic rename).
# Idempotent; runs on every run, so an interrupted migration is completed.
ensure_links() {
  local t=$1 n target tmp names
  names=$(bin_names "$t") && [ -n "$names" ] || return 1
  for n in $names; do
    target="$ROOT/$t/current/bin/$n"
    [ -e "$target" ] || continue
    [ "$(readlink "$BINDIR/$n" 2>/dev/null)" = "$target" ] && continue
    tmp="$BINDIR/.$n.fcode.$$"
    priv "$BINDIR" ln -s "$target" "$tmp" && priv "$BINDIR" mv -T "$tmp" "$BINDIR/$n" || { priv "$BINDIR" rm -f "$tmp"; echo "cannot link $BINDIR/$n"; return 1; }
  done
}

# links_ok <tool>: every bin link resolves into <root>/<tool>/
links_ok() {
  local n names r
  names=$(bin_names "$1") && [ -n "$names" ] || return 1
  for n in $names; do
    r=$(readlink -f "$BINDIR/$n" 2>/dev/null)
    case $r in "$ROOT/$1/"*) ;; *) return 1 ;; esac
  done
}

# switch_to <tool> <version>: install, verify, switch, link
switch_to() { install_version "$1" "$2" && flip "$1" "$2" && ensure_links "$1"; }

# ---- cleanup (best effort; a doubt always means "keep") ---------------------------------------

# dir_in_use <dir>: some process has the dir as exe/cwd/open file/mapping, or its path on its command line
dir_in_use() {
  local d=${1%/}
  sudo -n true 2>/dev/null </dev/null 9>&- || return 0 # cannot look at every process: assume in use
  [ -n "$(sudo -n find /proc -maxdepth 3 \( -lname "$d" -o -lname "$d/*" \) -print -quit 2>/dev/null </dev/null 9>&-)" ] && return 0
  cat /proc/[0-9]*/cmdline 2>/dev/null | tr '\0' '\n' | grep -qF -f <(printf '%s/\n' "$d") && return 0
  return 1
}

# tool_proc_starts <tool>: "pid start" for every running process that looks like the tool (start = seconds after
# boot; its name in comm or in the first five arguments). A node script keeps only its symlink on its command
# line, so this is how a long-lived session is noticed. Too broad only delays cleanup.
tool_proc_starts() {
  local d pid w s clk a=()
  clk=$(getconf CLK_TCK)
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    [ "$pid" = "$$" ] && continue
    { mapfile -d '' -t a <"$d/cmdline"; } 2>/dev/null || continue
    for w in "$(cat "$d/comm" 2>/dev/null)" "${a[@]:0:5}"; do
      [ "${w##*/}" = "$1" ] || continue
      s=$(sed 's/.*) //' "$d/stat" 2>/dev/null | cut -d' ' -f20)
      [ -n "$s" ] && echo "$pid $((s / clk))"
      break
    done
  done
}

# version_at <tool> <boot_id> <uptime>: the version that was current at that moment of this boot
# ("@legacy" = the old global install, before the first activation)
version_at() {
  awk -v b="$2" -v s="$3" 'BEGIN{v="@legacy"} $2 != b || $3 <= s {v=$1; next} {exit} END{print v}' "$ROOT/$1/activations" 2>/dev/null || echo @legacy
}

# proc_versions <tool> <pid>: the version dirs a process has actually loaded (its exe and mapped files)
proc_versions() {
  { readlink "/proc/$2/exe"; cat "/proc/$2/maps"; } 2>/dev/null | grep -o "$ROOT/$1/[^/]*/" | sed "s|^$ROOT/$1/||; s|/\$||" | sort -u
}

# pinned_versions <tool>: versions a running tool process may be using. Evidence wins: when its exe or mapped
# files show which version dir it loaded, that is the version. Otherwise the one current when it started (plus
# the neighbours within a few seconds: the stamp is written just before the switch, and the start time is
# rounded). Limit: the start time is the fork time of the pid, so a node-only tool exec'd from a shell that is
# days old (`exec codex`) is pinned to the version current when that shell started; it is still safe for claude
# and codex, whose native binary lives in the version dir and is caught by the evidence.
pinned_versions() {
  local pid s bn off ev
  bn=$(boot_id)
  while read -r pid s; do
    ev=$(proc_versions "$1" "$pid")
    if [ -n "$ev" ]; then echo "$ev"; continue; fi
    for off in -5 0 1; do version_at "$1" "$bn" $((s + off)); done
  done < <(tool_proc_starts "$1")
}

# ver_busy <tool> <version>: a running process may be using this version dir
ver_busy() {
  dir_in_use "$ROOT/$1/$2" && return 0
  pinned_versions "$1" | grep -qxF -- "$2"
}

# prune_tool <tool>: keep current, the 2 most recently activated others, and every version a running process
# may use (by start time, or by direct evidence). Remove the rest, the old global copy once the links no longer
# point into it, and half-installed leftovers (no activation entry, older than 1 h).
prune_tool() {
  local t=$1 cur keep n=0 v e legacy log="$ROOT/$1/activations"
  cur=$(readlink "$ROOT/$t/current") || return 0
  keep=" $cur "
  for v in $(tac "$log" 2>/dev/null | awk '!seen[$1]++ {print $1}'); do
    [ "$v" = "$cur" ] && continue
    n=$((n + 1)); [ $n -le 2 ] && keep="$keep$v "
  done
  for v in $(pinned_versions "$t"); do keep="$keep$v "; done
  legacy="$NM/$(pkg_of "$t")"
  if [ -n "$NM" ] && [ -d "$legacy" ] && [[ $keep != *" @legacy "* ]] && links_ok "$t" && ! dir_in_use "$legacy"; then
    priv "$NM" rm -rf "$legacy" && note "$t: removed old global copy $legacy"
  fi
  for e in "$ROOT/$t"/* "$ROOT/$t"/.[a-z]*; do
    [ -d "$e" ] && [ ! -L "$e" ] || continue
    v=${e##*/}
    [[ $keep == *" $v "* ]] && continue
    dir_in_use "$e" && continue
    if awk -v v="$v" '$1 == v {f = 1} END {exit !f}' "$log" 2>/dev/null; then : # an old activated version
    elif [ -z "$(find "$e" -maxdepth 0 -mmin +60)" ]; then continue # not activated and younger than 1 h: maybe being installed
    fi
    rm -rf "${e:?}" && note "$t: removed $v"
  done
  return 0
}

# rollback_tool <tool> <version>: atomic switch back to an installed version, logged, and updates held
rollback_tool() {
  local t=$1 v=${2:-}
  [ -n "$(pkg_of "$t")" ] || { echo "fcode-update: --rollback works for: claude codex" >&2; return 2; }
  semver_ok "$v" || { echo "fcode-update: '$v' is not a version" >&2; return 2; }
  [ -d "$ROOT/$t/$v" ] || { echo "fcode-update: $t $v is not installed (have: $(ls "$ROOT/$t" 2>/dev/null | grep -E '^[0-9]' | tr '\n' ' '))" >&2; return 1; }
  verify "$ROOT/$t/$v" "$t" "$v" || { echo "fcode-update: $ROOT/$t/$v does not run" >&2; return 1; }
  seed_log "$t"
  flip "$t" "$v" && ensure_links "$t" && touch "$ROOT/$t/hold" || return 1
  note "$t: rolled back to $v, updates held"
  echo "fcode-update: resume updates with: fcode-update --resume $t"
}
# resume_tool <tool>: allow updates again
resume_tool() { [ -n "$(pkg_of "$1")" ] || { echo "fcode-update: --resume works for: claude codex" >&2; return 2; }; rm -f "$ROOT/$1/hold" && note "$1: updates resumed"; }

# ---- one tool ----------------------------------------------------------------------------------

failed=0
update_tool() {
  local t=$1 cur lat out new v
  if [ -e "$ROOT/$t/hold" ]; then # rollback pin: touch <root>/<tool>/hold
    record "$t" "$(installed "$t")" "$(installed "$t")" current "held (remove $ROOT/$t/hold to resume updates)"; return
  fi
  if [ "$t" != omp ] && [ -z "$(cur_ver "$t")" ]; then # first run: move the old global install into the layout
    v=$(legacy_ver "$t")
    semver_ok "$v" || { record "$t" "" "" failed "not installed (no $ROOT/$t/current and no global package)"; failed=1; return; }
    out=$(switch_to "$t" "$v") || { record "$t" "$v" "" failed "migration failed: $out"; failed=1; return; }
    note "$t: migrated $v to $ROOT/$t/$v"
  fi
  [ "$t" = omp ] || seed_log "$t"
  [ "$t" = omp ] || ensure_links "$t" >/dev/null || note "$t: cannot ensure the $BINDIR links"
  cur=$(installed "$t")
  semver_ok "$cur" || { record "$t" "" "" failed "cannot read installed version"; failed=1; return; }
  lat=$(latest "$t" "$cur") || { record "$t" "$cur" "" failed "latest lookup failed: $lat"; failed=1; return; }
  if [ "$lat" != newer ] && ! semver_ok "$lat"; then record "$t" "$cur" "" failed "invalid latest version '$lat'"; failed=1; return; fi
  if ! newer "$cur" "$lat"; then
    record "$t" "$cur" "$cur" current
    [ "$t" = omp ] || prune_tool "$t"
    return
  fi
  if [ "$t" = omp ]; then
    out=$(x 600 omp update 2>&1 </dev/null) || { record "$t" "$cur" "$lat" failed "update failed: $(printf %s "$out" | tail -3)"; failed=1; return; }
  else
    out=$(switch_to "$t" "$lat") || { record "$t" "$cur" "$lat" failed "$out"; failed=1; return; }
  fi
  new=$(installed "$t")
  if [ -z "$new" ] || [ "$new" = "$cur" ] || { [ "$lat" != newer ] && [ "$new" != "$lat" ]; }; then
    record "$t" "$cur" "${new:-}" failed "version after update is '${new:-unreadable}', expected '$lat'"; failed=1; return
  fi
  record "$t" "$cur" "$new" updated
  [ "$t" = omp ] || prune_tool "$t"
}

main() {
  local mode=update TOOLS t
  case ${1:-} in --rollback | --resume) mode=${1#--}; shift ;; esac
  TOOLS="${*:-$ALL}"
  mkdir -p "$STATE"
  if [ $mode = update ]; then
    for t in $TOOLS; do
      case " $ALL " in *" $t "*) ;; *) echo "fcode-update: unknown tool '$t' (valid: $ALL)" >&2; exit 2 ;; esac
    done
  fi

  exec 9>"$STATE/lock"
  if [ $mode = update ]; then
    flock -n 9 || { echo "fcode-update: another run is active, exiting"; exit 0; }
  else
    flock -w 300 9 || { echo "fcode-update: another run is active, try again later" >&2; exit 1; }
  fi

  [ -n "$NM" ] || NM=$(x 30 npm root -g 2>/dev/null) || NM=
  [ -n "$NM" ] || NM=/usr/local/lib/node_modules
  case $mode in
    rollback) rollback_tool "$@"; exit $? ;;
    resume) resume_tool "$@"; exit $? ;;
  esac

  for t in $TOOLS; do update_tool "$t"; done
  exit $failed
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
