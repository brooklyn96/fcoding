#!/usr/bin/env bash
# Tests for box/fcode-git-sync.sh: it only fetches and reports; it never changes a repository.
# Needs: bash, git, node (flock only for the overlap test). Everything runs in a temp HOME with temp bare remotes;
# it never touches the real box, a real remote or the real home.
# Usage: bash test/git-sync.test.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$ROOT/box/fcode-git-sync.sh"
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME" "$T/bin"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi; }

# a host without flock (Git Bash) gets a no-op stand-in so the rest still runs; the overlap test is then skipped
REAL_FLOCK=1
command -v flock >/dev/null || { REAL_FLOCK=0; printf '#!/bin/sh\nexit 0\n' >"$T/bin/flock"; chmod +x "$T/bin/flock"; export PATH="$T/bin:$PATH"; echo "note: no flock here, using a no-op stand-in (overlap test skipped)"; }

STATEF="$HOME/.local/state/fcode/git-sync.json"
# q <path>: value at a dotted path of the state file (null / undefined printed as such); qj prints JSON
q() { node -e 'let v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); for (const k of process.argv[2].split(".")) v = v == null ? v : v[k]; console.log(v === null ? "null" : v)' "$STATEF" "$1"; }
qj() { node -e 'let v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); for (const k of process.argv[2].split(".")) v = v == null ? v : v[k]; console.log(JSON.stringify(v))' "$STATEF" "$1"; }
keys() { node -e 'console.log(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).projects).join())' "$STATEF"; }
run() { bash "$SYNC" >"$T/run.out" 2>&1; }
cfg() { # <name>...: config with those projects (dirs under ws/)
  { printf '{"projects":{'; local sep=; for n in "$@"; do printf '%s"%s":"%s"' "$sep" "$n" "$T/ws/$n"; sep=,; done; printf '}}\n'; } >"$HOME/.fcoding/config.json"
}

# ---- fixtures: a bare remote + a seed clone (to advance the remote) + a working clone per project ----
mkdir -p "$T/remotes" "$T/seed" "$T/ws" "$HOME/.fcoding"
mkproj() { # <name>
  git init -q --bare -b main "$T/remotes/$1.git"
  git clone -q "$T/remotes/$1.git" "$T/seed/$1" 2>/dev/null
  ( cd "$T/seed/$1" && git symbolic-ref HEAD refs/heads/main; echo one >a.txt; echo one >b.txt; git add .; git commit -qm one; git push -q origin main )
  git clone -q "$T/remotes/$1.git" "$T/ws/$1" 2>/dev/null
}
adv() { # <name> <file> <text>: a new commit on the remote main
  ( cd "$T/seed/$1" && echo "$3" >"$2" && git add "$2" && git commit -qm "$3" && git push -q origin main )
}
c() { git -C "$T/ws/$1" "${@:2}"; }
hd() { c "$1" rev-parse HEAD; }

for n in behind dirty branch diverged rebase lock same bad; do mkproj $n; done
adv behind a.txt r1; adv behind b.txt r2
for n in dirty branch diverged rebase lock bad; do adv $n a.txt "remote-$n"; done

echo local >"$T/ws/dirty/b.txt"; echo new >"$T/ws/dirty/new.txt"          # tracked change + untracked file
c branch switch -q -c box/topic                                          # not the default branch
( cd "$T/ws/diverged" && echo mine >b.txt && git commit -qam mine )      # local commit + remote commit
( cd "$T/ws/rebase" && git fetch -q && git switch -q -c topic && echo mine >a.txt && git commit -qam mine && ! git rebase origin/main >/dev/null 2>&1 )
touch "$T/ws/lock/.git/index.lock"                                       # stale lock
c bad remote set-url origin "$T/remotes/nope.git"                        # fetch fails for this one only
[ -d "$T/ws/rebase/.git/rebase-merge" ] || [ -d "$T/ws/rebase/.git/rebase-apply" ] && ok "fixture: rebase is stopped mid-way" || no "fixture: rebase is stopped mid-way"

# the failing project and a missing dir come FIRST: the others must still be reported
cfg bad gone behind dirty branch diverged rebase lock same
for n in behind dirty branch diverged rebase lock same; do eval "H_$n=$(hd $n)"; done
BEHIND_FILES=$(cat "$T/ws/behind/a.txt" "$T/ws/behind/b.txt")

run; eq "run exits 0" "$?" 0
[ -s "$T/run.out" ] && no "quiet run (printed: $(head -c 200 "$T/run.out"))" || ok "quiet run"
eq "nothing was pushed: every remote has only main" "$(for r in "$T"/remotes/*.git; do git -C "$r" for-each-ref --format='%(refname)' refs/heads; done | grep -vc '^refs/heads/main$')" 0

# 1. behind: reported, NOT updated
eq "behind: behindDefault 2, ahead 0, clean" "$(q projects.behind.behindDefault)/$(q projects.behind.aheadOfOrigin)/$(q projects.behind.dirty)" 2/0/false
eq "behind: HEAD and files unchanged (no fast-forward)" "$(hd behind)/$(cat "$T/ws/behind/a.txt" "$T/ws/behind/b.txt")" "$H_behind/$BEHIND_FILES"
eq "behind: origin/main did move (fetched)" "$(c behind rev-parse origin/main)" "$(git -C "$T/remotes/behind.git" rev-parse main)"
eq "behind: no .git/FETCH_HEAD written by the script" "$([ -e "$T/ws/behind/.git/FETCH_HEAD" ] && echo exists || echo none)" none
eq "behind: default and branch" "$(q projects.behind.default)/$(q projects.behind.branch)" main/main
# 2. dirty
eq "dirty: change and untracked file kept, HEAD unchanged" "$(cat "$T/ws/dirty/b.txt")/$([ -e "$T/ws/dirty/new.txt" ] && echo y)/$(hd dirty)" "local/y/$H_dirty"
eq "dirty: dirty true, behind 1" "$(q projects.dirty.dirty)/$(q projects.dirty.behindDefault)" true/1
# 3. other branch
eq "branch: still on box/topic, HEAD unchanged" "$(c branch symbolic-ref --short HEAD)/$(hd branch)" "box/topic/$H_branch"
eq "branch: name, behind 1, ahead 0 (nothing of its own)" "$(q projects.branch.branch)/$(q projects.branch.behindDefault)/$(q projects.branch.aheadOfOrigin)" box/topic/1/0
# 4. diverged
eq "diverged: HEAD unchanged, behind 1, ahead 1" "$(hd diverged)/$(q projects.diverged.behindDefault)/$(q projects.diverged.aheadOfOrigin)" "$H_diverged/1/1"
# 5. mid-rebase and lock: reported, untouched
eq "rebase: HEAD unchanged, branch (detached), dirty" "$(hd rebase)/$(q projects.rebase.branch)/$(q projects.rebase.dirty)" "$H_rebase/(detached)/true"
[ -d "$T/ws/rebase/.git/rebase-merge" ] || [ -d "$T/ws/rebase/.git/rebase-apply" ] && ok "rebase: still in progress" || no "rebase: still in progress"
eq "index.lock: still there, HEAD unchanged, behind reported" "$([ -e "$T/ws/lock/.git/index.lock" ] && echo y)/$(hd lock)/$(q projects.lock.behindDefault)" "y/$H_lock/1"
# 6. up to date
eq "same: behind 0, ahead 0, no error" "$(q projects.same.behindDefault)/$(q projects.same.aheadOfOrigin)/$(q projects.same.error)" 0/0/null
eq "same: lastFetchAt set" "$([ "$(q projects.same.lastFetchAt)" != null ] && echo set)" set
# 7. failures stay local to their project
eq "bad: error recorded" "$(q projects.bad.error | cut -c1-13)" "fetch failed:"
eq "bad: no lastFetchAt" "$(q projects.bad.lastFetchAt)" null
eq "gone: error recorded" "$(q projects.gone.error)" "not a git repository"
eq "behind still reported although bad+gone come first" "$(q projects.behind.behindDefault)" 2
# 8. state file
node -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); if (!/^\d{4}-\d\d-\d\dT[\d:]+Z$/.test(s.updatedAt) || Object.keys(s.projects).length !== 9) process.exit(1)' "$STATEF" && ok "state JSON valid: updatedAt + 9 projects" || no "state JSON valid"
node -e 'const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).projects.same; const k = Object.keys(p).sort().join(); if (k !== "aheadOfOrigin,behindDefault,branch,default,dirty,error,lastFetchAt") process.exit(1)' "$STATEF" && ok "state: per-project fields (no fastForwarded)" || no "state: per-project fields"
[ "$(uname)" = Linux ] && eq "state file mode 600" "$(stat -c %a "$STATEF")" 600
eq "no temp files left in the state dir" "$(ls -A "$HOME/.local/state/fcode" | grep -vcE '^(git-sync.json|git-sync.lock)$')" 0

# second run: a new remote commit shows up in behindDefault; a failing fetch keeps the old lastFetchAt
adv same a.txt r-new
sleep 1; run
eq "run 2: behindDefault after a new remote commit" "$(q projects.same.behindDefault)/$(hd same)" "1/$H_same"
LF1=$(q projects.same.lastFetchAt)
c same remote set-url origin "$T/remotes/nope.git"
sleep 1; run
eq "run 3: failed fetch keeps lastFetchAt, records the error" "$(q projects.same.lastFetchAt)/$(q projects.same.error | cut -c1-13)" "$LF1/fetch failed:"
c same remote set-url origin "$T/remotes/same.git"

# fetch timeout: an endless transport is cut at FCODE_GIT_FETCH_TIMEOUT and recorded
c same remote set-url origin 'ext::sleep 6'
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.ext.allow GIT_CONFIG_VALUE_0=always FCODE_GIT_FETCH_TIMEOUT=2 bash "$SYNC" >/dev/null 2>&1
eq "fetch timeout recorded" "$(q projects.same.error)" "fetch timed out after 2s"
c same remote set-url origin "$T/remotes/same.git"

# overlap: while another run holds the lock, a run exits 0 at once and writes nothing
if [ $REAL_FLOCK = 1 ]; then
  rm -f "$STATEF"
  ( exec 9>"$HOME/.local/state/fcode/git-sync.lock"; flock 9; sleep 3 ) &
  sleep 1
  run; RC=$?
  eq "overlap: exit 0 and nothing written" "$RC/$([ -e "$STATEF" ] && echo wrote)" "0/"
  wait
  run; [ -s "$STATEF" ] && ok "after the lock is released a run writes the state" || no "after the lock is released a run writes the state"
fi

# ---- read-only: working tree, index, local branches and tags stay byte-identical, even with an odd repo config ----
echo "# read-only"
mkproj ro; c ro fetch -q origin main                                                                      # leaves a FETCH_HEAD of the user's own
( cd "$T/ws/ro" && echo a2 >a.txt && git commit -qam a2 && git branch side HEAD~1 && git tag -a mytag -m x && git tag light \
  && echo staged >b.txt && git add b.txt && echo more >>a.txt && echo u >untracked.txt )                # local commit, branch, tags, staged + unstaged + untracked
git -C "$T/ws/ro" config --add remote.origin.fetch '+refs/heads/*:refs/heads/*'                          # configured refspec that would move local branches
git -C "$T/ws/ro" config remote.origin.prune true
git -C "$T/ws/ro" config remote.origin.tagopt --tags
( cd "$T/seed/ro" && git switch -q -c newb && echo nb >nb.txt && git add . && git commit -qm nb && git push -q origin newb && git tag rtag && git push -q origin rtag && git switch -q main \
  && echo rm >r.txt && git add . && git commit -qm rm && git push -q origin main )                       # remote: main moved, new branch, new tag
git -C "$T/ws/ro" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags >"$T/ro.refs.before"
git -C "$T/ws/ro" status --porcelain=v2 -uall >"$T/ro.status.before"                                      # (may refresh the index: take the index sum after it)
tree_sum() { ( cd "$T/ws/ro" && find . -path ./.git -prune -o -type f -print | sort | xargs cksum | cksum; cksum <.git/index; cksum <.git/FETCH_HEAD; git config --list | cksum ); }
RO_BEFORE=$(tree_sum); RO_HEAD=$(hd ro)
cfg ro; run
eq "read-only: files, index and repo config identical" "$(tree_sum)" "$RO_BEFORE"
git -C "$T/ws/ro" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags >"$T/ro.refs.after"
eq "read-only: local branches and tags unchanged (none moved, none deleted)" "$(cmp -s "$T/ro.refs.before" "$T/ro.refs.after" && echo same)" same
eq "read-only: tag 'mytag' and branch 'side' still there" "$(c ro tag -l mytag light | tr '\n' ' ')/$(c ro rev-parse --verify -q side >/dev/null && echo y)" "light mytag /y"
eq "read-only: status identical" "$(c ro status --porcelain=v2 -uall | cksum)" "$(cksum <"$T/ro.status.before")"
eq "read-only: HEAD unchanged" "$(hd ro)" "$RO_HEAD"
eq "read-only: remote tag not fetched (--no-tags)" "$(c ro tag -l rtag | wc -l | tr -d ' ')" 0
eq "read-only: remote-tracking refs did move" "$(c ro rev-parse origin/main)/$(c ro rev-parse origin/newb)" "$(git -C "$T/remotes/ro.git" rev-parse main)/$(git -C "$T/remotes/ro.git" rev-parse newb)"
eq "read-only: behind 1, ahead 1, dirty" "$(q projects.ro.behindDefault)/$(q projects.ro.aheadOfOrigin)/$(q projects.ro.dirty)/$(q projects.ro.error)" "1/1/true/null"
eq "read-only: nothing pushed (main and newb only)" "$(git -C "$T/remotes/ro.git" for-each-ref --format='%(refname)' refs/heads | tr '\n' ' ')" "refs/heads/main refs/heads/newb "

# ---- aheadOfOrigin: commits on no origin/* branch, whatever the upstream ----
echo "# ahead"
for n in up nu; do mkproj $n; done
( cd "$T/ws/up" && echo l1 >l1.txt && git add . && git commit -qm l1 )                                    # upstream origin/main, 1 ahead
( cd "$T/ws/nu" && git switch -q -c feat && echo a >f1 && git add . && git commit -qm f1 && echo b >f2 && git add . && git commit -qm f2 ) # no upstream, 2 commits
rm -rf "$T/ws/un" && git init -q -b main "$T/ws/un" && git -C "$T/ws/un" remote add origin "$T/remotes/up.git"  # unborn HEAD: cannot be computed
cfg up nu un; run
eq "ahead: upstream origin/main, one local commit -> 1" "$(q projects.up.aheadOfOrigin)" 1
eq "ahead: no upstream -> commits on no origin/* ref" "$(q projects.nu.aheadOfOrigin)/$(q projects.nu.branch)" 2/feat
eq "ahead: unborn HEAD -> null, behind null" "$(q projects.un.aheadOfOrigin)/$(q projects.un.behindDefault)" null/null
c up push -q origin main 2>/dev/null                                                                       # (the test pushes, the script never does)
git -C "$T/ws/nu" push -q origin feat 2>/dev/null
run
eq "ahead: upstream origin/main after a push -> 0" "$(q projects.up.aheadOfOrigin)" 0
eq "ahead: no upstream but commits on origin/feat -> 0" "$(q projects.nu.aheadOfOrigin)" 0
( cd "$T/ws/up" && echo l2 >l2.txt && git add . && git commit -qm l2 ); run
eq "ahead: upstream origin/main, one new local commit -> 1" "$(q projects.up.aheadOfOrigin)" 1

# ---- several remote.origin.url values: the FIRST one is used, like `git fetch origin` ----
echo "# two urls"
mkproj mu; adv mu a.txt r-mu; mkproj mv; adv mv a.txt r-mv1; adv mv b.txt r-mv2
c mu config --add remote.origin.url "$T/remotes/nope.git"               # second url does not exist
c mv config --add remote.origin.url "$T/remotes/behind.git"             # second url is another, reachable repository
cfg mu mv; run
eq "two urls (second broken): fetched from the first, no error" "$(q projects.mu.error)/$(q projects.mu.behindDefault)" null/1
eq "two urls (second reachable): origin/main comes from the first url" "$(c mv rev-parse origin/main)/$(q projects.mv.behindDefault)/$(q projects.mv.error)" "$(git -C "$T/remotes/mv.git" rev-parse main)/2/null"

# ---- a project called __proto__ is an ordinary entry ----
echo "# __proto__"
mkproj proto; adv proto a.txt rp; mv "$T/ws/proto" "$T/ws/__proto__"
cfg __proto__ same; run
eq "__proto__: its own entry, next to the other" "$(keys)" "__proto__,same"
eq "__proto__: values" "$(q projects.__proto__.branch)/$(q projects.__proto__.behindDefault)/$(q projects.__proto__.error)" main/1/null
adv same a.txt r-new2
bash "$SYNC" same >/dev/null 2>&1
eq "__proto__: kept by a single-project run" "$(keys)/$(q projects.__proto__.behindDefault)" "__proto__,same/1"

# ---- state errors carry no raw git output or credentials ----
echo "# redaction"
REAL_GIT=$(command -v git); mkdir -p "$T/racebin"
{ printf '#!/bin/sh\nREAL="%s"\n' "$REAL_GIT"; cat <<'EOF'; } >"$T/racebin/git"
case " $* " in
  *" fetch "*)
    if [ -n "${FAKE_FETCH_ERR:-}" ]; then printf '%s\nsecond line pw999\n' "$FAKE_FETCH_ERR" >&2; exit 128; fi ;;
esac
exec "$REAL" "$@"
EOF
chmod +x "$T/racebin/git"
cfg same
FAKE_FETCH_ERR='fatal: unable to access https://user:pw123@github.com/x/y.git with ghp_ABCDEF123 and github_pat_11XYZ_abc and x-access-token:zzz9' PATH="$T/racebin:$PATH" bash "$SYNC" >/dev/null 2>&1
ERR=$(q projects.same.error)
eq "redaction: reason prefix and masks" "$(printf %s "$ERR" | cut -c1-13)/$(printf %s "$ERR" | grep -o '\[redacted\]' | wc -l | tr -d ' ')" "fetch failed:/4"
eq "redaction: no secret, no second line" "$(printf %s "$ERR" | grep -cE 'pw123|ABCDEF123|11XYZ|zzz9|pw999|second line')" 0

# ---- config records: a name or path with a control character is skipped, not split ----
echo "# config records"
printf '{"projects":{"ok":"%s","bad\\nname":"%s","tab":"%s\\tx","nl":"%s\\nfoo"}}\n' "$T/ws/same" "$T/ws/same" "$T/ws/same" "$T/ws/same" >"$HOME/.fcoding/config.json"
bash "$SYNC" >/dev/null 2>&1
eq "config: only the clean record is in the state" "$(keys)" ok

# ---- single-project mode: fcode-git-sync.sh <project> touches only that project and its state entry ----
echo "# single project"
for n in sa sb; do mkproj $n; adv $n a.txt "remote-$n"; done
cfg sa sb; bash "$SYNC" >/dev/null 2>&1
adv sa a.txt remote-sa2; adv sb a.txt remote-sb2
SB_BEFORE=$(qj projects.sb); SA_HEAD=$(hd sa); SB_ORIGIN=$(c sb rev-parse origin/main)
bash "$SYNC" sa >"$T/one.out" 2>&1; eq "single: exit 0, quiet" "$?/$(wc -c <"$T/one.out" | tr -d ' ')" "0/0"
eq "single: sa reports the new commit, HEAD untouched" "$(q projects.sa.behindDefault)/$(hd sa)" "2/$SA_HEAD"
eq "single: sb untouched (entry kept, not fetched)" "$(qj projects.sb)/$(c sb rev-parse origin/main)" "$SB_BEFORE/$SB_ORIGIN"
eq "single: both entries still in the state" "$(keys)" "sa,sb"
SUM=$(cksum <"$STATEF")
bash "$SYNC" nope >"$T/one.out" 2>&1; eq "single: unknown project, exit 0" "$?" 0
eq "single: unknown project, message on stderr, state unchanged" "$(grep -c "no project 'nope'" "$T/one.out")/$(cksum <"$STATEF")" "1/$SUM"

# no config: exit 0, a message on stderr, no state change
rm -f "$HOME/.fcoding/config.json"; rm -f "$STATEF"
run; eq "no config: exit 0" "$?" 0
[ -e "$STATEF" ] && no "no config: state not written" || ok "no config: state not written"

# ---- the script has no git command that writes to a repository's work tree, index or branches ----
eq "no merge/checkout/reset/push/switch/rebase/update-ref/stash/pull/clean in the code (comments aside)" "$(sed 's/[[:space:]]#[[:space:]].*//; /^[[:space:]]*#/d' "$SYNC" | grep -cE '\b(merge|checkout|reset|push|switch|rebase|update-ref|stash|pull|clean)\b')" 0
eq "the one fetch names the url and the explicit refspec, no prune, no tags, no FETCH_HEAD" "$(grep -c "fetch --no-write-fetch-head --no-tags --no-prune --no-recurse-submodules" "$SYNC")/$(grep -c "'+refs/heads/\*:refs/remotes/origin/\*'" "$SYNC")" 1/1

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
