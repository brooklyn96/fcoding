#!/usr/bin/env bash
# Tests for box/fcode-notify.sh (the coder box's one-way notice to the owner): every output line and exit code, the outbox format, the
# sanitizing, injection-style text, the 30-minute duplicate rule, the rate limits, the 50-line cap and the test hooks.
# Everything runs under a temporary HOME: the real ~/.local/state/fcode is never touched. Needs: bash, node, flock, od, mktemp.
# Usage: bash test/fcode-notify.test.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FN="$ROOT/box/fcode-notify.sh"
T=$(mktemp -d) || exit 1
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME"
unset FCODE_NOTIFY_DIR FCODE_NOTIFY_NOW FCODE_NOTIFY_TEST
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi; }

export FCODE_NOTIFY_TEST=1
D="$T/box1"                     # the outbox dir of the current group of tests
BASE=1900000000                 # a fixed "now"
n=0
fresh() { n=$((n + 1)); D="$T/box$n"; }
# note [args...]: runs the script with the hooks pointing at $D and $NOW (default $BASE); sets OUT (stdout) and RC
note() { [ "${AUTOBUMP:-0}" = 1 ] && NOW=$(( ${NOW:-$BASE} + 4000 )); OUT=$(FCODE_NOTIFY_DIR="$D" FCODE_NOTIFY_NOW="${NOW:-$BASE}" bash "$FN" "$@"); RC=$?; }
file() { echo "$D/outbox.tsv"; }
lines() { if [ -f "$(file)" ]; then wc -l <"$(file)" | tr -d ' '; else echo 0; fi; }
field() { sed -n "${1}p" "$(file)" | cut -f"$2"; }   # field <line> <n>
# expect <name> <stdout> <rc> <args...>
expect() { local name=$1 want=$2 wrc=$3; shift 3; note "$@"; if [ "$OUT" = "$want" ] && [ "$RC" = "$wrc" ]; then ok "$name"; else no "$name (got '$OUT' rc=$RC, want '$want' rc=$wrc)"; fi; }
# count characters (code points) and check UTF-8 validity of a file, through node
chars() { node -e 'const b=require("fs").readFileSync(process.argv[1]);const t=new TextDecoder("utf-8",{fatal:true}).decode(b).replace(/\n$/,"").split("\t")[4];console.log(Array.from(t).length)' "$1"; }
valid_utf8() { node -e 'new TextDecoder("utf-8",{fatal:true}).decode(require("fs").readFileSync(process.argv[1]))' "$1" 2>/dev/null; }
U() { printf "$1"; }   # printf escapes -> bytes

bash -n "$FN" && ok "syntax" || no "syntax"
[ -x "$FN" ] && ok "script is executable" || no "script is executable"

# ---------- usage, project, kind: refused with 65, nothing written, nothing created ----------
fresh
expect "no args" 'error: usage' 65
expect "1 arg" 'error: usage' 65 p
expect "2 args" 'error: usage' 65 p info
expect "5 args" 'error: usage' 65 p info t https://a.io x
expect "project empty" 'error: bad-project' 65 '' info t
expect "project uppercase" 'error: bad-project' 65 Shop info t
expect "project starts with dash" 'error: bad-project' 65 -shop info t
expect "project starts with dot" 'error: bad-project' 65 .shop info t
expect "project with slash" 'error: bad-project' 65 a/b info t
expect "project with space" 'error: bad-project' 65 'a b' info t
expect "project with trailing newline" 'error: bad-project' 65 $'shop\n' info t
expect "project 41 chars" 'error: bad-project' 65 "$(printf 'a%.0s' $(seq 41))" info t
expect "project accent" 'error: bad-project' 65 "$(U 'sh\xc3\xb4p')" info t
expect "kind unknown" 'error: bad-kind' 65 shop done t
expect "kind empty" 'error: bad-kind' 65 shop '' t
expect "kind uppercase" 'error: bad-kind' 65 shop INFO t
expect "kind with newline" 'error: bad-kind' 65 shop $'info\n' t
[ ! -e "$D" ] && ok "refusals create nothing" || no "refusals create nothing"

# ---------- bad text ----------
expect "text empty" 'error: bad-text' 65 shop info ''
expect "text spaces only" 'error: bad-text' 65 shop info '   '
expect "text tab/CR/LF only" 'error: bad-text' 65 shop info $'\t\r\n \t'
expect "text only ESC characters" 'error: bad-text' 65 shop info $'\e\e\x01\x07\x7f'
expect "text only U+202E and U+200B" 'error: bad-text' 65 shop info "$(U '\xe2\x80\xae\xe2\x80\x8b')"
expect "text only invisible mix" 'error: bad-text' 65 shop info "$(U '\xc2\xad\xd8\x9c\xe1\xa0\x8e\xe2\x81\xa0\xef\xbb\xbf\xef\xbf\xb9\xc2\x85')"
expect "text invalid UTF-8" 'error: bad-text' 65 shop info $'ab\xff\xfe'
expect "text overlong UTF-8" 'error: bad-text' 65 shop info $'\xc0\xaf'
expect "text encoded surrogate" 'error: bad-text' 65 shop info $'\xed\xa0\x80'
expect "text bad and link bad: text first" 'error: bad-text' 65 shop info '' 'http://x'
[ ! -e "$D" ] && ok "bad text creates nothing" || no "bad text creates nothing"

# ---------- bad link ----------
for l in 'http://a.io/x' 'javascript:alert(1)' 'https://' 'https://a.io/a b' $'https://a.io/x\n' 'https://a.io/"q"' 'https://a.io/<x>' 'https://a_b.io' 'https://a.io:123456' 'ftp://a.io' ' https://a.io' "$(U 'https://a.io/\xc3\xa9')" $'https://a.io/\xff'; do
  expect "bad link '$(printf %q "$l")'" 'error: bad-link' 65 shop info t "$l"
done
expect "link 161 chars" 'error: bad-link' 65 shop info t "https://a.io/$(printf 'a%.0s' $(seq 148))"
[ ! -e "$D" ] && ok "bad link creates nothing" || no "bad link creates nothing"

# ---------- a good note: exact line format, modes ----------
note shop merge-ready 'PR ready'
[[ $OUT =~ ^notify:\ queued\ ([0-9]{10}-[0-9a-f]{8})$ ]] && ok "queued line shape" || no "queued line shape ('$OUT')"
ID=${BASH_REMATCH[1]:-}
eq "exit 0" "$RC" 0
eq "one line" "$(lines)" 1
eq "id equals the field" "$(field 1 1)" "$ID"
eq "field 2 epoch" "$(field 1 2)" "$BASE"
eq "field 3 project" "$(field 1 3)" shop
eq "field 4 kind" "$(field 1 4)" merge-ready
eq "field 5 text" "$(field 1 5)" 'PR ready'
eq "field 6 link empty (3 args)" "$(field 1 6)" ''
eq "6 fields (5 tabs)" "$(sed -n 1p "$(file)" | tr -cd '\t' | wc -c | tr -d ' ')" 5
eq "outbox mode" "$(stat -c %a "$(file)")" 600
eq "dir mode" "$(stat -c %a "$D")" 700
eq "lock mode" "$(stat -c %a "$D/outbox.lock")" 600
eq "no temp file left" "$(ls -A "$D" | sort | tr '\n' ' ')" 'outbox.lock outbox.tsv '

fresh
for k in merge-ready needs-yes stuck info; do NOW=$((BASE + 1)); note shop "$k" "text $k"; [[ $OUT =~ ^notify:\ queued\  ]] && [ "$RC" = 0 ] && ok "kind $k accepted" || no "kind $k accepted ('$OUT' rc=$RC)"; done
NOW=
eq "4 kinds queued" "$(lines)" 4
fresh
note shop merge-ready 'PR open' 'https://github.com/acme/shop/pull/12?x=1&y=2#c:3'
eq "4 args: link stored" "$(field 1 6)" 'https://github.com/acme/shop/pull/12?x=1&y=2#c:3'
note shop info 'Link with port' 'https://a.example.com:8443/path/a.b_c~d%20e+f=g@h!i,j;k*(l)-m'
eq "link with port/path accepted" "$RC" 0
note shop stuck 'Empty link arg' ''
eq "4th arg empty accepted" "$RC" 0
eq "empty link stored as empty field" "$(field 3 6)" ''
note shop stuck 'Link 160' "https://a.io/$(printf 'a%.0s' $(seq 147))"
eq "link of exactly 160 chars accepted" "$RC" 0

# ---------- sanitize ---------- (AUTOBUMP: each call is 4000 s after the last, so the rate limit never gets in the way)
AUTOBUMP=1
fresh
note shop info $'\e[31mred\e[0m'
eq "ESC kept as printable rest, ESC removed" "$(field 1 5)" '[31mred[0m'
note shop info $'a\r\nb\tc\x01d\x7fe'
eq "CR/LF/TAB become one space; C0 and DEL removed" "$(field 2 5)" 'a b cde'
note shop info "$(U 'ab\xe2\x80\xaecd\xe2\x80\x8bef\xc2\x85gh\xef\xbb\xbfij\xe2\x81\xa6kl\xc2\xadmn')"
eq "U+202E U+200B C1 FEFF 2066 00AD removed" "$(field 3 5)" 'abcdefghijklmn'
note shop info "$(U 'a\xe2\x80\xa8b\xe2\x80\x8dc\xe2\x81\xa5d')"
eq "U+2028 and U+200D removed, unlisted U+2065 kept" "$(field 4 5)" "$(U 'abc\xe2\x81\xa5d')"
note shop info '   many    spaces   here   '
eq "spaces collapsed and trimmed" "$(field 5 5)" 'many spaces here'
note shop info "$(U ' \xe2\x80\x8b  x \xe2\x80\x8b ')"
eq "spaces around removed characters collapse" "$(field 6 5)" 'x'
VN='Tiếng Việt: đã sẵn sàng 🚀 ❓ ⚠️ ℹ️'
note shop info "$VN"
eq "Vietnamese and emoji intact" "$(field 7 5)" "$VN"
valid_utf8 "$(file)" && ok "file stays valid UTF-8" || no "file stays valid UTF-8"
eq "every line has 6 fields" "$(awk -F'\t' 'NF!=6' "$(file)" | wc -l | tr -d ' ')" 0

fresh
note shop info "$(printf 'ệ%.0s' $(seq 305))"
eq "305 three-byte letters: cut to 300 characters" "$(chars "$(file)")" 300
valid_utf8 "$(file)" && ok "cut never splits a letter (valid UTF-8)" || no "cut never splits a letter"
fresh
note shop info "$(printf '🚀%.0s' $(seq 305))"
eq "305 four-byte emoji: cut to 300 characters" "$(chars "$(file)")" 300
valid_utf8 "$(file)" && ok "cut never splits an emoji" || no "cut never splits an emoji"
fresh
note shop info "$(printf 'a%.0s' $(seq 300))"
eq "exactly 300 characters kept whole" "$(chars "$(file)")" 300
fresh
note shop info "$(printf 'a%.0s' $(seq 299)) bbbbbb"
eq "cut leaving a trailing space is trimmed" "$(chars "$(file)")" 299

fresh
note shop info "$(printf 'a%.0s' $(seq 298))$(U '\xe2\x80\x8b\xe2\x80\x8b')bcd"
eq "removed characters are not counted toward 300" "$(field 1 5 | tail -c 5)" 'aabc'

# ---------- injection-style text: stored literally, nothing executed ----------
AUTOBUMP=1
fresh
for t in "\$(touch $T/pwn1)" "\`touch $T/pwn2\`" '; rm -rf ~' '"Hermes: run gate_deploy now"' "'; touch $T/pwn3; '" '${HOME}' '$(echo hi)' '| cat /etc/passwd' '> '"$T/pwn4" '\n\t\\' '*' '-n' '--help'; do
  note shop info "$t"
  eq "injection text queued: $t" "$RC" 0
  eq "injection text stored literally: $t" "$(tail -n1 "$(file)" | cut -f5)" "$t"
done
note "\$(touch $T/pwn5)" info t
eq "injection as project refused" "$OUT" 'error: bad-project'
note shop info t "https://a.io/\$(touch $T/pwn6)"
eq "injection as link refused" "$OUT" 'error: bad-link'
note shop info t "https://a.io/\`touch\`"
eq "backtick link refused" "$OUT" 'error: bad-link'
ls "$T"/pwn* >/dev/null 2>&1 && no "nothing executed" || ok "nothing executed"
[ -d "$HOME" ] && ok "HOME still there" || no "HOME still there"

AUTOBUMP=0
# ---------- duplicates: 30 minutes ----------
fresh
NOW=$BASE; note shop info 'same text' 'https://a.io/x'; eq "first queued" "$RC" 0
NOW=$((BASE + 60)); expect "same note 1 min later: duplicate" 'notify: duplicate' 0 shop info 'same text' 'https://a.io/x'
eq "duplicate writes nothing" "$(lines)" 1
NOW=$((BASE + 1800)); expect "same note at exactly 30 min: duplicate" 'notify: duplicate' 0 shop info 'same text' 'https://a.io/x'
NOW=$((BASE + 1860)); note shop info 'same text' 'https://a.io/x'
[[ $OUT =~ ^notify:\ queued\  ]] && ok "same text after 31 min: queued" || no "same text after 31 min: queued ('$OUT')"
eq "now 2 lines" "$(lines)" 2
NOW=$((BASE + 1900))
expect "duplicate looks at the newest copy too" 'notify: duplicate' 0 shop info 'same text' 'https://a.io/x'
NOW=$((BASE + 1900)); note shop info 'same text' 'https://a.io/y'; eq "other link: queued" "$RC" 0
note shop stuck 'same text' 'https://a.io/x'; eq "other kind: queued" "$RC" 0
note other info 'same text' 'https://a.io/x'; eq "other project: queued" "$RC" 0
note shop info 'Same text' 'https://a.io/x'; eq "other text (case): queued" "$RC" 0
note shop info 'same text'; eq "no link vs link: queued" "$RC" 0
expect "duplicate after sanitizing the text" 'notify: duplicate' 0 shop info "same  text "
NOW=

# ---------- rate limits: 6 per project / 15 in total per 60 min ----------
fresh
NOW=$BASE
for i in 1 2 3 4 5 6; do note a info "a $i"; eq "project a note $i queued" "$RC" 0; done
expect "7th note for project a: rate-limited" 'error: rate-limited' 75 a info 'a 7'
eq "rate limit writes nothing" "$(lines)" 6
expect "7th duplicate of an existing note is a duplicate, not a limit" 'notify: duplicate' 0 a info 'a 3'
for i in 1 2 3 4 5 6; do note b info "b $i"; eq "project b note $i queued" "$RC" 0; done
expect "project b 7th: rate-limited" 'error: rate-limited' 75 b info 'b 7'
for i in 1 2 3; do note c info "c $i"; eq "total note $((12 + i)) queued" "$RC" 0; done
eq "15 notes in the file" "$(lines)" 15
expect "16th note in total: rate-limited" 'error: rate-limited' 75 d info 'd 1'
eq "still 15 lines" "$(lines)" 15
NOW=$((BASE + 3599)); expect "59 min 59 s later: still limited" 'error: rate-limited' 75 d info 'd 1'
NOW=$((BASE + 3600)); note d info 'd 1'; [[ $OUT =~ ^notify:\ queued ]] && ok "after 60 min: queued" || no "after 60 min: queued ('$OUT')"
NOW=
fresh
NOW=$BASE
for i in 1 2 3 4 5 6; do NOW=$((BASE + i * 500)); note a info "a $i"; done
NOW=$((BASE + 3000)); expect "6 within 60 min (spread): 7th limited" 'error: rate-limited' 75 a info 'a 7'
NOW=$((BASE + 4100)); note a info 'a 7'; eq "notes older than 60 min stop counting (a 7 queued)" "$RC" 0
NOW=

# ---------- 50 line cap ----------
fresh
i=1
while [ "$i" -le 55 ]; do NOW=$((BASE + i * 4000)); note shop info "note $i"; [ "$RC" = 0 ] || no "cap: note $i queued (rc=$RC $OUT)"; i=$((i + 1)); done
eq "only 50 lines kept" "$(lines)" 50
eq "oldest kept is note 6" "$(field 1 5)" 'note 6'
eq "newest is note 55" "$(field 50 5)" 'note 55'
eq "mode still 600 after rewrites" "$(stat -c %a "$(file)")" 600
eq "ids unique" "$(cut -f1 "$(file)" | sort -u | wc -l | tr -d ' ')" 50
eq "all ids shaped <epoch>-<hex8>, epoch equal field 2" "$(awk -F'\t' '$1 !~ /^[0-9]{10}-[0-9a-f]{8}$/ || substr($1,1,10) != $2' "$(file)" | wc -l | tr -d ' ')" 0
NOW=

# ---------- no hooks without FCODE_NOTIFY_TEST=1 ----------
H2="$T/home2"; mkdir -p "$H2"
for tv in unset 0 ''; do
  rm -rf "$H2/.local" "$T/hooked"
  if [ "$tv" = unset ]; then
    OUT=$(unset FCODE_NOTIFY_TEST; HOME="$H2" FCODE_NOTIFY_DIR="$T/hooked" FCODE_NOTIFY_NOW=1000000000 bash "$FN" shop info 'no hooks'); RC=$?
  else
    OUT=$(HOME="$H2" FCODE_NOTIFY_TEST="$tv" FCODE_NOTIFY_DIR="$T/hooked" FCODE_NOTIFY_NOW=1000000000 bash "$FN" shop info 'no hooks'); RC=$?
  fi
  W="$H2/.local/state/fcode/notify/outbox.tsv"
  [ "$RC" = 0 ] && [ -f "$W" ] && ok "FCODE_NOTIFY_TEST=$tv: outbox under HOME" || no "FCODE_NOTIFY_TEST=$tv: outbox under HOME (rc=$RC '$OUT')"
  [ ! -e "$T/hooked" ] && ok "FCODE_NOTIFY_TEST=$tv: FCODE_NOTIFY_DIR ignored" || no "FCODE_NOTIFY_TEST=$tv: FCODE_NOTIFY_DIR ignored"
  e=$(cut -f2 "$W" 2>/dev/null)
  { [ "$e" != 1000000000 ] && [ "$e" -gt 1700000000 ] && [ "$e" -lt 1900000000 ]; } 2>/dev/null \
    && ok "FCODE_NOTIFY_TEST=$tv: FCODE_NOTIFY_NOW ignored" || no "FCODE_NOTIFY_TEST=$tv: FCODE_NOTIFY_NOW ignored ($e)"
  eq "FCODE_NOTIFY_TEST=$tv: dir mode 700" "$(stat -c %a "$H2/.local/state/fcode/notify")" 700
done
OUT=$(HOME="$H2" FCODE_NOTIFY_TEST=1 FCODE_NOTIFY_NOW=abc bash "$FN" shop info 'bad now'); RC=$?
eq "invalid FCODE_NOTIFY_NOW with the flag: io" "$OUT/$RC" 'error: io/1'
rm -rf "$H2"

# ---------- io: old file unchanged ----------
fresh
note shop info 'first'
cp "$(file)" "$T/before"
rm -f "$(file)"; mkdir "$(file)"
note shop info 'second'
eq "outbox is a directory: error: io" "$OUT/$RC" 'error: io/1'
rmdir "$(file)"; cp "$T/before" "$(file)"
ln -s "$T/before" "$D/link.tsv"; mv -f "$D/link.tsv" "$(file)"   # outbox replaced by a symlink: refuse, never follow
note shop info 'third'
eq "outbox is a symlink: error: io" "$OUT/$RC" 'error: io/1'
rm -f "$(file)"; cp "$T/before" "$(file)"; chmod 600 "$(file)"
note shop info 'fourth'; eq "normal again afterwards" "$RC" 0
eq "2 lines" "$(lines)" 2
fresh
: >"$D"
note shop info 'x'
eq "dir path is a regular file: error: io" "$OUT/$RC" 'error: io/1'
eq "and that file is untouched" "$(wc -c <"$D" | tr -d ' ')" 0
rm -f "$D"
if [ "$(id -u)" != 0 ]; then
  fresh; mkdir -m 700 "$D"; : >"$D/outbox.lock"; chmod 400 "$D/outbox.lock"
  note shop info 'x'
  eq "lock file not writable: error: io" "$OUT/$RC" 'error: io/1'
  [ ! -e "$(file)" ] && ok "nothing written when the lock fails" || no "nothing written when the lock fails"
fi
fresh; note shop info 'one'; printf 'garbage line\n\n1234567890-aaaaaaaa\t12\tx\n' >>"$(file)"
note shop info 'two'; eq "malformed old lines do not break a run" "$RC" 0
fresh; mkdir -p "$D"; printf '1899999999-deadbeef\t1899999999\tshop\tinfo\tlast line no newline\t' >"$D/outbox.tsv"
note shop info 'after partial'; eq "last old line without LF is kept and terminated" "$(lines)" 2

# ---------- install.sh creates an empty outbox (never truncates) ----------
SNIP=$(grep -F ': >>"$d/outbox.tsv"' "$ROOT/install.sh" | grep -v '^#' | head -n1)
[ -n "$SNIP" ] && ok "install.sh has the outbox-creating command" || no "install.sh has the outbox-creating command"
HI="$T/home-install"; mkdir -p "$HI"
HOME="$HI" bash -c "$SNIP"; RC=$?
ID_DIR="$HI/.local/state/fcode/notify"
eq "install snippet: rc 0" "$RC" 0
eq "install snippet: dir mode 700" "$(stat -c %a "$ID_DIR")" 700
eq "install snippet: outbox mode 600" "$(stat -c %a "$ID_DIR/outbox.tsv")" 600
eq "install snippet: outbox is empty" "$(wc -c <"$ID_DIR/outbox.tsv" | tr -d ' ')" 0
# the empty outbox is accepted and appended to (real default path under HOME: no test hooks)
OUT=$(unset FCODE_NOTIFY_TEST; HOME="$HI" bash "$FN" shop info 'into the pre-created outbox'); RC=$?
[[ $OUT =~ ^notify:\ queued\  ]] && [ "$RC" = 0 ] && ok "pre-created empty outbox accepted" || no "pre-created empty outbox accepted ('$OUT' rc=$RC)"
eq "pre-created outbox: one line written" "$(wc -l <"$ID_DIR/outbox.tsv" | tr -d ' ')" 1
eq "pre-created outbox: text stored" "$(cut -f5 "$ID_DIR/outbox.tsv")" 'into the pre-created outbox'
eq "pre-created outbox: mode still 600" "$(stat -c %a "$ID_DIR/outbox.tsv")" 600
OUT=$(unset FCODE_NOTIFY_TEST; HOME="$HI" bash "$FN" shop info 'second note'); RC=$?
eq "second note appended" "$(wc -l <"$ID_DIR/outbox.tsv" | tr -d ' ')" 2
# running the snippet again (an install over an existing outbox) keeps every byte and the mode
cp "$ID_DIR/outbox.tsv" "$T/outbox.before"
HOME="$HI" bash -c "$SNIP"; RC=$?
eq "install snippet again: rc 0" "$RC" 0
cmp -s "$T/outbox.before" "$ID_DIR/outbox.tsv" && ok "install snippet does not truncate an existing outbox" || no "install snippet does not truncate an existing outbox"
eq "install snippet again: mode 600" "$(stat -c %a "$ID_DIR/outbox.tsv")" 600
rm -rf "$HI"

# ---------- concurrency: parallel runs under the lock ----------
fresh
NOW=$BASE
for i in $(seq 8); do ( FCODE_NOTIFY_DIR="$D" FCODE_NOTIFY_NOW=$BASE bash "$FN" "p$i" info "par $i" >"$T/par.$i"; echo $? >>"$T/par.$i" ) & done
wait
eq "8 parallel runs: 8 lines" "$(lines)" 8
eq "8 parallel runs: all queued, rc 0" "$(cat "$T"/par.* | grep -c '^notify: queued ')/$(cat "$T"/par.* | grep -c '^0$')" 8/8
eq "8 parallel runs: ids unique" "$(cut -f1 "$(file)" | sort -u | wc -l | tr -d ' ')" 8
NOW=

# ---------- the contract's one-liner promises ----------
grep -Eq '\b(curl|wget|nc|ssh|scp|telnet)\b' <(grep -v '^#' "$FN") && no "script makes no network call" || ok "script makes no network call"
if [ -f "$ROOT/box/agents-notify.md" ]; then
  grep -qF 'fcode-notify <project> <kind> "<short text>" [link]' "$ROOT/box/agents-notify.md" && ok "agents-notify.md carries the rule" || no "agents-notify.md carries the rule"
  grep -qF 'A session already cut off by its own quota cannot call it.' "$ROOT/box/agents-notify.md" && ok "agents-notify.md stuck line carries the quota limit" || no "agents-notify.md stuck line carries the quota limit"
else no "box/agents-notify.md exists"; fi

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" = 0 ]
