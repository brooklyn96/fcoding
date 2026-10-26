#!/bin/bash
# fcode add (chay tren box): them 1 project GitHub vao /data/workspace va vao cau hinh FCode.
# Tham so $1=<owner/repo>, $2=<ten> do fcode.ps1 dat bang "set --" ngay truoc script nay (khong qua dong lenh).
# Thu muc /data/workspace/<ten> da ton tai (thu muc, file, lien ket, git hay khong) KHONG BAO GIO duoc nhan lai: tu choi truoc moi thay doi
# (R DIR_EXISTS exists / R DIR_UNSAFE unsafe, thoat 11). Ngoai le duy nhat: project da ghi trong cau hinh voi dung thu muc nay va dung origin
# -> in "R CFG_EXISTS" va thoat 0, khong dung gi them (khong ghi thu, khong doi cau hinh). Moi buoc con lai chay tren ban clone CUA lan chay nay.
# Duong 1 (token): neu gh cua box (GH_TOKEN) thay repo va API bao quyen push (chi la goi y: do la vai tro cua nguoi dung, khong phai pham vi
#   cua token) thi clone qua HTTPS, gh la credential helper (chuoi helper duoc dat lai, chi dat trong cau hinh rieng cua repo; token khong bao gio
#   duoc in, luu hay ghi vao URL). In "R TOKEN_OK". Viec GHI THAT (buoc 6) moi quyet dinh: bi tu choi (403...) thi in "R TOKEN_FALLBACK", xoa ban
#   clone cua minh va chay lai bang duong 2.
# Duong 2 (du phong): moi repo co 1 deploy key SSH rieng (cung kieu 3 project san co): ~/.ssh/id_ed25519_<ten> + alias "github-<ten>".
#   Dung khi token khong thay repo, khong co quyen push, clone/ghi bang token bi tu choi, hoac thieu gh. FCODE_NO_TOKEN=1: bo qua duong 1.
# Chi in ASCII: dong "R <MA> [chi tiet]" de fcode.ps1 dich ra tieng Viet.
# Khong bao gio in khoa rieng; chi in khoa cong khai (PUBKEY). Khong dung token/API de them khoa.
# Thu muc dich duoc DAT CHO bang 1 lenh mkdir nguyen tu ngay sau khi biet no chua co (owned=1, tin hieu bi hoan lai qua lenh do): thu muc nay
# (ca khi clone hong hay bi tat giua chung) bi xoa neu co loi truoc khi project duoc ghi vao cau hinh (va chua co ten nay -> thu muc nay trong cau hinh).
# Vong doi: moi tien trinh con hoac duoc cho den khi xong truoc khi script di tiep (trap chi chay sau khi lenh dang chay xong), hoac tu bi gioi han:
# process substitution o url_rewrite_check la 1 lenh git config cuc bo doc den EOF; "timeout 20 gh ..." chay rieng voi gioi han rieng.
# Han chot cua job la timeout(1) (server.mjs): TERM roi KILL cho ca nhom tien trinh; TERM tu close() cua server duoc timeout chuyen tiep va cung
# khoi dong KILL do. KHONG them &, nohup, setsid, disown, coproc, hay process substitution khong doc den EOF.
# Ma thoat: 0 xong, 30 xong nhung co canh bao, 40 can dan khoa vao GitHub, 41 khoa chua co quyen ghi,
# 42 GitHub chan tao nhanh box/*, 43 mang loi, 44 repo da luu tru, 24 khong cai/kiem chung duoc hook, 25 khong dat duoc credential helper,
# 26 cau hinh git (url.*.insteadOf / pushurl) doi huong URL, 2 tham so sai, 11 thu muc da co / khong an toan, 21/22 cau hinh xung dot / hong,
# 23 ten khoa/alias da dung cho repo khac, 20 khong tao duoc khoa, 12 clone loi.
set -u
arg1="${1:-}"; arg2="${2:-}"
repo="${1:-}"; name="${2:-}"
[ -n "$repo" ] && [ -n "$name" ] || { echo "R USAGE"; exit 2; }
repo="${repo%.git}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$name" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] && [ "$name" != home ] \
  && ! [[ "${repo%%/*}" =~ ^\.+$ ]] && ! [[ "${repo##*/}" =~ ^\.+$ ]] || { echo "R BAD_ARGS"; exit 2; }
# vi tri (de thu tren thu muc tam: FCODE_SSH_DIR / FCODE_WORKSPACE / FCODE_CFG; that thi de mac dinh)
sshdir="${FCODE_SSH_DIR:-$HOME/.ssh}"
ws="${FCODE_WORKSPACE:-/data/workspace}"
dir="$ws/$name"
cfg="${FCODE_CFG:-/data/home/.fcoding/config.json}"
key="$sshdir/id_ed25519_$name"
alias_="github-$name"
url="git@$alias_:$repo.git"
export GIT_SSH_COMMAND="ssh -F $sshdir/config -o BatchMode=yes -o ConnectTimeout=15"
export GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1   # khong bao gio hoi mat khau
GHELPER='!gh auth git-credential'
via=key
GH_ED25519='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'   # khoa may chu github.com (chinh thuc)
fail=0; owned=0; registered=0; prereg=0
# 1 dong ket qua; neu nguoi doc (server) da dong ong thi lan chay van tiep tuc (SIGPIPE chi bi bo qua trong dong nay)
say() { ( trap '' PIPE; echo "R $*" ) 2>/dev/null; return 0; }
clean() { sed -E 's/(gh[a-z]_|github_pat_)[A-Za-z0-9_]+/<token>/g' | head -n 1 | cut -c1-200; }
# cau hinh co ghi <ten> -> <thu muc nay> khong? (0 = co)
cfg_maps() {
  python3 - "$cfg" "$name" "$dir" <<'PY'
import json, sys
try:
    p = json.load(open(sys.argv[1], encoding='utf-8')).get('projects') or {}
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(p, dict) and p.get(sys.argv[2]) == sys.argv[3] else 1)
PY
}
err="$(mktemp)"
# don dep khi thoat (ca khi bi tat bang TERM/INT/HUP): file tam, va ban clone do lan chay nay tao ra neu project CHUA duoc ghi vao cau hinh.
# Truoc khi xoa con xem lai cau hinh: neu da ghi <ten> -> thu muc nay (vd. python da doi file roi moi bi loi/bi tat) thi KHONG xoa.
cleanup() {
  if [ "$owned" = 1 ] && [ "$registered" != 1 ]; then
    if [ "$prereg" = 1 ] || ! cfg_maps; then rm -rf -- "$dir"; fi
  fi
  rm -f "$err"; return 0
}
trap cleanup EXIT
trap 'cleanup; exit 143' TERM INT HUP

# 0a. thu muc dich khong duoc la lien ket, va thu muc that + git dir that phai nam trong workspace that (kiem tra truoc moi thay doi)
if [ -L "$dir" ]; then say DIR_UNSAFE unsafe; exit 11; fi
if [ -e "$dir" ]; then
  rws="$(readlink -f "$ws")"; rdir="$(readlink -f "$dir")"
  if [ -z "$rws" ] || [ "$rdir" != "$rws/$name" ] || [ -L "$dir/.git" ]; then say DIR_UNSAFE unsafe; exit 11; fi
  if [ -d "$dir/.git" ]; then
    gdir="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)"
    if [ -z "$gdir" ] || [ "$(readlink -f "$gdir")" != "$rdir/.git" ]; then say DIR_UNSAFE unsafe; exit 11; fi
  fi
fi

# hook chan push thang len main/master (noi dung chuan cua box)
hook_text() {
  cat <<'HOOK'
#!/bin/sh
# Box guard: never push directly to main/master. Work on box/<topic>, then merge through a PR.
while read local_ref local_sha remote_ref remote_sha; do
  case "$remote_ref" in
    refs/heads/main|refs/heads/master) echo "pre-push: pushing to ${remote_ref#refs/heads/} is blocked on this box; push a box/<topic> branch and merge via PR" >&2; exit 1;;
  esac
done
exit 0
HOOK
}

# alias cua rieng repo nay? 0 = co (co dong "# fcode add: <repo>" ngay tren), 1 = chua co, 2 = co nhung cua nguoi khac
alias_owner() {
  [ -f "$sshdir/config" ] || return 1
  awk -v h="Host $alias_" -v m="# fcode add: $want" 'tolower(prev)==m && $0==h {ok=1} $0==h {seen=1} {prev=$0} END {exit (ok ? 0 : (seen ? 2 : 1))}' "$sshdir/config"
}

# phan loai loi tu noi dung $err (chi dua vao chu cua ssh / may chu GitHub bang tieng Anh, khong phu thuoc ngon ngu cua git)
NETRE='connect to host|Connection (timed out|refused|reset|closed)|Could not resolve|hung up|Network is unreachable|Operation timed out|kex_exchange|Broken pipe|Temporary failure|Failed to connect|Couldn.t connect to server|SSL_connect|Recv failure|Empty reply from server|Error in the pull function|RPC failed'   # ssh va curl (https)
classify_fail() { # dat $kind: net | archived | ro | other
  if grep -qiE "$NETRE" "$err"; then kind=net
  elif grep -qi 'archived' "$err"; then kind=archived
  elif grep -qiE 'marked as read only|Permission to .* denied|Write access to repository not granted|returned error: 40[13]|Authentication failed|could not read (Username|Password)|terminal prompts disabled' "$err"; then kind=ro   # ssh va https (token)
  else kind=other; fi
}

# git cho moi lenh MANG: duong token dat lai chuoi credential helper (gia tri rong xoa helper ke thua tu system/global) roi chi dung gh
gt() { if [ "$via" = token ]; then git -c credential.helper= -c "credential.helper=$GHELPER" "$@"; else git "$@"; fi; }

# cau hinh git (system/global/repo, khong tinh -c / bien moi truong cua chinh lan chay nay) khong duoc doi huong "$url": url.*.insteadOf /
# pushInsteadOf co tien to khop "$url", hay remote.origin.pushurl. $1 = thu muc clone (bo trong: chi system/global). 0 = khong bi doi huong.
url_rewrite_check() {
  local g=(git) scope kv key val bad=0
  [ -n "${1:-}" ] && g+=(-C "$1")
  while IFS=$'\t' read -r scope kv; do
    [ "$scope" = command ] && continue
    key="${kv%% *}"; val="${kv#* }"
    case "$key" in
      url.*.insteadof|url.*.pushinsteadof) [ -n "$val" ] && case "$url" in "$val"*) bad=1;; esac;;
      remote.origin.pushurl) bad=1;;
    esac
  done < <("${g[@]}" config --show-scope --get-regexp '^(url\..*\.(insteadof|pushinsteadof)|remote\.origin\.pushurl)$' 2>/dev/null)
  [ "$bad" -eq 0 ]
}

# 1 commit rong (cay rong) do lan chay nay tao ra; in sha. Dung cho ca buoc ghi thu va buoc kiem chung hook.
empty_commit() { # $1 = thu muc clone, $2 = thong diep
  local tree; tree="$(git -C "$1" hash-object -t tree -w /dev/null)" || return 1
  GIT_AUTHOR_NAME=fcode GIT_AUTHOR_EMAIL=fcode@box GIT_COMMITTER_NAME=fcode GIT_COMMITTER_EMAIL=fcode@box git -C "$1" commit-tree "$tree" -m "$2" </dev/null
}

# git THAT SU dung hook cua box: push vao 1 remote cuc bo tam (khong dung GitHub, khong ghi gi): main phai bi hook chan, box/x thi khong.
# Chay file hook truc tiep khong tinh. 0 = dung.
hook_verify() {
  local t c a b o
  t="$(mktemp -d)" || return 1
  git init -q --bare "$t/r.git" >/dev/null 2>&1 || { rm -rf "$t"; return 1; }
  c="$(empty_commit "$dir" 'fcode add hook check' 2>/dev/null)" || { rm -rf "$t"; return 1; }
  o="$(git -C "$dir" push --dry-run "$t/r.git" "$c:refs/heads/main" 2>&1 </dev/null)"; a=$?
  git -C "$dir" push --dry-run "$t/r.git" "$c:refs/heads/box/x" >/dev/null 2>&1 </dev/null; b=$?
  rm -rf "$t"
  [ "$a" -ne 0 ] && [ "$b" -eq 0 ] && printf '%s' "$o" | grep -q 'blocked on this box'
}

# ghi duoc repo: CHINH lan chay nay day THAT 1 nhanh thu duy nhat (box/fcode-add-check-<ten>-<epoch>-<pid>-<so ngau nhien>) tu commit cay rong cua no
# TOI DUNG "$url" (khong qua 'origin': khong remote.origin.pushurl nao co the doi cho den), roi xoa dung commit do (--force-with-lease).
# Khong nhanh co san nao la bang chung. Tao that bai -> chua chung minh duoc (1, noi dung loi o $err). Tao duoc roi thi DA ghi duoc: xoa that bai
# (bat ky ly do nao) chi la CLEANUP_FAIL <nhanh> (ADDED_WARN); mot TERM giua luc tao va xoa cung de lai nhanh (ten duy nhat, chap nhan).
write_check() { # $1 = thu muc clone; 0 = ghi duoc; 1 = loi
  local c ref e2 safe; safe="$(printf '%s' "$name" | tr -c 'a-z0-9-' '-')"
  # ten nhanh khong bao gio trung: ten-epoch-pid-ngau nhien (lan chay du phong exec giu nguyen pid), va chi tao khi nhanh CHUA co (lease rong)
  ref="refs/heads/box/fcode-add-check-$safe-$(date +%s)-$$-$RANDOM"
  c="$(empty_commit "$1" 'fcode add write check' 2>"$err")" || return 1
  gt -C "$1" push -q --force-with-lease="$ref:" "$url" "$c:$ref" >/dev/null 2>"$err" </dev/null || return 1
  e2="$(mktemp)"
  if ! gt -C "$1" push -q --force-with-lease="$ref:$c" "$url" ":$ref" >/dev/null 2>"$e2" </dev/null; then
    sleep 2
    gt -C "$1" push -q --force-with-lease="$ref:$c" "$url" ":$ref" >/dev/null 2>"$e2" </dev/null || { say CLEANUP_FAIL "$ref"; fail=1; }
  fi
  rm -f "$e2"; return 0
}
# 0. hai lan fcode add cung ten khong chay song song
mkdir -p "$sshdir"; chmod 700 "$sshdir"; exec 8>>"$sshdir/.fcode-add-$name.lock"; flock 8

# 1. kiem tra truoc (chua tao gi): cau hinh, thu muc, khoa/alias co phai cua repo khac khong
want="$(printf '%s' "$repo" | tr 'A-Z' 'a-z')"
python3 - "$cfg" "$name" "$dir" <<'PY'
import json, os, sys
cfg, name, d = sys.argv[1:4]
def out(s):
    try: os.write(1, (s + '\n').encode())
    except OSError: pass
try:
    c = json.load(open(cfg, encoding='utf-8'))
    if not isinstance(c, dict): raise ValueError('config is not an object')
    p = c.get('projects')
    if p is None: p = {}
    if not isinstance(p, dict): raise ValueError('projects is not an object')
except (OSError, ValueError) as e:
    out('R CFG_BROKEN ' + type(e).__name__); sys.exit(22)
if name in p and p[name] != d:
    out('R CFG_CONFLICT ' + str(p[name])[:100]); sys.exit(21)
PY
rc=$?; [ "$rc" -eq 0 ] || exit "$rc"
if cfg_maps; then prereg=1; fi
if [ -e "$dir" ]; then
  # chi 1 ngoai le: project da ghi (dung thu muc nay) voi dung origin -> chay lai la thanh cong, khong dung gi them
  have="$(git -C "$dir" config --get remote.origin.url 2>/dev/null | tr 'A-Z' 'a-z' | sed -E 's#^(https://github\.com/|git@[^:]*:)##; s#\.git$##')"
  if [ "$prereg" = 1 ] && [ -d "$dir/.git" ] && [ "$have" = "$want" ]; then say CFG_EXISTS; exit 0; fi
  say DIR_EXISTS exists; exit 11
fi
# 1a. DAT CHO thu muc dich bang 1 lenh mkdir nguyen tu (khong -p: that bai neu da co): tu luc mkdir thanh cong thu muc la CUA lan chay nay (owned=1),
# va cleanup / fallback xoa no o moi duong thoat truoc khi project duoc ghi (clone hong, bi tat giua chung, loi hook...). Tin hieu TERM/INT/HUP
# bi hoan lai qua mkdir -> owned=1 (bash chi chay trap sau khi lenh dang chay xong) roi xu ly ngay sau do: khong bao gio de mot thu muc moi tao
# ma khong ai so huu. Tien trinh con mkdir chay voi TERM/INT/HUP bi BO QUA (SIG_IGN song sot qua exec; chi trong tien trinh con): mot tin hieu
# gui cho ca nhom khong giet duoc mkdir giua luc mkdir(2) da xong va luc ta biet ket qua. Thu muc cha: mkdir -p "$ws" rieng (khong thuoc ten nay).
sig=
trap 'sig=1' TERM INT HUP
mkdir -p "$ws" 2>/dev/null
if ! ( trap '' TERM INT HUP; exec mkdir "$dir" ) 2>"$err"; then
  trap 'cleanup; exit 143' TERM INT HUP
  [ -z "$sig" ] || exit 143                                    # co tin hieu trong luc do: dung, khong dung vao thu muc (owned=0)
  if [ -e "$dir" ] || [ -L "$dir" ]; then say DIR_EXISTS exists; exit 11; fi    # ai do vua tao ra (ca lien ket treo) cung luc: khong dung vao
  say CLONE_FAIL "$(clean <"$err")"; exit 12
fi
owned=1
trap 'cleanup; exit 143' TERM INT HUP
[ -z "$sig" ] || { cleanup; exit 143; }
# khoa/alias cua ten nay co phai cua repo khac khong (chi doc; truoc ca duong token, de mot lan chay du phong khong de lai ban clone mo coi)
alias_owner; ao=$?
if [ "$ao" -eq 2 ]; then say NAME_USED; exit 23; fi
if [ "$ao" -eq 1 ] && [ -e "$key" ] && [ "$(awk '{print tolower($3)}' "$key.pub" 2>/dev/null)" != "fcode-$want" ]; then say NAME_USED; exit 23; fi
# 1b. duong token: gh cua box co quyen push vao repo nay? (khong -> duong khoa SSH ben duoi).
# Chi doc "true"/"false" tu API; stderr bo di; token khong di qua dong lenh, URL hay file nao.
if [ -z "${FCODE_NO_TOKEN:-}" ] && command -v gh >/dev/null 2>&1 \
   && [ "$(timeout 20 gh api "repos/$repo" --jq .permissions.push </dev/null 2>/dev/null)" = true ]; then
  via=token; url="https://github.com/$repo.git"
fi
# cau hinh git chung khong duoc doi huong URL nay (truoc moi lenh mang, truoc ca khi tao khoa)
if ! url_rewrite_check; then
  # tuyen https bi doi huong -> chay NGAY bang duong khoa (khong in TOKEN_OK, khong TOKEN_FALLBACK, khong exec lai); URL khoa cung duoc kiem tra
  if [ "$via" = token ]; then via=key; url="git@$alias_:$repo.git"; url_rewrite_check || { say URL_REWRITE rewrite; exit 26; }
  else say URL_REWRITE rewrite; exit 26; fi
fi
if [ "$via" = token ]; then
  say TOKEN_OK; say READ_OK
else   # ---- duong khoa SSH (cho den het buoc 3) ----

# 2. khoa SSH rieng + alias + ghim khoa may chu github.com (khoa thu muc ~/.ssh: cac lan chay khac ten cung ghi config nay)
mkdir -p "$sshdir"; chmod 700 "$sshdir"
exec 9<"$sshdir"; flock 9
if [ -s "$key" ]; then say KEY_EXISTS
else
  rm -f "$key" "$key.pub"
  ssh-keygen -q -t ed25519 -N '' -C "fcode-$repo" -f "$key" </dev/null >/dev/null 2>&1 || { say KEY_FAIL; exit 20; }
  chmod 600 "$key"; say KEY_NEW
fi
# khoa cong khai luon suy ra tu khoa rieng (khong tin file .pub cu)
pubk="$(ssh-keygen -y -f "$key" </dev/null 2>/dev/null | cut -d' ' -f1,2)"; [ -n "$pubk" ] || { say KEY_FAIL; exit 20; }
pub="$pubk fcode-$repo"
printf '%s\n' "$pub" >"$key.pub"; chmod 644 "$key.pub"
touch "$sshdir/known_hosts"; chmod 644 "$sshdir/known_hosts"
grep -qF "$GH_ED25519" "$sshdir/known_hosts" || printf 'github.com %s\n' "$GH_ED25519" >>"$sshdir/known_hosts"
if [ "$ao" -eq 0 ]; then say ALIAS_EXISTS
else
  ctmp="$(mktemp "$sshdir/.config.XXXXXX")"
  { [ -f "$sshdir/config" ] && cat "$sshdir/config"
    printf '\n# fcode add: %s\nHost %s\n  HostName github.com\n  User git\n  IdentityFile %s\n  IdentitiesOnly yes\n  StrictHostKeyChecking yes\n  UserKnownHostsFile %s\n' "$repo" "$alias_" "$key" "$sshdir/known_hosts"
  } >"$ctmp" && chmod 600 "$ctmp" && mv -f "$ctmp" "$sshdir/config" || { rm -f "$ctmp"; say ALIAS_FAIL; exit 21; }
  say ALIAS_ADDED
fi
flock -u 9

# 3. doc duoc repo qua khoa nay? (khong duoc -> nguoi dung dan khoa cong khai vao GitHub, roi chay lai)
if ! git ls-remote "$url" >/dev/null 2>"$err" </dev/null; then
  say SSH_DETAIL "$(clean <"$err")"; classify_fail
  if [ "$kind" = net ]; then say NET_FAIL; exit 43; fi
  say PUBKEY "$pub"; say NEED_KEY; exit 40
fi
say READ_OK
fi   # ---- het duong khoa SSH ----

# duong token khong qua duoc (clone/ghi bi tu choi: vd. token thieu quyen Contents): lam lai tu dau bang duong khoa SSH.
# Thu muc la cua lan chay nay (owned; thu muc co san da bi tu choi o tren): xoa no, lan chay khoa se dat cho va clone lai.
# Nha khoa thu muc truoc (cung file khoa, mo moi se doi mai) va xoa file tam (trap EXIT khong chay khi exec).
fallback() {
  say TOKEN_FALLBACK
  if [ "$owned" = 1 ]; then rm -rf -- "$dir"; owned=0; fi
  rm -f "$err"; exec 8>&-; FCODE_NO_TOKEN=1 exec bash "$0" "$arg1" "$arg2"
}

# 4. clone vao thu muc da dat cho o 1a (rong, cua lan chay nay). Duong token: gh la credential helper duy nhat (gt), roi ghi vao cau hinh rieng cua repo.
gt clone -q "$url" "$dir" >/dev/null 2>"$err" </dev/null || {
  classify_fail; if [ "$kind" = net ]; then say SSH_DETAIL "$(clean <"$err")"; say NET_FAIL; exit 43; fi
  [ "$via" = token ] && fallback
  say CLONE_FAIL "$(clean <"$err")"; exit 12
}
say CLONED
# ban clone phai khong doi huong URL (pushurl / insteadOf trong cau hinh cua no) va khong lech khoi workspace
if ! url_rewrite_check "$dir"; then say URL_REWRITE rewrite; exit 26; fi
if [ "$via" = token ]; then
  # chuoi helper cua repo: truoc het 1 gia tri rong (xoa helper system/global), roi gh; ghi loi thi that bai
  git -C "$dir" config --local --unset-all credential.helper 2>/dev/null
  git -C "$dir" config --local --add credential.helper '' && git -C "$dir" config --local --add credential.helper "$GHELPER" || { say CRED_FAIL config; exit 25; }
fi

# 5. hook chan push len main/master. Git phai THAT SU dung hook nay: core.hooksPath (chi cua repo nay) tro vao thu muc hooks cua chinh no, nen
# core.hooksPath ke thua tu global/system khong vo hieu hoa duoc (hook global cua box khong chay trong ban clone nay); roi kiem chung bang push
# that (hook_verify). Thu muc hooks (hay pre-push) la lien ket / nam ngoai ban clone thi tu choi TRUOC khi tao/ghi/chmod. Loi o day: KHONG them project.
rdir="$(readlink -f "$dir")"; gdir="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)"; hooks="$gdir/hooks"
if [ -z "$gdir" ] || [ "$(readlink -f "$gdir")" != "$rdir/.git" ] || [ -L "$dir/.git" ] || [ -L "$hooks" ] || [ -L "$hooks/pre-push" ]; then say HOOK_FAIL install; exit 24; fi
if [ -e "$hooks" ]; then case "$(readlink -f "$hooks")" in "$rdir"/*) ;; *) say HOOK_FAIL install; exit 24;; esac; fi
htmp="$(mktemp)"; hook_text >"$htmp"
hk=1
if mkdir -p "$hooks"; then
  if cmp -s "$htmp" "$hooks/pre-push" 2>/dev/null; then hk=0; say HOOK_EXISTS
  elif install -m 755 "$htmp" "$hooks/pre-push"; then hk=0; say HOOK_OK; fi
fi
rm -f "$htmp"
if [ "$hk" -eq 0 ]; then chmod 755 "$hooks/pre-push" && git -C "$dir" config --local core.hooksPath "$hooks" || hk=1; fi
if [ "$hk" -ne 0 ]; then say HOOK_FAIL install; exit 24; fi
if ! hook_verify; then say HOOK_FAIL verify; exit 24; fi

# 6. ghi duoc repo?
if ! write_check "$dir"; then
  classify_fail
  [ "$via" = token ] && [ "$kind" = ro ] && fallback   # token reads but may not write: the deploy key decides
  say SSH_DETAIL "$(clean <"$err")"
  case "$kind" in
    net) say NET_FAIL; exit 43;;
    archived) say REPO_ARCHIVED; exit 44;;
    ro) say PUBKEY "$pub"; say NEED_WRITE; exit 41;;
  esac
  say WRITE_BLOCKED; exit 42
fi
say WRITE_OK

# 7. them vao config FCode (chi them 1 khoa trong "projects"; khoa thu muc; sao luu truoc; ghi roi fsync file, doi ten, fsync thu muc; 0600).
# Buoc nay KHONG bi TERM/INT/HUP cat ngang (se mat tin hieu): xong roi moi dat lai trap. Python ghi qua os.write va bo qua ong da dong; tu luc
# os.replace xong thi project da duoc ghi: moi loi sau do (fsync thu muc...) chi la canh bao (thoat 3), khong bao gio la that bai.
trap '' TERM INT HUP
python3 - "$cfg" "$name" "$dir" <<'PY'
import fcntl, json, os, sys, tempfile, time
cfg, name, d = sys.argv[1:4]
cdir = os.path.dirname(cfg)
def out(s):
    try: os.write(1, (s + '\n').encode())
    except OSError: pass
def broken(why):
    out('R CFG_BROKEN ' + str(why)[:80]); sys.exit(22)
try:
    lock = os.open(cdir, os.O_RDONLY)
    fcntl.flock(lock, fcntl.LOCK_EX)      # hai lan fcode add cung luc phai doi nhau
    rawb = open(cfg, 'rb').read()
    raw = rawb.decode('utf-8')
    c = json.loads(raw)
    if not isinstance(c, dict): raise ValueError('config is not an object')
    p = c.get('projects')
    if p is None: p = c['projects'] = {}
    if not isinstance(p, dict): raise ValueError('projects is not an object')
except (OSError, ValueError) as e:
    broken(type(e).__name__)
if name in p:
    if p[name] == d:
        out('R CFG_EXISTS'); sys.exit(0)
    out('R CFG_CONFLICT ' + str(p[name])[:100]); sys.exit(21)
tmp = None
try:
    bak = '%s.bak-%s-%d' % (cfg, time.strftime('%Y%m%d-%H%M%S'), os.getpid())
    bfd = os.open(bak, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(bfd, 'wb') as b:
        b.write(rawb); b.flush(); os.fsync(b.fileno())            # ban sao luu xuong dia truoc khi doi file chinh
    p[name] = d
    fd, tmp = tempfile.mkstemp(dir=cdir, prefix='.config.json.', suffix='.tmp')   # 0600, ten khong trung
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write(json.dumps(c, indent=2, ensure_ascii=False) if '\n' in raw.strip() else json.dumps(c, ensure_ascii=False, separators=(',', ':')))
        if raw.endswith('\n'): f.write('\n')
        f.flush(); os.fsync(f.fileno())                            # file moi xuong dia truoc khi rename
    os.replace(tmp, cfg); tmp = None
except OSError as e:
    if tmp:
        try: os.unlink(tmp)
        except OSError: pass
    broken(type(e).__name__)
out('R CFG_ADDED')                                                  # tu day project DA duoc ghi
try:
    os.fsync(lock)                                                  # roi fsync thu muc (rename va ban sao luu)
except OSError:
    out('R CFG_WARN fsync'); sys.exit(3)
PY
rc=$?
trap 'cleanup; exit 143' TERM INT HUP
case "$rc" in
  0) registered=1;;
  3) registered=1; fail=1;;   # da ghi, nhung fsync thu muc loi: canh bao (xong, thoat 30)
  *) exit "$rc";;
esac

# 8. kiem tra
branch="$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null)"
defb="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"; defb="${defb#origin/}"
if ! git -C "$dir" rev-parse -q --verify HEAD >/dev/null 2>&1; then say V_EMPTY_REPO
elif [ -n "$branch" ] && [ "$branch" = "$defb" ]; then say V_BRANCH_OK "$branch"; else say V_BRANCH_BAD "${branch:-none}/${defb:-?}"; fail=1; fi
if timeout 20 gh pr list -R "$repo" --limit 1 >/dev/null 2>&1 </dev/null; then say V_PR_OK; else say V_PR_BAD; fail=1; fi
# hook: kiem chung lai bang push that vao remote cuc bo tam (buoc 5 da kiem chung truoc khi them project)
if hook_verify; then say V_HOOK_OK; else say V_HOOK_BAD; fail=1; fi
# cau hinh FCode hop le + server dang chay khong bao loi nap lai
if python3 - "$cfg" "$name" "$dir" <<'PY'
import json, os, sys
cfg, name, d = sys.argv[1:4]
c = json.load(open(cfg, encoding='utf-8'))
v = c.get('projects', {}).get(name)
sys.exit(0 if v == d and os.path.isabs(v) and os.path.isdir(v) and oct(os.stat(cfg).st_mode & 0o777) == '0o600' else 1)
PY
then
  cport="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('port',''))" "$cfg" 2>/dev/null)"
  [ -n "$cport" ] && curl -s -o /dev/null -m 5 "http://127.0.0.1:$cport/api/overview" </dev/null   # keo server nap lai config (401 la binh thuong)
  sleep 1
  bad="$(journalctl --user -u fcoding --since '-2min' --no-pager 2>/dev/null | grep -c 'config reload failed')"
  if [ "${bad:-0}" -eq 0 ]; then say V_SERVER_OK; else say V_SERVER_BAD; fail=1; fi
else
  say V_CFG_BAD; fail=1
fi
# quy tac deploy trong repo?
if grep -qis 'deploy' "$dir/CLAUDE.md" "$dir/AGENTS.md" 2>/dev/null; then say RULES_YES; else say RULES_NO; fi
exit $((fail * 30))
