#!/usr/bin/env bash
# Tests for box/fcode-git-sync.sh: it fetches and reports, and fast-forwards the default branch of a project that is idle and
# clean (and nothing else: it never pushes, stashes, resets or touches another branch).
# Needs: bash, git, node (flock only for the overlap test; Linux /proc for the fast-forward and busy tests). Everything runs in a temp HOME with temp bare remotes;
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

# LINUX=1: /proc/<pid>/cwd can be read here, so the script can tell busy projects (its fast-forward then runs); else every project counts as busy
LINUX=0; [ -n "$(readlink /proc/self/cwd 2>/dev/null)" ] && LINUX=1
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

# 1. behind, idle, clean, on main: fast-forwarded (on a host without /proc the project counts as busy and stays put)
if [ $LINUX = 1 ]; then
  eq "behind: fast-forwarded to origin/main, behind 0, ahead 0, clean" "$(hd behind)/$(q projects.behind.behindDefault)/$(q projects.behind.aheadOfOrigin)/$(q projects.behind.dirty)" "$(git -C "$T/remotes/behind.git" rev-parse main)/0/0/false"
  eq "behind: files updated, autoUpdated true, autoSkip null" "$(cat "$T/ws/behind/a.txt" "$T/ws/behind/b.txt" | tr '\n' ' ')/$(q projects.behind.autoUpdated)/$(q projects.behind.autoSkip)" "r1 r2 /true/null"
else
  eq "behind (no /proc): untouched, autoSkip busy" "$(hd behind)/$BEHIND_FILES/$(q projects.behind.behindDefault)/$(q projects.behind.autoSkip)" "$H_behind/$BEHIND_FILES/2/busy"
fi
eq "behind: origin/main did move (fetched)" "$(c behind rev-parse origin/main)" "$(git -C "$T/remotes/behind.git" rev-parse main)"
eq "behind: no .git/FETCH_HEAD written by the script" "$([ -e "$T/ws/behind/.git/FETCH_HEAD" ] && echo exists || echo none)" none
eq "behind: default and branch" "$(q projects.behind.default)/$(q projects.behind.branch)" main/main
# 2. dirty
eq "dirty: change and untracked file kept, HEAD unchanged" "$(cat "$T/ws/dirty/b.txt")/$([ -e "$T/ws/dirty/new.txt" ] && echo y)/$(hd dirty)" "local/y/$H_dirty"
eq "dirty: dirty true, behind 1, autoSkip dirty, not updated" "$(q projects.dirty.dirty)/$(q projects.dirty.behindDefault)/$(q projects.dirty.autoSkip)/$(q projects.dirty.autoUpdated)" true/1/dirty/false
# 3. other branch
eq "branch: still on box/topic, HEAD unchanged" "$(c branch symbolic-ref --short HEAD)/$(hd branch)" "box/topic/$H_branch"
eq "branch: name, behind 1, ahead 0 (nothing of its own), autoSkip on_branch" "$(q projects.branch.branch)/$(q projects.branch.behindDefault)/$(q projects.branch.aheadOfOrigin)/$(q projects.branch.autoSkip)" box/topic/1/0/on_branch
# 4. diverged
eq "diverged: HEAD unchanged, behind 1, ahead 1, autoSkip ahead" "$(hd diverged)/$(q projects.diverged.behindDefault)/$(q projects.diverged.aheadOfOrigin)/$(q projects.diverged.autoSkip)" "$H_diverged/1/1/ahead"
# 5. mid-rebase and lock: reported, untouched
eq "rebase: HEAD unchanged, branch (detached), dirty, behind 0 (stopped on origin/main): nothing to update" "$(hd rebase)/$(q projects.rebase.branch)/$(q projects.rebase.dirty)/$(q projects.rebase.behindDefault)/$(q projects.rebase.autoSkip)" "$H_rebase/(detached)/true/0/null"
[ -d "$T/ws/rebase/.git/rebase-merge" ] || [ -d "$T/ws/rebase/.git/rebase-apply" ] && ok "rebase: still in progress" || no "rebase: still in progress"
eq "index.lock: still there, HEAD unchanged, behind reported, autoSkip in_progress" "$([ -e "$T/ws/lock/.git/index.lock" ] && echo y)/$(hd lock)/$(q projects.lock.behindDefault)/$(q projects.lock.autoSkip)" "y/$H_lock/1/in_progress"
# 6. up to date
eq "same: behind 0, ahead 0, no error, nothing to update" "$(q projects.same.behindDefault)/$(q projects.same.aheadOfOrigin)/$(q projects.same.error)/$(q projects.same.autoUpdated)/$(q projects.same.autoSkip)" 0/0/null/false/null
eq "same: lastFetchAt set" "$([ "$(q projects.same.lastFetchAt)" != null ] && echo set)" set
# 7. failures stay local to their project
eq "bad: error recorded" "$(q projects.bad.error | cut -c1-13)" "fetch failed:"
eq "bad: no lastFetchAt" "$(q projects.bad.lastFetchAt)" null
eq "gone: error recorded" "$(q projects.gone.error)" "not a git repository"
if [ $LINUX = 1 ]; then eq "behind still handled although bad+gone come first" "$(q projects.behind.behindDefault)/$(q projects.behind.autoUpdated)" 0/true
else eq "behind still reported although bad+gone come first" "$(q projects.behind.behindDefault)" 2; fi
# 8. state file
node -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); if (!/^\d{4}-\d\d-\d\dT[\d:]+Z$/.test(s.updatedAt) || Object.keys(s.projects).length !== 9) process.exit(1)' "$STATEF" && ok "state JSON valid: updatedAt + 9 projects" || no "state JSON valid"
node -e 'const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).projects.same; const k = Object.keys(p).sort().join(); if (k !== "aheadOfOrigin,autoSkip,autoUpdated,behindDefault,branch,default,dirty,error,lastFetchAt") process.exit(1)' "$STATEF" && ok "state: per-project fields (old ones kept, autoUpdated + autoSkip added)" || no "state: per-project fields"
[ "$(uname)" = Linux ] && eq "state file mode 600" "$(stat -c %a "$STATEF")" 600
eq "no temp files left in the state dir" "$(ls -A "$HOME/.local/state/fcode" | grep -vcE '^(git-sync.json|git-sync.lock)$')" 0

# second run: a new remote commit shows up in behindDefault; a failing fetch keeps the old lastFetchAt
# ('same' gets a tracked change first, so these fetch-only checks are not about the fast-forward, which has its own section)
echo wip >"$T/ws/same/b.txt"
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
echo wip >"$T/ws/mu/b.txt"; echo wip >"$T/ws/mv/a.txt"                  # tracked changes: these are fetch checks, not fast-forward ones
c mu config --add remote.origin.url "$T/remotes/nope.git"               # second url does not exist
c mv config --add remote.origin.url "$T/remotes/behind.git"             # second url is another, reachable repository
cfg mu mv; run
eq "two urls (second broken): fetched from the first, no error" "$(q projects.mu.error)/$(q projects.mu.behindDefault)" null/1
eq "two urls (second reachable): origin/main comes from the first url" "$(c mv rev-parse origin/main)/$(q projects.mv.behindDefault)/$(q projects.mv.error)" "$(git -C "$T/remotes/mv.git" rev-parse main)/2/null"

# ---- a project called __proto__ is an ordinary entry ----
echo "# __proto__"
mkproj proto; adv proto a.txt rp; echo wip >"$T/ws/proto/b.txt"; mv "$T/ws/proto" "$T/ws/__proto__"
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
SB_BEFORE=$(qj projects.sb); SB_HEAD=$(hd sb); SB_ORIGIN=$(c sb rev-parse origin/main); SA_HEAD=$(hd sa)
bash "$SYNC" sa >"$T/one.out" 2>&1; eq "single: exit 0, quiet" "$?/$(wc -c <"$T/one.out" | tr -d ' ')" "0/0"
# the single-project run is look-only: sa is fetched (origin/main moved) and counted, but never fast-forwarded
eq "single: sa fetched, never fast-forwarded (HEAD unchanged, autoUpdated false, autoSkip null)" "$(q projects.sa.behindDefault)/$(q projects.sa.autoUpdated)/$(q projects.sa.autoSkip)/$(hd sa)/$(c sa rev-parse origin/main)" "$([ $LINUX = 1 ] && echo 1 || echo 2)/false/null/$SA_HEAD/$(git -C "$T/remotes/sa.git" rev-parse main)"
eq "single: sb untouched (entry kept, not fetched, not fast-forwarded)" "$(qj projects.sb)/$(c sb rev-parse origin/main)/$(hd sb)" "$SB_BEFORE/$SB_ORIGIN/$SB_HEAD"
eq "single: both entries still in the state" "$(keys)" "sa,sb"
SUM=$(cksum <"$STATEF")
bash "$SYNC" nope >"$T/one.out" 2>&1; eq "single: unknown project, exit 0" "$?" 0
eq "single: unknown project, message on stderr, state unchanged" "$(grep -c "no project 'nope'" "$T/one.out")/$(cksum <"$STATEF")" "1/$SUM"

# no config: exit 0, a message on stderr, no state change
rm -f "$HOME/.fcoding/config.json"; rm -f "$STATEF"
run; eq "no config: exit 0" "$?" 0
[ -e "$STATEF" ] && no "no config: state not written" || ok "no config: state not written"

# ---- automatic fast-forward: when it happens, when it is skipped, and what it never touches ----
echo "# auto fast-forward"
if [ $LINUX = 1 ]; then
  # fixtures: every project is on main with a clean tree and the remote is 2 commits ahead, then each case spoils one thing
  for n in ff skipb skipd skipa skipp ffu ffx busy pre; do mkproj $n; adv $n a.txt "r-$n-1"; adv $n b.txt "r-$n-2"; done
  # ff: other branch + annotated tag + a hook + an untracked file that does not clash
  ( cd "$T/ws/ff" && git branch keep && git tag -a keeptag -m k && echo scratch >scratch.txt \
    && printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$T" >.git/hooks/post-merge && chmod +x .git/hooks/post-merge )
  # skip reasons
  c skipb switch -q -c box/topic
  echo wip >"$T/ws/skipd/b.txt"                                                  # unstaged tracked change
  ( cd "$T/ws/skipa" && echo mine >mine.txt && git add . && git commit -qm mine ) # a local commit on main, remote also moved
  ( cd "$T/ws/skipp" && git rev-parse HEAD >.git/MERGE_HEAD )                    # a merge under way (clean tree, on main)
  # ff_failed 1: the remote adds new.txt, and an untracked new.txt is in the way
  ( cd "$T/seed/ffu" && echo remote >new.txt && git add . && git commit -qm newfile && git push -q origin main ); echo mine >"$T/ws/ffu/new.txt"
  # ff_failed 2: HEAD's commit is on origin/side only, so ahead is 0 but main cannot fast-forward
  ( cd "$T/ws/ffx" && echo x >x.txt && git add . && git commit -qm x && git push -q origin HEAD:refs/heads/side )
  # busy: a process with its cwd inside the project (a subdirectory), and a sibling dir whose name only starts the same
  mkdir -p "$T/ws/busy/sub" "$T/ws/pre-other"; : >"$T/ws/busy/sub/.keep"
  cfg ff skipb skipd skipa skipp ffu ffx busy pre
  for n in ff skipb skipd skipa skipp ffu ffx busy pre; do eval "A_$n=$(hd $n)"; done
  FF_FILES=$(cd "$T/ws/ffu" && git status --porcelain --untracked-files=all | tr '\n' ' ')
  REMOTES_BEFORE=$(for r in "$T"/remotes/{ff,skipb,skipd,skipa,skipp,ffu,ffx,busy,pre}.git; do git -C "$r" for-each-ref --format='%(refname) %(objectname)'; done | cksum)
  ( cd "$T/ws/busy/sub" && exec sleep 60 ) & BUSY1=$!
  ( cd "$T/ws/pre-other" && exec sleep 60 ) & BUSY2=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(readlink /proc/$BUSY1/cwd 2>/dev/null)" = "$T/ws/busy/sub" ] && [ "$(readlink /proc/$BUSY2/cwd 2>/dev/null)" = "$T/ws/pre-other" ] && break; sleep 0.3; done
  run; eq "autoff: run exits 0, quiet" "$?/$(wc -c <"$T/run.out" | tr -d ' ')" "0/0"
  REMOTE_MAIN=$(git -C "$T/remotes/ff.git" rev-parse main)
  # the one that happens
  eq "ff: HEAD is origin/main, files updated, on main" "$(hd ff)/$(c ff symbolic-ref --short HEAD)/$(cat "$T/ws/ff/a.txt" "$T/ws/ff/b.txt" | tr '\n' ' ')" "$REMOTE_MAIN/main/r-ff-1 r-ff-2 "
  eq "ff: state autoUpdated true, autoSkip null, behind 0, ahead 0" "$(q projects.ff.autoUpdated)/$(q projects.ff.autoSkip)/$(q projects.ff.behindDefault)/$(q projects.ff.aheadOfOrigin)" true/null/0/0
  eq "ff: untracked file kept (and reported as dirty), tree otherwise clean" "$(cat "$T/ws/ff/scratch.txt")/$(q projects.ff.dirty)/$(c ff status --porcelain)" "scratch/true/?? scratch.txt"
  eq "ff: no merge commit (history is the remote's, linear)" "$(c ff rev-list --count --merges HEAD)/$(c ff rev-list --count HEAD)" "0/3"
  eq "ff: other branch and tag untouched, no stash" "$(c ff rev-parse keep)/$(c ff rev-parse keeptag^{commit})/$(c ff stash list | wc -l | tr -d ' ')" "$(c ff rev-parse HEAD~2)/$(c ff rev-parse HEAD~2)/0"
  eq "ff: repo hooks do not run for the automatic merge" "$([ -e "$T/hook-ran" ] && echo ran || echo none)" none
  # the skips: each one leaves HEAD (and what is there) as it was and says why
  eq "skip on_branch: still on box/topic, HEAD unchanged" "$(q projects.skipb.autoSkip)/$(q projects.skipb.autoUpdated)/$(hd skipb)/$(c skipb symbolic-ref --short HEAD)/$(q projects.skipb.behindDefault)" "on_branch/false/$A_skipb/box/topic/2"
  eq "skip dirty: tracked change kept, HEAD unchanged" "$(q projects.skipd.autoSkip)/$(hd skipd)/$(cat "$T/ws/skipd/b.txt")" "dirty/$A_skipd/wip"
  eq "skip ahead: autoSkip ahead, HEAD unchanged, ahead 1 behind 2" "$(q projects.skipa.autoSkip)/$(hd skipa)/$(q projects.skipa.aheadOfOrigin)/$(q projects.skipa.behindDefault)" "ahead/$A_skipa/1/2"
  eq "skip in_progress (MERGE_HEAD): HEAD unchanged, marker kept" "$(q projects.skipp.autoSkip)/$(hd skipp)/$([ -e "$T/ws/skipp/.git/MERGE_HEAD" ] && echo y)" "in_progress/$A_skipp/y"
  eq "skip busy: HEAD unchanged, behind 2" "$(q projects.busy.autoSkip)/$(q projects.busy.autoUpdated)/$(hd busy)/$(q projects.busy.behindDefault)" "busy/false/$A_busy/2"
  eq "busy: a sibling dir with the same name prefix does not block" "$(q projects.pre.autoUpdated)/$(q projects.pre.autoSkip)/$(hd pre)" "true/null/$(git -C "$T/remotes/pre.git" rev-parse main)"
  # ff_failed: checkout as it was
  eq "ff_failed (untracked file in the way): reason, HEAD and file unchanged" "$(q projects.ffu.autoSkip)/$(q projects.ffu.autoUpdated)/$(hd ffu)/$(cat "$T/ws/ffu/new.txt")/$(cd "$T/ws/ffu" && git status --porcelain --untracked-files=all | tr '\n' ' ')" "ff_failed/false/$A_ffu/mine/$FF_FILES"
  eq "ff_failed (main diverged from origin/main, ahead 0): reason, HEAD unchanged" "$(q projects.ffx.autoSkip)/$(q projects.ffx.aheadOfOrigin)/$(q projects.ffx.behindDefault)/$(hd ffx)" "ff_failed/0/2/$A_ffx"
  # while the sleeper runs: not busy once it is gone -> the next run fast-forwards (and in_progress/dirty/branch stay skipped)
  kill $BUSY1 $BUSY2 2>/dev/null; wait $BUSY1 $BUSY2 2>/dev/null
  run
  eq "busy gone: next run fast-forwards busy" "$(q projects.busy.autoUpdated)/$(q projects.busy.autoSkip)/$(hd busy)/$(q projects.busy.behindDefault)" "true/null/$(git -C "$T/remotes/busy.git" rev-parse main)/0"
  eq "ff again: nothing to do, autoUpdated back to false" "$(q projects.ff.autoUpdated)/$(q projects.ff.autoSkip)/$(hd ff)" "false/null/$REMOTE_MAIN"
  eq "still skipped: on_branch, dirty, ahead, in_progress" "$(q projects.skipb.autoSkip)/$(q projects.skipd.autoSkip)/$(q projects.skipa.autoSkip)/$(q projects.skipp.autoSkip)" "on_branch/dirty/ahead/in_progress"
  eq "skipped projects: HEADs still unchanged" "$(hd skipb)/$(hd skipd)/$(hd skipa)/$(hd skipp)/$(hd ffu)" "$A_skipb/$A_skipd/$A_skipa/$A_skipp/$A_ffu"
  # nothing was pushed by the script: every remote ref is as the test left it (ffx's side branch is the test's own push)
  eq "nothing pushed: every remote ref unchanged" "$(for r in "$T"/remotes/{ff,skipb,skipd,skipa,skipp,ffu,ffx,busy,pre}.git; do git -C "$r" for-each-ref --format='%(refname) %(objectname)'; done | cksum)" "$REMOTES_BEFORE"
  # every other in-progress marker is a skip too (clean tree, on main, behind)
  for m in CHERRY_PICK_HEAD REVERT_HEAD REBASE_HEAD BISECT_LOG index.lock rebase-merge rebase-apply sequencer; do
    n="m_${m//[.-]/_}"; mkproj "$n"; adv "$n" a.txt rm; cfg "$n"
    case $m in
      rebase-merge|rebase-apply|sequencer) mkdir "$T/ws/$n/.git/$m" ;;
      index.lock|BISECT_LOG) : >"$T/ws/$n/.git/$m" ;;
      *) c "$n" rev-parse HEAD >"$T/ws/$n/.git/$m" ;;
    esac
    H=$(hd "$n"); run
    eq "skip in_progress ($m): reason, HEAD unchanged" "$(q projects.$n.autoSkip)/$(hd "$n")" "in_progress/$H"
  done
  # control for the hook test: the same hook does run when git merges with hooks on
  mkproj hk; adv hk a.txt hk1; printf '#!/bin/sh\ntouch "%s/hook-control"\n' "$T" >"$T/ws/hk/.git/hooks/post-merge"; chmod +x "$T/ws/hk/.git/hooks/post-merge"
  c hk fetch -q origin; c hk merge -q --ff-only origin/main
  eq "control: the post-merge hook runs under a plain git merge" "$([ -e "$T/hook-control" ] && echo ran || echo none)" ran

  # ignored file in the way (the laptop handoff puts TASK.md & co. in .git/info/exclude): the merge must not replace it
  mkproj ign; echo TASK.md >>"$T/ws/ign/.git/info/exclude"; echo "box-only notes" >"$T/ws/ign/TASK.md"
  ( cd "$T/seed/ign" && echo "remote task" >TASK.md && git add . && git commit -qm task && git push -q origin main )
  H=$(hd ign); cfg ign; run
  eq "ignored file in the way: ff_failed, file and HEAD unchanged" "$(q projects.ign.autoSkip)/$(q projects.ign.autoUpdated)/$(cat "$T/ws/ign/TASK.md")/$(hd ign)/$(q projects.ign.behindDefault)" "ff_failed/false/box-only notes/$H/1"

  # filters: any filter.* key configured in any scope (repo or global) turns the ff off; attributes are not read
  for n in fsm fpr fnone gplain; do mkproj $n; done
  ( cd "$T/ws/fnone" && echo '*.bin filter=lfs -text' >.gitattributes && git add . && git commit -qm attrs && git push -q origin main )  # attributes without any driver
  ( cd "$T/seed/fnone" && git pull -q origin main )
  for n in fsm fpr fnone gplain; do adv $n a.txt "r-$n"; done
  echo '*.bin filter=lfs' >"$T/ws/fnone/.git/info/attributes"
  c fsm config filter.lfs.smudge 'git-lfs smudge -- %f'
  c fpr config filter.lfs.process 'git-lfs filter-process'
  mkproj freq; adv freq a.txt r-freq
  c freq config filter.x.clean cat; c freq config filter.x.required true       # required + clean only: git would die mid-checkout
  for n in fsm fpr fnone gplain freq; do eval "H_$n=$(hd $n)"; done
  printf '[filter "lfs"]\n\tprocess = git-lfs filter-process\n\tsmudge = git-lfs smudge -- %%f\n\trequired = true\n' >"$HOME/.gitconfig"
  cfg gplain; run; rm -f "$HOME/.gitconfig"
  eq "global lfs config (git lfs install): even a plain repo is skipped (accepted, safe)" "$(q projects.gplain.autoSkip)/$(q projects.gplain.autoUpdated)/$(hd gplain)" "filters/false/$H_gplain"
  cfg fsm fpr fnone gplain freq; run
  eq "repo config filter.x.required=true + clean only: autoSkip filters, HEAD unchanged" "$(q projects.freq.autoSkip)/$(q projects.freq.autoUpdated)/$(hd freq)" "filters/false/$H_freq"
  eq "repo config filter.*.smudge: autoSkip filters, HEAD unchanged" "$(q projects.fsm.autoSkip)/$(q projects.fsm.autoUpdated)/$(hd fsm)/$(q projects.fsm.behindDefault)" "filters/false/$H_fsm/1"
  eq "repo config filter.*.process: autoSkip filters, HEAD unchanged" "$(q projects.fpr.autoSkip)/$(q projects.fpr.autoUpdated)/$(hd fpr)/$(q projects.fpr.behindDefault)" "filters/false/$H_fpr/1"
  eq "filter= attributes (HEAD, info) but no filter.* config: fast-forwarded" "$(q projects.fnone.autoSkip)/$(q projects.fnone.autoUpdated)/$(hd fnone)" "null/true/$(git -C "$T/remotes/fnone.git" rev-parse main)"
  eq "no driver left (global config removed): the plain repo fast-forwards" "$(q projects.gplain.autoSkip)/$(q projects.gplain.autoUpdated)" "null/true"

  # late: a run older than FCODE_GIT_LATE_AFTER seconds (600 by default) starts no merge; a bad value means 600
  mkproj lat; adv lat a.txt r-lat; H=$(hd lat); cfg lat
  FCODE_GIT_LATE_AFTER=0 bash "$SYNC" >/dev/null 2>&1
  eq "late: no merge, autoSkip late, HEAD unchanged, behind 1" "$(q projects.lat.autoSkip)/$(q projects.lat.autoUpdated)/$(hd lat)/$(q projects.lat.behindDefault)" "late/false/$H/1"
  FCODE_GIT_LATE_AFTER=abc bash "$SYNC" >/dev/null 2>&1
  eq "late: a non-numeric FCODE_GIT_LATE_AFTER falls back to 600 (not late, fast-forwards, no shell error)" "$(q projects.lat.autoUpdated)/$(q projects.lat.autoSkip)" "true/null"
  mkproj lat2; adv lat2 a.txt r-lat2; cfg lat2
  FCODE_GIT_LATE_AFTER= bash "$SYNC" >"$T/late.out" 2>&1
  eq "late: an empty FCODE_GIT_LATE_AFTER falls back to 600, quiet" "$(q projects.lat2.autoUpdated)/$(wc -c <"$T/late.out" | tr -d ' ')" "true/0"

  # busy root is the work tree: a project configured as a subdirectory of a checkout is busy while a process sits in a sibling dir
  mkproj mono; ( cd "$T/ws/mono" && mkdir web api && echo w >web/w.txt && echo a >api/a.txt && git add . && git commit -qm dirs && git push -q origin main )
  ( cd "$T/seed/mono" && git pull -q origin main && echo m >b.txt && git add . && git commit -qm m && git push -q origin main )
  printf '{"projects":{"monoweb":"%s"}}\n' "$T/ws/mono/web" >"$HOME/.fcoding/config.json"
  H=$(hd mono); ( cd "$T/ws/mono/api" && exec sleep 60 ) & BUSY3=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(readlink /proc/$BUSY3/cwd 2>/dev/null)" = "$T/ws/mono/api" ] && break; sleep 0.3; done
  run; eq "busy root: a process in a sibling dir of the configured subdir blocks the ff" "$(q projects.monoweb.autoSkip)/$(hd mono)/$(cat "$T/ws/mono/b.txt")" "busy/$H/one"
  kill $BUSY3 2>/dev/null; wait $BUSY3 2>/dev/null
  run; eq "busy root: once it is gone the ff happens" "$(q projects.monoweb.autoUpdated)/$(cat "$T/ws/mono/b.txt")" "true/m"

  # a single-project run (the server runs it right before opening a session) never fast-forwards
  mkproj sing; adv sing a.txt r-sing; cfg sing; H=$(hd sing)
  bash "$SYNC" sing >"$T/one.out" 2>&1
  eq "single-project run: fetched, behind 1, but no ff (autoUpdated false, autoSkip null, HEAD unchanged)" "$(q projects.sing.behindDefault)/$(q projects.sing.autoUpdated)/$(q projects.sing.autoSkip)/$(hd sing)/$(c sing rev-parse origin/main)" "1/false/null/$H/$(git -C "$T/remotes/sing.git" rev-parse main)"
  run; eq "the timer run then fast-forwards it" "$(q projects.sing.autoUpdated)/$(hd sing)" "true/$(git -C "$T/remotes/sing.git" rev-parse main)"
else
  echo "note: no Linux /proc here, the auto fast-forward and busy tests are skipped"
fi

# ---- GH_TOKEN for the timer (it has none of its own): GH_TOKEN alone is taken from the vault file, as text, when the environment has none ----
# A `timeout` shim (first on the script's PATH) records the GH_TOKEN | INSTABOX_API_KEY the fetch would see; it then runs the real one.
REALTO=$(command -v timeout) && {
  mkdir -p "$HOME/.local/bin"
  cat >"$HOME/.local/bin/timeout" <<SHIM
#!/bin/sh
printf '%s|%s\n' "\${GH_TOKEN-unset}" "\${INSTABOX_API_KEY-unset}" >>"$T/envseen"
exec "$REALTO" "\$@"
SHIM
  chmod +x "$HOME/.local/bin/timeout"
  mkproj tk; adv tk a.txt r-tk; cfg tk
  # tokrun [VAR=value ...]: one timer run with no GH_TOKEN / INSTABOX_API_KEY in the environment (unless given); prints what the fetch saw
  tokrun() { : >"$T/envseen"; env -u GH_TOKEN -u INSTABOX_API_KEY "$@" bash "$SYNC" >"$T/run.out" 2>&1; tr '\n' ' ' <"$T/envseen" | sed 's/ $//'; }
  V="$T/vault-env"
  printf 'echo noise\nexport INSTABOX_API_KEY=ikey-secret-9\nexport GH_TOKEN_X=nope\nexport GH_TOKEN="tok-vault-1"\nexport OTHER=zz\n' >"$V"
  eq "vault: GH_TOKEN reaches the fetch, INSTABOX_API_KEY does not" "$(tokrun FCODE_SECRETS_ENV="$V")" "tok-vault-1|unset"
  eq "vault: fetched fine, quiet, token in neither git-sync.json nor stderr, key not either" "$(q projects.tk.error)/$(wc -c <"$T/run.out" | tr -d ' ')/$(grep -rlE 'tok-vault-1|ikey-secret-9' "$HOME/.local/state" "$T/run.out" | wc -l | tr -d ' ')" "null/0/0"
  printf 'GH_TOKEN=tok_bare.2\r\nINSTABOX_API_KEY=ikey-2\r\n' >"$V"
  eq "vault: bare line with CRLF" "$(tokrun FCODE_SECRETS_ENV="$V")" "tok_bare.2|unset"
  printf "export GH_TOKEN='tok-single'\n" >"$V"
  eq "vault: single quotes" "$(tokrun FCODE_SECRETS_ENV="$V")" "tok-single|unset"
  printf 'export GH_TOKEN=$(touch "%s/pwned")\n' "$T" >"$V"
  eq "vault: a value that is not token-like is dropped and nothing is executed (the file is never sourced)" "$(tokrun FCODE_SECRETS_ENV="$V")/$([ -e "$T/pwned" ] && echo pwned || echo none)" "unset|unset/none"
  printf 'export GH_TOKEN="a b"\n' >"$V"
  eq "vault: a value with a space is dropped" "$(tokrun FCODE_SECRETS_ENV="$V")" "unset|unset"
  printf 'export GH_TOKEN=tok-vault-1\n' >"$V"
  eq "an already set GH_TOKEN wins over the vault" "$(tokrun FCODE_SECRETS_ENV="$V" GH_TOKEN=mine)" "mine|unset"
  eq "no vault file: unchanged, no token" "$(tokrun FCODE_SECRETS_ENV="$T/missing-vault")/$(q projects.tk.error)" "unset|unset/null"
  mkdir -p "$T/vault-dir"
  eq "vault path is not a readable file: unchanged, no token, quiet" "$(tokrun FCODE_SECRETS_ENV="$T/vault-dir")/$(wc -c <"$T/run.out" | tr -d ' ')" "unset|unset/0"
  printf 'export INSTABOX_API_KEY=ikey-3\n' >"$V"
  eq "vault without a GH_TOKEN line: nothing taken (INSTABOX_API_KEY never)" "$(tokrun FCODE_SECRETS_ENV="$V")" "unset|unset"
  printf 'export GH_TOKEN=tok-vault-1\n' >"$V"
  : >"$T/envseen"; env -u GH_TOKEN -u INSTABOX_API_KEY FCODE_SECRETS_ENV="$V" bash "$SYNC" tk >"$T/run.out" 2>&1
  eq "single-project run also gets it, same 55 s plan (one fetch)" "$(tr '\n' ' ' <"$T/envseen" | sed 's/ $//')" "tok-vault-1|unset"
  rm -f "$HOME/.local/bin/timeout"
} || echo "note: no timeout command here, the GH_TOKEN tests are skipped"

# ---- the script has no git command that writes to a repository except the one fast-forward ----
CODE=$(sed 's/[[:space:]]#[[:space:]].*//; /^[[:space:]]*#/d' "$SYNC" | grep -v 'for f in MERGE_HEAD' | sed 's/\^{commit}//g') # (the marker names rebase-merge/-apply and the rev-parse peel are not git commands)
eq "no checkout/reset/push/switch/rebase/update-ref/stash/pull/clean/commit/branch/tag in the code (comments aside)" "$(printf '%s\n' "$CODE" | grep -cE '\b(checkout|reset|push|switch|rebase|update-ref|stash|pull|clean|commit|branch -[dDmM]|tag -d)\b')" 0
eq "the only merge is one --ff-only --no-overwrite-ignore on origin/<default>, hooks/gc/maintenance off, never under timeout" "$(printf '%s\n' "$CODE" | grep -cE '\bmerge\b' | tr -d ' ')/$(printf '%s\n' "$CODE" | grep -c 'merge --ff-only --quiet --no-edit --no-overwrite-ignore "refs/remotes/origin/\$def"')/$(printf '%s\n' "$CODE" | grep -c 'core.hooksPath=/dev/null')/$(printf '%s\n' "$CODE" | grep -c 'gc.auto=0 -c maintenance.auto=false -c core.hooksPath=/dev/null -c core.fsmonitor=false')/$(printf '%s\n' "$CODE" | grep -cE '\bx [0-9]')" "2/1/1/1/0"
eq "the one fetch names the url and the explicit refspec, no prune, no tags, no FETCH_HEAD" "$(grep -c "fetch --no-write-fetch-head --no-tags --no-prune --no-recurse-submodules" "$SYNC")/$(grep -c "'+refs/heads/\*:refs/remotes/origin/\*'" "$SYNC")" 1/1

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
