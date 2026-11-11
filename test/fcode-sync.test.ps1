# Tests for `fcode sync` (Invoke-Sync in laptop/fcode.ps1): update with local changes, follow the repo's default branch.
# Run:  pwsh -NoProfile -File test/fcode-sync.test.ps1     (also works with: powershell -NoProfile -File ...)
# No network, no real ssh / gh: the functions are loaded out of fcode.ps1 and run in this process against temp bare repos + clones.
# Git runs with an isolated global config (GIT_CONFIG_GLOBAL, no system config), USERPROFILE is a temp folder; everything lives in
# one temp folder that is removed at the end.
#   FCODE_TEST_ONLY=<regex>   run only the tests whose name matches
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$Repo = Split-Path -Parent $PSScriptRoot
$Fcode = Join-Path $Repo 'laptop\fcode.ps1'
$Root = Join-Path ([IO.Path]::GetTempPath()) ('fcode-sync-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $Root)
Set-Location -LiteralPath $Root
$script:pass = 0; $script:fail = 0
$utf8 = New-Object Text.UTF8Encoding($false)
$savedEnv = @{}
foreach ($k in 'USERPROFILE', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM', 'FCODE_SYNC_REPOS') { $savedEnv[$k] = [Environment]::GetEnvironmentVariable($k) }
$env:USERPROFILE = Join-Path $Root 'home'; [void](New-Item -ItemType Directory -Path $env:USERPROFILE)
$gc = Join-Path $Root 'gitconfig'
[IO.File]::WriteAllText($gc, "[user]`n`tname = T`n`temail = t@example.invalid`n[core]`n`tautocrlf = false`n[init]`n`tdefaultBranch = main`n", $utf8)
$env:GIT_CONFIG_GLOBAL = $gc; $env:GIT_CONFIG_NOSYSTEM = '1'; Remove-Item Env:FCODE_SYNC_REPOS -ErrorAction SilentlyContinue

function T([string]$Name, [scriptblock]$Body) {
  if ($env:FCODE_TEST_ONLY -and $Name -notmatch $env:FCODE_TEST_ONLY) { return }
  try { & $Body; $script:pass++; Write-Host "PASS $Name" }
  catch { $script:fail++; Write-Host "FAIL $Name :: $($_.Exception.Message)" }
}
function Eq($Got, $Want, [string]$What = '') { if ("$Got" -cne "$Want") { throw "$What expected [$Want] got [$Got]" } }
function Ok([bool]$c, [string]$What) { if (-not $c) { throw $What } }

# --- load the sync functions out of fcode.ps1 without running the script ---
$tokens = $null; $errs = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Fcode, [ref]$tokens, [ref]$errs)
if ($errs.Count) { throw "fcode.ps1 does not parse: $($errs[0].Message)" }
$wanted = 'Invoke-Git', 'Get-GitError', 'Get-GitCount', 'Get-SyncDefaultBranch', 'Invoke-Sync'
$found = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true))
if ($found.Count -ne $wanted.Count) { throw "fcode.ps1 lacks some of: $($wanted -join ', ')" }
foreach ($fn in $found) { . ([scriptblock]::Create($fn.Extent.Text)) }
# fakes: no box, no aliases, no GitHub (the temp origins are not GitHub URLs, so `gh` is never reached)
function Add-SyncMissing { }
function Format-ProjectName([string]$Name, [string]$Dir = '') { $Name }
function gh { throw 'gh must not be called' }
$ConfigFile = Join-Path $env:USERPROFILE '.fcode\config.json'
$script:SyncRepos = @()

# --- git helpers (throw on a non-zero exit) ---
function G([string]$Dir, [string[]]$GitArgs) {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = & git -C $Dir @GitArgs 2>&1; $c = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
  if ($c -ne 0) { throw "git $($GitArgs -join ' ') (in $Dir) exit ${c}: $(@($o) -join ' ')" }
  (@($o | ForEach-Object { "$_" }) -join "`n").Trim()
}
function Put([string]$Dir, [string]$File, [string]$Text) { [IO.File]::WriteAllText((Join-Path $Dir $File), $Text, $utf8) }
function Get-Text([string]$Dir, [string]$File) { [IO.File]::ReadAllText((Join-Path $Dir $File)) }
$script:N = 0
# one world: <name>.git (origin, default branch $Def), <name>-seed (where "upstream" commits are made), <name> (the laptop clone)
function New-World([string]$Def = 'main') {
  $script:N++; $n = "w$($script:N)"
  $bare = Join-Path $Root "$n.git"; $seed = Join-Path $Root "$n-seed"; $lap = Join-Path $Root $n
  [void](G $Root @('init', '-q', '--bare', '-b', $Def, $bare))
  [void](New-Item -ItemType Directory -Path $seed)
  [void](G $seed @('init', '-q', '-b', $Def))
  Put $seed 'a.txt' "one`n"; Put $seed '.gitignore' ".env`n"
  [void](G $seed @('add', '-A')); [void](G $seed @('commit', '-q', '-m', 'first'))
  [void](G $seed @('remote', 'add', 'origin', $bare)); [void](G $seed @('push', '-q', 'origin', $Def))
  [void](G $Root @('clone', '-q', $bare, $lap))
  @{ Bare = $bare; Seed = $seed; Lap = $lap; Def = $Def }
}
# a commit upstream: Files = @{ name = text }; -Force adds ignored files too
function Push-Up($W, [hashtable]$Files, [string]$Msg = 'up', [switch]$Force) {
  foreach ($k in $Files.Keys) { Put $W.Seed $k $Files[$k] }
  [void](G $W.Seed $(if ($Force) { @('add', '-f', '-A') } else { @('add', '-A') }))
  [void](G $W.Seed @('commit', '-q', '-m', $Msg)); [void](G $W.Seed @('push', '-q', 'origin', $W.Def))
}
# git 2.48+ fetch re-creates a missing origin/HEAD (followRemoteHEAD=create); `never` keeps the old-git case testable
function No-Head($W) { [void](G $W.Lap @('config', 'remote.origin.followRemoteHEAD', 'never')); [void](G $W.Lap @('remote', 'set-head', 'origin', '-d')) }
function Head($W) { G $W.Lap @('rev-parse', 'HEAD') }
function Run-Sync([string]$Dir) {
  $script:SyncRepos = @($Dir)
  $all = @(& { Invoke-Sync } 6>&1)
  $code = @($all | Where-Object { $_ -isnot [Management.Automation.InformationRecord] })
  $text = @($all | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" })
  if ($code.Count -ne 1) { throw "Invoke-Sync returned $($code.Count) values: $($code -join ',')" }
  @{ Code = [int]$code[0]; Text = ($text -join "`n") }
}
function Summary($r) { ($r.Text -split "`n" | Where-Object { $_ -match '^\d+ project:' } | Select-Object -First 1) }

T 'clean main behind: updated' {
  $w = New-World; Push-Up $w @{ 'b.txt' = "two`n" }
  $r = Run-Sync $w.Lap
  Eq $r.Code 0
  Ok ($r.Text.Contains('main: đã cập nhật 1 commit')) "message: $($r.Text)"
  Ok (-not $r.Text.Contains('giữ nguyên')) 'no kept-files note on a clean tree'
  Eq (Head $w) (G $w.Lap @('rev-parse', 'origin/main')) 'HEAD at origin/main'
  Eq (Get-Text $w.Lap 'b.txt') "two`n" 'new file arrived'
  Ok ((Summary $r).StartsWith('1 project: 1 đã cập nhật, 0 đã mới nhất, 0 bỏ qua')) "summary: $(Summary $r)"
}
T 'clean main, nothing new: already current' {
  $w = New-World
  $r = Run-Sync $w.Lap
  Ok ($r.Text.Contains('main: đã mới nhất')) "message: $($r.Text)"
  Ok ((Summary $r).StartsWith('1 project: 0 đã cập nhật, 1 đã mới nhất, 0 bỏ qua')) "summary: $(Summary $r)"
}
T 'untracked unrelated file + behind: updated, file kept, note counts 1 file' {
  $w = New-World; Push-Up $w @{ 'b.txt' = "two`n" }
  Put $w.Lap 'TASK.md' "my notes`n"
  $r = Run-Sync $w.Lap
  Ok ($r.Text.Contains('main: đã cập nhật 1 commit (giữ nguyên 1 file chưa lưu)')) "message: $($r.Text)"
  Eq (Get-Text $w.Lap 'TASK.md') "my notes`n" 'untracked file kept'
  Eq (Get-Text $w.Lap 'b.txt') "two`n" 'new file arrived'
  Ok ((Summary $r).StartsWith('1 project: 1 đã cập nhật, 0 đã mới nhất, 0 bỏ qua')) "summary: $(Summary $r)"
}
T 'untracked unrelated file + nothing new: already current (not skipped)' {
  $w = New-World; Put $w.Lap 'TASK.md' "x`n"
  $r = Run-Sync $w.Lap
  Ok ($r.Text.Contains('main: đã mới nhất')) "message: $($r.Text)"
  Ok ((Summary $r).StartsWith('1 project: 0 đã cập nhật, 1 đã mới nhất, 0 bỏ qua')) "summary: $(Summary $r)"
}
T 'modified tracked file not touched upstream + behind: updated, change kept' {
  $w = New-World; Push-Up $w @{ 'b.txt' = "two`n" }
  Put $w.Lap 'a.txt' "one edited`n"
  $r = Run-Sync $w.Lap
  Ok ($r.Text.Contains('main: đã cập nhật 1 commit (giữ nguyên 1 file chưa lưu)')) "message: $($r.Text)"
  Eq (Get-Text $w.Lap 'a.txt') "one edited`n" 'local edit kept'
  Eq (Get-Text $w.Lap 'b.txt') "two`n" 'new file arrived'
}
T 'untracked file that upstream adds: refused, file and HEAD unchanged, counted skipped' {
  $w = New-World; Push-Up $w @{ 'new.txt' = "upstream`n" }
  Put $w.Lap 'new.txt' "mine`n"; $h0 = Head $w
  $r = Run-Sync $w.Lap
  Ok ($r.Text -match 'bỏ qua: git không cập nhật được: error:') "message: $($r.Text)"
  Ok ($r.Text -match '(?m)^    new\.txt$') "git's file list shows new.txt: $($r.Text)"
  Eq (Get-Text $w.Lap 'new.txt') "mine`n" 'file not overwritten'
  Eq (Head $w) $h0 'HEAD unchanged'
  Eq (G $w.Lap @('stash', 'list')) '' 'no stash made'
  Ok ((Summary $r).StartsWith('1 project: 0 đã cập nhật, 0 đã mới nhất, 1 bỏ qua')) "summary: $(Summary $r)"
}
T 'modified tracked file that upstream changes: refused, local change kept' {
  $w = New-World; Push-Up $w @{ 'a.txt' = "one upstream`n" }
  Put $w.Lap 'a.txt' "one mine`n"; $h0 = Head $w
  $r = Run-Sync $w.Lap
  Ok ($r.Text -match 'bỏ qua: git không cập nhật được: error:') "message: $($r.Text)"
  Ok ($r.Text -match '(?m)^    a\.txt$') "git's file list shows a.txt: $($r.Text)"
  Eq (Get-Text $w.Lap 'a.txt') "one mine`n" 'local change kept'
  Eq (Head $w) $h0 'HEAD unchanged'
  Eq (G $w.Lap @('stash', 'list')) '' 'no stash made'
  Ok ((Summary $r).StartsWith('1 project: 0 đã cập nhật, 0 đã mới nhất, 1 bỏ qua')) "summary: $(Summary $r)"
}
T 'ignored file (.env) that upstream adds: refused, not overwritten' {
  $w = New-World; Push-Up $w @{ '.env' = "upstream`n" } -Force
  Put $w.Lap '.env' "secret`n"; $h0 = Head $w
  Eq (G $w.Lap @('status', '--porcelain')) '' 'the .env is ignored (clean status)'
  $r = Run-Sync $w.Lap
  Ok ($r.Text -match 'bỏ qua: git không cập nhật được: error:') "message: $($r.Text)"
  Ok ($r.Text -match '(?m)^    \.env$') "git's file list shows .env: $($r.Text)"
  Eq (Get-Text $w.Lap '.env') "secret`n" '.env not overwritten'
  Eq (Head $w) $h0 'HEAD unchanged'
  Ok ((Summary $r).StartsWith('1 project: 0 đã cập nhật, 0 đã mới nhất, 1 bỏ qua')) "summary: $(Summary $r)"
}
T 'refusal lists at most 5 files, then ...' {
  $w = New-World; $f = @{}; 1..7 | ForEach-Object { $f["n$_.txt"] = "u$_`n" }; Push-Up $w $f
  1..7 | ForEach-Object { Put $w.Lap "n$_.txt" "m$_`n" }
  $r = Run-Sync $w.Lap
  Eq @($r.Text -split "`n" | Where-Object { $_ -match '^    n\d\.txt$' }).Count 5 'five file lines'
  Ok ($r.Text -match '(?m)^    \.\.\.$') "ellipsis: $($r.Text)"
}
T 'default branch master (origin/HEAD -> origin/master): updated, messages say master' {
  $w = New-World 'master'
  Eq (G $w.Lap @('symbolic-ref', '--short', 'refs/remotes/origin/HEAD')) 'origin/master' 'origin/HEAD'
  Push-Up $w @{ 'b.txt' = "two`n" }
  Put $w.Lap 'notes.md' "n`n"
  $r = Run-Sync $w.Lap
  Ok ($r.Text.Contains('master: đã cập nhật 1 commit (giữ nguyên 1 file chưa lưu)')) "message: $($r.Text)"
  Ok (-not ($r.Text -match '\bmain\b')) "no word main in the output: $($r.Text)"
  Eq (Head $w) (G $w.Lap @('rev-parse', 'origin/master')) 'HEAD at origin/master'
}
T 'default branch master: box branch counts are against origin/master' {
  $w = New-World 'master'
  [void](G $w.Seed @('checkout', '-q', '-b', 'box/topic')); Put $w.Seed 'x.txt' "x`n"; [void](G $w.Seed @('add', '-A')); [void](G $w.Seed @('commit', '-q', '-m', 'x1'))
  Put $w.Seed 'y.txt' "y`n"; [void](G $w.Seed @('add', '-A')); [void](G $w.Seed @('commit', '-q', '-m', 'x2'))
  [void](G $w.Seed @('push', '-q', 'origin', 'box/topic'))
  [void](G $w.Seed @('checkout', '-q', '-b', 'box/old', 'master')); [void](G $w.Seed @('push', '-q', 'origin', 'box/old'))
  $r = Run-Sync $w.Lap
  Ok ($r.Text -match 'nhánh box: origin/box/topic - 2 commit chờ merge') "waiting branch: $($r.Text)"
  Ok ($r.Text -match 'nhánh box: origin/box/old - đã nằm trong master') "merged branch says master: $($r.Text)"
  Ok ((Summary $r).EndsWith('; 1 nhánh box chờ merge')) "summary: $(Summary $r)"
}
T 'no origin/HEAD: falls back to origin/main' {
  $w = New-World; No-Head $w; Push-Up $w @{ 'b.txt' = "two`n" }
  $r = Run-Sync $w.Lap
  Ok ($r.Text.Contains('main: đã cập nhật 1 commit')) "message: $($r.Text)"
}
T 'no origin/HEAD, only origin/master: falls back to origin/master' {
  $w = New-World 'master'; No-Head $w; Push-Up $w @{ 'b.txt' = "two`n" }
  $r = Run-Sync $w.Lap
  Ok ($r.Text.Contains('master: đã cập nhật 1 commit')) "message: $($r.Text)"
}
T 'default branch master + branch.master.mergeOptions=--squash: really fast-forwarded (the override follows the default branch)' {
  $w = New-World 'master'; [void](G $w.Lap @('config', 'branch.master.mergeOptions', '--squash')); Push-Up $w @{ 'b.txt' = "two`n" }
  $r = Run-Sync $w.Lap
  Ok ($r.Text.Contains('master: đã cập nhật 1 commit')) "message: $($r.Text)"
  Eq (Head $w) (G $w.Lap @('rev-parse', 'origin/master')) 'HEAD at origin/master'
  Eq (G $w.Lap @('status', '--porcelain')) '' 'clean tree, nothing staged by a squash'
}
T 'dangling origin/HEAD (points at a missing branch): falls back to origin/main' {
  $w = New-World; [void](G $w.Lap @('config', 'remote.origin.followRemoteHEAD', 'never'))
  [void](G $w.Lap @('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/develop')); Push-Up $w @{ 'b.txt' = "two`n" }
  $r = Run-Sync $w.Lap
  Ok ($r.Text.Contains('main: đã cập nhật 1 commit')) "message: $($r.Text)"
}
T 'a local branch named origin/<default> exists: the default branch is still read from origin/HEAD' {
  $w = New-World 'develop'
  [void](G $w.Lap @('branch', 'origin/develop')); Push-Up $w @{ 'b.txt' = "two`n" }
  Eq (G $w.Lap @('symbolic-ref', '--short', 'refs/remotes/origin/HEAD')) 'remotes/origin/develop' 'git prints the long form here'
  $r = Run-Sync $w.Lap
  Ok ($r.Text.Contains('develop: đã cập nhật 1 commit')) "message: $($r.Text)"
  Eq (Head $w) (G $w.Lap @('rev-parse', 'refs/remotes/origin/develop')) 'HEAD at origin/develop'
}
T 'no default branch found: skipped with a clear message' {
  $w = New-World 'trunk'; No-Head $w; Push-Up $w @{ 'b.txt' = "two`n" }
  $h0 = Head $w
  $r = Run-Sync $w.Lap
  Ok ($r.Text.Contains('bỏ qua: không tìm thấy nhánh mặc định của origin')) "message: $($r.Text)"
  Eq (Head $w) $h0 'HEAD unchanged'
  Ok ((Summary $r).StartsWith('1 project: 0 đã cập nhật, 0 đã mới nhất, 1 bỏ qua')) "summary: $(Summary $r)"
}
T 'on a box/feature branch: skipped, nothing changes' {
  $w = New-World; Push-Up $w @{ 'b.txt' = "two`n" }
  [void](G $w.Lap @('checkout', '-q', '-b', 'box/topic')); $h0 = Head $w
  $r = Run-Sync $w.Lap
  Ok ($r.Text.Contains('bỏ qua: đang ở nhánh box/topic (origin/main hơn main trên laptop 1 commit)')) "message: $($r.Text)"
  Eq (Head $w) $h0 'HEAD unchanged'
  Eq (G $w.Lap @('rev-parse', 'main')) (G $w.Seed @('rev-parse', 'HEAD~1')) 'local main not moved'
  Ok ((Summary $r).StartsWith('1 project: 0 đã cập nhật, 0 đã mới nhất, 1 bỏ qua')) "summary: $(Summary $r)"
}
T 'detached HEAD: skipped' {
  $w = New-World; Push-Up $w @{ 'b.txt' = "two`n" }
  [void](G $w.Lap @('checkout', '-q', '--detach')); $h0 = Head $w
  $r = Run-Sync $w.Lap
  Ok ($r.Text.Contains('bỏ qua: không ở nhánh nào (origin/main hơn main trên laptop 1 commit)')) "message: $($r.Text)"
  Eq (Head $w) $h0 'HEAD unchanged'
}
T 'default branch ahead of origin (and behind): skipped' {
  $w = New-World; Push-Up $w @{ 'b.txt' = "two`n" }
  Put $w.Lap 'mine.txt' "m`n"; [void](G $w.Lap @('add', '-A')); [void](G $w.Lap @('commit', '-q', '-m', 'local')); $h0 = Head $w
  $r = Run-Sync $w.Lap
  Ok ($r.Text.Contains('main trên laptop có commit chưa đẩy, bỏ qua')) "message: $($r.Text)"
  Eq (Head $w) $h0 'HEAD unchanged'
  Ok ((Summary $r).StartsWith('1 project: 0 đã cập nhật, 0 đã mới nhất, 1 bỏ qua')) "summary: $(Summary $r)"
}
T 'default branch ahead of origin, not behind: current, with the unpushed note' {
  $w = New-World
  Put $w.Lap 'mine.txt' "m`n"; [void](G $w.Lap @('add', '-A')); [void](G $w.Lap @('commit', '-q', '-m', 'local'))
  $r = Run-Sync $w.Lap
  Ok ($r.Text.Contains('main: đã mới nhất (1 commit chưa đẩy)')) "message: $($r.Text)"
}
T 'missing project folder: counted as an error (unchanged rule)' {
  $r = Run-Sync (Join-Path $Root 'does-not-exist')
  Eq $r.Code 1
  Ok ($r.Text.Contains('lỗi: không tìm thấy project')) "message: $($r.Text)"
}
T 'source: the default branch is not hard-coded in Invoke-Sync' {
  $fn = ($found | Where-Object { $_.Name -eq 'Invoke-Sync' }).Extent.Text
  Ok (-not $fn.Contains('refs/heads/main') -and -not $fn.Contains("'refs/remotes/origin/main'")) 'no hard-coded main refs'
  Ok (-not $fn.Contains('có thay đổi chưa lưu')) 'dirty is no longer a skip reason'
}

Set-Location $env:TEMP
foreach ($k in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $savedEnv[$k]) }
Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "fcode-sync.test.ps1: passed $script:pass, failed $script:fail"
if ($script:fail) { exit 1 }
exit 0
