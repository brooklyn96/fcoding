#!/usr/bin/env bash
# fcode-git-sync: tell how far every FCode project is from GitHub, and (timer run only) fast-forward the ones that are idle and clean.
# The only change it ever makes to a repository is one fast-forward of the default branch (step 3): it never creates a commit and
# never checks out, resets, stashes, rebases, deletes or pushes; every other local branch and tag stays as it is.
# `fcode-git-sync <project>` (the server runs it right before it opens a session) is look-only: steps 1, 2 and 4, never step 3.
# For each project in ~/.fcoding/config.json ("projects": name -> dir):
#   1. fetch from origin into refs/remotes/origin/* only (timeout, no prompts). The fetch names the URL and an explicit
#      refspec, so a configured refspec, prune or tag option of the repo cannot make it touch local branches or tags.
#   2. count, read-only: behindDefault = commits on origin/<default> that HEAD lacks; aheadOfOrigin = HEAD commits that
#      are on no origin/* branch; dirty = tracked or untracked changes.
#   3. `git merge --ff-only origin/<default>` ONLY when ALL hold: behind > 0 and ahead == 0; HEAD is on the default branch;
#      no tracked change (untracked files do not count); no merge / rebase / cherry-pick / revert / bisect / index.lock in
#      progress; no filter.* config key exists in any scope (Git LFS and the like: a checkout would run
#      slow external code; a global `git lfs install` thus turns this step off on the box); the run is younger than 10 min; and no process of this user (omp, claude, codex, a
#      shell, a tmux pane) has its cwd inside the work tree (/proc/<pid>/cwd; without /proc the project counts as busy).
#      Hooks, fsmonitor, submodule recursion, auto gc and overwriting of ignored files are off for that merge, so an
#      untracked OR ignored file in the way makes it fail. The merge is never time-limited or killed (a half-written work
#      tree is worse than a slow merge; the 10 min rule keeps systemd's 15 min unit timeout from ever hitting one).
#      A failure leaves the checkout as it was.
#      Why a project was not updated is recorded as autoSkip in the state file.
#   4. write ~/.local/state/fcode/git-sync.json (atomic, mode 600).
# Agents still sync first at the start of a task (see agents-git.md, "Sync first"): this timer only catches up an idle main.
# GH_TOKEN (private https projects) is taken from the instabox vault file when the environment has none; see the block before the project loop.
# One run at a time (flock). Quiet: problems go in the state file; stderr only when the script itself cannot run.
# One project failing never stops the others. Exit 0 unless the script itself is broken.
# `fcode-git-sync <project>`: the same for that one project only (shorter timeouts, the whole run within about 55 s: 15 s lock wait + 30 s fetch + 5 s kill + counts); the
# other entries of the state file stay as they are. An unknown name: a message on stderr, exit 0, state unchanged.
set -u
export PATH="$HOME/.local/bin:$HOME/.bun/bin:/usr/local/bin:$PATH"
export LC_ALL=C GIT_TERMINAL_PROMPT=0

CFG="$HOME/.fcoding/config.json"
DIR="$HOME/.local/state/fcode"
STATE="$DIR/git-sync.json"
ONLY="${1:-}"
if [ -n "$ONLY" ]; then FETCH_T="${FCODE_GIT_FETCH_TIMEOUT:-30}" LOCK_W=15
else FETCH_T="${FCODE_GIT_FETCH_TIMEOUT:-60}" LOCK_W=0; fi
LATE_S="${FCODE_GIT_LATE_AFTER:-600}" # no merge is started once the run is this many seconds old (the unit's TimeoutStartSec is 15 min)
case $LATE_S in ''|*[!0-9]*) LATE_S=600 ;; esac

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# first line only, control characters dropped, URL credentials / tokens masked, at most 200 characters:
# raw git output never goes into the state file
redact() {
  head -n1 | tr '\r\t' '  ' | tr -d '\000-\010\013\014\016-\037\177' \
    | sed -E 's#//[^/@[:space:]]+@#//[redacted]@#g; s#(ghp_|gho_|ghs_|ghu_|ghr_|github_pat_)[A-Za-z0-9_]+#[redacted]#g; s#x-access-token[^[:space:]]*#[redacted]#g' \
    | cut -c1-200
}
# external commands: no stdin, and without the lock fd so a leftover child (ssh) cannot hold the lock
x() { local t=$1; shift; timeout -k 5 "$t" "$@" 9>&- </dev/null; }
g() { git --no-optional-locks -C "$P" "$@" 9>&- </dev/null; }
add_err() { err="${err:+$err; }$1"; }
# in_progress <git dir>: a merge, rebase, cherry-pick, revert or bisect is under way, or a stale index.lock is there
in_progress() {
  local f
  for f in MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG index.lock rebase-merge rebase-apply sequencer; do
    [ -e "$1/$f" ] && return 0
  done
  return 1
}
# filters: any filter.* key is configured in any scope (repo, global, system): a checkout could run slow external code, or die
# mid-way (a `required` driver that cannot smudge), e.g. Git LFS. No attributes parsing: a global `git lfs install` therefore
# turns the auto fast-forward off on this box, which is accepted (safe; agents still sync first).
filters() { [ -n "$(g config --get-regexp '^filter\.' 2>/dev/null)" ]; }
# busy: a process of this user has its cwd inside the work tree the merge moves (the repo's top level, not the configured dir,
# which can be a subdirectory), or we cannot tell (no /proc). omp, claude, codex, a shell and a tmux pane all show up here.
# The scan runs in a subshell with cwd / so neither it nor its children can match; this script's own pid is skipped.
# The trailing slash keeps /ws/app from matching /ws/app-two.
busy() {
  local rp
  [ -d /proc/self ] || return 0
  rp=$(g rev-parse --show-toplevel 2>/dev/null) && rp=$(realpath -e -- "$rp" 2>/dev/null) || return 0
  ! command -v cygpath >/dev/null || rp=$(cygpath -u "$rp") # Git Bash prints C:/... from git; /proc shows /c/...
  rp=${rp%/}
  (
    cd / || exit 0
    for d in /proc/[0-9]*; do
      [ "${d#/proc/}" = "$$" ] && continue
      c=$(readlink "$d/cwd" 2>/dev/null) || continue
      case "$c/" in "$rp"/*) exit 0 ;; esac
    done
    exit 1
  )
}

# sync_one <name> <dir>: appends one TSV row (name branch default dirty behind ahead fetchedAt autoUpdated autoSkip error)
sync_one() {
  local name=$1 gd out rc ssh url dirty=false fetched= err= branch= def= behind= ahead= updated=false skip=
  P=$2
  if ! gd=$(g rev-parse --absolute-git-dir 2>/dev/null); then
    add_err "not a git repository"
  else
    branch=$(g symbolic-ref --short -q HEAD) || branch="(detached)"
    def=$(g symbolic-ref --short -q refs/remotes/origin/HEAD) || def=origin/main
    def=${def#origin/}

    # the repo's own ssh command (deploy key) when it sets one; never ask a question
    ssh=$(g config --get core.sshCommand) || ssh=ssh
    export GIT_SSH_COMMAND="$ssh -o BatchMode=yes -o ConnectTimeout=20"
    url=$(g config --get-all remote.origin.url | head -n1) # the FIRST url, the one `git fetch origin` uses
    if [ -z "$url" ]; then
      add_err "no origin remote"
    else
      # --no-write-fetch-head: .git/FETCH_HEAD stays as the user's own fetch left it (a later `git merge FETCH_HEAD` must not see ours)
      out=$(x "$FETCH_T" git -C "$P" -c gc.auto=0 -c maintenance.auto=false fetch --no-write-fetch-head --no-tags --no-prune --no-recurse-submodules \
        "$url" '+refs/heads/*:refs/remotes/origin/*' 2>&1); rc=$?
      if [ $rc -eq 0 ]; then fetched=$(now)
      elif [ $rc -eq 124 ]; then add_err "fetch timed out after ${FETCH_T}s"
      else add_err "fetch failed: $(printf %s "$out" | redact)"; fi
    fi

    if out=$(g status --porcelain 2>&1); then [ -z "$out" ] || dirty=true; else dirty=true; add_err "status failed"; fi
    if g rev-parse -q --verify "refs/remotes/origin/$def^{commit}" >/dev/null; then
      behind=$(g rev-list --count "HEAD..origin/$def" 2>/dev/null) || behind=
    else
      add_err "no origin/$def"
    fi
    ahead=$(g rev-list --count HEAD --not --remotes=origin 2>/dev/null) || ahead=

    # fast-forward the default branch (timer run only), only when nothing can be in the way (see the header); the first failing check is the reason
    if [ -z "$ONLY" ] && [ "${behind:-0}" -gt 0 ]; then
      if [ "$SECONDS" -ge "$LATE_S" ]; then skip=late # the run is old: systemd's TimeoutStartSec must never find a merge in flight
      elif in_progress "$gd"; then skip=in_progress
      elif [ "$branch" != "$def" ]; then skip=on_branch
      elif ! out=$(g status --porcelain --untracked-files=no 2>/dev/null) || [ -n "$out" ]; then skip=dirty
      elif [ "${ahead:-1}" -ne 0 ]; then skip=ahead
      elif filters; then skip=filters
      elif busy; then skip=busy
      elif g -c gc.auto=0 -c maintenance.auto=false -c core.hooksPath=/dev/null -c core.fsmonitor=false -c submodule.recurse=false -c merge.autoStash=false \
          merge --ff-only --quiet --no-edit --no-overwrite-ignore "refs/remotes/origin/$def" >/dev/null 2>&1; then
        updated=true
        behind=$(g rev-list --count "HEAD..origin/$def" 2>/dev/null) || behind=
      else skip=ff_failed; fi
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$branch" "$def" "$dirty" "$behind" "$ahead" "$fetched" "$updated" "$skip" "$err" >>"$ROWS"
}

command -v node >/dev/null || { echo "fcode-git-sync: node is missing" >&2; exit 1; }
mkdir -p "$DIR" && chmod 700 "$DIR" 2>/dev/null
exec 9>"$DIR/git-sync.lock"
{ if [ "$LOCK_W" -gt 0 ]; then flock -w "$LOCK_W" 9; else flock -n 9; fi; } || exit 0 # another run is active (a single-project run waits up to LOCK_W s)

# The timer unit has no GH_TOKEN (a systemd user unit gets no login environment), so the fetch of a project added by the token route
# (https origin + the repo's `!gh auth git-credential` helper) would fail on every run. Take GH_TOKEN alone from the instabox vault
# file, the way start.sh does (install.sh): the one line `[export ]GH_TOKEN=...` is read as text (the file is never sourced), the
# value must look like a token, and nothing else (INSTABOX_API_KEY included) is taken. An already set GH_TOKEN wins. It only lives in
# this process's environment for git's children: never written to the state file, never printed.
vf=${FCODE_SECRETS_ENV:-/run/instabox/secrets/env}
if [ -z "${GH_TOKEN:-}" ] && [ -r "$vf" ]; then
  t=$(sed -n -E '/^(export[[:space:]]+)?GH_TOKEN=/{s///p;q;}' "$vf" 2>/dev/null | tr -d '\r')
  case $t in \"*\") t=${t#\"}; t=${t%\"} ;; \'*\') t=${t#\'}; t=${t%\'} ;; esac
  case $t in ''|*[!A-Za-z0-9._-]*) t= ;; esac
  if [ -n "$t" ]; then GH_TOKEN=$t; export GH_TOKEN; fi
  unset t
fi
unset vf

rm -f "$STATE".*.tmp # left by a run that was killed while writing (we hold the lock)
ROWS=$(mktemp "$DIR/rows.XXXXXX") || exit 1
LIST="$ROWS.list"
trap 'rm -f "$ROWS" "$LIST" "$LIST.err"' EXIT
trap 'exit 143' TERM INT HUP
# project records: NUL-delimited name, path; a name or path with a control character is skipped
node -e '
const bad = /[\x00-\x1f\x7f]/, p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).projects || {};
for (const [k, v] of Object.entries(p)) if (k && typeof v === "string" && v && !bad.test(k) && !bad.test(v)) process.stdout.write(k + "\0" + v + "\0");
' "$CFG" >"$LIST" 2>"$LIST.err" || { echo "fcode-git-sync: cannot read $CFG: $(redact <"$LIST.err")" >&2; exit 0; }
found=0
while IFS= read -r -d '' name && IFS= read -r -d '' path; do
  [ -z "$ONLY" ] || [ "$name" = "$ONLY" ] || continue
  found=1; sync_one "$name" "$path"
done <"$LIST"
[ -z "$ONLY" ] || [ $found = 1 ] || { echo "fcode-git-sync: no project '$ONLY' in $CFG" >&2; exit 0; }

# rows -> state file: atomic (temp + rename), mode 600; lastFetchAt of a failed fetch keeps the previous value.
# The maps have no prototype, so a project called __proto__ is an ordinary entry.
node -e '
const fs = require("fs"), [rows, out, at, only] = process.argv.slice(1);
const old = Object.create(null);
try { for (const [k, v] of Object.entries(JSON.parse(fs.readFileSync(out, "utf8")).projects || {})) old[k] = v; } catch {}
const projects = Object.create(null); // single-project run: the other entries stay as they are
if (only) for (const k in old) projects[k] = old[k];
for (const l of fs.readFileSync(rows, "utf8").split("\n")) {
  if (!l) continue;
  const [n, b, d, di, be, ah, lf, au, sk, er] = l.split("\t");
  projects[n] = { branch: b || null, default: d || null, dirty: di === "true", behindDefault: be ? +be : null,
    aheadOfOrigin: ah ? +ah : null, lastFetchAt: lf || (old[n] && old[n].lastFetchAt) || null, error: er || null,
    autoUpdated: au === "true", autoSkip: sk || null };
}
const tmp = out + "." + process.pid + ".tmp";
fs.writeFileSync(tmp, JSON.stringify({ updatedAt: at, projects }, null, 2) + "\n", { mode: 0o600 });
fs.renameSync(tmp, out);
' "$ROWS" "$STATE" "$(now)" "$ONLY" 9>&- || { echo "fcode-git-sync: cannot write $STATE" >&2; exit 1; }
exit 0
