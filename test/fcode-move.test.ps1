# Tests for `fcode move` v2 (laptop/fcode.ps1): the laptop side of deploy-gate docs/move/CONTRACT.md (DESIGN rev 1k3.7.1, DECISION-1k3 and its errata).
# Run:  pwsh -NoProfile -File test/fcode-move.test.ps1      (Windows: pwsh only, the bash cases print a skipped count; Linux: full run)
# Nothing real is contacted. Every function of fcode.ps1 is loaded out of the file (the script body never runs) and the seams are replaced
# by fakes defined afterwards: Invoke-MoveTimedExe (every ssh to old / new), Invoke-MoveTool (ssh -G, ssh-keygen, gh), Invoke-BoxScript
# (the coder box), Read-SyncLine (the owner's answers), Get-MoveNow / Wait-Move (the clock), Get-Cfg. The fake ssh holds a small model of
# both machines (move-id, marker, holds, call records with attach / replay / re-run, the door, host keys) so the laptop is driven by real
# state, as on the rehearsal pair. USERPROFILE is a temp folder, removed at the end.
#   FCODE_TEST_ONLY=<regex>   run only the cases whose name matches
#   FCODE_TEST_NO_BASH=1      run as on Windows (no bash): the bash cases are skipped and counted
#   MV_MOVE_MD=<path>         deploy-gate docs/MOVE.md for L.texts-match-move-md, which fails when it is unset (G.2, W1-T11-DG-T11-1)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$Repo = Split-Path -Parent $PSScriptRoot
$Fcode = Join-Path (Join-Path $Repo 'laptop') 'fcode.ps1'
$Root = Join-Path ([IO.Path]::GetTempPath()) ('fcode-move-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $Root)
$savedProfile = $env:USERPROFILE
$Home2 = Join-Path $Root 'home'
$CoderHome = Join-Path $Root 'coder'
$env:USERPROFILE = $Home2
$utf8 = New-Object Text.UTF8Encoding($false)
$script:pass = 0; $script:fail = 0; $script:skip = 0
$script:OnWindows = ([Environment]::OSVersion.Platform -eq 'Win32NT')
$script:BashExe = $null
if (-not $script:OnWindows -and $env:FCODE_TEST_NO_BASH -ne '1') { $b = Get-Command bash -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($b) { $script:BashExe = $b.Source } }
$script:AllCalls = New-Object Collections.ArrayList   # every recorded call id the laptop sent in this run (L.call-key-sites, runtime half)

# ============================== the closed lists (CONTRACT §1.3, §2) ==============================
$StepList = @('c.init-old', 'c.init-new', 'c.repin.N', 'c.prepare.N', 'c.transfer.N', 'c.verify.N', 'c.adopt.N', 'x.freeze', 'x.check', 'x.repin', 'x.baseline', 'x.guards', 'x.stop-src', 'x.stop-dst', 'x.final', 'x.verify', 'x.prepare-id', 'x.adopt', 'x.start', 'x.health', 'x.switch', 'x.enable.N', 'x.unfreeze.N', 'r.stop-dst', 'r.start-src', 'r.unfreeze-src', 'r.health-src', 'b.init-new', 'b.init-old', 'f.old', 'f.new', 'a.old', 'a.new', 'p.pm2-save.N', 'p.cert-renew.N')
$CallRx = '^(fwd|back)-(0|[1-9][0-9]*)-(c\.init-old|c\.init-new|c\.(repin|prepare|transfer|verify|adopt)\.[1-9][0-9]*|x\.(freeze|check|repin|baseline|guards|stop-src|stop-dst|final|verify|prepare-id|adopt|start|health|switch)|x\.(enable|unfreeze)\.[1-9][0-9]*|r\.(stop-dst|start-src|unfreeze-src|health-src)|b\.init-(new|old)|[fa]\.(old|new)|p\.(pm2-save|cert-renew)\.[1-9][0-9]*)$'
$IgnoredFlags = @('budget', 'mark', 'dst-started', 'phase', 'serving')
$Valued = @('dir', 'attempt', 'sha', 'call', 'budget', 'serving', 'mark', 'dst-started', 'phase', 'role', 'seed', 'since', 'lst')

# ============================== rulings and readings the suite follows (a reading = one named spot; the Architect rules it) ==============================
$BackDoneExit = 0                                         # D.8: a manual back that reaches back-done exits 0 (W1-T11-DG-T11-8)
$GhForm = @{                                              # D.0.2: T10's gh call forms; CONTRACT §7 records them from T10's code (W1-T11-DG-T11-9)
  RepoList = '^repo list'; SecretList = '^secret list -R '; SecretSet = '^secret set DEPLOY_KNOWN_HOSTS'; RunList = '^run list -R '; Disable = '^workflow disable'
  WfDir = '^api repos/{0}/contents/\.github/workflows$'; WfFile = '^api repos/{0}/contents/\.github/workflows/{1}'
  SecretListAny = '^secret list'; Json = '--json'; Api = '^api '        # the fake gh's default answers (test: Invoke-MoveTool, gh branch)
}
$CutAllowlistText = 'danh sách IP được phép'              # T10-G8: the Q-cut wording of E-N9's external-IP-allowlist reminder (D.15 gives no Vietnamese text)
$DiskLabel0c = 'Máy mới không đủ chỗ trống trên đĩa'      # T10-G14: 0c "fresh space" = dst free_mb >= 2048, refused as `INV refuse disk`
# D.7 / D.10: finish's "new healthy now" is new's unrecorded status: hold_active = the non-follower holds of hold_sets.start, frozen=0, no call running (W1-T10-G18, W1-T11-DG-T11-5) -> L.finish-health
# D.5.2: a sent x.final, whatever its outcome (unknown included), has started: exit 70, resume only (W1-T11-DG-R11-1) -> L.carry-after-final-70 (PROBE.er5-final-new-down), L.back-rollback-to-cut
# D.0.9 / D.0.10: new keeps c.init-new's "target" stdin key as MV_DIR/target.json; a rebuild takes the target_* values from rebuild read's MOVE target line (W1-T11-DG-R11-2, W1-T10R-F4) -> L.rebuild
function PassStep([string]$Step, [int]$N) { "$Step.$N" }  # T10-G19: one N per pass of a counted step, the same id on both machines
$FenceStep = 'r.stop-dst'                                 # T10-G12: the lost/discarded-new fence step on new (Architect: step and machine open)
$QGuardKey = 'Q-guard'                                    # T10-G51: the Q-guard project names kept in answers{} for the question of a resume
$CutOffUnknown = 'không rõ'                               # T10's wording of the <giờ> fill when dst_started_at is empty or unparseable (R5-2)
$ClockUnreadable = 'side={0} skew_s=-'                    # T10 R2-5: unreadable facts refuse `INV refuse clock side=<m> skew_s=-`
$GioFmt = 'dd/MM/yyyy HH:mm:ss'                           # R5-2: the <giờ> fill is exactly (ConvertTo-MoveTime $dst_started_at).ToLocalTime().ToString($GioFmt, Invariant), no suffix (D.5.3: dst_started_at in the laptop's time zone)
$RebuildDstStartedAt = 'fwd-{0}-x.start'                  # R5-1: a rebuilt dst_started_at = start= of new's fwd-<a>-x.start record; a = attempt when dir=fwd, attempt − 1 when carry=true; '' otherwise (manual back, no record, start=-). Q-cut.ts stays the start= of old's latest fwd x.freeze (R2-4)
$TsRx = '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$'               # the record format of every time value in state.json
$LegacyWfLine = '      - run: echo "${{ secrets.DEPLOY_KNOWN_HOSTS }}" > kh'   # a legacy deploy workflow line (B.10.2); the scan matches it, but naming DEPLOY_KNOWN_HOSTS never makes a repo gate-push (ruling T10c-LP 04/11) -> L.push-scan
$LegacyFactsLine = 'MOVE legacy project={0} origin={1}'   # ruling T10c-LP 04/11: the facts script prints `git -C <dir> remote get-url origin` of /opt/deal-sync (project deal-sync) and /opt/internal-scraper (vps-scraper, lib/legacy.sh); T10d's line form; only old's lines count -> Use-Legacy, L.push-scan, L.rebuild

# ============================== harness ==============================
function T([string]$Name, [scriptblock]$Body, [switch]$NeedsBash) {
  if ($env:FCODE_TEST_ONLY -and $Name -notmatch $env:FCODE_TEST_ONLY) { return }
  if ($NeedsBash -and -not $script:BashExe) { $script:skip++; Write-Host "SKIP $Name (needs bash)"; return }
  if ($script:LoadErr) { $script:fail++; Write-Host "FAIL $Name :: $($script:LoadErr)"; return }
  try {
    Reset-World
    & $Body
    if ($script:W.Runaway) { throw "runaway: $($script:W.Runaway)" }
    if ($script:W.Violations.Count) { throw ('contract violations: ' + (@($script:W.Violations | Select-Object -First 5) -join ' ; ')) }
    $script:pass++; Write-Host "PASS $Name"
  } catch {
    $script:fail++
    $at = if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) { " (test line $($_.InvocationInfo.ScriptLineNumber))" } else { '' }
    Write-Host "FAIL $Name :: $($_.Exception.Message)$at"
    if ($env:FCODE_TEST_VERBOSE -eq '1' -and $script:W) { Write-Host ('   log: ' + (@($script:W.Log) -join ' ; ')); if ($script:Last) { Write-Host ('   out: ' + $script:Last.Text) } }
  }
  foreach ($c in @($script:W.Calls)) { if ($c.Call) { [void]$script:AllCalls.Add($c.Call) } }
}
function Eq($Got, $Want, [string]$What = '') { if ("$Got" -cne "$Want") { throw "$What expected [$Want] got [$Got]" } }
function Ok([bool]$c, [string]$What) { if (-not $c) { throw $What } }

# ============================== load fcode.ps1 (functions only) ==============================
$script:LoadErr = $null
$tokens = $null; $errs = $null
$script:FcodeAst = [Management.Automation.Language.Parser]::ParseFile($Fcode, [ref]$tokens, [ref]$errs)
$script:FcodeText = [IO.File]::ReadAllText($Fcode)
if ($errs.Count) { $script:LoadErr = "fcode.ps1 does not parse: $($errs[0].Message)" }
else {
  foreach ($fn in @($script:FcodeAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false))) { . ([scriptblock]::Create($fn.Extent.Text)) }
  foreach ($need in 'Invoke-Move', 'Invoke-MoveCall', 'Invoke-MoveTimedExe', 'Invoke-MoveTool', 'Get-MoveNow', 'Wait-Move') {
    if (-not (Get-Command $need -CommandType Function -ErrorAction SilentlyContinue)) { $script:LoadErr = "fcode.ps1 lacks $need (T10 unfinished)"; break }
  }
}

# ============================== small helpers ==============================
function Get-Sha256Hex([byte[]]$b) { ([BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($b)) -replace '-', '').ToLowerInvariant() }
function Get-Gz64([byte[]]$b) { $ms = New-Object IO.MemoryStream; $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Compress); $gz.Write($b, 0, $b.Length); $gz.Close(); [Convert]::ToBase64String($ms.ToArray()) }
function Format-Iso([DateTime]$d) { $d.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }
function Get-Epoch([DateTime]$d) { [long]($d.ToUniversalTime() - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalSeconds }
# an ed25519 public key blob (string "ssh-ed25519", 32 key bytes) as base64
function New-EdKey([int]$Seed) {
  $t = [Text.Encoding]::ASCII.GetBytes('ssh-ed25519'); $k = [byte[]](1..32 | ForEach-Object { [byte](($_ * 7 + $Seed) % 256) })
  $b = New-Object Collections.Generic.List[byte]
  $b.AddRange([byte[]](0, 0, 0, 11)); $b.AddRange($t); $b.AddRange([byte[]](0, 0, 0, 32)); $b.AddRange($k)
  [Convert]::ToBase64String($b.ToArray())
}
function Get-Fp([string]$B64) { 'SHA256:' + [Convert]::ToBase64String(([Security.Cryptography.SHA256]::Create()).ComputeHash([Convert]::FromBase64String($B64))).TrimEnd('=') }

$OldAlias = 'oldbox'; $NewAlias = 'newbox'
$OldAddr = '203.0.113.10'; $NewAddr = '198.51.100.20'
$KeyOld = New-EdKey 3; $KeyNew = New-EdKey 41; $TheMoveKey = New-EdKey 77
$SshConfig0 = "Host $OldAlias`n  HostName $OldAddr`n  User root`n`nHost $NewAlias`n  HostName $NewAddr`n  User root`n"
$CoderConfig0 = "Host $OldAlias`n  HostName $OldAddr`n  User root`n"
$GateA = 'aaaaaaaaaaaa'; $GateB = 'bbbbbbbbbbbb'
$Holds = 3
$LegacyRepo = 'brooklyn96/BD-Team-Project'

function New-Machine([string]$Name, [string]$Addr, [string]$Key, [string]$Hn, [bool]$Serving) {
  @{ Name = $Name; Addr = $Addr; Key = $Key; Hostname = $Hn; Up = $true; HasGate = $Serving; NoMove = $false; Gate = $GateA
     MoveId = $null; Frozen = $false; Holds = $Holds; Active = $(if ($Serving) { $Holds } else { 0 }); Enabled = $Serving
     Rec = @{}; Order = (New-Object Collections.ArrayList); Last = $null; Running = $null; Skew = 0; Digest = @{}; Lst = @{}; Os = 'debian-13'; Sha = ''; Legacy = @() }
}
function New-Manifest {
  [ordered]@{
    schema = 2
    items = @([ordered]@{ id = 'opt-app'; root = '/opt/app'; kind = 'tree'; bytes_apparent = 1000000; inodes = 100 }, [ordered]@{ id = 'srv-data'; root = '/srv/data'; kind = 'tree'; bytes_apparent = 2000000; inodes = 200 })
    deleted_conffiles = @()
    holds = @([ordered]@{ id = 'app.service'; kind = 'unit'; type = 'service'; unit_file_state = 'enabled'; active_state = 'active'; sub_state = 'running'; remain_after_exit = 'no'; n_restarts = 0; stop_budget_s = 120; start_budget_s = 60; listen = @() },
              [ordered]@{ id = 'worker.service'; kind = 'unit'; type = 'service'; unit_file_state = 'enabled'; active_state = 'active'; sub_state = 'running'; remain_after_exit = 'no'; n_restarts = 0; stop_budget_s = 120; start_budget_s = 60; listen = @() },
              [ordered]@{ id = 'cron.service'; kind = 'unit'; type = 'service'; unit_file_state = 'enabled'; active_state = 'active'; sub_state = 'running'; remain_after_exit = 'no'; n_restarts = 0; stop_budget_s = 120; start_budget_s = 60; listen = @() })
    hold_sets = [ordered]@{ enable = @('app.service', 'worker.service', 'cron.service'); start = @('app.service', 'worker.service', 'cron.service'); stop = @('app.service', 'worker.service', 'cron.service') }
    followers = @()
    users = @([ordered]@{ name = 'quoc'; uid = 1000 }, [ordered]@{ name = 'app'; uid = 1001 })
    same_users = @(); groups = @(); subids = @(); idmap = @()
    pkgs = @([ordered]@{ name = 'nodejs'; version = '22.23.3-1nodesource1' })
    apt_sources = @(); firewall = [ordered]@{ state = 'inactive'; rules = @() }; hosts_custom = @(); hostnames = @(); connectors = @()
    pm2 = [ordered]@{ configured = @(); must_be_online = @() }; redis = @(); pg = @(); guards = @(); inbound = @(); public_ports = @(); egress = @(); rewrites = @()
    identity = [ordered]@{ hostname = 'oldhost'; tz = 'Asia/Ho_Chi_Minh'; locales = @('en_US.UTF-8'); swap_mb = 0; os = 'debian-13'; arch = 'x86_64'; systemd = 257 }
    gate_id = $GateA
    totals = [ordered]@{ bytes_apparent = 3000000; inodes = 300 }
  }
}

function Reset-World {
  if (Test-Path -LiteralPath $Home2) { Remove-Item -LiteralPath $Home2 -Recurse -Force }
  if (Test-Path -LiteralPath $CoderHome) { Remove-Item -LiteralPath $CoderHome -Recurse -Force }
  [void](New-Item -ItemType Directory -Path (Join-Path $Home2 '.ssh'))
  [void](New-Item -ItemType Directory -Path (Join-Path $CoderHome '.ssh'))
  [IO.File]::WriteAllText((Join-Path (Join-Path $Home2 '.ssh') 'config'), $SshConfig0, $utf8)
  [IO.File]::WriteAllText((Join-Path (Join-Path $CoderHome '.ssh') 'config'), $CoderConfig0, $utf8)
  $script:Clock = [DateTime]::SpecifyKind([DateTime]'2026-11-02T10:00:00', [DateTimeKind]::Utc)
  $script:Last = $null
  $script:W = @{
    old = (New-Machine 'old' $OldAddr $KeyOld 'oldhost' $true); new = (New-Machine 'new' $NewAddr $KeyNew 'newhost' $false)
    Log = (New-Object Collections.ArrayList); Calls = (New-Object Collections.ArrayList); From = 0
    Faults = (New-Object Collections.ArrayList); Answers = (New-Object Collections.Queue); Prompts = (New-Object Collections.ArrayList)
    Gh = (New-Object Collections.ArrayList); GhLog = (New-Object Collections.ArrayList); KeygenLog = (New-Object Collections.ArrayList); ToolLog = (New-Object Collections.ArrayList)
    BoxLog = (New-Object Collections.ArrayList); Mf = (New-Manifest); PlanStdin = (New-Object Collections.ArrayList); PlanN = 0
    Pf = @('INV target user=quoc uid=1000 home-nonskel=1', 'INV target addr=198.51.100.20', 'INV target platform=0', 'INV target stop_budget_s=120'); PfCode = 0
    CheckOut = @('INV ok'); CheckCode = 0; CheckOnlyOut = @('INV ok'); CheckOnlyCode = 0; PlanHook = $null; PlanOut = @('INV ok'); PlanCode = 0
    NewGate = (New-Object Collections.Queue); TcpFail = @{}; LoginRc = 0; CoderUp = $true; Dur = @{}; Sleeps = 0
    Violations = (New-Object Collections.ArrayList); Runaway = $null; StateSeen = (New-Object Collections.ArrayList); Hooks = @{}; Out = (New-Object Collections.ArrayList); OutFrom = 0; BoxStates = (New-Object Collections.ArrayList)
  }
}

# ============================== fakes (defined after fcode.ps1, so they win) ==============================
$script:Cfg2 = @{ deployHost = $OldAlias }
function Get-Cfg([string]$Key, $Default) { if ($script:Cfg2.ContainsKey($Key)) { $script:Cfg2[$Key] } else { $Default } }
function Get-MoveNow { $script:Clock }
function Wait-Move([int]$Sec) { $script:W.Sleeps += $Sec; $script:Clock = $script:Clock.AddSeconds($Sec); if ($script:W.Sleeps -gt 400000) { $script:W.Runaway = 'the laptop waits without end (Wait-Move)'; throw 'runaway wait' } }
function Read-SyncLine([string]$Prompt) {
  [void]$script:W.Prompts.Add($Prompt); Write-Host "<<Q>> $Prompt"
  if ($script:W.Answers.Count) { $a = $script:W.Answers.Dequeue(); Write-Host "<<A>> $a"; $a } else { Write-Host '<<A>> (none)'; $null }
}
function Ans([string[]]$A) { foreach ($x in $A) { $script:W.Answers.Enqueue($x) } }
function Log([string]$s) { [void]$script:W.Log.Add($s) }
function New-Res([int]$Code, [string[]]$Out) { @{ Code = $Code; Out = [string[]]@($Out); Err = '' } }
function Add-Fault([string]$M = '.', [string]$Key, [int]$Rc = 1, [string[]]$Out = $null, [int]$N = 1, [string]$Mode = '', [scriptblock]$Do = $null, [switch]$Effect, [int]$Left = 2) {
  [void]$script:W.Faults.Add(@{ M = $M; Key = $Key; Rc = $Rc; Out = $Out; N = $N; Mode = $Mode; Do = $Do; Effect = [bool]$Effect; Left = $Left })
}
function Get-Fault([string]$M, [string]$Key) {
  foreach ($f in $script:W.Faults) { if ($f.N -ne 0 -and $M -match "\A(?:$($f.M))\z" -and $Key -match $f.Key) { if ($f.N -gt 0) { $f.N-- }; return $f } }
  $null
}
function Decode-B64([string]$t) {
  $t = "$t".Trim(); if (-not $t) { return '' }
  try { $utf8.GetString([Convert]::FromBase64String($t)) } catch { [void]$script:W.Violations.Add("stdin is not one base64 line"); $t }
}
function Get-SshOpts([string[]]$a) {
  $o = @{}
  for ($i = 0; $i -lt $a.Count - 2; $i++) {
    $x = $a[$i]; $kv = $null
    if ($x -ceq '-o' -and $i + 1 -lt $a.Count - 2) { $kv = $a[$i + 1]; $i++ } elseif ($x -clike '-o?*') { $kv = $x.Substring(2) } else { continue }
    $j = $kv.IndexOf('='); if ($j -lt 0) { $j = $kv.IndexOf(' ') }
    if ($j -gt 0) { $o[$kv.Substring(0, $j).Trim().ToLowerInvariant()] = $kv.Substring($j + 1).Trim().Trim('"') }
  }
  $o
}
# Host blocks of an ssh config text: alias -> HostName (first Host line word only, exact)
function Get-ConfigHosts([string]$Text) {
  $h = @{}; $cur = @()
  foreach ($l in @($Text -split '\r?\n')) {
    if ($l -match '^\s*Host\s+(.+)$') { $cur = @($Matches[1].Trim() -split '\s+'); foreach ($c in $cur) { if (-not $h.ContainsKey($c)) { $h[$c] = $null } } }
    elseif ($l -match '^\s*HostName\s+(\S+)') { foreach ($c in $cur) { if ($null -eq $h[$c]) { $h[$c] = $Matches[1] } } }
  }
  $h
}
function Get-LaptopConfig { $p = Join-Path (Join-Path $Home2 '.ssh') 'config'; if (Test-Path -LiteralPath $p) { [IO.File]::ReadAllText($p) } else { '' } }
function Resolve-Addr([string]$HostArg, $o) {
  if ($o['hostname']) { return $o['hostname'] }
  $h = Get-ConfigHosts (Get-LaptopConfig)
  if ($h.ContainsKey($HostArg) -and $h[$HostArg]) { return $h[$HostArg] }
  $HostArg
}
function Get-Machine([string]$Addr) { if ($Addr -ceq $OldAddr) { $script:W.old } elseif ($Addr -ceq $NewAddr) { $script:W.new } else { $null } }
function Test-HostKey($m, $o, [string]$HostArg, [string]$Addr) {
  $f = $o['userknownhostsfile']; $s = "$($o['stricthostkeychecking'])".ToLowerInvariant()
  if (-not $f) { [void]$script:W.Violations.Add("ssh $HostArg without -o UserKnownHostsFile (B.11.3)"); return $true }
  if ($s -notin 'yes', 'accept-new') { [void]$script:W.Violations.Add("ssh $HostArg with StrictHostKeyChecking=$s (B.11.3)") }
  $name = if ($o['hostkeyalias']) { $o['hostkeyalias'] } else { $Addr }
  $lines = if (Test-Path -LiteralPath $f) { [IO.File]::ReadAllLines($f) } else { @() }
  foreach ($l in $lines) { $p = @("$l".Trim() -split '\s+'); if ($p.Count -ge 3 -and (@($p[0] -split ',') -ccontains $name) -and $p[1] -ceq 'ssh-ed25519') { return ($p[2] -ceq $m.Key) } }
  if ($s -eq 'accept-new') { $d = Split-Path -Parent $f; if ($d) { [void][IO.Directory]::CreateDirectory($d) }; [IO.File]::AppendAllText($f, "$name ssh-ed25519 $($m.Key)`n", $utf8); return $true }
  $false
}

# the one ssh seam: every call to old or new
function Invoke-MoveTimedExe([string]$Exe, [string[]]$ExeArgs, [string]$StdinText, [int]$TimeoutSec) {
  $W = $script:W
  if ($W.Runaway) { return (New-Res 255 @()) }
  if ($W.Calls.Count -gt 3000) { $W.Runaway = 'more than 3000 ssh calls in one case'; return (New-Res 255 @()) }
  # a state.json written by the laptop must parse at every instant a call goes out (I18, L.state-atomic)
  $sp = Join-Path (Join-Path (Join-Path $Home2 '.fcode') 'move') 'state.json'
  if (Test-Path -LiteralPath $sp) { try { $sj = [IO.File]::ReadAllText($sp) | ConvertFrom-Json; [void]$W.StateSeen.Add($sj) } catch { [void]$W.Violations.Add("state.json does not parse while a call goes out: $($_.Exception.Message)") } }
  $a = @($ExeArgs | ForEach-Object { [string]$_ })
  $o = Get-SshOpts $a
  $hostArg = $a[-2]; $remote = $a[-1]
  $addr = Resolve-Addr $hostArg $o
  $m = Get-Machine $addr
  $e = [pscustomobject]@{ M = $(if ($m) { $m.Name } else { "?$addr" }); Host = $hostArg; Remote = $remote; Opts = $o; Argv = $a; Timeout = $TimeoutSec; Exe = $Exe; Kind = ''; Verb = ''; Id = ''; Call = ''; Step = ''; Budget = $null; Flags = @{}; Sw = @{}; Pos = @(); Stdin = ''; Script = ''; Args = @(); Replay = $false; Attach = $false; Code = $null; Out = @() }
  [void]$W.Calls.Add($e)
  if ($TimeoutSec -le 0) { [void]$W.Violations.Add("a call without a deadline: $remote (I15)") }
  if (-not $m -or -not $m.Up) { $e.Kind = 'down'; Log "$($e.M) down"; $r = New-Res 255 @("ssh: connect to host $hostArg port 22: Connection timed out"); $e.Code = 255; return $r }
  if (-not (Test-HostKey $m $o $hostArg $addr)) { $e.Kind = 'hostkey'; Log "$($m.Name) hostkey-fail"; $e.Code = 255; return (New-Res 255 @('Host key verification failed.')) }
  if ($remote -cmatch '\A(?:base64 -di \| )?/usr/local/sbin/fcode-deploy-gate --move (.*)\z') { $r = Fake-Gate $m $Matches[1] (Decode-B64 $StdinText) $e }
  elseif ($remote -cmatch 'f=\$\(mktemp\)') { $r = Fake-Script $m (Decode-B64 $StdinText) $e }
  elseif ($remote -ceq 'true') { $e.Kind = 'login'; Log "$($m.Name) login"; $r = New-Res $W.LoginRc @() }
  else { [void]$W.Violations.Add("unexpected ssh remote command: $remote"); $r = New-Res 1 @() }
  $e.Code = $r.Code; $e.Out = $r.Out
  $r
}

function Get-StatusFields($m) {
  $mi = $m.MoveId; $last = $m.Last; $cs = '-'; $rc = '-'
  if ($last) { $rec = $m.Rec[$last]; if ($m.Running -and $m.Running.Call -ceq $last) { $cs = 'running' } elseif ($null -eq $rec.Rc) { $cs = 'interrupted' } elseif ([int]$rec.Rc -eq 0) { $cs = 'done'; $rc = '0' } else { $cs = 'failed'; $rc = "$($rec.Rc)" } }
  $v = { param($x) if ($null -eq $x -or "$x" -eq '' -or "$x" -ceq 'null') { '-' } else { "$x" } }
  [ordered]@{ move_id = (& $v $(if ($mi) { $mi.id })); role = (& $v $(if ($mi) { $mi.role })); dir = (& $v $(if ($mi) { $mi.dir })); attempt = (& $v $(if ($mi) { $mi.attempt }))
    state = (& $v $(if ($mi) { $mi.state })); frozen = $(if ($m.Frozen) { '1' } else { '0' }); call = (& $v $last); call_state = $cs; rc = $rc; last_final = (& $v (@($m.Order | Where-Object { $_ -match '-x\.final$' }) | Select-Object -Last 1))
    serving = (& $v $(if ($mi) { $mi.serving })); hold_active = "$($m.Active)"; followers_active = '0'; free_mb = "$(if ($m.FreeMb) { $m.FreeMb } else { 900000 })"; free_inodes = '9000000'
    time = (Format-Iso ($script:Clock.AddSeconds($m.Skew))); hostname = $m.Hostname; gate = $m.Gate; mark = (& $v $(if ($mi) { $mi.mark })); dst_started = $(if ($mi -and "$($mi.dst_started)" -in '1', 'true', 'True') { '1' } else { '0' }) }
}
function Complete-Running($m) {
  $r = $m.Running; $m.Running = $null
  $rec = $m.Rec[$r.Call]; $rec.Rc = $r.Rc
  if ($r.Rc -eq 0) { Apply-Effects $m $r.Step $r.Verb $r.F $r.Sw $r.Id $r.Stdin }
}
function Get-ManifestLine([string[]]$TargetUsers) {
  $mf = $script:W.Mf
  $same = @()
  foreach ($t in @($TargetUsers)) { $p = @($t -split ' '); foreach ($u in @($mf.users)) { if ($u.name -ceq $p[1] -and "$($u.uid)" -ceq $p[2]) { $same += [ordered]@{ name = $u.name; uid = $u.uid } } } }
  if ($null -ne $TargetUsers) { $mf.same_users = @($same) }
  $json = ConvertTo-Json -InputObject $mf -Depth 12 -Compress
  $b = $utf8.GetBytes($json)
  $script:W.LastSha = Get-Sha256Hex $b; $script:W.LastManifest = $json
  "MOVE manifest sha=$($script:W.LastSha) gz64=$(Get-Gz64 $b)"
}

function Fake-Gate($m, [string]$Cmd, [string]$Stdin, $e) {
  $W = $script:W
  $wd = @($Cmd -split ' ' | Where-Object { $_ -ne '' })
  $verb = [string]$wd[0]; $id = if ($wd.Count -gt 1) { [string]$wd[1] } else { '' }
  $f = @{}; $sw = @{}; $pos = @()
  for ($i = 2; $i -lt $wd.Count; $i++) {
    $x = [string]$wd[$i]
    if ($x.StartsWith('--')) { $n = $x.Substring(2); if ($n -in $Valued -and $i + 1 -lt $wd.Count) { $f[$n] = [string]$wd[$i + 1]; $i++ } else { $sw[$n] = $true } } else { $pos += $x }
  }
  $e.Kind = 'gate'; $e.Verb = $verb; $e.Id = $id; $e.Flags = $f; $e.Sw = $sw; $e.Pos = $pos; $e.Stdin = $Stdin
  if (-not $m.HasGate) { Log "$($m.Name) nogate $verb"; return (New-Res 127 @('bash: line 1: /usr/local/sbin/fcode-deploy-gate: No such file or directory')) }
  if ($m.NoMove) { Log "$($m.Name) nomove $verb"; return (New-Res 65 @('GATE_ERROR gate installed without exactly one project argument', 'GATE_EXIT 65')) }
  if ($verb -ceq 'status') {
    $e.Step = 'status'; Log "$($m.Name) status$(if ($f['lst']) { ' --lst ' + $f['lst'] })"
    $flt = Get-Fault $m.Name 'status'
    if ($flt) { if ($flt.Mode -eq 'timeout') { return (New-Res 124 @()) }; if ($flt.Mode -eq 'down') { return (New-Res 255 @()) } }
    if ($m.Running) { $m.Running.Left--; if ($m.Running.Left -lt 0) { Complete-Running $m } }
    if ($f['lst']) { $o = @(foreach ($l in @($m.Lst[$f['lst']])) { if ($null -ne $l) { "MOVE lst $l" } }); return (New-Res 0 ($o + 'GATE_EXIT 0')) }
    $sf = Get-StatusFields $m
    if ($sw['json']) {
      $j = [ordered]@{}; foreach ($k in $sf.Keys) { $v = $sf[$k]; if ($v -ceq '-') { $j[$k] = $null } elseif ($v -match '\A[0-9]+\z' -and $k -notin 'gate', 'call', 'move_id', 'hostname') { $j[$k] = [long]$v } else { $j[$k] = $v } }
      $j['inbound'] = @()
      return (New-Res 0 @((ConvertTo-Json -InputObject $j -Compress), 'GATE_EXIT 0'))
    }
    return (New-Res 0 @(('MOVE state ' + (@(foreach ($k in $sf.Keys) { "$k=$($sf[$k])" }) -join ' ')), 'GATE_EXIT 0'))
  }
  $mi = $m.MoveId
  # the door (D.12.2): a finished old / an aborted new answers every --move but status
  if ($mi -and (($mi.state -ceq 'finished' -and $mi.role -ceq 'old') -or ($mi.state -ceq 'aborted' -and $mi.role -ceq 'new'))) {
    $wd = if ($mi.state -ceq 'finished') { 'moved' } else { 'aborted' }
    Log "$($m.Name) door-$wd $verb $($f['call'])"; return (New-Res 1 @("GATE_ERROR $wd", 'GATE_EXIT 1'))
  }
  if ($verb -ceq 'plan' -and -not $f.ContainsKey('call')) {
    if ($sw['check']) { [void]$W.Violations.Add('plan --check sent without --call (it is the recorded x.check)') }
    if ($f.ContainsKey('budget')) { [void]$W.Violations.Add('an unrecorded plan form carries --budget') }
    if ($sw['check-only'] -and $id -ceq '-') {
      $e.Step = 'plan:check'; Log "$($m.Name) plan:check"
      foreach ($k in 'dir', 'attempt', 'sha', 'serving') { if ($f.ContainsKey($k)) { [void]$W.Violations.Add("plan - --check-only carries --$k (D.0.1)") } }
      $flt = Get-Fault $m.Name 'plan:check'; if ($flt) { if ($flt.Mode -eq 'noexit') { return (New-Res 0 @($flt.Out)) }; return (New-Res $flt.Rc (@($flt.Out) + "GATE_EXIT $($flt.Rc)")) }
      return (New-Res $W.CheckCode (@($W.CheckOut) + "GATE_EXIT $($W.CheckCode)"))
    }
    if ($sw['check-only']) {
      $e.Step = 'plan:check-only'; Log "$($m.Name) plan:check-only"; $script:Clock = $script:Clock.AddSeconds(7)
      foreach ($k in 'dir', 'attempt', 'sha', 'serving') { if (-not $f.ContainsKey($k)) { [void]$W.Violations.Add("plan <id> --check-only lacks --$k (D.0.1)") } }
      $flt = Get-Fault $m.Name 'plan:check-only'; if ($flt) { return (New-Res $flt.Rc (@($flt.Out) + "GATE_EXIT $($flt.Rc)")) }
      return (New-Res $W.CheckOnlyCode (@($W.CheckOnlyOut) + "GATE_EXIT $($W.CheckOnlyCode)"))
    }
    $e.Step = 'plan:full'; $W.PlanN++; Log "$($m.Name) plan:full"
    foreach ($k in 'dir', 'attempt', 'sha', 'serving') { if ($f.ContainsKey($k)) { [void]$W.Violations.Add("plan <id> carries --$k (D.0.1)") } }
    $lines = @($Stdin -split '\r?\n' | Where-Object { $_ -ne '' })
    [void]$W.PlanStdin.Add($lines)
    $tu = @($lines | Where-Object { $_ -cmatch '\Atarget-user ' })
    $mapl = @($lines | Where-Object { $_ -cnotmatch '\Atarget-user ' })
    # plan <id> copies the stdin `idmap <user|group> <name> <src_id> <dst_id>` lines into the manifest's idmap[] (B.6.2); plan --check / --check-only keep the pinned value
    $W.Mf.idmap = @(foreach ($l in $lines) { if ($l -cmatch '\Aidmap (user|group) (\S+) ([0-9]+) ([0-9]+)\z') { [ordered]@{ kind = $Matches[1]; name = $Matches[2]; src_id = [int]$Matches[3]; dst_id = [int]$Matches[4] } } })
    $out = @($W.PlanOut); $code = $W.PlanCode
    if ($W.PlanHook) { $h = & $W.PlanHook $W.PlanN $mapl; if ($h) { $out = @($h.Out); $code = $h.Code } }
    $flt = Get-Fault $m.Name 'plan:full'; if ($flt) { $out = @($flt.Out); $code = $flt.Rc; if ($flt.Mode -ceq 'nomanifest') { return (New-Res $code (@($out) + "GATE_EXIT $code")) } }   # nomanifest: a refusal the server prints without a manifest (map-invalid, _mvp_finalize)
    return (New-Res $code (@($out) + (Get-ManifestLine $tu) + "GATE_EXIT $code"))
  }
  # a recorded call
  if (-not $f.ContainsKey('call')) { [void]$W.Violations.Add("--move $verb sent without --call (every verb but status and the read-only plan forms is recorded)"); return (New-Res 65 @('MOVE error bad-request why=call-id', 'GATE_EXIT 65')) }
  $call = $f['call']; $e.Call = $call; $e.Budget = $f['budget']
  if ($call -notmatch $CallRx) { [void]$W.Violations.Add("call id not in the closed step list: $call"); return (New-Res 65 @('MOVE error bad-request why=call-id', 'GATE_EXIT 65')) }
  $cm = [regex]::Match($call, '^(fwd|back)-([0-9]+)-(.+)$'); $step = $cm.Groups[3].Value; $e.Step = $step
  if ($f['dir'] -cne $cm.Groups[1].Value -or $f['attempt'] -cne $cm.Groups[2].Value) { [void]$W.Violations.Add("call id $call disagrees with --dir $($f['dir']) --attempt $($f['attempt'])") }
  foreach ($k in 'dir', 'attempt', 'sha', 'budget', 'serving', 'mark', 'dst-started', 'phase') { if (-not $f.ContainsKey($k)) { [void]$W.Violations.Add("recorded call $call lacks --$k (D.0.1)") } }
  if ($f['budget'] -notmatch '\A[0-9]+\z') { [void]$W.Violations.Add("recorded call ${call}: --budget is not an integer") }
  $tag = "$($m.Name) $call"
  if ($m.Running) {
    if ($m.Running.Call -cne $call) { Log "$tag busy"; return (New-Res 75 @('MOVE error busy', 'GATE_EXIT 75')) }
    $e.Attach = $true; Log "$tag attach"; Complete-Running $m; $rec = $m.Rec[$call]
    return (New-Res ([int]$rec.Rc) (@($rec.Out) + "MOVE call id=$call rc=$($rec.Rc) dur_s=$($rec.Dur)" + "GATE_EXIT $($rec.Rc)"))
  }
  $isInit = ($verb -ceq 'init' -and -not $sw['repin'])
  $mark = $f['mark']; $markNull = (-not $mark -or $mark -ceq 'null')
  if ($step -like 'p.*') {
    if ($cm.Groups[2].Value -cne '0') { [void]$W.Violations.Add("p.* call with attempt $($cm.Groups[2].Value)") }
    if ($mi -and $mi.state -ceq 'open' -and $mi.id -cne $id) { Log "$tag other-move"; return (New-Res 65 @("MOVE error other-move id=$($mi.id)", 'GATE_EXIT 65')) }
  } elseif ($isInit) {
    $role = $f['role']
    if (($step -match 'init-old' -and $role -cne 'old') -or ($step -match 'init-new' -and $role -cne 'new')) { [void]$W.Violations.Add("$call sent with --role $role") }
    $side = if (($role -ceq 'old' -and $f['dir'] -ceq 'fwd') -or ($role -ceq 'new' -and $f['dir'] -ceq 'back')) { 'src' } else { 'dst' }
    if ($side -ceq 'dst' -and $markNull -and $f['serving'] -ceq $role) { Log "$tag init-serving"; return (New-Res 65 @('MOVE error bad-request why=init-serving', 'GATE_EXIT 65')) }
    if ($mi -and $mi.state -ceq 'open' -and $mi.id -cne $id) { Log "$tag other-move"; return (New-Res 65 @("MOVE error other-move id=$($mi.id)", 'GATE_EXIT 65')) }
  } else {
    if (-not $mi -and $step -like 'a.*') { Log "$tag (nothing to abort)"; return (New-Res 0 @("MOVE call id=$call rc=0 dur_s=0", 'GATE_EXIT 0')) }
    if (-not $mi) { Log "$tag no-move"; return (New-Res 65 @('MOVE error no-move', 'GATE_EXIT 65')) }
    if ($mi.id -cne $id) { Log "$tag other-move"; return (New-Res 65 @("MOVE error other-move id=$($mi.id)", 'GATE_EXIT 65')) }
    if ($mi.dir -cne $f['dir'] -or "$($mi.attempt)" -cne $f['attempt']) { Log "$tag mismatch"; return (New-Res 65 @("MOVE error move-id-mismatch dir=$($mi.dir) attempt=$($mi.attempt)", 'GATE_EXIT 65')) }
  }
  if ($verb -ceq 'init' -and $sw['repin']) {
    if (($step -like 'c.repin.*' -and -not $markNull) -or ($step -ceq 'x.repin' -and $mark -cne 'cutting') -or ($step -notlike 'c.repin.*' -and $step -cne 'x.repin')) { Log "$tag repin-step"; return (New-Res 65 @('MOVE error bad-request why=repin-step', 'GATE_EXIT 65')) }
  }
  $norm = @(); for ($i = 0; $i -lt $wd.Count; $i++) { $x = [string]$wd[$i]; if ($x.StartsWith('--') -and $x.Substring(2) -in $IgnoredFlags) { $i++; continue }; $norm += $x }
  $normS = $norm -join ' '
  if ($m.Rec.ContainsKey($call)) {
    $rec = $m.Rec[$call]
    if ($rec.Argv -cne '?' -and $rec.Argv -cne $normS) { Log "$tag call-argv"; return (New-Res 65 @('MOVE error bad-request why=call-argv', 'GATE_EXIT 65')) }
    if ($null -ne $rec.Rc -and [int]$rec.Rc -eq 0) { $e.Replay = $true; Log "$tag (replay)"; return (New-Res 0 (@($rec.Out) + "MOVE call id=$call rc=0 dur_s=$($rec.Dur)" + 'GATE_EXIT 0')) }
  }
  Log $tag
  if ($mi) { if ($f.ContainsKey('mark')) { $mi.mark = $(if ($markNull) { $null } else { $mark }) }; foreach ($k in 'phase', 'serving', 'dst-started') { if ($f.ContainsKey($k)) { $mi[$k.Replace('-', '_')] = $f[$k] } } }
  $hk = $W.Hooks[$step]; if ($hk) { & $hk $m $e }
  $flt = Get-Fault $m.Name $call
  $rc = 0; $out = Get-DefaultOut $m $step $call; $eff = $true
  if ($flt) { $rc = $flt.Rc; if ($null -ne $flt.Out) { $out = @($flt.Out) }; $eff = ($rc -eq 0 -or $flt.Effect -or ($step -ceq 'x.freeze' -and $rc -eq 75)); if ($flt.Do) { & $flt.Do $m $e } }
  $dur = 5; foreach ($k in $W.Dur.Keys) { if ($step -match $k) { $dur = $W.Dur[$k] } }
  $rec = @{ Rc = $rc; Out = @($out); Dur = $dur; Argv = $normS; Start = (Format-Iso $script:Clock); End = (Format-Iso $script:Clock.AddSeconds($dur)) }
  $m.Rec[$call] = $rec; [void]$m.Order.Add($call); $m.Last = $call
  $script:Clock = $script:Clock.AddSeconds($dur)   # the fake clock moves by each recorded call's dur: every record has its own Start, "now" is later than all of them
  if ($flt -and $flt.Mode -ceq 'running') { $rec.Rc = $null; $m.Running = @{ Call = $call; Left = $flt.Left; Rc = $rc; Step = $step; Verb = $verb; F = $f; Sw = $sw; Id = $id; Stdin = $Stdin }; return (New-Res 124 @()) }
  if ($eff) { Apply-Effects $m $step $verb $f $sw $id $Stdin }
  if ($flt -and $flt.Mode -ceq 'noexit') { return (New-Res 255 @($out)) }
  if ($flt -and $flt.Mode -ceq 'timeout') { $rec.Rc = 143; return (New-Res 124 @()) }
  if ($flt -and $flt.Mode -ceq 'down') { $m.Up = $false; return (New-Res 255 @()) }
  New-Res $rc (@($out) + "MOVE call id=$call rc=$rc dur_s=$dur" + "GATE_EXIT $rc")
}
function Get-DefaultOut($m, [string]$Step, [string]$Call) {
  if ($Step -match '^(c\.verify\.[0-9]+|x\.verify)$') {
    $o = @(); $lst = @()
    foreach ($it in @($script:W.Mf.items)) {
      $d = $m.Digest[$it.id]; $l = if ($d) { $d } else { 'aaaaaaaaaaaa' }
      $o += "MOVE digest item=$($it.id) n=$($it.inodes) list=$l sum=bbbbbbbbbbbb"
      $lst += "# item=$($it.id)"; for ($k = 1; $k -le 25; $k++) { $lst += ("$($it.root)/f$k`tf`t10`t0644`troot`troot`t1700000000000000000`t`t" + $(if ($d -and $k -eq 3) { 'user:bob:r--' } else { '' })) }
    }
    $m.Lst[$Call] = $lst; return $o
  }
  if ($Step -ceq 'x.check') { return @(Get-ManifestLine $null) }
  @("LOG $Step done")
}
function Apply-Effects($m, [string]$Step, [string]$Verb, $f, $sw, [string]$Id, [string]$Stdin) {
  switch -regex ($Step) {
    '^(c\.init-(old|new)|b\.init-(new|old))$' {
      $j = $null; try { $j = $Stdin | ConvertFrom-Json } catch { [void]$script:W.Violations.Add("init stdin is not JSON") }
      $m.MoveId = @{ id = $Id; role = $f['role']; dir = $f['dir']; attempt = [int]$f['attempt']; state = 'open'; mark = $(if ($f['mark'] -and $f['mark'] -cne 'null') { $f['mark'] } else { $null }); phase = $f['phase']; serving = $f['serving']; dst_started = $f['dst-started']; old_addr = $(if ($j) { $j.old_addr }); new_addr = $(if ($j) { $j.new_addr }) }
      $m.InitStdin = $j; $m.Sha = $f['sha']
      if ($Step -ceq 'c.init-new' -and $j -and $j.PSObject.Properties['target'] -and -not $m.Target) { $m.Target = ConvertTo-Json -InputObject $j.target -Depth 10 -Compress }   # MV_DIR/target.json, written only when absent (D.0.9)
      if ($f['role'] -ceq 'new' -and $f['dir'] -ceq 'fwd') { $m.Frozen = $true; $m.Active = 0; $m.Enabled = $false }
    }
    '^(c\.repin\.[0-9]+|x\.repin)$' { $m.Sha = $f['sha']; try { $m.RepinStdin = $Stdin | ConvertFrom-Json } catch { [void]$script:W.Violations.Add('repin stdin is not JSON') } }
    '^(c\.prepare\.[0-9]+|x\.prepare-id)$' { $m.Hostname = $script:W.Mf.identity.hostname }
    '^x\.freeze$' { $m.Frozen = $true }
    '^(x\.unfreeze\.[0-9]+|r\.unfreeze-src)$' { $m.Frozen = $false }
    '^(x\.stop-src|x\.stop-dst|r\.stop-dst)$' { $m.Active = 0; $m.Enabled = $false }
    '^x\.start$' { $m.Active = $m.Holds }
    '^(x\.enable\.[0-9]+|r\.start-src)$' { $m.Active = $m.Holds; $m.Enabled = $true }
    '^f\.(old|new)$' { if ($m.MoveId) { $m.MoveId.state = 'finished' }; $m.Frozen = $false }
    '^a\.(old|new)$' { if ($m.MoveId) { $m.MoveId.state = 'aborted' }; $m.Frozen = $false }
    '^x\.switch$' { $m.Switched = $true }
  }
}

function Fake-Script($m, [string]$Text, $e) {
  $W = $script:W
  $sa = @()
  if ($Text -match '\Aset -- (.*?)\r?\n') { $sa = @([regex]::Matches($Matches[1], "'((?:[^']|'\\'')*)'") | ForEach-Object { $_.Groups[1].Value -replace "'\\''", "'" }) }
  $name = if ($Text -match '(?m)^# fcode move: ([^\r\n]+?)\s*$') { $Matches[1] } else { 'unknown' }
  $e.Kind = 'script'; $e.Script = $name; $e.Args = $sa; $e.Step = "script:$name"
  Log "$($m.Name) script:$name"
  $flt = Get-Fault $m.Name "script:$name"
  if ($flt) { if ($flt.Do) { & $flt.Do $m $e }; if ($flt.Mode -eq 'down') { return (New-Res 255 @()) }; return (New-Res $flt.Rc @($flt.Out)) }
  switch ($name) {
    'preflight' { return (New-Res $W.PfCode @($W.Pf)) }
    'facts' { return (New-Res 0 (@($m.Legacy) + @("MOVE facts os=$($m.Os) arch=x86_64 systemd=257 epoch=$(Get-Epoch ($script:Clock.AddSeconds($m.Skew)))"))) }   # the legacy origin lines ($LegacyFactsLine) come first, as T10d's script prints them
    'bootstrap key' { return (New-Res 0 @("MOVE key type=ssh-ed25519 pub=$TheMoveKey")) }
    'bootstrap gate' { $m.HasGate = $true; $m.Gate = $(if ($W.NewGate.Count) { $W.NewGate.Dequeue() } else { $W.old.Gate }); return (New-Res 0 @('LOG gate installed')) }
    'tcp' { $k = "$($sa[0]):$($sa[1])"; return (New-Res $(if ($W.TcpFail.ContainsKey($k)) { 1 } else { 0 }) @()) }
    'rebuild read' {
      if (-not $m.MoveId) { return (New-Res 1 @()) }
      $mi = $m.MoveId; $o = @('MOVE moveid ' + (@(foreach ($k in 'id', 'role', 'dir', 'attempt', 'state', 'mark', 'dst_started', 'phase', 'serving', 'old_addr', 'new_addr') { "$k=$(if ($null -ne $mi[$k]) { $mi[$k] })" }) -join ' '))
      $o += "MOVE hostkey ssh-ed25519 $($m.Key)"
      foreach ($c in $m.Order) { $r = $m.Rec[$c]; $o += "MOVE record id=$c start=$(if ($r.Start) { $r.Start } else { '-' }) end=$(if ($r.End) { $r.End } else { '-' }) rc=$(if ($null -ne $r.Rc) { $r.Rc } else { '-' })" }
      $o += (Get-ManifestLine $null)
      if ($m.Target) { $o += "MOVE target $($m.Target)" }   # new only: c.init-new kept it (D.0.10)
      return (New-Res 0 $o)
    }
    default { return (New-Res 0 @()) }
  }
}

function Invoke-MoveTool([string]$Tool, [string[]]$ToolArgs, [string]$Stdin = $null) {
  $W = $script:W
  $a = @($ToolArgs | ForEach-Object { [string]$_ })
  [void]$W.ToolLog.Add(@{ Tool = $Tool; Args = $a; Stdin = $Stdin })
  if ($Tool -match 'ssh-keygen') {
    [void]$W.KeygenLog.Add($a)
    $fi = [Array]::IndexOf($a, '-f'); $file = if ($fi -ge 0 -and $fi + 1 -lt $a.Count) { $a[$fi + 1] } else { $null }
    if ($a -ccontains '-F') {
      if (-not $file) { [void]$W.Violations.Add('ssh-keygen -F on the default known_hosts (B.11.3)'); return @{ Code = 1; Out = @() } }
      $name = $a[[Array]::IndexOf($a, '-F') + 1]
      $ls = if (Test-Path -LiteralPath $file) { @([IO.File]::ReadAllLines($file)) } else { @() }
      $hit = @($ls | Where-Object { $p = @("$_".Trim() -split '\s+'); $p.Count -ge 3 -and (@($p[0] -split ',') -ccontains $name) })
      if ($hit.Count) { return @{ Code = 0; Out = @("# Host $name found: line 1") + $hit } } else { return @{ Code = 1; Out = @() } }
    }
    if ($a -ccontains '-R') { $name = $a[[Array]::IndexOf($a, '-R') + 1]; if ($file -and (Test-Path -LiteralPath $file)) { $ls = @([IO.File]::ReadAllLines($file) | Where-Object { -not (@(@("$_".Trim() -split '\s+')[0] -split ',') -ccontains $name) }); [IO.File]::WriteAllText($file, (($ls -join "`n") + $(if ($ls.Count) { "`n" } else { '' })), $utf8) }; return @{ Code = 0; Out = @() } }
    if (($a -ccontains '-l') -or ($a -ccontains '-lf')) {
      $src = if ($file -and $file -ne '-') { [IO.File]::ReadAllText($file) } else { "$Stdin" }
      $o = @(foreach ($l in @($src -split '\r?\n')) { $p = @($l.Trim() -split '\s+'); $ki = [Array]::IndexOf($p, 'ssh-ed25519'); if ($ki -ge 0 -and $ki + 1 -lt $p.Count) { "256 $(Get-Fp $p[$ki + 1]) $(if ($ki -gt 0) { $p[0] } else { 'no comment' }) (ED25519)" } })
      return @{ Code = $(if ($o.Count) { 0 } else { 1 }); Out = $o }
    }
    return @{ Code = 0; Out = @() }
  }
  if ($Tool -match 'ssh-keyscan') { $h = $a[-1]; $m = Get-Machine (Resolve-Addr $h @{}); if ($m) { return @{ Code = 0; Out = @("$h ssh-ed25519 $($m.Key)") } }; return @{ Code = 1; Out = @() } }
  if ($Tool -match '(^|[\\/])ssh(\.exe)?$' -and $a[0] -ceq '-G') {
    $h = Get-ConfigHosts (Get-LaptopConfig); $al = $a[1]
    $hn = if ($h.ContainsKey($al) -and $h[$al]) { $h[$al] } else { $al }
    return @{ Code = 0; Out = @("host $al", "hostname $hn", 'port 22', 'user root') }
  }
  if ($Tool -match '(^|[\\/])gh(\.exe)?$') {
    $t = $a -join ' '
    [void]$W.GhLog.Add(@{ Text = $t; Stdin = $Stdin })
    Log "gh $t"
    foreach ($r in $W.Gh) { if ($r.N -ne 0 -and $t -match $r.Rx) { if ($r.N -gt 0) { $r.N-- }; return @{ Code = $r.Code; Out = @($r.Out) } } }
    if ($t -match $GhForm.SecretListAny) { return @{ Code = 0; Out = @("DEPLOY_KNOWN_HOSTS`t2026-10-01T00:00:00Z", "DEPLOY_SSH_KEY`t2026-10-01T00:00:00Z") } }
    if ($t -match $GhForm.Json -or $t -match $GhForm.Api) { return @{ Code = 0; Out = @('[]') } }
    return @{ Code = 0; Out = @() }
  }
  @{ Code = 0; Out = @() }
}
function Add-Gh([string]$Rx, [string[]]$Out = @(), [int]$Code = 0, [int]$N = -1) { [void]$script:W.Gh.Insert(0, @{ Rx = $Rx; Out = $Out; Code = $Code; N = $N }) }

# the coder box: the laptop's script runs with real bash in a fake HOME (bash cases); without bash the coder answers nothing (unreachable)
function Invoke-BoxScript([string]$Script, [string[]]$ScriptArgs) {
  [void]$script:W.BoxLog.Add(@{ Script = $Script; Args = @($ScriptArgs) }); [void]$script:W.BoxStates.Add((Get-St)); Log 'coder script'
  if (-not $script:W.CoderUp -or -not $script:BashExe) { $global:LASTEXITCODE = 255; return }
  $f = Join-Path $Root ('box-' + [guid]::NewGuid().ToString('N') + '.sh')
  $pre = if (@($ScriptArgs).Count) { 'set -- ' + ((@($ScriptArgs) | ForEach-Object { "'" + ("$_" -replace "'", "'\''") + "'" }) -join ' ') + "`n" } else { '' }
  [IO.File]::WriteAllText($f, $pre + ($Script -replace "`r`n", "`n"), $utf8)
  $oldHome = $env:HOME; $env:HOME = $CoderHome
  try { $o = @(& $script:BashExe $f 2>&1 | ForEach-Object { "$_" }); $c = $LASTEXITCODE } finally { $env:HOME = $oldHome; Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
  $global:LASTEXITCODE = $c
  $o
}

# ============================== running the laptop ==============================
function Run-Move([string[]]$Words) {
  $script:W.From = $script:W.Log.Count; $script:W.CallFrom = $script:W.Calls.Count
  # every `fcode move` is a fresh process: drop the script variables the laptop's move functions keep ($script:Move*)
  Get-Variable -Scope Script | Where-Object { $_.Name -clike 'Move*' } | ForEach-Object { Remove-Variable -Name $_.Name -Scope Script -Force -ErrorAction SilentlyContinue }
  $all = @(& { Invoke-Move $Words } 6>&1)
  $code = @($all | Where-Object { $_ -isnot [Management.Automation.InformationRecord] })
  $text = @($all | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" })
  if ($code.Count -ne 1) { throw "Invoke-Move $($Words -join ' ') returned $($code.Count) values: $($code -join ',') :: $($text -join ' | ')" }
  $script:Last = @{ Code = [int]$code[0]; Text = ($text -join "`n"); Words = $Words }
  $script:W.OutFrom = $script:W.Out.Count
  foreach ($t in $text) { foreach ($l in @($t -split '\r?\n')) { [void]$script:W.Out.Add($l.TrimEnd()) } }
  $script:Last
}
function MoveDir { Join-Path (Join-Path $Home2 '.fcode') 'move' }
function StatePath { Join-Path (MoveDir) 'state.json' }
function Get-St { $p = StatePath; if (-not (Test-Path -LiteralPath $p)) { return $null }; [IO.File]::ReadAllText($p) | ConvertFrom-Json }
function Set-Prop($o, [string]$Name, $Value) { if ($o.PSObject.Properties[$Name]) { $o.$Name = $Value } else { Add-Member -InputObject $o -NotePropertyName $Name -NotePropertyValue $Value } }
function Patch-St([hashtable]$P) { $s = Get-St; if (-not $s) { throw 'fixture: no state.json to patch' }; foreach ($k in $P.Keys) { Set-Prop $s $k $P[$k] }; [IO.File]::WriteAllText((StatePath), (ConvertTo-Json -InputObject $s -Depth 20), $utf8); $s }
# one whole expected time string: a record's Start, a state.json field read from the raw text (never through ConvertFrom-Json), the expected <giờ>
function Rec-Start([string]$M, [string]$Call) { $r = $script:W[$M].Rec[$Call]; if (-not $r -or -not $r.Start) { throw "fixture: no Start for $M $Call" }; [string]$r.Start }
$StRawVal = '("(?:[^"\\]|\\.)*"|true|false|null|-?\d+(?:\.\d+)?)'
function St-Raw([string]$Field) {
  $t = [IO.File]::ReadAllText((StatePath)); $ms = [regex]::Matches($t, '"' + [regex]::Escape($Field) + '"\s*:\s*' + $StRawVal)
  if ($ms.Count -eq 0) { return $null }; if ($ms.Count -gt 1) { throw "St-Raw: $($ms.Count) keys named $Field in state.json" }
  $v = $ms[0].Groups[1].Value; if ($v.StartsWith('"')) { $v.Substring(1, $v.Length - 2) } else { $v }
}
# St-RawSet <field> <JSON literal>: a raw text replace in state.json ($null removes the key), so no JSON round trip rewrites a time
function St-RawSet([string]$Field, $Literal) {
  $p = StatePath; $t = [IO.File]::ReadAllText($p); $k = '"' + [regex]::Escape($Field) + '"\s*:\s*' + $StRawVal
  $n = [regex]::Matches($t, $k).Count; if ($n -ne 1) { throw "St-RawSet: $n keys named $Field in state.json" }
  if ($null -eq $Literal) { $t2 = [regex]::Replace($t, ',\s*' + $k, ''); if ($t2 -ceq $t) { $t2 = [regex]::Replace($t, $k + '\s*,?', '') } }
  else { $t2 = [regex]::Replace($t, $k, { param($mm) $mm.Value.Substring(0, $mm.Groups[1].Index - $mm.Index) + $Literal }) }
  [IO.File]::WriteAllText($p, $t2, $utf8)
}
function Expect-Gio([string]$Iso) { (ConvertTo-MoveTime $Iso).ToLocalTime().ToString($GioFmt, [Globalization.CultureInfo]::InvariantCulture) }
function Get-QuestionTime { $q = @(Lines -Last | Where-Object { $_ -match 'Mọi thay đổi trên máy mới (?:từ|sau) (.+) sẽ mất' } | Select-Object -First 1); Ok ($q.Count -eq 1) "question asked: $(Lines -Last)"; [void]($q[0] -match '(?:từ|sau) (.+) sẽ mất'); $Matches[1] }
# calls of the last run (or of the whole case with -All)
function Calls([switch]$All) { $from = if ($All) { 0 } else { $script:W.CallFrom }; @(for ($i = $from; $i -lt $script:W.Calls.Count; $i++) { $script:W.Calls[$i] }) }
function RecCalls([switch]$All) { @(Calls -All:$All | Where-Object { $_.Call }) }
function LogNow([switch]$All) { $from = if ($All) { 0 } else { $script:W.From }; @(for ($i = $from; $i -lt $script:W.Log.Count; $i++) { $script:W.Log[$i] }) }
# a call that ran a verb body: replays and attaches to a running unit are not counted
function Sent([string]$M, [string]$Rx, [switch]$All) { @(RecCalls -All:$All | Where-Object { $_.M -ceq $M -and $_.Call -match $Rx -and -not $_.Replay -and -not $_.Attach }).Count }
function SentAny([string]$Rx, [switch]$All) { @(RecCalls -All:$All | Where-Object { $_.Call -match $Rx }).Count }
function Ordered([string[]]$Rxs, [switch]$All) { $l = LogNow -All:$All; $p = -1; foreach ($rx in $Rxs) { $hit = -1; for ($i = $p + 1; $i -lt $l.Count; $i++) { if ($l[$i] -match $rx) { $hit = $i; break } }; if ($hit -lt 0) { throw "missing or out of order: $rx   in: $($l -join ' ; ')" }; $p = $hit } }
function Before([string]$A, [string]$B) { $l = LogNow; $ia = -1; $ib = -1; for ($i = 0; $i -lt $l.Count; $i++) { if ($ia -lt 0 -and $l[$i] -match $A) { $ia = $i }; if ($ib -lt 0 -and $l[$i] -match $B) { $ib = $i } }; Ok ($ia -ge 0) "missing: $A in $($l -join ' ; ')"; Ok ($ib -ge 0) "missing: $B in $($l -join ' ; ')"; Ok ($ia -lt $ib) "$A must come before $B in $($l -join ' ; ')" }
function HasText([string]$S) { Ok ($script:Last.Text.Contains($S)) "output lacks [$S]: $($script:Last.Text)" }
# every output line of the case (-Last: of the last run only), the owner questions included
function Lines([switch]$Last) { $from = if ($Last) { $script:W.OutFrom } else { 0 }; @(for ($i = $from; $i -lt $script:W.Out.Count; $i++) { $script:W.Out[$i] }) }
function NoText([string]$S) { Ok (-not $script:Last.Text.Contains($S)) "output must not hold [$S]" }
function NoRecorded([string]$What = 'refusal') { $r = @(RecCalls | Where-Object { -not $_.Replay }); Ok ($r.Count -eq 0) "$What must send no recorded call; sent: $(@($r | ForEach-Object { $_.M + ' ' + $_.Call }) -join ', ')" }
function NoChore0 { Ok ((SentAny '-x\.(enable|unfreeze)\.') -eq 0) "chore 0 (x.enable.N / x.unfreeze.N) must not run here: $(@(RecCalls | ForEach-Object { $_.M + ' ' + $_.Call }) -join ', ')" }

# ---- flows ----
function Do-Plan([string[]]$Extra = @(), [int]$Want = 0) {
  $r = Run-Move (@('plan', $NewAlias, '--addr', $NewAddr) + $Extra)
  if ($Want -ge 0) { Eq $r.Code $Want "plan exit ($($r.Text))" }
  $r
}
function Do-Copy([int]$Want = 0) { $r = Run-Move @('copy'); if ($Want -ge 0) { Eq $r.Code $Want "copy exit ($($r.Text))" }; $r }
function Do-Cutover([int]$Want = 0) { Ans 'có'; $r = Run-Move @('cutover'); if ($Want -ge 0) { Eq $r.Code $Want "cutover exit ($($r.Text))" }; $r }
function Fx-Planned { [void](Do-Plan) }
function Fx-Copied { [void](Do-Plan); [void](Do-Copy) }
function Fx-Cut { Fx-Copied; [void](Do-Cutover) }
function Fx-BackDone { Fx-Cut; Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "back exit ($($r.Text))"; Eq (Get-St).phase 'back-done' 'fixture back-done' }
# a recorded call whose unit still runs (its record has no rc yet); the fake attaches when the same id comes again
function Set-Running([string]$M, [string]$Call) {
  $mc = $script:W[$M]; $st = $Call -replace '^(fwd|back)-[0-9]+-', ''
  $mc.Rec[$Call] = @{ Rc = $null; Out = @("LOG $Call"); Dur = 5; Argv = '?'; Start = ''; End = '' }; [void]$mc.Order.Add($Call); $mc.Last = $Call
  $mc.Running = @{ Call = $Call; Left = 1000; Rc = 0; Step = $st; Verb = ''; F = @{}; Sw = @{}; Id = (Id); Stdin = '' }
}
function Fx-RolledBack { Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Rc 1; [void](Do-Cutover 10); Eq (Get-St).phase 'rolled-back' 'fixture rolled-back' }
function Id { (Get-St).move_id }
function Add-Rec([string]$M, [string]$Call, [int]$Rc = 0) { $mc = $script:W[$M]; $mc.Rec[$Call] = @{ Rc = $Rc; Out = @("LOG $Call"); Dur = 5; Argv = '?'; Start = ''; End = '' }; [void]$mc.Order.Add($Call); $mc.Last = $Call }
# make both machines' move-ids agree with the laptop state (the real state a laptop crash leaves behind)
function Set-Real([string]$Dir, [int]$Attempt, $Mark = $null, [string]$Phase = '', [string]$Serving = 'old', [int]$DstStarted = 0) {
  $id = Id
  foreach ($n in 'old', 'new') { $m = $script:W[$n]; $m.HasGate = $true; $m.MoveId = @{ id = $id; role = $n; dir = $Dir; attempt = $Attempt; state = 'open'; mark = $Mark; phase = $Phase; serving = $Serving; dst_started = "$DstStarted"; old_addr = $OldAddr; new_addr = $NewAddr } }
}
function Recs([string]$M, [string]$Pre, [string[]]$Steps, [int]$Rc = 0) { foreach ($s in $Steps) { Add-Rec $M "$Pre-$s" $Rc } }
# fwd cutover in flight, the laptop gone after step 5 (both stops done), dst_started false
function Fx-Cutting0 {
  Fx-Copied
  [void](Patch-St @{ mark = 'cutting'; dst_started = $false })
  Set-Real 'fwd' 1 'cutting' 'copied' 'old' 0
  Recs 'old' 'fwd-1' @('x.freeze', 'x.check', 'x.baseline', 'x.guards', 'x.stop-src'); Recs 'new' 'fwd-1' @('x.repin', 'x.stop-dst')
  $o = $script:W.old; $o.Frozen = $true; $o.Active = 0; $o.Enabled = $false
  $n = $script:W.new; $n.Frozen = $true; $n.Active = 0; $n.Enabled = $false
}
function Fx-CuttingStarted {
  Fx-Cutting0
  [void](Patch-St @{ dst_started = $true }); Set-Real 'fwd' 1 'cutting' 'copied' 'old' 1
  Recs 'new' 'fwd-1' @('x.final', 'x.verify', 'x.prepare-id', 'x.adopt'); Recs 'old' 'fwd-1' @('x.verify')
}
function Fx-Switching {
  Fx-CuttingStarted
  [void](Patch-St @{ mark = 'switching' }); Set-Real 'fwd' 1 'switching' 'copied' 'old' 1
  Recs 'new' 'fwd-1' @('x.start', 'x.health'); $script:W.new.Active = $Holds
}
function Fx-RollingBack {
  Fx-Cutting0
  [void](Patch-St @{ mark = 'rolling-back' }); Set-Real 'fwd' 1 'rolling-back' 'copied' 'old' 0
  Add-Rec 'new' 'fwd-1-x.final' 1; Add-Rec 'new' 'fwd-1-r.stop-dst' 0
}
# a carry-back written ahead and both b.init done (fwd mark kept), the laptop gone before x.freeze on new
function Fx-Carry {
  Fx-Switching
  Add-Rec 'new' 'fwd-1-x.switch' 1
  [void](Patch-St @{ dir = 'back'; attempt = 2; phase = 'planned'; carry = $true; mark = 'switching'; dst_started = $true; serving = 'old' })
  Set-Real 'back' 2 'switching' 'planned' 'old' 1
  Add-Rec 'new' 'back-2-b.init-new'; Add-Rec 'old' 'back-2-b.init-old'
}
function Fx-BackAt([string]$Phase, $Mark = $null) {
  Fx-Cut
  [void](Patch-St @{ dir = 'back'; attempt = 2; phase = $Phase; carry = $false; mark = $Mark; dst_started = $false; serving = 'new' })
  Set-Real 'back' 2 $Mark $Phase 'new' 0
  Add-Rec 'new' 'back-2-b.init-new'; Add-Rec 'old' 'back-2-b.init-old'
  if ($Mark) { Add-Rec 'new' 'back-2-x.freeze'; $script:W.new.Frozen = $true }
}
function Fx-BackRolledBack {
  Fx-Cut
  [void](Patch-St @{ dir = 'back'; attempt = 2; phase = 'rolled-back'; carry = $false; mark = $null; dst_started = $false; serving = 'old'; enabled = $true })
  Set-Real 'back' 2 $null 'rolled-back' 'old' 0
  $o = $script:W.old; $o.Frozen = $false; $o.Active = $Holds; $o.Enabled = $true
  $n = $script:W.new; $n.Active = 0; $n.Enabled = $false
}
# a manual back in flight at the switch (steps 2–8 done on both machines), the laptop gone before x.switch
function Fx-BackSwitching {
  Fx-BackAt 'copied' 'switching'
  Recs 'new' 'back-2' @('x.check', 'x.stop-src', 'x.final', 'x.verify'); Recs 'old' 'back-2' @('x.repin', 'x.stop-dst', 'x.verify', 'x.prepare-id', 'x.adopt', 'x.start', 'x.health')
  [void](Patch-St @{ dst_started = $true }); Set-Real 'back' 2 'switching' 'copied' 'new' 1
  $n = $script:W.new; $n.Active = 0; $n.Enabled = $false; $o = $script:W.old; $o.Active = $Holds
}
# a manual back rolling back after x.stop-dst failed on old (E-R19 under way), the laptop gone before new was restarted
function Fx-BackRollingBack {
  Fx-BackAt 'copied' 'rolling-back'
  Recs 'new' 'back-2' @('x.check', 'x.stop-src'); Add-Rec 'old' 'back-2-x.repin'; Add-Rec 'old' 'back-2-x.stop-dst' 1
  $n = $script:W.new; $n.Active = 0; $n.Enabled = $false
}
function Fx-Finished { Fx-Cut; Ans 'YES'; $r = Run-Move @('finish'); Eq $r.Code 0 "finish exit ($($r.Text))" }
function Fx-Aborted { Fx-Copied; Ans 'có'; $r = Run-Move @('abort'); Eq $r.Code 0 "abort exit ($($r.Text))" }
# a carry-back started by a failed x.health on new (E-R8), with an extra fault inside it
function Start-Carry([switch]$NoRun) { Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Rc 69 -Out @('MOVE item app.service kind=unit state=failed ActiveState=failed') }
# a legacy repo as the push scan finds it: a matched workflow and old's /opt/deal-sync origin = its slug (ruling T10c-LP 04/11, $LegacyFactsLine);
# legacy_push[] is a state field, never a manifest field (W1-T3-GAP-11)
function Use-Legacy {
  Add-Gh $GhForm.RepoList @("[{""nameWithOwner"":""$LegacyRepo""}]")
  Add-Gh ($GhForm.WfDir -f $LegacyRepo) @('[{"name":"deploy.yml"}]')
  Add-Gh ($GhForm.WfFile -f $LegacyRepo, 'deploy\.yml') @($LegacyWfLine)
  $script:W.old.Legacy = @($LegacyFactsLine -f 'deal-sync', "git@github.com:$LegacyRepo.git")
}
function NothingWritten([string]$What = 'nothing written') { $s = Get-St; Ok ($null -eq $s -or $s.phase -cne 'planned') $What }

# bash runs (the scripts the laptop sends over plain ssh, run for real against a throw-away FCM_ROOT, tools stubbed through PATH)
function New-Stubs([hashtable]$Bodies) {
  $d = Join-Path $Root ('stubs-' + [guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory -Path $d)
  $all = @{}; foreach ($n in 'apt-get', 'apt-cache', 'apt-mark', 'dpkg', 'dpkg-query', 'curl', 'gpg', 'systemctl', 'docker', 'pm2', 'loginctl', 'git', 'getfacl', 'setfacl', 'mke2fs', 'e2fsck', 'mkfs.ext4') { $all[$n] = 'exit 0' }
  $all['node'] = 'if [ "$1" = -p ]; then echo 22; else echo v22.23.3; fi'
  $all['systemctl'] = 'if [ "$1" = --version ]; then echo "systemd 257 (257.9-1~deb13u1)"; fi; exit 0'
  foreach ($k in $Bodies.Keys) { $all[$k] = $Bodies[$k] }
  foreach ($k in $all.Keys) { $p = Join-Path $d $k; [IO.File]::WriteAllText($p, "#!/bin/bash`n$($all[$k])`n", $utf8); & chmod +x $p }
  $d
}
function Run-Bash([string]$Text, [string[]]$A, [string]$FcmRoot, [string]$Stubs) {
  $f = Join-Path $Root ('run-' + [guid]::NewGuid().ToString('N') + '.sh')
  $pre = if (@($A).Count) { 'set -- ' + ((@($A) | ForEach-Object { "'" + ("$_" -replace "'", "'\''") + "'" }) -join ' ') + "`n" } else { '' }
  [IO.File]::WriteAllText($f, $pre + ($Text -replace "`r`n", "`n"), $utf8)
  $oldP = $env:PATH; $oldR = $env:FCM_ROOT
  try { $env:PATH = "$Stubs$([IO.Path]::PathSeparator)$oldP"; $env:FCM_ROOT = $FcmRoot; $o = @(& $script:BashExe $f 2>&1 | ForEach-Object { "$_" }); $c = $LASTEXITCODE }
  finally { $env:PATH = $oldP; $env:FCM_ROOT = $oldR; Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
  @{ Code = $c; Out = $o; Text = ($o -join "`n") }
}
function New-FcmRoot {
  $r = Join-Path $Root ('fcm-' + [guid]::NewGuid().ToString('N'))
  foreach ($d in 'root/.ssh', 'etc/ssh', 'var/lib', 'opt', 'srv', 'usr/local', 'etc/systemd/system', 'home') { [void](New-Item -ItemType Directory -Path (Join-Path $r $d) -Force) }
  [IO.File]::WriteAllText((Join-Path $r 'etc/ssh/ssh_host_ed25519_key.pub'), "ssh-ed25519 $KeyNew root@new`n", $utf8)
  [IO.File]::WriteAllText((Join-Path $r 'etc/os-release'), "ID=debian`nVERSION_ID=`"13`"`n", $utf8)
  $r
}

# ============================== plan and its preconditions (D.2, B.0, I14) ==============================
T 'L.plan-state: plan writes the D.2 step 6 state and the manifest, sends the default map lines then the target-user lines, and writes nothing on old' {
  [void](Do-Plan)
  $s = Get-St
  Ok ("$($s.move_id)" -cmatch '^mv-[0-9]{14}-[0-9a-f]{6}$') "move_id: $($s.move_id)"
  Eq $s.phase 'planned' 'phase'; Eq $s.dir 'fwd' 'dir'; Eq $s.attempt 1 'attempt'; Eq $s.serving 'old' 'serving'; Ok ($null -eq $s.mark) 'mark null'
  Eq $s.enabled $true 'enabled'; Eq $s.carry $false 'carry'; Eq $s.manifest_sha $W.LastSha 'manifest_sha'
  Ok (@($s.target_users | Where-Object { $_.name -ceq 'quoc' -and "$($_.uid)" -ceq '1000' }).Count -eq 1) 'target_users[] holds preflight''s users'
  $mp = Join-Path (MoveDir) 'manifest.json'; Ok (Test-Path -LiteralPath $mp) 'manifest.json kept'
  Eq (Get-Sha256Hex ([IO.File]::ReadAllBytes($mp))) $W.LastSha 'manifest.json bytes = the pinned sha'
  $in = @($W.PlanStdin[-1])
  foreach ($l in 'exclude user dino', 'exclude unit velh-pilot-hourly.timer', 'target-user quoc 1000') { Ok ($in -ccontains $l) "plan stdin lacks [$l]: $($in -join ' | ')" }
  Ok ([Array]::IndexOf($in, 'target-user quoc 1000') -gt [Array]::IndexOf($in, 'exclude unit velh-pilot-hourly.timer')) 'target-user lines come after the map lines'
  Ordered @('^new script:preflight', '^old plan:full') -All
  Eq (@(RecCalls -All | Where-Object { $_.Call -notmatch '-p\.' }).Count) 0 'plan sends no recorded call but p.*'
}
T 'L.plan-questions: Q-pm2save có saves on old as p.pm2-save.1 (attempt 0) and plans again; Q-cert có renews as p.cert-renew.1; texts as CONTRACT §8.3' {
  $W.PlanHook = { param($n, $map) if ($n -eq 1) { @{ Out = @('INV refuse pm2-unsaved names=api,bot', 'INV warn cert-expiring name=a.example.com days=5'); Code = 65 } } else { @{ Out = @('INV ok'); Code = 0 } } }
  Ans 'có', 'có'
  [void](Do-Plan)
  Ok (@(Lines | Where-Object { $_ -match '\ADanh sách pm2 đang chạy khác danh sách đã lưu \(.*\)\. Lưu danh sách hiện tại trên máy cũ\? \(có / không\)\z' }).Count -ge 1) "Q-pm2save text: $(Lines)"
  Ok (@(Lines | Where-Object { $_ -match '\AChứng chỉ .* hết hạn sau 5 ngày\. Gia hạn trên máy cũ trước khi chuyển\? \(có / không\)\z' }).Count -ge 1) "Q-cert text: $(Lines)"
  Ok ((Sent 'old' '^fwd-0-p\.pm2-save\.1$' -All) -eq 1) 'p.pm2-save.1 on old with attempt 0'
  Ok ((Sent 'old' '^fwd-0-p\.cert-renew\.1$' -All) -eq 1) 'p.cert-renew.1 on old with attempt 0'
  Ordered @('^old plan:full', '^old fwd-0-p\.pm2-save\.1$', '^old plan:full') -All
}
T 'L.plan-rewrites-remedy: old''s plan <id> refusing map-invalid ref=rewrites with no manifest (a bare rewrite own-ip line while a family has more than one old or new address) ends plan with 65 and the remedy "ghi rõ `<from>=<to>`", nothing written; another map-invalid ref gets no such remedy (ruling 04/11 #3, B.12.5, E-P11)' {
  Add-Fault -M old -Key '^plan:full$' -Rc 65 -Out @('INV refuse map-invalid ref=rewrites') -Mode nomanifest
  [void](Do-Plan -Want 65); HasText 'ghi rõ `<from>=<to>`'
  NothingWritten; Ok (-not (Test-Path -LiteralPath (Join-Path (MoveDir) 'manifest.json'))) 'no manifest.json'; Eq (@(RecCalls -All).Count) 0 'no recorded call'
  Reset-World; Add-Fault -M old -Key '^plan:full$' -Rc 65 -Out @('INV refuse map-invalid ref=include') -Mode nomanifest
  [void](Do-Plan -Want 65); NoText 'ghi rõ `<from>=<to>`'; NothingWritten
}
T 'L.plan-tunnel-remedies: a connector ingress naming old''s own address (INV refuse own-ip path=ingress:<hostname>), Q-ownip không, ends plan 65 with the remedy "đổi service của tên đó trong cấu hình tunnel sang 127.0.0.1 hoặc tên container"; an own-ip file path gets no such remedy (B.12.4, W1-T3-GAP-17, CONTRACT §8.3.2)' {
  $W.PlanOut = @('INV refuse own-ip path=ingress:app.example.com'); $W.PlanCode = 65; Ans 'không'
  [void](Do-Plan -Want 65); HasText 'đổi service của tên đó trong cấu hình tunnel sang 127.0.0.1 hoặc tên container'; NothingWritten
  Reset-World; $W.PlanOut = @('INV refuse own-ip path=/opt/app/conf.yml'); $W.PlanCode = 65; Ans 'không'
  [void](Do-Plan -Want 65); NoText 'đổi service của tên đó trong cấu hình tunnel'
}
T 'L.plan-tunnel-remedies: a connector whose /config cannot be read (INV refuse unmapped what=connector path=<hold id>) ends plan 65 with the remedy "kiểm tra cổng metrics của connector rồi chạy lại"; another unmapped form gets no such remedy (B.12.4, W1-T3-GAP-18, CONTRACT §8.3.2)' {
  $W.PlanOut = @('INV refuse unmapped what=connector path=cloudflared.service'); $W.PlanCode = 65
  [void](Do-Plan -Want 65); HasText 'kiểm tra cổng metrics của connector rồi chạy lại'; NothingWritten
  Reset-World; $W.PlanOut = @('INV refuse unmapped what=unit path=x.service'); $W.PlanCode = 65
  [void](Do-Plan -Want 65); NoText 'kiểm tra cổng metrics của connector'
}
T 'L.plan-tunnel-remedies: old''s plan <id> refusing with no manifest (an invalid map, move-plan.sh _mvp_finalize) still prints the B.12.4 tunnel refusals; each gets its CONTRACT §8.3.2 remedy' {
  Add-Fault -M old -Key '^plan:full$' -Rc 65 -Out @('INV refuse own-ip path=ingress:app.example.com', 'INV refuse unmapped what=connector path=cloudflared.service', 'INV refuse map-invalid ref=include') -Mode nomanifest
  [void](Do-Plan -Want 65); HasText 'đổi service của tên đó trong cấu hình tunnel sang 127.0.0.1 hoặc tên container'; HasText 'kiểm tra cổng metrics của connector rồi chạy lại'; NothingWritten
}
T 'L.pre-os: preflight refusing os or arch ends plan with 65, the label, and nothing written' {
  foreach ($c in @(@('os want=debian-13 have=ubuntu-24.04', 'Máy mới khác bản Debian của máy cũ'), @('arch want=x86_64 have=aarch64', 'Máy mới khác kiến trúc CPU của máy cũ'))) {
    Reset-World; $W.Pf = @("INV refuse $($c[0])", 'INV target stop_budget_s=0'); $W.PfCode = 65
    [void](Do-Plan -Want 65); HasText $c[1]
    $s = Get-St; Ok ($null -eq $s -or $s.phase -cne 'planned') 'no planned state'
    Eq (@(RecCalls -All).Count) 0 'no recorded call'; Eq (@(LogNow -All | Where-Object { $_ -match 'plan:full' }).Count) 0 'old plan <id> not run after a preflight refusal'
  }
}
T 'L.pre-empty: B.0.3 user clause — a non-skel home of a user moved with the same name and uid passes; same name with another uid, or a user not moved, refuses target-not-empty' {
  [void](Do-Plan -Want 0)
  Reset-World; $W.Mf.users = @([ordered]@{ name = 'quoc'; uid = 1001 }, [ordered]@{ name = 'app'; uid = 1002 })
  [void](Do-Plan -Want 65); HasText 'Máy mới không trống'; HasText 'quoc'
  Reset-World; $W.Pf = @('INV target user=quoc uid=1000 home-nonskel=1', 'INV target user=bob uid=1500 home-nonskel=1', 'INV target stop_budget_s=120')
  [void](Do-Plan -Want 65); HasText 'Máy mới không trống'; HasText 'bob'
  $s = Get-St; Ok ($null -eq $s -or $s.phase -cne 'planned') 'nothing written on a refusal'
  Reset-World; $W.Pf = @('INV target user=quoc uid=1000 home-nonskel=1', 'INV target user=bob uid=1500 home-nonskel=0', 'INV target stop_budget_s=120')
  [void](Do-Plan -Want 0)
}
T 'L.pre-uid-collision: a moved uid held by another name on new, or a moved name with another uid, refuses uid-collision at plan with the remedy; same name and uid is no collision' {
  $W.Pf = @('INV target user=quoc uid=1000 home-nonskel=1', 'INV target user=other uid=1001 home-nonskel=0', 'INV target stop_budget_s=120')
  [void](Do-Plan -Want 65); HasText 'Trùng user hoặc uid trên máy mới'; HasText 'xóa user other trên máy mới'
  Eq (@(RecCalls -All).Count) 0 'found at plan: no recorded call'; $s = Get-St; Ok ($null -eq $s -or $s.phase -cne 'planned') 'nothing written'
  Reset-World; $W.Pf = @('INV target user=quoc uid=1000 home-nonskel=1', 'INV target user=app uid=1500 home-nonskel=0', 'INV target stop_budget_s=120')
  [void](Do-Plan -Want 65); HasText 'Trùng user hoặc uid trên máy mới'
}
T 'L.pre-uid-collision: groups and subid ranges (B.6.2; W1-T11-DG-T11-4) — a moved gid held by another group on new, a moved group with another gid, or a moved user''s subid range overlapping another user''s range on new refuses uid-collision at plan, nothing written; the same name and gid, the same user''s range or an adjacent range pass' {
  $pf0 = @('INV target user=quoc uid=1000 home-nonskel=1', 'INV target user=app uid=1001 home-nonskel=0', 'INV target platform=0', 'INV target stop_budget_s=120')
  foreach ($c in @(@('ops', 1800, 65), @('devs', 1801, 65), @('devs', 1800, 0))) {
    Reset-World; $W.Mf.groups = @([ordered]@{ name = $c[0]; gid = $c[1]; members = @() }); $W.Pf = $pf0 + 'INV target group=devs gid=1800'
    [void](Do-Plan -Want $c[2])
    if ($c[2] -eq 65) { HasText 'Trùng user hoặc uid trên máy mới'; NothingWritten "[$($c[0]) $($c[1])] nothing written"; Eq (@(RecCalls -All).Count) 0 'no recorded call' }
  }
  foreach ($c in @(@('zed', 120000, 65), @('app', 120000, 0), @('zed', 165536, 0))) {
    Reset-World; $W.Mf.subids = @([ordered]@{ kind = 'uid'; name = 'app'; start = 100000; count = 65536 }); $W.Pf = $pf0 + "INV target subid user=$($c[0]) kind=uid start=$($c[1]) count=65536"
    [void](Do-Plan -Want $c[2])
    if ($c[2] -eq 65) { HasText 'Trùng user hoặc uid trên máy mới'; HasText 'what=subuid'; NothingWritten "[$($c[0]) $($c[1])] nothing written" }
  }
}
T 'L.pre-platform-mixed: with platform=1 from preflight, plan refuses at 3b (target-not-empty, nothing written) a manifest moving /usr/local/bin/node, a root under a platform directory or the unit file of a platform unit; with platform=0 the same manifest passes (B.5.2 mixed pair)' {
  $pf = { param($p) @('INV target user=quoc uid=1000 home-nonskel=1', "INV target platform=$p", 'INV target stop_budget_s=120') }
  $cases = @(
    @([ordered]@{ id = 'file-usr-local-bin-node'; root = '/usr/local/bin/node'; kind = 'file'; bytes_apparent = 1000; inodes = 1 }, '/usr/local/bin/node'),
    @([ordered]@{ id = 'tree-usr-local-lib-node_modules-pkg'; root = '/usr/local/lib/node_modules/pkg'; kind = 'tree'; bytes_apparent = 1000; inodes = 3 }, '/usr/local/lib/node_modules/pkg'),
    @([ordered]@{ id = 'files-etc-systemd-system'; root = '/etc/systemd/system'; kind = 'files'; files_from = @('sshd.service'); bytes_apparent = 100; inodes = 1 }, '/etc/systemd/system/sshd.service'))
  foreach ($c in $cases) {
    Reset-World; $W.Pf = & $pf 1; $W.Mf.items = @($W.Mf.items) + $c[0]
    [void](Do-Plan -Want 65); HasText 'Máy mới không trống'; HasText $c[1]; NothingWritten "[$($c[1])] nothing written"; Eq (@(RecCalls -All).Count) 0 'no recorded call'
    Reset-World; $W.Pf = & $pf 0; $W.Mf.items = @($W.Mf.items) + $c[0]
    [void](Do-Plan -Want 0); Eq (St-Raw 'target_platform') '0' "[$($c[1])] target_platform stored"
  }
  Reset-World; $W.Pf = & $pf 1; [void](Do-Plan -Want 0); Eq (St-Raw 'target_platform') '1' 'a platform=1 target with no platform path moved passes'
}
T 'L.pre-platform-mixed: a D.3 copy re-run checks its re-plan against the stored target_platform — an item root added under /usr/local/bin refuses at 3b before c.repin.N; with a stored 0 it passes; new is never asked again (B.5.2, D.3; GAP-RULINGS-3 §16.7 T-4)' {
  $node = [ordered]@{ id = 'file-usr-local-bin-node'; root = '/usr/local/bin/node'; kind = 'file'; bytes_apparent = 1000; inodes = 1 }
  $W.Pf = @('INV target user=quoc uid=1000 home-nonskel=1', 'INV target platform=1', 'INV target stop_budget_s=120'); Fx-Copied; Eq (St-Raw 'target_platform') '1' 'stored from preflight'
  $W.Mf.items = @($W.Mf.items) + $node
  [void](Do-Copy 65); HasText 'Máy mới không trống'; HasText '/usr/local/bin/node'
  Ordered @('^old plan:full$'); Eq (SentAny '-c\.repin\.') 0 'refused before c.repin.N'; Eq (SentAny '-c\.(prepare|transfer)\.') 0 'nothing prepared or transferred'
  Eq (@(LogNow | Where-Object { $_ -match 'script:preflight' }).Count) 0 'new not asked again'
  Reset-World; Fx-Copied; Eq (St-Raw 'target_platform') '0' 'stored 0'
  $W.Pf = @('INV target user=quoc uid=1000 home-nonskel=1', 'INV target platform=1', 'INV target stop_budget_s=120')   # new would answer 1 now; the stored value rules
  $W.Mf.items = @($W.Mf.items) + $node
  [void](Do-Copy 0); Ok ((Sent 'old' '-c\.repin\.1$') -eq 1) "the re-plan went on to c.repin.1: $(LogNow)"; Eq (@(LogNow | Where-Object { $_ -match 'script:preflight' }).Count) 0 'new not asked again'
}
T 'L.pre-reach: preflight refusing old-unreachable, new-unreachable or dns ends plan with 65 and the label' {
  foreach ($c in @(@('old-unreachable', 'Máy mới không kết nối được máy cũ'), @('new-unreachable host=github.com', 'Máy mới không kết nối được tới địa chỉ cần thiết'), @('dns why=unreachable', 'Không tra được DNS qua DoH'))) {
    Reset-World; $W.Pf = @("INV refuse $($c[0])"); $W.PfCode = 65
    [void](Do-Plan -Want 65); HasText $c[1]; Eq (@(RecCalls -All).Count) 0 'no recorded call'
  }
}
T 'L.pre-addr: an --addr that is not IPv4 or a name refuses target-addr before any ssh; a target without an ed25519 host key refuses too' {
  $r = Run-Move @('plan', $NewAlias, '--addr', 'bad_addr!'); Eq $r.Code 65 'exit'; HasText 'Địa chỉ máy mới không hợp lệ'; Eq $W.Calls.Count 0 'no ssh at all'
  Reset-World; $W.Pf = @('INV refuse target-addr why=hostkey'); $W.PfCode = 65; [void](Do-Plan -Want 65); HasText 'Địa chỉ máy mới không hợp lệ'
}
T 'L.pre-gh: gh without admin on a legacy repo refuses gh-permission at plan and at cutover 0c, nothing frozen' {
  Use-Legacy
  Add-Gh "$($GhForm.SecretList)$([regex]::Escape($LegacyRepo))" @('HTTP 403: Resource not accessible') 1 1
  [void](Do-Plan -Want 65); HasText 'gh không có quyền admin trên repo'; HasText $LegacyRepo
  Reset-World; Use-Legacy; Fx-Copied
  Add-Gh "$($GhForm.SecretList)$([regex]::Escape($LegacyRepo))" @('HTTP 403') 1 -1
  [void](Do-Cutover 65); HasText 'gh không có quyền admin trên repo'; Eq (Sent 'old' '-x\.freeze$') 0 'nothing frozen'
}
T 'L.pre-clock: clock skew over 5 s refuses clock at plan and at cutover 0c, nothing frozen' {
  $W.old.Skew = 10; [void](Do-Plan -Want 65); HasText 'Đồng hồ các máy lệch nhau quá 5 giây'
  Reset-World; $W.new.Skew = -9; [void](Do-Plan -Want 65); HasText 'Đồng hồ các máy lệch nhau quá 5 giây'
  Reset-World; Fx-Copied; $W.new.Skew = 12; [void](Do-Cutover 65); HasText 'Đồng hồ các máy lệch nhau quá 5 giây'; Eq (Sent 'old' '-x\.freeze$') 0 'nothing frozen'
}
T 'L.pre-gate-missing: an old gate without --move (the exact GATE_ERROR, 65, no INV) refuses gate-missing side=old in check and plan' {
  $W.old.NoMove = $true
  $r = Run-Move @('check'); Eq $r.Code 65 'check exit'; HasText 'Máy cũ chưa cài bản gate có lệnh chuyển máy'
  Reset-World; $W.old.NoMove = $true; [void](Do-Plan -Want 65); HasText 'Máy cũ chưa cài bản gate có lệnh chuyển máy'
}
T 'L.pre-sshd: each key of the closed sshd set asks Q-sshd; không refuses sshd-config, có sends `accept sshd` and plan passes' {
  foreach ($k in 'permitrootlogin', 'passwordauthentication', 'kbdinteractiveauthentication', 'pubkeyauthentication', 'authorizedkeysfile', 'allowtcpforwarding', 'gatewayports', 'port', 'acceptenv', 'permituserenvironment') {
    foreach ($a in 'không', 'có') {
      Reset-World; $script:SshdKey = $k
      $W.PlanHook = { param($n, $map) if ($map -ccontains 'accept sshd') { @{ Out = @('INV ok'); Code = 0 } } else { @{ Out = @("INV refuse sshd-config key=$($script:SshdKey)"); Code = 65 } } }
      Ans $a
      if ($a -ceq 'không') { [void](Do-Plan -Want 65); HasText 'Cấu hình sshd hai máy khác nhau' } else { [void](Do-Plan -Want 0); Ok (@($W.PlanStdin[-1]) -ccontains 'accept sshd') "[$k] the có answer is the map line accept sshd" }
      Ok (@(Lines | Where-Object { $_ -match "\ACấu hình sshd của máy mới khác máy cũ \(.*$k.*\)\. Áp dụng các file sshd của máy cũ lên máy mới\? \(có / không\)\z" }).Count -ge 1) "[$k] Q-sshd text: $(Lines)"
    }
  }
}
T 'L.pre-egress-after-manifest: after plan step 3 and at 0c new tests a TCP connect to every egress pair; a failure warns egress and goes on' {
  $W.Mf.egress = @([ordered]@{ addr = '192.0.2.50'; port = 443 }); $W.TcpFail['192.0.2.50:443'] = $true
  [void](Do-Plan -Want 0); HasText 'Máy mới không kết nối ra được địa chỉ này'
  Ordered @('^old plan:full', '^new script:tcp') -All
  [void](Do-Copy); [void](Do-Cutover 0)
  Before '^new script:tcp' '^old fwd-1-x\.freeze$'
  HasText 'Máy mới không kết nối ra được địa chỉ này'
}
T 'L.pre-identity-drift: at 0c a new whose hostname differs from the manifest (cloud-init reset) refuses, nothing frozen' {
  Fx-Copied; $W.new.Hostname = 'debian-cloud'
  $r = Do-Cutover -1; Ok ($r.Code -ne 0) 'cutover must not run'; Eq (Sent 'old' '-x\.freeze$') 0 'nothing frozen'; Ok ($null -eq (Get-St).mark) 'mark still null'
}
function Assert-NothingFrozen([int]$Want, [string]$Text = '') { Eq $script:Last.Code $Want "0c exit ($($script:Last.Text))"; Eq (Sent 'old' '-x\.freeze$') 0 'nothing frozen'; Ok ($null -eq (Get-St).mark) 'mark still null'; if ($Text) { HasText $Text } }
T 'L.pre-call-running: at 0c a call still running on new ends the cutover with 75, nothing frozen' {
  Fx-Copied; Set-Running 'new' 'fwd-1-c.adopt.1'; [void](Do-Cutover -1); Assert-NothingFrozen 75
}
T 'L.pre-stale-manifest: 0c plan <id> --check-only and x.check read the same stdin as plan <id> (the target-user, target-addr and idmap lines; D.0.9, D.2 step 3)' {
  Fx-Planned; Add-Fault -M new -Key '-c\.prepare\.1$' -Rc 0 -Out @('MOVE item idmap:user:svc kind=prepare state=mapped src_id=105 dst_id=110'); [void](Do-Copy 0); [void](Do-Cutover 0)
  $cs = @(@(RecCalls | Where-Object { $_.Call -ceq 'fwd-1-x.check' }) + @(Calls | Where-Object { $_.Step -ceq 'plan:check-only' })); Ok ($cs.Count -ge 2) "x.check and the 0c check-only were sent: $(LogNow)"
  foreach ($c in $cs) {
    $in = @("$($c.Stdin)" -split '\r?\n' | Where-Object { $_ })
    foreach ($l in 'target-user quoc 1000', 'target-addr 198.51.100.20', 'idmap user svc 105 110') { Ok ($in -ccontains $l) "$($c.M) $($c.Step) stdin lacks [$l]: $($in -join ' | ')" }
  }
}
T 'L.pre-dst-quiet: at 0c an active hold on new ends the cutover with 65, nothing frozen' {
  Fx-Copied; $W.new.Active = 1; [void](Do-Cutover -1); Assert-NothingFrozen 65
}
T 'L.pre-stale-manifest: at 0c a plan <id> --check-only refusing manifest-stale ends with 65 "chạy fcode move copy lại", nothing frozen' {
  Fx-Copied; Add-Fault -M old -Key '^plan:check-only$' -Rc 65 -Out @('MOVE error manifest-stale what=user name=bob'); [void](Do-Cutover -1); Assert-NothingFrozen 65 'chạy fcode move copy lại'
}
T 'L.plan-tunnel-remedies: at 0c a plan <id> --check-only refusing unmapped what=connector (the same discovery as plan) ends 65 with the remedy, nothing frozen' {
  Fx-Copied; Add-Fault -M old -Key '^plan:check-only$' -Rc 65 -Out @('INV refuse unmapped what=connector path=cloudflared.service'); [void](Do-Cutover -1); Assert-NothingFrozen 65 'kiểm tra cổng metrics của connector rồi chạy lại'
}
T 'L.plan-tunnel-remedies: at 0c a plan <id> --check-only refusing own-ip path=ingress:<hostname> ends 65 with the remedy, nothing frozen' {
  Fx-Copied; Add-Fault -M old -Key '^plan:check-only$' -Rc 65 -Out @('INV refuse own-ip path=ingress:app.example.com'); [void](Do-Cutover -1); Assert-NothingFrozen 65 'đổi service của tên đó trong cấu hình tunnel sang 127.0.0.1 hoặc tên container'
}
T 'L.pre-uid-collision: at 0c the uid-collision compare runs again against the stored target_users[] and refuses, nothing frozen' {
  Fx-Copied; [void](Patch-St @{ target_users = @([ordered]@{ name = 'other'; uid = 1001; home_nonskel = 0 }) }); [void](Do-Cutover -1); Assert-NothingFrozen 65 'Trùng user hoặc uid trên máy mới'
}
T 'L.pre-space: at 0c a new short of free space refuses disk (reading T10-G14), nothing frozen' {
  Fx-Copied; $W.new.FreeMb = 100; [void](Do-Cutover -1); Assert-NothingFrozen 65 $DiskLabel0c
}
T 'L.pre-rsync-argv: preflight refusing target-rsync-argv ends plan with 65, nothing written, the label and the remedy' {
  $W.Pf = @('INV refuse target-rsync-argv shape=fwd-files'); $W.PfCode = 65
  [void](Do-Plan -Want 65); HasText 'Lệnh rsync của máy mới khác mẫu đã ghi'; HasText 'cài rsync '; HasText 'trên máy mới, hoặc chụp lại T0b và phát hành gate'
  $s = Get-St; Ok ($null -eq $s -or $s.phase -cne 'planned') 'nothing written'
}
T 'L.pre-rsync-argv: the preflight script refuses a client argv that is not its template, and the pair''s rsync passes' {
  $txt = Get-MovePreflightScript
  $pa = @('--old-addr', $OldAddr, '--addr', $NewAddr, '--src-os', 'debian-13', '--src-arch', 'x86_64', '--src-systemd', '257')
  $bogus = 'e=; prev=; for a in "$@"; do [ "$prev" = -e ] && e=$a; case $a in --rsh=*) e=${a#--rsh=};; esac; prev=$a; done; [ -n "$e" ] && eval "$e oldhost rsync --server --bogus-flag . /x"; exit 0'
  $tmo = 'case "$*" in *"/dev/tcp"*) exit 0;; esac; shift; exec "$@"'
  $r = Run-Bash $txt $pa (New-FcmRoot) (New-Stubs @{ rsync = $bogus; ssh = 'exit 0'; timeout = $tmo })
  Ok ($r.Text -match 'INV refuse target-rsync-argv shape=') "a foreign argv must refuse target-rsync-argv: $($r.Text)"
  $r = Run-Bash $txt $pa (New-FcmRoot) (New-Stubs @{ ssh = 'exit 0'; timeout = $tmo })
  Ok ($r.Text -notmatch 'target-rsync-argv') "the pair's own rsync must pass: $($r.Text)"
} -NeedsBash
# ============================== the shipped preflight script, run for real (G.2, W1-T11-DG-R11-3; bash cases) ==============================
$PfArgs = @('--old-addr', $OldAddr, '--addr', $NewAddr, '--src-os', 'debian-13', '--src-arch', 'x86_64', '--src-systemd', '257')
$PlatformUnits = @('instabox-data-init.service', 'instabox-guest-agent.service', 'instabox-guest-reboot.service', 'instabox-identity.service', 'instabox-ssh-hostkeys.service', 'instabox-user.service', 'sshd.service')   # CONTRACT §3.5 LIST platform-units
function Fx-File([string]$R, [string]$P, [string]$Text = "x`n") { $f = Join-Path $R $P.TrimStart('/'); [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f)); [IO.File]::WriteAllText($f, $Text, $utf8) }
# a fixture root: dpkg lists, /etc/skel, /etc/subuid, /etc/subgid, and fx-passwd / fx-group (what the getent stub answers)
function Pf-Root {
  $r = New-FcmRoot
  foreach ($d in 'var/lib/dpkg/info', 'etc/skel') { [void](New-Item -ItemType Directory -Force -Path (Join-Path $r $d)) }
  foreach ($f in 'fx-passwd', 'fx-group', 'etc/subuid', 'etc/subgid') { Fx-File $r $f '' }
  $r
}
function Pf-Timeout([int]$TcpRc) { 'while [ $# -gt 0 ]; do case $1 in -k|-s|--kill-after|--signal) shift 2;; -*) shift;; *) break;; esac; done; shift; case "$*" in *"/dev/tcp"*) exit {0};; esac; exec "$@"' -f $TcpRc }
function Pf-Stubs([hashtable]$Over = @{}) {
  $b = @{
    uname = 'echo x86_64'; ssh = 'exit 0'; timeout = (Pf-Timeout 0)
    getent = 'case $1 in passwd) f=fx-passwd;; group) f=fx-group;; *) exit 2;; esac; [ -r "$FCM_ROOT/$f" ] || exit 2; if [ $# -ge 2 ]; then grep -E "^$2:" "$FCM_ROOT/$f" || exit 2; else cat "$FCM_ROOT/$f"; fi'
    ip = 'fam=; for a in "$@"; do case $a in -4) fam=4;; -6) fam=6;; esac; done; [ "$fam" = 6 ] || echo "2: eth0    inet 198.51.100.20/24 brd 198.51.100.255 scope global eth0"; [ "$fam" = 4 ] || echo "2: eth0    inet6 2001:db8::20/64 scope global"; exit 0'
  }
  foreach ($k in $Over.Keys) { $b[$k] = $Over[$k] }
  New-Stubs $b
}
function Pf-Run([string]$R, [string]$Stubs, [string[]]$A = $PfArgs) { Run-Bash (Get-MovePreflightScript) $A $R $Stubs }
function PfHas($Res, [string]$Line) { Ok (@($Res.Out | Where-Object { "$_".TrimEnd() -ceq $Line }).Count -ge 1) "preflight must print [$Line]: $($Res.Text)" }
function PfLacks($Res, [string]$Rx) { $h = @($Res.Out | Where-Object { "$_" -match $Rx }); Ok ($h.Count -eq 0) "preflight must not print [$Rx]: $($h -join ' | ')" }
T 'L.pre-os: the preflight script refuses another Debian major, another arch or a lower systemd major (65) and passes the pair''s own values (B.0.2)' {
  $r = Pf-Run (Pf-Root) (Pf-Stubs); Eq $r.Code 0 "a clean target ($($r.Text))"; PfHas $r 'INV ok'; PfLacks $r '^INV refuse '
  $fr = Pf-Root; Fx-File $fr 'etc/os-release' "ID=ubuntu`nVERSION_ID=`"24.04`"`n"
  $r = Pf-Run $fr (Pf-Stubs); Eq $r.Code 65 'ubuntu'; PfHas $r 'INV refuse os src=debian-13 dst=ubuntu-24'
  $r = Pf-Run (Pf-Root) (Pf-Stubs @{ uname = 'echo aarch64' }); Eq $r.Code 65 'arch'; PfHas $r 'INV refuse arch src=x86_64 dst=aarch64'
  $r = Pf-Run (Pf-Root) (Pf-Stubs @{ systemctl = 'if [ "$1" = --version ]; then echo "systemd 252 (252.30-1~deb12u2)"; fi; exit 0' }); Eq $r.Code 65 'systemd'; PfHas $r 'INV refuse os what=systemd src=257 dst=252'
} -NeedsBash
T 'L.pre-reach: the preflight script refuses old-unreachable, new-unreachable host=github.com and dns why=unreachable with 65 (B.0.2)' {
  $r = Pf-Run (Pf-Root) (Pf-Stubs @{ timeout = (Pf-Timeout 1) }); Eq $r.Code 65 'old'; PfHas $r "INV refuse old-unreachable addr=$OldAddr"
  $r = Pf-Run (Pf-Root) (Pf-Stubs @{ curl = 'case "$*" in *dns-query*) exit 0;; *github.com*) exit 7;; esac; exit 0' }); Eq $r.Code 65 'github'; PfHas $r 'INV refuse new-unreachable host=github.com'; PfLacks $r '^INV refuse dns '
  $r = Pf-Run (Pf-Root) (Pf-Stubs @{ curl = 'case "$*" in *dns-query*) exit 7;; esac; exit 0' }); Eq $r.Code 65 'dns'; PfHas $r 'INV refuse dns why=unreachable'; PfLacks $r 'new-unreachable'
} -NeedsBash
T 'L.pre-addr: the preflight script refuses an --addr outside ^[A-Za-z0-9.-]+$ (target-addr addr=-) and a target without an ed25519 host key (target-addr why=no-ed25519) (B.0.2)' {
  $a = @($PfArgs); $a[3] = 'bad_addr!'; $r = Pf-Run (Pf-Root) (Pf-Stubs) $a; Eq $r.Code 65 'addr'; PfHas $r 'INV refuse target-addr addr=-'
  $fr = Pf-Root; Remove-Item -LiteralPath (Join-Path $fr 'etc/ssh/ssh_host_ed25519_key.pub'); $r = Pf-Run $fr (Pf-Stubs); Eq $r.Code 65 'no key'; PfHas $r 'INV refuse target-addr why=no-ed25519'
} -NeedsBash
T 'L.pre-empty-rules: package-default units, skel copies and empty unowned dirs pass; a uid ≥ 1000 user with a non-skel home is reported home-nonskel=1 and never refused by preflight (B.0.3, E-P2)' {
  $fr = Pf-Root
  Fx-File $fr 'etc/systemd/system/pkg-default.service' "[Unit]`n"; Fx-File $fr 'opt/vendor/bin/tool'; Fx-File $fr 'var/lib/dpkg/info/pkgx.list' "/etc/systemd/system/pkg-default.service`n/opt/vendor/bin/tool`n"
  [void](New-Item -ItemType Directory -Force -Path (Join-Path $fr 'etc/systemd/system/multi-user.target.wants'))
  & ln -s /usr/lib/systemd/system/cron.service (Join-Path $fr 'etc/systemd/system/multi-user.target.wants/cron.service'); & ln -s /usr/lib/systemd/system/rsyslog.service (Join-Path $fr 'etc/systemd/system/syslog.service')
  foreach ($d in 'opt/emptydir', 'srv/empty', 'usr/local/bin', 'usr/local/etc') { [void](New-Item -ItemType Directory -Force -Path (Join-Path $fr $d)) }
  Fx-File $fr 'etc/skel/.bashrc' "# skel`n"; Fx-File $fr 'home/alice/.bashrc' "# skel`n"; Fx-File $fr 'home/bob/.bashrc' "# skel`n"; Fx-File $fr 'home/bob/notes.txt' "mine`n"
  Fx-File $fr 'fx-passwd' "root:x:0:0:root:/root:/bin/bash`nalice:x:1500:1500::/home/alice:/bin/bash`nbob:x:1501:1501::/home/bob:/bin/bash`nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin`n"
  $r = Pf-Run $fr (Pf-Stubs); Eq $r.Code 0 "exit ($($r.Text))"; PfHas $r 'INV ok'; PfLacks $r '^INV refuse '
  PfHas $r 'INV target user=alice uid=1500 home-nonskel=0'; PfHas $r 'INV target user=bob uid=1501 home-nonskel=1'; PfLacks $r '^INV target user=(nobody|root) '
} -NeedsBash
T 'L.pre-empty-rules: an unowned file under /opt refuses once with its top-level entry; an unowned unit file, a running container and another move''s move-id refuse target-not-empty (65) (B.0.3, E-P2, E-P36)' {
  $fr = Pf-Root
  Fx-File $fr 'opt/app/data/f.txt'; Fx-File $fr 'opt/app/g.txt'; Fx-File $fr 'srv/www/index.html'; Fx-File $fr 'etc/systemd/system/app.service' "[Unit]`n"; Fx-File $fr 'var/lib/fcode-move/move-id' "id=mv-20261101000000-abcdef`n"
  $r = Pf-Run $fr (Pf-Stubs @{ docker = 'case "$*" in *--format*) echo web;; *ps*) echo 0123456789ab;; esac; exit 0' }); Eq $r.Code 65 "exit ($($r.Text))"
  PfHas $r 'INV refuse target-not-empty path=/opt/app'; Eq (@($r.Out | Where-Object { "$_" -match 'path=/opt/app' }).Count) 1 'one refusal for /opt/app'; PfLacks $r 'path=/opt/app/'; PfHas $r 'INV refuse target-not-empty path=/srv/www'
  PfHas $r 'INV refuse target-not-empty path=/etc/systemd/system/app.service'; PfHas $r 'INV refuse target-not-empty path=container:web'; PfHas $r 'INV refuse target-not-empty path=/var/lib/fcode-move/move-id'
} -NeedsBash
T 'L.pre-empty-rules: the platform entries pass only on a target carrying all seven platform unit files (INV target platform=1); a non-platform entry still refuses; with one unit file missing the same paths and unit files refuse and platform=0 (B.5.2, CONTRACT §3.5)' {
  $mk = {
    param([string[]]$Units)
    $fr = Pf-Root
    foreach ($u in $Units) { Fx-File $fr "etc/systemd/system/$u" "[Unit]`n" }
    foreach ($p in 'usr/local/bin/node', 'usr/local/etc/npmrc', 'opt/npm/bin/npm', 'opt/containerd/bin/x', 'usr/local/lib/node_modules/corepack/package.json', 'usr/local/go/bin/go', 'usr/local/share/ca-certificates/instabox-proxy.crt') { Fx-File $fr $p }
    $fr
  }
  $r = Pf-Run (& $mk $PlatformUnits) (Pf-Stubs); Eq $r.Code 0 "platform present ($($r.Text))"; PfHas $r 'INV target platform=1'; PfLacks $r '^INV refuse '; PfHas $r 'INV ok'
  $fr = & $mk $PlatformUnits; Fx-File $fr 'usr/local/bin/mytool'; $r = Pf-Run $fr (Pf-Stubs); Eq $r.Code 65 'a non-platform entry'; PfHas $r 'INV refuse target-not-empty path=/usr/local/bin'
  $r = Pf-Run (& $mk @($PlatformUnits | Where-Object { $_ -cne 'sshd.service' })) (Pf-Stubs); Eq $r.Code 65 "six of seven ($($r.Text))"; PfHas $r 'INV target platform=0'
  PfHas $r 'INV refuse target-not-empty path=/opt/npm'; Ok (@($r.Out | Where-Object { "$_" -match '^INV refuse target-not-empty path=/usr/local/' }).Count -ge 1) "the /usr/local entries refuse: $($r.Text)"
  PfHas $r 'INV refuse target-not-empty path=/etc/systemd/system/instabox-user.service'
} -NeedsBash
T 'L.pre-uid-collision: the preflight script prints new''s groups with gid ≥ 1000, every /etc/subuid and /etc/subgid line and every global address (B.0.2; W1-T11-DG-T11-4)' {
  $fr = Pf-Root
  Fx-File $fr 'fx-group' "root:x:0:`nsudo:x:27:alice`ndevs:x:1800:alice`n"; Fx-File $fr 'etc/subuid' "alice:100000:65536`n"; Fx-File $fr 'etc/subgid' "alice:165536:65536`n"
  $r = Pf-Run $fr (Pf-Stubs); Eq $r.Code 0 "exit ($($r.Text))"
  PfHas $r 'INV target group=devs gid=1800'; PfLacks $r '^INV target group=(root|sudo) '
  PfHas $r 'INV target subid user=alice kind=uid start=100000 count=65536'; PfHas $r 'INV target subid user=alice kind=gid start=165536 count=65536'
  PfHas $r 'INV target addr=198.51.100.20'; PfHas $r 'INV target addr=2001:db8::20'
} -NeedsBash
T 'L.push-scan: the facts script prints one MOVE legacy line per legacy project directory on the machine (/opt/deal-sync deal-sync, /opt/internal-scraper vps-scraper) from a read-only git remote get-url origin, next to MOVE facts; no other directory, nothing written (ruling T10c-LP 04/11)' {
  $git = @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue)[0]; Ok ($null -ne $git) 'git on the test machine'
  $fr = New-FcmRoot
  $repos = [ordered]@{ 'opt/deal-sync' = 'git@github.com:brooklyn96/BD-Team-Project.git'; 'opt/internal-scraper' = 'https://github.com/brooklyn96/Internal-scraper.git'; 'opt/internal-scraper-staging' = 'git@github.com:brooklyn96/Staging.git'; 'srv/deal-sync' = 'git@github.com:brooklyn96/Other.git' }
  foreach ($d in $repos.Keys) { $p = Join-Path $fr $d; [void](& $git.Source -c init.defaultBranch=main init -q $p 2>&1); [void](& $git.Source -C $p remote add origin $repos[$d] 2>&1) }
  $snap = { @(Get-ChildItem -LiteralPath $fr -Recurse -File -Force | Sort-Object FullName | ForEach-Object { "$($_.FullName.Substring($fr.Length)) $(Get-Sha256Hex ([IO.File]::ReadAllBytes($_.FullName)))" }) -join "`n" }
  $before = & $snap
  $gs = @{ git = "GIT_TEST_ASSUME_DIFFERENT_OWNER=1 exec '$($git.Source)' `"`$@`""; uname = 'echo x86_64' }   # every repo counts as another owner's: /opt/internal-scraper is not root-owned on contabo (safe.directory)
  $r = Run-Bash (Get-MoveFactsScript) @() $fr (New-Stubs $gs); Eq $r.Code 0 "exit ($($r.Text))"
  $lg = @($r.Out | Where-Object { "$_" -cmatch '\AMOVE legacy ' } | ForEach-Object { "$_".TrimEnd() })
  Eq ($lg -join ' | ') ((($LegacyFactsLine -f 'deal-sync', $repos['opt/deal-sync']), ($LegacyFactsLine -f 'vps-scraper', $repos['opt/internal-scraper'])) -join ' | ') 'the legacy lines'
  Ok (@($r.Out | Where-Object { "$_" -cmatch '\AMOVE facts os=debian-13 ' }).Count -eq 1) "MOVE facts still printed: $($r.Text)"
  Eq (& $snap) $before 'nothing written under the root'
  [IO.Directory]::Delete((Join-Path $fr 'opt/deal-sync'), $true); $r = Run-Bash (Get-MoveFactsScript) @() $fr (New-Stubs $gs); Eq $r.Code 0 "exit without /opt/deal-sync ($($r.Text))"
  Eq (@($r.Out | Where-Object { "$_" -cmatch '\AMOVE legacy ' }) -join ' | ') ($LegacyFactsLine -f 'vps-scraper', $repos['opt/internal-scraper']) 'a missing directory prints no line'
} -NeedsBash
T 'L.check-diff: check is zero-write, sends plan - --check-only, shows new refusals first against check.json, exits 65 or 0' {
  $W.CheckOut = @('INV refuse pm2-unsaved names=api'); $W.CheckCode = 65
  $r = Run-Move @('check'); Eq $r.Code 65 'first check'; HasText 'Danh sách pm2 chưa được lưu'
  Ok (Test-Path -LiteralPath (Join-Path (MoveDir) 'check.json')) 'check.json written'
  $W.CheckOut = @('INV refuse pm2-unsaved names=api', 'INV refuse own-ip path=/etc/app.conf'); $W.CheckCode = 65
  $r = Run-Move @('check'); Eq $r.Code 65 'second check'
  $i1 = $r.Text.IndexOf('File chứa địa chỉ IP của máy cũ'); $i2 = $r.Text.IndexOf('Danh sách pm2 chưa được lưu')
  Ok ($i1 -ge 0 -and $i2 -ge 0 -and $i1 -lt $i2) "the new refusal is shown first: $($r.Text)"
  $W.CheckOut = @('INV ok'); $W.CheckCode = 0; $r = Run-Move @('check'); Eq $r.Code 0 'clean check'
  Eq (@(RecCalls -All).Count) 0 'check sends no recorded call'; Ok ($null -eq (Get-St)) 'check writes no state.json'
  Ok (@(LogNow -All | Where-Object { $_ -notmatch '^old (plan:check|status|script:facts)$' }).Count -eq 0) "check talks to old's plan - --check-only (and read-only facts) only: $(LogNow -All)"
}
T 'L.push-scan: a matched repo is gate-push only when its slug equals the origin remote of a legacy directory on old, project = that legacy name; every other match (one naming DEPLOY_KNOWN_HOSTS, or an origin seen only on new, included) asks Q-sshpush; không refuses push-deploy, có disables that workflow for good (B.10.5, ruling T10c-LP 04/11)' {
  foreach ($a in 'không', 'có') {
    Reset-World
    Add-Gh $GhForm.RepoList @('[{"nameWithOwner":"brooklyn96/task"},{"nameWithOwner":"brooklyn96/BD-Team-Project"},{"nameWithOwner":"brooklyn96/Internal-scraper"}]')
    foreach ($rp in 'brooklyn96/task', 'brooklyn96/BD-Team-Project', 'brooklyn96/Internal-scraper') { Add-Gh ($GhForm.WfDir -f $rp) @('[{"name":"deploy.yml"}]') }
    Add-Gh ($GhForm.WfFile -f 'brooklyn96/task', 'deploy\.yml') @('jobs:', '  d:', '    steps:', '      - run: ssh-keyscan $HOST >> ~/.ssh/known_hosts', $LegacyWfLine)
    Add-Gh ($GhForm.WfFile -f 'brooklyn96/BD-Team-Project', 'deploy\.yml') @('jobs:', '  d:', '    steps:', '      - uses: appleboy/ssh-action@v1')
    Add-Gh ($GhForm.WfFile -f 'brooklyn96/Internal-scraper', 'deploy\.yml') @($LegacyWfLine)
    $W.old.Legacy = @(($LegacyFactsLine -f 'deal-sync', 'git@github.com:brooklyn96/BD-Team-Project.git'), ($LegacyFactsLine -f 'vps-scraper', 'https://github.com/brooklyn96/Internal-scraper.git'))
    $W.new.Legacy = @($LegacyFactsLine -f 'deal-sync', 'git@github.com:brooklyn96/task.git')   # not a directory on old
    Ans $a
    if ($a -ceq 'không') { [void](Do-Plan -Want 65); HasText 'Có workflow deploy thẳng qua ssh' } else { [void](Do-Plan -Want 0) }
    Ok (@(Lines | Where-Object { $_ -match '\AWorkflow của repo brooklyn96/task( \(deploy\.yml\))? deploy thẳng qua ssh\. Tắt hẳn workflow đó\? \(có / không\)\z' }).Count -ge 1) "Q-sshpush text: $(Lines)"
    Ok (@(Lines | Where-Object { $_ -match '(BD-Team-Project|Internal-scraper).*\(có / không\)' }).Count -eq 0) "a legacy repo is gate-push: no question: $(Lines)"
    $dis = @($W.GhLog | Where-Object { $_.Text -match $GhForm.Disable })
    if ($a -ceq 'không') { Eq $dis.Count 0 'không disables nothing' } else {
      Ok ($dis.Count -eq 1 -and $dis[0].Text -match 'deploy\.yml' -and $dis[0].Text -match 'brooklyn96/task') "có disables brooklyn96/task deploy.yml only: $(@($dis | ForEach-Object { $_.Text }) -join ' | ')"
      $lp = @(@((Get-St).legacy_push) | Where-Object { $_ } | ForEach-Object { "$($_.project)=$($_.repo)" }) | Sort-Object
      Eq ($lp -join ',') 'deal-sync=brooklyn96/BD-Team-Project,vps-scraper=brooklyn96/Internal-scraper' 'state legacy_push[] {project, repo}'
    }
  }
}

# ============================== copy (D.3) ==============================
T 'L.copy-first-gate-equal: a new whose gate id differs after bootstrap gate is refreshed once; a second difference refuses gate-version side=new, nothing stopped' {
  Fx-Planned; $W.NewGate.Enqueue($GateB)
  [void](Do-Copy 0); Eq (@(LogNow | Where-Object { $_ -ceq 'new script:bootstrap gate' }).Count) 2 'one refresh'
  Reset-World; Fx-Planned; $W.NewGate.Enqueue($GateB); $W.NewGate.Enqueue($GateB)
  [void](Do-Copy 65); HasText 'Hai máy chạy bản gate khác nhau'; Eq (Sent 'new' '-c\.init-new$') 0 'nothing on new after the refusal'
}
T 'L.copy-refresh-transfers-again: a copy re-run is a full re-plan from the stored target_users, then c.repin.1 on both, c.prepare.2 and steps 6–8 under new ids' {
  Fx-Copied
  $W.Pf = @('INV target user=zed uid=1700 home-nonskel=0', 'INV target stop_budget_s=1')
  [void](Do-Copy 0)
  Ordered @('^old plan:full$', '^old fwd-1-c\.repin\.1$', '^new fwd-1-c\.prepare\.2$', '^new fwd-1-c\.transfer\.2$', '^new fwd-1-c\.adopt\.2$')
  Ok ((Sent 'new' "^fwd-1-$([regex]::Escape((PassStep 'c.repin' 1)))$") -eq 1) 'c.repin.1 on new (T10-G19)'; Ok ((Sent 'old' "^fwd-1-$([regex]::Escape((PassStep 'c.verify' 2)))$") -eq 1 -and (Sent 'new' "^fwd-1-$([regex]::Escape((PassStep 'c.verify' 2)))$") -eq 1) 'c.verify.2 on both (T10-G19)'
  Eq (@(LogNow | Where-Object { $_ -match 'script:preflight' }).Count) 0 'no new preflight'
  $in = @($W.PlanStdin[-1]); Ok ($in -ccontains 'target-user quoc 1000') "stored target_users on the re-plan stdin: $($in -join ' | ')"; Ok (-not ($in -match 'zed')) 'never the current preflight list'
  foreach ($n in 'old', 'new') { $j = $W[$n].RepinStdin; Ok ($null -ne $j -and $null -ne $j.manifest) "c.repin stdin on $n holds the manifest"; Ok (-not $j.PSObject.Properties['old_addr'] -and -not $j.PSObject.Properties['new_addr']) "c.repin stdin on $n has no address keys" }
}
T 'L.copy-refresh-transfers-again: a first copy that failed after both c.init-* is re-run with no c.init-* (both statuses show this move-id at the state''s dir and attempt): plan <id>, c.repin.N on both, c.prepare.N, steps 6–8 (ruling NEW-2 (a), K1)' {
  Fx-Planned; Add-Fault -M new -Key '-c\.transfer\.1$' -Rc 1
  $r1 = Run-Move @('copy'); Ok ($r1.Code -ne 0) "first copy fails ($($r1.Text))"
  [void](Do-Copy 0)
  Eq (SentAny '-c\.init-(old|new)$') 0 "no c.init-* re-sent: $((LogNow) -join ' ; ')"
  Eq (@(LogNow | Where-Object { $_ -match '^old plan:full$' }).Count) 1 "one plan <id>: $((LogNow) -join ' ; ')"
  Ok ((Sent 'old' '^fwd-1-c\.repin\.[0-9]+$') -eq 1 -and (Sent 'new' '^fwd-1-c\.repin\.[0-9]+$') -eq 1) "c.repin.N on both: $((LogNow) -join ' ; ')"
  foreach ($n in 'old', 'new') { Before '^old plan:full$' "^$n fwd-1-c\.repin\.[0-9]+$"; Before "^$n fwd-1-c\.repin\.[0-9]+$" '^new fwd-1-c\.prepare\.[0-9]+$' }
  Ordered @('^new fwd-1-c\.prepare\.[0-9]+$', '^new fwd-1-c\.transfer\.[0-9]+$', '^(old|new) fwd-1-c\.verify\.[0-9]+$', '^new fwd-1-c\.adopt\.[0-9]+$')
  Eq (Get-St).phase 'copied' 'phase'; foreach ($n in 'old', 'new') { Eq $W[$n].Sha $W.LastSha "$n pinned to the re-plan's sha" }
}
T 'L.copy-refresh-reprepares: a user added on old after the first copy is in the re-planned manifest; both machines re-pin to its sha before c.prepare.2 creates it' {
  Fx-Copied
  $W.Mf.users = @($W.Mf.users) + [ordered]@{ name = 'late'; uid = 1003 }
  [void](Do-Copy 0)
  $s = Get-St; Eq $s.manifest_sha $W.LastSha 'state pins the re-planned sha'
  foreach ($n in 'old', 'new') { Eq $W[$n].Sha $W.LastSha "$n re-pinned" }
  Before '^new fwd-1-c\.repin\.1$' '^new fwd-1-c\.prepare\.2$'; Before '^old fwd-1-c\.repin\.1$' '^new fwd-1-c\.prepare\.2$'
}
T 'L.copy-planned-no-chore0: plan sets enabled=true, so copy in phase planned never runs chore 0 (I31)' {
  Fx-Planned; Eq (Get-St).enabled $true 'enabled at plan'
  [void](Do-Copy 0); NoChore0
}
T 'L.copy-idmap: a c.prepare.N idmap line the state lacks is kept in idmap[] and re-plans (plan <id> with the idmap stdin line, c.repin.N on both) before c.transfer.N; a re-plan that was refused is redone by the next copy before any transfer (B.6.2)' {
  $idl = 'MOVE item idmap:user:svc kind=prepare state=mapped src_id=105 dst_id=110'
  Fx-Planned; Add-Fault -M new -Key '-c\.prepare\.1$' -Rc 0 -Out @($idl)
  [void](Do-Copy 0)
  Ordered @('^new fwd-1-c\.prepare\.1$', '^old plan:full$', '^(old|new) fwd-1-c\.repin\.1$', '^new fwd-1-c\.transfer\.1$')
  Ok ((Sent 'old' '-c\.repin\.1$') -eq 1 -and (Sent 'new' '-c\.repin\.1$') -eq 1) "c.repin.1 on both: $(LogNow)"
  Ok (@($W.PlanStdin[-1]) -ccontains 'idmap user svc 105 110') "re-plan stdin: $(@($W.PlanStdin[-1]) -join ' | ')"
  Ok (@(@((Get-St).idmap) | Where-Object { $_.kind -ceq 'user' -and $_.name -ceq 'svc' -and "$($_.src_id)" -ceq '105' -and "$($_.dst_id)" -ceq '110' }).Count -eq 1) "state idmap[]: $(ConvertTo-Json -InputObject @((Get-St).idmap) -Compress)"
  Eq $W.new.Sha $W.LastSha 'new pinned to the re-planned sha'
  Reset-World; Fx-Planned
  Add-Fault -M new -Key '-c\.prepare\.1$' -Rc 0 -Out @($idl); Add-Fault -M old -Key '^plan:full$' -Rc 65 -Out @('INV refuse transient unit=x.service')
  $r1 = Run-Move @('copy'); Ok ($r1.Code -ne 0) "the refused re-plan stops the copy ($($r1.Text))"; Eq (SentAny '-c\.transfer\.') 0 'first copy: nothing transferred'
  Add-Fault -M new -Key '-c\.prepare\.2$' -Rc 0 -Out @($idl)
  [void](Do-Copy 0); Before '^old plan:full$' '^new fwd-1-c\.transfer\.'; Ok (@($W.PlanStdin[-1]) -ccontains 'idmap user svc 105 110') "the redone re-plan sends the idmap line: $(@($W.PlanStdin[-1]) -join ' | ')"
}
T 'L.copy-idmap: a state idmap[] entry that the re-plan dropped (the owner added exclude user svc) and this c.prepare.N no longer prints never re-plans again at the refresh (B.6.2: only an entry this c.prepare.N printed that the pinned idmap[] lacks)' {
  $idl = 'MOVE item idmap:user:svc kind=prepare state=mapped src_id=105 dst_id=110'
  Fx-Planned; Add-Fault -M new -Key '-c\.prepare\.1$' -Rc 0 -Out @($idl)
  [void](Do-Copy 0); Eq (Get-St).phase 'copied' 'phase after the first copy'
  $W.PlanHook = { param($n, $mapl) $W.Mf.idmap = @(@($W.Mf.idmap) | Where-Object { $_.name -cne 'svc' }); $null }   # the server's map step drops the excluded user's entry
  [void](Do-Copy 0)
  Eq (@(LogNow | Where-Object { $_ -match '^old plan:full$' }).Count) 1 "plan:full count in the refresh copy (its own re-plan only): $((LogNow) -join ' ; ')"
}
T 'L.copy-idmap: a first copy whose idmap re-plan re-pinned both machines and then failed at c.adopt.1 is copied again with no c.init-* (ruling NEW-2 (a); T10c PROBE.rev2-replan-then-fail)' {
  $idl = 'MOVE item idmap:user:svc kind=prepare state=mapped src_id=105 dst_id=110'
  Fx-Planned; Add-Fault -M new -Key '-c\.prepare\.1$' -Rc 0 -Out @($idl); Add-Fault -M new -Key '-c\.adopt\.1$' -Rc 1
  $r1 = Run-Move @('copy'); Ok ($r1.Code -ne 0) "first copy fails ($($r1.Text))"; Ok ((Sent 'new' '^fwd-1-c\.repin\.1$') -eq 1) "the first copy re-pinned new: $((LogNow) -join ' ; ')"
  Add-Fault -M new -Key '-c\.prepare\.[2-9]$' -Rc 0 -Out @($idl)
  $r2 = Run-Move @('copy'); Eq $r2.Code 0 "second copy exit ($($r2.Text)) log: $((LogNow) -join ' ; ')"
  Eq (SentAny '-c\.init-(old|new)$') 0 "no c.init-* re-sent: $((LogNow) -join ' ; ')"; Eq (@(LogNow | Where-Object { $_ -match 'call-argv' }).Count) 0 'no call-argv'
  Before '^old plan:full$' '^new fwd-1-c\.prepare\.[0-9]+$'; Before '^new fwd-1-c\.prepare\.[0-9]+$' '^new fwd-1-c\.adopt\.[0-9]+$'
  Eq (Get-St).phase 'copied' 'phase'; foreach ($n in 'old', 'new') { Eq $W[$n].Sha $W.LastSha "$n pinned to the re-planned sha" }
}
T 'L.copy-idmap: an idmap re-plan whose c.repin.1 failed on new (the laptop already on the new sha) is finished by the next copy with no c.init-* (ruling NEW-2 (a); T10c PROBE.rev2-repin-fail)' {
  $idl = 'MOVE item idmap:user:svc kind=prepare state=mapped src_id=105 dst_id=110'
  Fx-Planned; Add-Fault -M new -Key '-c\.prepare\.1$' -Rc 0 -Out @($idl); Add-Fault -M new -Key '-c\.repin\.1$' -Rc 1
  $r1 = Run-Move @('copy'); Ok ($r1.Code -ne 0) "first copy fails ($($r1.Text))"; Eq (SentAny '-c\.transfer\.') 0 'nothing transferred'; Eq (Get-St).manifest_sha $W.LastSha 'the laptop is on the new sha'
  Add-Fault -M new -Key '-c\.prepare\.[2-9]$' -Rc 0 -Out @($idl)
  $r2 = Run-Move @('copy'); Eq $r2.Code 0 "second copy exit ($($r2.Text)) log: $((LogNow) -join ' ; ')"
  Eq (SentAny '-c\.init-(old|new)$') 0 "no c.init-* re-sent: $((LogNow) -join ' ; ')"; Eq (@(LogNow | Where-Object { $_ -match 'call-argv' }).Count) 0 'no call-argv'
  Ok ((Sent 'new' '^fwd-1-c\.repin\.[0-9]+$') -ge 1) "new re-pinned: $((LogNow) -join ' ; ')"; Before '^new fwd-1-c\.repin\.[0-9]+$' '^new fwd-1-c\.transfer\.[0-9]+$'
  Eq (Get-St).phase 'copied' 'phase'; foreach ($n in 'old', 'new') { Eq $W[$n].Sha $W.LastSha "$n pinned to the re-planned sha" }
}
T 'L.copy-after-collision-remedy: a copy whose c.init-new failed (the server wrote the move-id first) is re-run under the same id after the remedy, and the server runs it again; old''s init is not re-sent, so the copy goes on as the D.3 re-run (plan <id>, c.repin.N on both, c.prepare.N)' {
  Fx-Planned; Add-Fault -M new -Key '-c\.init-new$' -Rc 1 -Out @('MOVE error tool-missing tool=e2fsprogs') -Effect
  $r = Do-Copy -1; Ok ($r.Code -ne 0) 'the first copy fails'
  [void](Do-Copy 0)
  Eq (Sent 'new' '^fwd-1-c\.init-new$') 1 'the same id runs again (not a replay)'; Eq (Get-St).phase 'copied' 'phase'
  Eq (SentAny '^fwd-1-c\.init-old$' -All) 1 "c.init-old never re-sent: old's status shows this move-id at (fwd, 1) (ruling NEW-2 (a)): $((LogNow) -join ' ; ')"
  Eq (@(LogNow | Where-Object { $_ -match '^old plan:full$' }).Count) 1 "one plan <id>: $((LogNow) -join ' ; ')"; Before '^new fwd-1-c\.init-new$' '^old plan:full$'
  Ok ((Sent 'old' '^fwd-1-c\.repin\.[0-9]+$') -eq 1 -and (Sent 'new' '^fwd-1-c\.repin\.[0-9]+$') -eq 1) "c.repin.N once on each machine: $((LogNow) -join ' ; ')"
  foreach ($n in 'old', 'new') { Before '^old plan:full$' "^$n fwd-1-c\.repin\.[0-9]+$"; Before "^$n fwd-1-c\.repin\.[0-9]+$" '^new fwd-1-c\.prepare\.[0-9]+$' }
}
T 'L.copy-after-collision-remedy: c.init-old wrote the move-id, then failed (keys-race 70 at the move-key line, E-S8); the next copy re-sends c.init-old under the same id and the server runs it again (D.0.5, E-P31; move-run.sh writes the move-id first; T10d review PROBE.rv10d-init-old-halfdone)' {
  Fx-Planned; Add-Fault -M old -Key '-c\.init-old$' -Rc 70 -Out @('MOVE error keys-race path=/root/.ssh/authorized_keys') -Effect
  $r1 = Run-Move @('copy'); Ok ($r1.Code -ne 0) "first copy fails ($($r1.Text))"
  Ok ($null -ne $W.old.MoveId -and "$($W.old.MoveId.attempt)" -ceq '1') 'old holds the move-id of the half-done init'
  $r2 = Run-Move @('copy'); Eq $r2.Code 0 "second copy exit ($($r2.Text))"; Eq (Get-St).phase 'copied' 'phase'
  Eq (Sent 'old' '^fwd-1-c\.init-old$') 1 "the half-done c.init-old runs again on the re-run: $((LogNow) -join ' ; ')"
}
T 'L.copy-after-collision-remedy: c.init-new wrote the move-id, then failed (holds-off rc 1); the next copy re-sends c.init-new before any transfer (I12, D.0.5, E-P31; T10d review PROBE.rv10d-init-new-halfdone)' {
  Fx-Planned; Add-Fault -M new -Key '-c\.init-new$' -Rc 1 -Out @('LOG holds-off failed') -Effect
  $r1 = Run-Move @('copy'); Ok ($r1.Code -ne 0) "first copy fails ($($r1.Text))"
  $r2 = Run-Move @('copy'); Eq $r2.Code 0 "second copy exit ($($r2.Text))"; Eq (Get-St).phase 'copied' 'phase'
  Eq (Sent 'new' '^fwd-1-c\.init-new$') 1 "the half-done c.init-new runs again on the re-run: $((LogNow) -join ' ; ')"; Before '^new fwd-1-c\.init-new$' '^new fwd-1-c\.transfer\.[0-9]+$'
}
T 'L.copy-after-collision-remedy: c.init-new wrote the move-id and was still running when ssh dropped; the next copy''s status shows it running, it ends failed while copy waits (Wait-MoveRunning keeps the stale status), and the copy re-sends c.init-new under the same id before any transfer (DESIGN-GAP T10d-NEW2-halfdone: only a done init counts as seen)' {
  Fx-Planned; Add-Fault -M new -Key '-c\.init-new$' -Rc 1 -Out @('LOG holds-off pending') -Effect -Mode down
  $r1 = Run-Move @('copy'); Ok ($r1.Code -ne 0) "first copy fails ($($r1.Text))"
  Ok ($null -ne $W.new.MoveId -and "$($W.new.MoveId.attempt)" -ceq '1') 'new holds the move-id of the half-done init'
  $W.new.Up = $true; Set-Running 'new' 'fwd-1-c.init-new'; $W.new.Running.Rc = 1; $W.new.Running.Left = 1
  $r2 = Run-Move @('copy'); Eq $r2.Code 0 "second copy exit ($($r2.Text)) log: $((LogNow) -join ' ; ')"; Eq (Get-St).phase 'copied' 'phase'
  Eq (Sent 'new' '^fwd-1-c\.init-new$') 1 "the init that ended failed runs again: $((LogNow) -join ' ; ')"; Before '^new fwd-1-c\.init-new$' '^new fwd-1-c\.transfer\.[0-9]+$'
}
T 'L.wait-transfer: a call still running when its deadline passes is waited for or re-attached by id, never answered busy by another id' {
  Fx-Planned; Add-Fault -M new -Key '-c\.transfer\.1$' -Rc 0 -Mode running -Left 3
  [void](Do-Copy 0)
  Eq (@(LogNow | Where-Object { $_ -match ' busy$' }).Count) 0 'no other id while the transfer runs'
  Eq (Get-St).phase 'copied' 'phase'
}
T 'L.bootstrap-tools: bootstrap key ending with tool-missing (after its install try) stops copy with the label before any init; nothing written on old' {
  Fx-Planned; Add-Fault -M new -Key '^script:bootstrap key$' -Rc 1 -Out @('MOVE error tool-missing name=acl')
  $r = Do-Copy -1; Ok ($r.Code -ne 0) 'copy stops'; HasText 'Thiếu công cụ cần thiết'; Eq (SentAny '-c\.init-') 0 'no init'; Eq (Get-St).phase 'planned' 'phase'
}
T 'L.bootstrap-known-hosts-port: bootstrap key gets --old-addr from plan (default old''s address, else --old-addr as given)' {
  Fx-Copied
  $bk = @(Calls -All | Where-Object { $_.Script -ceq 'bootstrap key' })[0]; Ok ($null -ne $bk) 'bootstrap key ran'
  Eq $bk.Args[0] '--old-addr' 'arg 1'; Eq $bk.Args[1] $OldAddr 'default --old-addr'; Eq $bk.Args[2] "ssh-ed25519 $KeyOld" 'old''s key line'
  Reset-World; [void](Do-Plan @('--old-addr', '127.0.0.1:2222')); [void](Do-Copy)
  $bk = @(Calls -All | Where-Object { $_.Script -ceq 'bootstrap key' })[0]; Eq $bk.Args[1] '127.0.0.1:2222' '--old-addr kept as given'
}
T 'L.bootstrap-known-hosts-port: the bootstrap key script writes MV_DIR/known_hosts as <host> <key> for port 22 and [<host>]:<port> <key> otherwise' {
  $txt = Get-MoveBootstrapKeyScript
  foreach ($c in @(@($OldAddr, "$OldAddr ssh-ed25519 $KeyOld"), @("${OldAddr}:22", "$OldAddr ssh-ed25519 $KeyOld"), @('127.0.0.1:2222', "[127.0.0.1]:2222 ssh-ed25519 $KeyOld"))) {
    $fr = New-FcmRoot
    $r = Run-Bash $txt @('--old-addr', $c[0], "ssh-ed25519 $KeyOld", '--node-major', '22') $fr (New-Stubs @{})
    Eq $r.Code 0 "bootstrap key [$($c[0])] exit: $($r.Text)"
    Ok ($r.Text -match '(?m)^MOVE key type=ssh-ed25519 pub=[A-Za-z0-9+/=]+\s*$') "MOVE key line: $($r.Text)"
    $kh = Join-Path $fr 'var/lib/fcode-move/known_hosts'; Ok (Test-Path -LiteralPath $kh) "[$($c[0])] known_hosts written"
    $ls = @([IO.File]::ReadAllLines($kh) | Where-Object { $_.Trim() })
    Ok ($ls -ccontains $c[1]) "[$($c[0])] known_hosts must hold [$($c[1])]: $($ls -join ' | ')"
    Ok (-not ($ls -match '^\[[^\]]+\]:22 ')) "[$($c[0])] port 22 is never bracketed"
  }
} -NeedsBash

# ============================== cutover (D.4) ==============================
T 'L.cut-text: Q-cut names both estimates, the Zalo loss, the external IP allowlist reminder (reading T10-G8), the three fixed texts and the excluded transient units; không writes nothing' {
  $W.PlanOut = @('INV warn transient-excluded unit=velh-x.service', 'INV ok')
  Fx-Copied; Ans 'không'
  $r = Run-Move @('cutover'); Eq $r.Code 0 'không = exit 0'
  foreach ($t in 'nếu lỗi sau khi máy mới đã chạy, dữ liệu sẽ được chép ngược về máy cũ', 'đừng deploy tay lúc này', 'Hermes và `fcode deploy status` báo `moving` trong lúc chuyển', 'Zalo', 'Các unit tạm sau đã dừng và sẽ không được tạo lại: ', 'velh-x.service') { HasText $t }
  NoRecorded 'Q-cut không'; Ok ($null -eq (Get-St).mark) 'mark still null'; Eq (Get-St).phase 'copied' 'phase'
  HasText $CutAllowlistText
  $est = (Get-St).est; $ql = @(Lines -Last | Where-Object { $_ -match 'Zalo' } | Select-Object -First 1)
  Ok ($ql.Count -eq 1 -and $ql[0] -match "(^|\D)$([int]$est.typical_s)(\D|$)" -and $ql[0] -match "(^|\D)$([int]$est.max_s)(\D|$)") "Q-cut shows est_typical $($est.typical_s) and est_max $($est.max_s): $ql"
}
T 'L.drain-question: x.freeze busy at cap_s asks Q-drain; đợi sends the same x.freeze again and the cutover goes on' {
  Fx-Copied; Add-Fault -M old -Key '-x\.freeze$' -Rc 75 -Out @('MOVE wait drain lock=/var/lock/fcode-deploy/task.lock waited=900')
  Ans 'có', 'đợi'; $r = Run-Move @('cutover'); Eq $r.Code 0 "exit ($($r.Text))"
  Ok (@(Lines | Where-Object { $_ -match '\AMáy cũ còn việc deploy đang chạy \(.*\)\. đợi = đợi thêm [0-9]+ phút; dừng = mở lại máy cũ và dừng\. \(đợi / dừng\)\z' }).Count -ge 1) "Q-drain text: $(Lines)"
  Eq (@(LogNow | Where-Object { $_ -ceq 'old fwd-1-x.freeze' }).Count) 2 'x.freeze sent twice under its id'; Eq (Get-St).phase 'cut' 'phase'
}
T 'L.drain-question: a follower still active at its own stop_budget_s (MOVE wait follower) asks Q-drain naming the unit; đợi sends the same x.freeze again (D.4 step 2, DECISION-1k6-K1budget)' {
  Fx-Copied; Add-Fault -M old -Key '-x\.freeze$' -Rc 75 -Out @('MOVE wait follower unit=job.service waited=930')
  Ans 'có', 'đợi'; $r = Run-Move @('cutover'); Eq $r.Code 0 "exit ($($r.Text))"
  Ok (@(Lines | Where-Object { $_ -match '\AMáy cũ còn việc deploy đang chạy \([^)]*job\.service[^)]*\)\. đợi = đợi thêm [0-9]+ phút; dừng = mở lại máy cũ và dừng\. \(đợi / dừng\)\z' }).Count -ge 1) "Q-drain names the follower: $(Lines)"
  Eq (@(LogNow | Where-Object { $_ -ceq 'old fwd-1-x.freeze' }).Count) 2 'x.freeze sent twice under its id'; Eq (Get-St).phase 'cut' 'phase'
}
T 'L.guard-question: a busy guard at cap_s asks Q-guard; tiếp tục goes to step 5 without re-running guards, dừng rolls back (10, never 75)' {
  Fx-Copied; Add-Fault -M old -Key '-x\.guards$' -Rc 75 -Out @('MOVE wait guard project=task waited=900')
  Ans 'có', 'tiếp tục'; $r = Run-Move @('cutover'); Eq $r.Code 0 'tiếp tục'
  Ok (@(Lines | Where-Object { $_ -match '\AỨng dụng .* đang bận\. tiếp tục = vẫn dừng ứng dụng để chuyển; dừng = quay lại máy cũ\. \(tiếp tục / dừng\)\z' }).Count -ge 1) "Q-guard text: $(Lines)"
  Eq (Sent 'old' '-x\.guards$') 1 'guards not run again'; Before '^old fwd-1-x\.guards$' '^old fwd-1-x\.stop-src$'
  Reset-World; Fx-Copied; Add-Fault -M old -Key '-x\.guards$' -Rc 75 -Out @('MOVE wait guard project=task waited=900')
  Ans 'có', 'dừng'; $r = Run-Move @('cutover'); Eq $r.Code 10 'dừng rolls back'; Eq (Sent 'old' '-x\.stop-src$') 0 'nothing stopped'; Eq (Get-St).phase 'rolled-back' 'phase'
}
function Assert-Rb([int]$Code = 10) {
  Eq $script:Last.Code $Code "rollback exit ($($script:Last.Text))"
  $s = Get-St; Eq $s.phase 'rolled-back' 'phase'; Eq $s.serving 'old' 'serving'; Ok ($null -eq $s.mark) 'mark null'
  Eq (SentAny '-x\.start$') 0 'x.start never sent in a plain rollback'
  Ordered @('^old fwd-1-r\.start-src$', '^old fwd-1-r\.unfreeze-src$', '^old fwd-1-r\.health-src$')
  HasText 'Đã quay về máy cũ; máy cũ đang phục vụ.'
}
function Rb-Trigger([string]$M, [string]$Key, [int]$Rc, [string[]]$Out) { Fx-Copied; Add-Fault -M $M -Key $Key -Rc $Rc -Out $Out; [void](Do-Cutover -1); Assert-Rb; Eq $W.old.Frozen $false 'old unfrozen'; Eq $W.old.Active $Holds 'old serves'; Eq (Get-St).enabled $true 'enabled after r.start-src 0' }
T 'L.rb-trigger-2: x.freeze failing rolls back (exit 10)' { Rb-Trigger 'old' '-x\.freeze$' 1 @('MOVE error tool-missing tool=x') }
T 'L.rb-trigger-3: x.check manifest-stale rolls back' { Rb-Trigger 'old' '-x\.check$' 65 @('MOVE error manifest-stale what=user name=bob') }
T 'L.rb-trigger-4: x.guards guard-failed rolls back' { Rb-Trigger 'old' '-x\.guards$' 1 @('MOVE error guard-failed project=task why=fail') }
T 'L.rb-trigger-5: x.stop-src drain-lost rolls back and stops dst' { Rb-Trigger 'old' '-x\.stop-src$' 1 @('MOVE error drain-lost lock=/var/lock/fcode-deploy/task.lock'); Ok ((Sent 'new' '-r\.stop-dst$') -eq 1) 'r.stop-dst on new' }
T 'L.rb-trigger-6: x.final failing rolls back' { Rb-Trigger 'new' '-x\.final$' 1 @('MOVE error rsync-failed why=net'); Ok ((Sent 'new' '-r\.stop-dst$') -eq 1) 'r.stop-dst on new' }
T 'L.rb-trigger-7: x.adopt failing rolls back' { Rb-Trigger 'new' '-x\.adopt$' 1 @('MOVE item nginx kind=check state=failed') }
T 'L.verify-compare: a digest difference at x.verify rolls back first, then fetches both verify.lst with status --lst and reports sum-mismatch with the paths' {
  Fx-Copied; $W.new.Digest['opt-app'] = 'cccccccccccc'
  [void](Do-Cutover -1); Assert-Rb
  Before '^old fwd-1-r\.unfreeze-src$' '^(old|new) status --lst fwd-1-x\.verify$'
  Ok (@(LogNow | Where-Object { $_ -match '^(old|new) status --lst fwd-1-x\.verify$' }).Count -ge 2) 'both verify.lst fetched'
  HasText 'Dữ liệu hai máy khác nhau'; HasText 'opt-app'; HasText '/opt/app/f3'
  Reset-World; Fx-Planned; $W.new.Digest['opt-app'] = 'cccccccccccc'; [void](Do-Copy 0)
}
# R5-4: "sent with the call" (D.4 step 8) is the existing --dst-started 1 flag; no new argv token (the argv contract check is unchanged)
T 'L.dst-started-before-start: dst_started=true and dst_started_at are saved in state.json before x.start is sent, and x.start carries --dst-started 1 (R5-3, R5-4)' {
  Fx-Copied; $script:SeenDst = $null; $script:SeenArg = $null; $script:SeenAt = $null
  $W.Hooks['x.start'] = { param($m, $e) $script:SeenDst = (Get-St).dst_started; $script:SeenArg = $e.Flags['dst-started']; $script:SeenAt = St-Raw 'dst_started_at' }
  [void](Do-Cutover 0); Eq $script:SeenDst $true 'state at x.start'; Eq $script:SeenArg '1' '--dst-started'
  Ok ("$script:SeenAt" -match $TsRx) "dst_started_at in state.json at x.start: [$script:SeenAt]"
}
T 'L.rb-dst-unreachable-not-started: new unreachable in a rollback before x.start: dst stop skipped after its retries, old started, exit 10 with the text' {
  Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Mode down
  [void](Do-Cutover -1); Eq $script:Last.Code 10 'exit'; HasText 'máy mới không trả lời; máy cũ chạy lại'
  Ok ((Sent 'old' '-r\.start-src$') -eq 1) 'old started'; Eq $W.old.Active $Holds 'old serves'
}
T 'L.rb-fail-src-start: old r.start-src failing in a rollback: unfreeze still tried, exit 70, enabled=false' {
  Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Rc 1; Add-Fault -M old -Key '-r\.start-src$' -Rc 1
  [void](Do-Cutover 70); Ok ((Sent 'old' '-r\.unfreeze-src$') -eq 1) 'unfreeze tried'; Eq (Get-St).enabled $false 'enabled'
}
T 'L.rb-unfreeze-fail: r.unfreeze-src failing: exit 70, old serves frozen, enabled=false' {
  Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Rc 1; Add-Fault -M old -Key '-r\.unfreeze-src$' -Rc 1
  [void](Do-Cutover 70); $s = Get-St; Eq $s.enabled $false 'enabled'; Eq $s.phase 'rolled-back' 'phase'; Eq $s.serving 'old' 'serving'; Eq $W.old.Frozen $true 'old still frozen'
}
T 'L.prerule-after-rb-unfreeze-fail: the next verb repairs old first with chore 0 (x.enable.N, x.unfreeze.N) under the current attempt' {
  Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Rc 1; Add-Fault -M old -Key '-r\.unfreeze-src$' -Rc 1
  [void](Do-Cutover 70)
  [void](Do-Copy 0)
  Ordered @('^old fwd-1-x\.enable\.[0-9]+$', '^old fwd-1-x\.unfreeze\.[0-9]+$', '^old fwd-2-c\.init-old$')
  Eq $W.old.Frozen $false 'old unfrozen by the repair'
}
T 'L.rb-health-fail-unfreezes: a failing r.health-src is reported after the unfreeze with the failed checks; old serves, exit 10 (report only: D.5.1, E-R18; W1-T11-DG-T11-2)' {
  Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Rc 1; Add-Fault -M old -Key '-r\.health-src$' -Rc 69 -Out @('MOVE item health-nginx kind=check state=failed')
  [void](Do-Cutover 10); HasText 'health-nginx'
  Before '^old fwd-1-r\.unfreeze-src$' '^old fwd-1-r\.health-src$'; Eq $W.old.Frozen $false 'unfrozen'; $s = Get-St; Eq $s.serving 'old' 'serving'; Eq $s.phase 'rolled-back' 'phase'; Eq $s.enabled $true 'enabled (r.start-src answered 0)'
}
T 'L.rb-after-deadline: a call past its deadline (budget + 60, unit ended rc 143) is read by status, then the rollback runs' {
  Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Mode timeout
  [void](Do-Cutover 10)
  $fc = @(RecCalls | Where-Object { $_.Call -match '-x\.final$' })[0]; Eq $fc.Timeout ([int]$fc.Budget + 60) 'x.final deadline'
  Ordered @('^new fwd-1-x\.final$', '^new status', '^new fwd-1-r\.stop-dst$')
}
T 'L.rb-text-excluded-transient: every return-to-old text names the excluded transient units' {
  $W.PlanOut = @('INV warn transient-excluded unit=velh-x.service', 'INV ok')
  Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Rc 1; [void](Do-Cutover 10)
  HasText 'Đã quay về máy cũ; máy cũ đang phục vụ.'; HasText 'Các unit tạm sau đã dừng và sẽ không được tạo lại: '; HasText 'velh-x.service'
}
T 'L.unknown-outcome: a call answered without GATE_EXIT is resolved by real state: done goes on, a recorded failure rolls back, never taken as done' {
  Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Rc 0 -Mode noexit
  [void](Do-Cutover 0); Ordered @('^new fwd-1-x\.final$', '^new status', '^(old|new) fwd-1-x\.verify$'); Eq (Get-St).phase 'cut' 'done goes on'
  Reset-World; Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Rc 1 -Mode noexit; [void](Do-Cutover 10); Eq (SentAny '-x\.start$') 0 'a failed final is never taken as done'
}
T 'L.unknown-outcome: both status answers are read before the laptop acts on an unknown outcome (I16)' {
  Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Rc 0 -Mode noexit
  [void](Do-Cutover 0)
  $l = LogNow; $i = [Array]::IndexOf($l, 'new fwd-1-x.final'); $after = @($l[($i + 1)..($l.Count - 1)]); $j = [Array]::IndexOf($after, (@($after | Where-Object { $_ -match 'x\.verify' })[0]))
  $between = @($after[0..([Math]::Max(0, $j - 1))]); Ok ((@($between | Where-Object { $_ -ceq 'old status' }).Count -ge 1) -and (@($between | Where-Object { $_ -ceq 'new status' }).Count -ge 1)) "both status read: $($between -join ' ; ')"
}
T 'L.parse: only INV, MOVE and GATE_EXIT lines are parsed; LOG and other lines never refuse' {
  $W.PlanOut = @('LOG INV refuse os', 'XINV refuse arch', 'note: MOVE error busy', ' INV refuse dns', 'INV ok')
  [void](Do-Plan -Want 0)
}
T 'L.parse-no-exit: an answer without GATE_EXIT is a failure (exit 1), nothing written' {
  Add-Fault -M old -Key '^plan:check$' -Rc 0 -Out @('INV ok') -Mode noexit
  $r = Run-Move @('check'); Eq $r.Code 1 'exit'
  Ok (-not (Test-Path -LiteralPath (Join-Path (MoveDir) 'check.json'))) 'nothing written (no check.json)'; Ok ($null -eq (Get-St)) 'no state.json'
}
T 'L.exit-codes: 0 done, 1 failed safe to re-run, 10 rolled back, 65 refused, 70 needs a human, 75 busy; 75 never after a rollback, 10 never when it failed' {
  Fx-Copied; Eq (Get-St).phase 'copied' '0 path'
  Reset-World; Fx-Planned; Add-Fault -M new -Key '-c\.transfer\.1$' -Rc 1 -Out @('MOVE error rsync-failed why=net'); [void](Do-Copy 1); HasText 'mạng đứt; chạy fcode move copy lại'
  Reset-World; Fx-Planned; Add-Fault -M new -Key '-c\.transfer\.1$' -Rc 75 -Out @('MOVE error busy'); [void](Do-Copy 75)
  Reset-World; Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Rc 1; [void](Do-Cutover 10)
  Reset-World; Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Rc 1; Add-Fault -M old -Key '-r\.start-src$' -Rc 1; [void](Do-Cutover 70)
  Reset-World; Fx-Copied; Add-Fault -M old -Key '-x\.guards$' -Rc 75 -Out @('MOVE wait guard project=task waited=900'); Ans 'có', 'dừng'; $r = Run-Move @('cutover'); Eq $r.Code 10 'Q-guard dừng after a rollback'
  Reset-World; $W.Pf = @('INV refuse disk need_mb=9 free_mb=1'); $W.PfCode = 65; [void](Do-Plan -Want 65)
}
T 'L.bounded-calls: every call has a deadline; recorded calls carry --budget from the D.0.6 table, then max(table, 3 × last dur_s), deadline budget + 60; status 60; ssh keepalive options' {
  $W.Dur['^c\.prepare\.'] = 200; $W.Dur['^c\.adopt\.'] = 1000
  Fx-Copied
  $b = @{}; foreach ($c in @(RecCalls -All)) { $b[$c.Call] = [int]$c.Budget; Eq $c.Timeout ([int]$c.Budget + 60) "deadline of $($c.Call)" }
  Eq $b['fwd-1-c.init-old'] 300 'c.init-old'; Eq $b['fwd-1-c.init-new'] 180 'c.init-new = stop_budget_s + 60'; Eq $b['fwd-1-c.prepare.1'] 300 'c.prepare.1'
  Eq $b['fwd-1-c.transfer.1'] 21600 'first transfer'; Eq $b['fwd-1-c.verify.1'] 1800 'first verify'; Eq $b['fwd-1-c.adopt.1'] 1860 'adopt'
  [void](Do-Copy 0)
  $b2 = @{}; foreach ($c in @(RecCalls)) { $b2[$c.Call] = [int]$c.Budget }
  Eq $b2['fwd-1-c.prepare.2'] 600 'c.prepare.2 = max(300, 3 × 200)'; Eq $b2['fwd-1-c.adopt.2'] 3000 'c.adopt.2 = max(1860, 3 × 1000)'
  [void](Do-Cutover 0); $s = Get-St
  $b3 = @{}; foreach ($c in @(RecCalls)) { $b3[$c.Call] = [int]$c.Budget }
  Eq $b3['fwd-1-x.freeze'] (900 + 120 + 30) 'x.freeze = cap_s + cron.service (the one periodic source of the stop set) + 30'; Eq $b3['fwd-1-x.guards'] 930 'x.guards = cap_s + Σ run_s (no guard) + 30'; Eq $b3['fwd-1-x.switch'] 60 'x.switch = 60 (no connector, no tunnel name)'
  Eq $b3['fwd-1-x.baseline'] 300 'x.baseline = 300 (no redis, pg, tunnel, container, linger or health entry)'; Eq $b3['fwd-1-x.health'] 300 'x.health'
  Eq $b3['fwd-1-x.check'] (3 * 7 + 60) 'x.check = 3 × the measured 0c check-only + 60'
  Eq $b3['fwd-1-x.stop-src'] (3 * 120 + 30) 'x.stop-src = Σ stop budgets + 30'; Eq $b3['fwd-1-x.start'] (3 * 60 + 60) 'x.start = Σ start budgets + 60'
  Eq $b3['fwd-1-x.final'] (2 * [int]$s.est.transfer_s + 300) 'x.final = 2 × transfer_s + 300'; Eq $b3['fwd-1-x.verify'] (2 * [int]$s.est.verify_s + 120) 'x.verify = 2 × verify_s + 120'
  foreach ($c in @(Calls -All | Where-Object { $_.Kind -ceq 'gate' -and $_.Verb -ceq 'status' })) { Eq $c.Timeout 60 'status deadline' }
  foreach ($c in @(Calls -All | Where-Object { $_.Kind -in 'gate', 'script', 'login' })) {
    foreach ($kv in @('connecttimeout=10', 'serveraliveinterval=15', 'serveralivecountmax=4', 'batchmode=yes')) { $k, $v = $kv -split '='; Eq "$($c.Opts[$k])".ToLowerInvariant() $v "$k on $($c.M) $($c.Step)" }
  }
}
T 'L.move-lock: a second fcode move while move.lock is held answers 75 and calls nothing' {
  Fx-Planned
  $fs = New-Object IO.FileStream((Join-Path (MoveDir) 'move.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  try { $r = Run-Move @('copy'); Eq $r.Code 75 'exit'; Eq @(Calls).Count 0 'no ssh' } finally { $fs.Dispose() }
}
T 'L.state-atomic: state.json parses at every call of a whole move; no temp file is left; every write of state.json goes through the atomic writer (temp file + rename)' {
  Fx-Cut
  Ok ($W.StateSeen.Count -gt 10) 'state seen at the calls'
  $left = @(Get-ChildItem -LiteralPath (MoveDir) -File | Where-Object { $_.Name -notin 'state.json', 'known_hosts', 'manifest.json', 'map.txt', 'check.json', 'move.lock' })
  Ok ($left.Count -eq 0) "leftover files: $(@($left | ForEach-Object { $_.Name }) -join ', ')"
  $fns = @($script:FcodeAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -match 'Move' -and $n.Extent.Text.Contains("'state.json'") }, $true))
  Ok ($fns.Count -gt 0) 'no function names state.json'
  $bad = @($fns | Where-Object { $_.Extent.Text -match 'WriteAllText|AppendAllText|WriteAllBytes|Set-Content|Add-Content|Out-File' } | ForEach-Object { $_.Name })
  Ok ($bad.Count -eq 0) "state.json written in place (not atomic) by: $($bad -join ', ')"
  Ok (@($fns | Where-Object { $_.Extent.Text -match 'Write-PhienText|::Replace\(|::Move\(' }).Count -ge 1) 'state.json is written through a temp file and a rename'
}
T 'L.state-corrupt: a corrupt state.json stops every verb with the rebuild text, nothing called' {
  Fx-Copied; [IO.File]::WriteAllText((StatePath), '{"move_id": "mv-2026', $utf8)
  foreach ($v in 'copy', 'cutover', 'finish', 'abort', 'back') { $r = Run-Move @($v); Ok ($r.Code -ne 0) "$v exit"; HasText 'dựng lại trạng thái'; Eq @(Calls).Count 0 "$v calls nothing" }
}
T 'L.rebuild: status --rebuild reads both machines and writes state.json: addresses from the move-ids (not the ssh config), dur{} from the records, rebuilt=true' {
  Fx-Copied; $id0 = Id; [IO.File]::Delete((StatePath))
  [IO.File]::WriteAllText((Join-Path (Join-Path $Home2 '.ssh') 'config'), ($SshConfig0 + "`n"), $utf8)
  $W.old.MoveId.old_addr = $OldAddr; $W.old.MoveId.new_addr = $NewAddr; $W.new.MoveId.old_addr = $OldAddr; $W.new.MoveId.new_addr = $NewAddr
  $r = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $r.Code 0 "exit ($($r.Text))"
  $s = Get-St; Eq $s.rebuilt $true 'rebuilt'; Eq $s.move_id $id0 'move_id'; Eq $s.old.addr $OldAddr 'old.addr'; Eq $s.new.addr $NewAddr 'new.addr'; Eq $s.serving 'old' 'serving from the move-ids'
  Ok ($null -ne $s.dur -and @($s.dur.PSObject.Properties).Count -gt 0) 'dur{} rebuilt from the records'
  Ok ($null -ne $s.dur.'c.transfer.N' -and [int]$s.dur.'c.transfer.N'.new -eq 5) "dur c.transfer.N on new: $(ConvertTo-Json $s.dur -Compress)"
  Reset-World; Fx-Copied; [IO.File]::Delete((StatePath)); $W.new.MoveId.new_addr = '198.51.100.21'; $W.new.MoveId.old_addr = $OldAddr; $W.old.MoveId.new_addr = '198.51.100.21'; $W.old.MoveId.old_addr = $OldAddr
  [void](Run-Move @('status', '--rebuild', $OldAlias, $NewAlias)); Eq (Get-St).new.addr '198.51.100.21' 'new.addr comes from the move-id, never from ssh -G'
}
T 'L.pin-hostkey: the first contact pins new''s key under --addr in the move known_hosts (never ssh-keygen -F on the default file), later calls are strict, status prints the fingerprint, a changed key stops the move, abort and a new plan re-pin' {
  [void](Do-Plan)
  $kh = Join-Path (MoveDir) 'known_hosts'; Ok (Test-Path -LiteralPath $kh) 'move known_hosts'
  Ok (@([IO.File]::ReadAllLines($kh) | Where-Object { $_ -ceq "$NewAddr ssh-ed25519 $KeyNew" }).Count -eq 1) "new pinned under --addr: $([IO.File]::ReadAllText($kh))"
  Ok (-not (Test-Path -LiteralPath (Join-Path (Join-Path $Home2 '.ssh') 'known_hosts'))) 'the default known_hosts is never written'
  [void](Do-Copy)
  foreach ($c in @(Calls | Where-Object { $_.M -ceq 'new' })) { Eq "$($c.Opts['stricthostkeychecking'])".ToLowerInvariant() 'yes' "strict after the pin ($($c.Step))" }
  $r = Run-Move @('status'); Eq $r.Code 0 'status'; HasText (Get-Fp $KeyNew)
  $W.new.Key = New-EdKey 99; $r = Run-Move @('cutover'); Ok ($r.Code -ne 0) 'a changed key stops the move'; Eq (Sent 'old' '-x\.freeze$') 0 'nothing frozen'
  $W.new.Key = $KeyNew; Ans 'có'; [void](Run-Move @('abort'))
  $k2 = New-EdKey 123; $W.new.Key = $k2; $W.new.MoveId = $null; $W.old.MoveId.state = 'aborted'
  [void](Do-Plan); HasText (Get-Fp $k2)
  Ok (@([IO.File]::ReadAllLines($kh) | Where-Object { $_ -ceq "$NewAddr ssh-ed25519 $k2" }).Count -eq 1) 'the new plan re-pins --addr'
}

# ============================== step 10 and 11: chore 0 and the chores ==============================
function GhSets { @($W.GhLog | Where-Object { $_.Text -match $GhForm.SecretSet }) }
T 'L.known-hosts-line-format: DEPLOY_KNOWN_HOSTS becomes "<--addr> ssh-ed25519 <new key>"; old''s line is "<alias HostName before the swap> ssh-ed25519 <old key>", never --old-addr' {
  Use-Legacy; [void](Do-Plan @('--old-addr', '127.0.0.1:2222')); [void](Do-Copy); [void](Do-Cutover 0)
  $set = @(GhSets); Ok ($set.Count -ge 1 -and $set[-1].Text -match [regex]::Escape($LegacyRepo)) "gh secret set for $LegacyRepo"
  Eq "$($set[-1].Stdin)".Trim() "$NewAddr ssh-ed25519 $KeyNew" 'the new line (stdin)'
  Eq (Get-St).legacy_known_hosts.$LegacyRepo "$OldAddr ssh-ed25519 $KeyOld" 'old''s line kept in the state'
}
T 'L.back-known-hosts: a back after a cut sets DEPLOY_KNOWN_HOSTS to old''s stored line again' {
  Use-Legacy; Fx-Cut; Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "back ($($r.Text))"
  $set = @(GhSets); Ok ($set.Count -ge 1) 'gh secret set in the back'; Eq "$($set[-1].Stdin)".Trim() "$OldAddr ssh-ed25519 $KeyOld" 'old''s line'
}
T 'L.chore-gh-fail: a failing gh secret set ends exit 1 "chạy lại fcode move cutover" with chores pending; the re-run runs the pending chores only' {
  Use-Legacy; Fx-Copied; Add-Gh $GhForm.SecretSet @('HTTP 500') 1 1
  [void](Do-Cutover 1); HasText 'chạy lại fcode move cutover'; $s = Get-St; Eq $s.phase 'cut' 'phase'; Eq $s.chores_done $false 'chores pending'
  $r = Run-Move @('cutover'); Eq $r.Code 0 "re-run ($($r.Text))"; NoRecorded 'the pending-chores re-run'; Eq (Get-St).chores_done $true 'chores done'
  Eq @(GhSets).Count 2 'secret set tried again'
}
T 'L.alias-swap-fail: a laptop ssh config without the old alias block fails the chore (exit 1, chores pending, the alias named)' {
  Fx-Copied; [IO.File]::WriteAllText((Join-Path (Join-Path $Home2 '.ssh') 'config'), "Host $NewAlias`n  HostName $NewAddr`n", $utf8)
  [void](Do-Cutover 1); HasText $OldAlias; Eq (Get-St).chores_done $false 'chores pending'; Eq (Get-St).phase 'cut' 'phase'
}
T 'L.backups-recorded: the laptop alias backup (old''s HostName before the swap) is in state aliases.laptop_backup; the swap points the alias at new and a back restores it' {
  Fx-Cut; Eq "$((Get-St).aliases.laptop_backup)" $OldAddr 'aliases.laptop_backup'
  $h = Get-ConfigHosts (Get-LaptopConfig); Eq $h[$OldAlias] $NewAddr 'the old alias now reaches new'
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "back ($($r.Text))"
  $h = Get-ConfigHosts (Get-LaptopConfig); Eq $h[$OldAlias] $OldAddr 'the back points the alias at old again'
}
T 'L.backups-recorded: the laptop alias backup is saved in the state before the config write (a write that fails still leaves it recorded)' {
  Fx-Copied; $d = Join-Path $Home2 '.ssh'
  $W.Hooks['x.switch'] = { param($m, $e) & chmod 555 (Join-Path $Home2 '.ssh') }
  try { [void](Do-Cutover -1) } finally { & chmod 755 $d }
  Ok ($script:Last.Code -ne 0) 'the swap fails on the read-only ~/.ssh'; Eq "$((Get-St).aliases.laptop_backup)" $OldAddr 'backup recorded before the write'
} -NeedsBash
T 'L.backups-recorded-coder: the coder alias backup is in state aliases.coder_backup before the coder''s config is written; the coder alias then reaches new' {
  Fx-Cut; Eq "$((Get-St).aliases.coder_backup)" $OldAddr 'aliases.coder_backup'
  $w0 = @($W.BoxStates | Where-Object { $_ -and $_.phase -ceq 'cut' } | Select-Object -Last 1)
  Ok ($w0.Count -eq 1 -and "$($w0[0].aliases.coder_backup)" -ceq $OldAddr) 'the backup is saved before the coder write'
  $h = Get-ConfigHosts ([IO.File]::ReadAllText((Join-Path (Join-Path $CoderHome '.ssh') 'config'))); Eq $h[$OldAlias] $NewAddr 'the coder alias reaches new'
} -NeedsBash
T 'L.reach-old-after-swap: after the alias swap every call meant for old still reaches old (Reach-Old)' {
  Fx-Cut; Ans 'YES'; $r = Run-Move @('finish'); Eq $r.Code 0 "finish ($($r.Text))"
  Eq (Sent 'old' '-f\.old$') 1 'f.old reached old'; Eq (Sent 'new' '-f\.new$') 1 'f.new reached new'; Eq (Sent 'new' '-f\.old$') 0 'f.old never lands on new'
}
T 'L.list-failed-runs: step 11 lists the legacy runs that failed since step 2' {
  Use-Legacy; Fx-Copied; Add-Gh "$($GhForm.RunList)$([regex]::Escape($LegacyRepo))" @('[{"databaseId":4242,"displayTitle":"deploy main","createdAt":"2026-11-02T10:00:05Z"}]')
  [void](Do-Cutover 0); HasText '4242'
}
T 'L.list-failed-runs: after a reload, step 11 sends Q-cut.ts as --created in the record format (W1-T10R4-N1)' {
  Use-Legacy; Fx-Cut; $ts0 = St-Raw 'ts'; St-RawSet 'chores_done' 'false'; $n0 = $W.GhLog.Count; $r = Run-Move @('cutover')
  $b = @(@(for ($i = $n0; $i -lt $W.GhLog.Count; $i++) { if ($W.GhLog[$i].Text -match $GhForm.RunList) { $W.GhLog[$i] } }) | Select-Object -Last 1)
  Ok ($ts0 -match $TsRx -and $b.Count -eq 1 -and $b[0].Text -match ('--created >=' + [regex]::Escape($ts0) + '( |$)')) "step 11 since after a reload (exit $($r.Code); ts0 [$ts0]): $(if ($b.Count) { $b[0].Text })"
}
T 'L.chore-ufw-lockout: an adopt warning ufw-lockout is shown at copy and repeated in the step-11 list with the label; never a rollback' {
  Fx-Planned; Add-Fault -M new -Key '-c\.adopt\.1$' -Rc 0 -Out @('INV warn ufw-lockout addr=192.0.2.7'); [void](Do-Copy 0)
  HasText 'Tường lửa máy mới để tắt vì luật hiện tại sẽ khóa phiên ssh; cần bật lại bằng tay'
  Add-Fault -M new -Key '-x\.adopt$' -Rc 0 -Out @('INV warn ufw-lockout addr=192.0.2.7'); [void](Do-Cutover 0)
  $t = $script:Last.Text; $i = $t.LastIndexOf('Tường lửa máy mới để tắt'); Ok ($i -ge 0) 'label in the cutover'
  Ok (@($t.Substring($i) -split "`n")[0] -match '22' -or $t.Substring($i) -match 'ufw enable') 'detail: port 22 / ufw enable'
  Eq (Get-St).phase 'cut' 'no rollback'
}
T 'L.step10-fail-no-carry: chore 0 failing after the proof ends exit 1 with new serving (no carry-back); the next verb runs chore 0 first with a raised N' {
  Fx-Copied; Add-Fault -M new -Key '-x\.enable\.1$' -Rc 1
  [void](Do-Cutover 1); $s = Get-St; Eq $s.phase 'cut' 'phase'; Eq $s.serving 'new' 'serving'; Eq $s.enabled $false 'enabled'
  Eq (SentAny '-b\.init-') 0 'no carry-back'
  $r = Run-Move @('cutover'); Eq $r.Code 0 "re-run ($($r.Text))"
  Ok ((Sent 'new' '^fwd-1-x\.enable\.2$') -eq 1) 'x.enable.2 runs'; Eq (Get-St).enabled $true 'enabled after the repair'; Eq $W.new.Frozen $false 'new unfrozen'
}

# ============================== finish (D.7) ==============================
T 'L.finish-health: finish refuses (exit 1) when new is not healthy now (D.7: new''s status shows fewer active holds than the non-follower holds of the start set); no f.* call' {
  Fx-Cut; $W.new.Active = 1; Ans 'YES'; $r = Run-Move @('finish'); Eq $r.Code 1 'exit'; Eq (SentAny '-f\.(old|new)$') 0 'no finish call'
}
T 'L.finish-health: hold_active must equal the non-follower holds of hold_sets.start (D.7, D.10; W1-T10-G18, W1-T11-DG-T11-5) — a follower in the start set never blocks finish; one active hold more refuses' {
  $fx = {
    $W.Mf.holds = @($W.Mf.holds) + [ordered]@{ id = 'job.service'; kind = 'unit'; type = 'service'; unit_file_state = 'static'; active_state = 'inactive'; sub_state = 'dead'; remain_after_exit = 'no'; triggered_by = @('cron.service'); n_restarts = 0; stop_budget_s = 120; start_budget_s = 60; listen = @() }
    $W.Mf.followers = @('job.service'); $W.Mf.hold_sets.start = @($W.Mf.hold_sets.start) + 'job.service'; $W.Mf.hold_sets.stop = @($W.Mf.hold_sets.stop) + 'job.service'
    Fx-Cut
  }
  & $fx; Eq $W.new.Active $Holds 'new runs the three non-follower holds'
  Ans 'YES'; $r = Run-Move @('finish'); Eq $r.Code 0 "finish with a follower in the start set ($($r.Text))"; Eq (Get-St).phase 'finished' 'phase'
  Reset-World; & $fx; $W.new.Active = $Holds + 1
  Ans 'YES'; $r = Run-Move @('finish'); Eq $r.Code 1 "hold_active above the non-follower count ($($r.Text))"; Eq (SentAny '-f\.(old|new)$') 0 'no finish call'
}
T 'L.finish-chores-pending: finish refuses (exit 1) while a chore is pending' {
  Fx-Cut; [void](Patch-St @{ chores_done = $false }); Ans 'YES'; $r = Run-Move @('finish'); Eq $r.Code 1 'exit'; Eq (SentAny '-f\.(old|new)$') 0 'no finish call'
}
T 'L.finish-after-new-gate-release: a gate release on new during the watch does not stop finish (no gate compare)' {
  Fx-Cut; $W.new.Gate = $GateB; Ans 'YES'; $r = Run-Move @('finish'); Eq $r.Code 0 "finish ($($r.Text))"; Eq (Get-St).phase 'finished' 'phase'
}
T 'L.gate-id-compare: gate ids are compared at copy, at 0c and at back start, never at finish or abort' {
  Fx-Copied; $W.new.Gate = $GateB; [void](Do-Cutover 65); Eq (Sent 'old' '-x\.freeze$') 0 '0c compare'
  Reset-World; Fx-Copied; $W.new.Gate = $GateB; Ans 'có'; $r = Run-Move @('abort'); Eq $r.Code 0 'abort compares nothing'
  Reset-World; Fx-Cut; $W.new.Gate = $GateB; Ans 'YES'; $r = Run-Move @('finish'); Eq $r.Code 0 'finish compares nothing'
}
T 'L.gate-skew-after-copy: a gate release on old between copy and cutover ends 0c with 65 "chạy fcode move copy lại", nothing frozen' {
  Fx-Copied; $W.old.Gate = $GateB; [void](Do-Cutover 65); HasText 'chạy fcode move copy lại'; Eq (Sent 'old' '-x\.freeze$') 0 'nothing frozen'
}
T 'L.back-gate-refuse: back with differing gates refuses gate-version side=old with "cài cùng bản gate lên máy cũ", no init' {
  Fx-Cut; $W.old.Gate = $GateB; Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code 65 'exit'; HasText 'cài cùng bản gate lên máy cũ'; Eq (SentAny '-b\.init-') 0 'no b.init'
}

# ============================== back (D.8) and E-R19 ==============================
T 'L.back-same-code: a manual back runs the cutover steps with dir=back: src = new, dst = old, the transfer on new, chore 0 on old' {
  Fx-Cut; Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "back ($($r.Text))"
  Ok (@(Lines | Where-Object { $_ -match '\AChuyển ngược về máy cũ\. Những thứ này ở lại máy mới, không chạy trên máy cũ: .*\. Gõ YES để xác nhận\.\z' }).Count -ge 1) "Q-back text: $(Lines)"
  foreach ($p in @(@('new', 'x.freeze'), @('new', 'x.check'), @('old', 'x.repin'), @('new', 'x.stop-src'), @('old', 'x.stop-dst'), @('new', 'x.final'), @('old', 'x.verify'), @('new', 'x.verify'), @('old', 'x.prepare-id'), @('old', 'x.adopt'), @('old', 'x.start'), @('old', 'x.health'), @('old', 'x.switch'), @('old', (PassStep 'x.enable' 1)), @('old', (PassStep 'x.unfreeze' 1)))) {
    Ok ((Sent $p[0] ("^back-2-" + [regex]::Escape($p[1]) + '$')) -eq 1) "back-2-$($p[1]) on $($p[0])"
  }
  Eq (Sent 'old' '-x\.freeze$') 0 'no freeze on old in a back'
  $s = Get-St; Eq $s.phase 'back-done' 'phase'; Eq $s.serving 'old' 'serving'; Ok ($null -eq $s.mark) 'mark'; Eq $s.dir 'back' 'dir'
}
T 'L.back-same-code: step 3 re-pins both machines with x.repin under one id, in a fwd cutover and in a manual back (D.4 step 3; GAP-RULINGS-3 rev 1k3.3 "x.repin on both")' {
  Fx-Cut; Eq (Sent 'old' '^fwd-1-x\.repin$' -All) 1 'fwd x.repin on old'; Eq (Sent 'new' '^fwd-1-x\.repin$' -All) 1 'fwd x.repin on new'
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "back ($($r.Text))"
  Eq (Sent 'old' '^back-2-x\.repin$') 1 'back x.repin on old'; Eq (Sent 'new' '^back-2-x\.repin$') 1 'back x.repin on new'
}
T 'L.back-same-code: a manual back''s 0c plan <id> --check-only on new carries --dir back --attempt <state attempt + 1> (the write-ahead values); a fwd cutover''s carries the state''s fwd values (D.0.1, W1-T10-G16)' {
  $show = { param($cs) @($cs | ForEach-Object { "$($_.M) --dir $($_.Flags['dir']) --attempt $($_.Flags['attempt'])" }) -join ', ' }
  Fx-Copied; [void](Do-Cutover 0)
  $c = @(Calls | Where-Object { $_.Step -ceq 'plan:check-only' }); Ok ($c.Count -ge 1 -and $c[0].M -ceq 'old' -and $c[0].Flags['dir'] -ceq 'fwd' -and $c[0].Flags['attempt'] -ceq '1') "fwd 0c: $(& $show $c)"
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "back ($($r.Text))"
  $c = @(Calls | Where-Object { $_.Step -ceq 'plan:check-only' }); Ok ($c.Count -ge 1 -and $c[0].M -ceq 'new' -and $c[0].Flags['dir'] -ceq 'back' -and $c[0].Flags['attempt'] -ceq '2') "back 0c: $(& $show $c)"
}
T 'L.back-init-crash: the back write-ahead (dir=back, attempt+1, phase=planned, carry=false) is in state.json before b.init-*; a crash after it re-runs both inits' {
  Fx-Cut; $script:Seen = $null; $W.Hooks['b.init-new'] = { param($m, $e) if (-not $script:Seen) { $script:Seen = Get-St } }
  Add-Fault -M new -Key '^back-2-b\.init-new$' -Mode down
  Ans 'YES'; $r = Run-Move @('back'); Ok ($r.Code -ne 0) 'the back stops when new drops'
  Eq $script:Seen.dir 'back' 'dir ahead'; Eq $script:Seen.attempt 2 'attempt ahead'; Eq $script:Seen.phase 'planned' 'phase ahead'; Eq $script:Seen.carry $false 'carry ahead'
  $W.new.Up = $true; Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "resume ($($r.Text))"
  Ok ((Sent 'new' '^back-2-b\.init-new$') -eq 1 -and (Sent 'old' '^back-2-b\.init-old$') -eq 1) 'both inits re-run'; Eq (Get-St).phase 'back-done' 'phase'
}
T 'L.back-rollback-to-cut: in a manual back a failure before x.start on old restarts new and ends dir=back, attempt n+1, phase=cut, serving=new, mark=null' {
  Fx-Cut; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1
  Ans 'YES'; $r = Run-Move @('back'); Ok ($r.Code -ne 0) 'not a success'
  Ok ((Sent 'new' '^back-2-r\.start-src$') -eq 1 -and (Sent 'new' '^back-2-r\.unfreeze-src$') -eq 1) 'new restarted and unfrozen'
  $s = Get-St; Eq $s.dir 'back' 'dir'; Eq $s.attempt 2 'attempt'; Eq $s.phase 'cut' 'phase'; Eq $s.serving 'new' 'serving'; Ok ($null -eq $s.mark) 'mark'
  Eq $W.new.Active $Holds 'new serves'; Eq $W.new.Frozen $false 'new unfrozen'
}
T 'L.e-r19-finish: after E-R19 finish runs (chores were done) and abort is refused' {
  Fx-Cut; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1; Ans 'YES'; [void](Run-Move @('back'))
  $r = Run-Move @('abort'); Eq $r.Code 1 'abort refused'; NoRecorded 'abort refusal'
  Ans 'YES'; $r = Run-Move @('finish'); Eq $r.Code 0 "finish ($($r.Text))"; Eq (Get-St).phase 'finished' 'phase'
}
T 'L.finish-text-back: the finish texts name the machines from dir and serving (after E-R19 the machine left is still old)' {
  Fx-Cut; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1; Ans 'YES'; [void](Run-Move @('back'))
  Ans 'YES'; $r = Run-Move @('finish'); Eq $r.Code 0 'finish'
  Ok (@(Lines | Where-Object { $_ -ceq 'Kết thúc chuyển máy: sau bước này không quay lại máy cũ được nữa. Gõ YES để xác nhận.' }).Count -ge 1) "Q-finish text: $(Lines)"
  HasText $OldAlias; Eq (Sent 'old' '-f\.old$') 1 'old finished as old'
}
T 'L.new-lost-not-in-back: old unreachable during a back ends exit 70, resume only, no Q-newlost and no new_lost' {
  Fx-Cut; Add-Fault -M old -Key '^back-2-x\.start$' -Mode down
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code 70 'exit'
  Ok (@(Lines | Where-Object { $_ -match 'Máy mới không trả lời\. Trước khi trả lời' }).Count -eq 0) 'no Q-newlost'; Ok ((Get-St).new_lost -ne $true) 'new_lost'
}

# ============================== carry-back (D.5.2) and new lost (D.5.3) ==============================
T 'L.carry-after-start: a failure after x.start carries dst''s data back with no question: b.init, freeze and stop on new, x.final, start on old, back-done, exit 10' {
  Start-Carry; [void](Do-Cutover 10)
  Ordered @('^new back-2-b\.init-new$', '^old back-2-b\.init-old$', '^new back-2-x\.freeze$', '^new back-2-x\.stop-src$', '^old back-2-x\.stop-dst$', '^new back-2-x\.final$', '^old back-2-x\.start$', '^old back-2-x\.switch$', '^old back-2-x\.enable\.1$')
  Eq (SentAny '^back-2-x\.check$') 0 'no step 3 in a carry-back'
  Ok (@(Lines | Where-Object { $_ -match 'Gõ YES' }).Count -eq 0) 'no discard question'
  $s = Get-St; Eq $s.phase 'back-done' 'phase'; Eq $s.serving 'old' 'serving'; Ok ($null -eq $s.mark) 'mark'; Eq $s.carry $false 'carry cleared'
  Ok (@($W.StateSeen | Where-Object { $_.carry -eq $true -and $_.phase -ceq 'cut' }).Count -eq 0) 'a carry-back never writes cut'
}
T 'L.carry-init-crash: the carry-back write-ahead (dir=back, attempt+1, planned, carry=true, fwd mark kept) is in state.json before b.init-new' {
  Start-Carry; $script:Seen = $null; $W.Hooks['b.init-new'] = { param($m, $e) if (-not $script:Seen) { $script:Seen = Get-St } }
  [void](Do-Cutover 10)
  Eq $script:Seen.dir 'back' 'dir'; Eq $script:Seen.attempt 2 'attempt'; Eq $script:Seen.phase 'planned' 'phase'; Eq $script:Seen.carry $true 'carry'; Eq $script:Seen.mark 'cutting' 'fwd mark kept'
}
T 'L.carry-init-old-passes: the carry-back''s b.init-old carries the fwd mark, so init-serving does not refuse it and the carry-back reaches x.final' {
  Start-Carry; [void](Do-Cutover 10)
  $bi = @(RecCalls | Where-Object { $_.Call -ceq 'back-2-b.init-old' })[0]; Ok ($null -ne $bi) 'b.init-old sent'; Ok ($bi.Flags['mark'] -in 'cutting', 'switching') "b.init-old --mark $($bi.Flags['mark'])"
  Eq (@(LogNow | Where-Object { $_ -match 'init-serving' }).Count) 0 'no init-serving refusal'; Eq (Sent 'new' '^back-2-x\.final$') 1 'x.final reached'
}
T 'L.carry-fail: a carry-back failure before x.final offers Q-discard (no answer: exit 70); after x.final started: exit 70, resume only' {
  Start-Carry; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1; Ans 'có'
  $r = Run-Move @('cutover'); Eq $r.Code 70 'exit'
  Ok (@(Lines | Where-Object { $_ -match '\AChép ngược tự động bị lỗi trước khi chép dữ liệu\. Chạy lại máy cũ với dữ liệu của nó\? Mọi thay đổi trên máy mới từ .* sẽ mất\. Gõ YES để xác nhận\.\z' }).Count -ge 1) "Q-discard text: $(Lines)"
  Reset-World; Start-Carry; Add-Fault -M new -Key '^back-2-x\.final$' -Rc 1; Ans 'có'
  $r = Run-Move @('cutover'); Eq $r.Code 70 'exit after x.final'; HasText 'dữ liệu máy cũ đang dở; chỉ tiếp tục được khi máy mới nối lại'
  Ok (@(Lines -Last | Where-Object { $_ -match 'Gõ YES' }).Count -eq 0) 'no Q-discard after x.final'
}
T 'L.carry-after-final-70: a carry-back failing after x.final started ends exit 70 with both status, never starts old' {
  Start-Carry; Add-Fault -M new -Key '^back-2-x\.final$' -Rc 1 -Mode noexit; Ans 'có'
  $r = Run-Move @('cutover'); Eq $r.Code 70 'exit'; Eq (SentAny '-r\.start-src$') 0 'old not started'; HasText 'dữ liệu máy cũ đang dở; chỉ tiếp tục được khi máy mới nối lại'
  $l = LogNow; $i = [Array]::IndexOf($l, 'new back-2-x.final'); $after = @($l[($i + 1)..($l.Count - 1)])
  Ok ((@($after | Where-Object { $_ -ceq 'old status' }).Count -ge 1) -and (@($after | Where-Object { $_ -ceq 'new status' }).Count -ge 1)) "both status answers read: $($after -join ' ; ')"
}
T 'L.carry-after-final-70: new unreachable after the carry-back''s x.final (at x.verify): exit 70, no YES question, old never started, also on the next cutover with new still down' {
  Start-Carry; Add-Fault -M new -Key '^back-2-x\.verify$' -Mode down; Ans 'có', 'YES', 'YES'
  $r = Run-Move @('cutover'); Eq $r.Code 70 "exit ($($r.Text))"; HasText 'dữ liệu máy cũ đang dở; chỉ tiếp tục được khi máy mới nối lại'
  Ok (@(Lines | Where-Object { $_ -match 'Gõ YES' }).Count -eq 0) "no YES question: $(Lines)"
  Eq (SentAny '-r\.start-src$') 0 'old not started'; Ok ((Get-St).new_lost -ne $true) 'no new_lost'
  $r = Run-Move @('cutover'); Ok ($r.Code -ne 10) "next cutover, new down: exit $($r.Code)"
  Eq (SentAny '-r\.start-src$' -All) 0 'old never started'; Ok ((Get-St).new_lost -ne $true) 'no new_lost'
}
T 'L.carry-resume: after a carry-back stopped before x.final, cutover resumes it to back-done (exit 10); phase cut is never written' {
  Start-Carry; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1; Ans 'có'; [void](Run-Move @('cutover'))
  $r = Run-Move @('cutover'); Eq $r.Code 10 "resume ($($r.Text))"; Eq (Get-St).phase 'back-done' 'phase'
  Ok (@($W.StateSeen | Where-Object { $_.dir -ceq 'back' -and $_.phase -ceq 'cut' }).Count -eq 0) 'no cut in a carry-back'
}
T 'L.carry-resume-no-chore0: resuming a carry-back (mark set) never runs the chore-0 pre-rule before the switch' {
  Start-Carry; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1; Ans 'có'; [void](Run-Move @('cutover'))
  $r = Run-Move @('cutover'); Eq $r.Code 10 'resume'
  Before '^old back-2-x\.switch$' '^old back-2-x\.enable\.'; Eq (Sent 'new' '-x\.(enable|unfreeze)\.') 0 'no chore 0 on new'
}
T 'L.carry-discard-yes: carry-back failure before x.final with new cleanly stopped: Q-discard YES starts old with its own data, exit 10, new_discarded' {
  Start-Carry; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1; Ans 'có', 'YES'
  $r = Run-Move @('cutover'); Eq $r.Code 10 "exit ($($r.Text))"
  Ordered @('^old back-2-r\.start-src$', '^old back-2-r\.unfreeze-src$', '^old back-2-r\.health-src$')
  $s = Get-St; Eq $s.phase 'rolled-back' 'phase'; Eq $s.serving 'old' 'serving'; Ok ($null -eq $s.mark) 'mark'; Eq $s.carry $false 'carry'; Eq $s.enabled $true 'enabled'; Eq $s.new_discarded $true 'new_discarded'
}
T 'L.no-discard-without-yes: anything but the typed YES discards nothing (exit 70, old not started)' {
  foreach ($a in 'yes', 'có', 'Yes', '') { Reset-World; Start-Carry; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1; Ans 'có', $a; $r = Run-Move @('cutover'); Eq $r.Code 70 "[$a] exit"; Eq (SentAny '-r\.start-src$') 0 "[$a] old not started" }
}
T 'L.carry-discard-new-unreachable-needs-poweroff: new unreachable in a carry-back before x.final: Q-discard carries the power-off text; YES sets new_lost' {
  Start-Carry; Add-Fault -M new -Key '^back-2-x\.stop-src$' -Mode down; Ans 'có', 'YES'
  $r = Run-Move @('cutover'); Eq $r.Code 10 "exit ($($r.Text))"
  Ok (@(Lines | Where-Object { $_ -match '\AMáy mới không trả lời\. Trước khi trả lời, hãy tắt hoặc cài lại máy mới trong trang quản lý nhà cung cấp\. Mọi thay đổi trên máy mới sau .* sẽ mất\. Gõ YES để chạy lại máy cũ\.\z' }).Count -ge 1) "power-off text: $(Lines)"
  Eq (Get-St).new_lost $true 'new_lost'
}
T 'L.carry-discard-stop-partial: new''s stop not clean in a carry-back: Q-discard is the power-off form only' {
  Start-Carry; Add-Fault -M new -Key '^back-2-x\.stop-src$' -Rc 1; Ans 'có'
  [void](Run-Move @('cutover'))
  Ok (@(Lines | Where-Object { $_ -match 'hãy tắt hoặc cài lại máy mới' }).Count -ge 1) "power-off form: $(Lines)"
  Ok (@(Lines | Where-Object { $_ -match 'Chạy lại máy cũ với dữ liệu của nó' }).Count -eq 0) 'never the clean form'
}
T 'L.new-lost: new unreachable after dst_started: exit 70 and nothing automatic; Q-newlost YES starts old (exit 10, new_lost)' {
  Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Mode down
  [void](Do-Cutover 70); Eq (SentAny '-(r\.|b\.init)') 0 'nothing automatic'
  Ans 'YES'; $r = Run-Move @('cutover'); Eq $r.Code 10 "Q-newlost ($($r.Text))"
  Ordered @('^old fwd-1-r\.start-src$', '^old fwd-1-r\.unfreeze-src$', '^old fwd-1-r\.health-src$')
  $s = Get-St; Eq $s.new_lost $true 'new_lost'; Eq $s.phase 'rolled-back' 'phase'; Eq $s.serving 'old' 'serving'; Eq $s.carry $false 'carry'
}
T 'L.new-lost-fence-text: Q-newlost asks to power off or reinstall new first and names <giờ> (D.5.3)' {
  Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Mode down; [void](Do-Cutover 70)
  Ans 'không'; $r = Run-Move @('cutover'); Ok ($r.Code -ne 10) 'no YES, no discard'; Eq (SentAny '-r\.start-src$') 0 'old not started'
  Ok (@(Lines | Where-Object { $_ -match '\AMáy mới không trả lời\. Trước khi trả lời, hãy tắt hoặc cài lại máy mới trong trang quản lý nhà cung cấp\. Mọi thay đổi trên máy mới sau .*[0-9].* sẽ mất\. Gõ YES để chạy lại máy cũ\.\z' }).Count -ge 1) "Q-newlost text: $(Lines)"
}

# ============================== resume by real state (D.11, E-R16, E-R17, E-R33) ==============================
T 'L.resume-old-reboot: old rebooted between steps 2 and 5 (holds started at boot, marker kept): the resume''s x.stop-src stops them' {
  Fx-Cutting0; $W.old.Rec.Remove('fwd-1-x.stop-src'); $W.new.Rec.Remove('fwd-1-x.stop-dst'); $W.old.Last = 'fwd-1-x.guards'; $W.old.Active = $Holds; $W.old.Enabled = $true
  $r = Run-Move @('cutover'); Eq $r.Code 0 "resume ($($r.Text))"; Eq (Sent 'old' '^fwd-1-x\.stop-src$') 1 'x.stop-src runs'; Eq $W.old.Active 0 'old stopped'; Eq (Get-St).phase 'cut' 'phase'
}
T 'L.resume-old-reboot-after-stop: old rebooted after step 5 (holds disabled, nothing starts): the resume goes on with x.final' {
  Fx-Cutting0
  $r = Run-Move @('cutover'); Eq $r.Code 0 "resume ($($r.Text))"; Eq (Sent 'old' '^fwd-1-x\.stop-src$') 0 'no second stop'; Eq (Sent 'new' '^fwd-1-x\.final$') 1 'x.final'; Eq (Get-St).phase 'cut' 'phase'
}
T 'L.resume-mid-cutover-no-chore0: resuming a cutover (mark set) while old holds its marker never runs chore 0 on old' {
  Fx-Cutting0; $r = Run-Move @('cutover'); Eq $r.Code 0 'resume'; Eq (Sent 'old' '-x\.(enable|unfreeze)\.') 0 'no chore 0 on old'
}
T 'L.status-no-init: status and check never run the agreement check: no init or other recorded call even when the machines disagree' {
  Fx-RolledBack; [void](Patch-St @{ attempt = 2 })   # the write-ahead of a new attempt, then a crash: both machines still hold attempt 1
  $r = Run-Move @('status'); Eq $r.Code 0 'status'; Eq @(RecCalls).Count 0 "status sends no recorded call: $(@(RecCalls | ForEach-Object { $_.M + ' ' + $_.Call }) -join ', ')"
  $r = Run-Move @('check'); Eq @(RecCalls).Count 0 'check sends no recorded call'
}

# ============================== abort (D.9) ==============================
T 'L.abort-text: Q-abort carries the D.9 text and the excluded transient units; có runs a.old then a.new (phase aborted); không writes nothing' {
  $W.PlanOut = @('INV warn transient-excluded unit=velh-x.service', 'INV ok'); Fx-Copied
  Ans 'không'; $r = Run-Move @('abort'); Eq $r.Code 0 'không'; NoRecorded 'Q-abort không'; Eq (Get-St).phase 'copied' 'phase kept'
  Ans 'có'; $r = Run-Move @('abort'); Eq $r.Code 0 "có ($($r.Text))"
  HasText 'máy mới đang giữ bản sao của mọi dữ liệu và bí mật; xóa hoặc cài lại máy mới trước khi plan lại'; HasText 'velh-x.service'
  Ordered @('^old fwd-1-a\.old$', '^new fwd-1-a\.new$'); Eq (Get-St).phase 'aborted' 'phase'; Eq $W.old.MoveId.state 'aborted' 'old aborted'
}
T 'L.abort-new-unreachable: abort with new unreachable aborts old and skips new (best effort), phase aborted' {
  Fx-Copied; $W.new.Up = $false; Ans 'có'; $r = Run-Move @('abort'); Eq $r.Code 0 "exit ($($r.Text))"; Eq (Sent 'old' '-a\.old$') 1 'a.old'; Eq (Get-St).phase 'aborted' 'phase'
}
T 'L.back-done-abort-runs-chore0: abort in back-done with enabled=false runs chore 0 on old first, then a.old' {
  Fx-BackDone; [void](Patch-St @{ enabled = $false }); $W.old.Enabled = $false; $W.old.Frozen = $true
  Ans 'có'; $r = Run-Move @('abort'); Eq $r.Code 0 "abort ($($r.Text))"
  Ordered @('^old back-2-x\.enable\.[0-9]+$', '^old back-2-x\.unfreeze\.[0-9]+$', '^old back-2-a\.old$')
}
T 'L.retry-after-back-done: a carry-back ends with carry=false, so copy starts the next forward attempt (attempt+1, dir=fwd) and abort runs' {
  Start-Carry; [void](Do-Cutover 10); Eq (Get-St).carry $false 'carry cleared at back-done'
  [void](Do-Copy 0); $s = Get-St; Eq $s.dir 'fwd' 'dir'; Eq $s.attempt 3 'attempt'; Eq $s.phase 'copied' 'phase'
  Ok ((Sent 'old' '^fwd-3-c\.init-old$') -eq 1) 'c.init-old of attempt 3'; Eq (@(LogNow | Where-Object { $_ -match 'script:preflight' }).Count) 0 'no B.0.3 preflight'
  Eq (@(LogNow | Where-Object { $_ -match '^old plan:full$' }).Count) 0 "attempt 3's first copy is no re-run (status showed the move-id at the earlier attempt; ruling NEW-2 (dir, attempt)): $((LogNow) -join ' ; ')"; Eq (SentAny '-c\.repin\.') 0 'no c.repin.N'
  Reset-World; Start-Carry; [void](Do-Cutover 10); Ans 'có'; $r = Run-Move @('abort'); Eq $r.Code 0 "abort after the carry-back ($($r.Text))"; Eq (Get-St).phase 'aborted' 'phase'
}

# ============================== L.resume-table: every D.11 cell ==============================
function Cell([string]$Name, [scriptblock]$Setup, [string]$Verb, [string[]]$A, $Expect) {
  $script:CellArgs = @{ Setup = $Setup; Verb = $Verb; A = $A; Expect = $Expect }
  T $Name {
    $c = $script:CellArgs
    & $c.Setup
    if ($c.A) { Ans $c.A }
    $r = Run-Move @($c.Verb)
    if ($c.Expect -is [string]) {
      Eq $r.Code 1 "refused with exit 1 ($($r.Text))"; NoRecorded "the refusal of $($c.Verb)"
      $t = $c.Expect -replace '^refuse:?', ''; if ($t) { HasText $t }
    } else { & $c.Expect $r }
  }
}
function Want([int]$Code, [string]$Phase) { Eq $script:Last.Code $Code "exit ($($script:Last.Text))"; if ($Phase) { Eq (Get-St).phase $Phase 'phase' } }
$runCopy = { Want 0 'copied'; Ok ((Sent 'new' '-c\.init-new$') -eq 1) 'c.init-new'; NoChore0 }
$runAbort = { Want 0 'aborted'; Eq (Sent 'old' '-a\.old$') 1 'a.old' }
$runNewAttempt = { Want 0 'copied'; $s = Get-St; Eq $s.dir 'fwd' 'dir'; Ok ((Sent 'old' "^fwd-$($s.attempt)-c\.init-old$") -eq 1) 'c.init-old of the new attempt'; Eq (@(LogNow | Where-Object { $_ -match 'script:preflight' }).Count) 0 'no B.0.3' }
$backDone0 = { Want $BackDoneExit 'back-done'; Eq (Get-St).serving 'old' 'serving' }

Cell 'L.resume-table: fwd planned, copy: run' { Fx-Planned } 'copy' @() $runCopy
Cell 'L.resume-table: fwd planned, cutover: refuse' { Fx-Planned } 'cutover' @() 'refuse:chạy copy trước'
Cell 'L.resume-table: fwd planned, back: refuse' { Fx-Planned } 'back' @() 'refuse:máy cũ đang chạy'
Cell 'L.resume-table: fwd planned, finish: refuse' { Fx-Planned } 'finish' @() 'refuse'
Cell 'L.resume-table: fwd planned, abort: run' { Fx-Planned } 'abort' @('có') { Want 0 'aborted' }
Cell 'L.resume-table: fwd copied, copy: refresh' { Fx-Copied } 'copy' @() { Want 0 'copied'; Ok ((Sent 'old' '-c\.repin\.1$') -eq 1) 'c.repin on old'; Ok ((Sent 'new' '-c\.transfer\.2$') -eq 1) 'c.transfer.2' }
Cell 'L.resume-table: fwd copied, cutover: run' { Fx-Copied } 'cutover' @('có') { Want 0 'cut'; Eq (Get-St).serving 'new' 'serving' }
Cell 'L.resume-table: fwd copied, back: refuse' { Fx-Copied } 'back' @() 'refuse'
Cell 'L.resume-table: fwd copied, finish: refuse' { Fx-Copied } 'finish' @() 'refuse'
Cell 'L.resume-table: fwd copied, abort: run' { Fx-Copied } 'abort' @('có') $runAbort
Cell 'L.resume-table: fwd cutting dst_started=false, copy: refuse' { Fx-Cutting0 } 'copy' @() 'refuse'
Cell 'L.resume-table: fwd cutting dst_started=false, cutover: resume by real state' { Fx-Cutting0 } 'cutover' @() { Want 0 'cut'; Eq (Sent 'new' '^fwd-1-x\.final$') 1 'x.final'; Eq (Sent 'old' '^fwd-1-x\.freeze$') 0 'no new freeze' }
Cell 'L.resume-table: fwd cutting dst_started=false, back: refuse' { Fx-Cutting0 } 'back' @() 'refuse'
Cell 'L.resume-table: fwd cutting dst_started=false, finish: refuse' { Fx-Cutting0 } 'finish' @() 'refuse'
Cell 'L.resume-table: fwd cutting dst_started=false, abort: refuse' { Fx-Cutting0 } 'abort' @() 'refuse'
Cell 'L.resume-table: fwd cutting dst_started=false, cutover after a definite earlier failure: plain rollback' { Fx-Cutting0; Add-Rec 'new' 'fwd-1-x.final' 1 } 'cutover' @() { Want 10 'rolled-back'; Eq (SentAny '-x\.start$') 0 'no start' }
Cell 'L.resume-table: fwd cutting dst_started=false, cutover: a running final transfer is re-attached' { Fx-Cutting0; Set-Running 'new' 'fwd-1-x.final' } 'cutover' @() { Want 0 'cut'; Ok (@(LogNow | Where-Object { $_ -ceq 'new fwd-1-x.final attach' }).Count -eq 1) "re-attached: $(LogNow)"; Eq (Sent 'new' '^fwd-1-x\.final$') 0 'no second x.final run' }
Cell 'L.resume-table: fwd cutting dst_started=true, copy: refuse' { Fx-CuttingStarted } 'copy' @() 'refuse'
Cell 'L.resume-table: fwd cutting dst_started=true, cutover: resume step 8' { Fx-CuttingStarted } 'cutover' @() { Want 0 'cut'; Eq (Sent 'new' '^fwd-1-x\.start$') 1 'x.start'; Eq (Sent 'new' '^fwd-1-x\.final$') 0 'no second final' }
Cell 'L.resume-table: fwd cutting dst_started=true, cutover failing at health: carry-back' { Fx-CuttingStarted; Add-Fault -M new -Key '^fwd-1-x\.health$' -Rc 69 } 'cutover' @() { Want 10 'back-done' }
Cell 'L.resume-table: fwd cutting dst_started=true, back: refuse' { Fx-CuttingStarted } 'back' @() 'refuse:cutover sẽ tự chép ngược'
Cell 'L.resume-table: fwd cutting dst_started=true, finish: refuse' { Fx-CuttingStarted } 'finish' @() 'refuse'
Cell 'L.resume-table: fwd cutting dst_started=true, abort: refuse' { Fx-CuttingStarted } 'abort' @() 'refuse'
Cell 'L.resume-table: fwd switching, copy: refuse' { Fx-Switching } 'copy' @() 'refuse'
Cell 'L.resume-table: fwd switching, cutover: resume steps 9–11' { Fx-Switching } 'cutover' @() { Want 0 'cut'; Eq (Sent 'new' '^fwd-1-x\.switch$') 1 'x.switch'; Eq (Sent 'new' '^fwd-1-x\.start$') 0 'no second start' }
Cell 'L.resume-table: fwd switching, cutover with a definite switch failure: carry-back' { Fx-Switching; Add-Fault -M new -Key '^fwd-1-x\.switch$' -Rc 1 } 'cutover' @() { Want 10 'back-done' }
Cell 'L.resume-table: fwd switching, back: refuse' { Fx-Switching } 'back' @() 'refuse:cutover sẽ tự chép ngược'
Cell 'L.resume-table: fwd switching, finish: refuse' { Fx-Switching } 'finish' @() 'refuse'
Cell 'L.resume-table: fwd switching, abort: refuse' { Fx-Switching } 'abort' @() 'refuse'
Cell 'L.resume-table: fwd rolling-back, copy: refuse' { Fx-RollingBack } 'copy' @() 'refuse'
Cell 'L.resume-table: fwd rolling-back, cutover: continue the plain rollback' { Fx-RollingBack } 'cutover' @() { Want 10 'rolled-back'; Eq (Sent 'old' '^fwd-1-r\.start-src$') 1 'r.start-src' }
Cell 'L.resume-table: fwd rolling-back, back: refuse' { Fx-RollingBack } 'back' @() 'refuse'
Cell 'L.resume-table: fwd rolling-back, finish: refuse' { Fx-RollingBack } 'finish' @() 'refuse'
Cell 'L.resume-table: fwd rolling-back, abort: refuse' { Fx-RollingBack } 'abort' @() 'refuse'
Cell 'L.resume-table: fwd cut, copy: refuse' { Fx-Cut } 'copy' @() 'refuse'
Cell 'L.resume-table: fwd cut, cutover: pending chores only' { Fx-Cut; [void](Patch-St @{ chores_done = $false }) } 'cutover' @() { Want 0 'cut'; NoRecorded 'pending chores'; Eq (Get-St).chores_done $true 'chores done' }
Cell 'L.resume-table: fwd cut, back: run' { Fx-Cut } 'back' @('YES') $backDone0
Cell 'L.resume-table: fwd cut, finish: run when chores_done' { Fx-Cut } 'finish' @('YES') { Want 0 'finished'; Eq (Sent 'old' '-f\.old$') 1 'f.old'; Eq (Sent 'new' '-f\.new$') 1 'f.new' }
Cell 'L.resume-table: fwd cut, abort: refuse' { Fx-Cut } 'abort' @() 'refuse'
Cell 'L.resume-table: fwd rolled-back, copy: run a new attempt' { Fx-RolledBack } 'copy' @() { & $runNewAttempt; Eq (Get-St).attempt 2 'attempt' }
Cell 'L.resume-table: fwd rolled-back, cutover: refuse' { Fx-RolledBack } 'cutover' @() 'refuse:chạy copy trước'
Cell 'L.resume-table: fwd rolled-back, back: refuse' { Fx-RolledBack } 'back' @() 'refuse'
Cell 'L.resume-table: fwd rolled-back, finish: refuse' { Fx-RolledBack } 'finish' @() 'refuse'
Cell 'L.resume-table: fwd rolled-back, abort: run' { Fx-RolledBack } 'abort' @('có') $runAbort
Cell 'L.resume-table: back planned carry=true (carry case), copy: refuse' { Fx-Carry } 'copy' @() 'refuse'
Cell 'L.resume-table: back planned carry=true (carry case), cutover: resume the carry-back' { Fx-Carry } 'cutover' @() { Want 10 'back-done'; Eq (Get-St).carry $false 'carry'; Eq (Sent 'new' '^back-2-x\.final$') 1 'x.final' }
Cell 'L.resume-table: back planned carry=true (carry case), back: refuse' { Fx-Carry } 'back' @() 'refuse:đang chép ngược tự động'
Cell 'L.resume-table: back planned carry=true (carry case), finish: refuse' { Fx-Carry } 'finish' @() 'refuse'
Cell 'L.resume-table: back planned carry=true (carry case), abort: refuse' { Fx-Carry } 'abort' @() 'refuse'
Cell 'L.resume-table: back planned carry=false, copy: run (pre-copy new→old)' { Fx-BackAt 'planned' } 'copy' @() { Want 0 ''; Ok ((Sent 'new' '^back-2-c\.transfer\.') -ge 1) 'back pre-copy on new' }
Cell 'L.resume-table: back planned carry=false, cutover: run the back cutover' { Fx-BackAt 'planned' } 'cutover' @() $backDone0
Cell 'L.resume-table: back planned carry=false, back: resume the back' { Fx-BackAt 'planned' } 'back' @() $backDone0
Cell 'L.resume-table: back planned carry=false, finish: refuse' { Fx-BackAt 'planned' } 'finish' @() 'refuse'
Cell 'L.resume-table: back planned carry=false, abort: refuse' { Fx-BackAt 'planned' } 'abort' @() 'refuse'
Cell 'L.resume-table: back copied carry=false, copy: run' { Fx-BackAt 'copied' } 'copy' @() { Want 0 ''; Ok ((Sent 'new' '^back-2-c\.transfer\.') -ge 1) 'back pre-copy on new' }
Cell 'L.resume-table: back copied carry=false, cutover: run' { Fx-BackAt 'copied' } 'cutover' @() $backDone0
Cell 'L.resume-table: back copied carry=false, back: resume' { Fx-BackAt 'copied' } 'back' @() $backDone0
Cell 'L.resume-table: back copied carry=false, finish: refuse' { Fx-BackAt 'copied' } 'finish' @() 'refuse'
Cell 'L.resume-table: back copied carry=false, abort: refuse' { Fx-BackAt 'copied' } 'abort' @() 'refuse'
Cell 'L.resume-table: back cutting carry=false, copy: refuse' { Fx-BackAt 'copied' 'cutting' } 'copy' @() 'refuse'
Cell 'L.resume-table: back cutting carry=false, cutover: resume the back cutover' { Fx-BackAt 'copied' 'cutting' } 'cutover' @() { & $backDone0; Eq (Sent 'new' '^back-2-x\.freeze$') 0 'no second freeze' }
Cell 'L.resume-table: back cutting carry=false, back: resume' { Fx-BackAt 'copied' 'cutting' } 'back' @() $backDone0
Cell 'L.resume-table: back cutting carry=false, finish: refuse' { Fx-BackAt 'copied' 'cutting' } 'finish' @() 'refuse'
Cell 'L.resume-table: back cutting carry=false, abort: refuse' { Fx-BackAt 'copied' 'cutting' } 'abort' @() 'refuse'
Cell 'L.resume-table: back switching carry=false, cutover: resume (x.switch on old again, no second x.start)' { Fx-BackSwitching } 'cutover' @() { & $backDone0; Eq (Sent 'old' '^back-2-x\.switch$') 1 'x.switch'; Eq (Sent 'old' '^back-2-x\.start$') 0 'no second start' }
Cell 'L.resume-table: back switching carry=false, back: resume' { Fx-BackSwitching } 'back' @() { & $backDone0; Eq (Sent 'old' '^back-2-x\.switch$') 1 'x.switch'; Eq (Sent 'old' '^back-2-x\.start$') 0 'no second start' }
Cell 'L.resume-table: back rolling-back carry=false, cutover: continue E-R19 (new restarted, cut, serving new)' { Fx-BackRollingBack } 'cutover' @() { $s = Get-St; Eq $s.phase 'cut' 'phase'; Eq $s.serving 'new' 'serving'; Ok ($null -eq $s.mark) 'mark'; Ok ((Sent 'new' '^back-2-r\.start-src$') -ge 1) 'new r.start-src'; Ok ((Sent 'new' '^back-2-r\.unfreeze-src$') -ge 1) 'new r.unfreeze-src'; Eq $W.new.Frozen $false 'new unfrozen'; Eq $W.new.Active $Holds 'new serves' }
Cell 'L.resume-table: back rolling-back carry=false, back: continue E-R19' { Fx-BackRollingBack } 'back' @() { $s = Get-St; Eq $s.phase 'cut' 'phase'; Eq $s.serving 'new' 'serving'; Ok ($null -eq $s.mark) 'mark'; Ok ((Sent 'new' '^back-2-r\.start-src$') -ge 1) 'new r.start-src'; Ok ((Sent 'new' '^back-2-r\.unfreeze-src$') -ge 1) 'new r.unfreeze-src'; Eq $W.new.Frozen $false 'new unfrozen'; Eq $W.new.Active $Holds 'new serves' }
Cell 'L.resume-table: back cut (= fwd cut), copy: refuse' { Fx-BackAt 'cut' } 'copy' @() 'refuse'
Cell 'L.resume-table: back cut (= fwd cut), cutover: pending chores only' { Fx-BackAt 'cut'; [void](Patch-St @{ chores_done = $false }) } 'cutover' @() { Want 0 'cut'; NoRecorded 'pending chores' }
Cell 'L.resume-table: back cut (= fwd cut), back: run again (attempt raised)' { Fx-BackAt 'cut' } 'back' @('YES') { & $backDone0; Eq (Get-St).attempt 3 'attempt' }
Cell 'L.resume-table: back cut (= fwd cut), finish: run when chores_done' { Fx-BackAt 'cut' } 'finish' @('YES') { Want 0 'finished' }
Cell 'L.resume-table: back cut (= fwd cut), abort: refuse' { Fx-BackAt 'cut' } 'abort' @() 'refuse'
Cell 'L.resume-table: back rolled-back (= fwd rolled-back), copy: run a new attempt' { Fx-BackRolledBack } 'copy' @() { & $runNewAttempt; Eq (Get-St).attempt 3 'attempt' }
Cell 'L.resume-table: back rolled-back (= fwd rolled-back), cutover: refuse' { Fx-BackRolledBack } 'cutover' @() 'refuse:chạy copy trước'
Cell 'L.resume-table: back rolled-back (= fwd rolled-back), back: refuse' { Fx-BackRolledBack } 'back' @() 'refuse'
Cell 'L.resume-table: back rolled-back (= fwd rolled-back), finish: refuse' { Fx-BackRolledBack } 'finish' @() 'refuse'
Cell 'L.resume-table: back rolled-back (= fwd rolled-back), abort: run' { Fx-BackRolledBack } 'abort' @('có') $runAbort
Cell 'L.resume-table: back back-done, copy: run a new attempt' { Fx-BackDone } 'copy' @() { & $runNewAttempt; Eq (Get-St).attempt 3 'attempt' }
Cell 'L.resume-table: back back-done, cutover: refuse' { Fx-BackDone } 'cutover' @() 'refuse'
Cell 'L.resume-table: back back-done, back: chores (0)' { Fx-BackDone; [void](Patch-St @{ chores_done = $false }) } 'back' @() { Want 0 'back-done'; NoRecorded 'back chores' }
Cell 'L.resume-table: back back-done, finish: refuse' { Fx-BackDone } 'finish' @() 'refuse'
Cell 'L.resume-table: back back-done, abort: run' { Fx-BackDone } 'abort' @('có') $runAbort
Cell 'L.resume-table: finished, copy: refuse' { Fx-Finished } 'copy' @() 'refuse'
Cell 'L.resume-table: finished, cutover: refuse' { Fx-Finished } 'cutover' @() 'refuse'
Cell 'L.resume-table: finished, back: refuse' { Fx-Finished } 'back' @() 'refuse'
Cell 'L.resume-table: finished, finish: idempotent (0)' { Fx-Finished } 'finish' @('YES') { Want 0 'finished'; NoRecorded 'finish again' }
Cell 'L.resume-table: finished, abort: idempotent (0)' { Fx-Finished } 'abort' @('có') { Want 0 'finished'; NoRecorded 'abort after finish' }
Cell 'L.resume-table: aborted, copy: refuse' { Fx-Aborted } 'copy' @() 'refuse'
Cell 'L.resume-table: aborted, cutover: refuse' { Fx-Aborted } 'cutover' @() 'refuse'
Cell 'L.resume-table: aborted, back: refuse' { Fx-Aborted } 'back' @() 'refuse'
Cell 'L.resume-table: aborted, finish: idempotent (0)' { Fx-Aborted } 'finish' @('YES') { Want 0 'aborted'; NoRecorded 'finish after abort' }
Cell 'L.resume-table: aborted, abort: idempotent (0)' { Fx-Aborted } 'abort' @('có') { Want 0 'aborted'; NoRecorded 'abort again' }
# the last row: machines that disagree with the state on (dir, attempt) are re-init-ed first (the write-ahead of a copy, then a crash)
function Fx-Disagree { Fx-RolledBack; [void](Patch-St @{ attempt = 2 }) }
$reinit = { Ordered @('^old fwd-2-c\.init-old$'); Ok ((Sent 'new' '^fwd-2-c\.init-new$') -ge 1) 'c.init-new re-run'; Eq (@(LogNow | Where-Object { $_ -match ' mismatch$' }).Count) 0 'no call before the re-init' }
Cell 'L.resume-table: machines disagree on (dir, attempt), copy: re-init then run' { Fx-Disagree } 'copy' @() { Want 0 'copied'; & $reinit }
Cell 'L.resume-table: machines disagree on (dir, attempt), cutover: re-init then refuse' { Fx-Disagree } 'cutover' @() { Eq $script:Last.Code 1 'refused after the re-init'; & $reinit }
Cell 'L.resume-table: machines disagree on (dir, attempt), back: re-init then refuse' { Fx-Disagree } 'back' @() { Eq $script:Last.Code 1 'refused after the re-init'; & $reinit }
Cell 'L.resume-table: machines disagree on (dir, attempt), finish: re-init then refuse' { Fx-Disagree } 'finish' @() { Eq $script:Last.Code 1 'refused after the re-init'; & $reinit }
Cell 'L.resume-table: machines disagree on (dir, attempt), abort: re-init then run' { Fx-Disagree } 'abort' @('có') { Want 0 'aborted'; & $reinit }

# the named cases of OMP-HANDOFF §5 T11
T 'L.resume-table: fwd dừng case — r.unfreeze-src under the current attempt, then attempt+1, copied, mark null (exit 75); the next cutover re-inits and never replays x.freeze' {
  Fx-Copied; Add-Fault -M old -Key '-x\.freeze$' -Rc 75 -Out @('MOVE wait drain lock=/var/lock/fcode-deploy/task.lock waited=900')
  Ans 'có', 'dừng'; $r = Run-Move @('cutover'); Eq $r.Code 75 "dừng ($($r.Text))"
  Eq (Sent 'old' '^fwd-1-r\.unfreeze-src$') 1 'unfreeze under attempt 1'; Eq $W.old.Frozen $false 'old open'
  $s = Get-St; Eq $s.attempt 2 'attempt+1'; Eq $s.phase 'copied' 'phase'; Ok ($null -eq $s.mark) 'mark'; Eq $s.dir 'fwd' 'dir'
  [void](Do-Cutover 0); Before '^old fwd-2-c\.init-old$' '^old fwd-2-x\.freeze$'; Eq (@(LogNow | Where-Object { $_ -match 'fwd-1-x\.freeze' }).Count) 0 'the abandoned x.freeze is never sent again'
}
T 'L.resume-table: back dừng case — the E-R19 end state (cut, serving new, mark null, attempt unchanged); finish runs, abort is refused (1)' {
  Fx-Cut; Add-Fault -M new -Key '^back-2-x\.freeze$' -Rc 75 -Out @('MOVE wait drain lock=/var/lock/fcode-deploy/task.lock waited=900')
  Ans 'YES', 'dừng'; $r = Run-Move @('back'); Eq $r.Code 75 "dừng ($($r.Text))"
  Eq (Sent 'new' '^back-2-r\.unfreeze-src$') 1 'new unfrozen under the current attempt'
  $s = Get-St; Eq $s.dir 'back' 'dir'; Eq $s.attempt 2 'attempt unchanged'; Eq $s.phase 'cut' 'phase'; Eq $s.serving 'new' 'serving'; Ok ($null -eq $s.mark) 'mark'
  $r = Run-Move @('abort'); Eq $r.Code 1 'abort refused'
  Ans 'YES'; $r = Run-Move @('finish'); Eq $r.Code 0 "finish ($($r.Text))"
}
T 'L.resume-table: fwd dừng unfreeze-fail case — exit 70 with old frozen; the next verb re-inits both machines before the pre-rule''s chore 0' {
  Fx-Copied; Add-Fault -M old -Key '-x\.freeze$' -Rc 75 -Out @('MOVE wait drain lock=/var/lock/fcode-deploy/task.lock waited=900'); Add-Fault -M old -Key '-r\.unfreeze-src$' -Rc 1
  Ans 'có', 'dừng'; $r = Run-Move @('cutover'); Eq $r.Code 70 "dừng + failed unfreeze ($($r.Text))"
  $s = Get-St; Eq $s.attempt 2 'attempt+1 written whatever the unfreeze answered'; Eq $s.phase 'copied' 'phase'; Eq $W.old.Frozen $true 'old still frozen'
  [void](Do-Cutover 0)
  Ordered @('^old fwd-2-c\.init-old$', '^old fwd-2-x\.enable\.1$', '^old fwd-2-x\.unfreeze\.1$', '^old fwd-2-x\.freeze$')
  Eq (@(LogNow | Where-Object { $_ -match ' mismatch$' }).Count) 0 'no chore 0 before the agreement re-init'
}
T 'L.resume-table: two chore-0 repairs in one attempt — the second repair uses x.enable.2 / x.unfreeze.2 and really runs' {
  Fx-Copied; Add-Fault -M old -Key '-x\.freeze$' -Rc 75 -Out @('MOVE wait drain lock=/var/lock/fcode-deploy/task.lock waited=900'); Add-Fault -M old -Key '-r\.unfreeze-src$' -Rc 1
  Ans 'có', 'dừng'; [void](Run-Move @('cutover'))
  Add-Fault -M new -Key '^fwd-2-x\.final$' -Rc 1; Add-Fault -M old -Key '^fwd-2-r\.unfreeze-src$' -Rc 1
  [void](Do-Cutover 70); Eq (Sent 'old' '^fwd-2-x\.unfreeze\.1$' -All) 1 'first repair'; Eq $W.old.Frozen $true 'frozen again after the failed rollback unfreeze'
  Ans 'có'; $r = Run-Move @('abort'); Eq $r.Code 0 "abort ($($r.Text))"
  Eq (Sent 'old' '^fwd-2-x\.enable\.2$') 1 'second repair x.enable.2 runs'; Eq (Sent 'old' '^fwd-2-x\.unfreeze\.2$') 1 'second repair x.unfreeze.2 runs'
  Before '^old fwd-2-x\.unfreeze\.2$' '^old fwd-2-a\.old$'
}
T 'L.resume-table: cut, enabled, pending chore, hand-stopped unit — cutover runs the pending chores only; the stopped unit stays stopped' {
  Fx-Cut; [void](Patch-St @{ chores_done = $false }); $W.new.Active = 2
  $r = Run-Move @('cutover'); Eq $r.Code 0 "pending chores ($($r.Text))"; NoChore0; Eq $W.new.Active 2 'the hand-stopped unit stays stopped'; Eq (Get-St).chores_done $true 'chores done'
  Reset-World; Fx-BackDone; [void](Patch-St @{ chores_done = $false }); $W.old.Active = 2
  $r = Run-Move @('back'); Eq $r.Code 0 "back chores ($($r.Text))"; NoChore0; Eq $W.old.Active 2 'the hand-stopped unit stays stopped on old'
}
T 'L.resume-table: post-carry back-done — copy and abort run as after a manual back' {
  Start-Carry; [void](Do-Cutover 10); Ans 'có'; $r = Run-Move @('abort'); Eq $r.Code 0 "abort after a carry-back ($($r.Text))"; Eq (Get-St).phase 'aborted' 'phase'
  Reset-World; Start-Carry; [void](Do-Cutover 10); [void](Do-Copy 0); $s = Get-St; Eq $s.dir 'fwd' 'dir'; Eq $s.attempt 3 'attempt'
}
T 'L.resume-table: post-carry rolled-back (Q-discard) — copy starts the next attempt' {
  Start-Carry; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1; Ans 'có', 'YES'; [void](Run-Move @('cutover')); Eq (Get-St).phase 'rolled-back' 'phase'
  [void](Do-Copy 0); $s = Get-St; Eq $s.dir 'fwd' 'dir'; Eq $s.attempt 3 'attempt'
}

# ============================== static checks of laptop/fcode.ps1 ==============================
T 'L.call-key-sites: every Invoke-MoveCall site sends a single-quoted step of the closed list as its 3rd argument, every step has a site, and --call is built only inside Invoke-MoveCall' {
  $sites = @($script:FcodeAst.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Invoke-MoveCall' }, $true))
  Ok ($sites.Count -gt 0) 'no Invoke-MoveCall site'
  $bad = @(); $seen = @{}
  foreach ($c in $sites) {
    $pos = @($c.CommandElements | Select-Object -Skip 1 | Where-Object { $_ -isnot [Management.Automation.Language.CommandParameterAst] })
    $a = if ($pos.Count -ge 3) { $pos[2] } else { $null }
    if ($a -is [Management.Automation.Language.StringConstantExpressionAst] -and $a.StringConstantType -eq 'SingleQuoted' -and $StepList -ccontains $a.Value) { $seen[$a.Value] = $true }
    else { $bad += "line $($c.Extent.StartLineNumber): $(if ($a) { $a.Extent.Text } else { '(none)' })" }
  }
  Ok ($bad.Count -eq 0) "call sites without a literal step of the closed list: $($bad -join ' ; ')"
  $miss = @($StepList | Where-Object { -not $seen.ContainsKey($_) }); Ok ($miss.Count -eq 0) "steps with no call site: $($miss -join ' ')"
  $fn = @($script:FcodeAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-MoveCall' }, $true))[0]
  $out = @($script:FcodeAst.FindAll({ param($n) ($n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and "$($n.Value)" -match '(^|\s)--call(\s|$)' }, $true) | Where-Object { $_.Extent.StartOffset -lt $fn.Extent.StartOffset -or $_.Extent.EndOffset -gt $fn.Extent.EndOffset })
  Ok ($out.Count -eq 0) "--call built outside Invoke-MoveCall: $(@($out | ForEach-Object { 'line ' + $_.Extent.StartLineNumber }) -join ', ')"
}
T 'L.texts-match-move-md: every owner text and reason label of docs/MOVE.md (CONTRACT §8.3 copy) is in laptop/fcode.ps1 verbatim' {
  $p = $env:MV_MOVE_MD
  Ok ($p -and (Test-Path -LiteralPath $p)) "MV_MOVE_MD must name deploy-gate docs/MOVE.md (G.2, W1-T11-DG-T11-1; got [$p])"
  $md = [IO.File]::ReadAllText($p) -replace "`r`n", "`n"
  $blk = { param($b, $e) $i = $md.IndexOf($b); if ($i -lt 0) { throw "docs/MOVE.md lacks $b" }; $j = $md.IndexOf($e, $i); $md.Substring($i + $b.Length, $j - $i - $b.Length) }
  $d151 = & $blk '<!-- BEGIN verbatim DESIGN D.15.1' '<!-- END verbatim -->'
  $texts = @([regex]::Matches($d151, '(?m)^\|[^|\n]+\|\s*"([^"\n]+)"\s*\|\s*$') | ForEach-Object { $_.Groups[1].Value })
  $vi = @((& $blk '<!-- BEGIN vi-texts -->' '<!-- END vi-texts -->') -split "`n" | Where-Object { $_ -and $_ -notmatch '^```' })
  $lab = @([regex]::Matches((& $blk '<!-- BEGIN reason-labels -->' '<!-- END reason-labels -->'), '(?m)^(refuse|warn|error) (\S+) \| (.+)$') | ForEach-Object { $_.Groups[3].Value.Trim() })
  Ok ($texts.Count -ge 15) "D.15.1 texts found: $($texts.Count)"; Ok ($vi.Count -ge 20) "vi-texts found: $($vi.Count)"; Ok ($lab.Count -ge 78) "labels found: $($lab.Count)"
  $src = $script:FcodeText -replace '``', '`' -replace "''", "'"
  $miss = @()
  foreach ($t in @($texts) + @($vi)) { foreach ($fr in @($t -split '<[^>]+>')) { $f2 = $fr.Trim(); if ($f2.Length -ge 4 -and -not $src.Contains($f2)) { $miss += $f2 } } }
  foreach ($l in $lab) { if (-not $src.Contains($l)) { $miss += $l } }
  Ok ($miss.Count -eq 0) "texts of docs/MOVE.md not in laptop/fcode.ps1 ($($miss.Count)): $(@($miss | Select-Object -First 12) -join ' || ')"
}
T 'L.suite-windows: without bash (Windows) a bash case is skipped and counted, never failed' {
  $saved = $script:BashExe; $p0 = $script:pass; $f0 = $script:fail; $s0 = $script:skip
  try { $script:BashExe = $null; $wk = $script:W; T 'L.suite-windows: inner bash case' { throw 'must not run' } -NeedsBash; $script:W = $wk }
  finally { $script:BashExe = $saved }
  Eq ($script:skip - $s0) 1 'skipped'; Eq ($script:fail - $f0) 0 'not failed'; Eq ($script:pass - $p0) 0 'not run'
  $script:skip--
}

# ============================== a down new, rebuild after the swap, the cut-off time (T10 review r1 F1–F6) ==============================
T 'L.carry-after-final-70: PROBE.er5-final-new-down — an x.final whose outcome stays unknown (new drops during it) has started (D.5.2, W1-T11-DG-R11-1): exit 70, no Q-discard, old never started' {
  Start-Carry; Add-Fault -M new -Key '^back-2-x\.final$' -Mode down; Ans 'có', 'YES'
  $r = Run-Move @('cutover'); Eq $r.Code 70 "exit ($($r.Text))"; Eq (SentAny '-r\.start-src$') 0 'old not started'
  Ok (@(Lines -Last | Where-Object { $_ -match 'Gõ YES' }).Count -eq 0) 'no Q-discard after x.final started'
}
T 'L.abort-new-unreachable: after Q-newlost YES (new powered off), abort skips new and aborts old' {
  Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Mode down; [void](Do-Cutover 70)
  Ans 'YES'; $r = Run-Move @('cutover'); Eq $r.Code 10 "Q-newlost ($($r.Text))"
  Eq (Get-St).new_lost $true 'new_lost'
  Ans 'có'; $r = Run-Move @('abort'); Eq $r.Code 0 "abort ($($r.Text))"; Eq (Get-St).phase 'aborted' 'phase'; Eq (Sent 'old' '-a\.old$') 1 'a.old'
}
T 'L.rb-dst-unreachable-not-started: a plain rollback resumed while new is down skips r.stop-dst and starts old (exit 10)' {
  Fx-RollingBack; $W.new.Up = $false
  $r = Run-Move @('cutover'); Eq $r.Code 10 "rollback continued ($($r.Text))"; Eq (Sent 'old' '-r\.start-src$') 1 'old started'; Eq (Get-St).phase 'rolled-back' 'phase'
}
T 'L.carry-discard-new-unreachable-needs-poweroff: a power-off Q-discard left unanswered is asked again by the next cutover while new is down; YES starts old (10, new_lost)' {
  Start-Carry; Add-Fault -M new -Key '^back-2-x\.stop-src$' -Mode down; Ans 'có', 'không'
  $r = Run-Move @('cutover'); Eq $r.Code 70 'first answer not YES'
  Ans 'YES'; $r = Run-Move @('cutover'); Eq $r.Code 10 "after power-off ($($r.Text))"; Eq (Get-St).new_lost $true 'new_lost'; Eq (Sent 'old' '^back-2-r\.start-src$') 1 'old started'
}
T 'L.rebuild: after the step-11 alias swap the rebuild reads old through Reach-Old (move-id old_addr), never new twice; old''s key is old''s' {
  Fx-Cut; [IO.File]::Delete((StatePath))
  foreach ($n in 'old', 'new') { $W[$n].MoveId.old_addr = $OldAddr; $W[$n].MoveId.new_addr = $NewAddr }
  $r = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $r.Code 0 "rebuild ($($r.Text))"
  Ok (@(LogNow | Where-Object { $_ -ceq 'old script:rebuild read' }).Count -ge 1) "rebuild must read old: $(LogNow)"
  $s = Get-St; Ok ("$($s.old.hostkey_line)" -match [regex]::Escape($KeyOld)) "old.hostkey_line holds old's key: $($s.old.hostkey_line)"; Eq $s.serving 'new' 'serving'
  Eq $s.old.addr $OldAddr 'old.addr'; Eq $s.new.addr $NewAddr 'new.addr'
  Eq "$($s.aliases.laptop_backup)" $OldAddr 'laptop_backup rebuilt from the move-ids'; Eq "$($s.aliases.coder_backup)" $OldAddr 'coder_backup rebuilt from the move-ids'
}
T 'L.rebuild: target_users[], target_groups[], target_subids[], target_addrs[] and target_stop_budget_s come from new''s target.json (c.init-new''s "target" stdin, read back as MOVE target), never from the pinned same_users[] or new''s current users; the next re-plan sends them (D.0.9, D.0.10; W1-T11-DG-R11-2, W1-T10R-F4)' {
  $W.Pf = @('INV target user=quoc uid=1000 home-nonskel=1', 'INV target user=zed uid=1700 home-nonskel=0', 'INV target group=devs gid=1800', 'INV target subid user=zed kind=uid start=300000 count=65536', 'INV target subid user=zed kind=gid start=300000 count=65536', 'INV target addr=198.51.100.20', 'INV target addr=2001:db8::20', 'INV target platform=0', 'INV target stop_budget_s=240')
  Fx-Copied
  $want = [ordered]@{ users = 'quoc:1000,zed:1700'; groups = 'devs:1800'; subids = 'zed:uid:300000:65536,zed:gid:300000:65536'; addrs = '198.51.100.20,2001:db8::20'; stop = '240' }
  $flat = { param($u, $g, $sb, $a, $st) [ordered]@{ users = (@($u | ForEach-Object { "$($_.name):$($_.uid)" }) -join ','); groups = (@($g | ForEach-Object { "$($_.name):$($_.gid)" }) -join ','); subids = (@($sb | ForEach-Object { "$($_.user):$($_.kind):$($_.start):$($_.count)" }) -join ','); addrs = (@($a) -join ','); stop = "$st" } }
  $t = $W.new.InitStdin.target; Ok ($null -ne $t) "c.init-new stdin carries the ""target"" key: $(ConvertTo-Json -InputObject $W.new.InitStdin -Depth 4 -Compress)"
  $got = & $flat $t.users $t.groups $t.subids $t.addrs $t.stop_budget_s; foreach ($k in $want.Keys) { Eq $got[$k] $want[$k] "c.init-new target.$k" }
  $s = Get-St; $got = & $flat $s.target_users $s.target_groups $s.target_subids $s.target_addrs $s.target_stop_budget_s; foreach ($k in $want.Keys) { Eq $got[$k] $want[$k] "state target_$k after plan" }
  $in = @($W.PlanStdin[-1]); foreach ($l in 'target-user zed 1700', 'target-addr 198.51.100.20', 'target-addr 2001:db8::20') { Ok ($in -ccontains $l) "plan stdin lacks [$l]: $($in -join ' | ')" }
  [IO.File]::Delete((StatePath)); foreach ($n in 'old', 'new') { $W[$n].MoveId.old_addr = $OldAddr; $W[$n].MoveId.new_addr = $NewAddr }
  $W.Pf = @('INV target user=quoc uid=1000 home-nonskel=1', 'INV target user=late uid=1900 home-nonskel=1', 'INV target stop_budget_s=1')   # new's users now: never read by a rebuild
  $r = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $r.Code 0 "rebuild ($($r.Text))"
  Ok (@(LogNow | Where-Object { $_ -ceq 'new script:rebuild read' }).Count -ge 1) "rebuild read on new: $(LogNow)"; Eq (@(LogNow | Where-Object { $_ -match 'script:preflight' }).Count) 0 'no preflight in a rebuild'
  $s = Get-St; $got = & $flat $s.target_users $s.target_groups $s.target_subids $s.target_addrs $s.target_stop_budget_s; foreach ($k in $want.Keys) { Eq $got[$k] $want[$k] "rebuilt target_$k" }
  $n0 = $W.PlanStdin.Count; [void](Run-Move @('copy')); Ok ($W.PlanStdin.Count -gt $n0) 'the copy refresh re-plans'
  $in = @($W.PlanStdin[-1]); foreach ($l in 'target-user quoc 1000', 'target-user zed 1700', 'target-addr 2001:db8::20') { Ok ($in -ccontains $l) "re-plan stdin lacks [$l]: $($in -join ' | ')" }; Ok (-not ($in -match 'late')) 'never new''s current users'
}
T 'L.pre-clock: new against old over 5 s refuses clock even when each is within 5 s of the laptop' {
  $W.old.Skew = 4; $W.new.Skew = -4; [void](Do-Plan -Want 65); HasText 'Đồng hồ các máy lệch nhau quá 5 giây'
}
# R5-3: step 8 writes dst_started_at only when it is empty, in the same save as dst_started=true, before x.start; every dst_started=false write clears it
T 'L.new-lost-fence-text: Q-newlost''s <giờ> is dst_started_at (= new''s x.start, saved before the call, R5-3) printed per R5-2 — never Q-cut.ts, the x.freeze start or the question time (D.5.3, W1-T10-F5)' {
  Fx-Copied; $W.Hooks['x.start'] = { $script:AtStart = @{ Clock = (Format-Iso $script:Clock); Saved = (St-Raw 'dst_started_at') } }
  Add-Fault -M new -Key '^fwd-1-x\.health$' -Mode down; [void](Do-Cutover 70)
  $xs = Rec-Start new ($RebuildDstStartedAt -f 1); $da = St-Raw 'dst_started_at'
  Ok ($da -match $TsRx) "dst_started_at in the record format: [$da]"; Eq $da $xs 'dst_started_at = the x.start instant'; Eq $script:AtStart.Saved $xs 'in state.json when x.start arrives (R5-3 order)'
  $script:Clock = $script:Clock.AddHours(2); $tq = Format-Iso $script:Clock
  Ans 'YES'; $r = Run-Move @('cutover'); Eq $r.Code 10 "Q-newlost YES ($($r.Text))"
  $g = Get-QuestionTime
  Eq $g (Expect-Gio $xs) '<giờ>'
  Ok ($g -cne (Expect-Gio (Rec-Start old fwd-1-x.freeze))) "not the x.freeze start: $g"
  Ok ($g -cne (Expect-Gio (St-Raw 'ts'))) "not Q-cut.ts (the overruled source): $g"
  Ok ($g -cne (Expect-Gio $tq)) "not the question time: $g"
  Ok ((St-Raw 'dst_started_at') -match $TsRx) 'dst_started_at after the save'; Ok ((St-Raw 'ts') -match $TsRx) 'Q-cut.ts after the save'
}
T 'L.new-lost-fence-text: a resumed cutover keeps dst_started_at = the first x.start of the attempt (R5-3 "only when empty"; D.5.3, W1-T10-F5)' {
  Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Mode down; [void](Do-Cutover 70)
  $W.new.Up = $true; $script:Clock = $script:Clock.AddHours(1)
  $r = Run-Move @('cutover'); Eq $r.Code 0 "resume ($($r.Text))"; Eq (St-Raw 'dst_started_at') (Rec-Start new ($RebuildDstStartedAt -f 1)) 'dst_started_at'
}
T 'L.new-lost-fence-text: a later attempt''s <giờ> is its own x.start, never an earlier attempt''s dst_started_at (R5-3 cleared; D.5.3, W1-T10-F5)' {
  Start-Carry; [void](Do-Cutover 10); [void](Do-Copy 0)
  $script:AtFreeze = '?'; $W.Hooks['x.freeze'] = { param($m, $e) if ($e.Call -ceq 'fwd-3-x.freeze') { $script:AtFreeze = St-Raw 'dst_started_at' } }
  Add-Fault -M new -Key '^fwd-3-x\.health$' -Mode down; [void](Do-Cutover 70)
  Ok ($null -eq $script:AtFreeze -or $script:AtFreeze -ceq 'null') "the dst_started=false save of step 1 also cleared dst_started_at (R5-3), seen at fwd-3-x.freeze: [$($script:AtFreeze)]"
  $script:Clock = $script:Clock.AddHours(2); Ans 'không'; [void](Run-Move @('cutover')); $g = Get-QuestionTime
  Eq $g (Expect-Gio (Rec-Start new ($RebuildDstStartedAt -f 3))) '<giờ> of attempt 3'; Ok ($g -cne (Expect-Gio (Rec-Start new ($RebuildDstStartedAt -f 1)))) "not attempt 1's x.start: $g"
}
T 'L.new-lost-fence-text: an empty, null, unparseable, non-ISO or missing dst_started_at prints "không rõ"; an unreadable Q-cut.ts never reaches gh as a --created token (W1-T10R4-N1)' {
  $variants = @('""', 'null', '"garbage"', '"11/02/2026 10:00:07"', $null)
  Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Mode down; [void](Do-Cutover 70)
  $base = [IO.File]::ReadAllText((StatePath)); $st0 = (Run-Move @('status')).Code
  foreach ($v in $variants) {
    [IO.File]::WriteAllText((StatePath), $base, $utf8); St-RawSet 'dst_started_at' $v
    Ans 'không'; $r = Run-Move @('cutover'); Eq $r.Code 70 "[$v] cutover"; $g = Get-QuestionTime; Ok ($g -match $CutOffUnknown) "[$v] <giờ>: $g"
    [IO.File]::WriteAllText((StatePath), $base, $utf8); St-RawSet 'dst_started_at' $v; Eq (Run-Move @('status')).Code $st0 "[$v] status"
  }
  Reset-World; Use-Legacy; Fx-Cut; St-RawSet 'chores_done' 'false'
  $base = [IO.File]::ReadAllText((StatePath)); $st0 = (Run-Move @('status')).Code
  foreach ($v in $variants) {
    [IO.File]::WriteAllText((StatePath), $base, $utf8); St-RawSet 'ts' $v; Eq (Run-Move @('status')).Code $st0 "[$v] status"
    [IO.File]::WriteAllText((StatePath), $base, $utf8); St-RawSet 'ts' $v; $n0 = $W.GhLog.Count; [void](Run-Move @('cutover'))
    $bad = @(for ($i = $n0; $i -lt $W.GhLog.Count; $i++) { $t = $W.GhLog[$i].Text; if ($t -match $GhForm.RunList -and $t -match '--created (\S+)' -and $Matches[1].TrimStart('>', '=') -notmatch $TsRx) { $t } })
    Ok ($bad.Count -eq 0) "[$v] a --created token outside the record format: $($bad -join ' | ')"
  }
}

# ============================== round 3: T11 review-r2 N1 and T10 review-r2 OUT-OF-SCOPE (T11) ==============================
T 'L.carry-after-final-70: new misses one status after an x.final with no GATE_EXIT, then answers (last_final = that id): exit 70, old never started' {
  Start-Carry
  $W.Hooks['x.final'] = { param($m, $e) if ($e.Call -ceq 'back-2-x.final') { Add-Fault -M new -Key '^status$' -Mode down -N 1 } }
  Add-Fault -M new -Key '^back-2-x\.final$' -Rc 0 -Mode noexit; Ans 'có', 'YES'
  $r = Run-Move @('cutover'); Eq (SentAny '-r\.start-src$') 0 "old started over the copy x.final wrote (exit $($r.Code))"; Eq $r.Code 70 'exit'
}
T 'L.carry-after-final-70: a carry-back failing after x.final shows both MOVE state lines with the carry-half text (exit 70)' {
  Start-Carry; Add-Fault -M new -Key '^back-2-x\.final$' -Rc 1; Ans 'có'
  $r = Run-Move @('cutover'); Eq $r.Code 70 "exit ($($r.Text))"
  Eq @(Lines -Last | Where-Object { $_ -match '^\s*MOVE state ' }).Count 2 "both MOVE state lines: $(Lines -Last)"
  HasText 'dữ liệu máy cũ đang dở; chỉ tiếp tục được khi máy mới nối lại'; Eq (SentAny '-r\.start-src$') 0 'old not started'
}
T 'L.step10-fail-no-carry: chore 0 failing at the end of a carry-back prints the return-to-old text and the remedy (exit 1)' {
  Start-Carry; Add-Fault -M old -Key '^back-2-x\.enable\.' -Rc 1; Ans 'có'
  $r = Run-Move @('cutover'); Eq $r.Code 1 "exit ($($r.Text))"; HasText 'Đã quay về máy cũ; máy cũ đang phục vụ.'; HasText 'chạy lại fcode move cutover'
}
T 'L.resume-old-reboot-after-stop: a fwd cutover resumed after x.stop-src (x.guards answered 75 + tiếp tục before the crash) never runs the guards again' {
  Fx-Copied; [void](Patch-St @{ mark = 'cutting'; dst_started = $false }); Set-Real 'fwd' 1 'cutting' 'copied' 'old' 0
  Recs 'old' 'fwd-1' @('x.freeze', 'x.check', 'x.baseline'); Add-Rec 'old' 'fwd-1-x.guards' 75; Add-Rec 'old' 'fwd-1-x.stop-src'; Recs 'new' 'fwd-1' @('x.repin')
  $r = Run-Move @('cutover'); Eq $r.Code 0 "resume ($($r.Text))"; Eq (Sent 'old' '-x\.guards$') 0 "x.guards re-run: $(LogNow)"
}
T 'L.guard-question: a crash while Q-guard was open asks it again on resume, guards not re-run' {
  Fx-Copied; [void](Patch-St @{ mark = 'cutting'; dst_started = $false }); Set-Real 'fwd' 1 'cutting' 'copied' 'old' 0
  Recs 'old' 'fwd-1' @('x.freeze', 'x.check', 'x.baseline'); Add-Rec 'old' 'fwd-1-x.guards' 75; Recs 'new' 'fwd-1' @('x.repin')
  Ans 'tiếp tục'; $r = Run-Move @('cutover'); Eq $r.Code 0 "resume ($($r.Text))"
  Eq (Sent 'old' '-x\.guards$') 0 "x.guards re-run: $(LogNow)"; Ok (@(Lines -Last | Where-Object { $_ -match 'đang bận' }).Count -ge 1) 'Q-guard asked again'
}
T 'L.resume-table: back cutting carry=false, back: an interrupted x.final on new resumes at step 6; the guards are not run again and Q-guard is not asked' {
  Fx-BackAt 'copied' 'cutting'; Recs 'new' 'back-2' @('x.check', 'x.baseline'); Add-Rec 'new' 'back-2-x.guards' 75; Add-Rec 'new' 'back-2-x.stop-src'; Add-Rec 'old' 'back-2-x.repin'; Add-Rec 'old' 'back-2-x.stop-dst'
  $n = $script:W.new; $n.Rec['back-2-x.final'] = @{ Rc = $null; Out = @('LOG back-2-x.final'); Dur = 5; Argv = '?'; Start = ''; End = '' }; [void]$n.Order.Add('back-2-x.final'); $n.Last = 'back-2-x.final'
  Ans 'tiếp tục'; $r = Run-Move @('back')
  Eq (Sent 'new' '^back-2-x\.guards$') 0 "x.guards re-run on resume (exit $($r.Code)): $(LogNow)"; Ok (-not (@(Lines -Last) | Where-Object { $_ -match 'đang bận' })) 'Q-guard asked again'
}
T 'L.copy-refresh-reprepares: a refresh that failed before its c.prepare blocks the cutover ("chạy fcode move copy lại", nothing frozen) until a good refresh' {
  Fx-Copied; Add-Fault -M new -Key '-c\.prepare\.2$' -Rc 1; [void](Do-Copy 1)
  Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 1 "cutover after a failed refresh ($($r.Text))"; HasText 'chạy fcode move copy lại'; Eq (SentAny '-x\.freeze$') 0 'nothing frozen'
  [void](Do-Copy 0); Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 0 "cutover after a good refresh ($($r.Text))"
}
T 'L.back-rollback-to-cut: in a manual back an x.final whose outcome stays unknown ends 70 (resume only), never the E-R19 restart (D.5.2, W1-T11-DG-R11-1)' {
  Fx-Cut; Add-Fault -M new -Key '^back-2-x\.final$' -Mode down; Ans 'YES'
  $r = Run-Move @('back'); $s = Get-St
  Eq $r.Code 70 "exit ($($r.Text))"; Eq (SentAny '-r\.start-src$') 0 'no E-R19 restart'
  Eq $s.mark 'cutting' 'resume only: the back''s mark is kept (E-R19 writes mark=null, phase=cut)'
  NoText 'Chuyển ngược không xong'
}
T 'L.resume-table: machines disagree on (dir, attempt), copy with new_lost set: new is re-initialised before the lost-new fence runs' {
  Fx-Disagree; [void](Patch-St @{ new_lost = $true })
  $r = Run-Move @('copy'); Eq $r.Code 0 "copy ($($r.Text))"; Eq (@(LogNow | Where-Object { $_ -match ' mismatch$' }).Count) 0 "a call before the re-init: $(LogNow)"
}
T 'L.abort-new-unreachable: new answers again after a carry-back''s Q-newlost (its move-id lags the state): abort runs (exit 0)' {
  Start-Carry; Add-Fault -M new -Key '^back-2-b\.init-new$' -Mode down; Ans 'có'; $r1 = Run-Move @('cutover')
  Ans 'YES'; $r2 = Run-Move @('cutover'); Eq $r2.Code 10 "Q-newlost after power-off (first run $($r1.Code): $($r1.Text) || second: $($r2.Text))"; Eq (Get-St).new_lost $true 'new_lost'
  $script:W.new.Up = $true; Ans 'có'; $r = Run-Move @('abort'); Eq $r.Code 0 "abort once new answers again ($($r.Text)) log: $(LogNow)"
}
T 'L.new-lost: a later attempt in which new serves again is never fenced by the old new_lost flag (no r.stop-dst to the serving new; D.5.3, W1-T10-O1)' {
  Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Mode down; [void](Do-Cutover 70)
  Ans 'YES'; $r = Run-Move @('cutover'); Eq $r.Code 10 'Q-newlost'
  $script:W.new.Up = $true; [void](Do-Copy); Eq (Get-St).new_lost $false 'cleared by the later c.init-new rc 0'; [void](Do-Cutover); Eq (Get-St).serving 'new' 'second attempt cut'
  Add-Fault -M new -Key '-c\.transfer\.' -Rc 1; Ans 'YES'; $rb = Run-Move @('back'); $st = Get-St; $r = Run-Move @('back')
  Eq (Sent 'new' "$([regex]::Escape($FenceStep))$") 0 "$FenceStep sent to the serving new (first back $($rb.Code), state $($st.dir)-$($st.attempt) $($st.phase) serving=$($st.serving)): $(LogNow)"
}
T 'L.new-lost: a later attempt''s c.init-new rc 0 clears new_lost and new_discarded; a c.init-new that failed clears neither (D.5.3, W1-T10-O1)' {
  Start-Carry; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1; Ans 'có', 'YES'; $r = Run-Move @('cutover'); Eq $r.Code 10 "Q-discard YES ($($r.Text))"; Eq (Get-St).new_discarded $true 'new_discarded'
  Add-Fault -M new -Key '-c\.init-new$' -Rc 1 -Out @('MOVE error tool-missing tool=e2fsprogs'); $r = Do-Copy -1; Ok ($r.Code -ne 0) "the copy whose c.init-new failed ($($r.Text))"; Eq (Get-St).new_discarded $true 'kept after a failed c.init-new'
  [void](Do-Copy 0); Eq (Get-St).new_discarded $false 'cleared by c.init-new rc 0'
  Reset-World; Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Mode down; [void](Do-Cutover 70); Ans 'YES'; $r = Run-Move @('cutover'); Eq $r.Code 10 'Q-newlost'; Eq (Get-St).new_lost $true 'new_lost'
  $W.new.Up = $true; Add-Fault -M new -Key '-c\.init-new$' -Rc 1 -Out @('MOVE error tool-missing tool=e2fsprogs'); $r = Do-Copy -1; Ok ($r.Code -ne 0) "the copy whose c.init-new failed ($($r.Text))"; Eq (Get-St).new_lost $true 'new_lost kept after a failed c.init-new'
  [void](Do-Copy 0); Eq (Get-St).new_lost $false 'cleared by c.init-new rc 0'
}
T 'L.rebuild: a manual back in flight (mark set, x.freeze sent) is rebuilt with carry=false, never as a carry-back (D.0.10, W1-T10-O2)' {
  Fx-BackAt 'copied' 'cutting'; Recs 'new' 'back-2' @('x.check'); [IO.File]::Delete((StatePath))
  $r = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $r.Code 0 "rebuild ($($r.Text))"
  Eq (Get-St).carry $false "a manual back rebuilt as a carry-back (phase $((Get-St).phase), mark $((Get-St).mark))"; Eq (Get-St).phase 'copied' 'phase = the latest move-id phase (D.0.10, W1-T10-O2)'
}
T 'L.rebuild: legacy_push[] comes from a new push scan and legacy_known_hosts{} holds old''s line from old''s key (D.0.10; W1-T3-GAP-11)' {
  Use-Legacy; Fx-Cut; [IO.File]::Delete((StatePath)); foreach ($n in 'old', 'new') { $W[$n].MoveId.old_addr = $OldAddr; $W[$n].MoveId.new_addr = $NewAddr }
  $r = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $r.Code 0 "rebuild ($($r.Text))"
  $s = Get-St; Ok (@($s.legacy_push | Where-Object { "$($_.repo)" -ceq $LegacyRepo -and "$($_.project)" -ceq 'deal-sync' }).Count -eq 1) "legacy_push[] from the scan (project from old's /opt/deal-sync origin, ruling T10c-LP): $(ConvertTo-Json -InputObject $s.legacy_push -Compress)"
  Eq "$($s.legacy_known_hosts.$LegacyRepo)" "$OldAddr ssh-ed25519 $KeyOld" 'old''s line rebuilt from old''s key'
}

# ============================== round 4: T10 review-r3 OUT-OF-SCOPE (T11), the cases that kill m2, m4, m5 and m6 ==============================
T 'L.resume-table: machines disagree on (dir, attempt), abort with new_lost set and no move-id on new: no fence is sent to new (reading T10-G12)' {
  Fx-Disagree; [void](Patch-St @{ new_lost = $true }); $script:W.new.MoveId = $null
  Ans 'có'; $r = Run-Move @('abort'); Eq $r.Code 0 "abort ($($r.Text))"
  Eq (@(LogNow | Where-Object { $_ -match "^new \S+-$([regex]::Escape($FenceStep))" }).Count) 0 "no fence on a new without this move-id: $(LogNow)"
}
T 'L.guard-question: a crash while Q-guard is open keeps the project names; the resume asks "Ứng dụng task đang bận" and does not re-run the guards (reading T10-G51)' {
  Fx-Copied; Add-Fault -M old -Key '-x\.guards$' -Rc 75 -Out @('MOVE wait guard project=task waited=900')
  $script:SavedRSL = ${function:Read-SyncLine}
  try {
    function script:Read-SyncLine([string]$Prompt) { if ($Prompt -match 'tiếp tục / dừng') { throw 'laptop gone while Q-guard is open' }; & $script:SavedRSL $Prompt }
    Ans 'có'; $r1 = Run-Move @('cutover')
  } finally { Set-Item -Path function:script:Read-SyncLine -Value $script:SavedRSL }
  Eq (Get-St).mark 'cutting' "crash while Q-guard open (exit $($r1.Code)): $($r1.Text)"
  Eq ([string](Get-St).answers.$QGuardKey) 'task' 'names kept in the state'
  Ans 'tiếp tục'; $r = Run-Move @('cutover'); Eq $r.Code 0 "resume ($($r.Text))"
  Ok (@(Lines -Last | Where-Object { $_ -match '\AỨng dụng task đang bận\.' }).Count -ge 1) "Q-guard names on resume: $(Lines -Last)"
  Eq (Sent 'old' '-x\.guards$') 0 "x.guards re-run: $(LogNow)"
}
T 'L.rebuild: dst_started_at and Q-cut.ts are rebuilt from the records (R5-1; R2-4), never now; no record: dst_started_at empty and no Q-cut; a carry rebuilds from fwd-<attempt−1>-x.start (D.0.10, D.5.3, W1-T10-F5)' {
  $prep = { [IO.File]::Delete((StatePath)); foreach ($n in 'old', 'new') { if ($W[$n].MoveId) { $W[$n].MoveId.old_addr = $OldAddr; $W[$n].MoveId.new_addr = $NewAddr } } }
  $rebuild = { $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild ($($rr.Text))" }
  # (a) at cut: dst_started_at = new's fwd-1-x.start, Q-cut.ts = old's fwd-1-x.freeze
  Fx-Cut; $xs = Rec-Start new ($RebuildDstStartedAt -f 1); $fz = Rec-Start old fwd-1-x.freeze
  & $prep; $script:Clock = $script:Clock.AddHours(1); & $rebuild
  Eq (St-Raw 'dst_started') 'true' '(a) dst_started'; Eq (St-Raw 'dst_started_at') $xs '(a) dst_started_at'; Eq (St-Raw 'ts') $fz '(a) Q-cut.ts (R2-4)'
  Ok ((St-Raw 'dst_started_at') -match $TsRx -and (St-Raw 'ts') -match $TsRx) '(a) record format'
  # (b) copied, no x.start / x.freeze record: dst_started_at empty, no Q-cut, never now
  Reset-World; Fx-Copied; & $prep; $script:Clock = $script:Clock.AddHours(1); & $rebuild
  Eq (St-Raw 'dst_started') 'false' '(b) dst_started'; $b = St-Raw 'dst_started_at'; Ok ($null -eq $b -or $b -ceq '' -or $b -ceq 'null') "(b) dst_started_at empty, never now: [$b]"
  Ok (-not ([IO.File]::ReadAllText((StatePath)).Contains('"Q-cut"'))) '(b) no Q-cut in a rebuilt state without an x.freeze record'
  # (c) a carry whose x.start record has no start= (start=-): unknown <giờ>, never the question time
  Reset-World; Fx-Carry; & $prep; & $rebuild
  Eq (St-Raw 'carry') 'true' '(c) carry'; $c = St-Raw 'dst_started_at'; Ok ($null -eq $c -or $c -ceq '' -or $c -ceq 'null') "(c) dst_started_at empty: [$c]"
  $script:Clock = $script:Clock.AddHours(1); $tq = Format-Iso $script:Clock
  Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1; [void](Run-Move @('cutover')); $g = Get-QuestionTime
  Ok ($g -match $CutOffUnknown) "(c) <giờ> unknown: $g"; Ok ($g -cne (Expect-Gio $tq)) "(c) not the question time: $g"
  # (d) a carry (dir=back, attempt 2): rebuilt from new's fwd-1-x.start (a = attempt − 1)
  Reset-World; Fx-Carry; $d = Format-Iso ($script:Clock.AddMinutes(-30)); $W.new.Rec[($RebuildDstStartedAt -f 1)].Start = $d
  & $prep; & $rebuild; Eq (St-Raw 'dst_started_at') $d '(d) dst_started_at from fwd-<attempt−1>-x.start'
}
T 'L.rebuild: a save after a reload writes Q-cut.ts and dst_started_at back byte-equal, and an unparseable dst_started_at back as null (W1-T10R4-N1; R5-3)' {
  Use-Legacy; Fx-Cut; $raw = @((St-Raw 'ts'), (St-Raw 'dst_started_at')); St-RawSet 'chores_done' 'false'
  [void](Run-Move @('cutover'))
  Eq (St-Raw 'chores_done') 'true' 'chores_done saved again'; Eq (St-Raw 'ts') $raw[0] 'Q-cut.ts byte-equal'; Eq (St-Raw 'dst_started_at') $raw[1] 'dst_started_at byte-equal'
  Reset-World; Use-Legacy; Fx-Cut; St-RawSet 'chores_done' 'false'; St-RawSet 'dst_started_at' '"garbage"'; [void](Run-Move @('cutover')); Eq (St-Raw 'chores_done') 'true' 'chores_done saved again (unparseable dst_started_at)'; Eq (St-Raw 'dst_started_at') 'null' 'an unparseable dst_started_at is saved back as null (normalised on load like last_copy_at, R5-3)'
}
T 'L.new-lost-fence-text: after a rebuild, Q-discard''s <giờ> is new''s fwd x.start record (R5-1, a = attempt − 1 in a carry), never old''s x.freeze start, the rebuild time or the question time (D.5.3, W1-T10-F5)' {
  Start-Carry; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1; Ans 'có'; $r1 = Run-Move @('cutover'); Eq $r1.Code 70 "first ($($r1.Text))"
  $xs = Rec-Start new ($RebuildDstStartedAt -f 1); $fz = Rec-Start old fwd-1-x.freeze
  [IO.File]::Delete((StatePath)); foreach ($n in 'old', 'new') { $W[$n].MoveId.old_addr = $OldAddr; $W[$n].MoveId.new_addr = $NewAddr }
  $script:Clock = $script:Clock.AddHours(1); $rbNow = Format-Iso $script:Clock
  $rb = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rb.Code 0 "rebuild ($($rb.Text))"
  Eq (St-Raw 'dst_started_at') $xs 'rebuilt dst_started_at'; Eq (St-Raw 'ts') $fz 'rebuilt Q-cut.ts (R2-4 kept)'; Eq (St-Raw 'carry') 'true' 'carry'
  $script:Clock = $script:Clock.AddHours(3); $tq = Format-Iso $script:Clock
  Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1; [void](Run-Move @('cutover')); $g = Get-QuestionTime
  Eq $g (Expect-Gio $xs) '<giờ>'
  Ok ($g -cne (Expect-Gio $fz)) "not old's x.freeze start (the overruled rebuilt source): $g"; Ok ($g -cne (Expect-Gio $rbNow)) "not the rebuild time: $g"
  Ok ($g -cne (Expect-Gio $tq)) "not the question time: $g"; Ok ($g -notmatch $CutOffUnknown) "known: $g"
}
T 'L.pre-clock: unreadable facts on one machine refuse clock at plan and at 0c, nothing frozen (reading T10 R2-5)' {
  Add-Fault -M new -Key '^script:facts$' -Rc 0 -Out @('MOVE facts os=debian-13 arch=x86_64 systemd=257 epoch=x'); $r = Do-Plan -Want 65
  HasText 'Đồng hồ các máy lệch nhau quá 5 giây'; HasText ($ClockUnreadable -f 'new')
  Reset-World; Fx-Copied; Add-Fault -M old -Key '^script:facts$' -Rc 1 -Out @(); $r = Do-Cutover 65
  HasText 'Đồng hồ các máy lệch nhau quá 5 giây'; HasText ($ClockUnreadable -f 'old'); Eq (Sent 'old' '-x\.freeze$') 0 'nothing frozen'
}

# ============================== rev 1k3.7: the K1 budget rows (D.0.6, G.2.1; DECISION-1k6-K1budget) ==============================
function New-Hold([string]$Id, [int]$Stop, [string]$Kind = 'unit', [string[]]$Trig = @(), [string]$User = '') {
  $h = [ordered]@{ id = $Id; kind = $Kind }; if ($User) { $h['user'] = $User }
  $h['type'] = $(if ($Id -match '\.([a-z]+)$') { $Matches[1] } else { $Kind })
  $h['unit_file_state'] = 'enabled'; $h['active_state'] = 'active'; $h['sub_state'] = 'running'; $h['remain_after_exit'] = 'no'
  if ($Trig.Count) { $h['triggered_by'] = @($Trig) }
  $h['n_restarts'] = 0; $h['stop_budget_s'] = $Stop; $h['start_budget_s'] = 60; $h['listen'] = @(); $h
}
function Set-Holds([object[]]$H, [string[]]$Start, [string[]]$Stop, [string[]]$Followers = @()) { $W.Mf.holds = @($H); $W.Mf.hold_sets = [ordered]@{ enable = @($Start); start = @($Start); stop = @($Stop) }; $W.Mf.followers = @($Followers) }
function Budget-Of([string]$M, [string]$Call) { $c = @(RecCalls -All | Where-Object { $_.M -ceq $M -and $_.Call -ceq $Call }); Ok ($c.Count -ge 1) "$M $Call was not sent: $(LogNow -All)"; [int]$c[0].Budget }
function Tunnel-Names { @(foreach ($n in 'a', 'b', 'c') { [ordered]@{ name = "$n.example.com"; source = 'ingress'; class = 'tunnel'; service = 'http://127.0.0.1:8080' } }) }
T 'L.budget-freeze: x.freeze --budget = cap_s + Σ stop_budget_s of the periodic sources (kind unit, in hold_sets.stop, cron.service|*.timer|*.path) and of the same-scope holds they trigger, each once, + 30 = 1950' {
  Set-Holds @((New-Hold 'cron.service' 60), (New-Hold 'x.timer' 30), (New-Hold 'job.service' 930 -Trig 'x.timer', 'cron.service'), (New-Hold 'app.service' 120), (New-Hold 'y.timer' 40), (New-Hold 'alice:z.timer' 70 'user-unit' -User 'alice'), (New-Hold 's-job.service' 50 -Trig 'x.socket')) `
    -Start @('cron.service', 'x.timer', 'app.service', 'y.timer') -Stop @('cron.service', 'x.timer', 'job.service', 'app.service', 'alice:z.timer', 's-job.service') -Followers @('job.service', 's-job.service')
  Fx-Copied; [void](Do-Cutover -1)
  Eq (Budget-Of 'old' 'fwd-1-x.freeze') 1950 'x.freeze = 900 + 60 + 30 + 930 + 30'
}
function Fx-HealthManifest {
  $W.Mf.redis = @([ordered]@{ unit = 'redis-server.service' }, [ordered]@{ unit = 'redis-b.service' }); $W.Mf.pg = @([ordered]@{ cluster = '17/main' })
  $W.Mf.hostnames = @(Tunnel-Names) + [ordered]@{ name = 'd.example.com'; source = 'nginx'; class = 'inbound-backed' }
  $extra = @((New-Hold 'container:web' 120 'container'), (New-Hold 'linger:alice' 30 'linger' -User 'alice'), (New-Hold 'alice:container:bot' 120 'user-container' -User 'alice'))
  $W.Mf.holds = @($W.Mf.holds) + $extra; $W.Mf.hold_sets.start = @($W.Mf.hold_sets.start) + @($extra | ForEach-Object { $_.id }); $W.Mf.hold_sets.enable = @($W.Mf.hold_sets.start)
  $W.Mf.health = @([ordered]@{ project = 'p1'; health_budget_s = 135 }, [ordered]@{ project = 'p2'; health_budget_s = 30 }, [ordered]@{ project = 'p3'; health_budget_s = 30 })
  $W.Mf.guards = @([ordered]@{ project = 'p1'; kind = 'v2'; guard_timeout_s = 95; run_s = 235 }, [ordered]@{ project = 'p2'; kind = 'v2'; guard_timeout_s = 30; run_s = 170 })   # p3 has no guard
}
T 'L.budget-health: x.baseline, x.health and r.health-src --budget = 300 + 10 × (|redis[]| + |pg[]|) + 20 × tunnel names + 60 × container + 40 × linger + 60 × user-container holds of hold_sets.start + 20 × |health[]| + Σ health_budget_s = 805; with dur.x.baseline.old = 300 → 900' {
  Fx-HealthManifest; Fx-Copied; [void](Do-Cutover -1)
  Eq (Budget-Of 'old' 'fwd-1-x.baseline') 805 'x.baseline'; Eq (Budget-Of 'new' 'fwd-1-x.health') 805 'x.health'
  Reset-World; Fx-HealthManifest; $W.Dur['^x\.baseline$'] = 300; Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.final$' -Rc 1; [void](Do-Cutover 10)
  Eq (Budget-Of 'old' 'fwd-1-r.health-src') 805 'r.health-src'; Eq (Budget-Of 'old' 'fwd-1-x.baseline') 805 'x.baseline before any measure'
  [void](Do-Copy 0); [void](Do-Cutover -1); Eq (Budget-Of 'old' 'fwd-2-x.baseline') 900 'x.baseline = max(805, 3 × 300)'
}
T 'L.budget-guards: x.guards --budget = cap_s + Σ guards[].run_s + 30 = 1573 (a v2 guard_timeout_s 120 pinned as run_s 260, deal-sync 130, vps-scraper 253)' {
  $W.Mf.guards = @([ordered]@{ project = 'task'; kind = 'v2'; guard_timeout_s = 120; run_s = 260 }, [ordered]@{ project = 'deal-sync'; kind = 'legacy'; run_s = 130 }, [ordered]@{ project = 'vps-scraper'; kind = 'legacy'; run_s = 253 })
  Fx-Copied; [void](Do-Cutover -1); Eq (Budget-Of 'old' 'fwd-1-x.guards') 1573 'x.guards = 900 + 260 + 130 + 253 + 30'
}
T 'L.budget-switch: x.switch --budget = 60 + 140 × unit connectors + 140 × container connectors + 20 × tunnel names = 540' {
  $W.Mf.connectors = @([ordered]@{ id = 'cloudflared.service'; kind = 'unit' }, [ordered]@{ id = 'cloudflared-b.service'; kind = 'unit' }, [ordered]@{ id = 'container:tunnel'; kind = 'container' })
  $W.Mf.hostnames = @(Tunnel-Names) + [ordered]@{ name = 'd.example.com'; source = 'nginx'; class = 'inbound-backed' }
  Fx-Copied; [void](Do-Cutover -1); Eq (Budget-Of 'new' 'fwd-1-x.switch') 540 'x.switch = 60 + 280 + 140 + 60'
}
T 'L.budget-stop: x.stop-src, x.stop-dst and r.stop-dst --budget = Σ stop_budget_s of hold_sets.stop + 30 + 600 per Redis hold + 60 per pm2 hold + 120 per container/user-container hold = 1930' {
  $fx = {
    Set-Holds @((New-Hold 'app.service' 400), (New-Hold 'redis-server.service' 300), (New-Hold 'pm2-root.service' 100), (New-Hold 'container:web' 100 'container'), (New-Hold 'alice:container:bot' 100 'user-container' -User 'alice')) `
      -Start @('app.service', 'redis-server.service', 'pm2-root.service', 'container:web', 'alice:container:bot') -Stop @('app.service', 'redis-server.service', 'pm2-root.service', 'container:web', 'alice:container:bot')
    $W.Mf.redis = @([ordered]@{ unit = 'redis-server.service' })   # pm2 hold = pm2-*.service (B.5.9 classes, W1-T4-DG-T4-3); Redis holds = the redis[] entries (D.0.6)
  }
  & $fx; Fx-Copied; [void](Do-Cutover -1)
  Eq (Budget-Of 'old' 'fwd-1-x.stop-src') 1930 'x.stop-src = 1000 + 30 + 600 + 60 + 240'; Eq (Budget-Of 'new' 'fwd-1-x.stop-dst') 1930 'x.stop-dst'
  Reset-World; & $fx; Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.final$' -Rc 1; [void](Do-Cutover 10); Eq (Budget-Of 'new' 'fwd-1-r.stop-dst') 1930 'r.stop-dst'
}
T 'L.call-key-sites: every call id the laptop sent in this run is in the closed step list' {
  Ok ($script:AllCalls.Count -gt 0) 'no recorded call was seen in this run'
  $bad = @($script:AllCalls | Where-Object { $_ -notmatch $CallRx } | Select-Object -Unique); Ok ($bad.Count -eq 0) "ids outside the closed list: $($bad -join ', ')"
}

# ============================== end ==============================
$env:USERPROFILE = $savedProfile
Set-Location -LiteralPath ([IO.Path]::GetTempPath())
Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "fcode-move.test.ps1: $($script:pass) passed, $($script:fail) failed, $($script:skip) skipped (bash cases)"
if ($script:fail -gt 0) { exit 1 }
exit 0
