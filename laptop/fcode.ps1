# fcode: vao phien tmux tren box instabox "coder" (1 lan ssh). Xem fcode.sh.
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$arg = if ($Rest -and $Rest.Count -gt 0) { $Rest[0] } else { '' }
# Cau hinh rieng tung may: %USERPROFILE%\.fcode\config.json (install.ps1 tao). Thieu khoa thi dung mac dinh.
# Khoa: instabox (duong dan instabox.exe), box (ten box), syncRepos (danh sach thu muc cho fcode sync), ipaRepo, ipaTag, deployHost (ten ssh den VPS cho fcode deploy, mac dinh contabo).
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
# project cua box (ten + URL origin + ten goi): danh thuc box, hoi mot lan (han 60 giay, khong phai 900 giay cua mot dot chep phien, tinh tu luc box da thuc).
# $null neu khong doc duoc. Cung cap nhat ban sao ten goi.
function Get-BoxProjects {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { & (Get-InstaboxExe) wake $box *> $null; $script:PhienDeadline = [DateTime]::UtcNow.AddSeconds([Math]::Min(60, (Get-PhienLimitSec $false))); $bp = Get-BoxJson (Invoke-BoxPy 'projects' ([byte[]]@())) } catch { $bp = $null } finally { $ErrorActionPreference = $old; $script:PhienDeadline = $null }
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

# duong dan instabox.exe: config > PATH > thu muc cai mac dinh
function Get-InstaboxExe {
  $p = Get-Cfg 'instabox' ''
  if ($p -and (Test-Path -LiteralPath $p)) { return $p }
  $c = Get-Command instabox -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  Join-Path $env:LOCALAPPDATA 'Programs\instabox\instabox.exe'
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
    'fcode move plan <máy mới>@@Kiểm tra, lập kế hoạch chuyển VPS',
    'fcode move copy | cutover@@Chép trước, rồi chuyển (tạm dừng 1 lần)',
    'fcode move finish | back | status@@Bỏ máy cũ, quay lại, xem trạng thái',
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
      '  Chuyển cả VPS (cổng deploy, mọi ứng dụng, database, tunnel) sang máy',
      '  mới trong vài lệnh, một lần tạm dừng chung. Hai máy chép dữ liệu',
      '  thẳng cho nhau; không bí mật nào đi qua máy này. Trạng thái nằm ở',
      '  %USERPROFILE%\.fcode\move\state.json; chạy lại lệnh là tiếp tục.',
      '',
      '#Lệnh',
      'plan <máy mới> [--map f]@@Chỉ đọc: kiểm tra, ước tính thời gian',
      'copy@@Cài công cụ, chép trước (chạy lại = làm mới)',
      'cutover@@Tạm dừng, chép nốt, bật bên máy mới, chuyển tunnel',
      'finish@@Bỏ máy cũ (hoặc huỷ lần chuyển chưa xong)',
      'back@@Chuyển ngược lại (thêm một lần tạm dừng)',
      'status@@Xem giai đoạn và trạng thái hai máy',
      '',
      '#Lưu ý',
      '  <máy mới>: tên ssh (alias) của máy mới, root vào được từ laptop.',
      '  cutover / back / finish hỏi gõ YES. Lỗi trước khi chuyển xong thì máy',
      '  cũ tự chạy lại như cũ. Workflow GitHub deploy thẳng vào máy cũ qua',
      '  SSH bị tắt cho tới khi trỏ lại.',
      '',
      '#Ví dụ',
      '  fcode move plan newbox',
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
      '    cửa sổ), chỉ khi box đang chạy, và chỉ mở kết nối khi box vừa bật',
      '    hoặc cách lần mở trước từ 40 phút (để box tự nghỉ được).',
      '>fcode phien tu-dong trangthai',
      '    Xem tự động đồng bộ đang bật hay tắt.',
      '>fcode phien <project> --nhanh',
      '    Bản nhanh cho hook (fcode moc): chỉ một project, không đánh thức',
      '    box (box đang ngủ thì bỏ qua), tối đa 20 giây, đang có lượt đồng',
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
      '  bộ nhanh phiên trước và sau khi chạy (tối đa khoảng 20 giây, box ngủ',
      '  thì bỏ qua).',
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

# chi de thu: FCODE_ADD_TIMEOUT_S / FCODE_ADD_KILL_AFTER_S (so nguyen duong, khong co 0: timeout 0 = khong co han) thanh bien cho $FcodeAddRun
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
        'NO_SCRIPT'     { Write-Host "lỗi: box chưa có script thêm dự án (bản FCode trên box đã cũ). Cập nhật box: instabox ssh $box rồi chạy: cd ~/fcode-src && git pull && bash install.sh"; Write-Host "  Xong thì chạy lại: fcode add $repo $name" }
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
        'V_EMPTY_REPO'  { Write-Host '[7] Repo còn trống (chưa có commit nào): bình thường với repo mới' }
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
    # timeout tren box: 124 = qua han, da dung (TERM); 137 = khong dung theo TERM nen bi KILL
    if ($code -in 124, 137) { Write-Host "lỗi: thêm dự án trên box chạy quá 10 phút nên đã bị dừng (mã $code). Chạy lại là an toàn: fcode add $repo $name"; return 1 }
    if ($code -eq 11) { Write-Host "Thư mục $name đã có trên box (hoặc không an toàn) — chọn tên khác: fcode add $repo <tên-khác>"; return 1 }
    if ($code -eq 25) { Write-Host 'lỗi: box không ghi được cấu hình đăng nhập GitHub cho repo này, nên chưa thêm project.'; return 1 }
    if ($code -eq 26) { Write-Host 'lỗi: cấu hình git trên box đang chuyển hướng địa chỉ GitHub (insteadOf / pushInsteadOf / pushurl) — cần gỡ trên box rồi chạy lại.'; return 1 }
    if ($code -eq 24) { Write-Host '[4] lỗi: không cài được chốt chặn push lên main, nên chưa thêm project.'; if ($hookD) { Write-Host "  (chi tiết: $hookD)" }; return 1 }
    if ($seen.Count -eq 0) {
      $d = ($lines | Where-Object { "$_".Trim() } | Select-Object -First 1)
      Write-IpaError 'không nói chuyện được với box. Kiểm tra: đã chạy "instabox login" chưa, và box đang bật không.' $d
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
    # chi noi "chay lai la an toan" khi chay lai co the giup (mang / box bi dung giua chung); 124 / 137 (qua han) da bao rieng o tren; ma la: chi bao ma
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
# $HostName (tuy chon): ten ssh cua may khac (fcode move); khong co thi deployHost. Cung luat ky tu nhu deployHost.
function Invoke-DeploySsh([string]$Remote, [string]$B64, [switch]$Quiet, [string]$HostName) {
  $dh = if ($HostName) { if ($HostName -cmatch '\A[A-Za-z0-9][A-Za-z0-9._@-]{0,99}\z') { $HostName } } else { Get-DeployHost }
  $buf = New-Object 'System.Collections.Generic.List[string]'
  $emit = { param($l) $buf.Add([string]$l); if (-not $Quiet) { if ("$l" -cmatch '\AGATE_WARN') { Write-Host $l -ForegroundColor Yellow } else { Write-Host $l } } }   # GATE_WARN = canh bao cua cong: mau vang
  if (-not $dh) { Write-Host $(if ($HostName) { "lỗi: tên ssh '$($HostName -replace '[\x00-\x1f\x7f]', '?')' không dùng được (chỉ chữ, số, dấu . _ @ -)." } else { 'lỗi: deployHost trong file cấu hình không dùng được (chỉ chữ, số, dấu . _ @ -).' }); return @{ Code = 1; Lines = @() } }
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
    Write-Host "  (nếu dòng INV unit ở trên có trusted_needed=yes, hoặc project là compose / script:  fcode deploy $name trust on i-understand-root)"
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
  $verbs = 'status', 'deploy', 'retry', 'pause', 'resume', 'trust', 'logs', 'recheck', 'inventory', 'register', 'compact'
  if ($a.Count -gt 0 -and $a[0] -ceq 'add') { return (Invoke-DeployAdd @($a | Select-Object -Skip 1)) }
  if ($a.Count -gt 0 -and ($a[0] -ceq 'allow' -or $a[0] -ceq 'disallow')) { return (Invoke-DeployAllow ([string]$a[0]) @($a | Select-Object -Skip 1)) }
  $name = if ($a.Count -gt 0) { [string]$a[0] } else { '' }; $verb = if ($a.Count -gt 1) { [string]$a[1] } else { '' }
  $rest = @($a | Select-Object -Skip 2)
  if (-not (Test-DeployName $name) -or $verbs -cnotcontains $verb) {
    Write-Host 'Cách dùng: fcode deploy <tên> <lệnh> [đối số]'
    Write-Host '  lệnh: status [id] · deploy <sha> · retry [sha] · pause · resume · trust on i-understand-root | off · logs [id] [số dòng] · recheck · compact · inventory <draft.json> · register <sha256> <draft.json>'
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
# fcode move plan <may-moi> [--map <file>] | copy | cutover | finish | back | status: move the whole VPS to a new machine.
# The spec is docs/move/CONTRACT.md section 8 of the deploy-gate repo. The laptop conducts and its state file is the one authority;
# the servers are reached only through `fcode-deploy-gate --move <verb>` (Invoke-DeploySsh -HostName) and a few small scripts sent on
# stdin. Only INV / MOVE / GATE_EXIT lines are parsed and printed; no secret is ever written to disk or to the screen.
function Get-MoveNow { [DateTime]::UtcNow }
function Wait-Move([int]$Sec) { Start-Sleep -Seconds $Sec }
function Format-MoveTs([DateTime]$d) { $d.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }
# a state field as UTC DateTime, $null when empty (PowerShell 7 turns ISO strings into DateTime while reading JSON, 5.1 does not)
function ConvertTo-MoveTime($v) {
  if ($null -eq $v -or "$v" -eq '') { return $null }
  if ($v -is [DateTime]) { return $v.ToUniversalTime() }
  try { [DateTime]::ParseExact([string]$v, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)) } catch { $null }
}
function Get-MoveDir { $d = Join-Path (Join-Path $env:USERPROFILE '.fcode') 'move'; [void][IO.Directory]::CreateDirectory($d); $d }
function Get-MovePath([string]$Leaf) { Join-Path (Get-MoveDir) $Leaf }
function Set-MoveProp($o, [string]$Name, $Value) { if ($o.PSObject.Properties[$Name]) { $o.$Name = $Value } else { Add-Member -InputObject $o -NotePropertyName $Name -NotePropertyValue $Value } }
function Get-MoveSha256Hex([byte[]]$b) { ([BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($b)) -replace '-', '').ToLowerInvariant() }
# a word of a gate request (the gate allows [A-Za-z0-9 ._=:/,-]; no space in one word)
function Test-MoveWord([string]$w) { $w -cmatch '\A[A-Za-z0-9._=:/,-]{1,100}\z' }
# exit codes of fcode move: the gate's 0 / 65 / 69 / 70 / 75 come back unchanged, everything else (ssh 255, 1 ...) is 1
function ConvertTo-MoveExit([int]$Code) { if ($Code -eq 0) { 0 } elseif ($Code -in 65, 69, 70, 75) { $Code } else { 1 } }

# ---- the state file: %USERPROFILE%\.fcode\move\state.json, written atomically (Write-PhienText) after every step ----
function Read-MoveState {
  $p = Get-MovePath 'state.json'
  if (-not [IO.File]::Exists($p)) { return $null }
  try { $s = [IO.File]::ReadAllText($p) | ConvertFrom-Json } catch { throw "file trạng thái $p bị hỏng ($($_.Exception.Message))" }
  if ($null -eq $s -or $s.schema -ne 1 -or -not $s.move_id -or -not $s.old -or -not $s.new -or -not $s.answers) { throw "file trạng thái $p không đúng định dạng" }
  foreach ($f in 'cut_at', 'cut_not_before') { $t = ConvertTo-MoveTime $s.$f; Set-MoveProp $s $f $(if ($t) { Format-MoveTs $t } else { $null }) }
  foreach ($k in 'cut', 'back', 'finish', 'finish_early') { $a = $s.answers.$k; if ($a -and $a.ts) { $t = ConvertTo-MoveTime $a.ts; $a.ts = $(if ($t) { Format-MoveTs $t } else { $null }) } }
  $s
}
function Save-MoveState($S) { Write-PhienText (Get-MovePath 'state.json') (ConvertTo-Json -InputObject $S -Depth 8) }
function New-MoveState([string]$Id, [string]$Dir, [string]$Via, $Old, $New) {
  [pscustomobject][ordered]@{
    schema = 1; move_id = $Id; dir = $Dir; via = $Via; old = $Old; new = $New
    manifest_sha = ''; est_downtime_s = 0; cap_s = 1800
    phase = 'planned'; mark = $null; cut_at = $null; cut_not_before = $null; dst_started = $false
    answers = [pscustomobject][ordered]@{ cut = $null; back = $null; finish = $null; finish_early = $null }
    repos = @()
    backups = [pscustomobject][ordered]@{ ssh_config = $null; coder_ssh_config = $null; coder_known_hosts = $null }
  }
}
# only one fcode move at a time: move.lock opened with no sharing; $null when another run holds it
function Open-MoveLock { try { New-Object IO.FileStream((Get-MovePath 'move.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) } catch { $null } }

# ---- lines and remote calls ----
# "INV target moveid=x peer=y" -> @{ Words = @('INV','target'); Kv = @{ moveid = 'x'; peer = 'y' } }
function ConvertFrom-MoveLine([string]$Line) {
  $kv = @{}; $w = @()
  foreach ($x in @("$Line".Trim() -split '\s+')) { $i = $x.IndexOf('='); if ($i -gt 0) { $kv[$x.Substring(0, $i)] = $x.Substring($i + 1) } else { $w += $x } }
  @{ Words = $w; Kv = $kv }
}
# print only the grammar lines (INV, MOVE, GATE_*); the manifest and key payloads (b64=) are never echoed, and the server's own `INV ok` is left to the laptop
function Write-MoveLines($Lines) {
  foreach ($l in @($Lines)) {
    $t = "$l"
    if ($t -cnotmatch '\A(INV|MOVE|GATE_EXIT|GATE_ERROR|GATE_WARN)\b' -or $t -ceq 'INV ok') { continue }
    $t = $t -replace '\b((?:pub_)?b64)=\S+', '$1=...'
    if ($t -cmatch '\AGATE_WARN') { Write-Host $t -ForegroundColor Yellow } else { Write-Host $t }
  }
}
# run a program (gh, ssh -G, ssh-keygen) and return @{ Code; Out } (stderr merged); $Stdin is piped in when given
function Invoke-MoveTool([string]$Tool, [string[]]$ToolArgs, [string]$Stdin = $null) {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $o = if ($null -ne $Stdin) { @($Stdin | & $Tool @ToolArgs 2>&1 | ForEach-Object { "$_" }) } else { @(& $Tool @ToolArgs 2>&1 | ForEach-Object { "$_" }) }
    $code = [int]$LASTEXITCODE
  } catch { $o = @("$($_.Exception.Message)"); $code = 1 } finally { $ErrorActionPreference = $old }
  @{ Code = $code; Out = $o }
}
# the result of one ssh call: the code is the GATE_EXIT line when there is one (ssh 255 stays 255), the grammar lines are printed unless -Quiet
function Complete-MoveResult($R, [switch]$Quiet) {
  $code = [int]$R.Code
  $g = @($R.Lines | Where-Object { "$_" -cmatch '\AGATE_EXIT\s+[0-9]+\s*\z' } | Select-Object -Last 1)
  if ($code -ne 255 -and $g.Count) { $code = [int](("$($g[0])".Trim() -split '\s+')[1]) }
  if (-not $Quiet) { Write-MoveLines $R.Lines }
  @{ Code = $code; Lines = @($R.Lines) }
}
# `ssh <host> "fcode-deploy-gate --move <verb> <move_id> <args>"`; $B64 = stdin (one base64 line, decoded on the server side)
function Invoke-MoveGate([string]$HostName, [string]$Verb, [string]$Id, [string[]]$VArgs = @(), [string]$B64 = '', [switch]$Quiet) {
  foreach ($w in (@($Verb) + @($Id) + @($VArgs))) { if ($w -and -not (Test-MoveWord ([string]$w))) { Write-Host "lỗi: tham số '$("$w" -replace '[\x00-\x1f\x7f]', '?')' không hợp lệ."; return @{ Code = 65; Lines = @() } } }
  $cmd = '/usr/local/sbin/fcode-deploy-gate --move ' + $Verb
  if ($Id) { $cmd += ' ' + $Id }
  foreach ($a in @($VArgs)) { $cmd += ' ' + $a }
  if ($B64) { $cmd = 'base64 -di | ' + $cmd }
  Complete-MoveResult (Invoke-DeploySsh $cmd $B64 -Quiet -HostName $HostName) -Quiet:$Quiet
}
# a small bash script over plain ssh (before the gate exists on the machine): the arguments travel in a `set --` line of the payload, never on the ssh command line
function Invoke-MoveScript([string]$HostName, [string]$Script, [string[]]$ScriptArgs = @(), [switch]$Quiet) {
  foreach ($a in @($ScriptArgs)) { if ("$a" -match '[\x00-\x1f\x7f]') { Write-Host 'lỗi: tham số của script có ký tự điều khiển.'; return @{ Code = 65; Lines = @() } } }
  $pre = if (@($ScriptArgs).Count) { 'set -- ' + ((@($ScriptArgs) | ForEach-Object { "'" + ("$_" -replace "'", "'\''") + "'" }) -join ' ') + "`n" } else { '' }
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pre + ($Script -replace "`r`n", "`n")))   # a Windows checkout may have CRLF in the here-strings; bash needs LF
  $remote = 'f=$(mktemp) && base64 -di >$f && bash $f </dev/null; rc=$?; rm -f $f; exit $rc'
  Complete-MoveResult (Invoke-DeploySsh $remote $b64 -Quiet -HostName $HostName) -Quiet:$Quiet
}

# ---- the scripts sent on stdin (plain ssh, bash, root). FCM_ROOT is a test hook: a prefix for every path ----
# preflight on dst (plan step 2): read-only, prints INV lines only
function Get-MovePreflightScript {
@'
#!/bin/bash
# fcode move: preflight (plan step 2). Read-only; prints INV lines only.
R=${FCM_ROOT:-}
os=unknown-0
if [ -r "$R/etc/os-release" ]; then os=$(. "$R/etc/os-release"; echo "${ID:-unknown}-${VERSION_ID:-0}"); fi
mem=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}'); swap=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}')
tz=$(timedatectl show -p Timezone --value 2>/dev/null); [ -n "$tz" ] || tz=$(cat "$R/etc/timezone" 2>/dev/null); [ -n "$tz" ] || tz=UTC
nm=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null); [ -n "$nm" ] || nm=0
echo "INV host os=$os arch=$(uname -m) cpus=$(nproc 2>/dev/null || echo 1) mem_mb=${mem:-0} swap_mb=${swap:-0} tz=${tz// /_} node_major=$nm"
df -P -BM "${R:-/}" 2>/dev/null | awk 'NR==2 { u=$3; f=$4; sub(/M$/, "", u); sub(/M$/, "", f); print "INV disk mount=/ used_mb=" u " free_mb=" f }'
smtp=unknown
if command -v timeout >/dev/null 2>&1; then
  if timeout 6 bash -c 'exec 3<>/dev/tcp/aspmx.l.google.com/25' >/dev/null 2>&1; then smtp=open; else smtp=blocked; fi
fi
echo "INV egress smtp=$smtp"
mid=; peer=
f=$R/var/lib/fcode-move/move-id
if [ -r "$f" ]; then
  mid=$(sed -n 's/.*"move_id":"\([0-9a-f-]*\)".*/\1/p' "$f" | head -n 1)
  peer=$(sed -n 's/.*"peer":"\([a-z][a-z0-9-]*\)".*/\1/p' "$f" | head -n 1)
fi
n=$(ls "$R/etc/fcode-deploy/projects/"*.json 2>/dev/null | wc -l)
echo "INV target moveid=${mid:--} peer=${peer:--} projects=$((n + 0))"
for d in /root/.cloudflared /etc/cloudflared; do
  [ -d "$R$d" ] || continue
  find "$R$d" \( -type f -o -type l \) 2>/dev/null
done | while IFS= read -r p; do printf '%s\n' "${p#"$R"}"; done | grep -E '^/[A-Za-z0-9._/+@=,:-]+$' | sort -u | while IFS= read -r p; do echo "INV target-file $p"; done
for d in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
  [ -d "$R$d" ] || continue
  grep -lsE '^[[:space:]]*ExecStart=.*cloudflared' "$R$d"/*.service 2>/dev/null
done | while IFS= read -r p; do basename "$p"; done | grep -E '^[A-Za-z0-9@._-]+$' | sort -u | while IFS= read -r u; do
  if systemctl is-active --quiet "$u" 2>/dev/null; then a=yes; else a=no; fi
  echo "INV target-unit $u active=$a"
done
exit 0
'@
}
# can this machine open a TCP connection to $1:$2 (exit 0 = yes)? Used for `INV reach` (new -> old) and the coder -> new warning
function Get-MoveTcpScript {
@'
#!/bin/bash
# fcode move: TCP test to $1:$2 (exit 0 = reachable)
timeout 8 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" 2>/dev/null
'@
}
# copy step (a), on new: tools, Node.js, the move key, old's host key. Prints `MOVE key ...` (with the PUBLIC key as base64) and nothing secret.
function Get-MoveBootstrapKeyScript {
@'
#!/bin/bash
# fcode move: bootstrap key (copy step a), on the new machine. Idempotent.
# args: $1 = alias of this machine, $2 = known_hosts line of the old machine, $3 = Node.js major to have at least
set -u
umask 077
alias=$1; known=$2; need=$3
R=${FCM_ROOT:-}
MV=$R/var/lib/fcode-move
key=$R/root/.ssh/fcode-move
nodemajor() { node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }
missing=
for t in rsync git curl flock fallocate mkfs.ext4 mountpoint mount losetup systemd-run systemctl ssh-keygen; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
have=$(nodemajor)
if [ -n "$missing" ] || [ "${have:-0}" -lt "$need" ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q >/dev/null 2>&1 || true
  apt-get install -y -q rsync git curl util-linux e2fsprogs ca-certificates gnupg >/dev/null 2>&1 || { echo "MOVE error tool-missing name=apt-install"; exit 70; }
  if [ "${have:-0}" -lt "$need" ]; then
    install -d -m 0755 "$R/etc/apt/keyrings"
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o "$R/etc/apt/keyrings/nodesource.gpg" || { echo "MOVE error tool-missing name=nodesource-key"; exit 70; }
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${need}.x nodistro main" > "$R/etc/apt/sources.list.d/nodesource.list"
    apt-get update -q >/dev/null 2>&1 || true
    apt-get install -y -q nodejs >/dev/null 2>&1 || { echo "MOVE error tool-missing name=nodejs"; exit 70; }
  fi
fi
for t in rsync git curl flock fallocate mkfs.ext4 mountpoint mount losetup systemd-run systemctl ssh-keygen node; do
  command -v "$t" >/dev/null 2>&1 || { echo "MOVE error tool-missing name=$t"; exit 70; }
done
mkdir -p "$MV" "$R/root/.ssh" && chmod 700 "$MV" "$R/root/.ssh" || { echo "MOVE error bad-request what=dirs"; exit 1; }
state=exists
if [ ! -e "$key" ]; then
  rm -f "$key.pub"
  ssh-keygen -q -t ed25519 -N '' -C "fcode-move-$alias" -f "$key" || { echo "MOVE error tool-missing name=ssh-keygen"; exit 70; }
  state=created
elif [ ! -e "$key.pub" ]; then
  ssh-keygen -y -f "$key" > "$key.pub" || { echo "MOVE error tool-missing name=ssh-keygen"; exit 70; }
fi
chmod 600 "$key"
if [ -n "$known" ] && [ "$known" != - ]; then
  printf '%s\n' "$known" > "$MV/known_hosts.tmp" && mv -f "$MV/known_hosts.tmp" "$MV/known_hosts" || { echo "MOVE error bad-request what=known_hosts"; exit 1; }
fi
pub=$(cut -d' ' -f1,2 "$key.pub")
echo "MOVE key $state name=$alias pub_b64=$(printf '%s' "$pub" | base64 -w0 | tr -d =)"
exit 0
'@
}
# copy step (d), on new: pull the gate (entry, lib, units) from old with the move key when the entry is missing; the entry comes last, so a cut-off run is redone
function Get-MoveBootstrapGateScript {
@'
#!/bin/bash
# fcode move: bootstrap gate (copy step d), on the new machine. Idempotent.
# args: $1 = old address, $2 = old ssh port, $3 = gate entry file, $4 = gate lib dir, $5... = gate unit files
set -u
umask 022
addr=$1; port=$2; entry=$3; lib=$4; shift 4
R=${FCM_ROOT:-}
MV=$R/var/lib/fcode-move
if [ -e "$R$entry" ]; then echo "MOVE step bootstrap-gate skipped=yes"; exit 0; fi
ssh="ssh -i $R/root/.ssh/fcode-move -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$MV/known_hosts -p $port"
pull() { mkdir -p "$(dirname "$R$2")" && rsync -aHAX -e "$ssh" "root@$ra:$1" "$R$2"; }
ra=$addr; case $addr in *:*) ra="[$addr]" ;; esac   # an IPv6 address needs brackets in an rsync source
mkdir -p "$R$lib" && rsync -aHAX -e "$ssh" "root@$ra:$lib/" "$R$lib/" || { echo "MOVE error rsync-failed what=lib"; exit 1; }
for u in "$@"; do pull "$u" "$u" || { echo "MOVE error rsync-failed what=units"; exit 1; }; done
pull "$entry" "$entry" || { echo "MOVE error rsync-failed what=entry"; exit 1; }
systemctl daemon-reload 2>/dev/null
echo "MOVE step bootstrap-gate skipped=no"
exit 0
'@
}
# post-cut chore (c), on the coder box: print its ssh config (base64) so the laptop can rewrite it
function Get-MoveCoderReadScript {
@'
#!/bin/bash
# fcode move: coder ssh config (read)
f=$HOME/.ssh/config
if [ -r "$f" ]; then echo "MOVE coder-config exists=yes b64=$(base64 -w0 "$f")"; else echo "MOVE coder-config exists=no b64="; fi
'@
}
# post-cut chore (c), on the coder box: $1 = the new ssh config (base64, or - = unchanged), $2 = safety-copy tag, $3 = known_hosts line to add (or -)
function Get-MoveCoderWriteScript {
@'
#!/bin/bash
# fcode move: coder ssh config (write). The safety copies are written only when absent and never restored by code.
set -u
umask 077
d=$HOME/.ssh; mkdir -p "$d" && chmod 700 "$d"
if [ "$1" != - ]; then
  cfg=$d/config; bak=$d/config.fcode-move.$2.bak
  new=$(mktemp "$d/.fcode-move.XXXXXX") || exit 1
  printf '%s' "$1" | base64 -d > "$new" || { rm -f "$new"; exit 1; }
  if [ -e "$cfg" ] && [ ! -e "$bak" ]; then cp -a "$cfg" "$bak" || { rm -f "$new"; exit 1; }; fi
  mv -f "$new" "$cfg" && chmod 600 "$cfg" || exit 1
fi
if [ "$3" != - ]; then
  kh=$d/known_hosts; kbak=$d/known_hosts.fcode-move.$2.bak
  touch "$kh"
  if ! grep -qxF -- "$3" "$kh"; then
    [ -e "$kbak" ] || cp -a "$kh" "$kbak" || exit 1
    printf '%s\n' "$3" >> "$kh" || exit 1
  fi
fi
echo "MOVE alias coder done"
'@
}

# ---- ssh facts of an alias, host keys ----
# `ssh -G <alias>`: @{ Addr; Port; Proxy; HostKeyAlias }, $null when ssh cannot resolve it
function Get-MoveSshInfo([string]$Alias) {
  $r = Invoke-MoveTool 'ssh' @('-G', $Alias)
  if ($r.Code -ne 0) { return $null }
  $h = @{}
  foreach ($l in $r.Out) { if ($l -match '\A(\S+)\s+(.*)\z') { $k = $Matches[1].ToLowerInvariant(); if (-not $h.ContainsKey($k)) { $h[$k] = $Matches[2].Trim() } } }
  if (-not $h.ContainsKey('hostname')) { return $null }
  $px = [bool](($h['proxycommand'] -and $h['proxycommand'] -ne 'none') -or ($h['proxyjump'] -and $h['proxyjump'] -ne 'none'))
  @{ Addr = [string]$h['hostname']; Port = $(if ("$($h['port'])" -match '\A[0-9]+\z') { [int]$h['port'] } else { 22 }); Proxy = $px; HostKeyAlias = [string]$h['hostkeyalias'] }
}
# a machine behind a ProxyCommand / ProxyJump, or at a private, CGNAT (100.64/10), link-local, .local or .lan address, is `home`
function Test-MoveHome($Info) {
  if ($Info.Proxy) { return $true }
  $a = [string]$Info.Addr
  if ($a -match '(?i)\.(local|lan)\z') { return $true }
  $ip = $null
  if ([Net.IPAddress]::TryParse($a, [ref]$ip)) {
    if ($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
      $b = $ip.GetAddressBytes()
      return [bool]($b[0] -eq 10 -or $b[0] -eq 127 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) -or ($b[0] -eq 169 -and $b[1] -eq 254))
    }
    return [bool]($a -match '(?i)\A(fe80:|f[cd][0-9a-f]{2}:|::1\z)')
  }
  $false
}
# the laptop's verified known_hosts entry of a machine: @{ Line = '<addr> <type> <key>' ([addr]:port when the port is not 22); Fp = 'SHA256:..' }, $null when there is none
function Get-MoveHostKey($Info) {
  $spec = if ($Info.Port -ne 22) { "[$($Info.Addr)]:$($Info.Port)" } else { [string]$Info.Addr }
  $names = @($spec); if ($Info.HostKeyAlias -and $Info.HostKeyAlias -cne $spec) { $names += $Info.HostKeyAlias }
  $best = $null
  foreach ($n in $names) {
    $r = Invoke-MoveTool 'ssh-keygen' @('-F', $n)
    if ($r.Code -ne 0) { continue }
    foreach ($l in $r.Out) {
      if ("$l" -match '\A#' -or -not ("$l" -match '\A\S+\s+(\S+)\s+([A-Za-z0-9+/=]+)')) { continue }
      $type = $Matches[1]; $key = $Matches[2]
      try { $kb = [Convert]::FromBase64String($key) } catch { continue }
      if (-not $best -or ($type -ceq 'ssh-ed25519' -and $best.Type -cne 'ssh-ed25519')) { $best = @{ Type = $type; Key = $key; Kb = $kb } }
    }
    if ($best) { break }
  }
  if (-not $best) { return $null }
  @{ Line = "$spec $($best.Type) $($best.Key)"; Fp = 'SHA256:' + [Convert]::ToBase64String(([Security.Cryptography.SHA256]::Create()).ComputeHash($best.Kb)).TrimEnd('=') }
}

# ---- the laptop's and the coder's ssh config, rewritten by content ----
function Get-MoveSshConfigPath { Join-Path (Join-Path $env:USERPROFILE '.ssh') 'config' }
function Get-MoveKnownHostsPath { Join-Path (Join-Path $env:USERPROFILE '.ssh') 'known_hosts' }
# blocks of an ssh config as lines: @{ Start; End (exclusive); IsHost; Names } for every Host / Match line
function Get-MoveHostBlocks($Lines) {
  $b = @(); $cur = $null
  for ($i = 0; $i -lt $Lines.Count; $i++) {
    if ($Lines[$i] -match '^\s*(Host|Match)(?:\s*=\s*|\s+)(.*?)\s*$') {
      $isHost = ($Matches[1] -ieq 'Host'); $rest = $Matches[2]
      if ($cur) { $cur.End = $i; $b += $cur }
      $cur = @{ Start = $i; End = $Lines.Count; IsHost = $isHost; Names = $(if ($isHost) { @($rest -split '\s+' | Where-Object { $_ }) } else { @() }) }
    }
  }
  if ($cur) { $b += $cur }
  , $b
}
function Find-MoveHostBlock($Lines, [string]$Name) {
  foreach ($b in (Get-MoveHostBlocks $Lines)) { if ($b.IsHost -and @($b.Names | Where-Object { $_ -ieq $Name }).Count) { return $b } }
  $null
}
# the directive lines of a block: First..Last (the trailing blank and comment lines belong to what follows); Last < First when empty
function Get-MoveBlockBody($Lines, $B) {
  $last = $B.End - 1
  while ($last -gt $B.Start -and ($Lines[$last].Trim() -eq '' -or $Lines[$last].TrimStart().StartsWith('#'))) { $last-- }
  @{ First = $B.Start + 1; Last = $last }
}
# the directives of the laptop's `Host <new>` block, with a HostName always present (the rewritten alias must not fall back to its own name)
function Get-MoveNewDirectives([string]$Text, [string]$New, [string]$NewAddr) {
  $lines = @($Text -split '\r?\n')
  $b = Find-MoveHostBlock $lines $New
  if (-not $b) { return @{ Err = "không thấy khối 'Host $New' trong ~/.ssh/config của máy này"; Lines = @() } }
  $body = Get-MoveBlockBody $lines $b
  $d = @(if ($body.Last -ge $body.First) { $lines[$body.First..$body.Last] })
  if (-not @($d | Where-Object { $_ -match '^\s*HostName(\s|=)' }).Count) {
    $ind = '  '; foreach ($x in $d) { if ($x -match '^(\s+)\S') { $ind = $Matches[1]; break } }
    $d = @($ind + 'HostName ' + $NewAddr) + $d
  }
  @{ Err = ''; Lines = $d }
}
# forward: `Host <old>` -> the directives of `Host <new>` + HostKeyAlias <new>; the original goes to `Host <old>-old`. Skipped when `Host <old>-old` exists.
# $Coder: the coder's own block keeps its other directives (IdentityFile ...); only HostName / Port / ProxyCommand / ProxyJump come from the laptop's new block.
function Convert-MoveSshFwd([string]$Text, [string]$Old, [string[]]$NewLines, [string]$NewAlias, [bool]$Coder) {
  $nl = if ($Text -match "`r`n") { "`r`n" } else { "`n" }
  $lines = @($Text -split '\r?\n')
  if (Find-MoveHostBlock $lines "$Old-old") { return @{ Text = $Text; Changed = $false; Why = 'old-exists' } }
  $b = Find-MoveHostBlock $lines $Old
  if (-not $b) { return @{ Text = $Text; Changed = $false; Why = 'no-block' } }
  if (@($b.Names).Count -ne 1) { return @{ Text = $Text; Changed = $false; Why = 'shared-block' } }
  $body = Get-MoveBlockBody $lines $b
  $oldDir = @(if ($body.Last -ge $body.First) { $lines[$body.First..$body.Last] })
  $ind = '  '; foreach ($x in (@($NewLines) + $oldDir)) { if ($x -match '^(\s+)\S') { $ind = $Matches[1]; break } }
  if ($Coder) {
    $newDir = @($NewLines | Where-Object { $_ -match '^\s*(HostName|Port|ProxyCommand|ProxyJump)(\s|=)' }) + @($oldDir | Where-Object { $_ -notmatch '^\s*(HostName|Port|ProxyCommand|ProxyJump|HostKeyAlias)(\s|=)' })
  } else { $newDir = @($NewLines | Where-Object { $_ -notmatch '^\s*HostKeyAlias(\s|=)' }) }
  $newDir += ($ind + 'HostKeyAlias ' + $NewAlias)
  $out = @()
  if ($b.Start -gt 0) { $out += $lines[0..($b.Start - 1)] }
  $out += "Host $Old"; $out += $newDir; $out += ''; $out += "Host $Old-old"; $out += $oldDir
  if ($body.Last + 1 -le $lines.Count - 1) { $out += $lines[($body.Last + 1)..($lines.Count - 1)] }
  @{ Text = ($out -join $nl); Changed = $true; Why = 'ok' }
}
# reverse (a `back` that ends on old), by content: `Host <old>` is rebuilt from `Host <old>-old`, which is removed; nothing else changes. Skipped without a -old block.
function Convert-MoveSshBack([string]$Text, [string]$Old) {
  $nl = if ($Text -match "`r`n") { "`r`n" } else { "`n" }
  $lines = @($Text -split '\r?\n')
  $ob = Find-MoveHostBlock $lines "$Old-old"
  if (-not $ob) { return @{ Text = $Text; Changed = $false; Why = 'no-old-block' } }
  $cur = Find-MoveHostBlock $lines $Old
  if (@($ob.Names).Count -ne 1 -or ($cur -and @($cur.Names).Count -ne 1)) { return @{ Text = $Text; Changed = $false; Why = 'shared-block' } }
  if (-not $cur) { $lines[$ob.Start] = "Host $Old"; return @{ Text = ($lines -join $nl); Changed = $true; Why = 'ok' } }
  $obody = Get-MoveBlockBody $lines $ob
  $oldDir = @(if ($obody.Last -ge $obody.First) { $lines[$obody.First..$obody.Last] })
  $cb = Get-MoveBlockBody $lines $cur
  $rmFrom = $ob.Start; if ($rmFrom -gt 0 -and $lines[$rmFrom - 1].Trim() -eq '') { $rmFrom-- }
  $out = New-Object 'System.Collections.Generic.List[string]'
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($i -ge $rmFrom -and $i -le $obody.Last) { continue }
    if ($i -eq $cb.First) { foreach ($d in $oldDir) { $out.Add([string]$d) } }
    if ($i -ge $cb.First -and $i -le $cb.Last) { continue }
    $out.Add([string]$lines[$i])
  }
  @{ Text = ($out -join $nl); Changed = $true; Why = 'ok' }
}
# Reach-Old: the alias every laptop ssh to the OLD machine uses = `<old>-old` while that Host block exists, else `<old>`. Derived at every call, never stored.
function Get-MoveReachOld([string]$OldAlias) {
  try {
    $p = Get-MoveSshConfigPath
    if ([IO.File]::Exists($p) -and (Find-MoveHostBlock @([IO.File]::ReadAllText($p) -split '\r?\n') "$OldAlias-old")) { return "$OldAlias-old" }
  } catch { }
  $OldAlias
}
# append a known_hosts line unless it is already there (by content); $true when written
function Add-MoveKnownHost([string]$Path, [string]$Line) {
  $t = if ([IO.File]::Exists($Path)) { [IO.File]::ReadAllText($Path) } else { '' }
  foreach ($l in @($t -split '\r?\n')) { if ($l.Trim() -ceq $Line) { return $false } }
  $nl = if ($t -match "`r`n") { "`r`n" } else { "`n" }
  if ($t -and -not $t.EndsWith("`n")) { $t += $nl }
  Write-PhienText $Path ($t + $Line + $nl)
  $true
}
# `<new alias> <type> <key>`: the known_hosts name that `HostKeyAlias <new alias>` looks up
function Get-MoveAliasKnownLine($Machine) {
  $f = @("$($Machine.hostkey_line)" -split '\s+')
  if ($f.Count -ge 3) { "$($Machine.alias) $($f[1]) $($f[2])" } else { '' }
}
# post-cut chore (b): the laptop's alias follows the move. Returns 0 or 1 (printed).
function Set-MoveLaptopAlias($S) {
  $cfg = Get-MoveSshConfigPath
  $text = if ([IO.File]::Exists($cfg)) { [IO.File]::ReadAllText($cfg) } else { '' }
  $old = [string]$S.old.alias
  if ([string]$S.dir -ceq 'fwd') {
    $nd = Get-MoveNewDirectives $text ([string]$S.new.alias) ([string]$S.new.addr)
    if ($nd.Err) { Write-Host "lỗi: $($nd.Err)"; return 1 }
    $r = Convert-MoveSshFwd $text $old $nd.Lines ([string]$S.new.alias) $false
    if ($r.Why -ceq 'old-exists') { Write-Host "ssh config của máy này: đã có 'Host $old-old', giữ nguyên."; return 0 }
    if ($r.Why -ceq 'no-block') { Write-Host "lỗi: ~/.ssh/config của máy này không có khối 'Host $old' để chuyển sang máy mới (nó có nằm trong file Include không?)."; return 1 }
    if ($r.Why -ceq 'shared-block') { Write-Host "lỗi: khối 'Host $old' dùng chung dòng Host với tên khác; tách riêng ra rồi chạy lại cutover."; return 1 }
    $kh = Get-MoveAliasKnownLine $S.new
    if ($kh) { [void](Add-MoveKnownHost (Get-MoveKnownHostsPath) $kh) }
    $bak = Get-MovePath ('ssh_config.' + $S.move_id + '.bak')
    if ([IO.File]::Exists($cfg) -and -not [IO.File]::Exists($bak)) { [IO.File]::Copy($cfg, $bak) }
    Set-MoveProp $S.backups 'ssh_config' $bak
    Write-PhienText $cfg $r.Text
    Save-MoveState $S
    Write-Host "ssh config của máy này: 'Host $old' giờ vào máy mới; máy cũ là 'Host $old-old'."
    return 0
  }
  $r = Convert-MoveSshBack $text $old
  if ($r.Why -ceq 'shared-block') { Write-Host "lỗi: khối 'Host $old' hoặc '$old-old' dùng chung dòng Host với tên khác; tách riêng ra rồi chạy lại cutover."; return 1 }
  if (-not $r.Changed) { Write-Host "ssh config của máy này: không có 'Host $old-old', giữ nguyên."; return 0 }
  Write-PhienText $cfg $r.Text
  Write-Host "ssh config của máy này: 'Host $old' lại vào máy cũ; khối '$old-old' đã bỏ."
  0
}
function Invoke-MoveBox([string]$Script, [string[]]$ScriptArgs = @()) {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = @(Invoke-BoxScript ($Script -replace "`r`n", "`n") $ScriptArgs 2>&1 | ForEach-Object { "$_" }); $code = [int]$LASTEXITCODE } catch { $o = @("$($_.Exception.Message)"); $code = 1 } finally { $ErrorActionPreference = $old }
  @{ Code = $code; Lines = $o }
}
# post-cut chore (c): the same rewrite in the coder box's ~/.ssh/config through Invoke-BoxScript. An unreachable coder is a warning, never a failure. Returns 0 or 1.
function Set-MoveCoderAlias($S) {
  $rd = Invoke-MoveBox (Get-MoveCoderReadScript) @()
  $hit = @($rd.Lines | Where-Object { "$_" -cmatch '\AMOVE coder-config exists=(yes|no) b64=' } | Select-Object -First 1)
  if ($rd.Code -ne 0 -or -not $hit.Count) { Write-Host 'INV warn coder-unreachable'; return 0 }
  $b64 = ("$($hit[0])" -replace '\A.*\bb64=', '').Trim()
  try { $ctext = if ($b64) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) } else { '' } } catch { Write-Host 'INV warn coder-unreachable'; return 0 }
  $old = [string]$S.old.alias; $newCfg = '-'; $kh = '-'
  if ([string]$S.dir -ceq 'fwd') {
    $lt = if ([IO.File]::Exists((Get-MoveSshConfigPath))) { [IO.File]::ReadAllText((Get-MoveSshConfigPath)) } else { '' }
    $nd = Get-MoveNewDirectives $lt ([string]$S.new.alias) ([string]$S.new.addr)
    if ($nd.Err) { Write-Host "lỗi: $($nd.Err)"; return 1 }
    $r = Convert-MoveSshFwd $ctext $old $nd.Lines ([string]$S.new.alias) $true
    if ($r.Why -ceq 'no-block') { Write-Host "coder: ~/.ssh/config không có khối 'Host $old', không đổi gì ở đó."; return 0 }
    if ($r.Why -ceq 'shared-block') { Write-Host "lỗi: coder: khối 'Host $old' dùng chung dòng Host với tên khác; tách riêng ra rồi chạy lại cutover."; return 1 }
    if ($r.Changed) { $newCfg = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($r.Text)) }
    $l = Get-MoveAliasKnownLine $S.new; if ($l) { $kh = $l }
  } else {
    $r = Convert-MoveSshBack $ctext $old
    if ($r.Why -ceq 'shared-block') { Write-Host "lỗi: coder: khối 'Host $old' hoặc '$old-old' dùng chung dòng Host với tên khác."; return 1 }
    if ($r.Changed) { $newCfg = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($r.Text)) }
  }
  if ($newCfg -ceq '-' -and $kh -ceq '-') { Write-Host 'coder: ssh config đã đúng, giữ nguyên.'; return 0 }
  $w = Invoke-MoveBox (Get-MoveCoderWriteScript) @($newCfg, [string]$S.move_id, $kh)
  if ($w.Code -ne 0) { Write-Host "lỗi: coder: không ghi được ssh config (mã $($w.Code)). Chạy lại cutover."; return 1 }
  if ($newCfg -cne '-' -and [string]$S.dir -ceq 'fwd') { Set-MoveProp $S.backups 'coder_ssh_config' ('~/.ssh/config.fcode-move.' + $S.move_id + '.bak') }
  if ($kh -cne '-') { Set-MoveProp $S.backups 'coder_known_hosts' ('~/.ssh/known_hosts.fcode-move.' + $S.move_id + '.bak') }
  Save-MoveState $S
  Write-Host 'coder: ssh config đã cập nhật.'
  0
}

# ---- the manifest the laptop keeps, preflight facts, the laptop refusals of plan step (6) ----
# `manifest <id>` on a machine: @{ Code; Text; Sha; Obj }; the sha256 of the bytes must equal the line the server prints
function Get-MoveRemoteManifest([string]$HostName, [string]$Id) {
  $r = Invoke-MoveGate $HostName 'manifest' $Id
  if ($r.Code -ne 0) { return @{ Code = $r.Code } }
  $b64 = ''; $sha = ''
  foreach ($l in $r.Lines) {
    if ("$l" -match '\AMOVE manifest b64=(\S+)\s*\z') { $b64 = $Matches[1] }
    elseif ("$l" -match '\AMOVE manifest-sha ([0-9a-f]{64})\s*\z') { $sha = $Matches[1] }
  }
  if (-not $b64 -or -not $sha) { Write-Host 'lỗi: máy không trả manifest (thiếu dòng MOVE manifest).'; return @{ Code = 1 } }
  while ($b64.Length % 4) { $b64 += '=' }
  try { $bytes = [Convert]::FromBase64String($b64) } catch { Write-Host 'lỗi: manifest không giải mã được.'; return @{ Code = 1 } }
  if ($bytes.Length -gt 1048576 -or (Get-MoveSha256Hex $bytes) -cne $sha) { Write-Host 'lỗi: manifest nhận về không khớp sha256 của máy gửi.'; return @{ Code = 1 } }
  $text = [Text.Encoding]::UTF8.GetString($bytes)
  try { $obj = ConvertFrom-Json $text } catch { Write-Host 'lỗi: manifest không phải JSON.'; return @{ Code = 1 } }
  if ($obj.schema -ne 1 -or "$($obj.move_id)" -cne $Id) { Write-Host 'lỗi: manifest của lần chuyển khác.'; return @{ Code = 1 } }
  @{ Code = 0; Text = $text; Sha = $sha; Obj = $obj }
}
function Save-MoveManifest([string]$Text) { Write-PhienText (Get-MovePath 'manifest.json') $Text }
# the saved manifest: @{ Text; Sha; Obj } or $null
function Read-MoveManifestFile {
  $p = Get-MovePath 'manifest.json'
  if (-not [IO.File]::Exists($p)) { return $null }
  try { $b = [IO.File]::ReadAllBytes($p); $t = [Text.Encoding]::UTF8.GetString($b); @{ Text = $t; Sha = (Get-MoveSha256Hex $b); Obj = (ConvertFrom-Json $t) } } catch { $null }
}
# the INV lines of the preflight script
function ConvertFrom-MovePreflight($Lines) {
  $f = @{ HasHost = $false; Arch = ''; Os = ''; FreeMb = -1.0; MoveId = '-'; Peer = '-'; Projects = 0; Files = @(); Units = @(); Smtp = 'unknown' }
  foreach ($l in @($Lines)) {
    if ("$l" -cnotmatch '\AINV ') { continue }
    $p = ConvertFrom-MoveLine "$l"; $w = $p.Words; $k = $p.Kv
    if ($w.Count -lt 2) { continue }
    switch -CaseSensitive ($w[1]) {
      'host' { $f.HasHost = $true; $f.Arch = [string]$k['arch']; $f.Os = [string]$k['os'] }
      'disk' { if ($k['mount'] -ceq '/' -and "$($k['free_mb'])" -match '\A[0-9]+\z') { $f.FreeMb = [double]$k['free_mb'] } }
      'egress' { $f.Smtp = [string]$k['smtp'] }
      'target' { $f.MoveId = [string]$k['moveid']; $f.Peer = [string]$k['peer']; if ("$($k['projects'])" -match '\A[0-9]+\z') { $f.Projects = [int]$k['projects'] } }
      'target-file' { if ($w.Count -ge 3) { $f.Files += $w[2] } }
      'target-unit' { if ($w.Count -ge 3) { $f.Units += $w[2] } }
    }
  }
  $f
}
# free MB of `/` in the `INV disk` lines of a plan on src, -1 when there is none
function Get-MoveDiskFree($Lines) {
  foreach ($l in @($Lines)) {
    if ("$l" -cmatch '\AINV disk ') { $p = ConvertFrom-MoveLine "$l"; if ($p.Kv['mount'] -ceq '/' -and "$($p.Kv['free_mb'])" -match '\A[0-9]+\z') { return [double]$p.Kv['free_mb'] } }
  }
  -1.0
}
function Get-MoveOsKey([string]$Os) { $p = @("$Os" -split '-', 2); $mj = (@("$($p[1])" -split '\.'))[0]; "$($p[0])-$mj" }
# the refusals of plan step (6) as `INV refuse ...` lines. $M = manifest, $D = preflight facts of dst, $SrcFree = src `/` free MB, $Repos = state repos.
# `target-not-empty` and `target-access-path` are not checked in a `back` run ($Back).
function Get-MoveRefusals($M, $D, [double]$SrcFree, [bool]$ReachOk, $Repos, [string]$OldAlias, [bool]$Back, [bool]$DstHome) {
  $r = New-Object 'System.Collections.Generic.List[string]'
  $sumAll = 0.0; $db = 0.0
  foreach ($it in @($M.items)) {
    $sz = [double]$it.size_mb; $sumAll += $sz
    if ((@('pgdb', 'pgroles') -ccontains [string]$it.kind) -or ([string]$it.kind -ceq 'image' -and $it.meta.local -eq $true)) { $db += $sz }
  }
  if ([string]$M.host.arch -cne $D.Arch) { $r.Add("INV refuse arch src=$($M.host.arch) dst=$($D.Arch)") }
  if ((Get-MoveOsKey ([string]$M.host.os)) -cne (Get-MoveOsKey $D.Os)) { $r.Add("INV refuse os src=$($M.host.os) dst=$($D.Os)") }
  $foreign = ($D.MoveId -ceq '-' -or $D.Peer -cne $OldAlias)
  # dst already holds this peer's copy (a re-plan after copy) or is old in a back run (it still holds everything): only the dump space is still needed
  $needDst = $(if ($Back -or -not $foreign) { 2 * $db + 4096 } else { [Math]::Ceiling(1.2 * $sumAll) + 2 * $db + 4096 })
  if ($D.FreeMb -lt 0 -or $D.FreeMb -lt $needDst) { $r.Add("INV refuse disk side=dst need_mb=$([int64]$needDst) free_mb=$(if ($D.FreeMb -lt 0) { 'unknown' } else { [int64]$D.FreeMb })") }
  $needSrc = $db + 4096
  if ($SrcFree -lt 0 -or $SrcFree -lt $needSrc) { $r.Add("INV refuse disk side=src need_mb=$([int64]$needSrc) free_mb=$(if ($SrcFree -lt 0) { 'unknown' } else { [int64]$SrcFree })") }
  if (-not $Back -and $D.Projects -gt 0 -and $foreign) { $r.Add("INV refuse target-not-empty projects=$($D.Projects)") }
  if (-not $Back -and $foreign) {
    $seen = @{}
    foreach ($it in @($M.items)) {
      if ([string]$it.kind -ceq 'tunnel') { foreach ($root in @($it.roots)) { if (@($D.Files) -ccontains [string]$root -and -not $seen["file=$root"]) { $seen["file=$root"] = $true; $r.Add("INV refuse target-access-path file=$root") } } }
      foreach ($u in @($it.meta.connector_units)) { if ($u -and @($D.Units) -ccontains [string]$u -and -not $seen["unit=$u"]) { $seen["unit=$u"] = $true; $r.Add("INV refuse target-access-path unit=$u") } }
    }
  }
  if ($DstHome) { foreach ($a in @(@($Repos | Where-Object { $_.kind -ceq 'gate-push' } | ForEach-Object { [string]$_.app }) | Select-Object -Unique)) { $r.Add("INV refuse push-deploy-unreachable app=$a") } }
  if (-not $ReachOk) { $r.Add('INV refuse old-unreachable') }
  $r.ToArray()
}
# plan step (5): push deploys of every app with a repo. @{ Code; Repos = @(state entries); Lines = @(INV lines) }; Code 1 = gh could not tell (nothing is registered)
function Get-MovePushScan($Apps, [string]$OldAddr) {
  $repos = @(); $lines = @()
  foreach ($a in @($Apps)) {
    $repo = [string]$a.repo; $app = [string]$a.name
    if (-not $repo) { continue }
    $legacy = ([string]$a.kind -ceq 'legacy')
    if (-not (Test-DeployRepo $repo)) { Write-Host "lỗi: repo '$repo' của app $app không đúng dạng chủ/repo."; return @{ Code = 1 } }
    $sec = Invoke-MoveTool 'gh' @('secret', 'list', '-R', $repo)
    if ($sec.Code -ne 0) { Write-Host "lỗi: gh không đọc được tên secret của $repo (mã $($sec.Code)); chưa xác nhận được push deploy. Chạy gh auth login rồi plan lại."; return @{ Code = 1 } }
    $secNames = @($sec.Out | ForEach-Object { @("$_" -split '\s+')[0] } | Where-Object { $_ })
    $ls = Invoke-MoveTool 'gh' @('api', "repos/$repo/contents/.github/workflows")
    $files = @()
    if ($ls.Code -eq 0) {
      try { $j = ConvertFrom-Json ($ls.Out -join "`n"); $files = @(foreach ($e in @($j)) { [string]$e.name }) | Where-Object { $_ -cmatch '\A[A-Za-z0-9._-]+\.ya?ml\z' } } catch { Write-Host "lỗi: gh trả danh sách workflow của $repo không đọc được."; return @{ Code = 1 } }
    } elseif (($ls.Out -join ' ') -notmatch '404|Not Found') { Write-Host "lỗi: gh không đọc được workflow của $repo (mã $($ls.Code))."; return @{ Code = 1 } }
    $states = @{}
    if (@($files).Count) {
      $wl = Invoke-MoveTool 'gh' @('workflow', 'list', '-R', $repo, '--all', '--json', 'path,state')
      if ($wl.Code -ne 0) { Write-Host "lỗi: gh không đọc được trạng thái workflow của $repo (mã $($wl.Code))."; return @{ Code = 1 } }
      try { $wj = ConvertFrom-Json ($wl.Out -join "`n"); foreach ($e in @($wj)) { $states[[string]$e.path] = [string]$e.state } } catch { Write-Host "lỗi: gh trả trạng thái workflow của $repo không đọc được."; return @{ Code = 1 } }   # foreach over $wj: Windows PowerShell 5.1 gives a JSON array as ONE object
    }
    $found = 0
    foreach ($f in @($files)) {
      $tx = Invoke-MoveTool 'gh' @('api', "repos/$repo/contents/.github/workflows/$f", '-H', 'Accept: application/vnd.github.raw')
      if ($tx.Code -ne 0) { Write-Host "lỗi: gh không đọc được workflow $f của $repo (mã $($tx.Code))."; return @{ Code = 1 } }
      $t = $tx.Out -join "`n"
      $kind = ''
      if ($t -match 'secrets\.DEPLOY_KNOWN_HOSTS\b') { if ($legacy) { $kind = 'gate-push' } else { continue } }   # CONTRACT section 8: only a `legacy` app has gate-push workflows; for a gate / unmanaged app the workflow is ignored (the conversion disabled it)
      elseif ($t -match 'secrets\.(VPS_HOST|VPS_SSH_KEY|SSH_PRIVATE_KEY|DEPLOY_SSH_KEY)\b' -or ($OldAddr -and $t.Contains($OldAddr))) { $kind = 'ssh-push' }
      if (-not $kind) { continue }
      $found++
      $st = $states[".github/workflows/$f"]
      $repos += [pscustomobject][ordered]@{ repo = $repo; app = $app; kind = $kind; workflow = $f; enabled = $(if ($st) { $st -ceq 'active' } else { $true }) }
      $lines += "INV push $repo app=$app kind=$kind workflow=$f"
      if ($kind -ceq 'ssh-push') { $lines += "INV warn ssh-push repo=$repo app=$app workflow=$f" }
    }
    $unv = if ($legacy) { '\A(VPS_HOST|VPS_SSH_KEY|SSH_PRIVATE_KEY|DEPLOY_SSH_KEY|DEPLOY_KNOWN_HOSTS)\z' } else { '\A(VPS_HOST|VPS_SSH_KEY|SSH_PRIVATE_KEY|DEPLOY_SSH_KEY)\z' }   # a DEPLOY_KNOWN_HOSTS secret alone says nothing about a converted app
    if (-not $found -and @($secNames | Where-Object { $_ -cmatch $unv }).Count) { $lines += "INV warn ssh-push repo=$repo app=$app unverified" }
  }
  @{ Code = 0; Repos = $repos; Lines = $lines }
}


# ---- questions (DESIGN.md section 1, verbatim). The agent asks in chat; the CLI also needs the typed word YES, as `deploy add` does ----
function Get-MoveMinutes($S) { [int][Math]::Max(1, [Math]::Ceiling([double]$S.est_downtime_s / 60)) }
function Get-MoveQuestion([string]$Kind, $S) {
  $n = Get-MoveMinutes $S
  switch -CaseSensitive ($Kind) {
    'cut' { "Chuyển tất cả ứng dụng sang máy mới bây giờ? Mọi ứng dụng sẽ cùng tạm dừng một lần, khoảng $n phút. Nếu có lỗi trước khi chuyển xong, máy cũ tự chạy lại như cũ. Các workflow GitHub deploy thẳng vào máy cũ qua SSH sẽ bị tắt. (Có/Không)" }
    'back' {
      if ([string]$S.dir -ceq 'back') { "Quay lại máy cũ? Dữ liệu ghi ở máy mới sẽ được chép ngược về máy cũ; mọi ứng dụng cùng tạm dừng một lần, khoảng $n phút. (Có/Không)" }
      else { "Chuyển lại sang máy mới? Dữ liệu ghi ở máy cũ sẽ được chép sang máy mới; mọi ứng dụng cùng tạm dừng một lần, khoảng $n phút. (Có/Không)" }
    }
    'finish' { 'Máy cũ có thể bỏ được chưa? Lệnh sẽ tắt hẳn ứng dụng trên máy cũ và xoá khoá chuyển máy. Sau bước này KHÔNG quay lại được nữa. Huỷ gói VPS cũ ở trang Contabo do bạn tự làm. (Có/Không)' }
    'finish-early' { 'Mới chuyển chưa đủ 72 giờ. Vẫn bỏ máy cũ ngay? (Có/Không)' }
    'abandon' {
      $running = if ([string]$S.dir -ceq 'fwd') { [string]$S.old.alias } else { [string]$S.new.alias }
      "Huỷ lần chuyển này? Ứng dụng vẫn chạy ở máy $running; khoá chuyển máy và file tạm bị xoá. Máy mới vẫn giữ bản sao dữ liệu và mật khẩu của các ứng dụng (đã tắt). Nếu không dùng máy mới nữa, hãy xoá hoặc cài lại máy đó. (Có/Không)"
    }
  }
}
function Confirm-MoveYes([string]$Question) {
  Write-Host ''
  Write-Host $Question
  $ans = Read-SyncLine 'Gõ YES để đồng ý (chữ khác = huỷ): '
  [bool]($null -ne $ans -and $ans.Trim() -ceq 'YES')
}
function New-MoveAnswer { [pscustomobject][ordered]@{ a = 'yes'; ts = (Format-MoveTs (Get-MoveNow)) } }

# ---- the re-run table (CONTRACT section 8): what a command does in the phase / mark of the state ----
# @{ Do = refuse | plan-new | replan | copy | cutover | cutover-continue | chores | finish | abandon | abandon-rollback | done | back-start | back-copy-cutover; Msg }
function Resolve-MoveAction([string]$Cmd, $S) {
  $phase = if ($S) { [string]$S.phase } else { 'none' }
  $mark = if ($S) { [string]$S.mark } else { '' }
  $isBack = [bool]($S -and [string]$S.via -ceq 'back')
  $ref = @{ Do = 'refuse'; Msg = "lệnh '$Cmd' không dùng được khi lần chuyển đang ở giai đoạn '$phase'$(if ($mark) { " (đang $mark)" })." }
  $viaPlan = @{ Do = 'refuse'; Msg = "lệnh '$Cmd': lần chuyển này bắt đầu bằng 'fcode move plan', chưa chuyển xong nên chưa dùng được; giai đoạn '$phase'." }
  $viaBack = @{ Do = 'refuse'; Msg = "lệnh '$Cmd': lần chuyển này bắt đầu bằng 'fcode move back'; chạy tiếp bằng  fcode move back  (giai đoạn '$phase')." }
  if ($phase -ceq 'none') {
    if ($Cmd -ceq 'plan') { return @{ Do = 'plan-new' } }
    return @{ Do = 'refuse'; Msg = "lệnh '$Cmd': chưa có lần chuyển nào; chạy  fcode move plan <máy mới>  trước." }
  }
  if ($mark) {   # a cutover is in flight (cutting / switching / rolling-back), in any phase: the mark decides, never answers or dst_started
    $srcA = if ([string]$S.dir -ceq 'fwd') { [string]$S.old.alias } else { [string]$S.new.alias }; $dstA = if ([string]$S.dir -ceq 'fwd') { [string]$S.new.alias } else { [string]$S.old.alias }
    if ($Cmd -ceq 'cutover' -or ($Cmd -ceq 'back' -and $isBack)) { return @{ Do = 'cutover-continue' } }
    if ($Cmd -ceq 'finish' -and $mark -cne 'switching') { return @{ Do = 'abandon-rollback' } }
    if ($mark -ceq 'switching') { return @{ Do = 'refuse'; Msg = "lệnh '$Cmd' không dùng được: cutover đang ở bước switch (mark 'switching'); ứng dụng có thể đã chạy ở máy '$dstA' và đang nhận truy cập. Chỉ có một đường đi: chạy  fcode move cutover  (lần quay lại: fcode move back) để làm nốt; sau khi xong, muốn về lại máy '$srcA' thì dùng  fcode move back  (dữ liệu được chép về)." } }
    return @{ Do = 'refuse'; Msg = "lệnh '$Cmd' không dùng được: một cutover đang dở (mark '$mark'; ứng dụng có thể đang tạm dừng ở máy '$srcA'). Hai cách đi tiếp: chạy  fcode move cutover  (lần quay lại: fcode move back) để làm nốt, hoặc  fcode move finish  để cho ứng dụng chạy lại ở máy '$srcA' rồi huỷ lần chuyển." }
  }
  switch -CaseSensitive ($phase) {
    'finished' {
      if ($Cmd -ceq 'plan') { return @{ Do = 'plan-new' } }
      if ($Cmd -ceq 'finish') { return @{ Do = 'done' } }
      return $ref
    }
    'planned' {
      if ($Cmd -ceq 'plan') { if ($isBack) { return $viaBack }; return @{ Do = 'replan' } }
      if ($Cmd -ceq 'copy') { return @{ Do = 'copy' } }
      if ($Cmd -ceq 'finish') { return @{ Do = 'abandon' } }
      if ($Cmd -ceq 'back') { if ($isBack) { return @{ Do = 'back-copy-cutover' } }; return $viaPlan }
      return $ref
    }
    { $_ -ceq 'copied' -or $_ -ceq 'rolled-back' } {   # mark null: the apps run on src and the move has stopped nothing
      if ($Cmd -ceq 'plan') { if ($isBack) { return $viaBack }; return @{ Do = 'replan' } }
      if ($Cmd -ceq 'copy') { return @{ Do = 'copy' } }
      if ($Cmd -ceq 'cutover') { return @{ Do = 'cutover' } }
      if ($Cmd -ceq 'finish') { return @{ Do = 'abandon' } }
      if ($Cmd -ceq 'back') { if ($isBack) { return @{ Do = 'cutover' } }; return $viaPlan }
      return $ref
    }
    'cut' {
      if ($Cmd -ceq 'cutover') { return @{ Do = 'chores' } }
      if ($Cmd -ceq 'finish') { return @{ Do = 'finish' } }
      if ($Cmd -ceq 'back') { return @{ Do = 'back-start' } }
      return $ref
    }
  }
  $ref
}

# ---- hosts: src / dst follow `dir`; every laptop ssh to old goes through Reach-Old, derived at every call ----
function Get-MoveOldHost($S) { Get-MoveReachOld ([string]$S.old.alias) }
function Get-MoveNewHost($S) { [string]$S.new.alias }
function Get-MoveSrcHost($S) { if ([string]$S.dir -ceq 'fwd') { Get-MoveOldHost $S } else { Get-MoveNewHost $S } }
function Get-MoveDstHost($S) { if ([string]$S.dir -ceq 'fwd') { Get-MoveNewHost $S } else { Get-MoveOldHost $S } }
function Get-MoveItemRoots($Obj, [string]$Id) { foreach ($it in @($Obj.items)) { if ([string]$it.id -ceq $Id) { foreach ($r in @($it.roots)) { [string]$r } } } }
function Get-MoveCap($Obj) { $c = 1800; foreach ($a in @($Obj.apps)) { if ([int]$a.guard_cap_s -gt $c) { $c = [int]$a.guard_cap_s } }; $c }
function ConvertTo-MoveJsonStr([string]$s) { ConvertTo-Json -InputObject $s -Compress }
# stdin of `init`: the manifest goes in byte for byte (its sha256 is manifest_sha); pub only for old, peer_* only for new
function New-MoveInitJson([string]$Machine, [string]$Peer, [string]$Sha, [string]$ManifestText, [string]$Pub, [string]$PeerAddr, [int]$PeerPort, [string]$PeerHostKey, [string]$NewKind = 'vps') {
  $j = '{"schema":1,"machine":' + (ConvertTo-MoveJsonStr $Machine) + ',"peer":' + (ConvertTo-MoveJsonStr $Peer) + ',"new_kind":' + (ConvertTo-MoveJsonStr $NewKind) + ',"manifest_sha":"' + $Sha + '","manifest":' + $ManifestText.Trim()   # A30: new_kind on both machines
  if ($Pub) { $j += ',"pub":' + (ConvertTo-MoveJsonStr $Pub) }
  if ($PeerAddr) { $j += ',"peer_addr":' + (ConvertTo-MoveJsonStr $PeerAddr) + ',"peer_port":' + $PeerPort + ',"peer_hostkey":' + (ConvertTo-MoveJsonStr $PeerHostKey) }
  $j + '}'
}

# ---- plan (sequence 1) ----
# steps (2)-(6) for the run in $S (nothing is saved here). @{ Code; Obj; Text; Sha; Repos }; Code 0 = nothing refused. $Back: a `back` run (no scan, no target checks).
function Invoke-MovePlanSteps($S, [string]$MapText, [string]$FromText, [bool]$Back) {
  $id = [string]$S.move_id
  $src = Get-MoveSrcHost $S; $dst = Get-MoveDstHost $S; $newH = Get-MoveNewHost $S
  $oi = Get-MoveSshInfo (Get-MoveOldHost $S); $ni = Get-MoveSshInfo $newH
  if (-not $oi -or -not $ni) { Write-Host 'lỗi: ssh -G không đọc được cấu hình của máy cũ hoặc máy mới.'; return @{ Code = 1 } }
  Write-Host "plan: kiểm tra máy đích '$dst'..."
  $pf = Invoke-MoveScript $dst (Get-MovePreflightScript) @()
  $D = ConvertFrom-MovePreflight $pf.Lines
  if ($pf.Code -ne 0 -or -not $D.HasHost) { Write-Host 'INV refuse target-unreachable'; return @{ Code = 65 } }
  $reachOk = $false
  if ("$($S.old.addr)" -cmatch '\A[A-Za-z0-9._:-]{1,255}\z') { $rc = Invoke-MoveScript $newH (Get-MoveTcpScript) @([string]$S.old.addr, [string]$oi.Port) -Quiet; $reachOk = ($rc.Code -eq 0) }
  Write-Host ('INV reach old=' + $(if ($reachOk) { 'yes' } else { 'no' }))
  Write-Host "plan: máy nguồn '$src' lập manifest..."
  $json = '{"schema":1,"map":' + $(if ($MapText) { $MapText.Trim() } else { 'null' }) + ',"from":' + $(if ($FromText) { $FromText.Trim() } else { 'null' }) + '}'
  $jb = [Text.Encoding]::UTF8.GetBytes($json)
  if ($jb.Length -gt 2097152) { Write-Host 'INV refuse map-invalid'; return @{ Code = 65 } }
  $pr = Invoke-MoveGate $src 'plan' $id @() ([Convert]::ToBase64String($jb))
  if ($pr.Code -eq 255) { Write-Host $(if ([string]$S.dir -ceq 'fwd') { 'INV refuse old-unreachable' } else { 'INV refuse target-unreachable' }); return @{ Code = 65 } }
  if ($pr.Code -ne 0 -and $pr.Code -ne 65) { return @{ Code = (ConvertTo-MoveExit $pr.Code) } }
  $serverRefused = @($pr.Lines | Where-Object { "$_" -cmatch '\AINV refuse ' }).Count -gt 0 -or $pr.Code -eq 65
  $mf = Get-MoveRemoteManifest $src $id
  if ($mf.Code -ne 0) { return @{ Code = $(if ($serverRefused) { 65 } else { ConvertTo-MoveExit $mf.Code }) } }
  $repos = @($S.repos)
  if (-not $Back) {
    $sc = Get-MovePushScan $mf.Obj.apps ([string]$S.old.addr)
    if ($sc.Code -ne 0) { return @{ Code = $sc.Code } }
    foreach ($l in @($sc.Lines)) { Write-Host $l }
    $repos = @($sc.Repos)
  }
  $dstHome = [bool](-not $Back -and [string]$S.new.kind -ceq 'home')
  $ref = @(Get-MoveRefusals $mf.Obj $D (Get-MoveDiskFree $pr.Lines) $reachOk $repos ([string]$S.old.alias) $Back $dstHome)
  foreach ($l in $ref) { Write-Host $l }
  if ("$($S.new.addr)" -cmatch '\A[A-Za-z0-9._:-]{1,255}\z') { $cb = Invoke-MoveBox (Get-MoveTcpScript) @([string]$S.new.addr, [string]$ni.Port); if ($cb.Code -ne 0) { Write-Host 'INV warn coder-unreachable' } }
  if ($serverRefused -or $ref.Count) { return @{ Code = 65 } }
  @{ Code = 0; Obj = $mf.Obj; Text = $mf.Text; Sha = $mf.Sha; Repos = $repos }
}
# fcode move plan <new alias> [--map f]: a new move ($New) or a re-plan of the move in $S0. Returns the exit code.
function Invoke-MovePlan($S0, [string]$Alias, [string]$MapFile, [bool]$New) {
  if (-not $Alias -and $S0 -and -not $New) { $Alias = [string]$S0.new.alias }
  if ($Alias -cnotmatch '\A[a-z][a-z0-9-]{0,30}\z') { Write-Host 'Cách dùng: fcode move plan <máy mới> [--map <file>]   (<máy mới> = tên ssh: chữ thường, số, dấu -, bắt đầu bằng chữ)'; return 65 }
  $oldAlias = if ($New) { Get-DeployHost } else { [string]$S0.old.alias }
  if (-not $oldAlias) { Write-Host 'lỗi: deployHost trong file cấu hình không dùng được (chỉ chữ, số, dấu . _ @ -).'; return 1 }
  if ($oldAlias -cnotmatch '\A[a-z][a-z0-9-]{0,30}\z') { Write-Host "lỗi: tên ssh của máy cũ ('$oldAlias') không dùng được cho fcode move (chữ thường, số, dấu -, bắt đầu bằng chữ; đổi deployHost hoặc đặt lại tên Host)."; return 65 }
  if ($Alias -ceq $oldAlias) { Write-Host "lỗi: máy mới không thể trùng tên ssh với máy cũ ($oldAlias)."; return 65 }
  if (-not $New -and $Alias -cne [string]$S0.new.alias) { Write-Host "lỗi: lần chuyển này nhắm máy '$($S0.new.alias)'. Muốn đổi máy: fcode move finish (huỷ lần này) rồi plan lại."; return 65 }
  if ($New -and (Get-MoveReachOld $oldAlias) -cne $oldAlias) { Write-Host "lỗi: ~/.ssh/config đã có 'Host $oldAlias-old' (lần chuyển trước chưa dọn). Xoá khối đó khi máy cũ đã bỏ, rồi plan lại."; return 65 }
  $mapText = $null
  if ($MapFile) {
    try { $mb = [IO.File]::ReadAllBytes($MapFile); $mapText = [Text.Encoding]::UTF8.GetString($mb).TrimStart([char]0xFEFF); if ($mb.Length -gt 16384) { throw 'quá 16 KiB' }; [void](ConvertFrom-Json $mapText) }
    catch { Write-Host "lỗi: move-map không đọc được ($($_.Exception.Message))."; Write-Host 'INV refuse map-invalid'; return 65 }
  } elseif (-not $New -and [IO.File]::Exists((Get-MovePath 'move-map.json'))) { $mapText = [IO.File]::ReadAllText((Get-MovePath 'move-map.json')) }
  $oldHost = if ($New) { $oldAlias } else { Get-MoveOldHost $S0 }
  $oi = Get-MoveSshInfo $oldHost; $ni = Get-MoveSshInfo $Alias
  if (-not $oi -or -not $ni) { Write-Host "lỗi: ssh -G không đọc được cấu hình của '$oldHost' hoặc '$Alias'."; return 1 }
  # the alias rewrite of the cutover (chore b) needs `Host <old>` and `Host <new>` as their own blocks directly in ~/.ssh/config: find out now, not after the cut
  $cfgP = Get-MoveSshConfigPath
  $cfgT = if ([IO.File]::Exists($cfgP)) { [IO.File]::ReadAllText($cfgP) } else { '' }
  $dnd = Get-MoveNewDirectives $cfgT $Alias ([string]$ni.Addr)
  $drw = if ($dnd.Err) { $null } else { Convert-MoveSshFwd $cfgT $oldAlias $dnd.Lines $Alias $false }
  if ($dnd.Err -or $drw.Why -in 'no-block', 'shared-block') {
    Write-Host 'lỗi: ~/.ssh/config của máy này không dùng được cho fcode move (chưa chạy gì).'
    Write-Host "  $(if ($dnd.Err) { $dnd.Err } elseif ($drw.Why -ceq 'shared-block') { "khối 'Host $oldAlias' dùng chung dòng Host với tên khác" } else { "không thấy khối 'Host $oldAlias' (nó có nằm trong file Include không?)" })"
    Write-Host "  Cần mỗi máy một khối 'Host <tên>' riêng, nằm thẳng trong ~/.ssh/config (không phải trong file Include): '$oldAlias' và '$Alias'."
    return 65
  }
  if ($New) {
    $mo = [pscustomobject][ordered]@{ alias = $oldAlias; addr = $oi.Addr; hostkey_line = ''; fp = '' }
    $mn = [pscustomobject][ordered]@{ alias = $Alias; kind = $(if (Test-MoveHome $ni) { 'home' } else { 'vps' }); addr = $ni.Addr; hostkey_line = ''; fp = '' }
    $S = New-MoveState ([guid]::NewGuid().ToString()) 'fwd' 'plan' $mo $mn
  } else {
    $S = $S0
    Set-MoveProp $S.old 'addr' $oi.Addr; Set-MoveProp $S.new 'addr' $ni.Addr; Set-MoveProp $S.new 'kind' $(if (Test-MoveHome $ni) { 'home' } else { 'vps' })
  }
  $r = Invoke-MovePlanSteps $S $mapText $null $false
  if ($r.Code -ne 0) { return $r.Code }
  $ok = Get-MoveHostKey $oi; $nk = Get-MoveHostKey $ni
  if (-not $ok) { Write-Host "INV refuse old-unreachable"; Write-Host "  (chưa có khoá máy của '$oldHost' trong known_hosts: chạy  ssh $oldHost  một lần để xác nhận rồi plan lại)"; return 65 }
  if (-not $nk) { Write-Host "INV refuse target-unreachable"; Write-Host "  (chưa có khoá máy của '$Alias' trong known_hosts: chạy  ssh $Alias  một lần để xác nhận rồi plan lại)"; return 65 }
  Set-MoveProp $S.old 'hostkey_line' $ok.Line; Set-MoveProp $S.old 'fp' $ok.Fp
  Set-MoveProp $S.new 'hostkey_line' $nk.Line; Set-MoveProp $S.new 'fp' $nk.Fp
  # `enabled` is the workflow's state at the FIRST plan: a re-plan keeps what is recorded (a cut-off cutover may have disabled it since)
  $merged = @(foreach ($n in @($r.Repos)) { $e = @(@($S.repos) | Where-Object { $_.repo -ceq $n.repo -and $_.workflow -ceq $n.workflow })[0]; if ($e) { $n.enabled = [bool]$e.enabled }; $n })
  Set-MoveProp $S 'repos' $merged
  Set-MoveProp $S 'manifest_sha' $r.Sha; Set-MoveProp $S 'est_downtime_s' ([int]$r.Obj.est_downtime_s); Set-MoveProp $S 'cap_s' (Get-MoveCap $r.Obj)
  Set-MoveProp $S 'phase' 'planned'; Set-MoveProp $S 'mark' $null
  Save-MoveManifest $r.Text
  $mp = Get-MovePath 'move-map.json'
  if ($mapText) { Write-PhienText $mp $mapText } elseif ([IO.File]::Exists($mp)) { [IO.File]::Delete($mp) }
  Save-MoveState $S
  Write-Host 'INV ok'
  Write-Host "Kế hoạch xong: ước tính tạm dừng khoảng $(Get-MoveMinutes $S) phút. Việc tiếp theo:  fcode move copy"
  0
}

# ---- copy (sequence 2) ----
# cut_not_before: the largest ttl of the a-record hostnames of the saved manifest (+60 s), never lowered
function Update-MoveCutNotBefore($S, $Obj) {
  $ttl = 0
  foreach ($h in @($Obj.hostnames)) { if ([string]$h.kind -ceq 'a-record' -and [int]$h.ttl -gt $ttl) { $ttl = [int]$h.ttl } }
  if ($ttl -le 0) { return }
  $nb = (Get-MoveNow).AddSeconds($ttl + 60)
  $cur = ConvertTo-MoveTime $S.cut_not_before
  if (-not $cur -or $nb -gt $cur) { Set-MoveProp $S 'cut_not_before' (Format-MoveTs $nb); Save-MoveState $S }
}
# new: poll `status` every 10 s until transfer=done|failed. 0 = done.
function Wait-MoveTransferEnd([string]$NewHost) {
  $last = ''; $idle = 0; $bad = 0
  while ($true) {
    Wait-Move 10
    $st = Invoke-MoveGate $NewHost 'status' '' @() -Quiet
    if ($st.Code -ne 0) { $bad++; if ($bad -ge 12) { Write-Host "lỗi: mất liên lạc với máy mới '$NewHost' khi đang chép."; return 1 }; continue }
    $bad = 0; $v = ''
    foreach ($l in $st.Lines) { if ("$l" -match '\AMOVE state .*\btransfer=([a-z]+)') { $v = $Matches[1] } }
    if ($v -cne $last) { Write-Host "transfer: $(if ($v) { $v } else { '?' })"; $last = $v }
    if ($v -ceq 'done') { return 0 }
    if ($v -ceq 'failed') { Write-Host "lỗi: transfer thất bại trên máy mới (xem /var/lib/fcode-move/transfer.out trên đó); chạy lại lệnh để thử lại."; return 1 }
    if ($v -ceq 'idle' -or -not $v) { $idle++; if ($idle -ge 4) { Write-Host 'lỗi: transfer không chạy trên máy mới.'; return 1 } } else { $idle = 0 }
  }
}
# `transfer` (a detached unit), then poll. A `--final` call that finds a transfer already RUNNING (a non-final one left by a killed `copy`) did not start the final pass:
# wait for that one to end, then call `--final` again and poll that.
function Invoke-MoveTransfer([string]$NewHost, [string]$Id, [bool]$Final) {
  $va = $(if ($Final) { @('--final') } else { @() })
  $r = Invoke-MoveGate $NewHost 'transfer' $Id $va
  if ($r.Code -ne 0) { return (ConvertTo-MoveExit $r.Code) }
  if ($Final -and @($r.Lines | Where-Object { "$_" -cmatch '\AMOVE transfer state=running\b' }).Count) {
    Write-Host 'Một lần chép trước đang chạy trên máy mới: chờ nó xong rồi chạy lượt chép nốt (--final).'
    $w = Wait-MoveTransferEnd $NewHost
    if ($w -ne 0) { return $w }
    $r = Invoke-MoveGate $NewHost 'transfer' $Id $va
    if ($r.Code -ne 0) { return (ConvertTo-MoveExit $r.Code) }
  }
  Wait-MoveTransferEnd $NewHost
}
# the machine must run no hold item or connector (`status` shows hold_active=0); 65 = dst-running
function Test-MoveHoldIdle([string]$HostName) {
  $r = Invoke-MoveGate $HostName 'status' ''
  if ($r.Code -ne 0) { return (ConvertTo-MoveExit $r.Code) }
  foreach ($l in $r.Lines) {
    if ("$l" -match '\AMOVE state .*\bhold_active=(\S+)') {
      if ($Matches[1] -ceq '0') { return 0 }
      if ($Matches[1] -ceq '-') { Write-Host "dừng: máy '$HostName' không đếm được ứng dụng đang chạy (hold_active=-); chưa coi là rảnh. Kiểm tra máy đó rồi chạy lại."; return 65 }
      Write-Host "dừng: máy '$HostName' đang chạy ứng dụng hoặc connector (dst-running). Kiểm tra máy đó rồi chạy lại."
      return 65
    }
  }
  Write-Host "lỗi: status của '$HostName' không có hold_active."
  1
}
function Invoke-MoveCopy($S) {
  $id = [string]$S.move_id; $fwd = ([string]$S.dir -ceq 'fwd')
  $src = Get-MoveSrcHost $S; $dst = Get-MoveDstHost $S; $newH = Get-MoveNewHost $S; $oldH = Get-MoveOldHost $S
  $mf = Read-MoveManifestFile
  if (-not $mf) { Write-Host 'lỗi: chưa có manifest đã lưu (manifest.json); chạy lại  fcode move plan.'; return 1 }
  $oi = Get-MoveSshInfo $oldH
  if (-not $oi) { Write-Host "lỗi: ssh -G không đọc được cấu hình của '$oldH'."; return 1 }
  Write-Host "copy (a): công cụ và khoá chuyển máy trên '$newH'..."
  $need = [Math]::Max(20, [int]$mf.Obj.host.node_major)
  $kr = Invoke-MoveScript $newH (Get-MoveBootstrapKeyScript) @([string]$S.new.alias, [string]$S.old.hostkey_line, "$need")
  if ($kr.Code -ne 0) { return (ConvertTo-MoveExit $kr.Code) }
  $pub = ''
  foreach ($l in $kr.Lines) { if ("$l" -match '\AMOVE key (created|exists) .*\bpub_b64=(\S+)') { $p = $Matches[2]; while ($p.Length % 4) { $p += '=' }; try { $pub = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) } catch { } } }
  if ($pub -cnotmatch '\Assh-ed25519 [A-Za-z0-9+/=]+\z') { Write-Host 'lỗi: máy mới không trả khoá công khai của khoá chuyển máy.'; return 1 }
  Write-Host "copy (b): tunnel trên '$src'..."
  Update-MoveCutNotBefore $S $mf.Obj
  $t = Invoke-MoveGate $src 'tunnels' $id
  if ($t.Code -ne 0) { Write-Host "copy dừng ở tunnels (mã $($t.Code)); sửa theo dòng MOVE ở trên rồi chạy lại fcode move copy."; return (ConvertTo-MoveExit $t.Code) }
  $m2 = Get-MoveRemoteManifest $src $id
  if ($m2.Code -ne 0) { return (ConvertTo-MoveExit $m2.Code) }
  Save-MoveManifest $m2.Text; Set-MoveProp $S 'manifest_sha' $m2.Sha; Save-MoveState $S
  Write-Host "copy (c): init trên máy cũ '$oldH'..."
  $ij = New-MoveInitJson 'old' ([string]$S.new.alias) $m2.Sha $m2.Text $pub '' 0 '' ([string]$S.new.kind)
  $r = Invoke-MoveGate $oldH 'init' $id @($(if ($fwd) { 'src' } else { 'dst' })) ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ij)))
  if ($r.Code -ne 0) { return (ConvertTo-MoveExit $r.Code) }
  Write-Host "copy (d): chép cổng deploy sang '$newH' khi chưa có..."
  $entry = @(Get-MoveItemRoots $m2.Obj 'gate-entry'); $lib = @(Get-MoveItemRoots $m2.Obj 'gate-lib'); $units = @(Get-MoveItemRoots $m2.Obj 'gate-units')
  $roots = @($entry) + @($lib) + @($units)
  if ($entry.Count -ne 1 -or $lib.Count -ne 1 -or @($roots | Where-Object { $_ -cnotmatch '\A/[A-Za-z0-9._/+@=,:-]{1,255}\z' }).Count -or "$($S.old.addr)" -cnotmatch '\A[A-Za-z0-9._:-]{1,255}\z') { Write-Host 'INV refuse gate-missing'; return 65 }
  $g = Invoke-MoveScript $newH (Get-MoveBootstrapGateScript) (@([string]$S.old.addr, [string]$oi.Port, $entry[0], $lib[0]) + $units)
  if ($g.Code -ne 0) { return (ConvertTo-MoveExit $g.Code) }
  Write-Host "copy (e): init trên máy mới '$newH'..."
  $nj = New-MoveInitJson 'new' ([string]$S.old.alias) $m2.Sha $m2.Text '' ([string]$S.old.addr) ([int]$oi.Port) ([string]$S.old.hostkey_line) ([string]$S.new.kind)
  $r = Invoke-MoveGate $newH 'init' $id @($(if ($fwd) { 'dst' } else { 'src' })) ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($nj)))
  if ($r.Code -ne 0) { return (ConvertTo-MoveExit $r.Code) }
  Write-Host "copy (f, g): prepare trên '$dst'..."
  $r = Invoke-MoveGate $dst 'prepare' $id
  if ($r.Code -ne 0) { return (ConvertTo-MoveExit $r.Code) }
  $h = Test-MoveHoldIdle $dst; if ($h -ne 0) { return $h }
  Write-Host "copy (h): dump trên '$src'..."
  $r = Invoke-MoveGate $src 'dump' $id
  if ($r.Code -ne 0) { return (ConvertTo-MoveExit $r.Code) }
  Write-Host "copy (i): chép dữ liệu (máy mới kéo / đẩy trực tiếp)..."
  $x = Invoke-MoveTransfer $newH $id $false; if ($x -ne 0) { return $x }
  Write-Host "copy (j): adopt và restore trên '$dst'..."
  foreach ($v in 'adopt', 'restore') { $r = Invoke-MoveGate $dst $v $id; if ($r.Code -ne 0) { return (ConvertTo-MoveExit $r.Code) } }
  Write-Host "copy (k): verify (chỉ báo cáo)..."
  $r = Invoke-MoveGate $newH 'verify' $id
  if ($r.Code -ne 0) { return (ConvertTo-MoveExit $r.Code) }
  Set-MoveProp $S 'phase' 'copied'; Save-MoveState $S
  Write-Host "Copy xong (giai đoạn: copied). Chạy lại fcode move copy để làm mới bất cứ lúc nào. Khi sẵn sàng:  fcode move cutover"
  0
}

# ---- cutover (sequence 3) ----
# the ssh-push workflows that were enabled at plan: disable / enable them (a workflow the user had disabled is never touched)
function Set-MoveWorkflows($S, [bool]$Enable) {
  $act = if ($Enable) { 'enable' } else { 'disable' }; $rc = 0
  foreach ($r in @(@($S.repos) | Where-Object { $_.kind -ceq 'ssh-push' -and $_.enabled -eq $true })) {
    $o = Invoke-MoveTool 'gh' @('workflow', $act, [string]$r.workflow, '-R', [string]$r.repo)
    if ($o.Code -ne 0 -and (($o.Out -join ' ') -notmatch "already $($act)d")) { Write-Host "lỗi: gh workflow $act $($r.workflow) -R $($r.repo) mã $($o.Code)."; $rc = 1 }
  }
  $rc
}
# wait (poll 10 s, cap 900 s) until no run of those workflows is queued or in progress; 1 = still busy or unreadable
function Wait-MoveRunsIdle($S) {
  $t0 = Get-MoveNow
  foreach ($r in @(@($S.repos) | Where-Object { $_.kind -ceq 'ssh-push' -and $_.enabled -eq $true })) {
    while ($true) {
      $busy = $false
      foreach ($st in 'queued', 'in_progress') {
        $o = Invoke-MoveTool 'gh' @('run', 'list', '-R', [string]$r.repo, '--workflow', [string]$r.workflow, '--status', $st, '--json', 'databaseId')
        if ($o.Code -ne 0) { Write-Host "lỗi: gh không đọc được các lượt chạy của $($r.workflow) ($($r.repo))."; return 1 }
        try { $j = ConvertFrom-Json ($o.Out -join "`n"); if ($null -ne $j -and @($j).Count -gt 0) { $busy = $true } } catch { Write-Host "lỗi: gh trả danh sách lượt chạy của $($r.repo) không đọc được."; return 1 }
      }
      if (-not $busy) { break }
      if (((Get-MoveNow) - $t0).TotalSeconds -ge 900) { Write-Host "lỗi: workflow $($r.workflow) ($($r.repo)) vẫn còn lượt chạy sau 900 giây."; return 1 }
      Wait-Move 10
    }
  }
  0
}
# a step that answers 75 (busy, nothing changed) is run again after the smallest retry_s of its MOVE wait lines, until the cap (counted from $T0) is over
function Invoke-MoveWaitStep([string]$HostName, [string]$Verb, [string]$Id, [string[]]$VArgs, [DateTime]$T0, [int]$Cap) {
  while ($true) {
    $r = Invoke-MoveGate $HostName $Verb $Id $VArgs
    if ($r.Code -ne 75) { return $r }
    $min = 0
    foreach ($l in $r.Lines) { if ("$l" -match '\AMOVE wait .*\bretry_s=([0-9]+)') { $v = [int]$Matches[1]; if ($v -gt 0 -and ($min -eq 0 -or $v -lt $min)) { $min = $v } } }
    if ($min -eq 0) { $min = 10 }
    if (((Get-MoveNow) - $T0).TotalSeconds -ge $Cap) { return @{ Code = 75; Lines = $r.Lines; Cap = $true } }
    Write-Host "busy ($Verb): thử lại sau $min giây..."
    Wait-Move $min
  }
}
function Invoke-MoveTry3([scriptblock]$Do) {
  for ($i = 1; $i -le 3; $i++) { $r = & $Do; if ($r.Code -eq 0) { return $true }; if ($i -lt 3) { Wait-Move 5 } }
  $false
}
# steps (2)-(11); @{ Code; Why; NoRollback }. Code 0 = phase cut reached. $Resume: mark switching = resume at step (10); $Resume9: a kill inside step 9 = resume at step (9).
function Invoke-MoveCutSteps($S, [bool]$Resume, [bool]$Resume9 = $false) {
  $id = [string]$S.move_id; $src = Get-MoveSrcHost $S; $dst = Get-MoveDstHost $S; $newH = Get-MoveNewHost $S
  if (-not $Resume -and -not $Resume9) {
    Write-Host '(2) tắt workflow deploy thẳng vào máy cũ qua SSH (nếu có)...'
    $w = Set-MoveWorkflows $S $false
    if ($w -eq 0) { $w = Wait-MoveRunsIdle $S }
    if ($w -ne 0) { return @{ Code = 1; Why = 'không tắt được workflow deploy' } }
    $t0 = Get-MoveNow; $cap = [int]$S.cap_s
    Write-Host "(3) freeze trên '$src'..."
    $r = Invoke-MoveWaitStep $src 'freeze' $id @() $t0 $cap
    if ($r.Code -ne 0) { return @{ Code = (ConvertTo-MoveExit $r.Code); Why = $(if ($r.Cap) { "quá hạn chờ $cap giây (freeze)" } else { 'freeze lỗi' }) } }
    Write-Host "(4) stop --guards trên '$src' (chờ mọi ứng dụng rảnh cùng lúc)..."
    $r = Invoke-MoveWaitStep $src 'stop' $id @('--guards') $t0 $cap
    if ($r.Code -ne 0) { return @{ Code = (ConvertTo-MoveExit $r.Code); Why = $(if ($r.Cap) { "quá hạn chờ $cap giây (guard)" } else { 'stop --guards lỗi' }) } }
    Write-Host "(5) stop và prepare trên '$dst'..."
    $r = Invoke-MoveGate $dst 'stop' $id
    if ($r.Code -ne 0) { return @{ Code = (ConvertTo-MoveExit $r.Code); Why = "stop trên '$dst' lỗi" } }
    Set-MoveProp $S 'dst_started' $false; Save-MoveState $S
    $r = Invoke-MoveGate $dst 'prepare' $id
    if ($r.Code -ne 0) { return @{ Code = (ConvertTo-MoveExit $r.Code); Why = "prepare trên '$dst' lỗi" } }
    $h = Test-MoveHoldIdle $dst; if ($h -ne 0) { return @{ Code = $h; Why = "'$dst' không rảnh" } }
    Write-Host "(6) dump trên '$src'..."
    $r = Invoke-MoveGate $src 'dump' $id
    if ($r.Code -ne 0) { return @{ Code = (ConvertTo-MoveExit $r.Code); Why = 'dump lỗi' } }
    Write-Host '(7) chép nốt (transfer --final)...'
    $x = Invoke-MoveTransfer $newH $id $true
    if ($x -ne 0) { return @{ Code = $x; Why = 'transfer --final lỗi' } }
    Write-Host "(8) adopt, restore --final trên '$dst'; verify --strict..."
    $r = Invoke-MoveGate $dst 'adopt' $id; if ($r.Code -ne 0) { return @{ Code = (ConvertTo-MoveExit $r.Code); Why = 'adopt lỗi' } }
    $r = Invoke-MoveGate $dst 'restore' $id @('--final'); if ($r.Code -ne 0) { return @{ Code = (ConvertTo-MoveExit $r.Code); Why = 'restore --final lỗi' } }   # A32: a failed sqlite integrity_check is restore-failed here
    $r = Invoke-MoveGate $newH 'verify' $id @('--strict')
    if ($r.Code -ne 0) { return @{ Code = (ConvertTo-MoveExit $r.Code); Why = 'verify --strict lỗi' } }
  }
  if (-not $Resume) {
    Write-Host "(9) start và health trên '$dst'..."
    Set-MoveProp $S 'dst_started' $true; Save-MoveState $S
    $r = Invoke-MoveGate $dst 'start' $id
    if ($r.Code -ne 0) { return @{ Code = (ConvertTo-MoveExit $r.Code); Why = "start trên '$dst' lỗi" } }
    $r = Invoke-MoveGate $dst 'health' $id
    if ($r.Code -ne 0) { return @{ Code = (ConvertTo-MoveExit $r.Code); Why = "health trên '$dst' lỗi" } }
  }
  Write-Host "(10) switch trên '$dst'..."
  Set-MoveProp $S 'mark' 'switching'; Save-MoveState $S
  $r = Invoke-MoveGate $dst 'switch' $id
  if ($r.Code -ne 0) { return @{ Code = (ConvertTo-MoveExit $r.Code); Why = 'switch lỗi' } }
  Write-Host "(11) unfreeze trên '$dst'..."
  $r = Invoke-MoveGate $dst 'unfreeze' $id
  if ($r.Code -ne 0) { return @{ Code = (ConvertTo-MoveExit $r.Code); Why = 'unfreeze lỗi'; NoRollback = $true } }
  Set-MoveProp $S 'mark' $null; Set-MoveProp $S 'cut_at' (Format-MoveTs (Get-MoveNow)); Set-MoveProp $S 'phase' 'cut'
  Set-MoveProp $S.answers 'finish' $null; Set-MoveProp $S.answers 'finish_early' $null   # a new cut needs a new finish answer
  Save-MoveState $S
  @{ Code = 0 }
}
# the rollback: dst stop, src start --connectors, src unfreeze, workflows (src is old), phase rolled-back, src health. Each step is tried 3 times;
# when dst cannot be reached and has started nothing, dst-unreachable is only a warning. Returns the exit code of the cutover that failed (70 = needs a human).
function Invoke-MoveRollback($S, [int]$Cause, [string]$Why) {
  $id = [string]$S.move_id
  Write-Host "Quay lại: $Why"
  Set-MoveProp $S 'mark' 'rolling-back'; Set-MoveProp $S.answers 'cut' $null; Set-MoveProp $S.answers 'back' $null; Save-MoveState $S
  $dst = Get-MoveDstHost $S; $src = Get-MoveSrcHost $S
  if (Invoke-MoveTry3 { Invoke-MoveGate $dst 'stop' $id }) { Set-MoveProp $S 'dst_started' $false; Save-MoveState $S }
  elseif ([bool]$S.dst_started) { Write-Host "CẦN NGƯỜI (70): không dừng được máy đích '$dst' mà nó có thể đang chạy ứng dụng. Giữ nguyên mark rolling-back; khi máy đích nối lại được, chạy lại fcode move cutover."; return 70 }
  else { Write-Host 'INV warn dst-unreachable' }
  if (-not (Invoke-MoveTry3 { Invoke-MoveGate $src 'start' $id @('--connectors') })) { Write-Host "CẦN NGƯỜI (70): máy cũ '$src' không start lại được. Giữ nguyên mark rolling-back."; return 70 }
  if (-not (Invoke-MoveTry3 { Invoke-MoveGate $src 'unfreeze' $id })) { Write-Host "CẦN NGƯỜI (70): máy cũ '$src' không unfreeze được. Giữ nguyên mark rolling-back."; return 70 }
  if ([string]$S.dir -ceq 'fwd' -and -not (Invoke-MoveTry3 { @{ Code = (Set-MoveWorkflows $S $true) } })) { Write-Host 'CẦN NGƯỜI (70): không bật lại được workflow deploy. Giữ nguyên mark rolling-back.'; return 70 }
  Set-MoveProp $S 'mark' $null; Set-MoveProp $S 'phase' 'rolled-back'; Save-MoveState $S
  $h = Invoke-MoveGate $src 'health' $id
  if ($h.Code -ne 0) { Write-Host "CẦN NGƯỜI (70): máy cũ '$src' đã được start lại nhưng health lỗi (phase rolled-back)."; return 70 }
  Write-Host "rolled_back: các ứng dụng đã chạy lại ở máy '$src' như cũ."
  if ($Cause -eq 0) { 1 } else { $Cause }
}
# step (12): chores, each idempotent by content. From here nothing is rolled back; a failure is fixed by running `cutover` again.
function Invoke-MoveChores($S) {
  Write-Host '(12) việc sau khi chuyển: secret GitHub, ssh alias...'
  $fwd = ([string]$S.dir -ceq 'fwd')
  $dside = if ($fwd) { $S.new } else { $S.old }
  $kf = @("$($dside.hostkey_line)" -split '\s+')
  $line = if ($kf.Count -ge 3 -and $dside.addr) { "$($dside.addr) $($kf[1]) $($kf[2])" } else { '' }   # CONTRACT: `<dst addr> <keytype> <key>` (hostkey_line is [addr]:port when the port is not 22)
  $gp = @(@(@($S.repos) | Where-Object { $_.kind -ceq 'gate-push' } | ForEach-Object { [string]$_.repo }) | Select-Object -Unique)
  if ($gp.Count) {
    if (-not $line) { Write-Host 'lỗi: thiếu khoá máy đích trong state; chạy lại fcode move plan.'; return 1 }
    foreach ($repo in $gp) {
      $o = Invoke-MoveTool 'gh' @('secret', 'set', 'DEPLOY_KNOWN_HOSTS', '-R', $repo) $line
      if ($o.Code -ne 0) { Write-IpaError "gh không đặt được DEPLOY_KNOWN_HOSTS của $repo (mã $($o.Code))." ($o.Out -join "`n"); Write-Host 'Chạy lại:  fcode move cutover'; return 1 }
      Write-Host "DEPLOY_KNOWN_HOSTS của $repo đã trỏ vào máy mới nhất."
    }
  }
  if ((Set-MoveLaptopAlias $S) -ne 0) { Write-Host 'Chạy lại:  fcode move cutover'; return 1 }
  if ((Set-MoveCoderAlias $S) -ne 0) { Write-Host 'Chạy lại:  fcode move cutover'; return 1 }
  Write-Host 'MOVE done cutover'
  $sp = @(@(@($S.repos) | Where-Object { $_.kind -ceq 'ssh-push' -and $_.enabled -eq $true } | ForEach-Object { "$($_.repo) ($($_.workflow))" }) | Select-Object -Unique)
  if ($sp.Count) { Write-Host "Workflow deploy thẳng qua SSH vẫn đang TẮT: $($sp -join ', '). Trỏ repo vào máy mới rồi bật lại tay$(if (-not $fwd) { ' (lệnh finish bật lại chúng)' })." }
  Write-Host $(if ($fwd) { 'Đã chuyển xong. Giữ máy cũ ít nhất 72 giờ; khi chắc chắn:  fcode move finish   (cần quay lại:  fcode move back)' } else { 'Đã quay lại xong. Khi chắc chắn:  fcode move finish   (chuyển lại sang máy mới:  fcode move back)' })
  0
}
function Invoke-MoveCutover($S) {
  $mark = [string]$S.mark
  if ($mark -ceq 'rolling-back') { return (Invoke-MoveRollback $S 1 'làm nốt lần quay lại đang dở') }
  if ([string]$S.phase -ceq 'cut') { return (Invoke-MoveChores $S) }
  if ($mark -ceq 'switching') { $f = Invoke-MoveCutSteps $S $true }   # resume at step (10)
  elseif ($mark -ceq 'cutting') { $f = Invoke-MoveCutSteps $S $false ([bool]($S.dst_started -eq $true)) }   # step (1) never runs again; A31: dst_started true = continue at step (9)
  else {
    $nb = ConvertTo-MoveTime $S.cut_not_before; $now = Get-MoveNow
    if ($nb -and $now -lt $nb) {
      Write-Host "Chưa chuyển được: bản ghi DNS cũ còn trong thời gian TTL, cần chờ thêm khoảng $([int][Math]::Ceiling(($nb - $now).TotalMinutes)) phút (đến $(Format-MoveTs $nb)). Chưa chạy gì."
      return 65
    }
    $key = if ([string]$S.via -ceq 'back') { 'back' } else { 'cut' }
    if (-not $S.answers.$key) {
      if (-not (Confirm-MoveYes (Get-MoveQuestion $key $S))) { Write-Host 'Đã huỷ, chưa đổi gì.'; return 65 }
      Set-MoveProp $S.answers $key (New-MoveAnswer)
    }
    Set-MoveProp $S 'mark' 'cutting'; Save-MoveState $S   # ONE write: the answer and the mark that says a cutover is in flight
    $f = Invoke-MoveCutSteps $S $false $false
  }
  if ($f.Code -eq 0) { return (Invoke-MoveChores $S) }
  if ($f.NoRollback) { Write-Host "lỗi ở bước cuối ($($f.Why)); chạy lại  fcode move cutover  để làm tiếp (mark switching giữ nguyên)."; return $f.Code }
  Invoke-MoveRollback $S ([int]$f.Code) ([string]$f.Why)
}

# ---- finish (sequence 5) and back (sequence 4) ----
function Invoke-MoveFinish($S, [string]$Do) {
  if ($Do -ceq 'done') { Write-Host 'Lần chuyển này đã xong (finished).'; return 0 }
  $abandon = ($Do -ceq 'abandon' -or $Do -ceq 'abandon-rollback')
  $ca = ConvertTo-MoveTime $S.cut_at
  $needEarly = [bool]($ca -and (Get-MoveNow) -lt $ca.AddHours(72) -and -not $S.answers.finish_early)
  $needMain = [bool](-not $S.answers.finish)
  if ($Do -ceq 'abandon-rollback') {   # said BEFORE the question(s): the rollback follows a YES
    $srcA = if ([string]$S.dir -ceq 'fwd') { [string]$S.old.alias } else { [string]$S.new.alias }; $dstA = if ([string]$S.dir -ceq 'fwd') { [string]$S.new.alias } else { [string]$S.old.alias }
    Write-Host "Một cutover đang dở (mark '$($S.mark)'). Nếu đồng ý huỷ, ứng dụng sẽ được cho chạy lại ở máy '$srcA' trước (rollback), rồi mới huỷ lần chuyển."
    if ($S.dst_started -eq $true) { Write-Host "Dữ liệu các ứng dụng đã ghi ở máy '$dstA' từ lúc cutover bị ngắt sẽ không được chép về." }
  }
  if ($needMain -and -not (Confirm-MoveYes (Get-MoveQuestion $(if ($abandon) { 'abandon' } else { 'finish' }) $S))) { Write-Host 'Đã huỷ, chưa đổi gì.'; return 65 }
  if ($needEarly -and -not (Confirm-MoveYes (Get-MoveQuestion 'finish-early' $S))) { Write-Host 'Đã huỷ, chưa đổi gì.'; return 65 }
  if ($needMain) { Set-MoveProp $S.answers 'finish' (New-MoveAnswer) }
  if ($needEarly) { Set-MoveProp $S.answers 'finish_early' (New-MoveAnswer) }
  if ($needMain -or $needEarly) { Save-MoveState $S }
  if ($Do -ceq 'abandon-rollback') {   # mark cutting / rolling-back: put the apps back on src (idempotent), then abandon
    $rb = @(Invoke-MoveRollback $S 1 'huỷ lần chuyển khi một cutover đang dở')
    if ([int]$rb[-1] -ne 1) { return [int]$rb[-1] }   # 70 = needs a human: mark rolling-back kept, nothing is finished
  }
  $id = [string]$S.move_id; $fwd = ([string]$S.dir -ceq 'fwd')
  $order = if ($abandon) { @('old', 'new') } elseif ($fwd) { @('old', 'new') } else { @('new', 'old') }   # phase cut: src first, then dst
  foreach ($m in $order) {
    $h = if ($m -ceq 'old') { Get-MoveOldHost $S } else { Get-MoveNewHost $S }
    $peer = if ($m -ceq 'old') { [string]$S.new.alias } else { [string]$S.old.alias }
    Write-Host "finish trên '$h'..."
    $r = Invoke-MoveGate $h 'finish' $id @($peer)
    $lines = @($r.Lines | ForEach-Object { "$_" })
    $done = ($r.Code -eq 0) -or ($abandon -and (($r.Code -eq 65 -and @($lines | Where-Object { $_ -cmatch '\AMOVE error (no-move|move-id-mismatch)\b' }).Count) -or $r.Code -eq 127))   # abandon: `copy`/`init` of this run never reached that machine (nothing, or the move-id of an earlier move)
    if (-not $done) { return (ConvertTo-MoveExit $r.Code) }
  }
  $reenable = if ($abandon) { $fwd } else { -not $fwd }   # workflows come back when the apps run on old
  if ($reenable -and (Set-MoveWorkflows $S $true) -ne 0) { Write-Host 'lỗi: không bật lại được workflow; chạy lại fcode move finish.'; return 1 }
  Set-MoveProp $S 'phase' 'finished'; Set-MoveProp $S 'mark' $null; Save-MoveState $S
  Write-Host $(if ($abandon) { 'Đã huỷ lần chuyển (finished). Máy mới vẫn giữ bản sao dữ liệu và mật khẩu (đã tắt): nếu không dùng nữa, hãy xoá hoặc cài lại máy đó.' } else { 'Đã bỏ máy cũ (finished): ứng dụng trên máy đó đã tắt, khoá chuyển máy đã xoá. Huỷ gói VPS cũ ở trang Contabo là việc của bạn.' })
  0
}
# phase cut: Q-back, then a new run with src and dst swapped (plan on its src with the saved move-map and manifest), then its copy and cutover
function Invoke-MoveBackStart($S) {
  $N = New-MoveState ([guid]::NewGuid().ToString()) $(if ([string]$S.dir -ceq 'fwd') { 'back' } else { 'fwd' }) 'back' $S.old $S.new
  Set-MoveProp $N 'est_downtime_s' $S.est_downtime_s; Set-MoveProp $N 'cap_s' $S.cap_s; Set-MoveProp $N 'cut_at' $S.cut_at
  Set-MoveProp $N 'repos' @($S.repos); Set-MoveProp $N 'backups' $S.backups
  if (-not (Confirm-MoveYes (Get-MoveQuestion 'back' $N))) { Write-Host 'Đã huỷ, chưa đổi gì.'; return 65 }
  Set-MoveProp $N.answers 'back' (New-MoveAnswer)
  $from = Read-MoveManifestFile
  if (-not $from) { Write-Host 'lỗi: chưa có manifest đã lưu của lần chuyển trước (manifest.json).'; return 1 }
  $mp = Get-MovePath 'move-map.json'
  $mapText = if ([IO.File]::Exists($mp)) { [IO.File]::ReadAllText($mp) } else { $null }
  $r = Invoke-MovePlanSteps $N $mapText $from.Text $true
  if ($r.Code -ne 0) { return $r.Code }
  Set-MoveProp $N 'manifest_sha' $r.Sha; Set-MoveProp $N 'est_downtime_s' ([int]$r.Obj.est_downtime_s); Set-MoveProp $N 'cap_s' (Get-MoveCap $r.Obj)
  Save-MoveManifest $r.Text; Save-MoveState $N
  Write-Host 'INV ok'
  $c = Invoke-MoveCopy $N; if ($c -ne 0) { return $c }
  Invoke-MoveCutover $N
}

# ---- status and the entry ----
function Show-MoveStatus {
  try { $S = Read-MoveState } catch { Write-Host "lỗi: $($_.Exception.Message)"; return 1 }
  if (-not $S) { Write-Host 'Chưa có lần chuyển nào. Bắt đầu bằng:  fcode move plan <máy mới>'; return 0 }
  $nz = { param($v) if ($v) { [string]$v } else { '-' } }
  Write-Host "move_id=$($S.move_id) hướng=$($S.dir) bắt đầu bằng=$($S.via) giai đoạn=$($S.phase) mark=$(& $nz $S.mark) dst_started=$($S.dst_started)"
  Write-Host "  cut_at=$(& $nz $S.cut_at) cut_not_before=$(& $nz $S.cut_not_before) máy cũ=$($S.old.alias) máy mới=$($S.new.alias) (kiểu $($S.new.kind))"
  foreach ($m in @(@{ N = 'máy cũ'; H = (Get-MoveOldHost $S) }, @{ N = 'máy mới'; H = (Get-MoveNewHost $S) })) {
    Write-Host "$($m.N) ($($m.H)):"
    $r = Invoke-MoveGate $m.H 'status' ''
    if ($r.Code -ne 0) { Write-Host "  không đọc được trạng thái (mã $($r.Code))." }
  }
  0
}
function Invoke-MoveDispatch($Act, $S, [string]$Alias, [string]$MapFile) {
  switch -CaseSensitive ($Act.Do) {
    'refuse' { Write-Host "lỗi: $($Act.Msg)"; 65 }
    'plan-new' { Invoke-MovePlan $null $Alias $MapFile $true }
    'replan' { Invoke-MovePlan $S $Alias $MapFile $false }
    'copy' { Invoke-MoveCopy $S }
    { $_ -in 'cutover', 'cutover-continue', 'chores' } { Invoke-MoveCutover $S }
    { $_ -in 'finish', 'abandon', 'abandon-rollback', 'done' } { Invoke-MoveFinish $S $Act.Do }
    'back-start' { Invoke-MoveBackStart $S }
    'back-copy-cutover' { $c = Invoke-MoveCopy $S; if ([int]@($c)[-1] -ne 0) { [int]@($c)[-1] } else { Invoke-MoveCutover $S } }
    default { Write-Host "lỗi: việc '$($Act.Do)' không biết."; 1 }
  }
}
# fcode move plan <máy mới> [--map <file>] | copy | cutover | finish | back | status. Returns the exit code (0 / 1 / 65 / 69 / 70 / 75).
function Invoke-Move {
  $a = @($Rest | Select-Object -Skip 1)
  $verb = if ($a.Count -gt 0) { [string]$a[0] } else { '' }
  $usage = {
    Write-Host 'Cách dùng: fcode move plan <máy mới> [--map <file>] | copy | cutover | finish | back | status'
    Write-Host '  Chi tiết: fcode help move'
  }
  if ($verb -cnotin 'plan', 'copy', 'cutover', 'finish', 'back', 'status') { & $usage; return 65 }
  $alias = ''; $mapFile = ''
  if ($verb -ceq 'plan') {
    $i = 1
    while ($i -lt $a.Count) {
      if ($a[$i] -ceq '--map') { if ($i + 1 -ge $a.Count -or $mapFile) { & $usage; return 65 }; $mapFile = [string]$a[$i + 1]; $i += 2 }
      elseif (-not $alias -and ([string]$a[$i]) -notmatch '\A-') { $alias = [string]$a[$i]; $i++ }
      else { & $usage; return 65 }
    }
  } elseif ($a.Count -gt 1) { & $usage; return 65 }
  if ($verb -ceq 'status') { return [int]@(Show-MoveStatus)[-1] }
  $lock = Open-MoveLock
  if (-not $lock) { Write-Host 'lỗi: đang có một lần fcode move khác chạy (move.lock); chờ nó xong rồi chạy lại.'; return 1 }
  try {
    $S = Read-MoveState
    $act = Resolve-MoveAction $verb $S
    $res = @(Invoke-MoveDispatch $act $S $alias $mapFile)
    return [int]$res[-1]
  } catch {
    Write-Host "lỗi: $($_.Exception.Message)"
    return 1
  } finally { $lock.Dispose() }
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

attach() {
  echo "Thoát mà không tắt phiên: bấm Ctrl+B rồi D"
  sleep 2
  case "${TERM:-}" in ""|dumb) export TERM=xterm-256color ;; esac
  exec tmux -u attach -t "=$1"
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

# fcode add chay script DA CAI tren box (box/fcode-add.sh, install.sh dat o /data/home/fcoding/fcode-add.sh): mot nguon duy nhat cho ca app va laptop.
# Dong ket qua dang "R <MA> [chi tiet]" do Invoke-Add dich ra tieng Viet. Thieu script -> "R NO_SCRIPT" (box chua cap nhat).
# Cung han voi server (server.mjs): toi da 600 giay, roi TERM, 30 giay sau KILL (124 / 137), de khoa theo ten tren box khong bi giu mai.
$FcodeAddRun = (@'
s="${FCODE_ADD_SCRIPT:-/data/home/fcoding/fcode-add.sh}"
[ -f "$s" ] || { echo "R NO_SCRIPT"; exit 3; }
exec env -u INSTABOX_API_KEY timeout --kill-after="${FCODE_ADD_KILL_AFTER_S:-30}" "${FCODE_ADD_TIMEOUT_S:-600}" bash "$s" "$@"
'@) -replace "`r`n", "`n"

# fcode-pair tren box (server worker them --qr). $1 = ten thiet bi (co the rong).
$FcodePairSh = (@'
name="${1:-}"
if [ -n "$name" ]; then exec fcode-pair "$name" --qr; else exec fcode-pair --qr; fi
'@) -replace "`r`n", "`n"

# fcode phien tren box: chuong trinh python (instabox ssh chay no, yeu cau di qua stdin)
$PhienPy = (@'
#!/usr/bin/env python3
# fcode phien (chay tren box): doc / gui / nhan phien chat omp. Chi laptop goi lenh nay (qua instabox ssh).
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
# Ben tren box la mot chuong trinh python nho ($PhienPy, chay qua instabox ssh); yeu cau di qua stdin, khong qua dong lenh.
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
# 'running' | 'stopped' | 'unknown' (instabox ls loi, JSON hong, khong thay box hoac khong co trang thai): unknown khong doi gi ca
function Test-BoxRunning {
  try {
    $r = Invoke-PhienExe (Get-InstaboxExe) @('ls', '--json')
    if ($r.Code -eq 124) { return 'timeout' }   # only while a phien deadline is set (--nhanh): `instabox ls` ran into it
    if ($r.Code -ne 0) { return 'unknown' }
    $list = ($r.Out -join "`n") | ConvertFrom-Json
    $b = $null; foreach ($x in $list) { foreach ($y in @($x)) { if ($y -and $y.name -eq $box) { $b = $y } } }
    if (-not $b -or -not "$($b.state)") { return 'unknown' }
    if ("$($b.state)" -eq 'running') { 'running' } else { 'stopped' }
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
# dung tien trinh va moi tien trinh con cua no (instabox -> ssh); Windows PowerShell 5.1 khong co Kill($true) nen dung taskkill
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
      if ($StdinText) { $sb = [Text.Encoding]::UTF8.GetBytes($StdinText); $p.StandardInput.BaseStream.Write($sb, 0, $sb.Length); $p.StandardInput.BaseStream.Flush() }   # raw UTF-8 bytes (no BOM; 5.1 has no StandardInputEncoding)
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
  if ($box -notmatch '\A[A-Za-z0-9._-]+\z') { throw "tên box '$box' không hợp lệ" }
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
  $psi.FileName = Get-InstaboxExe
  $psi.Arguments = 'ssh ' + $box + ' -- "' + $remote + '"'
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
# $Quick (--nhanh, cho hook cua `fcode moc`): mot project, KHONG danh thuc box, khong cho khoa, toi da 20 s; thoat 0 khi box ngu / khoa ban / het gio.
# Che do nhanh chi ghi phien.log; man hinh nhan toi da MOT dong (Invoke-Phien in $script:PhienScreen, hoac dong loi khi that bai); thanh cong thi im lang.
# Han chot (--nhanh, tu dong) chi duoc xem o diem an toan, truoc moi muc (quet, hash, mot dot, mot ghi chu); mot muc da bat dau thi xong tron hoac hong tron.
function Invoke-PhienSync([string]$Only, [bool]$Auto, [bool]$DryRun = $false, [bool]$BoxKnownRunning = $false, [bool]$Quick = $false) {
  $script:PhienQuiet = $Auto; $script:PhienQuick = $Quick; $script:PhienScreen = $null; $script:PhienRepoIds = @{}
  $capMsg = $PhienCapMsg
  $code = 0; $capHit = $false
  # lan tu dong: MOT han chot cho ca lan chay, tinh tu luc tien trinh bat dau (nhu gioi han 8 phut cua Task Scheduler)
  $script:PhienDeadline = if ($Auto) { [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().AddSeconds((Get-PhienLimitSec $true)) } elseif ($Quick) { [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().AddSeconds((Get-PhienCapSec)) } else { $null }
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
    if (-not $DryRun) { Clear-PhienLeftovers @() }   # the lock is held: a killed run's staging goes now, even when this run stops early (box asleep)
    $projs = Get-PhienProjects
    if ($projs.Count -eq 0) { Write-PhienOut "Chưa có project nào trong syncRepos ($ConfigFile)."; return 0 }
    $names = @($projs.Keys)
    if ($Only) {
      $o = $Only.ToLowerInvariant()
      if (-not $projs.Contains($o)) { Write-PhienOut "Không thấy project '$Only' trong syncRepos. Có: $(@($names | ForEach-Object { Format-ProjectName $_ $projs[$_] }) -join ', ')"; return 1 }
      $names = @($o)
    }
    if ($Quick) {   # only `instabox ls`: never wakes the box
      $bs = Test-BoxRunning
      if ($bs -eq 'timeout') { Set-PhienScreen $capMsg; return 0 }
      if ($bs -eq 'unknown') { $stat.ok = $false; Write-PhienOut 'lỗi: không đọc được trạng thái box (instabox ls lỗi — đã chạy "instabox login" chưa?)'; return 1 }
      if ($bs -ne 'running') { Set-PhienScreen 'phien: box đang ngủ, bỏ qua'; return 0 }
    }
    elseif ($Auto) { if (-not $BoxKnownRunning -and (Test-BoxRunning) -ne 'running') { return 0 } }
    else { & (Get-InstaboxExe) wake $box *> $null }
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
      Write-PhienOut 'lỗi: không nói chuyện được với box. Kiểm tra: đã chạy "instabox login" chưa, và box đang bật không.'
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

# che do tu dong (luat v2): chi doc `instabox ls --json`, ssh moi ngan khong tinh la hoat dong lam box khong tu nghi duoc.
#  - box khong chay: khong ssh
#  - box vua tu khong chay thanh dang chay: dong bo mot lan ngay
#  - con lai: chi dong bo khi lan mo ssh gan nhat da cach >= 40 phut (lon hon 30 phut box tu nghi khi ranh, nen box khong dung
#    den thi luon duoc nghi). Lan loi cung chi cho den moc 40 phut sau, khong thu lai nhanh.
$PhienAutoGapSec = 2400
function Invoke-PhienAutoRun {
  $as = Read-PhienAutoState
  $last = if ($as) { [double]$as.lastSshAt } else { 0 }
  $bs = Test-BoxRunning
  # instabox ls loi / tra ve thu khong doc duoc: khong biet box ra sao -> khong ssh va KHONG doi trang thai (khong tu tao ra "box vua chay")
  if ($bs -eq 'unknown') { Add-PhienLog @('không đọc được trạng thái box (instabox ls lỗi): bỏ qua lần này, giữ nguyên trạng thái'); return 0 }
  if ($bs -ne 'running') {
    if ($as -and $as.boxRunning) { Add-PhienLog @('box không chạy nữa, tạm nghỉ') }
    Write-PhienAutoState @{ boxRunning = $false; lastSshAt = $last }
    return 0
  }
  $age = (ConvertTo-Epoch (Get-Date)) - $last
  $mins = [int][Math]::Floor($age / 60)
  if (-not $as -or -not $as.boxRunning) { $why = 'box vừa chạy (lần đầu trong đợt chạy này)' }
  elseif ($age -ge $PhienAutoGapSec) { $why = "lần mở ssh trước đã cách $mins phút (từ 40 phút trở lên, box ranh thì đã tự nghỉ)" }
  else {
    Add-PhienLog @("box đang chạy, lần mở ssh trước mới cách $mins phút (dưới 40): bỏ qua để box tự nghỉ được")
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
      Write-Host 'Đã bật tự động: cứ 10 phút, nếu box đang chạy, fcode tự đồng bộ phiên chat omp hai chiều (chạy ngầm, không hiện cửa sổ). Mở kết nối thưa (box vừa bật, hoặc cách lần trước từ 40 phút), để box vẫn tự nghỉ được.'
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
# and all its children (git, tar, instabox, ssh). So there is no kill call here.
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
  # --nhanh (the hook): the screen gets at most one line, the asleep / busy / cap message, or one short line when the sync failed; success prints nothing
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
    Write-Host 'Xong. Mở cửa sổ PowerShell mới. Từ giờ, gõ omp / claude / codex trong thư mục một project (có trong syncRepos), fcode đồng bộ nhanh phiên trước và sau (tối đa khoảng 20 giây; box đang ngủ thì bỏ qua).'
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
if ($arg -eq 'pair') { exit (Invoke-Pair) }
if ($arg -eq 'move') { exit (Invoke-Move) }
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
$ib = Get-InstaboxExe
while ($true) {
  # tham so $1 di cung script (set -- '..'), khong nam tren dong lenh ssh
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-BareScript $arg)))
  $remote = "bash <(echo $b64 | base64 -d)"
  # box tu tam dung (ranh 30 phut / chay 8 tieng) thi danh thuc truoc; loi wake de ssh tu bao
  & $ib wake $box *> $null
  if ($arg -eq '--list') { & $ib ssh $box -- $remote } else { & $ib ssh $box -- -q -tt $remote }
  $rc = $LASTEXITCODE
  if ($rc -eq 78 -and $bareWord -and -not $asked) {   # box bao khong co phien nao ten nay (ma 78; ssh dut, 255, thi khong): co the la ten goi moi dat trong app. Hoi box mot lan; doi duoc ra ten that thi chay lai
    $asked = $true
    $new = Resolve-ProjectArg $arg @(Get-PrefsNames) $true
    if ($new -cne $arg -and $new -match '\A[A-Za-z0-9._-]+\z') { $arg = $new; continue }
  }
  break
}
if ($rc -eq 78) { $rc = 1 }   # 78 chi la tin hieu giua script tren box va laptop; nguoi dung van thay ma 1
if ($rc -eq 77 -and -not $arg) { exit (Invoke-PhienMenu) }
# tham so khong khop phien nao (hoac loi) thi nhac lenh help
if ($rc -ne 0 -and $arg -and $arg -ne '--list' -and $arg -ne '--new') { Write-Host "Nếu '$arg' không phải tên phiên, gõ fcode help để xem các lệnh." }
exit $rc
