#!/usr/bin/env bash
# fcode-notify (runs ON the coder box, installed as ~/.local/bin/fcode-notify): the main omp session leaves a one-way notice for the owner.
# It only appends one line to a local outbox file; nothing is sent from here. Hermes (another machine) pulls the file read-only over ssh
# with a forced command and sends the notes to the owner's Zalo. A note is data only: it is never executed, evaluated or sourced.
#   fcode-notify <project> <kind> <text> [link]
#   <project>: ^[a-z0-9][a-z0-9._-]{0,39}$     <kind>: merge-ready | needs-yes | stuck | info
#   <text>: free text; control and invisible characters are removed, spaces collapsed, cut to 300 characters; must be valid UTF-8
#   [link]: empty or an https URL of at most 160 characters
# Output: exactly one line on stdout, then exit:
#   notify: queued <id>                                        exit 0
#   notify: duplicate                                          exit 0   (same project+kind+text+link+session in the last 30 min; nothing written)
#   error: usage | bad-project | bad-kind | bad-text | bad-link  exit 65 (nothing written)
#   error: rate-limited                                        exit 75  (more than 6 notes for this project or 15 in total in the last 60 min)
#   error: io                                                  exit 1   (lock / write failure; the old file stays as it was)
# Outbox: $HOME/.local/state/fcode/notify/outbox.tsv (dir 700, file 600), one note per line, 7 TAB-separated fields:
#   id (<epoch>-<8 hex>)  epoch  project  kind  text  link  session
# session = the tmux session this note comes from (^[a-z0-9][a-z0-9._-]{0,63}$), found by this script itself: `tmux display-message -p -t $TMUX_PANE '#S'`
# when TMUX and TMUX_PANE are set (under `timeout 2`); empty (never an error) outside tmux, when tmux fails or hangs or when the name does not match. Old 6-field lines are still read (session empty).
# Only the newest 50 lines are kept; every rewrite is a temp file + mv under flock (outbox.lock).
# Test hooks, honoured only with FCODE_NOTIFY_TEST=1: FCODE_NOTIFY_DIR (outbox dir), FCODE_NOTIFY_NOW (epoch seconds) and FCODE_NOTIFY_SESSION (replaces the tmux lookup; may be empty).
# Needs: bash, node (text check only), flock, od, mktemp, timeout (coreutils; only for the tmux lookup). Reads nothing but its arguments and the outbox; makes no network call.
set -u
export LC_ALL=C
export PATH="${HOME:-/nonexistent}/.local/bin:${HOME:-/nonexistent}/.bun/bin:/usr/local/bin:$PATH"
umask 077

bye() { echo "$1"; exit "$2"; }
io() { bye 'error: io' 1; }

[ $# -eq 3 ] || [ $# -eq 4 ] || bye 'error: usage' 65
project=$1 kind=$2 text=$3 link=${4:-}
[[ $project =~ ^[a-z0-9][a-z0-9._-]{0,39}$ ]] || bye 'error: bad-project' 65
case $kind in merge-ready | needs-yes | stuck | info) ;; *) bye 'error: bad-kind' 65 ;; esac

# Text and link go to node on stdin (bytes, NUL-separated): bash cannot tell characters from bytes, and node's decoder in fatal mode rejects invalid UTF-8.
# Exit 3 = bad text (invalid UTF-8, or empty after cleaning), 4 = bad link; anything else = the check itself failed.
read -r -d '' JS <<'EOF'
const fs = require("fs");
let b;
try { b = fs.readFileSync(0); } catch (e) { process.exit(1); }
const i = b.indexOf(0);
if (i < 0) process.exit(1);
const dec = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
let t, l;
try { t = dec.decode(b.subarray(0, i)); } catch (e) { process.exit(3); }
t = t.replace(/[\t\n\r]/g, " ")
  .replace(/[\u0000-\u001F\u007F-\u009F\u00AD\u061C\u180E\u200B-\u200F\u2028-\u202E\u2060-\u2064\u2066-\u206F\uFEFF\uFFF9-\uFFFB]/g, "")
  .replace(/ {2,}/g, " ").replace(/^ +| +$/g, "");
t = Array.from(t).slice(0, 300).join("").replace(/^ +| +$/g, "");
if (t === "") process.exit(3);
try { l = dec.decode(b.subarray(i + 1)); } catch (e) { process.exit(4); }
if (l !== "" && !(l.length <= 160 && /^https:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?(\/[A-Za-z0-9._~%\/+?=&#:@!,;*()-]*)?$/.test(l))) process.exit(4);
process.stdout.write(t);
EOF
text=$(printf '%s\0%s' "$text" "$link" | node -e "$JS"); rc=$?
case $rc in 0) ;; 3) bye 'error: bad-text' 65 ;; 4) bye 'error: bad-link' 65 ;; *) io ;; esac
[ -n "$text" ] || io

[ -n "${HOME:-}" ] || io
DIR=$HOME/.local/state/fcode/notify
NOW=
if [ "${FCODE_NOTIFY_TEST:-}" = 1 ]; then
  [ -z "${FCODE_NOTIFY_DIR:-}" ] || DIR=$FCODE_NOTIFY_DIR
  NOW=${FCODE_NOTIFY_NOW:-}
  [ -z "$NOW" ] || [[ $NOW =~ ^[0-9]{10}$ ]] || io
fi
[ -n "$NOW" ] || NOW=$(date -u +%s) || io
[[ $NOW =~ ^[0-9]{10}$ ]] || io
OUT=$DIR/outbox.tsv

# session: from tmux, or (test only) from FCODE_NOTIFY_SESSION; anything that does not match the name rule becomes empty
session=
if [ "${FCODE_NOTIFY_TEST:-}" = 1 ] && [ -n "${FCODE_NOTIFY_SESSION+x}" ]; then
  session=$FCODE_NOTIFY_SESSION
elif [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
  session=$(timeout 2 tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null </dev/null) || session=
fi
[[ $session =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || session=

mkdir -p "$DIR" 2>/dev/null && chmod 700 "$DIR" 2>/dev/null || io
if ! { exec 9>>"$DIR/outbox.lock"; } 2>/dev/null; then io; fi
flock -w 10 9 || io
chmod 600 "$DIR/outbox.lock" 2>/dev/null
rm -f "$DIR"/.outbox.* # left by a run that was killed while writing (we hold the lock)
tmp=
trap 'rm -f "$tmp"' EXIT

old=()
if [ -e "$OUT" ] || [ -L "$OUT" ]; then
  [ -f "$OUT" ] && [ ! -L "$OUT" ] && [ -r "$OUT" ] || io
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] || old+=("$line")
  done <"$OUT"
fi

# duplicate (same project+kind+text+link+session within 30 min) is answered before the rate limit; the counts are over the last 60 min
ids=" " n_all=0 n_proj=0 i=0
while [ "$i" -lt "${#old[@]}" ]; do
  # TAB is blank space to read: empty fields would collapse. Text has no control characters, so \001 is a safe separator.
  IFS=$'\001' read -r l_id l_ep l_pr l_kd l_tx l_lk l_se <<<"${old[$i]//$'\t'/$'\001'}"
  i=$((i + 1))
  ids="$ids$l_id "
  [[ $l_ep =~ ^[0-9]{10}$ ]] || continue
  age=$((NOW - 10#$l_ep))
  if [ "$age" -le 1800 ] && [ "$l_pr" = "$project" ] && [ "$l_kd" = "$kind" ] && [ "$l_tx" = "$text" ] && [ "$l_lk" = "$link" ] && [ "$l_se" = "$session" ]; then
    bye 'notify: duplicate' 0
  fi
  if [ "$age" -lt 3600 ]; then
    n_all=$((n_all + 1))
    [ "$l_pr" != "$project" ] || n_proj=$((n_proj + 1))
  fi
done
{ [ "$n_proj" -le 5 ] && [ "$n_all" -le 14 ]; } || bye 'error: rate-limited' 75

try=0
while :; do
  hex=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  [[ $hex =~ ^[0-9a-f]{8}$ ]] || io
  id=$NOW-$hex
  [[ $ids == *" $id "* ]] || break
  try=$((try + 1))
  [ "$try" -lt 20 ] || io
done

tmp=$(mktemp "$DIR/.outbox.XXXXXX") || io
start=0
[ "${#old[@]}" -le 49 ] || start=$((${#old[@]} - 49))
{
  i=$start
  while [ "$i" -lt "${#old[@]}" ]; do printf '%s\n' "${old[$i]}"; i=$((i + 1)); done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$NOW" "$project" "$kind" "$text" "$link" "$session"
} >"$tmp" || io
chmod 600 "$tmp" && mv -f "$tmp" "$OUT" || io
tmp=
echo "notify: queued $id"
exit 0
