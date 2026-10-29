# Tests for `fcode phien` (laptop/fcode.ps1): omp session sync laptop <-> box.
# Run:  pwsh -NoProfile -File test/fcode-phien.test.ps1     (also works with: powershell -NoProfile -File ...)
# Needs python (3.8+) on PATH: the box program ($PhienPy) is run locally through test/fake-instabox.cmd, so the real
# ~/.omp and the real box are never touched. Everything lives in a temp folder that is removed at the end.
#   FCODE_TEST_BOX=1   also run one end-to-end pass on the real instabox box (throwaway HOME there; laptop side = temp USERPROFILE).
#   FCODE_TEST_ONLY=<regex>   run only the tests whose name matches (used for the mutant runs)
# Test-only overrides of fcode.ps1 used by the 1.3.3 tests (`phien --nhanh`, `moc`): FCODE_PHIEN_CAP_SEC (the 20 s cap of --nhanh), FCODE_DOCUMENTS
# (stands for [Environment]::GetFolderPath('MyDocuments'), where `fcode moc` keeps the PowerShell profiles), FCODE_PHIEN_LOCK (the lock name),
# FCODE_MOC_DELAY (read by `fcode phien <p> --nhanh --nen`, the hook's run after the agent ends: seconds it waits first; 35 by default, the tests use 4).
# The profile hook is run in child PowerShell processes with a temp USERPROFILE and a fake bin folder (omp / claude / codex / fcode .cmd) first on PATH.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$Repo = Split-Path -Parent $PSScriptRoot
$Fcode = Join-Path $Repo 'laptop\fcode.ps1'
$Root = Join-Path ([IO.Path]::GetTempPath()) ('fcode-phien-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $Root)
Set-Location -LiteralPath $Root   # stray files from child processes (e.g. PowerShell's module cache) land here and are removed with it
$script:pass = 0; $script:fail = 0
# a lock name of our own: never the real `Local\fcode-phien` (the user's task or a second suite run would collide)
$env:FCODE_PHIEN_LOCK = 'Local\fcode-phien-test-' + [guid]::NewGuid().ToString('N')

function T([string]$Name, [scriptblock]$Body) {
  if ($env:FCODE_TEST_ONLY -and $Name -notmatch $env:FCODE_TEST_ONLY) { return }
  try { & $Body; $script:pass++; Write-Host "PASS $Name" }
  catch { $script:fail++; Write-Host "FAIL $Name :: $($_.Exception.Message)" }
}
function Eq($Got, $Want, [string]$What = '') { if ("$Got" -cne "$Want") { throw "$What expected [$Want] got [$Got]" } }
function Ok([bool]$c, [string]$What) { if (-not $c) { throw $What } }

# --- load the phien functions and $PhienPy out of fcode.ps1 without running the script ---
$tokens = $null; $errs = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Fcode, [ref]$tokens, [ref]$errs)
if ($errs.Count) { throw "fcode.ps1 does not parse: $($errs[0].Message)" }
$wanted = 'Test-WinPath', 'Resolve-OmpPath', 'Get-OmpUnder', 'Join-OmpName', 'Get-OmpEncodedDir', 'ConvertTo-Epoch', 'Convert-OmpCwd', 'ConvertTo-JsonStr',
  'Get-OmpHeaderSpan', 'Open-ShareRead', 'Read-Head', 'Get-OmpBodyOff', 'Test-OmpNonEmpty', 'Get-RangeSha', 'Get-PhienOff', 'Test-PhienPrefix', 'Get-PhienKnownVersions', 'Test-PhienKnownVersion', 'Get-OmpHeaderVersion', 'Get-OmpHeaderInfo', 'Get-PhienVersionNote', 'Get-PhienUnknownNote', 'Get-PhienNoteRx', 'Get-PhienNoteSpecs', 'Invoke-GitQuiet', 'Get-PhienLocalNotes', 'Get-PhienNotePlan', 'Get-PhienNoteStatePath', 'Read-PhienNoteState', 'Write-PhienNoteState', 'Get-PhienExcludeFile', 'Add-PhienExcludeLine', 'Test-PhienExcludeLine', 'Install-PhienNote',
  'Copy-OmpSession', 'Get-OmpBlobRefs', 'Get-OmpBlobIndex', 'Get-PhienLocalScan', 'Compare-PhienFile', 'Get-PhienPlan', 'Install-PhienFile',
  'Install-PhienTask', 'Remove-PhienTask', 'New-PhienPartName', 'Get-PhienBoxBlobSet', 'New-PhienBatch', 'Get-PhienBatch', 'Remove-PhienNoteExclude',
  'Get-PhienDirFiles', 'Get-PhienIdOf', 'Test-PhienDeps', 'Get-PhienUnitBytes', 'Get-PhienUpstreamNotes',
  'Add-SyncRepoConfig', 'Test-SyncFolder', 'Get-RepoKey', 'Get-GitDirOrigin', 'Find-LocalClones', 'Get-SyncDesktop', 'Get-FcodeAddLimitVars', 'Get-MocPolicy', 'Write-MocPolicy',
  'Test-PhienTimeUp', 'Get-PhienChildMs', 'Stop-PhienProc', 'ConvertTo-PhienArg', 'Invoke-PhienExe',
  'Write-PhienText', 'Test-PhienReparse', 'Get-PhienLockName', 'Add-PhienLog', 'Write-PhienOut', 'Get-PhienCapSec', 'Get-PhienNenDelaySec', 'Invoke-PhienBounded',
  'Clear-PhienPartFiles', 'Test-PhienOwnerGone', 'Get-PhienMarkRx', 'Test-PhienMarkedLine', 'ConvertTo-PhienLatin1', 'Read-PhienExcludeText', 'Get-PhienRepoId', 'Get-PhienRepoIdNow', 'Test-PhienSharedNote', 'Get-PhienLaptopRelease',
  'Get-PrefsPath', 'Get-PrefsMap', 'Get-PrefsNames', 'Get-ProjectAliases', 'Save-PrefsCache', 'Resolve-ProjectName', 'Format-ProjectName', 'Get-PhienKeyOf', 'Get-LocalRepoKey', 'Get-BareScript'
foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
# the git half and the file half that Install-PhienNote uses (git first, then the move, then the line), as one call for the exclude tests below
function Add-PhienNoteExclude([string]$Dir, [string]$Name) { $f = Get-PhienExcludeFile $Dir $Name; [bool]($f -and (Add-PhienExcludeLine $f $Name)) }
$pyAssign = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$PhienPy' }, $true)
Invoke-Expression $pyAssign.Extent.Text
foreach ($mn in '$MocBegin', '$MocEnd', '$MocRx', '$MocBlock', '$PhienFailMsg', '$FcodeSh') {   # the profile hook text and its markers, exactly as `fcode moc bat` writes them; the failure line
  Invoke-Expression ($ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $mn }, $true).Extent.Text)
}
$PhienLog = Join-Path $Root 'unit-phien.log'   # in-process Add-PhienLog / Write-PhienOut write here, never to the real log
$PyFile = Join-Path $Root 'phien.py'
[IO.File]::WriteAllText($PyFile, $PhienPy, (New-Object Text.UTF8Encoding($false)))

# --- fixtures ---
$utf8 = New-Object Text.UTF8Encoding($false)
$Now = ConvertTo-Epoch (Get-Date)
$AgeBase = [DateTime]::UtcNow
function Set-Age([string]$Path, [int]$Sec) { [IO.File]::SetLastWriteTimeUtc($Path, $AgeBase.AddSeconds(-$Sec)) }   # same age = same instant (the equal-length rule compares mtimes)
function Msg([string]$Id, [string]$Text = 'hi') { '{"type":"message","id":"' + $Id + '","parentId":null,"timestamp":"2026-10-25T16:18:29.000Z","message":{"role":"user","content":"' + $Text + '"}}' }
# session file: line1 title, line2 header, then message lines (no model_change: omp would try to restore a model that an empty throwaway profile lacks). $Nl = line ending. keys of the header like omp (laptop order)
function New-Sess([string]$Dir, [string]$Id, [string]$Cwd, [string[]]$Msgs, [string]$Title = 'T', [string]$Nl = "`n", [string]$Ts = '2026-10-25T16-18-25-246Z') {
  [void](New-Item -ItemType Directory -Path $Dir -Force)
  $p = Join-Path $Dir ($Ts + '_' + $Id + '.jsonl')
  $lines = @(('{"type":"title","v":1,"title":"' + $Title + '","updatedAt":"2026-10-25T16:18:25.246Z","pad":"  "}'),
    ('{"type":"session","version":3,"id":"' + $Id + '","timestamp":"2026-10-25T16:18:25.246Z","cwd":' + (ConvertTo-JsonStr $Cwd) + ',"title":"' + $Title + '"}')) + @($Msgs | ForEach-Object { Msg $_ })
  [IO.File]::WriteAllBytes($p, $utf8.GetBytes(($lines -join $Nl) + $Nl))
  Set-Age $p 600
  $p
}
function Add-Msgs([string]$Path, [string[]]$Msgs, [string]$Nl = "`n") {
  $fs = [IO.File]::Open($Path, 'Append'); try { $b = $utf8.GetBytes((@($Msgs | ForEach-Object { Msg $_ }) -join $Nl) + $Nl); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
  Set-Age $Path 600
}
# mtimes are compared per second: tar keeps whole seconds
function Mt1([string]$p) { [long][Math]::Floor([IO.File]::GetLastWriteTimeUtc($p).Ticks / 1e7) }
function Read-Bytes([string]$p) { [IO.File]::ReadAllBytes($p) }
function Bytes-Eq([byte[]]$A, [byte[]]$B) { $A.Length -eq $B.Length -and [Convert]::ToBase64String($A) -eq [Convert]::ToBase64String($B) }
function Latin([string]$p) { [Text.Encoding]::GetEncoding(28591).GetString((Read-Bytes $p)) }

# ============================== pure functions ==============================
T 'encode: observed laptop names' {
  $h = 'C:\Users\conta'; $tmp = 'C:\Users\conta\AppData\Local\Temp'
  Eq (Get-OmpEncodedDir 'C:\Users\conta\Desktop\Project BD\deal-sync' $h $tmp) '-Desktop-Project BD-deal-sync'
  Eq (Get-OmpEncodedDir 'C:\Users\conta\Desktop\New folder\vps-scraper' $h $tmp) '-Desktop-New folder-vps-scraper'
  Eq (Get-OmpEncodedDir 'C:\Users\conta\Desktop\New folder (2)\Task' $h $tmp) '-Desktop-New folder (2)-Task'
  Eq (Get-OmpEncodedDir 'C:\Users\conta' $h $tmp) '-'
  Eq (Get-OmpEncodedDir 'c:\users\CONTA\Desktop\x' $h $tmp) '-Desktop-x' 'windows paths ignore case'
}
T 'encode: box path (not under home) and tmp rule' {
  Eq (Get-OmpEncodedDir '/data/workspace/deal-sync' '/data/home' '/tmp') '--data-workspace-deal-sync--'
  Eq (Get-OmpEncodedDir '/data/workspace/deal-sync/' '/data/home' '/tmp') '--data-workspace-deal-sync--' 'trailing slash'
  Eq (Get-OmpEncodedDir '/data/home/code/x' '/data/home' '/tmp') '-code-x'
  Eq (Get-OmpEncodedDir '/tmp/pc-it-run-1' '/data/home' '/tmp') '-tmp-pc-it-run-1'
  Eq (Get-OmpEncodedDir '/tmp' '/data/home' '/tmp') '-tmp'
  Eq (Get-OmpEncodedDir 'D:\work\p' 'C:\Users\conta' 'C:\Users\conta\AppData\Local\Temp') '--D--work-p--' 'other drive = absolute rule'
  Eq (Get-OmpEncodedDir 'C:\Users\conta\AppData\Local\Temp\x' 'C:\Users\conta' 'C:\Users\conta\AppData\Local\Temp') '-tmp-x' 'tmp wins over home'
}
T 'encode: python side gives the same names' {
  $drv = Join-Path $Root 'enc.py'
  [IO.File]::WriteAllText($drv, "import runpy,sys`nm=runpy.run_path(sys.argv[1], run_name='x')`nfor line in open(sys.argv[2]).read().splitlines():`n    p,h,t=line.split('|')`n    print(m['enc'](p,h,t))`n")
  $cases = @(
    @('C:\Users\conta\Desktop\Project BD\deal-sync', 'C:\Users\conta', 'C:\Users\conta\AppData\Local\Temp'),
    @('C:\Users\conta\Desktop\New folder (2)\Task', 'C:\Users\conta', 'C:\Users\conta\AppData\Local\Temp'),
    @('/data/workspace/deal-sync', '/data/home', '/tmp'), @('/data/home/code/x', '/data/home', '/tmp'),
    @('/tmp/pc-it-run-1', '/data/home', '/tmp'), @('/tmp', '/data/home', '/tmp'), @('C:\Users\conta', 'C:\Users\conta', 'C:\Users\conta\AppData\Local\Temp'),
    @('D:\work\p', 'C:\Users\conta', 'C:\Users\conta\AppData\Local\Temp'))
  $inp = Join-Path $Root 'enc-cases.txt'; [IO.File]::WriteAllText($inp, (($cases | ForEach-Object { $_ -join '|' }) -join "`n"))   # a file, not a pipe: Windows PowerShell 5.1 would put a BOM in front
  $got = @(python -I $drv $PyFile $inp)
  for ($i = 0; $i -lt $cases.Count; $i++) { Eq $got[$i] (Get-OmpEncodedDir $cases[$i][0] $cases[$i][1] $cases[$i][2]) ("case " + $cases[$i][0]) }
}
T 'cwd mapping' {
  Eq (Convert-OmpCwd 'C:\Users\conta\Desktop\p' 'C:\Users\conta\Desktop\p' '/data/workspace/p') '/data/workspace/p'
  Eq (Convert-OmpCwd 'C:\Users\conta\Desktop\p\sub\x y' 'C:\Users\conta\Desktop\p' '/data/workspace/p') '/data/workspace/p/sub/x y'
  Eq (Convert-OmpCwd 'c:\users\conta\desktop\P\a' 'C:\Users\conta\Desktop\p' '/data/workspace/p') '/data/workspace/p/a' 'case-insensitive on windows'
  Ok ($null -eq (Convert-OmpCwd 'C:\Users\conta\Desktop\p2' 'C:\Users\conta\Desktop\p' '/x')) 'sibling with common prefix must not map'
  Ok ($null -eq (Convert-OmpCwd '/other' 'C:\Users\conta\Desktop\p' '/x')) 'other style'
  Eq (Convert-OmpCwd '/data/workspace/p/sub' '/data/workspace/p' 'C:\Users\conta\Desktop\p') 'C:\Users\conta\Desktop\p\sub'
  Ok ($null -eq (Convert-OmpCwd '/data/workspace/P' '/data/workspace/p' 'C:\x')) 'posix is case-sensitive'
}
T 'header cwd rewrite: top + nested, other bytes identical, CRLF and LF kept' {
  foreach ($nl in "`n", "`r`n") {
    $src = Join-Path $Root ('rw' + $nl.Length); $dst = Join-Path $Root ('rwo' + $nl.Length)
    $top = New-Sess $src 'aaaa1111' 'C:\Users\conta\Desktop\p' @('m1', 'm2') 'Tiêu đề' $nl
    $nested = New-Sess (Join-Path $src 'x') 'bbbb2222' 'C:\Users\conta\Desktop\p\sub' @('n1') 'n' $nl
    $other = New-Sess (Join-Path $src 'y') 'cccc3333' 'C:\Elsewhere\q' @('n1') 'n' $nl
    foreach ($f in $top, $nested, $other) {
      $out = Join-Path $dst ($f.Substring($src.Length + 1))
      [void](Copy-OmpSession $f $out 'C:\Users\conta\Desktop\p' '/data/workspace/p')
      $a = Latin $f; $b = Latin $out
      if ($f -eq $other) { Eq $b $a 'unrelated cwd file must be byte-identical' }
      else {
        $mapped = if ($f -eq $top) { '/data/workspace/p' } else { '/data/workspace/p/sub' }
        $from = if ($f -eq $top) { 'C:\\Users\\conta\\Desktop\\p' } else { 'C:\\Users\\conta\\Desktop\\p\\sub' }
        Eq $b ($a.Replace('"cwd":"' + $from + '"', '"cwd":"' + $mapped + '"')) 'only the cwd value may change'
        Ok ($b -ne $a) 'cwd did change'
      }
      Eq ((Mt1 ($out))) ((Mt1 ($f))) 'mtime kept'
    }
  }
}
T 'header cwd rewrite: non-ascii path and other key order (box style)' {
  $d = Join-Path $Root 'rw-box'; [void](New-Item -ItemType Directory -Path $d)
  $p = Join-Path $d 's.jsonl'
  [IO.File]::WriteAllBytes($p, $utf8.GetBytes('{"type":"title","v":1,"title":"","pad":"  "}' + "`n" + '{"cwd":"/data/workspace/d\u1ef1 \"án\"","id":"i","timestamp":"t","type":"session","version":3}' + "`n" + (Msg 'a') + "`n"))
  $o = Join-Path $d 'o.jsonl'
  [void](Copy-OmpSession $p $o '/data/workspace/d\u1ef1 "án"'.Replace('\u1ef1', 'ự') 'C:\Users\conta\Desktop\ca')
  $t = $utf8.GetString((Read-Bytes $o))
  Ok ($t.Contains('"cwd":"C:\\Users\\conta\\Desktop\\ca"')) "got: $t"
}
T 'blob refs' {
  $d = Join-Path $Root 'blobs1'; [void](New-Item -ItemType Directory -Path $d)
  $h1 = 'a' * 64; $h2 = 'b' * 64; $h3 = '0123456789abcdef' * 4
  $f1 = Join-Path $d '1.jsonl'; $f2 = Join-Path $d '2.jsonl'
  [IO.File]::WriteAllText($f1, '{"x":"blob:sha256:' + $h1 + '"}' + "`n" + '{"y":["blob:sha256:' + $h2 + '","blob:sha256:' + $h1 + '","blob:sha256:short"]}' + "`n")
  [IO.File]::WriteAllText($f2, '{"z":"blob:sha256:' + $h3 + '"}' + "`n" + '{"w":"BLOB:SHA256:' + $h2 + '"}')
  Eq ((Get-OmpBlobRefs @($f1, $f2)) -join ',') (($h1, $h2, $h3 | Sort-Object) -join ',')
  $bd = Join-Path $Root 'blobdir'; [void](New-Item -ItemType Directory -Path $bd)
  foreach ($n in $h1, ($h2 + '.png'), ($h3 + '.webp'), 'junk.txt', ($h1.Substring(0, 63) + 'x')) { [IO.File]::WriteAllText((Join-Path $bd $n), 'x') }
  $ix = Get-OmpBlobIndex $bd
  Eq $ix.Count 3; Eq ($ix[$h2] -join ',') ($h2 + '.png')
}
T 'empty-session detection and body offset' {
  $d = Join-Path $Root 'ne'
  $e = New-Sess $d 'e0000000' '/x' @(); $m = New-Sess $d 'f1111111' '/x' @('a')
  Ok (-not (Test-OmpNonEmpty $e)) 'empty has no message'; Ok (Test-OmpNonEmpty $m) 'has message'
  $b = Read-Bytes $m; $text = [Text.Encoding]::GetEncoding(28591).GetString($b)
  Eq (Get-OmpBodyOff $m) $text.IndexOf('{"type":"message"') 'body starts at the line after the header'
}

# ============================== planner ==============================
function Get-Hashes($Plan, [string]$BoxDir, [string]$Enc) {
  $h = @{}
  foreach ($n in $Plan.Need) { $p = Join-Path $BoxDir ($n.rel -replace '/', '\'); $h[$n.key] = Get-RangeSha $p (Get-PhienOff $p) $n.len }
  $h
}
T 'planner: one side / same / prefix both ways / diverged / busy / empty / nested' {
  $L = Join-Path $Root 'pl\L'; $B = Join-Path $Root 'pl\B'
  # only laptop (non-empty) + only laptop (empty) + only box
  [void](New-Sess $L 'lonly001' 'C:\p' @('a')); [void](New-Sess $L 'lempty01' 'C:\p' @()); [void](New-Sess $B 'bonly001' '/d/p' @('a'))
  # same body, other header cwd/title
  [void](New-Sess $L 'same0001' 'C:\p' @('a', 'b') 'T1'); [void](New-Sess $B 'same0001' '/d/p' @('a', 'b') 'T2')
  # laptop longer / box longer
  $x = New-Sess $L 'lng00001' 'C:\p' @('a', 'b'); [void](New-Sess $B 'lng00001' '/d/p' @('a')); Add-Msgs $x @('c')
  [void](New-Sess $L 'bng00001' 'C:\p' @('a')); $y = New-Sess $B 'bng00001' '/d/p' @('a', 'b'); Add-Msgs $y @('c', 'd')
  # diverged
  [void](New-Sess $L 'div00001' 'C:\p' @('a', 'b')); [void](New-Sess $B 'div00001' '/d/p' @('a', 'zzz', 'q'))
  # busy (changed just now)
  $bz = New-Sess $L 'busy0001' 'C:\p' @('a'); [void](New-Sess $B 'busy0001' '/d/p' @('a', 'b')); [IO.File]::SetLastWriteTimeUtc($bz, [DateTime]::UtcNow)
  # nested: file only on box, file longer on box (laptop prefix), file only on laptop
  $nb = Join-Path $B ((Split-Path (Get-ChildItem $B -Filter '*same0001.jsonl').FullName -Leaf).Replace('.jsonl', ''))
  $nl = Join-Path $L ((Split-Path (Get-ChildItem $L -Filter '*same0001.jsonl').FullName -Leaf).Replace('.jsonl', ''))
  [void](New-Item -ItemType Directory -Path $nb, $nl -Force)
  [IO.File]::WriteAllText((Join-Path $nb 'only.log'), 'box only'); [IO.File]::WriteAllText((Join-Path $nb 'grow.log'), 'abcdef'); [IO.File]::WriteAllText((Join-Path $nl 'grow.log'), 'abc')
  [IO.File]::WriteAllText((Join-Path $nl 'lap.md'), 'laptop only')
  foreach ($f in (Get-ChildItem $nb, $nl -File)) { Set-Age $f.FullName 600 }
  $ls = Get-PhienLocalScan $L; $rs = Get-PhienLocalScan $B
  $n = ConvertTo-Epoch (Get-Date)
  $p1 = Get-PhienPlan $ls $rs 'ENC' @{} $L $n $n 30
  $p2 = Get-PhienPlan $ls $rs 'ENC' (Get-Hashes $p1 $B 'ENC') $L $n $n 30
  $put = @($p2.Put | ForEach-Object { $_.Id + ($(if ($_.Top) { '+top' } else { '' })) + ($(if ($_.Files.Count) { '[' + (($_.Files | ForEach-Object { Split-Path $_ -Leaf }) -join ',') + ']' } else { '' })) } | Sort-Object)
  $get = @($p2.Get | ForEach-Object { $_.Id + ($(if ($_.Top) { '+top' } else { '' })) + ($(if ($_.Files.Count) { '[' + (($_.Files | ForEach-Object { Split-Path $_ -Leaf }) -join ',') + ']' } else { '' })) } | Sort-Object)
  Eq ($put -join ' ') 'lng00001+top lonly001+top same0001[lap.md]' 'put'
  Eq ($get -join ' ') 'bng00001+top bonly001+top same0001[grow.log,only.log]' 'get'
  Ok (@($p2.Notes | Where-Object { $_ -like '*div00001*khác nhau*' }).Count -eq 1) 'diverged noted'
  Ok (@($p2.Notes | Where-Object { $_ -like '*busy0001*' }).Count -eq 1) 'busy noted'
  Eq $p2.Same 0 'same0001 has nested work so it is not counted as untouched'
}
T 'planner: second run with equal sides copies nothing' {
  $L = Join-Path $Root 'pl2\L'; $B = Join-Path $Root 'pl2\B'
  [void](New-Sess $L 'same0001' 'C:\p' @('a', 'b') 'T1'); [void](New-Sess $B 'same0001' '/d/p' @('a', 'b') 'T2')
  $n = ConvertTo-Epoch (Get-Date)
  $p = Get-PhienPlan (Get-PhienLocalScan $L) (Get-PhienLocalScan $B) 'E' @{} $L $n $n 30
  Eq $p.Put.Count 0; Eq $p.Get.Count 0; Eq $p.Need.Count 0; Eq $p.Same 1
}

T 'equal-length bodies: sha256 decides (other content = diverged, same content = same); same length + same mtime is not hashed' {
  $L = Join-Path $Root 'eq\L'; $B = Join-Path $Root 'eq\B'
  [void](New-Sess $L 'eq000001' 'C:\p' @('aaa')); $b1 = New-Sess $B 'eq000001' '/d/p' @('bbb'); Set-Age $b1 601      # same length, other content, other mtime
  [void](New-Sess $L 'eq000002' 'C:\p' @('ccc')); $b2 = New-Sess $B 'eq000002' '/d/p' @('ccc'); Set-Age $b2 700      # same content, other mtime
  [void](New-Sess $L 'eq000003' 'C:\p' @('xxx')); [void](New-Sess $B 'eq000003' '/d/p' @('yyy'))                    # same length, same mtime: shortcut
  $n = ConvertTo-Epoch (Get-Date)
  $p1 = Get-PhienPlan (Get-PhienLocalScan $L) (Get-PhienLocalScan $B) 'E' @{} $L $n $n 30
  Eq $p1.Need.Count 2 'only the two pairs with different mtimes are hashed'
  $p2 = Get-PhienPlan (Get-PhienLocalScan $L) (Get-PhienLocalScan $B) 'E' (Get-Hashes $p1 $B 'E') $L $n $n 30
  Eq $p2.Diverged 1; Ok (@($p2.Notes | Where-Object { $_ -like '*eq000001*khác nhau*' }).Count -eq 1) 'diverged is reported'
  Eq ($p2.Put.Count + $p2.Get.Count) 0 'nothing is copied either way'
  Eq $p2.Same 2 'eq000002 (same hash) and eq000003 (shortcut)'
}
# ============================== omp format guard ==============================
function New-RawSess([string]$Dir, [string]$Name, [string[]]$Lines) {
  [void](New-Item -ItemType Directory -Path $Dir -Force)
  $p = Join-Path $Dir $Name
  [IO.File]::WriteAllBytes($p, $utf8.GetBytes(($Lines -join "`n") + "`n")); Set-Age $p 600; $p
}
T 'format guard: header version reader' {
  $d = Join-Path $Root 'fg1'
  $m = Msg 'a'
  Eq (Get-OmpHeaderVersion (New-Sess $d 'v3000000' '/x' @('a'))) 3
  Eq (Get-OmpHeaderVersion (New-RawSess $d 'v4.jsonl' @('{"type":"title","v":1}', '{"type":"session","version":4,"id":"i","cwd":"/x"}', $m))) 4
  Ok ($null -eq (Get-OmpHeaderVersion (New-RawSess $d 'nov.jsonl' @('{"type":"title","v":1}', '{"type":"session","id":"i","cwd":"/x"}', $m)))) 'no version field'
  Ok ($null -eq (Get-OmpHeaderVersion (New-RawSess $d 'str.jsonl' @('{"type":"session","version":"3","id":"i"}', $m)))) 'version as a string is not accepted'
  Ok ($null -eq (Get-OmpHeaderVersion (New-RawSess $d 'nohdr.jsonl' @('{"type":"title","v":1}', $m)))) 'no header at all'
  Ok ($null -eq (Get-OmpHeaderVersion (New-RawSess $d 'bad.jsonl' @('{"type":"title","v":1}', '{"type":"session","version":3,"cwd":', $m)))) 'unparseable header'
  Ok (Test-PhienKnownVersion 3) 'known'; Ok (-not (Test-PhienKnownVersion 4)) 'unknown'; Ok (-not (Test-PhienKnownVersion $null)) 'missing'
}
T 'format guard: planner never copies unknown / missing / unparseable headers and reports them' {
  $L = Join-Path $Root 'fg2\L'; $B = Join-Path $Root 'fg2\B'
  [void](New-RawSess $L '2026_aaaa0001.jsonl' @('{"type":"title","v":1}', '{"type":"session","version":4,"id":"aaaa0001","cwd":"C:\\p"}', (Msg 'a')))         # laptop only, version 4
  [void](New-RawSess $B '2026_bbbb0002.jsonl' @('{"type":"title","v":1}', (Msg 'a')))                                                                                  # box only, no header
  [void](New-Sess $L 'cccc0003' 'C:\p' @('a')); [void](New-RawSess $B '2026-10-25T16-18-25-246Z_cccc0003.jsonl' @('{"type":"session","version":9,"id":"cccc0003","cwd":"/d/p"}', (Msg 'a'), (Msg 'b')))  # both, box unknown
  [void](New-Sess $L 'dddd0004' 'C:\p' @('a')); [void](New-Sess $B 'eeee0005' '/d/p' @('a'))                                                                           # known: laptop-only + box-only
  # known top, nested jsonl with unknown header
  $top = New-Sess $L 'ffff0006' 'C:\p' @('a'); $nd = Join-Path $L ((Split-Path $top -Leaf).Replace('.jsonl', '') + '\x')
  [void](New-RawSess $nd 'n.jsonl' @('{"type":"session","version":5,"id":"n","cwd":"C:\\p"}', (Msg 'a')))
  $n = ConvertTo-Epoch (Get-Date)
  $p = Get-PhienPlan (Get-PhienLocalScan $L) (Get-PhienLocalScan $B) 'E' @{} $L $n $n 30
  $p = Get-PhienPlan (Get-PhienLocalScan $L) (Get-PhienLocalScan $B) 'E' @{} $L $n $n 30
  Eq ((@($p.Put | ForEach-Object { $_.Id }) | Sort-Object) -join ',') 'dddd0004' 'only the known laptop session is sent'
  Eq ((@($p.Get | ForEach-Object { $_.Id }) | Sort-Object) -join ',') 'eeee0005' 'only the known box session is fetched'
  Eq ((@($p.Unknown | ForEach-Object { $_.Id }) | Sort-Object) -join ',') 'aaaa0001,bbbb0002,cccc0003,ffff0006' 'unknown ids'
  Eq ((@($p.Unknown | ForEach-Object { "$($_.Ver)" }) | Sort-Object) -join ',') ',4,5,9' 'versions reported (missing = empty)'
  Eq (Get-PhienUnknownNote $p.Unknown) 'omp đổi định dạng phiên (version ?, 4, 5, 9) — chưa đồng bộ, báo Claude'
}
T 'format guard: version note' {
  Eq (Get-PhienVersionNote '18.12.6' '18.12.7') 'omp laptop 18.12.6 khác box 18.12.7'
  Ok ($null -eq (Get-PhienVersionNote '18.12.6' '18.12.6')) 'same'
  Ok ($null -eq (Get-PhienVersionNote '18.12.6' '')) 'unknown side is no difference'
}
# ============================== project notes (HANDOFF*.md, CLAUDE.md, ...) ==============================
function Nt([string]$Name, [string]$Sha, [double]$Age = 600, [bool]$Ign = $true, [switch]$Fx) { [pscustomobject]@{ name = $Name; size = 1; mtime = ((ConvertTo-Epoch (Get-Date)) - $Age); sha = $Sha; ign = $Ign; fx = [bool]$Fx } }
function NS($Files, $Tracked = @(), [bool]$GitOk = $true, $Upstream = @()) { [pscustomobject]@{ gitok = $GitOk; tracked = @($Tracked); upstream = @($Upstream); files = @($Files) } }
T 'notes: name list' {
  $rx = Get-PhienNoteRx
  foreach ($n in 'HANDOFF.md', 'HANDOFF-mobile-1.md', 'HANDOFFnotes.md', 'CLAUDE.md', 'AGENTS.md', 'WORKFLOW.md', 'agent_state.md', 'TASK.md', 'CLAUDE.local.md', 'HANDOFF-ghi chú.md') { Ok ($n -cmatch $rx) "$n should match" }
  foreach ($n in 'handoff.md', 'HANDOFF.txt', 'claude.md', 'CLAUDE.md.bak', 'README.md', 'TASK.md.part', 'sub/CLAUDE.md', 'HANDOFF/x.md', 'AGENT_STATE.md') { Ok ($n -cnotmatch $rx) "$n should NOT match" }
}
T 'notes planner: copy, record, overwrite rule, conflicts, tracked, busy, git missing' {
  $now = ConvertTo-Epoch (Get-Date)
  $p = Get-PhienNotePlan 'proj' (NS @((Nt 'A.md' 'a1'))) (NS @()) @{} $now $now   # file names are not filtered by the planner itself
  Eq (@($p.Put | ForEach-Object { $_.Name }) -join ',') 'A.md'; Eq $p.Put[0].Expect ''; Eq $p.Put[0].Sha 'a1'
  $p = Get-PhienNotePlan 'proj' (NS @()) (NS @((Nt 'B.md' 'b1'))) @{} $now $now
  Eq (@($p.Get | ForEach-Object { $_.Name }) -join ',') 'B.md'
  # equal -> record only (first run), ensure on the box when git does not ignore it yet
  $p = Get-PhienNotePlan 'proj' (NS @((Nt 'C.md' 'c1'))) (NS @((Nt 'C.md' 'c1' 600 $false))) @{} $now $now
  Eq $p.Put.Count 0; Eq $p.Get.Count 0; Eq $p.Record['proj/C.md'] 'c1'; Eq ($p.Ensure -join ',') 'C.md'
  $p = Get-PhienNotePlan 'proj' (NS @((Nt 'C.md' 'c1'))) (NS @((Nt 'C.md' 'c1' 600 $true))) @{} $now $now
  Eq $p.Ensure.Count 0 'already ignored on the box: nothing to ensure'
  # differ: only the laptop changed since the record -> put; only the box changed -> get; both / no record -> conflict
  $L = NS @((Nt 'D.md' 'new-l')); $R = NS @((Nt 'D.md' 'old'))
  $p = Get-PhienNotePlan 'proj' $L $R @{ 'proj/D.md' = 'old' } $now $now; Eq ($p.Put | ForEach-Object { $_.Name }) 'D.md'; Eq $p.Put[0].Expect 'old'; Eq $p.Put[0].Sha 'new-l'
  $L = NS @((Nt 'D.md' 'old')); $R = NS @((Nt 'D.md' 'new-r'))
  $p = Get-PhienNotePlan 'proj' $L $R @{ 'proj/D.md' = 'old' } $now $now; Eq ($p.Get | ForEach-Object { $_.Name }) 'D.md'; Eq $p.Get[0].Expect 'old'
  $L = NS @((Nt 'D.md' 'x')); $R = NS @((Nt 'D.md' 'y'))
  $p = Get-PhienNotePlan 'proj' $L $R @{ 'proj/D.md' = 'old' } $now $now; Eq $p.Conflicts.Count 1 'both changed'; Eq $p.Put.Count 0; Eq $p.Get.Count 0
  $p = Get-PhienNotePlan 'proj' $L $R @{} $now $now; Eq ($p.Conflicts -join ',') 'proj/D.md' 'no record and different'
  # tracked on either side: never synced (travels through git)
  $p = Get-PhienNotePlan 'proj' (NS @((Nt 'E.md' 'e1')) @('E.md')) (NS @()) @{} $now $now; Eq ($p.Put.Count + $p.Get.Count) 0 'tracked on the laptop'
  $p = Get-PhienNotePlan 'proj' (NS @((Nt 'E.md' 'e1'))) (NS @() @('E.md')) @{} $now $now; Eq ($p.Put.Count + $p.Get.Count) 0 'tracked (even if deleted from the work tree) on the box'
  # busy source
  $p = Get-PhienNotePlan 'proj' (NS @((Nt 'F.md' 'f1' 5))) (NS @()) @{} $now $now; Eq $p.Put.Count 0 'being written'
  # not a git repo on one side
  $p = Get-PhienNotePlan 'proj' (NS @((Nt 'G.md' 'g1')) @() $false) (NS @()) @{} $now $now; Eq ($p.Put.Count + $p.Get.Count) 0
}
function New-GitDir([string]$Dir) { $ErrorActionPreference = 'Continue'; [void](New-Item -ItemType Directory -Path $Dir -Force); & git -C $Dir init -q 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'git init' } }
function Git-Commit([string]$Dir, [string[]]$Files) { $ErrorActionPreference = 'Continue'; & git -C $Dir -c core.autocrlf=false add -- @Files 2>&1 | Out-Null; & git -C $Dir -c user.name=t -c user.email=t@t commit -q -m x 2>&1 | Out-Null }
function Put-File([string]$Path, [string]$Text, [int]$Age = 600) { [void][IO.Directory]::CreateDirectory((Split-Path $Path)); [IO.File]::WriteAllText($Path, $Text, $utf8); Set-Age $Path $Age }
T 'notes: local scan sees untracked/ignored root notes only, tracked names are listed' {
  $d = Join-Path $Root 'nt1'; New-GitDir $d
  Put-File "$d\HANDOFF-x.md" 'h'; Put-File "$d\CLAUDE.md" 'tracked'; Put-File "$d\TASK.md" 't'; Put-File "$d\README.md" 'r'; Put-File "$d\.gitignore" "TASK.md`n"
  [void](New-Item -ItemType Directory -Path "$d\sub"); Put-File "$d\sub\AGENTS.md" 'sub'
  Git-Commit $d @('CLAUDE.md', '.gitignore', 'README.md')
  $n = Get-PhienLocalNotes $d
  Eq $n.gitok $true; Eq ($n.tracked -join ',') 'CLAUDE.md'
  Eq ((@($n.files | ForEach-Object { $_.name }) | Sort-Object) -join ',') 'CLAUDE.md,HANDOFF-x.md,TASK.md' 'root only, no README, no sub/'
  Eq (@($n.files | Where-Object name -eq 'TASK.md')[0].ign) $true 'gitignored'; Eq (@($n.files | Where-Object name -eq 'HANDOFF-x.md')[0].ign) $false 'plain untracked'
  Eq (@($n.files | Where-Object name -eq 'HANDOFF-x.md')[0].sha) ((Get-FileHash "$d\HANDOFF-x.md" -Algorithm SHA256).Hash.ToLowerInvariant()) 'sha256'
  $x = Join-Path $Root 'nt-nogit'; [void](New-Item -ItemType Directory $x); Put-File "$x\TASK.md" 't'
  Eq (Get-PhienLocalNotes $x).gitok $false
}
T 'notes: exclude goes to .git/info/exclude (never .gitignore), once, only when git does not already ignore the file' {
  $d = Join-Path $Root 'nt2'; New-GitDir $d
  Put-File "$d\HANDOFF-a.md" 'a'; Put-File "$d\TASK.md" 't'; Put-File "$d\.gitignore" "TASK.md`n"
  $gi = Get-Content "$d\.gitignore" -Raw
  Add-PhienNoteExclude $d 'HANDOFF-a.md'; Add-PhienNoteExclude $d 'HANDOFF-a.md'; Add-PhienNoteExclude $d 'TASK.md'
  $ex = Get-Content "$d\.git\info\exclude" -Raw
  Eq (([regex]::Matches($ex, '(?m)^/HANDOFF-a\.md$')).Count) 1 'added exactly once'
  Ok ($ex -notmatch 'TASK\.md') 'already ignored by .gitignore: not added'
  Eq (Get-Content "$d\.gitignore" -Raw) $gi '.gitignore untouched'
  Ok (((& git -C $d status --porcelain | Out-String)) -notmatch 'HANDOFF-a') 'no longer shows in git status'
  # exclude file without trailing newline
  Add-PhienNoteExclude $d 'HANDOFF-b.md'; Put-File "$d\HANDOFF-b.md" 'b'; [IO.File]::WriteAllText("$d\.git\info\exclude", ((Get-Content "$d\.git\info\exclude" -Raw).TrimEnd("`r", "`n")))
  Add-PhienNoteExclude $d 'HANDOFF-c.md'
  Ok ((Get-Content "$d\.git\info\exclude" -Raw) -match "(?m)^/HANDOFF-b\.md\r?\n# fcode\r?\n/HANDOFF-c\.md") 'new pair started after a file without final newline'
  Ok ((Get-Content "$d\.git\info\exclude" -Raw) -match "(?m)^# fcode\r?\n/HANDOFF-a\.md\r?$") 'each line fcode adds has the # fcode marker right above it'
}
T 'notes: install refuses when the target changed, is busy or is tracked' {
  $d = Join-Path $Root 'nt3'; New-GitDir $d; $src = Join-Path $Root 'nt3-src.md'; Put-File $src 'from box'
  $n = ConvertTo-Epoch (Get-Date)
  Eq (Install-PhienNote $src $d 'HANDOFF-i.md' '' $n) 'ok'; Eq (Get-Content "$d\HANDOFF-i.md" -Raw) 'from box'
  Eq (Mt1 "$d\HANDOFF-i.md") (Mt1 $src) 'mtime kept'
  $sha = (Get-FileHash "$d\HANDOFF-i.md" -Algorithm SHA256).Hash.ToLowerInvariant()
  Set-Age "$d\HANDOFF-i.md" 600
  Eq (Install-PhienNote $src $d 'HANDOFF-i.md' 'not-the-current-sha' $n) 'changed'
  Eq (Install-PhienNote $src $d 'HANDOFF-i.md' $sha $n) 'ok' 'expected sha matches -> replaced'
  Eq (Install-PhienNote $src $d 'HANDOFF-j.md' $sha $n) 'changed' 'expected a file that is not there'
  [IO.File]::SetLastWriteTimeUtc("$d\HANDOFF-i.md", [DateTime]::UtcNow)
  Eq (Install-PhienNote $src $d 'HANDOFF-i.md' $sha $n) 'busy'
  Put-File "$d\CLAUDE.md" 'tracked'; Git-Commit $d @('CLAUDE.md')
  Eq (Install-PhienNote $src $d 'CLAUDE.md' '' $n) 'tracked'
  Ok (-not (Get-ChildItem $d -Filter '*.fcode-part*' -Force)) 'no part files'
}
T 'batches: <= 50 MB per tar stream, a bigger single item gets its own batch' {
  $bs = New-Object System.Collections.ArrayList
  foreach ($mb in 30, 30, 10, 60, 1, 49, 2) { $b = Get-PhienBatch $bs 'R' ([long]$mb * 1MB); [void]$b.Items.Add($mb) }
  Eq (($bs | ForEach-Object { ($_.Items -join '+') }) -join ' | ') '30 | 30+10 | 60 | 1+49 | 2' 'grouping'
  Ok (@($bs | Where-Object { $_.Bytes -gt 50MB -and $_.Items.Count -gt 1 }).Count -eq 0) 'only a lone item may pass 50 MB'
  Eq (($bs | ForEach-Object { $_.Dir }) -join ',') 'R\put0,R\put1,R\put2,R\put3,R\put4' 'own dir per batch'
  $z = New-Object System.Collections.ArrayList; $b0 = Get-PhienBatch $z 'R' 0; Eq $z.Count 1 'a zero-size add still gives a batch (notes ensure / unexclude)'
}
T 'notes planner: release when git starts tracking a name that fcode placed and excluded on the other side' {
  $now = ConvertTo-Epoch (Get-Date)
  # tracked on the laptop now, the box copy was placed by fcode (marker) -> release on the box
  $p = Get-PhienNotePlan 'proj' (NS @((Nt 'A.md' 'a1')) @('A.md')) (NS @((Nt 'A.md' 'a1'))) @{ 'exclude:box:proj/A.md' = '1'; 'proj/A.md' = 'a1' } $now $now
  Eq (($p.Release | ForEach-Object { "$($_.Name):$($_.TrackedOn):$($_.OldOn):$($_.Legacy)" }) -join ',') 'A.md:laptop:box:True' 'a 1.3.2/1.3.3 record: legacy'; Eq ($p.Put.Count + $p.Get.Count) 0 'and it is not synced any more'
  # tracked on the box, the laptop copy came from the box (marker) -> release on the laptop
  $p = Get-PhienNotePlan 'proj' (NS @((Nt 'B.md' 'b1'))) (NS @((Nt 'B.md' 'b1')) @('B.md')) @{ 'exclude:laptop:proj/B.md' = '1' } $now $now
  Eq (($p.Release | ForEach-Object { "$($_.Name):$($_.TrackedOn):$($_.OldOn):$($_.Legacy)" }) -join ',') 'B.md:box:laptop:True'
  # r6: the "# fcode" pair on that side (fx) is the ownership: a release without any record, not legacy
  $p = Get-PhienNotePlan 'proj' (NS @((Nt 'F.md' 'f1')) @('F.md')) (NS @((Nt 'F.md' 'f1' -Fx))) @{} $now $now
  Eq (($p.Release | ForEach-Object { "$($_.Name):$($_.TrackedOn):$($_.OldOn):$($_.Legacy)" }) -join ',') 'F.md:laptop:box:False' 'box pair'
  $p = Get-PhienNotePlan 'proj' (NS @((Nt 'G.md' 'g1' -Fx))) (NS @((Nt 'G.md' 'g1')) @('G.md')) @{} $now $now
  Eq (($p.Release | ForEach-Object { "$($_.Name):$($_.TrackedOn):$($_.OldOn):$($_.Legacy)" }) -join ',') 'G.md:box:laptop:False' 'laptop pair'
  $p = Get-PhienNotePlan 'proj' (NS @((Nt 'H.md' 'h1' -Fx)) @('H.md')) (NS @((Nt 'H.md' 'h1'))) @{} $now $now; Eq $p.Release.Count 0 'a pair on the side that tracks it releases nothing'
  # no marker = the exclude line was not ours (or git ignored it already): nothing to give back
  $p = Get-PhienNotePlan 'proj' (NS @((Nt 'C.md' 'c1')) @('C.md')) (NS @((Nt 'C.md' 'c1'))) @{} $now $now; Eq $p.Release.Count 0
  # marker for the other side only, or tracked on both sides: nothing
  $p = Get-PhienNotePlan 'proj' (NS @((Nt 'D.md' 'd1')) @('D.md')) (NS @((Nt 'D.md' 'd1'))) @{ 'exclude:laptop:proj/D.md' = '1' } $now $now; Eq $p.Release.Count 0
  $p = Get-PhienNotePlan 'proj' (NS @((Nt 'E.md' 'e1')) @('E.md')) (NS @((Nt 'E.md' 'e1')) @('E.md')) @{ 'exclude:box:proj/E.md' = '1' } $now $now; Eq $p.Release.Count 0
}
T 'notes: Add returns true only when it added the line; Remove takes out only that exact line' {
  $d = Join-Path $Root 'nt5'; New-GitDir $d; Put-File "$d\HANDOFF-a.md" 'a'; Put-File "$d\HANDOFF-ab.md" 'ab'
  $ex = "$d\.git\info\exclude"
  [IO.File]::WriteAllText($ex, "# my own comment`n/HANDOFF-ab.md`n/other.txt`n")
  Eq (Add-PhienNoteExclude $d 'HANDOFF-a.md') $true; Eq (Add-PhienNoteExclude $d 'HANDOFF-a.md') $false 'second time: already ignored'
  Eq (Add-PhienNoteExclude $d 'HANDOFF-ab.md') $false 'a pre-existing line is not ours'
  Ok ((Read-Bytes $ex).Length -gt 0 -and (Latin $ex) -match '(?m)^# fcode\n/HANDOFF-a\.md\n' -and (Latin $ex) -notmatch '# fcode\n/HANDOFF-ab') 'the pair for ours, no marker above the user''s line'
  Eq (Remove-PhienNoteExclude $ex 'HANDOFF-a.md' $false) 'removed'
  $t = Get-Content $ex -Raw
  Ok ($t -notmatch '(?m)^/HANDOFF-a\.md\r?$' -and $t -notmatch '# fcode') 'our pair is gone'
  Ok ($t -match '(?m)^/HANDOFF-ab\.md\r?$' -and $t -match '(?m)^/other\.txt\r?$' -and $t -match '# my own comment') 'every other line stays (also the one with the same prefix)'
  Eq (Remove-PhienNoteExclude $ex 'HANDOFF-a.md' $false) 'absent' 'nothing left to remove: confirmed absent'
  Ok (Bytes-Eq (Read-Bytes $ex) $utf8.GetBytes("# my own comment`n/HANDOFF-ab.md`n/other.txt`n")) 'the three user rules survive our add + remove byte for byte'
  Eq @(Get-ChildItem "$d\.git\info" -Force -Filter '*.part-*').Count 0 'no part file left'
}
# r4 F2: fcode never writes .git/info/exclude through a link (junction / symlink of the file or of its folder)
function New-InfoJunction([string]$Dir, [string]$Target, [string]$Text) {
  [void](New-Item -ItemType Directory -Path $Target -Force); [IO.File]::WriteAllText((Join-Path $Target 'exclude'), $Text)
  Remove-Item -LiteralPath "$Dir\.git\info" -Recurse -Force
  [void](New-Item -ItemType Junction -Path "$Dir\.git\info" -Target $Target)
}
T 'notes r4: a junction .git/info: Get-PhienExcludeFile gives $null (the note is not placed), the exclude file is never written' {
  $d = Join-Path $Root 'nt6'; New-GitDir $d; Put-File "$d\HANDOFF-x.md" 'x'
  New-InfoJunction $d (Join-Path $Root 'nt6-elsewhere') "# user`n"
  Eq $null (Get-PhienExcludeFile $d 'HANDOFF-x.md') 'link: no exclude file to write'
  Eq (Get-Content (Join-Path $Root 'nt6-elsewhere\exclude') -Raw) "# user`n" 'the target is untouched'
}
T 'notes r4: Remove-PhienNoteExclude through a junction .git/info: failed (not absent), the target bytes unchanged, the junction intact; no path = failed; no exclude file = absent' {
  $d = Join-Path $Root 'nt7'; New-GitDir $d; $tg = Join-Path $Root 'nt7-elsewhere'
  $txt = "# user rules`n# fcode`n/HANDOFF-z.md`n*.log`n"
  New-InfoJunction $d $tg $txt
  Eq (Remove-PhienNoteExclude "$d\.git\info\exclude" 'HANDOFF-z.md' $true) 'failed' 'nothing removed through a link, and that is a failure'
  Ok (Bytes-Eq (Read-Bytes (Join-Path $tg 'exclude')) $utf8.GetBytes($txt)) 'target bytes unchanged'
  Ok ((Get-Item -LiteralPath "$d\.git\info" -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) 'the junction is still a junction'
  Eq (Remove-PhienNoteExclude '' 'HANDOFF-z.md' $true) 'failed' 'the scan had no path: failed'
  $d2 = Join-Path $Root 'nt7b'; New-GitDir $d2; Remove-Item "$d2\.git\info\exclude"; Eq (Remove-PhienNoteExclude "$d2\.git\info\exclude" 'HANDOFF-z.md' $false) 'absent' 'no exclude file: absent'
}
# r6 T9: a bare "/<name>" without the marker is the user's; it goes only when a 1.3.2/1.3.3 record asks (legacy), on both machines
T 'nhanh r6: the legacy flag: a bare line goes only with it; the pair goes either way (laptop and box)' {
  $f = Join-Path $Root 't9\exclude'; $user = "# mine`n/HANDOFF.md`n/keep`n"
  Put-File $f $user
  Eq (Remove-PhienNoteExclude $f 'HANDOFF.md' $false) 'absent' 'laptop: the user''s bare line without the flag'; Ok (Bytes-Eq (Read-Bytes $f) $utf8.GetBytes($user)) 'laptop: bytes unchanged'
  Eq (Remove-PhienNoteExclude $f 'HANDOFF.md' $true) 'removed' 'laptop: with the flag'; Eq ([IO.File]::ReadAllText($f)) "# mine`n/keep`n" 'laptop: only the bare line went'
  Put-File $f "# mine`n/HANDOFF.md`n# fcode`n/HANDOFF.md`n/keep`n"
  Eq (Remove-PhienNoteExclude $f 'HANDOFF.md' $false) 'removed' 'laptop: the pair without the flag'; Eq ([IO.File]::ReadAllText($f)) $user 'laptop: only the pair went'
  $bd = Join-Path $Root 't9box'; New-GitDir $bd; $bf = "$bd\.git\info\exclude"
  $drv = Join-Path $Root 't9.py'
  [IO.File]::WriteAllText($drv, ("import runpy, sys`nm = runpy.run_path(sys.argv[1], run_name='x')`nd, p = sys.argv[2], sys.argv[3]`n" +
    "def put(b):`n    open(p, 'wb').write(b)`ndef get():`n    return open(p, 'rb').read()`n" +
    "u = b'# mine\n/HANDOFF.md\n/keep\n'`nput(u)`nprint(m['unexclude'](d, 'HANDOFF.md', False), get() == u)`n" +
    "print(m['unexclude'](d, 'HANDOFF.md', True), get() == b'# mine\n/keep\n')`n" +
    "put(b'# mine\n/HANDOFF.md\n# fcode\n/HANDOFF.md\n/keep\n')`nprint(m['unexclude'](d, 'HANDOFF.md', False), get() == u)`n"))
  $out = @(python -I $drv $PyFile $bd $bf)
  Eq ($out -join ',') 'True True,True True,True True' 'box: no flag = nothing touched (still True: nothing of fcode''s there); flag = bare line gone; the pair goes without it'
}
# r6 L5: handoff-state.json is read strictly: missing = empty; not one JSON object = stop (PowerShell 7 unwraps a one-item array: the raw text must start with {)
T 'nhanh r6: Read-PhienNoteState: missing = empty, an object is read, anything else throws the state-file error' {
  $sl = $env:LOCALAPPDATA; $env:LOCALAPPDATA = Join-Path $Root 'l5'
  try {
    Eq (Read-PhienNoteState).Count 0 'no file: empty state'
    Put-File (Get-PhienNoteStatePath) '{"proj/A.md":"a1","exclude:laptop:proj/B.md":"1"}'
    $s = Read-PhienNoteState; Eq $s['proj/A.md'] 'a1'; Eq $s['exclude:laptop:proj/B.md'] '1'
    foreach ($bad in '{', '42', 'null', '', '[{}]', '[{"exclude:laptop:proj/HANDOFF.md":"1"}]', ' [ {"a":"1"} ] ') {
      Put-File (Get-PhienNoteStatePath) $bad
      $msg = $null; try { [void](Read-PhienNoteState) } catch { $msg = $_.Exception.Message }
      Ok ($msg -match '^không đọc được trạng thái ghi chú \(handoff-state\.json\): ') "refused [$bad]: $msg"
    }
  } finally { $env:LOCALAPPDATA = $sl }
}
# r4 F1: every rewrite of a file goes through Write-PhienText (part file + atomic Replace / Move); the log is appended
T 'files r4: outside Write-PhienText, the config / profile writers and the staging manifest, fcode.ps1 has no WriteAllText( / AppendAllText( / Set-Content' {
  $src = [IO.File]::ReadAllText($Fcode)
  $ok = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'Write-PhienText', 'Add-SyncRepoConfig', 'Set-MocProfile' }, $true) | ForEach-Object { , @($_.Extent.StartOffset, $_.Extent.EndOffset) })
  Eq $ok.Count 3 'the three allowed writers exist'
  $bad = @()
  foreach ($m in [regex]::Matches($src, 'WriteAllText\(|AppendAllText\(|Set-Content')) {
    if (@($ok | Where-Object { $m.Index -ge $_[0] -and $m.Index -lt $_[1] }).Count) { continue }
    $ls = $src.LastIndexOf("`n", $m.Index) + 1; $le = $src.IndexOf("`n", $m.Index); $line = $src.Substring($ls, $le - $ls)
    if ($line -match "Join-Path \`$pb\.Dir 'manifest\.json'") { continue }   # the staging manifest: a temp file of this run only
    $bad += $line.Trim()
  }
  Eq $bad.Count 0 ('in-place writes: ' + ($bad -join ' || '))
}
T 'files r4: Write-PhienText writes UTF-8 without BOM, replaces an existing file, leaves no part file' {
  $p = Join-Path $Root 'wpt\sub\x.json'
  Write-PhienText $p 'một'; Ok (Bytes-Eq (Read-Bytes $p) $utf8.GetBytes('một')) 'new file, no BOM'
  Write-PhienText $p 'hai'; Eq ([IO.File]::ReadAllText($p)) 'hai' 'replaced'
  Eq @(Get-ChildItem (Split-Path $p) -Force -Filter '*.part-*').Count 0 'no part file'
}
T 'log r4: above 200 KB phien.log is renamed to phien.log.1 (the older log) and the new line starts a new phien.log; a second rotation replaces .1' {
  $saved = $PhienLog; $script:PhienLog = Join-Path $Root 'rot\phien.log'
  try {
    [void](New-Item -ItemType Directory -Path (Split-Path $PhienLog) -Force)
    $big1 = [byte[]]($utf8.GetBytes(('a' * 99) + "`n") * 2100)   # 210 000 bytes
    [IO.File]::WriteAllBytes($PhienLog, $big1)
    Add-PhienLog @('dòng mới')
    Ok (Bytes-Eq (Read-Bytes "$PhienLog.1") $big1) '.1 holds the old content, whole'
    $t = @(Get-Content $PhienLog -Encoding UTF8); Eq $t.Count 1 'phien.log holds only the new line'; Ok ($t[0] -match 'dòng mới$') $t[0]
    $big2 = [byte[]]($utf8.GetBytes(('b' * 99) + "`n") * 2100)
    [IO.File]::WriteAllBytes($PhienLog, $big2)
    Add-PhienLog @('dòng ba')
    Ok (Bytes-Eq (Read-Bytes "$PhienLog.1") $big2) 'a second rotation replaces .1'
    Eq @(Get-Content $PhienLog -Encoding UTF8).Count 1 'and phien.log starts again'
    Add-PhienLog @('dòng bốn'); Eq @(Get-Content $PhienLog -Encoding UTF8).Count 2 'below 200 KB: plain append'
  } finally { $script:PhienLog = $saved }
}
T 'log r4: a quick or auto run writes each line to phien.log at once (Write-PhienOut does not buffer)' {
  $saved = $PhienLog; $script:PhienLog = Join-Path $Root 'inc\phien.log'
  try {
    $script:PhienQuick = $true
    Write-PhienOut 'dòng một'
    Ok ((Test-Path $PhienLog) -and (Get-Content $PhienLog -Raw -Encoding UTF8) -match 'dòng một') 'the line is in the file right after Write-PhienOut'
    Write-PhienOut 'dòng hai'; Eq @(Get-Content $PhienLog -Encoding UTF8).Count 2 'and the next one'
  } finally { $script:PhienQuick = $false; $script:PhienLog = $saved }
}
function Grow-Sess([string]$Path, [int]$MB) {
  $line = $utf8.GetBytes('{"type":"message","id":"pad","parentId":null,"timestamp":"2026-10-25T16:18:29.000Z","message":{"role":"user","content":"' + ('x' * 100000) + '"}}' + "`n")
  $fs = [IO.File]::Open($Path, 'Append'); try { for ($i = 0; $i -lt $MB * 10; $i++) { $fs.Write($line, 0, $line.Length) } } finally { $fs.Dispose() }
  Set-Age $Path 600
}
# ============================== install (place) rules ==============================
T 'install: new / same / replaced (only when target is a prefix) / skip / busy; no overwrite of diverged' {
  $S = Join-Path $Root 'in\S'; $D = Join-Path $Root 'in\D'
  $a = New-Sess $S 'inn00001' '/d/p' @('a', 'b')
  $dst = Join-Path $D (Split-Path $a -Leaf)
  Eq (Install-PhienFile $a $dst '/d/p' 'C:\Users\conta\Desktop\p' $Now) 'new'
  Ok ((Latin $dst).Contains('"cwd":"C:\\Users\\conta\\Desktop\\p"')) 'cwd rewritten on install'
  Set-Age $dst 600
  Eq (Install-PhienFile $a $dst '/d/p' 'C:\Users\conta\Desktop\p' $Now) 'same'
  Add-Msgs $a @('c')
  Eq (Install-PhienFile $a $dst '/d/p' 'C:\Users\conta\Desktop\p' $Now) 'replaced'
  Ok ((Latin $dst).Contains('"cwd":"C:\\Users\\conta\\Desktop\\p"')) 'replaced keeps rewritten cwd'
  Eq (Read-Bytes $dst).Length ((Read-Bytes $a).Length + 'C:\\Users\\conta\\Desktop\\p'.Length - '/d/p'.Length) 'length = source + cwd delta'
  Set-Age $dst 600
  # target diverges: has an extra different line
  Add-Msgs $dst @('zz'); Add-Msgs $a @('d')
  Eq (Install-PhienFile $a $dst '/d/p' 'C:\Users\conta\Desktop\p' $Now) 'skip'
  # target just written
  $x = New-Sess $S 'inn00002' '/d/p' @('a'); $dx = Join-Path $D (Split-Path $x -Leaf)
  [void](Install-PhienFile $x $dx '/d/p' 'C:\q' $Now); Add-Msgs $x @('b'); [IO.File]::SetLastWriteTimeUtc($dx, [DateTime]::UtcNow)
  Eq (Install-PhienFile $x $dx '/d/p' 'C:\q' $Now) 'busy'
  Ok (-not (Get-ChildItem $D -Recurse -Filter '*.fcode-part*')) 'no part files left'
}

# ============================== end to end through the real fcode.ps1 + fake instabox ==============================
$Cmd = Join-Path $PSScriptRoot 'fake-instabox.cmd'
$script:E2E = $null
function Read-PhienLog($w) { $p = Join-Path $w.U '.fcode\phien.log'; if (Test-Path $p) { Get-Content $p -Raw } else { '' } }
function New-LogMark($w) { (Read-PhienLog $w).Length }
function Log-Since($w, [int]$Mark) { $t = Read-PhienLog $w; if ($t.Length -gt $Mark) { $t.Substring($Mark) } else { '' } }
function New-World([string]$Name) {
  $w = Join-Path $Root $Name
  $u = Join-Path $w 'home'; $lp = Join-Path $u 'Desktop\proj'; $bh = Join-Path $w 'boxhome'; $bp = ($w -replace '\\', '/') + '/boxws/proj'
  [void](New-Item -ItemType Directory -Path $lp, (Join-Path $u '.fcode'), $bh, $bp -Force)
  $cfg = Join-Path $w 'boxcfg.json'
  [IO.File]::WriteAllText($cfg, (@{ projects = @{ proj = $bp; other = ($w -replace '\\', '/') + '/boxws/other' } } | ConvertTo-Json -Compress))
  [IO.File]::WriteAllText((Join-Path $u '.fcode\config.json'), (@{ instabox = $Cmd; box = 'coder'; syncRepos = @($lp, (Join-Path $u 'Desktop\other'), (Join-Path $u 'Desktop\notonbox')) } | ConvertTo-Json -Compress))
  [pscustomobject]@{ W = $w; U = $u; LP = $lp; BH = $bh; BP = $bp; Cfg = $cfg
    LS = Join-Path $u ('.omp\agent\sessions\' + (Get-OmpEncodedDir $lp $u (Join-Path $u 'AppData\Local\Temp')))
    BS = Join-Path $bh ('.omp\agent\sessions\' + (Get-OmpEncodedDir $bp ($bh -replace '\\', '/') (Join-Path $u 'AppData\Local\Temp')))
    LBlobs = Join-Path $u '.omp\agent\blobs'; BBlobs = Join-Path $bh '.omp\agent\blobs'; Log = Join-Path $w 'ssh.log' }
}
# -NoWait: start it hidden and return the process (for the kill test); -Async: the same with the screen output captured, returns {P; Out = task};
# otherwise run it and return {Code; Out}
function Invoke-Fcode($World, [string[]]$FArgs, [hashtable]$ExtraEnv = @{}, [string]$InText = $null, [switch]$NoWait, [switch]$Async) {
  $ErrorActionPreference = 'Continue'   # Windows PowerShell 5.1 turns native stderr into errors under Stop
  $save = @{}
  $set = @{ USERPROFILE = $World.U; LOCALAPPDATA = (Join-Path $World.U 'AppData\Local'); FCODE_PHIEN_BOXENV = ('HOME=' + ($World.BH -replace '\\', '/') + ' FCODE_CFG=' + ($World.Cfg -replace '\\', '/')); FAKE_SSH_LOG = $World.Log; TEMP = (Join-Path $World.U 'AppData\Local\Temp'); TMP = (Join-Path $World.U 'AppData\Local\Temp') }
  foreach ($k in $ExtraEnv.Keys) { $set[$k] = $ExtraEnv[$k] }
  foreach ($k in $set.Keys) { $save[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $set[$k]) }
  try {
    if ($NoWait -or $Async) {
      $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
      $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Fcode + '" ' + ($FArgs -join ' ')
      $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
      if ($Async) { $psi.RedirectStandardOutput = $true; $psi.StandardOutputEncoding = $utf8 }
      $p = [Diagnostics.Process]::Start($psi)
      if ($Async) { return [pscustomobject]@{ P = $p; Out = $p.StandardOutput.ReadToEndAsync() } }
      return $p
    }
    $out = if ($InText) { $InText | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Fcode @FArgs 2>&1 | Out-String } else { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Fcode @FArgs 2>&1 | Out-String }
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
  } finally { foreach ($k in $save.Keys) { [Environment]::SetEnvironmentVariable($k, $(if ($null -eq $save[$k]) { [NullString]::Value } else { $save[$k] })) } }
}
function Set-AutoState($w, [bool]$running, [double]$ageMin) {
  $p = Join-Path $w.U 'AppData\Local\fcode\phien-auto.json'; [void](New-Item -ItemType Directory -Path (Split-Path $p) -Force)
  [IO.File]::WriteAllText($p, (@{ boxRunning = $running; lastSshAt = ((ConvertTo-Epoch (Get-Date)) - $ageMin * 60) } | ConvertTo-Json -Compress))
}
function Get-AutoState($w) { Get-Content (Join-Path $w.U 'AppData\Local\fcode\phien-auto.json') -Raw | ConvertFrom-Json }
function SshCount($World) { if (Test-Path $World.Log) { @(Get-Content $World.Log).Count } else { 0 } }
function Tree([string]$d) { if (Test-Path $d) { @(Get-ChildItem $d -Recurse -File | ForEach-Object { $_.FullName.Substring($d.Length + 1) } | Sort-Object) } else { @() } }

T 'e2e: first sync copies both ways, rewrites cwd, blobs and sidecars; second sync copies nothing' {
  $w = New-World 'e2e1'
  [void](New-Item -ItemType Directory -Path (Join-Path $w.U 'Desktop\other'), (Join-Path $w.U 'Desktop\notonbox') -Force)
  $h1 = 'a1' * 32; $h2 = 'b2' * 32
  # laptop-only session with nested subagent file and one blob; box-only session with another blob
  $ls = New-Sess $w.LS '11111111-aaaa' $w.LP @('a', ('blob:sha256:' + $h1))
  $nd = Join-Path $w.LS ((Split-Path $ls -Leaf).Replace('.jsonl', '') + '\sub'); [void](New-Item -ItemType Directory -Path $nd)
  $null = New-Sess $nd '11111111-sub1' ($w.LP + '\x') @('n1'); [IO.File]::WriteAllText((Join-Path $nd '1.bash.log'), 'log'); Set-Age (Join-Path $nd '1.bash.log') 600
  [void](New-Item -ItemType Directory -Path $w.LBlobs); [IO.File]::WriteAllText((Join-Path $w.LBlobs ($h1 + '.png')), 'png1')
  $bs = New-Sess $w.BS '22222222-bbbb' $w.BP @('b', ('blob:sha256:' + $h2))
  [void](New-Item -ItemType Directory -Path $w.BBlobs); [IO.File]::WriteAllText((Join-Path $w.BBlobs $h2), 'raw2')
  # a session of the project that is not synced (project not on both sides) must be ignored
  $r = Invoke-Fcode $w @('phien')
  Eq $r.Code 0 ("exit; out: " + $r.Out)
  Ok ($r.Out -match '== proj: gửi 1 phiên lên box, lấy 1 phiên về, 0 đã giống nhau') ("summary; out: " + $r.Out)
  Ok ($r.Out -match 'Nhớ đẩy code lên GitHub') 'push reminder'
  # laptop -> box
  $bl = Join-Path $w.BS (Split-Path $ls -Leaf)
  Ok (Test-Path $bl) 'session on box'
  Ok ((Latin $bl).Contains('"cwd":"' + $w.BP + '"')) "box header cwd; got: $((Latin $bl).Split("`n")[1])"
  Eq ((Get-Content ($bl.Replace('.jsonl', '.fcode-origin')) -Raw).Trim()) 'laptop' 'origin sidecar on box'
  $nb = Get-ChildItem (Join-Path $w.BS ((Split-Path $ls -Leaf).Replace('.jsonl', ''))) -Recurse -File
  Eq (@($nb).Count) 2 'nested files copied'
  Ok ((Latin ($nb | Where-Object Name -like '*.jsonl').FullName).Contains('"cwd":"' + $w.BP + '/x"')) 'nested header cwd mapped (subpath)'
  Ok (Test-Path (Join-Path $w.BBlobs ($h1 + '.png'))) 'blob copied to box (with extension)'
  Eq ((Mt1 ((Join-Path $w.BBlobs ($h1 + '.png'))))) ((Mt1 ((Join-Path $w.LBlobs ($h1 + '.png'))))) 'blob mtime kept (box)'
  Eq ((Mt1 (($nb | Where-Object Name -eq '1.bash.log').FullName))) ((Mt1 ((Join-Path $nd '1.bash.log')))) 'nested file mtime kept (box)'
  # box -> laptop
  $ll = Join-Path $w.LS (Split-Path $bs -Leaf)
  Ok (Test-Path $ll) 'session on laptop'
  Ok ((Latin $ll).Contains('"cwd":' + (ConvertTo-JsonStr $w.LP))) 'laptop header cwd'
  Ok (-not (Test-Path ($ll.Replace('.jsonl', '.fcode-origin')))) 'nothing extra is written into the laptop omp folder'
  Ok (Test-Path (Join-Path $w.LBlobs $h2)) 'blob copied to laptop'
  Eq ((Mt1 ((Join-Path $w.LBlobs $h2)))) ((Mt1 ((Join-Path $w.BBlobs $h2)))) 'blob mtime kept (laptop)'
  Eq ((Mt1 ($ll))) ((Mt1 ($bs))) 'mtime kept (laptop copy)'
  Eq ((Mt1 ($bl))) ((Mt1 ($ls))) 'mtime kept (box copy)'
  # second run: idempotent
  $before = (Tree $w.LS) -join '|'; $beforeB = (Tree $w.BS) -join '|'
  $r2 = Invoke-Fcode $w @('phien')
  Eq $r2.Code 0
  Ok ($r2.Out -match '0 file gửi lên box, 0 file lấy về laptop') ("second run copies nothing; out: " + $r2.Out)
  Eq ((Tree $w.LS) -join '|') $before; Eq ((Tree $w.BS) -join '|') $beforeB
  $script:E2E = $w
}
T 'e2e: continued session is copied over the shorter one; diverged is left alone; busy is skipped' {
  $w = $script:E2E
  $ls = Get-ChildItem $w.LS -Filter '*11111111-aaaa.jsonl'
  Add-Msgs $ls.FullName @('c', 'd')                                # laptop continues
  $bs = Get-ChildItem $w.BS -Filter '*22222222-bbbb.jsonl'
  Add-Msgs $bs.FullName @('e')                                      # box continues the other one
  $dl = New-Sess $w.LS '33333333-divv' $w.LP @('a', 'b'); $db = New-Sess $w.BS '33333333-divv' $w.BP @('a', 'zzz', 'q')
  $bz = New-Sess $w.LS '44444444-busy' $w.LP @('a'); [IO.File]::SetLastWriteTimeUtc($bz, [DateTime]::UtcNow)
  $divL = Read-Bytes $dl; $divB = Read-Bytes $db
  $r = Invoke-Fcode $w @('phien', 'proj')
  Eq $r.Code 0 $r.Out
  Eq (Read-Bytes (Join-Path $w.BS $ls.Name)).Length ((Read-Bytes $ls.FullName).Length + $w.BP.Length - (ConvertTo-JsonStr $w.LP).Length + 2) 'box copy caught up'
  Eq ((Read-Bytes (Join-Path $w.LS $bs.Name)).Length + $w.BP.Length - (ConvertTo-JsonStr $w.LP).Length + 2) (Read-Bytes $bs.FullName).Length 'laptop copy caught up'
  Eq ([Convert]::ToBase64String((Read-Bytes $dl))) ([Convert]::ToBase64String($divL)) 'diverged laptop file untouched'
  Eq ([Convert]::ToBase64String((Read-Bytes $db))) ([Convert]::ToBase64String($divB)) 'diverged box file untouched'
  Ok ($r.Out -match 'phiên 33333333 đã khác nhau ở hai máy, giữ nguyên cả hai') ("diverged message; out: " + $r.Out)
  Ok ($r.Out -match 'phiên 44444444 đang được ghi trên laptop') 'busy message'
  Ok (-not (Test-Path (Join-Path $w.BS (Split-Path $bz -Leaf)))) 'busy session not copied'
}
T 'e2e: nothing is ever deleted; only the session files and blobs are written' {
  $w = $script:E2E
  Ok (-not (Get-ChildItem $w.W -Recurse -Filter '*.fcode-part*')) 'no part files'
  Ok (-not (Get-ChildItem $w.W -Recurse -Filter '*.bak*')) 'no backups'
  $agentL = Join-Path $w.U '.omp\agent'; $agentB = Join-Path $w.BH '.omp\agent'
  foreach ($a in $agentL, $agentB) { foreach ($c in (Get-ChildItem $a -Directory)) { Ok ($c.Name -in 'sessions', 'blobs') "unexpected dir $($c.Name) in $a" }; Ok (-not (Get-ChildItem $a -File)) "unexpected files in $a" }
}
T 'e2e: unknown project and project missing on box' {
  $w = $script:E2E
  $r = Invoke-Fcode $w @('phien', 'nope'); Eq $r.Code 1; Ok ($r.Out -match "Không thấy project 'nope'") $r.Out
  $r = Invoke-Fcode $w @('phien', 'notonbox'); Eq $r.Code 0 $r.Out   # not in box config: nothing to do, no crash
}
T 'e2e: auto mode runs only while the box is running, never wakes it, logs a summary' {
  $w = New-World 'e2e2'
  [void](New-Item -ItemType Directory -Path (Join-Path $w.U 'Desktop\other'), (Join-Path $w.U 'Desktop\notonbox') -Force)
  $s = New-Sess $w.LS '55555555-auto' $w.LP @('a')
  $r = Invoke-Fcode $w @('phien', '--tu-dong') @{ FAKE_BOX_STATE = 'suspended' }
  Eq $r.Code 0 $r.Out; Eq (SshCount $w) 0 'no ssh while the box is not running'
  Ok (-not (Test-Path $w.BS)) 'nothing copied'
  $r = Invoke-Fcode $w @('phien', '--tu-dong') @{ FAKE_BOX_STATE = 'running' }
  Eq $r.Code 0 $r.Out; Ok (Test-Path (Join-Path $w.BS (Split-Path $s -Leaf))) 'copied while running'
  Eq ($r.Out.Trim()) '' 'auto mode prints nothing'
  $log = Join-Path $w.U '.fcode\phien.log'
  Ok ((Test-Path $log) -and ((Get-Content $log -Raw) -match 'Xong: 1 file gửi lên box')) 'log has the summary'
}
T 'e2e: --thu (dry run) lists what would be copied and writes nothing' {
  $w = New-World 'e2e4'
  [void](New-Item -ItemType Directory -Path (Join-Path $w.U 'Desktop\other'), (Join-Path $w.U 'Desktop\notonbox') -Force)
  $s = New-Sess $w.LS '66666666-dry0' $w.LP @('a'); $x = New-Sess $w.BS '77777777-dry1' $w.BP @('a')
  $r = Invoke-Fcode $w @('phien', '--thu')
  Eq $r.Code 0 $r.Out
  Ok ($r.Out -match 'sẽ gửi lên box: phiên 66666666') ("dry put; out: " + $r.Out)
  Ok ($r.Out -match 'sẽ lấy về laptop: phiên 77777777') 'dry get'
  Ok ($r.Out -match 'Chạy thử') 'dry banner'
  Eq (@(Get-ChildItem $w.LS -File).Count) 1 'laptop untouched'; Eq (@(Get-ChildItem $w.BS -File).Count) 1 'box untouched'
}
$OmpExe = Get-Command omp -ErrorAction SilentlyContinue
# omp's own lookup: run omp in rpc mode (no model call) against the synced store and ask which session file it opened
function Get-OmpOpened([string]$Home_, [string]$Cwd, [string[]]$OmpArgs) {
  $agent = Join-Path $Root ('agentcopy-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
  Copy-Item -LiteralPath (Join-Path $Home_ '.omp\agent') -Destination $agent -Recurse   # omp may append to what it opens: never use the synced store itself
  $save = @{}; $set = @{ USERPROFILE = $Home_; HOME = $Home_; PI_CODING_AGENT_DIR = $agent; TEMP = (Join-Path $Home_ 'AppData\Local\Temp'); TMP = (Join-Path $Home_ 'AppData\Local\Temp') }
  foreach ($k in $set.Keys) { $save[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $set[$k]) }
  [void](New-Item -ItemType Directory -Path $set.TEMP -Force)
  try {
    $p = New-Object Diagnostics.Process
    $p.StartInfo.FileName = $OmpExe.Source
    $p.StartInfo.Arguments = '--mode rpc --no-extensions --no-skills --no-rules --no-title ' + ($OmpArgs -join ' ')
    $p.StartInfo.WorkingDirectory = $Cwd
    $p.StartInfo.UseShellExecute = $false; $p.StartInfo.CreateNoWindow = $true
    $p.StartInfo.RedirectStandardInput = $true; $p.StartInfo.RedirectStandardOutput = $true; $p.StartInfo.RedirectStandardError = $true
    [void]$p.Start()
    $err = $p.StandardError.ReadToEndAsync()
    $p.StandardInput.WriteLine('{"id":"1","type":"get_state"}'); $p.StandardInput.Flush()
    $res = $null
    for ($i = 0; $i -lt 60 -and -not $res; $i++) {
      $rl = $p.StandardOutput.ReadLineAsync()
      if (-not $rl.Wait(30000)) { break }
      if ($null -eq $rl.Result) { break }
      if ($rl.Result -match '^\{"id":"1","type":"response"') { $res = ($rl.Result | ConvertFrom-Json).data }
    }
    try { $p.StandardInput.Close() } catch { }
    if (-not $p.WaitForExit(8000)) { $p.Kill() }
    if (-not $res) { throw ('omp gave no state: ' + $err.Result.Substring(0, [Math]::Min(300, $err.Result.Length))) }
    [pscustomobject]@{ File = [string]$res.sessionFile; Id = [string]$res.sessionId; Agent = $agent }
  } finally { foreach ($k in $save.Keys) { [Environment]::SetEnvironmentVariable($k, $(if ($null -eq $save[$k]) { [NullString]::Value } else { $save[$k] })) } }
}
T 'e2e: omp itself finds the synced sessions (-r id resolves the file, -c picks the newest by mtime), on both machines' {
  if (-not $OmpExe) { Write-Host 'SKIP (omp not installed)'; return }
  $w = New-World 'e2e5'
  [void](New-Item -ItemType Directory -Path (Join-Path $w.U 'Desktop\other'), (Join-Path $w.U 'Desktop\notonbox') -Force)
  $a = New-Sess $w.LS 'a0000000-0000-7000-8000-00000000000a' $w.LP @('a') 'A' "`n" '2026-10-20T10-00-00-000Z'; Set-Age $a 3000
  $c = New-Sess $w.LS 'c0000000-0000-7000-8000-00000000000c' $w.LP @('c') 'C' "`n" '2026-10-21T10-00-00-000Z'; Set-Age $c 2000
  $b = New-Sess $w.BS 'b0000000-0000-7000-8000-00000000000b' $w.BP @('b') 'B' "`n" '2026-10-19T10-00-00-000Z'; Set-Age $b 1000   # created first, but touched last
  $d = New-Sess $w.BS 'd0000000-0000-7000-8000-00000000000d' $w.BP @('d') 'D' "`n" '2026-10-22T10-00-00-000Z'; Set-Age $d 4000
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  # laptop: sees the box session b, and it is the newest by mtime (omp -c)
  $o = Get-OmpOpened $w.U $w.LP @('-r', 'b0000000'); Eq $o.Id 'b0000000-0000-7000-8000-00000000000b' 'omp -r b (laptop)'
  Ok ($o.File -like (Join-Path $o.Agent 'sessions\*\*b0000000-0000-7000-8000-00000000000b.jsonl')) "file: $($o.File)"
  $o = Get-OmpOpened $w.U $w.LP @('-c'); Eq $o.Id 'b0000000-0000-7000-8000-00000000000b' 'omp -c (laptop) picks the newest by mtime = the box-origin session'
  # box: sees the laptop sessions; newest by mtime there is b (box-own, mtime 1000s ago) -> -c gives b, -r a/c resolve
  $o = Get-OmpOpened $w.BH ($w.BP -replace '/', '\') @('-r', 'a0000000'); Eq $o.Id 'a0000000-0000-7000-8000-00000000000a' 'omp -r a (box)'
  $o = Get-OmpOpened $w.BH ($w.BP -replace '/', '\') @('-r', 'c0000000'); Eq $o.Id 'c0000000-0000-7000-8000-00000000000c' 'omp -r c (box)'
  $o = Get-OmpOpened $w.BH ($w.BP -replace '/', '\') @('-c'); Eq $o.Id 'b0000000-0000-7000-8000-00000000000b' 'omp -c (box) newest by mtime'
  # mtimes survived the copy in both directions
  Eq ((Mt1 ((Join-Path $w.LS (Split-Path $b -Leaf))))) ((Mt1 ($b))) 'laptop copy mtime'
  Eq ((Mt1 ((Join-Path $w.BS (Split-Path $a -Leaf))))) ((Mt1 ($a))) 'box copy mtime'
}
T 'e2e: format guard in a real run: unknown session skipped and reported, status file written, menu warns, clears when fixed' {
  $w = New-World 'e2e6'
  [void](New-Item -ItemType Directory -Path (Join-Path $w.U 'Desktop\other'), (Join-Path $w.U 'Desktop\notonbox') -Force)
  $ok = New-Sess $w.LS '88888888-good' $w.LP @('a')
  $bad = New-RawSess $w.LS '2026-10-25T16-18-25-246Z_99999999-newf.jsonl' @('{"type":"title","v":1}', ('{"type":"session","version":4,"id":"99999999-newf","cwd":' + (ConvertTo-JsonStr $w.LP) + '}'), (Msg 'a'))
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Ok ($r.Out -match 'omp đổi định dạng phiên \(version 4\) — chưa đồng bộ, báo Claude') ("summary line; out: " + $r.Out)
  Ok (Test-Path (Join-Path $w.BS (Split-Path $ok -Leaf))) 'known session copied'
  Ok (-not (Test-Path (Join-Path $w.BS (Split-Path $bad -Leaf)))) 'unknown session NOT copied'
  $sp = Join-Path $w.U 'AppData\Local\fcode\phien-status.json'
  Ok (Test-Path $sp) 'status file'
  $s = Get-Content $sp -Raw | ConvertFrom-Json
  Eq ($s.ok) $true; Eq ($s.copied) 1; Eq (@($s.unknownFormat) -join ',') '99999999-newf'; Eq $s.diverged 0; Eq $s.skipped 0
  Ok ((Get-Content $sp -Raw) -match '"at":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"') 'at is UTC ISO'
  foreach ($k in 'at', 'ok', 'copied', 'skipped', 'diverged', 'unknownFormat', 'ompLaptop', 'ompBox') { Ok ($null -ne $s.PSObject.Properties[$k]) "status has $k" }
  if ($OmpExe) { Ok ($s.ompLaptop -match '^\d+\.\d+\.\d+') "ompLaptop recorded: $($s.ompLaptop)"; Eq $s.ompBox $s.ompLaptop 'same omp on both sides (the box program is run locally here)' }
  # fcode menu (no args): warning line first, before anything else
  $m = Invoke-Fcode $w @()
  Ok ($m.Out.TrimStart() -like 'Cảnh báo: omp đổi định dạng phiên, 1 phiên chưa đồng bộ*') ("menu warning first; out: " + $m.Out)
  # dry run does not touch the status file
  $before = Get-Content $sp -Raw
  [void](Invoke-Fcode $w @('phien', '--thu')); Eq (Get-Content $sp -Raw) $before 'dry run leaves the status alone'
  # fixed: remove the unknown session -> next run clears the warning
  Remove-Item $bad
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  $s = Get-Content $sp -Raw | ConvertFrom-Json; Eq @($s.unknownFormat).Count 0 'cleared'
  $m = Invoke-Fcode $w @(); Ok ($m.Out -notmatch 'Cảnh báo') ("no warning any more; out: " + $m.Out)
  # a failed AUTO run warns too; a failed manual run does not
  Set-AutoState $w $true 41   # the last ssh is long enough ago, so the auto run does try ssh
  $r = Invoke-Fcode $w @('phien', '--tu-dong') @{ FAKE_SSH_FAIL = '1' }
  $s = Get-Content $sp -Raw | ConvertFrom-Json; Eq $s.ok $false 'auto run failed'
  $m = Invoke-Fcode $w @(); Ok ($m.Out.TrimStart() -like 'Cảnh báo: lần tự động đồng bộ phiên omp gần nhất bị lỗi*') ("auto-failure warning; out: " + $m.Out)
  [void](Invoke-Fcode $w @('phien')); $m = Invoke-Fcode $w @(); Ok ($m.Out -notmatch 'Cảnh báo') 'a later good run clears it'
  $r = Invoke-Fcode $w @('phien') @{ FAKE_SSH_FAIL = '1' }; Eq $r.Code 1
  $m = Invoke-Fcode $w @(); Ok ($m.Out -notmatch 'Cảnh báo') 'failed manual run does not warn'
}
T 'e2e: project notes both ways with git rules, hash state, big files, exclude, conflicts, never delete' {
  $w = New-World 'e2e7'
  [void](New-Item -ItemType Directory -Path (Join-Path $w.U 'Desktop\other'), (Join-Path $w.U 'Desktop\notonbox') -Force)
  New-GitDir $w.LP; New-GitDir $w.BP
  $big = (1..32000 | ForEach-Object { "line $_ of the agent state file with some text`n" }) -join ''
  Ok ($big.Length -gt 600000) 'fixture is about 600 KB'
  Put-File "$($w.LP)\HANDOFF-mobile-1.md" 'laptop handoff'                       # laptop only -> box
  Put-File "$($w.LP)\agent_state.md" $big                                          # big, laptop only, gitignored on the laptop
  Put-File "$($w.LP)\TASK.md" 'task'; Put-File "$($w.LP)\.gitignore" "agent_state.md`nTASK.md`n"
  Put-File "$($w.BP)\HANDOFF-box.md" 'box handoff'                                 # box only -> laptop
  Put-File "$($w.LP)\AGENTS.md" 'same on both'; Put-File "$($w.BP)\AGENTS.md" 'same on both'     # identical: first run only records
  Put-File "$($w.LP)\WORKFLOW.md" 'laptop version'; Put-File "$($w.BP)\WORKFLOW.md" 'box version'  # differ, no record -> conflict
  Put-File "$($w.LP)\CLAUDE.md" 'laptop claude (untracked)'; Put-File "$($w.BP)\CLAUDE.md" 'box claude (tracked)'; Git-Commit $w.BP @('CLAUDE.md')   # tracked on the box -> never synced
  $mtBig = Mt1 "$($w.LP)\agent_state.md"
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Eq (Get-Content "$($w.BP)\HANDOFF-mobile-1.md" -Raw) 'laptop handoff' 'laptop -> box'
  Eq (Get-Content "$($w.LP)\HANDOFF-box.md" -Raw) 'box handoff' 'box -> laptop'
  Eq ((Get-FileHash "$($w.BP)\agent_state.md" -Algorithm SHA256).Hash) ((Get-FileHash "$($w.LP)\agent_state.md" -Algorithm SHA256).Hash) '600 KB file identical'
  Eq (Mt1 "$($w.BP)\agent_state.md") $mtBig 'mtime preserved'
  Eq (Get-Content "$($w.BP)\TASK.md" -Raw) 'task' 'gitignored on the laptop still travels'
  Eq (Get-Content "$($w.BP)\WORKFLOW.md" -Raw) 'box version'; Eq (Get-Content "$($w.LP)\WORKFLOW.md" -Raw) 'laptop version'
  Eq (Get-Content "$($w.BP)\CLAUDE.md" -Raw) 'box claude (tracked)'; Eq (Get-Content "$($w.LP)\CLAUDE.md" -Raw) 'laptop claude (untracked)'
  Ok ($r.Out -match 'ghi chú dự án: chép 4, xung đột 1') ("summary; out: " + $r.Out)
  Ok ($r.Out -match 'handoff WORKFLOW\.md khác nhau ở hai máy, giữ nguyên cả hai') 'conflict line'
  # exclude: target side only
  $bx = Get-Content "$($w.BP)\.git\info\exclude" -Raw
  foreach ($n in 'HANDOFF-mobile-1.md', 'agent_state.md', 'TASK.md', 'AGENTS.md') { Ok ($bx -match "(?m)^/$([regex]::Escape($n))\r?$") "box exclude has $n" }
  Ok ($bx -notmatch 'CLAUDE|WORKFLOW|HANDOFF-box') 'box exclude has only what arrived or was ensured'
  $lx = Get-Content "$($w.LP)\.git\info\exclude" -Raw
  Ok ($lx -match '(?m)^/HANDOFF-box\.md\r?$') 'laptop exclude has the file that came from the box'
  Ok ($lx -notmatch 'HANDOFF-mobile-1') 'the source file is not excluded'
  Ok (((& git -C $w.BP status --porcelain | Out-String)) -notmatch 'HANDOFF-mobile|agent_state|TASK|AGENTS') 'box git status does not list synced notes'
  Ok ((Get-Content "$($w.LP)\.gitignore" -Raw) -eq "agent_state.md`nTASK.md`n" -and -not (Test-Path "$($w.BP)\.gitignore")) '.gitignore never edited or created'
  # state + status
  $st = Get-Content (Join-Path $w.U 'AppData\Local\fcode\handoff-state.json') -Raw | ConvertFrom-Json
  foreach ($n in 'HANDOFF-mobile-1.md', 'HANDOFF-box.md', 'agent_state.md', 'TASK.md', 'AGENTS.md') { Ok ($null -ne $st.PSObject.Properties["proj/$n"]) "state records $n" }
  Ok ($null -eq $st.PSObject.Properties['proj/WORKFLOW.md']) 'conflict is not recorded'
  $s = Get-Content (Join-Path $w.U 'AppData\Local\fcode\phien-status.json') -Raw | ConvertFrom-Json
  Eq $s.notes.copied 4; Eq (@($s.notes.conflicts) -join ',') 'proj/WORKFLOW.md'; Ok ($null -eq $s.PSObject.Properties['handoffs']) 'key is notes'
  # second run: nothing to do
  $r2 = Invoke-Fcode $w @('phien'); Eq $r2.Code 0
  Ok ($r2.Out -notmatch 'chép [1-9]') ("nothing copied again; out: " + $r2.Out); Ok ($r2.Out -match 'xung đột 1') 'conflict is still reported'
  # only one side changed since the record -> that side wins
  Put-File "$($w.LP)\HANDOFF-mobile-1.md" 'laptop handoff v2'
  $r3 = Invoke-Fcode $w @('phien'); Eq $r3.Code 0 $r3.Out
  Eq (Get-Content "$($w.BP)\HANDOFF-mobile-1.md" -Raw) 'laptop handoff v2' 'laptop change reaches the box'
  Put-File "$($w.BP)\HANDOFF-mobile-1.md" 'box handoff v3'
  $r4 = Invoke-Fcode $w @('phien'); Eq $r4.Code 0 $r4.Out
  Eq (Get-Content "$($w.LP)\HANDOFF-mobile-1.md" -Raw) 'box handoff v3' 'box change reaches the laptop'
  # both changed -> nothing touched
  Put-File "$($w.LP)\HANDOFF-mobile-1.md" 'laptop v4'; Put-File "$($w.BP)\HANDOFF-mobile-1.md" 'box v4'
  $r5 = Invoke-Fcode $w @('phien'); Eq $r5.Code 0
  Eq (Get-Content "$($w.LP)\HANDOFF-mobile-1.md" -Raw) 'laptop v4'; Eq (Get-Content "$($w.BP)\HANDOFF-mobile-1.md" -Raw) 'box v4'
  Ok ($r5.Out -match 'handoff HANDOFF-mobile-1\.md khác nhau ở hai máy, giữ nguyên cả hai') 'conflict reported'
  # never delete: removing a file on one side removes nothing on the other
  Remove-Item "$($w.LP)\TASK.md"
  [void](Invoke-Fcode $w @('phien'))
  Ok (Test-Path "$($w.BP)\TASK.md") 'box copy still there'
  # dry run lists, writes nothing
  Put-File "$($w.LP)\CLAUDE.local.md" 'local only'
  $d0 = Get-Content (Join-Path $w.U 'AppData\Local\fcode\handoff-state.json') -Raw
  $rd = Invoke-Fcode $w @('phien', '--thu'); Eq $rd.Code 0
  Ok ($rd.Out -match 'sẽ gửi lên box: ghi chú CLAUDE\.local\.md') ("dry run lists the note; out: " + $rd.Out)
  Ok (-not (Test-Path "$($w.BP)\CLAUDE.local.md")) 'dry run copied nothing'; Eq (Get-Content (Join-Path $w.U 'AppData\Local\fcode\handoff-state.json') -Raw) $d0 'dry run leaves the state alone'
}
# ============================== real box (opt-in) ==============================
# FCODE_TEST_BOX=1: the real instabox box "coder", but only in a throwaway HOME under /tmp there (removed at the end); the laptop side is a temp USERPROFILE.
if ($env:FCODE_TEST_BOX) {
  $RealIb = Join-Path $env:LOCALAPPDATA 'Programs\instabox\instabox.exe'
  function Invoke-RealBox([string]$Remote, [byte[]]$In = $null) {
    $psi = New-Object Diagnostics.ProcessStartInfo; $psi.FileName = $RealIb; $psi.Arguments = 'ssh coder -- "' + $Remote.Replace('"', '\"') + '"'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    if ($In) { $p.StandardInput.BaseStream.Write($In, 0, $In.Length) }
    $p.StandardInput.BaseStream.Close(); [void]$p.WaitForExit(120000)
    $o.Result.Trim()
  }
  T 'real box: both ways, cwd rewritten, blob, notes, second run copies nothing, omp on the box resolves the session' {
    $bt = Invoke-RealBox 'mktemp -d /tmp/fcode-phien-test-XXXXXXXX'; Ok ($bt -match '\A/tmp/fcode-phien-test-[A-Za-z0-9]{8}\z') "throwaway dir: $bt"; $bp = "$bt/ws/proj"
    $w = New-World 'real1'
    [void](New-Item -ItemType Directory -Path (Join-Path $w.U 'Desktop\other'), (Join-Path $w.U 'Desktop\notonbox') -Force)
    [IO.File]::WriteAllText((Join-Path $w.U '.fcode\config.json'), (@{ instabox = $RealIb; box = 'coder'; syncRepos = @($w.LP) } | ConvertTo-Json -Compress))
    $enc = Get-OmpEncodedDir $bp $bt "$bt/tmp"
    $sd = "$bt/.omp/agent/sessions/$enc"
    try {
      $cfgB64 = [Convert]::ToBase64String($utf8.GetBytes((@{ projects = @{ proj = $bp } } | ConvertTo-Json -Compress)))
      [void](Invoke-RealBox "mkdir -p $bp $sd $bt/tmp $bt/.omp/agent/blobs && git -C $bp init -q && echo $cfgB64 | base64 -d > $bt/cfg.json && echo ready")
      # box side fixtures (made on the box): one session + one handoff
      $bid = 'b0000000-0000-7000-8000-00000000000b'; $bname = "2026-10-19T10-00-00-000Z_$bid.jsonl"
      $bcontent = (@('{"type":"title","v":1,"title":"B","updatedAt":"2026-10-25T16:18:25.246Z","pad":"  "}', ('{"cwd":"' + $bp + '","id":"' + $bid + '","timestamp":"t","type":"session","version":3}'), (Msg 'b')) -join "`n") + "`n"
      [void](Invoke-RealBox "cat > $sd/$bname && touch -d @`$((`$(date +%s)-600)) $sd/$bname" $utf8.GetBytes($bcontent))
      [void](Invoke-RealBox "cat > $bp/HANDOFF-box.md && touch -d @`$((`$(date +%s)-600)) $bp/HANDOFF-box.md" $utf8.GetBytes('box handoff'))
      # laptop side fixtures
      New-GitDir $w.LP
      $h1 = 'c3' * 32
      $a = New-Sess $w.LS 'a0000000-0000-7000-8000-00000000000a' $w.LP @('a', ('blob:sha256:' + $h1)) 'A' "`n" '2026-10-20T10-00-00-000Z'
      [void](New-Item -ItemType Directory -Path $w.LBlobs); [IO.File]::WriteAllText((Join-Path $w.LBlobs ($h1 + '.png')), 'png'); Set-Age (Join-Path $w.LBlobs ($h1 + '.png')) 600
      Put-File "$($w.LP)\HANDOFF-laptop.md" 'laptop handoff'
      $env0 = @{ FCODE_PHIEN_BOXENV = "HOME=$bt TMPDIR=$bt/tmp FCODE_CFG=$bt/cfg.json" }   # TMPDIR: the leftover sweep stays inside the throwaway dir
      $r = Invoke-Fcode $w @('phien') $env0; Eq $r.Code 0 $r.Out
      Ok ($r.Out -match '== proj: gửi 1 phiên lên box, lấy 1 phiên về') ("summary; out: " + $r.Out)
      Ok (Test-Path (Join-Path $w.LS $bname)) 'box session arrived on the laptop'
      Ok ((Latin (Join-Path $w.LS $bname)).Contains('"cwd":' + (ConvertTo-JsonStr $w.LP))) 'laptop header cwd'
      $aname = Split-Path $a -Leaf
      Eq (Invoke-RealBox "grep -c '`"cwd`":`"$bp`"' $sd/$aname") '1' 'box header cwd rewritten'
      Eq (Invoke-RealBox "cat $sd/$($aname.Replace('.jsonl', '.fcode-origin'))") 'laptop' 'origin sidecar on the box'
      Ok ((Invoke-RealBox "ls $bt/.omp/agent/blobs") -match $h1) 'blob on the box (with extension)'
      Eq (Invoke-RealBox "cat $bp/HANDOFF-laptop.md") 'laptop handoff' 'note laptop -> box'
      Eq (Get-Content "$($w.LP)\HANDOFF-box.md" -Raw) 'box handoff' 'note box -> laptop'
      Ok ((Invoke-RealBox "cat $bp/.git/info/exclude") -match '(?m)^/HANDOFF-laptop\.md$') 'exclude on the box'
      Ok ((Invoke-RealBox "git -C $bp status --porcelain") -notmatch 'HANDOFF-laptop') 'the synced note does not show in box git status (the box-made source file is left as it was)'
      # omp itself, on the box, in the throwaway profile
      $o = Invoke-RealBox "cd $bp && printf '{`"id`":`"1`",`"type`":`"get_state`"}\n' | HOME=$bt TMPDIR=$bt/tmp PI_CODING_AGENT_DIR=$bt/.omp/agent timeout 60 /data/home/.local/bin/omp --mode rpc --no-extensions --no-skills --no-rules --no-title --model openai/gpt-5.5 --api-key sk-dummy -r a0000000 | grep -o '`"sessionFile`":`"[^`"]*`"' | head -n 1"
      Ok ($o -like "*$($aname)*") "omp on the box resolved the synced session: $o"
      # second run
      $r2 = Invoke-Fcode $w @('phien') $env0; Eq $r2.Code 0 $r2.Out
      Ok ($r2.Out -match '0 file gửi lên box, 0 file lấy về laptop' -and $r2.Out -notmatch 'chép [1-9]') ("second run copies nothing; out: " + $r2.Out)
    } finally { [void](Invoke-RealBox "rm -rf $bt") }
  }
  # r7: real symlinks (the Windows tests cannot make one): a linked .git/info/exclude, then a linked .git/info, on the box
  T 'real box: a symlinked .git/info/exclude (then a symlinked .git/info) is never written through or over: the note is not placed, the target and the link stay' {
    $bt = Invoke-RealBox 'mktemp -d /tmp/fcode-phien-test-XXXXXXXX'; Ok ($bt -match '\A/tmp/fcode-phien-test-[A-Za-z0-9]{8}\z') "throwaway dir: $bt"; $bp = "$bt/ws/proj"
    $w = New-World 'real4'
    [IO.File]::WriteAllText((Join-Path $w.U '.fcode\config.json'), (@{ instabox = $RealIb; box = 'coder'; syncRepos = @($w.LP) } | ConvertTo-Json -Compress))
    $sd = "$bt/.omp/agent/sessions/$(Get-OmpEncodedDir $bp $bt "$bt/tmp")"
    try {
      $cfgB64 = [Convert]::ToBase64String($utf8.GetBytes((@{ projects = @{ proj = $bp } } | ConvertTo-Json -Compress)))
      [void](Invoke-RealBox "mkdir -p $bp $sd $bt/tmp && git -C $bp init -q && echo $cfgB64 | base64 -d > $bt/cfg.json && printf '# shared\n' > $bt/shared-exclude && ln -sf $bt/shared-exclude $bp/.git/info/exclude && echo ready")
      New-GitDir $w.LP; Put-File "$($w.LP)\HANDOFF-laptop.md" 'laptop handoff'
      $env0 = @{ FCODE_PHIEN_BOXENV = "HOME=$bt TMPDIR=$bt/tmp FCODE_CFG=$bt/cfg.json" }
      $r = Invoke-Fcode $w @('phien') $env0; Eq $r.Code 0 $r.Out
      Eq (Invoke-RealBox "test -e $bp/HANDOFF-laptop.md && echo yes || echo no") 'no' 'file link: the note is not placed'
      Eq (Invoke-RealBox "readlink $bp/.git/info/exclude") "$bt/shared-exclude" 'file link: the link is still there'
      Eq (Invoke-RealBox "cat $bt/shared-exclude") '# shared' 'file link: nothing written through it'
      [void](Invoke-RealBox "rm $bp/.git/info/exclude && mv $bp/.git/info $bt/infodir && printf '# shared2\n' > $bt/infodir/exclude && ln -s $bt/infodir $bp/.git/info && echo ok")
      $r = Invoke-Fcode $w @('phien') $env0; Eq $r.Code 0 $r.Out
      Eq (Invoke-RealBox "test -e $bp/HANDOFF-laptop.md && echo yes || echo no") 'no' 'folder link: the note is not placed'
      Eq (Invoke-RealBox "readlink $bp/.git/info") "$bt/infodir" 'folder link: the link is still there'
      Eq (Invoke-RealBox "cat $bt/infodir/exclude") '# shared2' 'folder link: nothing written through it'
    } finally { [void](Invoke-RealBox "rm -rf $bt; echo ok") }
  }
  # r9 (Rule H): a release rewrites the exclude file only once .fcode/.gitignore holds "*"; a dangling link in that place is never followed or replaced (the release waits)
  T 'real box: a release with a dangling link at .fcode/.gitignore: the link is never followed or replaced and the release waits (error line, exit 1); link gone: released' {
    $bt = Invoke-RealBox 'mktemp -d /tmp/fcode-phien-test-XXXXXXXX'; Ok ($bt -match '\A/tmp/fcode-phien-test-[A-Za-z0-9]{8}\z') "throwaway dir: $bt"; $bp = "$bt/ws/proj"
    $w = New-World 'real5'
    [IO.File]::WriteAllText((Join-Path $w.U '.fcode\config.json'), (@{ instabox = $RealIb; box = 'coder'; syncRepos = @($w.LP) } | ConvertTo-Json -Compress))
    $sd = "$bt/.omp/agent/sessions/$(Get-OmpEncodedDir $bp $bt "$bt/tmp")"
    try {
      $cfgB64 = [Convert]::ToBase64String($utf8.GetBytes((@{ projects = @{ proj = $bp } } | ConvertTo-Json -Compress)))
      [void](Invoke-RealBox "mkdir -p $bp $sd $bt/tmp && git -C $bp init -q && echo $cfgB64 | base64 -d > $bt/cfg.json && echo ready")
      New-GitDir $w.LP; Put-File "$($w.LP)\HANDOFF-laptop.md" 'laptop handoff'
      $env0 = @{ FCODE_PHIEN_BOXENV = "HOME=$bt TMPDIR=$bt/tmp FCODE_CFG=$bt/cfg.json" }
      $r = Invoke-Fcode $w @('phien') $env0; Eq $r.Code 0 $r.Out
      Ok ((Invoke-RealBox "cat $bp/.git/info/exclude") -match '(?m)^# fcode\r?\n/HANDOFF-laptop\.md$') 'the pair is on the box'
      [void](Invoke-RealBox "mkdir -p $bp/.fcode && ln -s $bt/nowhere $bp/.fcode/.gitignore && echo ok")
      Git-Commit $w.LP @('HANDOFF-laptop.md'); $m = New-LogMark $w
      $r = Invoke-Fcode $w @('phien') $env0; Eq $r.Code 1 $r.Out
      Ok (($r.Out + (Get-Content (Join-Path $w.U '.fcode\phien.log') -Raw -ErrorAction SilentlyContinue)) -match '\[proj\] lỗi: ghi chú HANDOFF-laptop\.md: box chưa gỡ được dòng /HANDOFF-laptop\.md của fcode trong \.git/info/exclude \(liên kết, git trên box lỗi, hoặc chưa tạo được \.fcode/\.gitignore\), lần sau thử lại') ('the release error line: ' + $r.Out)
      Ok (($r.Out + (Log-Since $w $m)) -notmatch 'giờ do git theo dõi') 'a failed release prints no "xóa được" line (only the error line)'
      Eq @((Get-Content (Join-Path $w.U 'AppData\Local\fcode\phien-status.json') -Raw | ConvertFrom-Json).notes.released).Count 0 'a failed release is not in notes.released'
      Ok ((Invoke-RealBox "cat $bp/.git/info/exclude") -match '(?m)^# fcode\r?\n/HANDOFF-laptop\.md$') 'the pair is still on the box (the release waits)'
      Eq (Invoke-RealBox "readlink $bp/.fcode/.gitignore") "$bt/nowhere" 'the dangling link is still there'
      Eq (Invoke-RealBox "test -e $bt/nowhere && echo yes || echo no") 'no' 'nothing was made at the link target'
      Eq (Invoke-RealBox "ls -A $bp/.fcode") '.gitignore' 'nothing else in .fcode'
      # a link to an existing file: not followed (nothing written into the target) and not replaced either
      [void](Invoke-RealBox "rm $bp/.fcode/.gitignore && printf 'keep\n' > $bt/target && ln -s $bt/target $bp/.fcode/.gitignore && echo ok")
      $r = Invoke-Fcode $w @('phien') $env0; Eq $r.Code 1 $r.Out
      Eq (Invoke-RealBox "readlink $bp/.fcode/.gitignore") "$bt/target" 'the link to a file is still a link'; Eq (Invoke-RealBox "cat $bt/target") 'keep' 'nothing written through it'
      Ok ((Invoke-RealBox "cat $bp/.git/info/exclude") -match '(?m)^# fcode\r?\n/HANDOFF-laptop\.md$') 'the pair is still on the box'
      [void](Invoke-RealBox "rm $bp/.fcode/.gitignore && echo ok")
      $r = Invoke-Fcode $w @('phien') $env0; Eq $r.Code 0 $r.Out
      Ok ((Invoke-RealBox "cat $bp/.git/info/exclude") -notmatch 'HANDOFF-laptop') 'link gone: the release removed the pair'
      Eq (Invoke-RealBox "cat $bp/.fcode/.gitignore") '*' '.fcode/.gitignore holds *'
      Eq (Invoke-RealBox "ls -A $bp/.fcode") '.gitignore' 'nothing else in .fcode'
    } finally { [void](Invoke-RealBox "rm -rf $bt; echo ok") }
  }
  T 'real box: a session file that a box process holds open is left alone (busy) and its top waits; once closed, the next run updates it' {
    $bt = Invoke-RealBox 'mktemp -d /tmp/fcode-phien-test-XXXXXXXX'; Ok ($bt -match '\A/tmp/fcode-phien-test-[A-Za-z0-9]{8}\z') "throwaway dir: $bt"; $bp = "$bt/ws/proj"
    $w = New-World 'real2'
    [IO.File]::WriteAllText((Join-Path $w.U '.fcode\config.json'), (@{ instabox = $RealIb; box = 'coder'; syncRepos = @($w.LP) } | ConvertTo-Json -Compress))
    $sd = "$bt/.omp/agent/sessions/$(Get-OmpEncodedDir $bp $bt "$bt/tmp")"
    try {
      $cfgB64 = [Convert]::ToBase64String($utf8.GetBytes((@{ projects = @{ proj = $bp } } | ConvertTo-Json -Compress)))
      [void](Invoke-RealBox "mkdir -p $bp $sd $bt/tmp && echo $cfgB64 | base64 -d > $bt/cfg.json")
      $a = New-Sess $w.LS 'a0000000-0000-7000-8000-0000000000b5' $w.LP @('a') 'A' "`n" '2026-10-20T10-00-00-000Z'; $an = Split-Path $a -Leaf
      $env0 = @{ FCODE_PHIEN_BOXENV = "HOME=$bt TMPDIR=$bt/tmp FCODE_CFG=$bt/cfg.json" }
      $r = Invoke-Fcode $w @('phien') $env0; Eq $r.Code 0 $r.Out
      $len0 = Invoke-RealBox "stat -c %s $sd/$an"
      Add-Msgs $a @('b')
      [void](Invoke-RealBox "nohup sh -c 'echo `$`$ > $bt/pid; exec 3>>$sd/$an; exec sleep 120' </dev/null >/dev/null 2>&1 & sleep 1; echo started")
      $r = Invoke-Fcode $w @('phien') $env0
      Ok ($r.Out -match '1 file đang mở trên box') ("told; out: " + $r.Out)
      Eq (Invoke-RealBox "stat -c %s $sd/$an") $len0 'the held file is unchanged'
      [void](Invoke-RealBox "kill `$(cat $bt/pid); sleep 1; echo ok")
      $r = Invoke-Fcode $w @('phien') $env0; Eq $r.Code 0 $r.Out
      Eq (Invoke-RealBox "grep -c '`"id`":`"b`"' $sd/$an") '1' 'updated once nothing holds it'
    } finally { [void](Invoke-RealBox "kill `$(cat $bt/pid 2>/dev/null) 2>/dev/null; rm -rf $bt; echo ok") }
  }
  T 'real box: fcode add runs the box script under timeout: a stalled script is stopped (124, or 137 when it ignores TERM) and leaves no process' {
    $bt = Invoke-RealBox 'mktemp -d /tmp/fcode-phien-test-XXXXXXXX'; Ok ($bt -match '\A/tmp/fcode-phien-test-[A-Za-z0-9]{8}\z') "throwaway dir: $bt"
    $w = New-World 'real3'
    [IO.File]::WriteAllText((Join-Path $w.U '.fcode\config.json'), (@{ instabox = $RealIb; box = 'coder'; syncRepos = @() } | ConvertTo-Json -Compress))
    try {
      $n1 = Get-Random -Minimum 100000 -Maximum 199999; $n2 = $n1 + 1   # sleep lengths unique to this run: the process check sees only ours
      [void](Invoke-RealBox "cat > $bt/stall.sh" $utf8.GetBytes("echo 'R TOKEN_OK'`nsleep $n1`n"))
      [void](Invoke-RealBox "cat > $bt/stallterm.sh" $utf8.GetBytes("trap '' TERM`necho 'R TOKEN_OK'`nsleep $n2`n"))
      foreach ($c in @(@{ S = 'stall.sh'; Code = 124 }, @{ S = 'stallterm.sh'; Code = 137 })) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Fcode $w @('add', 'owner/repo') @{ FCODE_ADD_SCRIPT = "$bt/$($c.S)"; FCODE_ADD_TIMEOUT_S = '2'; FCODE_ADD_KILL_AFTER_S = '2' }
        Ok ($sw.Elapsed.TotalSeconds -lt 90) "returned in $([int]$sw.Elapsed.TotalSeconds) s"
        Eq $r.Code 1 $r.Out; Ok ($r.Out -match "chạy quá 10 phút nên đã bị dừng \(mã $($c.Code)\)") ("$($c.S): told; out: " + $r.Out)
      }
      $bp = '[' + $bt.Substring(0, 1) + ']' + $bt.Substring(1)   # [/]tmp/...: the grep never matches its own command line
      Eq (Invoke-RealBox "ps -eo args | grep -c '$bp/stall\|[s]leep $n1\|[s]leep $n2'") '0' 'no process left on the box'
    } finally { [void](Invoke-RealBox "rm -rf $bt; echo ok") }
  }
}
T 'e2e: equal-length sessions with other content are reported and left alone' {
  $w = New-World 'e2e8'
  [void](New-Item -ItemType Directory -Path (Join-Path $w.U 'Desktop\other'), (Join-Path $w.U 'Desktop\notonbox') -Force)
  $l = New-Sess $w.LS '77777777-eqln' $w.LP @('aaa'); $b = New-Sess $w.BS '77777777-eqln' $w.BP @('bbb'); Set-Age $b 650
  $lb = Read-Bytes $l; $bb = Read-Bytes $b
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Ok ($r.Out -match 'phiên 77777777 đã khác nhau ở hai máy, giữ nguyên cả hai') ("reported; out: " + $r.Out)
  Eq ([Convert]::ToBase64String((Read-Bytes $l))) ([Convert]::ToBase64String($lb)) 'laptop copy untouched'
  Eq ([Convert]::ToBase64String((Read-Bytes $b))) ([Convert]::ToBase64String($bb)) 'box copy untouched'
}
T 'e2e: auto run v2: no ssh while the box is down; one sync when it just started; then only when the last ssh is 40+ min old; failures wait for the next slot; manual always runs' {
  $w = New-World 'e2e9'
  [void](New-Item -ItemType Directory -Path (Join-Path $w.U 'Desktop\other'), (Join-Path $w.U 'Desktop\notonbox') -Force)
  $auto = { param($e = @{}) Invoke-Fcode $w @('phien', '--tu-dong') $e }
  $log = Join-Path $w.U '.fcode\phien.log'
  $logText = { if (Test-Path $log) { (Get-Content $log -Raw) } else { '' } }
  $onBox = { param($n) Test-Path (Join-Path $w.BS (Split-Path (Get-ChildItem $w.LS -Filter "*$n.jsonl").FullName -Leaf)) }
  [void](New-Sess $w.LS '11111111-aut1' $w.LP @('a'))
  # box not running: no ssh at all
  $r = & $auto @{ FAKE_BOX_STATE = 'suspended' }; Eq $r.Code 0; Eq (SshCount $w) 0 'suspended: no ssh'; Eq (Get-AutoState $w).boxRunning $false
  # box just started: one sync now
  $r = & $auto; Eq $r.Code 0 $r.Out
  $n1 = SshCount $w; Ok ($n1 -gt 0) 'just started: ssh'
  Ok ((& $logText) -match 'đồng bộ vì: box vừa chạy') 'reason logged'; Ok (& $onBox 'aut1') 'it synced'
  Ok (((ConvertTo-Epoch (Get-Date)) - (Get-AutoState $w).lastSshAt) -lt 180) 'last ssh time recorded'
  # running, last ssh a few minutes ago: no ssh, even with a laptop change
  [void](New-Sess $w.LS '22222222-aut2' $w.LP @('a'))
  $r = & $auto; Eq (SshCount $w) $n1 'right after: no ssh'
  Ok ((& $logText) -match 'dưới 40') 'skip reason logged'
  Set-AutoState $w $true 39; $r = & $auto; Eq (SshCount $w) $n1 '39 min: no ssh'
  Ok (-not (& $onBox 'aut2')) 'a laptop change alone does not open ssh before the slot'
  # 41 min: ssh, and it carries the change
  Set-AutoState $w $true 41; $r = & $auto; Eq $r.Code 0 $r.Out
  $n2 = SshCount $w; Ok ($n2 -gt $n1) '41 min: ssh'; Ok (& $onBox 'aut2') 'the change went with it'
  Ok ((& $logText) -match 'đồng bộ vì: lần mở ssh trước đã cách 41 phút') 'slot reason logged'
  $r = & $auto; Eq (SshCount $w) $n2 'quiet again right after'
  # a session that was being written (busy) is picked up at the next slot, a box session is pulled at the next slot
  $busy = New-Sess $w.LS '33333333-busy' $w.LP @('a'); [IO.File]::SetLastWriteTimeUtc($busy, [DateTime]::UtcNow)
  [void](New-Sess $w.BS '44444444-box1' $w.BP @('b'))
  Set-AutoState $w $true 41; $r = & $auto; Ok ((SshCount $w) -gt $n2) 'slot: ssh'
  Ok (-not (& $onBox 'busy')) 'busy session skipped this time'
  Ok (Test-Path (Join-Path $w.LS (Split-Path (Get-ChildItem $w.BS -Filter '*box1.jsonl').FullName -Leaf))) 'the box session was pulled in the slot'
  Set-Age $busy 600; Set-AutoState $w $true 41; $r = & $auto
  Ok (& $onBox 'busy') 'the session that was busy is synced at the next slot'
  # a failure waits for the next slot (no fast retry)
  [void](New-Sess $w.LS '55555555-aut5' $w.LP @('a'))
  Set-AutoState $w $true 41; $r = & $auto @{ FAKE_SSH_FAIL = '1' }; Eq $r.Code 1
  Ok (((ConvertTo-Epoch (Get-Date)) - (Get-AutoState $w).lastSshAt) -lt 180) 'a failed attempt counts as the last ssh'
  Eq ((Get-Content (Join-Path $w.U 'AppData\Local\fcode\phien-status.json') -Raw | ConvertFrom-Json).ok) $false 'failure recorded'
  $n3 = SshCount $w; $r = & $auto; Eq (SshCount $w) $n3 'after a failure: no fast retry'
  Set-AutoState $w $true 41; $r = & $auto; Eq $r.Code 0 $r.Out; Ok (& $onBox 'aut5') 'the next slot retried and copied'
  # box went away and came back: sync once at once, whatever the last ssh time
  $n4 = SshCount $w; $r = & $auto @{ FAKE_BOX_STATE = 'suspended' }; Eq (SshCount $w) $n4 'suspended: no ssh'
  $r = & $auto; Ok ((SshCount $w) -gt $n4) 'box running again: ssh at once'
  # manual runs always run
  $n5 = SshCount $w; $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0; Ok ((SshCount $w) -gt $n5) 'manual run: ssh'
  Ok ((Get-AutoState $w).PSObject.Properties.Name.Count -eq 2) 'state holds only boxRunning + lastSshAt'
  Ok (-not (Test-Path (Join-Path $w.U 'AppData\Local\fcode\phien-auto.json.part'))) 'no leftovers'
}
T 'e2e: a manual run waits for the auto-run lock; an auto run that finds the lock busy opens no ssh' {
  $w = New-World 'e2e10'
  [void](New-Item -ItemType Directory -Path (Join-Path $w.U 'Desktop\other'), (Join-Path $w.U 'Desktop\notonbox') -Force)
  $ls = New-Sess $w.LS '66666666-lock' $w.LP @('a')
  $mx = New-Object Threading.Mutex($false, $env:FCODE_PHIEN_LOCK); Ok ($mx.WaitOne(0)) 'the test holds the lock'
  try {
    Set-AutoState $w $true 41
    $n0 = SshCount $w; $r = Invoke-Fcode $w @('phien', '--tu-dong'); Eq $r.Code 0; Eq (SshCount $w) $n0 'lock busy: the auto run opens no ssh'
    # manual run in a background job while the lock is held
    $set = @{ USERPROFILE = $w.U; LOCALAPPDATA = (Join-Path $w.U 'AppData\Local'); FCODE_PHIEN_BOXENV = ('HOME=' + ($w.BH -replace '\\', '/') + ' FCODE_CFG=' + ($w.Cfg -replace '\\', '/')); FAKE_SSH_LOG = $w.Log; TEMP = (Join-Path $w.U 'AppData\Local\Temp'); TMP = (Join-Path $w.U 'AppData\Local\Temp') }
    $save = @{}; foreach ($k in $set.Keys) { $save[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $set[$k]) }
    try { $job = Start-Job -ScriptBlock { param($fc) & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fc phien 2>&1 | Out-String } -ArgumentList $Fcode }
    finally { foreach ($k in $save.Keys) { [Environment]::SetEnvironmentVariable($k, $(if ($null -eq $save[$k]) { [NullString]::Value } else { $save[$k] })) } }
    Start-Sleep -Seconds 7
    Eq $job.State 'Running' 'the manual run is waiting for the lock'
    Eq (SshCount $w) $n0 'and has opened no ssh yet'
    $mx.ReleaseMutex()
    [void](Receive-Job $job -Wait -AutoRemoveJob)
    Ok ((SshCount $w) -gt $n0) 'after the lock was released the manual run went on'
    Ok (Test-Path (Join-Path $w.BS (Split-Path $ls -Leaf))) 'and synced'
  } finally { try { $mx.ReleaseMutex() } catch { }; $mx.Dispose() }
}
T 'P3: box blob names are indexed by hex (a blob with an extension is not re-sent)' {
  $h1 = 'a1' * 32; $h2 = 'b2' * 32
  $b = Get-PhienBoxBlobSet @($h1, "$h2.png", 'junk', "$h1.webp")
  Eq $b.Count 2; Ok ($b.ContainsKey($h1) -and $b.ContainsKey($h2)) 'by hex'; Ok (-not $b.ContainsKey("$h2.png")) 'not by file name'
}
T 'P3: Copy-OmpSession copies exactly the planned size, never what was written after the scan' {
  $d = Join-Path $Root 'sz'; $f = New-Sess $d 'sz000001' 'C:\p' @('a', 'b', 'c', 'd')
  $all = Read-Bytes $f; $planned = $all.Length - 45
  $o = Join-Path $d 'out1.bin'; [void](Copy-OmpSession $f $o '' '' $planned)
  $got = Read-Bytes $o; Eq $got.Length $planned; Ok ([Linq.Enumerable]::SequenceEqual([byte[]]$got, [byte[]]($all[0..($planned - 1)]))) 'exact prefix'
  $o2 = Join-Path $d 'out2.bin'; [void](Copy-OmpSession $f $o2 'C:\p' '/data/workspace/p' $planned)   # with the cwd rewrite: planned + delta
  Eq (Read-Bytes $o2).Length ($planned + '/data/workspace/p'.Length - 'C:\\p'.Length)
  $o3 = Join-Path $d 'out3.bin'; [void](Copy-OmpSession $f $o3 '' '' ($all.Length + 1000)); Eq (Read-Bytes $o3).Length $all.Length 'a larger plan never invents bytes'
  # bigger than the 256 KB head buffer
  $big = Join-Path $d 'big.jsonl'; [IO.File]::WriteAllBytes($big, [byte[]](,[byte]65 * 700000))
  $o4 = Join-Path $d 'out4.bin'; [void](Copy-OmpSession $big $o4 '' '' 300000); Eq (Read-Bytes $o4).Length 300000
  $o5 = Join-Path $d 'out5.bin'; [void](Copy-OmpSession $big $o5 '' '' 100); Eq (Read-Bytes $o5).Length 100
}
T 'P3: box program `get` cuts each file at the planned size and skips a file that shrank' {
  $h = Join-Path $Root 'pg\home'; $enc = 'E-test'; $sd = "$h\.omp\agent\sessions\$enc"
  $f = New-Sess $sd 'gg000001' '/x' @('a', 'b', 'c'); $name = Split-Path $f -Leaf; $size = (Read-Bytes $f).Length
  $save = @{}; foreach ($k in 'HOME', 'FCODE_CFG', 'PI_CODING_AGENT_DIR') { $save[$k] = [Environment]::GetEnvironmentVariable($k) }
  [Environment]::SetEnvironmentVariable('HOME', $h); [Environment]::SetEnvironmentVariable('FCODE_CFG', "$Root\nocfg.json"); [Environment]::SetEnvironmentVariable('PI_CODING_AGENT_DIR', [NullString]::Value)
  try {
    foreach ($case in @(@{ n = 'cut'; planned = $size - 30; want = $size - 30 }, @{ n = 'whole'; planned = $size; want = $size }, @{ n = 'shrunk'; planned = $size + 50; want = -1 })) {
      $req = Join-Path $Root "pg-$($case.n).json"; $out = Join-Path $Root "pg-$($case.n).bin"
      [IO.File]::WriteAllText($req, (@{ files = @(@{ enc = $enc; rel = $name; size = $case.planned }); blobs = @() } | ConvertTo-Json -Compress -Depth 5), $utf8)
      cmd /c "python -I `"$PyFile`" get < `"$req`" > `"$out`""
      $bytes = Read-Bytes $out; $mk = $utf8.GetBytes("FCODE-TAR`n"); $pos = -1
      for ($i = 0; $i -lt 200 -and $pos -lt 0; $i++) { if ($bytes[$i] -eq $mk[0] -and [Linq.Enumerable]::SequenceEqual([byte[]]$bytes[$i..($i + $mk.Length - 1)], [byte[]]$mk)) { $pos = $i + $mk.Length } }
      Ok ($pos -ge 0) "tar marker ($($case.n))"
      $tar = Join-Path $Root "pg-$($case.n).tar"; [IO.File]::WriteAllBytes($tar, [byte[]]$bytes[$pos..($bytes.Length - 1)])
      $x = Join-Path $Root "pg-$($case.n)-x"; [void](New-Item -ItemType Directory -Path $x -Force); & tar -xf $tar -C $x
      $got = Join-Path $x "sessions\$enc\$name"
      if ($case.want -lt 0) { Ok (-not (Test-Path $got)) 'a shrunk file is left out' } else { Eq (Read-Bytes $got).Length $case.want "size ($($case.n))" }
    }
  } finally { foreach ($k in $save.Keys) { [Environment]::SetEnvironmentVariable($k, $(if ($null -eq $save[$k]) { [NullString]::Value } else { $save[$k] })) } }
}
T 'P3: prefix check uses native SHA-256 ranges: right answers and fast on big files' {
  $d = Join-Path $Root 'pf'; [void](New-Item -ItemType Directory -Path $d -Force)
  $hdr = $utf8.GetBytes('{"type":"title","v":1}' + "`n" + '{"type":"session","version":3,"id":"i","cwd":"/x"}' + "`n")
  $rnd = New-Object Random 7; $chunk = New-Object byte[] 1048576
  $mk = { param($path, $mb, $flip) $fs = [IO.File]::Create($path); try { $fs.Write($hdr, 0, $hdr.Length); $r = New-Object Random 7; for ($i = 0; $i -lt $mb; $i++) { $c = New-Object byte[] 1048576; $r.NextBytes($c); if ($flip -ge 0 -and $i -eq $flip) { $c[5] = ($c[5] + 1) % 256 }; $fs.Write($c, 0, $c.Length) } } finally { $fs.Dispose() } }
  $s30 = Join-Path $d 's30.jsonl'; $l40 = Join-Path $d 'l40.jsonl'; $bad = Join-Path $d 'bad.jsonl'
  & $mk $s30 30 -1; & $mk $l40 40 -1; & $mk $bad 40 29
  $t0 = Get-Date; $ok = Test-PhienPrefix $s30 $l40; $sec = ((Get-Date) - $t0).TotalSeconds
  Ok $ok 'a real prefix'; Ok ($sec -lt 6) "30 MB compared in $([Math]::Round($sec, 1)) s"
  Ok (-not (Test-PhienPrefix $s30 $bad)) 'a changed byte inside the compared range'
  Ok (Test-PhienPrefix $l40 $l40) 'a file is a prefix of itself'
}
T 'P3: temp names are unique per run and no part file is left behind' {
  $a = New-PhienPartName 'C:\x\f.jsonl'; $b = New-PhienPartName 'C:\x\f.jsonl'
  Ok ($a -ne $b) 'two names differ'; Ok ($a -match '\.fcode-part-\d+-[0-9a-f]{6}$') "pattern: $a"
  $S = Join-Path $Root 'pn\S'; $D = Join-Path $Root 'pn\D'
  $f = New-Sess $S 'pn000001' '/d/p' @('a'); $dst = Join-Path $D (Split-Path $f -Leaf)
  [void](New-Item -ItemType Directory -Path $D -Force); [IO.File]::WriteAllText("$dst.fcode-part", 'stale part of an older version, locked')
  $lock = [IO.File]::Open("$dst.fcode-part", 'Open', 'ReadWrite', 'None')
  try { Eq (Install-PhienFile $f $dst '/d/p' 'C:\q' (ConvertTo-Epoch (Get-Date))) 'new' 'a stale/locked old-style part name no longer gets in the way' } finally { $lock.Dispose() }
}
T 'e2e: git starts tracking a note fcode had placed and excluded: sync stops for it, only fcode''s own exclude line is given back, nothing is deleted' {
  $w = New-World 'e2e13'
  [void](New-Item -ItemType Directory -Path (Join-Path $w.U 'Desktop\other'), (Join-Path $w.U 'Desktop\notonbox') -Force)
  New-GitDir $w.LP; New-GitDir $w.BP
  foreach ($d in $w.LP, $w.BP) { [IO.File]::WriteAllText("$d\.git\info\exclude", "# my own comment`n/user-ignored.txt`n") }
  Put-File "$($w.LP)\HANDOFF-lap.md" 'from laptop'          # laptop -> box (box side gets an exclude line from fcode)
  Put-File "$($w.BP)\HANDOFF-box.md" 'from box'            # box -> laptop (laptop side gets an exclude line from fcode)
  Put-File "$($w.LP)\TASK.md" 'task'; [IO.File]::AppendAllText("$($w.BP)\.git\info\exclude", "/TASK.md`n")   # box already ignores TASK.md by the user's own line
  $boxUser = [IO.File]::ReadAllBytes("$($w.BP)\.git\info\exclude")
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Ok ((Get-Content "$($w.BP)\.git\info\exclude" -Raw) -match '(?m)^# fcode\r?\n/HANDOFF-lap\.md\r?$') 'box exclude has our pair'
  Ok ((Get-Content "$($w.LP)\.git\info\exclude" -Raw) -match '(?m)^# fcode\r?\n/HANDOFF-box\.md\r?$') 'laptop exclude has our pair'
  Ok ((Get-Content "$($w.BP)\.git\info\exclude" -Raw) -notmatch '# fcode\r?\n/TASK\.md') 'no marker above the user''s own /TASK.md'
  $st = Get-Content (Join-Path $w.U 'AppData\Local\fcode\handoff-state.json') -Raw | ConvertFrom-Json
  Eq @($st.PSObject.Properties | Where-Object { $_.Name -like 'exclude:*' }).Count 0 'r6: no ownership record (the pair is the ownership)'
  # B: the laptop starts tracking HANDOFF-lap.md and TASK.md (upstream began to carry them)
  Git-Commit $w.LP @('HANDOFF-lap.md', 'TASK.md')
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Ok ($r.Out -match 'ghi chú HANDOFF-lap\.md giờ do git theo dõi \(trên laptop\): bản cũ trên box xóa được') ("one line for the user; out: " + $r.Out)
  Ok ($r.Out -notmatch 'TASK\.md giờ do git') 'no line for a name whose exclude was not ours'
  Ok (Bytes-Eq ([IO.File]::ReadAllBytes("$($w.BP)\.git\info\exclude")) $boxUser) 'our pair removed on the box; every other byte is what the user had'
  Eq (Get-Content "$($w.BP)\HANDOFF-lap.md" -Raw) 'from laptop' 'the old copy is not deleted'
  $st = Get-Content (Join-Path $w.U 'AppData\Local\fcode\handoff-state.json') -Raw | ConvertFrom-Json
  Ok ($null -eq $st.PSObject.Properties['proj/HANDOFF-lap.md']) 'state forgets the name'
  $sj = Get-Content (Join-Path $w.U 'AppData\Local\fcode\phien-status.json') -Raw | ConvertFrom-Json
  Eq (@($sj.notes.released) -join ',') 'proj/HANDOFF-lap.md' 'status lists it'
  $m = Invoke-Fcode $w @(); Ok ($m.Out -match 'Ghi chú dự án: git đã theo dõi 1 file') ("menu warns; out: " + $m.Out)
  # it is no longer synced: a change on the tracked side does not travel, and the line is not printed again
  Put-File "$($w.LP)\HANDOFF-lap.md" 'changed on the laptop (tracked now)'
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Eq (Get-Content "$($w.BP)\HANDOFF-lap.md" -Raw) 'from laptop' 'no longer synced'
  Ok ($r.Out -notmatch 'giờ do git theo dõi') 'said once'
  # A: the box starts tracking HANDOFF-box.md
  Git-Commit $w.BP @('HANDOFF-box.md')
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Ok ($r.Out -match 'ghi chú HANDOFF-box\.md giờ do git theo dõi \(trên box\): bản cũ trên laptop xóa được') ("line for the laptop side; out: " + $r.Out)
  Eq ([IO.File]::ReadAllText("$($w.LP)\.git\info\exclude")) "# my own comment`n/user-ignored.txt`n" 'our pair removed on the laptop, the other lines stay'
  Eq (Get-Content "$($w.LP)\HANDOFF-box.md" -Raw) 'from box' 'laptop copy not deleted'
}
T 'e2e: sending is split into <= 50 MB batches (one ssh each); a failing batch leaves the rest for the next run' {
  $w = New-World 'e2e11'
  [void](New-Item -ItemType Directory -Path (Join-Path $w.U 'Desktop\other'), (Join-Path $w.U 'Desktop\notonbox') -Force)
  $a = New-Sess $w.LS 'aaaa1111-big1' $w.LP @('a'); Grow-Sess $a 30
  $b = New-Sess $w.LS 'bbbb2222-big2' $w.LP @('b'); Grow-Sess $b 30
  $c = New-Sess $w.LS 'cccc3333-sml3' $w.LP @('c'); Grow-Sess $c 10
  $delta = $w.BP.Length - (ConvertTo-JsonStr $w.LP).Length + 2
  $n0 = SshCount $w; $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Eq ((SshCount $w) - $n0) 3 'one scan + two put streams (30 MB | 30+10 MB)'
  foreach ($x in $a, $b, $c) { $bx = Join-Path $w.BS (Split-Path $x -Leaf); Ok (Test-Path $bx) "on the box: $(Split-Path $x -Leaf)"; Eq (Get-Item $bx).Length ((Get-Item $x).Length + $delta) 'complete' }
  # a failing second batch: the first one is already on the box, the rest comes with the next run
  $w2 = New-World 'e2e12'
  [void](New-Item -ItemType Directory -Path (Join-Path $w2.U 'Desktop\other'), (Join-Path $w2.U 'Desktop\notonbox') -Force)
  $p1 = New-Sess $w2.LS 'aaaa1111-fst1' $w2.LP @('a'); Grow-Sess $p1 30
  $p2 = New-Sess $w2.LS 'bbbb2222-snd2' $w2.LP @('b'); Grow-Sess $p2 30
  $r = Invoke-Fcode $w2 @('phien') @{ FAKE_SSH_FAIL_AFTER = [string]((SshCount $w2) + 2) }
  Eq $r.Code 1 $r.Out
  Ok (Test-Path (Join-Path $w2.BS (Split-Path $p1 -Leaf))) 'first batch arrived'
  Ok (-not (Test-Path (Join-Path $w2.BS (Split-Path $p2 -Leaf)))) 'second batch did not'
  Ok ($r.Out -match 'gửi phiên lên box không thành công') 'told'
  $r = Invoke-Fcode $w2 @('phien'); Eq $r.Code 0 $r.Out
  Ok (Test-Path (Join-Path $w2.BS (Split-Path $p2 -Leaf))) 'the next run sent the rest'
  Ok (-not (Get-ChildItem (Join-Path $w2.U 'AppData\Local\Temp') -Directory -Filter 'fcode-phien-*' -ErrorAction SilentlyContinue)) 'staging dirs are removed'
}
# ============================== round 3: by file, dependencies first, top last ==============================
function Put-Big([string]$Path, [int]$MB, [int]$Seed) {
  [void](New-Item -ItemType Directory -Path (Split-Path $Path) -Force)
  $c = New-Object byte[] 1048576; (New-Object Random $Seed).NextBytes($c)
  $fs = [IO.File]::Create($Path); try { for ($i = 0; $i -lt $MB; $i++) { $c[0] = [byte]$i; $fs.Write($c, 0, $c.Length) } } finally { $fs.Dispose() }
  Set-Age $Path 600
}
function Sha([string]$p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
function PutBytes($w) { $f = "$($w.Log).bytes"; if (Test-Path $f) { @(Get-Content $f | Where-Object { $_ -like 'put *' } | ForEach-Object { [long](($_ -split ' ')[1]) }) } else { @() } }
function Calls($w, [string]$Cmd) { if (Test-Path $w.Log) { @(Get-Content $w.Log | Where-Object { $_ -eq "ssh $Cmd" }).Count } else { 0 } }
function Body([string]$p) { $b = Read-Bytes $p; $o = Get-PhienOff $p; [Convert]::ToBase64String($b, $o, $b.Length - $o) }
function Parts([string]$d) { @(Get-ChildItem -LiteralPath $d -Recurse -Force -Filter '*.fcode-part*' -ErrorAction SilentlyContinue).Count }

T 'planner: an orphan dir on the receiver is inventory only (files it has are skipped, never a source); a busy dependency holds the top back' {
  $L = Join-Path $Root 'orp\L'; $B = Join-Path $Root 'orp\B'
  $s1 = New-Sess $L 'orp00001' 'C:\p' @('a'); $b1 = (Split-Path $s1 -Leaf).Replace('.jsonl', '')
  Put-File (Join-Path $L "$b1\f1.log") 'one'; Put-File (Join-Path $L "$b1\f2.log") 'two'
  [void](New-Item -ItemType Directory -Path (Join-Path $B $b1) -Force); Copy-Item (Join-Path $L "$b1\f1.log") (Join-Path $B "$b1\f1.log")   # an earlier batch got f1 there
  Put-File (Join-Path $B '2026-10-25T16-18-25-246Z_orp00002\x.log') 'box orphan'                                                         # orphan with no session anywhere
  $s3 = New-Sess $L 'orp00003' 'C:\p' @('a'); $b3 = (Split-Path $s3 -Leaf).Replace('.jsonl', '')
  Put-File (Join-Path $L "$b3\ok.log") 'ok'; Put-File (Join-Path $L "$b3\busy.log") 'being written'; [IO.File]::SetLastWriteTimeUtc((Join-Path $L "$b3\busy.log"), [DateTime]::UtcNow)
  $ls = Get-PhienLocalScan $L; $rs = Get-PhienLocalScan $B
  Ok (@($rs | Where-Object { $_.orphan }).Count -eq 2) 'the box scan lists both orphan dirs'
  $n = ConvertTo-Epoch (Get-Date)
  $p = Get-PhienPlan $ls $rs 'E' @{} $L $n $n 30
  $i1 = @($p.Put | Where-Object Id -eq 'orp00001')[0]
  Ok ($i1.Top) 'top of orp00001 goes'; Eq (($i1.Files | ForEach-Object { Split-Path $_ -Leaf }) -join ',') 'f2.log' 'only the file the receiver lacks'
  Eq ((@($i1.Deps | ForEach-Object { Split-Path $_.r -Leaf }) | Sort-Object) -join ',') 'f1.log,f2.log' 'the top names every dependency'
  Ok (-not ($p.Put + $p.Get | Where-Object Id -eq 'orp00002')) 'an orphan is never a source'
  $i3 = @($p.Put | Where-Object Id -eq 'orp00003')[0]
  Ok (-not $i3.Top) 'a busy dependency holds the top back'; Eq (($i3.Files | ForEach-Object { Split-Path $_ -Leaf }) -join ',') 'ok.log' 'the ready file still goes'
  Eq $p.Deferred 1; Ok (@($p.Notes | Where-Object { $_ -like '*orp00003*file chính để lần sau*' }).Count -eq 1) 'told'
}
T 'planner: equal tops do not prove the blobs: a missing blob is copied either way; missing on both is incomplete, never "same"' {
  $L = Join-Path $Root 'eqb\L'; $B = Join-Path $Root 'eqb\B'
  $h1 = '11' * 32; $h2 = '22' * 32; $h3 = '33' * 32
  foreach ($x in @(@('eqb00001', $h1), @('eqb00002', $h2), @('eqb00003', $h3))) { [void](New-Sess $L $x[0] 'C:\p' @('a', "blob:sha256:$($x[1])")); [void](New-Sess $B $x[0] '/d/p' @('a', "blob:sha256:$($x[1])")) }
  [void](New-Sess $L 'eqb00004' 'C:\p' @('a')); [void](New-Sess $B 'eqb00004' '/d/p' @('a'))
  $n = ConvertTo-Epoch (Get-Date)
  $p = Get-PhienPlan (Get-PhienLocalScan $L) (Get-PhienLocalScan $B) 'E' @{} $L $n $n 30 @{ $h1 = $true } @{ $h2 = $true }
  Eq ((@($p.Put | ForEach-Object { "$($_.Id):$($_.Top):$($_.Blobs -join '')" })) -join ' ') "eqb00001:False:$h1" 'the laptop blob goes to the box'
  Eq ((@($p.Get | ForEach-Object { "$($_.Id):$($_.Top):$($_.Blobs -join '')" })) -join ' ') "eqb00002:False:$h2" 'the box blob comes to the laptop'
  Eq $p.Incomplete 1 'missing on both sides'; Ok (@($p.Notes | Where-Object { $_ -like '*eqb00003*thiếu 1 file đính kèm*' }).Count -eq 1) 'reported'
  Eq $p.Same 1 'only eqb00004 counts as the same'
}
T 'notes planner: a name in origin/<default> counts as tracked (never synced) and gives back fcode''s own exclude line' {
  $now = ConvertTo-Epoch (Get-Date)
  $p = Get-PhienNotePlan 'proj' (NS @((Nt 'U.md' 'u1')) @() $true @('U.md')) (NS @()) @{} $now $now; Eq ($p.Put.Count + $p.Get.Count) 0 'in the laptop upstream'
  $p = Get-PhienNotePlan 'proj' (NS @()) (NS @((Nt 'V.md' 'v1')) @() $true @('V.md')) @{} $now $now; Eq ($p.Put.Count + $p.Get.Count) 0 'in the box upstream'
  $p = Get-PhienNotePlan 'proj' (NS @((Nt 'W.md' 'w1'))) (NS @() @() $true @('W.md')) @{ 'exclude:laptop:proj/W.md' = '1' } $now $now
  Eq (($p.Release | ForEach-Object { "$($_.Name):$($_.TrackedOn):$($_.OldOn)" }) -join ',') 'W.md:origin:laptop' 'release (upstream only, no index tracks it)'
  $p = Get-PhienNotePlan 'proj' (NS @((Nt 'X.md' 'x1')) @('X.md')) (NS @() @() $true @('X.md')) @{ 'exclude:laptop:proj/X.md' = '1' } $now $now
  Eq $p.Release.Count 0 'the laptop index tracks it itself: its copy is not an old one'
}
function New-W2([string]$Name) { $w = New-World $Name; [void](New-Item -ItemType Directory -Path (Join-Path $w.U 'Desktop\other'), (Join-Path $w.U 'Desktop\notonbox') -Force); $w }
# one session over many files: top + 7 x 8 MB tool logs + a nested subagent .jsonl, and two referenced blobs (1 MB each)
function New-BigSess([string]$SessDir, [string]$BlobDir, [string]$Cwd, [string]$Id, [string[]]$Msgs, [string]$Nl) {
  $h1 = 'd1' * 32; $h2 = 'e2' * 32
  $top = New-Sess $SessDir $Id $Cwd (@($Msgs) + @("blob:sha256:$h1"))
  $sd = $top.Replace('.jsonl', '')
  [void](New-Sess (Join-Path $sd 'subagents') 'nest0001' ($Cwd + $Nl + 'x') @('n', "blob:sha256:$h2"))
  for ($i = 1; $i -le 7; $i++) { Put-Big (Join-Path $sd "tool-$i.log") 8 $i }
  Put-Big (Join-Path $BlobDir ($h1 + '.png')) 1 21; Put-Big (Join-Path $BlobDir $h2) 1 22
  [pscustomobject]@{ Top = $top; Dir = $sd; H1 = $h1; H2 = $h2 }
}
T 'e2e: a session > 50 MB over many files, laptop -> box: a cut batch keeps the earlier ones, nothing half-done is placed, the top waits; the next run sends only the rest' {
  $w = New-W2 'e2e20'
  $s = New-BigSess $w.LS $w.LBlobs $w.LP 'b1g00000-0000-7000-8000-000000000001' @('a') '\'
  $name = Split-Path $s.Top -Leaf; $bt = Join-Path $w.BS $name; $bd = $bt.Replace('.jsonl', '')
  $r = Invoke-Fcode $w @('phien') @{ FAKE_SSH_CUT = 'put:2:4000000:cut' }
  Eq $r.Code 1 $r.Out; Ok ($r.Out -match 'gửi phiên lên box không thành công') ("told; out: " + $r.Out)
  Ok (-not (Test-Path $bt)) 'the top is not placed'; Ok (-not (Test-Path ($bt.Replace('.jsonl', '.fcode-origin')))) 'no origin either'
  Ok ((Test-Path (Join-Path $w.BBlobs ($s.H1 + '.png'))) -and (Test-Path (Join-Path $w.BBlobs $s.H2))) 'the blobs of batch 1 are there'
  $have = @(1..7 | Where-Object { Test-Path (Join-Path $bd "tool-$_.log") })
  Ok ($have.Count -ge 1 -and $have.Count -lt 7) "batch 1 stayed, batch 2 did not (have: $($have -join ','))"
  foreach ($i in $have) { Eq (Sha (Join-Path $bd "tool-$i.log")) (Sha (Join-Path $s.Dir "tool-$i.log")) "tool-$i whole"; Eq (Mt1 (Join-Path $bd "tool-$i.log")) (Mt1 (Join-Path $s.Dir "tool-$i.log")) "tool-$i mtime" }
  Ok (-not (Test-Path (Join-Path $bd 'subagents'))) 'the nested .jsonl of the cut batch is not there'
  Eq (Parts $w.BH) 0 'no part files'
  $n0 = @(PutBytes $w).Count
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  $pb = @(PutBytes $w); Eq ($pb.Count - $n0) 1 'one more put'
  Ok ($pb[-1] -lt ((7 - $have.Count) * 8MB + 4MB)) "only the rest was sent ($($pb[-1]) bytes)"
  for ($i = 1; $i -le 7; $i++) { Eq (Sha (Join-Path $bd "tool-$i.log")) (Sha (Join-Path $s.Dir "tool-$i.log")) "tool-$i body"; Eq (Mt1 (Join-Path $bd "tool-$i.log")) (Mt1 (Join-Path $s.Dir "tool-$i.log")) "tool-$i mtime" }
  $nb = @(Get-ChildItem (Join-Path $bd 'subagents') -Filter '*.jsonl')[0].FullName; $nl = @(Get-ChildItem (Join-Path $s.Dir 'subagents') -Filter '*.jsonl')[0].FullName
  Ok ((Latin $nb).Contains('"cwd":"' + $w.BP + '/x"')) 'nested header rewritten'; Eq (Body $nb) (Body $nl) 'nested body'; Eq (Mt1 $nb) (Mt1 $nl) 'nested mtime'
  Ok ((Latin $bt).Contains('"cwd":"' + $w.BP + '"')) 'top header rewritten'; Eq (Body $bt) (Body $s.Top) 'top body'; Eq (Mt1 $bt) (Mt1 $s.Top) 'top mtime'
  Eq ((Get-Content ($bt.Replace('.jsonl', '.fcode-origin')) -Raw).Trim()) 'laptop' 'origin'
  Ok (@($pb | Where-Object { $_ -gt 52428800 }).Count -eq 0) "every put stream <= 50 MB with the tar overhead ($($pb -join ','))"
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0; Ok ($r.Out -match '0 file gửi lên box, 0 file lấy về laptop \(hai bên đã giống nhau\)') ("then a no-op; out: " + $r.Out)
}
T 'e2e: a session > 50 MB over many files, box -> laptop: a cut batch keeps the earlier ones, the old laptop top stays unchanged, the next run fetches only the rest' {
  $w = New-W2 'e2e21'
  $id = 'b1g00000-0000-7000-8000-000000000002'
  $old = New-Sess $w.LS $id $w.LP @('a')                                                    # the laptop has the start of the conversation
  $s = New-BigSess $w.BS $w.BBlobs $w.BP $id @('a', 'b') '/'                                # the box went on, with many new files
  $oldBytes = [Convert]::ToBase64String((Read-Bytes $old)); $ld = $old.Replace('.jsonl', '')
  $r = Invoke-Fcode $w @('phien') @{ FAKE_SSH_CUT = 'get:2:4000000:cut' }
  Eq $r.Code 1 $r.Out; Ok ($r.Out -match 'lấy phiên từ box về không thành công') ("told; out: " + $r.Out)
  Eq ([Convert]::ToBase64String((Read-Bytes $old))) $oldBytes 'the laptop top is unchanged'
  Ok ((Test-Path (Join-Path $w.LBlobs ($s.H1 + '.png'))) -and (Test-Path (Join-Path $w.LBlobs $s.H2))) 'blobs of batch 1 arrived'
  $have = @(1..7 | Where-Object { Test-Path (Join-Path $ld "tool-$_.log") })
  Ok ($have.Count -ge 1 -and $have.Count -lt 7) "batch 1 stayed, batch 2 did not (have: $($have -join ','))"
  foreach ($i in $have) { Eq (Sha (Join-Path $ld "tool-$i.log")) (Sha (Join-Path $s.Dir "tool-$i.log")) "tool-$i whole" }
  Eq (Parts $w.U) 0 'no part files'
  $g0 = Calls $w 'get'
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Eq ((Calls $w 'get') - $g0) 1 'one more get'
  $gb = @(Get-Content "$($w.Log).bytes" | Where-Object { $_ -like 'get *' } | ForEach-Object { [long](($_ -split ' ')[2]) })
  Ok ($gb[-1] -lt ((7 - $have.Count) * 8MB + 4MB)) "only the rest came ($($gb[-1]) bytes)"
  Ok (@($gb | Where-Object { $_ -gt 52428800 }).Count -eq 0) "every get stream <= 50 MB ($($gb -join ','))"
  for ($i = 1; $i -le 7; $i++) { Eq (Sha (Join-Path $ld "tool-$i.log")) (Sha (Join-Path $s.Dir "tool-$i.log")) "tool-$i body"; Eq (Mt1 (Join-Path $ld "tool-$i.log")) (Mt1 (Join-Path $s.Dir "tool-$i.log")) "tool-$i mtime" }
  $nl = @(Get-ChildItem (Join-Path $ld 'subagents') -Filter '*.jsonl')[0].FullName; $nb = @(Get-ChildItem (Join-Path $s.Dir 'subagents') -Filter '*.jsonl')[0].FullName
  Ok ((Latin $nl).Contains('"cwd":' + (ConvertTo-JsonStr ($w.LP + '\x')))) 'nested header rewritten'; Eq (Body $nl) (Body $nb) 'nested body'
  Ok ((Latin $old).Contains('"cwd":' + (ConvertTo-JsonStr $w.LP))) 'top header rewritten'; Eq (Body $old) (Body $s.Top) 'top body = the box conversation'; Eq (Mt1 $old) (Mt1 $s.Top) 'top mtime'
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0; Ok ($r.Out -match '0 file gửi lên box, 0 file lấy về laptop \(hai bên đã giống nhau\)') ("then a no-op; out: " + $r.Out)
}
T 'e2e: a blob that cannot be placed holds the top back (box and laptop); after the fix the next run completes, then a no-op' {
  $w = New-W2 'e2e22'
  $h1 = 'f3' * 32; $h2 = 'f4' * 32
  $ls = New-Sess $w.LS '12121212-blbf' $w.LP @('a', "blob:sha256:$h1"); Put-File (Join-Path $ls.Replace('.jsonl', '') '1.log') 'log'
  Put-Big (Join-Path $w.LBlobs $h1) 1 31
  $bs = New-Sess $w.BS '34343434-blbf' $w.BP @('b', "blob:sha256:$h2"); Put-Big (Join-Path $w.BBlobs $h2) 1 32
  # a directory squats on each blob's name at the receiver: the blob cannot be placed there
  [void](New-Item -ItemType Directory (Join-Path $w.BBlobs $h1)); [void](New-Item -ItemType Directory (Join-Path $w.LBlobs $h2))
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  $bt = Join-Path $w.BS (Split-Path $ls -Leaf); $lt = Join-Path $w.LS (Split-Path $bs -Leaf)
  Ok (-not (Test-Path $bt)) 'box: the top waits'; Ok (Test-Path (Join-Path $w.BS ((Split-Path $ls -Leaf).Replace('.jsonl', '') + '\1.log'))) 'box: its other file is placed'
  Ok (-not (Test-Path $lt)) 'laptop: the top waits'
  Ok ($r.Out -match '2 phiên chưa đặt file chính vì file đi kèm chưa đủ') ("told; out: " + $r.Out)
  Ok ($r.Out -notmatch 'hai bên đã giống nhau') 'never "same"'
  Remove-Item (Join-Path $w.BBlobs $h1), (Join-Path $w.LBlobs $h2)
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Ok ((Test-Path $bt) -and (Test-Path (Join-Path $w.BBlobs $h1))) 'box complete'; Ok ((Test-Path $lt) -and (Test-Path (Join-Path $w.LBlobs $h2))) 'laptop complete'
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0; Ok ($r.Out -match '0 file gửi lên box, 0 file lấy về laptop \(hai bên đã giống nhau\)') ("no-op; out: " + $r.Out)
}
T 'e2e: a lost acknowledgement (the box placed everything, the answer never came) is recovered by the next run, then a no-op' {
  $w = New-W2 'e2e23'
  $h1 = 'a7' * 32
  $ls = New-Sess $w.LS '56565656-nack' $w.LP @('a', "blob:sha256:$h1"); Put-File (Join-Path $ls.Replace('.jsonl', '') '1.log') 'log'; Put-Big (Join-Path $w.LBlobs $h1) 1 41
  $r = Invoke-Fcode $w @('phien') @{ FAKE_SSH_CUT = 'put:1:0:noack' }; Eq $r.Code 1 $r.Out
  $bt = Join-Path $w.BS (Split-Path $ls -Leaf); Ok (Test-Path $bt) 'the box did place it'
  $p0 = Calls $w 'put'
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out; Eq ((Calls $w 'put') - $p0) 0 'nothing to send again'
  Ok ($r.Out -match '0 file gửi lên box, 0 file lấy về laptop \(hai bên đã giống nhau\)') ("recovered; out: " + $r.Out)
  Eq (Body $bt) (Body $ls) 'complete'; Ok (Test-Path (Join-Path $w.BBlobs $h1)) 'blob there'
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0; Ok ($r.Out -match 'hai bên đã giống nhau') 'no-op'
}
T 'e2e: auto run: a failed or unreadable `instabox ls` opens no ssh and leaves phien-auto.json unchanged; the next good check inside 40 min opens none either' {
  $w = New-W2 'e2e24'
  [void](New-Sess $w.LS '78787878-lsfl' $w.LP @('a'))
  Set-AutoState $w $true 10
  $sp = Join-Path $w.U 'AppData\Local\fcode\phien-auto.json'; $before = [IO.File]::ReadAllText($sp)
  foreach ($m in 'fail', 'bad', 'nostate') {
    $r = Invoke-Fcode $w @('phien', '--tu-dong') @{ FAKE_LS = $m }; Eq $r.Code 0 $r.Out
    Eq (SshCount $w) 0 "ls $($m): no ssh"; Eq ([IO.File]::ReadAllText($sp)) $before "ls $($m): state unchanged"
  }
  Ok ((Get-Content (Join-Path $w.U '.fcode\phien.log') -Raw) -match 'không đọc được trạng thái box') 'logged'
  $r = Invoke-Fcode $w @('phien', '--tu-dong'); Eq $r.Code 0 $r.Out
  Eq (SshCount $w) 0 'recovery 10 min after the last ssh: still no ssh (no false "box just started")'
  Ok ((Get-AutoState $w).boxRunning -and [Math]::Abs((Get-AutoState $w).lastSshAt - ($before | ConvertFrom-Json).lastSshAt) -lt 1) 'last ssh time kept'
}
T 'e2e: the auto deadline holds while stdin is blocked: the stalled call is killed, no later batch starts, earlier work stays' {
  $w = New-W2 'e2e25'
  $a = New-Sess $w.LS 'aaaa1111-dln1' $w.LP @('a'); Grow-Sess $a 30
  $b = New-Sess $w.LS 'bbbb2222-dln2' $w.LP @('b'); Grow-Sess $b 30
  Set-AutoState $w $true 41
  $t0 = Get-Date
  $r = Invoke-Fcode $w @('phien', '--tu-dong') @{ FCODE_PHIEN_TIMEOUT = '25'; FAKE_SSH_CUT = 'put:1:0:stall' }
  $sec = ((Get-Date) - $t0).TotalSeconds
  Eq $r.Code 1 $r.Out; Ok ($sec -lt 45) "ended at the deadline ($([Math]::Round($sec)) s, stall is 60 s)"
  Eq (Calls $w 'put') 1 'no batch is started after the deadline'
  Ok (-not (Test-Path (Join-Path $w.BS (Split-Path $a -Leaf))) -and -not (Test-Path (Join-Path $w.BS (Split-Path $b -Leaf)))) 'nothing half-sent is placed'
  Ok ((Get-Content (Join-Path $w.U '.fcode\phien.log') -Raw) -match 'gửi phiên lên box không thành công') 'logged'
  Ok (-not (Get-ChildItem (Join-Path $w.U 'AppData\Local\Temp') -Directory -Filter 'fcode-phien-*' -ErrorAction SilentlyContinue)) 'staging removed'
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Ok ((Test-Path (Join-Path $w.BS (Split-Path $a -Leaf))) -and (Test-Path (Join-Path $w.BS (Split-Path $b -Leaf)))) 'the next run sends both'
}
function New-Origin([string]$Bare, [string]$Branch = 'main') {
  $ErrorActionPreference = 'Continue'
  & git -c init.defaultBranch=$Branch init -q --bare $Bare 2>&1 | Out-Null
  & git -c init.defaultBranch=$Branch init -q "$Bare-work" 2>&1 | Out-Null
  Put-File "$Bare-work\README.md" 'r'; Git-Commit "$Bare-work" @('README.md'); & git -C "$Bare-work" push -q $Bare "HEAD:$Branch" 2>&1 | Out-Null
}
function Push-Origin([string]$Bare, [string]$Name, [string]$Text, [string]$Branch = 'main') { $ErrorActionPreference = 'Continue'; Put-File "$Bare-work\$Name" $Text; Git-Commit "$Bare-work" @($Name); & git -C "$Bare-work" push -q $Bare "HEAD:$Branch" 2>&1 | Out-Null }
function Fetch-Origin([string]$Dir, [string]$Bare) { $ErrorActionPreference = 'Continue'; & git -C $Dir remote add origin $Bare 2>&1 | Out-Null; & git -C $Dir fetch -q origin 2>&1 | Out-Null }
T 'e2e: a note that origin/<default> already tracks is never synced (laptop and box), and fcode''s own exclude line is given back once upstream tracks it' {
  $w = New-W2 'e2e26'
  New-GitDir $w.LP; New-GitDir $w.BP
  # each side has its own origin, so a name only one side's origin tracks proves that side's check on its own
  $bl = Join-Path $w.W 'origin-l.git'; $bb = Join-Path $w.W 'origin-b.git'; New-Origin $bl; New-Origin $bb
  Push-Origin $bl 'HANDOFF-up.md' 'upstream'; Push-Origin $bb 'HANDOFF-up2.md' 'upstream 2'
  Put-File "$($w.BP)\HANDOFF-rel.md" 'from box'                       # box -> laptop (the laptop gets fcode's exclude line)
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Ok ((Get-Content "$($w.LP)\.git\info\exclude" -Raw) -match '(?m)^/HANDOFF-rel\.md\r?$') 'laptop exclude has our line'
  Fetch-Origin $w.LP $bl; Fetch-Origin $w.BP $bb
  Ok ((Get-PhienUpstreamNotes $w.LP) -ccontains 'HANDOFF-up.md') 'laptop scan sees the upstream name'
  Put-File "$($w.LP)\HANDOFF-up.md" 'laptop copy, untracked here'; Put-File "$($w.BP)\HANDOFF-up2.md" 'box copy, untracked there'
  Push-Origin $bl 'HANDOFF-rel.md' 'now in git'; Push-Origin $bb 'HANDOFF-rel.md' 'now in git'; Fetch-Origin $w.LP $bl; Fetch-Origin $w.BP $bb
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Ok (-not (Test-Path "$($w.BP)\HANDOFF-up.md")) 'laptop note tracked upstream: not sent to the box'
  Ok (-not (Test-Path "$($w.LP)\HANDOFF-up2.md")) 'box note tracked upstream: not fetched to the laptop'
  Ok ($r.Out -match 'ghi chú HANDOFF-rel\.md giờ do git theo dõi \(trên origin\): bản cũ trên laptop xóa được') ("release line; out: " + $r.Out)
  Ok ((Get-Content "$($w.LP)\.git\info\exclude" -Raw) -notmatch '(?m)^/HANDOFF-rel\.md\r?$') 'our line given back on the laptop'
  Eq (Get-Content "$($w.LP)\HANDOFF-rel.md" -Raw) 'from box' 'the old copy is not deleted'
}

# ============================== round 4: run order, leftovers, master fallback, sidecar order ==============================
function Get-PhienStat($w) { Get-Content (Join-Path $w.U 'AppData\Local\fcode\phien-status.json') -Raw | ConvertFrom-Json }
T 'e2e r4: a file > 50 MB that is cut every time goes last: the small sessions of both directions still sync, the status names it, a later good run finishes it' {
  $w = New-W2 'e2e30'
  $a = New-Sess $w.LS '0000000a-big1' $w.LP @('a'); Put-Big (Join-Path $a.Replace('.jsonl', '') 'huge.log') 60 51   # lowest id: planned first
  $b = New-Sess $w.LS 'ffffffff-sml1' $w.LP @('b')
  $c = New-Sess $w.BS 'cccccccc-box1' $w.BP @('c')
  foreach ($i in 1, 2) {
    $r = Invoke-Fcode $w @('phien') @{ FAKE_SSH_CUT = 'put:*:20000000:cut' }
    Eq $r.Code 1 $r.Out
    Ok (Test-Path (Join-Path $w.BS (Split-Path $b -Leaf))) "run $($i): the small laptop session after it is on the box"
    Ok (Test-Path (Join-Path $w.LS (Split-Path $c -Leaf))) "run $($i): the box-only session came to the laptop"
    Ok (-not (Test-Path (Join-Path $w.BS (Split-Path $a -Leaf)))) "run $($i): the big session's top waits"
    Ok ($r.Out -match 'phiên lớn: \S*huge\.log chưa chép xong') ("named; out: " + $r.Out)
    Ok (@(@((Get-PhienStat $w).unfinished) | Where-Object { $_ -like '*huge.log' }).Count -eq 1) 'unfinished in phien-status.json'
  }
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Ok (Test-Path (Join-Path $w.BS (Split-Path $a -Leaf))) 'a good run finishes it'; Eq @((Get-PhienStat $w).unfinished).Count 0 'status cleared'
}
T 'e2e r4: the same for a file > 50 MB on the box that is cut every time on the way down' {
  $w = New-W2 'e2e31'
  $a = New-Sess $w.BS '0000000b-big2' $w.BP @('a'); Put-Big (Join-Path $a.Replace('.jsonl', '') 'huge.log') 60 52
  $b = New-Sess $w.BS 'fffffffe-sml2' $w.BP @('b')
  $c = New-Sess $w.LS 'cccccccd-lap2' $w.LP @('c')
  $r = Invoke-Fcode $w @('phien') @{ FAKE_SSH_CUT = 'get:*:20000000:cut' }
  Eq $r.Code 1 $r.Out
  Ok (Test-Path (Join-Path $w.LS (Split-Path $b -Leaf))) 'the small box session came down'
  Ok (Test-Path (Join-Path $w.BS (Split-Path $c -Leaf))) 'the laptop session went up'
  Ok (-not (Test-Path (Join-Path $w.LS (Split-Path $a -Leaf)))) 'the big top waits'
  Ok ($r.Out -match 'phiên lớn: \S*huge\.log chưa chép xong') ("named; out: " + $r.Out)
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Ok (Test-Path (Join-Path $w.LS (Split-Path $a -Leaf))) 'a good run finishes it'
}
T 'e2e r4: a batch that fails on the box (not a lost connection) is recorded and the run goes on with the next batch' {
  $w = New-W2 'e2e32'
  $a = New-Sess $w.LS '1111aaaa-fl1' $w.LP @('a'); Grow-Sess $a 30
  $b = New-Sess $w.LS '2222bbbb-fl2' $w.LP @('b'); Grow-Sess $b 30
  $r = Invoke-Fcode $w @('phien') @{ FAKE_SSH_CUT = 'put:1:0:fail' }
  Eq $r.Code 1 $r.Out
  Eq (Calls $w 'put') 2 'the second batch is still sent'
  Eq (@($a, $b | Where-Object { Test-Path (Join-Path $w.BS (Split-Path $_ -Leaf)) }).Count) 1 'the second session is on the box'
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Eq (@($a, $b | Where-Object { Test-Path (Join-Path $w.BS (Split-Path $_ -Leaf)) }).Count) 2 'the next run sends the failed one'
}
T 'e2e r4: leftovers of a cut-off run older than 1 h are removed at the start on both sides; fresh ones and other files stay' {
  $w = New-W2 'e2e33'
  [void](New-Sess $w.LS '4444dddd-lft' $w.LP @('a'))
  $lt = Join-Path $w.U 'AppData\Local\Temp'; $bt = Join-Path $w.W 'boxtmp'
  [void](New-Item -ItemType Directory -Force -Path $lt, $bt, $w.BS, $w.LBlobs)
  $old = [DateTime]::UtcNow.AddHours(-2)
  $mk = { param([string]$p, [bool]$dir, [bool]$aged)
    $t = if ($aged) { $old } else { [DateTime]::UtcNow }
    if ($dir) { [void](New-Item -ItemType Directory -Force -Path $p); Put-File (Join-Path $p 'x.tar') 'x'; [IO.File]::SetLastWriteTimeUtc((Join-Path $p 'x.tar'), $t); [IO.Directory]::SetLastWriteTimeUtc($p, $t) }
    else { Put-File $p 'x'; [IO.File]::SetLastWriteTimeUtc($p, $t) } }
  # r6 Rule L: only fcode's complete names (laptop: fcode-phien-[<PID>-]<32hex>, <name>.fcode-part-<PID>-<6hex>; box: fcode-phien-<8>, the same part name)
  $h32 = 'ab' * 16; $lold = "fcode-phien-$h32"; $lnew = "fcode-phien-$PID-$h32"   # $PID: this test process, alive and older than the dir
  & $mk "$lt\$lold" $true $true; & $mk "$lt\$lnew" $true $false; & $mk "$lt\other-old" $true $true
  & $mk "$($w.LS)\x.jsonl.fcode-part-1-abcdef" $false $true; & $mk "$($w.LS)\y.jsonl.fcode-part-$PID-abcdef" $false $false
  & $mk "$($w.LBlobs)\.$('ab' * 32).fcode-part-3-abcdef" $false $true
  & $mk "$bt\fcode-phien-0ldaaaaa" $true $true; & $mk "$bt\fcode-phien-n3waaaaa" $true $false; & $mk "$bt\other-old" $true $true
  & $mk "$($w.BS)\z.jsonl.fcode-part-9-abcdef" $false $true; & $mk "$($w.BS)\w.jsonl.fcode-part-8-abcdef" $false $false
  $env0 = @{ FCODE_PHIEN_BOXENV = ('HOME=' + ($w.BH -replace '\\', '/') + ' FCODE_CFG=' + ($w.Cfg -replace '\\', '/') + ' TMPDIR=' + ($bt -replace '\\', '/')) }
  $r = Invoke-Fcode $w @('phien') $env0; Eq $r.Code 0 $r.Out
  Ok (-not (Test-Path "$lt\$lold")) 'laptop: old staging dir removed'; Ok (Test-Path "$lt\$lnew") 'laptop: fresh staging dir kept'; Ok (Test-Path "$lt\other-old") 'laptop: other names untouched'
  Ok (-not (Test-Path "$($w.LS)\x.jsonl.fcode-part-1-abcdef")) 'laptop: old part file removed'; Ok (Test-Path "$($w.LS)\y.jsonl.fcode-part-$PID-abcdef") 'laptop: fresh part file kept'
  Ok (-not (Test-Path "$($w.LBlobs)\.$('ab' * 32).fcode-part-3-abcdef")) 'laptop: old blob part removed'
  Ok (-not (Test-Path "$bt\fcode-phien-0ldaaaaa")) 'box: old staging dir removed'; Ok (Test-Path "$bt\fcode-phien-n3waaaaa") 'box: fresh staging dir kept'; Ok (Test-Path "$bt\other-old") 'box: other names untouched'
  Ok (-not (Test-Path "$($w.BS)\z.jsonl.fcode-part-9-abcdef")) 'box: old part file removed'; Ok (Test-Path "$($w.BS)\w.jsonl.fcode-part-8-abcdef") 'box: fresh part file kept'
}
function Set-NoOriginHead([string]$Dir) { $ErrorActionPreference = 'Continue'; & git -C $Dir remote set-head origin -d 2>&1 | Out-Null }
T 'e2e r4: origin/<default> falls back to origin/master when origin/HEAD is not set (laptop and box)' {
  $w = New-W2 'e2e34'
  New-GitDir $w.LP; New-GitDir $w.BP
  $bl = Join-Path $w.W 'om-l.git'; $bb = Join-Path $w.W 'om-b.git'; New-Origin $bl 'master'; New-Origin $bb 'master'
  Push-Origin $bl 'HANDOFF-m1.md' 'u' 'master'; Push-Origin $bb 'HANDOFF-m2.md' 'u' 'master'
  Fetch-Origin $w.LP $bl; Fetch-Origin $w.BP $bb; Set-NoOriginHead $w.LP; Set-NoOriginHead $w.BP
  Ok (-not (Test-Path "$($w.LP)\.git\refs\remotes\origin\HEAD") -and -not (Test-Path "$($w.BP)\.git\refs\remotes\origin\HEAD")) 'no origin/HEAD on either side'
  Ok ((Get-PhienUpstreamNotes $w.LP) -ccontains 'HANDOFF-m1.md') 'the laptop reads origin/master'
  Put-File "$($w.LP)\HANDOFF-m1.md" 'laptop copy'; Put-File "$($w.BP)\HANDOFF-m2.md" 'box copy'
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Ok (-not (Test-Path "$($w.BP)\HANDOFF-m1.md")) 'laptop note tracked on origin/master: not sent'
  Ok (-not (Test-Path "$($w.LP)\HANDOFF-m2.md")) 'box note tracked on origin/master: not fetched'
}
T 'e2e r4: the .fcode-origin sidecar is written only after the top is in place' {
  $w = New-W2 'e2e35'
  $a = New-Sess $w.LS '5555eeee-side' $w.LP @('a')
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  $bt = Join-Path $w.BS (Split-Path $a -Leaf); $sc = $bt.Replace('.jsonl', '.fcode-origin')
  Ok (Test-Path $sc) 'sidecar after a good placement'
  Remove-Item $sc; Add-Msgs $a @('b'); $before = Body $bt
  $fs = [IO.File]::Open($bt, 'Open', 'Read', 'ReadWrite')   # no delete sharing: the box program cannot replace the file
  try { $r = Invoke-Fcode $w @('phien') } finally { $fs.Dispose() }
  Eq $r.Code 1 $r.Out
  Ok (-not (Test-Path $sc)) 'no sidecar while the top could not be replaced'; Eq (Body $bt) $before 'top unchanged'
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Ok (Test-Path $sc) 'sidecar once the top is placed'
}
T 'r5: sidecar: a failed sidecar write never turns a placed top into failed; a missing sidecar is written when the top arrives equal' {
  $d = Join-Path $Root 'sc'; $src = New-Sess (Join-Path $d 'src') 'sc000001' '/x' @('a'); $dst = Join-Path $d ('dst\' + (Split-Path $src -Leaf))
  $drv = Join-Path $Root 'sc.py'
  [IO.File]::WriteAllText($drv, ("import os, runpy, sys`nm = runpy.run_path(sys.argv[1], run_name='x')`nsrc, dst, side = sys.argv[2], sys.argv[3], sys.argv[4]`n" +
    "def bad():`n    raise OSError('no room')`n" +
    "def good():`n    if not os.path.isfile(side):`n        open(side, 'w').write('laptop\n')`n" +
    "print(m['place_file'](src, dst, bad))`nprint(os.path.isfile(side))`nos.utime(dst, (1, 1))`nprint(m['place_file'](src, dst, good))`nprint(os.path.isfile(side))`n"))
  $out = @(python -I $drv $PyFile $src $dst $dst.Replace('.jsonl', '.fcode-origin'))
  Eq ($out -join ',') 'new,False,same,True' 'placed despite the sidecar error; written later when equal'
}
T 'e2e r5: a session whose blob is > 50 MB is placed in one good run (its top goes after the blob)' {
  $w = New-W2 'e2e37'
  $h = 'f7' * 32
  $a = New-Sess $w.LS '7777aaaa-bblob' $w.LP @('a', "blob:sha256:$h")
  Put-Big (Join-Path $w.LBlobs ($h + '.bin')) 60 37
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Ok (Test-Path (Join-Path $w.BBlobs ($h + '.bin'))) 'the blob is on the box'
  Ok (Test-Path (Join-Path $w.BS (Split-Path $a -Leaf))) ("the top is placed in the same run; out: " + $r.Out)
}
T 'e2e r5: the notes exclude rides on the first normal put batch, not on an oversized one that is cut every time' {
  $w = New-W2 'e2e38'; New-GitDir $w.LP; New-GitDir $w.BP
  Put-File "$($w.LP)\HANDOFF-same.md" 'same text'; Put-File "$($w.BP)\HANDOFF-same.md" 'same text'
  $a = New-Sess $w.LS '0000000c-big3' $w.LP @('a'); Put-Big (Join-Path $a.Replace('.jsonl', '') 'huge.log') 60 53
  $r = Invoke-Fcode $w @('phien') @{ FAKE_SSH_CUT = 'put:*:20000000:cut' }
  Eq $r.Code 1 $r.Out
  $ex = Join-Path $w.BP '.git\info\exclude'
  Ok ((Test-Path $ex) -and ((Get-Content $ex -Raw) -match '(?m)^/HANDOFF-same\.md\r?$')) ("exclude on the box; out: " + $r.Out)
}
T 'e2e r4: phien matches a laptop folder to a box project by its GitHub repo when the folder name differs; a box project with no laptop folder is only noted' {
  $w = New-World 'e2e36'
  $ld = Join-Path $w.U 'Desktop\New folder (2)'; New-GitDir $ld; & git -C $ld remote add origin https://github.com/Owner/Proj.git
  New-GitDir $w.BP; & git -C $w.BP remote add origin git@github-proj:owner/proj.git
  [IO.File]::WriteAllText($w.Cfg, (@{ projects = @{ proj = $w.BP; zeta = ($w.W -replace '\\', '/') + '/boxws/zeta' } } | ConvertTo-Json -Compress))
  [IO.File]::WriteAllText((Join-Path $w.U '.fcode\config.json'), (@{ instabox = $Cmd; box = 'coder'; syncRepos = @($ld) } | ConvertTo-Json -Compress))
  $lsd = Join-Path $w.U ('.omp\agent\sessions\' + (Get-OmpEncodedDir $ld $w.U (Join-Path $w.U 'AppData\Local\Temp')))
  $a = New-Sess $lsd 'abcdabcd-rep1' $ld @('a')
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  $bt = Join-Path $w.BS (Split-Path $a -Leaf)
  Ok (Test-Path $bt) ("synced into box project proj; out: " + $r.Out); Ok ((Latin $bt).Contains('"cwd":"' + $w.BP + '"')) 'cwd = the box project dir'
  Ok ($r.Out -match 'project trên box chưa có trên laptop: zeta') 'the new box project is noted'
  Eq (@((Get-PhienStat $w).newProjects) -join ',') 'zeta' 'and recorded in the status'
  $r = Invoke-Fcode $w @('phien', '--tu-dong'); Eq $r.Code 0 $r.Out   # the auto run never asks
  # r5: an exact name always wins over a repo match (box {aaa, proj} with the same origin; laptop Desktop\proj)
  $w2 = New-World 'e2e36b'
  New-GitDir $w2.LP; & git -C $w2.LP remote add origin https://github.com/owner/proj.git
  $aaa = ($w2.W -replace '\\', '/') + '/boxws/aaa'
  foreach ($d in $w2.BP, $aaa) { New-GitDir ($d -replace '/', '\'); & git -C $d remote add origin https://github.com/owner/proj.git }
  [IO.File]::WriteAllText($w2.Cfg, (@{ projects = @{ proj = $w2.BP; aaa = $aaa } } | ConvertTo-Json -Compress))
  [IO.File]::WriteAllText((Join-Path $w2.U '.fcode\config.json'), (@{ instabox = $Cmd; box = 'coder'; syncRepos = @($w2.LP) } | ConvertTo-Json -Compress))
  $a2 = New-Sess $w2.LS 'abcdabcd-rep2' $w2.LP @('a')
  $r = Invoke-Fcode $w2 @('phien'); Eq $r.Code 0 $r.Out
  Ok (Test-Path (Join-Path $w2.BS (Split-Path $a2 -Leaf))) ("the exact name proj gets the folder; out: " + $r.Out)
  Eq @(Get-ChildItem (Join-Path $w2.BH '.omp\agent\sessions') -Recurse -File -Filter '*.jsonl').Count 1 'aaa gets nothing'
  Ok ($r.Out -notmatch '== aaa') 'aaa is not synced'
}
T 'r5: box `projects` never sends a token or password from the origin URL; the repo still matches' {
  $d = Join-Path $Root 'pj\ws\tok'; New-GitDir $d; & git -C $d remote add origin 'https://x-access-token:ghp_TEST@github.com/o/r.git'
  $cfg = Join-Path $Root 'pj\cfg.json'; [IO.File]::WriteAllText($cfg, (@{ projects = @{ tok = $d } } | ConvertTo-Json -Compress))
  $save = @{}; foreach ($k in 'HOME', 'FCODE_CFG') { $save[$k] = [Environment]::GetEnvironmentVariable($k) }
  [Environment]::SetEnvironmentVariable('HOME', (Join-Path $Root 'pj\home')); [Environment]::SetEnvironmentVariable('FCODE_CFG', $cfg)
  try { $out = (cmd /c "python -I `"$PyFile`" projects < NUL") | Out-String } finally { foreach ($k in $save.Keys) { [Environment]::SetEnvironmentVariable($k, $(if ($null -eq $save[$k]) { [NullString]::Value } else { $save[$k] })) } }
  Ok ($out -notmatch 'ghp_TEST|x-access-token') "no secret in the answer: $out"
  $j = ($out.Trim() -replace '^FCODE-JSON ', '') | ConvertFrom-Json
  Eq $j.projects[0].origin 'https://github.com/o/r.git' 'origin without userinfo'; Eq $j.projects[0].repo 'o/r' 'repo still matches'
}

# ============================== round 4: fcode add (installed box script) and fcode sync (find / ask / clone) ==============================
function ConvertTo-Posix([string]$p) { '/' + $p.Substring(0, 1).ToLowerInvariant() + ($p.Substring(2) -replace '\\', '/') }
function New-FakeAdd([string]$Path, [string]$Body) { [IO.File]::WriteAllText($Path, ((("#!/bin/bash`n" + $Body + "`n") -replace "`r`n", "`n")), $utf8) }
T 'add: fcode add runs the script installed on the box (token path: no key step), with the repo and name as arguments' {
  $w = New-World 'add1'; $fa = Join-Path $w.W 'fake-add.sh'; $log = ($w.W -replace '\\', '/') + '/add.log'
  New-FakeAdd $fa ('echo "ARGS $1 $2" >> "' + $log + '"; for c in TOKEN_OK READ_OK CLONED HOOK_OK WRITE_OK CFG_ADDED V_BRANCH_OK RULES_NO; do echo "R $c"; done; exit 0')
  $r = Invoke-Fcode $w @('add', 'Owner/Repo-X') @{ FCODE_ADD_SCRIPT = (ConvertTo-Posix $fa) }
  Eq $r.Code 0 $r.Out
  Ok ($r.Out -match 'Box dùng khoá GitHub sẵn có \(token\)' -and $r.Out -match 'Xong\. Mở app FCode') ("token path told; out: " + $r.Out)
  Ok ($r.Out -notmatch 'Deploy keys|settings/keys') 'no key step'
  Ok ($r.Out -match '\[2\] Box đọc được repo: OK' -and $r.Out -notmatch 'qua khoá SSH') 'token path: neutral read line'
  Eq ((Get-Content ($log -replace '/', '\')) -join '|') 'ARGS Owner/Repo-X repo-x' 'arguments'
  Ok ($r.Out -match 'chạy fcode sync') 'points to fcode sync for the laptop copy'
}
T 'add: a box without the installed script is told to update the box' {
  $w = New-World 'add2'
  $r = Invoke-Fcode $w @('add', 'owner/repo') @{ FCODE_ADD_SCRIPT = (ConvertTo-Posix (Join-Path $w.W 'missing\fcode-add.sh')) }
  Eq $r.Code 1 $r.Out
  Ok ($r.Out -match 'box chưa có script thêm dự án' -and $r.Out -match 'cd ~/fcode-src && git pull && bash install\.sh') ("told; out: " + $r.Out)
  Eq (@(Get-Content $w.Log | Where-Object { $_ -eq 'ssh script' }).Count) 1 'no retry'
}
T 'add: NEED_KEY shows the key and the steps, waits for Enter, then the retry succeeds' {
  $w = New-World 'add3'; $fa = Join-Path $w.W 'fake-add.sh'; $cnt = ($w.W -replace '\\', '/') + '/n'
  New-FakeAdd $fa ('n=$(cat "' + $cnt + '" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "' + $cnt + '"' + "`n" +
    'if [ $n -eq 1 ]; then echo "R KEY_NEW"; echo "R ALIAS_ADDED"; echo "R PUBKEY ssh-ed25519 AAAAfakekey"; echo "R NEED_KEY"; exit 40; fi' + "`n" +
    'for c in KEY_EXISTS ALIAS_EXISTS READ_OK CLONED HOOK_OK WRITE_OK CFG_ADDED; do echo "R $c"; done; exit 0')
  $r = Invoke-Fcode $w @('add', 'owner/repo') @{ FCODE_ADD_SCRIPT = (ConvertTo-Posix $fa) } "`n"
  Eq $r.Code 0 $r.Out
  Ok ($r.Out -match 'Khoá của box \(copy cả dòng\): ssh-ed25519 AAAAfakekey' -and $r.Out -match 'settings/keys/new' -and $r.Out -match 'Xong\.') ("key flow; out: " + $r.Out)
  Eq (@(Get-Content $w.Log | Where-Object { $_ -eq 'ssh script' }).Count) 2 'retried once'
}
T 'add r5: exit 11 (folder exists or unsafe), exit 24 (HOOK_FAIL) stop without a retry; CLEANUP_FAIL names the exact branch and the add still succeeds' {
  $w = New-World 'add4'; $fa = Join-Path $w.W 'fake-add.sh'
  $cases = @(
    @{ B = 'echo "R DIR_EXISTS /data/workspace/repo"; exit 11'; Code = 1; Rx = 'Thư mục repo đã có trên box \(hoặc không an toàn\) — chọn tên khác: fcode add owner/repo <tên-khác>' },
    @{ B = 'echo "R DIR_UNSAFE /data/workspace/repo"; exit 11'; Code = 1; Rx = 'Thư mục repo đã có trên box \(hoặc không an toàn\)' },
    @{ B = 'echo "R TOKEN_OK"; echo "R READ_OK"; echo "R CLONED"; echo "R HOOK_FAIL verify"; exit 24'; Code = 1; Rx = 'không cài được chốt chặn push lên main[\s\S]*chi tiết: verify' },
    @{ B = 'for c in TOKEN_OK READ_OK CLONED HOOK_OK; do echo "R $c"; done; echo "R CLEANUP_FAIL refs/heads/box/fcode-add-check-repo-1700000000-42-7"; for c in WRITE_OK CFG_ADDED V_BRANCH_OK; do echo "R $c"; done; exit 30'; Code = 1
       Rx = 'không cho box xoá nhánh thử box/fcode-add-check-repo-1700000000-42-7 \(refs/heads/box/fcode-add-check-repo-1700000000-42-7\)\. Hãy xoá nhánh này trên GitHub' })
  foreach ($c in $cases) {
    Remove-Item $w.Log -ErrorAction SilentlyContinue
    New-FakeAdd $fa $c.B
    $r = Invoke-Fcode $w @('add', 'owner/repo') @{ FCODE_ADD_SCRIPT = (ConvertTo-Posix $fa) }
    Eq $r.Code $c.Code $r.Out; Ok ($r.Out -match $c.Rx) ("message; out: " + $r.Out)
    Eq (@(Get-Content $w.Log | Where-Object { $_ -eq 'ssh script' }).Count) 1 'no retry'
    Ok ($r.Out -notmatch 'dùng lại đúng nhánh này') 'no reuse hint'
  }
  Ok ($r.Out -match 'Đã thêm nhưng có 1 mục cần xem lại') 'cleanup failure: added with a warning'
}
T 'add r6: re-add (only CFG_EXISTS) is success; CFG_WARN is a warning; exits 25 / 26 stop without a retry; codes that a retry cannot fix never say "chạy lại là an toàn"' {
  $w = New-World 'add5'; $fa = Join-Path $w.W 'fake-add.sh'
  $cases = @(
    @{ B = 'echo "R CFG_EXISTS"; exit 0'; Code = 0; Rx = "'repo' đã có trên box, không cần thêm" },
    @{ B = 'for c in TOKEN_OK READ_OK CLONED HOOK_OK WRITE_OK CFG_ADDED; do echo "R $c"; done; echo "R CFG_WARN fsync"; for c in V_BRANCH_OK V_PR_OK V_HOOK_OK V_SERVER_OK RULES_NO; do echo "R $c"; done; exit 30'; Code = 1; Rx = 'cảnh báo: đã thêm vào cấu hình FCode[\s\S]*Đã thêm nhưng có 1 mục cần xem lại' },
    @{ B = 'echo "R TOKEN_OK"; echo "R READ_OK"; echo "R CLONED"; echo "R CRED_FAIL config"; exit 25'; Code = 1; Rx = 'box không ghi được cấu hình đăng nhập GitHub cho repo này' },
    @{ B = 'echo "R URL_REWRITE rewrite"; exit 26'; Code = 1; Rx = 'cấu hình git trên box đang chuyển hướng địa chỉ GitHub \(insteadOf / pushInsteadOf / pushurl\) — cần gỡ trên box rồi chạy lại' },
    @{ B = 'echo "R BAD_ARGS"; exit 2'; Code = 1; Rx = 'tên repo hoặc tên project không hợp lệ' },
    @{ B = 'echo "R KEY_FAIL"; exit 20'; Code = 1; Rx = 'box không tạo được khoá SSH' },
    @{ B = 'echo "R SOMETHING_NEW x"; exit 77'; Code = 1; Rx = 'Chưa xong \(mã 77\)\. Xem thông báo ở trên\.' })
  foreach ($c in $cases) {
    Remove-Item $w.Log -ErrorAction SilentlyContinue
    New-FakeAdd $fa $c.B
    $r = Invoke-Fcode $w @('add', 'owner/repo') @{ FCODE_ADD_SCRIPT = (ConvertTo-Posix $fa) }
    Eq $r.Code $c.Code $r.Out; Ok ($r.Out -match $c.Rx) ("message; out: " + $r.Out)
    Eq (@(Get-Content $w.Log | Where-Object { $_ -eq 'ssh script' }).Count) 1 'no retry'
    Ok ($r.Out -notmatch 'chạy lại là an toàn' -or $c.B -match 'CFG_WARN') ("no false retry promise; out: " + $r.Out)
  }
}
T 'add r7: the box script runs under the same timeout as the server (600 s, KILL 30 s later); a stalled script is stopped and told as a safe retry' {
  $runAst = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$FcodeAddRun' }, $true)
  $FcodeAddRun = $null; Invoke-Expression $runAst.Extent.Text
  Ok ($FcodeAddRun -match '(?m)^exec env -u INSTABOX_API_KEY timeout --kill-after="\$\{FCODE_ADD_KILL_AFTER_S:-30\}" "\$\{FCODE_ADD_TIMEOUT_S:-600\}" bash "\$s" "\$@"$') ("wrapper: " + $FcodeAddRun)
  $w = New-World 'add6'; $fa = Join-Path $w.W 'fake-add.sh'
  foreach ($c in @(@{ B = "echo 'R TOKEN_OK'`nsleep 297"; Code = 124 }, @{ B = "trap '' TERM`necho 'R TOKEN_OK'`nsleep 297"; Code = 137 })) {
    New-FakeAdd $fa $c.B
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Fcode $w @('add', 'owner/repo') @{ FCODE_ADD_SCRIPT = (ConvertTo-Posix $fa); FCODE_ADD_TIMEOUT_S = '2'; FCODE_ADD_KILL_AFTER_S = '2' }
    Ok ($sw.Elapsed.TotalSeconds -lt 60) "returned in $([int]$sw.Elapsed.TotalSeconds) s"
    Eq $r.Code 1 $r.Out; Ok ($r.Out -match "chạy quá 10 phút nên đã bị dừng \(mã $($c.Code)\)\. Chạy lại là an toàn: fcode add owner/repo repo") ("told; out: " + $r.Out)
  }
}
T 'add r7: the test-only limit overrides take positive integers only (0 would mean no limit for timeout)' {
  $save = @{}; foreach ($k in 'FCODE_ADD_TIMEOUT_S', 'FCODE_ADD_KILL_AFTER_S') { $save[$k] = [Environment]::GetEnvironmentVariable($k) }
  try {
    foreach ($c in @(@('2', '3', "FCODE_ADD_TIMEOUT_S=2`nFCODE_ADD_KILL_AFTER_S=3`n"), @('0', '0', ''), @('00', '05', ''), @('1x', '-1', ''), @('123456', ' 2', ''), @('99999', $null, "FCODE_ADD_TIMEOUT_S=99999`n"))) {
      [Environment]::SetEnvironmentVariable('FCODE_ADD_TIMEOUT_S', $c[0]); [Environment]::SetEnvironmentVariable('FCODE_ADD_KILL_AFTER_S', $c[1])
      Eq (Get-FcodeAddLimitVars) $c[2] "timeout [$($c[0])] kill-after [$($c[1])]"
    }
  } finally { foreach ($k in $save.Keys) { [Environment]::SetEnvironmentVariable($k, $(if ($null -eq $save[$k]) { [NullString]::Value } else { $save[$k] })) } }
}
T 'sync r6: the 60 s `projects` deadline starts after the box is awake (a slow wake does not eat it)' {
  $w = New-World 'syn4'
  $r = Invoke-Fcode $w @('sync') @{ FAKE_WAKE_SLEEP = '5'; FCODE_PHIEN_TIMEOUT = '3' }
  Ok ($r.Out -notmatch 'không đọc được danh sách project trên box') ("the project list was read; out: " + $r.Out)
  Eq (@(Get-Content $w.Log | Where-Object { $_ -eq 'ssh projects' }).Count) 1 'asked once'
}
T 'sync: box projects missing on the laptop are found (OneDrive Desktop, names with spaces and brackets, several matches) or cloned (default folder, empty folder); wrong origin and non-git folders are refused; config keeps its other keys' {
  $w = New-World 'syn1'
  $gh = Join-Path $w.W 'github-test'; $own = Join-Path $gh 'owner'; [void](New-Item -ItemType Directory -Force -Path $own)
  foreach ($n in 'alpha', 'beta', 'gamma', 'delta') { New-Origin (Join-Path $own "$n.git") }
  $bw = ($w.W -replace '\\', '/') + '/boxws'; $proj = @{}
  foreach ($n in 'alpha', 'beta', 'gamma', 'delta') { $d = "$bw/$n"; New-GitDir ($d -replace '/', '\'); & git -C $d remote add origin "git@github-$($n):owner/$n.git"; $proj[$n] = $d }
  [IO.File]::WriteAllText($w.Cfg, (@{ projects = $proj } | ConvertTo-Json -Compress))
  $desk = Join-Path $w.U 'OneDrive\Desktop'; $docs = Join-Path $w.U 'Documents'; [void](New-Item -ItemType Directory -Force -Path $desk, $docs)
  $ErrorActionPreference = 'Continue'
  & git clone -q (Join-Path $own 'alpha.git') "$desk\New folder (2)\alpha" 2>&1 | Out-Null
  & git clone -q (Join-Path $own 'beta.git') "$desk\beta" 2>&1 | Out-Null
  & git clone -q (Join-Path $own 'beta.git') "$desk\New folder\beta [old]" 2>&1 | Out-Null
  $ErrorActionPreference = 'Stop'
  $wrong = Join-Path $w.W 'elsewhere\wrong'; New-GitDir $wrong; & git -C $wrong remote add origin https://github.com/owner/other.git
  $nongit = Join-Path $w.W 'elsewhere\notgit'; Put-File "$nongit\a.txt" 'x'
  $empty = Join-Path $w.W 'elsewhere\work [x]\gamma'; [void](New-Item -ItemType Directory -Force -Path $empty)
  $cfgFile = Join-Path $w.U '.fcode\config.json'
  [IO.File]::WriteAllText($cfgFile, "{`r`n  `"instabox`": $(ConvertTo-JsonStr $Cmd),`r`n  `"box`": `"coder`",`r`n  `"syncRepos`": [],`r`n  `"ipaTag`": `"latest`"`r`n}`r`n")
  $env0 = @{ FCODE_DESKTOP = $desk; FCODE_DOCUMENTS = $docs; FCODE_GITHUB_BASE = $gh }
  # box order: alpha (one found), beta (two found: pick 2), delta (none: Enter = default), gamma (none: wrong origin, not git, then an empty folder)
  $r = Invoke-Fcode $w @('sync') $env0 ("`n2`n`n" + "$wrong`n$nongit`nC:\a|b`n$empty`n")
  Eq $r.Code 0 $r.Out
  Ok ($r.Out -match 'đường dẫn không hợp lệ\. Chọn thư mục khác') 'a bad pasted path is refused and asked again (Windows PowerShell 5.1)'
  Eq ([IO.File]::ReadAllBytes($cfgFile)[0]) 0x7B 'no BOM before: none written'
  Ok ($r.Out -match [regex]::Escape("Đã tìm bản có sẵn trong: $desk (4 cấp)")) ("where it looked; out: " + $r.Out)
  Ok ($r.Out -match [regex]::Escape("Đã có owner/alpha ở $desk\New folder (2)\alpha")) 'one found: offered'
  Ok ($r.Out -match 'Có 2 bản owner/beta') 'several found: listed'
  Ok ($r.Out -match 'đây là repo owner/other, không phải owner/gamma') 'wrong origin refused'
  Ok ($r.Out -match 'thư mục này không phải git') 'non-git folder refused'
  $c = Get-Content $cfgFile -Raw
  Ok ($c -match '"ipaTag": "latest"' -and $c -match '"box": "coder"') 'other keys and their layout kept'
  $sr = @(($c | ConvertFrom-Json).syncRepos)
  Eq (($sr | Sort-Object) -join '|') ((@("$desk\New folder (2)\alpha", "$desk\New folder\beta [old]", "$desk\delta", $empty) | Sort-Object) -join '|') 'syncRepos'
  Ok ((Test-Path -LiteralPath "$desk\delta\.git") -and (Test-Path -LiteralPath "$empty\.git")) 'cloned into the default folder and into the empty folder'
  Ok ($r.Out -match '== beta \[old\]' -and $r.Out -match '== delta' -and $r.Out -match 'main: đã mới nhất') 'synced at once'
  $r = Invoke-Fcode $w @('sync') $env0
  Eq $r.Code 0 $r.Out; Ok ($r.Out -notmatch 'chưa có trên laptop') 'second run: nothing to add, nothing asked'
  # r5: config.json BOM kept only when it was there; "syncRepos": null / a string is replaced, never a second key
  $CfgBroken = $false
  $cases = @(
    @{ N = 'bom'; Pre = [byte[]](0xEF, 0xBB, 0xBF); Body = "{`r`n  `"box`": `"coder`",`r`n  `"syncRepos`": [`"C:\\x`"]`r`n}`r`n"; Want = @('C:\x', 'C:\new dir') },
    @{ N = 'nobom'; Pre = [byte[]]@(); Body = "{ `"box`": `"coder`", `"syncRepos`": [] }"; Want = @('C:\new dir') },
    @{ N = 'null'; Pre = [byte[]]@(); Body = "{ `"box`": `"coder`", `"syncRepos`": null }"; Want = @('C:\new dir') },
    @{ N = 'string'; Pre = [byte[]](0xEF, 0xBB, 0xBF); Body = "{ `"syncRepos`": `"C:\\old`", `"box`": `"coder`" }"; Want = @('C:\old', 'C:\new dir') },
    @{ N = 'number'; Pre = [byte[]]@(); Body = "{ `"syncRepos`": 12, `"box`": `"coder`" }"; Want = @('C:\new dir') },
    @{ N = 'true'; Pre = [byte[]]@(); Body = "{ `"syncRepos`": true, `"box`": `"coder`" }"; Want = @('C:\new dir') },
    @{ N = 'false'; Pre = [byte[]]@(); Body = "{ `"box`": `"coder`", `"syncRepos`": false }"; Want = @('C:\new dir') })
  foreach ($c in $cases) {
    $ConfigFile = Join-Path $w.W "cfg-$($c.N).json"
    [IO.File]::WriteAllBytes($ConfigFile, [byte[]](@($c.Pre) + @($utf8.GetBytes($c.Body))))
    Add-SyncRepoConfig 'C:\new dir'
    $b = [IO.File]::ReadAllBytes($ConfigFile)
    Eq (($b[0..2] | ForEach-Object { '{0:X2}' -f $_ }) -join ' ') $(if ($c.Pre.Length) { 'EF BB BF' } else { (($utf8.GetBytes($c.Body)[0..2] | ForEach-Object { '{0:X2}' -f $_ }) -join ' ') }) "$($c.N): first bytes"
    $t = $utf8.GetString($b); if ($c.Pre.Length) { $t = $t.Substring(1) }
    Eq ([regex]::Matches($t, '"syncRepos"').Count) 1 "$($c.N): one syncRepos key"
    $j = $t | ConvertFrom-Json; Eq (@($j.syncRepos) -join '|') ($c.Want -join '|') "$($c.N): syncRepos"; Eq $j.box 'coder' "$($c.N): other key kept"
  }
  # r6: a config.json that is not UTF-8 is refused and never rewritten
  $ConfigFile = Join-Path $w.W 'cfg-latin1.json'; $lb = [byte[]](@($utf8.GetBytes('{ "box": "c')) + @(0xE0) + @($utf8.GetBytes('", "syncRepos": [] }')))
  [IO.File]::WriteAllBytes($ConfigFile, $lb)
  $msg = ''; try { Add-SyncRepoConfig 'C:\new dir' } catch { $msg = $_.Exception.Message }
  Eq $msg 'config.json không phải UTF-8, lưu lại dạng UTF-8 rồi chạy lại' 'refused'
  Eq ([Convert]::ToBase64String([IO.File]::ReadAllBytes($ConfigFile))) ([Convert]::ToBase64String($lb)) 'bytes unchanged'
  # r5: a bad pasted path never throws, on this edition too (r6: a tab or other control character too)
  foreach ($p in 'C:\a:b', 'C:\a|b', 'C:\x\D?esktop\p', 'C:\a<b', 'C:\a"b', 'C:\a*', "C:\a`tb", "C:\a$([char]1)b") {
    $v = Test-SyncFolder $p 'owner/x'; Ok (-not $v.Ok) "refused: $p"; Eq $v.Why 'đường dẫn không hợp lệ' "why: $p"
  }
}
T 'sync r5: a search root that is itself a git checkout is searched inside; roots not reached in time are marked "(chưa tìm)"' {
  $d = Join-Path $Root 'fl\desk'; New-GitDir $d; & git -C $d remote add origin https://github.com/me/dotfiles.git
  New-GitDir (Join-Path $d 'sub\alpha'); & git -C (Join-Path $d 'sub\alpha') remote add origin https://github.com/Owner/Alpha.git
  $docs = Join-Path $Root 'fl\docs'; $prof = Join-Path $Root 'fl\profile'; [void](New-Item -ItemType Directory -Force -Path $docs, $prof)
  $save = @{}; foreach ($k in 'FCODE_DESKTOP', 'FCODE_DOCUMENTS', 'FCODE_FIND_SEC', 'USERPROFILE') { $save[$k] = [Environment]::GetEnvironmentVariable($k) }
  [Environment]::SetEnvironmentVariable('FCODE_DESKTOP', $d); [Environment]::SetEnvironmentVariable('FCODE_DOCUMENTS', $docs); [Environment]::SetEnvironmentVariable('USERPROFILE', $prof)
  $SyncRepos = @()
  try {
    $f = Find-LocalClones @{ 'owner/alpha' = $true }
    Eq (@($f.Found['owner/alpha']) -join '|') (Join-Path $d 'sub\alpha') 'found inside a root that is a git checkout'
    Ok (@($f.Where)[0] -eq "$d (4 cấp)") ("where: " + ($f.Where -join '; '))
    [Environment]::SetEnvironmentVariable('FCODE_FIND_SEC', '0')
    $SyncRepos = @((Join-Path $d 'proj'))   # its parent is the Desktop root again: listed once
    $f = Find-LocalClones @{ 'owner/alpha' = $true }
    Ok (@($f.Where | Where-Object { $_ -match 'cấp\)$' }).Count -eq 0) ("no root claimed as searched: " + ($f.Where -join '; '))
    Ok (@($f.Where | Where-Object { $_ -eq "$d (chưa tìm)" }).Count -eq 1 -and @($f.Where)[-1] -match 'chưa tìm hết') ("marked: " + ($f.Where -join '; '))
  } finally { foreach ($k in $save.Keys) { [Environment]::SetEnvironmentVariable($k, $(if ($null -eq $save[$k]) { [NullString]::Value } else { $save[$k] })) } }
}
T 'sync r5: the box `projects` call has its own short deadline; a stalled answer does not hang `fcode sync`' {
  $w = New-World 'syn3'
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $r = Invoke-Fcode $w @('sync') @{ FAKE_SSH_CUT = 'projects:1:0:stall'; FCODE_PHIEN_TIMEOUT = '4' }
  Ok ($sw.Elapsed.TotalSeconds -lt 40) "returned in $([int]$sw.Elapsed.TotalSeconds) s"
  Ok ($r.Out -match 'không đọc được danh sách project trên box') ("told; out: " + $r.Out)
}

# ============================== scheduled task (hidden) ==============================
T 'task scheduler: registers a headless every-10-minutes task and the action shows no window' {
  $tp = '\FCode-test\'; $tn = 'phien-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  $marker = Join-Path $Root 'task-marker.txt'
  $script = Join-Path $Root 'task-probe.ps1'
  [IO.File]::WriteAllText($script, "param([string]`$x)`n`$p = Get-Process -Id `$PID`n`$h = `$p.MainWindowHandle`n[IO.File]::WriteAllText('$marker', ('handle=' + `$h + ' arg=' + `$x))`n")
  try {
    Install-PhienTask $script $tn $tp 'probe'
    $t = Get-ScheduledTask -TaskPath $tp -TaskName $tn
    Eq $t.Actions[0].Execute 'conhost.exe'
    Ok ($t.Actions[0].Arguments -like '--headless "*powershell.exe" -NoProfile*-File "*task-probe.ps1" probe') $t.Actions[0].Arguments
    Eq $t.Triggers[0].Repetition.Interval 'PT10M'
    Eq $t.Settings.MultipleInstances 'IgnoreNew'
    Start-ScheduledTask -TaskPath $tp -TaskName $tn
    $end = (Get-Date).AddSeconds(30)
    while (-not (Test-Path $marker) -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 300 }
    Ok (Test-Path $marker) 'task ran'
    Eq (Get-Content $marker -Raw) 'handle=0 arg=probe' 'no window handle'
  } finally { if (-not (Remove-PhienTask $tn $tp)) { Write-Host 'task already gone?' }; Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue }
  Ok (-not (Get-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction SilentlyContinue)) 'task removed'
  Ok (-not (Remove-PhienTask $tn $tp)) 'removing twice is harmless'
}

# ============================== 1.3.3: fcode phien <project> --nhanh ==============================
# instabox wrapper that logs the first word of every call (ls / wake / ssh): the fake itself logs only ssh
# $Stall: 'ls' = every `instabox ls` hangs for 60 s; 'put2' = the second and later `ssh ... put` hang for 60 s (the first one runs as the fake decides)
function Use-LoggedIb($w, [string]$Stall = '') {
  $w | Add-Member -NotePropertyName IbLog -NotePropertyValue (Join-Path $w.W 'ib-calls.log') -Force
  $wrap = Join-Path $w.W 'ib-wrap.cmd'
  $hang = switch ($Stall) {
    'ls' { "if /i `"%1`"==`"ls`" ping -n 60 127.0.0.1 >nul`r`n" }
    'put2' { "if /i not `"%1`"==`"ssh`" goto run`r`necho %* | findstr /c:`"' put`" >nul || goto run`r`nfindstr /c:`"ssh put`" `"%FAKE_SSH_LOG%`" >nul 2>&1 || goto run`r`nping -n 60 127.0.0.1 >nul`r`n:run`r`n" }
    # 'put1late': the first `ssh ... put` waits until the epoch second in FAKE_PUT_UNTIL, then runs as the fake decides (an item still under way when the deadline passes)
    'put1late' { "if /i not `"%1`"==`"ssh`" goto run`r`necho %* | findstr /c:`"' put`" >nul || goto run`r`nfindstr /c:`"ssh put`" `"%FAKE_SSH_LOG%`" >nul 2>&1 && goto run`r`npython -c `"import os,time;time.sleep(max(0,float(os.environ['FAKE_PUT_UNTIL'])-time.time()))`"`r`n:run`r`n" }
    # 'gitbreak': before an `ssh ... put` the box project's .git is renamed to .git-x (FAKE_BP = that folder, Windows form; unset = off): the box can no longer find its exclude file
    'gitbreak' { "if `"%FAKE_BP%`"==`"`" goto run`r`nif /i not `"%1`"==`"ssh`" goto run`r`necho %* | findstr /c:`"' put`" >nul || goto run`r`nif exist `"%FAKE_BP%\.git`" attrib -h `"%FAKE_BP%\.git`" & ren `"%FAKE_BP%\.git`" .git-x`r`n:run`r`n" }   # .git is hidden: ren does not see it
    # 'exclbreak': before an `ssh ... put` the box project's .git/info/exclude becomes a folder (FAKE_BP as above; unset = off): reading it fails with an OSError
    'exclbreak' { "if `"%FAKE_BP%`"==`"`" goto run`r`nif /i not `"%1`"==`"ssh`" goto run`r`necho %* | findstr /c:`"' put`" >nul || goto run`r`ndel /q `"%FAKE_BP%\.git\info\exclude`" >nul 2>&1`r`nmd `"%FAKE_BP%\.git\info\exclude`" >nul 2>&1`r`n:run`r`n" }
    default { '' }
  }
  [IO.File]::WriteAllText($wrap, "@echo off`r`necho %1 >>`"$($w.IbLog)`"`r`n${hang}call `"$Cmd`" %*`r`nexit /b %errorlevel%`r`n")
  [IO.File]::WriteAllText((Join-Path $w.U '.fcode\config.json'), (@{ instabox = $wrap; box = 'coder'; syncRepos = @($w.LP, (Join-Path $w.U 'Desktop\other'), (Join-Path $w.U 'Desktop\notonbox')) } | ConvertTo-Json -Compress))
}
function IbCalls($w) { if (Test-Path $w.IbLog) { @(Get-Content $w.IbLog | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() } }
function BoxSessions($w) { if (Test-Path $w.BH) { @(Get-ChildItem (Join-Path $w.BH '.omp\agent\sessions') -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue).Count } else { 0 } }
$CapMsg = 'phien: hết 20 giây, phần còn lại chạy lần sau'
$FailMsg = 'phien: không đồng bộ được, xem phien.log'
function Screen-Lines([string]$Text) { @($Text -split "`r?`n" | Where-Object { $_.Trim() }) }   # what a run printed on the screen

T 'nhanh: box asleep: exit 0 and a message, only `instabox ls`, never wake or ssh' {
  $w = New-W2 'q1'; Use-LoggedIb $w
  [void](New-Sess $w.LS '11111111-qs01' $w.LP @('a'))
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FAKE_BOX_STATE = 'suspended' }
  Eq $r.Code 0 $r.Out
  Eq ((Screen-Lines $r.Out) -join '|') 'phien: box đang ngủ, bỏ qua' 'one line'
  Eq ((IbCalls $w) -join ',') 'ls' 'only the state check: no wake, no ssh'
  Eq (SshCount $w) 0 'no ssh'; Eq (BoxSessions $w) 0 'nothing copied'
}
T 'nhanh r4: box state unknown (instabox ls fails, bad answer, no state): a failure, exit 1, only `instabox ls`, never wake or ssh' {
  $w = New-W2 'q1u'; Use-LoggedIb $w
  [void](New-Sess $w.LS '11111111-qs1u' $w.LP @('a'))
  foreach ($m in 'fail', 'bad', 'nostate') {
    $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FAKE_LS = $m }
    Eq $r.Code 1 "${m}: $($r.Out)"
    Eq ((Screen-Lines $r.Out) -join '|') $FailMsg "${m}: the failure line only"
  }
  Eq @([regex]::Matches((Read-PhienLog $w), 'lỗi: không đọc được trạng thái box \(instabox ls lỗi')).Count 3 'the reason is in phien.log each time'
  Eq ((IbCalls $w) -join ',') 'ls,ls,ls' 'only the state check: no wake, no ssh'
  Eq (SshCount $w) 0 'no ssh'; Eq (BoxSessions $w) 0 'nothing copied'
}
T 'nhanh: running box: the same work as fcode phien for that one project, no wake, no git-push hint, logged' {
  $w = New-W2 'q2'; Use-LoggedIb $w
  $s = New-Sess $w.LS '22222222-qs02' $w.LP @('a')
  $otherLs = Join-Path $w.U ('.omp\agent\sessions\' + (Get-OmpEncodedDir (Join-Path $w.U 'Desktop\other') $w.U (Join-Path $w.U 'AppData\Local\Temp')))
  [void](New-Sess $otherLs '22222222-qs03' (Join-Path $w.U 'Desktop\other') @('b'))
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh')
  Eq $r.Code 0 $r.Out
  Eq (Screen-Lines $r.Out).Count 0 ("success prints nothing on the screen: " + $r.Out)
  Ok ((Read-PhienLog $w) -match '== proj: gửi 1 phiên lên box') 'the details go to phien.log'
  Ok ((Read-PhienLog $w) -notmatch 'Nhớ đẩy code') 'no push hint in the hook'
  Ok (Test-Path (Join-Path $w.BS (Split-Path $s -Leaf))) 'the project session is on the box'
  Eq (BoxSessions $w) 1 'the other project was not touched'
  Ok ((IbCalls $w) -notcontains 'wake') ('never wakes: ' + ((IbCalls $w) -join ','))
  Ok ((IbCalls $w) -contains 'ssh') 'it did sync'
  Ok ((Get-Content (Join-Path $w.U '.fcode\phien.log') -Raw) -match 'Xong: 1 file gửi lên box') 'summary in the log (a background run has no screen)'
  $r = Invoke-Fcode $w @('phien', 'nope', '--nhanh'); Eq $r.Code 1 'unknown project is still an error'
  Eq ((Screen-Lines $r.Out) -join '|') $FailMsg 'a failure is one short line'; Ok ((Read-PhienLog $w) -match "Không thấy project 'nope'") 'the reason is in phien.log'
  $r = Invoke-Fcode $w @('phien', '--nhanh'); Eq $r.Code 1 '--nhanh needs a project'
}
T 'nhanh: lock busy: exit 0 at once with a message, nothing else is touched' {
  $w = New-W2 'q3'; Use-LoggedIb $w
  [void](New-Sess $w.LS '33333333-qs04' $w.LP @('a'))
  $mx = New-Object Threading.Mutex($false, $env:FCODE_PHIEN_LOCK); Ok ($mx.WaitOne(0)) 'the test holds the lock'
  try {
    $t0 = Get-Date; $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); $sec = ((Get-Date) - $t0).TotalSeconds
    Eq $r.Code 0 $r.Out
    Eq ((Screen-Lines $r.Out) -join '|') 'phien: đang có lần đồng bộ khác, bỏ qua' 'one line'
    Ok ($sec -lt 25) "no waiting for the lock ($([Math]::Round($sec)) s)"
    Eq (IbCalls $w).Count 0 'not even `instabox ls`'
    Ok ((Read-PhienLog $w) -match 'đang có lần đồng bộ khác, bỏ qua') 'the busy line is in phien.log too'
    # r4 F1: phien.log has its own lock (<lock>-log). $sec (above) is the run with that lock free; the busy line is the run's only log line
    $busy = 'đang có lần đồng bộ khác, bỏ qua'; $logf = Join-Path $w.U '.fcode\phien.log'
    $n = { @([regex]::Matches((Read-PhienLog $w), [regex]::Escape($busy))).Count }
    $lm = New-Object Threading.Mutex($false, ($env:FCODE_PHIEN_LOCK + '-log')); Ok ($lm.WaitOne(0)) 'the test holds the log lock'
    $held = $true
    try {
      # 1. held all the time: the line waits for the lock (absent 1 s after the free-lock run would have ended), then is appended anyway after 2 s
      $c0 = & $n; $a = Invoke-Fcode $w @('phien', 'proj', '--nhanh') -Async; $t0 = Get-Date; $mid = $null
      while (-not $a.P.HasExited -and ((Get-Date) - $t0).TotalSeconds -lt 40) { if ($null -eq $mid -and ((Get-Date) - $t0).TotalSeconds -ge $sec + 1) { $mid = & $n }; Start-Sleep -Milliseconds 50 }
      $s1 = ((Get-Date) - $t0).TotalSeconds; [void]$a.P.WaitForExit(); $o1 = $a.Out.Result; $a.P.Dispose()
      Eq $mid $c0 "1 s after the free-lock run time ($([Math]::Round($sec, 1)) s) the busy line is not in phien.log yet"
      Ok ($s1 -ge $sec + 1.5 -and $s1 -lt $sec + 8) "the run waited about 2 s for the log lock, then went on ($([Math]::Round($s1, 1)) s)"
      Eq ((Screen-Lines $o1) -join '|') "phien: $busy" 'the busy line on the screen'
      Eq (& $n) ($c0 + 1) 'and in phien.log (appended without the lock)'
      # 2. released 0.5 s after the free-lock run time: the waiting run takes the lock and writes at once
      $c0 = & $n; $a = Invoke-Fcode $w @('phien', 'proj', '--nhanh') -Async; $t0 = Get-Date
      while (((Get-Date) - $t0).TotalSeconds -lt $sec + 0.5) { Start-Sleep -Milliseconds 50 }
      $lm.ReleaseMutex(); $held = $false; $tr = Get-Date
      while ((& $n) -eq $c0 -and ((Get-Date) - $tr).TotalSeconds -lt 5) { Start-Sleep -Milliseconds 50 }
      $s2 = ((Get-Date) - $tr).TotalSeconds; [void]$a.P.WaitForExit(30000); $a.P.Dispose()
      Ok ($s2 -lt 1.5) "after the release the line is there within 1.5 s ($([Math]::Round($s2, 1)) s)"
      # 3. phien.log over 200 KB, lock held: a run that gives up appends without rotating; the holder's next line rotates; nothing is lost
      $pre = [byte[]]$utf8.GetBytes((@(1..2100 | ForEach-Object { 'old line ' + $_.ToString('D4') + ' ' + ('p' * 85) }) -join "`n") + "`n")   # 210 000 bytes
      [IO.File]::WriteAllBytes($logf, $pre); Remove-Item "$logf.1" -ErrorAction SilentlyContinue
      Ok ($lm.WaitOne(0)) 'held again'; $held = $true
      $r3 = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r3.Code 0 $r3.Out
      $saved = $PhienLog; $script:PhienLog = $logf
      try { Add-PhienLog @('x') } finally { $script:PhienLog = $saved }
      Ok ((Test-Path "$logf.1") -and (Bytes-Eq ([byte[]]@(Read-Bytes "$logf.1")[0..($pre.Length - 1)]) $pre)) 'every old line is kept, whole, in phien.log.1'
      $all = [IO.File]::ReadAllText("$logf.1") + [IO.File]::ReadAllText($logf)
      Ok ($all.Contains($busy)) "the line of the run that gave up is in phien.log.1 or phien.log, never lost"
      Ok (([IO.File]::ReadAllText($logf)) -match ' x\r?\n\z') "the holder's line starts the new phien.log"
    } finally { if ($held) { try { $lm.ReleaseMutex() } catch { } }; $lm.Dispose() }
  } finally { try { $mx.ReleaseMutex() } catch { }; $mx.Dispose() }
}
T 'nhanh: the 20 s cap ends the run cleanly: exit 0, message, no later batch, nothing half-placed; the next run finishes' {
  $w = New-W2 'q4'; Use-LoggedIb $w
  $a = New-Sess $w.LS 'aaaa1111-cap1' $w.LP @('a'); Grow-Sess $a 30
  $b = New-Sess $w.LS 'bbbb2222-cap2' $w.LP @('b'); Grow-Sess $b 30
  $t0 = Get-Date
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FCODE_PHIEN_CAP_SEC = '15'; FAKE_SSH_CUT = 'put:1:0:stall' }
  $sec = ((Get-Date) - $t0).TotalSeconds
  Eq $r.Code 0 $r.Out; Eq ((Screen-Lines $r.Out) -join '|') $CapMsg 'only the cap line on the screen, no false "lỗi" and no summary'
  Ok ((Read-PhienLog $w) -notmatch 'lỗi') 'a cut by the cap is not logged as an error either'
  Ok ($sec -lt 45) "ended at the cap ($([Math]::Round($sec)) s, the stall is 60 s)"
  Eq (Calls $w 'put') 1 'no batch is started after the cap'
  Ok (-not (Test-Path (Join-Path $w.BS (Split-Path $a -Leaf))) -and -not (Test-Path (Join-Path $w.BS (Split-Path $b -Leaf)))) 'nothing half-sent is placed'
  Eq (Parts $w.LS) 0 'no part file on the laptop'
  Ok (-not (Get-ChildItem (Join-Path $w.U 'AppData\Local\Temp') -Directory -Filter 'fcode-phien-*' -ErrorAction SilentlyContinue)) 'staging removed'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Ok ((Test-Path (Join-Path $w.BS (Split-Path $a -Leaf))) -and (Test-Path (Join-Path $w.BS (Split-Path $b -Leaf)))) 'the next run sends both'
}
T 'nhanh: a cap that has already passed before the scan: exit 0 and the message, no ssh' {
  $w = New-W2 'q5'; Use-LoggedIb $w
  [void](New-Sess $w.LS '55555555-qs05' $w.LP @('a'))
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FCODE_PHIEN_CAP_SEC = '1' }
  Eq $r.Code 0 $r.Out; Eq ((Screen-Lines $r.Out) -join '|') $CapMsg 'only the cap line'
  Eq (SshCount $w) 0 'no ssh once the time is up'
  $r = Invoke-Fcode $w @('phien', 'proj') @{ FCODE_PHIEN_CAP_SEC = '1' }; Eq $r.Code 0 'the cap is for --nhanh only'; Eq (BoxSessions $w) 1 'a normal run ignores the cap and syncs'
}
T 'nhanh r2: a failing sync (box listed running, ssh fails) is ONE short line on the screen; the details are in phien.log' {
  $w = New-W2 'q6'; Use-LoggedIb $w
  [void](New-Sess $w.LS '66666666-qs06' $w.LP @('a'))
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FAKE_SSH_FAIL = '1' }
  Eq $r.Code 1 $r.Out
  Eq ((Screen-Lines $r.Out) -join '|') $FailMsg 'one line, not the 2 lines of the old output'
  Ok ((Read-PhienLog $w) -match 'lỗi: không nói chuyện được với box') 'the reason is logged'
}
# L2: every child program of a quick run is bounded by the cap (the stalls below last 60 s; the cap is 8 s)
T 'nhanh r2: `instabox ls` that hangs is killed at the cap: exit 0, only the cap line, no ssh' {
  $w = New-W2 'q7'; Use-LoggedIb $w 'ls'
  [void](New-Sess $w.LS '77777777-qs07' $w.LP @('a'))
  $t0 = Get-Date; $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FCODE_PHIEN_CAP_SEC = '8' }; $sec = ((Get-Date) - $t0).TotalSeconds
  Eq $r.Code 0 $r.Out; Eq ((Screen-Lines $r.Out) -join '|') $CapMsg 'the cap line, not "box đang ngủ"'
  Ok ($sec -lt 30) "ended at the cap ($([Math]::Round($sec)) s, `instabox ls` hangs 60 s)"
  Eq (SshCount $w) 0 'no ssh'
}
foreach ($shim in 'omp', 'git') {
  T "nhanh r2: a hanging `"$shim`" (found first on PATH) is killed at the cap: exit 0, only the cap line, nothing is sent" {
    $w = New-W2 "q8$shim"; Use-LoggedIb $w
    [void](New-Sess $w.LS '88888888-qs08' $w.LP @('a'))
    $bin = Join-Path $w.W 'shim'; [void](New-Item -ItemType Directory -Path $bin -Force)
    [IO.File]::WriteAllText((Join-Path $bin "$shim.cmd"), "@echo off`r`nping -n 60 127.0.0.1 >nul`r`n")
    $t0 = Get-Date; $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FCODE_PHIEN_CAP_SEC = '8'; PATH = ($bin + ';' + $env:PATH) }; $sec = ((Get-Date) - $t0).TotalSeconds
    Eq $r.Code 0 $r.Out; Eq ((Screen-Lines $r.Out) -join '|') $CapMsg 'the cap line only'
    Ok ($sec -lt 30) "ended at the cap ($([Math]::Round($sec)) s, $shim hangs 60 s)"
    Eq (BoxSessions $w) 0 'nothing was sent'
  }
}
T 'nhanh r3: Invoke-PhienExe: arguments reach the program intact, exit code and lines come back; with a deadline a child gets the time left + 5 s (at least 3 s), then it and its children are killed (124)' {
  $py = (Get-Command python -CommandType Application | Select-Object -First 1).Source
  $r = Invoke-PhienExe $py @('-c', 'import sys;[print(a) for a in sys.argv[1:]];sys.exit(3)', 'a b', 'say "hi"', 'end\', 'x\"y', '')
  Eq $r.Code 3 'exit code'; Eq ($r.Out -join '|') 'a b|say "hi"|end\|x\"y|' 'arguments (spaces, quotes, trailing backslash, empty) and lines'
  $script:PhienDeadline = [DateTime]::UtcNow.AddSeconds(2)
  try {
    $t0 = Get-Date; $r = Invoke-PhienExe $env:ComSpec @('/c', 'ping -n 40 127.0.0.1 >nul'); $sec = ((Get-Date) - $t0).TotalSeconds
    Eq $r.Code 124 'killed'; Ok ($sec -ge 6 -and $sec -lt 14) "killed after the time left + 5 s grace ($([Math]::Round($sec, 1)) s, 2 s were left, the program runs 39 s)"
    $script:PhienDeadline = [DateTime]::UtcNow.AddSeconds(-30)
    $t0 = Get-Date; $r = Invoke-PhienExe $env:ComSpec @('/c', 'ping -n 40 127.0.0.1 >nul'); $sec = ((Get-Date) - $t0).TotalSeconds
    Eq $r.Code 124 'killed'; Ok ($sec -ge 2.5 -and $sec -lt 9) "past the deadline a child still gets the 3 s floor ($([Math]::Round($sec, 1)) s)"
    $mark = Join-Path $Root 'exe-started.txt'
    $r = Invoke-PhienExe $py @('-c', "open(r'$mark', 'w').write('x')"); Eq $r.Code 0 'a short child of an item that has started still runs to its end'; Ok (Test-Path $mark) 'it ran'
  } finally { $script:PhienDeadline = $null }
}
T 'nhanh r4: Invoke-PhienExe without a deadline (-1) waits as long as the program runs' {
  $script:PhienDeadline = $null
  $t0 = Get-Date; $r = Invoke-PhienExe $env:ComSpec @('/c', 'ping -n 3 127.0.0.1 >nul'); $sec = ((Get-Date) - $t0).TotalSeconds
  Eq $r.Code 0 'not killed'; Ok ($sec -ge 1.5) "it ran its 2 s ($([Math]::Round($sec, 1)) s)"
}
T 'nhanh r4: the supervisor (Invoke-PhienBounded) has no kill call of its own: the job ends the worker' {
  $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-PhienBounded' }, $true)
  Ok ($null -ne $fn) 'Invoke-PhienBounded exists'
  foreach ($x in 'Stop-PhienProc', '.Kill(', 'taskkill') { Ok (-not $fn.Body.Extent.Text.Contains($x)) "no $x in it" }
}
T 'nhanh r4: no job = no sync (fail closed): exit 1, the failure line, the reason in phien.log, no worker started' {
  $saved = $PhienLog, $FcodeScript; $script:PhienLog = Join-Path $Root 'fc\phien.log'
  $mark = Join-Path $Root 'fc\worker-ran.txt'; $script:FcodeScript = Join-Path $Root 'fc\worker.ps1'   # never the real fcode.ps1: a worker here would run in this test's environment
  [void](New-Item -ItemType Directory -Path (Split-Path $mark) -Force); [IO.File]::WriteAllText($FcodeScript, "[IO.File]::WriteAllText('$mark', 'ran')")
  function Get-PhienJob { $script:PhienJobError = 'test: refused'; $null }
  try {
    $out = @(Invoke-PhienBounded 'proj' $false 6>&1)
    Eq @($out | Where-Object { $_ -is [int] })[0] 1 'exit code 1'
    Ok ((@($out | ForEach-Object { "$_" }) -join '|') -match [regex]::Escape($FailMsg)) ('the failure line: ' + ($out -join '|'))
    Ok ((Get-Content $PhienLog -Raw -Encoding UTF8) -match 'không tạo được job bảo vệ cho lần chạy nhanh \(test: refused\)') 'the reason is logged'
    Start-Sleep -Seconds 2; Ok (-not (Test-Path $mark)) 'no worker was started'
  } finally { $script:PhienLog, $script:FcodeScript = $saved; Remove-Item Function:\Get-PhienJob -ErrorAction SilentlyContinue }
}
# Q2: the deadline is checked only between items; nothing inside one stops for it (no half-done item: a note placed without its exclude line, a cut scan)
T 'nhanh r3: nothing inside an item stops for the deadline: hash, scan, notes, git and a note install run to their end after it has passed' {
  $w = New-World 'q9'; $s = New-Sess $w.LS '99999999-qs09' $w.LP @('a', 'b'); New-GitDir $w.LP
  $src = Join-Path $w.W 'note-src.md'; Put-File $src 'from box'
  $script:PhienDeadline = [DateTime]::UtcNow.AddSeconds(-5)
  try {
    Ok ((Get-RangeSha $s 0 10) -match '\A[0-9a-f]{64}\z') 'hash'
    Eq @(Get-PhienLocalScan $w.LS).Count 1 'scan'
    Eq (Get-PhienLocalNotes $w.LP).gitok $true 'notes'
    Eq (Invoke-GitQuiet $w.LP @('status')).Code 0 'git'
    Eq (Install-PhienNote $src $w.LP 'HANDOFF-dl.md' '' (ConvertTo-Epoch (Get-Date))) 'ok' 'a note install is one whole item'
    Eq (Get-Content "$($w.LP)\HANDOFF-dl.md" -Raw) 'from box' 'placed'
    Ok ((Get-Content "$($w.LP)\.git\info\exclude" -Raw) -match '(?m)^/HANDOFF-dl\.md\r?$') 'and excluded'
  } finally { $script:PhienDeadline = $null }
}
# L4: the cap line is for a run that stopped on the cap; a real error keeps its exit code and its own one line (a second batch that is cut by the cap does not wipe it)
T 'nhanh r2: a real error before the cap keeps exit code 1 and the failure line; the cap does not turn it into a clean exit' {
  $w = New-W2 'q10'; Use-LoggedIb $w 'put2'
  $a = New-Sess $w.LS 'aaaa1010-er01' $w.LP @('a'); Grow-Sess $a 30
  $b = New-Sess $w.LS 'bbbb1010-er02' $w.LP @('b'); Grow-Sess $b 30
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FCODE_PHIEN_CAP_SEC = '25'; FAKE_SSH_CUT = 'put:1:0:fail' }
  Eq $r.Code 1 $r.Out
  Eq ((Screen-Lines $r.Out) -join '|') $FailMsg 'the failure line only (not the cap line)'
  Eq (Calls $w 'put') 1 'only the first put (failed on the box) reached the box; the second hung and was cut by the cap'
  Ok ((Read-PhienLog $w) -match [regex]::Escape($CapMsg)) 'the cap is in the log'
}
T 'nhanh r2: a run that all finished does not claim the cap: no cap line, no "phần còn lại" in the log' {
  $w = New-W2 'q11'; Use-LoggedIb $w
  [void](New-Sess $w.LS '11111111-fin1' $w.LP @('a'))
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FCODE_PHIEN_CAP_SEC = '60' }
  Eq $r.Code 0 $r.Out; Eq (Screen-Lines $r.Out).Count 0 'silent'
  Ok ((Read-PhienLog $w) -notmatch 'phần còn lại') 'no cap line in the log'
}
# L3 (second half): a quick run does not move the 40-minute gap of the auto run, so what it left undone is still picked up by the next auto run
T 'nhanh r2: a cut quick run leaves phien-auto.json alone; the next 10-minute auto run (last ssh 100 min ago) still syncs what was left' {
  $w = New-W2 'q12'; Use-LoggedIb $w
  $a = New-Sess $w.LS 'aaaa1212-au01' $w.LP @('a'); Grow-Sess $a 30
  Set-AutoState $w $true 100; $before = Get-AutoState $w
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FCODE_PHIEN_CAP_SEC = '15'; FAKE_SSH_CUT = 'put:1:0:stall' }
  Eq $r.Code 0 $r.Out; Ok ($r.Out.Contains($CapMsg)) 'the quick run was cut'
  $after = Get-AutoState $w
  Eq $after.lastSshAt $before.lastSshAt 'the gap is not reset by a quick run'; Eq $after.boxRunning $before.boxRunning
  Eq (BoxSessions $w) 0 'nothing arrived yet'
  $r = Invoke-Fcode $w @('phien', '--tu-dong'); Eq $r.Code 0 $r.Out
  Eq (BoxSessions $w) 1 'the auto run did not skip behind the gap'
}

# ---- r3 "safe points only": an item (a batch, a note) ends whole or not at all; the deadline only stops the run between items ----
function Body-Sha([string]$p) { $o = Get-PhienOff $p; Get-RangeSha $p $o ((Get-Item -LiteralPath $p).Length - $o) }
# Q1: Install-PhienNote does every git call before it places the note; a git that never answers check-ignore is killed (3 s floor or
# time left + 5 s) and the note waits: never placed without its exclude line (r6: a stall on --git-path now hits the scan: no note work at all)
T 'nhanh r3: a note from the box with a git that stalls (check-ignore): never placed without its exclude line; the next run places and excludes it' {
  $w = New-W2 'q13'; Use-LoggedIb $w
  New-GitDir $w.LP; New-GitDir $w.BP
  Put-File "$($w.BP)\HANDOFF.md" 'box handoff'
  $realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
  $bin = Join-Path $w.W 'shim'; [void](New-Item -ItemType Directory -Path $bin -Force); $glog = Join-Path $w.W 'git-calls.log'
  [IO.File]::WriteAllText((Join-Path $bin 'git.cmd'), "@echo off`r`n>>`"$glog`" echo %*`r`necho %* | findstr /c:`"check-ignore`" >nul || goto run`r`nping -n 60 127.0.0.1 >nul`r`nexit /b 1`r`n:run`r`n`"$realGit`" %*`r`nexit /b %errorlevel%`r`n")
  $t0 = Get-Date; $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FCODE_PHIEN_CAP_SEC = '15'; PATH = ($bin + ';' + $env:PATH) }; $sec = ((Get-Date) - $t0).TotalSeconds
  Ok ((Get-Content $glog -Raw) -match 'check-ignore') ('the note install reached git (the stall was hit): ' + $r.Out)
  Eq $r.Code 0 $r.Out; Eq ((Screen-Lines $r.Out) -join '|') $CapMsg 'a git that did not answer in time is a cut, not an error'
  Ok ($sec -lt 35) "bounded by the cap + 5 s ($([Math]::Round($sec)) s, the stall is 60 s)"
  $exf = "$($w.LP)\.git\info\exclude"; $ex = if (Test-Path $exf) { Get-Content $exf -Raw } else { '' }
  Ok (-not (Test-Path "$($w.LP)\HANDOFF.md") -or $ex -match '(?m)^/HANDOFF\.md\r?$') 'never placed without its exclude line'
  Eq (@(Get-ChildItem $w.LP -Force -Filter '*.fcode-part*').Count) 0 'no part file in the project'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Eq (Get-Content "$($w.LP)\HANDOFF.md" -Raw) 'box handoff' 'the next run places it'
  Ok ((Get-Content $exf -Raw) -match '(?m)^/HANDOFF\.md\r?$') 'and excludes it'
  Ok (((& git -C $w.LP status --porcelain | Out-String)) -notmatch 'HANDOFF') 'git status on the laptop does not list it'
}
# Q2: a batch that is under way when the deadline passes is finished whole (its child has the 5 s grace); the run then stops before the next batch
T 'nhanh r3: a batch still under way when the deadline passes ends whole (placed, all of it); no next batch starts; the next run sends the rest' {
  $w = New-W2 'q14'; Use-LoggedIb $w 'put1late'
  $a = New-Sess $w.LS 'aaaa1414-it01' $w.LP @('a'); Grow-Sess $a 30
  $b = New-Sess $w.LS 'bbbb1414-it02' $w.LP @('b'); Grow-Sess $b 30
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FCODE_PHIEN_CAP_SEC = '15'; FAKE_PUT_UNTIL = "$((ConvertTo-Epoch (Get-Date)) + 15.5)" }
  Eq $r.Code 0 $r.Out; Eq ((Screen-Lines $r.Out) -join '|') $CapMsg 'the cap line only'
  Eq (Calls $w 'put') 1 'no batch is started after the deadline'
  $on = @($a, $b | Where-Object { Test-Path (Join-Path $w.BS (Split-Path $_ -Leaf)) })
  Eq $on.Count 1 'the batch under way at the deadline was placed, the next one was not started'
  Eq (Body-Sha (Join-Path $w.BS (Split-Path $on[0] -Leaf))) (Body-Sha $on[0]) 'placed whole'
  Eq (Parts $w.LS) 0 'no part file on the laptop'; Eq (Parts $w.BS) 0 'no part file on the box'
  Ok (-not (Get-ChildItem (Join-Path $w.U 'AppData\Local\Temp') -Directory -Filter 'fcode-phien-*' -ErrorAction SilentlyContinue)) 'staging removed'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out; Eq (Screen-Lines $r.Out).Count 0 $r.Out
  Eq (BoxSessions $w) 2 'the next run sends the other one'
}
T 'nhanh r3: an earlier batch failure, then the deadline at the next safe point: exit 1 and the failure line (the cap does not erase it)' {
  $w = New-W2 'q15'; Use-LoggedIb $w 'put1late'
  $a = New-Sess $w.LS 'aaaa1515-ef01' $w.LP @('a'); Grow-Sess $a 30
  $b = New-Sess $w.LS 'bbbb1515-ef02' $w.LP @('b'); Grow-Sess $b 30
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FCODE_PHIEN_CAP_SEC = '15'; FAKE_PUT_UNTIL = "$((ConvertTo-Epoch (Get-Date)) + 15.5)"; FAKE_SSH_CUT = 'put:1:0:fail' }
  Eq $r.Code 1 $r.Out; Eq ((Screen-Lines $r.Out) -join '|') $FailMsg 'the failure line only'
  Eq (Calls $w 'put') 1 'the run stopped at the safe point after the failed batch'
  $log = Read-PhienLog $w
  Ok ($log -match 'gửi phiên lên box không thành công') 'the failure is logged'; Ok ($log -match [regex]::Escape($CapMsg)) 'and the cap'
}
# Q6: a run killed at any point (the hook's 25 s kill, Ctrl+C) never leaves a half-written file under a real name; what it left (its staging in
# %TEMP%, part files) carries its PID and is removed at the start of the next run, however fresh; a live run's part file stays
T 'nhanh r3: a run killed mid-way leaves nothing half-written; the next run removes its staging and part files at once and finishes' {
  $w = New-W2 'q16'; Use-LoggedIb $w
  $a = New-Sess $w.LS 'aaaa1616-kil1' $w.LP @('a'); Grow-Sess $a 5
  $lt = Join-Path $w.U 'AppData\Local\Temp'; [void](New-Item -ItemType Directory -Force -Path $lt)
  $p = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FCODE_PHIEN_CAP_SEC = '60'; FAKE_SSH_CUT = 'put:1:0:stall' } -NoWait
  $kpid = $p.Id
  try {
    $until = (Get-Date).AddSeconds(40)
    while ((Calls $w 'put') -lt 1 -and (Get-Date) -lt $until -and -not $p.HasExited) { Start-Sleep -Milliseconds 200 }
    Ok ((Calls $w 'put') -eq 1 -and -not $p.HasExited) 'the run is in the middle of sending'
  } finally { Stop-PhienProc $p; [void]$p.WaitForExit(15000); $p.Dispose() }
  Start-Sleep -Seconds 1
  $left = @(Get-ChildItem $lt -Directory -Filter 'fcode-phien-*')   # named after the worker (the supervisor's child), not $kpid
  Eq $left.Count 1 'the killed run left its staging behind (fresh, under 1 h)'
  Eq (BoxSessions $w) 0 'nothing half-sent is placed on the box'; Eq (Parts $w.LS) 0 'no part file of a session on the laptop'
  $dead = "$($w.LS)\x.jsonl.fcode-part-$kpid-abcdef", "$($w.LP)\HANDOFF-k.md.fcode-part-$kpid-abcdef"
  $live = "$($w.LS)\y.jsonl.fcode-part-$PID-abcdef"   # this test process is alive and older than the file: a run that is still going
  foreach ($f in @($dead) + @($live)) { Put-File $f 'x' }
  # r4 F4: the staging goes as soon as the next run holds the lock, even when that run stops early (box asleep)
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FAKE_BOX_STATE = 'suspended' }; Eq $r.Code 0 $r.Out
  Eq ((Screen-Lines $r.Out) -join '|') 'phien: box đang ngủ, bỏ qua' 'the asleep line'
  Ok (-not (Test-Path $left[0].FullName)) 'the staging of the killed run is removed at once, before the box check'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FCODE_PHIEN_CAP_SEC = '60' }; Eq $r.Code 0 $r.Out
  foreach ($f in $dead) { Ok (-not (Test-Path $f)) "part file of the killed run removed: $(Split-Path $f -Leaf)" }
  Ok (Test-Path $live) 'the part file of a live run stays'
  Ok (Test-Path (Join-Path $w.BS (Split-Path $a -Leaf))) 'the next run sends the session'
}
# Q4: quick mode keeps the script's ErrorActionPreference ('Stop'): a cmdlet error is an error as in `fcode phien`, never a silent partial run
T 'nhanh r3: a cmdlet error (a folder that cannot be listed) is an error in quick mode too: exit 1, the failure line, the reason in phien.log' {
  $w = New-W2 'q17'; Use-LoggedIb $w
  $s = New-Sess $w.LS 'eeee1717-acl1' $w.LP @('a')
  $lk = Join-Path $w.LS ([IO.Path]::GetFileNameWithoutExtension($s) + '\locked'); Put-File "$lk\x.txt" 'x'
  $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  & icacls.exe $lk /deny "${me}:(OI)(CI)(RD)" | Out-Null
  try {
    $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh')
    Eq $r.Code 1 $r.Out; Eq ((Screen-Lines $r.Out) -join '|') $FailMsg 'one failure line'
    Ok ((Read-PhienLog $w) -match 'lỗi: ') 'the reason is in phien.log'
    Eq (BoxSessions $w) 0 'no partial listing was sent as if it were complete'
  } finally { & icacls.exe $lk /remove:d $me | Out-Null }
}

# ---- r4: the supervisor (kill-on-close job), crash-safe writes, ownership first, big items left to the other runs ----
# F3: the exclude line is added before the note is placed: an exclude file fcode cannot write means no note (never a visible, unexcluded one)
T 'nhanh r4: a read-only .git/info/exclude on the laptop: the note is not placed, exit 1, the failure line, the reason logged; writable again: placed and excluded' {
  $w = New-W2 'q19'; Use-LoggedIb $w
  New-GitDir $w.LP; New-GitDir $w.BP
  Put-File "$($w.BP)\HANDOFF.md" 'box handoff'
  $exf = "$($w.LP)\.git\info\exclude"; $before = Read-Bytes $exf
  (Get-Item -LiteralPath $exf).IsReadOnly = $true
  try {
    $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh')
    Eq $r.Code 1 $r.Out; Eq ((Screen-Lines $r.Out) -join '|') $FailMsg 'the failure line'
    Ok (-not (Test-Path "$($w.LP)\HANDOFF.md")) 'the note is not placed without its line'
    Ok (Bytes-Eq (Read-Bytes $exf) $before) 'the exclude file is unchanged'
    Eq (@(Get-ChildItem $w.LP -Force -Filter '*.fcode-part*').Count + @(Get-ChildItem "$($w.LP)\.git\info" -Force -Filter '*.part-*').Count) 0 'no part file'
    Ok ((Read-PhienLog $w) -match 'lỗi') 'the reason is in phien.log'
  } finally { (Get-Item -LiteralPath $exf).IsReadOnly = $false }
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Eq (Get-Content "$($w.LP)\HANDOFF.md" -Raw) 'box handoff' 'the next run places it'
  Ok ((Get-Content $exf -Raw) -match '(?m)^/HANDOFF\.md\r?$') 'and excludes it'
  Eq ((& git -C $w.LP status --porcelain | Out-String).Trim()) '' 'git status on the laptop is clean'
}
# F2: never write through a link
T 'nhanh r4: a note from the box when .git/info on the laptop is a junction: not placed, one log line, exit 0, the target untouched' {
  $w = New-W2 'q20'; Use-LoggedIb $w
  New-GitDir $w.LP; New-GitDir $w.BP
  Put-File "$($w.BP)\HANDOFF.md" 'box handoff'
  $tg = Join-Path $w.W 'info-elsewhere'; New-InfoJunction $w.LP $tg "# user`n"
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out; Eq (Screen-Lines $r.Out).Count 0 $r.Out
  Ok (-not (Test-Path "$($w.LP)\HANDOFF.md")) 'not placed'
  Ok ((Read-PhienLog $w) -match 'ghi chú HANDOFF\.md: \.git/info/exclude là liên kết, fcode không ghi vào đó, chưa đặt') ('logged: ' + (Read-PhienLog $w))
  Eq (Get-Content (Join-Path $tg 'exclude') -Raw) "# user`n" 'the target is untouched'
}
# F3 end to end: the ownership saved with the placement lets fcode give its line back once git tracks the name; the user's copy is never lost
T 'nhanh r4: a note placed from the box, then committed on the box and fetched on the laptop: the line is given back, git shows the copy, refuses to overwrite it, the text stays' {
  $w = New-W2 'q21'; Use-LoggedIb $w
  New-GitDir $w.LP; New-GitDir $w.BP
  $bo = Join-Path $w.W 'origin.git'; New-Origin $bo
  foreach ($d in $w.LP, $w.BP) { Fetch-Origin $d $bo; $ErrorActionPreference = 'Continue'; & git -C $d checkout -q -B main origin/main 2>&1 | Out-Null; $ErrorActionPreference = 'Stop' }
  Put-File "$($w.BP)\HANDOFF.md" 'box text'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Eq (Get-Content "$($w.LP)\HANDOFF.md" -Raw) 'box text' 'placed from the box'
  # r6 T1: the ownership is the "# fcode" pair in the laptop exclude; no record of any kind
  Ok ((Get-Content "$($w.LP)\.git\info\exclude" -Raw) -match '(?m)^# fcode\r?\n/HANDOFF\.md\r?$') 'the laptop exclude has the pair'
  $st = Get-Content (Join-Path $w.U 'AppData\Local\fcode\handoff-state.json') -Raw | ConvertFrom-Json
  Ok ($null -ne $st.PSObject.Properties['proj/HANDOFF.md']) 'the sha record'; Eq @($st.PSObject.Properties | Where-Object { $_.Name -like 'exclude:*' }).Count 0 'no exclude: record'
  Put-File "$($w.LP)\HANDOFF.md" 'laptop edit'
  $ErrorActionPreference = 'Continue'
  Git-Commit $w.BP @('HANDOFF.md'); & git -C $w.BP push -q $bo HEAD:main 2>&1 | Out-Null; & git -C $w.LP fetch -q origin 2>&1 | Out-Null
  $ErrorActionPreference = 'Stop'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Ok ((Read-PhienLog $w) -match 'ghi chú HANDOFF\.md giờ do git theo dõi \(trên (box|origin)\): bản cũ trên laptop xóa được') ('release line: ' + (Read-PhienLog $w))
  $lx = Get-Content "$($w.LP)\.git\info\exclude" -Raw
  Ok ($lx -notmatch '(?m)^/HANDOFF\.md\r?$' -and $lx -notmatch '# fcode') 'both lines of the pair are given back'
  Eq ((& git -C $w.LP status --porcelain | Out-String).Trim()) '?? HANDOFF.md' 'git now shows the laptop copy'
  $ErrorActionPreference = 'Continue'; $mo = (& git -C $w.LP merge origin/main 2>&1 | Out-String); $mc = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
  Ok ($mc -ne 0 -and $mo -match 'would be overwritten') "git refuses to overwrite it: $mo"
  Eq (Get-Content "$($w.LP)\HANDOFF.md" -Raw) 'laptop edit' 'the local text is intact'
}
# F6: a quick run (20 s) never starts a batch of one file over 50 MB, nor the late top waiting for it
T 'nhanh r4: a file over 50 MB is left to the auto run / fcode phien: the small sessions sync both ways, a log line names it, exit 0, silent; fcode phien sends it' {
  $w = New-W2 'q18'; Use-LoggedIb $w
  $a = New-Sess $w.LS '0000000a-big8' $w.LP @('a'); Put-Big (Join-Path $a.Replace('.jsonl', '') 'huge.log') 60 58
  $b = New-Sess $w.LS 'ffffffff-sml8' $w.LP @('b')
  $c = New-Sess $w.BS 'cccccccc-box8' $w.BP @('c')
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FCODE_PHIEN_CAP_SEC = '60' }
  Eq $r.Code 0 $r.Out; Eq (Screen-Lines $r.Out).Count 0 ('silent: ' + $r.Out)
  Ok (Test-Path (Join-Path $w.BS (Split-Path $b -Leaf))) 'the small laptop session is on the box'
  Ok (Test-Path (Join-Path $w.LS (Split-Path $c -Leaf))) 'the box session came to the laptop'
  Ok (-not (Test-Path (Join-Path $w.BS (Split-Path $a -Leaf)))) 'the big session waits'
  Eq @(PutBytes $w | Where-Object { $_ -gt 50MB }).Count 0 'no put over 50 MB'
  Ok ((Read-PhienLog $w) -match 'phiên lớn: \S*huge\.log — lần nhanh không chép, để lần tự động hoặc fcode phien') ('logged: ' + (Read-PhienLog $w))
  $r = Invoke-Fcode $w @('phien', 'proj'); Eq $r.Code 0 $r.Out
  Ok (Test-Path (Join-Path $w.BS (Split-Path $a -Leaf))) 'fcode phien sends it'
}
# F7: the hard bound. git answers check-ignore after 2 s; 12 notes make the local scan (one item) run far past the cap, so only the supervisor ends it
T 'nhanh r4: a quick run still busy at cap + 10 s is ended for good with every child (git): exit 1, the failure line, logged; the next run syncs' {
  $w = New-W2 'q22'; Use-LoggedIb $w
  New-GitDir $w.LP; New-GitDir $w.BP
  foreach ($i in 1..12) { Put-File "$($w.LP)\HANDOFF-$i.md" "n$i" }
  $realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
  $bin = Join-Path $w.W 'shim'; [void](New-Item -ItemType Directory -Path $bin -Force); $glog = Join-Path $w.W 'git-slow.log'
  [IO.File]::WriteAllText((Join-Path $bin 'git.cmd'), "@echo off`r`necho %* | findstr /c:`"check-ignore`" >nul || goto run`r`n>>`"$glog`" echo start`r`nping -n 3 127.0.0.1 >nul`r`n>>`"$glog`" echo done`r`n:run`r`n`"$realGit`" %*`r`nexit /b %errorlevel%`r`n")
  $t0 = Get-Date; $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FCODE_PHIEN_CAP_SEC = '5'; PATH = ($bin + ';' + $env:PATH) }; $sec = ((Get-Date) - $t0).TotalSeconds
  Eq $r.Code 1 $r.Out; Eq ((Screen-Lines $r.Out) -join '|') $FailMsg 'the failure line'
  Ok ($sec -lt 22) "ended at cap + 10 s ($([Math]::Round($sec, 1)) s; the scan alone needs about 26 s)"
  Ok ((Read-PhienLog $w) -match 'lỗi: lần chạy nhanh vượt quá 15 giây nên bị ngắt hẳn') ('logged: ' + (Read-PhienLog $w))
  Start-Sleep -Seconds 3
  $alive = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Fcode) -and $_.CommandLine.Contains('phien proj --nhanh') })
  Eq $alive.Count 0 'no part of the run is still alive'
  $gl = @(Get-Content $glog | ForEach-Object { $_.Trim() }); Eq $gl[-1] 'start' 'the git call under way was ended with it (its "done" never came)'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FCODE_PHIEN_CAP_SEC = '60' }; Eq $r.Code 0 $r.Out
  Eq @(Get-ChildItem $w.BP -Filter 'HANDOFF-*.md').Count 12 'the next run syncs'
}
T 'nhanh r4: --nen waits first (35 s by default, more than the 30 s "being written" rule; FCODE_MOC_DELAY in tests), then syncs; --nen needs --nhanh' {
  $sd = $env:FCODE_MOC_DELAY; $env:FCODE_MOC_DELAY = $null
  try { Eq (Get-PhienNenDelaySec) 35 'the default wait'; Ok ((Get-PhienNenDelaySec) -gt 30) 'longer than the 30 s rule' } finally { $env:FCODE_MOC_DELAY = $sd }
  $w = New-W2 'q23'; Use-LoggedIb $w
  [void](New-Sess $w.LS '23232323-nen1' $w.LP @('a'))
  $p = Invoke-Fcode $w @('phien', 'proj', '--nhanh', '--nen') @{ FCODE_MOC_DELAY = '4' } -NoWait
  try {
    Start-Sleep -Seconds 2; Eq (IbCalls $w).Count 0 'nothing in the first 2 s, not even `instabox ls`'
    Ok ($p.WaitForExit(40000)) 'it ends'; Eq $p.ExitCode 0 'exit 0'
  } finally { $p.Dispose() }
  Eq (BoxSessions $w) 1 'then it synced'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nen'); Eq $r.Code 1 '--nen without --nhanh is refused'
}
# F7: the supervisor's job ends the worker however the supervisor ends; k = ms after its start, -1 = in the middle of sending
function Get-RunTree([int]$Top, [datetime]$Since) {
  $all = @(Get-CimInstance Win32_Process | Where-Object { $_.CreationDate -ge $Since.AddSeconds(-1) })
  $ids = @{ $Top = $true }; $found = New-Object System.Collections.ArrayList; $grew = $true
  while ($grew) { $grew = $false; foreach ($x in $all) { if ($ids.ContainsKey([int]$x.ParentProcessId) -and -not $ids.ContainsKey([int]$x.ProcessId)) { $ids[[int]$x.ProcessId] = $true; [void]$found.Add($x); $grew = $true } } }
  , @($found | Where-Object { $_.Name -ne 'conhost.exe' } | ForEach-Object { "$($_.Name) $($_.ProcessId)" })
}
T 'nhanh r4: the supervisor killed at any moment (before its job, while the worker starts, mid-send): 2 s later nothing of the run is alive, nothing is half-placed' {
  $w = New-W2 'q24'; Use-LoggedIb $w
  $a = New-Sess $w.LS 'aaaa2424-sup1' $w.LP @('a'); Grow-Sess $a 5
  foreach ($k in 0, 60, 150, 400, 1500, -1) {
    $ev = @{ FCODE_PHIEN_CAP_SEC = '60' }
    if ($k -lt 0) { $ev['FAKE_SSH_CUT'] = 'put:1:0:stall'; Remove-Item -LiteralPath $w.Log -ErrorAction SilentlyContinue }
    $t0 = Get-Date; $p = Invoke-Fcode $w @('phien', 'proj', '--nhanh') $ev -NoWait; $kpid = $p.Id
    if ($k -ge 0) { while (((Get-Date) - $t0).TotalMilliseconds -lt $k) { Start-Sleep -Milliseconds 5 } }
    else {
      $until = (Get-Date).AddSeconds(40)
      while ((Calls $w 'put') -lt 1 -and (Get-Date) -lt $until -and -not $p.HasExited) { Start-Sleep -Milliseconds 200 }
      Ok ((Calls $w 'put') -eq 1 -and -not $p.HasExited) 'the run is in the middle of sending'
    }
    Stop-Process -Id $kpid -Force -ErrorAction SilentlyContinue; $p.Dispose()
    Start-Sleep -Seconds 2
    $alive = Get-RunTree $kpid $t0
    foreach ($x in $alive) { Stop-Process -Id ([int]($x -split ' ')[-1]) -Force -ErrorAction SilentlyContinue }   # a failing run must not hang the suite
    Eq $alive.Count 0 "k=$($k): nothing of the run is alive ($($alive -join ', '))"
    Eq (BoxSessions $w) 0 "k=$($k): nothing placed on the box"; Eq (Parts $w.LS) 0 "k=$($k): no part file on the laptop"; Eq (Parts $w.BS) 0 "k=$($k): no part file on the box"
  }
}

# ---- r5: ownership is saved for sure before the line; a release that could not remove the line keeps it; Write-PhienText leftovers ----
# r6 T4: ownership needs no record (the pair is written with the note); a state file that cannot be written still stops the run with the failure line
T 'nhanh r5: handoff-state.json cannot be written: the note from the box is placed with its pair; exit 1, the failure line, the reason logged; writable again: the sha is saved' {
  $w = New-W2 'q25'; Use-LoggedIb $w
  New-GitDir $w.LP; New-GitDir $w.BP
  Put-File "$($w.BP)\HANDOFF.md" 'box handoff'
  $sf = Join-Path $w.U 'AppData\Local\fcode\handoff-state.json'; Put-File $sf '{}'
  $exf = "$($w.LP)\.git\info\exclude"
  (Get-Item -LiteralPath $sf).IsReadOnly = $true
  try {
    $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh')
    Eq $r.Code 1 $r.Out; Eq ((Screen-Lines $r.Out) -join '|') $FailMsg 'the failure line'
    Eq (Get-Content "$($w.LP)\HANDOFF.md" -Raw) 'box handoff' 'the note is placed'
    Ok ((Get-Content $exf -Raw) -match '(?m)^# fcode\r?\n/HANDOFF\.md\r?$') 'with its pair'
    Ok ((Read-PhienLog $w) -match 'lỗi: không ghi được trạng thái ghi chú \(handoff-state\.json\)') ('logged: ' + (Read-PhienLog $w))
    Eq ([IO.File]::ReadAllText($sf)) '{}' 'the state file is unchanged'
  } finally { (Get-Item -LiteralPath $sf).IsReadOnly = $false }
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Eq (Get-Content "$($w.LP)\HANDOFF.md" -Raw) 'box handoff' 'writable again: the note unchanged'
  Ok ($null -ne (Get-Content $sf -Raw | ConvertFrom-Json).PSObject.Properties['proj/HANDOFF.md']) 'and the sha record saved'
}
T 'nhanh r5: a release whose exclude line cannot be removed (.git/info became a link) says so, exit 1, nothing written through the link; once fixed the next run removes the pair' {
  $w = New-W2 'q26'; Use-LoggedIb $w
  New-GitDir $w.LP; New-GitDir $w.BP
  $bo = Join-Path $w.W 'origin.git'; New-Origin $bo
  foreach ($d in $w.LP, $w.BP) { Fetch-Origin $d $bo; $ErrorActionPreference = 'Continue'; & git -C $d checkout -q -B main origin/main 2>&1 | Out-Null; $ErrorActionPreference = 'Stop' }
  Put-File "$($w.BP)\HANDOFF.md" 'box text'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  $sf = Join-Path $w.U 'AppData\Local\fcode\handoff-state.json'; $key = 'exclude:laptop:proj/HANDOFF.md'
  Ok ((Get-Content "$($w.LP)\.git\info\exclude" -Raw) -match '(?m)^# fcode\r?\n/HANDOFF\.md\r?$') 'the pair is in the laptop exclude'
  Eq @((Get-Content $sf -Raw | ConvertFrom-Json).PSObject.Properties | Where-Object { $_.Name -like 'exclude:*' }).Count 0 'no exclude: record'
  $ErrorActionPreference = 'Continue'; Git-Commit $w.BP @('HANDOFF.md'); & git -C $w.BP push -q $bo HEAD:main 2>&1 | Out-Null; & git -C $w.LP fetch -q origin 2>&1 | Out-Null; $ErrorActionPreference = 'Stop'
  $info = "$($w.LP)\.git\info"; $tg = Join-Path $w.W 'info-elsewhere'
  New-InfoJunction $w.LP $tg ([IO.File]::ReadAllText("$info\exclude"))
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 1 $r.Out; Eq ((Screen-Lines $r.Out) -join '|') $FailMsg 'the failure line'
  Ok ((Read-PhienLog $w) -match 'lỗi: ghi chú HANDOFF\.md: chưa gỡ được dòng /HANDOFF\.md của fcode trong \.git/info/exclude') ('logged: ' + (Read-PhienLog $w))
  Ok ((Read-PhienLog $w) -notmatch 'ghi chú HANDOFF\.md giờ do git theo dõi') 'a failed release prints no "xóa được" line (only the error line)'
  Eq @((Get-Content (Join-Path $w.U 'AppData\Local\fcode\phien-status.json') -Raw | ConvertFrom-Json).notes.released).Count 0 'a failed release is not in notes.released'
  Ok ((Get-Content (Join-Path $tg 'exclude') -Raw) -match '(?m)^# fcode\r?\n/HANDOFF\.md\r?$') 'nothing written through the link: the pair is still in the target'
  Ok ($null -ne (Get-Content $sf -Raw | ConvertFrom-Json).PSObject.Properties['proj/HANDOFF.md']) 'the sha record is kept'
  # fixed: a plain folder again (same content); the pair is still there, so the next run gives the line back
  $txt = [IO.File]::ReadAllText((Join-Path $tg 'exclude')); [IO.Directory]::Delete($info); [void](New-Item -ItemType Directory -Path $info); [IO.File]::WriteAllText("$info\exclude", $txt)
  $m = New-LogMark $w
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Eq ([regex]::Matches((Log-Since $w $m), 'ghi chú HANDOFF\.md giờ do git theo dõi').Count) 1 'the healed run prints the release line exactly once'
  $lx = Get-Content "$info\exclude" -Raw
  Ok ($lx -notmatch '(?m)^/HANDOFF\.md\r?$' -and $lx -notmatch '# fcode') 'the pair is given back'
  $st = Get-Content $sf -Raw | ConvertFrom-Json
  Ok ($null -eq $st.PSObject.Properties['proj/HANDOFF.md'] -and $null -eq $st.PSObject.Properties[$key]) 'the state forgets the name (it never had an exclude: record)'
}
# r6 T-L3a (Rule L): only fcode's complete generated names are deleted, on both machines; a lookalike name is never touched however old
T 'nhanh r6: lookalike names are never deleted; fcode''s own dead names are (laptop and box)' {
  $w = New-W2 'q27'; Use-LoggedIb $w
  New-GitDir $w.LP; New-GitDir $w.BP; [void](New-Sess $w.LS '27272727-lft1' $w.LP @('a'))
  Put-File "$($w.BP)\HANDOFF.md" 'box handoff'   # placed on the laptop: the laptop exclude is written in this run
  $gone = Start-Process -FilePath $env:ComSpec -ArgumentList '/c', 'exit' -WindowStyle Hidden -PassThru; $gone.WaitForExit(); $dp = $gone.Id
  $sd = Join-Path $w.U 'AppData\Local\fcode'; $tmp = Join-Path $w.U 'AppData\Local\Temp'; $inf = "$($w.LP)\.git\info"; $h32 = 'cd' * 16
  $old = [DateTime]::UtcNow.AddHours(-2)
  $mk = { param([string]$p, [bool]$dir, [bool]$aged)
    if ($dir) { [void](New-Item -ItemType Directory -Force -Path $p); Put-File (Join-Path $p 'x.tar') 'x' 0; if ($aged) { [IO.File]::SetLastWriteTimeUtc((Join-Path $p 'x.tar'), $old); [IO.Directory]::SetLastWriteTimeUtc($p, $old) } }
    else { Put-File $p 'x' 0; if ($aged) { [IO.File]::SetLastWriteTimeUtc($p, $old) } } }
  # the laptop and the fake box share TEMP here: each sweeps only its own patterns
  $stay = @(@("$tmp\fcode-phien-backup", $true, $true), @("$($w.LS)\s.jsonl.fcode-part-backup", $false, $true), @("$($w.LP)\HANDOFF.md.fcode-part-backup", $false, $true),
    @("$inf\exclude.part-backup", $false, $true), @("$inf\exclude.part-backup.part-123", $false, $true), @("$sd\handoff-state.json.part-x", $false, $true),
    @("$sd\handoff-state.json.part-$PID", $false, $false), @("$inf\exclude.part-$PID", $false, $false),   # this test process: alive and older than the file
    @("$($w.BS)\x.jsonl.fcode-part-backup", $false, $true))
  $go = @(@("$tmp\fcode-phien-$dp-$h32", $true, $false), @("$tmp\fcode-phien-$h32", $true, $true), @("$($w.LS)\s.jsonl.fcode-part-$dp-abcdef", $false, $false),
    @("$inf\exclude.part-$dp", $false, $false), @("$sd\handoff-state.json.part-$dp", $false, $false), @("$sd\phien-status.json.part-$dp", $false, $false), @("$sd\phien-auto.json.part-$dp", $false, $false),
    @("$tmp\fcode-phien-abcdefgh", $true, $true), @("$($w.BS)\x.jsonl.fcode-part-123-abcdef", $false, $true))
  foreach ($x in $stay + $go) { & $mk $x[0] $x[1] $x[2] }
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Eq (Get-Content "$($w.LP)\HANDOFF.md" -Raw) 'box handoff' 'the note was placed (the exclude file was written)'
  foreach ($x in $go) { Ok (-not (Test-Path -LiteralPath $x[0])) "removed: $($x[0].Substring($w.W.Length))" }
  foreach ($x in $stay) { Ok (Test-Path -LiteralPath $x[0]) "kept: $($x[0].Substring($w.W.Length))" }
}
# r6 T-L3b: a linked worktree (.git is a file): the exclude file and its leftovers are at the path git names (the main repo's .git\info)
T 'nhanh r6: a project that is a linked worktree: the note is excluded at the path git names and a dead run''s part file there is swept' {
  $w = New-W2 'q28'; Use-LoggedIb $w
  $main = Join-Path $w.W 'main repo'; New-GitDir $main; New-GitDir $w.BP
  $ErrorActionPreference = 'Continue'
  & git -C $main -c user.name=t -c user.email=t@t commit -q --allow-empty -m x 2>&1 | Out-Null
  Remove-Item -LiteralPath $w.LP -Recurse -Force; & git -C $main worktree add -q $w.LP 2>&1 | Out-Null
  $ErrorActionPreference = 'Stop'
  Ok (Test-Path -LiteralPath "$($w.LP)\.git" -PathType Leaf) '.git is a file in the worktree'
  Put-File "$($w.BP)\HANDOFF.md" 'box handoff'
  $gone = Start-Process -FilePath $env:ComSpec -ArgumentList '/c', 'exit' -WindowStyle Hidden -PassThru; $gone.WaitForExit(); $dp = $gone.Id
  $dead = "$main\.git\info\exclude.part-$dp"; Put-File $dead 'x' 0
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Eq (Get-Content "$($w.LP)\HANDOFF.md" -Raw) 'box handoff' 'placed in the worktree'
  Ok ((Get-Content "$main\.git\info\exclude" -Raw) -match '(?m)^# fcode\r?\n/HANDOFF\.md\r?$') 'the pair is in the main repo''s exclude (the path git names)'
  Ok (-not (Test-Path -LiteralPath $dead)) 'the dead part file there is swept'
  Ok (-not (Test-Path -LiteralPath "$($w.LP)\.git\info")) 'no .git\info folder made in the worktree'
  Eq ((& git -C $w.LP status --porcelain | Out-String).Trim()) '' 'git status in the worktree is clean'
}
function Get-NoteState($w) { $sf = Join-Path $w.U 'AppData\Local\fcode\handoff-state.json'; if (Test-Path $sf) { Get-Content $sf -Raw | ConvertFrom-Json } else { [pscustomobject]@{} } }
function Set-NoteState($w, [hashtable]$S) { Put-File (Join-Path $w.U 'AppData\Local\fcode\handoff-state.json') ($S | ConvertTo-Json -Compress) 0 }
function Get-DeadPid { $g = Start-Process -FilePath $env:ComSpec -ArgumentList '/c', 'exit' -WindowStyle Hidden -PassThru; $g.WaitForExit(); $g.Id }
# r6 T-L5: the state file is read strictly; a broken one stops the run before any change (and names the file)
T 'nhanh r6: a handoff-state.json that is not a JSON object stops the run before anything is changed' {
  $w = New-W2 'q29'; Use-LoggedIb $w
  New-GitDir $w.LP; New-GitDir $w.BP
  Put-File "$($w.BP)\HANDOFF.md" 'box handoff'
  $sf = Join-Path $w.U 'AppData\Local\fcode\handoff-state.json'; $exf = "$($w.LP)\.git\info\exclude"; $ex0 = Read-Bytes $exf
  foreach ($bad in '{', '42', 'null', '[{}]', '[{"exclude:laptop:proj/HANDOFF.md":"1"}]') {
    Put-File $sf $bad 0; $b0 = Read-Bytes $sf; $m = New-LogMark $w
    $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh')
    Eq $r.Code 1 "[$bad] $($r.Out)"; Eq ((Screen-Lines $r.Out) -join '|') $FailMsg "[$bad] the failure line"
    Ok ((Log-Since $w $m) -match 'lỗi: không đọc được trạng thái ghi chú \(handoff-state\.json\)') "[$bad] logged: $(Log-Since $w $m)"
    Ok (Bytes-Eq (Read-Bytes $sf) $b0) "[$bad] the state bytes are unchanged"
    Ok (-not (Test-Path "$($w.LP)\HANDOFF.md")) "[$bad] the note is not placed"; Ok (Bytes-Eq (Read-Bytes $exf) $ex0) "[$bad] the exclude file is unchanged"
  }
  Remove-Item -LiteralPath $sf
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Eq (Get-Content "$($w.LP)\HANDOFF.md" -Raw) 'box handoff' 'the file deleted: the next run places the note'
}
# r6 T-L2a: a 1.3.2/1.3.3 record whose line is not there any more ('absent') is forgotten by the release, exit 0
T 'nhanh r6: a legacy record whose line the user already removed: the release forgets it, exit 0' {
  $w = New-W2 'q30'; Use-LoggedIb $w
  New-GitDir $w.LP; New-GitDir $w.BP
  $bo = Join-Path $w.W 'origin.git'; New-Origin $bo; Push-Origin $bo 'HANDOFF.md' 'in git'; Fetch-Origin $w.LP $bo
  Put-File "$($w.LP)\HANDOFF.md" 'laptop copy'
  Set-NoteState $w @{ 'exclude:laptop:proj/HANDOFF.md' = '1'; 'proj/HANDOFF.md' = 'x' }
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Ok ((Read-PhienLog $w) -match 'ghi chú HANDOFF\.md giờ do git theo dõi \(trên origin\): bản cũ trên laptop xóa được') ('release line: ' + (Read-PhienLog $w))
  $st = Get-NoteState $w
  Ok ($null -eq $st.PSObject.Properties['exclude:laptop:proj/HANDOFF.md'] -and $null -eq $st.PSObject.Properties['proj/HANDOFF.md']) 'both records are forgotten'
}
# r6 T3: ownership comes from the box's own file, never from a reply: a lost reply cannot turn the user's line into fcode's
T 'nhanh r6: a put whose reply is lost, onto a box that already had the user''s own /HANDOFF.md line: no ownership, the user''s line is never removed' {
  $w = New-W2 'q31'; Use-LoggedIb $w
  New-GitDir $w.LP; New-GitDir $w.BP
  $bex = "$($w.BP)\.git\info\exclude"; [IO.File]::WriteAllText($bex, "# mine`n/HANDOFF.md`n"); $b0 = Read-Bytes $bex
  Put-File "$($w.LP)\HANDOFF.md" 'laptop handoff'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FAKE_SSH_CUT = 'put:1:0:noack' }
  Eq $r.Code 1 $r.Out
  Eq (Get-Content "$($w.BP)\HANDOFF.md" -Raw) 'laptop handoff' 'the box has the note'; Ok (Bytes-Eq (Read-Bytes $bex) $b0) 'the box exclude is unchanged'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Eq ((@((Get-NoteState $w).PSObject.Properties | ForEach-Object { $_.Name })) -join ',') 'proj/HANDOFF.md' 'the state is the sha record only'
  Git-Commit $w.LP @('HANDOFF.md'); $m = New-LogMark $w
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Ok ((Log-Since $w $m) -notmatch 'giờ do git theo dõi') ('no release: ' + (Log-Since $w $m))
  Ok (Bytes-Eq (Read-Bytes $bex) $b0) 'the user''s line is still there, the file byte for byte'
}
# r6 T5: 1.3.2/1.3.3 lines (bare, remembered by a record) are released by the record on both machines; a link keeps the record
T 'nhanh r6: lines of 1.3.2/1.3.3 (bare, with a record) are still released by the record (laptop and box); a linked .git/info keeps it' {
  $w = New-W2 'q32'; Use-LoggedIb $w
  New-GitDir $w.LP; New-GitDir $w.BP
  $n = 'HANDOFF-legacy.md'; $user = "# mine`n/$n`n/keep`n"
  $bo = Join-Path $w.W 'origin.git'; New-Origin $bo; Push-Origin $bo $n 'in git'; Fetch-Origin $w.LP $bo
  Put-File "$($w.LP)\$n" 'laptop copy'
  Set-NoteState $w @{ "exclude:laptop:proj/$n" = '1'; "proj/$n" = 'x' }
  $info = "$($w.LP)\.git\info"; $tg = Join-Path $w.W 'info-elsewhere'; New-InfoJunction $w.LP $tg $user
  $m = New-LogMark $w
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 1 $r.Out; Eq ((Screen-Lines $r.Out) -join '|') $FailMsg 'the failure line'
  Ok ((Read-PhienLog $w) -match 'lỗi: ghi chú HANDOFF-legacy\.md: chưa gỡ được dòng /HANDOFF-legacy\.md của fcode trong \.git/info/exclude') ('logged: ' + (Read-PhienLog $w))
  Ok ((Log-Since $w $m) -notmatch 'ghi chú HANDOFF-legacy\.md giờ do git theo dõi') 'a failed release prints no "xóa được" line (only the error line)'
  Eq @((Get-Content (Join-Path $w.U 'AppData\Local\fcode\phien-status.json') -Raw | ConvertFrom-Json).notes.released).Count 0 'a failed release is not in notes.released'
  Eq (Get-NoteState $w)."exclude:laptop:proj/$n" '1' 'the record is kept'; Eq ([IO.File]::ReadAllText((Join-Path $tg 'exclude'))) $user 'nothing written through the link'
  [IO.Directory]::Delete($info); [void](New-Item -ItemType Directory -Path $info); [IO.File]::WriteAllText("$info\exclude", $user)
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Ok ((Read-PhienLog $w) -match 'ghi chú HANDOFF-legacy\.md giờ do git theo dõi \(trên origin\): bản cũ trên laptop xóa được') 'the laptop release line'
  Eq ([IO.File]::ReadAllText("$info\exclude")) "# mine`n/keep`n" 'laptop: the bare line removed, the other lines intact'
  Ok ($null -eq (Get-NoteState $w).PSObject.Properties["exclude:laptop:proj/$n"]) 'laptop: the record is gone'
  # box half: a bare line on the box remembered by exclude:box:, the name now tracked on the laptop
  Put-File "$($w.BP)\$n" 'box copy'; [IO.File]::WriteAllText("$($w.BP)\.git\info\exclude", $user)
  $s = @{}; foreach ($q in (Get-NoteState $w).PSObject.Properties) { $s[$q.Name] = [string]$q.Value }; $s["exclude:box:proj/$n"] = '1'; Set-NoteState $w $s
  Git-Commit $w.LP @($n)
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Ok ((Read-PhienLog $w) -match 'ghi chú HANDOFF-legacy\.md giờ do git theo dõi \(trên laptop\): bản cũ trên box xóa được') 'the box release line'
  Eq ([IO.File]::ReadAllText("$($w.BP)\.git\info\exclude")) "# mine`n/keep`n" 'box: the bare line removed (unexcluded), the other lines intact'
  Ok ($null -eq (Get-NoteState $w).PSObject.Properties["exclude:box:proj/$n"]) 'box: the record is gone'
}
# r6 T6 (O5): a release the box could not do is a failure; nothing is forgotten; the pair is still there for the next run
T 'nhanh r6: the box cannot find its exclude file during a release: failure line, exit 1, nothing forgotten; fixed: removed' {
  $w = New-W2 'q33'; Use-LoggedIb $w 'gitbreak'
  New-GitDir $w.LP; New-GitDir $w.BP
  Put-File "$($w.LP)\HANDOFF-lap.md" 'from laptop'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  $bex = "$($w.BP)\.git\info\exclude"; Ok ((Get-Content $bex -Raw) -match '(?m)^# fcode\r?\n/HANDOFF-lap\.md\r?$') 'the pair on the box'
  Git-Commit $w.LP @('HANDOFF-lap.md')
  $bpw = $w.BP -replace '/', '\'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FAKE_BP = $bpw }
  Ok (Test-Path -LiteralPath "$bpw\.git-x") ('the wrapper broke the box repo before the put: ' + (Read-PhienLog $w))
  Rename-Item -LiteralPath "$bpw\.git-x" -NewName '.git'
  Eq $r.Code 1 $r.Out; Eq ((Screen-Lines $r.Out) -join '|') $FailMsg 'the failure line'
  Ok ((Read-PhienLog $w) -match '\[proj\] lỗi: ghi chú HANDOFF-lap\.md: box chưa gỡ được dòng /HANDOFF-lap\.md của fcode trong \.git/info/exclude \(liên kết, git trên box lỗi, hoặc chưa tạo được \.fcode/\.gitignore\), lần sau thử lại') ('logged: ' + (Read-PhienLog $w))
  Ok ((Read-PhienLog $w) -notmatch 'ghi chú HANDOFF-lap\.md giờ do git theo dõi') 'a failed box release prints no "xóa được" line (only the error line)'
  Eq @((Get-Content (Join-Path $w.U 'AppData\Local\fcode\phien-status.json') -Raw | ConvertFrom-Json).notes.released).Count 0 'a failed box release is not in notes.released'
  Ok ((Get-Content $bex -Raw) -match '(?m)^# fcode\r?\n/HANDOFF-lap\.md\r?$') 'the pair is still on the box'
  Ok ($null -ne (Get-NoteState $w).PSObject.Properties['proj/HANDOFF-lap.md']) 'nothing forgotten'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Ok ((Get-Content $bex -Raw) -notmatch 'HANDOFF-lap|# fcode') 'fixed: the pair is gone'
  Ok ($null -eq (Get-NoteState $w).PSObject.Properties['proj/HANDOFF-lap.md']) 'and forgotten'
}
# r6 T7 (O6): the box writes its exclude file through write_exclude only (part + os.replace); injected failures leave it as it was
T 'notes r6: the box rewrites .git/info/exclude atomically and sweeps only its own part files beside it' {
  foreach ($fn in 'ensure_excluded', 'unexclude') {
    $mm = [regex]::Match($PhienPy, "(?ms)^def $fn\(.*?(?=^\S)")
    Ok $mm.Success "found $fn"; Ok ($mm.Value -notmatch 'open\(') "$fn opens no file itself (reads: read_exclude, writes: append_exclude / write_exclude)"
  }
  $d = Join-Path $Root 't7'; [void](New-Item -ItemType Directory -Force -Path $d); $p = Join-Path $d 'exclude'; $drv = Join-Path $Root 't7.py'
  [IO.File]::WriteAllText($drv, ("import os, runpy, sys`nm = runpy.run_path(sys.argv[1], run_name='x')`np, missing = sys.argv[2], sys.argv[3]`norig = b'# user\r\n/a\r\n'`n" +
    "def reset():`n    open(p, 'wb').write(orig)`ndef parts():`n    return [n for n in os.listdir(os.path.dirname(p)) if '.fcode-part-' in n]`n" +
    "def boom(a, b):`n    raise OSError('x')`nreset()`nreal = os.replace`nos.replace = boom`n" +
    "try:`n    m['write_exclude'](p, b'new')`n    print('A-no-raise')`nexcept OSError:`n    print('A-raised')`nos.replace = real`nprint(open(p, 'rb').read() == orig, parts() == [])`n" +
    "reset()`ng = m['write_exclude'].__globals__`nrp = g['part_name']`ng['part_name'] = lambda q: os.path.join(missing, 'x')`n" +
    "try:`n    m['write_exclude'](p, b'new')`n    print('B-no-raise')`nexcept OSError:`n    print('B-raised')`ng['part_name'] = rp`nprint(open(p, 'rb').read() == orig, parts() == [])`n" +
    "m['write_exclude'](p, b'new')`nprint(open(p, 'rb').read() == b'new', parts() == [])`n"))
  $out = @(python -I $drv $PyFile $p (Join-Path $d 'missing-dir'))
  Eq ($out -join ',') 'A-raised,True True,B-raised,True True,True True' 'os.replace fails: raised, bytes unchanged, no part; staging fails: the same; a good write replaces it'
  # end to end: the user's rules survive add + remove byte for byte; the next write sweeps fcode's dead / old part files there, nothing else
  $w = New-W2 'q34'; New-GitDir $w.LP; New-GitDir $w.BP
  $bi = "$($w.BP)\.git\info"; $bex = "$bi\exclude"; [IO.File]::WriteAllText($bex, "# user rules`n/one`n*.log`n"); $b0 = Read-Bytes $bex
  $dp = Get-DeadPid
  $deadp = "$bi\exclude.fcode-part-$dp-abcdef"; $oldp = "$bi\exclude.fcode-part-$PID-abcdef"; $keep = "$bi\exclude.fcode-part-backup"
  foreach ($f in $deadp, $oldp, $keep) { Put-File $f 'x' 0 }; foreach ($f in $oldp, $keep) { [IO.File]::SetLastWriteTimeUtc($f, [DateTime]::UtcNow.AddHours(-2)) }
  Put-File "$($w.LP)\HANDOFF.md" 'laptop handoff'
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Ok ((Get-Content $bex -Raw) -match '(?m)^# fcode\r?\n/HANDOFF\.md\r?$') 'added: the pair'
  Ok (-not (Test-Path -LiteralPath $deadp)) 'a dead run''s part file is swept'; Ok (-not (Test-Path -LiteralPath $oldp)) 'a part file over 1 h old is swept'
  Ok (Test-Path -LiteralPath $keep) 'a lookalike name stays'
  Git-Commit $w.LP @('HANDOFF.md')
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Ok (Bytes-Eq (Read-Bytes $bex) $b0) 'removed: the user''s three rules byte for byte'
  Eq @(Get-ChildItem -LiteralPath $bi -Force -Filter 'exclude.fcode-part-*' | Where-Object { $_.Name -ne 'exclude.fcode-part-backup' }).Count 0 'no part file of fcode left'
}
# r6 T8: both machines edit .git/info/exclude as bytes, keeping the file's newline; the pattern is the note name's UTF-8 bytes (what git reads)
T 'nhanh r6: .git/info/exclude is edited as bytes on both machines: CRLF, a Latin-1 byte and a Vietnamese note name survive add + remove' {
  $w = New-W2 'q35'; Use-LoggedIb $w
  New-GitDir $w.LP; New-GitDir $w.BP
  $lat = [Text.Encoding]::GetEncoding(28591)
  $orig = $lat.GetBytes("# mine`r`n/caf" + [char]0xE9 + ".txt`r`n/keep`r`n")
  foreach ($d in $w.LP, $w.BP) { [IO.File]::WriteAllBytes("$d\.git\info\exclude", $orig) }
  $nl = 'HANDOFF-ghi-chú.md'; $nb = 'HANDOFF-ghi-chú-b.md'
  Put-File "$($w.LP)\$nl" 'from laptop'; Put-File "$($w.BP)\$nb" 'from box'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Ok (Bytes-Eq (Read-Bytes "$($w.BP)\.git\info\exclude") ([byte[]]($orig + $utf8.GetBytes("# fcode`r`n/$nl`r`n")))) ('box: the original bytes + the pair in CRLF, the name in UTF-8: ' + (Latin "$($w.BP)\.git\info\exclude"))
  Ok (Bytes-Eq (Read-Bytes "$($w.LP)\.git\info\exclude") ([byte[]]($orig + $utf8.GetBytes("# fcode`r`n/$nb`r`n")))) ('laptop: the same: ' + (Latin "$($w.LP)\.git\info\exclude"))
  $ErrorActionPreference = 'Continue'
  & git -C $w.BP check-ignore -q -- $nl; $ib = $LASTEXITCODE; & git -C $w.LP check-ignore -q -- $nb; $il = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  Eq "$ib,$il" '0,0' 'git ignores both notes by those patterns'
  Git-Commit $w.LP @($nl); Git-Commit $w.BP @($nb)
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Ok (Bytes-Eq (Read-Bytes "$($w.BP)\.git\info\exclude") $orig) ('box: released, the original bytes: ' + (Latin "$($w.BP)\.git\info\exclude"))
  Ok (Bytes-Eq (Read-Bytes "$($w.LP)\.git\info\exclude") $orig) ('laptop: released, the original bytes: ' + (Latin "$($w.LP)\.git\info\exclude"))
}
# r6 T10: an exclude file that cannot be read means no note work for that project this run (never "no line of ours"), then the release
T 'nhanh r6: an exclude file that cannot be read: no note work for that project this run, then the release (laptop and box)' {
  # laptop: the pair from a placement, the name then tracked on the box (fetched)
  $w = New-W2 'q36'; Use-LoggedIb $w
  New-GitDir $w.LP; New-GitDir $w.BP
  Put-File "$($w.BP)\HANDOFF.md" 'box text'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Git-Commit $w.BP @('HANDOFF.md')
  $exf = "$($w.LP)\.git\info\exclude"; $m = New-LogMark $w
  $fs = [IO.File]::Open($exf, 'Open', 'Read', 'None')
  try { $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') } finally { $fs.Dispose() }
  Eq $r.Code 0 $r.Out
  $lg = Log-Since $w $m
  Ok ($lg -match 'không đọc được \.git/info/exclude \(.+\), bỏ qua ghi chú của dự án này lần này') ('the log line: ' + $lg)
  Ok ($lg -notmatch 'giờ do git theo dõi') 'no release'; Ok ((Get-Content $exf -Raw) -match '(?m)^# fcode\r?\n/HANDOFF\.md\r?$') 'the pair intact'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Ok ((Get-Content $exf -Raw) -notmatch 'HANDOFF') 'unlocked: released'
  # box: the pair on the box, the name then tracked on the laptop, and a new laptop note waiting
  $w = New-W2 'q37'; Use-LoggedIb $w
  New-GitDir $w.LP; New-GitDir $w.BP
  Put-File "$($w.LP)\HANDOFF-lap.md" 'from laptop'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Git-Commit $w.LP @('HANDOFF-lap.md'); Put-File "$($w.LP)\HANDOFF-2.md" 'second'
  $bex = "$($w.BP)\.git\info\exclude"; $m = New-LogMark $w
  $fs = [IO.File]::Open($bex, 'Open', 'Read', 'None')
  try { $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') } finally { $fs.Dispose() }
  Eq $r.Code 0 $r.Out
  Ok ((Log-Since $w $m) -notmatch 'giờ do git theo dõi') 'no release'; Ok (-not (Test-Path "$($w.BP)\HANDOFF-2.md")) 'no note work for the project: HANDOFF-2.md not sent'
  Ok ((Get-Content $bex -Raw) -match '(?m)^# fcode\r?\n/HANDOFF-lap\.md\r?$') 'the pair intact'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Ok ((Get-Content $bex -Raw) -notmatch 'HANDOFF-lap') 'unlocked: released'; Eq (Get-Content "$($w.BP)\HANDOFF-2.md" -Raw) 'second' 'and HANDOFF-2.md sent'
}
# r7 R2-2: git answers `ls-files` but not `rev-parse --git-path` (exit 128): no note work for that project this run, on either direction, nothing written
T 'nhanh r7: a git whose rev-parse --git-path fails after ls-files answered: no note work for that project this run, nothing written; the next run works' {
  $w = New-W2 'q38'; Use-LoggedIb $w
  New-GitDir $w.LP; New-GitDir $w.BP
  Put-File "$($w.LP)\HANDOFF-lap.md" 'from laptop'; Put-File "$($w.BP)\HANDOFF-box.md" 'from box'
  $lex = "$($w.LP)\.git\info\exclude"; $bex = "$($w.BP)\.git\info\exclude"; $l0 = Read-Bytes $lex; $b0 = Read-Bytes $bex
  $realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
  $bin = Join-Path $w.W 'shim'; [void](New-Item -ItemType Directory -Path $bin -Force); $glog = Join-Path $w.W 'git-calls.log'
  [IO.File]::WriteAllText((Join-Path $bin 'git.cmd'), "@echo off`r`n>>`"$glog`" echo %*`r`necho %* | findstr /c:`"--git-path`" >nul && exit /b 128`r`n`"$realGit`" %*`r`nexit /b %errorlevel%`r`n")
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ PATH = ($bin + ';' + $env:PATH) }
  Eq $r.Code 0 $r.Out
  $gl = Get-Content $glog -Raw; Ok ($gl -match 'ls-files' -and $gl -match '--git-path') ('the shim saw ls-files, then the failing --git-path: ' + $gl)
  Ok (-not (Test-Path "$($w.LP)\HANDOFF-box.md")) 'box -> laptop: not placed'; Ok (-not (Test-Path "$($w.BP)\HANDOFF-lap.md")) 'laptop -> box: not sent'
  Ok (Bytes-Eq (Read-Bytes $lex) $l0) 'the laptop exclude file is unchanged'; Ok (Bytes-Eq (Read-Bytes $bex) $b0) 'the box exclude file is unchanged'
  Eq @((Get-NoteState $w).PSObject.Properties).Count 0 'no state recorded'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Eq (Get-Content "$($w.LP)\HANDOFF-box.md" -Raw) 'from box' 'the next run places the box note'; Eq (Get-Content "$($w.BP)\HANDOFF-lap.md" -Raw) 'from laptop' 'and sends the laptop one'
}
# r7: the box program, driven directly (a throwaway repo; os.path.islink is patched, creating a link needs privileges on Windows and a junction is no link to Python)
function Invoke-BoxDriver([string]$Name, [string]$Body, [string]$Dir) {
  $drv = Join-Path $Root "$Name.py"
  [IO.File]::WriteAllText($drv, ("import os, runpy, sys`nm = runpy.run_path(sys.argv[1], run_name='x')`nd = sys.argv[2]`ng = m['place_note'].__globals__`n" +
    "p = os.path.join(d, '.git', 'info', 'exclude')`ninfo = os.path.dirname(p)`nname = 'HANDOFF.md'`n" + ($Body -replace "`r`n", "`n")), $utf8)
  @(python -I $drv $PyFile $Dir)
}
# r7 R2-1: place_note puts the pair first, then moves the note; a failed pair leaves no note on the box
T 'notes r7: the box places the note only after its exclude pair is in; a failed pair leaves no note and no part file' {
  $d = Join-Path $Root 'r7a'; New-GitDir $d; $src = Join-Path $Root 'r7a-src.md'; Put-File $src 'note'
  $out = Invoke-BoxDriver 'r7a' ("src = os.path.join(os.path.dirname(d), 'r7a-src.md')`ndst = os.path.join(d, name)`n" +
    "def parts():`n    return [n for n in os.listdir(d) if '.fcode-part-' in n]`n" +
    "real = g['ensure_excluded']`n" +
    "def boom(*a):`n    raise OSError('x')`n" +
    "g['ensure_excluded'] = boom`nprint(m['place_note'](d, name, src, ''), os.path.exists(dst), parts() == [])`n" +
    "g['ensure_excluded'] = lambda *a: False`nprint(m['place_note'](d, name, src, ''), os.path.exists(dst), parts() == [])`n" +
    "seen = []`ndef spy(dd, n):`n    seen.append(os.path.exists(dst))`n    return real(dd, n)`n" +
    "g['ensure_excluded'] = spy`nprint(m['place_note'](d, name, src, ''), os.path.exists(dst), seen, parts() == [])`n" +
    "print(b'# fcode\n/HANDOFF.md\n' in open(p, 'rb').read().replace(b'\r\n', b'\n'))`n") $d
  Eq ($out -join ',') 'failed False True,failed False True,ok True [False] True,True' 'ensure raises: no note; ensure False: no note; real order: the note was not there yet when the pair was written; the pair is in'
}
# r7 R2-3: the box refuses a link as its exclude file or the folder of it, like the laptop: nothing written through or over it
T 'notes r7: the box never writes through or over a linked .git/info/exclude or .git/info (ensure and unexclude)' {
  $d = Join-Path $Root 'r7b'; New-GitDir $d
  $out = Invoke-BoxDriver 'r7b' ("orig = b'# user\n/keep\n'`nlinks = set()`nreal = os.path.islink`nos.path.islink = lambda q: os.path.normpath(q) in links`n" +
    "def parts():`n    return [n for n in os.listdir(info) if '.fcode-part-' in n]`n" +
    "def untouched(b):`n    return open(p, 'rb').read() == b and parts() == []`n" +
    "for target in (p, info):`n    links.clear()`n    links.add(os.path.normpath(target))`n" +
    "    open(p, 'wb').write(orig)`n    print(m['ensure_excluded'](d, name), untouched(orig))`n" +
    "    paired = orig + b'# fcode\n/HANDOFF.md\n'`n    open(p, 'wb').write(paired)`n    print(m['unexclude'](d, name, False), m['unexclude'](d, name, True), untouched(paired))`n" +
    "links.clear()`nopen(p, 'wb').write(orig)`nprint(m['ensure_excluded'](d, name), open(p, 'rb').read() == orig + b'# fcode\n/HANDOFF.md\n')`n" +
    "print(m['unexclude'](d, name, False), open(p, 'rb').read() == orig)`n") $d
  Eq ($out -join ',') 'False True,False False True,False True,False False True,True True,True True' 'file link and folder link: ensure False and unwritten, unexclude False and unwritten; no link: both work'
}
# r7 (no change): a file without a final newline gets a separator newline before the pair and keeps it after the pair goes (laptop and box)
T 'notes r7: an exclude file without a final newline: the separator newline fcode adds stays after add + remove (laptop and box)' {
  $f = Join-Path $Root 'r7c\exclude'; Put-File $f 'abc'
  Eq (Add-PhienExcludeLine $f 'HANDOFF.md') $true; Eq (Latin $f) "abc`n# fcode`n/HANDOFF.md`n" 'laptop: separator newline, then the pair'
  Eq (Remove-PhienNoteExclude $f 'HANDOFF.md' $false) 'removed'; Eq (Latin $f) "abc`n" 'laptop: the pair is gone, the separator newline stays (one byte more than the user''s file)'
  $d = Join-Path $Root 'r7d'; New-GitDir $d
  $out = Invoke-BoxDriver 'r7d' ("open(p, 'wb').write(b'abc')`nprint(m['ensure_excluded'](d, name), open(p, 'rb').read() == b'abc\n# fcode\n/HANDOFF.md\n')`n" +
    "print(m['unexclude'](d, name, False), open(p, 'rb').read() == b'abc\n')`n") $d
  Eq ($out -join ',') 'True True,True True' 'box: the same'
}
# r9 (mixed versions, decision-134-r3): the box ADDS its pair with one O_APPEND write (it composes with the 1.3.3 server's own append of "/.fcode/"),
# only the release rewrites the file, and before that rewrite .fcode/.gitignore = "*" is made to exist (a lost "/.fcode/" line then exposes nothing)
T 'notes r9: a /.fcode/ line a 1.3.3 server appends while the box adds its pair is kept; one appended inside a release''s rewrite is lost, but .fcode/.gitignore made before it keeps the uploads hidden' {
  $d = Join-Path $Root 'r9a'; New-GitDir $d
  $out = Invoke-BoxDriver 'r9a' @'
import subprocess, shutil
fc = os.path.join(d, '.fcode')
gi = os.path.join(fc, '.gitignore')
def ign(rel):
    return subprocess.run(['git', '-C', d, 'check-ignore', '-q', '--', rel]).returncode == 0
def parts():
    return [n for n in os.listdir(info) if '.fcode-part-' in n]
def mkup():
    os.makedirs(os.path.join(fc, 'uploads'))
    open(os.path.join(fc, 'uploads', 'x.png'), 'wb').write(b'x')
real = g['read_exclude']
def racy(q):
    b = real(q)
    if os.path.normpath(q) == os.path.normpath(p):
        open(q, 'ab').write(b'/.fcode/\n')
    return b
g['read_exclude'] = racy
open(p, 'wb').write(b'# user\n/keep\n')
print(m['ensure_excluded'](d, name), open(p, 'rb').read() == b'# user\n/keep\n/.fcode/\n# fcode\n/HANDOFF.md\n', not os.path.exists(fc))
mkup()
print(ign('.fcode/uploads/x.png'), ign(name), parts() == [], not os.path.exists(gi))
shutil.rmtree(fc)
open(p, 'wb').write(b'# user\n/keep\n# fcode\n/HANDOFF.md\n')
# the release cuts the file again right before the write (1.3.6), so the append that is lost is the one inside the write itself
g['read_exclude'] = real
realw = g['write_exclude']
def racyw(q, data):
    open(q, 'ab').write(b'/.fcode/\n')
    return realw(q, data)
g['write_exclude'] = racyw
print(m['unexclude'](d, name, False), open(p, 'rb').read() == b'# user\n/keep\n', open(gi, 'rb').read() == b'*\n', sorted(os.listdir(fc)) == ['.gitignore'])
mkup()
print(ign('.fcode/uploads/x.png'), subprocess.run(['git', '-C', d, 'status', '--porcelain'], capture_output=True, text=True).stdout.strip() == '')
'@ $d
  Eq ($out -join ',') 'True True True,True True True True,True True True True,True True' 'add: both appends kept, nothing created; the uploads made after are ignored; release: the line is lost, the folder own .gitignore hides the uploads, git status is clean'
}
# r11 (release 1.3.5): a release gates the rewrite on the config projects a 1.3.3 server can write "/<prefix>.fcode/" for and that share the exclude file
# (realpath compared): sub-folder projects and linked work trees that are projects, not every work tree root
T 'notes r11: a: a sub-folder project of the same repository is gated: its uploads stay ignored although the release lost the 1.3.3 line' {
  $d = Join-Path $Root 'r11a'; New-GitDir $d
  $out = Invoke-BoxDriver 'r11a' @'
import subprocess
def G(*a, cwd=d):
    return subprocess.run(['git', '-C', cwd] + list(a), capture_output=True, text=True)
web = os.path.join(d, 'web')
os.makedirs(web)
projs = {'root': d, 'web': web}
realw = g['write_exclude']   # the 1.3.3 line lands inside the write: the release cuts again right before it (1.3.6), so only this one is lost
def racy(q, data):
    open(q, 'ab').write(b'/web/.fcode/\n')
    return realw(q, data)
g['write_exclude'] = racy
open(p, 'wb').write(b'# user\n# fcode\n/HANDOFF.md\n')
print(m['unexclude'](d, name, False, projs), open(p, 'rb').read() == b'# user\n')
os.makedirs(os.path.join(web, '.fcode', 'uploads'))
open(os.path.join(web, '.fcode', 'uploads', 'x.png'), 'wb').write(b'x')
print(G('check-ignore', '-q', '--', '.fcode/uploads/x.png', cwd=web).returncode == 0, G('status', '--porcelain').stdout.strip() == '', open(os.path.join(web, '.fcode', '.gitignore'), 'rb').read() == b'*\n', open(os.path.join(d, '.fcode', '.gitignore'), 'rb').read() == b'*\n')
'@ $d
  Eq ($out -join ',') 'True True,True True True True' 'release True; the line of web is lost but web/.fcode/.gitignore and the root one hide the uploads, git status is clean'
}
T 'notes r11: b: a linked work tree whose project is a sub-folder is gated; a work tree root that is not a project is never touched' {
  $d = Join-Path $Root 'r11b'; New-GitDir $d
  $out = Invoke-BoxDriver 'r11b' @'
import subprocess
def G(*a, cwd=d):
    return subprocess.run(['git', '-C', cwd] + list(a), capture_output=True, text=True)
G('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'x')
B = os.path.join(os.path.dirname(d), 'r11b-B')
G('worktree', 'add', '-q', B)
bapp = os.path.join(B, 'app')
os.makedirs(bapp)
projs = {'root': d, 'bapp': bapp}
realw = g['write_exclude']   # the 1.3.3 line lands inside the write: the release cuts again right before it (1.3.6), so only this one is lost
def racy(q, data):
    open(q, 'ab').write(b'/app/.fcode/\n')
    return realw(q, data)
g['write_exclude'] = racy
open(p, 'wb').write(b'# user\n# fcode\n/HANDOFF.md\n')
print(m['unexclude'](d, name, False, projs), open(p, 'rb').read() == b'# user\n')
os.makedirs(os.path.join(bapp, '.fcode', 'uploads'))
open(os.path.join(bapp, '.fcode', 'uploads', 'x.png'), 'wb').write(b'x')
print(G('check-ignore', '-q', '--', '.fcode/uploads/x.png', cwd=bapp).returncode == 0, G('status', '--porcelain', cwd=B).stdout.strip() == '', open(os.path.join(bapp, '.fcode', '.gitignore'), 'rb').read() == b'*\n', not os.path.exists(os.path.join(B, '.fcode')))
'@ $d
  Eq ($out -join ',') 'True True,True True True True' 'B/app ignored and clean; B itself (not a project) got no .fcode'
}
T 'notes r11: c: projects that cannot receive an upload line are skipped and never given a .fcode: another repository, a plain folder, a missing folder, a bare repository, a folder inside .git, a relative path, a non-string, the same folder twice' {
  $d = Join-Path $Root 'r11c'; New-GitDir $d
  $out = Invoke-BoxDriver 'r11c' @'
import subprocess
par = os.path.dirname(d)
S = os.path.join(par, 'r11c-S')
N = os.path.join(par, 'r11c-N')
M = os.path.join(par, 'r11c-missing')
Q = os.path.join(par, 'r11c-Q.git')
I = os.path.join(d, '.git', 'sub')
os.makedirs(S)
subprocess.run(['git', '-C', S, 'init', '-q'])
os.makedirs(N)
subprocess.run(['git', 'init', '-q', '--bare', Q])
os.makedirs(I)
projs = {'root': d, 'again': d, 'other': S, 'plain': N, 'gone': M, 'bare': Q, 'inside': I, 'rel': 'rel', 'seven': 7}
open(p, 'wb').write(b'# user\n# fcode\n/HANDOFF.md\n')
print(m['unexclude'](d, name, False, projs), open(p, 'rb').read() == b'# user\n')
print(os.path.exists(os.path.join(d, '.fcode', '.gitignore')), [os.path.exists(os.path.join(x, '.fcode')) for x in (S, N, Q, I)], os.path.exists(M))
'@ $d
  Eq ($out -join ',') 'True True,True [False, False, False, False] False' 'released; only the project itself got .fcode; nothing was made in the other repo, plain folder, bare repo, .git subfolder or the missing folder'
}
T 'notes r11: d + e: a project of the set that cannot be verified (linked .fcode, or git not answering for it) defers the release; fixed, it goes through' {
  $d = Join-Path $Root 'r11d'; New-GitDir $d
  $out = Invoke-BoxDriver 'r11d' @'
web = os.path.join(d, 'web')
os.makedirs(web)
projs = {'root': d, 'web': web}
pair = b'# user\n# fcode\n/HANDOFF.md\n'
def run():
    open(p, 'wb').write(pair)
    return m['unexclude'](d, name, False, projs)
def exb():
    return open(p, 'rb').read()
gw = os.path.join(web, '.fcode', '.gitignore')
links = {os.path.normpath(os.path.join(web, '.fcode'))}
os.makedirs(os.path.join(web, '.fcode'))
os.path.islink = lambda q: os.path.normpath(q) in links
print(run(), exb() == pair, not os.path.exists(gw))
links.clear()
print(run(), exb() == b'# user\n', open(gw, 'rb').read() == b'*\n')
realgit = g['git']
g['git'] = lambda dd, *a: None if (os.path.normpath(dd) == os.path.normpath(web) and a[:1] == ('rev-parse',)) else realgit(dd, *a)
print(run(), exb() == pair)
g['git'] = realgit
print(run(), exb() == b'# user\n')
'@ $d
  Eq ($out -join ',') 'False True True,True True True,False True,True True' 'a linked .fcode in web: False, pair stays, nothing written; then True; git silent for web: False, pair stays; then True'
}
# r12 (release 1.3.6): the box keeps fcode's line while another project that shares the exclude file still depends on it ('kept')
T 'notes r12: a: unexclude answers kept while a project on the shared exclude file holds an untracked copy that only the pair hides; every other state releases; a git failure on the holder test is False, never kept' {
  $d = Join-Path $Root 'r12a'; New-GitDir $d
  $out = Invoke-BoxDriver 'r12a' @'
import subprocess, shutil
def G(*a, cwd=d):
    return subprocess.run(['git', '-C', cwd] + list(a), capture_output=True, text=True)
G('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'x')
par = os.path.dirname(d)
B = os.path.join(par, 'r12a-B')
G('worktree', 'add', '-q', B)
web = os.path.join(d, 'web')
projs = {'root': d, 'b': B}
fb = os.path.join(B, 'HANDOFF.md')
pair = b'# user\n# fcode\n/HANDOFF.md\n'
def reset(data=pair):
    open(p, 'wb').write(data)
def exb():
    return open(p, 'rb').read()
def U(pr=projs, rel=(), legacy=False):
    return m['unexclude'](d, name, legacy, pr, rel)
def nof():
    return not os.path.exists(os.path.join(d, '.fcode')) and not os.path.exists(os.path.join(B, '.fcode'))
realgit = g['git']
realtn = g['tracked_names']
def iseq(x, y):
    return os.path.normpath(x) == os.path.normpath(y)
# 1 untracked copy hidden by the pair only
open(fb, 'w').write('x')
reset()
print(U(), exb() == pair, nof())
# 2 tracked on origin's default branch only, then index-tracked
T = os.path.join(par, 'r12a-T')
O = os.path.join(par, 'r12a-O.git')
os.makedirs(T)
subprocess.run(['git', 'init', '-q', '--bare', O])
subprocess.run(['git', '-C', T, 'init', '-q'])
open(os.path.join(T, 'HANDOFF.md'), 'w').write('in git')
subprocess.run(['git', '-C', T, 'add', 'HANDOFF.md'])
subprocess.run(['git', '-C', T, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'x'])
subprocess.run(['git', '-C', T, 'push', '-q', O, 'HEAD:refs/heads/main'])
G('remote', 'add', 'origin', O)
G('fetch', '-q', 'origin')
reset()
print(U(), exb() == b'# user\n')
G('remote', 'remove', 'origin')
G('add', '-f', 'HANDOFF.md', cwd=B)
reset()
print(U(), exb() == b'# user\n')
G('rm', '-q', '--cached', 'HANDOFF.md', cwd=B)
# 3 independent: B's own .gitignore names /HANDOFF.md
open(os.path.join(B, '.gitignore'), 'w').write('/HANDOFF.md\n')
reset()
print(U(), exb() == b'# user\n', G('check-ignore', '-q', 'HANDOFF.md', cwd=B).returncode == 0)
os.unlink(os.path.join(B, '.gitignore'))
# 4 copy deleted
os.unlink(fb)
reset()
print(U(), exb() == b'# user\n')
open(fb, 'w').write('x')
shutil.rmtree(os.path.join(d, '.fcode'), ignore_errors=True)
shutil.rmtree(os.path.join(B, '.fcode'), ignore_errors=True)
# 5a discovery failure, 5b holder query: check-ignore silent, 5c tracked_names silent, 6 rc 128
g['git'] = lambda dd, *a, **k: None if (iseq(dd, B) and a[:1] == ('rev-parse',)) else realgit(dd, *a, **k)
reset()
print(U(), exb() == pair, nof())
g['git'] = lambda dd, *a, **k: None if (iseq(dd, B) and a[:1] == ('check-ignore',)) else realgit(dd, *a, **k)
reset()
print(U(), exb() == pair)
g['git'] = realgit
g['tracked_names'] = lambda x, s=False: None
reset()
print(U(), exb() == pair)
g['tracked_names'] = realtn
g['git'] = lambda dd, *a, **k: subprocess.CompletedProcess([], 128, b'', b'') if (iseq(dd, B) and a[:1] == ('check-ignore',)) else realgit(dd, *a, **k)
reset()
print(U(), exb() == pair)
g['git'] = realgit
# 6b the upstream half of the holder test: B's copy is in origin's default branch only, and git gives no answer for B's ls-tree (a timeout): False,
# the pair stays (never kept, never released on a guess); with git answering it is released (control)
G('remote', 'add', 'origin', O)
G('fetch', '-q', 'origin')
g['git'] = lambda dd, *a, **k: None if (iseq(dd, B) and a[:1] == ('ls-tree',)) else realgit(dd, *a, **k)
reset()
print(U(), exb() == pair)
g['git'] = realgit
reset()
print(U(), exb() == b'# user\n')
# the other two strict branches of the upstream half: symbolic-ref gives no answer; then (origin/HEAD gone) `rev-parse --verify origin/main` gives none;
# then git answers: the origin/main fallback finds it upstream (released)
g['git'] = lambda dd, *a, **k: None if (iseq(dd, B) and a[:1] == ('symbolic-ref',)) else realgit(dd, *a, **k)
reset()
print(U(), exb() == pair)
G('symbolic-ref', '--delete', 'refs/remotes/origin/HEAD')
g['git'] = lambda dd, *a, **k: None if (iseq(dd, B) and a[:3] == ('rev-parse', '-q', '--verify')) else realgit(dd, *a, **k)
reset()
print(U(), exb() == pair)
g['git'] = realgit
reset()
print(U(), exb() == b'# user\n')
G('remote', 'remove', 'origin')
# 6c a sibling whose rev-parse fails with rc 128 but not "not a git repository" (dubious ownership): False, the pair stays; the real "not a git
# repository" skips that folder (released)
def rp(msg):
    return lambda dd, *a, **k: subprocess.CompletedProcess([], 128, b'', msg) if (iseq(dd, B) and a[:1] == ('rev-parse',) and '--is-inside-work-tree' in a) else realgit(dd, *a, **k)
g['git'] = rp(b'fatal: detected dubious ownership in repository at B\n')
reset()
print(U(), exb() == pair)
g['git'] = rp(b'fatal: not a git repository (or any of the parent directories): .git\n')
reset()
print(U(), exb() == b'# user\n')
# 6d a config project Z whose rev-parse fails with "dubious ownership": while it holds no copy of the note it is skipped (it never blocks a release, and a
# holder B past it is still found); once it holds a regular copy it is a holder candidate and the failure is an error
Z = os.path.join(par, 'r12a-Z')
os.makedirs(Z)
pz = {'root': d, 'b': B, 'z': Z}
g['git'] = lambda dd, *a, **k: subprocess.CompletedProcess([], 128, b'', b'fatal: detected dubious ownership in repository at Z\n') if (iseq(dd, Z) and a[:1] == ('rev-parse',) and '--is-inside-work-tree' in a) else realgit(dd, *a, **k)
os.unlink(fb)
reset()
print(U(pz), exb() == b'# user\n')
open(fb, 'w').write('x')
reset()
print(U(pz), exb() == pair)
open(os.path.join(Z, 'HANDOFF.md'), 'w').write('x')
reset()
print(U(pz), exb() == pair)
os.unlink(os.path.join(Z, 'HANDOFF.md'))
g['git'] = realgit
# 6e order: B holds, and a second candidate C after B (another work tree on the same exclude file, holding a copy) gets no answer from ls-files:
# False (an error), never kept; the answer does not depend on where the failing candidate sits
C = os.path.join(par, 'r12a-C')
G('worktree', 'add', '-q', C)
fc = os.path.join(C, 'HANDOFF.md')
open(fc, 'w').write('x')
g['git'] = lambda dd, *a, **k: None if (iseq(dd, C) and a[:1] == ('ls-files',)) else realgit(dd, *a, **k)
reset()
print(U({'root': d, 'b': B, 'c': C}), exb() == pair)
g['git'] = realgit
os.unlink(fc)
shutil.rmtree(os.path.join(C, '.fcode'), ignore_errors=True)
# 7 the copy sits in a sub-folder project (the /HANDOFF.md line is anchored at the root)
os.unlink(fb)
os.makedirs(web)
open(os.path.join(web, 'HANDOFF.md'), 'w').write('x')
reset()
print(U({'root': d, 'web': web}), exb() == b'# user\n')
os.unlink(os.path.join(web, 'HANDOFF.md'))
open(fb, 'w').write('x')
# 8 legacy: a bare line only
reset(b'# user\n/HANDOFF.md\n')
print(U(legacy=True), exb() == b'# user\n/HANDOFF.md\n')
print(U(legacy=False), exb() == b'# user\n/HANDOFF.md\n')
# 9 both released in one batch: both hold an untracked copy; each one's release holds nothing for the other (True, from either side, pair present);
# a release alone is kept by the other one
open(os.path.join(d, 'HANDOFF.md'), 'w').write('x')
reset()
print(U(rel=[d, B]), exb() == b'# user\n', m['unexclude'](B, name, False, projs, [d, B]))
reset()
print(m['unexclude'](B, name, False, projs, [d, B]))
reset()
print(m['unexclude'](B, name, False, projs, []))
reset()
print(U(rel=[]))
'@ $d
  Eq ($out -join ',') "kept True True,True True,True True,True True True,True True,False True True,False True,False True,False True,False True,True True,False True,False True,True True,False True,True True,True True,kept True,False True,False True,True True,kept True,True True,True True True,True,kept,kept" '1 kept; 2 upstream-only and 2b index-tracked release; 3 independent .gitignore releases and stays hidden; 4 deleted releases; 5a False and nothing made; 5b/5c/6 a git failure on the holder test is False (an error, never kept), the pair stays; 6e a failing candidate after a holder is False too (order-free); 7 sub-folder copy releases; 8 legacy kept, non-legacy untouched; 9 releasing set ends the hold'
}
# r12 (release 1.3.6 P3): the box reads check-ignore's "<source>:<line>:<pattern>" from the known pattern, not by colons
T 'notes r12: b: the box reads check-ignore -v -z (never quoted; fewer than four fields is a failure: False, the pair stays); a note name holding a colon is still told apart (kept by the pair, released by a .gitignore); a negated .gitignore line releases; the exclude file is cut again right before the write' {
  $d = Join-Path $Root 'r12b'; New-GitDir $d
  $out = Invoke-BoxDriver 'r12b' @'
import subprocess
def G(*a, cwd=d):
    return subprocess.run(['git', '-C', cwd] + list(a), capture_output=True, text=True)
G('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'x')
par = os.path.dirname(d)
B = os.path.join(par, 'r12b-B')
G('worktree', 'add', '-q', B)
projs = {'root': d, 'b': B}
fb = os.path.join(B, 'HANDOFF.md')
open(fb, 'w').write('x')
pu = p.replace('\\', '/').encode()
def reset(n=name):
    open(p, 'wb').write(b'# user\n# fcode\n/' + n.encode() + b'\n')
def exb():
    return open(p, 'rb').read()
def iseq(x, y):
    return os.path.normpath(x) == os.path.normpath(y)
def U(n=name):
    return m['unexclude'](d, n, False, projs, ())
realgit = g['git']
def zf(src, pat, n):
    return src + b'\0' + b'3\0' + pat + b'\0' + n + b'\0'   # git check-ignore -v -z: <source> NUL <line> NUL <pattern> NUL <path> NUL
def ans(src, pat, n=b'HANDOFF.md', fields=None):
    # git's answer for B, as it gives it: -z never quotes; the text form (no -z) quotes a path with special characters
    z = fields if fields is not None else zf(src, pat, n)
    txt = b'"' + src + b'":3:' + pat + b'\t' + n + b'\n'
    def f(dd, *a, **k):
        if iseq(dd, B) and a[:1] == ('check-ignore',):
            return subprocess.CompletedProcess([], 0, z if '-z' in a else txt, b'')
        return realgit(dd, *a, **k)
    return f
# 1 the text form of the answer is quoted (what a path with special characters gives); the -z form is not: kept; from B's own .gitignore: released;
# fewer than four fields: a failure (False, the pair stays)
g['git'] = ans(pu, b'/HANDOFF.md')
reset()
print(U(), exb() == b'# user\n# fcode\n/HANDOFF.md\n')
g['git'] = ans(os.path.join(B, '.gitignore').replace('\\', '/').encode(), b'/HANDOFF.md')
print(U(), exb() == b'# user\n')
g['git'] = ans(b'', b'', fields=pu + b'\x003\0/HANDOFF.md\0')
reset()
print(U(), exb() == b'# user\n# fcode\n/HANDOFF.md\n')
g['git'] = realgit
# 2 a negated .gitignore line outranks the exclude file: the copy is visible anyway, released
open(os.path.join(B, '.gitignore'), 'w').write('!HANDOFF.md\n')
reset()
print(U(), exb() == b'# user\n')
os.unlink(os.path.join(B, '.gitignore'))
# 3 a name that holds ':' (the box allows it; this machine cannot create the file, so the file test and git's answer are faked)
n3 = 'a:b.md'
fb3 = os.path.join(B, n3)
realisf = os.path.isfile
os.path.isfile = lambda q: iseq(q, fb3) or realisf(q)
g['git'] = ans(pu, b'/a:b.md', b'a:b.md')
reset(n3)
print(U(n3), exb() == b'# user\n# fcode\n/a:b.md\n')
g['git'] = ans(os.path.join(B, '.gitignore').replace('\\', '/').encode(), b'/a:b.md', b'a:b.md')
reset(n3)
print(U(n3), exb() == b'# user\n')
os.path.isfile = realisf
g['git'] = realgit
# 4 / 5 another writer changes the shared exclude file after the first read, while the upload folders are verified: the write is cut from what is there now
os.unlink(fb)
realhide = g['hide_all_uploads']
def inject(extra):
    def f(*a):
        open(p, 'wb').write(extra)
        return realhide(*a)
    return f
g['hide_all_uploads'] = inject(b'# user\n# fcode\n/HANDOFF.md\n/injected\n')
reset()
print(U(), exb() == b'# user\n/injected\n')
g['hide_all_uploads'] = inject(b'# user\n/other\n')
reset()
wr = []
realwe = g['write_exclude']
def we(q, *a):
    if iseq(q, p):
        wr.append(1)
    return realwe(q, *a)
g['write_exclude'] = we
print(U(), exb() == b'# user\n/other\n', not wr)   # nothing left to cut: no write at all (a needless rewrite could drop a line appended meanwhile)
g['write_exclude'] = realwe
g['hide_all_uploads'] = realhide
'@ $d
  Eq ($out -join ',') 'kept True,True True,False True,True True,kept True,True True,True True,True True True' '1 -z answer (the text form would be quoted): kept; .gitignore source releases; three fields: failed, pair stays; 2 negation releases; 3 colon name: pair holds, .gitignore releases; 4 a line added meanwhile survives; 5 the pair taken meanwhile: nothing written (write_exclude not called)'
}
# r12 (release 1.3.6 P3): real git, folders with non-ASCII names (the exclude path and the sibling tree): the holder is told apart, kept and released
T 'notes r12: e: a folder name with non-ASCII characters (the exclude path and the other work tree): kept while that copy is held, released when its own .gitignore hides it' {
  $d = Join-Path $Root ('r12e D' + [char]0x1EF1 + ' ' + [char]0xE1 + 'n'); New-GitDir $d
  $out = Invoke-BoxDriver 'r12e' @'
import subprocess
def G(*a, cwd=d):
    return subprocess.run(['git', '-C', cwd] + list(a), capture_output=True, text=True)
G('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'x')
B = os.path.join(os.path.dirname(d), 'r12e-B-Dự_án')   # no space: `worktree add` takes the folder name for the branch name
G('worktree', 'add', '-q', B)
projs = {'root': d, 'b': B}
open(os.path.join(B, 'HANDOFF.md'), 'w').write('x')
def reset():
    open(p, 'wb').write(b'# user\n# fcode\n/HANDOFF.md\n')
def exb():
    return open(p, 'rb').read()
reset()
print(m['unexclude'](d, name, False, projs, ()), exb() == b'# user\n# fcode\n/HANDOFF.md\n', any(ord(c) > 127 for c in p + B))
open(os.path.join(B, '.gitignore'), 'w').write('/HANDOFF.md\n')
reset()
print(m['unexclude'](d, name, False, projs, ()), exb() == b'# user\n')
'@ $d
  Eq ($out -join ',') 'kept True True,True True' 'a held copy keeps the line (exclude path non-ASCII, tree folder non-ASCII); its own .gitignore releases'
}
# r12 (release 1.3.6 P3): only git's own "not a git repository" is "not a repository" (the folder is skipped); every other failure is unknown (the line stays)
T 'notes r12: c: Get-PhienRepoId answers $null only for git''s "not a git repository"; no answer, a start failure and every other failure are unknown' {
  $rp = Join-Path $Root 'r12c'; New-GitDir $rp
  Ok ((Get-PhienRepoId $rp) -is [hashtable]) 'a repository: an id'
  Eq ($null -eq (Get-PhienRepoId $Root)) $true 'a folder outside any repository: $null'
  Eq (Get-PhienRepoId (Join-Path $Root 'missing-folder')) 'unknown' 'a folder git cannot enter: unknown'
  function Invoke-GitQuiet([string]$Dir, [string[]]$GitArgs, [string]$StdinText) { $script:fakeGit }
  $script:PhienRepoIds = @{}   # the answer is cached per folder for a run: forget it between the fake answers
  $script:fakeGit = [pscustomobject]@{ Code = 128; Out = @(); Err = "fatal: not a git repository (or any of the parent directories): .git`n" }; Eq ($null -eq (Get-PhienRepoId $rp)) $true 'rc 128 + message'
  foreach ($c in @(@(-1, ''), @(129, 'usage: git rev-parse'), @(124, ''), @(128, 'fatal: detected dubious ownership in repository'), @(0, ''))) {
    $script:PhienRepoIds = @{}
    $script:fakeGit = [pscustomobject]@{ Code = $c[0]; Out = @(); Err = $c[1] }
    Eq (Get-PhienRepoId $rp) 'unknown' "rc $($c[0]): unknown"
  }
  $script:fakeGit = [pscustomobject]@{ Code = -1; Out = @(); Err = '' }; $script:PhienRepoIds = @{}
  [void](Get-PhienRepoId $rp); $script:fakeGit = [pscustomobject]@{ Code = 0; Out = @('.git', $rp); Err = '' }
  Eq (Get-PhienRepoId $rp) 'unknown' 'asked once per folder for the run: the first answer is reused'
}

T 'notes r12: h: the laptop runs git with LC_ALL=C through the process environment (restored after the call); fcode.ps1 never touches the ProcessStartInfo environment dictionary' {
  $rp = Join-Path $Root 'r12h'; New-GitDir $rp
  $al = @('-c', 'alias.e=!printf %s "$LC_ALL"', 'e')   # the alias prints what the git child sees
  $had = Test-Path Env:LC_ALL; $was = $env:LC_ALL
  try {
    if ($had) { Remove-Item Env:LC_ALL }
    $r = Invoke-GitQuiet $rp $al
    Eq $r.Code 0 ('git ran: ' + $r.Err); Eq ([string]@($r.Out)[0]) 'C' 'the child sees LC_ALL=C'; Eq (Test-Path Env:LC_ALL) $false 'unset before: unset after'
    $env:LC_ALL = 'vi_VN.UTF-8'
    $r = Invoke-GitQuiet $rp $al
    Eq ([string]@($r.Out)[0]) 'C' 'C even when the user set another locale'; Eq $env:LC_ALL 'vi_VN.UTF-8' 'set before: restored after'
  } finally { if ($had) { $env:LC_ALL = $was } else { Remove-Item Env:LC_ALL -ErrorAction SilentlyContinue } }
  Eq @(Select-String -LiteralPath $Fcode -Pattern '(?<!System)\.Environment(Variables)?\b').Count 0 'no environment dictionary of ProcessStartInfo anywhere (.EnvironmentVariables fails on Windows PowerShell 5.1 when two names differ only in case; .Environment does not exist there)'
}
T 'notes r12: i: the box runs git with LC_ALL=C' {
  $d = Join-Path $Root 'r12i'; New-GitDir $d
  $out = Invoke-BoxDriver 'r12i' @'
print(m['git'](d, '-c', 'alias.e=!printf %s "$LC_ALL"', 'e').stdout == b'C')
'@ $d
  Eq ($out -join ',') 'True' 'the box git child sees LC_ALL=C'
}
# r12 e2e (release 1.3.6): two projects on one repository (linked work trees) share one .git/info/exclude on each side
function Git-Seed([string]$Dir) { $ErrorActionPreference = 'Continue'; & git -C $Dir -c user.name=t -c user.email=t@t commit -q --allow-empty -m seed 2>&1 | Out-Null }
function Add-Wt([string]$Repo, [string]$Path, [string]$Branch) { $ErrorActionPreference = 'Continue'; & git -C $Repo worktree add -q $Path -b $Branch 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw "git worktree add $Path failed" } }
function Set-SyncRepos($w, [string[]]$Repos) { $cp = Join-Path $w.U '.fcode\config.json'; $c = Get-Content $cp -Raw | ConvertFrom-Json; [IO.File]::WriteAllText($cp, (@{ instabox = $c.instabox; box = $c.box; syncRepos = @($Repos) } | ConvertTo-Json -Compress)) }
function Pair-Count([string]$File, [string]$Name) { [regex]::Matches((Latin $File), '(?m)^# fcode\r?\n/' + [regex]::Escape($Name) + '\r?$').Count }
function Kept-Rx([string]$Proj, [string]$File, [string]$Side) { '(?m)  \[' + $Proj + '\] ghi chú ' + [regex]::Escape($File) + ': dự án khác cùng kho trên ' + $Side + ' còn dùng dòng giấu /' + [regex]::Escape($File) + ', fcode chưa gỡ\r?$' }
function Ign-Rc([string]$Dir, [string]$Name) { $ErrorActionPreference = 'Continue'; & git -C $Dir check-ignore -q -- $Name 2>&1 | Out-Null; $LASTEXITCODE }
# a world with project proj and project other as linked work trees of one repository on BOTH sides; -Junction: the laptop project is registered
# through a junction alias (Desk2 -> Desktop)
function New-ShareWorld([string]$Name, [switch]$Junction) {
  $w = New-W2 $Name; Use-LoggedIb $w
  New-GitDir $w.LP; New-GitDir $w.BP; Git-Seed $w.LP; Git-Seed $w.BP
  $w | Add-Member -NotePropertyName LO -NotePropertyValue (Join-Path $w.U 'Desktop\other') -Force
  $w | Add-Member -NotePropertyName BO -NotePropertyValue (($w.W -replace '\\', '/') + '/boxws/other') -Force
  Add-Wt $w.LP $w.LO 'other'; Add-Wt $w.BP $w.BO 'other'
  if ($Junction) { [void](New-Item -ItemType Junction -Path (Join-Path $w.U 'Desk2') -Target (Join-Path $w.U 'Desktop')); Set-SyncRepos $w @((Join-Path $w.U 'Desk2\proj'), $w.LP, $w.LO) }
  $w
}
T 'nhanh r12: box side: a release the other box work tree still depends on is kept (line printed, pair stays, no error); when that copy is tracked too, both are released in one run' {
  $w = New-ShareWorld 'q41'
  Put-File "$($w.LP)\HANDOFF.md" 'shared'; Put-File "$($w.LO)\HANDOFF.md" 'shared'
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  $bex = "$($w.BP)\.git\info\exclude"
  Eq (Pair-Count $bex 'HANDOFF.md') 1 'run 1: one pair on the box'; Ok ((Test-Path "$($w.BP)\HANDOFF.md") -and (Test-Path "$($w.BO)\HANDOFF.md")) 'both box copies placed'; Eq (Ign-Rc $w.BO 'HANDOFF.md') 0 'run 1: the other box tree hides it'
  Git-Commit $w.LP @('HANDOFF.md'); $m = New-LogMark $w
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  $lg = Log-Since $w $m
  Ok ($lg -notmatch 'ghi chú HANDOFF\.md giờ do git theo dõi') ('run 2: a kept pair gets no release line: ' + $lg); Ok ($lg -match (Kept-Rx 'proj' 'HANDOFF.md' 'box') -and $lg -notmatch 'xóa được') ('run 2: the kept line: ' + $lg); Ok ($lg -notmatch 'lỗi:') ('run 2: no error line: ' + $lg)
  Eq (Pair-Count $bex 'HANDOFF.md') 1 'run 2: the pair stays'; Eq (Ign-Rc $w.BO 'HANDOFF.md') 0 'run 2: the other tree still hides its copy'
  $sj = Get-Content (Join-Path $w.U 'AppData\Local\fcode\phien-status.json') -Raw | ConvertFrom-Json
  Eq @($sj.notes.released).Count 0 'run 2: the status does not list a kept pair (the menu never says "xóa được" for it)'
  Ok ($null -ne (Get-NoteState $w).PSObject.Properties['proj/HANDOFF.md']) 'run 2: nothing forgotten'
  Remove-Item -LiteralPath "$($w.BO)\HANDOFF.md"; Put-File "$($w.LO)\HANDOFF.md" 'changed'; $m = New-LogMark $w
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  $lg = $r.Out
  Eq (Get-Content "$($w.BO)\HANDOFF.md" -Raw) 'changed' 'run 3: the re-sent copy is on the box'; Eq (Ign-Rc $w.BO 'HANDOFF.md') 0 'run 3: and hidden'; Eq (Pair-Count $bex 'HANDOFF.md') 1 'run 3: the pair stays'
  Ok ($lg -match (Kept-Rx 'proj' 'HANDOFF.md' 'box') -and $lg -notmatch 'xóa được') ('run 3: the kept line again: ' + $lg); Ok ($lg -notmatch 'lỗi:') ('run 3: no error line: ' + $lg)
  Git-Commit $w.LO @('HANDOFF.md'); $m = New-LogMark $w
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  $lg = $r.Out
  Ok ($lg -match '\[proj\] ghi chú HANDOFF\.md giờ do git theo dõi' -and $lg -match '\[other\] ghi chú HANDOFF\.md giờ do git theo dõi') ('run 4: both release lines: ' + $lg); Ok ($lg -notmatch 'dự án khác cùng kho' -and $lg -notmatch 'lỗi:') ('run 4: no kept line, no error: ' + $lg)
  Eq (Pair-Count $bex 'HANDOFF.md') 0 'run 4: the pair is gone'; Ok ((Test-Path "$($w.BP)\HANDOFF.md") -and (Test-Path "$($w.BO)\HANDOFF.md")) 'run 4: both box copies are kept'
}
T 'nhanh r12: laptop side (project registered through a junction): a release the other laptop work tree still depends on is kept; when its index cannot be read it is an error (exit 1, pair stays), not a keep' {
  $w = New-ShareWorld 'q42' -Junction
  Put-File "$($w.BP)\TASK.md" 'shared'; Put-File "$($w.BO)\TASK.md" 'shared'
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  $lex = "$($w.LP)\.git\info\exclude"
  Eq (Pair-Count $lex 'TASK.md') 1 'run 1: one pair on the laptop'; Ok ((Test-Path "$($w.LP)\TASK.md") -and (Test-Path "$($w.LO)\TASK.md")) 'both laptop copies placed'
  Git-Commit $w.BP @('TASK.md'); $m = New-LogMark $w
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  $lg = Log-Since $w $m
  Ok ($lg -notmatch 'ghi chú TASK\.md giờ do git theo dõi') ('run 2: a kept pair gets no release line: ' + $lg); Ok ($lg -match (Kept-Rx 'proj' 'TASK.md' 'laptop') -and $lg -notmatch 'xóa được') ('run 2: the kept line: ' + $lg); Ok ($lg -notmatch 'lỗi:') ('run 2: no error line: ' + $lg)
  Eq (Pair-Count $lex 'TASK.md') 1 'run 2: the pair stays'; Eq (Ign-Rc $w.LO 'TASK.md') 0 'run 2: the other tree still hides its copy'
  Eq @((Get-Content (Join-Path $w.U 'AppData\Local\fcode\phien-status.json') -Raw | ConvertFrom-Json).notes.released).Count 0 'run 2: the status does not list a kept pair'
  # a corrupt index of the other work tree: git cannot say whether its copy is tracked: an error (exit 1), the pair stays, nothing is forgotten; healed, the next run keeps it
  $ErrorActionPreference = 'Continue'; $ix = (@(& git -C $w.LO rev-parse --git-path index)[0]) -replace '/', '\'; $ErrorActionPreference = 'Stop'
  if (-not [IO.Path]::IsPathRooted($ix)) { $ix = Join-Path $w.LO $ix }
  $orig = Read-Bytes $ix; $junk = New-Object byte[] 16; (New-Object Random 7).NextBytes($junk); [IO.File]::WriteAllBytes($ix, $junk); $m = New-LogMark $w
  try { $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') } finally { [IO.File]::WriteAllBytes($ix, $orig) }
  Eq $r.Code 1 $r.Out; $lg = Log-Since $w $m
  Ok ($lg -match 'lỗi: ghi chú TASK\.md: chưa gỡ được dòng /TASK\.md') ('run 3 (corrupt index): the error line: ' + $lg); Ok ($lg -notmatch (Kept-Rx 'proj' 'TASK.md' 'laptop') -and $lg -notmatch 'xóa được') ('run 3: not a kept line, no "xóa được" line (the error line alone): ' + $lg); Eq (Pair-Count $lex 'TASK.md') 1 'run 3: the pair stays'
  Ok ($null -ne (Get-NoteState $w).PSObject.Properties['proj/TASK.md']) 'run 3: nothing forgotten'
  Eq @((Get-Content (Join-Path $w.U 'AppData\Local\fcode\phien-status.json') -Raw | ConvertFrom-Json).notes.released).Count 0 'run 3: the status does not list a failed release'
  $m = New-LogMark $w; $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out; $lg = Log-Since $w $m
  Ok ($lg -match (Kept-Rx 'proj' 'TASK.md' 'laptop') -and $lg -notmatch 'xóa được' -and $lg -notmatch 'lỗi:') ('run 4 (index healed): the kept line again: ' + $lg)
}
T 'nhanh r12: laptop side: a copy that the other work tree hides through its own .gitignore does not keep the line (released, still hidden there)' {
  $w = New-ShareWorld 'q43' -Junction
  Put-File "$($w.BP)\TASK.md" 'shared'; Put-File "$($w.BO)\TASK.md" 'shared'
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  $lex = "$($w.LP)\.git\info\exclude"; Eq (Pair-Count $lex 'TASK.md') 1 'run 1: one pair'
  Put-File "$($w.LO)\.gitignore" "/TASK.md`n"; Git-Commit $w.BP @('TASK.md'); $m = New-LogMark $w
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  $lg = Log-Since $w $m
  Ok ($lg -match 'ghi chú TASK\.md giờ do git theo dõi' -and $lg -notmatch 'dự án khác cùng kho' -and $lg -notmatch 'lỗi:') ('released, no kept line: ' + $lg)
  Eq (Pair-Count $lex 'TASK.md') 0 'the pair is gone'; Eq (Ign-Rc $w.LO 'TASK.md') 0 'the other tree still hides its copy through its .gitignore'
}
T 'nhanh r12: laptop side: both work trees released in one run: no kept line, the line goes' {
  $w = New-ShareWorld 'q44' -Junction
  Put-File "$($w.BP)\TASK.md" 'shared'; Put-File "$($w.BO)\TASK.md" 'shared'
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  $lex = "$($w.LP)\.git\info\exclude"; Eq (Pair-Count $lex 'TASK.md') 1 'run 1: one pair'
  Git-Commit $w.BP @('TASK.md'); Git-Commit $w.BO @('TASK.md'); $m = New-LogMark $w
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  $lg = $r.Out
  Ok ($lg -match '\[proj\] ghi chú TASK\.md giờ do git theo dõi' -and $lg -match '\[other\] ghi chú TASK\.md giờ do git theo dõi') ('both release lines: ' + $lg); Ok ($lg -notmatch 'dự án khác cùng kho' -and $lg -notmatch 'lỗi:') ('no kept line, no error: ' + $lg)
  Eq (Pair-Count $lex 'TASK.md') 0 'the pair is gone'; Ok ((Test-Path "$($w.LP)\TASK.md") -and (Test-Path "$($w.LO)\TASK.md")) 'both laptop copies are kept'
}
T 'nhanh r12: quick run, two laptop checkouts with the same folder name: the one the run does not scan still counts (syncRepos is walked, not the project list)' {
  $w = New-W2 'q45'; Use-LoggedIb $w
  New-GitDir $w.LP; New-GitDir $w.BP; Git-Seed $w.LP; Git-Seed $w.BP
  $a = Join-Path $w.U 'A\proj'; [void](New-Item -ItemType Directory -Path (Split-Path $a) -Force); Add-Wt $w.LP $a 'wta'
  Set-SyncRepos $w @($a, $w.LP)
  Put-File "$($w.BP)\TASK.md" 'shared'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  $lex = "$($w.LP)\.git\info\exclude"; Ok (Test-Path "$a\TASK.md") 'run 1: placed in A\proj (the first of the two)'; Eq (Pair-Count $lex 'TASK.md') 1 'run 1: one pair'
  Put-File "$($w.LP)\TASK.md" 'main copy'; Git-Commit $w.BP @('TASK.md'); $m = New-LogMark $w
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  $lg = Log-Since $w $m
  Ok ($lg -match (Kept-Rx 'proj' 'TASK.md' 'laptop') -and $lg -notmatch 'xóa được') ('the kept line: ' + $lg); Ok ($lg -notmatch 'lỗi:') ('no error line: ' + $lg); Eq (Pair-Count $lex 'TASK.md') 1 'the pair stays'; Eq (Ign-Rc $w.LP 'TASK.md') 0 'the main checkout still hides its copy'
}
T 'nhanh r12: a note placed in the same run on the other laptop work tree: the line is back after the release, and the next run keeps it' {
  $w = New-ShareWorld 'q46'
  Put-File "$($w.BP)\TASK.md" 'shared'
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  $lex = "$($w.LP)\.git\info\exclude"; Ok (Test-Path "$($w.LP)\TASK.md") 'run 1: proj has its copy'; Eq (Pair-Count $lex 'TASK.md') 1 'run 1: one pair'
  Git-Commit $w.BP @('TASK.md'); Put-File "$($w.BO)\TASK.md" 'for other'; $m = New-LogMark $w
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Eq (Get-Content "$($w.LO)\TASK.md" -Raw) 'for other' 'run 2: other got its note'; Eq (Pair-Count $lex 'TASK.md') 1 'run 2: the pair is there again'; Eq (Ign-Rc $w.LO 'TASK.md') 0 'run 2: other is hidden'
  $m = New-LogMark $w; $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out; $lg = $r.Out
  Ok ($lg -match (Kept-Rx 'proj' 'TASK.md' 'laptop') -and $lg -notmatch 'xóa được' -and $lg -notmatch 'lỗi:') ('run 3: the kept line: ' + $lg)
}
T 'notes r12: d: the laptop asks git about the other work trees only while fcode''s line is still in the exclude file; a git failure there is failed (never kept)' {
  $dd = Join-Path $Root 'r12d'; [void](New-Item -ItemType Directory -Path $dd -Force)
  $ex = Join-Path $dd 'exclude'; $SyncRepos = @($dd); $script:gitCalls = 0
  function Invoke-GitQuiet([string]$Dir, [string[]]$GitArgs, [string]$StdinText) { $script:gitCalls++; [pscustomobject]@{ Code = -1; Out = @(); Err = '' } }
  function Rel([string]$Text, [bool]$Legacy) { [IO.File]::WriteAllText($ex, $Text); $script:PhienRepoIds = @{}; $script:gitCalls = 0; Get-PhienLaptopRelease $dd $ex 'TASK.md' $Legacy @() }
  Eq (Rel "# user`n" $false) 'absent' 'A took the pair already: straight to Remove, absent'; Eq $script:gitCalls 0 'git not asked'
  Eq (Rel "# user`n/TASK.md`n" $false) 'absent' 'a bare user line without the legacy flag: not fcode''s'; Eq $script:gitCalls 0 'git not asked (bare, no legacy)'
  Eq (Rel "# user`n# fcode`n/TASK.md`n" $false) 'failed' 'the pair is there and git cannot say: failed, not kept'; Ok ($script:gitCalls -gt 0) 'git asked'; Eq ([IO.File]::ReadAllText($ex)) "# user`n# fcode`n/TASK.md`n" 'nothing written'
  Eq (Rel "# user`n/TASK.md`n" $true) 'failed' 'legacy + the bare line: git asked, cannot say: failed'
  # a link is checked before any holder is asked (the box order: is_link first): .git/info a junction + a holder = failed, never kept
  $real = Join-Path $Root 'r12d-real'; [void](New-Item -ItemType Directory -Path $real -Force)
  $jn = Join-Path $Root 'r12d-info'; [void](New-Item -ItemType Junction -Path $jn -Target $real)
  $jex = Join-Path $jn 'exclude'; [IO.File]::WriteAllText($jex, "# fcode`n/TASK.md`n")
  function Test-PhienSharedNote { $true }   # a holder exists
  Eq (Get-PhienLaptopRelease $dd $jex 'TASK.md' $false @()) 'failed' 'the exclude file sits under a junction and a holder exists: failed, not kept'
  Eq ([IO.File]::ReadAllText($jex)) "# fcode`n/TASK.md`n" 'nothing written'
  [IO.File]::WriteAllText($ex, "# fcode`n/TASK.md`n")
  Eq (Get-PhienLaptopRelease $dd $ex 'TASK.md' $false @()) 'kept' 'a plain file with a holder: kept (the control)'
}
T 'notes r12: g: a note file whose attributes cannot be read (a race after the file test) is unknown for that release, never an abort of the run' {
  $rp = Join-Path $Root 'r12g'; New-GitDir $rp
  $SyncRepos = @($rp); $script:PhienRepoIds = @{}
  function Test-Path { param($LiteralPath, $PathType) if ($PathType -eq 'Leaf') { $true } else { Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath } }   # the file was there for the file test, gone for GetAttributes
  Eq (Test-PhienSharedNote $rp 'TASK.md' @()) 'unknown' 'GetAttributes throws: unknown'
}
T 'notes r12: f: laptop, real git, folders with non-ASCII names (the exclude path and the other work tree): the holder is seen; its own .gitignore ends the hold' {
  $a = Join-Path $Root ('r12f D' + [char]0x1EF1 + ' ' + [char]0xE1 + 'n'); New-GitDir $a; Git-Seed $a
  $b = Join-Path $Root ('r12f-B-D' + [char]0x1EF1 + '_' + [char]0xE1 + 'n'); Add-Wt $a $b 'wtf'
  Put-File "$b\TASK.md" 'x'; [void](Add-PhienExcludeLine "$a\.git\info\exclude" 'TASK.md')
  $SyncRepos = @($a, $b); $script:PhienRepoIds = @{}
  Eq (Test-PhienSharedNote $a 'TASK.md' @()) $true 'the copy the pair hides is held'
  Put-File "$b\.gitignore" "/TASK.md`n"; $script:PhienRepoIds = @{}
  Eq (Test-PhienSharedNote $a 'TASK.md' @()) $false 'its own .gitignore hides it: no hold'
}
T 'notes r12: j: laptop, a real holder plus a candidate whose git fails: unknown in either syncRepos order (box pair_holders parity), never kept' {
  $a = Join-Path $Root 'r12j'; New-GitDir $a; Git-Seed $a
  $b = Join-Path $Root 'r12j-B'; Add-Wt $a $b 'wtj'
  Put-File "$b\TASK.md" 'x'; [void](Add-PhienExcludeLine "$a\.git\info\exclude" 'TASK.md')
  $z = Join-Path $Root 'r12j-Z'; [void](New-Item -ItemType Directory -Path $z -Force); Put-File "$z\TASK.md" 'z'   # a candidate: a regular TASK.md at its root
  $SyncRepos = @($a, $b); $script:PhienRepoIds = @{}
  Eq (Test-PhienSharedNote $a 'TASK.md' @()) $true 'the control: B holds'
  foreach ($order in @(@($a, $b, $z), @($a, $z, $b))) {
    $SyncRepos = $order; $script:PhienRepoIds = @{}; $script:PhienRepoIds[$z.ToLowerInvariant()] = 'unknown'   # git could not tell what Z is
    Eq (Test-PhienSharedNote $a 'TASK.md' @()) 'unknown' ('Z failing is unknown whatever its place: ' + (($order | ForEach-Object { Split-Path $_ -Leaf }) -join ','))
  }
}
T 'nhanh r12: laptop side: a sibling registered through a junction to its work tree still holds its note (only the note file being a link skips a folder)' {
  $w = New-ShareWorld 'q47'
  $j = Join-Path $w.U 'Alias\other'; [void](New-Item -ItemType Directory -Path (Split-Path $j) -Force); [void](New-Item -ItemType Junction -Path $j -Target $w.LO)
  Set-SyncRepos $w @($w.LP, $j)
  Put-File "$($w.BP)\TASK.md" 'shared'; Put-File "$($w.BO)\TASK.md" 'shared'
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  $lex = "$($w.LP)\.git\info\exclude"
  Eq (Pair-Count $lex 'TASK.md') 1 'run 1: one pair'; Ok ((Test-Path "$($w.LP)\TASK.md") -and (Test-Path "$($w.LO)\TASK.md")) 'both laptop copies placed (the second through the junction)'
  Git-Commit $w.BP @('TASK.md'); $m = New-LogMark $w
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  $lg = Log-Since $w $m
  Ok ($lg -match (Kept-Rx 'proj' 'TASK.md' 'laptop') -and $lg -notmatch 'xóa được') ('the kept line: ' + $lg); Ok ($lg -notmatch 'lỗi:') ('no error line: ' + $lg)
  Eq (Pair-Count $lex 'TASK.md') 1 'the pair stays'; Eq (Ign-Rc $w.LO 'TASK.md') 0 'the work tree behind the junction still hides its copy'
}

T 'notes r9: a release rewrites the exclude file only when .fcode/.gitignore is verified to hold "*": other content and an empty file are replaced (the server''s own rule); a linked .fcode or .gitignore, a non-file, a failed write and a torn write defer the release (False, the pair stays)' {
  $d = Join-Path $Root 'r9b'; New-GitDir $d
  $out = Invoke-BoxDriver 'r9b' @'
import shutil
fc = os.path.join(d, '.fcode')
gi = os.path.join(fc, '.gitignore')
pair = b'# fcode\n/HANDOFF.md\n'
def run():
    open(p, 'wb').write(pair)
    return m['unexclude'](d, name, False)
def exb():
    return open(p, 'rb').read()
def rd():
    return open(gi, 'rb').read()
os.makedirs(fc)
open(gi, 'wb').write(b'keep\n')
print(run(), rd() == b'*\n', sorted(os.listdir(fc)) == ['.gitignore'], exb() == b'')
open(gi, 'wb').write(b'')
print(run(), rd() == b'*\n', exb() == b'')
shutil.rmtree(fc)
os.makedirs(fc)
links = set()
os.path.islink = lambda q: os.path.normpath(q) in links
links.add(os.path.normpath(fc))
print(run(), not os.path.exists(gi), exb() == pair)
shutil.rmtree(fc)
print(run(), not os.path.exists(fc), exb() == pair)
links.clear()
os.makedirs(fc)
open(gi, 'wb').write(b'')
links.add(os.path.normpath(gi))
print(run(), os.path.getsize(gi) == 0, exb() == pair)
links.clear()
shutil.rmtree(fc)
os.makedirs(gi)
print(run(), os.path.isdir(gi), exb() == pair)
shutil.rmtree(fc)
os.makedirs(fc)
realw = g['write_exclude']
def boom(q, b):
    raise OSError('x')
g['write_exclude'] = boom
print(run(), not os.path.exists(gi), exb() == pair)
g['write_exclude'] = lambda q, b: open(q, 'wb').close()
print(run(), os.path.getsize(gi) == 0, exb() == pair)
g['write_exclude'] = realw
print(run(), rd() == b'*\n', exb() == b'')
'@ $d
  Eq ($out -join ',') 'True True True True,True True True,False True True,False True True,False True True,False True True,False True True,False True True,True True True' 'wrong content and an empty file are replaced; a link, a directory, a failed or a torn write: False and the pair stays; then it works'
}
T 'notes r9: a short append is a failure (no note) and the next run completes the pair; a 1.3.3 append right after a short write glues the two patterns (both inert until the next run)' {
  $d = Join-Path $Root 'r9d'; New-GitDir $d; Put-File (Join-Path $Root 'r9d-src.md') 'note'
  $out = Invoke-BoxDriver 'r9d' @'
import subprocess
src = os.path.join(os.path.dirname(d), 'r9d-src.md')
dst = os.path.join(d, name)
def parts():
    return [n for n in os.listdir(d) if '.fcode-part-' in n]
def ens():
    try:
        return m['ensure_excluded'](d, name)
    except OSError:
        return 'raised'
def ign():
    return subprocess.run(['git', '-C', d, 'check-ignore', '-q', '--', name]).returncode == 0
real = os.write
open(p, 'wb').write(b'')
os.write = lambda fd, b: real(fd, b[:-1])
print(ens())
open(p, 'wb').write(b'')
print(m['place_note'](d, name, src, ''), os.path.exists(dst), parts() == [], open(p, 'rb').read() == b'# fcode\n/HANDOFF.md')
os.write = real
print(ens(), open(p, 'rb').read() == b'# fcode\n/HANDOFF.md', m['place_note'](d, name, src, ''))
os.unlink(dst)
open(p, 'wb').write(b'# user\n')
os.write = lambda fd, b: (real(fd, b[:-1]), open(p, 'ab').write(b'/.fcode/\n'))[0]
print(m['place_note'](d, name, src, ''), not os.path.exists(dst), open(p, 'rb').read() == b'# user\n# fcode\n/HANDOFF.md/.fcode/\n')
os.write = real
print(ens(), open(p, 'rb').read() == b'# user\n# fcode\n/HANDOFF.md/.fcode/\n# fcode\n/HANDOFF.md\n', ign())
'@ $d
  Eq ($out -join ',') 'raised,failed False True True,True True ok,failed True True,True True True' 'the append raises on a short write; cut pair: no note; the exact line is there next time (git honours it), placed; glued: no note, a fresh pair completes it'
}
T 'notes r9: a /<name> line git does not honour (a .gitignore negation outranks info/exclude): the box adds nothing over the user''s line and places no note; its own pair that git does not honour places no note either; negation gone: placed' {
  $d = Join-Path $Root 'r9e'; New-GitDir $d; Put-File (Join-Path $Root 'r9e-src.md') 'note'
  $out = Invoke-BoxDriver 'r9e' @'
src = os.path.join(os.path.dirname(d), 'r9e-src.md')
dst = os.path.join(d, name)
neg = os.path.join(d, '.gitignore')
def parts():
    return [n for n in os.listdir(d) if '.fcode-part-' in n]
open(neg, 'wb').write(b'!HANDOFF.md\n')
u = b'/HANDOFF.md\n'
open(p, 'wb').write(u)
print(m['ensure_excluded'](d, name), open(p, 'rb').read() == u, m['place_note'](d, name, src, ''), os.path.exists(dst), parts() == [])
pair = b'# fcode\n/HANDOFF.md\n'
open(p, 'wb').write(b'')
print(m['ensure_excluded'](d, name), open(p, 'rb').read() == pair)
print(m['ensure_excluded'](d, name), open(p, 'rb').read() == pair)
os.unlink(neg)
print(m['ensure_excluded'](d, name), open(p, 'rb').read() == pair, m['place_note'](d, name, src, ''), os.path.exists(dst))
'@ $d
  Eq ($out -join ',') 'False True failed False True,False True,False True,True True ok True' 'a negated name is never placed (the user''s line untouched, no duplicate pair); once git hides it, it is placed'
}
T 'nhanh r9: a .gitignore negation on the laptop (!HANDOFF.md) outranks the pair: the note from the box is not placed until the negation is gone' {
  $w = New-W2 'q40'; Use-LoggedIb $w
  New-GitDir $w.LP; New-GitDir $w.BP
  [IO.File]::WriteAllText("$($w.LP)\.gitignore", "!HANDOFF.md`n"); Put-File "$($w.BP)\HANDOFF.md" 'box handoff'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Ok (-not (Test-Path "$($w.LP)\HANDOFF.md")) 'the note is not placed'
  Ok ((Get-Content "$($w.LP)\.git\info\exclude" -Raw) -match '(?m)^# fcode\r?\n/HANDOFF\.md\r?$') 'the pair was written (inert)'
  Eq @((Get-NoteState $w).PSObject.Properties).Count 0 'no state recorded'; Eq @(Get-ChildItem $w.LP -Force -Filter '*.fcode-part*').Count 0 'no part file in the project'
  Remove-Item -LiteralPath "$($w.LP)\.gitignore"
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh'); Eq $r.Code 0 $r.Out
  Eq (Get-Content "$($w.LP)\HANDOFF.md" -Raw) 'box handoff' 'the negation gone: placed'
  Ok ($null -ne (Get-NoteState $w).PSObject.Properties['proj/HANDOFF.md']) 'and its sha recorded'
}
# r8: an OSError of ensure_excluded in the put's ensure loop is a False, not a traceback: the reply is still sent, the run does not fail as a whole
T 'nhanh r8: the box cannot read its exclude file in the put''s ensure step (it is a folder): the put still answers, exit 0' {
  $w = New-W2 'q39'; Use-LoggedIb $w 'exclbreak'
  New-GitDir $w.LP; New-GitDir $w.BP
  Put-File "$($w.LP)\HANDOFF.md" 'same text'; Put-File "$($w.BP)\HANDOFF.md" 'same text'
  $r = Invoke-Fcode $w @('phien', 'proj', '--nhanh') @{ FAKE_BP = ($w.BP -replace '/', '\') }
  $bex = "$($w.BP)\.git\info\exclude"
  Ok (Test-Path -LiteralPath $bex -PathType Container) ('the wrapper made the box exclude file a folder before the put: ' + (Read-PhienLog $w))
  Eq $r.Code 0 $r.Out; Ok ((Read-PhienLog $w) -notmatch 'gửi phiên lên box không thành công') ('the put was answered: ' + (Read-PhienLog $w))
}

# ============================== 1.3.3: fcode moc (profile hook) ==============================
$PwshExe = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
function Moc($w, [string]$Sub) { Invoke-Fcode $w @('moc', $Sub) @{ FCODE_DOCUMENTS = (Join-Path $w.W 'Documents') } }
function Count-Of([string]$Text, [string]$Needle) { [regex]::Matches($Text, [regex]::Escape($Needle)).Count }
function Moc-Block([string]$Nl = "`r`n") { ($MocBlock -replace "`r?`n", $Nl) + $Nl }

T 'moc: the hook text is plain ASCII, between the two exact marker lines, defines omp / claude / codex' {
  Ok (-not ($MocBlock.ToCharArray() | Where-Object { [int]$_ -gt 127 })) 'ASCII only (a profile without BOM is read as ANSI by Windows PowerShell 5.1)'
  $lines = @($MocBlock -split "`r?`n" | Where-Object { $_ })
  Eq $lines[0] '# >>> fcode moc >>>'; Eq $lines[-1] '# <<< fcode moc <<<'
  foreach ($n in 'omp', 'claude', 'codex') { Ok ($MocBlock -match "(?m)^function $n \{") "function $n" }
  Ok ($MocBlock -match "FCODE_MOC -ne '0'") 'FCODE_MOC=0 skips the sync'
  Ok ($MocBlock -match '-CommandType Application') 'the real program is the Application, never the function'
  # r4 F8: fcode.ps1 started directly (no batch file); the after-exit run through the shell, hidden, with --nen (fcode waits itself)
  Ok ($MocBlock -match 'fcode\.ps1') 'fcode.ps1 next to fcode.cmd'
  Ok ($MocBlock -match 'UseShellExecute = \$true' -and $MocBlock -match "WindowStyle = 'Hidden'") 'the after-exit run goes through the shell, hidden'
  Ok ($MocBlock -match '--nhanh --nen') 'with --nen'
  Ok ($MocBlock -notmatch 'ping -n' -and $MocBlock -notmatch 'cmd\.exe') 'no cmd.exe / ping delay in the hook'
  Ok ($MocBlock -match 'WaitForExit\(35000\)') 'the foreground run is waited for at most 35 s (a backstop: fcode ends itself by about 30 s)'
}
T 'moc: bat creates both profile files with exactly one block, trang-thai reports it, tat removes it again' {
  $w = New-World 'moc1'; $docs = Join-Path $w.W 'Documents'
  $p5 = Join-Path $docs 'WindowsPowerShell\profile.ps1'; $p7 = Join-Path $docs 'PowerShell\profile.ps1'
  $r = Moc $w 'trang-thai'; Eq $r.Code 0 $r.Out
  Eq (Count-Of $r.Out ': không có khối hook') 2 $r.Out
  Ok ($r.Out -match 'Chính sách chạy script của Windows PowerShell 5\.1: ') 'the execution policy is reported, labelled Windows PowerShell 5.1'
  if ($PwshExe) {   # pwsh's own policy, asked from pwsh itself (the Bypass fcode.cmd gives its own process is not inherited)
    $direct = (& $PwshExe.Source -NoProfile -NonInteractive -Command '$env:PSExecutionPolicyPreference = $null; (Get-ExecutionPolicy).ToString()' | Out-String).Trim()
    Ok ($r.Out -match ('Chính sách chạy script của PowerShell 7 \(pwsh\): ' + [regex]::Escape($direct) + '\r?\n')) ("pwsh policy line says [$direct]: " + $r.Out)
  }
  Ok (-not (Test-Path $p5) -and -not (Test-Path $p7)) 'trang-thai creates nothing'
  $r = Moc $w 'bat'; Eq $r.Code 0 $r.Out
  Ok ($r.Out -match 'Remove-Item Env:FCODE_MOC') 'bat says how to turn the hook back on after FCODE_MOC=0'
  Ok ($r.Out -match 'claude\.exe' -and $r.Out -match '--') 'bat says the wrappers are not exact for -- / -x:value / $?; run claude.exe directly'
  foreach ($p in $p5, $p7) {
    $t = Latin $p
    Eq (Count-Of $t '# >>> fcode moc >>>') 1 $p; Eq (Count-Of $t '# <<< fcode moc <<<') 1 $p
    Eq $t (Moc-Block) 'a new file holds just the block'
    Ok (-not (Test-Path "$p.bak-fcode")) 'a file that did not exist needs no backup'
  }
  $r = Moc $w 'trang-thai'; Eq (Count-Of $r.Out ': có khối hook') 2 $r.Out
  $r = Moc $w 'tat'; Eq $r.Code 0 $r.Out
  foreach ($p in $p5, $p7) { Eq (Get-Item -LiteralPath $p).Length 0 'the block is gone' }
  $r = Moc $w 'trang-thai'; Eq (Count-Of $r.Out ': không có khối hook') 2 $r.Out
  $r = Moc $w 'xyz'; Eq $r.Code 1 'unknown subcommand'
}
T 'moc: an existing profile keeps every other byte (BOM, CRLF, accents); bat twice does not duplicate; the backup is made once and never overwritten' {
  $w = New-World 'moc2'; $docs = Join-Path $w.W 'Documents'
  $p5 = Join-Path $docs 'WindowsPowerShell\profile.ps1'; $p7 = Join-Path $docs 'PowerShell\profile.ps1'
  [void](New-Item -ItemType Directory -Path (Split-Path $p5) -Force)
  $orig = [byte[]](@(0xEF, 0xBB, 0xBF) + [byte[]]$utf8.GetBytes("# my profile`r`nSet-Alias ll Get-ChildItem`r`nWrite-Host 'xin chào'`r`n"))
  [IO.File]::WriteAllBytes($p5, $orig)
  $r = Moc $w 'bat'; Eq $r.Code 0 $r.Out
  $now = Read-Bytes $p5
  Ok (Bytes-Eq $now[0..($orig.Length - 1)] $orig) 'the old bytes are the same, in front'
  Eq (Latin $p5).Substring($orig.Length) (Moc-Block) 'the block follows'
  Ok (Bytes-Eq (Read-Bytes "$p5.bak-fcode") $orig) 'backup of the original'
  Ok (-not (Test-Path "$p5.fcode-tmp")) 'no temp file left'
  # twice: nothing changes (one block), and a backup that already exists is never overwritten
  [IO.File]::WriteAllText("$p5.bak-fcode", 'KEEP')
  $before = Sha $p5
  $r = Moc $w 'bat'; Eq $r.Code 0 $r.Out
  Eq (Sha $p5) $before 'second bat: same file'
  Eq (Count-Of (Latin $p5) '# >>> fcode moc >>>') 1 'one block, not two'
  Eq (Count-Of (Latin $p7) '# >>> fcode moc >>>') 1 'the other profile too'
  Eq (Get-Content "$p5.bak-fcode" -Raw) 'KEEP' 'backup untouched'
  # the user adds lines after the block; tat removes only the block and still does not overwrite the backup
  $fs = [IO.File]::Open($p5, 'Append'); try { $b = $utf8.GetBytes("Import-Module posh-git`r`n"); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
  $r = Moc $w 'tat'; Eq $r.Code 0 $r.Out
  Ok (Bytes-Eq (Read-Bytes $p5) ([byte[]](@($orig) + [byte[]]$utf8.GetBytes("Import-Module posh-git`r`n")))) 'everything but the block is as it was'
  Eq (Get-Content "$p5.bak-fcode" -Raw) 'KEEP' 'backup still untouched after tat'
  $before = Sha $p5; $r = Moc $w 'tat'; Eq $r.Code 0; Eq (Sha $p5) $before 'second tat: same file'
  $r = Moc $w 'bat'; Eq $r.Code 0 $r.Out; Eq (Count-Of (Latin $p5) '# >>> fcode moc >>>') 1 'bat again after tat'
}
T 'moc: bat replaces an old block in place (lines before and after untouched); LF files get LF; no final newline gets one; lone marker and UTF-16 are refused untouched' {
  $w = New-World 'moc3'; $docs = Join-Path $w.W 'Documents'
  $p5 = Join-Path $docs 'WindowsPowerShell\profile.ps1'; $p7 = Join-Path $docs 'PowerShell\profile.ps1'
  [void](New-Item -ItemType Directory -Path (Split-Path $p5), (Split-Path $p7) -Force)
  [IO.File]::WriteAllText($p5, "A`r`n# >>> fcode moc >>>`r`nold stuff`r`n# <<< fcode moc <<<`r`nB`r`n")
  [IO.File]::WriteAllText($p7, "A`nB")
  $r = Moc $w 'bat'; Eq $r.Code 0 $r.Out
  Eq (Latin $p5) ("A`r`n" + (Moc-Block) + "B`r`n") 'replaced where it was'
  Eq (Latin $p7) ("A`nB`n" + (Moc-Block "`n")) 'LF file: LF block, newline added before it'
  Ok ((Latin $p7) -notmatch "`r") 'no CR in the LF file'
  # refusals leave the file alone
  $half = "A`r`n# >>> fcode moc >>>`r`nB`r`n"; [IO.File]::WriteAllText($p5, $half); Remove-Item "$p5.bak-fcode" -ErrorAction SilentlyContinue
  $u16 = [byte[]](@(0xFF, 0xFE) + [byte[]][Text.Encoding]::Unicode.GetBytes("x")); [IO.File]::WriteAllBytes($p7, $u16); Remove-Item "$p7.bak-fcode" -ErrorAction SilentlyContinue
  $r = Moc $w 'bat'; Eq $r.Code 1 $r.Out
  Eq (Latin $p5) $half 'half block: untouched'; Ok (Bytes-Eq (Read-Bytes $p7) $u16) 'UTF-16: untouched'
  Ok (-not (Test-Path "$p5.bak-fcode") -and -not (Test-Path "$p7.bak-fcode")) 'no backup when nothing was changed'
  $r = Moc $w 'tat'; Eq $r.Code 1 'tat refuses the same way'
}
T 'moc: trang-thai says in Vietnamese when the execution policy blocks profiles, ignores the Process scope, and the policy is never changed' {
  function Set-ExecutionPolicy { throw 'fcode must never change the execution policy' }
  function Get-ExecutionPolicy { param([switch]$List) $script:EP }
  function EP([string]$Mu, [string]$Us, [string]$Pr, [string]$Cu, [string]$Lm) { $script:EP = @(@('MachinePolicy', $Mu), @('UserPolicy', $Us), @('Process', $Pr), @('CurrentUser', $Cu), @('LocalMachine', $Lm) | ForEach-Object { [pscustomobject]@{ Scope = $_[0]; ExecutionPolicy = $_[1] } }) }
  function Get-MocPwshPolicy { $script:PW }   # pwsh's own answer is mocked here; the real one is checked through `fcode moc trang-thai` in the test above
  $script:PW = $null
  function Say-Policy { (Write-MocPolicy *>&1 | Out-String) }
  EP 'Undefined' 'Undefined' 'Bypass' 'Restricted' 'Undefined'
  $o = Say-Policy
  Ok ($o -match 'Windows PowerShell 5\.1: Restricted \(đặt ở: CurrentUser\)') ("Process=Bypass must not hide Restricted; the line is labelled 5.1: $o")
  Ok ($o -notmatch 'PowerShell 7') 'no pwsh on this machine = no pwsh line'
  Ok ($o -match 'KHÔNG nạp file profile') 'says the hook will not load'; Ok ($o -match 'Set-ExecutionPolicy -Scope CurrentUser RemoteSigned') 'says how to allow it'
  # a shell is warned about only when ITS policy blocks profiles: 5.1 Restricted + pwsh RemoteSigned (a default Windows client) warns about 5.1 only, and the other way round
  $script:PW = 'RemoteSigned'; $o = Say-Policy
  Ok ($o -match 'PowerShell 7 \(pwsh\): RemoteSigned') 'pwsh policy is printed'; Ok ($o -match 'Windows PowerShell 5\.1 sẽ KHÔNG nạp' -and $o -notmatch 'PowerShell 7 sẽ KHÔNG nạp') "5.1 only: $o"
  EP 'Undefined' 'Undefined' 'Undefined' 'RemoteSigned' 'Undefined'; $script:PW = 'AllSigned'; $o = Say-Policy
  Ok ($o -match 'PowerShell 7 \(pwsh\): AllSigned' -and $o -match 'PowerShell 7 sẽ KHÔNG nạp' -and $o -notmatch 'Windows PowerShell 5\.1 sẽ KHÔNG nạp') "pwsh only: $o"
  $script:PW = 'RemoteSigned'; Ok ((Say-Policy) -notmatch 'Cảnh báo') 'both fine = no warning'
  $script:PW = $null
  EP 'Undefined' 'Undefined' 'Bypass' 'Restricted' 'Undefined'
  EP 'Undefined' 'Undefined' 'Undefined' 'Undefined' 'AllSigned'; Ok ((Say-Policy) -match 'KHÔNG nạp') 'AllSigned warns'
  EP 'Undefined' 'Undefined' 'Undefined' 'Undefined' 'Undefined'; $o = Say-Policy; Ok ($o -match 'Restricted' -and $o -match 'KHÔNG nạp') "nothing set = the Windows default, Restricted: $o"
  EP 'Undefined' 'Undefined' 'Undefined' 'RemoteSigned' 'Restricted'; $o = Say-Policy; Ok ($o -match 'RemoteSigned' -and $o -notmatch 'Cảnh báo') ("RemoteSigned is fine: $o")
  EP 'Undefined' 'Undefined' 'Undefined' 'Bypass' 'Restricted'; Ok ((Say-Policy) -notmatch 'Cảnh báo') 'Bypass is fine'
  EP 'AllSigned' 'Undefined' 'Undefined' 'RemoteSigned' 'Undefined'; $o = Say-Policy; Ok ($o -match 'Cảnh báo' -and $o -match 'Group Policy') ("a policy set by the administrator: $o")
}

# the hook run for real: child PowerShell processes, a temp USERPROFILE, fake omp / claude / codex / fcode (.cmd) first on PATH
function New-MocBin($w) {
  $bin = Join-Path $w.W 'bin'; [void](New-Item -ItemType Directory -Path $bin -Force)
  $log = Join-Path $w.W 'moc.log'
  # the part before the first agent line ("omp ", "claude ", "codex ") of the log is the foreground sync, the part after it the background one; FAKE_FG / FAKE_BG = ping count (about seconds + 1); FAKE_RC = its exit code
  [IO.File]::WriteAllText((Join-Path $bin 'fcode.cmd'), "@echo off`r`necho fcode %* [%MOC_LABEL%] >>`"%MOCLOG%`"`r`nfindstr /b /c:`"omp `" /c:`"claude `" /c:`"codex `" `"%MOCLOG%`" >nul 2>&1`r`nif errorlevel 1 (if defined FAKE_FG ping -n %FAKE_FG% 127.0.0.1 >nul) else (if defined FAKE_BG ping -n %FAKE_BG% 127.0.0.1 >nul)`r`necho fcode-end %* [%MOC_LABEL%] >>`"%MOCLOG%`"`r`nif defined FAKE_RC exit /b %FAKE_RC%`r`nexit /b 0`r`n")
  foreach ($n in 'omp', 'claude', 'codex') { [IO.File]::WriteAllText((Join-Path $bin "$n.cmd"), "@echo off`r`necho $n %* >>`"%MOCLOG%`"`r`necho $n-out`r`nif defined FAKE_TTY python -c `"import sys;open(sys.argv[1],'w').write(str(sys.stdin.isatty())+' '+str(sys.stdout.isatty()))`" `"%FAKE_TTY%`"`r`nif defined FAKE_STDIN findstr `"^`" >`"%FAKE_STDIN%`"`r`nexit /b 7`r`n") }
  # fcode.ps1 beside fcode.cmd (the hook starts it directly): the same log lines; FAKE_FG / FAKE_BG (the --nen run) as above; a --nen run records
  # whether its console has a visible window (MainWindowHandle) in <log>.handle
  # (appends retry: the test reads the log while it is written)
  [IO.File]::WriteAllText((Join-Path $bin 'fcode.ps1'), (@(
      'function L([string]$f, [string]$t) { for ($i = 0; $i -lt 50; $i++) { try { [IO.File]::AppendAllText($f, $t + "`r`n"); return } catch { Start-Sleep -Milliseconds 100 } } }'
      '$a = $args -join '' ''; $nen = $args -contains ''--nen'''
      'L $env:MOCLOG "fcode $a [$env:MOC_LABEL]"'
      'if ($nen) { L ($env:MOCLOG + ''.handle'') (''handle='' + (Get-Process -Id $PID).MainWindowHandle) }'
      '$n = if ($nen) { $env:FAKE_BG } else { $env:FAKE_FG }; if ($n) { Start-Sleep -Seconds ([int]$n - 1) }'
      'L $env:MOCLOG "fcode-end $a [$env:MOC_LABEL]"'
      'if ($env:FAKE_RC) { exit [int]$env:FAKE_RC }; exit 0') -join "`r`n"))
  [pscustomobject]@{ Bin = $bin; Log = $log }
}
function Get-MocLog($b) { if (Test-Path $b.Log) { @(Get-Content $b.Log | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() } }
function Wait-MocLog($b, [string]$Pat, [int]$Count, [int]$Sec = 40) {
  $end = (Get-Date).AddSeconds($Sec)
  while ((Get-Date) -lt $end -and @(Get-MocLog $b | Where-Object { $_ -match $Pat }).Count -lt $Count) { Start-Sleep -Milliseconds 300 }
  @(Get-MocLog $b | Where-Object { $_ -match $Pat }).Count
}
# runs $Body (PowerShell text) in a child host after dot-sourcing the profile that `fcode moc bat` wrote; returns the child's output
# -Headless: the child gets a real console (stdin / stdout are a terminal, as at a prompt) but no window, the way the Task Scheduler entry runs (conhost --headless); its own output is not captured
function Invoke-MocChild($w, $b, [string]$Body, [hashtable]$ExtraEnv = @{}, [string]$HostExe = 'powershell.exe', [switch]$Headless) {
  $prof = Join-Path $w.W $(if ($HostExe -eq 'powershell.exe') { 'Documents\WindowsPowerShell\profile.ps1' } else { 'Documents\PowerShell\profile.ps1' })
  $script = Join-Path $w.W 'child.ps1'
  [IO.File]::WriteAllText($script, "`$ErrorActionPreference = 'Continue'`r`n. '$prof'`r`n$Body`r`n", (New-Object Text.UTF8Encoding($true)))
  $set = @{ USERPROFILE = $w.U; MOCLOG = $b.Log; PATH = ($b.Bin + ';' + $env:PATH); MOC_LABEL = 'x'; FAKE_FG = [NullString]::Value; FAKE_BG = [NullString]::Value; FAKE_RC = [NullString]::Value; FAKE_TTY = [NullString]::Value; FAKE_STDIN = [NullString]::Value; FCODE_MOC = [NullString]::Value; FCODE_MOC_DELAY = '1' }
  foreach ($k in $ExtraEnv.Keys) { $set[$k] = $ExtraEnv[$k] }
  $save = @{}; foreach ($k in $set.Keys) { $save[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $set[$k]) }
  try {
    if ($Headless) {
      $pr = Start-Process -FilePath conhost.exe -ArgumentList @('--headless', $HostExe, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) -WindowStyle Hidden -PassThru
      if (-not $pr.WaitForExit(90000)) { & taskkill.exe /PID $pr.Id /T /F 2>&1 | Out-Null }
    } else { & $HostExe -NoProfile -ExecutionPolicy Bypass -File $script 2>&1 | Out-String }
  } finally { foreach ($k in $save.Keys) { [Environment]::SetEnvironmentVariable($k, $(if ($null -eq $save[$k]) { [NullString]::Value } else { $save[$k] })) } }
}
function New-MocWorld([string]$Name) { $w = New-World $Name; [void](Moc $w 'bat'); $w }

foreach ($hostExe in 'powershell.exe', 'pwsh') {
  if ($hostExe -eq 'pwsh' -and -not $PwshExe) { continue }
  T "moc hook ($hostExe): in a project folder the sync runs first and is waited for, then the real program gets the args, then a hidden sync; output and exit code pass through" {
    $w = New-MocWorld ($(if ($hostExe -eq 'pwsh') { 'moc4pw' } else { 'moc4ps' })); $b = New-MocBin $w
    $deep = Join-Path $w.LP 'sub\deep'; [void](New-Item -ItemType Directory -Path $deep -Force)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $o = Invoke-MocChild $w $b ("Set-Location -LiteralPath '$deep'`r`n`$sw = [Diagnostics.Stopwatch]::StartNew()`r`nomp a 'b c' --x`r`n'RC=' + `$LASTEXITCODE + ' T=' + [int]`$sw.Elapsed.TotalSeconds") @{ FAKE_BG = '10' } $hostExe
    $whole = $sw.Elapsed.TotalSeconds
    Ok ($o -match 'omp-out') "the program's own output comes through: $o"
    Ok ($o -match 'RC=7 ') "its exit code is left in LASTEXITCODE: $o"
    $t = [int]([regex]::Match($o, 'T=(\d+)').Groups[1].Value)
    Ok ($t -lt 8) "the background sync (about 9 s) is not waited for ($t s)"
    # the after-exit run holds none of the shell's handles: the shell (and a pipe reading it) ends at once, not when that run ends
    Ok ($whole -lt 6) "the shell ends without waiting for the background run ($([Math]::Round($whole, 1)) s)"
    Eq ((Wait-MocLog $b '^fcode-end ' 2 45)) 2 'foreground and background sync both ran'
    Eq ((Get-MocLog $b) -join '|') 'fcode phien proj --nhanh [x]|fcode-end phien proj --nhanh [x]|omp a "b c" --x|fcode phien proj --nhanh --nen [x]|fcode-end phien proj --nhanh --nen [x]'
    Eq ((Get-Content "$($b.Log).handle" -Raw).Trim()) 'handle=0' 'the after-exit run has no visible window'
  }
}
T 'moc hook: without fcode.ps1 next to fcode.cmd the hook runs fcode.cmd (before and after, the after-exit run with --nen)' {
  $w = New-MocWorld 'moc9'; $b = New-MocBin $w; Remove-Item -LiteralPath (Join-Path $b.Bin 'fcode.ps1')
  [void](Invoke-MocChild $w $b "Set-Location -LiteralPath '$($w.LP)'`r`nomp z")
  Eq ((Wait-MocLog $b '^fcode-end ' 2 45)) 2 'both runs'
  Eq ((Get-MocLog $b) -join '|') 'fcode phien proj --nhanh [x]|fcode-end phien proj --nhanh [x]|omp z|fcode phien proj --nhanh --nen [x]|fcode-end phien proj --nhanh --nen [x]'
}
T 'moc hook: project is found by the folder you are in (nested, longest path, case, slashes, trailing slash); no project or FCODE_MOC=0 = only the real program' {
  $w = New-World 'moc5'; $d = Join-Path $w.U 'Desktop'
  foreach ($x in 'proj\a\b', 'proj\sub\z', 'proj2', 'Mixed\child', 'x\app', 'y\app', 'New folder (2)\q') { [void](New-Item -ItemType Directory -Path (Join-Path $d $x) -Force) }
  # the nested repo is listed BEFORE its parent: a "last match wins" rule would pick the parent and fail the 'longest' case
  $repos = @((Join-Path $w.LP 'sub'), $w.LP, (($d + '\MIXED\') -replace '\\', '/'), (Join-Path $d 'x\app'), (Join-Path $d 'y\app'), (Join-Path $d 'New folder (2)'))
  [IO.File]::WriteAllText((Join-Path $w.U '.fcode\config.json'), (@{ instabox = $Cmd; box = 'coder'; syncRepos = $repos } | ConvertTo-Json -Compress))
  [void](Moc $w 'bat'); $b = New-MocBin $w
  $cases = @(@('root', 'proj', 'proj'), @('nested', 'proj\a\b', 'proj'), @('longest', 'proj\sub\z', 'sub'), @('sibling', 'proj2', ''), @('case', 'Mixed\child', 'mixed'),
    @('dupfirst', 'x\app', 'app'), @('dupsecond', 'y\app', ''), @('badname', 'New folder (2)\q', ''), @('outside', '', ''))
  # after each synced case the child waits for its background run to end, so two fake fcode processes never append to the log at the same moment
  $body = "function W([int]`$n) { `$e = (Get-Date).AddSeconds(30); while ((Get-Date) -lt `$e -and @(Get-Content `$env:MOCLOG | Where-Object { `$_ -match '^fcode-end' }).Count -lt `$n) { Start-Sleep -Milliseconds 200 } }`r`n"
  $want = 0
  foreach ($c in $cases) {
    $body += "`$env:MOC_LABEL = '$($c[0])'; Set-Location -LiteralPath '$(Join-Path $d $c[1])'; omp $($c[0])`r`n"
    if ($c[2]) { $want += 2; $body += "W $want`r`n" }
  }
  $body += "`$env:FCODE_MOC = '0'; `$env:MOC_LABEL = 'off'; Set-Location -LiteralPath '$($w.LP)'; omp off"
  [void](Invoke-MocChild $w $b $body)
  $log = Get-MocLog $b
  Eq (@($log | Where-Object { $_ -match '^fcode-end ' }).Count) 10 ("five synced folders = ten sync runs (before and after): " + ($log -join '|'))
  foreach ($c in $cases) {
    $seen = @($log | Where-Object { $_ -match "^fcode phien (\S+) --nhanh(?: --nen)? \[$($c[0])\]$" } | ForEach-Object { $Matches[1] })
    Eq ($seen -join ',') $(if ($c[2]) { "$($c[2]),$($c[2])" } else { '' }) ("sync project for '$($c[0])'")
    Ok (@($log | Where-Object { $_ -eq "omp $($c[0])" }).Count -eq 1) "the real program ran once for '$($c[0])'"
  }
  Eq @($log | Where-Object { $_ -match '\[off\]$' }).Count 0 'FCODE_MOC=0: no sync'; Ok ($log -contains 'omp off') 'but the program runs'
}
T 'moc hook: with nothing piped the real program keeps the console (stdin and stdout stay a terminal, so its UI works); piped input reaches it' {
  $w = New-MocWorld 'moc7'; $b = New-MocBin $w
  $f1 = Join-Path $w.W 'tty-direct.txt'; $f2 = Join-Path $w.W 'tty-hook.txt'; $f3 = Join-Path $w.W 'stdin.txt'
  # the first call is the control: the same program run by hand, not through the hook
  $body = "Set-Location -LiteralPath '$($w.U)'`r`n`$env:FAKE_TTY = '$f1'; & '$(Join-Path $b.Bin 'omp.cmd')' direct`r`n`$env:FAKE_TTY = '$f2'; omp via-hook`r`n`Remove-Item Env:FAKE_TTY; `$env:FAKE_STDIN = '$f3'; 'piped line' | codex c`r`n"
  [void](Invoke-MocChild $w $b $body @{} 'powershell.exe' -Headless)
  Ok (Test-Path $f1) 'the control ran'
  Eq ((Get-Content $f1 -Raw).Trim()) 'True True' 'control: a headless console is a terminal on both sides (else this test proves nothing)'
  Ok (Test-Path $f2) 'the hook ran the program'
  Eq ((Get-Content $f2 -Raw).Trim()) 'True True' 'through the hook function: still a terminal'
  Ok ((Test-Path $f3) -and (Get-Content $f3 -Raw) -match 'piped line') 'piped input arrives'
  Eq (@(Get-MocLog $b | Where-Object { $_ -match '^(omp via-hook|codex c)$' }).Count) 2 'both programs ran through the functions'
}
T 'moc help: fcode help names how to turn the hook off in a window and back on, and the wrapper limits' {
  $w = New-World 'help1'; $r = Invoke-Fcode $w @('help', 'moc'); Eq $r.Code 0; $r2 = Invoke-Fcode $w @('help', 'phien'); Eq $r2.Code 0
  $o = ($r.Out + ' ' + $r2.Out) -replace '\s+', ' '   # the detail text is wrapped at 78 chars: compare with single spaces
  Ok ($o -match "FCODE_MOC = '0'" -and $o -match 'Remove-Item Env:FCODE_MOC' -and $o -match 'cửa sổ này') 'turn off in this window / on again'
  Ok ($o -match 'claude\.exe / codex\.exe / omp\.exe' -and $o -match 'x:giá-trị') 'wrapper limits and the bypass'
  Ok ($o -match 'fcode phien <project> --nhanh --nen' -and $o -match 'chưa xong sau 30 giây thì bị ngắt hẳn và báo lỗi') 'r4: --nen and the 30 s hard end are in the help'
}
T 'moc hook: a failing sync does not stop the agent; a sync that hangs is killed after 35 s (the backstop: fcode itself ends by about 30 s)' {
  $w = New-MocWorld 'moc6'; $b = New-MocBin $w
  $o = Invoke-MocChild $w $b "Set-Location -LiteralPath '$($w.LP)'`r`ncodex hello`r`n'RC=' + `$LASTEXITCODE" @{ FAKE_RC = '1' }
  Ok ($o -match 'codex-out' -and $o -match 'RC=7') "the agent started anyway and keeps its own exit code: $o"
  Eq (@(Get-MocLog $b | Where-Object { $_ -eq 'codex hello' }).Count) 1
  Eq (Wait-MocLog $b '^fcode-end ' 2 20) 2 'both syncs ran'
  Remove-Item $b.Log -ErrorAction SilentlyContinue; $b2 = $b
  $o = Invoke-MocChild $w $b2 "Set-Location -LiteralPath '$($w.LP)'`r`n`$sw = [Diagnostics.Stopwatch]::StartNew()`r`nclaude hi`r`n'RC=' + `$LASTEXITCODE + ' T=' + [int]`$sw.Elapsed.TotalSeconds" @{ FAKE_FG = '61' }
  $t = [int]([regex]::Match($o, 'T=(\d+)').Groups[1].Value)
  Ok ($o -match 'RC=7 ' -and $o -match 'claude-out') "the agent started after the kill: $o"
  Ok ($t -ge 34 -and $t -lt 55) "waited 35 s for the sync, then killed it ($t s)"
  Eq (Wait-MocLog $b2 '^fcode-end ' 1 20) 1 'only the background run finished; the killed one never reached its end'
  Eq (@(Get-MocLog $b2 | Where-Object { $_ -match '^fcode phien' }).Count) 2
}

# ============================== 1.3.11: a project alias works wherever a project name does (phien [project], the bare session form) ==============================
# The box keeps <configDir>/prefs.json (next to config.json); the laptop only reads it through the scan / projects call it already makes and caches it in %LOCALAPPDATA%\fcode\prefs.json.
function With-PrefsCache($Text, [scriptblock]$Body) {   # $Text = the cache file's text; $null = no file
  $save = $env:LOCALAPPDATA; $d = Join-Path $Root ('lad-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  [void](New-Item -ItemType Directory -Path (Join-Path $d 'fcode') -Force)
  if ($null -ne $Text) { [IO.File]::WriteAllText((Join-Path $d 'fcode\prefs.json'), $Text, $utf8) }
  $env:LOCALAPPDATA = $d
  try { & $Body } finally { $env:LOCALAPPDATA = $save }
}
function Set-BoxPrefs($w, [string]$Text) { [IO.File]::WriteAllText((Join-Path $w.W 'prefs.json'), $Text, $utf8) }   # beside the box config.json (boxcfg.json)
function Get-AliasCache($w) { $p = Join-Path $w.U 'AppData\Local\fcode\prefs.json'; if (Test-Path $p) { [IO.File]::ReadAllText($p) } else { $null } }
function Set-AliasCache($w, [string]$Text) { $p = Join-Path $w.U 'AppData\Local\fcode\prefs.json'; [void](New-Item -ItemType Directory -Path (Split-Path $p) -Force); [IO.File]::WriteAllText($p, $Text, $utf8) }

T 'alias: the resolver turns an alias into the real name (exact, case-insensitive); a real name wins; unknown stays' {
  $json = '{"order":[],"aliases":{"deal-sync":"ds","vps-scraper":"deal-sync","other":"Cửa Hàng 1","proj":"p"}}'
  With-PrefsCache $json {
    Eq (Resolve-ProjectName 'ds') 'deal-sync' 'alias'
    Eq (Resolve-ProjectName 'DS') 'deal-sync' 'alias, upper case'
    Eq (Resolve-ProjectName 'cửa hàng 1') 'other' 'alias with spaces and Vietnamese letters, lower case'
    Eq (Resolve-ProjectName 'CỬA HÀNG 1') 'other' 'alias with spaces and Vietnamese letters, upper case'
    Eq (Resolve-ProjectName 'deal-sync') 'deal-sync' 'a name that is a real name and also another project''s alias: the real name wins'
    Eq (Resolve-ProjectName 'DEAL-SYNC') 'DEAL-SYNC' 'the real name, other case: left as typed'
    Eq (Resolve-ProjectName 'p' @('p')) 'p' 'a known real name (not in the aliases) wins over an alias of that spelling'
    Eq (Resolve-ProjectName 'nope') 'nope' 'unknown stays'
    Eq (Resolve-ProjectName 'ds ') 'ds ' 'no trimming: not an exact match'
    Eq (Resolve-ProjectName '') '' 'empty'
  }
  With-PrefsCache '{"order":[],"aliases":{"proj":"pj","other":"proj"}}' {
    Eq (Resolve-ProjectName 'proj' @('proj', 'other')) 'proj' 'alias of another project spelled like this one''s real name'
    Eq (Resolve-ProjectName 'pj' @('proj', 'other')) 'proj'
  }
}
T 'alias: a missing, empty or broken prefs cache is harmless (no aliases, no error)' {
  foreach ($c in @($null, '', '   ', '{oops', 'null', '[]', '"x"', '42', '{}', '{"aliases":5}', '{"aliases":null}', '{"aliases":["a"]}', '{"aliases":{"a":5,"b":"","c":"  ","d":null,"e":["x"],"f":{"g":1}}}')) {
    With-PrefsCache $c {
      Eq (@((Get-ProjectAliases).Keys).Count) 0 "aliases of [$c]"
      Eq (Resolve-ProjectName 'a') 'a' "resolve with [$c]"
      Eq (Format-ProjectName 'a') 'a' "format with [$c]"
    }
  }
}
T 'alias: lists print "alias (real name)"; control characters in an alias are shown as ?' {
  With-PrefsCache ('{"order":[],"aliases":{"proj":"Dự án 1","other":"a' + '\u001b[31mb"}}') {
    Eq (Format-ProjectName 'proj') 'Dự án 1 (proj)'
    Eq (Format-ProjectName 'PROJ') 'Dự án 1 (PROJ)' 'the key is found whatever its case'
    Eq (Format-ProjectName 'other') 'a?[31mb (other)'
  }
  With-PrefsCache ('{"order":[],"aliases":{"p":"a' + '\u009bb' + '\u202ec' + '\u200bd"}}') {
    Eq (Format-ProjectName 'p') 'a?b?c?d (p)' 'C1 control, bidi override and zero-width space are masked'
    Eq (Format-ProjectName 'third') 'third' 'no alias: the name alone'
  }
}
T 'alias: Save-PrefsCache keeps the old copy when the box said nothing, and replaces it when it answered' {
  With-PrefsCache $null {
    Save-PrefsCache $null
    Ok (-not (Test-Path (Get-PrefsPath))) 'nothing to save, nothing written'
    Save-PrefsCache ([pscustomobject]@{ order = @('proj'); aliases = [pscustomobject]@{ proj = 'pj' } })
    Eq (Resolve-ProjectName 'pj') 'proj' 'saved'
    Save-PrefsCache $null
    Eq (Resolve-ProjectName 'pj') 'proj' 'a silent box does not wipe it'
    Save-PrefsCache ([pscustomobject]@{ order = @(); aliases = [pscustomobject]@{} })
    Eq (Resolve-ProjectName 'pj') 'pj' 'an answer with no aliases clears it'
  }
}
T 'alias e2e: fcode phien <alias> with no cache asks the box once, syncs the real project and saves the cache; the next runs (any case) ask nothing' {
  $w = New-W2 'al1'; Set-BoxPrefs $w '{"order":["proj","other"],"aliases":{"proj":"my proj"}}'
  $s = New-Sess $w.LS '11111111-al01' $w.LP @('a')
  $r = Invoke-Fcode $w @('phien', 'my proj')
  Eq $r.Code 0 $r.Out
  Ok ($r.Out -match '== my proj \(proj\): gửi 1 phiên lên box') ("header names alias and real name; out: " + $r.Out)
  Ok (Test-Path (Join-Path $w.BS (Split-Path $s -Leaf))) 'the real project was synced'
  Eq (Calls $w 'projects') 1 'one extra call to learn the aliases'
  Ok ((Get-AliasCache $w) -match '"proj":"my proj"') 'cache saved'
  $r = Invoke-Fcode $w @('phien', 'MY PROJ')
  Eq $r.Code 0 $r.Out
  Ok ($r.Out -match '== my proj \(proj\):') ("upper case alias; out: " + $r.Out)
  Eq (Calls $w 'projects') 1 'the cache resolved it: no extra call'
  $r = Invoke-Fcode $w @('phien', 'proj'); Eq $r.Code 0 $r.Out; Eq (Calls $w 'projects') 1 'the real name asks nothing either'
}
T 'alias e2e: a real name wins over an alias spelled like it' {
  $w = New-W2 'al2'; Set-BoxPrefs $w '{"order":[],"aliases":{"other":"proj"}}'
  $s = New-Sess $w.LS '11111111-al02' $w.LP @('a')
  $r = Invoke-Fcode $w @('phien', 'proj')
  Eq $r.Code 0 $r.Out
  Ok (Test-Path (Join-Path $w.BS (Split-Path $s -Leaf))) ("proj was synced, not other; out: " + $r.Out)
}
T 'alias e2e: a missing or broken box prefs file is harmless: sync works, an unknown name gets the usual message' {
  $n = 0
  foreach ($c in @($null, '{oops', '[1,2]', '{"aliases":{"proj":5,"":"x"}}')) {
    $n++; $w = New-W2 "al3-$n"
    if ($null -ne $c) { Set-BoxPrefs $w $c }
    $s = New-Sess $w.LS '11111111-al03' $w.LP @('a')
    $r = Invoke-Fcode $w @('phien', 'proj'); Eq $r.Code 0 "[$c] $($r.Out)"
    Ok (Test-Path (Join-Path $w.BS (Split-Path $s -Leaf))) "[$c] synced"
    $r = Invoke-Fcode $w @('phien', 'pj'); Eq $r.Code 1 "[$c] $($r.Out)"
    Ok ($r.Out -match "Không thấy project 'pj' trong syncRepos. Có: proj, other, notonbox") "[$c] usual message; out: $($r.Out)"
  }
}
T 'alias e2e: when the box cannot be reached the cached copy resolves the alias, and a failed call does not wipe it' {
  $w = New-W2 'al4'; $cache = '{"order":[],"aliases":{"proj":"pj"}}'; Set-AliasCache $w $cache
  [void](New-Sess $w.LS '11111111-al04' $w.LP @('a'))
  $r = Invoke-Fcode $w @('phien', 'pj') @{ FAKE_SSH_FAIL = '1' }
  Eq $r.Code 1 $r.Out
  Ok ($r.Out -match 'không nói chuyện được với box') ("got as far as the box: $($r.Out)")
  Ok ($r.Out -notmatch 'Không thấy project') 'the alias was resolved from the cache'
  Eq (Get-AliasCache $w) $cache 'the cache is untouched'
}
T 'alias e2e: the project list shows "alias (real name)"' {
  $w = New-W2 'al5'
  Set-BoxPrefs $w ('{"order":[],"aliases":{"proj":"Dự án","other":"a' + '\u001b[31mb"}}')   # the box drops the second: a control character
  $r = Invoke-Fcode $w @('phien', 'nope')
  Eq $r.Code 1 $r.Out
  Ok ($r.Out -match "Có: Dự án \(proj\), other, notonbox") ("list; out: " + $r.Out)
  Ok ($r.Out.IndexOf([char]27) -lt 0) 'no escape code reaches the screen'
}
# the bare form (fcode <name>) opens an interactive ssh: a stub instabox logs the script it would run and passes everything else to the fake box
function Use-BareIb($w) {
  $py = Join-Path $w.W 'ib-bare.py'; $cmd = Join-Path $w.W 'ib-bare.cmd'; $w | Add-Member -NotePropertyName BareLog -NotePropertyValue (Join-Path $w.W 'bare.log') -Force
  $fake = Join-Path $PSScriptRoot 'fake-instabox.py'
  # BARE_FAIL=<word>,<word>: a call whose word is one of these exits 1 (the box knows no session of that name)
  $src = @'
import base64, os, re, subprocess, sys
a = sys.argv[1:]
if a and a[0] == 'ssh' and 'base64 -d' in a[-1] and 'python3' not in a[-1]:
    open(os.environ['BARE_LOG'], 'a', encoding='utf-8').write(a[-1] + '\n')
    t = base64.b64decode(re.search(r'echo (\S+) \|', a[-1]).group(1)).decode('utf-8')
    w = re.search(r"(?m)^set -- '(.*)'", t).group(1)
    sys.exit(1 if w in os.environ.get('BARE_FAIL', '').split(',') else 0)
sys.exit(subprocess.call([sys.executable, r'@@FAKE@@'] + a))
'@
  [IO.File]::WriteAllText($py, $src.Replace('@@FAKE@@', $fake), $utf8)
  [IO.File]::WriteAllText($cmd, "@echo off`r`npython `"$py`" %*`r`nexit /b %errorlevel%`r`n")
  [IO.File]::WriteAllText((Join-Path $w.U '.fcode\config.json'), (@{ instabox = $cmd; box = 'coder'; syncRepos = @($w.LP, (Join-Path $w.U 'Desktop\other'), (Join-Path $w.U 'Desktop\notonbox')) } | ConvertTo-Json -Compress))
}
function Get-BareArgs($w) {   # the word each bare call put in `set -- '<word>'` at the head of the script it sent to the box
  if (-not (Test-Path $w.BareLog)) { return @() }
  @(Get-Content $w.BareLog | Where-Object { $_ } | ForEach-Object {
    $b = [regex]::Match($_, 'echo (\S+) \|').Groups[1].Value
    $t = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b))
    [regex]::Match($t, "(?m)^set -- '(.*)'").Groups[1].Value })
}
T 'alias e2e: the bare form turns an alias into the real name before the script goes to the box; a number, a session name and a real name go through as typed' {
  $w = New-W2 'al6'; Use-BareIb $w; Set-AliasCache $w '{"order":[],"aliases":{"proj":"my proj"}}'
  foreach ($a in 'my proj', 'MY PROJ', 'proj', '2', 'omp-1') { $r = Invoke-Fcode $w @($a) @{ BARE_LOG = $w.BareLog }; Eq $r.Code 0 "[$a] $($r.Out)" }
  Eq ((Get-BareArgs $w) -join '|') 'proj|proj|proj|2|omp-1'
  Eq (Calls $w 'projects') 0 'the cache was there: no extra call'
}
T 'alias e2e: the bare form with no cache asks the box once, then never again' {
  $w = New-W2 'al7'; Use-BareIb $w; Set-BoxPrefs $w '{"order":[],"aliases":{"proj":"pj"}}'
  $r = Invoke-Fcode $w @('pj') @{ BARE_LOG = $w.BareLog }; Eq $r.Code 0 $r.Out
  Eq (Calls $w 'projects') 1 'the first call learns the aliases'
  $r = Invoke-Fcode $w @('omp-1') @{ BARE_LOG = $w.BareLog }; Eq $r.Code 0 $r.Out
  Eq (Calls $w 'projects') 1 'the cache exists now'
  Eq ((Get-BareArgs $w) -join '|') 'proj|omp-1'
}
T 'alias e2e: the bare form asks the box once for a word that can only be an alias, then refuses it; no script goes to the box' {
  $w = New-W2 'al8'; Use-BareIb $w; Set-AliasCache $w '{"order":[],"aliases":{"proj":"pj"}}'
  $r = Invoke-Fcode $w @('a b') @{ BARE_LOG = $w.BareLog }; Eq $r.Code 1 $r.Out
  Ok ($r.Out -match "Không hiểu lệnh 'a b'") $r.Out
  Eq (@(Get-BareArgs $w).Count) 0 'nothing was sent'
  Eq (Calls $w 'projects') 1 'one ask'
}
T 'alias help: fcode help and the phien / vao detail say an alias works' {
  $w = New-World 'alh'; $o = ((Invoke-Fcode $w @('help')).Out + ' ' + (Invoke-Fcode $w @('help', 'phien')).Out + ' ' + (Invoke-Fcode $w @('help', 'vao')).Out) -replace '\s+', ' '
  Ok ($o -match 'tên gọi \(alias\) đặt trong app đều được') 'overview'
  Ok ($o -match '\[project\] là tên project hoặc tên gọi \(alias\)') 'phien'
  Ok ($o -match 'tên gọi \(alias\) của nó cũng được') 'vao'
  Ok (@((Invoke-Fcode $w @('help')).Out -split "`r?`n" | Where-Object { $_.Length -gt 80 }).Count -eq 0) 'overview lines stay within 80 chars'
}

# ---- rework r1: the box reads prefs.json by the server's lenient rules; a laptop folder named differently; `fcode new` and the session list; case-only keys; unknown word; masks
function Set-BoxCfg($w, [string[]]$Names) {   # the box config.json with exactly these projects, in this order, each in its own absolute folder
  $b = ($w.W -replace '\\', '/') + '/boxws/'; $i = 0
  $items = @($Names | ForEach-Object { $i++; '"' + $_ + '":"' + $b + 'd' + $i + '"' })
  [IO.File]::WriteAllText($w.Cfg, ('{"projects":{' + ($items -join ',') + '}}'), $utf8)
}
T 'alias e2e: the box reads prefs.json by the server''s lenient rules: known projects only, NFC, 1..30 characters of letters / marks / digits / space . _ -, no real name of another project, first project wins a duplicate' {
  $w = New-W2 'al9'; Set-BoxCfg $w @('proj', 'other', 'zeta', 'p4', 'p5', 'p6', 'p7')
  Set-BoxPrefs $w ('{"order":["zeta","nope","proj","zeta"],"aliases":{"proj":"Same","other":"same","zeta":"proj","p4":"a/b","p5":"' + ('y' * 31) + '","p6":"' + ('x' * 30) + '","p7":"  Aé  ","ghost":"Boo"}}')
  $r = Invoke-Fcode $w @('phien', 'proj'); Eq $r.Code 0 $r.Out
  $c = Get-AliasCache $w | ConvertFrom-Json
  Eq (@($c.aliases.PSObject.Properties.Name | Sort-Object) -join ',') 'p6,p7,proj' 'kept: the first of a duplicate, 30 characters, NFC; dropped: another project''s name, bad character, 31 characters, unknown project'
  Eq $c.aliases.proj 'Same'
  Eq $c.aliases.p7 ('A' + [char]0xE9) 'trimmed and NFC'
  Eq ($c.order -join ',') 'zeta,proj' 'known and unique'
  Eq ($c.names -join ',') 'proj,other,zeta,p4,p5,p6,p7' 'the real names, in config order'
}
T 'alias e2e: a project added later takes a name that was an alias: the real name wins (bare form and phien)' {
  $w = New-W2 'al10'; Use-BareIb $w; Set-BoxCfg $w @('web', 'beta'); Set-BoxPrefs $w '{"aliases":{"beta":"web"}}'
  $r = Invoke-Fcode $w @('web') @{ BARE_LOG = $w.BareLog }; Eq $r.Code 0 $r.Out
  Eq ((Get-BareArgs $w) -join '|') 'web' 'the box dropped the alias: web is web'
  Ok ((Get-AliasCache $w) -notmatch '"beta":"web"') 'and the cache has none'
  Set-AliasCache $w '{"order":[],"names":["web","beta"],"aliases":{"beta":"web"},"repos":{}}'   # a cache written before web was added: the cached real names settle it
  $r = Invoke-Fcode $w @('web') @{ BARE_LOG = $w.BareLog }; Eq $r.Code 0 $r.Out
  Eq ((Get-BareArgs $w) -join '|') 'web|web'
  $r = Invoke-Fcode $w @('phien', 'web'); Eq $r.Code 1 $r.Out
  Ok ($r.Out -match "Không thấy project 'web' trong syncRepos") ("web, not beta; out: " + $r.Out)
}
T 'alias: a laptop folder named differently is found through the cached repo (Format-ProjectName with the folder, Get-PhienKeyOf)' {
  $gd = Join-Path $Root 'ak\FCode'; New-GitDir $gd; & git -C $gd remote add origin https://github.com/Owner/Fcoding.git
  With-PrefsCache '{"order":[],"names":["fcoding"],"aliases":{"fcoding":"App"},"repos":{"fcoding":"owner/fcoding"}}' {
    Eq (Format-ProjectName 'FCode' $gd) 'App (FCode)'
    Eq (Format-ProjectName 'FCode') 'FCode' 'no folder: no link'
    $pp = [ordered]@{ fcode = $gd; other = (Join-Path $Root 'ak\none') }
    Eq (Get-PhienKeyOf 'fcoding' $pp) 'fcode'
    Eq (Get-PhienKeyOf 'FCODING' $pp) 'fcode' 'any case'
    Eq (Get-PhienKeyOf 'fcode' $pp) 'fcode' 'a folder of that name'
    Ok ($null -eq (Get-PhienKeyOf 'nope' $pp)) 'unknown'
  }
}
T 'alias e2e: fcode phien <alias> (or the box name) works when the laptop folder has another name but the same GitHub repo; the list shows the alias' {
  $w = New-World 'al11'
  $ld = Join-Path $w.U 'Desktop\FCode'; New-GitDir $ld; & git -C $ld remote add origin https://github.com/Owner/Proj.git
  New-GitDir $w.BP; & git -C $w.BP remote add origin git@github-proj:owner/proj.git
  [IO.File]::WriteAllText($w.Cfg, (@{ projects = @{ proj = $w.BP } } | ConvertTo-Json -Compress))
  [IO.File]::WriteAllText((Join-Path $w.U '.fcode\config.json'), (@{ instabox = $Cmd; box = 'coder'; syncRepos = @($ld) } | ConvertTo-Json -Compress))
  Set-BoxPrefs $w '{"aliases":{"proj":"App"}}'
  $lsd = Join-Path $w.U ('.omp\agent\sessions\' + (Get-OmpEncodedDir $ld $w.U (Join-Path $w.U 'AppData\Local\Temp')))
  $a = New-Sess $lsd 'abcdabcd-al11' $ld @('a')
  $r = Invoke-Fcode $w @('phien', 'App'); Eq $r.Code 0 $r.Out
  Ok (Test-Path (Join-Path $w.BS (Split-Path $a -Leaf))) ("synced into the box project; out: " + $r.Out)
  Ok ($r.Out -match '== App \(proj\): gửi 1 phiên') ("header; out: " + $r.Out)
  $r = Invoke-Fcode $w @('phien', 'proj'); Eq $r.Code 0 $r.Out
  Ok ($r.Out -match '== App \(proj\):') ("the box name finds the folder too; out: " + $r.Out)
  $r = Invoke-Fcode $w @('phien', 'nope'); Eq $r.Code 1 $r.Out
  Ok ($r.Out -match 'Có: App \(fcode\)') ("list; out: " + $r.Out)
}
# the bare-form script runs on the box; here it runs in Git's bash with fake tmux and fcode-new
$GitBash = Join-Path (Split-Path (Split-Path (Split-Path (((& git --exec-path) | Select-Object -First 1) -replace '/', '\')))) 'bin\bash.exe'
function Invoke-BareScript([string]$Text, [string]$Stdin, [string]$Tag) {
  $d = Join-Path $Root ('bs-' + $Tag); $bin = Join-Path $d 'bin'; [void](New-Item -ItemType Directory -Path $bin -Force)
  $log = Join-Path $d 'calls.log'
  [IO.File]::WriteAllText((Join-Path $bin 'tmux'), @'
#!/bin/bash
case "$1" in
  list-sessions) echo 'deal-sync-omp|0|deal-sync|omp' ;;
  *) echo "tmux $*" >> "$FAKE_LOG" ;;
esac
'@.Replace("`r`n", "`n"), $utf8)
  [IO.File]::WriteAllText((Join-Path $bin 'fcode-new'), @'
#!/bin/bash
echo "fcode-new $*" >> "$FAKE_LOG"
case "$1" in
  --projects) printf 'deal-sync\nother\n' ;;
  --harnesses) printf 'omp\nclaude\n' ;;
  *) echo deal-sync-omp ;;
esac
'@.Replace("`r`n", "`n"), $utf8)
  $sf = Join-Path $d 'script.sh'; [IO.File]::WriteAllText($sf, $Text.Replace("`r`n", "`n"), $utf8)
  $psi = New-Object Diagnostics.ProcessStartInfo $GitBash
  $psi.Arguments = '"' + ($sf -replace '\\', '/') + '"'
  $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = $utf8
  $psi.EnvironmentVariables['PATH'] = $bin + ';' + $env:PATH; $psi.EnvironmentVariables['FAKE_LOG'] = $log
  $p = [Diagnostics.Process]::Start($psi)
  $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
  $p.StandardInput.Write($Stdin); $p.StandardInput.Close()
  if (-not $p.WaitForExit(60000)) { $p.Kill(); throw 'the box script timed out' }
  [pscustomobject]@{ Out = $o.Result; Err = $e.Result; Log = $(if (Test-Path $log) { [IO.File]::ReadAllText($log) } else { '' }) }
}
T 'alias: the box script shows "alias (real name)" in the session list and the `fcode new` project picker; the real name is what is picked and run; alias text is data, never code' {
  With-PrefsCache '{"order":[],"aliases":{"deal-sync":"Cửa hàng","other":"a$(echo PWNED)b\t;x","bad key":"zzz"}}' {
    $s = Get-BareScript '--list'
    Ok ($s.StartsWith("set -- '--list'`naliases_b64='")) 'the word and the aliases lead the script'
    $r = Invoke-BareScript $s '' 'list'
    Ok ($r.Out.Contains('dự án: Cửa hàng (deal-sync)')) ("session list; out: " + $r.Out + $r.Err)
    $r = Invoke-BareScript (Get-BareScript '--new') "1`n1`n" 'new'
    Ok ($r.Out.Contains('  1) Cửa hàng (deal-sync)')) ("picker; out: " + $r.Out + $r.Err)
    Ok ($r.Out.Contains('  2) a$(echo PWNED)b?;x (other)')) 'a tab became ?, the text was not run'
    Ok ($r.Out -notmatch '(?m)^PWNED' -and -not $r.Out.Contains('zzz')) 'nothing ran; a name that is no project name is not sent'
    Ok ($r.Out.Contains('Đang mở phiên mới (Cửa hàng (deal-sync), omp)')) ("opening line; out: " + $r.Out)
    Ok ($r.Log.Contains('fcode-new deal-sync omp') -and $r.Log.Contains('tmux -u attach -t =deal-sync-omp')) ("the real name went to fcode-new; log: " + $r.Log)
  }
  With-PrefsCache $null {
    $r = Invoke-BareScript (Get-BareScript '--list') '' 'list0'
    Ok ($r.Out.Contains('dự án: deal-sync') -and -not $r.Out.Contains('(deal-sync)')) ("no aliases: the real name alone; out: " + $r.Out)
  }
}
T 'alias e2e: project names that differ only in case cannot break the scan reply; the CLI keeps working' {
  $w = New-W2 'al12'; Set-BoxCfg $w @('Alpha', 'alpha', 'proj'); Set-BoxPrefs $w '{"aliases":{"Alpha":"x","alpha":"y","proj":"pj"}}'
  $r = Invoke-Fcode $w @('phien', 'proj'); Eq $r.Code 0 $r.Out
  Ok ($r.Out -notmatch 'Cannot convert|keys with different casing') $r.Out
  Eq (@(((Get-AliasCache $w) | ConvertFrom-Json).aliases.PSObject.Properties.Name | Sort-Object) -join ',') 'Alpha,proj'
}
T 'alias e2e: the bare form asks the box once for a word the box does not know, even with a cache; an alias set after the cache is found; a session the box knows asks nothing' {
  $w = New-W2 'al13'; Use-BareIb $w; Set-AliasCache $w '{"order":[],"names":["proj","other"],"aliases":{},"repos":{}}'
  Set-BoxPrefs $w '{"aliases":{"proj":"pj"}}'
  $e = @{ BARE_LOG = $w.BareLog; BARE_FAIL = 'pj,omp-9' }
  $r = Invoke-Fcode $w @('omp-1') $e; Eq $r.Code 0 $r.Out
  Eq (Calls $w 'projects') 0 'a session the box knows: no ask'
  $r = Invoke-Fcode $w @('pj') $e; Eq $r.Code 0 $r.Out
  Eq (Calls $w 'projects') 1 'one ask after the box refused pj'
  Eq ((Get-BareArgs $w) -join '|') 'omp-1|pj|proj' 'then the script ran again with the real name'
  $r = Invoke-Fcode $w @('omp-9') $e; Eq $r.Code 1 $r.Out
  Eq (Calls $w 'projects') 2 'a word that is nothing: asked once, no loop'
  Eq ((Get-BareArgs $w) -join '|') 'omp-1|pj|proj|omp-9'
  Set-BoxPrefs $w '{"aliases":{"proj":"my proj"}}'
  $r = Invoke-Fcode $w @('my proj') $e; Eq $r.Code 0 $r.Out
  Eq (@(Get-BareArgs $w) | Select-Object -Last 1) 'proj' 'a word with a space can only be an alias: asked before the first script'
}
if ($env:FCODE_TEST_KEEP) { Write-Host "kept: $Root" } else { for ($i = 0; $i -lt 4 -and (Test-Path -LiteralPath $Root); $i++) { Set-Location -LiteralPath $env:TEMP; Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path -LiteralPath $Root) { Start-Sleep -Seconds 3 } } }   # omp may still hold its native addon for a moment
Write-Host ''
Write-Host "passed $script:pass, failed $script:fail"
exit $(if ($script:fail) { 1 } else { 0 })
