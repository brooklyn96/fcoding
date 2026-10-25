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
#
# Test hooks (not for users):
#   FCODE_INSTALL_SOURCE  folder or URL that holds fcode.ps1 and fcode.cmd
#   FCODE_INSTALL_DRYRUN  =1: print the install and login commands instead of running them
#   FCODE_INSTALL_HIDE    comma list of tools (gh,instabox,winget,npx) hidden from the PATH search
#   FCODE_INSTALL_ENVKEY  HKCU subkey used instead of "Environment" when editing the user PATH
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
    # An item that is not done keeps its "what to do" sentence; $null means done.
    $todo = [ordered]@{ fcode = $null; gh = $null; instabox = $null; ibLogin = $null; ghLogin = $null }

    function V($s) { [regex]::Unescape($s) }
    function Say($m, $a) { Write-Host ((V $m) -f $a) }
    function Step($m) { Write-Host ''; Write-Host (V $m) -ForegroundColor Cyan }

    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { Say 'L\u1ec7nh c\u00e0i n\u00e0y ch\u1ec9 d\u00e0nh cho Windows.'; $global:FcodeInstallExit = 1; return }
    $oldEnc = $null
    try { $oldEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch {}
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
        $raw = Get-UserPathRaw
        $new = if ($raw.Trim()) { $raw.TrimEnd(';') + ';' + $dir } else { $dir }
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
        if ($hide -notcontains ($name -replace '\.cmd$', '')) { # FCODE_INSTALL_HIDE hides a tool from the PATH search only
            $c = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($c) { return $c.Source }
        }
        foreach ($p in $extra) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
        return $null
    }
    function Find-Gh { Find-Tool 'gh' @((Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'), (Join-Path $ghZipDir 'bin\gh.exe')) }
    function Find-Ib { Find-Tool 'instabox' @((Join-Path $ibDir 'instabox.exe')) }

    # ---------- 1. fcode files ----------
    Step 'C\u00e0i l\u1ec7nh fcode'
    $src = $env:FCODE_INSTALL_SOURCE
    if (-not $src) {
        if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'fcode.ps1'))) { $src = $PSScriptRoot } else { $src = $rawBase }
    }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('fcode-install-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tmp -Force
    try {
        $null = New-Item -ItemType Directory -Path $binDir -Force
        $changed = $false
        foreach ($f in 'fcode.ps1', 'fcode.cmd') {
            $from = Join-Path $tmp $f
            if ($src -match '^https?://') { Invoke-WebRequest -UseBasicParsing -Uri ($src.TrimEnd('/') + '/' + $f) -OutFile $from -ErrorAction Stop }
            else { Copy-Item -LiteralPath (Join-Path $src $f) -Destination $from -ErrorAction Stop }
            if ((Get-Item -LiteralPath $from).Length -lt 50) { throw ('{0} is empty' -f $f) }
            $to = Join-Path $binDir $f
            if ((Test-Path -LiteralPath $to) -and ((Get-FileHash $to).Hash -eq (Get-FileHash $from).Hash)) { continue }
            Copy-Item -LiteralPath $from -Destination $to -Force
            try { Unblock-File -LiteralPath $to } catch {}
            $changed = $true
        }
        if ($changed) { Say '\u2713 \u0110\u00e3 ch\u00e9p fcode v\u00e0o {0}' $binDir } else { Say '\u2713 fcode \u0111\u00e3 c\u00f3 s\u1eb5n, kh\u00f4ng c\u1ea7n ch\u00e9p l\u1ea1i' }
        if (Add-UserPath $binDir) { Say '\u2713 \u0110\u00e3 th\u00eam th\u01b0 m\u1ee5c fcode v\u00e0o PATH' }
    } catch {
        $todo.fcode = 'ch\u01b0a ch\u00e9p \u0111\u01b0\u1ee3c file fcode: ki\u1ec3m tra m\u1ea1ng r\u1ed3i ch\u1ea1y l\u1ea1i l\u1ec7nh c\u00e0i'
        Say '\u2717 Kh\u00f4ng ch\u00e9p \u0111\u01b0\u1ee3c file fcode. {0}' $_.Exception.Message
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

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
        $arch = $env:PROCESSOR_ARCHITEW6432; if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
        $a = switch ($arch) { 'AMD64' { 'amd64' } 'ARM64' { 'arm64' } default { $null } }
        if (-not $a) { throw ('unsupported CPU {0}' -f $arch) }
        # The /releases/latest page redirects to /releases/tag/vX.Y.Z; reading that avoids the rate-limited GitHub API.
        $req = [Net.HttpWebRequest]::Create('https://github.com/cli/cli/releases/latest')
        $req.AllowAutoRedirect = $false; $req.UserAgent = 'fcode-install'; $req.Timeout = 30000
        $resp = $req.GetResponse(); $loc = [string]$resp.Headers['Location']; $resp.Close()
        if ($loc -notmatch '^https://github\.com/cli/cli/releases/tag/(v\d+\.\d+\.\d+)$') { throw ('unexpected redirect from github.com/cli/cli: {0}' -f $loc) }
        $tag = $Matches[1]; $ver = $tag.Substring(1)
        $zip = [pscustomobject]@{ name = "gh_${ver}_windows_$a.zip"; browser_download_url = "https://github.com/cli/cli/releases/download/$tag/gh_${ver}_windows_$a.zip" }
        $sum = [pscustomobject]@{ name = "gh_${ver}_checksums.txt"; browser_download_url = "https://github.com/cli/cli/releases/download/$tag/gh_${ver}_checksums.txt" }
        if ($dry) { Say '[ch\u1ea1y th\u1eed] s\u1ebd t\u1ea3i {0} r\u1ed3i gi\u1ea3i n\u00e9n v\u00e0o {1}' @($zip.browser_download_url, $ghZipDir); return }
        $d = Join-Path ([IO.Path]::GetTempPath()) ('fcode-gh-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $d -Force
        try {
            Say '\u0110ang t\u1ea3i GitHub CLI {0}...' $tag
            $zf = Join-Path $d $zip.name; $sf = Join-Path $d 'sums.txt'
            Invoke-WebRequest -UseBasicParsing -Uri $zip.browser_download_url -OutFile $zf -ErrorAction Stop
            Invoke-WebRequest -UseBasicParsing -Uri $sum.browser_download_url -OutFile $sf -ErrorAction Stop
            $want = (Get-Content -LiteralPath $sf | Where-Object { $_ -match ('\s\*?' + [regex]::Escape($zip.name) + '$') } | Select-Object -First 1) -replace '\s.*$', ''
            if (-not $want -or (Get-FileHash $zf -Algorithm SHA256).Hash -ne $want.ToUpperInvariant()) { throw 'checksum mismatch, download discarded' }
            Expand-Archive -LiteralPath $zf -DestinationPath $ghZipDir -Force
            $null = Add-UserPath (Join-Path $ghZipDir 'bin')
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
        try { Install-Gh } catch { Say '\u2717 Kh\u00f4ng c\u00e0i t\u1ef1 \u0111\u1ed9ng \u0111\u01b0\u1ee3c: {0}' $_.Exception.Message }
        $gh = Find-Gh
        if ($gh) { Say '\u2713 \u0110\u00e3 c\u00e0i GitHub CLI' }
        elseif ($dry) { $todo.gh = 'ch\u01b0a c\u00e0i (\u0111ang ch\u1ea1y th\u1eed)' }
        else { $todo.gh = 'c\u00e0i tay t\u1eeb https://cli.github.com r\u1ed3i ch\u1ea1y l\u1ea1i l\u1ec7nh c\u00e0i' }
    }

    # ---------- 4. instabox ----------
    Step 'Ki\u1ec3m tra instabox'
    function Install-Instabox {
        # Official Windows method: `npx instabox@latest` (https://instabox.sh/docs/start). It puts instabox.exe in
        # %LOCALAPPDATA%\Programs\instabox and signs in with a device code. --no-skills: do not add agent skills.
        $npx = Find-Tool 'npx.cmd' @()
        if (-not $npx) {
            $winget = Find-Tool 'winget' @()
            if (-not $winget) { throw 'no Node.js and no winget on this machine' }
            $wa = 'install', '--id', 'OpenJS.NodeJS.LTS', '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements'
            Say 'instabox c\u1ea7n Node.js. \u0110ang c\u00e0i Node.js b\u1eb1ng winget, n\u1ebfu Windows h\u1ecfi quy\u1ec1n th\u00ec b\u1ea5m Yes.'
            if ($dry) { Say '[ch\u1ea1y th\u1eed] winget {0}' ($wa -join ' '); Say '[ch\u1ea1y th\u1eed] r\u1ed3i: npx --yes instabox@latest --no-skills'; return }
            & $winget @wa
            Update-SessionPath
            $npx = Find-Tool 'npx.cmd' @((Join-Path $env:ProgramFiles 'nodejs\npx.cmd'))
            if (-not $npx) { throw 'Node.js install did not finish' }
        }
        Say '\u0110ang c\u00e0i instabox b\u1eb1ng l\u1ec7nh ch\u00ednh th\u1ee9c c\u1ee7a instabox. L\u00fac n\u00e0y n\u00f3 s\u1ebd hi\u1ec7n m\u1ed9t m\u00e3 v\u00e0 m\u1edf tr\u00ecnh duy\u1ec7t \u0111\u1ec3 b\u1ea1n \u0111\u0103ng nh\u1eadp.'
        if ($dry) { Say '[ch\u1ea1y th\u1eed] npx --yes instabox@latest --no-skills'; return }
        & $npx --yes 'instabox@latest' --no-skills
    }
    $ib = Find-Ib
    if ($ib) { Say '\u2713 instabox \u0111\u00e3 c\u00f3' }
    else {
        Say 'M\u00e1y ch\u01b0a c\u00f3 instabox, \u0111ang c\u00e0i.'
        try { Install-Instabox } catch { Say '\u2717 Kh\u00f4ng c\u00e0i t\u1ef1 \u0111\u1ed9ng \u0111\u01b0\u1ee3c: {0}' $_.Exception.Message }
        $ib = Find-Ib
        if ($ib) { Say '\u2713 \u0110\u00e3 c\u00e0i instabox' }
        elseif ($dry) { $todo.instabox = 'ch\u01b0a c\u00e0i (\u0111ang ch\u1ea1y th\u1eed)' }
        else { $todo.instabox = 'c\u00e0i Node.js t\u1eeb https://nodejs.org (b\u1ea3n LTS) r\u1ed3i ch\u1ea1y l\u1ea1i l\u1ec7nh c\u00e0i; h\u01b0\u1edbng d\u1eabn ch\u00ednh th\u1ee9c: https://instabox.sh/docs/start' }
    }
    if ($ib) {
        try { if ((Split-Path $ib) -eq $ibDir -and (Add-UserPath $ibDir)) { Say '\u2713 \u0110\u00e3 th\u00eam th\u01b0 m\u1ee5c instabox v\u00e0o PATH' } } catch {}
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
            else { $todo.ibLogin = 'g\u00f5: instabox login (n\u1ebfu tr\u00ecnh duy\u1ec7t kh\u00f4ng m\u1edf: instabox login --device)' }
        }
    } else { $todo.ibLogin = 'l\u00e0m sau khi c\u00e0i instabox xong' }

    if ($gh) {
        if (Test-GhLogin) { Say '\u2713 \u0110\u00e3 \u0111\u0103ng nh\u1eadp GitHub' }
        else {
            Step 'B\u01b0\u1edbc 2/2: \u0111\u0103ng nh\u1eadp GitHub'
            Say 'GitHub s\u1ebd hi\u1ec7n m\u1ed9t m\u00e3 g\u1ed3m 8 k\u00fd t\u1ef1 (d\u1ea1ng ABCD-1234). B\u1ea1n ch\u00e9p m\u00e3 \u0111\u00f3,'
            Say 'b\u1ea5m Enter \u0111\u1ec3 m\u1edf tr\u00ecnh duy\u1ec7t, d\u00e1n m\u00e3 v\u00e0o \u00f4 tr\u00ean trang GitHub r\u1ed3i b\u1ea5m Authorize.'
            Say 'N\u1ebfu n\u00f3 h\u1ecfi g\u00ec kh\u00e1c, c\u1ee9 b\u1ea5m Enter \u0111\u1ec3 ch\u1ecdn m\u1eb7c \u0111\u1ecbnh.'
            if ($dry) { Say '[ch\u1ea1y th\u1eed] gh auth login -h github.com -p https --web' } else { & $gh auth login -h github.com -p https --web }
            if (Test-GhLogin) { Say '\u2713 \u0110\u00e3 \u0111\u0103ng nh\u1eadp GitHub' }
            else { $todo.ghLogin = 'g\u00f5: gh auth login -h github.com -p https --web' }
        }
    } else { $todo.ghLogin = 'l\u00e0m sau khi c\u00e0i gh xong' }

    # ---------- summary ----------
    Step 'K\u1ebft qu\u1ea3'
    $names = [ordered]@{ fcode = 'L\u1ec7nh fcode'; gh = 'GitHub CLI (gh)'; instabox = 'instabox'; ibLogin = '\u0110\u0103ng nh\u1eadp instabox'; ghLogin = '\u0110\u0103ng nh\u1eadp GitHub' }
    foreach ($k in $names.Keys) {
        if ($todo[$k]) { Write-Host ((V '\u2717 {0}: {1}') -f (V $names[$k]), (V $todo[$k])) -ForegroundColor Yellow }
        else { Write-Host ((V '\u2713 {0}') -f (V $names[$k])) -ForegroundColor Green }
    }
    Say ''
    Say 'M\u1edf c\u1eeda s\u1ed5 PowerShell m\u1edbi r\u1ed3i g\u00f5: fcode help'
    try { if ($oldEnc) { [Console]::OutputEncoding = $oldEnc } } catch {}
    $global:FcodeInstallExit = [int](@($todo.Values | Where-Object { $_ }).Count -gt 0)
}

Invoke-FcodeInstall
$fcodeInstallCode = $global:FcodeInstallExit
Remove-Variable FcodeInstallExit -Scope Global -ErrorAction SilentlyContinue
Remove-Item Function:\Invoke-FcodeInstall -ErrorAction SilentlyContinue
if ($PSCommandPath) { exit $fcodeInstallCode }
