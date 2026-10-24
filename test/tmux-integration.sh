#!/usr/bin/env bash
# Linux-only integration test: the real server against REAL tmux on a private socket (tmux -L pcit-<pid>).
# Needs: bash, node 22, tmux, curl, cmp. Never touches the default tmux socket, never publishes a port.
# Usage: bash test/tmux-integration.sh      (run from anywhere; server.mjs is the parent folder of test/)
# The server runs with HOME=$RUN/home, so the harness PATH (A3: $HOME/.local/bin first) finds the fake omp/codex there.
# Last section (skipped without systemctl --user or a real ~/.local/bin/omp): a THROWAWAY unit built from
# install.sh's directives (fcoding-it-<pid>.service, socket pcunit-<pid>) proves the real omp opens and stays alive.
# Every name is per run ($$), so two runs cannot collide; override with PC_IT_ID / PC_IT_PORT / PC_IT_UPORT.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ID=${PC_IT_ID:-$$}
RUN=/tmp/pc-it-run-$ID
PORT=${PC_IT_PORT:-$((20000 + 2 * (ID % 10000)))}   # even; the unit gets PORT+1, so runs never share a port
UPORT=${PC_IT_UPORT:-$((PORT + 1))}
SOCK=pcit-$ID; USOCK=pcunit-$ID
export PC_TMUX="[\"tmux\",\"-L\",\"$SOCK\"]"
export PC_CONFIG_DIR="$RUN/cfg"
export PC_PORT=$PORT
export LANG=C.UTF-8 LC_ALL=C.UTF-8
BASE="http://127.0.0.1:$PORT"
OUT="$RUN/out.txt"; EXP="$RUN/expected.txt"; RESP="$RUN/resp.txt"
PASS=0; FAIL=0; SERVER_PID=""
REAL_HOME=$HOME
UNIT=fcoding-it-$ID; UNIT_FILE="${XDG_CONFIG_HOME:-$REAL_HOME/.config}/systemd/user/$UNIT.service"

T() { tmux -L "$SOCK" "$@"; }   # the ONLY way this script runs tmux
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  pkill -f "curl .*127.0.0.1:$PORT" 2>/dev/null
  T kill-server 2>/dev/null
  if [ -f "$UNIT_FILE" ]; then systemctl --user stop "$UNIT" 2>/dev/null; rm -f "$UNIT_FILE"; systemctl --user daemon-reload 2>/dev/null; fi
  tmux -L "$USOCK" kill-server 2>/dev/null
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$USOCK" # tmux leaves the socket file
  rm -rf "$RUN"
}
trap cleanup EXIT
ok()   { PASS=$((PASS+1)); echo "ok   - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL - $1${2:+ ($2)}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
jf() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);console.log(eval("j."+process.argv[1]))})' "$1"; }
jbody() { node -e 'process.stdout.write(JSON.stringify({text:process.argv[1],enter:process.argv[2]==="true"}))' -- "$1" "$2"; }

command -v tmux >/dev/null && command -v curl >/dev/null && command -v node >/dev/null || { echo "need tmux, curl, node"; exit 2; }
[ "$(uname -s)" = Linux ] || { echo "Linux only"; exit 2; }
T kill-server 2>/dev/null
rm -rf "$RUN"; mkdir -p "$RUN/work" "$RUN/home/.local/bin"; chmod 700 "$RUN"
# fake harnesses, found only through the server's explicit PATH ($HOME/.local/bin)
printf '#!/bin/sh\nexit 3\n' >"$RUN/home/.local/bin/omp"                                # exits at once
printf '#!/bin/sh\necho "FAKE-CODEX-UP P=$PATH"\nexec sleep 600\n' >"$RUN/home/.local/bin/codex"   # stays up
printf '#!/bin/sh\nsleep 0.2\nexit 3\n' >"$RUN/home/.local/bin/claude"                     # exits after 0.2 s
chmod +x "$RUN/home/.local/bin/omp" "$RUN/home/.local/bin/codex" "$RUN/home/.local/bin/claude"

# ---- config: random cookie secret + one project (no password: devices are paired, A4) ----
mkdir -p "$PC_CONFIG_DIR"; chmod 700 "$PC_CONFIG_DIR"
node -e '
  const fs=require("fs"),c={cookieSecret:require("crypto").randomBytes(32).toString("base64"),projects:{work:process.argv[1]},port:7681};
  fs.writeFileSync(process.env.PC_CONFIG_DIR+"/config.json",JSON.stringify(c),{mode:0o600})' "$RUN/work"
# the fcode-pair wrapper exactly as install.sh writes it, pointed at this run's config and server
WRAPBODY=$(sed -n '/^cat > "\$HOME\/.local\/bin\/fcode-pair" <<WRAP$/,/^WRAP$/p' "$ROOT/install.sh" | sed '1d;$d')
APP="$ROOT" CFG="$PC_CONFIG_DIR" WRAPBODY="$WRAPBODY" bash -c 'eval "cat <<WRAP
$WRAPBODY
WRAP"' >"$RUN/fcode-pair"; chmod 755 "$RUN/fcode-pair"
grep -q -- "--pair" "$RUN/fcode-pair" || { echo "fcode-pair wrapper not found in install.sh"; exit 2; }
# install.sh on an older install: passwordHash is dropped atomically, cookieSecret and the rest kept; a second run is a no-op
eval "$(sed -n '/^strip_password_hash() {/,/^}$/p' "$ROOT/install.sh")"
node -e '
  const fs=require("fs"),c=JSON.parse(fs.readFileSync(process.argv[1]));c.passwordHash={salt:"x",hash:"y"};
  fs.writeFileSync(process.argv[2],JSON.stringify(c),{mode:0o644})' "$PC_CONFIG_DIR/config.json" "$RUN/old.json"
strip_password_hash "$RUN/old.json"
check "install.sh drops passwordHash, keeps cookieSecret and projects" "$(node -e '
  const fs=require("fs"),o=JSON.parse(fs.readFileSync(process.argv[1])),c=JSON.parse(fs.readFileSync(process.argv[2]));
  console.log(!("passwordHash" in o) && o.cookieSecret===c.cookieSecret && JSON.stringify(o.projects)===JSON.stringify(c.projects))' "$RUN/old.json" "$PC_CONFIG_DIR/config.json")" true
check "rewritten config is mode 600" "$(stat -c %a "$RUN/old.json")" 600
BEFORE=$(stat -c '%i %Y %s' "$RUN/old.json"; sha256sum <"$RUN/old.json")
sleep 1.1; strip_password_hash "$RUN/old.json"
check "second strip is a no-op" "$(stat -c '%i %Y %s' "$RUN/old.json"; sha256sum <"$RUN/old.json")" "$BEFORE"
[ -e "$RUN/old.json.tmp" ] && bad "no tmp file left" || ok "no tmp file left"

# ---- config dir hygiene: loose modes are repaired, a symlinked dir is refused ----
chmod 777 "$PC_CONFIG_DIR"; chmod 666 "$PC_CONFIG_DIR/config.json"
ln -s "$PC_CONFIG_DIR" "$RUN/cfglink"
if PC_CONFIG_DIR="$RUN/cfglink" timeout 5 node "$ROOT/server.mjs" >"$RUN/link.out" 2>&1; then bad "symlinked config dir refused"; else
  grep -q "unsafe config path" "$RUN/link.out" && ok "symlinked config dir refused" || bad "symlinked config dir refused" "$(cat "$RUN/link.out")"; fi

# ---- malformed config at startup: exit 1, nothing of the file printed ----
cp "$PC_CONFIG_DIR/config.json" "$RUN/good.json"
printf '{"cookieSecret":"SEKRET-it' >"$PC_CONFIG_DIR/config.json"
timeout 5 node "$ROOT/server.mjs" >"$RUN/bad.out" 2>&1; check "malformed config at startup -> exit 1" "$?" 1
grep -q SEKRET "$RUN/bad.out" && bad "startup error leaks config text" || ok "startup error does not leak config text"
cp "$RUN/good.json" "$PC_CONFIG_DIR/config.json"; chmod 777 "$PC_CONFIG_DIR"; chmod 666 "$PC_CONFIG_DIR/config.json"

# ---- a tmux server that already runs WITHOUT ~/.local/bin on PATH (the server must not depend on its PATH) ----
env -i HOME="$RUN/home" PATH=/usr/bin:/bin tmux -L "$SOCK" new-session -d -s keeper 'sleep 3600'
T show-environment -g PATH | grep -q '.local/bin' && bad "keeper tmux PATH is bare" || ok "pre-existing tmux server has a bare PATH"

# ready = OUR process listens on the port (never talk to another run's server); exit if it died
owns() { ss -ltnpH "sport = :$1" 2>/dev/null | grep -q "pid=$2,"; }
await_ready() { # await_ready PORT PID LABEL
  for _ in $(seq 100); do owns "$1" "$2" && break; kill -0 "$2" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$2" 2>/dev/null && owns "$1" "$2" || { echo "FATAL - $3 (pid $2) is not serving port $1 (port taken?)"; exit 1; }
}
start_server() {
  HOME="$RUN/home" node "$ROOT/server.mjs" >>"$RUN/server.log" 2>&1 &
  SERVER_PID=$!
  await_ready "$PORT" "$SERVER_PID" server
}
start_server
check "GET / body" "$(curl -s "$BASE/")" "fcoding ok"
check "config dir mode repaired to 700" "$(stat -c %a "$PC_CONFIG_DIR")" "700"
check "config.json mode repaired to 600" "$(stat -c %a "$PC_CONFIG_DIR/config.json")" "600"

# ---- pairing via the CLI (fcode-pair), then the Bearer token as the iOS app uses it ----
check "admin.sock mode 600" "$(stat -c %a "$PC_CONFIG_DIR/admin.sock")" 600
pair_token() { # pair_token BASEURL PAIRCMD... -> prints the token
  local base=$1; shift
  local code; code=$("$@" | sed -n 's/^Mã ghép: \([0-9]\{6\}\) .*/\1/p')
  curl -s -X POST -H 'X-PC: 1' -H 'Content-Type: application/json' -d "{\"code\":\"$code\"}" "$base/api/pair" | jf token
}
CODE=$("$RUN/fcode-pair" it phone | sed -n 's/^Mã ghép: \([0-9]\{6\}\) .*/\1/p')
[ -n "$CODE" ] && ok "fcode-pair prints a 6-digit code" || bad "fcode-pair code"
WRONG=$(( (10#$CODE + 1) % 1000000 )); WRONG=$(printf '%06d' "$WRONG")
check "wrong code -> 401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'X-PC: 1' -H 'Content-Type: application/json' -d "{\"code\":\"$WRONG\"}" "$BASE/api/pair")" 401
LOGIN=$(curl -s -X POST -H 'X-PC: 1' -H 'Content-Type: application/json' -d "{\"code\":\"$CODE\"}" "$BASE/api/pair")
TOKEN=$(printf '%s' "$LOGIN" | jf token)
[ -n "$TOKEN" ] && [ "$TOKEN" != undefined ] && ok "pairing gives a token" || { bad "pairing" "$LOGIN"; exit 1; }
check "the code is single use" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'X-PC: 1' -H 'Content-Type: application/json' -d "{\"code\":\"$CODE\"}" "$BASE/api/pair")" 401
check "devices.json mode 600" "$(stat -c %a "$PC_CONFIG_DIR/devices.json")" 600
grep -q "$TOKEN" "$PC_CONFIG_DIR/devices.json" && bad "devices.json holds no token" || ok "devices.json holds no token"
node "$ROOT/server.mjs" --devices | grep -q '  it phone$' && ok "--devices lists the phone" || bad "--devices"
api() { # api METHOD PATH [JSON]  -> prints the HTTP status, body in $RESP
  curl -s -o "$RESP" -w '%{http_code}' -X "$1" -H 'X-PC: 1' -H "Authorization: Bearer $TOKEN" \
    ${3:+-H 'Content-Type: application/json' --data-binary "$3"} "$BASE$2"
}
[ -e "$PC_CONFIG_DIR/sessions.json" ] && bad "no sessions.json (memory only)" || ok "no sessions.json (memory only)"

# ---- harness PATH (A3) on the pre-existing bare-PATH tmux server ----
check "open codex (fake, via \$HOME/.local/bin)" "$(api POST /api/open '{"project":"work","harness":"codex"}')" 200
sleep 1.5
api GET /api/sessions >/dev/null
grep -q '"name":"work-codex"' "$RESP" && ok "fake codex stays alive" || bad "fake codex alive" "$(head -c 300 "$RESP")"
api GET /api/screen/work-codex >/dev/null
grep -q FAKE-CODEX-UP "$RESP" && ok "fake codex output on screen" || bad "fake codex screen" "$(head -c 300 "$RESP")"
grep -q "P=$RUN/home/.local/bin:$RUN/home/.bun/bin:/usr/local/bin:/usr/bin:/bin" "$RESP" && ok "harness PATH is explicit" || bad "harness PATH" "$(head -c 400 "$RESP")"
check "open omp that exits at once -> 500" "$(api POST /api/open '{"project":"work","harness":"omp"}')" 500
check "error harness_exited" "$(jf error <"$RESP")" harness_exited
check "create omp that exits at once -> 500" "$(api POST /api/sessions '{"name":"dies","project":"work","harness":"omp"}')" 500
check "error harness_exited (create)" "$(jf error <"$RESP")" harness_exited
check "open claude that exits after 0.2 s -> 500" "$(api POST /api/open '{"project":"work","harness":"claude"}')" 500
check "error harness_exited (late exit)" "$(jf error <"$RESP")" harness_exited
check "delete work-codex" "$(api DELETE /api/sessions/work-codex)" 200
T kill-session -t =keeper

# ---- sessions: /api/open + create + list ----
check "open creates" "$(api POST /api/open '{"project":"work","harness":"shell"}')" 200
check "open created:true" "$(jf created <"$RESP")" true
check "open again reuses" "$(api POST /api/open '{"project":"work","harness":"shell"}')" 200
check "open created:false" "$(jf created <"$RESP")" false
api GET /api/sessions >/dev/null
check "session name" "$(jf 'sessions[0].name' <"$RESP")" "work-shell"
check "session meta" "$(jf 'sessions[0].project+"/"+j.sessions[0].harness' <"$RESP")" "work/shell"
check "create it1" "$(api POST /api/sessions '{"name":"it1","project":"work","harness":"shell"}')" 201
check "create it1 again -> 409" "$(api POST /api/sessions '{"name":"it1","project":"work","harness":"shell"}')" 409
check "exact targets: 'it' does not prefix-match it1" "$(api GET /api/screen/it)" 404
sleep 1.2

# ---- byte-exact typing into `cat > file` ----
roundtrip() { # roundtrip LABEL TEXT   (sent with enter:false, then Enter and Ctrl-D)
  rm -f "$OUT"
  api POST /api/send/it1 "$(jbody "cat > $OUT" true)" >/dev/null; sleep 0.5
  local st; st=$(api POST /api/send/it1 "$(jbody "$2" false)")
  api POST /api/key/it1 '{"key":"Enter"}' >/dev/null
  api POST /api/key/it1 '{"key":"C-d"}' >/dev/null
  printf '%s\n' "$2" >"$EXP"
  for _ in $(seq 25); do cmp -s "$OUT" "$EXP" && break; sleep 0.2; done
  if [ "$st" = 200 ] && cmp -s "$OUT" "$EXP"; then ok "byte-exact: $1"; else bad "byte-exact: $1" "http $st; got $(head -c 200 "$OUT" 2>/dev/null | od -c | head -3 | tr '\n' ' ')"; fi
}
roundtrip "Vietnamese one line" "Xin chào, tiếng Việt có dấu: ắ ẫ ợ ữ"
roundtrip "Vietnamese multi-line + shell metachars" $'Dòng 1: ắ ẫ ợ ữ 😀\nDòng 2: "quote" \'x\' $HOME `id`; rm -rf /\n\ttab và \\n'
roundtrip "trailing semicolon" "let x = 1;"
roundtrip "backslash-semicolon" 'a\;'
roundtrip "lone semicolon" ";"
roundtrip "double semicolon" "a;;"
roundtrip "semicolons only" ";;"
roundtrip "tmux syntax stays literal" "x ; kill-server"
roundtrip "option-like text" "-l -- -t x"
roundtrip "tmux format-like text" '#{pane_id} #(id) ~ $(id)'
roundtrip "long line via buffer" "$(printf 'ắ%.0s' $(seq 600))"
roundtrip "multi-line ending in semicolon" $'one;\ntwo;'
T ls >/dev/null 2>&1 && ok "tmux server still alive after literal 'kill-server' text" || bad "tmux server died"

# ---- keys ----
rm -f "$OUT"; api POST /api/send/it1 "$(jbody "cat > $OUT" true)" >/dev/null; sleep 0.5
api POST /api/send/it1 "$(jbody ab false)" >/dev/null
for k in BSpace y Space n Enter C-d; do api POST /api/key/it1 "{\"key\":\"$k\"}" >/dev/null; done
sleep 0.6; printf 'ay n\n' >"$EXP"; cmp -s "$OUT" "$EXP" && ok "keys BSpace y Space n Enter C-d" || bad "keys" "$(od -c "$OUT" | head -2)"
check "bad key rejected" "$(api POST /api/key/it1 '{"key":"F13"}')" 400
check "repeat key" "$(api POST /api/key/it1 '{"key":"Down","repeat":3}')" 200

# ---- screen + resize ----
api POST /api/send/it1 "$(jbody "echo SCREEN-MARK-ắ" true)" >/dev/null; sleep 0.6
check "screen http" "$(api GET '/api/screen/it1?lines=100')" 200
grep -q "SCREEN-MARK-ắ" "$RESP" && ok "screen text has the output (UTF-8)" || bad "screen text" "$(head -c 300 "$RESP")"
check "resize" "$(api POST /api/resize/it1 '{"cols":100,"rows":30}')" 200
api GET '/api/screen/it1?lines=100' >/dev/null
check "pane width after resize" "$(jf cols <"$RESP")" 100
check "pane height after resize" "$(jf rows <"$RESP")" 30

# ---- linear trim on real tmux: 2100 lines of 300 spaces (was 1.4 s with the old regex) ----
check "resize 300 cols" "$(api POST /api/resize/it1 '{"cols":300,"rows":50}')" 200
api POST /api/send/it1 "$(jbody "clear; for i in \$(seq 2100); do printf '%300s\\n' ''; done; echo END-MARK" true)" >/dev/null; sleep 2
SECS=$(curl -s -o "$RESP" -w '%{time_total}' -H "Authorization: Bearer $TOKEN" "$BASE/api/screen/it1?lines=2000")
grep -q END-MARK "$RESP" && ok "trim keeps the output" || bad "trim output" "$(tail -c 200 "$RESP")"
node -e 'process.exit(Number(process.argv[1]) < 0.3 ? 0 : 1)' "$SECS" && ok "screen with 2000 blank 300-col lines in ${SECS}s (< 0.3 s)" || bad "trim time" "${SECS}s"
api POST /api/send/it1 "$(jbody clear true)" >/dev/null

# ---- SSE: screen event, then gone when the session is deleted ----
check "create it2" "$(api POST /api/sessions '{"name":"it2","project":"work","harness":"shell"}')" 201
curl -sN -H 'X-PC: 1' -H "Authorization: Bearer $TOKEN" "$BASE/api/stream/it2" >"$RUN/sse.out" &
for _ in $(seq 40); do grep -q "event: screen" "$RUN/sse.out" 2>/dev/null && break; sleep 0.1; done
grep -q "^retry: 3000" "$RUN/sse.out" && grep -q "event: screen" "$RUN/sse.out" && ok "SSE retry + screen event" || bad "SSE start" "$(head -c 200 "$RUN/sse.out")"
check "delete it2" "$(api DELETE /api/sessions/it2)" 200
for _ in $(seq 40); do grep -q "event: gone" "$RUN/sse.out" && break; sleep 0.1; done
grep -q "event: gone" "$RUN/sse.out" && ok "SSE gone after delete" || bad "SSE gone"
check "delete missing -> 404" "$(api DELETE /api/sessions/it2)" 404

# ---- stream capacity does not leak: 60 aborted, then 50 fresh streams must all be accepted ----
for _ in $(seq 60); do curl -s -m 0.03 -o /dev/null -H 'X-PC: 1' -H "Authorization: Bearer $TOKEN" "$BASE/api/stream/it1" & done
wait $(jobs -p | grep -v "^$SERVER_PID$") 2>/dev/null
sleep 1
# opened one by one: a stream whose first capture finds no free read slot gets 503 busy and is retried
GOOD=0
for i in $(seq 50); do
  for _try in 1 2 3 4 5; do
    rm -f "$RUN/h.$i"
    curl -s -m 10 -o /dev/null -D "$RUN/h.$i" -H 'X-PC: 1' -H "Authorization: Bearer $TOKEN" "$BASE/api/stream/it1" &
    for _ in $(seq 40); do grep -q '^HTTP' "$RUN/h.$i" 2>/dev/null && break; sleep 0.05; done
    grep -q '^HTTP/1.1 200' "$RUN/h.$i" && { GOOD=$((GOOD+1)); break; }
    sleep 0.1
  done
done
check "50 fresh streams accepted after 60 aborted ones" "$GOOD" 50
check "51st stream -> 503 busy" "$(curl -s -m 2 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$BASE/api/stream/it1")" 503
pkill -f "curl .*127.0.0.1:$PORT/api/stream" 2>/dev/null
sleep 1

# ---- delete everything, server still fine ----
check "delete it1" "$(api DELETE /api/sessions/it1)" 200
check "delete work-shell" "$(api DELETE /api/sessions/work-shell)" 200
api GET /api/sessions >/dev/null
check "sessions empty" "$(jf 'sessions.length' <"$RESP")" 0
# ---- malformed config at reload keeps the old one ----
printf '{"broken' >"$PC_CONFIG_DIR/config.json"
check "malformed config at reload: token still valid" "$(api GET /api/me)" 200
cp "$RUN/good.json" "$PC_CONFIG_DIR/config.json"
check "repaired config: token still valid (same secret)" "$(api GET /api/me)" 200
check "logout" "$(api POST /api/logout)" 200
check "token dead after logout" "$(api GET /api/me)" 401
kill -0 "$SERVER_PID" 2>/dev/null && ok "server process alive at the end" || bad "server died"

# ---- paired devices survive a restart; --revoke goes through admin.sock ----
TOKEN=$(pair_token "$BASE" "$RUN/fcode-pair" second phone)
check "fresh pairing works" "$(api GET /api/me)" 200
kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null
"$RUN/fcode-pair" x >"$RUN/down.out" 2>&1; check "fcode-pair with the server down -> exit 1" "$?" 1
grep -q "not running" "$RUN/down.out" && ok "fcode-pair says the server is not running" || bad "server-down message" "$(cat "$RUN/down.out")"
start_server
check "after restart the token still works" "$(api GET /api/me)" 200
DEV=$(node "$ROOT/server.mjs" --devices | awk '/  second phone$/ {print $1}')
check "--revoke <id>" "$(node "$ROOT/server.mjs" --revoke "$DEV")" "revoked: 1"
check "revoked token -> 401" "$(api GET /api/me)" 401
grep -qiE "password|$TOKEN|$CODE|Xin chào|SCREEN-MARK" "$RUN/server.log" && bad "server log contains secrets/text" || ok "server log is clean"

kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""
T kill-server 2>/dev/null

# ---- THROWAWAY systemd --user unit from install.sh's directives: the real omp opens and stays alive ----
if systemctl --user show-environment >/dev/null 2>&1 && [ -x "$REAL_HOME/.local/bin/omp" ]; then
  UBASE="http://127.0.0.1:$UPORT"
  mkdir -p "$RUN/unitcfg" "$(dirname "$UNIT_FILE")"; chmod 700 "$RUN/unitcfg"
  cp "$RUN/good.json" "$RUN/unitcfg/config.json"; chmod 600 "$RUN/unitcfg/config.json"
  BODY=$(sed -n '/^cat > "\$UNIT_DIR\/fcoding.service" <<UNIT$/,/^UNIT$/p' "$ROOT/install.sh" | sed '1d;$d')
  APP="$ROOT" CFG="$RUN/unitcfg" BODY="$BODY" bash -c 'eval "cat <<UNIT
$BODY
UNIT"' | sed "s|^\[Service\]\$|[Service]\nEnvironment='PC_TMUX=[\"tmux\",\"-L\",\"$USOCK\"]'\nEnvironment=PC_PORT=$UPORT|" >"$UNIT_FILE"
  grep -q '^KillMode=process' "$UNIT_FILE" && grep -q "^ExecStart=.*node $ROOT/server.mjs" "$UNIT_FILE" && ok "throwaway unit built from install.sh" || bad "unit file" "$(cat "$UNIT_FILE")"
  systemctl --user daemon-reload
  unit_case() { # unit_case LABEL
    systemctl --user restart "$UNIT"
    local pid; pid=$(systemctl --user show -p MainPID --value "$UNIT")
    [ "${pid:-0}" -gt 0 ] || { echo "FATAL - $UNIT has no MainPID"; exit 1; }
    await_ready "$UPORT" "$pid" "$UNIT"
    local tok st
    tok=$(pair_token "$UBASE" env PC_CONFIG_DIR="$RUN/unitcfg" node "$ROOT/server.mjs" --pair "unit $1")
    [ -n "$tok" ] && [ "$tok" != undefined ] && ok "unit, $1: paired through admin.sock" || bad "unit, $1: pairing"
    st=$(curl -s -o "$RESP" -w '%{http_code}' -X POST -H 'X-PC: 1' -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d '{"project":"work","harness":"omp"}' "$UBASE/api/open")
    check "unit, $1: open omp" "$st" 200
    sleep 5
    curl -s -o "$RESP" -H "Authorization: Bearer $tok" "$UBASE/api/sessions"
    grep -q '"name":"work-omp"' "$RESP" && ok "unit, $1: omp alive after 5 s" || bad "unit, $1: omp alive" "$(head -c 300 "$RESP")"
    curl -s -o "$RESP" -H "Authorization: Bearer $tok" "$UBASE/api/screen/work-omp"
    [ "$(jf 'text.trim().length > 0' <"$RESP")" = true ] && ok "unit, $1: omp draws a screen" || bad "unit, $1: omp screen" "$(head -c 300 "$RESP")"
    systemctl --user stop "$UNIT"
    tmux -L "$USOCK" kill-server 2>/dev/null
  }
  tmux -L "$USOCK" kill-server 2>/dev/null
  unit_case "fresh tmux server"
  env -i HOME="$REAL_HOME" PATH=/usr/bin:/bin tmux -L "$USOCK" new-session -d -s keeper 'sleep 3600'
  tmux -L "$USOCK" show-environment -g PATH | grep -q '.local/bin' && bad "pcunit keeper PATH bare" || ok "pcunit tmux server pre-started with a bare PATH"
  unit_case "pre-existing bare-PATH tmux server"
  journalctl --user -u "$UNIT" --no-pager 2>/dev/null | grep -qiE "password|SEKRET|Bearer" && bad "unit log clean" || ok "unit log clean"
else
  echo "skip - systemd unit section (no systemctl --user or no $REAL_HOME/.local/bin/omp)"
fi

echo "RESULT pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
