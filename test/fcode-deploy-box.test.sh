#!/usr/bin/env bash
# Tests for box/fcode-deploy.sh (the coder box's CLI for the deploy gate's operator key): what it sends to the VPS, what it refuses before
# sending anything, and the gh checks around `add`. A fake ssh and a fake gh (both log every call) stand in for the VPS and GitHub; nothing
# connects anywhere. Needs: bash, node, sha256sum.
# Usage: bash test/fcode-deploy-box.test.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FD="$ROOT/box/fcode-deploy.sh"
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" FAKE="$T/fake"
unset XDG_CONFIG_HOME GH_TOKEN
mkdir -p "$HOME" "$T/bin"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi; }
has() { if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else no "$1 (no '$2' in $3)"; fi; }
hasnt() { if grep -qF -- "$2" "$3" 2>/dev/null; then no "$1 (found '$2' in $3)"; else ok "$1"; fi; }

# fake ssh: one log line per call = "<all args>\tIN=<sha256 of stdin, or - when ssh -n>"; the answer comes from $FAKE/out.<verb> and $FAKE/rc.<verb>
cat >"$T/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
cmd="${*: -1}"; v="${cmd#* }"; v="${v%% *}"
in=-; n=0; for a in "$@"; do [ "$a" = -n ] && n=1; done
[ "$n" = 1 ] || in=$(cat | sha256sum | cut -d' ' -f1)
printf '%s\tIN=%s\n' "$*" "$in" >>"$FAKE/ssh.log"
[ "$v" = inventory ] && [ -f "$FAKE/busy-after-inv" ] && : >"$FAKE/busy"
[ -f "$FAKE/out.$v" ] && cat "$FAKE/out.$v"
[ -f "$FAKE/rc.$v" ] && exit "$(cat "$FAKE/rc.$v")"
exit 0
FAKE
# fake gh: run list -> N entries (N = $FAKE/runs.<status>, or 1 in_progress once $FAKE/busy exists); deploy-key list -> $FAKE/dk.json; deploy-key add logs the .pub it was given
cat >"$T/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/gh.log"
[ -f "$FAKE/gh.fail" ] && { echo "gh: boom" >&2; exit 1; }
case "$1 $2 $3" in
  "run list -R")
    st=; prev=; for a in "$@"; do [ "$prev" = --status ] && st=$a; prev=$a; done
    c=0; [ -f "$FAKE/runs.$st" ] && c=$(cat "$FAKE/runs.$st"); { [ -f "$FAKE/busy" ] && [ "$st" = in_progress ]; } && c=1
    printf '['; i=0; while [ "$i" -lt "$c" ]; do [ "$i" -gt 0 ] && printf ','; printf '{"databaseId":%s}' "$i"; i=$((i + 1)); done; printf ']\n' ;;
  "repo deploy-key list") cat "$FAKE/dk.json" ;;
  "repo deploy-key add") echo "PUB=$(cat "$4")" >>"$FAKE/gh.log"; [ -f "$FAKE/rc.gh-add" ] && exit "$(cat "$FAKE/rc.gh-add")"; exit 0 ;;
  *) exit 2 ;;
esac
FAKE
chmod +x "$T/bin/ssh" "$T/bin/gh"
export PATH="$T/bin:$PATH"

PK='ssh-ed25519 AAAAC3NzaFAKEKEY'
KEYFILE="$T/operator-key"; : >"$KEYFILE"
SHA40=0123456789abcdef0123456789abcdef01234567
OPTS="-i $KEYFILE -o IdentitiesOnly=yes -o BatchMode=yes vps.test"   # what every ssh call must carry before the remote command
DRAFT="$T/draft.json"
printf '{"registry":{"repo":"acme/shop","name":"shop"},"units":[]}\n' >"$DRAFT"
DSHA=$(sha256sum "$DRAFT" | cut -d' ' -f1)

reset() { # fresh fake world: key present and read-only on GitHub, nothing running
  rm -rf "$FAKE"; mkdir -p "$FAKE"
  export FCODE_DEPLOY_HOST=vps.test FCODE_DEPLOY_KEY="$KEYFILE"
  echo "$PK" >"$FAKE/out.prepare-key"
  printf 'INV unit ok\nINV ok\nGATE_EXIT 0\n' >"$FAKE/out.inventory"
  printf 'GATE_RESULT registered\nGATE_EXIT 0\n' >"$FAKE/out.register"
  echo "[{\"key\":\"$PK fcode-deploy-shop\",\"readOnly\":true}]" >"$FAKE/dk.json"
}
fd() { bash "$FD" "$@" >"$T/out" 2>&1 </dev/null; RC=$?; }   # RC and $T/out
calls() { cut -f1 "$FAKE/ssh.log" 2>/dev/null; }          # the ssh calls, one per line
sent() { [ -f "$FAKE/ssh.log" ] && echo yes || echo no; }

# ---- every verb maps to the exact remote command ----
reset
for v in status recheck pause resume "trust off" "deploy $SHA40"; do
  reset; fd demo $v
  eq "verb '$v': exit 0" "$RC" 0
  eq "verb '$v': exact ssh call" "$(cat "$FAKE/ssh.log")" "-n $OPTS demo $v	IN=-"
done
reset; echo 'PROJECT demo repo=acme/shop branch=main shape=release' >"$FAKE/out.status"; fd demo trust on i-understand-root
eq 'trust on: exit 0' "$RC" 0
eq 'trust on: status first, then the trust call' "$(calls)" "-n $OPTS demo status
-n $OPTS demo trust on i-understand-root"
has 'trust on: warning names repo and branch' 'anyone who can merge to acme/shop main gets root' "$T/out"
reset; fd demo trust on i-understand-root
eq 'trust on: no PROJECT line = refused 65' "$RC" 65
eq 'trust on: refused before the trust call' "$(calls)" "-n $OPTS demo status"

# ---- the gate's lines and exit code pass through ----
for c in 0 1 65 69 70; do
  reset; printf 'GATE_RESULT x\nGATE_EXIT %s\n' "$c" >"$FAKE/out.status"; echo "$c" >"$FAKE/rc.status"; fd demo status
  eq "exit code $c passes through" "$RC" "$c"
  has "gate line shown (code $c)" "GATE_EXIT $c" "$T/out"
done
reset; echo 255 >"$FAKE/rc.status"; fd demo status
eq 'ssh failure 255 passes through' "$RC" 255
has '255 prints a hint' 'không nối được VPS' "$T/out"

# ---- refused locally: nothing is sent ----
refuse() { # refuse <label> <args...>
  local l=$1; shift; reset; fd "$@"
  eq "refused 65: $l" "$RC" 65
  eq "nothing sent: $l" "$(sent)" no
}
refuse 'no arguments'
refuse 'name with capital' Demo status
refuse 'name too short' a status
refuse 'name ends with dash' demo- status
refuse 'name starts with dash' -demo status
refuse 'injection in name' 'x;id' status
refuse 'unknown verb' demo logs
refuse 'unknown verb (rm)' demo rm
refuse 'name only' demo
refuse 'status with an argument' demo status extra
refuse 'status;id as the verb' demo 'status;id'
refuse 'pause with an argument' demo pause now
refuse 'deploy without sha' demo deploy
refuse 'deploy short sha' demo deploy 0123456
refuse 'deploy upper-case sha' demo deploy 0123456789ABCDEF0123456789ABCDEF01234567
refuse 'deploy injection sha' demo deploy "$SHA40;id"
refuse 'deploy 41 hex' demo deploy "${SHA40}0"
refuse 'deploy two args' demo deploy "$SHA40" "$SHA40"
refuse 'trust alone' demo trust
refuse 'trust on without the word' demo trust on
refuse 'trust on wrong word' demo trust on yes
refuse 'trust off with extra' demo trust off now
refuse 'add with 2 args' add acme/shop shop
refuse 'add bad repo' add acme shop "$DRAFT"
refuse 'add repo with ..' add ../x shop "$DRAFT"
refuse 'add bad name' add acme/shop Shop "$DRAFT"
refuse 'add reserved name' add acme/shop gate "$DRAFT"
refuse 'add legacy name' add acme/shop deal-sync "$DRAFT"
refuse 'add 5 args' add acme/shop shop "$DRAFT" --yes extra
reset; bash "$FD" --help >"$T/out" 2>&1; eq '--help exits 0' "$?" 0

# ---- config: host and key ----
reset; unset FCODE_DEPLOY_HOST; fd demo status
eq 'no host: tool error 1' "$RC" 1; eq 'no host: nothing sent' "$(sent)" no
reset; FCODE_DEPLOY_HOST='-oProxyCommand=x' fd demo status
eq 'host that looks like an ssh option: 1' "$RC" 1; eq 'bad host: nothing sent' "$(sent)" no
reset; FCODE_DEPLOY_KEY="$T/none" fd demo status
eq 'no key file: 1' "$RC" 1; eq 'no key file: nothing sent' "$(sent)" no
reset; unset FCODE_DEPLOY_HOST; mkdir -p "$HOME/.config/fcode"; echo 'file.host' >"$HOME/.config/fcode/deploy-host"; fd demo status
eq 'host from the config file' "$(cut -f1 "$FAKE/ssh.log")" "-n -i $KEYFILE -o IdentitiesOnly=yes -o BatchMode=yes file.host demo status"
rm -rf "$HOME/.config"

# ---- add without --yes: checks, key, INV lines, then stop ----
reset; fd add acme/shop shop "$DRAFT"
eq 'add: exit 0' "$RC" 0
eq 'add (no --yes): prepare-key then inventory, nothing else' "$(calls)" "-n $OPTS shop prepare-key
$OPTS shop inventory"
hasnt 'add (no --yes): never sends register' ' register ' "$FAKE/ssh.log"
has 'add (no --yes): inventory carries the draft on stdin' "shop inventory	IN=$DSHA" "$FAKE/ssh.log"
has 'add (no --yes): INV lines printed' 'INV ok' "$T/out"
has 'add (no --yes): says to rerun with --yes' 'chạy lại với --yes để đăng ký' "$T/out"
has 'add: sha256 printed' "$DSHA" "$T/out"
hasnt 'add: key already on GitHub, not added again' 'deploy-key add' "$FAKE/gh.log"
# a key GitHub has not seen yet is added read-only (no --allow-write), as a public-key file
reset; echo '[]' >"$FAKE/dk.json"; fd add acme/shop shop "$DRAFT"
eq 'add, key missing on GitHub: exit 0' "$RC" 0
has 'add: deploy-key add with the repo and the read-only title' 'repo deploy-key add' "$FAKE/gh.log"
has 'add: title says read-only' '--title fcode deploy shop (read-only)' "$FAKE/gh.log"
hasnt 'add: never asks for write access' 'allow-write' "$FAKE/gh.log"
has 'add: the public key was the file given to gh' "PUB=$PK" "$FAKE/gh.log"
reset; echo '[]' >"$FAKE/dk.json"; echo 1 >"$FAKE/rc.gh-add"; fd add acme/shop shop "$DRAFT"
eq 'add: gh refuses the key = 1' "$RC" 1
eq 'add: gh add failed, inventory not reached' "$(calls)" "-n $OPTS shop prepare-key"

# ---- add --yes ----
reset; fd add acme/shop shop "$DRAFT" --yes
eq 'add --yes: exit 0' "$RC" 0
eq 'add --yes: prepare-key, inventory, register in that order' "$(calls)" "-n $OPTS shop prepare-key
$OPTS shop inventory
$OPTS shop register $DSHA"
has 'add --yes: register carries the draft on stdin' "shop register $DSHA	IN=$DSHA" "$FAKE/ssh.log"
has 'add --yes: next steps printed' "fcode-deploy shop status" "$T/out"
reset; fd add --yes acme/shop shop "$DRAFT"
eq 'add: --yes before the arguments works too' "$(calls | tail -n 1 | cut -d' ' -f8-9)" "shop register"
reset; echo 70 >"$FAKE/rc.register"; echo 'BLOCKED x' >"$FAKE/out.status"; fd add acme/shop shop "$DRAFT" --yes
eq 'add --yes: register 70 passes through' "$RC" 70
has 'add --yes: 70 shows status' 'BLOCKED x' "$T/out"
reset; echo 1 >"$FAKE/rc.register"; fd add acme/shop shop "$DRAFT" --yes
eq 'add --yes: register 1 passes through' "$RC" 1
# a BOM is dropped and the sha256 is of the bytes actually sent
printf '\xef\xbb\xbf' >"$T/bom.json"; cat "$DRAFT" >>"$T/bom.json"
reset; fd add acme/shop shop "$T/bom.json" --yes
eq 'add --yes with a BOM draft: exit 0' "$RC" 0
has 'add --yes with a BOM draft: sha256 of the bytes after the BOM' "shop register $DSHA	IN=$DSHA" "$FAKE/ssh.log"

# ---- Actions in flight ----
reset; echo 2 >"$FAKE/runs.in_progress"; fd add acme/shop shop "$DRAFT" --yes
eq 'add --yes, runs in progress: refused 65' "$RC" 65
eq 'add --yes, runs in progress: nothing sent' "$(sent)" no
has 'add --yes, runs in progress: says so' 'runs-in-flight' "$T/out"
reset; echo 1 >"$FAKE/runs.queued"; fd add acme/shop shop "$DRAFT" --yes
eq 'add --yes, runs queued: refused 65' "$RC" 65
eq 'add --yes, runs queued: nothing sent' "$(sent)" no
reset; echo 2 >"$FAKE/runs.in_progress"; fd add acme/shop shop "$DRAFT"
eq 'add (no --yes), runs in progress: refused 65' "$RC" 65
reset; : >"$FAKE/busy-after-inv"; fd add acme/shop shop "$DRAFT" --yes
eq 'add --yes, run starts during the inventory: refused 65 before register' "$RC" 65
hasnt 'add --yes, run starts during the inventory: register never sent' ' register ' "$FAKE/ssh.log"
has 'add --yes, run starts during the inventory: inventory was sent' ' inventory' "$FAKE/ssh.log"
reset; : >"$FAKE/gh.fail"; fd add acme/shop shop "$DRAFT" --yes
eq 'add --yes, gh cannot tell: 1' "$RC" 1
eq 'add --yes, gh cannot tell: nothing sent' "$(sent)" no

# ---- the deploy key must be read-only (both spellings of the field) ----
reset; echo "[{\"key\":\"$PK x\",\"readOnly\":false}]" >"$FAKE/dk.json"; fd add acme/shop shop "$DRAFT" --yes
eq 'key with write access (readOnly:false): refused 65' "$RC" 65
eq 'key with write access: only prepare-key was sent' "$(calls)" "-n $OPTS shop prepare-key"
has 'key with write access: says so' 'CÓ quyền ghi' "$T/out"
reset; echo "[{\"key\":\"$PK x\",\"read_only\":false}]" >"$FAKE/dk.json"; fd add acme/shop shop "$DRAFT" --yes
eq 'key with write access (read_only:false): refused 65' "$RC" 65
reset; echo "[{\"key\":\"$PK x\"}]" >"$FAKE/dk.json"; fd add acme/shop shop "$DRAFT" --yes
eq 'key with no read-only field at all: refused 65' "$RC" 65
reset; echo "[{\"key\":\"$PK x\",\"read_only\":true}]" >"$FAKE/dk.json"; fd add acme/shop shop "$DRAFT" --yes
eq 'read_only:true is accepted' "$RC" 0
reset; echo "[{\"key\":\"$PK x\",\"readOnly\":true}]" >"$FAKE/dk.json"; fd add acme/shop shop "$DRAFT" --yes
eq 'readOnly:true is accepted' "$RC" 0
reset; echo "[{\"key\":\"ssh-ed25519 AAAAother\",\"readOnly\":false},{\"key\":\"$PK\",\"read_only\":true}]" >"$FAKE/dk.json"; fd add acme/shop shop "$DRAFT" --yes
eq 'another key with write access does not matter' "$RC" 0
reset; echo 'not json' >"$FAKE/dk.json"; fd add acme/shop shop "$DRAFT" --yes
eq 'unreadable key list: 1' "$RC" 1
eq 'unreadable key list: register not sent' "$(calls | grep -c ' register ')" 0

# ---- the gate's answers decide ----
reset; printf 'INV unit refuse missing\nINV refuse\nGATE_EXIT 65\n' >"$FAKE/out.inventory"; fd add acme/shop shop "$DRAFT" --yes
eq 'INV refuse: refused 65' "$RC" 65
hasnt 'INV refuse: register never sent' ' register ' "$FAKE/ssh.log"
reset; printf 'INV ok\nINV unit extra\n' >"$FAKE/out.inventory"; fd add acme/shop shop "$DRAFT" --yes
eq 'the last INV line must be INV ok' "$RC" 65
reset; echo 'GATE_EXIT 0' >"$FAKE/out.inventory"; fd add acme/shop shop "$DRAFT" --yes
eq 'no INV line at all: refused 65' "$RC" 65
reset; echo 'INV ok' >"$FAKE/out.inventory"; echo 69 >"$FAKE/rc.inventory"; fd add acme/shop shop "$DRAFT" --yes
eq 'inventory exit code passes through' "$RC" 69
hasnt 'inventory failed: register never sent' ' register ' "$FAKE/ssh.log"
reset; printf 'GATE_ERROR legacy project\nGATE_EXIT 65\n' >"$FAKE/out.prepare-key"; echo 65 >"$FAKE/rc.prepare-key"; fd add acme/shop shop "$DRAFT" --yes
eq 'prepare-key refused: its code passes through' "$RC" 65
has 'prepare-key refused: the gate line is shown' 'GATE_ERROR legacy project' "$T/out"
eq 'prepare-key refused: nothing else sent' "$(calls | wc -l | tr -d ' ')" 1
reset; echo 'GATE_EXIT 0' >"$FAKE/out.prepare-key"; fd add acme/shop shop "$DRAFT" --yes
eq 'prepare-key without a public key line: 1' "$RC" 1

# ---- the draft is checked locally ----
reset; printf '{"registry":{"repo":"acme/shop","name":"other"}}' >"$T/d2.json"; fd add acme/shop shop "$T/d2.json" --yes
eq 'draft name differs from the command line: 65' "$RC" 65; eq 'draft name differs: nothing sent' "$(sent)" no
reset; printf '{"registry":{"repo":"acme/other","name":"shop"}}' >"$T/d3.json"; fd add acme/shop shop "$T/d3.json" --yes
eq 'draft repo differs from the command line: 65' "$RC" 65; eq 'draft repo differs: nothing sent' "$(sent)" no
reset; printf '{nope' >"$T/d4.json"; fd add acme/shop shop "$T/d4.json" --yes
eq 'draft is not JSON: 65' "$RC" 65; eq 'draft not JSON: nothing sent' "$(sent)" no
reset; head -c 16385 /dev/zero | tr '\0' ' ' >"$T/d5.json"; fd add acme/shop shop "$T/d5.json" --yes
eq 'draft over 16 KiB: 65' "$RC" 65; eq 'draft over 16 KiB: nothing sent' "$(sent)" no
reset; fd add acme/shop shop "$T/missing.json" --yes
eq 'draft file missing: 65' "$RC" 65; eq 'draft missing: nothing sent' "$(sent)" no
reset; : >"$T/d6.json"; fd add acme/shop shop "$T/d6.json" --yes
eq 'empty draft: 65' "$RC" 65

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
