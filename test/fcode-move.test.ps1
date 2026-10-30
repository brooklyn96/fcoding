# Tests for `fcode move` (laptop/fcode.ps1): the laptop side of the whole-VPS move (deploy-gate docs/move/CONTRACT.md section 8).
# Run:  pwsh -NoProfile -File test/fcode-move.test.ps1     (also works with: powershell -NoProfile -File ...)
# Nothing real is contacted: the move functions are loaded out of fcode.ps1 and run in this process against function fakes of `ssh`,
# `ssh-keygen`, `gh`, `Invoke-BoxScript`, `Read-SyncLine`, the clock and the sleep; a few scripts (preflight, bootstrap key) are also run
# with bash against a throw-away FCM_ROOT. The laptop home (USERPROFILE) is a temp folder, removed at the end.
#   FCODE_TEST_ONLY=<regex>   run only the tests whose name matches
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$Repo = Split-Path -Parent $PSScriptRoot
$Fcode = Join-Path (Join-Path $Repo 'laptop') 'fcode.ps1'
$Root = Join-Path ([IO.Path]::GetTempPath()) ('fcode-move-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $Root)
Set-Location -LiteralPath $Root
$script:pass = 0; $script:fail = 0
$utf8 = New-Object Text.UTF8Encoding($false)
$savedProfile = $env:USERPROFILE
$Home2 = Join-Path $Root 'home'

function T([string]$Name, [scriptblock]$Body) {
  if ($env:FCODE_TEST_ONLY -and $Name -notmatch $env:FCODE_TEST_ONLY) { return }
  try { & $Body; $script:pass++; Write-Host "PASS $Name" }
  catch { $script:fail++; Write-Host "FAIL $Name :: $($_.Exception.Message)" }
}
function Eq($Got, $Want, [string]$What = '') { if ("$Got" -cne "$Want") { throw "$What expected [$Want] got [$Got]" } }
function Ok([bool]$c, [string]$What) { if (-not $c) { throw $What } }

# --- load the move functions (and the few helpers they use) out of fcode.ps1 without running the script ---
$tokens = $null; $errs = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Fcode, [ref]$tokens, [ref]$errs)
if ($errs.Count) { throw "fcode.ps1 does not parse: $($errs[0].Message)" }
$extra = 'Get-DeployHost', 'Test-DeployRepo', 'Invoke-DeploySsh', 'Write-PhienText', 'Clear-PhienPartFiles', 'Test-PhienOwnerGone', 'Write-IpaError'
$found = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and ($n.Name -match '-Move' -or $n.Name -in $extra) }, $true))
foreach ($e in $extra) { if (-not @($found | Where-Object { $_.Name -eq $e }).Count) { throw "fcode.ps1 lacks $e" } }
foreach ($fn in $found) { . ([scriptblock]::Create($fn.Extent.Text)) }
foreach ($need in 'Invoke-Move', 'Resolve-MoveAction', 'Invoke-MoveGate', 'Invoke-MoveCutover', 'Get-MovePreflightScript') { if (-not @($found | Where-Object { $_.Name -eq $need }).Count) { throw "fcode.ps1 lacks $need" } }

# --- fakes (defined AFTER the real functions, so they win) ---
function Get-Cfg([string]$Key, $Default) { if ($Key -eq 'deployHost' -and $script:DeployHost) { $script:DeployHost } else { $Default } }
$script:Answers = New-Object Collections.Queue
$script:Prompts = New-Object Collections.ArrayList
function Read-SyncLine([string]$Prompt) { [void]$script:Prompts.Add($Prompt); if ($script:Answers.Count) { $script:Answers.Dequeue() } else { $null } }
$script:Clock = [DateTime]::SpecifyKind([DateTime]'2026-10-29T10:00:00', [DateTimeKind]::Utc)
$script:Sleeps = New-Object Collections.ArrayList
function Get-MoveNow { $script:Clock }
function Wait-Move([int]$Sec) { [void]$script:Sleeps.Add($Sec); $script:Clock = $script:Clock.AddSeconds($Sec) }
$script:Log = New-Object Collections.ArrayList
$script:Rules = New-Object Collections.ArrayList
$script:GhIn = New-Object Collections.ArrayList     # stdin given to gh calls
$script:ScriptLog = New-Object Collections.ArrayList # @{ Host; Name; Args; Text }
$script:GateIn = New-Object Collections.ArrayList   # @{ Host; Verb; Stdin }
function Add-Rule([string]$H, [string]$V, [int]$N = -1, [int]$Code = 0, [string[]]$Out = @(), [scriptblock]$Do = $null, [object[]]$Seq = $null) {
  [void]$script:Rules.Insert(0, @{ H = $H; V = $V; N = $N; Code = $Code; Out = $Out; Do = $Do; Seq = $Seq; I = 0 })
}
function Get-Rule([string]$H, [string]$Line) {
  foreach ($r in $script:Rules) { if ($r.N -ne 0 -and $H -match $r.H -and $Line -match $r.V) { if ($r.N -gt 0) { $r.N-- }; return $r } }
}
function Idx([string]$Rx, [int]$From = 0) { for ($i = $From; $i -lt $script:Log.Count; $i++) { if ($script:Log[$i] -match $Rx) { return $i } }; -1 }
function Ordered([string[]]$Rxs) { $p = -1; foreach ($rx in $Rxs) { $i = Idx $rx ($p + 1); if ($i -lt 0) { throw "missing or out of order: $rx   in: $($script:Log -join ' ; ')" }; $p = $i } }
function Count([string]$Rx) { @($script:Log | Where-Object { $_ -match $Rx }).Count }

$OldAddr = '203.0.113.10'; $NewAddr = '198.51.100.20'
$KeyOld = [Convert]::ToBase64String([byte[]](1..40)); $KeyNew = [Convert]::ToBase64String([byte[]](41..80))
$Pub = 'ssh-ed25519 ' + [Convert]::ToBase64String([byte[]](90..130))
$CANARY = 'CANARY-7f3a91c2'
$script:SshG = @{}
$script:Known = @{}
$script:Coder = @{ Up = $true; Config = ''; Known = '' }
$script:Pf = @{}
$script:Tcp = @{}
$script:Mf = $null
$script:Tunneled = $false
$script:Gh = @{}
$script:GhFail = @{}

function New-FakeManifest([string]$Id) {
  $m = [ordered]@{
    schema = 1; created = '2026-10-29T00:00:00Z'; move_id = $Id; gate = @{ version = 'abc123' }
    host = @{ os = 'ubuntu-24.04'; arch = 'x86_64'; cpus = 4; mem_mb = 8000; swap_mb = 0; tz = 'Asia/Singapore'; node_major = 22; pg_major = 16; docker = $true; disk = @(@{ mount = '/'; used_mb = 1000; free_mb = 50000 }) }
    apps = @(
      @{ name = 'deal-sync'; kind = 'legacy'; repo = 'brooklyn96/BD-Team-Project'; shape = '-'; guard = 'deal-sync'; guard_retry_s = 60; guard_cap_s = 5400; health = @() }
      @{ name = 'autoshopee'; kind = 'gate'; repo = 'brooklyn96/autoshopee'; shape = 'release'; guard = 'gate'; guard_retry_s = 30; guard_cap_s = 600; health = @() }
      @{ name = 'notes'; kind = 'unmanaged'; repo = $null; shape = '-'; guard = 'none'; guard_retry_s = 0; guard_cap_s = 0; health = @() }
    )
    items = @(
      @{ id = 'gate-entry'; kind = 'files'; app = 'host'; roots = @('/usr/local/sbin/fcode-deploy-gate'); size_mb = 1; meta = @{} }
      @{ id = 'gate-lib'; kind = 'files'; app = 'host'; roots = @('/usr/local/lib/fcode-deploy-gate'); size_mb = 2; meta = @{} }
      @{ id = 'gate-units'; kind = 'files'; app = 'host'; roots = @('/etc/systemd/system/fcode-deploy-poll.service', '/etc/systemd/system/fcode-deploy-poll.timer'); size_mb = 1; meta = @{} }
      @{ id = 'tunnel-fcode-sites'; kind = 'tunnel'; app = 'host'; roots = @('/root/.cloudflared/abc.json', '/root/.cloudflared/config.yml', '/etc/systemd/system/cloudflared.service'); size_mb = 1; meta = @{ name = 'fcode-sites'; connector_units = @('cloudflared.service') } }
      @{ id = 'pgdb-deal-sync'; kind = 'pgdb'; app = 'deal-sync'; roots = @(); size_mb = 300; meta = @{ db = 'deal_sync' } }
      @{ id = 'files-opt-x'; kind = 'files'; app = 'autoshopee'; roots = @('/opt/x'); size_mb = 2000; meta = @{} }
    )
    hostnames = @(@{ name = 'a.example.com'; kind = $(if ($script:Tunneled) { 'tunnel' } else { 'a-record' }); app = 'deal-sync'; tunnel = $null; resolves = 'here'; ttl = 300 })
    unmapped = @(); est_downtime_s = 120
  }
  if ($script:Mf) { & $script:Mf $m }
  ConvertTo-Json -InputObject $m -Depth 10 -Compress
}
function ConvertTo-NoPad([string]$s) { [Convert]::ToBase64String($utf8.GetBytes($s)).TrimEnd('=') }

function Fake-Result($Rule, [string[]]$Default, [int]$DefaultCode = 0) {
  if ($Rule -and $Rule.Seq) { $a = $Rule.Seq[[Math]::Min($Rule.I, $Rule.Seq.Count - 1)]; $Rule.I++; return @{ Out = @($a.Out); Code = $a.Code } }
  $out = if ($Rule -and $Rule.Out.Count) { $Rule.Out } else { $Default }
  $code = if ($Rule) { $Rule.Code } else { $DefaultCode }
  @{ Out = @($out); Code = $code }
}
function Fake-Gate([string]$H, [string]$Verb, [string]$Id, [string]$Rest, [string]$Stdin) {
  $line = "$H $Verb$(if ($Rest) { ' ' + $Rest })"
  [void]$script:Log.Add($line)
  [void]$script:GateIn.Add(@{ Host = $H; Verb = $Verb; Stdin = $Stdin; Id = $Id; Rest = $Rest })
  $r = Get-Rule $H $line
  if ($r -and $r.Do) { & $r.Do $H $Verb $Id $Rest $Stdin | Out-Null }
  $def = switch ($Verb) {
    'plan' { @("LOG $CANARY", 'INV disk mount=/ used_mb=1000 free_mb=900000', 'INV downtime est_s=120', 'INV ok') }
    'manifest' { $t = New-FakeManifest $Id; @(('MOVE manifest b64=' + (ConvertTo-NoPad $t)), ('MOVE manifest-sha ' + (Get-MoveSha256Hex ($utf8.GetBytes($t))))) }
    'status' { @("MOVE state move_id=$Id role=dst machine=new finished=no frozen=3 hold_active=0 transfer=done manifest_sha=-") }
    'transfer' { @('MOVE transfer state=started items_done=0 items_total=3 unit=fcode-move-transfer') }
    'tunnels' { $script:Tunneled = $true; @('MOVE done tunnels routed=1') }
    default { @("MOVE step $Verb skipped=no ms=5", "LOG $CANARY") }
  }
  $res = Fake-Result $r $def
  $o = @($res.Out); if (-not @($o | Where-Object { $_ -match '^GATE_EXIT' }).Count) { $o += "GATE_EXIT $($res.Code)" }
  @{ Out = $o; Code = $res.Code }
}
function Get-ScriptName([string]$Text) { if ($Text -match '(?m)^# fcode move: ([a-z ]+(?:\((?:read|write)\))?)') { $Matches[1].Trim() } else { 'unknown' } }
function Fake-Script([string]$H, [string]$Text, [string[]]$ScriptArgs) {
  $name = Get-ScriptName $Text
  [void]$script:Log.Add("$H script:$name")
  [void]$script:ScriptLog.Add(@{ Host = $H; Name = $name; Args = $ScriptArgs; Text = $Text })
  $r = Get-Rule $H "script:$name"
  if ($r -and $r.Do) { & $r.Do $H $name $ScriptArgs $Text | Out-Null }
  $def = switch ($name) {
    'preflight' { if ($script:Pf.ContainsKey($H)) { $script:Pf[$H] } else { @('INV host os=ubuntu-24.04 arch=x86_64 cpus=4 mem_mb=8000 swap_mb=0 tz=Asia/Singapore node_major=0', 'INV disk mount=/ used_mb=2000 free_mb=900000', 'INV egress smtp=open', 'INV target moveid=- peer=- projects=0') } }
    'bootstrap key' { @(('MOVE key created name=newbox pub_b64=' + (ConvertTo-NoPad $Pub)), "LOG $CANARY") }
    'bootstrap gate' { @('MOVE step bootstrap-gate skipped=no') }
    default { @() }
  }
  $code = 0
  if ($name -ceq 'TCP test to $1:$2 (exit 0 = reachable)' -or $name -match '^TCP') { $code = $(if ($script:Tcp.ContainsKey($H)) { $script:Tcp[$H] } else { 0 }) }
  $res = Fake-Result $r $def $code
  @{ Out = @($res.Out); Code = $res.Code }
}
function ssh {
  $in = (@($input) -join "`n"); $a = @($args | ForEach-Object { [string]$_ })
  if ($a[0] -ceq '-G') {
    $g = $script:SshG[$a[1]]
    if (-not $g) { $global:LASTEXITCODE = 255; return }
    $global:LASTEXITCODE = 0
    return @("host $($a[1])", "hostname $($g.Host)", 'user root', "port $(if ($g.Port) { $g.Port } else { 22 })") + @(if ($g.Proxy) { "proxycommand $($g.Proxy)" })
  }
  $h = $a[-2]; $remote = $a[-1]
  if ($script:Down -and $h -match $script:Down) { $global:LASTEXITCODE = 255; return }
  $r = $null
  if ($remote -match '/usr/local/sbin/fcode-deploy-gate --move (\S+)(?: (\S+))?(?: (.*))?$') {
    $verb = $Matches[1]; $id = $Matches[2]; $rest = $Matches[3]
    if ($verb -ceq 'status') { $rest = ("$id $rest").Trim(); $id = '' }
    $stdin = ''
    if ($remote.StartsWith('base64 -di | ')) { $stdin = $utf8.GetString([Convert]::FromBase64String($in.Trim())) }
    $r = Fake-Gate $h $verb $id $rest $stdin
  } elseif ($remote -match '^f=\$\(mktemp\)') {
    $text = $utf8.GetString([Convert]::FromBase64String($in.Trim()))
    $sa = @()
    if ($text -match '(?s)\Aset -- (.*?)\n') { $sa = @([regex]::Matches($Matches[1], "'((?:[^']|'\\'')*)'") | ForEach-Object { $_.Groups[1].Value -replace "'\\''", "'" }); $text = $text.Substring($text.IndexOf("`n") + 1) }
    $r = Fake-Script $h $text $sa
  } else { throw "unexpected ssh call: $($a -join ' ')" }
  $global:LASTEXITCODE = $r.Code
  $r.Out
}
function ssh-keygen {
  $a = @($args | ForEach-Object { [string]$_ })
  if ($a[0] -ceq '-F' -and $script:Known.ContainsKey($a[1])) { $global:LASTEXITCODE = 0; return @("# Host $($a[1]) found: line 1", "$($a[1]) ssh-ed25519 $($script:Known[$a[1]])") }
  $global:LASTEXITCODE = 1
}
function gh {
  $t = (@($args | ForEach-Object { [string]$_ }) -join ' ')
  $in = (@($input) -join "`n")
  [void]$script:Log.Add("gh $t"); [void]$script:GhIn.Add($in)
  $global:LASTEXITCODE = 0
  foreach ($k in $script:GhFail.Keys) { if ($t -match $k) { $global:LASTEXITCODE = [int]$script:GhFail[$k]; return @('gh: failure') } }
  if ($t -match '^secret list -R (\S+)') { return @("DEPLOY_KNOWN_HOSTS`t2026-01-01", "VPS_HOST`t2026-01-01") }
  if ($t -match '^api repos/([^/]+/[^/]+)/contents/\.github/workflows/(\S+) -H') { $f = $script:Gh[$Matches[1]][$Matches[2]]; if ($f) { return @($f.Text -split "`n") }; $global:LASTEXITCODE = 1; return @('Not Found') }
  if ($t -match '^api repos/([^/]+/[^/]+)/contents/\.github/workflows$') {
    $w = $script:Gh[$Matches[1]]
    if (-not $w) { $global:LASTEXITCODE = 1; return @('gh: Not Found (HTTP 404)') }
    return @(ConvertTo-Json -InputObject @($w.Keys | ForEach-Object { @{ name = $_ } }) -Compress)
  }
  if ($t -match '^workflow list -R (\S+) ') { $w = $script:Gh[$Matches[1]]; return @(ConvertTo-Json -InputObject @($w.Keys | ForEach-Object { @{ path = ".github/workflows/$_"; state = $w[$_].State } }) -Compress) }
  if ($t -match '^run list ') { return @('[]') }
  @()
}
function Invoke-BoxScript([string]$Script, [string[]]$ScriptArgs) {
  $name = Get-ScriptName $Script
  [void]$script:Log.Add("box:$name")
  if (-not $script:Coder.Up) { $global:LASTEXITCODE = 255; return }
  $global:LASTEXITCODE = 0
  if ($name -like '*read*') { return @("MOVE coder-config exists=yes b64=$([Convert]::ToBase64String($utf8.GetBytes($script:Coder.Config)))") }
  if ($name -like '*write*') {
    if ($ScriptArgs[0] -cne '-') { $script:Coder.Config = $utf8.GetString([Convert]::FromBase64String($ScriptArgs[0])) }
    if ($ScriptArgs[2] -cne '-' -and $script:Coder.Known -notmatch [regex]::Escape($ScriptArgs[2])) { $script:Coder.Known += $ScriptArgs[2] + "`n" }
    return @('MOVE alias coder done')
  }
  @()
}

# --- the world ---
$LaptopCfg = @"
Host contabo
  HostName $OldAddr
  User root
  IdentityFile ~/.ssh/contabo_key

Host newbox
  HostName $NewAddr
  User root
  IdentityFile ~/.ssh/newbox_key

Host homebox
  HostName 192.168.1.50
  User root

Host cfbox
  HostName ssh.example.net
  User root
  ProxyCommand cloudflared access ssh --hostname %h
"@ -replace "`r`n", "`n"
function Reset-World {
  $script:Log.Clear(); $script:Rules.Clear(); $script:Answers.Clear(); $script:Prompts.Clear(); $script:Sleeps.Clear(); $script:GhIn.Clear(); $script:ScriptLog.Clear(); $script:GateIn.Clear()
  $script:Clock = [DateTime]::SpecifyKind([DateTime]'2026-10-29T10:00:00', [DateTimeKind]::Utc)
  $script:Pf = @{}; $script:Tcp = @{}; $script:Mf = $null; $script:Tunneled = $false; $script:Down = $null; $script:GhFail = @{}; $script:DeployHost = $null
  $script:Gh = @{
    'brooklyn96/BD-Team-Project' = @{ 'deploy.yml' = @{ Text = "run: ssh with `${{ secrets.DEPLOY_KNOWN_HOSTS }}"; State = 'active' } }
    'brooklyn96/autoshopee' = @{ 'deploy.yml' = @{ Text = "key: `${{ secrets.VPS_SSH_KEY }}"; State = 'active' }; 'old.yml' = @{ Text = "key: `${{ secrets.SSH_PRIVATE_KEY }}"; State = 'disabled_manually' }; 'ci.yml' = @{ Text = 'run: npm test'; State = 'active' } }
  }
  $script:SshG = @{ 'contabo' = @{ Host = $OldAddr }; 'contabo-old' = @{ Host = $OldAddr }; 'newbox' = @{ Host = $NewAddr }; 'homebox' = @{ Host = '192.168.1.50' }; 'cfbox' = @{ Host = 'ssh.example.net'; Proxy = 'cloudflared access ssh --hostname %h' } }
  $script:Known = @{ $OldAddr = $KeyOld; $NewAddr = $KeyNew; '192.168.1.50' = $KeyNew; 'ssh.example.net' = $KeyNew }
  $script:Coder = @{ Up = $true; Config = $LaptopCfg -replace [regex]::Escape($NewAddr), '198.51.100.99'; Known = '' }
  $script:Coder.Config = "Host contabo`n  HostName $OldAddr`n  User root`n  IdentityFile ~/.ssh/coder_key`n"
  if (Test-Path -LiteralPath $Home2) { Remove-Item -LiteralPath $Home2 -Recurse -Force }
  $ssh = Join-Path $Home2 '.ssh'; [void](New-Item -ItemType Directory -Path $ssh -Force)
  [IO.File]::WriteAllText((Join-Path $ssh 'config'), $LaptopCfg, $utf8)
  $env:USERPROFILE = $Home2
}
function Run-Move([string[]]$Words) {
  $script:Rest = @('move') + $Words
  $script:Log.Clear(); $script:Prompts.Clear(); $script:GateIn.Clear(); $script:ScriptLog.Clear(); $script:GhIn.Clear()
  $all = @(& { Invoke-Move } 6>&1)
  $code = @($all | Where-Object { $_ -isnot [Management.Automation.InformationRecord] })
  $text = @($all | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" })
  if ($code.Count -ne 1) { throw "Invoke-Move returned $($code.Count) values: $($code -join ',') :: $($text -join ' | ')" }
  @{ Code = [int]$code[0]; Text = ($text -join "`n") }
}
function State { Read-MoveState }
function Seed([string]$Phase = 'copied', [string]$Dir = 'fwd', [string]$Via = 'plan', [string]$Mark = '') {
  $id = [guid]::NewGuid().ToString()
  $mo = [pscustomobject][ordered]@{ alias = 'contabo'; addr = $OldAddr; hostkey_line = "$OldAddr ssh-ed25519 $KeyOld"; fp = 'SHA256:old' }
  $mn = [pscustomobject][ordered]@{ alias = 'newbox'; kind = 'vps'; addr = $NewAddr; hostkey_line = "$NewAddr ssh-ed25519 $KeyNew"; fp = 'SHA256:new' }
  $s = New-MoveState $id $Dir $Via $mo $mn
  Set-MoveProp $s 'phase' $Phase; Set-MoveProp $s 'mark' $(if ($Mark) { $Mark } else { $null })
  Set-MoveProp $s 'est_downtime_s' 120; Set-MoveProp $s 'cap_s' 1800
  Set-MoveProp $s 'repos' @(
    [pscustomobject][ordered]@{ repo = 'brooklyn96/BD-Team-Project'; app = 'deal-sync'; kind = 'gate-push'; workflow = 'deploy.yml'; enabled = $true }
    [pscustomobject][ordered]@{ repo = 'brooklyn96/autoshopee'; app = 'autoshopee'; kind = 'ssh-push'; workflow = 'deploy.yml'; enabled = $true }
    [pscustomobject][ordered]@{ repo = 'brooklyn96/autoshopee'; app = 'autoshopee'; kind = 'ssh-push'; workflow = 'old.yml'; enabled = $false })
  $t = New-FakeManifest $id
  Save-MoveManifest $t; Set-MoveProp $s 'manifest_sha' (Get-MoveSha256Hex ($utf8.GetBytes($t)))
  Save-MoveState $s
  $s
}
function Yes { $script:Answers.Enqueue('YES') }
function Names([string]$Rx) { @($script:Log | Where-Object { $_ -match $Rx }) }

# ============================== state and the re-run table ==============================
T 'state: round-trip keeps every field of the schema; atomic (no part file left); times stay strings' {
  Reset-World
  $s = Seed 'cut' 'back' 'back' 'switching'
  Set-MoveProp $s 'cut_at' '2026-10-28T01:02:03Z'; Set-MoveProp $s 'cut_not_before' '2026-10-29T11:00:00Z'; Set-MoveProp $s 'dst_started' $true
  Set-MoveProp $s.answers 'cut' ([pscustomobject]@{ a = 'yes'; ts = '2026-10-28T00:00:00Z' })
  Save-MoveState $s
  $r = State
  foreach ($k in 'schema', 'move_id', 'dir', 'via', 'old', 'new', 'manifest_sha', 'est_downtime_s', 'cap_s', 'phase', 'mark', 'cut_at', 'cut_not_before', 'dst_started', 'answers', 'repos', 'backups') { Ok ($null -ne $r.PSObject.Properties[$k]) "field $k" }
  Eq $r.phase 'cut'; Eq $r.mark 'switching'; Eq $r.dir 'back'; Eq $r.via 'back'; Eq $r.dst_started $true
  Eq $r.cut_at '2026-10-28T01:02:03Z'; Eq $r.cut_not_before '2026-10-29T11:00:00Z'; Eq $r.answers.cut.ts '2026-10-28T00:00:00Z'; Eq $r.answers.cut.a 'yes'
  Eq $r.old.alias 'contabo'; Eq $r.new.kind 'vps'; Eq @($r.repos).Count 3; Eq $r.repos[1].kind 'ssh-push'; Eq $r.repos[2].enabled $false
  Eq @(Get-ChildItem -LiteralPath (Get-MoveDir) -Filter '*.part-*').Count 0 'no part file'
  Save-MoveState $r; $r2 = State; Eq $r2.cut_at $r.cut_at; Eq $r2.answers.cut.ts $r.answers.cut.ts   # a second round trip is stable
}
T 'state: a corrupt or foreign state file stops every command but plan-free ones with exit 1 and no ssh call' {
  Reset-World
  [IO.File]::WriteAllText((Get-MovePath 'state.json'), '{"schema":1,"move_id":', $utf8)
  foreach ($w in @('copy'), @('cutover'), @('finish'), @('back'), @('plan', 'newbox'), @('status')) { $r = Run-Move $w; Eq $r.Code 1 ($w -join ' '); Ok ($r.Text -match 'state') 'names the state file'; Eq $script:Log.Count 0 'no call' }
  [IO.File]::WriteAllText((Get-MovePath 'state.json'), '{"schema":2,"move_id":"x"}', $utf8)
  Eq (Run-Move @('copy')).Code 1
}
T 'move.lock: a held lock refuses the second run (exit 1, no call); released lock lets it run' {
  Reset-World; [void](Seed 'planned')
  $lk = Open-MoveLock
  try { Ok ($null -ne $lk) 'first lock'; $r = Run-Move @('copy'); Eq $r.Code 1; Ok ($r.Text -match 'move\.lock') 'names the lock'; Eq $script:Log.Count 0; Eq (Run-Move @('status')).Code 0 'status needs no lock' } finally { $lk.Dispose() }
  $lk2 = Open-MoveLock; Ok ($null -ne $lk2) 'free again'; $lk2.Dispose()
}
T 're-run table: every phase x mark x via x command' {
  $t = New-Object Collections.ArrayList
  # phase, mark, via, then plan / copy / cutover / finish / back (then flags: dst_started, answers_cut, answers_back)
  foreach ($row in @(
    , @('none', '', '', 'plan-new', 'refuse', 'refuse', 'refuse', 'refuse')
    , @('planned', '', 'plan', 'replan', 'copy', 'refuse', 'abandon', 'refuse')
    , @('planned', '', 'back', 'refuse', 'copy', 'refuse', 'abandon', 'back-copy-cutover')
    , @('copied', '', 'plan', 'replan', 'copy', 'cutover', 'abandon', 'refuse')
    , @('rolled-back', '', 'plan', 'replan', 'copy', 'cutover', 'abandon', 'refuse')
    , @('copied', '', 'back', 'refuse', 'copy', 'cutover', 'abandon', 'cutover')
    , @('rolled-back', '', 'back', 'refuse', 'copy', 'cutover', 'abandon', 'cutover')
    , @('cut', '', 'plan', 'refuse', 'refuse', 'chores', 'finish', 'back-start')
    , @('cut', '', 'back', 'refuse', 'refuse', 'chores', 'finish', 'back-start')
    , @('finished', '', 'plan', 'plan-new', 'refuse', 'refuse', 'done', 'refuse')
    # mark null: neither answers nor dst_started change anything (they are not "in flight")
    , @('copied', '', 'plan', 'replan', 'copy', 'cutover', 'abandon', 'refuse', 'answers_cut')
    , @('copied', '', 'back', 'refuse', 'copy', 'cutover', 'abandon', 'cutover', 'answers_back')
    , @('copied', '', 'plan', 'replan', 'copy', 'cutover', 'abandon', 'refuse', 'dst_started')
    , @('planned', '', 'back', 'refuse', 'copy', 'refuse', 'abandon', 'back-copy-cutover', 'answers_back')
  )) { [void]$t.Add($row) }
  # a mark set, in every phase (CONTRACT section 8, one row): cutting and rolling-back roll back before an abandon, switching refuses it
  foreach ($ph in 'copied', 'rolled-back', 'planned') {
    foreach ($mk in 'cutting', 'rolling-back') {
      [void]$t.Add(@($ph, $mk, 'plan', 'refuse', 'refuse', 'cutover-continue', 'abandon-rollback', 'refuse'))
      [void]$t.Add(@($ph, $mk, 'back', 'refuse', 'refuse', 'cutover-continue', 'abandon-rollback', 'cutover-continue'))
    }
    [void]$t.Add(@($ph, 'switching', 'plan', 'refuse', 'refuse', 'cutover-continue', 'refuse', 'refuse'))
    [void]$t.Add(@($ph, 'switching', 'back', 'refuse', 'refuse', 'cutover-continue', 'refuse', 'cutover-continue'))
  }
  [void]$t.Add(@('copied', 'cutting', 'plan', 'refuse', 'refuse', 'cutover-continue', 'abandon-rollback', 'refuse', 'dst_started', 'answers_cut'))   # side fields do not matter under a mark either
  $cmds = 'plan', 'copy', 'cutover', 'finish', 'back'
  foreach ($row in $t) {
    $fl = @($row | Select-Object -Skip 8)
    $s = if ($row[0] -ceq 'none') { $null } else { [pscustomobject]@{ phase = $row[0]; mark = $(if ($row[1]) { $row[1] } else { $null }); via = $row[2]; dst_started = ($fl -contains 'dst_started'); answers = [pscustomobject]@{ cut = $(if ($fl -contains 'answers_cut') { 1 } else { $null }); back = $(if ($fl -contains 'answers_back') { 1 } else { $null }) } } }
    for ($i = 0; $i -lt 5; $i++) {
      $a = Resolve-MoveAction $cmds[$i] $s
      Eq $a.Do $row[3 + $i] "phase=$($row[0]) mark=$($row[1]) via=$($row[2]) cmd=$($cmds[$i])"
      if ($a.Do -ceq 'refuse') { Ok ($a.Msg.Length -gt 10) 'a refuse says why' }
    }
  }
  Ok ((Resolve-MoveAction 'cutover' ([pscustomobject]@{ phase = 'planned'; mark = $null; via = 'plan' })).Msg -match "'planned'") 'the refusal names the phase'
}
T 're-run table through the real entry: a refused command runs nothing (exit 65, no ssh, no question)' {
  foreach ($c in @(@('planned', 'cutover'), @('planned', 'back'), @('cut', 'copy'), @('cut', 'plan', 'newbox'), @('finished', 'cutover'), @('copied', 'back'))) {
    Reset-World; [void](Seed $c[0]); $w = @($c | Select-Object -Skip 1)
    $r = Run-Move $w; Eq $r.Code 65 ($c -join ' '); Eq $script:Log.Count 0 'no call'; Eq $script:Prompts.Count 0 'no question'; Ok ($r.Text -match 'lỗi') 'message'
  }
  Reset-World; $r = Run-Move @('copy'); Eq $r.Code 65; Ok ($r.Text -match 'fcode move plan') 'no state: points to plan'
  $r = Run-Move @('rm'); Eq $r.Code 65; Ok ($r.Text -match 'Cách dùng') 'usage'
  $r = Run-Move @('plan'); Eq $r.Code 65; $r = Run-Move @('plan', 'x', 'y'); Eq $r.Code 65; $r = Run-Move @('copy', 'x'); Eq $r.Code 65; $r = Run-Move @('plan', 'newbox', '--map'); Eq $r.Code 65; Eq $script:Log.Count 0
}

# ============================== plan ==============================
T 'plan: a new move runs preflight, reach, server plan + manifest, push scan; INV ok; state planned; files saved; nothing else' {
  Reset-World
  $r = Run-Move @('plan', 'newbox')
  Eq $r.Code 0 $r.Text
  Ok ($r.Text -match '(?m)^INV ok$') 'INV ok'; Ok (([regex]::Matches($r.Text, '(?m)^INV ok$')).Count -eq 1) 'one INV ok'
  Ordered @('^newbox script:preflight', '^newbox script:TCP', '^contabo plan$', '^contabo manifest$', '^gh secret list', 'gh workflow list')
  $s = State
  Ok ($s.move_id -cmatch '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z') 'lowercase uuid'
  Eq $s.phase 'planned'; Eq $s.dir 'fwd'; Eq $s.via 'plan'; Eq $s.old.alias 'contabo'; Eq $s.new.alias 'newbox'; Eq $s.new.kind 'vps'; Eq $s.old.addr $OldAddr; Eq $s.new.addr $NewAddr
  Eq $s.old.hostkey_line "$OldAddr ssh-ed25519 $KeyOld"; Eq $s.new.hostkey_line "$NewAddr ssh-ed25519 $KeyNew"; Ok ($s.old.fp -cmatch '\ASHA256:[A-Za-z0-9+/]{43}\z') 'fingerprint'
  Eq $s.est_downtime_s 120; Eq $s.cap_s 5400 'cap = max(1800, guard caps)'; Eq $s.dst_started $false; Eq $s.cut_not_before $null; Eq $s.mark $null
  Eq (@($s.repos | Where-Object { $_.kind -ceq 'gate-push' }).Count) 1; Eq (@($s.repos | Where-Object { $_.kind -ceq 'ssh-push' }).Count) 2
  Eq (@($s.repos | Where-Object { $_.workflow -ceq 'old.yml' })[0].enabled) $false 'a workflow disabled before the move is recorded as disabled'
  $mf = Read-MoveManifestFile; Eq $mf.Sha $s.manifest_sha; Eq $mf.Obj.move_id $s.move_id
  # the stdin of the server plan and the scripts that went over ssh
  $pi = $script:GateIn | Where-Object { $_.Verb -ceq 'plan' }; Eq $pi.Stdin '{"schema":1,"map":null,"from":null}'
  Eq $pi.Rest ''; Eq $pi.Id $s.move_id
  $pf = $script:ScriptLog | Where-Object { $_.Name -ceq 'preflight' }; Eq $pf.Text ((Get-MovePreflightScript) -replace "`r`n", "`n") 'the preflight script as sent'; Eq @($pf.Args).Count 0
  $tc = $script:ScriptLog | Where-Object { $_.Name -match '^TCP' } | Select-Object -First 1; Eq ($tc.Args -join ' ') "$OldAddr 22" 'reach test targets old'
  Ok ($r.Text -match 'INV reach old=yes') 'INV reach'; Ok ($r.Text -match 'INV push brooklyn96/BD-Team-Project app=deal-sync kind=gate-push workflow=deploy.yml') 'INV push'; Ok ($r.Text -match 'INV warn ssh-push') 'ssh-push warning'
  Ok ($r.Text -notmatch $CANARY) 'LOG lines are not echoed'
  Ok ($r.Text -notmatch 'b64=[A-Za-z0-9+/]{20}') 'no payload on the screen'
}
T 'plan: a refusal from the server is printed, ends with exit 65 and creates no state' {
  Reset-World
  Add-Rule 'contabo' ' plan$' -Code 65 -Out @('INV unmapped unit foo.service /etc/x', 'INV refuse unmapped', 'GATE_EXIT 65')
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 65
  Ok ($r.Text -match 'INV refuse unmapped') 'server refusal shown'; Ok ($r.Text -notmatch '(?m)^INV ok$') 'no INV ok'
  Ok (-not (Test-Path (Get-MovePath 'state.json'))) 'no state'
}
T 'plan: dst unreachable = INV refuse target-unreachable; old unreachable = old-unreachable; nothing else runs' {
  Reset-World; $script:Down = 'newbox'
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 65; Ok ($r.Text -match 'INV refuse target-unreachable') 'target-unreachable'; Eq (Count 'contabo') 0
  Reset-World; $script:Down = 'contabo'
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 65; Ok ($r.Text -match 'INV refuse old-unreachable') 'old-unreachable'; Ok (-not (Test-Path (Get-MovePath 'state.json'))) 'no state'
  Reset-World; $script:Tcp['newbox'] = 1
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 65; Ok ($r.Text -match 'INV reach old=no' -and $r.Text -match 'INV refuse old-unreachable') 'reach no = old-unreachable'
}
T 'plan: the target checks (token connector, config collision, remedy fixture, own move-id)' {
  # a box that already holds this peer's move-id and copied projects -> INV ok
  Reset-World; $script:Pf['newbox'] = @('INV host os=ubuntu-24.04 arch=x86_64 cpus=2 mem_mb=4000 swap_mb=0 tz=UTC node_major=22', 'INV disk mount=/ used_mb=1 free_mb=900000', 'INV egress smtp=open', 'INV target moveid=11111111-2222-3333-4444-555555555555 peer=contabo projects=6', 'INV target-file /root/.cloudflared/config.yml', 'INV target-unit cloudflared.service active=yes')
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 0 $r.Text; Ok ($r.Text -match '(?m)^INV ok$') 'own move-id: ok even with its own tunnel files and unit'
  # projects and no move-id -> target-not-empty
  Reset-World; $script:Pf['newbox'] = @('INV host os=ubuntu-24.04 arch=x86_64 cpus=2 mem_mb=4000 swap_mb=0 tz=UTC node_major=22', 'INV disk mount=/ used_mb=1 free_mb=900000', 'INV target moveid=- peer=- projects=3')
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 65; Ok ($r.Text -match 'INV refuse target-not-empty') 'target-not-empty'
  # another peer's move-id with projects is not "this peer's" either
  Reset-World; $script:Pf['newbox'] = @('INV host os=ubuntu-24.04 arch=x86_64 cpus=2 mem_mb=4000 swap_mb=0 tz=UTC node_major=22', 'INV disk mount=/ used_mb=1 free_mb=900000', 'INV target moveid=11111111-2222-3333-4444-555555555555 peer=other projects=3')
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 65; Ok ($r.Text -match 'INV refuse target-not-empty') 'foreign peer'
  # a config.yml on new colliding with a tunnel root, no move-id, no projects -> target-access-path file=
  Reset-World; $script:Pf['newbox'] = @('INV host os=ubuntu-24.04 arch=x86_64 cpus=2 mem_mb=4000 swap_mb=0 tz=UTC node_major=22', 'INV disk mount=/ used_mb=1 free_mb=900000', 'INV target moveid=- peer=- projects=0', 'INV target-file /root/.cloudflared/config.yml', 'INV target-file /root/.cloudflared/other.json')
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 65; Ok ($r.Text -match 'INV refuse target-access-path file=/root/.cloudflared/config.yml') 'file collision'; Ok ($r.Text -notmatch 'target-access-path file=/root/.cloudflared/other.json') 'a non-colliding file is no collision'; Ok ($r.Text -notmatch 'target-not-empty') 'no projects: not target-not-empty'
  # a token-based cloudflared.service on new (no file in either dir) and a manifest connector cloudflared.service -> unit collision
  Reset-World; $script:Pf['newbox'] = @('INV host os=ubuntu-24.04 arch=x86_64 cpus=2 mem_mb=4000 swap_mb=0 tz=UTC node_major=22', 'INV disk mount=/ used_mb=1 free_mb=900000', 'INV target moveid=- peer=- projects=0', 'INV target-unit cloudflared.service active=yes')
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 65; Ok ($r.Text -match 'INV refuse target-access-path unit=cloudflared.service') 'token connector'
  # after the remedy fixture (unit renamed to cloudflared-access.service, old file removed) -> INV ok
  Reset-World; $script:Pf['newbox'] = @('INV host os=ubuntu-24.04 arch=x86_64 cpus=2 mem_mb=4000 swap_mb=0 tz=UTC node_major=22', 'INV disk mount=/ used_mb=1 free_mb=900000', 'INV target moveid=- peer=- projects=0', 'INV target-unit cloudflared-access.service active=yes', 'INV target-file /root/.cloudflared/access.json')
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 0 $r.Text; Ok ($r.Text -match '(?m)^INV ok$') 'remedy fixture: ok'
}
T 'plan: arch, os major, disk (dst and src), home + gate-push are refused; every line is printed; nothing is saved' {
  Reset-World; $script:Pf['newbox'] = @('INV host os=ubuntu-22.04 arch=aarch64 cpus=2 mem_mb=4000 swap_mb=0 tz=UTC node_major=22', 'INV disk mount=/ used_mb=1 free_mb=1000', 'INV target moveid=- peer=- projects=0')
  Add-Rule 'contabo' ' plan$' -Out @('INV disk mount=/ used_mb=1 free_mb=4000', 'INV ok')
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 65
  foreach ($x in 'INV refuse arch', 'INV refuse os ', 'INV refuse disk side=dst need_mb=', 'INV refuse disk side=src need_mb=4396') { Ok ($r.Text.Contains($x)) "has $x :: $($r.Text)" }
  Ok (-not (Test-Path (Get-MovePath 'state.json'))) 'no state'
  # same os major (24.04 vs 24.10) is fine; disk need = ceil(1.2*2305) + 2*300 + 4096 = 7462
  Reset-World; $script:Pf['newbox'] = @('INV host os=ubuntu-24.10 arch=x86_64 cpus=2 mem_mb=4000 swap_mb=0 tz=UTC node_major=22', 'INV disk mount=/ used_mb=1 free_mb=7461', 'INV target moveid=- peer=- projects=0')
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 65; Ok ($r.Text.Contains('need_mb=7462 free_mb=7461')) "boundary: $($r.Text)"
  Reset-World; $script:Pf['newbox'] = @('INV host os=ubuntu-24.10 arch=x86_64 cpus=2 mem_mb=4000 swap_mb=0 tz=UTC node_major=22', 'INV disk mount=/ used_mb=1 free_mb=7462', 'INV target moveid=- peer=- projects=0')
  Eq (Run-Move @('plan', 'newbox')).Code 0
  # a home dst with a gate-push app
  Reset-World; $r = Run-Move @('plan', 'homebox'); Eq $r.Code 65; Ok ($r.Text -match 'INV refuse push-deploy-unreachable app=deal-sync') 'gate-push to a home dst'; Ok ($r.Text -notmatch 'push-deploy-unreachable app=autoshopee') 'ssh-push is not refused'
  Reset-World; $r = Run-Move @('plan', 'cfbox'); Ok ($r.Text -match 'push-deploy-unreachable') 'a ProxyCommand host is home'
}
T 'plan: new.kind home|vps from ssh -G (proxy, private, CGNAT, link-local, .local, .lan)' {
  foreach ($c in @(@('10.1.2.3', $true), @('172.16.0.1', $true), @('172.32.0.1', $false), @('192.168.0.9', $true), @('100.64.0.1', $true), @('100.128.0.1', $false), @('169.254.1.1', $true), @('nas.local', $true), @('box.lan', $true), @('fd12::1', $true), @('fe80::1', $true), @('203.0.113.7', $false), @('example.com', $false))) {
    Eq (Test-MoveHome @{ Addr = $c[0]; Proxy = $false }) $c[1] $c[0]
  }
  Eq (Test-MoveHome @{ Addr = '203.0.113.7'; Proxy = $true }) $true 'proxy'
}
T 'plan: --map is validated, saved, sent in the stdin; a later re-plan reuses the saved map' {
  Reset-World
  $mp = Join-Path $Root 'map.json'; [IO.File]::WriteAllText($mp, '{"schema":1,"map":[],"exclude":[{"match":{"unit":"x.service"},"reason":"test"}]}', $utf8)
  $r = Run-Move @('plan', 'newbox', '--map', $mp); Eq $r.Code 0 $r.Text
  $pi = $script:GateIn | Where-Object { $_.Verb -ceq 'plan' }; Ok ($pi.Stdin -match '"map":\{"schema":1,') 'map in stdin'; Ok ($pi.Stdin -match '"from":null') 'no from'
  Eq ([IO.File]::ReadAllText((Get-MovePath 'move-map.json'))) ([IO.File]::ReadAllText($mp)) 'saved copy'
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 0; $pi = $script:GateIn | Where-Object { $_.Verb -ceq 'plan' }; Ok ($pi.Stdin -match '"map":\{"schema":1,') 're-plan resends the saved map'
  foreach ($bad in 'not json', ('{"a":"' + ('x' * 17000) + '"}')) { [IO.File]::WriteAllText((Join-Path $Root 'bad.json'), $bad, $utf8); $r = Run-Move @('plan', 'newbox', '--map', (Join-Path $Root 'bad.json')); Eq $r.Code 65; Ok ($r.Text -match 'INV refuse map-invalid') 'map-invalid' }
  $r = Run-Move @('plan', 'newbox', '--map', (Join-Path $Root 'nope.json')); Eq $r.Code 65
}
T 'plan: a re-plan keeps the move_id, cut_not_before and the recorded workflow state; another alias is refused; copied goes back to planned' {
  Reset-World; $s = Seed 'copied'; Set-MoveProp $s 'cut_not_before' '2026-10-30T00:00:00Z'
  Set-MoveProp $s.repos[1] 'enabled' $false   # a cut-off cutover disabled it after the first plan
  Save-MoveState $s
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 0 $r.Text
  $n = State; Eq $n.move_id $s.move_id; Eq $n.phase 'planned'; Eq $n.cut_not_before '2026-10-30T00:00:00Z'
  Eq (@($n.repos | Where-Object { $_.workflow -ceq 'deploy.yml' -and $_.kind -ceq 'ssh-push' })[0].enabled) $false 'enabled kept from the first plan'
  $r = Run-Move @('plan', 'othermachine'); Eq $r.Code 65; Ok ($r.Text -match 'newbox') 'names the current target'
  $r = Run-Move @('plan'); Eq $r.Code 0 'alias optional on a re-plan'
}
T 'plan: after finished a new move starts (new move_id); a stale Host <old>-old refuses it' {
  Reset-World; $s = Seed 'finished'
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 0 $r.Text; Ok ((State).move_id -cne $s.move_id) 'new move_id'; Eq (State).phase 'planned'
  Reset-World; [IO.File]::AppendAllText((Join-Path (Join-Path $Home2 '.ssh') 'config'), "`nHost contabo-old`n  HostName $OldAddr`n", $utf8)
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 65; Ok ($r.Text -match 'contabo-old') 'stale -old block'; Eq $script:Log.Count 0
}
T 'plan: an old alias the server would refuse (RE_MV_NAME) or a new alias equal to it is refused before any call' {
  foreach ($bad in 'Conta_bo', 'x.y', '9box') { Reset-World; $script:DeployHost = $bad; $r = Run-Move @('plan', 'newbox'); Eq $r.Code 65 $bad; Eq $script:Log.Count 0 "$bad no call"; Ok ($r.Text -match 'deployHost') 'names deployHost' }
  Reset-World; $r = Run-Move @('plan', 'contabo'); Eq $r.Code 65; Eq $script:Log.Count 0
  Reset-World; foreach ($bad in 'NewBox', 'new_box', '-x', 'a;b') { $r = Run-Move @('plan', $bad); Ok ($r.Code -eq 65) "alias $bad" ; Eq $script:Log.Count 0 }
}
T 'plan: host key missing from known_hosts is refused (old-unreachable / target-unreachable) and nothing is saved' {
  Reset-World; $script:Known.Remove($OldAddr)
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 65; Ok ($r.Text -match 'INV refuse old-unreachable' -and $r.Text -match 'ssh contabo'); Ok (-not (Test-Path (Get-MovePath 'state.json'))) 'no state'
  Reset-World; $script:Known.Remove($NewAddr)
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 65; Ok ($r.Text -match 'INV refuse target-unreachable')
}
T 'plan: coder box cannot reach new = INV warn coder-unreachable (a warning, plan still ok)' {
  Reset-World
  $script:Coder.Up = $false
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 0 $r.Text; Ok ($r.Text -match 'INV warn coder-unreachable') 'warn'; Ok ($r.Text -match '(?m)^INV ok$') 'ok'
}
T 'push scan: gate-push / ssh-push by workflow text, enabled by state, ci workflows ignored, an old-address workflow, gh failures stop' {
  Reset-World
  $apps = @([pscustomobject]@{ name = 'deal-sync'; kind = 'legacy'; repo = 'brooklyn96/BD-Team-Project' }, [pscustomobject]@{ name = 'autoshopee'; kind = 'gate'; repo = 'brooklyn96/autoshopee' }, [pscustomobject]@{ name = 'notes'; kind = 'unmanaged'; repo = $null })
  $sc = Get-MovePushScan $apps $OldAddr; Eq $sc.Code 0
  Eq @($sc.Repos).Count 3; Eq (@($sc.Repos | Where-Object { $_.workflow -ceq 'ci.yml' }).Count) 0 'a plain ci workflow is no push deploy'
  Eq (@($sc.Repos | Where-Object { $_.workflow -ceq 'old.yml' })[0].enabled) $false; Eq (@($sc.Repos | Where-Object { $_.workflow -ceq 'old.yml' })[0].kind) 'ssh-push'
  $script:Gh['brooklyn96/autoshopee'] = @{ 'host.yml' = @{ Text = "run: ssh root@$OldAddr deploy"; State = 'active' } }
  $sc = Get-MovePushScan @($apps[1]) $OldAddr; Eq @($sc.Repos)[0].kind 'ssh-push' 'old address in the file'
  $script:Gh['brooklyn96/autoshopee'] = @{ 'both.yml' = @{ Text = "`${{ secrets.DEPLOY_KNOWN_HOSTS }} `${{ secrets.DEPLOY_SSH_KEY }}"; State = 'active' } }
  $sc = Get-MovePushScan @([pscustomobject]@{ name = 'x'; kind = 'legacy'; repo = 'brooklyn96/autoshopee' }) $OldAddr; Eq @($sc.Repos)[0].kind 'gate-push' 'DEPLOY_KNOWN_HOSTS wins (legacy app)'
  $sc = Get-MovePushScan @($apps[1]) $OldAddr; Eq @($sc.Repos).Count 0 'a gate app ignores it'
  $script:Gh.Remove('brooklyn96/autoshopee')
  $sc = Get-MovePushScan @($apps[1]) $OldAddr; Eq $sc.Code 0 'no workflows dir = no push deploy'; Eq @($sc.Repos).Count 0; Ok ([bool](@($sc.Lines) -match 'unverified')) 'secrets named like push-deploy ones but no workflow: warned'
  $script:GhFail = @{ '^secret list' = 4 }; $sc = Get-MovePushScan @($apps[0]) $OldAddr; Eq $sc.Code 1 'gh secret list failure'
  $script:GhFail = @{ 'workflow list' = 1 }; $sc = Get-MovePushScan @($apps[0]) $OldAddr; Eq $sc.Code 1 'gh workflow list failure'
  Reset-World; $script:GhFail = @{ 'contents/\.github/workflows$' = 1 }; $sc = Get-MovePushScan @($apps[0]) $OldAddr; Eq $sc.Code 1 'a non-404 api failure stops'
}
T 'CONTRACT section 8 push deploys: only a `legacy` app has gate-push workflows; a converted (gate / unmanaged) app with a DEPLOY_KNOWN_HOSTS workflow (even a disabled one) is ignored: no INV push, home dst plan not refused, no DEPLOY_KNOWN_HOSTS chore; a legacy app behaves as before' {
  Reset-World
  $script:Gh['brooklyn96/BD-Team-Project'] = @{ 'deploy.yml' = @{ Text = "run: ssh with `${{ secrets.DEPLOY_KNOWN_HOSTS }}"; State = 'disabled_manually' } }
  foreach ($k in 'gate', 'unmanaged') {
    $sc = Get-MovePushScan @([pscustomobject]@{ name = 'deal-sync'; kind = $k; repo = 'brooklyn96/BD-Team-Project' }) $OldAddr
    Eq $sc.Code 0; Eq @($sc.Repos).Count 0 "$k app: no entry"; Ok (-not [bool](@($sc.Lines) -match 'INV push')) "$k app: no INV push"
  }
  $sc = Get-MovePushScan @([pscustomobject]@{ name = 'deal-sync'; kind = 'legacy'; repo = 'brooklyn96/BD-Team-Project' }) $OldAddr
  Eq @($sc.Repos).Count 1; Eq $sc.Repos[0].kind 'gate-push'; Eq $sc.Repos[0].enabled $false 'legacy keeps the recorded state'
  # end to end: the app is a gate app in the manifest, deploy.yml disabled; a home dst is not refused; cutover sets no secret
  Reset-World; $script:Gh['brooklyn96/BD-Team-Project'] = @{ 'deploy.yml' = @{ Text = "run: ssh with `${{ secrets.DEPLOY_KNOWN_HOSTS }}"; State = 'disabled_manually' } }
  $script:Mf = { param($m) $m.apps[0].kind = 'gate'; $m.apps[0].guard = 'gate' }
  $r = Run-Move @('plan', 'homebox'); Eq $r.Code 0 $r.Text; Ok ($r.Text -notmatch 'push-deploy-unreachable') 'not refused'; Ok ($r.Text -notmatch 'INV push brooklyn96/BD-Team-Project') 'no INV push for the converted app'
  Eq (@((State).repos | Where-Object { $_.kind -ceq 'gate-push' }).Count) 0 'no gate-push in the state'
  $r = Run-Move @('copy'); Eq $r.Code 0 $r.Text; $script:Clock = $script:Clock.AddMinutes(10); Yes; $r = Run-Move @('cutover'); Eq $r.Code 0 $r.Text
  Eq (Count 'gh secret set') 0 'no DEPLOY_KNOWN_HOSTS chore'; Eq (State).phase 'cut'
  # the legacy app, same home dst: refused as before
  Reset-World; $script:Gh['brooklyn96/BD-Team-Project'] = @{ 'deploy.yml' = @{ Text = "run: ssh with `${{ secrets.DEPLOY_KNOWN_HOSTS }}"; State = 'active' } }
  $r = Run-Move @('plan', 'homebox'); Eq $r.Code 65; Ok ($r.Text -match 'INV refuse push-deploy-unreachable app=deal-sync') 'legacy: refused as before'
}

# ============================== copy ==============================
T 'copy: the sequence of CONTRACT section 8 (a)-(l), the init stdin, phase copied, cut_not_before before tunnels' {
  Reset-World; $s = Seed 'planned'
  Add-Rule 'contabo' ' tunnels' -Do { $st = State; $script:NbAtTunnels = $st.cut_not_before }
  $script:NbAtTunnels = 'unset'
  $r = Run-Move @('copy'); Eq $r.Code 0 $r.Text
  Ordered @('^newbox script:bootstrap key', '^contabo tunnels', '^contabo manifest', '^contabo init src', '^newbox script:bootstrap gate', '^newbox init dst', '^newbox prepare', '^newbox status', '^contabo dump', '^newbox transfer', '^newbox status', '^newbox adopt', '^newbox restore', '^newbox verify')
  Eq (State).phase 'copied'
  Eq $script:NbAtTunnels '2026-10-29T10:06:00Z' 'cut_not_before = now + ttl 300 + 60 s, written before tunnels'
  $k = $script:ScriptLog | Where-Object { $_.Name -ceq 'bootstrap key' }; Eq $k.Args[0] 'newbox'; Eq $k.Args[1] "$OldAddr ssh-ed25519 $KeyOld" 'old host key goes to new'; Eq $k.Args[2] '22' 'node major = max(20, manifest)'
  $g = $script:ScriptLog | Where-Object { $_.Name -ceq 'bootstrap gate' }; Eq ($g.Args -join '|') "$OldAddr|22|/usr/local/sbin/fcode-deploy-gate|/usr/local/lib/fcode-deploy-gate|/etc/systemd/system/fcode-deploy-poll.service|/etc/systemd/system/fcode-deploy-poll.timer"
  $io = $script:GateIn | Where-Object { $_.Verb -ceq 'init' -and $_.Host -ceq 'contabo' }; $in = $script:GateIn | Where-Object { $_.Verb -ceq 'init' -and $_.Host -ceq 'newbox' }
  $jo = $io.Stdin | ConvertFrom-Json; $jn = $in.Stdin | ConvertFrom-Json
  Eq $jo.machine 'old'; Eq $jo.peer 'newbox'; Eq $jo.pub $Pub 'old gets the public key'; Eq $jo.manifest_sha (State).manifest_sha; Eq $jo.manifest.move_id $s.move_id; Ok ($null -eq $jo.PSObject.Properties['peer_addr']) 'no peer_addr on old'
  Eq $jn.machine 'new'; Eq $jn.peer 'contabo'; Eq $jn.peer_addr $OldAddr; Eq $jn.peer_port 22; Eq $jn.peer_hostkey "$OldAddr ssh-ed25519 $KeyOld"; Ok ($null -eq $jn.PSObject.Properties['pub']) 'no pub on new'
  Ok ($io.Stdin.Contains((Read-MoveManifestFile).Text.Trim())) 'the manifest goes in byte for byte'
  Ok ($r.Text -notmatch $CANARY) 'no LOG canary on screen'; Ok ($r.Text -notmatch [regex]::Escape((ConvertTo-NoPad $Pub))) 'no public key payload on screen'
  Ok ((Get-ChildItem -LiteralPath $Home2 -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join '' -notmatch $CANARY) 'no canary on disk'
}
function St([string]$Transfer, [int]$Hold = 0, [int]$Code = 0) { @{ Out = @("MOVE state move_id=x role=dst machine=new finished=no frozen=0 hold_active=$Hold transfer=$Transfer manifest_sha=-"); Code = $Code } }
T 'copy: transfer is polled every 10 s until done; failed, idle-forever and a dead machine stop; a lost ssh is tolerated; dst-running stops at step (g)' {
  # the first status is step (g) (hold_active), the next ones are the polls
  Reset-World; [void](Seed 'planned'); Add-Rule 'newbox' ' status' -Seq @((St 'idle'), (St 'running'), (St 'running'), (St 'done'))
  $r = Run-Move @('copy'); Eq $r.Code 0 $r.Text
  Eq (@($script:Sleeps | Where-Object { $_ -eq 10 }).Count) 3 'three polls, 10 s apart'
  Ok ($r.Text -match 'transfer: running' -and $r.Text -match 'transfer: done') 'progress lines'
  Reset-World; [void](Seed 'planned'); Add-Rule 'newbox' ' status' -Seq @((St 'idle'), (St 'running'), (St 'failed'))
  $r = Run-Move @('copy'); Eq $r.Code 1 'transfer failed'; Eq (State).phase 'planned' 'phase unchanged'; Eq (Count 'newbox adopt') 0
  Reset-World; [void](Seed 'planned'); Add-Rule 'newbox' ' status' -Seq @((St 'idle'), (St 'idle'))
  $r = Run-Move @('copy'); Eq $r.Code 1 'never started'; Eq (Count '^newbox status') 5 'tolerates 3 idle polls, stops at the 4th'
  Reset-World; [void](Seed 'planned'); Add-Rule 'newbox' ' status' -Seq @((St 'idle'), (St 'x' 0 255), (St 'x' 0 255), (St 'done'))
  $r = Run-Move @('copy'); Eq $r.Code 0 'a lost ssh while polling is retried'
  Reset-World; [void](Seed 'planned'); Add-Rule 'newbox' ' status' -Seq @((St 'idle'), (St 'x' 0 255))
  $r = Run-Move @('copy'); Eq $r.Code 1 'a machine that never answers again stops after 12 tries'; Eq (Count '^newbox status') 13
  Reset-World; [void](Seed 'planned'); Add-Rule 'newbox' ' status' -Seq @((St 'idle' 2))
  $r = Run-Move @('copy'); Eq $r.Code 65; Ok ($r.Text -match 'dst-running') 'dst-running'; Eq (Count ' dump') 0
  $r = Run-Move @('copy'); Eq $r.Code 65 'still refused'
}
T 'copy: a failing step returns its code, stops there, and phase is not advanced (tunnels 65, init 1, adopt 70)' {
  foreach ($c in @(@('tunnels', 65, 'contabo'), @('init', 1, 'newbox'), @('adopt', 70, 'newbox'), @('dump', 1, 'contabo'), @('verify', 1, 'newbox'))) {
    Reset-World; [void](Seed 'planned'); Add-Rule $c[2] " $($c[0])" -Code $c[1] -Out @("MOVE error x", "GATE_EXIT $($c[1])")
    $r = Run-Move @('copy'); Eq $r.Code $c[1] "$($c[0])"; Eq (State).phase 'planned' "$($c[0]) phase"
  }
  Reset-World; [void](Seed 'planned'); Add-Rule 'newbox' 'script:bootstrap key' -Out @('MOVE error tool-missing name=rsync') -Code 70
  Eq (Run-Move @('copy')).Code 70 'tool-missing on new'
  Reset-World; [void](Seed 'planned'); Add-Rule 'newbox' 'script:bootstrap key' -Out @('MOVE key exists name=newbox')
  Eq (Run-Move @('copy')).Code 1 'no public key = 1'
  Reset-World; [void](Seed 'planned'); $script:Mf = { param($m) $m.items = @($m.items | Where-Object { $_.id -ne 'gate-lib' }) }; [void](Seed 'planned')
  $r = Run-Move @('copy'); Eq $r.Code 65; Ok ($r.Text -match 'gate-missing')
}
T 'copy: re-run (refresh) from copied and rolled-back; cut_not_before is never lowered; a back-style manifest with no a-record leaves it' {
  Reset-World; $s = Seed 'copied'; Set-MoveProp $s 'cut_not_before' '2026-10-31T00:00:00Z'; Save-MoveState $s
  $r = Run-Move @('copy'); Eq $r.Code 0 $r.Text; Eq (State).cut_not_before '2026-10-31T00:00:00Z' 'never lowered'; Eq (State).phase 'copied'
  Reset-World; [void](Seed 'rolled-back'); Eq (Run-Move @('copy')).Code 0; Eq (State).phase 'copied' 'rolled-back behaves like copied'
  Reset-World; $script:Tunneled = $true; $s = Seed 'copied'; $r = Run-Move @('copy'); Eq (State).cut_not_before $null 'no a-record left (already tunnel) = nothing written'
}

# ============================== cutover ==============================
function Cut-State { Reset-World; $s = Seed 'copied'; $s }
T 'cutover: refused inside the TTL with the wait in minutes; nothing run and no question; later it runs' {
  $s = Cut-State; Set-MoveProp $s 'cut_not_before' '2026-10-29T10:20:30Z'; Save-MoveState $s
  $r = Run-Move @('cutover'); Eq $r.Code 65; Ok ($r.Text -match 'khoảng 21 phút') "minutes: $($r.Text)"; Eq $script:Log.Count 0; Eq $script:Prompts.Count 0
  # a re-plan after routing leaves it, a copy re-run leaves it
  $script:Clock = $script:Clock.AddMinutes(30); Yes
  $r = Run-Move @('cutover'); Eq $r.Code 0 $r.Text
}
T 'cutover: the happy path = the normative sequence; one YES; marks and dst_started written at the right moments; chores done' {
  $s = Cut-State; Yes
  $script:Seen = @{}
  Add-Rule 'newbox' ' start' -Do { $st = State; $script:Seen.StartStarted = $st.dst_started; $script:Seen.StartMark = $st.mark }
  Add-Rule 'newbox' ' switch' -Do { $st = State; $script:Seen.SwitchMark = $st.mark; $script:Seen.SwitchStarted = $st.dst_started }
  Add-Rule 'newbox' ' stop' -Do { $st = State; $script:Seen.StopStarted = $st.dst_started }
  Add-Rule 'contabo' ' freeze' -Do { $st = State; $script:Seen.FreezeMark = $st.mark }
  $global:MoveSaves = New-Object Collections.ArrayList; $origSave = (Get-Item function:Save-MoveState).ScriptBlock
  Set-Item function:Save-MoveState -Value ({ param($S) [void]$global:MoveSaves.Add(@{ Mark = $S.mark; Cut = [bool]$S.answers.cut; Phase = $S.phase }); & $origSave $S }.GetNewClosure())
  try { $r = Run-Move @('cutover') } finally { Set-Item function:Save-MoveState -Value $origSave }
  Eq $r.Code 0 $r.Text
  Ordered @('gh workflow disable deploy.yml -R brooklyn96/autoshopee', '^contabo freeze', '^contabo stop --guards', '^newbox stop', '^newbox prepare', '^newbox status', '^contabo dump', '^newbox transfer --final', '^newbox status', '^newbox adopt', '^newbox restore', '^newbox verify --strict', '^newbox start', '^newbox health', '^newbox switch', '^newbox unfreeze', 'gh secret set DEPLOY_KNOWN_HOSTS -R brooklyn96/BD-Team-Project', 'box:coder ssh config \(read\)', 'box:coder ssh config \(write\)')
  Eq (Count 'gh workflow disable') 1 'only the workflow that was enabled at plan is disabled'; Ok ((Names 'gh workflow') -join ' ' -notmatch 'old\.yml') 'old.yml (disabled by the user) is never touched'
  Eq (Count 'gh workflow enable') 0 'a forward cut leaves the ssh-push workflows disabled'
  Eq $script:Prompts.Count 1 'one YES'
  Eq $script:Seen.StopStarted $false 'dst_started false after the dst stop'; Eq $script:Seen.StartStarted $true 'dst_started true before start'; Eq $script:Seen.SwitchMark 'switching' 'mark switching before switch'; Eq $script:Seen.StartMark 'cutting' 'mark cutting while the apps are being started'; Eq $script:Seen.FreezeMark 'cutting' 'mark cutting at the first step that changes src'
  Eq @($global:MoveSaves | Where-Object { $_.Cut -and -not $_.Mark -and $_.Phase -cne 'cut' }).Count 0 'no saved state has the cut answer with no mark before phase cut (one write)'
  Ok (@($global:MoveSaves | Where-Object { $_.Mark -ceq 'cutting' }).Count -ge 1) 'cutting was saved'; Eq (State).answers.finish $null 'answers.finish reset at the cut'; Eq (State).answers.finish_early $null
  $n = State; Eq $n.phase 'cut'; Eq $n.mark $null; Ok ($n.cut_at -cmatch '\A2026-10-29T10:0\d:\d\dZ\z') 'cut_at'; Eq $n.answers.cut.a 'yes'; Eq $n.dst_started $true
  Ok ($r.Text -match 'MOVE done cutover') 'MOVE done cutover'; Ok ($r.Text -match 'brooklyn96/autoshopee \(deploy.yml\)') 'final report names the disabled workflow'; Ok ($r.Text -notmatch 'old\.yml') 'not the user-disabled one'
  Ok ($r.Text.Contains('Chuyển tất cả ứng dụng sang máy mới bây giờ? Mọi ứng dụng sẽ cùng tạm dừng một lần, khoảng 2 phút. Nếu có lỗi trước khi chuyển xong, máy cũ tự chạy lại như cũ. Các workflow GitHub deploy thẳng vào máy cũ qua SSH sẽ bị tắt. (Có/Không)')) 'Q-cut verbatim'
  # chores: the secret is the dst's host key line, on stdin; the aliases follow
  $gi = @($script:GhIn | Where-Object { $_ })[0]; Eq $gi "$NewAddr ssh-ed25519 $KeyNew" 'DEPLOY_KNOWN_HOSTS value'; Ok ((Names 'gh secret set') -join ' ' -notmatch [regex]::Escape($KeyNew)) 'the value is never in argv'
  Eq (Get-MoveReachOld 'contabo') 'contabo-old'; Ok ($r.Text -notmatch $CANARY) 'no canary'
  # phase cut + cutover again = chores only, idempotent, no question
  $script:Log.Clear(); $r = Run-Move @('cutover'); Eq $r.Code 0; Eq (Count '^(contabo|newbox) ') 0 'no gate call'; Eq $script:Prompts.Count 0; Ok ($r.Text -match 'MOVE done cutover')
}
T 'cutover: a failure in steps 2-10 rolls back (dst stop, src start --connectors, unfreeze, workflows, phase, health) and keeps old as it was' {
  foreach ($failing in @(@(' freeze', 1, 'contabo'), @(' dump', 1, 'contabo'), @(' transfer --final', 1, 'newbox'), @(' adopt', 1, 'newbox'), @(' verify --strict', 1, 'newbox'), @(' health', 69, 'newbox'), @(' switch', 1, 'newbox'))) {
    $s = Cut-State; Yes
    Add-Rule $failing[2] ($failing[0] + '$') -Code $failing[1] -Out @('MOVE error x')
    $r = Run-Move @('cutover'); Eq $r.Code $failing[1] "$($failing[0]) code"
    $n = State; Eq $n.phase 'rolled-back' "$($failing[0]) phase"; Eq $n.mark $null; Eq $n.dst_started $false; Eq $n.answers.cut $null 'the answer is cleared'
    Ordered @('^newbox stop', '^contabo start --connectors', '^contabo unfreeze', 'gh workflow enable deploy.yml -R brooklyn96/autoshopee', '^contabo health')
    Eq (Count 'gh workflow enable') 1 'only the workflow that was enabled before the move comes back'; Ok ((Names 'gh workflow') -join ' ' -notmatch 'old\.yml') 'old.yml untouched'
    Eq (Count 'gh secret set') 0 'no chores'; Eq (Count 'box:') 0 'no alias change'; Eq (Get-MoveReachOld 'contabo') 'contabo'
    Ok ($r.Text -match 'rolled_back') 'rolled_back reported'
  }
}
T 'cutover: after a rollback the next cutover asks again and is refused without YES (nothing runs); with YES it runs' {
  $s = Cut-State; Yes
  Add-Rule 'newbox' ' health' -N 1 -Code 69 -Out @('MOVE error health app=x')
  Eq (Run-Move @('cutover')).Code 69; Eq (State).phase 'rolled-back'
  $script:Log.Clear(); $r = Run-Move @('cutover'); Eq $r.Code 65 'no answer = refused'; Eq $script:Log.Count 0 'nothing ran'; Eq $script:Prompts.Count 1 'asked again'
  $script:Answers.Enqueue('yes'); $r = Run-Move @('cutover'); Eq $r.Code 65 'only the typed word YES counts'
  Yes; $r = Run-Move @('cutover'); Eq $r.Code 0 $r.Text; Eq (State).phase 'cut'; Eq (State).answers.cut.a 'yes'
}
T 'cutover: a via=back run needs answers.back; after its rollback `back` without YES is refused' {
  Reset-World; $s = Seed 'copied' 'back' 'back'
  $r = Run-Move @('back'); Eq $r.Code 65; Eq $script:Log.Count 0; Eq $script:Prompts.Count 1
  Yes; Add-Rule 'contabo' ' health' -N 1 -Code 69 -Out @('MOVE error health app=x')   # dst of a back run is old
  $r = Run-Move @('back'); Eq $r.Code 69 $r.Text; $n = State; Eq $n.phase 'rolled-back'; Eq $n.answers.back $null 'answer cleared'
  Ordered @('^contabo stop', '^newbox start --connectors', '^newbox unfreeze', '^newbox health')   # src of a back run is new
  Eq (Count 'gh workflow') (Count 'gh workflow disable') 'a back run never re-enables the ssh-push workflows on rollback'
  $script:Log.Clear(); $r = Run-Move @('back'); Eq $r.Code 65 'rolled-back via back: back without YES refused'; Eq $script:Log.Count 0
  $r = Run-Move @('cutover'); Eq $r.Code 65 'cutover too'; Eq $script:Log.Count 0
}
T 'cutover: Q-back text follows the direction (back: "Quay lại máy cũ?", forward again: "Chuyển lại sang máy mới?")' {
  Reset-World; [void](Seed 'copied' 'back' 'back'); $r = Run-Move @('cutover'); Ok ($r.Text.Contains('Quay lại máy cũ? Dữ liệu ghi ở máy mới sẽ được chép ngược về máy cũ; mọi ứng dụng cùng tạm dừng một lần, khoảng 2 phút. (Có/Không)')) "Q-back: $($r.Text)"
  Reset-World; [void](Seed 'copied' 'fwd' 'back'); $r = Run-Move @('cutover'); Ok ($r.Text.Contains('sang máy mới')) 'forward again says sang máy mới'
}
T 'rollback: dst unreachable and dst_started false = warn dst-unreachable, old comes back (phase rolled-back, health)' {
  $s = Cut-State; Yes
  $script:Rules.Clear(); Add-Rule 'newbox' ' transfer --final' -Code 1 -Out @('MOVE error rsync-failed'); Add-Rule 'newbox' ' stop$' -Code 255 -N -1; Add-Rule 'newbox' ' stop$' -N 1
  $script:Down = $null
  $r = Run-Move @('cutover'); $n = State
  # step (5) stop succeeded (dst_started false); the rollback stop fails 3 times
  Eq (Count '^newbox stop$') 4 'one stop in step 5 + three tries in the rollback'
  Ok ($r.Text -match 'INV warn dst-unreachable') 'warned'; Eq $n.phase 'rolled-back'; Eq $n.mark $null; Eq $n.dst_started $false
  Ordered @('^contabo start --connectors', '^contabo unfreeze', '^contabo health'); Eq $r.Code 1
}
T 'rollback: dst_started true and dst unreachable = exit 70, mark rolling-back kept, old not started; dst back -> cutover finishes it' {
  $s = Cut-State; Yes
  $script:Rules.Clear(); Add-Rule 'newbox' ' health' -Code 69 -Out @('MOVE error health app=x'); Add-Rule 'newbox' ' stop$' -Code 255 -N 3; Add-Rule 'newbox' ' stop$' -N 1   # step (5) passes once, the rollback's three tries fail
  $r = Run-Move @('cutover'); Eq $r.Code 70 $r.Text
  $n = State; Eq $n.mark 'rolling-back' 'mark kept'; Eq $n.dst_started $true; Eq $n.phase 'copied'
  Eq (Count '^contabo start') 0 'old not started'; Ok ($r.Text -match '70') 'needs a human'
  # dst is back: cutover finishes the rollback; no question
  $script:Rules.Clear(); $script:Log.Clear()
  $r = Run-Move @('cutover'); Eq $r.Code 1 $r.Text; $n = State; Eq $n.phase 'rolled-back'; Eq $n.mark $null; Eq $n.dst_started $false
  Ordered @('^newbox stop', '^contabo start --connectors', '^contabo unfreeze', '^contabo health'); Eq $script:Prompts.Count 0 'no question at a resume'
}
T 'rollback: old cannot be started after 3 tries = exit 70 with the mark kept; a failed health at the end = 70, phase stays rolled-back' {
  $s = Cut-State; Yes
  Add-Rule 'newbox' ' health' -Code 69 -Out @('MOVE error health')
  Add-Rule 'contabo' ' start --connectors' -Code 1
  $r = Run-Move @('cutover'); Eq $r.Code 70; Eq (Count 'start --connectors') 3 'three tries'; Eq (State).mark 'rolling-back'
  $s = Cut-State; Yes
  Add-Rule 'newbox' ' health' -Code 69 -Out @('MOVE error health'); Add-Rule 'contabo' ' health' -Code 69 -Out @('MOVE error health')
  $r = Run-Move @('cutover'); Eq $r.Code 70; Eq (State).phase 'rolled-back'; Eq (State).mark $null
}
T 'cutover: resume at step 10 after a kill (mark switching): only switch, unfreeze and the chores; no question, no stop' {
  Reset-World; $s = Seed 'copied' 'fwd' 'plan' 'switching'; Set-MoveProp $s 'dst_started' $true; Save-MoveState $s
  $r = Run-Move @('cutover'); Eq $r.Code 0 $r.Text
  Ordered @('^newbox switch', '^newbox unfreeze', 'gh secret set'); Eq (Count '^(contabo|newbox) (freeze|stop|dump|transfer|adopt|start)') 0 'nothing earlier re-run'; Eq $script:Prompts.Count 0
  Eq (State).phase 'cut'
  # a switch failure on resume rolls back
  Reset-World; $s = Seed 'copied' 'fwd' 'plan' 'switching'; Set-MoveProp $s 'dst_started' $true; Save-MoveState $s
  Add-Rule 'newbox' ' switch' -Code 1 -Out @('MOVE error switch-failed host=a')
  $r = Run-Move @('cutover'); Eq $r.Code 1; Eq (State).phase 'rolled-back'; Ordered @('^newbox stop', '^contabo start --connectors')
}
T 'cutover: 75 waits the smallest retry_s and runs the same step again; past cap_s it rolls back (exit 75)' {
  $s = Cut-State; Yes
  Add-Rule 'contabo' ' stop --guards' -N 2 -Code 75 -Out @('MOVE wait guard=busy app=a retry_s=30 cap_s=600', 'MOVE wait guard=deploy-running app=b retry_s=10 cap_s=0', 'GATE_EXIT 75')
  $r = Run-Move @('cutover'); Eq $r.Code 0 $r.Text
  Eq (Count '^contabo stop --guards') 3 'tried again'; Eq (Count '^contabo freeze') 1 'freeze not repeated'; Eq (@($script:Sleeps | Where-Object { $_ -eq 10 }).Count -ge 2) $true 'slept the smallest retry_s'
  # never go: the cap (1800 s) is counted from the first try of freeze
  $s = Cut-State; Yes; Set-MoveProp $s 'cap_s' 100; Save-MoveState $s
  Add-Rule 'contabo' ' stop --guards' -Code 75 -Out @('MOVE wait guard=busy app=a retry_s=40 cap_s=600', 'GATE_EXIT 75')
  $r = Run-Move @('cutover'); Eq $r.Code 75 $r.Text; Eq (State).phase 'rolled-back'; Eq (Count '^contabo stop --guards') 4 'tries until the cap (0, 40, 80 s, then 120 s is past 100)'
  Ordered @('^newbox stop', '^contabo start --connectors', '^contabo unfreeze'); Ok ($r.Text -match 'quá hạn') 'says the cap'
  # freeze busy (75) too
  $s = Cut-State; Yes
  Add-Rule 'contabo' ' freeze' -N 1 -Code 75 -Out @('MOVE wait guard=deploy-running app=a retry_s=10 cap_s=0', 'GATE_EXIT 75')
  Eq (Run-Move @('cutover')).Code 0
}
T 'cutover: ssh-push workflows: gh failure or a run that never ends (900 s) stops before the freeze and rolls back; gate-push is not disabled' {
  $s = Cut-State; Yes; $script:GhFail = @{ '^workflow disable' = 1 }
  $r = Run-Move @('cutover'); Ok ($r.Code -ne 0) 'disable failed'; Eq (Count '^contabo freeze') 0 'never froze'; Eq (State).phase 'rolled-back'
  $script:GhFail = @{}
  $s = Cut-State; Yes
  $orig = (Get-Item function:gh).ScriptBlock
  Set-Item function:gh -Value { $t = (@($args | ForEach-Object { [string]$_ }) -join ' '); [void]$script:Log.Add("gh $t"); $global:LASTEXITCODE = 0; if ($t -match '^run list ') { return @('[{"databaseId":1}]') }; @() }
  try { $r = Run-Move @('cutover'); Ok ($r.Code -ne 0) 'busy forever'; Eq (Count '^contabo freeze') 0; Ok (@($script:Sleeps | Where-Object { $_ -eq 10 }).Count -ge 90) '900 s of 10 s polls' } finally { Set-Item function:gh -Value $orig }
}
T 'cutover: a failure of the last step (unfreeze) does not roll back; mark switching is kept and a re-run resumes' {
  $s = Cut-State; Yes
  Add-Rule 'newbox' ' unfreeze' -N 1 -Code 1 -Out @('MOVE error x')
  $r = Run-Move @('cutover'); Eq $r.Code 1; Eq (State).mark 'switching'; Eq (State).phase 'copied'; Eq (Count '^contabo start --connectors') 0 'no rollback'
  $r = Run-Move @('cutover'); Eq $r.Code 0 $r.Text; Eq (State).phase 'cut'
}
T 'workflow disabled before the move stays disabled after a rollback; the others come back' {
  $s = Cut-State; Yes; Add-Rule 'newbox' ' adopt' -Code 1 -Out @('MOVE error x')
  [void](Run-Move @('cutover'))
  Eq (Count 'gh workflow disable deploy.yml -R brooklyn96/autoshopee') 1; Eq (Count 'gh workflow enable deploy.yml -R brooklyn96/autoshopee') 1; Eq (Count 'old\.yml') 0 'never mentioned'
}

# ============================== aliases ==============================
function Cfg-Text { [IO.File]::ReadAllText((Join-Path (Join-Path $Home2 '.ssh') 'config')) }
function Alias-State([string]$Dir = 'fwd') { $s = Seed 'cut' $Dir 'plan'; $s }
T 'aliases: the forward rewrite by content: Host contabo -> new, Host contabo-old keeps the original, one safety copy, twice = one change' {
  Reset-World; $s = Alias-State; $orig = Cfg-Text
  Eq (Set-MoveLaptopAlias $s) 0
  $t = Cfg-Text
  Eq ([regex]::Matches($t, '(?m)^Host contabo-old\s*$')).Count 1 'one -old block'; Eq ([regex]::Matches($t, '(?m)^Host contabo\s*$')).Count 1 'one Host contabo'
  Ok ($t -match "(?s)Host contabo\n  HostName $NewAddr\n  User root\n  IdentityFile ~/.ssh/newbox_key\n  HostKeyAlias newbox\n\nHost contabo-old\n  HostName $OldAddr\n  User root\n  IdentityFile ~/.ssh/contabo_key\n") "layout: $t"
  Ok ($t -match '(?s)Host newbox\n  HostName 198\.51\.100\.20') 'the new block is untouched'
  $bak = Get-MovePath ('ssh_config.' + $s.move_id + '.bak'); Eq ([IO.File]::ReadAllText($bak)) $orig 'safety copy = the original bytes'; Eq (State).backups.ssh_config $bak
  Ok ([IO.File]::ReadAllText((Join-Path (Join-Path $Home2 '.ssh') 'known_hosts')).Contains("newbox ssh-ed25519 $KeyNew")) 'the HostKeyAlias name has the key'
  $after = Cfg-Text; Eq (Set-MoveLaptopAlias $s) 0; Eq (Cfg-Text) $after 'second run: no change'; Eq (Get-MoveReachOld 'contabo') 'contabo-old' 'Reach-Old after the rewrite, with no state write needed'
  Eq (([IO.File]::ReadAllText((Join-Path (Join-Path $Home2 '.ssh') 'known_hosts')) -split "`n" | Where-Object { $_ -match 'newbox ssh-ed25519' }).Count) 1 'known_hosts line added once'
  Eq ([IO.File]::ReadAllText($bak)) $orig 'the safety copy is never rewritten'
}
T 'aliases: an unrelated Host block added after the cut survives the reverse; the reverse twice = one change; Reach-Old after the reverse = contabo' {
  Reset-World; $s = Alias-State; [void](Set-MoveLaptopAlias $s)
  [IO.File]::AppendAllText((Join-Path (Join-Path $Home2 '.ssh') 'config'), "`nHost box7`n  HostName 10.0.0.7`n  User dev`n", $utf8)
  $s.dir = 'back'; Save-MoveState $s
  Eq (Set-MoveLaptopAlias $s) 0
  $t = Cfg-Text
  Ok ($t -notmatch 'contabo-old') 'the -old block is gone'; Ok ($t -match "(?s)Host contabo\n  HostName $OldAddr\n  User root\n  IdentityFile ~/.ssh/contabo_key\n") 'Host contabo rebuilt from the -old directives'
  Ok ($t.Contains("Host box7`n  HostName 10.0.0.7`n  User dev`n")) 'box7 survived byte for byte'; Ok ($t -match '(?s)Host newbox\n  HostName 198\.51\.100\.20') 'newbox untouched'
  Eq (Get-MoveReachOld 'contabo') 'contabo' 'Reach-Old after the reverse'
  $once = Cfg-Text; Eq (Set-MoveLaptopAlias $s) 0; Eq (Cfg-Text) $once 'reverse twice: one change'
  Ok (Test-Path (Get-MovePath ('ssh_config.' + $s.move_id + '.bak'))) 'the safety copy stays as a file'
}
T 'aliases: pure rewrite edge cases: no Host block, shared Host line, CRLF file, Match block, a new block without HostName' {
  $r = Convert-MoveSshFwd "Host other`n  User x`n" 'contabo' @('  HostName 1.2.3.4') 'newbox' $false; Eq $r.Why 'no-block'; Eq $r.Changed $false
  $r = Convert-MoveSshFwd "Host contabo other`n  User x`n" 'contabo' @('  HostName 1.2.3.4') 'newbox' $false; Eq $r.Why 'shared-block'
  $r = Convert-MoveSshFwd "Host contabo`r`n  HostName 9.9.9.9`r`n" 'contabo' @('  HostName 1.2.3.4') 'newbox' $false; Ok ($r.Text.Contains("`r`n") -and -not $r.Text.Replace("`r`n", '').Contains("`n")) 'CRLF stays CRLF'
  $r = Convert-MoveSshFwd "Host contabo`n  HostName 9.9.9.9`nMatch host x`n  User y`n" 'contabo' @('  HostName 1.2.3.4') 'newbox' $false; Ok ($r.Text.Contains("Match host x`n  User y")) 'the Match block is not swallowed'
  $nd = Get-MoveNewDirectives "Host newbox`n  User root`n  Port 2222`n" 'newbox' '198.51.100.20'; Eq $nd.Lines[0] '  HostName 198.51.100.20' 'HostName added when the block has none'; Eq @($nd.Lines).Count 3
  $nd = Get-MoveNewDirectives "Host other`n" 'newbox' '1.1.1.1'; Ok ($nd.Err.Length -gt 0) 'missing new block'
  $r = Convert-MoveSshFwd "Host contabo`n  HostName 9.9.9.9`n  HostKeyAlias zzz`n" 'contabo' @('  HostName 1.2.3.4', '  HostKeyAlias stale') 'newbox' $false
  Eq ([regex]::Matches($r.Text, 'HostKeyAlias')).Count 2 'one HostKeyAlias in the rewritten block (the new one) + the original in -old'; Ok ($r.Text -notmatch 'stale') 'the new block alias is replaced'
  $r = Convert-MoveSshBack "Host contabo-old`n  HostName 9.9.9.9`n" 'contabo'; Ok ($r.Changed -and $r.Text.StartsWith('Host contabo')) 'only a -old block: renamed back'
}
T 'aliases: no Host contabo block in the laptop config = exit 1 with a clear line, nothing written; coder chore too' {
  Reset-World; $s = Alias-State; [IO.File]::WriteAllText((Join-Path (Join-Path $Home2 '.ssh') 'config'), "Host newbox`n  HostName $NewAddr`n", $utf8)
  $r = @(& { Set-MoveLaptopAlias $s } 6>&1); Eq ($r | Where-Object { $_ -isnot [Management.Automation.InformationRecord] }) 1; Ok ((($r | Where-Object { $_ -is [Management.Automation.InformationRecord] }) -join ' ') -match 'Host contabo') 'says which block'
  Ok (-not (Test-Path (Get-MovePath ('ssh_config.' + $s.move_id + '.bak')))) 'no safety copy for nothing'
}
T 'aliases: the coder box through Invoke-BoxScript: same shape, its IdentityFile kept, known_hosts line, twice = no write; unreachable = warning only' {
  Reset-World; $s = Alias-State
  Eq (Set-MoveCoderAlias $s) 0
  $c = $script:Coder.Config
  Ok ($c -match "(?s)Host contabo\n  HostName $NewAddr\n  User root\n  IdentityFile ~/.ssh/coder_key\n  HostKeyAlias newbox\n\nHost contabo-old\n  HostName $OldAddr\n  User root\n  IdentityFile ~/.ssh/coder_key\n") "coder config: $c"
  Ok ($script:Coder.Known.Contains("newbox ssh-ed25519 $KeyNew")) 'coder known_hosts has new'
  Eq (State).backups.coder_ssh_config ('~/.ssh/config.fcode-move.' + $s.move_id + '.bak'); Eq (State).backups.coder_known_hosts ('~/.ssh/known_hosts.fcode-move.' + $s.move_id + '.bak')
  $script:Log.Clear(); $before = $script:Coder.Config; Eq (Set-MoveCoderAlias $s) 0
  Eq (Count 'box:coder ssh config \(write\)') 1 'the known_hosts content check still writes only when absent'; Eq $script:Coder.Config $before
  # reverse
  $s.dir = 'back'; Save-MoveState $s; Eq (Set-MoveCoderAlias $s) 0
  Ok ($script:Coder.Config -notmatch 'contabo-old' -and $script:Coder.Config -match "HostName $OldAddr") 'coder reverse by content'
  $script:Log.Clear(); Eq (Set-MoveCoderAlias $s) 0; Eq (Count 'write') 0 'reverse twice: no write'
  # unreachable
  Reset-World; $s = Alias-State; $script:Coder.Up = $false
  $r = @(& { Set-MoveCoderAlias $s } 6>&1); Eq ($r | Where-Object { $_ -isnot [Management.Automation.InformationRecord] }) 0; Ok ((($r | Where-Object { $_ -is [Management.Automation.InformationRecord] }) -join ' ') -match 'INV warn coder-unreachable') 'warn'
  # a coder without the Host block
  Reset-World; $s = Alias-State; $script:Coder.Config = "Host other`n  User x`n"; $script:Log.Clear(); Eq (Set-MoveCoderAlias $s) 0; Eq (Count 'write') 0 'nothing to rewrite'
}
T 'aliases: killed between the alias rewrite and the state write: a re-run of cutover (phase cut) completes the chores without redoing them' {
  Reset-World; $s = Alias-State; [void](Set-MoveLaptopAlias $s)   # the rewrite happened; pretend the state write (backups) was lost
  $s2 = State; Set-MoveProp $s2.backups 'ssh_config' $null; Save-MoveState $s2
  $before = Cfg-Text
  $r = Run-Move @('cutover'); Eq $r.Code 0 $r.Text; Eq (Cfg-Text) $before 'config untouched by the re-run'; Eq (Count '^(contabo|newbox) ') 0
}

# ============================== back ==============================
T 'back: Q-back, a new run (new move_id, dir flipped, via back, repos/backups/cut_at kept), plan with the saved map and manifest as from; its copy and cutover with src and dst swapped' {
  Reset-World; $script:Tunneled = $true; $s = Seed 'cut'; Set-MoveProp $s 'cut_at' '2026-10-28T10:00:00Z'; Set-MoveProp $s 'cut_not_before' '2026-10-28T09:00:00Z'; Set-MoveProp $s 'dst_started' $true; Save-MoveState $s
  [IO.File]::WriteAllText((Get-MovePath 'move-map.json'), '{"schema":1,"map":[],"exclude":[]}', $utf8)
  [void](Set-MoveLaptopAlias $s)   # the forward chores happened: Reach-Old = contabo-old
  $savedManifest = (Read-MoveManifestFile).Text
  Yes
  $r = Run-Move @('back'); Eq $r.Code 0 $r.Text
  $n = State
  Ok ($n.move_id -cne $s.move_id) 'new move_id'; Eq $n.dir 'back'; Eq $n.via 'back'; Eq $n.phase 'cut' 'ran to its own cut'; Eq $n.cut_not_before $null; Eq $n.old.alias 'contabo'; Eq $n.new.alias 'newbox'
  Eq @($n.repos).Count 3; Eq $n.answers.back.a 'yes'; Eq $n.answers.cut $null; Ok ($n.cut_at -cne '2026-10-28T10:00:00Z') 'its own cut_at'
  Ok ($r.Text.Contains('Quay lại máy cũ? Dữ liệu ghi ở máy mới sẽ được chép ngược về máy cũ')) 'Q-back verbatim'; Eq $script:Prompts.Count 1 'one YES for the whole back'
  $pi = $script:GateIn | Where-Object { $_.Verb -ceq 'plan' }; Eq $pi.Host 'newbox' 'plan runs on the new src'; Ok ($pi.Stdin -match '"map":\{"schema":1,"map":\[\]') 'saved map'; Ok ($pi.Stdin.Contains($savedManifest.Trim())) 'the saved manifest as from'
  Ordered @('^contabo(-old)? script:preflight', 'script:TCP', '^newbox plan$', '^newbox manifest$', 'script:bootstrap key', '^newbox tunnels', '^newbox manifest', 'init dst', 'init src', 'prepare', 'dump', '^newbox transfer', 'adopt', 'restore', 'verify', '^newbox freeze', '^newbox stop --guards', '^contabo-old stop', 'contabo-old start|contabo-old health', 'gh secret set')
  Eq (Count 'gh secret list') 0 'no push scan in a back run'; Eq (Count 'gh workflow') (Count 'gh workflow disable') 'workflows only disabled, not re-enabled'
  $io = $script:GateIn | Where-Object { $_.Verb -ceq 'init' }; Eq (@($io | Where-Object { $_.Host -like 'contabo*' })[0].Rest) 'dst' 'old is dst'; Eq (@($io | Where-Object { $_.Host -ceq 'newbox' })[0].Rest) 'src' 'new is src'
  Eq (@($script:GhIn | Where-Object { $_ })[0]) "$OldAddr ssh-ed25519 $KeyOld" 'DEPLOY_KNOWN_HOSTS goes back to old'
  Eq (Get-MoveReachOld 'contabo') 'contabo' 'the reverse alias rewrite ran'; Ok ($script:Coder.Config -notmatch 'contabo-old') 'and the coder one'
  Eq (Count '^(contabo|contabo-old) tunnels') 0
}
T 'back: a refused plan leaves the cut run exactly as it was; no YES = nothing' {
  Reset-World; $script:Tunneled = $true; $s = Seed 'cut'; $bytes = [IO.File]::ReadAllText((Get-MovePath 'state.json'))
  $r = Run-Move @('back'); Eq $r.Code 65; Eq $script:Log.Count 0
  Yes; Add-Rule 'newbox' ' plan$' -Code 65 -Out @('INV refuse disk', 'GATE_EXIT 65')
  $r = Run-Move @('back'); Eq $r.Code 65; Eq ([IO.File]::ReadAllText((Get-MovePath 'state.json'))) $bytes 'state file unchanged'
  Eq (Read-MoveManifestFile).Obj.move_id $s.move_id 'the saved manifest is the cut run''s'
  # the back-run plan does not check the target
  Reset-World; $script:Tunneled = $true; [void](Seed 'cut'); Yes; $script:Pf['contabo'] = @('INV host os=ubuntu-24.04 arch=x86_64 cpus=2 mem_mb=4000 swap_mb=0 tz=UTC node_major=22', 'INV disk mount=/ used_mb=1 free_mb=900000', 'INV target moveid=- peer=- projects=9', 'INV target-file /root/.cloudflared/config.yml')
  $r = Run-Move @('back'); Eq $r.Code 0 $r.Text
}
T 'back: re-running `back` continues that run by the table (planned: copy then cutover; copied: cutover); forward again after back works' {
  Reset-World; $script:Tunneled = $true; [void](Seed 'planned' 'back' 'back'); Yes
  $r = Run-Move @('back'); Eq $r.Code 0 $r.Text; Eq (State).phase 'cut'; Ordered @('script:bootstrap key', '^newbox freeze')
  Reset-World; $script:Tunneled = $true; [void](Seed 'copied' 'back' 'back'); Yes
  $r = Run-Move @('back'); Eq $r.Code 0 $r.Text; Eq (Count 'bootstrap') 0 }
T 'back: a second back (phase cut, dir back) starts a forward run: dir fwd, via back, src old' {
  Reset-World; $script:Tunneled = $true; $s = Seed 'cut' 'back' 'back'; Yes
  $r = Run-Move @('back'); Eq $r.Code 0 $r.Text; $n = State; Eq $n.dir 'fwd'; Eq $n.via 'back'; Eq $n.phase 'cut'; Ok ($r.Text.Contains('Chuyển lại sang máy mới?')) 'text says sang máy mới'
  $pi = $script:GateIn | Where-Object { $_.Verb -ceq 'plan' }; Ok ($pi.Host -like 'contabo*') 'plan on old (src)'
  # forward again: the alias is rewritten again (the back run removed the -old block)
  Eq (Get-MoveReachOld 'contabo') 'contabo-old'
}

# ============================== finish, status ==============================
T 'finish (phase cut): Q-finish verbatim, 72 h second question, src then dst with the peer alias, phase finished' {
  Reset-World; $s = Seed 'cut'; Set-MoveProp $s 'cut_at' '2026-10-29T08:00:00Z'; Save-MoveState $s; [void](Set-MoveLaptopAlias $s)
  Yes; $r = Run-Move @('finish'); Eq $r.Code 65 'the second question is not answered'; Eq $script:Log.Count 0 'nothing ran'; Eq $script:Prompts.Count 2
  Ok ($r.Text.Contains('Máy cũ có thể bỏ được chưa? Lệnh sẽ tắt hẳn ứng dụng trên máy cũ và xoá khoá chuyển máy. Sau bước này KHÔNG quay lại được nữa. Huỷ gói VPS cũ ở trang Contabo do bạn tự làm. (Có/Không)')) 'Q-finish'
  Yes; Yes; $r = Run-Move @('finish'); Eq $r.Code 0 $r.Text
  Ok ($r.Text.Contains('Mới chuyển chưa đủ 72 giờ. Vẫn bỏ máy cũ ngay? (Có/Không)')) 'second question'
  Ordered @("^contabo-old finish newbox$", '^newbox finish contabo$')   # old via Reach-Old, with the new alias; new with the old alias
  $n = State; Eq $n.phase 'finished'; Eq $n.answers.finish.a 'yes'; Eq $n.answers.finish_early.a 'yes'
  $r = Run-Move @('finish'); Eq $r.Code 0 'finished: prints done'; Ok ($r.Text -match 'finished'); Eq $script:Log.Count 0
  # 72 h over: one question only
  Reset-World; $s = Seed 'cut'; Set-MoveProp $s 'cut_at' '2026-10-26T08:00:00Z'; Save-MoveState $s; Yes
  $r = Run-Move @('finish'); Eq $r.Code 0 $r.Text; Eq $script:Prompts.Count 1
  # a killed finish does not ask again
  Reset-World; $s = Seed 'cut'; Set-MoveProp $s 'cut_at' '2026-10-26T08:00:00Z'; Yes; Set-MoveProp $s.answers 'finish' (New-MoveAnswer); Save-MoveState $s; Add-Rule 'newbox' ' finish' -N 1 -Code 1
  $r = Run-Move @('finish'); Eq $r.Code 1 'dst finish failed'; Eq (State).phase 'cut'; $script:Answers.Clear(); $r = Run-Move @('finish'); Eq $r.Code 0 $r.Text; Eq $script:Prompts.Count 0 'answer remembered'
}
T 'finish (back run): src new then dst old; the ssh-push workflows that were enabled come back (dst is old)' {
  Reset-World; $s = Seed 'cut' 'back' 'back'; Set-MoveProp $s 'cut_at' '2026-10-20T08:00:00Z'; Save-MoveState $s; Yes
  $r = Run-Move @('finish'); Eq $r.Code 0 $r.Text
  Ordered @('^newbox finish contabo$', '^contabo finish newbox$', 'gh workflow enable deploy.yml -R brooklyn96/autoshopee'); Eq (Count 'gh workflow enable') 1; Ok ((Names 'gh workflow') -join ' ' -notmatch 'old\.yml') 'old.yml never'
}
T 'finish (abandon): the abandon text verbatim with the running machine; both machines get finish; no-move and 127 count as done; workflows come back when src is old' {
  Reset-World; [void](Seed 'planned')
  Add-Rule 'newbox' ' finish' -Code 127 -Out @('bash: fcode-deploy-gate: command not found')
  Add-Rule 'contabo' ' finish' -Code 65 -Out @('MOVE error no-move', 'GATE_EXIT 65')
  Yes; $r = Run-Move @('finish'); Eq $r.Code 0 $r.Text
  Ok ($r.Text.Contains('Huỷ lần chuyển này? Ứng dụng vẫn chạy ở máy contabo; khoá chuyển máy và file tạm bị xoá. Máy mới vẫn giữ bản sao dữ liệu và mật khẩu của các ứng dụng (đã tắt). Nếu không dùng máy mới nữa, hãy xoá hoặc cài lại máy đó. (Có/Không)')) 'abandon text'
  Ordered @('^contabo finish newbox$', '^newbox finish contabo$', 'gh workflow enable deploy.yml -R brooklyn96/autoshopee'); Eq (State).phase 'finished'
  # a real failure on one machine is not "done"
  Reset-World; [void](Seed 'copied'); Add-Rule 'newbox' ' finish' -Code 70 -Out @('MOVE error x'); Yes
  $r = Run-Move @('finish'); Eq $r.Code 70; Eq (State).phase 'copied'
  # no YES = nothing
  Reset-World; [void](Seed 'rolled-back'); $r = Run-Move @('finish'); Eq $r.Code 65; Eq $script:Log.Count 0
  # abandoning a back run: workflows are not re-enabled (src is new)
  Reset-World; [void](Seed 'planned' 'back' 'back'); Yes; $r = Run-Move @('finish'); Eq $r.Code 0; Eq (Count 'gh workflow') 0
}
T 'status: no state = a hint (exit 0); with a state the phase and both machines (old through Reach-Old); a dead machine is shown, not fatal' {
  Reset-World; $r = Run-Move @('status'); Eq $r.Code 0; Ok ($r.Text -match 'Chưa có lần chuyển') 'hint'; Eq $script:Log.Count 0
  $s = Seed 'cut'; [void](Set-MoveLaptopAlias $s)
  $r = Run-Move @('status'); Eq $r.Code 0; Ok ($r.Text -match 'giai đoạn=cut'); Ordered @('^contabo-old status$', '^newbox status$'); Ok ($r.Text -match 'MOVE state')
  $script:Down = 'newbox'; $r = Run-Move @('status'); Eq $r.Code 0; Ok ($r.Text -match 'không đọc được')
}

# ============================== round 2 (review findings) ==============================
T 'cutover: transfer --final that finds a copy transfer still RUNNING waits for it, then runs --final again and polls that' {
  $s = Cut-State; Yes
  Add-Rule 'newbox' ' transfer --final' -Seq @(@{ Out = @('MOVE transfer state=running items_done=1 items_total=3 unit=fcode-move-transfer'); Code = 0 }, @{ Out = @('MOVE transfer state=started items_done=0 items_total=3 unit=fcode-move-transfer'); Code = 0 })
  Add-Rule 'newbox' ' status' -Seq @((St 'done'), (St 'running'), (St 'done'), (St 'running'), (St 'done'))
  $r = Run-Move @('cutover'); Eq $r.Code 0 $r.Text
  Eq (Count '^newbox transfer --final') 2 'the final pass is started after the old one ended'
  Ordered @('^contabo dump', '^newbox transfer --final', '^newbox status', '^newbox status', '^newbox transfer --final', '^newbox status', '^newbox status', '^newbox adopt')
  Eq (Count '^newbox status') 5 'hold check + 2 + 2 polls'
  # a non-final copy that is running is the same state, but a failed old unit stops the cutover (and rolls back)
  $s = Cut-State; Yes
  Add-Rule 'newbox' ' transfer --final' -Out @('MOVE transfer state=running items_done=1 items_total=3 unit=fcode-move-transfer')
  Add-Rule 'newbox' ' status' -Seq @((St 'done'), (St 'failed'))
  $r = Run-Move @('cutover'); Eq $r.Code 1; Eq (Count '^newbox transfer --final') 1; Eq (State).phase 'rolled-back'
  # copy (not final) never starts a second pass on `running`
  Reset-World; [void](Seed 'planned'); Add-Rule 'newbox' ' transfer$' -Out @('MOVE transfer state=running items_done=1 items_total=3 unit=fcode-move-transfer')
  Add-Rule 'newbox' ' status' -Seq @((St 'idle'), (St 'running'), (St 'done'))
  $r = Run-Move @('copy'); Eq $r.Code 0 $r.Text; Eq (Count '^newbox transfer$') 1
}
T 'plan: the dst disk check counts only the dump space when dst holds this peer''s copy (re-plan after copy) or is old in a back run; a foreign dst keeps the full formula' {
  $own = @('INV host os=ubuntu-24.04 arch=x86_64 cpus=2 mem_mb=4000 swap_mb=0 tz=UTC node_major=22', 'INV disk mount=/ used_mb=1 free_mb=4695', 'INV target moveid=11111111-2222-3333-4444-555555555555 peer=contabo projects=6')
  Reset-World; $script:Pf['newbox'] = $own; $r = Run-Move @('plan', 'newbox'); Eq $r.Code 65; Ok ($r.Text.Contains('INV refuse disk side=dst need_mb=4696 free_mb=4695')) "own: $($r.Text)"
  Reset-World; $script:Pf['newbox'] = @($own | ForEach-Object { $_ -replace 'free_mb=4695', 'free_mb=4696' }); $r = Run-Move @('plan', 'newbox'); Eq $r.Code 0 $r.Text
  Reset-World; $script:Pf['newbox'] = @('INV host os=ubuntu-24.04 arch=x86_64 cpus=2 mem_mb=4000 swap_mb=0 tz=UTC node_major=22', 'INV disk mount=/ used_mb=1 free_mb=4696', 'INV target moveid=- peer=- projects=0')
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 65; Ok ($r.Text.Contains('need_mb=7462')) 'foreign dst: full formula'
  Reset-World; $script:Tunneled = $true; [void](Seed 'cut'); Yes
  $script:Pf['contabo'] = @('INV host os=ubuntu-24.04 arch=x86_64 cpus=2 mem_mb=4000 swap_mb=0 tz=UTC node_major=22', 'INV disk mount=/ used_mb=1 free_mb=4800', 'INV target moveid=- peer=- projects=0')
  $r = Run-Move @('back'); Eq $r.Code 0 "back with 4800 MB free on old: $($r.Text)"
  Reset-World; $script:Tunneled = $true; [void](Seed 'cut'); Yes
  $script:Pf['contabo'] = @('INV host os=ubuntu-24.04 arch=x86_64 cpus=2 mem_mb=4000 swap_mb=0 tz=UTC node_major=22', 'INV disk mount=/ used_mb=1 free_mb=4000', 'INV target moveid=- peer=- projects=0')
  $r = Run-Move @('back'); Eq $r.Code 65; Ok ($r.Text.Contains('INV refuse disk side=dst need_mb=4696 free_mb=4000')) 'back: still refused below the dump space'
}
T 'finish (abandon): move-id-mismatch (an earlier move''s id on that machine) counts as done like no-move' {
  Reset-World; [void](Seed 'planned'); Add-Rule 'newbox' ' finish' -Code 65 -Out @('MOVE error move-id-mismatch'); Yes
  $r = Run-Move @('finish'); Eq $r.Code 0 $r.Text; Eq (State).phase 'finished'
  # the same answer outside an abandon is a real failure
  Reset-World; [void](Seed 'cut'); $script:Answers.Enqueue('YES'); $script:Answers.Enqueue('YES'); Add-Rule 'newbox' ' finish' -Code 65 -Out @('MOVE error move-id-mismatch')
  $r = Run-Move @('finish'); Eq $r.Code 65; Eq (State).phase 'cut'
}
T 'chores: DEPLOY_KNOWN_HOSTS is `<dst addr> <keytype> <key>` even when the ssh port is not 22' {
  Reset-World; $s = Seed 'cut'; Set-MoveProp $s.new 'hostkey_line' "[$NewAddr]:2222 ssh-ed25519 $KeyNew"; Save-MoveState $s
  $r = Run-Move @('cutover'); Eq $r.Code 0 $r.Text; Eq (@($script:GhIn | Where-Object { $_ })[0]) "$NewAddr ssh-ed25519 $KeyNew"
  Reset-World; $s = Seed 'cut' 'back' 'back'; Set-MoveProp $s.old 'hostkey_line' "[$OldAddr]:2200 ssh-ed25519 $KeyOld"; Save-MoveState $s
  $r = Run-Move @('cutover'); Eq $r.Code 0 $r.Text; Eq (@($script:GhIn | Where-Object { $_ })[0]) "$OldAddr ssh-ed25519 $KeyOld" 'back: old addr'
}
T 'plan: Host <old> and Host <new> must be their own blocks in ~/.ssh/config; refused at plan (65, no call), not after the cut' {
  $cfg = Join-Path (Join-Path $Home2 '.ssh') 'config'
  foreach ($c in @(@("Host newbox`n  HostName $NewAddr`n", 'contabo'), @("Host contabo other`n  HostName $OldAddr`n`nHost newbox`n  HostName $NewAddr`n", 'dùng chung'), @("Host contabo`n  HostName $OldAddr`n", 'newbox'), @("Include other.conf`n", 'Include'))) {
    Reset-World; [IO.File]::WriteAllText($cfg, $c[0], $utf8)
    $r = Run-Move @('plan', 'newbox'); Eq $r.Code 65 $c[1]; Eq $script:Log.Count 0 'no call'; Ok ($r.Text -match $c[1]) "says why ($($c[1])): $($r.Text)"; Ok (-not (Test-Path (Get-MovePath 'state.json'))) 'no state'
  }
  Reset-World; $r = Run-Move @('plan', 'newbox'); Eq $r.Code 0 'the normal config passes'
}
T 'scripts: the bootstrap gate script brackets an IPv6 old address in the rsync source and not an IPv4 one' {
  $bin = Join-Path $Root 'fakebin3'; [void](New-Item -ItemType Directory -Force -Path $bin)
  [IO.File]::WriteAllText((Join-Path $bin 'rsync'), "#!/bin/bash`nprintf '%s\n' `"`$*`" >> `"`$RSYNC_LOG`"`n"); [IO.File]::WriteAllText((Join-Path $bin 'systemctl'), "#!/bin/bash`nexit 0`n"); & chmod +x (Join-Path $bin 'rsync') (Join-Path $bin 'systemctl')
  $f = Join-Path $Root 'bg.sh'; [IO.File]::WriteAllText($f, (Get-MoveBootstrapGateScript) + "`n", $utf8)
  foreach ($c in @(@('2001:db8::1', 'root@[2001:db8::1]:/usr/local/lib/fcode-deploy-gate/'), @('203.0.113.10', 'root@203.0.113.10:/usr/local/lib/fcode-deploy-gate/'))) {
    $R = Join-Path $Root ('fcmroot3-' + $c[0].Replace(':', '_')); [void](New-Item -ItemType Directory -Force -Path $R); $log = Join-Path $R 'rsync.log'
    $savedPath = $env:PATH; $env:PATH = "$bin$([IO.Path]::PathSeparator)$env:PATH"; $env:FCM_ROOT = $R; $env:RSYNC_LOG = $log
    try { $o = @(& bash $f $c[0] 22 /usr/local/sbin/fcode-deploy-gate /usr/local/lib/fcode-deploy-gate /etc/systemd/system/a.service 2>&1 | ForEach-Object { "$_" }); $rc = $LASTEXITCODE } finally { $env:PATH = $savedPath; $env:FCM_ROOT = $null; $env:RSYNC_LOG = $null }
    Eq $rc 0 ($o -join ' | '); $l = [IO.File]::ReadAllText($log); Ok ($l.Contains($c[1])) "source spec for $($c[0]): $l"
    foreach ($x in $l -split "`n") { if ($x -match 'root@\S+:/etc/systemd') { Ok ($x -match $(if ($c[0] -match ':') { 'root@\[2001:db8::1\]:/etc' } else { 'root@203\.0\.113\.10:/etc' })) "unit spec: $x" } }
  }
}
# ============================== round 3 (decisions A30-A33) ==============================
T 'A30: init stdin carries new_kind on both machines (vps and home), after the other keys are unchanged' {
  Reset-World; [void](Seed 'planned'); $r = Run-Move @('copy'); Eq $r.Code 0 $r.Text
  foreach ($g in $script:GateIn | Where-Object { $_.Verb -ceq 'init' }) { $j = $g.Stdin | ConvertFrom-Json; Eq $j.new_kind 'vps' "new_kind on $($g.Host)"; Eq $j.schema 1 }
  Eq (@($script:GateIn | Where-Object { $_.Verb -ceq 'init' }).Count) 2
  Reset-World; $s = Seed 'planned'; Set-MoveProp $s.new 'kind' 'home'; Save-MoveState $s; $r = Run-Move @('copy'); Eq $r.Code 0 $r.Text
  foreach ($g in $script:GateIn | Where-Object { $_.Verb -ceq 'init' }) { Eq ($g.Stdin | ConvertFrom-Json).new_kind 'home' "home on $($g.Host)" }
  # a back run keeps the kind of the new machine
  Reset-World; $script:Tunneled = $true; $s = Seed 'cut'; Set-MoveProp $s.new 'kind' 'home'; Save-MoveState $s; Yes; $r = Run-Move @('back'); Eq $r.Code 0 $r.Text
  foreach ($g in $script:GateIn | Where-Object { $_.Verb -ceq 'init' }) { Eq ($g.Stdin | ConvertFrom-Json).new_kind 'home' "back: home on $($g.Host)" }
}
T 'state: a mark `cutting` round-trips like the others (schema stays 1)' {
  Reset-World; $s = Seed 'copied' 'fwd' 'plan' 'cutting'; Set-MoveProp $s.answers 'cut' (New-MoveAnswer); Save-MoveState $s
  $r = State; Eq $r.mark 'cutting'; Eq $r.schema 1; Eq $r.phase 'copied'; Eq ([bool]$r.answers.cut) $true
  Save-MoveState $r; Eq (State).mark 'cutting'
}
T 'A32: cutover step 8 runs `restore <id> --final`; copy (j) runs plain `restore`; a failing restore --final rolls back' {
  Reset-World; [void](Seed 'planned'); $r = Run-Move @('copy'); Eq $r.Code 0 $r.Text; Eq (Count '^newbox restore$') 1; Eq (Count 'restore --final') 0
  $s = Cut-State; Yes; $r = Run-Move @('cutover'); Eq $r.Code 0 $r.Text; Eq (Count '^newbox restore --final$') 1; Eq (Count '^newbox restore$') 0
  Ordered @('^newbox adopt$', '^newbox restore --final$', '^newbox verify --strict$', '^newbox start$')
  $s = Cut-State; Yes; Add-Rule 'newbox' ' restore --final' -Code 1 -Out @('MOVE error restore-failed item=x')
  $r = Run-Move @('cutover'); Eq $r.Code 1; Eq (State).phase 'rolled-back'; Eq (Count '^newbox verify') 0; Ordered @('^newbox restore --final', '^newbox stop', '^contabo start --connectors')
}
T 'A33: hold_active=- (cannot be counted) is not 0: copy (g) stops with 65, cutover step (5) rolls back with 65' {
  $dash = @{ Out = @('MOVE state move_id=x role=dst machine=new finished=no frozen=0 hold_active=- transfer=idle manifest_sha=-'); Code = 0 }
  Reset-World; [void](Seed 'planned'); Add-Rule 'newbox' ' status' -Seq @($dash)
  $r = Run-Move @('copy'); Eq $r.Code 65; Ok ($r.Text -match 'hold_active=-') 'says it'; Eq (Count ' dump') 0; Eq (State).phase 'planned'
  $s = Cut-State; Yes; Add-Rule 'newbox' ' status' -Seq @($dash)
  $r = Run-Move @('cutover'); Eq $r.Code 65 $r.Text; Eq (State).phase 'rolled-back'; Eq (Count ' dump') 0; Ordered @('^newbox status', '^newbox stop', '^contabo start --connectors')
  # a missing hold_active field is still a failure (1), a 0 passes
  Reset-World; [void](Seed 'planned'); Add-Rule 'newbox' ' status' -Seq @(@{ Out = @('MOVE state move_id=x role=dst'); Code = 0 })
  Eq (Run-Move @('copy')).Code 1
}
# ============================== round 5 (arbitration: a cutover in flight is a mark) ==============================
function Seed-Mark([string]$Mark, [string]$Dir = 'fwd', [string]$Via = 'plan', [string]$Phase = 'copied') {
  $s = Seed $Phase $Dir $Via $Mark
  if ($Mark -ceq 'cutting') { Set-MoveProp $s.answers $(if ($Via -ceq 'back') { 'back' } else { 'cut' }) (New-MoveAnswer) }
  Save-MoveState $s; $s
}
T 'a mark set: plan, copy and back (via=plan) are refused (65, no call, no prompt, state unchanged): cutting / rolling-back name cutover AND finish and the src alias; switching names cutover and the dst alias and never finish; status runs and shows the mark' {
  foreach ($ph in 'copied', 'rolled-back') {
    foreach ($mk in 'cutting', 'rolling-back', 'switching') {
      Reset-World; $s = Seed-Mark $mk 'fwd' 'plan' $ph; Set-MoveProp $s 'dst_started' $true; Save-MoveState $s
      $words = @(@('plan', 'newbox'), @('copy'), @('back'))
      if ($mk -ceq 'switching') { $words += , @('finish') }
      foreach ($w in $words) {
        $r = Run-Move $w; Eq $r.Code 65 "$ph $mk $($w -join ' ')"; Eq $script:Log.Count 0 'no call'; Eq $script:Prompts.Count 0 'no prompt'
        Ok ($r.Text -match 'fcode move cutover') "names cutover: $($r.Text)"
        if ($mk -ceq 'switching') { Ok ($r.Text -match "máy 'newbox'" -and $r.Text -notmatch 'fcode move finish' -and $r.Text -match 'fcode move back') "switching line: $($r.Text)" }
        else { Ok ($r.Text -match 'fcode move finish' -and $r.Text -match "máy 'contabo'") "mark line: $($r.Text)" }
        $n = State; Eq $n.phase $ph; Eq $n.mark $mk; Eq $n.dst_started $true
      }
      $r = Run-Move @('status'); Eq $r.Code 0 "status under $mk"; Ok ($r.Text -match "mark=$mk")
    }
  }
  # a back run: the lines name the other machines (src = new, dst = old)
  Reset-World; [void](Seed-Mark 'cutting' 'back' 'back'); $r = Run-Move @('plan', 'newbox'); Eq $r.Code 65; Ok ($r.Text -match "máy 'newbox'" -and $r.Text -match 'fcode move finish') 'src of a back run is new'
  Reset-World; [void](Seed-Mark 'switching' 'back' 'back'); $r = Run-Move @('copy'); Eq $r.Code 65; Ok ($r.Text -match "máy 'contabo'" -and $r.Text -notmatch 'fcode move finish') 'dst of a back run is old'
}
T 'cutting: cutover continues from step (2) with no question and no cut_not_before check' {
  Reset-World; $s = Seed-Mark 'cutting'; Set-MoveProp $s 'cut_not_before' '2026-10-30T00:00:00Z'; Save-MoveState $s
  $r = Run-Move @('cutover'); Eq $r.Code 0 $r.Text; Eq $script:Prompts.Count 0
  Ordered @('gh workflow disable deploy.yml -R brooklyn96/autoshopee', '^contabo freeze', '^contabo stop --guards', '^newbox stop', '^newbox prepare', '^newbox status', '^contabo dump', '^newbox transfer --final', '^newbox adopt', '^newbox restore --final', '^newbox verify --strict', '^newbox start', '^newbox health', '^newbox switch', '^newbox unfreeze')
  $n = State; Eq $n.phase 'cut'; Eq $n.mark $null
}
T 'cutting + dst_started true (a kill inside step 9): cutover continues at step 9 (start, health, switch, unfreeze); nothing is re-copied; a failing resume rolls back; via=back: `back` continues' {
  Reset-World; $s = Seed-Mark 'cutting'; Set-MoveProp $s 'dst_started' $true; Set-MoveProp $s 'cut_not_before' '2026-10-30T00:00:00Z'; Save-MoveState $s
  $r = Run-Move @('cutover'); Eq $r.Code 0 $r.Text
  Ordered @('^newbox start$', '^newbox health$', '^newbox switch$', '^newbox unfreeze$', 'gh secret set')
  Eq (Count '^(contabo|newbox) (freeze|stop|dump|transfer|adopt|restore|prepare|verify)') 0 'nothing is re-copied over the started dst'; Eq (Count 'gh workflow disable') 0 'workflows are not touched again'; Eq $script:Prompts.Count 0
  $n = State; Eq $n.phase 'cut'; Eq $n.mark $null
  Reset-World; $s = Seed-Mark 'cutting' 'fwd' 'plan' 'rolled-back'; Set-MoveProp $s 'dst_started' $true; Save-MoveState $s; Add-Rule 'newbox' ' health' -Code 69 -Out @('MOVE error health app=x')
  $r = Run-Move @('cutover'); Eq $r.Code 69 $r.Text; $n = State; Eq $n.phase 'rolled-back'; Eq $n.mark $null; Eq $n.dst_started $false
  Ordered @('^newbox start$', '^newbox health$', '^newbox stop$', '^contabo start --connectors', '^contabo unfreeze', '^contabo health'); Eq $script:Prompts.Count 0
  Reset-World; $s = Seed-Mark 'cutting' 'back' 'back'; Set-MoveProp $s 'dst_started' $true; Save-MoveState $s
  $r = Run-Move @('back'); Eq $r.Code 0 $r.Text; Ordered @('^contabo start$', '^contabo health$', '^contabo switch$'); Eq (Count ' freeze') 0
}
T 'via=back run: cutting is written at step (1) although answers.back was set before the plan; `back` with cutting continues at the freeze' {
  Reset-World; $script:Tunneled = $true; [void](Seed 'cut'); Yes; $script:Seen = @{}
  Add-Rule 'newbox' ' freeze' -Do { $script:Seen.Mark = (State).mark; $script:Seen.Ans = [bool](State).answers.back }
  $r = Run-Move @('back'); Eq $r.Code 0 $r.Text; Eq $script:Seen.Mark 'cutting' 'mark at the freeze of the back run'; Ok $script:Seen.Ans 'answer set in the same state'
  Reset-World; [void](Seed-Mark 'cutting' 'back' 'back'); $r = Run-Move @('back'); Eq $r.Code 0 $r.Text; Eq $script:Prompts.Count 0; Ordered @('^newbox freeze', '^newbox stop --guards')
}
T 'abandon (finish) under cutting / rolling-back: the dst-data and rollback line come BEFORE the question; no YES = nothing runs; YES = rollback to its end, then both finish calls; answers cleared, phase finished' {
  Reset-World; [void](Seed-Mark 'cutting')
  $r = Run-Move @('finish'); Eq $r.Code 65 'no YES'; Eq $script:Log.Count 0; Eq $script:Prompts.Count 1
  $iLine = $r.Text.IndexOf("Một cutover đang dở (mark 'cutting')"); $iQ = $r.Text.IndexOf('Huỷ lần chuyển này?'); Ok ($iLine -ge 0 -and $iQ -gt $iLine) 'the line precedes the question'; Ok ($r.Text -match "máy 'contabo'") 'names src'
  Yes; $r = Run-Move @('finish'); Eq $r.Code 0 $r.Text
  Ordered @('^newbox stop$', '^contabo start --connectors$', '^contabo unfreeze$', 'gh workflow enable deploy.yml -R brooklyn96/autoshopee', '^contabo health$', '^contabo finish newbox$', '^newbox finish contabo$')
  $n = State; Eq $n.phase 'finished'; Eq $n.mark $null; Eq $n.answers.cut $null; Eq $n.dst_started $false
  Reset-World; [void](Seed-Mark 'cutting' 'back' 'back'); Yes; $r = Run-Move @('finish'); Eq $r.Code 0 $r.Text
  Ordered @('^contabo stop$', '^newbox start --connectors$', '^newbox unfreeze$', '^newbox health$', '^contabo finish newbox$', '^newbox finish contabo$'); Eq (Count 'gh workflow enable') 0
  Reset-World; $s = Seed-Mark 'cutting'; Set-MoveProp $s 'dst_started' $true; Save-MoveState $s; Yes; $r = Run-Move @('finish'); Eq $r.Code 0 $r.Text
  Ok ($r.Text -match "Dữ liệu các ứng dụng đã ghi ở máy 'newbox'") 'dst data sentence'; Ordered @('^newbox stop$', '^contabo start --connectors$', '^contabo finish newbox$')
  Reset-World; $s = Seed-Mark 'cutting'; Set-MoveProp $s 'dst_started' $true; Save-MoveState $s; Yes; Add-Rule 'newbox' ' stop$' -Code 255 -N 3
  $r = Run-Move @('finish'); Eq $r.Code 70; $n = State; Eq $n.mark 'rolling-back'; Eq (Count ' finish') 0; Eq $n.dst_started $true
  Reset-World; [void](Seed-Mark 'rolling-back' 'fwd' 'plan' 'rolled-back'); Yes; $r = Run-Move @('finish'); Eq $r.Code 0 $r.Text
  Ordered @('^newbox stop$', '^contabo start --connectors$', '^contabo finish newbox$', '^newbox finish contabo$'); Eq (State).phase 'finished'
  Reset-World; [void](Seed-Mark 'cutting'); Yes; Add-Rule 'contabo' ' start --connectors' -Code 1
  $r = Run-Move @('finish'); Eq $r.Code 70; Eq (State).mark 'rolling-back'; Eq (Count ' finish') 0
  # negatives: mark null never rolls back, whatever the side fields say
  Reset-World; $s = Seed 'copied'; Set-MoveProp $s.answers 'cut' (New-MoveAnswer); Set-MoveProp $s 'dst_started' $true; Save-MoveState $s; Yes; $r = Run-Move @('finish'); Eq $r.Code 0; Eq (Count ' start --connectors') 0
  Reset-World; [void](Seed 'rolled-back'); Yes; $r = Run-Move @('finish'); Eq $r.Code 0; Eq (Count ' start --connectors') 0
  Reset-World; $s = Seed 'copied' 'back' 'back'; Set-MoveProp $s.answers 'back' (New-MoveAnswer); Save-MoveState $s; Yes; $r = Run-Move @('finish'); Eq $r.Code 0; Eq (Count ' start --connectors') 0 'a back run with the answer set but no cutover started'
}
T 'the r5 reproduction: a cutover cut off under cutting: plan and copy are refused, finish rolls back first, then both finish calls (none before src is started)' {
  Reset-World; [void](Seed-Mark 'cutting')
  $r = Run-Move @('plan', 'newbox'); Eq $r.Code 65; Eq $script:Log.Count 0; Eq (State).phase 'copied'; Eq (State).mark 'cutting'
  $r = Run-Move @('copy'); Eq $r.Code 65; Eq $script:Log.Count 0
  Yes; $r = Run-Move @('finish'); Eq $r.Code 0 $r.Text
  Ordered @('^newbox stop$', '^contabo start --connectors$', '^contabo unfreeze$', '^contabo health$', '^contabo finish newbox$', '^newbox finish contabo$'); Eq (State).phase 'finished'
  Ok ((Idx '^(contabo|newbox) finish') -gt (Idx '^contabo start --connectors')) 'no finish call before src is started'
}
T 'switching: cutover resumes at step (10) and finishes the cut; a failing switch on resume rolls back; answers.finish does not leak into a later finish (reset at the cut), also after an abandon that ended in 70' {
  Reset-World; [void](Seed-Mark 'switching'); $r = Run-Move @('cutover'); Eq $r.Code 0 $r.Text; Ordered @('^newbox switch$', '^newbox unfreeze$'); Eq (Count '^(contabo|newbox) (freeze|stop|dump)') 0
  Reset-World; $s = Seed-Mark 'switching'; Add-Rule 'newbox' ' switch' -Code 1 -Out @('MOVE error switch-failed host=a'); $r = Run-Move @('cutover'); Eq $r.Code 1; Eq (State).phase 'rolled-back'; Eq (State).mark $null
  Reset-World; $s = Seed 'copied'; Set-MoveProp $s.answers 'finish' (New-MoveAnswer); Save-MoveState $s; Yes
  $r = Run-Move @('cutover'); Eq $r.Code 0 $r.Text; $n = State; Eq $n.phase 'cut'; Eq $n.answers.finish $null
  $script:Answers.Clear(); $r = Run-Move @('finish'); Eq $r.Code 65; Ok ($r.Text.Contains('Máy cũ có thể bỏ được chưa?')) 'Q-finish asked again'; Eq $script:Log.Count 0
  Reset-World; [void](Seed-Mark 'cutting'); Yes; Add-Rule 'contabo' ' health' -Code 69 -Out @('MOVE error health')
  $r = Run-Move @('finish'); Eq $r.Code 70 $r.Text; Eq (State).phase 'rolled-back'; Ok ($null -ne (State).answers.finish) 'answers.finish set by the abandon'
  $script:Rules.Clear(); Yes; $r = Run-Move @('cutover'); Eq $r.Code 0 $r.Text; Eq (State).phase 'cut'; Eq (State).answers.finish $null
  $script:Clock = $script:Clock.AddHours(80); $script:Answers.Clear(); $script:Log.Clear(); $r = Run-Move @('finish'); Eq $r.Code 65; Eq $script:Prompts.Count 1 'Q-finish asked'; Eq $script:Log.Count 0
}
# ============================== transport and scripts ==============================
T 'Invoke-DeploySsh -HostName: ssh -n <alias> <cmd> without stdin, ssh <alias> <cmd> with stdin; an unsafe alias is refused with no call; default unchanged' {
  Reset-World
  $origSsh = (Get-Item function:ssh).ScriptBlock
  Set-Item function:ssh -Value { $script:Cap = @($args | ForEach-Object { [string]$_ }); $in = @($input); $global:LASTEXITCODE = 0; 'x' }
  try {
    $r = Invoke-DeploySsh 'cmd one' '' -Quiet -HostName 'newbox'; Eq ($script:Cap -join '|') '-n|newbox|cmd one'; Eq $r.Code 0
    $r = Invoke-DeploySsh 'cmd one' 'QUJD' -Quiet -HostName 'new-box_2'; Eq ($script:Cap -join '|') 'new-box_2|cmd one'
    $script:Cap = $null; foreach ($bad in '-oProxyCommand=x', 'a b', 'h;id', 'x$(id)') { $r = Invoke-DeploySsh 'c' '' -Quiet -HostName $bad; Eq $r.Code 1 $bad; Eq $script:Cap $null "[$bad] no call" }
    $r = Invoke-DeploySsh 'cmd' '' -Quiet; Eq ($script:Cap -join '|') '-n|contabo|cmd' 'no HostName = deployHost'
  } finally { Set-Item function:ssh -Value $origSsh; $env:USERPROFILE = $Home2 }
}
T 'scripts: every script passes bash -n; arguments ride in a set -- line, never in the ssh command line' {
  foreach ($n in 'Get-MovePreflightScript', 'Get-MoveTcpScript', 'Get-MoveBootstrapKeyScript', 'Get-MoveBootstrapGateScript', 'Get-MoveCoderReadScript', 'Get-MoveCoderWriteScript') {
    $f = Join-Path $Root "$n.sh"; [IO.File]::WriteAllText($f, ((& $n) -replace "`r`n", "`n") + "`n", $utf8)
    $o = & bash -n $f 2>&1; Eq $LASTEXITCODE 0 "${n}: $o"
  }
  Reset-World
  $r = Invoke-MoveScript 'newbox' (Get-MoveTcpScript) @("it's", 'a b') -Quiet
  $c = $script:ScriptLog[$script:ScriptLog.Count - 1]
  Eq ($c.Args -join '|') "it's|a b" 'args survive the quoting'
  $r = Invoke-MoveScript 'newbox' (Get-MoveTcpScript) @("bad`narg") -Quiet; Eq $r.Code 65 'a control character in an argument is refused'
  $r = Invoke-MoveScript 'newbox' "#!/bin/bash`r`n# fcode move: preflight`r`nexit 0`r`n" @() -Quiet; $c = $script:ScriptLog[$script:ScriptLog.Count - 1]; Ok (-not $c.Text.Contains("`r")) 'CRLF from a Windows checkout is turned into LF before it is sent'
}
T 'scripts: the preflight script run for real against a throw-away FCM_ROOT prints the INV lines the laptop parses' {
  $R = Join-Path $Root 'fcmroot'; foreach ($d in 'etc', 'etc/fcode-deploy/projects', 'var/lib/fcode-move', 'root/.cloudflared', 'etc/cloudflared', 'etc/systemd/system', 'usr/lib/systemd/system') { [void](New-Item -ItemType Directory -Force -Path (Join-Path $R $d)) }
  [IO.File]::WriteAllText((Join-Path $R 'etc/os-release'), "ID=ubuntu`nVERSION_ID=`"24.04`"`n")
  foreach ($p in 'a', 'b', 'c') { [IO.File]::WriteAllText((Join-Path $R "etc/fcode-deploy/projects/$p.json"), '{}') }
  [IO.File]::WriteAllText((Join-Path $R 'var/lib/fcode-move/move-id'), '{"schema":1,"move_id":"0a1b2c3d-0000-4000-8000-123456789abc","role":"dst","machine":"new","peer":"contabo","peer_addr":"203.0.113.10","peer_port":22,"manifest_sha":"x","finished":false,"at":"2026-10-29T00:00:00Z"}')
  [IO.File]::WriteAllText((Join-Path $R 'root/.cloudflared/config.yml'), 'x'); [IO.File]::WriteAllText((Join-Path $R 'root/.cloudflared/other.json'), 'x'); [IO.File]::WriteAllText((Join-Path $R 'root/.cloudflared/we ird.json'), 'x')
  [IO.File]::WriteAllText((Join-Path $R 'etc/systemd/system/cloudflared.service'), "[Service]`nExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token CANARY-TOKEN`n")
  [IO.File]::WriteAllText((Join-Path $R 'etc/systemd/system/plain.service'), "[Service]`nExecStart=/usr/bin/true`n")
  $bin = Join-Path $Root 'fakebin'; [void](New-Item -ItemType Directory -Force -Path $bin)
  [IO.File]::WriteAllText((Join-Path $bin 'timeout'), "#!/bin/bash`nexit 1`n"); [IO.File]::WriteAllText((Join-Path $bin 'systemctl'), "#!/bin/bash`n[ `"`$3`" = cloudflared.service ]`n")
  & chmod +x (Join-Path $bin 'timeout') (Join-Path $bin 'systemctl')
  $f = Join-Path $Root 'pf.sh'; [IO.File]::WriteAllText($f, (Get-MovePreflightScript) + "`n", $utf8)
  $savedPath = $env:PATH; $env:PATH = "$bin$([IO.Path]::PathSeparator)$env:PATH"; $env:FCM_ROOT = $R
  try { $out = @(& bash $f 2>&1 | ForEach-Object { "$_" }); $rc = $LASTEXITCODE } finally { $env:PATH = $savedPath; $env:FCM_ROOT = $null }
  Eq $rc 0 ($out -join ' | ')
  $f2 = ConvertFrom-MovePreflight $out
  Ok $f2.HasHost 'INV host'; Eq $f2.Os 'ubuntu-24.04'; Ok ($f2.Arch.Length -gt 0) 'arch'; Ok ($f2.FreeMb -gt 0) 'free_mb of /'; Eq $f2.Smtp 'blocked' 'port 25 test (timeout stubbed to fail: no network is touched)'
  Eq $f2.MoveId '0a1b2c3d-0000-4000-8000-123456789abc'; Eq $f2.Peer 'contabo'; Eq $f2.Projects 3
  Eq (@($f2.Files | Sort-Object) -join ',') '/root/.cloudflared/config.yml,/root/.cloudflared/other.json' 'one INV target-file per regular file, an odd name is skipped'
  Eq (@($f2.Units) -join ',') 'cloudflared.service' 'only a unit whose ExecStart runs cloudflared'; Ok (($out -join "`n") -match 'INV target-unit cloudflared.service active=yes') 'active=yes'
  Ok (($out -join "`n") -notmatch 'CANARY-TOKEN') 'the unit text (token) is never printed'
  foreach ($l in $out) { Ok ($l -match '^INV ') "only INV lines: $l" }
}
T 'scripts: the bootstrap key script run for real (stub tools, throw-away FCM_ROOT): creates the key once, prints the PUBLIC key, writes known_hosts, never the private key' {
  $R = Join-Path $Root 'fcmroot2'; [void](New-Item -ItemType Directory -Force -Path $R)
  $bin = Join-Path $Root 'fakebin2'; [void](New-Item -ItemType Directory -Force -Path $bin)
  foreach ($t in 'rsync', 'git', 'curl', 'flock', 'fallocate', 'mkfs.ext4', 'mountpoint', 'mount', 'losetup', 'systemd-run', 'systemctl') { [IO.File]::WriteAllText((Join-Path $bin $t), "#!/bin/bash`nexit 0`n") }
  [IO.File]::WriteAllText((Join-Path $bin 'node'), "#!/bin/bash`necho 22`n"); & chmod +x (Get-ChildItem $bin | ForEach-Object { $_.FullName })
  if (-not (Get-Command ssh-keygen -CommandType Application -ErrorAction SilentlyContinue)) { Write-Host '  (no ssh-keygen here: skipped)'; return }
  $f = Join-Path $Root 'bk.sh'; [IO.File]::WriteAllText($f, (Get-MoveBootstrapKeyScript) + "`n", $utf8)
  $savedPath = $env:PATH; $env:PATH = "$bin$([IO.Path]::PathSeparator)$env:PATH"; $env:FCM_ROOT = $R
  try {
    $o1 = @(& bash $f newbox "$OldAddr ssh-ed25519 $KeyOld" 22 2>&1 | ForEach-Object { "$_" }); Eq $LASTEXITCODE 0 ($o1 -join ' | ')
    $o2 = @(& bash $f newbox "$OldAddr ssh-ed25519 $KeyOld" 22 2>&1 | ForEach-Object { "$_" }); Eq $LASTEXITCODE 0
  } finally { $env:PATH = $savedPath; $env:FCM_ROOT = $null }
  Ok ($o1[-1] -match '^MOVE key created name=newbox pub_b64=\S+$') "first run: $($o1 -join ' | ')"; Ok ($o2[-1] -match '^MOVE key exists name=newbox pub_b64=\S+$') 'second run: exists'
  $p1 = ($o1[-1] -replace '^.*pub_b64=', ''); $p2 = ($o2[-1] -replace '^.*pub_b64=', ''); Eq $p1 $p2 'same key'; Ok ($p1 -notmatch '=') 'no padding'
  while ($p1.Length % 4) { $p1 += '=' }; $pub = $utf8.GetString([Convert]::FromBase64String($p1)); Ok ($pub -cmatch '\Assh-ed25519 [A-Za-z0-9+/=]+\z') "public key: $pub"
  Eq ([IO.File]::ReadAllText((Join-Path $R 'var/lib/fcode-move/known_hosts'))) "$OldAddr ssh-ed25519 $KeyOld`n" 'old host key pinned'
  Ok (($o1 + $o2) -join "`n" -notmatch 'PRIVATE') 'no private key printed'
  Ok ((Test-Path (Join-Path $R 'root/.ssh/fcode-move')) -and (Test-Path (Join-Path $R 'root/.ssh/fcode-move.pub'))) 'key files'
  if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') { Eq ((& stat -c '%a' (Join-Path $R 'root/.ssh/fcode-move'))) '600' 'private key 0600'; Eq ((& stat -c '%a' (Join-Path $R 'var/lib/fcode-move'))) '700' 'move dir 0700' }
  # a missing tool the stub dir cannot satisfy: exit 70 with MOVE error tool-missing (no apt in the way: apt-get stubbed to fail)
  Remove-Item (Join-Path $bin 'flock'); [IO.File]::WriteAllText((Join-Path $bin 'apt-get'), "#!/bin/bash`nexit 1`n"); & chmod +x (Join-Path $bin 'apt-get')
  $savedPath = $env:PATH; $env:PATH = "$bin$([IO.Path]::PathSeparator)/usr/bin$([IO.Path]::PathSeparator)/bin"; $env:FCM_ROOT = $R
  try { $o3 = @(& bash $f newbox - 22 2>&1 | ForEach-Object { "$_" }); $rc3 = $LASTEXITCODE } finally { $env:PATH = $savedPath; $env:FCM_ROOT = $null }
  if (Test-Path /usr/bin/flock) { Write-Host '  (flock is a real tool here: the missing-tool leg is skipped)' } else { Eq $rc3 70; Ok ($o3 -match 'MOVE error tool-missing') 'tool-missing' }
}

# ============================== source checks ==============================
$src = [IO.File]::ReadAllText($Fcode)
T 'dispatch and help: `fcode move` is routed; the overview and `help move` list it (lines within the limits)' {
  Ok ($src.Contains("if (`$arg -eq 'move') { exit (Invoke-Move) }")) 'route'
  $iDep = $src.IndexOf("if (`$arg -eq 'deploy') { exit (Invoke-Deploy) }"); $iMv = $src.IndexOf("if (`$arg -eq 'move') { exit (Invoke-Move) }"); Ok ($iDep -gt 0 -and $iMv -gt $iDep) 'after deploy'
  $hostExe = (Get-Process -Id $PID).Path
  $o = @(& $hostExe -NoProfile -File $Fcode help 2>&1 | ForEach-Object { "$_" }); Eq $LASTEXITCODE 0
  foreach ($l in $o) { Ok ($l.Length -le 80) "overview line too long: $l" }
  foreach ($x in 'fcode move plan <máy mới>', 'fcode move copy | cutover', 'fcode move finish | back | status') { Ok (($o -join "`n").Contains($x)) "overview lists $x" }
  $m = @(& $hostExe -NoProfile -File $Fcode help move 2>&1 | ForEach-Object { "$_" }); Eq $LASTEXITCODE 0
  foreach ($l in $m) { Ok ($l.Length -le 78) "help move line too long ($($l.Length)): $l" }
  foreach ($x in 'fcode move <lệnh>', 'plan <máy mới> [--map f]', 'cutover', 'finish', 'back', 'status', 'fcode move plan newbox') { Ok (($m -join "`n").Contains($x)) "help move lacks $x" }
  Ok (($o + $m) -join "`n" -notmatch [char]27) 'no escape code when piped'
}
T 'source: the move code writes no file by itself except through Write-PhienText / File.Copy, runs no shell string, and never puts a secret value in argv' {
  $d = (@($found | Where-Object { $_.Name -match '-Move' }) | ForEach-Object { $_.Extent.Text }) -join "`n"
  Ok ($d -notmatch 'Set-Content|AppendAllText|WriteAllText|Out-File|WriteAllBytes') 'no direct writers'
  Ok ($d -notmatch 'Invoke-Expression|\biex\b|Start-Process|cmd /c') 'no shell re-parse'
  Ok ($d -notmatch 'DEPLOY_KNOWN_HOSTS[^\n]*--body') 'the secret value goes on stdin, not as --body'
}

Set-Location $env:TEMP
$env:USERPROFILE = $savedProfile
Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "passed $script:pass, failed $script:fail"
if ($script:fail) { exit 1 }
exit 0
