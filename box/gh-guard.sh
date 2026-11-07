#!/bin/bash
# gh-guard (runs ON the coder box, installed as ~/.local/bin/gh, ahead of /usr/bin/gh on PATH): every call goes to the real gh unchanged
# (exec: same argv, stdin, stdout, stderr, exit code), except the ways to merge a PR or write .github / move a branch through gh:
#  - `gh pr merge` (any flag order, --auto included, -R/--repo, GH_REPO or the current repo) and `gh api` PUT repos/<o>/<r>/pulls/<n>/merge
#    of a PR that changes .github/ in a repo "with secrets" -> refused, exit 65;
#  - `gh api` writes (any method but GET/HEAD; fields or --input without -X mean POST) on repos/<o>/<r>/contents/.github..., actions/secrets...,
#    environments..., git/refs..., git/trees, git/commits or merges of a repo with secrets -> refused, exit 65;
#  - `gh api graphql` whose query, fields or --input body name mergePullRequest, enablePullRequestAutoMerge, enqueuePullRequest,
#    createCommitOnBranch, updateRef(s), createRef or mergeBranch -> refused, exit 65, in every repo: those mutations name their target by
#    node ID only, so the box cannot tell its repo (gh pr merge and git push stay open where the rules allow them);
#  - an alias (`gh alias set`) whose expansion runs merge or api -> refused, exit 65: type the full command so it is checked.
# A repo has secrets when owner/repo is listed in ~/.config/fcode/sensitive-repos, or a workflow on its default branch reads secrets other than
# GITHUB_TOKEN: read from origin's default branch when the current directory is a clone of that repo (same rule as the pre-push hook in
# box/fcode-add.sh hook_text; change both together), else from the GitHub API through the real gh. Anything unreadable counts as secrets.
# This is a box-side guard (defence in depth): /usr/bin/gh called directly, or the API reached without gh, bypasses it. The real gh is
# FCODE_GH_REAL (default /usr/bin/gh), resolved once and never this script.
real="${FCODE_GH_REAL:-/usr/bin/gh}"
if [ ! -x "$real" ] || [ -d "$real" ] || [ "$(readlink -f "$real")" = "$(readlink -f "$0")" ]; then echo "gh-guard: real gh not found ($real)" >&2; exit 127; fi
RE='secrets[[:space:]]*(\.[[:space:]]*[a-z0-9_-]+|\[)|tojson\([[:space:]]*secrets|secrets:[[:space:]]*inherit'
GQL='mergePullRequest|enablePullRequestAutoMerge|enqueuePullRequest|createCommitOnBranch|updateRefs?|createRef|mergeBranch'

# positional words of the call (flag values skipped), the -R/--repo, -X/--method and --input values and the api fields;
# -h/--help means pass through
words=(); repo=; method=; help=; input=; rawf=(); typf=()
vflag() { case "$1" in -R|--repo|-t|--subject|-b|--body|-F|--body-file|-A|--author-email|--match-head-commit|-X|--method|--field|-f|--raw-field|-H|--header|--input|-q|--jq|--template|--hostname|--cache|-p|--preview) return 0;; esac; return 1; }
setv() { case "$1" in -R|--repo) repo="$2";; -X|--method) method="$2";; -f|--raw-field) rawf+=("$2");; -F|--field) typf+=("$2");; --input) input="$2";; esac; }
args=("$@"); i=0; n=${#args[@]}
while [ "$i" -lt "$n" ]; do
  a="${args[$i]}"; i=$((i + 1))
  case "$a" in
    --) words+=("${args[@]:$i}"); break;;
    -h|--help) help=1;;
    --*=*) setv "${a%%=*}" "${a#*=}";;
    --*) if vflag "$a"; then setv "$a" "${args[$i]:-}"; i=$((i + 1)); fi;;
    -?*) # short flags, maybe clustered (-ds), the value attached (-Ro/r) or next
      j=1
      while [ "$j" -lt "${#a}" ]; do
        f="-${a:$j:1}"; j=$((j + 1))
        if vflag "$f"; then
          if [ "$j" -lt "${#a}" ]; then setv "$f" "${a:$j}"; else setv "$f" "${args[$i]:-}"; i=$((i + 1)); fi
          break
        fi
      done;;
    *) words+=("$a");;
  esac
done
[ -z "$help" ] || exec "$real" "$@"

# owner/repo of a git remote URL or path (git@host:o/r.git, https://host/o/r, /x/o/r.git)
slug_of() { local u="${1%/}"; u="${u%.git}"; local o="${u%/*}"; printf '%s/%s' "${o##*[/:]}" "${u##*/}"; }
# 0 = the matches of $RE (stdin) include a secret other than GITHUB_TOKEN
reads_secret() { tr -d ' \t' | grep -qvixF secrets.github_token; }
# 0 = sensitive. Local when the current directory is a clone of $1 (origin), else the API.
sensitive() {
  local s="$1" f="$HOME/.config/fcode/sensitive-repos" o b c m rc urls u e
  [ -f "$f" ] && sed 's/#.*//; s/[[:space:]]//g' "$f" | grep -qixF -- "$s" && return 0
  o="$(git config --get remote.origin.url 2>/dev/null)"
  if [ -n "$o" ] && [ "$(slug_of "$o" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')" ]; then
    b=$(git symbolic-ref -q refs/remotes/origin/HEAD) || b=
    for c in refs/remotes/origin/main refs/remotes/origin/master; do [ -n "$b" ] || ! git rev-parse -q --verify "$c" >/dev/null || b=$c; done
    [ -n "$b" ] || return 0
    m=$(git grep -ohiE "$RE" "$b" -- .github/workflows 2>/dev/null); rc=$?
    [ "$rc" -eq 1 ] && return 1
    [ "$rc" -eq 0 ] || return 0
    printf '%s\n' "$m" | reads_secret
    return
  fi
  e="$(mktemp)" || return 0
  urls="$("$real" api "repos/$s/contents/.github/workflows" -q '.[] | select(.type == "file") | .url' </dev/null 2>"$e")"; rc=$?
  if [ "$rc" -ne 0 ]; then grep -q 'HTTP 404' "$e"; rc=$?; rm -f "$e"; [ "$rc" -ne 0 ]; return; fi
  rm -f "$e"
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    m="$("$real" api "$u" -H 'Accept: application/vnd.github.raw' </dev/null 2>/dev/null)" || return 0
    printf '%s\n' "$m" | grep -oiE "$RE" | reads_secret && return 0
  done <<<"$urls"
  return 1
}
tmp= # stdin of the call, kept here when the guard had to read it (gh api graphql --input - or -F k=@-); handed to the real gh at exec
refuse() { [ -z "$tmp" ] || rm -f "$tmp"; echo "$1" >&2; exit 65; }
# the repo gh means by {owner}/{repo} (GH_REPO or the current clone)
cur=
current() { [ -n "$cur" ] || cur="$("$real" repo view --json nameWithOwner -q .nameWithOwner </dev/null 2>/dev/null)"; [ -n "$cur" ]; }
# refuse merging PR $1 ("" = the current branch's PR) of repo $2 ("" = gh's default) when it changes .github/ in a repo with secrets
merge_check() {
  local v=(pr view) out num url cnt paths p base touches=
  [ -z "$1" ] || v+=("$1"); [ -z "$2" ] || v+=(-R "$2")
  out="$("$real" "${v[@]}" --json number,url,changedFiles,files -q '.number, .url, .changedFiles, .files[].path' </dev/null 2>/dev/null)" \
    || refuse "gh-guard: không đọc được PR ${1:-của nhánh này}; không merge (chặn khi không chắc) — báo fcoding."
  { read -r num; read -r url; read -r cnt; mapfile -t paths; } <<<"$out"
  [[ "$url" =~ ^https://[^/]+/([^/]+/[^/]+)/pull/[0-9]+$ ]] || refuse "gh-guard: không đọc được repo của PR ${num:-?}; không merge (chặn khi không chắc) — báo fcoding."
  base="${BASH_REMATCH[1]}"
  [ "$cnt" = "${#paths[@]}" ] || touches=1 # gh lists at most 100 files: a list shorter than changedFiles may hide .github
  for p in "${paths[@]}"; do case "$p" in .github/*) touches=1;; esac; done
  if [ -n "$touches" ] && sensitive "$base"; then
    refuse "gh-guard: PR #$num sửa .github/ ở repo có secret; chỉ chủ được merge — gọi fcode-notify merge-ready."
  fi
}
# refuse a graphql call whose query, fields or body name a merge / branch-write mutation; files given with -F k=@<path> or --input are read
gql() {
  local b f src k
  b="$(printf '%s\n' "${rawf[@]}" "${typf[@]}")"
  for f in "${typf[@]}" ${input:+"=@$input"}; do
    f="${f#*=}"; [ "${f:0:1}" = @ ] || continue
    src="${f:1}"
    if [ "$src" = - ]; then
      [ -n "$tmp" ] || { tmp="$(mktemp)" && cat >"$tmp"; } || refuse "gh-guard: không đọc được stdin cho gh api graphql; bị chặn — báo fcoding."
      src="$tmp"
    fi
    if [ ! -f "$src" ] || [ ! -r "$src" ]; then refuse "gh-guard: không đọc được $src cho gh api graphql; bị chặn (chặn khi không chắc) — báo fcoding."; fi
    b+=$'\n'"$(cat -- "$src")"
  done
  k="$(grep -oiE "$GQL" <<<"$b")" || return 0
  refuse "gh-guard: gh api graphql có ${k%%$'\n'*} (merge hoặc ghi nhánh) bị chặn: box không biết repo đích; dùng gh pr merge hoặc git push để box kiểm tra — repo có secret thì gọi fcode-notify merge-ready."
}

case "${words[0]:-}" in
  ''|auth|browse|codespace|discussion|gist|issue|org|pr|project|release|repo|skill|cache|run|workflow|agent-task|alias|api|attestation|completion|\
  config|copilot|extension|gpg-key|label|licenses|preview|ruleset|search|secret|ssh-key|status|variable|help|version|accessibility|actions|\
  environment|exit-codes|formatting|mintty|reference|telemetry) ;;
  *) # an alias or an extension: an alias that runs merge or api would skip the checks below
    while IFS= read -r l; do
      [ "${l%%: *}" = "${words[0]}" ] || continue
      [[ " ${l#*: } " =~ [^[:alnum:]_-](merge|api)[^[:alnum:]_-] ]] \
        && refuse "gh-guard: alias ${words[0]} chạy '${l#*: }'; box không kiểm tra alias — gõ lệnh gh đầy đủ."
    done < <("$real" alias list </dev/null 2>/dev/null);;
esac
if [ "${words[0]:-}" = pr ] && [ "${words[1]:-}" = merge ]; then
  merge_check "${words[2]:-}" "$repo"
elif [ "${words[0]:-}" = api ]; then
  m="${method^^}"
  if [ -z "$m" ]; then if [ "${#rawf[@]}" -gt 0 ] || [ "${#typf[@]}" -gt 0 ] || [ -n "$input" ]; then m=POST; else m=GET; fi; fi
  g=; shopt -s nocasematch
  for a in "${words[@]:1}"; do [[ "$a" =~ ^([^?#]*/)?graphql/*([?#].*)?$ ]] && g=1; done
  shopt -u nocasematch
  [ -z "$g" ] || gql
  case "$m" in
    GET|HEAD) ;;
    *)
      for a in "${words[@]:1}"; do
        t="$a"
        if [[ "$t" == *'{owner}'* || "$t" == *'{repo}'* ]]; then
          current || refuse "gh-guard: không biết repo hiện tại cho gh api $m; bị chặn — báo fcoding."
          t="${t//\{owner\}\/\{repo\}/$cur}"
        fi
        [[ "$t" == *repos/* ]] || continue
        [[ "$t" == *://* ]] && t="${t#*://}" && t="/${t#*/}"
        if [[ "$t" == *%* || "$t" == *\\* || "$t" == *//* || "$t" == */./* || "$t" == */../* || "$t" == */. || "$t" == */.. || "$t" == *'{'* ]]; then
          refuse "gh-guard: không đọc rõ đường dẫn của gh api $m ($a); bị chặn — báo fcoding."
        fi
        shopt -s nocasematch
        if [[ "$t" =~ (^|/)repos/([^/]+/[^/?#]+)/pulls/([^/?#]+)/merge([/?#]|$) ]]; then
          s="${BASH_REMATCH[2]}"; p="${BASH_REMATCH[3]}"; shopt -u nocasematch
          merge_check "$p" "$s"
        elif [[ "$t" =~ (^|/)repos/([^/]+/[^/?#]+)/(contents/\.github([/?#]|$)|actions/secrets([/?#]|$)|environments([/?#]|$)|git/(refs|trees|commits)([/?#]|$)|merges([/?#]|$)) ]]; then
          s="${BASH_REMATCH[2]}"; shopt -u nocasematch
          sensitive "$s" && refuse "gh-guard: $s dùng secret trong workflow; gh api $m vào .github/, secrets, environments, git refs/trees/commits hay merges bị chặn — báo fcoding, chủ làm."
        fi
        shopt -u nocasematch
      done;;
  esac
fi
[ -z "$tmp" ] || { exec 0<"$tmp"; rm -f "$tmp"; }
exec "$real" "$@"
