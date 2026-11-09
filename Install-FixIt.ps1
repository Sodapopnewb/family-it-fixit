<#
Install-FixIt.ps1  -  sets up Family Fix-It on this PC (no administrator needed).

What it does, in plain words:
  1. Downloads the list of files (manifest.json) and the files from Trey's GitHub page.
  2. Checks every file against its SHA-256 fingerprint. If anything does not match, nothing is installed.
  3. Closes any Family Fix-It window that is still open on the old version, then puts the files in  %LOCALAPPDATA%\FamilyFixIt  (your own user folder).
  4. Makes a "Family Fix-It" shortcut (with its own icon) on the Desktop and in the Start menu,
     and registers the per-user link familyfixit://open (no administrator needed).
  5. Turns on the scary-pop-up watcher (Guardian) and the weekly check-in.
  6. Opens Family Fix-It.
Running it again is safe: it repairs missing or changed files, or updates to the newest version.

Use:  double-click Install-FamilyFixIt.cmd   (or)   irm <raw address>/Install-FixIt.ps1 | iex
Practice run (changes nothing):  .\Install-FixIt.ps1 -WhatIf
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'https://raw.githubusercontent.com/Sodapopnewb/family-it-fixit/main',
    [string]$InstallDir = '',
    [string]$LogPath = '',
    [switch]$NoLaunch,
    [switch]$WhatIf,
    [switch]$LibraryOnly
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:InstallerVersion = '1.1.0'
$script:InstallerPlaceholder = ('<' + 'OWNER>')   # the guard below compares with this; Publish never rewrites it
$script:InstallerFiles = @('FamilyFixIt.ps1', 'Start-FixIt.cmd', 'README.md', 'guides.json', 'FamilyFixIt.ico')   # the only files this installer will ever write
$script:InstallerRequired = @('FamilyFixIt.ps1', 'Start-FixIt.cmd')   # the icon is not required: a download list without it still installs
$script:InstallDry = [bool]$WhatIf
$script:InstallLog = ''
$script:ShortcutName = 'Family Fix-It'
$script:TestShortcutName = 'Family Fix-It (Test mode)'   # Start menu only; the same program with -Test (it only checks the fixes)
$script:ShortcutIcon = 'shell32.dll,22'   # only used if the program icon file is missing
$script:IconFileName = 'FamilyFixIt.ico'

# ----- small helpers ------------------------------------------------------
function Write-InstallLog {
    param([string]$Text, [string]$Level = 'INFO')
    if (-not $script:InstallLog) { return }
    try { Add-Content -LiteralPath $script:InstallLog -Value ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Text) -Encoding UTF8 } catch { }
}
# The same daily log the program uses (fixit-YYYY-MM-DD.log). Install steps that change the open link are written here too.
function Write-InstallFixItLog {
    param([string]$Text)
    try {
        $base = $env:LOCALAPPDATA
        if (-not $base) { $base = [IO.Path]::GetTempPath() }
        $dir = Join-Path $base 'FamilyFixIt\logs'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $log = Join-Path $dir ('fixit-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
        $line = '{0} [INFO] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
        [IO.File]::AppendAllText($log, ($line + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    } catch { }
}
function Say {
    param([string]$Text, [string]$Color = '')
    if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
    Write-InstallLog $Text
}
function New-InstallResult {
    param([bool]$Ok, [string]$Title, [string]$Message, [string]$Version = '', [bool]$Changed = $false)
    return [pscustomobject]@{ Ok = $Ok; Title = $Title; Message = $Message; Version = $Version; Changed = $Changed }
}

# ----- Windows / network adapters (the tests replace these with pretend versions) ------
function Test-InstallWindows { return ([Environment]::OSVersion.Platform -eq 'Win32NT') }
function Test-InstallElevated {
    try { $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false }
}
function Get-InstallDefaultDir {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = [IO.Path]::GetTempPath() }
    return (Join-Path $base 'FamilyFixIt')
}
function Get-InstallFolderPath { param([string]$Which) return [Environment]::GetFolderPath($Which) }   # 'Desktop' or 'Programs'
function Initialize-InstallNetwork {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
}
function Get-InstallText {
    param([string]$Url)
    Initialize-InstallNetwork
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 60
    if ($r.Content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($r.Content).TrimStart([char]0xFEFF) }
    return [string]$r.Content
}
function Save-InstallFile {
    param([string]$Url, [string]$Dest)
    Initialize-InstallNetwork
    Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 120 -OutFile $Dest
}
function Get-InstallHash {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Get-InstallShortcut {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $sh = New-Object -ComObject WScript.Shell
        $l = $sh.CreateShortcut($Path)
        return [pscustomobject]@{ Target = [string]$l.TargetPath; Arguments = [string]$l.Arguments; Icon = [string]$l.IconLocation }
    } catch { return $null }
}
function New-InstallShortcut {
    param([string]$Path, [string]$Target, [string]$Arguments, [string]$WorkDir, [string]$Icon, [string]$Description)
    $sh = New-Object -ComObject WScript.Shell
    $l = $sh.CreateShortcut($Path)
    $l.TargetPath = $Target
    $l.Arguments = $Arguments
    $l.WorkingDirectory = $WorkDir
    $l.Description = $Description
    $l.WindowStyle = 7
    if ($Icon) { $l.IconLocation = $Icon }
    $l.Save()
}
function Get-InstallPowerShell {
    if ($env:SystemRoot) { $p = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; if (Test-Path -LiteralPath $p) { return $p } }
    return 'powershell.exe'
}
# Runs a command-line action of the installed tool (for example GuardianOn) and waits for THAT program only. Returns the exit code.
# Never use Start-Process -Wait here: it also waits for every program the action starts, and GuardianOn starts the
# pop-up watcher, which keeps running for good - so the installer would wait forever (a real PC did exactly that).
# -Yes: nobody can answer a question here, so the program must never ask one.
function Invoke-InstalledAction {
    param([string]$Dir, [string]$Action, [int]$TimeoutSeconds = 120)
    $exe = Get-InstallPowerShell
    $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (Join-Path $Dir 'FamilyFixIt.ps1'), '-Action', $Action, '-Yes')
    $p = Start-Process -FilePath $exe -ArgumentList $args2 -WindowStyle Hidden -PassThru
    try { $null = $p.Handle } catch { }   # keep the handle so the exit code can be read afterwards
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        Write-InstallLog ('{0} did not finish in {1} seconds; stopped it' -f $Action, $TimeoutSeconds) 'WARN'
        try { $p.Kill() } catch { }
        return 1
    }
    return [int]$p.ExitCode
}
function Start-InstalledTool {
    param([string]$Dir)
    $exe = Get-InstallPowerShell
    Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', (Join-Path $Dir 'FamilyFixIt.ps1')) -WindowStyle Hidden | Out-Null
}

# ----- old windows ------------------------------------------------------------
# A Family Fix-It window that is still open runs the OLD program. Before the files are replaced, this PC user's open Family Fix-It
# windows are closed: first politely (the same as clicking the X), then, after about 5 seconds, by force. Only a process whose
# command line names FamilyFixIt.ps1 and has no -Action (or -Action Gui) counts. The pop-up watcher (-Action Guardian), the weekly
# check-in and every unrelated PowerShell are never touched; the watcher is restarted through its own GuardianOff / GuardianOn.
$script:InstallCloseWaitSeconds = 5
function Get-InstallGuiWindowKind {
    param([string]$CommandLine)
    if (-not $CommandLine) { return '' }
    if ($CommandLine -notmatch '(?i)(?<=[\\/"''\s])FamilyFixIt\.ps1(?=["''\s]|$)') { return '' }
    if ($CommandLine -match '(?i)\s-LibraryOnly(?=[\s"'']|$)') { return '' }
    if ($CommandLine -match '(?i)\s-Ac[a-z]*(?:\s+|:)(?!["'']?Gui(?:["''\s]|$))\S') { return '' }
    return 'Window'
}
function Get-InstallProcessTable {
    $o = @()
    try {
        foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop)) {
            $o += [pscustomobject]@{ Id = [int]$p.ProcessId; CommandLine = [string]$p.CommandLine; SessionId = [int]$p.SessionId; Owner = '' }
        }
    } catch { Write-InstallLog ('Could not list the running programs: ' + $_.Exception.Message) 'WARN' }
    return @($o)
}
function Get-InstallProcessOwner {
    param([int]$Id)
    try {
        $p = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId={0}' -f $Id) -ErrorAction Stop
        if ($p) { $r = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop; if ($r -and $r.User) { return ([string]$r.Domain + '\' + [string]$r.User) } }
    } catch { }
    return ''
}
function Get-InstallOwnSession { try { return [int][Diagnostics.Process]::GetCurrentProcess().SessionId } catch { return -1 } }
function Get-InstallOwnUserName { return ([string]$env:USERDOMAIN + '\' + [string]$env:USERNAME) }
function Test-InstallProcessAlive { param([int]$Id) return [bool](Get-Process -Id $Id -ErrorAction SilentlyContinue) }
function Request-InstallWindowClose { param([int]$Id) $p = Get-Process -Id $Id -ErrorAction SilentlyContinue; if ($p) { [void]$p.CloseMainWindow() } }
function Stop-InstallWindowProcess { param([int]$Id) Stop-Process -Id $Id -Force -ErrorAction Stop }

function Get-InstallGuiProcesses {
    $mySession = Get-InstallOwnSession
    $me = Get-InstallOwnUserName
    $found = @()
    foreach ($p in @(Get-InstallProcessTable)) {
        if ([int]$p.Id -eq $PID) { continue }
        if (-not (Get-InstallGuiWindowKind -CommandLine ([string]$p.CommandLine))) { continue }
        if ($mySession -ge 0 -and [int]$p.SessionId -ne $mySession) { continue }   # another person signed in on this PC
        $owner = [string]$p.Owner
        if (-not $owner) { $owner = [string](Get-InstallProcessOwner -Id ([int]$p.Id)) }
        if ($owner -and $me -ne '\' -and [string]::Compare($owner, $me, $true) -ne 0) { continue }
        $found += [int]$p.Id
    }
    return @($found)
}

# Closes this PC user's open Family Fix-It windows. Returns how many were closed. Never throws: an update must not fail over this.
function Stop-InstallGuiWindows {
    param([int]$WaitSeconds = -1)
    if ($WaitSeconds -lt 0) { $WaitSeconds = $script:InstallCloseWaitSeconds }
    $ids = @()
    try { $ids = @(Get-InstallGuiProcesses) } catch { Write-InstallLog ('Could not look for open windows: ' + $_.Exception.Message) 'WARN'; return 0 }
    if ($ids.Count -eq 0) { Write-InstallLog 'No Family Fix-It window is open'; return 0 }
    Say '   Closing the Family Fix-It window that is open, so it can be updated ...'
    Write-InstallLog ('Closing {0} open Family Fix-It window(s): {1}; asking politely first' -f $ids.Count, ($ids -join ', '))
    foreach ($id in $ids) { try { Request-InstallWindowClose -Id $id } catch { Write-InstallLog ('Could not ask window {0} to close: {1}' -f $id, $_.Exception.Message) 'WARN' } }
    $end = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $end -and @($ids | Where-Object { Test-InstallProcessAlive -Id $_ }).Count -gt 0) { Start-Sleep -Milliseconds 200 }
    $left = @($ids | Where-Object { Test-InstallProcessAlive -Id $_ })
    if ($left.Count -gt 0) {
        $still = @(); try { $still = @(Get-InstallGuiProcesses) } catch { }
        foreach ($id in $left) {
            if ($still -notcontains $id) { Write-InstallLog ('Process {0} is no longer a Family Fix-It window; left alone' -f $id); continue }
            try { Stop-InstallWindowProcess -Id $id; Write-InstallLog ('Window {0} did not close on its own; closed by force' -f $id) }
            catch { Write-InstallLog ('Could not close window {0}: {1}' -f $id, $_.Exception.Message) 'WARN' }
        }
        $t2 = (Get-Date).AddSeconds(2)
        while ((Get-Date) -lt $t2 -and @($left | Where-Object { Test-InstallProcessAlive -Id $_ }).Count -gt 0) { Start-Sleep -Milliseconds 100 }
    }
    $closed = @($ids | Where-Object { -not (Test-InstallProcessAlive -Id $_) })
    Write-InstallLog ('Closed {0} of {1} Family Fix-It window(s): {2}' -f $closed.Count, $ids.Count, ($closed -join ', '))
    return $closed.Count
}

# ----- the list of files ----------------------------------------------------
# Reads manifest.json text and returns the entries, or throws a plain-English message.
function Read-InstallManifest {
    param([string]$Json)
    $m = $null
    try { $m = $Json | ConvertFrom-Json } catch { throw 'The download list on GitHub could not be read.' }
    if ($null -eq $m -or [string]$m.name -ne 'family-it-fixit') { throw 'The download list on GitHub is not the Family Fix-It list.' }
    if ([string]$m.version -notmatch '^\d+\.\d+\.\d+$') { throw 'The download list has no proper version number.' }
    $entries = @()
    $listed = @($m.files)
    # the program icon is listed under "assets" (older program versions refuse unknown names in "files")
    if ($m.PSObject.Properties.Name -contains 'assets') { $listed += @($m.assets) }
    foreach ($f in $listed) {
        $path = [string]$f.path; $hash = [string]$f.sha256
        if ($script:InstallerFiles -notcontains $path) { continue }   # anything unexpected is ignored, never installed
        if ($hash -notmatch '^[0-9a-fA-F]{64}$') { throw ('The download list has a bad fingerprint for ' + $path + '.') }
        $size = 0; try { $size = [int64]$f.size } catch { }
        if ($size -le 0 -or $size -gt 5MB) { throw ('The download list has a bad size for ' + $path + '.') }
        $entries += [pscustomobject]@{ Path = $path; Sha256 = $hash.ToLowerInvariant(); Size = $size }
    }
    foreach ($r in $script:InstallerRequired) { if (-not (@($entries | Where-Object { $_.Path -eq $r }).Count)) { throw ('The download list is missing ' + $r + '.') } }
    $seen = @{}
    foreach ($e in $entries) { if ($seen.ContainsKey($e.Path)) { throw ('The download list names ' + $e.Path + ' twice.') }; $seen[$e.Path] = $true }
    return [pscustomobject]@{ Version = [string]$m.version; Files = $entries }
}
function Get-InstalledVersion {
    param([string]$Dir)
    $p = Join-Path $Dir 'FamilyFixIt.ps1'
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    try { $mm = [regex]::Match([IO.File]::ReadAllText($p), "FixItVersion = '(\d+\.\d+\.\d+)'"); if ($mm.Success) { return $mm.Groups[1].Value } } catch { }
    return ''
}

# ----- the install ------------------------------------------------------------
function Install-FixItFiles {
    param($Manifest, [string]$Base, [string]$Dir)
    $stage = Join-Path $Dir '.staging'
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $changed = @()
    try {
        # download and check EVERYTHING first; only then touch the installed copy
        foreach ($f in $Manifest.Files) {
            $tmpFile = Join-Path $stage $f.Path
            $have = Join-Path $Dir $f.Path
            if ((Test-Path -LiteralPath $have) -and ((Get-InstallHash $have) -eq $f.Sha256)) { Write-InstallLog ('Already correct: ' + $f.Path); continue }
            Say ('   Downloading {0} ...' -f $f.Path)
            try { Save-InstallFile -Url ($Base.TrimEnd('/') + '/' + $f.Path) -Dest $tmpFile } catch {
                Write-InstallLog ('Download failed for {0}: {1}' -f $f.Path, $_.Exception.Message) 'ERROR'
                throw 'A file could not be downloaded. Please check that the internet is working, then run this again.'
            }
            if (-not (Test-Path -LiteralPath $tmpFile)) { throw 'A file could not be downloaded. Please check that the internet is working, then run this again.' }
            $got = Get-InstallHash $tmpFile
            if ($got -ne $f.Sha256 -or (Get-Item -LiteralPath $tmpFile).Length -ne $f.Size) {
                Write-InstallLog ('CHECKSUM MISMATCH for {0}: expected {1}, got {2}' -f $f.Path, $f.Sha256, $got) 'ERROR'
                throw ('The downloaded file "' + $f.Path + '" did not pass its safety check, so NOTHING was installed. Please tell Trey.')
            }
            $changed += $f.Path
        }
        if ($changed.Count -gt 0) {
            # a window that is still open runs the old program: close it before the program file is replaced (a change to the other files alone does not need that)
            if ($changed -contains 'FamilyFixIt.ps1') { try { [void](Stop-InstallGuiWindows) } catch { Write-InstallLog ('Closing open windows: ' + $_.Exception.Message) 'WARN' } }
            $prev = Join-Path $Dir 'previous'
            foreach ($p in $changed) {
                $dest = Join-Path $Dir $p
                if (Test-Path -LiteralPath $dest) {
                    if (-not (Test-Path -LiteralPath $prev)) { New-Item -ItemType Directory -Path $prev -Force | Out-Null }
                    Copy-Item -LiteralPath $dest -Destination (Join-Path $prev $p) -Force
                }
                try { Move-Item -LiteralPath (Join-Path $stage $p) -Destination $dest -Force }
                catch { Start-Sleep -Seconds 2; Move-Item -LiteralPath (Join-Path $stage $p) -Destination $dest -Force }
                Write-InstallLog ('Installed ' + $p)
            }
        }
    } finally {
        try { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
    return $changed
}

function Test-InstallSameIcon {
    param([string]$A, [string]$B)
    $x = ($A -replace ',\s*-?\d+\s*$', '').Trim().Trim('"'); $y = ($B -replace ',\s*-?\d+\s*$', '').Trim().Trim('"')
    return ([string]::Compare($x, $y, $true) -eq 0)
}
# The icon file is only used when it is really there (and starts like an .ico); otherwise the old built-in icon.
function Get-InstallIconLocation {
    param([string]$Dir)
    $p = Join-Path $Dir $script:IconFileName
    try {
        if (Test-Path -LiteralPath $p) {
            $b = [IO.File]::ReadAllBytes($p)
            if ($b.Length -ge 22 -and $b[0] -eq 0 -and $b[1] -eq 0 -and $b[2] -eq 1 -and $b[3] -eq 0) { return ($p + ',0') }
        }
    } catch { }
    return $script:ShortcutIcon
}

# The exact arguments the Desktop shortcut uses. Test mode is the same line plus " -Test" (Start menu only).
function Get-InstallGuiArguments {
    param([string]$Dir)
    return ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + (Join-Path $Dir 'FamilyFixIt.ps1') + '"')
}

function Set-InstallShortcuts {
    param([string]$Dir)
    $ps = Get-InstallPowerShell
    $icon = Get-InstallIconLocation -Dir $Dir
    $args2 = Get-InstallGuiArguments -Dir $Dir
    $made = 0
    foreach ($w in @('Desktop', 'Programs')) {
        $folder = Get-InstallFolderPath $w
        if (-not $folder) { Write-InstallLog ('No ' + $w + ' folder found') 'WARN'; continue }
        $lnk = Join-Path $folder ($script:ShortcutName + '.lnk')
        $cur = Get-InstallShortcut $lnk
        if ($null -ne $cur -and $cur.Target -eq $ps -and $cur.Arguments -eq $args2 -and (Test-InstallSameIcon $cur.Icon $icon)) { Write-InstallLog ('Shortcut already correct: ' + $lnk); $made++; continue }
        try {
            if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
            New-InstallShortcut -Path $lnk -Target $ps -Arguments $args2 -WorkDir $Dir -Icon $icon -Description 'Family Fix-It: fixes common computer problems'
            Write-InstallLog ('Shortcut written: ' + $lnk)
            $made++
        } catch { Write-InstallLog ('Could not make shortcut {0}: {1}' -f $lnk, $_.Exception.Message) 'WARN' }
    }
    # The Test mode shortcut (Start menu only). Best effort: it is not counted above, so a problem here never fails the install.
    try {
        $tf = Get-InstallFolderPath 'Programs'
        if ($tf) {
            $tl = Join-Path $tf ($script:TestShortcutName + '.lnk')
            $targs = $args2 + ' -Test'
            $tc = Get-InstallShortcut $tl
            if ($null -ne $tc -and $tc.Target -eq $ps -and $tc.Arguments -eq $targs -and (Test-InstallSameIcon $tc.Icon $icon)) { Write-InstallLog ('Shortcut already correct: ' + $tl) }
            else {
                if (-not (Test-Path -LiteralPath $tf)) { New-Item -ItemType Directory -Path $tf -Force | Out-Null }
                New-InstallShortcut -Path $tl -Target $ps -Arguments $targs -WorkDir $Dir -Icon $icon -Description 'Family Fix-It in Test mode: checks that each fix could work, and changes nothing'
                Write-InstallLog ('Shortcut written: ' + $tl)
            }
        }
    } catch { Write-InstallLog ('Could not make the Test mode shortcut: ' + $_.Exception.Message) 'WARN' }
    return $made
}

# ----- the familyfixit: link -------------------------------------------------
# A web page opens Family Fix-It with familyfixit://open. The link is registered for this
# Windows user only (HKCU\Software\Classes\familyfixit). No administrator.
# The registered command does not contain %1. It starts Start-FixItLink.ps1, which never
# reads the address Windows may append, then starts the same command as the Desktop shortcut.
# Every familyfixit: address is the same: open the normal window. Nothing is fixed from the link.
$script:LaunchLinkKey = 'Software\Classes\familyfixit'

function Get-InstallLaunchLinkScript {
    $s = @'
# Start-FixItLink.ps1 - opens the normal Family Fix-It window (the same start as the Desktop shortcut).
# Windows may add the familyfixit: address after this file. Those arguments are never read.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$tool = Join-Path $root 'FamilyFixIt.ps1'
$ps = 'powershell.exe'
if ($env:SystemRoot) {
    $candidate = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $candidate) { $ps = $candidate }
}
$arg = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $tool + '"'
try {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = [IO.Path]::GetTempPath() }
    $logDir = Join-Path $base 'FamilyFixIt\logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $log = Join-Path $logDir ('fixit-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
    $enc = New-Object Text.UTF8Encoding $false
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line1 = '{0} [INFO] Opened from a familyfixit: link. The address was ignored. Opening the normal window.' -f $stamp
    $line2 = '{0} [INFO] Normal window command: {1} {2}' -f $stamp, $ps, $arg
    [IO.File]::AppendAllText($log, ($line1 + [Environment]::NewLine + $line2 + [Environment]::NewLine), $enc)
} catch { }
try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ps
    $psi.Arguments = $arg
    $psi.WorkingDirectory = $root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    [void][System.Diagnostics.Process]::Start($psi)
} catch {
    try {
        $why = '{0} [INFO] Could not open the window: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message
        [IO.File]::AppendAllText($log, ($why + [Environment]::NewLine), $enc)
    } catch { }
}
'@
    $s = $s -replace "(?<!\r)\n", "`r`n"
    if (-not $s.EndsWith("`r`n")) { $s += "`r`n" }
    return $s
}

# Quoted command line for the registry. No %1, so the address is not placed inside this command.
# A path that contains a quote or a percent sign is refused (it could change the command).
function Get-InstallLaunchCommand {
    param([string]$Dir)
    $ps = Get-InstallPowerShell
    # Checked before Join-Path: a quote or a percent sign must never become part of the command.
    if ($ps.Contains('"') -or $ps.Contains('%') -or $Dir.Contains('"') -or $Dir.Contains('%')) { return '' }
    $link = Join-Path $Dir 'Start-FixItLink.ps1'
    if ($link.Contains('"') -or $link.Contains('%')) { return '' }
    return ('"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}"' -f $ps, $link)
}

function Test-InstallRegistryPresent {
    try {
        $cu = [Microsoft.Win32.Registry]::CurrentUser
        if ($null -eq $cu) { return $false }
        $k = $cu.OpenSubKey('Software')
        if ($k) { $k.Close(); return $true }
        return $false
    } catch { return $false }
}

function Get-InstallRegLines {
    param($Key, [string]$Prefix)
    $o = @()
    foreach ($n in @($Key.GetValueNames())) { $o += ($Prefix + '|' + $n + '|' + [string]$Key.GetValue($n)) }
    foreach ($n in @($Key.GetSubKeyNames())) {
        $sub = $Key.OpenSubKey($n)
        if ($null -eq $sub) { continue }
        try { $o += @(Get-InstallRegLines -Key $sub -Prefix ($Prefix + '\' + $n)) } finally { $sub.Close() }
    }
    return @($o)
}

function ConvertTo-InstallLaunchLinkSnapshot {
    param([string[]]$Lines)
    $desc = ''; $proto = ''; $protoPresent = $false; $icon = ''; $command = ''
    $extra = New-Object System.Collections.ArrayList
    foreach ($line in @($Lines)) {
        if (-not $line) { continue }
        $p = $line.Split([char[]]@([char]'|'), 3)
        if ($p.Count -lt 3) { [void]$extra.Add($line); continue }
        $path = $p[0]; $name = $p[1]; $value = $p[2]
        if ($path -eq '' -and $name -eq '') { $desc = $value }
        elseif ($path -eq '' -and $name -eq 'URL Protocol') { $protoPresent = $true; $proto = $value }
        elseif ($path -eq '\DefaultIcon' -and $name -eq '') { $icon = $value }
        elseif ($path -eq '\shell\open\command' -and $name -eq '') { $command = $value }
        else { [void]$extra.Add($line) }
    }
    return [pscustomobject]@{ Description = $desc; ProtocolPresent = $protoPresent; Protocol = $proto; Icon = $icon; Command = $command; Extra = @($extra) }
}

function Get-InstallLaunchLinkSnapshot {
    $cu = [Microsoft.Win32.Registry]::CurrentUser
    $base = $cu.OpenSubKey($script:LaunchLinkKey)
    if ($null -eq $base) { return $null }
    try { return (ConvertTo-InstallLaunchLinkSnapshot -Lines @(Get-InstallRegLines -Key $base -Prefix '')) }
    finally { $base.Close() }
}

function Set-InstallLaunchLinkSnapshot {
    param([string]$Description, [string]$Protocol, [string]$Icon, [string]$Command)
    $cu = [Microsoft.Win32.Registry]::CurrentUser
    $have = $cu.OpenSubKey($script:LaunchLinkKey)
    if ($have) { $have.Close(); $cu.DeleteSubKeyTree($script:LaunchLinkKey) }
    $base = $cu.CreateSubKey($script:LaunchLinkKey)
    try {
        $base.SetValue('', $Description)
        $base.SetValue('URL Protocol', $Protocol)
        $iconKey = $base.CreateSubKey('DefaultIcon')
        try { $iconKey.SetValue('', $Icon) } finally { $iconKey.Close() }
        $open = $base.CreateSubKey('shell\open')
        try {
            $cmdKey = $open.CreateSubKey('command')
            try { $cmdKey.SetValue('', $Command) } finally { $cmdKey.Close() }
        } finally { $open.Close() }
    } finally { $base.Close() }
}

function Remove-InstallLaunchLinkKey {
    $cu = [Microsoft.Win32.Registry]::CurrentUser
    $have = $cu.OpenSubKey($script:LaunchLinkKey)
    if ($have) { $have.Close(); $cu.DeleteSubKeyTree($script:LaunchLinkKey) }
}

function Test-InstallLaunchLinkSame {
    param($Have, [string]$Description, [string]$Icon, [string]$Command)
    if ($null -eq $Have) { return $false }
    if (-not $Have.ProtocolPresent -or [string]$Have.Protocol -ne '') { return $false }
    if ([string]$Have.Description -ne $Description -or [string]$Have.Icon -ne $Icon -or [string]$Have.Command -ne $Command) { return $false }
    return (@($Have.Extra).Count -eq 0)
}

# Writes the opener and the per-user registry key. Safe to run again: the same values are written, and any extra values are removed.
function Register-InstallLaunchLink {
    param([string]$Dir)
    $cmd = Get-InstallLaunchCommand -Dir $Dir
    if (-not $cmd) {
        Write-InstallLog 'Launch link was not registered: the folder path cannot be used in the open command.' 'WARN'
        Write-InstallFixItLog 'Launch link was not registered: the folder path cannot be used in the open command.'
        return $false
    }
    $opener = Join-Path $Dir 'Start-FixItLink.ps1'
    $text = Get-InstallLaunchLinkScript
    try {
        $curText = ''
        if (Test-Path -LiteralPath $opener) { $curText = [IO.File]::ReadAllText($opener) }
        if ($curText -ne $text) {
            [IO.File]::WriteAllText($opener, $text, (New-Object Text.UTF8Encoding($false)))
            Write-InstallLog ('Launch link opener written: ' + $opener)
            Write-InstallFixItLog ('Launch link opener written: ' + $opener)
        } else {
            Write-InstallLog ('Launch link opener already correct: ' + $opener)
        }
    } catch {
        Write-InstallLog ('Could not write the launch link opener: ' + $_.Exception.Message) 'WARN'
        Write-InstallFixItLog ('Could not write the launch link opener: ' + $_.Exception.Message)
        return $false
    }
    if (-not (Test-InstallRegistryPresent)) {
        Write-InstallLog 'Launch link was not registered: the per-user registry is not available on this computer.' 'WARN'
        Write-InstallFixItLog 'Launch link was not registered: the per-user registry is not available on this computer.'
        return $false
    }
    $icon = Get-InstallIconLocation -Dir $Dir
    $desc = 'URL:Family Fix-It'
    try {
        $have = Get-InstallLaunchLinkSnapshot
        if (Test-InstallLaunchLinkSame -Have $have -Description $desc -Icon $icon -Command $cmd) {
            Write-InstallLog 'Launch link already correct: HKCU\Software\Classes\familyfixit'
            Write-InstallFixItLog 'Launch link already correct: HKCU\Software\Classes\familyfixit'
            Write-InstallFixItLog ('Launch link command: ' + $cmd)
            return $true
        }
        Set-InstallLaunchLinkSnapshot -Description $desc -Protocol '' -Icon $icon -Command $cmd
        Write-InstallLog 'Launch link written: HKCU\Software\Classes\familyfixit'
        Write-InstallLog ('Launch link command: ' + $cmd)
        Write-InstallFixItLog 'Launch link written: HKCU\Software\Classes\familyfixit'
        Write-InstallFixItLog ('Launch link command: ' + $cmd)
        return $true
    } catch {
        Write-InstallLog ('Could not write the launch link: ' + $_.Exception.Message) 'WARN'
        Write-InstallFixItLog ('Could not write the launch link: ' + $_.Exception.Message)
        return $false
    }
}

# Removes the per-user key and the opener. The repo has no uninstall program; this is what an uninstall would call.
function Remove-InstallLaunchLink {
    param([string]$Dir = '')
    if (-not (Test-InstallRegistryPresent)) {
        Write-InstallLog 'Launch link was not removed: the per-user registry is not available on this computer.' 'WARN'
        Write-InstallFixItLog 'Launch link was not removed: the per-user registry is not available on this computer.'
        return $false
    }
    try { Remove-InstallLaunchLinkKey } catch {
        Write-InstallLog ('Could not remove the launch link: ' + $_.Exception.Message) 'WARN'
        Write-InstallFixItLog ('Could not remove the launch link: ' + $_.Exception.Message)
        return $false
    }
    if ($Dir) {
        $opener = Join-Path $Dir 'Start-FixItLink.ps1'
        try { if (Test-Path -LiteralPath $opener) { Remove-Item -LiteralPath $opener -Force } } catch {
            Write-InstallLog ('Could not remove the launch link opener: ' + $_.Exception.Message) 'WARN'
        }
    }
    Write-InstallLog 'Launch link removed: HKCU\Software\Classes\familyfixit'
    Write-InstallFixItLog 'Launch link removed: HKCU\Software\Classes\familyfixit'
    return $true
}

function Install-FamilyFixIt {
    param([string]$Base, [string]$Dir, [bool]$Launch = $true)
    if (-not (Test-InstallWindows)) { return (New-InstallResult $false 'Windows only' 'Family Fix-It only works on Windows.') }
    if ($Base.Contains($script:InstallerPlaceholder)) { return (New-InstallResult $false 'Not set up yet' 'This installer has not been given its GitHub address yet. Please tell Trey.') }
    if ($Base -notmatch '^https://') { return (New-InstallResult $false 'Not allowed' 'The download address must start with https://') }
    if (-not $Dir) { $Dir = Get-InstallDefaultDir }

    Say ''
    Say 'Installing Family Fix-It' 'Cyan'
    Say 'This takes about a minute. You do not need to do anything.'
    if (Test-InstallElevated) { Say 'Note: this window is running as administrator. It is better to run this as yourself (just double-click it).' 'Yellow' }

    Say '1 of 5: Getting the list of files ...'
    $manifest = $null
    try { $manifest = Read-InstallManifest -Json (Get-InstallText -Url ($Base.TrimEnd('/') + '/manifest.json')) }
    catch {
        Write-InstallLog ('Manifest problem: ' + $_.Exception.Message) 'ERROR'
        $msg = $_.Exception.Message
        if ($msg -notmatch '^The download list') { $msg = 'Could not reach the download page. Please check that the internet is working, then run this again.' }
        return (New-InstallResult $false 'Could not install' $msg)
    }
    $old = Get-InstalledVersion $Dir
    $what = 'Installing version ' + $manifest.Version
    if ($old -and $old -eq $manifest.Version) { $what = 'Checking and repairing version ' + $manifest.Version }
    elseif ($old) { $what = 'Updating from version ' + $old + ' to ' + $manifest.Version }
    Say ('   ' + $what)

    if ($script:InstallDry) {
        Write-InstallLog 'Practice run: nothing is changed'
        Say ''
        Say 'Practice run only - nothing was changed. This is what would happen:' 'Yellow'
        Say ('   - download and check {0} files into {1}' -f @($manifest.Files).Count, $Dir)
        Say '   - close a Family Fix-It window that is still open on the old version'
        Say ('   - make a "{0}" shortcut on the Desktop and in the Start menu' -f $script:ShortcutName)
        Say ('   - make a "{0}" shortcut in the Start menu (it only checks the fixes and changes nothing)' -f $script:TestShortcutName)
        Say '   - register the familyfixit: link (familyfixit://open) for this Windows user'
        Say '   - turn on the pop-up watcher (Guardian) and the weekly check-in'
        if ($Launch) { Say '   - open Family Fix-It' }
        return (New-InstallResult $true 'Practice run' 'Practice run only - nothing was changed.' $manifest.Version $false)
    }

    Say '2 of 5: Downloading and checking the files ...'
    try {
        if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
        $changed = @(Install-FixItFiles -Manifest $manifest -Base $Base -Dir $Dir)
    } catch {
        Write-InstallLog ('Install failed: ' + $_.Exception.Message) 'ERROR'
        $msg = $_.Exception.Message
        if ($msg -notmatch 'could not be downloaded|safety check') { $msg = 'The files could not be saved on this computer. Please tell Trey.' }
        return (New-InstallResult $false 'Could not install' $msg)
    }
    if ($changed.Count -eq 0) { Say '   Everything was already up to date.' } else { Say ('   Installed: ' + ($changed -join ', ')) }

    Say '3 of 5: Making the shortcuts ...'
    $n = Set-InstallShortcuts -Dir $Dir
    if ($n -eq 0) { Say '   I could not make the shortcut. You can still open Family Fix-It from the folder.' 'Yellow' }
    $linked = $false
    try { $linked = [bool](Register-InstallLaunchLink -Dir $Dir) } catch { Write-InstallLog ('Launch link: ' + $_.Exception.Message) 'WARN' }
    if (-not $linked) { Say '   I could not add the open link. You can still open Family Fix-It from the Desktop shortcut.' 'Yellow' }

    Say '4 of 5: Turning on the pop-up watcher and the weekly check-in ...'
    $warn = @()
    if ($old -and ($changed -contains 'FamilyFixIt.ps1')) {
        # new program file: restart a watcher that is running the old one (Off, then On)
        try { [void](Invoke-InstalledAction -Dir $Dir -Action 'GuardianOff') } catch { Write-InstallLog ('GuardianOff: ' + $_.Exception.Message) 'WARN' }
    }
    foreach ($a in @(@('GuardianOn', 'the pop-up watcher'), @('CheckInOn', 'the weekly check-in'))) {
        $code = 1
        try { $code = Invoke-InstalledAction -Dir $Dir -Action $a[0] } catch { Write-InstallLog ('{0}: {1}' -f $a[0], $_.Exception.Message) 'WARN' }
        Write-InstallLog ('Action {0} exit code {1}' -f $a[0], $code)
        if ($code -ne 0) { $warn += $a[1] }
    }
    foreach ($w in $warn) { Say ('   I could not turn on {0}. You can switch it on inside Family Fix-It.' -f $w) 'Yellow' }
    if (-not $old) {
        # a FRESH install only (never an update): leave a note so the first normal window shows the "What's shared" window once.
        # The installer shows nothing itself and never waits for it, so a silent install (-Yes) cannot hang.
        $fr = 1
        try { $fr = Invoke-InstalledAction -Dir $Dir -Action 'FirstRunPending' } catch { Write-InstallLog ('FirstRunPending: ' + $_.Exception.Message) 'WARN' }
        Write-InstallLog ('Action FirstRunPending exit code {0}' -f $fr)
    }

    Say '5 of 5: Opening Family Fix-It ...'
    if ($Launch) { try { Start-InstalledTool -Dir $Dir } catch { Write-InstallLog ('Launch: ' + $_.Exception.Message) 'WARN'; Say ('   I could not open it automatically. Double-click "{0}" on your Desktop.' -f $script:ShortcutName) 'Yellow' } }

    $final = @(
        'All done!',
        ('Family Fix-It is on your Desktop and in the Start menu (look for "{0}").' -f $script:ShortcutName),
        'If a scary page ever takes over your whole screen, press Ctrl + Shift + F.'
    ) -join "`r`n"
    Say ''
    Say $final 'Green'
    return (New-InstallResult $true 'Installed' $final $manifest.Version ($changed.Count -gt 0))
}

# ----- go --------------------------------------------------------------------
if (-not $LibraryOnly) {
    if ($LogPath) { $script:InstallLog = $LogPath }
    else { $d0 = Get-InstallDefaultDir; $script:InstallLog = Join-Path $d0 ('logs\install-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd')) }
    try { $ld = Split-Path -Parent $script:InstallLog; if ($ld -and -not (Test-Path -LiteralPath $ld)) { New-Item -ItemType Directory -Path $ld -Force | Out-Null } } catch { $script:InstallLog = '' }
    Write-InstallLog ('Installer {0} started{1}' -f $script:InstallerVersion, $(if ($script:InstallDry) { ' (practice run)' } else { '' }))
    $script:InstallResult = $null
    try { $script:InstallResult = Install-FamilyFixIt -Base $BaseUrl -Dir $InstallDir -Launch (-not $NoLaunch) }
    catch {
        Write-InstallLog ('Unexpected problem: ' + $_.Exception.Message) 'ERROR'
        $script:InstallResult = New-InstallResult $false 'Could not install' 'Something unexpected went wrong. Please tell Trey.'
    }
    if (-not $script:InstallResult.Ok) {
        Write-Host ''
        Write-Host ('Sorry - ' + $script:InstallResult.Message) -ForegroundColor Red
        if ($script:InstallLog) { Write-Host ('(Details are saved in: ' + $script:InstallLog + ')') }
    }
    Write-InstallLog ('Installer finished: ok={0}' -f $script:InstallResult.Ok)
    $global:FixItInstallExitCode = $(if ($script:InstallResult.Ok) { 0 } else { 1 })
    if ($PSCommandPath) { if ($script:InstallResult.Ok) { exit 0 } else { exit 1 } }
}
