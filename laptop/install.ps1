# FCode: install the `fcode` command on a Windows machine (Windows PowerShell 5.1 or PowerShell 7, no admin needed).
#
#   From a clone:  powershell -ExecutionPolicy Bypass -File .\laptop\install.ps1
#   One-liner:     irm https://raw.githubusercontent.com/brooklyn96/fcoding/main/laptop/install.ps1 | iex
#
# Safe to run again: anything already in place is left alone.
#
# ENCODING: this file is pure ASCII on purpose. A UTF-8 BOM breaks `irm | iex` (the BOM becomes part of the first
# command name) and a file without BOM is read as ANSI by Windows PowerShell 5.1. So the Vietnamese messages are
# written as \uXXXX escapes and decoded by V() when printed. To read one: [regex]::Unescape('<text>').
# Messages are format strings: use {0}, {1} for values, never put a value into the string itself.
# A thrown message of the form 'fc:<cause>|<what to do>|<detail>' is shown as a Vietnamese cause first, with the
# raw detail (often English) on a short dim second line. Any other exception gets a generic cause.
#
# Test hooks (not for users):
#   FCODE_INSTALL_SOURCE  folder or https:// URL that holds fcode.ps1 and fcode.cmd
#   FCODE_INSTALL_DRYRUN  =1: print the install and login commands instead of running them
#   FCODE_INSTALL_HIDE    comma list of tools (gh,instabox,winget) hidden from the PATH search
#   FCODE_INSTALL_ENVKEY  HKCU subkey used instead of "Environment" when editing the user PATH
#   FCODE_INSTALL_EPFAKE  fake execution policy list, e.g. CurrentUser=Restricted,LocalMachine=Undefined (nothing is set)
#   FCODE_INSTALL_EPREAL  exactly 1, and only together with EPFAKE: really run Set-ExecutionPolicy (only safe where CurrentUser is already RemoteSigned)
#
# Do not capture the output of Invoke-FcodeInstall in a variable: gh and instabox need the real console to log in.

function Invoke-FcodeInstall {
    $ErrorActionPreference = 'Continue'
    $ProgressPreference = 'SilentlyContinue'
    $rawBase = 'https://raw.githubusercontent.com/brooklyn96/fcoding/main/laptop'
    $dry = $env:FCODE_INSTALL_DRYRUN -eq '1'
    $hide = @(([string]$env:FCODE_INSTALL_HIDE) -split ',' | Where-Object { $_ })
    $envKey = if ($env:FCODE_INSTALL_ENVKEY) { $env:FCODE_INSTALL_ENVKEY } else { 'Environment' }
    $binDir = Join-Path $env:USERPROFILE '.local\bin'
    $cfgDir = Join-Path $env:USERPROFILE '.fcode'
    $cfgFile = Join-Path $cfgDir 'config.json'
    $ibDir = Join-Path $env:LOCALAPPDATA 'Programs\instabox'
    $ghZipDir = Join-Path $env:LOCALAPPDATA 'Programs\gh'
    $ghManual = 'C\u00e0i tay t\u1eeb https://cli.github.com r\u1ed3i ch\u1ea1y l\u1ea1i l\u1ec7nh c\u00e0i'
    $ibManual = 'Ki\u1ec3m tra m\u1ea1ng r\u1ed3i ch\u1ea1y l\u1ea1i l\u1ec7nh c\u00e0i, ho\u1eb7c l\u00e0m theo https://instabox.sh/docs/start'
    # An item that is not done keeps its "what to do" sentence; $null means done.
    $todo = [ordered]@{ fcode = $null; gh = $null; instabox = $null; ibLogin = $null; ghLogin = $null }
    $cmdName = 'fcode'

    function V($s) { [regex]::Unescape($s) }
    function Say($m, $a) { Write-Host ((V $m) -f $a) }
    function Step($m) { Write-Host ''; Write-Host (V $m) -ForegroundColor Cyan }
    function Get-Why($e, $cause, $action) {
        $m = [string]$e.Exception.Message
        if ($m.StartsWith('fc:')) {
            $p = $m.Substring(3) -split '\|', 3
            return @{ Cause = (V $p[0]); Action = (V $p[1]); Detail = $(if ($p.Count -gt 2) { $p[2] } else { '' }) }
        }
        return @{ Cause = (V $cause); Action = (V $action); Detail = $m }
    }
    function Show-Why($w) {
        Write-Host ((V '\u2717 {0}') -f $w.Cause) -ForegroundColor Yellow
        $d = ($w.Detail -replace '\s+', ' ').Trim()
        if ($d) { if ($d.Length -gt 160) { $d = $d.Substring(0, 160) + '...' }; Write-Host ('  ' + $d) -ForegroundColor DarkGray }
    }
    function Net($cause, $action, [scriptblock]$sb) {
        try { & $sb } catch { throw ('fc:' + $cause + '|' + $action + '|' + $_.Exception.Message) }
    }

    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { Say 'L\u1ec7nh c\u00e0i n\u00e0y ch\u1ec9 d\u00e0nh cho Windows.'; $global:FcodeInstallExit = 1; return }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}

    # ---------- PATH ----------
    function Norm($p) { [Environment]::ExpandEnvironmentVariables($p).Trim().TrimEnd('\').ToLowerInvariant() }
    function Get-UserPathRaw {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($envKey)
        if (-not $k) { return '' }
        try { return [string]$k.GetValue('Path', '', 'DoNotExpandEnvironmentNames') } finally { $k.Close() }
    }
    function Test-OnUserPath($dir) {
        foreach ($p in ((Get-UserPathRaw) -split ';')) { if ($p.Trim() -and (Norm $p) -eq (Norm $dir)) { return $true } }
        return $false
    }
    function Update-SessionPath {
        # Add to this window every folder that is in the Machine + User PATH, so no new window is needed.
        $all = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::ExpandEnvironmentVariables((Get-UserPathRaw))
        $have = @($env:Path -split ';' | Where-Object { $_ } | ForEach-Object { Norm $_ })
        $add = @()
        foreach ($p in ($all -split ';')) {
            if ($p.Trim() -and ($have -notcontains (Norm $p))) { $add += $p.Trim(); $have += (Norm $p) }
        }
        if ($add.Count) { $env:Path = $env:Path.TrimEnd(';') + ';' + ($add -join ';') }
    }
    function Add-UserPath($dir) {
        # Returns $true when it just added the folder. Writes the registry directly to keep the value kind (it may hold %VAR%).
        if (Test-OnUserPath $dir) { Update-SessionPath; return $false }
        $old = (Get-UserPathRaw).Trim().Trim(';')
        $new = if ($old) { $old + ';' + $dir } else { $dir }
        $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($envKey)
        $kind = 'ExpandString'
        try { $kind = $k.GetValueKind('Path') } catch {}
        $k.SetValue('Path', $new, $kind)
        $k.Close()
        if (-not $env:FCODE_INSTALL_ENVKEY) {
            try { # tell Windows the environment changed so new windows see it at once
                if (-not ('Fcode.Native' -as [type])) {
                    Add-Type -Namespace Fcode -Name Native -MemberDefinition '[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, UIntPtr w, string l, uint f, uint t, out UIntPtr r);'
                }
                $r = [UIntPtr]::Zero
                [void][Fcode.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$r)
            } catch {}
        }
        Update-SessionPath
        return $true
    }

    # ---------- find tools ----------
    function Find-Tool($name, $extra) {
        if ($hide -notcontains $name) { # FCODE_INSTALL_HIDE hides a tool from the PATH search only
            $c = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($c) { return $c.Source }
        }
        foreach ($p in $extra) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
        return $null
    }
    function Find-Gh { Find-Tool 'gh' @((Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'), (Join-Path $ghZipDir 'bin\gh.exe')) }
    function Test-Runs($exe) {
        # A file that is not a valid program makes the call throw, so that counts as "does not run" too.
        try { & $exe --version *> $null; return ($LASTEXITCODE -eq 0) } catch { return $false }
    }
    function Find-Ib {
        # Every candidate is tried (all PATH hits, then the install folder) and the first that runs wins, so a broken copy
        # (a download cut short, a stale shim) never hides a good one. No working copy means "missing".
        $c = @()
        if ($hide -notcontains 'instabox') { $c += @(Get-Command 'instabox' -CommandType Application -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source }) }
        $c += (Join-Path $ibDir 'instabox.exe')
        foreach ($p in $c) { if ($p -and (Test-Path -LiteralPath $p) -and (Test-Runs $p)) { return $p } }
        return $null
    }
    function Ensure-OnPath($exe) {
        # fcode.ps1 calls gh and instabox by name, so the folder of each must be on PATH (this window and the user PATH).
        $d = Split-Path $exe
        foreach ($p in ($env:Path -split ';')) { if ($p.Trim() -and (Norm $p) -eq (Norm $d)) { return $true } }
        try { if (Add-UserPath $d) { Say '\u2713 \u0110\u00e3 th\u00eam th\u01b0 m\u1ee5c {0} v\u00e0o PATH' $d }; return $true } catch { return $false }
    }
    function Get-Cpu { $a = $env:PROCESSOR_ARCHITEW6432; if (-not $a) { $a = $env:PROCESSOR_ARCHITECTURE }; return $a }

    # ---------- 1. fcode files ----------
    Step 'C\u00e0i l\u1ec7nh fcode'
    $src = $env:FCODE_INSTALL_SOURCE
    if (-not $src) {
        if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'fcode.ps1'))) { $src = $PSScriptRoot } else { $src = $rawBase }
    }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('fcode-install-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tmp -Force
    try {
        if ($src -match '^[A-Za-z][A-Za-z0-9+.-]*://' -and $src -notmatch '^https://') { throw 'fc:\u0110\u1ecba ch\u1ec9 ngu\u1ed3n kh\u00f4ng h\u1ee3p l\u1ec7|Ch\u1ec9 d\u00f9ng \u0111\u1ecba ch\u1ec9 b\u1eaft \u0111\u1ea7u b\u1eb1ng https:// ho\u1eb7c m\u1ed9t th\u01b0 m\u1ee5c tr\u00ean m\u00e1y|' + $src }
        $files = 'fcode.ps1', 'fcode.cmd'
        # Fetch and check both files first, copy only after both are good, so the pair never gets mismatched.
        foreach ($f in $files) {
            $from = Join-Path $tmp $f
            if ($src -match '^https://') { Invoke-WebRequest -UseBasicParsing -Uri ($src.TrimEnd('/') + '/' + $f) -OutFile $from -ErrorAction Stop }
            else { Copy-Item -LiteralPath (Join-Path $src $f) -Destination $from -ErrorAction Stop }
            if ((Get-Item -LiteralPath $from).Length -lt 50) { throw ('fc:File {0} t\u1ea3i v\u1ec1 b\u1ecb r\u1ed7ng|Ch\u1ea1y l\u1ea1i l\u1ec7nh c\u00e0i sau \u00edt ph\u00fat|' -f $f) }
        }
        $null = New-Item -ItemType Directory -Path $binDir -Force
        $changed = $false
        foreach ($f in $files) {
            $from = Join-Path $tmp $f
            $to = Join-Path $binDir $f
            if ((Test-Path -LiteralPath $to) -and ((Get-FileHash $to).Hash -eq (Get-FileHash $from).Hash)) { continue }
            Copy-Item -LiteralPath $from -Destination $to -Force
            try { Unblock-File -LiteralPath $to } catch {}
            $changed = $true
        }
        if ($changed) { Say '\u2713 \u0110\u00e3 ch\u00e9p fcode v\u00e0o {0}' $binDir } else { Say '\u2713 fcode \u0111\u00e3 c\u00f3 s\u1eb5n, kh\u00f4ng c\u1ea7n ch\u00e9p l\u1ea1i' }
        if (Add-UserPath $binDir) { Say '\u2713 \u0110\u00e3 th\u00eam th\u01b0 m\u1ee5c fcode v\u00e0o PATH' }
    } catch {
        $w = Get-Why $_ 'Kh\u00f4ng ch\u00e9p \u0111\u01b0\u1ee3c file fcode' 'Ki\u1ec3m tra m\u1ea1ng r\u1ed3i ch\u1ea1y l\u1ea1i l\u1ec7nh c\u00e0i'
        Show-Why $w
        $todo.fcode = $w.Cause + '. ' + $w.Action
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

    # ---------- 1b. let PowerShell run fcode.ps1 ----------
    # With the default policy (Restricted) typing `fcode` in PowerShell fails. Windows PowerShell 5.1 is the one that matters,
    # so the policy is read and set through powershell.exe even when this script runs in PowerShell 7.
    function Invoke-Ps5($command) {
        # Run Windows PowerShell 5.1 without the Process-scope policy that `-ExecutionPolicy Bypass -File` leaves in the
        # environment (PSExecutionPolicyPreference); a child that inherits it sees Bypass and Set-ExecutionPolicy errors out.
        $saved = $env:PSExecutionPolicyPreference
        Remove-Item Env:\PSExecutionPolicyPreference -ErrorAction SilentlyContinue
        try { & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -Command $command }
        finally { if ($saved) { $env:PSExecutionPolicyPreference = $saved } }
    }
    if (-not $todo.fcode) {
        try {
            if ($env:FCODE_INSTALL_EPFAKE) { $lines = $env:FCODE_INSTALL_EPFAKE -split ',' }
            else { $lines = Invoke-Ps5 "Get-ExecutionPolicy -List | ForEach-Object { '{0}={1}' -f `$_.Scope, `$_.ExecutionPolicy }" }
            $ep = @{}
            foreach ($l in $lines) { $kv = ([string]$l).Trim() -split '=', 2; if ($kv.Count -eq 2) { $ep[$kv[0]] = $kv[1] } }
            # The first scope that is not Undefined decides (MachinePolicy and UserPolicy are group policy).
            $decider = $null; $eff = 'Undefined'
            foreach ($s in 'MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine') {
                if ($ep[$s] -and $ep[$s] -ne 'Undefined') { $decider = $s; $eff = $ep[$s]; break }
            }
            if (@('Undefined', 'Restricted', 'AllSigned') -contains $eff) {
                if ($decider -like '*Policy') {
                    # Group policy outranks everything, including the -ExecutionPolicy Bypass that fcode.cmd uses, so fcode.cmd cannot help here.
                    $why = V 'PowerShell tr\u00ean m\u00e1y n\u00e0y b\u1ecb qu\u1ea3n tr\u1ecb vi\u00ean kh\u00f3a n\u00ean ch\u01b0a ch\u1ea1y \u0111\u01b0\u1ee3c l\u1ec7nh fcode'
                    $act = V 'Nh\u1edd qu\u1ea3n tr\u1ecb vi\u00ean cho ph\u00e9p PowerShell ch\u1ea1y script \u1edf ch\u1ebf \u0111\u1ed9 RemoteSigned, r\u1ed3i ch\u1ea1y l\u1ea1i l\u1ec7nh c\u00e0i'
                    Show-Why @{ Cause = $why; Detail = '' }
                    $todo.fcode = $why + '. ' + $act
                } elseif (($dry -or $env:FCODE_INSTALL_EPFAKE) -and -not ($env:FCODE_INSTALL_EPFAKE -and $env:FCODE_INSTALL_EPREAL -eq '1')) {
                    Say '[ch\u1ea1y th\u1eed] Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force'
                } else {
                    # Judge the result by reading the CurrentUser policy back, not by the exit code.
                    $now = Invoke-Ps5 'try { Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force } catch { }; Get-ExecutionPolicy -Scope CurrentUser'
                    if ((@($now) -join '').Trim() -ne 'RemoteSigned') { throw ('Set-ExecutionPolicy did not take effect: ' + (@($now) -join ' ')) }
                    Say '\u0110\u00e3 cho ph\u00e9p PowerShell ch\u1ea1y l\u1ec7nh fcode (ch\u1ebf \u0111\u1ed9 RemoteSigned, ch\u1ec9 \u00e1p d\u1ee5ng cho t\u00e0i kho\u1ea3n c\u1ee7a b\u1ea1n).'
                }
            }
        } catch {
            $cmdName = 'fcode.cmd'
            Say 'Kh\u00f4ng b\u1eadt \u0111\u01b0\u1ee3c quy\u1ec1n cho PowerShell ch\u1ea1y l\u1ec7nh fcode. H\u00e3y g\u00f5 fcode.cmd thay cho fcode.'
            Write-Host ('  ' + (($_.Exception.Message -replace '\s+', ' ').Trim())) -ForegroundColor DarkGray
        }
    }

    # ---------- 2. config ----------
    if (-not (Test-Path -LiteralPath $cfgFile)) {
        $json = "{`n  `"instabox`": `"`",`n  `"box`": `"coder`",`n  `"syncRepos`": [],`n  `"ipaRepo`": `"brooklyn96/fcoding`",`n  `"ipaTag`": `"latest`"`n}`n"
        $null = New-Item -ItemType Directory -Path $cfgDir -Force
        [IO.File]::WriteAllText($cfgFile, $json, (New-Object Text.UTF8Encoding $false))
        Say '\u2713 \u0110\u00e3 t\u1ea1o file c\u1ea5u h\u00ecnh {0}' $cfgFile
    } else { Say '\u2713 File c\u1ea5u h\u00ecnh \u0111\u00e3 c\u00f3 s\u1eb5n, gi\u1eef nguy\u00ean' }

    # ---------- 3. GitHub CLI ----------
    Step 'Ki\u1ec3m tra GitHub CLI (gh)'
    function Install-GhZip {
        # No-admin fallback: the official .zip of the latest cli/cli release (their .msi installs machine-wide and needs admin).
        $arch = Get-Cpu
        $a = switch ($arch) { 'AMD64' { 'amd64' } 'ARM64' { 'arm64' } 'x86' { '386' } default { $null } }
        if (-not $a) { throw ('fc:M\u00e1y n\u00e0y (CPU {0}) ch\u01b0a c\u00f3 b\u1ea3n GitHub CLI t\u1ef1 c\u00e0i|{1}|' -f $arch, $ghManual) }
        $netCause = 'Kh\u00f4ng t\u1ea3i \u0111\u01b0\u1ee3c GitHub CLI (kh\u00f4ng v\u00e0o \u0111\u01b0\u1ee3c github.com)'
        # The /releases/latest page redirects to /releases/tag/vX.Y.Z; reading that avoids the rate-limited GitHub API.
        $loc = Net $netCause $ghManual {
            $req = [Net.HttpWebRequest]::Create('https://github.com/cli/cli/releases/latest')
            $req.AllowAutoRedirect = $false; $req.UserAgent = 'fcode-install'; $req.Timeout = 30000
            $resp = $req.GetResponse()
            try { [string]$resp.Headers['Location'] } finally { $resp.Close() }
        }
        if ($loc -notmatch '^https://github\.com/cli/cli/releases/tag/(v\d+\.\d+\.\d+)$') { throw ('fc:' + $netCause + '|' + $ghManual + '|unexpected redirect: ' + $loc) }
        $tag = $Matches[1]; $ver = $tag.Substring(1)
        $zipName = "gh_${ver}_windows_$a.zip"; $sumName = "gh_${ver}_checksums.txt"
        $zipUrl = "https://github.com/cli/cli/releases/download/$tag/$zipName"; $sumUrl = "https://github.com/cli/cli/releases/download/$tag/$sumName"
        if ($dry) { Say '[ch\u1ea1y th\u1eed] s\u1ebd t\u1ea3i {0} r\u1ed3i gi\u1ea3i n\u00e9n v\u00e0o {1}' @($zipUrl, $ghZipDir); return }
        $d = Join-Path ([IO.Path]::GetTempPath()) ('fcode-gh-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $d -Force
        try {
            Say '\u0110ang t\u1ea3i GitHub CLI {0}...' $tag
            $zf = Join-Path $d $zipName; $sf = Join-Path $d 'sums.txt'
            Net $netCause $ghManual { Invoke-WebRequest -UseBasicParsing -Uri $zipUrl -OutFile $zf -ErrorAction Stop }
            Net $netCause $ghManual { Invoke-WebRequest -UseBasicParsing -Uri $sumUrl -OutFile $sf -ErrorAction Stop }
            $want = (Get-Content -LiteralPath $sf | Where-Object { $_ -match ('\s\*?' + [regex]::Escape($zipName) + '\s*$') } | Select-Object -First 1) -replace '\s.*$', ''
            if (-not $want -or (Get-FileHash $zf -Algorithm SHA256).Hash -ne $want.ToUpperInvariant()) { throw ('fc:File t\u1ea3i v\u1ec1 kh\u00f4ng kh\u1edbp m\u00e3 ki\u1ec3m tra n\u00ean \u0111\u00e3 b\u1ecf|Ch\u1ea1y l\u1ea1i l\u1ec7nh c\u00e0i sau \u00edt ph\u00fat. N\u1ebfu v\u1eabn l\u1ed7i: {0}|' -f $ghManual) }
            Expand-Archive -LiteralPath $zf -DestinationPath $ghZipDir -Force
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    function Install-Gh {
        $winget = Find-Tool 'winget' @()
        if ($winget) {
            $wa = 'install', '--id', 'GitHub.cli', '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements'
            Say '\u0110ang c\u00e0i GitHub CLI b\u1eb1ng winget. N\u1ebfu Windows h\u1ecfi quy\u1ec1n, b\u1ea5m Yes.'
            if ($dry) { Say '[ch\u1ea1y th\u1eed] winget {0}' ($wa -join ' '); return }
            & $winget @wa
            Update-SessionPath
            if (Find-Gh) { return }
            Say 'winget ch\u01b0a c\u00e0i \u0111\u01b0\u1ee3c, th\u1eed c\u00e1ch kh\u00e1c...'
        }
        Install-GhZip
    }
    $gh = Find-Gh
    if ($gh) { Say '\u2713 GitHub CLI \u0111\u00e3 c\u00f3' }
    else {
        Say 'M\u00e1y ch\u01b0a c\u00f3 GitHub CLI (gh), \u0111ang c\u00e0i.'
        $ghWhy = $null
        try { Install-Gh } catch { $ghWhy = Get-Why $_ 'Kh\u00f4ng c\u00e0i t\u1ef1 \u0111\u1ed9ng \u0111\u01b0\u1ee3c GitHub CLI' $ghManual; Show-Why $ghWhy }
        $gh = Find-Gh
        if ($gh) { Say '\u2713 \u0110\u00e3 c\u00e0i GitHub CLI' }
        elseif ($dry) { $todo.gh = V 'ch\u01b0a c\u00e0i (\u0111ang ch\u1ea1y th\u1eed)' }
        elseif ($ghWhy) { $todo.gh = $ghWhy.Cause + '. ' + $ghWhy.Action }
        else { $todo.gh = V $ghManual }
    }
    if ($gh -and -not (Ensure-OnPath $gh)) { $todo.gh = (V 'Kh\u00f4ng th\u00eam \u0111\u01b0\u1ee3c th\u01b0 m\u1ee5c GitHub CLI v\u00e0o PATH. Ch\u1ea1y l\u1ea1i l\u1ec7nh c\u00e0i, ho\u1eb7c t\u1ef1 th\u00eam th\u01b0 m\u1ee5c ') + (Split-Path $gh) + (V ' v\u00e0o PATH') }

    # ---------- 4. instabox ----------
    Step 'Ki\u1ec3m tra instabox'
    function Install-Instabox {
        # Direct download of the official Windows build, the same files and checks that `npx instabox@latest` uses
        # (npm package "instabox", lib/cli.mjs installWindows): https://api.instabox.sh/dl/<file> and SHA256SUMS.
        # Needs no Node.js, no npm and no admin. Docs: https://instabox.sh/docs/start
        $arch = Get-Cpu
        $a = switch ($arch) { 'AMD64' { 'amd64' } 'ARM64' { 'arm64' } default { $null } }
        if (-not $a) { throw ('fc:M\u00e1y n\u00e0y (CPU {0}) ch\u01b0a c\u00f3 b\u1ea3n instabox cho Windows|Xem https://instabox.sh/docs/start|' -f $arch) }
        $name = "instabox-windows-$a.exe"; $base = 'https://api.instabox.sh/dl'
        $netCause = 'Kh\u00f4ng t\u1ea3i \u0111\u01b0\u1ee3c instabox (kh\u00f4ng v\u00e0o \u0111\u01b0\u1ee3c api.instabox.sh)'
        Say '\u0110ang t\u1ea3i instabox t\u1eeb trang ch\u00ednh th\u1ee9c c\u1ee7a instabox v\u00e0 ki\u1ec3m tra m\u00e3 SHA256.'
        if ($dry) { Say '[ch\u1ea1y th\u1eed] s\u1ebd t\u1ea3i {0}/{1} v\u00e0 {0}/SHA256SUMS, ki\u1ec3m tra SHA256, r\u1ed3i \u0111\u1eb7t v\u00e0o {2}' @($base, $name, $ibDir); return }
        # Temp exes left by a run that was killed (closed window) are never cleaned by its finally block, so remove them now.
        Get-ChildItem -LiteralPath $ibDir -Filter '.instabox.install.*.exe' -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        $d = Join-Path ([IO.Path]::GetTempPath()) ('fcode-ib-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $d -Force
        # The exe is downloaded into its final folder under a temporary name (same volume) and renamed only after it is
        # checked, so an interrupted run can never leave a half-written instabox.exe behind.
        $null = New-Item -ItemType Directory -Path $ibDir -Force
        $exe = Join-Path $ibDir ('.instabox.install.' + [guid]::NewGuid().ToString('N') + '.exe')
        try {
            $sf = Join-Path $d 'SHA256SUMS'
            Net $netCause $ibManual { Invoke-WebRequest -UseBasicParsing -Uri "$base/$name" -OutFile $exe -ErrorAction Stop }
            Net $netCause $ibManual { Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile $sf -ErrorAction Stop }
            $want = (Get-Content -LiteralPath $sf | Where-Object { $_ -match ('\s\*?' + [regex]::Escape($name) + '\s*$') } | Select-Object -First 1) -replace '\s.*$', ''
            if ($want -notmatch '^[0-9a-fA-F]{64}$' -or (Get-FileHash $exe -Algorithm SHA256).Hash -ne $want.ToUpperInvariant()) { throw 'fc:File t\u1ea3i v\u1ec1 kh\u00f4ng kh\u1edbp m\u00e3 ki\u1ec3m tra n\u00ean \u0111\u00e3 b\u1ecf|Ch\u1ea1y l\u1ea1i l\u1ec7nh c\u00e0i sau v\u00e0i ph\u00fat. N\u1ebfu v\u1eabn l\u1ed7i: https://instabox.sh/docs/start|' }
            if (-not (Test-Runs $exe)) { throw 'fc:File instabox t\u1ea3i v\u1ec1 kh\u00f4ng ch\u1ea1y \u0111\u01b0\u1ee3c|Ch\u1ea1y l\u1ea1i l\u1ec7nh c\u00e0i sau v\u00e0i ph\u00fat. N\u1ebfu v\u1eabn l\u1ed7i: https://instabox.sh/docs/start|' }
            try { Move-Item -LiteralPath $exe -Destination (Join-Path $ibDir 'instabox.exe') -Force -ErrorAction Stop }
            catch { throw ('fc:Kh\u00f4ng ghi \u0111\u00e8 \u0111\u01b0\u1ee3c instabox.exe (c\u00f3 th\u1ec3 instabox \u0111ang ch\u1ea1y \u1edf m\u1ed9t c\u1eeda s\u1ed5 kh\u00e1c)|\u0110\u00f3ng c\u1eeda s\u1ed5 instabox \u0111ang ch\u1ea1y r\u1ed3i ch\u1ea1y l\u1ea1i l\u1ec7nh c\u00e0i|' + $_.Exception.Message) }
        } finally {
            Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $ib = Find-Ib
    if ($ib) { Say '\u2713 instabox \u0111\u00e3 c\u00f3' }
    else {
        Say 'M\u00e1y ch\u01b0a c\u00f3 instabox, \u0111ang c\u00e0i.'
        $ibWhy = $null
        try { Install-Instabox } catch { $ibWhy = Get-Why $_ 'Kh\u00f4ng c\u00e0i t\u1ef1 \u0111\u1ed9ng \u0111\u01b0\u1ee3c instabox' $ibManual; Show-Why $ibWhy }
        $ib = Find-Ib
        if ($ib) { Say '\u2713 \u0110\u00e3 c\u00e0i instabox' }
        elseif ($dry) { $todo.instabox = V 'ch\u01b0a c\u00e0i (\u0111ang ch\u1ea1y th\u1eed)' }
        elseif ($ibWhy) { $todo.instabox = $ibWhy.Cause + '. ' + $ibWhy.Action }
        else { $todo.instabox = V $ibManual }
    }
    if ($ib) {
        if (-not (Ensure-OnPath $ib)) { $todo.instabox = (V 'Kh\u00f4ng th\u00eam \u0111\u01b0\u1ee3c th\u01b0 m\u1ee5c instabox v\u00e0o PATH. Ch\u1ea1y l\u1ea1i l\u1ec7nh c\u00e0i, ho\u1eb7c t\u1ef1 th\u00eam th\u01b0 m\u1ee5c ') + (Split-Path $ib) + (V ' v\u00e0o PATH') }
    }

    # ---------- 5. logins ----------
    # Both checks call the network, so a single failure may be a hiccup: try up to 3 times before asking for a login.
    function Test-Login($exe, $a) {
        for ($i = 0; $i -lt 3; $i++) {
            & $exe @a *> $null
            if ($LASTEXITCODE -eq 0) { return $true }
            if ($i -lt 2) { Start-Sleep -Seconds 2 }
        }
        return $false
    }
    function Test-IbLogin { Test-Login $ib @('whoami') }
    function Test-GhLogin { Test-Login $gh @('auth', 'status') }

    if ($ib) {
        if (Test-IbLogin) { Say '\u2713 \u0110\u00e3 \u0111\u0103ng nh\u1eadp instabox' }
        else {
            Step 'B\u01b0\u1edbc 1/2: \u0111\u0103ng nh\u1eadp instabox. Tr\u00ecnh duy\u1ec7t s\u1ebd m\u1edf ra, b\u1ea1n \u0111\u0103ng nh\u1eadp r\u1ed3i quay l\u1ea1i \u0111\u00e2y'
            if ($dry) { Say '[ch\u1ea1y th\u1eed] instabox login' } else { & $ib login }
            if (Test-IbLogin) { Say '\u2713 \u0110\u00e3 \u0111\u0103ng nh\u1eadp instabox' }
            else { $todo.ibLogin = V 'g\u00f5: instabox login (n\u1ebfu tr\u00ecnh duy\u1ec7t kh\u00f4ng m\u1edf: instabox login --device)' }
        }
    } else { $todo.ibLogin = V 'l\u00e0m sau khi c\u00e0i instabox xong' }

    if ($gh) {
        if (Test-GhLogin) { Say '\u2713 \u0110\u00e3 \u0111\u0103ng nh\u1eadp GitHub' }
        else {
            Step 'B\u01b0\u1edbc 2/2: \u0111\u0103ng nh\u1eadp GitHub'
            Say 'GitHub s\u1ebd hi\u1ec7n m\u1ed9t m\u00e3 g\u1ed3m 8 k\u00fd t\u1ef1 (d\u1ea1ng ABCD-1234). B\u1ea1n ch\u00e9p m\u00e3 \u0111\u00f3,'
            Say 'b\u1ea5m Enter \u0111\u1ec3 m\u1edf tr\u00ecnh duy\u1ec7t, d\u00e1n m\u00e3 v\u00e0o \u00f4 tr\u00ean trang GitHub r\u1ed3i b\u1ea5m Authorize.'
            Say 'N\u1ebfu n\u00f3 h\u1ecfi g\u00ec kh\u00e1c, c\u1ee9 b\u1ea5m Enter \u0111\u1ec3 ch\u1ecdn m\u1eb7c \u0111\u1ecbnh.'
            if ($dry) { Say '[ch\u1ea1y th\u1eed] gh auth login -h github.com -p https --web' } else { & $gh auth login -h github.com -p https --web }
            if (Test-GhLogin) { Say '\u2713 \u0110\u00e3 \u0111\u0103ng nh\u1eadp GitHub' }
            else { $todo.ghLogin = V 'g\u00f5: gh auth login -h github.com -p https --web' }
        }
    } else { $todo.ghLogin = V 'l\u00e0m sau khi c\u00e0i gh xong' }

    # ---------- summary ----------
    Step 'K\u1ebft qu\u1ea3'
    $names = [ordered]@{ fcode = 'L\u1ec7nh fcode'; gh = 'GitHub CLI (gh)'; instabox = 'instabox'; ibLogin = '\u0110\u0103ng nh\u1eadp instabox'; ghLogin = '\u0110\u0103ng nh\u1eadp GitHub' }
    foreach ($k in $names.Keys) {
        if ($todo[$k]) { Write-Host ((V '\u2717 {0}: {1}') -f (V $names[$k]), $todo[$k]) -ForegroundColor Yellow }
        else { Write-Host ((V '\u2713 {0}') -f (V $names[$k])) -ForegroundColor Green }
    }
    if (-not $todo.fcode) { Say ''; Say 'M\u1edf c\u1eeda s\u1ed5 PowerShell m\u1edbi r\u1ed3i g\u00f5: {0} help' $cmdName }
    $global:FcodeInstallExit = [int](@($todo.Values | Where-Object { $_ }).Count -gt 0)
}

function Start-FcodeInstall {
    # Show Vietnamese correctly in the console, and always put the console encoding back (also on Ctrl+C).
    $enc = $null
    try { $enc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch {}
    try { Invoke-FcodeInstall } finally { try { if ($enc) { [Console]::OutputEncoding = $enc } } catch {} }
}

Start-FcodeInstall
$fcodeInstallCode = $global:FcodeInstallExit
Remove-Variable FcodeInstallExit -Scope Global -ErrorAction SilentlyContinue
Remove-Item Function:\Invoke-FcodeInstall, Function:\Start-FcodeInstall -ErrorAction SilentlyContinue
if ($PSCommandPath) { exit $fcodeInstallCode }
