#!/bin/bash
# gh-guard (runs ON the coder box, installed as ~/.local/bin/gh, ahead of /usr/bin/gh on PATH).
# Threat model: this guard and the box pre-push hook (box/fcode-add.sh hook_text) stop an honest agent's mistake and a rule-following agent's
# shortcut. They are NOT a security boundary against a hostile process on the box (it can run /usr/bin/gh, git push --no-verify or curl with
# the token). The guard fails CLOSED by refusing whole classes of calls (exit 65), never by reading content.
# Every call goes to the real gh unchanged (exec: same argv, stdin, stdout, stderr, exit code), except:
#  - the first word is not a full built-in gh command name (an alias, an extension, gh's own short names; `gh alias` and `gh extension`
#    themselves included) -> refused;
#  - `gh pr merge` and `gh api` are parsed the way gh parses flags (--f=v, --f v, -f=v, -fv, clustered -ds); a flag that command does not
#    have, a missing value or an extra argument -> refused. --help changes nothing: the call is judged as if it runs;
#  - `gh pr merge` of a PR whose base repo is not in ~/.config/fcode/no-secret-repos (no_secret: the owner confirmed it has no Actions
#    repository secret): --auto / --disable-auto (any value) -> refused. Else the PR's files are read from REST pulls/<n>/files (every page,
#    the new AND the old name of a rename); a path under .github/, a list shorter than the PR's file count or an unreadable list -> refused
#    (the owner merges such a PR on GitHub). The merge then runs pinned to the inspected head: --match-head-commit <sha> is added (another
#    value given -> refused). Listed repos: unchanged;
#  - `gh api`: every graphql call and every call that is not GET (fields or --input without -X mean POST, as in gh) -> refused, in every repo.
# The real gh is FCODE_GH_REAL (default /usr/bin/gh), never this script.
real="${FCODE_GH_REAL:-/usr/bin/gh}"
if [ ! -x "$real" ] || [ -d "$real" ] || [ "$(readlink -f "$real")" = "$(readlink -f "$0")" ]; then echo "gh-guard: real gh not found ($real)" >&2; exit 127; fi

# no_secret <owner/repo>: 0 = listed in ~/.config/fcode/no-secret-repos (one GitHub slug per line, any case, # comments); the same line is in the hook
no_secret() { [ -f "$HOME/.config/fcode/no-secret-repos" ] && sed 's/#.*//; s/[[:space:]]//g' "$HOME/.config/fcode/no-secret-repos" | grep -qixF -- "$1"; }
refuse() { echo "$1" >&2; exit 65; }

# ---- parse like gh (pflag). The flags of gh pr merge and gh api (gh 2.103): ..B = no value, ..V = takes a value; no flag is a value flag in
# one and a no-value flag in the other, so one pass with both value lists finds the command words; then the command's own lists must hold
# every flag seen.
GHCMDS=' auth browse codespace discussion gist issue org pr project release repo skill cache run workflow agent-task api attestation completion config copilot gpg-key label licenses preview ruleset search secret ssh-key status variable help version accessibility actions environment exit-codes formatting mintty reference telemetry '
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
[[ "$GHCMDS" == *" ${words[0]} "* ]] || refuse "gh-guard: '${words[0]}' không chạy được trên box (không phải tên lệnh gh đầy đủ; alias, extension và tên tắt đều bị chặn) — gõ lệnh gh đầy đủ."

if [ "${words[0]}" = pr ] && [ "${words[1]:-}" = merge ]; then
  hint='(trợ giúp: gh help pr merge)'
  { known "$PRB$PRV" && [ -z "$bad" ] && [ "${#words[@]}" -le 3 ]; } || refuse "gh-guard: không đọc chắc lệnh gh pr merge này (cờ lạ, thiếu giá trị hay thừa đối số); bị chặn — gõ lại đúng cú pháp gh. $hint"
  v=(pr view); [ -z "${words[2]:-}" ] || v+=("${words[2]}"); [ -z "${val[--repo]+x}" ] || v+=(-R "${val[--repo]}")
  out="$("$real" "${v[@]}" --json number,url,headRefOid,changedFiles -q '.number, .url, .headRefOid, .changedFiles' </dev/null 2>/dev/null)" \
    || refuse "gh-guard: không đọc được PR ${words[2]:-của nhánh này}; không merge (chặn khi không chắc) — báo fcoding. $hint"
  { read -r num; read -r url; read -r head; read -r cnt; } <<<"$out"
  { [[ "$url" =~ ^https://[^/]+/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+)$ ]] && [ "${BASH_REMATCH[2]}" = "$num" ] && base="${BASH_REMATCH[1]}" \
    && [[ "$head" =~ ^[0-9a-f]{40}$ ]] && [[ "$cnt" =~ ^[0-9]+$ ]]; } || refuse "gh-guard: không đọc rõ PR ${num:-?} (repo, head, số file); không merge — báo fcoding. $hint"
  no_secret "$base" && exec "$real" "$@"
  for f in "${fl[@]}"; do
    case "$f" in --auto|--disable-auto) refuse "gh-guard: PR #$num: auto-merge ở repo không có trong ~/.config/fcode/no-secret-repos bị chặn (box chỉ kiểm tra được lần merge chạy ngay); merge không --auto. $hint";; esac
  done
  if [ -n "${val[--match-head-commit]+x}" ] && [ "${val[--match-head-commit]}" != "$head" ]; then
    refuse "gh-guard: PR #$num: --match-head-commit ${val[--match-head-commit]} khác head đã kiểm tra $head; bị chặn. $hint"
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
  [ -z "$touches" ] || refuse "gh-guard: PR #$num sửa .github/ ở repo không có trong ~/.config/fcode/no-secret-repos (head $head); box không merge — gọi fcode-notify <dự án> merge-ready \"<một dòng>\" $url, chủ merge trên GitHub."
  # the call as given, pinned to the inspected head (before a closing --, where flags still count)
  fwd=("$@")
  if [ -z "${val[--match-head-commit]+x}" ]; then
    if [ "$dd" -lt 0 ]; then fwd+=(--match-head-commit "$head"); else fwd=("${@:1:$dd}" --match-head-commit "$head" "${@:$((dd + 1))}"); fi
  fi
  exec "$real" "${fwd[@]}"
elif [ "${words[0]}" = api ]; then
  { known "$APB$APV" && [ -z "$bad" ] && [ "${#words[@]}" -eq 2 ]; } || refuse "gh-guard: không đọc chắc lệnh gh api này (cờ lạ, thiếu giá trị hay thừa đối số); bị chặn — gõ lại đúng cú pháp gh."
  ep="${words[1]}"
  shopt -s nocasematch
  [[ "$ep" == *graphql* ]] && { shopt -u nocasematch; refuse "gh-guard: gh api graphql bị chặn trên box; dùng lệnh gh thường (gh pr …, gh issue …) — báo fcoding nếu thật cần."; }
  shopt -u nocasematch
  if [ -n "${val[--method]+x}" ]; then m="${val[--method]^^}"
  else m=GET; for f in "${fl[@]}"; do case "$f" in -f|--raw-field|-F|--field|--input) m=POST;; esac; done; fi
  [ "$m" = GET ] || refuse "gh-guard: gh api $m $ep bị chặn trên box (chỉ lệnh đọc GET đi qua); dùng lệnh gh tương ứng (gh pr / issue / release / workflow …) — báo fcoding nếu thật cần."
fi
exec "$real" "$@"
