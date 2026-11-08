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
#   MV_RUN_SH=<path>          deploy-gate lib/move-run.sh for L.target-key-server-validator (the real MVR_TJS validator of c.init-new's target key; bash cases only; fails when unset)
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
     MoveId = $null; Frozen = $false; Holds = $Holds; Active = $(if ($Serving) { $Holds } else { 0 }); Enabled = $Serving; Conn = $Serving
     Rec = @{}; Order = (New-Object Collections.ArrayList); Last = $null; Running = $null; Skew = 0; Digest = @{}; Lst = @{}; Content = (New-Object Collections.Hashtable ([StringComparer]::Ordinal)); NoAcl = $false; LstOld = $false; Drop = (New-Object Collections.Hashtable ([StringComparer]::Ordinal)); Extra = @(); Os = 'debian-13'; Sha = ''; Legacy = @(); GoneRoots = @(); PinManifest = $null }   # Content/Drop: paths are case-sensitive, like Linux; GoneRoots = item roots deleted on this machine, PinManifest = the manifest it pinned (init / repin)
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
  [void]$script:Cfg2.Remove('moveTargets')   # O1: no platform_user unless a case names one (Set-PlatformUser)
  $script:Last = $null
  $script:W = @{
    old = (New-Machine 'old' $OldAddr $KeyOld 'oldhost' $true); new = (New-Machine 'new' $NewAddr $KeyNew 'newhost' $false)
    Log = (New-Object Collections.ArrayList); Calls = (New-Object Collections.ArrayList); From = 0
    Faults = (New-Object Collections.ArrayList); Answers = (New-Object Collections.Queue); Prompts = (New-Object Collections.ArrayList)
    Gh = (New-Object Collections.ArrayList); GhLog = (New-Object Collections.ArrayList); KeygenLog = (New-Object Collections.ArrayList); ToolLog = (New-Object Collections.ArrayList)
    BoxLog = (New-Object Collections.ArrayList); Mf = (New-Manifest); Mfs = @{}; HealthFail = @{}; Tunnel = $null; CheckNoPin = $false; StoredLf = $false; CheckProjects = @(); PlanStdin = (New-Object Collections.ArrayList); PlanN = 0
    Pf = @('INV target user=quoc uid=1000 home-nonskel=1', 'INV target addr=198.51.100.20', 'INV target platform=0', 'INV target stop_budget_s=120'); PfCode = 0
    CheckOut = @('INV ok'); CheckCode = 0; CheckOnlyOut = @('INV ok'); CheckOnlyCode = 0; PlanHook = $null; PlanOut = @('INV ok'); PlanCode = 0
    NewGate = (New-Object Collections.Queue); TcpFail = @{}; LoginRc = 0; LoginErr = ''; CoderUp = $true; Dur = @{}; Sleeps = 0
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
function Add-Fault([string]$M = '.', [string]$Key, [int]$Rc = 1, [string[]]$Out = $null, [int]$N = 1, [string]$Mode = '', [scriptblock]$Do = $null, [switch]$Effect, [int]$Left = 2, [int]$Skip = 0) {
  [void]$script:W.Faults.Add(@{ Skip = $Skip; Seen = 0; M = $M; Key = $Key; Rc = $Rc; Out = $Out; N = $N; Mode = $Mode; Do = $Do; Effect = [bool]$Effect; Left = $Left })
}
function Get-Fault([string]$M, [string]$Key) {
  foreach ($f in $script:W.Faults) { if ($f.N -ne 0 -and $M -match "\A(?:$($f.M))\z" -and $Key -match $f.Key) { $f.Seen++; if ($f.Skip -gt 0) { $f.Skip--; continue }; if ($f.N -gt 0) { $f.N-- }; return $f } }
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
  elseif ($remote -ceq 'true') { $e.Kind = 'login'; Log "$($m.Name) login"; $lf = Get-Fault $m.Name 'login'; $r = if ($lf -and $lf.Mode -eq 'down') { New-Res 255 @() } else { New-Res $W.LoginRc @() }; if ($W.LoginErr) { $r.Err = $W.LoginErr } }
  else { [void]$W.Violations.Add("unexpected ssh remote command: $remote"); $r = New-Res 1 @() }
  $e.Code = $r.Code; $e.Out = $r.Out
  $r
}

function Get-StatusFields($m) {
  # R16 r8 (server status rule): `call` / `call_state` name the RUNNING call whenever a unit runs, whatever the record timestamps say (same-second ties); otherwise the latest record
  $mi = $m.MoveId; $last = $(if ($m.Running) { $m.Running.Call } else { $m.Last }); $cs = '-'; $rc = '-'
  if ($last) { $rec = $m.Rec[$last]; if ($m.Running -and $m.Running.Call -ceq $last) { $cs = 'running'; if ($m.Running.RcRecorded) { $rc = "$($m.Running.Rc)" } } elseif ($null -eq $rec.Rc) { $cs = 'interrupted' } elseif ([int]$rec.Rc -eq 0) { $cs = 'done'; $rc = '0' } else { $cs = 'failed'; $rc = "$($rec.Rc)" } }   # a unit that has written its rc but not yet exited (_mvr_unit_end) is `running` WITH its rc (the completion window)
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
  $script:W.LastSha = Get-Sha256Hex $b; $script:W.LastManifest = $json; $script:W.Mfs[$script:W.LastSha] = $json
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
    if ($flt) { if ($flt.Mode -eq 'timeout') { return (New-Res 124 @()) }; if ($flt.Mode -eq 'down') { return (New-Res 255 @()) }; if ($flt.Mode -eq 'nomove') { return (New-Res 65 @('GATE_ERROR gate installed without exactly one project argument', 'GATE_EXIT 65')) } }   # nomove: this machine's gate has no --move
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
      $flt = Get-Fault $m.Name 'plan:check'; if ($flt) { if ($flt.Mode -eq 'down') { return (New-Res 255 @()) }; if ($flt.Mode -eq 'noexit') { return (New-Res 0 @($flt.Out)) }; return (New-Res $flt.Rc (@($flt.Out) + "GATE_EXIT $($flt.Rc)")) }
      return (New-Res $W.CheckCode (@($W.CheckOut) + "GATE_EXIT $($W.CheckCode)"))
    }
    if ($sw['check-only']) {
      $e.Step = 'plan:check-only'; Log "$($m.Name) plan:check-only"; $script:Clock = $script:Clock.AddSeconds(7)
      foreach ($k in 'dir', 'attempt', 'sha', 'serving') { if (-not $f.ContainsKey($k)) { [void]$W.Violations.Add("plan <id> --check-only lacks --$k (D.0.1)") } }
      # D.0.1 / move-run.sh (W1-T10-G16): `mv_moveid check call <id> <dir> <attempt> <sha>` against the stored move-id; the only exemption is a manual back's 0c (--dir back --attempt <stored + 1>) against a stored FWD move-id,
      # which is then compared as (fwd, stored). Any other dir/attempt is compared in full: other-move / no-move, what=dir, what=attempt, what=sha. A machine with no move-id answers no-move (mode call); an empty pin never matches a sha.
      if ($m.MoveId) {
        $mi0 = $m.MoveId; $cd = [string]$f['dir']; $ca = [string]$f['attempt']
        if ($cd -ceq 'back' -and [string]$mi0.dir -ceq 'fwd' -and "$($mi0.attempt)" -match '\A[0-9]+\z' -and $ca -ceq "$([int]$mi0.attempt + 1)") { $cd = [string]$mi0.dir; $ca = "$($mi0.attempt)" }
        $why = if ($mi0.id -cne $id) { if ($mi0.state -ceq 'open') { "other-move id=$($mi0.id)" } else { 'no-move' } } elseif ([string]$mi0.dir -cne $cd) { 'move-id-mismatch what=dir' } elseif ("$($mi0.attempt)" -cne $ca) { 'move-id-mismatch what=attempt' } elseif ([string]$f['sha'] -cne [string]$m.Sha) { 'move-id-mismatch what=sha' } else { $null }
        if ($why) { Log "$($m.Name) plan:check-only refused $why"; return (New-Res 65 @("MOVE error $why", 'GATE_EXIT 65')) }
      } else { Log "$($m.Name) plan:check-only refused no-move"; return (New-Res 65 @('MOVE error no-move', 'GATE_EXIT 65')) }
      $flt = Get-Fault $m.Name 'plan:check-only'; if ($flt) { if ($flt.Mode -eq 'down') { return (New-Res 255 @()) }; if ($flt.Mode -eq 'noexit') { return (New-Res 0 @($flt.Out)) }; return (New-Res $flt.Rc (@($flt.Out) + "GATE_EXIT $($flt.Rc)")) }
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
    $flt = Get-Fault $m.Name 'plan:full'; if ($flt) { $out = @($flt.Out); $code = $flt.Rc; if ($flt.Mode -ceq 'down') { return (New-Res 255 @()) }; if ($flt.Mode -ceq 'noexit') { return (New-Res 0 @($out)) }; if ($flt.Mode -ceq 'nomanifest') { return (New-Res $code (@($out) + "GATE_EXIT $code")) } }   # nomanifest: a refusal the server prints without a manifest (map-invalid, _mvp_finalize)
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
  # D.0.1 / K1 (ruling 06/11 (33)): a call that executes carries the sha of the manifest THIS machine holds (mode call; init, init --repin and p.* are not compared).
  # A re-sent id whose record is done is a replay: it executes nothing, so only id/dir/attempt are compared (above) and --sha is ignored, in the gate and in the argv compare.
  $recDone = ($m.Rec.ContainsKey($call) -and $null -ne $m.Rec[$call].Rc -and [int]$m.Rec[$call].Rc -eq 0)
  if (-not $isInit -and -not ($verb -ceq 'init' -and $sw['repin']) -and $step -notlike 'p.*' -and -not $recDone -and $f['sha'] -cne [string]$m.Sha) { Log "$tag sha"; return (New-Res 65 @('MOVE error move-id-mismatch what=sha', 'GATE_EXIT 65')) }   # a machine with no pin refuses every sha (cur="" in mv_moveid check)
  $norm = @(); for ($i = 0; $i -lt $wd.Count; $i++) { $x = [string]$wd[$i]; if ($x.StartsWith('--') -and ($x.Substring(2) -in $IgnoredFlags -or ($recDone -and $x -ceq '--sha'))) { $i++; continue }; $norm += $x }
  $normS = $norm -join ' '
  if ($m.Rec.ContainsKey($call)) {
    $rec = $m.Rec[$call]
    $recArgv = if ($recDone) { [string]$rec.Argv -replace ' --sha [0-9a-f]+', '' } else { $rec.Argv }
    if ($rec.Argv -cne '?' -and $recArgv -cne $normS) { Log "$tag call-argv"; return (New-Res 65 @('MOVE error bad-request why=call-argv', 'GATE_EXIT 65')) }
    if ($recDone) { $e.Replay = $true; Log "$tag (replay)"; return (New-Res 0 (@($rec.Out) + "MOVE call id=$call rc=0 dur_s=$($rec.Dur)" + 'GATE_EXIT 0')) }
  }
  # S4 (R16 rework): init and init --repin pin the --sha flag; the flag must be the sha256 of the stdin manifest (bad-request why=manifest-sha, 65, nothing written)
  if ($isInit -or ($verb -ceq 'init' -and $sw['repin'])) {
    $ok = $false; $ref = $W.Mfs[[string]$f['sha']]
    if ($ref) { try { $sm = ($Stdin | ConvertFrom-Json).manifest; $ok = ((ConvertTo-Json -InputObject $sm -Depth 12 -Compress) -ceq (ConvertTo-Json -InputObject (ConvertFrom-Json $ref) -Depth 12 -Compress)) } catch { $ok = $false } }
    if (-not $ok) { Log "$tag manifest-sha"; return (New-Res 65 @('MOVE error bad-request why=manifest-sha', 'GATE_EXIT 65')) }
  }
  # Mode never: the laptop died before the call reached the machine; nothing is written (no move-id flag, no record, no hook), and the call is not counted as sent
  foreach ($nf in @($W.Faults)) { if ($nf.Mode -ceq 'never' -and $nf.N -ne 0 -and $m.Name -match "\A(?:$($nf.M))\z" -and $call -match $nf.Key) { if ($nf.N -gt 0) { $nf.N-- }; [void]$W.Calls.Remove($e); throw "laptop gone: $call never reached $($m.Name)" } }
  Log $tag
  if ($mi) { if ($f.ContainsKey('mark')) { $mi.mark = $(if ($markNull) { $null } else { $mark }) }; foreach ($k in 'phase', 'serving', 'dst-started') { if ($f.ContainsKey($k)) { $mi[$k.Replace('-', '_')] = $f[$k] } } }
  $hk = $W.Hooks[$step]; if ($hk) { & $hk $m $e }
  $flt = Get-Fault $m.Name $call
  $rc = 0; $out = Get-DefaultOut $m $step $call; $eff = $true
  if ($step -cin 'x.health', 'x.switch') { $hv = Get-HealthVerdict $step $Stdin; $out = @($hv.Out); $rc = $hv.Rc }   # the real check against the baseline the laptop sent on stdin (B.14.7); a Fault overrides it below
  # a missing source root: rsync fails (move-xfer.sh). The server's back PRE pass skips an item whose root is gone on the sender (`MOVE item <id> kind=<k> state=done why=item-gone`, rc 0, nothing copied); a fwd pass and every `final` pass against a pinned manifest that still lists it fail
  if ($step -like 'c.transfer.*' -or $step -ceq 'x.final') { if (@($m.GoneRoots).Count -and $m.PinManifest) { $goneIt = @(@($m.PinManifest.items) | Where-Object { $_ -and @($m.GoneRoots) -ccontains [string]$_.root })
      if ($goneIt.Count -and $step -like 'c.transfer.*' -and $call -like 'back-*') { $out = @($goneIt | ForEach-Object { "MOVE item $($_.id) kind=$($_.kind) state=done why=item-gone" }) }
      elseif ($goneIt.Count) { $out = @("MOVE error rsync-failed why=missing-root path=$($goneIt[0].root)"); $rc = 1 } } }
  if ($flt) { $rc = $flt.Rc; if ($null -ne $flt.Out) { $out = @($flt.Out) }; $eff = ($rc -eq 0 -or $flt.Effect -or ($step -ceq 'x.freeze' -and $rc -eq 75)); if ($flt.Do) { & $flt.Do $m $e } }
  $dur = 5; foreach ($k in $W.Dur.Keys) { if ($step -match $k) { $dur = $W.Dur[$k] } }
  $rec = @{ Rc = $rc; Out = @($out); Dur = $dur; Argv = $normS; Start = (Format-Iso $script:Clock.AddSeconds([int]$W.StartSkew)); End = (Format-Iso $script:Clock.AddSeconds($dur)) }   # StartSkew: the server stamps a record's start this many seconds after the laptop's clock reading (network and queue time)
  $m.Rec[$call] = $rec; [void]$m.Order.Add($call); $m.Last = $call
  $script:Clock = $script:Clock.AddSeconds($dur)   # the fake clock moves by each recorded call's dur: every record has its own Start, "now" is later than all of them
  if ($flt -and $flt.Mode -ceq 'running') { $rec.Rc = $null; $m.Running = @{ Call = $call; Left = $flt.Left; Rc = $rc; Step = $step; Verb = $verb; F = $f; Sw = $sw; Id = $id; Stdin = $Stdin }; return (New-Res 124 @()) }
  if ($eff) { Apply-Effects $m $step $verb $f $sw $id $Stdin }
  if ($flt -and $flt.Mode -ceq 'noexit') { return (New-Res 255 @($out)) }
  if ($flt -and $flt.Mode -ceq 'timeout') { $rec.Rc = 143; return (New-Res 124 @()) }
  if ($flt -and $flt.Mode -ceq 'down') { $m.Up = $false; return (New-Res 255 @()) }
  if ($flt -and $flt.Mode -ceq 'kill') { throw 'laptop gone: the call ran to the end on the machine, its answer never arrived' }
  New-Res $rc (@($out) + "MOVE call id=$call rc=$rc dur_s=$dur" + "GATE_EXIT $rc")
}
# ---- health (B.14.7): x.baseline prints one `MOVE item <check> kind=health state=ok|failed [class=<d>]` line per check; the laptop sends them on the stdin of x.health and x.switch, which gate only on a check that did not
# fail in the baseline (a check with no baseline line gates); a tunnel name is judged by its status class against the baseline class. Knobs: W.HealthFail[<hold id>] = $true (failing now), W.Tunnel = @{ Name; Code } (the live code).
function Get-HealthChecks { @(@($script:W.Mf.holds) | Where-Object { $_ -and $_.kind -ceq 'unit' } | ForEach-Object { [string]$_.id }) }
function Get-HealthBaseline {
  $o = @(); foreach ($id in Get-HealthChecks) { $o += "MOVE item $id kind=health state=$(if ($script:W.HealthFail[$id]) { 'failed' } else { 'ok' })" }
  $t = $script:W.Tunnel; if ($t) { $c = "$($t.BaseCode)"; $o += "MOVE item name:$($t.Name) kind=health state=$(if ($c -match '^[1-4]') { 'ok' } else { 'failed' }) class=$($c.Substring(0, 1))" }
  $o
}
function Get-HealthVerdict([string]$Step, [string]$Stdin) {
  $base = @{}; $cls = @{}
  foreach ($l in @($Stdin -split '\r?\n')) { if ($l -cmatch '\AMOVE item (\S+) kind=health state=(\S+)(?: class=(\S+))?\z') { $base[$Matches[1]] = $Matches[2]; if ($Matches[3]) { $cls[$Matches[1]] = $Matches[3] } } }
  $o = @(); $fail = 0
  if ($Step -ceq 'x.health') {
    foreach ($id in Get-HealthChecks) {
      if ($script:W.HealthFail[$id]) { $o += "MOVE item $id kind=health state=failed"; if ($base[$id] -ceq 'failed') { $o += "INV warn health-baseline check=$id" } else { $fail++ } } else { $o += "MOVE item $id kind=health state=ok" }
    }
    if ($fail) { $o += "MOVE error health failed=$fail"; return @{ Rc = 69; Out = $o } }
    return @{ Rc = 0; Out = $o }
  }
  $t = $script:W.Tunnel
  if ($t) {
    $n = "name:$($t.Name)"; $c = "$($t.Code)"; $want = $cls[$n]
    $bad = if ($c -match '^(52[0-9]|530|000)$') { $true } elseif ($want -and $c.Substring(0, 1) -cne $want) { $true } elseif (-not $want -and $c -notmatch '^[1-4]') { $true } else { $false }
    $o += "MOVE item $n kind=health state=$(if ($bad) { 'failed' } else { 'ok' })"
    if ($bad) { $o += 'MOVE error switch-failed why=name'; return @{ Rc = 1; Out = $o } }
  }
  @{ Rc = 0; Out = $o }
}
function Get-DefaultOut($m, [string]$Step, [string]$Call) {
  if ($Step -match '^(c\.verify\.[0-9]+|x\.verify)$') {
    $o = @(); $lst = @()
    foreach ($it in @($script:W.Mf.items)) {
      $d = $m.Digest[$it.id]; $l = if ($d) { $d } else { 'aaaaaaaaaaaa' }
      $o += "MOVE digest item=$($it.id) n=$($it.inodes) list=$l sum=bbbbbbbbbbbb"
      # ruling 06/11 (32): the last field is the file's sha256 for the sum set (here f1..f5), empty for the rest; Content[path] overrides it, LstOld drops the field (an older server)
      $lst += "# item=$($it.id)"
      $names = @(1..25 | ForEach-Object { "f$_" }) + @($m.Extra | Where-Object { $_.StartsWith("$($it.root)/", [StringComparison]::Ordinal) } | ForEach-Object { $_.Substring($it.root.Length + 1) })
      foreach ($nm in $names) {
        $pa = "$($it.root)/$nm"; if ($m.Drop.ContainsKey($pa)) { continue }
        $ln = "$pa`tf`t10`t0644`troot`troot`t1700000000000000000`t`t" + $(if ($d -and $nm -ceq 'f3' -and -not $m.NoAcl) { 'user:bob:r--' } else { '' })
        if (-not $m.LstOld) { $sh = if ($m.Content.ContainsKey($pa)) { [string]$m.Content[$pa] } elseif ($nm -cin 'f1', 'f2', 'f3', 'f4', 'f5' -or $m.Extra -ccontains $pa) { ('ab') * 32 } else { '' }; $ln += "`t$sh" }
        $lst += $ln
      }
    }
    $m.Lst[$Call] = $lst; return $o
  }
  if ($Step -ceq 'x.check') {   # the re-pin (B.14.6): the manifest of the frozen machine differs from the pinned one (hold states, sizes after the freeze), so every x.check that returns 0 changes the sha
    $h = @($script:W.Mf.holds); if ($h.Count) { $h[0].n_restarts = [int]$h[0].n_restarts + 1 } else { $script:W.Mf.identity.swap_mb = [int]$script:W.Mf.identity.swap_mb + 1 }
    $gw = @(); if (@($m.GoneRoots).Count) { foreach ($r in @($m.GoneRoots)) { if (@(@($script:W.Mf.items) | Where-Object { [string]$_.root -ceq $r }).Count) { $gw += "INV warn item-gone path=$r" } }; $script:W.Mf.items = @(@($script:W.Mf.items) | Where-Object { @($m.GoneRoots) -cnotcontains [string]$_.root }) }   # E-R31: an item whose root is gone on the checked machine is dropped from the re-pinned manifest
    return @(@(Get-ManifestLine $null) + $gw + @($script:W.CheckProjects | ForEach-Object { "INV warn back-new-only kind=project name=$_" }))   # CheckProjects: the project registry names new lists at x.check (a back)
  }
  if ($Step -ceq 'x.baseline') { return @(Get-HealthBaseline) }
  @("LOG $Step done")
}
function Apply-Effects($m, [string]$Step, [string]$Verb, $f, $sw, [string]$Id, [string]$Stdin) {
  switch -regex ($Step) {
    '^(c\.init-(old|new)|b\.init-(new|old))$' {
      $j = $null; try { $j = $Stdin | ConvertFrom-Json } catch { [void]$script:W.Violations.Add("init stdin is not JSON") }
      $m.MoveId = @{ id = $Id; role = $f['role']; dir = $f['dir']; attempt = [int]$f['attempt']; state = 'open'; mark = $(if ($f['mark'] -and $f['mark'] -cne 'null') { $f['mark'] } else { $null }); phase = $f['phase']; serving = $f['serving']; dst_started = $f['dst-started']; old_addr = $(if ($j) { $j.old_addr }); new_addr = $(if ($j) { $j.new_addr }) }
      $m.InitStdin = $j; $m.Sha = $f['sha']; if ($j) { $m.PinManifest = $j.manifest }
      if ($Step -ceq 'c.init-new' -and $j -and $j.PSObject.Properties['target'] -and -not $m.Target) { $m.Target = ConvertTo-Json -InputObject $j.target -Depth 10 -Compress }   # MV_DIR/target.json, written only when absent (D.0.9)
      if ($Step -ceq 'c.init-new' -and $j -and $j.PSObject.Properties['target']) { $m.TargetIn = ConvertTo-Json -InputObject $j.target -Depth 10 -Compress }   # the call's recorded stdin: the newest c.init-new record's `in`
      if ($f['role'] -ceq 'new' -and $f['dir'] -ceq 'fwd') { $m.Frozen = $true; $m.Active = 0; $m.Enabled = $false }
    }
    '^(c\.repin\.[0-9]+|x\.repin)$' {   # _mvr_put_manifest stores the --sha FLAG as manifest.json.sha256 (the gate has refused a flag that is not the sha256 of the stdin manifest, S4)
      $m.Sha = $f['sha']
      try { $m.RepinStdin = $Stdin | ConvertFrom-Json; $m.PinManifest = $m.RepinStdin.manifest } catch { [void]$script:W.Violations.Add('repin stdin is not JSON') }
    }
    '^x\.check$' { if (-not $script:W.CheckNoPin) { $m.Sha = $script:W.LastSha; $m.PinManifest = ($script:W.LastManifest | ConvertFrom-Json) } }   # x.check rc 0 writes the re-pinned manifest and its sha on the machine that ran it; CheckNoPin = a gate that wrote no pin (the defensive case of a garbled answer)
    '^(c\.prepare\.[0-9]+|x\.prepare-id)$' { $m.Hostname = $script:W.Mf.identity.hostname }
    '^x\.freeze$' { $m.Frozen = $true }
    '^(x\.unfreeze\.[0-9]+|r\.unfreeze-src)$' { $m.Frozen = $false }
    '^(x\.stop-src|x\.stop-dst|r\.stop-dst)$' { $m.Active = 0; $m.Enabled = $false; $m.Conn = $false }
    '^x\.start$' { $m.Active = $m.Holds }
    '^x\.enable\.[0-9]+$' { $m.Active = $m.Holds; $m.Enabled = $true; if ($m.MoveId) { $pf = "$($m.MoveId.dir)-$($m.MoveId.attempt)-"; if ($m.Rec.ContainsKey("${pf}r.start-src") -or $m.Rec.ContainsKey("${pf}x.stop-src")) { $m.Conn = $true } } }   # move-run.sh:481-483: x.enable.N runs `mvh_start rollback` (unit connectors too) when the machine holds the (dir, attempt)'s r.start-src or x.stop-src record, plain enable otherwise
    '^r\.start-src$' { $m.Active = $m.Holds; $m.Enabled = $true; $m.Conn = $true }   # mvh_start rollback: starts the unit connectors too
    '^f\.(old|new)$' { if ($m.MoveId) { $m.MoveId.state = 'finished' }; $m.Frozen = $false }
    '^a\.(old|new)$' { if ($m.MoveId) { $m.MoveId.state = 'aborted' }; $m.Frozen = $false }
    '^x\.switch$' { $m.Switched = $true; $m.Conn = $true }
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
      foreach ($c in $m.Order) { $r = $m.Rec[$c]; $sn = if ("$($r.Argv)" -cmatch '--since (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)') { $Matches[1] } else { '-' }; $sh = if ("$($r.Argv)" -cmatch '--sha ([0-9a-f]{64})') { $Matches[1] } else { '-' }; $o += "MOVE record id=$c start=$(if ($r.Start) { $r.Start } else { '-' }) end=$(if ($r.End) { $r.End } else { '-' }) rc=$(if ($null -ne $r.Rc) { $r.Rc } else { '-' }) since=$sn sha=$sh" }   # since= / sha= = the --since / --sha word of the record's argv, like the server's rebuild read
      # the machine's own pin (manifest.json + manifest.json.sha256, D.0.10): the manifest whose sha it pinned; the plan's last one when it pinned none
      # the stored manifest.json holds exactly the hashed bytes (R16 r4 server); StoredLf = an older machine: the text plus a final LF (jsontool's output) under the sha256 of the text without it
      if ($m.Sha -and $W.Mfs.ContainsKey($m.Sha)) { $mb = $utf8.GetBytes([string]$W.Mfs[$m.Sha] + $(if ($W.StoredLf) { "`n" } else { '' })); $o += "MOVE manifest sha=$($m.Sha) gz64=$(Get-Gz64 $mb)" } else { $o += (Get-ManifestLine $null) }
      if ($m.Target) { $o += "MOVE target $($m.Target)" }   # new only: c.init-new kept it (D.0.10)
      if ($m.TargetIn) { $o += "MOVE target-in $($m.TargetIn)" }   # the `target` key of the newest run/*-c.init-new/in record (the call's recorded stdin; written when the call began, before MV_DIR/target.json): the snapshot a rebuild falls back on (final7 :2)
      if (-not $W.RebuildNoProbe) { $pl = if (@($W.Pf | Where-Object { $_ -ceq 'INV target platform=1' }).Count) { 1 } else { 0 }; $o += "INV target platform=$pl" }   # preflight's probe lines (shared, B.5.2): the platform answer of this machine; RebuildNoProbe = an older rebuild script without the line
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
    Log "gh $t"; if ($W.GhHook -and $t -match $GhForm.RepoList) { & $W.GhHook }   # GhHook: a case's side effect at the push scan (the one gh call of a rebuild, after its reads)
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
# the recorded out of a fixture record: the real x.check prints the re-pinned `MOVE manifest sha= gz64=` line (D.4 step 3), which a replay returns
function Get-RecOut([string]$Call) { if ($Call -match '-x\.check$') { return @(Get-ManifestLine $null) }; if ($Call -match '-x\.baseline$') { return @(Get-HealthBaseline) }; @("LOG $Call") }
# a recorded call whose unit still runs (its record has no rc yet); the fake attaches when the same id comes again
function Set-Running([string]$M, [string]$Call, [int]$Left = 1000, [int]$Rc = 0, [switch]$Tie, [switch]$RcRecorded) {   # Left = the status polls the unit survives (each status answer of the machine counts one); Rc = its rc when it ends; -Tie = a same-second tie: the call before it stays `Last`; -RcRecorded = the completion window: the unit has written its rc but still runs, status shows call_state=running AND the rc
  $mc = $script:W[$M]; $st = $Call -replace '^(fwd|back)-[0-9]+-', ''
  $mc.Rec[$Call] = @{ Rc = $null; Out = @(Get-RecOut $Call); Dur = 5; Argv = '?'; Start = ''; End = '' }; [void]$mc.Order.Remove($Call); [void]$mc.Order.Add($Call); if (-not $Tie) { $mc.Last = $Call }
  $mc.Running = @{ Call = $Call; Left = $Left; Rc = $Rc; Step = $st; Verb = ''; F = @{}; Sw = @{}; Id = (Id); Stdin = ''; RcRecorded = [bool]$RcRecorded }
}
function Fx-RolledBack { Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Rc 1; [void](Do-Cutover 10); Eq (Get-St).phase 'rolled-back' 'fixture rolled-back' }
function Id { (Get-St).move_id }
function Add-Rec([string]$M, [string]$Call, [int]$Rc = 0) { $mc = $script:W[$M]; $mc.Rec[$Call] = @{ Rc = $Rc; Out = @(Get-RecOut $Call); Dur = 5; Argv = '?'; Start = ''; End = '' }; [void]$mc.Order.Add($Call); $mc.Last = $Call }
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
T 'L.plan-state: with --map <file> the laptop still prepends every default line before the file''s lines, map.txt keeps them and the copy re-plan sends them again (B.14.2, CONTRACT LIST map-defaults; ruling 05/11 (27) 2: no certs exclude)' {
  $mf = Join-Path $Root ('map-' + [guid]::NewGuid().ToString('N') + '.txt'); [IO.File]::WriteAllText($mf, "exclude pkg chromium`n", $utf8)
  [void](Do-Plan -Extra @('--map', $mf)); Remove-Item -LiteralPath $mf -Force
  $in = @($W.PlanStdin[-1]); $d = @('exclude user dino', 'exclude unit velh-pilot-hourly.timer')
  foreach ($l in $d) { Ok ($in -ccontains $l) "plan stdin lacks the default [$l]: $($in -join ' | ')"; Ok ([Array]::IndexOf($in, $l) -lt [Array]::IndexOf($in, 'exclude pkg chromium')) "the default [$l] comes before the map file's lines: $($in -join ' | ')" }
  $mt = @([IO.File]::ReadAllText((Join-Path (MoveDir) 'map.txt')) -split "`r?`n")
  foreach ($l in @($d) + 'exclude pkg chromium') { Ok ($mt -ccontains $l) "map.txt lacks [$l]: $($mt -join ' | ')" }
  [void](Do-Copy); $n0 = $W.PlanStdin.Count; [void](Do-Copy 0); Ok ($W.PlanStdin.Count -gt $n0) 'the copy re-run re-plans (D.3)'
  $in = @($W.PlanStdin[-1]); foreach ($l in @($d) + 'exclude pkg chromium') { Ok ($in -ccontains $l) "re-plan stdin lacks [$l]: $($in -join ' | ')" }
}
T 'L.plan-default-map: the default map equals CONTRACT `LIST map-defaults` (MV_CONTRACT) and is exactly `exclude user dino` and `exclude unit velh-pilot-hourly.timer`: no `exclude /etc/ssl/certs` (nor any /etc/ssl/certs line) in Get-MoveDefaultMap, in the plan stdin, in map.txt, in the copy re-plan or with --map (B.14.2, ruling 05/11 (27) F-T13-fwd6-snakeoil: the snakeoil pem travels with its key)' {
  $p = $env:MV_CONTRACT
  Ok ($p -and (Test-Path -LiteralPath $p)) "MV_CONTRACT must name deploy-gate docs/move/CONTRACT.md (got [$p])"
  $cm = [regex]::Match(([IO.File]::ReadAllText($p) -replace "`r`n", "`n"), '(?m)^LIST map-defaults: (.+)$'); Ok $cm.Success 'CONTRACT has no LIST map-defaults'
  $want = (@($cm.Groups[1].Value.Trim() -split '\s*\|\s*') -join '|')
  Eq $want 'exclude user dino|exclude unit velh-pilot-hourly.timer' 'CONTRACT LIST map-defaults'
  $dm = @(Get-MoveDefaultMap)
  Eq ($dm -join '|') $want 'Get-MoveDefaultMap = CONTRACT LIST map-defaults'
  [void](Do-Plan)
  $in = @($W.PlanStdin[-1]); $pre = @($in | Where-Object { $_ -cmatch '\Aexclude ' })
  Eq ($pre -join '|') $want "plan stdin map lines: $($in -join ' | ')"
  Ok (@($in | Where-Object { $_ -match 'ssl/certs' }).Count -eq 0) "plan stdin names /etc/ssl/certs: $($in -join ' | ')"
  $mt = @([IO.File]::ReadAllText((Join-Path (MoveDir) 'map.txt')) -split "`r?`n" | Where-Object { $_ })
  Eq ($mt -join '|') $want 'map.txt'
  Reset-World
  $mf = Join-Path $Root ('map-' + [guid]::NewGuid().ToString('N') + '.txt'); [IO.File]::WriteAllText($mf, "exclude pkg chromium`n", $utf8)
  [void](Do-Plan -Extra @('--map', $mf)); Remove-Item -LiteralPath $mf -Force
  $in = @($W.PlanStdin[-1]); Ok (@($in | Where-Object { $_ -match 'ssl/certs' }).Count -eq 0) "plan --map stdin names /etc/ssl/certs: $($in -join ' | ')"
  [void](Do-Copy); $n0 = $W.PlanStdin.Count; [void](Do-Copy 0); Ok ($W.PlanStdin.Count -gt $n0) 'the copy re-run re-plans (D.3)'
  $in = @($W.PlanStdin[-1]); Ok (@($in | Where-Object { $_ -match 'ssl/certs' }).Count -eq 0) "re-plan stdin names /etc/ssl/certs: $($in -join ' | ')"
}
# O1 (ruling 04/11 (3) 5, CONTRACT §4.1): the laptop's config.json key moveTargets.<ssh alias>.platform_user, as ConvertFrom-Json gives it
function Set-PlatformUser($Old, $New) {
  $o = [ordered]@{}; if ($null -ne $Old) { $o[$OldAlias] = [pscustomobject]@{ platform_user = $Old } }; if ($null -ne $New) { $o[$NewAlias] = [pscustomobject]@{ platform_user = $New } }
  $script:Cfg2['moveTargets'] = [pscustomobject]$o
}
function PuLines($Calls) { @(foreach ($c in @($Calls)) { @("$($c.Stdin)" -split "`n" | Where-Object { $_ -cmatch '\Aplatform-user' }) }) }
function PlanPuLines { @(foreach ($s in $script:W.PlanStdin) { @($s | Where-Object { $_ -cmatch '\Aplatform-user' }) }) }
# CONTRACT §4.1 / D.0.9: the platform-user line is the LAST stdin line, after the idmap lines (review t10f F2)
function PuLast([string[]]$In, [string]$Want, [string]$What) {
  $in = @($In | Where-Object { $_ }); Eq $in[-1] $Want "$What the last stdin line: $($in -join ' | ')"
  Eq (@($in | Where-Object { $_ -cmatch '\Aplatform-user' }).Count) 1 "$What one platform-user line"
  $ix = @(for ($i = 0; $i -lt $in.Count; $i++) { if ($in[$i] -cmatch '\Aidmap ') { $i } }); Ok ($ix.Count -ge 1) "$What holds an idmap line: $($in -join ' | ')"
}
T 'L.plan-platform-user: old.platform_user set in config.json sends exactly one stdin line platform-user <old''s name>, as the last line after the idmap lines, to plan <id> on old (the copy re-plan, plan --check-only and x.check on old too) and state.json keeps old.platform_user and new.platform_user; in fwd no call to new carries it; a manual back sends platform-user <new''s name> last to plan --check-only and x.check on new, none to old, none when new''s key is unset (ruling 04/11 (3) 5, R6-CONTRACT O1 fix 04/11, CONTRACT §4.1)' {
  $idl = 'MOVE item idmap:user:svc kind=prepare state=mapped src_id=105 dst_id=110'
  Set-PlatformUser 'quoc' 'admin'; [void](Do-Plan)
  Eq ((PlanPuLines) -join ' | ') 'platform-user quoc' 'plan stdin: one platform-user line with old''s name'; Eq @($W.PlanStdin[-1])[-1] 'platform-user quoc' 'plan stdin: the last line'
  $s = Get-St; Eq "$($s.old.platform_user)" 'quoc' 'state old.platform_user'; Eq "$($s.new.platform_user)" 'admin' 'state new.platform_user'
  Add-Fault -M new -Key '-c\.prepare\.1$' -Rc 0 -Out @($idl); [void](Do-Copy 0); Ok (@(@((Get-St).idmap) | Where-Object { $_.name -ceq 'svc' }).Count -eq 1) 'the idmap entry is in state'
  $n0 = $W.PlanStdin.Count; [void](Do-Copy 0); Ok ($W.PlanStdin.Count -gt $n0) 'the copy re-run re-plans'
  PuLast @($W.PlanStdin[-1]) 'platform-user quoc' 're-plan:'
  [void](Do-Cutover)
  foreach ($st in 'plan:check-only', 'x.check') {
    $cs = @($W.Calls | Where-Object { $_.M -ceq 'old' -and $_.Step -ceq $st }); Ok ($cs.Count -ge 1) "$st on old was sent: $(LogNow)"
    foreach ($c in $cs) { PuLast @("$($c.Stdin)" -split '\r?\n') 'platform-user quoc' "$st on old:" }
  }
  Eq (@(PuLines @($W.Calls | Where-Object { $_.M -ceq 'new' })).Count) 0 'fwd: no call to new carries a platform-user line'
  Reset-World; Set-PlatformUser 'quoc' 'admin'; Fx-Planned; Add-Fault -M new -Key '-c\.prepare\.1$' -Rc 0 -Out @($idl); [void](Do-Copy 0); [void](Do-Cutover); Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "back exit ($($r.Text))"
  $bk = @(for ($i = $W.CallFrom; $i -lt $W.Calls.Count; $i++) { $W.Calls[$i] })
  $cs = @($bk | Where-Object { $_.M -ceq 'new' -and $_.Step -cin 'plan:check-only', 'x.check' }); Ok ($cs.Count -ge 1) "a manual back checks on new: $(LogNow)"
  foreach ($c in $cs) { PuLast @("$($c.Stdin)" -split '\r?\n') 'platform-user admin' "back $($c.Step) on new:" }
  Eq (@(PuLines @($bk | Where-Object { $_.M -ceq 'old' })).Count) 0 'back: no call to old carries a platform-user line'
  Reset-World; Set-PlatformUser 'quoc' $null; Fx-BackDone
  $bk = @(for ($i = $W.CallFrom; $i -lt $W.Calls.Count; $i++) { $W.Calls[$i] }); Ok (@($bk | Where-Object { $_.M -ceq 'new' -and $_.Step -cin 'plan:check-only', 'x.check' }).Count -ge 1) "a manual back checks on new: $(LogNow)"
  Eq (@(PuLines $bk).Count) 0 "back with new's key unset: no platform-user line: $(PuLines $bk)"
  Reset-World; Set-PlatformUser 'quoc' $null; [void](Do-Plan); Eq ((PlanPuLines) -join ' | ') 'platform-user quoc' 'only old''s key set: the line'; Eq "$((Get-St).new.platform_user)" '' 'new.platform_user empty'
  Reset-World; Set-PlatformUser $null 'quoc'; [void](Do-Plan); Eq (@(PlanPuLines).Count) 0 "only new's key set: no line at a fwd plan ($(PlanPuLines))"; Eq "$((Get-St).old.platform_user)" '' 'old.platform_user empty'; Eq "$((Get-St).new.platform_user)" 'quoc' 'new.platform_user'
}
T 'L.plan-platform-user: with no platform_user (no moveTargets, no entry for the alias, or an empty name) no platform-user line is ever sent, at plan, the copy re-plan or the cutover checks, and the state keeps both empty (ruling 04/11 (3) 5: unset = contabo, nothing changes)' {
  foreach ($c in 'none', 'empty', 'other alias') {
    Reset-World; if ($c -ceq 'empty') { Set-PlatformUser '' '' } elseif ($c -ceq 'other alias') { $script:Cfg2['moveTargets'] = [pscustomobject]@{ elsewhere = [pscustomobject]@{ platform_user = 'quoc' } } }
    Fx-Copied; [void](Do-Copy 0); [void](Do-Cutover)
    Eq (@(PlanPuLines).Count) 0 "[$c] no platform-user line at plan: $(PlanPuLines)"; Eq (@(PuLines $W.Calls).Count) 0 "[$c] no call carries a platform-user line"
    $s = Get-St; Eq "$($s.old.platform_user)" '' "[$c] old.platform_user"; Eq "$($s.new.platform_user)" '' "[$c] new.platform_user"
  }
}
T 'L.plan-platform-user: a platform_user that is not a Linux user name (target-user grammar ^[a-z_][a-z0-9_.-]*$) for old or new refuses plan with 65 before any ssh and writes nothing; status --rebuild reads the same key (a valid name rebuilt and sent again, an invalid one refused 65) (ruling 04/11 (3) 5)' {
  foreach ($v in @('Quoc', '1x', 'a b', 'quoc;id', 'quoc$', [int]5)) {
    foreach ($side in 'old', 'new') {
      Reset-World; if ($side -ceq 'old') { Set-PlatformUser $v 'quoc' } else { Set-PlatformUser 'quoc' $v }
      [void](Do-Plan -Want 65); HasText 'platform_user'; Eq $W.Calls.Count 0 "[$side $v] no ssh to old or new"; NothingWritten "[$side $v] nothing written"
    }
  }
  Reset-World; Set-PlatformUser 'quoc' 'quoc'; Fx-Copied; [IO.File]::Delete((StatePath)); foreach ($n in 'old', 'new') { $W[$n].MoveId.old_addr = $OldAddr; $W[$n].MoveId.new_addr = $NewAddr }
  $r = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $r.Code 0 "rebuild ($($r.Text))"; Eq "$((Get-St).old.platform_user)" 'quoc' 'rebuilt old.platform_user'; Eq "$((Get-St).new.platform_user)" 'quoc' 'rebuilt new.platform_user'
  $n0 = $W.PlanStdin.Count; [void](Run-Move @('copy')); Ok ($W.PlanStdin.Count -gt $n0) 'the copy refresh re-plans'; Eq ((@($W.PlanStdin[-1]) | Where-Object { $_ -cmatch '\Aplatform-user' }) -join ' | ') 'platform-user quoc' 'the re-plan after a rebuild'
  [IO.File]::Delete((StatePath)); Set-PlatformUser 'Quoc' 'quoc'; $n0 = $W.Calls.Count
  $r = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $r.Code 65 "rebuild with an invalid name ($($r.Text))"; HasText 'platform_user'; Eq $W.Calls.Count $n0 'no ssh'; Ok (-not (Test-Path -LiteralPath (StatePath))) 'no state written'
}
# RV-G1 (R7-CONTRACT P3, 04/11 (4)): a moveTargets.<alias> entry that is not an object, or a platform_user that is not a string, is refused with
# a Vietnamese error naming moveTargets and config.json, never read as unset. Values as ConvertFrom-Json gives them (a JSON array = object[]).
function Set-TargetEntries($OldE, $NewE) { $script:Cfg2['moveTargets'] = [pscustomobject][ordered]@{ $OldAlias = $OldE; $NewAlias = $NewE } }
function Pu-Obj($V) { [pscustomobject]@{ platform_user = $V } }
$MalformedEntries = @(
  @{ N = 'entry string'; V = 'quoc' }, @{ N = 'entry array of one object'; V = @([pscustomobject]@{ platform_user = 'quoc' }) }, @{ N = 'entry array of two'; V = @((Pu-Obj 'quoc'), (Pu-Obj 'admin')) },
  @{ N = 'entry empty array'; V = @() }, @{ N = 'entry number'; V = [long]5 }, @{ N = 'entry bool'; V = $true }, @{ N = 'entry null'; V = $null })
$MalformedNames = @(
  @{ N = 'platform_user number'; V = [long]5 }, @{ N = 'platform_user fraction'; V = [double]1.5 }, @{ N = 'platform_user bool'; V = $true },
  @{ N = 'platform_user array of one string'; V = @('quoc') }, @{ N = 'platform_user array empty'; V = @() }, @{ N = 'platform_user object'; V = [pscustomobject]@{ a = 'quoc' } }, @{ N = 'platform_user null'; V = $null })
T 'L.plan-platform-user: a malformed moveTargets entry (the entry for old or new is a string, an array, a number or null; or its platform_user is a number, a bool, an array, an object or null; or moveTargets itself is not an object) refuses plan with 65 and an error naming the key moveTargets.<alias> (or .platform_user) and config.json, before any ssh, and writes nothing; status --rebuild refuses it too; a valid entry (extra keys, or an object without platform_user) still plans (RV-G1, R7-CONTRACT P3)' {
  foreach ($m in @($MalformedEntries) + @($MalformedNames)) {
    foreach ($side in 'old', 'new') {
      Reset-World; $ok = Pu-Obj 'quoc'; if ($m.N -like 'entry*') { $bad = $m.V } else { $bad = Pu-Obj $m.V }   # plain assignment keeps an array whole (an if-expression would unroll it)
      if ($side -ceq 'old') { $a = $OldAlias } else { $a = $NewAlias }; if ($m.N -like 'entry*') { $key = "moveTargets.$($a) trong config.json" } else { $key = "moveTargets.$($a).platform_user trong config.json" }
      if ($side -ceq 'old') { Set-TargetEntries $bad $ok } else { Set-TargetEntries $ok $bad }
      [void](Do-Plan -Want 65); HasText $key   # the key of the refused value, with its alias (the old grammar text names only 'moveTargets' and config.json)
      Eq $W.Calls.Count 0 "[$side $($m.N)] no ssh to old or new"; Eq $W.PlanStdin.Count 0 "[$side $($m.N)] no plan sent"; NothingWritten "[$side $($m.N)] nothing written"
    }
  }
  foreach ($tl in @(@{ N = 'string'; V = 'x' }, @{ N = 'number'; V = [long]5 }, @{ N = 'false'; V = $false }, @{ N = 'array of two objects'; V = @((Pu-Obj 'quoc'), (Pu-Obj 'admin')) })) {   # a one-element array is unrolled by Get-Cfg itself (DG-1), not tested
    Reset-World; $script:Cfg2['moveTargets'] = $tl.V
    [void](Do-Plan -Want 65); HasText 'khóa moveTargets trong config.json'; Eq $W.Calls.Count 0 "[moveTargets $($tl.N)] no ssh"; Eq $W.PlanStdin.Count 0 "[moveTargets $($tl.N)] no plan sent"; NothingWritten "[moveTargets $($tl.N)] nothing written"
  }
  foreach ($c in @(@('old', $MalformedEntries[0]), @('new', $MalformedEntries[1]), @('old', $MalformedNames[0]), @('new', $MalformedNames[3]))) {
    Reset-World; Set-PlatformUser 'quoc' 'quoc'; Fx-Copied; [IO.File]::Delete((StatePath)); foreach ($n in 'old', 'new') { $W[$n].MoveId.old_addr = $OldAddr; $W[$n].MoveId.new_addr = $NewAddr }
    if ($c[1].N -like 'entry*') { $bad = $c[1].V } else { $bad = Pu-Obj $c[1].V }; $ok = Pu-Obj 'quoc'
    if ($c[0] -ceq 'old') { $a = $OldAlias } else { $a = $NewAlias }; if ($c[1].N -like 'entry*') { $key = "moveTargets.$($a) trong config.json" } else { $key = "moveTargets.$($a).platform_user trong config.json" }
    if ($c[0] -ceq 'old') { Set-TargetEntries $bad $ok } else { Set-TargetEntries $ok $bad }; $n0 = $W.Calls.Count
    $r = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $r.Code 65 "[rebuild $($c[0]) $($c[1].N)] exit ($($r.Text))"; HasText $key
    Eq $W.Calls.Count $n0 "[rebuild $($c[0]) $($c[1].N)] no ssh"; Ok (-not (Test-Path -LiteralPath (StatePath))) "[rebuild $($c[0]) $($c[1].N)] no state written"
  }
  Reset-World; Set-TargetEntries ([pscustomobject]@{ platform_user = 'quoc'; note = 'x'; extra = 5 }) ([pscustomobject]@{}); [void](Do-Plan)
  Eq ((PlanPuLines) -join ' | ') 'platform-user quoc' 'a valid entry with extra keys: the line'; $s = Get-St; Eq "$($s.old.platform_user)" 'quoc' 'valid entry: old.platform_user'; Eq "$($s.new.platform_user)" '' 'an object without platform_user is unset'
  Reset-World; Set-TargetEntries ([pscustomobject]@{}) ([pscustomobject]@{ platform_user = '' }); Fx-Copied; [void](Do-Cutover)
  Eq (@(PuLines $W.Calls).Count) 0 'objects without a name or with an empty name: unset, no line'
}
T 'L.plan-platform-user: a --map file line platform-user <name> (a laptop stdin line, never a map line) refuses map-invalid ref=platform-user, plan exits 65 before any ssh and writes nothing, with or without platform_user in config.json (ruling 04/11 (3) 5: named only in the config; D.0.9)' {
  foreach ($c in @(@('platform-user quoc', $null), @('  platform-user root', 'quoc'))) {
    Reset-World; if ($null -ne $c[1]) { Set-PlatformUser $c[1] $null }
    $mf = Join-Path $Root ('map-' + [guid]::NewGuid().ToString('N') + '.txt'); [IO.File]::WriteAllText($mf, "exclude pkg chromium`n$($c[0])`n", $utf8)
    [void](Do-Plan -Extra @('--map', $mf) -Want 65); Remove-Item -LiteralPath $mf -Force
    HasText 'File map có tham chiếu sai'; HasText 'ref=platform-user'   # the map-invalid label of INV refuse map-invalid ref=platform-user
    Eq $W.Calls.Count 0 "[$($c[0])] no ssh"; Eq $W.PlanStdin.Count 0 "[$($c[0])] no plan sent"; NothingWritten "[$($c[0])] nothing written"
  }
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
# B45 (ruling 06/11 (a)): a symlink directly under / that the plan would move is refused by the server (`MOVE error bad-request why=root-link path=<p>` + a `LOG remedy root-link` line); the owner sees ONE sentence with the remedy
T 'L.plan-root-link: old''s plan <id> refusing `MOVE error bad-request why=root-link path=/data` (+ the server''s LOG remedy line) ends plan with 65 and the single owner sentence with the path and the remedy (no generic "Lệnh gửi tới máy không hợp lệ", no why=, no "remedy"), nothing written' {
  Add-Fault -M old -Key '^plan:full$' -Rc 65 -Out @('MOVE error bad-request why=root-link path=/data', 'LOG remedy root-link path=/data move the target path instead of the link, or recreate the link by hand') -Mode nomanifest
  [void](Do-Plan -Want 65)
  $want = 'Đường /data là symlink ngay dưới / nằm trong phần chuyển; hãy chuyển thư mục đích thay cho link, hoặc tạo lại link bằng tay trên máy mới'
  Ok (@(Lines -Last | Where-Object { "$_".TrimEnd() -ceq $want }).Count -eq 1) "the one owner sentence: $(Lines -Last)"
  NoText 'Lệnh gửi tới máy không hợp lệ'; NoText 'why=root-link'; NoText 'remedy'
  NothingWritten; Ok (-not (Test-Path -LiteralPath (Join-Path (MoveDir) 'manifest.json'))) 'no manifest.json'; Eq (@(RecCalls -All).Count) 0 'no recorded call'
  # another bad-request why keeps the generic label
  Reset-World; Add-Fault -M old -Key '^plan:full$' -Rc 65 -Out @('MOVE error bad-request why=call-id') -Mode nomanifest
  [void](Do-Plan -Want 65); Ok (-not ($script:Last.Text.Contains('Đường '))) 'no root-link sentence for another why'
}
# Q-ownip-compose (ruling 04/11 (2); DESIGN rev 1k3.8 B.12.5, D.15, D.15.1). The fake plan <id> answers as old's B.12.5 / E-P11: an own-ip
# path without a rewrite line refuses own-ip, a bare `rewrite own-ip <path>` while a family has more than one address in dial.old or
# dial.new refuses map-invalid ref=rewrites, every path covered gives INV ok. The manifest's dial {old[], new[]} carries the addresses.
$OwnipPaths = @('/etc/hostview-turn.conf', '/etc/hostview-turn.nft')
$OwnipSeveralText = 'Máy cũ có các địa chỉ <địa chỉ cũ>, máy mới có các địa chỉ <địa chỉ mới>. Gõ từng cặp theo dạng địa chỉ máy cũ=địa chỉ máy mới để thay trong các file trên, mỗi cặp một dòng; gõ một dòng trống để kết thúc.'   # DESIGN D.15.1 "Q-ownip (several addresses)" = CONTRACT §8.3.1, verbatim
function Set-OwnipPlan([string[]]$Old, [string[]]$New) {
  $W.Mf.dial = [ordered]@{ old = @($Old); new = @($New) }
  $fam = { param($a, $six) @($a | Where-Object { ($_ -like '*:*') -eq $six }).Count }
  $script:OwnipSeveral = (& $fam $Old $false) -gt 1 -or (& $fam $Old $true) -gt 1 -or (& $fam $New $false) -gt 1 -or (& $fam $New $true) -gt 1
  $W.PlanHook = { param($n, $map)
    $rw = @($map | Where-Object { $_ -cmatch '\Arewrite own-ip ' })
    if ($script:OwnipSeveral -and @($rw | Where-Object { $_ -cmatch '\Arewrite own-ip \S+\z' }).Count) { return @{ Out = @('INV refuse map-invalid ref=rewrites'); Code = 65 } }
    $left = @($OwnipPaths | Where-Object { $p = $_; -not @($rw | Where-Object { $_ -cmatch "\Arewrite own-ip $([regex]::Escape($p))(?: \S+=\S+)?\z" }).Count })
    if ($left.Count) { @{ Out = @($left | ForEach-Object { "INV refuse own-ip path=$_" }); Code = 65 } } else { @{ Out = @('INV ok'); Code = 0 } }
  }
}
function OwnipLines { @(foreach ($s in $W.PlanStdin) { @($s | Where-Object { $_ -cmatch '\Arewrite own-ip ' }) }) }
T 'L.plan-rewrites-remedy: Q-ownip with two old addresses in a family (or two new ones; IPv4 or IPv6) asks for the <from>=<to> pairs after có, writes rewrite own-ip <path> <from>=<to> per path and pair, never the bare line, and the re-plan accepts its own output (ruling 04/11 (2) Q-ownip-compose, B.12.5, D.15)' {
  Set-OwnipPlan @('203.0.113.10', '203.0.113.11') @('198.51.100.20'); Ans 'có', '203.0.113.10=198.51.100.20', '203.0.113.11=198.51.100.20', ''
  [void](Do-Plan); Eq $W.PlanN 2 'plan runs = the refusal + one accepted re-plan'; Eq $W.Answers.Count 0 'every typed pair and the closing blank line were read'
  $want = @(foreach ($p in $OwnipPaths) { foreach ($x in '203.0.113.10=198.51.100.20', '203.0.113.11=198.51.100.20') { "rewrite own-ip $p $x" } })
  Eq ((@($W.PlanStdin[-1]) | Where-Object { $_ -cmatch '\Arewrite own-ip ' }) -join ' | ') ($want -join ' | ') 'the re-plan map: one pair line per path and pair'
  Ok (@(OwnipLines | Where-Object { $_ -cmatch '\Arewrite own-ip \S+\z' }).Count -eq 0) "no bare rewrite line is ever sent: $(OwnipLines)"
  $mt = @([IO.File]::ReadAllText((Join-Path (MoveDir) 'map.txt')) -split "`r?`n" | Where-Object { $_ -cmatch '\Arewrite own-ip ' })
  Eq ($mt -join ' | ') ($want -join ' | ') 'map.txt keeps the pair lines (the copy re-plan reads them)'; Eq (Get-St).phase 'planned' 'phase'
  Reset-World; Set-OwnipPlan @('203.0.113.10') @('198.51.100.20', '198.51.100.21'); Ans 'có', '203.0.113.10=198.51.100.21', ''
  [void](Do-Plan); Eq $W.PlanN 2 'two new addresses: one accepted re-plan'
  Eq ((@($W.PlanStdin[-1]) | Where-Object { $_ -cmatch '\Arewrite own-ip ' }) -join ' | ') (@($OwnipPaths | ForEach-Object { "rewrite own-ip $_ 203.0.113.10=198.51.100.21" }) -join ' | ') 'two new addresses: the pair lines'
  Reset-World; Set-OwnipPlan @('203.0.113.10', '2001:db8::10', '2001:db8::11') @('198.51.100.20', '2001:db8::20'); Ans 'có', '2001:db8::10=2001:db8::20', '2001:db8::11=2001:db8::20', ''
  [void](Do-Plan); Eq $W.PlanN 2 'two old IPv6 addresses: one accepted re-plan'
  $want = @(foreach ($p in $OwnipPaths) { foreach ($x in '2001:db8::10=2001:db8::20', '2001:db8::11=2001:db8::20') { "rewrite own-ip $p $x" } })
  Eq ((@($W.PlanStdin[-1]) | Where-Object { $_ -cmatch '\Arewrite own-ip ' }) -join ' | ') ($want -join ' | ') 'two old IPv6 addresses: the pair lines'
  Ok (@(OwnipLines | Where-Object { $_ -cmatch '\Arewrite own-ip \S+\z' }).Count -eq 0) "two old IPv6 addresses: no bare rewrite line is sent: $(OwnipLines)"
}
T 'L.plan-rewrites-remedy: Q-ownip with exactly one address per family in dial.old and dial.new (one IPv4, one IPv6 each) writes the bare rewrite own-ip <path> as before and asks for no pair (ruling 04/11 (2) Q-ownip-compose, B.12.5)' {
  Set-OwnipPlan @('203.0.113.10', '2001:db8::10') @('198.51.100.20', '2001:db8::20'); Ans 'có'
  [void](Do-Plan); Eq $W.PlanN 2 'one accepted re-plan'; Eq $W.Prompts.Count 1 "only Q-ownip is asked: $($W.Prompts -join ' | ')"
  Eq ((OwnipLines) -join ' | ') (@($OwnipPaths | ForEach-Object { "rewrite own-ip $_" }) -join ' | ') 'the bare lines, once each'
  NoText 'Gõ từng cặp'; Eq (Get-St).phase 'planned' 'phase'
}
T 'L.plan-rewrites-remedy: the pair question is the D.15.1 text "Q-ownip (several addresses)" byte for byte, after the Q-ownip text, its fills naming old''s and new''s dial addresses (ruling 04/11 (2) Q-ownip-compose, CONTRACT §8.3.1)' {
  Set-OwnipPlan @('203.0.113.10', '203.0.113.11') @('198.51.100.20'); Ans 'có', '203.0.113.10=198.51.100.20', '203.0.113.11=198.51.100.20', ''
  [void](Do-Plan)
  $rx = '\A' + (@($OwnipSeveralText -split '<[^>]+>' | ForEach-Object { [regex]::Escape($_) }) -join '(.+)') + '\z'
  $hit = @(Lines | Where-Object { $_ -cmatch $rx }); Eq $hit.Count 1 "the D.15.1 line once: $(Lines)"
  $m = [regex]::Match($hit[0], $rx); $f1 = $m.Groups[1].Value; $f2 = $m.Groups[2].Value
  Ok ($f1.Contains('203.0.113.10') -and $f1.Contains('203.0.113.11') -and -not $f1.Contains('198.51.100.20')) "<địa chỉ cũ> = old's dial addresses: [$f1]"
  Ok ($f2.Contains('198.51.100.20') -and -not $f2.Contains('203.0.113.1')) "<địa chỉ mới> = new's dial addresses: [$f2]"
  $l = @(Lines); $iq = [Array]::IndexOf($l, (@($l | Where-Object { $_ -cmatch '\ACác file sau chứa địa chỉ của máy cũ: ' })[0])); $is = [Array]::IndexOf($l, $hit[0])
  Ok ($iq -ge 0 -and $iq -lt $is) "Q-ownip comes before the pair question: $iq, $is"
}
T 'L.plan-tunnel-remedies: a connector ingress naming old''s own address (INV refuse own-ip path=ingress:<hostname>), Q-ownip không, ends plan 65 with the remedy "đổi service của tên đó trong cấu hình tunnel sang 127.0.0.1 hoặc tên container"; an own-ip file path gets no such remedy (B.12.4, W1-T3-GAP-17, CONTRACT §8.3.2)' {
  $W.PlanOut = @('INV refuse own-ip path=ingress:app.example.com'); $W.PlanCode = 65; Ans 'không'
  [void](Do-Plan -Want 65); HasText 'đổi service của tên đó trong cấu hình tunnel sang 127.0.0.1 hoặc tên container'; NothingWritten
  Reset-World; $W.PlanOut = @('INV refuse own-ip path=/opt/app/conf.yml'); $W.PlanCode = 65; Ans 'không'
  [void](Do-Plan -Want 65); NoText 'đổi service của tên đó trong cấu hình tunnel'
}
# g37 triage §B.4 (B.12.4): an `own-ip path=ingress:<hostname>` hit has no file to rewrite (`rewrite own-ip` takes an absolute path only, B.14.2): it is not listed by Q-ownip and gets no map line; its remedy is printed and the plan
# ends 65. The Q-ownip list holds the absolute paths only. The plan keeps refusing the ingress hit after the file's rewrite, so the plan always ends 65 here.
$OwnipFile = '/opt/app/conf.yml'; $OwnipIngress = 'ingress:app.example.com'; $IngressRemedy = 'đổi service của tên đó trong cấu hình tunnel sang 127.0.0.1 hoặc tên container'
function Set-OwnipIngress([string[]]$Old, [string[]]$New) {   # the refusal: the ingress hit always, the file hit until its `rewrite own-ip <file>` line (bare only for one address per family, else map-invalid ref=rewrites)
  $W.Mf.dial = [ordered]@{ old = @($Old); new = @($New) }
  $fam = { param($a, $six) @($a | Where-Object { ($_ -like '*:*') -eq $six }).Count }
  $script:OwnipSeveral = (& $fam $Old $false) -gt 1 -or (& $fam $Old $true) -gt 1 -or (& $fam $New $false) -gt 1 -or (& $fam $New $true) -gt 1
  $W.PlanHook = { param($n, $map)
    $rw = @($map | Where-Object { $_ -cmatch '\Arewrite own-ip ' })
    if ($script:OwnipSeveral -and @($rw | Where-Object { $_ -cmatch '\Arewrite own-ip \S+\z' }).Count) { return @{ Out = @('INV refuse map-invalid ref=rewrites'); Code = 65 } }
    $o = @("INV refuse own-ip path=$OwnipIngress")
    if (-not @($rw | Where-Object { $_ -cmatch "\Arewrite own-ip $([regex]::Escape($OwnipFile))(?: \S+=\S+)?\z" }).Count) { $o += "INV refuse own-ip path=$OwnipFile" }
    @{ Out = $o; Code = 65 }
  }
}
function Assert-OwnipIngressPlan([string]$Tag, [string]$Rewrite) {
  $q = @(Lines | Where-Object { $_ -cmatch '\ACác file sau chứa địa chỉ của máy cũ: ' }); Eq $q.Count 1 "[$Tag] Q-ownip asked once: $(Lines)"
  Ok ($q.Count -ge 1 -and $q[0].Contains($OwnipFile) -and -not $q[0].Contains('ingress:') -and -not $q[0].Contains('app.example.com')) "[$Tag] the Q-ownip list names the file and not the ingress hit: $($q -join ' | ')"
  Eq $W.PlanN 2 "[$Tag] the refusal + one re-plan"; $in = @($W.PlanStdin[-1]); Eq (@($in | Where-Object { $_ -cmatch '\Arewrite own-ip ' }) -join ' | ') $Rewrite "[$Tag] the re-plan map has the file's rewrite line only"
  Eq (@(OwnipLines | Where-Object { $_ -cmatch 'ingress:' }).Count) 0 "[$Tag] no rewrite line for the ingress hit"; HasText $IngressRemedy; NoText 'map-invalid'; Eq (@(@($W.PlanStdin) | ForEach-Object { $_ } | Where-Object { $_ -cmatch 'ingress:' }).Count) 0 "[$Tag] no ingress token in any plan stdin"
}
T 'L.plan-ownip-ingress-mixed: old refuses own-ip for a connector ingress AND for a file; Q-ownip (có) lists only the file, the re-plan map has `rewrite own-ip <file>` and no ingress line, and the plan ends 65 with the ingress remedy, never map-invalid (g37 §B.4, B.12.4)' {
  Set-OwnipIngress @('203.0.113.10') @('198.51.100.20'); Ans 'có'; [void](Do-Plan -Want 65)
  Assert-OwnipIngressPlan 'one address' "rewrite own-ip $OwnipFile"
}
T 'L.plan-ownip-ingress-pairs: the same with two old addresses (the pairs branch): `có`, `<from>=<to>` then the empty line: the map has `rewrite own-ip <file> <from>=<to>` only, no ingress line, plan ends 65 with the ingress remedy' {
  Set-OwnipIngress @('203.0.113.10', '203.0.113.11') @('198.51.100.20'); Ans 'có', '203.0.113.10=198.51.100.20', '203.0.113.11=198.51.100.20', ''; [void](Do-Plan -Want 65)
  Eq $W.Answers.Count 0 'every typed pair and the closing blank line were read'
  Assert-OwnipIngressPlan 'pairs' ("rewrite own-ip $OwnipFile 203.0.113.10=198.51.100.20 | rewrite own-ip $OwnipFile 203.0.113.11=198.51.100.20")
  Ok (@(OwnipLines | Where-Object { $_ -cmatch '\Arewrite own-ip \S+\z' }).Count -eq 0) "no bare rewrite line: $(OwnipLines)"
}
T 'L.plan-ownip-ingress-only: only the ingress hit refused: Q-ownip is NOT asked (no prompt, no answer read), no map line, the plan ends 65 with the ingress remedy after one plan run' {
  $W.PlanOut = @("INV refuse own-ip path=$OwnipIngress"); $W.PlanCode = 65; Ans 'có'
  [void](Do-Plan -Want 65); Eq $W.Prompts.Count 0 "no question asked: $($W.Prompts -join ' | ')"; Eq $W.Answers.Count 1 'the queued answer was not read'; Eq $W.PlanN 1 'one plan run'; Eq (@(OwnipLines).Count) 0 'no rewrite own-ip line'; HasText $IngressRemedy; NothingWritten
}
T 'L.plan-ownip-other-kinds: an `INV refuse own-ip-nat path=<file>` or `own-ip-family path=<file>` refusal is another refusal with its own label: it never feeds Q-ownip (no question, no `rewrite own-ip` line, one plan run, ends 65)' {
  foreach ($k in 'own-ip-nat', 'own-ip-family') {
    Reset-World; $W.PlanOut = @("INV refuse $k path=$OwnipFile"); $W.PlanCode = 65; Ans 'có'
    [void](Do-Plan -Want 65); Eq $W.Prompts.Count 0 "[$k] no question asked: $($W.Prompts -join ' | ')"; Eq $W.PlanN 1 "[$k] one plan run"; Eq (@(OwnipLines).Count) 0 "[$k] no rewrite own-ip line"
  }
  Reset-World; $W.PlanOut = @("INV refuse own-ip-nat path=$OwnipFile", "INV refuse own-ip path=/etc/hostview-turn.conf"); $W.PlanCode = 65; Ans 'không'
  [void](Do-Plan -Want 65); $q = @(Lines | Where-Object { $_ -cmatch '\ACác file sau chứa địa chỉ của máy cũ: ' }); Eq $q.Count 1 'a real own-ip hit beside the other kind still asks'; Ok ($q[0].Contains('/etc/hostview-turn.conf') -and -not $q[0].Contains($OwnipFile)) "the list holds the own-ip hit only: $($q -join ' | ')"
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
  foreach ($c in @(@('zed', 120000, 65), @('app', 120000, 0), @('zed', 165536, 0), @('svc$', 120000, 65), @('svc$', 165536, 0), @('alice.smith', 120000, 65), @('Debian-exim', 120000, 65))) {   # names a target account may hold (the shared name-token rule: `svc$`, `alice.smith`, `Debian-exim`) must collide like any other
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
$PlatformEtc = @('/etc/instabox', '/etc/profile.d/instabox-universal.sh', '/etc/profile.d/instabox-tmpdir.sh', '/etc/profile.d/zz-instabox-secrets.sh', '/etc/profile.d/instabox-npm.sh', '/etc/sudoers.d/90-instabox-sudo', '/etc/sysctl.d/60-instabox-ping.conf', '/etc/tmpfiles.d/instabox-data-tmp.conf', '/etc/ssl/certs/instabox-proxy.pem',
  '/etc/systemd/system/halt.target.d/instabox.conf', '/etc/systemd/system/poweroff.target.d/instabox.conf', '/etc/systemd/system/systemd-halt.service.d/instabox.conf', '/etc/systemd/system/systemd-poweroff.service.d/instabox.conf', '/etc/systemd/system/tmp.mount.d/instabox.conf', '/etc/systemd/system/user@1000.service.d/instabox.conf')   # CONTRACT §3.5 LIST platform-etc (rulings 05/11 (22), (24), 07/11 B66 (a); no glob)
T 'L.pre-platform-etc: every path of LIST platform-etc (/etc/instabox, the eight instabox files in /etc and the six instabox systemd drop-ins: 15 paths) is a platform path: with platform=1 a source outside the platform scope that emits it as a tree, a file, a files entry, or something under /etc/instabox is refused at 3b (target-not-empty, nothing written); with platform=0 the same manifest passes (B.5.2 mixed pair, CONTRACT §3.5; the list itself is compared with CONTRACT in L.platform-lists-match-contract)' {
  $pf = { param($p) @('INV target user=quoc uid=1000 home-nonskel=1', "INV target platform=$p", 'INV target stop_budget_s=120') }
  $cases = @(
    @([ordered]@{ id = 'tree-etc-instabox-keys'; root = '/etc/instabox/keys'; kind = 'tree'; bytes_apparent = 1000; inodes = 3 }, '/etc/instabox/keys'),
    @([ordered]@{ id = 'files-etc-instabox-gw'; root = '/etc'; kind = 'files'; files_from = @('instabox/gateway.key'); bytes_apparent = 100; inodes = 1 }, '/etc/instabox/gateway.key'))
  foreach ($e in $PlatformEtc) {
    $dir = $e.Substring(0, $e.LastIndexOf('/')); $leaf = $e.Substring($e.LastIndexOf('/') + 1)
    $cases += , @([ordered]@{ id = "tree-$($leaf)"; root = $e; kind = 'tree'; bytes_apparent = 1000; inodes = 3 }, $e)
    $cases += , @([ordered]@{ id = "file-$($leaf)"; root = $e; kind = 'file'; bytes_apparent = 100; inodes = 1 }, $e)
    $cases += , @([ordered]@{ id = "files-$($leaf)"; root = $dir; kind = 'files'; files_from = @($leaf); bytes_apparent = 100; inodes = 1 }, $e)
  }
  foreach ($c in $cases) {
    Reset-World; $W.Pf = & $pf 1; $W.Mf.items = @($W.Mf.items) + $c[0]
    [void](Do-Plan -Want 65); HasText 'Máy mới không trống'; HasText $c[1]; NothingWritten "[$($c[1])] nothing written"; Eq (@(RecCalls -All).Count) 0 'no recorded call'
    Reset-World; $W.Pf = & $pf 0; $W.Mf.items = @($W.Mf.items) + $c[0]
    [void](Do-Plan -Want 0)
  }
  Reset-World; $W.Pf = & $pf 1; $W.Mf.items = @($W.Mf.items) + [ordered]@{ id = 'tree-etc-instabox-other'; root = '/etc/instabox-other'; kind = 'tree'; bytes_apparent = 1000; inodes = 3 }
  [void](Do-Plan -Want 0)   # a sibling name is no prefix match
  Reset-World; $W.Pf = & $pf 1; $W.Mf.items = @($W.Mf.items) + [ordered]@{ id = 'files-etc-profile-d-other'; root = '/etc/profile.d'; kind = 'files'; files_from = @('mine.sh'); bytes_apparent = 100; inodes = 1 }
  [void](Do-Plan -Want 0)   # a neighbour in the same directory is no platform path
}
# ---- ruling 05/11 (25) (B31): the 3b guard also refuses an item root or files name that HOLDS a platform path (an ancestor) and a deleted_conffiles entry at or under one ----
T 'L.pre-platform-ancestor: with platform=1 an item root (tree) or a files name that is an ancestor of a platform path (/etc, /etc/profile.d, /etc/sudoers.d, /etc/ssl/certs, /etc/systemd/system, /usr/local/bin, /opt: its transfer would overwrite or --delete new''s platform files) is refused at 3b with the standard target-not-empty text, nothing written; with platform=0 the same manifest passes; a sibling with a longer name and a files item whose root is only the base directory pass (ruling 05/11 (25) R11-INT-ancestor)' {
  $pf = { param($p) @('INV target user=quoc uid=1000 home-nonskel=1', "INV target platform=$p", 'INV target stop_budget_s=120') }
  $cases = @()
  foreach ($r in '/etc', '/etc/profile.d', '/etc/sudoers.d', '/etc/sysctl.d', '/etc/tmpfiles.d', '/etc/ssl', '/etc/ssl/certs', '/etc/systemd/system', '/usr/local', '/usr/local/bin', '/usr/local/share', '/opt') {
    $cases += , @([ordered]@{ id = "tree-anc$($r.Replace('/', '-'))"; root = $r; kind = 'tree'; bytes_apparent = 1000; inodes = 3 }, $r)
  }
  foreach ($n in @(@('/etc', 'profile.d'), @('/etc', 'sudoers.d'), @('/etc', 'ssl/certs'), @('/etc/systemd', 'system'), @('/usr/local', 'bin'), @('/', 'opt'))) {
    $path = if ($n[0] -ceq '/') { "/$($n[1])" } else { "$($n[0])/$($n[1])" }
    $cases += , @([ordered]@{ id = "files-anc$($path.Replace('/', '-'))"; root = $n[0]; kind = 'files'; files_from = @($n[1]); bytes_apparent = 100; inodes = 1 }, $path)
  }
  foreach ($c in $cases) {
    Reset-World; $W.Pf = & $pf 1; $W.Mf.items = @($W.Mf.items) + $c[0]
    [void](Do-Plan -Want 65); HasText 'Máy mới không trống'; HasText "path=$($c[1])"; NothingWritten "[$($c[1])] nothing written"; Eq (@(RecCalls -All).Count) 0 'no recorded call'
    Reset-World; $W.Pf = & $pf 0; $W.Mf.items = @($W.Mf.items) + $c[0]
    [void](Do-Plan -Want 0)
  }
  foreach ($ok in @([ordered]@{ id = 'tree-etc-profile-dx'; root = '/etc/profile.dx'; kind = 'tree'; bytes_apparent = 1000; inodes = 3 },
                    [ordered]@{ id = 'tree-etc-nginx'; root = '/etc/nginx'; kind = 'tree'; bytes_apparent = 1000; inodes = 3 },
                    [ordered]@{ id = 'files-etc-hosts'; root = '/etc'; kind = 'files'; files_from = @('hosts'); bytes_apparent = 100; inodes = 1 })) {
    Reset-World; $W.Pf = & $pf 1; $W.Mf.items = @($W.Mf.items) + $ok
    [void](Do-Plan -Want 0)   # [$($ok.root)]: no platform path under it, and a files root is only a base directory
  }
}
T 'L.pre-platform-delconf: with platform=1 a deleted_conffiles entry at or under a platform path (/etc/sudoers.d/90-instabox-sudo, a file under /etc/instabox, a platform unit file, /usr/local/bin/node) is refused at 3b with the standard target-not-empty text, nothing written (the conffile delete would remove new''s file); with platform=0, or an entry outside the platform paths, the plan passes (ruling 05/11 (25) R11-INT-delconf)' {
  $pf = { param($p) @('INV target user=quoc uid=1000 home-nonskel=1', "INV target platform=$p", 'INV target stop_budget_s=120') }
  foreach ($p in '/etc/sudoers.d/90-instabox-sudo', '/etc/instabox/identity', '/etc/profile.d/instabox-npm.sh', '/etc/systemd/system/sshd.service', '/usr/local/bin/node', '/opt/npm/etc/npmrc') {
    Reset-World; $W.Pf = & $pf 1; $W.Mf.deleted_conffiles = @($p)
    [void](Do-Plan -Want 65); HasText 'Máy mới không trống'; HasText "path=$p"; NothingWritten "[$p] nothing written"; Eq (@(RecCalls -All).Count) 0 'no recorded call'
    Reset-World; $W.Pf = & $pf 0; $W.Mf.deleted_conffiles = @($p)
    [void](Do-Plan -Want 0)
  }
  Reset-World; $W.Pf = & $pf 1; $W.Mf.deleted_conffiles = @('/etc/nginx/nginx.conf', '/etc/profile.d/mine.sh')
  [void](Do-Plan -Want 0)
  Reset-World; $W.Pf = & $pf 1; $W.Mf.deleted_conffiles = @('/etc/nginx/nginx.conf', '/etc/sudoers.d/90-instabox-sudo')
  [void](Do-Plan -Want 65); HasText 'path=/etc/sudoers.d/90-instabox-sudo'; NoText 'path=/etc/nginx/nginx.conf'
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
T 'L.platform-lists-match-contract: the laptop lists (Get-MovePlatformUnits, the /etc and /opt entries of Get-MovePlatformPaths) and the suite''s pinned $PlatformEtc / $PlatformUnits equal CONTRACT `LIST platform-units`, `LIST platform-etc` and `LIST platform-opt`, in order (CONTRACT §3, §3.5; MV_CONTRACT)' {
  $p = $env:MV_CONTRACT
  Ok ($p -and (Test-Path -LiteralPath $p)) "MV_CONTRACT must name deploy-gate docs/move/CONTRACT.md (got [$p])"
  $ct = [IO.File]::ReadAllText($p) -replace "`r`n", "`n"
  $list = { param($n) $m = [regex]::Match($ct, "(?m)^LIST $n`: (.+)$"); if ($m.Success) { @($m.Groups[1].Value.Trim() -split '\s+') } else { @() } }
  $units = & $list 'platform-units'; $etc = & $list 'platform-etc'; $opt = & $list 'platform-opt'
  Ok ($units.Count -gt 0 -and $etc.Count -gt 0 -and $opt.Count -gt 0) "CONTRACT carries the three platform lists (units $($units.Count), etc $($etc.Count), opt $($opt.Count))"
  $pp = @(Get-MovePlatformPaths)
  Eq (@(Get-MovePlatformUnits) -join ' ') ($units -join ' ') 'laptop units = LIST platform-units'
  Eq ($PlatformUnits -join ' ') ($units -join ' ') 'suite $PlatformUnits = LIST platform-units'
  Eq (@($pp | Where-Object { $_.StartsWith('/etc/') }) -join ' ') ($etc -join ' ') 'laptop /etc entries = LIST platform-etc'
  Eq ($PlatformEtc -join ' ') ($etc -join ' ') 'suite $PlatformEtc = LIST platform-etc'
  Eq (@($pp | Where-Object { $_.StartsWith('/opt/') }) -join ' ') ($opt -join ' ') 'laptop /opt entries = LIST platform-opt'
  Eq (@($pp | Select-Object -First ($etc.Count + $opt.Count)) -join ' ') ((@($etc) + @($opt)) -join ' ') 'the list starts with platform-etc then platform-opt (MV_PLATFORM order)'
}
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
T 'L.pre-empty-rules: /usr/local/man as the base-files link with the text share/man passes, on a platform and on a non-platform target; a real dir there, a plain file, a link with any other text (also /usr/local/share/man, which resolves to the same dir) or the same link at another path refuses target-not-empty (ruling 04/11 (3) 2, B.0.3, CONTRACT §3.5)' {
  $mk = {
    param([string[]]$Units = @())
    $fr = Pf-Root; foreach ($u in $Units) { Fx-File $fr "etc/systemd/system/$u" "[Unit]`n" }
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $fr 'usr/local/share/man')); $fr
  }
  foreach ($u in @(, @()) + @(, $PlatformUnits)) {
    $fr = & $mk $u; & ln -s share/man (Join-Path $fr 'usr/local/man')
    $r = Pf-Run $fr (Pf-Stubs); Eq $r.Code 0 "the link share/man, $(@($u).Count) platform units ($($r.Text))"; PfHas $r 'INV ok'; PfLacks $r '^INV refuse '
  }
  $fr = & $mk; Fx-File $fr 'usr/local/man/man1/x.1'; $r = Pf-Run $fr (Pf-Stubs); Eq $r.Code 65 "a real dir ($($r.Text))"; PfHas $r 'INV refuse target-not-empty path=/usr/local/man'
  $fr = & $mk; Fx-File $fr 'usr/local/man' "share/man`n"; $r = Pf-Run $fr (Pf-Stubs); Eq $r.Code 65 "a plain file ($($r.Text))"; PfHas $r 'INV refuse target-not-empty path=/usr/local/man'
  foreach ($t in '/usr/local/share/man', 'share/man/', './share/man', 'share/doc') {
    $fr = & $mk $PlatformUnits; & ln -s $t (Join-Path $fr 'usr/local/man'); $r = Pf-Run $fr (Pf-Stubs); Eq $r.Code 65 "the link text [$t] ($($r.Text))"; PfHas $r 'INV refuse target-not-empty path=/usr/local/man'
  }
  foreach ($p in 'usr/local/manpages', 'opt/man', 'srv/man') {
    $fr = & $mk $PlatformUnits; [void](New-Item -ItemType Directory -Force -Path (Join-Path $fr (Split-Path -Parent $p))); & ln -s share/man (Join-Path $fr $p)
    $r = Pf-Run $fr (Pf-Stubs); Eq $r.Code 65 "the link share/man at /$p ($($r.Text))"; PfHas $r "INV refuse target-not-empty path=/$p"
  }
} -NeedsBash
T 'L.pre-uid-collision: the preflight script prints new''s groups with gid ≥ 1000, every /etc/subuid and /etc/subgid line and every global address (B.0.2; W1-T11-DG-T11-4)' {
  $fr = Pf-Root
  Fx-File $fr 'fx-group' "root:x:0:`nsudo:x:27:alice`ndevs:x:1800:alice`n"; Fx-File $fr 'etc/subuid' "alice:100000:65536`nsvc`$:300000:65536`nalice.smith:400000:65536`n"; Fx-File $fr 'etc/subgid' "alice:165536:65536`nsvc`$:365536:65536`n"
  $r = Pf-Run $fr (Pf-Stubs); Eq $r.Code 0 "exit ($($r.Text))"
  PfHas $r 'INV target group=devs gid=1800'; PfLacks $r '^INV target group=(root|sudo) '
  PfHas $r 'INV target subid user=alice kind=uid start=100000 count=65536'; PfHas $r 'INV target subid user=alice kind=gid start=165536 count=65536'
  PfHas $r 'INV target subid user=svc$ kind=uid start=300000 count=65536'; PfHas $r 'INV target subid user=svc$ kind=gid start=365536 count=65536'; PfHas $r 'INV target subid user=alice.smith kind=uid start=400000 count=65536'
  PfHas $r 'INV target addr=198.51.100.20'; PfHas $r 'INV target addr=2001:db8::20'
} -NeedsBash
T 'L.preflight-subid-names: the preflight script keeps every subid name that is a name token (B.6.2.1: `svc$`, `alice.smith`, `Debian-exim`, 256 characters) and drops one with a blank, a tab or a control byte, an empty one or one longer than 256 characters; the range of a kept name is printed for subuid and subgid' {
  $fr = Pf-Root; $long = 'n' * 257; $ok256 = 'm' * 256
  Fx-File $fr 'etc/subuid' ("svc`$:300000:65536`nDebian-exim:310000:65536`nalice.smith:320000:65536`n${ok256}:330000:65536`nsp ace:340000:65536`ntab`tname:350000:65536`nctl$([char]1)name:360000:65536`n:370000:65536`n${long}:380000:65536`n"); Fx-File $fr 'etc/subgid' "svc`$:300000:65536`n"
  $r = Pf-Run $fr (Pf-Stubs); Eq $r.Code 0 "exit ($($r.Text))"
  foreach ($n in 'svc$', 'Debian-exim', 'alice.smith', $ok256) { PfHas $r "INV target subid user=$n kind=uid start=$(@{ 'svc$' = 300000; 'Debian-exim' = 310000; 'alice.smith' = 320000; $ok256 = 330000 }[$n]) count=65536" }
  PfHas $r 'INV target subid user=svc$ kind=gid start=300000 count=65536'
  foreach ($n in 'sp ace', "tab`tname", "ctl$([char]1)name", $long) { PfLacks $r ('^INV target subid user=' + [regex]::Escape($n) + ' ') }
  Eq @($r.Out | Where-Object { "$_" -match '^INV target subid user=' }).Count 5 'exactly the four kept uid names and the one gid range'
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
T 'L.check-diff: check''s plan - --check-only stdin is exactly the default map lines (exclude user dino, exclude unit velh-pilot-hourly.timer) and nothing else: no /etc/ssl/certs line, no platform-user line with platform_user set, no map.txt line after a plan with --map (GAP-RULINGS-3 W1-T3-GAP-1, D.0.9; ruling 05/11 (27) 2, review t10f F1/F3)' {
  $want = "exclude user dino`nexclude unit velh-pilot-hourly.timer`n"
  foreach ($c in 'plain', 'platform_user', 'after plan --map') {
    Reset-World
    if ($c -cne 'plain') { Set-PlatformUser 'quoc' 'quoc' }
    if ($c -ceq 'after plan --map') { $mf = Join-Path $Root ('map-' + [guid]::NewGuid().ToString('N') + '.txt'); [IO.File]::WriteAllText($mf, "exclude pkg chromium`n", $utf8); [void](Do-Plan -Extra @('--map', $mf)); Remove-Item -LiteralPath $mf -Force }
    $n0 = $W.Calls.Count; $r = Run-Move @('check'); Eq $r.Code 0 "[$c] check ($($r.Text))"
    $cs = @(for ($i = $n0; $i -lt $W.Calls.Count; $i++) { if ($W.Calls[$i].Step -ceq 'plan:check') { $W.Calls[$i] } }); Eq $cs.Count 1 "[$c] one plan - --check-only"
    Eq ("$($cs[0].Stdin)" -replace "`r`n", "`n") $want "[$c] check stdin"
  }
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
T 'L.copy-first-preinstall-probe: the first copy''s status probe of a new without a gate (127) prints the calm "chưa có công cụ chuyển máy" line, never the unclear-answer line; any other 127 (gate_id already stored, or a later phase) keeps the old line' {
  $Calm = "máy '$NewAlias' chưa có công cụ chuyển máy; sẽ cài ngay bây giờ."; $Unclear = "máy '$NewAlias' không trả lời rõ (không có GATE_EXIT; mã 127)."
  Fx-Planned; [void](Do-Copy 0); HasText $Calm; NoText 'không trả lời rõ'
  Reset-World; Fx-Planned; [void](Patch-St @{ gate_id = 'abc' }); [void](Do-Copy -1); HasText $Unclear; NoText $Calm
  Reset-World; Fx-Copied; $W.new.HasGate = $false; [void](Do-Copy -1); HasText $Unclear; NoText $Calm
  foreach ($v in 'cutover', 'back', 'abort') { Reset-World; Fx-Planned; Ans 'có', 'YES'; [void](Run-Move @($v)); HasText $Unclear; NoText $Calm }   # the calm line is the copy verb's only
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
T 'L.copy-after-collision-remedy: c.init-new wrote the move-id and was still running when ssh dropped; the next copy''s status shows it running, it ends failed while copy waits (Wait-MoveRunning stores the refreshed Ok status, which shows failed), and the copy re-sends c.init-new under the same id before any transfer (DESIGN-GAP T10d-NEW2-halfdone: only a done init counts as seen)' {
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
# ruling 06/11 (32): verify.lst has a last field sha256 (sum set only, empty otherwise); a line pair that differs only there is named by the laptop; an older line (no field) reads as "no hash"
function SumPaths { @(Lines | Where-Object { $_ -match 'Dữ liệu hai máy khác nhau: item=(\S+) path=(.*)\z' } | ForEach-Object { "$($Matches[1])`t$($Matches[2])" }) }
function Dig-Diff { $script:W.new.Digest['opt-app'] = 'cccccccccccc'; $script:W.new.NoAcl = $true }   # a digest difference at x.verify with identical lines
function Content-Flip([string]$Sha = 'ee') { Dig-Diff; $script:W.new.Content['/opt/app/f2'] = $Sha * 32 }
T 'L.verify-compare-sha256: two verify.lst lines that differ only in the last field (sha256) are reported as MOVE error sum-mismatch item= path= after the rollback' {
  Fx-Copied; Content-Flip; [void](Do-Cutover -1); Assert-Rb
  Before '^old fwd-1-r\.unfreeze-src$' '^(old|new) status --lst fwd-1-x\.verify$'
  Ok (@(LogNow | Where-Object { $_ -match '^(old|new) status --lst fwd-1-x\.verify$' }).Count -ge 2) 'both verify.lst fetched'
  $lo = $W.old.Lst['fwd-1-x.verify']; $ln = $W.new.Lst['fwd-1-x.verify']
  Ok ((@($lo | Where-Object { $_ -like '/opt/app/*' }).Count) -eq 25 -and (@($ln | Where-Object { $_ -like '/opt/app/*' }).Count) -eq 25) 'fixture: 25 lines per item'
  Ok (@($ln | Where-Object { $_ -like "/opt/app/f2`t*" })[0].EndsWith("`t" + ('ee' * 32))) 'fixture: sha256 is the last field'
  Ok (@($ln | Where-Object { $_ -like "/opt/app/f9`t*" })[0].EndsWith("`t")) 'fixture: a file outside the sum set has an empty last field'
  $sp = @(SumPaths); Eq $sp.Count 1 "one path ($($sp -join ' | '))"; Eq $sp[0] "opt-app`t/opt/app/f2" 'the flipped file'
  HasText 'Dữ liệu hai máy khác nhau'
}
T 'L.verify-compare-sha256-cap: at most 20 differing paths are printed (B.8.6)' {
  Fx-Copied; Content-Flip
  foreach ($k in 1..25) { $W.old.Content["/opt/app/f$k"] = 'dd' * 32; $W.new.Content["/opt/app/f$k"] = 'ee' * 32 }
  [void](Do-Cutover -1); Assert-Rb
  $sp = @(SumPaths); Eq $sp.Count 20 'exactly 20 paths of 25'; Eq (@($sp | Sort-Object -Unique).Count) 20 'distinct'
}
T 'L.verify-compare-sha256-oldformat: a line without the field (older server) against one with it reads as no hash: not an error, and the other fields are still compared' {
  Fx-Copied; Content-Flip; $W.old.LstOld = $true; [void](Do-Cutover -1); Assert-Rb
  Ok (@($W.old.Lst['fwd-1-x.verify'] | Where-Object { $_ -like "/opt/app/f2`t*" })[0].Split("`t").Count -eq 9) 'fixture: old line has 9 fields'
  Ok (@($W.new.Lst['fwd-1-x.verify'] | Where-Object { $_ -like "/opt/app/f2`t*" })[0].Split("`t").Count -eq 10) 'fixture: new line has 10 fields'
  Eq (@(SumPaths).Count) 0 'no path for a pair that differs only by the missing hash'
  Reset-World; Fx-Copied; $W.new.Digest['opt-app'] = 'cccccccccccc'; $W.old.LstOld = $true; $W.new.Content['/opt/app/f2'] = 'ee' * 32   # f3 acl differs too
  [void](Do-Cutover -1); Assert-Rb; $sp = @(SumPaths); Eq $sp.Count 1 "only the real difference ($($sp -join ' | '))"; Eq $sp[0] "opt-app`t/opt/app/f3" 'acl difference still named'
  Reset-World; Fx-Copied; Content-Flip; $W.new.LstOld = $true; [void](Do-Cutover -1); Assert-Rb
  Eq (@(SumPaths).Count) 0 'new without the field against old with it: also no hash'
}
T 'L.verify-compare-sha256-empty: empty against a hash (either side), and empty against empty, is no difference; two different non-empty hashes, and a literal - against a hash, are named; the other fields are still compared' {
  Fx-Copied; Content-Flip; $W.old.Content['/opt/app/f2'] = ''; [void](Do-Cutover -1); Assert-Rb
  Eq (@(SumPaths).Count) 0 'old empty vs new hash'
  Reset-World; Fx-Copied; Content-Flip; $W.new.Content['/opt/app/f2'] = ''; [void](Do-Cutover -1); Assert-Rb
  Eq (@(SumPaths).Count) 0 'new empty vs old hash'
  Reset-World; Fx-Copied; Content-Flip; $W.old.Content['/opt/app/f2'] = ''; $W.new.Content['/opt/app/f2'] = ''; [void](Do-Cutover -1); Assert-Rb
  Eq (@(SumPaths).Count) 0 'empty vs empty'
  Reset-World; Fx-Copied; Content-Flip; $W.old.Content['/opt/app/f2'] = 'dd' * 32; [void](Do-Cutover -1); Assert-Rb
  $sp = @(SumPaths); Eq $sp.Count 1 'two different hashes'; Eq $sp[0] "opt-app`t/opt/app/f2" 'named'
  Reset-World; Fx-Copied; Content-Flip; $W.new.Content['/opt/app/f2'] = '-'; [void](Do-Cutover -1); Assert-Rb
  $sp = @(SumPaths); Eq $sp.Count 1 '- vs hash'; Eq $sp[0] "opt-app`t/opt/app/f2" 'unreadable marker is not "no hash"'
  Reset-World; Fx-Copied; $W.new.Digest['opt-app'] = 'cccccccccccc'; $W.old.Content['/opt/app/f2'] = ''   # f3 acl differs, f2 empty vs hash
  [void](Do-Cutover -1); Assert-Rb; $sp = @(SumPaths); Eq $sp.Count 1 "only the acl difference ($($sp -join ' | '))"; Eq $sp[0] "opt-app`t/opt/app/f3" 'fields 1-9 compared'
}
T 'L.verify-compare-onesided: a path present on one machine only is reported (missing on new, missing on old, with an old-format line on either side)' {
  Fx-Copied; Dig-Diff; $W.new.Drop['/opt/app/f7'] = $true; [void](Do-Cutover -1); Assert-Rb
  $sp = @(SumPaths); Eq $sp.Count 1 "missing on new ($($sp -join ' | '))"; Eq $sp[0] "opt-app`t/opt/app/f7" 'f7'
  Reset-World; Fx-Copied; Dig-Diff; $W.old.Drop['/opt/app/f7'] = $true; [void](Do-Cutover -1); Assert-Rb
  $sp = @(SumPaths); Eq $sp.Count 1 "missing on old ($($sp -join ' | '))"; Eq $sp[0] "opt-app`t/opt/app/f7" 'f7'
  Reset-World; Fx-Copied; Dig-Diff; $W.old.LstOld = $true; $W.new.Drop['/opt/app/f7'] = $true; [void](Do-Cutover -1); Assert-Rb
  $sp = @(SumPaths); Eq $sp.Count 1 "old-format old, missing on new ($($sp -join ' | '))"; Eq $sp[0] "opt-app`t/opt/app/f7" 'f7'
  Reset-World; Fx-Copied; Dig-Diff; $W.new.LstOld = $true; $W.old.Drop['/opt/app/f7'] = $true; [void](Do-Cutover -1); Assert-Rb
  $sp = @(SumPaths); Eq $sp.Count 1 "old-format new, missing on old ($($sp -join ' | '))"; Eq $sp[0] "opt-app`t/opt/app/f7" 'f7'
  Reset-World; Fx-Copied; Dig-Diff; $W.new.Extra = @('/opt/app/extra'); [void](Do-Cutover -1); Assert-Rb
  $sp = @(SumPaths); Eq $sp.Count 1 "extra on new ($($sp -join ' | '))"; Eq $sp[0] "opt-app`t/opt/app/extra" 'extra'
}
T 'L.verify-compare-case-only: paths that differ only in case stay two paths (a flip in either is named, a flip in both names both)' {
  Fx-Copied; Dig-Diff; foreach ($m in 'old', 'new') { $W[$m].Extra = @('/opt/app/README', '/opt/app/Readme') }
  $W.new.Content['/opt/app/README'] = 'ee' * 32; [void](Do-Cutover -1); Assert-Rb
  $sp = @(SumPaths); Eq $sp.Count 1 "flip in README only ($($sp -join ' | '))"; Eq $sp[0] "opt-app`t/opt/app/README" 'README named'
  Reset-World; Fx-Copied; Dig-Diff; foreach ($m in 'old', 'new') { $W[$m].Extra = @('/opt/app/README', '/opt/app/Readme') }
  $W.new.Content['/opt/app/Readme'] = 'ee' * 32; [void](Do-Cutover -1); Assert-Rb
  $sp = @(SumPaths); Eq $sp.Count 1 "flip in Readme only ($($sp -join ' | '))"; Eq $sp[0] "opt-app`t/opt/app/Readme" 'Readme named'
  Reset-World; Fx-Copied; Dig-Diff; foreach ($m in 'old', 'new') { $W[$m].Extra = @('/opt/app/README', '/opt/app/Readme') }
  $W.new.Content['/opt/app/README'] = 'ee' * 32; $W.new.Content['/opt/app/Readme'] = 'ee' * 32; [void](Do-Cutover -1); Assert-Rb
  $sp = @(SumPaths | Sort-Object -CaseSensitive); Eq $sp.Count 2 "both flipped ($($sp -join ' | '))"
  Reset-World; Fx-Copied; Dig-Diff; $W.old.Extra = @('/opt/app/README'); $W.new.Extra = @('/opt/app/Readme'); [void](Do-Cutover -1); Assert-Rb
  $sp = @(SumPaths | Sort-Object -CaseSensitive); Eq $sp.Count 2 "README on old only + Readme on new only ($($sp -join ' | '))"
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
function Rebuild-Now { $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild ($($rr.Text) | log: $(@(LogNow | Select-Object -Last 6) -join ' ; '))"; Get-St }
function Assert-OldServes([string]$Tag, [switch]$NewDown) {   # -NewDown: new does not answer, only old is judged
  $s = Get-St; Eq $s.phase 'rolled-back' "[$Tag] phase"; Eq $s.serving 'old' "[$Tag] serving"; Ok ($null -eq $s.mark) "[$Tag] mark"; Eq $s.enabled $true "[$Tag] enabled"
  Eq $W.old.Frozen $false "[$Tag] old unfrozen"; Eq $W.old.Enabled $true "[$Tag] old enabled"; Eq $W.old.Active $Holds "[$Tag] old serves"; Eq $W.old.Conn $true "[$Tag] old's connectors run (r.start-src, not x.enable.N)"
  if (-not $NewDown) { Eq $W.new.Active 0 "[$Tag] new stopped"; Ok (-not ($W.new.Active -gt 0 -and $W.old.Active -gt 0)) "[$Tag] never both" }
}
function Assert-NewUntouched([string]$Tag) {   # the first call to new is the fence; nothing that starts, enables, switches or health-checks it
  $nc = @(RecCalls | Where-Object { $_.M -ceq 'new' } | ForEach-Object { $_.Call }); Ok ($nc.Count -ge 1) "[$Tag] a call reached new"
  if ($nc.Count -ge 1) { Ok ($nc[0] -match '-r\.stop-dst$') "[$Tag] r.stop-dst is the FIRST call to new: $($nc -join ', ')" }
  Eq (Sent 'new' '-x\.(enable|unfreeze)\.[0-9]+$') 0 "[$Tag] no x.enable.N / x.unfreeze.N to new"; Eq (Sent 'new' '-x\.(switch|health|start|final)$') 0 "[$Tag] no x.switch / x.health / x.start / x.final to new"
}
# ADDENDUM (E-R3): a definite r.start-src / r.unfreeze-src failure leaves the write-ahead state rolling-back (serving old, enabled false) and exits 70; copy / abort / back are refused, `cutover` re-sends the three calls (the failed id is re-executed, the done ones replay) and a now-successful start ends rolled-back; chore 0 never repairs a return
function Rb-Fail-Case([string]$Which) {
  Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Rc 1; Add-Fault -M old -Key "-r\.$Which-src`$" -Rc 1
  [void](Do-Cutover 70); Ok ((Sent 'old' '-r\.unfreeze-src$') -eq 1) "[$Which] unfreeze tried (also after a failed start)"
  $s = Get-St; Eq $s.mark 'rolling-back' "[$Which] state stays rolling-back"; Eq $s.serving 'old' "[$Which] serving"; Eq $s.enabled $false "[$Which] enabled"; Eq $s.carry $false "[$Which] carry"; Ok ($s.phase -cne 'rolled-back') "[$Which] not rolled-back"
  if ($Which -ceq 'unfreeze') { Eq $W.old.Frozen $true "[$Which] old still frozen" }
  foreach ($v in 'copy', 'abort', 'back') { $r = Run-Move @($v); Ok ($r.Code -ne 0) "[$Which] $v is refused ($($r.Text))"; Eq (SentAny '.') 0 "[$Which] $v sent nothing" }
  $r = Run-Move @('cutover'); Eq $r.Code 10 "[$Which] cutover continues the return ($($r.Text))"
  foreach ($c in 'start', 'unfreeze', 'health') { Ok ((SentAny "^fwd-1-r\.$c-src`$") -ge 1) "[$Which] r.$c-src re-sent (a done one replays)" }; Eq (Sent 'old' "^fwd-1-r\.$Which-src`$") 1 "[$Which] the failed r.$Which-src is re-executed"
  Eq (SentAny '-x\.(enable|unfreeze)\.[0-9]+$') 0 "[$Which] no chore 0"; Assert-OldServes $Which
}
T 'L.rb-fail-src-start: old r.start-src failing in a rollback: unfreeze still tried, exit 70, the state stays rolling-back with enabled=false; copy / abort / back refused; `cutover` re-sends the three calls and a now-successful start ends rolled-back, enabled (E-R3)' { Rb-Fail-Case 'start' }
T 'L.rb-unfreeze-fail: r.unfreeze-src failing: exit 70, old serves frozen, the state stays rolling-back with enabled=false; `cutover` repairs it with the return''s own calls, never with chore 0' { Rb-Fail-Case 'unfreeze' }
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
  $W.Dur['^c\.prepare\.'] = 800; $W.Dur['^c\.adopt\.'] = 1000
  Fx-Copied
  $b = @{}; foreach ($c in @(RecCalls -All)) { $b[$c.Call] = [int]$c.Budget; Eq $c.Timeout ([int]$c.Budget + 60) "deadline of $($c.Call)" }
  Eq $b['fwd-1-c.init-old'] 300 'c.init-old'; Eq $b['fwd-1-c.init-new'] 180 'c.init-new = stop_budget_s + 60'; Eq $b['fwd-1-c.prepare.1'] 2100 'c.prepare.1 = 300 + the apt-get bound 1800 (the B.7.3 package install runs in prepare; CONTRACT §5, D.0.6)'
  Eq $b['fwd-1-c.transfer.1'] 21600 'first transfer'; Eq $b['fwd-1-c.verify.1'] 1800 'first verify'; Eq $b['fwd-1-c.adopt.1'] 1860 'adopt'
  [void](Do-Copy 0)
  $b2 = @{}; foreach ($c in @(RecCalls)) { $b2[$c.Call] = [int]$c.Budget }
  Eq $b2['fwd-1-c.prepare.2'] 2400 'c.prepare.2 = max(2100, 3 × 800)'; Eq $b2['fwd-1-c.adopt.2'] 3000 'c.adopt.2 = max(1860, 3 × 1000)'
  [void](Do-Cutover 0); $s = Get-St
  $b3 = @{}; foreach ($c in @(RecCalls)) { $b3[$c.Call] = [int]$c.Budget }
  Eq $b3['fwd-1-x.prepare-id'] 300 'x.prepare-id stays 300 (the two prepare forms stay apart)'; Eq $b3['fwd-1-x.freeze'] (900 + 120 + 30) 'x.freeze = cap_s + cron.service (the one periodic source of the stop set) + 30'; Eq $b3['fwd-1-x.guards'] 930 'x.guards = cap_s + Σ run_s (no guard) + 30'; Eq $b3['fwd-1-x.switch'] 60 'x.switch = 60 (no connector, no tunnel name)'
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
T 'L.pkg-extra-label: INV warn pkg-extra (c.adopt.N, x.adopt) is shown with the cautious CONTRACT 8.3.3 label per line and no 8.3.2 remedy line (R10-INT-23, B22)' {
  $rem = 'xóa file mặc định đó rồi chạy lại'
  $lab = 'Có file lạ trong thư mục được chuyển, chưa bị xóa; chỉ xóa nếu chắc đây là file mặc định của gói vừa cài (vd sites-enabled/default); KHÔNG xóa file của chính máy mới (vd sudoers.d/90-cloud-init-users, netplan/50-cloud-init.yaml) — xóa nhầm có thể mất sudo hoặc mạng'
  Fx-Planned; [void](Do-Copy 0); NoText $rem; NoText 'Có file lạ trong thư mục được chuyển'
  Reset-World; Fx-Planned
  Add-Fault -M new -Key '-c\.adopt\.1$' -Rc 0 -Out @('INV warn pkg-extra path=/etc/nginx/sites-enabled/default', 'INV warn pkg-extra path=/etc/nginx/conf.d/default.conf')
  [void](Do-Copy 0)
  HasText "${lab}: path=/etc/nginx/sites-enabled/default"; HasText "${lab}: path=/etc/nginx/conf.d/default.conf"
  NoText $rem
  Add-Fault -M new -Key '-x\.adopt$' -Rc 0 -Out @('INV warn pkg-extra path=/etc/nginx/sites-enabled/default')
  [void](Do-Cutover 0)
  HasText "${lab}: path=/etc/nginx/sites-enabled/default"
  NoText $rem
  Eq (Get-St).phase 'cut' 'report-only: no rollback'
}
T 'L.no-install-end-remedy: MOVE item <id> kind=adopt state=failed why=no-install-end (c.prepare.N) is shown and then the CONTRACT 8.3.2 remedy once per call (R10-INT-23, B18/B20)' {
  $rem = 'xóa file mặc định đó rồi chạy lại'
  $l1 = 'MOVE item nginx kind=adopt state=failed why=no-install-end path=/etc/nginx/sites-enabled/default'
  $l2 = 'MOVE item nginx kind=adopt state=failed why=no-install-end path=/etc/nginx/conf.d/default.conf'
  Fx-Planned; Add-Fault -M new -Key '-c\.prepare\.1$' -Rc 1 -Out @($l1, $l2)
  $r = Do-Copy -1; Ok ($r.Code -ne 0) "copy stops ($($r.Text))"; $t = $script:Last.Text
  HasText $l1; HasText $l2
  Eq ([regex]::Matches($t, [regex]::Escape($rem)).Count) 1 "the remedy once (two failed items, one call): $t"
  Ok ($t.LastIndexOf($rem) -gt $t.LastIndexOf($l2)) 'the remedy follows the lines'
  Reset-World; Fx-Planned; Add-Fault -M new -Key '-c\.prepare\.1$' -Rc 1 -Out @('MOVE item nginx kind=apt state=failed')
  [void](Do-Copy -1); NoText $rem
}
T 'L.step10-fail-no-carry: chore 0 failing after the proof ends exit 1 with new serving (no carry-back); the next verb runs chore 0 first with a raised N' {
  Fx-Copied; Add-Fault -M new -Key '-x\.enable\.1$' -Rc 1
  [void](Do-Cutover 1); $s = Get-St; Eq $s.phase 'cut' 'phase'; Eq $s.serving 'new' 'serving'; Eq $s.enabled $false 'enabled'
  Eq (SentAny '-b\.init-') 0 'no carry-back'
  $r = Run-Move @('cutover'); Eq $r.Code 0 "re-run ($($r.Text))"
  Ok ((Sent 'new' '^fwd-1-x\.enable\.2$') -eq 1) 'x.enable.2 runs'; Eq (Get-St).enabled $true 'enabled after the repair'; Eq $W.new.Frozen $false 'new unfrozen'
}

# ---- B24 (R10-INT-26, DG6): an exit that gives up because a machine did not answer ends with the re-run sentence, once; a drop is never a clock refusal or a lockout ----
$Rerun = 'Chạy lại khi máy nối lại được.'
function LastLine { @(@($script:Last.Text -split '\r?\n') | Where-Object { "$_".Trim() }) | Select-Object -Last 1 }
function EndsRerun([string]$Head) {
  Eq "$(LastLine)" "lỗi: $Head $Rerun" "the last line (output: $($script:Last.Text))"
  Eq ([regex]::Matches($script:Last.Text, [regex]::Escape($Rerun)).Count) 1 'the re-run sentence once'
}
T 'L.no-answer-copy-gate-ids: copy (4) with a machine that does not answer status ends with the re-run sentence (once), exit 1, no gate-version refusal (B24)' {
  foreach ($c in @(@('old', 1), @('new', 0))) {   # status order of a first copy: old (agreement), new (agreement: nogate, never faulted), then (4): old, new
    Reset-World; Fx-Planned; Add-Fault -M $c[0] -Key '^status$' -Mode down -N -1 -Skip $c[1]
    [void](Do-Copy 1); EndsRerun "máy '$(if ($c[0] -ceq 'old') { $OldAlias } else { $NewAlias })' không trả lời khi đọc status (mã 255)."; NoText 'INV refuse gate-version'; Eq (SentAny '-c\.prepare\.') 0 "[$($c[0])] no prepare"
  }
}
T 'L.no-answer-cutover-0c: the 0c status read, the agreement check and the verb rows that need a machine end with the re-run sentence (once), exit 1, nothing frozen (B24)' {
  Fx-Copied; Add-Fault -M new -Key '^status$' -Mode down -N -1 -Skip 1   # the second status of new is 0c's gate-id read
  [void](Do-Cutover 1); EndsRerun "máy '$NewAlias' không trả lời khi đọc status (mã 255)."; Eq (Sent 'old' '-x\.freeze$') 0 'nothing frozen (0c)'
  Reset-World; Fx-Copied; Add-Fault -M old -Key '^status$' -Mode down -N -1
  [void](Do-Cutover 1); EndsRerun "máy '$OldAlias' không trả lời khi đọc status (mã 255)."; Eq (Sent 'old' '-x\.freeze$') 0 'nothing frozen (agreement)'
  Reset-World; Fx-Copied; $W.new.Up = $false
  [void](Do-Cutover 1); EndsRerun "máy '$NewAlias' không trả lời khi lệnh 'cutover' cần máy mới (mã 255)."; Eq (Sent 'old' '-x\.freeze$') 0 'nothing frozen (row)'
  Reset-World; Fx-Planned; $W.new.Up = $false
  [void](Do-Copy 1); EndsRerun "máy '$NewAlias' không trả lời khi lệnh 'copy' cần máy mới (mã 255)."
  Reset-World; Fx-Cut; $W.new.Up = $false
  $r = Run-Move @('finish'); Eq $r.Code 1 "finish exit ($($r.Text))"; EndsRerun "máy '$NewAlias' không trả lời khi đang phục vụ (mã 255)."
}
T 'L.no-answer-facts-255: no answer (255 or the deadline) at the 0c facts read and at the plan facts read of new is "không trả lời" with the re-run sentence, exit 1, never a clock refusal (B24, DG6)' {
  foreach ($mach in 'old', 'new') { foreach ($rc in 255, 124) {
    Reset-World; Fx-Copied; Add-Fault -M $mach -Key '^script:facts$' -Rc $rc -Out @()
    [void](Do-Cutover 1); EndsRerun "máy '$(if ($mach -ceq 'old') { $OldAlias } else { $NewAlias })' không trả lời khi đọc dữ kiện (mã $rc)."; NoText 'Đồng hồ các máy lệch nhau'; NoText 'skew_s'; Eq (Sent 'old' '-x\.freeze$') 0 "[$mach $rc] nothing frozen"
  } }
  Reset-World; Add-Fault -M new -Key '^script:facts$' -Rc 255 -Out @(); $r = Do-Plan -Want 1
  EndsRerun "máy '$NewAlias' không trả lời khi đọc dữ kiện (mã 255)."; NoText 'Đồng hồ các máy lệch nhau'; NothingWritten 'plan wrote nothing'
  Reset-World; Fx-Copied; Add-Fault -M new -Key '^script:facts$' -Rc 1 -Out @(); [void](Do-Cutover 65); HasText 'Đồng hồ các máy lệch nhau quá 5 giây'; NoText $Rerun
}
T 'L.login-no-answer: ssh 255 or the deadline at the post-adopt login check (copy, cutover, back) without an authentication refusal is "không trả lời" with the re-run sentence, exit 1, no lockout; a refusal or another code stays lockout, exit 70 (B24, DG6)' {
  $lockLab = 'Mất quyền đăng nhập vào máy đích'
  foreach ($c in @(@(255, ''), @(124, ''), @(255, 'ssh: connect to host 192.0.2.1 port 22: Connection timed out'))) {
    Reset-World; Fx-Planned; $W.LoginRc = $c[0]; $W.LoginErr = $c[1]
    [void](Do-Copy 1); EndsRerun "máy '$NewAlias' không trả lời khi kiểm tra đăng nhập (mã $($c[0]))."; NoText $lockLab; NoText 'MOVE error lockout'
  }
  foreach ($c in @(@(255, 'new@192.0.2.1: Permission denied (publickey).'), @(255, 'Received disconnect: Too many authentication failures'), @(124, 'Permission denied (publickey).'), @(1, ''), @(2, 'Connection timed out'))) {
    Reset-World; Fx-Planned; $W.LoginRc = $c[0]; $W.LoginErr = $c[1]
    [void](Do-Copy 70); HasText $lockLab; NoText $Rerun
  }
  Reset-World; Fx-Copied; $W.LoginRc = 255
  [void](Do-Cutover 1); EndsRerun "máy '$NewAlias' không trả lời khi kiểm tra đăng nhập (mã 255)."; NoText $lockLab; Eq (SentAny '-r\.') 0 'no rollback after a login that did not answer'
  Reset-World; Fx-Copied; $W.LoginRc = 255; $W.LoginErr = 'Permission denied (publickey).'
  [void](Do-Cutover 70); HasText $lockLab; NoText $Rerun
  Reset-World; Fx-Cut; $W.LoginRc = 255; Ans 'YES'
  $r = Run-Move @('back'); Eq $r.Code 1 "back exit ($($r.Text))"; EndsRerun "máy '$OldAlias' không trả lời khi kiểm tra đăng nhập (mã 255)."; NoText $lockLab
  Reset-World; Fx-Cut; $W.LoginRc = 255; $W.LoginErr = 'Permission denied (publickey).'; Ans 'YES'
  $r = Run-Move @('back'); Eq $r.Code 70 "back lockout exit ($($r.Text))"; HasText $lockLab; NoText $Rerun
  foreach ($err in @('', 'Permission denied (publickey).')) {   # a carry-back (failed x.health): the login of its x.adopt on old
    $script:CarryLoginErr = $err
    Reset-World; Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Rc 69 -Out @('MOVE item app.service kind=unit state=failed ActiveState=failed') -Do { $W.LoginRc = 255; $W.LoginErr = $script:CarryLoginErr }
    if ($err) { [void](Do-Cutover 70); HasText $lockLab; NoText $Rerun }
    else { [void](Do-Cutover 1); EndsRerun "máy '$OldAlias' không trả lời khi kiểm tra đăng nhập (mã 255)."; NoText $lockLab }
  }
}
# ---- R10-INT-31 (B24): an unknown outcome of a call (-1 / 124 / 255) ends the run with the re-run sentence once, exit 1; a plain failed call (rc 1) has none ----
function EndsBareRerun {
  Eq "$(LastLine)" $Rerun "the last line is the re-run sentence (output: $($script:Last.Text))"
  Eq ([regex]::Matches($script:Last.Text, [regex]::Escape($Rerun)).Count) 1 'the re-run sentence once'
}
T 'L.no-answer-call-unknown: c.transfer.N and c.init-old with an unknown outcome (machine lost) end the copy with the re-run sentence once as the last line, exit 1 (net-drop text first); a failed call (rc 1) has no sentence (R10-INT-31)' {
  Fx-Planned; Add-Fault -M new -Key '-c\.transfer\.1$' -Mode down
  [void](Do-Copy 1); EndsBareRerun
  $t = $script:Last.Text; Ok ($t.IndexOf('mạng đứt; chạy fcode move copy lại') -ge 0 -and $t.IndexOf('mạng đứt; chạy fcode move copy lại') -lt $t.LastIndexOf($Rerun)) "the net-drop text comes before the sentence: $t"
  Reset-World; Fx-Planned; Add-Fault -M old -Key '-c\.init-old$' -Mode down
  [void](Do-Copy 1); EndsBareRerun
  Reset-World; Fx-Planned; Add-Fault -M new -Key '-c\.transfer\.1$' -Rc 1
  [void](Do-Copy 1); NoText $Rerun
}
# ---- ruling 05/11 (20) (B26, F-T13-fwd5c): a transfer (c.transfer.N, any pass) that fails with why=net is a no-answer of the sending side: the head keeps "mạng đứt", the sentence is last ----
$NetOut = @('MOVE error rsync-failed why=net')
T 'L.no-answer-copy-why-net: c.transfer.N failing with why=net (first pass, refresh pass, the back direction) ends exit 1 with the "mạng đứt" head and the re-run sentence once as the last line; another failed transfer (rc=23, disk) has none (ruling 05/11 (20))' {
  Fx-Planned; Add-Fault -M new -Key '-c\.transfer\.1$' -Rc 1 -Out $NetOut
  [void](Do-Copy 1); EndsBareRerun; HasText 'mạng đứt'
  $t = $script:Last.Text; Ok ($t.IndexOf('mạng đứt') -ge 0 -and $t.IndexOf('mạng đứt') -lt $t.LastIndexOf($Rerun)) "the head comes before the sentence: $t"
  Eq (SentAny '-c\.adopt\.') 0 'nothing adopted after the failed transfer'
  Reset-World; Fx-Copied; Add-Fault -M new -Key '-c\.transfer\.[0-9]+$' -Rc 1 -Out $NetOut
  [void](Do-Copy 1); EndsBareRerun; HasText 'mạng đứt'
  Reset-World; Fx-Cut; Add-Fault -M new -Key '-c\.transfer\.[0-9]+$' -Rc 1 -Out $NetOut; Ans 'YES'
  $r = Run-Move @('back'); Eq $r.Code 1 "back exit ($($r.Text))"; EndsBareRerun; HasText 'Chép dữ liệu bị lỗi: why=net'; NoText 'chạy fcode move copy lại'   # the back's pre-copy shows the label only: "copy lại" would be wrong advice on `back`
  foreach ($o in @(@('MOVE error rsync-failed rc=23'), @('MOVE error disk'))) {
    Reset-World; Fx-Planned; Add-Fault -M new -Key '-c\.transfer\.1$' -Rc 1 -Out $o
    [void](Do-Copy -1); NoText $Rerun
  }
}
T 'L.no-answer-copy-why-net-status-failed: c.transfer.N whose stream is lost (no GATE_EXIT) while new''s status says call_state=failed and the partial lines hold the why=net line ends exit 1 with the re-run sentence once as the last line (the status-failed branch of Invoke-MoveCall marks the run; RV12-a)' {
  Fx-Planned; Add-Fault -M new -Key '-c\.transfer\.1$' -Rc 1 -Out $NetOut -Mode noexit
  [void](Do-Copy 1); EndsBareRerun; HasText 'mạng đứt'; HasText 'call_state=failed'
  Reset-World; Fx-Planned; Add-Fault -M new -Key '-c\.transfer\.1$' -Rc 1 -Out @('MOVE error rsync-failed rc=23') -Mode noexit
  [void](Do-Copy 1); NoText $Rerun
}
T 'L.no-answer-final-why-net: x.final failing with why=net keeps the exit codes of the code: a forward cutover rolls back (exit 10), a carry-back or a manual back ends 70; neither carries the re-run sentence (only exit 1 does; ruling 05/11 (20))' {
  Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Rc 1 -Out $NetOut
  [void](Do-Cutover -1); Assert-Rb; NoText $Rerun
  Reset-World; Start-Carry; Add-Fault -M new -Key '^back-2-x\.final$' -Rc 1 -Out $NetOut; Ans 'có'
  $r = Run-Move @('cutover'); Eq $r.Code 70 "carry-back exit ($($r.Text))"; NoText $Rerun
  Reset-World; Fx-Cut; Add-Fault -M new -Key '^back-2-x\.final$' -Rc 1 -Out $NetOut; Ans 'YES'
  $r = Run-Move @('back'); Eq $r.Code 70 "back exit ($($r.Text))"; NoText $Rerun
}
T 'L.no-answer-check-plan: check, plan and the 0c check-only that get no answer from old (no GATE_EXIT, or no facts / key) end with the re-run sentence, exit 1 (R10-INT-31)' {
  Add-Fault -M old -Key 'plan:check' -Mode noexit; $r = Run-Move @('check'); Eq $r.Code 1 "check exit ($($r.Text))"; EndsRerun "máy '$OldAlias' không trả lời khi kiểm tra (mã 0)."
  Reset-World; Add-Fault -M old -Key '^script:facts$' -Rc 255 -Out @(); $r = Run-Move @('check'); Eq $r.Code 1 "check, first contact lost ($($r.Text))"; EndsRerun "máy '$OldAlias' không trả lời khi nối (mã 255)."
  Reset-World; Add-Fault -M old -Key '^script:facts$' -Rc 255 -Out @(); $r = Do-Plan -Want 1; EndsRerun "máy '$OldAlias' không trả lời khi đọc dữ kiện (mã 255)."
  Reset-World; Add-Fault -M old -Key '^script:facts$' -Rc 255 -Out @() -Skip 1; $r = Do-Plan -Want -1; Ok ($r.Code -ne 0) "plan stops ($($r.Text))"; EndsRerun "máy '$OldAlias' không trả lời khi đọc dữ kiện (mã 255)."
  Reset-World; Add-Fault -M old -Key 'plan:full' -Mode noexit; $r = Do-Plan -Want -1; Ok ($r.Code -ne 0) "plan stops ($($r.Text))"; EndsRerun "máy '$OldAlias' không trả lời khi lập manifest (mã 0)."
  Reset-World; Fx-Copied; Add-Fault -M old -Key 'plan:check-only' -Mode noexit
  [void](Do-Cutover 1); EndsRerun "máy '$OldAlias' không trả lời khi kiểm tra trước (mã 0)."; Eq (Sent 'old' '-x\.freeze$') 0 'nothing frozen (0c check-only)'
}
# ---- DECISION-r2 (R10-INT-31, the count-free rule): the re-run sentence ends a run exactly when it ends 1 after a machine did not answer ----
function EndsWithRerunOnce {
  Ok ("$(LastLine)".EndsWith($Rerun)) "the last line ends with the re-run sentence (output: $($script:Last.Text))"
  Eq ([regex]::Matches($script:Last.Text, [regex]::Escape($Rerun)).Count) 1 'the re-run sentence once'
}
function Set-RebuildAddrs { foreach ($n in 'old', 'new') { $script:W[$n].MoveId.old_addr = $OldAddr; $script:W[$n].MoveId.new_addr = $NewAddr } }
# one fixture per verb's normal row (a refused row is never a fixture): Setup runs after Reset-World, Run is the verb
$SweepFx = [ordered]@{
  'check'        = @{ Setup = { };                                                                    Run = { Run-Move @('check') } }
  'plan'         = @{ Setup = { };                                                                    Run = { Do-Plan -Want -1 } }
  'copy-first'   = @{ Setup = { Fx-Planned };                                                         Run = { Run-Move @('copy') } }
  'copy-refresh' = @{ Setup = { Fx-Copied };                                                          Run = { Run-Move @('copy') } }
  'cutover'      = @{ Setup = { Fx-Copied };                                                          Run = { Ans 'có'; Run-Move @('cutover') } }
  'carry-resume' = @{ Setup = { Start-Carry };                                                        Run = { Ans 'có'; Run-Move @('cutover') } }
  'back'         = @{ Setup = { Fx-Cut };                                                             Run = { Ans 'YES'; Run-Move @('back') } }
  'finish'       = @{ Setup = { Fx-Cut };                                                             Run = { Ans 'YES'; Run-Move @('finish') } }
  'abort'        = @{ Setup = { Fx-Copied };                                                          Run = { Ans 'có'; Run-Move @('abort') } }
  'rebuild'      = @{ Setup = { Fx-Copied; [IO.File]::Delete((StatePath)); Set-RebuildAddrs };        Run = { Run-Move @('status', '--rebuild', $OldAlias, $NewAlias) } }
}
T 'L.no-answer-sweep: for every verb row, every machine and every position k at which the machine goes down for good (k = number of consults answered first): exit 1 ends with the re-run sentence once as the last line; exit 0, 10, 65, 70 and 75 never carry it; no other exit; no contract violation (R10-INT-31, DECISION-r2)' {
  $n = 0; $bad = New-Object Collections.ArrayList
  foreach ($fx in $SweepFx.Keys) { foreach ($m in 'old', 'new') {
    for ($k = 0; $k -le 400; $k++) {
      Reset-World; & $SweepFx[$fx].Setup
      Add-Fault -M $m -Key '.' -Mode down -N -1 -Skip $k
      $fault = $script:W.Faults[$script:W.Faults.Count - 1]
      $r = & $SweepFx[$fx].Run; $n++
      $tag = "[$fx, $m down from consult $k]"
      if ($script:W.Runaway) { [void]$bad.Add("$tag runaway: $($script:W.Runaway)") }
      if ($script:W.Violations.Count) { [void]$bad.Add("$tag contract violations: $(@($script:W.Violations | Select-Object -First 3) -join ' ; ')") }
      $cnt = [regex]::Matches($r.Text, [regex]::Escape($Rerun)).Count
      if ($r.Code -eq 1) {
        if (-not "$(LastLine)".EndsWith($Rerun) -or $cnt -ne 1) { [void]$bad.Add("$tag exit 1 without the sentence once as the last line (sentences $cnt; last line: $(LastLine))") }
      } elseif ($r.Code -in 0, 10, 65, 70, 75) {
        if ($cnt -ne 0) { [void]$bad.Add("$tag exit $($r.Code) carries the re-run sentence (last line: $(LastLine))") }
      } else { [void]$bad.Add("$tag exit $($r.Code) is not one of 0, 1, 10, 65, 70, 75 (last line: $(LastLine))") }
      if ($fault.Seen -le $k) { break }   # the machine was consulted at most k times: the fault never fired, the next k is the same run
    }
  } }
  Ok ($bad.Count -eq 0) "$($bad.Count) of $n sweep runs fail: $(@($bad | Select-Object -First 12) -join ' || ')"
  Ok ($n -gt 100) "the sweep ran ($n runs)"
}
T 'L.no-answer-copy-bootstrap-key: new dropped at copy (2) bootstrap key ends exit 1 with the bare re-run sentence last, no c.init-old (R10-INT-31, L11)' {
  Fx-Planned; Add-Fault -M new -Key '^script:bootstrap key$' -Mode down -N -1
  [void](Do-Copy 1); EndsBareRerun; Eq (SentAny '-c\.init-old') 0 'no c.init-old'
}
T 'L.no-answer-rebuild: status --rebuild with a machine (or the Reach-Old re-read) that does not answer ends with the B25 line "khi đọc lại trạng thái", exit 1, nothing written; old facts lost at the push scan end with the B25 line, no trailer (R10-INT-31, L12, L13)' {
  foreach ($m in @(@('old', $OldAlias), @('new', $NewAlias))) {
    Reset-World; Fx-Copied; [IO.File]::Delete((StatePath)); Set-RebuildAddrs; Add-Fault -M $m[0] -Key '^script:rebuild' -Mode down -N -1
    $r = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $r.Code 1 "[$($m[0])] exit ($($r.Text))"
    EndsRerun "máy '$($m[1])' không trả lời khi đọc lại trạng thái (mã 255)."; Ok (-not (Test-Path -LiteralPath (StatePath))) "[$($m[0])] nothing written"
  }
  Reset-World; Fx-Cut; [IO.File]::Delete((StatePath)); Set-RebuildAddrs   # after the step-11 swap the old alias reaches the machine new: its first read answers role=new, the re-read goes to old through Reach-Old
  Add-Fault -M old -Key '^script:rebuild' -Mode down -N -1
  $r = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $r.Code 1 "Reach-Old re-read exit ($($r.Text))"
  EndsRerun "máy '$OldAlias' không trả lời khi đọc lại trạng thái (mã 255)."; Ok (-not (Test-Path -LiteralPath (StatePath))) 'Reach-Old: nothing written'
  Reset-World; Fx-Copied; [IO.File]::Delete((StatePath)); Set-RebuildAddrs; Add-Fault -M old -Key '^script:facts$' -Mode down -N -1
  $r = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $r.Code 1 "push scan exit ($($r.Text))"
  EndsRerun "máy '$OldAlias' không trả lời khi đọc dữ kiện (mã 255)."; NoText 'không quét lại được repo'; Ok (-not (Test-Path -LiteralPath (StatePath))) 'push scan: nothing written'
}
T 'L.no-answer-chore0: the pre-rule chore 0 whose call is lost (the call itself, or its one status read) ends exit 1 with the re-run sentence last, once (R10-INT-31, L14)' {
  foreach ($shape in 1, 2) {
    Reset-World; Fx-Cut; [void](Patch-St @{ enabled = $false })
    if ($shape -eq 1) { Add-Fault -M new -Key '^fwd-1-x\.enable\.2$' -Mode down }
    else { Add-Fault -M new -Key '^fwd-1-x\.enable\.2$' -Mode noexit -Rc 0; Add-Fault -M new -Key '^status$' -Mode down -N 1 -Skip 1 }
    $r = Run-Move @('cutover'); Eq $r.Code 1 "[shape $shape] exit ($($r.Text))"; HasText "lỗi: chưa bật lại được máy đang phục vụ ('$NewAlias'); chạy lại lệnh vừa rồi để sửa."; EndsBareRerun; Eq (Get-St).enabled $false "[shape $shape] chore 0 not done"
  }
}
T 'L.no-answer-chore0-in-run: a chore 0 lost inside a cutover (step 10) ends with the generic line, "chạy lại fcode move cutover", then the bare re-run sentence last; inside a carry-back the return-to-old text comes first (R10-INT-31, RV10h3-1)' {
  $generic = "lỗi: chưa bật lại được máy đang phục vụ ('$NewAlias'); chạy lại lệnh vừa rồi để sửa."
  Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.enable\.1$' -Mode down; Ans 'có'
  $r = Run-Move @('cutover'); Eq $r.Code 1 "cutover exit ($($r.Text))"; EndsBareRerun; $t = $r.Text
  Ok ($t.IndexOf($generic) -ge 0 -and $t.IndexOf($generic) -lt $t.IndexOf('chạy lại fcode move cutover') -and $t.IndexOf('chạy lại fcode move cutover') -lt $t.LastIndexOf($Rerun)) "generic line, then the cutover-again text, then the sentence: $t"
  Reset-World; Start-Carry; Add-Fault -M old -Key '^back-2-x\.enable\.1$' -Mode down; Ans 'có'
  $r = Run-Move @('cutover'); Eq $r.Code 1 "carry-back exit ($($r.Text))"; EndsBareRerun; $t = $r.Text
  $g2 = "lỗi: chưa bật lại được máy đang phục vụ ('$OldAlias'); chạy lại lệnh vừa rồi để sửa."
  Ok ($t.IndexOf($g2) -ge 0 -and $t.IndexOf($g2) -lt $t.IndexOf('Đã quay về máy cũ; máy cũ đang phục vụ.') -and $t.IndexOf('Đã quay về máy cũ; máy cũ đang phục vụ.') -lt $t.IndexOf('chạy lại fcode move cutover') -and $t.IndexOf('chạy lại fcode move cutover') -lt $t.LastIndexOf($Rerun)) "generic line, return-to-old, cutover-again, sentence: $t"
}
T 'L.no-answer-finish-health: finish whose health read of new does not answer ends exit 1 with the B25 line "khi kiểm tra sức khỏe", no f.* call; a Known hold_active mismatch stays the health refusal without the sentence (R10-INT-31, L15)' {
  Fx-Cut; Add-Fault -M new -Key '^status$' -Mode down -N -1 -Skip 1; Ans 'YES'
  $r = Run-Move @('finish'); Eq $r.Code 1 "exit ($($r.Text))"; EndsRerun "máy '$NewAlias' không trả lời khi kiểm tra sức khỏe (mã 255)."; NoText 'Kiểm tra sức khỏe không đạt'; Eq (SentAny '-f\.(old|new)$') 0 'no f.* call'
  Reset-World; Fx-Cut; $W.new.Active = 1; Ans 'YES'
  $r = Run-Move @('finish'); Eq $r.Code 1 "mismatch exit ($($r.Text))"; HasText 'Kiểm tra sức khỏe không đạt'; NoText $Rerun; Eq (SentAny '-f\.(old|new)$') 0 'no f.* call'
}
T 'L.no-answer-carry-writeahead: a carry-back whose write-ahead agreement check finds old silent ends exit 1 with the B25 line last; a definite b.init-new failure at the write-ahead stays exit 70 (R10-INT-31, L16)' {
  Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Rc 69 -Out @('MOVE item app.service kind=unit state=failed ActiveState=failed') -Do { Add-Fault -M old -Key '^status$' -Mode down -N -1 }
  Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 1 "exit ($($r.Text))"; EndsRerun "máy '$OldAlias' không trả lời khi đọc status (mã 255)."
  Reset-World; Start-Carry; Add-Fault -M new -Key '^back-2-b\.init-new$' -Rc 1   # a definite failure at the write-ahead: no no-answer, so exit 70 and no sentence
  Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 70 "definite b.init-new failure ($($r.Text))"; NoText $Rerun
}
T 'L.no-answer-carry-binit: a carry-back whose b.init-old is lost asks Q-newlost with no re-run sentence before it: exit 70 without an answer, 10 with YES (R10-INT-31, L17)' {
  $hook = { Add-Fault -M old -Key '^back-2-b\.init-old$' -Rc 0 -Do { $W.new.Up = $false } }
  Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Rc 69 -Out @('MOVE item app.service kind=unit state=failed ActiveState=failed') -Do $hook
  Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 70 "no answer to Q-newlost ($($r.Text))"; HasText 'Máy mới không trả lời. Trước khi trả lời'; NoText $Rerun
  Reset-World; Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Rc 69 -Out @('MOVE item app.service kind=unit state=failed ActiveState=failed') -Do $hook
  Ans 'có', 'YES'; $r = Run-Move @('cutover'); Eq $r.Code 10 "Q-newlost YES ($($r.Text))"; NoText $Rerun
}
T 'L.no-answer-back-er19: a manual back whose x.freeze outcome stays unknown ends the E-R19 return with exit 1, "Chuyển ngược không xong", then the bare re-run sentence last; a definite x.freeze failure has no sentence (R10-INT-31, PR4)' {
  Fx-Cut; Add-Fault -M new -Key '^back-2-x\.freeze$' -Mode noexit -Rc 0; Add-Fault -M new -Key '^status$' -Mode down -N 1 -Skip 2; Ans 'YES'
  $r = Run-Move @('back'); Eq $r.Code 1 "exit ($($r.Text))"; EndsBareRerun; HasText 'Chuyển ngược không xong'
  Ok ($script:Last.Text.IndexOf('Chuyển ngược không xong') -lt $script:Last.Text.LastIndexOf($Rerun)) 'the sentence follows the E-R19 text'
  Reset-World; Fx-Cut; Add-Fault -M new -Key '^back-2-x\.freeze$' -Rc 1; Ans 'YES'
  $r = Run-Move @('back'); Eq $r.Code 1 "definite failure exit ($($r.Text))"; NoText $Rerun
}
T 'L.status-known-not-ok: a machine that answers status with GATE_EXIT 65 is shown with its label and ends by that code, never as a no-answer: the agreement check, the 0c gate-id read; with old Known-not-Ok and new unknown at 0c the B25 line names new (R10-INT-31 item 10, PR1, RV10h-5)' {
  Fx-Copied; $W.old.NoMove = $true; Ans 'có'
  $r = Run-Move @('cutover'); Eq $r.Code 65 "agreement exit ($($r.Text))"; HasText 'Máy cũ chưa cài bản gate có lệnh chuyển máy'; NoText $Rerun
  Reset-World; Fx-Copied; Add-Fault -M old -Key '^status$' -Mode nomove -Skip 1; Ans 'có'
  $r = Run-Move @('cutover'); Eq $r.Code 65 "0c exit ($($r.Text))"; HasText 'Máy cũ chưa cài bản gate có lệnh chuyển máy'; NoText $Rerun; Eq (Sent 'old' '-x\.freeze$') 0 'nothing frozen'
  Reset-World; Fx-Copied; Add-Fault -M old -Key '^status$' -Mode nomove -Skip 1; Add-Fault -M new -Key '^status$' -Mode down -N -1 -Skip 1; Ans 'có'
  $r = Run-Move @('cutover'); Eq $r.Code 1 "old Known-not-Ok and new unknown ($($r.Text))"; EndsRerun "máy '$NewAlias' không trả lời khi đọc status (mã 255)."; Eq (Sent 'old' '-x\.freeze$') 0 'nothing frozen'
}
T 'L.facts-rc1-plain: old facts that answered with rc 1 (no MOVE facts line, no transport loss) are "không đọc được dữ kiện máy cũ" with exit 1 and no re-run sentence: plan, check, rebuild push scan (R10-INT-31 item 11, RV10h-4)' {
  Add-Fault -M old -Key '^script:facts$' -Rc 1 -Out @(); $r = Do-Plan -Want 1; HasText "không đọc được dữ kiện máy cũ '$OldAlias' (mã 1)."; NoText $Rerun
  Reset-World; Add-Fault -M old -Key '^script:facts$' -Rc 1 -Out @(); $r = Run-Move @('check'); Eq $r.Code 1 "check exit ($($r.Text))"; HasText "không đọc được dữ kiện máy cũ '$OldAlias' (mã 1)."; NoText $Rerun
  Reset-World; Fx-Copied; [IO.File]::Delete((StatePath)); Set-RebuildAddrs; Add-Fault -M old -Key '^script:facts$' -Rc 1 -Out @()
  $r = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $r.Code 1 "rebuild exit ($($r.Text))"; HasText "không đọc được dữ kiện máy cũ '$OldAlias' (mã 1)."; NoText $Rerun
}
T 'L.no-answer-reach: the reach script lost at plan step 3b and at 0c (ssh 255) is the B25 line "khi kiểm tra kết nối ra ngoài", exit 1, nothing written / nothing frozen; a refused or silent connect (rc 1) is warn egress and the run goes on (R10-INT-31 item 12, O1)' {
  $W.Mf.egress = @([ordered]@{ addr = '192.0.2.50'; port = 443 }); Add-Fault -M new -Key '^script:tcp$' -Mode down -N -1
  $r = Do-Plan -Want 1; EndsRerun "máy '$NewAlias' không trả lời khi kiểm tra kết nối ra ngoài (mã 255)."; NothingWritten 'plan wrote nothing'
  Reset-World; $W.Mf.egress = @([ordered]@{ addr = '192.0.2.50'; port = 443 }); Fx-Copied; Add-Fault -M new -Key '^script:tcp$' -Mode down -N -1; Ans 'có'
  $r = Run-Move @('cutover'); Eq $r.Code 1 "0c exit ($($r.Text))"; EndsRerun "máy '$NewAlias' không trả lời khi kiểm tra kết nối ra ngoài (mã 255)."; Eq (Sent 'old' '-x\.freeze$') 0 'nothing frozen'
  Reset-World; $W.Mf.egress = @([ordered]@{ addr = '192.0.2.50'; port = 443 }); $W.TcpFail['192.0.2.50:443'] = $true
  [void](Do-Plan -Want 0); HasText 'Máy mới không kết nối ra được địa chỉ này'; NoText $Rerun; [void](Do-Copy 0); [void](Do-Cutover 0); HasText 'Máy mới không kết nối ra được địa chỉ này'; NoText $Rerun
}
T 'L.no-answer-never-at-skip: a verb that skips a silent new and then refuses or fails for its own reason has no re-run sentence (R10-INT-31, PR7, PR8)' {
  Fx-Planned; $W.new.Up = $false; Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 1 "PR7 exit ($($r.Text))"; HasText 'chạy copy trước'; NoText $Rerun
  Reset-World; Fx-Copied; $W.new.Up = $false; Add-Fault -M old -Key '\.a\.old$|a\.old$' -Rc 1; Ans 'có'
  $r = Run-Move @('abort'); Ok ($r.Code -ne 0) "PR8 exit ($($r.Text))"; NoText $Rerun
}
T 'L.no-answer-never-after-recovery: a carry-back that resolved a lost x.health and then ends 1 or 70 for its own reason carries no re-run sentence; the carry-back start clears the mark (R10-INT-31 item B, O2)' {
  $lost = { Add-Fault -M new -Key '^status$' -Mode down -N 1 }
  Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Rc 69 -Mode noexit -Do $lost; Add-Fault -M new -Key '^back-2-b\.init-new$' -Rc 1
  Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 70 "A: a definite b.init-new failure ($($r.Text))"; NoText $Rerun
  Reset-World; Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Rc 69 -Mode noexit -Do $lost; Add-Fault -M old -Key '^back-2-x\.enable\.1$' -Rc 1
  Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 1 "B: the back's chore 0 fails ($($r.Text))"; Eq "$(LastLine)" 'chạy lại fcode move cutover' 'B: the last line'; NoText $Rerun
}
T 'L.pre-egress-timeout: the reach script returns 1 for a connect that does not finish (timeout 124) and 1 for a refused one, 0 for a connect that works; 124 and 255 come only from the transport (R10-INT-31 item A, O1)' {
  $fr = New-FcmRoot
  foreach ($c in @(@(124, 1), @(1, 1), @(0, 0))) {
    $r = Run-Bash (Get-MoveTcpScript) @('192.0.2.50', '443') $fr (New-Stubs @{ timeout = "exit $($c[0])" }); Eq $r.Code $c[1] "timeout stub rc $($c[0]) -> script rc ($($r.Text))"
  }
} -NeedsBash
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
# D.5.2 / E-R23, ruling 05/11 (27) F-T13-fwd6-text: exit 70 after x.final ends with ONE last line: when new answered status the generic resume line,
# when new did not answer (down, or the status call got no gate answer) the carry-half sentence; never both
$CarryResume = 'Chạy lại fcode move cutover để tiếp tục chép ngược.'; $CarryHalf = 'dữ liệu máy cũ đang dở; chỉ tiếp tục được khi máy mới nối lại'
function CarryEnd([bool]$Answered, [string]$What = '') {
  $ll = @(Lines -Last | Where-Object { "$_".Trim() -ne '' }); $last = if ($ll.Count) { "$($ll[-1])" } else { '' }
  $want = if ($Answered) { $CarryResume } else { $CarryHalf }; $other = if ($Answered) { $CarryHalf } else { $CarryResume }
  Eq $last $want "$What last output line (new $(if ($Answered) { 'answered' } else { 'did not answer' }))"
  NoText $other
}
T 'L.carry-fail: a carry-back failure before x.final offers Q-discard (no answer: exit 70); after x.final started: exit 70, resume only' {
  Start-Carry; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1; Ans 'có'
  $r = Run-Move @('cutover'); Eq $r.Code 70 'exit'
  Ok (@(Lines | Where-Object { $_ -match '\AChép ngược tự động bị lỗi trước khi chép dữ liệu\. Chạy lại máy cũ với dữ liệu của nó\? Mọi thay đổi trên máy mới từ .* sẽ mất\. Gõ YES để xác nhận\.\z' }).Count -ge 1) "Q-discard text: $(Lines)"
  $ll = @(Lines | Where-Object { "$_".Trim() -ne '' }); Eq "$($ll[-1])" 'Chưa làm gì thêm. Chạy lại fcode move cutover để tiếp tục chép ngược.' 'Q-discard unanswered: last line (single spaces, the carry-resume text; review r12 P3)'
  Reset-World; Start-Carry; Add-Fault -M new -Key '^back-2-x\.final$' -Rc 1; Ans 'có'
  $r = Run-Move @('cutover'); Eq $r.Code 70 'exit after x.final'; CarryEnd $true 'carry-fail'
  Ok (@(Lines -Last | Where-Object { $_ -match 'Gõ YES' }).Count -eq 0) 'no Q-discard after x.final'
}
T 'L.carry-after-final-70: a carry-back failing after x.final started ends exit 70 with both status, never starts old' {
  Start-Carry; Add-Fault -M new -Key '^back-2-x\.final$' -Rc 1 -Mode noexit; Ans 'có'
  $r = Run-Move @('cutover'); Eq $r.Code 70 'exit'; Eq (SentAny '-r\.start-src$') 0 'old not started'; CarryEnd $true 'noexit'
  $l = LogNow; $i = [Array]::IndexOf($l, 'new back-2-x.final'); $after = @($l[($i + 1)..($l.Count - 1)])
  Ok ((@($after | Where-Object { $_ -ceq 'old status' }).Count -ge 1) -and (@($after | Where-Object { $_ -ceq 'new status' }).Count -ge 1)) "both status answers read: $($after -join ' ; ')"
}
T 'L.carry-after-final-70: new up but its status call gets no gate answer after x.final failed (exit 70): new did not answer, the carry-half sentence ends the output, never the resume line' {
  Start-Carry
  $W.Hooks['x.final'] = { param($m, $e) if ($e.Call -ceq 'back-2-x.final') { Add-Fault -M new -Key '^status$' -Mode timeout -N 5 } }
  Add-Fault -M new -Key '^back-2-x\.final$' -Rc 1; Ans 'có'
  $r = Run-Move @('cutover'); Eq $r.Code 70 "exit ($($r.Text))"; Eq (SentAny '-r\.start-src$') 0 'old not started'; CarryEnd $false 'status without gate answer'
  Ok (@(Lines -Last | Where-Object { $_ -match 'Gõ YES' }).Count -eq 0) 'no Q-discard after x.final'
}
T 'L.carry-after-final-70: new answers status with a gate answer that is not ok (GATE_EXIT 65, no MOVE state line) after x.final failed (exit 70): that is an answer, the resume line ends the output, never the carry-half sentence (the answered boundary is a gate answer, not an ok status; review r12 RV12L-1)' {
  Start-Carry
  $W.Hooks['x.final'] = { param($m, $e) if ($e.Call -ceq 'back-2-x.final') { Add-Fault -M new -Key '^status$' -Mode nomove -N 5 } }
  Add-Fault -M new -Key '^back-2-x\.final$' -Rc 1; Ans 'có'
  $r = Run-Move @('cutover'); Eq $r.Code 70 "exit ($($r.Text))"; Eq (SentAny '-r\.start-src$') 0 'old not started'
  Ok (@(Lines -Last | Where-Object { $_ -match '^\s*MOVE state ' }).Count -eq 1) "only old's MOVE state line: $(Lines -Last)"
  CarryEnd $true 'gate answer, not ok'
}
T 'L.carry-after-final-70: new unreachable after the carry-back''s x.final (at x.verify): exit 70, no YES question, old never started, also on the next cutover with new still down' {
  Start-Carry; Add-Fault -M new -Key '^back-2-x\.verify$' -Mode down; Ans 'có', 'YES', 'YES'
  $r = Run-Move @('cutover'); Eq $r.Code 70 "exit ($($r.Text))"; CarryEnd $false 'x.verify down'
  Ok (@(Lines | Where-Object { $_ -match 'Gõ YES' }).Count -eq 0) "no YES question: $(Lines)"
  Eq (SentAny '-r\.start-src$') 0 'old not started'; Ok ((Get-St).new_lost -ne $true) 'no new_lost'
  $r = Run-Move @('cutover'); Eq $r.Code 70 "next cutover, new down: exit $($r.Code)"; CarryEnd $false 'next cutover, new still down'
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
# E-R15 (D.5.2, D.5.3): once new answers again after a lost-new return or a discard, the next verb fences it FIRST: exactly one r.stop-dst (this attempt's id) on new, before any other call to new
T 'L.new-lost-return-fences: after Q-newlost YES (new_lost), when new answers status again the next verb sends exactly one fwd-1-r.stop-dst to new, and it is the first recorded call to new of that run; the same after a discarded carry-back (back-2-r.stop-dst)' {
  Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Mode down; [void](Do-Cutover 70); Ans 'YES'; $r = Run-Move @('cutover'); Eq $r.Code 10 "Q-newlost ($($r.Text))"; Eq (Get-St).new_lost $true 'new_lost'
  Eq (Sent 'new' '^fwd-1-r\.stop-dst$') 0 'fixture: no fence yet (new is down)'
  $W.new.Up = $true; $r = Run-Move @('copy'); Eq $r.Code 0 "copy after new came back ($($r.Text))"
  Eq (Sent 'new' '^fwd-1-r\.stop-dst$') 1 'exactly one r.stop-dst on new'; $first = @(RecCalls | Where-Object { $_.M -ceq 'new' } | Select-Object -First 1); Eq $first[0].Call 'fwd-1-r.stop-dst' "the fence is the first call to new: $(@(RecCalls | Where-Object { $_.M -ceq 'new' } | ForEach-Object { $_.Call }) -join ', ')"
  Reset-World; Start-Carry; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1; Ans 'có', 'YES'; $r = Run-Move @('cutover'); Eq $r.Code 10 "Q-discard YES ($($r.Text))"; Eq (Get-St).new_discarded $true 'new_discarded'
  # ADDENDUM: the YES return IS a rollback, so it stops new first when it answers: the fence is the first call to new of the YES run itself (one r.stop-dst) and is not re-executed by the next verb
  Eq (Sent 'new' '^back-2-r\.stop-dst$') 1 'exactly one r.stop-dst on new (the discard)'; $last = @(RecCalls | Where-Object { $_.M -ceq 'new' } | Select-Object -Last 1); Eq $last[0].Call 'back-2-r.stop-dst' 'the fence is the last call to new of the run (the return''s own first call, after the carry-back''s earlier calls)'
  $r = Run-Move @('copy'); Eq $r.Code 0 "copy after the discard ($($r.Text))"; Eq (Sent 'new' '^back-2-r\.stop-dst$') 0 'the fence is not executed again'
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
# ============================== DECISION-r5 (T1/T5/T10): every resume first waits for a running call of its attempt ==============================
# The fake models the server's lock: a machine whose unit runs answers 75 `busy` to EVERY other call, a re-sent done call (a replay) included; the status answers (Set-Running -Left = the polls it survives)
# are what the laptop waits on. A status fault is checked before the unit's Left is spent. The resume rows (cut-resume, carry-resume, rb-continue) wait first, never re-send a done call into the busy.
function NoBusy([string]$What) { $b = @(LogNow -All | Where-Object { $_ -match ' busy$' }); Eq $b.Count 0 "$What : no call answered busy: $($b -join ', ')" }
$TxtBusy = 'Máy cũ còn đang chạy lệnh trước; chạy lại  fcode move cutover , lệnh sẽ đợi lệnh đó xong.'; $TxtIncomplete = 'Máy cũ chưa chạy lại đủ: cần người xem (70). Sau khi sửa, chạy lại  fcode move cutover  để hoàn tất quay lại.'
# ruling B59 (a): a return to old (Q-discard YES, Q-newlost YES, a plain rollback, rb-continue: ONE path, Invoke-MoveRollback) first fences new, then WAITS, bounded, for a call still running on old (it would answer r.start-src busy):
# the resume rows' wait (polls 10 s, budget first_transfer_s + 60 = 21660 s); past the budget, 70 with the usual text, the state stays rolling-back (old not started) and `cutover` continues
function Hold-OldDo([string]$Call, [int]$Left) { $script:HoldCall = $Call; $script:HoldLeft = $Left; { Set-Running 'old' $script:HoldCall $script:HoldLeft } }   # the fault's side effect: old's call <Call> is still running (its unit survives <Left> status polls)
function Setup-HeldReturn([string]$Leg, [int]$Left) {   # Reset-World + the fixture of one leg up to (not including) the run that returns to old
  Reset-World
  switch ($Leg) {
    'carry-discard' { Start-Carry; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1 -Do (Hold-OldDo 'back-2-x.baseline' $Left); Ans 'có', 'YES'; return 'back-2' }
    'newlost'       { Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Mode down -Do (Hold-OldDo 'fwd-1-x.stop-src' $Left); [void](Do-Cutover 70); Ans 'YES'; return 'fwd-1' }
    'plain'         { Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Rc 1 -Do (Hold-OldDo 'fwd-1-x.stop-src' $Left); Ans 'có'; return 'fwd-1' }
  }
}
T 'L.return-waits-for-old-call: a call still running on old when the return to old starts (carry-back Q-discard YES, fwd Q-newlost YES, a plain rollback): the return fences new first, waits for it (the "đợi <call>" line, polls of old, no call answered busy), then r.start-src / r.unfreeze-src / r.health-src, and ends rolled-back, exit 10, old serving and enabled' {
  foreach ($leg in 'carry-discard', 'newlost', 'plain') {
    $p = Setup-HeldReturn $leg 3; $r = Run-Move @('cutover'); Eq $r.Code 10 "[$leg] the return completes ($($r.Text))"
    Ok (@(Lines | Where-Object { $_ -match '\Ađợi (fwd|back)-[0-9]+-\S+ trên ' }).Count -ge 1) "[$leg] the wait line is printed: $(Lines)"; NoBusy $leg
    foreach ($c in 'start', 'unfreeze', 'health') { Eq (Sent 'old' "^$p-r\.$c-src`$") 1 "[$leg] r.$c-src sent once" }
    if ($leg -cne 'newlost') { Ordered @("^new $p-r\.stop-dst`$", '^old status$', "^old $p-r\.start-src`$"); Eq (Sent 'new' "^$p-r\.stop-dst`$") 1 "[$leg] new fenced once" } else { Eq (Sent 'new' "^$p-r\.stop-dst`$") 0 "[$leg] new is down: no fence"; Ordered @('^old status$', "^old $p-r\.start-src`$") }
    $s = Get-St; Eq $s.phase 'rolled-back' "[$leg] phase"; Ok ($null -eq $s.mark) "[$leg] mark"; Eq $s.serving 'old' "[$leg] serving"; Eq $s.enabled $true "[$leg] enabled"; if ($leg -ne 'plain') { Eq $s.new_discarded ($leg -ceq 'carry-discard') "[$leg] new_discarded" }
    Eq $W.old.Active $Holds "[$leg] old serves"; Eq $W.old.Frozen $false "[$leg] old unfrozen"
  }
}
T 'L.return-busy-past-budget: the call on old outlives the wait (21660 s): the return ends 70 with "vẫn đang chạy <call>; chạy lại sau" and "Máy cũ chưa chạy lại đủ", sends no r.start-src / r.unfreeze-src / r.health-src, new was already fenced, the state stays rolling-back (serving old, enabled false, never rolled-back); once the call ended, `cutover` continues the return and ends 10' {
  foreach ($leg in 'carry-discard', 'newlost', 'plain') {
    $p = Setup-HeldReturn $leg 2400; $r = Run-Move @('cutover'); Eq $r.Code 70 "[$leg] ends 70 ($($r.Text))"
    HasText 'vẫn đang chạy'; HasText 'chạy lại sau'; HasText $TxtBusy; NoText $TxtIncomplete; Eq (SentAny "-r\.(start|unfreeze|health)-src`$") 0 "[$leg] no return call was sent into the busy"; NoBusy $leg
    if ($leg -cne 'newlost') { Eq (Sent 'new' "^$p-r\.stop-dst`$") 1 "[$leg] new was fenced before the wait" }
    $s = Get-St; Eq $s.mark 'rolling-back' "[$leg] mark kept"; Eq $s.serving 'old' "[$leg] serving"; Eq $s.enabled $false "[$leg] enabled"; Eq $s.carry $false "[$leg] carry"; Ok ($s.phase -cne 'rolled-back') "[$leg] never rolled-back"
    $W.old.Running = $null; $r = Run-Move @('cutover'); Eq $r.Code 10 "[$leg] cutover continues the return once the call ended ($($r.Text))"; Assert-OldServes $leg -NewDown:($leg -ceq 'newlost')
  }
}
# ruling B60 (a): the wait reads old's status FRESH (the agreement check's snapshot is stale: old was idle then), a wait that ends 75 (busy past the budget) or 1 (status unreadable) after the write-ahead cannot be returned: 70, state rolling-back, enabled
# false, no r.* sent; the texts: return-busy "Máy cũ còn đang chạy lệnh trước; chạy lại  fcode move cutover , lệnh sẽ đợi lệnh đó xong." (only busy 75 answers) vs return-incomplete "Máy cũ chưa chạy lại đủ: cần người xem (70)..." (a real failure)
T 'L.return-fresh-status: the agreement check saw old idle, then a call starts on old before the return reaches it: the return reads old''s status fresh, waits for that call (the "đợi" line, polls) and ends 10; a stale snapshot would send r.start-src into the busy' {
  $p = Setup-HeldReturn 'plain' 3; $r = Run-Move @('cutover'); Eq $r.Code 10 "plain rollback ($($r.Text))"
  Ok (@(Lines | Where-Object { $_ -match '\Ađợi fwd-1-x\.stop-src trên ' }).Count -ge 1) "the wait fired from the fresh status: $(Lines)"; NoBusy 'fresh'; NoText $TxtBusy; Assert-OldServes 'fresh'
  # one or two lost status answers (< retries = 3) are retried: the fresh read succeeds, the return goes on and ends 10 (never read as "not running", never 70)
  Reset-World; Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Rc 1; Add-Fault -M new -Key '^fwd-1-r\.stop-dst$' -Rc 0 -Do { Add-Fault -M old -Key '^status$' -Mode down -N 2 }; Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 10 "[blip] two lost status answers are retried ($($r.Text))"; NoText $TxtIncomplete; Assert-OldServes 'blip'
}
T 'L.return-busy-vs-failed-text: after the write-ahead a return that cannot finish ends 70 with the state rolling-back and enabled false, and names the cause: busy (75 only: the wait past the budget, r.start-src or r.unfreeze-src answering busy) prints the return-busy text, a real failure (rc 1, an unreadable fresh status, busy mixed with a failure) the return-incomplete text; `cutover` then continues and ends 10' {
  $legs = [ordered]@{
    'start busy'        = @{ Fault = { Add-Fault -M old -Key '^fwd-1-r\.start-src$' -Rc 75 -N 1 }; Busy = $true; Sent = $true }
    'unfreeze busy'     = @{ Fault = { Add-Fault -M old -Key '^fwd-1-r\.unfreeze-src$' -Rc 75 -N 1 }; Busy = $true; Sent = $true }
    'start rc 1'        = @{ Fault = { Add-Fault -M old -Key '^fwd-1-r\.start-src$' -Rc 1 -N 1 }; Busy = $false; Sent = $true }
    'busy and failure'  = @{ Fault = { Add-Fault -M old -Key '^fwd-1-r\.start-src$' -Rc 75 -N 1; Add-Fault -M old -Key '^fwd-1-r\.unfreeze-src$' -Rc 1 -N 1 }; Busy = $false; Sent = $true }
    'status unreadable' = @{ Fault = { Add-Fault -M new -Key '^fwd-1-r\.stop-dst$' -Rc 0 -Do { Add-Fault -M old -Key '^status$' -Mode down -N 3 } }; Busy = $false; Sent = $false }
  }
  foreach ($k in $legs.Keys) {
    Reset-World; Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Rc 1 -Do $legs[$k].Fault; Ans 'có'
    $r = Run-Move @('cutover'); Eq $r.Code 70 "[$k] ends 70 ($($r.Text))"
    if ($legs[$k].Busy) { HasText $TxtBusy; NoText $TxtIncomplete } else { HasText $TxtIncomplete; NoText $TxtBusy }
    if (-not $legs[$k].Sent) { Eq (SentAny "-r\.(start|unfreeze|health)-src`$") 0 "[$k] nothing sent to old after the unreadable status" }
    $s = Get-St; Eq $s.mark 'rolling-back' "[$k] mark kept"; Eq $s.serving 'old' "[$k] serving"; Eq $s.enabled $false "[$k] enabled"; Ok ($s.phase -cne 'rolled-back') "[$k] never rolled-back"
    $r = Run-Move @('cutover'); Eq $r.Code 10 "[$k] cutover continues ($($r.Text))"; Assert-OldServes $k
  }
}
T 'L.fake-busy-on-done-replay: while another call''s unit runs, a re-sent DONE call answers 75 busy (nothing replayed, record untouched); with no unit running the same call is a replay' {
  Fx-Cutting0; Set-Running 'new' 'fwd-1-x.final'; $S = Read-MoveState
  $r = Invoke-MoveCall $S 'new' 'x.stop-dst' -Quiet; Eq $r.Code 75 "busy ($($r.Lines -join ' '))"; Ok (@(LogNow | Where-Object { $_ -match '^new fwd-1-x\.stop-dst busy$' }).Count -eq 1) "busy logged: $(LogNow)"
  Eq ([int]$W.new.Rec['fwd-1-x.stop-dst'].Rc) 0 'the done record is untouched'; Eq (Sent 'new' '^fwd-1-x\.stop-dst$') 1 'sent (counted: it was not a replay)'
  $W.new.Running = $null; $r = Invoke-MoveCall $S 'new' 'x.stop-dst' -Quiet; Eq $r.Code 0 'replay'; Ok (@(Calls | Where-Object { $_.Call -ceq 'fwd-1-x.stop-dst' -and $_.Replay }).Count -eq 1) 'a replay'
}
T 'L.resume-waits-for-running-call: cutover resumes a cutting run whose x.check unit still runs on old: the laptop prints the wait line and waits, no call answered busy, x.freeze / x.check are replayed, exit 0 phase cut' {
  Fx-Cutting0; Set-Running 'old' 'fwd-1-x.check' 2
  $r = Run-Move @('cutover'); Eq $r.Code 0 "resume ($($r.Text))"; Eq (Get-St).phase 'cut' 'phase'; HasText 'đợi fwd-1-x.check'; NoBusy 'cut-resume'
  Eq (Sent 'old' '^fwd-1-x\.freeze$') 0 'x.freeze replayed'; Eq (SentAny '^fwd-1-x\.freeze$') 1 'x.freeze sent again'; Eq (Sent 'old' '^fwd-1-x\.check$') 0 'x.check replayed, not run'; Eq (SentAny '^fwd-1-x\.check$') 1 'x.check sent again'
}
T 'L.resume-waits-then-failed: the running x.check ends rc 1: after the wait the resume rolls back (10) from the status it refreshed; the failed call is not re-sent' {
  Fx-Cutting0; Set-Running 'old' 'fwd-1-x.check' 2 1
  $r = Run-Move @('cutover'); Eq $r.Code 10 "plain rollback ($($r.Text))"; Eq (Get-St).phase 'rolled-back' 'phase'; HasText 'đợi fwd-1-x.check'; NoBusy 'cut-resume'
  Eq (SentAny '^fwd-1-x\.check$') 0 'the failed x.check is not sent again'; Eq (Sent 'old' '^fwd-1-r\.start-src$') 1 'old restarted'
}
T 'L.resume-started-waits: dst started (x.start done), new''s x.health unit still runs: the resume waits, no call answered busy, no back-* call (no carry-back), exit 0 phase cut' {
  Fx-CuttingStarted; Add-Rec 'new' 'fwd-1-x.start' 0; Set-Running 'new' 'fwd-1-x.health' 2
  $r = Run-Move @('cutover'); Eq $r.Code 0 "resume ($($r.Text))"; Eq (Get-St).phase 'cut' 'phase'; HasText 'đợi fwd-1-x.health'; NoBusy 'cut-resume (dst started)'; Eq (SentAny '^back-') 0 'no back-* call'
}
T 'L.carry-resume-waits: a carry-back stopped while new''s x.stop-src unit still runs: `cutover` waits, never re-sends b.init-new into the busy, no Q-newlost / Q-discard question, ends back-done (10)' {
  Fx-Carry; Set-Running 'new' 'back-2-x.stop-src' 2
  $r = Run-Move @('cutover'); Eq $r.Code 10 "resume ($($r.Text))"; Eq (Get-St).phase 'back-done' 'phase'; HasText 'đợi back-2-x.stop-src'; NoBusy 'carry-resume'; Eq $W.Prompts.Count 0 "no question asked: $($W.Prompts -join ' | ')"
}
T 'L.carry-resume-final-running: the carry-back''s x.final unit still runs on new (steps up to x.stop-dst done): carry-resume waits for it too (the b.init-* go to new before it), no busy, ends 10' {
  Fx-Carry; Add-Rec 'new' 'back-2-x.freeze'; Add-Rec 'new' 'back-2-x.stop-src'; Add-Rec 'old' 'back-2-x.stop-dst'; Set-Running 'new' 'back-2-x.final' 2
  $r = Run-Move @('cutover'); Eq $r.Code 10 "resume ($($r.Text))"; Eq (Get-St).phase 'back-done' 'phase'; HasText 'đợi back-2-x.final'; NoBusy 'carry-resume (x.final)'; Eq $W.Prompts.Count 0 'no question asked'
}
T 'L.rb-continue-waits: a plain rollback under way while old''s r.unfreeze-src unit still runs: the continuation waits, no busy, ends 10 with enabled true' {
  Fx-RollingBack; Add-Rec 'old' 'fwd-1-r.start-src' 0; Set-Running 'old' 'fwd-1-r.unfreeze-src' 2
  $r = Run-Move @('cutover'); Eq $r.Code 10 "continued rollback ($($r.Text))"; Eq (Get-St).phase 'rolled-back' 'phase'; HasText 'đợi fwd-1-r.unfreeze-src'; NoBusy 'rb-continue'; Eq (Get-St).enabled $true 'enabled'
}
# a status poll inside the wait that fails is retried (never "not running"). $AgreeReads = the status answers a machine gives before the wait's first poll: the agreement check reads each machine once (it retries only a not-Known answer) and a resumed run has its mark set, so no pre-rule runs; Skip 1 makes the FIRST poll inside the wait fail
$AgreeReads = 1
T 'L.resume-wait-status-blip: the first status poll INSIDE the wait fails (one transport loss): the wait retries and goes on, never reads it as "not running": no busy, no Q-newlost / Q-discard, carry-back ends back-done (10)' {
  Fx-Carry; Set-Running 'new' 'back-2-x.stop-src' 3; Add-Fault -M new -Key '^status$' -Mode down -N 1 -Skip $AgreeReads
  $r = Run-Move @('cutover'); Eq $r.Code 10 "resume ($($r.Text))"; Eq (Get-St).phase 'back-done' 'phase'; HasText 'đợi back-2-x.stop-src'; NoBusy 'blip'; Eq $W.Prompts.Count 0 "no question asked: $($W.Prompts -join ' | ')"
  Eq $W.Faults[$W.Faults.Count - 1].N 0 'the status fault was used (inside the wait)'
}
T 'L.resume-wait-status-lost: the status of new stays unreadable inside the wait: the wait retries `retries` times, then the run ends 1 as a no-answer, nothing written, no call sent to new' {
  Fx-Carry; Set-Running 'new' 'back-2-x.stop-src' 3; Add-Fault -M new -Key '^status$' -Mode down -N -1 -Skip $AgreeReads
  $r = Run-Move @('cutover'); Eq $r.Code 1 "no-answer ($($r.Text))"; Eq @(RecCalls | Where-Object { $_.M -ceq 'new' }).Count 0 "no call sent to new: $(@(RecCalls | ForEach-Object { $_.M + ' ' + $_.Call }) -join ', ')"
  Eq $W.Prompts.Count 0 'no question asked'; Ok (@(Lines -Last | Where-Object { $_ -match 'khi đợi lệnh đang chạy' }).Count -ge 1) "the no-answer line names the wait: $(Lines -Last)"; Eq (Get-St).phase 'planned' 'nothing written'
}
T 'L.resume-wait-status-refused: inside the wait the status of new is answered by a refusal (a gate with no --move, Known but not Ok): the run ends as the agreement check does (a refusal), never reads it as "not running"; nothing written, no call sent to new, no question' {
  Fx-Carry; Set-Running 'new' 'back-2-x.stop-src' 3; Add-Fault -M new -Key '^status$' -Mode nomove -N -1 -Skip $AgreeReads
  $r = Run-Move @('cutover'); Ok ($r.Code -ne 0 -and $r.Code -ne 10) "the run ends with a refusal, not a success ($($r.Code): $($r.Text))"; Eq @(RecCalls | Where-Object { $_.M -ceq 'new' }).Count 0 "no call sent to new: $(@(RecCalls | ForEach-Object { $_.M + ' ' + $_.Call }) -join ', ')"
  Eq $W.Prompts.Count 0 "no question asked: $($W.Prompts -join ' | ')"; Eq (Get-St).phase 'planned' 'nothing written'; NoBusy 'refused'
}
T 'L.resume-wait-status-blip-cut: the same blip on a cut-resume (x.check running on old): the resume waits on, no Q-drain, the failed status is not stored (the failed-call check still sees the real status), ends cut' {
  Fx-Cutting0; Set-Running 'old' 'fwd-1-x.check' 3; Add-Fault -M old -Key '^status$' -Mode down -N 1 -Skip $AgreeReads
  $r = Run-Move @('cutover'); Eq $r.Code 0 "resume ($($r.Text))"; Eq (Get-St).phase 'cut' 'phase'; NoBusy 'cut blip'; Eq $W.Prompts.Count 0 "no question asked: $($W.Prompts -join ' | ')"
  Eq $W.Faults[$W.Faults.Count - 1].N 0 'the status fault was used (inside the wait)'
}
# a same-second tie: the unit's record does not sort last (its `start` equals the call before it): the server names the RUNNING call anyway (status rule, R16 r8), so the resume still waits
T 'L.resume-waits-same-second-tie: old''s x.check unit runs but the latest record is the call before it (x.stop-src stays `Last`, a same-second tie): status still names the running call, `cutover` waits for it, no call answered busy, exit 0 phase cut' {
  Fx-Cutting0; Set-Running 'old' 'fwd-1-x.check' 3 -Tie; Eq $W.old.Last 'fwd-1-x.stop-src' 'fixture: the running call is not Last'
  $s0 = Get-MoveStatus (Read-MoveState) 'old' -Quiet; Eq ([string]$s0.Kv['call']) 'fwd-1-x.check' 'status names the running call'; Eq ([string]$s0.Kv['call_state']) 'running' 'call_state'; Eq ([string]$s0.Kv['rc']) '-' 'rc empty while running'
  $r = Run-Move @('cutover'); Eq $r.Code 0 "resume ($($r.Text))"; Eq (Get-St).phase 'cut' 'phase'; HasText 'đợi fwd-1-x.check'; NoBusy 'cut-resume (tie)'
}
T 'L.resume-started-waits-same-second-tie: dst started, new''s x.health unit runs and x.start (done) stays `Last` (the x.start -> x.health tie): the resume waits, no busy, no carry-back (no back-* call), exit 0 phase cut' {
  Fx-CuttingStarted; Add-Rec 'new' 'fwd-1-x.start' 0; Set-Running 'new' 'fwd-1-x.health' 3 -Tie; Eq $W.new.Last 'fwd-1-x.start' 'fixture: x.start is Last'
  $r = Run-Move @('cutover'); Eq $r.Code 0 "resume ($($r.Text))"; Eq (Get-St).phase 'cut' 'phase'; HasText 'đợi fwd-1-x.health'; NoBusy 'cut-resume (dst started, tie)'; Eq (SentAny '^back-') 0 'no back-* call'
}
# the wait is bounded (first_transfer_s + 60 s = 21660 s, polls 10 s apart): a unit that outlives it ends the run 75 "chạy lại sau" with nothing written; Left 2200 polls = 22000 s
T 'L.resume-wait-deadline: old''s x.check unit outlives the wait''s deadline: the run ends 75 with the "vẫn đang chạy ... chạy lại sau" line, state.json unchanged, no call sent to either machine, no question' {
  Fx-Cutting0; Set-Running 'old' 'fwd-1-x.check' 2200; $t0 = [IO.File]::ReadAllText((StatePath))
  $r = Run-Move @('cutover'); Eq $r.Code 75 "deadline ($($r.Text))"; HasText 'vẫn đang chạy fwd-1-x.check'; HasText 'chạy lại sau'
  Eq ([IO.File]::ReadAllText((StatePath))) $t0 'state.json unchanged'; Eq @(RecCalls).Count 0 "no recorded call: $(@(RecCalls | ForEach-Object { $_.M + ' ' + $_.Call }) -join ', ')"; Eq $W.Prompts.Count 0 'no question asked'; NoBusy 'deadline'
}
# the completion window: `_mvr_unit_end` writes the unit's rc before the unit exits, so a status can read call_state=running WITH an rc; the unit still holds the call lock, so the wait keeps waiting (the rc is not "done")
T 'L.resume-wait-completion-window: old''s x.check unit has written its rc 0 but still runs (status: call_state=running, rc=0): the wait does not read the rc as "finished" - it waits until the unit is done, no call answered busy, x.freeze / x.check replayed, exit 0 phase cut' {
  Fx-Cutting0; Set-Running 'old' 'fwd-1-x.check' 3 -RcRecorded
  $s0 = Get-MoveStatus (Read-MoveState) 'old' -Quiet; Eq ([string]$s0.Kv['call_state']) 'running' 'call_state'; Eq ([string]$s0.Kv['rc']) '0' 'rc already recorded while running'
  $r = Run-Move @('cutover'); Eq $r.Code 0 "resume ($($r.Text))"; Eq (Get-St).phase 'cut' 'phase'; HasText 'đợi fwd-1-x.check'; NoBusy 'cut-resume (completion window)'
  Eq (Sent 'old' '^fwd-1-x\.check$') 0 'x.check replayed, not run again'
}
T 'L.resume-wait-completion-window-failed: the unit has written rc 1 but still runs (call_state=running, rc=1): the wait waits for it to end, then the resume rolls back (10) from the refreshed status; nothing is re-sent into the busy' {
  Fx-Cutting0; Set-Running 'old' 'fwd-1-x.check' 3 1 -RcRecorded
  $r = Run-Move @('cutover'); Eq $r.Code 10 "plain rollback ($($r.Text))"; Eq (Get-St).phase 'rolled-back' 'phase'; HasText 'đợi fwd-1-x.check'; NoBusy 'cut-resume (completion window, failed)'; Eq (SentAny '^fwd-1-x\.check$') 0 'the failed x.check is not sent again'
}
T 'L.carry-resume-completion-window: a carry-back whose new x.stop-src unit has written its rc but still runs: carry-resume waits, never re-sends b.init-new into the busy, no question, ends back-done (10)' {
  Fx-Carry; Set-Running 'new' 'back-2-x.stop-src' 3 0 -RcRecorded
  $r = Run-Move @('cutover'); Eq $r.Code 10 "resume ($($r.Text))"; Eq (Get-St).phase 'back-done' 'phase'; HasText 'đợi back-2-x.stop-src'; NoBusy 'carry-resume (completion window)'; Eq $W.Prompts.Count 0 "no question asked: $($W.Prompts -join ' | ')"
}
function CallShas([string]$M, [string]$Rx) { @(RecCalls | Where-Object { $_.M -ceq $M -and $_.Call -match $Rx } | ForEach-Object { [string]$_.Flags['sha'] }) }
function ShaRefusals { @(LogNow -All | Where-Object { $_ -match ' sha$' }) }
# ============================== T14-PRE rework (FINDINGS INT / S5): finish after f.old, lost x.repin, x.check without a manifest, missing move-id, carry-back answers ==============================
# finish: once f.old has run, old's door answers every call but status `moved` (D.12.2) - a re-sent f.old can never be replayed. The laptop must read old's state (finished = f.old is done) and go on to f.new.
T 'L.finish-rerun-after-f.old: f.old ran, f.new was lost (new unreachable): finish ends 1 with phase cut; the re-run does NOT re-send f.old into old''s door (moved), sends f.new, ends 0 and phase finished' {
  Fx-Cut; Add-Fault -M new -Key '-f\.new$' -Mode down; Ans 'YES'; $r = Run-Move @('finish'); Ok ($r.Code -ne 0) "finish fails with new down ($($r.Text))"; Eq (Get-St).phase 'cut' 'phase stays cut'
  Eq $W.old.MoveId.state 'finished' 'old is finished (f.old ran)'; Eq (Sent 'old' '-f\.old$') 1 'f.old sent once'
  $W.new.Up = $true; Ans 'YES'; $r = Run-Move @('finish'); Eq $r.Code 0 "the re-run finishes ($($r.Text))"; Eq (Get-St).phase 'finished' 'phase'
  Eq (Sent 'old' '-f\.old$') 0 'the re-run sends no f.old'; Eq (SentAny '-f\.old$') 0 'no f.old at all in the re-run (not even into the door)'; Eq (Sent 'new' '-f\.new$') 1 'f.new sent'
  Eq @(LogNow | Where-Object { $_ -match 'door-moved' }).Count 0 "nothing hit the door: $(LogNow)"; Eq $W.new.MoveId.state 'finished' 'new finished'
}
T 'L.finish-f.old-answer-lost: f.old ran to the end but its answer was lost (no GATE_EXIT): finish goes on with f.new (f.old is done, not re-sent into the door), ends 0 and phase finished' {
  Fx-Cut; Add-Fault -M old -Key '-f\.old$' -Rc 0 -Mode noexit; Ans 'YES'; $r = Run-Move @('finish'); Eq $r.Code 0 "finish ($($r.Text))"; Eq (Get-St).phase 'finished' 'phase'
  Eq (Sent 'new' '-f\.new$') 1 'f.new sent'; Eq $W.old.MoveId.state 'finished' 'old finished'; Eq $W.new.MoveId.state 'finished' 'new finished'
}
# a lost x.repin to dst: the ssh drops with no GATE_EXIT and dst's I16 status fails too, so the call ends -1 at once; the unit still runs to the end and pins B on dst. The plain rollback's r.stop-dst then
# meets dst's sha hook (the pin is B, the laptop still sends A): the laptop must not end in a 70 loop
T 'L.repin-dst-lost-rollback: x.repin to new is lost (no GATE_EXIT, the status of new fails too) but new pinned B: the rollback''s r.stop-dst is not stuck on what=sha - it ends 10 (rolled-back, old serving, new stopped), never 70, and a re-run has nothing to repair' {
  Fx-Copied; $A = (Get-St).manifest_sha
  Add-Fault -M new -Key '^fwd-1-x\.repin$' -Rc 0 -Mode noexit -Do { Add-Fault -M new -Key '^status$' -Mode down -N 1 }
  Ans 'có'; $r = Run-Move @('cutover'); $B = $W.LastSha; Ok ($B -cne $A) 'fixture: x.check re-pinned old'; Eq $W.new.Sha $B 'the unit pinned B on new (ssh loss never stops the unit)'
  Eq $r.Code 10 "plain rollback ($($r.Text))"; Eq (Get-St).phase 'rolled-back' 'phase'; Eq (Get-St).serving 'old' 'serving'
  Eq (SentAny '^fwd-1-r\.stop-dst$') 2 'r.stop-dst sent twice: A (refused what=sha), then the same id with B'; Eq (@(CallShas 'new' '^fwd-1-r\.stop-dst$') -join ' ') "$A $B" 'the re-send carries manifest_sha'; Ok ([int]$W.new.Rec['fwd-1-r.stop-dst'].Rc -eq 0) 'r.stop-dst is done on new'; Eq $W.new.Active 0 'new stopped'; Eq $W.old.Active $Holds 'old serves again'; Eq $W.old.Frozen $false 'old unfrozen'
  Ok (-not [string](Get-St).manifest_sha_prev) "manifest_sha_prev cleared (new pins B): [$((Get-St).manifest_sha_prev)]"
}
T 'L.repin-dst-lost-rollback-rerun: the same loss, but the first rollback could not reach new (down): the re-run (rb-continue) does not loop on what=sha either: r.stop-dst is accepted, ends 10' {
  Fx-Copied
  Add-Fault -M new -Key '^fwd-1-x\.repin$' -Rc 0 -Mode noexit -Do { Add-Fault -M new -Key '^status$' -Mode down -N 1 }
  Add-Fault -M new -Key '^fwd-1-r\.stop-dst$' -Rc 1 -Out @('MOVE error busy') -N 1
  Ans 'có'; $r1 = Run-Move @('cutover'); Ok ($r1.Code -ne 0) "the first run does not finish ($($r1.Text))"
  Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 10 "the re-run finishes the rollback ($($r.Text))"; Eq (Get-St).phase 'rolled-back' 'phase'; Eq @(LogNow | Where-Object { $_ -match ' sha$' }).Count 0 "no what=sha refusal in the re-run: $(@(LogNow | Where-Object { $_ -match ' sha$' }))"
}
# x.check rc 0 without a usable `MOVE manifest` line: the plan is stale (the drift x.check found is lost); never goes on to x.repin with the old manifest over x.check's pin
T 'L.x-check-no-manifest: x.check answers rc 0 with no MOVE manifest line: the cutover rolls back (10) before any x.repin; old is restarted and unfrozen' {
  Fx-Copied; $W.CheckNoPin = $true; Add-Fault -M old -Key '^fwd-1-x\.check$' -Rc 0 -Out @('INV ok')
  Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 10 "plain rollback ($($r.Text))"; Eq (Get-St).phase 'rolled-back' 'phase'; Eq (SentAny '-x\.repin$') 0 'no x.repin sent'; Eq (Sent 'old' '^fwd-1-r\.start-src$') 1 'old restarted'; Eq $W.old.Frozen $false 'old unfrozen'
}
T 'L.x-check-corrupt-manifest: x.check rc 0 with a MOVE manifest line whose sha does not match its bytes: the same rollback, no x.repin' {
  Fx-Copied; $W.CheckNoPin = $true; Add-Fault -M old -Key '^fwd-1-x\.check$' -Rc 0 -Out @('MOVE manifest sha=' + ('c' * 64) + ' gz64=H4sIAAAAAAAAA6tWyk0tSczJSVWyMjQ0UMrIL8lQKAAA6DJ3pyEAAAA=')
  Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 10 "plain rollback ($($r.Text))"; Eq (Get-St).phase 'rolled-back' 'phase'; Eq (SentAny '-x\.repin$') 0 'no x.repin sent'
}
# FINDINGS-r2 S5 (P2): x.check to old is lost (no GATE_EXIT, old's one I16 status fails, so the call ends -1 at once) but the unit ran to the end and pinned B on old. The plain rollback's calls to SRC (old) carry A and are
# refused what=sha (no record): the laptop must take x.check's recorded answer (a replay) to learn B, then re-send the refused call with it - never end 70 with old frozen
T 'L.x-check-lost-rollback: x.check to old is lost but old pinned B: the rollback''s r.start-src / r.unfreeze-src / r.health-src on old are refused what=sha once, the laptop replays this attempt''s x.check, takes its MOVE manifest line (manifest_sha = B, manifest_sha_prev = new''s A), re-sends and ends 10: rolled-back, old unfrozen and serving, never 70' {
  Fx-Copied; $A = (Get-St).manifest_sha
  Add-Fault -M old -Key '^fwd-1-x\.check$' -Rc 0 -Mode noexit -Do { Add-Fault -M old -Key '^status$' -Mode down -N 1 }
  Ans 'có'; $r = Run-Move @('cutover'); $B = $W.LastSha; Ok ($B -cne $A) 'fixture: x.check re-pinned old'; Eq $W.old.Sha $B 'the unit pinned B on old (ssh loss never stops the unit)'
  Eq $r.Code 10 "plain rollback ($($r.Text))"; Eq (Get-St).phase 'rolled-back' 'phase'; Eq (Get-St).serving 'old' 'serving'
  Eq $W.old.Frozen $false 'old unfrozen'; Eq $W.old.Active $Holds 'old serves again'; Eq $W.old.Enabled $true 'old enabled'; Eq (Get-St).enabled $true 'state enabled'
  Eq (@(CallShas 'old' '^fwd-1-r\.start-src$') -join ' ') "$A $B" 'r.start-src: A (refused what=sha), then the same id with B'; Eq (Sent 'old' '^fwd-1-x\.check$') 1 'x.check ran once'; Eq (SentAny '^fwd-1-x\.check$') 2 'x.check was replayed once (the recovery)'
  Eq (Get-St).manifest_sha $B 'manifest_sha = B'; Eq (Get-Sha256Hex ([IO.File]::ReadAllBytes((Join-Path (MoveDir) 'manifest.json')))) $B 'manifest.json = B'; Eq (SentAny '-x\.repin$') 0 'no x.repin'
  foreach ($st in 'r.unfreeze-src', 'r.health-src') { Eq (@(CallShas 'old' "^fwd-1-$([regex]::Escape($st))$") -join ' ') $B "$st carries B" }
}
T 'L.x-check-lost-rollback-rerun: the same loss, but the re-sent r.start-src of the recovery is lost too (old drops again): the run does not finish; after old answers again the next verb is `cutover` (the state stays rolling-back, `copy` is refused): rb-continue re-sends the return''s calls from the saved B (no what=sha refusal), never chore 0' {
  Fx-Copied
  Add-Fault -M old -Key '^fwd-1-x\.check$' -Rc 0 -Mode noexit -Do { Add-Fault -M old -Key '^status$' -Mode down -N 1 }
  Add-Fault -M old -Key '^fwd-1-r\.start-src$' -Mode down -N 1
  Ans 'có'; $r1 = Run-Move @('cutover'); $B = $W.LastSha; Ok ($r1.Code -ne 0 -and $r1.Code -ne 10) "the first run does not finish ($($r1.Code): $($r1.Text))"; Eq (Get-St).manifest_sha $B 'the recovery saved B'; Eq (Get-St).mark 'rolling-back' 'the write-ahead state stays'
  $W.old.Up = $true; $rc = Run-Move @('copy'); Ok ($rc.Code -ne 0) "copy is refused while the return is unfinished ($($rc.Text))"
  $r = Run-Move @('cutover'); Eq $r.Code 10 "cutover continues the return from the saved B ($($r.Text))"; Eq (Get-St).phase 'rolled-back' 'phase'; Eq $W.old.Frozen $false 'old unfrozen'; Eq $W.old.Active $Holds 'old serves again'; Eq (Sent 'old' '-x\.enable\.') 0 'no chore 0'
  foreach ($st in 'r.start-src', 'r.unfreeze-src', 'r.health-src') { Eq (@(CallShas 'old' "^fwd-1-$([regex]::Escape($st))$") -join ' ') $B "$st carries B" }
  Eq @(LogNow | Where-Object { $_ -match ' sha$' }).Count 0 "no what=sha refusal in the next verb: $(@(LogNow | Where-Object { $_ -match ' sha$' }))"
}
T 'L.x-check-lost-unpinned-rollback: the lost x.check did NOT pin (old still pins A): the rollback''s calls to old carry A and pass - no what=sha, no x.check replay, ends 10 as before' {
  Fx-Copied; $W.CheckNoPin = $true
  Add-Fault -M old -Key '^fwd-1-x\.check$' -Rc 0 -Mode noexit -Do { Add-Fault -M old -Key '^status$' -Mode down -N 1 }
  Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 10 "plain rollback ($($r.Text))"; Eq (Get-St).phase 'rolled-back' 'phase'; Eq $W.old.Frozen $false 'old unfrozen'
  Eq (SentAny '^fwd-1-x\.check$') 1 'no replay of x.check (nothing was refused)'; Eq (ShaRefusals).Count 0 "no what=sha refusal: $(ShaRefusals)"
}
T 'L.x-check-lost-back-rollback: a manual back whose x.check to new (src) is lost while new pinned C: the E-R19 end''s r.start-src / r.unfreeze-src on new are refused what=sha once, the laptop replays the back''s x.check, takes C (manifest_sha = C, manifest_sha_prev = old''s pin), re-sends and ends 1 (E-R19: new restarted and unfrozen, phase cut, serving new), never 70' {
  Fx-Cut; $B0 = $W.old.Sha
  Add-Fault -M new -Key '^back-2-x\.check$' -Rc 0 -Mode noexit -Do { Add-Fault -M new -Key '^status$' -Mode down -N 1 }
  Ans 'YES'; $r = Run-Move @('back'); $C = $W.LastSha; Ok ($C -cne $B0) 'fixture: the back''s x.check re-pinned new'; Eq $W.new.Sha $C 'the unit pinned C on new'
  Eq $r.Code 1 "E-R19 end ($($r.Text))"; $s = Get-St; Eq $s.phase 'cut' 'phase'; Eq $s.serving 'new' 'serving'; Ok ($null -eq $s.mark) 'mark'; Eq $W.new.Frozen $false 'new unfrozen'; Eq $W.new.Active $Holds 'new serves again'
  Eq (@(CallShas 'new' '^back-2-r\.start-src$') -join ' ') "$B0 $C" 'r.start-src: the old sha (refused what=sha), then the same id with C'; Eq $s.manifest_sha $C 'manifest_sha = C'; Eq (@(CallShas 'new' '^back-2-r\.unfreeze-src$') -join ' ') $C 'r.unfreeze-src carries C'
}
# ============================== T14 final rework (Astra :2, :3, :6) ==============================
# :2 x.baseline prints its health lines; x.health AND x.switch read them on stdin (B.14.7, _mvr_base_load): a check that failed in the baseline is a warn, never a gate; a tunnel name is judged by its class against the baseline class
function HealthStdin([string]$Call) { $c = @(RecCalls -All | Where-Object { $_.Call -ceq $Call -and -not $_.Replay } | Select-Object -First 1); if ($c.Count) { [string]$c[0].Stdin } else { $null } }
function BaselineLines { @(@($W.old.Rec['fwd-1-x.baseline'].Out) | Where-Object { $_ -match '^MOVE item .* kind=health ' }) }
T 'L.baseline-stdin-health-switch: x.baseline''s health lines (one check failed already, a tunnel at class 2) are sent as the stdin of x.health and x.switch; a check failing now that the baseline marked failed is a warn, not a gate (cutover ends cut), and the tunnel at 200 passes' {
  $W.HealthFail['worker.service'] = $true; $W.Tunnel = @{ Name = 't.example.com'; BaseCode = 200; Code = 200 }
  Fx-Copied; [void](Do-Cutover 0); Eq (Get-St).phase 'cut' 'phase'
  $bl = @(BaselineLines); Ok ($bl.Count -eq 4) "x.baseline printed 4 health lines: $($bl -join ' | ')"; Ok ($bl -contains 'MOVE item worker.service kind=health state=failed') 'the failed check is in the baseline'
  foreach ($c in 'fwd-1-x.health', 'fwd-1-x.switch') { $in = HealthStdin $c; Ok ($null -ne $in) "$c was sent"; Eq (@($in -split '\r?\n' | Where-Object { $_ }) -join "`n") ($bl -join "`n") "$c stdin = the baseline lines" }
  Ok (@($W.new.Rec['fwd-1-x.health'].Out) -contains 'INV warn health-baseline check=worker.service') 'x.health warned about the baseline-failed check, no gate'
}
T 'L.baseline-regression: a check that was ok in the baseline and fails at x.health gates (69): the cutover turns into the carry-back (10); the same for a tunnel whose class changes 2 -> 4 at x.switch, which the server passes only if no baseline class was sent' {
  Fx-Copied; $W.Hooks['x.health'] = { param($m, $e) $W.HealthFail['app.service'] = ($e.Call -like 'fwd-*') }; Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 10 "x.health regression: carry-back ($($r.Text))"; Eq (Get-St).phase 'back-done' 'phase'
  Reset-World; $W.Tunnel = @{ Name = 't.example.com'; BaseCode = 200; Code = 200 }; $W.Hooks['x.switch'] = { param($m, $e) $W.Tunnel.Code = $(if ($e.Call -like 'fwd-*') { 404 } else { 200 }) }; Fx-Copied; Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 10 "x.switch class regression 200 -> 404: carry-back ($($r.Text))"; Eq (Get-St).phase 'back-done' 'phase'
}
T 'L.baseline-resume: the laptop died after x.start: the resume (step 8) sends the baseline lines it kept as the stdin of x.health and x.switch, and does not send x.baseline again' {
  $W.HealthFail['worker.service'] = $true; Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.start$' -Rc 0 -Mode kill; Ans 'có'; $r1 = Run-Move @('cutover'); Ok ($r1.Code -ne 0) "the laptop died ($($r1.Text))"
  $bl = @(BaselineLines); Ok ($bl.Count -ge 3) 'fixture: a baseline was taken'; $r = Run-Move @('cutover'); Eq $r.Code 0 "resume ($($r.Text))"; Eq (Get-St).phase 'cut' 'phase'
  Eq (SentAny '-x\.baseline$') 0 'x.baseline not sent again in the resume'
  foreach ($c in 'fwd-1-x.health', 'fwd-1-x.switch') { $in = HealthStdin $c; Eq (@($in -split '\r?\n' | Where-Object { $_ }) -join "`n") ($bl -join "`n") "$c stdin = the baseline lines (resumed)" }
}
T 'L.baseline-recover: the lines are not in the laptop state (wiped, or a rebuilt state): the resume replays this attempt''s x.baseline once (a done record answers its stored out, nothing runs) and sends those lines; when the replay fails, x.health is not sent and the run turns to the recovery path' {
  $W.HealthFail['worker.service'] = $true; Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.start$' -Rc 0 -Mode kill; Ans 'có'; $r1 = Run-Move @('cutover'); Ok ($r1.Code -ne 0) "the laptop died ($($r1.Text))"
  $s = Get-St; $a = $s.answers; [void]$a.PSObject.Properties.Remove('health-baseline'); [void](Patch-St @{ answers = $a }); Ok ($null -eq (Get-St).answers.PSObject.Properties['health-baseline']) 'fixture: the stored baseline is gone'
  $bl = @(BaselineLines); $r = Run-Move @('cutover'); Eq $r.Code 0 "resume ($($r.Text))"; Eq (Get-St).phase 'cut' 'phase'
  Eq (SentAny '-x\.baseline$') 1 'x.baseline sent once (a replay)'; Eq (Sent 'old' '-x\.baseline$') 0 'it executed nothing (done record)'; Eq (@((HealthStdin 'fwd-1-x.health') -split '\r?\n' | Where-Object { $_ }) -join "`n") ($bl -join "`n") 'x.health stdin = the replayed lines'
  Reset-World; Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.start$' -Rc 0 -Mode kill; Ans 'có'; [void](Run-Move @('cutover'))
  $s = Get-St; $a = $s.answers; [void]$a.PSObject.Properties.Remove('health-baseline'); [void](Patch-St @{ answers = $a }); $W.old.Rec['fwd-1-x.baseline'].Rc = 1; Add-Fault -M old -Key '^fwd-1-x\.baseline$' -Rc 1
  $r = Run-Move @('cutover'); Ok ($r.Code -ne 0) "the replay failed ($($r.Code): $($r.Text))"; Eq (SentAny '^fwd-1-x\.health$') 0 'x.health not sent without a baseline'
}
T 'L.baseline-carry-empty: the carry-back runs no x.baseline, so its x.health goes out with an empty stdin (no baseline line gates)' {
  Start-Carry; Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 10 "carry-back ($($r.Text))"
  $h = @(RecCalls -All | Where-Object { $_.Call -ceq 'back-2-x.health' }); Ok ($h.Count -ge 1) 'the carry-back sent x.health'; Eq ([string]$h[0].Stdin) '' 'x.health stdin is empty'
  $h = @(RecCalls -All | Where-Object { $_.Call -ceq 'back-2-x.switch' }); foreach ($x in $h) { Eq ([string]$x.Stdin) '' 'x.switch stdin is empty' }
}
T 'L.baseline-other-attempt: a later attempt takes its OWN baseline: the lines kept for attempt 1 are never sent in attempt 3 (a resume that finds only the attempt-1 lines replays attempt 3''s x.baseline)' {
  Fx-BackDone; [void](Do-Copy 0); $W.HealthFail['cron.service'] = $true; [void](Do-Cutover 0); Eq (Get-St).attempt 3 'attempt'
  $in = HealthStdin 'fwd-3-x.health'; Ok ($null -ne $in) 'attempt 3 sent x.health'; Ok ($in -match 'MOVE item cron\.service kind=health state=failed') "attempt 3's own baseline (cron failed): $in"
  # the stale leftover: the laptop died after x.start of attempt 3 and only attempt 1's lines are in the state
  Reset-World; Fx-BackDone; [void](Do-Copy 0); $W.HealthFail['cron.service'] = $true; Add-Fault -M new -Key '^fwd-3-x\.start$' -Rc 0 -Mode kill; Ans 'có'; $r1 = Run-Move @('cutover'); Ok ($r1.Code -ne 0) "the laptop died ($($r1.Text))"
  $s = Get-St; $a = $s.answers; Set-Prop $a 'health-baseline' ([pscustomobject]@{ id = 'fwd-1'; lines = @('MOVE item app.service kind=health state=ok', 'MOVE item worker.service kind=health state=ok', 'MOVE item cron.service kind=health state=ok') }); [void](Patch-St @{ answers = $a })
  $r = Run-Move @('cutover'); Eq $r.Code 0 "resume ($($r.Text))"; Eq (SentAny '^fwd-3-x\.baseline$') 1 'attempt 3''s x.baseline replayed: the attempt-1 lines were not taken'
  Ok ((HealthStdin 'fwd-3-x.health') -match 'MOVE item cron\.service kind=health state=failed') 'attempt 3''s own baseline reached x.health'
}
# :3 a manual back: a failed x.final / x.verify / x.prepare-id / x.adopt (steps 6-7) ends 70 and is resume-only - old holds an incomplete copy, new stays frozen and stopped: the resume retries them, it is never E-R19 (which restarts new)
T 'L.back-final-failed-resume: a manual back whose x.final fails ends 70 (resume only, new frozen and stopped, no r.start-src); `back` again retries x.final under the same id and goes on to back-done' {
  Fx-Cut; Add-Fault -M new -Key '^back-2-x\.final$' -Rc 1; Ans 'YES'; $r1 = Run-Move @('back'); Eq $r1.Code 70 "x.final failed ($($r1.Text))"; $s = Get-St; Eq $s.mark 'cutting' 'mark kept'; Eq $s.dir 'back' 'dir'; Eq $W.new.Frozen $true 'new frozen'; Eq $W.new.Active 0 'new stopped'
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "resume ($($r.Text))"; Eq (Get-St).phase 'back-done' 'phase'
  Eq (SentAny '-r\.start-src$') 0 'never E-R19: new was not restarted'; Eq (Sent 'new' '^back-2-x\.final$') 1 'x.final re-sent (the failed record runs again)'; Ok ((Sent 'old' '^back-2-x\.start$') -ge 1) 'old started after the final copy'
}
T 'L.back-adopt-failed-resume: a manual back whose x.adopt on old fails ends 70; the resume does not restart new: it replays the done steps, runs x.adopt again and goes on to back-done' {
  Fx-Cut; Add-Fault -M old -Key '^back-2-x\.adopt$' -Rc 1; Ans 'YES'; $r1 = Run-Move @('back'); Eq $r1.Code 70 "x.adopt failed ($($r1.Text))"; Eq $W.new.Frozen $true 'new frozen'
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "resume ($($r.Text))"; Eq (Get-St).phase 'back-done' 'phase'; Eq (SentAny '-r\.start-src$') 0 'never E-R19'; Eq (Sent 'old' '^back-2-x\.adopt$') 1 'x.adopt run again'
}
T 'L.back-stop-failed-still-e-r19: a failure BEFORE the final copy (x.stop-dst on old) still ends the manual back as E-R19: new restarted and unfrozen, phase cut, serving new, exit 1; the fwd cutover is unchanged (plain rollback)' {
  Fx-Cut; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1; Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code 1 "E-R19 ($($r.Text))"; $s = Get-St; Eq $s.phase 'cut' 'phase'; Eq $s.serving 'new' 'serving'; Eq (Sent 'new' '^back-2-r\.start-src$') 1 'new restarted'; Eq $W.new.Frozen $false 'new unfrozen'
  # the same failure found on a RESUME (the laptop died after the failed x.stop-dst record): the failed record is before the final copy, so the resume ends it as E-R19 too
  Reset-World; Fx-Cut; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1 -Effect -Mode kill; Ans 'YES'; $r1 = Run-Move @('back'); Ok ($r1.Code -ne 0) "the laptop died ($($r1.Text))"
  Eq (SentAny '-r\.start-src$') 0 'fixture: no restart yet'; Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code 1 "the resume ends E-R19 ($($r.Text))"; Eq (Get-St).phase 'cut' 'phase'; Eq (Sent 'new' '^back-2-r\.start-src$') 1 'new restarted by the resume'
}
# :6 rebuild after f.old but before f.new: phase finished only when BOTH machines are finished
T 'L.rebuild-finish-half: f.old ran, f.new never did, the laptop state is lost: `status --rebuild` does NOT write phase finished; the next `finish` skips old (no call into its door) and runs f.new, ends 0 and finished, new''s move-id finished' {
  Fx-Cut; Add-Fault -M new -Key '-f\.new$' -Mode down; Ans 'YES'; $r = Run-Move @('finish'); Ok ($r.Code -ne 0) 'finish stops at f.new'; Eq $W.old.MoveId.state 'finished' 'old finished'; Eq $W.new.MoveId.state 'open' 'new still open'
  $W.new.Up = $true; [IO.File]::Delete((StatePath)); foreach ($n in 'old', 'new') { $W[$n].MoveId.old_addr = $OldAddr; $W[$n].MoveId.new_addr = $NewAddr }
  $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild ($($rr.Text))"; $s = Get-St; Ok ($s.phase -cne 'finished') "phase is not finished: $($s.phase)"; Eq $s.phase 'cut' 'phase'; Eq $s.serving 'new' 'serving'
  Ans 'YES'; $r = Run-Move @('finish'); Eq $r.Code 0 "finish ($($r.Text))"; Eq (Get-St).phase 'finished' 'phase'; Eq $W.new.MoveId.state 'finished' 'new closed'; Eq (Sent 'new' '-f\.new$') 1 'f.new sent'; Eq (SentAny '-f\.old$') 0 'no f.old (not even into the door)'
}
T 'L.rebuild-finish-both: both machines finished: `status --rebuild` writes phase finished (idempotent: finish and every verb end as D.11 says)' {
  Fx-Finished; [IO.File]::Delete((StatePath)); foreach ($n in 'old', 'new') { $W[$n].MoveId.old_addr = $OldAddr; $W[$n].MoveId.new_addr = $NewAddr }
  $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild ($($rr.Text))"; Eq (Get-St).phase 'finished' 'phase'
}
# ============================== T14 final2 (Astra final2 :7-10) ==============================
function Lose-State { [IO.File]::Delete((StatePath)); foreach ($n in 'old', 'new') { if ($W[$n].MoveId) { $W[$n].MoveId.old_addr = $OldAddr; $W[$n].MoveId.new_addr = $NewAddr } } }
function SinceOf([string]$Call) { $s = @(); foreach ($n in 'old', 'new') { $r = $W[$n].Rec[$Call]; if ($r -and "$($r.Argv)" -match '--since (\S+)') { $s += $Matches[1] } }; $s }
# :7 the server keeps its call records across a rebuild; the rebuilt laptop must number its next `.N` calls past every record it can read (done, failed or interrupted, either machine), else it re-sends a done id (a replay: nothing is prepared or copied) or a changed argv (call-argv)
T 'L.rebuild-pass-counters: state lost after a finished copy: `status --rebuild` rebuilds pass{} from the records of both machines; the next `copy` sends c.prepare / c.transfer / c.verify / c.adopt as .2 (never a replay of .1, never call-argv) and ends copied' {
  Fx-Copied; Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild ($($rr.Text))"; $p = (Get-St).pass
  foreach ($b in 'c.prepare', 'c.transfer', 'c.verify', 'c.adopt') { Eq ([int]$p.PSObject.Properties["fwd-1-$b"].Value) 1 "pass[fwd-1-$b] = the highest N on the machines" }
  $r = Run-Move @('copy'); Eq $r.Code 0 "copy ($($r.Text))"; Eq (Get-St).phase 'copied' 'phase'
  Eq (Sent 'new' '^fwd-1-c\.prepare\.2$') 1 'c.prepare.2 ran'; Eq (SentAny '^fwd-1-c\.prepare\.1$') 0 'no c.prepare.1 again'; Eq (Sent 'new' '^fwd-1-c\.transfer\.2$') 1 'c.transfer.2 ran'; Eq (SentAny '^fwd-1-c\.transfer\.1$') 0 'no c.transfer.1 again'
  Eq (Sent 'old' '^fwd-1-c\.verify\.2$') 1 'c.verify.2 on old'; Eq (Sent 'new' '^fwd-1-c\.verify\.2$') 1 'c.verify.2 on new'; Eq (Sent 'new' '^fwd-1-c\.adopt\.2$') 1 'c.adopt.2'
  Eq @(LogNow -All | Where-Object { $_ -match 'call-argv' }).Count 0 "no call-argv refusal: $(@(LogNow | Where-Object { $_ -match 'call-argv' }))"
}
T 'L.rebuild-pass-counters-failed: a failed c.transfer.2 and an interrupted c.prepare.3 on new count too: the rebuilt pass{} holds 2 and 3, the next copy sends c.transfer.3 and c.prepare.4 (a failed or interrupted id is never re-used by a new pass)' {
  Fx-Copied; Add-Rec 'new' 'fwd-1-c.transfer.2' 1; $W.new.Rec['fwd-1-c.prepare.3'] = @{ Rc = $null; Out = @('LOG fwd-1-c.prepare.3'); Dur = 5; Argv = '?'; Start = (Format-Iso $script:Clock); End = '' }; [void]$W.new.Order.Add('fwd-1-c.prepare.3')
  Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild ($($rr.Text))"; $p = (Get-St).pass
  Eq ([int]$p.PSObject.Properties['fwd-1-c.transfer'].Value) 2 'pass[c.transfer] counts the failed record'; Eq ([int]$p.PSObject.Properties['fwd-1-c.prepare'].Value) 3 'pass[c.prepare] counts the interrupted record'
  $r = Run-Move @('copy'); Eq $r.Code 0 "copy ($($r.Text))"; Eq (Sent 'new' '^fwd-1-c\.transfer\.3$') 1 'c.transfer.3'; Eq (Sent 'new' '^fwd-1-c\.prepare\.4$') 1 'c.prepare.4'; Eq (SentAny '^fwd-1-c\.(prepare\.[123]|transfer\.[12])$') 0 'no old id re-sent'
}
# :8 the server compares --since of x.verify even for a done record (K1 argv compare): a resumed back must send the value it sent the first time, on both machines, not "now"
T 'L.rebuild-since: a manual back dies after x.verify, the state is lost and rebuilt: the resume sends x.verify with the SAME --since on both machines (no call-argv), and the back ends back-done' {
  Fx-Cut; Add-Fault -M old -Key '^back-2-x\.verify$' -Rc 0 -Mode kill; Ans 'YES'; $r1 = Run-Move @('back'); Ok ($r1.Code -ne 0) "the laptop died ($($r1.Text))"
  $s1 = @(SinceOf 'back-2-x.verify'); Ok ($s1.Count -eq 2) "x.verify ran on both machines: $($s1 -join ',')"; Eq $s1[0] $s1[1] 'the same --since on both machines'
  Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild ($($rr.Text))"
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "resume ($($r.Text))"; Eq (Get-St).phase 'back-done' 'phase'
  Eq @(LogNow -All | Where-Object { $_ -match 'call-argv' }).Count 0 "no call-argv refusal: $(@(LogNow | Where-Object { $_ -match 'call-argv' }))"
  $vs = @(RecCalls -All | Where-Object { $_.Call -ceq 'back-2-x.verify' } | ForEach-Object { [string]$_.Flags['since'] } | Select-Object -Unique); Eq $vs.Count 1 "every x.verify of the back carries one --since: $($vs -join ',')"; Eq $vs[0] $s1[0] 'the recorded value'
}
# a FAILED x.verify record carries the recorded --since too (any rc): the resume re-sends it with that value and the failed call runs again
T 'L.rebuild-since-failed: x.verify fails on old (rc 1) or on new (the only record), the back ends 70, the state is lost and rebuilt: the resume re-sends x.verify with the RECORDED --since, the failed call executes again, no call-argv, back-done' {
  Fx-Cut; Add-Fault -M old -Key '^back-2-x\.verify$' -Rc 1; Ans 'YES'; $r1 = Run-Move @('back'); Ok ($r1.Code -ne 0 -and $r1.Code -ne $BackDoneExit) "x.verify failed on old ($($r1.Code): $($r1.Text))"
  $s2 = @(SinceOf 'back-2-x.verify'); Eq $s2.Count 2 'x.verify ran on both machines'; Eq $s2[0] $s2[1] 'the same --since'; Eq ([int]$W.old.Rec['back-2-x.verify'].Rc) 1 'the dst record is failed'
  Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild ($($rr.Text))"; Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "resume ($($r.Text))"
  Eq @(LogNow -All | Where-Object { $_ -match 'call-argv' }).Count 0 'no call-argv refusal'; $vs = @(RecCalls -All | Where-Object { $_.Call -ceq 'back-2-x.verify' } | ForEach-Object { [string]$_.Flags['since'] } | Select-Object -Unique); Eq $vs.Count 1 'one --since'; Eq $vs[0] $s2[0] 'the recorded value'; Eq (Sent 'old' '^back-2-x\.verify$') 1 'the failed x.verify ran again'
  Reset-World; $W.StartSkew = 2; Fx-Cut; foreach ($n in 'old', 'new') { [void]$W[$n].Rec.Remove('fwd-1-c.verify.1'); [void]$W[$n].Order.Remove('fwd-1-c.verify.1') }; Add-Fault -M new -Key '^back-2-x\.verify$' -Rc 1; Ans 'YES'; $r1 = Run-Move @('back'); Ok ($r1.Code -ne 0 -and $r1.Code -ne $BackDoneExit) "x.verify failed on new ($($r1.Code))"
  $s3 = @(SinceOf 'back-2-x.verify'); Eq $s3.Count 1 'only the failed record exists'; Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 'rebuild'; Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "resume ($($r.Text))"
  Eq @(LogNow -All | Where-Object { $_ -match 'call-argv' }).Count 0 'no call-argv refusal'; $vs = @(RecCalls -All | Where-Object { $_.Call -ceq 'back-2-x.verify' } | ForEach-Object { [string]$_.Flags['since'] } | Select-Object -Unique); Eq $vs.Count 1 'one --since'; Eq $vs[0] $s3[0] 'taken from the failed record'
}
# no x.verify record of the attempt yet: last_copy_at falls back to new's newest forward pass (the field is written only in Invoke-MovePasses, just before that transfer; the same pass's c.verify.N carries it)
T 'L.rebuild-since-fallback: (a) a manual back rebuilt between the pre-copy and x.verify sends its first x.verify with the --since of new''s newest fwd c.verify.N (not now, not the back''s pre-copy start); (b) with that c.verify record gone: the start of the fwd c.transfer.N; (c) a fwd rebuilt at copied within 60 min: cutover does not re-copy (0b)' {
  $W.StartSkew = 2; Fx-Cut; $V1 = @(SinceOf 'fwd-1-c.verify.1'); Ok ($V1.Count -ge 1) 'fixture: the fwd pass recorded a --since'; Ok ($V1[0] -cne [string]$W.new.Rec['fwd-1-c.transfer.1'].Start) 'fixture: the verify since differs from the transfer start'
  Add-Fault -M new -Key '^back-2-x\.final$' -Rc 0 -Mode kill; Ans 'YES'; $r1 = Run-Move @('back'); Ok ($r1.Code -ne 0) "the back died after the pre-copy ($($r1.Text))"; Eq @(SinceOf 'back-2-x.verify').Count 0 'fixture: no x.verify record yet'
  Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild ($($rr.Text))"; Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "resume ($($r.Text))"
  $vs = @(RecCalls -All | Where-Object { $_.Call -ceq 'back-2-x.verify' } | ForEach-Object { [string]$_.Flags['since'] } | Select-Object -Unique); Eq $vs.Count 1 'one --since'; Eq $vs[0] $V1[0] 'the since of the fwd c.verify.N'; Ok ($vs[0] -cne [string]$W.new.Rec['back-2-c.transfer.1'].Start) 'not the back''s pre-copy start'
  Reset-World; $W.StartSkew = 2; Fx-Cut; $T1 = [string]$W.new.Rec['fwd-1-c.transfer.1'].Start; foreach ($n in 'old', 'new') { [void]$W[$n].Rec.Remove('fwd-1-c.verify.1'); [void]$W[$n].Order.Remove('fwd-1-c.verify.1') }
  Add-Fault -M new -Key '^back-2-x\.final$' -Rc 0 -Mode kill; Ans 'YES'; [void](Run-Move @('back')); Lose-State; [void](Run-Move @('status', '--rebuild', $OldAlias, $NewAlias)); Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "resume without c.verify.N ($($r.Text))"
  $vs = @(RecCalls -All | Where-Object { $_.Call -ceq 'back-2-x.verify' } | ForEach-Object { [string]$_.Flags['since'] } | Select-Object -Unique); Eq $vs.Count 1 'one --since'; Eq $vs[0] $T1 'the start of the fwd c.transfer.N'
  Reset-World; Fx-Copied; Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 'rebuild'; Ok ($null -ne (Get-St).last_copy_at) 'last_copy_at restored'; Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 0 "cutover ($($r.Text))"; NoText 'cutover (0b)'; Eq (SentAny '-c\.transfer\.') 0 'no re-copy before the cutover'
}
# E-R19 on a rebuild (D.0.10): only a done r.start-src / r.unfreeze-src of NEW means the back ended as E-R19; the fence's r.stop-dst (sent under dir=back too) never does
T 'L.rebuild-after-discard-fence: a carry-back Q-discard YES, the next verb fences new (back-2-r.stop-dst done on new), the state is lost and rebuilt: phase rolled-back, serving old, new_discarded true; the next verb sends no x.enable.N / x.unfreeze.N to new' {
  Start-Carry; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1; Ans 'có', 'YES'; $r = Run-Move @('cutover'); Eq $r.Code 10 "Q-discard YES ($($r.Text))"; Eq (Get-St).new_discarded $true 'new_discarded'
  $r2 = Run-Move @('cutover'); Ok ($W.new.Rec.ContainsKey('back-2-r.stop-dst') -and [int]$W.new.Rec['back-2-r.stop-dst'].Rc -eq 0) "the fence ran on new: $(@($W.new.Order) -join ',')"
  Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild ($($rr.Text))"; $s = Get-St; Eq $s.phase 'rolled-back' 'phase'; Eq $s.serving 'old' 'serving'; Eq $s.new_discarded $true 'new_discarded'
  $r3 = Run-Move @('copy'); Eq (Sent 'new' '-x\.(enable|unfreeze)\.') 0 'nothing enables new'
}
T 'L.rebuild-cut-no-fence: a rebuilt `cut` and a rebuilt `back-done` send no r.stop-dst to new on their next verb (new_discarded stays false; the E-R19 end still rebuilds as cut)' {
  Fx-Cut; Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 'rebuild'; $s = Get-St; Eq $s.phase 'cut' 'phase'; Eq $s.new_discarded $false 'new_discarded'; [void](Run-Move @('cutover')); Eq (SentAny '-r\.stop-dst$') 0 'no fence at cut'
  Reset-World; Fx-BackDone; Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 'rebuild'; $s = Get-St; Eq $s.phase 'back-done' 'phase'; Eq $s.new_discarded $false 'new_discarded'; [void](Run-Move @('abort')); Eq (SentAny '-r\.stop-dst$') 0 'no fence at back-done'
  Reset-World; Fx-Cut; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1; Ans 'YES'; [void](Run-Move @('back')); Eq (Get-St).phase 'cut' 'fixture: E-R19 end'; Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 'rebuild'; $s = Get-St; Eq $s.phase 'cut' 'the E-R19 end rebuilds as cut'; Eq $s.serving 'new' 'serving new'
}
T 'L.rebuild-fence: Q-newlost YES (new down), the state is lost, new answers again and is rebuilt: new_discarded is true, the next `copy` sends r.stop-dst to new at the start of the verb, before c.init-new; `abort` after that rebuild still sends a.new' {
  Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Mode down; [void](Do-Cutover 70); Ans 'YES'; $r = Run-Move @('cutover'); Eq $r.Code 10 "Q-newlost ($($r.Text))"
  $W.new.Up = $true; Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild ($($rr.Text))"; $s = Get-St; Eq $s.phase 'rolled-back' 'phase'; Eq $s.new_discarded $true 'new_discarded'
  $r = Run-Move @('copy'); Eq (Sent 'new' '^fwd-1-r\.stop-dst$') 1 'the fence r.stop-dst on new'; $l = @(LogNow | Where-Object { $_ -match '^new fwd-1-r\.stop-dst$|^new fwd-[0-9]+-c\.init-new$' }); Ok ($l.Count -ge 1 -and $l[0] -match 'r\.stop-dst') "the fence comes first: $($l -join ' ; ')"
  Reset-World; Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Mode down; [void](Do-Cutover 70); Ans 'YES'; [void](Run-Move @('cutover')); $W.new.Up = $true; Lose-State; [void](Run-Move @('status', '--rebuild', $OldAlias, $NewAlias))
  Ans 'có'; $r = Run-Move @('abort'); Eq $r.Code 0 "abort ($($r.Text))"; Eq (Sent 'new' '-a\.new$') 1 'a.new is still sent'
}
T 'L.rebuild-fence-plain: after a plain rollback (new''s r.stop-dst done) the rebuilt `copy` re-sends the fence under the same id: it is a replay of the done record, nothing executes' {
  Fx-RolledBack; Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild ($($rr.Text))"; $s = Get-St; Eq $s.phase 'rolled-back' 'phase'; Eq $s.new_discarded $true 'new_discarded'
  [void](Run-Move @('copy')); Eq (Sent 'new' '^fwd-1-r\.stop-dst$') 0 'nothing executes'; $rp = @(Calls | Where-Object { $_.Call -ceq 'fwd-1-r.stop-dst' }); Eq $rp.Count 1 'the fence was sent once'; Ok ($rp[0].Replay -eq $true) 'as a replay'; Ok (@(LogNow | Where-Object { $_ -match 'fwd-1-r\.stop-dst \(replay\)' }).Count -ge 1) 'the log says replay'
}
# Astra final4 P1: x.switch ran to the end on new but its answer was lost (new then went down); Q-newlost YES restarted old; new is back and the state is lost. The completed x.switch must not override the LATER return-to-old records:
# the rebuild is rolled-back with new_discarded (the fence), never `cut`, whose chore 0 would start new while old serves
T 'L.rebuild-switch-lost-newlost: x.switch done on new (answer lost, new down), Q-newlost YES starts old, new comes back, the state is lost and rebuilt: rolled-back, serving old, new_discarded true, never cut; the next verb fences new first, never enables it, and old and new are never both serving after it' {
  Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.switch$' -Rc 0 -Mode down; [void](Do-Cutover 70); Ok ([int]$W.new.Rec['fwd-1-x.switch'].Rc -eq 0) 'fixture: x.switch ran to the end on new'
  Ans 'YES'; $r = Run-Move @('cutover'); Eq $r.Code 10 "Q-newlost YES starts old ($($r.Text))"; Eq (Get-St).new_lost $true 'new_lost'; Ok ([int]$W.old.Rec['fwd-1-r.start-src'].Rc -eq 0) 'fixture: old was restarted (a done r.start-src later than the switch)'
  $W.new.Up = $true; Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild ($($rr.Text))"; $s = Get-St
  Ok ($s.phase -cne 'cut') 'never cut'; Eq $s.phase 'rolled-back' 'phase'; Eq $s.serving 'old' 'serving'; Eq $s.new_discarded $true 'new_discarded'; Eq $s.mark $null 'mark'
  $r = Run-Move @('copy'); Eq (Sent 'new' '^fwd-1-r\.stop-dst$') 1 'the fence r.stop-dst reached new'; Eq (Sent 'new' '-x\.(enable|unfreeze)\.') 0 'nothing enables or unfreezes new'
  Ok (-not ($W.new.Active -gt 0 -and $W.old.Active -gt 0)) "never both: old Active=$($W.old.Active) new Active=$($W.new.Active)"; Eq $W.new.Active 0 'new stopped by the fence'; Eq $W.old.Active $Holds 'old serves'
  # a successful x.switch with NO later return record stays cut (the precedence only applies to records after it)
  Reset-World; Fx-Cut; Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 'rebuild'; Eq (Get-St).phase 'cut' 'a done x.switch alone is cut'; Eq (Get-St).new_discarded $false 'not fenced'
}
# Astra final5 P1 (+ ADDENDUM): the return-to-old record that follows the lost x.switch is NOT always done: the laptop is killed during old's r.start-src (the record is interrupted, the apps are already started) or it fails;
# ANY return record of old (any state) is a return that began: the rebuild is rolling-back (serving old, new_discarded; the x.switch is not applied), never cut and never rolled-back; `cutover` is rb-continue (new fenced first, none enabled)
T 'L.rebuild-switch-lost-interrupted-start: x.switch done on new (answer lost), Q-newlost YES, the laptop is killed during old''s r.start-src (interrupted record, apps started) or old''s r.start-src, r.unfreeze-src and r.health-src fail (rc 1): the rebuild is rolling-back (never cut, never rolled-back), serving old, new_discarded true, phase copied; `cutover` is rb-continue: r.stop-dst first to new, nothing enabled or unfrozen on new, old ends rolled-back, serving, unfrozen, enabled; old and new are never both serving' {
  foreach ($leg in 'interrupted', 'failed') {
    Reset-World; Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.switch$' -Rc 0 -Mode down; [void](Do-Cutover 70); Ok ([int]$W.new.Rec['fwd-1-x.switch'].Rc -eq 0) "[$leg] fixture: x.switch ran to the end on new"
    if ($leg -ceq 'interrupted') { Add-Fault -M old -Key '^fwd-1-r\.start-src$' -Rc 0 -Mode kill } else { Add-Fault -M old -Key '^fwd-1-r\.(start|unfreeze|health)-src$' -Rc 1 -N 3 }
    Ans 'YES'; $r = Run-Move @('cutover')
    if ($leg -ceq 'interrupted') { Ok ($r.Code -ne 0) "[$leg] the laptop died ($($r.Text))"; $W.old.Rec['fwd-1-r.start-src'].Rc = $null; Ok ($W.old.Active -gt 0) "[$leg] fixture: the apps are already started on old" }
    else { Eq $r.Code 70 "[$leg] old did not start ($($r.Text))"; Eq ([int]$W.old.Rec['fwd-1-r.start-src'].Rc) 1 "[$leg] fixture: a failed r.start-src on old" }
    $W.new.Up = $true; Lose-State; $s = Rebuild-Now
    Ok ($s.phase -cne 'cut') "[$leg] never cut"; Ok ($s.phase -cne 'rolled-back') "[$leg] not rolled-back (r.start-src / r.unfreeze-src did not both return 0)"; Eq $s.phase 'copied' "[$leg] phase"; Eq $s.mark 'rolling-back' "[$leg] mark"; Eq $s.serving 'old' "[$leg] serving"; Eq $s.carry $false "[$leg] carry"; Eq $s.new_discarded $true "[$leg] new_discarded"
    $r = Run-Move @('cutover'); Eq $r.Code 10 "[$leg] rb-continue ($($r.Text))"; Assert-NewUntouched $leg; Assert-OldServes $leg
  }
}
# ======= ADDENDUM (challenger, "return to old is a rollback"): every return (plain rollback, Q-newlost YES, Q-discard YES) writes ahead mark=rolling-back, serving=old, carry=false (+ the fence flag) BEFORE r.start-src;
# `rolled-back` is written only when r.start-src and r.unfreeze-src returned 0; the rebuild reads ANY return record of old (any state) as rolling-back; chore 0 is never the repair of a return
T 'L.newlost-kill-during-return: x.switch done on new (answer lost) or new down after x.health; Q-newlost YES; the laptop is killed while old''s r.start-src unit runs (the write-ahead rolling-back survives); new answers again: `cutover` is rb-continue (r.stop-dst the first call to new, no enable / unfreeze / switch / health to new, old''s three calls), rolled-back, old serving with its connectors, exit 10; a second `cutover` is refused copy-first' {
  foreach ($leg in 'switch-lost', 'health-down', 'serving-new-state') {   # serving-new-state: the state said serving=new when the return began (a state of an older fcode): the return's own write-ahead must say old
    Reset-World; Fx-Copied; if ($leg -ceq 'switch-lost') { Add-Fault -M new -Key '^fwd-1-x\.switch$' -Rc 0 -Mode down } else { Add-Fault -M new -Key '^fwd-1-x\.health$' -Mode down }
    [void](Do-Cutover 70); if ($leg -ceq 'serving-new-state') { [void](Patch-St @{ serving = 'new' }) }; Add-Fault -M old -Key '^fwd-1-r\.start-src$' -Rc 0 -Mode kill; Ans 'YES'; $r = Run-Move @('cutover'); Ok ($r.Code -ne 0) "[$leg] the laptop died ($($r.Text))"
    $W.old.Rec['fwd-1-r.start-src'].Rc = $null; Ok ($W.old.Conn -eq $true) "[$leg] fixture: the unit started the connectors"
    $s = Get-St; Eq $s.mark 'rolling-back' "[$leg] write-ahead mark"; Eq $s.serving 'old' "[$leg] write-ahead serving"; Eq $s.carry $false "[$leg] write-ahead carry"; Eq $s.new_lost $true "[$leg] the fence flag"
    $W.new.Up = $true; $r = Run-Move @('cutover'); Eq $r.Code 10 "[$leg] rb-continue ($($r.Text))"
    Assert-NewUntouched $leg; Ok ((SentAny '^fwd-1-r\.start-src$') -ge 1) "[$leg] r.start-src attached or replayed"; Eq (Sent 'old' '^fwd-1-r\.unfreeze-src$') 1 "[$leg] r.unfreeze-src"; Eq (Sent 'old' '^fwd-1-r\.health-src$') 1 "[$leg] r.health-src"
    Assert-OldServes $leg; $r2 = Run-Move @('cutover'); Ok ($r2.Code -ne 0) "[$leg] a second cutover is refused"; HasText 'chạy copy trước'; Eq (SentAny '-x\.(enable|unfreeze)\.[0-9]+$') 0 "[$leg] and sends nothing"
  }
}
T 'L.carry-discard-kill-during-return: a carry-back Q-discard YES, the laptop is killed during old''s r.start-src: `cutover` is rb-continue IN dir=back (back-2 r.* ids, no carry-resume, no x.final, no x.enable.N), rolled-back, serving old, exit 10' {
  Start-Carry; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1; Add-Fault -M old -Key '^back-2-r\.start-src$' -Rc 0 -Mode kill; Ans 'có', 'YES'; $r = Run-Move @('cutover'); Ok ($r.Code -ne 0) "the laptop died ($($r.Text))"
  $W.old.Rec['back-2-r.start-src'].Rc = $null; $s = Get-St; Eq $s.mark 'rolling-back' 'write-ahead mark'; Eq $s.dir 'back' 'dir'; Eq $s.serving 'old' 'serving'; Eq $s.carry $false 'carry'; Eq $s.new_discarded $true 'the fence flag'
  $r = Run-Move @('cutover'); Eq $r.Code 10 "rb-continue ($($r.Text))"; Eq (SentAny '-x\.final$') 0 'no x.final (no carry-resume)'; Eq (SentAny '-(x\.enable|x\.unfreeze|b\.init-new)') 0 'no enable / unfreeze / b.init-new'
  Ok ((SentAny '^back-2-r\.start-src$') -ge 1) 'r.start-src attached or replayed'; Eq (Sent 'old' '^back-2-r\.unfreeze-src$') 1 'r.unfreeze-src'; Eq (Sent 'old' '^back-2-r\.health-src$') 1 'r.health-src'
  $s = Get-St; Eq $s.phase 'rolled-back' 'phase'; Eq $s.serving 'old' 'serving'; Ok ($null -eq $s.mark) 'mark'; Eq $W.old.Active $Holds 'old serves'; Eq $W.old.Conn $true 'connectors run'; Eq $W.new.Active 0 'new stopped'
  # counter-addendum §5: a YES return stops new first when it answers; a DEFINITE r.stop-dst refusal ends 70 with the power-off remedy and old is NOT started (the plain rollback keeps its own text)
  Reset-World; Start-Carry; Add-Fault -M new -Key '^back-2-x\.stop-src$' -Rc 1; Add-Fault -M new -Key '^back-2-r\.stop-dst$' -Rc 1; Ans 'có', 'YES'
  $r = Run-Move @('cutover'); Eq $r.Code 70 "stop refused ($($r.Text))"; HasText 'tắt hoặc cài lại máy mới trong trang quản lý nhà cung cấp, rồi chạy lại  fcode move cutover'; Eq (SentAny '-r\.start-src$') 0 'old is not started'
  $s = Get-St; Eq $s.mark 'rolling-back' 'the return stays rolling-back'; Eq $s.serving 'old' 'serving'
  Reset-World; Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Rc 1; Add-Fault -M new -Key '^fwd-1-r\.stop-dst$' -Rc 1; [void](Do-Cutover 70); HasText 'chạy lại  fcode move cutover  khi máy mới trả lời'; NoText 'tắt hoặc cài lại máy mới'; Eq (SentAny '-r\.start-src$') 0 'plain rollback: old is not started either'
}
T 'L.newlost-no-requestion: after a kill during the return (state rolling-back) with new still down, `cutover` continues the return (old started, rolled-back, exit 10) and never asks Q-newlost again' {
  Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Mode down; [void](Do-Cutover 70); Add-Fault -M old -Key '^fwd-1-r\.start-src$' -Rc 0 -Mode kill; Ans 'YES'; $r = Run-Move @('cutover'); Ok ($r.Code -ne 0) "the laptop died ($($r.Text))"
  $W.old.Rec['fwd-1-r.start-src'].Rc = $null; Eq (Get-St).mark 'rolling-back' 'fixture: rolling-back'; Ok ($W.new.Up -eq $false) 'fixture: new is still down'
  $n0 = $W.Prompts.Count; $r = Run-Move @('cutover'); Eq $r.Code 10 "continued ($($r.Text))"; Eq $W.Prompts.Count $n0 "no question asked: $($W.Prompts -join ' | ')"; NoText 'Gõ YES'
  Ok ((SentAny '^fwd-1-r\.start-src$') -ge 1) 'old started'; Assert-OldServes 'new down' -NewDown
}
T 'L.rebuild-return-partial: old holds r.start-src FAILED (rc 1) or INTERRUPTED (no rc) and no r.unfreeze-src, in a fwd (new down after x.start) and in a carry-back; the state is lost, new answers: the rebuild is mark rolling-back, serving old, carry false, new_discarded true, phase copied (fwd) / planned (carry); `cutover` is rb-continue (r.stop-dst first to new, r.start-src re-executed with the connectors, r.unfreeze-src, r.health-src) and ends rolled-back' {
  foreach ($dir in 'fwd', 'carry') { foreach ($st in 'failed', 'interrupted') {
    $tag = "$dir/$st"; Reset-World; $p = $(if ($dir -ceq 'fwd') { 'fwd-1' } else { 'back-2' })
    if ($dir -ceq 'fwd') { Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Mode down; [void](Do-Cutover 70); Ans 'YES' } else { Start-Carry; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1; Ans 'có', 'YES' }
    Add-Fault -M old -Key "^$p-r\.start-src`$" -Rc 1; [void](Run-Move @('cutover')); foreach ($c in 'r.unfreeze-src', 'r.health-src') { [void]$W.old.Rec.Remove("$p-$c"); [void]$W.old.Order.Remove("$p-$c") }
    if ($st -ceq 'interrupted') { $W.old.Rec["$p-r.start-src"].Rc = $null };
    $W.new.Up = $true; Lose-State; $s = Rebuild-Now
    Eq $s.mark 'rolling-back' "[$tag] mark"; Eq $s.serving 'old' "[$tag] serving"; Eq $s.carry $false "[$tag] carry"; Eq $s.new_discarded $true "[$tag] new_discarded"; Eq $s.phase $(if ($dir -ceq 'fwd') { 'copied' } else { 'planned' }) "[$tag] phase"
    $r = Run-Move @('cutover'); Eq $r.Code 10 "[$tag] rb-continue ($($r.Text))"; Assert-NewUntouched $tag; Eq (SentAny '-x\.final$') 0 "[$tag] no x.final (never carry-resume)"; Eq (Sent 'old' "^$p-r\.start-src`$") 1 "[$tag] r.start-src re-executed"; Ok ((SentAny "^$p-r\.unfreeze-src`$") -ge 1) "[$tag] r.unfreeze-src"; Ok ((SentAny "^$p-r\.health-src`$") -ge 1) "[$tag] r.health-src"
    Assert-OldServes $tag
  } }
}
# review-lap-final P3-2: a log part file left by a run killed between Write-PhienText's write and its move is dropped by the next call's log write, before the number is counted
T 'L.movelog-stale-part: a `log\<n>-<alias>-<call>.log.part-<pid>` left in the move log dir is deleted by the next recorded call, the new log is numbered WITHOUT it (existing files + 1), no .part-* remains, the new log is UTF-8 without BOM, and an existing .log and an unrelated file in the dir are untouched' {
  Fx-Planned; $ld = Join-Path (MoveDir) 'log'; [void](New-Item -ItemType Directory -Force -Path $ld)
  foreach ($f in @(Get-ChildItem -LiteralPath $ld -File)) { Remove-Item -LiteralPath $f.FullName -Force }
  $keep1 = Join-Path $ld '00001-oldbox-fwd-1-x.freeze.log'; $keep2 = Join-Path $ld 'notes.txt'; $part = Join-Path $ld '00007-oldbox-fwd-1-x.freeze.log.part-99999'
  [IO.File]::WriteAllText($keep1, "one`n", (New-Object Text.UTF8Encoding($false))); [IO.File]::WriteAllText($keep2, "mine`n", (New-Object Text.UTF8Encoding($false))); [IO.File]::WriteAllText($part, "half a log", (New-Object Text.UTF8Encoding($false)))
  [void](Do-Copy)
  Ok (-not (Test-Path -LiteralPath $part)) 'the stale part file is gone'; Eq (@(Get-ChildItem -LiteralPath $ld -Force | Where-Object { $_.Name -like '*.part-*' }).Count) 0 'no .part-* remains'
  Eq ([IO.File]::ReadAllText($keep1)) "one`n" 'the existing log is untouched'; Eq ([IO.File]::ReadAllText($keep2)) "mine`n" 'the unrelated file is untouched'
  $new = @(Get-ChildItem -LiteralPath $ld -File | Where-Object { $_.Name -like '*.log' -and $_.Name -cne '00001-oldbox-fwd-1-x.freeze.log' } | Sort-Object Name); Ok ($new.Count -ge 1) 'the call logs were written'
  Ok ($new[0].Name -match '\A00003-') "the first new log is numbered 3 (2 files + 1), not 4 (the part counted): $($new[0].Name)"
  $b = [IO.File]::ReadAllBytes($new[0].FullName); Ok (-not ($b.Count -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) 'UTF-8 without BOM'; Ok ($b.Count -gt 0 -and $b[$b.Count - 1] -eq 10) 'ends with LF'
}
# review-lap-final P3-1: the rebuild pins old's and new's host keys in the move known_hosts through a whole-file rewrite (Write-PhienText, ASCII); the file's content is checked, not only that it exists
T 'L.rebuild-known-hosts: the rebuild writes the pins `<addr> <key>` of old and new into the move known_hosts as plain ASCII (no BOM, LF, one line per pin, old first), keeps an unrelated line and adds the missing newline before the first new pin, never duplicates a pin already there, and a second rebuild leaves the file byte-identical; no .part file is left' {
  $kh = Join-Path (MoveDir) 'known_hosts'; $lo = "$OldAddr ssh-ed25519 $KeyOld"; $ln = "$NewAddr ssh-ed25519 $KeyNew"
  $lines = { @([IO.File]::ReadAllLines($kh)) }; $bytes = { [IO.File]::ReadAllBytes($kh) }
  # ssh's accept-new pins the key during the rebuild's reads (the fake does too); the rebuild's own write is the net for a pin that is still missing at the end: the push scan (gh repo list: after the reads, before the write) clears the pins here
  Fx-Copied; $W.GhHook = { [IO.File]::WriteAllText($kh, '') }; Lose-State; [void](Rebuild-Now)
  $b = & $bytes; Ok (-not ($b.Count -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) 'no BOM'; Ok (@($b | Where-Object { $_ -eq 13 -or $_ -gt 127 }).Count -eq 0) 'plain ASCII, no CR'; Ok ($b[$b.Count - 1] -eq 10) 'ends with LF'
  Eq ((& $lines) -join ' | ') "$lo | $ln" 'a missing file is rebuilt with old first, then new, one line each'
  Eq (@(Get-ChildItem -LiteralPath (MoveDir) -Force | Where-Object { $_.Name -like 'known_hosts.part-*' }).Count) 0 'no .part file left'
  $before = & $bytes; $W.GhHook = $null; Lose-State; [void](Rebuild-Now); Eq ([Convert]::ToBase64String((& $bytes))) ([Convert]::ToBase64String($before)) 'a second rebuild leaves the file byte-identical (pins are never added twice)'
  Reset-World; Fx-Copied; $W.GhHook = { [IO.File]::WriteAllText($kh, "other.example ssh-ed25519 AAAAother`n$lo", (New-Object Text.UTF8Encoding($false))) }   # an unrelated line, old already pinned, no final newline, new not pinned
  Lose-State; [void](Rebuild-Now); Eq ((& $lines) -join ' | ') "other.example ssh-ed25519 AAAAother | $lo | $ln" 'the unrelated line and the old pin are kept, the new pin is added on its own line'
  Ok ((& $bytes)[-1] -eq 10) 'ends with LF'
}
T 'L.rebuild-return-complete: all three return calls done on old (Q-newlost YES, with no x.switch): the rebuild is rolled-back, serving old, mark null, new_discarded true; the next verb fences new first and enables nothing on it; a FAILED r.health-src (it is report-only: E-R18) still rebuilds rolled-back, a MISSING one rolling-back (it is re-run)' {
  foreach ($leg in 'all-done', 'health-failed', 'health-missing') {
    Reset-World; Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.health$' -Mode down; [void](Do-Cutover 70); if ($leg -ceq 'health-failed') { Add-Fault -M old -Key '^fwd-1-r\.health-src$' -Rc 69 -Out @('MOVE item health-nginx kind=check state=failed') }
    Ans 'YES'; $r = Run-Move @('cutover'); Eq $r.Code 10 "[$leg] Q-newlost ($($r.Text))"; if ($leg -ceq 'health-missing') { [void]$W.old.Rec.Remove('fwd-1-r.health-src'); [void]$W.old.Order.Remove('fwd-1-r.health-src') }
    $W.new.Up = $true; Lose-State; $s = Rebuild-Now; Eq $s.serving 'old' "[$leg] serving"; Eq $s.new_discarded $true "[$leg] new_discarded"; Ok ($s.phase -cne 'cut') "[$leg] never cut"
    if ($leg -ceq 'health-missing') { Eq $s.mark 'rolling-back' "[$leg] mark"; Eq $s.phase 'copied' "[$leg] phase"; $r = Run-Move @('cutover'); Eq $r.Code 10 "[$leg] the return is completed ($($r.Text))"; Eq (Sent 'old' '^fwd-1-r\.health-src$') 1 "[$leg] r.health-src re-run"; Assert-NewUntouched $leg; Assert-OldServes $leg }
    else { Eq $s.phase 'rolled-back' "[$leg] phase"; Ok ($null -eq $s.mark) "[$leg] mark"; $r = Run-Move @('copy'); Assert-NewUntouched $leg }
  }
}
T 'L.rebuild-rollback-stop-only: a plain rollback is killed after new''s r.stop-dst and before old''s r.start-src (no return record on old); the state is lost: the rebuild is NOT rolled-back (the fence''s r.stop-dst on new is no return), mark rolling-back from the move-ids; `cutover` completes the rollback (old started, rolled-back, exit 10)' {
  Fx-Copied; Add-Fault -M new -Key '-x\.final$' -Rc 1; Add-Fault -M old -Key '^fwd-1-r\.start-src$' -Rc 0 -Do { throw 'laptop gone before r.start-src' }; Ans 'có'; $r = Run-Move @('cutover'); Ok ($r.Code -ne 0) "the laptop died ($($r.Text))"
  Ok ($W.new.Rec.ContainsKey('fwd-1-r.stop-dst') -and [int]$W.new.Rec['fwd-1-r.stop-dst'].Rc -eq 0) 'fixture: new''s r.stop-dst is done'; Ok (-not $W.old.Rec.ContainsKey('fwd-1-r.start-src')) 'fixture: no return record on old'
  Lose-State; $s = Rebuild-Now; Ok ($s.phase -cne 'rolled-back') "not rolled-back: $($s.phase)"; Eq $s.mark 'rolling-back' 'mark'
  $r = Run-Move @('cutover'); Eq $r.Code 10 "the rollback completes ($($r.Text))"; Eq (Sent 'old' '^fwd-1-r\.start-src$') 1 'old started'; Assert-OldServes 'stop-only'
  # the same in a carry-back (dir back): a Q-discard YES return killed after new's back-2-r.stop-dst, before old's r.start-src: the fence's r.stop-dst on new is NOT an E-R19 end (cut, serving new)
  Reset-World; Start-Carry; Add-Fault -M old -Key '^back-2-x\.stop-dst$' -Rc 1; Add-Fault -M old -Key '^back-2-r\.start-src$' -Rc 0 -Do { throw 'laptop gone before r.start-src' }; Ans 'có', 'YES'; $r = Run-Move @('cutover'); Ok ($r.Code -ne 0) "[carry] the laptop died ($($r.Text))"
  Ok ($W.new.Rec.ContainsKey('back-2-r.stop-dst') -and [int]$W.new.Rec['back-2-r.stop-dst'].Rc -eq 0) '[carry] fixture: new''s back-2-r.stop-dst is done'; Ok (-not $W.old.Rec.ContainsKey('back-2-r.start-src')) '[carry] fixture: no return record on old'
  Lose-State; $s = Rebuild-Now; Ok ($s.phase -cne 'cut') "[carry] never cut (not an E-R19 end): $($s.phase)"; Ok ($s.phase -cne 'rolled-back') "[carry] not rolled-back: $($s.phase)"; Eq $s.serving 'old' '[carry] serving'; Eq $s.carry $false '[carry] carry'
  $r = Run-Move @('cutover'); Eq $r.Code 10 "[carry] the rollback completes ($($r.Text))"; Eq (Sent 'old' '^back-2-r\.start-src$') 1 '[carry] old started'; Eq (SentAny '-x\.final$') 0 '[carry] no x.final'; Assert-OldServes 'stop-only carry'
}
# ======= final7 :2 (P2): c.init-new killed after new published its move-id (move-run.sh:555) but before target.json was written (:559), then the laptop state is lost: the rebuild takes target_* from the durable c.init-new `in` record
# (`MOVE target-in <json>`, the newest run/*-c.init-new record's `target` key) when target.json is missing or invalid; with neither it refuses before any write; a valid target.json wins
function Flat-Target($T) { [ordered]@{ users = (@($T.users | ForEach-Object { "$($_.name):$($_.uid)" }) -join ','); groups = (@($T.groups | ForEach-Object { "$($_.name):$($_.gid)" }) -join ','); subids = (@($T.subids | ForEach-Object { "$($_.user):$($_.kind):$($_.start):$($_.count)" }) -join ','); addrs = (@($T.addrs) -join ','); stop = "$($T.stop_budget_s)" } }
function Flat-State($S) { Flat-Target ([pscustomobject]@{ users = $S.target_users; groups = $S.target_groups; subids = $S.target_subids; addrs = $S.target_addrs; stop_budget_s = $S.target_stop_budget_s }) }
$TargetInPf = @('INV target user=quoc uid=1000 home-nonskel=1', 'INV target user=zed uid=1700 home-nonskel=0', 'INV target group=devs gid=1800', 'INV target subid user=zed kind=uid start=300000 count=65536', 'INV target subid user=zed kind=gid start=300000 count=65536', 'INV target addr=198.51.100.20', 'INV target addr=2001:db8::20', 'INV target platform=0', 'INV target stop_budget_s=240')
function Kill-InitNew { Reset-World; $W.Pf = $TargetInPf; Fx-Planned; Add-Fault -M new -Key '^fwd-1-c\.init-new$' -Rc 0 -Mode kill; $r = Run-Move @('copy'); Ok ($r.Code -ne 0) "the laptop died in c.init-new ($($r.Text))"; Ok ($null -ne $W.new.TargetIn) 'fixture: new recorded the call''s in (the target snapshot)' }
function Mut-TargetIn([scriptblock]$F) { $t = $W.new.TargetIn | ConvertFrom-Json; & $F $t; $W.new.TargetIn = ConvertTo-Json -InputObject $t -Depth 10 -Compress }
T 'L.rebuild-target-in: target.json missing (c.init-new killed before it was written) and the state lost: the rebuild restores target_users / groups / subids / addrs / stop_budget_s from the c.init-new in-record snapshot, the next copy re-plans with the same_users protection and sends the same target; an invalid target.json falls back to the snapshot, a valid target.json wins over it' {
  $want = [ordered]@{ users = 'quoc:1000,zed:1700'; groups = 'devs:1800'; subids = 'zed:uid:300000:65536,zed:gid:300000:65536'; addrs = '198.51.100.20,2001:db8::20'; stop = '240' }
  Kill-InitNew; $snap = Flat-Target ($W.new.TargetIn | ConvertFrom-Json); foreach ($k in $want.Keys) { Eq $snap[$k] $want[$k] "fixture: snapshot $k" }; $W.new.Target = $null   # the kill came before :559
  Lose-State; $s = Rebuild-Now; $got = Flat-State $s; foreach ($k in $want.Keys) { Eq $got[$k] $want[$k] "[missing target.json] state target_$k from the snapshot" }; Eq $s.phase 'planned' '[missing target.json] phase'
  $r = Run-Move @('copy'); Eq $r.Code 0 "[retry] copy ($($r.Text))"; $in = @($W.PlanStdin[-1]); foreach ($l in 'target-user zed 1700', 'target-addr 198.51.100.20') { Ok ($in -ccontains $l) "[retry] the re-plan keeps the target protection: lacks [$l]" }
  $sent = Flat-Target $W.new.InitStdin.target; foreach ($k in $want.Keys) { Eq $sent[$k] $want[$k] "[retry] c.init-new sends target.$k" }
  Kill-InitNew; $W.new.Target = '{"users":[]}'; Lose-State; $s = Rebuild-Now; $got = Flat-State $s; foreach ($k in $want.Keys) { Eq $got[$k] $want[$k] "[invalid target.json] state target_$k from the snapshot" }
  Kill-InitNew; Mut-TargetIn { param($t) $t.stop_budget_s = 999 }; Lose-State; $s = Rebuild-Now; Eq (Flat-State $s).stop '240' '[both valid] target.json wins over the snapshot'
}
T 'L.rebuild-target-in-refused: new holds a move-id but neither a valid target.json nor a valid c.init-new snapshot (none, or a snapshot with a missing key, a non-digit uid, a bad subid kind, a bad address, a name with a blank): the rebuild refuses (exit 1, "không còn danh sách tài khoản đích") BEFORE any write: no state.json, no manifest.json' {
  $dirSnap = { @(Get-ChildItem -LiteralPath (MoveDir) -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object { "$($_.FullName):$((Get-FileHash -LiteralPath $_.FullName).Hash)" }) }
  $legs = [ordered]@{
    'no snapshot'      = { $W.new.TargetIn = $null }
    'no stop_budget_s' = { Mut-TargetIn { param($t) [void]$t.PSObject.Properties.Remove('stop_budget_s') } }
    'stop_budget_s not digits' = { Mut-TargetIn { param($t) $t.stop_budget_s = 'abc' } }
    'uid not digits'   = { Mut-TargetIn { param($t) $t.users[0].uid = 'x1' } }
    'subid kind'       = { Mut-TargetIn { param($t) $t.subids[0].kind = 'sub' } }
    'addr chars'       = { Mut-TargetIn { param($t) $t.addrs[0] = '1.2.3.4;rm' } }
    'name with blank'  = { Mut-TargetIn { param($t) $t.users[0].name = 'a b' } }
  }
  foreach ($k in $legs.Keys) {
    Kill-InitNew; $W.new.Target = $null; & $legs[$k]; Lose-State; $d0 = & $dirSnap; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias)
    Eq $rr.Code 1 "[$k] refused ($($rr.Text))"; HasText 'không còn danh sách tài khoản đích'; Ok (-not (Test-Path -LiteralPath (StatePath))) "[$k] no state.json"; Eq ((& $dirSnap) -join '|') ($d0 -join '|') "[$k] nothing else written under the move dir (manifest.json, known_hosts, ...)"
  }
}
# ======= final7 :3 (P2): a manual back's x.switch completed, the laptop died before the alias chores, the state is lost: the rebuild (back-done, serving old) must keep both alias backups (old_addr) so that `back` restores the aliases
T 'L.rebuild-back-aliases: x.switch done in a manual back, the laptop dies before the alias chores, the state is lost: the rebuild is back-done / serving old with chores pending and aliases.laptop_backup = aliases.coder_backup = old_addr; `back` runs the chores and the laptop ssh alias reaches old again' {
  Fx-Cut; Add-Fault -M old -Key '^back-2-x\.switch$' -Rc 0 -Mode kill; Ans 'YES'; $r = Run-Move @('back'); Ok ($r.Code -ne 0) "the laptop died after x.switch ($($r.Text))"; Eq (Get-ConfigHosts (Get-LaptopConfig))[$OldAlias] $NewAddr 'fixture: the alias still reaches new'
  Lose-State; $s = Rebuild-Now; Eq $s.phase 'back-done' 'phase'; Eq $s.serving 'old' 'serving'; Eq $s.chores_done $false 'chores pending'; Eq "$($s.aliases.laptop_backup)" $OldAddr 'laptop_backup'; Eq "$($s.aliases.coder_backup)" $OldAddr 'coder_backup'
  Ans 'YES'; $r = Run-Move @('back'); Eq (Get-ConfigHosts (Get-LaptopConfig))[$OldAlias] $OldAddr "the back chores point the alias at old again ($($r.Code): $($r.Text))"; Eq (Get-St).chores_done $true 'chores done'
}
T 'L.rebuild-back-aliases-coder: the same rebuild: the coder alias script runs with old_addr (coder_backup) and the coder alias reaches old again' {
  Fx-Cut; $h = Get-ConfigHosts ([IO.File]::ReadAllText((Join-Path (Join-Path $CoderHome '.ssh') 'config'))); Eq $h[$OldAlias] $NewAddr 'fixture: the coder alias reaches new'
  Add-Fault -M old -Key '^back-2-x\.switch$' -Rc 0 -Mode kill; Ans 'YES'; [void](Run-Move @('back')); Lose-State; $s = Rebuild-Now; Eq "$($s.aliases.coder_backup)" $OldAddr 'coder_backup'
  Ans 'YES'; $r = Run-Move @('back'); $h = Get-ConfigHosts ([IO.File]::ReadAllText((Join-Path (Join-Path $CoderHome '.ssh') 'config'))); Eq $h[$OldAlias] $OldAddr "the coder alias reaches old again ($($r.Code): $($r.Text))"
} -NeedsBash
# G35 (E-R5, E-R23): x.final was SENT in a carry-back when new holds its record; a rebuilt state keeps that fact, so a new that is down later does not turn the carry-back into a Q-discard
T 'L.rebuild-final-sent: a carry-back dies after x.final was sent, the state is lost and rebuilt with both machines up, then new goes down: `cutover` ends 70 with the "chỉ tiếp tục được khi máy mới nối lại" line, no Q-discard / Q-newlost, no r.start-src to old' {
  Start-Carry; Add-Fault -M new -Key '^back-2-x\.final$' -Rc 0 -Mode kill; Ans 'có'; $r1 = Run-Move @('cutover'); Ok ($r1.Code -ne 0) "the laptop died ($($r1.Text))"; Ok ($W.new.Rec.ContainsKey('back-2-x.final')) 'fixture: new recorded x.final'
  Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild ($($rr.Text))"; Eq ([string](Get-St).answers.'final-sent') 'back-2-x.final' 'final-sent restored'
  $W.new.Up = $false; $n0 = $W.Prompts.Count; $r = Run-Move @('cutover'); Eq $r.Code 70 "exit ($($r.Text))"; HasText 'chỉ tiếp tục được khi máy mới nối lại'; Eq $W.Prompts.Count $n0 'no Q-discard / Q-newlost asked'; Eq (SentAny '-r\.start-src$') 0 'old is not restarted'
}
T 'L.rebuild-final-sent-none: no x.final record on new: the same rebuild and a down new keep today''s Q-discard question' {
  Start-Carry; Add-Fault -M new -Key '^back-2-x\.stop-src$' -Rc 0 -Mode kill; Ans 'có'; $r1 = Run-Move @('cutover'); Ok ($r1.Code -ne 0) "the laptop died ($($r1.Text))"; Ok (-not $W.new.Rec.ContainsKey('back-2-x.final')) 'fixture: no x.final'
  Lose-State; [void](Run-Move @('status', '--rebuild', $OldAlias, $NewAlias)); Ok (-not [string](Get-St).answers.'final-sent') 'no final-sent'
  $W.new.Up = $false; $n0 = $W.Prompts.Count; Ans 'không'; [void](Run-Move @('cutover')); Ok ($W.Prompts.Count -gt $n0) "a question was asked: $($W.Prompts -join ' | ')"; NoText 'chỉ tiếp tục được khi máy mới nối lại'
}
# O2: a refresh (D.3 re-run) that died after the re-pin: the cutover must still refuse (answers{refresh-pending}); the rebuild restores it from the records: pending iff no DONE c.adopt.N on new carries the manifest_sha
T 'L.rebuild-refresh-pending: (a) a refresh dies after c.repin.N on both and c.prepare.N failed: rebuilt copied with refresh-pending true, cutover refuses, no 0b transfer, `copy` completes and cutover goes on; (b) old-only re-pin (new still pins A): the same; (c) a completed refresh: not pending; (d) a first copy: not pending' {
  $late = [ordered]@{ name = 'late'; uid = 1003 }
  Fx-Copied; $W.Mf.users = @($W.Mf.users) + $late; Add-Fault -M new -Key '-c\.prepare\.2$' -Rc 1; [void](Do-Copy 1); Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild a ($($rr.Text))"
  Eq (Get-St).phase 'copied' 'phase'; Eq (Get-St).answers.'refresh-pending' $true '(a) pending'; Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 1 "(a) cutover refused ($($r.Text))"; HasText 'chạy fcode move copy lại'; Eq (SentAny '-c\.transfer\.|-x\.freeze$') 0 '(a) no 0b transfer, nothing frozen'
  [void](Do-Copy 0); Eq (Get-St).answers.'refresh-pending' $false '(a) the refresh ended'; Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 0 "(a) cutover after a good refresh ($($r.Text))"
  Reset-World; Fx-Copied; $W.Mf.users = @($W.Mf.users) + $late; Add-Fault -M new -Key '-c\.repin\.1$' -Rc 1; [void](Do-Copy -1); $B = $W.LastSha; Eq $W.old.Sha $B 'fixture: old pins B'; Ok ($W.new.Sha -cne $B) 'fixture: new still pins A'
  Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild b ($($rr.Text))"; Eq (Get-St).manifest_sha $B '(b) manifest_sha = old''s pin'; Eq (Get-St).answers.'refresh-pending' $true '(b) pending'
  Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 1 "(b) cutover refused ($($r.Text))"; HasText 'chạy fcode move copy lại'
  Reset-World; Fx-Copied; $W.Mf.users = @($W.Mf.users) + $late; [void](Do-Copy 0); Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild c ($($rr.Text))"; Eq (Get-St).answers.'refresh-pending' $false '(c) a completed refresh is not pending'; Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 0 "(c) cutover goes on ($($r.Text))"
  Reset-World; Fx-Copied; Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild d ($($rr.Text))"; Eq (Get-St).answers.'refresh-pending' $false '(d) a first copy is not pending'; Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 0 "(d) cutover goes on ($($r.Text))"
}
# O4: target_platform survives a rebuild (the probe line of the rebuild script; B31, DG-R1)
T 'L.rebuild-target-platform: a mixed pair (new carries the platform) is rebuilt: target_platform 1, so a copy refresh whose re-plan adds a tree item under a platform path refuses target-not-empty; with no probe line target_platform is 0 and the same copy goes on' {
  $node = [ordered]@{ id = 'file-usr-local-bin-node'; root = '/usr/local/bin/node'; kind = 'file'; bytes_apparent = 1000; inodes = 1 }
  $W.Pf = @('INV target user=quoc uid=1000 home-nonskel=1', 'INV target platform=1', 'INV target stop_budget_s=120'); Fx-Copied; Eq (St-Raw 'target_platform') '1' 'stored from preflight'
  Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild ($($rr.Text))"; Eq (St-Raw 'target_platform') '1' 'restored from the probe'
  $W.Mf.items = @($W.Mf.items) + $node; [void](Do-Copy 65); HasText 'Máy mới không trống'; HasText '/usr/local/bin/node'; Eq (SentAny '-c\.repin\.') 0 'refused before c.repin.N'
  Reset-World; $W.Pf = @('INV target user=quoc uid=1000 home-nonskel=1', 'INV target platform=1', 'INV target stop_budget_s=120'); Fx-Copied; $W.RebuildNoProbe = $true; Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 'rebuild'; Eq (St-Raw 'target_platform') '0' 'no probe line: 0'
  $W.Mf.items = @($W.Mf.items) + $node; [void](Do-Copy 0); Ok ((Sent 'old' '-c\.repin\.[0-9]+$') -ge 1) 'the copy went on to c.repin.N'
}
# Astra final4 P2: a target-only account whose name is a valid name token (`svc$`) holds a subuid range; the laptop must keep it (plan, target.json, rebuild) so a moved user overlapping it is refused before any write
T 'L.rebuild-target-subid-token: preflight''s `INV target subid user=svc$ ...` is kept in target_subids (plan) and restored by the rebuild from target.json; a copy refresh whose re-plan moves a user whose range overlaps it refuses uid-collision (what=subuid) before c.repin / prepare / transfer' {
  $W.Pf = @('INV target user=quoc uid=1000 home-nonskel=1', 'INV target user=app uid=1001 home-nonskel=0', 'INV target platform=0', 'INV target stop_budget_s=120', 'INV target subid user=svc$ kind=uid start=300000 count=65536', 'INV target subid user=alice.smith kind=gid start=500000 count=65536')
  Fx-Copied; $sb = @((Get-St).target_subids | ForEach-Object { "$($_.user):$($_.kind):$($_.start):$($_.count)" }); Ok ($sb -ccontains 'svc$:uid:300000:65536' -and $sb -ccontains 'alice.smith:gid:500000:65536') "plan kept the ranges of the token-named accounts: $($sb -join ',')"
  $t = $W.new.Target | ConvertFrom-Json; Ok (@($t.subids | Where-Object { $_.user -ceq 'svc$' }).Count -eq 1) 'c.init-new sent the range in target.json'
  Lose-State; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild ($($rr.Text))"
  $sb = @((Get-St).target_subids | ForEach-Object { "$($_.user):$($_.kind):$($_.start):$($_.count)" }); Ok ($sb -ccontains 'svc$:uid:300000:65536' -and $sb -ccontains 'alice.smith:gid:500000:65536') "the rebuild restored them: $($sb -join ',')"
  $W.Mf.subids = @([ordered]@{ kind = 'uid'; name = 'app'; start = 320000; count = 65536 }); [void](Do-Copy 65); HasText 'Trùng user hoặc uid trên máy mới'; HasText 'what=subuid'; Eq (SentAny '-c\.(repin|prepare|transfer)\.') 0 'refused before any write'
}
# O5 (DECISION-r3, static): every laptop-state field and every answers{} key the code writes is named in $MoveRebuildInventory (restored `from:<src>` or `empty:<why>`), the keys come from New-MoveState, the literal Set-MoveProp /
# Set-MoveAnswer $S '<k>', Set-MoveAsk (a literal key or the part before the first `$` of a computed one) and Set-MoveWriteAhead $S @{...}; `answers` has ONE writer (Set-MoveAnswer); every `from:` key is written by the rebuild code
function Get-InventoryProblems([string]$Text) {
  $A = [Management.Automation.Language.Parser]; $tk = $null; $er = $null; $ast = $A::ParseInput($Text, [ref]$tk, [ref]$er); $pr = New-Object Collections.Generic.List[string]
  if ($er.Count) { return @("does not parse: $($er[0].Message)") }
  $isS = { param($e) $e -is [Management.Automation.Language.VariableExpressionAst] -and $e.VariablePath.UserPath -ceq 'S' }
  $str = { param($e, [bool]$Prefix) if ($e -is [Management.Automation.Language.StringConstantExpressionAst]) { [string]$e.Value } elseif ($Prefix -and $e -is [Management.Automation.Language.ExpandableStringExpressionAst]) { $v = [string]$e.Value; $i = $v.IndexOf('$'); if ($i -ge 0) { $v.Substring(0, $i) } else { $v } } else { $null } }
  $asg = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$MoveRebuildInventory' }, $true))
  if ($asg.Count -ne 1) { return @('$MoveRebuildInventory is not assigned exactly once') }
  $inv = @{}; $iht = @($asg[0].FindAll({ param($n) $n -is [Management.Automation.Language.HashtableAst] }, $true))[0]; foreach ($kv in $iht.KeyValuePairs) { $inv[[string]$kv.Item1.Value] = ([string]$kv.Item2.Extent.Text).Trim("'") }
  foreach ($k in @($inv.Keys)) { if ($inv[$k] -cnotmatch '\A(from|empty):.+') { $pr.Add("inventory value of [$k] is neither from:<src> nor empty:<why>: $($inv[$k])") } }
  $nf = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'New-MoveState' }, $true))[0]; $props = @(); if ($nf) { $props = @(@($nf.FindAll({ param($n) $n -is [Management.Automation.Language.HashtableAst] }, $true))[0].KeyValuePairs | ForEach-Object { [string]$_.Item1.Value }) }
  if (-not $props.Count) { $pr.Add('New-MoveState: no property list found') }
  foreach ($p in $props) { if (-not $inv.ContainsKey($p)) { $pr.Add("New-MoveState property [$p] is not in the inventory") } }
  foreach ($f in 'map.txt', 'manifest.json', 'known_hosts') { if (-not $inv.ContainsKey($f)) { $pr.Add("file [$f] is not in the inventory") } }
  $inFn = { param($n, [string]$Name) $p = $n.Parent; while ($p) { if ($p -is [Management.Automation.Language.FunctionDefinitionAst] -and $p.Name -ceq $Name) { return $true }; $p = $p.Parent }; $false }
  foreach ($c in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))) {
    $nm = $c.GetCommandName(); $e = @($c.CommandElements)
    if ($nm -cin 'Set-MoveProp', 'Set-MoveAnswer') { if ($e.Count -ge 3 -and (& $isS $e[1])) { $k = & $str $e[2] $false; if ($null -ne $k -and -not $inv.ContainsKey($k)) { $pr.Add("$nm `$S '$k': [$k] is not in the inventory") } } }
    elseif ($nm -ceq 'Set-MoveAsk') { if ($e.Count -ge 4 -and (& $isS $e[1])) { $k = & $str $e[3] $true; if ($null -ne $k -and -not $inv.ContainsKey($k)) { $pr.Add("Set-MoveAsk key/prefix [$k] is not in the inventory") } } }
    elseif ($nm -ceq 'Set-MoveWriteAhead') { if ($e.Count -ge 3 -and (& $isS $e[1]) -and $e[2] -is [Management.Automation.Language.HashtableAst]) { foreach ($kv in $e[2].KeyValuePairs) { $k = & $str $kv.Item1 $false; if ($null -ne $k -and $props -cnotcontains $k) { $pr.Add("Set-MoveWriteAhead key [$k] is not declared in New-MoveState") } } } }
    elseif ($nm -ceq 'Set-MoveMapVal' -and $e.Count -ge 2 -and $e[1].Extent.Text -ceq '$S.answers' -and -not (& $inFn $c 'Set-MoveAnswer')) { $pr.Add("answers has a second writer: $($c.Extent.Text)") }
  }
  $rb = (@($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -cmatch 'Rebuil[dt]' }, $true) | ForEach-Object { $_.Extent.Text }) -join "`n")
  $alias = @{ 'known_hosts' = 'Get-MoveKnownFile'; 'manifest.json' = 'Save-MoveManifest'; 'answers' = 'Set-MoveAnswer' }
  foreach ($k in @($inv.Keys)) { if ($inv[$k] -cmatch '\Afrom:') { $w = if ($alias.ContainsKey($k)) { $alias[$k] } else { $k }; if ($rb -cnotmatch ('(?<![A-Za-z0-9_-])' + [regex]::Escape($w) + '(?![A-Za-z0-9_-])')) { $pr.Add("inventory says [$k] is restored (from:) but the rebuild code never writes it") } } }
  if ($Text -cnotmatch 'every top-level field.*declared here') { $pr.Add('New-MoveState lacks its "every top-level field is declared here" comment') }
  $pr
}
T 'L.rebuild-inventory: the rebuild inventory names every laptop-state field and every answers{} key the code writes (New-MoveState, literal Set-MoveProp / Set-MoveAnswer, the Set-MoveAsk keys and prefixes, Set-MoveWriteAhead), answers has one writer, every from: key is written by the rebuild; planted writers are caught' {
  $pr = @(Get-InventoryProblems $script:FcodeText); Eq $pr.Count 0 "inventory problems: $($pr -join ' | ')"
  $cases = @(
    @('a planted literal answers key', "`nSet-MoveAnswer `$S 'planted' 1`n", 'planted'),
    @('a planted literal state key', "`nSet-MoveProp `$S 'plantedprop' 1`n", 'plantedprop'),
    @('a planted Set-MoveAsk key', "`nSet-MoveAsk `$S `$asked 'Q-planted' 'có'`n", 'Q-planted'),
    @('a planted Set-MoveAsk computed key', "`nSet-MoveAsk `$S `$asked `"Q-plantedprefix:`$nm`" 'có'`n", 'Q-plantedprefix:'),
    @('a planted write-ahead key', "`nSet-MoveWriteAhead `$S @{ plantedwa = 1 } -NoCheck`n", 'plantedwa'),
    @('a second answers writer', "`nSet-MoveMapVal `$S.answers 'x' 1`n", 'second writer'))
  foreach ($c in $cases) { $p2 = @(Get-InventoryProblems ($script:FcodeText + $c[1])); Ok (@($p2 | Where-Object { $_ -like "*$($c[2])*" }).Count -ge 1) "$($c[0]) must be reported: $($p2 -join ' | ')" }
  $p3 = @(Get-InventoryProblems ($script:FcodeText -replace "'Q-ownip' = ", "'Q-ownipX' = ")); Ok (@($p3 | Where-Object { $_ -like '*Q-ownip*' }).Count -ge 1) "an inventory without a written key is reported: $($p3 -join ' | ')"
}
# :9 (DECISION-r3) a forward item root deleted on new: the SERVER's back pre pass skips it itself (`MOVE item <id> kind=<k> state=done why=item-gone`, rc 0, nothing copied); the laptop always sends the plain pre-copy and x.check drops the item (E-R31)
T 'L.back-precopy-item-gone: an item root deleted on new before a manual back: the pre-copy IS sent (one c.transfer.N) and ends 0 with the server''s item-gone line, old''s copy is untouched, x.check drops the item from the re-pin, x.final carries the re-pin and the back ends back-done; a final pass against a still-pinned gone root would fail' {
  Fx-Cut; $W.new.GoneRoots = @('/srv/data'); $c0 = $W.old.Content.Count
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "back ($($r.Text))"; Eq (Get-St).phase 'back-done' 'phase'
  Eq (SentAny '^back-2-c\.transfer\.') 1 'one pre-copy transfer is sent'; $t = @(RecCalls -All | Where-Object { $_.Call -match '^back-2-c\.transfer\.[0-9]+$' })[0]; Eq ([int]$W.new.Rec[$t.Call].Rc) 0 'it ended 0'; Ok (@($W.new.Rec[$t.Call].Out) -contains 'MOVE item srv-data kind=tree state=done why=item-gone') "the server's item-gone line: $(@($W.new.Rec[$t.Call].Out) -join ' | ')"
  Eq $W.old.Content.Count $c0 'old''s copies untouched'; Ok (@($W.new.Rec['back-2-x.check'].Out) -contains 'INV warn item-gone path=/srv/data') 'x.check dropped the item (E-R31)'; Eq (@($W.Mf.items | Where-Object { $_.root -ceq '/srv/data' }).Count) 0 'the re-pinned manifest has no /srv/data'
  Eq ([int]$W.new.Rec['back-2-x.final'].Rc) 0 'x.final (against the re-pin) ended 0'
}
T 'L.back-precopy-item-present: with every item root present the pre-copy runs (one c.transfer.N) and carries the whole manifest' {
  Fx-Cut; Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "back ($($r.Text))"; Eq (SentAny '^back-2-c\.transfer\.') 1 'one pre-copy transfer'; Eq (@($W.Mf.items).Count) 2 'both items kept'; Ok (-not @(@($W.new.Rec['back-2-x.check'].Out) | Where-Object { $_ -match 'item-gone' }).Count) 'no item-gone'
}
# :10 the bootstrap gate pulls through old's door by plain ssh from new: like the server's mv_ssh_opts it must ignore the client config and the global known_hosts the adopt may have copied from old
T 'L.bootstrap-ssh-isolated: the bootstrap gate script''s ssh (the -e of its rsync) carries -F /dev/null and -o GlobalKnownHostsFile=/dev/null besides its own key, known_hosts and host-key checking' {
  $fr = New-FcmRoot; $r = Run-Bash (Get-MoveBootstrapGateScript) @('--old-addr', "${OldAddr}:2222") $fr (New-Stubs @{ rsync = 'printf "%s\n" "$*" >> "$FCM_ROOT/rsync.log"; exit 0' })
  Eq $r.Code 0 "bootstrap gate ($($r.Text))"; $lg = Join-Path $fr 'rsync.log'; Ok (Test-Path -LiteralPath $lg) 'rsync was called'; $t = [IO.File]::ReadAllText($lg)
  foreach ($o in '-F /dev/null', '-o GlobalKnownHostsFile=/dev/null', '-o UserKnownHostsFile=', '-o StrictHostKeyChecking=yes', '-o BatchMode=yes', '-o IdentitiesOnly=yes', '-p 2222') { Ok ($t.Contains($o)) "ssh option [$o] in: $t" }
} -NeedsBash
# the agreement check (D.11, W1-T10-G9): a machine with no move-id is skipped only in phase planned; in every other phase it is re-init-ed like a disagreement
T 'L.agreement-missing-move-id: new lost its move-id after the copy (wiped box): `cutover` re-inits new (c.init-new under the same attempt) before any call that needs it, and the cutover goes through' {
  Fx-Copied; $n = $W.new; $n.MoveId = $null; $n.Rec = @{}; $n.Order.Clear(); $n.Last = $null; $n.Sha = ''
  Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 0 "cutover ($($r.Text))"; Eq (Get-St).phase 'cut' 'phase'
  Eq (Sent 'new' '^fwd-1-c\.init-new$') 1 'c.init-new re-sent to new'; Ok ((Sent 'new' '^fwd-1-c\.init-new$') -eq 1 -and $W.new.MoveId.id -ceq (Id)) 'new holds the move-id again'
  Ordered @('^new fwd-1-c\.init-new$', '^old fwd-1-x\.freeze$') -All
}
# a carry-back has no Q-back list (CONTRACT §4.1 answers key): the write-ahead of the carry-back removes a stale one
T 'L.carry-back-drops-back-new-projects: answers{back-new-projects} left by an earlier manual back is removed when a carry-back starts' {
  Start-Carry; $s = Get-St; $a = $s.answers; Set-Prop $a 'back-new-projects' @('app9'); [void](Patch-St @{ answers = $a }); Ok ($null -ne (Get-St).answers.'back-new-projects') 'fixture: a stale list is in the state'
  Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 10 "carry-back ($($r.Text))"; Eq (Get-St).phase 'back-done' 'phase'; Ok ($null -eq (Get-St).answers.PSObject.Properties['back-new-projects']) 'the key is gone from the state'
}
# c.init-new's `target` stdin key (D.0.9 Formats): the REAL server validator (MVR_TJS of deploy-gate lib/move-run.sh, taken out of the file named by MV_RUN_SH and run by node) must accept what Get-MoveTargetJson builds,
# empty and full states, names with `$` and `'`, IPv6 addresses; and it must refuse a malformed key (so the validator really ran)
function Run-TargetValidator([string]$Json) {
  $p = $env:MV_RUN_SH; Ok ($p -and (Test-Path -LiteralPath $p)) "MV_RUN_SH must name deploy-gate lib/move-run.sh (got [$p])"
  $jf = Join-Path $Root ('target-' + [guid]::NewGuid().ToString('N') + '.json'); [IO.File]::WriteAllText($jf, $Json, $utf8); $env:TJSON = $jf
  try {
    Run-Bash ("eval ""`$(sed -n ""/^MVR_TJS='/,/^'\`$/p"" ""`$MV_RUN_SH"")""`n" + '[ -n "${MVR_TJS-}" ] || { echo NO-VALIDATOR; exit 3; }' + "`n" + 'node -e "$MVR_TJS" < "$TJSON"') @() $Root $Root
  } finally { $env:TJSON = $null; Remove-Item -LiteralPath $jf -Force -ErrorAction SilentlyContinue }
}
T 'L.target-key-server-validator: Get-MoveTargetJson output (an empty state, a full one with names holding $ and an apostrophe, IPv6 addresses) is accepted by the server''s real target validator and comes back with the same content; a malformed key is refused' {
  Fx-Planned; [void](Patch-St @{ target_users = @(); target_groups = @(); target_subids = @(); target_addrs = @() }); $S = Read-MoveState
  $r = Run-TargetValidator (Get-MoveTargetJson $S); Eq $r.Code 0 "the empty state is accepted ($($r.Text))"; $o = $r.Text | ConvertFrom-Json; Eq @($o.users).Count 0 'users'; Eq @($o.addrs).Count 0 'addrs'
  [void](Patch-St @{ target_users = @([pscustomobject]@{ name = 'quoc'; uid = 1000 }, [pscustomobject]@{ name = 'a$b'; uid = 1001 }, [pscustomobject]@{ name = "o'brien"; uid = 1002 })
    target_groups = @([pscustomobject]@{ name = 'devs'; gid = 1800 }, [pscustomobject]@{ name = 'g$1'; gid = 1801 })
    target_subids = @([pscustomobject]@{ user = 'quoc'; kind = 'uid'; start = 100000; count = 65536 }, [pscustomobject]@{ user = "o'brien"; kind = 'gid'; start = 165536; count = 65536 })
    target_addrs = @('198.51.100.20', '2001:db8::20', 'fe80::1') })
  $S = Read-MoveState; $j = Get-MoveTargetJson $S; $r = Run-TargetValidator $j; Eq $r.Code 0 "the full state is accepted ($($r.Text))"; $o = $r.Text | ConvertFrom-Json; $i = $j | ConvertFrom-Json
  Eq (@($o.users | ForEach-Object { $_.name }) -join ',') "quoc,a`$b,o'brien" 'user names'; Eq (@($o.groups | ForEach-Object { $_.gid }) -join ',') '1800,1801' 'group ids'; Eq (@($o.subids | ForEach-Object { "$($_.user):$($_.kind):$($_.start):$($_.count)" }) -join ',') "quoc:uid:100000:65536,o'brien:gid:165536:65536" 'subids'
  Eq (@($o.addrs) -join ',') '198.51.100.20,2001:db8::20,fe80::1' 'addrs'; Eq $o.stop_budget_s $i.stop_budget_s 'stop_budget_s'
  $r = Run-TargetValidator '{"users":[],"groups":[],"subids":[],"addrs":[]}'; Eq $r.Code 1 "a key without stop_budget_s is refused ($($r.Text))"
  $r = Run-TargetValidator ((Get-MoveTargetJson $S) -replace '"uid":1000', '"uid":-1'); Eq $r.Code 1 'a negative uid is refused'
} -NeedsBash
# ============================== ruling 06/11 (33): the sha across the step-3 re-pin (manifest_sha_prev) and the replay of a done call ==============================
# The fake gate models what the server does (D.0.1, K1; T1/T5 R16): x.check rc 0 re-pins the manifest of the machine that ran it (new sha B); a machine holds ITS pin
# (A on dst until x.repin) and refuses an executing call whose --sha is not that pin (65 what=sha, a "<machine> <call> sha" log line); a re-sent id whose record
# is done is a replay (id/dir/attempt compared, --sha ignored, nothing executed, no state written). Mode kill = the call ran to the end, the laptop died before its answer.
# one step 3 that went through (S4, rework L3): x.repin on dst PINS the --sha flag, so it carries the sha of the manifest it ships (B), as does every call after it; every call
# before it carries A (the laptop's sha before x.check; -Before). A non-pinning call to dst while manifest_sha_prev is set carries A: see L.repin-dst-fail-rollback.
function Assert-ShaFlow([string]$Dst, [string]$A, [string]$B, [switch]$Before) {
  $c = @(RecCalls | Where-Object { -not $_.Replay }); $i = -1
  for ($k = 0; $k -lt $c.Count; $k++) { if ($c[$k].M -ceq $Dst -and $c[$k].Call -match '-x\.repin$') { $i = $k; break } }
  Ok ($i -ge 0) "x.repin was sent to $Dst : $(@($c | ForEach-Object { $_.M + ' ' + $_.Call }) -join ', ')"
  Eq $c[$i].Flags['sha'] $B "x.repin on $Dst pins its --sha flag: it carries the sha of the manifest it ships"
  for ($k = 0; $k -lt $c.Count; $k++) {
    if ($k -gt $i) { Eq $c[$k].Flags['sha'] $B "sha of $($c[$k].M) $($c[$k].Call) after x.repin on dst" }
    elseif ($k -lt $i -and $Before) { Eq $c[$k].Flags['sha'] $A "sha of $($c[$k].M) $($c[$k].Call) before x.repin on dst" }
  }
}
T 'L.manifest-sha-prev: x.check rc 0 saves manifest_sha = B and manifest_sha_prev = A before x.repin goes out; while it is set a call to dst that pins no manifest carries A, src and every pinning call (x.repin) carry B (the server pins the --sha flag); it is cleared when x.repin on dst returns 0, so every later call carries B; the same in a manual back (dst = old)' {
  Fx-Copied; $A = (Get-St).manifest_sha
  $script:SeenR = @{}; $W.Hooks['x.repin'] = { param($m, $e) $script:SeenR[$m.Name] = Get-St }
  [void](Do-Cutover); $B = $W.LastSha; Ok ($B -cne $A) 'fixture: x.check changes the sha'
  $d = $script:SeenR['new']; Ok ($null -ne $d) 'x.repin reached new'; Eq $d.manifest_sha $B 'saved before x.repin: manifest_sha = B'; Eq $d.manifest_sha_prev $A 'saved before x.repin: manifest_sha_prev = A'
  Assert-ShaFlow 'new' $A $B -Before
  Eq (ShaRefusals).Count 0 "no what=sha refusal: $(ShaRefusals)"
  $s = Get-St; Eq $s.phase 'cut' 'phase'; Eq $s.manifest_sha $B 'manifest_sha'; Ok (-not [string]$s.manifest_sha_prev) "manifest_sha_prev cleared after x.repin on dst: [$($s.manifest_sha_prev)]"
  Eq $W.old.Sha $B 'old pinned B'; Eq $W.new.Sha $B 'new pinned B'
  # a manual back re-pins too (B.14.6, dir=back: src = new runs x.check, dst = old)
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "back ($($r.Text))"; $B2 = $W.LastSha; Ok ($B2 -cne $B) 'fixture: the back''s x.check changes the sha again'
  Assert-ShaFlow 'old' $B $B2 -Before
  Eq (ShaRefusals).Count 0 "back: no what=sha refusal: $(ShaRefusals)"
  $s = Get-St; Eq $s.manifest_sha $B2 'back: manifest_sha'; Ok (-not [string]$s.manifest_sha_prev) 'back: manifest_sha_prev cleared'
}
# the laptop died while x.check ran (A in the state) or after it saved B, before x.repin reached dst: `cutover` resumes (D.11 cutting, dst_started false) across the re-pin
function Resume-AfterCheck([string]$A, [string]$B, [string]$What) {
  $s0 = Get-St; Eq $s0.mark 'cutting' "$What : the kill left the cutover open"; Eq $s0.dst_started $false "$What : dst_started"
  Ok ([int]$W.old.Rec['fwd-1-x.check'].Rc -eq 0 -and $null -ne $W.old.Rec['fwd-1-x.check'].Rc) "$What : x.check is done on old"
  Eq $W.old.Sha $B "$What : old holds the re-pinned manifest"; Eq $W.new.Sha $A "$What : new still holds the first pin"
  $r = Run-Move @('cutover'); Eq $r.Code 0 "$What : resume ($($r.Text))"; Eq (Get-St).phase 'cut' "$What : phase"
  foreach ($st in 'x.freeze', 'x.check') {
    Eq (Sent 'old' "^fwd-1-$([regex]::Escape($st))$") 0 "$What : $st is replayed, not run again"; Eq (SentAny "^fwd-1-$([regex]::Escape($st))$") 1 "$What : $st is sent again (D.0.5)"
  }
  Eq (Sent 'new' '^fwd-1-x\.repin$') 1 "$What : x.repin on new"; Eq (Sent 'old' '^fwd-1-x\.repin$') 1 "$What : x.repin on old"
  Eq (ShaRefusals).Count 0 "$What : no what=sha refusal: $(ShaRefusals)"; Eq (SentAny '-r\.') 0 "$What : no rollback"
  Assert-ShaFlow 'new' $A $B
  $s = Get-St; Eq $s.manifest_sha $B "$What : manifest_sha"; Ok (-not [string]$s.manifest_sha_prev) "$What : manifest_sha_prev cleared [$($s.manifest_sha_prev)]"
  Eq $W.old.Sha $B "$What : old pinned B"; Eq $W.new.Sha $B "$What : new pinned B"
  Eq (Get-Sha256Hex ([IO.File]::ReadAllBytes((Join-Path (MoveDir) 'manifest.json')))) $B "$What : manifest.json = B"
}
T 'L.resume-cutting-after-x.check: the laptop died while x.check ran (the unit finished, manifest_sha still A): `cutover` replays x.freeze and x.check (done records; their sha A is no longer old''s pin), takes B from the replayed x.check, re-pins new with x.repin (carrying B, the manifest it ships) and ends cut, exit 0; no rollback, no what=sha (ruling 06/11 (33), T13 triage-kill1 D1)' {
  Fx-Copied; $A = (Get-St).manifest_sha
  Add-Fault -M old -Key '^fwd-1-x\.check$' -Rc 0 -Mode kill; Ans 'có'; $r1 = Run-Move @('cutover'); Ok ($r1.Code -ne 0) "the laptop died ($($r1.Text))"
  $B = $W.LastSha; Ok ($B -cne $A) 'fixture: x.check re-pinned old'; Eq (Get-St).manifest_sha $A 'the laptop never saw B'
  Resume-AfterCheck $A $B 'B unsaved'
}
T 'L.resume-cutting-after-x.check-saved: the laptop died after x.check saved B (manifest_sha = B, manifest_sha_prev = A), before x.repin reached new: `cutover` replays x.freeze and x.check with B (done records), x.repin on new carries B, ends cut, exit 0 (ruling 06/11 (33))' {
  Fx-Copied; $A = (Get-St).manifest_sha
  Add-Fault -M new -Key '^fwd-1-x\.repin$' -Mode never; Ans 'có'; $r1 = Run-Move @('cutover'); Ok ($r1.Code -ne 0) "the laptop died ($($r1.Text))"
  $B = $W.LastSha; Ok ($B -cne $A) 'fixture: x.check re-pinned old'; $s = Get-St; Eq $s.manifest_sha $B 'B saved'; Eq $s.manifest_sha_prev $A 'A kept with it'
  Resume-AfterCheck $A $B 'B saved'
  # the same death, then the resume's x.repin on new fails: the plain rollback's r.stop-dst on new still carries A (the replayed x.check must not overwrite the saved manifest_sha_prev with B)
  Reset-World; Fx-Copied; $A = (Get-St).manifest_sha
  Add-Fault -M new -Key '^fwd-1-x\.repin$' -Mode never; Ans 'có'; $r1 = Run-Move @('cutover'); Ok ($r1.Code -ne 0) "the laptop died again ($($r1.Text))"; $B = $W.LastSha
  Add-Fault -M new -Key '^fwd-1-x\.repin$' -Rc 1; $r = Run-Move @('cutover'); Eq $r.Code 10 "resume, x.repin on new fails: plain rollback ($($r.Text))"
  Eq (Sent 'new' '^fwd-1-r\.stop-dst$') 1 'r.stop-dst on new'; Eq (@(CallShas 'new' '^fwd-1-r\.stop-dst$')[0]) $A 'r.stop-dst on new carries A'; Eq (@(CallShas 'old' '^fwd-1-r\.start-src$')[0]) $B 'r.start-src on old carries B'
  Eq (@(LogNow -All | Where-Object { $_ -match ' (manifest-sha|sha)$' })).Count 0 "no refusal: $(@(LogNow -All | Where-Object { $_ -match ' (manifest-sha|sha)$' }))"; Eq (Get-St).phase 'rolled-back' 'phase'
}
T 'L.repin-pinning-dst-call-with-prev: manifest_sha_prev is still set after a failed x.repin on new (new pins A): the copy after the rollback sends c.init-new (and c.repin.N) to new with manifest_sha = the sha of the manifest they ship (the server pins the --sha flag and refuses another: bad-request why=manifest-sha), never A; new then pins that sha and manifest_sha_prev is cleared by the first init on dst that returns 0 (rework R16 L3)' {
  Fx-Copied; $A = (Get-St).manifest_sha
  Add-Fault -M new -Key '^fwd-1-x\.repin$' -Rc 1; Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 10 "plain rollback ($($r.Text))"
  $B = $W.LastSha; $s = Get-St; Eq $s.manifest_sha $B 'manifest_sha = B'; Eq $s.manifest_sha_prev $A 'manifest_sha_prev = A is still set after the rollback'; Eq $W.new.Sha $A 'new still pins A'
  # the next copy: a new attempt re-inits new (Sync-MoveAgreement, a pinning call to dst while prev is set)
  $r = Run-Move @('copy'); Eq $r.Code 0 "copy ($($r.Text))"
  $ini = @(RecCalls | Where-Object { $_.M -ceq 'new' -and $_.Call -match '-c\.(init-new|repin\.[0-9]+)$' -and -not $_.Replay })
  Ok ($ini.Count -ge 1) "a pinning call reached new: $(@(RecCalls | ForEach-Object { $_.M + ' ' + $_.Call }) -join ', ')"
  foreach ($c in $ini) { Eq $c.Flags['sha'] $B "$($c.Call) on new carries the sha of the manifest it ships, not A" }
  $ref = @(LogNow -All | Where-Object { $_ -match ' (manifest-sha|sha)$' }); Eq $ref.Count 0 "no refusal: $ref"
  $s = Get-St; Eq $s.phase 'copied' 'phase'; Eq $W.new.Sha $s.manifest_sha 'new pins manifest_sha'; Ok (-not [string]$s.manifest_sha_prev) "manifest_sha_prev cleared by the init on dst [$($s.manifest_sha_prev)]"
}
T 'L.repin-flag-is-the-manifest-sha: the fake gate pins the --sha flag of init / init --repin and refuses (65 bad-request why=manifest-sha, nothing pinned) a flag that is not the sha256 of the stdin manifest (S4)' {
  Fx-Copied; $A = (Get-St).manifest_sha; $S = Read-MoveState
  $mk = { param($sha, $call) @('init', (Id), '--repin', '--dir', 'fwd', '--attempt', '1', '--sha', $sha, '--call', $call, '--budget', '10', '--serving', 'old', '--mark', 'null', '--dst-started', '0', '--phase', 'copied') }
  $in = '{"manifest":' + (Get-Content -LiteralPath (Join-Path (MoveDir) 'manifest.json') -Raw).Trim() + '}'
  $bad = 'e' * 64; $r = Invoke-MoveGate (Get-MoveMachine $S 'new') (& $mk $bad 'fwd-1-c.repin.7') $in 60 -Quiet
  Eq $r.Code 65 "an unknown sha is refused ($($r.Lines -join ' '))"; Ok (($r.Lines -join ' ') -match 'why=manifest-sha') "why=manifest-sha: $($r.Lines -join ' ')"; Eq $W.new.Sha $A 'nothing pinned'
  Ok (-not $W.new.Rec.ContainsKey('fwd-1-c.repin.7')) 'the refused call left no record'
  # the sha of ANOTHER known manifest (B) with the stdin manifest A is refused too; the flag A with the manifest A is accepted and pinned
  $W.Mf.holds[0].n_restarts = 7; [void](Get-ManifestLine $null); $B = $W.LastSha; Ok ($B -cne $A) 'fixture: a second manifest'
  $r = Invoke-MoveGate (Get-MoveMachine $S 'new') (& $mk $B 'fwd-1-c.repin.8') $in 60 -Quiet
  Eq $r.Code 65 "the flag B with the manifest A ($($r.Lines -join ' '))"; Ok (($r.Lines -join ' ') -match 'why=manifest-sha') 'why=manifest-sha (B with A)'; Eq $W.new.Sha $A 'nothing pinned'
  $r = Invoke-MoveGate (Get-MoveMachine $S 'new') (& $mk $A 'fwd-1-c.repin.9') $in 60 -Quiet
  Eq $r.Code 0 "the flag A with the manifest A ($($r.Lines -join ' '))"; Eq $W.new.Sha $A 'pinned the flag'
}
T 'L.rebuild-sha-prev: state.json lost inside the x.check .. x.repin-on-dst window (old pins B, new still pins A): `status --rebuild` reads each machine''s own pin (`MOVE manifest sha=` of rebuild read), sets manifest_sha = the src machine''s (B) and manifest_sha_prev = the dst machine''s (A); outside the window (both pin the same sha) manifest_sha_prev stays empty; the resumed cutover then goes through with no what=sha (rework R16 L2)' {
  Fx-Copied; $A = (Get-St).manifest_sha
  Add-Fault -M new -Key '^fwd-1-x\.repin$' -Mode never; Ans 'có'; $r1 = Run-Move @('cutover'); Ok ($r1.Code -ne 0) "the laptop died ($($r1.Text))"
  $B = $W.LastSha; Ok ($B -cne $A) 'fixture: x.check re-pinned old'; Eq $W.old.Sha $B 'old pins B'; Eq $W.new.Sha $A 'new pins A'
  [IO.File]::Delete((StatePath)); foreach ($n in 'old', 'new') { $W[$n].MoveId.old_addr = $OldAddr; $W[$n].MoveId.new_addr = $NewAddr }
  $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild ($($rr.Text))"
  $s = Get-St; Eq $s.manifest_sha $B 'manifest_sha = the src machine''s pin'; Eq $s.manifest_sha_prev $A 'manifest_sha_prev = the dst machine''s pin'; Eq $s.mark 'cutting' 'mark'
  $r = Run-Move @('cutover'); Eq $r.Code 0 "resume ($($r.Text))"; Eq (Get-St).phase 'cut' 'phase'
  Eq (@(LogNow -All | Where-Object { $_ -match ' (manifest-sha|sha)$' })).Count 0 "no refusal: $(@(LogNow -All | Where-Object { $_ -match ' (manifest-sha|sha)$' }))"
  $s = Get-St; Eq $W.new.Sha $s.manifest_sha 'new pins manifest_sha'; Ok (-not [string]$s.manifest_sha_prev) 'manifest_sha_prev cleared'
  # outside the window: both machines pin the same sha
  Reset-World; Fx-Cut; $prep = { [IO.File]::Delete((StatePath)); foreach ($n in 'old', 'new') { if ($W[$n].MoveId) { $W[$n].MoveId.old_addr = $OldAddr; $W[$n].MoveId.new_addr = $NewAddr } } }
  & $prep; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild at cut ($($rr.Text))"; $s = Get-St; Eq $s.manifest_sha $W.old.Sha 'manifest_sha'; Ok (-not [string]$s.manifest_sha_prev) "no manifest_sha_prev outside the window [$($s.manifest_sha_prev)]"
  # a manual back (src = new, dst = old): the laptop dies after the back's x.check, before x.repin on old; the rebuild reads new's pin (C) as manifest_sha and old's (B) as manifest_sha_prev
  Reset-World; Fx-Cut; $B0 = $W.old.Sha
  Add-Fault -M old -Key '^back-2-x\.repin$' -Mode never; Ans 'YES'; $r1 = Run-Move @('back'); Ok ($r1.Code -ne 0) "the laptop died in the back ($($r1.Text))"
  $C = $W.LastSha; Ok ($C -cne $B0) 'fixture: the back''s x.check re-pinned new'; Eq $W.new.Sha $C 'new pins C'; Eq $W.old.Sha $B0 'old still pins B'
  & $prep; $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild in the back ($($rr.Text))"
  $s = Get-St; Eq $s.dir 'back' 'dir'; Eq $s.manifest_sha $C 'back: manifest_sha = the src machine''s (new) pin'; Eq $s.manifest_sha_prev $B0 'back: manifest_sha_prev = the dst machine''s (old) pin'
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "resume of the back ($($r.Text))"; Eq (ShaRefusals).Count 0 "back: no what=sha refusal: $(ShaRefusals)"
  $s = Get-St; Eq $W.old.Sha $s.manifest_sha 'back: old pins manifest_sha'; Ok (-not [string]$s.manifest_sha_prev) 'back: manifest_sha_prev cleared'
}
# the server stores manifest.json as jsontool wrote it (the text + a final LF) next to a sha256 of the text without it; `rebuild read` gzips the stored bytes. The laptop's rebuild must accept both that form and a
# stored form with no LF (exact bytes), so the pins of both machines are read and manifest_sha_prev is recovered (R16 round 4, Astra P2)
foreach ($lf in $true, $false) {
  T "L.rebuild-manifest-forms: stored manifest $(if ($lf) { 'with' } else { 'without' }) a final LF: the rebuild in the x.check .. x.repin-on-dst window reads both pins (manifest_sha = old's B, manifest_sha_prev = new's A); a failed x.repin on new in the resume ends in the plain rollback whose r.stop-dst on new carries A (no what=sha); after both repins the rebuild still reads the pin" {
    $W.StoredLf = $lf; Fx-Copied; $A = (Get-St).manifest_sha
    Add-Fault -M new -Key '^fwd-1-x\.repin$' -Mode never; Ans 'có'; $r1 = Run-Move @('cutover'); Ok ($r1.Code -ne 0) "the laptop died ($($r1.Text))"
    $B = $W.LastSha; Ok ($B -cne $A) 'fixture: x.check re-pinned old'; Eq $W.new.Sha $A 'new pins A (x.repin never reached it)'
    [IO.File]::Delete((StatePath)); foreach ($n in 'old', 'new') { $W[$n].MoveId.old_addr = $OldAddr; $W[$n].MoveId.new_addr = $NewAddr }
    $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild ($($rr.Text))"
    $s = Get-St; Eq $s.manifest_sha $B 'manifest_sha = the src pin'; Eq $s.manifest_sha_prev $A 'manifest_sha_prev = the dst pin (the LF form is validated)'
    Add-Fault -M new -Key '^fwd-1-x\.repin$' -Rc 1; $r = Run-Move @('cutover'); Eq $r.Code 10 "resume, x.repin on new fails: plain rollback ($($r.Text))"
    Eq (@(CallShas 'new' '^fwd-1-r\.stop-dst$')[0]) $A 'r.stop-dst on new carries A'; Eq (ShaRefusals).Count 0 "no what=sha refusal: $(ShaRefusals)"
    # both machines pinned B (a second cutover to the end), the state lost again: the rebuild reads the pin of each
    Reset-World; $W.StoredLf = $lf; Fx-Cut; $B2 = $W.old.Sha; Eq $W.new.Sha $B2 'both machines pin the same sha after the cutover'
    [IO.File]::Delete((StatePath)); foreach ($n in 'old', 'new') { $W[$n].MoveId.old_addr = $OldAddr; $W[$n].MoveId.new_addr = $NewAddr }
    $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild at cut ($($rr.Text))"; $s = Get-St; Eq $s.manifest_sha $B2 'manifest_sha = the pin'; Ok (-not [string]$s.manifest_sha_prev) 'no manifest_sha_prev'
  }
}
# P1 chain (review-rest-r3): after a fwd cutover the laptop state keeps dst_started=true; a back's write-ahead must clear it for the back (its dst has not started), so b.init-old is sent with --dst-started 0 and a back
# rebuilt between x.freeze and x.repin resumes at step 2 (x.check ... x.final), never at step 8 (old started while new still runs its holds)
T 'L.back-rebuild-resume-step: b.init-new / b.init-old of a manual back carry --dst-started 0; the laptop dies after the back''s x.freeze, state.json lost, `status --rebuild` then `back`: dst_started is false, the resume runs x.check, x.repin, x.stop-src, x.stop-dst and x.final on new BEFORE old''s x.start, and ends back-done' {
  Fx-Cut; Eq (Get-St).dst_started $true 'fixture: the fwd cutover leaves dst_started=true in the laptop state'
  Add-Fault -M new -Key '^back-2-x\.freeze$' -Rc 0 -Mode kill; Ans 'YES'; $r1 = Run-Move @('back'); Ok ($r1.Code -ne 0) "the laptop died after x.freeze ($($r1.Text))"
  foreach ($c in 'b.init-new', 'b.init-old') { $x = @(RecCalls -All | Where-Object { $_.Call -ceq "back-2-$c" })[0]; Ok ($null -ne $x) "$c was sent"; Eq $x.Flags['dst-started'] '0' "$c carries --dst-started 0" }
  Eq $W.old.MoveId.dst_started '0' 'old''s move-id: the back''s dst has not started'; Eq $W.new.MoveId.dst_started '0' 'new''s move-id'
  [IO.File]::Delete((StatePath)); foreach ($n in 'old', 'new') { $W[$n].MoveId.old_addr = $OldAddr; $W[$n].MoveId.new_addr = $NewAddr }
  $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild ($($rr.Text))"
  $s = Get-St; Eq $s.dir 'back' 'dir'; Eq $s.mark 'cutting' 'mark'; Eq $s.dst_started $false 'rebuilt dst_started = false'
  $script:FinalFirst = $null; $W.Hooks['x.start'] = { param($m, $e) if ($m.Name -ceq 'old') { $script:FinalFirst = ($W.new.Rec.ContainsKey('back-2-x.final') -and [int]$W.new.Rec['back-2-x.final'].Rc -eq 0 -and [int]$W.new.Active -eq 0) } }
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "resume ($($r.Text))"
  Eq $script:FinalFirst $true 'old''s x.start came after new''s x.final, new stopped'
  foreach ($c in 'x.check', 'x.repin', 'x.stop-src', 'x.final') { Ok ((SentAny "^back-2-$([regex]::Escape($c))$") -ge 1) "$c ran in the resume" }
  Eq (ShaRefusals).Count 0 "no what=sha refusal: $(ShaRefusals)"; Eq (Get-St).phase 'back-done' 'phase'
}
T 'L.repin-dst-fail-rollback: x.check rc 0 (old pinned B), x.repin on new fails (new still holds A): the plain rollback sends r.stop-dst to new with A and old''s r.* with B, so no what=sha; ends exit 10, rolled-back, old serving (ruling 06/11 (33), D1b)' {
  Fx-Copied; $A = (Get-St).manifest_sha
  Add-Fault -M new -Key '^fwd-1-x\.repin$' -Rc 1; Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 10 "plain rollback ($($r.Text))"
  $B = $W.LastSha; Ok ($B -cne $A) 'fixture: x.check re-pinned old'; Eq $W.old.Sha $B 'old holds B'; Eq $W.new.Sha $A 'new still holds A'
  Eq (Sent 'old' '^fwd-1-x\.repin$') 0 'x.repin on src is never sent after dst failed'
  $s = Get-St; Eq $s.phase 'rolled-back' 'phase'; Eq $s.serving 'old' 'serving'
  Eq (Sent 'new' '^fwd-1-r\.stop-dst$') 1 'r.stop-dst on new'; Eq (@(CallShas 'new' '^fwd-1-r\.stop-dst$')[0]) $A 'r.stop-dst on new carries A'
  foreach ($st in 'r.start-src', 'r.unfreeze-src', 'r.health-src') { Eq (@(CallShas 'old' "^fwd-1-$([regex]::Escape($st))$")[0]) $B "$st on old carries B" }
  Eq (ShaRefusals).Count 0 "no what=sha refusal: $(ShaRefusals)"
  Eq $W.old.Active $Holds 'old serves again'; Eq $W.old.Frozen $false 'old unfrozen'; Eq $W.new.Active 0 'new stays stopped'
  # the move is not wedged: the next copy and cutover go through (nothing refused what=sha, new ends pinned to the manifest of the second x.check)
  $r = Run-Move @('copy'); Eq $r.Code 0 "copy after the rollback ($($r.Text))"; Eq (Get-St).phase 'copied' 'copied again'
  Ans 'có'; $r = Run-Move @('cutover'); Eq $r.Code 0 "second cutover ($($r.Text))"; Eq (Get-St).phase 'cut' 'cut'
  Eq (ShaRefusals).Count 0 "second try: no what=sha refusal: $(ShaRefusals)"; $s = Get-St; Eq $W.old.Sha $s.manifest_sha 'old pinned to the saved sha'; Eq $W.new.Sha $s.manifest_sha 'new pinned to the saved sha'; Ok (-not [string]$s.manifest_sha_prev) 'manifest_sha_prev cleared'
}
# ============================== DECISION-r2 (B41): the Q-back project list against the back's x.check ==============================
# Q-back shows the `INV warn back-new-only kind=project name=<n>` names of 0c; the laptop stores them (answers{'back-new-projects'}). The back's x.check lists the names again
# (the registry files of new, pinned by the back); a name it lists that Q-back did not show stops the back after the re-pin is saved, as E-R19 (new restarted and unfrozen,
# phase=cut serving=new mark=null, exit 1, no x.repin). A name Q-back showed and x.check no longer lists never stops; no stored list (rebuilt state) = no compare.
function Back-Projects([string[]]$Qback, [string[]]$Check) {
  Fx-Cut; $W.CheckOnlyOut = @('INV ok') + @($Qback | ForEach-Object { "INV warn back-new-only kind=project name=$_" }); $W.CheckProjects = @($Check)
}
$DriftLine = 'Máy mới có dự án đăng ký sau khi hỏi Q-back: {0}; chạy lại  fcode move back  để xem lại danh sách.'
T 'L.back-new-projects-drift: Q-back showed app9, the back''s x.check lists app9 and app10: the laptop saves the re-pin, prints the drift line naming app10, then ends as E-R19 (r.start-src + r.unfreeze-src on new carrying the re-pin sha, phase=cut serving=new mark=null, exit 1), no x.repin sent; `back` again shows both names at Q-back and goes through (DECISION-r2 T10.2)' {
  Back-Projects @('app9') @('app9', 'app10')
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code 1 "the back stops ($($r.Text))"
  $d = $DriftLine -f 'app10'; HasText $d; HasText 'Chuyển ngược không xong; máy mới vẫn phục vụ như trước.'
  Ok ($r.Text.IndexOf($d) -lt $r.Text.IndexOf('Chuyển ngược không xong')) 'the drift line comes before the E-R19 line'
  Eq (SentAny '-x\.repin$') 0 'no x.repin sent'; $C = $W.LastSha
  $s = Get-St; Eq $s.manifest_sha $C 'the re-pin of x.check is saved'; Eq ([string]$s.answers.'back-new-projects') 'app9' 'the stored Q-back list'
  Eq $s.phase 'cut' 'phase'; Eq $s.serving 'new' 'serving'; Ok ($null -eq $s.mark) 'mark'; Eq $s.dir 'back' 'dir'
  foreach ($st in 'r.start-src', 'r.unfreeze-src') { Eq (Sent 'new' "^back-2-$([regex]::Escape($st))$") 1 "$st on new"; Eq (@(CallShas 'new' "^back-2-$([regex]::Escape($st))$")[0]) $C "$st carries the x.check re-pin sha" }
  Eq (ShaRefusals).Count 0 "no what=sha refusal: $(ShaRefusals)"; Eq $W.new.Frozen $false 'new unfrozen'; Eq $W.new.Active $Holds 'new serves'
  # `back` again: Q-back lists both names (0c sees app10 now), the back goes through
  $W.CheckOnlyOut = @('INV ok', 'INV warn back-new-only kind=project name=app9', 'INV warn back-new-only kind=project name=app10')
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "back again ($($r.Text))"; Eq (Get-St).phase 'back-done' 'phase'; Eq ([string](Get-St).answers.'back-new-projects') 'app10 app9' 'the stored list is the new one (sorted)'
  Eq (Sent 'old' '^back-3-x\.repin$') 1 'x.repin on old in the second back'
}
T 'L.back-new-projects-retry-precheck: a drift stop leaves the machines at back/N (b.init-* carried N); `back` again sends its 0c `plan <id> --check-only` with --dir back --attempt N (the server exempts back/N+1 only against a stored fwd), reaches Q-back (both names listed) with no what=attempt refusal, then b.init-* carry N+1 and the back ends back-done' {
  Back-Projects @('app9') @('app9', 'app10')
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code 1 "the first back stops on the drift ($($r.Text))"
  $p1 = @(Calls | Where-Object { $_.Step -ceq 'plan:check-only' }); Ok ($p1.Count -ge 1) 'the first 0c was sent'; Eq $p1[0].Flags['attempt'] '2' 'the first 0c: attempt = stored fwd attempt + 1'; Eq $p1[0].Flags['dir'] 'back' 'the first 0c: dir back'
  Eq $W.new.MoveId.dir 'back' 'new holds back'; Eq "$($W.new.MoveId.attempt)" '2' 'new holds attempt 2'
  $W.CheckOnlyOut = @('INV ok', 'INV warn back-new-only kind=project name=app9', 'INV warn back-new-only kind=project name=app10'); $n0 = $W.Prompts.Count
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "back again ($($r.Text))"
  $p2 = @(Calls | Where-Object { $_.Step -ceq 'plan:check-only' }); Ok ($p2.Count -ge 1) 'the 0c was sent again'; Eq $p2[0].Flags['dir'] 'back' 'dir'; Eq $p2[0].Flags['attempt'] '2' 'the 0c carries the stored back attempt N, not N+1'
  Eq @(LogNow -All | Where-Object { $_ -match 'plan:check-only refused' }).Count 0 "no precheck refusal: $(@(LogNow -All | Where-Object { $_ -match 'plan:check-only refused' }))"
  $q = @(Lines -Last | Where-Object { $_ -match '\AChuyển ngược về máy cũ' }); Eq $q.Count 1 'Q-back was asked'; Ok ($q[0] -match 'name=app9' -and $q[0] -match 'name=app10') "Q-back lists both names: $($q[0])"
  foreach ($c in 'b.init-new', 'b.init-old') { $x = @(RecCalls | Where-Object { $_.Call -ceq "back-3-$c" }); Eq $x.Count 1 "$c of attempt 3 sent" }
  Eq (Get-St).phase 'back-done' 'phase'; Eq (Get-St).attempt 3 'attempt'
}
T 'L.precheck-identity: the fake gate compares the 0c `plan <id> --check-only` like the server: back/stored+1 is exempt only against a stored fwd; every other dir/attempt, another id and another sha are refused 65 (what=dir, what=attempt, other-move, what=sha), and nothing is written' {
  Fx-Cut; $S = Read-MoveState; $id = Id; $sha = $W.new.Sha
  $go = { param($dir, $att, $mid, $sh) Invoke-MoveGate (Get-MoveMachine $S 'new') @('plan', $mid, '--dir', $dir, '--attempt', "$att", '--sha', $sh, '--serving', 'new', '--check-only') '' 60 -Quiet }
  $chk = { param($r, $code, $why, $what) Eq $r.Code $code "$what ($($r.Lines -join ' '))"; if ($why) { Ok (($r.Lines -join ' ') -match [regex]::Escape($why)) "$what : [$why] in $($r.Lines -join ' ')" } }
  # stored fwd/1
  & $chk (& $go 'back' 2 $id $sha) 0 $null 'back/2 against fwd/1 (the exemption)'
  & $chk (& $go 'back' 3 $id $sha) 65 'what=dir' 'back/3 against fwd/1'
  & $chk (& $go 'back' 1 $id $sha) 65 'what=dir' 'back/1 against fwd/1 (dir differs)'
  & $chk (& $go 'fwd' 2 $id $sha) 65 'what=attempt' 'fwd/2 against fwd/1'
  & $chk (& $go 'fwd' 1 $id $sha) 0 $null 'fwd/1 against fwd/1'
  & $chk (& $go 'back' 2 'mv-20260101000000-abcdef' $sha) 65 'other-move' 'another move-id'
  & $chk (& $go 'back' 2 $id ('e' * 64)) 65 'what=sha' 'another sha'
  # stored back/2 (after a drift stop): the exemption is gone
  $W.new.MoveId.dir = 'back'; $W.new.MoveId.attempt = 2
  & $chk (& $go 'back' 3 $id $sha) 65 'what=attempt' 'back/3 against back/2 (no exemption against a stored back)'
  & $chk (& $go 'back' 2 $id $sha) 0 $null 'back/2 against back/2'
  & $chk (& $go 'fwd' 2 $id $sha) 65 'what=dir' 'fwd/2 against back/2'
  Eq $W.new.MoveId.dir 'back' 'nothing written'; Eq "$($W.new.MoveId.attempt)" '2' 'nothing written (attempt)'
  # a machine with an empty pin refuses every sha (the server reads cur=""), a machine with no move-id answers no-move (mode call)
  $W.new.Sha = ''; & $chk (& $go 'back' 2 $id $sha) 65 'what=sha' 'a move-id with no pin'
  $W.new.MoveId = $null; & $chk (& $go 'back' 2 $id $sha) 65 'no-move' 'a machine with no move-id'
}
T 'L.back-new-projects-same: Q-back and x.check list the same names: no stop, x.repin and on, back-done; answers{back-new-projects} holds the sorted names' {
  Back-Projects @('app9', 'app10') @('app10', 'app9')
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "back ($($r.Text))";
  Ok (-not ($r.Text -match 'Máy mới có dự án đăng ký sau khi hỏi Q-back')) 'no drift line'; Eq (Sent 'old' '^back-2-x\.repin$') 1 'x.repin on old'
  Eq ([string](Get-St).answers.'back-new-projects') 'app10 app9' 'stored list'
}
T 'L.back-new-projects-none: Q-back showed no project and x.check lists none: the stored list is empty and nothing stops' {
  Back-Projects @() @()
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "back ($($r.Text))"; Eq @((Get-St).answers.'back-new-projects').Count 0 'empty stored list'
}
T 'L.back-new-projects-removed: Q-back showed app9 and app8, x.check lists app9 only: nothing new, no stop (subset, not equality), x.repin sent' {
  Back-Projects @('app9', 'app8') @('app9')
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "back ($($r.Text))"; Ok (-not ($r.Text -match 'Máy mới có dự án đăng ký sau khi hỏi Q-back')) 'no drift line'; Eq (Sent 'old' '^back-2-x\.repin$') 1 'x.repin on old'
}
T 'L.back-new-projects-resume: the laptop died after the back''s x.check rc 0 (the same names as Q-back): `back` replays x.check, the stored list leaves nothing new, no stop, the back goes through' {
  Back-Projects @('app9') @('app9')
  Add-Fault -M new -Key '^back-2-x\.check$' -Rc 0 -Mode kill; Ans 'YES'; $r1 = Run-Move @('back'); Ok ($r1.Code -ne 0) "the laptop died ($($r1.Text))"
  Eq ([string](Get-St).answers.'back-new-projects') 'app9' 'the list survived in the state'
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "resume ($($r.Text))"; Eq (Sent 'new' '^back-2-x\.check$') 0 'x.check replayed, not run'; Eq (SentAny '^back-2-x\.check$') 1 'x.check sent again'
  Ok (-not ($r.Text -match 'Máy mới có dự án đăng ký sau khi hỏi Q-back')) 'no drift line'; Eq (ShaRefusals).Count 0 "no what=sha refusal: $(ShaRefusals)"
}
T 'L.back-new-projects-rebuilt: a rebuilt manual back carries an EMPTY Q-back list (DECISION-r3 O3): the resumed back''s x.check lists a name, which then stops the back as E-R19 (no x.repin), and `back` again shows the name' {
  Back-Projects @('app9') @('app9', 'app10')
  Add-Fault -M new -Key '^back-2-x\.check$' -Rc 0 -Mode kill; Ans 'YES'; $r1 = Run-Move @('back'); Ok ($r1.Code -ne 0) "the laptop died ($($r1.Text))"
  [IO.File]::Delete((StatePath)); foreach ($n in 'old', 'new') { $W[$n].MoveId.old_addr = $OldAddr; $W[$n].MoveId.new_addr = $NewAddr }
  $rr = Run-Move @('status', '--rebuild', $OldAlias, $NewAlias); Eq $rr.Code 0 "rebuild ($($rr.Text))"; Eq @((Get-St).answers.'back-new-projects').Count 0 'an empty stored list after the rebuild'; Ok ($null -ne (Get-St).answers.PSObject.Properties['back-new-projects']) 'the key exists'
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code 1 "the resume stops as E-R19 ($($r.Text))"; HasText 'Máy mới có dự án đăng ký sau khi hỏi Q-back'; HasText 'app10'; Eq (SentAny '-x\.repin$') 0 'no x.repin'
  # a manual-back state WITHOUT the key (written by an older fcode) keeps the old behaviour: no compare, no stop as E-R19 (the key guard of Invoke-MoveBack's drift test)
  Reset-World; Back-Projects @('app9') @('app9', 'app10'); Add-Fault -M new -Key '^back-2-x\.check$' -Rc 0 -Mode kill; Ans 'YES'; $r1 = Run-Move @('back'); Ok ($r1.Code -ne 0) "[no key] the laptop died ($($r1.Text))"
  $j = Get-St; [void]$j.answers.PSObject.Properties.Remove('back-new-projects'); [IO.File]::WriteAllText((StatePath), (ConvertTo-Json -InputObject $j -Depth 20), $utf8)
  Ans 'YES'; $r = Run-Move @('back'); NoText 'Máy mới có dự án đăng ký sau khi hỏi Q-back'; Ok ((SentAny '-x\.repin$') -ge 1) "[no key] no stop: the back goes on to x.repin ($($r.Code): $($r.Text))"
}
# O3: a rebuilt manual back carries an empty Q-back list, so a back-new-only project that x.check lists stops the back as E-R19 (the same names as at the original Q-back are indistinguishable from new ones)
T 'L.rebuild-back-new-projects: a manual back rebuilt at mark cutting before x.check, one kind=project name: the re-run x.check ends E-R19 (new restarted and unfrozen, cut, exit 1), no x.repin, no x.adopt; `back` again shows the name at Q-back and reaches back-done; the same when rebuilt after x.check (replayed); rebuilt after x.final: no compare' {
  Back-Projects @('app9') @('app9'); Add-Fault -M new -Key '^back-2-x\.freeze$' -Rc 0 -Mode kill; Ans 'YES'; [void](Run-Move @('back')); Lose-State; [void](Run-Move @('status', '--rebuild', $OldAlias, $NewAlias)); Eq @((Get-St).answers.'back-new-projects').Count 0 'empty list'
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code 1 "stops as E-R19 ($($r.Text))"; HasText 'app9'; Eq (SentAny '-x\.(repin|adopt)$') 0 'no x.repin, no x.adopt'; $s = Get-St; Eq $s.phase 'cut' 'phase'; Eq $s.serving 'new' 'serving'; Eq $W.new.Frozen $false 'new unfrozen'
  $r = Run-Move @('cutover'); Eq $r.Code 0 "the chores of the rebuilt cut run ($($r.Text))"
  $W.CheckOnlyOut = @('INV ok', 'INV warn back-new-only kind=project name=app9'); Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "back again ($($r.Text))"; Eq (Get-St).phase 'back-done' 'phase'; Eq ([string](Get-St).answers.'back-new-projects') 'app9' 'the list Q-back showed'
  Reset-World; Back-Projects @('app9') @('app9'); Add-Fault -M new -Key '^back-2-x\.check$' -Rc 0 -Mode kill; Ans 'YES'; [void](Run-Move @('back')); Lose-State; [void](Run-Move @('status', '--rebuild', $OldAlias, $NewAlias))
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code 1 "after x.check: stops the same way ($($r.Text))"; Eq (SentAny '-x\.(repin|adopt)$') 0 'no x.repin, no x.adopt'; Eq (Sent 'new' '^back-2-x\.check$') 0 'x.check was replayed'
  Reset-World; Back-Projects @('app9') @('app9'); Add-Fault -M new -Key '^back-2-x\.final$' -Rc 0 -Mode kill; Ans 'YES'; [void](Run-Move @('back')); Lose-State; [void](Run-Move @('status', '--rebuild', $OldAlias, $NewAlias))
  Ans 'YES'; $r = Run-Move @('back'); Eq $r.Code $BackDoneExit "after x.final: no compare ($($r.Text))"; Ok (-not ($r.Text -match 'Máy mới có dự án đăng ký sau khi hỏi Q-back')) 'no drift line'
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
T 'L.resume-table: two chore-0 repairs in one attempt — the first repair''s x.unfreeze.1 fails (x.enable.1 done), the second repair uses x.enable.2 / x.unfreeze.2 and really runs (a chore 0 repairs the abandon''s unfreeze only; a failed return is never repaired by it: ADDENDUM)' {
  Fx-Copied; Add-Fault -M old -Key '-x\.freeze$' -Rc 75 -Out @('MOVE wait drain lock=/var/lock/fcode-deploy/task.lock waited=900'); Add-Fault -M old -Key '-r\.unfreeze-src$' -Rc 1
  Ans 'có', 'dừng'; [void](Run-Move @('cutover'))
  Add-Fault -M old -Key '^fwd-2-x\.unfreeze\.1$' -Rc 1; Ans 'có'; $r1 = Run-Move @('abort'); Ok ($r1.Code -ne 0) "the first repair fails ($($r1.Text))"; Eq (Sent 'old' '^fwd-2-x\.enable\.1$') 1 'first repair: x.enable.1'; Eq (Sent 'old' '^fwd-2-x\.unfreeze\.1$') 1 'first repair: x.unfreeze.1'; Eq $W.old.Frozen $true 'still frozen'
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
  $r = Run-Move @('cutover'); Eq $r.Code 70 "exit ($($r.Text))"; Eq (SentAny '-r\.start-src$') 0 'old not started'; CarryEnd $false 'x.final down'
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
T 'L.carry-after-final-70: a carry-back failing after x.final shows both MOVE state lines and, new having answered status, ends with the resume line (exit 70)' {
  Start-Carry; Add-Fault -M new -Key '^back-2-x\.final$' -Rc 1; Ans 'có'
  $r = Run-Move @('cutover'); Eq $r.Code 70 "exit ($($r.Text))"
  Eq @(Lines -Last | Where-Object { $_ -match '^\s*MOVE state ' }).Count 2 "both MOVE state lines: $(Lines -Last)"
  CarryEnd $true 'MOVE state lines'; Eq (SentAny '-r\.start-src$') 0 'old not started'
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
  Start-Carry; Add-Fault -M new -Key '^back-2-b\.init-new$' -Mode down; Ans 'có'; $r1 = Run-Move @('cutover'); Eq $r1.Code 1 "r1 exit ($($r1.Text))"; EndsBareRerun   # R10-INT-31: the lost b.init-new ends the carry-back with the bare sentence last
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
T 'L.resume-table: machines disagree on (dir, attempt), abort with new_lost set and ANOTHER (closed) move-id on new: no fence is sent to new (reading T10-G12; a machine with no move-id is re-init-ed instead, T14 W1-T10-G9)' {
  Fx-Disagree; [void](Patch-St @{ new_lost = $true }); $script:W.new.MoveId = @{ id = 'mv-20260101000000-abcdef'; role = 'new'; dir = 'fwd'; attempt = 1; state = 'finished'; mark = $null; phase = 'copied'; serving = 'old'; dst_started = '0'; old_addr = $OldAddr; new_addr = $NewAddr }
  Ans 'có'; $r = Run-Move @('abort'); Eq $r.Code 0 "abort ($($r.Text))"
  Eq (@(LogNow | Where-Object { $_ -match "^new \S+-$([regex]::Escape($FenceStep))" }).Count) 0 "no fence on a new that holds another move-id: $(LogNow)"
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
function Fx-StartBudget([int[]]$ConnListen = @(), [int]$Other = 0, [string]$Extra = '') {   # $ConnListen = |listen[]| of each unit connector hold of the start set; $Other = |listen[]| of every other hold
  $mk = { param($n) @(for ($i = 1; $i -le $n; $i++) { [ordered]@{ proto = 'tcp'; port = 9000 + $i } }) }
  $h = @($W.Mf.holds); foreach ($x in $h) { $x['listen'] = @(& $mk $Other) }
  $ids = @($W.Mf.hold_sets.start); $conn = @()
  for ($i = 0; $i -lt $ConnListen.Count; $i++) { $c = New-Hold "cloudflared$($i + 1).service" 30; $c['listen'] = @(& $mk $ConnListen[$i]); $h += $c; $ids += $c.id; $conn += [ordered]@{ id = $c.id; kind = 'unit' } }
  if ($Extra -ceq 'container') { $c = New-Hold 'container:tunnel' 30 'container'; $c['listen'] = @(& $mk 3); $h += $c; $ids += $c.id; $conn += [ordered]@{ id = $c.id; kind = 'container' } }
  if ($Extra -ceq 'unit-off-start') { $c = New-Hold 'cf-off.service' 30; $c['listen'] = @(& $mk 3); $h += $c; $conn += [ordered]@{ id = $c.id; kind = 'unit' } }   # a unit connector the start set does not hold
  Set-Holds $h $ids @($W.Mf.hold_sets.stop); $W.Mf.connectors = @($conn)
}
T 'L.budget-start: x.start, x.enable.N and r.start-src --budget = Σ start_budget_s of hold_sets.start + 60, + 60 when the start set holds a unit connector (connectors[] kind unit, id in hold_sets.start) + 20 per listener after the first, the listeners of a connector = max(1, |its hold''s listen[]|); boundary 0 / 1 / 3 listeners (ruling 06/11 (30), B36): one connector with 3 listeners +100, two connectors with one each +80; a container connector, a unit connector outside hold_sets.start and the listen[] of other holds add nothing' {
  $cases = @(
    @{ C = @(); O = 0; X = ''; T = 0 }, @{ C = @(); O = 3; X = ''; T = 0 },                                   # no unit connector: no term, whatever the listeners
    @{ C = @(0); O = 0; X = ''; T = 60 }, @{ C = @(1); O = 0; X = ''; T = 60 }, @{ C = @(0); O = 3; X = ''; T = 60 },   # one listener (an unpinned connector has its metrics listener)
    @{ C = @(3); O = 0; X = ''; T = 100 },                                                                   # one connector, three listeners
    @{ C = @(0, 0); O = 0; X = ''; T = 80 }, @{ C = @(1, 1); O = 0; X = ''; T = 80 },                          # two connectors, one listener each
    @{ C = @(3, 1); O = 0; X = ''; T = 120 }, @{ C = @(0, 0, 0); O = 0; X = ''; T = 100 }, @{ C = @(1, 1, 1); O = 0; X = ''; T = 100 },
    @{ C = @(); O = 0; X = 'container'; T = 0 }, @{ C = @(1); O = 0; X = 'container'; T = 60 },
    @{ C = @(); O = 0; X = 'unit-off-start'; T = 0 }, @{ C = @(3); O = 0; X = 'unit-off-start'; T = 100 })
  foreach ($c in $cases) {
    $term = $c.T; $tag = "[connector listen[] $(@($c.C) -join ','), others $($c.O), extra '$($c.X)']"
    $sum = (3 + @($c.C).Count + $(if ($c.X -ceq 'container') { 1 } else { 0 })) * 60   # every hold of hold_sets.start has start_budget_s 60 (a unit connector too)
    Reset-World; Fx-StartBudget @($c.C) $c.O $c.X; Fx-Copied; [void](Do-Cutover -1)
    Eq (Budget-Of 'new' 'fwd-1-x.start') ($sum + 60 + $term) "$tag x.start = Σ + 60 + $term"; Eq (Budget-Of 'new' 'fwd-1-x.enable.1') ($sum + 60 + $term) "$tag x.enable.1"
    Reset-World; Fx-StartBudget @($c.C) $c.O $c.X; Fx-Copied; Add-Fault -M new -Key '^fwd-1-x\.final$' -Rc 1; [void](Do-Cutover 10)
    Eq (Budget-Of 'old' 'fwd-1-r.start-src') ($sum + 60 + $term) "$tag r.start-src"
  }
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
