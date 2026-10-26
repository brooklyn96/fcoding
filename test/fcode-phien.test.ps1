# Tests for `fcode phien` (laptop/fcode.ps1): omp session sync laptop <-> box.
# Run:  pwsh -NoProfile -File test/fcode-phien.test.ps1     (also works with: powershell -NoProfile -File ...)
# Needs python (3.8+) on PATH: the box program ($PhienPy) is run locally through test/fake-instabox.cmd, so the real
# ~/.omp and the real box are never touched. Everything lives in a temp folder that is removed at the end.
#   FCODE_TEST_BOX=1   also run one end-to-end pass on the real instabox box (throwaway HOME there; laptop side = temp USERPROFILE).
#   FCODE_TEST_ONLY=<regex>   run only the tests whose name matches (used for the mutant runs)
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
  'Get-OmpHeaderSpan', 'Open-ShareRead', 'Read-Head', 'Get-OmpBodyOff', 'Test-OmpNonEmpty', 'Get-RangeSha', 'Get-PhienOff', 'Test-PhienPrefix', 'Get-PhienKnownVersions', 'Test-PhienKnownVersion', 'Get-OmpHeaderVersion', 'Get-OmpHeaderInfo', 'Get-PhienVersionNote', 'Get-PhienUnknownNote', 'Get-PhienNoteRx', 'Get-PhienNoteSpecs', 'Invoke-GitQuiet', 'Get-PhienLocalNotes', 'Get-PhienNotePlan', 'Get-PhienNoteStatePath', 'Read-PhienNoteState', 'Write-PhienNoteState', 'Add-PhienNoteExclude', 'Install-PhienNote',
  'Copy-OmpSession', 'Get-OmpBlobRefs', 'Get-OmpBlobIndex', 'Get-PhienLocalScan', 'Compare-PhienFile', 'Get-PhienPlan', 'Install-PhienFile',
  'Install-PhienTask', 'Remove-PhienTask', 'New-PhienPartName', 'Get-PhienBoxBlobSet', 'New-PhienBatch', 'Get-PhienBatch', 'Remove-PhienNoteExclude',
  'Get-PhienDirFiles', 'Get-PhienIdOf', 'Test-PhienDeps', 'Get-PhienUnitBytes', 'Get-PhienUpstreamNotes'
foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
$pyAssign = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$PhienPy' }, $true)
Invoke-Expression $pyAssign.Extent.Text
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
function Nt([string]$Name, [string]$Sha, [double]$Age = 600, [bool]$Ign = $true) { [pscustomobject]@{ name = $Name; size = 1; mtime = ((ConvertTo-Epoch (Get-Date)) - $Age); sha = $Sha; ign = $Ign } }
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
  Ok ((Get-Content "$d\.git\info\exclude" -Raw) -match "(?m)^/HANDOFF-b\.md\r?\n/HANDOFF-c\.md") 'new line started after a file without final newline'
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
  Eq (($p.Release | ForEach-Object { "$($_.Name):$($_.TrackedOn):$($_.OldOn)" }) -join ',') 'A.md:laptop:box'; Eq ($p.Put.Count + $p.Get.Count) 0 'and it is not synced any more'
  # tracked on the box, the laptop copy came from the box (marker) -> release on the laptop
  $p = Get-PhienNotePlan 'proj' (NS @((Nt 'B.md' 'b1'))) (NS @((Nt 'B.md' 'b1')) @('B.md')) @{ 'exclude:laptop:proj/B.md' = '1' } $now $now
  Eq (($p.Release | ForEach-Object { "$($_.Name):$($_.TrackedOn):$($_.OldOn)" }) -join ',') 'B.md:box:laptop'
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
  Eq (Remove-PhienNoteExclude $d 'HANDOFF-a.md') $true
  $t = Get-Content $ex -Raw
  Ok ($t -notmatch '(?m)^/HANDOFF-a\.md\r?$') 'our line is gone'
  Ok ($t -match '(?m)^/HANDOFF-ab\.md\r?$' -and $t -match '(?m)^/other\.txt\r?$' -and $t -match '# my own comment') 'every other line stays (also the one with the same prefix)'
  Eq (Remove-PhienNoteExclude $d 'HANDOFF-a.md') $false 'nothing left to remove'
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
function Invoke-Fcode($World, [string[]]$FArgs, [hashtable]$ExtraEnv = @{}) {
  $ErrorActionPreference = 'Continue'   # Windows PowerShell 5.1 turns native stderr into errors under Stop
  $save = @{}
  $set = @{ USERPROFILE = $World.U; LOCALAPPDATA = (Join-Path $World.U 'AppData\Local'); FCODE_PHIEN_BOXENV = ('HOME=' + ($World.BH -replace '\\', '/') + ' FCODE_CFG=' + ($World.Cfg -replace '\\', '/')); FAKE_SSH_LOG = $World.Log; TEMP = (Join-Path $World.U 'AppData\Local\Temp'); TMP = (Join-Path $World.U 'AppData\Local\Temp') }
  foreach ($k in $ExtraEnv.Keys) { $set[$k] = $ExtraEnv[$k] }
  foreach ($k in $set.Keys) { $save[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $set[$k]) }
  try {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Fcode @FArgs 2>&1 | Out-String
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
    $enc = Get-OmpEncodedDir $bp $bt '/tmp'
    $sd = "$bt/.omp/agent/sessions/$enc"
    try {
      $cfgB64 = [Convert]::ToBase64String($utf8.GetBytes((@{ projects = @{ proj = $bp } } | ConvertTo-Json -Compress)))
      [void](Invoke-RealBox "mkdir -p $bp $sd $bt/.omp/agent/blobs && git -C $bp init -q && echo $cfgB64 | base64 -d > $bt/cfg.json && echo ready")
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
      $env0 = @{ FCODE_PHIEN_BOXENV = "HOME=$bt FCODE_CFG=$bt/cfg.json" }
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
      $o = Invoke-RealBox "cd $bp && printf '{`"id`":`"1`",`"type`":`"get_state`"}\n' | HOME=$bt PI_CODING_AGENT_DIR=$bt/.omp/agent timeout 60 /data/home/.local/bin/omp --mode rpc --no-extensions --no-skills --no-rules --no-title --model openai/gpt-5.5 --api-key sk-dummy -r a0000000 | grep -o '`"sessionFile`":`"[^`"]*`"' | head -n 1"
      Ok ($o -like "*$($aname)*") "omp on the box resolved the synced session: $o"
      # second run
      $r2 = Invoke-Fcode $w @('phien') $env0; Eq $r2.Code 0 $r2.Out
      Ok ($r2.Out -match '0 file gửi lên box, 0 file lấy về laptop' -and $r2.Out -notmatch 'chép [1-9]') ("second run copies nothing; out: " + $r2.Out)
    } finally { [void](Invoke-RealBox "rm -rf $bt") }
  }
  T 'real box: a session file that a box process holds open is left alone (busy) and its top waits; once closed, the next run updates it' {
    $bt = Invoke-RealBox 'mktemp -d /tmp/fcode-phien-test-XXXXXXXX'; Ok ($bt -match '\A/tmp/fcode-phien-test-[A-Za-z0-9]{8}\z') "throwaway dir: $bt"; $bp = "$bt/ws/proj"
    $w = New-World 'real2'
    [IO.File]::WriteAllText((Join-Path $w.U '.fcode\config.json'), (@{ instabox = $RealIb; box = 'coder'; syncRepos = @($w.LP) } | ConvertTo-Json -Compress))
    $sd = "$bt/.omp/agent/sessions/$(Get-OmpEncodedDir $bp $bt '/tmp')"
    try {
      $cfgB64 = [Convert]::ToBase64String($utf8.GetBytes((@{ projects = @{ proj = $bp } } | ConvertTo-Json -Compress)))
      [void](Invoke-RealBox "mkdir -p $bp $sd && echo $cfgB64 | base64 -d > $bt/cfg.json")
      $a = New-Sess $w.LS 'a0000000-0000-7000-8000-0000000000b5' $w.LP @('a') 'A' "`n" '2026-10-20T10-00-00-000Z'; $an = Split-Path $a -Leaf
      $env0 = @{ FCODE_PHIEN_BOXENV = "HOME=$bt FCODE_CFG=$bt/cfg.json" }
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
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Ok ((Get-Content "$($w.BP)\.git\info\exclude" -Raw) -match '(?m)^/HANDOFF-lap\.md\r?$') 'box exclude has our line'
  Ok ((Get-Content "$($w.LP)\.git\info\exclude" -Raw) -match '(?m)^/HANDOFF-box\.md\r?$') 'laptop exclude has our line'
  $st = Get-Content (Join-Path $w.U 'AppData\Local\fcode\handoff-state.json') -Raw | ConvertFrom-Json
  Ok ($null -ne $st.PSObject.Properties['exclude:box:proj/HANDOFF-lap.md'] -and $null -ne $st.PSObject.Properties['exclude:laptop:proj/HANDOFF-box.md']) 'markers recorded for the lines fcode added'
  Ok ($null -eq $st.PSObject.Properties['exclude:box:proj/TASK.md']) 'no marker for a line that was the user''s'
  # B: the laptop starts tracking HANDOFF-lap.md and TASK.md (upstream began to carry them)
  Git-Commit $w.LP @('HANDOFF-lap.md', 'TASK.md')
  $r = Invoke-Fcode $w @('phien'); Eq $r.Code 0 $r.Out
  Ok ($r.Out -match 'ghi chú HANDOFF-lap\.md giờ do git theo dõi \(trên laptop\): bản cũ trên box xóa được') ("one line for the user; out: " + $r.Out)
  Ok ($r.Out -notmatch 'TASK\.md giờ do git') 'no line for a name whose exclude was not ours'
  $bx = Get-Content "$($w.BP)\.git\info\exclude" -Raw
  Ok ($bx -notmatch '(?m)^/HANDOFF-lap\.md\r?$') 'our line removed on the box'
  Ok ($bx -match '(?m)^/TASK\.md\r?$' -and $bx -match '(?m)^/user-ignored\.txt\r?$' -and $bx -match '# my own comment') 'every other line stays'
  Eq (Get-Content "$($w.BP)\HANDOFF-lap.md" -Raw) 'from laptop' 'the old copy is not deleted'
  $st = Get-Content (Join-Path $w.U 'AppData\Local\fcode\handoff-state.json') -Raw | ConvertFrom-Json
  Ok ($null -eq $st.PSObject.Properties['exclude:box:proj/HANDOFF-lap.md'] -and $null -eq $st.PSObject.Properties['proj/HANDOFF-lap.md']) 'state forgets the name'
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
  $lx = Get-Content "$($w.LP)\.git\info\exclude" -Raw
  Ok ($lx -notmatch '(?m)^/HANDOFF-box\.md\r?$') 'our line removed on the laptop'
  Ok ($lx -match '(?m)^/user-ignored\.txt\r?$' -and $lx -match '# my own comment') 'laptop: other lines stay'
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
function New-Origin([string]$Bare) {
  $ErrorActionPreference = 'Continue'
  & git -c init.defaultBranch=main init -q --bare $Bare 2>&1 | Out-Null
  & git -c init.defaultBranch=main init -q "$Bare-work" 2>&1 | Out-Null
  Put-File "$Bare-work\README.md" 'r'; Git-Commit "$Bare-work" @('README.md'); & git -C "$Bare-work" push -q $Bare HEAD:main 2>&1 | Out-Null
}
function Push-Origin([string]$Bare, [string]$Name, [string]$Text) { $ErrorActionPreference = 'Continue'; Put-File "$Bare-work\$Name" $Text; Git-Commit "$Bare-work" @($Name); & git -C "$Bare-work" push -q $Bare HEAD:main 2>&1 | Out-Null }
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

if ($env:FCODE_TEST_KEEP) { Write-Host "kept: $Root" } else { for ($i = 0; $i -lt 4 -and (Test-Path -LiteralPath $Root); $i++) { Set-Location -LiteralPath $env:TEMP; Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path -LiteralPath $Root) { Start-Sleep -Seconds 3 } } }   # omp may still hold its native addon for a moment
Write-Host ''
Write-Host "passed $script:pass, failed $script:fail"
exit $(if ($script:fail) { 1 } else { 0 })
