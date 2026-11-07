# Tests for the box step of laptop/install.ps1 (the "Kiểm tra kết nối tới box" check and its summary row).
# Run:  pwsh -NoProfile -File test/fcode-install.test.ps1
# install.ps1 runs in Windows PowerShell (powershell.exe) in a dry run with a temp USERPROFILE / LOCALAPPDATA, a throwaway HKCU PATH key and a fake ssh
# (FCODE_INSTALL_SSH): no real ssh, nothing installed, no key read. Everything lives in a temp folder that is removed at the end.
#   FCODE_TEST_ONLY=<regex>   run only the tests whose name matches
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$Repo = Split-Path -Parent $PSScriptRoot
$Install = Join-Path $Repo 'laptop\install.ps1'
$Root = Join-Path ([IO.Path]::GetTempPath()) ('fcode-install-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $Root)
Set-Location -LiteralPath $Root
$script:pass = 0; $script:fail = 0
$utf8 = New-Object Text.UTF8Encoding($false)
$envKey = 'Software\FcodeInstallTest-' + [guid]::NewGuid().ToString('N')

function T([string]$Name, [scriptblock]$Body) {
  if ($env:FCODE_TEST_ONLY -and $Name -notmatch $env:FCODE_TEST_ONLY) { return }
  try { & $Body; $script:pass++; Write-Host "PASS $Name" }
  catch { $script:fail++; Write-Host "FAIL $Name :: $($_.Exception.Message)" }
}
function Eq($Got, $Want, [string]$What = '') { if ("$Got" -cne "$Want") { throw "$What expected [$Want] got [$Got]" } }
function Ok([bool]$c, [string]$What) { if (-not $c) { throw $What } }

# a fake ssh: logs its arguments, prints FAKE_SSH_ERR on stderr, exits FAKE_SSH_EXIT
$n = 0
function New-World {
  $script:n++; $d = Join-Path $Root "w$script:n"; [void](New-Item -ItemType Directory -Path (Join-Path $d 'AppData\Local') -Force)
  $ssh = Join-Path $d 'ssh.cmd'; $log = Join-Path $d 'ssh.log'
  [IO.File]::WriteAllText($ssh, "@echo off`r`necho %*>>`"$log`"`r`nif defined FAKE_SSH_ERR echo %FAKE_SSH_ERR% 1>&2`r`nexit /b %FAKE_SSH_EXIT%`r`n")
  [pscustomobject]@{ U = $d; Ssh = $ssh; Log = $log }
}
function Invoke-Install($w, [hashtable]$Env = @{}) {
  $ErrorActionPreference = 'Continue'
  $set = @{ USERPROFILE = $w.U; LOCALAPPDATA = (Join-Path $w.U 'AppData\Local'); FCODE_INSTALL_SOURCE = (Join-Path $Repo 'laptop'); FCODE_INSTALL_DRYRUN = '1'; FCODE_INSTALL_ENVKEY = $envKey
    FCODE_INSTALL_EPFAKE = 'CurrentUser=RemoteSigned'; FCODE_INSTALL_SSH = $w.Ssh; FAKE_SSH_EXIT = '0'; FCODE_HOST = $null }
  foreach ($k in $Env.Keys) { $set[$k] = $Env[$k] }
  $save = @{}
  foreach ($k in $set.Keys) { $save[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $set[$k]) }
  try { $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Install 2>&1 | Out-String; [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out } }
  finally { foreach ($k in $save.Keys) { [Environment]::SetEnvironmentVariable($k, $save[$k]) } }
}
function SshLog($w) { if (Test-Path $w.Log) { @(Get-Content $w.Log) } else { @() } }

T 'box: a reachable box gives a checkmark row and the check is `ssh -o BatchMode=yes -o ConnectTimeout=8 <host> true`' {
  $w = New-World
  $r = Invoke-Install $w
  Ok ($r.Out -match "Vào được box 'oracle'") $r.Out
  Ok ($r.Out -match '(?m)^✓ Kết nối tới box\s*$') ('summary row: ' + $r.Out)
  Eq ((SshLog $w) -join '|') '-o BatchMode=yes -o ConnectTimeout=8 oracle true'
}
T 'box: an unreachable box gives a failing row that names the Host block, the key and the first ssh, shows the ssh error, exit 1' {
  $w = New-World
  $r = Invoke-Install $w @{ FAKE_SSH_EXIT = '255'; FAKE_SSH_ERR = 'oracle: Permission denied (publickey).' }
  Eq $r.Code 1 $r.Out
  Ok ($r.Out -match "✗ Không vào được box 'oracle'") $r.Out
  Ok ($r.Out -match 'Permission denied \(publickey\)') ('the ssh error is shown: ' + $r.Out)
  Ok ($r.Out -match '(?m)^✗ Kết nối tới box: chưa vào được box ''oracle''.*Host oracle.*HostName fcode-quoc\.duckdns\.org.*User quoc.*IdentityFile.*ssh oracle một lần') ('summary row: ' + $r.Out)
  Ok ($r.Out -match [regex]::Escape((Join-Path $w.U '.ssh\config'))) 'it names the config file'
}
T 'box: the host comes from config.json host, FCODE_HOST wins' {
  $w = New-World
  [void](New-Item -ItemType Directory -Path (Join-Path $w.U '.fcode') -Force)
  [IO.File]::WriteAllText((Join-Path $w.U '.fcode\config.json'), '{"host":"oracle-ubuntu","syncRepos":[]}', $utf8)
  $r = Invoke-Install $w
  Eq ((SshLog $w) -join '|') '-o BatchMode=yes -o ConnectTimeout=8 oracle-ubuntu true' 'config host'
  Remove-Item $w.Log
  $r = Invoke-Install $w @{ FCODE_HOST = 'other-alias' }
  Eq ((SshLog $w) -join '|') '-o BatchMode=yes -o ConnectTimeout=8 other-alias true' 'FCODE_HOST wins'
}
T 'box: a host that ssh would read as an option is refused with no ssh call' {
  $w = New-World
  $r = Invoke-Install $w @{ FCODE_HOST = '-oProxyCommand=calc.exe' }
  Eq (SshLog $w).Count 0 'no ssh'
  Ok ($r.Out -match '(?m)^✗ Kết nối tới box: tên box .*không hợp lệ') $r.Out
}
T 'box: a dry run without the test hook only prints the check and runs no ssh' {
  $w = New-World
  $r = Invoke-Install $w @{ FCODE_INSTALL_SSH = $null }
  Ok ($r.Out -match '\[chạy thử\] ssh -o BatchMode=yes -o ConnectTimeout=8 oracle true') $r.Out
  Eq (SshLog $w).Count 0 'the fake ssh was not used'
}

try { Remove-Item -LiteralPath "HKCU:\$envKey" -Recurse -ErrorAction SilentlyContinue } catch { }
Set-Location $env:TEMP
Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "passed $script:pass, failed $script:fail"
exit $(if ($script:fail) { 1 } else { 0 })