#!/usr/bin/env bash
# fcode-update: keep omp, claude, codex, opencode and cmd (Command Code) up to date.
# Usage: fcode-update [tool ...]   (default: all five)
#
# npm tools (claude, codex, opencode, cmd) are never modified in place. Every version is installed into
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
ALL="omp claude codex opencode cmd"
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
    opencode) echo @opencode/cli ;;
    cmd) echo command-code ;;
  esac
}
# the process names a running tool can have (bin names and process titles)
tool_names() {
  case $1 in
    opencode) echo "opencode opencode2" ;;
    cmd) echo "cmd cmdc command-code commandcode" ;;
    *) echo "$1" ;;
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
  local out
  out=$(x 30 "$1/bin/$2" --version 2>&1 </dev/null) || return 1
  # the version as a whole token; "v" may be glued to it (opencode prints "opencode v2.1.4")
  printf %s "$out" | grep -Eq "(^|[^0-9.])v?${3//./\.}([^0-9A-Za-z.-]|$)"
}

# install_version <tool> <version>: npm install into <root>/<tool>/<version> (as this user, no sudo), verify there
install_version() {
  local t=$1 v=$2 d="$ROOT/$1/$2" out
  if [ -d "$d" ] && verify "$d" "$t" "$v"; then return 0; fi # already there and sound (maybe in use)
  rm -rf "$d"; mkdir -p "$d" || { echo "cannot create $d"; return 1; }
  out=$(x 600 npm install -g --prefix "$d" --no-audit --no-fund --no-progress --loglevel=error "$(pkg_of "$t")@$v" 2>&1 </dev/null) \
    || { rm -rf "$d"; echo "npm install failed: $(printf %s "$out" | tail -3)"; return 1; }
  verify "$d" "$t" "$v" || { rm -rf "$d"; echo "verify failed: $t --version does not report $v"; return 1; }
}

# flip <tool> <version>: atomic switch of <root>/<tool>/current (rename of a temp symlink over it)
flip() {
  local tmp="$ROOT/$1/.current.$$"
  # stamp = boot id + uptime (monotonic, immune to wall-clock jumps); the file mtime only orders versions
  printf '%s %s\n' "$(cat /proc/sys/kernel/random/boot_id)" "$(cut -d' ' -f1 /proc/uptime)" >"$ROOT/$1/$2/.activated" && ln -s "$2" "$tmp" && mv -T "$tmp" "$ROOT/$1/current" || { rm -f "$tmp"; echo "cannot switch $1 to $2"; return 1; }
}

# ensure_links <tool>: BINDIR/<bin> -> <root>/<tool>/current/bin/<bin> (each replaced by an atomic rename)
ensure_links() {
  local t=$1 n target tmp names
  names=$(jq -r 'if (.bin|type)=="object" then (.bin|keys[]) elif (.bin|type)=="string" then (.name|split("/")|last) else empty end' \
    "$ROOT/$t/current/lib/node_modules/$(pkg_of "$t")/package.json" 2>/dev/null) || return 1
  for n in $names; do
    target="$ROOT/$t/current/bin/$n"
    [ -e "$target" ] || continue
    [ "$(readlink "$BINDIR/$n" 2>/dev/null)" = "$target" ] && continue
    tmp="$BINDIR/.$n.fcode.$$"
    priv "$BINDIR" ln -s "$target" "$tmp" && priv "$BINDIR" mv -T "$tmp" "$BINDIR/$n" || { priv "$BINDIR" rm -f "$tmp"; echo "cannot link $BINDIR/$n"; return 1; }
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

# oldest_tool_start <tool>: start time (seconds after boot) of the oldest running process that looks like the tool (any of its bin
# names or process titles in comm or the first five arguments). A node script keeps only its symlink in
# its command line, so this is how a long-lived old session is noticed. Looking too broad only delays cleanup.
oldest_tool_start() {
  local names=" $(tool_names "$1") " d pid w s best='' a=()
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    [ "$pid" = "$$" ] && continue
    mapfile -d '' -t a <"$d/cmdline" 2>/dev/null || continue
    for w in "$(cat "$d/comm" 2>/dev/null)" "${a[@]:0:5}"; do
      w=${w##*/}
      [[ -n $w && $names == *" $w "* ]] || continue
      s=$(sed 's/.*) //' "$d/stat" 2>/dev/null | cut -d' ' -f20) || continue
      s=$((s / $(getconf CLK_TCK)))
      if [ -z "$best" ] || [ "$s" -lt "$best" ]; then best=$s; fi
      break
    done
  done
  echo "$best"
}

# prune_tool <tool>: keep current + the 2 most recently activated others; remove older version dirs and the
# old global copy only when nothing uses them. A tool process older than the current version blocks it all.
prune_tool() {
  local t=$1 cur boot='' act='' old keepall=0 n=0 f v legacy
  cur=$(readlink "$ROOT/$t/current") || return 0
  read -r boot act <"$ROOT/$t/$cur/.activated" 2>/dev/null
  # stamp from another boot: every process alive now started later. No stamp: assume "activated just now".
  if [ -n "$boot" ] && [ "$boot" != "$(cat /proc/sys/kernel/random/boot_id)" ]; then act=-1; fi
  act=${act%%.*}; act=${act:-$(cut -d. -f1 /proc/uptime)}
  old=$(oldest_tool_start "$t")
  if [ -n "$old" ] && [ "$old" -le "$act" ]; then keepall=1; fi
  [ $keepall = 0 ] || return 0
  legacy="$NM/$(pkg_of "$t")"
  if [ -n "$NM" ] && [ -d "$legacy" ] && ! dir_in_use "$legacy"; then
    priv "$NM" rm -rf "$legacy" && note "$t: removed old global copy $legacy"
  fi
  for f in $(ls -1t "$ROOT/$t"/*/.activated 2>/dev/null); do # newest first
    v=$(basename "$(dirname "$f")")
    [ "$v" = current ] || [ "$v" = "$cur" ] && continue
    n=$((n + 1))
    [ $n -le 2 ] && continue
    if ! dir_in_use "$ROOT/$t/$v"; then rm -rf "${ROOT:?}/$t/$v" && note "$t: removed old version $v"; fi
  done
  return 0
}

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
