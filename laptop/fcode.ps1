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

# project cua box (ten + URL origin) chua co trong syncRepos -> tim / hoi / tai, them vao syncRepos
function Add-SyncMissing {
  if ($env:FCODE_SYNC_REPOS) { return }   # danh sach dat tam cho lan chay nay: khong tim, khong ghi config
  Write-Host 'Đang hỏi box danh sách project...'
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  # han 60 giay cho lenh nay (khong phai 900 giay cua mot dot chep phien), tinh tu luc box da thuc
  try { & (Get-InstaboxExe) wake $box *> $null; $script:PhienDeadline = [DateTime]::UtcNow.AddSeconds([Math]::Min(60, (Get-PhienLimitSec $false))); $bp = Get-BoxJson (Invoke-BoxPy 'projects' ([byte[]]@())) } catch { $bp = $null } finally { $ErrorActionPreference = $old; $script:PhienDeadline = $null }
  if (-not $bp) { Write-Host 'cảnh báo: không đọc được danh sách project trên box; chỉ cập nhật các project đã có trên laptop.'; return }
  $have = @{}; foreach ($r in $SyncRepos) { $k = Get-LocalRepoKey $r; if ($k) { $have[$k] = $true } }
  $miss = @(@($bp.projects) | Where-Object { $_ -and $_.repo -and -not $have.ContainsKey([string]$_.repo) })
  if (-not $miss.Count) { return }
  Write-Host "Box có $($miss.Count) project chưa có trên laptop:"
  foreach ($m in $miss) { Write-Host "  $($m.name)  $($m.origin)" }
  $want = @{}; foreach ($m in $miss) { $want[[string]$m.repo] = $true }
  $f = Find-LocalClones $want
  Write-Host ('Đã tìm bản có sẵn trong: ' + ($f.Where -join '; '))
  $base = if ($env:FCODE_GITHUB_BASE) { $env:FCODE_GITHUB_BASE.TrimEnd('/', '\') } else { 'https://github.com' }
  foreach ($m in $miss) {
    Write-Host ''
    Write-Host "== $($m.name) ($($m.repo))"
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

function Show-Help {
  Write-Host 'fcode - điều khiển box coding từ máy này. Các lệnh:'
  Write-Host ''
  Write-Host '  fcode'
  Write-Host '      Xem danh sách phiên đang chạy trên box, gõ số để vào (gõ 0 để mở phiên mới).'
  Write-Host '      Ví dụ: fcode'
  Write-Host '  fcode <số hoặc tên phiên>'
  Write-Host '      Vào thẳng một phiên (tên có thể gõ phần đầu). Thoát mà không tắt phiên: Ctrl+B rồi D.'
  Write-Host '      Ví dụ: fcode 2    hoặc    fcode ten-phien'
  Write-Host '  fcode --list'
  Write-Host '      Chỉ in danh sách phiên, không vào (viết tắt: fcode -l).'
  Write-Host '      Ví dụ: fcode -l'
  Write-Host '  fcode new'
  Write-Host '      Mở một phiên MỚI trên box (như nút "+" trong app): chọn project, chọn omp / claude / codex, rồi vào luôn phiên đó.'
  Write-Host '      Gõ fcode rồi chọn 0 cũng được. Bấm Enter ở bất kỳ câu hỏi nào để quay lại.'
  Write-Host '      Ví dụ: fcode new'
  Write-Host '  fcode sync'
  Write-Host '      Cập nhật các project trên máy này từ GitHub, báo nhánh box chờ merge và PR đang mở.'
  Write-Host '      Ví dụ: fcode sync'
  Write-Host '  fcode ipa'
  Write-Host '      Tải bản FCode mới nhất về thư mục Downloads để kéo vào Sideloadly.'
  Write-Host '      Ví dụ: fcode ipa'
  Write-Host '  fcode add <chủ/repo> [tên]'
  Write-Host '      Thêm một project GitHub vào box để omp làm việc và app FCode hiện trong danh sách.'
  Write-Host '      Nếu token GitHub của box ghi được repo thì xong ngay; nếu không, lệnh hướng dẫn bạn dán một khoá vào trang GitHub của repo (một lần cho mỗi repo).'
  Write-Host '      Ví dụ: fcode add ten-tai-khoan/ten-repo    hoặc    fcode add ten-tai-khoan/ten-repo ten-ngan'
  Write-Host '  fcode pair [tên thiết bị]'
  Write-Host '      Tạo mã ghép (kèm mã QR) để ghép một iPhone mới với server FCode. Mã dùng 1 lần và hết hạn nhanh.'
  Write-Host '      Ví dụ: fcode pair    hoặc    fcode pair iPhone của Mẹ'
  Write-Host '  fcode phien [project]'
  Write-Host '      Đồng bộ phiên chat omp hai chiều giữa laptop và box (mọi project, hoặc chỉ một project): phiên nào chỉ có ở một bên thì chép sang bên kia, phiên đã đi tiếp ở một bên thì cập nhật bên còn lại. Không xoá gì. Sau đó omp trên mỗi máy tự thấy phiên đó trong /resume, omp -c và omp -r.'
  Write-Host '      Cùng lượt này đồng bộ cả ghi chú ở thư mục gốc project (HANDOFF*.md, CLAUDE.md, AGENTS.md, WORKFLOW.md, agent_state.md, TASK.md, CLAUDE.local.md) khi git không theo dõi chúng; file nào hai máy cùng sửa thì giữ nguyên và báo.'
  Write-Host '      Ví dụ: fcode phien    hoặc    fcode phien deal-sync'
  Write-Host '  fcode phien --thu [project]'
  Write-Host '      Chạy thử: chỉ liệt kê những phiên sẽ được chép đi đâu, không chép gì (chỉ ghi lại giờ vừa kết nối box).'
  Write-Host '      Ví dụ: fcode phien --thu'
  Write-Host '  fcode phien tu-dong bat   |   fcode phien tu-dong tat'
  Write-Host '      Bật / tắt tự động đồng bộ phiên mỗi 10 phút, chạy ngầm (không hiện cửa sổ), chỉ khi box đang chạy, và chỉ mở kết nối khi box vừa bật hoặc cách lần mở trước từ 40 phút (để box tự nghỉ được).'
  Write-Host '      Ví dụ: fcode phien tu-dong bat'
  Write-Host '  fcode phien <project> --nhanh'
  Write-Host '      Bản nhanh cho hook (fcode moc): chỉ một project, không đánh thức box (box đang ngủ thì bỏ qua), tối đa 20 giây, đang có lượt đồng bộ khác thì bỏ qua.'
  Write-Host '      Ví dụ: fcode phien deal-sync --nhanh'
  Write-Host '  fcode moc bat   |   fcode moc tat   |   fcode moc trang-thai'
  Write-Host '      Bật / tắt / xem hook trong profile PowerShell: gõ omp, claude hoặc codex trong thư mục một project (có trong syncRepos) thì fcode đồng bộ nhanh phiên trước và sau khi chạy (tối đa khoảng 20 giây, box ngủ thì bỏ qua). Tắt hook trong cửa sổ này: gõ $env:FCODE_MOC = ''0'' (đến khi gõ Remove-Item Env:FCODE_MOC hoặc đóng cửa sổ). Phiên Claude Code / Codex chưa được chép giữa hai máy, chỉ phiên omp và ghi chú project.'
  Write-Host '      Hook là hàm bọc nên không chuyển đúng hoàn toàn các tham số kiểu -- và -x:giá-trị, cũng không để lại lỗi của chương trình trong $?; những lúc cần đúng tuyệt đối, chạy thẳng claude.exe / codex.exe / omp.exe.'
  Write-Host '      Ví dụ: fcode moc bat'
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
rows=(); names=()
while IFS= read -r l; do
  [ -n "$l" ] && rows+=("$l") && names+=("${l%%|*}")
done < <(tmux list-sessions -F '#{session_name}|#{session_attached}|#{@pc_project}|#{@pc_harness}' 2>/dev/null)
n=${#rows[@]}

show() { # in 1 dong cho phien thu $1 (chi so tu 0)
  local name att proj har out
  IFS='|' read -r name att proj har <<<"${rows[$1]}"
  out="$(printf '%3d) %s' $(($1 + 1)) "$name")"
  [ -n "$proj" ] && out+="  -  dự án: $proj"
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
  for i in "${!opts[@]}"; do printf '%3d) %s\n' $((i + 1)) "${opts[$i]}"; done
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
  pick "Chọn project:" "${projs[@]}" || return 1; proj="$picked"
  fnew --harnesses || return 2
  mapfile -t harns < <(grep -v '^$' <<<"$out")
  [ "${#harns[@]}" -gt 0 ] || { echo "Lỗi: box không trả về danh sách harness."; return 2; }
  pick "Chọn harness:" "${harns[@]}" || return 1; har="$picked"
  echo "Đang mở phiên mới ($proj, $har)..."
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
if [ -n "$arg" ]; then resolve "$arg" || exit 1; attach "$sel"; fi

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
import hashlib, io, json, ntpath, os, posixpath, re, shutil, subprocess, sys, tarfile, tempfile, time

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
    sys.stdout.write('FCODE-JSON ' + json.dumps(o, ensure_ascii=False) + '\n')
    sys.stdout.flush()


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


def git(d, *a):
    try:
        return subprocess.run(['git', '--no-optional-locks', '-C', d, '-c', 'core.quotepath=false'] + list(a),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
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


def upstream_names(d):
    # ghi chu nam trong nhanh mac dinh cua origin (ban da fetch): git se mang file do toi, nen cung tinh la da theo doi
    # nhanh mac dinh: origin/HEAD, khong co thi origin/main, roi origin/master
    r = git(d, 'symbolic-ref', '-q', 'refs/remotes/origin/HEAD')
    ref = r.stdout.decode('utf-8', 'replace').strip() if r is not None and r.returncode == 0 else ''
    for c in ('refs/remotes/origin/main', 'refs/remotes/origin/master'):
        if ref:
            break
        r = git(d, 'rev-parse', '-q', '--verify', c)
        if r is not None and r.returncode == 0:
            ref = c
    if not ref:
        return set()
    r = git(d, 'ls-tree', '-z', '--name-only', ref)
    if r is None or r.returncode != 0:
        return set()
    return set(x for x in r.stdout.decode('utf-8', 'replace').split('\0') if NOTE_RX.match(x))


def tracked_names(d):
    t = index_names(d)
    return None if t is None else t | upstream_names(d)


def scan_notes(d):
    t = index_names(d) if os.path.isdir(d) else None
    if t is None:
        return {'gitok': False, 'tracked': [], 'upstream': [], 'files': []}
    files = []
    for n in sorted(os.listdir(d)):
        p = os.path.join(d, n)
        if NOTE_RX.match(n) and os.path.isfile(p):
            st = os.stat(p)
            ig = git(d, 'check-ignore', '-q', '--', n)
            files.append({'name': n, 'size': st.st_size, 'mtime': st.st_mtime, 'sha': file_sha(p),
                          'ign': bool(ig and ig.returncode == 0)})
    return {'gitok': True, 'tracked': sorted(t), 'upstream': sorted(upstream_names(d)), 'files': files}


LAST_EXCL = [False]


def exclude_path(d):
    r = git(d, 'rev-parse', '--git-path', 'info/exclude')
    if r is None or r.returncode != 0:
        return None
    p = r.stdout.decode('utf-8', 'replace').strip()
    return p if os.path.isabs(p) else os.path.join(d, p)


def ensure_excluded(d, name):
    # dong "/<ten>" trong .git/info/exclude (khong dung .gitignore) neu git chua bo qua file nay.
    # LAST_EXCL[0] = True chi khi LAN GOI NAY them dong (laptop ghi lai, de sau nay chi go dung dong do)
    LAST_EXCL[0] = False
    ig = git(d, 'check-ignore', '-q', '--', name)
    if ig is None or ig.returncode == 0:
        return
    p = exclude_path(d)
    if not p:
        return
    os.makedirs(os.path.dirname(p), exist_ok=True)
    cur = ''
    if os.path.exists(p):
        with open(p, encoding='utf-8', errors='replace') as f:
            cur = f.read()
    if ('/' + name) in cur.splitlines():
        return
    with open(p, 'a', encoding='utf-8') as f:
        f.write(('' if not cur or cur.endswith('\n') else '\n') + '/' + name + '\n')
    LAST_EXCL[0] = True


def unexclude(d, name):
    # go DUNG dong "/<ten>" (dong ensure_excluded da them); moi dong khac giu nguyen
    p = exclude_path(d)
    if not p or not os.path.exists(p):
        return False
    with open(p, encoding='utf-8', errors='replace', newline='') as f:
        cur = f.read()
    new = re.sub(r'(?m)^/' + re.escape(name) + r'\r?(?:\n|\Z)', '', cur)
    if new == cur:
        return False
    with open(p, 'w', encoding='utf-8', newline='') as f:
        f.write(new)
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
        os.replace(part, dst)
    finally:
        if os.path.exists(part):
            os.unlink(part)
    ensure_excluded(d, name)
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
    # do lai cua lan chay bi cat ngang (ssh rot, box nghi): chi ten tam cua fcode, cu hon 1 gio; khong dung toi gi khac
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
            if not n.startswith('fcode-phien-') or st.st_mtime >= old or (uid is not None and st.st_uid != uid) or os.path.islink(p):
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
                    if '.fcode-part-' in n and os.lstat(p).st_mtime < old and not os.path.islink(p):
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
              'omp': omp_version(), 'all': [{'name': x['name'], 'repo': x['repo']} for x in allp]})


def cmd_projects(_req):
    out_json({'projects': [{'name': x['name'], 'origin': x['origin'], 'repo': x['repo']} for x in box_projects()]})


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
        excl = []
        for it in man.get('notes', []):
            pn, name = it.get('project'), it.get('name')
            d = note_dir(projs, pn)
            if not d or not isinstance(name, str) or not NOTE_RX.match(name):
                continue
            src = os.path.join(stage, 'notes', pn, name)
            LAST_EXCL[0] = False
            if os.path.isfile(src) and place_note(d, name, src, it.get('expect') or '', it.get('sha') or '') == 'ok':
                placed.append(pn + '/' + name)
                if LAST_EXCL[0]:
                    excl.append(pn + '/' + name)
        for it in man.get('ensure', []):
            pn, name = it.get('project'), it.get('name')
            d = note_dir(projs, pn)
            t = tracked_names(d) if d else None
            if d and t is not None and isinstance(name, str) and NOTE_RX.match(name) and name not in t and os.path.isfile(os.path.join(d, name)):
                ensure_excluded(d, name)
                if LAST_EXCL[0]:
                    excl.append(pn + '/' + name)
        unexcl = []
        for it in man.get('unexclude', []):
            pn, name = it.get('project'), it.get('name')
            d = note_dir(projs, pn)   # the other side tracks the name now; the laptop only asks for it when it recorded that THIS line is fcode's
            if d and isinstance(name, str) and NOTE_RX.match(name) and unexclude(d, name):
                unexcl.append(pn + '/' + name)
        cnt['notePlaced'] = placed
        cnt['exclAdded'] = excl
        cnt['unexcluded'] = unexcl
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
      Assert-PhienTime   # quick mode: a big file does not run past the 20 s cap
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
        Assert-PhienTime
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
      Assert-PhienTime
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
    Assert-PhienTime
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
    Assert-PhienTime
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
function Get-PhienCapSec { if ("$env:FCODE_PHIEN_CAP_SEC" -match '\A[1-9][0-9]{0,2}\z') { [int]$env:FCODE_PHIEN_CAP_SEC } else { 20 } }
# "time is up" also when less than 1 s is left: Invoke-BoxPy refuses to start a call then, so the two checks must agree
function Test-PhienTimeUp { [bool]($script:PhienDeadline -and [DateTime]::UtcNow.AddSeconds(1) -ge $script:PhienDeadline) }
# dung tien trinh va moi tien trinh con cua no (instabox -> ssh); Windows PowerShell 5.1 khong co Kill($true) nen dung taskkill
function Stop-PhienProc($p) {
  try { $p.Kill($true) } catch { try { & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null } catch { }; try { $p.Kill() } catch { } }
}
# local scanning / hashing: with a phien deadline set (--nhanh, auto) it stops here, between files and read chunks; Invoke-PhienSync turns it into the cap message
function Assert-PhienTime { if (Test-PhienTimeUp) { throw 'phien-cap' } }

# one argument as the Windows command line wants it (.NET Framework, hence Windows PowerShell 5.1, has no ArgumentList)
function ConvertTo-PhienArg([string]$a) {
  if ($a -ne '' -and $a -notmatch '[\s"]') { return $a }
  '"' + ([regex]::Replace($a, '(\\*)"', '$1$1\"') -replace '(\\+)\z', '$1$1') + '"'
}
# run a program with its output captured (stdin closed, so it can never wait for a key). While a phien deadline is set the program is killed with its
# children when the deadline passes (Code 124), and it is not started at all when less than 1 s is left. Out = stdout lines.
function Invoke-PhienExe([string]$Exe, [string[]]$ExeArgs) {
  if (Test-PhienTimeUp) { return [pscustomobject]@{ Code = 124; Out = [string[]]@(); Err = '' } }
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe; $psi.Arguments = (@($ExeArgs | ForEach-Object { ConvertTo-PhienArg ([string]$_) }) -join ' ')
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  try { $p = [Diagnostics.Process]::Start($psi) } catch { return [pscustomobject]@{ Code = -1; Out = [string[]]@(); Err = "$($_.Exception.Message)" } }
  try {
    try { $p.StandardInput.Close() } catch { }
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    $ms = if ($script:PhienDeadline) { [int][Math]::Max(0, ($script:PhienDeadline - [DateTime]::UtcNow).TotalMilliseconds) } else { -1 }
    if (-not $p.WaitForExit($ms)) { Stop-PhienProc $p; return [pscustomobject]@{ Code = 124; Out = [string[]]@(); Err = 'quá thời gian chờ' } }
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
  $sec = Get-PhienLimitSec $false
  if ($script:PhienDeadline) {
    $sec = ($script:PhienDeadline - [DateTime]::UtcNow).TotalSeconds
    if ($sec -lt 1) { return [pscustomobject]@{ Code = 124; Out = [byte[]]@(); Err = 'hết thời gian của lượt này' } }
  }
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
  if ($script:PhienQuiet -or $script:PhienQuick) { $script:PhienLines.Add($Msg) }   # auto and quick (--nhanh) runs write phien.log only
  if (-not $script:PhienQuiet -and -not $script:PhienQuick) { Write-Host $Msg }
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

# do lai cua lan chay bi cat ngang (may ngu, mat dien, tat cua so): chi ten tam cua fcode, cu hon 1 gio.
# %TEMP%\fcode-phien-* va *.fcode-part-* trong cac thu muc phien da cho; khong dung toi gi khac.
function Clear-PhienLeftovers([string[]]$Dirs) {
  $old = (Get-Date).ToUniversalTime().AddHours(-1)
  foreach ($x in @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'fcode-phien-*' -Force -ErrorAction SilentlyContinue)) {
    if ($x.LastWriteTimeUtc -lt $old -and -not ($x.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Remove-Item -LiteralPath $x.FullName -Recurse -Force -ErrorAction SilentlyContinue }
  }
  foreach ($d in $Dirs) {
    if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
    foreach ($x in @(Get-ChildItem -LiteralPath $d -Recurse -File -Force -Filter '*.fcode-part-*' -ErrorAction SilentlyContinue)) {
      if ($x.LastWriteTimeUtc -lt $old) { Remove-Item -LiteralPath $x.FullName -Force -ErrorAction SilentlyContinue }
    }
  }
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
    [IO.File]::WriteAllText($p, ($o | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
  } catch { }
}
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
function Invoke-PhienSync([string]$Only, [bool]$Auto, [bool]$DryRun = $false, [bool]$BoxKnownRunning = $false, [bool]$Quick = $false) {
  $script:PhienQuiet = $Auto; $script:PhienQuick = $Quick; $script:PhienLines = New-Object System.Collections.Generic.List[string]; $script:PhienScreen = $null
  if ($Quick) { $ErrorActionPreference = 'SilentlyContinue' }   # a stray error of a cmdlet must not become a second line on the screen (this function's own scope only)
  $capMsg = 'phien: hết 20 giây, phần còn lại chạy lần sau'
  $code = 0; $capHit = $false
  # lan tu dong: MOT han chot cho ca lan chay, tinh tu luc tien trinh bat dau (nhu gioi han 8 phut cua Task Scheduler)
  $script:PhienDeadline = if ($Auto) { [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().AddSeconds((Get-PhienLimitSec $true)) } elseif ($Quick) { [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().AddSeconds((Get-PhienCapSec)) } else { $null }
  $mx = $null; $held = $false
  if (-not $DryRun) {
    try {
      # chi de thu: FCODE_PHIEN_LOCK doi ten khoa (bo test dung ten rieng, khong dung khoa that)
      $lk = if ("$env:FCODE_PHIEN_LOCK" -match '\A[A-Za-z0-9\\._-]{1,200}\z') { $env:FCODE_PHIEN_LOCK } else { 'Local\fcode-phien' }
      $mx = New-Object Threading.Mutex($false, $lk)
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
    $projs = Get-PhienProjects
    if ($projs.Count -eq 0) { Write-PhienOut "Chưa có project nào trong syncRepos ($ConfigFile)."; return 0 }
    $names = @($projs.Keys)
    if ($Only) {
      $o = $Only.ToLowerInvariant()
      if (-not $projs.Contains($o)) { Write-PhienOut "Không thấy project '$Only' trong syncRepos. Có: $($names -join ', ')"; return 1 }
      $names = @($o)
    }
    if ($Quick) {   # only `instabox ls`: never wakes the box
      $bs = Test-BoxRunning
      if ($bs -eq 'timeout') { Set-PhienScreen $capMsg; return 0 }
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
    $r = Invoke-BoxPy 'scan' ([Text.Encoding]::UTF8.GetBytes((@{ projects = @($names); repos = @($repoDir.Keys); clean = (-not $DryRun) } | ConvertTo-Json -Compress)))
    $scan = Get-BoxJson $r
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
      $ldir = $pick[[string]$bp.name]
      if (-not $ldir -and $bp.repo -and $repoDir.ContainsKey([string]$bp.repo)) { continue }   # thu muc cua repo nay da thuoc project khac
      if (-not $ldir -or -not (Test-Path -LiteralPath $ldir)) { Write-PhienOut "== $($bp.name): bỏ qua, không thấy thư mục project trên laptop"; continue }
      $lsd = Join-Path $sessRoot (Get-LaptopEncodedDir $ldir)
      $ctx += [pscustomobject]@{ Name = [string]$bp.name; LDir = $ldir; BDir = [string]$bp.dir; Lsd = $lsd; Benc = [string]$bp.enc; L = (Get-PhienLocalScan $lsd); R = @($bp.sessions); LN = (Get-PhienLocalNotes $ldir); RN = $bp.notes }
    }
    # project moi tren box chua co tren laptop: chi ghi lai (lan tu dong khong hoi, khong clone; `fcode sync` moi them)
    if (-not $Only) {
      $stat.newProjects = @(@($scan.all) | Where-Object { $_ -and -not $projs.Contains([string]$_.name) -and -not ($_.repo -and $repoDir.ContainsKey([string]$_.repo)) } | ForEach-Object { [string]$_.name })
      if ($stat.newProjects.Count) { Write-PhienOut "project trên box chưa có trên laptop: $($stat.newProjects -join ', ') (chạy fcode sync để thêm)" }
    }
    if (-not $DryRun) { Clear-PhienLeftovers @(@($ctx | ForEach-Object { $_.Lsd }) + @($laptopBlobDir)) }
    # lan 1: tim cac cho can hash cua box; hoi mot lan; lan 2: ke hoach that
    $hashes = @{}
    $need = @()
    foreach ($c in $ctx) {
      $need += @((Get-PhienPlan $c.L $c.R $c.Benc @{} $c.Lsd $lnow $rnow $PhienBusySec $lblobIx $boxBlobs).Need)
    }
    if ($need.Count -gt 0) {
      $q = @{ q = @($need | ForEach-Object { @{ enc = $_.enc; rel = $_.rel; len = $_.len } }) } | ConvertTo-Json -Compress -Depth 4
      $hr = Invoke-BoxPy 'hash' ([Text.Encoding]::UTF8.GetBytes($q))
      if ($Quick -and $hr.Code -eq 124) { Set-PhienScreen $capMsg; return 0 }   # the deadline ended the call: a cap hit, not a warning
      $h = Get-BoxJson $hr
      if ($h) { foreach ($pr in $h.h.PSObject.Properties) { $hashes[$pr.Name] = $pr.Value } }
      else { Write-PhienOut 'cảnh báo: không so sánh được các phiên đã đổi ở hai máy, bỏ qua chúng lần này' }
    }
    $tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('fcode-phien-' + [guid]::NewGuid().ToString('N'))
    try {
      $putU = New-Object System.Collections.ArrayList; $getU = New-Object System.Collections.ArrayList
      $putN = New-Object System.Collections.ArrayList; $getN = New-Object System.Collections.ArrayList
      $ensure = New-Object System.Collections.ArrayList; $unexcl = New-Object System.Collections.ArrayList
      $noteDel = New-Object System.Collections.ArrayList
      $nPutSess = 0; $nGetSess = 0; $nSame = 0; $planIncomplete = 0
      $plans = @{}; $queuedBlob = @{}
      $noteState = Read-PhienNoteState; $noteRec = @{}; $noteShaPut = @{}; $noteGetInfo = @{}; $noteSkipped = 0; $fileSkipped = 0
      foreach ($c in $ctx) {
        $plan = Get-PhienPlan $c.L $c.R $c.Benc $hashes $c.Lsd $lnow $rnow $PhienBusySec $lblobIx $boxBlobs
        $plans[$c.Name] = $plan
        $nSame += $plan.Same; $planIncomplete += $plan.Incomplete + $plan.Deferred
        $stat.unknown += @($plan.Unknown); $stat.diverged += $plan.Diverged
        $np = Get-PhienNotePlan $c.Name $c.LN $c.RN $noteState $lnow $rnow $PhienBusySec
        foreach ($cf in $np.Conflicts) { $stat.noteConf += $cf }
        foreach ($k in $np.Record.Keys) { $noteRec[$k] = $np.Record[$k] }
        foreach ($rl in $np.Release) {
          $stat.noteReleased += "$($c.Name)/$($rl.Name)"
          Write-PhienOut "  [$($c.Name)] ghi chú $($rl.Name) giờ do git theo dõi (trên $($rl.TrackedOn)): bản cũ trên $($rl.OldOn) xóa được, fcode không còn đồng bộ file này"
          if (-not $DryRun) {
            $rk = "$($c.Name)/$($rl.Name)"
            if ($rl.OldOn -eq 'laptop') { [void](Remove-PhienNoteExclude $c.LDir $rl.Name); [void]$noteDel.Add("exclude:laptop:$rk"); [void]$noteDel.Add($rk) }
            else { [void]$unexcl.Add(@{ project = $c.Name; name = $rl.Name }) }
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
      $saveNotes = { if ($noteRec.Count -or $noteDel.Count) { foreach ($k in $noteRec.Keys) { $noteState[$k] = $noteRec[$k] }; foreach ($k in $noteDel) { $noteState.Remove([string]$k) }; try { Write-PhienNoteState $noteState } catch { } } }
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
        foreach ($k in @($res.exclAdded)) { if ($k) { $noteRec["exclude:box:$k"] = '1' } }
        foreach ($k in @($res.unexcluded)) { if ($k) { [void]$noteDel.Add("exclude:box:$k"); [void]$noteDel.Add([string]$k) } }
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
          try { $st = Install-PhienFile $src (Join-Path $u.C.Lsd ($u.Rel -replace '/', '\')) $u.C.BDir $u.C.LDir $gnow $PhienBusySec } catch { if ("$($_.Exception.Message)" -ceq 'phien-cap') { throw }; $st = 'failed' }
          $getRes[$st]++
        }
        # 4. ghi chu
        foreach ($u in @($gbt.Items | Where-Object { $_.K -eq 'note' })) {
          $src = Join-Path $gt ('notes\' + $u.C.Name + '\' + $u.Name)
          $key = "$($u.C.Name)/$($u.Name)"; $info = $noteGetInfo[$key]
          if (-not (Test-Path -LiteralPath $src)) { $noteSkipped++; continue }
          if ((Install-PhienNote $src $u.C.LDir $u.Name $info.Expect $gnow $PhienBusySec ([string]$info.Sha)) -eq 'ok') { $noteRec[$key] = [string]$info.Sha; $stat.noteCopied++; if ($script:PhienLastExclAdded) { $noteRec["exclude:laptop:$key"] = '1' } } else { $noteSkipped++ }
        }
        Remove-Item -LiteralPath $gtar, $gt -Recurse -Force -ErrorAction SilentlyContinue
        & $saveNotes
        'ok'
      }
      # --- thu tu: moi dot thuong (<= 50 MB) truoc, lay ve roi gui len; roi moi dot mot file qua lon, nho truoc; sau cung file chinh cua cac phien do.
      # Dot loi thi ghi lai roi lam dot sau; chi het gio cua lan chay hoac mat box (ssh 255) moi dung han.
      $jobs = New-Object System.Collections.ArrayList; $big = New-Object System.Collections.ArrayList
      foreach ($bb in $getB) { if (& $bigName $bb) { [void]$big.Add(@{ D = 'get'; B = $bb }) } else { [void]$jobs.Add(@{ D = 'get'; B = $bb }) } }
      foreach ($bb in $putB) { if (& $bigName $bb) { [void]$big.Add(@{ D = 'put'; B = $bb }) } else { [void]$jobs.Add(@{ D = 'put'; B = $bb }) } }
      foreach ($job in @($big | Sort-Object { [long]$_.B.Bytes })) { [void]$jobs.Add($job) }
      foreach ($bb in $getLB) { [void]$jobs.Add(@{ D = 'get'; B = $bb }) }; foreach ($bb in $putLB) { [void]$jobs.Add(@{ D = 'put'; B = $bb }) }
      foreach ($job in $jobs) {
        if (Test-PhienTimeUp) { if ($Quick) { $capHit = $true } else { Write-PhienOut 'hết thời gian của lượt này: phần còn lại để lần sau'; $code = 1 }; break }
        $st = if ($job.D -eq 'put') { . $doPut $job.B } else { . $doGet $job.B }
        if ("$st" -eq 'ok') { continue }
        if ("$st" -eq 'cap') { if ($Quick) { $capHit = $true } else { Write-PhienOut 'hết thời gian của lượt này: phần còn lại để lần sau'; $code = 1 }; break }
        $code = 1
        $bn = & $bigName $job.B; if ($bn) { Write-PhienOut "phiên lớn: $bn chưa chép xong — chạy ``fcode phien`` khi mạng tốt"; $stat.unfinished += $bn }
        if ("$st" -eq 'lost') { Write-PhienOut 'lỗi: mất kết nối với box, phần còn lại để lần sau'; break }
      }
      $noteSkipped += $notePlanned - $placedPut
      # --- bao cao ---
      $up = [int]$putRes.new + [int]$putRes.replaced
      $down = [int]$getRes.new + [int]$getRes.replaced
      foreach ($c in $ctx) { $pl = $plans[$c.Name]; Write-PhienOut ("== $($c.Name): gửi $(@($pl.Put | Where-Object { $_.Top }).Count) phiên lên box, lấy $(@($pl.Get | Where-Object { $_.Top }).Count) phiên về, $($pl.Same) đã giống nhau") }
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
    if ("$($_.Exception.Message)" -ceq 'phien-cap') {   # a scan, hash or child program ran into the deadline (Assert-PhienTime, Invoke-GitQuiet)
      if ($Quick) { Set-PhienScreen $capMsg; return 0 }
      $stat.ok = $false; Write-PhienOut 'hết thời gian của lượt này: phần còn lại để lần sau'; return 1
    }
    $stat.ok = $false
    Write-PhienOut ('lỗi: ' + $_.Exception.Message)
    return 1
  } finally {
    if ($stat.ran -and -not $DryRun) { Write-PhienStatus $stat $Auto }
    if ($mx) { if ($held) { try { $mx.ReleaseMutex() } catch { } }; $mx.Dispose() }
    if (($Auto -or $Quick) -and $script:PhienLines.Count -gt 0) { Add-PhienLog $script:PhienLines }
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

function Invoke-GitQuiet([string]$Dir, [string[]]$GitArgs) {
  $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $git) { return [pscustomobject]@{ Code = -1; Out = @() } }
  $r = Invoke-PhienExe $git.Source (@('--no-optional-locks', '-C', $Dir, '-c', 'core.quotepath=false') + @($GitArgs))   # killed at the phien deadline like every other child
  if ($r.Code -eq 124) { throw 'phien-cap' }   # killed at the deadline: never read a half answer as "git said no"
  [pscustomobject]@{ Code = $r.Code; Out = @($r.Out) }
}

# ghi chu nam trong nhanh mac dinh cua origin (ban da fetch): git se mang file do toi, nen cung tinh la da theo doi (nhu box `upstream_names`)
function Get-PhienUpstreamNotes([string]$Dir) {
  $h = Invoke-GitQuiet $Dir @('symbolic-ref', '-q', 'refs/remotes/origin/HEAD')
  $ref = if ($h.Code -eq 0 -and @($h.Out)[0]) { [string]@($h.Out)[0] } else { '' }
  # khong co origin/HEAD (remote add + fetch): origin/main, roi origin/master
  foreach ($c in 'refs/remotes/origin/main', 'refs/remotes/origin/master') { if (-not $ref -and (Invoke-GitQuiet $Dir @('rev-parse', '-q', '--verify', $c)).Code -eq 0) { $ref = $c } }
  if (-not $ref) { return , @() }
  $r = Invoke-GitQuiet $Dir @('ls-tree', '--name-only', $ref)
  if ($r.Code -ne 0) { return , @() }
  $rx = Get-PhienNoteRx
  , @($r.Out | Where-Object { $_ -cmatch $rx } | Sort-Object)
}

# cung dang voi `scan_notes` cua box: @{gitok; tracked (index); upstream (origin/<mac dinh>); files = {name,size,mtime,sha,ign}}
function Get-PhienLocalNotes([string]$Dir) {
  $r = Invoke-GitQuiet $Dir (@('ls-files', '--') + (Get-PhienNoteSpecs))
  if ($r.Code -ne 0) { return [pscustomobject]@{ gitok = $false; tracked = @(); upstream = @(); files = @() } }
  $rx = Get-PhienNoteRx
  $files = New-Object System.Collections.ArrayList
  foreach ($f in (Get-ChildItem -LiteralPath $Dir -File -Force | Sort-Object Name)) {
    Assert-PhienTime
    if ($f.Name -cnotmatch $rx) { continue }
    $ig = Invoke-GitQuiet $Dir @('check-ignore', '-q', '--', $f.Name)
    [void]$files.Add([pscustomobject]@{ name = $f.Name; size = $f.Length; mtime = (ConvertTo-Epoch $f.LastWriteTimeUtc); sha = (Get-RangeSha $f.FullName 0 $f.Length); ign = ($ig.Code -eq 0) })
  }
  [pscustomobject]@{ gitok = $true; tracked = @($r.Out | Where-Object { $_ -cmatch $rx } | Sort-Object); upstream = (Get-PhienUpstreamNotes $Dir); files = @($files) }
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
    # and give that one line back
    foreach ($n in @($lt + $up | Sort-Object -Unique)) { if (-not ($rt -ccontains $n) -and $rm[$n] -and $State["exclude:box:$Proj/$n"]) { [void]$release.Add([pscustomobject]@{ Name = $n; TrackedOn = $(if ($lt -ccontains $n) { 'laptop' } else { 'origin' }); OldOn = 'box' }) } }
    foreach ($n in @($rt + $up | Sort-Object -Unique)) { if (-not ($lt -ccontains $n) -and $lm[$n] -and $State["exclude:laptop:$Proj/$n"]) { [void]$release.Add([pscustomobject]@{ Name = $n; TrackedOn = $(if ($rt -ccontains $n) { 'box' } else { 'origin' }); OldOn = 'laptop' }) } }
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

function Get-PhienNoteStatePath { Join-Path $env:LOCALAPPDATA 'fcode\handoff-state.json' }
function Read-PhienNoteState {
  $h = @{}
  try { foreach ($p in ([IO.File]::ReadAllText((Get-PhienNoteStatePath)) | ConvertFrom-Json).PSObject.Properties) { $h[$p.Name] = [string]$p.Value } } catch { }
  $h
}
function Write-PhienNoteState([hashtable]$S) {
  $p = Get-PhienNoteStatePath
  $d = Split-Path -Parent $p
  if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
  $o = [ordered]@{}; foreach ($k in ($S.Keys | Sort-Object)) { $o[$k] = $S[$k] }
  $tmp = $p + '.part'
  [IO.File]::WriteAllText($tmp, ($o | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
  if (Test-Path -LiteralPath $p) { [IO.File]::Replace($tmp, $p, [NullString]::Value) } else { [IO.File]::Move($tmp, $p) }
}

# them "/<ten>" vao .git/info/exclude (khong dung .gitignore) neu git chua bo qua file. Tra ve $true chi khi LAN NAY them dong
# (noi goi ghi lai de sau nay chi go dung dong do)
function Add-PhienNoteExclude([string]$Dir, [string]$Name) {
  if ((Invoke-GitQuiet $Dir @('check-ignore', '-q', '--', $Name)).Code -eq 0) { return $false }
  $r = Invoke-GitQuiet $Dir @('rev-parse', '--git-path', 'info/exclude')
  $p = @($r.Out)[0]
  if ($r.Code -ne 0 -or -not $p) { return $false }
  if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $Dir $p }
  $pd = Split-Path -Parent $p
  if (-not (Test-Path -LiteralPath $pd)) { [void](New-Item -ItemType Directory -Path $pd -Force) }
  $cur = if (Test-Path -LiteralPath $p) { [IO.File]::ReadAllText($p) } else { '' }
  if (@($cur -split '\r?\n') -ccontains ('/' + $Name)) { return $false }
  [IO.File]::AppendAllText($p, $(if ($cur -and -not $cur.EndsWith("`n")) { "`n" } else { '' }) + '/' + $Name + "`n", (New-Object Text.UTF8Encoding($false)))
  $true
}

# go DUNG dong "/<ten>" (dong fcode da them); moi dong khac trong .git/info/exclude giu nguyen. Tra ve $true neu da go
function Remove-PhienNoteExclude([string]$Dir, [string]$Name) {
  $r = Invoke-GitQuiet $Dir @('rev-parse', '--git-path', 'info/exclude')
  $p = @($r.Out)[0]
  if ($r.Code -ne 0 -or -not $p) { return $false }
  if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $Dir $p }
  if (-not (Test-Path -LiteralPath $p)) { return $false }
  $cur = [IO.File]::ReadAllText($p)
  $new = [regex]::Replace($cur, '(?m)^/' + [regex]::Escape($Name) + '\r?(?:\n|\z)', '')
  if ($new -ceq $cur) { return $false }
  [IO.File]::WriteAllText($p, $new, (New-Object Text.UTF8Encoding($false)))
  $true
}

# dat mot file ghi chu da lay tu box vao goc project tren laptop. Tra ve: ok | changed | busy | tracked
function Install-PhienNote([string]$Src, [string]$Dir, [string]$Name, [string]$Expect, [double]$Now, [int]$Busy = 30, [string]$Sha = '') {
  if ($Sha -and (Get-RangeSha $Src 0 (Get-Item -LiteralPath $Src).Length) -ne $Sha) { return 'changed' }
  $t = Invoke-GitQuiet $Dir @('ls-files', '--', $Name)
  if ($t.Code -ne 0 -or $t.Out -ccontains $Name -or (Get-PhienUpstreamNotes $Dir) -ccontains $Name) { return 'tracked' }
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
    if (Test-Path -LiteralPath $dst) { [IO.File]::Replace($part, $dst, [NullString]::Value) } else { [IO.File]::Move($part, $dst) }
    [IO.File]::SetLastWriteTimeUtc($dst, $mt)
  } finally { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
  $script:PhienLastExclAdded = [bool](Add-PhienNoteExclude $Dir $Name)
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
    [IO.File]::WriteAllText($p, ([ordered]@{ boxRunning = [bool]$S.boxRunning; lastSshAt = [double]$S.lastSshAt } | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
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
# nhat ky cho che do tu dong: chi dong tom tat, khong bao gio noi dung phien. Cat con ~100 KB.
function Add-PhienLog($Lines) {
  try {
    $d = Split-Path -Parent $PhienLog
    if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
    if ((Test-Path -LiteralPath $PhienLog) -and (Get-Item -LiteralPath $PhienLog).Length -gt 200KB) {
      $keep = Get-Content -LiteralPath $PhienLog -Tail 400; Set-Content -LiteralPath $PhienLog -Value $keep -Encoding UTF8
    }
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $PhienLog -Value @($Lines | ForEach-Object { "$ts $_" }) -Encoding UTF8
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

# fcode phien [project] | <project> --nhanh | tu-dong bat|tat|trangthai | --tu-dong (do Task Scheduler goi)
function Invoke-Phien {
  $dry = [bool]($Rest | Where-Object { $_ -eq '--thu' })
  $quick = [bool]($Rest | Where-Object { $_ -eq '--nhanh' })
  $pa = @($Rest | Select-Object -Skip 1 | Where-Object { $_ -ne '--thu' -and $_ -ne '--nhanh' })
  $sub = if ($pa.Count -gt 0) { $pa[0] } else { '' }
  foreach ($a in $Rest) { if (Test-HasControlChar $a) { Write-Host 'lỗi: tham số có ký tự không hợp lệ.'; return 1 } }
  if ($sub -eq '--tu-dong') { return (Invoke-PhienAutoRun) }   # khoa chung (Local\fcode-phien) nam trong Invoke-PhienSync
  if ($sub -eq 'tu-dong') { return (Invoke-PhienAuto $(if ($pa.Count -gt 1) { $pa[1] } else { '' })) }
  if (($sub -and $sub -notmatch '\A[A-Za-z0-9._-]+\z') -or ($quick -and (-not $sub -or $dry))) { Write-Host 'Cách dùng: fcode phien [project]    fcode phien <project> --nhanh    fcode phien tu-dong bat|tat'; return 1 }
  $rc = Invoke-PhienSync $sub $false $dry $false $quick
  # --nhanh (the hook): the screen gets at most one line, the asleep / busy / cap message, or one short line when the sync failed; success prints nothing
  if ($quick) { if ($script:PhienScreen) { Write-Host $script:PhienScreen } elseif ($rc -ne 0) { Write-Host 'phien: không đồng bộ được, xem phien.log' } }
  $rc
}

# --- fcode moc bat|tat|trang-thai: hook trong profile PowerShell ---
# Khi gõ omp / claude / codex trong thu muc mot project (syncRepos), hook chay `fcode phien <project> --nhanh` truoc (cho xong, toi da 25 s),
# chay chuong trinh that, roi chay lai --nhanh an o nen. Khoi nam giua hai dong danh dau; fcode chi sua khoi nay, khong dong gi khac cua profile.
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
    } catch { }
  }
  $sync = $proj -and $fc
  if ($sync) {
    try {
      $psi = New-Object Diagnostics.ProcessStartInfo
      $psi.FileName = $fc.Source; $psi.Arguments = "phien $proj --nhanh"; $psi.UseShellExecute = $false
      $pr = [Diagnostics.Process]::Start($psi)
      if (-not $pr.WaitForExit(25000)) { & taskkill.exe /PID $pr.Id /T /F 2>&1 | Out-Null }
      $pr.Dispose()
    } catch { Write-Host ([regex]::Unescape('fcode: kh\u00f4ng \u0111\u1ed3ng b\u1ed9 \u0111\u01b0\u1ee3c phi\u00ean, b\u1ecf qua.')) }
  }
  # piped input (echo hi | claude -p) goes on to the real program; with nothing piped it keeps the console, so the terminal UI works
  if ($MyInvocation.ExpectingInput) { $input | & $real.Source @Rest } else { & $real.Source @Rest }
  $rc = $LASTEXITCODE
  if ($sync) {
    try {
      # the sync after the agent ends waits 35 s first (a session saved a moment ago counts as "being written" for 30 s); FCODE_MOC_DELAY is for tests only
      $d = 35; if ($env:FCODE_MOC_DELAY -match '\A[0-9]{1,3}\z') { $d = [int]$env:FCODE_MOC_DELAY }
      $psi = New-Object Diagnostics.ProcessStartInfo
      $psi.FileName = 'cmd.exe'; $psi.Arguments = '/d /c "ping -n ' + ($d + 1) + ' 127.0.0.1 >nul & "' + $fc.Source + '" phien ' + $proj + ' --nhanh >nul 2>&1"'
      $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
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
if ($arg -eq 'phien') { exit (Invoke-Phien) }
if ($arg -eq 'moc') { exit (Invoke-Moc) }
if ($arg -eq '-l') { $arg = '--list' }
if ($arg -eq 'new') { $arg = '--new' }
# ten phien: chi chu, so, . _ - (\z, khong dung $: $ chap nhan them 1 ky tu xuong dong o cuoi)
if ($arg -and $arg -ne '--list' -and $arg -ne '--new' -and $arg -notmatch '\A[A-Za-z0-9._-]+\z') {
  Write-Host "Không hiểu lệnh '$($arg -replace '[\x00-\x1f\x7f]', '?')'. Gõ fcode help để xem các lệnh."
  exit 1
}
if (-not $arg) { $pw = Get-PhienWarning; if ($pw) { Write-Host $pw -ForegroundColor Yellow } }
$ib = Get-InstaboxExe
# tham so $1 di cung script (set -- '..'), khong nam tren dong lenh ssh
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("set -- '$arg'`n" + $FcodeSh))
$remote = "bash <(echo $b64 | base64 -d)"
# box tu tam dung (ranh 30 phut / chay 8 tieng) thi danh thuc truoc; loi wake de ssh tu bao
& $ib wake $box *> $null
if ($arg -eq '--list') { & $ib ssh $box -- $remote } else { & $ib ssh $box -- -q -tt $remote }
$rc = $LASTEXITCODE
if ($rc -eq 77 -and -not $arg) { exit (Invoke-PhienMenu) }
# tham so khong khop phien nao (hoac loi) thi nhac lenh help
if ($rc -ne 0 -and $arg -and $arg -ne '--list' -and $arg -ne '--new') { Write-Host "Nếu '$arg' không phải tên phiên, gõ fcode help để xem các lệnh." }
exit $rc
