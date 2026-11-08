# fcode: vao phien tmux tren box Oracle (ssh thang, alias "oracle" trong ~/.ssh/config, 1 lan ssh). Xem fcode.sh.
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$arg = if ($Rest -and $Rest.Count -gt 0) { $Rest[0] } else { '' }
# Cau hinh rieng tung may: %USERPROFILE%\.fcode\config.json (install.ps1 tao). Thieu khoa thi dung mac dinh.
# Khoa: ssh (duong dan ssh.exe), host (alias ssh den box, mac dinh oracle; FCODE_HOST doi tam cho mot lan chay), syncRepos (danh sach thu muc cho fcode sync), ipaRepo, ipaTag, deployHost (ten ssh den VPS cho fcode deploy, mac dinh contabo),
# moveTargets (moveTargets.<ten ssh>.platform_user = user dang nhap cua nen tang cua may do, de trong neu khong co; fcode move).
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
$box = [string]$(if ($env:FCODE_HOST) { $env:FCODE_HOST } else { Get-Cfg 'host' 'oracle' })   # alias ssh den box (ssh $box ...)
# checked once, here, for every ssh call (-oProxyCommand=... would run a program; a quote would break the hand-built command line of Invoke-BoxPy)
if ($box -notmatch '\A[A-Za-z0-9][A-Za-z0-9._-]*\z') { Write-Host "lỗi: tên box không hợp lệ ($(($box -replace '[^\x20-\x7e]', '?'))). Dùng tên trong ~/.ssh/config (chữ, số, dấu . _ -), đặt ở khóa host của config.json hoặc biến FCODE_HOST."; exit 1 }
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

# --- fcode sync: project tren box chua co tren laptop (khop theo repo GitHub cua origin, khong theo ten thu muc) ---
# Tim ban clone da co; khong co thi hoi thu muc de tai ve. Them vao syncRepos roi cap nhat ngay trong lan chay nay.
# Chi de thu: FCODE_DESKTOP / FCODE_DOCUMENTS thay Desktop / Documents that; FCODE_GITHUB_BASE thay https://github.com.
function Get-SyncDesktop { if ($env:FCODE_DESKTOP) { $env:FCODE_DESKTOP } else { [Environment]::GetFolderPath('Desktop') } }
function Read-SyncLine([string]$Prompt) { Write-Host -NoNewline $Prompt; $l = [Console]::In.ReadLine(); if ($null -eq $l) { Write-Host '' }; $l }

# URL origin doc thang tu .git/config (nhanh, khong chay git cho tung thu muc); .git la file (worktree) thi hoi git
function Get-GitDirOrigin([string]$Dir) {
  $g = Join-Path $Dir '.git'
  if (Test-Path -LiteralPath $g -PathType Container) {
    try { $txt = [IO.File]::ReadAllText((Join-Path $g 'config')) } catch { return '' }
    $in = $false
    foreach ($line in ($txt -split "`n")) { $t = $line.Trim(); if ($t.StartsWith('[')) { $in = $t -match '^\[remote\s+"origin"\]' } elseif ($in -and $t -match '^url\s*=\s*(.+)$') { return $Matches[1].Trim() } }
    return ''
  }
  if (Test-Path -LiteralPath $g -PathType Leaf) { $r = Invoke-GitQuiet $Dir @('remote', 'get-url', 'origin'); if ($r.Code -eq 0) { return [string]@($r.Out)[0] } }
  ''
}

# tim cac thu muc git co origin la mot trong cac repo $Want (key -> $true). Tra ve @{ Found = key -> [dirs]; Where = [noi da tim] }.
# Desktop that 4 cap; Documents va source\repos 3 cap; %USERPROFILE% 2 cap; thu muc cha cua moi syncRepos 2 cap.
# Bo qua node_modules, .git, thu muc an / he thong; dung sau 15 giay.
function Find-LocalClones([hashtable]$Want) {
  $docs = if ($env:FCODE_DOCUMENTS) { $env:FCODE_DOCUMENTS } else { [Environment]::GetFolderPath('MyDocuments') }
  $roots = @(@{ P = (Get-SyncDesktop); D = 4 }, @{ P = $docs; D = 3 }, @{ P = (Join-Path $env:USERPROFILE 'source\repos'); D = 3 }, @{ P = $env:USERPROFILE; D = 2 })
  foreach ($r in $SyncRepos) { $pp = Split-Path ([string]$r).TrimEnd('\', '/') -Parent; if ($pp) { $roots += @{ P = $pp; D = 2 } } }
  $found = @{}; $where = New-Object System.Collections.ArrayList; $seenRoot = @{}; $seenDir = @{}
  $lim = if ("$env:FCODE_FIND_SEC" -match '\A[0-9]{1,3}\z') { [int]$env:FCODE_FIND_SEC } else { 15 }   # FCODE_FIND_SEC: chi de thu
  $sw = [Diagnostics.Stopwatch]::StartNew(); $skip = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System
  foreach ($r in $roots) {
    if (-not $r.P -or -not (Test-Path -LiteralPath $r.P -PathType Container)) { continue }
    $rp = [IO.Path]::GetFullPath($r.P).TrimEnd('\'); $rk = $rp.ToLowerInvariant()
    if ($seenRoot.ContainsKey($rk) -and $seenRoot[$rk] -ge $r.D) { continue }
    if ($sw.Elapsed.TotalSeconds -ge $lim) { $seenRoot[$rk] = $r.D; [void]$where.Add("$rp (chưa tìm)"); continue }
    $seenRoot[$rk] = $r.D; [void]$where.Add("$rp ($($r.D) cấp)")
    $q = New-Object System.Collections.Queue; $q.Enqueue(@($rp, 0))
    while ($q.Count -and $sw.Elapsed.TotalSeconds -lt $lim) {
      $x = $q.Dequeue(); $d = [string]$x[0]; $lv = [int]$x[1]
      if ($lv -gt 0 -and (Test-Path -LiteralPath (Join-Path $d '.git'))) {   # thu muc goc la git (vd. %USERPROFILE%) van tim ben trong
        $k = Get-RepoKey (Get-GitDirOrigin $d); $dk = $d.ToLowerInvariant()
        if ($k -and $Want.ContainsKey($k) -and -not $seenDir.ContainsKey($dk)) { $seenDir[$dk] = $true; if (-not $found.ContainsKey($k)) { $found[$k] = New-Object System.Collections.ArrayList }; [void]$found[$k].Add($d) }
        continue
      }
      if ($lv -ge $r.D) { continue }
      try { $subs = [IO.Directory]::GetDirectories($d) } catch { continue }
      foreach ($s in $subs) {
        $n = [IO.Path]::GetFileName($s)
        if ($n -eq 'node_modules' -or $n.StartsWith('.')) { continue }
        try { if ([IO.File]::GetAttributes($s) -band $skip) { continue } } catch { continue }
        $q.Enqueue(@($s, ($lv + 1)))
      }
    }
  }
  if ($sw.Elapsed.TotalSeconds -ge $lim) { [void]$where.Add("(dừng sau $lim giây, chưa tìm hết)") }
  @{ Found = $found; Where = @($where) }
}

# thu muc dung duoc cho repo $Repo? @{Ok; Clone; Path; Why}
function Test-SyncFolder([string]$Path, [string]$Repo) {
  $p = $Path.Trim().Trim('"', "'").Trim()
  if (-not $p -or $p -notmatch '\A([A-Za-z]:\\|\\\\)') { return @{ Ok = $false; Why = 'cần đường dẫn đầy đủ, ví dụ C:\Users\ten\Desktop\du-an' } }
  # ky tu Windows khong cho trong ten (ca hai ban PowerShell); ':' chi duoc sau ky tu o dia
  if ($p -match '[<>|?*"\x00-\x1f]' -or $p.Substring(2).Contains(':')) { return @{ Ok = $false; Why = 'đường dẫn không hợp lệ' } }
  try { $p = [IO.Path]::GetFullPath($p) } catch { return @{ Ok = $false; Why = 'đường dẫn không hợp lệ' } }
  if (Test-Path -LiteralPath $p -PathType Leaf) { return @{ Ok = $false; Why = 'đây là một file, không phải thư mục' } }
  if (-not (Test-Path -LiteralPath $p)) { return @{ Ok = $true; Clone = $true; Path = $p } }
  if (Test-Path -LiteralPath (Join-Path $p '.git')) {
    $k = Get-RepoKey (Get-GitDirOrigin $p)
    if ($k -eq $Repo) { return @{ Ok = $true; Clone = $false; Path = $p } }
    if (-not $k) { return @{ Ok = $false; Why = 'thư mục này là git nhưng origin không phải repo GitHub' } }
    return @{ Ok = $false; Why = "đây là repo $k, không phải $Repo" }
  }
  if (@(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Select-Object -First 1).Count -eq 0) { return @{ Ok = $true; Clone = $true; Path = $p } }
  @{ Ok = $false; Why = 'thư mục này không phải git (và không trống nên không tải vào đây được)' }
}

# hoi nguoi dung thu muc cho mot project cua box. Tra ve @{Ok; Clone; Path}, '' = bo qua project nay, $null = het dau vao (dung hoi)
function Select-SyncFolder($M, $Cands) {
  $repo = [string]$M.repo; $name = [string]$M.name
  $cands = @(@($Cands) | Where-Object { $_ })
  while ($true) {
    if ($cands.Count -eq 1) {
      $a = Read-SyncLine "Đã có $repo ở $($cands[0]), dùng thư mục này? (Enter = có, n = không): "
      if ($null -eq $a) { return $null }
      if ($a.Trim() -match '\A(?i)(|y|yes|c|co|có)\z') { $pick = $cands[0] } else { $cands = @(); continue }
    } elseif ($cands.Count -gt 1) {
      Write-Host "Có $($cands.Count) bản $repo trên máy này:"
      for ($i = 0; $i -lt $cands.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $cands[$i]) }
      $a = Read-SyncLine 'Chọn số (0 = dùng thư mục khác, Enter = bỏ qua project này): '
      if ($null -eq $a) { return $null }
      $a = $a.Trim()
      if ($a -eq '') { return '' }
      if ($a -eq '0') { $cands = @(); continue }
      if ($a -notmatch '\A\d{1,3}\z' -or [int]$a -lt 1 -or [int]$a -gt $cands.Count) { Write-Host '  Số không hợp lệ, gõ lại.'; continue }
      $pick = $cands[[int]$a - 1]
    } else {
      $def = Join-Path (Get-SyncDesktop) $name
      $a = Read-SyncLine "Tải $name ($repo) về thư mục nào? (Enter = $def; hoặc dán đường dẫn thư mục đã có; - = bỏ qua): "
      if ($null -eq $a) { return $null }
      $a = $a.Trim()
      if ($a -eq '-') { return '' }
      $pick = if ($a) { $a } else { $def }
    }
    $v = Test-SyncFolder $pick $repo
    if ($v.Ok) { return $v }
    Write-Host "  $($v.Why). Chọn thư mục khác."
    $cands = @()
  }
}

# them $Path vao syncRepos trong config.json: chi chen dung mot muc, giu nguyen cac khoa va cach trinh bay khac; ghi bang file tam roi thay
function Add-SyncRepoConfig([string]$Path) {
  if ($CfgBroken) { throw "file cấu hình $ConfigFile bị hỏng, sửa tay trước" }
  $b = if (Test-Path -LiteralPath $ConfigFile) { [IO.File]::ReadAllBytes($ConfigFile) } else { [byte[]]@() }
  $bom = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF   # ReadAllText bo BOM nen phai doc byte
  # giai ma nghiem ngat: file khong phai UTF-8 thi khong bao gio ghi de (se lam hong chu co dau)
  try { $raw = if ($bom) { (New-Object Text.UTF8Encoding($false, $true)).GetString($b, 3, $b.Length - 3) } else { (New-Object Text.UTF8Encoding($false, $true)).GetString($b) } }
  catch { throw 'config.json không phải UTF-8, lưu lại dạng UTF-8 rồi chạy lại' }
  $js = ConvertTo-JsonStr $Path
  $m = [regex]::Match($raw, '"syncRepos"\s*:\s*\[')
  $mv = [regex]::Match($raw, '"syncRepos"\s*:\s*(null|true|false|-?[0-9][0-9.eE+-]*|"(?:[^"\\]|\\.)*")')   # khong phai danh sach: thay bang danh sach (chi giu mot chuoi cu)
  if (-not $m.Success -and $mv.Success) {
    $v = $mv.Groups[1].Value; $arr = if ($v.StartsWith('"')) { $v + ', ' + $js } else { $js }
    $new = $raw.Substring(0, $mv.Groups[1].Index) + '[' + $arr + ']' + $raw.Substring($mv.Groups[1].Index + $v.Length)
  } elseif ($m.Success) {
    $inStr = $false; $esc = $false; $last = -1
    for ($i = $m.Index + $m.Length; $i -lt $raw.Length; $i++) {
      $ch = $raw[$i]
      if ($inStr) { if ($esc) { $esc = $false } elseif ($ch -eq '\') { $esc = $true } elseif ($ch -eq '"') { $inStr = $false; $last = $i }; continue }
      if ($ch -eq '"') { $inStr = $true } elseif ($ch -eq ']') { break } elseif (-not [char]::IsWhiteSpace($ch)) { $last = $i }
    }
    if ($i -ge $raw.Length) { throw 'mục syncRepos trong config.json không đọc được' }
    $new = if ($last -lt 0) { $raw.Substring(0, $i) + $js + $raw.Substring($i) } else { $raw.Substring(0, $last + 1) + ', ' + $js + $raw.Substring($last + 1) }
  } elseif ($raw.Trim()) {
    $e = $raw.LastIndexOf('}'); if ($e -lt 0) { throw 'config.json không phải một đối tượng JSON' }
    $body = $raw.Substring(0, $e).TrimEnd()
    $new = $body + $(if ($body.EndsWith('{')) { '' } else { ',' }) + ' "syncRepos": [' + $js + ']' + $raw.Substring($body.Length)
  } else { $new = '{ "syncRepos": [' + $js + '] }' + "`r`n" }
  $chk = $new | ConvertFrom-Json
  if (-not (@($chk.syncRepos) -contains $Path)) { throw 'không ghi được syncRepos' }
  $dir = Split-Path -Parent $ConfigFile; if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
  $tmp = $ConfigFile + '.fcode-tmp-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  try {
    [IO.File]::WriteAllText($tmp, $new, (New-Object Text.UTF8Encoding($bom)))
    if (Test-Path -LiteralPath $ConfigFile) { [IO.File]::Replace($tmp, $ConfigFile, [NullString]::Value) } else { [IO.File]::Move($tmp, $ConfigFile) }
  } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

# Ten goi (alias) cua project: server FCode giu trong prefs.json canh config.json tren box; laptop chi doc (qua lenh 'scan' / 'projects' da co)
# va nho ban sao o %LOCALAPPDATA%\fcode\prefs.json. Box khong toi duoc thi dung ban sao; thieu hay hong file = khong co ten goi, khong bao gio la loi.
function Get-PrefsPath { Join-Path $env:LOCALAPPDATA 'fcode\prefs.json' }
# bang @{ ten project = chuoi } cua mot muc trong ban sao ('aliases': ten that -> ten goi; 'repos': ten that -> owner/repo); gi khac chuoi thi bo
function Get-PrefsMap([string]$Field) {
  $h = @{}
  try {
    $o = [IO.File]::ReadAllText((Get-PrefsPath)) | ConvertFrom-Json
    $m = $o.$Field
    if ($m -is [Management.Automation.PSCustomObject]) { foreach ($p in $m.PSObject.Properties) { if ($p.Value -is [string] -and $p.Value.Trim()) { $h[$p.Name] = $p.Value } } }
  } catch { }
  $h
}
function Get-ProjectAliases { Get-PrefsMap 'aliases' }   # @{ ten that = ten goi }
function Get-PrefsNames {   # ten that cua cac project tren box (ban sao lan hoi box gan nhat)
  try { @(([IO.File]::ReadAllText((Get-PrefsPath)) | ConvertFrom-Json).names | Where-Object { $_ -is [string] -and $_ }) } catch { @() }
}
function Save-PrefsCache($Prefs) {   # $null (box khong tra loi) thi giu ban cu
  if ($null -eq $Prefs) { return }
  try { Write-PhienText (Get-PrefsPath) ($Prefs | ConvertTo-Json -Compress -Depth 5) } catch { }
}
# ten that -> chinh no (ten that luon thang); ten goi, khong phan biet hoa thuong -> ten that; con lai giu nguyen (thong bao "khong thay project" van hien)
function Resolve-ProjectName([string]$Name, [string[]]$Known = @()) {
  if (-not $Name) { return $Name }
  $al = Get-ProjectAliases
  foreach ($k in (@($Known) + @($al.Keys))) { if ($k -ieq $Name) { return $Name } }
  foreach ($k in $al.Keys) { if ($al[$k] -ieq $Name) { return [string]$k } }
  $Name
}
# "ten goi (ten)" khi co ten goi; ky tu dieu khien va dinh dang (\p{Cc}, \p{Cf}: C0, C1, dao chieu chu) trong ten goi thanh '?'.
# $Dir (thu muc tren laptop): ten thu muc khac ten project tren box thi tim ten goi qua repo GitHub cua thu muc do
function Format-ProjectName([string]$Name, [string]$Dir = '') {
  $al = Get-ProjectAliases
  $real = $Name
  if (-not $al.ContainsKey($Name) -and $Dir -and $al.Count) {
    $repo = Get-LocalRepoKey $Dir
    if ($repo) { $rp = Get-PrefsMap 'repos'; foreach ($k in $rp.Keys) { if ($rp[$k] -eq $repo -and $al.ContainsKey($k)) { $real = [string]$k; break } } }
  }
  if ($al.ContainsKey($real)) { ($al[$real] -replace '[\p{Cc}\p{Cf}]', '?') + " ($Name)" } else { $Name }
}
# ten project tren box -> khoa cua Get-PhienProjects (thu muc cung ten, neu khong thi thu muc co cung repo GitHub theo ban sao); $null neu khong co
function Get-PhienKeyOf([string]$BoxName, $Projs) {
  $n = $BoxName.ToLowerInvariant()
  if ($Projs.Contains($n)) { return $n }
  $repo = (Get-PrefsMap 'repos')[$BoxName]
  if ($repo) { foreach ($k in $Projs.Keys) { if ((Get-LocalRepoKey $Projs[$k]) -eq $repo) { return [string]$k } } }
  $null
}
# project cua box (ten + URL origin + ten goi): hoi box mot lan (han 60 giay, khong phai 900 giay cua mot dot chep phien).
# $null neu khong doc duoc. Cung cap nhat ban sao ten goi.
function Get-BoxProjects {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $script:PhienDeadline = [DateTime]::UtcNow.AddSeconds([Math]::Min(60, (Get-PhienLimitSec $false))); $bp = Get-BoxJson (Invoke-BoxPy 'projects' ([byte[]]@())) } catch { $bp = $null } finally { $ErrorActionPreference = $old; $script:PhienDeadline = $null }
  if ($bp) { Save-PrefsCache $bp.prefs }
  $bp
}
# doi tham so project (ten goi hoac ten that) ra ten that. $Ask: ten la ma chua biet (khong nam trong $Known, khong la ten goi trong ban sao) thi hoi box mot lan roi thu lai
function Resolve-ProjectArg([string]$Name, [string[]]$Known, [bool]$Ask) {
  $r = Resolve-ProjectName $Name $Known
  if ($Ask -and $r -ceq $Name -and -not @($Known | Where-Object { $_ -ieq $Name }).Count) {
    Write-Host 'Đang hỏi box tên gọi của các project...'
    [void](Get-BoxProjects)
    $r = Resolve-ProjectName $Name (@($Known) + @(Get-PrefsNames))   # the names the box just reported count as real names too
  }
  $r
}

# project cua box (ten + URL origin) chua co trong syncRepos -> tim / hoi / tai, them vao syncRepos
function Add-SyncMissing {
  if ($env:FCODE_SYNC_REPOS) { return }   # danh sach dat tam cho lan chay nay: khong tim, khong ghi config
  Write-Host 'Đang hỏi box danh sách project...'
  $bp = Get-BoxProjects
  if (-not $bp) { Write-Host 'cảnh báo: không đọc được danh sách project trên box; chỉ cập nhật các project đã có trên laptop.'; return }
  $have = @{}; foreach ($r in $SyncRepos) { $k = Get-LocalRepoKey $r; if ($k) { $have[$k] = $true } }
  $miss = @(@($bp.projects) | Where-Object { $_ -and $_.repo -and -not $have.ContainsKey([string]$_.repo) })
  if (-not $miss.Count) { return }
  Write-Host "Box có $($miss.Count) project chưa có trên laptop:"
  foreach ($m in $miss) { Write-Host "  $(Format-ProjectName ([string]$m.name))  $($m.origin)" }
  $want = @{}; foreach ($m in $miss) { $want[[string]$m.repo] = $true }
  $f = Find-LocalClones $want
  Write-Host ('Đã tìm bản có sẵn trong: ' + ($f.Where -join '; '))
  $base = if ($env:FCODE_GITHUB_BASE) { $env:FCODE_GITHUB_BASE.TrimEnd('/', '\') } else { 'https://github.com' }
  foreach ($m in $miss) {
    Write-Host ''
    Write-Host "== $(Format-ProjectName ([string]$m.name)) ($($m.repo))"
    $v = Select-SyncFolder $m $f.Found[[string]$m.repo]
    if ($null -eq $v) { Write-Host 'Không đọc được câu trả lời: các project còn lại để lần sau.'; break }
    if ($v -is [string]) { Write-Host '  bỏ qua project này'; continue }
    if ($v.Clone) {
      Write-Host "  Đang tải $($m.repo) về $($v.Path)..."
      $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      try { $o = & git -c "core.hooksPath=$script:HooksDir" clone -q -- "$base/$($m.repo).git" $v.Path 2>&1; $gc = $LASTEXITCODE } catch { $o = @("$($_.Exception.Message)"); $gc = -1 } finally { $ErrorActionPreference = $old }
      if ($gc -ne 0) { Write-Host ('  lỗi: không tải được: ' + (Get-GitError ([pscustomobject]@{ Code = $gc; Out = ''; Err = (@($o | ForEach-Object { "$_" }) -join "`n") }))); continue }
    }
    if (@($SyncRepos | Where-Object { ([string]$_).TrimEnd('\', '/') -eq $v.Path.TrimEnd('\', '/') }).Count) { continue }
    try { Add-SyncRepoConfig $v.Path } catch { Write-Host ('  lỗi: chưa thêm được vào ' + $ConfigFile + ': ' + $_.Exception.Message); continue }
    $script:SyncRepos = @($script:SyncRepos) + @($v.Path)
    Write-Host "  Đã thêm $($v.Path) vào syncRepos."
  }
}

function Invoke-Sync {
  $env:GIT_TERMINAL_PROMPT = '0'; $env:GH_PROMPT_DISABLED = '1'
  $fetchFail = 0; $updated = 0; $current = 0; $skipped = 0; $waiting = 0
  # thu muc hooks rong, tao moi moi lan chay va kiem tra that su rong
  $script:HooksDir = Join-Path ([IO.Path]::GetTempPath()) ('fcode-nohooks-' + [guid]::NewGuid().ToString('N'))
  try {
    [void](New-Item -ItemType Directory -Path $script:HooksDir -ErrorAction Stop)
    if (@(Get-ChildItem -LiteralPath $script:HooksDir -Force).Count -ne 0) { throw 'thư mục không rỗng' }
  } catch { Write-Host ('lỗi: không tạo được thư mục hooks rỗng: ' + $_.Exception.Message); return 1 }
  try {
  Add-SyncMissing
  if ($SyncRepos.Count -eq 0) {
    Write-Host "Chưa có repo nào, thêm vào $ConfigFile"
    Write-Host '  (mục syncRepos: danh sách thư mục project trên máy này)'
    return 0
  }
  foreach ($repo in $SyncRepos) {
    Write-Host ''
    Write-Host ("== " + (Format-ProjectName (Split-Path $repo -Leaf) $repo))
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
  $target = Join-Path $IpaDir 'fcode.ipa'
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
        Clear-ReadOnly $target
        # thay truc tiep, khong giu ban sao: File.Replace (khong co file backup) la mot buoc cua he dieu hanh;
        # neu loi thi fcode.ipa cu van nguyen
        if ($hadTarget) { [IO.File]::Replace($tmp, $target, [NullString]::Value) }
        else { [IO.File]::Move($tmp, $target) }
      } catch {
        Write-IpaError 'không đặt được file mới. File cũ được giữ nguyên. Nếu Sideloadly hay chương trình khác đang mở fcode.ipa, hãy đóng nó rồi chạy lại.' $_.Exception.Message
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

# duong dan ssh.exe: config (khoa ssh, de thu) > PATH > "ssh"
function Get-SshExe {
  $p = Get-Cfg 'ssh' ''
  if ($p -and (Test-Path -LiteralPath $p)) { return $p }
  $c = Get-Command ssh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return $c.Source }
  'ssh'
}

# In mot phan cua bang help: co mau chi khi dau ra la cua so that (khong bi chuyen huong / pipe), nen khong bao gio co ky tu ESC trong van ban
function Write-HelpPart([string]$Text, [string]$Color, [switch]$NoNewline) {
  if ($Color -and -not [Console]::IsOutputRedirected) { Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewline } else { Write-Host $Text -NoNewline:$NoNewline }
}
# mot dong "lenh  mo ta": cot lenh rong $W; lenh dai hon cot thi mo ta xuong dong duoi
function Write-HelpRow([string]$Cmd, [string]$Desc, [int]$W) {
  if ($Cmd.Length -gt $W) { Write-HelpPart "  $Cmd" 'Green'; Write-Host ((' ' * ($W + 3)) + $Desc); return }
  Write-HelpPart "  $Cmd" 'Green' -NoNewline
  Write-Host ((' ' * ($W - $Cmd.Length + 1)) + $Desc)
}

# fcode help: bang tong quan, mot dong cho moi lenh. fcode help <lenh>: chi tiet cua lenh do.
# Du lieu: dong khong co @@ la tieu de nhom, "lenh@@mo ta" la mot dong; trong chi tiet: "#" tieu de, ">" lenh, "lenh@@mo ta" la bang thang cot, con lai la chu thuong (da ngat dong <= 78 ky tu).
function Show-Help([string]$Topic = '') {
  $overview = @(
    'Vào phiên trên box (chi tiết: fcode help vao)',
    'fcode@@Xem danh sách phiên, gõ số để vào',
    'fcode <số hoặc tên phiên>@@Vào thẳng một phiên',
    'fcode --list@@Chỉ in danh sách (viết tắt: -l)',
    'fcode new@@Mở một phiên mới trên box',
    'Dự án',
    'fcode sync@@Cập nhật project từ GitHub',
    'fcode add <chủ/repo> [tên]@@Thêm project GitHub vào box',
    'Deploy (cổng deploy trên VPS)',
    'fcode deploy <tên> <lệnh> [đối số]@@Điều khiển cổng deploy',
    'fcode deploy add <chủ/repo> <tên> <draft.json>@@Đăng ký project vào cổng deploy',
    'fcode deploy allow <tên> [root]@@Cho khoá box dùng project (root: +trust)',
    'fcode deploy disallow <tên>@@Thu hồi quyền của khoá box',
    'Chuyển VPS sang máy mới (chi tiết: fcode help move)',
    'fcode move check@@Chỉ đọc: máy hiện tại chuyển được chưa',
    'fcode move plan | copy | cutover@@Chuyển cả VPS sang máy mới',
    'fcode move finish | back | abort | status@@Kết thúc, quay lại, hủy, xem',
    'Đồng bộ phiên omp (laptop <-> box)',
    'fcode phien [project]@@Đồng bộ phiên hai chiều',
    'fcode phien --thu [project]@@Chạy thử, không chép gì',
    'fcode phien tu-dong bat|tat@@Bật / tắt tự đồng bộ mỗi 10 phút',
    'fcode phien <project> --nhanh@@Bản nhanh cho hook (--nen: chờ 35 giây)',
    'fcode moc bat|tat|trang-thai@@Hook đồng bộ khi gõ omp/claude/codex',
    'App và thiết bị',
    'fcode ipa@@Tải bản FCode mới nhất (Downloads)',
    'fcode pair [tên thiết bị]@@Ghép iPhone mới (mã QR)',
    'Khác',
    'fcode help [lệnh]@@Bảng này, hoặc chi tiết một lệnh'
  )
  $topics = @{
    vao = @(
      '#Vào phiên trên box',
      '>fcode',
      '    Xem danh sách phiên đang chạy trên box, gõ số để vào',
      '    (gõ 0 để mở phiên mới).',
      '>fcode <số hoặc tên phiên>',
      '    Vào thẳng một phiên (tên có thể gõ phần đầu). Gõ tên project hoặc',
      '    tên gọi (alias) của nó cũng được; tên mà box không biết thì fcode',
      '    hỏi box một lần xem có phải tên gọi mới đặt trong app.',
      '    Thoát mà không tắt phiên: Ctrl+B rồi D.',
      '>fcode --list',
      '    Chỉ in danh sách phiên, không vào (viết tắt: fcode -l).',
      '',
      '#Ví dụ',
      '  fcode 2',
      '  fcode ten-phien',
      '  fcode -l'
    )
    new = @(
      '#fcode new',
      '  Mở một phiên MỚI trên box (như nút "+" trong app): chọn project,',
      '  chọn omp / claude / codex, rồi vào luôn phiên đó.',
      '  Gõ fcode rồi chọn 0 cũng được.',
      '  Bấm Enter ở bất kỳ câu hỏi nào để quay lại.',
      '',
      '#Ví dụ',
      '  fcode new'
    )
    sync = @(
      '#fcode sync',
      '  Cập nhật các project trên máy này từ GitHub, báo nhánh box chờ',
      '  merge và PR đang mở.',
      '',
      '#Ví dụ',
      '  fcode sync'
    )
    ipa = @(
      '#fcode ipa',
      '  Tải bản FCode mới nhất về thư mục Downloads để kéo vào Sideloadly.',
      '',
      '#Ví dụ',
      '  fcode ipa'
    )
    add = @(
      '#fcode add <chủ/repo> [tên]',
      '  Thêm một project GitHub vào box để omp làm việc và app FCode hiện',
      '  trong danh sách.',
      '  Nếu token GitHub của box ghi được repo thì xong ngay; nếu không,',
      '  lệnh hướng dẫn bạn dán một khoá vào trang GitHub của repo (một lần',
      '  cho mỗi repo).',
      '',
      '#Ví dụ',
      '  fcode add ten-tai-khoan/ten-repo',
      '  fcode add ten-tai-khoan/ten-repo ten-ngan'
    )
    deploy = @(
      '#fcode deploy <tên> <lệnh> [đối số]',
      '  Điều khiển cổng deploy chung trên VPS (qua ssh; máy ssh lấy từ',
      '  deployHost trong file cấu hình, mặc định contabo). Lệnh được chuyển',
      '  nguyên cho cổng, kết quả in ra ngay và fcode thoát với đúng mã của',
      '  cổng (70 = cần người xử lý).',
      '',
      '#Lệnh (viết sau fcode deploy <tên>)',
      'status [id]@@Xem trạng thái',
      'deploy <sha>@@Deploy tay một commit',
      'retry [sha]@@Thử lại commit mới nhất (hoặc <sha>)',
      'pause@@Tạm dừng deploy tự động',
      'resume@@Bật lại deploy tự động',
      'trust on i-understand-root | off@@Cho phép chạy quyền root (xem Cảnh báo)',
      'logs [id] [số dòng]@@Xem nhật ký',
      'recheck@@Kiểm tra lại sau khi đã xử lý lỗi 70',
      'compact@@Dọn gọn nhật ký của cổng',
      'inventory <draft.json>@@In hiện trạng VPS theo bản nháp',
      'register <sha256> <draft.json>@@Đăng ký tay (sha256 của file nháp)',
      'approve <sha> now|idle|skip@@Trả lời khi cổng hỏi (app đang bận)',
      '',
      '  deploy <sha> cũng tạm dừng deploy tự động; gõ resume để bật lại.',
      '',
      '#Đăng ký project mới',
      '>fcode deploy add <chủ/repo> <tên> <draft.json>',
      '    Đăng ký một project vào cổng deploy: dùng lại (chỉ khi khoá đó chỉ',
      '    đọc) hoặc tạo khoá chỉ đọc của repo, từ chối nếu repo còn lượt',
      '    Actions đang chạy, in hiện trạng VPS (inventory), chờ bạn gõ YES',
      '    rồi mới đăng ký. Cổng báo cần người xử lý thì in status và nhắc',
      '    lệnh recheck.',
      '    Tên: chữ thường, số, dấu -, 2 đến 28 ký tự, bắt đầu bằng chữ.',
      '    "register" gõ tay cũng kiểm tra Actions và hỏi YES như lệnh add.',
      '',
      '#Cho khoá của box dùng project',
      '>fcode deploy allow <tên> [root]',
      '    Duyệt project cho khoá của box (chạy trên laptop, không hỏi lại).',
      '    "root" thêm quyền trust on i-understand-root: in một dòng cảnh báo',
      '    vàng rồi gửi. Cổng từ chối tên dành riêng, deal-sync, vps-scraper',
      '    (mã 65).',
      '>fcode deploy disallow <tên>',
      '    Thu hồi quyền đó. Project vẫn nằm trong cổng và vẫn deploy; muốn',
      '    bỏ root thì chạy thêm  fcode deploy <tên> trust off.',
      '',
      '#Trả lời khi app đang bận',
      '>fcode deploy <tên> approve <sha> now|idle|skip',
      '    App đang bận thì cổng không tự deploy mà hỏi bạn (deploy báo dòng',
      '    GATE_ASK, status có dòng ASK). Trả lời: now = deploy ngay (chấp',
      '    nhận bị gián đoạn), idle = đợi lúc app rảnh, skip = bỏ qua bản này.',
      '    <sha> là đủ 40 ký tự ghi ở dòng ASK. Chỉ gõ khi chủ đã nói rõ câu',
      '    trả lời. Máy coder không có lệnh này.',
      '',
      '#Cảnh báo',
      '  "trust on" in cảnh báo trước khi gửi: ai merge được vào nhánh đó đều',
      '  có quyền root trên VPS và đọc được token GitHub của cổng.',
      '',
      '#Ví dụ',
      '  fcode deploy task status',
      '  fcode deploy task deploy <sha>',
      '  fcode deploy add ten-tai-khoan/ten-repo ten-ngan ten-ngan.draft.json'
    )
    move = @(
      '#fcode move <lệnh>',
      '  Chuyển mọi thứ đang chạy trên VPS sang một máy mới, chủ chỉ trả lời',
      '  có / không (hoặc gõ YES). Trạng thái nằm ở',
      '  %USERPROFILE%\.fcode\move\state.json; chạy lại lệnh là tiếp tục.',
      '',
      '#Lệnh',
      'check@@Chỉ đọc: liệt kê điểm sẽ bị từ chối, câu hỏi, cảnh báo',
      'plan <máy mới> --addr <địa chỉ>@@Kiểm tra máy mới, lập danh sách chuyển',
      'copy@@Chép trước khi máy cũ vẫn chạy (chạy lại = làm mới)',
      'cutover@@Dừng, chép nốt, bật máy mới, chuyển tên miền',
      'finish@@Kết thúc: không quay lại máy cũ được nữa',
      'back@@Chuyển ngược về máy cũ',
      'abort@@Hủy lần chuyển khi máy cũ đang phục vụ',
      'status [--rebuild <cũ> <mới>]@@Xem trạng thái, hoặc dựng lại trạng thái',
      '',
      '#Lưu ý',
      '  --old-addr <host[:port]>: địa chỉ máy mới dùng để vào máy cũ (mặc định',
      '  địa chỉ của máy cũ). --map <file>: dòng map thêm vào danh sách chuyển.',
      '  Mã thoát: 0 xong, 1 lỗi (chạy lại được), 10 đã quay về máy cũ, 65 bị',
      '  từ chối, 70 cần người xem, 75 đang bận.',
      '',
      '#Ví dụ',
      '  fcode move check',
      '  fcode move plan newbox --addr 203.0.113.20',
      '  fcode move copy',
      '  fcode move cutover'
    )
    pair = @(
      '#fcode pair [tên thiết bị]',
      '  Tạo mã ghép (kèm mã QR) để ghép một iPhone mới với server FCode.',
      '  Mã dùng 1 lần và hết hạn nhanh.',
      '  Tên thiết bị: tối đa 64 ký tự, không bắt đầu bằng dấu -.',
      '',
      '#Ví dụ',
      '  fcode pair',
      '  fcode pair iPhone của Mẹ'
    )
    phien = @(
      '#Đồng bộ phiên chat omp giữa laptop và box',
      '>fcode phien [project]',
      '    Đồng bộ hai chiều (mọi project, hoặc chỉ một project): phiên nào',
      '    chỉ có ở một bên thì chép sang bên kia, phiên đã đi tiếp ở một bên',
      '    thì cập nhật bên còn lại. Không xoá gì. Sau đó omp trên mỗi máy tự',
      '    thấy phiên đó trong /resume, omp -c và omp -r.',
      '    Cùng lượt này đồng bộ cả ghi chú ở thư mục gốc project',
      '    (HANDOFF*.md, CLAUDE.md, AGENTS.md, WORKFLOW.md, agent_state.md,',
      '    TASK.md, CLAUDE.local.md) khi git không theo dõi chúng; file nào',
      '    hai máy cùng sửa thì giữ nguyên và báo.',
      '    [project] là tên project hoặc tên gọi (alias) đặt trong app FCode;',
      '    tên gọi mới đặt được cập nhật ở lần fcode phien / fcode sync kế tiếp,',
      '    hoặc ngay khi gõ một tên mà box không biết (hỏi box một lần).',
      '>fcode phien --thu [project]',
      '    Chạy thử: chỉ liệt kê những phiên sẽ được chép đi đâu, không chép',
      '    gì (chỉ ghi lại giờ vừa kết nối box).',
      '>fcode phien tu-dong bat    |    fcode phien tu-dong tat',
      '    Bật / tắt tự động đồng bộ phiên mỗi 10 phút, chạy ngầm (không hiện',
      '    cửa sổ), chỉ khi vào được box, và chỉ mở kết nối lần đầu hoặc khi',
      '    lần mở trước đã cách từ 40 phút.',
      '>fcode phien tu-dong trangthai',
      '    Xem tự động đồng bộ đang bật hay tắt.',
      '>fcode phien <project> --nhanh',
      '    Bản nhanh cho hook (fcode moc): chỉ một project, vào box bằng ssh',
      '    (không vào được box thì báo lỗi), tối đa 20 giây, đang có lượt đồng',
      '    bộ khác thì bỏ qua. Lần chạy nhanh chưa xong sau 30 giây thì bị',
      '    ngắt hẳn và báo lỗi (fcode phien chạy tay thì không bị ngắt như',
      '    vậy).',
      '>fcode phien <project> --nhanh --nen',
      '    Như --nhanh nhưng chờ 35 giây rồi mới đồng bộ (hook dùng sau khi',
      '    omp / claude / codex thoát).',
      '',
      '#Ví dụ',
      '  fcode phien',
      '  fcode phien deal-sync',
      '  fcode phien --thu',
      '  fcode phien tu-dong bat',
      '  fcode phien deal-sync --nhanh',
      '  fcode phien deal-sync --nhanh --nen'
    )
    moc = @(
      '#fcode moc bat    |    fcode moc tat    |    fcode moc trang-thai',
      '  Bật / tắt / xem hook trong profile PowerShell: gõ omp, claude hoặc',
      '  codex trong thư mục một project (có trong syncRepos) thì fcode đồng',
      '  bộ nhanh phiên trước và sau khi chạy (tối đa khoảng 20 giây; không',
      '  vào được box thì báo một dòng lỗi).',
      '  Phiên Claude Code / Codex chưa được chép giữa hai máy, chỉ phiên omp',
      '  và ghi chú project.',
      '',
      '#Tắt hook trong cửa sổ này',
      '  Gõ $env:FCODE_MOC = ''0'' (đến khi gõ Remove-Item Env:FCODE_MOC hoặc',
      '  đóng cửa sổ).',
      '',
      '#Lưu ý',
      '  Hook là hàm bọc nên không chuyển đúng hoàn toàn các tham số kiểu --',
      '  và -x:giá-trị, cũng không để lại lỗi của chương trình trong $?; những',
      '  lúc cần đúng tuyệt đối, chạy thẳng claude.exe / codex.exe / omp.exe.',
      '',
      '#Ví dụ',
      '  fcode moc bat'
    )
    help = @(
      '#fcode help [lệnh]',
      '  Không có lệnh: in bảng tổng quan (cũng là fcode -h, fcode --help,',
      '  fcode /?). Có lệnh: in chi tiết của lệnh đó.',
      '  Các lệnh có chi tiết: vao, new, sync, ipa, add, deploy, move, pair,',
      '  phien, moc, help.',
      '',
      '#Cấu hình riêng của máy',
      "  $ConfigFile",
      '',
      '#Ví dụ',
      '  fcode help',
      '  fcode help deploy'
    )
  }
  $alias = @{ '-l' = 'vao'; '--list' = 'vao'; list = 'vao'; fcode = 'vao'; '-h' = 'help'; '--help' = 'help'; '/?' = 'help' }
  $key = $Topic.Trim().ToLowerInvariant()
  if ($alias.ContainsKey($key)) { $key = $alias[$key] }
  if ($key -and -not $topics.ContainsKey($key)) {
    Write-Host "Không có lệnh '$($Topic -replace '[\x00-\x1f\x7f]', '?')'. Dưới đây là các lệnh có sẵn:"
    Write-Host ''
    $key = ''
  }
  if ($key) {
    $lines = @($topics[$key])
    $w = 0; foreach ($l in $lines) { if ($l -match '@@') { $w = [Math]::Max($w, $l.Split(@('@@'), 2, [StringSplitOptions]::None)[0].Length) } }
    $w += 1
    foreach ($l in $lines) {
      if ($l.StartsWith('#')) { Write-HelpPart $l.Substring(1) 'Cyan' }
      elseif ($l.StartsWith('>')) { Write-HelpPart ('  ' + $l.Substring(1)) 'Green' }
      elseif ($l -match '@@') { $p = $l.Split(@('@@'), 2, [StringSplitOptions]::None); Write-HelpRow $p[0] $p[1] $w }
      else { Write-Host $l }
    }
    return
  }
  Write-Host 'fcode - điều khiển box coding từ máy này'
  foreach ($l in $overview) {
    if ($l -match '@@') { $p = $l.Split(@('@@'), 2, [StringSplitOptions]::None); Write-HelpRow $p[0] $p[1] 36 }
    else { Write-Host ''; Write-HelpPart $l 'Cyan' }
  }
  Write-Host ''
  Write-Host 'Xem chi tiết: fcode help <lệnh>   (ví dụ: fcode help deploy)'
  Write-Host 'Tên project: gõ tên thật hoặc tên gọi (alias) đặt trong app đều được.'
  $cfg = "Cấu hình: $ConfigFile"
  if ($cfg.Length -le 80) { Write-Host $cfg }
}

# Chay script bash tren box. Tham so di CUNG script (dong "set -- '..'" dau payload, da kiem tra), khong bao gio nam tren dong lenh ssh.
function Invoke-BoxScript([string]$Script, [string[]]$ScriptArgs) {
  $pre = if ($ScriptArgs) { 'set -- ' + (($ScriptArgs | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' ') + "`n" } else { '' }
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pre + $Script))
  # script di qua stdin (dong lenh Windows bi gioi han ~8 KB); tren box luu ra file tam roi chay voi stdin = /dev/null
  $remote = 'f=$(mktemp) && base64 -di >$f && bash -l $f </dev/null; rc=$?; rm -f $f; exit $rc'
  $b64 | & (Get-SshExe) $box $remote
}

# ky tu dieu khien (ke ca xuong dong) khong bao gio duoc di vao tham so
function Test-HasControlChar([string]$s) { $s -match '[\x00-\x1f\x7f]' }

# chi de thu: FCODE_ADD_TIMEOUT_S / FCODE_ADD_KILL_AFTER_S (so nguyen duong 1-99999, khong co 0: watchdog tren box doc giay, 0 la het han ngay) thanh bien cho $FcodeAddRun
function Get-FcodeAddLimitVars {
  $o = ''
  foreach ($tv in 'FCODE_ADD_TIMEOUT_S', 'FCODE_ADD_KILL_AFTER_S') { $tx = [Environment]::GetEnvironmentVariable($tv); if ("$tx" -match '\A[1-9][0-9]{0,4}\z') { $o += "$tv=$tx`n" } }
  $o
}

# fcode add <owner/repo> [name]: them project vao box bang script da cai tren box (token GitHub cua box, khong thi khoa SSH rieng); xem $FcodeAddRun
# Neu GitHub chua co khoa cua box: in khoa cong khai + cac buoc, doi Enter, thu lai (toi da 3 lan).
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
  $max = 3
  for ($try = 1; $try -le $max; $try++) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
      # chi de thu: FCODE_ADD_SCRIPT doi duong dan script tren box; FCODE_ADD_TIMEOUT_S / FCODE_ADD_KILL_AFTER_S (chi chu so) doi han
      $run = $(if ("$env:FCODE_ADD_SCRIPT" -match '\A/[A-Za-z0-9_./-]{1,200}\z') { "FCODE_ADD_SCRIPT='$env:FCODE_ADD_SCRIPT'`n" } else { '' })
      $run += Get-FcodeAddLimitVars
      $run += $FcodeAddRun
      $lines = @(Invoke-BoxScript $run @($repo, $name) 2>&1 | ForEach-Object { "$_" })
      $code = $LASTEXITCODE
    } catch { $lines = @("$($_.Exception.Message)"); $code = 255 }
    finally { $ErrorActionPreference = $old }
    $rules = $false; $bad = 0; $seen = @{}; $pub = ''; $detail = ''; $hookD = ''
    foreach ($l in $lines) {
      if ($l -notmatch '^R (\S+)\s*(.*)$') { continue }
      $c = $Matches[1]; $d = $Matches[2]; $seen[$c] = $true
      # -Wildcard: DIR_* / HOOK_FAIL* / CLEANUP* khop theo tien to (ten ma tren box co the doi chut); cac nhan khac khop dung ten
      switch -Wildcard ($c) {
        'NO_SCRIPT'     { Write-Host "lỗi: box chưa có lệnh thêm dự án (fcode-add; bản FCode trên box đã cũ). Cập nhật box: ssh $box rồi chạy: cd ~/fcode-src && git pull && bash install.sh"; Write-Host "  Xong thì chạy lại: fcode add $repo $name" }
        'TOKEN_OK'      { if ($try -eq 1) { Write-Host '[1] Box dùng khoá GitHub sẵn có (token) cho repo này, không cần dán khoá' } }
        'TOKEN_FALLBACK' { Write-Host '[1] Khoá GitHub sẵn có của box không ghi được repo này, chuyển sang khoá SSH riêng cho repo' }
        'KEY_NEW'       { if ($try -eq 1) { Write-Host '[1] Đã tạo khoá SSH riêng cho repo này trên box' } }
        'KEY_EXISTS'    { if ($try -eq 1) { Write-Host '[1] Khoá SSH của repo này đã có trên box, dùng lại' } }
        'KEY_FAIL'      { Write-Host '[1] lỗi: box không tạo được khoá SSH.' }
        'ALIAS_ADDED'   { if ($try -eq 1) { Write-Host "[1] Đã khai báo kết nối GitHub riêng (github-$name) trong cấu hình SSH của box" } }
        'ALIAS_EXISTS'  { if ($try -eq 1) { Write-Host "[1] Kết nối GitHub riêng (github-$name) đã có trong cấu hình SSH của box" } }
        'ALIAS_FAIL'    { Write-Host '[1] lỗi: box không ghi được cấu hình SSH.' }
        'SSH_DETAIL'    { $detail = $d }
        'PUBKEY'        { $pub = $d }
        'READ_OK'       { if ($seen.ContainsKey('TOKEN_OK') -and -not $seen.ContainsKey('TOKEN_FALLBACK')) { Write-Host '[2] Box đọc được repo: OK' } else { Write-Host '[2] Box đọc được repo qua khoá SSH: OK' } }
        'WRITE_OK'      { Write-Host '[5] Box ghi được repo (đẩy thử một nhánh tạm rồi xoá ngay): OK' }
        'CLONED'        { Write-Host "[3] Đã tải repo về /data/workspace/$name" }
        'CLONE_EXISTS'  { Write-Host "[3] Repo đã có sẵn ở /data/workspace/$name, giữ nguyên" }
        'CLONE_FAIL'    { Write-Host '[3] lỗi: không tải được repo về box. Chạy lại sau ít phút.'; if ($d) { Write-Host "  (chi tiết: $d)" } }
        'DIR_*'         { }   # moi ma thoat 11: mot thong bao sau vong lap
        'HOOK_FAIL*'    { $hookD = $d }
        'HOOK_OK'       { Write-Host '[4] Đã cài hook chặn push thẳng lên main/master' }
        'HOOK_EXISTS'   { Write-Host '[4] Hook chặn push lên main/master đã có sẵn' }
        'CFG_ADDED'     { Write-Host "[6] Đã thêm '$name' vào danh sách project của FCode (có bản sao lưu config, không đụng project khác)" }
        'CFG_WARN*'     { Write-Host '[6] cảnh báo: đã thêm vào cấu hình FCode nhưng box chưa xác nhận ghi xuống đĩa (fsync); nếu box tắt đột ngột, chạy lại lệnh này'; $bad++ }
        'CFG_EXISTS'    { Write-Host "[6] '$name' đã có trong danh sách project của FCode" }
        'CFG_CONFLICT'  { Write-Host "lỗi: tên '$name' đang trỏ tới thư mục khác ($d). Đặt tên khác: fcode add $repo <tên>" }
        'CFG_BROKEN'    { Write-Host 'lỗi: file cấu hình FCode trên box (/data/home/.fcoding/config.json) bị hỏng hoặc không đọc được, nên chưa thêm project. Nhờ người quản lý box kiểm tra file đó rồi chạy lại.'; if ($d) { Write-Host "  (chi tiết: $d)" } }
        'V_BRANCH_OK'   { Write-Host "[7] Bản clone đang ở nhánh mặc định ($d): OK" }
        'V_BRANCH_BAD'  { Write-Host "[7] cảnh báo: bản clone không ở nhánh mặc định ($d)"; $bad++ }
        'V_PR_OK'       { Write-Host '[7] Xem được danh sách PR của repo (gh pr list): OK' }
        'V_PR_BAD'      { Write-Host '[7] cảnh báo: gh pr list chưa chạy được cho repo này (token của box thiếu quyền Pull requests?). Việc tải và đẩy code không bị ảnh hưởng.'; $bad++ }
        'V_HOOK_OK'     { Write-Host '[7] Hook chặn push lên main, vẫn cho push nhánh box/...: OK' }
        'V_HOOK_BAD'    { Write-Host "[7] cảnh báo: hook không chạy đúng ($d)"; $bad++ }
        'V_SERVER_OK'   { Write-Host '[7] Server FCode đã nạp cấu hình mới, không báo lỗi: OK' }
        'V_SERVER_BAD'  { Write-Host '[7] cảnh báo: server FCode báo lỗi khi nạp lại cấu hình'; $bad++ }
        'V_CFG_BAD'     { Write-Host '[7] cảnh báo: cấu hình FCode chưa đúng cho project này'; $bad++ }
        'V_EMPTY_REPO'  { Write-Host '[7] Repo còn trống (chưa có commit nào): bình thường với repo mới; lần đẩy đầu cần nhánh main trên GitHub (hoặc repo trong danh sách không có secret)' }
        'CLEANUP*'      { $br = $d.Trim() -replace '^refs/heads/', ''; Write-Host "cảnh báo: GitHub không cho box xoá nhánh thử $br ($($d.Trim())). Hãy xoá nhánh này trên GitHub: mở https://github.com/$repo/branches, tìm đúng nhánh $br, bấm biểu tượng thùng rác."; $bad++ }
        'NET_FAIL'      { Write-Host "lỗi: mạng từ box tới GitHub đang chập chờn nên chưa kiểm tra được. Đợi ít phút rồi chạy lại cùng lệnh: fcode add $repo $name"; if ($detail) { Write-Host "  (chi tiết: $detail)" } }
        'REPO_ARCHIVED' { Write-Host "[5] lỗi: repo này đã lưu trữ (archived) nên không ghi được. Vào Settings của repo để bỏ lưu trữ (Unarchive), hoặc chọn repo khác." }
        'NAME_USED'     { Write-Host "lỗi: tên '$name' đã được dùng cho khoá hoặc kết nối GitHub khác trên box (không phải repo này). Đặt tên khác: fcode add $repo <tên>" }
        'WRITE_BLOCKED' { Write-Host '[5] lỗi: khoá đã vào GitHub nhưng GitHub không cho box tạo nhánh thử box/... (thường do quy tắc bảo vệ nhánh của repo).'; Write-Host "    Nhờ chủ repo cho phép nhánh box/*, rồi chạy lại: fcode add $repo $name"; if ($detail) { Write-Host "  (chi tiết: $detail)" } }
        'RULES_YES'     { $rules = $true }
        'USAGE'         { Write-Host 'lỗi: thiếu tên repo hoặc tên project. Cách dùng: fcode add <chủ/repo> [tên]' }
        'BAD_ARGS'      { Write-Host 'lỗi: tên repo hoặc tên project không hợp lệ.' }
      }
    }
    # watchdog tren box: qua han -> TERM ca nhom, 30 giay sau KILL ca nhom (137)
    if ($code -eq 137) { Write-Host "lỗi: thêm dự án trên box chạy quá 10 phút nên đã bị dừng (mã $code). Chạy lại là an toàn: fcode add $repo $name"; return 1 }
    if ($code -eq 11) { Write-Host "Thư mục $name đã có trên box (hoặc không an toàn) — chọn tên khác: fcode add $repo <tên-khác>"; return 1 }
    if ($code -eq 25) { Write-Host 'lỗi: box không ghi được cấu hình đăng nhập GitHub cho repo này, nên chưa thêm project.'; return 1 }
    if ($code -eq 26) { Write-Host 'lỗi: cấu hình git trên box đang chuyển hướng địa chỉ GitHub (insteadOf / pushInsteadOf / pushurl) — cần gỡ trên box rồi chạy lại.'; return 1 }
    if ($code -eq 24) { Write-Host '[4] lỗi: không cài được chốt chặn push lên main, nên chưa thêm project.'; if ($hookD) { Write-Host "  (chi tiết: $hookD)" }; return 1 }
    if ($seen.Count -eq 0) {
      $d = ($lines | Where-Object { "$_".Trim() } | Select-Object -First 1)
      Write-IpaError "không nói chuyện được với box. Kiểm tra: gõ ssh $box có vào được không (alias trong ~/.ssh/config)." $d
      return 1
    }
    # loi can sua truoc (ten da dung, cau hinh hong, GitHub chan, mang, repo luu tru): thong bao cu the da in o tren, khong bao "chay lai cung lenh"
    if ($code -in 2, 3, 11, 20, 21, 22, 23, 24, 25, 26, 42, 43, 44) { return 1 }
    if ($code -eq 40 -or $code -eq 41) {
      # can dan khoa cong khai vao GitHub (nguoi dung tu dan; khong tu them bang token/API)
      Write-Host ''
      if ($code -eq 40) { Write-Host "GitHub chưa nhận khoá của box cho repo $repo (hoặc tên repo gõ chưa đúng). Làm một lần như sau:" }
      else { Write-Host 'GitHub đã nhận khoá nhưng khoá chưa có quyền GHI. Xoá khoá "fcode coder" cũ ở trang Deploy keys, rồi thêm lại đúng các bước sau:' }
      Write-Host "  Khoá của box (copy cả dòng): $pub"
      Write-Host "  1. Mở trang: https://github.com/$repo/settings/keys/new"
      Write-Host '  2. Dán khoá vào ô Key, đặt tên "fcode coder"'
      Write-Host '  3. TÍCH ô "Allow write access"'
      Write-Host '  4. Bấm Add key'
      Write-Host '  5. Quay lại đây bấm Enter'
      if ($detail) { Write-Host "  (chi tiết: $detail)" }
      if ($try -ge $max) {
        Write-Host ''
        Write-Host "Chưa xong sau $max lần thử, nên project CHƯA được thêm vào FCode (cấu hình giữ nguyên)."
        Write-Host "Khoá đã tạo sẵn trên box. Khi đã thêm khoá vào GitHub, chạy lại: fcode add $repo $name"
        return 1
      }
      Write-Host "Bấm Enter khi đã làm xong (lần thử $try/$max)..."
      try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { }   # bo cac phim go truoc luc cho
      $k = [Console]::In.ReadLine()
      if ($null -eq $k) { Write-Host "Không đọc được phím Enter. Làm các bước trên rồi chạy lại: fcode add $repo $name"; return 1 }
      Write-Host 'Đang kiểm tra lại...'
      continue
    }
    break
  }
  # them lai mot project da co (box chi tra CFG_EXISTS, thoat 0): xong, khong lam gi them
  if ($code -eq 0 -and $seen.ContainsKey('CFG_EXISTS') -and -not $seen.ContainsKey('CLONED') -and -not $seen.ContainsKey('READ_OK')) { Write-Host "'$name' đã có trên box, không cần thêm"; return 0 }
  # chi bao "Xong" khi script thoat 0 va that su qua: doc duoc + ghi duoc repo, va da vao cau hinh
  if ($code -eq 0 -and $seen.ContainsKey('READ_OK') -and $seen.ContainsKey('WRITE_OK') -and ($seen.ContainsKey('CFG_ADDED') -or $seen.ContainsKey('CFG_EXISTS'))) { }
  elseif ($code -ne 0 -and $code -ne 30) {
    # chi noi "chay lai la an toan" khi chay lai co the giup (mang / box bi dung giua chung); 137 (qua han) da bao rieng o tren; ma la: chi bao ma
    if ($code -in 1, 12, 143, 255) { Write-Host "Chưa xong (mã $code). Xem thông báo ở trên rồi chạy lại cùng lệnh, chạy lại là an toàn." } else { Write-Host "Chưa xong (mã $code). Xem thông báo ở trên." }
    return 1
  }
  elseif ($code -eq 0) { Write-Host "Chưa xong (mã $code). Xem thông báo ở trên rồi chạy lại cùng lệnh, chạy lại là an toàn."; return 1 }
  else { Write-Host "Đã thêm nhưng có $([Math]::Max($bad, 1)) mục cần xem lại (cảnh báo ở trên). Chạy lại lệnh này là an toàn."; return 1 }
  Write-Host ''
  Write-Host "Xong. Mở app FCode, project $name đã có trong danh sách."
  if ($rules) { Write-Host 'Repo có CLAUDE.md/AGENTS.md nhắc tới deploy: omp sẽ theo quy tắc deploy của repo.' }
  Write-Host "Muốn có project này trên laptop: chạy fcode sync (tìm bản đã có trên máy, không có thì hỏi chỗ để tải về)."
  return 0
}

# fcode deploy <ten> <lenh> [doi so]: cong deploy chung tren VPS (/usr/local/sbin/fcode-deploy-gate --local <ten> <lenh>), qua ssh.
# Cong tu kiem tra moi yeu cau; o day chi chuyen lenh nguyen ven, in ket qua ngay khi co va thoat voi ma cua cong (70 = can nguoi xu ly).
# May ssh den VPS: khoa deployHost trong config.json (mac dinh contabo). Khong co bi mat nao di qua tham so dong lenh: ban nhap di qua stdin.
# Ma thoat cua chinh fcode khi cong khong chay: 65 = yeu cau bi tu choi tai may nay, chua doi gi; 1 = loi cong cu (ssh, gh) hoac mang.
function Get-DeployHost {
  $h = [string](Get-Cfg 'deployHost' 'contabo')
  if ($h -cmatch '\A[A-Za-z0-9][A-Za-z0-9._@-]{0,99}\z') { $h }
}

# mot tu cua lenh (khong khoang trang, khong ky tu dac biet cua shell)
function Test-DeployWord([string]$w) { $w -cmatch '\A[A-Za-z0-9._/][A-Za-z0-9._/-]{0,199}\z' }
# ten project theo luat cua hop dong (contract C1, RE_NAME cua cong) va chu/repo; dung o moi duong cua fcode deploy
function Test-DeployName([string]$n) { ($n -cmatch '\A[a-z][a-z0-9-]{0,26}[a-z0-9]\z') -and $n -cnotin 'add', 'allow', 'disallow' }   # add / allow / disallow = lenh dung dau, khong the la ten project
function Test-DeployRepo([string]$r) { ($r -cmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z') -and ($r -notmatch '\A\.+/|/\.+\z') }

# chay mot lenh tren VPS qua ssh, in tung dong ngay khi tien toi (tru khi -Quiet), tra @{ Code; Lines }.
# $B64 (tuy chon): noi dung (base64, mot dong) gui vao stdin cua lenh tu xa
function Invoke-DeploySsh([string]$Remote, [string]$B64, [switch]$Quiet) {
  $dh = Get-DeployHost
  $buf = New-Object 'System.Collections.Generic.List[string]'
  $emit = { param($l) $buf.Add([string]$l); if (-not $Quiet) { if ("$l" -cmatch '\AGATE_WARN') { Write-Host $l -ForegroundColor Yellow } else { Write-Host $l } } }   # GATE_WARN = canh bao cua cong: mau vang
  if (-not $dh) { Write-Host 'lỗi: deployHost trong file cấu hình không dùng được (chỉ chữ, số, dấu . _ @ -).'; return @{ Code = 1; Lines = @() } }
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    if ($B64) { $B64 | & ssh $dh $Remote | ForEach-Object { & $emit $_ } }
    else { & ssh -n $dh $Remote | ForEach-Object { & $emit $_ } }
    $code = [int]$LASTEXITCODE
  } catch { Write-Host "lỗi: không chạy được ssh ($($_.Exception.Message))"; $code = 1 }
  finally { $ErrorActionPreference = $old }
  if ($code -eq 255) { Write-Host "lỗi: không nối được VPS bằng ssh $dh (mã 255). Thử gõ: ssh $dh" }
  @{ Code = $code; Lines = @($buf) }
}

# mot lenh cua cong cho project $Name; $B64 (tuy chon) = ban nhap onboarding gui vao stdin cua cong
function Invoke-DeployGate([string]$Name, [string[]]$GateArgs, [string]$B64, [switch]$Quiet) {
  $cmd = ('/usr/local/sbin/fcode-deploy-gate --local ' + $Name + ' ' + (@($GateArgs) -join ' ')).TrimEnd()
  if ($B64) { $cmd = 'base64 -di | ' + $cmd }
  Invoke-DeploySsh $cmd $B64 -Quiet:$Quiet
}

# ban nhap onboarding: toi da 16 KiB, JSON hop le (bo BOM neu co). Tra @{ B64; Sha } (sha256 cua dung cac byte se gui) hoac @{ Err }
function Read-DeployDraft([string]$Path) {
  try {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ Err = "không thấy file bản nháp: $Path" } }
    $b = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).ProviderPath)
  } catch { return @{ Err = "không đọc được file bản nháp: $($_.Exception.Message)" } }
  if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $t = New-Object byte[] ($b.Length - 3); [Array]::Copy($b, 3, $t, 0, $t.Length); $b = $t }
  if ($b.Length -eq 0 -or $b.Length -gt 16384) { return @{ Err = 'bản nháp phải có nội dung và tối đa 16 KiB' } }
  try { $j = [Text.Encoding]::UTF8.GetString($b) | ConvertFrom-Json } catch { return @{ Err = 'bản nháp không phải JSON hợp lệ' } }
  $sha = ([BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($b)) -replace '-', '').ToLowerInvariant()
  $dr = ''; try { if ($j.registry.repo -is [string]) { $dr = $j.registry.repo } } catch { }
  $dn = ''; try { if ($j.registry.name -is [string]) { $dn = $j.registry.name } } catch { }
  @{ B64 = [Convert]::ToBase64String($b); Sha = $sha; Repo = $dr; Name = $dn }
}

# repo khong con lan chay Actions nao dang chay hoac dang cho (in_progress, queued)? Tra @{ Code; Msg }: 0 = rong; 65 = con lan chay (doi chay xong roi lam lai); 1 = gh khong doc duoc (khong xac nhan duoc thi khong dang ky)
function Test-DeployRunsIdle([string]$Repo) {
  foreach ($st in 'in_progress', 'queued') {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = @(& gh run list -R $Repo --status $st --json databaseId 2>&1 | ForEach-Object { "$_" }); $code = [int]$LASTEXITCODE } catch { $o = @("$($_.Exception.Message)"); $code = 1 }
    finally { $ErrorActionPreference = $old }
    $n = -1
    if ($code -eq 0) { try { $j = ConvertFrom-Json ($o -join "`n"); $n = $(if ($null -eq $j) { 0 } else { @($j).Count }) } catch { } }
    if ($n -lt 0) { return @{ Code = 1; Msg = "gh không đọc được các lượt chạy Actions ($st) của $Repo nên chưa xác nhận được là không còn lượt nào. Chưa đăng ký.`n  (chi tiết: $(($o | Select-Object -First 1)))" } }
    if ($n -gt 0) { return @{ Code = 65; Msg = "runs-in-flight: $Repo còn $n lượt Actions ở trạng thái $st. Chờ chúng chạy xong (hoặc huỷ), rồi chạy lại. Chưa đăng ký." } }
  }
  @{ Code = 0; Msg = '' }
}

# buoc chung truoc moi `register` (add va register go tay): in sha256, go YES (chi dung chu YES), roi kiem tra lai Actions (trong luc go YES co the vua co lan chay moi). Tra 0 = di tiep, ma khac = dung
function Confirm-DeployRegister([string]$Repo, [string]$Sha) {
  Write-Host ''
  Write-Host "sha256 của bản nháp: $Sha"
  $ans = Read-SyncLine 'Gõ YES để đăng ký (chữ khác = huỷ): '
  if ($null -eq $ans -or $ans.Trim() -cne 'YES') { Write-Host 'Đã huỷ, chưa đăng ký gì.'; return 65 }
  $r = Test-DeployRunsIdle $Repo
  if ($r.Code -ne 0) { Write-Host "lỗi: $($r.Msg)"; return $r.Code }
  0
}

# khoa deploy chi doc cua repo (/root/.ssh/<ten>_deploy tren VPS + ban ghi github-<ten> trong /root/.ssh/config + khoa trong Deploy keys cua repo).
# Khoa da co chi duoc dung lai khi khoa cong cua no nam trong `gh repo deploy-key list`; khong thi tu choi, khong bao gio ghi de. Tra ma: 0 = san sang, 65 = tu choi, 1 = loi
function Confirm-DeployKey([string]$Repo, [string]$Name) {
  $probe = 'k=/root/.ssh/@NAME@_deploy; if [ -e $k ]; then ssh-keygen -y -f $k || echo KEY_UNREADABLE; else echo KEY_NONE; fi'
  $create = "umask 077; k=/root/.ssh/@NAME@_deploy; mkdir -p /root/.ssh && [ ! -e `$k ] && [ ! -e `$k.pub ] && ssh-keygen -q -t ed25519 -N '' -C fcode-deploy-@NAME@ -f `$k && cat `$k.pub"
  $alias = "umask 077; c=/root/.ssh/config; mkdir -p /root/.ssh; touch `$c; if grep -qE '^[[:space:]]*Host[[:space:]]+github-@NAME@[[:space:]]*`$' `$c; then echo ALIAS_EXISTS; else { [ -e `$c.bak-fcode-@NAME@ ] || cp -a `$c `$c.bak-fcode-@NAME@; } && printf '\nHost github-@NAME@\n  HostName github.com\n  User git\n  IdentityFile ~/.ssh/@NAME@_deploy\n  IdentitiesOnly yes\n' >> `$c && echo ALIAS_ADDED; fi"
  $keyFile = "/root/.ssh/${Name}_deploy"
  $p = Invoke-DeploySsh $probe.Replace('@NAME@', $Name) -Quiet
  if ($p.Code -ne 0) { Write-Host "lỗi: không đọc được khoá deploy trên VPS (mã $($p.Code))."; return 1 }
  $none = $false; $unread = $false; $pk = ''
  foreach ($l in $p.Lines) {
    if ($l -cmatch '\AKEY_NONE\s*\z') { $none = $true }
    elseif ($l -cmatch '\AKEY_UNREADABLE\s*\z') { $unread = $true }
    elseif (-not $pk -and $l -cmatch '\A(\S+)\s+(AAAA\S+)') { $pk = $Matches[1] + ' ' + $Matches[2] }
  }
  $isNew = $false
  if ($none) {
    $c = Invoke-DeploySsh $create.Replace('@NAME@', $Name) -Quiet
    foreach ($l in $c.Lines) { if (-not $pk -and $l -cmatch '\A(\S+)\s+(AAAA\S+)') { $pk = $Matches[1] + ' ' + $Matches[2] } }
    if ($c.Code -ne 0 -or -not $pk) { Write-Host "lỗi: VPS không tạo được khoá $keyFile (không ghi đè khoá hay file có sẵn). Kiểm tra trên VPS rồi chạy lại."; return 1 }
    $isNew = $true
    Write-Host "[1] Đã tạo khoá deploy mới $keyFile trên VPS"
  } elseif ($unread -or -not $pk) {
    Write-Host "lỗi: có sẵn $keyFile trên VPS nhưng không đọc được khoá công khai của nó. Không ghi đè. Xử lý tay trên VPS rồi chạy lại."
    return 65
  }
  if ($isNew) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('fcode-deploy-' + [guid]::NewGuid().ToString('N') + '.pub')   # chi khoa CONG KHAI
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
      [IO.File]::WriteAllBytes($tmp, [Text.Encoding]::ASCII.GetBytes($pk + "`n"))
      $o = @(& gh repo deploy-key add $tmp -R $Repo --title "fcode deploy $Name (read-only)" 2>&1 | ForEach-Object { "$_" }); $code = [int]$LASTEXITCODE
    } catch { $o = @("$($_.Exception.Message)"); $code = 1 }
    finally { $ErrorActionPreference = $old; Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    if ($code -ne 0) {
      Write-IpaError "gh không thêm được khoá chỉ đọc vào $Repo (mã $code)." ($o -join "`n")
      Write-Host "  Khoá đã tạo trên VPS, chưa vào GitHub. Khoá công khai: $pk"
      Write-Host "  Thêm tay ở https://github.com/$Repo/settings/keys/new (KHÔNG tích Allow write access) rồi chạy lại lệnh này."
      return 1
    }
    Write-Host "[2] Đã thêm khoá chỉ đọc vào Deploy keys của $Repo"
  } else {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = @(& gh repo deploy-key list -R $Repo --json 'key,readOnly' 2>&1 | ForEach-Object { "$_" }); $code = [int]$LASTEXITCODE } catch { $o = @("$($_.Exception.Message)"); $code = 1 }
    finally { $ErrorActionPreference = $old }
    $listed = $null
    if ($code -eq 0) { try { $j = ConvertFrom-Json ($o -join "`n"); $listed = @(foreach ($e in @($j)) { [pscustomobject]@{ Key = ((([string]$e.key).Trim() -split '\s+' | Select-Object -First 2) -join ' '); Ro = (($e.readOnly -eq $true) -or ($e.read_only -eq $true)) } }) } catch { } }   # foreach: Windows PowerShell 5.1 gives a JSON array as ONE object; read_only: gh 2.92 accepts --json readOnly but prints the field as read_only
    if ($null -eq $listed) { Write-IpaError "gh không đọc được Deploy keys của $Repo." ($o -join "`n"); return 1 }
    $mine = @($listed | Where-Object { $_.Key -ceq $pk })
    if ($mine.Count -eq 0) {
      Write-Host "lỗi: $keyFile đã có trên VPS nhưng khoá công khai của nó KHÔNG nằm trong Deploy keys của $Repo. Không ghi đè khoá."
      Write-Host '  Nếu là khoá của repo này: thêm nó vào Deploy keys của repo (chỉ đọc) rồi chạy lại. Nếu không: đổi tên project.'
      return 65
    }
    if (@($mine | Where-Object { -not $_.Ro }).Count) {
      Write-Host "lỗi: khoá $keyFile đã nằm trong Deploy keys của $Repo nhưng CÓ quyền ghi (Allow write access). Cổng chỉ dùng khoá chỉ đọc nên không dùng lại, không ghi đè."
      Write-Host "  Xoá khoá đó ở https://github.com/$Repo/settings/keys, thêm lại đúng khoá công khai này ở https://github.com/$Repo/settings/keys/new (KHÔNG tích Allow write access): $pk, rồi chạy lại lệnh này."
      return 65
    }
    Write-Host "[1] Khoá deploy $keyFile đã có trên VPS và đã nằm trong Deploy keys của $Repo, dùng lại"
  }
  $al = Invoke-DeploySsh $alias.Replace('@NAME@', $Name) -Quiet
  if ($al.Code -ne 0 -or -not (@($al.Lines) -match '\AALIAS_(ADDED|EXISTS)\s*\z')) { Write-Host "lỗi: VPS không khai báo được kết nối GitHub github-$Name trong /root/.ssh/config (mã $($al.Code))."; return 1 }
  if (@($al.Lines) -match '\AALIAS_ADDED') { Write-Host "[3] Đã khai báo kết nối GitHub github-$Name trong /root/.ssh/config của VPS (có bản sao lưu)" } else { Write-Host "[3] Kết nối GitHub github-$Name đã có trong /root/.ssh/config của VPS, giữ nguyên" }
  0
}

# fcode deploy add <chu/repo> <ten> <draft.json>: dang ky mot project vao cong (khoa chi doc -> kiem tra Actions -> xem hien trang -> go YES -> register)
function Invoke-DeployAdd([string[]]$AddArgs) {
  $reserved = 'deal-sync', 'vps-scraper', 'all', 'admin', 'gate', 'gen', 'src', 'build', 'poll', 'report', 'slot', 'legacy'   # contract C1: khong bao gio dang ky duoc
  $repo = if ($AddArgs.Count -gt 0) { [string]$AddArgs[0] } else { '' }; $name = if ($AddArgs.Count -gt 1) { [string]$AddArgs[1] } else { '' }
  if ($AddArgs.Count -ne 3 -or -not (Test-DeployRepo $repo) -or -not (Test-DeployName $name) -or $name -cin $reserved) {
    Write-Host 'Cách dùng: fcode deploy add <chủ/repo> <tên> <draft.json>'
    Write-Host '  <tên>: chữ thường, số, dấu -, bắt đầu bằng chữ thường, không kết thúc bằng dấu -, 2 đến 28 ký tự (không dùng tên dành riêng)   ·   <draft.json>: bản nháp đăng ký (tối đa 16 KiB)'
    return 65
  }
  $d = Read-DeployDraft ([string]$AddArgs[2])
  if ($d.Err) { Write-Host "lỗi: $($d.Err)"; return 65 }
  if ($d.Repo -ne $repo) { Write-Host "lỗi: bản nháp ghi registry.repo = '$($d.Repo)' nhưng repo ở dòng lệnh là '$repo'. Hai repo phải giống nhau. Chưa làm gì."; return 65 }
  if ($d.Name -cne $name) { Write-Host "lỗi: bản nháp ghi registry.name = '$($d.Name)' nhưng tên ở dòng lệnh là '$name'. Hai tên phải giống nhau. Chưa làm gì."; return 65 }
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Write-Host 'lỗi: không tìm thấy gh (GitHub CLI). Cài gh rồi chạy: gh auth login'; return 1 }
  # lan 1 (som, chua doi gi): co lan chay dang chay hoac cho thi dung ngay
  $r = Test-DeployRunsIdle $repo
  if ($r.Code -ne 0) { Write-Host "lỗi: $($r.Msg)"; return $r.Code }
  Write-Host "Đăng ký $repo vào cổng deploy với tên '$name'..."
  $k = Confirm-DeployKey $repo $name
  if ($k -ne 0) { return $k }
  Write-Host '[4] Đọc hiện trạng trên VPS (chỉ đọc, chưa đổi gì):'
  $inv = Invoke-DeployGate $name @('inventory') -B64 $d.B64
  # chi tiep tuc khi ma = 0 va dong CUOI bat dau bang `INV ` dung la `INV ok` (C13.3; dong GATE_EXIT di sau la binh thuong); thieu, cut giua chung hay `INV refuse` = tu choi
  $invLast = @($inv.Lines | Where-Object { "$_" -cmatch '\AINV ' } | Select-Object -Last 1)
  if ($inv.Code -ne 0 -or $invLast.Count -eq 0 -or $invLast[0] -cne 'INV ok') {
    Write-Host "Cổng không xác nhận bản nháp (mã $($inv.Code); kết quả phải kết thúc bằng dòng 'INV ok'). Sửa theo các dòng INV ở trên rồi chạy lại. Chưa đăng ký."
    return $(if ($inv.Code -ne 0) { $inv.Code } else { 65 })
  }
  # YES, roi kiem tra lai Actions ngay truoc register (trong luc xem va go YES co the vua co lan chay moi)
  $c = Confirm-DeployRegister $repo $d.Sha
  if ($c -ne 0) { return $c }
  $reg = Invoke-DeployGate $name @('register', $d.Sha) -B64 $d.B64
  if ($reg.Code -eq 0) {
    Write-Host ''
    Write-Host "Xong: '$name' đã đăng ký và đang tạm dừng. Việc tiếp theo, theo thứ tự:"
    Write-Host "  fcode deploy $name status"
    Write-Host "  fcode deploy $name trust on i-understand-root   (script của project chạy bằng root nên cần bật chế độ tin cậy trước khi deploy)"
    Write-Host "  fcode deploy $name deploy <sha của main>"
    Write-Host "  fcode deploy $name resume"
    return 0
  }
  if ($reg.Code -eq 70) {
    Write-Host ''
    Write-Host 'Cổng cần người xử lý (needs_human). Trạng thái hiện tại:'
    [void](Invoke-DeployGate $name @('status'))
    Write-Host "Xử lý theo dòng BLOCKED ở trên (ví dụ kết thúc tiến trình đang giữ thư mục), rồi chạy:  fcode deploy $name recheck"
    return 70
  }
  Write-Host "Đăng ký chưa xong (mã $($reg.Code)). Xem thông báo ở trên."
  $reg.Code
}

# fcode deploy allow <ten> [root] | disallow <ten>: duyet / thu hoi quyen cua khoa box tren cong (chi chay tu laptop; cong tu choi ten danh rieng, ma 65). `root` = them quyen trust on
function Invoke-DeployAllow([string]$Verb, [string[]]$AllowArgs) {
  $name = if ($AllowArgs.Count -gt 0) { [string]$AllowArgs[0] } else { '' }
  $root = ($Verb -ceq 'allow') -and $AllowArgs.Count -eq 2 -and $AllowArgs[1] -ceq 'root'
  if (-not (Test-DeployName $name) -or $AllowArgs.Count -gt $(if ($Verb -ceq 'allow') { 2 } else { 1 }) -or ($AllowArgs.Count -eq 2 -and -not $root)) {
    Write-Host "Cách dùng: fcode deploy $Verb <tên>$(if ($Verb -ceq 'allow') { ' [root]' })"
    return 65
  }
  $g = @($Verb); if ($root) { $g += 'root'; Write-Host 'coder sẽ được bật trust on (chạy bằng root) cho project này' -ForegroundColor Yellow }
  (Invoke-DeployGate $name $g).Code
}

function Invoke-Deploy {
  $a = @($Rest | Select-Object -Skip 1)
  $verbs = 'status', 'deploy', 'retry', 'pause', 'resume', 'trust', 'logs', 'recheck', 'inventory', 'register', 'compact', 'approve'
  if ($a.Count -gt 0 -and $a[0] -ceq 'add') { return (Invoke-DeployAdd @($a | Select-Object -Skip 1)) }
  if ($a.Count -gt 0 -and ($a[0] -ceq 'allow' -or $a[0] -ceq 'disallow')) { return (Invoke-DeployAllow ([string]$a[0]) @($a | Select-Object -Skip 1)) }
  $name = if ($a.Count -gt 0) { [string]$a[0] } else { '' }; $verb = if ($a.Count -gt 1) { [string]$a[1] } else { '' }
  $rest = @($a | Select-Object -Skip 2)
  if (-not (Test-DeployName $name) -or $verbs -cnotcontains $verb) {
    Write-Host 'Cách dùng: fcode deploy <tên> <lệnh> [đối số]'
    Write-Host '  lệnh: status [id] · deploy <sha> · retry [sha] · approve <sha> now|idle|skip · pause · resume · trust on i-understand-root | off · logs [id] [số dòng] · recheck · compact · inventory <draft.json> · register <sha256> <draft.json>'
    Write-Host '  Đăng ký project mới: fcode deploy add <chủ/repo> <tên> <draft.json>'
    Write-Host '  Duyệt / thu hồi quyền của khoá box: fcode deploy allow <tên> [root] · fcode deploy disallow <tên>'
    return 65
  }
  $b64 = ''; $gateArgs = @($rest)
  if ($verb -ceq 'inventory' -or $verb -ceq 'register') {
    # hai lenh nay doc ban nhap tu stdin cua cong: tham so cuoi la file ban nhap tren may nay, khong gui di
    if ($rest.Count -ne $(if ($verb -ceq 'inventory') { 1 } else { 2 })) { Write-Host "Cách dùng: fcode deploy $name $verb $(if ($verb -ceq 'register') { '<sha256> ' })<draft.json>"; return 65 }
    $d = Read-DeployDraft ([string]$rest[-1])
    if ($d.Err) { Write-Host "lỗi: $($d.Err)"; return 65 }
    $b64 = $d.B64; $gateArgs = @($rest | Select-Object -First ($rest.Count - 1))
  }
  if ($verb -ceq 'approve') {
    # tra loi cau hoi cua cong khi app ban: <sha 40 ky tu> now|idle|skip; chi laptop co lenh nay (coder khong co)
    if ($rest.Count -ne 2 -or ([string]$rest[0]) -cnotmatch '\A[0-9a-f]{40}\z' -or ([string]$rest[1]) -cnotin 'now', 'idle', 'skip') {
      Write-Host "Cách dùng: fcode deploy $name approve <sha đủ 40 ký tự> now|idle|skip"
      Write-Host '  now = deploy ngay (chấp nhận bị gián đoạn) · idle = đợi lúc app rảnh · skip = bỏ qua bản này'
      return 65
    }
  }
  foreach ($w in $gateArgs) { if (-not (Test-DeployWord ([string]$w))) { Write-Host "lỗi: đối số '$("$w" -replace '[\x00-\x1f\x7f]', '?')' không hợp lệ (chỉ chữ, số, dấu . _ / -)."; return 65 } }
  if ($verb -ceq 'register') {
    # register tay di qua cung buoc voi add: Actions khong con lan chay, go YES, kiem tra lai (tren repo ghi trong ban nhap)
    if ($rest[0] -cne $d.Sha) { Write-Host "lỗi: sha256 đã gõ ($($rest[0])) khác sha256 của file bản nháp ($($d.Sha)). Chạy lại inventory và dùng đúng sha256 của file. Chưa làm gì."; return 65 }
    if (-not (Test-DeployRepo $d.Repo)) { Write-Host "lỗi: registry.repo của bản nháp ('$($d.Repo)') không phải dạng chủ/repo. Chưa làm gì."; return 65 }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Write-Host 'lỗi: không tìm thấy gh (GitHub CLI). Cài gh rồi chạy: gh auth login'; return 1 }
    $r = Test-DeployRunsIdle $d.Repo
    if ($r.Code -ne 0) { Write-Host "lỗi: $($r.Msg)"; return $r.Code }
    $c = Confirm-DeployRegister $d.Repo $d.Sha
    if ($c -ne 0) { return $c }
  }
  if ($verb -ceq 'trust' -and $rest.Count -eq 2 -and $rest[0] -ceq 'on' -and $rest[1] -ceq 'i-understand-root') {
    # canh bao truoc khi gui, nhac ten repo va nhanh that cua project (doc tu dong PROJECT cua status)
    $s = Invoke-DeployGate $name @('status') -Quiet
    $tr = ''; $tb = ''
    foreach ($l in $s.Lines) { if ($l -match '\APROJECT\s') { if ($l -match '\brepo=(\S+)') { $tr = $Matches[1] }; if ($l -match '\bbranch=(\S+)') { $tb = $Matches[1] } } }
    if (-not $tr -or -not $tb) {
      Write-Host "lỗi: không đọc được repo và nhánh của '$name' từ lệnh status (project đã đăng ký chưa?). Chưa bật chế độ tin cậy."
      foreach ($l in $s.Lines) { Write-Host $l }
      return $(if ($s.Code -ne 0) { $s.Code } else { 65 })
    }
    Write-Host "Trusted mode: anyone who can merge to $tr $tb gets root on the VPS (compose controls the root docker daemon; script runs as root) and can read the gate's GitHub token, which can post statuses and issues on every brooklyn96 repository." -ForegroundColor Yellow
  }
  (Invoke-DeployGate $name (@($verb) + $gateArgs) -B64 $b64).Code
}

# ============================== fcode move ==============================
# fcode move check | plan <new-alias> --addr <ipv4|name> [--old-addr <host[:port]>] [--map <file>] | copy | cutover | finish | back | abort
#            | status [--rebuild <old-alias> <new-alias>]
# Moves everything the production machine runs to one other machine (deploy-gate docs/move/CONTRACT.md, DESIGN.md D.0-D.15).
# The laptop conducts: its state file %USERPROFILE%\.fcode\move\state.json is the one authority between runs; the machines are
# reached only through `fcode-deploy-gate --move <verb>` (recorded calls with a call id from the closed step list) and the
# plain-ssh scripts below. Only INV / MOVE / GATE_EXIT lines (and the two exact GATE_ERROR answers) are parsed; no secret is
# written to disk or to the screen. Every DESIGN-GAP reading lives in a function whose comment starts with "DESIGN-GAP".
function Get-MoveNow { [DateTime]::UtcNow }
function Wait-Move([int]$Sec) { Start-Sleep -Seconds $Sec }
function Format-MoveTs([DateTime]$d) { $d.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }
function ConvertTo-MoveTime($v) {
  if ($null -eq $v -or "$v" -eq '') { return $null }
  if ($v -is [DateTime]) { return $v.ToUniversalTime() }
  try { [DateTime]::ParseExact([string]$v, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)) } catch { $null }
}
function Get-MoveDir { $d = Join-Path (Join-Path $env:USERPROFILE '.fcode') 'move'; [void][IO.Directory]::CreateDirectory($d); $d }
function Get-MovePath([string]$Leaf) { Join-Path (Get-MoveDir) $Leaf }
function Set-MoveProp($o, [string]$Name, $Value) { if ($o.PSObject.Properties[$Name]) { $o.$Name = $Value } else { Add-Member -InputObject $o -NotePropertyName $Name -NotePropertyValue $Value } }
function Get-MoveProp($o, [string]$Name, $Default = $null) { if ($null -ne $o -and $o.PSObject.Properties[$Name]) { $o.$Name } else { $Default } }
function Get-MoveSha256Hex([byte[]]$b) { ([BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($b)) -replace '-', '').ToLowerInvariant() }
function Test-MoveWord([string]$w) { $w -cmatch '\A[A-Za-z0-9._=:/,@+-]{1,200}\z' }
function Test-MoveAddr([string]$a) { $a -cmatch '\A[A-Za-z0-9.-]{1,253}\z' }                              # B.0.2 / RE_MV_ADDR
function Test-MoveHostPort([string]$a) { $a -cmatch '\A[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?\z' }           # --old-addr <host[:port]>
function Test-MoveAlias([string]$a) { $a -cmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,62}\z' }
function Test-MoveId([string]$i) { $i -cmatch '\Amv-[0-9]{14}-[0-9a-f]{6}\z' }
function New-MoveIdText { 'mv-' + (Get-MoveNow).ToString('yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture) + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 6)) }
# laptop exit codes (I17): 0 done, 1 failed, 10 rolled back, 65 refused, 70 needs a human, 75 busy
# R10-INT-31 (B24): an unknown outcome (-1) or a transport 124/255 marks the run; the exit prints the sentence when the run ends 1
function ConvertTo-MoveExit([int]$Code) { if ($Code -in 0, 65, 70, 75) { $Code } elseif ($Code -in -1, 124, 255) { $script:MoveNoAnswer = $true; 1 } else { 1 } }

# D.0.6 numbers (W1-T10-G3: the read-only plan forms 3600 s; the plain-ssh scripts preflight, bootstrap key, bootstrap gate and rebuild
# read 2400 s; facts, the TCP reach test and the `true` login 30 s).
function Get-MoveConst([string]$Name) {
  switch -CaseSensitive ($Name) {
    'cap_s' { 900 } 'status_s' { 60 } 'plan_s' { 3600 } 'script_s' { 2400 } 'tcp_s' { 30 }
    'first_transfer_s' { 21600 } 'first_verify_s' { 1800 } 'adopt_s' { 1860 } 'other_s' { 300 }
    'refresh_min' { 60 } 'back_precopy_min' { 10 } 'clock_s' { 5 } 'drain_wait_min' { 15 } 'retries' { 3 }
    default { throw "Get-MoveConst: $Name" }
  }
}

# ---- owner texts: CONTRACT §8.3 verbatim (D.15.1, §8.3.2); <…> filled here ----
function Get-MoveText([string]$Key, [hashtable]$F = @{}) {
  $t = switch -CaseSensitive ($Key) {
    'Q-pm2save' { 'Danh sách pm2 đang chạy khác danh sách đã lưu (<tên>). Lưu danh sách hiện tại trên máy cũ? (có / không)' }
    'Q-cert' { 'Chứng chỉ <tên> hết hạn sau <n> ngày. Gia hạn trên máy cũ trước khi chuyển? (có / không)' }
    'Q-direct' { 'Tên <tên> trỏ thẳng về máy cũ (<lớp>). Bạn sẽ tự đổi bản ghi DNS hoặc origin Cloudflare sang máy mới lúc chuyển? (có / không)' }
    'Q-ownip' { 'Các file sau chứa địa chỉ của máy cũ: <danh sách>. Thay bằng địa chỉ máy mới khi chép? (có / không)' }
    'Q-ownip-pairs' { 'Máy cũ có các địa chỉ <địa chỉ cũ>, máy mới có các địa chỉ <địa chỉ mới>. Gõ từng cặp theo dạng địa chỉ máy cũ=địa chỉ máy mới để thay trong các file trên, mỗi cặp một dòng; gõ một dòng trống để kết thúc.' }   # D.15.1 "Q-ownip (several addresses)"
    'Q-port' { 'Các dịch vụ sau nhận kết nối thẳng qua IP: <danh sách>. Phía khách phải đổi sang IP máy mới sau khi chuyển. Đồng ý? (có / không)' }
    'Q-inbound' { 'Các kết nối vào sau sẽ mất sau khi chuyển cho đến khi bạn trỏ lại phía khách: <danh sách>. Đồng ý? (có / không)' }
    'Q-sshd' { 'Cấu hình sshd của máy mới khác máy cũ (<khóa>). Áp dụng các file sshd của máy cũ lên máy mới? (có / không)' }
    'Q-sshpush' { 'Workflow của repo <repo> deploy thẳng qua ssh. Tắt hẳn workflow đó? (có / không)' }
    'Q-drain' { 'Máy cũ còn việc deploy đang chạy (<khóa hoặc unit>). đợi = đợi thêm <n> phút; dừng = mở lại máy cũ và dừng. (đợi / dừng)' }
    'Q-guard' { 'Ứng dụng <tên> đang bận. tiếp tục = vẫn dừng ứng dụng để chuyển; dừng = quay lại máy cũ. (tiếp tục / dừng)' }
    'Q-finish' { 'Kết thúc chuyển máy: sau bước này không quay lại máy cũ được nữa. Gõ YES để xác nhận.' }
    'Q-back' { 'Chuyển ngược về máy cũ. Những thứ này ở lại máy mới, không chạy trên máy cũ: <danh sách>. Gõ YES để xác nhận.' }
    'Q-discard' { 'Chép ngược tự động bị lỗi trước khi chép dữ liệu. Chạy lại máy cũ với dữ liệu của nó? Mọi thay đổi trên máy mới từ <giờ> sẽ mất. Gõ YES để xác nhận.' }
    'Q-newlost' { 'Máy mới không trả lời. Trước khi trả lời, hãy tắt hoặc cài lại máy mới trong trang quản lý nhà cung cấp. Mọi thay đổi trên máy mới sau <giờ> sẽ mất. Gõ YES để chạy lại máy cũ.' }
    'return-old' { 'Đã quay về máy cũ; máy cũ đang phục vụ.' }
    'transient' { 'Các unit tạm sau đã dừng và sẽ không được tạo lại: <danh sách>.' }
    'uid-remedy' { 'xóa user <h> trên máy mới' }
    'reinstall-new' { 'cài lại máy mới' }
    'copy-again' { 'chạy fcode move copy lại' }
    'cutover-again' { 'chạy lại fcode move cutover' }
    'cutover-now' { 'chạy lại fcode move cutover ngay' }
    'carry-half' { 'dữ liệu máy cũ đang dở; chỉ tiếp tục được khi máy mới nối lại' }
    'carry-resume' { 'Chạy lại fcode move cutover để tiếp tục chép ngược.' }   # ruling 05/11 (27) F4: after x.final in a carry-back, new answered status (also the Q-discard "không" line)
    'back-stays' { 'những thứ này ở lại máy mới, không chạy trên máy cũ' }
    'abort-text' { 'máy mới đang giữ bản sao của mọi dữ liệu và bí mật; xóa hoặc cài lại máy mới trước khi plan lại' }
    'copy-first' { 'chạy copy trước' }
    'old-running' { 'máy cũ đang chạy' }
    'cut-carries' { 'cutover sẽ tự chép ngược' }
    'carrying' { 'đang chép ngược tự động' }
    'cut-1' { 'nếu lỗi sau khi máy mới đã chạy, dữ liệu sẽ được chép ngược về máy cũ' }
    'cut-2' { 'đừng deploy tay lúc này' }
    'cut-3' { 'Hermes và `fcode deploy status` báo `moving` trong lúc chuyển' }
    'same-gate' { 'cài cùng bản gate lên máy cũ' }
    'net-drop' { 'mạng đứt; chạy fcode move copy lại' }
    'rebuild' { 'dựng lại trạng thái' }
    'new-down' { 'máy mới không trả lời; máy cũ chạy lại' }
    'rsync-remedy' { 'cài rsync <CONTRACT version> trên máy mới, hoặc chụp lại T0b và phát hành gate' }
    'acl-remedy' { 'gỡ mục ACL đó trên máy cũ rồi chạy lại' }
    'pkg-extra-remedy' { 'xóa file mặc định đó rồi chạy lại' }
    'rerun' { 'Chạy lại khi máy nối lại được.' }
    'rewrites-remedy' { 'ghi rõ `<from>=<to>`' }
    'ingress-remedy' { 'đổi service của tên đó trong cấu hình tunnel sang 127.0.0.1 hoặc tên container' }
    'connector-remedy' { 'kiểm tra cổng metrics của connector rồi chạy lại' }
    'connector-unit-remedy' { 'nếu unit đó không phải tunnel cloudflared, thêm dòng map  accept not-connector <unit> ; nếu là tunnel thì bật nó lên (đang chạy thì kiểm tra cổng metrics) rồi chạy lại' }   # B77, B78 P3-S: a unit path of `unmapped what=connector`; a container keeps connector-remedy
    'return-busy' { 'Máy cũ còn đang chạy lệnh trước; chạy lại  fcode move cutover , lệnh sẽ đợi lệnh đó xong.' }   # B60 (a): a return that met a call still running on old
    'return-incomplete' { 'Máy cũ chưa chạy lại đủ: cần người xem (70). Sau khi sửa, chạy lại  fcode move cutover  để hoàn tất quay lại.' }
    'root-link' { 'Đường <đường dẫn> là symlink ngay dưới / nằm trong phần chuyển; hãy chuyển thư mục đích thay cho link, hoặc tạo lại link bằng tay trên máy mới' }   # B45 (ruling 06/11 (a)): `MOVE error bad-request why=root-link path=<p>`
    'connector-label' { 'Unit hoặc container có thể là connector tunnel cloudflared nhưng không đọc được cấu hình tunnel' }   # B78 P3-U: `INV refuse unmapped what=connector path=<p>` (the `unmapped` label is the extra-disk one)
    default { throw "Get-MoveText: $Key" }
  }
  foreach ($k in $F.Keys) { $t = $t.Replace("<$k>", [string]$F[$k]) }
  $t
}
# DESIGN-GAP (T10-G8): D.15 names the parts of Q-cut and Q-abort but gives no single sentence; this is the reading, built only from
# the CONTRACT §8.3 strings plus the numbers; T9 copies the same parts into docs/MOVE.md.
function Get-MoveCutText($S, [string[]]$Transient) {
  $typ = Get-MoveProp $S.est 'typical_s'; $max = Get-MoveProp $S.est 'max_s'
  $t = "Chuyển sang máy mới bây giờ? Thời gian dừng ước tính $(if ($null -ne $typ) { $typ } else { '?' }) giây, tối đa $(if ($null -ne $max) { $max } else { '?' }) giây. Tin nhắn Zalo trong lúc chuyển có thể mất; kiểm tra các danh sách IP được phép ở bên ngoài. $(Get-MoveText 'cut-1'); $(Get-MoveText 'cut-2'); $(Get-MoveText 'cut-3')."
  if (@($Transient).Count) { $t += ' ' + (Get-MoveText 'transient' @{ 'danh sách' = (@($Transient) -join ', ') }) }
  $t + ' (có / không)'
}
function Get-MoveAbortText([string[]]$Transient) {
  $t = 'Hủy lần chuyển máy? ' + (Get-MoveText 'abort-text') + '.'
  if (@($Transient).Count) { $t += ' ' + (Get-MoveText 'transient' @{ 'danh sách' = (@($Transient) -join ', ') }) }
  $t + ' (có / không)'
}
# CONTRACT §8.3.3: one label per closed reason; the laptop prints `<label>: <chi tiết>`
function Get-MoveLabels {
  if ($script:MoveLabels) { return $script:MoveLabels }
  $txt = @'
refuse os | Máy mới khác bản Debian của máy cũ
refuse arch | Máy mới khác kiến trúc CPU của máy cũ
refuse disk | Máy mới không đủ chỗ trống trên đĩa
refuse inodes | Máy mới không đủ inode trống
refuse clock | Đồng hồ các máy lệch nhau quá 5 giây
refuse dns | Không tra được DNS qua DoH
refuse unmapped | Có ổ đĩa gắn thêm chưa ghi trong map
refuse transient | Có unit tạm đang chạy chưa được loại trừ
refuse uid-collision | Trùng user hoặc uid trên máy mới
refuse excluded-user-ref | Có file còn nhắc tới user đã loại trừ
refuse pkg-local | Có gói cài tay, không có trong kho apt
refuse pkg-unavailable | Máy mới không cài được gói
refuse pkg-major | Phiên bản chính của gói khác giữa hai máy
refuse hostname-direct | Tên miền trỏ thẳng về máy cũ
refuse own-ip | File chứa địa chỉ IP của máy cũ
refuse own-ip-family | Máy mới thiếu loại địa chỉ IP cần thay
refuse own-ip-nat | Máy mới đứng sau NAT, cần dòng map đổi địa chỉ
refuse public-port | Có dịch vụ nhận kết nối thẳng qua IP
refuse pm2-unsaved | Danh sách pm2 chưa được lưu
refuse inbound | Có kết nối vào sẽ mất sau khi chuyển
refuse push-deploy | Có workflow deploy thẳng qua ssh
refuse gh-permission | gh không có quyền admin trên repo
refuse sshd-config | Cấu hình sshd hai máy khác nhau
refuse gate-missing | Máy cũ chưa cài bản gate có lệnh chuyển máy
refuse gate-version | Hai máy chạy bản gate khác nhau
refuse target-not-empty | Máy mới không trống
refuse target-addr | Địa chỉ máy mới không hợp lệ
refuse old-unreachable | Máy mới không kết nối được máy cũ
refuse new-unreachable | Máy mới không kết nối được tới địa chỉ cần thiết
refuse tool-missing | Thiếu công cụ cần thiết
refuse manifest-invalid | Danh sách chuyển không hợp lệ
refuse map-invalid | File map có tham chiếu sai
refuse manifest-stale | Máy cũ đã thay đổi từ lần copy trước
refuse path-chars | Đường dẫn có ký tự không cho phép
refuse v1-residue | Còn sót phần của gate v1
refuse other-move | Đang có một lần chuyển máy khác
refuse target-rsync-argv | Lệnh rsync của máy mới khác mẫu đã ghi
refuse acl-mapped-id | Có file có ACL gắn số user hoặc group sẽ bị đổi khi chuyển
warn pkg-modified | File của gói đã bị sửa, không chép
warn new-only | Chỉ có trên máy mới, được giữ nguyên
warn cert-expiring | Chứng chỉ sắp hết hạn
warn unit-failed | Unit đã lỗi từ trước
warn orphan-owner | Có file thuộc user đã loại trừ
warn egress | Máy mới không kết nối ra được địa chỉ này
warn vanished | File biến mất trong lúc chép
warn health-baseline | Kiểm tra này đã lỗi từ trước trên máy cũ
warn coder-unreachable | Không vào được máy coder
warn guard-skipped | Bỏ qua kiểm tra bận của ứng dụng
warn dst-own-unit | Unit riêng của máy mới được giữ tắt
warn transient-excluded | Unit tạm đã loại trừ sẽ không được tạo lại
warn hold-gone | Unit không còn trên máy mới
warn item-gone | Thư mục không còn trên máy mới, giữ bản trên máy cũ
warn back-new-only | Chỉ có trên máy mới, không mang về máy cũ
warn rsync-version | Bản rsync trên máy cũ khác bản đã ghi
warn ufw-lockout | Tường lửa máy mới để tắt vì luật hiện tại sẽ khóa phiên ssh; cần bật lại bằng tay
warn pkg-extra | Có file lạ trong thư mục được chuyển, chưa bị xóa; chỉ xóa nếu chắc đây là file mặc định của gói vừa cài (vd sites-enabled/default); KHÔNG xóa file của chính máy mới (vd sudoers.d/90-cloud-init-users, netplan/50-cloud-init.yaml) — xóa nhầm có thể mất sudo hoặc mạng
warn own-ip-tracked | File nằm trong repo của project gate, giữ nguyên khi chuyển, không đổi IP; nếu IP đó là cấu hình đang chạy thì sửa trong repo rồi deploy lại
error busy | Máy đang chạy một lệnh chuyển khác
error no-manifest | Máy chưa có danh sách chuyển
error no-move | Máy này chưa thuộc lần chuyển nào
error move-id-mismatch | Máy này thuộc lần chuyển hoặc lần thử khác
error other-move | Máy này thuộc một lần chuyển khác
error acl-mapped-id | Có file có ACL gắn số user hoặc group sẽ bị đổi khi chuyển
error bad-request | Lệnh gửi tới máy không hợp lệ
error health | Kiểm tra sức khỏe không đạt
error rsync-failed | Chép dữ liệu bị lỗi
error disk | Hết chỗ trên đĩa
error sum-mismatch | Dữ liệu hai máy khác nhau
error dst-running | Máy đích còn ứng dụng đang chạy
error switch-failed | Chuyển tên miền sang máy mới không đạt
error not-root | Cần quyền root
error tool-missing | Thiếu công cụ cần thiết
error moving | Máy đang được chuyển
error moved | Máy này đã chuyển xong
error manifest-stale | Máy cũ đã thay đổi từ lần copy trước
error guard-failed | Kiểm tra bận của ứng dụng không đạt
error drain-stuck | Còn việc deploy dở, cần chạy recheck
error drain-lost | Có việc deploy mới chen vào lúc dừng
error lockout | Mất quyền đăng nhập vào máy đích
error keys-race | File authorized_keys bị sửa cùng lúc
'@
  $h = @{}
  foreach ($l in @($txt -split "`r?`n")) { if ($l -match '\A(\S+ \S+) \| (.+)\z') { $h[$Matches[1]] = $Matches[2] } }
  $script:MoveLabels = $h
  $h
}
# one INV / MOVE / GATE_ERROR line as the owner reads it ('' = not shown)
function Format-MoveLine([string]$Line) {
  $l = "$Line"
  # B45: a symlink directly under / that the plan would move is refused (the server's own `LOG remedy root-link` line is never shown): the owner label carries the remedy
  if ($l -cmatch '\AMOVE error bad-request why=root-link path=(\S+)\z') { return (Get-MoveText 'root-link' @{ 'đường dẫn' = $Matches[1] }) }
  # B78 P3-U: an `unmapped what=connector` refusal has its own label (the generic `unmapped` one says "extra disk", which stays for what=mount); the line's keys follow it as for any label
  if ($l -cmatch '\AINV refuse unmapped (what=connector(?:\s.*)?)\z') { return "$(Get-MoveText 'connector-label'): $($Matches[1])" }
  if ($l -cmatch '\AINV (refuse|warn) (\S+)(.*)\z' -or $l -cmatch '\AMOVE (error) (\S+)(.*)\z') {
    $lab = (Get-MoveLabels)["$($Matches[1]) $($Matches[2])"]; $rest = $Matches[3].Trim()
    if (-not $lab) { return $l }
    return $(if ($rest) { "${lab}: $rest" } else { $lab })
  }
  if ($l -cmatch '\AGATE_ERROR (moving|moved)\z') { return (Get-MoveLabels)["error $($Matches[1])"] }
  # F8a: `GATE_ERROR aborted` has no §8.3.3 label (DESIGN-GAP T10-G38, the Architect may add one): printed as the machine wrote it
  if ($l -cmatch '\AGATE_ERROR aborted\z') { return $l }
  if ($l -ceq 'INV ok' -or $l -cmatch '\A(MOVE (manifest|key|lst|call|state|facts|record|moveid|hostkey|target)|GATE_EXIT)\b') { return '' }
  if ($l -cmatch '\A(INV|MOVE) ') { return $l }
  ''
}
# CONTRACT §7.5 (ruling 05/11 (15), B22): `INV warn pkg-extra` (c.adopt.N, x.adopt) is shown with its cautious §8.3.3 label only;
# `MOVE item <id> kind=adopt state=failed why=no-install-end` (c.prepare.N) is shown, then the §8.3.2 remedy once per call
# (the server's own remedy is a LOG line, which the laptop never shows)
function Write-MoveLines($Lines) {
  $rem = $false
  foreach ($l in @($Lines)) {
    $f = Format-MoveLine "$l"; if ($f) { Write-Host $f }
    if ("$l" -cmatch '\AMOVE item \S+ kind=adopt state=failed(\s.*)? why=no-install-end(\s|\z)') { $rem = $true }
  }
  if ($rem) { Write-Host ('  ' + (Get-MoveText 'pkg-extra-remedy')) }
}
# B24/B25 (R10-INT-26, DG6): the no-answer line, head and last sentence together: "lỗi: máy '<alias>' không trả lời <khi …> (mã <n>). Chạy lại khi máy
# nối lại được." It is printed by every exit that gives up because a machine did not answer and knows the step; a run that ends 1 after a marked
# loss without this line gets the bare sentence from the exit (Invoke-Move); an exit that is not 1 keeps its own text (CONTRACT §7.5). Returns 1.
function Write-MoveNoAnswer([string]$Alias, [string]$When, $Code) { $script:MoveNoAnswer = $true; $script:MoveNoAnswerShown = $true; Write-Host "lỗi: máy '$Alias' không trả lời $When (mã $Code). $(Get-MoveText 'rerun')"; 1 }
# the first machine of a gate-ids read whose status did not answer GATE_EXIT 0 (old first)
function Write-MoveIdsNoAnswer($S, $Ids) {
  $m = if (-not $Ids.StOld.Known) { 'old' } else { 'new' }; $st = if ($m -ceq 'old') { $Ids.StOld } else { $Ids.StNew }
  Write-MoveNoAnswer ([string]$(if ($m -ceq 'old') { $S.old.alias } else { $S.new.alias })) 'khi đọc status' $st.Transport
}
# a status that answered but is not GATE_EXIT 0 with a state line is never a no-answer (R10-INT-31 item 10): its lines with their labels, and its own code
function Write-MoveStatusFail($S, [string]$M, $St) {
  Write-MoveLines $St.Lines; $c = ConvertTo-MoveExit $St.Code
  if ($c -eq 0) { Write-Host "lỗi: máy '$(if ($M -ceq 'old') { $S.old.alias } else { $S.new.alias })' trả lời status không đọc được (mã $($St.Code))."; $c = 1 }
  $c
}
# "MOVE state a=1 b=2" -> @{ a = '1'; b = '2' } (k=v splits at the first =)
function ConvertFrom-MoveKv([string]$Line) {
  $kv = @{}
  foreach ($w in @("$Line" -split ' ')) { $i = $w.IndexOf('='); if ($i -gt 0) { $kv[$w.Substring(0, $i)] = $w.Substring($i + 1) } }
  $kv
}
# run a local program (ssh -G, ssh-keygen, gh) and return @{ Code; Out } (stderr merged); $Stdin piped in when given
function Invoke-MoveTool([string]$Tool, [string[]]$ToolArgs, [string]$Stdin = $null) {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $o = if ($null -ne $Stdin) { @($Stdin | & $Tool @ToolArgs 2>&1 | ForEach-Object { "$_" }) } else { @(& $Tool @ToolArgs 2>&1 | ForEach-Object { "$_" }) }
    $code = [int]$LASTEXITCODE
  } catch { $o = @("$($_.Exception.Message)"); $code = 1 } finally { $ErrorActionPreference = $old }
  @{ Code = $code; Out = $o }
}
# a program with a hard deadline: @{ Code; Out; Err }; 124 = killed at the deadline, -1 = could not start. stdin is written as UTF-8 and closed.
function Invoke-MoveTimedExe([string]$Exe, [string[]]$ExeArgs, [string]$StdinText, [int]$TimeoutSec) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe; $psi.Arguments = (@($ExeArgs | ForEach-Object { ConvertTo-PhienArg ([string]$_) }) -join ' ')
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  try { $p = [Diagnostics.Process]::Start($psi) } catch { return @{ Code = -1; Out = @() } }
  try {
    try { if ($StdinText) { $sb = [Text.Encoding]::UTF8.GetBytes($StdinText); $p.StandardInput.BaseStream.Write($sb, 0, $sb.Length); $p.StandardInput.BaseStream.Flush() }; $p.StandardInput.Close() } catch { }
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    $end = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSec))
    while (-not $p.WaitForExit(100)) { if ([DateTime]::UtcNow -ge $end) { Stop-PhienProc $p; return @{ Code = 124; Out = @() } } }
    try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($o, $e), 3000) } catch { }
    $lines = New-Object System.Collections.Generic.List[string]
    if ($o.IsCompleted -and -not $o.IsFaulted) { $lines.AddRange([string[]]@($o.Result -split "`r?`n")) }
    if ($lines.Count -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    @{ Code = $p.ExitCode; Out = [string[]]$lines.ToArray(); Err = $(if ($e.IsCompleted -and -not $e.IsFaulted) { $e.Result } else { '' }) }
  } finally { $p.Dispose() }
}

# ---- state.json (D.0.9; atomic through Write-PhienText) ----
# every top-level field is declared here (L.rebuild-inventory reads this list); a key written only through `Set-MoveWriteAhead $S @{…}` must be declared here too
function New-MoveState([string]$Id, $OldM, $NewM) {
  [pscustomobject][ordered]@{
    move_id = $Id; dir = 'fwd'; attempt = 1; phase = 'planned'; serving = 'old'; mark = $null; dst_started = $false; dst_started_at = $null; carry = $false; enabled = $true
    new_lost = $false; new_discarded = $false; chores_done = $false; rebuilt = $false
    pass = [pscustomobject]@{}; dur = [pscustomobject]@{}; answers = [pscustomobject]@{}
    manifest_sha = ''; manifest_sha_prev = ''; gate_id = ''
    est = [pscustomobject][ordered]@{ typical_s = $null; max_s = $null; transfer_s = $null; verify_s = $null; apply_s = $null; prepid_s = $null }
    last_copy_at = $null; old = $OldM; new = $NewM; legacy_known_hosts = [pscustomobject]@{}
    aliases = [pscustomobject][ordered]@{ laptop_backup = $null; coder_backup = $null }
    sshpush_disabled = @(); window_s = $null; target_users = @(); target_groups = @(); target_subids = @(); target_addrs = @(); target_stop_budget_s = 0
    target_platform = 0; idmap = @(); legacy_push = @()
  }
}
# $null = no move; throws on a corrupt file (E-L4: the owner rebuilds it, "dựng lại trạng thái")
function Read-MoveState {
  $p = Get-MovePath 'state.json'
  if (-not [IO.File]::Exists($p)) { return $null }
  try { $s = [IO.File]::ReadAllText($p) | ConvertFrom-Json } catch { $s = $null }
  if ($null -eq $s -or -not (Test-MoveId ([string](Get-MoveProp $s 'move_id')))) { throw "file trạng thái $p bị hỏng; $(Get-MoveText 'rebuild'): fcode move status --rebuild <máy cũ> <máy mới>" }
  foreach ($k in 'pass', 'dur', 'answers', 'est', 'old', 'new', 'legacy_known_hosts', 'aliases') { if ($null -eq (Get-MoveProp $s $k)) { Set-MoveProp $s $k ([pscustomobject]@{}) } }
  foreach ($k in 'sshpush_disabled', 'target_users', 'target_groups', 'target_subids', 'target_addrs', 'idmap', 'legacy_push') { Set-MoveProp $s $k @(Get-MoveProp $s $k @()) }
  $d = @{ dir = 'fwd'; attempt = 1; phase = 'planned'; serving = 'old'; mark = $null; dst_started = $false; carry = $false; enabled = $true; new_lost = $false; new_discarded = $false; chores_done = $false; rebuilt = $false; manifest_sha = ''; manifest_sha_prev = ''; gate_id = ''; last_copy_at = $null; window_s = $null }
  foreach ($k in $d.Keys) { if (-not $s.PSObject.Properties[$k]) { Set-MoveProp $s $k $d[$k] } }
  $t = ConvertTo-MoveTime $s.last_copy_at; Set-MoveProp $s 'last_copy_at' $(if ($t) { Format-MoveTs $t } else { $null })
  # (T10-G36) R3-1: pwsh 7's ConvertFrom-Json turns the ISO answers{'Q-cut'}.ts into a [DateTime]; normalise it back to the record format
  $qc = Get-MoveMapVal $s.answers 'Q-cut'; if ($qc) { $t = ConvertTo-MoveTime (Get-MoveProp $qc 'ts' ''); Set-MoveProp $qc 'ts' $(if ($t) { Format-MoveTs $t } else { '' }) }
  # DESIGN-GAP / R5-3 (D.0.9 :476): dst_started_at is normalised on load like last_copy_at (pwsh 7's ConvertFrom-Json gives a [DateTime])
  $t = ConvertTo-MoveTime (Get-MoveProp $s 'dst_started_at' $null); Set-MoveProp $s 'dst_started_at' $(if ($t) { Format-MoveTs $t } else { $null })
  $s
}
function Save-MoveState($S) { if (-not $script:MoveDraft) { Write-PhienText (Get-MovePath 'state.json') (ConvertTo-Json -InputObject $S -Depth 10) } }
# map fields (pass{}, dur{}, answers{}) of the state object
function Get-MoveMapVal($o, [string]$K, $Default = $null) { Get-MoveProp $o $K $Default }
function Set-MoveMapVal($o, [string]$K, $V) { Set-MoveProp $o $K $V }
# only one fcode move at a time (I3, E-L5): move.lock opened without sharing; $null when another run holds it
function Open-MoveLock { try { New-Object IO.FileStream((Get-MovePath 'move.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) } catch { $null } }
# the saved manifest (manifest.json; its sha is state.manifest_sha): @{ Text; Obj } or $null
function Read-MoveManifest {
  $p = Get-MovePath 'manifest.json'
  if (-not [IO.File]::Exists($p)) { return $null }
  try { $t = [IO.File]::ReadAllText($p); @{ Text = $t; Obj = (ConvertFrom-Json $t) } } catch { $null }
}
function Save-MoveManifest([string]$Text) { Write-PhienText (Get-MovePath 'manifest.json') $Text }
function Get-MoveManifestObj { if (-not $script:MoveManifest) { $script:MoveManifest = Read-MoveManifest }; if ($script:MoveManifest) { $script:MoveManifest.Obj } }
# `MOVE manifest sha=<sha256> gz64=<base64 of the gzip>` -> @{ Sha; Text; Obj } or $null (the sha must be the sha256 of the JSON bytes, D.0.8)
function ConvertFrom-MoveManifestLine($Lines) {
  foreach ($l in @($Lines)) {
    if ("$l" -cnotmatch '\AMOVE manifest sha=([0-9a-f]{64}) gz64=([A-Za-z0-9+/=]+)\z') { continue }
    $sha = $Matches[1]
    try {
      $ms = New-Object IO.MemoryStream(, [Convert]::FromBase64String($Matches[2]))
      $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Decompress)
      $out = New-Object IO.MemoryStream; $gz.CopyTo($out); $gz.Dispose()
      $bytes = $out.ToArray()
    } catch { return $null }
    # the server may store the manifest LF-terminated (jsontool's output) under the sha of the bytes without that LF: the sha is then checked against the bytes minus one trailing LF
    if ((Get-MoveSha256Hex $bytes) -cne $sha) {
      if ($bytes.Length -gt 0 -and $bytes[$bytes.Length - 1] -eq 10) { $nb = New-Object byte[] ($bytes.Length - 1); [Array]::Copy($bytes, $nb, $nb.Length); if ((Get-MoveSha256Hex $nb) -ceq $sha) { $bytes = $nb } else { return $null } } else { return $null }
    }
    $text = (New-Object Text.UTF8Encoding($false)).GetString($bytes)
    try { return @{ Sha = $sha; Text = $text; Obj = (ConvertFrom-Json $text) } } catch { return $null }
  }
  $null
}
# a log of every recorded call's lines: log\<n>-<alias>-<call>.log (D.0.9)
function Add-MoveLog([string]$Alias, [string]$Call, $Lines) {
  try {
    $d = Join-Path (Get-MoveDir) 'log'; [void][IO.Directory]::CreateDirectory($d)
    # a part file left by a run killed between Write-PhienText's write and its move (one fcode move runs at a time, move.lock) is dropped first: every log has its own name, so
    # Write-PhienText's own per-name cleanup would never see it, and it would count as a log in $n
    foreach ($pf in @([IO.Directory]::GetFiles($d, '*.log.part-*'))) { try { [IO.File]::Delete($pf) } catch { } }
    $n = @([IO.Directory]::GetFiles($d)).Count + 1
    Write-PhienText (Join-Path $d ("{0:d5}-{1}-{2}.log" -f $n, $Alias, $Call)) ((@($Lines) -join "`n") + "`n")   # main's rule (fcode-phien r4): every file write goes through Write-PhienText (UTF-8 no BOM, part file + move)
  } catch { }
}

# ---- ssh: pins in %USERPROFILE%\.fcode\move\known_hosts (B.11.3), the D.0.6 options, Reach-Old (D.0.7) ----
function Get-MoveKnownFile { Get-MovePath 'known_hosts' }
# `ssh -G <alias>`: @{ HostName; Port } or $null
function Get-MoveSshInfo([string]$Alias) {
  $r = Invoke-MoveTool 'ssh' @('-G', $Alias)
  if ($r.Code -ne 0) { return $null }
  $h = @{}
  foreach ($l in $r.Out) { if ("$l" -match '\A(\S+)\s+(.*)\z') { $k = $Matches[1].ToLowerInvariant(); if (-not $h.ContainsKey($k)) { $h[$k] = $Matches[2].Trim() } } }
  if (-not $h['hostname']) { return $null }
  @{ HostName = [string]$h['hostname']; Port = $(if ("$($h['port'])" -match '\A[0-9]+\z') { [int]$h['port'] } else { 22 }) }
}
# the pinned ed25519 line of an address in the move's known_hosts: 'ssh-ed25519 <b64>' or ''
function Get-MovePinnedKey([string]$Addr) {
  if (-not [IO.File]::Exists((Get-MoveKnownFile))) { return '' }
  $r = Invoke-MoveTool 'ssh-keygen' @('-F', $Addr, '-f', (Get-MoveKnownFile))
  if ($r.Code -ne 0) { return '' }
  foreach ($l in $r.Out) { if ("$l" -cmatch '\A\S+ (ssh-ed25519) ([A-Za-z0-9+/=]+)\s*\z') { return "$($Matches[1]) $($Matches[2])" } }
  ''
}
function Remove-MovePin([string]$Addr) { if ([IO.File]::Exists((Get-MoveKnownFile))) { [void](Invoke-MoveTool 'ssh-keygen' @('-R', $Addr, '-f', (Get-MoveKnownFile))) } }
# DESIGN-GAP (T10-G28): B.11.3 names the first-contact pin for new only; the move's known_hosts must also hold old's key. Reading: the
# first contact with an address that has no pin there (old at check / plan / rebuild, new at preflight) takes it with accept-new
# (ed25519 only); every later call is strict. This is the one place that decides it.
function Test-MoveFirstContact([string]$Addr) { -not (Get-MovePinnedKey $Addr) }
# SHA256 fingerprint of 'ssh-ed25519 <b64>'
function Get-MoveFingerprint([string]$KeyLine) {
  $f = @("$KeyLine" -split ' ')
  if ($f.Count -lt 2) { return '-' }
  try { 'SHA256:' + [Convert]::ToBase64String(([Security.Cryptography.SHA256]::Create()).ComputeHash([Convert]::FromBase64String($f[1]))).TrimEnd('=') } catch { '-' }
}
# a machine of the state: @{ Name = old|new; Alias; Addr; HostName } (HostName = Reach-Old override, '' when not needed)
function Get-MoveMachine($S, [string]$M) {
  $o = if ($M -ceq 'old') { $S.old } else { $S.new }
  $alias = [string]$o.alias; $addr = [string]$o.addr; $hn = ''
  if ($M -ceq 'old') { $i = Get-MoveSshInfo $alias; if ($i -and $i.HostName -cne $addr) { $hn = $addr } }   # D.0.7: the alias now points to new
  @{ Name = $M; Alias = $alias; Addr = $addr; HostName = $hn }
}
# one ssh to a machine with a deadline: @{ Code; Out; Err }. -Pin: the first contact takes the ed25519 key into the move's known_hosts (accept-new).
function Invoke-MoveRemote($Mach, [string]$Remote, [string]$Stdin, [int]$TimeoutSec, [switch]$Pin) {
  $o = @('-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=4', '-o', 'BatchMode=yes',
    '-o', "UserKnownHostsFile=$(Get-MoveKnownFile)", '-o', "StrictHostKeyChecking=$(if ($Pin) { 'accept-new' } else { 'yes' })", '-o', "HostKeyAlias=$($Mach.Addr)")
  if ($Pin) { $o += @('-o', 'HostKeyAlgorithms=ssh-ed25519') }
  if ($Mach.HostName) { $o += @('-o', "HostName=$($Mach.HostName)") }
  if (-not $Stdin) { $o += '-n' }
  Invoke-MoveTimedExe 'ssh' (@($o) + @($Mach.Alias, $Remote)) $Stdin $TimeoutSec
}
# the outcome of a gate answer: @{ Code (GATE_EXIT n, -1 = unknown: no GATE_EXIT, I16); Known; Lines; Transport }
function Complete-MoveResult($T, $Mach) {
  $lines = @($T.Out | ForEach-Object { "$_" })
  $g = @($lines | Where-Object { $_ -cmatch '\AGATE_EXIT [0-9]+\z' } | Select-Object -Last 1)
  $known = [bool]$g.Count -and $T.Code -ne 124
  $code = if ($known) { [int](($g[0] -split ' ')[1]) } else { -1 }
  # B.9.5 / E-G2: a gate without `--move` answers exactly this; the laptop maps it to gate-missing
  if ($known -and $code -eq 65 -and @($lines | Where-Object { $_ -ceq 'GATE_ERROR gate installed without exactly one project argument' }).Count -and -not @($lines | Where-Object { $_ -cmatch '\A(INV|MOVE) ' }).Count) {
    $lines = @("INV refuse gate-missing side=$($Mach.Name)", 'GATE_EXIT 65')
  }
  @{ Code = $code; Known = $known; Lines = $lines; Transport = [int]$T.Code }
}
# `fcode-deploy-gate --move <words>` on a machine; $Stdin (text) travels as one base64 line. -PreInstall: the call is the agreement probe of a new
# that has no gate yet (copy step 1, before copy (4) installs it): ssh's 127 (command not found) is then expected, not an unclear answer
function Invoke-MoveGate($Mach, [string[]]$Words, [string]$Stdin, [int]$TimeoutSec, [switch]$Quiet, [switch]$PreInstall) {
  foreach ($w in $Words) { if (-not (Test-MoveWord $w)) { Write-Host "lỗi: tham số '$("$w" -replace '[\x00-\x1f\x7f]', '?')' không hợp lệ."; return @{ Code = 65; Known = $true; Lines = @(); Transport = 65 } } }
  $cmd = '/usr/local/sbin/fcode-deploy-gate --move ' + ($Words -join ' ')
  $in = ''
  if ($Stdin) { $cmd = 'base64 -di | ' + $cmd; $in = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Stdin)) + "`n" }
  $r = Complete-MoveResult (Invoke-MoveRemote $Mach $cmd $in $TimeoutSec) $Mach
  if (-not $Quiet) { Write-MoveLines $r.Lines }
  if (-not $r.Known) {
    if ($PreInstall -and $r.Transport -eq 127) { Write-Host "máy '$($Mach.Alias)' chưa có công cụ chuyển máy; sẽ cài ngay bây giờ." }
    else { Write-Host "máy '$($Mach.Alias)' không trả lời rõ (không có GATE_EXIT; mã $($r.Transport))." }
  }
  $r
}
# a bash script over plain ssh (before the gate exists on new): arguments in a `set --` line of the payload, never on the ssh command line
function Invoke-MoveScript($Mach, [string]$Script, [string[]]$ScriptArgs = @(), [int]$TimeoutSec = 0, [switch]$Pin, [switch]$Quiet) {
  foreach ($a in @($ScriptArgs)) { if ("$a" -match '[\x00-\x1f\x7f]') { Write-Host 'lỗi: tham số của script có ký tự điều khiển.'; return @{ Code = 65; Lines = @() } } }
  $pre = if (@($ScriptArgs).Count) { 'set -- ' + ((@($ScriptArgs) | ForEach-Object { "'" + ("$_" -replace "'", "'\''") + "'" }) -join ' ') + "`n" } else { '' }
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pre + ($Script -replace "`r`n", "`n")))
  $to = if ($TimeoutSec -gt 0) { $TimeoutSec } else { Get-MoveConst 'script_s' }
  $t = Invoke-MoveRemote $Mach 'f=$(mktemp) && base64 -di >$f && bash $f </dev/null; rc=$?; rm -f $f; exit $rc' ($b64 + "`n") $to -Pin:$Pin
  $lines = @($t.Out | ForEach-Object { "$_" })
  if (-not $Quiet) { Write-MoveLines $lines }
  # every plain-ssh script exits with its own explicit codes, never 124/255 (the tcp script: `|| exit 1`), so these three are the transport
  if ($t.Code -in 124, 255, -1) { $script:MoveNoAnswer = $true; Write-Host "lỗi: không chạy được lệnh trên máy '$($Mach.Alias)' qua ssh (mã $($t.Code))." }
  @{ Code = [int]$t.Code; Lines = $lines }
}
# the box (coder) over plain ssh (Invoke-BoxScript, #39: `ssh <host alias>`, no instabox): @{ Code; Lines }
function Invoke-MoveBox([string]$Script, [string[]]$ScriptArgs = @()) {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = @(Invoke-BoxScript ($Script -replace "`r`n", "`n") $ScriptArgs 2>&1 | ForEach-Object { "$_" }); $code = [int]$LASTEXITCODE } catch { $o = @("$($_.Exception.Message)"); $code = 1 } finally { $ErrorActionPreference = $old }
  @{ Code = $code; Lines = $o }
}

# ---- plain-ssh scripts (CONTRACT §1.5). FCM_ROOT is a test hook: a prefix for every machine path; tools are called by name. ----
# E-P38 / B.2.5: the client command of every pass shape (DESIGN B.2.1 flags, + --checksum in the final column; files items add
# --delete-missing-args; fwd files read old's own list, back files a local list; back shapes with every map slot) and the server argv
# CONTRACT §6.3 (T0b, box/move-v2 c4ed7fa) gives for it, verbatim, with <path>, <list> and <map-slot> filled.
# One line per run: <shape><TAB><pull|push><TAB><client flags; @LIST@ = the list file><TAB><the exact server argv>.
function Get-MoveRsyncShapes {
  $P = '/srv/fcode-move-preflight/'; $L = '/var/lib/fcode-move/pin/preflight.lst'
  $base = '-aHAX --numeric-ids --delete --force --one-file-system --partial-dir=.fcode-move-partial --info=stats2,progress2'
  # CONTRACT §6.3, the four pass shapes: pre-copy column, --checksum column
  $t = @{
    'fwd-tree' = @('rsync --server --sender -lHogDtpAXrxe.iLsfxCIvu --numeric-ids --info=STATS2 . <path>', 'rsync --server --sender -lHogDtpAXrcxe.iLsfxCIvu --numeric-ids --info=STATS2 . <path>')
    'fwd-files' = @('rsync --server --sender -lHogDtpAXRxe.LsfxCIvu --delete-missing-args --numeric-ids --info=STATS2 --files-from <list> --from0 . <path>', 'rsync --server --sender -lHogDtpAXcRxe.LsfxCIvu --delete-missing-args --numeric-ids --info=STATS2 --files-from <list> --from0 . <path>')
    'back-tree' = @('rsync --server -lHogDtpAXrxe.iLsfxCIvu --delete --force --partial-dir .fcode-move-partial --numeric-ids <map-slot> --info=STATS2 . <path>', 'rsync --server -lHogDtpAXrcxe.iLsfxCIvu --delete --force --partial-dir .fcode-move-partial --numeric-ids <map-slot> --info=STATS2 . <path>')
    'back-files' = @('rsync --server -ldHogDtpAXRxe.LsfxCIvu --no-r --delete --force --delete-missing-args --partial-dir .fcode-move-partial --numeric-ids <map-slot> --info=STATS2 . <path>', 'rsync --server -ldHogDtpAXcRxe.LsfxCIvu --no-r --delete --force --delete-missing-args --partial-dir .fcode-move-partial --numeric-ids <map-slot> --info=STATS2 . <path>')
  }
  $maps = [ordered]@{ none = ''; user = '--usermap=2301:2201,2303:2203'; group = '--groupmap=2302:2202,2304:2204'; both = '--usermap=2301:2201,2303:2203 --groupmap=2302:2202,2304:2204' }
  $col = @(@('pre', ''), @('final', ' --checksum'))
  foreach ($k in 'fwd-tree', 'fwd-files', 'back-tree', 'back-files') {
    for ($i = 0; $i -lt 2; $i++) {
      $fl = $base + $col[$i][1]
      $mlist = if ($k.StartsWith('back')) { @($maps.Keys) } else { @('none') }
      foreach ($m in $mlist) {
        $f = $fl; if ($maps[$m]) { $f += ' ' + $maps[$m] }
        if ($k -ceq 'fwd-files') { $f += " --delete-missing-args --files-from=:$L --from0" } elseif ($k -ceq 'back-files') { $f += ' --delete-missing-args --files-from=@LIST@ --from0' }
        $want = $t[$k][$i].Replace('<path>', $P).Replace('<list>', $L)
        $want = if ($maps[$m]) { $want.Replace('<map-slot>', $maps[$m]) } else { $want.Replace(' <map-slot>', '') }
        "$k-$($col[$i][0])$(if ($k.StartsWith('back')) { "-$m" })`t$(if ($k.StartsWith('fwd')) { 'pull' } else { 'push' })`t$f`t$want"
      }
    }
  }
}
# CONTRACT §3.5 (B.5.2; W1-T7-DG-T7-1; rulings 05/11 (22), (24), 07/11 B66 (a)): the `platform` units (LIST platform-units) and paths (LIST platform-etc = /etc/instabox, the eight instabox files in /etc and the six instabox.conf systemd drop-ins, no glob,
# LIST platform-opt + the /usr/local list, in the order of MV_PLATFORM, each by its exact path; a directory entry covers what lies under it). One copy here: `preflight` and the 3b mixed-pair check read it.
function Get-MovePlatformUnits { @('instabox-data-init.service', 'instabox-guest-agent.service', 'instabox-guest-reboot.service', 'instabox-identity.service', 'instabox-ssh-hostkeys.service', 'instabox-user.service', 'sshd.service') }
function Get-MovePlatformPaths {
  $bin = 'bun bunx cargo cargo-clippy cargo-fmt cargo-miri claude clippy-driver codex corepack go gofmt instabox instabox-computer-use instabox-computer-use-proxy instabox-desktop instabox-mcp instabox-port mkswap node npm npx ocu opencode open-codex-computer-use-mcp open-computer-use open-computer-use-mcp pnpm pnpx rls rust-analyzer rustc rustdoc rustfmt rust-gdb rust-gdbgui rust-lldb rustup swapoff swapon uv uvx yarn yarnpkg'
  $sbin = 'instabox-data-init instabox-guest-agent instabox-identity instabox-preboot instabox-user'
  $etc = @('/etc/instabox', '/etc/profile.d/instabox-universal.sh', '/etc/profile.d/instabox-tmpdir.sh', '/etc/profile.d/zz-instabox-secrets.sh', '/etc/profile.d/instabox-npm.sh', '/etc/sudoers.d/90-instabox-sudo', '/etc/sysctl.d/60-instabox-ping.conf', '/etc/tmpfiles.d/instabox-data-tmp.conf', '/etc/ssl/certs/instabox-proxy.pem') +
    @('halt.target.d', 'poweroff.target.d', 'systemd-halt.service.d', 'systemd-poweroff.service.d', 'tmp.mount.d', 'user@1000.service.d' | ForEach-Object { "/etc/systemd/system/$_/instabox.conf" })
  $etc + @('/opt/containerd', '/opt/npm', '/opt/rust') + @($bin -split ' ' | ForEach-Object { "/usr/local/bin/$_" }) + @('/usr/local/etc/npmrc') + @($sbin -split ' ' | ForEach-Object { "/usr/local/sbin/$_" }) +
    @('/usr/local/share/ca-certificates/instabox-proxy.crt', '/usr/local/go', '/usr/local/include/node', '/usr/local/lib/instabox', '/usr/local/lib/node_modules', '/usr/local/share/doc', '/usr/local/share/instabox', '/usr/local/share/man/man1')
}
# `preflight` is a bash script the laptop ships and runs on new by plain ssh (B.0.2; W1-T10-G21).
# DESIGN-GAP (T10-G47, F8i): it does not check the B.0.2/B.14.8 space and inodes rule (that needs the manifest; the server checks space at
# transfer), and it does not prove that `--addr` itself answers on port 22: the laptop reaches new through its alias with HostKeyAlias=--addr.
function Get-MovePreflightScript {
  $shapes = (@(Get-MoveRsyncShapes) -join "`n")
  @'
#!/bin/bash
# fcode move: preflight
# D.2 step 2, plain ssh on new. Read-only. INV lines; exit 65 on any refuse, else 0.
# args: --old-addr <host[:port]> --addr <addr> --src-os <id-major> --src-arch <arch> --src-systemd <major>
R=${FCM_ROOT:-}
MV=$R/var/lib/fcode-move
oaddr= addr= sos= sarch= ssd=
while [ $# -gt 1 ]; do case $1 in --old-addr) oaddr=$2;; --addr) addr=$2;; --src-os) sos=$2;; --src-arch) sarch=$2;; --src-systemd) ssd=$2;; *) echo "INV refuse target-addr why=args"; exit 65;; esac; shift 2; done
nref=0
ref() { echo "INV refuse $*"; nref=$((nref + 1)); }
# B.0.2: OS, arch, systemd, address, host key
os=unknown-0
if [ -r "$R/etc/os-release" ]; then os=$(. "$R/etc/os-release"; v=${VERSION_ID%%.*}; echo "${ID:-unknown}-${v:-0}"); fi
[ "$os" = "$sos" ] || ref os src=$sos dst=$os
arch=$(uname -m); [ "$arch" = "$sarch" ] || ref arch src=$sarch dst=$arch
sd=$(systemctl --version 2>/dev/null | awk 'NR==1 { print $2 + 0 }'); sd=${sd:-0}
[ "$sd" -ge "${ssd:-0}" ] 2>/dev/null || ref os what=systemd src=$ssd dst=$sd
case $addr in ''|*[!A-Za-z0-9.-]*) ref target-addr addr=-;; esac
[ -s "$R/etc/ssh/ssh_host_ed25519_key.pub" ] || ref target-addr why=no-ed25519
# B.0.2: outbound ssh to --old-addr, HTTPS to github.com and the DoH resolver
oh=${oaddr%%:*}; op=22; case $oaddr in *:*) op=${oaddr##*:};; esac
case $oh in ''|*[!A-Za-z0-9.-]*) ref old-unreachable addr=-;; *) timeout 10 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$oh" "$op" 2>/dev/null || ref old-unreachable addr=$oaddr;; esac
curl -fsS -m 10 -o /dev/null https://github.com 2>/dev/null || ref new-unreachable host=github.com
curl -fsS -m 10 -o /dev/null -H 'accept: application/dns-json' 'https://1.1.1.1/dns-query?name=github.com&type=A' 2>/dev/null || ref dns why=unreachable
# B.5.2 / CONTRACT §3.5 scope: the platform list applies only when all seven unit files are in /etc/systemd/system
punits="@@PUNITS@@"
platform=1; for u in $punits; do [ -f "$R/etc/systemd/system/$u" ] || platform=0; done
ppaths=; [ "$platform" = 1 ] && ppaths="@@PPATHS@@"
inplat() { local q; for q in $ppaths; do case $1 in "$q"|"$q"/*) return 0;; esac; done; return 1; }
# B.0.3 except its user clause (the laptop applies it at D.2 step 3b)
[ -e "$MV/move-id" ] && ref target-not-empty path=/var/lib/fcode-move/move-id
owned=$(mktemp); trap 'rm -f "$owned" "$owned.opt"' EXIT
cat "$R"/var/lib/dpkg/info/*.list 2>/dev/null | sed 's#^/\(bin\|sbin\|lib\|lib64\)/#/usr/\1/#' | sort -u > "$owned"
# only a non-directory unowned entry refuses, named by the top-level entry that holds it (W1-T3-GAP-12); platform paths pass in scope
for d in /opt /srv /usr/local; do
  [ -d "$R$d" ] || continue
  find "$R$d" -xdev \( -type f -o -type l \) 2>/dev/null | while IFS= read -r p; do printf '%s\n' "${p#"$R"}"; done
done | sort -u | comm -23 - "$owned" | while IFS= read -r p; do
  inplat "$p" && continue
  # B.0.3 / CONTRACT §3.5 (ruling 04/11 (3) 2): base-files' link /usr/local/man, exactly with the link text share/man, is the one exemption
  [ "$p" = /usr/local/man ] && [ -L "$R/usr/local/man" ] && [ "$(readlink "$R/usr/local/man")" = share/man ] && continue
  case $p in /usr/local/*) b=/usr/local; r=${p#/usr/local/};; /opt/*) b=/opt; r=${p#/opt/};; /srv/*) b=/srv; r=${p#/srv/};; *) continue;; esac
  printf '%s\n' "$b/${r%%/*}"
done | sort -u | while IFS= read -r p; do echo "INV refuse target-not-empty path=${p// /_}"; done > "$owned.opt"
for p in "$R"/etc/systemd/system/*; do
  [ -f "$p" ] && [ ! -L "$p" ] || continue
  q=${p#"$R"}
  if [ "$platform" = 1 ]; then case " $punits " in *" ${q##*/} "*) continue;; esac; fi
  grep -qxF -- "$q" "$owned" || echo "INV refuse target-not-empty path=${q// /_}"
done >> "$owned.opt"
if command -v docker >/dev/null 2>&1; then docker ps --format '{{.Names}}' 2>/dev/null | while IFS= read -r c; do [ -n "$c" ] && echo "INV refuse target-not-empty path=container:$c"; done >> "$owned.opt"; fi
while IFS= read -r l; do echo "$l"; nref=$((nref + 1)); done < "$owned.opt"
# every uid >= 1000 user with home-nonskel (never refused here, K7)
getent passwd | awk -F: '$3 >= 1000 && $3 != 65534 { print $1 ":" $3 ":" $6 }' | while IFS=: read -r u uid home; do
  ns=0
  if [ -d "$R$home" ]; then
    while IFS= read -r f; do
      rel=${f#"$R$home"/}
      if [ -f "$R/etc/skel/$rel" ] && cmp -s "$f" "$R/etc/skel/$rel"; then continue; fi
      ns=1; break
    done < <(find "$R$home" -mindepth 1 \( -type f -o -type l \) 2>/dev/null)
  fi
  echo "INV target user=$u uid=$uid home-nonskel=$ns"
done
# new's groups (gid >= 1000), subid ranges and global addresses (B.0.2; W1-T11-DG-T11-4), and the platform scope (B.5.2)
getent group | awk -F: '$3 >= 1000 { print "INV target group=" $1 " gid=" $3 }'
for k in uid gid; do
  [ -r "$R/etc/sub$k" ] || continue
  while IFS=: read -r u s c; do
    case $u in ''|*[[:space:][:cntrl:]]*) continue;; esac   # the move's one name token (B.6.2.1): 1 to 256 characters, no blank, no control byte (`svc$`, `alice.smith`, `Debian-exim` are names)
    [ "${#u}" -le 256 ] || continue
    case $s in ''|*[!0-9]*) continue;; esac
    case $c in ''|*[!0-9]*) continue;; esac
    echo "INV target subid user=$u kind=$k start=$s count=$c"
  done < "$R/etc/sub$k"
done
ip -o addr show scope global 2>/dev/null | awk '{ split($4, a, "/"); if (a[1] != "") print "INV target addr=" a[1] }'
echo "INV target platform=$platform"
# stop_budget_s: B.5.8 over new's active non-infra services
tsec() { local v=$1 s=0 n u; [ "$v" = infinity ] && { echo 900; return; }
  for w in $v; do n=${w%%[a-z]*}; u=${w#"$n"}; case $u in min) s=$((s + n * 60));; h) s=$((s + n * 3600));; ms|us) ;; *) s=$((s + n));; esac; done; echo "$s"; }
sum=0
while IFS= read -r unit; do
  case $unit in systemd-*|dbus*|ssh.service|getty@*|serial-getty@*|console-*|keyboard-setup*|networking*|ifup@*|rsyslog*|apparmor*|kmod*|polkit*|ufw*|nftables*|fcode-deploy-w-*|fcode-deploy-g-*|fcode-move-*) continue;; esac
  if [ "$platform" = 1 ]; then case " $punits " in *" $unit "*) continue;; esac; fi
  t=$(tsec "$(systemctl show -p TimeoutStopUSec --value "$unit" 2>/dev/null)"); [ "${t:-0}" -gt 900 ] && t=900
  sum=$((sum + ${t:-0} + 30))
done < <(systemctl list-units --type=service --state=active --no-legend --plain 2>/dev/null | awk '{ print $1 }')
echo "INV target stop_budget_s=$sum"
# E-P38: the client command of every shape, run with a printing -e wrapper (no connection), compared with its CONTRACT item 6 template
w=$(mktemp); out=$(mktemp)
printf '#!/bin/sh\nshift\nprintf "%%s\\n" "$*" > "%s"\nexit 1\n' "$out" > "$w"; chmod 700 "$w"
nshape=0
tmpd=$(mktemp -d); lst=$(mktemp); printf 'a\0' > "$lst"
while IFS=$'\t' read -r shape dir flags want; do
  [ -n "$shape" ] || continue
  nshape=$((nshape + 1)); : > "$out"; flags=${flags//@LIST@/$lst}
  if [ "$dir" = pull ]; then rsync $flags -e "$w" "x:/srv/fcode-move-preflight/" "$tmpd/" >/dev/null 2>&1 </dev/null
  else rsync $flags -e "$w" "$tmpd/" "x:/srv/fcode-move-preflight/" >/dev/null 2>&1 </dev/null; fi
  [ "$(cat "$out")" = "$want" ] || ref target-rsync-argv shape=$shape
done <<'SHAPES'
@@SHAPES@@
SHAPES
rm -rf "$w" "$out" "$tmpd" "$lst"
[ "$nshape" -gt 0 ] || ref target-rsync-argv shape=none
[ "$nref" -eq 0 ] || exit 65
echo "INV ok"
exit 0
'@.Replace('@@SHAPES@@', $shapes).Replace('@@PUNITS@@', (@(Get-MovePlatformUnits) -join ' ')).Replace('@@PPATHS@@', (@(Get-MovePlatformPaths) -join ' '))
}
# D.3 step 2 (plain ssh on new): tools, the move key, MV_DIR/known_hosts in the OpenSSH form (DG-3, DG-5), own-keys; prints `MOVE key`.
# DESIGN-GAP (T10-G30): the NodeSource major comes as an extra `--node-major <n>` (CONTRACT §1.5 lists `--old-addr` and the key line only).
# DESIGN-GAP (T10-G31): own-keys captures the key files of EVERY uid ≥ 1000 user (the script has no manifest, so no same_users[]); adopt
# merges only the same_users[] ones (B.11.1).
function Get-MoveBootstrapKeyScript {
@'
#!/bin/bash
# fcode move: bootstrap key
# D.3 step 2, plain ssh on new. Idempotent.
# args: --old-addr <host[:port]> <ssh-ed25519 key of old> [--node-major <n>]
set -u
umask 077
R=${FCM_ROOT:-}
MV=$R/var/lib/fcode-move
[ "${1:-}" = --old-addr ] && [ $# -ge 3 ] || { echo "MOVE error bad-request why=old-addr"; exit 65; }
oaddr=$2; key=$3; shift 3; need=
if [ "${1:-}" = --node-major ]; then need=${2:-}; fi
case $oaddr in ''|*[!A-Za-z0-9.:-]*) echo "MOVE error bad-request why=old-addr"; exit 65;; esac
printf '%s\n' "$key" | grep -qE '^ssh-ed25519 [A-Za-z0-9+/=]+$' || { echo "MOVE error bad-request why=key"; exit 65; }
case $need in ''|*[!0-9]*) need=;; esac
host=${oaddr%%:*}; port=22; case $oaddr in *:*) port=${oaddr##*:};; esac
case $port in ''|*[!0-9]*) echo "MOVE error bad-request why=old-addr"; exit 65;; esac
nodemajor() { v=$(node --version 2>/dev/null); v=${v#v}; v=${v%%.*}; case $v in ''|*[!0-9]*) echo 0;; *) echo "$v";; esac; }
tools="rsync git curl flock mkfs.ext4 getfacl ssh-keygen"
missing=; for t in $tools; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
if [ -n "$missing" ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q >/dev/null 2>&1 || true
  apt-get install -y -q rsync git curl util-linux e2fsprogs acl >/dev/null 2>&1 || true
fi
if [ -n "$need" ] && [ "$(nodemajor)" != "$need" ]; then
  export DEBIAN_FRONTEND=noninteractive
  mkdir -p "$R/etc/apt/keyrings" "$R/etc/apt/sources.list.d"
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o "$R/etc/apt/keyrings/nodesource.gpg" 2>/dev/null &&
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${need}.x nodistro main" > "$R/etc/apt/sources.list.d/nodesource.list" &&
    apt-get update -q >/dev/null 2>&1; apt-get install -y -q nodejs >/dev/null 2>&1 || true
  [ "$(nodemajor)" = "$need" ] || { echo "MOVE error tool-missing name=nodejs"; exit 1; }
fi
for t in $tools; do command -v "$t" >/dev/null 2>&1 || { echo "MOVE error tool-missing name=$t"; exit 1; }; done
mkdir -p "$MV" && chmod 700 "$MV" || { echo "MOVE error tool-missing name=mv-dir"; exit 1; }
if [ ! -s "$MV/key" ]; then rm -f "$MV/key" "$MV/key.pub"; ssh-keygen -q -t ed25519 -N '' -C fcode-move -f "$MV/key" || { echo "MOVE error tool-missing name=ssh-keygen"; exit 1; }; fi
[ -s "$MV/key.pub" ] || ssh-keygen -y -f "$MV/key" > "$MV/key.pub" || { echo "MOVE error tool-missing name=ssh-keygen"; exit 1; }
chmod 600 "$MV/key"
if [ "$port" = 22 ]; then kh="$host $key"; else kh="[$host]:$port $key"; fi
printf '%s\n' "$kh" > "$MV/known_hosts.tmp" && mv -f "$MV/known_hosts.tmp" "$MV/known_hosts" || { echo "MOVE error tool-missing name=known_hosts"; exit 1; }
if [ ! -e "$MV/own-keys" ]; then   # captured once (B.11.1): root's key files and those of every uid >= 1000 user (absolute path)
  t=$(mktemp "$MV/.own-keys.XXXXXX")
  for f in authorized_keys authorized_keys2; do [ -r "$R/root/.ssh/$f" ] && while IFS= read -r l; do [ -n "$l" ] && printf '%s\t%s\n' "$f" "$l"; done < "$R/root/.ssh/$f"; done >> "$t"
  getent passwd | awk -F: '$3 >= 1000 && $3 != 65534 { print $6 }' | while IFS= read -r home; do
    for f in authorized_keys authorized_keys2; do p=$home/.ssh/$f; [ -r "$R$p" ] && while IFS= read -r l; do [ -n "$l" ] && printf '%s\t%s\n' "$p" "$l"; done < "$R$p"; done
  done >> "$t"
  chmod 600 "$t" && mv -f "$t" "$MV/own-keys"
fi
echo "MOVE key type=ssh-ed25519 pub=$(cut -d' ' -f2 "$MV/key.pub")"
exit 0
'@
}
# DESIGN-GAP (T10-G5): the closed gate file list B.9.2 lives in mv_gate_files on old; new has no gate yet, so the laptop's copy of
# the installed paths is here (install.sh ENTRY, MIGRATE_BIN, LIB_DIR, MOVE_LIB_DIR, the three units). Directories end in '/'.
function Get-MoveGatePaths { @('/usr/local/lib/fcode-deploy-gate/', '/usr/local/lib/fcode-move/', '/usr/local/sbin/migrate-v2.sh', '/etc/systemd/system/fcode-deploy.slice', '/etc/systemd/system/fcode-deploy-poll.service', '/etc/systemd/system/fcode-deploy-poll.timer', '/usr/local/sbin/fcode-deploy-gate') }
# D.3 step 4 (plain ssh on new): pull the gate files through old's door with the move key; the entry comes last
function Get-MoveBootstrapGateScript {
  $paths = (@(Get-MoveGatePaths) -join ' ')
  @'
#!/bin/bash
# fcode move: bootstrap gate
# D.3 step 4, plain ssh on new. args: --old-addr <host[:port]>
set -u
R=${FCM_ROOT:-}
MV=$R/var/lib/fcode-move
[ "${1:-}" = --old-addr ] && [ $# -ge 2 ] || { echo "MOVE error bad-request why=old-addr"; exit 65; }
oaddr=$2; host=${oaddr%%:*}; port=22; case $oaddr in *:*) port=${oaddr##*:};; esac
ssh="ssh -F /dev/null -i $MV/key -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$MV/known_hosts -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -p $port"   # as mv_ssh_opts: a moved old-side client config (Host * ProxyJump, Port, HostKeyAlias) never steers the pull
F="-aHAX --numeric-ids --delete --force --one-file-system --partial-dir=.fcode-move-partial --info=stats2,progress2"
for p in @@PATHS@@; do
  mkdir -p "$(dirname "$R${p%/}")"
  rsync $F -e "$ssh" "root@$host:$p" "$R$p" >/dev/null 2>&1 || { echo "MOVE error rsync-failed path=$p"; exit 1; }
done
systemctl daemon-reload 2>/dev/null
echo "MOVE item bootstrap-gate kind=gate state=done"
exit 0
'@.Replace('@@PATHS@@', $paths)
}
# DESIGN-GAP (T10-G2): B.0.2 compares new with src (OS, arch, systemd) and the clock (≤ 5 s) before `plan` on old exists, and no
# CONTRACT line carries those facts. Reading: this read-only script, on both machines. One line, MOVE facts.
# Ruling 04/11 #5 (T10c-LP): before it, one `MOVE legacy project=<name> origin=<url>` line per legacy project directory whose read-only
# `git remote get-url origin` answers (the push scan reads old's, Get-MovePushScan).
# DESIGN-GAP (T10d-LP-line, CONTRACT §7.7): ruling 5 gives no line form and the §7.7 `facts` row lists only `MOVE facts …`; this
# `MOVE legacy` form is the reading, for T0 to add to that row.
function Get-MoveFactsScript {
@'
#!/bin/bash
# fcode move: facts
# read-only
R=${FCM_ROOT:-}
os=unknown-0
if [ -r "$R/etc/os-release" ]; then os=$(. "$R/etc/os-release"; v=${VERSION_ID%%.*}; echo "${ID:-unknown}-${v:-0}"); fi
sd=$(systemctl --version 2>/dev/null | awk 'NR==1 { print $2 + 0 }')
for x in deal-sync=/opt/deal-sync vps-scraper=/opt/internal-scraper; do
  u=$(git -c safe.directory='*' -C "$R${x#*=}" remote get-url origin 2>/dev/null) && [ -n "$u" ] && echo "MOVE legacy project=${x%%=*} origin=$u"
done
echo "MOVE facts os=$os arch=$(uname -m) systemd=${sd:-0} epoch=$(date +%s)"
'@
}
# new's TCP connect to an address (D.2 step 3b, 0c): exit 0 = reachable, 1 = not (refused, or no answer in 8 s); 124/255 therefore come only from the transport
function Get-MoveTcpScript {
@'
#!/bin/bash
# fcode move: tcp
timeout 8 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" 2>/dev/null || exit 1
'@
}
# D.0.10 (W1-T10-G4, W1-T11-DG-T11-6): `rebuild read`, the read-only plain-ssh script on each machine; `MOVE target` on new only, when
# MV_DIR/target.json exists (W1-T11-DG-R11-2).
function Get-MoveRebuildScript {
@'
#!/bin/bash
# fcode move: rebuild read
# D.0.10; read-only
R=${FCM_ROOT:-}
MV=$R/var/lib/fcode-move
[ -r "$MV/move-id" ] || exit 1
echo "MOVE moveid $(grep -E '^[a-z_]+=[A-Za-z0-9._:-]*$' "$MV/move-id" | tr '\n' ' ' | sed 's/ $//')"
k=$(head -n1 "$R/etc/ssh/ssh_host_ed25519_key.pub" 2>/dev/null); [ -n "$k" ] && echo "MOVE hostkey $k"
punits="@@PUNITS@@"
platform=1; for u in $punits; do [ -f "$R/etc/systemd/system/$u" ] || platform=0; done
echo "INV target platform=$platform"
for d in "$MV"/run/*/; do
  [ -d "$d" ] || continue
  id=$(basename "$d"); rc=$(cat "$d/rc" 2>/dev/null); st=$(cat "$d/start" 2>/dev/null); en=$(cat "$d/end" 2>/dev/null)
  sn=$(awk '$0=="--since"{getline; print; exit}' "$d/argv" 2>/dev/null); [[ $sn =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || sn=
  sh=$(awk '$0=="--sha"{getline; print; exit}' "$d/argv" 2>/dev/null); [[ $sh =~ ^[0-9a-f]{64}$ ]] || sh=
  echo "MOVE record id=$id start=${st:--} end=${en:--} rc=${rc:--} since=${sn:--} sha=${sh:--}"
done
if [ -r "$MV/manifest.json" ] && [ -r "$MV/manifest.json.sha256" ]; then
  echo "MOVE manifest sha=$(cut -c1-64 "$MV/manifest.json.sha256") gz64=$(gzip -c -n "$MV/manifest.json" | base64 -w0)"
fi
if [ -r "$MV/target.json" ]; then
  echo "MOVE target $(tr -d '\r\n' < "$MV/target.json")"
fi
# the durable snapshot of c.init-new's `target` key: the call's recorded stdin (run/<id>/in; the init publishes the move-id BEFORE it writes target.json, so a kill between the two
# leaves a move-id without target.json); the newest c.init-new record's last key `,"target":{…}}`, printed as one line
bs=; bd=
for d in "$MV"/run/*-c.init-new/; do
  [ -f "$d/in" ] || continue
  s=$(cat "$d/start" 2>/dev/null)
  if [ -z "$bd" ] || [[ $s > $bs ]]; then bs=$s; bd=$d; fi
done
if [ -n "$bd" ]; then
  ti=$(tr -d '\r\n' < "$bd/in" | sed -n 's/.*,"target":\(.*\)}$/\1/p')
  [ -n "$ti" ] && echo "MOVE target-in $ti"
fi
exit 0
'@.Replace('@@PUNITS@@', (@(Get-MovePlatformUnits) -join ' '))
}
# step 11 on the coder box: the alias block `Host <alias>` gets HostName <addr>; HostKeyAlias <key alias> (or none); a known_hosts line added
# args: <alias> <hostname> <hostkeyalias|-> <known line|->. Prints `MOVE alias coder state=done|none`.
function Get-MoveCoderAliasScript {
@'
#!/bin/bash
# fcode move: coder alias
set -u
umask 077
alias=$1; hn=$2; hka=$3; kl=$4
d=$HOME/.ssh; cfg=$d/config
[ -r "$cfg" ] || { echo "MOVE alias coder state=none"; exit 0; }
grep -qiE "^[[:space:]]*Host[[:space:]]+$alias[[:space:]]*$" "$cfg" || { echo "MOVE alias coder state=none"; exit 0; }
t=$(mktemp "$d/.fcode-move.XXXXXX") || exit 1
awk -v a="$alias" -v hn="$hn" -v hka="$hka" '
  function flush() { if (inb && !done) { print "  HostName " hn; if (hka != "-") print "  HostKeyAlias " hka; done = 1 } }
  /^[[:space:]]*(Host|Match)[[:space:]]/ { flush(); inb = (tolower($1) == "host" && $2 == a && NF == 2); done = 0; print; next }
  inb && /^[[:space:]]*(HostName|HostKeyAlias)[[:space:]=]/ { next }
  { print }
  END { flush() }' "$cfg" > "$t" && chmod 600 "$t" && mv -f "$t" "$cfg" || { rm -f "$t"; exit 1; }
if [ "$kl" != - ]; then touch "$d/known_hosts"; grep -qxF -- "$kl" "$d/known_hosts" || printf '%s\n' "$kl" >> "$d/known_hosts"; fi
echo "MOVE alias coder state=done"
'@
}

# ---- recorded calls (K1, D.0.1, D.0.3, D.0.5, D.0.6) ----
# the verb words of a step of the closed list (CONTRACT §1.3); verify's --seed/--since are added by the caller
function Get-MoveStepVerb([string]$Step) {
  switch -CaseSensitive ($Step) {
    { $_ -in 'c.init-old', 'b.init-old' } { return @('init', '--role', 'old') }
    { $_ -in 'c.init-new', 'b.init-new' } { return @('init', '--role', 'new') }
    { $_ -in 'c.repin.N', 'x.repin' } { return @('init', '--repin') }
    { $_ -in 'c.prepare.N', 'x.prepare-id' } { return @('prepare') }
    'c.transfer.N' { return @('transfer') }
    'x.final' { return @('transfer', '--final') }
    { $_ -in 'c.verify.N', 'x.verify' } { return @('verify') }
    { $_ -in 'c.adopt.N', 'x.adopt' } { return @('adopt') }
    'x.freeze' { return @('freeze') }
    'x.check' { return @('plan', '--check') }
    'x.baseline' { return @('health', '--baseline') }
    'x.guards' { return @('stop', '--guards') }
    { $_ -in 'x.stop-src', 'x.stop-dst', 'r.stop-dst' } { return @('stop') }
    'x.start' { return @('start') }
    { $_ -in 'x.enable.N', 'r.start-src' } { return @('start', '--enable') }
    { $_ -in 'x.health', 'r.health-src' } { return @('health') }
    'x.switch' { return @('switch') }
    { $_ -in 'x.unfreeze.N', 'r.unfreeze-src' } { return @('unfreeze') }
    { $_ -in 'f.old', 'f.new' } { return @('finish') }
    { $_ -in 'a.old', 'a.new' } { return @('abort') }
    'p.pm2-save.N' { return @('pm2-save') }
    'p.cert-renew.N' { return @('cert-renew') }
  }
  throw "Get-MoveStepVerb: '$Step' is not in the closed step list"
}
# Σ of a per-hold budget field over a hold set of the manifest (B.5.8, B.5.10)
function Get-MoveSetBudget($M, [string]$Set, [string]$Field) {
  $ids = @(Get-MoveProp (Get-MoveProp $M 'hold_sets') $Set @()); $sum = 0
  foreach ($h in @(Get-MoveProp $M 'holds' @())) { if ($ids -ccontains [string]$h.id) { $sum += [int](Get-MoveProp $h $Field 0) } }
  $sum
}
# the holds of a set of the manifest (hold objects whose id is in hold_sets.<set>)
function Get-MoveSetHolds($M, [string]$Set) {
  $ids = @(Get-MoveProp (Get-MoveProp $M 'hold_sets') $Set @())
  @(@(Get-MoveProp $M 'holds' @()) | Where-Object { $_ -and $ids -ccontains [string]$_.id })
}
# K1 freeze row (DECISION-1k6-K1budget, D.0.6): Σ stop_budget_s over the periodic sources (kind `unit`, in hold_sets.stop, id
# cron.service, *.timer or *.path) and over every hold of the same scope (no `user`, as the server's _mvh_followers_of) whose
# triggered_by[] names one of them; the union, each hold once
function Get-MovePeriodicBudget($M) {
  $src = @(Get-MoveSetHolds $M 'stop' | Where-Object { [string]$_.kind -ceq 'unit' -and [string]$_.id -cmatch '\A(cron\.service|.+\.timer|.+\.path)\z' })
  $sid = @($src | ForEach-Object { [string]$_.id }); $seen = @{}; $sum = 0
  foreach ($h in $src) { $seen[[string]$h.id] = $true; $sum += [int](Get-MoveProp $h 'stop_budget_s' 0) }
  foreach ($h in @(Get-MoveProp $M 'holds' @())) {
    if (-not $h -or $seen.ContainsKey([string]$h.id) -or [string](Get-MoveProp $h 'user' '')) { continue }
    if (@(@(Get-MoveProp $h 'triggered_by' @()) | Where-Object { $sid -ccontains [string]$_ }).Count) { $seen[[string]$h.id] = $true; $sum += [int](Get-MoveProp $h 'stop_budget_s' 0) }
  }
  $sum
}
# the manifest's `tunnel` names (hostnames[] class tunnel)
function Get-MoveTunnelCount($M) { @(@(Get-MoveProp $M 'hostnames' @()) | Where-Object { $_ -and [string]$_.class -ceq 'tunnel' }).Count }
# K1 health row (x.baseline, x.health, r.health-src): 300 + 10 × (|redis[]| + |pg[]|) + 20 × tunnel names + 60 × container holds of
# hold_sets.start + 40 × linger holds of hold_sets.start + 60 × the user-container holds of those users + 20 × |health[]| + Σ health_budget_s
function Get-MoveHealthBudget($M) {
  $st = @(Get-MoveSetHolds $M 'start')
  $lu = @($st | Where-Object { [string]$_.kind -ceq 'linger' } | ForEach-Object { $u = [string](Get-MoveProp $_ 'user' ''); if (-not $u) { $u = ([string]$_.id) -replace '\Alinger:', '' }; $u })
  $uc = @(@(Get-MoveProp $M 'holds' @()) | Where-Object { $_ -and [string]$_.kind -ceq 'user-container' -and $lu -ccontains [string](Get-MoveProp $_ 'user' '') }).Count
  $hl = @(@(Get-MoveProp $M 'health' @()) | Where-Object { $_ }); $hs = 0; foreach ($x in $hl) { $hs += [int](Get-MoveProp $x 'health_budget_s' 0) }
  300 + 10 * (@(Get-MoveProp $M 'redis' @()).Count + @(Get-MoveProp $M 'pg' @()).Count) + 20 * (Get-MoveTunnelCount $M) + 60 * @($st | Where-Object { [string]$_.kind -ceq 'container' }).Count +
    40 * $lu.Count + 60 * $uc + 20 * $hl.Count + $hs
}
# K1 switch row: 60 + 140 × unit connectors + 140 × container connectors + 20 × tunnel names
function Get-MoveSwitchBudget($M) {
  $c = @(@(Get-MoveProp $M 'connectors' @()) | Where-Object { $_ -and [string]$_.kind -cin 'unit', 'container' }).Count
  60 + 140 * $c + 20 * (Get-MoveTunnelCount $M)
}
# K1 start row (x.start, x.enable.N, r.start-src; ruling 06/11 (30), B36; B70 P3-2): Σ start_budget_s of hold_sets.start + 60, then the two ready
# checks chore 0 can run (lib/move-hold.sh _mvh_conn_check, each one MVH_CONN_READY_S 20 + MVH_CONN_STABLE_S 20 window of its own):
# unit connectors (a connectors[] entry of kind unit whose id is in hold_sets.start): + 60, + 20 per listener after the first; N, the listeners
# the check probes, = Σ over those connector holds of max(1, |holds[].listen[]|): the entries pinned in the manifest, and at least the one
# metrics listener each connector has when none is pinned. Container connectors (kind container, id in hold_sets.start): + 40 (the two windows)
# + 180 each: three `docker inspect` bounded at 60 s (the "was it running" read before the start, the ready probe, the stability re-probe).
# Both kinds in the start set: both terms (the checks run one after the other)
function Get-MoveStartBudget($M) {
  $ids = @(Get-MoveProp (Get-MoveProp $M 'hold_sets') 'start' @())
  $cid = @(@(Get-MoveProp $M 'connectors' @()) | Where-Object { $_ -and [string]$_.kind -ceq 'unit' -and $ids -ccontains [string]$_.id } | ForEach-Object { [string]$_.id })
  $nct = @(@(Get-MoveProp $M 'connectors' @()) | Where-Object { $_ -and [string]$_.kind -ceq 'container' -and $ids -ccontains [string]$_.id }).Count
  $t = (Get-MoveSetBudget $M 'start' 'start_budget_s') + 60
  if ($cid.Count) {
    $n = 0
    foreach ($c in $cid) {
      $h = @(Get-MoveProp $M 'holds' @()) | Where-Object { $_ -and [string]$_.id -ceq $c } | Select-Object -First 1
      $n += [Math]::Max(1, @(Get-MoveProp $h 'listen' @()).Count)
    }
    $t += 60 + 20 * ($n - 1)
  }
  if ($nct) { $t += 40 + 180 * $nct }
  $t
}
# K1 stop row (x.stop-src, x.stop-dst, r.stop-dst): Σ stop_budget_s of hold_sets.stop + 30 + 600 per Redis hold (counted as the redis[]
# entries, D.0.6) + 60 per pm2 hold (pm2-*.service, B.5.9) + 120 per container/user-container hold of the stop set
function Get-MoveStopBudget($M) {
  $st = @(Get-MoveSetHolds $M 'stop')
  (Get-MoveSetBudget $M 'stop' 'stop_budget_s') + 30 + 600 * @(Get-MoveProp $M 'redis' @()).Count + 60 * @($st | Where-Object { [string]$_.id -cmatch '\Apm2-.+\.service\z' }).Count +
    120 * @($st | Where-Object { [string]$_.kind -cin 'container', 'user-container' }).Count
}
# --budget of a step on a machine: the D.0.6 first-run table (K1 as amended by DECISION-1k6-K1budget), then max(table, 3 x the last
# measured dur_s of that step there). x.check 300 when 0c's duration is unknown (W1-T10-G27); a later c.transfer.N 2 × transfer_s + 300
# (first copy 6 h, W1-T10-G29).
function Get-MoveBudget($S, [string]$Step, [string]$Machine) {
  $M = Get-MoveManifestObj; $e = $S.est
  $ts = Get-MoveProp $e 'transfer_s'; $vs = Get-MoveProp $e 'verify_s'
  $t = switch -CaseSensitive ($Step) {
    'x.freeze' { (Get-MoveConst 'cap_s') + (Get-MovePeriodicBudget $M) + 30; break }
    'x.guards' { $g = 0; foreach ($x in @(Get-MoveProp $M 'guards' @())) { if ($x) { $g += [int](Get-MoveProp $x 'run_s' 0) } }; (Get-MoveConst 'cap_s') + $g + 30; break }
    { $_ -in 'x.baseline', 'x.health', 'r.health-src' } { Get-MoveHealthBudget $M; break }
    { $_ -in 'x.stop-src', 'x.stop-dst', 'r.stop-dst' } { Get-MoveStopBudget $M; break }
    'c.transfer.N' { if ($null -ne $ts) { 2 * [int]$ts + 300 } else { Get-MoveConst 'first_transfer_s' }; break }   # "the laptop's estimate (first copy 6 h)"
    'x.final' { if ($null -ne $ts) { 2 * [int]$ts + 300 } else { Get-MoveConst 'first_transfer_s' }; break }
    { $_ -in 'c.verify.N', 'x.verify' } { if ($null -ne $vs) { 2 * [int]$vs + 120 } else { Get-MoveConst 'first_verify_s' }; break }
    { $_ -in 'c.adopt.N', 'x.adopt' } { Get-MoveConst 'adopt_s'; break }
    { $_ -in 'x.start', 'x.enable.N', 'r.start-src' } { Get-MoveStartBudget $M; break }
    'x.switch' { Get-MoveSwitchBudget $M; break }
    'c.init-new' { [int](Get-MoveTargetStopBudget $S) + 60; break }
    'c.prepare.N' { (Get-MoveConst 'other_s') + 1800; break }   # D.0.6 / CONTRACT §5: 300 + the apt-get bound 1800 (B.7.3 installs the manual packages in prepare); x.prepare-id stays 300
    'x.check' { if ($script:MoveCheckOnlyS) { 3 * [int]$script:MoveCheckOnlyS + 60 } else { Get-MoveConst 'other_s' }; break }
    default { Get-MoveConst 'other_s' }
  }
  $d = Get-MoveProp (Get-MoveProp $S.dur $Step) $Machine
  if ($null -ne $d -and 3 * [int]$d -gt [int]$t) { $t = 3 * [int]$d }
  [int]$t
}
# D.0.6 `c.init-new` = preflight's stop_budget_s + 60, kept as state target_stop_budget_s (W1-T10-G6; 0 when unknown)
function Get-MoveTargetStopBudget($S) { [int](Get-MoveProp $S 'target_stop_budget_s' 0) }
# the call id of a step under the state's dir and attempt (p.*: attempt 0); .N raised (and saved) before the call, never reset in an attempt.
# DESIGN-GAP (T10-G19): D.0.3 raises N "before each call", while c.repin.N and c.verify.N run on both machines in one pass; reading: one
# pass = one N, raised before the first machine's call and reused ($Pass) for the second, so both machines record the same call id.
function New-MoveCallId($S, [string]$Step, [int]$Pass = 0) {
  $att = if ($Step.StartsWith('p.')) { 0 } else { [int]$S.attempt }
  $sid = $Step
  if ($Step.EndsWith('.N')) {
    $base = $Step.Substring(0, $Step.Length - 2); $k = "$($S.dir)-$att-$base"
    $n = if ($Pass -gt 0) { $Pass } else { [int](Get-MoveMapVal $S.pass $k 0) + 1 }
    Set-MoveMapVal $S.pass $k $n; Save-MoveState $S
    $sid = "$base.$n"
  }
  @{ Id = "$($S.dir)-$att-$sid"; Attempt = $att }
}
function Get-MovePassOf([string]$Id) { if ($Id -match '\.([0-9]+)\z') { [int]$Matches[1] } else { 0 } }
# one recorded call: `--move <verb> <id> --dir --attempt --sha --call --budget --serving --mark --dst-started --phase [args]`.
# @{ Code; Lines; Id; Known }. Code -1 = unknown outcome after the real-state resolution (I16): the machine did not answer.
function Invoke-MoveCall($S, [string]$Machine, [string]$Step, [string[]]$VArgs = @(), [string]$Stdin = '', [switch]$Quiet, [int]$Pass = 0) {
  $c = New-MoveCallId $S $Step $Pass; $id = $c.Id
  $verb = @(Get-MoveStepVerb $Step)
  $budget = Get-MoveBudget $S $Step $Machine
  $mark = if ($S.mark) { [string]$S.mark } else { 'null' }
  # manifest_sha_prev (D.0.9 laptop state, L1): while it is set the dst machine still pins A (src re-pinned B at x.check): every dst call that does
  # not pin a manifest carries A; a pinning call (init: c.init-*, b.init-*, c.repin.N, x.repin) stores its --sha as the pin, so it carries the
  # sha of the manifest it ships (manifest_sha, B)
  $sha = Get-MoveCallSha $S $Machine ($verb[0] -ceq 'init')
  $words = @($verb[0], [string]$S.move_id, '--dir', [string]$S.dir, '--attempt', "$($c.Attempt)", '--sha', $sha, '--call', $id, '--budget', "$budget",
    '--serving', [string]$S.serving, '--mark', $mark, '--dst-started', $(if ($S.dst_started -eq $true) { '1' } else { '0' }), '--phase', [string]$S.phase) + @($verb | Select-Object -Skip 1) + @($VArgs)
  $mach = Get-MoveMachine $S $Machine
  if (-not $Quiet) { Write-Host "$id trên '$($mach.Alias)'..." }
  $r = $null
  for ($try = 1; $try -le (Get-MoveConst 'retries'); $try++) {
    $r = Invoke-MoveGate $mach $words $Stdin ($budget + 60) -Quiet:$Quiet
    Add-MoveLog $mach.Alias $id $r.Lines
    if ($r.Known) { break }
    # I16 / D.0.5: no GATE_EXIT = unknown. Both status answers first (the called machine decides): running = attach, done = replay,
    # failed = definite, interrupted or absent = run again
    $other = if ($Machine -ceq 'old') { 'new' } else { 'old' }
    $st = Get-MoveStatus $S $Machine -Quiet
    $so = Get-MoveStatus $S $other -Quiet
    foreach ($l in @(@($st.Lines) + @($so.Lines) | Where-Object { "$_" -cmatch '\AMOVE state ' })) { Write-Host "  $l" }
    if (-not $st.Ok) { $script:MoveNoAnswer = $true; return @{ Code = -1; Lines = $r.Lines; Id = $id; Known = $false } }
    if ([string]$st.Kv['call'] -ceq $id -and [string]$st.Kv['call_state'] -ceq 'failed') { Set-MoveNetLoss $r.Lines; return @{ Code = $(if ("$($st.Kv['rc'])" -match '\A[0-9]+\z') { [int]$st.Kv['rc'] } else { 1 }); Lines = $r.Lines; Id = $id; Known = $true } }
  }
  if (-not $r.Known) { $script:MoveNoAnswer = $true; return @{ Code = -1; Lines = $r.Lines; Id = $id; Known = $false } }
  # a dst call that carried manifest_sha_prev (A) and was refused `what=sha`: dst already pins B (a lost x.repin that ran to the end: the ssh dropped, the
  # unit did not stop). The refusal leaves no record, so the same id is sent once more with manifest_sha; any answer but that refusal shows dst pins it and clears prev
  if ($sha -cne [string]$S.manifest_sha -and $r.Code -eq 65 -and @($r.Lines | Where-Object { "$_" -cmatch '\AMOVE error move-id-mismatch what=sha\b' }).Count) {
    $w2 = @($words); $w2[[Array]::IndexOf($w2, '--sha') + 1] = [string]$S.manifest_sha
    $r2 = Invoke-MoveGate $mach $w2 $Stdin ($budget + 60) -Quiet:$Quiet
    Add-MoveLog $mach.Alias $id $r2.Lines
    if ($r2.Known) {
      $r = $r2
      if (-not @($r2.Lines | Where-Object { "$_" -cmatch '\AMOVE error move-id-mismatch what=sha\b' }).Count) { Set-MoveProp $S 'manifest_sha_prev' ''; Save-MoveState $S }
    }
  }
  # a call to the SRC machine refused `what=sha` (it carried manifest_sha A): an x.check whose answer was lost (no GATE_EXIT, the one I16 status failed) may
  # have run to the end and pinned B on src (`ssh loss never stops the unit`), and the rollback that follows would be refused on every r.* call. The refusal leaves
  # no record, so this attempt's x.check id is replayed (a done record answers with its stored out, whatever sha it carries; not done = refused again, nothing
  # runs), B is taken from its `MOVE manifest` line (prev := A, as at the x.check rc 0), and the refused call is re-sent once with the new sha. B39: a src call
  # carries the manifest it was refused for only after the laptop saw the pin
  if ($Step -cne 'x.check' -and $verb[0] -cne 'init' -and $r.Code -eq 65 -and $Machine -ceq (Get-MoveSide $S 'src') -and @($r.Lines | Where-Object { "$_" -cmatch '\AMOVE error move-id-mismatch what=sha\b' }).Count) {
    $xc = Invoke-MoveCall $S $Machine 'x.check' @() (Get-MovePlanStdin $S @(Get-MoveMapText) $Machine) -Quiet
    if ($xc.Code -eq 0 -and (Set-MoveCheckManifest $S $xc.Lines)) {
      $w3 = @($words); $w3[[Array]::IndexOf($w3, '--sha') + 1] = (Get-MoveCallSha $S $Machine $false)
      $r3 = Invoke-MoveGate $mach $w3 $Stdin ($budget + 60) -Quiet:$Quiet
      Add-MoveLog $mach.Alias $id $r3.Lines
      if ($r3.Known) { $r = $r3 }
    }
  }
  foreach ($l in $r.Lines) {
    if ("$l" -cmatch '\AMOVE call id=(\S+) rc=([0-9]+) dur_s=([0-9]+)\z' -and $Matches[1] -ceq $id) {
      $o = Get-MoveProp $S.dur $Step; if ($null -eq $o) { $o = [pscustomobject]@{}; Set-MoveMapVal $S.dur $Step $o }
      Set-MoveProp $o $Machine ([int]$Matches[3]); Save-MoveState $S
    }
  }
  if ($r.Code -eq 0 -and $verb[0] -ceq 'init' -and (Get-MoveProp $S 'manifest_sha_prev' '') -and $Machine -ceq (Get-MoveSide $S 'dst')) { Set-MoveProp $S 'manifest_sha_prev' ''; Save-MoveState $S }   # dst now pins manifest_sha
  if ($r.Code -ne 0) { Set-MoveNetLoss $r.Lines }
  @{ Code = $r.Code; Lines = $r.Lines; Id = $id; Known = $true }
}
# x.check rc 0's `MOVE manifest` line (D.4 step 3): src re-pinned it, so manifest_sha = B and the manifest is saved; manifest_sha_prev = the sha dst still pins
# (set only when empty and the sha changes: a resumed or replayed x.check, B already saved, never overwrites A); the `INV warn transient-excluded` names are kept.
# $false when the lines carry no usable manifest line (missing, bad gzip/base64, sha mismatch): nothing is changed then
function Set-MoveCheckManifest($S, $Lines) {
  $mf = ConvertFrom-MoveManifestLine $Lines
  if (-not $mf) { return $false }
  if (-not (Get-MoveProp $S 'manifest_sha_prev' '') -and [string]$S.manifest_sha -cne $mf.Sha) { Set-MoveProp $S 'manifest_sha_prev' ([string]$S.manifest_sha) }
  Set-MoveProp $S 'manifest_sha' $mf.Sha; Save-MoveManifest $mf.Text; $script:MoveManifest = @{ Text = $mf.Text; Obj = $mf.Obj }; Save-MoveState $S
  $tr = @($Lines | Where-Object { $_ -cmatch '\AINV warn transient-excluded unit=' } | ForEach-Object { if ($_ -cmatch 'unit=(\S+)') { $Matches[1] } }); if ($tr.Count) { Set-MoveAnswer $S 'transient-excluded' @($tr); Save-MoveState $S }
  $true
}
# the --sha of a call to $Machine: manifest_sha_prev (A) for a dst call that pins no manifest while it is set, else manifest_sha
function Get-MoveCallSha($S, [string]$Machine, [bool]$Pins) {
  $prev = [string](Get-MoveProp $S 'manifest_sha_prev' '')
  if ($prev -and -not $Pins -and $Machine -ceq (Get-MoveSide $S 'dst')) { return $prev }
  [string]$S.manifest_sha
}
# B26 (ruling 05/11 (20)): a copy that failed with `MOVE error rsync-failed why=net` (any c.transfer.N, x.final) is a no-answer of the sending
# side: it marks the run like a lost call, so the one exit of `fcode move` (Invoke-Move) ends an exit 1 with the re-run sentence. Set-only.
function Set-MoveNetLoss($Lines) { if (@($Lines | Where-Object { "$_" -cmatch '\AMOVE error rsync-failed why=net' }).Count) { $script:MoveNoAnswer = $true } }
# DESIGN-GAP (T10-G46, F8g): D.15 fixes "không = exit 0, nothing written" for Q-cut only; reading: Q-cut and Q-abort "không" end 0,
# while a data-loss question (Q-back, Q-finish) answered with anything but YES ends 65 (refused, nothing done).
function Get-MoveDeclinedExit { 65 }
# `status` (unrecorded, 60 s), with the state's four side flags (D.0.1): @{ Ok; Code; Kv (the MOVE state words); Lines; Known; Transport }
function Get-MoveStatus($S, [string]$Machine, [string[]]$Extra = @(), [switch]$Quiet, [switch]$PreInstall) {
  $Mach = Get-MoveMachine $S $Machine
  $w = @('status', [string]$S.move_id, '--dir', [string]$S.dir, '--attempt', "$($S.attempt)", '--sha', (Get-MoveCallSha $S $Machine $false), '--serving', [string]$S.serving)
  $r = Invoke-MoveGate $Mach (@($w) + @($Extra)) '' (Get-MoveConst 'status_s') -Quiet -PreInstall:$PreInstall
  $kv = @{}; $line = @($r.Lines | Where-Object { $_ -cmatch '\AMOVE state ' } | Select-Object -First 1)
  if ($line.Count) { $kv = ConvertFrom-MoveKv $line[0] }
  if (-not $Quiet) { Write-MoveLines $r.Lines }
  @{ Ok = [bool]($r.Known -and $r.Code -eq 0 -and $line.Count); Code = $r.Code; Kv = $kv; Lines = $r.Lines; Known = $r.Known; Transport = $r.Transport }
}
function Get-MoveSide($S, [string]$Side) { if (([string]$S.dir -ceq 'fwd') -eq ($Side -ceq 'src')) { 'old' } else { 'new' } }
function Test-MoveFrozen($Kv) { $f = [string]$Kv['frozen']; [bool]($f -and $f -cne '0' -and $f -cne '-') }

# ---- D.11: the K1 agreement check, the chore-0 pre-rule, the resume table ----
# DESIGN-GAP (T10-G9): D.11's last row says "machines disagree on (dir, attempt)". Reading: only a machine that holds this move's open
# move-id can disagree; a machine without it (before `c.init-*`) is initialised by the verb's own steps.
# F2 (D.5.1-D.5.3, D.9, E-R2, E-R4, E-R15): a new that does not answer status after the bounded retries (transport 255/124/-1) is marked
# down ($script:MoveNewDown) and skipped, never a failure here; no other call goes to it in this verb (Invoke-Move picks the rows that
# go on without it). Old not answering stays a failure.
function Sync-MoveAgreement($S, [string]$Verb = '') {
  $script:MoveSeen = @{}; $script:MoveNewDown = $false
  if ([string]$S.phase -cin 'finished', 'aborted') { return 0 }
  $order = if ([string]$S.dir -ceq 'back') { @('new', 'old') } else { @('old', 'new') }   # b.init-new, b.init-old (D.5.2, D.8); c.init-old, c.init-new (D.3)
  foreach ($m in $order) {
    # the first copy's probe of new: verb copy, fwd, phase planned and no gate_id yet (copy (4) stores it) = the gate is not installed yet
    $pre = [bool]($m -ceq 'new' -and $Verb -ceq 'copy' -and [string]$S.dir -ceq 'fwd' -and [string]$S.phase -ceq 'planned' -and -not [string](Get-MoveProp $S 'gate_id' ''))
    $st = Get-MoveStatus $S $m -Quiet -PreInstall:$pre
    for ($i = 2; $m -ceq 'new' -and -not $st.Known -and $st.Transport -in 124, 255, -1 -and $i -le (Get-MoveConst 'retries'); $i++) { Wait-Move 5; $st = Get-MoveStatus $S $m -Quiet -PreInstall:$pre }
    if (-not $st.Ok) {
      if (-not $st.Known -and $st.Transport -notin 124, 255, -1) { continue }   # no gate answer there yet (new before `bootstrap gate`): it holds no move-id
      if ($m -ceq 'new' -and -not $st.Known) { $script:MoveNewDown = $true; $script:MoveNewDownCode = $st.Transport; Write-Host "máy mới '$((Get-MoveMachine $S 'new').Alias)' không trả lời (mã $($st.Transport)); bỏ qua máy mới trong lệnh này."; continue }
      if ($st.Known) { return (Write-MoveStatusFail $S $m $st) }   # R10-INT-31 item 10: an answer that is not GATE_EXIT 0 is never a no-answer
      return (Write-MoveNoAnswer ([string]$(if ($m -ceq 'old') { $S.old.alias } else { $S.new.alias })) 'khi đọc status' $st.Transport)
    }
    $script:MoveSeen[$m] = $st
    # D.11 last row (W1-T10-G9): in phase planned a machine without a move-id is not a disagreement (copy's own c.init-* create it); in every other phase it is
    # re-init-ed like one (a wiped or restored box); another or a closed move-id: nothing of this move runs there (no re-init, no fence)
    if ([string]$st.Kv['move_id'] -ceq '-' -and [string]$S.phase -cne 'planned') {
      $c = Invoke-MoveInit $S $m
      if ($c -ne 0) { return $c }
    } elseif ([string]$st.Kv['move_id'] -cne [string]$S.move_id -or [string]$st.Kv['state'] -cne 'open') { continue }
    elseif ([string]$st.Kv['dir'] -cne [string]$S.dir -or [string]$st.Kv['attempt'] -cne "$($S.attempt)") {
      $c = Invoke-MoveInit $S $m
      if ($c -ne 0) { return $c }
    }
    # R2-1 (D.11: the agreement check before any recorded call): the lost/discarded-new fence (G12) runs after new's own agreement step,
    # only when new holds this move's open move-id, once per verb, and before any row call to new
    if ($m -ceq 'new') { $c = Invoke-MoveNewFence $S; if ($c -ne 0) { return $c } }
  }
  0
}
# init on one machine for the state's (dir, attempt): c.init-* in fwd, b.init-* in back; init stdin per D.0.9 Formats
function Invoke-MoveInit($S, [string]$M) {
  $mf = Read-MoveManifest
  if (-not $mf) { Write-Host "lỗi: thiếu manifest.json; $(Get-MoveText 'rebuild'): fcode move status --rebuild."; return 1 }
  $j = '{"manifest":' + $mf.Text.Trim() + ',"old_addr":' + (ConvertTo-Json -InputObject ([string]$S.old.addr) -Compress) + ',"new_addr":' + (ConvertTo-Json -InputObject ([string]$S.new.addr) -Compress)
  $fwd = [string]$S.dir -ceq 'fwd'
  if ($M -ceq 'old') {
    if ($fwd) {
      $pub = Get-MovePub $S
      if (-not $pub) { return 1 }
      $j += ',"pub":' + (ConvertTo-Json -InputObject $pub -Compress) + ',"alias":' + (ConvertTo-Json -InputObject ([string]$S.new.alias) -Compress) + '}'
      $r = Invoke-MoveCall $S 'old' 'c.init-old' @() $j
    } else { $r = Invoke-MoveCall $S 'old' 'b.init-old' @() ($j + '}') }
  } else {
    if ($fwd) {
      $r = Invoke-MoveCall $S 'new' 'c.init-new' @() ($j + ',"target":' + (Get-MoveTargetJson $S) + '}')
      if ($r.Code -eq 0) {
        # D.5.3 (W1-T10-O1): a later attempt's c.init-new rc 0 re-initialises new quiet as a fresh dst, so the fence flags clear
        Set-MoveProp $S 'new_lost' $false; Set-MoveProp $S 'new_discarded' $false
        # B.5.11 (W1-T3-DG-R3-5): its `INV warn dst-own-unit` / `INV warn new-only` lines are kept in answers{} for Q-cut.
        # DESIGN-GAP (T10c-W1, the key name is not given): answers{'init-new-warn'}, replaced at each c.init-new rc 0
        Set-MoveAnswer $S 'init-new-warn' @($r.Lines | Where-Object { "$_" -cmatch '\AINV warn (dst-own-unit|new-only) ' })
        Save-MoveState $S
      }
    } else { $r = Invoke-MoveCall $S 'new' 'b.init-new' @() ($j + '}') }
  }
  if ($r.Code -eq 0) { return 0 }
  ConvertTo-MoveExit $r.Code
}
# c.init-new's `"target"` stdin key (D.0.9 Formats, target.json): the state's target_* values
function Get-MoveTargetJson($S) {
  $o = [ordered]@{
    users = @(@($S.target_users) | Where-Object { $_ } | ForEach-Object { [ordered]@{ name = [string]$_.name; uid = [int]$_.uid } })
    groups = @(@(Get-MoveProp $S 'target_groups' @()) | Where-Object { $_ } | ForEach-Object { [ordered]@{ name = [string]$_.name; gid = [int]$_.gid } })
    subids = @(@(Get-MoveProp $S 'target_subids' @()) | Where-Object { $_ } | ForEach-Object { [ordered]@{ user = [string]$_.user; kind = [string]$_.kind; start = [long]$_.start; count = [long]$_.count } })
    addrs = @(@(Get-MoveProp $S 'target_addrs' @()) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    stop_budget_s = [int](Get-MoveTargetStopBudget $S)
  }
  ConvertTo-Json -InputObject $o -Compress -Depth 5
}
# the move key's public line from new (bootstrap key is idempotent: it prints the existing key)
function Get-MovePub($S) {
  if ($script:MovePub) { return $script:MovePub }
  $a = @('--old-addr', (Get-MoveOldAddrForNew $S), (Get-MoveProp $S.old 'hostkey_line' ''))
  $nm = Get-MoveNodeMajor; if ($nm) { $a += @('--node-major', $nm) }
  $k = Invoke-MoveScript (Get-MoveMachine $S 'new') (Get-MoveBootstrapKeyScript) $a
  if ($k.Code -ne 0) { return '' }
  foreach ($l in $k.Lines) { if ("$l" -cmatch '\AMOVE key type=ssh-ed25519 pub=([A-Za-z0-9+/=]+)\z') { $script:MovePub = "ssh-ed25519 $($Matches[1])"; return $script:MovePub } }
  Write-Host 'lỗi: máy mới không trả khoá công khai của khoá chuyển máy (thiếu dòng MOVE key).'
  ''
}
# DESIGN-GAP (T10-G10): `--old-addr` (the address new uses to reach old: a relay in the harness) is needed again by every copy and
# re-init, and D.0.9 has no field for it (old.addr is the alias HostName, B.10.2, D.0.7). Reading: state old.via, default old.addr.
function Get-MoveOldAddrForNew($S) { $v = [string](Get-MoveProp $S.old 'via' ''); if ($v) { $v } else { [string]$S.old.addr } }
# NodeSource major of the manifest (pkgs[] nodejs), '' when none
# (T10-G30: the major passed to bootstrap key)
function Get-MoveNodeMajor {
  foreach ($p in @(Get-MoveProp (Get-MoveManifestObj) 'pkgs' @())) { if ([string](Get-MoveProp $p 'name') -ceq 'nodejs' -and "$(Get-MoveProp $p 'version')" -match '\A(?:[0-9]+:)?([0-9]+)\.') { return $Matches[1] } }
  ''
}
# chore 0 on a machine (D.4 step 10, D.11 pre-rule): x.enable.N, x.unfreeze.N; enabled=true only when both returned 0
function Invoke-MoveChore0($S, [string]$M) {
  $a = Invoke-MoveCall $S $M 'x.enable.N'
  $b = Invoke-MoveCall $S $M 'x.unfreeze.N'
  if ($a.Code -eq 0 -and $b.Code -eq 0) { Set-MoveProp $S 'enabled' $true; Save-MoveState $S; return 0 }
  Set-MoveProp $S 'enabled' $false; Save-MoveState $S
  Write-Host "lỗi: chưa bật lại được máy đang phục vụ ('$((Get-MoveMachine $S $M).Alias)'); chạy lại lệnh vừa rồi để sửa."
  1
}
# D.11 pre-rule: only when mark is null; the serving machine with enabled=false or its marker still held runs chore 0 first
function Invoke-MovePreRule($S) {
  if ($S.mark -or [string]$S.phase -cin 'finished', 'aborted') { return 0 }
  $m = [string]$S.serving
  $held = $false
  if ($S.enabled -eq $true) {
    $st = $script:MoveSeen[$m]; if (-not $st) { $st = Get-MoveStatus $S $m -Quiet }
    if (-not $st.Ok) { return 0 }   # the row's own calls report an unreachable machine
    $held = Test-MoveFrozen $st.Kv
    if (-not $held) { return 0 }
  }
  Invoke-MoveChore0 $S $m
}
# the write-ahead of a new run or an end state, then the agreement check before the next recorded call (K1)
function Set-MoveWriteAhead($S, [hashtable]$Fields, [switch]$NoCheck) {
  foreach ($k in $Fields.Keys) { Set-MoveProp $S $k $Fields[$k] }
  Save-MoveState $S
  if ($NoCheck) { return 0 }
  Sync-MoveAgreement $S
}
# D.11: the row of the state for a verb: @{ Do = <action>; Msg = <refusal text> } (refusals exit 1)
function Resolve-MoveRow([string]$Verb, $S) {
  $phase = [string]$S.phase; $mark = [string]$S.mark; $dir = [string]$S.dir
  $ref = @{ Do = 'refuse'; Msg = "lệnh '$Verb' không dùng được lúc này (hướng $dir, giai đoạn $phase$(if ($mark) { ", đang $mark" }))." }
  $say = { param($t) @{ Do = 'refuse'; Msg = $t } }
  if ($phase -cin 'finished', 'aborted') { if ($Verb -cin 'finish', 'abort') { return @{ Do = 'idem' } }; return $ref }
  if ($S.carry -eq $true) {   # E-R34: with carry=true only the row `back | planned, carry=true` applies
    if ($Verb -ceq 'cutover') { return @{ Do = 'carry-resume' } }
    if ($Verb -ceq 'back') { return (& $say (Get-MoveText 'carrying')) }
    return $ref
  }
  # a return to old is a rollback: `rolling-back` with old serving (carry=false) is resumed by `cutover` in either dir (a plain rollback, Q-newlost, Q-discard), everything else is
  # refused. A manual back's rolling-back with NEW serving (dir=back) is the E-R19 end: it keeps the cut-resume row below
  if ($mark -ceq 'rolling-back' -and ($dir -ceq 'fwd' -or [string]$S.serving -ceq 'old')) { if ($Verb -ceq 'cutover') { return @{ Do = 'rb-continue' } }; return $ref }
  if ($mark) {
    if ($dir -ceq 'fwd') {
      if ($Verb -ceq 'cutover') { return @{ Do = 'cut-resume' } }
      if ($Verb -ceq 'back' -and ($mark -ceq 'switching' -or $S.dst_started -eq $true)) { return (& $say (Get-MoveText 'cut-carries')) }
      return $ref
    }
    if ($Verb -cin 'cutover', 'back') { return @{ Do = 'cut-resume' } }
    return $ref
  }
  if ($dir -ceq 'back' -and $phase -cin 'planned', 'copied') {
    switch -CaseSensitive ($Verb) { 'copy' { return @{ Do = 'back-precopy' } } 'cutover' { return @{ Do = 'back-run' } } 'back' { return @{ Do = 'back-run' } } }
    return $ref
  }
  switch -CaseSensitive ($phase) {
    'planned' { switch -CaseSensitive ($Verb) { 'copy' { return @{ Do = 'copy-first' } } 'cutover' { return (& $say (Get-MoveText 'copy-first')) } 'back' { return (& $say (Get-MoveText 'old-running')) } 'abort' { return @{ Do = 'abort' } } } }
    'copied' { switch -CaseSensitive ($Verb) { 'copy' { return @{ Do = 'copy-refresh' } } 'cutover' { return @{ Do = 'cut-run' } } 'abort' { return @{ Do = 'abort' } } } }
    'cut' { switch -CaseSensitive ($Verb) { 'cutover' { return @{ Do = 'chores' } } 'back' { return @{ Do = 'back-start' } } 'finish' { return @{ Do = 'finish' } } } }
    'rolled-back' { switch -CaseSensitive ($Verb) { 'copy' { return @{ Do = 'copy-attempt' } } 'cutover' { return (& $say (Get-MoveText 'copy-first')) } 'abort' { return @{ Do = 'abort' } } } }
    'back-done' { switch -CaseSensitive ($Verb) { 'copy' { return @{ Do = 'copy-attempt' } } 'back' { return @{ Do = 'back-chores' } } 'abort' { return @{ Do = 'abort' } } } }
  }
  $ref
}

# ---- check (D.1): preventive and zero-write ----
function Invoke-MoveCheckCmd {
  $oldAlias = Get-DeployHost
  if (-not $oldAlias) { Write-Host 'lỗi: deployHost trong file cấu hình không dùng được.'; return 1 }
  $oi = Get-MoveSshInfo $oldAlias
  if (-not $oi -or -not (Test-MoveAddr $oi.HostName)) { Write-Host "lỗi: ssh -G không đọc được địa chỉ của '$oldAlias'."; return 1 }
  $mach = @{ Name = 'old'; Alias = $oldAlias; Addr = $oi.HostName; HostName = '' }
  if (Test-MoveFirstContact $oi.HostName) { $p = Invoke-MoveScript $mach (Get-MoveFactsScript) @() (Get-MoveConst 'tcp_s') -Pin -Quiet; if ($p.Code -ne 0) { if ($p.Code -in 124, 255, -1) { return (Write-MoveNoAnswer $oldAlias 'khi nối' $p.Code) }; Write-Host "lỗi: không đọc được dữ kiện máy cũ '$oldAlias' (mã $($p.Code))."; return 1 } }
  $r = Invoke-MoveGate $mach @('plan', '-', '--check-only') ((@(Get-MoveDefaultMap) -join "`n") + "`n") (Get-MoveConst 'plan_s') -Quiet   # D.0.9 / W1-T3-GAP-1: the default map lines only
  if (-not $r.Known) { return (Write-MoveNoAnswer $oldAlias 'khi kiểm tra' $r.Transport) }
  $now = @($r.Lines | Where-Object { $_ -cmatch '\A(INV (refuse|warn|host|target|inbound|os)|MOVE error) ' })
  $cp = Get-MovePath 'check.json'; $prev = @()
  if ([IO.File]::Exists($cp)) { try { $prev = @((ConvertFrom-Json ([IO.File]::ReadAllText($cp))).lines) } catch { $prev = @() } }
  $new = @($now | Where-Object { $prev -cnotcontains $_ }); $same = @($now | Where-Object { $prev -ccontains $_ })
  if ($new.Count) { Write-Host 'Mới so với lần check trước:'; Write-MoveLines $new; if ($same.Count) { Write-Host 'Như lần trước:' } }
  Write-MoveLines $same
  Write-MoveConnectorUnitRemedies $now   # B77: the check prints the unit remedy under its line (a container's stays label-only here)
  Write-PhienText $cp (ConvertTo-Json -InputObject ([pscustomobject][ordered]@{ at = (Format-MoveTs (Get-MoveNow)); lines = @($now) }) -Depth 4)
  $refused = @($now | Where-Object { $_ -cmatch '\A(INV refuse|MOVE error) ' }).Count -gt 0 -or $r.Code -ne 0
  if ($refused) { Write-Host 'check: có điểm sẽ bị từ chối khi plan (mã 65).'; return 65 }
  Write-Host 'check: không có gì bị từ chối.'
  0
}

# ---- plan (D.2) and the re-plan of a copy refresh (D.3) ----
# DESIGN-GAP (T10-G48, F8j): B.14.2 says the owner may remove the default lines; reading: the first plan always prepends them and writes
# map.txt; the owner removes them by editing map.txt, which every re-plan (copy refresh) reads.
function Get-MoveDefaultMap { @('exclude user dino', 'exclude unit velh-pilot-hourly.timer') }   # B.14.2, owner answers I.8, I.10; ruling 05/11 (27) B33 dropped `exclude /etc/ssl/certs` (T3's B.13 certs rule decides the files under it)
# map lines of a --map file; $null (printed) when it is not usable
function Read-MoveMapLines([string]$Path) {
  try { $t = [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF) } catch { Write-Host "lỗi: không đọc được file map $Path."; return $null }
  $l = @($t -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
  foreach ($x in $l) { if ($x -cmatch '\A(target-user|dial|target-addr|idmap|platform-user)\b' -or $x -match '[\x00-\x1f\x7f]') { Write-MoveLines @("INV refuse map-invalid ref=$(($x -split ' ')[0])"); return $null } }   # D.0.9 (O1: platform-user too): the laptop's stdin lines are no map lines; a map file holding one is map-invalid
  , $l
}
function Get-MoveMapText { $p = Get-MovePath 'map.txt'; if ([IO.File]::Exists($p)) { @([IO.File]::ReadAllText($p) -split "`r?`n" | Where-Object { $_ }) } else { @(Get-MoveDefaultMap) } }
# O1 (ruling 04/11 (3) 5; CONTRACT §4.1 old/new.platform_user): the platform login user of a target is NAMED in the laptop's config.json,
# `moveTargets.<ssh alias>.platform_user` (one name or empty), never guessed. '' = unset; $null = not a name (printed; the caller exits 65).
function Get-MovePlatformUser([string]$Alias) {
  $mt = Get-Cfg 'moveTargets' $null
  $e = $null; $has = $false
  if ($null -ne $mt) {
    if ($mt -isnot [Management.Automation.PSCustomObject]) { Write-Host "lỗi: khóa moveTargets trong config.json không phải một đối tượng { `"<tên ssh>`": { `"platform_user`": `"<tên user>`" } }."; return $null }
    $p = $mt.PSObject.Properties[$Alias]
    if ($p) { $has = $true; $e = $p.Value }
  }
  if ($has) {
    if ($e -isnot [Management.Automation.PSCustomObject]) { Write-Host "lỗi: khóa moveTargets.$Alias trong config.json không phải một đối tượng { `"platform_user`": `"<tên user>`" }."; return $null }
    $pp = $e.PSObject.Properties['platform_user']
    if ($pp -and $pp.Value -isnot [string]) { Write-Host "lỗi: khóa moveTargets.$Alias.platform_user trong config.json không phải một chuỗi (tên user Linux hoặc để trống)."; return $null }
  }
  $v = Get-MoveProp $e 'platform_user'
  if ($null -eq $v -or ($v -is [string] -and $v -ceq '')) { return '' }
  if ($v -is [string] -and $v -cmatch '\A[a-z_][a-z0-9_.-]*\z') { return $v }   # the target-user name regex (lib/move-plan.sh stdin reader)
  Write-Host "lỗi: platform_user của máy '$Alias' trong config.json (moveTargets) không hợp lệ: cần một tên user Linux hoặc để trống."
  $null
}
# `plan <id>` on old (unrecorded, no side flags): stdin = the map lines, then one `target-user <name> <uid>` per target_users[], one
# `dial <old addr> <new addr>`, one `target-addr <a>` per target_addrs[], one `idmap <user|group> <name> <src_id> <dst_id>` per idmap[]
# (D.0.9 Formats; B.14.1, B.12.5, B.6.2) and, when the source machine's ($Src) platform_user is set, one `platform-user <name>` (O1: old's
# on old for fwd, new's on new for back); `plan <id> --check-only` and `x.check` read the same stdin. @{ Code; Lines; Mf }
function Get-MovePlanStdin($S, [string[]]$Map, [string]$Src = 'old') {
  $pu = [string](Get-MoveProp $(if ($Src -ceq 'new') { $S.new } else { $S.old }) 'platform_user' '')
  $in = @($Map) + @(@($S.target_users) | Where-Object { $_ } | ForEach-Object { "target-user $($_.name) $($_.uid)" }) + @("dial $($S.old.addr) $($S.new.addr)") +
    @(@(Get-MoveProp $S 'target_addrs' @()) | Where-Object { $_ } | ForEach-Object { "target-addr $_" }) +
    @(@(Get-MoveProp $S 'idmap' @()) | Where-Object { $_ } | ForEach-Object { "idmap $($_.kind) $($_.name) $($_.src_id) $($_.dst_id)" }) +
    @(if ($pu) { "platform-user $pu" })
  ($in -join "`n") + "`n"
}
function Invoke-MovePlanOld($S, [string[]]$Map) {
  $r = Invoke-MoveGate (Get-MoveMachine $S 'old') @('plan', [string]$S.move_id) (Get-MovePlanStdin $S $Map) (Get-MoveConst 'plan_s') -Quiet
  $mf = ConvertFrom-MoveManifestLine $r.Lines
  @{ Code = $r.Code; Known = $r.Known; Lines = $r.Lines; Mf = $mf; Transport = $r.Transport }
}
# DESIGN-GAP (DG-R1, CONTRACT §4.1): target_platform is read by D.0.10 from the `INV target platform=` line of new's `rebuild read` (preflight's probe of the platform units);
# a state without the field counts as 0.
function Get-MoveTargetPlatform($S) { [int](Get-MoveProp $S 'target_platform' 0) }
# D.2 step 3b and the D.3 re-plan's 3b: the B.5.2 mixed-pair check against the stored target_platform (GAP-RULINGS-3 §16.5, §16.7 T-4).
# With platform=1 on new, refuses target-not-empty path=<p> (ruling 05/11 (25), B31) for: (1) every item root (tree, file) or `files` name
# that is a platform path, lies under one, or HOLDS one (an ancestor, e.g. a tree /etc/profile.d: its transfer would overwrite or, with
# --delete, delete new's platform files; a `files` item's own root is only its base directory and is not tested); (2) every
# `deleted_conffiles` entry at or under a platform path (the conffile delete would remove new's file); (3) every unit file
# /etc/systemd/system/<u> of a platform unit among those. Refusal lines.
function Get-MovePlatformRefusals($S, $M) {
  if ((Get-MoveTargetPlatform $S) -ne 1) { return @() }
  $pp = @(Get-MovePlatformPaths); $pu = @(Get-MovePlatformUnits | ForEach-Object { "/etc/systemd/system/$_" }); $all = @($pp) + @($pu); $hit = @()
  $isAt = { param($p) ($pu -ccontains $p) -or @($pp | Where-Object { $p -ceq $_ -or $p.StartsWith("$_/", [StringComparison]::Ordinal) }).Count }
  foreach ($it in @(Get-MoveProp $M 'items' @())) {
    if (-not $it) { continue }
    $root = ([string]$it.root).TrimEnd('/')
    if ([string]$it.kind -ceq 'files') {   # the root is only the base directory: tested as a platform path, never as an ancestor
      if (& $isAt $root) { $hit += $root }
      $names = @(@(Get-MoveProp $it 'files_from' @()) | ForEach-Object { "$root/$(([string]$_).TrimEnd('/'))" })
    } else { $names = @($root) }
    foreach ($p in $names) { if ((& $isAt $p) -or @($all | Where-Object { $_.StartsWith("$p/", [StringComparison]::Ordinal) }).Count) { $hit += $p } }
  }
  foreach ($c in @(Get-MoveProp $M 'deleted_conffiles' @())) {
    $p = ([string]$(if ($c -is [string]) { $c } else { Get-MoveProp $c 'path' '' })).TrimEnd('/')
    if ($p -and (& $isAt $p)) { $hit += $p }
  }
  @($hit | Select-Object -Unique | ForEach-Object { "INV refuse target-not-empty path=$_" })
}
# D.2 step 3b: the B.0.3 user clause and the B.6.2 / K7 compare (users, groups, subid ranges; W1-T11-DG-T11-4, W1-T10-G25) against
# preflight's stored target_* values. Refusal lines. `<home>` = /home/<user> (W1-T10-G11).
# DESIGN-GAP (T10c-UC): no line form is given for a gid collision or the subid overlap; reading: a gid collision uses K7's one form
# (`user=<group> uid=<gid> holder=<h>`); a subid overlap with another user's range of the same kind (subuid or subgid) is
# `uid-collision what=subuid user=<u> holder=<h>` (B.6.5, E-P22).
function Get-MoveUserRefusals($S, $M) {
  $out = @(); $users = @(Get-MoveProp $M 'users' @())
  foreach ($t in @($S.target_users)) {
    $same = @($users | Where-Object { [string]$_.name -ceq [string]$t.name -and [int]$_.uid -eq [int]$t.uid }).Count -gt 0
    if ([int](Get-MoveProp $t 'home_nonskel' 0) -eq 1 -and -not $same) { $out += "INV refuse target-not-empty path=/home/$($t.name)" }
  }
  foreach ($u in $users) {
    if ([int]$u.uid -lt 1000) { continue }
    foreach ($t in @($S.target_users)) {
      $nm = [string]$t.name -ceq [string]$u.name; $id = [int]$t.uid -eq [int]$u.uid
      if ($nm -ne $id) { $out += "INV refuse uid-collision user=$($u.name) uid=$($u.uid) holder=$($t.name)" }
    }
  }
  foreach ($g in @(Get-MoveProp $M 'groups' @())) {
    if (-not $g -or [int]$g.gid -lt 1000) { continue }
    foreach ($t in @(Get-MoveProp $S 'target_groups' @())) {
      if (-not $t) { continue }
      $nm = [string]$t.name -ceq [string]$g.name; $id = [int]$t.gid -eq [int]$g.gid
      if ($nm -ne $id) { $out += "INV refuse uid-collision user=$($g.name) uid=$($g.gid) holder=$($t.name)" }
    }
  }
  foreach ($x in @(Get-MoveProp $M 'subids' @())) {
    if (-not $x) { continue }
    $a0 = [long]$x.start; $a1 = $a0 + [long]$x.count
    foreach ($t in @(Get-MoveProp $S 'target_subids' @())) {
      if (-not $t -or [string]$t.kind -cne [string]$x.kind -or [string]$t.user -ceq [string]$x.name) { continue }
      $b0 = [long]$t.start; $b1 = $b0 + [long]$t.count
      if ($a0 -lt $b1 -and $b0 -lt $a1) { $out += "INV refuse uid-collision what=subuid user=$($x.name) holder=$($t.user)" }
    }
  }
  $out
}
# D.2 step 3b, 0c: new's TCP connect to the manifest's egress[] pairs and the `INV host external` services (warn only)
# B.14.9: egress[] {addr, port} (W1-T10-G24)
function Test-MoveReach($S, $M, $Lines) {
  $pairs = @()
  foreach ($e in @(Get-MoveProp $M 'egress' @())) { $a = [string](Get-MoveProp $e 'addr' ''); $p = [string](Get-MoveProp $e 'port' ''); if ($a -and $p) { $pairs += , @($a, $p) } }
  foreach ($l in @($Lines)) { if ("$l" -cmatch '\AINV host external=\S+ service=([A-Za-z0-9.-]+):([0-9]+)\z') { $pairs += , @($Matches[1], $Matches[2]) } }
  $new = Get-MoveMachine $S 'new'
  foreach ($pp in $pairs) {
    $r = Invoke-MoveScript $new (Get-MoveTcpScript) @($pp[0], $pp[1]) (Get-MoveConst 'tcp_s') -Quiet
    if ($r.Code -in 124, 255, -1) { return (Write-MoveNoAnswer ([string]$S.new.alias) 'khi kiểm tra kết nối ra ngoài' $r.Code) }   # item 12: only the transport; a refused or silent connect is exit 1 = warn egress
    if ($r.Code -ne 0) { Write-MoveLines @("INV warn egress addr=$($pp[0]) port=$($pp[1])") }
  }
  0
}
# D.2 step 4 / 0c: gh admin on the state's legacy_push[] repos (B.10.4). Refusal lines.
function Get-MoveGhRefusals($S) {
  $out = @()
  foreach ($lp in @(Get-MoveProp $S 'legacy_push' @())) {
    $repo = [string](Get-MoveProp $lp 'repo' ''); if (-not (Test-DeployRepo $repo)) { continue }
    $r = Invoke-MoveTool 'gh' @('secret', 'list', '-R', $repo)
    if ($r.Code -ne 0) { $out += "INV refuse gh-permission repo=$repo" }
  }
  $out
}
# B.10.5 push scan (D.2 step 4; a rebuild scans again, D.0.10): the owner's repos (`gh repo list --limit 1000`, W1-T10-G23) whose
# workflows match DEPLOY_KNOWN_HOSTS, ssh-keyscan, an ssh deploy action (appleboy/ssh-action, webfactory/ssh-agent) or secrets.*HOST*.
# @{ Ok; Push = @(@{ Repo; File }) (ssh-push); Legacy = @({project, repo}) (gate-push, the state's legacy_push[], W1-T3-GAP-11) }
# Ruling 04/11 #5 (T10c-LP): a matched repo is gate-push when its slug equals the `origin` remote of a legacy project's directory on
# old (`MOVE legacy` lines of old's facts, read here at every scan); `project` = that legacy name. Every other match is ssh-push (Q-sshpush).
# DESIGN-GAP (T10d-LP-slug, P3): "slug" form not given; reading: ConvertTo-MoveSlug (host not checked), case ignored (as GitHub names).
function Get-MovePushScan($S) {
  $script:MoveFactsDown = $null
  $fo = Get-MoveFacts (Get-MoveMachine $S 'old')
  if (-not $fo) { if ($script:MoveFactsDown) { [void](Write-MoveNoAnswer ([string]$S.old.alias) 'khi đọc dữ kiện' $script:MoveFactsDown.Code) } else { Write-Host "lỗi: không đọc được dữ kiện máy cũ '$($S.old.alias)' (mã $script:MoveFactsCode)." }; return @{ Ok = $false } }
  $ls = Invoke-MoveTool 'gh' @('repo', 'list', '--limit', '1000', '--json', 'nameWithOwner')
  if ($ls.Code -ne 0) { Write-Host 'lỗi: gh không liệt kê được repo (gh auth login?).'; return @{ Ok = $false } }
  try { $repos = @(ConvertFrom-Json ($ls.Out -join "`n") | ForEach-Object { [string]$_.nameWithOwner }) } catch { Write-Host 'lỗi: gh trả danh sách repo không đọc được.'; return @{ Ok = $false } }
  $push = @(); $legacy = @()
  foreach ($repo in $repos) {
    if (-not (Test-DeployRepo $repo)) { continue }
    $w = Invoke-MoveTool 'gh' @('api', "repos/$repo/contents/.github/workflows")
    if ($w.Code -ne 0) { if (($w.Out -join ' ') -match '404|Not Found') { continue }; Write-Host "lỗi: gh không đọc được workflow của $repo."; return @{ Ok = $false } }
    try { $files = @(ConvertFrom-Json ($w.Out -join "`n") | ForEach-Object { [string]$_.name } | Where-Object { $_ -cmatch '\A[A-Za-z0-9._-]+\.ya?ml\z' }) } catch { continue }
    $hits = @()
    foreach ($f in $files) {
      $tx = Invoke-MoveTool 'gh' @('api', "repos/$repo/contents/.github/workflows/$f", '-H', 'Accept: application/vnd.github.raw')
      if ($tx.Code -ne 0) { Write-Host "lỗi: gh không đọc được $f của $repo."; return @{ Ok = $false } }
      $t = $tx.Out -join "`n"
      if ($t -notmatch 'DEPLOY_KNOWN_HOSTS|ssh-keyscan|appleboy/ssh-action|webfactory/ssh-agent|secrets\.\w*HOST\w*') { continue }
      $hits += $f
    }
    $lp = @($fo.Legacy | Where-Object { $hits.Count -and $_.Slug -and $_.Slug -ieq $repo } | Select-Object -First 1)
    if ($lp.Count) { $legacy += [pscustomobject][ordered]@{ project = [string]$lp[0].Project; repo = $repo }; continue }   # gate-push (B.10.2)
    foreach ($f in $hits) { $push += @{ Repo = $repo; File = $f } }
  }
  @{ Ok = $true; Push = $push; Legacy = $legacy }
}
# an owner question (D.15): the typed answer, one of $Words, or $null (no answer = the negative one)
function Read-MoveAnswer([string]$Text, [string[]]$Words) {
  Write-Host ''
  Write-Host $Text
  $a = Read-SyncLine "($($Words -join ' / ')): "
  if ($null -eq $a) { return $null }
  $a = $a.Trim()
  if ($Words -ccontains $a) { return $a }
  $null
}
function Set-MoveAnswer($S, [string]$Q, $A) { Set-MoveMapVal $S.answers $Q $A }
function Set-MoveAsk($S, [hashtable]$Asked, [string]$Q, $A) { $Asked[$Q] = $true; Set-MoveAnswer $S $Q $(if ($A) { $A } else { 'không' }) }
# CONTRACT §8.3.2 remedies of the B.12.4 tunnel refusals, wherever a plan form prints them: plan and the D.3 re-plan, with or without a
# manifest (move-plan.sh _mvp_finalize), and the 0c plan <id> --check-only (the same discovery)
# B77: `unmapped what=connector path=<unit>` (a unit, not `container:<name>`) gets the `accept not-connector <unit>` remedy once per unit;
# a container path keeps the metrics-port remedy (once)
function Write-MoveConnectorUnitRemedies($Lines) {
  foreach ($l in @($Lines)) { if ("$l" -cmatch '\AINV refuse unmapped what=connector path=(?!container:)(\S+)\z') { Write-Host (Get-MoveText 'connector-unit-remedy' @{ unit = $Matches[1] }) } }
}
function Write-MoveTunnelRemedies($Lines) {
  if (@($Lines | Where-Object { "$_" -cmatch '\AINV refuse own-ip path=ingress:\S+\z' }).Count) { Write-Host (Get-MoveText 'ingress-remedy') }   # B.12.4 (W1-T3-GAP-17)
  Write-MoveConnectorUnitRemedies $Lines
  if (@($Lines | Where-Object { "$_" -cmatch '\AINV refuse unmapped what=connector path=container:\S+\z' }).Count) { Write-Host (Get-MoveText 'connector-remedy') }   # B.12.4 (W1-T3-GAP-18)
}
# D.2 steps 3-5 (and the D.3 re-plan): plan on old with the map, the laptop checks, the questions, plan again until INV ok or a refusal the
# owner left. @{ Code; Mf; Map }
# DESIGN-GAP (T10-G22): CONTRACT §2.1 does not fix the k=v keys the questions are filled from; reading: pm2-unsaved (the rest of the
# line), cert-expiring name|path and days, hostname-direct host and class, public-port unit/proto/port, inbound user, sshd-config key.
function Invoke-MovePlanLoop($S, [string[]]$Map) {
  $map = @($Map); $asked = @{}   # each question once per plan run; a re-plan asks again (D.3)
  for ($round = 1; $round -le 6; $round++) {
    $p = Invoke-MovePlanOld $S $map
    if (-not $p.Known) { [void](Write-MoveNoAnswer ([string]$S.old.alias) 'khi lập manifest' $p.Transport); return @{ Code = 1 } }
    $mErr = @($p.Lines | Where-Object { $_ -cmatch '\AMOVE error ' })
    if (-not $p.Mf) {
      Write-MoveLines $p.Lines
      if ($p.Code -eq 65 -or $mErr.Count -or @($p.Lines | Where-Object { $_ -cmatch '\AINV refuse ' }).Count) {
        if (@($mErr | Where-Object { $_ -cmatch '\AMOVE error acl-mapped-id ' }).Count) { Write-Host (Get-MoveText 'acl-remedy') }
        if (@($p.Lines | Where-Object { $_ -cmatch '\AINV refuse map-invalid ref=rewrites\z' }).Count) { Write-Host (Get-MoveText 'rewrites-remedy') }   # B.12.5, E-P11 (ruling 04/11 #3)
        Write-MoveTunnelRemedies $p.Lines
        return @{ Code = 65 }
      }
      Write-Host 'lỗi: máy cũ không trả manifest (thiếu dòng MOVE manifest hoặc sha không khớp).'; return @{ Code = 1 }
    }
    Set-MoveProp $S 'manifest_sha' $p.Mf.Sha; $script:MoveManifest = @{ Text = $p.Mf.Text; Obj = $p.Mf.Obj }
    $M = $p.Mf.Obj
    $scan = Get-MovePushScan $S
    if (-not $scan.Ok) { return @{ Code = 1 } }
    Set-MoveProp $S 'legacy_push' @($scan.Legacy)   # D.0.9 state legacy_push[] from the push scan (W1-T3-GAP-11)
    $lines = @($p.Lines) + @(Get-MoveUserRefusals $S $M) + @(Get-MovePlatformRefusals $S $M) + @(Get-MoveGhRefusals $S)
    foreach ($x in @($scan.Push)) { if (@($S.sshpush_disabled) -cnotcontains "$($x.Repo):$($x.File)") { $lines += "INV refuse push-deploy repo=$($x.Repo) workflow=$($x.File)" } }
    $tr = @($p.Lines | Where-Object { $_ -cmatch '\AINV warn transient-excluded unit=(\S+)' } | ForEach-Object { if ($_ -cmatch 'unit=(\S+)') { $Matches[1] } })
    Set-MoveAnswer $S 'transient-excluded' @($tr)
    $refs = @($lines | Where-Object { $_ -cmatch '\AINV refuse ' })
    Write-MoveLines (@($p.Lines | Where-Object { $_ -cnotmatch '\AINV refuse ' }) + $refs)
    if (@($refs | Where-Object { $_ -cmatch '\AINV refuse uid-collision ' }).Count) { foreach ($x in $refs) { if ($x -cmatch '\AINV refuse uid-collision .*\bholder=(\S+)') { Write-Host ('  ' + (Get-MoveText 'uid-remedy' @{ h = $Matches[1] })) } } }
    Write-MoveTunnelRemedies $refs
    $x = Test-MoveReach $S $M $p.Lines; if ($x) { return @{ Code = $x } }
    # D.2 step 5: the questions, in this order; each answer writes a map line or runs its p.* call, then plan runs again
    $again = $false
    $kv = { param($l) ConvertFrom-MoveKv $l }
    $pm = @($refs | Where-Object { $_ -cmatch '\AINV refuse pm2-unsaved\b' })
    if ($pm.Count -and -not $asked['Q-pm2save']) {
      $a = Read-MoveAnswer (Get-MoveText 'Q-pm2save' @{ 'tên' = (($pm[0] -replace '\AINV refuse pm2-unsaved ?', '')) }) @('có', 'không')
      Set-MoveAsk $S $asked 'Q-pm2save' $a
      if ($a -ceq 'có') { $c = Invoke-MoveCall $S 'old' 'p.pm2-save.N'; if ($c.Code -ne 0) { return @{ Code = ConvertTo-MoveExit $c.Code } }; $again = $true }
    }
    foreach ($l in @($lines | Where-Object { $_ -cmatch '\AINV warn cert-expiring\b' })) {
      $k = & $kv $l; $nm = [string]$(if ($k['name']) { $k['name'] } else { $k['path'] })
      if ($asked["Q-cert:$nm"]) { continue }
      $a = Read-MoveAnswer (Get-MoveText 'Q-cert' @{ 'tên' = $nm; n = [string]$k['days'] }) @('có', 'không')
      Set-MoveAsk $S $asked "Q-cert:$nm" $a
      if ($a -ceq 'có') { $c = Invoke-MoveCall $S 'old' 'p.cert-renew.N'; if ($c.Code -ne 0) { return @{ Code = ConvertTo-MoveExit $c.Code } }; $again = $true }
    }
    foreach ($l in @($refs | Where-Object { $_ -cmatch '\AINV refuse hostname-direct\b' })) {
      $k = & $kv $l; $nm = [string]$k['host']
      if (-not $nm -or $asked["Q-direct:$nm"]) { continue }
      $a = Read-MoveAnswer (Get-MoveText 'Q-direct' @{ 'tên' = $nm; 'lớp' = [string]$k['class'] }) @('có', 'không')
      Set-MoveAsk $S $asked "Q-direct:$nm" $a
      if ($a -ceq 'có') { $map += "accept direct $nm"; $again = $true }
    }
    # B.12.4 (W1-T3-GAP-17): an `own-ip path=ingress:<hostname>` hit has no file to rewrite (and `rewrite own-ip` takes an absolute path only, B.14.2): it gets no Q-ownip entry and no
    # map line; Write-MoveTunnelRemedies above printed its remedy and the plan ends 65. The kind is matched exactly (own-ip-nat and own-ip-family are other refusals with their own label)
    $own = @($refs | Where-Object { $_ -cmatch '\AINV refuse own-ip(\s|\z)' } | ForEach-Object { [string](& $kv $_)['path'] } | Where-Object { $_ -cmatch '\A/' })
    if ($own.Count -and -not $asked['Q-ownip']) {
      $a = Read-MoveAnswer (Get-MoveText 'Q-ownip' @{ 'danh sách' = ($own -join ', ') }) @('có', 'không')
      Set-MoveAsk $S $asked 'Q-ownip' $a
      if ($a -ceq 'có') {
        # B.12.5 / D.15 (ruling 04/11 (2) C, Q-ownip-compose): a family (':' = IPv6, as the server) with more than one address in dial.old
        # or dial.new takes the owner's `<from>=<to>` pairs, so the re-plan never refuses its own output (map-invalid ref=rewrites); the
        # bare line only for exactly one address per family. A typed line not of the map's `<from>=<to>` form (B.14.2) is not written.
        $dial = Get-MoveProp $M 'dial'; $do = @(Get-MoveProp $dial 'old' @()); $dn = @(Get-MoveProp $dial 'new' @())
        if (@(foreach ($v6 in $false, $true) { foreach ($l in @(, $do) + @(, $dn)) { if (@($l | Where-Object { "$_".Contains(':') -eq $v6 }).Count -gt 1) { 1 } } }).Count) {
          Write-Host ''; Write-Host (Get-MoveText 'Q-ownip-pairs' @{ 'địa chỉ cũ' = ($do -join ', '); 'địa chỉ mới' = ($dn -join ', ') })
          $pairs = @(); while ($true) { $t = Read-SyncLine ''; if ($null -eq $t -or -not $t.Trim()) { break }; if ($t.Trim() -cmatch '\A[A-Za-z0-9._:-]{1,255}=[A-Za-z0-9._:-]{1,255}\z') { $pairs += $t.Trim() } }
          foreach ($x in $own) { foreach ($q in $pairs) { $map += "rewrite own-ip $x $q"; $again = $true } }
        } else { foreach ($x in $own) { $map += "rewrite own-ip $x" }; $again = $true }
      }
    }
    $ports = @($refs | Where-Object { $_ -cmatch '\AINV refuse public-port\b' } | ForEach-Object { $k = & $kv $_; if ($k['unit'] -and $k['proto'] -and $k['port']) { "$($k['unit'])/$($k['proto'])/$($k['port'])" } })
    if ($ports.Count -and -not $asked['Q-port']) {
      $a = Read-MoveAnswer (Get-MoveText 'Q-port' @{ 'danh sách' = ($ports -join ', ') }) @('có', 'không')
      Set-MoveAsk $S $asked 'Q-port' $a
      if ($a -ceq 'có') { foreach ($x in $ports) { $map += "accept public-port $x" }; $again = $true }
    }
    $inb = @(@($refs | Where-Object { $_ -cmatch '\AINV refuse inbound\b' }) + @($p.Lines | Where-Object { $_ -cmatch '\AINV inbound ' }) | ForEach-Object { [string](& $kv $_)['user'] } | Where-Object { $_ } | Select-Object -Unique)
    if (@($refs | Where-Object { $_ -cmatch '\AINV refuse inbound\b' }).Count -and -not $asked['Q-inbound']) {
      $det = @($p.Lines | Where-Object { $_ -cmatch '\AINV inbound ' } | ForEach-Object { ($_ -replace '\AINV inbound ', '') })
      $a = Read-MoveAnswer (Get-MoveText 'Q-inbound' @{ 'danh sách' = $(if ($det.Count) { $det -join '; ' } else { $inb -join ', ' }) }) @('có', 'không')
      Set-MoveAsk $S $asked 'Q-inbound' $a
      if ($a -ceq 'có') { foreach ($u in $inb) { $map += "accept inbound $u" }; $again = $true }
    }
    $sk = @($refs | Where-Object { $_ -cmatch '\AINV refuse sshd-config\b' } | ForEach-Object { [string](& $kv $_)['key'] })
    if ($sk.Count -and -not $asked['Q-sshd']) {
      $a = Read-MoveAnswer (Get-MoveText 'Q-sshd' @{ 'khóa' = ($sk -join ', ') }) @('có', 'không')
      Set-MoveAsk $S $asked 'Q-sshd' $a
      if ($a -ceq 'có') { $map += 'accept sshd'; $again = $true }
    }
    foreach ($x in @($scan.Push)) {
      $key = "$($x.Repo):$($x.File)"
      if (@($S.sshpush_disabled) -ccontains $key -or $asked["Q-sshpush:$key"]) { continue }
      $a = Read-MoveAnswer (Get-MoveText 'Q-sshpush' @{ repo = "$($x.Repo) ($($x.File))" }) @('có', 'không')
      Set-MoveAsk $S $asked "Q-sshpush:$key" $a
      if ($a -ceq 'có') {
        $g = Invoke-MoveTool 'gh' @('workflow', 'disable', $x.File, '-R', $x.Repo)
        if ($g.Code -ne 0 -and ($g.Out -join ' ') -notmatch 'already disabled') { Write-Host "lỗi: gh workflow disable $($x.File) -R $($x.Repo) (mã $($g.Code))."; return @{ Code = 1 } }
        Set-MoveProp $S 'sshpush_disabled' (@($S.sshpush_disabled) + $key); Save-MoveState $S; $again = $true
      }
    }
    if ($again) { Write-Host 'plan: chạy lại với các câu trả lời...'; continue }
    if ($refs.Count -or $p.Code -ne 0) { return @{ Code = 65; Map = $map; Mf = $p.Mf } }
    return @{ Code = 0; Map = $map; Mf = $p.Mf; Lines = $p.Lines }
  }
  Write-Host 'lỗi: plan vẫn chưa xong sau nhiều lượt trả lời.'
  @{ Code = 1 }
}
# `MOVE facts` of a machine: @{ Os; Arch; Systemd; Skew; Legacy = @(@{ Project; Slug }) } or $null
function Get-MoveFacts($Mach, [switch]$Pin) {
  $t0 = Get-MoveNow
  $r = Invoke-MoveScript $Mach (Get-MoveFactsScript) @() (Get-MoveConst 'tcp_s') -Pin:$Pin -Quiet
  $script:MoveFactsCode = $r.Code
  $t1 = Get-MoveNow
  $lg = @(foreach ($l in $r.Lines) { if ("$l" -cmatch '\AMOVE legacy project=(deal-sync|vps-scraper) origin=(\S+)\z') { @{ Project = $Matches[1]; Slug = (ConvertTo-MoveSlug $Matches[2]) } } })
  foreach ($l in $r.Lines) {
    if ("$l" -cmatch '\AMOVE facts ') {
      $k = ConvertFrom-MoveKv $l
      if ("$($k['epoch'])" -notmatch '\A[0-9]+\z') { return $null }
      $mid = $t0.AddTicks([long](($t1 - $t0).Ticks / 2))
      $off = [double]$k['epoch'] - ($mid - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalSeconds   # signed, corrected to the sample's midpoint
      return @{ Os = [string]$k['os']; Arch = [string]$k['arch']; Systemd = [string]$k['systemd']; Off = $off; Skew = [Math]::Abs($off); Slack = ($t1 - $t0).TotalSeconds / 2; Legacy = $lg }
    }
  }
  if (($r.Code -in 124, 255, -1) -and -not $script:MoveFactsDown) { $script:MoveFactsDown = @{ Alias = [string]$Mach.Alias; Code = $r.Code } }   # DG6: no answer (no `MOVE facts`, ssh lost): the callers say "không trả lời", never `refuse clock`
  $null
}
# `<owner>/<repo>` of a git remote url (ssh `git@host:o/r.git`, `https://host/o/r`): its last two path parts, `.git` and a trailing `/`
# dropped; '' when none
function ConvertTo-MoveSlug([string]$Url) { if ($Url -cmatch '[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?\z') { $Matches[1] } else { '' } }
# B.0.2 (D.2, 0c): new's skew against src and against the laptop, each ≤ 5 s (F6). Refusal lines.
# DESIGN-GAP (T10-G37, F6): B.0.2 does not state a rule for src against the laptop; reading: old more than 5 s off the laptop refuses too
# (it guards the laptop-side T0 that verify's --since carries).
function Get-MoveClockRefusals($Facts) {
  $out = @(); $lim = Get-MoveConst 'clock_s'; $o = $Facts['old']; $n = $Facts['new']
  if ($o -and $n -and [Math]::Abs($n.Off - $o.Off) - $o.Slack - $n.Slack -gt $lim) { $out += "INV refuse clock side=new-old skew_s=$([int][Math]::Abs($n.Off - $o.Off))" }
  foreach ($k in 'new', 'old') {
    $f = $Facts[$k]
    if (-not $f) { $out += "INV refuse clock side=$k skew_s=-"; continue }   # R2-5: no readable `MOVE facts` epoch is no pass
    if ($f.Skew - $f.Slack -gt $lim) { $out += "INV refuse clock side=$k skew_s=$([int]$f.Skew)" }
  }
  $out
}
function Invoke-MovePlanCmd([string]$NewAlias, [string]$Addr, [string]$OldAddrArg, [string]$MapFile) {
  $S0 = Read-MoveState
  if ($S0 -and [string]$S0.phase -cnotin 'finished', 'aborted') { Write-MoveLines @("INV refuse other-move phase=$($S0.phase)"); return 65 }
  if (-not (Test-MoveAlias $NewAlias)) { Write-Host 'Cách dùng: fcode move plan <máy mới> --addr <ipv4|tên> [--old-addr <host[:port]>] [--map <file>]'; return 65 }
  if (-not (Test-MoveAddr $Addr)) { Write-MoveLines @('INV refuse target-addr addr=-'); return 65 }
  if ($OldAddrArg -and -not (Test-MoveHostPort $OldAddrArg)) { Write-Host 'lỗi: --old-addr phải là host hoặc host:port.'; return 65 }
  $oldAlias = Get-DeployHost
  if (-not $oldAlias -or $oldAlias -ceq $NewAlias) { Write-Host 'lỗi: tên ssh của máy cũ (deployHost) không dùng được hoặc trùng máy mới.'; return 65 }
  $puo = Get-MovePlatformUser $oldAlias; $pun = Get-MovePlatformUser $NewAlias
  if ($null -eq $puo -or $null -eq $pun) { return 65 }
  $oi = Get-MoveSshInfo $oldAlias
  if (-not $oi -or -not (Test-MoveAddr $oi.HostName)) { Write-Host "lỗi: ssh -G không đọc được địa chỉ (HostName) của '$oldAlias'."; return 1 }
  $map = @(Get-MoveDefaultMap)
  if ($MapFile) { $ml = Read-MoveMapLines $MapFile; if ($null -eq $ml) { return 65 }; $map += @($ml) }
  $via = if ($OldAddrArg) { $OldAddrArg } elseif ($oi.Port -ne 22) { "$($oi.HostName):$($oi.Port)" } else { $oi.HostName }
  $S = New-MoveState (New-MoveIdText) ([pscustomobject][ordered]@{ alias = $oldAlias; addr = $oi.HostName; hostkey_line = ''; via = $via; platform_user = $puo }) ([pscustomobject][ordered]@{ alias = $NewAlias; addr = $Addr; hostkey_line = ''; platform_user = $pun })
  $script:MoveDraft = $true; $script:MoveManifest = $null
  try {
    $old = Get-MoveMachine $S 'old'; $new = Get-MoveMachine $S 'new'
    $script:MoveFactsDown = $null
    $fo = Get-MoveFacts $old -Pin:(Test-MoveFirstContact $S.old.addr)
    $okey = Get-MovePinnedKey $S.old.addr
    if (-not $fo) { if ($script:MoveFactsDown) { return (Write-MoveNoAnswer $oldAlias 'khi đọc dữ kiện' $script:MoveFactsDown.Code) }; Write-Host "lỗi: không đọc được dữ kiện máy cũ '$oldAlias' (mã $script:MoveFactsCode)."; return 1 }
    if (-not $okey) { Write-Host "lỗi: máy cũ '$oldAlias' không có khoá máy ed25519 hoặc không đọc được khoá."; return 1 }
    $S.old.hostkey_line = $okey
    # D.2 step 2: preflight on new; the first contact pins new's key (B.11.3: a new plan replaces the pin stored for --addr)
    Remove-MovePin $Addr
    Write-Host "plan: kiểm tra máy mới '$NewAlias' ($Addr)..."
    $pf = Invoke-MoveScript $new (Get-MovePreflightScript) @('--old-addr', $via, '--addr', $Addr, '--src-os', $fo.Os, '--src-arch', $fo.Arch, '--src-systemd', $fo.Systemd) -Pin
    if ($pf.Code -in 124, 255, -1) { Write-MoveLines @("INV refuse target-addr addr=$Addr"); return 65 }
    if (@($pf.Lines | Where-Object { $_ -cmatch '\AINV refuse target-rsync-argv ' }).Count) { Write-Host ('  ' + (Get-MoveText 'rsync-remedy')) }
    if (@($pf.Lines | Where-Object { $_ -cmatch '\AINV refuse target-not-empty path=/var/lib/fcode-move/move-id' }).Count) { Write-Host ('  ' + (Get-MoveText 'reinstall-new')) }
    if ($pf.Code -ne 0) { return 65 }
    $nkey = Get-MovePinnedKey $Addr
    if (-not $nkey) { Write-MoveLines @("INV refuse target-addr why=no-ed25519"); return 65 }
    $S.new.hostkey_line = $nkey
    Write-Host "Khoá máy mới (ed25519): $(Get-MoveFingerprint $nkey) — có thể so với trang quản lý của nhà cung cấp."
    # D.0.9: target_users[], target_groups[], target_subids[], target_addrs[], target_stop_budget_s and target_platform, once per move
    $tu = @(); $tg = @(); $ts = @(); $ta = @(); $sb = 0; $tp = 0
    foreach ($l in $pf.Lines) {
      # DESIGN-GAP (T10-G39, F8c): D.0.9 gives target_users[] as {name, uid}; the entries also keep preflight's home_nonskel for step 3b
      if ("$l" -cmatch '\AINV target user=(\S+) uid=([0-9]+) home-nonskel=([01])\z') { $tu += [pscustomobject][ordered]@{ name = $Matches[1]; uid = [int]$Matches[2]; home_nonskel = [int]$Matches[3] } }
      elseif ("$l" -cmatch '\AINV target group=(\S+) gid=([0-9]+)\z') { $tg += [pscustomobject][ordered]@{ name = $Matches[1]; gid = [int]$Matches[2] } }
      elseif ("$l" -cmatch '\AINV target subid user=(\S+) kind=(uid|gid) start=([0-9]+) count=([0-9]+)\z') { $ts += [pscustomobject][ordered]@{ user = $Matches[1]; kind = $Matches[2]; start = [long]$Matches[3]; count = [long]$Matches[4] } }
      elseif ("$l" -cmatch '\AINV target addr=(\S+)\z') { $ta += $Matches[1] }
      elseif ("$l" -cmatch '\AINV target platform=([01])\z') { $tp = [int]$Matches[1] }
      elseif ("$l" -cmatch '\AINV target stop_budget_s=([0-9]+)\z') { $sb = [int]$Matches[1] }
    }
    foreach ($kv in @{ target_users = @($tu); target_groups = @($tg); target_subids = @($ts); target_addrs = @($ta); target_stop_budget_s = $sb; target_platform = $tp }.GetEnumerator()) { Set-MoveProp $S $kv.Key $kv.Value }
    $script:MoveFactsDown = $null
    $fn = Get-MoveFacts $new
    if ($script:MoveFactsDown) { return (Write-MoveNoAnswer $script:MoveFactsDown.Alias 'khi đọc dữ kiện' $script:MoveFactsDown.Code) }   # DG6: a drop is no clock refusal
    $clk = @(Get-MoveClockRefusals @{ old = $fo; new = $fn })
    if ($clk.Count) { Write-MoveLines $clk; return 65 }
    # D.2 steps 3-5
    Write-Host "plan: máy cũ '$oldAlias' lập manifest..."
    $pl = Invoke-MovePlanLoop $S $map
    if ($pl.Code -ne 0) { return $pl.Code }
    # D.2 step 6
    foreach ($lp in @(Get-MoveProp $S 'legacy_push' @())) { Set-MoveMapVal $S.legacy_known_hosts ([string]$lp.repo) "$($S.old.addr) $okey" }
    Set-MoveProp $S 'manifest_sha' $pl.Mf.Sha
    $script:MoveDraft = $false
    Save-MoveManifest $pl.Mf.Text
    Write-PhienText (Get-MovePath 'map.txt') ((@($pl.Map) -join "`n") + "`n")
    Save-MoveState $S
    Write-MoveLines @('INV ok')
    Write-Host "Kế hoạch xong ($($S.move_id)). Việc tiếp theo:  fcode move copy"
    0
  } finally { $script:MoveDraft = $false }
}

# ---- copy (D.3) ----
# D.3 step 1 / D.11: wait for a running call of this attempt on either machine, within its deadline; used by copy-first, copy-refresh and the resume
# rows (cut-resume, rb-continue, carry-resume). It polls only a machine the agreement check stored an Ok status for (a new it marked down has none, F2)
# and refreshes $script:MoveSeen with every Ok poll. A poll that is not Ok is never read as "not running" and never stored: a transport failure is
# retried `retries` times, then it ends the run as a no-answer (1, nothing written); an answer that is not GATE_EXIT 0 with a state line ends the run
# as the agreement check does. -ExceptStep <step>: a running call of that step (this attempt) is not waited for (cut-resume: new's x.final is attached).
function Wait-MoveRunning($S, [string]$ExceptStep = '', [string[]]$Machines = @('old', 'new')) {
  $pre = "$($S.dir)-$($S.attempt)-"
  $busy = { param($s) [string]$s.Kv['call_state'] -ceq 'running' -and ([string]$s.Kv['call']).StartsWith($pre) -and -not ($ExceptStep -and [string]$s.Kv['call'] -ceq "$pre$ExceptStep") }
  foreach ($m in $Machines) {
    if (-not $script:MoveSeen.ContainsKey($m)) { continue }
    $st = $script:MoveSeen[$m]
    $t0 = Get-MoveNow
    while ($st.Ok -and (& $busy $st)) {
      if (((Get-MoveNow) - $t0).TotalSeconds -gt (Get-MoveConst 'first_transfer_s') + 60) { Write-Host "máy '$((Get-MoveMachine $S $m).Alias)' vẫn đang chạy $($st.Kv['call']); chạy lại sau."; return 75 }
      Write-Host "đợi $($st.Kv['call']) trên '$((Get-MoveMachine $S $m).Alias)' chạy xong..."
      Wait-Move 10
      for ($i = 1; ; $i++) {
        $p = Get-MoveStatus $S $m -Quiet
        if ($p.Ok) { break }
        if ($p.Known) { return (Write-MoveStatusFail $S $m $p) }
        if ($i -ge (Get-MoveConst 'retries')) { return (Write-MoveNoAnswer ([string](Get-MoveMachine $S $m).Alias) 'khi đợi lệnh đang chạy' $p.Transport) }
        Wait-Move 5
      }
      $script:MoveSeen[$m] = $p; $st = $p
    }
  }
  0
}
# D.5.2 / D.5.3 (W1-T10-G12): with new_lost or new_discarded, every later contact with new first runs `r.stop-dst` (stop) there, once per
# verb (a replay of its rc 0 inside the attempt is enough), sent by the agreement check after new answered status and after new's own
# agreement step, only while new holds this move's open move-id (R2-1); a new that does not answer is skipped (F2). The flags clear at a
# later c.init-new rc 0 (W1-T10-O1, Invoke-MoveInit). DESIGN-GAP (G12 dir=back, still with the Architect, OMP-HANDOFF §13 rev 1k3.7): in
# dir=back new is the src while CONTRACT §1.3 names r.stop-dst for dst; the step stays r.stop-dst.
function Invoke-MoveNewFence($S) {
  if (-not ($S.new_lost -eq $true -or $S.new_discarded -eq $true) -or $script:MoveFenced) { return 0 }
  $r = Invoke-MoveCall $S 'new' 'r.stop-dst'
  if ($r.Code -ne 0) { return (ConvertTo-MoveExit $r.Code) }
  $script:MoveFenced = $true; 0
}
# verify on both machines (K4): @{ Code; Diff = @(items that differ); Id = @{ old; new } }. -Final: x.verify (cutover step 7), else c.verify.N
# DESIGN-GAP (T10-G26): the format of `--since` is not fixed; reading: UTC `YYYY-MM-DDTHH:MM:SSZ` (the record time format).
function Invoke-MoveVerify($S, [switch]$Final) {
  $t0 = ConvertTo-MoveTime $S.last_copy_at; if (-not $t0) { $t0 = Get-MoveNow }
  $va = @('--seed', "$($S.move_id)-$($S.attempt)", '--since', (Format-MoveTs $t0))
  $d = @{}; $ids = @{}; $pass = 0
  foreach ($m in (Get-MoveSide $S 'src'), (Get-MoveSide $S 'dst')) {
    if ($Final) { $r = Invoke-MoveCall $S $m 'x.verify' $va -Quiet } else { $r = Invoke-MoveCall $S $m 'c.verify.N' $va -Quiet -Pass $pass; $pass = Get-MovePassOf $r.Id }
    if ($r.Code -ne 0) { return @{ Code = $r.Code; Diff = @(); Id = $ids } }
    $ids[$m] = $r.Id; $d[$m] = @{}
    foreach ($l in $r.Lines) { if ("$l" -cmatch '\AMOVE digest item=(\S+) n=([0-9]+) list=([0-9a-f]+) sum=([0-9a-f]+)\z') { $d[$m][$Matches[1]] = "$($Matches[2]) $($Matches[3]) $($Matches[4])" } }
  }
  $diff = @()
  foreach ($k in @(@($d['old'].Keys) + @($d['new'].Keys) | Select-Object -Unique)) { if ($d['old'][$k] -cne $d['new'][$k]) { $diff += $k } }
  foreach ($k in $diff) { Write-Host "MOVE verify item=$k diff=1" }
  @{ Code = 0; Diff = $diff; Id = $ids }
}
# B.11.1: a fresh BatchMode login to dst after adopt; a failure is `lockout` (exit 70)
function Test-MoveLogin($S, [string]$M) {
  $t = Invoke-MoveRemote (Get-MoveMachine $S $M) 'true' '' (Get-MoveConst 'tcp_s')
  if ($t.Code -eq 0) { return 0 }
  # DG6: ssh 255 / a deadline without an authentication refusal is "no answer", never a lockout; 1 = re-run (the line is shown here)
  if (($t.Code -in 124, 255, -1) -and "$($t.Err)" -cnotmatch 'Permission denied|Too many authentication failures') { return (Write-MoveNoAnswer ([string]$(if ($M -ceq 'old') { $S.old.alias } else { $S.new.alias })) 'khi kiểm tra đăng nhập' $t.Code) }
  Write-MoveLines @("MOVE error lockout side=$M"); 70
}
# D.3 steps 6-8 with the pass counter raised: transfer, verify (informational), adopt; then the estimates of step 9
function Invoke-MovePasses($S) {
  $dst = Get-MoveSide $S 'dst'
  Set-MoveProp $S 'last_copy_at' (Format-MoveTs (Get-MoveNow)); Save-MoveState $S   # DESIGN-GAP (T10-G13): T0 of B.8.6 kept in last_copy_at
  $r = Invoke-MoveCall $S 'new' 'c.transfer.N'
  if ($r.Code -ne 0) { if ($r.Code -eq -1 -or @($r.Lines | Where-Object { $_ -cmatch '\AMOVE error rsync-failed why=net' }).Count) { Write-Host (Get-MoveText 'net-drop') }; return (ConvertTo-MoveExit $r.Code) }
  $v = Invoke-MoveVerify $S
  if ($v.Code -ne 0) { return (ConvertTo-MoveExit $v.Code) }
  $r = Invoke-MoveCall $S $dst 'c.adopt.N'
  if ($r.Code -ne 0) { return (ConvertTo-MoveExit $r.Code) }
  $l = Test-MoveLogin $S $dst; if ($l -ne 0) { return $l }
  Update-MoveEst $S
  0
}
# D.6 estimates from the measured durations
function Update-MoveEst($S) {
  $M = Get-MoveManifestObj
  $g = { param($st, $m) $o = Get-MoveProp $S.dur $st; if ($o) { Get-MoveProp $o $m } else { $null } }
  $ts = & $g 'c.transfer.N' 'new'; $vo = & $g 'c.verify.N' 'old'; $vn = & $g 'c.verify.N' 'new'
  $vs = if ($null -ne $vo -or $null -ne $vn) { [Math]::Max([int]$vo, [int]$vn) } else { $null }
  $as = & $g 'c.adopt.N' (Get-MoveSide $S 'dst'); $ps = & $g 'c.prepare.N' (Get-MoveSide $S 'dst')
  $e = $S.est
  Set-MoveProp $e 'transfer_s' $ts; Set-MoveProp $e 'verify_s' $vs; Set-MoveProp $e 'apply_s' $as; if ($null -ne $ps) { Set-MoveProp $e 'prepid_s' $ps }
  $nStop = @(Get-MoveProp (Get-MoveProp $M 'hold_sets') 'stop' @()).Count; $nStart = @(Get-MoveProp (Get-MoveProp $M 'hold_sets') 'start' @()).Count
  # DESIGN-GAP (T10-G40, F8d): the B.14.1 redis[] element shape is open (T4 reads unit ids); reading: {rdb_mb}, so the sum is 0 without it
  $rdb = 0; foreach ($x in @(Get-MoveProp $M 'redis' @())) { $rdb += [double](Get-MoveProp $x 'rdb_mb' 0) }
  $T = [int]$ts; $V = [int]$vs; $A = [int]$as; $P = [int](Get-MoveProp $e 'prepid_s' 0)
  Set-MoveProp $e 'typical_s' ([int][Math]::Ceiling(40 + $T + $V + $A + $P + 5 * $nStop + 5 * $nStart + $rdb / 100))
  Set-MoveProp $e 'max_s' ([int](40 + 2 * $T + 2 * $V + $A + $P + (Get-MoveSetBudget $M 'stop' 'stop_budget_s') + (Get-MoveSetBudget $M 'start' 'start_budget_s')))
  Save-MoveState $S
}
# gate ids of both machines (I9): @{ Ok; Old; New; NewId }
function Get-MoveGateIds($S) {
  $o = Get-MoveStatus $S 'old' -Quiet; $n = Get-MoveStatus $S 'new' -Quiet
  @{ Ok = ($o.Known -and $n.Known); Old = [string]$o.Kv['gate']; New = [string]$n.Kv['gate']; NewMove = [string]$n.Kv['move_id']; StOld = $o; StNew = $n }
}
# D.3 steps 2-9 (the first copy of an attempt). Ruling 04/11 #9 (NEW-2, option (a)): a re-run never re-sends c.init-* to a machine whose
# status (the verb's agreement check, Test-MoveInitSeen) already shows this move-id at the state's (dir, attempt); when one was skipped,
# the copy goes on as the D.3 re-run: plan <id> -> c.repin.N on both -> c.prepare.N -> steps 6-8 (Invoke-MoveCopyRefresh).
# Ruling 04/11 (2) A (T10d-NEW2-halfdone; DESIGN D.0.5 / D.3 rev 1k3.8, E-P31, E-P33): "shows this move-id" means a FINISHED init. The
# server writes the move-id before the rest of init (lib/move-run.sh _mvr_init), so the machine's last call must not be this attempt's
# c.init-<machine> with a call_state other than done; a half-done init re-sends the same id (init is idempotent on src and dst).
# Remaining edge: on new, a fence r.stop-dst sent by the agreement check (new_lost / new_discarded) after a half-done c.init-new becomes
# new's last call, and the init then counts as done (these flags are not set in phase planned on a normal first copy).
function Test-MoveInitSeen($S, [string]$M) {
  $st = $script:MoveSeen[$M]
  [bool]($st -and $st.Ok -and [string]$st.Kv['move_id'] -ceq [string]$S.move_id -and [string]$st.Kv['dir'] -ceq [string]$S.dir -and [string]$st.Kv['attempt'] -ceq "$($S.attempt)" -and -not ([string]$st.Kv['call'] -ceq "$($S.dir)-$($S.attempt)-c.init-$M" -and [string]$st.Kv['call_state'] -cne 'done'))
}
function Invoke-MoveCopyFull($S) {
  $new = Get-MoveMachine $S 'new'; $rerun = $false
  Write-Host "copy (2): công cụ và khoá chuyển máy trên '$($new.Alias)'..."
  $script:MovePub = $null
  if (-not (Get-MovePub $S)) { return 1 }
  if (Test-MoveInitSeen $S 'old') { $rerun = $true }
  else { Write-Host 'copy (3): init trên máy cũ...'; $c = Invoke-MoveInit $S 'old'; if ($c -ne 0) { return $c } }
  Write-Host "copy (4): chép cổng deploy sang '$($new.Alias)'..."
  for ($i = 1; $i -le 2; $i++) {
    $g = Invoke-MoveScript $new (Get-MoveBootstrapGateScript) @('--old-addr', (Get-MoveOldAddrForNew $S))
    if ($g.Code -ne 0) { return (ConvertTo-MoveExit $g.Code) }
    $ids = Get-MoveGateIds $S
    if (-not $ids.Ok) { return (Write-MoveIdsNoAnswer $S $ids) }
    if ($ids.Old -and $ids.Old -ceq $ids.New) { break }
    $fresh = $ids.NewMove -in '', '-', [string]$S.move_id
    if ($i -eq 2 -or -not $fresh) { Write-MoveLines @('INV refuse gate-version side=new'); return 65 }   # E-G1: refresh once
  }
  Set-MoveProp $S 'gate_id' $ids.Old; Save-MoveState $S
  Write-Host "copy (5): init và prepare trên '$($new.Alias)'..."
  if (Test-MoveInitSeen $S 'new') { $rerun = $true } else { $c = Invoke-MoveInit $S 'new'; if ($c -ne 0) { return $c } }
  if ($rerun) { return (Invoke-MoveCopyRefresh $S) }
  $c = Invoke-MovePrepare $S; if ($c -ne 0) { return $c }
  Write-Host 'copy (6-8): chép, kiểm tra, áp dụng...'
  $p = Invoke-MovePasses $S; if ($p -ne 0) { return $p }
  Set-MoveAnswer $S 'refresh-pending' $false; Set-MoveProp $S 'phase' 'copied'; Save-MoveState $S
  Write-Host "Copy xong (copied). Ước tính dừng: khoảng $($S.est.typical_s) giây, tối đa $($S.est.max_s) giây. Khi sẵn sàng:  fcode move cutover"
  0
}
# c.prepare.N on new; B.6.2 (W1-T4b-MVX-GAP-2, GAP-RULINGS-3 §16.5 S-5): its `MOVE item idmap:<user|group>:<name> kind=prepare
# state=mapped src_id=<n> dst_id=<n>` lines go into state idmap[]; an entry the state lacks runs the D.3 re-plan (plan <id>, c.repin.N on
# both machines) before c.transfer.N, so every pass reads one pinned idmap[]. Trigger: an entry this c.prepare.N printed that the pinned
# idmap[] lacks (prepare prints every mapped id at every call), so a re-plan that ended before Invoke-MoveRepin kept the new manifest is
# redone by the next copy, and an entry nobody prints any more (e.g. a user excluded later) never re-plans (review r2 R2-1). A failure
# after Invoke-MoveRepin saved the new sha is redone by the next copy as the re-run of Invoke-MoveCopyFull (ruling 04/11 #9, NEW-2).
# Note (Architect, predates this round): the four-field merge keeps two entries for one kind+name when dst_id changes (fails closed at plan).
function Invoke-MovePrepare($S) {
  $r = Invoke-MoveCall $S 'new' 'c.prepare.N'; if ($r.Code -ne 0) { return (ConvertTo-MoveExit $r.Code) }
  $im = @(Get-MoveProp $S 'idmap' @() | Where-Object { $_ }); $got = @()
  $same = { param($a, $b) [string]$a.kind -ceq [string]$b.kind -and [string]$a.name -ceq [string]$b.name -and [int]$a.src_id -eq [int]$b.src_id -and [int]$a.dst_id -eq [int]$b.dst_id }
  foreach ($l in $r.Lines) {
    if ("$l" -cnotmatch '\AMOVE item idmap:(user|group):(\S+) kind=prepare state=mapped src_id=([0-9]+) dst_id=([0-9]+)\z') { continue }
    $e = [pscustomobject][ordered]@{ kind = $Matches[1]; name = $Matches[2]; src_id = [int]$Matches[3]; dst_id = [int]$Matches[4] }
    $got += $e; if (@($im | Where-Object { & $same $_ $e }).Count) { continue }
    $im += $e
  }
  Set-MoveProp $S 'idmap' @($im); Save-MoveState $S   # saved before the re-plan: its stdin carries them
  $pin = @(Get-MoveProp (Get-MoveManifestObj) 'idmap' @() | Where-Object { $_ })
  if (-not @($got | Where-Object { $x = $_; -not @($pin | Where-Object { & $same $_ $x }).Count }).Count) { return 0 }
  Write-Host 'copy: máy mới đổi số của user/group hệ thống; lập lại kế hoạch trên máy cũ...'
  $pl = Invoke-MovePlanLoop $S @(Get-MoveMapText)
  if ($pl.Code -ne 0) { return $pl.Code }
  Invoke-MoveRepin $S $pl
}
# the re-plan's new manifest kept, then c.repin.N on old and on new (one N for both, W1-T10-G19)
function Invoke-MoveRepin($S, $Pl) {
  Set-MoveAnswer $S 'refresh-pending' $true
  Set-MoveProp $S 'manifest_sha' $Pl.Mf.Sha; Save-MoveManifest $Pl.Mf.Text; $script:MoveManifest = @{ Text = $Pl.Mf.Text; Obj = $Pl.Mf.Obj }
  Write-PhienText (Get-MovePath 'map.txt') ((@($Pl.Map) -join "`n") + "`n"); Save-MoveState $S
  $j = '{"manifest":' + $Pl.Mf.Text.Trim() + '}'
  $r = Invoke-MoveCall $S 'old' 'c.repin.N' @() $j; if ($r.Code -ne 0) { return (ConvertTo-MoveExit $r.Code) }
  $r = Invoke-MoveCall $S 'new' 'c.repin.N' @() $j -Pass (Get-MovePassOf $r.Id); if ($r.Code -ne 0) { return (ConvertTo-MoveExit $r.Code) }
  0
}
# D.3 re-run: a full re-plan, then c.repin.N on old and on new, c.prepare.N, steps 6-8
# DESIGN-GAP (T10-G50, F13): DESIGN is silent on a refresh that re-pins and then fails before c.prepare.N / the passes end (new not
# prepared for the new manifest). Reading: answers{'refresh-pending'} is true from the new sha until the passes end; a cutover refuses
# while it is set, with "chạy fcode move copy lại" (Test-MoveRefreshPending).
function Test-MoveRefreshPending($S) { (Get-MoveMapVal $S.answers 'refresh-pending' $false) -eq $true }
function Invoke-MoveCopyRefresh($S) {
  Write-Host 'copy: lập lại kế hoạch trên máy cũ (lần chép lại)...'
  $pl = Invoke-MovePlanLoop $S @(Get-MoveMapText)
  if ($pl.Code -ne 0) { return $pl.Code }
  $c = Invoke-MoveRepin $S $pl; if ($c -ne 0) { return $c }
  $c = Invoke-MovePrepare $S; if ($c -ne 0) { return $c }
  $p = Invoke-MovePasses $S; if ($p -ne 0) { return $p }
  Set-MoveAnswer $S 'refresh-pending' $false; Set-MoveProp $S 'phase' 'copied'; Save-MoveState $S
  Write-Host "Copy làm mới xong. Ước tính dừng: khoảng $($S.est.typical_s) giây, tối đa $($S.est.max_s) giây."
  0
}

# ---- cutover (D.4), rollback and carry-back (D.5), back (D.8): one code for both dirs ----
# DESIGN-GAP (T10-G20): the excluded transient units (B.5.5) named in Q-cut, Q-abort and every return-to-old text have no state field;
# reading: answers{'transient-excluded'}, from the `INV warn transient-excluded` lines of the last `plan <id>` / `x.check`.
function Get-MoveTransient($S) { @(@(Get-MoveMapVal $S.answers 'transient-excluded' @()) | Where-Object { $_ }) }
function Write-MoveReturnOld($S) {
  Write-Host (Get-MoveText 'return-old')
  $t = @(Get-MoveTransient $S); if ($t.Count) { Write-Host (Get-MoveText 'transient' @{ 'danh sách' = ($t -join ', ') }) }
}
# 0c (I14): every check that needs no freeze, before step 1 writes the mark. 0 = go. -BackStart: D.8 0c (src = new, dst = old).
# A manual back's 0c `plan <id> --check-only` carries `--dir back --attempt <state attempt + 1>` (D.0.1; W1-T10-G16, §16 R-1); every other
# 0c carries the state's values. Its stdin is the `plan <id>` stdin (D.0.9: `--check-only` and `x.check` read the same stdin).
function Test-MovePreCut($S, [switch]$BackStart) {
  $src = Get-MoveSide $S 'src'; $dst = Get-MoveSide $S 'dst'
  if ($BackStart) { $src = 'new'; $dst = 'old' }
  $backish = $BackStart -or [string]$S.dir -ceq 'back'
  # DESIGN-GAP (T10-G42, F8f): D.8's 0c lists status, gate ids, check-only and Q-back only; reading: a back start also runs the fwd 0c
  # checks that need no new data (dst free_mb, clock, gh-permission).
  $ids = Get-MoveGateIds $S
  if (-not ($ids.StOld.Known -and $ids.StNew.Known)) { return (Write-MoveIdsNoAnswer $S $ids) }
  if (-not $ids.StOld.Ok) { return (Write-MoveStatusFail $S 'old' $ids.StOld) }
  if (-not $ids.StNew.Ok) { return (Write-MoveStatusFail $S 'new' $ids.StNew) }
  if (-not $ids.Old -or $ids.Old -cne $ids.New) {
    if ($backish) { Write-MoveLines @('INV refuse gate-version side=old'); Write-Host ('  ' + (Get-MoveText 'same-gate')) }   # E-G4
    else { Write-MoveLines @('INV refuse gate-version side=new'); Write-Host ('  ' + (Get-MoveText 'copy-again')) }   # E-G3
    return 65
  }
  foreach ($st in $ids.StOld, $ids.StNew) { if ([string]$st.Kv['call_state'] -ceq 'running') { Write-Host "lỗi: máy còn đang chạy $($st.Kv['call']). Chưa làm gì."; return 75 } }
  $dk = if ($dst -ceq 'new') { $ids.StNew.Kv } else { $ids.StOld.Kv }
  if ([string]$dk['hold_active'] -cne '0') { Write-MoveLines @("MOVE error dst-running hold_active=$($dk['hold_active'])"); return 65 }
  $M = Get-MoveManifestObj
  # DESIGN-GAP (T10-G41, F8e): D.4 0c names "hostname and hosts lines"; status carries hostname only, so only the hostname is compared
  if (-not $backish) {   # no identity drift on new (E-R14)
    $hn = [string](Get-MoveProp (Get-MoveProp $M 'identity') 'hostname' '')
    if ($hn -and [string]$ids.StNew.Kv['hostname'] -cne $hn) { Write-Host "lỗi: tên máy mới ($($ids.StNew.Kv['hostname'])) khác manifest ($hn): $(Get-MoveText 'copy-again'). Chưa làm gì."; return 65 }
  }
  # DESIGN-GAP (T10-G14): "fresh space" at 0c has no formula once dst holds the copy; reading: dst free_mb >= 2048 (the B.14.8 reserve floor)
  if ("$($dk['free_mb'])" -match '\A[0-9]+\z' -and [int]$dk['free_mb'] -lt 2048) { Write-MoveLines @("INV refuse disk free_mb=$($dk['free_mb'])"); return 65 }
  $script:MoveFactsDown = $null
  $fo0 = Get-MoveFacts (Get-MoveMachine $S 'old'); $fn0 = Get-MoveFacts (Get-MoveMachine $S 'new')
  if ($script:MoveFactsDown) { return (Write-MoveNoAnswer $script:MoveFactsDown.Alias 'khi đọc dữ kiện' $script:MoveFactsDown.Code) }   # DG6: a drop is no clock refusal
  $clk = @(Get-MoveClockRefusals @{ old = $fo0; new = $fn0 })
  if ($clk.Count) { Write-MoveLines $clk; return 65 }
  $gh = @(Get-MoveGhRefusals $S); if ($gh.Count) { Write-MoveLines $gh; return 65 }
  # one read-only `plan <id> --check-only` on src; its duration sets the x.check budget
  $t0 = Get-MoveNow
  # a back start's 0c carries the stored attempt when the machines already hold dir=back (the E-R19 end of an earlier back: both at back/N), attempt + 1
  # only against a stored fwd (the server exempts exactly that, D.0.1); the write-ahead raises the attempt after Q-back
  $cd = if ($BackStart) { 'back' } else { [string]$S.dir }; $ca = if ($BackStart -and [string]$S.dir -cne 'back') { [int]$S.attempt + 1 } else { [int]$S.attempt }
  $r = Invoke-MoveGate (Get-MoveMachine $S $src) @('plan', [string]$S.move_id, '--dir', $cd, '--attempt', "$ca", '--sha', [string]$S.manifest_sha, '--serving', [string]$S.serving, '--check-only') (Get-MovePlanStdin $S @(Get-MoveMapText) $src) (Get-MoveConst 'plan_s')
  $script:MoveCheckOnlyS = [int][Math]::Ceiling(((Get-MoveNow) - $t0).TotalSeconds)
  if (-not $r.Known) { return (Write-MoveNoAnswer ([string](Get-MoveMachine $S $src).Alias) 'khi kiểm tra trước' $r.Transport) }
  if ($r.Code -ne 0) {
    if (@($r.Lines | Where-Object { $_ -cmatch '\AMOVE error manifest-stale ' }).Count) { Write-Host (Get-MoveText 'copy-again') }
    if (@($r.Lines | Where-Object { $_ -cmatch '\AMOVE error acl-mapped-id ' }).Count) { Write-Host (Get-MoveText 'acl-remedy') }
    Write-MoveTunnelRemedies $r.Lines
    Write-Host 'Chưa làm gì.'
    return $(if ($r.Code -eq 75) { 75 } else { 65 })
  }
  $back = @($r.Lines | Where-Object { $_ -cmatch '\AINV warn back-new-only ' })
  $script:MoveBackNewOnly = $back
  $u = @(Get-MoveUserRefusals $S $M | Where-Object { $_ -cmatch 'uid-collision' })
  if (-not $backish -and $u.Count) { Write-MoveLines $u; return 65 }
  if (-not $backish) { $x = Test-MoveReach $S $M $r.Lines; if ($x) { return $x } }
  0
}
# a definite failure, an exceeded deadline or a transport loss of a cutover call: @{ Code; Fail = rb|carry|human|e-r19|discard; Why }
function New-MoveFail([string]$Kind, [string]$Why, [int]$Code = 1) { @{ Fail = $Kind; Why = $Why; Code = $Code } }
# D.4 step 2's two ends (dừng, drain-stuck, the D.12.4 crash): src r.unfreeze-src under the current attempt, then the write-ahead
function Invoke-MoveAbandonStart($S, [int]$Why) {
  if ((Get-MoveSide $S 'src') -ceq 'old') { $u = Invoke-MoveCall $S 'old' 'r.unfreeze-src' } else { $u = Invoke-MoveCall $S 'new' 'r.unfreeze-src' }
  if ([string]$S.dir -ceq 'fwd') { $w = Set-MoveWriteAhead $S @{ attempt = [int]$S.attempt + 1; phase = 'copied'; mark = $null; dst_started = $false; dst_started_at = $null } -NoCheck }   # E-P35; R5-3 clear
  else { $w = Set-MoveWriteAhead $S @{ phase = 'cut'; serving = 'new'; mark = $null } -NoCheck }                                                  # E-R19 end state, E-R36
  # DESIGN-GAP (T10-G49, F8b): §8.3 has no drain-stuck remedy sentence; D.12.3 names `fcode deploy <p> recheck`; reading: this line
  if ($Why -eq 65) { Write-Host 'Còn việc deploy dở: chạy  fcode deploy <tên> recheck  cho project ở dòng trên, rồi chạy lại cutover.'; return 65 }
  if ($u.Code -ne 0) { return 70 }   # E-P37: old stays frozen until the next verb's agreement check and pre-rule
  75
}
# steps 2-10 from $From (2..10); @{ Code = 0 } at the end of chore 0, or a New-MoveFail
function Invoke-MoveCutSteps($S, [int]$From, [switch]$Carry) {
  $src = Get-MoveSide $S 'src'; $dst = Get-MoveSide $S 'dst'; $fwd = [string]$S.dir -ceq 'fwd'
  $afterStart = { param($why) if ($fwd) { New-MoveFail 'carry' $why } else { New-MoveFail 'human' $why 70 } }
  $beforeStart = { param($why) if ($Carry) { New-MoveFail 'discard' $why } elseif ($fwd) { New-MoveFail 'rb' $why } else { New-MoveFail 'e-r19' $why } }
  if ($From -le 2) {
    while ($true) {
      $r = Invoke-MoveCall $S $src 'x.freeze'
      if ($r.Code -eq 0) { break }
      if ($r.Code -eq 75 -and -not $Carry) {
        # Q-drain lists the `MOVE wait drain` locks and the `MOVE wait follower` units (D.15, DECISION-1k6-K1budget)
        $lk = @($r.Lines | ForEach-Object { if ("$_" -cmatch '\AMOVE wait drain ') { [string](ConvertFrom-MoveKv $_)['lock'] } elseif ("$_" -cmatch '\AMOVE wait follower ') { [string](ConvertFrom-MoveKv $_)['unit'] } } | Where-Object { $_ }) -join ', '
        $a = Read-MoveAnswer (Get-MoveText 'Q-drain' @{ 'khóa hoặc unit' = $lk; n = (Get-MoveConst 'drain_wait_min') }) @('đợi', 'dừng')
        if ($a -ceq 'đợi') { continue }
        return @{ Fail = 'abandon'; Code = 75 }
      }
      if ($r.Code -eq 65 -and @($r.Lines | Where-Object { $_ -cmatch '\AMOVE error drain-stuck ' }).Count) { return @{ Fail = 'abandon'; Code = 65 } }
      return (& $beforeStart 'x.freeze')
    }
  }
  if ($From -le 3 -and -not $Carry) {
    $r = Invoke-MoveCall $S $src 'x.check' @() (Get-MovePlanStdin $S @(Get-MoveMapText) $src)
    if ($r.Code -ne 0) { return (& $beforeStart 'x.check') }
    if (-not (Set-MoveCheckManifest $S $r.Lines)) { Write-Host 'lỗi: x.check không trả manifest đọc được (thiếu dòng MOVE manifest, hoặc sha không khớp).'; return (& $beforeStart 'x.check') }   # never re-pin the stale plan over x.check's
    # B41: a project name x.check lists that Q-back did not show is never moved aside on old; stop as E-R19 (new restarted and unfrozen), after the re-pin
    # above is saved so that r.start-src / r.unfreeze-src carry new's pin. A name Q-back showed that is gone needs no stop; a rebuilt manual back stores an empty list (D.0.10), so any project
    # x.check lists then stops; a carry-back has no key (CONTRACT §4.1) and runs no x.check
    if ([string]$S.dir -ceq 'back' -and $S.answers.PSObject.Properties['back-new-projects']) {
      $shown = @(Get-MoveMapVal $S.answers 'back-new-projects' @())
      $drift = @($r.Lines | ForEach-Object { if ("$_" -cmatch '\AINV warn back-new-only kind=project name=(\S+)\z') { $Matches[1] } } | Where-Object { $shown -cnotcontains $_ } | Sort-Object -Unique -CaseSensitive)
      if ($drift.Count) {
        Write-Host "Máy mới có dự án đăng ký sau khi hỏi Q-back: $($drift -join ', '); chạy lại  fcode move back  để xem lại danh sách."
        return (& $beforeStart 'x.check')
      }
    }
    $mt = '{"manifest":' + (Read-MoveManifest).Text.Trim() + '}'
    foreach ($m in $dst, $src) {   # D.4 step 3: x.repin on dst and on src (src writes its pin lists, W1-T5-DG-T5-4); one id, each machine its record
      $r = Invoke-MoveCall $S $m 'x.repin' @() $mt
      if ($r.Code -ne 0) { return (& $beforeStart 'x.repin') }
    }
    $r = Invoke-MoveCall $S $src 'x.baseline'
    if ($r.Code -ne 0) { return (& $beforeStart 'x.baseline') }
    Set-MoveBaseline $S $r.Lines
  }
  # a manual back runs x.guards (D.8 row 4, W1-T10-G32); a carry-back does not (D.5.2 lists steps 2, 5, 6-10)
  if ($From -le 4 -and -not $Carry) {
    $r = Invoke-MoveCall $S $src 'x.guards'
    if ($r.Code -eq 75) {
      $nm = @($r.Lines | Where-Object { $_ -cmatch '\AMOVE (wait|item) .*\bproject=' } | ForEach-Object { [string](ConvertFrom-MoveKv $_)['project'] } | Select-Object -Unique) -join ', '
      Set-MoveAnswer $S 'Q-guard' $nm; Save-MoveState $S   # R2-3 (T10-G51): kept for the question of a resume
      $a = Read-MoveAnswer (Get-MoveText 'Q-guard' @{ 'tên' = $nm }) @('tiếp tục', 'dừng')
      if ($a -cne 'tiếp tục') { return (& $beforeStart 'Q-guard') }
    } elseif ($r.Code -ne 0) { return (& $beforeStart 'x.guards') }
  }
  if ($From -le 5) {
    $script:MoveWindowT0 = Get-MoveNow
    $r = Invoke-MoveCall $S $src 'x.stop-src'; if ($r.Code -ne 0) { return (& $beforeStart 'x.stop-src') }
    $script:MoveSrcStopped = $true
    $r = Invoke-MoveCall $S $dst 'x.stop-dst'; if ($r.Code -ne 0) { return (& $beforeStart 'x.stop-dst') }
  }
  if ($From -le 6) {
    Set-MoveAnswer $S 'final-sent' "$($S.dir)-$($S.attempt)-x.final"; Save-MoveState $S   # G35
    $r = Invoke-MoveCall $S 'new' 'x.final'
    # D.5.2 (W1-T11-DG-R11-1): x.final has started once the laptop has sent it, whatever its outcome, an unknown outcome included:
    # fwd plain rollback; a carry-back or a manual back ends 70, resume only (E-R5, E-R23)
    if ($r.Code -ne 0) { if ($fwd -and -not $Carry) { return (New-MoveFail 'rb' 'x.final') }; return (New-MoveFail 'human' 'x.final' 70) }
  }
  if ($From -le 7) {
    $v = Invoke-MoveVerify $S -Final
    if ($v.Code -ne 0 -or $v.Diff.Count) {
      if ($fwd -and -not $Carry) { $f = New-MoveFail 'rb' 'x.verify'; $f.Verify = $v; return $f }
      return (New-MoveFail 'human' 'x.verify' 70)
    }
    $r = Invoke-MoveCall $S $dst 'x.prepare-id'; if ($r.Code -ne 0) { if ($fwd -and -not $Carry) { return (New-MoveFail 'rb' 'x.prepare-id') }; return (New-MoveFail 'human' 'x.prepare-id' 70) }
    $r = Invoke-MoveCall $S $dst 'x.adopt'
    foreach ($l in $r.Lines) { if ("$l" -cmatch '\AINV warn ufw-lockout addr=(\S+)') { Set-MoveAnswer $S 'ufw-lockout' $Matches[1]; Save-MoveState $S } }   # DESIGN-GAP (T10-G15): kept for the step-11 list
    if ($r.Code -ne 0) { if ($fwd -and -not $Carry) { return (New-MoveFail 'rb' 'x.adopt') }; return (New-MoveFail 'human' 'x.adopt' 70) }
    $lg = Test-MoveLogin $S $dst
    if ($lg -eq 70) { return (New-MoveFail 'human' 'lockout' 70) }
    if ($lg -ne 0) { return (New-MoveFail 'no-answer' 'x.login' 1) }   # DG6: Test-MoveLogin has shown the no-answer line
  }
  if ($From -le 8) {
    # R5-3 (D.4 step 8, D.0.9) with the DG-R5-1 reading (t11/review-r5.md:131; DESIGN-GAP, one spot): dst_started_at = now only on the
    # entry that turns dst_started from false to true, in the same save, before x.start is sent; a resume or a carry-back (already true)
    # never writes, so an empty or unparseable value prints $CutOffUnknown and never a resume's time. R5-4: "sent with the call" is the
    # existing --dst-started 1, no new token.
    if ($S.dst_started -ne $true) { Set-MoveProp $S 'dst_started_at' (Format-MoveTs (Get-MoveNow)) }
    Set-MoveProp $S 'dst_started' $true; Save-MoveState $S
    $r = Invoke-MoveCall $S $dst 'x.start'; if ($r.Code -ne 0) { return (& $afterStart 'x.start') }
    $bl = Get-MoveBaselineStdin $S $src -Carry:$Carry; if ($null -eq $bl) { return (& $afterStart 'x.baseline') }
    $r = Invoke-MoveCall $S $dst 'x.health' @() $bl; if ($r.Code -ne 0) { return (& $afterStart 'x.health') }
  }
  if ($From -le 9) {
    if (-not $Carry) { Set-MoveProp $S 'mark' 'switching'; Save-MoveState $S }
    $bl = Get-MoveBaselineStdin $S $src -Carry:$Carry; if ($null -eq $bl) { return (& $afterStart 'x.baseline') }
    $r = Invoke-MoveCall $S $dst 'x.switch' @() $bl
    if ($r.Code -eq -1) { Write-Host (Get-MoveText 'cutover-now'); return (New-MoveFail 'human' 'x.switch' 70) }   # D.5.4
    if ($r.Code -ne 0) { return (& $afterStart 'x.switch') }
    $win = if ($script:MoveWindowT0) { [int][Math]::Ceiling(((Get-MoveNow) - $script:MoveWindowT0).TotalSeconds) } else { $S.window_s }
    if ($fwd) { $f = @{ phase = 'cut'; serving = 'new'; mark = $null; enabled = $false; carry = $false; chores_done = $false; window_s = $win } }
    else { $f = @{ phase = 'back-done'; serving = 'old'; mark = $null; enabled = $false; carry = $false; chores_done = $false; window_s = $win } }
    if ($Carry) { $f.chores_done = $true }   # the fwd chores never ran: nothing to undo (D.8 step 11, carry column)
    [void](Set-MoveWriteAhead $S $f -NoCheck)
    if ($null -ne $win) { Write-Host "Thời gian dừng: $win giây." }
  }
  $c = Invoke-MoveChore0 $S $dst
  if ($c -ne 0) { return @{ Fail = 'chore0'; Code = 1 } }   # E-R25
  @{ Code = 0 }
}
# D.5.1 plain rollback (fwd); exit 10, or 70 when r.start-src or r.unfreeze-src failed
function Invoke-MoveRollback($S, $Fail) {
  Write-Host "Quay lại máy cũ (lỗi ở $($Fail.Why))..."
  # the write-ahead of the return: from here on the laptop state says "rolling back, old serving" (a Q-newlost / Q-discard return added its fence flag before calling this), so a
  # laptop killed in any call below resumes this very rollback (`cutover` = rb-continue), never a cut or carry resume, and a rebuild reads the same from old's r.* records
  [void](Set-MoveWriteAhead $S @{ mark = 'rolling-back'; serving = 'old'; carry = $false } -NoCheck)
  # E-R2: an unreachable dst is skipped after its bounded retries (it has no started or enabled hold, I12); a new already found down by
  # the agreement check gets no call at all (F2).
  # DESIGN-GAP (T10-G45, F8k): D.5.1 is silent on a DEFINITE r.stop-dst failure; reading: stop at 70, old left stopped and frozen (safe for I8).
  $d = @{ Code = -1; Known = $false }
  if (-not $script:MoveNewDown) {
    for ($i = 1; $i -le (Get-MoveConst 'retries'); $i++) { $d = Invoke-MoveCall $S 'new' 'r.stop-dst'; if ($d.Code -eq 0 -or $d.Known) { break }; if ($i -lt (Get-MoveConst 'retries')) { Wait-Move 5 } }
  }
  if ($d.Code -ne 0) {
    if (-not $d.Known) { Write-Host (Get-MoveText 'new-down') }
    elseif ($S.new_lost -eq $true -or $S.new_discarded -eq $true) { Write-Host 'lỗi: không dừng được máy mới; tắt hoặc cài lại máy mới trong trang quản lý nhà cung cấp, rồi chạy lại  fcode move cutover.'; return 70 }   # a YES return (Q-newlost / Q-discard): old is not started; new answers, so D.5.3's power-off is the remedy
    else { Write-Host 'lỗi: không dừng được máy mới; giữ nguyên, chạy lại  fcode move cutover  khi máy mới trả lời.'; return 70 }
  }
  # B59 (a) / B60: a call still running on old (a held x.stop-dst / x.stop-src of this attempt keeps old's call lock) would answer r.start-src busy: the return WAITS for it, bounded, with
  # the resume rows' wait (Wait-MoveRunning on old, its budget and polls), after the fence on new above. The in-run MoveSeen is the agreement check's old snapshot, so old's status is READ FRESH
  # here (up to `retries` reads; one that is not Ok is never read as "not running") and replaces it, then the wait re-reads it at every poll. The wait's 75 (still busy past the budget) and its
  # 1 / status-failure results cannot be returned after the write-ahead (I17): they end 70 with the state kept rolling-back (old not started, enabled false), the busy one with the plain
  # remedy text, the others with the usual one; `cutover` continues. Nothing else is written
  $os = $null
  for ($i = 1; $i -le (Get-MoveConst 'retries'); $i++) { $os = Get-MoveStatus $S 'old' -Quiet; if ($os.Ok -or $os.Known) { break }; if ($i -lt (Get-MoveConst 'retries')) { Wait-Move 5 } }
  if ($os.Ok) { $script:MoveSeen['old'] = $os; $w = Wait-MoveRunning $S '' @('old') } else { $w = 1 }
  if ($w -ne 0) { Set-MoveProp $S 'enabled' $false; Save-MoveState $S; Write-Host $(if ($w -eq 75) { Get-MoveText 'return-busy' } else { Get-MoveText 'return-incomplete' }); return 70 }
  $a = Invoke-MoveCall $S 'old' 'r.start-src'
  Set-MoveProp $S 'enabled' ($a.Code -eq 0); Save-MoveState $S
  $u = Invoke-MoveCall $S 'old' 'r.unfreeze-src'
  if ($u.Code -ne 0) { Set-MoveProp $S 'enabled' $false; Save-MoveState $S }
  [void](Invoke-MoveCall $S 'old' 'r.health-src')   # report only (E-R18)
  if ($Fail.Verify) { Write-MoveVerifyReport $S $Fail.Verify }
  # the end state is written only when r.start-src and r.unfreeze-src both returned 0; otherwise the state stays `rolling-back` and `cutover` re-sends the three calls
  # (rollback mode: the unit connectors too); a chore 0 is never the repair of a return
  if ($a.Code -ne 0 -or $u.Code -ne 0) { Write-Host $(if (@($a.Code, $u.Code | Where-Object { $_ -ne 0 -and $_ -ne 75 }).Count -eq 0) { Get-MoveText 'return-busy' } else { Get-MoveText 'return-incomplete' }); return 70 }   # busy (75) alone = nothing to fix: the plain remedy; a real failure keeps the old text
  [void](Set-MoveWriteAhead $S @{ mark = $null; phase = 'rolled-back'; serving = 'old'; enabled = $true } -NoCheck)
  Write-MoveReturnOld $S
  10
}
# ruling 06/11 (32), B38: a verify.lst line is path, type, size, mode, owner, group, mtime, link, acl, then (new servers) sha256, the last field,
# empty for a file outside the sum set. A path on one side only is a difference. Fields 1-9 always decide; the sha256 decides only when both
# lines carry a non-empty one (an older server's line has no field 10, an empty one means "no hash": never a difference), and then two
# different hashes are a difference.
function Test-MoveLstSame($A, $B) {
  if ($null -eq $A -or $null -eq $B) { return ($null -eq $A -and $null -eq $B) }
  $fa = @($A -split "`t"); $fb = @($B -split "`t")
  if ($fa.Count -gt 9 -and $fb.Count -gt 9 -and $fa[9] -and $fb[9] -and $fa[9] -cne $fb[9]) { return $false }
  ($fa[0..8] -join "`t") -ceq ($fb[0..8] -join "`t")
}
# B.8.6 / E-T12: after the rollback, both verify.lst (status --lst) and the first 20 differing paths
function Write-MoveVerifyReport($S, $V) {
  $lst = @{}
  foreach ($m in 'old', 'new') {
    $lst[$m] = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)   # Linux paths differing only in case stay distinct
    if (-not $V.Id[$m]) { continue }
    $st = Get-MoveStatus $S $m @('--lst', [string]$V.Id[$m]) -Quiet
    $item = ''
    foreach ($l in $st.Lines) {
      if ("$l" -notmatch '\AMOVE lst (.*)\z') { continue }
      $x = $Matches[1]
      if ($x -cmatch '\A# item=(\S+)') { $item = $Matches[1]; continue }
      $p = ($x -split "`t")[0]; $lst[$m]["$item`t$p"] = $x
    }
  }
  $n = 0
  foreach ($k in @(@($lst['old'].Keys) + @($lst['new'].Keys) | Sort-Object -CaseSensitive -Unique)) {
    $a = $null; $b = $null; [void]$lst['old'].TryGetValue($k, [ref]$a); [void]$lst['new'].TryGetValue($k, [ref]$b)
    if (Test-MoveLstSame $a $b) { continue }
    $ip = $k -split "`t", 2
    Write-MoveLines @("MOVE error sum-mismatch item=$($ip[0]) path=$($ip[1])")
    if (++$n -ge 20) { break }
  }
}
# D.5.2 carry-back: write-ahead, b.init-*, then D.8 steps 2, 5, 6-10 with the fwd mark kept; Q-discard before x.final
function Invoke-MoveCarryBack($S, [switch]$Resume) {
  $script:MoveNoAnswer = $false   # D.5.2: the loss that led here was resolved by new's status answer (Complete-MoveCutFail 'carry'); this carry-back's own exit decides (B24)
  if (-not $Resume) {
    Write-Host 'Lỗi sau khi máy mới đã chạy: chép ngược dữ liệu về máy cũ (tự động)...'
    [void]$S.answers.PSObject.Properties.Remove('back-new-projects')   # CONTRACT §4.1: a carry-back has no Q-back list (it runs no x.check); the write-ahead below saves it
    $w = Set-MoveWriteAhead $S @{ dir = 'back'; attempt = [int]$S.attempt + 1; phase = 'planned'; carry = $true }
    if ($w -ne 0) { return $(if ($w -eq 1 -and $script:MoveNoAnswer) { 1 } else { 70 }) }   # this write-ahead's own loss; a definite b.init failure stays 70
  }
  if ($script:MoveNewDown) {   # F2: a carry-back resumed while new is down; no call to new
    if (Test-MoveFinalSent $S) { return (Invoke-MoveCarryFail $S (New-MoveFail 'human' 'x.final' 70)) }   # E-R5: resume only
    return (Invoke-MoveCarryFail $S (New-MoveFail 'discard' 'new down'))                                    # D.5.2: the power-off Q-discard
  }
  foreach ($m in 'new', 'old') { $c = Invoke-MoveInit $S $m; if ($c -ne 0) { return (Invoke-MoveCarryFail $S (New-MoveFail 'discard' "b.init-$m")) } }
  $from = 2
  if ($Resume) { $st = Get-MoveStatus $S 'new' -Quiet; if ((Test-MoveFinalSent $S) -or ($st.Ok -and [string]$st.Kv['last_final'] -ceq "back-$($S.attempt)-x.final")) { $from = 6 } }
  $f = Invoke-MoveCutSteps $S $from -Carry
  if ($f.Code -eq 0) { Write-MoveReturnOld $S; return 10 }
  Invoke-MoveCarryFail $S $f
}
# DESIGN-GAP (T10-G35): D.5.2 splits a carry-back failure at "x.final has started", and no state field records it; a resume while new
# is down cannot read new's last_final. Reading: answers{'final-sent'} = the x.final call id, saved before the call is sent.
function Test-MoveFinalSent($S) { [string](Get-MoveMapVal $S.answers 'final-sent' '') -ceq "$($S.dir)-$($S.attempt)-x.final" }
# DESIGN-GAP (T10-G36): answers{'Q-cut'}.ts = the fwd cutover start (in-run, before step 1; rebuilt from the start= of old's latest fwd
# x.freeze record, R2-4, Get-MoveRebuiltCutOff); its only reader is step 11's `--created` since. D.5.3 rev 1k3.6 (:551) overrules it for
# `<giờ>`, which is dst_started_at (below).
# DESIGN-GAP / R5-2 (D.5.3 :551 "`<giờ>` … is `dst_started_at` in the laptop's time zone"; the format is not named): the fill is the bare
# local time in $GioFmt, or $CutOffUnknown when dst_started_at is empty or unparseable.
function Get-MoveCutOff($S) {
  $GioFmt = 'dd/MM/yyyy HH:mm:ss'
  $CutOffUnknown = 'không rõ'
  $dst_started_at = Get-MoveProp $S 'dst_started_at' ''
  if (-not $dst_started_at -or $null -eq (ConvertTo-MoveTime $dst_started_at)) { return $CutOffUnknown }
  (ConvertTo-MoveTime $dst_started_at).ToLocalTime().ToString($GioFmt, [Globalization.CultureInfo]::InvariantCulture)
}
# the start= of the latest fwd attempt's x.freeze record on old ('' when none): the cutover start of a rebuilt state (G36, R2-4)
function Get-MoveRebuiltCutOff($Recs) {
  $best = $null; $ba = -1
  foreach ($rr in @($Recs)) { if ("$($rr['id'])" -match '\Afwd-([0-9]+)-x\.freeze\z' -and [int]$Matches[1] -gt $ba -and (ConvertTo-MoveTime $rr['start'])) { $ba = [int]$Matches[1]; $best = [string]$rr['start'] } }
  if ($best) { $best } else { '' }
}
# DESIGN-GAP / R5-1 (D.0.10 :490 names no source for dst_started_at; the move-id holds no time): the start= of new's `fwd-<a>-x.start`
# record, a = attempt when dir=fwd, attempt − 1 when carry=true (D.5.2 writes attempt+1); '' in every other case (a manual back, no such
# record, start=-).
function Get-MoveRebuiltDstStartedAt($S, $Recs) {
  $a = if ([string]$S.dir -ceq 'fwd') { [int]$S.attempt } elseif ($S.carry -eq $true) { [int]$S.attempt - 1 } else { return '' }
  foreach ($rr in @($Recs)) { if ([string]$rr['id'] -ceq "fwd-$a-x.start" -and (ConvertTo-MoveTime $rr['start'])) { return [string]$rr['start'] } }
  ''
}
# both `MOVE state` lines as the machines print them (D.5.2 "exit 70 with both status answers"); a down new is not asked.
# Returns $true when new answered status (a gate answer, any exit), $false when it did not (down, or no answer): ruling 05/11 (27) F4
function Write-MoveBothStatus($S) {
  $newAnswered = $false
  foreach ($m in 'old', 'new') {
    if ($m -ceq 'new' -and $script:MoveNewDown) { Write-Host "  máy mới: không trả lời"; continue }
    $st = Get-MoveStatus $S $m -Quiet
    if ($m -ceq 'new') { $newAnswered = [bool]$st.Known }
    foreach ($l in @($st.Lines | Where-Object { "$_" -cmatch '\AMOVE state ' })) { Write-Host "  $l" }
    if (-not $st.Ok) { Write-Host "  máy $(if ($m -ceq 'old') { 'cũ' } else { 'mới' }): không đọc được trạng thái (mã $($st.Code))" }
  }
  $newAnswered
}
function Invoke-MoveCarryFail($S, $F) {
  if ($F.Fail -ceq 'no-answer') { return 1 }   # DG6: the no-answer line is the last line
  if ($F.Fail -ceq 'chore0') { Write-MoveReturnOld $S; Write-Host (Get-MoveText 'cutover-again'); return 1 }   # F11, E-R25: old serves after x.switch
  $resume = Get-MoveText 'carry-resume'
  if ($F.Fail -cne 'discard') {   # after x.final started (E-R5, E-R23): resume only; ruling 05/11 (27) F4: new answered status -> the resume line, else the carry-half sentence
    if (Write-MoveBothStatus $S) { Write-Host $resume } else { Write-Host (Get-MoveText 'carry-half') }
    return 70
  }
  # Q-discard: the clean form only when new's x.stop-src returned 0 and new shows hold_active=0
  $clean = $false
  if (-not $script:MoveNewDown) { $st = Get-MoveStatus $S 'new' -Quiet; $clean = [bool]($script:MoveSrcStopped -and $st.Ok -and [string]$st.Kv['hold_active'] -ceq '0') }
  $a = Read-MoveAnswer (Get-MoveText $(if ($clean) { 'Q-discard' } else { 'Q-newlost' }) @{ 'giờ' = (Get-MoveCutOff $S) }) @('YES')
  if ($a -cne 'YES') { Write-Host "Chưa làm gì thêm. $resume"; return 70 }
  Invoke-MoveOldBack $S $(if ($clean) { 'new_discarded' } else { 'new_lost' })
}
# Q-discard / Q-newlost YES: old r.start-src, r.unfreeze-src, r.health-src; rolled-back, serving old, carry false; exit 10
function Invoke-MoveOldBack($S, [string]$Flag) {
  # one code path with the plain rollback: the write-ahead (state rolling-back, serving old, carry false, the fence flag) comes BEFORE r.start-src
  [void](Set-MoveWriteAhead $S @{ mark = 'rolling-back'; serving = 'old'; carry = $false; enabled = $false; $Flag = $true } -NoCheck)
  Invoke-MoveRollback $S (New-MoveFail 'rb' $(if ($Flag -ceq 'new_lost') { 'máy mới bị mất' } else { 'bỏ máy mới' }))
}
# D.8 E-R19 (manual back, a failure before x.start on old): new r.start-src + r.unfreeze-src; dir back, phase cut, serving new, mark null
function Invoke-MoveER19($S) {
  $a = Invoke-MoveCall $S 'new' 'r.start-src'
  $u = Invoke-MoveCall $S 'new' 'r.unfreeze-src'
  [void](Set-MoveWriteAhead $S @{ phase = 'cut'; serving = 'new'; mark = $null; enabled = ($a.Code -eq 0 -and $u.Code -eq 0) } -NoCheck)
  Write-Host 'Chuyển ngược không xong; máy mới vẫn phục vụ như trước.'
  if ($a.Code -ne 0 -or $u.Code -ne 0) { return 70 }
  1
}
# D.5.3 (W1-T11-DG-T11-11): the run that finds new unreachable after dst_started ends 70 without a question; the next `cutover` asks
# Q-newlost when new still does not answer status (Invoke-Move); YES puts old back with its own data, any other answer ends 70 again.
function Invoke-MoveNewLost($S) {
  Write-Host 'Máy mới không trả lời sau khi đã chạy ứng dụng.'
  $a = Read-MoveAnswer (Get-MoveText 'Q-newlost' @{ 'giờ' = (Get-MoveCutOff $S) }) @('YES')
  if ($a -cne 'YES') { return 70 }
  Invoke-MoveOldBack $S 'new_lost'
}
# what a failed run does next
function Complete-MoveCutFail($S, $F) {
  switch -CaseSensitive ($F.Fail) {
    'rb' { return (Invoke-MoveRollback $S $F) }
    'carry' {
      $st = Get-MoveStatus $S 'new' -Quiet
      if (-not $st.Known) { Write-Host 'Máy mới không trả lời sau khi đã chạy ứng dụng; chạy lại  fcode move cutover  để chọn cách xử lý.'; return 70 }   # E-R4: no automatic action
      return (Invoke-MoveCarryBack $S)
    }
    'discard' { return (Invoke-MoveCarryFail $S $F) }
    'e-r19' { return (Invoke-MoveER19 $S) }
    'abandon' { return (Invoke-MoveAbandonStart $S $F.Code) }
    'chore0' { Write-Host (Get-MoveText 'cutover-again'); return 1 }
    'no-answer' { return 1 }   # DG6: Test-MoveLogin has shown the no-answer line, the last line
    default { Write-Host "Cần người xem: lỗi ở $($F.Why); chạy lại lệnh khi đã sửa."; return $(if ($F.Code) { $F.Code } else { 70 }) }
  }
}
# D.4 step 11 (fwd) and D.8 step 11 (back): each chore idempotent; chores_done when all succeeded
function Invoke-MoveChores($S) {
  $fwd = [string]$S.serving -ceq 'new'
  $M = Get-MoveManifestObj; $ok = $true
  foreach ($lp in @(Get-MoveProp $S 'legacy_push' @())) {
    $repo = [string]$lp.repo
    $line = if ($fwd) { "$($S.new.addr) $($S.new.hostkey_line)" } else { [string](Get-MoveMapVal $S.legacy_known_hosts $repo '') }
    if (-not $line) { continue }
    $g = Invoke-MoveTool 'gh' @('secret', 'set', 'DEPLOY_KNOWN_HOSTS', '-R', $repo) $line
    if ($g.Code -ne 0) { Write-Host "lỗi: gh secret set DEPLOY_KNOWN_HOSTS -R $repo (mã $($g.Code))."; $ok = $false } else { Write-Host "DEPLOY_KNOWN_HOSTS của $repo đã cập nhật." }
  }
  if ((Set-MoveAliases $S $fwd) -ne 0) { $ok = $false }
  if ($fwd) {
    $since = [string](Get-MoveProp (Get-MoveMapVal $S.answers 'Q-cut') 'ts' '')
    foreach ($lp in @(Get-MoveProp $S 'legacy_push' @())) {
      if (-not $since) { break }
      $g = Invoke-MoveTool 'gh' @('run', 'list', '-R', [string]$lp.repo, '--status', 'failure', '--created', ">=$since", '--json', 'databaseId,displayTitle,createdAt')
      if ($g.Code -eq 0) { try { foreach ($x in @(ConvertFrom-Json ($g.Out -join "`n"))) { if ($x) { Write-Host "Lượt chạy lỗi trong lúc chuyển ($($lp.repo)): $($x.databaseId) $($x.displayTitle) — chạy lại tay." } } } catch { } }
    }
    $names = @(@(Get-MoveProp $M 'hostnames' @()) | Where-Object { [string]$_.class -cin 'direct', 'proxied', 'unrouted' } | ForEach-Object { "$($_.name) ($($_.class))" })
    if ($names.Count) { Write-Host "Đổi ngay các tên sau sang địa chỉ máy mới $($S.new.addr): $($names -join ', ')" }
    $ib = @(@(Get-MoveProp $M 'hostnames' @()) | Where-Object { [string]$_.class -ceq 'inbound-backed' } | ForEach-Object { [string]$_.name })
    if ($ib.Count) { Write-Host "Tên phụ thuộc kết nối vào (inbound-backed): $($ib -join ', ')" }
    foreach ($x in @(Get-MoveProp $M 'inbound' @())) { Write-Host "Kết nối vào cần trỏ lại: $(ConvertTo-Json -InputObject $x -Compress)" }
    foreach ($x in @(Get-MoveProp $M 'public_ports' @())) { Write-Host "Dịch vụ nhận kết nối thẳng qua IP: $(ConvertTo-Json -InputObject $x -Compress)" }
    $ufw = [string](Get-MoveMapVal $S.answers 'ufw-lockout' '')
    if ($ufw) { Write-MoveLines @("INV warn ufw-lockout addr=$ufw"); Write-Host '  cho phép cổng 22 từ địa chỉ của laptop, rồi chạy ufw enable trên máy mới.' }
    if ($null -ne $S.window_s) { Write-Host "Thời gian dừng: $($S.window_s) giây." }
  }
  if (-not $ok) { Write-Host (Get-MoveText 'cutover-again'); return 1 }
  Set-MoveProp $S 'chores_done' $true; Save-MoveState $S
  Write-Host $(if ($fwd) { 'Đã chuyển xong. Khi chắc chắn:  fcode move finish   (cần quay lại:  fcode move back)' } else { 'Đã quay về máy cũ xong.' })
  0
}
# the HostName/HostKeyAlias rewrite of `Host <alias>` in an ssh config text: @{ Text; Found }
function Set-MoveSshBlock([string]$Text, [string]$Alias, [string]$HostName, [string]$KeyAlias) {
  $nl = if ($Text -match "`r`n") { "`r`n" } else { "`n" }
  $lines = @($Text -split '\r?\n'); $out = New-Object Collections.Generic.List[string]; $in = $false; $found = $false; $done = $false
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if ($l -match '^\s*(Host|Match)(\s*=\s*|\s+)(.*?)\s*$') {
      if ($in -and -not $done) { $out.Add("  HostName $HostName"); if ($KeyAlias) { $out.Add("  HostKeyAlias $KeyAlias") }; $done = $true }
      $in = ($Matches[1] -ieq 'Host' -and @($Matches[3] -split '\s+').Count -eq 1 -and $Matches[3] -ceq $Alias); if ($in) { $found = $true; $done = $false }
      $out.Add($l); continue
    }
    if ($in -and $l -match '^\s*(HostName|HostKeyAlias)(\s*=\s*|\s+)') { continue }
    $out.Add($l)
  }
  if ($in -and -not $done) { $out.Add("  HostName $HostName"); if ($KeyAlias) { $out.Add("  HostKeyAlias $KeyAlias") } }
  @{ Text = ($out -join $nl); Found = $found }
}
# step 11: the laptop alias and the coder alias of old follow the move; backups (old's HostName) saved in the state before each write (E-L9)
function Set-MoveAliases($S, [bool]$ToNew) {
  $alias = [string]$S.old.alias; $rc = 0
  $cfg = Join-Path (Join-Path $env:USERPROFILE '.ssh') 'config'
  $text = if ([IO.File]::Exists($cfg)) { [IO.File]::ReadAllText($cfg) } else { '' }
  if ($ToNew) {
    if (-not $S.aliases.laptop_backup) { Set-MoveProp $S.aliases 'laptop_backup' ([string]$S.old.addr); Save-MoveState $S }
    $r = Set-MoveSshBlock $text $alias ([string]$S.new.addr) ([string]$S.new.addr)
    if (-not $r.Found) { Write-Host "lỗi: ~/.ssh/config không có khối 'Host $alias' riêng (nằm trong Include?)."; $rc = 1 }
    else {
      $kh = Join-Path (Join-Path $env:USERPROFILE '.ssh') 'known_hosts'; $kl = "$($S.new.addr) $($S.new.hostkey_line)"
      $kt = if ([IO.File]::Exists($kh)) { [IO.File]::ReadAllText($kh) } else { '' }
      if (@($kt -split '\r?\n') -cnotcontains $kl) { Write-PhienText $kh ($kt + $(if ($kt -and -not $kt.EndsWith("`n")) { "`n" }) + $kl + "`n") }
      if ($r.Text -cne $text) { Write-PhienText $cfg $r.Text }
      Write-Host "ssh config của máy này: '$alias' giờ vào máy mới ($($S.new.addr))."
    }
  } elseif ($S.aliases.laptop_backup) {
    $r = Set-MoveSshBlock $text $alias ([string]$S.aliases.laptop_backup) ''
    if ($r.Found -and $r.Text -cne $text) { Write-PhienText $cfg $r.Text }
    Write-Host "ssh config của máy này: '$alias' lại vào máy cũ."
  }
  # coder (B.11.3): an unreachable coder is a warning, never a failure
  $target = if ($ToNew) { [string]$S.new.addr } else { [string]$S.aliases.coder_backup }
  if (-not $target) { return $rc }
  if ($ToNew -and -not $S.aliases.coder_backup) { Set-MoveProp $S.aliases 'coder_backup' ([string]$S.old.addr); Save-MoveState $S }
  $b = Invoke-MoveBox (Get-MoveCoderAliasScript) @($alias, $target, $(if ($ToNew) { [string]$S.new.addr } else { '-' }), $(if ($ToNew) { "$($S.new.addr) $($S.new.hostkey_line)" } else { '-' }))
  if ($b.Code -ne 0 -or -not @($b.Lines | Where-Object { $_ -cmatch '\AMOVE alias coder state=' }).Count) { Write-MoveLines @('INV warn coder-unreachable') }
  $rc
}

# D.11 resume of a run in flight (mark set): real state first (I16), then the step to go on from
function Invoke-MoveCutResume($S) {
  $src = Get-MoveSide $S 'src'; $pre = "$($S.dir)-$($S.attempt)-"
  if ([string]$S.mark -ceq 'switching') { $f = Invoke-MoveCutSteps $S 9 }
  elseif ($S.dst_started -eq $true) { $f = Invoke-MoveCutSteps $S 8 }
  else {
    $st = $script:MoveSeen[$src]; if (-not $st) { $st = Get-MoveStatus $S $src -Quiet }
    $call = [string]$st.Kv['call']; $cs = [string]$st.Kv['call_state']; $rc = [string]$st.Kv['rc']
    if ($call -ceq "${pre}x.freeze" -and $cs -ceq 'failed' -and $rc -cin '75', '65') { return (Invoke-MoveAbandonStart $S ([int]$rc)) }   # D.12.4
    $guardBusy = ($call -ceq "${pre}x.guards" -and $cs -ceq 'failed' -and $rc -ceq '75')   # Q-guard was being asked when the laptop stopped
    foreach ($m in 'old', 'new') {
      $x = $script:MoveSeen[$m]
      if ($guardBusy -and $m -ceq $src) { continue }
      if ($x -and ([string]$x.Kv['call']).StartsWith($pre) -and [string]$x.Kv['call_state'] -ceq 'failed') {
        # D.8 steps 6-7 of a manual back (x.final, x.verify, x.prepare-id, x.adopt): once x.final was sent old holds an incomplete copy, the failure ended 70 "resume"
        # and it stays a resume: never the E-R19 restart of new (D.8 step 5 only); the steps below re-send from step 5 (done calls replay)
        if ([string]$S.dir -ceq 'back' -and ([string]$x.Kv['call'] -replace '\A(fwd|back)-[0-9]+-', '') -cin 'x.final', 'x.verify', 'x.prepare-id', 'x.adopt') { continue }
        return (Complete-MoveCutFail $S $(if ([string]$S.dir -ceq 'fwd') { New-MoveFail 'rb' $x.Kv['call'] } else { New-MoveFail 'e-r19' $x.Kv['call'] }))
      }
    }
    if ($script:MoveNewDown) { return (Complete-MoveCutFail $S (New-MoveFail 'rb' 'máy mới không trả lời')) }   # F2: fwd, dst never started (E-R2)
    # F12 (D.4 step 4 "the guards are not run again"): once src went past step 4, the resume starts at step 5
    $from = 2
    if ($guardBusy) {
      # DESIGN-GAP (T10-G51, R2-3): the busy projects come only from x.guards' output, lost with the laptop run; reading: answers{'Q-guard'}
      # holds them from the in-run question (written just before it is asked)
      $a = Read-MoveAnswer (Get-MoveText 'Q-guard' @{ 'tên' = [string](Get-MoveMapVal $S.answers 'Q-guard' '') }) @('tiếp tục', 'dừng')
      if ($a -cne 'tiếp tục') { return (Complete-MoveCutFail $S $(if ([string]$S.dir -ceq 'fwd') { New-MoveFail 'rb' 'Q-guard' } else { New-MoveFail 'e-r19' 'Q-guard' })) }
      $from = 5
    } elseif ($call.StartsWith($pre) -and ($call -replace '\A(fwd|back)-[0-9]+-', '') -cin 'x.stop-src', 'x.final', 'x.verify', 'x.prepare-id', 'x.adopt', 'x.start', 'x.health', 'x.switch') { $from = 5 }   # R2-2: in dir=back src = new runs x.final
    # D.11 "a running final transfer is re-attached": new holding this attempt's x.final (running or done) → resume at step 6, so the same
    # id attaches (or replays) and no earlier step is re-sent while its unit holds new's call lock
    $nx = $script:MoveSeen['new']
    if ($nx -and [string]$nx.Kv['call'] -ceq "${pre}x.final" -and [string]$nx.Kv['call_state'] -cin 'running', 'done') { $from = 6 }
    $f = Invoke-MoveCutSteps $S $from   # replays every call that returned 0 (D.0.5), re-attaches a running one
  }
  if ($f.Code -eq 0) { return (Invoke-MoveChores $S) }
  Complete-MoveCutFail $S $f
}
# D.4: preconditions 0a-0d, then steps 1-11
function Invoke-MoveCutRun($S) {
  if (Test-MoveRefreshPending $S) { Write-Host "lỗi: lần chép lại trước chưa xong: $(Get-MoveText 'copy-again'). Chưa làm gì."; return 1 }   # G50
  $last = ConvertTo-MoveTime $S.last_copy_at
  if ([string]$S.dir -ceq 'fwd' -and (-not $last -or ((Get-MoveNow) - $last).TotalMinutes -gt (Get-MoveConst 'refresh_min'))) {   # 0b
    Write-Host 'cutover (0b): lần chép cuối đã cũ, chép lại trước...'
    $p = Invoke-MovePasses $S; if ($p -ne 0) { return $p }
  }
  $c = Test-MovePreCut $S; if ($c -ne 0) { return $c }
  if ([string]$S.dir -ceq 'fwd') {
    Write-MoveLines @(Get-MoveMapVal $S.answers 'init-new-warn' @())   # B.5.11: c.init-new's dst-own-unit / new-only lines, kept for Q-cut
    $a = Read-MoveAnswer (Get-MoveCutText $S (Get-MoveTransient $S)) @('có', 'không')
    if ($a -cne 'có') { Write-Host 'Đã hủy, chưa làm gì.'; return 0 }
    Set-MoveAnswer $S 'Q-cut' ([pscustomobject]@{ a = 'có'; ts = (Format-MoveTs (Get-MoveNow)) })
  }
  [void](Set-MoveWriteAhead $S @{ mark = 'cutting'; dst_started = $false; dst_started_at = $null } -NoCheck)   # step 1; R5-3 clear
  $script:MoveSrcStopped = $false
  $f = Invoke-MoveCutSteps $S 2
  if ($f.Code -eq 0) { return (Invoke-MoveChores $S) }
  Complete-MoveCutFail $S $f
}
# D.8: Q-back, write-ahead, b.init-*, pre-copy, then the cutover steps with dir=back
function Invoke-MoveBackStart($S) {
  if ($S.serving -cne 'new' -or $S.chores_done -ne $true) { Write-Host "lỗi: chỉ quay lại được khi máy mới đang phục vụ và các việc sau chuyển đã xong (chạy fcode move cutover trước)."; return 1 }
  $c = Test-MovePreCut $S -BackStart; if ($c -ne 0) { return $c }
  $list = @($script:MoveBackNewOnly | ForEach-Object { $_ -replace '\AINV warn back-new-only ', '' }) -join '; '
  $a = Read-MoveAnswer (Get-MoveText 'Q-back' @{ 'danh sách' = $(if ($list) { $list } else { '-' }) }) @('YES')
  if ($a -cne 'YES') { Write-Host 'Đã hủy, chưa làm gì.'; return (Get-MoveDeclinedExit) }
  Set-MoveAnswer $S 'Q-back' 'YES'
  # the project names Q-back showed (B41): the back's x.check may list only these or fewer (D.8)
  Set-MoveAnswer $S 'back-new-projects' @(@($script:MoveBackNewOnly | ForEach-Object { if ("$_" -cmatch '\AINV warn back-new-only kind=project name=(\S+)\z') { $Matches[1] } } | Sort-Object -Unique -CaseSensitive))
  Save-MoveState $S
  [void](Set-MoveWriteAhead $S @{ dir = 'back'; attempt = [int]$S.attempt + 1; phase = 'planned'; carry = $false; dst_started = $false; dst_started_at = $null } -NoCheck)   # the back's dst (old) has not started: b.init-old / b.init-new send --dst-started 0, so a rebuilt manual back does not read the fwd's dst_started (D.0.10); R5-3 clear
  Invoke-MoveBackRun $S
}
function Invoke-MoveBackRun($S) {
  foreach ($m in 'new', 'old') { $c = Invoke-MoveInit $S $m; if ($c -ne 0) { return $c } }
  # DESIGN-GAP (T10-G17): "when the last fwd final is older than 10 min" has no stored time; reading: always one pre-copy new→old
  if ([string]$S.phase -ceq 'planned') {
    $r = Invoke-MoveCall $S 'new' 'c.transfer.N'; if ($r.Code -ne 0) { return (ConvertTo-MoveExit $r.Code) }
    Set-MoveProp $S 'phase' 'copied'; Save-MoveState $S
  }
  [void](Set-MoveWriteAhead $S @{ mark = 'cutting'; dst_started = $false; dst_started_at = $null } -NoCheck)   # D.8 step 1; R5-3 clear
  $script:MoveSrcStopped = $false
  $f = Invoke-MoveCutSteps $S 2
  # DESIGN-GAP (T10-G43, F8h, DG-T11-8): I17 has "10 rolled back, old serves" and D.8 names no exit for a completed manual back; reading:
  # 0 (the owner asked for it; nothing failed). A carry-back ends 10 (D.5.2).
  if ($f.Code -eq 0) { $c = Invoke-MoveChores $S; if ($c -ne 0) { return $c }; return 0 }
  Complete-MoveCutFail $S $f
}
# D.4 step 8 / 9 (B.14.7): `x.health` and `x.switch` read x.baseline's `MOVE item <id> kind=health` lines on stdin (a check that failed in the baseline does not
# gate, a tunnel name keeps its baseline status class). The laptop keeps them in answers{'health-baseline'} = {id = "<dir>-<attempt>"; lines[]} when x.baseline
# returns 0 and sends them again on a resume; a state without them for this attempt (laptop died before the save, rebuilt state) gets them by replaying
# this attempt's x.baseline (a done record answers with its stored out, nothing runs; step 8 is reached only after it returned 0). A carry-back has no
# x.baseline: empty stdin (every check gates). $null = the baseline could not be recovered
function Set-MoveBaseline($S, $Lines) {
  Set-MoveAnswer $S 'health-baseline' ([pscustomobject][ordered]@{ id = "$($S.dir)-$($S.attempt)"; lines = @(@($Lines | Where-Object { "$_" -cmatch '\AMOVE item \S+ kind=health ' } | ForEach-Object { "$_" })) })
  Save-MoveState $S
}
function Get-MoveBaselineStdin($S, [string]$Src, [switch]$Carry) {
  if ($Carry) { return '' }
  $b = Get-MoveMapVal $S.answers 'health-baseline' $null
  if (-not ($b -and [string]$b.id -ceq "$($S.dir)-$($S.attempt)")) {
    $r = Invoke-MoveCall $S $Src 'x.baseline' -Quiet
    if ($r.Code -ne 0) { return $null }
    Set-MoveBaseline $S $r.Lines
    $b = Get-MoveMapVal $S.answers 'health-baseline' $null
  }
  $ls = @(@($b.lines) | Where-Object { "$_" })
  if ($ls.Count) { ($ls -join "`n") + "`n" } else { '' }
}
# a fresh unrecorded status of $Machine: its move-id is this move's and `finished`
function Test-MoveSideFinished($S, [string]$Machine) {
  $st = Get-MoveStatus $S $Machine -Quiet
  [bool]($st.Ok -and [string]$st.Kv['move_id'] -ceq [string]$S.move_id -and [string]$st.Kv['state'] -ceq 'finished')
}
# D.7 finish, "new healthy now" (I27; W1-T10-G18, W1-T11-DG-T11-5): new's unrecorded status answers GATE_EXIT 0, no call running,
# frozen=0, and hold_active equal to the number of non-follower holds of hold_sets.start
function Test-MoveFinishHealth($S) {
  $st = Get-MoveStatus $S 'new' -Quiet
  if (-not $st.Known) { [void](Write-MoveNoAnswer ([string]$S.new.alias) 'khi kiểm tra sức khỏe' $st.Transport); return $false }   # a Known non-zero status stays "Kiểm tra sức khỏe không đạt"
  $M = Get-MoveManifestObj; $fol = @(Get-MoveProp $M 'followers' @() | ForEach-Object { [string]$_ })
  $need = @(@(Get-MoveProp (Get-MoveProp $M 'hold_sets') 'start' @()) | Where-Object { $fol -cnotcontains [string]$_ }).Count
  $ok = [bool]($st.Ok -and [string]$st.Kv['call_state'] -cne 'running' -and -not (Test-MoveFrozen $st.Kv) -and "$($st.Kv['hold_active'])" -match '\A[0-9]+\z' -and [int]$st.Kv['hold_active'] -eq $need)
  if (-not $ok) { Write-MoveLines @("MOVE error health side=new hold_active=$($st.Kv['hold_active'])") }
  $ok
}
function Invoke-MoveFinishCmd($S) {
  if ($S.serving -cne 'new' -or [string]$S.phase -cne 'cut' -or $S.mark) { Write-Host 'lỗi: finish chỉ chạy khi máy mới đang phục vụ (giai đoạn cut).'; return 1 }
  if ($S.chores_done -ne $true) { Write-Host "lỗi: còn việc sau chuyển chưa xong: $(Get-MoveText 'cutover-again')."; return 1 }   # I27
  if (-not (Test-MoveFinishHealth $S)) { return 1 }
  $a = Read-MoveAnswer (Get-MoveText 'Q-finish') @('YES')
  if ($a -cne 'YES') { Write-Host 'Đã hủy, chưa làm gì.'; return (Get-MoveDeclinedExit) }
  Set-MoveAnswer $S 'Q-finish' 'YES'
  # D.11 `finished: finish idempotent`: a finish that ran f.old (or f.new) but did not record the end is re-run; the door of a finished old answers only
  # `--move status` (`moved`), so a machine whose move-id is already this move's finished is skipped, and a refusal / lost answer from one that
  # turns out finished is the call done
  if (Test-MoveSideFinished $S 'old') { Write-Host "máy '$($S.old.alias)' đã kết thúc (f.old); bỏ qua." }
  else {
    $r = Invoke-MoveCall $S 'old' 'f.old'
    if ($r.Code -ne 0 -and -not (Test-MoveSideFinished $S 'old')) { return (ConvertTo-MoveExit $r.Code) }
  }
  if (Test-MoveSideFinished $S 'new') { Write-Host "máy '$($S.new.alias)' đã kết thúc (f.new); bỏ qua." }
  else {
    $r = Invoke-MoveCall $S 'new' 'f.new'
    if ($r.Code -ne 0 -and -not (Test-MoveSideFinished $S 'new')) { return (ConvertTo-MoveExit $r.Code) }
  }
  Set-MoveProp $S 'phase' 'finished'; Save-MoveState $S
  Write-Host "Đã kết thúc chuyển máy. Máy mới '$($S.new.alias)' đang phục vụ; máy cũ '$($S.old.alias)' đã tắt ứng dụng (giữ 7 ngày rồi hủy)."
  0
}
# D.9 abort
function Invoke-MoveAbortCmd($S) {
  if ($S.serving -cne 'old') { Write-Host 'lỗi: abort chỉ chạy khi máy cũ đang phục vụ.'; return 1 }
  $a = Read-MoveAnswer (Get-MoveAbortText (Get-MoveTransient $S)) @('có', 'không')
  if ($a -cne 'có') { Write-Host 'Đã hủy, chưa làm gì.'; return 0 }
  Set-MoveAnswer $S 'Q-abort' 'có'
  $r = Invoke-MoveCall $S 'old' 'a.old'
  if ($r.Code -ne 0 -and -not ($r.Code -eq 65 -and @($r.Lines | Where-Object { $_ -cmatch '\AMOVE error no-move\b' }).Count)) { return (ConvertTo-MoveExit $r.Code) }
  if ($S.new_lost -ne $true -and -not $script:MoveNewDown) {   # new: best effort, skipped when unreachable (D.9, F2)
    $n = Invoke-MoveCall $S 'new' 'a.new'
    if ($n.Code -ne 0) { Write-Host "máy mới '$($S.new.alias)' không hủy được (mã $($n.Code)); bỏ qua." }
  }
  Remove-MovePin ([string]$S.new.addr)   # B.11.3: abort replaces the laptop's pin for --addr
  Set-MoveProp $S 'phase' 'aborted'; Save-MoveState $S
  Write-Host ('Đã hủy lần chuyển. ' + (Get-MoveText 'abort-text') + '.')
  $t = @(Get-MoveTransient $S); if ($t.Count) { Write-Host (Get-MoveText 'transient' @{ 'danh sách' = ($t -join ', ') }) }
  0
}

# ---- status (D.10) and rebuild (D.0.10): never the agreement check (L.status-no-init) ----
function Show-MoveStatus {
  $S = Read-MoveState
  if (-not $S) { Write-Host 'Chưa có lần chuyển nào. Bắt đầu bằng:  fcode move check  rồi  fcode move plan <máy mới> --addr <địa chỉ>'; return 0 }
  if ($S.rebuilt -eq $true) { Write-Host 'Trạng thái này được dựng lại từ hai máy (status --rebuild): kiểm tra trước khi chạy tiếp.' }
  Write-Host "Lần chuyển $($S.move_id): hướng $($S.dir), lần thử $($S.attempt), giai đoạn $($S.phase), đang phục vụ: máy $(if ($S.serving -ceq 'new') { 'mới' } else { 'cũ' })$(if ($S.mark) { ", đang $($S.mark)" })."
  Write-Host "  máy cũ '$($S.old.alias)' ($($S.old.addr)); máy mới '$($S.new.alias)' ($($S.new.addr)), khoá ed25519 $(Get-MoveFingerprint ([string]$S.new.hostkey_line))"
  $rc = 0
  foreach ($m in 'old', 'new') {
    Write-Host "máy $(if ($m -ceq 'old') { 'cũ' } else { 'mới' }):"
    $st = Get-MoveStatus $S $m -Quiet
    foreach ($l in $st.Lines) { if ("$l" -cmatch '\A(MOVE state|INV inbound) ') { Write-Host "  $l" } }
    if (-not $st.Ok) { Write-Host "  không đọc được trạng thái (mã $($st.Code))."; $rc = 1 }
  }
  $rc
}
# one machine's `rebuild read` (D.0.10; 2400 s, W1-T10-G3): @{ Mid; Recs; Hk; Mf; Target } or $null when there is no readable move-id
function Read-MoveRebuildFacts($Mach) {
  $r = Invoke-MoveScript $Mach (Get-MoveRebuildScript) @() (Get-MoveConst 'script_s') -Pin:(Test-MoveFirstContact $Mach.Addr) -Quiet
  $mid = @{}; $recs = @(); $hk = ''; $tg = $null; $tgi = $null; $tp = $null
  foreach ($l in $r.Lines) {
    if ("$l" -cmatch '\AMOVE moveid ') { $mid = ConvertFrom-MoveKv $l }
    elseif ("$l" -cmatch '\AMOVE hostkey (ssh-ed25519) ([A-Za-z0-9+/=]+)(?: .*)?\z') { $hk = "$($Matches[1]) $($Matches[2])" }
    elseif ("$l" -cmatch '\AMOVE record ') { $recs += , (ConvertFrom-MoveKv $l) }
    elseif ("$l" -cmatch '\AMOVE target (.+)\z') { try { $tg = ConvertFrom-Json $Matches[1] } catch { $tg = $null } }
    elseif ("$l" -cmatch '\AMOVE target-in (.+)\z') { try { $tgi = ConvertFrom-Json $Matches[1] } catch { $tgi = $null } }
    elseif ("$l" -cmatch '\AINV target platform=([01])\z') { $tp = [int]$Matches[1] }
  }
  if ($r.Code -in 124, 255, -1) { return @{ Down = $r.Code } }   # the transport lost: the caller says "không trả lời", never "không có move-id"
  if ($r.Code -ne 0 -or -not $mid['id']) { return $null }
  @{ Mid = $mid; Recs = $recs; Hk = $hk; Mf = (ConvertFrom-MoveManifestLine $r.Lines); Target = $tg; TargetIn = $tgi; Platform = $tp }
}
# D.0.10: a target object (new's target.json, or the `target` key of the c.init-new record's stdin) is usable when it has users[] {name, uid}, groups[] {name, gid}, subids[]
# {user, kind uid|gid, start, count}, addrs[] of strings and stop_budget_s >= 0 (the server's own validator refuses anything else), every name one name token (B.6.2.1)
function Test-MoveTargetObj($T) {
  if ($null -eq $T -or $T -isnot [pscustomobject]) { return $false }
  foreach ($k in 'users', 'groups', 'subids', 'addrs', 'stop_budget_s') { if (-not $T.PSObject.Properties[$k]) { return $false } }
  $tok = '\A[^\s\x00-\x1f\x7f]{1,256}\z'
  foreach ($u in @($T.users)) { if ($null -eq $u -or "$($u.name)" -cnotmatch $tok -or "$($u.uid)" -cnotmatch '\A[0-9]+\z') { return $false } }
  foreach ($g in @($T.groups)) { if ($null -eq $g -or "$($g.name)" -cnotmatch $tok -or "$($g.gid)" -cnotmatch '\A[0-9]+\z') { return $false } }
  foreach ($s in @($T.subids)) { if ($null -eq $s -or "$($s.user)" -cnotmatch $tok -or "$($s.kind)" -cnotin 'uid', 'gid' -or "$($s.start)" -cnotmatch '\A[0-9]+\z' -or "$($s.count)" -cnotmatch '\A[0-9]+\z') { return $false } }
  foreach ($a in @($T.addrs)) { if ($a -isnot [string] -or $a -cnotmatch '\A[A-Za-z0-9.:-]{1,253}\z') { return $false } }
  "$($T.stop_budget_s)" -cmatch '\A[0-9]+\z'
}
# D.0.10: what a rebuilt state restores (`from:<source>`) and what it leaves empty (`empty:<why>`); every New-MoveState property, every literal `Set-MoveProp $S '<k>'` /
# `Set-MoveAnswer $S '<k>'` key, every Set-MoveAsk key (literal, or `<prefix>:`) and the files the rebuild writes. L.rebuild-inventory checks it against the code; the rebuild's
# Set-MoveProp / Set-MoveAnswer calls are the only ones for the `from:` keys
$MoveRebuildInventory = [ordered]@{
  'move_id' = 'from:move-ids'; 'dir' = 'from:move-ids'; 'attempt' = 'from:move-ids'; 'phase' = 'from:records'; 'serving' = 'from:move-ids'; 'mark' = 'from:move-ids'
  'dst_started' = 'from:move-ids'; 'dst_started_at' = 'from:records'; 'carry' = 'from:move-ids'; 'enabled' = 'from:move-ids'
  'new_lost' = 'empty:a lost new leaves no record; the owner answers Q-newlost again'; 'new_discarded' = 'from:records'; 'chores_done' = 'from:move-ids'; 'rebuilt' = 'from:move-ids'
  'pass' = 'from:records'; 'dur' = 'from:records'; 'answers' = 'empty:the container of the answers{} keys listed below'
  'manifest_sha' = 'from:pins'; 'manifest_sha_prev' = 'from:pins'; 'gate_id' = 'empty:read again by the next 0c (E-G4)'
  'est' = 'empty:measured again by the next copy and cutover'; 'last_copy_at' = 'from:records'; 'old' = 'from:move-ids'; 'new' = 'from:move-ids'
  'legacy_known_hosts' = 'from:scan'; 'aliases' = 'from:move-ids'; 'sshpush_disabled' = 'empty:plan-time answer; a re-plan asks again'; 'window_s' = 'empty:measured by the next x.switch'
  'target_users' = 'from:target.json'; 'target_groups' = 'from:target.json'; 'target_subids' = 'from:target.json'; 'target_addrs' = 'from:target.json'; 'target_stop_budget_s' = 'from:target.json'
  'target_platform' = 'from:probe'; 'idmap' = 'from:manifest'; 'legacy_push' = 'from:scan'
  'Q-abort' = 'empty:asked again by every abort'; 'Q-back' = 'empty:asked again by every back'; 'Q-cut' = 'from:records'; 'Q-finish' = 'empty:asked again by every finish'
  'Q-guard' = 'empty:the question of a resume is asked again from the guards'' own output'; 'back-new-projects' = 'from:answers'; 'final-sent' = 'from:records'
  'health-baseline' = 'empty:recovered by replaying this attempt''s x.baseline (Get-MoveBaselineStdin)'; 'init-new-warn' = 'empty:printed again by c.init-new'
  'refresh-pending' = 'from:records'; 'transient-excluded' = 'empty:listed again by the next plan or x.check'; 'ufw-lockout' = 'empty:printed again by x.adopt'
  'Q-pm2save' = 'empty:plan-time answer, the in-run $asked table is the reader; a re-plan asks again'; 'Q-cert:' = 'empty:plan-time answer, the in-run $asked table is the reader; a re-plan asks again'
  'Q-direct:' = 'empty:plan-time answer, the in-run $asked table is the reader; a re-plan asks again'; 'Q-ownip' = 'empty:plan-time answer, the in-run $asked table is the reader; a re-plan asks again'
  'Q-port' = 'empty:plan-time answer, the in-run $asked table is the reader; a re-plan asks again'; 'Q-inbound' = 'empty:plan-time answer, the in-run $asked table is the reader; a re-plan asks again'
  'Q-sshd' = 'empty:plan-time answer, the in-run $asked table is the reader; a re-plan asks again'; 'Q-sshpush:' = 'empty:plan-time answer, the in-run $asked table is the reader; a re-plan asks again'
  'map.txt' = 'empty:kept when present (never rewritten by the rebuild); a lost map.txt falls back to the default map and x.check refuses or rolls back (D.0.10.1)'; 'manifest.json' = 'from:pins'; 'known_hosts' = 'from:move-ids'
}
function Invoke-MoveRebuild([string]$OldAlias, [string]$NewAlias) {
  if (-not (Test-MoveAlias $OldAlias) -or -not (Test-MoveAlias $NewAlias)) { Write-Host 'Cách dùng: fcode move status --rebuild <máy cũ> <máy mới>'; return 65 }
  $puo = Get-MovePlatformUser $OldAlias; $pun = Get-MovePlatformUser $NewAlias   # O1: the same config source as plan
  if ($null -eq $puo -or $null -eq $pun) { return 65 }
  $got = @{}
  foreach ($x in @(@('old', $OldAlias), @('new', $NewAlias))) {
    $i = Get-MoveSshInfo $x[1]; if (-not $i) { Write-Host "lỗi: ssh -G không đọc được '$($x[1])'."; return 1 }
    $g = Read-MoveRebuildFacts @{ Name = $x[0]; Alias = $x[1]; Addr = $i.HostName; HostName = '' }
    if ($g -and $g.Down) { return (Write-MoveNoAnswer $x[1] 'khi đọc lại trạng thái' $g.Down) }
    # F3 (D.0.7, D.0.10): after the step-11 swap the old alias reaches new; read old again through Reach-Old (its move-id's old_addr)
    if ($x[0] -ceq 'old' -and $g -and [string]$g.Mid['role'] -ceq 'new' -and (Test-MoveAddr ([string]$g.Mid['old_addr']))) {
      $oa = [string]$g.Mid['old_addr']
      $g = Read-MoveRebuildFacts @{ Name = 'old'; Alias = $x[1]; Addr = $oa; HostName = $oa }
      if ($g -and $g.Down) { return (Write-MoveNoAnswer $x[1] 'khi đọc lại trạng thái' $g.Down) }
    }
    if (-not $g) { Write-Host "lỗi: máy '$($x[1])' không có move-id đọc được."; return 1 }
    if ([string]$g.Mid['role'] -cne $x[0]) { Write-Host "lỗi: '$($x[1])' trả về move-id của máy $($g.Mid['role']), không phải máy $(if ($x[0] -ceq 'old') { 'cũ' } else { 'mới' }); không dựng lại, chưa ghi gì."; return 1 }
    $got[$x[0]] = $g
  }
  $o = $got['old']; $n = $got['new']
  if ($o.Mid['id'] -cne $n.Mid['id']) { Write-Host 'lỗi: hai máy thuộc hai lần chuyển khác nhau; không dựng lại được.'; return 1 }
  $mf = if ($o.Mf) { $o.Mf } else { $n.Mf }
  if (-not $mf) { Write-Host 'lỗi: không đọc được manifest đã ghim trên máy nào.'; return 1 }
  $S = New-MoveState $o.Mid['id'] ([pscustomobject][ordered]@{ alias = $OldAlias; addr = [string]$o.Mid['old_addr']; hostkey_line = $o.Hk; platform_user = $puo }) ([pscustomobject][ordered]@{ alias = $NewAlias; addr = [string]$o.Mid['new_addr']; hostkey_line = $n.Hk; platform_user = $pun })
  $att = 0; $dir = 'fwd'
  foreach ($k in $o, $n) { if ("$($k.Mid['attempt'])" -match '\A[0-9]+\z' -and [int]$k.Mid['attempt'] -ge $att) { $att = [int]$k.Mid['attempt']; $dir = [string]$k.Mid['dir'] } }
  # L2: both machines' pinned sha come from their `rebuild read` (`MOVE manifest sha=` = manifest.json.sha256, the pin); the src machine's wins (it
  # re-pins first, at x.check), and when the dst machine's pin differs (inside the x.check .. x.repin-on-dst window) its sha is manifest_sha_prev
  $sg = if ($dir -ceq 'back') { $n } else { $o }; $dg = if ($dir -ceq 'back') { $o } else { $n }
  if ($sg.Mf) { $mf = $sg.Mf }
  $shaPrev = if ($sg.Mf -and $dg.Mf -and $sg.Mf.Sha -cne $dg.Mf.Sha) { [string]$dg.Mf.Sha } else { '' }
  # DESIGN-GAP (T10-G4): mark and serving from the move-ids (D.0.10): the move-id of the machine with the latest record end wins (the other one may be stale);
  # part of the G4 reading. The phase (below) overrides serving where it fixes it.
  $lastEnd = { param($g) @($g.Recs | ForEach-Object { [string]$_['end'] } | Where-Object { $_ -and $_ -cne '-' } | Sort-Object) | Select-Object -Last 1 }
  $latest = if ([string](& $lastEnd $n) -gt [string](& $lastEnd $o)) { $n } else { $o }
  $serv = [string]$latest.Mid['serving']; if (-not $serv) { $serv = 'old' }
  $mark = [string]$latest.Mid['mark']
  # the phase: the highest completed x.* / r.* record of the attempt (D.0.10)
  $done = @{}
  foreach ($k in 'old', 'new') { foreach ($rr in $got[$k].Recs) { if ([string]$rr['rc'] -ceq '0') { $done[[string]$rr['id']] = $true } } }
  $p = "$dir-$att-"; $phase = 'planned'
  if (@($done.Keys | Where-Object { $_ -like "${p}c.adopt.*" }).Count) { $phase = 'copied' }
  # a return to old is a rollback (D.0.10.1): ANY r.start-src / r.unfreeze-src / r.health-src record of the attempt ON OLD, whatever its rc or state (done, failed, running,
  # interrupted: a killed r.start-src may already have started old's apps), with or without a done x.switch, means the return began (a plain rollback, Q-newlost and Q-discard all
  # send these calls to old; the fence's r.stop-dst on new is no return record). The state is then `rolling-back`, serving old, carry false, new fenced (new_discarded) and resumable
  # (`cutover` = rb-continue), and `rolled-back` only as the run's end test: r.start-src and r.unfreeze-src done AND r.health-src has an rc (report-only, E-R18: any rc). A return record and an x.switch of one attempt can only be "switch, then return" (a return ends the
  # attempt), so no time compare is needed. Without a return record: a done x.switch decides cut (back-done), else a done c.adopt.N is copied, else planned
  $retIds = @("${p}r.start-src", "${p}r.unfreeze-src", "${p}r.health-src")
  $retRecs = @($o.Recs | Where-Object { [string]$_['id'] -cin $retIds })
  $returning = [bool]$retRecs.Count
  if ($returning) {
    $serv = 'old'
    $rcOf = { param($step, [bool]$AnyRc) @($retRecs | Where-Object { [string]$_['id'] -ceq "$p$step" -and $(if ($AnyRc) { [string]$_['rc'] -cmatch '\A[0-9]+\z' } else { [string]$_['rc'] -ceq '0' }) }).Count }
    if ((& $rcOf 'r.start-src' $false) -and (& $rcOf 'r.unfreeze-src' $false) -and (& $rcOf 'r.health-src' $true)) { $phase = 'rolled-back'; $mark = '' } else { $mark = 'rolling-back' }
  } elseif ($done["${p}x.switch"]) { $phase = $(if ($dir -ceq 'back') { 'back-done' } else { 'cut' }) }
  # a finished move-id on BOTH machines closes the move; old finished alone (f.old ran, f.new failed or was lost) is a resumable finish: phase cut, new serving,
  # chores done and old enabled (finish needs both, I27), so `finish` skips old (Test-MoveSideFinished) and completes new
  $finishPending = $false
  if ([string]$o.Mid['state'] -ceq 'finished') { if ([string]$n.Mid['state'] -ceq 'finished') { $phase = 'finished' } else { $phase = 'cut'; $finishPending = $true } } elseif ([string]$o.Mid['state'] -ceq 'aborted') { $phase = 'aborted' }
  # DESIGN-GAP (T10-G4): a manual back's E-R19 end ran r.start-src / r.unfreeze-src on NEW (dir=back): that is phase cut with new serving, not a return to old
  if (-not $returning -and $dir -ceq 'back' -and $phase -cin 'planned', 'copied' -and @($got['new'].Recs | Where-Object { [string]$_['rc'] -ceq '0' -and ([string]$_['id'] -cin @("${p}r.start-src", "${p}r.unfreeze-src")) }).Count) { $phase = 'cut' }
  # E-R19 (D.8 step 5) sends exactly r.start-src and r.unfreeze-src to new (the abandon end too); a done r.stop-dst on new is the fence's and never counts
  # DESIGN-GAP (T10-G4): end states are laptop-only (never sent to the machines), so the move-ids may still carry the run's mark: an end phase fixes both
  if ($phase -ceq 'cut') { $serv = 'new'; $mark = '' } elseif ($phase -cin 'back-done', 'rolled-back', 'finished', 'aborted') { if ($phase -cne 'finished') { $serv = 'old' } else { $serv = 'new' }; $mark = '' }
  # D.0.10 (W1-T10-O2): for dir=back with a mark set and no end phase in the records, the phase is the latest move-id's `phase` (a manual
  # back sends --phase copied from x.freeze on; a carry-back keeps planned), and carry=true only when that phase is planned
  if ($dir -ceq 'back' -and $mark -and $phase -cin 'planned', 'copied' -and [string]$latest.Mid['phase'] -cin 'planned', 'copied') { $phase = [string]$latest.Mid['phase'] }
  # new_discarded: a return to old fences new (Q-newlost / Q-discard, and a plain rollback's r.stop-dst is then a replay); new_lost stays false (abort still sends a.new)
  foreach ($kv in @{ dir = $dir; attempt = $att; phase = $phase; serving = $serv; mark = $(if ($mark) { $mark } else { $null }); dst_started = ([string]$o.Mid['dst_started'] -ceq '1' -or [string]$n.Mid['dst_started'] -ceq '1'); enabled = $finishPending; chores_done = $finishPending; new_discarded = ($phase -ceq 'rolled-back' -or $mark -ceq 'rolling-back'); rebuilt = $true; manifest_sha = $mf.Sha; manifest_sha_prev = $shaPrev; carry = [bool]($dir -ceq 'back' -and $phase -ceq 'planned' -and $mark -and $mark -cne 'rolling-back') }.GetEnumerator()) { Set-MoveProp $S $kv.Key $kv.Value }
  # D.0.10 (W1-T10-F4, W1-T11-DG-R11-2): target_users[], target_groups[], target_subids[], target_addrs[] and target_stop_budget_s come from new's MV_DIR/target.json (`MOVE target`),
  # never from new's current users. When target.json is missing or unusable, the durable snapshot of the same key, the newest c.init-new record's stdin on new (`MOVE target-in`:
  # the init publishes the move-id before it writes target.json, so a kill between the two leaves none), is validated and used; when neither is usable the rebuild is REFUSED
  # (new holds a move-id, so c.init-new began): persisting empty target_* would drop same_users protection from the next plan
  $T = $n.Target
  if (-not (Test-MoveTargetObj $T)) { $T = $n.TargetIn }
  if (-not (Test-MoveTargetObj $T)) { Write-Host "lỗi: máy mới '$NewAlias' không còn danh sách tài khoản đích (target.json) và không đọc được bản ghi c.init-new; không dựng lại, chưa ghi gì. Chạy lại fcode move copy từ máy còn state, hoặc đặt lại máy mới rồi chuyển lại."; return 1 }
  Set-MoveProp $S 'target_users' @(@(Get-MoveProp $T 'users' @()) | Where-Object { $_ } | ForEach-Object { [pscustomobject][ordered]@{ name = [string]$_.name; uid = [int]$_.uid } })
  Set-MoveProp $S 'target_groups' @(@(Get-MoveProp $T 'groups' @()) | Where-Object { $_ } | ForEach-Object { [pscustomobject][ordered]@{ name = [string]$_.name; gid = [int]$_.gid } })
  Set-MoveProp $S 'target_subids' @(@(Get-MoveProp $T 'subids' @()) | Where-Object { $_ } | ForEach-Object { [pscustomobject][ordered]@{ user = [string]$_.user; kind = [string]$_.kind; start = [long]$_.start; count = [long]$_.count } })
  Set-MoveProp $S 'target_addrs' @(@(Get-MoveProp $T 'addrs' @()) | Where-Object { $_ } | ForEach-Object { [string]$_ })
  Set-MoveProp $S 'target_stop_budget_s' ([int](Get-MoveProp $T 'stop_budget_s' 0))
  Set-MoveProp $S 'target_platform' ([int]$n.Platform)   # D.0.10: the probe line of new's rebuild read (0 when missing)
  Set-MoveProp $S 'idmap' @(@(Get-MoveProp $mf.Obj 'idmap' @()) | Where-Object { $_ })   # D.0.10: idmap[] from the manifest
  # what a rebuilt state restores and what it leaves empty (and why) is listed in $MoveRebuildInventory (L.rebuild-inventory)
  # D.0.10: every value the server compares in an argv (K1, D.0.5; `--budget --mark --dst-started --phase --serving` are ignored, `--sha` is the pin) is restored from the
  # machines, never invented: dir, attempt (move-ids), --sha (pins), --call = <dir>-<attempt>-<step>[.N] with every counter N raised past the highest record of EITHER machine
  # (failed and interrupted records included, so a done record is never replayed for current data), --role/--repin/--check/--final/--guards/--enable/--baseline (fixed per step),
  # --seed = <move_id>-<attempt> (derived), --since = the recorded x.verify argv (below)
  foreach ($k in 'old', 'new') {
    foreach ($rr in $got[$k].Recs) {
      if ("$($rr['id'])" -cmatch '\A((?:fwd|back)-[0-9]+-.+)\.([0-9]+)\z') {
        $cur = [int](Get-MoveMapVal $S.pass $Matches[1] 0); if ([int]$Matches[2] -gt $cur) { Set-MoveMapVal $S.pass $Matches[1] ([int]$Matches[2]) }
      }
    }
  }
  # last_copy_at: the `--since` of this attempt's x.verify record (src's, else dst's), so a resumed x.verify re-sends exactly the recorded argument on both machines. Without one the
  # laptop's own write is recovered: it writes the field only in Invoke-MovePasses, just before that pass's c.transfer.N, and the same pass's c.verify.N carries it verbatim: new's
  # newest fwd-<n>-c.transfer.<N> record (by start) gives `start`, replaced by the `since=` of new's fwd-<n>-c.verify.<N> when it has one; none of them: empty
  $tsRx = '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z'
  $vs = @(foreach ($k in $(if ($dir -ceq 'back') { 'new', 'old' } else { 'old', 'new' })) { foreach ($rr in $got[$k].Recs) { if ("$($rr['id'])" -ceq "${p}x.verify" -and "$($rr['since'])" -cmatch $tsRx) { "$($rr['since'])" } } })
  $lc = ''
  if ($vs.Count) { $lc = $vs[0] }
  else {
    $tr = @($n.Recs | Where-Object { "$($_['id'])" -cmatch '\Afwd-[0-9]+-c\.transfer\.[0-9]+\z' -and (ConvertTo-MoveTime $_['start']) } | Sort-Object -Property { [string]$_['start'] } -Descending | Select-Object -First 1)
    if ($tr.Count) {
      $lc = [string]$tr[0]['start']
      if ("$($tr[0]['id'])" -cmatch '\Afwd-([0-9]+)-c\.transfer\.([0-9]+)\z') { $vid = "fwd-$($Matches[1])-c.verify.$($Matches[2])"; foreach ($rr in $n.Recs) { if ("$($rr['id'])" -ceq $vid -and "$($rr['since'])" -cmatch $tsRx) { $lc = "$($rr['since'])" } } }
    }
  }
  if ($lc) { Set-MoveProp $S 'last_copy_at' $lc }
  # final-sent (G35, E-R5 / E-R23): new holds this attempt's x.final record, whatever its rc
  if (@($n.Recs | Where-Object { "$($_['id'])" -ceq "${p}x.final" }).Count) { Set-MoveAnswer $S 'final-sent' "${p}x.final" }
  # refresh-pending (F13): a forward copy whose manifest pin is newer than every done c.adopt.<N> on new (the record's --sha) has not prepared new for it
  $rp = $false
  if ($dir -ceq 'fwd' -and $phase -ceq 'copied') { $rp = -not @($n.Recs | Where-Object { "$($_['id'])" -cmatch ('\A' + [regex]::Escape($p) + 'c\.adopt\.[0-9]+\z') -and "$($_['rc'])" -ceq '0' -and "$($_['sha'])" -ceq [string]$mf.Sha }).Count }
  Set-MoveAnswer $S 'refresh-pending' $rp
  # Q-back's list (B41): a rebuilt manual back keeps an empty one, so a project x.check lists stops the back as E-R19 (D.8.2)
  if ($dir -ceq 'back' -and $S.carry -ne $true) { Set-MoveAnswer $S 'back-new-projects' @() }
  $scan = Get-MovePushScan $S; if (-not $scan.Ok) { if (-not $script:MoveNoAnswerShown) { Write-Host 'lỗi: không quét lại được repo (D.0.10: legacy_push[] từ một lần quét mới); chưa ghi gì.' }; return 1 }
  Set-MoveProp $S 'legacy_push' @($scan.Legacy)
  $co = Get-MoveRebuiltCutOff $o.Recs; if ($co) { Set-MoveAnswer $S 'Q-cut' ([pscustomobject]@{ a = 'có'; ts = $co }) }   # R2-4 (T10-G36): step 11's since
  Set-MoveProp $S 'dst_started_at' (Get-MoveRebuiltDstStartedAt $S $n.Recs)   # R5-1
  # dur{}: the last record per step and machine (D.0.5)
  foreach ($k in 'old', 'new') {
    foreach ($rr in @($got[$k].Recs | Sort-Object { [string]$_['end'] })) {
      $a = ConvertTo-MoveTime $rr['start']; $b = ConvertTo-MoveTime $rr['end']
      if (-not $a -or -not $b -or "$($rr['id'])" -notmatch '\A(?:fwd|back)-[0-9]+-(.+)\z') { continue }
      $step = $Matches[1] -replace '\.[0-9]+\z', '.N'
      $obj = Get-MoveProp $S.dur $step; if ($null -eq $obj) { $obj = [pscustomobject]@{}; Set-MoveMapVal $S.dur $step $obj }
      Set-MoveProp $obj $k ([int][Math]::Max(0, ($b - $a).TotalSeconds))
    }
  }
  # back chores may remain after x.switch (back-done: aliases back to old), so both backups are restored from old_addr there too, not only while new serves
  Set-MoveProp $S.aliases 'laptop_backup' $(if ($serv -ceq 'new' -or $phase -ceq 'back-done') { [string]$S.old.addr } else { $null })   # rebuilt from the move-ids, never from the ssh config
  Set-MoveProp $S.aliases 'coder_backup' $(if ($serv -ceq 'new' -or $phase -ceq 'back-done') { [string]$S.old.addr } else { $null })
  foreach ($lp in @(Get-MoveProp $S 'legacy_push' @())) { Set-MoveMapVal $S.legacy_known_hosts ([string]$lp.repo) "$($S.old.addr) $($o.Hk)" }
  foreach ($k in 'old', 'new') {
    $m = if ($k -ceq 'old') { $S.old } else { $S.new }
    if ($m.hostkey_line -and -not (Get-MovePinnedKey $m.addr)) {
      $kf = Get-MoveKnownFile; $kt = if ([IO.File]::Exists($kf)) { [IO.File]::ReadAllText($kf) } else { '' }
      Write-PhienText $kf ($kt + $(if ($kt -and -not $kt.EndsWith("`n")) { "`n" }) + "$($m.addr) $($m.hostkey_line)" + "`n") (New-Object Text.ASCIIEncoding)   # every file write goes through Write-PhienText (fcode-phien r4)
    }
  }
  Save-MoveManifest $mf.Text
  Save-MoveState $S
  Write-Host "Đã dựng lại trạng thái từ hai máy ($($S.move_id), giai đoạn $phase). Xem lại bằng fcode move status trước khi chạy tiếp."
  0
}

# ---- the entry ----
function Invoke-MoveRun([string[]]$MoveArgs) {
  $a = @($MoveArgs); $verb = if ($a.Count) { [string]$a[0] } else { '' }
  $usage = { Write-Host 'Cách dùng: fcode move check | plan <máy mới> --addr <ipv4|tên> [--old-addr <host[:port]>] [--map <file>] | copy | cutover | finish | back | abort | status [--rebuild <máy cũ> <máy mới>]'; Write-Host '  Chi tiết: fcode help move' }
  if ($verb -cnotin 'check', 'plan', 'copy', 'cutover', 'finish', 'back', 'abort', 'status') { & $usage; return 65 }
  $script:MoveManifest = $null; $script:MoveSeen = @{}; $script:MovePub = $null; $script:MoveFenced = $false; $script:MoveDraft = $false
  $script:MoveWindowT0 = $null; $script:MoveCheckOnlyS = $null; $script:MoveSrcStopped = $false; $script:MoveBackNewOnly = @()
  if ($verb -ceq 'status') {
    if ($a.Count -eq 1) { try { return [int]@(Show-MoveStatus)[-1] } catch { Write-Host "lỗi: $($_.Exception.Message)"; return 1 } }
    if ($a.Count -eq 4 -and $a[1] -ceq '--rebuild') { $lock = Open-MoveLock; if (-not $lock) { Write-Host 'lỗi: đang có một lần fcode move khác chạy (move.lock).'; return 75 }; try { return [int]@(Invoke-MoveRebuild ([string]$a[2]) ([string]$a[3]))[-1] } finally { $lock.Dispose() } }
    & $usage; return 65
  }
  if ($verb -ceq 'check') { if ($a.Count -ne 1) { & $usage; return 65 }; return [int]@(Invoke-MoveCheckCmd)[-1] }
  $alias = ''; $addr = ''; $oaddr = ''; $map = ''
  if ($verb -ceq 'plan') {
    for ($i = 1; $i -lt $a.Count; $i++) {
      switch -CaseSensitive ([string]$a[$i]) {
        '--addr' { $addr = [string]$a[++$i] } '--old-addr' { $oaddr = [string]$a[++$i] } '--map' { $map = [string]$a[++$i] }
        default { if (-not $alias -and "$($a[$i])" -notmatch '\A-') { $alias = [string]$a[$i] } else { & $usage; return 65 } }
      }
    }
    if (-not $alias -or -not $addr) { & $usage; return 65 }
  } elseif ($a.Count -ne 1) { & $usage; return 65 }
  $lock = Open-MoveLock
  if (-not $lock) { Write-Host 'lỗi: đang có một lần fcode move khác chạy (move.lock); chờ nó xong rồi chạy lại.'; return 75 }
  try {
    if ($verb -ceq 'plan') { return [int]@(Invoke-MovePlanCmd $alias $addr $oaddr $map)[-1] }
    $S = Read-MoveState
    if (-not $S) { Write-Host 'Chưa có lần chuyển nào: chạy  fcode move plan <máy mới> --addr <địa chỉ>  trước.'; return 1 }
    if ($S.rebuilt -eq $true) { Write-Host "Trạng thái được dựng lại: giai đoạn $($S.phase), hướng $($S.dir), lần thử $($S.attempt)." }
    # D.11 order: (1) the K1 agreement check, (2) unknown outcomes by real state (inside each call), (3) the chore-0 pre-rule, (4) the row
    $c = Sync-MoveAgreement $S $verb; if ($c -ne 0) { return $c }
    $down = [bool]$script:MoveNewDown
    # D.5.3 / E-R4: new unreachable after dst_started in a fwd cutover in flight: no automatic action; Q-newlost. Not while a return to old is under way (`rolling-back`): then
    # `cutover` continues that return (rb-continue) instead of asking again
    if ($down -and $verb -ceq 'cutover' -and [string]$S.dir -ceq 'fwd' -and $S.mark -and [string]$S.mark -cne 'rolling-back' -and $S.dst_started -eq $true -and $S.carry -ne $true) { return [int]@(Invoke-MoveNewLost $S)[-1] }
    if ($down -and [string]$S.serving -ceq 'new') { return (Write-MoveNoAnswer ([string]$S.new.alias) 'khi đang phục vụ' $script:MoveNewDownCode) }
    $c = Invoke-MovePreRule $S; if ($c -ne 0) { return $c }
    $row = Resolve-MoveRow $verb $S
    if ($row.Do -ceq 'refuse') { Write-Host "lỗi: $($row.Msg)"; return 1 }
    if ($row.Do -ceq 'idem') { Write-Host "Lần chuyển này đã $($S.phase)."; return 0 }
    if ($down) {   # F2: only the rows that need nothing from new go on; none of them sends a call to new
      $ok = $row.Do -cin 'abort', 'rb-continue', 'carry-resume' -or ($row.Do -ceq 'cut-resume' -and [string]$S.dir -ceq 'fwd' -and $S.dst_started -ne $true)
      if (-not $ok) { return (Write-MoveNoAnswer ([string]$S.new.alias) "khi lệnh '$verb' cần máy mới" $script:MoveNewDownCode) }
    }
    $res = switch -CaseSensitive ($row.Do) {
      'copy-first' { $w = Wait-MoveRunning $S; if ($w -ne 0) { $w } else { Invoke-MoveCopyFull $S } }
      'copy-refresh' { $w = Wait-MoveRunning $S; if ($w -ne 0) { $w } else { Invoke-MoveCopyRefresh $S } }
      'copy-attempt' {
        $w = Set-MoveWriteAhead $S @{ attempt = [int]$S.attempt + 1; dir = 'fwd'; carry = $false; mark = $null; dst_started = $false; dst_started_at = $null }   # R5-3 clear
        if ($w -ne 0) { $w } else { Invoke-MoveCopyFull $S }
      }
      'back-precopy' { $r = Invoke-MoveCall $S 'new' 'c.transfer.N'; if ($r.Code -eq 0) { Set-MoveProp $S 'phase' 'copied'; Save-MoveState $S }; ConvertTo-MoveExit $r.Code }
      'cut-run' { Invoke-MoveCutRun $S }
      'cut-resume' { $w = Wait-MoveRunning $S -ExceptStep 'x.final'; if ($w -ne 0) { $w } else { Invoke-MoveCutResume $S } }
      'rb-continue' { $w = Wait-MoveRunning $S; if ($w -ne 0) { $w } else { Invoke-MoveRollback $S (New-MoveFail 'rb' 'lần quay lại đang dở') } }
      'carry-resume' { $w = Wait-MoveRunning $S; if ($w -ne 0) { $w } else { Invoke-MoveCarryBack $S -Resume } }
      'chores' { Invoke-MoveChores $S }
      'back-start' { Invoke-MoveBackStart $S }
      'back-run' { Invoke-MoveBackRun $S }
      'back-chores' { if ($S.chores_done -eq $true) { Write-Host 'Không còn việc nào.'; 0 } else { Invoke-MoveChores $S } }
      'finish' { Invoke-MoveFinishCmd $S }
      'abort' { Invoke-MoveAbortCmd $S }
      default { Write-Host "lỗi: việc '$($row.Do)' không biết."; 1 }
    }
    return [int]@($res)[-1]
  } catch {
    Write-Host "lỗi: $($_.Exception.Message)"
    return 1
  } finally { $lock.Dispose() }
}

# B24: the one exit of `fcode move`. MoveNoAnswer is set by five places — Invoke-MoveCall's -1 returns, Set-MoveNetLoss (a failed copy with
# why=net, B26), Invoke-MoveScript's 124/255/-1, ConvertTo-MoveExit, Write-MoveNoAnswer — and cleared only at the carry-back's start (D.5.2: that loss was resolved by new's status answer).
# A run that ends 1 with it set prints the re-run sentence last, once: bare here unless Write-MoveNoAnswer already printed it with its head.
# Never on 0, 10, 65, 70, 75.
function Invoke-Move([string[]]$MoveArgs) {
  $script:MoveNoAnswer = $false; $script:MoveNoAnswerShown = $false
  $c = [int]@(Invoke-MoveRun $MoveArgs)[-1]
  if ($c -eq 1 -and $script:MoveNoAnswer -and -not $script:MoveNoAnswerShown) { Write-Host (Get-MoveText 'rerun') }
  $c
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
  $noUrl = $false; $noQr = $false
  try {
    # in nguyen van ra man hinh, dong thoi doc xem server co noi la chua co publicUrl / chua cai qrencode khong
    Invoke-BoxScript $FcodePairSh @($dev) | ForEach-Object {
      $l = "$_"
      if ($l -match 'publicUrl') { $noUrl = $true }
      if ($l -match 'qrencode') { $noQr = $true }
      $l
    } | Out-Host
    $code = $LASTEXITCODE
  }
  catch { Write-IpaError 'không chạy được trên box.' $_.Exception.Message; return 1 }
  finally { $ErrorActionPreference = $old }
  if ($code -ne 0) {
    Write-Host 'lỗi: không tạo được mã ghép. Kiểm tra box đang bật, server FCode trên box đã được cập nhật để hiện mã QR chưa, hoặc publicUrl trong config.json không hợp lệ.'
    Write-Host "  (chi tiết: lệnh fcode-pair trên box thoát mã $code)"
    return 1
  }
  Write-Host ''
  if ($noUrl -or $noQr) {
    # khong co ma QR that su: dung noi "quet ma"
    $why = if ($noUrl) { 'trên box chưa đặt publicUrl trong config.json' } else { 'trên box chưa cài qrencode' }
    Write-Host "Chưa có mã QR: $why. Trên iPhone mới, mở link hoặc gõ địa chỉ máy chủ rồi nhập mã 6 số ở trên."
  }
  else { Write-Host 'Mở Camera trên iPhone mới, quét mã, rồi bấm Ghép trong app FCode.' }
  return 0
}

# --- Hai script bash chay tren box (nhung san de chi can 1 file fcode.ps1) ---
# fcode.sh: liet ke / chon / vao phien tmux.
# attach() in it ends with two tmux commands after the attach (kept out of the here-string: the script travels gzip+base64 on the ssh command line):
# - set-option -w window-size latest: the app sizes the window to the phone (window-size manual), so a laptop client would see only part of it.
#   "latest" makes the window follow this client now and on every later resize of the laptop terminal (resize-window -A would freeze it
#   at the attach-time size). The app sets its own size again (resize-window, manual) when the phone opens the session.
# - set-option mouse on, for this session only (the server's tmux default is off): the wheel scrolls the pane history in copy mode.
#   A pane the laptop leaves in copy mode would swallow the app's input, so the server quits any pane mode before it sends text or keys.
# Before the attach, attach() also sets two global tmux bindings (idempotent, every attach) and, when the laptop passed FCODE_CLIP_SOCK (a path, in the remote command) and LC_FCODE_CLIP_TOKEN (ssh SendEnv, never argv),
# writes $PC_CONFIG_DIR/clip/<client tty with / as _>.json (see the clipboard server functions below the script):
# - MouseDrag1Pane: a drag always starts a tmux selection (tmux's default hands it to the app when the app asked for the mouse); on release tmux
#   copies and writes the laptop clipboard with OSC 52 (set-clipboard external, Windows Terminal accepts it).
# - M-v (Alt+V): runs server.mjs --clip, which fetches the image on the laptop clipboard through the reverse unix socket and types its path into the session.
$FcodeSh = (@'
#!/bin/bash
# fcode (chay tren box): liet ke / chon / vao phien tmux. Dung: fcode.sh [--list | so | ten]
arg="${1:-}"
# ten goi (alias) cua project, laptop gui kem (aliases_b64 = base64 cua cac dong "ten<TAB>ten goi"): chi de HIEN THI; gia tri chon van la ten that. Khong eval.
declare -A alias_of=()
while IFS=$'\t' read -r k v || [ -n "$k" ]; do [ -n "$k" ] && alias_of["$k"]="$v"; done < <(printf '%s' "${aliases_b64:-}" | base64 -d 2>/dev/null)
pname() { if [ -n "${alias_of[$1]:-}" ]; then printf '%s (%s)' "${alias_of[$1]}" "$1"; else printf '%s' "$1"; fi; }
rows=(); names=()
while IFS= read -r l; do
  [ -n "$l" ] && rows+=("$l") && names+=("${l%%|*}")
done < <(tmux list-sessions -F '#{session_name}|#{session_attached}|#{@pc_project}|#{@pc_harness}' 2>/dev/null)
n=${#rows[@]}

show() { # in 1 dong cho phien thu $1 (chi so tu 0)
  local name att proj har out
  IFS='|' read -r name att proj har <<<"${rows[$1]}"
  out="$(printf '%3d) %s' $(($1 + 1)) "$name")"
  [ -n "$proj" ] && out+="  -  dự án: $(pname "$proj")"
  [ -n "$har" ] && out+="  -  harness: $har"
  [ "${att:-0}" != "0" ] && out+="  -  đang có người xem"
  echo "$out"
}
show_all() {
  local i
  if [ "$n" -eq 0 ]; then echo "Chưa có phiên nào trên box."; return; fi
  echo "Các phiên trên box:"; for ((i = 0; i < n; i++)); do show "$i"; done
}

resolve() { # $1 = so hoac ten (hoac dau ten) -> dat $sel
  local q="$1" ql="${1,,}" i matches=()
  sel=""
  if [[ "$q" =~ ^[0-9]+$ ]] && [ "${#q}" -le 6 ] && [ "$((10#$q))" -ge 1 ] && [ "$((10#$q))" -le "$n" ]; then
    sel="${names[$((10#$q - 1))]}"; return 0
  fi
  for i in "${!names[@]}"; do [ "${names[$i]}" = "$q" ] && { sel="$q"; return 0; }; done
  for i in "${!rows[@]}"; do   # đầu tên phiên, hoặc phiên gắn với project đó (@pc_project: tên phiên không luôn bắt đầu bằng tên project: my_app -> my-app-omp, phiên đã đổi tên)
    IFS='|' read -r n2 _ p2 _ <<<"${rows[$i]}"
    if [[ "${n2,,}" == "$ql"* ]] || { [ -n "$p2" ] && [ "${p2,,}" = "$ql" ]; }; then matches+=("$i"); fi
  done
  if [ "${#matches[@]}" -eq 1 ]; then sel="${names[${matches[0]}]}"; return 0; fi
  if [ "${#matches[@]}" -eq 0 ]; then
    echo "Không thấy phiên nào tên \"$q\"."; return 78   # 78 = không có phiên nào tên này (laptop chỉ thử hỏi tên gọi khi gặp mã này, không phải khi ssh đứt)
  else
    echo "Có nhiều phiên khớp \"$q\", gõ dài hơn hoặc dùng số:"
    for i in "${matches[@]}"; do show "$i"; done
  fi
  return 1
}

# clip_map: remember where the laptop clipboard server is reachable (remote unix socket + token) for THIS client tty; Alt+V (server.mjs --clip) reads it.
# The socket name is new for every ssh call (sshd never unlinks a -R socket when the session ends), so the old files are cleaned here: the one the previous
# mapping of this tty names, and this user's fcode-clip-*.sock older than a day that no mapping names (a live session keeps its socket).
clip_map() { # $1 = config dir
  local tt key f tmp old s
  tt=$(tty 2>/dev/null) || return 0
  key="${tt//\//_}"; f="$1/clip/$key.json"
  # the clip dir must be a real dir of ours before anything is read or removed through it (a symlink there could point the rm elsewhere)
  if [ -e "$1/clip" ] || [ -L "$1/clip" ]; then { [ -d "$1/clip" ] && [ ! -L "$1/clip" ] && [ -O "$1/clip" ]; } || return 0; fi
  if [ -f "$f" ] && [ ! -L "$f" ]; then
    old=$(sed -n 's/.*"sock": "\([^"]*\)".*/\1/p' "$f" 2>/dev/null)
    case "$old" in /tmp/fcode-clip-*.sock) case "${old#/tmp/}" in */*|*[!A-Za-z0-9._-]*) ;; *) rm -f -- "$old" 2>/dev/null ;; esac ;; esac
  fi
  find /tmp -maxdepth 1 -type s -name 'fcode-clip-*.sock' -user "$(id -u)" -mmin +1440 2>/dev/null | while IFS= read -r s; do
    grep -rqF -- "$s" "$1/clip" 2>/dev/null || rm -f -- "$s" 2>/dev/null
  done
  if [ -z "${FCODE_CLIP_SOCK:-}" ] || [ -z "${LC_FCODE_CLIP_TOKEN:-}" ]; then rm -f "$f" 2>/dev/null; return 0; fi
  case "$FCODE_CLIP_SOCK$LC_FCODE_CLIP_TOKEN" in *[!A-Za-z0-9/._-]*) return 0 ;; esac
  (
    umask 077
    mkdir -p "$1/clip" && chmod 700 "$1/clip" && [ -d "$1/clip" ] && [ ! -L "$1/clip" ] && [ -O "$1/clip" ] || exit 0   # a real dir of ours, never a symlink
    tmp=$(mktemp "$1/clip/.tmp.XXXXXX") || exit 0
    { printf '{"sock": "%s", "token": "%s"}\n' "$FCODE_CLIP_SOCK" "$LC_FCODE_CLIP_TOKEN" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$f"; } || rm -f "$tmp"
  ) 2>/dev/null
  return 0
}

attach() {
  echo "Thoát mà không tắt phiên: bấm Ctrl+B rồi D. Lăn chuột để cuộn, bấm q để về cuối; kéo chuột để bôi đen là chép luôn vào clipboard laptop; Alt+V dán ảnh từ clipboard laptop; Ctrl+V vẫn dán chữ"
  sleep 2
  case "${TERM:-}" in ""|dumb) export TERM=xterm-256color ;; esac
  # the laptop token arrives in LC_FCODE_CLIP_TOKEN (ssh SendEnv): write the mapping, then drop it from the environment so tmux and every pane never inherit it
  local cdir="${PC_CONFIG_DIR:-/data/home/.fcoding}" node srv=/data/home/fcoding/server.mjs
  clip_map "$cdir"
  unset LC_FCODE_CLIP_TOKEN
  # a drag always starts a tmux selection (default: handed to the app when the app asked for the mouse); release copies, tmux sends it to the laptop by OSC 52
  # Known trade-off: tmux's default MouseDown1Pane still sends the PRESS to an app that asked for the mouse, while the drag and release go to copy mode;
  # a TUI that started its own selection on that press resets on the next click.
  tmux bind-key -n MouseDrag1Pane if-shell -F '#{pane_in_mode}' 'send-keys -M' 'copy-mode -M' 2>/dev/null
  if ! grep -q -- "'--clip'" "$srv" 2>/dev/null; then
    # box not updated: its server.mjs does not know --clip and would start a server of its own under run-shell, so Alt+V never runs it
    tmux bind-key -n M-v display-message -d 5000 'Box chưa cập nhật: cd ~/fcode-src && git pull && bash install.sh' 2>/dev/null
  else
    node=$(command -v node) || node=""
    case "$cdir$node" in
      *"'"*|*"#"*) ;;   # a quote or # would break the tmux command string: no binding
      # client_tty / session_name change at run time: #{q:...} escapes them for the shell (never inside quotes; a renamed session may hold a quote)
      *) [ -n "$node" ] && tmux bind-key -n M-v run-shell -b "PC_CONFIG_DIR='$cdir' '$node' '$srv' --clip #{q:client_tty} #{q:session_name}" 2>/dev/null ;;
    esac
  fi
  exec tmux -u attach -t "=$1" \; set-option -w window-size latest \; set-option mouse on
}

# --- mo phien moi: dung fcode-new tren box (hop dong: --projects / --harnesses / <project> <harness>) ---
# Moi ten di qua mang bash co dau nhay kep, khong bao gio qua eval hay dong lenh.
export PATH="$HOME/.local/bin:$PATH"

fnew() { # chay fcode-new "$@": stdout vao $out; thong bao loi (stderr, tieng Viet) cua box hien thang tren man hinh
  out="$(fcode-new "$@" </dev/null)"
}

pick() { # $1 = tieu de, con lai = lua chon -> dat $picked. 0 = da chon, 1 = Enter (quay lai)
  local title="$1" i c; shift
  local opts=("$@")
  echo; echo "$title"
  for i in "${!opts[@]}"; do printf '%3d) %s\n' $((i + 1)) "$([ "${pick_proj:-}" = 1 ] && pname "${opts[$i]}" || printf '%s' "${opts[$i]}")"; done
  while true; do
    read -r -p "Chọn số (Enter để quay lại): " c || return 1
    [ -z "$c" ] && return 1
    if [[ "$c" =~ ^[0-9]{1,6}$ ]] && [ "$((10#$c))" -ge 1 ] && [ "$((10#$c))" -le "${#opts[@]}" ]; then
      picked="${opts[$((10#$c - 1))]}"; return 0
    fi
    echo "Số không hợp lệ, gõ lại."
  done
}

newflow() { # chon project, harness, tao phien -> dat $sel. 0 = xong, 1 = quay lai (Enter), 2 = loi
  local projs harns proj har
  if ! command -v fcode-new >/dev/null 2>&1; then
    echo "Box chưa có lệnh fcode-new nên chưa mở được phiên mới từ máy này. Hãy cập nhật box (trong thư mục fcoding chạy git pull rồi bash install.sh) rồi thử lại."
    return 2
  fi
  fnew --projects || return 2
  mapfile -t projs < <(grep -v '^$' <<<"$out")
  [ "${#projs[@]}" -gt 0 ] || { echo "Box chưa có project nào. Thêm project bằng: fcode add <chủ/repo>"; return 2; }
  pick_proj=1; pick "Chọn project:" "${projs[@]}" || { pick_proj=0; return 1; }; pick_proj=0; proj="$picked"
  fnew --harnesses || return 2
  mapfile -t harns < <(grep -v '^$' <<<"$out")
  [ "${#harns[@]}" -gt 0 ] || { echo "Lỗi: box không trả về danh sách harness."; return 2; }
  pick "Chọn harness:" "${harns[@]}" || return 1; har="$picked"
  echo "Đang mở phiên mới ($(pname "$proj"), $har)..."
  fnew "$proj" "$har" || return 2
  sel="$(printf '%s\n' "$out" | head -n 1)"
  if ! [[ "$sel" =~ ^[A-Za-z0-9._-]+$ ]]; then echo "Lỗi: box trả về tên phiên không hợp lệ."; return 2; fi
  return 0
}

if [ "$arg" = "--list" ]; then show_all; exit 0; fi
if [ "$arg" = "--new" ]; then
  newflow; rc=$?
  [ "$rc" -eq 0 ] && attach "$sel"
  [ "$rc" -eq 2 ] && exit 1
  exit 0
fi
if [ -n "$arg" ]; then resolve "$arg" || exit $?; attach "$sel"; fi

show_all
[ -t 0 ] || { [ "$n" -eq 0 ] && echo "Mở phiên mới bằng lệnh: fcode new"; exit 0; }
echo "  0) Mở phiên mới"; echo "  p) Đồng bộ phiên chat omp giữa laptop và box"
ask="Chọn số phiên, 0 để mở phiên mới, p để đồng bộ phiên chat omp (Enter để thoát): "
[ "$n" -eq 0 ] && ask="Gõ 0 để mở phiên mới, p để đồng bộ phiên chat omp (Enter để thoát): "
while true; do
  echo
  read -r -p "$ask" c || exit 0
  [ -z "$c" ] && exit 0
  if [ "$c" = p ]; then exit 77; fi
  if [ "$c" = 0 ]; then newflow && attach "$sel"; echo; show_all; echo "  0) Mở phiên mới"; echo "  p) Đồng bộ phiên chat omp giữa laptop và box"; continue; fi
  resolve "$c" && attach "$sel"
done
'@) -replace "`r`n", "`n"
# script gui len box cho cach vao phien: set -- '<tu>' va cac ten goi (chi ten that hop le, ky tu dieu khien / dinh dang thanh '?') dang base64, roi $FcodeSh
function Get-BareScript([string]$Arg) {
  $al = Get-ProjectAliases
  $rows = @(foreach ($k in @($al.Keys | Where-Object { $_ -match '\A[A-Za-z0-9._-]+\z' } | Sort-Object | Select-Object -First 100)) { $k + "`t" + ($al[$k] -replace '[\p{Cc}\p{Cf}]', '?') })
  $data = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rows -join "`n"))
  "set -- '$Arg'`naliases_b64='$data'`n" + $FcodeSh
}

# --- clipboard cua laptop cho Alt+V (anh): may chu nho tren 127.0.0.1 (tien trinh con), ssh -R noi o unix cua box toi no ---
# Box (server.mjs --clip) goi GET /image kem header X-Fcode-Token. Dung System.Windows.Forms.Clipboard nen tien trinh con chay -STA.
# Tra loi (HTTP/1.0, mot yeu cau mot ket noi): sai phuong thuc hay duong dan 404; thieu / sai token 403; khong co anh 204; PNG qua 10485760 byte 413;
# clipboard ban sau 3 lan thu 500; co anh 200 image/png. Moi ket noi co han 5 giay (doc dau yeu cau + tra loi); rieng than anh 200 (toi 10 MiB,
# chi gui cho ben co token) han la "5 giay khong tien trien": dong ho chay lai moi khoi 64 KiB, de duong mang cham van chay duoc. Qua han thi dong ket noi.
# Toc do (hop dong A4 muc 16-17): truoc khi nhan yeu cau dau tien tien trinh con nap WinForms / Drawing va ma hoa thu mot PNG 1x1 (khoi dong nguoi); luc ranh no
# ma hoa truoc anh moi tren clipboard va giu mot ban (xem Invoke-FcodeClipServe). Con chi DOC clipboard, khong bao gio ghi.
function New-FcodeHex([int]$Bytes) {
  $b = New-Object byte[] $Bytes
  $r = [Security.Cryptography.RandomNumberGenerator]::Create(); $r.GetBytes($b); $r.Dispose()
  -join ($b | ForEach-Object { $_.ToString('x2') })
}
# ten o unix tren box cho MOI lan goi ssh (ke ca chay lai khi ma 78): sshd khong bao gio go o -R khi phien ket thuc, dung lai ten cu thi -R sau bi tu choi
function New-FcodeClipSock { '/tmp/fcode-clip-' + (New-FcodeHex 8) + '.sock' }
# vong lap cua may chu: chay trong tien trinh CON (Start-FcodeClipServer gui NGUYEN van ban ham nay sang do), nen phai tu du, khong goi ham khac
# $StdinTask = viec doc stdin cua tien trinh con: xong (cha dong ong / bi giet) thi thoat, de khong mo coi
# $GetSeq = so thu tu clipboard (GetClipboardSequenceNumber, uint32; 0 / loi = khong biet); $ReadPng = doc clipboard: $null khi khong co anh, byte[] PNG khi co, nem loi khi clipboard ban.
# $ReadPng nhan mot doi so: $true = luc ranh (chi ma hoa truoc khi clipboard co dinh dang anh va KHONG co dinh dang chu nao: kiem tra bang ContainsImage / ContainsText, khong
# render; clipboard co ca chu (Excel, Office, RDP...) thi tra $null, chi ma hoa khi Alt+V hoi), $false = luc co yeu cau (luon ma hoa neu co anh).
# Hai ham do duoc truyen vao (tien trinh con dung ban that, test dung ban gia). $Dbg khac $null (chi test dat FCODE_CLIP_DEBUG=1): moi tra loi them dong X-Fcode-Debug.
# Ma hoa truoc: luc ranh (moi 250 ms) so thu tu doi va clipboard chi co anh thi ma hoa PNG ngay va giu DUNG MOT ban trong bo nho (so thu tu + byte; anh qua 10 MiB chi giu co "Big").
# GET /image doc lai so thu tu: bang ban giu thi tra byte da giu, khac (hoac chua co) thi ma hoa luc do roi giu. Khong co anh thi bo ban giu (204). Khong ghi dia.
function Invoke-FcodeClipServe {
  param([System.Net.Sockets.TcpListener]$Listener, [string]$Token, $StdinTask, [scriptblock]$GetSeq, [scriptblock]$ReadPng, $Dbg = $null)
  $ErrorActionPreference = 'Continue'
  $max = 10485760
  $limit = 5000
  $enc = [Text.Encoding]::ASCII
  $reasons = @{ 200 = 'OK'; 204 = 'No Content'; 403 = 'Forbidden'; 404 = 'Not Found'; 413 = 'Payload Too Large'; 500 = 'Internal Server Error' }
  $acc = $null
  $cache = $null; $polled = $null; $encodes = 0
  while ($true) {
    if ($StdinTask.IsCompleted) { break }
    $c = $null
    try {
      if (-not $acc) { $acc = $Listener.AcceptTcpClientAsync() }
      if (-not $acc.Wait(250)) {
        # ranh: ma hoa truoc neu clipboard doi (loi / ban thi bo qua, lan sau thu lai)
        try {
          $sq = & $GetSeq
          if ($sq) { $sq = [uint32]$sq } else { $sq = $null }
          if ($null -ne $sq -and $sq -ne $polled) {
            $pp = & $ReadPng $true
            if ($pp) { $encodes++ }
            $big = $false
            if ($pp -and $pp.Length -gt $max) { $big = $true; $pp = $null }
            if ($pp -or $big) { $cache = @{ Seq = $sq; Png = $pp; Big = $big } } else { $cache = $null }
            $polled = $sq
          }
        } catch { }
        continue
      }
      $c = $acc.Result; $acc = $null
    } catch { break }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
      $ns = $c.GetStream()
      $buf = New-Object byte[] 8192; $n = 0; $head = ''
      while ($n -lt 8192) {
        $left = $limit - [int]$sw.ElapsedMilliseconds
        if ($left -le 0) { throw 'deadline' }
        $rt = $ns.ReadAsync($buf, $n, 8192 - $n)
        if (-not $rt.Wait($left)) { throw 'deadline' }   # qua han: bo, finally dong ket noi
        $k = $rt.Result
        if ($k -le 0) { break }
        $n += $k
        $head = $enc.GetString($buf, 0, $n)
        if ($head.Contains("`r`n`r`n")) { break }
      }
      $code = 404; $type = $null; $body = $null
      $lines = $head -split "`r`n"
      if ($head.Contains("`r`n`r`n") -and $lines[0] -cmatch '\AGET /image HTTP/1\.[01]\z') {
        $tok = ''
        for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '\AX-Fcode-Token:[ \t]*(.*?)[ \t]*\z') { $tok = $Matches[1]; break } }
        if ($Token.Length -eq 0 -or $tok -cne $Token) { $code = 403 }
        else {
          # so thu tu doc TRUOC khi doc anh: clipboard doi giua chung thi ban giu mang so cu va lan sau bi coi la cu (khong bao gio tra anh cu)
          $sq = $null; try { $sq = & $GetSeq; if ($sq) { $sq = [uint32]$sq } else { $sq = $null } } catch { $sq = $null }
          $png = $null; $big = $false; $got = $false
          if ($null -ne $sq -and $cache -and $cache.Seq -eq $sq) { $png = $cache.Png; $big = $cache.Big; $got = $true }
          else {
            for ($t = 0; $t -lt 3 -and -not $got; $t++) {   # the clipboard can be busy for a moment (another program holds it)
              try { $png = & $ReadPng $false; $got = $true } catch { Start-Sleep -Milliseconds 150 }
            }
            if ($got) {
              if ($png) { $encodes++ }
              if ($png -and $png.Length -gt $max) { $big = $true; $png = $null }
              if ($png -or $big) { $cache = @{ Seq = $sq; Png = $png; Big = $big } } else { $cache = $null }
              if ($null -ne $sq) { $polled = $sq }
            }
          }
          if (-not $got) { $code = 500 }
          elseif ($big) { $code = 413 }
          elseif (-not $png) { $code = 204 }
          else { $code = 200; $type = 'image/png'; $body = $png }
        }
      }
      $h = "HTTP/1.0 $code $($reasons[$code])`r`n"
      if ($code -ne 204) { $len = 0; if ($body) { $len = $body.Length }; $h += "Content-Length: $len`r`n" }
      if ($type) { $h += "Content-Type: $type`r`n" }
      if ($Dbg) { $h += "X-Fcode-Debug: encodes=$encodes warm=$([int][bool]$Dbg.Warm)`r`n" }
      $h += "Connection: close`r`n`r`n"
      $parts = @(, $enc.GetBytes($h))
      if ($body) { $parts += , $body }
      foreach ($part in $parts) {
        $off = 0
        while ($off -lt $part.Length) {
          if ($code -eq 200) { $sw.Restart() }   # image body: 5 s per 64 KiB chunk (see the note above)
          $left = $limit - [int]$sw.ElapsedMilliseconds
          if ($left -le 0) { throw 'deadline' }
          $len = [Math]::Min(65536, $part.Length - $off)
          $wt = $ns.WriteAsync($part, $off, $len)
          if (-not $wt.Wait($left)) { throw 'deadline' }
          $off += $len
        }
      }
      $ns.Flush()
    } catch { }
    finally { try { $c.Close() } catch { } }
  }
}
# bat may chu clipboard trong tien trinh CON: powershell.exe -STA (System.Windows.Forms.Clipboard can STA) -EncodedCommand. Token di vao stdin cua con (khong len dong lenh),
# con in cong (do he dieu hanh chon, 127.0.0.1) o dong dau cua stdout. Tra $null khi khong bat duoc (khi do vao phien khong co -R, Alt+V bao laptop chua noi).
# Con tu thoat khi stdin dong (fcode bi giet); Stop-FcodeClipServer giet con ngay.
function Start-FcodeClipServer([string]$Shell = 'powershell.exe') {
  $p = $null
  try {
    $token = New-FcodeHex 16
    $script = "`$ProgressPreference = 'SilentlyContinue'; `$ErrorActionPreference = 'Stop'`n" +
      "function Invoke-FcodeClipServe {`n" + ${function:Invoke-FcodeClipServe}.ToString() + "`n}`n" + @'
$in = [Console]::OpenStandardInput()
$tb = New-Object Collections.Generic.List[byte]
while ($tb.Count -lt 128) { $x = $in.ReadByte(); if ($x -lt 0 -or $x -eq 10) { break }; $tb.Add([byte]$x) }
$token = [Text.Encoding]::ASCII.GetString($tb.ToArray()) -replace '[^0-9a-f]', ''
if ($token.Length -ne 32) { exit 1 }
$l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$l.Start()
[Console]::Out.WriteLine([string]$l.LocalEndpoint.Port); [Console]::Out.Flush()
# the port line comes first (the parent waits for it); a request that arrives during the warm-up waits in the listener's backlog until the loop starts, it never fails.
# warm-up: load WinForms / Drawing, JIT one PNG encode of a 1x1 bitmap, load the sequence-number P/Invoke and touch the clipboard read path once; a load that fails leaves the
# server up: the clipboard read then fails and every image request answers 500
$warm = $false
try {
  Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
  $wb = New-Object System.Drawing.Bitmap 1, 1
  try { $wm = New-Object IO.MemoryStream; $wb.Save($wm, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $wb.Dispose() }
  Add-Type -Namespace FcodeClip -Name Native -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();'
  [void][FcodeClip.Native]::GetClipboardSequenceNumber()
  try { [void][System.Windows.Forms.Clipboard]::ContainsImage() } catch { }
  $warm = $true
} catch { }
$getSeq = { [FcodeClip.Native]::GetClipboardSequenceNumber() }
$readPng = {   # $null: no image (or, with $Idle, not an image-only clipboard); byte[]: the PNG; throws when the clipboard is busy
  param([bool]$Idle)
  if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) { return }
  if ($Idle) {   # idle pre-encode: only an image-only clipboard (a screenshot); a text format next to the image means a source that renders on demand, so leave it to Alt+V
    foreach ($f in [Enum]::GetValues([System.Windows.Forms.TextDataFormat])) { if ([System.Windows.Forms.Clipboard]::ContainsText($f)) { return } }
  }
  $img = [System.Windows.Forms.Clipboard]::GetImage()
  if (-not $img) { return }
  try { $ms = New-Object IO.MemoryStream; $img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); , $ms.ToArray() } finally { $img.Dispose() }
}
$dbg = $null; if ($env:FCODE_CLIP_DEBUG -eq '1') { $dbg = @{ Warm = $warm } }   # tests only: a debug header (encode count, warm-up done) on every reply
$buf = New-Object byte[] 64
Invoke-FcodeClipServe $l $token ($in.ReadAsync($buf, 0, 64)) $getSeq $readPng $dbg
'@
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Shell
    $psi.Arguments = '-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    [void]$p.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)   # ong stderr khong bao gio day (con bi chan)
    $tb = [Text.Encoding]::ASCII.GetBytes($token + "`n")
    $si = $p.StandardInput.BaseStream; $si.Write($tb, 0, $tb.Length); $si.Flush()   # ghi byte tho; khi trang ma nhap cua console la 65001, Process.Start da ghi BOM vao ong truoc byte nay (server --clip bo ky tu khong phai hex)
    $rt = $p.StandardOutput.ReadLineAsync()
    $line = $null
    if ($rt.Wait(15000)) { $line = $rt.Result }
    if ($line -notmatch '\A[0-9]{1,5}\z' -or [int]$line -lt 1 -or [int]$line -gt 65535) { throw 'no port' }
    [pscustomobject]@{ Port = [int]$line; Token = $token; Proc = $p }
  } catch {
    try { if ($p -and -not $p.HasExited) { $p.Kill() } } catch { }
    try { if ($p) { $p.Dispose() } } catch { }
    $null
  }
}
# dong may chu (khi ssh tra ve, ke ca khi loi): Kill tien trinh con, cho toi da 2 giay
function Stop-FcodeClipServer($Srv) {
  if (-not $Srv -or -not $Srv.Proc) { return }
  $p = $Srv.Proc
  try { if (-not $p.HasExited) { $p.Kill() } } catch { }
  try { [void]$p.WaitForExit(2000) } catch { }
  try { $p.StandardInput.Close() } catch { }
  try { $p.Dispose() } catch { }
}

# fcode add chay script DA CAI tren box (box/fcode-add.sh, install.sh dat o /data/home/fcoding/fcode-add.sh): mot nguon duy nhat cho ca app va laptop.
# Dong ket qua dang "R <MA> [chi tiet]" do Invoke-Add dich ra tieng Viet. Thieu CLI fcode-add -> "R NO_SCRIPT" (box chua cap nhat: bash install.sh).
# CLI fcode-add tren box chay script da cai duoi chinh watchdog cua server (cung han: 600 giay, TERM, 30 giay sau KILL ca nhom), qua han -> ma 137.
$FcodeAddRun = (@'
export FCODE_ADD_SCRIPT FCODE_ADD_TIMEOUT_S FCODE_ADD_KILL_AFTER_S
f="$HOME/.local/bin/fcode-add"
[ -x "$f" ] || { echo "R NO_SCRIPT"; exit 3; }
exec "$f" "$@"
'@) -replace "`r`n", "`n"

# fcode-pair tren box (server worker them --qr). $1 = ten thiet bi (co the rong).
$FcodePairSh = (@'
name="${1:-}"
if [ -n "$name" ]; then exec fcode-pair "$name" --qr; else exec fcode-pair --qr; fi
'@) -replace "`r`n", "`n"

# fcode phien tren box: chuong trinh python (ssh chay no, yeu cau di qua stdin)
$PhienPy = (@'
#!/usr/bin/env python3
# fcode phien (chay tren box): doc / gui / nhan phien chat omp. Chi laptop goi lenh nay (qua ssh).
# Lenh: scan | hash | get | put. Dong 1 cua stdin la chinh chuong trinh nay (deflate + base64, do lenh nap doc); phan con lai la
# yeu cau (JSON) hoac luong tar; ket qua la dong "FCODE-JSON {...}" hoac luong tar sau dong "FCODE-TAR".
# Chi ghi trong ~/.omp/agent/sessions/<thu-muc-du-an>/ va ~/.omp/agent/blobs/. Khong bao gio xoa, khong doc noi dung tin nhan.
import hashlib, io, json, ntpath, os, posixpath, re, shutil, subprocess, sys, tarfile, tempfile, time, unicodedata

NOW = time.time()
BUSY = 30
KNOWN_VERSIONS = (3,)   # version cua dong header "session" ma chuong trinh nay hieu (cung danh sach voi laptop va server.mjs)
HOME = os.environ.get('HOME') or os.path.expanduser('~')
AGENT = os.environ.get('PI_CODING_AGENT_DIR') or os.path.join(HOME, '.omp', 'agent')
CFG = os.environ.get('FCODE_CFG') or '/data/home/.fcoding/config.json'
SESS = os.path.join(AGENT, 'sessions')
BLOBS = os.path.join(AGENT, 'blobs')
RX_SESSION = re.compile(rb'"type"\s*:\s*"session"')
RX_MESSAGE = re.compile(rb'"type"\s*:\s*"message"')
RX_BLOB = re.compile(rb'blob:sha256:([a-f0-9]{64})')
RX_BLOBNAME = re.compile(r'^([a-f0-9]{64})(?:\.[A-Za-z0-9][A-Za-z0-9._-]{0,31})?$')


def out_json(o):
    # bytes UTF-8 thang vao stdout (laptop doc UTF-8); sys.stdout.write di qua bang ma cua locale, locale khong phai UTF-8 thi tieng Viet thanh '?'
    sys.stdout.buffer.write(('FCODE-JSON ' + json.dumps(o, ensure_ascii=False) + '\n').encode('utf-8', 'replace'))
    sys.stdout.buffer.flush()


# ---- thu muc ma hoa cua omp (cung quy tac voi omp: tmp truoc, roi home, roi duong dan tuyet doi) ----
def style(p):
    return ntpath if re.match(r'^[A-Za-z]:[\\/]|^\\\\', p) else posixpath


def rel_under(base, p, m):
    b = m.normcase(m.normpath(base))
    q = m.normcase(m.normpath(p))
    if q == b:
        return ''
    pre = b if b.endswith(m.sep) else b + m.sep
    if q.startswith(pre):
        r = m.normpath(p)[len(pre):]
        return None if r.startswith('..') else r
    return None


def xn(pre, r):
    a = re.sub(r'[/\\:]', '-', r)
    if not a:
        return pre
    return pre + a if pre.endswith('-') else pre + '-' + a


def enc(path, home, tmp):
    m = style(path)
    o = m.normpath(path)
    t = rel_under(tmp, o, m) if style(tmp) is m else None
    h = rel_under(home, o, m) if style(home) is m else None
    if t is not None:
        return xn('-tmp', t)
    if h is not None:
        return xn('-', h)
    return '--' + re.sub(r'[/\\:]', '-', re.sub(r'^[/\\]', '', o)) + '--'


def project_enc(d):
    return enc(d, HOME, tempfile.gettempdir())


# ---- doc dau file ----
def header_span(path):
    # (bat dau, het) cua dong "session" trong 5 dong dau (het = ngay sau dau xuong dong), hoac None
    try:
        with open(path, 'rb') as f:
            buf = f.read(65536)
    except OSError:
        return None
    pos = 0
    for _ in range(5):
        i = buf.find(b'\n', pos)
        if i < 0:
            return None
        if RX_SESSION.search(buf[pos:i]):
            return pos, i + 1, buf[pos:i]
        pos = i + 1
    return None


def body_off(path):
    # vi tri ngay sau dong "session"; 0 neu khong co. Phan sau do chi noi them (append-only).
    s = header_span(path)
    return s[1] if s else 0


def header_version(path):
    # "version" cua header (so nguyen) hoac None neu thieu / khong doc duoc
    s = header_span(path)
    if not s:
        return None
    try:
        v = json.loads(s[2].decode('utf-8')).get('version')
    except Exception:
        return None
    return v if isinstance(v, int) and not isinstance(v, bool) else None


def omp_version():
    for exe in (os.path.join(HOME, '.local', 'bin', 'omp'), 'omp'):
        try:
            r = subprocess.run([exe, '--version'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
            m = re.search(r'\d+\.\d+\.\d+\S*', r.stdout.decode('utf-8', 'replace'))
            if m:
                return m.group(0)
        except Exception:
            pass
    return ''


def nonempty(path):
    try:
        with open(path, 'rb') as f:
            for line in f:
                if RX_MESSAGE.search(line):
                    return True
    except OSError:
        pass
    return False


def eff(path):
    n = os.path.getsize(path)
    return n - (body_off(path) if path.endswith('.jsonl') else 0)


def is_prefix(short, long_):
    # phan than (sau dong header) cua file ngan co phai la dau cua file dai
    so = body_off(short) if short.endswith('.jsonl') else 0
    lo = body_off(long_) if long_.endswith('.jsonl') else 0
    n = os.path.getsize(short) - so
    with open(short, 'rb') as a, open(long_, 'rb') as b:
        a.seek(so)
        b.seek(lo)
        left = n
        while left > 0:
            x = a.read(min(1 << 20, left))
            if not x or x != b.read(len(x)):
                return False
            left -= len(x)
    return True


def range_sha(path, length):
    off = body_off(path) if path.endswith('.jsonl') else 0
    if os.path.getsize(path) - off < length:
        return None
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        f.seek(off)
        left = length
        while left > 0:
            x = f.read(min(1 << 20, left))
            if not x:
                return None
            h.update(x)
            left -= len(x)
    return h.hexdigest()


def safe_rel(rel):
    # duong dan tuong doi an toan: khong tuyet doi, khong .., khong rong
    if not rel or rel.startswith('/') or rel.startswith('\\') or re.match(r'^[A-Za-z]:', rel):
        return None
    parts = rel.replace('\\', '/').split('/')
    if any(p in ('', '.', '..') for p in parts):
        return None
    return '/'.join(parts)


def safe_enc(e):
    return e if isinstance(e, str) and e and e not in ('.', '..') and not re.search(r'[/\\]', e) else None


# ---- ghi chu goc project (HANDOFF*.md, CLAUDE.md, ...): chi khi git KHONG theo doi file do ----
NOTE_RX = re.compile(r'^(?:HANDOFF[^/\\]*\.md|CLAUDE\.md|AGENTS\.md|WORKFLOW\.md|agent_state\.md|TASK\.md|CLAUDE\.local\.md)$')
NOTE_SPECS = [':(glob)HANDOFF*.md', 'CLAUDE.md', 'AGENTS.md', 'WORKFLOW.md', 'agent_state.md', 'TASK.md', 'CLAUDE.local.md']
PROJ_RX = re.compile(r'^[a-z0-9][a-z0-9._-]{0,63}$')


def git(d, *a, inp=None):
    try:   # LC_ALL=C: git's own messages stay English (shared_projects reads "not a git repository"); paths are bytes either way
        return subprocess.run(['git', '--no-optional-locks', '-C', d, '-c', 'core.quotepath=false'] + list(a), env=dict(os.environ, LC_ALL='C'),
                              input=inp, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    except Exception:
        return None


def file_sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for blk in iter(lambda: f.read(1 << 20), b''):
            h.update(blk)
    return h.hexdigest()


def index_names(d):
    # ten cac file ghi chu ma git DANG theo doi (ke ca file bi xoa khoi thu muc lam viec); None neu khong phai repo
    r = git(d, 'ls-files', '-z', '--', *NOTE_SPECS)
    if r is None or r.returncode != 0:
        return None
    return set(x for x in r.stdout.decode('utf-8', 'replace').split('\0') if NOTE_RX.match(x))


def upstream_names(d, strict=False):
    # ghi chu nam trong nhanh mac dinh cua origin (ban da fetch): git se mang file do toi, nen cung tinh la da theo doi
    # nhanh mac dinh: origin/HEAD, khong co thi origin/main, roi origin/master
    # strict (the holder check): a git that gives no answer at all (git() None: timeout, not started) is None, never "nothing upstream"; no ref or
    # rc != 0 stays an empty set (the laptop's Get-PhienUpstreamNotes: only a non-answer is a failure)
    r = git(d, 'symbolic-ref', '-q', 'refs/remotes/origin/HEAD')
    if r is None and strict:
        return None
    ref = r.stdout.decode('utf-8', 'replace').strip() if r is not None and r.returncode == 0 else ''
    for c in ('refs/remotes/origin/main', 'refs/remotes/origin/master'):
        if ref:
            break
        r = git(d, 'rev-parse', '-q', '--verify', c)
        if r is None and strict:
            return None
        if r is not None and r.returncode == 0:
            ref = c
    if not ref:
        return set()
    r = git(d, 'ls-tree', '-z', '--name-only', ref)
    if r is None and strict:
        return None
    if r is None or r.returncode != 0:
        return set()
    return set(x for x in r.stdout.decode('utf-8', 'replace').split('\0') if NOTE_RX.match(x))


def tracked_names(d, strict=False):
    t = index_names(d)
    u = None if t is None else upstream_names(d, strict)
    return None if u is None else t | u


def scan_notes(d):
    # fx = the exclude file has fcode's pair for that name (Rule O); no exclude path, or a file that cannot be read: gitok False
    # (no note work for this project this run, never "no line of ours"); no file = no pair
    no = {'gitok': False, 'tracked': [], 'upstream': [], 'files': []}
    t = index_names(d) if os.path.isdir(d) else None
    if t is None:
        return no
    p = exclude_path(d)
    if p is None:
        return no
    try:
        ext = read_exclude(p)
    except OSError:
        return no
    files = []
    for n in sorted(os.listdir(d)):
        p = os.path.join(d, n)
        if NOTE_RX.match(n) and os.path.isfile(p):
            st = os.stat(p)
            ig = git(d, 'check-ignore', '-q', '--', n)
            files.append({'name': n, 'size': st.st_size, 'mtime': st.st_mtime, 'sha': file_sha(p),
                          'ign': bool(ig and ig.returncode == 0), 'fx': bool(mark_rx(n).search(ext))})
    return {'gitok': True, 'tracked': sorted(t), 'upstream': sorted(upstream_names(d)), 'files': files}


def exclude_path(d):
    r = git(d, 'rev-parse', '--git-path', 'info/exclude')
    if r is None or r.returncode != 0:
        return None
    p = r.stdout.decode('utf-8', 'replace').strip()
    return p if os.path.isabs(p) else os.path.join(d, p)


# Rule O: a line of .git/info/exclude is fcode's when it is the pair "# fcode" + "/<ten>" (one atomic write). The file is handled as bytes,
# so every other byte and its newline (CRLF or LF) stay as they were
MARK = b'# fcode'


def mark_rx(name):
    return re.compile(rb'(?m)^' + re.escape(MARK) + rb'\r?\n/' + re.escape(name.encode('utf-8')) + rb'\r?(?:\n|\Z)')


def bare_rx(name):
    return re.compile(rb'(?m)^/' + re.escape(name.encode('utf-8')) + rb'\r?(?:\n|\Z)')


def read_exclude(p):
    try:
        with open(p, 'rb') as f:
            return f.read()
    except FileNotFoundError:
        return b''


def pid_gone(pid):
    # the PID of a part file no longer runs. The box is Linux; on Windows (the tests run this program there) os.kill(pid, 0) would END that process
    if os.name == 'nt':
        import ctypes
        k = ctypes.WinDLL('kernel32', use_last_error=True)
        h = k.OpenProcess(0x1000, False, pid)
        if not h:
            return ctypes.get_last_error() == 87
        c = ctypes.c_ulong()
        ok = k.GetExitCodeProcess(h, ctypes.byref(c))
        k.CloseHandle(h)
        return bool(ok) and c.value != 259
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except OSError:
        return False
    return False


def sweep_exclude_parts(p):
    # fcode's own leftovers beside the exclude file go: exactly <leaf>.fcode-part-<PID>-<6hex>, over 1 h old or of a PID that no longer runs
    d, leaf = os.path.split(p)
    rx = re.compile(re.escape(leaf) + r'\.fcode-part-([0-9]+)-[0-9a-f]{6}')
    try:
        names = os.listdir(d)
    except OSError:
        names = []
    for n in names:
        m = rx.fullmatch(n)
        q = os.path.join(d, n)
        try:
            if m and not os.path.islink(q) and (os.lstat(q).st_mtime < NOW - 3600 or pid_gone(int(m.group(1)))):
                os.unlink(q)
        except OSError:
            pass


def write_exclude(p, data):
    # the one way the box REWRITES .git/info/exclude (the release): a part file beside it, then os.replace (a kill leaves the old file or the new one)
    sweep_exclude_parts(p)
    part = part_name(p)
    try:
        with open(part, 'wb') as f:
            f.write(data)
        os.replace(part, p)
    finally:
        if os.path.exists(part):
            os.unlink(part)


def append_exclude(p, data):
    # the one way the box ADDS to .git/info/exclude: one O_APPEND write (the pair in one syscall). It composes with any other appender
    # (a 1.3.3 server.mjs adds "/.fcode/" the same way); a read-then-replace could drop a line appended in between. O_NOFOLLOW: a link is
    # never written through (is_link already said no). write(2) may write less than asked: that is a failure (no note), never a success
    sweep_exclude_parts(p)
    fd = os.open(p, os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_BINARY', 0), 0o644)
    try:
        if os.write(fd, data) != len(data):
            raise OSError('short write')
    finally:
        os.close(fd)


def is_link(p):
    # the exclude file or its folder is a link: fcode never writes through or over one (the laptop's rule)
    return os.path.islink(p) or os.path.islink(os.path.dirname(p))


def hide_uploads(d):
    # Rule H: the one rewrite of .git/info/exclude (a release) can drop a "/.fcode/" line a 1.3.3 server.mjs appends during it (on a project's
    # FIRST upload, before it makes .fcode). So the rewrite is allowed only once the uploads folder hides itself: .fcode/.gitignore holds exactly
    # "*\n", VERIFIED by reading it back. The folder is made when missing (the one the server makes for photos); the file is FCode's own and the
    # server keeps it at "*\n" too, so a regular file with any other content (an empty one included) is replaced through write_exclude (part file +
    # os.replace; its sweep removes stale ".gitignore.fcode-part-*" there, the server's own leftover name); a link at .fcode or .gitignore, or a
    # non-file there, is never followed or replaced. False = not verified: the caller does not rewrite, the release waits for the next run
    fc = os.path.join(d, '.fcode')
    f = os.path.join(fc, '.gitignore')

    def ok():
        return not os.path.islink(fc) and not os.path.islink(f) and os.path.isfile(f) and os.path.getsize(f) == 2 and read_exclude(f) == b'*\n'
    try:
        if os.path.islink(fc):
            return False
        os.makedirs(fc, mode=0o700, exist_ok=True)
        if os.path.islink(fc) or os.path.islink(f) or (os.path.lexists(f) and not os.path.isfile(f)):
            return False
        if not ok():
            write_exclude(f, b'*\n')
        return ok()
    except OSError:
        return False


def same_file(a, b):
    # the same file or folder, whatever the spelling (links, relative paths); a path that is gone is not the same as anything
    try:
        return os.path.samefile(a, b)
    except OSError:
        return False


def holds_note(x, name):
    # a holder candidate: a regular file <name> (not a link) at the project's root. The ONE test the holder check (pair_holders) and its
    # git-failure rule (shared_projects) share, the laptop's order: no file, no question to git, no error
    f = os.path.join(x, name)
    return os.path.isfile(f) and not os.path.islink(f)


def shared_projects(d, p, projs, name=None):
    # The folders a 1.3.3 server.mjs can append "/<prefix>.fcode/" to THIS exclude file for are exactly the config projects it uploads into:
    # a value of `projects` that is a string and an absolute path (1bc8703:server.mjs:196), an existing directory (:1847-1848), inside a work
    # tree (`rev-parse --is-inside-work-tree`, :1785-1787), whose `--git-path info/exclude` (the server's own question, :1785) is this file p.
    # Linked work trees, and projects that are sub-folders of one repository, share one file. Files are compared with os.path.samefile
    # (git prints a relative path from a sub-folder and an absolute one from a linked work tree; links and bind mounts resolve to one file).
    # Returns the folders other than d, or None when git does not answer for one of them (the caller waits). A bare repository, a plain
    # folder and a folder that is gone hold no uploads: skipped. `name` (unexclude, the holder check): a config project that holds a regular
    # `<name>` is a holder candidate; for it only git's own "not a git repository" skips the folder and any other failure (rc 128 "detected
    # dubious ownership", a bad config, a permission error) is None, the release is retried. A project without the file is skipped on any
    # rc != 0 as in 1.3.5 (Rule H: the same-uid 1.3.3 server gets the same failure and appends nothing)
    out = []
    for x in projs.values():
        if not (isinstance(x, str) and os.path.isabs(x) and os.path.isdir(x)) or same_file(x, d):
            continue
        r = git(x, 'rev-parse', '--is-inside-work-tree', '--git-path', 'info/exclude')
        if r is None:
            return None
        ls = r.stdout.decode('utf-8', 'replace').splitlines()
        if r.returncode != 0 and name and b'not a git repository' not in r.stderr and holds_note(x, name):
            return None
        if r.returncode != 0 or len(ls) < 2 or ls[0] != 'true':
            continue
        q = ls[1] if os.path.isabs(ls[1]) else os.path.join(x, ls[1])
        if same_file(q, p):
            out.append(x)
    return out


def hide_all_uploads(d, others):
    # the Rule H gate for the project d and for every other config project that shares its exclude file (shared_projects); False = one of them
    # could not be verified
    return all([hide_uploads(w) for w in [d] + others])


def pair_holders(others, name, releasing, p):
    # True = some other project on the shared exclude file still depends on fcode's line for <name>; False = none does; None = git could not tell
    # (tracked_names or check-ignore failed, or its answer is not the four NUL-separated fields): a failure, the caller reports it, nothing is removed.
    # A project depends on it when it holds a regular file <name> at its root that is tracked nowhere for it (index and origin default) and that
    # git hides through a "/<name>" line of info/exclude (check-ignore -v names the source; a .gitignore or global match is independent).
    # A project whose own release of this name is in the same batch (`releasing`) does not hold the line: its copy is given back anyway.
    # NB: with -v, check-ignore exits 0 also for a negated match ("!<name>"), whose pattern is not "/<name>": that copy is visible anyway
    # Every candidate is asked, a holder included: a git failure about any of them is None whatever its place in `others` (DECISION B)
    held = False
    for x in others:
        if any(same_file(x, r) for r in releasing):
            continue
        if not holds_note(x, name):
            continue
        t = tracked_names(x, True)   # strict: a git that does not answer is a failure here, never "not tracked"
        if t is None:
            return None
        if name in t:
            continue
        # -z: <source> NUL <line> NUL <pattern> NUL <path> NUL, never quoted (a path with a special character, a note name holding ':' parse the same)
        ig = git(x, 'check-ignore', '-v', '-z', '--stdin', inp=name.encode('utf-8') + b'\0')   # -z needs --stdin
        if ig is None or ig.returncode not in (0, 1):
            return None
        if ig.returncode == 1:
            continue
        fs = ig.stdout.split(b'\0')
        if len(fs) != 5 or fs[4] != b'':
            return None
        if fs[2] == b'/' + name.encode('utf-8') and same_file(os.path.join(x, os.fsdecode(fs[0])), p):
            held = True
    return held


def ensure_excluded(d, name):
    # the pair "# fcode" + "/<ten>" in .git/info/exclude (never .gitignore) when git does not ignore the file yet; an exact "/<ten>"
    # already there is the user's: nothing added, nothing claimed.
    # True = git ignores <name> now (asked again after the write); False = it could not be made so, or git still shows it (a `!<ten>` in a
    # .gitignore outranks info/exclude): nothing placed, tried again next run
    ig = git(d, 'check-ignore', '-q', '--', name)
    if ig is None or ig.returncode not in (0, 1):
        return False
    if ig.returncode == 0:
        return True
    p = exclude_path(d)
    if not p or is_link(p):
        return False
    os.makedirs(os.path.dirname(p), exist_ok=True)
    cur = read_exclude(p)
    line = b'/' + name.encode('utf-8')
    if line not in cur.splitlines():          # an exact "/<ten>" already there is the user's: nothing added, nothing claimed
        nl = b'\r\n' if b'\r\n' in cur else b'\n'
        append_exclude(p, (b'' if not cur or cur.endswith(b'\n') else nl) + MARK + nl + line + nl)
    ig = git(d, 'check-ignore', '-q', '--', name)   # git's own answer after the write: a line git does not honour places no note
    return bool(ig is not None and ig.returncode == 0)


def unexclude(d, name, legacy, projs=None, releasing=()):
    # give fcode's line back: the pair, or the bare "/<ten>" only when legacy (a line 1.3.2/1.3.3 added; the laptop kept its record).
    # True = no line of fcode's is there now (removed, or not there); False = git could not say where the file is, the file / its folder is a link, or .fcode/.gitignore could not be made to hold `*` in this project or in any other box project that shares this exclude file, or git did not answer for one of them (nothing written);
    # 'kept' = another project that shares this exclude file still depends on the line (pair_holders): nothing written, nothing forgotten; False also when
    # git could not tell whether one does (pair_holders None)
    p = exclude_path(d)
    if not p or is_link(p):
        return False
    if not os.path.exists(p):
        return True
    if projs is None:
        projs = cfg_projects()
    def cut():
        cur = read_exclude(p)
        new = mark_rx(name).sub(b'', cur)
        if new == cur and legacy:
            new = bare_rx(name).sub(b'', cur)
        return cur, new
    cur, new = cut()
    if new != cur:
        others = shared_projects(d, p, projs, name)
        if others is None:
            return False
        held = pair_holders(others, name, releasing, p)
        if held is None:   # git could not tell: a failure (the laptop prints the error line and tries again), never 'kept'
            return False
        if held:
            return 'kept'
        if not hide_all_uploads(d, others):   # Rule H: no rewrite unless the uploads folder of every project sharing this file is verified to hide itself
            return False
        cur, new = cut()   # the checks above take time and the file is shared: cut again from what is there now, never from the first read
        if new == cur:
            return True
        write_exclude(p, new)
    return True


def part_name(p):
    # ten tam rieng cho tung lan chay (hai lan chay cung luc khong dam len nhau)
    return '%s.fcode-part-%d-%s' % (p, os.getpid(), os.urandom(3).hex())


def note_dir(projs, pn):
    d = projs.get(pn) if isinstance(pn, str) and PROJ_RX.match(pn) else None
    return d if isinstance(d, str) and os.path.isdir(d) else None


def place_note(d, name, src, expect, sha=''):
    t = tracked_names(d)
    if t is None or name in t:
        return 'tracked'
    if sha and file_sha(src) != sha:
        return 'changed'
    dst = os.path.join(d, name)
    if os.path.exists(dst):
        if NOW - os.path.getmtime(dst) < BUSY:
            return 'busy'
        if file_sha(dst) != expect:
            return 'changed'
    elif expect:
        return 'changed'
    part = part_name(dst)
    try:
        shutil.copyfile(src, part)
        st = os.stat(src)
        os.utime(part, (st.st_atime, st.st_mtime))
        try:
            ok = ensure_excluded(d, name)   # the pair first, then the move (the laptop's order): a kill leaves at most an inert pair, never a visible unexcluded note
        except OSError:
            ok = False
        if not ok:
            return 'failed'
        os.replace(part, dst)
    finally:
        if os.path.exists(part):
            os.unlink(part)
    return 'ok'


# ---- scan ----
def refs_of(path, size):
    # blob:sha256:<hex> trong `size` byte dau cua file (dung phan da quet, khong doc qua)
    s = set()
    try:
        with open(path, 'rb') as f:
            left, tail = size, b''
            while left > 0:
                b = f.read(min(1 << 20, left))
                if not b:
                    break
                left -= len(b)
                buf = tail + b
                for m in RX_BLOB.finditer(buf):
                    s.add(m.group(1).decode())
                tail = buf[-75:]
    except OSError:
        pass
    return s


def dir_files(d, base):
    # cac file trong thu muc di kem <base>/ va blob ma cac .jsonl trong do nhac toi
    files, refs = [], set()
    sd = os.path.join(d, base)
    for root, _dirs, fs in os.walk(sd):
        for f in sorted(fs):
            if '.fcode-part' in f:
                continue
            fp = os.path.join(root, f)
            try:
                s2 = os.stat(fp)
            except OSError:
                continue
            j = f.endswith('.jsonl')
            files.append({'rel': base + '/' + os.path.relpath(fp, sd).replace(os.sep, '/'), 'size': s2.st_size, 'mtime': s2.st_mtime,
                          'off': body_off(fp) if j else 0, 'ver': header_version(fp) if j else None})
            if j:
                refs |= refs_of(fp, s2.st_size)
    return files, refs


def sid_of(n):
    return n[n.rfind('_') + 1:-6] if '_' in n else ''


def scan_dir(d):
    res = []
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return res
    tops = set(n[:-6] for n in names if n.endswith('.jsonl'))
    for n in names:
        p = os.path.join(d, n)
        if '.fcode-part' in n:
            continue
        if n.endswith('.jsonl') and os.path.isfile(p):
            st = os.stat(p)
            base = n[:-6]
            files, refs = dir_files(d, base)
            org = ''
            try:
                with open(os.path.join(d, base + '.fcode-origin'), encoding='utf-8') as f:
                    org = f.read(32).strip()
            except OSError:
                pass
            res.append({'name': n, 'id': sid_of(n), 'size': st.st_size, 'mtime': st.st_mtime, 'off': body_off(p), 'ver': header_version(p),
                        'ne': nonempty(p), 'files': files, 'origin': org, 'refs': sorted(refs | refs_of(p, st.st_size))})
        elif n not in tops and os.path.isdir(p):
            # thu muc di kem ma file .jsonl chua toi (lan truoc dung giua chung): chi la danh sach file da nhan, khong phai phien
            files, _r = dir_files(d, n)
            res.append({'name': n + '.jsonl', 'id': sid_of(n + '.jsonl'), 'orphan': True, 'size': 0, 'mtime': 0, 'off': 0, 'ver': None,
                        'ne': False, 'files': files, 'origin': '', 'refs': []})
    return res


def cfg_projects():
    try:
        with open(CFG, encoding='utf-8') as f:
            p = json.load(f).get('projects') or {}
        return p if isinstance(p, dict) else {}
    except Exception:
        return {}


def read_prefs(allp):
    # prefs.json canh config.json (ten goi + thu tu project do server FCode giu), doc theo luat long (lenient) cua GET /api/prefs cua server:
    # chi ten project co trong config, alias da NFC + trim, 1..30 ky tu, chi chu / dau / so / cach / . _ -, khong trung ten that cua project khac,
    # khong trung alias truoc do (project dung truoc trong config thang). Chi doc; thieu hay hong = rong. Kem ten that va repo cua tung project.
    names, seen = [], set()
    for k, d in cfg_projects().items():
        if k and isinstance(d, str) and os.path.isabs(d) and k.lower() not in seen:   # khoa chi khac hoa thuong lam hong ConvertFrom-Json o laptop
            seen.add(k.lower())
            names.append(k)
    out = {'order': [], 'aliases': {}, 'names': names, 'repos': dict((x['name'], x['repo']) for x in allp if x['repo'] and x['name'] in names)}
    try:
        with open(os.path.join(os.path.dirname(CFG), 'prefs.json'), encoding='utf-8') as f:
            p = json.load(f)
        if isinstance(p.get('order'), list):
            out['order'] = [n for i, n in enumerate(p['order']) if isinstance(n, str) and n in names and n not in p['order'][:i]]
        al = p.get('aliases')
        if isinstance(al, dict):
            used = {}
            for name in names:
                raw = al.get(name)
                if not isinstance(raw, str):
                    continue
                a = unicodedata.normalize('NFC', raw).strip()
                if not a or a == name or len(a) > 30 or not all(unicodedata.category(c)[0] in 'LMN' or c in ' ._-' for c in a):
                    continue
                key = a.lower()
                if key in used or any(n != name and n.lower() == key for n in names):
                    continue
                used[key] = name
                out['aliases'][name] = a
    except Exception:
        pass
    return out


def repo_key(u):
    # owner/name (chu thuong) cua mot URL GitHub o moi dang (https, git@github.com:, alias github-<ten>:); khong phai GitHub -> ''
    u = (u or '').strip().replace('\\', '/').rstrip('/')
    if u.lower().endswith('.git'):
        u = u[:-4]
    p = [x for x in re.split('[/:]', u) if x]
    return (p[-2] + '/' + p[-1]).lower() if 'github' in u.lower() and len(p) >= 2 else ''


def origin_of(d):
    r = git(d, 'remote', 'get-url', 'origin')
    return r.stdout.decode('utf-8', 'replace').strip() if r is not None and r.returncode == 0 else ''


def box_projects():
    # chi ten project va URL origin (khong in gi khac cua config.json)
    out = []
    for name, d in sorted(cfg_projects().items()):
        if isinstance(d, str) and d:
            o = origin_of(d) if os.path.isdir(d) else ''
            o = re.sub(r'^([a-z][a-z0-9+.-]*://)[^/@]*@', r'\1', o, flags=re.I)   # khong bao gio gui token / mat khau trong URL
            out.append({'name': name, 'dir': d, 'origin': o, 'repo': repo_key(o)})
    return out


def clean_old(dirs):
    # do lai cua lan chay bi cat ngang (ssh rot, box nghi), Rule L: only fcode's complete names, over 1 h old, never a link:
    # $TMPDIR/fcode-phien-<8 of [a-z0-9_]> (mkdtemp) owned by this user, <name>.fcode-part-<PID>-<6hex> in the session / blob dirs
    old = NOW - 3600
    tmp = tempfile.gettempdir()
    uid = os.getuid() if hasattr(os, 'getuid') else None
    try:
        names = os.listdir(tmp)
    except OSError:
        names = []
    for n in names:
        p = os.path.join(tmp, n)
        try:
            st = os.lstat(p)
            if not re.fullmatch(r'fcode-phien-[a-z0-9_]{8}', n) or st.st_mtime >= old or (uid is not None and st.st_uid != uid) or os.path.islink(p):
                continue
            if os.path.isdir(p):
                shutil.rmtree(p, ignore_errors=True)
            else:
                os.unlink(p)
        except OSError:
            pass
    for d in dirs:
        for root, _ds, fs in os.walk(d):
            for n in fs:
                p = os.path.join(root, n)
                try:
                    if re.search(r'\.fcode-part-[0-9]+-[0-9a-f]{6}\Z', n) and os.lstat(p).st_mtime < old and not os.path.islink(p):
                        os.unlink(p)
                except OSError:
                    pass


def cmd_scan(req):
    allp = box_projects()
    names, repos = set(req.get('projects', [])), set(req.get('repos', []))
    out = []
    for bp in allp:
        name, d = bp['name'], bp['dir']
        if name not in names and not (bp['repo'] and bp['repo'] in repos):
            continue
        e = project_enc(d)
        out.append({'name': name, 'dir': d, 'enc': e, 'repo': bp['repo'], 'sessions': scan_dir(os.path.join(SESS, e)), 'notes': scan_notes(d)})
    if req.get('clean'):
        clean_old([os.path.join(SESS, x['enc']) for x in out] + [BLOBS])
    try:
        blobs = sorted(n for n in os.listdir(BLOBS) if RX_BLOBNAME.match(n) and os.path.isfile(os.path.join(BLOBS, n)))
    except OSError:
        blobs = []
    out_json({'now': NOW, 'projects': out, 'blobs': blobs, 'blobsize': dict((n, os.path.getsize(os.path.join(BLOBS, n))) for n in blobs),
              'omp': omp_version(), 'all': [{'name': x['name'], 'repo': x['repo']} for x in allp], 'prefs': read_prefs(allp)})


def cmd_projects(_req):
    allp = box_projects()
    out_json({'projects': [{'name': x['name'], 'origin': x['origin'], 'repo': x['repo']} for x in allp], 'prefs': read_prefs(allp)})


def cmd_hash(req):
    res = {}
    for q in req.get('q', []):
        e = safe_enc(q.get('enc')); r = safe_rel(q.get('rel', '')); n = q.get('len')
        if not e or not r or not isinstance(n, int) or n < 0:
            continue
        p = os.path.join(SESS, e, *r.split('/'))
        if os.path.isfile(p):
            res['%s|%s|%d' % (e, r, n)] = range_sha(p, n)
    out_json({'h': res})


# ---- get: tar cua dung cac file laptop xin (mot dot <= 50 MB; laptop tu chon blob nao can) ----
def cmd_get(req):
    adds = []
    projs = cfg_projects()
    for it in req.get('notes', []):
        pn, name = it.get('project'), it.get('name')
        d = note_dir(projs, pn)
        if not d or not isinstance(name, str) or not NOTE_RX.match(name):
            continue
        p = os.path.join(d, name)
        t = tracked_names(d)
        if t is None or name in t or not os.path.isfile(p) or NOW - os.path.getmtime(p) < BUSY:
            continue
        adds.append((p, 'notes/' + pn + '/' + name, None))
    for it in req.get('files', []):
        e, r, planned = safe_enc(it.get('enc')), safe_rel(it.get('rel', '')), it.get('size')
        if not e or not r or not isinstance(planned, int):
            continue
        p = os.path.join(SESS, e, *r.split('/'))
        if not os.path.isfile(p) or NOW - os.path.getmtime(p) < BUSY:
            continue
        adds.append((p, 'sessions/' + e + '/' + r, planned))
    for n in req.get('blobs', []):
        if isinstance(n, str) and RX_BLOBNAME.match(n) and os.path.isfile(os.path.join(BLOBS, n)):
            adds.append((os.path.join(BLOBS, n), 'blobs/' + n, None))
    sys.stdout.buffer.write(b'FCODE-TAR\n')
    sys.stdout.buffer.flush()
    with tarfile.open(fileobj=sys.stdout.buffer, mode='w|') as t:
        for p, arc, planned in adds:
            info = t.gettarinfo(p, arcname=arc)
            if planned is not None:
                if info.size < planned:   # the file shrank since the scan: leave it for the next run
                    continue
                info.size = planned       # exactly what the 30 s rule let through, never what omp wrote meanwhile
            with open(p, 'rb') as f:
                t.addfile(info, f)


# ---- put: nhan tar tu laptop, dat vao dung cho theo luat chi-noi-them ----
OPEN = []


def held_open(p):
    # mot tien trinh cua user nay (omp trong tmux) dang mo file: /proc/<pid>/fd tro toi no (nhu busy() cua fcode-git-sync.sh).
    # Doc mot lan moi lan chay; khong co /proc (may khac Linux) thi khong biet duoc, coi nhu khong mo.
    if not OPEN:
        s = set()
        try:
            pids = os.listdir('/proc')
        except OSError:
            pids = []
        me = str(os.getpid())
        for pid in pids:
            if not pid.isdigit() or pid == me:
                continue
            fd = '/proc/' + pid + '/fd'
            try:
                fds = os.listdir(fd)
            except OSError:
                continue
            for x in fds:
                try:
                    s.add(os.readlink(fd + '/' + x))
                except OSError:
                    pass
        OPEN.append(s)
    return os.path.realpath(p) in OPEN[0]


def place_file(src, dst, after=None):
    if src.endswith('.jsonl') and header_version(src) not in KNOWN_VERSIONS:
        return 'skip'
    if not os.path.exists(dst):
        status = 'new'
    else:
        if NOW - os.path.getmtime(dst) < BUSY or held_open(dst):
            return 'busy'
        a, b = eff(dst), eff(src)
        if b == a:
            if after:   # file nhan bi mat o lan truoc: ghi lai khi file chinh da giong
                try:
                    after()
                except OSError:
                    pass
            return 'same'
        if b < a or not is_prefix(dst, src):
            return 'skip'
        status = 'replaced'
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    part = part_name(dst)
    try:
        shutil.copyfile(src, part)
        st = os.stat(src)
        os.utime(part, (st.st_atime, st.st_mtime))
        os.replace(part, dst)
        if after:   # file nhan (.fcode-origin) chi ghi khi file chinh da dat xong; loi ghi file nhan khong lam hong file chinh da dat
            try:
                after()
            except OSError:
                pass
    finally:
        if os.path.exists(part):
            os.unlink(part)
    return status


def cmd_put(_req):
    stage = tempfile.mkdtemp(prefix='fcode-phien-')
    try:
        if sys.stdin.buffer.peek(3)[:3] == b'\xef\xbb\xbf':   # PowerShell 5.1 can put a BOM in front of stdin
            sys.stdin.buffer.read(3)
        with tarfile.open(fileobj=sys.stdin.buffer, mode='r|') as t:
            for m in t:
                name = m.name[2:] if m.name.startswith('./') else m.name
                if name in ('', '.'):
                    continue
                if not (m.isfile() or m.isdir()) or not safe_rel(name):
                    continue
                m.name = name
                try:
                    t.extract(m, stage, filter='data')
                except TypeError:
                    t.extract(m, stage)
        with open(os.path.join(stage, 'manifest.json'), encoding='utf-8') as f:
            man = json.load(f)
        # thu tu dat: blob, file trong thu muc di kem, .jsonl long ben trong, file origin, va file .jsonl chinh SAU CUNG
        # (chi khi moi file no can da co du tren box), nen mot phien khong bao gio trong nhu da du khi con thieu
        cnt = {'new': 0, 'replaced': 0, 'same': 0, 'skip': 0, 'busy': 0, 'blobs': 0, 'failed': 0}
        busyf, defer = [], []
        bs = os.path.join(stage, 'blobs')
        if os.path.isdir(bs):
            for n in sorted(os.listdir(bs)):
                if RX_BLOBNAME.match(n) and not os.path.exists(os.path.join(BLOBS, n)):
                    tmp = part_name(os.path.join(BLOBS, '.' + n))
                    try:
                        os.makedirs(BLOBS, exist_ok=True)
                        shutil.copyfile(os.path.join(bs, n), tmp)
                        st = os.stat(os.path.join(bs, n))
                        os.utime(tmp, (st.st_atime, st.st_mtime))
                        os.replace(tmp, os.path.join(BLOBS, n))
                        cnt['blobs'] += 1
                    except OSError:
                        cnt['failed'] += 1
                        if os.path.isfile(tmp):
                            os.unlink(tmp)

        def put1(e, r, before=None):
            src = os.path.join(stage, 'sessions', e, *r.split('/'))
            if not os.path.isfile(src):
                return
            try:
                st = place_file(src, os.path.join(SESS, e, *r.split('/')), before)
            except OSError:
                st = 'failed'
            cnt[st] += 1
            if st == 'busy':
                busyf.append(r)
        fl = []
        for it in man.get('files', []):
            e, r = safe_enc(it.get('enc')), safe_rel(it.get('rel', ''))
            if e and r:
                fl.append((r.endswith('.jsonl'), e, r))
        for _j, e, r in sorted(fl, key=lambda x: x[0]):
            put1(e, r)
        try:
            have = set(m.group(1) for m in (RX_BLOBNAME.match(n) for n in os.listdir(BLOBS)) if m and os.path.isfile(os.path.join(BLOBS, m.group(0))))
        except OSError:
            have = set()
        for t in man.get('tops', []):
            e, r = safe_enc(t.get('enc')), safe_rel(t.get('rel', ''))
            if not e or not r:
                continue
            dest = os.path.join(SESS, e)
            ok = all(h in have for h in t.get('blobs') or [])
            for d in t.get('deps') or []:
                dr, dn = safe_rel(d.get('r', '')), d.get('n')
                p = os.path.join(dest, *dr.split('/')) if dr else ''
                if not dr or not isinstance(dn, int) or not os.path.isfile(p) or eff(p) < dn:
                    ok = False
                    break
            if not ok:
                defer.append(r)
                continue

            def side(dest=dest, r=r):
                sp = os.path.join(dest, r[:-6] + '.fcode-origin')
                if not os.path.isfile(sp):
                    with open(sp, 'w', encoding='utf-8') as f:
                        f.write('laptop\n')
            put1(e, r, side if t.get('origin') == 'laptop' else None)
        cnt['busyFiles'] = busyf
        cnt['deferred'] = defer
        projs = cfg_projects()
        placed = []
        for it in man.get('notes', []):
            pn, name = it.get('project'), it.get('name')
            d = note_dir(projs, pn)
            if not d or not isinstance(name, str) or not NOTE_RX.match(name):
                continue
            src = os.path.join(stage, 'notes', pn, name)
            if os.path.isfile(src) and place_note(d, name, src, it.get('expect') or '', it.get('sha') or '') == 'ok':
                placed.append(pn + '/' + name)
        for it in man.get('ensure', []):
            pn, name = it.get('project'), it.get('name')
            d = note_dir(projs, pn)
            t = tracked_names(d) if d else None
            if d and t is not None and isinstance(name, str) and NOTE_RX.match(name) and name not in t and os.path.isfile(os.path.join(d, name)):
                try:
                    ensure_excluded(d, name)
                except OSError:
                    pass   # False, like place_note: the pair is not there, nothing else fails; the next run tries again
        unexcl, kept, rel = [], [], {}
        for it in man.get('unexclude', []):   # every release of this run rides this one batch: a project releasing its own copy holds nothing for the others
            pn, name = it.get('project'), it.get('name')
            d = note_dir(projs, pn)
            if d and isinstance(name, str) and NOTE_RX.match(name):
                rel.setdefault(name, []).append(d)
        for it in man.get('unexclude', []):
            pn, name = it.get('project'), it.get('name')
            d = note_dir(projs, pn)   # the other side tracks the name now; the laptop asks only when the scan saw fcode's pair here (or a 1.3.2/1.3.3 record: legacy)
            try:
                gone = d and isinstance(name, str) and NOTE_RX.match(name) and unexclude(d, name, bool(it.get('legacy')), projs, rel.get(name, []))
            except OSError:
                gone = False
            if gone is True:
                unexcl.append(pn + '/' + name)
            elif gone == 'kept':
                kept.append(pn + '/' + name)
        cnt['notePlaced'] = placed
        cnt['unexcluded'] = unexcl
        cnt['noteKept'] = kept
        out_json(cnt)
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def main():
    cmd = sys.argv[-1] if len(sys.argv) > 1 else ''
    req = {}
    if cmd in ('scan', 'hash', 'get'):
        raw = sys.stdin.buffer.read()
        if raw.startswith(b'\xef\xbb\xbf'):   # PowerShell 5.1 can put a BOM in front of stdin
            raw = raw[3:]
        req = json.loads(raw.decode('utf-8')) if raw.strip() else {}
    fn = {'scan': cmd_scan, 'hash': cmd_hash, 'get': cmd_get, 'put': cmd_put, 'projects': cmd_projects}.get(cmd)
    if not fn:
        sys.stderr.write('lenh khong hop le\n')
        return 2
    fn(req)
    return 0


if __name__ == '__main__':
    sys.exit(main())
'@) -replace "`r`n", "`n"

# --- fcode phien: dong bo phien chat omp giua laptop va box (laptop luon la ben goi; box khong the goi laptop) ---
# Luat (mot phien = mot ma = mot file .jsonl chi noi them): chi o mot ben -> chep sang ben kia; o ca hai ben va mot ben la phan dau
# cua ben kia (sau dong header "session") -> chep ban dai de len ban ngan; khac nhau -> khong dong vao, chi bao. Khong bao gio xoa gi.
# Ben tren box la mot chuong trinh python nho ($PhienPy, chay qua ssh); yeu cau di qua stdin, khong qua dong lenh.
$PhienBusySec = 30
$FcodeScript = $PSCommandPath
$PhienLog = Join-Path $env:USERPROFILE '.fcode\phien.log'

function Test-WinPath([string]$p) { $p -match '^[A-Za-z]:[\\/]|^\\\\' }

# duong dan chuan hoa nhu path.resolve cua node (khong dung thu muc hien tai)
function Resolve-OmpPath([string]$p) {
  if (Test-WinPath $p) {
    $r = [IO.Path]::GetFullPath(($p -replace '/', '\'))
    if ($r.Length -gt 3) { $r = $r.TrimEnd('\') }
    return $r
  }
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($s in ($p -split '/+')) {
    if ($s -eq '' -or $s -eq '.') { continue }
    if ($s -eq '..') { if ($out.Count -gt 0) { $out.RemoveAt($out.Count - 1) } } else { $out.Add($s) }
  }
  '/' + ($out -join '/')
}

# phan con lai cua $Path duoi $Base ('' neu bang nhau), $null neu khong nam duoi. Windows: khong phan biet hoa thuong.
function Get-OmpUnder([string]$Base, [string]$Path, [bool]$Win) {
  $sep = if ($Win) { '\' } else { '/' }
  $cmp = if ($Win) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
  if ([string]::Equals($Base, $Path, $cmp)) { return '' }
  $pre = if ($Base.EndsWith($sep)) { $Base } else { $Base + $sep }
  if ($Path.StartsWith($pre, $cmp)) {
    $r = $Path.Substring($pre.Length)
    if ($r.StartsWith('..')) { return $null }
    return $r
  }
  $null
}

function Join-OmpName([string]$Prefix, [string]$Rel) {
  $a = $Rel -replace '[/\\:]', '-'
  if (-not $a) { return $Prefix }
  if ($Prefix.EndsWith('-')) { $Prefix + $a } else { $Prefix + '-' + $a }
}

# ten thu muc phien cua omp cho mot project: duoi tmp -> "-tmp-..", duoi home -> "-..", con lai "--duong-dan--"
function Get-OmpEncodedDir([string]$Path, [string]$HomeDir, [string]$TmpDir) {
  $win = Test-WinPath $Path
  $o = Resolve-OmpPath $Path
  $t = $null; $h = $null
  if ($TmpDir -and ((Test-WinPath $TmpDir) -eq $win)) { $t = Get-OmpUnder (Resolve-OmpPath $TmpDir) $o $win }
  if ($HomeDir -and ((Test-WinPath $HomeDir) -eq $win)) { $h = Get-OmpUnder (Resolve-OmpPath $HomeDir) $o $win }
  if ($null -ne $t) { return (Join-OmpName '-tmp' $t) }
  if ($null -ne $h) { return (Join-OmpName '-' $h) }
  '--' + (($o -replace '^[/\\]', '') -replace '[/\\:]', '-') + '--'
}

function Get-OmpAgentDir { if ($env:PI_CODING_AGENT_DIR) { $env:PI_CODING_AGENT_DIR } else { Join-Path $env:USERPROFILE '.omp\agent' } }
function Get-LaptopEncodedDir([string]$Dir) { Get-OmpEncodedDir $Dir $env:USERPROFILE ([IO.Path]::GetTempPath().TrimEnd('\', '/')) }

function ConvertTo-Epoch([datetime]$d) { ($d.ToUniversalTime() - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalSeconds }

# cwd cua mot header sau khi doi goc $From -> $To; $null neu khong nam duoi $From
function Convert-OmpCwd([string]$Cwd, [string]$From, [string]$To) {
  $fw = Test-WinPath $From
  if ((Test-WinPath $Cwd) -ne $fw) { return $null }
  $rel = Get-OmpUnder (Resolve-OmpPath $From) (Resolve-OmpPath $Cwd) $fw
  if ($null -eq $rel) { return $null }
  if ($rel -eq '') { return $To }
  $tsep = if ($To.Contains('/') -and -not $To.Contains('\')) { '/' } elseif (Test-WinPath $To) { '\' } else { '/' }
  $To.TrimEnd('\', '/') + $tsep + $rel.Replace('\', $tsep).Replace('/', $tsep)
}

function ConvertTo-JsonStr([string]$s) {
  $sb = New-Object Text.StringBuilder
  [void]$sb.Append('"')
  foreach ($c in $s.ToCharArray()) {
    if ($c -ceq [char]'"') { [void]$sb.Append('\"') }
    elseif ($c -ceq [char]'\') { [void]$sb.Append('\\') }
    elseif ([int]$c -lt 32) { [void]$sb.Append(('\u{0:x4}' -f [int]$c)) }
    else { [void]$sb.Append($c) }
  }
  [void]$sb.Append('"')
  $sb.ToString()
}



# dong "session" (trong 5 dong dau): @{Start; End} (End = ngay sau dau xuong dong), hoac $null
function Get-OmpHeaderSpan([byte[]]$Buf) {
  $rx = [regex]'"type"\s*:\s*"session"'
  $pos = 0
  for ($k = 0; $k -lt 5; $k++) {
    $i = [Array]::IndexOf($Buf, [byte]10, $pos)
    if ($i -lt 0) { return $null }
    if ($rx.IsMatch([Text.Encoding]::GetEncoding(28591).GetString($Buf, $pos, $i - $pos))) { return @{ Start = $pos; End = $i + 1 } }
    $pos = $i + 1
  }
  $null
}

function Open-ShareRead([string]$Path) { New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite,Delete') }

function Read-Head($fs, [int]$Max) {
  $n = [int][Math]::Min($fs.Length - $fs.Position, $Max)
  $b = New-Object byte[] $n; $g = 0
  while ($g -lt $n) { $r = $fs.Read($b, $g, $n - $g); if ($r -le 0) { break }; $g += $r }
  if ($g -lt $n) { $b2 = New-Object byte[] $g; [Array]::Copy($b, $b2, $g); $b = $b2 }
  , $b
}

# vi tri bat dau phan than (sau dong header; 0 neu khong co) va "version" cua header (so nguyen, $null neu thieu / khong doc duoc)
function Get-OmpHeaderInfo([string]$Path) {
  $fs = Open-ShareRead $Path
  try { $buf = Read-Head $fs 65536 } finally { $fs.Dispose() }
  $sp = Get-OmpHeaderSpan $buf
  if (-not $sp) { return [pscustomobject]@{ Off = 0; Ver = $null } }
  $ver = $null
  try {
    $o = [Text.Encoding]::UTF8.GetString($buf, $sp.Start, $sp.End - $sp.Start) | ConvertFrom-Json
    if ($o -and ($o.version -is [int] -or $o.version -is [long])) { $ver = [int]$o.version }
  } catch { }
  [pscustomobject]@{ Off = $sp.End; Ver = $ver }
}
function Get-OmpBodyOff([string]$Path) { (Get-OmpHeaderInfo $Path).Off }

function Test-OmpNonEmpty([string]$Path) {
  $rx = [regex]'"type"\s*:\s*"message"'
  $sr = New-Object IO.StreamReader((Open-ShareRead $Path), [Text.Encoding]::GetEncoding(28591), $false, 1048576)
  try { while ($null -ne ($line = $sr.ReadLine())) { if ($rx.IsMatch($line)) { return $true } } } finally { $sr.Dispose() }
  $false
}

function Get-RangeSha([string]$Path, [long]$Off, [long]$Len) {
  $sha = [Security.Cryptography.SHA256]::Create()
  $fs = Open-ShareRead $Path
  try {
    if ($fs.Length - $Off -lt $Len) { return $null }
    [void]$fs.Seek($Off, [IO.SeekOrigin]::Begin)
    $buf = New-Object byte[] 1048576; $left = $Len
    while ($left -gt 0) {
      $r = $fs.Read($buf, 0, [int][Math]::Min($buf.Length, $left))
      if ($r -le 0) { return $null }
      [void]$sha.TransformBlock($buf, 0, $r, $null, 0); $left -= $r
    }
    [void]$sha.TransformFinalBlock($buf, 0, 0)
    ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLowerInvariant()
  } finally { $fs.Dispose(); $sha.Dispose() }
}

# cac version header "session" ma fcode phien hieu (cung danh sach voi chuong trinh tren box va server.mjs). Khac thi khong chep.
function Get-PhienKnownVersions { , @(3) }
function Test-PhienKnownVersion($v) { $null -ne $v -and "$v" -match '\A[0-9]+\z' -and ((Get-PhienKnownVersions) -contains [int]$v) }

# "version" cua dong header "session" (so nguyen), $null neu thieu hoac khong doc duoc
function Get-OmpHeaderVersion([string]$Path) { (Get-OmpHeaderInfo $Path).Ver }

function Get-PhienOff([string]$Path) { if ($Path.EndsWith('.jsonl')) { Get-OmpBodyOff $Path } else { 0 } }

# ten file tam rieng cho tung lan chay (hai lan chay cung luc khong dam len nhau)
function New-PhienPartName([string]$Path) { $Path + '.fcode-part-' + $PID + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6) }

# bang: hex -> $true cho cac file blob dang co tren box (ten file co the la <hex> hoac <hex>.duoi)
function Get-PhienBoxBlobSet($Names) {
  $h = @{}
  foreach ($b in @($Names)) { if (([string]$b) -match '\A([a-f0-9]{64})') { $h[$Matches[1]] = $true } }
  $h
}

# phan than (sau header) cua $Short co la phan dau cua $Long khong (so sha256 cua hai doan, ham co san cua .NET)
function Test-PhienPrefix([string]$Short, [string]$Long) {
  $so = Get-PhienOff $Short; $lo = Get-PhienOff $Long
  $n = (Get-Item -LiteralPath $Short).Length - $so
  if ($n -le 0) { return $true }
  $a = Get-RangeSha $Short $so $n; $b = Get-RangeSha $Long $lo $n
  [bool]($a -and $b -and $a -eq $b)
}
# chep mot file; voi .jsonl thi doi cwd trong dong header "session" ($From -> $To), moi byte khac giu nguyen. Giu gio sua file.
# Tra ve $true neu header da doi.
# $MaxLen >= 0: chep dung ngan ay byte dau (do dai da quet, da qua luat 30 giay), khong chep phan omp ghi them sau do
function Copy-OmpSession([string]$Src, [string]$Dst, [string]$From, [string]$To, [long]$MaxLen = -1) {
  $dir = Split-Path -Parent $Dst
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
  $mt = (Get-Item -LiteralPath $Src).LastWriteTimeUtc
  $fs = Open-ShareRead $Src
  $changed = $false
  try {
    $buf = Read-Head $fs ([int][Math]::Min([long]262144, [long]$(if ($MaxLen -ge 0) { $MaxLen } else { [long]::MaxValue })))
    $new = $null; $sp = $null
    if ($Src.EndsWith('.jsonl') -and $From -and $To) {
      $sp = Get-OmpHeaderSpan $buf
      if ($sp) {
        $utf8 = New-Object Text.UTF8Encoding($false)
        $text = $utf8.GetString($buf, $sp.Start, $sp.End - $sp.Start)
        $m = ([regex]'("cwd"\s*:\s*)"((?:[^"\\]|\\.)*)"').Match($text)
        if ($m.Success) {
          $old = (ConvertFrom-Json ('{"c":"' + $m.Groups[2].Value + '"}')).c
          $nc = Convert-OmpCwd $old $From $To
          if ($null -ne $nc -and $nc -cne $old) {
            $new = $utf8.GetBytes($text.Substring(0, $m.Index) + $m.Groups[1].Value + (ConvertTo-JsonStr $nc) + $text.Substring($m.Index + $m.Length))
          }
        }
      }
    }
    $out = New-Object IO.FileStream($Dst, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
      if ($null -ne $new) {
        $out.Write($buf, 0, $sp.Start); $out.Write($new, 0, $new.Length); $out.Write($buf, $sp.End, $buf.Length - $sp.End)
        $changed = $true
      } else { $out.Write($buf, 0, $buf.Length) }
      if ($MaxLen -lt 0) { $fs.CopyTo($out) }
      else {
        $left = $MaxLen - $buf.Length; $chunk = New-Object byte[] 1048576
        while ($left -gt 0) { $n = $fs.Read($chunk, 0, [int][Math]::Min($chunk.Length, $left)); if ($n -le 0) { break }; $out.Write($chunk, 0, $n); $left -= $n }
      }
    } finally { $out.Dispose() }
  } finally { $fs.Dispose() }
  [IO.File]::SetLastWriteTimeUtc($Dst, $mt)
  $changed
}

# tat ca blob:sha256:<hex> trong cac file .jsonl (chi doc, khong in noi dung). $Lens[i] >= 0: chi doc ngan ay byte dau (phan da quet)
function Get-OmpBlobRefs([string[]]$Files, [long[]]$Lens = @()) {
  $set = @{}
  $rx = [regex]'blob:sha256:([a-f0-9]{64})'
  $lat = [Text.Encoding]::GetEncoding(28591)
  for ($i = 0; $i -lt @($Files).Count; $i++) {
    $left = if ($i -lt $Lens.Count -and $Lens[$i] -ge 0) { $Lens[$i] } else { [long]::MaxValue }
    $fs = Open-ShareRead $Files[$i]
    try {
      $buf = New-Object byte[] 1048576; $tail = ''
      while ($left -gt 0) {
        $n = $fs.Read($buf, 0, [int][Math]::Min([long]$buf.Length, $left)); if ($n -le 0) { break }
        $left -= $n
        $s = $tail + $lat.GetString($buf, 0, $n)
        foreach ($m in $rx.Matches($s)) { $set[$m.Groups[1].Value] = $true }
        $tail = if ($s.Length -gt 75) { $s.Substring($s.Length - 75) } else { $s }
      }
    } finally { $fs.Dispose() }
  }
  @($set.Keys | Sort-Object)
}

# bang tra: hex -> danh sach ten file blob (hex hoac hex.duoi) trong thu muc blob
function Get-OmpBlobIndex([string]$BlobDir) {
  $ix = @{}
  if (Test-Path -LiteralPath $BlobDir) {
    foreach ($f in [IO.Directory]::GetFiles($BlobDir)) {
      $n = [IO.Path]::GetFileName($f)
      if ($n -match '^([a-f0-9]{64})(?:\.[A-Za-z0-9][A-Za-z0-9._-]{0,31})?$') {
        if (-not $ix.ContainsKey($Matches[1])) { $ix[$Matches[1]] = New-Object System.Collections.ArrayList }
        [void]$ix[$Matches[1]].Add($n)
      }
    }
  }
  $ix
}

# cac file trong thu muc di kem <Base>\ cua mot phien (cung dang voi `dir_files` cua box)
function Get-PhienDirFiles([string]$Dir, [string]$Base) {
  $files = New-Object System.Collections.ArrayList
  $sd = Join-Path $Dir $Base
  if (Test-Path -LiteralPath $sd -PathType Container) {
    foreach ($f in (Get-ChildItem -LiteralPath $sd -Recurse -File -Force)) {
      if ($f.Name.Contains('.fcode-part')) { continue }
      $hi = if ($f.Name.EndsWith('.jsonl')) { Get-OmpHeaderInfo $f.FullName } else { [pscustomobject]@{ Off = 0; Ver = $null } }
      [void]$files.Add([pscustomobject]@{
        rel = $Base + '/' + $f.FullName.Substring($sd.Length + 1).Replace('\', '/')
        size = $f.Length; mtime = (ConvertTo-Epoch $f.LastWriteTimeUtc); off = $hi.Off; ver = $hi.Ver; path = $f.FullName })
    }
  }
  , @($files)
}
function Get-PhienIdOf([string]$Name) { $u = $Name.LastIndexOf('_'); if ($u -ge 0) { $Name.Substring($u + 1, $Name.Length - $u - 7) } else { '' } }

# danh sach phien o mot thu muc sessions\<enc> tren laptop, cung dang voi `scan` cua box. Mot thu muc di kem ma file .jsonl chua toi
# (lan truoc dung giua chung) cung duoc liet ke voi orphan = $true: chi la danh sach file da nhan, khong bao gio la mot phien de chep.
function Get-PhienLocalScan([string]$Dir) {
  $res = New-Object System.Collections.ArrayList
  if (-not (Test-Path -LiteralPath $Dir)) { return , @() }
  $tops = @{}
  foreach ($fi in (Get-ChildItem -LiteralPath $Dir -File -Filter '*.jsonl' | Sort-Object Name)) {
    if ($fi.Name.Contains('.fcode-part')) { continue }
    $n = $fi.Name; $base = $n.Substring(0, $n.Length - 6); $tops[$base] = $true
    $files = Get-PhienDirFiles $Dir $base
    $org = ''
    $sc = Join-Path $Dir ($base + '.fcode-origin')
    if (Test-Path -LiteralPath $sc) { try { $org = ([IO.File]::ReadAllText($sc)).Trim() } catch { } }
    $top = Get-OmpHeaderInfo $fi.FullName
    $js = @($files | Where-Object { $_.rel.EndsWith('.jsonl') })
    $refs = Get-OmpBlobRefs (@($fi.FullName) + @($js | ForEach-Object { $_.path })) ([long[]](@($fi.Length) + @($js | ForEach-Object { $_.size })))
    [void]$res.Add([pscustomobject]@{
      name = $n; id = (Get-PhienIdOf $n)
      size = $fi.Length; mtime = (ConvertTo-Epoch $fi.LastWriteTimeUtc); off = $top.Off; ver = $top.Ver
      ne = (Test-OmpNonEmpty $fi.FullName); files = $files; origin = $org; refs = @($refs) })
  }
  foreach ($di in (Get-ChildItem -LiteralPath $Dir -Directory -Force | Sort-Object Name)) {
    if ($tops.ContainsKey($di.Name) -or $di.Name.Contains('.fcode-part')) { continue }
    [void]$res.Add([pscustomobject]@{ name = $di.Name + '.jsonl'; id = (Get-PhienIdOf ($di.Name + '.jsonl')); orphan = $true; size = 0; mtime = 0; off = 0; ver = $null
      ne = $false; files = (Get-PhienDirFiles $Dir $di.Name); origin = ''; refs = @() })
  }
  , @($res)
}

# so sanh mot file co mat o hai ben: 'same' | 'put' (laptop dai hon) | 'get' (box dai hon) | 'diverged' | 'need' (can hash cua box)
function Compare-PhienFile($L, $R, [string]$Enc, [string]$Rel, [hashtable]$BoxHash, [string]$LDir, $Need) {
  $a = [long]$L.size - [long]$L.off; $b = [long]$R.size - [long]$R.off
  # cung do dai: file do chinh fcode chep giu nguyen gio sua (den giay), va moi lan ghi sau do deu doi gio sua
  # -> cung do dai + cung gio sua = giong nhau, khong can bam; khac gio sua thi so sha256 (khac noi dung = diverged)
  if ($a -eq $b -and [Math]::Floor([double]$L.mtime) -eq [Math]::Floor([double]$R.mtime)) { return 'same' }
  $len = [Math]::Min($a, $b)
  $key = "$Enc|$Rel|$len"
  if (-not $BoxHash.ContainsKey($key)) {
    if (-not ($Need | Where-Object { $_.key -eq $key })) { [void]$Need.Add([pscustomobject]@{ key = $key; enc = $Enc; rel = $Rel; len = $len }) }
    return 'need'
  }
  $bh = $BoxHash[$key]
  $lh = Get-RangeSha (Join-Path $LDir ($Rel -replace '/', '\')) ([long]$L.off) $len
  if ($bh -and $lh -and $bh -eq $lh) { if ($a -eq $b) { 'same' } elseif ($a -lt $b) { 'get' } else { 'put' } } else { 'diverged' }
}

# ke hoach cho mot project, so tung FILE: Put/Get = danh sach {Id; Name; Top; Files; Blobs; Deps; DepBlobs}; Need = cac hash can hoi box.
# Top (file .jsonl chinh) chi di khi moi file di kem va blob cua no da co hoac cung di; Deps/DepBlobs = nhung gi ben nhan phai thay
# tren dia truoc khi dat Top. Thu muc mo coi (orphan) chi la danh sach file ben nhan da co. $LBlobs/$RBlobs: hex -> co tren laptop/box.
function Get-PhienPlan($L, $R, [string]$Enc, [hashtable]$BoxHash, [string]$LDir, [double]$LNow, [double]$RNow, [int]$Busy = 30, [hashtable]$LBlobs = @{}, [hashtable]$RBlobs = @{}) {
  $put = New-Object System.Collections.ArrayList; $get = New-Object System.Collections.ArrayList
  $notes = New-Object System.Collections.ArrayList; $need = New-Object System.Collections.ArrayList
  $unknown = New-Object System.Collections.ArrayList; $diverged = 0
  $same = 0; $incomplete = 0; $deferred = 0
  $lm = @{}; foreach ($s in @($L)) { if ($s) { $lm[[string]$s.id] = $s } }
  $rm = @{}; foreach ($s in @($R)) { if ($s) { $rm[[string]$s.id] = $s } }
  $ids = @(@($lm.Keys) + @($rm.Keys) | Sort-Object -Unique)
  foreach ($id in $ids) {
    $l = $lm[$id]; $r = $rm[$id]
    $lr = [bool]($l -and -not $l.orphan); $rr = [bool]($r -and -not $r.orphan)
    if (-not $lr -and -not $rr) { continue }
    $lab = if ($id.Length -gt 8) { $id.Substring(0, 8) } else { $id }
    if ($lr -and $rr) {
      if ($l.name -cne $r.name) { [void]$notes.Add("phiên $lab có tên file khác nhau ở hai máy, giữ nguyên cả hai"); continue }
      if (-not $l.ne -and -not $r.ne) { continue }
      if (-not (Test-PhienKnownVersion $l.ver) -or -not (Test-PhienKnownVersion $r.ver)) {
        [void]$unknown.Add([pscustomobject]@{ Id = $id; Ver = $(if (Test-PhienKnownVersion $l.ver) { $r.ver } else { $l.ver }) }); continue
      }
    } else {
      $s = if ($lr) { $l } else { $r }
      if (-not $s.ne) { continue }
      if (-not (Test-PhienKnownVersion $s.ver)) { [void]$unknown.Add([pscustomobject]@{ Id = $id; Ver = $s.ver }); continue }
    }
    # a nested .jsonl with an unknown header on a real side: the whole session waits (never guess a format)
    $bad = @(@($(if ($lr) { $l.files })) + @($(if ($rr) { $r.files })) | Where-Object { $_ -and $_.rel.EndsWith('.jsonl') -and -not (Test-PhienKnownVersion $_.ver) } | Select-Object -First 1)
    if ($bad.Count) { [void]$unknown.Add([pscustomobject]@{ Id = $id; Ver = $bad[0].ver }); continue }
    if ($lr -and $rr) {
      $t = Compare-PhienFile $l $r $Enc $l.name $BoxHash $LDir $need
      if ($t -eq 'diverged') { $diverged++; [void]$notes.Add("phiên $lab đã khác nhau ở hai máy, giữ nguyên cả hai"); continue }
      if ($t -ne 'same' -and (($LNow - $l.mtime -lt $Busy) -or ($RNow - $r.mtime -lt $Busy))) { [void]$notes.Add("phiên $lab đang được ghi, sẽ đồng bộ lần sau"); continue }
    } elseif ($lr) {
      if ($LNow - $l.mtime -lt $Busy) { [void]$notes.Add("phiên $lab đang được ghi trên laptop, sẽ đồng bộ lần sau"); continue }
      $t = 'put'
    } else {
      if ($RNow - $r.mtime -lt $Busy) { [void]$notes.Add("phiên $lab đang được ghi trên box, sẽ đồng bộ lần sau"); continue }
      $t = 'get'
    }
    # per file: missing or a prefix on the other side -> copy; a file being written or not comparable now holds the top back
    $lf = @{}; if ($l) { foreach ($f in @($l.files)) { if ($f) { $lf[$f.rel] = $f } } }
    $rf = @{}; if ($r) { foreach ($f in @($r.files)) { if ($f) { $rf[$f.rel] = $f } } }
    $pf = New-Object System.Collections.ArrayList; $gf = New-Object System.Collections.ArrayList
    $pd = $false; $gd = $false
    foreach ($rel in @(@($lf.Keys) + @($rf.Keys) | Sort-Object -Unique)) {
      $x = $lf[$rel]; $y = $rf[$rel]
      if ($x -and -not $y) { if ($lr) { if ($LNow - $x.mtime -ge $Busy) { [void]$pf.Add($rel) } else { $pd = $true } }; continue }
      if ($y -and -not $x) { if ($rr) { if ($RNow - $y.mtime -ge $Busy) { [void]$gf.Add($rel) } else { $gd = $true } }; continue }
      $c = Compare-PhienFile $x $y $Enc $rel $BoxHash $LDir $need
      if ($c -eq 'same') { continue }
      if ($c -eq 'need') { $pd = $true; $gd = $true; continue }
      if ($c -eq 'diverged') { $diverged++; [void]$notes.Add("file $rel của phiên $lab đã khác nhau ở hai máy, giữ nguyên cả hai"); $pd = $true; $gd = $true; continue }
      $bz = ($LNow - $x.mtime -lt $Busy) -or ($RNow - $y.mtime -lt $Busy)
      if ($c -eq 'put') { if ($lr) { if ($bz) { $pd = $true } else { [void]$pf.Add($rel) } } }
      elseif ($rr) { if ($bz) { $gd = $true } else { [void]$gf.Add($rel) } }
    }
    if ($t -eq 'need') { continue }
    # blobs: an equal .jsonl does not prove its blobs are there; every blob a real side refers to and the other side lacks is copied
    $pb = New-Object System.Collections.ArrayList; $gb = New-Object System.Collections.ArrayList; $miss = @{}
    if ($lr) { foreach ($h in @($l.refs)) { if (-not $h -or $RBlobs.ContainsKey($h)) { continue }; if ($LBlobs.ContainsKey($h)) { [void]$pb.Add($h) } else { $miss[$h] = $true } } }
    if ($rr) { foreach ($h in @($r.refs)) { if (-not $h -or $LBlobs.ContainsKey($h)) { continue }; if ($RBlobs.ContainsKey($h)) { [void]$gb.Add($h) } else { $miss[$h] = $true } } }
    if ($miss.Count) { $incomplete++; [void]$notes.Add("phiên $lab thiếu $($miss.Count) file đính kèm (blob) ở máy gửi, phiên chưa đầy đủ") }
    $tp = ($t -eq 'put') -and -not $pd; $tg = ($t -eq 'get') -and -not $gd
    if (($t -eq 'put' -and $pd) -or ($t -eq 'get' -and $gd)) { $deferred++; [void]$notes.Add("phiên $lab còn file đi kèm chưa chép được, file chính để lần sau") }
    if ($tp -or $pf.Count -or $pb.Count) {
      [void]$put.Add([pscustomobject]@{ Id = $id; Name = $l.name; Top = $tp; Files = @($pf); Blobs = @($pb)
        Deps = @($(if ($tp) { foreach ($f in @($l.files)) { if ($f) { @{ r = $f.rel; n = [long]$f.size - [long]$f.off } } } }))
        DepBlobs = @($(if ($tp) { @($l.refs) | Where-Object { $_ -and ($LBlobs.ContainsKey($_) -or $RBlobs.ContainsKey($_)) } })) })
    }
    if ($tg -or $gf.Count -or $gb.Count) {
      [void]$get.Add([pscustomobject]@{ Id = $id; Name = $r.name; Top = $tg; Files = @($gf); Blobs = @($gb)
        Deps = @($(if ($tg) { foreach ($f in @($r.files)) { if ($f) { @{ r = $f.rel; n = [long]$f.size - [long]$f.off } } } }))
        DepBlobs = @($(if ($tg) { @($r.refs) | Where-Object { $_ -and ($LBlobs.ContainsKey($_) -or $RBlobs.ContainsKey($_)) } })) })
    }
    if ($t -eq 'same' -and -not ($pf.Count + $gf.Count + $pb.Count + $gb.Count + $miss.Count) -and -not ($pd -or $gd)) { $same++ }
  }
  [pscustomobject]@{ Put = @($put); Get = @($get); Need = @($need); Notes = @($notes); Same = $same; Unknown = @($unknown); Diverged = $diverged; Incomplete = $incomplete; Deferred = $deferred }
}

# ben nhan: moi file di kem (do dai phan than >= n) va moi blob (theo hex) ma file chinh can da co tren dia chua
function Test-PhienDeps([string]$Dir, $Deps, $DepBlobs, [hashtable]$BlobIx) {
  foreach ($h in @($DepBlobs)) { if ($h -and -not $BlobIx.ContainsKey([string]$h)) { return $false } }
  foreach ($d in @($Deps)) {
    if (-not $d) { continue }
    $p = Join-Path $Dir (([string]$d.r) -replace '/', '\')
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $false }
    if (((Get-Item -LiteralPath $p).Length - (Get-PhienOff $p)) -lt [long]$d.n) { return $false }
  }
  $true
}

# dat mot file da nhan (o thu muc tam) vao dich theo luat chi-noi-them. Tra ve: new | replaced | same | skip | busy
function Install-PhienFile([string]$Src, [string]$Dst, [string]$From, [string]$To, [double]$Now, [int]$Busy = 30) {
  if ($Src.EndsWith('.jsonl') -and -not (Test-PhienKnownVersion (Get-OmpHeaderVersion $Src))) { return 'skip' }
  if (Test-Path -LiteralPath $Dst) {
    $di = Get-Item -LiteralPath $Dst
    if ($Now - (ConvertTo-Epoch $di.LastWriteTimeUtc) -lt $Busy) { return 'busy' }
    $a = $di.Length - (Get-PhienOff $Dst); $b = (Get-Item -LiteralPath $Src).Length - (Get-PhienOff $Src)
    if ($a -eq $b) { return 'same' }
    if ($b -lt $a -or -not (Test-PhienPrefix $Dst $Src)) { return 'skip' }
    $st = 'replaced'
  } else { $st = 'new' }
  $part = New-PhienPartName $Dst
  try {
    [void](Copy-OmpSession $Src $part $From $To)
    $mt = (Get-Item -LiteralPath $part).LastWriteTimeUtc
    if ($st -eq 'new') { [IO.File]::Move($part, $Dst) } else { [IO.File]::Replace($part, $Dst, [NullString]::Value) }
    [IO.File]::SetLastWriteTimeUtc($Dst, $mt)
  } finally { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
  $st
}


# --- chia thanh tung dot <= 50 MB moi luong tar, tinh ca phan tar them vao (mot dot = mot lan ssh; gui va nhan deu vay) ---
$PhienBatchBytes = 52428800
$PhienBatchLimit = $PhienBatchBytes - 131072   # cho cho manifest, dong chuong trinh va phan cuoi tar
function New-PhienBatch([string]$Dir) {
  [pscustomobject]@{ Dir = $Dir; Bytes = [long]0; Items = (New-Object System.Collections.ArrayList)
    Ensure = (New-Object System.Collections.ArrayList); Unexclude = (New-Object System.Collections.ArrayList) }
}
# dot hien tai neu con cho cho them $Add byte, khong thi mo dot moi (mot file lon hon 50 MB tu thanh mot dot rieng)
function Get-PhienBatch($Batches, [string]$Root, [long]$Add, [long]$Limit = 52428800) {
  $cur = if ($Batches.Count) { $Batches[$Batches.Count - 1] } else { $null }
  if (-not $cur -or ($cur.Bytes -gt 0 -and $cur.Bytes + $Add -gt $Limit)) { $cur = New-PhienBatch (Join-Path $Root ('put' + $Batches.Count)); [void]$Batches.Add($cur) }
  $cur.Bytes += $Add
  $cur
}
# so byte toi da mot file chiem trong luong tar: dau muc 512 + phan mo rong pax + lam tron 512; .jsonl con co the dai them do doi cwd
function Get-PhienUnitBytes([long]$Size, [string]$Rel = '', [long]$Extra = 0) {
  $s = $Size + $(if ($Rel.EndsWith('.jsonl')) { 4096 } else { 0 })
  2560 + [long]([Math]::Ceiling($s / 512) * 512) + $Extra + 3 * $Rel.Length + 80
}

# --- noi chuyen voi box ---
# 'running' (ssh vao duoc box) | 'unknown' (khong vao duoc: mang, box tat, alias sai): unknown khong doi gi ca. Box Oracle luon bat, khong co trang thai "ngu".
function Test-BoxRunning {
  try {
    $r = Invoke-PhienExe (Get-SshExe) @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', $box, 'true')
    if ($r.Code -eq 124) { return 'timeout' }   # only while a phien deadline is set (--nhanh): the ssh ran into it
    if ($r.Code -eq 0) { 'running' } else { 'unknown' }
  } catch { 'unknown' }
}

# gioi han giay: lan tu dong = MOT han cho ca lan chay (420 s, duoi 8 phut cua Task Scheduler); chay tay = 900 s moi lan goi box.
# Chi de thu: FCODE_PHIEN_TIMEOUT=<giay>.
function Get-PhienLimitSec([bool]$Auto) { if ("$env:FCODE_PHIEN_TIMEOUT" -match '\A[0-9]{1,5}\z') { [int]$env:FCODE_PHIEN_TIMEOUT } elseif ($Auto) { 420 } else { 900 } }
# han chot cua che do nhanh (--nhanh): 20 s. Chi de thu: FCODE_PHIEN_CAP_SEC=<giay> (1-999).
$PhienCapMsg = 'phien: hết 20 giây, phần còn lại chạy lần sau'
function Get-PhienCapSec { if ("$env:FCODE_PHIEN_CAP_SEC" -match '\A[1-9][0-9]{0,2}\z') { [int]$env:FCODE_PHIEN_CAP_SEC } else { 20 } }
# the phien deadline (--nhanh, auto) is checked ONLY here, at a safe point of Invoke-PhienSync: before an item (a batch, a note) starts. Nothing inside an
# item stops for it: an item is all fallible work first, then its commit step (an atomic move), then plain file writes, so it ends whole or not at all.
# "Time is up" already when less than 1 s is left: no item is worth starting then.
function Test-PhienTimeUp { [bool]($script:PhienDeadline -and [DateTime]::UtcNow.AddSeconds(1) -ge $script:PhienDeadline) }
# timeout of one child program (ms, -1 = none): the time left + 5 s grace, at least 3 s. A child that runs into it fails only its own item cleanly,
# and the run stops at the next safe point, so a quick run ends by about cap + 5 s.
function Get-PhienChildMs { if ($script:PhienDeadline) { [int][Math]::Max(3000, ($script:PhienDeadline - [DateTime]::UtcNow).TotalMilliseconds + 5000) } else { -1 } }
# a safe point found the deadline passed (nothing failed before it): --nhanh -> the cap line, exit 0; auto -> the run is cut, exit 1
function Stop-PhienAtCap([bool]$Quick, [hashtable]$Stat) {
  if ($Quick) { Set-PhienScreen $PhienCapMsg; return 0 }
  $Stat.ok = $false; Write-PhienOut 'hết thời gian của lượt này: phần còn lại để lần sau'; 1
}
# dung tien trinh va moi tien trinh con cua no; Windows PowerShell 5.1 khong co Kill($true) nen dung taskkill
function Stop-PhienProc($p) {
  try { $p.Kill($true) } catch { try { & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null } catch { }; try { $p.Kill() } catch { } }
}
# one argument as the Windows command line wants it (.NET Framework, hence Windows PowerShell 5.1, has no ArgumentList)
function ConvertTo-PhienArg([string]$a) {
  if ($a -ne '' -and $a -notmatch '[\s"]') { return $a }
  '"' + ([regex]::Replace($a, '(\\*)"', '$1$1\"') -replace '(\\+)\z', '$1$1') + '"'
}
# run a program with its output captured (stdin closed, so it can never wait for a key). While a phien deadline is set the program is killed with its
# children after Get-PhienChildMs (Code 124). Out = stdout lines.
function Invoke-PhienExe([string]$Exe, [string[]]$ExeArgs, [string]$StdinText) {   # $StdinText (optional): written to the child's stdin as UTF-8 before it is closed
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe; $psi.Arguments = (@($ExeArgs | ForEach-Object { ConvertTo-PhienArg ([string]$_) }) -join ' ')
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  try { $p = [Diagnostics.Process]::Start($psi) } catch { return [pscustomobject]@{ Code = -1; Out = [string[]]@(); Err = "$($_.Exception.Message)" } }
  try {
    try {
      if ($StdinText) { $sb = [Text.Encoding]::UTF8.GetBytes($StdinText); $p.StandardInput.BaseStream.Write($sb, 0, $sb.Length); $p.StandardInput.BaseStream.Flush() }   # raw UTF-8 bytes; not BOM-free: with console input code page 65001 Windows PowerShell 5.1's Process.Start makes StandardInput a StreamWriter with the UTF-8 preamble and AutoFlush, so a BOM is already in the pipe before this write (5.1 has no StandardInputEncoding); see the --stdin note near check-ignore
      $p.StandardInput.Close()
    } catch { }
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    # short waits, so a kill of this process (the job ending it) is never stuck behind one long native wait; -1 = no deadline, wait as long as it runs
    $ms = Get-PhienChildMs; $end = if ($ms -lt 0) { $null } else { [DateTime]::UtcNow.AddMilliseconds($ms) }
    while (-not $p.WaitForExit(100)) {
      if ($end -and [DateTime]::UtcNow -ge $end) { Stop-PhienProc $p; return [pscustomobject]@{ Code = 124; Out = [string[]]@(); Err = 'quá thời gian chờ' } }
    }
    try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($o, $e), 3000) } catch { }
    $lines = New-Object System.Collections.Generic.List[string]
    if ($o.IsCompleted -and -not $o.IsFaulted) { $lines.AddRange([string[]]@($o.Result -split "`r?`n")) }
    if ($lines.Count -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    [pscustomobject]@{ Code = $p.ExitCode; Out = [string[]]$lines.ToArray(); Err = $(if ($e.IsCompleted -and -not $e.IsFaulted) { $e.Result } else { '' }) }
  } finally { $p.Dispose() }
}

# chay $PhienPy tren box. Tra ve @{Code; Out = byte[]; Err}. stdin: $InBytes hoac noi dung file $InFile.
# Han chot tinh tu truoc khi ghi byte stdin dau tien; stdin ghi bat dong bo, nen box dung doc thi den han van dung duoc.
function Invoke-BoxPy([string]$Cmd, [byte[]]$InBytes, [string]$InFile) {
  $sec = if ($script:PhienDeadline) { (Get-PhienChildMs) / 1000 } else { Get-PhienLimitSec $false }
  $end = [DateTime]::UtcNow.AddSeconds($sec)
  # chuong trinh python (deflate + base64) la dong dau cua stdin; dong lenh chi co lenh nap ngan (khong vuong gioi han do dai)
  # chu thich va dong trong bo di truoc khi nen
  $src = (($PhienPy -split "`n") | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') }) -join "`n"
  $raw = [Text.Encoding]::UTF8.GetBytes($src)
  $zs = New-Object IO.MemoryStream
  $ds = New-Object IO.Compression.DeflateStream($zs, [IO.Compression.CompressionMode]::Compress, $true)
  $ds.Write($raw, 0, $raw.Length); $ds.Dispose()
  $head = [Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String($zs.ToArray()) + "`n")
  $pre = ''
  # chi de thu: FCODE_PHIEN_BOXENV="HOME=/tmp/x FCODE_CFG=/tmp/y" doi moi truong cua chuong trinh tren box
  if ($env:FCODE_PHIEN_BOXENV) {
    if ($env:FCODE_PHIEN_BOXENV -notmatch '\A[A-Za-z_][A-Za-z0-9_]*=[A-Za-z0-9_./:@-]*( [A-Za-z_][A-Za-z0-9_]*=[A-Za-z0-9_./:@-]*)*\z') { throw 'FCODE_PHIEN_BOXENV không hợp lệ' }
    $pre = 'env ' + $env:FCODE_PHIEN_BOXENV + ' '
  }
  $remote = $pre + "python3 -c 'import base64,sys,zlib;exec(zlib.decompress(base64.b64decode(sys.stdin.buffer.readline()),-15).decode())' $Cmd"
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = Get-SshExe
  $psi.Arguments = '-o BatchMode=yes ' + $box + ' "' + $remote + '"'
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $body = if ($InFile) { [IO.File]::OpenRead($InFile) } elseif ($InBytes) { New-Object IO.MemoryStream(, $InBytes) } else { New-Object IO.MemoryStream }
  try {
    $p = [Diagnostics.Process]::Start($psi)
    try {
      $ms = New-Object IO.MemoryStream
      $t1 = $p.StandardOutput.BaseStream.CopyToAsync($ms)
      $t2 = $p.StandardError.ReadToEndAsync()
      $si = $p.StandardInput.BaseStream
      $tin = $si.WriteAsync($head, 0, $head.Length); $step = 0
      while ($true) {
        if ($null -ne $tin -and $tin.IsCompleted) {
          if ($step -eq 0 -and -not $tin.IsFaulted) { $step = 1; $tin = $body.CopyToAsync($si) }
          else { try { $si.Close() } catch { }; $tin = $null }
        }
        $left = ($end - [DateTime]::UtcNow).TotalMilliseconds
        if ($left -le 0) { Stop-PhienProc $p; return [pscustomobject]@{ Code = 124; Out = [byte[]]@(); Err = 'quá thời gian chờ' } }
        if ($p.WaitForExit([int][Math]::Min(100, $left))) { break }
      }
      $left = [Math]::Max(5000, ($end - [DateTime]::UtcNow).TotalMilliseconds)
      if (-not $t1.Wait([int]$left)) { Stop-PhienProc $p; return [pscustomobject]@{ Code = 124; Out = [byte[]]@(); Err = 'quá thời gian chờ' } }
      [void]$t2.Wait(5000)
      [pscustomobject]@{ Code = $p.ExitCode; Out = $ms.ToArray(); Err = $(if ($t2.IsCompleted) { $t2.Result } else { '' }) }
    } finally { $p.Dispose() }
  } finally { $body.Dispose() }
}

# doc dong "FCODE-JSON {..}" trong ket qua; $null neu khong co
function Get-BoxJson($r) {
  if ($r.Code -ne 0) { return $null }
  $txt = [Text.Encoding]::UTF8.GetString($r.Out)
  foreach ($l in ($txt -split "`n")) { if ($l.StartsWith('FCODE-JSON ')) { return ($l.Substring(11) | ConvertFrom-Json) } }
  $null
}

function Find-TarExe { $c = Get-Command tar.exe -ErrorAction SilentlyContinue; if ($c) { $c.Source } else { throw 'máy này không có tar.exe (Windows 10 trở lên mới có)' } }

function Write-PhienOut([string]$Msg) {
  if ($script:PhienQuiet -or $script:PhienQuick) { Add-PhienLog @($Msg) } else { Write-Host $Msg }   # auto and quick (--nhanh) runs: phien.log only, each line at once
}
# --nhanh: the one line (at most) that reaches the screen, printed by Invoke-Phien after the run; it is logged too
function Set-PhienScreen([string]$Msg) { $script:PhienScreen = $Msg; Write-PhienOut $Msg }

# owner/name (chu thuong) cua mot URL GitHub o moi dang (https, git@github.com:, alias github-<ten>:); khong phai GitHub -> '' (nhu repo_key cua box)
function Get-RepoKey([string]$Url) {
  $u = "$Url".Trim().Replace('\', '/').TrimEnd('/')
  if ($u -match '(?i)\.git\z') { $u = $u.Substring(0, $u.Length - 4) }
  $p = @($u -split '[/:]' | Where-Object { $_ })
  if ($u -match '(?i)github' -and $p.Count -ge 2) { ($p[-2] + '/' + $p[-1]).ToLowerInvariant() } else { '' }
}
function Get-LocalRepoKey([string]$Dir) {
  if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return '' }
  $r = Invoke-GitQuiet $Dir @('remote', 'get-url', 'origin')
  if ($r.Code -eq 0) { Get-RepoKey ([string]@($r.Out)[0]) } else { '' }
}

# do lai cua lan chay bi cat ngang (may ngu, mat dien, tat cua so, lan nhanh bi ngat o ~30 s, Ctrl+C). Rule L: fcode deletes only a name that is one of
# its own complete generated names, only where it put it, and only when it is over 1 h old or the PID in the name no longer runs (or is now a newer
# process): %TEMP%\fcode-phien-<PID>-<32hex> (and 1.3.2's fcode-phien-<32hex>, age only, never a link); <name>.fcode-part-<PID>-<6hex> in the session
# dirs ($Dirs, with subfolders) and the project roots ($Flat, root only); <file>.part-<PID> beside a file Write-PhienText rewrites (Clear-PhienPartFiles:
# by Write-PhienText itself before each write, and for the three state files here). Nothing else, nowhere else.
function Test-PhienOwnerGone($Item, [string]$Rx) {
  if ($Item.Name -notmatch $Rx -or -not $Matches[1]) { return $false }   # no PID in the name: the 1 h rule only
  try { $p = Get-Process -Id ([int]$Matches[1]) -ErrorAction Stop } catch { return $true }
  try { $p.StartTime.ToUniversalTime() -gt $Item.CreationTimeUtc } catch { $false }
}
# the only sweep of Write-PhienText leftovers: exactly <leaf>.part-<PID>, beside the file they belonged to (the path git named, for an exclude file)
function Clear-PhienPartFiles([string]$Path) {
  $dir = [IO.Path]::GetDirectoryName($Path); $leaf = [IO.Path]::GetFileName($Path)
  if (-not $dir -or -not [IO.Directory]::Exists($dir)) { return }
  $rx = '\A' + [regex]::Escape($leaf) + '\.part-([0-9]+)\z'
  $old = (Get-Date).ToUniversalTime().AddHours(-1)
  foreach ($x in @(Get-ChildItem -LiteralPath $dir -File -Force -Filter ($leaf + '.part-*') -ErrorAction SilentlyContinue)) {
    if ($x.Name -notmatch $rx) { continue }
    if ($x.LastWriteTimeUtc -lt $old -or (Test-PhienOwnerGone $x $rx)) { Remove-Item -LiteralPath $x.FullName -Force -ErrorAction SilentlyContinue }
  }
}
function Clear-PhienLeftovers([string[]]$Dirs, [string[]]$Flat = @()) {
  $old = (Get-Date).ToUniversalTime().AddHours(-1)
  $tmpRx = '\Afcode-phien-(?:([0-9]+)-)?[0-9a-f]{32}\z'
  $partRx = '\.fcode-part-([0-9]+)-[0-9a-f]{6}\z'
  foreach ($x in @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'fcode-phien-*' -Force -ErrorAction SilentlyContinue)) {
    if ($x.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
    if ($x.Name -notmatch $tmpRx) { continue }
    if ($x.LastWriteTimeUtc -lt $old -or (Test-PhienOwnerGone $x $tmpRx)) { Remove-Item -LiteralPath $x.FullName -Recurse -Force -ErrorAction SilentlyContinue }
  }
  foreach ($d in @(@($Dirs | ForEach-Object { @{ D = $_; R = $true } }) + @($Flat | ForEach-Object { @{ D = $_; R = $false } }))) {
    if (-not $d.D -or -not (Test-Path -LiteralPath $d.D)) { continue }
    foreach ($x in @(Get-ChildItem -LiteralPath $d.D -Recurse:$d.R -File -Force -Filter '*.fcode-part-*' -ErrorAction SilentlyContinue)) {
      if ($x.Name -notmatch $partRx) { continue }
      if ($x.LastWriteTimeUtc -lt $old -or (Test-PhienOwnerGone $x $partRx)) { Remove-Item -LiteralPath $x.FullName -Force -ErrorAction SilentlyContinue }
    }
  }
  $sd = Join-Path $env:LOCALAPPDATA 'fcode'
  foreach ($f in 'handoff-state.json', 'phien-status.json', 'phien-auto.json') { Clear-PhienPartFiles (Join-Path $sd $f) }
}

function Get-PhienProjects {
  $h = [ordered]@{}
  foreach ($r in $SyncRepos) {
    $n = (Split-Path ([string]$r).TrimEnd('\', '/') -Leaf).ToLowerInvariant()
    if ($n -notmatch '\A[a-z0-9][a-z0-9._-]{0,63}\z') { $n = '~' + $n }   # ten thu muc khong phai ten project (vd "New folder (2)"): chi khop theo repo
    if (-not $h.Contains($n)) { $h[$n] = [string]$r }
  }
  $h
}

# phien ban omp tren laptop ('' neu khong chay duoc)
function Get-OmpVersion {
  try {
    $c = Get-Command omp -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1   # the real program, never the `omp` function of the fcode moc hook
    if (-not $c) { return '' }
    $r = Invoke-PhienExe $c.Source @('--version')
    if ((($r.Out -join ' ') + ' ' + $r.Err) -match '\d+\.\d+\.\d+\S*') { return $Matches[0] }
  } catch { }
  ''
}
function Get-PhienVersionNote([string]$Laptop, [string]$Box) { if ($Laptop -and $Box -and $Laptop -ne $Box) { "omp laptop $Laptop khác box $Box" } }
# dong tom tat khi gap phien co dinh dang la (omp vua doi): khong chep, khong doan
function Get-PhienUnknownNote($Unknown) {
  if (-not @($Unknown).Count) { return }
  $vs = @($Unknown | ForEach-Object { if ($null -ne $_.Ver -and "$($_.Ver)" -ne '') { "$($_.Ver)" } else { '?' } } | Sort-Object -Unique)
  "omp đổi định dạng phiên (version $($vs -join ', ')) — chưa đồng bộ, báo Claude"
}
function Get-PhienStatusPath { Join-Path $env:LOCALAPPDATA 'fcode\phien-status.json' }
# ghi ket qua moi lan chay (tay hay tu dong) de menu fcode canh bao; khong bao gio hien cua so
function Write-PhienStatus([hashtable]$Stat, [bool]$Auto) {
  try {
    $p = Get-PhienStatusPath
    $d = Split-Path -Parent $p
    if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
    $o = [ordered]@{
      at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); ok = [bool]$Stat.ok; copied = [int]$Stat.copied; skipped = [int]$Stat.skipped
      diverged = [int]$Stat.diverged; unknownFormat = @($Stat.unknown | ForEach-Object { [string]$_.Id } | Sort-Object -Unique)
      ompLaptop = [string]$Stat.ompL; ompBox = [string]$Stat.ompB; auto = $Auto
      notes = [ordered]@{ copied = [int]$Stat.noteCopied; conflicts = @($Stat.noteConf); released = @($Stat.noteReleased) }; unfinished = @($Stat.unfinished); newProjects = @($Stat.newProjects) }
    Write-PhienText $p ($o | ConvertTo-Json -Compress)
  } catch { }
}
# the one way fcode rewrites a file of its own or the user's (.git/info/exclude, the state JSONs): a part file next to it, then an atomic
# Replace / Move, so a kill at any instant leaves the old file or the new one, never a cut one. UTF-8 without BOM, or $Enc (Latin-1 for
# .git/info/exclude: its bytes go through unchanged). A dead run's part file of this same file is swept first (Rule L).
function Write-PhienText([string]$Path, [string]$Text, [Text.Encoding]$Enc = (New-Object Text.UTF8Encoding($false))) {
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
  Clear-PhienPartFiles $Path
  $part = "$Path.part-$PID"
  try {
    [IO.File]::WriteAllText($part, $Text, $Enc)
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($part, $Path, [NullString]::Value) } else { [IO.File]::Move($part, $Path) }
  } finally { if ([IO.File]::Exists($part)) { try { [IO.File]::Delete($part) } catch { } } }
}
# $true when the path or its folder is a link (symlink / junction): fcode never writes through one
function Test-PhienReparse([string]$Path) {
  foreach ($x in @($Path, [IO.Path]::GetDirectoryName($Path))) {
    if (-not $x) { continue }
    try { if ([IO.File]::GetAttributes($x) -band [IO.FileAttributes]::ReparsePoint) { return $true } } catch { }
  }
  $false
}
# ten khoa dong bo (nhat ky dung ten nay + '-log'). Chi de thu: FCODE_PHIEN_LOCK doi ten khoa (bo test dung ten rieng, khong dung khoa that)
function Get-PhienLockName { if ("$env:FCODE_PHIEN_LOCK" -match '\A[A-Za-z0-9\\._-]{1,200}\z') { $env:FCODE_PHIEN_LOCK } else { 'Local\fcode-phien' } }
# mot dong canh bao dau menu fcode: co phien dinh dang la, hoac lan tu dong gan nhat bi loi
function Get-PhienWarning {
  try {
    $p = Get-PhienStatusPath
    if (-not (Test-Path -LiteralPath $p)) { return }
    $s = [IO.File]::ReadAllText($p) | ConvertFrom-Json
    if (@($s.unknownFormat).Count -gt 0) { return "Cảnh báo: omp đổi định dạng phiên, $(@($s.unknownFormat).Count) phiên chưa đồng bộ. Hãy báo Claude." }
    if ($s.auto -and -not $s.ok) { return 'Cảnh báo: lần tự động đồng bộ phiên omp gần nhất bị lỗi. Chạy fcode phien để xem.' }
    if (@($s.notes.released).Count -gt 0) { return "Ghi chú dự án: git đã theo dõi $(@($s.notes.released).Count) file, bản cũ xóa được (chạy fcode phien để xem tên)." }
  } catch { }
}

# dong bo mot hay moi project. Tra ve 0 xong, 1 loi.
# Chep theo tung FILE, tung dot <= 50 MB (mot dot = mot lan ssh), ca hai chieu: dot nao xong thi nam lai ben nhan, lan sau chi chep
# phan con thieu. Ben nhan dat blob, file di kem, .jsonl long ben trong, roi file .jsonl chinh sau cung (khi moi thu no can da co).
# $Quick (--nhanh, cho hook cua `fcode moc`): mot project, khong cho khoa, toi da 20 s; thoat 0 khi khoa ban / het gio (khong vao duoc box la loi, thoat 1).
# Che do nhanh chi ghi phien.log; man hinh nhan toi da MOT dong (Invoke-Phien in $script:PhienScreen, hoac dong loi khi that bai); thanh cong thi im lang.
# Han chot (--nhanh, tu dong) chi duoc xem o diem an toan, truoc moi muc (quet, hash, mot dot, mot ghi chu); mot muc da bat dau thi xong tron hoac hong tron.
function Invoke-PhienSync([string]$Only, [bool]$Auto, [bool]$DryRun = $false, [bool]$BoxKnownRunning = $false, [bool]$Quick = $false) {
  $script:PhienQuiet = $Auto; $script:PhienQuick = $Quick; $script:PhienScreen = $null; $script:PhienRepoIds = @{}
  $capMsg = $PhienCapMsg
  $code = 0; $capHit = $false
  # lan tu dong: MOT han chot cho ca lan chay, tinh tu luc tien trinh bat dau (nhu gioi han 8 phut cua Task Scheduler)
  $script:PhienDeadline = if ($Auto) { Get-PhienAutoDeadline } elseif ($Quick) { [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().AddSeconds((Get-PhienCapSec)) } else { $null }
  $mx = $null; $held = $false
  if (-not $DryRun) {
    try {
      $mx = New-Object Threading.Mutex($false, (Get-PhienLockName))
      try { $held = $mx.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
      if (-not $held -and -not $Auto -and -not $Quick) {
        Write-Host 'Đang có một lượt đồng bộ khác chạy (tự động), chờ nó xong...'
        try { $held = $mx.WaitOne(540000) } catch [Threading.AbandonedMutexException] { $held = $true }
      }
    } catch { }
    if (-not $held) {
      if ($mx) { $mx.Dispose() }
      if ($Quick) { Set-PhienScreen 'phien: đang có lần đồng bộ khác, bỏ qua'; return 0 }
      if (-not $Auto) { Write-Host 'lỗi: lượt đồng bộ khác chạy quá lâu, thử lại sau.'; return 1 }
      return 0
    }
  }
  $stat = @{ ran = $false; ok = $true; copied = 0; skipped = 0; diverged = 0; unknown = @(); ompL = ''; ompB = ''; noteCopied = 0; noteConf = @(); noteReleased = @(); unfinished = @(); newProjects = @() }
  try {
    if (-not $DryRun) { Clear-PhienLeftovers @() }   # the lock is held: a killed run's staging goes now, even when this run stops early (box unreachable)
    $projs = Get-PhienProjects
    if ($projs.Count -eq 0) { Write-PhienOut "Chưa có project nào trong syncRepos ($ConfigFile)."; return 0 }
    $names = @($projs.Keys)
    if ($Only) {
      $o = $Only.ToLowerInvariant()
      if (-not $projs.Contains($o)) { Write-PhienOut "Không thấy project '$Only' trong syncRepos. Có: $(@($names | ForEach-Object { Format-ProjectName $_ $projs[$_] }) -join ', ')"; return 1 }
      $names = @($o)
    }
    if ($Quick) {   # one cheap reachability check first (ssh true)
      $bs = Test-BoxRunning
      if ($bs -eq 'timeout') { Set-PhienScreen $capMsg; return 0 }
      if ($bs -ne 'running') { $stat.ok = $false; Write-PhienOut "lỗi: không vào được box (ssh $box lỗi — kiểm tra mạng và alias ssh)"; return 1 }
    }
    elseif ($Auto) { if (-not $BoxKnownRunning -and (Test-BoxRunning) -ne 'running') { return 0 } }
    $stat.ran = $true; $stat.ompL = Get-OmpVersion
    # moc cho lan tu dong sau: ghi truoc khi mo ssh (lan loi, bi dung giua chung hay chay thu cung tinh: ssh nao cung la hoat dong cua box)
    # a quick run (the hook) does not count: a cut or failed one must not push the next 10-minute auto run behind the 40-minute gap
    if (-not $Quick) { Write-PhienAutoState @{ boxRunning = $true; lastSshAt = (ConvertTo-Epoch (Get-Date)) } }
    $agent = Get-OmpAgentDir
    $sessRoot = Join-Path $agent 'sessions'
    $laptopBlobDir = Join-Path $agent 'blobs'
    $lnow = ConvertTo-Epoch (Get-Date)
    # project nhan theo ten thu muc, hoac theo repo GitHub cua origin (thu muc ten khac van khop project cua box)
    $repoDir = @{}
    foreach ($n in $names) { $k = Get-LocalRepoKey $projs[$n]; if ($k -and -not $repoDir.ContainsKey($k)) { $repoDir[$k] = $projs[$n] } }
    if (Test-PhienTimeUp) { return (Stop-PhienAtCap $Quick $stat) }   # safe point: before the scan
    $r = Invoke-BoxPy 'scan' ([Text.Encoding]::UTF8.GetBytes((@{ projects = @($names); repos = @($repoDir.Keys); clean = (-not $DryRun) } | ConvertTo-Json -Compress)))
    $scan = Get-BoxJson $r
    if ($scan) { Save-PrefsCache $scan.prefs }
    if (-not $scan) {
      if ($Quick -and $r.Code -eq 124) { Set-PhienScreen $capMsg; return 0 }   # the deadline ended the call: a cap hit, not an error
      $stat.ok = $false
      Write-PhienOut "lỗi: không nói chuyện được với box. Kiểm tra: gõ ssh $box có vào được không (alias trong ~/.ssh/config)."
      $d = ("$($r.Err)" -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1); if ($d) { Write-PhienOut "  (chi tiết: $($d.Trim()))" }
      return 1
    }
    $rnow = [double]$scan.now
    $stat.ompB = [string]$scan.omp
    $boxBlobs = Get-PhienBoxBlobSet $scan.blobs
    $boxBlobNames = @{}
    foreach ($n in @($scan.blobs)) { if (([string]$n) -match '\A([a-f0-9]{64})') { $hx = $Matches[1]; if (-not $boxBlobNames.ContainsKey($hx)) { $boxBlobNames[$hx] = New-Object System.Collections.ArrayList }; [void]$boxBlobNames[$hx].Add([string]$n) } }
    $boxBlobSize = @{}; if ($scan.blobsize) { foreach ($pr in $scan.blobsize.PSObject.Properties) { $boxBlobSize[$pr.Name] = [long]$pr.Value } }
    $lblobIx = Get-OmpBlobIndex $laptopBlobDir
    # trung ten luon thang; khop theo repo chi lay thu muc chua project nao dung
    $ctx = @(); $used = @{}; $pick = @{}
    foreach ($bp in @($scan.projects)) { $ld = $projs[[string]$bp.name]; if ($ld) { $pick[[string]$bp.name] = $ld; $used[$ld] = $true } }
    foreach ($bp in @($scan.projects)) {
      $ld = if ($bp.repo) { $repoDir[[string]$bp.repo] } else { $null }
      if (-not $pick.ContainsKey([string]$bp.name) -and $ld -and -not $used.ContainsKey($ld)) { $pick[[string]$bp.name] = $ld; $used[$ld] = $true }
    }
    foreach ($bp in @($scan.projects)) {
      if (Test-PhienTimeUp) { return (Stop-PhienAtCap $Quick $stat) }   # safe point: before the local scan of a project
      $ldir = $pick[[string]$bp.name]
      if (-not $ldir -and $bp.repo -and $repoDir.ContainsKey([string]$bp.repo)) { continue }   # thu muc cua repo nay da thuoc project khac
      if (-not $ldir -or -not (Test-Path -LiteralPath $ldir)) { Write-PhienOut "== $(Format-ProjectName ([string]$bp.name)): bỏ qua, không thấy thư mục project trên laptop"; continue }
      $lsd = Join-Path $sessRoot (Get-LaptopEncodedDir $ldir)
      $ctx += [pscustomobject]@{ Name = [string]$bp.name; LDir = $ldir; BDir = [string]$bp.dir; Lsd = $lsd; Benc = [string]$bp.enc; L = (Get-PhienLocalScan $lsd); R = @($bp.sessions); LN = (Get-PhienLocalNotes $ldir); RN = $bp.notes }
    }
    # project moi tren box chua co tren laptop: chi ghi lai (lan tu dong khong hoi, khong clone; `fcode sync` moi them)
    if (-not $Only) {
      $stat.newProjects = @(@($scan.all) | Where-Object { $_ -and -not $projs.Contains([string]$_.name) -and -not ($_.repo -and $repoDir.ContainsKey([string]$_.repo)) } | ForEach-Object { [string]$_.name })
      if ($stat.newProjects.Count) { Write-PhienOut "project trên box chưa có trên laptop: $(@($stat.newProjects | ForEach-Object { Format-ProjectName $_ }) -join ', ') (chạy fcode sync để thêm)" }
    }
    if (-not $DryRun) { Clear-PhienLeftovers @(@($ctx | ForEach-Object { $_.Lsd }) + @($laptopBlobDir)) @($ctx | ForEach-Object { $_.LDir }) }
    # lan 1: tim cac cho can hash cua box; hoi mot lan; lan 2: ke hoach that
    $hashes = @{}
    $need = @()
    foreach ($c in $ctx) {
      $need += @((Get-PhienPlan $c.L $c.R $c.Benc @{} $c.Lsd $lnow $rnow $PhienBusySec $lblobIx $boxBlobs).Need)
    }
    if ($need.Count -gt 0) {
      if (Test-PhienTimeUp) { return (Stop-PhienAtCap $Quick $stat) }   # safe point: before the hash call
      $q = @{ q = @($need | ForEach-Object { @{ enc = $_.enc; rel = $_.rel; len = $_.len } }) } | ConvertTo-Json -Compress -Depth 4
      $hr = Invoke-BoxPy 'hash' ([Text.Encoding]::UTF8.GetBytes($q))
      if ($Quick -and $hr.Code -eq 124) { Set-PhienScreen $capMsg; return 0 }   # the deadline ended the call: a cap hit, not a warning
      $h = Get-BoxJson $hr
      if ($h) { foreach ($pr in $h.h.PSObject.Properties) { $hashes[$pr.Name] = $pr.Value } }
      else { Write-PhienOut 'cảnh báo: không so sánh được các phiên đã đổi ở hai máy, bỏ qua chúng lần này' }
    }
    $tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('fcode-phien-' + $PID + '-' + [guid]::NewGuid().ToString('N'))   # PID: a later run sees when its owner is gone
    try {
      $putU = New-Object System.Collections.ArrayList; $getU = New-Object System.Collections.ArrayList
      $putN = New-Object System.Collections.ArrayList; $getN = New-Object System.Collections.ArrayList
      $ensure = New-Object System.Collections.ArrayList; $unexcl = New-Object System.Collections.ArrayList
      $noteDel = New-Object System.Collections.ArrayList; $relPend = @{}
      $nPutSess = 0; $nGetSess = 0; $nSame = 0; $planIncomplete = 0
      $plans = @{}; $queuedBlob = @{}
      $noteState = Read-PhienNoteState; $noteRec = @{}; $noteShaPut = @{}; $noteGetInfo = @{}; $noteSkipped = 0; $fileSkipped = 0
      # every note plan first (a pure function): the project dirs whose release of a name on the laptop is planned in this run hold nothing for the
      # others (Test-PhienSharedNote); the box gets the same set through the one batch that carries every unexclude item
      $nps = @{}; $relL = @{}
      foreach ($c in $ctx) {
        $nps[$c.Name] = Get-PhienNotePlan $c.Name $c.LN $c.RN $noteState $lnow $rnow $PhienBusySec
        foreach ($rl in $nps[$c.Name].Release) { if ($rl.OldOn -eq 'laptop') { if (-not $relL.ContainsKey($rl.Name)) { $relL[$rl.Name] = New-Object System.Collections.ArrayList }; [void]$relL[$rl.Name].Add($c.LDir) } }
      }
      foreach ($c in $ctx) {
        $plan = Get-PhienPlan $c.L $c.R $c.Benc $hashes $c.Lsd $lnow $rnow $PhienBusySec $lblobIx $boxBlobs
        $plans[$c.Name] = $plan
        $nSame += $plan.Same; $planIncomplete += $plan.Incomplete + $plan.Deferred
        $stat.unknown += @($plan.Unknown); $stat.diverged += $plan.Diverged
        $np = $nps[$c.Name]
        foreach ($cf in $np.Conflicts) { $stat.noteConf += $cf }
        foreach ($k in $np.Record.Keys) { $noteRec[$k] = $np.Record[$k] }
        foreach ($rl in $np.Release) {
          $rk = "$($c.Name)/$($rl.Name)"
          $relLine = "  [$($c.Name)] ghi chú $($rl.Name) giờ do git theo dõi (trên $($rl.TrackedOn)): bản cũ trên $($rl.OldOn) xóa được, fcode không còn đồng bộ file này"
          # the release line (and notes.released, the menu's "xóa được") only when the old copy really can go (removed / absent / True): a kept pair gets
          # the kept line alone and a failed release the error line alone. A dry run asks nothing: its line as before. The box answer comes with the put result ($relPend)
          if ($DryRun) { $stat.noteReleased += $rk; Write-PhienOut $relLine }
          else {
            if ($rl.OldOn -eq 'laptop') {
              # the records go only when the line is gone for sure (removed now, or not there): else they stay and the next run tries again.
              # The path is the one the scan resolved (no git call inside Remove-PhienNoteExclude); the shared-note check (git calls) runs before it,
              # only while fcode's line is still there: another project on the same repository that still depends on the line keeps it (nothing is
              # forgotten); a git failure there is an error, not a keep (Get-PhienLaptopRelease)
              $rs = Get-PhienLaptopRelease $c.LDir $c.LN.excl $rl.Name $rl.Legacy @($relL[$rl.Name] | Where-Object { $_ -ne $c.LDir })
              if ($rs -eq 'kept') { Write-PhienOut "  [$($c.Name)] ghi chú $($rl.Name): dự án khác cùng kho trên laptop còn dùng dòng giấu /$($rl.Name), fcode chưa gỡ" }
              else {
                if ($rs -ne 'failed') { $stat.noteReleased += $rk; Write-PhienOut $relLine; [void]$noteDel.Add("exclude:laptop:$rk"); [void]$noteDel.Add($rk) }
                else { $code = 1; Write-PhienOut "  [$($c.Name)] lỗi: ghi chú $($rl.Name): chưa gỡ được dòng /$($rl.Name) của fcode trong .git/info/exclude (liên kết, hoặc git lỗi / không trả lời kịp), lần sau thử lại" }
              }
            }
            else { $relPend[$rk] = $relLine; [void]$unexcl.Add(@{ project = $c.Name; name = $rl.Name; legacy = $rl.Legacy }) }
          }
        }
        if ($DryRun) {
          foreach ($n in $np.Put) { Write-PhienOut "  [$($c.Name)] sẽ gửi lên box: ghi chú $($n.Name)" }
          foreach ($n in $np.Get) { Write-PhienOut "  [$($c.Name)] sẽ lấy về laptop: ghi chú $($n.Name)" }
          foreach ($it in $plan.Put) { Write-PhienOut ("  [$($c.Name)] sẽ gửi lên box: " + (Format-PhienItem $it)) }
          foreach ($it in $plan.Get) { Write-PhienOut ("  [$($c.Name)] sẽ lấy về laptop: " + (Format-PhienItem $it)) }
          continue
        }
        # cac phan se chep (moi phan mot file), theo thu tu: ghi chu; roi tung phien: blob, file di kem, .jsonl long ben trong, file chinh
        $lnm = @{}; foreach ($f in @($c.LN.files)) { $lnm[[string]$f.name] = $f }
        $rnm = @{}; foreach ($f in @($c.RN.files)) { $rnm[[string]$f.name] = $f }
        foreach ($n in $np.Put) { [void]$putN.Add(@{ K = 'note'; C = $c; Name = $n.Name; Size = [long]$lnm[$n.Name].size; Expect = $n.Expect; Sha = $n.Sha }) }
        foreach ($n in $np.Ensure) { [void]$ensure.Add(@{ project = $c.Name; name = $n }) }
        foreach ($n in $np.Get) { [void]$getN.Add(@{ K = 'note'; C = $c; Name = $n.Name; Size = [long]$rnm[$n.Name].size }); $noteGetInfo["$($c.Name)/$($n.Name)"] = $n }
        $lsz = @{}; foreach ($s in @($c.L)) { $lsz[[string]$s.name] = [long]$s.size; foreach ($f in @($s.files)) { $lsz[[string]$f.rel] = [long]$f.size } }
        $rsz = @{}; foreach ($s in @($c.R)) { $rsz[[string]$s.name] = [long]$s.size; foreach ($f in @($s.files)) { $rsz[[string]$f.rel] = [long]$f.size } }
        foreach ($dir in 'put', 'get') {
          $items = $plan.Put; $us = $putU; $sz = $lsz   # plain assignments: an `if` expression would unroll an empty list to $null
          if ($dir -eq 'get') { $items = $plan.Get; $us = $getU; $sz = $rsz }
          foreach ($it in $items) {
            $bigBlob = $false
            foreach ($hx in @($it.Blobs)) {
              $bns = if ($dir -eq 'put') { @($lblobIx[$hx]) } else { @($boxBlobNames[$hx]) }
              foreach ($bn in $bns) {
                if (-not $bn) { continue }
                $bsz = if ($dir -eq 'put') { (Get-Item -LiteralPath (Join-Path $laptopBlobDir $bn)).Length } else { [long]$boxBlobSize[[string]$bn] }
                if ((Get-PhienUnitBytes ([long]$bsz) ([string]$bn)) -gt $PhienBatchLimit) { $bigBlob = $true }
                if ($queuedBlob.ContainsKey("$dir/$bn")) { continue }
                $queuedBlob["$dir/$bn"] = $true
                [void]$us.Add(@{ K = 'blob'; Name = [string]$bn; Size = [long]$bsz })
              }
            }
            foreach ($rel in @(@($it.Files | Where-Object { -not $_.EndsWith('.jsonl') }) + @($it.Files | Where-Object { $_.EndsWith('.jsonl') }))) { if ($rel) { [void]$us.Add(@{ K = 'file'; C = $c; Rel = $rel; Size = $sz[$rel] }) } }
            if ($it.Top) {
              # file chinh cua phien co file qua 50 MB: dat sau dot cua file do (cung lan chay), khong thi phai cho lan sau
              $late = $bigBlob -or @(@($it.Files) | Where-Object { $_ -and (Get-PhienUnitBytes ([long]$sz[$_]) $_) -gt $PhienBatchLimit }).Count -gt 0
              [void]$us.Add(@{ K = 'top'; C = $c; Rel = $it.Name; Size = $sz[$it.Name]; Deps = @($it.Deps); DepBlobs = @($it.DepBlobs); Late = $late })
              if ($dir -eq 'put') { $nPutSess++ } else { $nGetSess++ }
            }
          }
        }
      }
      foreach ($c in $ctx) {
        $pl = $plans[$c.Name]
        foreach ($nt in $pl.Notes) { Write-PhienOut "  [$($c.Name)] $nt" }
      }
      foreach ($cf in $stat.noteConf) { Write-PhienOut ('  ' + ($cf -replace '/.*$', '') + ': handoff ' + ($cf -replace '^[^/]*/', '') + ' khác nhau ở hai máy, giữ nguyên cả hai') }
      $un = Get-PhienUnknownNote $stat.unknown; if ($un) { Write-PhienOut $un }
      $vn = Get-PhienVersionNote $stat.ompL $stat.ompB; if ($vn) { Write-PhienOut $vn }
      if ($DryRun) { Write-PhienOut "Chạy thử (--thu): chưa chép gì (chỉ ghi lại giờ vừa kết nối box). $nSame phiên đã giống nhau."; return 0 }
      # chia dot: <= 50 MB moi dot, tinh ca phan tar them vao; mot file lon hon thi di mot minh mot dot
      $est = { param($u) $x = [long]0; if ($u.K -eq 'top') { foreach ($d in @($u.Deps)) { if ($d) { $x += 3 * ([string]$d.r).Length + 40 } }; $x += 70 * @($u.DepBlobs).Count }; Get-PhienUnitBytes ([long]$u.Size) $(if ($u.Rel) { [string]$u.Rel } else { [string]$u.Name }) $x }
      $putB = New-Object System.Collections.ArrayList; $getB = New-Object System.Collections.ArrayList
      $putLB = New-Object System.Collections.ArrayList; $getLB = New-Object System.Collections.ArrayList
      foreach ($u in @(@($putN) + @($putU))) { if ($u.Late) { [void](Get-PhienBatch $putLB (Join-Path $tmpRoot 'putlate') (& $est $u) $PhienBatchLimit).Items.Add($u) } else { [void](Get-PhienBatch $putB (Join-Path $tmpRoot 'put') (& $est $u) $PhienBatchLimit).Items.Add($u) } }
      foreach ($u in @(@($getN) + @($getU))) { if ($u.Late) { [void](Get-PhienBatch $getLB (Join-Path $tmpRoot 'getlate') (& $est $u) $PhienBatchLimit).Items.Add($u) } else { [void](Get-PhienBatch $getB (Join-Path $tmpRoot 'get') (& $est $u) $PhienBatchLimit).Items.Add($u) } }
      $bigName = { param($b) if ($b.Items.Count -eq 1 -and $b.Bytes -gt $PhienBatchLimit) { $u = $b.Items[0]; if ($u.Rel) { [string]$u.Rel } else { [string]$u.Name } } }
      # exclude / go exclude cua ghi chu di cung dot gui THUONG dau tien (dot qua lon chay sau cung va co the hong), khong co thi mot dot rong
      $nb = $null; foreach ($bb in $putB) { if (-not (& $bigName $bb)) { $nb = $bb; break } }
      if (($ensure.Count -or $unexcl.Count) -and -not $nb) { $nb = New-PhienBatch (Join-Path $tmpRoot 'put\notes'); [void]$putB.Add($nb) }
      if ($nb) { foreach ($x in $ensure) { [void]$nb.Ensure.Add($x) }; foreach ($x in $unexcl) { [void]$nb.Unexclude.Add($x) } }
      $notePlanned = $putN.Count; $placedPut = 0
      # every write of handoff-state.json is strict: a failed write stops the run there with the file name and the reason
      $saveNotes = { if ($noteRec.Count -or $noteDel.Count) { foreach ($k in $noteRec.Keys) { $noteState[$k] = $noteRec[$k] }; foreach ($k in $noteDel) { $noteState.Remove([string]$k) }; try { Write-PhienNoteState $noteState } catch { throw "không ghi được trạng thái ghi chú (handoff-state.json): $($_.Exception.Message)" } } }
      $deferredTops = New-Object System.Collections.ArrayList; $busyFiles = New-Object System.Collections.ArrayList
      # --- mot dot gui len box (chep sang thu muc tam, doi cwd, dong goi, gui, xoa): 'ok' | 'fail' | 'lost' (ssh 255: mat box) ---
      $putRes = @{ new = 0; replaced = 0; same = 0; skip = 0; busy = 0; blobs = 0; failed = 0 }
      $doPut = {
        param($pb)
        [void](New-Item -ItemType Directory -Path $pb.Dir -Force)
        $mf = New-Object System.Collections.ArrayList; $mt = New-Object System.Collections.ArrayList; $mn = New-Object System.Collections.ArrayList
        foreach ($u in $pb.Items) {
          if ($u.K -eq 'blob') {
            $bd = Join-Path $pb.Dir 'blobs'; [void](New-Item -ItemType Directory -Path $bd -Force)
            Copy-Item -LiteralPath (Join-Path $laptopBlobDir $u.Name) -Destination (Join-Path $bd $u.Name)
          } elseif ($u.K -eq 'note') {
            $nd = Join-Path $pb.Dir ('notes\' + $u.C.Name); [void](New-Item -ItemType Directory -Path $nd -Force)
            $ns = Join-Path $nd $u.Name
            Copy-Item -LiteralPath (Join-Path $u.C.LDir $u.Name) -Destination $ns
            if ((Get-RangeSha $ns 0 (Get-Item -LiteralPath $ns).Length) -ne $u.Sha) { Remove-Item -LiteralPath $ns -Force; continue }   # changed while copying: next run
            [void]$mn.Add(@{ project = $u.C.Name; name = $u.Name; expect = $u.Expect; sha = $u.Sha }); $noteShaPut["$($u.C.Name)/$($u.Name)"] = $u.Sha
          } else {
            $src = Join-Path $u.C.Lsd ($u.Rel -replace '/', '\')
            $cur = Get-Item -LiteralPath $src -ErrorAction SilentlyContinue
            if (-not $cur -or $cur.Length -lt [long]$u.Size) { $fileSkipped++; continue }   # shrank since the scan: left for the next run
            [void](Copy-OmpSession $src (Join-Path $pb.Dir ('sessions\' + $u.C.Benc + '\' + ($u.Rel -replace '/', '\'))) $u.C.LDir $u.C.BDir ([long]$u.Size))
            if ($u.K -eq 'top') { [void]$mt.Add(@{ enc = $u.C.Benc; rel = $u.Rel; origin = 'laptop'; deps = @($u.Deps); blobs = @($u.DepBlobs) }) }
            else { [void]$mf.Add(@{ enc = $u.C.Benc; rel = $u.Rel }) }
          }
        }
        [IO.File]::WriteAllText((Join-Path $pb.Dir 'manifest.json'), (@{ files = @($mf); tops = @($mt); notes = @($mn); ensure = @($pb.Ensure); unexclude = @($pb.Unexclude) } | ConvertTo-Json -Compress -Depth 6), (New-Object Text.UTF8Encoding($false)))
        $tarFile = $pb.Dir + '.tar'
        $tr = Invoke-PhienExe (Find-TarExe) @('-cf', $tarFile, '-C', $pb.Dir, '.')
        if ($tr.Code -eq 124) { Remove-Item -LiteralPath $tarFile, $pb.Dir -Recurse -Force -ErrorAction SilentlyContinue; return 'cap' }   # tar ran into the deadline
        if ($tr.Code -ne 0) { throw 'tar không đóng gói được' }
        $rp = Invoke-BoxPy 'put' $null $tarFile
        $res = Get-BoxJson $rp
        Remove-Item -LiteralPath $tarFile, $pb.Dir -Recurse -Force -ErrorAction SilentlyContinue   # free the disk before the next batch
        if (-not $res -and $Quick -and $rp.Code -eq 124) { return 'cap' }   # the deadline ended the call: not an error, the next run sends it
        if (-not $res) { Write-PhienOut 'lỗi: gửi phiên lên box không thành công (đợt này để lần tới)'; if ($rp.Code -eq 255) { return 'lost' }; return 'fail' }
        foreach ($k in @($putRes.Keys)) { $putRes[$k] += [int]$res.$k }
        foreach ($x in @($res.deferred)) { if ($x) { [void]$deferredTops.Add([string]$x) } }
        foreach ($x in @($res.busyFiles)) { if ($x) { [void]$busyFiles.Add([string]$x) } }
        foreach ($k in @($res.notePlaced)) { if ($k) { $noteRec[[string]$k] = $noteShaPut[[string]$k]; $stat.noteCopied++; $placedPut++ } }
        foreach ($k in @($res.unexcluded)) { if ($k) { [void]$noteDel.Add("exclude:box:$k"); [void]$noteDel.Add([string]$k) } }
        # a release the box could not do (git could not name its exclude file or did not answer, the exclude file or .git/info is a link, a read / write of it failed with an OSError, or .fcode/.gitignore could not be verified to hold `*`): a failure, nothing forgotten, the next run tries again
        # a release a sharing box project still depends on is kept (the box answers noteKept): a notice, not a failure, nothing forgotten
        foreach ($k in @($res.noteKept)) { if ($k) { $kp = ([string]$k).IndexOf('/'); Write-PhienOut "  [$(([string]$k).Substring(0, $kp))] ghi chú $(([string]$k).Substring($kp + 1)): dự án khác cùng kho trên box còn dùng dòng giấu /$(([string]$k).Substring($kp + 1)), fcode chưa gỡ" } }
        # the release line and notes.released only for a real removal (the kept line above and the error line are alone); a batch that never got an answer prints neither (next run)
        foreach ($x in @($pb.Unexclude)) {
          $xk = "$($x.project)/$($x.name)"
          if (@($res.noteKept) -contains $xk) { continue }
          if (@($res.unexcluded) -contains $xk) { $stat.noteReleased += $xk; Write-PhienOut $relPend[$xk] }
          else { $code = 1; Write-PhienOut "  [$($x.project)] lỗi: ghi chú $($x.name): box chưa gỡ được dòng /$($x.name) của fcode trong .git/info/exclude (liên kết, git trên box lỗi, hoặc chưa tạo được .fcode/.gitignore), lần sau thử lại" }
        }
        & $saveNotes
        'ok'
      }
      # --- mot dot lay ve laptop; dot loi (cat ngang, het gio) thi khong dat gi cua dot do ---
      $getRes = @{ new = 0; replaced = 0; same = 0; skip = 0; busy = 0; blobs = 0; failed = 0 }
      $mk = [Text.Encoding]::ASCII.GetBytes("FCODE-TAR`n")
      $doGet = {
        param($gbt)
        $qf = New-Object System.Collections.ArrayList; $qb = New-Object System.Collections.ArrayList; $qn = New-Object System.Collections.ArrayList
        foreach ($u in $gbt.Items) {
          if ($u.K -eq 'blob') { [void]$qb.Add($u.Name) } elseif ($u.K -eq 'note') { [void]$qn.Add(@{ project = $u.C.Name; name = $u.Name }) } else { [void]$qf.Add(@{ enc = $u.C.Benc; rel = $u.Rel; size = [long]$u.Size }) }
        }
        $req = @{ files = @($qf); blobs = @($qb); notes = @($qn) } | ConvertTo-Json -Compress -Depth 5
        $g = Invoke-BoxPy 'get' ([Text.Encoding]::UTF8.GetBytes($req))
        $gcode = $g.Code; $pos = -1
        if ($g.Code -eq 0) {
          for ($i = 0; $i -le $g.Out.Length - $mk.Length; $i++) {
            if ($g.Out[$i] -eq $mk[0]) { $ok = $true; for ($j = 1; $j -lt $mk.Length; $j++) { if ($g.Out[$i + $j] -ne $mk[$j]) { $ok = $false; break } }; if ($ok) { $pos = $i + $mk.Length; break } }
            if ($i -gt 65536) { break }
          }
        }
        $gt = $gbt.Dir; $gtar = $gt + '.tar'; $xok = $false
        if ($pos -ge 0) {
          [void](New-Item -ItemType Directory -Path $gt -Force)
          $fsT = [IO.File]::Create($gtar); try { $fsT.Write($g.Out, $pos, $g.Out.Length - $pos) } finally { $fsT.Dispose() }
          $tr = Invoke-PhienExe (Find-TarExe) @('-xf', $gtar, '-C', $gt)
          $xok = ($tr.Code -eq 0)
        }
        $g = $null
        if (-not $xok) {
          Remove-Item -LiteralPath $gtar, $gt -Recurse -Force -ErrorAction SilentlyContinue
          if (($Quick -and $gcode -eq 124) -or ($pos -ge 0 -and $tr.Code -eq 124)) { return 'cap' }   # the deadline ended the call or tar: not an error, the next run fetches it
          Write-PhienOut 'lỗi: lấy phiên từ box về không thành công (đợt này để lần tới)'
          if ($gcode -eq 255) { return 'lost' }; return 'fail'
        }
        $gnow = ConvertTo-Epoch (Get-Date)
        # 1. blob
        foreach ($u in @($gbt.Items | Where-Object { $_.K -eq 'blob' })) {
          $f = Join-Path $gt ('blobs\' + $u.Name)
          if ($u.Name -notmatch '^[a-f0-9]{64}(?:\.[A-Za-z0-9][A-Za-z0-9._-]{0,31})?$' -or -not (Test-Path -LiteralPath $f) -or (Get-Item -LiteralPath $f).Length -ne [long]$u.Size) { continue }
          $dst = Join-Path $laptopBlobDir $u.Name
          if (Test-Path -LiteralPath $dst) { continue }
          $part = New-PhienPartName (Join-Path $laptopBlobDir ('.' + $u.Name))
          try { [void](New-Item -ItemType Directory -Path $laptopBlobDir -Force -ErrorAction Stop); [IO.File]::Copy($f, $part, $true); [IO.File]::Move($part, $dst); $getRes.blobs++ }
          catch { $getRes.failed++; Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
        }
        $lblobIx = Get-OmpBlobIndex $laptopBlobDir
        # 2. file di kem, roi .jsonl long ben trong; 3. file chinh, chi khi moi thu no can da co tren laptop
        $files = @($gbt.Items | Where-Object { $_.K -eq 'file' })
        foreach ($u in @(@($files | Where-Object { -not $_.Rel.EndsWith('.jsonl') }) + @($files | Where-Object { $_.Rel.EndsWith('.jsonl') }) + @($gbt.Items | Where-Object { $_.K -eq 'top' }))) {
          if (-not $u) { continue }
          $src = Join-Path $gt ('sessions\' + $u.C.Benc + '\' + ($u.Rel -replace '/', '\'))
          if (-not (Test-Path -LiteralPath $src) -or (Get-Item -LiteralPath $src).Length -ne [long]$u.Size) { continue }   # left out by the box (being written, shrank)
          if ($u.K -eq 'top' -and -not (Test-PhienDeps $u.C.Lsd $u.Deps $u.DepBlobs $lblobIx)) { [void]$deferredTops.Add([string]$u.Rel); continue }
          try { $st = Install-PhienFile $src (Join-Path $u.C.Lsd ($u.Rel -replace '/', '\')) $u.C.BDir $u.C.LDir $gnow $PhienBusySec } catch { $st = 'failed' }
          $getRes[$st]++
        }
        # 4. ghi chu: each note is an item of its own (it runs git), so the deadline is checked before each one
        $cut = $false
        foreach ($u in @($gbt.Items | Where-Object { $_.K -eq 'note' })) {
          $src = Join-Path $gt ('notes\' + $u.C.Name + '\' + $u.Name)
          $key = "$($u.C.Name)/$($u.Name)"; $info = $noteGetInfo[$key]
          if (Test-PhienTimeUp) { $cut = $true }   # safe point: before a note
          if ($cut -or -not (Test-Path -LiteralPath $src)) { $noteSkipped++; continue }
          $ns = Install-PhienNote $src $u.C.LDir $u.Name $info.Expect $gnow $PhienBusySec ([string]$info.Sha)
          if ($ns -eq 'ok') { $noteRec[$key] = [string]$info.Sha; $stat.noteCopied++ } else { $noteSkipped++ }
          if ($ns -eq 'timeout') { $cut = $true; Write-PhienOut "  [$($u.C.Name)] ghi chú $($u.Name): git không trả lời kịp, chưa đặt (lần sau làm tiếp)" }
          if ($ns -eq 'link') { Write-PhienOut "  [$($u.C.Name)] ghi chú $($u.Name): .git/info/exclude là liên kết, fcode không ghi vào đó, chưa đặt" }
        }
        Remove-Item -LiteralPath $gtar, $gt -Recurse -Force -ErrorAction SilentlyContinue
        & $saveNotes
        if ($cut) { 'cap' } else { 'ok' }
      }
      # --- thu tu: moi dot thuong (<= 50 MB) truoc, lay ve roi gui len; roi moi dot mot file qua lon, nho truoc; sau cung file chinh cua cac phien do.
      # Dot loi thi ghi lai roi lam dot sau; chi het gio cua lan chay hoac mat box (ssh 255) moi dung han.
      $jobs = New-Object System.Collections.ArrayList; $big = New-Object System.Collections.ArrayList
      foreach ($bb in $getB) { if (& $bigName $bb) { [void]$big.Add(@{ D = 'get'; B = $bb }) } else { [void]$jobs.Add(@{ D = 'get'; B = $bb }) } }
      foreach ($bb in $putB) { if (& $bigName $bb) { [void]$big.Add(@{ D = 'put'; B = $bb }) } else { [void]$jobs.Add(@{ D = 'put'; B = $bb }) } }
      if ($Quick) {
        # a quick run (the hook, 20 s) never starts a batch of one file over 50 MB, nor the late batch waiting for it: the auto run or `fcode phien` sends them
        foreach ($bb in @(@($big | ForEach-Object { $_.B }) + @($getLB) + @($putLB))) {
          if (-not $bb) { continue }
          $bn = & $bigName $bb; if (-not $bn) { $bn = @($bb.Items | ForEach-Object { if ($_.Rel) { [string]$_.Rel } else { [string]$_.Name } }) -join ', ' }
          Write-PhienOut "phiên lớn: $bn — lần nhanh không chép, để lần tự động hoặc fcode phien"; $fileSkipped++
        }
      } else {
        foreach ($job in @($big | Sort-Object { [long]$_.B.Bytes })) { [void]$jobs.Add($job) }
        foreach ($bb in $getLB) { [void]$jobs.Add(@{ D = 'get'; B = $bb }) }; foreach ($bb in $putLB) { [void]$jobs.Add(@{ D = 'put'; B = $bb }) }
      }
      foreach ($job in $jobs) {
        if (Test-PhienTimeUp) { if ($Quick) { $capHit = $true } else { Write-PhienOut 'hết thời gian của lượt này: phần còn lại để lần sau'; $code = 1 }; break }
        $st = if ($job.D -eq 'put') { . $doPut $job.B } else { . $doGet $job.B }
        if ("$st" -eq 'ok') { continue }
        if ("$st" -eq 'cap') { if ($Quick) { $capHit = $true } else { Write-PhienOut 'hết thời gian của lượt này: phần còn lại để lần sau'; $code = 1 }; break }
        $code = 1
        $bn = & $bigName $job.B; if ($bn) { Write-PhienOut "phiên lớn: $bn chưa chép xong — chạy fcode phien khi mạng tốt"; $stat.unfinished += $bn }
        if ("$st" -eq 'lost') { Write-PhienOut 'lỗi: mất kết nối với box, phần còn lại để lần sau'; break }
      }
      $noteSkipped += $notePlanned - $placedPut
      # --- bao cao ---
      $up = [int]$putRes.new + [int]$putRes.replaced
      $down = [int]$getRes.new + [int]$getRes.replaced
      foreach ($c in $ctx) { $pl = $plans[$c.Name]; Write-PhienOut ("== $(Format-ProjectName $c.Name): gửi $(@($pl.Put | Where-Object { $_.Top }).Count) phiên lên box, lấy $(@($pl.Get | Where-Object { $_.Top }).Count) phiên về, $($pl.Same) đã giống nhau") }
      if ($deferredTops.Count) { Write-PhienOut "$($deferredTops.Count) phiên chưa đặt file chính vì file đi kèm chưa đủ, lần sau làm tiếp" }
      if ($busyFiles.Count) { Write-PhienOut "$($busyFiles.Count) file đang mở trên box (omp đang chạy phiên đó), để lần sau" }
      $failed = [int]$putRes.failed + [int]$getRes.failed
      if ($failed) { Write-PhienOut "lỗi: $failed file chưa ghi được ở máy nhận, lần sau làm tiếp"; $code = 1 }
      $skipped = [int]$getRes.skip + [int]$getRes.busy + [int]$putRes.skip + [int]$putRes.busy
      if ($skipped) { Write-PhienOut "$skipped file được giữ nguyên vì đã khác nhau hoặc đang được ghi" }
      $stat.copied = $up + $down; $stat.skipped = $skipped + $fileSkipped + @($plans.Values | ForEach-Object { $_.Notes } | Where-Object { $_ -like '*đang được ghi*' }).Count
      if ($stat.noteCopied -or $stat.noteConf.Count) { Write-PhienOut "ghi chú dự án: chép $($stat.noteCopied), xung đột $($stat.noteConf.Count)" }
      & $saveNotes
      $stat.skipped += $noteSkipped
      $open = $planIncomplete + $deferredTops.Count + $busyFiles.Count + $failed + $fileSkipped + $code + [int]$capHit
      Write-PhienOut ("Xong: $up file gửi lên box, $down file lấy về laptop" + $(if ($up + $down -eq 0 -and $open -eq 0) { ' (hai bên đã giống nhau)' } else { '' }))
      if (-not $Auto -and -not $Quick -and ($nPutSess + $nGetSess) -gt 0) { Write-PhienOut 'Nhớ đẩy code lên GitHub trước (git push) để hai bên cùng một bản code.' }
      # the cap line only when nothing failed for real: a real error keeps its exit code and its own one line
      if ($capHit) { if ($code -eq 0) { Set-PhienScreen $capMsg } else { Write-PhienOut $capMsg } }
    } finally { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if ($code -ne 0) { $stat.ok = $false }
    return $code
  } catch {
    $stat.ok = $false
    Write-PhienOut ('lỗi: ' + $_.Exception.Message)
    return 1
  } finally {
    if ($stat.ran -and -not $DryRun) { Write-PhienStatus $stat $Auto }
    if ($mx) { if ($held) { try { $mx.ReleaseMutex() } catch { } }; $mx.Dispose() }
  }
}

# mot dong cho che do chay thu: ma phien (8 ky tu dau) va so file
function Format-PhienItem($it) {
  $id = [string]$it.Id; if ($id.Length -gt 8) { $id = $id.Substring(0, 8) }
  $n = @($it.Files).Count + @($it.Blobs | Where-Object { $_ }).Count
  if ($it.Top) { if ($n) { "phiên $id (và $n file đi kèm)" } else { "phiên $id" } } else { "$n file đi kèm của phiên $id" }
}

# --- ghi chu goc project (HANDOFF*.md, CLAUDE.md, AGENTS.md, WORKFLOW.md, agent_state.md, TASK.md, CLAUDE.local.md) ---
# Hai chieu cung luot dong bo, chi khi git KHONG theo doi file do o ben nao. Trang thai: %LOCALAPPDATA%\fcode\handoff-state.json
# (sha256 lan dong bo cuoi theo project/file). Khong bao gio xoa; hai ben cung doi -> giu nguyen va bao.
function Get-PhienNoteRx { '\A(?:HANDOFF[^/\\]*\.md|CLAUDE\.md|AGENTS\.md|WORKFLOW\.md|agent_state\.md|TASK\.md|CLAUDE\.local\.md)\z' }
function Get-PhienNoteSpecs { , @(':(glob)HANDOFF*.md', 'CLAUDE.md', 'AGENTS.md', 'WORKFLOW.md', 'agent_state.md', 'TASK.md', 'CLAUDE.local.md') }

function Invoke-GitQuiet([string]$Dir, [string[]]$GitArgs, [string]$StdinText) {
  $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  $script:PhienLastGitCode = -1
  if (-not $git) { return [pscustomobject]@{ Code = -1; Out = @(); Err = '' } }
  $old = $env:LC_ALL; $env:LC_ALL = 'C'   # git's messages stay English ("not a git repository" is matched); the child inherits the process environment. Never the ProcessStartInfo environment dictionary: on Windows PowerShell 5.1 its getter fails when two names differ only in case (Path/PATH from an MSYS parent) and git would not start at all
  try { $r = Invoke-PhienExe $git.Source (@('--no-optional-locks', '-C', $Dir, '-c', 'core.quotepath=false') + @($GitArgs)) $StdinText }   # bounded like every other child
  finally { $env:LC_ALL = $old }   # $null / '' removes it again
  $script:PhienLastGitCode = $r.Code
  [pscustomobject]@{ Code = $r.Code; Out = @($r.Out); Err = [string]$r.Err }   # Code 124 = killed at its timeout: callers never read that as "git said no"
}

# ghi chu nam trong nhanh mac dinh cua origin (ban da fetch): git se mang file do toi, nen cung tinh la da theo doi (nhu box `upstream_names`)
# $null = git did not answer in time (124): unknown, never "nothing upstream"
function Get-PhienUpstreamNotes([string]$Dir) {
  $h = Invoke-GitQuiet $Dir @('symbolic-ref', '-q', 'refs/remotes/origin/HEAD')
  if ($h.Code -eq 124) { return $null }
  $ref = if ($h.Code -eq 0 -and @($h.Out)[0]) { [string]@($h.Out)[0] } else { '' }
  # khong co origin/HEAD (remote add + fetch): origin/main, roi origin/master
  foreach ($c in 'refs/remotes/origin/main', 'refs/remotes/origin/master') {
    if ($ref) { break }
    $v = Invoke-GitQuiet $Dir @('rev-parse', '-q', '--verify', $c)
    if ($v.Code -eq 124) { return $null }
    if ($v.Code -eq 0) { $ref = $c }
  }
  if (-not $ref) { return , @() }
  $r = Invoke-GitQuiet $Dir @('ls-tree', '--name-only', $ref)
  if ($r.Code -eq 124) { return $null }
  if ($r.Code -ne 0) { return , @() }
  $rx = Get-PhienNoteRx
  , @($r.Out | Where-Object { $_ -cmatch $rx } | Sort-Object)
}

# cung dang voi `scan_notes` cua box: @{gitok; tracked (index); upstream (origin/<mac dinh>); files = {name,size,mtime,sha,ign,fx}; excl}
# fx = the exclude file has fcode's pair for that name (Rule O); excl = the exclude file git names (the release reuses it: no git call there)
function Get-PhienLocalNotes([string]$Dir) {
  $nogit = [pscustomobject]@{ gitok = $false; tracked = @(); upstream = @(); files = @(); excl = '' }   # also when git did not answer in time: no note sync for it this run
  $r = Invoke-GitQuiet $Dir (@('ls-files', '--') + (Get-PhienNoteSpecs))
  if ($r.Code -ne 0) { return $nogit }
  # no answer for the exclude path, or a file that cannot be read: no note work for this project this run (never "no line of ours"); no file = no pair
  $ep = Invoke-GitQuiet $Dir @('rev-parse', '--git-path', 'info/exclude')
  $excl = [string]@($ep.Out)[0]
  if ($ep.Code -ne 0 -or -not $excl) { return $nogit }
  if (-not [IO.Path]::IsPathRooted($excl)) { $excl = Join-Path $Dir $excl }
  try { $ext = Read-PhienExcludeText $excl } catch { Write-PhienOut "  [$Dir] không đọc được .git/info/exclude ($($_.Exception.Message)), bỏ qua ghi chú của dự án này lần này"; return $nogit }
  $rx = Get-PhienNoteRx
  $files = New-Object System.Collections.ArrayList
  foreach ($f in (Get-ChildItem -LiteralPath $Dir -File -Force | Sort-Object Name)) {
    if ($f.Name -cnotmatch $rx) { continue }
    $ig = Invoke-GitQuiet $Dir @('check-ignore', '-q', '--', $f.Name)
    if ($ig.Code -eq 124) { return $nogit }
    [void]$files.Add([pscustomobject]@{ name = $f.Name; size = $f.Length; mtime = (ConvertTo-Epoch $f.LastWriteTimeUtc); sha = (Get-RangeSha $f.FullName 0 $f.Length); ign = ($ig.Code -eq 0); fx = (Test-PhienMarkedLine $ext $f.Name) })
  }
  $up = Get-PhienUpstreamNotes $Dir
  if ($null -eq $up) { return $nogit }
  [pscustomobject]@{ gitok = $true; tracked = @($r.Out | Where-Object { $_ -cmatch $rx } | Sort-Object); upstream = @($up); files = @($files); excl = $excl }
}

# ke hoach cho mot project: Put/Get = {Name; Expect (sha hien co o dich, '' neu chua co); Sha (sha noi dung se chep)};
# Record = {project/file -> sha} can ghi vao state; Ensure = file giong nhau tren box nhung git chua bo qua; Conflicts
function Get-PhienNotePlan([string]$Proj, $LN, $RN, $State, [double]$LNow, [double]$RNow, [int]$Busy = 30) {
  $put = New-Object System.Collections.ArrayList; $get = New-Object System.Collections.ArrayList
  $ensure = New-Object System.Collections.ArrayList; $conf = New-Object System.Collections.ArrayList; $rec = @{}
  $release = New-Object System.Collections.ArrayList
  if ($LN.gitok -and $RN.gitok) {
    # tracked = in either index, or in either side's origin/<default> (git brings it there with the next pull)
    $lt = @(@($LN.tracked) | Where-Object { $_ }); $rt = @(@($RN.tracked) | Where-Object { $_ })
    $up = @(@($LN.upstream) + @($RN.upstream) | Where-Object { $_ })
    $tracked = $lt + $rt + $up
    $lm = @{}; foreach ($f in @($LN.files)) { $lm[[string]$f.name] = $f }
    $rm = @{}; foreach ($f in @($RN.files)) { $rm[[string]$f.name] = $f }
    # git tracks a name now (other index or upstream) and fcode had placed + excluded the untracked copy on one side: stop syncing it
    # and give that one line back. Ownership = the "# fcode" pair in that side's exclude file (fx); the record only for a line 1.3.2/1.3.3
    # added (Legacy: then the bare line may go too)
    foreach ($n in @($lt + $up | Sort-Object -Unique)) { if (-not ($rt -ccontains $n) -and $rm[$n] -and ($rm[$n].fx -or $State["exclude:box:$Proj/$n"])) { [void]$release.Add([pscustomobject]@{ Name = $n; TrackedOn = $(if ($lt -ccontains $n) { 'laptop' } else { 'origin' }); OldOn = 'box'; Legacy = [bool]$State["exclude:box:$Proj/$n"] }) } }
    foreach ($n in @($rt + $up | Sort-Object -Unique)) { if (-not ($lt -ccontains $n) -and $lm[$n] -and ($lm[$n].fx -or $State["exclude:laptop:$Proj/$n"])) { [void]$release.Add([pscustomobject]@{ Name = $n; TrackedOn = $(if ($rt -ccontains $n) { 'box' } else { 'origin' }); OldOn = 'laptop'; Legacy = [bool]$State["exclude:laptop:$Proj/$n"] }) } }
    foreach ($n in @(@($lm.Keys) + @($rm.Keys) | Sort-Object -Unique)) {
      if ($tracked -ccontains $n) { continue }
      $l = $lm[$n]; $r = $rm[$n]; $key = "$Proj/$n"
      if ($l -and -not $r) { if ($LNow - $l.mtime -ge $Busy) { [void]$put.Add([pscustomobject]@{ Name = $n; Expect = ''; Sha = $l.sha }) }; continue }
      if ($r -and -not $l) { if ($RNow - $r.mtime -ge $Busy) { [void]$get.Add([pscustomobject]@{ Name = $n; Expect = ''; Sha = $r.sha }) }; continue }
      # same content on both: record it; the box gets its exclude line only for files that were identical from the start (no record yet),
      # never for a file that came from the box itself (the user may want to `git add` it there)
      if ($l.sha -eq $r.sha) { $rec[$key] = [string]$l.sha; if (-not $r.ign -and -not $State[$key]) { [void]$ensure.Add($n) }; continue }
      $last = [string]$State[$key]
      if ($last -and $last -eq $l.sha) { if ($RNow - $r.mtime -ge $Busy) { [void]$get.Add([pscustomobject]@{ Name = $n; Expect = [string]$l.sha; Sha = $r.sha }) } }
      elseif ($last -and $last -eq $r.sha) { if ($LNow - $l.mtime -ge $Busy) { [void]$put.Add([pscustomobject]@{ Name = $n; Expect = [string]$r.sha; Sha = $l.sha }) } }
      else { [void]$conf.Add($key) }
    }
  }
  [pscustomobject]@{ Put = @($put); Get = @($get); Ensure = @($ensure); Conflicts = @($conf); Record = $rec; Release = @($release) }
}

# the repository a folder belongs to and where the folder sits in it, from git itself (it resolves junction aliases, `..` and slashes):
# @{ Common = the shared .git dir; Root = the folder's own root (work tree top + prefix) }; $null = git said "not a git repository" (rc 128 and that
# message); 'unknown' = anything else (no answer in time, git missing or not started, any other failure). This call never reads the index
function Get-PhienRepoId([string]$Dir) {
  # asked once per folder for the run ($script:PhienRepoIds is reset at the start of each run)
  if (-not $script:PhienRepoIds) { $script:PhienRepoIds = @{} }
  $k = $Dir.ToLowerInvariant()
  if (-not $script:PhienRepoIds.ContainsKey($k)) { $script:PhienRepoIds[$k] = Get-PhienRepoIdNow $Dir }
  $script:PhienRepoIds[$k]
}
function Get-PhienRepoIdNow([string]$Dir) {
  $r = Invoke-GitQuiet $Dir @('rev-parse', '--git-common-dir', '--show-toplevel', '--show-prefix')
  if ($r.Code -eq 128 -and "$($r.Err)" -match 'not a git repository') { return $null }
  $o = @($r.Out)
  if ($r.Code -ne 0 -or $o.Count -lt 2) { return 'unknown' }
  $prefix = if ($o.Count -ge 3) { [string]$o[2] } else { '' }
  $root = [IO.Path]::GetFullPath((Join-Path ([string]$o[1]) $prefix)).TrimEnd('\')
  $common = [string]$o[0]; if (-not [IO.Path]::IsPathRooted($common)) { $common = Join-Path $root $common }
  @{ Common = [IO.Path]::GetFullPath($common).TrimEnd('\'); Root = $root }
}
# $true = another project (a `syncRepos` folder; the raw list, so folders with the same leaf name count) on the same repository still depends on
# fcode's `/<name>` line in the shared info/exclude (the line stays: "kept"); $false = the line may go; 'unknown' = git could not tell (a failure:
# the caller reports an error, nothing is removed or forgotten, the next run tries again). A folder depends on it when
# it holds a regular file <name> at its root that is tracked nowhere for it (index and origin default) and that git hides through a `/<name>` line
# of info/exclude (check-ignore -v names the source: a .gitignore or global match is independent). A folder whose own release of this name is
# in this run ($Releasing: its project dirs) holds nothing for the others. Only "not a repository" skips a folder; every other git failure is 'unknown'.
# NB: with -v, check-ignore exits 0 also for a negated match ("!<name>"), whose pattern is not "/<name>": that copy is visible anyway
function Test-PhienSharedNote([string]$Dir, [string]$Name, [string[]]$Releasing) {
  $me = Get-PhienRepoId $Dir
  if ($null -eq $me -or $me -is [string]) { return 'unknown' }
  $skip = @()
  foreach ($rd in @($Releasing)) { if (-not $rd) { continue }; $ri = Get-PhienRepoId $rd; if ($ri -is [string]) { return 'unknown' }; if ($ri) { $skip += $ri.Root } }
  $held = $false   # every candidate is asked, a holder included: a git failure about any of them is 'unknown' whatever its place in syncRepos (box pair_holders)
  foreach ($o in @($SyncRepos)) {
    $f = Join-Path ([string]$o) $Name
    # the file itself only (box parity: os.path.islink(f)): a folder that is a junction to a work tree still holds its note
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
    try { if ([IO.File]::GetAttributes($f) -band [IO.FileAttributes]::ReparsePoint) { continue } } catch { return 'unknown' }   # cannot read its attributes (access denied, a race): git cannot be told apart from a link: a failure for this release, never an abort of the run
    $id = Get-PhienRepoId ([string]$o)
    if ($null -eq $id) { continue }
    if ($id -is [string]) { return 'unknown' }
    if ($id.Common -ine $me.Common -or $id.Root -ieq $me.Root -or ($skip -icontains $id.Root)) { continue }
    $t = Invoke-GitQuiet ([string]$o) @('ls-files', '--', $Name)
    if ($t.Code -ne 0) { return 'unknown' }
    if (@($t.Out) -ccontains $Name) { continue }
    $up = Get-PhienUpstreamNotes ([string]$o)
    if ($null -eq $up) { return 'unknown' }
    if (@($up) -ccontains $Name) { continue }
    # -z: <source> NUL <line> NUL <pattern> NUL <path> NUL, never quoted (a folder name with non-ASCII or special characters parses the same)
    # -z needs --stdin: the path goes in NUL-terminated. Twice: Windows PowerShell 5.1 puts a BOM in front of the first stdin byte (that record is a
    # path that does not exist, never a match); the answer is read as records of four fields and the one whose path is <name> counts
    $ig = Invoke-GitQuiet ([string]$o) @('check-ignore', '-v', '-z', '--stdin') ($Name + "`0" + $Name + "`0")
    if ($ig.Code -ne 0 -and $ig.Code -ne 1) { return 'unknown' }
    if ($ig.Code -eq 1) { continue }
    $fs = @(([string]::Join("`n", [string[]]@($ig.Out))) -split "`0")
    if ($fs.Count -lt 5 -or $fs[-1] -ne '' -or ($fs.Count - 1) % 4 -ne 0) { return 'unknown' }
    $hit = $null
    for ($i = 0; $i -lt $fs.Count - 1; $i += 4) { if ($fs[$i + 3] -ceq $Name) { $hit = @($fs[$i], $fs[$i + 2]); break } }
    if (-not $hit) { continue }
    $src = @($hit[0] -split '[\\/]')
    if ($hit[1] -ceq "/$Name" -and $src.Count -ge 2 -and $src[-1] -ceq 'exclude' -and $src[-2] -ceq 'info') { $held = $true; continue }
  }
  $held
}
# what the laptop does for one release of <Name> in the project <Dir> whose exclude file the scan resolved ($Excl): kept | failed | removed | absent.
# Git is asked (Test-PhienSharedNote) only while fcode's line is still in that file: an earlier release of this run may have taken the pair already,
# then it goes straight to Remove-PhienNoteExclude ('absent'), like the box (new -ne cur). 'unknown' from git is 'failed' (nothing written, retried)
function Get-PhienLaptopRelease([string]$Dir, [string]$Excl, [string]$Name, [bool]$Legacy, [string[]]$Releasing) {
  if (-not $Excl -or (Test-PhienReparse $Excl)) { return 'failed' }   # a link is never read through nor written (box order: is_link before the holders)
  $has = (Test-PhienMarkedLine (Read-PhienExcludeText $Excl) $Name) -or ($Legacy -and (Test-PhienExcludeLine $Excl $Name))
  if ($has) {
    $sh = Test-PhienSharedNote $Dir $Name $Releasing
    if ($sh -is [string]) { return 'failed' }
    if ($sh) { return 'kept' }
  }
  Remove-PhienNoteExclude $Excl $Name $Legacy
}
function Get-PhienNoteStatePath { Join-Path $env:LOCALAPPDATA 'fcode\handoff-state.json' }
# strict: a missing file is an empty state; anything else that is not one JSON object (unreadable, cut, `null`, `42`, an array) stops the run
# before any change, so the sha memory and the 1.3.2/1.3.3 ownership records are never overwritten with nothing
function Read-PhienNoteState {
  $sp = Get-PhienNoteStatePath
  if (-not (Test-Path -LiteralPath $sp)) { return @{} }
  $h = @{}
  try {
    $raw = [IO.File]::ReadAllText($sp)
    if ($raw -notmatch '\A\s*\{') { throw 'không phải một đối tượng JSON' }   # PowerShell 7 unwraps a one-item array into its object
    $o = $raw | ConvertFrom-Json
    if ($o -isnot [Management.Automation.PSCustomObject]) { throw 'không phải một đối tượng JSON' }
    foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = [string]$p.Value }
  } catch { throw "không đọc được trạng thái ghi chú (handoff-state.json): $($_.Exception.Message)" }
  $h
}
function Write-PhienNoteState([hashtable]$S) {
  $p = Get-PhienNoteStatePath
  $d = Split-Path -Parent $p
  if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
  $o = [ordered]@{}; foreach ($k in ($S.Keys | Sort-Object)) { $o[$k] = $S[$k] }
  Write-PhienText $p ($o | ConvertTo-Json -Compress)
}

# the git half of excluding a note (khong dung .gitignore): '' = git already ignores <ten>; else the full path of .git/info/exclude;
# $null = git could not say (error or timeout), or the exclude file or its folder is a link ($script:PhienExclLink): the caller must not place the note
function Get-PhienExcludeFile([string]$Dir, [string]$Name) {
  $script:PhienExclLink = $false
  $ig = (Invoke-GitQuiet $Dir @('check-ignore', '-q', '--', $Name)).Code
  if ($ig -eq 0) { return '' }
  if ($ig -ne 1) { return $null }
  $r = Invoke-GitQuiet $Dir @('rev-parse', '--git-path', 'info/exclude')
  $p = @($r.Out)[0]
  if ($r.Code -ne 0 -or -not $p) { return $null }
  if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $Dir $p }
  if (Test-PhienReparse $p) { $script:PhienExclLink = $true; return $null }   # never write through a symlink / junction
  $p
}
# .git/info/exclude is read and written as Latin-1 (one char per byte, lossless): every byte of the user's file survives a rewrite, whatever its
# encoding; a note name is compared and written as the Latin-1 form of its UTF-8 bytes (what git reads)
function ConvertTo-PhienLatin1([string]$Text) { [Text.Encoding]::GetEncoding(28591).GetString([Text.Encoding]::UTF8.GetBytes($Text)) }
function Read-PhienExcludeText([string]$File) { if (-not [IO.File]::Exists($File)) { return '' }; [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($File)) }
# Rule O: a line is fcode's when it is the pair "# fcode" (its own line) right above "/<ten>", written in one atomic write
function Get-PhienMarkRx([string]$Name) { '(?m)^# fcode\r?\n/' + [regex]::Escape((ConvertTo-PhienLatin1 $Name)) + '\r?(?:\n|\z)' }
function Test-PhienMarkedLine([string]$Text, [string]$Name) { [bool]($Text -and [regex]::IsMatch($Text, (Get-PhienMarkRx $Name))) }
# the file half (plain .NET, no git): add the pair "# fcode" + "/<ten>" to that exclude file in one atomic rewrite (the pair is the ownership),
# with the file's own newline. Tra ve $true chi khi LAN NAY them; an exact "/<ten>" already there is the user's: nothing added, nothing claimed
function Add-PhienExcludeLine([string]$File, [string]$Name) {
  if (Test-PhienExcludeLine $File $Name) { return $false }
  $cur = Read-PhienExcludeText $File
  $nl = if ($cur -match "`r`n") { "`r`n" } else { "`n" }
  Write-PhienText $File ($cur + $(if ($cur -and -not $cur.EndsWith("`n")) { $nl } else { '' }) + '# fcode' + $nl + '/' + (ConvertTo-PhienLatin1 $Name) + $nl) ([Text.Encoding]::GetEncoding(28591))
  $true
}
# the exclude file already has the exact line "/<ten>"
function Test-PhienExcludeLine([string]$File, [string]$Name) { [IO.File]::Exists($File) -and (@((Read-PhienExcludeText $File) -split '\r?\n') -ccontains ('/' + (ConvertTo-PhienLatin1 $Name))) }

# give fcode's line back: the pair "# fcode" + "/<ten>", or — only for a line 1.3.2/1.3.3 added ($Legacy: its record says so) — the bare
# "/<ten>"; every other byte stays. No git here: $File is the path the scan resolved ('' = it could not).
# Tra ve: removed | absent (no file / nothing of fcode's there) | failed (no path, or the file / its folder is a link: nothing written)
function Remove-PhienNoteExclude([string]$File, [string]$Name, [bool]$Legacy) {
  if (-not $File -or (Test-PhienReparse $File)) { return 'failed' }
  if (-not (Test-Path -LiteralPath $File)) { return 'absent' }
  $cur = Read-PhienExcludeText $File
  $new = [regex]::Replace($cur, (Get-PhienMarkRx $Name), '')
  if ($new -ceq $cur -and $Legacy) { $new = [regex]::Replace($cur, '(?m)^/' + [regex]::Escape((ConvertTo-PhienLatin1 $Name)) + '\r?(?:\n|\z)', '') }
  if ($new -ceq $cur) { return 'absent' }
  Write-PhienText $File $new ([Text.Encoding]::GetEncoding(28591))
  'removed'
}

# dat mot file ghi chu da lay tu box vao goc project tren laptop.
# Tra ve: ok | changed | busy | tracked | failed | link (.git/info/exclude la lien ket) | timeout (git did not answer in time)
# One item, in this order: the git half, then the marked pair (one atomic write, which is the ownership), then git's own answer (check-ignore 0,
# else `failed`: git still shows the name, e.g. a `!<ten>` in a .gitignore outranks info/exclude), then the move.
# A kill anywhere leaves at most an inert pair, never a visible unexcluded note.
function Install-PhienNote([string]$Src, [string]$Dir, [string]$Name, [string]$Expect, [double]$Now, [int]$Busy = 30, [string]$Sha = '') {
  if ($Sha -and (Get-RangeSha $Src 0 (Get-Item -LiteralPath $Src).Length) -ne $Sha) { return 'changed' }
  $t = Invoke-GitQuiet $Dir @('ls-files', '--', $Name)
  if ($t.Code -eq 124) { return 'timeout' }
  if ($t.Code -ne 0 -or $t.Out -ccontains $Name) { return 'tracked' }
  $up = Get-PhienUpstreamNotes $Dir
  if ($null -eq $up) { return 'timeout' }
  if ($up -ccontains $Name) { return 'tracked' }
  $ex = Get-PhienExcludeFile $Dir $Name
  if ($null -eq $ex) { if ($script:PhienExclLink) { return 'link' }; if ($script:PhienLastGitCode -eq 124) { return 'timeout' }; return 'failed' }
  $dst = Join-Path $Dir $Name
  if (Test-Path -LiteralPath $dst) {
    $di = Get-Item -LiteralPath $dst
    if ($Now - (ConvertTo-Epoch $di.LastWriteTimeUtc) -lt $Busy) { return 'busy' }
    if ((Get-RangeSha $dst 0 $di.Length) -ne $Expect) { return 'changed' }
  } elseif ($Expect) { return 'changed' }
  $mt = (Get-Item -LiteralPath $Src).LastWriteTimeUtc
  $part = New-PhienPartName $dst
  try {
    [IO.File]::Copy($Src, $part, $true)
    [IO.File]::SetLastWriteTimeUtc($part, $mt)
    if ($ex) { [void](Add-PhienExcludeLine $ex $Name) }
    if ($ex) { $v = (Invoke-GitQuiet $Dir @('check-ignore', '-q', '--', $Name)).Code; if ($v -eq 124) { return 'timeout' }; if ($v -ne 0) { return 'failed' } }
    if (Test-Path -LiteralPath $dst) { [IO.File]::Replace($part, $dst, [NullString]::Value) } else { [IO.File]::Move($part, $dst) }
  } finally { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
  'ok'
}
# trang thai che do tu dong (%LOCALAPPDATA%\fcode\phien-auto.json): box dang chay o lan kiem tra truoc, va luc (epoch giay) mo ssh
# gan nhat cua BAT KY lan chay nao (tay hay tu dong; ghi ngay truoc khi mo ssh, ke ca lan sau do bi loi)
function Get-PhienAutoStatePath { Join-Path $env:LOCALAPPDATA 'fcode\phien-auto.json' }
function Read-PhienAutoState {
  try {
    $o = [IO.File]::ReadAllText((Get-PhienAutoStatePath)) | ConvertFrom-Json
    @{ boxRunning = [bool]$o.boxRunning; lastSshAt = [double]$o.lastSshAt }
  } catch { $null }
}
function Write-PhienAutoState([hashtable]$S) {
  try {
    $p = Get-PhienAutoStatePath
    $d = Split-Path -Parent $p
    if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
    Write-PhienText $p ([ordered]@{ boxRunning = [bool]$S.boxRunning; lastSshAt = [double]$S.lastSshAt } | ConvertTo-Json -Compress)
  } catch { }
}

# che do tu dong (luat v2): truoc het kiem tra box vao duoc khong (`ssh <host> true`, rat re).
#  - khong vao duoc: khong lam gi, khong doi trang thai, ghi mot dong nhat ky
#  - lan dau (chua co trang thai): dong bo mot lan ngay
#  - con lai: chi dong bo khi lan mo ssh gan nhat da cach >= 40 phut. Lan loi cung chi cho den moc 40 phut sau, khong thu lai nhanh.
$PhienAutoGapSec = 2400
function Get-PhienAutoDeadline { [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().AddSeconds((Get-PhienLimitSec $true)) }
function Invoke-PhienAutoRun {
  $as = Read-PhienAutoState
  $last = if ($as) { [double]$as.lastSshAt } else { 0 }
  # the reachability check runs under the same one deadline as the sync (ConnectTimeout covers only connect + handshake, not auth, a proxy hop or the remote true); a timeout counts as unreachable
  $saveDl = $script:PhienDeadline; $script:PhienDeadline = Get-PhienAutoDeadline
  try { $bs = Test-BoxRunning } finally { $script:PhienDeadline = $saveDl }
  # khong vao duoc box (mang, box tat, alias sai): khong mo ssh dong bo va KHONG doi trang thai
  if ($bs -ne 'running') { Add-PhienLog @("không vào được box (ssh $box lỗi): bỏ qua lần này, giữ nguyên trạng thái"); return 0 }
  $age = (ConvertTo-Epoch (Get-Date)) - $last
  $mins = [int][Math]::Floor($age / 60)
  if (-not $as) { $why = 'lần đầu (chưa có trạng thái)' }
  elseif ($age -ge $PhienAutoGapSec) { $why = "lần mở ssh trước đã cách $mins phút (từ 40 phút trở lên)" }
  else {
    Add-PhienLog @("box vào được, lần mở ssh trước mới cách $mins phút (dưới 40): bỏ qua lần này")
    Write-PhienAutoState @{ boxRunning = $true; lastSshAt = $last }
    return 0
  }
  Add-PhienLog @("đồng bộ vì: $why")
  Invoke-PhienSync '' $true $false $true
}
# nhat ky cho che do tu dong va --nhanh: chi dong tom tat, khong bao gio noi dung phien. Moi dong ghi ngay (append), nen lan chay bi ngat
# giua chung van giu moi dong da ghi. Khoa ten <khoa>-log giu dong cua hai lan chay khong lan vao nhau; cho toi da 2 s roi van ghi (khong bao
# gio cho lan chay khac), nhung khi do khong xoay file. Qua 200 KB: doi ten thanh phien.log.1 (nhat ky cu hon), roi ghi tiep vao phien.log moi.
function Add-PhienLog($Lines) {
  try {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $PhienLog))
    $mx = New-Object Threading.Mutex($false, ((Get-PhienLockName) + '-log'))
    $own = $false
    try { $own = $mx.WaitOne(2000) } catch [Threading.AbandonedMutexException] { $own = $true }
    try {
      if ($own -and [IO.File]::Exists($PhienLog) -and (New-Object IO.FileInfo($PhienLog)).Length -gt 200KB) {
        $old = $PhienLog + '.1'
        try { if ([IO.File]::Exists($old)) { [IO.File]::Replace($PhienLog, $old, [NullString]::Value) } else { [IO.File]::Move($PhienLog, $old) } } catch { }   # in use (sharing violation): rotate next time
      }
      $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
      Add-Content -LiteralPath $PhienLog -Value @($Lines | ForEach-Object { "$ts $_" }) -Encoding UTF8
    } finally { if ($own) { try { $mx.ReleaseMutex() } catch { } }; $mx.Dispose() }
  } catch { }
}

# --- tu dong: Task Scheduler chay an (conhost --headless: khong bao gio hien cua so) moi 10 phut ---
function Install-PhienTask([string]$ScriptPath, [string]$TaskName = 'phien-sync', [string]$TaskPath = '\FCode\', [string]$Extra = 'phien --tu-dong') {
  $ps = (Get-Command powershell.exe).Source
  $arg = '--headless "' + $ps + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '" ' + $Extra
  $act = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $arg
  $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 3650)
  $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 8)
  $pri = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
  [void](Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Action $act -Trigger $trg -Settings $set -Principal $pri -Force)
}
function Remove-PhienTask([string]$TaskName = 'phien-sync', [string]$TaskPath = '\FCode\') {
  $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($t) { Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false; $true } else { $false }
}

function Invoke-PhienAuto([string]$Mode) {
  switch ($Mode) {
    'bat' {
      try { Install-PhienTask $FcodeScript } catch { Write-IpaError 'không bật được chế độ tự động (Task Scheduler báo lỗi).' $_.Exception.Message; return 1 }
      Write-Host 'Đã bật tự động: cứ 10 phút, nếu vào được box, fcode tự đồng bộ phiên chat omp hai chiều (chạy ngầm, không hiện cửa sổ). Mở kết nối thưa (lần đầu, hoặc cách lần trước từ 40 phút).'
      Write-Host "Nhật ký: $PhienLog    Tắt: fcode phien tu-dong tat"
      return 0
    }
    'tat' {
      try { $was = Remove-PhienTask } catch { Write-IpaError 'không tắt được chế độ tự động.' $_.Exception.Message; return 1 }
      if ($was) { Write-Host 'Đã tắt tự động đồng bộ phiên chat omp.' } else { Write-Host 'Chế độ tự động đang tắt sẵn.' }
      return 0
    }
    { $_ -in '', 'trangthai' } {
      $t = Get-ScheduledTask -TaskPath '\FCode\' -TaskName 'phien-sync' -ErrorAction SilentlyContinue
      if ($t) { Write-Host 'Tự động đồng bộ: ĐANG BẬT (kiểm tra mỗi 10 phút, chỉ mở kết nối khi box vừa bật hoặc cách lần trước từ 40 phút).' } else { Write-Host 'Tự động đồng bộ: đang tắt. Bật: fcode phien tu-dong bat' }
      return 0
    }
    default { Write-Host 'Cách dùng: fcode phien tu-dong bat   hoặc   fcode phien tu-dong tat   hoặc   fcode phien tu-dong trangthai'; return 1 }
  }
}

function Invoke-PhienMenu {
  Write-Host ''
  Write-Host 'Phiên chat omp (laptop <-> box):'
  Write-Host '  1) Đồng bộ ngay tất cả project'
  Write-Host '  2) Bật tự động đồng bộ mỗi 10 phút'
  Write-Host '  3) Tắt tự động đồng bộ'
  $k = Read-Host 'Chọn số (Enter để thoát)'
  switch ($k) {
    '1' { return (Invoke-PhienSync '' $false) }
    '2' { return (Invoke-PhienAuto 'bat') }
    '3' { return (Invoke-PhienAuto 'tat') }
    default { return 0 }
  }
}

# --- --nhanh: a supervisor in its own kill-on-close job runs the real sync as a worker process inside that job ---
$PhienFailMsg = 'phien: không đồng bộ được, xem phien.log'
# --nen (the hook's run after the agent ends) waits 35 s first: a session saved a moment ago counts as "being written" for 30 s. FCODE_MOC_DELAY: tests only.
function Get-PhienNenDelaySec { if ("$env:FCODE_MOC_DELAY" -match '\A[0-9]{1,3}\z') { [int]$env:FCODE_MOC_DELAY } else { 35 } }
$PhienJobSrc = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class FcodeJob {
  [StructLayout(LayoutKind.Sequential)] struct Basic { public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass; }
  [StructLayout(LayoutKind.Sequential)] struct Io { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
  [StructLayout(LayoutKind.Sequential)] struct Ext { public Basic BasicLimits; public Io IoInfo; public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit; public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed; }
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr attrs, string name);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int cls, ref Ext info, uint len);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr proc);
  // a job whose last handle closing (this process ending, however it ends) makes Windows end every process in it
  public static IntPtr Create() {
    IntPtr j = CreateJobObject(IntPtr.Zero, null);
    if (j == IntPtr.Zero) throw new Win32Exception();
    Ext x = new Ext(); x.BasicLimits.LimitFlags = 0x2000;   // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if (!SetInformationJobObject(j, 9, ref x, (uint)Marshal.SizeOf(typeof(Ext)))) throw new Win32Exception();   // 9 = JobObjectExtendedLimitInformation
    return j;
  }
  public static void Assign(IntPtr job, IntPtr proc) { if (!AssignProcessToJobObject(job, proc)) throw new Win32Exception(); }
}
'@
# the job with THIS process in it (every child started later is born in it); $null when Windows refuses, the reason in $script:PhienJobError.
# The handle is never closed: it closes when this process ends.
function Get-PhienJob {
  try {
    if (-not ('FcodeJob' -as [type])) { Add-Type -TypeDefinition $PhienJobSrc }
    $j = [FcodeJob]::Create()
    [FcodeJob]::Assign($j, [Diagnostics.Process]::GetCurrentProcess().Handle)
    $j
  } catch { $script:PhienJobError = $_.Exception.Message; $null }
}
# the supervisor of a quick run: no job -> no sync at all (fail closed). The worker is the same program with FCODE_PHIEN_WORKER=1 and the screen of this
# one. When it overruns cap + 10 s this process returns 1 and ends; however this process ends (also killed, or its window closed), the job ends the worker
# and all its children (git, tar, ssh). So there is no kill call here.
function Invoke-PhienBounded([string]$Proj, [bool]$Nen) {
  if ($Nen) { Start-Sleep -Seconds (Get-PhienNenDelaySec) }
  $job = Get-PhienJob
  if ($null -eq $job) {
    Add-PhienLog @("lỗi: không tạo được job bảo vệ cho lần chạy nhanh ($script:PhienJobError) — không đồng bộ")
    Write-Host $PhienFailMsg
    return 1
  }
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
  $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $FcodeScript + '" phien ' + $Proj + ' --nhanh'
  $psi.UseShellExecute = $false
  $env:FCODE_PHIEN_WORKER = '1'   # the child inherits the process environment (never the ProcessStartInfo environment dictionary: its getter fails on Windows PowerShell 5.1 with two names that differ only in case)
  try { $p = [Diagnostics.Process]::Start($psi) } catch { Add-PhienLog @("lỗi: không chạy được lần đồng bộ nhanh ($($_.Exception.Message))"); Write-Host $PhienFailMsg; return 1 }
  finally { Remove-Item Env:FCODE_PHIEN_WORKER -ErrorAction SilentlyContinue }
  try {
    $lim = (Get-PhienCapSec) + 10
    if ($p.WaitForExit($lim * 1000)) { return $p.ExitCode }
    if ($p.HasExited) { return $p.ExitCode }
    Add-PhienLog @("lỗi: lần chạy nhanh vượt quá $lim giây nên bị ngắt hẳn (việc đang làm dở để lần sau; các dòng ngay trên là của lần chạy đó)")
    try { Write-Host $PhienFailMsg } catch { }
    return 1
  } finally { $p.Dispose() }
}

# fcode phien [project] | <project> --nhanh [--nen] | tu-dong bat|tat|trangthai | --tu-dong (do Task Scheduler goi)
function Invoke-Phien {
  $dry = [bool]($Rest | Where-Object { $_ -eq '--thu' })
  $quick = [bool]($Rest | Where-Object { $_ -eq '--nhanh' })
  $nen = [bool]($Rest | Where-Object { $_ -eq '--nen' })
  $pa = @($Rest | Select-Object -Skip 1 | Where-Object { $_ -ne '--thu' -and $_ -ne '--nhanh' -and $_ -ne '--nen' })
  $sub = if ($pa.Count -gt 0) { $pa[0] } else { '' }
  foreach ($a in $Rest) { if (Test-HasControlChar $a) { Write-Host 'lỗi: tham số có ký tự không hợp lệ.'; return 1 } }
  if ($sub -eq '--tu-dong') { return (Invoke-PhienAutoRun) }   # khoa chung (Local\fcode-phien) nam trong Invoke-PhienSync
  if ($sub -eq 'tu-dong') { return (Invoke-PhienAuto $(if ($pa.Count -gt 1) { $pa[1] } else { '' })) }
  if ($sub) { $sub = Resolve-ProjectArg $sub @(@((Get-PhienProjects).Keys) + @(Get-PrefsNames)) (-not $quick) }   # ten goi -> ten that, truoc moi viec khac (hook --nhanh khong hoi box)
  if (($sub -and $sub -notmatch '\A[A-Za-z0-9._-]+\z') -or ($quick -and (-not $sub -or $dry)) -or ($nen -and -not $quick)) { Write-Host 'Cách dùng: fcode phien [project]    fcode phien <project> --nhanh    fcode phien tu-dong bat|tat'; return 1 }
  if ($quick -and $env:FCODE_PHIEN_WORKER -ne '1') { return (Invoke-PhienBounded $sub $nen) }
  $key = if ($sub) { Get-PhienKeyOf $sub (Get-PhienProjects) }   # ten that tren box -> thu muc tren laptop (cung ten, hoac cung repo GitHub; ten thu muc co the khac)
  $rc = Invoke-PhienSync $(if ($key) { $key } else { $sub }) $false $dry $false $quick
  # --nhanh (the hook): the screen gets at most one line, the busy / cap message, or one short line when the sync failed; success prints nothing
  if ($quick) { if ($script:PhienScreen) { Write-Host $script:PhienScreen } elseif ($rc -ne 0) { Write-Host $PhienFailMsg } }
  $rc
}

# --- fcode moc bat|tat|trang-thai: hook trong profile PowerShell ---
# Khi gõ omp / claude / codex trong thu muc mot project (syncRepos), hook chay `fcode phien <project> --nhanh` truoc (cho xong, fcode tu ngat o ~30 s, hook chot 35 s),
# chay chuong trinh that, roi chay `--nhanh --nen` an o nen (fcode tu cho 35 s). Khoi nam giua hai dong danh dau; fcode chi sua khoi nay, khong dong gi khac cua profile.
# Khoi chi co ky tu ASCII (profile khong BOM doc theo ANSI trong Windows PowerShell 5.1); cau tieng Viet duy nhat di qua [regex]::Unescape.
$MocBegin = '# >>> fcode moc >>>'; $MocEnd = '# <<< fcode moc <<<'
$MocRx = '(?ms)^# >>> fcode moc >>>[ \t]*\r?\n.*?^# <<< fcode moc <<<[ \t]*(?:\r?\n|\z)'
$MocBlock = @'
# >>> fcode moc >>>
# Added by "fcode moc bat"; remove with "fcode moc tat". Off in this window: $env:FCODE_MOC = '0' (on again: Remove-Item Env:FCODE_MOC)
function Invoke-FcodeMoc([string]$Name, $Rest) {
  $real = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $real) { Write-Host "${Name}: not found on PATH"; $global:LASTEXITCODE = 127; return }
  $proj = $null; $fc = $null
  if ($env:FCODE_MOC -ne '0') {
    try {
      $cwd = ((Get-Location).ProviderPath -replace '/', '\').TrimEnd('\')
      $cfg = [IO.File]::ReadAllText((Join-Path $env:USERPROFILE '.fcode\config.json')) | ConvertFrom-Json
      $repos = @(@($cfg.syncRepos) | ForEach-Object { ([string]$_ -replace '/', '\').TrimEnd('\') } | Where-Object { $_ })
      $best = ''
      foreach ($s in $repos) { if (($cwd -ieq $s -or $cwd.StartsWith($s + '\', [StringComparison]::OrdinalIgnoreCase)) -and $s.Length -gt $best.Length) { $best = $s } }
      $n = if ($best) { (Split-Path $best -Leaf).ToLowerInvariant() } else { '' }
      $first = $repos | Where-Object { (Split-Path $_ -Leaf).ToLowerInvariant() -eq $n } | Select-Object -First 1
      if ($n -match '\A[a-z0-9][a-z0-9._-]{0,63}\z' -and $first -eq $best) { $proj = $n }
      $fc = Get-Command fcode -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($fc) {
        # fcode.ps1 next to fcode.cmd: start it directly (no batch file in the chain, so Ctrl+C never asks "Terminate batch job"); else fcode.cmd
        $ps1 = Join-Path (Split-Path -Parent $fc.Source) 'fcode.ps1'
        $psh = Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ((Test-Path -LiteralPath $ps1) -and $psh) { $exe = $psh.Source; $pre = '-NoProfile -ExecutionPolicy Bypass -File "' + $ps1 + '" ' } else { $exe = $fc.Source; $pre = '' }
      }
    } catch { }
  }
  $sync = $proj -and $fc
  if ($sync) {
    try {
      # fcode bounds itself (ends by about 30 s); the 35 s wait and taskkill are only a backstop
      $psi = New-Object Diagnostics.ProcessStartInfo
      $psi.FileName = $exe; $psi.Arguments = $pre + "phien $proj --nhanh"; $psi.UseShellExecute = $false
      $pr = [Diagnostics.Process]::Start($psi)
      if (-not $pr.WaitForExit(35000)) { & taskkill.exe /PID $pr.Id /T /F 2>&1 | Out-Null }
      $pr.Dispose()
    } catch { Write-Host ([regex]::Unescape('fcode: kh\u00f4ng \u0111\u1ed3ng b\u1ed9 \u0111\u01b0\u1ee3c phi\u00ean, b\u1ecf qua.')) }
  }
  # piped input (echo hi | claude -p) goes on to the real program; with nothing piped it keeps the console, so the terminal UI works
  if ($MyInvocation.ExpectingInput) { $input | & $real.Source @Rest } else { & $real.Source @Rest }
  $rc = $LASTEXITCODE
  if ($sync) {
    try {
      # the sync after the agent ends: started through the shell, so it inherits none of this shell's handles and its console stays hidden;
      # fcode waits 35 s itself (--nen) and bounds itself
      $psi = New-Object Diagnostics.ProcessStartInfo
      $psi.FileName = $exe; $psi.Arguments = $pre + "phien $proj --nhanh --nen"
      $psi.UseShellExecute = $true; $psi.WindowStyle = 'Hidden'
      [void][Diagnostics.Process]::Start($psi)
    } catch { }
  }
  $global:LASTEXITCODE = $rc
}
function omp { if ($MyInvocation.ExpectingInput) { $input | Invoke-FcodeMoc 'omp' $args } else { Invoke-FcodeMoc 'omp' $args } }
function claude { if ($MyInvocation.ExpectingInput) { $input | Invoke-FcodeMoc 'claude' $args } else { Invoke-FcodeMoc 'claude' $args } }
function codex { if ($MyInvocation.ExpectingInput) { $input | Invoke-FcodeMoc 'codex' $args } else { Invoke-FcodeMoc 'codex' $args } }
# <<< fcode moc <<<
'@

# hai file profile (CurrentUserAllHosts) cua Windows PowerShell 5.1 va PowerShell 7. Chi de thu: FCODE_DOCUMENTS thay thu muc Documents that.
function Get-MocProfiles {
  $d = if ($env:FCODE_DOCUMENTS) { $env:FCODE_DOCUMENTS } else { [Environment]::GetFolderPath('MyDocuments') }
  @((Join-Path $d 'WindowsPowerShell\profile.ps1'), (Join-Path $d 'PowerShell\profile.ps1'))
}
# 'ok' | 'same' (khong doi gi) | 'utf16' | 'half' (chi co mot dau danh dau): ghi/go khoi trong mot file profile. File doc theo byte (Latin-1 1:1),
# nen phan ngoai khoi giu NGUYEN byte (BOM, xuong dong). Lan doi dau tien cua file co san: chep sang profile.ps1.bak-fcode (khong bao gio de len).
function Set-MocProfile([string]$Path, [bool]$On) {
  $latin = [Text.Encoding]::GetEncoding(28591)
  $exists = Test-Path -LiteralPath $Path
  if (-not $exists -and -not $On) { return 'same' }
  $text = ''
  if ($exists) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) { return 'utf16' }
    $text = $latin.GetString($bytes)
  }
  $m = [regex]::Match($text, $MocRx)
  if (-not $m.Success -and ($text.Contains($MocBegin) -or $text.Contains($MocEnd))) { return 'half' }
  $nl = if ($text -match "\r\n" -or $text -notmatch "\n") { "`r`n" } else { "`n" }
  if ($On) {
    $block = ($MocBlock -replace "`r?`n", $nl) + $nl
    $new = if ($m.Success) { $text.Substring(0, $m.Index) + $block + $text.Substring($m.Index + $m.Length) }
           else { $text + $(if ($text -and -not $text.EndsWith("`n")) { $nl }) + $block }
  } else { $new = [regex]::Replace($text, $MocRx, '') }
  if ($new -ceq $text) { return 'same' }
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
  if ($exists -and -not (Test-Path -LiteralPath "$Path.bak-fcode")) { Copy-Item -LiteralPath $Path -Destination "$Path.bak-fcode" }
  $tmp = "$Path.fcode-tmp"
  [IO.File]::WriteAllBytes($tmp, $latin.GetBytes($new))
  if ($exists) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
  'ok'
}
# chinh sach chay script hieu luc, KHONG tinh pham vi Process (fcode.cmd chay voi -ExecutionPolicy Bypass nen se che mat chinh sach that)
function Get-MocPolicy {
  try { $l = @(Get-ExecutionPolicy -List | Where-Object { $_.Scope -ne 'Process' -and "$($_.ExecutionPolicy)" -ne 'Undefined' }); if ($l.Count) { return [pscustomobject]@{ Policy = "$($l[0].ExecutionPolicy)"; Scope = "$($l[0].Scope)" } } } catch { }
  [pscustomobject]@{ Policy = 'Restricted'; Scope = 'mặc định' }
}
# chinh sach hieu luc cua PowerShell 7 (pwsh), hoi chinh pwsh; $null neu may khong co pwsh hoac khong hoi duoc. Bo moi truong -ExecutionPolicy Bypass
# cua fcode.cmd (con thua huong qua PSExecutionPolicyPreference), khong thi pwsh luon tra Bypass.
function Get-MocPwshPolicy {
  $pw = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $pw) { return $null }
  $save = $script:PhienDeadline
  try {
    $script:PhienDeadline = [DateTime]::UtcNow.AddSeconds(15)
    $r = Invoke-PhienExe $pw.Source @('-NoProfile', '-NonInteractive', '-Command', '$env:PSExecutionPolicyPreference = $null; (Get-ExecutionPolicy).ToString()')
    $v = "$(@($r.Out)[-1])".Trim()
    if ($r.Code -eq 0 -and $v -match '\A[A-Za-z]+\z') { return $v }
  } catch { } finally { $script:PhienDeadline = $save }
  $null
}
function Write-MocPolicy {
  $p = Get-MocPolicy
  Write-Host "Chính sách chạy script của Windows PowerShell 5.1: $($p.Policy) (đặt ở: $($p.Scope))"
  if ($p.Policy -in 'Restricted', 'AllSigned') {
    Write-Host "  Cảnh báo: với chính sách này Windows PowerShell 5.1 sẽ KHÔNG nạp file profile nên hook chưa chạy ở đó. fcode không tự đổi chính sách."
    Write-Host '  Muốn cho phép, mở PowerShell và gõ:  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned   rồi mở cửa sổ PowerShell mới.'
    if ($p.Scope -in 'MachinePolicy', 'UserPolicy') { Write-Host '  (Chính sách này do Group Policy đặt nên lệnh trên có thể không đổi được; hỏi người quản trị máy.)' }
  }
  $pp = Get-MocPwshPolicy
  if ($pp) {
    Write-Host "Chính sách chạy script của PowerShell 7 (pwsh): $pp"
    if ($pp -in 'Restricted', 'AllSigned') {
      Write-Host "  Cảnh báo: với chính sách này PowerShell 7 sẽ KHÔNG nạp file profile nên hook chưa chạy ở đó. fcode không tự đổi chính sách."
      Write-Host '  Muốn cho phép, mở PowerShell 7 và gõ:  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned   rồi mở cửa sổ mới.'
    }
  }
}
# fcode moc bat|tat|trang-thai
function Invoke-Moc {
  foreach ($a in $Rest) { if (Test-HasControlChar $a) { Write-Host 'lỗi: tham số có ký tự không hợp lệ.'; return 1 } }
  $sub = if ($Rest.Count -gt 1) { $Rest[1] } else { '' }
  if ($sub -notin 'bat', 'tat', 'trang-thai') { Write-Host 'Cách dùng: fcode moc bat   |   fcode moc tat   |   fcode moc trang-thai'; return 1 }
  $rc = 0
  if ($sub -eq 'trang-thai') {
    Write-Host 'Hook đồng bộ phiên khi mở omp / claude / codex (trong thư mục project):'
    foreach ($f in (Get-MocProfiles)) {
      $has = $false; try { $has = (Test-Path -LiteralPath $f) -and [regex]::IsMatch([IO.File]::ReadAllText($f), $MocRx) } catch { }
      Write-Host ("  ${f}: " + $(if ($has) { 'có khối hook' } else { 'không có khối hook' }))
    }
    Write-MocPolicy
    return 0
  }
  foreach ($f in (Get-MocProfiles)) {
    try { $r = Set-MocProfile $f ($sub -eq 'bat') } catch { Write-Host "lỗi: không ghi được ${f}: $($_.Exception.Message)"; $rc = 1; continue }
    switch ($r) {
      'ok' { Write-Host ("  ${f}: " + $(if ($sub -eq 'bat') { 'đã thêm khối hook' } else { 'đã gỡ khối hook' })) }
      'same' { Write-Host ("  ${f}: " + $(if ($sub -eq 'bat') { 'khối hook đã có sẵn' } else { 'không có khối hook' })) }
      'utf16' { Write-Host "  ${f}: không sửa vì file lưu dạng UTF-16; hãy lưu lại dạng UTF-8 rồi chạy lại."; $rc = 1 }
      'half' { Write-Host "  ${f}: không sửa vì chỉ còn một dòng đánh dấu '# >>> fcode moc >>>' / '# <<< fcode moc <<<'; hãy xoá tay dòng còn lại rồi chạy lại."; $rc = 1 }
    }
  }
  if ($sub -eq 'bat') {
    Write-Host 'Xong. Mở cửa sổ PowerShell mới. Từ giờ, gõ omp / claude / codex trong thư mục một project (có trong syncRepos), fcode đồng bộ nhanh phiên trước và sau (tối đa khoảng 20 giây; không vào được box thì báo một dòng lỗi).'
    Write-Host "Tắt hook trong cửa sổ này: `$env:FCODE_MOC = '0'  (bật lại: Remove-Item Env:FCODE_MOC, hoặc đóng cửa sổ)    Tắt hẳn: fcode moc tat    Xem trạng thái: fcode moc trang-thai"
    Write-Host 'Hook là hàm bọc nên không chuyển đúng hoàn toàn các tham số kiểu -- và -x:giá-trị, cũng không để lại lỗi trong $?; khi cần đúng tuyệt đối, chạy thẳng claude.exe / codex.exe / omp.exe.'
    Write-MocPolicy
  } else { Write-Host 'Đã tắt hook. Cửa sổ PowerShell đang mở vẫn còn hook cho tới khi đóng.' }
  $rc
}

if ($arg -in '-h', '--help', '/?', 'help') { Show-Help $(if ($Rest.Count -gt 1) { [string]$Rest[1] } else { '' }); exit 0 }
if ($CfgBroken) {
  Write-Host "lỗi: file cấu hình bị sai, không đọc được: $ConfigFile"
  Write-Host '  Mở file bằng Notepad để sửa, hoặc xóa file rồi chạy lại install.ps1 để tạo lại.'
  Write-Host "  (chi tiết: $(($CfgBroken -split "`n")[0].Trim()))"
  exit 1
}
if ($arg -eq 'sync') { exit (Invoke-Sync) }
if ($arg -eq 'ipa') { exit (Invoke-Ipa) }
if ($arg -eq 'add') { exit (Invoke-Add) }
if ($arg -eq 'deploy') { exit (Invoke-Deploy) }
if ($arg -eq 'move') { exit (Invoke-Move @($Rest | Select-Object -Skip 1)) }
if ($arg -eq 'pair') { exit (Invoke-Pair) }
if ($arg -eq 'phien') { exit (Invoke-Phien) }
if ($arg -eq 'moc') { exit (Invoke-Moc) }
if ($arg -eq '-l') { $arg = '--list' }
if ($arg -eq 'new') { $arg = '--new' }
# ten goi cua project -> ten that (ban sao tren laptop), truoc khi kiem tra ten. Hoi box mot lan khi chua co ban sao, hoac khi tu khong the la ten phien
# (co dau cach, chu co dau: chi co the la ten goi). Tu hop le ma box khong biet (khong phai phien) thi hoi box mot lan sau khi ssh bao loi (vong lap duoi).
$bareWord = [bool]($arg -and $arg -ne '--list' -and $arg -ne '--new' -and $arg -notmatch '\A[0-9]+\z')
$asked = $false
if ($bareWord) {
  $asked = -not (Test-Path -LiteralPath (Get-PrefsPath)) -or $arg -notmatch '\A[A-Za-z0-9._-]+\z'
  $arg = Resolve-ProjectArg $arg @(Get-PrefsNames) $asked
}
# ten phien: chi chu, so, . _ - (\z, khong dung $: $ chap nhan them 1 ky tu xuong dong o cuoi)
if ($arg -and $arg -ne '--list' -and $arg -ne '--new' -and $arg -notmatch '\A[A-Za-z0-9._-]+\z') {
  Write-Host "Không hiểu lệnh '$($arg -replace '[\x00-\x1f\x7f]', '?')'. Gõ fcode help để xem các lệnh."
  exit 1
}
if (-not $arg) { $pw = Get-PhienWarning; if ($pw) { Write-Host $pw -ForegroundColor Yellow } }
$ssh = Get-SshExe
# vao phien (khong phai --list): may chu clipboard cho Alt+V dan anh, dong khi ssh tra ve (ke ca khi loi); keo chuot de chep va Alt+V can Windows Terminal
$clip = $null
if ($arg -ne '--list') {
  if (-not $env:WT_SESSION) { Write-Host 'Lưu ý: không chạy trong Windows Terminal: kéo chuột để chép và Alt+V dán ảnh cần Windows Terminal.' -ForegroundColor Yellow }
  $clip = Start-FcodeClipServer
}
try {
  while ($true) {
    # tham so $1 di cung script (set -- '..'), khong nam tren dong lenh ssh. Script nen gzip roi base64: dong lenh ngan (cmd.exe/wrapper .cmd gioi han 8191 ky tu)
    $gzIn = [Text.Encoding]::UTF8.GetBytes((Get-BareScript $arg))
    $gzMs = New-Object IO.MemoryStream
    $gz = New-Object IO.Compression.GZipStream($gzMs, [IO.Compression.CompressionMode]::Compress)
    $gz.Write($gzIn, 0, $gzIn.Length); $gz.Close()
    $b64 = [Convert]::ToBase64String($gzMs.ToArray())
    $remote = "bash <(echo $b64 | base64 -d | gunzip)"
    if ($arg -eq '--list') { & $ssh $box $remote }
    elseif ($clip) {
      # -R: o unix tren box -> may chu clipboard o day (ssh loi khi chuyen tiep thi van vao phien: khong dat ExitOnForwardFailure).
      # Ten o MOI cho moi lan goi ssh (chay lai khi ma 78 cung vay): sshd khong go o -R khi phien ket thuc nen ten cu se bi tu choi.
      # Token khong bao gio len dong lenh (ssh.exe hay box): di bang bien moi truong LC_FCODE_CLIP_TOKEN + -o SendEnv (sshd cua box nhan LC_*); dong lenh tren box chi mang duong o (khong phai bi mat).
      # Script tren box doc bien roi unset truoc khi exec tmux; day xoa bien khoi moi truong cua fcode ngay khi ssh tra ve (hop dong A3 muc 13).
      $sock = New-FcodeClipSock
      $env:LC_FCODE_CLIP_TOKEN = $clip.Token
      try { & $ssh -q -tt -R "${sock}:127.0.0.1:$($clip.Port)" -o StreamLocalBindUnlink=yes -o SendEnv=LC_FCODE_CLIP_TOKEN $box "FCODE_CLIP_SOCK=$sock $remote" }
      finally { $env:LC_FCODE_CLIP_TOKEN = $null }
    }
    else { & $ssh -q -tt $box $remote }
    $rc = $LASTEXITCODE
    if ($rc -eq 78 -and $bareWord -and -not $asked) {   # box bao khong co phien nao ten nay (ma 78; ssh dut, 255, thi khong): co the la ten goi moi dat trong app. Hoi box mot lan; doi duoc ra ten that thi chay lai
      $asked = $true
      $new = Resolve-ProjectArg $arg @(Get-PrefsNames) $true
      if ($new -cne $arg -and $new -match '\A[A-Za-z0-9._-]+\z') { $arg = $new; continue }
    }
    break
  }
} finally { Stop-FcodeClipServer $clip }
if ($rc -eq 78) { $rc = 1 }   # 78 chi la tin hieu giua script tren box va laptop; nguoi dung van thay ma 1
if ($rc -eq 77 -and -not $arg) { exit (Invoke-PhienMenu) }
# tham so khong khop phien nao (hoac loi) thi nhac lenh help
if ($rc -ne 0 -and $arg -and $arg -ne '--list' -and $arg -ne '--new') { Write-Host "Nếu '$arg' không phải tên phiên, gõ fcode help để xem các lệnh." }
exit $rc
