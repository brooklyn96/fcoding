#!/usr/bin/env bash
# fcode-deploy (runs ON the coder box, installed as ~/.local/bin/fcode-deploy): drives the deploy gate on the VPS through the gate's operator
# key. That key can run only the gate's own verbs (no shell, no file read). The same verbs as the laptop's `fcode deploy`; never interactive,
# so an agent can drive it: `add` stops after the INV lines unless --yes is given.
#   fcode-deploy add <owner/repo> <name> <draft.json> [--yes]
#   fcode-deploy <name> status | recheck | pause | resume
#   fcode-deploy <name> deploy <sha1, 40 hex>
#   fcode-deploy <name> trust on i-understand-root | trust off
# Needs: ssh, node, gh (add only; GH_TOKEN from the box vault). The VPS host comes from FCODE_DEPLOY_HOST or the one-line file
# ~/.config/fcode/deploy-host; the operator key is ~/.ssh/fcode-operator (FCODE_DEPLOY_KEY overrides). No secret lives in this script.
# Each verb is sent as one remote command `<name> <verb> [args]`; the gate's lines (INV / GATE_RESULT / GATE_EXIT) are printed as they come
# and the exit code is the gate's. Exit codes of this script itself: 65 = request refused here (nothing was sent), 1 = tool error (config, gh, ssh).
set -u
export LC_ALL=C

die() { echo "lỗi: $2" >&2; exit "$1"; }

usage() {
  echo 'Cách dùng:'
  echo '  fcode-deploy add <chủ/repo> <tên> <draft.json> [--yes]   (không có --yes: chỉ kiểm tra và in các dòng INV, chưa đăng ký)'
  echo '  fcode-deploy <tên> status | recheck | pause | resume'
  echo '  fcode-deploy <tên> deploy <sha đủ 40 ký tự>'
  echo '  fcode-deploy <tên> trust on i-understand-root | trust off'
  echo '  <tên>: chữ thường, số, dấu -, bắt đầu bằng chữ thường, không kết thúc bằng dấu -, 2 đến 28 ký tự'
  exit "${1:-65}"
}

name_ok() { [[ $1 =~ ^[a-z][a-z0-9-]{0,26}[a-z0-9]$ ]]; }
repo_ok() { [[ $1 =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && ! [[ $1 =~ ^\.+/ || $1 =~ /\.+$ ]]; }

# the VPS host and the operator key; checked only when something is really sent
need_ssh() {
  HOST=${FCODE_DEPLOY_HOST:-}
  if [ -z "$HOST" ]; then
    local f=${XDG_CONFIG_HOME:-$HOME/.config}/fcode/deploy-host
    [ -r "$f" ] && IFS= read -r HOST <"$f"
    HOST=${HOST%$'\r'}
  fi
  [[ $HOST =~ ^[A-Za-z0-9][A-Za-z0-9._@-]{0,99}$ ]] \
    || die 1 'chưa có máy chủ VPS hợp lệ: đặt FCODE_DEPLOY_HOST hoặc ghi một dòng tên máy vào ~/.config/fcode/deploy-host (chỉ chữ, số, dấu . _ @ -).'
  KEY=${FCODE_DEPLOY_KEY:-$HOME/.ssh/fcode-operator}
  [ -r "$KEY" ] || die 1 "không thấy khoá ssh của cổng: $KEY"
}

# remote <draft file or ""> <command>: one gate command over ssh; the draft (if any) is the remote stdin
remote() {
  local rc
  if [ -n "$1" ]; then
    ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes "$HOST" "$2" <"$1"
  else
    ssh -n -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes "$HOST" "$2"
  fi
  rc=$?
  [ "$rc" -ne 255 ] || echo "lỗi: không nối được VPS bằng ssh $HOST (mã 255). Kiểm tra FCODE_DEPLOY_HOST và khoá $KEY." >&2
  return "$rc"
}

# reads the draft (<= 16 KiB, valid JSON, BOM dropped), writes the exact bytes to send to $2 and prints "<sha256>|<registry.repo>|<registry.name>"
DRAFT_JS='
const fs = require("fs"), c = require("crypto");
let b;
try { b = fs.readFileSync(process.argv[1]); } catch { console.log("read"); process.exit(1); }
if (b.length >= 3 && b[0] === 0xEF && b[1] === 0xBB && b[2] === 0xBF) b = b.subarray(3);
if (!b.length || b.length > 16384) { console.log("size"); process.exit(1); }
let j;
try { j = JSON.parse(b.toString("utf8")); } catch { console.log("json"); process.exit(1); }
fs.writeFileSync(process.argv[2], b, { mode: 0o600 });
const r = (j && j.registry) || {};
console.log([c.createHash("sha256").update(b).digest("hex"), typeof r.repo === "string" ? r.repo : "", typeof r.name === "string" ? r.name : ""].join("|"));'
# stdin: gh run list JSON -> number of runs
RUNS_JS='
let s = ""; process.stdin.on("data", (d) => s += d).on("end", () => {
  try { const j = JSON.parse(s); console.log(j === null ? 0 : Array.isArray(j) ? j.length : 1); } catch { process.exit(2); } });'
# stdin: gh repo deploy-key list JSON, argv[1] = our public key "<type> <base64>" -> none | ro | rw (gh 2.92 prints read_only, older readOnly: both accepted)
KEYS_JS='
let s = ""; process.stdin.on("data", (d) => s += d).on("end", () => {
  let j; try { j = JSON.parse(s); } catch { process.exit(2); }
  if (!Array.isArray(j)) process.exit(2);
  const m = j.filter((e) => e && typeof e.key === "string" && e.key.trim().split(/\s+/).slice(0, 2).join(" ") === process.argv[1]);
  console.log(!m.length ? "none" : m.every((e) => e.readOnly === true || e.read_only === true) ? "ro" : "rw"); });'

# no workflow run of the repo may be in flight (in_progress, queued). 0 = none, 65 = some, 1 = gh could not tell (then nothing is registered)
runs_idle() {
  local st o n
  for st in in_progress queued; do
    o=$(gh run list -R "$1" --status "$st" --json databaseId 2>&1) && n=$(printf '%s' "$o" | node -e "$RUNS_JS") || {
      echo "lỗi: gh không đọc được các lượt chạy Actions ($st) của $1 nên chưa xác nhận được là không còn lượt nào. Chưa đăng ký." >&2
      echo "  (chi tiết: ${o%%$'\n'*})" >&2
      return 1
    }
    if [ "$n" -gt 0 ]; then
      echo "lỗi: runs-in-flight: $1 còn $n lượt Actions ở trạng thái $st. Chờ chúng chạy xong (hoặc huỷ), rồi chạy lại. Chưa đăng ký." >&2
      return 65
    fi
  done
  return 0
}

cmd_add() {
  local yes=0 a pos=() repo name draft info sha drepo dname out rc pk l st o last
  for a in "$@"; do if [ "$a" = --yes ]; then yes=1; else pos+=("$a"); fi; done
  [ "${#pos[@]}" -eq 3 ] || usage
  repo=${pos[0]} name=${pos[1]} draft=${pos[2]}
  case $name in deal-sync | vps-scraper | all | admin | gate | gen | src | build | poll | report | slot | legacy) usage ;; esac
  repo_ok "$repo" && name_ok "$name" || usage
  command -v node >/dev/null || die 1 'không tìm thấy node.'
  T=$(mktemp -d) || die 1 'không tạo được thư mục tạm.'
  trap 'rm -rf "$T"' EXIT
  info=$(node -e "$DRAFT_JS" -- "$draft" "$T/draft.json") || case $info in
    read) die 65 "không đọc được file bản nháp: $draft" ;;
    size) die 65 'bản nháp phải có nội dung và tối đa 16 KiB' ;;
    *) die 65 'bản nháp không phải JSON hợp lệ' ;;
  esac
  IFS='|' read -r sha drepo dname <<<"$info"
  [ "$drepo" = "$repo" ] || die 65 "bản nháp ghi registry.repo = '$drepo' nhưng repo ở dòng lệnh là '$repo'. Hai repo phải giống nhau. Chưa làm gì."
  [ "$dname" = "$name" ] || die 65 "bản nháp ghi registry.name = '$dname' nhưng tên ở dòng lệnh là '$name'. Hai tên phải giống nhau. Chưa làm gì."
  command -v gh >/dev/null || die 1 'không tìm thấy gh (GitHub CLI) hoặc chưa có GH_TOKEN.'
  need_ssh
  runs_idle "$repo" || exit $?
  echo "Đăng ký $repo vào cổng deploy với tên '$name'..."

  # the deploy key: the gate makes (or reuses) /root/.ssh/<name>_deploy and the github-<name> alias, and prints the public key
  out=$(remote "" "$name prepare-key"); rc=$?
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$out"; die "$rc" "cổng không chuẩn bị được khoá deploy của '$name' (mã $rc)."; fi
  pk=
  while IFS= read -r l; do
    if [[ $l =~ ^([^[:space:]]+)[[:space:]]+(AAAA[^[:space:]]+) ]]; then pk="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"; break; fi
  done <<<"$out"
  [ -n "$pk" ] || { printf '%s\n' "$out"; die 1 "cổng không trả về khoá công khai của '$name'."; }
  o=$(gh repo deploy-key list -R "$repo" --json key,readOnly 2>&1) && st=$(printf '%s' "$o" | node -e "$KEYS_JS" "$pk") \
    || die 1 "gh không đọc được Deploy keys của $repo. ${o%%$'\n'*}"
  case $st in
    rw)
      echo "lỗi: khoá deploy của '$name' đã nằm trong Deploy keys của $repo nhưng CÓ quyền ghi (Allow write access). Cổng chỉ dùng khoá chỉ đọc nên không dùng lại." >&2
      echo "  Xoá khoá đó ở https://github.com/$repo/settings/keys, rồi chạy lại lệnh này (lệnh sẽ thêm lại khoá chỉ đọc). Khoá công khai: $pk" >&2
      exit 65 ;;
    none)
      printf '%s\n' "$pk" >"$T/key.pub"   # only the PUBLIC key ever reaches a file here
      o=$(gh repo deploy-key add "$T/key.pub" -R "$repo" --title "fcode deploy $name (read-only)" 2>&1) || {
        echo "lỗi: gh không thêm được khoá chỉ đọc vào $repo. ${o%%$'\n'*}" >&2
        echo "  Thêm tay ở https://github.com/$repo/settings/keys/new (KHÔNG tích Allow write access), khoá công khai: $pk" >&2
        exit 1
      }
      echo "[1] Đã thêm khoá chỉ đọc vào Deploy keys của $repo" ;;
    *) echo "[1] Khoá deploy của '$name' đã nằm trong Deploy keys của $repo (chỉ đọc), dùng lại" ;;
  esac

  echo '[2] Đọc hiện trạng trên VPS (chỉ đọc, chưa đổi gì):'
  out=$(remote "$T/draft.json" "$name inventory"); rc=$?
  printf '%s\n' "$out"
  last=$(printf '%s\n' "$out" | grep '^INV ' | tail -n 1)
  if [ "$rc" -ne 0 ] || [ "$last" != 'INV ok' ]; then
    echo "Cổng không xác nhận bản nháp (mã $rc; kết quả phải kết thúc bằng dòng 'INV ok'). Sửa theo các dòng INV ở trên rồi chạy lại. Chưa đăng ký." >&2
    exit $((rc != 0 ? rc : 65))
  fi
  echo "sha256 của bản nháp: $sha"
  if [ "$yes" -ne 1 ]; then
    echo 'Chưa đăng ký gì. Nếu các dòng INV ở trên ổn, chạy lại với --yes để đăng ký (cùng lệnh, thêm --yes).'
    exit 0
  fi

  # --yes: Actions may have started while the draft was being read, so check again right before register
  runs_idle "$repo" || exit $?
  remote "$T/draft.json" "$name register $sha"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo
    echo "Xong: '$name' đã đăng ký và đang tạm dừng. Việc tiếp theo, theo thứ tự:"
    echo "  fcode-deploy $name status"
    echo "  (nếu dòng INV unit ở trên có trusted_needed=yes, hoặc project là compose / script:  fcode-deploy $name trust on i-understand-root)"
    echo "  fcode-deploy $name deploy <sha của main>"
    echo "  fcode-deploy $name resume"
    exit 0
  fi
  if [ "$rc" -eq 70 ]; then
    echo
    echo 'Cổng cần người xử lý (needs_human). Trạng thái hiện tại:'
    remote "" "$name status"
    echo "Xử lý theo dòng BLOCKED ở trên, rồi chạy:  fcode-deploy $name recheck"
    exit 70
  fi
  echo "Đăng ký chưa xong (mã $rc). Xem thông báo ở trên." >&2
  exit "$rc"
}

cmd_trust_on() { # warn first, naming the repo and the real branch of the project (read from the gate's status)
  local s rc l tr= tb=
  need_ssh
  s=$(remote "" "$name status"); rc=$?
  while IFS= read -r l; do
    if [[ $l == PROJECT[[:space:]]* ]]; then
      [[ $l =~ (^|[[:space:]])repo=([^[:space:]]+) ]] && tr=${BASH_REMATCH[2]}
      [[ $l =~ (^|[[:space:]])branch=([^[:space:]]+) ]] && tb=${BASH_REMATCH[2]}
    fi
  done <<<"$s"
  if [ -z "$tr" ] || [ -z "$tb" ]; then
    echo "lỗi: không đọc được repo và nhánh của '$name' từ lệnh status (project đã đăng ký chưa?). Chưa bật chế độ tin cậy." >&2
    printf '%s\n' "$s"
    exit $((rc != 0 ? rc : 65))
  fi
  echo "Trusted mode: anyone who can merge to $tr $tb gets root on the VPS (compose controls the root docker daemon; script runs as root) and can read the gate's GitHub token, which can post statuses and issues on every brooklyn96 repository."
  remote "" "$name trust on i-understand-root"; exit $?
}

[ $# -gt 0 ] || usage
case $1 in -h | --help | help) usage 0 ;; add) shift; cmd_add "$@" ;; esac

name=$1 verb=${2:-}
name_ok "$name" || usage
shift 2 2>/dev/null || shift $#
case "$verb $*" in
  'status ' | 'recheck ' | 'pause ' | 'resume ' | 'trust off') ;;
  'trust on i-understand-root') cmd_trust_on ;;
  'deploy '*) [[ ${1:-} =~ ^[0-9a-f]{40}$ ]] && [ $# -eq 1 ] || usage ;;
  *) usage ;;
esac
need_ssh
remote "" "$name $verb${*:+ $*}"
exit $?
