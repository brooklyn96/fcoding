#!/bin/bash
# gh-guard (runs ON the coder box, installed as ~/.local/bin/gh, ahead of /usr/bin/gh on PATH).
# Threat model: this guard and the box pre-push hook (box/fcode-add.sh hook_text) stop an honest agent's mistake and a rule-following agent's
# shortcut. They are NOT a security boundary against a hostile process on the box (it can run /usr/bin/gh, git push --no-verify or curl with
# the token): the real boundary is that every deploy key stored as a GitHub secret is a VPS forced-command key that can only run the deploy
# gate. Still, the guard fails CLOSED: what it cannot classify with certainty is refused (exit 65), by refusing whole classes of calls.
# Every call goes to the real gh unchanged (exec: same argv, stdin, stdout, stderr, exit code), except:
#  - the first word is not a built-in gh command (an alias, an extension) -> refused;
#  - `gh pr merge` and `gh api` are parsed the way gh parses flags (--f=v, --f v, -f=v, -fv, clustered -ds); a flag that command does not
#    have, a missing value or an extra argument -> refused. --help changes nothing: the call is judged as if it runs;
#  - `gh pr merge` of a PR whose base repo has secrets: --auto / --disable-auto (any value) -> refused. Else the PR's files are read from REST
#    pulls/<n>/files (every page, the new AND the old name of a rename); a path under .github/ or a list shorter than the PR's file count ->
#    refused, unless the owner approved that head commit (guard_allow; the file is removed after the merge succeeds). The merge then runs
#    pinned to the inspected head: --match-head-commit <sha> is added (another value given -> refused). Repos without secrets: unchanged;
#  - `gh api`: every graphql call -> refused (its target repo cannot be known). A call that is not GET (fields or --input without -X mean
#    POST, as in gh) -> refused unless its endpoint names repos/<owner>/<repo>/... plainly ({owner}/{repo} filled from the current repo; no
#    backslash, //, . or .. segment, %2e %2f %5c %25; github.com only) and that repo has no secrets. GET calls pass.
# "Has secrets": the shared rule below (the same text as in the hook), read from origin's default branch when the current directory is a
# clone of that repo, else through the API: listed in ~/.config/fcode/sensitive-repos, or a file under .github/ on the default branch
# contains "secrets" in any case. Anything unreadable counts as secrets. The real gh is FCODE_GH_REAL (default /usr/bin/gh), never this script.
real="${FCODE_GH_REAL:-/usr/bin/gh}"
if [ ! -x "$real" ] || [ -d "$real" ] || [ "$(readlink -f "$real")" = "$(readlink -f "$0")" ]; then echo "gh-guard: real gh not found ($real)" >&2; exit 127; fi

# >>> shared rule (the same text in box/fcode-add.sh hook_text; a test keeps them equal)
# listed <owner/repo>: 0 = the owner listed it in ~/.config/fcode/sensitive-repos (one per line, any case, # comments)
listed() { [ -f "$HOME/.config/fcode/sensitive-repos" ] && sed 's/#.*//; s/[[:space:]]//g' "$HOME/.config/fcode/sensitive-repos" | grep -qixF -- "$1"; }
# default_ref: $db = origin's default branch (origin/HEAD, else origin/main, else origin/master); 1 = none
default_ref() {
  db=$(git symbolic-ref -q refs/remotes/origin/HEAD) || db=
  for sr_c in refs/remotes/origin/main refs/remotes/origin/master; do [ -n "$db" ] || ! git rev-parse -q --verify "$sr_c" >/dev/null || db=$sr_c; done
  [ -n "$db" ]
}
# sensitive_local <owner/repo> [tree]: 0 = the repo of this clone has secrets: it is listed; origin's default branch cannot be resolved; or a
# file under .github/ (any depth, workflows and actions) on that branch, or on [tree], contains "secrets" in any case. Unreadable = secrets.
# $why ends the refusal message.
sensitive_local() {
  why=' dùng secret trong workflow'
  listed "$1" && return 0
  default_ref || { why=': không xác định được nhánh chính; coi là repo có secret'; return 0; }
  for sr_t in "$db" ${2:+"$2"}; do
    git grep -qiF secrets "$sr_t" -- ':(top).github' 2>/dev/null
    case $? in 0) return 0;; 1) ;; *) why=': không đọc được .github/; coi là repo có secret'; return 0;; esac
  done
  return 1
}
# guard_allow <owner/repo> <sha> <push|merge>: 0 = the owner approved exactly this commit: ~/.config/fcode/guard-allow/<owner>__<repo>__<sha>
# (lower case, a plain file of mode 600, made by the Architect only after the owner's explicit Yes). Each use adds one line to
# ~/.local/state/fcode/guard-allow.log (UTC time, repo, sha, push|merge); no log line, no allow. $ga = the file.
guard_allow() {
  case "$2" in *[!0-9a-f]*) return 1;; esac
  [ "${#2}" -eq 40 ] || return 1
  ga=$HOME/.config/fcode/guard-allow/$(printf '%s__%s__%s' "${1%%/*}" "${1#*/}" "$2" | tr '[:upper:]' '[:lower:]')
  [ -f "$ga" ] && [ ! -L "$ga" ] && [ "$(stat -c %a "$ga" 2>/dev/null)" = 600 ] || return 1
  mkdir -p "$HOME/.local/state/fcode" && printf '%s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >>"$HOME/.local/state/fcode/guard-allow.log"
}
# <<< shared rule

refuse() { echo "$1" >&2; exit 65; }
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# owner/repo of a git remote URL or path (git@host:o/r.git, https://host/o/r, /x/o/r.git)
slug_of() { local u="${1%/}"; u="${u%.git}"; local o="${u%/*}"; printf '%s/%s' "${o##*[/:]}" "${u##*/}"; }
# 0 = owner/repo $1 has secrets (see the header): the shared rule in a clone of $1, else the API
sensitive() {
  local s="$1" o b out t list x
  o="$(git config --get remote.origin.url 2>/dev/null)"
  if [ -n "$o" ] && [ "$(lc "$(slug_of "$o")")" = "$(lc "$s")" ]; then sensitive_local "$s"; return; fi
  why=' dùng secret trong workflow'
  listed "$s" && return 0
  why=': không đọc được .github/ qua API; coi là repo có secret'
  b="$("$real" api "repos/$s" -q .default_branch </dev/null 2>/dev/null)" || return 0
  [[ "$b" =~ ^[A-Za-z0-9._-]+$ ]] || return 0
  out="$("$real" api "repos/$s/git/trees/$b?recursive=1" -q '.truncated, (.tree[] | select(.type != "tree" and (.path == ".github" or (.path | startswith(".github/")))) | .type + " " + .sha)' </dev/null 2>/dev/null)" || return 0
  { read -r t; mapfile -t list; } <<<"$out"
  [ "$t" = false ] || return 0
  for x in "${list[@]}"; do
    [ -n "$x" ] || continue
    [[ "$x" =~ ^blob\ [0-9a-f]{40}$ ]] || return 0
    out="$("$real" api "repos/$s/git/blobs/${x#blob }" -H 'Accept: application/vnd.github.raw' </dev/null 2>/dev/null)" || return 0
    grep -qiF secrets <<<"$out" && { why=' dùng secret trong workflow'; return 0; }
  done
  return 1
}
# the repo gh means by {owner}/{repo} (GH_REPO or the current clone)
cur=
current() { [ -n "$cur" ] || cur="$("$real" repo view --json nameWithOwner -q .nameWithOwner </dev/null 2>/dev/null)"; [[ "$cur" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; }

# ---- parse like gh (pflag). The flags of gh pr merge and gh api (gh 2.103): ..B = no value, ..V = takes a value; no flag is a value flag in
# one and a no-value flag in the other, so one pass with both value lists finds the command words; then the command's own lists must hold
# every flag seen.
GHCMDS=' auth browse codespace discussion gist issue org pr project release repo skill cache run workflow agent-task alias api attestation completion config copilot extension gpg-key label licenses preview ruleset search secret ssh-key status variable help version accessibility actions environment exit-codes formatting mintty reference telemetry '
PRB=' --admin --auto -d --delete-branch --disable-auto -m --merge -r --rebase -s --squash --help '
PRV=' -A --author-email -b --body -F --body-file --match-head-commit -t --subject -R --repo '
APB=' --allow-escape-sequences -i --include --paginate --silent --slurp --verbose --help '
APV=' --cache -F --field -H --header --hostname --input -q --jq -X --method -p --preview -f --raw-field -t --template '
words=(); fl=(); declare -A val=(); bad=; dd=-1
setv() { case "$1" in -R) val[--repo]="$2";; -X) val[--method]="$2";; *) val[$1]="$2";; esac; }
args=("$@"); i=0; n=$#
while [ "$i" -lt "$n" ]; do
  a="${args[$i]}"; i=$((i + 1))
  case "$a" in
    --) dd=$((i - 1)); words+=("${args[@]:$i}"); break;;
    --*=*) fl+=("${a%%=*}"); setv "${a%%=*}" "${a#*=}";;
    --?*) fl+=("$a"); if [[ "$PRV$APV" == *" $a "* ]]; then [ "$i" -lt "$n" ] || bad=1; setv "$a" "${args[$i]:-}"; i=$((i + 1)); fi;;
    -?*) # short flags, maybe clustered (-ds); a value attached (-Ro/r, -R=o/r) or next; -d=false gives the rest to the no-value flag
      j=1
      while [ "$j" -lt "${#a}" ]; do
        f="-${a:$j:1}"; j=$((j + 1)); fl+=("$f")
        if [[ "$PRV$APV" == *" $f "* ]]; then
          if [ "$j" -lt "${#a}" ]; then v="${a:$j}"; [ "${v:0:1}" != = ] || v="${v:1}"; setv "$f" "$v"
          else [ "$i" -lt "$n" ] || bad=1; setv "$f" "${args[$i]:-}"; i=$((i + 1)); fi
          break
        fi
        [ "${a:$j:1}" != = ] || break
      done;;
    *) words+=("$a");;
  esac
done
# 0 = every flag seen is in the list $1
known() { local f; for f in "${fl[@]}"; do [[ "$1" == *" $f "* ]] || return 1; done; }

[ -n "${words[0]:-}" ] || exec "$real" "$@"
[[ "$GHCMDS" == *" ${words[0]} "* ]] || refuse "gh-guard: '${words[0]}' không phải lệnh gh có sẵn (alias, extension) — box không chạy alias hay extension; gõ lệnh gh đầy đủ."

if [ "${words[0]}" = pr ] && [ "${words[1]:-}" = merge ]; then
  { known "$PRB$PRV" && [ -z "$bad" ] && [ "${#words[@]}" -le 3 ]; } || refuse "gh-guard: không đọc chắc lệnh gh pr merge này (cờ lạ, thiếu giá trị hay thừa đối số); bị chặn — gõ lại đúng cú pháp gh."
  v=(pr view); [ -z "${words[2]:-}" ] || v+=("${words[2]}"); [ -z "${val[--repo]+x}" ] || v+=(-R "${val[--repo]}")
  out="$("$real" "${v[@]}" --json number,url,headRefOid,changedFiles -q '.number, .url, .headRefOid, .changedFiles' </dev/null 2>/dev/null)" \
    || refuse "gh-guard: không đọc được PR ${words[2]:-của nhánh này}; không merge (chặn khi không chắc) — báo fcoding."
  { read -r num; read -r url; read -r head; read -r cnt; } <<<"$out"
  { [[ "$url" =~ ^https://[^/]+/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+)$ ]] && [ "${BASH_REMATCH[2]}" = "$num" ] && base="${BASH_REMATCH[1]}" \
    && [[ "$head" =~ ^[0-9a-f]{40}$ ]] && [[ "$cnt" =~ ^[0-9]+$ ]]; } || refuse "gh-guard: không đọc rõ PR ${num:-?} (repo, head, số file); không merge — báo fcoding."
  sensitive "$base" || exec "$real" "$@"
  for f in "${fl[@]}"; do
    case "$f" in --auto|--disable-auto) refuse "gh-guard: PR #$num: auto-merge ở repo có secret bị chặn (box chỉ kiểm tra được lần merge chạy ngay); merge không --auto.";; esac
  done
  if [ -n "${val[--match-head-commit]+x}" ] && [ "${val[--match-head-commit]}" != "$head" ]; then
    refuse "gh-guard: PR #$num: --match-head-commit ${val[--match-head-commit]} khác head đã kiểm tra $head; bị chặn."
  fi
  touches=
  out="$("$real" api --paginate "repos/$base/pulls/$num/files" -q '.[] | [.filename, (.previous_filename // "")] | @tsv' </dev/null 2>/dev/null)" || touches=1
  files=(); [ -z "$out" ] || mapfile -t files <<<"$out"
  [ "${#files[@]}" = "$cnt" ] || touches=1 # GitHub lists at most 3000 files: a shorter list may hide .github
  shopt -s nocasematch
  for x in "${files[@]}"; do
    for p in "${x%%$'\t'*}" "${x#*$'\t'}"; do [[ "$p" == .github || "$p" == .github/* ]] && touches=1; done
  done
  shopt -u nocasematch
  # the call as given, pinned to the inspected head (before a closing --, where flags still count)
  fwd=("$@")
  if [ -z "${val[--match-head-commit]+x}" ]; then
    if [ "$dd" -lt 0 ]; then fwd+=(--match-head-commit "$head"); else fwd=("${@:1:$dd}" --match-head-commit "$head" "${@:$((dd + 1))}"); fi
  fi
  if [ -n "$touches" ]; then
    guard_allow "$base" "$head" merge \
      || refuse "gh-guard: PR #$num sửa .github/ ở repo có secret (head $head); chỉ chủ được duyệt — gọi fcode-notify <dự án> merge-ready \"<một dòng>\" $url"
    "$real" "${fwd[@]}"; rc=$?
    [ "$rc" -ne 0 ] || rm -f -- "$ga"
    exit "$rc"
  fi
  exec "$real" "${fwd[@]}"
elif [ "${words[0]}" = api ]; then
  { known "$APB$APV" && [ -z "$bad" ] && [ "${#words[@]}" -eq 2 ]; } || refuse "gh-guard: không đọc chắc lệnh gh api này (cờ lạ, thiếu giá trị hay thừa đối số); bị chặn — gõ lại đúng cú pháp gh."
  ep="${words[1]}"
  shopt -s nocasematch
  [[ "$ep" == *graphql* ]] && { shopt -u nocasematch; refuse "gh-guard: gh api graphql bị chặn trên box (box không biết repo đích); dùng lệnh gh thường (gh pr …, gh issue …) — báo fcoding nếu thật cần."; }
  shopt -u nocasematch
  if [ -n "${val[--method]+x}" ]; then m="${val[--method]}"
  else m=GET; for f in "${fl[@]}"; do case "$f" in -f|--raw-field|-F|--field|--input) m=POST;; esac; done; fi
  if [ "${m^^}" != GET ]; then
    p="${ep#/}"; tgt=
    shopt -s nocasematch
    if [[ -z "${val[--hostname]+x}" && ( -z "${GH_HOST:-}" || "$GH_HOST" == github.com ) && "$p" != *\\* && "$p" != *//* ]] \
      && ! [[ "$p" =~ (^|/)\.\.?([/?#]|$) || "$p" =~ %(2e|2f|5c|25) ]]; then
      shopt -u nocasematch
      if [[ "$p" == *'{owner}'* || "$p" == *'{repo}'* ]]; then current && p="${p//\{owner\}/${cur%%/*}}" && p="${p//\{repo\}/${cur#*/}}" || p=; fi
      [[ "$p" =~ ^repos/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)([/?#]|$) ]] && tgt="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    fi
    shopt -u nocasematch
    [ -n "$tgt" ] || refuse "gh-guard: gh api $m $ep: không xác định chắc repo đích; bị chặn (chặn khi không chắc) — báo fcoding."
    sensitive "$tgt" && refuse "gh-guard: $tgt$why; gh api $m vào repo này bị chặn — báo fcoding, chủ làm."
  fi
fi
exec "$real" "$@"
