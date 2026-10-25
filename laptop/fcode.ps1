# fcode: vao phien tmux tren box instabox "coder" (1 lan ssh). Xem fcode.sh.
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$arg = if ($Rest -and $Rest.Count -gt 0) { $Rest[0] } else { '' }
# Cau hinh rieng tung may: %USERPROFILE%\.fcode\config.json (install.ps1 tao). Thieu khoa thi dung mac dinh.
# Khoa: instabox (duong dan instabox.exe), box (ten box), syncRepos (danh sach thu muc cho fcode sync), ipaRepo, ipaTag.
$ConfigFile = Join-Path $env:USERPROFILE '.fcode\config.json'
$Cfg = $null; $CfgBroken = $null
if (Test-Path -LiteralPath $ConfigFile) {
  try { $Cfg = [IO.File]::ReadAllText($ConfigFile) | ConvertFrom-Json }
  catch { $CfgBroken = $_.Exception.Message; $Cfg = $null }
}
function Get-Cfg([string]$Key, $Default) {
  $v = if ($Cfg) { $Cfg.$Key }
  if ($null -ne $v -and "$v" -ne '') { $v } else { $Default }
}
$box = if ($env:FCODE_BOX) { $env:FCODE_BOX } else { Get-Cfg 'box' 'coder' }
# fcode sync: cap nhat cac project tu GitHub (chi fetch + merge --ff-only), liet ke nhanh box/* va PR dang mo.
# Danh sach project lay tu syncRepos trong config (de test: dat FCODE_SYNC_REPOS = cac duong dan cach nhau bang dau ;)
$SyncRepos = @(Get-Cfg 'syncRepos' @()) | Where-Object { $_ }
if ($env:FCODE_SYNC_REPOS) { $SyncRepos = $env:FCODE_SYNC_REPOS -split ';' | Where-Object { $_ } }
$SyncRepos = @($SyncRepos)

function Invoke-Git([string]$Repo, [string[]]$GitArgs) {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $exc = @()
  # core.hooksPath tro vao thu muc rong: khong hook nao cua project chay trong luc sync
  try { $o = & git --no-optional-locks -c "core.hooksPath=$script:HooksDir" -C $Repo @GitArgs 2>&1; $code = $LASTEXITCODE }
  catch { $o = @(); $code = -1; $exc = @("$($_.Exception.Message)") }
  finally { $ErrorActionPreference = $old }
  # stdout va stderr tach rieng: canh bao cua git khong lot vao gia tri dang doc
  $err = @($o | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) + $exc
  $out = @($o | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
  [pscustomobject]@{ Code = $code; Out = ($out -join "`n").Trim(); Err = ($err -join "`n").Trim() }
}

# dong loi dau tien cua git (fatal:/error:), neu khong co thi dong dau
function Get-GitError($r) {
  $lines = @(($r.Err + "`n" + $r.Out) -split "`n" | Where-Object { $_.Trim() })
  $hit = $lines | Where-Object { $_ -match '^(fatal|error):' } | Select-Object -First 1
  $i = [array]::IndexOf($lines, $hit)
  if ($hit -and $hit.EndsWith(':') -and $i + 1 -lt $lines.Count) { $hit = $hit + ' ' + $lines[$i + 1].Trim() }
  if ($hit) { $hit } elseif ($lines) { $lines[0] } else { "git thoát mã $($r.Code)" }
}

# so commit: $null neu git loi
function Get-GitCount([string]$Repo, [string]$Range) {
  $r = Invoke-Git $Repo @('rev-list', '--count', $Range)
  if ($r.Code -eq 0 -and $r.Out -match '^\d+$') { [int]$r.Out }
}

function Invoke-Sync {
  if ($SyncRepos.Count -eq 0) {
    Write-Host "Chưa có repo nào, thêm vào $ConfigFile"
    Write-Host '  (mục syncRepos: danh sách thư mục project trên máy này)'
    return 0
  }
  $env:GIT_TERMINAL_PROMPT = '0'; $env:GH_PROMPT_DISABLED = '1'
  $fetchFail = 0; $updated = 0; $current = 0; $skipped = 0; $waiting = 0
  # thu muc hooks rong, tao moi moi lan chay va kiem tra that su rong
  $script:HooksDir = Join-Path ([IO.Path]::GetTempPath()) ('fcode-nohooks-' + [guid]::NewGuid().ToString('N'))
  try {
    [void](New-Item -ItemType Directory -Path $script:HooksDir -ErrorAction Stop)
    if (@(Get-ChildItem -LiteralPath $script:HooksDir -Force).Count -ne 0) { throw 'thư mục không rỗng' }
  } catch { Write-Host ('lỗi: không tạo được thư mục hooks rỗng: ' + $_.Exception.Message); return 1 }
  try {
  foreach ($repo in $SyncRepos) {
    Write-Host ''
    Write-Host ("== " + (Split-Path $repo -Leaf))
    if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) { Write-Host '  lỗi: không tìm thấy project (thư mục hoặc .git)'; $fetchFail++; continue }
    $f = Invoke-Git $repo @('fetch', '--prune', 'origin')
    if ($f.Code -ne 0) { Write-Host ('  lỗi: không tải được từ GitHub: ' + (Get-GitError $f)); $fetchFail++; continue }

    $b = Invoke-Git $repo @('branch', '--show-current')
    # --untracked-files=all / --ignore-submodules=none: cau hinh cua project khong the che thay doi chua luu
    $s = Invoke-Git $repo @('status', '--porcelain=v1', '--untracked-files=all', '--ignore-submodules=none')
    $branch = $b.Out; $dirty = [bool]$s.Out
    $LM = 'refs/heads/main'; $RM = 'refs/remotes/origin/main'
    $behind = Get-GitCount $repo "$LM..$RM"
    $ahead = Get-GitCount $repo "$RM..$LM"
    if ($b.Code -ne 0 -or $s.Code -ne 0) {
      Write-Host ('  bỏ qua: không kiểm tra được trạng thái project: ' + (Get-GitError $(if ($b.Code -ne 0) { $b } else { $s })))
      $skipped++
    } elseif ($branch -eq 'main' -and -not $dirty) {
      if ($null -eq $behind -or $null -eq $ahead) { Write-Host '  bỏ qua: không đọc được main/origin/main'; $skipped++ }
      elseif ($behind -eq 0) {
        $note = if ($ahead -gt 0) { " ($ahead commit chưa đẩy)" } else { '' }
        Write-Host ("  main: đã mới nhất" + $note); $current++
      }
      elseif ($ahead -gt 0) {
        Write-Host '  main trên laptop có commit chưa đẩy, bỏ qua'; $skipped++
      }
      else {
        # --no-overwrite-ignore: khong ghi de file bi gitignore (vd .env); --no-autostash: khong stash;
        # mergeOptions rong: cau hinh nhu --squash cua project khong doi duoc ket qua
        $mg = Invoke-Git $repo @('-c', 'branch.main.mergeOptions=', 'merge', '--ff-only', '--no-overwrite-ignore', '--no-autostash', $RM)
        if ($mg.Code -eq 0) { Write-Host ("  main: đã cập nhật $behind commit"); $updated++ }
        else { Write-Host ('  bỏ qua: git không cập nhật được: ' + (Get-GitError $mg)); $skipped++ }
      }
    } else {
      $why = @()
      if (-not $branch) { $why += 'không ở nhánh nào' } elseif ($branch -ne 'main') { $why += "đang ở nhánh $branch" }
      if ($dirty) { $why += 'có thay đổi chưa lưu' }
      $n = if ($null -ne $behind) { $behind } else { '?' }
      Write-Host ("  bỏ qua: " + ($why -join ', ') + " (origin/main hơn main trên laptop $n commit)")
      $skipped++
    }

    $r = Invoke-Git $repo @('for-each-ref', '--sort=-committerdate', '--format=%(refname:short)|%(committerdate:short)', 'refs/remotes/origin/box/')
    $refs = @($r.Out -split "`n" | Where-Object { $_ })
    if ($r.Code -ne 0) { Write-Host '  nhánh box: không đọc được' }
    elseif (-not $refs) { Write-Host '  nhánh box: không có' }
    foreach ($line in $(if ($r.Code -eq 0) { $refs })) {
      $name, $date = $line -split '\|', 2
      $a = Get-GitCount $repo "$RM..$name"
      if ($null -eq $a) { Write-Host "  nhánh box: $name - ? commit (không đọc được), mới nhất $date" }
      elseif ($a -gt 0) { $waiting++; Write-Host "  nhánh box: $name - $a commit chờ merge, mới nhất $date" }
      else { Write-Host "  nhánh box: $name - đã nằm trong main, mới nhất $date" }
    }

    $url = (Invoke-Git $repo @('remote', 'get-url', 'origin')).Out
    if ($url -notmatch 'github\.com[:/]([^/]+/[^/]+?)(\.git)?$') { Write-Host '  PR: origin không phải GitHub'; continue }
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $prs = $null
    try {
      $j = & gh pr list -R $Matches[1] --state open --json number,title,headRefName,url 2>&1; $gc = $LASTEXITCODE
      if ($gc -eq 0) {
        # chi doc stdout; stderr (canh bao) bo ra ngoai
        $txt = (@($j | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join '')
        $prs = @(ConvertFrom-Json $txt | ForEach-Object { $_ })
      }
    }
    catch { $prs = $null }
    finally { $ErrorActionPreference = $old }
    if ($null -eq $prs) { Write-Host '  PR: không lấy được danh sách (gh lỗi)'; continue }
    if ($prs.Count -eq 0) { Write-Host '  PR đang mở: không có' }
    foreach ($p in $prs) { Write-Host ("  PR #" + $p.number + ": " + $p.title + " [" + $p.headRefName + "] " + $p.url) }
  }
  } finally { Remove-Item -LiteralPath $script:HooksDir -Recurse -Force -ErrorAction SilentlyContinue }
  Write-Host ''
  $sum = "$($SyncRepos.Count) project: $updated đã cập nhật, $current đã mới nhất, $skipped bỏ qua"
  if ($fetchFail) { $sum += ", $fetchFail lỗi" }
  Write-Host ($sum + "; $waiting nhánh box chờ merge")
  if ($fetchFail) { 1 } else { 0 }
}

# fcode ipa: tai ban FCode moi nhat (release `latest` cua brooklyn96/fcoding) ve de keo vao Sideloadly.
# De test: FCODE_IPA_TAG doi ten tag.
$IpaRepo = Get-Cfg 'ipaRepo' 'brooklyn96/fcoding'
$IpaDir = Join-Path $env:USERPROFILE 'Downloads'
# loi cho nguoi dung: dong 1 la cau tieng Viet de hieu, dong 2 ngan la chi tiet ky thuat
function Write-IpaError([string]$Msg, $Detail) {
  Write-Host "lỗi: $Msg"
  $d = ("$Detail" -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
  if ($d) { $d = $d.Trim(); if ($d.Length -gt 160) { $d = $d.Substring(0, 160) + '...' }; Write-Host "  (chi tiết: $d)" }
}

# ngay phat hanh = updated_at cua asset fcode.ipa trong JSON cua GitHub API; loi gi cung tra $null (khong hien ngay)
function Get-IpaReleaseDate([string]$Tag) {
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 -Headers @{ 'User-Agent' = 'fcode'; 'Accept' = 'application/vnd.github+json' } `
      -Uri ("https://api.github.com/repos/$IpaRepo/releases/tags/" + [uri]::EscapeDataString($Tag))
    $a = @((ConvertFrom-Json $r.Content).assets) | Where-Object { $_.name -eq 'fcode.ipa' } | Select-Object -First 1
    $v = $a.updated_at
    if ($v -is [datetime]) { return $v.ToLocalTime() }
    if ($v) { return [DateTimeOffset]::Parse("$v", [Globalization.CultureInfo]::InvariantCulture).LocalDateTime }
  } catch { }
  return $null
}

# SHA256 bang .NET (Get-FileHash khong co trong powershell 5.1 khi no thua PSModulePath cua pwsh 7)
function Get-Sha256([string]$Path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite,Delete')
  try { [BitConverter]::ToString($sha.ComputeHash($fs)) } finally { $fs.Dispose(); $sha.Dispose() }
}

function Clear-ReadOnly([string]$Path) {
  if (Test-Path -LiteralPath $Path) { [IO.File]::SetAttributes($Path, ([IO.File]::GetAttributes($Path) -band (-bnot [IO.FileAttributes]::ReadOnly))) }
}

# chi mot lan tai chay cung luc (mutex ten): lan thu hai bao ro va thoat
function Invoke-Ipa {
  $mx = $null; $held = $false; $busy = 'đang có một lần tải FCode khác chạy, chờ xong rồi chạy lại'
  try {
    try { $mx = New-Object Threading.Mutex($false, 'Local\fcode-ipa'); $held = $mx.WaitOne(0) }
    catch {
      # PowerShell boc loi .NET trong MethodInvocationException: xet loi goc
      $x = $_.Exception; if ($x.InnerException) { $x = $x.InnerException }
      if ($x -is [Threading.AbandonedMutexException]) { $held = $true }
      # lan chay khac (vd. quyen admin) giu mutex: khong mo duoc -> coi nhu dang ban
      elseif ($x -is [UnauthorizedAccessException] -or $x -is [Threading.WaitHandleCannotBeOpenedException]) { Write-Host $busy; return 1 }
      else { throw }
    }
    if (-not $held) { Write-Host $busy; return 1 }
    return (Invoke-IpaLocked)
  } finally {
    if ($mx) {
      if ($held) { try { $mx.ReleaseMutex() } catch { } }
      $mx.Dispose()
    }
  }
}

function Invoke-IpaLocked {
  $tag = if ($env:FCODE_IPA_TAG) { $env:FCODE_IPA_TAG } else { Get-Cfg 'ipaTag' 'latest' }
  # file tam nam cung thu muc voi dich: doi ten/thay the cung o dia nen khong bao gio mat fcode.ipa
  $target = Join-Path $IpaDir 'fcode.ipa'; $prev = Join-Path $IpaDir 'fcode.prev.ipa'
  $tmp = Join-Path $IpaDir ('fcode.ipa.' + [guid]::NewGuid().ToString('N') + '.part')
  $old = $ErrorActionPreference
  try {
    try { [void](New-Item -ItemType Directory -Force -Path $IpaDir) }
    catch { Write-IpaError "không tạo được thư mục lưu file ($IpaDir)." $_.Exception.Message; return 1 }
    # don file .part cu (lan tai truoc bi ngat) qua 1 gio; da co khoa nen khong dung lan tai dang chay
    try {
      Get-ChildItem -LiteralPath $IpaDir -Filter 'fcode.ipa.*.part' -File |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
    Write-Host 'Đang tải bản FCode mới nhất...'
    $ok = $false
    if (Get-Command gh -ErrorAction SilentlyContinue) {
      try {
        $ErrorActionPreference = 'Continue'
        $null = & gh release download $tag -R $IpaRepo -p fcode.ipa -O $tmp 2>&1
        $ok = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $tmp)
      } catch { $ok = $false } finally { $ErrorActionPreference = $old }
      if (-not $ok) { Write-Host 'gh không tải được, thử tải trực tiếp...' }
    }
    if (-not $ok) {
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
      try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 -Uri "https://github.com/$IpaRepo/releases/download/$([uri]::EscapeDataString($tag))/fcode.ipa" -OutFile $tmp
      } catch {
        Write-IpaError 'không tải được file fcode.ipa. Hãy kiểm tra mạng rồi chạy lại. File cũ (nếu có) được giữ nguyên.' $_.Exception.Message
        return 1
      }
    }
    # kiem tra file: > 100 KB, bat dau bang PK, mo duoc nhu zip, co thu muc Payload/
    $why = $null
    $len = (Get-Item -LiteralPath $tmp).Length
    if ($len -le 100KB) { $why = "file quá nhỏ ($len byte)" }
    else {
      $fs = [IO.File]::OpenRead($tmp)
      try { $m = New-Object byte[] 2; [void]$fs.Read($m, 0, 2) } finally { $fs.Dispose() }
      if ($m[0] -ne 0x50 -or $m[1] -ne 0x4B) { $why = 'không phải file zip (thiếu PK)' }
      else {
        try {
          Add-Type -AssemblyName System.IO.Compression.FileSystem
          $z = [IO.Compression.ZipFile]::OpenRead($tmp)
          try { if (-not @($z.Entries | Where-Object { $_.FullName.StartsWith('Payload/') }).Count) { $why = 'trong file không có Payload/' } }
          finally { $z.Dispose() }
        } catch { $why = 'file zip bị hỏng' }
      }
    }
    if ($why) { Write-IpaError 'file tải về bị hỏng hoặc không đúng. Hãy chạy lại sau ít phút. File cũ (nếu có) được giữ nguyên.' $why; return 1 }

    # cung dung luong moi bam hash
    $hadTarget = Test-Path -LiteralPath $target
    $same = $hadTarget -and ((Get-Item -LiteralPath $target).Length -eq $len) -and ((Get-Sha256 $tmp) -eq (Get-Sha256 $target))
    if ($same) { Write-Host 'đã là bản mới nhất (giống file đang có)' }
    else {
      try {
        Clear-ReadOnly $prev; Clear-ReadOnly $target
        # File.Replace: mot buoc, fcode.ipa cu thanh fcode.prev.ipa; neu loi thi fcode.ipa cu van nguyen
        if ($hadTarget) { [IO.File]::Replace($tmp, $target, $prev) }
        else { [IO.File]::Move($tmp, $target) }
      } catch {
        $e1 = $_.Exception.Message
        # Replace do dang: fcode.ipa da thanh fcode.prev.ipa ma file moi chua vao -> tra lai
        if ($hadTarget -and -not (Test-Path -LiteralPath $target) -and (Test-Path -LiteralPath $prev)) {
          try { Move-Item -LiteralPath $prev -Destination $target -Force } catch { }
        }
        Write-IpaError 'không đặt được file mới. File cũ được giữ nguyên. Nếu Sideloadly hay chương trình khác đang mở fcode.ipa, hãy đóng nó rồi chạy lại.' $e1
        return 1
      }
      Write-Host 'đã tải bản mới'
    }
    $when = Get-IpaReleaseDate $tag
    if ($when) { Write-Host ('Ngày phát hành: ' + $when.ToString('dd/MM/yyyy HH:mm')) }
    Write-Host "File: $target"
    Write-Host 'Bước tiếp theo: Mở Sideloadly, kéo file này vào, bấm Start'
    return 0
  } catch {
    Write-IpaError 'có lỗi bất ngờ khi tải FCode. File cũ (nếu có) được giữ nguyên.' $_.Exception.Message
    return 1
  } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

# duong dan instabox.exe: config > PATH > thu muc cai mac dinh
function Get-InstaboxExe {
  $p = Get-Cfg 'instabox' ''
  if ($p -and (Test-Path -LiteralPath $p)) { return $p }
  $c = Get-Command instabox -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  Join-Path $env:LOCALAPPDATA 'Programs\instabox\instabox.exe'
}

function Show-Help {
  Write-Host 'fcode - điều khiển box coding từ máy này. Các lệnh:'
  Write-Host ''
  Write-Host '  fcode'
  Write-Host '      Xem danh sách phiên đang chạy trên box, gõ số để vào.'
  Write-Host '      Ví dụ: fcode'
  Write-Host '  fcode <số hoặc tên phiên>'
  Write-Host '      Vào thẳng một phiên (tên có thể gõ phần đầu). Thoát mà không tắt phiên: Ctrl+B rồi D.'
  Write-Host '      Ví dụ: fcode 2    hoặc    fcode ten-phien'
  Write-Host '  fcode --list'
  Write-Host '      Chỉ in danh sách phiên, không vào (viết tắt: fcode -l).'
  Write-Host '      Ví dụ: fcode -l'
  Write-Host '  fcode sync'
  Write-Host '      Cập nhật các project trên máy này từ GitHub, báo nhánh box chờ merge và PR đang mở.'
  Write-Host '      Ví dụ: fcode sync'
  Write-Host '  fcode ipa'
  Write-Host '      Tải bản FCode mới nhất về thư mục Downloads để kéo vào Sideloadly.'
  Write-Host '      Ví dụ: fcode ipa'
  Write-Host '  fcode add <chủ/repo> [tên]'
  Write-Host '      Thêm một project GitHub vào box để omp làm việc và app FCode hiện trong danh sách.'
  Write-Host '      Ví dụ: fcode add ten-tai-khoan/ten-repo    hoặc    fcode add ten-tai-khoan/ten-repo ten-ngan'
  Write-Host '  fcode pair [tên thiết bị]'
  Write-Host '      Tạo mã ghép (kèm mã QR) để ghép một iPhone mới với server FCode. Mã dùng 1 lần, hết hạn sau 5 phút.'
  Write-Host '      Ví dụ: fcode pair    hoặc    fcode pair iPhone của Mẹ'
  Write-Host '  fcode help'
  Write-Host '      In bảng này (cũng là fcode -h, fcode --help, fcode /?).'
  Write-Host '      Ví dụ: fcode help'
  Write-Host ''
  Write-Host "Cấu hình riêng của máy: $ConfigFile"
}

# Chay script bash tren box. Tham so di CUNG script (dong "set -- '..'" dau payload, da kiem tra), khong bao gio nam tren dong lenh ssh.
function Invoke-BoxScript([string]$Script, [string[]]$ScriptArgs) {
  $ib = Get-InstaboxExe
  $pre = if ($ScriptArgs) { 'set -- ' + (($ScriptArgs | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' ') + "`n" } else { '' }
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pre + $Script))
  # script di qua stdin (dong lenh Windows bi gioi han ~8 KB); tren box luu ra file tam roi chay voi stdin = /dev/null
  $remote = 'f=$(mktemp) && base64 -di >$f && bash -l $f </dev/null; rc=$?; rm -f $f; exit $rc'
  & $ib wake $box *> $null
  $b64 | & $ib ssh $box -- $remote
}

# ky tu dieu khien (ke ca xuong dong) khong bao gio duoc di vao tham so
function Test-HasControlChar([string]$s) { $s -match '[\x00-\x1f\x7f]' }

# fcode add <owner/repo> [name]: them project vao box (clone + hook + cau hinh FCode); xem $FcodeAddSh
function Invoke-Add {
  $repo = if ($Rest.Count -gt 1) { $Rest[1] } else { '' }
  if ((Test-HasControlChar $repo) -or ($Rest.Count -gt 2 -and (Test-HasControlChar $Rest[2]))) { Write-Host 'lỗi: tên repo hoặc tên project có ký tự không hợp lệ.'; return 1 }
  $repo = $repo -replace '(?i)\.git\z', ''
  $name = if ($Rest.Count -gt 2) { $Rest[2].ToLowerInvariant() -replace '\.git\z', '' } elseif ($repo -match '/') { ($repo -split '/')[1].ToLowerInvariant() } else { '' }
  if ($repo -notmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z' -or $repo -match '\A\.+/|/\.+\z') {
    Write-Host 'Cách dùng: fcode add <chủ/repo> [tên]'
    Write-Host 'Ví dụ: fcode add ten-tai-khoan/ten-repo'
    return 1
  }
  if ($name -notmatch '\A[a-z0-9][a-z0-9._-]{0,63}\z' -or $name -eq 'home') {
    Write-Host "Tên project '$name' không dùng được: chỉ gồm chữ thường, số, dấu . _ - và không trùng 'home'."
    Write-Host 'Đặt tên khác: fcode add <chủ/repo> <tên>'
    return 1
  }
  Write-Host "Đang thêm $repo vào box '$box' (tên project: $name)..."
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $lines = @(Invoke-BoxScript $FcodeAddSh @($repo, $name) 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
  } catch { $lines = @("$($_.Exception.Message)"); $code = 255 }
  finally { $ErrorActionPreference = $old }
  $rules = $false; $bad = 0; $seen = @{}
  foreach ($l in $lines) {
    if ($l -notmatch '^R (\S+)\s*(.*)$') { continue }
    $c = $Matches[1]; $d = $Matches[2]; $seen[$c] = $true
    switch ($c) {
      'ACCESS_OK'     { Write-Host '[1] Token của box vào được repo: OK' }
      'NOACCESS'      { Write-Host 'Token của box chưa có quyền vào repo này: vào GitHub > Settings > Developer settings > Fine-grained tokens > token của box > thêm repo này (Contents: Read and write, Pull requests: Read and write)'; if ($d) { Write-Host "  (chi tiết: $d)" } }
      'NOWRITE'       { Write-Host "Token của box mới chỉ đọc được repo này, chưa ghi được: vào GitHub > Settings > Developer settings > Fine-grained tokens > token của box > cho repo này quyền Contents: Read and write, Pull requests: Read and write"; Write-Host "  (chi tiết: quyền hiện tại $d)" }
      'CLONED'        { Write-Host "[2] Đã tải repo về /data/workspace/$name" }
      'CLONE_EXISTS'  { Write-Host "[2] Repo đã có sẵn ở /data/workspace/$name, giữ nguyên" }
      'CLONE_FAIL'    { Write-Host '[2] lỗi: không tải được repo về box. Chạy lại sau ít phút.'; if ($d) { Write-Host "  (chi tiết: $d)" } }
      'DIR_NOTGIT'    { Write-Host "[2] lỗi: thư mục /data/workspace/$name đã có nhưng không phải project git. Đặt tên khác: fcode add $repo <tên>" }
      'DIR_OTHER'     { Write-Host "[2] lỗi: thư mục /data/workspace/$name đang là project khác ($d). Đặt tên khác: fcode add $repo <tên>" }
      'HOOK_OK'       { Write-Host '[3] Đã cài hook chặn push thẳng lên main/master' }
      'HOOK_EXISTS'   { Write-Host '[3] Hook chặn push lên main/master đã có sẵn' }
      'CFG_ADDED'     { Write-Host "[4] Đã thêm '$name' vào danh sách project của FCode (có bản sao lưu config, không đụng project khác)" }
      'CFG_EXISTS'    { Write-Host "[4] '$name' đã có trong danh sách project của FCode" }
      'CFG_CONFLICT'  { Write-Host "[4] lỗi: tên '$name' đang trỏ tới thư mục khác ($d). Đặt tên khác: fcode add $repo <tên>" }
      'CFG_BROKEN'    { Write-Host '[4] lỗi: file cấu hình FCode trên box (/data/home/.fcoding/config.json) bị hỏng hoặc không đọc được, nên chưa thêm project. Nhờ người quản lý box kiểm tra file đó rồi chạy lại.'; if ($d) { Write-Host "  (chi tiết: $d)" } }
      'V_BRANCH_OK'   { Write-Host "[5] Bản clone đang ở nhánh mặc định ($d): OK" }
      'V_BRANCH_BAD'  { Write-Host "[5] cảnh báo: bản clone không ở nhánh mặc định ($d)"; $bad++ }
      'V_PR_OK'       { Write-Host '[5] Xem được danh sách PR của repo (gh pr list): OK' }
      'V_PR_BAD'      { Write-Host '[5] cảnh báo: gh pr list chưa chạy được cho repo này (token thiếu quyền Pull requests?)'; $bad++ }
      'V_HOOK_OK'     { Write-Host '[5] Hook chặn push lên main, vẫn cho push nhánh box/...: OK' }
      'V_HOOK_BAD'    { Write-Host "[5] cảnh báo: hook không chạy đúng ($d)"; $bad++ }
      'V_CRED_OK'     { Write-Host '[5] Git trên box đăng nhập GitHub thật (thử đẩy nhánh thử không gửi gì): OK' }
      'V_CRED_BAD'    {
        Write-Host '[5] cảnh báo: git trên box chưa tự đăng nhập được GitHub qua https. Xem code và PR vẫn được, nhưng omp chưa push được lên repo này.'
        Write-Host '    Báo người quản lý box để xử lý cách đăng nhập git; sau đó chạy lại lệnh này.'
        if ($d) { Write-Host "  (chi tiết: $d)" }; $bad++
      }
      'V_SERVER_OK'   { Write-Host '[5] Server FCode đã nạp cấu hình mới, không báo lỗi: OK' }
      'V_SERVER_BAD'  { Write-Host '[5] cảnh báo: server FCode báo lỗi khi nạp lại cấu hình'; $bad++ }
      'V_CFG_BAD'     { Write-Host '[5] cảnh báo: cấu hình FCode chưa đúng cho project này'; $bad++ }
      'RULES_YES'     { $rules = $true }
      'USAGE'         { Write-Host 'lỗi: thiếu tên repo hoặc tên project. Cách dùng: fcode add <chủ/repo> [tên]' }
      'BAD_ARGS'      { Write-Host 'lỗi: tên repo hoặc tên project không hợp lệ.' }
    }
  }
  if ($seen.Count -eq 0) {
    $d = ($lines | Where-Object { "$_".Trim() } | Select-Object -First 1)
    Write-IpaError 'không nói chuyện được với box. Kiểm tra: đã chạy "instabox login" chưa, và box đang bật không.' $d
    return 1
  }
  if ($code -eq 10 -or $code -eq 14) { return 1 }
  # chi bao "Xong" khi script thoat 0 va that su da qua buoc 1 (quyen) va buoc 4 (cau hinh)
  if ($code -eq 0 -and $seen.ContainsKey('ACCESS_OK') -and ($seen.ContainsKey('CFG_ADDED') -or $seen.ContainsKey('CFG_EXISTS'))) { }
  elseif ($bad -eq 0) { Write-Host "Chưa xong (mã $code). Xem thông báo ở trên rồi chạy lại cùng lệnh, chạy lại là an toàn."; return 1 }
  else { Write-Host "Đã thêm nhưng có $bad mục cần xem lại (cảnh báo ở trên). Chạy lại lệnh này là an toàn."; return 1 }
  Write-Host ''
  Write-Host "Xong. Mở app FCode, project $name đã có trong danh sách."
  if ($rules) { Write-Host 'Repo có CLAUDE.md/AGENTS.md nhắc tới deploy: omp sẽ theo quy tắc deploy của repo.' }
  Write-Host "Muốn dùng fcode sync cho project này: tải về máy (git clone https://github.com/$repo) rồi thêm đường dẫn thư mục vào syncRepos trong $ConfigFile."
  return 0
}

# fcode pair [ten thiet bi]: tao ma ghep 1 lan (kem ma QR) tren box cho iPhone moi
function Invoke-Pair {
  $dev = if ($Rest.Count -gt 1) { ($Rest[1..($Rest.Count - 1)] -join ' ').Trim() } else { '' }
  if ($dev.Length -gt 64 -or (Test-HasControlChar $dev) -or $dev.StartsWith('-')) {
    Write-Host 'Tên thiết bị không dùng được: tối đa 64 ký tự, không xuống dòng, không bắt đầu bằng dấu -.'
    Write-Host 'Ví dụ: fcode pair iPhone của Mẹ'
    return 1
  }
  Write-Host 'Đang tạo mã ghép trên box...'
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { Invoke-BoxScript $FcodePairSh @($dev) | Out-Host; $code = $LASTEXITCODE }
  catch { Write-IpaError 'không chạy được trên box.' $_.Exception.Message; return 1 }
  finally { $ErrorActionPreference = $old }
  if ($code -ne 0) {
    Write-Host 'lỗi: không tạo được mã ghép. Kiểm tra box đang bật, và server FCode trên box đã được cập nhật để hiện mã QR chưa.'
    Write-Host "  (chi tiết: lệnh fcode-pair trên box thoát mã $code)"
    return 1
  }
  Write-Host ''
  Write-Host 'Mở Camera trên iPhone mới, quét mã, rồi bấm Ghép trong app FCode. Mã hết hạn sau 5 phút.'
  return 0
}

# --- Hai script bash chay tren box (nhung san de chi can 1 file fcode.ps1) ---
# fcode.sh: liet ke / chon / vao phien tmux.
$FcodeSh = (@'
#!/bin/bash
# fcode (chay tren box): liet ke / chon / vao phien tmux. Dung: fcode.sh [--list | so | ten]
arg="${1:-}"
rows=(); names=()
while IFS= read -r l; do
  [ -n "$l" ] && rows+=("$l") && names+=("${l%%|*}")
done < <(tmux list-sessions -F '#{session_name}|#{session_attached}|#{@pc_project}|#{@pc_harness}' 2>/dev/null)
n=${#rows[@]}
if [ "$n" -eq 0 ]; then
  echo "Chưa có phiên nào trên box. Mở phiên mới từ app FCode."
  exit 0
fi

show() { # in 1 dong cho phien thu $1 (chi so tu 0)
  local name att proj har out
  IFS='|' read -r name att proj har <<<"${rows[$1]}"
  out="$(printf '%3d) %s' $(($1 + 1)) "$name")"
  [ -n "$proj" ] && out+="  -  dự án: $proj"
  [ -n "$har" ] && out+="  -  harness: $har"
  [ "${att:-0}" != "0" ] && out+="  -  đang có người xem"
  echo "$out"
}
show_all() { local i; echo "Các phiên trên box:"; for ((i = 0; i < n; i++)); do show "$i"; done; }

resolve() { # $1 = so hoac ten (hoac dau ten) -> dat $sel
  local q="$1" ql="${1,,}" i matches=()
  sel=""
  if [[ "$q" =~ ^[0-9]+$ ]] && [ "${#q}" -le 6 ] && [ "$((10#$q))" -ge 1 ] && [ "$((10#$q))" -le "$n" ]; then
    sel="${names[$((10#$q - 1))]}"; return 0
  fi
  for i in "${!names[@]}"; do [ "${names[$i]}" = "$q" ] && { sel="$q"; return 0; }; done
  for i in "${!names[@]}"; do
    n2="${names[$i]}"; [[ "${n2,,}" == "$ql"* ]] && matches+=("$i")
  done
  if [ "${#matches[@]}" -eq 1 ]; then sel="${names[${matches[0]}]}"; return 0; fi
  if [ "${#matches[@]}" -eq 0 ]; then
    echo "Không thấy phiên nào tên \"$q\"."
  else
    echo "Có nhiều phiên khớp \"$q\", gõ dài hơn hoặc dùng số:"
    for i in "${matches[@]}"; do show "$i"; done
  fi
  return 1
}

attach() {
  echo "Thoát mà không tắt phiên: bấm Ctrl+B rồi D"
  sleep 2
  case "${TERM:-}" in ""|dumb) export TERM=xterm-256color ;; esac
  exec tmux -u attach -t "=$1"
}

if [ "$arg" = "--list" ]; then show_all; exit 0; fi
if [ -n "$arg" ]; then resolve "$arg" || exit 1; attach "$sel"; fi

show_all
[ -t 0 ] || exit 0
while true; do
  echo
  read -r -p "Chọn số phiên (Enter để thoát): " c || exit 0
  [ -z "$c" ] && exit 0
  resolve "$c" && attach "$sel"
done
'@) -replace "`r`n", "`n"

# fcode-add.sh: them project vao box. Dong ket qua dang "R <MA> [chi tiet]" do Invoke-Add dich ra tieng Viet.
$FcodeAddSh = (@'
#!/bin/bash
# fcode add (chay tren box): them 1 project GitHub vao /data/workspace va vao cau hinh FCode.
# Tham so $1=<owner/repo>, $2=<ten> do fcode.ps1 dat bang "set --" ngay truoc script nay (khong qua dong lenh).
# Chay lai nhieu lan van an toan. Chi in ASCII: dong "R <MA> [chi tiet]" de fcode.ps1 dich ra tieng Viet.
# Khong bao gio in token.
set -u
repo="${1:-}"; name="${2:-}"
[ -n "$repo" ] && [ -n "$name" ] || { echo "R USAGE"; exit 2; }
repo="${repo%.git}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$name" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] && [ "$name" != home ] \
  && ! [[ "${repo%%/*}" =~ ^\.+$ ]] && ! [[ "${repo##*/}" =~ ^\.+$ ]] || { echo "R BAD_ARGS"; exit 2; }
dir="/data/workspace/$name"
cfg="/data/home/.fcoding/config.json"
fail=0
say() { echo "R $*"; }
clean() { sed -E 's/(gh[a-z]_|github_pat_)[A-Za-z0-9_]+/<token>/g' | head -n 1 | cut -c1-200; }
err="$(mktemp)"; trap 'rm -f "$err"' EXIT

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

# --- dang nhap git cho repo: tach rieng de doi cach khi co co che chinh thuc ---
setup_git_auth() { # $1 = thu muc clone
  local ghbin; ghbin="$(command -v gh)"
  git -C "$1" config --local --replace-all 'credential.https://github.com.helper' \
    "!f() { [ -r /run/instabox/secrets/env ] && . /run/instabox/secrets/env; $ghbin auth git-credential \"\$@\"; }; f"
}
verify_git_auth() { # $1 = thu muc clone; that su dang nhap GitHub (push thu, khong gui gi), moi truong sach nhu phien omp
  env -i HOME="$HOME" PATH=/usr/local/bin:/usr/bin:/bin GIT_TERMINAL_PROMPT=0 \
    git -C "$1" push --dry-run origin HEAD:refs/heads/box/fcode-add-check >"$err" 2>&1 </dev/null
}

# 1. token cua box doc duoc repo VA ghi duoc (WRITE/MAINTAIN/ADMIN)
if ! gh repo view "$repo" >/dev/null 2>"$err" </dev/null; then say NOACCESS "$(clean <"$err")"; exit 10; fi
say ACCESS_OK
perm="$(gh repo view "$repo" --json viewerPermission -q .viewerPermission 2>/dev/null </dev/null)"
case "$perm" in WRITE|MAINTAIN|ADMIN) ;; *) say NOWRITE "${perm:-unknown}"; exit 14;; esac

# 2. clone (https + token cua gh; ssh deploy key can quyen admin repo de tao, https thi khong)
want="$(printf '%s' "$repo" | tr 'A-Z' 'a-z')"
if [ -e "$dir" ]; then
  if [ ! -d "$dir/.git" ]; then say DIR_NOTGIT "$dir"; exit 11; fi
  have="$(git -C "$dir" remote get-url origin 2>/dev/null | tr 'A-Z' 'a-z' | sed -E 's#^(https://github\.com/|git@[^:]*:)##; s#\.git$##')"
  if [ "$have" != "$want" ]; then say DIR_OTHER "$have"; exit 11; fi
  say CLONE_EXISTS
else
  if ! gh repo clone "$repo" "$dir" >/dev/null 2>"$err" </dev/null; then say CLONE_FAIL "$(clean <"$err")"; exit 12; fi
  say CLONED
fi
setup_git_auth "$dir"

# 3. hook chan push len main/master
mkdir -p "$dir/.git/hooks"
htmp="$(mktemp)"; hook_text >"$htmp"
if cmp -s "$htmp" "$dir/.git/hooks/pre-push" 2>/dev/null; then say HOOK_EXISTS; else install -m 755 "$htmp" "$dir/.git/hooks/pre-push"; say HOOK_OK; fi
rm -f "$htmp"; chmod 755 "$dir/.git/hooks/pre-push"

# 4. them vao config FCode (chi them 1 khoa trong "projects"; khoa thu muc; sao luu truoc; ghi bang rename, 0600)
python3 - "$cfg" "$name" "$dir" <<'PY'
import fcntl, json, os, shutil, sys, tempfile, time
cfg, name, d = sys.argv[1:4]
cdir = os.path.dirname(cfg)
def broken(why):
    print('R CFG_BROKEN ' + str(why)[:80]); sys.exit(22)
try:
    lock = os.open(cdir, os.O_RDONLY)
    fcntl.flock(lock, fcntl.LOCK_EX)      # hai lan fcode add cung luc phai doi nhau
    raw = open(cfg, encoding='utf-8').read()
    c = json.loads(raw)
    if not isinstance(c, dict): raise ValueError('config is not an object')
    p = c.get('projects')
    if p is None: p = c['projects'] = {}
    if not isinstance(p, dict): raise ValueError('projects is not an object')
except (OSError, ValueError) as e:
    broken(type(e).__name__)
if name in p:
    if p[name] == d:
        print('R CFG_EXISTS'); sys.exit(0)
    print('R CFG_CONFLICT ' + str(p[name])[:100]); sys.exit(21)
tmp = None
try:
    bak = '%s.bak-%s-%d' % (cfg, time.strftime('%Y%m%d-%H%M%S'), os.getpid())
    shutil.copyfile(cfg, bak); os.chmod(bak, 0o600)
    p[name] = d
    fd, tmp = tempfile.mkstemp(dir=cdir, prefix='.config.json.', suffix='.tmp')   # 0600, ten khong trung
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write(json.dumps(c, indent=2, ensure_ascii=False) if '\n' in raw.strip() else json.dumps(c, ensure_ascii=False, separators=(',', ':')))
        if raw.endswith('\n'): f.write('\n')
    os.replace(tmp, cfg); tmp = None
except OSError as e:
    if tmp:
        try: os.unlink(tmp)
        except OSError: pass
    broken(type(e).__name__)
print('R CFG_ADDED')
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

# 5. kiem tra
branch="$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null)"
defb="$(gh repo view "$repo" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null </dev/null)"
if [ -n "$branch" ] && [ "$branch" = "$defb" ]; then say V_BRANCH_OK "$branch"; else say V_BRANCH_BAD "${branch:-none}/${defb:-?}"; fail=1; fi
if gh pr list -R "$repo" --limit 1 >/dev/null 2>&1 </dev/null; then say V_PR_OK; else say V_PR_BAD; fail=1; fi
# hook: chay thu voi ref gia, khong push gi
hook="$dir/.git/hooks/pre-push"
printf 'refs/heads/x 0 refs/heads/main 0\n' | "$hook" origin x >/dev/null 2>&1; r1=$?
printf 'refs/heads/box/x 0 refs/heads/box/x 0\n' | "$hook" origin x >/dev/null 2>&1; r2=$?
if [ "$r1" -ne 0 ] && [ "$r2" -eq 0 ]; then say V_HOOK_OK; else say V_HOOK_BAD "main=$r1 box=$r2"; fail=1; fi
# git dang nhap duoc GitHub that su (khong chi "co helper")
if verify_git_auth "$dir"; then say V_CRED_OK; else say V_CRED_BAD "$(clean <"$err")"; fail=1; fi
# cau hinh FCode hop le + server dang chay khong bao loi nap lai
if python3 - "$cfg" "$name" "$dir" <<'PY'
import json, os, sys
cfg, name, d = sys.argv[1:4]
c = json.load(open(cfg, encoding='utf-8'))
v = c.get('projects', {}).get(name)
sys.exit(0 if v == d and os.path.isabs(v) and os.path.isdir(v) and oct(os.stat(cfg).st_mode & 0o777) == '0o600' else 1)
PY
then
  cport="$(python3 -c "import json;print(json.load(open('$cfg')).get('port',''))" 2>/dev/null)"
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
'@) -replace "`r`n", "`n"

# fcode-pair tren box (server worker them --qr). $1 = ten thiet bi (co the rong).
$FcodePairSh = (@'
name="${1:-}"
if [ -n "$name" ]; then exec fcode-pair "$name" --qr; else exec fcode-pair --qr; fi
'@) -replace "`r`n", "`n"

if ($arg -in '-h', '--help', '/?', 'help') { Show-Help; exit 0 }
if ($CfgBroken) {
  Write-Host "lỗi: file cấu hình bị sai, không đọc được: $ConfigFile"
  Write-Host '  Mở file bằng Notepad để sửa, hoặc xóa file rồi chạy lại install.ps1 để tạo lại.'
  Write-Host "  (chi tiết: $(($CfgBroken -split "`n")[0].Trim()))"
  exit 1
}
if ($arg -eq 'sync') { exit (Invoke-Sync) }
if ($arg -eq 'ipa') { exit (Invoke-Ipa) }
if ($arg -eq 'add') { exit (Invoke-Add) }
if ($arg -eq 'pair') { exit (Invoke-Pair) }
if ($arg -eq '-l') { $arg = '--list' }
# ten phien: chi chu, so, . _ - (\z, khong dung $: $ chap nhan them 1 ky tu xuong dong o cuoi)
if ($arg -and $arg -ne '--list' -and $arg -notmatch '\A[A-Za-z0-9._-]+\z') {
  Write-Host "Không hiểu lệnh '$($arg -replace '[\x00-\x1f\x7f]', '?')'. Gõ fcode help để xem các lệnh."
  exit 1
}
$ib = Get-InstaboxExe
# tham so $1 di cung script (set -- '..'), khong nam tren dong lenh ssh
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("set -- '$arg'`n" + $FcodeSh))
$remote = "bash <(echo $b64 | base64 -d)"
# box tu tam dung (ranh 30 phut / chay 8 tieng) thi danh thuc truoc; loi wake de ssh tu bao
& $ib wake $box *> $null
if ($arg -eq '--list') { & $ib ssh $box -- $remote } else { & $ib ssh $box -- -q -tt $remote }
$rc = $LASTEXITCODE
# tham so khong khop phien nao (hoac loi) thi nhac lenh help
if ($rc -ne 0 -and $arg -and $arg -ne '--list') { Write-Host "Nếu '$arg' không phải tên phiên, gõ fcode help để xem các lệnh." }
exit $rc
