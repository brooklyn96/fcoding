# Tests for `fcode deploy` (laptop/fcode.ps1): pass-through to the VPS deploy gate, `add`, the `trust on` warning.
# Run:  pwsh -NoProfile -File test/fcode-deploy.test.ps1     (also works with: powershell -NoProfile -File ...)
# No network, no real ssh / gh: the functions are loaded out of fcode.ps1 and run in this process against function fakes of `ssh`, `gh`
# and `Read-SyncLine` (a function beats an executable of the same name); a few end-to-end runs start the real fcode.ps1 in a child process
# with ssh.cmd / gh.cmd stubs first on PATH and a temp USERPROFILE. Everything lives in a temp folder that is removed at the end.
#   FCODE_TEST_ONLY=<regex>   run only the tests whose name matches
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$Repo = Split-Path -Parent $PSScriptRoot
$Fcode = Join-Path $Repo 'laptop\fcode.ps1'
$Root = Join-Path ([IO.Path]::GetTempPath()) ('fcode-deploy-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $Root)
Set-Location -LiteralPath $Root
$script:pass = 0; $script:fail = 0
$utf8 = New-Object Text.UTF8Encoding($false)
$SEP = [string][char]1   # joins the argument list of a fake ssh / gh call

function T([string]$Name, [scriptblock]$Body) {
  if ($env:FCODE_TEST_ONLY -and $Name -notmatch $env:FCODE_TEST_ONLY) { return }
  try { & $Body; $script:pass++; Write-Host "PASS $Name" }
  catch { $script:fail++; Write-Host "FAIL $Name :: $($_.Exception.Message)" }
}
function Eq($Got, $Want, [string]$What = '') { if ("$Got" -cne "$Want") { throw "$What expected [$Want] got [$Got]" } }
function Ok([bool]$c, [string]$What) { if (-not $c) { throw $What } }

# --- load the deploy functions out of fcode.ps1 without running the script ---
$tokens = $null; $errs = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Fcode, [ref]$tokens, [ref]$errs)
if ($errs.Count) { throw "fcode.ps1 does not parse: $($errs[0].Message)" }
$wanted = 'Get-DeployHost', 'Test-DeployWord', 'Test-DeployName', 'Test-DeployRepo', 'Invoke-DeploySsh', 'Invoke-DeployGate', 'Read-DeployDraft', 'Test-DeployRunsIdle', 'Confirm-DeployRegister', 'Confirm-DeployKey', 'Invoke-DeployAdd', 'Invoke-Deploy', 'Write-IpaError'
$found = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true))
if ($found.Count -ne $wanted.Count) { throw "fcode.ps1 lacks some of: $($wanted -join ', ')" }
foreach ($fn in $found) { . ([scriptblock]::Create($fn.Extent.Text)) }

# --- fakes: config, prompt, ssh, gh ---
$script:CfgVals = @{}
function Get-Cfg([string]$Key, $Default) { if ($script:CfgVals.ContainsKey($Key) -and "$($script:CfgVals[$Key])" -ne '') { $script:CfgVals[$Key] } else { $Default } }
$script:Answers = New-Object Collections.Queue
function Read-SyncLine([string]$Prompt) { Write-Host '<<PROMPT>>'; if ($script:Answers.Count) { $script:Answers.Dequeue() } else { $null } }
$script:Calls = New-Object Collections.ArrayList
$script:Rules = New-Object Collections.ArrayList
# rule = tool + regex on the joined argument text (ssh: the remote command); Seq = answers in call order (the last one repeats)
function Add-Rule([string]$Tool, [string]$Rx, [object[]]$Seq) { [void]$script:Rules.Insert(0, [pscustomobject]@{ Tool = $Tool; Rx = $Rx; Seq = @($Seq); N = 0 }) }
function Ans([string[]]$Out, [int]$Code = 0) { @{ Out = $Out; Code = $Code } }
function Use-Fake([string]$Tool, [string]$Text, [string]$Stdin = '', [string]$KeyText = $null) {
  [void]$script:Calls.Add([pscustomobject]@{ Tool = $Tool; Text = $Text; Stdin = $Stdin; KeyText = $KeyText })
  $rule = $script:Rules | Where-Object { $_.Tool -eq $Tool -and $Text -match $_.Rx } | Select-Object -First 1
  if (-not $rule) { throw "no fake rule for: $Tool $Text" }
  $a = $rule.Seq[[Math]::Min($rule.N, $rule.Seq.Count - 1)]; $rule.N++
  $global:LASTEXITCODE = $a.Code
  $a.Out
}
function ssh {
  $in = (@($input) -join "`n"); $t = (@($args | ForEach-Object { [string]$_ }) -join "$SEP")
  Write-Host ('<<ssh ' + $args[-1] + '>>')
  $r = Use-Fake 'ssh' $t $in
  $r
}
function gh {
  $t = (@($args | ForEach-Object { [string]$_ }) -join ' ')
  $kt = $null
  if ($t -match '^repo deploy-key add (\S+) ') { $f = $Matches[1]; $kt = if (Test-Path -LiteralPath $f) { [IO.File]::ReadAllText($f) } else { '<missing>' }; $script:KeyFile = $f }
  Write-Host "<<gh $t>>"
  Use-Fake 'gh' $t '' $kt
}
function Reset-World { $script:Calls.Clear(); $script:Rules.Clear(); $script:Answers.Clear(); $script:CfgVals = @{}; $script:KeyFile = $null }

$GATE = '/usr/local/sbin/fcode-deploy-gate --local'
$SHA = '0123456789abcdef0123456789abcdef01234567'
$PUB = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEKEYFORTHETESTSONLY'
function Run-Fcode([string[]]$Words) {   # fcode deploy <Words>: @{ Code; Text; Calls }
  $script:Rest = @('deploy') + $Words
  $script:Calls.Clear()
  $all = @(& { Invoke-Deploy } 6>&1)
  $code = @($all | Where-Object { $_ -isnot [Management.Automation.InformationRecord] })
  $text = @($all | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" })
  if ($code.Count -ne 1) { throw "Invoke-Deploy returned $($code.Count) values: $($code -join ',')" }
  @{ Code = [int]$code[0]; Text = ($text -join "`n"); Calls = @($script:Calls) }
}

# a draft file with a sentinel (a "secret" that must never reach an argument list)
$Draft = Join-Path $Root 'task.draft.json'
$DraftBytes = $utf8.GetBytes('{"draft_version":1,"registry":{"name":"task","repo":"brooklyn96/task","branch":"main","note":"SECRET-SENTINEL-9f3"},"deployed_sha":null,"legacy_config":null,"drop":[],"guard_files":{},"stop_units":false}')
[IO.File]::WriteAllBytes($Draft, $DraftBytes)
$DraftSha = ([BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($DraftBytes)) -replace '-', '').ToLowerInvariant()
$DraftB64 = [Convert]::ToBase64String($DraftBytes)
function Bytes-Eq([byte[]]$A, [byte[]]$B) { $A.Length -eq $B.Length -and [Convert]::ToBase64String($A) -ceq [Convert]::ToBase64String($B) }

# ============================== pass-through ==============================
T 'pass-through: every gate verb goes to ssh <host> unchanged; one call, ssh -n, output streamed in order, exit code = ssh code' {
  $table = @(
    @{ W = @('task', 'status'); R = "$GATE task status" }
    @{ W = @('task', 'status', '3f2a9c1e-0000-4000-8000-000000000001'); R = "$GATE task status 3f2a9c1e-0000-4000-8000-000000000001" }
    @{ W = @('task', 'deploy', $SHA); R = "$GATE task deploy $SHA" }
    @{ W = @('task', 'deploy', 'abc1234'); R = "$GATE task deploy abc1234" }
    @{ W = @('task', 'retry'); R = "$GATE task retry" }
    @{ W = @('task', 'retry', $SHA); R = "$GATE task retry $SHA" }
    @{ W = @('task', 'pause'); R = "$GATE task pause" }
    @{ W = @('task', 'resume'); R = "$GATE task resume" }
    @{ W = @('task', 'trust', 'off'); R = "$GATE task trust off" }
    @{ W = @('task', 'logs'); R = "$GATE task logs" }
    @{ W = @('task', 'logs', '3f2a9c1e-0000-4000-8000-000000000001', '50'); R = "$GATE task logs 3f2a9c1e-0000-4000-8000-000000000001 50" }
    @{ W = @('task', 'recheck'); R = "$GATE task recheck" }
    @{ W = @('task', 'compact'); R = "$GATE task compact" }
    @{ W = @('shopee-dashboard', 'status'); R = "$GATE shopee-dashboard status" }
    @{ W = @('a-b-1', 'resume'); R = "$GATE a-b-1 resume" }
    @{ W = @('ab', 'status'); R = "$GATE ab status" }
    @{ W = @(('a' * 28), 'status'); R = "$GATE $('a' * 28) status" }
  )
  foreach ($c in $table) {
    Reset-World; Add-Rule 'ssh' '.' @(Ans @('LINE one', 'LINE two', 'GATE_EXIT 0') 0)
    $r = Run-Fcode $c.W
    Eq $r.Code 0 ($c.R + ' code'); Eq $r.Calls.Count 1 ($c.R + ' calls')
    $parts = $r.Calls[0].Text -split "$SEP"
    Eq $parts.Count 3 'ssh argv: -n host command'; Eq $parts[0] '-n'; Eq $parts[1] 'contabo'; Eq $parts[2] $c.R 'remote command'
    Eq $r.Calls[0].Stdin '' 'no stdin'
    $i1 = $r.Text.IndexOf('LINE one'); $i2 = $r.Text.IndexOf('LINE two'); $i3 = $r.Text.IndexOf('GATE_EXIT 0')
    Ok ($i1 -ge 0 -and $i2 -gt $i1 -and $i3 -gt $i2) ('output streamed in order: ' + $r.Text)
  }
}
T 'pass-through: the exit code of the gate comes back unchanged (0 1 65 69 70 255 and an odd one)' {
  foreach ($rc in 0, 1, 65, 69, 70, 255, 3) {
    Reset-World; Add-Rule 'ssh' '.' @(Ans @('GATE_EXIT ' + $rc) $rc)
    $r = Run-Fcode @('task', 'deploy', $SHA)
    Eq $r.Code $rc "rc $rc"
    if ($rc -eq 255) { Ok ($r.Text -match 'ssh contabo') '255 names the ssh host' } else { Ok ($r.Text -notmatch 'không nối được') "no ssh hint at $rc" }
  }
}
T 'pass-through: the ssh host is deployHost from the config (default contabo); an unsafe host is refused without any call' {
  Reset-World; $script:CfgVals['deployHost'] = 'vps-two'; Add-Rule 'ssh' '.' @(Ans @('ok') 0)
  $r = Run-Fcode @('task', 'status'); Eq (($r.Calls[0].Text -split "$SEP")[1]) 'vps-two' 'host from config'
  foreach ($bad in '-oProxyCommand=x', 'a b', 'h;id', 'x$(id)', '') {
    Reset-World; $script:CfgVals['deployHost'] = $bad; Add-Rule 'ssh' '.' @(Ans @('ok') 0)
    if ($bad -eq '') { $r = Run-Fcode @('task', 'status'); Eq (($r.Calls[0].Text -split "$SEP")[1]) 'contabo' 'empty = default'; continue }
    $r = Run-Fcode @('task', 'status'); Eq $r.Code 1 "[$bad] code"; Eq $r.Calls.Count 0 "[$bad] no call"
  }
}
T 'name rule (contract C1): 2..28 chars, letter first, letters/digits/-, no trailing -' {
  foreach ($n in 'ab', 'a1', 'a-b', 'ab-c', ('a' * 28), ('a' * 27 + '1')) { Ok (Test-DeployName $n) "accepted: $n" }
  foreach ($n in 'a', '', 'ab-', 'a-', ('a' * 27 + '-'), ('a' * 29), '1ab', '-ab', 'aB', 'a_b', 'a.b') { Ok (-not (Test-DeployName $n)) "refused: $n" }
}
T 'refusals: bad name, unknown verb or an unsafe word never reach ssh (rc 65)' {
  $bad = @(
    @(), @('task'), @('task', 'rm'), @('task', 'STATUS'), @('task', 'status;id'), @('Task', 'status'), @('-x', 'status'), @('a b', 'status'), @('task;id', 'status'), @('', 'status'),
    @('task', 'deploy', 'abc;rm -rf /'), @('task', 'deploy', '$(id)'), @('task', 'deploy', 'a b'), @('task', 'deploy', 'a`b'), @('task', 'deploy', "a`nb"), @('task', 'logs', '-n'),
    @('task', 'deploy', ('a' * 201)), @('task', 'deploy', 'x|y'), @('task', 'deploy', 'x&y'), @('task', 'deploy', "x'y"), @('task', 'deploy', 'x"y'), @('task', 'deploy', 'x>y'),
    @('task', 'add'), @('task', 'trust', 'on', 'i understand'),
    @('a.b_c-1', 'status'), @('a', 'status'), @('ab-', 'status'), @(('a' * 27 + '-'), 'status'), @('1abc', 'status'), @('-abc', 'status'), @('my.proj', 'status'), @('my_proj', 'status'), @(('a' * 29), 'status'), @(('a' * 64), 'status')
  )
  foreach ($w in $bad) {
    Reset-World; Add-Rule 'ssh' '.' @(Ans @('ok') 0)
    $r = Run-Fcode $w
    Eq $r.Code 65 ('[' + ($w -join '|') + '] code'); Eq $r.Calls.Count 0 ('[' + ($w -join '|') + '] no call')
  }
}
T 'refusals: `fcode deploy add` with the wrong arguments is refused before any call' {
  foreach ($w in @(@('add'), @('add', 'brooklyn96/task'), @('add', 'brooklyn96/task', 'task'), @('add', 'nope', 'task', $Draft), @('add', 'a/b', 'Task', $Draft), @('add', 'a/b/c', 'task', $Draft), @('add', '../b', 'task', $Draft), @('add', 'a/b', 'task', $Draft, 'extra'), @('add', 'brooklyn96/task', 'shopee_dashboard', $Draft), @('add', 'brooklyn96/task', 'a.b', $Draft), @('add', 'brooklyn96/task', '1abc', $Draft), @('add', 'brooklyn96/task', 'a', $Draft), @('add', 'brooklyn96/task', ('a' * 29), $Draft), @('add', 'brooklyn96/task', ('a' * 64), $Draft), @('add', 'brooklyn96/task', 'deal-sync', $Draft), @('add', 'brooklyn96/task', 'gate', $Draft), @('add', 'brooklyn96/task', 'legacy', $Draft))) {
    Reset-World; Add-Rule 'ssh' '.' @(Ans @('ok') 0); Add-Rule 'gh' '.' @(Ans @('[]') 0)
    $r = Run-Fcode $w; Eq $r.Code 65 ('[' + ($w -join '|') + '] code'); Eq $r.Calls.Count 0 'no call'
  }
}

T 'refusals: `fcode deploy add o/r ab-` (draft says the same name) is refused by the name rule before any gh or ssh call' {
  $f = Join-Path $Root 'trail.json'; [IO.File]::WriteAllBytes($f, $utf8.GetBytes('{"draft_version":1,"registry":{"name":"ab-","repo":"o/r"}}'))
  Reset-World; Add-Rule 'ssh' '.' @(Ans @('ok') 0); Add-Rule 'gh' '.' @(Ans @('[]') 0)
  $r = Run-Fcode @('add', 'o/r', 'ab-', $f); Eq $r.Code 65 'code'; Eq $r.Calls.Count 0 'no call'
}

# ============================== trust ==============================
function Expected-Warning([string]$Repo, [string]$Branch) {
  "Trusted mode: anyone who can merge to $Repo $Branch gets root on the VPS (compose controls the root docker daemon; script runs as root) and can read the gate's GitHub token, which can post statuses and issues on every brooklyn96 repository."
}
T 'trust on i-understand-root: prints the decision text verbatim (repo and branch from status) BEFORE the trust call; then sends it unchanged' {
  Reset-World
  Add-Rule 'ssh' '.' @(Ans @('GATE_EXIT 0') 0)
  Add-Rule 'ssh' '--local task status' @(Ans @('DEPLOY_RUNNING no', 'PROJECT task shape=release trusted=no branch=main repo=brooklyn96/task', 'GATE_EXIT 0') 0)
  $r = Run-Fcode @('task', 'trust', 'on', 'i-understand-root')
  Eq $r.Code 0 'code'; Eq $r.Calls.Count 2 'status then trust'
  Eq (($r.Calls[0].Text -split "$SEP")[2]) "$GATE task status" 'first call = status'
  Eq (($r.Calls[1].Text -split "$SEP")[2]) "$GATE task trust on i-understand-root" 'second call = trust, unchanged'
  $w = Expected-Warning 'brooklyn96/task' 'main'
  $iw = $r.Text.IndexOf($w); $it = $r.Text.IndexOf("<<ssh $GATE task trust on i-understand-root>>")
  Ok ($iw -ge 0) ('the warning text is missing or changed: ' + $r.Text); Ok ($it -gt $iw) 'the warning comes before the trust call'
  Ok ($r.Text -notmatch 'PROJECT task shape') 'the status lines are not shown'
  Ok ($w -match "can read the gate's GitHub token, which can post statuses and issues on every brooklyn96 repository") 'names the single-PAT exposure'
}
T 'trust on: another repo and branch are named in the warning (taken from the PROJECT line in either field order)' {
  Reset-World
  Add-Rule 'ssh' '.' @(Ans @('GATE_EXIT 0') 0)
  Add-Rule 'ssh' '--local vps-tracker status' @(Ans @('PROJECT vps-tracker repo=brooklyn96/VPS-Tracker shape=release trusted=no branch=master') 0)
  $r = Run-Fcode @('vps-tracker', 'trust', 'on', 'i-understand-root')
  Ok ($r.Text.Contains((Expected-Warning 'brooklyn96/VPS-Tracker' 'master'))) ('warning: ' + $r.Text)
}
T 'trust on: status without a PROJECT line (unknown project, ssh down) = refused, nothing is trusted, warning not shown' {
  foreach ($case in @(@('GATE_ERROR unknown project', 65), @('x', 0), @('x', 255))) {
    Reset-World
    Add-Rule 'ssh' '.' @(Ans @('GATE_EXIT 0') 0)
    Add-Rule 'ssh' '--local task status' @(Ans @($case[0]) $case[1])
    $r = Run-Fcode @('task', 'trust', 'on', 'i-understand-root')
    Ok ($r.Code -ne 0) "code $($case[1]) not 0"; Eq $r.Calls.Count 1 'only the status call'
    Ok ($r.Text -notmatch 'Trusted mode') 'no warning'
  }
}
T 'trust off and a wrong or missing confirmation word: one unchanged call, no warning (the gate answers 65 itself)' {
  foreach ($w in @(@('task', 'trust', 'off'), @('task', 'trust', 'on'), @('task', 'trust', 'on', 'yes'), @('task', 'trust', 'on', 'I-UNDERSTAND-ROOT'), @('task', 'trust'))) {
    Reset-World; Add-Rule 'ssh' '.' @(Ans @('GATE_ERROR confirmation word needed') 65)
    $r = Run-Fcode $w
    Eq $r.Calls.Count 1 ($w -join ' '); Eq (($r.Calls[0].Text -split "$SEP")[2]) ("$GATE " + ($w -join ' ')) 'unchanged'
    Ok ($r.Text -notmatch 'Trusted mode') 'no warning'
  }
}

# ============================== inventory / register with a draft file ==============================
T 'inventory and register by hand: the draft file goes to the gate as base64 on stdin (exact bytes), never in the arguments' {
  Reset-World; Add-Rule 'ssh' '.' @(Ans @('INV ok') 0)
  $r = Run-Fcode @('task', 'inventory', $Draft)
  Eq $r.Code 0; Eq $r.Calls.Count 1
  Eq (($r.Calls[0].Text -split "$SEP")[-1]) "base64 -di | $GATE task inventory" 'remote'
  Eq (($r.Calls[0].Text -split "$SEP").Count) 2 'with stdin: ssh <host> <command>, no -n'
  Ok (Bytes-Eq ([Convert]::FromBase64String($r.Calls[0].Stdin)) $DraftBytes) 'stdin decodes to the file bytes'
  Ok ($r.Calls[0].Text -notmatch 'SECRET-SENTINEL' -and $r.Calls[0].Text -notmatch [regex]::Escape($DraftB64)) 'no secret in argv'
  Add-Rule 'gh' 'run list' @(Ans @('[]') 0); $script:Answers.Enqueue('YES')
  $r = Run-Fcode @('task', 'register', $DraftSha, $Draft)
  $reg = @($r.Calls | Where-Object { $_.Tool -eq 'ssh' })
  Eq $reg.Count 1 'one ssh call'
  Eq (($reg[0].Text -split "$SEP")[-1]) "base64 -di | $GATE task register $DraftSha" 'register remote'
  Ok (Bytes-Eq ([Convert]::FromBase64String($reg[0].Stdin)) $DraftBytes) 'register stdin'
}
T 'inventory and register by hand: wrong argument count, missing, empty, oversized or non-JSON draft = rc 65, no call; a BOM is dropped and the sha covers the sent bytes' {
  Reset-World; Add-Rule 'ssh' '.' @(Ans @('ok') 0)
  $big = Join-Path $Root 'big.json'; [IO.File]::WriteAllBytes($big, $utf8.GetBytes('{"a":"' + ('x' * 17000) + '"}'))
  $nj = Join-Path $Root 'nj.json'; [IO.File]::WriteAllBytes($nj, $utf8.GetBytes('not json'))
  $em = Join-Path $Root 'empty.json'; [IO.File]::WriteAllBytes($em, [byte[]]@())
  foreach ($w in @(@('task', 'inventory'), @('task', 'inventory', $Draft, $Draft), @('task', 'register', $Draft), @('task', 'register', $SHA), @('task', 'inventory', (Join-Path $Root 'nope.json')), @('task', 'inventory', $big), @('task', 'inventory', $nj), @('task', 'inventory', $em), @('task', 'register', 'a b', $Draft))) {
    $r = Run-Fcode $w; Eq $r.Code 65 ('[' + ($w -join '|') + ']'); Eq $r.Calls.Count 0 'no call'
  }
  $bom = Join-Path $Root 'bom.json'; [IO.File]::WriteAllBytes($bom, ([byte[]](0xEF, 0xBB, 0xBF) + $DraftBytes))
  $r = Run-Fcode @('task', 'inventory', $bom); Eq $r.Code 0
  Ok (Bytes-Eq ([Convert]::FromBase64String($r.Calls[0].Stdin)) $DraftBytes) 'BOM dropped'
  $d = Read-DeployDraft $bom; Eq $d.Sha $DraftSha 'sha of the bytes that are sent'
}

# ============================== add ==============================
function Kind($c) {   # a short label per call
  $t = $c.Text
  if ($c.Tool -eq 'gh') {
    if ($t -match '^run list .*--status (\S+)') { return 'runs:' + $Matches[1] }
    if ($t -match '^repo deploy-key list') { return 'keylist' }
    if ($t -match '^repo deploy-key add') { return 'keyadd' }
    return "gh?$t"
  }
  $rem = ($t -split "$SEP")[-1]
  if ($rem -match 'KEY_NONE') { return 'probe' }
  if ($rem -match 'ssh-keygen -q') { return 'create' }
  if ($rem -match 'ALIAS_EXISTS') { return 'alias' }
  if ($rem -match ' --local \S+ (\S+)') { return $Matches[1] }
  "ssh?$rem"
}
function New-AddWorld {
  Reset-World
  Add-Rule 'gh' 'run list' @(Ans @('[]') 0)
  Add-Rule 'gh' 'deploy-key list' @(Ans @('[{"key":"' + $PUB + '","readOnly":true}]') 0)
  Add-Rule 'gh' 'deploy-key add' @(Ans @('') 0)
  Add-Rule 'ssh' '.' @(Ans @('?') 99)
  Add-Rule 'ssh' 'KEY_NONE' @(Ans @($PUB) 0)
  Add-Rule 'ssh' 'ssh-keygen -q' @(Ans @($PUB + ' fcode-deploy-task') 0)
  Add-Rule 'ssh' 'ALIAS_EXISTS' @(Ans @('ALIAS_EXISTS') 0)
  Add-Rule 'ssh' '--local task inventory' @(Ans @(('INV repo default_branch=main registry_branch=main ref=' + $SHA), 'INV ok') 0)
  Add-Rule 'ssh' '--local task register' @(Ans @('GATE_RESULT outcome=deployed', 'GATE_EXIT 0') 0)
  Add-Rule 'ssh' '--local task status' @(Ans @('PROJECT task shape=release trusted=no branch=main repo=brooklyn96/task', 'BLOCKED paths-busy attempt=x pid=7 comm=tail path=/opt/task', 'GATE_EXIT 70') 70)
  $script:Answers.Enqueue('YES')
}
function Add-Run([string[]]$W = @('add', 'brooklyn96/task', 'task', $Draft)) { Run-Fcode $W }
function Kinds($r) { (@($r.Calls | ForEach-Object { Kind $_ }) -join ' ') }

T 'add (existing key listed on GitHub): runs check, key reuse, alias, inventory, YES, runs check again, register with the draft sha256' {
  New-AddWorld
  $r = Add-Run
  Eq $r.Code 0 ('code: ' + $r.Text)
  Eq (Kinds $r) 'runs:in_progress runs:queued probe keylist alias inventory runs:in_progress runs:queued register'
  $inv = $r.Calls | Where-Object { (Kind $_) -eq 'inventory' }; $reg = $r.Calls | Where-Object { (Kind $_) -eq 'register' }
  Ok (Bytes-Eq ([Convert]::FromBase64String($inv.Stdin)) $DraftBytes) 'inventory stdin = draft bytes'
  Ok (Bytes-Eq ([Convert]::FromBase64String($reg.Stdin)) $DraftBytes) 'register stdin = draft bytes'
  Eq (($reg.Text -split "$SEP")[-1]) "base64 -di | $GATE task register $DraftSha" 'register carries the sha256 of the draft'
  Ok ($r.Text -match 'INV ok' -and $r.Text.Contains($DraftSha)) 'inventory shown, sha256 printed'
  Ok ($r.Text -match 'resume' -and $r.Text -match 'trust on i-understand-root') 'next steps named'
  $runs = @($r.Calls | Where-Object { $_.Tool -eq 'gh' -and $_.Text -match '^run list' })
  foreach ($x in $runs) { Ok ($x.Text -match '^run list -R brooklyn96/task --status (in_progress|queued) --json databaseId$') ('gh run list argv: ' + $x.Text) }
  $ps = $r.Text.IndexOf('<<PROMPT>>'); $ir = $r.Text.IndexOf('<<ssh base64 -di | /usr/local/sbin/fcode-deploy-gate --local task register')
  Ok ($ps -ge 0 -and $ir -gt $ps) 'the YES prompt comes before register'
}
T 'add: no secret in any argument; stdin only on inventory and register' {
  New-AddWorld; $r = Add-Run
  foreach ($c in $r.Calls) {
    Ok ($c.Text -notmatch 'SECRET-SENTINEL' -and -not $c.Text.Contains($DraftB64)) ('draft content in argv of ' + (Kind $c))
    if ((Kind $c) -notin 'inventory', 'register') { Eq $c.Stdin '' ((Kind $c) + ' has no stdin') }
  }
}
T 'add (no key yet): create without overwrite, then the read-only key goes to GitHub from a temp file that is removed; no --allow-write' {
  New-AddWorld
  Add-Rule 'ssh' 'KEY_NONE' @(Ans @('KEY_NONE') 0)
  $r = Add-Run
  Eq $r.Code 0 ('code: ' + $r.Text)
  Eq (Kinds $r) 'runs:in_progress runs:queued probe create keyadd alias inventory runs:in_progress runs:queued register'
  $cr = ($r.Calls | Where-Object { (Kind $_) -eq 'create' }); $rem = ($cr.Text -split "$SEP")[-1]
  Ok ($rem -match '\[ ! -e \$k \]' -and $rem -match '\[ ! -e \$k\.pub \]') 'create is guarded against an existing key or .pub'
  Ok ($rem -notmatch '\brm\b|-y -f') 'create never deletes'
  $ka = $r.Calls | Where-Object { (Kind $_) -eq 'keyadd' }
  Ok ($ka.Text -match '-R brooklyn96/task' -and $ka.Text -notmatch '--allow-write|-w\b') ('read-only: ' + $ka.Text)
  Eq $ka.KeyText ($PUB + "`n") 'the temp file held the public key (and only it)'
  Ok ($script:KeyFile -and -not (Test-Path -LiteralPath $script:KeyFile)) 'temp key file removed'
}
T 'add: the alias snippet adds github-<name> only when absent (append, backup, never rewrite)' {
  New-AddWorld; $r = Add-Run
  $rem = (($r.Calls | Where-Object { (Kind $_) -eq 'alias' }).Text -split "$SEP")[-1]
  Ok ($rem -match 'Host github-task' -and $rem -match 'IdentityFile ~/.ssh/task_deploy' -and $rem -match '>> \$c' -and $rem -match 'cp -a') 'appends with a backup'
  Ok ($rem -notmatch '[^>]> \$c|sed -i|\brm\b') 'no truncating write, no in-place edit'
}
T 'add: an existing key that is NOT in the repo deploy keys is refused (65, never overwritten): no alias, inventory, register' {
  New-AddWorld
  Add-Rule 'gh' 'deploy-key list' @(Ans @('[{"key":"ssh-ed25519 AAAAOTHERKEY"}]') 0)
  $r = Add-Run; Eq $r.Code 65
  Eq (Kinds $r) 'runs:in_progress runs:queued probe keylist'
  Ok ($r.Text -match 'KHÔNG nằm trong Deploy keys') 'says why'
}
T 'add: an existing key listed WITH write access (readOnly false, or the field missing) is refused (65, never reused): no alias, inventory, register' {
  foreach ($l in ('[{"key":"' + $PUB + '","readOnly":false}]'), ('[{"key":"' + $PUB + '","read_only":false}]'), ('[{"key":"' + $PUB + '"}]'), ('[{"key":"' + $PUB + ' comment","readOnly":"no"}]'), ('[{"key":"ssh-ed25519 AAAAOTHER","readOnly":true},{"key":"' + $PUB + '","readOnly":false}]')) {
    New-AddWorld; Add-Rule 'gh' 'deploy-key list' @(Ans @($l) 0)
    $r = Add-Run; Eq $r.Code 65 $l
    Eq (Kinds $r) 'runs:in_progress runs:queued probe keylist' $l
    Ok ($r.Text -match 'CÓ quyền ghi' -and $r.Text -match 'KHÔNG tích Allow write access') 'says why and how to fix'
    Eq $script:Answers.Count 1 'YES was never asked'
  }
  New-AddWorld; $r = Add-Run
  $kl = $r.Calls | Where-Object { (Kind $_) -eq 'keylist' }
  Ok ($kl.Text -match '--json key,readOnly$') ('the listing asks for readOnly: ' + $kl.Text)
  New-AddWorld; Add-Rule 'gh' 'deploy-key list' @(Ans @('[{"key":"ssh-ed25519 AAAAOTHER","readOnly":false},{"key":"' + $PUB + ' c","readOnly":true}]') 0)
  $r = Add-Run; Eq $r.Code 0 'a write-enabled OTHER key does not matter; the matching one is read-only'
}
T 'add: the real gh output shape (read_only true, with id/title/created_at) is accepted as read-only' {
  New-AddWorld; Add-Rule 'gh' 'deploy-key list' @(Ans @('[{"id":167812789,"key":"' + $PUB + ' c","title":"fcode-deploy-task","created_at":"2026-10-29T00:00:00Z","read_only":true}]') 0)
  $r = Add-Run; Eq $r.Code 0 'read_only:true is a read-only key'
}
T 'add: an unreadable existing key is refused (65); gh or ssh failing while reading keys = rc 1, nothing registered' {
  New-AddWorld; Add-Rule 'ssh' 'KEY_NONE' @(Ans @('KEY_UNREADABLE') 0)
  $r = Add-Run; Eq $r.Code 65; Eq (Kinds $r) 'runs:in_progress runs:queued probe'
  New-AddWorld; Add-Rule 'gh' 'deploy-key list' @(Ans @('boom') 1)
  $r = Add-Run; Eq $r.Code 1; Eq (Kinds $r) 'runs:in_progress runs:queued probe keylist'
  New-AddWorld; Add-Rule 'gh' 'deploy-key list' @(Ans @('not json') 0)
  $r = Add-Run; Eq $r.Code 1
  New-AddWorld; Add-Rule 'ssh' 'KEY_NONE' @(Ans @('x') 255)
  $r = Add-Run; Eq $r.Code 1; Eq (Kinds $r) 'runs:in_progress runs:queued probe'
  New-AddWorld; Add-Rule 'ssh' 'KEY_NONE' @(Ans @('KEY_NONE') 0); Add-Rule 'ssh' 'ssh-keygen -q' @(Ans @('') 1)
  $r = Add-Run; Eq $r.Code 1; Eq (Kinds $r) 'runs:in_progress runs:queued probe create'
  New-AddWorld; Add-Rule 'ssh' 'KEY_NONE' @(Ans @('KEY_NONE') 0); Add-Rule 'gh' 'deploy-key add' @(Ans @('HTTP 422') 1)
  $r = Add-Run; Eq $r.Code 1; Ok ($r.Text -match 'AAAAC3NzaC1lZDI1NTE5AAAAIFAKEKEY') 'prints the public key for a manual add'
  Ok ($script:KeyFile -and -not (Test-Path -LiteralPath $script:KeyFile)) 'temp key file removed on failure too'
  New-AddWorld; Add-Rule 'ssh' 'ALIAS_EXISTS' @(Ans @('x') 1)
  $r = Add-Run; Eq $r.Code 1; Ok ((Kinds $r) -notmatch 'inventory')
}
T 'add: runs in flight at the start (in_progress or queued) = refused 65 with NO ssh call at all' {
  foreach ($st in 'in_progress', 'queued') {
    New-AddWorld; Add-Rule 'gh' "run list .*--status $st" @(Ans @('[{"databaseId":5},{"databaseId":6}]') 0)
    $r = Add-Run; Eq $r.Code 65 $st
    Ok (@($r.Calls | Where-Object { $_.Tool -eq 'ssh' }).Count -eq 0) "no ssh when $st runs exist"
    Ok ($r.Text -match 'runs-in-flight' -and $r.Text -match '2 lượt') 'names the reason and the count'
    Eq $script:Answers.Count 1 'YES was never asked'
  }
}
T 'add: a run that starts while the person reads the inventory is caught right before register (65, no register)' {
  New-AddWorld; Add-Rule 'gh' 'run list .*--status in_progress' @((Ans @('[]') 0), (Ans @('[{"databaseId":9}]') 0))
  $r = Add-Run; Eq $r.Code 65
  Ok ((Kinds $r) -match 'inventory' -and (Kinds $r) -notmatch 'register') (Kinds $r)
  New-AddWorld; Add-Rule 'gh' 'run list .*--status queued' @((Ans @('[]') 0), (Ans @('[{"databaseId":9}]') 0))
  $r = Add-Run; Eq $r.Code 65; Ok ((Kinds $r) -notmatch 'register')
}
T 'add: gh unable to list runs = rc 1 (cannot verify, so nothing is registered), at the start and before register' {
  New-AddWorld; Add-Rule 'gh' 'run list' @(Ans @('HTTP 502') 1)
  $r = Add-Run; Eq $r.Code 1; Eq $r.Calls.Count 1
  New-AddWorld; Add-Rule 'gh' 'run list' @(Ans @('garbage') 0)
  $r = Add-Run; Eq $r.Code 1; Eq $r.Calls.Count 1
  New-AddWorld; Add-Rule 'gh' 'run list .*--status queued' @((Ans @('[]') 0), (Ans @('') 4))
  $r = Add-Run; Eq $r.Code 1; Ok ((Kinds $r) -notmatch 'register')
}
T 'add: only the exact word YES registers (anything else, empty, end of input = 65, no register, no second runs check)' {
  foreach ($a in 'yes', 'Y', 'y', 'YES!', 'no', '', '  ', 'YES YES', $null) {
    New-AddWorld; $script:Answers.Clear(); $script:Answers.Enqueue($a)
    $r = Add-Run; Eq $r.Code 65 "[$a]"
    Eq (Kinds $r) 'runs:in_progress runs:queued probe keylist alias inventory' "[$a]"
  }
  New-AddWorld; $script:Answers.Clear(); $script:Answers.Enqueue('  YES  ')
  $r = Add-Run; Eq $r.Code 0 'surrounding spaces are only trimmed'
}
T 'add: inventory refused (rc 65, or an INV refuse line with rc 0) or failing = no YES prompt, no register, the code is returned' {
  New-AddWorld; Add-Rule 'ssh' '--local task inventory' @(Ans @('INV refuse names-taken') 65)
  $r = Add-Run; Eq $r.Code 65; Eq $script:Answers.Count 1; Ok ((Kinds $r) -notmatch 'register')
  New-AddWorld; Add-Rule 'ssh' '--local task inventory' @(Ans @('INV refuse units-active') 0)
  $r = Add-Run; Eq $r.Code 65; Eq $script:Answers.Count 1; Ok ((Kinds $r) -notmatch 'register')
  New-AddWorld; Add-Rule 'ssh' '--local task inventory' @(Ans @('x') 70)
  $r = Add-Run; Eq $r.Code 70; Ok ((Kinds $r) -notmatch 'register')
}
T 'add: inventory must END with exactly `INV ok` (rc 0 but missing, truncated, not last, or empty = 65, no YES prompt, no register)' {
  foreach ($out in @('INV repo default_branch=main'), @(), @('INV ok', 'INV unit x'), @('INV okay'), @('INV ok extra'), @('inv ok'), @('INV refuse x', 'INV ok x')) {
    New-AddWorld; Add-Rule 'ssh' '--local task inventory' @(Ans $out 0)
    $r = Add-Run; Eq $r.Code 65 ('[' + ($out -join '|') + ']'); Eq $script:Answers.Count 1 'no prompt'; Ok ((Kinds $r) -notmatch 'register') (Kinds $r)
  }
  foreach ($out in @('INV unit x', 'INV ok', ''), @('INV ok', 'GATE_EXIT 0'), @('INV repo x', 'INV ok', 'GATE_EXIT 0', '')) {
    New-AddWorld; Add-Rule 'ssh' '--local task inventory' @(Ans $out 0)
    $r = Add-Run; Eq $r.Code 0 ('a trailing blank or GATE_EXIT line after INV ok is fine: [' + ($out -join '|') + '] ' + $r.Text)
  }
  foreach ($out in @('INV ok', 'INV refuse x', 'GATE_EXIT 65'), @('GATE_EXIT 0')) {   # the LAST INV line decides; a bare GATE_EXIT is no INV ok
    New-AddWorld; Add-Rule 'ssh' '--local task inventory' @(Ans $out 0)
    $r = Add-Run; Eq $r.Code 65 ('[' + ($out -join '|') + ']'); Eq $script:Answers.Count 1 'no prompt'
  }
}
T 'add: the draft registry.repo must equal <repo> (case-insensitive); a mismatch or a missing registry.repo = 65 before ANY call' {
  $mk = { param($body) $f = Join-Path $Root ('d' + [guid]::NewGuid().ToString('N') + '.json'); [IO.File]::WriteAllBytes($f, $utf8.GetBytes($body)); $f }
  foreach ($body in '{"draft_version":1,"registry":{"name":"task","repo":"brooklyn96/other"}}', '{"draft_version":1,"registry":{"name":"task","branch":"main"}}', '{"draft_version":1,"registry":{"name":"task"}}', '{"draft_version":1,"registry":{"name":"task","repo":["brooklyn96/task"]}}') {
    New-AddWorld; $f = & $mk $body
    $r = Add-Run @('add', 'brooklyn96/task', 'task', $f); Eq $r.Code 65 $body; Eq $r.Calls.Count 0 'no gh, no ssh'
  }
  New-AddWorld; $f = & $mk '{"draft_version":1,"registry":{"name":"task","repo":"Brooklyn96/TASK"}}'
  $r = Add-Run @('add', 'brooklyn96/task', 'task', $f); Eq $r.Code 0 ('case-insensitive: ' + $r.Text)
}
T 'add: the draft registry.name must equal <name> exactly (case-sensitive); a mismatch or a missing name = 65 before ANY call (no key, alias or deploy key is created)' {
  $mk = { param($body) $f = Join-Path $Root ('d' + [guid]::NewGuid().ToString('N') + '.json'); [IO.File]::WriteAllBytes($f, $utf8.GetBytes($body)); $f }
  foreach ($body in '{"draft_version":1,"registry":{"name":"vps-tracker","repo":"brooklyn96/task"}}', '{"draft_version":1,"registry":{"name":"Task","repo":"brooklyn96/task"}}', '{"draft_version":1,"registry":{"repo":"brooklyn96/task"}}', '{"draft_version":1,"registry":{"name":["task"],"repo":"brooklyn96/task"}}') {
    New-AddWorld; $f = & $mk $body
    $r = Add-Run @('add', 'brooklyn96/task', 'task', $f); Eq $r.Code 65 $body; Eq $r.Calls.Count 0 'no gh, no ssh'
    Ok ($r.Text -match 'registry\.name') 'says which field'
  }
}
T 'register by hand: same runs-in-flight check and typed YES as add (one shared function): runs before YES, YES, runs again, then register' {
  Reset-World; Add-Rule 'gh' 'run list' @(Ans @('[]') 0); Add-Rule 'ssh' '.' @(Ans @('GATE_EXIT 0') 0); $script:Answers.Enqueue('YES')
  $r = Run-Fcode @('task', 'register', $DraftSha, $Draft); Eq $r.Code 0 $r.Text
  Eq (Kinds $r) 'runs:in_progress runs:queued runs:in_progress runs:queued register'
  $ps = $r.Text.IndexOf('<<PROMPT>>'); Ok ($ps -ge 0 -and $r.Text.IndexOf('<<ssh base64 -di') -gt $ps) 'YES before register'
  Ok ($r.Text.Contains($DraftSha)) 'sha256 shown'
  foreach ($st in 'in_progress', 'queued') {
    Reset-World; Add-Rule 'gh' 'run list' @(Ans @('[]') 0); Add-Rule 'gh' "run list .*--status $st" @(Ans @('[{"databaseId":1}]') 0); Add-Rule 'ssh' '.' @(Ans @('x') 0); $script:Answers.Enqueue('YES')
    $r = Run-Fcode @('task', 'register', $DraftSha, $Draft); Eq $r.Code 65 "early $st"; Eq @($r.Calls | Where-Object { $_.Tool -eq 'ssh' }).Count 0 'no ssh'; Eq $script:Answers.Count 1 'YES never asked'
    Reset-World; Add-Rule 'gh' 'run list' @(Ans @('[]') 0); Add-Rule 'gh' "run list .*--status $st" @((Ans @('[]') 0), (Ans @('[{"databaseId":1}]') 0)); Add-Rule 'ssh' '.' @(Ans @('x') 0); $script:Answers.Enqueue('YES')
    $r = Run-Fcode @('task', 'register', $DraftSha, $Draft); Eq $r.Code 65 "late $st"; Eq @($r.Calls | Where-Object { $_.Tool -eq 'ssh' }).Count 0 'no register after the late check'
  }
  foreach ($a in 'yes', '', $null) {
    Reset-World; Add-Rule 'gh' 'run list' @(Ans @('[]') 0); Add-Rule 'ssh' '.' @(Ans @('x') 0); $script:Answers.Enqueue($a)
    $r = Run-Fcode @('task', 'register', $DraftSha, $Draft); Eq $r.Code 65 "[$a]"; Eq @($r.Calls | Where-Object { $_.Tool -eq 'ssh' }).Count 0 'no ssh without the exact YES'
  }
  Reset-World; Add-Rule 'gh' 'run list' @(Ans @('boom') 1); Add-Rule 'ssh' '.' @(Ans @('x') 0); $script:Answers.Enqueue('YES')
  $r = Run-Fcode @('task', 'register', $DraftSha, $Draft); Eq $r.Code 1 'gh cannot list runs'; Eq @($r.Calls | Where-Object { $_.Tool -eq 'ssh' }).Count 0
}
T 'register by hand: a typed sha256 that differs from the sha256 of the draft file = 65 before any call (never shown as the draft sha); the YES prompt shows the real sha' {
  $old = 'f' * 64
  foreach ($w in $old, $DraftSha.ToUpperInvariant(), $DraftSha.Substring(0, 63)) {
    Reset-World; Add-Rule 'gh' 'run list' @(Ans @('[]') 0); Add-Rule 'ssh' '.' @(Ans @('GATE_EXIT 0') 0); $script:Answers.Enqueue('YES')
    $r = Run-Fcode @('task', 'register', $w, $Draft); Eq $r.Code 65 $w; Eq $r.Calls.Count 0 'no gh, no ssh'; Eq $script:Answers.Count 1 'YES never asked'
    Ok ($r.Text.Contains($DraftSha) -and $r.Text.Contains($w)) 'both shas named'; Ok ($r.Text -notmatch '<<PROMPT>>') 'no prompt'
  }
  Reset-World; Add-Rule 'gh' 'run list' @(Ans @('[]') 0); Add-Rule 'ssh' '.' @(Ans @('GATE_EXIT 0') 0); $script:Answers.Enqueue('YES')
  $r = Run-Fcode @('task', 'register', $DraftSha, $Draft); Eq $r.Code 0 $r.Text; Ok ($r.Text -match ('sha256 của bản nháp: ' + $DraftSha)) 'the prompt shows the draft sha'
}
T 'register by hand: a bad sha word or a draft without a usable registry.repo = 65, no call at all' {
  $nr = Join-Path $Root 'norepo.json'; [IO.File]::WriteAllBytes($nr, $utf8.GetBytes('{"draft_version":1}'))
  foreach ($w in @(@('task', 'register', 'a b', $Draft), @('task', 'register', 'x;id', $Draft), @('task', 'register', $DraftSha, $nr))) {
    Reset-World; Add-Rule 'gh' 'run list' @(Ans @('[]') 0); Add-Rule 'ssh' '.' @(Ans @('x') 0); $script:Answers.Enqueue('YES')
    $r = Run-Fcode $w; Eq $r.Code 65 ($w -join '|'); Eq $r.Calls.Count 0 'no call'
  }
}
T 'add: register rc 70 (needs_human) = exit 70, status printed, recheck hint shown' {
  New-AddWorld; Add-Rule 'ssh' '--local task register' @(Ans @('GATE_RESULT outcome=needs_human reason=paths-busy', 'GATE_EXIT 70') 70)
  $r = Add-Run
  Eq $r.Code 70
  Ok ((Kinds $r) -match 'register status$') ('status follows register: ' + (Kinds $r))
  Ok ($r.Text -match 'BLOCKED paths-busy') 'status lines shown'
  Ok ($r.Text -match 'fcode deploy task recheck') 'recheck hint'
  Ok ($r.Text.IndexOf('fcode deploy task recheck') -gt $r.Text.IndexOf('BLOCKED paths-busy')) 'hint after the status'
}
T 'add: other register codes are returned as they are, without a status call' {
  foreach ($rc in 1, 65, 255) {
    New-AddWorld; Add-Rule 'ssh' '--local task register' @(Ans @('GATE_ERROR x') $rc)
    $r = Add-Run; Eq $r.Code $rc "rc $rc"; Ok ((Kinds $r) -notmatch 'status') "no status at $rc"
  }
}
T 'add: argument and draft problems are refused before any call' {
  New-AddWorld
  foreach ($w in @(@('add', 'brooklyn96/task', 'task', (Join-Path $Root 'nope.json')), @('add', 'brooklyn96/task', 'task', (Join-Path $Root 'nj.json')))) {
    $r = Run-Fcode $w; Eq $r.Code 65; Eq $r.Calls.Count 0
  }
}

# ============================== source checks ==============================
$src = [IO.File]::ReadAllText($Fcode)
T 'dispatch: `fcode deploy` is routed before the session-name check, and the other commands are routed as before' {
  $iDep = $src.IndexOf("if (`$arg -eq 'deploy') { exit (Invoke-Deploy) }"); Ok ($iDep -gt 0) 'dispatch line present'
  Ok ($src.IndexOf("if (`$arg -eq 'add') { exit (Invoke-Add) }") -lt $iDep -and $iDep -lt $src.IndexOf("if (`$arg -eq 'pair') { exit (Invoke-Pair) }")) 'next to add and pair'
  foreach ($c in 'sync:Invoke-Sync', 'ipa:Invoke-Ipa', 'add:Invoke-Add', 'pair:Invoke-Pair', 'phien:Invoke-Phien', 'moc:Invoke-Moc') { $p = $c -split ':'; Ok ($src.Contains("if (`$arg -eq '$($p[0])') { exit ($($p[1])) }")) "route $($p[0])" }
}
T 'agents-git.md (decision-r4 4.4): no fcode/deploy status yet on the merge sha = still running (poll like waiting); only a 403 or an unreadable answer goes to the user' {
  $md = [IO.File]::ReadAllText((Join-Path $Repo 'box/agents-git.md'))
  Ok ($md -match 'No such status yet[^.]*= still running, handled like `waiting`') 'no status yet = waiting'
  Ok ($md -match 'no `fcode/deploy` status yet = still running: read it again every minute') 'in the polling rule'
  Ok ($md -notmatch 'No such status yet, or the API answers 403: say so') 'the old "tell the user there is no status" rule is gone'
  Ok ($md -match 'answers 403 or the answer cannot be read: say so to the user') '403 is still reported'
}
T 'source: the deploy code never writes files except the one public-key temp file, and never puts the draft into an argument' {
  $d = ($found | ForEach-Object { $_.Extent.Text }) -join "`n"
  Ok ($d -notmatch 'Set-Content|AppendAllText|WriteAllText|Out-File') 'no text writers'
  Ok (([regex]::Matches($d, 'WriteAllBytes')).Count -eq 1) 'one WriteAllBytes (the temp public key)'
  Ok ($d -notmatch 'Invoke-Expression|\biex\b|Start-Process|cmd /c') 'no shell re-parse of user words'
}

# ============================== end to end: the real fcode.ps1 in a child process, ssh.cmd / gh.cmd stubs on PATH ==============================
$hostExe = (Get-Process -Id $PID).Path
$Bin = Join-Path $Root 'bin'; [void](New-Item -ItemType Directory -Path $Bin)
$StubLog = Join-Path $Root 'stub.log'
[IO.File]::WriteAllText((Join-Path $Bin 'stub.ps1'), @'
$tool = $args[0]; $rest = @($args | Select-Object -Skip 1)
$stdin = ''; if ($rest -notcontains '-n') { $stdin = [Console]::In.ReadToEnd() }   # like ssh -n: no stdin read
$line = $tool + ' ' + ($rest -join [char]1) + ' STDIN=' + ($stdin.Trim())
[IO.File]::AppendAllText($env:STUB_LOG, $line + "`n")
if ($env:STUB_OUT) { $env:STUB_OUT -split ';' | ForEach-Object { Write-Output $_ } }
exit ([int]$env:STUB_RC)
'@, $utf8)
foreach ($t in 'ssh', 'gh') { [IO.File]::WriteAllText((Join-Path $Bin "$t.cmd"), "@echo off`r`n`"$hostExe`" -NoProfile -File `"%~dp0stub.ps1`" $t %*`r`nexit /b %errorlevel%`r`n", $utf8) }
$Home2 = Join-Path $Root 'home'; [void](New-Item -ItemType Directory -Path (Join-Path $Home2 '.fcode'))
[IO.File]::WriteAllText((Join-Path $Home2 '.fcode\config.json'), '{"deployHost":"vps-e2e"}', $utf8)
function Run-E2E([string[]]$Words, [string]$Out = '', [int]$Rc = 0) {
  $savedPath = $env:PATH; $savedUp = $env:USERPROFILE
  $env:PATH = "$Bin;$env:PATH"; $env:USERPROFILE = $Home2; $env:STUB_LOG = $StubLog; $env:STUB_OUT = $Out; $env:STUB_RC = "$Rc"
  try {
    if (Test-Path $StubLog) { Remove-Item $StubLog }
    $o = @(& $hostExe -NoProfile -File $Fcode @Words 2>&1)
    $code = $LASTEXITCODE
  } finally { $env:PATH = $savedPath; $env:USERPROFILE = $savedUp; $env:STUB_LOG = $null; $env:STUB_OUT = $null; $env:STUB_RC = $null }
  @{ Code = $code; Out = (($o | ForEach-Object { "$_" }) -join "`n"); Log = @(if (Test-Path $StubLog) { [IO.File]::ReadAllLines($StubLog) }) }
}
T 'e2e: fcode deploy <name> status = ssh -n <deployHost> "<gate> --local <name> status"; output streamed; exit code = the gate code' {
  $r = Run-E2E @('deploy', 'task', 'status') 'DEPLOY_RUNNING no;BLOCKED paths-busy;GATE_EXIT 70' 70
  Eq $r.Code 70 ('exit code: ' + $r.Out)
  Ok ($r.Out -match 'DEPLOY_RUNNING no' -and $r.Out -match 'BLOCKED paths-busy' -and $r.Out -match 'GATE_EXIT 70') ('output: ' + $r.Out)
  Eq $r.Log.Count 1 'one ssh call'
  Eq ($r.Log[0] -replace ' STDIN=.*$', '') ("ssh -n${SEP}vps-e2e${SEP}$GATE task status") 'argv'
}
T 'e2e: a refused word never starts ssh; exit 65; bare `fcode deploy` prints the usage' {
  foreach ($w in @(@('deploy', 'task', 'rm'), @('deploy', 'task', 'deploy', 'x;id'), @('deploy'), @('deploy', 'add', 'x'))) {
    $r = Run-E2E $w; Eq $r.Code 65 ($w -join ' '); Eq $r.Log.Count 0 'no ssh'; Ok ($r.Out.Trim().Length -gt 0) 'a message is shown'
  }
}
T 'e2e: inventory <draft>: the real pipe to the native ssh carries the exact draft bytes as base64; nothing in argv' {
  $r = Run-E2E @('deploy', 'task', 'inventory', $Draft) 'INV ok' 0
  Eq $r.Code 0 $r.Out; Eq $r.Log.Count 1
  $line = $r.Log[0]
  Ok ($line -match [regex]::Escape("ssh vps-e2e${SEP}base64 -di | $GATE task inventory STDIN=")) ('argv: ' + $line)
  $b64 = ($line -split ' STDIN=', 2)[1]
  Ok (Bytes-Eq ([Convert]::FromBase64String($b64)) $DraftBytes) 'stdin bytes'
  Ok (($line -split ' STDIN=', 2)[0] -notmatch 'SECRET-SENTINEL') 'argv has no draft content'
}
T 'e2e: trust on i-understand-root through the real script: status first, warning, then trust; exit code of the trust call' {
  $r = Run-E2E @('deploy', 'task', 'trust', 'on', 'i-understand-root') 'PROJECT task shape=release trusted=no branch=main repo=brooklyn96/task' 0
  Eq $r.Code 0 $r.Out; Eq $r.Log.Count 2
  Ok ($r.Out.Contains((Expected-Warning 'brooklyn96/task' 'main'))) ('warning: ' + $r.Out)
  Ok ($r.Log[1] -match 'trust on i-understand-root') 'second call is the trust'
}
T 'help: the overview is compact (every line <= 80 chars), has the two rollout-guide strings, lists every command, no ESC when piped' {
  $r = Run-E2E @('help'); Eq $r.Code 0; Eq $r.Log.Count 0
  $lines = @($r.Out -split "`n")
  foreach ($l in $lines) { Ok ($l.Length -le 80) ("line too long (" + $l.Length + "): $l") }
  Ok ($r.Out.IndexOf([char]27) -lt 0) 'no escape code in piped output'
  $d = @($lines | Where-Object { $_ -match 'fcode deploy' })
  Ok ($d.Count -ge 2) 'at least two fcode deploy lines'
  Ok (@($d | Where-Object { $_.Contains('fcode deploy <tên> <lệnh> [đối số]') }).Count -ge 1) 'deploy <tên> <lệnh> [đối số]'
  Ok (@($d | Where-Object { $_.Contains('fcode deploy add <chủ/repo> <tên> <draft.json>') }).Count -ge 1) 'deploy add <chủ/repo> <tên> <draft.json>'
  foreach ($c in 'sync', 'ipa', 'add', 'deploy', 'pair', 'phien', 'moc', 'new', '--list', 'help') { Ok ($r.Out.Contains("fcode $c")) "overview lists fcode $c" }
  Ok ($r.Out.Contains('fcode help <lệnh>')) 'closing hint'
  Ok ($r.Out.Contains('fcode help vao')) 'overview names the topic vao'
  foreach ($f in '-h', '--help', '/?') { $x = Run-E2E @($f); Eq $x.Code 0 $f; Eq $x.Out $r.Out "$f prints the same overview" }
}
T 'help: fcode help <lệnh> prints the detail of every command (lines <= 78 chars, no ESC); unknown topic -> message + overview, exit 0' {
  foreach ($t in 'vao', 'new', 'sync', 'ipa', 'add', 'deploy', 'pair', 'phien', 'moc', 'help') {
    $r = Run-E2E @('help', $t); Eq $r.Code 0 $t; Ok ($r.Out.IndexOf([char]27) -lt 0) "$t no escape code"
    foreach ($l in @($r.Out -split "`n")) { if ($l -notmatch 'config\.json') { Ok ($l.Length -le 78) ("$t line too long (" + $l.Length + "): $l") } }
    Ok ($r.Out.Contains("fcode $t") -or $t -eq 'vao') "$t names its command"
  }
  $r = Run-E2E @('help', 'deploy'); Eq $r.Code 0
  foreach ($s in 'status [id]', 'deploy <sha>', 'retry [sha]', 'pause', 'resume', 'trust on i-understand-root | off', 'logs [id] [số dòng]', 'recheck', 'compact', 'inventory <draft.json>', 'register <sha256> <draft.json>', 'fcode deploy add <chủ/repo> <tên> <draft.json>', 'deployHost', 'quyền root', 'fcode deploy task status') { Ok ($r.Out.Contains($s)) "help deploy lacks: $s" }
  Ok (@($r.Out -split "`n" | Where-Object { $_ -match 'deploy <sha>' -and $_ -match 'tạm dừng' -and $_ -match 'resume' }).Count -ge 1) 'help deploy: deploy <sha> pauses until resume'
  $o = Run-E2E @('help'); $u = Run-E2E @('help', 'xyz')
  Eq $u.Code 0; Ok ($u.Out.Contains("Không có lệnh 'xyz'")) 'unknown topic message'; Ok ($u.Out.Contains($o.Out)) 'unknown topic prints the overview'
  Eq (Run-E2E @('help', '-l')).Out (Run-E2E @('help', 'vao')).Out 'alias -l'
}

Set-Location $env:TEMP
Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "passed $script:pass, failed $script:fail"
if ($script:fail) { exit 1 }
exit 0
