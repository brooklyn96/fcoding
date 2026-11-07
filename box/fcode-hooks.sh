#!/bin/bash
# fcode-hooks (runs ON the coder box, installed as ~/.local/bin/fcode-hooks; install.sh runs it after each install): puts the CURRENT box
# pre-push hook into every project of the FCode config, so a newer hook reaches the projects fcode add made earlier. Idempotent.
# The hook text is not a copy: it is "fcode-add.sh --hook-text" of the installed script ($FCODE_APP/fcode-add.sh, FCODE_APP defaults to
# /data/home/fcoding; FCODE_ADD_SCRIPT overrides the script and FCODE_CFG the config, for tests).
# Same safety rules as fcode add's step 5: the project's .git is a real directory inside the project (no link), its hooks dir and pre-push are
# no links and live inside the project, and git uses that hooks dir (repo-local core.hooksPath; set when unset, never changed when it points elsewhere).
# A pre-push that is not a box hook (no "# Box guard:" line) is never replaced. Only hooks/pre-push and core.hooksPath are ever written.
# One line per project: HOOK_OK <name> (written), HOOK_EXISTS <name> (already current), HOOK_FAIL <name> <reason>.
# Exit: 0 all OK/EXISTS, 1 any HOOK_FAIL, 2 no hook text or unreadable config.
set -u
app="${FCODE_APP:-/data/home/fcoding}"
add="${FCODE_ADD_SCRIPT:-$app/fcode-add.sh}"
cfg="${FCODE_CFG:-/data/home/.fcoding/config.json}"
htmp="$(mktemp)" || exit 2
trap 'rm -f "$htmp"' EXIT
if ! bash "$add" --hook-text >"$htmp" 2>/dev/null || ! head -n 1 "$htmp" | grep -qx '#!/bin/sh'; then echo "HOOK_FAIL - no hook text ($add)"; exit 2; fi
# name<TAB>dir per project; a name or dir holding a tab or newline, or a dir that is not a string, comes out with an empty dir (HOOK_FAIL)
list="$(python3 - "$cfg" <<'PY'
import json, sys
for k, v in json.load(open(sys.argv[1], encoding="utf-8"))["projects"].items():
    bad = any(c in k for c in "\t\n")
    ok = isinstance(v, str) and not any(c in v for c in "\t\n")
    if not bad:
        print(f"{k}\t{v if ok else ''}")
PY
)" || { echo "HOOK_FAIL - config ($cfg)"; exit 2; }
rc=0
fail() { echo "HOOK_FAIL $name $1"; rc=1; }
while IFS=$'\t' read -r name dir; do
  [ -n "$name" ] || continue
  if [ -z "$dir" ] || [ -L "$dir" ] || [ ! -d "$dir" ]; then fail dir; continue; fi
  rdir="$(readlink -f "$dir")"; gdir="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)"; hooks="$gdir/hooks"
  if [ -z "$gdir" ] || [ "$(readlink -f "$gdir")" != "$rdir/.git" ] || [ -L "$dir/.git" ] || [ -L "$hooks" ] || [ -L "$hooks/pre-push" ]; then fail unsafe; continue; fi
  if [ -e "$hooks" ]; then case "$(readlink -f "$hooks")" in "$rdir"/*) ;; *) fail unsafe; continue;; esac; fi
  hp="$(git -C "$dir" config --local --get core.hooksPath 2>/dev/null)"
  if [ -n "$hp" ] && [ "$(readlink -f "$hp")" != "$(readlink -f "$hooks")" ]; then fail hookspath; continue; fi
  if [ -e "$hooks/pre-push" ] && ! grep -q '^# Box guard:' "$hooks/pre-push" 2>/dev/null; then fail foreign; continue; fi
  if cmp -s "$htmp" "$hooks/pre-push" 2>/dev/null; then st=HOOK_EXISTS
  elif mkdir -p "$hooks" && install -m 755 "$htmp" "$hooks/pre-push"; then st=HOOK_OK
  else fail install; continue; fi
  chmod 755 "$hooks/pre-push" 2>/dev/null || { fail install; continue; }
  if [ -z "$hp" ] && ! git -C "$dir" config --local core.hooksPath "$hooks"; then fail hookspath; continue; fi
  # git really resolves pre-push to this file (a global or system core.hooksPath cannot win over the repo-local one)
  if [ "$(readlink -f "$(git -C "$dir" rev-parse --git-path hooks 2>/dev/null)")" != "$(readlink -f "$hooks")" ]; then fail verify; continue; fi
  echo "$st $name"
done <<<"$list"
exit "$rc"
