<#
Family Fix-It  -  a small self-repair tool for Windows.
Fixes: printer, Acrobat in Outlook, Outlook, internet, slow computer, sound/mic/camera,
browser clean-up, Windows Update, OneDrive; a red "scary pop-up" button; screen sharing with Trey
(Zoho Assist); and a report that is saved on the Desktop and sent to Trey. See README.md.

Run with no options to open the friendly window.
Command-line use (for Trey):
  FamilyFixIt.ps1 -Action Printer|Acrobat|AcrobatRepair|Outlook|Network|Slow|Sound|Browser|WinUpdate|OneDrive|Scam|Screen|Report|Pin|Update [-WhatIf]
  -WhatIf (alias -DryRun) shows what would happen and changes nothing (nothing is sent either).
  -Test (Test mode) runs the normal window and questions but only CHECKS each change step (PASS/WARN/FAIL); -Action TestAll checks every button.
  -ReportUrl overrides the address that reports are sent to.
  Guardian (runs at sign-in, hidden) watches for a full-screen browser page and offers a way out; GuardianOn/GuardianOff/GuardianDemo.
#>
param(
    [ValidateSet('Gui', 'TestAll', 'Printer', 'Acrobat', 'AcrobatRepair', 'Outlook', 'Network', 'Slow', 'Sound', 'Browser', 'WinUpdate', 'OneDrive', 'Scam', 'Screen', 'Report', 'Pin', 'Update', 'Restart', 'Status', 'Undo', 'CheckIn', 'CheckInOn', 'CheckInOff', 'HealthCheck', 'History', 'Files', 'Install', 'Guardian', 'GuardianOn', 'GuardianOff', 'GuardianDemo', 'PCInfo', 'Guides', 'Simple',
        'PrinterAdmin', 'AcrobatAdmin', 'AcrobatRepairAdmin', 'NetworkAdmin', 'SlowAdmin', 'SoundAdmin', 'OutlookAdmin', 'DefenderScanAdmin', 'WinUpdateAdmin', 'WinUpdateDeepAdmin', 'UndoAdmin')]
    [string]$Action = 'Gui',
    [Alias('DryRun')][switch]$WhatIf,
    [string]$LogPath,
    [string]$ResultFile,
    [string]$ManifestUrl,
    [string]$ReportUrl,
    [string]$InputFile,
    [string]$Query,
    [string]$App,
    [string]$OutputDir,
    [switch]$NoUpdateCheck,
    [switch]$Yes,
    [switch]$Test,
    [switch]$LibraryOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
$script:FixItVersion = '2.3.4'
$script:DefaultManifestUrl = 'https://raw.githubusercontent.com/Sodapopnewb/family-it-fixit/main/manifest.json'
$script:OwnerPlaceholder = ('<' + 'OWNER>')   # the guards compare with this; Publish never rewrites it
# Where reports are sent (a small Cloudflare Worker that Trey runs). The app header is NOT a secret.
$script:DefaultReportUrl = 'https://fixit-report.hg-fixit.workers.dev/report'
$script:AppHeader = 'family-it-fixit'
# "Let Trey see my screen": Zoho Assist's page where a customer types the code Trey gives them.
$script:ScreenShareUrl = 'https://join.zoho.com/'
# Microsoft's public service status (used by Is it just me?).
$script:StatusFeedUrl = 'https://status.cloud.microsoft/api/feed/mac'
$script:AllowedUpdateFiles = @('FamilyFixIt.ps1', 'Start-FixIt.cmd', 'README.md', 'guides.json')
# Pictures listed under "assets" in manifest.json. They are NOT in "files" because older versions refuse any unknown file there (they could not update).
$script:AllowedAssetFiles = @('FamilyFixIt.ico')
$script:IconFileName = 'FamilyFixIt.ico'
$script:ShortcutFileName = 'Family Fix-It.lnk'
$script:TestShortcutFileName = 'Family Fix-It (Test mode).lnk'   # Start menu only; opens the window in Test mode (-Test)
$script:SelfPath = $PSCommandPath
$script:InstallDir = $PSScriptRoot
$script:DryRun = [bool]$WhatIf
# Test mode (-Test, or -Action TestAll): every change step is only CHECKED, never run. It builds on practice mode (-WhatIf).
$script:TestMode = ([bool]$Test -or $Action -eq 'TestAll')
if ($script:TestMode) { $script:DryRun = $true }
$winDir = $env:SystemRoot
if (-not $winDir) { $winDir = 'C:\Windows' }
$script:SpoolFolder = $winDir.TrimEnd('\') + '\System32\spool\PRINTERS'
$script:EchoLog = $false
$script:GuiActive = $false
# Background work (the installer, the sign-in watcher, the weekly check-in, the administrator parts) has nobody at the keyboard.
# It must never ask a question: a hidden window that waits for typing waits forever.
$script:BackgroundActions = @('Guardian', 'GuardianOn', 'GuardianOff', 'CheckInOn', 'CheckInOff', 'HealthCheck', 'PrinterAdmin', 'AcrobatAdmin', 'AcrobatRepairAdmin', 'NetworkAdmin', 'SlowAdmin', 'SoundAdmin', 'OutlookAdmin', 'DefenderScanAdmin', 'WinUpdateAdmin', 'WinUpdateDeepAdmin', 'UndoAdmin')
$script:Background = $false
$script:AssumeYes = [bool]$Yes
$script:AddinName = 'PDFMaker.OfficeAddin'
$script:OfficeVersions = @('16.0', '15.0', '14.0')
$script:LogFile = $null

if ($ManifestUrl) { $script:ManifestUrl = $ManifestUrl } else { $script:ManifestUrl = $script:DefaultManifestUrl }
if ($ReportUrl) { $script:ReportUrl = $ReportUrl } else { $script:ReportUrl = $script:DefaultReportUrl }

# ---------------------------------------------------------------------------
# Logging and small helpers
# ---------------------------------------------------------------------------
function Initialize-FixItLog {
    if ($LogPath) {
        $script:LogFile = $LogPath
    } else {
        $base = $env:LOCALAPPDATA
        if (-not $base) { $base = [IO.Path]::GetTempPath() }
        $dir = Join-Path $base 'FamilyFixIt\logs'
        $script:LogFile = Join-Path $dir ('fixit-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
    }
    try {
        $dir = Split-Path -Parent $script:LogFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    } catch { }
}

function Write-FixItLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:LogFile) {
        try { [IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false))) } catch { }
    }
    if ($script:EchoLog) { Write-Host $line }
}

function New-FixItResult {
    param([bool]$Ok, [string]$Title, [string]$Message, [string[]]$Details = @(), [hashtable]$Extra = @{})
    $r = [ordered]@{ Ok = $Ok; Title = $Title; Message = $Message; Details = @($Details) }
    foreach ($k in $Extra.Keys) { $r[$k] = $Extra[$k] }
    return [pscustomobject]$r
}

# Run one change. In practice mode (-WhatIf) it only logs what it would do.
# Returns $true when it worked (or would have), $false when it failed.
function Invoke-FixItStep {
    param([string]$Description, [scriptblock]$Do)
    if ($script:TestMode) { return (Invoke-FixItTestStep -Description $Description -Do $Do) }
    if ($script:DryRun) {
        Write-FixItLog ('Would do: {0}' -f $Description) 'DRYRUN'
        return $true
    }
    Write-FixItLog ('Doing: {0}' -f $Description)
    try {
        & $Do | Out-Null
        Write-FixItLog ('Done: {0}' -f $Description)
        return $true
    } catch {
        Write-FixItLog ('FAILED: {0} -- {1}' -f $Description, $_.Exception.Message) 'ERROR'
        return $false
    }
}

# ---------------------------------------------------------------------------
# Test mode (-Test): the normal window and questions, but every change step becomes a read-only check
# that says whether the step COULD work here. Nothing is changed, closed, restarted or sent.
#   - Every adapter that changes something starts with:  if ($script:TestMode) { Invoke-FixItProbe ... }
#   - Invoke-FixItProbe only answers inside Invoke-FixItStep (a checked step). Anywhere else it THROWS,
#     so a change that is not behind a checked step cannot run in Test mode.
#   - Invoke-FixItStep in Test mode runs the step's code with the adapters in "check" mode and records
#     PASS / WARN / FAIL for the step. The checklist is shown at the end of each button.
# ---------------------------------------------------------------------------
$script:TestAll = $false
$script:InProbe = $false
$script:ProbeResults = $null
$script:TestRecords = New-Object System.Collections.ArrayList
$script:TestLastReportPreview = ''

function New-FixItProbeResult {
    param([string]$Status, [string]$Text)
    return [pscustomobject]@{ Status = $Status; Text = $Text }
}

function Get-FixItWorstStatus {
    param($Statuses)
    $s = @($Statuses)
    if ($s -contains 'FAIL') { return 'FAIL' }
    if ($s -contains 'WARN') { return 'WARN' }
    return 'PASS'
}

# Called by every changing adapter in Test mode. Records a check; refuses when not inside a checked step.
function Invoke-FixItProbe {
    param([string]$Adapter, $Arguments = $null)
    if (-not $script:InProbe) {
        Write-FixItLog ('TEST MODE BLOCKED: {0} tried to change something outside a checked step' -f $Adapter) 'ERROR'
        throw ('Test mode: {0} tried to change something outside a checked step. Nothing was changed.' -f $Adapter)
    }
    $found = @()
    try { $found = @(Get-FixItPreflight -Adapter $Adapter -Arguments $Arguments) }
    catch { $found = @((New-FixItProbeResult 'FAIL' ('could not be checked: {0}' -f $_.Exception.Message))) }
    foreach ($f in $found) { if ($null -ne $f) { [void]$script:ProbeResults.Add($f) } }
}

# The Test-mode version of Invoke-FixItStep. Always returns $true so the rest of the button is checked too.
function Invoke-FixItTestStep {
    param([string]$Description, [scriptblock]$Do)
    Write-FixItLog ('Test mode - checking: {0}' -f $Description) 'TEST'
    $prevIn = $script:InProbe
    $prevRes = $script:ProbeResults
    $script:InProbe = $true
    $script:ProbeResults = New-Object System.Collections.ArrayList
    try { & $Do | Out-Null }
    catch {
        $m = $_.Exception.Message
        if ($_.Exception.InnerException) { $m = $_.Exception.InnerException.Message }
        [void]$script:ProbeResults.Add((New-FixItProbeResult 'FAIL' ('the check stopped: {0}' -f $m)))
    }
    finally {
        $mine = @($script:ProbeResults)
        $script:InProbe = $prevIn
        $script:ProbeResults = $prevRes
    }
    $uniq = New-Object System.Collections.ArrayList; $seenText = @{}
    foreach ($m1 in $mine) { $kk = ('{0}|{1}' -f $m1.Status, $m1.Text); if (-not $seenText.ContainsKey($kk)) { $seenText[$kk] = $true; [void]$uniq.Add($m1) } }
    $mine = @($uniq)
    if ($mine.Count -eq 0) { $mine = @((New-FixItProbeResult 'PASS' 'nothing needs to be checked for this step')) }
    $st = Get-FixItWorstStatus -Statuses @($mine | ForEach-Object { $_.Status })
    [void]$script:TestRecords.Add([pscustomobject]@{ Step = $Description; Status = $st; Checks = $mine })
    foreach ($c in $mine) { Write-FixItLog ('Test mode - {0}: {1} - {2}' -f $c.Status, $Description, ($c.Text -replace '\s+', ' ')) 'TEST' }
    return $true
}

# What the normal window would have said, for the checklist ("Practice run" is only Test mode's own wording, so it is left out).
function Get-FixItTestSaid {
    param($Result)
    if ($null -eq $Result) { return '' }
    if ([string]$Result.Title -eq 'Practice run') { return '' }
    return ('{0} - {1}' -f $Result.Title, $Result.Message)
}

# One check that is not a step (for example "can the report address be reached?").
function Add-FixItTestNote {
    param([string]$Step, [string]$Status, [string]$Text)
    [void]$script:TestRecords.Add([pscustomobject]@{ Step = $Step; Status = $Status; Checks = @((New-FixItProbeResult $Status $Text)) })
}

# ----- read-only facts the checks use (replaceable in the tests) -----
function Test-FixItCanElevate {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        foreach ($g in @($id.Groups)) { if ([string]$g.Value -eq 'S-1-5-32-544') { return $true } }
    } catch { }
    return $false
}
function Test-FixItCommandPresent { param([string]$Name) return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue) }
function Test-FixItUriHandler {
    param([string]$Scheme)
    try { return [bool](Test-Path -LiteralPath ('Registry::HKEY_CLASSES_ROOT\' + $Scheme)) } catch { return $false }
}
function Test-FixItProcessExists { param([int]$Id) return [bool](Get-Process -Id $Id -ErrorAction SilentlyContinue) }
# Does the registry key exist, can it be written (asks Windows for write access but writes nothing), does it need administrator rights?
function Get-FixItRegAccess {
    param([string]$Path)
    $needsAdmin = ($Path -match '(?i)^(HKLM:|Registry::HKEY_LOCAL_MACHINE|HKEY_LOCAL_MACHINE)')
    $exists = $false; try { $exists = [bool](Test-Path -LiteralPath $Path) } catch { }
    $near = $Path
    while ($near -and -not (Test-Path -LiteralPath $near -ErrorAction SilentlyContinue)) {
        $up = Split-Path -Parent $near
        if ($up -eq $near) { $near = ''; break }
        $near = $up
    }
    $canWrite = $false
    if (-not $needsAdmin -and $near) {
        $sub = ($near -replace '^(HKCU:|HKEY_CURRENT_USER|Registry::HKEY_CURRENT_USER)\\?', '')
        try {
            $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sub, $true)
            if ($null -ne $k) { $canWrite = $true; $k.Close() }
        } catch { $canWrite = $false }
    }
    return [pscustomobject]@{ Exists = $exists; NearestExists = [bool]$near; CanWrite = $canWrite; NeedsAdmin = $needsAdmin }
}
# Can this existing file be opened for writing? (Opens it and closes it again. Writes nothing.)
function Test-FixItFileWritable {
    param([string]$Path)
    try { $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite); $fs.Close(); return $true } catch { return $false }
}
# Only asks whether the address answers (no data is sent to it).
function Test-FixItReportReachable {
    param([string]$Url)
    try {
        $u = New-Object System.Uri($Url)
        return (Test-FixItHttps -Url ($u.Scheme + '://' + $u.Host + '/'))
    } catch { return $false }
}

# Administrator rights: PASS when already on, or when this account is allowed to say yes to Windows' question (nothing is elevated here).
function Get-FixItAdminCheck {
    param([string]$What)
    if (Test-FixItAdmin) { return (New-FixItProbeResult 'PASS' 'administrator rights are already on') }
    if (Test-FixItCanElevate) { return (New-FixItProbeResult 'PASS' ('{0} needs administrator permission. Windows will ask, and this account is allowed to say yes' -f $What)) }
    return (New-FixItProbeResult 'FAIL' ('{0} needs administrator permission, and this account is not allowed to give it' -f $What))
}

function Get-FixItNativeNeedsAdmin {
    param([string]$File, [string[]]$Arguments)
    $f = ([IO.Path]::GetFileName($File)).ToLowerInvariant()
    $a = (@($Arguments) -join ' ').ToLowerInvariant()
    if ($f -in @('dism.exe', 'sfc.exe')) { return $true }
    if ($f -eq 'netsh.exe') { return $true }
    if ($f -eq 'ipconfig.exe') { return $true }
    return $false
}
# Programs that only READ something may run in Test mode (everything else is checked, never run).
function Test-FixItNativeReadOnly {
    param([string]$File, [string[]]$Arguments)
    $f = ([IO.Path]::GetFileName($File)).ToLowerInvariant()
    $first = ''; if (@($Arguments).Count -gt 0) { $first = ([string]@($Arguments)[0]).ToLowerInvariant() }
    if ($f -eq 'schtasks.exe' -and $first -eq '/query') { return $true }
    if ($f -eq 'winget.exe' -and $first -eq 'list') { return $true }
    return $false
}

function Get-FixItPreflight {
    param([string]$Adapter, $Arguments = $null)
    $A = @{}
    if ($null -ne $Arguments) { foreach ($k in @($Arguments.Keys)) { $A[[string]$k] = $Arguments[$k] } }
    $o = New-Object System.Collections.ArrayList
    $pass = { param($t) [void]$o.Add((New-FixItProbeResult 'PASS' $t)) }
    $warn = { param($t) [void]$o.Add((New-FixItProbeResult 'WARN' $t)) }
    $fail = { param($t) [void]$o.Add((New-FixItProbeResult 'FAIL' $t)) }
    $admin = { param($t) [void]$o.Add((Get-FixItAdminCheck -What $t)) }
    $need = { param($cmd) if (Test-FixItCommandPresent -Name $cmd) { & $pass ('{0} is available' -f $cmd) } else { & $fail ('{0} was not found on this PC' -f $cmd) } }
    switch ($Adapter) {
        { $_ -in @('Set-RegDword', 'Set-RegString', 'Remove-RegValue', 'Restore-FixItRegValue') } {
            $path = [string]$A['Path']; $name = [string]$A['Name']
            $acc = Get-FixItRegAccess -Path $path
            $removing = ($_ -eq 'Remove-RegValue') -or ($_ -eq 'Restore-FixItRegValue' -and $A.ContainsKey('Existed') -and -not [bool]$A['Existed'])
            if ($removing -and ($null -eq (Get-RegValue -Path $path -Name $name))) { & $pass ('the setting "{0}" is not there, so there is nothing to remove' -f $name); break }
            if ($acc.Exists) { & $pass ('the setting location exists ({0})' -f $path) }
            elseif ($acc.NearestExists) { & $pass ('the setting location does not exist yet, but it can be created ({0})' -f $path) }
            else { & $fail ('the setting location was not found ({0})' -f $path) }
            if ($acc.NeedsAdmin) { & $admin 'changing this setting' }
            elseif ($acc.CanWrite) { & $pass 'this user is allowed to change the setting' }
            else { & $fail 'this user is not allowed to change the setting' }
            break
        }
        { $_ -in @('Stop-FixItService', 'Start-FixItService', 'Set-FixItServiceStartType') } {
            $n = [string]$A['Name']; $st = Get-FixItServiceStatus -Name $n
            if ($st -eq 'Missing') { & $fail ('the Windows service "{0}" was not found' -f $n) } else { & $pass ('the Windows service "{0}" exists (it is {1})' -f $n, $st) }
            & $admin 'controlling a Windows service'
            break
        }
        { $_ -in @('Stop-SpoolerService', 'Start-SpoolerService') } {
            $st = Get-FixItServiceStatus -Name 'Spooler'
            if ($st -eq 'Missing') { & $fail 'the Print Spooler service was not found' } else { & $pass ('the Print Spooler service exists (it is {0})' -f $st) }
            & $admin 'controlling the Print Spooler'
            break
        }
        'Remove-SpoolFile' {
            if (Test-Path -LiteralPath ([string]$A['FullName'])) { & $pass 'the stuck print file exists' } else { & $warn 'the stuck print file is already gone' }
            & $admin 'clearing the print queue folder'
            break
        }
        { $_ -in @('Remove-FixItPrinter', 'Set-FixItDefaultPrinter') } {
            $n = [string]$A['Name']; $have = @()
            try { $have = @(Get-FixItPrinters | Where-Object { $_.Name -eq $n }) } catch { & $warn ('the printer list could not be read: {0}' -f $_.Exception.Message); break }
            if ($have.Count -gt 0) { & $pass ('the printer "{0}" exists' -f $n) } else { & $fail ('the printer "{0}" was not found' -f $n) }
            & $need 'Get-Printer'
            break
        }
        'Add-FixItPrinterConnection' {
            $n = [string]$A['Name']; $srv = ''
            if ($n.StartsWith('\\')) { $srv = ($n.TrimStart('\') -split '\\')[0] }
            if ($srv) { if (Test-HostReachable -ComputerName $srv) { & $pass ('the print server "{0}" answers' -f $srv) } else { & $warn ('the print server "{0}" did not answer just now' -f $srv) } }
            & $need 'Add-Printer'
            break
        }
        'Stop-FixItApp' {
            if (Test-FixItProcessExists -Id ([int]$A['Id'])) { & $pass 'the program is running and could be closed' } else { & $warn 'the program is not running any more' }
            break
        }
        'Request-AppClose' {
            $n = @(Get-RunningApp -ProcessNames @($A['ProcessNames'])).Count
            if ($n -gt 0) { & $pass ('{0} program(s) are running and could be asked to close' -f $n) } else { & $pass 'none of those programs are running' }
            break
        }
        'Stop-FixItAppsByName' {
            $n = @(Get-RunningApp -ProcessNames @($A['ProcessNames'])).Count
            if ($n -gt 0) { & $pass ('{0} program(s) are running and could be ended' -f $n) } else { & $pass 'none of those programs are running' }
            break
        }
        'Stop-FixItProcessForce' {
            if (Test-FixItProcessExists -Id ([int]$A['Id'])) { & $pass 'the program is running and could be ended' } else { & $warn 'the program is not running any more' }
            break
        }
        'Clear-FixItFolder' {
            $p = [string]$A['Path']
            if (-not (Test-SafeCleanPath -Path $p)) { & $fail ('this folder is not on the safe list: {0}' -f $p); break }
            if (Test-Path -LiteralPath $p) { & $pass ('the folder exists ({0})' -f $p) } else { & $pass ('the folder is not there, so there is nothing to clear ({0})' -f $p) }
            if ($p -match '(?i)^[A-Z]:\\Windows\\') { & $admin 'clearing this folder' } else { & $pass 'this is the user''s own folder, so no extra permission is needed' }
            break
        }
        'Clear-FixItRecycleBin' { & $need 'Clear-RecycleBin'; break }
        'Restart-FixItAdapter' {
            $n = [string]$A['Name']; $have = @()
            try { $have = @(Get-FixItAdapters) } catch { }
            if ($have -contains $n) { & $pass ('the network adapter "{0}" exists and is up' -f $n) } else { & $fail ('the network adapter "{0}" was not found' -f $n) }
            & $need 'Restart-NetAdapter'
            & $admin 'restarting the network adapter'
            break
        }
        { $_ -in @('Restart-FixItNow', 'Restart-FixItComputer') } { & $need 'shutdown.exe'; & $pass 'any user may restart the computer'; break }
        'Set-FixItAudioDevice' {
            $d = $null; try { $d = Get-FixItAudioDevice -Kind ([string]$A['Kind']) } catch { }
            if ($null -ne $d) { & $pass ('the {0} "{1}" was found' -f ([string]$A['Kind']).ToLowerInvariant(), $d.Name) } else { & $fail ('no {0} was found' -f ([string]$A['Kind']).ToLowerInvariant()) }
            break
        }
        { $_ -in @('Start-FixItOutlook', 'Start-FixItOutlookSafe') } {
            $ol = $null; try { $ol = Get-OutlookInfo } catch { }
            if ($null -ne $ol -and $ol.Installed -and $ol.Path) { & $pass ('Outlook was found ({0})' -f $ol.Path) } else { & $fail 'Outlook was not found on this PC' }
            break
        }
        'Open-FixItSettings' {
            $sch = ([string]$A['Uri'] -replace ':.*$', '')
            if (Test-FixItUriHandler -Scheme $sch) { & $pass ('Windows knows how to open "{0}" pages' -f $sch) } else { & $fail ('Windows has no handler for "{0}" pages' -f $sch) }
            break
        }
        'Open-FixItUrl' {
            if (Test-FixItUriHandler -Scheme 'https') { & $pass 'Windows has a web browser for https pages' } else { & $fail 'Windows has no web browser set for https pages' }
            break
        }
        'Open-FixItBrowserPage' {
            $e = [string]$A['Exe']
            if (Test-FixItCommandPresent -Name $e) { & $pass ('{0} was found' -f $e) } else { & $fail ('{0} was not found on this PC' -f $e) }
            break
        }
        'Open-FixItFile' {
            if (Test-FixItCommandPresent -Name 'notepad.exe') { & $pass 'Notepad is available' } else { & $fail 'Notepad was not found' }
            if (Test-Path -LiteralPath ([string]$A['Path'])) { & $pass 'the file exists' } else { & $warn 'the file does not exist yet' }
            break
        }
        { $_ -in @('Open-FixItUserFile', 'Show-FixItFileInFolder') } {
            if (Test-Path -LiteralPath ([string]$A['Path'])) { & $pass 'the file exists' } else { & $fail 'the file was not found' }
            break
        }
        'Copy-FixItBackup' {
            if (Test-Path -LiteralPath ([string]$A['Source'])) { & $pass 'the file to back up exists' } else { & $pass 'the file to back up is not there, so nothing needs saving' }
            $dd = [string]$A['DestDir']
            if ((Test-Path -LiteralPath $dd) -or (Test-Path -LiteralPath (Split-Path -Parent $dd))) { & $pass 'the backup folder exists or can be made' } else { & $fail 'the backup folder cannot be made here' }
            break
        }
        'Start-FixItDefenderScan' {
            & $need 'Start-MpScan'
            $svc = Get-FixItServiceStatus -Name 'WinDefend'
            if ($svc -eq 'Missing') { & $warn 'Microsoft Defender was not found (another virus program may be in charge)' } else { & $pass ('Microsoft Defender exists (it is {0})' -f $svc) }
            break
        }
        { $_ -in @('Start-FixItOneDriveReset', 'Start-FixItOneDrive') } {
            if ($A['Exe'] -and (Test-Path -LiteralPath ([string]$A['Exe']))) { & $pass 'OneDrive was found' } else { & $fail 'OneDrive was not found' }
            break
        }
        'Register-FixItTask' { & $need 'schtasks.exe'; & $pass 'a task for this user needs no extra permission'; break }
        'Unregister-FixItTask' {
            & $need 'schtasks.exe'
            if (Test-FixItTask -Name ([string]$A['Name'])) { & $pass ('the task "{0}" exists' -f $A['Name']) } else { & $pass ('the task "{0}" is not there, so there is nothing to remove' -f $A['Name']) }
            break
        }
        'Install-FixItApp' { & $need 'winget.exe'; break }
        'Invoke-Msi' {
            & $need 'msiexec.exe'
            & $admin 'repairing a program'
            break
        }
        'Install-FixItUpdate' {
            $dir = $script:InstallDir
            $main = ''; if ($dir) { $main = Join-Path $dir 'FamilyFixIt.ps1' }
            if ($main -and (Test-Path -LiteralPath $main)) {
                if (Test-FixItFileWritable -Path $main) { & $pass 'the program file can be replaced by the update' } else { & $fail 'the program file cannot be replaced (it is locked or read-only)' }
            } else { & $warn 'the program folder is not known here' }
            break
        }
        'Save-WebFile' { & $pass 'a download would be saved in a temporary folder'; break }
        'Send-WebReport' {
            $url = [string]$A['Url']; $json = [string]$A['Json']
            $bytes = (New-Object Text.UTF8Encoding($false)).GetByteCount($json)
            if (Test-FixItReportReachable -Url $url) { & $pass ('the report address answers ({0})' -f $url) } else { & $warn ('the report address did not answer just now ({0}); a real report would be saved on the Desktop instead' -f $url) }
            $preview = ''
            try {
                $obj = $json | ConvertFrom-Json
                $lines = @(([string]$obj.report) -split "`r?`n")
                $first = @($lines | Select-Object -First 14)
                $preview = ('This is what WOULD be sent ({0} bytes; PC name {1}, version {2}). The first {3} of {4} lines:' -f $bytes, $obj.pcName, $obj.version, $first.Count, $lines.Count) + "`n" + (($first | ForEach-Object { '    | ' + $_ }) -join "`n")
            } catch { $preview = ('This is what WOULD be sent: {0} bytes (nothing is sent in Test mode)' -f $bytes) }
            $script:TestLastReportPreview = $preview
            & $pass ($preview + "`n" + 'Nothing is sent in Test mode.')
            break
        }
        'Write-FixItTextFile' {
            $dir = Split-Path -Parent ([string]$A['Path'])
            if ($dir -and (Test-Path -LiteralPath $dir)) { & $pass ('the folder exists ({0})' -f $dir) } else { & $fail ('the folder was not found ({0})' -f $dir) }
            break
        }
        { $_ -in @('Rename-FixItFolderAside', 'Restore-FixItFolder') } {
            $p = [string]$A['Path']
            if ($_ -eq 'Restore-FixItFolder') { if (Test-Path -LiteralPath ([string]$A['Aside'])) { & $pass 'the saved folder exists' } else { & $fail 'the saved folder is gone' } }
            elseif (Test-Path -LiteralPath $p) { & $pass ('the folder exists ({0})' -f $p) } else { & $pass ('the folder is not there, so there is nothing to set aside ({0})' -f $p) }
            & $admin 'changing a Windows folder'
            break
        }
        'Restore-FixItFile' {
            if (Test-Path -LiteralPath ([string]$A['Backup'])) { & $pass 'the saved copy exists' } else { & $fail 'the saved copy is gone' }
            if (Test-Path -LiteralPath (Split-Path -Parent ([string]$A['Original']))) { & $pass 'the folder for the original exists' } else { & $fail 'the folder for the original was not found' }
            break
        }
        'Clear-FixItBrowserSessions' {
            $n = 0; try { $n = @(Get-FixItSessionTargets).Count } catch { }
            & $pass ('{0} browser "restore pages" file(s) would be set aside (a backup is made first)' -f $n)
            break
        }
        'Start-FixItGuardianProcess' {
            if ($script:SelfPath -and (Test-Path -LiteralPath $script:SelfPath)) { & $pass 'the program file for the watcher exists' } else { & $fail 'the program file for the watcher was not found' }
            & $need 'powershell.exe'
            break
        }
        'Stop-FixItGuardianProcess' { & $pass 'the watcher could be stopped (it is only this tool''s own helper)'; break }
        'Repair-FixItIcon' { & $pass 'the shortcut icon could be refreshed'; break }
        'Invoke-FixItNative' {
            $file = [string]$A['File']; $args2 = @($A['Arguments'])
            & $need $file
            if (Get-FixItNativeNeedsAdmin -File $file -Arguments $args2) { & $admin ('running {0}' -f $file) } else { & $pass 'no administrator permission is needed' }
            break
        }
        default { & $warn ('no check is written for "{0}" yet' -f $Adapter) }
    }
    return @($o)
}

# ----- the checklist -----
function Format-FixItTestChecklist {
    param([string]$Title, $Records, [string]$Said = '')
    $recs = @($Records)
    $overall = Get-FixItWorstStatus -Statuses @($recs | ForEach-Object { $_.Status })
    $o = New-Object System.Collections.Generic.List[string]
    $o.Add(('TEST MODE - {0}' -f $Title))
    $o.Add(('Overall: {0}   (nothing was changed on this PC)' -f $overall))
    if ($Said) { $o.Add(''); $o.Add(('The normal answer would have said: {0}' -f $Said)) }
    $o.Add('')
    if ($recs.Count -eq 0) { $o.Add('[PASS] This button changes nothing, so there was nothing to check.') }
    foreach ($r in $recs) {
        $o.Add(('[{0}] {1}' -f $r.Status, $r.Step))
        foreach ($c in @($r.Checks)) {
            $lines = @(([string]$c.Text) -split "`r?`n")
            $o.Add(('       {0}: {1}' -f $c.Status, $lines[0]))
            foreach ($l in @($lines | Select-Object -Skip 1)) { $o.Add(('           {0}' -f $l)) }
        }
    }
    return @($o)
}

function Get-FixItTestSummaryLine {
    param($Records)
    $recs = @($Records)
    $p = @($recs | Where-Object { $_.Status -eq 'PASS' }).Count
    $w = @($recs | Where-Object { $_.Status -eq 'WARN' }).Count
    $f = @($recs | Where-Object { $_.Status -eq 'FAIL' }).Count
    return ('{0} check(s): {1} PASS, {2} WARN, {3} FAIL' -f $recs.Count, $p, $w, $f)
}

function Start-FixItTestButton { $script:TestRecords = New-Object System.Collections.ArrayList }
function Get-FixItTestRecords { return @($script:TestRecords) }
# A button that never reached a change step (nothing to fix on this PC, or it stopped early) must not look like a plain PASS
# with nothing behind it: say what happened, in the checklist.
function Complete-FixItTestRecords {
    param($Result = $null)
    if (@($script:TestRecords).Count -gt 0) { return }
    if ($null -eq $Result) { Add-FixItTestNote -Step 'This button' -Status 'WARN' -Text 'it gave no answer and reached no change step'; return }
    $what = ('{0} - {1}' -f $Result.Title, $Result.Message)
    if ([string]$Result.Title -eq 'Practice run') { Add-FixItTestNote -Step 'This button' -Status 'PASS' -Text 'no change step was needed on this PC (nothing was found that needs fixing)'; return }
    if ($Result.Ok) { Add-FixItTestNote -Step 'This button' -Status 'PASS' -Text ('no change step was needed. It said: {0}' -f $what); return }
    Add-FixItTestNote -Step 'This button' -Status 'WARN' -Text ('it stopped before any change step was reached (for example, this PC does not have the program or device it fixes). It said: {0}' -f $what)
}

# The buttons that "Test all buttons" runs (every fix, the report, the restart, the undo, the toggles and the update check).
$script:TestAllKeys = @('Printer', 'Acrobat', 'AcrobatRepair', 'Outlook', 'Network', 'Slow', 'Sound', 'Browser', 'WinUpdate', 'OneDrive', 'Scam', 'Screen', 'Report', 'Update', 'Restart', 'Undo', 'CheckIn', 'Guardian', 'HealthCheck')

function Get-FixItTestResultsPath {
    $dir = $OutputDir
    if (-not $dir) { $dir = Get-DesktopFolder }
    return (Join-Path $dir ('FamilyFixIt-TestResults-{0}-{1}.txt' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm')))
}

# Runs every button's checks one after the other (questions are answered "yes" so it never waits for a person).
# Returns a list of @{ Key; Title; Status; Records; Said }.
function Invoke-FixItTestAll {
    param([scriptblock]$Progress = $null)
    $script:TestAll = $true
    $out = New-Object System.Collections.ArrayList
    try {
        $i = 0
        foreach ($k in $script:TestAllKeys) {
            $i++
            $t = (Get-FixItActionTable)[$k]
            if (-not $t) { continue }
            if ($Progress) { try { & $Progress $i $script:TestAllKeys.Count ([string]$t.Title) } catch { } }
            Start-FixItTestButton
            $said = ''
            $r = $null
            try {
                $r = Invoke-FixItAction -Which $k -SkipPlan
                $said = Get-FixItTestSaid -Result $r
            } catch {
                Add-FixItTestNote -Step ('The "{0}" button' -f $t.Title) -Status 'FAIL' -Text ('stopped early: {0}' -f $_.Exception.Message)
                Write-FixItLog ('Test all: {0} stopped: {1}' -f $k, $_.Exception.Message) 'ERROR'
            }
            Complete-FixItTestRecords -Result $r
            $recs = @(Get-FixItTestRecords)
            [void]$out.Add([pscustomobject]@{ Key = $k; Title = [string]$t.Title; Status = (Get-FixItWorstStatus -Statuses @($recs | ForEach-Object { $_.Status })); Records = $recs; Said = $said })
        }
    } finally { $script:TestAll = $false }
    return @($out)
}

function Format-FixItTestAllReport {
    param($Results)
    $res = @($Results)
    $o = New-Object System.Collections.Generic.List[string]
    $o.Add(('Family Fix-It {0} - TEST MODE results' -f $script:FixItVersion))
    $o.Add(('PC: {0}   User: {1}   Date: {2}' -f $env:COMPUTERNAME, $env:USERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm')))
    $o.Add('Nothing was changed, closed, restarted or sent on this PC. Each step was only checked.')
    $o.Add('')
    $o.Add('SUMMARY')
    foreach ($r in $res) { $o.Add(('  [{0}] {1}' -f $r.Status, $r.Title)) }
    $o.Add('')
    $o.Add('DETAILS')
    foreach ($r in $res) {
        $o.Add('')
        $o.Add('-----------------------------------------------------------------')
        foreach ($l in (Format-FixItTestChecklist -Title $r.Title -Records $r.Records -Said $r.Said)) { $o.Add($l) }
    }
    return @($o)
}

# Saves the results next to the Desktop. This is the one file Test mode writes, and only because the person asked for it.
function Save-FixItTestResults {
    param($Results)
    $path = Get-FixItTestResultsPath
    $text = (Format-FixItTestAllReport -Results $Results) -join "`r`n"
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($true)))
    Write-FixItLog ('Test mode: results saved to {0}' -f $path)
    return $path
}

# ---------------------------------------------------------------------------
# Keeping the window alive (nothing slow may run on the window's own thread)
#   - Wait-FixIt         : a wait that keeps the window responding (a plain Start-Sleep freezes it)
#   - Invoke-FixItOffUi  : runs one slow, stateless function in a background worker and keeps the window
#                          responding until it is done (slow Windows questions, web calls, programs that take a while)
#   - Test-FixItOffUiWanted : true only while the window is open and we are not already in the worker
# ---------------------------------------------------------------------------
$script:InOffUiWorker = $false
$script:OffUiBroken = $false
$script:OffUiWorkers = New-Object System.Collections.ArrayList
$script:OffUiDefaultSeconds = 180
$script:ActionBusy = $false
$script:OffUiRunner = @'
param($Self, $Log, $NeedLoad, $Cmd, $CmdArgs)
if ($NeedLoad) {
    try { . $Self -LibraryOnly -LogPath $Log } catch { throw ('FIXIT-OFFUI-LOAD: ' + $_.Exception.Message) }
    $script:LogFile = $Log
    $script:InOffUiWorker = $true
    $script:GuiActive = $false
}
& $Cmd @CmdArgs
'@

function Update-FixItUi {
    if ($script:GuiActive) { try { [System.Windows.Forms.Application]::DoEvents() } catch { } }
}

function Wait-FixIt {
    param([double]$Seconds = 0, [int]$Milliseconds = 0)
    $ms = [int]([math]::Round($Seconds * 1000)) + $Milliseconds
    if ($ms -le 0) { return }
    if ($script:InProbe) { return }   # Test mode only checks; it never waits for a change to settle
    if (-not $script:GuiActive) { Start-Sleep -Milliseconds $ms; return }
    $end = (Get-Date).AddMilliseconds($ms)
    while ($true) {
        Update-FixItUi
        $left = ($end - (Get-Date)).TotalMilliseconds
        if ($left -le 0) { break }
        [Threading.Thread]::Sleep([int][math]::Min(30, [math]::Ceiling($left)))
    }
}

function Test-FixItOffUiWanted { return ([bool]$script:GuiActive -and -not $script:InOffUiWorker -and -not $script:OffUiBroken) }

function Get-FixItOffUiWorker {
    foreach ($w in $script:OffUiWorkers) { if (-not $w.Busy) { return $w } }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [Threading.ApartmentState]::MTA
    $rs.Open()
    $w = [pscustomobject]@{ Runspace = $rs; Busy = $false; Ready = $false }
    [void]$script:OffUiWorkers.Add($w)
    return $w
}

function Remove-FixItOffUiWorker {
    param($Worker)
    [void]$script:OffUiWorkers.Remove($Worker)
    # a worker that is still busy (it took too long) is only asked to stop; an idle one is closed properly so the program can exit
    try { if ($Worker.Busy) { $Worker.Runspace.CloseAsync() } else { $Worker.Runspace.Close(); $Worker.Runspace.Dispose() } } catch { }
}

function Stop-FixItOffUiWorkers {
    foreach ($w in @($script:OffUiWorkers)) { Remove-FixItOffUiWorker -Worker $w }
}

# Runs the named function in the background worker and waits for it, keeping the window responding.
# Errors come back as errors. Too slow: the worker is abandoned and a plain "took too long" error is thrown.
# When the worker itself cannot start, it falls back (once, logged) to running the function right here.
function Invoke-FixItOffUi {
    param([string]$Command, $Arguments = $null, [int]$TimeoutSeconds = 0)
    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = $script:OffUiDefaultSeconds }
    $argTable = @{}
    if ($null -ne $Arguments) { foreach ($k in @($Arguments.Keys)) { $argTable[[string]$k] = $Arguments[$k] } }
    $w = $null; $ps = $null; $h = $null
    try {
        $w = Get-FixItOffUiWorker
        $w.Busy = $true
        $ps = [powershell]::Create()
        $ps.Runspace = $w.Runspace
        [void]$ps.AddScript($script:OffUiRunner).AddArgument($script:SelfPath).AddArgument($script:LogFile).AddArgument(-not $w.Ready).AddArgument($Command).AddArgument($argTable)
        $h = $ps.BeginInvoke()
    } catch {
        Write-FixItLog ('The background worker could not start ({0}); doing "{1}" in the window instead' -f $_.Exception.Message, $Command) 'WARN'
        $script:OffUiBroken = $true
        if ($w) { $w.Busy = $false; Remove-FixItOffUiWorker -Worker $w }
        if ($ps) { try { $ps.Dispose() } catch { } }
        return (& $Command @argTable)
    }
    $started = Get-Date
    $deadline = $started.AddSeconds($TimeoutSeconds)
    $timedOut = $false
    while (-not $h.IsCompleted) {
        Update-FixItUi
        [void]$h.AsyncWaitHandle.WaitOne(30)
        if ((Get-Date) -gt $deadline) { $timedOut = $true; break }
    }
    if ($timedOut) {
        Write-FixItLog ('Background work "{0}" took longer than {1} seconds and was left behind' -f $Command, $TimeoutSeconds) 'WARN'
        try { [void]$ps.BeginStop($null, $null) } catch { }
        Remove-FixItOffUiWorker -Worker $w
        throw ('"{0}" took too long (more than {1} seconds)' -f $Command, $TimeoutSeconds)
    }
    $result = @()
    $failure = $null
    try { $result = @($ps.EndInvoke($h)) }
    catch {
        $failure = $_.Exception
        if ($failure.InnerException) { $failure = $failure.InnerException }
    }
    $ps.Dispose()
    $w.Busy = $false
    if ($null -ne $failure) {
        if ($failure.Message -like 'FIXIT-OFFUI-LOAD:*') {
            Write-FixItLog ('The background worker could not load the program ({0}); doing "{1}" in the window instead' -f $failure.Message, $Command) 'WARN'
            $script:OffUiBroken = $true
            Remove-FixItOffUiWorker -Worker $w
            return (& $Command @argTable)
        }
        throw $failure
    }
    $w.Ready = $true
    $ms = [int]((Get-Date) - $started).TotalMilliseconds
    if ($ms -gt 2000) { Write-FixItLog ('Background work "{0}" took {1} ms (the window stayed responsive)' -f $Command, $ms) }
    foreach ($o in $result) { $o }
}

# ---------------------------------------------------------------------------
# Windows adapters. These are the only places that touch Windows itself,
# so the tests can replace them with pretend versions.
# ---------------------------------------------------------------------------
function Test-FixItAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-RegKey { param([string]$Path) return (Test-Path -LiteralPath $Path) }

function Get-RegValueNames {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @((Get-Item -LiteralPath $Path).GetValueNames() | Where-Object { $_ -ne '' })
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $key = Get-Item -LiteralPath $Path
    if ($key.GetValueNames() -notcontains $Name) { return $null }
    $v = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($v -is [byte[]]) { return , $v }
    return $v
}

function Set-RegDword {
    param([string]$Path, [string]$Name, [int]$Value)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Set-RegDword' -Arguments $PSBoundParameters; return }
    Register-FixItRegUndo -Path $Path -Name $Name
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

function Remove-RegValue {
    param([string]$Path, [string]$Name)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Remove-RegValue' -Arguments $PSBoundParameters; return }
    Register-FixItRegUndo -Path $Path -Name $Name
    Remove-ItemProperty -LiteralPath $Path -Name $Name -Force
}

function Get-SpoolerState {
    $s = Get-Service -Name 'Spooler' -ErrorAction Stop
    return [pscustomobject]@{ Status = [string]$s.Status; StartType = [string]$s.StartType }
}

function Stop-SpoolerService {
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Stop-SpoolerService' -Arguments $PSBoundParameters; return }
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Stop-SpoolerService' -Arguments $PSBoundParameters) }
    Stop-Service -Name 'Spooler' -Force -ErrorAction Stop
    $end = (Get-Date).AddSeconds(25)
    while ((Get-Service -Name 'Spooler').Status -ne 'Stopped' -and (Get-Date) -lt $end) { Wait-FixIt -Milliseconds 500 }
    if ((Get-Service -Name 'Spooler').Status -ne 'Stopped') {
        Write-FixItLog 'Print Spooler did not stop in time; ending its process' 'WARN'
        Stop-Process -Name 'spoolsv' -Force -ErrorAction SilentlyContinue
        Wait-FixIt -Seconds 2
    }
}

function Start-SpoolerService {
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Start-SpoolerService' -Arguments $PSBoundParameters; return }
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Start-SpoolerService' -Arguments $PSBoundParameters) }
    Start-Service -Name 'Spooler' -ErrorAction Stop
    $end = (Get-Date).AddSeconds(25)
    while ((Get-Service -Name 'Spooler').Status -ne 'Running' -and (Get-Date) -lt $end) { Wait-FixIt -Milliseconds 500 }
    if ((Get-Service -Name 'Spooler').Status -ne 'Running') { throw 'Print Spooler did not start' }
}

function Get-SpoolFiles {
    if (-not (Test-Path -LiteralPath $script:SpoolFolder)) { return @() }
    return @(Get-ChildItem -LiteralPath $script:SpoolFolder -File -Force -ErrorAction Stop |
        Where-Object { $_.Extension -in @('.SHD', '.SPL', '.shd', '.spl') })
}

function Remove-SpoolFile { param([string]$FullName)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Remove-SpoolFile' -Arguments $PSBoundParameters; return }
 Remove-Item -LiteralPath $FullName -Force -ErrorAction Stop }

# Waiting print jobs for one printer. Never needs administrator rights (this is NOT the spool folder).
# Tries Get-PrintJob first, then Win32_PrintJob. Document names are left out on purpose (private).
function Get-FixItPrintJobs {
    param([string]$PrinterName)
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItPrintJobs' -Arguments $PSBoundParameters) }
    $out = @()
    try {
        foreach ($j in @(Get-PrintJob -PrinterName $PrinterName -ErrorAction Stop)) {
            $sub = $null; try { $sub = [datetime]$j.SubmittedTime } catch { }
            $out += [pscustomobject]@{ Id = [int]$j.ID; Status = [string]$j.JobStatus; Submitted = $sub }
        }
        return $out
    } catch {
        $first = $_
        try {
            foreach ($j in @(Get-CimInstance -ClassName Win32_PrintJob -ErrorAction Stop)) {
                if (-not ([string]$j.Name).StartsWith($PrinterName + ',', [StringComparison]::OrdinalIgnoreCase)) { continue }
                $sub = $null; try { $sub = [datetime]$j.TimeSubmitted } catch { }
                $out += [pscustomobject]@{ Id = [int]$j.JobId; Status = [string]$j.JobStatus; Submitted = $sub }
            }
            return $out
        } catch { throw $first }
    }
}

function Get-FixItPrinters {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItPrinters' -Arguments $PSBoundParameters) }
    $result = @()
    $wmi = @{}
    try { foreach ($w in @(Get-CimInstance -ClassName Win32_Printer)) { $wmi[[string]$w.Name] = $w } } catch { }
    foreach ($p in @(Get-Printer -ErrorAction Stop)) {
        $name = [string]$p.Name
        $offline = $false
        $isDefault = $false
        if ($wmi.ContainsKey($name)) {
            $offline = [bool]$wmi[$name].WorkOffline
            $isDefault = [bool]$wmi[$name].Default
        }
        $result += [pscustomobject]@{
            Name = $name
            IsNetwork = ($name.StartsWith('\\') -or ([string]$p.Type -eq 'Connection'))
            Server = $(if ($name.StartsWith('\\')) { ($name.TrimStart('\') -split '\\')[0] } else { '' })
            PortName = [string]$p.PortName
            StatusText = [string]$p.PrinterStatus
            WorkOffline = $offline
            IsDefault = $isDefault
        }
    }
    return $result
}

function Test-HostReachable {
    param([string]$ComputerName)
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Test-HostReachable' -Arguments $PSBoundParameters) }
    try {
        $c = New-Object Net.Sockets.TcpClient
        $iar = $c.BeginConnect($ComputerName, 445, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(3000, $false) -and $c.Connected
        $c.Close()
        return [bool]$ok
    } catch { return $false }
}

function Remove-FixItPrinter { param([string]$Name)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Remove-FixItPrinter' -Arguments $PSBoundParameters; return }
 Remove-Printer -Name $Name -ErrorAction Stop }
function Add-FixItPrinterConnection { param([string]$Name)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Add-FixItPrinterConnection' -Arguments $PSBoundParameters; return }
 Add-Printer -ConnectionName $Name -ErrorAction Stop }
function Set-FixItDefaultPrinter {
    param([string]$Name)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Set-FixItDefaultPrinter' -Arguments $PSBoundParameters; return }
    $p = Get-CimInstance -ClassName Win32_Printer -Filter ("Name='{0}'" -f ($Name.Replace('\', '\\').Replace("'", "\'")))
    if ($p) { Invoke-CimMethod -InputObject $p -MethodName SetDefaultPrinter | Out-Null }
}

# Printers that only make files (PDF, XPS, OneNote, fax). They are never picked on their own.
$script:VirtualPrinterPattern = '(?i)print to pdf|xps document writer|onenote|^fax$|microsoft shared fax|adobe pdf|pdfcreator|cutepdf|save as pdf|snagit'
$script:PrinterReadyPattern = '^(|Normal|Idle|IOActive|Busy|Printing|Waiting|Processing|Initializing|WarmingUp|TonerLow|PowerSave)$'
# Windows keeps choosing the default printer by itself unless this is set to 1.
$script:WindowsNtKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows'

function Test-FixItVirtualPrinter { param([string]$Name) return ($Name -match $script:VirtualPrinterPattern) }

# Real printers first. If every printer is a "make a file" printer, they are all returned.
function Get-FixItPickablePrinters {
    param($Printers)
    $all = @($Printers | Where-Object { $null -ne $_ })
    $real = @($all | Where-Object { -not (Test-FixItVirtualPrinter -Name ([string]$_.Name)) })
    if ($real.Count -gt 0) { return $real }
    return $all
}

# A printer on the network is found by the address in its port name (for example IP_192.168.1.20).
function Get-FixItPrinterAddress {
    param([string]$PortName)
    if ($PortName -match '^(?:IP_)?(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?:_\d+)?$') { return $Matches[1] }
    return ''
}
function Test-FixItPortOpen {
    param([string]$Address, [int[]]$Ports)
    foreach ($port in $Ports) {
        try {
            $c = New-Object Net.Sockets.TcpClient
            $iar = $c.BeginConnect($Address, $port, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne(1500, $false) -and $c.Connected
            $c.Close()
            if ($ok) { return $true }
        } catch { }
    }
    return $false
}

# Tests one printer. Returns Ok (true/false) and Why (a short, plain reason when it is not ok).
function Test-FixItPrinterAvailable {
    param($Printer)
    $name = [string]$Printer.Name
    if ([bool]$Printer.WorkOffline) { return [pscustomobject]@{ Name = $name; Ok = $false; Why = 'Windows says it is offline' } }
    if ([string]$Printer.StatusText -notmatch $script:PrinterReadyPattern) {
        return [pscustomobject]@{ Name = $name; Ok = $false; Why = ('Windows says: {0}' -f $Printer.StatusText) }
    }
    if ([bool]$Printer.IsNetwork -and [string]$Printer.Server) {
        if (-not (Test-HostReachable -ComputerName ([string]$Printer.Server))) {
            return [pscustomobject]@{ Name = $name; Ok = $false; Why = ('the computer that shares it ({0}) cannot be reached' -f $Printer.Server) }
        }
    }
    $addr = Get-FixItPrinterAddress -PortName ([string]$Printer.PortName)
    if ($addr) {
        if (-not (Test-FixItPortOpen -Address $addr -Ports @(9100, 515, 631))) {
            return [pscustomobject]@{ Name = $name; Ok = $false; Why = 'it does not answer on the network' }
        }
    }
    return [pscustomobject]@{ Name = $name; Ok = $true; Why = '' }
}

# Makes one printer the default, in a way Windows keeps. The old default is saved so Undo can put it back.
function Set-FixItPrinterAsDefault {
    param([string]$Name, [string]$Previous = '')
    if ($Previous -and $Previous -ne $Name) { Add-FixItUndoStep ([ordered]@{ Kind = 'defaultprinter'; Name = $Previous }) }
    $a = Invoke-FixItStep 'Stop Windows from choosing the default printer by itself' { Set-RegDword -Path $script:WindowsNtKey -Name 'LegacyDefaultPrinterMode' -Value 1 }
    $b = Invoke-FixItStep ('Make {0} the default printer' -f $Name) { Set-FixItDefaultPrinter -Name $Name }
    return ($a -and $b)
}

# Asks which printer. The window shows a list of buttons; the command line shows numbers. Returns '' when the person goes back.
function Select-FixItPrinter {
    param([string[]]$Names, [string]$Current = '')
    if ($script:TestAll) { Write-FixItLog 'Test all: the first printer was picked' 'TEST'; return [string]@($Names)[0] }
    if ($script:GuiActive) { return [string](Show-FixItPrinterPickDialog -Names $Names -Current $Current) }
    if (-not (Test-FixItCanAsk)) { Write-FixItLog 'Nobody is there to pick a printer' 'WARN'; return '' }
    $i = 1
    foreach ($n in $Names) { Write-Host ('  {0}. {1}' -f $i, $n); $i++ }
    $a = Read-Host 'Type the number of your printer (or press Enter to go back)'
    $k = 0
    if ([int]::TryParse([string]$a, [ref]$k) -and $k -ge 1 -and $k -le @($Names).Count) { return [string]@($Names)[$k - 1] }
    return ''
}

function Get-RunningApp {
    param([string[]]$ProcessNames)
    return @(Get-Process -Name $ProcessNames -ErrorAction SilentlyContinue)
}

function Request-AppClose {
    param([string[]]$ProcessNames)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Request-AppClose' -Arguments $PSBoundParameters; return }
    foreach ($p in @(Get-Process -Name $ProcessNames -ErrorAction SilentlyContinue)) { [void]$p.CloseMainWindow() }
    $end = (Get-Date).AddSeconds(20)
    while (@(Get-Process -Name $ProcessNames -ErrorAction SilentlyContinue).Count -gt 0 -and (Get-Date) -lt $end) { Wait-FixIt -Milliseconds 500 }
}

function Get-InstalledProducts {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-InstalledProducts' -Arguments $PSBoundParameters) }
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $out = @()
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $r -ErrorAction SilentlyContinue)) {
            $dn = $k.GetValue('DisplayName', $null)
            if (-not $dn) { continue }
            $out += [pscustomobject]@{
                DisplayName = [string]$dn
                DisplayVersion = [string]$k.GetValue('DisplayVersion', '')
                ProductCode = $(if ($k.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') { $k.PSChildName } else { '' })
                WindowsInstaller = [bool]($k.GetValue('WindowsInstaller', 0))
            }
        }
    }
    return $out
}

function Get-OutlookInfo {
    $info = [ordered]@{ Installed = $false; Version = ''; Bitness = ''; Path = '' }
    $path = Get-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE' -Name ''
    if (-not $path) {
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE'
        if (Test-Path -LiteralPath $k) { $path = (Get-Item -LiteralPath $k).GetValue('') }
    }
    if ($path -and (Test-Path -LiteralPath $path)) {
        $info.Installed = $true
        $info.Path = [string]$path
        $info.Version = (Get-Item -LiteralPath $path).VersionInfo.ProductVersion
    }
    $c2r = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    if (Test-Path -LiteralPath $c2r) {
        $v = (Get-Item -LiteralPath $c2r).GetValue('VersionToReport', '')
        if ($v) { $info.Version = [string]$v; $info.Installed = $true }
        $info.Bitness = [string](Get-Item -LiteralPath $c2r).GetValue('Platform', '')
    }
    return [pscustomobject]$info
}

function Get-FixItFileVersion {
    param([string]$ExeName)
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\' + $ExeName
    if (-not (Test-Path -LiteralPath $k)) { return '' }
    $p = (Get-Item -LiteralPath $k).GetValue('')
    if ($p -and (Test-Path -LiteralPath $p)) { return [string](Get-Item -LiteralPath $p).VersionInfo.ProductVersion }
    return ''
}

# "No events found" is a normal answer (a clean PC). Anything else (for example access denied) is thrown so the report can say "not available" instead of "no errors".
function Test-FixItNoEvents {
    param($Err)
    $id = ''; try { $id = [string]$Err.FullyQualifiedErrorId } catch { }
    $m = ''; try { $m = [string]$Err.Exception.Message } catch { }
    return ($id -like 'NoMatchingEventsFound*' -or $m -match 'No events were found')
}
function Get-FixItEvents {
    param([string]$LogName, [int]$Max = 25)
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItEvents' -Arguments $PSBoundParameters) }
    $filter = @{ LogName = $LogName; Level = @(1, 2); StartTime = (Get-Date).AddDays(-7) }
    try { return @(Get-WinEvent -FilterHashtable $filter -MaxEvents $Max -ErrorAction Stop) } catch {
        if (Test-FixItNoEvents -Err $_) { return @() }
        throw
    }
}

function Get-FixItOsInfo {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItOsInfo' -Arguments $PSBoundParameters) }
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $disk = $null
    try { $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" } catch { }
    return [pscustomobject]@{
        Caption = [string]$os.Caption
        Version = [string]$os.Version
        Build = [string]$os.BuildNumber
        Arch = [string]$os.OSArchitecture
        LastBoot = [string]$os.LastBootUpTime
        ComputerName = $env:COMPUTERNAME
        UserName = $env:USERNAME
        FreeGB = $(if ($disk) { [math]::Round($disk.FreeSpace / 1GB, 1) } else { $null })
    }
}

function Get-DesktopFolder { return [Environment]::GetFolderPath('Desktop') }

function Open-FixItFile { param([string]$Path)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Open-FixItFile' -Arguments $PSBoundParameters; return }
 Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $Path) | Out-Null }

function Invoke-Msi {
    param([string]$ProductCode)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Invoke-Msi' -Arguments $PSBoundParameters; return 0 }
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Invoke-Msi' -Arguments $PSBoundParameters) }
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/fa', $ProductCode, '/qb', '/norestart') -Wait -PassThru
    return [int]$p.ExitCode
}

function Get-WebText {
    param([string]$Url)
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-WebText' -Arguments $PSBoundParameters) }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10
    return [string]$r.Content
}

function Save-WebFile {
    param([string]$Url, [string]$Dest)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Save-WebFile' -Arguments $PSBoundParameters; return }
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Save-WebFile' -Arguments $PSBoundParameters) }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 -OutFile $Dest
}

# ---------------------------------------------------------------------------
# The program icon (monitor with a heart and a bandage) - file, shortcuts, window
# ---------------------------------------------------------------------------
function Get-FixItIconPath { return (Join-Path $script:InstallDir $script:IconFileName) }

# True when the file is a real .ico (starts 00 00 01 00, has at least one picture, and is a sensible size).
function Test-FixItIconFile {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $len = (Get-Item -LiteralPath $Path).Length
        if ($len -lt 22 -or $len -gt 1MB) { return $false }
        $b = [IO.File]::ReadAllBytes($Path)
        return ($b[0] -eq 0 -and $b[1] -eq 0 -and $b[2] -eq 1 -and $b[3] -eq 0 -and ($b[4] + 256 * $b[5]) -ge 1)
    } catch { return $false }
}

# Windows adapters for the shortcuts (the tests replace these).
function Get-FixItShortcutPaths {
    $list = @()
    foreach ($w in @('Desktop', 'Programs')) {
        try { $fo = [Environment]::GetFolderPath($w); if ($fo) { $list += (Join-Path $fo $script:ShortcutFileName) } } catch { }
    }
    try { $fo = [Environment]::GetFolderPath('Programs'); if ($fo) { $list += (Join-Path $fo $script:TestShortcutFileName) } } catch { }
    return $list
}
function Read-FixItShortcut {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $l = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
        return [pscustomobject]@{ Arguments = [string]$l.Arguments; Icon = [string]$l.IconLocation }
    } catch { return $null }
}
function Write-FixItShortcutIcon {
    param([string]$Path, [string]$Icon)
    $l = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
    $l.IconLocation = $Icon
    $l.Save()
}
function Test-FixItSameIcon {
    param([string]$A, [string]$B)
    $x = ($A -replace ',\s*-?\d+\s*$', '').Trim().Trim('"'); $y = ($B -replace ',\s*-?\d+\s*$', '').Trim().Trim('"')
    return ([string]::Compare($x, $y, $true) -eq 0)
}
# Points the Family Fix-It shortcuts (Desktop and Start menu) at the program icon. Only touches OUR shortcuts
# (right name, and they start FamilyFixIt.ps1), only when the icon differs, and never creates or removes one. Safe to repeat.
function Update-FixItShortcutIcons {
    $ico = Get-FixItIconPath
    if (-not (Test-FixItIconFile -Path $ico)) { return 0 }
    $want = $ico + ',0'
    $changed = 0
    foreach ($lnk in @(Get-FixItShortcutPaths)) {
        try {
            $cur = Read-FixItShortcut -Path $lnk
            if ($null -eq $cur) { continue }
            if ($cur.Arguments -notmatch 'FamilyFixIt\.ps1') { continue }
            if (Test-FixItSameIcon $cur.Icon $want) { continue }
            if ($script:DryRun) { Write-FixItLog ('Would do: set the icon of {0}' -f $lnk) 'DRYRUN'; continue }
            Write-FixItShortcutIcon -Path $lnk -Icon $want
            Write-FixItLog ('Shortcut icon updated: {0}' -f $lnk)
            $changed++
        } catch { Write-FixItLog ('Could not update the icon of {0}: {1}' -f $lnk, $_.Exception.Message) 'WARN' }
    }
    return $changed
}
# Window and taskbar icon for a form. Windows picks the best size (16, 24, 32 ...) out of the .ico by itself.
$script:UiAppIcon = $null
function Get-FixItAppIcon {
    if ($null -ne $script:UiAppIcon) { return $script:UiAppIcon }
    try {
        $p = Get-FixItIconPath
        if (Test-FixItIconFile -Path $p) { $script:UiAppIcon = New-Object System.Drawing.Icon($p) }
    } catch { Write-FixItLog ('The program icon could not be loaded: {0}' -f $_.Exception.Message) 'WARN' }
    return $script:UiAppIcon
}
function Set-FixItFormIcon {
    param($Form)
    try { $ic = Get-FixItAppIcon; if ($null -ne $ic) { $Form.Icon = $ic } } catch { }
}
# If the icon file is missing (for example after an update from a version that did not know about it), fetch it
# from the update list, check its fingerprint, then point the shortcuts at it. Quiet; never asks anything.
function Repair-FixItIcon {
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Repair-FixItIcon' -Arguments $PSBoundParameters; return $false }
    if ($script:DryRun) { return $false }
    $ico = Get-FixItIconPath
    if (Test-FixItIconFile -Path $ico) { [void](Update-FixItShortcutIcons); return $false }
    $m = Get-RemoteManifest -Url $script:ManifestUrl
    if ($m.State -ne 'Ok') { return $false }
    $a = @($m.Assets | Where-Object { [string]$_.path -eq $script:IconFileName }) | Select-Object -First 1
    if ($null -eq $a) { return $false }
    $tmp = $ico + '.download'
    try {
        Save-WebFile -Url ($m.BaseUrl + $script:IconFileName) -Dest $tmp
        if ((Get-FileSha256 -Path $tmp) -ne ([string]$a.sha256).ToLowerInvariant() -or -not (Test-FixItIconFile -Path $tmp)) { throw 'icon failed its safety check' }
        Move-Item -LiteralPath $tmp -Destination $ico -Force
        Write-FixItLog 'Program icon downloaded'
        [void](Update-FixItShortcutIcons)
        return $true
    } catch {
        Write-FixItLog ('Could not get the program icon: {0}' -f $_.Exception.Message) 'WARN'
        return $false
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# More Windows adapters (version 2). Again: only these touch Windows itself.
# ---------------------------------------------------------------------------
function Get-FixItProp {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if (Test-FixItHas $Object $Name) { return $Object.$Name }
    return $Default
}
function Test-FixItHas {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    foreach ($p in $Object.PSObject.Properties) { if ($p.Name -eq $Name) { return $true } }
    return $false
}

function Set-RegString {
    param([string]$Path, [string]$Name, [string]$Value)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Set-RegString' -Arguments $PSBoundParameters; return }
    Register-FixItRegUndo -Path $Path -Name $Name
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}


# Runs a program and returns its exit code and text. -Live shows the program's own progress in the window.
function Invoke-FixItNative {
    param([string]$File, [string[]]$Arguments = @(), [switch]$Live)
    if ($script:TestMode -and -not (Test-FixItNativeReadOnly -File $File -Arguments $Arguments)) {
        Invoke-FixItProbe -Adapter 'Invoke-FixItNative' -Arguments $PSBoundParameters
        return [pscustomobject]@{ ExitCode = 0; Output = '' }
    }
    if ((Test-FixItOffUiWanted) -and -not $Live) { return (Invoke-FixItOffUi -Command 'Invoke-FixItNative' -Arguments $PSBoundParameters) }
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Live) { & $File @Arguments | Out-Host; $text = '' }
        else { $text = (& $File @Arguments 2>&1 | Out-String) }
        $code = [int]$LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    return [pscustomobject]@{ ExitCode = $code; Output = [string]$text }
}

# Runs a program as one step; throws when it reports a problem (so Invoke-FixItStep counts it as failed).
function Invoke-FixItTool {
    param([string]$File, [string[]]$Arguments = @(), [int[]]$OkCodes = @(0), [switch]$Live)
    $r = Invoke-FixItNative -File $File -Arguments $Arguments -Live:$Live
    if ($OkCodes -notcontains [int]$r.ExitCode) { throw ('{0} ended with code {1}' -f $File, $r.ExitCode) }
}

function Open-FixItSettings { param([string]$Uri)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Open-FixItSettings' -Arguments $PSBoundParameters; return }
 Start-Process -FilePath $Uri | Out-Null }
function Open-FixItUrl { param([string]$Url)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Open-FixItUrl' -Arguments $PSBoundParameters; return }
 Start-Process -FilePath $Url | Out-Null }
function Restart-FixItComputer {
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Restart-FixItComputer' -Arguments $PSBoundParameters; return }
 Start-Process -FilePath 'shutdown.exe' -ArgumentList @('/r', '/t', '30', '/c', 'Family Fix-It: restarting your computer in 30 seconds. Save your work.') | Out-Null }

function Get-FixItServiceStatus {
    param([string]$Name)
    try { return [string](Get-Service -Name $Name -ErrorAction Stop).Status } catch { return 'Missing' }
}
function Stop-FixItService {
    param([string]$Name)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Stop-FixItService' -Arguments $PSBoundParameters; return }
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Stop-FixItService' -Arguments $PSBoundParameters) }
    $s = Get-Service -Name $Name -ErrorAction Stop
    if ($s.Status -eq 'Stopped') { return }
    Stop-Service -Name $Name -Force -ErrorAction Stop
    $end = (Get-Date).AddSeconds(30)
    while ((Get-Service -Name $Name).Status -ne 'Stopped' -and (Get-Date) -lt $end) { Wait-FixIt -Milliseconds 500 }
    if ((Get-Service -Name $Name).Status -ne 'Stopped') { throw ('{0} did not stop' -f $Name) }
}
function Start-FixItService {
    param([string]$Name)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Start-FixItService' -Arguments $PSBoundParameters; return }
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Start-FixItService' -Arguments $PSBoundParameters) }
    $s = Get-Service -Name $Name -ErrorAction Stop
    if ($s.Status -eq 'Running') { return }
    Start-Service -Name $Name -ErrorAction Stop
    $end = (Get-Date).AddSeconds(30)
    while ((Get-Service -Name $Name).Status -ne 'Running' -and (Get-Date) -lt $end) { Wait-FixIt -Milliseconds 500 }
    if ((Get-Service -Name $Name).Status -ne 'Running') { throw ('{0} did not start' -f $Name) }
}

function Get-FixItFreeBytes {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItFreeBytes' -Arguments $PSBoundParameters) }
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'"
    if ($disk) { return [int64]$disk.FreeSpace }
    return [int64]0
}
function Get-FixItUptimeDays {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItUptimeDays' -Arguments $PSBoundParameters) }
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    return [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
}
# Only the two flags Windows itself sets when an update needs a restart. PendingFileRenameOperations is NOT used:
# installers and antivirus leave it set all the time, so it caused "restart waiting" when nothing was waiting.
function Test-PendingReboot {
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
                     'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        if (Test-RegKey -Path $k) { return $true }
    }
    return $false
}
# Days since the last REAL restart. With Windows "fast startup", Shut down does not reset this (only Restart does).
$script:RestartHintDays = 7
function Test-FixItRestartWanted {
    $pending = $false; try { $pending = [bool](Test-PendingReboot) } catch { }
    $days = 0; try { $days = [double](Get-FixItUptimeDays) } catch { }
    return [pscustomobject]@{ Wanted = ($pending -or $days -gt $script:RestartHintDays); Pending = $pending; Days = $days }
}
function Get-FixItLastUpdate {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItLastUpdate' -Arguments $PSBoundParameters) }
    try {
        $h = @(Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1)
        if ($h.Count -gt 0) { return ('{0} on {1}' -f $h[0].HotFixID, ([datetime]$h[0].InstalledOn).ToString('yyyy-MM-dd')) }
    } catch { }
    return 'unknown'
}
function Get-FixItTopApps {
    param([int]$Count = 5)
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItTopApps' -Arguments $PSBoundParameters) }
    $g = @(Get-Process -ErrorAction SilentlyContinue | Group-Object -Property ProcessName | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; MemMB = [math]::Round((($_.Group | Measure-Object -Property WorkingSet64 -Sum).Sum) / 1MB) } })
    return @($g | Sort-Object MemMB -Descending | Select-Object -First $Count)
}
function Get-FixItHungApps {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItHungApps' -Arguments $PSBoundParameters) }
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and -not $_.Responding } |
        ForEach-Object { [pscustomobject]@{ Name = $_.ProcessName; Id = $_.Id; Title = [string]$_.MainWindowTitle } })
}
function Stop-FixItApp {
    param([int]$Id)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Stop-FixItApp' -Arguments $PSBoundParameters; return }
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Stop-FixItApp' -Arguments $PSBoundParameters) }   # it waits up to 5 seconds for the program to close
    $p = Get-Process -Id $Id -ErrorAction Stop
    [void]$p.CloseMainWindow()
    if (-not $p.WaitForExit(5000)) { $p.Kill() }
}

# Folders that this tool may empty. Anything else is refused. Documents, Desktop, Downloads and mail files are never allowed.
function Test-SafeCleanPath {
    param([string]$Path)
    if (-not $Path) { return $false }
    $p = $Path.TrimEnd('\')
    if ($p -match '(?i)\\(Documents|Desktop|Downloads|Pictures|Music|Videos|OneDrive[^\\]*)(\\|$)') { return $false }
    if ($p -match '(?i)\.(pst|ost)$|\\Microsoft\\Outlook(\\|$)') { return $false }
    if ($p -match '(?i)\\AppData\\Local\\Temp$') { return $true }
    if ($env:TEMP -and ($p -ieq $env:TEMP.TrimEnd('\'))) { return $true }
    if ($p -match '(?i)^[A-Za-z]:\\Windows\\Temp$') { return $true }
    if ($p -match '(?i)^[A-Za-z]:\\Windows\\SoftwareDistribution\\Download$') { return $true }
    if ($p -match '(?i)\\(Microsoft\\Edge|Google\\Chrome)\\User Data\\[^\\]+\\(Cache|Code Cache|GPUCache)$') { return $true }
    return $false
}

function Get-FixItFolderBytes {
    param([string]$Path)
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItFolderBytes' -Arguments $PSBoundParameters) }
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    $m = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
    if ($m -and $m.Sum) { return [int64]$m.Sum }
    return [int64]0
}

# Empties a folder (keeps the folder). Files that are in use are skipped. Returns the bytes freed.
function Clear-FixItFolder {
    param([string]$Path)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Clear-FixItFolder' -Arguments $PSBoundParameters; return [int64]0 }
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Clear-FixItFolder' -Arguments $PSBoundParameters) }
    if (-not (Test-SafeCleanPath -Path $Path)) { throw ('Refusing to clean this folder: {0}' -f $Path) }
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    $before = Get-FixItFolderBytes -Path $Path
    foreach ($c in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $c.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    $after = Get-FixItFolderBytes -Path $Path
    return [int64]([math]::Max([int64]0, $before - $after))
}
function Clear-FixItRecycleBin {
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Clear-FixItRecycleBin' -Arguments $PSBoundParameters; return }
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Clear-FixItRecycleBin' -Arguments $PSBoundParameters) }
 Clear-RecycleBin -Force -ErrorAction Stop }

function Get-FixItBrowserCacheFolders {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItBrowserCacheFolders' -Arguments $PSBoundParameters) }
    $out = @()
    $local = $env:LOCALAPPDATA
    if (-not $local) { return $out }
    foreach ($b in @(@{ N = 'Edge'; P = 'Microsoft\Edge\User Data' }, @{ N = 'Chrome'; P = 'Google\Chrome\User Data' })) {
        $root = Join-Path $local $b.P
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
            foreach ($sub in @('Cache', 'Code Cache', 'GPUCache')) {
                $out += [pscustomobject]@{ Browser = $b.N; Path = (Join-Path $d.FullName $sub) }
            }
        }
    }
    return $out
}

# ----- internet checks
function Get-FixItGateway {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItGateway' -Arguments $PSBoundParameters) }
    $c = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop)
    foreach ($a in $c) { foreach ($g in @($a.DefaultIPGateway)) { if ($g -and $g -match '^\d+\.\d+\.\d+\.\d+$') { return [string]$g } } }
    return ''
}
function Test-FixItPing {
    param([string]$Target)
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Test-FixItPing' -Arguments $PSBoundParameters) }
    try { return [bool](Test-Connection -ComputerName $Target -Count 2 -Quiet -ErrorAction Stop) } catch { return $false }
}
function Test-FixItDns {
    param([string]$Name)
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Test-FixItDns' -Arguments $PSBoundParameters) }
    try { return (@([Net.Dns]::GetHostAddresses($Name)).Count -gt 0) } catch { return $false }
}
function Test-FixItWeb {
    try { return ((Get-WebText -Url 'http://www.msftconnecttest.com/connecttest.txt') -match 'Microsoft Connect Test') } catch { return $false }
}
function Get-FixItUserProxy {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    return [pscustomobject]@{
        Enabled = ((Get-RegValue -Path $k -Name 'ProxyEnable') -eq 1)
        Server = [string](Get-RegValue -Path $k -Name 'ProxyServer')
        Key = $k
    }
}
function Get-FixItAdapters {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItAdapters' -Arguments $PSBoundParameters) }
    return @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } | ForEach-Object { [string]$_.Name })
}
function Restart-FixItAdapter { param([string]$Name)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Restart-FixItAdapter' -Arguments $PSBoundParameters; return }
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Restart-FixItAdapter' -Arguments $PSBoundParameters) }
 Restart-NetAdapter -Name $Name -Confirm:$false -ErrorAction Stop }

# ----- sound, microphone, camera
function Initialize-FixItAudio {
    if ('FixItAudio' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FixItAudio {
    [StructLayout(LayoutKind.Sequential)] struct PropKey { public Guid fmtid; public int pid; }
    [StructLayout(LayoutKind.Explicit, Size = 16)] struct PropVariant { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; }
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class Enumerator { }
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IEnum { int Unused1(); int GetDefaultAudioEndpoint(int flow, int role, out IDev dev); }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDev { int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); int OpenPropertyStore(int access, out IStore s); }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IStore { int GetCount(out int c); int GetAt(int i, out PropKey k); int GetValue(ref PropKey k, out PropVariant v); }
    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IVol {
        int RegisterControlChangeNotify(IntPtr p); int UnregisterControlChangeNotify(IntPtr p); int GetChannelCount(out int c);
        int SetMasterVolumeLevel(float l, ref Guid g); int SetMasterVolumeLevelScalar(float l, ref Guid g);
        int GetMasterVolumeLevel(out float l); int GetMasterVolumeLevelScalar(out float l);
        int SetChannelVolumeLevel(int c, float l, ref Guid g); int SetChannelVolumeLevelScalar(int c, float l, ref Guid g);
        int GetChannelVolumeLevel(int c, out float l); int GetChannelVolumeLevelScalar(int c, out float l);
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool m, ref Guid g); int GetMute(out bool m);
    }
    static IDev Dev(int flow) { IEnum e = (IEnum)new Enumerator(); IDev d; if (e.GetDefaultAudioEndpoint(flow, 1, out d) != 0) return null; return d; }
    static IVol Vol(IDev d) { Guid iid = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A"); object o; d.Activate(ref iid, 23, IntPtr.Zero, out o); return (IVol)o; }
    // flow: 0 = speakers/headphones, 1 = microphone. Returns "name|volume 0-100|muted 0/1", or "" when there is no default device.
    public static string Get(int flow) {
        IDev d = Dev(flow); if (d == null) return "";
        string name = "";
        try {
            IStore s; d.OpenPropertyStore(0, out s);
            PropKey k = new PropKey(); k.fmtid = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"); k.pid = 14;
            PropVariant v; s.GetValue(ref k, out v);
            if (v.vt == 31) name = Marshal.PtrToStringUni(v.p);
        } catch { }
        IVol vol = Vol(d); float lv; bool m; vol.GetMasterVolumeLevelScalar(out lv); vol.GetMute(out m);
        return name + "|" + ((int)Math.Round(lv * 100)).ToString() + "|" + (m ? "1" : "0");
    }
    public static void Set(int flow, int volume, bool mute) {
        IDev d = Dev(flow); if (d == null) return; IVol vol = Vol(d); Guid g = Guid.Empty;
        if (volume >= 0) vol.SetMasterVolumeLevelScalar(volume / 100f, ref g);
        vol.SetMute(mute, ref g);
    }
}
'@
}

function Get-FixItAudioDevice {
    param([ValidateSet('Speakers', 'Microphone')][string]$Kind)
    $flow = 0; if ($Kind -eq 'Microphone') { $flow = 1 }
    Initialize-FixItAudio
    $raw = [FixItAudio]::Get($flow)
    if (-not $raw) { return $null }
    $parts = $raw.Split('|')
    return [pscustomobject]@{ Name = $parts[0]; Volume = [int]$parts[1]; Muted = ($parts[2] -eq '1') }
}
function Set-FixItAudioDevice {
    param([ValidateSet('Speakers', 'Microphone')][string]$Kind, [int]$Volume, [bool]$Muted = $false)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Set-FixItAudioDevice' -Arguments $PSBoundParameters; return }
    $flow = 0; if ($Kind -eq 'Microphone') { $flow = 1 }
    Initialize-FixItAudio
    [FixItAudio]::Set($flow, $Volume, $Muted)
}
function Get-FixItPrivacy {
    param([ValidateSet('microphone', 'webcam')][string]$Capability)
    $sub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\' + $Capability
    return [pscustomobject]@{
        User = [string](Get-RegValue -Path ('HKCU:\' + $sub) -Name 'Value')
        Machine = [string](Get-RegValue -Path ('HKLM:\' + $sub) -Name 'Value')
    }
}
function Set-FixItPrivacyAllow {
    param([ValidateSet('microphone', 'webcam')][string]$Capability)
    Set-RegString -Path ('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\' + $Capability) -Name 'Value' -Value 'Allow'
}
function Get-FixItCameras {
    return @(Get-PnpDevice -Class @('Camera', 'Image') -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Name = [string]$_.FriendlyName; Status = [string]$_.Status } })
}

# ----- Outlook
function Get-FixItOutlookAddins {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItOutlookAddins' -Arguments $PSBoundParameters) }
    $out = @()
    $roots = @('HKCU:\Software\Microsoft\Office\Outlook\Addins', 'HKLM:\SOFTWARE\Microsoft\Office\Outlook\Addins', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\Outlook\Addins')
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $r -ErrorAction SilentlyContinue)) {
            $out += [pscustomobject]@{
                ProgId = [string]$k.PSChildName
                Description = [string]$k.GetValue('FriendlyName', '')
                LoadBehavior = $k.GetValue('LoadBehavior', $null)
                Path = ($r + '\' + $k.PSChildName)
                IsMachineWide = $r.StartsWith('HKLM')
            }
        }
    }
    return $out
}
function Get-FixItCrashingAddins {
    $out = @()
    foreach ($v in $script:OfficeVersions) {
        $path = 'HKCU:\Software\Microsoft\Office\{0}\Outlook\Resiliency\CrashingAddinList' -f $v
        foreach ($n in @(Get-RegValueNames -Path $path)) { $out += $n }
    }
    return $out
}
function Start-FixItOutlookSafe {
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Start-FixItOutlookSafe' -Arguments $PSBoundParameters; return }
    $ol = Get-OutlookInfo
    $exe = 'outlook.exe'
    if ($ol.Installed -and $ol.Path) { $exe = $ol.Path }
    Start-Process -FilePath $exe -ArgumentList '/safe' | Out-Null
}
function Start-FixItOutlook {
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Start-FixItOutlook' -Arguments $PSBoundParameters; return }
    $ol = Get-OutlookInfo
    $exe = 'outlook.exe'
    if ($ol.Installed -and $ol.Path) { $exe = $ol.Path }
    Start-Process -FilePath $exe | Out-Null
}
# Every program that is "Outlook" (the classic one and the new one). Used to close it completely.
$script:OutlookProcessNames = @('OUTLOOK', 'olk')
function Stop-FixItAppsByName {
    param([string[]]$ProcessNames)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Stop-FixItAppsByName' -Arguments $PSBoundParameters; return }
    foreach ($p in @(Get-Process -Name $ProcessNames -ErrorAction SilentlyContinue)) { try { $p.Kill() } catch { } }
    $end = (Get-Date).AddSeconds(10)
    while (@(Get-Process -Name $ProcessNames -ErrorAction SilentlyContinue).Count -gt 0 -and (Get-Date) -lt $end) { Wait-FixIt -Milliseconds 300 }
}
# ----- browsers
function Get-FixItBrowserProfiles {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItBrowserProfiles' -Arguments $PSBoundParameters) }
    $out = @()
    $local = $env:LOCALAPPDATA
    if (-not $local) { return $out }
    foreach ($b in @(@{ N = 'Edge'; P = 'Microsoft\Edge\User Data' }, @{ N = 'Chrome'; P = 'Google\Chrome\User Data' })) {
        $root = Join-Path $local $b.P
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
            if (Test-Path -LiteralPath (Join-Path $d.FullName 'Preferences')) {
                $out += [pscustomobject]@{ Browser = $b.N; Name = $d.Name; Dir = $d.FullName }
            }
        }
    }
    return $out
}
function Get-FixItBrowserSettings {
    param([string]$Dir)
    $j = Get-Content -LiteralPath (Join-Path $Dir 'Preferences') -Raw -Encoding UTF8 | ConvertFrom-Json
    $r = [ordered]@{ Homepage = ''; StartupUrls = @(); SearchName = ''; SearchUrl = ''; NotificationSites = @() }
    if ((Test-FixItHas $j 'homepage')) { $r.Homepage = [string]$j.homepage }
    if ((Test-FixItHas $j 'session') -and (Test-FixItHas $j.session 'startup_urls')) { $r.StartupUrls = @($j.session.startup_urls) }
    if ((Test-FixItHas $j 'default_search_provider_data')) {
        $t = $j.default_search_provider_data.template_url_data
        if ($t) { $r.SearchName = [string]$t.short_name; $r.SearchUrl = [string]$t.url }
    }
    if ((Test-FixItHas $j 'profile') -and (Test-FixItHas $j.profile 'content_settings')) {
        $cs = $j.profile.content_settings
        if ((Test-FixItHas $cs 'exceptions') -and (Test-FixItHas $cs.exceptions 'notifications')) {
            foreach ($p in $cs.exceptions.notifications.PSObject.Properties) {
                if ((Test-FixItHas $p.Value 'setting') -and [int]$p.Value.setting -eq 1) { $r.NotificationSites += ($p.Name -replace ',\*$', '') }
            }
        }
    }
    return [pscustomobject]$r
}
function Get-FixItBrowserExtensions {
    param([string]$Dir)
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItBrowserExtensions' -Arguments $PSBoundParameters) }
    $out = @()
    $root = Join-Path $Dir 'Extensions'
    if (-not (Test-Path -LiteralPath $root)) { return $out }
    foreach ($e in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        $ver = Get-ChildItem -LiteralPath $e.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if (-not $ver) { continue }
        $name = $e.Name
        try {
            $m = Get-Content -LiteralPath (Join-Path $ver.FullName 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $name = [string]$m.name
            if ($name -match '^__MSG_(.+)__$') {
                $key = $Matches[1]
                foreach ($loc in @('en', 'en_US', 'en_GB')) {
                    $mp = Join-Path $ver.FullName ('_locales\{0}\messages.json' -f $loc)
                    if (Test-Path -LiteralPath $mp) {
                        $msgs = Get-Content -LiteralPath $mp -Raw -Encoding UTF8 | ConvertFrom-Json
                        foreach ($p in $msgs.PSObject.Properties) { if ($p.Name -ieq $key) { $name = [string]$p.Value.message } }
                        break
                    }
                }
            }
        } catch { }
        $out += [pscustomobject]@{ Id = [string]$e.Name; Name = $name }
    }
    return $out
}
function Copy-FixItBackup {
    param([string]$Source, [string]$DestDir)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Copy-FixItBackup' -Arguments $PSBoundParameters; return }
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Copy-FixItBackup' -Arguments $PSBoundParameters) }
    if (-not (Test-Path -LiteralPath $Source)) { return }
    if (-not (Test-Path -LiteralPath $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }
    Copy-Item -LiteralPath $Source -Destination $DestDir -Force -ErrorAction Stop
}
function Start-FixItDefenderScan {
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Start-FixItDefenderScan' -Arguments $PSBoundParameters; return }
 Start-MpScan -ScanType QuickScan -ErrorAction Stop }

# ----- Windows Update
function Rename-FixItFolderAside {
    param([string]$Path, [string]$Tag)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Rename-FixItFolderAside' -Arguments $PSBoundParameters; return '' }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $leaf = Split-Path -Leaf $Path
    $parent = Split-Path -Parent $Path
    if ($leaf -notin @('SoftwareDistribution', 'catroot2')) { throw ('Refusing to rename {0}' -f $Path) }
    foreach ($old in @(Get-ChildItem -LiteralPath $parent -Directory -Filter ($leaf + '.fixit-old*') -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    $newName = '{0}.fixit-old-{1}' -f $leaf, $Tag
    Rename-Item -LiteralPath $Path -NewName $newName -ErrorAction Stop
    return (Join-Path $parent $newName)
}
function Get-FixItStateFile {
    $b = $env:LOCALAPPDATA
    if (-not $b) { $b = [IO.Path]::GetTempPath() }
    return (Join-Path $b 'FamilyFixIt\state.json')
}
function Get-FixItState {
    $f = Get-FixItStateFile
    if (Test-Path -LiteralPath $f) { try { return (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json) } catch { } }
    return [pscustomobject]@{}
}
function Set-FixItStateValue {
    param([string]$Name, [string]$Value)
    if ($script:TestMode) { return }
    $f = Get-FixItStateFile
    $d = Split-Path -Parent $f
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $h = [ordered]@{}
    $cur = Get-FixItState
    foreach ($p in $cur.PSObject.Properties) { $h[$p.Name] = $p.Value }
    $h[$Name] = $Value
    [IO.File]::WriteAllText($f, ($h | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
}

# ----- OneDrive
function Get-FixItOneDriveInfo {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItOneDriveInfo' -Arguments $PSBoundParameters) }
    $exe = ''
    foreach ($c in @(($env:LOCALAPPDATA + '\Microsoft\OneDrive\OneDrive.exe'), ($env:ProgramFiles + '\Microsoft OneDrive\OneDrive.exe'), (${env:ProgramFiles(x86)} + '\Microsoft OneDrive\OneDrive.exe'))) {
        if ($c -and (Test-Path -LiteralPath $c)) { $exe = $c; break }
    }
    $accounts = @()
    $root = 'HKCU:\Software\Microsoft\OneDrive\Accounts'
    if (Test-Path -LiteralPath $root) {
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $email = [string]$k.GetValue('UserEmail', '')
            if ($email) { $accounts += [pscustomobject]@{ Kind = [string]$k.PSChildName; Email = $email; Folder = [string]$k.GetValue('UserFolder', '') } }
        }
    }
    return [pscustomobject]@{ Exe = $exe; Installed = [bool]$exe; Running = (@(Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue).Count -gt 0); Accounts = $accounts }
}
# Best effort: OneDrive does not publish a "paused" setting, so this reads the number in its own sync log.
function Get-FixItOneDriveSyncState {
    param([string]$Kind)
    $log = '{0}\Microsoft\OneDrive\logs\{1}\SyncDiagnostics.log' -f $env:LOCALAPPDATA, $Kind
    if (-not (Test-Path -LiteralPath $log)) { return 'Unknown' }
    $line = Get-Content -LiteralPath $log -ErrorAction Stop | Where-Object { $_ -match 'SyncProgressState' } | Select-Object -First 1
    if (-not $line) { return 'Unknown' }
    $n = ($line -split '\s+') | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
    switch ([string]$n) {
        { $_ -in @('0', '42', '16777216', '12544') } { return 'UpToDate' }
        '65536' { return 'Paused' }
        { $_ -in @('8194', '1854') } { return 'Problem' }
        default { return 'Unknown' }
    }
}
function Get-FixItKnownFolders {
    return [pscustomobject]@{
        Desktop = [Environment]::GetFolderPath('Desktop')
        Documents = [Environment]::GetFolderPath('MyDocuments')
        Pictures = [Environment]::GetFolderPath('MyPictures')
    }
}
function Start-FixItOneDriveReset {
    param([string]$Exe)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Start-FixItOneDriveReset' -Arguments $PSBoundParameters; return }
    Start-Process -FilePath $Exe -ArgumentList '/reset' | Out-Null
}
function Start-FixItOneDrive {
    param([string]$Exe)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Start-FixItOneDrive' -Arguments $PSBoundParameters; return }
    Start-Process -FilePath $Exe | Out-Null
}

# Small adapters that were inline code before. Test mode checks them instead of running them.
function Write-FixItTextFile {
    param([string]$Path, [string]$Text)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Write-FixItTextFile' -Arguments $PSBoundParameters; return }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($true)))
}
function Set-FixItServiceStartType {
    param([string]$Name, [string]$StartType)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Set-FixItServiceStartType' -Arguments $PSBoundParameters; return }
    Set-Service -Name $Name -StartupType $StartType
}
function Open-FixItBrowserPage {
    param([string]$Exe, [string]$Url)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Open-FixItBrowserPage' -Arguments $PSBoundParameters; return }
    Start-Process -FilePath $Exe -ArgumentList $Url | Out-Null
}

# ----- extra facts for reports
function Get-FixItCrashes {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItCrashes' -Arguments $PSBoundParameters) }
    $out = @()
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 10 -ErrorAction Stop)
        foreach ($e in $ev) { $out += [pscustomobject]@{ Time = [datetime]$e.TimeCreated; Message = [string]$e.Message } }
    } catch { if (-not (Test-FixItNoEvents -Err $_)) { throw } }
    return $out
}
function Get-FixItUnexpectedShutdowns {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItUnexpectedShutdowns' -Arguments $PSBoundParameters) }
    try { return @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 50 -ErrorAction Stop).Count } catch {
        if (Test-FixItNoEvents -Err $_) { return 0 }
        throw
    }
}
function Get-FixItDiskHealth {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItDiskHealth' -Arguments $PSBoundParameters) }
    $out = @()
    try {
        foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) {
            $out += [pscustomobject]@{ Name = [string]$d.FriendlyName; Type = [string]$d.MediaType; Health = [string]$d.HealthStatus; Status = [string]$d.OperationalStatus }
        }
    } catch { Write-FixItLog ('Disk list not available: {0}' -f $_.Exception.Message) }
    $pred = 'not available'
    try {
        $s = @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSStorageDriver_FailurePredictStatus' -ErrorAction Stop)
        if ($s.Count -gt 0) { if (@($s | Where-Object { $_.PredictFailure }).Count -gt 0) { $pred = 'FAILURE PREDICTED' } else { $pred = 'OK' } }
    } catch {
        if (Test-FixItAccessDenied -Err $_) { $pred = 'not checked (needs administrator rights)' }
        Write-FixItLog ('Disk prediction not available: {0}' -f $_.Exception.Message)
    }
    return [pscustomobject]@{ Disks = $out; SmartPrediction = $pred }
}
function Get-FixItRemoteToolProcesses {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItRemoteToolProcesses' -Arguments $PSBoundParameters) }
    $pat = '^(AnyDesk|TeamViewer.*|ScreenConnect.*|ConnectWise.*|Splashtop.*|SRService|SRManager|LogMeIn.*|RustDesk|UltraViewer.*|ZA_Connect|ZohoMeeting|ZohoURS|ZAService|Zoho.*|quickassist|msra|vncviewer|winvnc|tvnserver|uvnc.*|Supremo.*|AmmyyAdmin|DWAgent.*|RemotePC.*|GoToAssist.*|g2.*agent|bomgar.*|BASupSrvc.*|Atera.*|AteraAgent|ISLLight|helpwire.*|aweray.*|ToDesk.*|Parsec.*|Chrome ?Remote.*|remoting_host)$'
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $pat } | ForEach-Object { [pscustomobject]@{ Name = $_.ProcessName; Id = $_.Id } })
}
function Get-FixItRecentInstalls {
    param([int]$Days = 14)
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItRecentInstalls' -Arguments $PSBoundParameters) }
    $out = @()
    $cut = (Get-Date).AddDays(-$Days)
    foreach ($r in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $r -ErrorAction SilentlyContinue)) {
            $dn = $k.GetValue('DisplayName', $null); $id = [string]$k.GetValue('InstallDate', '')
            if (-not $dn -or $id -notmatch '^\d{8}$') { continue }
            $d = [datetime]::MinValue
            if ([datetime]::TryParseExact($id, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d) -and $d -ge $cut) {
                $out += [pscustomobject]@{ Name = [string]$dn; Date = $d }
            }
        }
    }
    return $out
}
function Get-FixItRecentDownloads {
    param([int]$Days = 7, [int]$Max = 30)
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItRecentDownloads' -Arguments $PSBoundParameters) }
    $dir = Join-Path $env:USERPROFILE 'Downloads'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge (Get-Date).AddDays(-$Days) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First $Max | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Date = $_.LastWriteTime; KB = [math]::Round($_.Length / 1KB) } })
}

# Posts the report. This is the ONLY place that sends anything over the internet.
function Send-WebReport {
    param([string]$Url, [string]$Json, [string]$AppValue)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Send-WebReport' -Arguments $PSBoundParameters; return 200 }
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Send-WebReport' -Arguments $PSBoundParameters) }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Json)
    $r = Invoke-WebRequest -Uri $Url -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -Headers @{ 'X-FixIt-App' = $AppValue } -UseBasicParsing -TimeoutSec 20
    return [int]$r.StatusCode
}

# ---------------------------------------------------------------------------
# More Windows adapters (version 2, part two)
# ---------------------------------------------------------------------------
function Restore-FixItRegValue {
    param([string]$Path, [string]$Name, [bool]$Existed, [string]$Type, [string]$Value)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Restore-FixItRegValue' -Arguments $PSBoundParameters; return }
    if (-not $Existed) {
        if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path).GetValueNames() -contains $Name)) { Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction Stop }
        return
    }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    switch ($Type) {
        'dword'  { New-ItemProperty -LiteralPath $Path -Name $Name -Value ([int]$Value) -PropertyType DWord -Force | Out-Null }
        'binary' { New-ItemProperty -LiteralPath $Path -Name $Name -Value ([byte[]][Convert]::FromBase64String($Value)) -PropertyType Binary -Force | Out-Null }
        default  { New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType String -Force | Out-Null }
    }
}
function Restore-FixItFile {
    param([string]$Backup, [string]$Original)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Restore-FixItFile' -Arguments $PSBoundParameters; return }
    if (-not (Test-Path -LiteralPath $Backup)) { throw 'The saved copy is gone' }
    Copy-Item -LiteralPath $Backup -Destination $Original -Force -ErrorAction Stop
}
# Puts a folder that was set aside back in place. The folder that Windows made meanwhile is kept next to it.
function Restore-FixItFolder {
    param([string]$Path, [string]$Aside)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Restore-FixItFolder' -Arguments $PSBoundParameters; return }
    $leaf = Split-Path -Leaf $Path
    if ($leaf -notin @('SoftwareDistribution', 'catroot2')) { throw ('Refusing to touch {0}' -f $Path) }
    if (-not (Test-Path -LiteralPath $Aside)) { throw 'The saved folder is gone' }
    if (Test-Path -LiteralPath $Path) { Rename-Item -LiteralPath $Path -NewName ('{0}.fixit-new-{1}' -f $leaf, (Get-Date -Format 'yyyyMMddHHmm')) -ErrorAction Stop }
    Rename-Item -LiteralPath $Aside -NewName $leaf -ErrorAction Stop
}
function Get-FixItPendingUpdates {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItPendingUpdates' -Arguments $PSBoundParameters) }
    $s = New-Object -ComObject 'Microsoft.Update.Session'
    $r = $s.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0")
    return [int]$r.Updates.Count
}
function Get-FixItDefender {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItDefender' -Arguments $PSBoundParameters) }
    $m = Get-MpComputerStatus -ErrorAction Stop
    $q = $null; if ($m.QuickScanEndTime -and $m.QuickScanEndTime.Year -gt 2000) { $q = [datetime]$m.QuickScanEndTime }
    return [pscustomobject]@{ Enabled = [bool]$m.AMServiceEnabled; RealTime = [bool]$m.RealTimeProtectionEnabled; SignatureAgeDays = [int]$m.AntivirusSignatureAge; LastQuickScan = $q }
}
# Best effort: the newest time OneDrive wrote to its own logs.
function Get-FixItOneDriveLastSync {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItOneDriveLastSync' -Arguments $PSBoundParameters) }
    $dir = Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\logs'
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $f = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($f.Count -eq 0) { return $null }
    return [datetime]$f[0].LastWriteTime
}
# True when the website answers at all (even with an error page); false when it cannot be reached.
function Test-FixItHttps {
    param([string]$Url)
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Test-FixItHttps' -Arguments $PSBoundParameters) }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    try { Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10 -Method Head | Out-Null; return $true }
    catch { return ($null -ne (Get-FixItProp $_.Exception 'Response' $null)) }
}
function Restart-FixItNow {
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Restart-FixItNow' -Arguments $PSBoundParameters; return }
    Start-Process -FilePath 'shutdown.exe' -ArgumentList @('/r', '/t', '0', '/c', 'Family Fix-It: restarting your computer.') | Out-Null
}
function Test-FixItTask {
    param([string]$Name)
    $r = Invoke-FixItNative -File 'schtasks.exe' -Arguments @('/Query', '/TN', $Name)
    return ($r.ExitCode -eq 0)
}
function Register-FixItTask {
    param([string]$Name, [string]$Xml)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Register-FixItTask' -Arguments $PSBoundParameters; return }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('fixit-task-{0}.xml' -f ([guid]::NewGuid().ToString('N')))
    try {
        [IO.File]::WriteAllText($tmp, $Xml, [Text.Encoding]::Unicode)
        Invoke-FixItTool -File 'schtasks.exe' -Arguments @('/Create', '/TN', $Name, '/XML', $tmp, '/F')
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}
function Unregister-FixItTask {
    param([string]$Name)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Unregister-FixItTask' -Arguments $PSBoundParameters; return }
    Invoke-FixItTool -File 'schtasks.exe' -Arguments @('/Delete', '/TN', $Name, '/F')
}

# Runs one of this script's "...Admin" parts in a Windows-permission (UAC) window and waits for it.
function Start-FixItElevated {
    param([string]$Part, [string]$ResultPath, [switch]$Visible, [string]$InputPath)
    if ($script:TestMode) { throw 'Test mode never asks Windows for administrator rights.' }
    $q = { param($s) '"' + $s + '"' }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (& $q $script:SelfPath), '-Action', $Part,
        '-LogPath', (& $q $script:LogFile), '-ResultFile', (& $q $ResultPath))
    if ($InputPath) { $argList += @('-InputFile', (& $q $InputPath)) }
    $argList = $argList -join ' '
    $exe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $exe)) { $exe = 'powershell.exe' }
    $proc = Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs -WindowStyle $(if ($Visible) { 'Normal' } else { 'Hidden' }) -PassThru
    while (-not $proc.HasExited) { Wait-FixIt -Milliseconds 200 }
    return [int]$proc.ExitCode
}

# Is there a person who can answer a typed question? Adapter (replaced in the tests). Not when the program has no user session
# or its input is piped in. (A hidden console cannot be detected reliably - Windows Terminal's console window is always "hidden" -
# so hidden background runs are marked by the action name instead: see $script:BackgroundActions.)
function Test-FixItConsoleInteractive {
    try {
        if (-not [Environment]::UserInteractive) { return $false }
        if ([Console]::IsInputRedirected) { return $false }
    } catch { return $false }
    return $true
}
# True when a question may be asked: the window is open, or a person can type at the console. Background actions never ask.
function Test-FixItCanAsk {
    if ($script:GuiActive) { return $true }
    if ($script:Background) { return $false }
    return [bool](Test-FixItConsoleInteractive)
}

# Questions for the person. The window and the command line each supply their own.
function Confirm-FixIt {
    param([string]$Question, [string]$Title = 'Family Fix-It', [string]$Kind = '', [string]$Detail = '')
    if ($script:TestAll) { Write-FixItLog ('Test all: answered yes to: {0}' -f $Question) 'TEST'; return $true }
    if ($script:GuiActive) {
        if ($Kind -eq 'Fixed') { return (Show-FixItFixedDialog -Title $Question -Detail $Detail) }
        $r = [System.Windows.Forms.MessageBox]::Show($Question, $Title, 'YesNo', 'Question')
        return ($r -eq 'Yes')
    }
    if (-not (Test-FixItCanAsk)) { Write-FixItLog ('Nobody is there to answer, so the answer is no: {0}' -f $Question) 'WARN'; return $false }
    if ($Kind -eq 'Fixed') { $Question = $Question + ' ' + $Detail + " If it's still broken, I'll send Trey a report automatically." }
    $a = Read-Host ('{0} (Y/N)' -f $Question)
    return ($a -match '^(y|yes)$')
}

# ---------------------------------------------------------------------------
# Run something that needs administrator rights (only the parts that must)
# ---------------------------------------------------------------------------
function Invoke-AdminPart {
    param([string]$Part, [scriptblock]$InProcess, [switch]$Visible, [string]$InputPath)
    if ($script:DryRun -or (Test-FixItAdmin)) {
        if (-not $script:DryRun) { Write-FixItLog ('Already running as administrator; doing "{0}" directly' -f $Part) }
        return (& $InProcess)
    }
    Write-FixItLog ('Asking Windows for permission (administrator) to do: {0}' -f $Part)
    $resultPath = Join-Path ([IO.Path]::GetTempPath()) ('fixit-{0}.json' -f ([guid]::NewGuid().ToString('N')))
    try {
        $code = Start-FixItElevated -Part $Part -ResultPath $resultPath -Visible:$Visible -InputPath $InputPath
        if (Test-Path -LiteralPath $resultPath) {
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
            Merge-FixItUndoFromAdmin -Result $json
            return $json
        }
        Write-FixItLog ('The administrator step "{0}" ended (code {1}) without a result' -f $Part, $code) 'ERROR'
        return New-FixItResult $false 'Could not finish' 'The step that needs Windows permission did not finish.'
    } catch {
        Write-FixItLog ('Permission window was cancelled or failed: {0}' -f $_.Exception.Message) 'WARN'
        return New-FixItResult $false 'Permission needed' 'Windows asked for permission and it was not given, so this step was skipped.' @() @{ Declined = $true }
    }
}

# ---------------------------------------------------------------------------
# 1. Fix my printer
# ---------------------------------------------------------------------------
function Invoke-PrinterAdmin {
    $details = @()
    $ok = $true
    $cleared = 0
    $state = $null
    try { $state = Get-SpoolerState } catch {
        Write-FixItLog ('Could not read the Print Spooler: {0}' -f $_.Exception.Message) 'ERROR'
    }
    if (-not $state) {
        return New-FixItResult $false 'Printer' 'Windows printing service could not be found on this computer.' @() @{ Cleared = 0 }
    }
    Write-FixItLog ('Print Spooler is {0} (start type {1})' -f $state.Status, $state.StartType)

    if ($state.Status -ne 'Stopped') {
        if (-not (Invoke-FixItStep 'Stop the Print Spooler service' { Stop-SpoolerService })) { $ok = $false }
    }

    $files = @()
    try { $files = @(Get-SpoolFiles) } catch {
        Write-FixItLog ('Could not look in the spool folder: {0}' -f $_.Exception.Message) 'WARN'
        if (-not $script:DryRun) { $ok = $false }
    }
    Write-FixItLog ('Found {0} stuck print file(s) in the spool folder' -f $files.Count)
    $jobNames = @{}
    foreach ($f in $files) {
        if (Invoke-FixItStep ('Delete stuck print file {0}' -f $f.Name) { Remove-SpoolFile -FullName $f.FullName }) {
            $jobNames[[IO.Path]::GetFileNameWithoutExtension($f.Name)] = $true
        } else { $ok = $false }
    }
    $cleared = $jobNames.Count

    if ($state.StartType -eq 'Disabled') {
        $details += 'The printing service was switched off in Windows settings.'
        if (-not (Invoke-FixItStep 'Set Print Spooler to start automatically' { Set-FixItServiceStartType -Name 'Spooler' -StartType 'Automatic' })) { $ok = $false }
    }
    if (-not (Invoke-FixItStep 'Start the Print Spooler service' { Start-SpoolerService })) { $ok = $false }

    if ($ok) {
        return New-FixItResult $true 'Printing service restarted' 'The Windows printing service was restarted.' $details @{ Cleared = $cleared }
    }
    return New-FixItResult $false 'Printing service problem' 'The Windows printing service could not be fully restarted.' $details @{ Cleared = $cleared }
}

function Invoke-PrinterRefreshUser {
    $notes = @()
    $fixed = 0
    $problems = 0
    $printers = @()
    try { $printers = @(Get-FixItPrinters) } catch {
        Write-FixItLog ('Could not list printers: {0}' -f $_.Exception.Message) 'ERROR'
        return [pscustomobject]@{ Fixed = 0; Problems = 1; Notes = @('Could not get the list of printers.'); Count = 0 }
    }
    Write-FixItLog ('Found {0} printer(s)' -f $printers.Count)
    $default = $printers | Where-Object { $_.IsDefault } | Select-Object -First 1

    foreach ($p in $printers) {
        $bad = ($p.WorkOffline -or $p.StatusText -match 'Offline|Error|Unknown')
        Write-FixItLog ('Printer "{0}": network={1} status={2} workOffline={3} default={4}' -f $p.Name, $p.IsNetwork, $p.StatusText, $p.WorkOffline, $p.IsDefault)
        if (-not $bad) { continue }
        if (-not $p.IsNetwork) {
            $notes += ('"{0}" says it is offline. Check that it is turned on and plugged in or on Wi-Fi.' -f $p.Name)
            $problems++
            continue
        }
        if (-not (Test-HostReachable -ComputerName $p.Server)) {
            Write-FixItLog ('Cannot reach {0}' -f $p.Server) 'WARN'
            $notes += ('"{0}" is shared from another computer ({1}) that could not be reached. Make sure that computer is on and you are on the home network.' -f $p.Name, $p.Server)
            $problems++
            continue
        }
        $removed = Invoke-FixItStep ('Remove disconnected network printer {0}' -f $p.Name) { Remove-FixItPrinter -Name $p.Name }
        $added = $false
        if ($removed) {
            $added = Invoke-FixItStep ('Add network printer {0} back' -f $p.Name) { Add-FixItPrinterConnection -Name $p.Name }
            if (-not $added -and -not $script:DryRun) {
                $added = Invoke-FixItStep ('Try again to add network printer {0}' -f $p.Name) { Wait-FixIt -Seconds 2; Add-FixItPrinterConnection -Name $p.Name }
            }
        }
        if ($removed -and $added) { $fixed++ } else {
            $problems++
            $notes += ('"{0}" could not be reconnected. Trey may need to set it up again.' -f $p.Name)
        }
    }
    if ($fixed -gt 0 -and $default -and $default.IsNetwork) {
        Invoke-FixItStep ('Make {0} the default printer again' -f $default.Name) { Set-FixItDefaultPrinter -Name $default.Name } | Out-Null
    }
    return [pscustomobject]@{ Fixed = $fixed; Problems = $problems; Notes = $notes; Count = $printers.Count }
}

function Invoke-PrinterFix {
    Write-FixItLog 'Started: Fix my printer'
    $before = @()
    try { $before = @(Get-FixItPrinters) } catch { Write-FixItLog ('Could not list printers: {0}' -f $_.Exception.Message) 'ERROR' }
    $pickable = @(Get-FixItPickablePrinters -Printers $before)
    $oldDefault = ''
    $dflt = @($before | Where-Object { $_.IsDefault } | Select-Object -First 1)
    if ($dflt.Count -gt 0) { $oldDefault = [string]$dflt[0].Name }

    # First question: do they already know which printer they want?
    $mode = 'none'      # none = no printers on this computer, pick = they chose one, auto = I choose
    $chosen = ''
    if ($pickable.Count -gt 0) {
        $mode = 'auto'
        if (Confirm-FixItStep "Do you know which printer you're trying to use?") {
            $mode = 'pick'
            if ($script:DryRun) {
                Write-FixItLog 'Would do: show the list of printers and make the one you pick your default printer' 'DRYRUN'
            } else {
                $names = @($pickable | ForEach-Object { [string]$_.Name })
                $chosen = [string](Select-FixItPrinter -Names $names -Current $oldDefault)
                if (-not $chosen) {
                    Write-FixItLog 'Printer fix: nothing was picked, so nothing was changed'
                    return New-FixItResult $true 'Nothing changed' 'OK, nothing was changed.' @() @{ SkipFollowUp = $true }
                }
                Write-FixItLog ('Printer picked from the list: {0}' -f $chosen)
            }
        } else {
            if ($script:DryRun) { Write-FixItLog 'Would do: test every printer and make one that works your default printer' 'DRYRUN' }
        }
    } else {
        Write-FixItLog 'No printers were found on this computer' 'WARN'
    }

    $admin = Invoke-AdminPart -Part 'PrinterAdmin' -InProcess { Invoke-PrinterAdmin }
    $adminOk = [bool]$admin.Ok
    if (-not $adminOk -and (($admin.PSObject.Properties.Name -contains 'Declined') -and $admin.Declined)) {
        Write-FixItLog 'Printer fix stopped: permission was not given' 'WARN'
        return New-FixItResult $false 'Printer not fixed' 'Windows needs your permission to restart printing, and it was not given. Please click the button again and choose Yes when Windows asks.'
    }
    $user = Invoke-PrinterRefreshUser

    $lines = @()
    if ($adminOk -and ($admin.PSObject.Properties.Name -contains 'Cleared')) {
        if ([int]$admin.Cleared -gt 0) { $lines += ('Cleared {0} stuck print job(s).' -f $admin.Cleared) }
        else { $lines += 'There were no stuck print jobs.' }
    }
    if ($user.Fixed -gt 0) { $lines += ('Reconnected {0} network printer(s).' -f $user.Fixed) }

    # Which printer ends up as the default
    $now = @()
    if ($mode -ne 'none') { try { $now = @(Get-FixItPrinters) } catch { Write-FixItLog ('Could not list printers again: {0}' -f $_.Exception.Message) 'ERROR' } }
    $pickNow = @(Get-FixItPickablePrinters -Printers $now)
    $picked = ''          # the printer that is now the default (or would be)
    $pickedOk = $true
    $headline = ''
    $problemText = ''
    if ($mode -eq 'pick' -and -not $script:DryRun) {
        $target = @($now | Where-Object { [string]$_.Name -eq $chosen } | Select-Object -First 1)
        if ($target.Count -eq 0) {
            $pickedOk = $false
            $problemText = ('"{0}" is not in the printer list any more. Trey may need to set it up again.' -f $chosen)
        } else {
            $t = Test-FixItPrinterAvailable -Printer $target[0]
            $curNow = ''
            $cd = @($now | Where-Object { $_.IsDefault } | Select-Object -First 1)
            if ($cd.Count -gt 0) { $curNow = [string]$cd[0].Name }
            if ($curNow -ne $chosen) {
                $setOk = Set-FixItPrinterAsDefault -Name $chosen -Previous $curNow
                if (-not $setOk) { $pickedOk = $false; $problemText = ('Windows would not let me make "{0}" your default printer.' -f $chosen) }
            } else {
                $lines += ('"{0}" was already your default printer.' -f $chosen)
            }
            if ($pickedOk) {
                $picked = $chosen
                if ($t.Ok) {
                    $headline = ('"{0}" is now your default printer, so Windows will use it first whenever you print.' -f $chosen)
                } else {
                    $pickedOk = $false
                    $problemText = ('"{0}" is now your default printer, but it is not answering ({1}). Check that it is turned on, has paper, and is plugged in or on Wi-Fi.' -f $chosen, $t.Why)
                }
            }
        }
    } elseif ($mode -eq 'auto' -and -not $script:DryRun) {
        $good = @()
        foreach ($pp in $pickNow) {
            $tt = Test-FixItPrinterAvailable -Printer $pp
            if ($tt.Ok) { $lines += ('Tested "{0}": ready.' -f $pp.Name); $good += $pp }
            else { $lines += ('Tested "{0}": not available ({1}).' -f $pp.Name, $tt.Why) }
        }
        if ($good.Count -eq 0) {
            $pickedOk = $false
            $problemText = 'I tested every printer on this computer and none of them is available right now. Check that your printer is turned on, has paper, and is plugged in or on Wi-Fi. If it still does not work, please call Trey.'
        } else {
            $best = $good[0]
            foreach ($g in $good) { if ($g.IsDefault) { $best = $g; break } }
            $curNow = ''
            $cd = @($now | Where-Object { $_.IsDefault } | Select-Object -First 1)
            if ($cd.Count -gt 0) { $curNow = [string]$cd[0].Name }
            $setOk = $true
            if ($curNow -ne [string]$best.Name) { $setOk = Set-FixItPrinterAsDefault -Name ([string]$best.Name) -Previous $curNow }
            if ($setOk) {
                $picked = [string]$best.Name
                $headline = ('I tested your printers. "{0}" is working, so I made it your default printer. Please print to it.' -f $picked)
                if ($curNow -eq $picked) { $headline = ('I tested your printers. "{0}" is working and it is already your default printer. Please print to it.' -f $picked) }
            } else {
                $pickedOk = $false
                $problemText = ('"{0}" is working, but Windows would not let me make it your default printer.' -f $best.Name)
            }
        }
    }
    foreach ($n in @($user.Notes)) { $lines += $n }
    $lines += @($admin.Details)

    if ($script:DryRun) {
        $msg = 'Practice run only - nothing was changed. Details are in the log file.'
        Write-FixItLog 'Finished (practice run): Fix my printer'
        return New-FixItResult $true 'Practice run' $msg $lines
    }
    if (-not $adminOk) {
        Write-FixItLog 'Finished: Fix my printer - could not restart printing' 'ERROR'
        return New-FixItResult $false 'Printer not fixed' 'We could not restart printing. Please click "Something else is wrong" and send Trey the report.' $lines
    }
    if ($pickedOk) {
        Write-FixItLog 'Finished: Fix my printer - success'
        $m = 'Your printing should be working again. Please try printing now.'
        if ($headline) { $m = $m + "`r`n`r`n" + $headline }
        return New-FixItResult $true 'Printer fixed' $m $lines @{ DefaultPrinter = $picked }
    }
    Write-FixItLog ('Finished: Fix my printer - printing restarted but: {0}' -f $problemText) 'WARN'
    $m2 = 'Printing was restarted, but there is still a problem.' + "`r`n`r`n" + $problemText
    return New-FixItResult $false 'Almost there' $m2 $lines @{ DefaultPrinter = $picked }
}

# ---------------------------------------------------------------------------
# 2. Fix Acrobat in Outlook
# ---------------------------------------------------------------------------
function Get-AddinKeyPaths {
    return @(
        ('HKCU:\Software\Microsoft\Office\Outlook\Addins\{0}' -f $script:AddinName),
        ('HKLM:\SOFTWARE\Microsoft\Office\Outlook\Addins\{0}' -f $script:AddinName),
        ('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\Outlook\Addins\{0}' -f $script:AddinName)
    )
}

function Test-IsPdfMakerEntry {
    param([string]$Name, $Value)
    if ($Name -match 'PDFMaker') { return $true }
    if ($Value -is [array] -and $Value -isnot [byte[]]) {
        try { $Value = [byte[]]$Value } catch { return $false }
    }
    if ($Value -is [byte[]]) {
        $u = [Text.Encoding]::Unicode.GetString($Value)
        $a = [Text.Encoding]::ASCII.GetString($Value)
        return (($u -match 'PDFMaker') -or ($a -match 'PDFMaker'))
    }
    if ($Value -is [string]) { return ($Value -match 'PDFMaker') }
    return $false
}

function Get-AddinState {
    $state = @()
    foreach ($p in (Get-AddinKeyPaths)) {
        if (Test-RegKey -Path $p) {
            $lb = Get-RegValue -Path $p -Name 'LoadBehavior'
            $state += [pscustomobject]@{ Path = $p; Present = $true; LoadBehavior = $lb; IsMachineWide = $p.StartsWith('HKLM') }
        }
    }
    return $state
}

function Get-ResiliencyHits {
    $hits = @()
    foreach ($v in $script:OfficeVersions) {
        $base = 'HKCU:\Software\Microsoft\Office\{0}\Outlook\Resiliency' -f $v
        foreach ($list in @('DisabledItems', 'CrashingAddinList')) {
            $path = '{0}\{1}' -f $base, $list
            foreach ($n in @(Get-RegValueNames -Path $path)) {
                if (Test-IsPdfMakerEntry -Name $n -Value (Get-RegValue -Path $path -Name $n)) {
                    $hits += [pscustomobject]@{ Path = $path; Name = $n; List = $list }
                }
            }
        }
    }
    return $hits
}

function Invoke-AcrobatAdmin {
    $changed = 0
    $ok = $true
    foreach ($s in @(Get-AddinState | Where-Object { $_.IsMachineWide })) {
        if ($s.LoadBehavior -ne 3) {
            Write-FixItLog ('{0}: LoadBehavior is {1}, needs to be 3' -f $s.Path, $s.LoadBehavior)
            $path = $s.Path
            if (Invoke-FixItStep ('Set LoadBehavior=3 at {0}' -f $path) { Set-RegDword -Path $path -Name 'LoadBehavior' -Value 3 }) { $changed++ } else { $ok = $false }
        } else {
            Write-FixItLog ('{0}: LoadBehavior already 3' -f $s.Path)
        }
    }
    return New-FixItResult $ok 'Acrobat add-in (all users)' $(if ($ok) { 'Done' } else { 'Some settings could not be changed.' }) @() @{ Changed = $changed }
}

function Invoke-AcrobatUser {
    $changed = 0
    $ok = $true
    foreach ($s in @(Get-AddinState | Where-Object { -not $_.IsMachineWide })) {
        if ($s.LoadBehavior -ne 3) {
            Write-FixItLog ('{0}: LoadBehavior is {1}, needs to be 3' -f $s.Path, $s.LoadBehavior)
            $path = $s.Path
            if (Invoke-FixItStep ('Set LoadBehavior=3 at {0}' -f $path) { Set-RegDword -Path $path -Name 'LoadBehavior' -Value 3 }) { $changed++ } else { $ok = $false }
        } else {
            Write-FixItLog ('{0}: LoadBehavior already 3' -f $s.Path)
        }
    }
    foreach ($h in @(Get-ResiliencyHits)) {
        $hp = $h.Path; $hn = $h.Name
        if (Invoke-FixItStep ('Remove Outlook "{0}" entry {1} for the Acrobat add-in' -f $h.List, $hn) { Remove-RegValue -Path $hp -Name $hn }) { $changed++ } else { $ok = $false }
    }
    foreach ($v in $script:OfficeVersions) {
        $list = 'HKCU:\Software\Microsoft\Office\{0}\Outlook\Resiliency\DoNotDisableAddinList' -f $v
        $officeRoot = 'HKCU:\Software\Microsoft\Office\{0}\Outlook' -f $v
        if (-not (Test-RegKey -Path $officeRoot)) { continue }
        $cur = Get-RegValue -Path $list -Name $script:AddinName
        if ($cur -ne 1) {
            if (Invoke-FixItStep ('Tell Outlook {0} never to disable the Acrobat add-in' -f $v) { Set-RegDword -Path $list -Name $script:AddinName -Value 1 }) { $changed++ } else { $ok = $false }
        } else {
            Write-FixItLog ('Outlook {0}: Acrobat add-in already on the never-disable list' -f $v)
        }
    }
    return New-FixItResult $ok 'Acrobat add-in (this user)' $(if ($ok) { 'Done' } else { 'Some settings could not be changed.' }) @() @{ Changed = $changed }
}

function Select-AcrobatProducts {
    param($Products)
    $out = @()
    foreach ($p in @($Products)) {
        if ($p -and $p.DisplayName -match '^Adobe Acrobat' -and $p.DisplayName -notmatch 'Reader') { $out += $p }
    }
    return $out
}

function Test-AcrobatAddinHealthy {
    $s = @(Get-AddinState)
    if ($s.Count -eq 0) { return $false }
    foreach ($x in $s) { if ($x.LoadBehavior -ne 3) { return $false } }
    if (@(Get-ResiliencyHits).Count -gt 0) { return $false }
    return $true
}

function Invoke-AcrobatRepairAdmin {
    $products = @(Select-AcrobatProducts (Get-InstalledProducts) | Where-Object { $_.WindowsInstaller -and $_.ProductCode })
    if ($products.Count -eq 0) {
        Write-FixItLog 'No Windows Installer based Acrobat found to repair' 'WARN'
        return New-FixItResult $false 'Acrobat repair' 'No repairable copy of Acrobat was found.' @() @{ NotFound = $true }
    }
    $ok = $true
    $reboot = $false
    foreach ($prod in $products) {
        if ($script:DryRun) { [void](Invoke-FixItStep ('Repair {0} with msiexec /fa {1}' -f $prod.DisplayName, $prod.ProductCode) { [void](Invoke-Msi -ProductCode $prod.ProductCode) }); continue }
        Write-FixItLog ('Doing: Repair {0} with msiexec /fa {1}' -f $prod.DisplayName, $prod.ProductCode)
        try {
            $code = Invoke-Msi -ProductCode $prod.ProductCode
            Write-FixItLog ('msiexec finished with code {0}' -f $code)
            if ($code -eq 3010 -or $code -eq 1641) { $reboot = $true }
            elseif ($code -ne 0) { $ok = $false }
        } catch {
            Write-FixItLog ('FAILED: repair -- {0}' -f $_.Exception.Message) 'ERROR'
            $ok = $false
        }
    }
    return New-FixItResult $ok 'Acrobat repair' $(if ($ok) { 'Done' } else { 'The repair did not finish.' }) @() @{ Reboot = $reboot }
}

function Invoke-AcrobatRepair {
    Write-FixItLog 'Started: Repair Acrobat'
    $products = @(Select-AcrobatProducts (Get-InstalledProducts))
    if ($products.Count -eq 0) {
        Write-FixItLog 'Acrobat (full version) not found' 'WARN'
        return New-FixItResult $false 'Acrobat not found' 'The full version of Adobe Acrobat does not seem to be installed on this computer. Please click "Something else is wrong" and send Trey the report.'
    }
    if ($script:TestMode) { [void](Invoke-FixItStep 'Ask Acrobat to close if it is open' { Request-AppClose -ProcessNames @('Acrobat', 'AcroCEF', 'AcroRd32') }) }
    if (@(Get-RunningApp -ProcessNames @('Acrobat', 'AcroCEF', 'AcroRd32')).Count -gt 0 -and -not $script:DryRun) {
        if (Confirm-FixIt 'Acrobat is open. It needs to be closed before it can be repaired. Close it now? (Save your work first.)') {
            Request-AppClose -ProcessNames @('Acrobat', 'AcroCEF', 'AcroRd32')
        }
        if (@(Get-RunningApp -ProcessNames @('Acrobat', 'AcroRd32')).Count -gt 0) {
            return New-FixItResult $false 'Acrobat is still open' 'Please close Acrobat and then click the button again.'
        }
    }
    $outlookWasOpen = (@(Get-RunningApp -ProcessNames $script:OutlookProcessNames).Count -gt 0)
    if ($outlookWasOpen) {
        $cr = Close-FixItOutlookForFix -Question "Outlook is open. It has to be closed completely for the repair, and I will open it again afterwards.`r`n`r`nPlease save or send anything you are writing first.`r`n`r`nClose Outlook now?"
        if ($cr -ne 'closed') { return (New-FixItOutlookCloseResult -State $cr) }
    }
    $r = Invoke-AdminPart -Part 'AcrobatRepairAdmin' -InProcess { Invoke-AcrobatRepairAdmin }
    if ($outlookWasOpen) { [void](Open-FixItOutlookForFix) }
    if ($script:DryRun) { return New-FixItResult $true 'Practice run' 'Practice run only - nothing was changed. Details are in the log file.' }
    if ($r.Ok) {
        Write-FixItLog 'Finished: Repair Acrobat - success'
        $extra = ''
        if (($r.PSObject.Properties.Name -contains 'Reboot') -and $r.Reboot) { $extra = ' Windows says it needs a restart to finish - please restart the computer when convenient.' }
        return New-FixItResult $true 'Acrobat repaired' ('Acrobat was repaired. Please open Outlook and check again.' + $extra)
    }
    Write-FixItLog 'Finished: Repair Acrobat - failed' 'ERROR'
    return New-FixItResult $false 'Acrobat not repaired' 'We could not repair Acrobat automatically. You can try it yourself: open Acrobat, click Help, then "Repair Installation". Or click "Something else is wrong" and send Trey the report.'
}

function Invoke-AcrobatFix {
    Write-FixItLog 'Started: Fix Acrobat in Outlook'
    $products = @(Get-InstalledProducts)
    $acrobat = @(Select-AcrobatProducts $products)
    if ($acrobat.Count -eq 0) {
        $reader = @($products | Where-Object { $_.DisplayName -match '^Adobe (Acrobat )?Reader' })
        Write-FixItLog ('Full Acrobat not found (Reader installed: {0})' -f ($reader.Count -gt 0)) 'WARN'
        if ($reader.Count -gt 0) {
            return New-FixItResult $false 'Different Acrobat' 'This computer has Adobe Reader, which does not add anything to Outlook. Only the full Adobe Acrobat does. Please ask Trey.'
        }
        return New-FixItResult $false 'Acrobat not found' 'Adobe Acrobat does not seem to be installed on this computer. Please ask Trey.'
    }

    # Step 1: the gentle fix. Close every Outlook program, open it again, and ask.
    $closeQ = "Outlook is open. To fix the Acrobat buttons, I first need to close Outlook completely - including the parts running in the background - and then open it again.`r`n`r`nPlease save or send anything you are writing first.`r`n`r`nClose Outlook now?"
    $c = Close-FixItOutlookForFix -Question $closeQ
    if ($c -ne 'closed') { return (New-FixItOutlookCloseResult -State $c) }
    if (-not (Open-FixItOutlookForFix)) { return (New-FixItOutlookOpenFailResult) }
    if ($script:DryRun) {
        Write-FixItLog 'Would ask: Is Acrobat showing up in Outlook? (If yes, I stop here. If not, the next steps below happen.)' 'DRYRUN'
    } else {
        $w1 = Confirm-FixIt "Outlook is opening again - give it a moment.`r`n`r`nPlease look for Acrobat in Outlook (an Acrobat tab or Create PDF buttons).`r`n`r`nIs Acrobat showing up in Outlook?"
        Write-FixItLog ('Asked: Is Acrobat showing up in Outlook? -> {0}' -f $(if ($w1) { 'yes' } else { 'no' })) $(if ($w1) { 'INFO' } else { 'WARN' })
        if ($w1) {
            Write-FixItLog 'Finished: Fix Acrobat in Outlook - fixed by closing and opening Outlook again'
            return New-FixItResult $true 'Acrobat fixed' ("Great - Acrobat is working in Outlook again.`r`n`r`nI only closed Outlook completely and opened it again. " + $script:OutlookKeepText) @() @{ SkipFollowUp = $true }
        }
        if (-not (Confirm-FixIt "Sorry about that. The next step is to switch the Acrobat add-in back on in Outlook's settings. Outlook will close once more for this.`r`n`r`nYour email accounts and sign-ins will not be touched.`r`n`r`nContinue?")) {
            return New-FixItResult $false 'Acrobat still needs help' "OK, I stopped here. Acrobat is still not showing in Outlook.`r`n`r`nPlease call Trey." @($script:OutlookKeepText) @{ SkipFollowUp = $true }
        }
    }

    # Step 2: only because it is still not working.
    $c2 = Close-FixItOutlookFully
    if ($c2 -ne 'closed') { return (New-FixItOutlookCloseResult -State $c2) }

    $before = @(Get-AddinState)
    $hits = @(Get-ResiliencyHits)
    if ($before.Count -eq 0) {
        Write-FixItLog 'Acrobat is installed but its Outlook add-in is not registered anywhere' 'WARN'
    } else {
        foreach ($b in $before) { Write-FixItLog ('Add-in at {0}: LoadBehavior={1}' -f $b.Path, $b.LoadBehavior) }
    }
    Write-FixItLog ('Outlook has the Acrobat add-in in its disabled/crashed lists: {0} entr(ies)' -f $hits.Count)

    $user = Invoke-AcrobatUser
    $machineNeeds = @($before | Where-Object { $_.IsMachineWide -and $_.LoadBehavior -ne 3 }).Count -gt 0
    $adminResult = $null
    if ($machineNeeds) {
        $adminResult = Invoke-AdminPart -Part 'AcrobatAdmin' -InProcess { Invoke-AcrobatAdmin }
        if (-not $script:DryRun -and -not $adminResult.Ok -and (($adminResult.PSObject.Properties.Name -contains 'Declined') -and $adminResult.Declined)) {
            return New-FixItResult $false 'Permission needed' 'Windows needs your permission to finish this fix, and it was not given. Please click the button again and choose Yes when Windows asks.'
        }
    }

    if ($script:DryRun) {
        Write-FixItLog 'Finished (practice run): Fix Acrobat in Outlook'
        return New-FixItResult $true 'Practice run' 'Practice run only - nothing was changed. Details are in the log file.' @($script:OutlookKeepText)
    }

    $healthy = Test-AcrobatAddinHealthy
    $changedUser = [int]$user.Changed
    $changedAdmin = 0
    if ($adminResult -and ($adminResult.PSObject.Properties.Name -contains 'Changed')) { $changedAdmin = [int]$adminResult.Changed }
    Write-FixItLog ('Add-in settings now healthy: {0}; changes made: {1}' -f $healthy, ($changedUser + $changedAdmin))

    if (-not $healthy) {
        Write-FixItLog 'Add-in settings still not right after the fix' 'WARN'
        if (Confirm-FixIt 'The Acrobat add-in is not set up correctly on this computer, so Acrobat may need to be repaired (this takes a few minutes and Windows will ask for permission). Repair Acrobat now?') {
            return Invoke-AcrobatRepair
        }
        return New-FixItResult $false 'Acrobat still needs help' 'The Acrobat add-in could not be switched back on. You can click this button again later, or click "Something else is wrong" and send Trey the report.'
    }

    $said = 'Done. The Acrobat add-in is switched back on.'
    if (($changedUser + $changedAdmin) -eq 0) { $said = 'The Acrobat add-in was already switched on, so nothing needed changing.' }
    Write-FixItLog 'Settings fixed; opening Outlook and asking the person to check'
    if (-not (Open-FixItOutlookForFix)) { return (New-FixItOutlookOpenFailResult) }
    $works = Confirm-FixIt ($said + "`r`n`r`nOutlook is opening again - give it a moment, then look for Acrobat (an Acrobat tab or Create PDF buttons).`r`n`r`nIs Acrobat showing up in Outlook?")
    if ($works) {
        Write-FixItLog 'Finished: Fix Acrobat in Outlook - success (confirmed by user)'
        return New-FixItResult $true 'Acrobat fixed' 'Great - Acrobat is working in Outlook again.' @($script:OutlookKeepText) @{ SkipFollowUp = $true }
    }
    Write-FixItLog 'User says Acrobat is still missing in Outlook' 'WARN'
    if (Confirm-FixIt 'Sorry about that. The next step is to repair Acrobat. It takes a few minutes and Windows will ask for permission. Repair Acrobat now?') {
        return Invoke-AcrobatRepair
    }
    return New-FixItResult $false 'Acrobat still needs help' 'Acrobat is still not showing in Outlook. Please click "Something else is wrong" and send Trey the report.'
}

# ---------------------------------------------------------------------------
# 3. Something else is wrong: make a report (never sends anything)
# ---------------------------------------------------------------------------
# True when an error means "you are not an administrator" (access denied and friends).
function Test-FixItAccessDenied {
    param($Err)
    if ($null -eq $Err) { return $false }
    $e = $Err
    if ($Err -is [System.Management.Automation.ErrorRecord]) {
        $e = $Err.Exception
        try { if ([string]$Err.CategoryInfo.Category -eq 'PermissionDenied') { return $true } } catch { }
    }
    $n = 0
    while ($null -ne $e -and $n -lt 5) {
        if ($e -is [UnauthorizedAccessException] -or $e -is [System.Security.SecurityException]) { return $true }
        if ([string]$e.Message -match '(?i)access.{0,60}denied|unauthorized|not authorized|requires elevation|elevated|privilege|0x80041003') { return $true }
        $e = $e.InnerException
        $n++
    }
    return $false
}

# Plain note for the report when one item could not be read. The technical reason goes only in the log.
function Get-FixItReportItemNote {
    param([string]$Label, $Err)
    $why = ''; try { $why = [string]$Err.Exception.Message } catch { $why = [string]$Err }
    if (Test-FixItAccessDenied -Err $Err) {
        Write-FixItLog ('Report item "{0}" needs administrator rights, so it was left out: {1}' -f $Label, $why)
        return ('{0}: not shown (needs administrator rights)' -f $Label)
    }
    Write-FixItLog ('Report item "{0}" could not be read: {1}' -f $Label, $why) 'WARN'
    return ('{0}: not available on this PC' -f $Label)
}

# One small piece of a report section. If it fails, only this piece becomes a short note; the rest of the section still shows.
function Invoke-ReportItem {
    param([string]$Label, [scriptblock]$Body)
    $lines = @()
    try { $lines = @(& $Body) } catch { return @(Get-FixItReportItemNote -Label $Label -Err $_) }
    return $lines
}

function Add-ReportSection {
    param([System.Collections.Generic.List[string]]$Out, [string]$Title, [scriptblock]$Body)
    $Out.Add('')
    $Out.Add('=== ' + $Title + ' ===')
    try {
        foreach ($l in @(& $Body)) { $Out.Add([string]$l) }
    } catch {
        $Out.Add((Get-FixItReportItemNote -Label 'This part' -Err $_))
    }
}

function Format-EventLines {
    param($Events)
    $e = @($Events | Where-Object { $null -ne $_ })
    if ($e.Count -eq 0) { return @('No errors in the last 7 days.') }
    foreach ($x in $e) {
        $m = ([string]$x.Message) -replace '\s+', ' '
        if ($m.Length -gt 300) { $m = $m.Substring(0, 300) + '...' }
        '{0}  {1} (ID {2}): {3}' -f ([datetime]$x.TimeCreated).ToString('yyyy-MM-dd HH:mm'), $x.ProviderName, $x.Id, $m
    }
}

function Format-FixItPrintJobLine {
    param($Jobs)
    $j = @($Jobs | Where-Object { $null -ne $_ })
    if ($j.Count -eq 0) { return '      Waiting print jobs: 0' }
    $sts = @($j | ForEach-Object { [string]$_.Status } | Where-Object { $_ } | Sort-Object -Unique)
    $old = ''
    $subs = @($j | Where-Object { $_.Submitted } | ForEach-Object { [datetime]$_.Submitted } | Sort-Object)
    if ($subs.Count -gt 0) { $old = ', oldest submitted {0}' -f $subs[0].ToString('yyyy-MM-dd HH:mm') }
    return ('      Waiting print jobs: {0}{1}{2}' -f $j.Count, $old, $(if ($sts.Count -gt 0) { ' (status: ' + ($sts -join ', ') + ')' } else { '' }))
}

function Get-FixItReportText {
    param([ValidateSet('report', 'scam')][string]$Kind = 'report', [string]$Note = '')
    $o = New-Object 'System.Collections.Generic.List[string]'
    if ($Kind -eq 'scam') { $o.Add('FAMILY FIX-IT *** SCAM ALERT ***'); $o.Add('A scary pop-up alert (the red button, or the pop-up watcher). Call them now.') }
    else { $o.Add('FAMILY FIX-IT REPORT') }
    $o.Add('Made: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + '   Tool version: ' + $script:FixItVersion)
    foreach ($l in (Invoke-ReportItem 'PC code' { Get-FixItPcCodeLine })) { $o.Add([string]$l) }
    $o.Add('This report is saved on the Desktop and sent to Trey by the tool.')
    $o.Add('(It includes the computer name, the Windows user name and the printer names.)')
    if ($Note) { $o.Add(''); $o.Add('NOTE: ' + $Note) }

    Add-ReportSection $o 'Windows' {
        $info = $null
        try { $info = Get-FixItOsInfo } catch { Get-FixItReportItemNote -Label 'Windows details' -Err $_ }
        if ($info) {
            'Computer name: ' + $info.ComputerName
            'Windows user: ' + $info.UserName
            'Windows: {0} (version {1}, build {2}, {3})' -f $info.Caption, $info.Version, $info.Build, $info.Arch
            'Last restarted: ' + $info.LastBoot
            'Free space on C: ' + $(if ($null -ne $info.FreeGB) { '{0} GB' -f $info.FreeGB } else { 'unknown' })
        } else {
            'Computer name: ' + $env:COMPUTERNAME
            'Windows user: ' + $env:USERNAME
        }
        Invoke-ReportItem 'Running as administrator' { 'Running as administrator: ' + (Test-FixItAdmin) }
    }
    if ($Kind -eq 'scam') { Add-ReportSection $o 'Scam check: remote-control programs, recent installs and downloads' { Get-FixItScamLines } }
    Add-ReportSection $o 'Health check' { Get-FixItHealthLines }
    Add-ReportSection $o 'Printing' {
        Invoke-ReportItem 'Print Spooler service' {
            $s = Get-SpoolerState
            'Print Spooler service: {0} (starts: {1})' -f $s.Status, $s.StartType
        }
        # The spool folder can only be read by an administrator. A normal user gets the per-printer job lists below instead.
        if (Test-FixItAdmin) {
            Invoke-ReportItem 'Files waiting in the print queue folder' { 'Files waiting in the print queue folder: ' + @(Get-SpoolFiles).Count }
        } else {
            'Print queue folder: not checked (it needs administrator rights). Waiting print jobs are listed for each printer instead.'
        }
        $ctx = @{ Printers = @(); Jobs = 0 }
        Invoke-ReportItem 'Printers' {
            $ctx.Printers = @(Get-FixItPrinters)
            'Printers found: ' + $ctx.Printers.Count
        }
        foreach ($p in @($ctx.Printers)) {
            Invoke-ReportItem ('Printer ' + [string]$p.Name) {
                '  - {0}{1}  [{2}] status={3}{4}' -f $p.Name, $(if ($p.IsDefault) { ' (default)' } else { '' }), $(if ($p.IsNetwork) { 'network' } else { 'local/direct' }), $p.StatusText, $(if ($p.WorkOffline) { ' OFFLINE' } else { '' })
            }
            Invoke-ReportItem '      Waiting print jobs' {
                $jobs = @(Get-FixItPrintJobs -PrinterName ([string]$p.Name))
                $ctx.Jobs += $jobs.Count
                Format-FixItPrintJobLine -Jobs $jobs
            }
        }
    }
    Add-ReportSection $o 'Outlook' {
        Invoke-ReportItem 'Outlook details' {
            $ol = Get-OutlookInfo
            'Outlook installed: ' + $ol.Installed
            if ($ol.Installed) { 'Outlook version: {0} {1}' -f $ol.Version, $ol.Bitness }
        }
        Invoke-ReportItem 'Outlook open right now' { 'Outlook open right now: ' + (@(Get-RunningApp -ProcessNames @('OUTLOOK')).Count -gt 0) }
    }
    Add-ReportSection $o 'Acrobat' {
        Invoke-ReportItem 'Installed Acrobat programs' {
            $allProducts = @(Get-InstalledProducts)
            $ac = @($allProducts | Where-Object { $_.DisplayName -match 'Acrobat' })
            if ($ac.Count -eq 0) { 'No Adobe Acrobat or Reader found in the list of installed programs.' }
            foreach ($a in $ac) { '{0}  version {1}{2}' -f $a.DisplayName, $a.DisplayVersion, $(if ($a.WindowsInstaller) { '  (repairable)' } else { '' }) }
        }
        Invoke-ReportItem 'Acrobat.exe file version' {
            $exe = Get-FixItFileVersion -ExeName 'Acrobat.exe'
            if ($exe) { 'Acrobat.exe file version: ' + $exe }
        }
    }
    Add-ReportSection $o 'Acrobat add-in in Outlook' {
        Invoke-ReportItem 'Acrobat add-in settings' {
            $st = @(Get-AddinState)
            if ($st.Count -eq 0) { 'The Acrobat PDFMaker add-in is not registered for Outlook.' }
            foreach ($x in $st) { '{0}  LoadBehavior={1} {2}' -f $x.Path, $x.LoadBehavior, $(if ($x.LoadBehavior -eq 3) { '(on)' } else { '(OFF)' }) }
        }
        Invoke-ReportItem 'Outlook add-in switched-off list' {
            $h = @(Get-ResiliencyHits)
            'Outlook has switched the Acrobat add-in off or flagged it as crashing: ' + $(if ($h.Count -gt 0) { 'YES (' + $h.Count + ' entries)' } else { 'no' })
            foreach ($x in $h) { '  - {0} : {1}' -f $x.Path, $x.Name }
        }
        foreach ($v in $script:OfficeVersions) {
            Invoke-ReportItem ('Outlook ' + $v + ' disabled list') {
                $d = @(Get-RegValueNames -Path ('HKCU:\Software\Microsoft\Office\{0}\Outlook\Resiliency\DisabledItems' -f $v))
                if ($d.Count -gt 0) { 'Outlook {0}: {1} add-in(s) in its disabled list (any program)' -f $v, $d.Count }
            }
        }
    }
    Add-ReportSection $o 'Recent errors - System log (last 7 days, newest first)' { Invoke-ReportItem 'System log' { Format-EventLines (Get-FixItEvents -LogName 'System') } }
    Add-ReportSection $o 'Recent errors - Application log (last 7 days, newest first)' { Invoke-ReportItem 'Application log' { Format-EventLines (Get-FixItEvents -LogName 'Application') } }
    Add-ReportSection $o 'What this tool did recently (from its log)' {
        Invoke-ReportItem 'This tool''s log' {
            if ($script:LogFile -and (Test-Path -LiteralPath $script:LogFile)) { @(Get-Content -LiteralPath $script:LogFile -Tail 40) } else { 'Nothing yet.' }
        }
    }
    return ($o -join "`r`n")
}

# ---------------------------------------------------------------------------
# Extra facts for every report (each item stands alone: one failure never hides the others)
# ---------------------------------------------------------------------------
function Get-FixItHealthLines {
    $o = @()
    $o += Invoke-ReportItem 'Free space on C:' { 'Free space on C: {0}' -f (Format-FixItBytes (Get-FixItFreeBytes)) }
    $o += Invoke-ReportItem 'Days since last restart' { 'Days since last restart: {0}' -f (Get-FixItUptimeDays) }
    $o += Invoke-ReportItem 'Windows waiting for a restart' { 'Windows waiting for a restart: {0}' -f $(if (Test-PendingReboot) { 'YES' } else { 'no' }) }
    $o += Invoke-ReportItem 'Last Windows update installed' { 'Last Windows update installed: {0}' -f (Get-FixItLastUpdate) }
    $o += Invoke-ReportItem 'Connection test' {
        $c = Get-FixItConnection
        'Connection test:'
        foreach ($l in (Format-FixItConnection $c)) { '  ' + $l }
    }
    $o += Invoke-ReportItem 'Blue-screen crashes in the last 30 days' {
        $cr = @(Get-FixItCrashes)
        if ($cr.Count -eq 0) { 'Blue-screen crashes in the last 30 days: none found' }
        else {
            'Blue-screen crashes in the last 30 days: {0}' -f $cr.Count
            foreach ($x in $cr) {
                $m = ([string]$x.Message) -replace '\s+', ' '
                if ($m.Length -gt 200) { $m = $m.Substring(0, 200) + '...' }
                '  {0}  {1}' -f ([datetime]$x.Time).ToString('yyyy-MM-dd HH:mm'), $m
            }
        }
    }
    $o += Invoke-ReportItem 'Unexpected shutdowns or power losses in the last 30 days' { 'Unexpected shutdowns or power losses in the last 30 days: {0}' -f (Get-FixItUnexpectedShutdowns) }
    $o += Invoke-ReportItem 'Disk health' {
        $dh = Get-FixItDiskHealth
        $disks = @($dh.Disks)
        if ($disks.Count -eq 0) { 'Disk health: not available' }
        foreach ($d in $disks) { 'Disk {0} ({1}): health {2}, status {3}' -f $d.Name, $d.Type, $d.Health, $d.Status }
        'Disk SMART prediction: {0}' -f $dh.SmartPrediction
    }
    $o += Invoke-ReportItem 'OneDrive backup' {
        $bk = Get-FixItBackupSummary
        'OneDrive backup of Desktop/Documents/Pictures: {0}' -f $(if ($bk.Ok) { 'on' } else { 'not fully set up' })
        foreach ($w in $bk.Warnings) { '  ' + $w }
    }
    return $o
}

function Get-FixItScamLines {
    $o = @()
    $o += Invoke-ReportItem 'Remote-control programs' {
        $rt = @(Get-FixItRemoteToolProcesses)
        if ($rt.Count -eq 0) { 'Remote-control programs running right now: none found' }
        else { 'REMOTE-CONTROL PROGRAMS RUNNING RIGHT NOW:'; foreach ($r in $rt) { '  {0} (process {1})' -f $r.Name, $r.Id } }
    }
    $o += Invoke-ReportItem 'Recent installs' {
        $ins = @(Get-FixItRecentInstalls -Days 14)
        ''
        if ($ins.Count -eq 0) { 'Programs installed in the last 14 days: none found' }
        else { 'Programs installed in the last 14 days:'; foreach ($i in $ins) { '  {0}  {1}' -f ([datetime]$i.Date).ToString('yyyy-MM-dd'), $i.Name } }
    }
    $o += Invoke-ReportItem 'Recent downloads' {
        $dl = @(Get-FixItRecentDownloads -Days 7 -Max 30)
        ''
        if ($dl.Count -eq 0) { 'Files downloaded in the last 7 days: none found' }
        else { 'Files downloaded in the last 7 days (names only):'; foreach ($d in $dl) { '  {0}  {1}  ({2} KB)' -f ([datetime]$d.Date).ToString('yyyy-MM-dd HH:mm'), $d.Name, $d.KB } }
    }
    return $o
}

# ---------------------------------------------------------------------------
# Sending a report to Trey (the ONLY thing this tool ever sends)
# ---------------------------------------------------------------------------
function Get-FixItReportJson {
    param([string]$Text, [string]$Kind = 'report')
    $pc = [string]$env:COMPUTERNAME
    if (-not $pc) { $pc = 'unknown' }
    $limit = 500 * 1024 - 2048
    $enc = New-Object Text.UTF8Encoding($false)
    $t = $Text
    while ($true) {
        $json = ConvertTo-Json -InputObject ([ordered]@{ pcName = $pc; version = $script:FixItVersion; kind = $Kind; report = $t }) -Compress
        if ($enc.GetByteCount($json) -lt $limit) { return $json }
        $t = $t.Substring(0, [int]($t.Length * 0.8)) + "`r`n(The rest of this report was cut off because it was too long.)"
    }
}

function Send-FixItReport {
    param([string]$Text, [string]$Kind = 'report')
    $url = $script:ReportUrl
    if (-not $url -or $url -notmatch '^https://') { Write-FixItLog 'No valid report address is set, so nothing was sent' 'WARN'; return $false }
    if ($script:TestMode) {
        $json = ''
        try { $json = Get-FixItReportJson -Text $Text -Kind $Kind } catch { Add-FixItTestNote -Step 'Send the report to Trey' -Status 'FAIL' -Text ('the report could not be put together: ' + $_.Exception.Message); return $true }
        return [bool](Invoke-FixItStep ('Send the {0} to Trey' -f $Kind) { [void](Send-WebReport -Url $url -Json $json -AppValue $script:AppHeader) })
    }
    if ($script:DryRun) { Write-FixItLog ('Would do: send the report to {0}' -f $url) 'DRYRUN'; return $true }
    try {
        $json = Get-FixItReportJson -Text $Text -Kind $Kind
        Write-FixItLog ('Sending the report to Trey ({0} bytes)' -f (New-Object Text.UTF8Encoding($false)).GetByteCount($json))
        $code = Send-WebReport -Url $url -Json $json -AppValue $script:AppHeader
        if ($code -ge 200 -and $code -lt 300) { Write-FixItLog ('Report sent (answer {0})' -f $code); return $true }
        Write-FixItLog ('The report was not accepted (answer {0})' -f $code) 'ERROR'
        return $false
    } catch {
        Write-FixItLog ('Could not send the report: {0}' -f $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Save-FixItReportFile {
    param([string]$Text, [string]$Prefix)
    $dir = $OutputDir
    if (-not $dir) { $dir = Get-DesktopFolder }
    $name = '{0}-{1}-{2}.txt' -f $Prefix, $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm')
    $path = Join-Path $dir $name
    $ok = Invoke-FixItStep ('Save report to {0}' -f $path) { Write-FixItTextFile -Path $path -Text $Text }
    return [pscustomobject]@{ Ok = $ok; Path = $path; Name = $name }
}

function Invoke-FixItReport {
    param([string]$Note = '')
    Write-FixItLog 'Started: report for Trey'
    try { $text = Get-FixItReportText -Kind 'report' -Note $Note } catch {
        Write-FixItLog ('Report failed: {0}' -f $_.Exception.Message) 'ERROR'
        return New-FixItResult $false 'Report not made' 'Sorry, the report could not be put together.'
    }
    $f = Save-FixItReportFile -Text $text -Prefix 'Report-for-Trey'
    $sent = Send-FixItReport -Text $text -Kind 'report'
    if ($script:DryRun) {
        return New-FixItResult $true 'Practice run' ('Practice run only - the report would be saved to: {0} and sent to Trey.' -f $f.Path) @() @{ ReportPath = $f.Path; ReportText = $text }
    }
    if ($sent) {
        Write-FixItLog 'Finished: report for Trey (sent)'
        return New-FixItResult $true 'Report sent' 'Report sent to Trey' $(if ($f.Ok) { @('A copy is saved on your Desktop.') } else { @() }) @{ ReportPath = $f.Path; Sent = $true }
    }
    if (-not $f.Ok) {
        Write-FixItLog 'Finished: report for Trey (could not save or send)' 'ERROR'
        return New-FixItResult $false 'Report not sent' 'Sorry, the report could not be saved or sent. Please tell Trey.' @() @{ Sent = $false }
    }
    try { Open-FixItFile -Path $f.Path } catch { Write-FixItLog ('Could not open the report: {0}' -f $_.Exception.Message) 'WARN' }
    Write-FixItLog 'Finished: report for Trey (saved, not sent)' 'WARN'
    return New-FixItResult $false 'Report not sent' ("Couldn't send" + [string][char]0x2014 + 'please send the file on your Desktop to Trey') @() @{ ReportPath = $f.Path; Sent = $false }
}

# ---------------------------------------------------------------------------
# The red button: "I see a scary pop-up". It fixes nothing. It collects facts, tells Trey, and tells the person what to do.
# ---------------------------------------------------------------------------
function Invoke-ScamAlert {
    Write-FixItLog 'Started: scary pop-up (scam) alert' 'WARN'
    $text = ''
    try { $text = Get-FixItReportText -Kind 'scam' } catch {
        Write-FixItLog ('Scam report could not be fully built: {0}' -f $_.Exception.Message) 'ERROR'
        $text = 'SCAM ALERT: the person pressed the red button. The full report could not be built: ' + $_.Exception.Message
    }
    $f = Save-FixItReportFile -Text $text -Prefix 'SCAM-Report-for-Trey'
    $sent = Send-FixItReport -Text $text -Kind 'scam'
    $msg = "STOP. Do NOT call any phone number on the screen.`r`n`r`n" +
        "1. Turn off your Wi-Fi now (or unplug the network cable).`r`n" +
        "2. Do not click anything else, and do not type any passwords.`r`n" +
        "3. Call Trey.`r`n`r`n" +
        'Trey never asks you for codes or to install remote-control programs unless YOU contacted him first.'
    $sentLine = 'A report about this computer was sent to Trey.'
    if ($script:DryRun) { $sentLine = 'Practice run: a report would be saved and sent to Trey.' }
    elseif (-not $sent) { $sentLine = "The report could not be sent, so tell Trey on the phone. A copy is saved on your Desktop." }
    Write-FixItLog ('Finished: scam alert (report sent: {0})' -f $sent) 'WARN'
    return New-FixItResult $true 'Do not call that number' ($msg + "`r`n`r`n" + $sentLine) @() @{ Scam = $true; Sent = [bool]$sent; ReportPath = $f.Path }
}

# ---------------------------------------------------------------------------
# Updates (from the public GitHub repo; only ever asks first)
# ---------------------------------------------------------------------------
function Get-FileSha256 {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLowerInvariant() }
    finally { $fs.Dispose(); $sha.Dispose() }
}

function Get-RemoteManifest {
    param([string]$Url)
    if ($Url.Contains($script:OwnerPlaceholder)) { return [pscustomobject]@{ State = 'NotSetUp' } }
    if ($Url -notmatch '^https://') { return [pscustomobject]@{ State = 'Bad'; Why = 'The update address is not a secure (https) address.' } }
    try { $text = Get-WebText -Url $Url } catch {
        Write-FixItLog ('Could not reach the update site: {0}' -f $_.Exception.Message) 'WARN'
        return [pscustomobject]@{ State = 'Offline' }
    }
    if ($text.Length -gt 200000) { return [pscustomobject]@{ State = 'Bad'; Why = 'The update list is too large.' } }
    try {
        $m = $text | ConvertFrom-Json
        $ver = [version]([string]$m.version)
        $files = @($m.files)
        if ($files.Count -eq 0) { throw 'no files listed' }
        foreach ($f in $files) {
            if ([string]$f.path -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw ('unsafe file name: ' + $f.path) }
            if ($script:AllowedUpdateFiles -notcontains [string]$f.path) { throw ('file not allowed: ' + $f.path) }
            if ([string]$f.sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw ('bad checksum for ' + $f.path) }
        }
    } catch {
        Write-FixItLog ('Update list is not valid: {0}' -f $_.Exception.Message) 'WARN'
        return [pscustomobject]@{ State = 'Bad'; Why = 'The update list could not be understood.' }
    }
    # optional pictures ("assets"): anything not allowed or odd-looking is simply ignored
    $assets = @()
    try {
        if ($m.PSObject.Properties.Name -contains 'assets') {
            foreach ($a in @($m.assets)) {
                $ap = [string]$a.path; $ah = [string]$a.sha256
                $asz = 0; try { $asz = [int64]$a.size } catch { }
                if ($script:AllowedAssetFiles -contains $ap -and $ah -match '^[0-9a-fA-F]{64}$' -and $asz -gt 0 -and $asz -le 1MB) { $assets += $a }
            }
        }
    } catch { Write-FixItLog ('Update list pictures ignored: {0}' -f $_.Exception.Message) 'WARN'; $assets = @() }
    return [pscustomobject]@{ State = 'Ok'; Version = $ver; Files = $files; Assets = $assets; BaseUrl = $Url.Substring(0, $Url.LastIndexOf('/') + 1) }
}

function Get-UpdateStatus {
    $m = Get-RemoteManifest -Url $script:ManifestUrl
    if ($m.State -ne 'Ok') { return $m }
    if ($m.Version -gt [version]$script:FixItVersion) { $m | Add-Member -NotePropertyName State -NotePropertyValue 'Available' -Force }
    else { $m | Add-Member -NotePropertyName State -NotePropertyValue 'Current' -Force }
    return $m
}

function Install-FixItUpdate {
    param($Manifest)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Install-FixItUpdate' -Arguments $PSBoundParameters; return }
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('fixit-update-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        $everything = @($Manifest.Files)
        if ($Manifest.PSObject.Properties.Name -contains 'Assets') { $everything += @($Manifest.Assets) }
        foreach ($f in $everything) {
            $dest = Join-Path $stage ([string]$f.path)
            Write-FixItLog ('Downloading {0}' -f $f.path)
            Save-WebFile -Url ($Manifest.BaseUrl + [string]$f.path) -Dest $dest
            $hash = Get-FileSha256 -Path $dest
            if ($hash -ne ([string]$f.sha256).ToLowerInvariant()) { throw ('Checksum mismatch for ' + $f.path) }
            if ([string]$f.path -like '*.ico' -and -not (Test-FixItIconFile -Path $dest)) { throw ('Not a valid icon: ' + $f.path) }
        }
        $main = Join-Path $stage 'FamilyFixIt.ps1'
        if (Test-Path -LiteralPath $main) {
            $errs = $null; $tokens = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($main, [ref]$tokens, [ref]$errs)
            if ($errs -and $errs.Count -gt 0) { throw 'The downloaded script is damaged' }
            $txt = Get-Content -LiteralPath $main -Raw
            if ($txt -notmatch ("FixItVersion = '" + [regex]::Escape([string]$Manifest.Version) + "'")) { throw 'Downloaded script version does not match the update list' }
        }
        $backup = Join-Path $script:InstallDir 'previous'
        New-Item -ItemType Directory -Path $backup -Force | Out-Null
        $done = @()
        try {
            foreach ($f in $everything) {
                $target = Join-Path $script:InstallDir ([string]$f.path)
                if (Test-Path -LiteralPath $target) { Copy-Item -LiteralPath $target -Destination (Join-Path $backup ([string]$f.path)) -Force }
                Copy-Item -LiteralPath (Join-Path $stage ([string]$f.path)) -Destination $target -Force
                $done += [string]$f.path
            }
        } catch {
            foreach ($d in $done) {
                $b = Join-Path $backup $d
                if (Test-Path -LiteralPath $b) { Copy-Item -LiteralPath $b -Destination (Join-Path $script:InstallDir $d) -Force -ErrorAction SilentlyContinue }
            }
            throw
        }
        # the shortcuts follow the icon (never a reason to fail the update)
        try { [void](Update-FixItShortcutIcons) } catch { Write-FixItLog ('Shortcut icon refresh: {0}' -f $_.Exception.Message) 'WARN' }
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Check for a newer version. -Prompt: tell the person and ask. Quiet when nothing to say.
function Invoke-FixItUpdate {
    param([switch]$Quiet)
    Write-FixItLog ('Checking for a newer version (this is version {0})' -f $script:FixItVersion)
    $s = Get-UpdateStatus
    switch ($s.State) {
        'NotSetUp' { Write-FixItLog 'Update address is not set up yet'; if ($Quiet) { return $null }; return New-FixItResult $true 'Updates' 'Automatic updates are not set up yet.' }
        'Offline'  { if ($Quiet) { return $null }; return New-FixItResult $false 'Could not check' 'Could not reach the update website. Check your internet connection and try again.' }
        'Bad'      { if ($Quiet) { return $null }; return New-FixItResult $false 'Could not check' $s.Why }
        'Current'  { Write-FixItLog 'Already the newest version'; if ($Quiet) { return $null }; return New-FixItResult $true 'Up to date' ('You already have the newest version ({0}).' -f $script:FixItVersion) }
    }
    Write-FixItLog ('Newer version available: {0}' -f $s.Version)
    if ($script:TestMode) { [void](Invoke-FixItStep ('Install version {0} (download the files and replace the program)' -f $s.Version) { Install-FixItUpdate -Manifest $s }) }
    if ($script:DryRun) {
        Write-FixItLog ('Would do: update from {0} to {1}' -f $script:FixItVersion, $s.Version) 'DRYRUN'
        return New-FixItResult $true 'Practice run' ('Practice run only - version {0} is available and would be installed.' -f $s.Version)
    }
    if (-not (Confirm-FixIt ('A newer version of this tool is available ({0}). Update now? It only takes a moment.' -f $s.Version))) {
        Write-FixItLog 'Update declined'
        return $null
    }
    try {
        Install-FixItUpdate -Manifest $s
        Write-FixItLog ('Updated to version {0}' -f $s.Version)
        return New-FixItResult $true 'Updated' ('Updated to version {0}. Please close this window and open Family Fix-It again.' -f $s.Version) @() @{ Updated = $true }
    } catch {
        Write-FixItLog ('Update failed: {0}' -f $_.Exception.Message) 'ERROR'
        return New-FixItResult $false 'Update did not work' 'The update did not work, so nothing was changed. You can keep using this version.'
    }
}

# ---------------------------------------------------------------------------
# Shared helpers for the fixes below
# ---------------------------------------------------------------------------
# A question for the person. In practice mode (-WhatIf) it just says yes so every step shows in the log.
function Confirm-FixItStep {
    param([string]$Question)
    if ($script:DryRun -and -not $script:TestMode) { Write-FixItLog ('Would ask: {0}' -f $Question) 'DRYRUN'; return $true }
    $a = Confirm-FixIt -Question $Question
    Write-FixItLog ('Asked: {0} -> {1}' -f $Question, $(if ($a) { 'yes' } else { 'no' }))
    return [bool]$a
}

function Format-FixItBytes {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    return ('{0:N0} MB' -f ($Bytes / 1MB))
}

function Test-FixItDeclined { param($R) return (($null -ne $R) -and [bool](Get-FixItProp $R 'Declined' $false)) }
# True when the fix already asked the person (or already told them to call Trey), so "Did that fix it?" would be asked twice.
function Test-FixItSkipFollowUp { param($R) return (($null -ne $R) -and [bool](Get-FixItProp $R 'SkipFollowUp' $false)) }

# ---------------------------------------------------------------------------
# Internet and Wi-Fi
# ---------------------------------------------------------------------------
function Get-FixItConnection {
    $gw = ''
    try { $gw = [string](Get-FixItGateway) } catch { Write-FixItLog ('Could not find the router address: {0}' -f $_.Exception.Message) 'WARN' }
    $routerOk = $false
    if ($gw) { $routerOk = [bool](Test-FixItPing -Target $gw) }
    return [pscustomobject]@{
        Gateway = $gw
        RouterOk = $routerOk
        InternetOk = [bool](Test-FixItPing -Target '8.8.8.8')
        DnsOk = [bool](Test-FixItDns -Name 'www.microsoft.com')
        WebOk = [bool](Test-FixItWeb)
    }
}
function Test-FixItConnectionGood { param($C) return ($C.RouterOk -and $C.InternetOk -and $C.DnsOk -and $C.WebOk) }
function Format-FixItConnection {
    param($C)
    $yn = { param($b) if ($b) { 'OK' } else { 'NOT working' } }
    $rt = 'router not found'
    if ($C.Gateway) { $rt = & $yn $C.RouterOk; $rt = '{0} ({1})' -f $rt, $C.Gateway }
    return @(
        ('Your router: {0}' -f $rt),
        ('The internet (8.8.8.8): {0}' -f (& $yn $C.InternetOk)),
        ('Website names (DNS): {0}' -f (& $yn $C.DnsOk)),
        ('Opening a website: {0}' -f (& $yn $C.WebOk))
    )
}

function Invoke-NetworkAdmin {
    $ok = $true
    if (-not (Invoke-FixItStep 'Reset the Windows network connection settings (Winsock)' { Invoke-FixItTool -File 'netsh.exe' -Arguments @('winsock', 'reset') })) { $ok = $false }
    $names = @()
    try { $names = @(Get-FixItAdapters) } catch { Write-FixItLog ('Could not list network adapters: {0}' -f $_.Exception.Message) 'WARN'; $ok = $false }
    foreach ($n in $names) {
        $nn = $n
        if (-not (Invoke-FixItStep ('Restart network adapter {0}' -f $nn) { Restart-FixItAdapter -Name $nn })) { $ok = $false }
    }
    if (-not $script:DryRun -and $names.Count -gt 0) { Wait-FixIt -Seconds 8 }
    Add-FixItCannotUndo 'Resetting the network settings and restarting the network adapters cannot be undone (it is safe to repeat).'
    return New-FixItResult $ok 'Network (all users)' $(if ($ok) { 'Done' } else { 'Some steps could not be done.' }) @() @{ Adapters = $names.Count }
}

$script:RouterRestartText = 'Unplug the router, wait 30 seconds, then plug it back in.'
$script:RouterWaitSeconds = 120
$script:RouterExtraWaitSeconds = 30

# What the waiting window says as the time runs down.
function Get-FixItCountdownText {
    param([int]$Remaining, [int]$Total)
    if ($Remaining -gt ($Total * 0.6)) { return 'Your router is starting up. This takes about 2 minutes.' }
    if ($Remaining -gt ($Total * 0.2)) { return 'The lights on your router should be settling down now.' }
    return 'Nearly done - I will test your internet in a moment.'
}
# A friendly waiting window with a countdown. The window shows it; the command line prints it.
function Show-FixItCountdown {
    param([int]$Seconds, [string]$Title = 'Please wait', [string]$Message = '')
    if ($script:TestAll -or $script:TestMode) { Write-FixItLog ('Test mode: skipped the {0} second countdown' -f $Seconds) 'TEST'; return }
    if ($script:GuiActive) { Show-FixItCountdownDialog -Seconds $Seconds -Title $Title -Message $Message; return }
    Write-Host $Message
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        $left = [int][math]::Ceiling(($end - (Get-Date)).TotalSeconds)
        Write-Host ('  {0}:{1:00} left - {2}' -f [int][math]::Floor($left / 60), ($left % 60), (Get-FixItCountdownText -Remaining $left -Total $Seconds))
        Wait-FixIt -Seconds ([math]::Min(10, [math]::Max(1, $left)))
    }
}

function Invoke-NetworkFix {
    Write-FixItLog 'Started: Fix my internet'
    $before = Get-FixItConnection
    foreach ($l in (Format-FixItConnection $before)) { Write-FixItLog ('Before: {0}' -f $l) }
    if (Test-FixItConnectionGood $before) {
        Write-FixItLog 'Finished: internet already working, nothing changed'
        return New-FixItResult $true 'Internet looks fine' 'Your internet is working right now: your router answers, the internet answers and websites open. Nothing was changed. If just one website or program is broken, try again in a little while.' (Format-FixItConnection $before)
    }
    $lines = @()
    Invoke-FixItStep 'Clear saved web addresses (flush DNS)' { Invoke-FixItTool -File 'ipconfig.exe' -Arguments @('/flushdns') } | Out-Null
    Invoke-FixItStep 'Ask the router for a fresh address (release)' { Invoke-FixItTool -File 'ipconfig.exe' -Arguments @('/release') } | Out-Null
    Invoke-FixItStep 'Ask the router for a fresh address (renew)' { Invoke-FixItTool -File 'ipconfig.exe' -Arguments @('/renew') } | Out-Null
    $proxy = $null
    try { $proxy = Get-FixItUserProxy } catch { Write-FixItLog ('Could not read the proxy setting: {0}' -f $_.Exception.Message) 'WARN' }
    if ($proxy -and $proxy.Enabled) {
        $pk = $proxy.Key
        Write-FixItLog ('A proxy was switched on for this user: {0}' -f $proxy.Server) 'WARN'
        if (Invoke-FixItStep ('Switch off the web proxy setting (it was {0})' -f $proxy.Server) { Set-RegDword -Path $pk -Name 'ProxyEnable' -Value 0 }) {
            $lines += ('A "proxy" setting that can block websites was switched off (it pointed to {0}).' -f $proxy.Server)
        }
    }
    $after = Get-FixItConnection
    $needRestart = $false
    $adminDeclined = $false
    if (-not (Test-FixItConnectionGood $after)) {
        $admin = Invoke-AdminPart -Part 'NetworkAdmin' -InProcess { Invoke-NetworkAdmin }
        if (Test-FixItDeclined $admin) { $adminDeclined = $true } elseif ($admin.Ok) { $needRestart = $true }
        $after = Get-FixItConnection
    }
    foreach ($l in (Format-FixItConnection $after)) { Write-FixItLog ('After: {0}' -f $l) }
    $lines += (Format-FixItConnection $after)
    if ($script:DryRun) {
        Write-FixItLog 'Would do (only if the internet is still not working): show "Unplug the router, wait 30 seconds, then plug it back in." and ask "Is that done?"' 'DRYRUN'
        Write-FixItLog ('Would do: on Yes, wait about {0} seconds with a countdown, test the connection again and report clearly' -f $script:RouterWaitSeconds) 'DRYRUN'
        Write-FixItLog 'Would do: if it still fails, tell the person to call Trey and send Trey the report automatically' 'DRYRUN'
        return New-FixItResult $true 'Practice run' 'Practice run only - nothing was changed. Details are in the log file.' $lines
    }
    if (Test-FixItConnectionGood $after) {
        Write-FixItLog 'Finished: Fix my internet - success'
        return New-FixItResult $true 'Internet fixed' 'Your internet is working again.' $lines
    }
    $restartHint = @()
    if ($needRestart) { $restartHint += 'One of the repairs only finishes after a restart, so please also restart your computer once.' }
    if ($adminDeclined) { $restartHint += 'Windows asked for permission to do a deeper repair and it was not given.' }

    # Still not working: the router step. Say it clearly, ask "Is that done?", wait, test again.
    Write-FixItLog 'The internet is still not working; asking the person to restart the router' 'WARN'
    $done = Confirm-FixIt ("I tried everything I can from this computer, and the internet is still not working.`r`n`r`n" + $script:RouterRestartText + "`r`n`r`nIs that done?") -Title 'Fix my internet'
    Write-FixItLog ('Asked: router unplugged and plugged back in? -> {0}' -f $(if ($done) { 'yes' } else { 'no' }))
    if (-not $done) {
        return New-FixItResult $false 'Router not restarted' ("OK, no problem. Whenever you are ready:`r`n`r`n" + $script:RouterRestartText + "`r`n`r`nThen click 'Fix my internet' again.`r`n`r`nIf you need help, please call Trey.") $lines @{ SkipFollowUp = $true }
    }
    Show-FixItCountdown -Seconds $script:RouterWaitSeconds -Title 'Giving your router time to start up' -Message 'Your router needs a couple of minutes to wake up. Nothing else to do - please wait.'
    Invoke-FixItStep 'Ask the router for a fresh address (renew)' { Invoke-FixItTool -File 'ipconfig.exe' -Arguments @('/renew') } | Out-Null
    $final = Get-FixItConnection
    if (-not (Test-FixItConnectionGood $final) -and (-not $final.RouterOk -or -not $final.InternetOk)) {
        Write-FixItLog 'Still starting up; waiting a little longer' 'WARN'
        Show-FixItCountdown -Seconds $script:RouterExtraWaitSeconds -Title 'Still starting up' -Message 'Your router is taking a little longer. Please wait just a bit more.'
        $final = Get-FixItConnection
    }
    foreach ($l in (Format-FixItConnection $final)) { Write-FixItLog ('After the router restart: {0}' -f $l) }
    $report = @('Router unplugged and plugged back in, then waited. Test results:') + @(Format-FixItConnection $final)
    if (Test-FixItConnectionGood $final) {
        Write-FixItLog 'Finished: Fix my internet - success after the router restart'
        return New-FixItResult $true 'Internet fixed' ("Your internet is working again.`r`n`r`nRestarting the router did it. Your router answers, the internet answers and websites open.") $report @{ SkipFollowUp = $true }
    }
    Write-FixItLog 'Finished: Fix my internet - still not working after the router restart' 'WARN'
    $sent = $false
    try {
        $note = 'Fix my internet did NOT work, even after the router was unplugged and plugged back in and about {0} seconds had passed. Test results: {1}' -f $script:RouterWaitSeconds, ((Format-FixItConnection $final) -join '; ')
        $text = Get-FixItReportText -Kind 'report' -Note $note
        [void](Save-FixItReportFile -Text $text -Prefix 'Report-for-Trey')
        $sent = [bool](Send-FixItReport -Text $text -Kind 'report')
    } catch { Write-FixItLog ('The internet report could not be made: {0}' -f $_.Exception.Message) 'ERROR' }
    $sentLine = 'I have sent Trey a report with everything I found, so he can see what happened.'
    if (-not $sent) { $sentLine = "I tried to send Trey a report, but that needs the internet, and the internet is not working. A copy of the report is saved on your Desktop - please tell Trey when you call." }
    $msg = "Your internet is still not working, even after restarting the router.`r`n`r`nPlease call Trey.`r`n`r`n" + $sentLine
    foreach ($h in $restartHint) { $msg += "`r`n`r`n" + $h }
    return New-FixItResult $false 'Please call Trey' $msg $report @{ SkipFollowUp = $true; ReportSent = $sent }
}

# ---------------------------------------------------------------------------
# Slow computer / full disk
# ---------------------------------------------------------------------------
function Invoke-SlowAdmin {
    $ok = $true
    $freed = [int64]0
    $wasRunning = ((Get-FixItServiceStatus -Name 'wuauserv') -eq 'Running')
    $sysTemp = ($env:SystemRoot, 'C:\Windows' | Where-Object { $_ } | Select-Object -First 1).TrimEnd('\') + '\Temp'
    $wuCache = ($env:SystemRoot, 'C:\Windows' | Where-Object { $_ } | Select-Object -First 1).TrimEnd('\') + '\SoftwareDistribution\Download'
    $script:__f = [int64]0
    if (-not (Invoke-FixItStep 'Empty the Windows temporary files folder' { $script:__f += (Clear-FixItFolder -Path $sysTemp) })) { $ok = $false }
    $stopped = Invoke-FixItStep 'Pause Windows Update for a moment' { Stop-FixItService -Name 'wuauserv' }
    if (-not (Invoke-FixItStep 'Empty the Windows Update download folder' { $script:__f += (Clear-FixItFolder -Path $wuCache) })) { $ok = $false }
    if ($stopped -and $wasRunning) { Invoke-FixItStep 'Start Windows Update again' { Start-FixItService -Name 'wuauserv' } | Out-Null }
    $freed = $script:__f
    return New-FixItResult $ok 'Cleanup (all users)' $(if ($ok) { 'Done' } else { 'Some folders could not be cleaned.' }) @() @{ FreedBytes = [string]$freed }
}

function Invoke-SlowFix {
    Write-FixItLog 'Started: My computer is slow'
    $startFree = Get-FixItFreeBytes
    $uptime = Get-FixItUptimeDays
    $pending = Test-PendingReboot
    $lines = @()
    $closed = 0
    foreach ($h in @(Get-FixItHungApps)) {
        $hid = [int]$h.Id
        $label = $h.Name; if ($h.Title) { $label = '{0} ("{1}")' -f $h.Name, $h.Title }
        Write-FixItLog ('Not responding: {0}' -f $label) 'WARN'
        if (Confirm-FixItStep ('{0} has frozen. Close it? Anything you have not saved in it will be lost.' -f $label)) {
            if (Invoke-FixItStep ('Close the frozen program {0}' -f $h.Name) { Stop-FixItApp -Id $hid }) { $closed++; $lines += ('Closed the frozen program {0}.' -f $h.Name) }
        }
    }
    $freed = [int64]0
    $problems = 0
    Add-FixItCannotUndo 'Deleted temporary files and the emptied Recycle Bin cannot be brought back.'
    $script:__f = [int64]0
    $userTemp = $env:TEMP
    if ($userTemp) {
        if (-not (Invoke-FixItStep 'Empty your temporary files folder' { $script:__f += (Clear-FixItFolder -Path $userTemp) })) { $problems++ }
    }
    if (-not (Invoke-FixItStep 'Empty the Recycle Bin' { Clear-FixItRecycleBin })) { $problems++ }
    $cacheFolders = @(Get-FixItBrowserCacheFolders)
    $clearCache = $false
    if ($cacheFolders.Count -gt 0) {
        $clearCache = Confirm-FixItStep "Clear the temporary website files your browser has saved (called the cache)? This can free a lot of space.`r`n`r`nWarning: afterwards you may need to sign back in to websites you visit, so have your passwords handy.`r`n`r`nClear them now?"
        if (-not $clearCache) { $lines += 'Your browser was left alone, as you chose. You will not need to sign in to any website again.' }
    }
    if ($clearCache) {
        foreach ($c in $cacheFolders) {
            $cp = $c.Path
            if (-not (Invoke-FixItStep ('Empty the {0} browser cache {1}' -f $c.Browser, $cp) { $script:__f += (Clear-FixItFolder -Path $cp) })) { $problems++ }
        }
        $lines += 'Cleared the temporary website files your browser had saved. You may need to sign back in to some websites.'
    }
    $freed += $script:__f
    $admin = Invoke-AdminPart -Part 'SlowAdmin' -InProcess { Invoke-SlowAdmin }
    $adminNote = ''
    if (Test-FixItDeclined $admin) { $adminNote = 'The deeper cleanup of Windows folders was skipped because permission was not given.' }
    elseif (-not $admin.Ok) { $adminNote = 'Some Windows folders could not be cleaned.' }
    $endFree = Get-FixItFreeBytes
    $gained = [int64]([math]::Max([int64]0, $endFree - $startFree))

    if ($script:DryRun) {
        $lines += ('Free space now: {0}' -f (Format-FixItBytes $startFree))
        return New-FixItResult $true 'Practice run' 'Practice run only - nothing was deleted. Details are in the log file.' $lines
    }
    $lines += ('Free space on C: before {0}, now {1} (about {2} freed).' -f (Format-FixItBytes $startFree), (Format-FixItBytes $endFree), (Format-FixItBytes $gained))
    $lines += ('Your computer was last restarted {0} day(s) ago.' -f $uptime)
    if ($pending) { $lines += 'Windows is waiting for a restart to finish an update.' }
    $top = @(Get-FixItTopApps -Count 5)
    if ($top.Count -gt 0) {
        $lines += 'Programs using the most memory right now:'
        foreach ($t in $top) { $lines += ('  {0} - {1} MB' -f $t.Name, $t.MemMB) }
    }
    if ($adminNote) { $lines += $adminNote }
    $msg = 'Cleanup finished. Your documents, desktop and downloads were not touched.'
    if ($uptime -gt 7 -or $pending) { $msg += ' A restart is a good idea now - please save your work and restart your computer.' }
    Write-FixItLog ('Finished: slow computer - freed about {0}' -f (Format-FixItBytes $gained))
    return New-FixItResult ($problems -eq 0) $(if ($problems -eq 0) { 'Cleanup done' } else { 'Cleanup mostly done' }) $msg $lines
}

# ---------------------------------------------------------------------------
# Sound, microphone, camera
# ---------------------------------------------------------------------------
function Invoke-SoundAdmin {
    $ok = $true
    foreach ($s in @('AudioEndpointBuilder', 'Audiosrv')) {
        $sn = $s
        if (-not (Invoke-FixItStep ('Restart the Windows sound service {0}' -f $sn) { Stop-FixItService -Name $sn; Start-FixItService -Name $sn })) { $ok = $false }
    }
    return New-FixItResult $ok 'Sound service' $(if ($ok) { 'Done' } else { 'The sound service could not be restarted.' })
}

# When the speakers are muted or almost silent they are set to this, so a video call does not suddenly blast out.
$script:SpeakerRestoreVolume = 25
$script:MicRestoreVolume = 70

function Invoke-SoundFix {
    Write-FixItLog 'Started: Fix sound, microphone and camera'
    $lines = @()
    $page = ''
    $needRestart = $false
    $spk = $null; $mic = $null
    try { $spk = Get-FixItAudioDevice -Kind Speakers } catch { Write-FixItLog ('Could not read the speakers: {0}' -f $_.Exception.Message) 'WARN' }
    try { $mic = Get-FixItAudioDevice -Kind Microphone } catch { Write-FixItLog ('Could not read the microphone: {0}' -f $_.Exception.Message) 'WARN' }
    $cams = @()
    try { $cams = @(Get-FixItCameras) } catch { Write-FixItLog ('Could not list cameras: {0}' -f $_.Exception.Message) 'WARN' }

    if (-not $spk) { $lines += 'No speakers or headphones are selected in Windows.'; $needRestart = $true; $page = 'ms-settings:sound' }
    else {
        Write-FixItLog ('Speakers: {0} volume={1} muted={2}' -f $spk.Name, $spk.Volume, $spk.Muted)
        if ($spk.Muted -or $spk.Volume -lt 10) {
            Add-FixItUndoStep ([ordered]@{ Kind = 'audio'; Device = 'Speakers'; Volume = [int]$spk.Volume; Muted = [bool]$spk.Muted })
            if (Invoke-FixItStep ('Unmute the speakers and set the volume to {0}%' -f $script:SpeakerRestoreVolume) { Set-FixItAudioDevice -Kind Speakers -Volume $script:SpeakerRestoreVolume }) { $lines += ('Your speakers ({0}) were muted or almost silent. They are now on at {1}% - not too loud. Turn them up if you need to.' -f $spk.Name, $script:SpeakerRestoreVolume) }
        } else { $lines += ('Speakers: {0}, volume {1}%.' -f $spk.Name, $spk.Volume) }
    }
    if (-not $mic) { $lines += 'No microphone is selected in Windows.'; $needRestart = $true; if (-not $page) { $page = 'ms-settings:sound' } }
    else {
        Write-FixItLog ('Microphone: {0} volume={1} muted={2}' -f $mic.Name, $mic.Volume, $mic.Muted)
        if ($mic.Muted -or $mic.Volume -lt 10) {
            Add-FixItUndoStep ([ordered]@{ Kind = 'audio'; Device = 'Microphone'; Volume = [int]$mic.Volume; Muted = [bool]$mic.Muted })
            if (Invoke-FixItStep ('Unmute the microphone and set the volume to {0}%' -f $script:MicRestoreVolume) { Set-FixItAudioDevice -Kind Microphone -Volume $script:MicRestoreVolume }) { $lines += ('Your microphone ({0}) was muted or almost silent. It is now on.' -f $mic.Name) }
        } else { $lines += ('Microphone: {0}, volume {1}%.' -f $mic.Name, $mic.Volume) }
    }

    foreach ($cap in @(@{ C = 'microphone'; N = 'your microphone'; P = 'ms-settings:privacy-microphone' }, @{ C = 'webcam'; N = 'your camera'; P = 'ms-settings:privacy-webcam' })) {
        $pv = $null
        try { $pv = Get-FixItPrivacy -Capability $cap.C } catch { }
        if (-not $pv) { continue }
        Write-FixItLog ('Privacy {0}: user={1} machine={2}' -f $cap.C, $pv.User, $pv.Machine)
        if ($pv.Machine -eq 'Deny') {
            $lines += ('Windows is blocking {0} for everyone on this computer. That switch is in Settings > Privacy; Trey may need to help.' -f $cap.N)
            if (-not $page) { $page = $cap.P }
        } elseif ($pv.User -eq 'Deny') {
            $capName = $cap.C
            if (Confirm-FixItStep ('Windows is blocking apps from using {0}. Turn that back on?' -f $cap.N)) {
                if (Invoke-FixItStep ('Allow apps to use {0}' -f $capName) { Set-FixItPrivacyAllow -Capability $capName }) { $lines += ('Apps may use {0} again.' -f $cap.N) }
            } else {
                $lines += ('{0} is still blocked, as you chose.' -f $cap.N)
                if (-not $page) { $page = $cap.P }
            }
        }
    }
    $bad = @($cams | Where-Object { $_.Status -ne 'OK' })
    if ($cams.Count -eq 0) { $lines += 'No camera was found on this computer.'; if (-not $page) { $page = 'ms-settings:privacy-webcam' } }
    elseif ($bad.Count -gt 0) { foreach ($b in $bad) { $lines += ('The camera "{0}" reports a problem ({1}).' -f $b.Name, $b.Status) }; if (-not $page) { $page = 'ms-settings:privacy-webcam' } }
    else { $lines += ('Camera found: {0}.' -f $cams[0].Name) }

    if (-not $needRestart -and -not $page) {
        if (Confirm-FixItStep 'Everything looks fine. Restart the Windows sound service anyway? (Windows will ask for permission.)') { $needRestart = $true }
    }
    if ($needRestart) {
        $admin = Invoke-AdminPart -Part 'SoundAdmin' -InProcess { Invoke-SoundAdmin }
        if ($admin.Ok) { $lines += 'The Windows sound service was restarted.' }
        elseif (Test-FixItDeclined $admin) { $lines += 'The sound service was not restarted because permission was not given.' }
        else { $lines += 'The sound service could not be restarted.' }
    }
    if (-not $page) { $page = 'ms-settings:sound' }
    Invoke-FixItStep ('Open the Windows settings page {0}' -f $page) { Open-FixItSettings -Uri $page } | Out-Null
    if ($script:DryRun) { return New-FixItResult $true 'Practice run' 'Practice run only - nothing was changed. Details are in the log file.' $lines }
    Write-FixItLog 'Finished: sound, microphone and camera'
    return New-FixItResult $true 'Sound check done' 'I checked your speakers, microphone and camera and opened the Windows page where you can pick the right one. Please try again now.' $lines
}

# ---------------------------------------------------------------------------
# "Let Trey see my screen" (Zoho Assist, joined by typing a code Trey gives)
# ---------------------------------------------------------------------------
function Invoke-ScreenShare {
    Write-FixItLog 'Started: Let Trey see my screen'
    $url = $script:ScreenShareUrl
    if (-not (Invoke-FixItStep ('Open the Zoho Assist join page {0}' -f $url) { Open-FixItUrl -Url $url })) {
        return New-FixItResult $false 'Could not open the page' ("Sorry, the page could not be opened. Please open your web browser and type: join.zoho.com") @()
    }
    if ($script:DryRun) { return New-FixItResult $true 'Practice run' ('Practice run only - the page {0} would open.' -f $url) }
    Write-FixItLog 'Finished: Let Trey see my screen (page opened)'
    return New-FixItResult $true 'Zoho Assist page opened' ("Trey will give you a code. Type it in and click Join.`r`n`r`nNothing is installed in advance, and Trey cannot see your screen until you do this.`r`n`r`nOnly do this if YOU called Trey. If someone else asked you to - on the phone, in a pop-up or in an email - stop and do not do it.") @()
}

# ---------------------------------------------------------------------------
# Outlook (slow, freezing or will not open)
# ---------------------------------------------------------------------------
$script:KnownBadAddinPatterns = @('^Ask', 'Babylon', 'Conduit', 'SearchProtect', 'Snap\.?do', 'MyWebSearch', 'Yontoo', 'Delta ?Search', 'WebSearch', 'Coupon', 'Shopping')

function Find-FixItBadAddins {
    $crashing = @()
    try { $crashing = @(Get-FixItCrashingAddins) } catch { }
    $found = @()
    foreach ($a in @(Get-FixItOutlookAddins)) {
        if ($a.ProgId -match 'PDFMaker') { continue }
        $reason = ''
        if ($crashing -contains $a.ProgId) { $reason = 'Outlook says it keeps crashing' }
        else { foreach ($p in $script:KnownBadAddinPatterns) { if ($a.ProgId -match $p -or $a.Description -match $p) { $reason = 'looks like an unwanted toolbar or add-on'; break } } }
        if ($reason -and ($null -ne $a.LoadBehavior) -and ([int]$a.LoadBehavior -ne 0)) { $found += [pscustomobject]@{ Add = $a; Reason = $reason } }
    }
    return $found
}

function Invoke-OutlookAdmin {
    $ok = $true
    $reg = 'HKLM:\SOFTWARE\Microsoft\Windows Search'
    if (-not (Invoke-FixItStep 'Tell Windows Search to rebuild its index' { Set-RegDword -Path $reg -Name 'SetupCompletedSuccessfully' -Value 0 })) { $ok = $false }
    if (-not (Invoke-FixItStep 'Restart Windows Search' { Stop-FixItService -Name 'WSearch'; Start-FixItService -Name 'WSearch' })) { $ok = $false }
    return New-FixItResult $ok 'Search index' $(if ($ok) { 'Done' } else { 'The search index could not be rebuilt.' })
}

# Closes every Outlook process (also the ones with no window). Returns 'closed', 'declined' (they said no to ending it by force) or 'stuck'.
function Close-FixItOutlookFully {
    $names = $script:OutlookProcessNames
    if ($script:DryRun) {
        Write-FixItLog 'Would do: close every Outlook program completely (and ask first before ending one by force)' 'DRYRUN'
        if ($script:TestMode) { [void](Invoke-FixItStep 'Ask Outlook to close, and end it only if it is stuck' { Request-AppClose -ProcessNames $names; Stop-FixItAppsByName -ProcessNames $names }) }
        return 'closed'
    }
    if (@(Get-RunningApp -ProcessNames $names).Count -eq 0) { return 'closed' }
    Write-FixItLog 'Doing: close Outlook completely'
    Request-AppClose -ProcessNames $names
    if (@(Get-RunningApp -ProcessNames $names).Count -gt 0) {
        $force = Confirm-FixIt "Outlook is not closing on its own. It may be stuck, or waiting for you (for example, to save a message).`r`n`r`nClose it by force? Anything you have not saved in Outlook will be lost."
        Write-FixItLog ('Asked: end Outlook by force -> {0}' -f $(if ($force) { 'yes' } else { 'no' }))
        if (-not $force) { return 'declined' }
        [void](Invoke-FixItStep 'End the Outlook programs that are still running' { Stop-FixItAppsByName -ProcessNames $names })
        Wait-FixIt -Seconds 2
        if (@(Get-RunningApp -ProcessNames $names).Count -gt 0) { Write-FixItLog 'Outlook is still running after ending it' 'ERROR'; return 'stuck' }
    }
    Wait-FixIt -Seconds 3
    return 'closed'
}
# Asks first (only when Outlook is open), then closes it completely. Same return values as Close-FixItOutlookFully.
function Close-FixItOutlookForFix {
    param([string]$Question)
    $running = (@(Get-RunningApp -ProcessNames $script:OutlookProcessNames).Count -gt 0)
    if ($running) { if (-not (Confirm-FixItStep $Question)) { return 'declined' } }
    return (Close-FixItOutlookFully)
}
function Open-FixItOutlookForFix {
    return (Invoke-FixItStep 'Open Outlook again' { Wait-FixIt -Seconds 2; Start-FixItOutlook })
}
$script:OutlookKeepText = 'Your email accounts, passwords, sign-ins and Outlook profiles were not touched.'
function New-FixItOutlookCloseResult {
    param([string]$State)
    if ($State -eq 'declined') {
        return New-FixItResult $true 'Nothing changed' 'OK, Outlook was left alone and nothing was changed.' @($script:OutlookKeepText) @{ SkipFollowUp = $true }
    }
    return New-FixItResult $false 'Outlook would not close' "Outlook is stuck and would not close, even when I asked firmly.`r`n`r`nPlease restart your computer, then click the button again. If it still does not work, please call Trey." @($script:OutlookKeepText)
}
function New-FixItOutlookOpenFailResult {
    return New-FixItResult $false 'Outlook did not open' "I closed Outlook, but it did not open again by itself.`r`n`r`nPlease open Outlook from the Start menu. If it will not open, please call Trey." @($script:OutlookKeepText)
}

function Invoke-OutlookFix {
    Write-FixItLog 'Started: Fix Outlook'
    $lines = @()
    $closeQ = "Outlook is open. To fix it, I need to close it completely - including the parts running in the background - and then open it again.`r`n`r`nPlease save or send anything you are writing first.`r`n`r`nClose Outlook now?"

    # Step 1: the gentle fix. Close every Outlook program, open it again, and ask.
    $c = Close-FixItOutlookForFix -Question $closeQ
    if ($c -ne 'closed') { return (New-FixItOutlookCloseResult -State $c) }
    if (-not (Open-FixItOutlookForFix)) { return (New-FixItOutlookOpenFailResult) }
    $lines += 'Closed Outlook completely and opened it again.'
    if ($script:DryRun) {
        Write-FixItLog 'Would ask: Is Outlook working properly now? (If yes, I stop here. If not, the next steps below happen.)' 'DRYRUN'
    } else {
        $works = Confirm-FixIt "Outlook is opening again - give it a moment.`r`n`r`nIs Outlook working properly now?"
        Write-FixItLog ('Asked: Is Outlook working properly now? -> {0}' -f $(if ($works) { 'yes' } else { 'no' })) $(if ($works) { 'INFO' } else { 'WARN' })
        if ($works) {
            Write-FixItLog 'Finished: Fix Outlook - fixed by closing and opening it again'
            return New-FixItResult $true 'Outlook fixed' ("Great - Outlook is working again.`r`n`r`nI only closed it completely and opened it again. " + $script:OutlookKeepText) $lines @{ SkipFollowUp = $true }
        }
        if (-not (Confirm-FixIt "Sorry about that. The next steps are gentle too: I will look for Outlook add-ins that cause trouble, you can choose to rebuild Outlook search, and I can open Outlook in safe mode to test it.`r`n`r`nOutlook will close once more for this. Your email accounts and sign-ins will not be touched.`r`n`r`nContinue?")) {
            Write-FixItLog 'The person did not want the next Outlook steps' 'WARN'
            return New-FixItResult $false 'Outlook still needs help' "OK, I stopped here. Outlook is still open.`r`n`r`nIf it still does not work, please call Trey." @($script:OutlookKeepText) @{ SkipFollowUp = $true }
        }
    }

    # Step 2: only because it is still not working.
    $c2 = Close-FixItOutlookFully
    if ($c2 -ne 'closed') { return (New-FixItOutlookCloseResult -State $c2) }
    $bad = @(Find-FixItBadAddins)
    $disableUser = @($bad | Where-Object { -not $_.Add.IsMachineWide })
    foreach ($b in @($bad | Where-Object { $_.Add.IsMachineWide })) { $lines += ('The add-in "{0}" {1}, but it is installed for everyone, so Trey needs to turn it off.' -f $b.Add.ProgId, $b.Reason) }
    if ($disableUser.Count -gt 0) {
        $names = ($disableUser | ForEach-Object { '{0} ({1})' -f $_.Add.ProgId, $_.Reason }) -join "`r`n"
        if (Confirm-FixItStep ("These Outlook add-ins look like trouble:`r`n`r`n{0}`r`n`r`nTurn them off? (They can be turned back on later.)" -f $names)) {
            foreach ($d in $disableUser) {
                $path = $d.Add.Path; $old = $d.Add.LoadBehavior
                Write-FixItLog ('Add-in {0}: LoadBehavior was {1}' -f $d.Add.ProgId, $old)
                if (Invoke-FixItStep ('Turn off the Outlook add-in {0} (LoadBehavior {1} -> 0)' -f $d.Add.ProgId, $old) { Set-RegDword -Path $path -Name 'LoadBehavior' -Value 0 }) { $lines += ('Turned off the add-in {0}.' -f $d.Add.ProgId) }
            }
        }
    } elseif ($bad.Count -eq 0) { $lines += 'No troublesome add-ins were found.' }

    if (Confirm-FixItStep "Rebuild the Outlook search index? Search may be incomplete for an hour or so. Windows will ask for permission.") {
        $admin = Invoke-AdminPart -Part 'OutlookAdmin' -InProcess { Invoke-OutlookAdmin }
        if ($admin.Ok) { $lines += 'Windows is rebuilding the search index in the background.' }
        elseif (Test-FixItDeclined $admin) { $lines += 'The search index was not rebuilt because permission was not given.' }
        else { $lines += 'The search index could not be rebuilt.' }
    }
    $opened = $false
    if (Confirm-FixItStep "Open Outlook in safe mode to test it? (Safe mode starts Outlook without any add-ins. Choose No to open Outlook normally.)") {
        if (Invoke-FixItStep 'Start Outlook in safe mode' { Start-FixItOutlookSafe }) { $lines += 'Outlook was started in safe mode. If it works there, an add-in was the problem.'; $opened = $true }
    }
    if (-not $opened) { if (Open-FixItOutlookForFix) { $lines += 'Outlook was opened again.' } }
    $lines += $script:OutlookKeepText
    if ($script:DryRun) { return New-FixItResult $true 'Practice run' 'Practice run only - nothing was changed. Details are in the log file.' $lines }
    Write-FixItLog 'Finished: Fix Outlook (further steps)'
    return New-FixItResult $true 'Outlook check done' 'I went through the extra Outlook steps. Please try Outlook now.' $lines
}

# ---------------------------------------------------------------------------
# Browser clean-up (Edge and Chrome)
# ---------------------------------------------------------------------------
$script:KnownGoodExtensionIds = @(
    'efaidnbmnnnibpcajpcglclefindmkaj',  # Adobe Acrobat
    'ghbmnnjooekpmoecnnnilnnbdlolhkhi',  # Google Docs Offline
    'nmmhkkegccagdldgiimedpiccmgmieda',  # Google Wallet / Payments
    'pkedcjkdefgpdelpbcmbmeomcjbeemfm',  # Chrome Media Router
    'gcbommkclmclpchllfjekcdonpmejbdp',  # HTTPS Everywhere
    'cjpalhdlnbpafiamejdnhcphjbkeiagm',  # uBlock Origin
    'ddkjiahejlhfcafbddmgiahcphecmpfh',  # uBlock Origin Lite
    'nngceckbapebfimnlniiiahkandclblb',  # Bitwarden
    'hdokiejnpimakedhajhdlcegeplioahd',  # LastPass
    'aapbdbdomjkkjkaonfhkkikfgjllcleb',  # Google Translate
    'kbfnbcaeplbcioakkpcpgfkobkghlhen',  # Grammarly
    'jlgkpaicikihijadgifklkbpdajbkhjo'   # Edge: Microsoft Defender browser protection (typical)
)
$script:KnownGoodSearchWords = 'google|bing|duckduckgo|yahoo|ecosia|microsoft|msn|edge|brave|startpage'

function Invoke-DefenderScanAdmin {
    $ok = Invoke-FixItStep 'Run a Microsoft Defender quick scan' { Start-FixItDefenderScan }
    return New-FixItResult $ok 'Virus scan' $(if ($ok) { 'The quick scan finished.' } else { 'The quick scan could not be run.' })
}

function Invoke-BrowserFix {
    Write-FixItLog 'Started: Clean up my browser'
    $profiles = @()
    try { $profiles = @(Get-FixItBrowserProfiles) } catch { Write-FixItLog ('Could not look for browsers: {0}' -f $_.Exception.Message) 'WARN' }
    $lines = @()
    if ($profiles.Count -eq 0) {
        $lines += 'Microsoft Edge or Google Chrome was not found for this user.'
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupRoot = Join-Path ($(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [IO.Path]::GetTempPath() })) ('FamilyFixIt\backups\' + $stamp)
    $oddSearch = @{}
    $unknownExt = @()
    $notifSites = @()
    foreach ($p in $profiles) {
        $pd = $p.Dir; $label = '{0} ({1})' -f $p.Browser, $p.Name
        $dest = Join-Path $backupRoot ('{0}-{1}' -f $p.Browser, ($p.Name -replace '\s', '_'))
        foreach ($f in @('Preferences', 'Secure Preferences', 'Bookmarks', 'Web Data')) {
            $src = Join-Path $pd $f
            if (Invoke-FixItStep ('Back up {0} for {1} to {2}' -f $f, $label, $dest) { Copy-FixItBackup -Source $src -DestDir $dest }) { Add-FixItUndoStep ([ordered]@{ Kind = 'file'; Backup = (Join-Path $dest $f); Original = $src }) }
        }
        $s = $null
        try { $s = Get-FixItBrowserSettings -Dir $pd } catch { Write-FixItLog ('Could not read the settings of {0}: {1}' -f $label, $_.Exception.Message) 'WARN' }
        if ($s) {
            $urls = @($s.Homepage) + @($s.StartupUrls) | Where-Object { $_ }
            $odd = @()
            foreach ($u in $urls) { if ($u -notmatch $script:KnownGoodSearchWords -and $u -notmatch '^(about|edge|chrome):') { $odd += $u } }
            if ($s.SearchName -and ($s.SearchName -notmatch $script:KnownGoodSearchWords) -and ($s.SearchUrl -notmatch $script:KnownGoodSearchWords)) { $odd += ('search engine: {0}' -f $s.SearchName) }
            if ($odd.Count -gt 0) { $oddSearch[$p.Browser] = $odd; $lines += ('{0}: homepage or search looks changed: {1}' -f $label, ($odd -join ', ')) }
            foreach ($n in @($s.NotificationSites)) { $notifSites += ('{0}: {1}' -f $p.Browser, $n) }
        }
        try {
            foreach ($e in @(Get-FixItBrowserExtensions -Dir $pd)) {
                if ($script:KnownGoodExtensionIds -notcontains $e.Id) { $unknownExt += ('{0}: {1}' -f $p.Browser, $e.Name) }
            }
        } catch { Write-FixItLog ('Could not list extensions for {0}: {1}' -f $label, $_.Exception.Message) 'WARN' }
    }
    if ($profiles.Count -gt 0) { $lines += ('Your browser settings were backed up first (in {0}).' -f $backupRoot) }

    foreach ($br in @($oddSearch.Keys)) {
        $b2 = $br
        $url = 'edge://settings/resetProfileSettings'; if ($b2 -eq 'Chrome') { $url = 'chrome://settings/resetProfileSettings' }
        if (Confirm-FixItStep ('{0}: your homepage or search engine was changed to something unusual. Open the {0} page where you can put them back to normal?' -f $b2)) {
            $exe = 'msedge.exe'; if ($b2 -eq 'Chrome') { $exe = 'chrome.exe' }
            Invoke-FixItStep ('Open the {0} reset page' -f $b2) { Open-FixItBrowserPage -Exe $exe -Url $url } | Out-Null
            $lines += ('{0}: opened its settings reset page. Click "Restore settings to their default values".' -f $b2)
        }
    }
    if ($unknownExt.Count -gt 0) {
        $lines += 'Extensions I do not recognise (turn off any you did not choose):'
        foreach ($u in $unknownExt) { $lines += ('  ' + $u) }
        if (Confirm-FixItStep 'Open the extensions page so you can turn off the ones you do not want?') {
            $page = 'edge://extensions'; $exe2 = 'msedge.exe'
            if (@($profiles | Where-Object { $_.Browser -eq 'Edge' }).Count -eq 0) { $page = 'chrome://extensions'; $exe2 = 'chrome.exe' }
            Invoke-FixItStep ('Open {0}' -f $page) { Open-FixItBrowserPage -Exe $exe2 -Url $page } | Out-Null
        }
    }
    if ($notifSites.Count -gt 0) {
        $lines += 'Websites allowed to show you notification pop-ups:'
        foreach ($n in ($notifSites | Select-Object -First 15)) { $lines += ('  ' + $n) }
        if (Confirm-FixItStep 'Open the notification settings so you can remove sites you do not want?') {
            $exe3 = 'msedge.exe'; $page3 = 'edge://settings/content/notifications'
            if (@($profiles | Where-Object { $_.Browser -eq 'Edge' }).Count -eq 0) { $exe3 = 'chrome.exe'; $page3 = 'chrome://settings/content/notifications' }
            Invoke-FixItStep ('Open {0}' -f $page3) { Open-FixItBrowserPage -Exe $exe3 -Url $page3 } | Out-Null
        }
    }
    if (Confirm-FixItStep 'Run a quick virus scan with Microsoft Defender now? It can take 5 to 10 minutes. Windows will ask for permission.') {
        $admin = Invoke-AdminPart -Part 'DefenderScanAdmin' -InProcess { Invoke-DefenderScanAdmin }
        if ($admin.Ok) { $lines += 'The Defender quick scan finished.' }
        elseif (Test-FixItDeclined $admin) { $lines += 'The virus scan was skipped because permission was not given.' }
        else { $lines += 'The virus scan could not be run.' }
    }
    if ($script:DryRun) { return New-FixItResult $true 'Practice run' 'Practice run only - nothing was changed. Details are in the log file.' $lines }
    Write-FixItLog 'Finished: Clean up my browser'
    return New-FixItResult $true 'Browser check done' 'I checked your browser. Passwords, bookmarks and history were not touched.' $lines
}

# ---------------------------------------------------------------------------
# Windows Update
# ---------------------------------------------------------------------------
$script:WuServices = @('wuauserv', 'bits', 'cryptsvc', 'msiserver')

function Invoke-WinUpdateAdmin {
    $ok = $true
    $win = $env:SystemRoot; if (-not $win) { $win = 'C:\Windows' }
    $win = $win.TrimEnd('\')
    $tag = Get-Date -Format 'yyyyMMddHHmm'
    foreach ($s in $script:WuServices) { $sn = $s; if (-not (Invoke-FixItStep ('Stop the Windows service {0}' -f $sn) { Stop-FixItService -Name $sn })) { $ok = $false } }
    if ($ok) {
        foreach ($f in @(($win + '\SoftwareDistribution'), ($win + '\System32\catroot2'))) {
            $ff = $f
            if (-not (Invoke-FixItStep ('Set aside the update folder {0}' -f $ff) { $aside = Rename-FixItFolderAside -Path $ff -Tag $tag; if ($aside) { Add-FixItUndoStep ([ordered]@{ Kind = 'rename'; Path = $ff; Aside = [string]$aside }) } })) { $ok = $false }
        }
    }
    foreach ($s in @('cryptsvc', 'bits', 'wuauserv', 'msiserver')) { $sn = $s; if (-not (Invoke-FixItStep ('Start the Windows service {0}' -f $sn) { Start-FixItService -Name $sn })) { $ok = $false } }
    if (-not $script:DryRun -and (Get-FixItServiceStatus -Name 'wuauserv') -ne 'Running') { $ok = $false }
    return New-FixItResult $ok 'Windows Update reset' $(if ($ok) { 'Done' } else { 'The Windows Update reset did not finish.' })
}

function Invoke-WinUpdateDeepAdmin {
    $ok = $true
    $needRestart = $false
    Add-FixItCannotUndo 'The deep Windows repair (DISM and sfc) cannot be undone.'
    Write-Host 'Repairing Windows. This can take 20 to 40 minutes. Please leave this window open.'
    Write-Host ''
    Write-Host 'Step 1 of 2: repairing Windows files (DISM)...'
    $dism = Invoke-FixItStep 'Repair the Windows component store (DISM RestoreHealth)' { Invoke-FixItTool -File 'dism.exe' -Arguments @('/Online', '/Cleanup-Image', '/RestoreHealth') -OkCodes @(0, 3010) -Live }
    if (-not $dism) { $ok = $false }
    Write-Host ''
    Write-Host 'Step 2 of 2: checking system files (SFC)...'
    $sfc = Invoke-FixItStep 'Check and repair system files (sfc /scannow)' { Invoke-FixItTool -File 'sfc.exe' -Arguments @('/scannow') -Live }
    if (-not $sfc) { $ok = $false }
    if (-not $script:DryRun) { $needRestart = $true }
    return New-FixItResult $ok 'Deep repair' $(if ($ok) { 'The deep repair finished.' } else { 'The deep repair found a problem it could not fix.' }) @() @{ NeedsRestart = $needRestart }
}

function Invoke-WinUpdateFix {
    Write-FixItLog 'Started: Fix Windows Update'
    $state = Get-FixItState
    $recent = $false
    $last = [string](Get-FixItProp $state 'LastQuickReset' '')
    if ($last) { $d = [datetime]::MinValue; if ([datetime]::TryParse($last, [ref]$d) -and ((Get-Date) - $d).TotalDays -lt 3) { $recent = $true } }
    $lines = @()
    $quickOk = $false
    $declined = $false
    if ($recent) {
        Write-FixItLog 'The quick reset was already done in the last 3 days'
        $lines += 'The quick reset was already done recently, and updates are still stuck.'
    } else {
        $admin = Invoke-AdminPart -Part 'WinUpdateAdmin' -InProcess { Invoke-WinUpdateAdmin }
        $declined = Test-FixItDeclined $admin
        $quickOk = [bool]$admin.Ok
        if ($quickOk -and -not $script:DryRun) { Set-FixItStateValue -Name 'LastQuickReset' -Value ((Get-Date).ToString('s')) }
        if ($declined) { return New-FixItResult $false 'Permission needed' 'Windows needs your permission to reset updates, and it was not given. Please click the button again and choose Yes.' }
    }
    if ($quickOk) {
        Invoke-FixItStep 'Open Windows Update settings' { Open-FixItSettings -Uri 'ms-settings:windowsupdate' } | Out-Null
        if ($script:DryRun) { return New-FixItResult $true 'Practice run' 'Practice run only - nothing was changed. Details are in the log file.' $lines }
        Write-FixItLog 'Finished: Fix Windows Update - quick reset worked'
        return New-FixItResult $true 'Updates reset' 'Windows Update was reset. I opened the Windows Update page: click "Check for updates". If updates are still stuck, click this button again later and I will offer a deeper repair.' $lines
    }
    if (-not $recent) { $lines += 'The quick reset did not finish.' }
    if (-not (Confirm-FixItStep "Run the deeper repair? It checks and repairs Windows itself and can take 20 to 40 minutes. A black window will show the progress - please leave it open. Windows will ask for permission.")) {
        return New-FixItResult $false 'Not fixed yet' 'No problem. Click this button again when you have time for the deeper repair.' $lines
    }
    $deep = Invoke-AdminPart -Part 'WinUpdateDeepAdmin' -InProcess { Invoke-WinUpdateDeepAdmin } -Visible
    if (Test-FixItDeclined $deep) { return New-FixItResult $false 'Permission needed' 'Windows needs your permission for the deeper repair, and it was not given.' $lines }
    if ($script:DryRun) { return New-FixItResult $true 'Practice run' 'Practice run only - nothing was changed. Details are in the log file.' $lines }
    if ($deep.Ok) {
        if (Confirm-FixItStep 'The repair finished. Restart your computer now to finish? Please save your work first.') { Restart-FixItComputer; return New-FixItResult $true 'Restarting' 'Your computer will restart in 30 seconds.' $lines }
        return New-FixItResult $true 'Repair finished' 'The deeper repair finished. Please restart your computer soon, then check for updates.' $lines
    }
    return New-FixItResult $false 'Repair did not finish' 'The deeper repair could not fix everything. Please click the report button so Trey can look at it.' $lines
}

# ---------------------------------------------------------------------------
# OneDrive
# ---------------------------------------------------------------------------
function Invoke-OneDriveFix {
    Write-FixItLog 'Started: Fix OneDrive'
    $lines = @()
    $info = Get-FixItOneDriveInfo
    $accounts = @($info.Accounts)
    if (-not $info.Installed) {
        return New-FixItResult $false 'OneDrive not found' 'OneDrive does not seem to be installed for this user, so there is nothing to fix.' @()
    }
    $lines += ('OneDrive is {0}.' -f $(if ($info.Running) { 'running' } else { 'NOT running' }))
    if ($accounts.Count -eq 0) { $lines += 'OneDrive is not signed in. Click the OneDrive cloud icon near the clock and sign in.' }
    foreach ($a in $accounts) {
        $st = 'Unknown'
        try { $st = Get-FixItOneDriveSyncState -Kind $a.Kind } catch { }
        $txt = switch ($st) { 'UpToDate' { 'up to date' } 'Paused' { 'PAUSED - click the cloud icon and choose Resume syncing' } 'Problem' { 'has a sync problem' } default { 'status could not be read' } }
        $lines += ('Signed in as {0}: {1}.' -f $a.Email, $txt)
        if ($a.Folder -and (Test-Path -LiteralPath $a.Folder)) {
            $lines += ('  Its folder: {0}' -f $a.Folder)
        }
    }
    $free = Get-FixItFreeBytes
    $lines += ('Free space on this computer: {0}.' -f (Format-FixItBytes $free))
    $bk = Get-FixItBackupSummary
    if ($bk.Ok) { $lines += 'Backup check: your Desktop, Documents and Pictures are backed up to OneDrive.' } else { foreach ($w in $bk.Warnings) { $lines += ('BACKUP WARNING: ' + $w) } }
    $kf = Get-FixItKnownFolders
    foreach ($pair in @(@('Desktop', $kf.Desktop), @('Documents', $kf.Documents), @('Pictures', $kf.Pictures))) {
        $inOd = ([string]$pair[1] -match '(?i)\\OneDrive')
        $lines += ('Your {0} folder is here: {1}{2}' -f $pair[0], $pair[1], $(if ($inOd) { '  (kept in OneDrive)' } else { '  (on this computer only)' }))
    }
    if (-not (Confirm-FixItStep "Reset OneDrive? This makes OneDrive check everything again and can take a few minutes. Your files are NOT deleted.")) {
        if ($script:DryRun) { return New-FixItResult $true 'Practice run' 'Practice run only.' $lines }
        return New-FixItResult $true 'OneDrive checked' 'Here is what I found. Nothing was changed.' $lines
    }
    $exe = $info.Exe
    Add-FixItCannotUndo 'The OneDrive reset cannot be undone (your files were not deleted; OneDrive just checks them again).'
    $okReset = Invoke-FixItStep 'Reset OneDrive (onedrive.exe /reset)' { Start-FixItOneDriveReset -Exe $exe }
    if ($okReset -and -not $script:DryRun) {
        $end = (Get-Date).AddSeconds(90)
        Wait-FixIt -Seconds 10
        while (@(Get-FixItOneDriveInfo | ForEach-Object { $_.Running } | Where-Object { $_ }).Count -eq 0 -and (Get-Date) -lt $end) { Wait-FixIt -Seconds 5 }
        if (-not (Get-FixItOneDriveInfo).Running) { Invoke-FixItStep 'Start OneDrive again' { Start-FixItOneDrive -Exe $exe } | Out-Null }
    }
    if ($script:DryRun) { return New-FixItResult $true 'Practice run' 'Practice run only - nothing was changed. Details are in the log file.' $lines }
    if (-not $okReset) { return New-FixItResult $false 'OneDrive not reset' 'OneDrive could not be reset. Please click the report button and send Trey the report.' $lines }
    Write-FixItLog 'Finished: Fix OneDrive - reset'
    return New-FixItResult $true 'OneDrive reset' 'OneDrive was reset and is checking your files again. Give it a few minutes. Your files were not deleted.' $lines
}

# ---------------------------------------------------------------------------
# Settings remembered per user (big text, high contrast)
# ---------------------------------------------------------------------------
function Get-FixItSetting {
    param([string]$Name, [string]$Default = '')
    $v = Get-FixItProp (Get-FixItState) $Name $null
    if ($null -eq $v) { return $Default }
    return [string]$v
}
function Set-FixItSetting {
    param([string]$Name, [string]$Value)
    if ($script:DryRun) { Write-FixItLog ('Would do: remember setting {0}={1}' -f $Name, $Value) 'DRYRUN'; return }
    Set-FixItStateValue -Name $Name -Value $Value
}

# Colours for each kind of tile. In high contrast mode everything is black, white and yellow.
function Get-FixItTileColors {
    param([string]$Style, [bool]$Hover = $false, [bool]$HighContrast = $false, [string]$IconBg = '#E6F0FA')
    if ($Style -eq 'btn') { $Style = 'outline' }
    if ($HighContrast) {
        $c = @{ Fill = '#000000'; Line = '#FFFFFF'; LineW = 2.0; Title = '#FFFFFF'; Sub = '#FFFFFF'; IconBg = '#FFFFFF' }
        switch ($Style) {
            'card'    { if ($Hover) { $c.Fill = '#1A1A1A'; $c.Line = '#FFFF00' } }
            'scam'    { $c.Line = '#FF5555'; $c.Title = '#FF8A8A'; $c.Sub = '#FFFFFF'; $c.IconBg = '#D9473C'; if ($Hover) { $c.Fill = '#2A0000' } }
            'primary' { $c.Fill = '#FFFF00'; $c.Line = '#FFFF00'; $c.Title = '#000000'; $c.Sub = '#000000'; $c.IconBg = '#000000'; if ($Hover) { $c.Fill = '#FFFFFF'; $c.Line = '#FFFFFF' } }
            'outline' { $c.Line = '#FFFF00'; $c.Title = '#FFFF00'; $c.IconBg = '#FFFF00'; if ($Hover) { $c.Fill = '#1A1A1A' } }
            'yes'     { $c.Fill = '#FFFF00'; $c.Line = '#FFFF00'; $c.Title = '#000000'; $c.Sub = '#000000'; if ($Hover) { $c.Fill = '#FFFFFF'; $c.Line = '#FFFFFF' } }
            'no'      { $c.Line = '#FF8A8A'; $c.Title = '#FF8A8A'; $c.Sub = '#FF8A8A'; if ($Hover) { $c.Fill = '#2A0000' } }
        }
        return $c
    }
    $c = @{ Fill = '#FFFFFF'; Line = '#E3E3E3'; LineW = 1.0; Title = '#1A1A1A'; Sub = '#6B6B6B'; IconBg = $IconBg }
    switch ($Style) {
        'card'    { if ($Hover) { $c.Fill = '#F3F8FD'; $c.Line = '#0F6CBD' } }
        'scam'    { $c.Fill = '#FDECEA'; $c.Line = '#E5736A'; $c.LineW = 1.5; $c.Title = '#B3261E'; $c.Sub = '#7A3F3A'; $c.IconBg = '#D9473C'; if ($Hover) { $c.Fill = '#FADBD7'; $c.Line = '#D9473C' } }
        'primary' { $c.Fill = '#0F6CBD'; $c.Line = '#0F6CBD'; $c.Title = '#FFFFFF'; $c.Sub = '#E8F2FB'; $c.IconBg = '#3F8BCB'; if ($Hover) { $c.Fill = '#0C5A9E'; $c.Line = '#0C5A9E' } }
        'outline' { $c.Line = '#0F6CBD'; $c.LineW = 1.5; $c.Title = '#0F6CBD'; $c.Sub = '#555F6B'; $c.IconBg = '#E6F0FA'; if ($Hover) { $c.Fill = '#F3F8FD' } }
        'yes'     { $c.Fill = '#107C41'; $c.Line = '#107C41'; $c.Title = '#FFFFFF'; $c.Sub = '#FFFFFF'; if ($Hover) { $c.Fill = '#0B6334'; $c.Line = '#0B6334' } }
        'no'      { $c.Line = '#B3261E'; $c.LineW = 1.5; $c.Title = '#B3261E'; $c.Sub = '#B3261E'; if ($Hover) { $c.Fill = '#FDECEA' } }
    }
    return $c
}
function Get-FixItLuminance {
    param([string]$Hex)
    $h = $Hex.TrimStart('#')
    $v = @(0, 2, 4 | ForEach-Object { [Convert]::ToInt32($h.Substring($_, 2), 16) / 255.0 })
    $l = @($v | ForEach-Object { if ($_ -le 0.03928) { $_ / 12.92 } else { [math]::Pow(($_ + 0.055) / 1.055, 2.4) } })
    return (0.2126 * $l[0] + 0.7152 * $l[1] + 0.0722 * $l[2])
}
function Get-FixItContrast {
    param([string]$A, [string]$B)
    $x = Get-FixItLuminance $A; $y = Get-FixItLuminance $B
    $hi = [math]::Max($x, $y); $lo = [math]::Min($x, $y)
    return (($hi + 0.05) / ($lo + 0.05))
}

# ---------------------------------------------------------------------------
# Undo: every fix writes down how to put things back
# ---------------------------------------------------------------------------
$script:UndoCur = $null
$script:UndoKeep = 30

function Get-FixItUndoFile {
    $b = $env:LOCALAPPDATA
    if (-not $b) { $b = [IO.Path]::GetTempPath() }
    return (Join-Path $b 'FamilyFixIt\undo.json')
}
function Read-FixItUndoJournal {
    $f = Get-FixItUndoFile
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    try { return @(Get-Content -LiteralPath $f -Raw | ConvertFrom-Json | Where-Object { $null -ne $_ }) } catch { Write-FixItLog ('The undo list could not be read: {0}' -f $_.Exception.Message) 'WARN'; return @() }
}
function Write-FixItUndoJournal {
    param($Records)
    if ($script:TestMode) { return }
    $f = Get-FixItUndoFile
    $d = Split-Path -Parent $f
    if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $keep = @($Records | Select-Object -Last $script:UndoKeep)
    [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject $keep -Depth 6), (New-Object Text.UTF8Encoding($false)))
}
function Start-FixItUndoRecord {
    param([string]$Fix, [string]$Title)
    $script:UndoCur = @{ Fix = $Fix; Title = $Title; Steps = (New-Object System.Collections.ArrayList); Cannot = (New-Object System.Collections.ArrayList) }
}
function Add-FixItUndoStep {
    param($Step)
    if ($script:UndoCur -and -not $script:DryRun) { [void]$script:UndoCur.Steps.Add($Step) }
}
function Add-FixItCannotUndo {
    param([string]$Text)
    if ($script:UndoCur -and -not $script:DryRun -and -not $script:UndoCur.Cannot.Contains($Text)) { [void]$script:UndoCur.Cannot.Add($Text) }
}
# Called by the registry helpers just before they change or remove a value.
function Register-FixItRegUndo {
    param([string]$Path, [string]$Name)
    if (-not $script:UndoCur -or $script:DryRun) { return }
    $old = $null
    try { $old = Get-RegValue -Path $Path -Name $Name } catch { }
    $step = [ordered]@{ Kind = 'reg'; Path = $Path; Name = $Name; Existed = ($null -ne $old); Type = 'none'; Value = '' }
    if ($null -ne $old) {
        if ($old -is [byte[]]) { $step.Type = 'binary'; $step.Value = [Convert]::ToBase64String($old) }
        elseif ($old -is [int] -or $old -is [uint32] -or $old -is [int64]) { $step.Type = 'dword'; $step.Value = [string]$old }
        else { $step.Type = 'string'; $step.Value = [string]$old }
    }
    Add-FixItUndoStep $step
}
# Merge what an administrator window recorded into the current record.
function Merge-FixItUndoFromAdmin {
    param($Result)
    if (-not $script:UndoCur) { return }
    foreach ($s in @(Get-FixItProp $Result 'UndoSteps' @())) { if ($null -ne $s) { Add-FixItUndoStep $s } }
    foreach ($c in @(Get-FixItProp $Result 'UndoCannot' @())) { if ($c) { Add-FixItCannotUndo ([string]$c) } }
}
function Save-FixItUndoRecord {
    $cur = $script:UndoCur
    $script:UndoCur = $null
    if (-not $cur -or $script:DryRun) { return }
    if ($cur.Steps.Count -eq 0 -and $cur.Cannot.Count -eq 0) { return }
    $rec = [ordered]@{
        Id = [guid]::NewGuid().ToString('N'); Time = (Get-Date).ToString('s'); Fix = $cur.Fix; Title = $cur.Title
        Undone = $false; Steps = @($cur.Steps); Cannot = @($cur.Cannot)
    }
    try {
        $j = @(Read-FixItUndoJournal)
        $j += [pscustomobject]$rec
        Write-FixItUndoJournal -Records $j
        Write-FixItLog ('Undo information saved for "{0}" ({1} step(s))' -f $cur.Title, $cur.Steps.Count)
    } catch { Write-FixItLog ('Could not save the undo information: {0}' -f $_.Exception.Message) 'WARN' }
}

function Test-FixItUndoNeedsAdmin {
    param($Step)
    $k = [string](Get-FixItProp $Step 'Kind' '')
    if ($k -eq 'rename') { return $true }
    if ($k -eq 'reg') { return ([string](Get-FixItProp $Step 'Path' '') -match '^(?i)HKLM') }
    return $false
}
function Invoke-FixItUndoSteps {
    param($Steps)
    $ok = $true
    $ordered = @($Steps)
    [array]::Reverse($ordered)
    foreach ($s in $ordered) {
        $st = $s
        $kind = [string](Get-FixItProp $st 'Kind' '')
        switch ($kind) {
            'reg' {
                $p = [string]$st.Path; $n = [string]$st.Name
                $label = 'Put the setting {0} \ {1} back the way it was' -f $p, $n
                if (-not (Invoke-FixItStep $label { Restore-FixItRegValue -Path $p -Name $n -Existed ([bool]$st.Existed) -Type ([string]$st.Type) -Value ([string]$st.Value) })) { $ok = $false }
            }
            'file' {
                $b = [string]$st.Backup; $o = [string]$st.Original
                if (-not (Invoke-FixItStep ('Put the saved file back: {0}' -f $o) { Restore-FixItFile -Backup $b -Original $o })) { $ok = $false }
            }
            'rename' {
                $p = [string]$st.Path; $a = [string]$st.Aside
                if (-not (Invoke-FixItStep ('Put the folder {0} back' -f $p) { Restore-FixItFolder -Path $p -Aside $a })) { $ok = $false }
            }
            'audio' {
                $kd = [string]$st.Device; $vol = [int]$st.Volume; $mu = [bool]$st.Muted
                if (-not (Invoke-FixItStep ('Put the {0} volume back to {1}' -f $kd, $vol) { Set-FixItAudioDevice -Kind $kd -Volume $vol -Muted $mu })) { $ok = $false }
            }
            'defaultprinter' {
                $pn = [string]$st.Name
                if (-not (Invoke-FixItStep ('Make {0} the default printer again' -f $pn) { Set-FixItDefaultPrinter -Name $pn })) { $ok = $false }
            }
            default { Write-FixItLog ('Unknown undo step "{0}" skipped' -f $kind) 'WARN'; $ok = $false }
        }
    }
    return $ok
}
function Invoke-UndoAdmin {
    param($Steps = $null)
    $todo = @()
    if ($null -ne $Steps) { $todo = @($Steps) }
    elseif ($InputFile -and (Test-Path -LiteralPath $InputFile)) {
        try { $todo = @((Get-Content -LiteralPath $InputFile -Raw | ConvertFrom-Json).Steps | Where-Object { $null -ne $_ }) } catch { Write-FixItLog ('Could not read the undo steps: {0}' -f $_.Exception.Message) 'ERROR' }
    }
    $svc = @()
    if (@($todo | Where-Object { [string](Get-FixItProp $_ 'Kind' '') -eq 'rename' }).Count -gt 0) { $svc = $script:WuServices }
    foreach ($s in $svc) { $sn = $s; Invoke-FixItStep ('Stop the Windows service {0}' -f $sn) { Stop-FixItService -Name $sn } | Out-Null }
    $ok = Invoke-FixItUndoSteps -Steps $todo
    foreach ($s in @('cryptsvc', 'bits', 'wuauserv', 'msiserver')) { if ($svc -contains $s) { $sn = $s; Invoke-FixItStep ('Start the Windows service {0}' -f $sn) { Start-FixItService -Name $sn } | Out-Null } }
    return New-FixItResult $ok 'Undo (all users)' $(if ($ok) { 'Done' } else { 'Some steps could not be undone.' })
}

function Invoke-UndoLast {
    Write-FixItLog 'Started: undo the last fix'
    $j = @(Read-FixItUndoJournal)
    $open = @($j | Where-Object { -not [bool](Get-FixItProp $_ 'Undone' $false) })
    if ($open.Count -eq 0) { return New-FixItResult $true 'Nothing to undo' 'There is nothing to undo right now.' }
    $rec = $open[$open.Count - 1]
    $steps = @(Get-FixItProp $rec 'Steps' @() | Where-Object { $null -ne $_ })
    $cannot = @(Get-FixItProp $rec 'Cannot' @() | Where-Object { $_ })
    $when = [string](Get-FixItProp $rec 'Time' '')
    $title = [string](Get-FixItProp $rec 'Title' 'the last fix')
    $lines = @()
    foreach ($c in $cannot) { $lines += ('Cannot be undone: {0}' -f $c) }
    if ($steps.Count -eq 0) {
        Mark-FixItUndone -Record $rec
        return New-FixItResult $false 'Cannot be undone' ('"{0}" ({1}) made changes that cannot be undone.' -f $title, $when) $lines
    }
    if (-not (Confirm-FixItStep ('Undo "{0}" from {1}? This puts {2} setting(s) back the way they were.' -f $title, $when, $steps.Count))) {
        return New-FixItResult $true 'Nothing changed' 'OK, nothing was changed.'
    }
    $userSteps = @($steps | Where-Object { -not (Test-FixItUndoNeedsAdmin $_) })
    $adminSteps = @($steps | Where-Object { Test-FixItUndoNeedsAdmin $_ })
    $ok = $true; $declined = $false
    if ($userSteps.Count -gt 0) { if (-not (Invoke-FixItUndoSteps -Steps $userSteps)) { $ok = $false } }
    if ($adminSteps.Count -gt 0) {
        $inFile = Join-Path ([IO.Path]::GetTempPath()) ('fixit-undo-{0}.json' -f ([guid]::NewGuid().ToString('N')))
        if (-not $script:DryRun) { [IO.File]::WriteAllText($inFile, (ConvertTo-Json -InputObject @{ Steps = $adminSteps } -Depth 6), (New-Object Text.UTF8Encoding($false))) }
        try {
            $admin = Invoke-AdminPart -Part 'UndoAdmin' -InputPath $inFile -InProcess { Invoke-UndoAdmin -Steps $adminSteps }
            if (Test-FixItDeclined $admin) { $ok = $false; $declined = $true; $lines += 'Windows needs your permission for part of this undo, and it was not given.' }
            elseif (-not $admin.Ok) { $ok = $false }
        } finally { if (Test-Path -LiteralPath $inFile) { Remove-Item -LiteralPath $inFile -Force -ErrorAction SilentlyContinue } }
    }
    if ($script:DryRun) { return New-FixItResult $true 'Practice run' 'Practice run only - nothing was changed. Details are in the log file.' $lines }
    if ($ok) {
        Mark-FixItUndone -Record $rec
        Write-FixItLog ('Finished: undid "{0}"' -f $title)
        return New-FixItResult $true 'Undone' ('"{0}" was undone.' -f $title) $lines
    }
    if ($declined) { return New-FixItResult $false 'Needs permission' 'Part of this undo needs Windows permission (the shield box), and it was not given. Click Undo again and say Yes when Windows asks.' $lines }
    return New-FixItResult $false 'Could not undo everything' 'Some of it could not be put back. Please click "Send Trey a report".' $lines
}
function Mark-FixItUndone {
    param($Record)
    try {
        $id = [string](Get-FixItProp $Record 'Id' '')
        $j = @(Read-FixItUndoJournal)
        foreach ($r in $j) { if ([string](Get-FixItProp $r 'Id' '') -eq $id) { $r.Undone = $true } }
        Write-FixItUndoJournal -Records $j
    } catch { Write-FixItLog ('Could not update the undo list: {0}' -f $_.Exception.Message) 'WARN' }
}

# ---------------------------------------------------------------------------
# Running a fix: undo record + "Did that fix it?"
# ---------------------------------------------------------------------------
# Every action in one place. The main buttons also carry a Plan: the text of the "Here is what I will do" window.
# Plan.Does = what happens, in order. Plan.Heads = other things worth knowing. Plan.Restart / Plan.SignIn stay empty when
# nothing is needed, otherwise they say when a restart or signing in again may be needed. The window and the tests both read this.
function Get-FixItActionTable {
    return @{
        Printer = @{ Fn = 'Invoke-PrinterFix'; Title = 'Fix my printer'; Fix = $true; Plan = @{
            Time = 'About 1 minute'
            Does = @(
                "I will ask you: Do you know which printer you're trying to use?",
                'If you do, you pick it from a list and I make it your main (default) printer, so Windows uses it first.',
                'If you are not sure, I test every printer on this computer, pick one that is available, make it your main printer, and tell you which one I picked.',
                'I restart the part of Windows that handles printing and clear out any print jobs that are stuck in the line.',
                'I reconnect any shared printers that have lost their connection.')
            Heads = @(
                'Anything waiting in the print line is cancelled, so you will need to print it again.',
                'Windows may ask for permission (a box with a shield). Please click Yes.')
            Restart = ''; SignIn = '' } }
        Acrobat = @{ Fn = 'Invoke-AcrobatFix'; Title = 'Fix Acrobat in Outlook'; Fix = $true; Plan = @{
            Time = 'About 2 minutes'
            Does = @(
                'I close Outlook completely, including the parts that run in the background, and open it again. Often that is all it takes.',
                'I ask you whether Acrobat is showing up in Outlook. If it is, I stop there.',
                "If it is not, I switch the Acrobat add-in back on in Outlook's settings, then close and open Outlook once more and ask you again.",
                'Only if Acrobat is still missing, I offer to repair Acrobat. I ask you first.')
            Heads = @(
                'Outlook closes for a moment. Please save or send anything you are writing first.',
                'Your email accounts, passwords and sign-ins are not touched.')
            Restart = 'Only if Acrobat has to be repaired: Windows may say it needs a restart to finish. I will tell you if so.'; SignIn = '' } }
        AcrobatRepair = @{ Fn = 'Invoke-AcrobatRepair'; Title = 'Repair Acrobat'; Fix = $true; Plan = @{
            Time = 'A few minutes'
            Does = @(
                'I check that the full Adobe Acrobat is installed on this computer.',
                'I close Acrobat and Outlook completely (I ask you first).',
                "I run Windows' own repair for Adobe Acrobat. This takes a few minutes.",
                'I open Outlook again afterwards.')
            Heads = @(
                'Please save your work first. Anything unsaved in Acrobat or Outlook could be lost when they close.',
                'Windows will ask for permission (a box with a shield). Please click Yes.',
                'Your email accounts, passwords and sign-ins are not touched.')
            Restart = 'Windows may say it needs a restart to finish the repair. I will tell you if so.'; SignIn = '' } }
        Outlook = @{ Fn = 'Invoke-OutlookFix'; Title = 'Fix Outlook'; Fix = $true; Plan = @{
            Time = 'About 2 minutes'
            Does = @(
                'I close Outlook completely, including the parts that run in the background, and open it again. Most of the time that is all it needs.',
                'I ask you whether Outlook is working properly now. If it is, I stop there.',
                'If it is not, I ask before going on. Then I look for add-ins (small extras plugged into Outlook) that cause trouble and offer to turn them off (this can be undone), offer to rebuild the Outlook search, and offer to open Outlook in safe mode to test it.')
            Heads = @(
                'Outlook closes for a moment. Please save or send anything you are writing first.',
                'Your email accounts, passwords, sign-ins and Outlook profiles are never cleared or changed.',
                'If you choose to rebuild the search, searching may be incomplete for about an hour.')
            Restart = ''; SignIn = '' } }
        Network = @{ Fn = 'Invoke-NetworkFix'; Title = 'Fix my internet'; Fix = $true; Plan = @{
            Time = 'About 1 to 5 minutes'
            Does = @(
                'I test your router, the internet and opening a website.',
                'If something is wrong, I refresh your internet address, clear the saved website addresses, switch off a setting that can block websites if it is on, and reset the network settings. Windows may ask for permission.',
                "If the internet is still not working, I will ask you to do this: Unplug the router, wait 30 seconds, then plug it back in. Then I ask 'Is that done?'",
                'When you say Yes, I wait about 2 minutes (with a countdown) while the router starts up, then I test again and tell you clearly if it works.',
                'If it still does not work, I tell you to call Trey and send him a report automatically.')
            Heads = @(
                'Your internet disconnects for a few seconds while it is reset. Downloads and video calls will be interrupted.',
                'If you restart the router, everyone in your home loses the internet for a few minutes.')
            Restart = 'Sometimes one of the repairs only finishes after a restart. I will tell you if that happens.'; SignIn = '' } }
        Slow = @{ Fn = 'Invoke-SlowFix'; Title = 'My computer is slow'; Fix = $true; Plan = @{
            Time = 'A few minutes'
            Does = @(
                'If a program has frozen, I offer to close it. I ask first.',
                'I empty your temporary files, empty the Recycle Bin, and empty the temporary files Windows keeps (Windows will ask for permission).',
                "I ask you before clearing your web browser's saved temporary website files (called the cache). If you say No, only that step is skipped.",
                'I show you how much space was freed and which programs use the most memory.')
            Heads = @(
                'The Recycle Bin is emptied for good. Please look inside it first if you might need something.',
                'Deleted temporary files cannot be brought back. Your Documents, Desktop, Pictures and Downloads are never touched.',
                'Anything you have not saved in a frozen program is lost if you let me close it.')
            Restart = 'Not required, but I will suggest a restart if your computer has not been restarted in over a week, or Windows is waiting for one.'
            SignIn = 'Only if you say Yes to clearing the browser cache: you may need to sign back in to websites you visit, so have your passwords handy. I ask you first.' } }
        Sound = @{ Fn = 'Invoke-SoundFix'; Title = 'Fix sound, mic and camera'; Fix = $true; Plan = @{
            Time = 'About 1 minute'
            Does = @(
                'I check your speakers and microphone. If the speakers are muted or almost silent, I turn them on at 25% (quiet, so nothing blasts out) and you can turn them up. If the microphone is muted or almost silent, I turn it on at 70%.',
                'If Windows is blocking programs from using your microphone or camera, I offer to allow it. I ask first.',
                'If needed, I restart the part of Windows that handles sound (Windows will ask for permission).',
                'I open the Windows page where you can pick the right speakers, microphone and camera.')
            Heads = @(
                'Sound cuts out for a second or two while that part of Windows restarts.',
                'A volume that is not muted and not almost silent is left exactly as it is.')
            Restart = ''; SignIn = '' } }
        Browser = @{ Fn = 'Invoke-BrowserFix'; Title = 'Clean up my browser'; Fix = $true; Plan = @{
            Time = 'A few minutes'
            Does = @(
                'I make a safe copy of your browser settings and bookmarks first.',
                'I look for a changed home page or search engine, extensions you do not know, and websites allowed to send you pop-up notices.',
                'For each thing I find, I ask before I open the browser page where you can fix it. You choose what to turn off.',
                'I offer a quick virus scan with Microsoft Defender (5 to 10 minutes). I ask first.')
            Heads = @(
                'I do not change your browser myself. I only open the pages where you can.',
                'Your passwords, bookmarks and history are not touched.')
            Restart = ''
            SignIn = "Only if you choose to reset your browser's settings on a page I open: the browser may sign you out of some websites." } }
        WinUpdate = @{ Fn = 'Invoke-WinUpdateFix'; Title = 'Fix Windows Update'; Fix = $true; Plan = @{
            Time = 'A few minutes (20 to 40 minutes for the deeper repair)'
            Does = @(
                'I pause Windows Update, set aside the folders where it keeps its update files (nothing is deleted), and start it again.',
                'I open the Windows Update page so you can click Check for updates.',
                'If updates are still stuck, I offer a deeper repair of Windows itself. It can take 20 to 40 minutes, and I ask you first.')
            Heads = @(
                'Windows will ask for permission (a box with a shield). Please click Yes.',
                'For the deeper repair, a black window shows the progress. Please leave it open.',
                'Updates cannot be installed for a minute or so while this runs.')
            Restart = 'After the deeper repair, your computer should be restarted. I ask you before I do it. Please save your work first.'; SignIn = '' } }
        OneDrive = @{ Fn = 'Invoke-OneDriveFix'; Title = 'Fix OneDrive'; Fix = $true; Plan = @{
            Time = 'A few minutes'
            Does = @(
                'I check whether OneDrive is installed, signed in and running, and whether your folders are backed up to it.',
                'I tell you what I find. If a reset would help, I ask before I do it.',
                'A reset makes OneDrive restart and check all of your files again. Your files are not deleted.')
            Heads = @(
                'After a reset OneDrive can take a few minutes (longer if you have many files) to catch up.')
            Restart = ''
            SignIn = 'OneDrive normally stays signed in. If it asks you to sign in again, use your usual Microsoft email and password.' } }
        Scam = @{ Fn = 'Invoke-ScamAlert'; Title = 'Scary pop-up'; Fix = $false; Plan = @{
            Time = 'A few seconds'
            Does = @(
                'I gather basic facts about this computer, such as what is running and what was installed or downloaded lately.',
                'I send Trey a report right away and save a copy on your Desktop.',
                'I tell you what to do next.')
            Heads = @(
                'I do not change anything on your computer.',
                'Do NOT call any phone number shown on the screen.')
            Restart = ''; SignIn = '' } }
        Screen = @{ Fn = 'Invoke-ScreenShare'; Title = 'Let Trey see my screen'; Fix = $false; Plan = @{
            Time = 'About 1 minute'
            Does = @(
                'I open the Zoho Assist web page where you type in a code.',
                'Trey gives you the code on the phone. You type it in and click Join. Only then can Trey see your screen.')
            Heads = @(
                'Nothing is installed ahead of time, and Trey cannot see your screen until you do this.',
                'Only do this if YOU called Trey. If someone else asked you to, say no.')
            Restart = ''; SignIn = '' } }
        Report = @{ Fn = 'Invoke-FixItReport'; Title = 'Send Trey a report'; Fix = $false; Plan = @{
            Time = 'A few seconds'
            Does = @(
                'I collect information about this computer that helps Trey: your Windows version, printers, Outlook and Acrobat, a health check and recent problems.',
                'I save a copy on your Desktop and send it to Trey.')
            Heads = @(
                'The report does not include your files or your passwords.',
                'I do not change anything on your computer.')
            Restart = ''; SignIn = '' } }
        Pin = @{ Fn = 'Invoke-PinGuide'; Title = 'Pin me to the taskbar'; Fix = $false }
        Update = @{ Fn = 'Invoke-FixItUpdate'; Title = 'Update'; Fix = $false }
        Restart = @{ Fn = 'Invoke-RestartRight'; Title = 'Restart the right way'; Fix = $false }
        Status = @{ Fn = 'Invoke-StatusCheck'; Title = 'Is it just me?'; Fix = $false }
        Undo = @{ Fn = 'Invoke-UndoLast'; Title = 'Undo last fix'; Fix = $false }
        CheckIn = @{ Fn = 'Invoke-CheckInToggle'; Title = 'Weekly check-in'; Fix = $false }
        HealthCheck = @{ Fn = 'Invoke-HealthCheck'; Title = 'Health check'; Fix = $false }
        History = @{ Fn = 'Invoke-HistoryShow'; Title = 'What did I fix?'; Fix = $false }
        Files = @{ Fn = 'Invoke-FilesHelper'; Title = 'My files'; Fix = $false }
        Install = @{ Fn = 'Invoke-InstallApp'; Title = 'Install an app safely'; Fix = $false }
        Guardian = @{ Fn = 'Invoke-GuardianToggle'; Title = 'Scary pop-up watcher'; Fix = $false }
        PCInfo = @{ Fn = 'Invoke-PcInfo'; Title = 'My PC info'; Fix = $false }
        Guides = @{ Fn = 'Invoke-GuidesHelper'; Title = 'Help me with...'; Fix = $false }
        Simple = @{ Fn = 'Invoke-SimpleToggle'; Title = 'Simple mode'; Fix = $false }
    }
}

# ---------------------------------------------------------------------------
# The "Here is what I will do" window. Every main button shows it first; Go Back does nothing.
# ---------------------------------------------------------------------------
function Get-FixItPlan {
    param([string]$Which)
    $t = (Get-FixItActionTable)[$Which]
    if (-not $t -or -not $t.ContainsKey('Plan')) { return $null }
    $pl = $t.Plan
    $restart = [string]$pl.Restart
    $signIn = [string]$pl.SignIn
    $restartLine = 'You will not need to restart your computer.'
    if ($restart) { $restartLine = 'You may need to restart your computer. ' + $restart }
    $signInLine = 'You will not need to sign in again anywhere.'
    if ($signIn) { $signInLine = 'You may need to sign in again. ' + $signIn }
    return [pscustomobject]@{
        Which = $Which; Title = [string]$t.Title; Time = [string]$pl.Time
        Does = @($pl.Does); Heads = @($pl.Heads)
        NeedsRestart = [bool]$restart; NeedsSignIn = [bool]$signIn
        RestartLine = $restartLine; SignInLine = $signInLine
    }
}

function Format-FixItPlanText {
    param($Plan)
    $o = New-Object System.Collections.Generic.List[string]
    $o.Add($Plan.Title)
    $o.Add(('How long it takes: {0}' -f $Plan.Time))
    $o.Add('')
    $o.Add('Here is what I will do:')
    $n = 1
    foreach ($d in @($Plan.Does)) { $o.Add(('  {0}. {1}' -f $n, $d)); $n++ }
    if (@($Plan.Heads).Count -gt 0) {
        $o.Add('')
        $o.Add('Please know:')
        foreach ($h in @($Plan.Heads)) { $o.Add(('  - {0}' -f $h)) }
    }
    $o.Add('')
    $o.Add($Plan.RestartLine)
    $o.Add($Plan.SignInLine)
    return @($o)
}

# The window shows the plan with Proceed and Go Back. The command line prints it and asks. Returns $true for Proceed.
function Read-FixItPlanChoice {
    param($Plan)
    if ($script:GuiActive) { return [bool](Show-FixItPlanDialog -Plan $Plan) }
    if (-not (Test-FixItCanAsk)) {
        Write-FixItLog 'Nobody is there to press Proceed, so nothing was done. (Run with -Yes to skip the question.)' 'WARN'
        Write-Host 'I could not ask you to press Proceed, so nothing was done. To run this without the question, add -Yes.'
        return $false
    }
    Write-Host ''
    foreach ($l in (Format-FixItPlanText -Plan $Plan)) { Write-Host $l }
    Write-Host ''
    $a = Read-Host 'Type P to Proceed, or G to Go Back'
    return ($a -match '^(p|proceed)$')
}

function Confirm-FixItPlan {
    param([string]$Which)
    $plan = Get-FixItPlan -Which $Which
    if ($null -eq $plan) { return $true }
    if ($script:Background) { return $true }   # background work is never asked
    if ($script:TestAll) { return $true }
    if ($script:DryRun -and -not $script:TestMode) {
        Write-FixItLog ('Would show the "what I will do" window for: {0}' -f $plan.Title) 'DRYRUN'
        foreach ($l in (Format-FixItPlanText -Plan $plan)) { if ($l) { Write-FixItLog ('  {0}' -f $l) 'DRYRUN' } }
        return $true
    }
    if ($script:AssumeYes -and -not $script:GuiActive) {
        Write-FixItLog ('Plan window "{0}" -> Proceed (-Yes was given)' -f $plan.Title)
        return $true
    }
    $go = [bool](Read-FixItPlanChoice -Plan $plan)
    Write-FixItLog ('Plan window "{0}" -> {1}' -f $plan.Title, $(if ($go) { 'Proceed' } else { 'Go Back (nothing was done)' }))
    return $go
}

# Runs one action by name, keeping an undo record for the fixes. Returns the result.
# Main buttons show the "what I will do" window first; Go Back returns nothing and changes nothing.
function Invoke-FixItAction {
    param([string]$Which, [switch]$SkipPlan)
    $t = (Get-FixItActionTable)[$Which]
    if (-not $t) { throw ('Unknown action {0}' -f $Which) }
    if (-not $SkipPlan) { if (-not (Confirm-FixItPlan -Which $Which)) { return $null } }
    if ($t.Fix) { Start-FixItUndoRecord -Fix $Which -Title $t.Title }
    try {
        $r = & $t.Fn
        if ($t.Fix -and -not $script:DryRun -and $r) { Write-FixItLog ('Fix result: {0}|{1}|{2}' -f $Which, $t.Title, $(if ($r.Ok) { 'ok' } else { 'problem' })) }
        return $r
    } finally { if ($t.Fix) { Save-FixItUndoRecord } }
}

# After a fix: ask "Did that fix it?". "No" sends the report to Trey on its own.
function Invoke-FixItFollowUp {
    param([string]$Which, $Result)
    $t = (Get-FixItActionTable)[$Which]
    if (-not $t -or -not $t.Fix -or $null -eq $Result) { return $null }
    if (Test-FixItDeclined $Result) { return $null }
    if (Test-FixItSkipFollowUp $Result) { return $null }
    if ($script:DryRun -and -not $script:TestMode) { Write-FixItLog 'Would ask: Did that fix it?' 'DRYRUN'; return $null }
    if ($script:TestAll) { return $null }
    if (-not (Test-FixItCanAsk)) { Write-FixItLog 'Nobody is there to answer "Did that fix it?", so no report was sent' 'WARN'; return $null }
    $yes = Confirm-FixIt -Question 'Did that fix it?' -Title $t.Title -Kind 'Fixed' -Detail ("I just ran {0}. Try it now, then let me know." -f $t.Title)
    Write-FixItLog ('Did that fix it? ({0}) -> {1}' -f $t.Title, $(if ($yes) { 'yes' } else { 'NO' })) $(if ($yes) { 'INFO' } else { 'WARN' })
    if ($yes) { return $null }
    $note = 'The person said the fix "{0}" did NOT fix the problem. Result shown to them: {1}' -f $t.Title, [string]$Result.Title
    return (Invoke-FixItReport -Note $note)
}

# What the command line and the window both do for one button.
function Invoke-FixItAndShow {
    param([string]$Which)
    if ($script:TestMode) { Start-FixItTestButton }
    $r = Invoke-FixItAction -Which $Which
    if ($script:TestMode) {
        $f = Invoke-FixItFollowUp -Which $Which -Result $r
        $said = Get-FixItTestSaid -Result $r
        Complete-FixItTestRecords -Result $r
        foreach ($l in (Format-FixItTestChecklist -Title ([string](Get-FixItActionTable)[$Which].Title) -Records (Get-FixItTestRecords) -Said $said)) { Write-Host $l }
        return $r
    }
    Show-FixItResult $r
    $f = Invoke-FixItFollowUp -Which $Which -Result $r
    if ($f) { Show-FixItResult $f }
    return $r
}

# ---------------------------------------------------------------------------
# Restart the right way
# ---------------------------------------------------------------------------
function Invoke-RestartRight {
    Write-FixItLog 'Started: restart the right way'
    if (-not (Confirm-FixItStep "Restart your computer completely now?`r`n`r`nSave your work first. This is a full restart - it clears problems that 'Shut down' and turning it on again do not.")) {
        return New-FixItResult $true 'Not restarted' 'OK, your computer was not restarted.'
    }
    if (-not (Invoke-FixItStep 'Restart the computer completely (shutdown /r /t 0)' { Restart-FixItNow })) {
        return New-FixItResult $false 'Could not restart' 'The restart did not start. Please use the Start menu: Power, then Restart.'
    }
    if ($script:DryRun) { return New-FixItResult $true 'Practice run' 'Practice run only - the computer would restart now.' }
    return New-FixItResult $true 'Restarting' 'Your computer is restarting now.'
}

# ---------------------------------------------------------------------------
# Is it just me?
# ---------------------------------------------------------------------------
function Get-FixItStatusProblems {
    param([string]$FeedXml)
    $problems = @()
    $x = New-Object System.Xml.XmlDocument
    $x.LoadXml($FeedXml)
    foreach ($i in @($x.SelectNodes('//item'))) {
        $st = ''; $sn = $i.SelectSingleNode('status'); if ($sn) { $st = [string]$sn.InnerText }
        $ti = ''; $tn = $i.SelectSingleNode('title'); if ($tn) { $ti = [string]$tn.InnerText }
        if ($st -and $st -notmatch '^(?i)(Available|Operational|Resolved|Normal)$') { $problems += ('{0}: {1}' -f $ti, $st) }
    }
    return $problems
}
function Invoke-StatusCheck {
    Write-FixItLog 'Started: is it just me?'
    $internet = [bool](Test-FixItPing -Target '8.8.8.8') -and [bool](Test-FixItDns -Name 'www.microsoft.com')
    if (-not $internet) {
        return New-FixItResult $false 'Your internet is not working' "Your computer cannot reach the internet, so it is not just Outlook or Microsoft - it is your connection.`r`n`r`nClick 'Fix my internet'." @('The internet: not reachable')
    }
    $reach = [ordered]@{
        'Outlook mail servers' = 'https://outlook.office365.com/'
        'Microsoft sign-in' = 'https://login.microsoftonline.com/'
        'Microsoft 365 websites' = 'https://www.office.com/'
    }
    $down = @(); $lines = @('The internet: reachable')
    foreach ($k in $reach.Keys) {
        if (Test-FixItHttps -Url $reach[$k]) { $lines += ('{0}: reachable from your computer' -f $k) } else { $down += $k; $lines += ('{0}: NOT reachable from your computer' -f $k) }
    }
    $problems = @(); $feedOk = $true
    try { $problems = @(Get-FixItStatusProblems -FeedXml (Get-WebText -Url $script:StatusFeedUrl)) } catch { $feedOk = $false; Write-FixItLog ('Could not read the Microsoft status feed: {0}' -f $_.Exception.Message) 'WARN' }
    if ($feedOk) { if ($problems.Count -eq 0) { $lines += 'Microsoft says: all services are working' } else { foreach ($p in $problems) { $lines += ('Microsoft says: {0}' -f $p) } } }
    else { $lines += "Microsoft's status page could not be read" }
    Write-FixItLog ('Status check: down={0} problems={1} feedOk={2}' -f $down.Count, $problems.Count, $feedOk)
    if ($problems.Count -gt 0) {
        return New-FixItResult $false 'Microsoft has a problem' "It is not just you - Microsoft is reporting a problem with its services. There is nothing wrong with your computer. Please wait a while and try again." $lines
    }
    if ($down.Count -gt 0) {
        return New-FixItResult $false 'Your computer cannot reach Microsoft' "Microsoft is not reporting a problem, but your computer cannot reach some Microsoft services. Try 'Fix my internet' or restart your router." $lines
    }
    if (-not $feedOk) {
        return New-FixItResult $true 'No problem found' "Your internet works and your computer can reach Microsoft. I could not read Microsoft's status page, so I cannot be sure it is not them. Try again in a few minutes." $lines
    }
    return New-FixItResult $true 'It is just you' "Microsoft says everything is working and your computer can reach it. So the problem is probably on your computer. Try the matching fix button (for example 'Fix Outlook') or 'Send Trey a report'." $lines
}

# ---------------------------------------------------------------------------
# Backup check and the weekly health summary
# ---------------------------------------------------------------------------
function Get-FixItBackupSummary {
    $info = Get-FixItOneDriveInfo
    $accts = @($info.Accounts)
    $kf = Get-FixItKnownFolders
    $warn = @(); $imp = @(); $folders = @()
    foreach ($pair in @(@('Desktop', $kf.Desktop), @('Documents', $kf.Documents), @('Pictures', $kf.Pictures))) {
        $path = [string]$pair[1]
        $inOd = $false
        foreach ($a in $accts) { if ($a.Folder -and $path.StartsWith(([string]$a.Folder).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $inOd = $true } }
        if (-not $inOd -and $path -match '(?i)\\OneDrive[^\\]*\\') { $inOd = $true }
        $folders += [pscustomobject]@{ Name = $pair[0]; Path = $path; InOneDrive = $inOd }
    }
    $last = $null
    if (-not $info.Installed) { $warn += 'OneDrive is not installed, so your Desktop, Documents and Pictures are not backed up online.' }
    else {
        if ($accts.Count -eq 0) { $warn += 'OneDrive is not signed in, so nothing is being backed up online.' }
        elseif (-not $info.Running) { $warn += 'OneDrive is not running, so nothing is being backed up right now.'; $imp += $warn[$warn.Count - 1] }
        $off = @($folders | Where-Object { -not $_.InOneDrive })
        if ($off.Count -gt 0) { $warn += ('Not backed up to OneDrive: {0}.' -f (($off | ForEach-Object { $_.Name }) -join ', ')) }
        try { $last = Get-FixItOneDriveLastSync } catch { }
        if ($accts.Count -gt 0 -and $last -and (((Get-Date) - [datetime]$last).TotalDays -gt 7)) { $warn += ('OneDrive has not synced for {0} days.' -f [int]((Get-Date) - [datetime]$last).TotalDays); if (((Get-Date) - [datetime]$last).TotalDays -gt 14) { $imp += $warn[$warn.Count - 1] } }
        foreach ($a in $accts) {
            $st = 'Unknown'; try { $st = Get-FixItOneDriveSyncState -Kind $a.Kind } catch { }
            if ($st -eq 'Paused') { $warn += ('OneDrive syncing is paused for {0}.' -f $a.Email); $imp += $warn[$warn.Count - 1] }
            if ($st -eq 'Problem') { $warn += ('OneDrive has a sync problem for {0}.' -f $a.Email); $imp += $warn[$warn.Count - 1] }
        }
    }
    return [pscustomobject]@{ Installed = [bool]$info.Installed; Running = [bool]$info.Running; SignedIn = ($accts.Count -gt 0); Folders = $folders; LastSync = $last; Warnings = $warn; Important = $imp; Ok = ($warn.Count -eq 0) }
}

function Get-FixItHealthSummary {
    $attention = @(); $lines = @()
    $os = Get-FixItOsInfo
    $lines += ('Computer: {0}   Windows user: {1}' -f $os.ComputerName, $os.UserName)
    $lines += ('Windows: {0} (build {1})' -f $os.Caption, $os.Build)
    $lines += ('Family Fix-It version: {0}' -f $script:FixItVersion)
    $free = Get-FixItFreeBytes
    $lines += ('Free disk space on C: {0}' -f (Format-FixItBytes $free))
    if ($free -lt 10GB) { $attention += ('Low disk space: only {0} free.' -f (Format-FixItBytes $free)) }
    $up = Get-FixItUptimeDays
    $lines += ('Days since last restart: {0}' -f $up)
    if ($up -gt 14) { $attention += ('The computer has not been restarted for {0} days.' -f $up) }
    $pend = Test-PendingReboot
    $lines += ('Windows waiting for a restart: {0}' -f $(if ($pend) { 'YES' } else { 'no' }))
    if ($pend) { $attention += 'Windows is waiting for a restart.' }   # only the two real Windows flags (see Test-PendingReboot)
    $pu = -1; try { $pu = [int](Get-FixItPendingUpdates) } catch { }
    if ($pu -ge 0) { $lines += ('Windows updates waiting to install: {0}' -f $pu); if ($pu -gt 20) { $attention += ('{0} Windows updates are waiting.' -f $pu) } } else { $lines += 'Windows updates waiting to install: could not check' }
    $lines += ('Last Windows update installed: {0}' -f (Get-FixItLastUpdate))
    $d = $null; try { $d = Get-FixItDefender } catch { }
    if ($d) {
        $lines += ('Windows Defender: protection {0}, real-time {1}, virus definitions {2} day(s) old' -f $(if ($d.Enabled) { 'on' } else { 'OFF' }), $(if ($d.RealTime) { 'on' } else { 'OFF' }), $d.SignatureAgeDays)
        $ls = 'never'; $scanAge = 9999
        if ($d.LastQuickScan) { $ls = ([datetime]$d.LastQuickScan).ToString('yyyy-MM-dd'); $scanAge = [int]((Get-Date) - [datetime]$d.LastQuickScan).TotalDays }
        $lines += ('Last Defender scan: {0}' -f $ls)
        if (-not $d.Enabled -or -not $d.RealTime) { $attention += 'Windows Defender protection is turned off.' }
        if ($d.SignatureAgeDays -gt 14) { $attention += ('Virus definitions are {0} days old.' -f $d.SignatureAgeDays) }   # the report still lists the age and the last scan; Defender scans on its own
    } else { $lines += 'Windows Defender: could not check (another antivirus may be in use)' }
    $b = Get-FixItBackupSummary
    $lines += ('OneDrive: {0}' -f $(if (-not $b.Installed) { 'not installed' } elseif (-not $b.SignedIn) { 'not signed in' } elseif ($b.Running) { 'running' } else { 'NOT running' }))
    foreach ($f in $b.Folders) { $lines += ('  {0}: {1}' -f $f.Name, $(if ($f.InOneDrive) { 'backed up to OneDrive' } else { 'NOT backed up' })) }
    if ($b.LastSync) { $lines += ('  Last OneDrive activity: {0}' -f ([datetime]$b.LastSync).ToString('yyyy-MM-dd')) }
    foreach ($w in @($b.Important)) { $attention += $w }   # the other backup notes are already in the lines above
    foreach ($w in @($b.Warnings)) { if (@($b.Important) -notcontains $w) { Write-FixItLog ('Backup note (not raised): {0}' -f $w) } }
    return [pscustomobject]@{ Lines = $lines; Attention = $attention }
}

function Invoke-HealthCheck {
    Write-FixItLog 'Started: weekly health check'
    $h = $null
    try { $h = Get-FixItHealthSummary } catch {
        Write-FixItLog ('Health check failed: {0}' -f $_.Exception.Message) 'ERROR'
        return New-FixItResult $false 'Health check failed' 'The health check could not be completed.'
    }
    $o = @('FAMILY FIX-IT WEEKLY HEALTH CHECK', ('Made: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm')), (Get-FixItPcCodeLine), '')
    if (@($h.Attention).Count -eq 0) { $o += 'ATTENTION: nothing - all fine.' } else { $o += 'ATTENTION:'; foreach ($a in $h.Attention) { $o += ('  * ' + $a) } }
    $o += ''; $o += $h.Lines
    $text = $o -join "`r`n"
    $sent = Send-FixItReport -Text $text -Kind 'health'
    Write-FixItLog ('Finished: weekly health check (needs attention: {0}, sent: {1})' -f @($h.Attention).Count, $sent)
    if ($script:DryRun) { return New-FixItResult $true 'Practice run' 'Practice run only - nothing was sent.' $o @{ ReportText = $text } }
    return New-FixItResult $sent $(if ($sent) { 'Health check sent' } else { 'Health check not sent' }) $(if ($sent) { 'The weekly health check was sent to Trey.' } else { 'The weekly health check could not be sent.' }) @() @{ ReportText = $text; Sent = $sent }
}

# ---------------------------------------------------------------------------
# Weekly check-in (a Scheduled Task for this user only - no administrator rights)
# ---------------------------------------------------------------------------
$script:CheckInTaskName = 'Family Fix-It Weekly Check'
function Get-FixItCheckInXml {
    param([string]$ScriptPath)
    $esc = { param($v) [Security.SecurityElement]::Escape($v) }
    $args1 = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action HealthCheck' -f $ScriptPath
    return ('<?xml version="1.0" encoding="UTF-16"?>' + "`r`n" +
        '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">' +
        '<RegistrationInfo><Description>Sends Trey a small weekly health summary (Family Fix-It).</Description></RegistrationInfo>' +
        '<Triggers><CalendarTrigger><StartBoundary>2026-01-04T10:00:00</StartBoundary><Enabled>true</Enabled><ScheduleByWeek><DaysOfWeek><Sunday /></DaysOfWeek><WeeksInterval>1</WeeksInterval></ScheduleByWeek></CalendarTrigger></Triggers>' +
        '<Principals><Principal id="Author"><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>' +
        '<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><ExecutionTimeLimit>PT15M</ExecutionTimeLimit><Enabled>true</Enabled></Settings>' +
        '<Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>' + (& $esc $args1) + '</Arguments></Exec></Actions></Task>')
}
function Install-FixItCheckIn {
    $sp = $script:SelfPath
    if (-not $sp -or -not (Test-Path -LiteralPath $sp)) { throw 'The tool path is not known' }
    Register-FixItTask -Name $script:CheckInTaskName -Xml (Get-FixItCheckInXml -ScriptPath $sp)
}
function Invoke-CheckInToggle {
    param([ValidateSet('Toggle', 'On', 'Off')][string]$Mode = 'Toggle')
    Write-FixItLog ('Started: weekly check-in ({0})' -f $Mode)
    $on = [bool](Test-FixItTask -Name $script:CheckInTaskName)
    $wantOn = (-not $on)
    if ($Mode -eq 'On') { $wantOn = $true } elseif ($Mode -eq 'Off') { $wantOn = $false }
    if ($wantOn) {
        if (-not $on -and $Mode -eq 'Toggle') {
            if (-not (Confirm-FixItStep "Turn on the weekly check-in?`r`n`r`nOnce a week this computer quietly sends Trey a small summary: free disk space, updates, antivirus, OneDrive backup and when it was last restarted. It never sends your files, documents or passwords. You can turn it off here at any time.")) {
                return New-FixItResult $true 'Not turned on' 'OK, the weekly check-in stays off.'
            }
        }
        if (-not (Invoke-FixItStep 'Set up the weekly check-in (a Windows scheduled task for this user)' { Install-FixItCheckIn })) {
            return New-FixItResult $false 'Could not turn it on' 'The weekly check-in could not be set up.'
        }
        if ($script:DryRun) { return New-FixItResult $true 'Practice run' 'Practice run only - the weekly check-in would be turned on.' }
        return New-FixItResult $true 'Weekly check-in is on' 'Every Sunday this computer will quietly send Trey a small health summary. (If it was off at that time, it runs the next time you are signed in.)'
    }
    if ($on) {
        if (-not (Invoke-FixItStep 'Remove the weekly check-in scheduled task' { Unregister-FixItTask -Name $script:CheckInTaskName })) {
            return New-FixItResult $false 'Could not turn it off' 'The weekly check-in could not be turned off.'
        }
    } else { Write-FixItLog 'The weekly check-in was already off' }
    if ($script:DryRun) { return New-FixItResult $true 'Practice run' 'Practice run only - the weekly check-in would be turned off.' }
    return New-FixItResult $true 'Weekly check-in is off' 'The weekly check-in is turned off. Nothing will be sent.'
}


# The small "healthy" badge in the window header. Quick and read-only.
function Get-FixItHealthPill {
    if (Test-FixItOffUiWanted) { return (Invoke-FixItOffUi -Command 'Get-FixItHealthPill') }
    $issues = @()
    try { if ([int64](Get-FixItFreeBytes) -lt 10GB) { $issues += 'low disk space' } } catch { }
    try { $rw = Test-FixItRestartWanted; if ($rw.Wanted) { $issues += 'restart waiting' } } catch { }
    $bk = $null
    try { $bk = Get-FixItBackupSummary } catch { }
    $dot = [string][char]0x00B7
    $backup = 'backup unknown'
    if ($bk) {
        # Only a backup that is set up but not working needs a look. No OneDrive at all, or one folder outside it, is not a problem for the badge (Trey's report still lists it).
        if (@($bk.Important).Count -gt 0) { $backup = 'backup needs a look'; $issues += 'backup needs a look' }
        elseif ($bk.Ok) { $backup = 'backup on' }
        elseif (-not $bk.Installed) { $backup = 'no backup' }
        else { $backup = 'backup partly on' }
    }
    if ($issues.Count -eq 0) { return [pscustomobject]@{ Ok = $true; Text = ('Your computer looks healthy {0} {1}' -f $dot, $backup) } }
    return [pscustomobject]@{ Ok = $false; Text = ('Needs a look: {0}' -f (($issues | Select-Object -First 2) -join ', ')) }
}

# ---------------------------------------------------------------------------
# What did I fix?  (read from the tool's own log)
# ---------------------------------------------------------------------------
function Read-FixItLogLines {
    $out = @()
    try {
        $dir = Split-Path -Parent $script:LogFile
        $files = @()
        if ($dir -and (Test-Path -LiteralPath $dir)) { $files = @(Get-ChildItem -LiteralPath $dir -Filter 'fixit-*.log' -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 60) }
        foreach ($f in $files) { $out += @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue) }
        if ($script:LogFile -and (Test-Path -LiteralPath $script:LogFile) -and (@($files | Where-Object { $_.FullName -eq $script:LogFile }).Count -eq 0)) { $out += @(Get-Content -LiteralPath $script:LogFile -Encoding UTF8 -ErrorAction SilentlyContinue) }
    } catch { }
    return $out
}
function Get-FixItHistory {
    param([int]$Max = 15)
    $items = New-Object System.Collections.ArrayList
    $inv = [Globalization.CultureInfo]::InvariantCulture
    foreach ($l in @(Read-FixItLogLines)) {
        $line = [string]$l
        $m = [regex]::Match($line, '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) \[\w+\] Fix result: ([^|]+)\|([^|]*)\|(ok|problem)\s*$')
        if ($m.Success) {
            $when = [datetime]::MinValue
            try { $when = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', $inv) } catch { }
            [void]$items.Add([pscustomobject]@{ Time = $when; Fix = $m.Groups[2].Value; Title = $m.Groups[3].Value; Ok = ($m.Groups[4].Value -eq 'ok'); Answer = '' })
            continue
        }
        $m = [regex]::Match($line, '\] Did that fix it\? \((.*)\) -> (yes|NO)\s*$')
        if ($m.Success -and $items.Count -gt 0) {
            $last = $items[$items.Count - 1]
            if ($last.Title -eq $m.Groups[1].Value -and $last.Answer -eq '') { $last.Answer = $m.Groups[2].Value.ToLower() }
        }
    }
    $arr = @($items.ToArray())
    [array]::Reverse($arr)
    return @($arr | Select-Object -First $Max)
}
function Format-FixItHistoryLine {
    param($Item)
    $when = ([datetime]$Item.Time).ToString('ddd MMM d, h:mm tt', [Globalization.CultureInfo]::InvariantCulture)
    $res = 'finished (you did not say if it worked)'
    if ($Item.Answer -eq 'yes') { $res = 'WORKED (you said yes)' }
    elseif ($Item.Answer -eq 'no') { $res = 'did NOT work (you said no) - a report went to Trey' }
    elseif (-not $Item.Ok) { $res = 'could not be finished' }
    return ('{0}  -  {1}  -  {2}' -f $when, $Item.Title, $res)
}
function Invoke-HistoryShow {
    Write-FixItLog 'Started: what did I fix'
    $h = @(Get-FixItHistory -Max 15)
    if ($h.Count -eq 0) { return New-FixItResult $true 'Nothing yet' 'This tool has not fixed anything on this computer yet. After you use one of the fix buttons, it will be listed here.' @() }
    $lines = @($h | ForEach-Object { Format-FixItHistoryLine $_ })
    $undo = ''
    try {
        $j = @(Read-FixItUndoJournal)
        $open = @($j | Where-Object { -not (Get-FixItProp $_ 'Undone' $false) })
        if ($open.Count -gt 0) { $undo = ("`r`n`r`nIf the newest fix made things worse, click 'Undo last fix' - it will put back: {0}." -f [string]$open[$open.Count - 1].Title) }
    } catch { }
    return New-FixItResult $true 'What I fixed' (('These are the last {0} fixes, newest first.' -f $h.Count) + $undo) $lines
}

# ---------------------------------------------------------------------------
# My files: find a file by name or see what was saved lately. Read-only.
# ---------------------------------------------------------------------------
$script:RiskyExtensions = @('.exe', '.msi', '.bat', '.cmd', '.ps1', '.psm1', '.vbs', '.vbe', '.js', '.jse', '.wsf', '.wsh', '.scr', '.com', '.pif', '.hta', '.lnk', '.reg', '.jar', '.cpl', '.dll')
$script:JunkFileNames = '^(desktop\.ini|thumbs\.db|\.ds_store)$|^~\$|\.tmp$'
function Get-FixItUserFolders {
    $list = @()
    foreach ($n in @('Desktop', 'MyDocuments', 'MyPictures')) {
        $p = ''; try { $p = [Environment]::GetFolderPath($n) } catch { }
        if ($p) { $label = $n; if ($n -eq 'MyDocuments') { $label = 'Documents' } elseif ($n -eq 'MyPictures') { $label = 'Pictures' }; $list += [pscustomobject]@{ Name = $label; Path = $p } }
    }
    $dl = ''; if ($env:USERPROFILE) { $dl = (Join-Path $env:USERPROFILE 'Downloads') }
    if ($dl) { $list += [pscustomobject]@{ Name = 'Downloads'; Path = $dl } }
    try {
        $od = Get-FixItOneDriveInfo
        if ($od) { foreach ($a in @($od.Accounts)) { if ($a.Folder) { $list += [pscustomobject]@{ Name = 'OneDrive'; Path = [string]$a.Folder } } } }
    } catch { }
    $seen = @{}; $out = @()
    foreach ($f in $list) { $k = ([string]$f.Path).TrimEnd('\', '/').ToLower(); if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $out += $f } }
    return $out
}
# ---- The file scan. It never touches the screen, so it can run in a background runspace (the window stays alive).
# It only LISTS names and dates (no file is opened or read), and it skips anything that could make Windows download or wait:
#   - reparse points (junctions, symbolic links, OneDrive placeholders that are links) - so loops and other drives are never followed
#   - cloud-only OneDrive files and folders (Offline / RecallOnOpen / RecallOnDataAccess) - looking inside would download them
# It stops by itself at a depth, folder, file and time limit, and when State.Cancel is set.
# $State is a synchronized hashtable: Cancel (in), Files, Folders, Skipped, Done, Reason, Log (out, read by the window).
$script:FileScanScript = {
    param([string[]]$Roots, [string]$Words, [string]$JunkPattern, [int]$Max, [int]$MaxDepth, [int]$MaxFolders, [int]$MaxFiles, [int]$MaxSeconds, $State)
    $skipDirBits = 0x400 -bor 0x1000 -bor 0x40000 -bor 0x400000      # ReparsePoint, Offline, RecallOnOpen, RecallOnDataAccess
    $skipFileBits = 0x400 -bor 0x1000 -bor 0x40000 -bor 0x400000
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $wordList = @(); foreach ($w in ($Words -split '\s+')) { if ($w) { $wordList += $w } }
    $cand = New-Object System.Collections.ArrayList
    $seen = @{}
    $State.Files = 0; $State.Folders = 0; $State.Skipped = 0; $State.Denied = 0; $State.Reason = ''
    $stack = New-Object System.Collections.Queue   # level by level, so every folder gets looked at near its top before any deep tree uses up the limits
    # a folder inside another listed folder (the OneDrive folder holds Desktop) is walked once
    $rootList = @(); foreach ($r in $Roots) { if ($r) { $rootList += ([string]$r).TrimEnd('\', '/') } }
    $keep = @()
    foreach ($r in $rootList) {
        $inside = $false
        foreach ($o in $rootList) { if ($o.ToLower() -ne $r.ToLower() -and ($r.StartsWith($o + '\', [StringComparison]::OrdinalIgnoreCase) -or $r.StartsWith($o + '/', [StringComparison]::OrdinalIgnoreCase))) { $inside = $true } }
        if (-not $inside) { $keep += $r }
    }
    $rootSeen = @{}
    foreach ($r in $keep) { $rk = $r.ToLower(); if (-not $rootSeen.ContainsKey($rk)) { $rootSeen[$rk] = $true; $stack.Enqueue(@($r, 0)) } }
    $stop = ''
    try {
        while ($stack.Count -gt 0 -and -not $stop) {
            $item = $stack.Dequeue(); $dir = [string]$item[0]; $depth = [int]$item[1]
            if ($State.Cancel) { $stop = 'cancelled'; break }
            if ($sw.Elapsed.TotalSeconds -gt $MaxSeconds) { $stop = 'time limit'; break }
            if ($State.Folders -ge $MaxFolders) { $stop = 'folder limit'; break }
            $State.Folders = $State.Folders + 1
            $State.Current = $dir
            $n = 0
            try {
                $di = New-Object System.IO.DirectoryInfo $dir
                foreach ($e in $di.EnumerateFileSystemInfos()) {
                    $n++
                    if (($n % 100) -eq 0) {
                        if ($State.Cancel) { $stop = 'cancelled'; break }
                        if ($sw.Elapsed.TotalSeconds -gt $MaxSeconds) { $stop = 'time limit'; break }
                    }
                    $attr = [int]$e.Attributes
                    if ($e -is [System.IO.DirectoryInfo]) {
                        if (($attr -band $skipDirBits) -ne 0 -or ($attr -band 0x4) -ne 0) { $State.Skipped = $State.Skipped + 1; continue }   # 0x4 = System
                        if ($depth + 1 -gt $MaxDepth) { continue }
                        $stack.Enqueue(@($e.FullName, ($depth + 1)))
                        continue
                    }
                    if (($attr -band $skipFileBits) -ne 0) { $State.Skipped = $State.Skipped + 1; continue }
                    $State.Files = $State.Files + 1
                    if ($State.Files -ge $MaxFiles) { $stop = 'file limit'; break }
                    $name = [string]$e.Name
                    if ($JunkPattern -and $name -match $JunkPattern) { continue }
                    $ok = $true
                    foreach ($w in $wordList) { if ($name.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $ok = $false; break } }
                    if (-not $ok) { continue }
                    $k = ([string]$e.FullName).ToLower()
                    if ($seen.ContainsKey($k)) { continue }
                    $seen[$k] = $true
                    [void]$cand.Add([pscustomobject]@{ Name = $name; FullName = [string]$e.FullName; Folder = [string]$e.DirectoryName; Modified = $e.LastWriteTime; KB = [math]::Round($e.Length / 1KB) })
                    if ($cand.Count -gt ($Max * 25 + 200)) {
                        $sorted = @($cand | Sort-Object Modified -Descending | Select-Object -First ($Max * 5))
                        $cand.Clear(); foreach ($c in $sorted) { [void]$cand.Add($c) }
                    }
                }
            } catch { $State.Denied = $State.Denied + 1 }
        }
    } catch { $stop = 'error: ' + $_.Exception.Message }
    $State.Reason = $stop
    $State.Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $State.Result = @($cand | Sort-Object Modified -Descending | Select-Object -First $Max)
    $State.Done = $true
}
$script:FileScanLimits = @{ Depth = 8; Folders = 4000; Files = 30000; Seconds = 15 }
function New-FixItFileScanState {
    return [hashtable]::Synchronized(@{ Cancel = $false; Done = $false; Files = 0; Folders = 0; Skipped = 0; Denied = 0; Reason = ''; Seconds = 0; Current = ''; Result = @() })
}
function Get-FixItFileScanArgs {
    param([string]$Query, [int]$Max, $State)
    $roots = @(Get-FixItUserFolders | ForEach-Object { [string]$_.Path })
    $L = $script:FileScanLimits
    return @{ Roots = $roots; Words = $Query; JunkPattern = $script:JunkFileNames; Max = $Max; MaxDepth = $L.Depth; MaxFolders = $L.Folders; MaxFiles = $L.Files; MaxSeconds = $L.Seconds; State = $State }
}
function Write-FixItFileScanSummary {
    param($State, [string]$Query)
    $why = ''; if ($State.Reason) { $why = (', stopped: {0}' -f $State.Reason) }
    $lvl = 'INFO'; if ($State.Reason -like 'error*') { $lvl = 'WARN' }
    Write-FixItLog ('My files: finished in {0}s: {1} files looked at, {2} folders, {3} skipped (cloud-only or links), {4} folders not readable, {5} match(es){6}' -f $State.Seconds, $State.Files, $State.Folders, $State.Skipped, $State.Denied, @($State.Result).Count, $why) $lvl
}
# Same scan, run to the end right here (command line, tests). The window uses Start-FixItFileSearch instead.
function Find-FixItFiles {
    param([string]$Query = '', [int]$Max = 8)
    $st = New-FixItFileScanState
    $a = Get-FixItFileScanArgs -Query $Query -Max $Max -State $st
    Write-FixItLog ('My files: looking in {0} folder(s) (search: "{1}")' -f @($a.Roots).Count, $Query)
    & $script:FileScanScript @a
    Write-FixItFileScanSummary -State $st -Query $Query
    return @($st.Result)
}
# ---- background version for the window: a runspace does the walking; the window polls it from a timer
function Start-FixItFileSearch {
    param([string]$Query = '', [int]$Max = 8)
    $st = New-FixItFileScanState
    $a = Get-FixItFileScanArgs -Query $Query -Max $Max -State $st
    Write-FixItLog ('My files: looking in the background in {0} folder(s) (search: "{1}"; limits: depth {2}, {3} folders, {4} files, {5} seconds)' -f @($a.Roots).Count, $Query, $a.MaxDepth, $a.MaxFolders, $a.MaxFiles, $a.MaxSeconds)
    $job = [pscustomobject]@{ State = $st; Query = $Query; PS = $null; Runspace = $null; Handle = $null; Started = (Get-Date); Abandoned = $false; LastLog = (Get-Date) }
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($script:FileScanScript.ToString())
        foreach ($k in $a.Keys) { [void]$ps.AddParameter($k, $a[$k]) }
        $job.PS = $ps; $job.Runspace = $rs
        $job.Handle = $ps.BeginInvoke()
    } catch {
        Write-FixItLog ('My files: could not start the background search: {0}' -f $_.Exception.Message) 'ERROR'
        $st.Reason = 'error: could not start'; $st.Done = $true
    }
    return $job
}
# Called by the window's timer. Returns 'Running' or 'Done'. Never blocks.
function Get-FixItFileSearchStatus {
    param($Job)
    $st = $Job.State
    if ($st.Done) { return 'Done' }
    $age = ((Get-Date) - $Job.Started).TotalSeconds
    if (((Get-Date) - $Job.LastLog).TotalSeconds -ge 5) { $Job.LastLog = Get-Date; Write-FixItLog ('My files: still looking ({0:N0}s): {1} files, {2} folders so far' -f $age, $st.Files, $st.Folders) }
    # a single stuck disk call cannot be interrupted: give up waiting (the window stays alive) and show what was found
    if ($age -gt ($script:FileScanLimits.Seconds + 10)) {
        Write-FixItLog ('My files: the background search did not finish in time; giving up on it ({0} files, {1} folders so far)' -f $st.Files, $st.Folders) 'WARN'
        $st.Cancel = $true; $st.Reason = 'did not finish'; $Job.Abandoned = $true
        try { if ($Job.PS) { [void]$Job.PS.BeginStop($null, $null) } } catch { }
        $st.Done = $true
    }
    if ($st.Done) { return 'Done' }
    return 'Running'
}
function Stop-FixItFileSearch {
    param($Job)
    if ($Job -and $Job.State) { $Job.State.Cancel = $true; Write-FixItLog 'My files: Cancel clicked' }
}
function Close-FixItFileSearch {
    param($Job)
    if (-not $Job) { return }
    if ($Job.Abandoned) { return }       # a stuck one is left to finish on its own; disposing it could freeze the window
    try { if ($Job.PS) { $Job.PS.Dispose() } } catch { }
    try { if ($Job.Runspace) { $Job.Runspace.Dispose() } } catch { }
}
function Test-FixItUserFilePath {
    param([string]$Path)
    if (-not $Path) { return $false }
    if ($Path -match '\.\.[\\/]') { return $false }
    foreach ($f in @(Get-FixItUserFolders)) {
        $root = ([string]$f.Path).TrimEnd('\', '/')
        if ($Path.Length -gt $root.Length -and $Path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($Path.Length -gt $root.Length -and $Path.StartsWith($root + '/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
function Open-FixItUserFile { param([string]$Path)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Open-FixItUserFile' -Arguments $PSBoundParameters; return }
 Start-Process -FilePath $Path | Out-Null }
function Show-FixItFileInFolder { param([string]$Path)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Show-FixItFileInFolder' -Arguments $PSBoundParameters; return }
 Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $Path) | Out-Null }
function Open-FixItFoundFile {
    param([string]$Path)
    if (-not (Test-FixItUserFilePath $Path)) { return New-FixItResult $false 'Cannot open that' 'I only open files from your Desktop, Documents, Downloads, Pictures and OneDrive folders.' }
    $ext = [IO.Path]::GetExtension($Path).ToLower()
    if ($script:RiskyExtensions -contains $ext) { return New-FixItResult $false 'Not opened' "That file is a program, not a document, so I will not run it. If you did not expect it, do not open it. I can show you where it is instead." }
    if (-not $script:DryRun -and -not (Test-Path -LiteralPath $Path)) { return New-FixItResult $false 'File not found' 'That file is not there any more.' }
    if (Invoke-FixItStep ('Open the file {0}' -f $Path) { Open-FixItUserFile -Path $Path }) { return New-FixItResult $true 'Opened' 'The file is opening now.' }
    return New-FixItResult $false 'Could not open it' 'The file would not open. Try "Show me where it is" and open it from there.'
}
function Show-FixItFoundFile {
    param([string]$Path)
    if (-not (Test-FixItUserFilePath $Path)) { return New-FixItResult $false 'Cannot show that' 'I only show files from your Desktop, Documents, Downloads, Pictures and OneDrive folders.' }
    if (-not $script:DryRun -and -not (Test-Path -LiteralPath $Path)) { return New-FixItResult $false 'File not found' 'That file is not there any more.' }
    if (Invoke-FixItStep ('Show where the file is: {0}' -f $Path) { Show-FixItFileInFolder -Path $Path }) { return New-FixItResult $true 'Showing it' 'A folder window opens with the file highlighted.' }
    return New-FixItResult $false 'Could not show it' 'Windows would not open the folder.'
}
# Command line / plain result: lists what was found (the window shows the same list with two buttons per file).
function Invoke-FilesHelper {
    param([string]$Search = '')
    $q = $Search; if (-not $q -and $script:Query) { $q = $script:Query }
    Write-FixItLog ('Started: my files (search: "{0}")' -f $q)
    $found = @(Find-FixItFiles -Query $q -Max 8)
    if ($found.Count -eq 0) {
        if ($q) { return New-FixItResult $true 'No files found' ('I did not find a file with "{0}" in its name in your Desktop, Documents, Downloads, Pictures or OneDrive folders. Try fewer or different words.' -f $q) @() }
        return New-FixItResult $true 'No files found' 'I did not find any files in your Desktop, Documents, Downloads, Pictures or OneDrive folders.' @()
    }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $lines = @($found | ForEach-Object { '{0}  -  saved {1}  -  in {2}' -f $_.Name, ([datetime]$_.Modified).ToString('ddd MMM d, h:mm tt', $inv), $_.Folder })
    $head = 'These files were saved most recently:'; if ($q) { $head = ('Files with "{0}" in the name (newest first):' -f $q) }
    return New-FixItResult $true 'Files found' $head $lines @{ Files = @($found | ForEach-Object { [string]$_.FullName }) }
}

# ---------------------------------------------------------------------------
# Install an app safely (only apps on Trey's approved list, through winget)
# ---------------------------------------------------------------------------
$script:DefaultApps = @(
    @{ id = 'Google.Chrome'; name = 'Google Chrome' },
    @{ id = 'Zoom.Zoom'; name = 'Zoom' },
    @{ id = 'Adobe.Acrobat.Reader.64-bit'; name = 'Adobe Acrobat Reader' },
    @{ id = 'VideoLAN.VLC'; name = 'VLC media player' })
function Test-FixItAppEntry {
    param($Id, $Name)
    return (([string]$Id) -match '^[A-Za-z0-9][A-Za-z0-9+_\-]*(\.[A-Za-z0-9+_\-]+)+$' -and ([string]$Id).Length -le 80 -and ([string]$Name) -match '^[A-Za-z0-9][A-Za-z0-9 .,+&()\-]{0,59}$')
}
function Get-FixItApprovedApps {
    $apps = @()
    $json = $null
    if ($script:ManifestUrl -and $script:ManifestUrl -match '^https://' -and -not $script:ManifestUrl.Contains($script:OwnerPlaceholder)) {
        try { $json = (Get-WebText -Url $script:ManifestUrl) | ConvertFrom-Json } catch { Write-FixItLog ('Could not read the approved app list online, using the built-in list: {0}' -f $_.Exception.Message) 'WARN' }
    }
    if ($json -and (Test-FixItHas $json 'apps')) {
        foreach ($a in @($json.apps | Select-Object -First 20)) {
            $id = Get-FixItProp $a 'id' ''; $nm = Get-FixItProp $a 'name' ''
            if (Test-FixItAppEntry $id $nm) { $apps += [pscustomobject]@{ Id = [string]$id; Name = [string]$nm } }
            else { Write-FixItLog ('Ignored an app list entry that looks wrong: {0}' -f $id) 'WARN' }
        }
        if ($apps.Count -gt 0) { return $apps }
    }
    foreach ($a in $script:DefaultApps) { $apps += [pscustomobject]@{ Id = $a.id; Name = $a.name } }
    return $apps
}
function Test-FixItWinget { return [bool](Get-Command 'winget.exe' -ErrorAction SilentlyContinue) }
function Test-FixItAppInstalled {
    param([string]$Id)
    $r = Invoke-FixItNative -File 'winget.exe' -Arguments @('list', '--id', $Id, '--exact', '--source', 'winget', '--accept-source-agreements')
    return ($r.ExitCode -eq 0 -and ([string]$r.Output) -match [regex]::Escape($Id))
}
function Install-FixItApp {
    param([string]$Id)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Install-FixItApp' -Arguments $PSBoundParameters; return 0 }
    $r = Invoke-FixItNative -File 'winget.exe' -Arguments @('install', '--id', $Id, '--exact', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements') -Live
    return $r.ExitCode
}
function Invoke-InstallApp {
    param([string]$AppName = '')
    $nm = $AppName; if (-not $nm -and $script:App) { $nm = $script:App }
    Write-FixItLog ('Started: install an app ({0})' -f $nm)
    $apps = @(Get-FixItApprovedApps)
    if (-not $nm) {
        return New-FixItResult $true 'Apps I can install' 'These are the apps Trey approved. Pick one in the window, or run again with -App and the name.' @($apps | ForEach-Object { $_.Name })
    }
    $app = @($apps | Where-Object { $_.Name -eq $nm -or $_.Id -eq $nm } | Select-Object -First 1)
    if ($app.Count -eq 0) { return New-FixItResult $false 'Not on the safe list' ('"{0}" is not on the list of apps Trey approved, so I did not install it. Ask Trey if you need it.' -f $nm) @($apps | ForEach-Object { $_.Name }) }
    $app = $app[0]
    if ($app.Id -notmatch '^[A-Za-z0-9][A-Za-z0-9+_\-]*(\.[A-Za-z0-9+_\-]+)+$') { return New-FixItResult $false 'Not installed' 'That entry on the app list looks wrong, so I did not install it. Please tell Trey.' }
    if (-not (Test-FixItWinget)) { return New-FixItResult $false 'Cannot install apps here' "This computer does not have Windows' app installer (winget). Ask Trey to install $($app.Name) for you." }
    $already = $false
    try { $already = Test-FixItAppInstalled -Id $app.Id } catch { Write-FixItLog ('Could not check if {0} is installed: {1}' -f $app.Name, $_.Exception.Message) 'WARN' }
    if ($already) { return New-FixItResult $true 'Already installed' ('{0} is already installed on this computer. Nothing was changed. Look for it in the Start menu.' -f $app.Name) }
    if (-not (Confirm-FixItStep ('Install {0}? It comes from Microsoft''s official app list (winget). Windows may ask for permission.' -f $app.Name))) { return New-FixItResult $true 'Not installed' ('OK, {0} was not installed.' -f $app.Name) }
    $code = 0
    $okRun = Invoke-FixItStep ('Install {0} with winget (id {1}, source winget)' -f $app.Name, $app.Id) { $script:__InstallCode = Install-FixItApp -Id $app.Id; if ($script:__InstallCode -ne 0 -and $script:__InstallCode -ne -1978335135) { throw ('winget finished with code {0}' -f $script:__InstallCode) } }
    if ($script:DryRun) { return New-FixItResult $true 'Practice run' 'Practice run only - nothing was installed. Details are in the log file.' }
    if ($okRun) { return New-FixItResult $true 'Installed' ('{0} is installed. Look for it in the Start menu.' -f $app.Name) }
    return New-FixItResult $false 'Could not install it' ('{0} could not be installed. Check your internet, then try again. If it still fails, click "Send Trey a report".' -f $app.Name)
}
# ---------------------------------------------------------------------------
# Guardian: quietly watches for a browser page that takes over the whole screen
# and offers a way out. Runs at sign-in (no administrator rights).
# ---------------------------------------------------------------------------
$script:GuardianRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:GuardianRunName = 'FamilyFixItGuardian'
$script:GuardianMutexName = 'Local\FamilyFixItGuardian'
$script:GuardianBrowsers = @('msedge', 'chrome', 'firefox', 'brave', 'opera', 'iexplore')
$script:GuardianPollMs = 1500
$script:GuardianQuietMinutes = 120   # after "I'm fine" (a long video should not ask again)
$script:GuardianLooksNeeded = 4        # looks in a row (1.5 s apart) a page must stay full screen before the box appears
$script:GuardianCalmSeconds = 120
$script:GuardianKeepBackups = 5
$script:GuardianCalm = "You're safe. Don't call any number that page showed. Trey has been told."
$script:GuardianRestoreAdvice = "When you open your browser again, do not click 'Restore' if it asks."
$script:GuardianHotkeyText = 'Ctrl + Shift + F'
$script:GState = $null
$script:GBusy = $false
$script:GT = $null
$script:GToastFg = $null
$script:GProcNames = @{}
$script:GLastDay = ''
$script:GLastErrLog = [datetime]::MinValue
$script:GNativeReady = $false

# ----- pure logic (tested) --------------------------------------------------
function Test-FixItBrowserName {
    param([string]$Name)
    if (-not $Name) { return $false }
    $n = ($Name.ToLowerInvariant()) -replace '\.exe$', ''
    return ($script:GuardianBrowsers -contains $n)
}

# True when the window covers its whole monitor (full screen or kiosk). An ordinary maximized window
# (it has a title bar and spills a few pixels past the screen edge) does not count.
function Test-FixItWindowFullscreen {
    param($Fg)
    if ($null -eq $Fg) { return $false }
    if (($Fg.MonRight - $Fg.MonLeft) -le 0 -or ($Fg.MonBottom - $Fg.MonTop) -le 0) { return $false }
    $tol = 1
    $covers = ($Fg.Left -le ($Fg.MonLeft + $tol)) -and ($Fg.Top -le ($Fg.MonTop + $tol)) -and ($Fg.Right -ge ($Fg.MonRight - $tol)) -and ($Fg.Bottom -ge ($Fg.MonBottom - $tol))
    if (-not $covers) { return $false }
    $over = ($Fg.Left -lt $Fg.MonLeft) -or ($Fg.Top -lt $Fg.MonTop) -or ($Fg.Right -gt $Fg.MonRight) -or ($Fg.Bottom -gt $Fg.MonBottom)
    if ([bool]$Fg.IsZoomed -and [bool]$Fg.HasCaption -and $over) { return $false }
    return $true
}

function New-FixItGuardianState {
    return @{ Candidate = ''; Streak = 0; ToastOpen = $false; ToastMode = ''; ToastHandle = ''; CalmSince = [datetime]::MinValue; Dismissed = @{}; ProcQuiet = @{} }
}

# Decides what to do after one look at the foreground window: 'Show', 'Hide' or 'None'.
# A page must stay full screen for several looks in a row (see GuardianLooksNeeded) before the question appears.
function Get-FixItGuardianDecision {
    param($Fg, $State, [datetime]$Now)
    $full = ($null -ne $Fg) -and (Test-FixItBrowserName $Fg.ProcessName) -and (Test-FixItWindowFullscreen $Fg)
    if ($State.ToastOpen) {
        if ($State.ToastMode -eq 'Calm') {
            if (($Now - $State.CalmSince).TotalSeconds -ge $script:GuardianCalmSeconds) { $State.ToastOpen = $false; return 'Hide' }
            return 'None'
        }
        if (-not $full) { $State.ToastOpen = $false; $State.Streak = 0; $State.Candidate = ''; return 'Hide' }
        return 'None'
    }
    if (-not $full) { $State.Streak = 0; $State.Candidate = ''; return 'None' }
    $h = [string]$Fg.Handle
    if ($State.Dismissed.ContainsKey($h)) { return 'None' }
    $q = $null
    if ($State.ProcQuiet.ContainsKey([string]$Fg.ProcessName)) { $q = [datetime]$State.ProcQuiet[[string]$Fg.ProcessName] }
    if ($null -ne $q -and $Now -lt $q) { return 'None' }
    if ($State.Candidate -ne $h) { $State.Candidate = $h; $State.Streak = 1; return 'None' }
    $State.Streak = [int]$State.Streak + 1
    if ($State.Streak -lt $script:GuardianLooksNeeded) { return 'None' }
    $State.ToastOpen = $true; $State.ToastMode = 'Ask'; $State.ToastHandle = $h
    return 'Show'
}

# "I'm fine": never ask again about this window, and stay quiet about this browser for a while (e.g. a video).
function Set-FixItGuardianFine {
    param($Fg, $State, [datetime]$Now)
    if ($null -ne $Fg) {
        $State.Dismissed[[string]$Fg.Handle] = $true
        $State.ProcQuiet[[string]$Fg.ProcessName] = $Now.AddMinutes($script:GuardianQuietMinutes)
        if ($State.Dismissed.Count -gt 200) { $State.Dismissed = @{ ([string]$Fg.Handle) = $true } }
    }
    $State.ToastOpen = $false
}

# Picks out the parts of a browser's command line that matter for a scam report (web address, kiosk/app mode).
function Get-FixItBrowserFlags {
    param([string]$CommandLine)
    $out = @()
    if (-not $CommandLine) { return $out }
    foreach ($m in [regex]::Matches($CommandLine, '"[^"]*"|\S+')) {
        $t = $m.Value.Trim('"')
        if ($t -match '^(https?://|--app=|--kiosk|--start-fullscreen|--new-window|--incognito|--inprivate|--no-first-run)') {
            if ($t.Length -gt 400) { $t = $t.Substring(0, 400) + '...' }
            $out += $t
        }
    }
    return $out
}

function Get-FixItGuardianDetails {
    param($Fg)
    $d = [ordered]@{ Browser = ''; ProcessId = 0; Title = ''; Url = ''; Flags = @() }
    if ($null -ne $Fg -and (Test-FixItBrowserName $Fg.ProcessName)) {
        $d.Browser = [string]$Fg.ProcessName
        $d.ProcessId = [int]$Fg.ProcessId
        $d.Title = [string]$Fg.Title
        try { $d.Url = [string](Get-FixItBrowserUrl -Handle $Fg.Handle) } catch { Write-FixItLog ('Could not read the page address: {0}' -f $_.Exception.Message) 'WARN' }
        try { $d.Flags = @(Get-FixItBrowserFlags -CommandLine ([string](Get-FixItProcessCommandLine -Id $Fg.ProcessId))) } catch { }
    }
    return [pscustomobject]$d
}

function Get-FixItGuardianNote {
    param($Details, [string]$Reason, [int]$Closed, [string[]]$ClosedNames = @(), [string]$SessionNote = '')
    $why = 'a browser page took over the whole screen and the person clicked "Get me out of here"'
    if ($Reason -eq 'hotkey') { $why = 'the person pressed Ctrl+Shift+F (the panic key)' }
    $o = @()
    $o += ('GUARDIAN: ' + $why + '.')
    if ($Details.Browser) { $o += ('Browser in front: {0} (process {1})' -f $Details.Browser, $Details.ProcessId) } else { $o += 'Browser in front: none was in front' }
    if ($Details.Title) { $o += ('Window title: ' + $Details.Title) }
    if ($Details.Url) { $o += ('Page address: ' + $Details.Url) } else { $o += 'Page address: not available (the address bar is hidden in full screen)' }
    foreach ($f in @($Details.Flags)) { $o += ('Browser was started with: ' + $f) }
    $o += ('Browser programs closed: {0}{1}' -f $Closed, $(if ($ClosedNames.Count -gt 0) { ' (' + (($ClosedNames | Sort-Object -Unique) -join ', ') + ')' } else { '' }))
    if ($SessionNote) { $o += $SessionNote }
    $o += 'Recent downloads and installed programs are listed below.'
    return ($o -join "`r`n")
}

# ----- closing the browsers and clearing "restore pages" -------------------
function Close-FixItBrowsers {
    $procs = @(Get-FixItBrowserProcesses)
    $names = @($procs | ForEach-Object { [string]$_.Name })
    if ($script:DryRun) {
        Write-FixItLog ('Would do: close {0} browser program(s)' -f $procs.Count) 'DRYRUN'
        if ($script:TestMode) { foreach ($bp in $procs) { $bid = [int]$bp.Id; [void](Invoke-FixItStep ('Close the browser program {0} (process {1})' -f $bp.Name, $bid) { Stop-FixItProcessForce -Id $bid }) } }
        return [pscustomobject]@{ Count = $procs.Count; Names = $names; Failed = 0 }
    }
    $failed = 0
    foreach ($p in $procs) {
        try { Stop-FixItProcessForce -Id ([int]$p.Id) } catch { $failed++; Write-FixItLog ('Could not close {0} ({1}): {2}' -f $p.Name, $p.Id, $_.Exception.Message) 'WARN' }
    }
    if ($procs.Count -gt 0) { Wait-FixItProcessesGone -Ids @($procs | ForEach-Object { [int]$_.Id }) -Seconds 4 }
    Write-FixItLog ('Closed {0} browser program(s): {1}' -f ($procs.Count - $failed), (($names | Sort-Object -Unique) -join ', ')) 'WARN'
    return [pscustomobject]@{ Count = ($procs.Count - $failed); Names = $names; Failed = $failed }
}

function Get-FixItGuardianBackupRoot { return (Join-Path (Split-Path -Parent (Get-FixItStateFile)) 'guardian-backup') }

# Moves the browsers' "last session" files aside (backed up first) and marks Edge/Chrome/Brave as closed normally,
# so the browser does not offer to bring the scary page back. Nothing is deleted except backups older than the newest 5.
function Clear-FixItBrowserSessions {
    param([string]$BackupRoot = '')
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Clear-FixItBrowserSessions' -Arguments $PSBoundParameters; return [pscustomobject]@{ Moved = 0; Patched = 0; Failed = 0; Backup = '' } }
    if (-not $BackupRoot) { $BackupRoot = Get-FixItGuardianBackupRoot }
    $targets = @(Get-FixItSessionTargets)
    $res = [pscustomobject]@{ Moved = 0; Patched = 0; Failed = 0; Backup = '' }
    if ($targets.Count -eq 0) { Write-FixItLog 'No browser session files were found'; return $res }
    if ($script:DryRun) {
        Write-FixItLog ('Would do: back up and move aside {0} browser session file(s) in {1}' -f $targets.Count, $BackupRoot) 'DRYRUN'
        return $res
    }
    $dest = Join-Path $BackupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
    $res.Backup = $dest
    foreach ($t in $targets) {
        try {
            $sub = Join-Path $dest ('{0}-{1}' -f $t.Browser, ($t.Profile -replace '[^A-Za-z0-9_-]', '_'))
            if (-not (Test-Path -LiteralPath $sub)) { New-Item -ItemType Directory -Path $sub -Force | Out-Null }
            if ($t.Action -eq 'prefs') {
                Copy-Item -LiteralPath $t.Path -Destination (Join-Path $sub 'Preferences') -Force -ErrorAction Stop
                $txt = [IO.File]::ReadAllText($t.Path)
                $new = $txt -replace '"exit_type"\s*:\s*"[^"]*"', '"exit_type":"Normal"' -replace '"exited_cleanly"\s*:\s*false', '"exited_cleanly":true'
                if ($new -ne $txt) { [IO.File]::WriteAllText($t.Path, $new, (New-Object Text.UTF8Encoding($false))); $res.Patched++ }
            } else {
                $leaf = Split-Path -Leaf $t.Path
                $target = Join-Path $sub $leaf
                if (Test-Path -LiteralPath $target) { $target = Join-Path $sub ('{0}-{1}' -f [guid]::NewGuid().ToString('N').Substring(0, 6), $leaf) }
                Move-Item -LiteralPath $t.Path -Destination $target -Force -ErrorAction Stop
                $res.Moved++
            }
        } catch { $res.Failed++; Write-FixItLog ('Could not clear a session file ({0}): {1}' -f $t.Path, $_.Exception.Message) 'WARN' }
    }
    try {
        $old = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -Skip $script:GuardianKeepBackups)
        foreach ($o in $old) { Remove-Item -LiteralPath $o.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { }
    Write-FixItLog ('Browser sessions: {0} file(s) moved aside, {1} preferences file(s) marked as closed normally, {2} problem(s). Backup: {3}' -f $res.Moved, $res.Patched, $res.Failed, $dest)
    return $res
}

# Phase 1 of "Get me out of here": note what is on screen, close the browsers, clear session restore.
function Invoke-GuardianClose {
    param($Fg = $null, [string]$Reason = 'button', [switch]$Demo)
    Write-FixItLog ('Guardian: get me out ({0}){1}' -f $Reason, $(if ($Demo) { ' [demo - nothing is closed]' } else { '' })) 'WARN'
    $details = Get-FixItGuardianDetails -Fg $Fg
    $closed = [pscustomobject]@{ Count = 0; Names = @(); Failed = 0 }
    $sess = [pscustomobject]@{ Moved = 0; Patched = 0; Failed = 0; Backup = '' }
    if (-not $Demo) {
        try { $closed = Close-FixItBrowsers } catch { Write-FixItLog ('Closing browsers failed: {0}' -f $_.Exception.Message) 'ERROR' }
        try {
            if ($script:TestMode) { [void](Invoke-FixItStep 'Back up and move aside the browsers saved-pages files' { [void](Clear-FixItBrowserSessions) }) }
            else { $sess = Clear-FixItBrowserSessions }
        } catch { Write-FixItLog ('Clearing sessions failed: {0}' -f $_.Exception.Message) 'ERROR' }
    }
    return [pscustomobject]@{ Details = $details; Closed = $closed; Sessions = $sess; Reason = $Reason; Demo = [bool]$Demo }
}

# Phase 2: tell Trey (a SCAM alert report). A copy goes on the Desktop only if sending fails.
function Invoke-GuardianAlert {
    param($Close)
    $sn = ''
    if ($Close.Sessions.Backup -and ($Close.Sessions.Moved -gt 0 -or $Close.Sessions.Patched -gt 0)) {
        $sn = ('Session restore cleared; backup in {0}' -f $Close.Sessions.Backup)
    }
    $note = Get-FixItGuardianNote -Details $Close.Details -Reason $Close.Reason -Closed ([int]$Close.Closed.Count) -ClosedNames @($Close.Closed.Names) -SessionNote $sn
    if ($Close.Demo) {
        Write-FixItLog 'Guardian demo: no report is sent'
        return New-FixItResult $true 'Practice' ('(Practice only - nothing was closed and nothing was sent.) ' + $script:GuardianCalm) @() @{ Sent = $false; Demo = $true; Note = $note }
    }
    $text = ''
    try { $text = Get-FixItReportText -Kind 'scam' -Note $note } catch {
        Write-FixItLog ('Guardian report could not be fully built: {0}' -f $_.Exception.Message) 'ERROR'
        $text = "SCAM ALERT (Guardian). The full report could not be built: " + $_.Exception.Message + "`r`n`r`n" + $note
    }
    $sent = [bool](Send-FixItReport -Text $text -Kind 'scam')
    $path = ''
    if (-not $sent -and -not $script:DryRun) { $f = Save-FixItReportFile -Text $text -Prefix 'SCAM-Report-for-Trey'; $path = $f.Path }
    $msg = $script:GuardianCalm
    if ($script:DryRun) { $msg = 'Practice run: ' + $script:GuardianCalm }
    elseif (-not $sent) { $msg = "You're safe. Don't call any number that page showed. I could not reach Trey, so please call him." }
    Write-FixItLog ('Guardian: finished (report sent: {0})' -f $sent) 'WARN'
    return New-FixItResult $true 'You are safe' $msg @() @{ Sent = $sent; ReportPath = $path; Demo = $false; Note = $note }
}

# Both phases in a row (command line, tests).
function Invoke-GuardianGetOut {
    param($Fg = $null, [string]$Reason = 'button', [switch]$Demo)
    $c = Invoke-GuardianClose -Fg $Fg -Reason $Reason -Demo:$Demo
    return (Invoke-GuardianAlert -Close $c)
}

# ----- the toast: what the person sees ------------------------------------
# Runs the "Get me out" flow with live updates in the toast.
function Start-GuardianGetOutUi {
    param($Fg = $null, [string]$Reason = 'button', [switch]$Demo)
    if ($script:GBusy) { return }
    $script:GBusy = $true
    try {
        if ($null -ne $script:GState) { $script:GState.ToastOpen = $true; $script:GState.ToastMode = 'Calm'; $script:GState.CalmSince = (Get-Date) }
        Set-FixItGuardianToast -Fg $Fg -Mode 'Calm' -Text 'Closing the page...' -Status '' -Done $false
        $c = Invoke-GuardianClose -Fg $Fg -Reason $Reason -Demo:$Demo
        $base = $script:GuardianCalm
        if ($Demo) { $base = '(Practice only - nothing was closed.) ' + $base }
        Set-FixItGuardianToast -Fg $Fg -Mode 'Calm' -Text ($base + "`r`n`r`n" + $script:GuardianRestoreAdvice) -Status 'Telling Trey...' -Done $false
        $r = Invoke-GuardianAlert -Close $c
        $status = 'Trey has been told.'
        if ($Demo) { $status = '(Practice: nothing was sent.)' } elseif (-not [bool]$r.Sent) { $status = 'I could not reach Trey. Please call him.' }
        $text = [string]$r.Message
        if (-not $Demo) { $text = $text + "`r`n`r`n" + $script:GuardianRestoreAdvice }
        if ($null -ne $script:GState) { $script:GState.CalmSince = (Get-Date) }
        Set-FixItGuardianToast -Fg $Fg -Mode 'Calm' -Text $text -Status $status -Done $true
    } catch {
        Write-FixItLog ('Guardian get-out failed: {0}' -f $_.Exception.Message) 'ERROR'
        try { Set-FixItGuardianToast -Fg $Fg -Mode 'Calm' -Text "You're safe. Don't call any number that page showed. Please call Trey." -Status '' -Done $true } catch { }
    } finally { $script:GBusy = $false }
}

function Invoke-GuardianHotkey {
    if ($script:GBusy) { return }
    $fg = $null
    try { $fg = Get-FixItForeground } catch { }
    Write-FixItLog 'Guardian: Ctrl+Shift+F pressed' 'WARN'
    Start-GuardianGetOutUi -Fg $fg -Reason 'hotkey'
}

function Invoke-GuardianFineClick {
    if ($null -ne $script:GState) { Set-FixItGuardianFine -Fg $script:GToastFg -State $script:GState -Now (Get-Date) }
    Write-FixItLog ("Guardian: 'I'm fine' clicked (quiet for {0} minutes for this browser)" -f $script:GuardianQuietMinutes)
    Close-FixItGuardianToast
}

function Invoke-GuardianTick {
    try {
        $now = Get-Date
        $day = $now.ToString('yyyy-MM-dd')
        if ($script:GLastDay -ne $day) { if ($script:GLastDay) { Initialize-FixItLog }; $script:GLastDay = $day }
        if ($script:GBusy) { Update-FixItGuardianTopMost; return }
        $fg = Get-FixItForeground
        $d = Get-FixItGuardianDecision -Fg $fg -State $script:GState -Now $now
        if ($d -eq 'Show') {
            Write-FixItLog ('Guardian: a full-screen {0} page was found. Title: {1}' -f $fg.ProcessName, $fg.Title) 'WARN'
            Show-FixItGuardianToast -Fg $fg
        } elseif ($d -eq 'Hide') {
            Close-FixItGuardianToast
        }
        if ($script:GState.ToastOpen) { Update-FixItGuardianTopMost }
    } catch {
        if (((Get-Date) - $script:GLastErrLog).TotalSeconds -ge 60) {
            $script:GLastErrLog = Get-Date
            Write-FixItLog ('Guardian check failed: {0}' -f $_.Exception.Message) 'WARN'
        }
    }
}

function Invoke-GuardianRun {
    if ($script:DryRun) {
        Write-FixItLog ('Would do: watch the front window every {0} seconds, and register the {1} key' -f ($script:GuardianPollMs / 1000), $script:GuardianHotkeyText) 'DRYRUN'
        return New-FixItResult $true 'Practice run' ('Practice run only - the watcher would check the front window about every {0} seconds and listen for {1}.' -f ($script:GuardianPollMs / 1000), $script:GuardianHotkeyText)
    }
    $mutex = Enter-FixItGuardianMutex
    if ($null -eq $mutex) { Write-FixItLog 'Guardian is already running; this copy will stop'; return New-FixItResult $true 'Already running' 'The watcher is already running.' }
    $hk = $null
    try {
        Initialize-FixItGuardianNative
        $script:GState = New-FixItGuardianState
        $script:GLastDay = (Get-Date).ToString('yyyy-MM-dd')
        try { $hk = New-FixItGuardianHotkey } catch { Write-FixItLog ('Hotkey setup failed: {0}' -f $_.Exception.Message) 'WARN' }
        Write-FixItLog ('Guardian started (version {0}); hotkey {1}' -f $script:FixItVersion, $(if ($hk) { 'ready' } else { 'NOT available' }))
        Start-FixItGuardianLoop
    } finally {
        if ($hk) { try { $hk.Dispose() } catch { } }
        Release-FixItGuardianMutex $mutex
        Write-FixItLog 'Guardian stopped'
    }
    return New-FixItResult $true 'Stopped' 'The watcher stopped.'
}

# Shows the question right away (no full-screen page needed) so Trey can see how it looks. Nothing is closed or sent.
function Invoke-GuardianDemo {
    if ($script:DryRun) { Write-FixItLog 'Would do: show the demo question box' 'DRYRUN'; return New-FixItResult $true 'Practice run' 'Practice run only - the demo box would be shown.' }
    Initialize-FixItGuardianNative
    $script:GState = New-FixItGuardianState
    $script:GDemo = $true
    Show-FixItGuardianToast -Fg $null
    Wait-FixItGuardianToastClosed
    return New-FixItResult $true 'Demo finished' 'Demo finished. Nothing was closed and nothing was sent.'
}
$script:GDemo = $false

# ----- turning it on and off (Run key for this user; no administrator) ----
function Get-FixItGuardianCommand {
    return ('powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action Guardian' -f $script:SelfPath)
}
function Get-FixItGuardianRunValue {
    try { $v = Get-RegValue -Path $script:GuardianRunKey -Name $script:GuardianRunName; if ($null -eq $v) { return '' }; return [string]$v } catch { return '' }
}
function Test-FixItGuardianInstalled { return ([string](Get-FixItGuardianRunValue) -ne '') }

function Invoke-GuardianToggle {
    param([ValidateSet('Toggle', 'On', 'Off')][string]$Mode = 'Toggle')
    Write-FixItLog ('Started: scary pop-up watcher ({0})' -f $Mode)
    $on = Test-FixItGuardianInstalled
    $wantOn = (-not $on)
    if ($Mode -eq 'On') { $wantOn = $true } elseif ($Mode -eq 'Off') { $wantOn = $false }
    if ($wantOn) {
        if (-not $script:SelfPath) { return New-FixItResult $false 'Could not turn it on' 'The tool path is not known, so the watcher could not be set up.' }
        $cmd = Get-FixItGuardianCommand
        if (-not (Invoke-FixItStep 'Start the pop-up watcher when you sign in (a startup entry for this user only)' { Set-RegString -Path $script:GuardianRunKey -Name $script:GuardianRunName -Value $cmd })) {
            return New-FixItResult $false 'Could not turn it on' 'The pop-up watcher could not be set up.'
        }
        [void](Invoke-FixItStep 'Start the pop-up watcher now' { if (-not (Test-FixItGuardianRunning)) { Start-FixItGuardianProcess } })
        Set-FixItSetting -Name 'Guardian' -Value '1'
        if ($script:DryRun) { return New-FixItResult $true 'Practice run' 'Practice run only - the pop-up watcher would be turned on.' }
        return New-FixItResult $true 'Pop-up watcher is on' ("I'll quietly watch for a web page that takes over your whole screen. If that happens, a small box appears in the bottom right corner asking if you are OK.`r`n`r`nYou can also press " + $script:GuardianHotkeyText + ' at any time to close your browser and tell Trey.')
    }
    if ($Mode -eq 'Toggle' -and $on) {
        if (-not (Confirm-FixItStep "Turn off the scary pop-up watcher?`r`n`r`nIf a page takes over your screen again, I won't notice. (The red 'I see a scary pop-up' button still works.)")) {
            return New-FixItResult $true 'Still on' 'OK, the pop-up watcher stays on.'
        }
    }
    $ok = $true
    if ($on) {
        $ok = Invoke-FixItStep 'Remove the pop-up watcher startup entry' { Remove-RegValue -Path $script:GuardianRunKey -Name $script:GuardianRunName }
    } else { Write-FixItLog 'The pop-up watcher startup entry was already off' }
    [void](Invoke-FixItStep 'Stop the pop-up watcher that is running now' { Stop-FixItGuardianProcess })
    Set-FixItSetting -Name 'Guardian' -Value '0'
    if (-not $ok) { return New-FixItResult $false 'Could not turn it off' 'The pop-up watcher could not be turned off.' }
    if ($script:DryRun) { return New-FixItResult $true 'Practice run' 'Practice run only - the pop-up watcher would be turned off.' }
    return New-FixItResult $true 'Pop-up watcher is off' "I won't watch for full-screen pages any more. The red 'I see a scary pop-up' button still works."
}

# On by default: the first time the window opens it is switched on; if the person turned it off it stays off.
function Initialize-FixItGuardianDefault {
    if ($script:DryRun) { return }
    $s = Get-FixItSetting -Name 'Guardian' -Default ''
    if ($s -eq '0') { return }
    if ($s -eq '' -or -not (Test-FixItGuardianInstalled)) { [void](Invoke-GuardianToggle -Mode 'On'); return }
    if (-not (Test-FixItGuardianRunning)) { try { Start-FixItGuardianProcess } catch { Write-FixItLog ('Could not start the watcher: {0}' -f $_.Exception.Message) 'WARN' } }
}

function Get-FixItIdleStatus {
    $on = $false
    try { $on = Test-FixItGuardianInstalled } catch { }
    if ($on) { return ('Stuck on a scary full-screen page? Press ' + $script:GuardianHotkeyText + '.') }
    return 'Click a button above.'
}

# ----- Windows adapters (replaced by pretend versions in the tests) -------
$script:GuardianProbeCs = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace FixItGuard {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public int dwFlags; }
    public class Probe {
        public long Handle; public int ProcessId; public string Title;
        public int Left; public int Top; public int Right; public int Bottom;
        public int MonLeft; public int MonTop; public int MonRight; public int MonBottom;
        public bool IsZoomed; public bool HasCaption;
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
        [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern int GetWindowLongNative(IntPtr h, int idx);
        [DllImport("user32.dll", EntryPoint = "IsZoomed")] static extern bool IsZoomedNative(IntPtr h);
        [DllImport("user32.dll", EntryPoint = "GetWindowTextW", CharSet = CharSet.Unicode)] static extern int GetWindowTextNative(IntPtr h, StringBuilder sb, int max);
        public static Probe Read() {
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero) { return null; }
            RECT r;
            if (!GetWindowRect(h, out r)) { return null; }
            IntPtr mon = MonitorFromWindow(h, 2);
            MONITORINFO mi = new MONITORINFO();
            mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
            if (mon == IntPtr.Zero) { return null; }
            if (!GetMonitorInfo(mon, ref mi)) { return null; }
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            StringBuilder sb = new StringBuilder(512);
            GetWindowTextNative(h, sb, 512);
            Probe p = new Probe();
            p.Handle = h.ToInt64(); p.ProcessId = (int)pid; p.Title = sb.ToString();
            p.Left = r.Left; p.Top = r.Top; p.Right = r.Right; p.Bottom = r.Bottom;
            p.MonLeft = mi.rcMonitor.Left; p.MonTop = mi.rcMonitor.Top; p.MonRight = mi.rcMonitor.Right; p.MonBottom = mi.rcMonitor.Bottom;
            p.IsZoomed = IsZoomedNative(h);
            p.HasCaption = ((GetWindowLongNative(h, -16) & 0x00C00000) == 0x00C00000);
            return p;
        }
    }
}
'@

$script:GuardianUiCs = @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
namespace FixItGuard {
    public class HotkeyWindow : NativeWindow, IDisposable {
        [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
        [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
        public event EventHandler Pressed;
        public bool Registered;
        public HotkeyWindow() {
            CreateParams cp = new CreateParams();
            cp.Parent = (IntPtr)(-3);
            CreateHandle(cp);
        }
        public bool Register(uint mod, uint vk) { Registered = RegisterHotKey(this.Handle, 1, mod, vk); return Registered; }
        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x0312) { EventHandler h = Pressed; if (h != null) { h(this, EventArgs.Empty); } }
            base.WndProc(ref m);
        }
        public void Dispose() {
            if (this.Handle != IntPtr.Zero) { UnregisterHotKey(this.Handle, 1); this.DestroyHandle(); }
        }
    }
    public class ToastForm : Form {
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams {
            get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x08000000 | 0x00000080 | 0x00000008; return cp; }
        }
        public void ReassertTopMost() { SetWindowPos(this.Handle, (IntPtr)(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010 | 0x0040); }
    }
}
'@

function Initialize-FixItGuardianNative {
    if ($script:GNativeReady) { return }
    try {
        Add-Type -Namespace FixIt -Name Dpi -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -ErrorAction SilentlyContinue
        [void][FixIt.Dpi]::SetProcessDPIAware()
    } catch { }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if (-not ('FixItGuard.Probe' -as [type])) { Add-Type -TypeDefinition $script:GuardianProbeCs -ErrorAction Stop }
    if (-not ('FixItGuard.ToastForm' -as [type])) { Add-Type -TypeDefinition $script:GuardianUiCs -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing') -ErrorAction Stop }
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $script:GNativeReady = $true
}

# One quick look at the front window (a handful of cheap user32 calls). The process name is remembered per process id.
function Get-FixItForeground {
    $p = [FixItGuard.Probe]::Read()
    if ($null -eq $p) { return $null }
    $key = [string]$p.ProcessId
    $name = ''
    $now = Get-Date
    if ($script:GProcNames.ContainsKey($key) -and ($now - $script:GProcNames[$key].At).TotalSeconds -lt 60) { $name = $script:GProcNames[$key].Name }
    else {
        try { $name = [string](Get-Process -Id $p.ProcessId -ErrorAction Stop).ProcessName } catch { $name = '' }
        if ($script:GProcNames.Count -gt 100) { $script:GProcNames = @{} }
        $script:GProcNames[$key] = @{ Name = $name; At = $now }
    }
    return [pscustomobject]@{
        Handle = [int64]$p.Handle; ProcessId = [int]$p.ProcessId; ProcessName = $name; Title = [string]$p.Title
        Left = $p.Left; Top = $p.Top; Right = $p.Right; Bottom = $p.Bottom
        MonLeft = $p.MonLeft; MonTop = $p.MonTop; MonRight = $p.MonRight; MonBottom = $p.MonBottom
        IsZoomed = [bool]$p.IsZoomed; HasCaption = [bool]$p.HasCaption
    }
}

function Get-FixItBrowserProcesses {
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { Test-FixItBrowserName $_.ProcessName } | ForEach-Object { [pscustomobject]@{ Name = [string]$_.ProcessName; Id = [int]$_.Id } })
}
function Stop-FixItProcessForce { param([int]$Id)
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Stop-FixItProcessForce' -Arguments $PSBoundParameters; return }
 Stop-Process -Id $Id -Force -ErrorAction Stop }
function Wait-FixItProcessesGone {
    param([int[]]$Ids, [int]$Seconds = 4)
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        $left = @($Ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($left.Count -eq 0) { return }
        Wait-FixIt -Milliseconds 200
    }
}
function Get-FixItProcessCommandLine {
    param([int]$Id)
    $p = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId={0}' -f $Id) -ErrorAction Stop
    if ($p) { return [string]$p.CommandLine }
    return ''
}

# Best effort: reads the address bar with Windows' accessibility interface. It often is not available in full screen.
# It runs with a time limit so a stuck page can never freeze the watcher.
function Get-FixItBrowserUrl {
    param([int64]$Handle)
    $ps = [powershell]::Create()
    try {
        [void]$ps.AddScript({
            param($h)
            Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
            $el = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$h)
            $cond = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Edit)
            foreach ($e in $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
                $n = [string]$e.Current.Name
                if ($n -match 'address|search or enter') {
                    $vp = $null
                    if ($e.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) { return [string]$vp.Current.Value }
                }
            }
            return ''
        }).AddArgument($Handle)
        $ar = $ps.BeginInvoke()
        if ($ar.AsyncWaitHandle.WaitOne(4000)) {
            $out = @($ps.EndInvoke($ar))
            if ($out.Count -gt 0) { $u = [string]$out[0]; if ($u.Length -gt 500) { $u = $u.Substring(0, 500) }; return $u }
            return ''
        }
        Write-FixItLog 'Reading the page address took too long, so it was skipped' 'WARN'
        return ''
    } finally { try { $ps.Dispose() } catch { } }
}

# Every file that could bring the scary page back: Edge/Chrome/Brave session files and Preferences, Firefox session store.
function Get-FixItSessionTargets {
    $out = @()
    $local = $env:LOCALAPPDATA
    if ($local) {
        foreach ($b in @(@{ N = 'Edge'; P = 'Microsoft\Edge\User Data' }, @{ N = 'Chrome'; P = 'Google\Chrome\User Data' }, @{ N = 'Brave'; P = 'BraveSoftware\Brave-Browser\User Data' })) {
            $root = Join-Path $local $b.P
            if (-not (Test-Path -LiteralPath $root)) { continue }
            foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
                $prefs = Join-Path $d.FullName 'Preferences'
                if (Test-Path -LiteralPath $prefs) { $out += [pscustomobject]@{ Browser = $b.N; Profile = $d.Name; Path = $prefs; Action = 'prefs' } }
                $sd = Join-Path $d.FullName 'Sessions'
                if (Test-Path -LiteralPath $sd) {
                    foreach ($f in @(Get-ChildItem -LiteralPath $sd -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Session_*' -or $_.Name -like 'Tabs_*' })) {
                        $out += [pscustomobject]@{ Browser = $b.N; Profile = $d.Name; Path = $f.FullName; Action = 'move' }
                    }
                }
                foreach ($n in @('Current Session', 'Current Tabs', 'Last Session', 'Last Tabs')) {
                    $f = Join-Path $d.FullName $n
                    if (Test-Path -LiteralPath $f) { $out += [pscustomobject]@{ Browser = $b.N; Profile = $d.Name; Path = $f; Action = 'move' } }
                }
            }
        }
    }
    $app = $env:APPDATA
    if ($app) {
        $fx = Join-Path $app 'Mozilla\Firefox\Profiles'
        if (Test-Path -LiteralPath $fx) {
            foreach ($d in @(Get-ChildItem -LiteralPath $fx -Directory -ErrorAction SilentlyContinue)) {
                $sb = Join-Path $d.FullName 'sessionstore-backups'
                if (Test-Path -LiteralPath $sb) {
                    foreach ($f in @(Get-ChildItem -LiteralPath $sb -File -ErrorAction SilentlyContinue)) { $out += [pscustomobject]@{ Browser = 'Firefox'; Profile = $d.Name; Path = $f.FullName; Action = 'move' } }
                }
                $one = Join-Path $d.FullName 'sessionstore.jsonlz4'
                if (Test-Path -LiteralPath $one) { $out += [pscustomobject]@{ Browser = 'Firefox'; Profile = $d.Name; Path = $one; Action = 'move' } }
            }
        }
    }
    return $out
}

function Enter-FixItGuardianMutex {
    $created = $false
    $m = New-Object System.Threading.Mutex($true, $script:GuardianMutexName, [ref]$created)
    if (-not $created) { $m.Dispose(); return $null }
    return $m
}
function Release-FixItGuardianMutex { param($Mutex) try { $Mutex.ReleaseMutex() } catch { }; try { $Mutex.Dispose() } catch { } }
function Test-FixItGuardianRunning {
    $m = $null
    if ([System.Threading.Mutex]::TryOpenExisting($script:GuardianMutexName, [ref]$m)) { $m.Dispose(); return $true }
    return $false
}
function Start-FixItGuardianProcess {
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Start-FixItGuardianProcess' -Arguments $PSBoundParameters; return }
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script:SelfPath), '-Action', 'Guardian') -WindowStyle Hidden | Out-Null
}
function Stop-FixItGuardianProcess {
    if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Stop-FixItGuardianProcess' -Arguments $PSBoundParameters; return }
    $me = $PID
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue)) {
        if ($p.ProcessId -ne $me -and [string]$p.CommandLine -match 'FamilyFixIt\.ps1.*-Action\s+Guardian(\s|"|$)') {
            try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch { }
        }
    }
}

function New-FixItGuardianHotkey {
    $w = New-Object FixItGuard.HotkeyWindow
    # Ctrl (2) + Shift (4) + no auto-repeat (0x4000), key F (0x46)
    if (-not $w.Register(0x4006, 0x46)) {
        Write-FixItLog ('The key {0} is already used by another program, so the panic key is off' -f $script:GuardianHotkeyText) 'WARN'
        $w.Dispose()
        return $null
    }
    $w.add_Pressed({ try { Invoke-GuardianHotkey } catch { Write-FixItLog ('Hotkey failed: {0}' -f $_.Exception.Message) 'ERROR' } })
    return $w
}

function Start-FixItGuardianLoop {
    $tm = New-Object System.Windows.Forms.Timer
    $tm.Interval = $script:GuardianPollMs
    $tm.Add_Tick({ Invoke-GuardianTick })
    $tm.Start()
    try { [System.Windows.Forms.Application]::Run() } finally { $tm.Stop(); $tm.Dispose() }
}

function Wait-FixItGuardianToastClosed {
    $tm = New-Object System.Windows.Forms.Timer
    $tm.Interval = 1000
    $tm.Add_Tick({ Update-FixItGuardianTopMost; if ($null -eq $script:GT -or $script:GT.Form.IsDisposed) { [System.Windows.Forms.Application]::ExitThread() } })
    $tm.Start()
    try { [System.Windows.Forms.Application]::Run() } finally { $tm.Stop(); $tm.Dispose() }
}

function Update-FixItGuardianTopMost {
    if ($null -ne $script:GT -and -not $script:GT.Form.IsDisposed) { try { $script:GT.Form.ReassertTopMost() } catch { } }
}

function Close-FixItGuardianToast {
    if ($null -ne $script:GT) {
        $f = $script:GT.Form
        $script:GT = $null
        try { if (-not $f.IsDisposed) { $f.Close(); $f.Dispose() } } catch { }
    }
    if ($null -ne $script:GState) { $script:GState.ToastOpen = $false }
}

# Shows the toast (bottom right, always on top, never takes the keyboard focus), or switches it to the calm view.
function Show-FixItGuardianToast {
    param($Fg = $null)
    $script:GToastFg = $Fg
    Initialize-FixItGuardianNative
    if ($null -ne $script:GT) { $old = $script:GT.Form; $script:GT = $null; try { if (-not $old.IsDisposed) { $old.Dispose() } } catch { } }
    $g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $S = [double]($g0.DpiX / 96.0); $g0.Dispose()
    if ($S -lt 1) { $S = 1.0 }
    $px = [System.Drawing.GraphicsUnit]::Pixel
    $f = New-Object FixItGuard.ToastForm
    $f.FormBorderStyle = 'None'; $f.ShowInTaskbar = $false; $f.TopMost = $true; $f.StartPosition = 'Manual'
    $f.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FFFFFF')
    $W = [int](440 * $S); $H = [int](250 * $S)
    $f.ClientSize = New-Object System.Drawing.Size($W, $H)
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    if ($null -ne $Fg) { $bounds = New-Object System.Drawing.Rectangle($Fg.MonLeft, $Fg.MonTop, ($Fg.MonRight - $Fg.MonLeft), ($Fg.MonBottom - $Fg.MonTop)) }
    $f.Location = New-Object System.Drawing.Point(($bounds.Right - $W - [int](24 * $S)), ($bounds.Bottom - $H - [int](56 * $S)))
    $f.Add_Paint({ param($s, $e)
        $pen = New-Object System.Drawing.Pen([System.Drawing.ColorTranslator]::FromHtml('#D9473C'), 4)
        $e.Graphics.DrawRectangle($pen, 1, 1, ($s.ClientSize.Width - 3), ($s.ClientSize.Height - 3)); $pen.Dispose() })
    $mk = {
        param($text, $size, $bold, $x, $y, $w, $h, $color)
        $l = New-Object System.Windows.Forms.Label
        $style = [System.Drawing.FontStyle]::Regular; if ($bold) { $style = [System.Drawing.FontStyle]::Bold }
        $l.Text = $text; $l.AutoSize = $false; $l.BackColor = [System.Drawing.Color]::Transparent
        $l.Font = New-Object System.Drawing.Font('Segoe UI', [single]($size * $S), $style, $px)
        $l.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($color)
        $l.Location = New-Object System.Drawing.Point([int]($x * $S), [int]($y * $S)); $l.Size = New-Object System.Drawing.Size([int]($w * $S), [int]($h * $S))
        return $l
    }
    $title = & $mk 'Are you OK?' 28 $true 20 14 400 40 '#1A1A1A'
    $sub = & $mk 'Is a website scaring you?' 20 $false 20 54 400 30 '#333333'
    $hint = & $mk ('Or press ' + $script:GuardianHotkeyText + ' at any time.') 14 $false 20 218 400 22 '#616161'
    $calm = & $mk '' 19 $false 20 16 400 150 '#1A1A1A'
    $status = & $mk '' 18 $true 20 170 400 28 '#2F5E42'
    $mkb = {
        param($text, $size, $x, $y, $w, $h, $back, $fore)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text; $b.FlatStyle = 'Flat'; $b.UseVisualStyleBackColor = $false
        $b.BackColor = [System.Drawing.ColorTranslator]::FromHtml($back); $b.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($fore)
        $b.FlatAppearance.BorderColor = [System.Drawing.ColorTranslator]::FromHtml('#8A8A8A')
        $b.Font = New-Object System.Drawing.Font('Segoe UI', [single]($size * $S), [System.Drawing.FontStyle]::Bold, $px)
        $b.Location = New-Object System.Drawing.Point([int]($x * $S), [int]($y * $S)); $b.Size = New-Object System.Drawing.Size([int]($w * $S), [int]($h * $S))
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand; $b.TabStop = $false
        return $b
    }
    $out = & $mkb 'Get me out of here' 22 20 96 400 62 '#D9473C' '#FFFFFF'
    $out.FlatAppearance.BorderColor = [System.Drawing.ColorTranslator]::FromHtml('#D9473C')
    $fine = & $mkb "I'm fine" 18 20 164 400 46 '#FFFFFF' '#1A1A1A'
    $close = & $mkb 'Close' 18 20 196 400 44 '#FFFFFF' '#1A1A1A'
    $out.Add_Click({ param($s, $e) $fg = $script:GToastFg; Start-GuardianGetOutUi -Fg $fg -Reason 'button' -Demo:$script:GDemo })
    $fine.Add_Click({ param($s, $e) Invoke-GuardianFineClick })
    $close.Add_Click({ param($s, $e) Close-FixItGuardianToast })
    foreach ($c in @($title, $sub, $hint, $out, $fine, $calm, $status, $close)) { $f.Controls.Add($c) }
    $calm.Visible = $false; $status.Visible = $false; $close.Visible = $false
    $f.Add_FormClosed({ param($s, $e) if ($null -ne $script:GState) { $script:GState.ToastOpen = $false } })
    $script:GT = @{ Form = $f; Title = $title; Sub = $sub; Hint = $hint; Out = $out; Fine = $fine; Calm = $calm; Status = $status; Close = $close }
    $f.Show()
    $f.ReassertTopMost()
}

# Switches the toast to the calm view and sets its text. Creates the toast first if it is not showing.
function Set-FixItGuardianToast {
    param($Fg = $null, [string]$Mode = 'Calm', [string]$Text = '', [string]$Status = '', [bool]$Done = $false)
    if ($null -eq $script:GT -or $script:GT.Form.IsDisposed) { Show-FixItGuardianToast -Fg $Fg }
    $t = $script:GT
    foreach ($k in @('Title', 'Sub', 'Hint', 'Out', 'Fine')) { $t[$k].Visible = $false }
    $t.Calm.Text = $Text; $t.Calm.Visible = $true
    $t.Status.Text = $Status; $t.Status.Visible = [bool]$Status
    $t.Close.Visible = $Done
    $t.Form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
}
# ---------------------------------------------------------------------------
# My PC info (and the short PC code), Help me with... (guides you can search), Simple mode
# ---------------------------------------------------------------------------
# A letter/number alphabet with nothing that sounds or looks alike (no B/8, S/5, O/0, I/1/L, Z/2, Q, V, U).
$script:PcCodeAlphabet = 'ACDEFGHJKMNPRTWXY34679'

# ----- Windows adapters (replaced by pretend versions in the tests) -------
function Get-FixItMachineGuid {
    try { return [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name 'MachineGuid' -ErrorAction Stop).MachineGuid } catch { return '' }
}
function Set-FixItClipboard {
    param([string]$Text)
    try { [System.Windows.Forms.Clipboard]::SetText($Text); return $true } catch { Write-FixItLog ('Could not copy to the clipboard: {0}' -f $_.Exception.Message) 'WARN'; return $false }
}
function Get-FixItLocalGuidesText {
    $p = Join-Path $script:InstallDir 'guides.json'
    if (Test-Path -LiteralPath $p) { return [IO.File]::ReadAllText($p) }
    return ''
}

# ----- the PC code ----------------------------------------------------------
# 6 characters from SHA-256 of  UPPER(computer name) + '|' + lower(MachineGuid). Trey can work out the same code from a report.
function Get-FixItPcCode {
    param([string]$ComputerName, [string]$MachineGuid)
    $in = ([string]$ComputerName).Trim().ToUpperInvariant() + '|' + ([string]$MachineGuid).Trim().ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($in)) } finally { $sha.Dispose() }
    $alpha = $script:PcCodeAlphabet
    $code = ''
    for ($i = 0; $i -lt 6; $i++) { $code += [string]$alpha[[int]($h[$i] % $alpha.Length)] }
    return $code
}
function Format-FixItPcCode {
    param([string]$Code)
    if ($Code.Length -ne 6) { return $Code }
    return ($Code.Substring(0, 3) + '-' + $Code.Substring(3, 3))
}
function Get-FixItMyPcCode {
    $name = [string]$env:COMPUTERNAME
    $guid = ''
    try { $guid = [string](Get-FixItMachineGuid) } catch { }
    return (Format-FixItPcCode (Get-FixItPcCode -ComputerName $name -MachineGuid $guid))
}
function Get-FixItPcCodeLine { return ('PC code: ' + (Get-FixItMyPcCode)) }

function Get-FixItPcInfo {
    $os = $null
    try { $os = Get-FixItOsInfo } catch { Write-FixItLog ('Could not read Windows details: {0}' -f $_.Exception.Message) 'WARN' }
    $win = 'unknown'
    if ($os) { $win = ('{0} (version {1}, build {2})' -f $os.Caption, $os.Version, $os.Build) }
    $nm = [string]$env:COMPUTERNAME; if (-not $nm) { $nm = 'unknown' }
    return [pscustomobject]@{ PcName = $nm; Windows = $win; Tool = [string]$script:FixItVersion; Code = (Get-FixItMyPcCode) }
}
function Get-FixItPcInfoText {
    param($Info)
    return ((@(
        ('PC name: ' + $Info.PcName),
        ('Windows: ' + $Info.Windows),
        ('Family Fix-It version: ' + $Info.Tool),
        ('PC code: ' + $Info.Code)) -join "`r`n"))
}
function Invoke-PcInfo {
    Write-FixItLog 'Started: my PC info'
    $i = Get-FixItPcInfo
    $lines = @(('PC name: ' + $i.PcName), ('Windows: ' + $i.Windows), ('Family Fix-It version: ' + $i.Tool))
    return New-FixItResult $true 'My PC info' ('PC code: ' + $i.Code + '   (tell Trey this code if he asks)') $lines @{ PcInfo = $true; PcCode = $i.Code; CopyText = (Get-FixItPcInfoText $i); Info = $i }
}
function Copy-FixItPcInfo {
    $i = Get-FixItPcInfo
    if ($script:DryRun) { Write-FixItLog 'Would do: copy the PC info to the clipboard' 'DRYRUN'; return $true }
    return (Set-FixItClipboard -Text (Get-FixItPcInfoText $i))
}

# ----- guides ("Help me with...") ------------------------------------------
$script:GuideStopWords = @('a', 'an', 'the', 'to', 'my', 'me', 'i', 'how', 'do', 'does', 'can', 'of', 'in', 'on', 'for', 'and', 'is', 'it', 'with', 'help', 'want', 'need', 'please', 'what', 'where', 'am', 'are', 'you', 'up')

function Clear-FixItGuideText {
    param($Text, [int]$Max = 300)
    $t = ([string]$Text) -replace '[\x00-\x1F\x7F]', ' '
    $t = ($t -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) }
    return $t
}

# Checks the guides one at a time; a bad one is skipped (and logged), the rest still work.
function ConvertTo-FixItGuides {
    param($Json)
    $list = @()
    if ($null -eq $Json) { return @() }
    $items = $Json
    if (Test-FixItHas $Json 'guides') { $items = $Json.guides }
    $seen = @{}
    foreach ($g in @($items | Select-Object -First 20)) {
        $id = [string](Get-FixItProp $g 'id' '')
        $title = Clear-FixItGuideText (Get-FixItProp $g 'title' '') 60
        $steps = @()
        foreach ($st in @(Get-FixItProp $g 'steps' @() | Select-Object -First 15)) {
            $x = Clear-FixItGuideText $st 300
            if ($x) { $steps += $x }
        }
        $kw = @()
        $rawKw = Get-FixItProp $g 'keywords' @()
        if ($rawKw -is [string]) { $rawKw = @($rawKw -split ',') }
        foreach ($k in @($rawKw | Select-Object -First 40)) {
            $x = Clear-FixItGuideText $k 40
            if ($x) { $kw += $x }
        }
        if ($id -notmatch '^[a-z0-9][a-z0-9-]{0,39}$' -or -not $title -or $steps.Count -eq 0 -or $seen.ContainsKey($id)) {
            Write-FixItLog ('Ignored a help guide that looks wrong: {0}' -f $id) 'WARN'
            continue
        }
        $seen[$id] = $true
        $list += [pscustomobject]@{ Id = $id; Title = $title; Steps = @($steps); Keywords = @($kw) }
    }
    return @($list)
}

function Get-FixItBuiltInGuides {
    return @([pscustomobject]@{ Id = 'screenshot'; Title = 'Take a screenshot and send it to Trey'; Keywords = @('picture', 'screen', 'capture', 'snip'); Steps = @(
        'Get the problem on your screen.',
        'Press the Windows key, the Shift key and the S key all together, then drag a box over the part you want to show.',
        'Start a new email to Trey and press the Ctrl key and the V key together. The picture appears.',
        'Add a few words about what is wrong, then click Send.') })
}

# Online list (so Trey can fix a guide without anyone updating the program), then the local guides.json, then a tiny built-in list.
function Get-FixItGuides {
    if ($script:ManifestUrl -and $script:ManifestUrl -match '^https://' -and -not $script:ManifestUrl.Contains($script:OwnerPlaceholder)) {
        try {
            $m = (Get-WebText -Url $script:ManifestUrl) | ConvertFrom-Json
            if (Test-FixItHas $m 'guides') {
                $g = @(ConvertTo-FixItGuides $m.guides)
                if ($g.Count -gt 0) { return $g }
            }
        } catch { Write-FixItLog ('Could not read the help guides online, using the saved ones: {0}' -f $_.Exception.Message) 'WARN' }
    }
    try {
        $t = Get-FixItLocalGuidesText
        if ($t) {
            $g = @(ConvertTo-FixItGuides ($t | ConvertFrom-Json))
            if ($g.Count -gt 0) { return $g }
        }
    } catch { Write-FixItLog ('The saved help guides could not be read: {0}' -f $_.Exception.Message) 'WARN' }
    return @(Get-FixItBuiltInGuides)
}

function ConvertTo-FixItWords {
    param([string]$Text)
    $low = ([string]$Text).ToLowerInvariant()
    $t = $low -replace '[^a-z0-9]+', ' '
    $words = @($t.Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
    # "wi-fi" also counts as "wifi"
    foreach ($m in [regex]::Matches($low, '[a-z0-9]+(?:-[a-z0-9]+)+')) { $words += ($m.Value -replace '-', '') }
    return @($words)
}
function Get-FixItWordStem {
    param([string]$Word)
    $s = $Word
    if ($s.Length -gt 5 -and $s.EndsWith('ing')) {
        $s = $s.Substring(0, $s.Length - 3)
        if ($s.Length -gt 3 -and $s[$s.Length - 1] -eq $s[$s.Length - 2]) { $s = $s.Substring(0, $s.Length - 1) }
    } elseif ($s.Length -gt 5 -and $s.EndsWith('er')) {
        $s = $s.Substring(0, $s.Length - 2)
        if ($s.Length -gt 3 -and $s[$s.Length - 1] -eq $s[$s.Length - 2]) { $s = $s.Substring(0, $s.Length - 1) }
    } elseif ($s.Length -gt 4 -and $s.EndsWith('ies')) { $s = $s.Substring(0, $s.Length - 3) + 'y' }
    elseif ($s.Length -gt 4 -and $s.EndsWith('ed')) { $s = $s.Substring(0, $s.Length - 2) }
    elseif ($s.Length -gt 3 -and $s.EndsWith('s') -and -not $s.EndsWith('ss')) { $s = $s.Substring(0, $s.Length - 1) }
    return $s
}
# Edit distance that counts a swapped pair of letters as one slip. Gives up (returns Max+1) when the words are too different in length.
function Get-FixItEditDistance {
    param([string]$A, [string]$B, [int]$Max = 2)
    if ([math]::Abs($A.Length - $B.Length) -gt $Max) { return ($Max + 1) }
    $n = $A.Length; $m = $B.Length
    # One flat array (row i, column j lives at i * w + j) and plain temp variables: Windows PowerShell 5.1 cannot parse
    # a comma index like $d[($i - 1), $j] inside a method call.
    $w = $m + 1
    $d = New-Object 'int[]' (($n + 1) * $w)
    for ($i = 0; $i -le $n; $i++) { $d[$i * $w] = $i }
    for ($j = 0; $j -le $m; $j++) { $d[$j] = $j }
    for ($i = 1; $i -le $n; $i++) {
        for ($j = 1; $j -le $m; $j++) {
            $cost = 1; if ($A[$i - 1] -eq $B[$j - 1]) { $cost = 0 }
            $up = $d[($i - 1) * $w + $j] + 1
            $left = $d[$i * $w + ($j - 1)] + 1
            $diag = $d[($i - 1) * $w + ($j - 1)] + $cost
            $v = $up
            if ($left -lt $v) { $v = $left }
            if ($diag -lt $v) { $v = $diag }
            if ($i -gt 1 -and $j -gt 1 -and $A[$i - 1] -eq $B[$j - 2] -and $A[$i - 2] -eq $B[$j - 1]) {
                $swap = $d[($i - 2) * $w + ($j - 2)] + 1
                if ($swap -lt $v) { $v = $swap }
            }
            $d[$i * $w + $j] = $v
        }
    }
    return $d[$n * $w + $m]
}
# How well a typed word matches a word in a guide: 3 same word, 2 starts the same way, 1 probably a typing slip, 0 no.
function Get-FixItWordMatch {
    param([string]$Token, [string]$Word, [string]$TokenStem = '', [string]$WordStem = '')
    if ($Token -eq $Word) { return 3 }
    $ts = $TokenStem; if (-not $ts) { $ts = Get-FixItWordStem $Token }
    $ws = $WordStem; if (-not $ws) { $ws = Get-FixItWordStem $Word }
    if ($ts -eq $ws) { return 3 }
    if ($Token.Length -ge 3 -and $Word.StartsWith($Token)) { return 2 }
    if ($Word.Length -ge 4 -and $Token.StartsWith($Word) -and ($Token.Length - $Word.Length) -le 3) { return 2 }
    if ($ts.Length -ge 3 -and $ws.StartsWith($ts)) { return 2 }
    if ($Token.Length -ge 4 -and $Word.Length -ge 4 -and $Token[0] -eq $Word[0]) {
        $max = 1; if ($Token.Length -ge 8) { $max = 2 }
        if ((Get-FixItEditDistance -A $Token -B $Word -Max $max) -le $max) { return 1 }
        if ((Get-FixItEditDistance -A $ts -B $ws -Max $max) -le $max) { return 1 }
    }
    return 0
}

# Finds guides for what was typed. Looks in the title, the keywords/synonyms and the steps; forgives typing slips.
# An empty search (or only filler words like "help me with") returns every guide in its normal order.
$script:GuideIndex = @{}
function ConvertTo-FixItWordEntries {
    param([string[]]$Words)
    $o = @()
    foreach ($w in @($Words | Select-Object -Unique)) { $o += [pscustomobject]@{ W = $w; S = (Get-FixItWordStem $w) } }
    return @($o)
}
# The searchable words of one guide, worked out once and remembered.
function Get-FixItGuideIndex {
    param($Guide)
    $text = [string]$Guide.Title + '|' + ((@($Guide.Steps)) -join '|') + '|' + ((@($Guide.Keywords)) -join '|')
    $key = [string]$Guide.Id + '|' + [string]$text.Length + '|' + [string]$text.GetHashCode()
    if ($script:GuideIndex.ContainsKey($key)) { return $script:GuideIndex[$key] }
    $phrases = @(); $kw = @()
    foreach ($k in @($Guide.Keywords)) { $kn = ((ConvertTo-FixItWords $k) -join ' '); if ($kn) { $phrases += $kn; $kw += @($kn -split ' ') } }
    $idx = [pscustomobject]@{
        Title = @(ConvertTo-FixItWordEntries (ConvertTo-FixItWords $Guide.Title))
        Keys = @(ConvertTo-FixItWordEntries $kw)
        Steps = @(ConvertTo-FixItWordEntries (ConvertTo-FixItWords ((@($Guide.Steps)) -join ' ')))
        Phrases = @($phrases) }
    if ($script:GuideIndex.Count -gt 200) { $script:GuideIndex = @{} }
    $script:GuideIndex[$key] = $idx
    return $idx
}
function Search-FixItGuides {
    param($Guides, [string]$Query)
    $all = @($Guides)
    $tokens = @(ConvertTo-FixItWords $Query | Where-Object { $_.Length -ge 2 -and $script:GuideStopWords -notcontains $_ } | Select-Object -Unique | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ W = $_; S = (Get-FixItWordStem $_) } })
    $out = @()
    if ($tokens.Count -eq 0) {
        $n = 0
        foreach ($g in $all) { $out += [pscustomobject]@{ Guide = $g; Score = 0; Matched = 0; Order = $n }; $n++ }
        return @($out)
    }
    $need = [int][math]::Ceiling($tokens.Count / 2.0)
    $qNorm = (@($tokens | ForEach-Object { $_.W }) -join ' ')
    $wTitle = @{ 3 = 10; 2 = 8; 1 = 5 }; $wKey = @{ 3 = 9; 2 = 7; 1 = 4 }; $wStep = @{ 3 = 3; 2 = 2; 1 = 1 }
    $order = 0
    foreach ($g in $all) {
        $ix = Get-FixItGuideIndex $g
        $score = 0; $matched = 0
        foreach ($tk in $tokens) {
            $best = 0
            $t = $tk.W
            foreach ($w in $ix.Title) { $m = Get-FixItWordMatch -Token $t -Word $w.W -TokenStem $tk.S -WordStem $w.S; if ($m -gt 0 -and $wTitle[$m] -gt $best) { $best = $wTitle[$m] } }
            foreach ($w in $ix.Keys) { $m = Get-FixItWordMatch -Token $t -Word $w.W -TokenStem $tk.S -WordStem $w.S; if ($m -gt 0 -and $wKey[$m] -gt $best) { $best = $wKey[$m] } }
            if ($best -lt 8) { foreach ($w in $ix.Steps) { $m = Get-FixItWordMatch -Token $t -Word $w.W -TokenStem $tk.S -WordStem $w.S; if ($m -gt 0 -and $wStep[$m] -gt $best) { $best = $wStep[$m] } } }
            if ($best -gt 0) { $matched++; $score += $best }
        }
        foreach ($p in $ix.Phrases) { if ($p.Length -ge 4 -and ($qNorm.Contains($p) -or ($qNorm.Length -ge 4 -and $p.Contains($qNorm)))) { $score += 6; break } }
        if ($matched -ge $need) { $out += [pscustomobject]@{ Guide = $g; Score = $score; Matched = $matched; Order = $order } }
        $order++
    }
    $sorted = @($out | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'Matched'; Descending = $true }, @{ Expression = 'Order'; Descending = $false })
    # When there is a clear best answer, hide the weak maybes (like a one-letter-off title word).
    if ($sorted.Count -gt 0 -and $sorted[0].Score -ge 8) { $top = $sorted[0].Score; $sorted = @($sorted | Where-Object { ($_.Score * 100) -ge ($top * 40) }) }
    return @($sorted)
}

function Format-FixItGuideText {
    param($Guide)
    $o = @($Guide.Title, '')
    $n = 1
    foreach ($s in @($Guide.Steps)) { $o += ('{0}. {1}' -f $n, $s); $n++ }
    return ($o -join "`r`n")
}
function Get-FixItNoGuideNote {
    param([string]$Query)
    $q = Clear-FixItGuideText $Query 80
    return ('The person looked in "Help me with..." for "{0}" and there was no guide for it yet.' -f $q)
}
# Windows does not let a program pin itself to the taskbar, so this shows the few clicks. One guide, kept here so it is always right.
function Get-FixItPinGuide {
    return [pscustomobject]@{ Id = 'pin-taskbar'; Title = 'Pin Family Fix-It to the taskbar'; Keywords = @('pin', 'taskbar', 'shortcut', 'icon', 'find'); Steps = @(
        'Click the Start button (the Windows logo at the bottom of the screen).',
        'Type Family Fix-It. It shows up at the top of the list.',
        'Right-click it (press the right mouse button). If you only see a short list, click Show more options or More.',
        'Click Pin to taskbar.',
        'Family Fix-It now stays at the bottom of your screen. Click it any time you need help.') }
}
function Invoke-PinGuide {
    Write-FixItLog 'Started: pin me to the taskbar (guide)'
    $g = Get-FixItPinGuide
    $n = 1
    $lines = @()
    foreach ($st in @($g.Steps)) { $lines += ('{0}. {1}' -f $n, $st); $n++ }
    return New-FixItResult $true $g.Title 'Windows does not allow a program to pin itself, so here is how to do it:' $lines @{ GuideId = $g.Id }
}

function Invoke-GuidesHelper {
    param([string]$Search = '')
    $q = $Search; if (-not $q -and $script:Query) { $q = $script:Query }
    Write-FixItLog ('Started: help guides (search: "{0}")' -f (Clear-FixItGuideText $q 80))
    $guides = @(Get-FixItGuides)
    if (-not $q) {
        return New-FixItResult $true 'Help me with...' 'Pick a guide in the window, or run again with -Query and a few words (for example: scan).' @($guides | ForEach-Object { $_.Title }) @{ Guides = @($guides) }
    }
    $hits = @(Search-FixItGuides -Guides $guides -Query $q)
    if ($hits.Count -eq 0) { return New-FixItResult $true 'No guide yet' 'No guide for that yet - Send Trey a report?' @() @{ Guides = @(); NoMatch = $true } }
    $first = $hits[0].Guide
    $more = @($hits | Select-Object -Skip 1 | ForEach-Object { 'Also: ' + $_.Guide.Title })
    return New-FixItResult $true $first.Title (Format-FixItGuideText $first) $more @{ Guides = @($hits | ForEach-Object { $_.Guide }) }
}

# ----- Simple mode -----------------------------------------------------------
function Test-FixItSimpleMode { return ((Get-FixItSetting -Name 'SimpleMode' -Default '0') -eq '1') }
function Invoke-SimpleToggle {
    param([ValidateSet('Toggle', 'On', 'Off')][string]$Mode = 'Toggle')
    $now = Test-FixItSimpleMode
    $want = $now
    if ($Mode -eq 'On') { $want = $true } elseif ($Mode -eq 'Off') { $want = $false } else { $want = -not $now }
    Set-FixItSetting -Name 'SimpleMode' -Value $(if ($want) { '1' } else { '0' })
    if ($script:DryRun) { return New-FixItResult $true 'Practice run' ('Practice run only - Simple mode would be turned {0}.' -f $(if ($want) { 'on' } else { 'off' })) }
    if ($want) { return New-FixItResult $true 'Simple mode is on' 'The window now shows only the basics. Switch "Simple mode" off in the list on the left to see everything again.' }
    return New-FixItResult $true 'Simple mode is off' 'The window shows everything again.'
}

# What the window shows. Pure data (no drawing), so it can be tested. Positions are in 96-dpi pixels.
$script:SimpleTileIds = @('Printer', 'Network', 'Slow', 'Scam', 'Screen', 'Report')
function Get-FixItLayout {
    param([bool]$Simple = $false, [bool]$GuardianOn = $false, [bool]$BigText = $false, [bool]$HighContrast = $false, [bool]$CheckInOn = $false)
    $tiles1 = @(@('Printer', 'Fix my printer', "Won't print or is stuck", 'printer'), @('Acrobat', 'Fix Acrobat in Outlook', 'Acrobat buttons are missing', 'pdf'), @('Outlook', 'Fix Outlook', "Freezes or won't open", 'mail'))
    $tiles2 = @(@('Network', 'Fix my internet', "Wi-Fi or websites won't work", 'wifi'), @('Slow', 'My computer is slow', 'Clean up and speed up', 'slow'), @('Sound', 'Fix sound/mic/camera', "Video calls aren't working", 'cam'))
    $tiles3 = @(@('Browser', 'Clean up my browser', 'Pop-ups or a new homepage', 'globe'), @('WinUpdate', 'Fix Windows Update', 'Updates are stuck', 'upd'), @('OneDrive', 'Fix OneDrive', 'Files have disappeared', 'cloud'))
    if ($Simple) {
        $groups = @(@{ Name = 'THE BASICS'; Y = 84; Bg = '#E6F0FA'; Tiles = @($tiles1[0], $tiles2[0], $tiles2[1]) })
        $toggles = @(
            @('Simple', 'Simple mode', 'simple', $true, 44, 40),
            @('BigText', 'Big text', 'text', $BigText, 88, 40),
            @('Contrast', 'High contrast', 'contrast', $HighContrast, 132, 40))
        $pin = @('Pin', 'Pin me to the taskbar', '', 'pin', 428, 40)
        $lay = @{ Simple = $true; SideTitle = 'SETTINGS'; Nav = @(); SepY = 0; Pin = $pin; Toggles = $toggles; Groups = $groups; ScamY = 236; PrimaryY = 324; StatusY = 412; LinksY = 446; FullH = 480 }
    } else {
        $groups = @(
            @{ Name = 'PRINTING AND EMAIL'; Y = 84; Bg = '#E6F0FA'; Tiles = $tiles1 },
            @{ Name = 'INTERNET AND MY COMPUTER'; Y = 234; Bg = '#E3F4EA'; Tiles = $tiles2 },
            @{ Name = 'BROWSER, UPDATES AND FILES'; Y = 384; Bg = '#EEE9F9'; Tiles = $tiles3 })
        $nav = @(
            @('Restart', 'Restart the right way', '', 'restart', 44, 40),
            @('Status', 'Is it just me?', 'Check for outages', 'out', 88, 52),
            @('Undo', 'Undo last fix', '', 'undo', 144, 40),
            @('History', 'What did I fix?', '', 'history', 188, 40),
            @('Files', 'My files', 'Find a saved file', 'files', 232, 52),
            @('Install', 'Install an app', 'From a safe list', 'install', 288, 52),
            @('PCInfo', 'My PC info', 'Name, code and version', 'pcinfo', 344, 52),
            @('Guides', 'Help me with...', 'Step-by-step guides', 'guides', 400, 52))
        $toggles = @(
            @('Simple', 'Simple mode', 'simple', $false, 484, 40),
            @('Guardian', 'Watch for scary pop-ups', 'shield', $GuardianOn, 528, 52),
            @('BigText', 'Big text', 'text', $BigText, 584, 40),
            @('Contrast', 'High contrast', 'contrast', $HighContrast, 628, 40),
            @('CheckIn', 'Weekly check-in', 'check', $CheckInOn, 672, 40))
        $pin = @('Pin', 'Pin me to the taskbar', '', 'pin', 728, 40)
        $lay = @{ Simple = $false; SideTitle = 'TOOLS'; Nav = $nav; SepY = 470; Pin = $pin; Toggles = $toggles; Groups = $groups; ScamY = 538; PrimaryY = 626; StatusY = 712; LinksY = 746; FullH = 780 }
    }
    $ids = @()
    foreach ($g in $lay.Groups) { foreach ($t in $g.Tiles) { $ids += [string]$t[0] } }
    $ids += @('Scam', 'Screen', 'Report')
    $lay['TileIds'] = @($ids)
    return [pscustomobject]$lay
}
# ---------------------------------------------------------------------------
# The friendly window
# ---------------------------------------------------------------------------
function Show-FixItResult {
    param($Result)
    if ($null -eq $Result) { return }
    $text = $Result.Message
    if (@($Result.Details).Count -gt 0) { $text += "`r`n`r`n" + ((@($Result.Details) | Where-Object { $_ }) -join "`r`n") }
    if ($script:GuiActive -and (Get-FixItProp $Result 'PcInfo' $false)) { Show-FixItPcInfoForm -Result $Result; return }
    if ($script:GuiActive -and (Get-FixItProp $Result 'Scam' $false)) { Show-FixItScamForm -Result $Result; return }
    if ($script:GuiActive) {
        $icon = 'Information'
        if (-not $Result.Ok) { $icon = 'Warning' }
        [void][System.Windows.Forms.MessageBox]::Show($text, $Result.Title, 'OK', $icon)
    } else {
        Write-Host ''
        Write-Host ('[{0}] {1}' -f $(if ($Result.Ok) { 'OK' } else { 'PROBLEM' }), $Result.Title)
        Write-Host $text
    }
}

# ---------------------------------------------------------------------------
# The friendly window (modern look: rounded flat tiles, line icons)
# ---------------------------------------------------------------------------
function Show-FixItScamForm {
    param($Result)
    $S = $script:UiScale
    $f = New-Object System.Windows.Forms.Form
    Set-FixItFormIcon $f
    $f.Text = 'Family Fix-It'
    $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FDECEA')
    $f.ClientSize = New-Object System.Drawing.Size([int](620 * $S), [int](520 * $S))
    $h = New-Object System.Windows.Forms.Label
    $h.Text = "Do NOT call that number"
    $h.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#B3261E')
    $h.Font = New-Object System.Drawing.Font('Segoe UI', [single](30 * $S), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $h.AutoSize = $false
    $h.Location = New-Object System.Drawing.Point([int](24 * $S), [int](18 * $S))
    $h.Size = New-Object System.Drawing.Size([int](572 * $S), [int](48 * $S))
    $f.Controls.Add($h)
    $t = New-Object System.Windows.Forms.Label
    $t.Text = [string]$Result.Message
    $t.Font = New-Object System.Drawing.Font('Segoe UI', [single](19 * $S), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $t.AutoSize = $false
    $t.Location = New-Object System.Drawing.Point([int](24 * $S), [int](76 * $S))
    $t.Size = New-Object System.Drawing.Size([int](572 * $S), [int](370 * $S))
    $f.Controls.Add($t)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'
    $ok.Font = New-Object System.Drawing.Font('Segoe UI', [single](18 * $S), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $ok.Size = New-Object System.Drawing.Size([int](160 * $S), [int](48 * $S))
    $ok.Location = New-Object System.Drawing.Point([int](230 * $S), [int](452 * $S))
    $ok.DialogResult = 'OK'
    $f.AcceptButton = $ok
    $f.Controls.Add($ok)
    [void]$f.ShowDialog()
}

function Get-FixItIconMap {
    $b64 = @{
        'pcinfo' = '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'
        'pcinfoW' = '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'
        'guides' = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAC4ElEQVR4nOybTWgTQRTH/29309Ji/Sh+HqxeevAD1IMXP2pRpLQHwWoKnhVaFFG8elBvBjx6UEGPIkTwZEO1eqgXkYog2kMpIj1oUVuIHqxuss8nWkiyNTONSmcz84NsyNs3k53/zktml/96sBwPlmO9AAFq4MCxE2saisEhMHYQYa+EtsIgGPhMzMOhH55+eOfWu2q5CxKgs/Ni0LRy6gwV+AIILfIyEjmspSDqDaLUM/mYqZarXQI9vac2NK+eekkerkjnLUgCTPtUKfozwC/elu0mJAgpz5QqR0uAnnT/OZlXu+bdyTwp+94yE2MxIQQy9XeXhpg5UjXTEkBGdr6y3KXz1/LWl8teH4MBdKWPt/qUmi6NEZGyxJUCHDzS3y4dtZbGmDEdodAxlL05g4SjFCBF2BMLMl8aupuAwcs0VaWoS4CoIx7DIyQBmbqqFGWNMHh9rFHKe486wV0LwHKcALAcJwAsxwkAy3ECwHKcALAcJwAsxwkAy3ECwHKcALAcJwAsxwkAy3ECwHKcALAcJwAspyaf4GyxsKq7b+CoST7B+bwQEXOjql1NAjRG3qjJPsE5CLxOlVOTAInxCZLXrEqpTYCkwPxBlfL3ApjiE/w1ljKfIBF90mlUE0b6BFHuE9RBKQCDm6ji104GP2ONT1AGv7wyFjFlEuET1ECnBFZUBjy/MII6QcMniHxlTGZFXZz9n+gshQdjEfa3wzCCVEPsX0jHLa4UQM72/VjHQKYzfXIJDKIQfo+tS3Xc4sqErx/Xjsgye6KsY2BjE4pPu9P9m5FwtFbz3emB/fQng7TZD0w8kHVKV7VmWguhXPbaYxHhnohwOP7F1CbbNjLwwuiflMAcIaKzlaVgOnK8oSpHW4Dh7I3JYDbaJp1eZY0HEUxADlK5XvGxAMbHn4cTY6O59i07n0j332SS5X/X3jIYhJyfvBzTYMEPL7959eJLtVzDb2n8f9xNUVjODwAAAP//jITlpwAAAAZJREFUAwC0o9edv4vtuwAAAABJRU5ErkJggg=='
        'guidesW' = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAACJElEQVR4nOybvUoDQRSFz4oiioIGRCyiFlr4A2rrTwQfQBBEH8FKFCvBQiwDlj6DrZVWamFlYSXEykIsFEQFbRXXM2CazZiZLAuZ2TsfHCbcvUm4Z/fubsLdFginBcIRb0ArUhDHcT+XZWqGWqAm4Raf1Dm1GUXRU73ECA3AwpVhW9Q+1Q332aUB5XoJ1i3A4oe43FKH8KN4xaIpoZEWOKbG4BdtpgQrA7j3d7jM/rP5kXpQaWguqpa5ROzH5k027GliFWqNPXYHB+BOKnB5S4SNLW40gB88yqWQCKsvKrH4d3iOzREwr4kdeFK8sS1tDChpYhfwA+Nl3saAoib2jJwQfgtAOMEACCcYAOEEAyCcYACEEwyAcIIBEE4wAMIJBkA4wQAIJxgA4QQDIJxgAIQTDIBwggEQTqo5QdIXx/Eq3J0TrNJuSkhrwA38GJUbMCWkNcCXOcFOU0JaA3zhxZSQhQEuzwm+2rwpLT7MCRqxMaBDE1MjcmLmBHs0sXIeilfYGNCriV0hJ9jcCX5oYrnY+wobA840sWm4h+4qZJwWtzHgVBMr86zbBbfQjcUa67MxQPX7fSI2TF3ThHF4jvEkyLP9NwvdQO2A9ARV4TaXboSSZPPABE24ZKEnfLmi2Tz4JxfJpAWqbKO2FVzny5RgbQCPAnWoT1FHaP7hbovxfqWh5warsB2WuKxTI5R6pKYIt1D3Luqcle2Dk3kk/CkK4fwCAAD///TlHzoAAAAGSURBVAMAcHNsDTwTRe0AAAAASUVORK5CYII='
        'simple' = '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'
        'simpleW' = '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'
        'shield' = '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'
        'shieldW' = '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'
        'printer' = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAEG0lEQVR4nOybTYgURxTH/69mRNbdnQmBhCQSc0jYaAwhwUM+yNfurIeAyTGQgCEEYmR3hE1ySA7JLSSnILrjuOhBQUHw5NdB0dlVbyIqoiL4LSqCF51Z1/Vjup6v1Znt6mndnVJ7Zrb7B9s99aqrq9+bejWvXvUqRByFiBN5AyRhSWe28J9ifAfCG2gkjIsMbCityvwNCwgWpJcV3pSOz6CJuKuTc8bzX1xCnVi5gGb+Ek1GkpyFsMDKAErbu87zQlm6s1UjnSAt/m/AzKeI6CpCQPp6Vfrq8srkgRgWWBlAOaygzOmDoP4v5nrWIATSfXt+kQ6HvDKlyWo+i+MARJzYAIg4sQEQcWIDIOLEBkDEiQ2AiDPpAsJNfmim+bLYmseEtgdCxgJpuci4kLFDZIcQBpP0T4xxWRudVMQnioOZs0+61WMN0LF05F2VcDbLsnMeWhhZOp/UTuLbm0Pdx4PqA10glR3+NZHUx1pdeRdXB1eXVH9hILDeL+jMDn+jwFsxDWHNX5XyvTu9MtMAAyMvpMr6lAhfwjRE3OEa6Zlzi6s/u16RGRmhznvOTzJkApTnvTLJHGSiW76KLrmrlnHWqAxxYP/EPEuOH8rX+7khJ3qZ1Z3F8nFlRWYYQCaEj/09MHhxKde7ES1IZ1/hR6WwzpSSq2PVAMYkyKBPYQoutKryLqP5zHo5XfbKiPgTb3nCAEt2pyWt+Iq3UtKsp9HqsF8HmoO+kY5KqWqAVHt7wt9WrGWVaW0ytF+Q5uSMyud4LYCIExsAESfy7wdYjQB3iSwN/2y48i7yDPLz/Vdb377XYUH8fgAsiN8PiN8PiN8PmDZUDVAaG3P8lcxkNayaCqrNehWTM6q6ToyANQuLcrxhNubZaHFkZpjtExQx+FGpUvS7wGFfeW5H//B8tCizlu3+QGaGt70yyWod8JbNSZBxRAZMT6Uoo0cp0vvT/YW1sjC+Xb2MeUGzrZMlc/V1Klt4rVImcJtou6T2OvNLNgxwx1G5mUlnqTRvn7gRvSiHP8i8ScATUHg2CehLBO5GySJDUtMOo2UHOa/IcIHbQ90XWNPPsEBDv4WQ0IQuWKCJfxgfylzxymp+Bkv5zCbJDf6GelGqjNDge6gTcZGB0VzvFr88MA4o5XqWl4ned7eVMEUkEDuPkJCHPjfVa10dytDvSXJ3RVD9YyPBscGeo3J6J3BzFLI5Cd/mZIOReWmHnGo2R0XxJ26OThoKP9pddf+2VWSPQtGmMoBM1tttQvE4FEbEiQ2AiPPsEiLQv6ezhe8RAg8SIj5Z4xMiDzM0VhFavVBA1B1qQkQrhBj1TQ3ZALR6JisDkE7sQ5NRdngXLLAyQCnffUZS4/+KM9b9f3rPGnH8s+L9//gXOVNlOmx/PxVxHICIcx8AAP//mdnOzQAAAAZJREFUAwC3onODnJhs7AAAAABJRU5ErkJggg=='
        'pdf' = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAEW0lEQVR4nOybXWgcVRTH/2dmN9m2SQa0vvgk1optrUWUUlSsuxsIVClF7KOQF0Orm0KfCj4VREUQRbOBWKXqiyB9qaJ5SrKtShGRomiJX4GCCCIq7G7TzWY/jmd2I013N7k76Zmww8yPnd2dO/fOvfc/d86c+zEWQo6FkBN6AWLwyMDzF3dZVvU4gfcyYy8R3Q4l5Hzud3OHaKG8jJHymfQCfIS8RB56YeaEJHmNCAn4gCsA0ep9XihYy3swcagMn+j6FnAyM+/J1X7Lt8rj5so3INrh1Ps/x2jOlzwbWXQTaTAzd9gCfwIfaQiwduhcnsqH/GgJRgEGx3LbKV6fl6uzvfWYNNmfJfxPKMCgmNiVR1tDVxVxLh/f8hTefKQERYxG0IrXj6Kt8vxDuWofXppKXoUSQycv3YZK6Z91oqScSumz/GjuSXyQXIISRhsg1+De9jA6pVl5D6ScgbqqTejCCPI9rSHV5fh32AwYxQ6hTRFOXtoCBYwCEKgto7hNak3QwLciwuUO4Y3bAePT/bhFetsTJNTy1rbkmiJw//StitD7rvDEgYKfIgSjL+CjCMHpDPkkQrB6gz6IELzusLIIwRwPUBTB83iAS76/ylCGlmoMuy102MnMds6LF9fsyUgfJTWE/t8rx2YfLE2l/8A69EwL4ITtaWxiPdxutXzuiFs4a4rbMwIUFvuK0qSvQREm7DbF6R0bcObhihT4UygiLeEvU5wN2QCnHKM89CkkqmPOdfsLuSzPSPHjXtJysy6N8QTC/yMJ/K8p3YYE8I3XRxZF2HfQ3DzhjifQqvGEbg1KNC+AkBMJgJATCYCQE02OQpGB8ZndxPSsqLpfdm3oUqsD30hP5/3i5PAvUEJVAIvxhjggI/AJETYlHt4u+XsESujdAkd/7JPvJHxGBH5iJS8V9AQ4d/+yzCHMw2+Irrp5QQlVI1gHn2bw17LVoQwz12T7iplehCKqNqCYHT4vP+cRICI/ACEnEgAhJ3KFochgZuaIOCqn5O9+8QlUxV15tIorbL1UmExNQwnVQlqg01LxA9qVd3HP2Tg38StQRK2gg5ncffKzD/6zbyUvFdQEKGaTP0kz/Rg+I97gh25eUELVBhSuJ55ztpYvyNzc09JUPY3rm5BeYFm2c8W+rR9BEd15gbOPFWVcfwrNLRBEfgBCTiQAQo5ZAELbRHDFLqksU9WkUupQJoZxEtu8WJr5+9awGOzNcHg8EYvRQ61hDDKuaTYLQFbbScTffzVxLHcXegRnfHaHBX65/QhdNqU1T6OP5hLOttoVGYy8u/WQtI55IjKuwvAT8T7vlD7CzrZwxm+FyfROU/qu1hEMjM8dtJkvIEDUiR8vTgx/aYrX1VPg2kTqovy8i4AgLvNUN5V36foxmM+mx+TEJ6Rpbda7Ahuh5JaxkE0f7zaB57V5N16cxAMixp5OL1NtJlKGv6UMVxpPKzueLbx98Fcv6dUWJwaVyBNEyPkPAAD//8dWlTIAAAAGSURBVAMACNt4CvU5g7AAAAAASUVORK5CYII='
        'mail' = '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'
        'wifi' = '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'
        'slow' = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAELElEQVR4nOybS2sTXxjGn3dq8/8vbFJw4zdw40q8oQunC0HF28Iroiv1I7gwFQq2GxG3guBC8FoVtIKKKC2KuPCycSV+BsFEXZi08/qe2qkzySQ5MznjvBB/0E565p3Lefs855I542HA8TDg/EsABpyBT8AK5MjIuL/bC7C61ijdwsVnP6CQ3BJQqY69J2Cd0Vjlv+apGrAJCsnFAuXqtqNEUvkl5PPGStU/DIXkkgAP1FZZScIRKITgmgl/ZWWevsiJS9FiBhq1FbwKE3PfoQjnCigvYH9r5Q2mrNzEPijDeQI8poMd9wEHoQy3Fugg/xCNNnCqgE7yD9FoA6cJ6Cb/yAVV2cCdBc5sHRktleo2oV8bjTIuvP4GBThTQHl4eG97KT+QXzN2scXgLAFJ0g6I7gbEd21ii8KNBRJa/+UWX+i4T0Fv4EQBSa0/MT9ZrKD8yL6nsX2KegMnCUhq/QNgWfqabdB/AkT+Iukd0SIj8fowHoZ/14fwwJTFYoh2mmNRMH0noKv8QxTboO8E9JL/cplSG/SXAAv5h2i1QV8JsJJ/iFIb9JUAW/kv71Nog+wJSCH/EI02yJyAVPIPUWiDtq/FK2e3bWcPm+WLzaFuBzKjbUITeDSNHgTM0x5R7FiPcEA2N5CGCf//yjx2SwLX2oQH4AUCvalNzj2PlscSMDo+dk02J2wmCK0xi/If4plexxmLyI034nMD2rVogxRzg9EmvZCb2GIb7y3dcWXcvypJOPmnPEKrp9NA4MdWFTA2MFaJHWtswHtgSfmcfyRN5ePXkjYnQiwBxGgiI2KJ27axgYd7rWVJzxI6IY/bsj9jYF6IXzd6Y8AVZDvrq9rU3B3baNMbtBUS7bPqDUyMic0IE1+OXbY1YGR8bI0HPiA7hmFzQqaPtanZ+0iJtDemu4w1hgHhWP387M1ux5Wr/jFpRK/H7wEfiPhRt+PE3k1GMF2ffPk5Wt7WC3ybnP0kmynkjBkUyUAq3hsEfEg2XRMglT/UWsbgS9KwpetFwvOhIDINijIMvnpR3AKJDIOiTIOvHhS6QiTt3CDt3MOGQhOQygY5yN9Q7BqhFDbIQ/6GwhdJ2dogD/kvXatYrGyQk/wNxS+Ts7BBXvI3qFgn2MsGecnfkOs6QVuMDdqmyBEb8Dx2RMfsruRv0LFStNMUeYH25il/gwoFGIyk5b8R6/48ZpE+eUmxcISaBNSbzZnRUuvqGtrfKRaO0LNY+veKkd4VY37ocnWJqtXiSb1BW4xD+RtUJSBpUBTFZesfout9gYRBURSXrX+IrgSguw1cy9+gLgGdbJCH/A36XplJGBQZrJ87pERfApD8iC3Nc4c0uH9fwBGVqv+WiNabz8z8Tp47bEAOqH1rzFRYGsTj8l3+6drPko+cUKuAv4VaBfwt/iUAA87AJ+AXAAAA//9ylWJ/AAAABklEQVQDAPEJ4QDADOOOAAAAAElFTkSuQmCC'
        'cam' = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAFA0lEQVR4nOyaX2xTVRzHv7/b29FN1lvIUBISQTQoAUFdUFDStUqIPjiNRH3wwQTjInEaiQ+ArVqzVcceMCSGkCgxMT4IJpJITISo64pGJIiKwKKJZsqLAZTeMmlpb+/hdwssW3vbdaVs9/b2k+z29pxzT/f7nt/5nX9XgsOR4HAaAsDhNASAw2kIAIfTEAAOx/ECyIUJM8P+xTJcG/h2mYBYQqA2TDH8u2n+GCLghE74ItkT+wTXCRr7xRsKvkwktrLRHlgIAXwmZV3rz239SkWNGRVACQc+YMOfg1URYjjhTi1H5Ickakg+BrSGg52WNt6AaIEv27wDNYZaI4E2STP6W3FfZ9f7jV3kH0wxHANa+P9ZYZaXAx473zvwOWqELGniSYJUYLz4FRo61b7YMKaLjaualRs827kBnh+bLAnRzR9VCTBr0xpFd2e7IOg+QWIwKY/skknQovGhENB1sSnZNziM6eTd71Mc8bp84eDT/M17NZk9YxGqoDXkv18gt4cbe55hL9ezzpvz/ivz3W2FhTXoP8MiCCFOEtHK0QTCfEyGSEBWsvQW17TFsHpsFnvTI/yH5sJn3Hp+HLYK/xcmKJtXz0IFcLmFiobDRHiNRaTCfI5xc+t2JqiEAi+QSz7OjX53yUIcbWXUGb5IwIcsPuJh89EJC7M6dSXAzJDfLzTsZm+fW+kz9SFAV7vbN6e1n1v9lVJFuL+/Xziksgvothfg8uJN2s3G3GmWz938LMf7Z4ScOkKap0AAIdk6CHpDgW4XpKOljccBTXctVXu/OVCqDlt6QFrOtnGU/5T7+kNm+Wx4hgS2qNGBbRPVZUsBPKLlEI/qs83y2Pg/OG9donfgF1SATWOAmA1QcSrwoSonuxH58QIqpD5GAQFVSOhSewb2YJJYXgCO4s1k0tqj+UIcykB/KtUTP4UqsMMocIdZIhvO2ohe9fc5q1PRiY2ntEuYpOqWF4BMFkOXM+iMYQCuEcsLIMh8R4qFuZEvbyi3nznoefOBm1El1vcAQWU3QTk+rPJoTcd84cDj5coJT84kkNh8JjgKQeHLXiUU3IVIe8tkHrWpAPSfaSphvaJ5j/leDy5HhdhSgDRdWMmDwNdmeeznt/L4cNgX7tiICrClAB7NfVaNxtboQrx05RhtHCxCE5u2TQkH9xvb/uXqsnUMSEZj7+Wg38MiDJnlsxBrpSwdV8IPri1Vh+2D4EhvfEiVT9+lC5iu/Dgu3EQQ+0mb0V+Uyfvk9TEKRE5mktGBVzWR62BvKDFvMDn6I7jqald4JBqP8y7nYp4i76v0mbrbFk9EYolENNbJo8QGFiJVtjC7S92eC/AosVPktKVs408lC3G/kDhKFL10kPWIZlgFQtHMTu379hwqgMv9qcq4l+cFb+dXj8WVJ42jsaKtIzkjVzyTuq5EAh5upCXjE/nkelJ1xDTeGwzpkujgLjFu2cwnxHslXm0VHYRKkvSOb3NgAaYT43g8S9sx5mQ4j8BRVMH5nsGDcGMZO8JO7hZf6oRnkz2xj8lQmX/oBI+XCwsfMiYY3AKnMcWUe0GCDVjB/fsIakR+iciLB3YPxGBxuLvuYHd+ETXEZVzS8eG/ZvhvmcdqtMO6/K1mM0/gu1MZ1BDX1ZuL8eF9Tf75xjIzaLVD0yuvyT2c7h+s6RtiBkW7JI5+UdKJNF6WhsNpCACH0xAADqchABxOQwA4nEsAAAD//6q/L6YAAAAGSURBVAMAJmawx56k1bUAAAAASUVORK5CYII='
        'globe' = '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'
        'upd' = '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'
        'cloud' = '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'
        'warn' = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAFbUlEQVR4nOxbW4iVVRReZ4ii6PLSTai8jGU3qYeC6IKkvWSNmpNhPiYSkU7TlFqjCSFSY6JkFwjpIXowMqPwApFCVlIIvgjiXUcULzgvgihej9/yrDMe17/2Of9l73/OnOMHa9bM2mv/e6/1r/2df+//TAs1OVqoyXE9AdTkaPoE3EADgGKx2A41BjJUTL2QvwuFwmrKGQXKEQh8AtRXkAccLr2QWUjEWsoJuS0BBP8p1O/kDp4xDLIGvvMpJ+RSAQjoBahNCcYrQsagEv6hwAieAAR/M9QuyP2UDIcgI5GEcxQQeSyBbrKD/wHCZDgV8qPRzn0+ocAIWgG4+61Qe42mZbizXcp3OdQsw7cVvvspEEInYAPUOGU2Sxu+N1IpWbpaNsL3JQqEYEsAAU2iaPCMt611LbZ3Df9xuNZECoQgFVDlbq5FoG01+sauGh8IVQH8Oa6DPwt5J0bfGeJbCb7WPAoA7wnAHRwONcdo+hx38HCt/vA5ALXYaJqLa99HnuF9Cfgo4SpLaD2u8Qp5hNcKkGd9i/hmJlm/4tthNI3HGG3kEd4qIMTHWB6E6LMCrCc+JrMZlB7c97yy8Rgfkyd4qQAhJ777N6mmhbhTCxx97oIqr+d18Dvh8FtEpeRWghM7Mg6p1oKvBKyDGq/MzlKV5cIB3y6mk5C7Hb68mdoHGaKa1sB/AmVE5iWACb5K0eAZHVXW6Vi6GjzjDsizliOucYbsPUIbxn6ZMiJTAuROfms0MfH9VqXrUMP2kMtZjso2Gk3fyRxSI2sFMBlp4mPSykJ8LrgI8SPKgNQJEOKz2HixPM15hVxzqdHUneUJMUsFfENR1mfiW0ThwOeKR5WN5/A1pUSqBCDjTGIWA3cKaQWBXLvTaJooc0qMxAkQ0llhNDHx/UqBgTF+htpsNK3A3BK/50hTAXMhI5QtFPG5MB1yUdl4TokJMVEChGysffmSEMTnAsbiU+ZlRtP8pISYtAL4rY4mPialhZQ/FpBNiMspAWInQEhmktHUEZL4XJAxPzCaXktCiLESIOTiIr5faICAsVdSRkKMWwG+iW+T+ptfhW2gdHAR4pw4nWsmQEil22hampb40G8nlc79Dop8lvblhxCite7nxSHEmtthXIQ3IpOVmcmndSDWvgXM8VYovhl3qqbVmOPr1fq21Lgwk8lko6mzXoJnYC6noN43mtprEaKzAoREuLz02t+MAZ+nOgTm/C/Uc8rMS2sU5nzB6lOtAmaTTXzTqX7hIsQPXR3MCkAm76XSMdQtqukLZDIWuw4UMPcvKXqkfppKnHVM+7sSsApKk0ddEZ8LVQhxFeb+hvZvMS7ApGExZ5fP4DFOD6RXpIc8QQjRKvkpFiEW1KRyIT6M8zDUDmV+RJ4PfI2xBeppZY4Qoq4AfrbWwTOp+Ca+qTFtWcBzLiobx3bNN1P6KwAZu4dKGdLEx1vd2eQRcqjSB7lNTFy2Q6R8fY7Du9eZynwNIVZWwHsUDZ6Jz3yzkwXyvuBJyBKRJ3wHL+DvKfQpG8fYf6xWWQH8pkYz5zTZcQ1aIK63oL5X5j7Exa/mSgmA02iobcppN5xGUQMA8fHSHq7MjyO+7eUlMMLo9wc1Dv40bMP4R/nQ4Jjh8Bg1Dh41bFeO08oVYH3+jkXpWGfwgwqIgXeJ1jPMHv5RSYJ83j7FcGRuWE/Rb27VO/iAlL9/MNpoW4n1P41/qUzAM1D/UXPgKSRgK//S/xwAw/9U+kxudPSUg2dEdoOoBD7lbafGxE8I/s1KQ2Q3KGdo/IrpODUOmPG7dPCMqoeiqIYXoR6E8AHJYPsPs0uQI5C9CPwvl1Ou/zRVjxhsd9U7rieAmhxNn4DLAAAA//8fEv6AAAAABklEQVQDADZW1kJEo9w0AAAAAElFTkSuQmCC'
        'mon' = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAACq0lEQVR4nOya3YtNURjGn3NQTArJhCaSYnwkpciNSblRZq7kbiI3I274B5R/wY2PEheuXJg0Ny4U1yRqCCPlI6bccOVjxPFbzuzTPss6Z9RZZ7TOu3719p797rV353n22l/ttyrjVGWcbICMY96AhXMNqNVqG0nbiC3EEqXBV+IZ8bRSqbxqN7DSagXCt5NuqC48ZZwRRzDiSWhl8BRA/BnSpNIX73AaJtF0OrTyrxnAwBHSLfUmB5kJt8uFJgMQv5w0RaxSb/KRGMSET0XBvwgeV1j8PeIB8UVp0EfsIfZ59X5ilDhfFHwD9gZ2Nopj15UgzOhjpKte2WlsGOCfAtOk1aXSa8RvUMKg6R1poFR6i6b1xUK1NHCZmsU7Xip9fA3r0Lq0WCifAgsCG7d8TkiIX4HaouJHfheQcbIBMk42QMbJBsg42QAZJxsg42QDZJxsgIyTDZBxsgEyTjZAxskGyDjZgNJv98n4h7d+hdJnpbfs2mc+FwsNA/hgWCM99AZv5TtavxKF/76GtNMrP5rV+gf/FHjsLbumqHF2NESk0iDlhPcR+/k5HljddJD9z+ODqvcGzdk9ligzxA5mwIui0DQDWPGcdE69y9myeEfw8zczYYJ0SL3FBOJH/GLwNsjAYdJJpdMT1A6n4VRIvKNtAwQzwbWSHFD8TlF3dd7k1Vx32rTi0OgUJe4g/k2rgf+lAwRjx0gXvfIYf/Sy5pn8JCjjZANknKhPfFzcFpOGiN0Kt90V7ArUhtl+bZttfhL3ibtcLGcUiah3AQRcIx1Vd7mEAScUiWgGIN7t673q9/hu8oEYKL/RdULsl575eK74pohEuwjOHpEr6j4XYh19R/QjxqmwmXRYpX7cNhSPw1P/MPY7cdN/m+uUXmiG7oj8ICTjZANknN8AAAD//+wzBSMAAAAGSURBVAMAjU6dX+xuHXAAAAAASUVORK5CYII='
        'send' = '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'
        'restart' = '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'
        'restartW' = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAFMklEQVR4nOxbW4hVVRj+xu4GWtHojEVp5I2KJCQKo8vDNJrWBF2srJDC6PIS9BA9OQ+lTVF4ARV98EURFZ3RUVAUfFLxCt7x8jDgbXS8IDreQI/f7yzxsM6/9l77zD5778M5H3yss/+11l7/+ve/7uv0QYWjDyocVQMgJeRyuRayw/AvpIQapABWeASDQ/kicnhNTc1RJIy0POAL61k+xCdIAQ8iHZxWZBeQAqqdICocVQOgwlE1ACocVQOgwlGUATiVfYGcRy6Q30gJLHsouZCcTT6LIhB5JsiCXmSwi+xnRE2UPcd5/HUkCJb5OIPt5BNGNImy16hHByIgkgewgKcYbMD9ygtqyW+QPKbgfuUFT5LrqWO/CO/wNwBfLN6yhhysRG9G8timyIaRbdTVe5UbxQMWkG8q8qV0u4NIGCxzK4PVStR75P/whJcBaNEJDCYrUbKm/w7p4WvyiCL/lTqPgQdCDWDc6T8l6hzZwC9xFSmBZV9m0EheVKJnwAM+HiBfeJglu0GOpQInkTJMry8eesuKGs2PNzEsf6AB+IJHGExTolpY8C5kBNRlC4NZStR003k7EeYBv5EDLNklsgXZw59ktyUbQv4clCnMAD8psmlptnsXqJNsqWm9/49B+ZwGoOsMZ2BPL6WdzUF2IR1fzpKNZF1qXRmCPOB9RbaBlr6CjMJ4gTYpm+DKE2SABkW2AtnHSkXW4EocZIBR1rO4VjkYYIkiG+VKHGSAeuv5GF3sIjIO6tiJwnOHQa70qgHYaQxE4VL5OMoHJ6zn/qxTXy2hywMGeby0N9ijyPYiPmgf6xktYRQDxOkBspTdl/e8H/rytlhouqrNwDVNrFNksc372U7pkblX+XO8Ea0VGeKD5q31WkKXAboVWV/ECFPhNSgNHlVk6padywBnFdlAlA80D+7UEroMcEaRlbsBtDpFMkAdygearmon7tw8ZCd124rvYrsdgIyDesvIJjtF+X3WZequ7hYHzQR3W8+1fPnryD7eQWGHvduVOMgA7YpsPLIPbeXX7kocZABtiCoHA2g6OofbwAMEunwXg6ct8egs7Qfmg/q+y2CTJe6gvkNcecK2xFoVmdd2c0qYrchagzKEGWAmeduSvUVLf4CMgTp9zuBlSyxbeHOD8gUagK5zgMEiJervKOdvpYYZ+rSd6vlht099Dkb+QOE8+hVyOrID+cqDLZmsZ6aGZQw1AC14Cnq7/52Wn4yUQR3k7OIHJeof6t4Vlt/LjVmIrK7kNNbeW5M2JkdkG5ECqNfH6NkEteuxkxxDvW6GvcPrdNjc/hiHwr22B8h2KvIpEgbL/IrBUhRWXvYCxvpUXuB9P8BsNooRrllR4h3LqVAzEoB0vuS//LmYfNiKlnYvJ9bn4YnIPTkL/5DBKkdekU+kAjdQAph7QctIbRiW4boxanOMfEuMBci8eoojuok8TEW/R8zgO3+Rd0OvvODbYvqiosdyKvQ2gzb0XE7SIDc3ZBhqK/YGmdnK/sy8xzWdlZ6+yVyZiYxeTWao4PMM1pEjApJJu1yPninp2rDDFXMTTTxJeng50nosILnsJo/jO4vesu/1bM5cS5N22eiZRQxyyVA6q4fI/nn03XyV/mYSK9+NXiCW6ayZFourNpMjUVrIecJUVrwVMSDW+byZk3+JnjY7FPFCbqQ1k8vjPEMoyYLGeMQb5EekDJsvoTjIcZncBZSRZ0fMhyd3kciKznSW0qmJV9QZ1ptQKnXvRLfTUIa71iRuoWVmSZsWqv8XQIXjDgAAAP//IssUBAAAAAZJREFUAwBgsIWyK4Hc0wAAAABJRU5ErkJggg=='
        'out' = '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'
        'outW' = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAEfElEQVR4nOyaW6hVRRzGv2MlFR7rnCCyIkqhXnuoB6HMUgK1LOqlmw9BdKELRBRyuuiDcSQyMnoTrIfuqKeyC9iFIAwKTwje0AdvqPjg/X7f/v6uLWznzN4za+21th7W+uBjzp71nz3/7zsza2bW2iNUcoxQyVEZoJKjMkAlR2WASo7KAJUclQEqOUpvwOXqMGq12liKmxpo2H6eXV1dG9VBdKlAINa+/244FU6Bdyk86s7A/+Cv8Bc4iCk1FYRCDEB4D0UffBZep/awGy6E/RixVzkjVwMQfhXF6/AteI3yxT44F87HiGPKCbkZgPjblQzZcSoW6+F0TNigHJCLAYh/lOJLeHUg1P5zy+HeOnfXc+iFNm1sutyvMI7AJzHhR7WJtgxAuN3Q3oczW4Sdhr8rMWgJSR9W6+8cRfEYfBpOgpc1C4Vz4Kx2bpLtGvATxbQml+2/vQDOJcEdyvb9tyi5n7zcImwp3z9dGZF5I0Ryn6u5+I/hjST2WlbxBtpuha/w5/Xw0yZhD5PLQmVEphFAh29SfOC5dBLOIOlvVQDodwbFZ/JPizfo9yOlRGoDSGIyxTJP2/1wGkksV4Gg/4kUS+Eo55JtoKbQ/zKlQKopQOfdFN9pqPjjcFJR4um3D+6BA3wcVLJSHHfCTMvXxIRWoiGN0uA9JcuVi6cQP6gCgKB+JSuN9WvL7Tz6WkH5jCfcltN3lALRU4BExlBsgVc4l+aQ0LsqAPRpwvuc6hPwBtsW181xl2BbfcbF3nzTjIB5Gip+dYHiTVyf59KahjOBXV/vXL8S9isSUSOAZGxo7fLEP0QyPytn0J9tcN72XDLh99LnmoZYmxYDTpxtvnqJO6AAYkeAdeKK/6cg8bPkF2+rzH2N4g18/p5ihRNry2TU5ijWgEc8dZ8oZyDe5vNszyUT/wBiVzVpOt9TF2VAcAqQlM37Q3BkQ7UNsR4SOqicUBfvm7vnxf/fou1oJcflRj12YOqm3Rm1QMwjMXuSM9Kp+6sd8SR8G8WrcGy9yk6B93hCg+INNtf5zr/5c0JDte0H7DD1W6u2MQbc6anLfAwlUTs/fAVHB0KjxDs5TXDqLPe2DfBtfFYqAxBvD0G/0dBtrAubcmnEN8upN9QoxoBrPXVZn819qLB4O1BNTileTXLqCbTJPAKyGjA1IuYg4v9VevhyCo6AmGXQ3UxYgtuUEvXVpDsitIfY1O8ryGmTkqnTiMOhdjEGLHY+DygDSNCGdsyDzHXEnlI2uDfnRaEGQQNI5geKB5XcuV+ALyo7Ysxboux4Hr4Ev1ByPA/uVAt9M+Si/t5gLby1SchmeAeJn1CH0NGXowg7SjFe/qFpj9HGd1L8uZx0kcBouFnJ1LJt9R9Zbqx54KIZcKmg+oGESo7KAJUclQEqOSoDQgG2YYGL4b7a8IHluqiWbLbaMwA8p+QHC3n/5qdIWK6Py//67ALEGPCEhi+CuccYMFPDF7NDAbGvxiYqOWuP0fDATriAA9afocDqMKSSozJAJUdlgEqOygCVHGcBAAD//86LCCAAAAAGSURBVAMA3IvwK4+AgdMAAAAASUVORK5CYII='
        'undo' = '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'
        'undoW' = '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'
        'text' = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAACV0lEQVR4nOyaz2sTQRTHv293lWIEMeAP8CB40T/A/0CoVkHQ1h+Xngq2/RtEj4IHD+IhbVEPhfZQsUhKiaAXRTwJ4smDIAh6UaK0FjGa7PPtFiSmScaEGUh573PYnZ19M/vmk93JHCaCciIoxwRAOSYAyjEBUE7iChgeHy8ktcIEM07I5R54gsFFIuzPy4zPBPoKf6xJp0+TGt9bWZn70S3QKSCq7R6TFG9Lst7grN/sgM1OCXxAhIB8PoTobGOIq1Ja7Bbm/AQkuVPwTTb45sFmZY9jb+p3xBXingOY98EzbcfKCAAddEXYJIg+oISKq4ulb+iT02NTk/IazDTXyRwwWVmanUOfnLwwUYxpR7XHZvYGmAAoxwT8R0yjtSLeqNUxYEQ7d23JSVaYv53tXAEgftbS6ety+f53DBiVhTvrkt2b5jpZWjx3tXMLqKfz8hf1SDpbZ+YXKdJrGFBSjq7LqF9KnmtZzo3417yrjXMdUFm++1FO57ANePygVJZTuZc2NglCOSYAyjEBUI4JgHJMAJRjAqAcEwDlmAAoxwRAOSYAyjEBUI4JgHJMAJRjAqAc9QJCbE/MGbk4dZMYl+QJh7fczDdKtlRxh52ijA9MWKgszVxFAIIIGB69ciyJo7cdA3oRsHmP6ymOPnk4+w6eCfIJyOAvwyMihuKIRhGAIAIKXL0hP1uXbTSc77X5e9XmjfgnmrHxZW96CwEINgecOT99JE3SaTAd7xAyBOJDeYnpkxx/to0ifhXVo9Lqcuk9AhBMwHbB1gFQjgmAckwAlKNewB8AAAD//1N9K/QAAAAGSURBVAMAL5OlPTp+1hIAAAAASUVORK5CYII='
        'textW' = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAABsklEQVR4nOyaPUvDUBiFT4qIICJUFMHBUUcH/4GLjuKg4ODgoP4G0d1f4CRIQWfp7KKIkyBODk6CLiKCH4j4wfWEdiptb5rkQsJ5Hzi8abi3vXmam7TkViBOBeKYAIhjAiCOCYA4fb4GzrlBlnVmjhlGflSZseb2E/OC/HhlTpmDKIo+uzWM4IEC1lgOUU5WKeC4W4MkU2Ae5WXB18A7Bcgoysu4r4HdBZCOapQB9t9s854bUQbYfwQpsDMA4pgAiJPkNvjXZt8vike7Mf3AQ5Iz4Kzl9TUvuu8oGBzTG8tNy+5zX78kAmrMCRN/wAWzg+Kyy1yi8V8gHnPN18E7BWj2gWURJYBjrbPUe+ljdwGIYwIgjgmAOCYA4pgAiGMCII4JgDgmAOKYAIhjAiCOCYA4JgDimACIYwIgjrwA70rRtDjn9liWmUlk45454pPfbQQgiAAe/DTLLfLDMVOUcIecCTUFVpAv8Re1hACEOgP6WZ6ZIeTDBxqLM71rfnolySKpnuFAvylhhptbzGyHZgPMRHP7kfnq0O6K2Q9x8DHBLoJlwX4HQBwTAHFMAMSRF/APAAD//8TyYGYAAAAGSURBVAMAd50/LahArqEAAAAASUVORK5CYII='
        'check' = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAADcklEQVR4nOyaTUwTQRTH3wwk4s2bB28KiaEnA0VMjIKitpUbtoSTiYm04EVPGKPxIFHixcREoCRePbRwpJRERKOEkBRv1BiLZw8eNaKGGd9rS+3HutuW3brb2d+J/Wr4/+bt7M7MclAcDorjCgDFcQWA4rgCQHFcAaA4rgBQHOUFtEKT4R8e62VS9oDksUR8+ovR+QyaiEAo/AwjjWc3JPwQwE4k4zMf9a5pmlvAH4o8L4QnGBxkTNwxuq4pbgEKj6V8DerA8QICocgs/CO8lPyh0fWOFpAr+8rwEuRvATywbHD/E44V4A9Gpple+NjMy2p+x5ECsuEZjJXvrzU84TgBZoYnHCXA7PCEYwRYEZ5whACrwhO2F+APhZ9gb29JeMLWr8K58Oxm+X4p4acZ4QnbVoBeeHzRv4Th34AJ2FKAUfiluDnhiaoEDAYjRwSDIdgVG4mFuQ2wkEAw/Bi0woPcQQGDyflZ08IThvMBF4dGj7dy/p6Gl/l/ZToRi94AC8CWn8KWn9A6JoQcSM5HV8BkDDvBFs7v/Q1PsPH8IMRUAsHII63wVPZSsj4rwhN1PQVoEELPZjAJCo8/ert8vxX3fDmGAnaFeKC1n15MsGSfwj5BkZNa4WlKizPhtzI80WJ0wvaHza9HPd41BnIES7TkfNw+2d7ZfTiTTi1CHWTLnkHFtFW+5X2JePQ1WIyhAGJ7K/X5mKdnXVMCA2+7p+tQZmtzGWrgf5Z9MVUJIHQlAOutRQJOY93Hi+5WHMCyp5ZvVHiiagGEkYSOzu62T+mUbm+N/cYEnjtZcSA7jS3PJ+Oz76CB1CSA0JOAFk7rSciHn6o4UAgfXYcGU7MAoiBBwjD2AaVvkyihvbNLZtKbJWVsx/BEXQIIktDh8b7FP0fKJTDG+rFP2ME+YY227Rqe2PfSmO9KpI9zWNU6JoW4BZwdsGt4wpS1wcuh0X4J/FW15+cGNvJCMj7X0A5PC1MmRBZjc6sMxLncY0wfDP8dvQ/YITxh6uqwPzh2Fp8OS6WDpyJsUvbFmL48jkvUZyTAMt73bcX7qeWx7H12afk9LPk+wBcMn+LAVvYqAV9vvzEh+xML0RTYDMs+kPANX/cy0fIC4/9iAq7aMTzRVF+I1IP7lRgojisAFMcVAIrjCgDFcQWA4rgCQHFcAaA4ygv4AwAA///KOC8qAAAABklEQVQDAF53j/otffKsAAAAAElFTkSuQmCC'
        'checkW' = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAACrUlEQVR4nOyazWoUQRSFzwRFfAPBF8jWhagrE038iQ8hZCOJGOLKUVE3gqMbF2Jw49ZHUAR/EAQ34lZ9D0WTLCbn0BUyGWqmunuqZqq76oPiMnO7p+ucvtXdVT1zSJw5JE42AImTDUDiZAOQONkAJE42AImTDUDL6Pf7Z9k22E6U2b6DFkHRLxnWzcd/bKc6nc7vcfu0pgIo/jUOxIvjbPdc+x1BCzDiV1GDxg8Bin/FcGNEet41BBpdAWPO/C7biku8aKwBFL+F8eI/oASNNMCIX7OkKokXjTPAp3jRKAN8ixeNMSCEeNEIA0KJF9EbQPHPEUi8iPpR2IjftKS24UG8iLYCHOIvU/wXeCBKA6YlXpQaAuzQSTPHPoPA8BjPYBf/n+2aT/HCORlih+YZfqCYXootduImAsBj9RjujEgv8bgf4ZkyFfAAB+LFupmEeIW/+QR28Sr7hRDiRd27wKq5N3vBiO9aUt7H/DBlh8DPEekX7NwGJoC//5jhviWlJS2N+c8IiLMC2IFfDMsoHjyGuTVJJZgzbxOvM381tHhRagiYB44V2E1YM7etSsyy7AcpfQ1wmLBZxQRu+wh28Sr7qYkXldcE2fklhrdsRy3pHjt/17G/rvQ9S0riL3L/b5gitRZF65oQm3hR6zY4MBy2LekuhT4c/jJG8WKiZXGKOs/wnu2YJd2lqKdmuyjFi4nfC1DcAsOo29VtFOZEKV54eTFCExYZPlXYRRObZYr/ihnjZUHEPLBcQHFWXfxFMbGZuXjh9dWYuSa8w+HJ0yBRlP0gXpfEzAPMFRQlPozO/KWYxIsgL0dZCecYNH3dr4Q/bIsU/x2REeztME04zfCGbYfteoziRav+IVKH/CcpJE42AImTDUDiZAOQONkAJE42AImTDUDiJG/AHgAAAP//Mt/wAgAAAAZJREFUAwDBsxEM5eTNfwAAAABJRU5ErkJggg=='
        'files' = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAADn0lEQVR4nOybS2hTQRSG/zNJfCMoKIIgiILWiA8QRBERN2kjuNEk4AtFbKMg6koQQUXdi4qkdeEDX2kEEbSt4ELEjfh+1IIPcKF7rdiWpr3Hcy293EdrNSZt0plvkcycmbs4/8yZO/feMwqao6A5RgBojvYChIfqUJOqnQOmBcwUVYRx+Fcs+sJjw43NV8+0owwZVIBYqm5xiOk6GFV2nQiFoRiU794kpbUoQ0IDGauT6QMh0C0pTkNRoNlzo8usj61PH6LMCIxrdWL3ekV8G0WGGT1KqUV3s+faUEZ4FsF1m3ZPIfB5lAAJoTBbvddQZnjWAM5bO4hour+TjN4DEeaJeNGBv4SBiEyvQx4j0ZL4xrrDTTfrT6BM8AoArPDHhAXe2pKrv4ICiCfT3fJ31GNUdDyeqL3dlGt4gzLAEwIEWuWuiyCfWxoLc96mqTFzTGbP62ALXUaZ4MyAms17JyOfn+FpZX6P/8RSvE1upy89RjsUkumslEqyIFqMLiJuBfG75mzDpz/1dQRQ3BNiFJ972fpX4uwxKR7xNSVRItTvOJYfJjsM28BWarCQc0LgZ0dn0H+REUVAQuHowKEwLFSB1Ot4om7fQI2OAGMjocBzAQ2yUSoEOxTsvQBGCqJTIkK13+w4HY6MCYw2M1soEnYoiKC7MKLQhVhi51S3ZciHoWLSlMtcjCX2PFKwUrIxiqBUME+Q6btcHF7tsRNmhBDZIqXT/aZhFcDmXu7cR/k7iWEgnkhvF6cvuG32XgcuAUb1+wB7xkkYf3HbiHmluz7qX4hIqH3wGWatSeyZ1F91BOjJd1PwYqp4geTOE1jIJ0bYWX/MO0FojhEAmmMEgOYYAaA5RgBojhEAmmMEgOYYAaA5RgBojhEAmmMEgOYYAaA5RgBojhGgv9CLUG+gVT6touIJZjlbFHZ8dQS4n2v4Lg5/c3cU72ei8vH4IGP63Z257gkBBj131+Xr8PzYhl1RVCg1G9JLZfzn+cyP3RVvhgjhBbxp7Up4WJOsO0+gLlQQMnvHE3OtPx+cfIPsTZVVOAuL09JponMBkZ1UdBAVRl+qoC/8mX8o0Fm3yRMCLTcyn0c+k6t0MPG2O7nMV7ctkAf4ofXZ2znRZe0iRAyjCeb9zbmGS37zoAdh1qXSC+Um2Aj0HZmpYNokEpJ3s5m3AzUOeRLIPjTFVihKZFXJ2jAeFQCDO5lVG6ne1qGSpQs9CjVqMFthaI4RAJrzCwAA//+TEqbZAAAABklEQVQDANRMC/wxK1b4AAAAAElFTkSuQmCC'
        'filesW' = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAACzUlEQVR4nOybz28NURTHv/OQKCJhIRKJEAuqUqyEhYSVlWW7oWHB1o+lEBXsxdaiFhLRlf4FRGxEQlst4kfSBbFVEkTK8z0Zb3Lf6X2dtm/mzbw595OcnJlz58275/vumTc/7tRgnBqMEwSAccwLsDJtg3q9voNuN62PthpL5xNtNIqibyghUasGJr6X7j6tF+3ziAIcRQnxlgCTv0A3jmySF45wn1dQQuaNAHb0ON0YsmeO1s+R8AYlokkAJr+B7i1tE/JhnALsR4nQB8HT8Cf/mPac9gOLZxXtkorto8iXKcINlAQtwEHPNifZ4XtYBkz2N92wCl9nfIz7fIUSoEvgC91mJzTDjm5HG3CfE3T9KlyaUkhGADu6Hs3JC+/QPkOI/1FcpBQe0Od1QPxFm6a9ptAfF9rQLYEVyAF2YILJXuPiVdU0gA7A7xaRB1uVnHseUPd9HhnALx+mm0QxyLnMJIU452ustVhukOWokFKYQ3HcogjHdDBtBPxFRkgp0J1BsYxQhI1uIPViKEsowl124CkXBxGfJ+TFGtoB2mEVl4P8CdrtRqCjAggU4QPdTXQAin2KbkSF5VwnEaDS9wNkxCG+HHc55K5YuCHyXq1v5chY11hxS8B3b6AKAvkO5MnxJ9wThHGCADBOEADGCQLAOEEAGCcIAOMEAWCcIACMEwSAcYIAME4QAMYJAsA4QQAYJ0yWdpb/eNozmSJTML5nnkmuyQjgo+RZuq9qwy3ofnQOs+7MdV0CL9T6Lj5K7kOXwr7LXMSdKvzMXdEzRF7S3GntItAT7ugO4rl33UQP7awn3vQj65mi2+imaGtRTb7TelkCnxuBphJgwwyKn8mVJ0Nu8sK8v0FuIG+JXET1OM/cHurgQq/M7KEbRXZvjRSFTJUdYPJTvsYo7dP/X5qSfwIRogfdwU/EiU+nTZZOFaDqhGsBGCcIAOP8AwAA//8YxeIJAAAABklEQVQDAG3tqEdQcuWRAAAAAElFTkSuQmCC'
        'install' = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAEmklEQVR4nOyaW2gcVRjH/2f2ZpNabYO3gojgpVBEbZGCaNOLJGwCNUo2orVSL6QG8cXLi099ESGKCkXcVrCF0ApdSyVps9hSk9S0tQ+1D5IiSEofBKPVdJs0yd4yn9+XdCG7M9vs7sxmEmZ+kOzM952Z833/c2bOmTOjweVocDmeAHA5rhfAD4cIR16/SyHULNuE1PF4bP9VOICCA0QikeANVXeVK18h+0R0fTlG747FYmksMI5cAhNYtSWXvKCUumOc6p6GAzhzDyD1gMGm9EfgAN4oAJfjCQCX4wkAl+MJAJfjCQCX4wkAl+MJAJfjLYnBBsJt7R8paB8QaCCQzLzW3f3tOKrAtm1v3J4NBbp4BWUjSP+kN7bvU1jEcg8It7Y3cPIf8+ZKBdXCAZ6WQGEzN5M/zck/L3VBaZ2NbR3PwSKWBVCa9mG+QT2RCQUHNrXsvBM20fxKx8pMKHBGzj3X7iP9fVjEsgCk42ShTSk8WRMI9dkhgpxDz+g/87rhYybuk7CIZQHi30c7iTBgcHBriQjSeqgQObYmGOrn5NcavdTXG9v7OSxiyyiQwLIwL20PGhwsgrReJT0h1/J8kscLfVLXNapphg3YIsC52BdTCdQ0cGTnC33SessCocFyRNj6wjt1coxZy0vyUpfUCRuwbR4gAWVvm9xqVQRJPuifPmPa7fncdiY/ExtspmHHjlp/suYUZ72h0MetN5TO+utDvulWlj4616eTviuTDRyZTR6PwnjweRH4RFfXBGzE9pmgBCiB8qTo10KftKokqBPVGg7UUVsseTlXNZKfiQlVIrz93RXIpPt4crTO4CT6m9W4J99EIyzQvYaiImQguDl+cM8YqkBVX47OiJBODxrGcDLWzAJIDykoVt3kgQV4O9wYeXOVT/l/yhvOShCAdy9OZZJb+n84kEAVKSrA3Pf3qayv59TRr/5DhciEhjL6Wc5wzYxhHgF4+zctoNUfP/T1NVRIqfGb3wR372Z78A8Ocr/8Bf3Z4VlbZUgihPRGTuzSfGUleR4pNltJvpz4TY3hoZFN8s4+ty/bTZf+egYWkC9A/H6q5wx/L1qIfdLyVnqbUE78pgIowsOFNh661sAiPd/t+9fnp2f55vansVJcEZ+lls+dqoz4F3xFSESYmkg9xV09lbPx5Z+6npjcID4sMI4sifX3HhhJjI2u5pvhIdLp4Pjk2H1nT3T9Awdw7Cuxcz/GRvlnOxzGWxWGy/EEgMvxBIDLKSKAmsYSRlc6Ga3mOZkKQIouGwoqbTWWCJpS9xuMpIZNy5oZM9AvGK30Mhz6urwsZp/62grNyeXJX8yKF02oKfL2Ffbmf9RMuMC2Y1jUUEvhuwR++BqOH977kFnpolNhvog+Y3X25BkV1vP/9VjUGNuUH7w6Sy89h6bIrmP8MG3LGxin4CfNo/FY9MVi/lsOg5OZ1KvcfXqwROHkuxEM7LxVmZJuak2tHW+Rpn/JS9y1WAJw4jc4s/fih6PfzFe2rLt640vt63y6tpZ7xYO8zLSoJlF8neukcFlNq6H4kejFUo9b/MNalfGmwnA5ngBwOf8DAAD//0qrTWIAAAAGSURBVAMAlRjNgyQs86kAAAAASUVORK5CYII='
        'installW' = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAADWklEQVR4nOybO2gUQRzGvwsiSPAZfAVEBB9BCT5ABFFy8SQgASO2WtiojZ3Y2NuksLGz1zZitLK4PAULDSKiCJEUFj5jFMUH6Pn9uQGXzeze3s3szV1mfvCxl5nZmfl/M3e7O7PpgOd0wHOCAfAc7w1YBkdUKpX1PAyqP+8XCoUPcEABDmDwy3mQgFeppC/UBprwG03G1VfgGP4HL6ymDsMBrgzYqknbCQeEqwA8JxgAzwkGwHOCAfCcYAA8JxgAzwkGwHOCAbAAV3iuUvPUCLUSOSF1U3dUW1dgAWMD2JEBHq5Ra6lT1EQeJqg6J6gh1dYw047DEBszID4S+6hxdm4NLMG6JOBpVXeUyzDEhgEPNGn7qbINE1Qdk1QvsrVdF8YGcCV3mIdxTZaMVlmNXkOoc8eoPZrsMtu+DkNsXQVOUFOadDFhspGZEBn5vZpsaWsQFrBiAEfiBw/yY/hIky2jN1WPCSzbhWqQupGX9AHVpjHW7gNUh0owNEEFPw198FK3teAFqzdC7Nh31DahK+n8SPC7NNlSZ8lm8IL1O8GICU802WKCBNipyetEcvBSV0nVbZXc9gY5mrL1VaYOaLLfURtjaW+pTZqyEnw/g/+KHMh1c1SZID9avWiMXIMXcn0YUh0vUk9RPzOoTvvcghcSZ0Bs/36UHfmEBlE3NA+pnoynPKP62OZnNEjW/hcSTpaZMY/qtrUg+/frWMlfmHVojNpdo6gE329oeOb+J30FipGToT4fgQHqDZA+6mVKMcnrMwleUUTG/icZsEOTlnX6JsLAPvJwlHqjyZ6TPJNpHyFz/5u+IqRMOEj9iiTL50Mqr6k4WRJjoHLN76ZuU7eozUx7Dwc4e0uMAcuP1Bk4JiyKwnOCAfCcYAA8J+ky+AftTUWTpo0pyYDXmrRutA9bNGmzuoJJT4Py8LAQS35F9fAGRuduy6CeBF9g8bvHK9j3n/HyaesBc1j8UvNj6h5aG9mfjO8lzDL47brCaQZc4uEGlgYXacBNXUbqmiBNkNG2sgPjkBEGfzops9Zl8Cw1ivblLnUurUCqAXRugTrJj+cp62vyOfKNusC+D9VaVK1rWZxfCVnjl82NbWi9myhZ75PL93MGPZP1JCf/NNVKhGcBeE4wAJ7zDwAA//9vOEjWAAAABklEQVQDANfN/8cCskU8AAAAAElFTkSuQmCC'
        'history' = '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'
        'historyW' = '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'
        'contrast' = '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'
        'contrastW' = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAFR0lEQVR4nOSbeYhVVRzHf89Ki2wbwxZaqYgisgXCQktJsRJriqbQdohMMimCMgyMlCyTKEiijKDF8o8siYZIYSrSMgvBCBGDCiJpKJss20bt9fl574z3nXfufu/z3TNf+HK4Z7n3/L5nvWcZJkMcw2SIY8gLcKC0APV6fQrOeHgcHO3zTHg4rMHd8F+4E+6AvbC7Vqs9KSWjJiUAg4fjTIbXw2vgUZINdfgNfB0uQZC/pWAUKgCGawnPg7fCw6R4bIIzEGKzFIRCBMDwo3EehrPgIVI+NsDpCPGt5EQuATD8SJy5cI60xnAT6+ENCPGDZERmATB+DM774nVsUdB2+zFcA9fBbfAK+KIUgz3iifC2ZECmUQDjr8RZKdGlvgy+RcZWW9IX2fccoHnhnfP41uOSEqkF4EN34rwg4XOId+BcMrM14jVljD4LydtJfPfuNIlSTYT4wALxStaWbi0cSwauizF+76ukeKioM8ljT5pEiQXgxdNxHrEFwfkYPR5+LslQyvzDx0TyujRp5EQC8MKxOK9YgvphJ4Y/Ju2FWeR5ZpKIsQLwolNxuuFBRtCvcBzGvyvp8Z+UC61hz5P3S+IiRgrAC3Q29wHsMIJ2wakY/4VkQyt+wlSEHmwYLTky8gQ8w+J/G8avl/bHCPEKMBShAqDcyTi2drQY49+U6mAMtowLC4yqAU+JN8kIYjPGPyTVgjaF18ICrQKg2Pk4XZagVJOMNsIp2HStLSCsBjxn8VtF6X8i1cUym2eTACh1Fo45fGivP0eqjVHYNsH0tNWAqyx+z+T55WwjzDY9bD9DUy1+z4obmGB6NNQAqoj+3l5qxNlK6f8obqDDX70ahNkEtPqbQ98acQc6JN4X9DCbwIWWRC4JoGiYFJkCHG9J8JW4hWODD0kEcKH3D6Lhxy5OgJ10gLvFLYwMPsQJ8JO4hxHBh8FRgOFBe39zC6tX3EMNWw8eeAjWANus0MXdYx0KB1ekBg2kret8v8+IfIy4hzq29g88mCVsVvkTxD30Bx9MAcxObzjtZaS4hT+DD3E1QOFaM9gRfIirAYoLxC1sDz6YAmy0JLha3MKnwQdTgFXSvG83jX7AleFQbWs4d9RgGMPD7zjmut8R4h1wcgF92Lgt6GErWdtW1z3iBpp2jm0CrLT4ddEMzpXqY4Hp0SQAVeR7nNWWxIul2ujFtqa1jbDO7QGL3xRqQVX7Au38brEFWAVAqa9xVliCXkaEQ6V6+A6brEt7UcObnvvbY/idDqu0MarQ0u8KCwwVwO8LbEfZdF7woFQHm7BlY1hg3ARHd4JtB54WIcJl0v7QA9iToyJECoByf+DomcDfLOn0bN7Fkg1lH5FRaNWfhA2/REWKneL653F1u2yXETQKfoQIMyQ9yp5aq/F3kfe1cRETZYQX6Q/EHZYgPRa/HBEWFXz6My+WkueXkkRMXBK8cDnO/JBgPTD9ZZJTWT7KOCg5gB7yem/SyKmqon8e8CbxbniY0HWDdYiwwj9fFPkqKR4qqpb85WkSpW6LfOAN8XaQt4dEuRFuQYSFLZw0aad6O3mbnTZhps6ID32Gcx7cEhJF19315kgvInTD++E5Ug7+Ee+M8quSAXkvTKihut2sxiZdPNUhVUusQ/LjPQyfJjlQ1JUZHRIfFe8UWStuoundoU5/tpoLRV+aOg1nCeyUcqCrOTdj+IdSEMq6NneieIupOoGaKF6fkBU/i7eS8zSGb5CCUfrkxT93NAleJN7us+4zaPs/WxovTurdor9k38VJLWU9ndYnJaKdZm/7BS7u/qbCkBfgfwAAAP//6/2pvwAAAAZJREFUAwC18mXrBdzWagAAAABJRU5ErkJggg=='
        'pin' = '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'
        'pinW' = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAEJUlEQVR4nOyaS0gVURjH/0ZRlpVFb4ik9wuKwpBqUdAqwwoNicpqURa0M1q5CKJN0KoWkUIGuigSwUerFklUEGlBRS+026KHYmXZkx72/5gbyHiu9zxmusLMD/6c65nj+c755jxmvjMjEHFGIOJE3gEjEQD9/f1jmVRQ+dQyai7CoYN6RN2lTmdlZX2FI1lwhJ1fyaQe4XU6FZ1UMZ1wHw44OYCd38KkCZmlkE64CkusHcDO5zJ5Rk1FZummFtMJH2CByxpQBXXne6jH1B8EiyzYS6gpvvxp1FlqFyywGgG8+9LxbsWlEt6JeoQIbRczuaK4lEvbH2GI7Ta4QJF3IezOC0kbtYpLC2GBrQNUK77TamyIypbVLmS7BrxW5E3G/yNXkdcFC2zXgIlMen3ZsiPIatyPEKFtGbWyyPqHfDZtf4chLttggskcX3Yb1ezLk3JNbNw7mNUvC20hlee7tI1a4cvrYP3zYYGLA44wOaNZXFbnyWyk1taYvMvvqYnQo5x1n4cF1i9DNCh7b4tmcenIeuizAfqdb7DtvOD6Nrgb+o/Ci6DPPM1yjdQ+OODkAHq+lyrizwPUl3TFoU+6dn2mDtL2VuoTHAgkHsBGVFM5/LmaKoN3Z/yY7A6qtULq3CM2aGs8VYUACCQe8A82qp1JezI+UOS/DH1UN6aF9dciYOKQGCJO7ABEnNgBiDixAxBxAn0QGoDqocckSPpbs05nwnJAviLPJGLTo8hbhRAIfArwMbiASbHi0gvok1Dk7WDd+QiYwBzAxuVQJ/jzNga/y7/lc/xDaJI87vKH3SdRd8SG2EJAODuAjRlNHYV31ypTFKuGOTUp8sVGgjYrxDYccT0blDjAcWrWEMUeUOt4V/tgVreMolvU0iGKvaIqWXcNLLGNCksA8iK1Nk3RVqqUDbQKWdPObHinQGvSFL1BldFOAoYYO4CNWg5vng81DyVsfYwNakYA0OZ2JifhnQ2mQsL0BbT5FAYYOYANmcDkObwDSRUJeEOyDiFA+3vhTbm8FEVe0nYeDDBdBOUEVtV5OSk6RC0Iq/MC65ZpJ+eSh6E+nZpDJ+2HAaYj4CYGz3v5OGGna3DSlORWeIna7Lt0nW3ZCE1MHSCnOwPPAH9ROTT4AxmA7RkDLxo9cCR3sT0zdOvQngI0lo3BB6Btmeq8kDwLvOfLng4DTNaAbEWe0d4eEv5DWrlZk6BJ/DoMNzbR26Eeh4dN5EeA6S4gcz6wN7GQ6OPiOEG3sOkIaMTwp8GksOkIGAfvSLyEGgV7ZmLwJy7yic0b2POTukzVcgR80/2nUOJs6aAjy5mc82Vbf+XhQhwWR8SJHYCIEzsAESd2ACJO7ABEnLBOh9PR6vtbYgrXkAEy4gA+8z/h+8Ap/ixNZtUxrxMZICMvQ8OJeBFExPkLAAD//yTi7rUAAAAGSURBVAMAOdETdfaKR2MAAAAASUVORK5CYII='
    }
    $map = @{}
    foreach ($k in $b64.Keys) {
        try {
            $ms = New-Object System.IO.MemoryStream (, [Convert]::FromBase64String($b64[$k]))
            $map[$k] = [System.Drawing.Image]::FromStream($ms)
        } catch { Write-FixItLog ('Icon {0} could not be loaded: {1}' -f $k, $_.Exception.Message) 'WARN' }
    }
    return $map
}

function New-FixItRoundPath {
    param([System.Drawing.RectangleF]$R, [single]$Radius)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    $p.AddArc($R.X, $R.Y, $d, $d, 180, 90)
    $p.AddArc($R.Right - $d, $R.Y, $d, $d, 270, 90)
    $p.AddArc($R.Right - $d, $R.Bottom - $d, $d, $d, 0, 90)
    $p.AddArc($R.X, $R.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Get-FixItColor { param([string]$Hex) return [System.Drawing.ColorTranslator]::FromHtml($Hex) }

# Draws one tile. Everything it needs is in the button's Tag.
function Invoke-FixItTilePaint {
    param($Btn, [System.Drawing.Graphics]$G)
    $t = $Btn.Tag
    $S = $script:UiScale
    $G.SmoothingMode = 'AntiAlias'
    $style = $t.Style
    $hover = ([bool]$t.Hover -or $Btn.Focused) -and $Btn.Enabled
    $w = $Btn.ClientSize.Width; $h = $Btn.ClientSize.Height
    $hc = [bool]$script:UiHighContrast
    $clr = $script:UiBack
    if ($style -eq 'nav' -or $style -eq 'toggle') { $clr = $script:UiSide }
    $G.Clear((Get-FixItColor $clr))
    if ($style -eq 'nav' -or $style -eq 'toggle') { Invoke-FixItSidePaint -Btn $Btn -G $G -Hover $hover; return }
    if ($style -eq 'logo') {
        $lb = New-Object System.Drawing.SolidBrush((Get-FixItColor $(if ($hc) { '#FFFF00' } else { '#0F6CBD' })))
        $lp = New-FixItRoundPath -R (New-Object System.Drawing.RectangleF(0, 0, ($w - 1), ($h - 1))) -Radius ([single](12 * $S))
        $G.FillPath($lb, $lp); $lb.Dispose(); $lp.Dispose()
        if ($t.Icon) { $G.InterpolationMode = 'HighQualityBicubic'; $ls = [int](24 * $S); $G.DrawImage($t.Icon, [int](($w - $ls) / 2), [int](($h - $ls) / 2), $ls, $ls) }
        return
    }
    $col = Get-FixItTileColors -Style $style -Hover $hover -HighContrast $hc -IconBg $t.IconBg
    $fill = $col.Fill; $line = $col.Line; $lw = $col.LineW; $ttl = $col.Title; $sub = $col.Sub; $ibg = $col.IconBg
    if (-not $Btn.Enabled) { $ttl = '#8A8A8A'; $sub = '#A8A8A8'; if ($hc) { $ttl = '#999999'; $sub = '#999999' } }
    $half = $lw / 2
    $rect = New-Object System.Drawing.RectangleF($half, $half, ($w - $lw - 1), ($h - $lw - 1))
    $path = New-FixItRoundPath -R $rect -Radius ([single](12 * $S))
    $br = New-Object System.Drawing.SolidBrush((Get-FixItColor $fill))
    $G.FillPath($br, $path)
    $pen = New-Object System.Drawing.Pen((Get-FixItColor $line), [single]$lw)
    $G.DrawPath($pen, $path)
    $br.Dispose(); $pen.Dispose(); $path.Dispose()
    $tf = [System.Windows.Forms.TextFormatFlags]
    if ($style -eq 'yes' -or $style -eq 'no' -or $style -eq 'btn') {
        $cf = $tf::HorizontalCenter -bor $tf::VerticalCenter -bor $tf::SingleLine -bor $tf::NoPadding
        $cfont = $script:UiFonts.Big; if ($style -eq 'btn') { $cfont = $script:UiFonts.Title }
        [System.Windows.Forms.TextRenderer]::DrawText($G, [string]$t.Title, $cfont, (New-Object System.Drawing.Rectangle(0, 0, $w, $h)), (Get-FixItColor $ttl), $cf)
        return
    }
    $flags = $tf::Left -bor $tf::NoPadding -bor $tf::EndEllipsis -bor $tf::SingleLine -bor $tf::VerticalCenter
    if ($t.Wide) {
        $isz = [int](($(if ($style -eq 'scam') { 44 } else { 40 })) * $S)
        $ix = [int](18 * $S); $iy = [int](($h - $isz) / 2)
        $tx = $ix + $isz + [int](14 * $S)
        $r1 = New-Object System.Drawing.Rectangle($tx, [int]($h / 2 - 24 * $S), ($w - $tx - [int](12 * $S)), [int](24 * $S))
        $r2 = New-Object System.Drawing.Rectangle($tx, [int]($h / 2 + 1 * $S), ($w - $tx - [int](12 * $S)), [int](20 * $S))
        $f1 = $script:UiFonts.Big; $f2 = $script:UiFonts.Small
        if ($style -eq 'scam') { $f1 = $script:UiFonts.BigScam }
    } else {
        $isz = [int](36 * $S)
        $ix = [int](14 * $S); $iy = [int](12 * $S)
        $r1 = New-Object System.Drawing.Rectangle($ix, [int](12 * $S + $isz + 8 * $S), ($w - 2 * $ix), [int](20 * $S))
        $r2 = New-Object System.Drawing.Rectangle($ix, ($r1.Bottom + [int](1 * $S)), ($w - 2 * $ix), [int](18 * $S))
        $f1 = $script:UiFonts.Title; $f2 = $script:UiFonts.Small
    }
    $ib = New-Object System.Drawing.SolidBrush((Get-FixItColor $ibg))
    $ipath = New-FixItRoundPath -R (New-Object System.Drawing.RectangleF($ix, $iy, $isz, $isz)) -Radius ([single](10 * $S))
    $G.FillPath($ib, $ipath)
    $ib.Dispose(); $ipath.Dispose()
    $img = $t.Icon
    if ($img) {
        $is = [int](22 * $S)
        if ($t.Wide -and $style -ne 'scam') { $is = [int](22 * $S) }
        if ($style -eq 'scam') { $is = [int](24 * $S) }
        $G.InterpolationMode = 'HighQualityBicubic'
        $G.DrawImage($img, [int]($ix + ($isz - $is) / 2), [int]($iy + ($isz - $is) / 2), $is, $is)
    }
    [System.Windows.Forms.TextRenderer]::DrawText($G, [string]$t.Title, $f1, $r1, (Get-FixItColor $ttl), $flags)
    [System.Windows.Forms.TextRenderer]::DrawText($G, [string]$t.Sub, $f2, $r2, (Get-FixItColor $sub), $flags)
}

# Sidebar rows: a plain row (nav) or a row with an on/off switch (toggle).
function Invoke-FixItSidePaint {
    param($Btn, [System.Drawing.Graphics]$G, [bool]$Hover)
    $t = $Btn.Tag
    $S = $script:UiScale
    $hc = [bool]$script:UiHighContrast
    $w = $Btn.ClientSize.Width; $h = $Btn.ClientSize.Height
    $cText = '#2B3340'; $cSub = '#566070'
    if ($hc) { $cText = '#FFFFFF'; $cSub = '#FFFFFF' }
    if ($Hover -and $Btn.Enabled) {
        $fill = '#FFFFFF'; if ($hc) { $fill = '#1A1A1A' }
        $rr = New-Object System.Drawing.RectangleF(0.5, 0.5, ($w - 2), ($h - 2))
        $pp = New-FixItRoundPath -R $rr -Radius ([single](8 * $S))
        $br = New-Object System.Drawing.SolidBrush((Get-FixItColor $fill))
        $G.FillPath($br, $pp); $br.Dispose()
        if ($hc) { $pn = New-Object System.Drawing.Pen((Get-FixItColor '#FFFF00'), [single]2); $G.DrawPath($pn, $pp); $pn.Dispose() }
        $pp.Dispose()
    }
    if (-not $Btn.Enabled) { $cText = '#8A8A8A'; $cSub = '#A0A0A0'; if ($hc) { $cText = '#999999'; $cSub = '#999999' } }
    $G.InterpolationMode = 'HighQualityBicubic'
    $img = $t.Icon; if ($hc -and $t.IconW) { $img = $t.IconW }
    $is = [int](18 * $S)
    if ($img) { $G.DrawImage($img, [int](12 * $S), [int](($h - $is) / 2), $is, $is) }
    $tf = [System.Windows.Forms.TextFormatFlags]
    $flags = $tf::Left -bor $tf::NoPadding -bor $tf::EndEllipsis -bor $tf::SingleLine -bor $tf::VerticalCenter
    $tx = [int](42 * $S)
    if ($t.Style -eq 'toggle') {
        $sw = [int](34 * $S); $sh = [int](18 * $S)
        $sx = $w - $sw - [int](12 * $S); $sy = [int](($h - $sh) / 2)
        $r1 = New-Object System.Drawing.Rectangle($tx, 0, ($sx - $tx - [int](6 * $S)), $h)
        $flagsW = $tf::Left -bor $tf::NoPadding -bor $tf::EndEllipsis -bor $tf::WordBreak -bor $tf::VerticalCenter
        [System.Windows.Forms.TextRenderer]::DrawText($G, [string]$t.Title, $script:UiFonts.Side, $r1, (Get-FixItColor $cText), $flagsW)
        $G.SmoothingMode = 'AntiAlias'
        $on = [bool]$t.On
        $track = New-FixItRoundPath -R (New-Object System.Drawing.RectangleF($sx, $sy, $sw, $sh)) -Radius ([single]($sh / 2))
        if ($on) {
            $tc = '#0F6CBD'; $kc = '#FFFFFF'; if ($hc) { $tc = '#FFFF00'; $kc = '#000000' }
            $b1 = New-Object System.Drawing.SolidBrush((Get-FixItColor $tc)); $G.FillPath($b1, $track); $b1.Dispose()
            $kx = $sx + $sw - $sh + [int](3 * $S)
        } else {
            $oc = '#8A8A8A'; $kc = '#6A6A6A'; if ($hc) { $oc = '#FFFFFF'; $kc = '#FFFFFF' }
            $p1 = New-Object System.Drawing.Pen((Get-FixItColor $oc), [single](1.5 * $S)); $G.DrawPath($p1, $track); $p1.Dispose()
            $kx = $sx + [int](3 * $S)
        }
        $track.Dispose()
        $kd = $sh - [int](6 * $S)
        $b2 = New-Object System.Drawing.SolidBrush((Get-FixItColor $kc)); $G.FillEllipse($b2, $kx, ($sy + [int](3 * $S)), $kd, $kd); $b2.Dispose()
        return
    }
    if ($t.Sub) {
        $r1 = New-Object System.Drawing.Rectangle($tx, [int]($h / 2 - 17 * $S), ($w - $tx - [int](8 * $S)), [int](18 * $S))
        $r2 = New-Object System.Drawing.Rectangle($tx, [int]($h / 2 + 1 * $S), ($w - $tx - [int](8 * $S)), [int](16 * $S))
        [System.Windows.Forms.TextRenderer]::DrawText($G, [string]$t.Title, $script:UiFonts.Side, $r1, (Get-FixItColor $cText), $flags)
        [System.Windows.Forms.TextRenderer]::DrawText($G, [string]$t.Sub, $script:UiFonts.SideSmall, $r2, (Get-FixItColor $cSub), $flags)
    } else {
        $r1 = New-Object System.Drawing.Rectangle($tx, 0, ($w - $tx - [int](8 * $S)), $h)
        [System.Windows.Forms.TextRenderer]::DrawText($G, [string]$t.Title, $script:UiFonts.Side, $r1, (Get-FixItColor $cText), $flags)
    }
}

function New-FixItTile {
    param([string]$Run, [string]$Title, [string]$Sub, [string]$IconKey, [string]$Style, [string]$IconBg, [int]$X, [int]$Y, [int]$W, [int]$H, [bool]$Wide = $false, [bool]$On = $false)
    $S = $script:UiScale
    $b = New-Object System.Windows.Forms.Button
    $bk = $script:UiBack
    if ($Style -eq 'nav' -or $Style -eq 'toggle') { $bk = $script:UiSide }
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = (Get-FixItColor $bk)
    $b.FlatAppearance.MouseDownBackColor = (Get-FixItColor $bk)
    $b.UseVisualStyleBackColor = $false
    $b.BackColor = (Get-FixItColor $bk)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.TabStop = $true
    $b.AccessibleName = ('{0}. {1}' -f $Title, $Sub)
    $b.Location = New-Object System.Drawing.Point([int]($X * $S), [int]($Y * $S))
    $b.Size = New-Object System.Drawing.Size([int]($W * $S), [int]($H * $S))
    $icon = $null; if ($script:UiIcons.ContainsKey($IconKey)) { $icon = $script:UiIcons[$IconKey] }
    $iconW = $null; if ($script:UiIcons.ContainsKey($IconKey + 'W')) { $iconW = $script:UiIcons[$IconKey + 'W'] }
    $b.Tag = @{ Run = $Run; Title = $Title; Sub = $Sub; Style = $Style; IconBg = $IconBg; Icon = $icon; IconW = $iconW; Hover = $false; Wide = $Wide; On = $On }
    try { [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($b, $true, $null) } catch { }
    $b.Add_Paint({ param($s, $e) Invoke-FixItTilePaint -Btn $s -G $e.Graphics })
    $b.Add_MouseEnter({ param($s, $e) $s.Tag.Hover = $true; $s.Invalidate() })
    $b.Add_MouseLeave({ param($s, $e) $s.Tag.Hover = $false; $s.Invalidate() })
    $b.Add_GotFocus({ param($s, $e) $s.Invalidate() })
    $b.Add_LostFocus({ param($s, $e) $s.Invalidate() })
    $b.Add_SizeChanged({ param($s, $e)
        $rr = New-Object System.Drawing.RectangleF(0, 0, $s.Width, $s.Height)
        $pp = New-FixItRoundPath -R $rr -Radius ([single](12 * $script:UiScale))
        $s.Region = New-Object System.Drawing.Region($pp)
        $pp.Dispose()
    })
    $b.Add_Click({ param($s, $e) Invoke-GuiButton -Which ([string]$s.Tag.Run) })
    $rr0 = New-Object System.Drawing.RectangleF(0, 0, $b.Width, $b.Height)
    $pp0 = New-FixItRoundPath -R $rr0 -Radius ([single](12 * $S))
    $b.Region = New-Object System.Drawing.Region($pp0)
    $pp0.Dispose()
    return $b
}

function Add-FixItLink {
    param($Form, [string]$Text, [string]$Run, [int]$X, [int]$Y, [string]$Color, $Font)
    $l = New-Object System.Windows.Forms.LinkLabel
    $l.Text = $Text
    $l.Font = $Font
    $l.AutoSize = $true
    $l.LinkColor = (Get-FixItColor $Color); $l.ActiveLinkColor = (Get-FixItColor $Color); $l.VisitedLinkColor = (Get-FixItColor $Color)
    $l.LinkBehavior = 'HoverUnderline'
    $l.Location = New-Object System.Drawing.Point([int]($X * $script:UiScale), [int]($Y * $script:UiScale))
    $l.Tag = $Run
    $l.Add_LinkClicked({ param($s, $e) Invoke-GuiButton -Which ([string]$s.Tag) })
    $Form.Controls.Add($l)
    $l.Update()
    return $l
}

function Show-FixItWindowOnce {
    param([bool]$FirstTime)
    $S = $script:UiScale
    $px = [System.Drawing.GraphicsUnit]::Pixel
    $hc = [bool]$script:UiHighContrast
    $cText = '#1A1A1A'; $cMuted = '#616161'; $cLink = '#0F6CBD'; $cFaint = '#6B6B6B'
    if ($hc) { $cText = '#FFFFFF'; $cMuted = '#FFFFFF'; $cLink = '#FFFF00'; $cFaint = '#FFFFFF' }
    $script:UiFonts = @{
        Title = New-Object System.Drawing.Font('Segoe UI', [single](14 * $S), [System.Drawing.FontStyle]::Bold, $px)
        Small = New-Object System.Drawing.Font('Segoe UI', [single](11.5 * $S), [System.Drawing.FontStyle]::Regular, $px)
        Big = New-Object System.Drawing.Font('Segoe UI', [single](16 * $S), [System.Drawing.FontStyle]::Bold, $px)
        BigScam = New-Object System.Drawing.Font('Segoe UI', [single](17 * $S), [System.Drawing.FontStyle]::Bold, $px)
        Side = New-Object System.Drawing.Font('Segoe UI', [single](13 * $S), [System.Drawing.FontStyle]::Regular, $px)
        SideSmall = New-Object System.Drawing.Font('Segoe UI', [single](10.5 * $S), [System.Drawing.FontStyle]::Regular, $px)
    }
    $form = New-Object System.Windows.Forms.Form
    Set-FixItFormIcon $form
    $script:Form = $form
    $form.Text = 'Family Fix-It'
    if ($script:DryRun) { $form.Text = 'Family Fix-It (practice mode - nothing will be changed)' }
    if ($script:TestMode) { $form.Text = 'Family Fix-It - TEST MODE (nothing will be changed)' }
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.BackColor = (Get-FixItColor $script:UiBack)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', [single](14 * $S), [System.Drawing.FontStyle]::Regular, $px)
    $checkIn = 'off'; try { if (Test-FixItTask -Name $script:CheckInTaskName) { $checkIn = 'on' } } catch { }
    $gOn = $false; try { $gOn = [bool](Test-FixItGuardianInstalled) } catch { }
    $simple = $false; try { $simple = [bool](Test-FixItSimpleMode) } catch { }
    $lay = Get-FixItLayout -Simple $simple -GuardianOn $gOn -BigText ([bool]$script:UiBigText) -HighContrast $hc -CheckInOn ($checkIn -eq 'on')
    $fullH = [int]($lay.FullH * $S)
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $clientH = [math]::Min($fullH, ($wa.Height - [int](50 * $S)))
    $extra = 0; if ($clientH -lt $fullH) { $extra = [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth }
    $clientW = [int](940 * $S) + $extra
    if ($clientW -gt ($wa.Width - 20)) { $clientW = $wa.Width - 20 }
    $form.AutoScroll = $true
    $form.AutoScrollMinSize = New-Object System.Drawing.Size(0, $fullH)
    $form.ClientSize = New-Object System.Drawing.Size($clientW, $clientH)

    # ---- left sidebar: tools and settings
    $side = New-Object System.Windows.Forms.Panel
    $side.BackColor = (Get-FixItColor $script:UiSide)
    $side.Location = New-Object System.Drawing.Point(0, 0)
    $side.Size = New-Object System.Drawing.Size([int](200 * $S), $fullH)
    $form.Controls.Add($side)
    $sl = New-Object System.Windows.Forms.Label
    $sl.Text = $lay.SideTitle
    $sl.Font = New-Object System.Drawing.Font('Segoe UI', [single](11 * $S), [System.Drawing.FontStyle]::Bold, $px)
    $sl.ForeColor = (Get-FixItColor $(if ($hc) { '#FFFFFF' } else { '#566070' })); $sl.BackColor = (Get-FixItColor $script:UiSide); $sl.AutoSize = $false
    $sl.Location = New-Object System.Drawing.Point([int](22 * $S), [int](22 * $S)); $sl.Size = New-Object System.Drawing.Size([int](150 * $S), [int](18 * $S))
    $side.Controls.Add($sl)
    $script:FixButtons = New-Object System.Collections.ArrayList
    foreach ($nd in @($lay.Nav)) {
        $nt = New-FixItTile -Run $nd[0] -Title $nd[1] -Sub $nd[2] -IconKey $nd[3] -Style 'nav' -IconBg '' -X 12 -Y $nd[4] -W 176 -H $nd[5]
        $side.Controls.Add($nt); [void]$script:FixButtons.Add($nt)
    }
    if ($lay.SepY -gt 0) {
        $sep = New-Object System.Windows.Forms.Label
        $sep.BackColor = (Get-FixItColor $(if ($hc) { '#FFFFFF' } else { '#DDE3EC' }))
        $sep.Location = New-Object System.Drawing.Point([int](12 * $S), [int]($lay.SepY * $S)); $sep.Size = New-Object System.Drawing.Size([int](176 * $S), 1)
        $side.Controls.Add($sep)
    }
    foreach ($td in @($lay.Toggles)) {
        $tt = New-FixItTile -Run $td[0] -Title $td[1] -Sub '' -IconKey $td[2] -Style 'toggle' -IconBg '' -X 12 -Y $td[4] -W 176 -H $td[5] -On $td[3]
        $tt.AccessibleName = ('{0}: {1}' -f $td[1], $(if ($td[3]) { 'on' } else { 'off' }))
        $side.Controls.Add($tt)
    }
    # last item on the left bar: how to pin this program to the taskbar (Windows does not let a program pin itself)
    $pd = $lay.Pin
    $pt = New-FixItTile -Run $pd[0] -Title $pd[1] -Sub $pd[2] -IconKey $pd[3] -Style 'nav' -IconBg '' -X 12 -Y $pd[4] -W 176 -H $pd[5]
    $side.Controls.Add($pt); [void]$script:FixButtons.Add($pt)
    $script:CheckInLinkText = $checkIn

    # ---- main area
    $MX = 228
    $logo = New-FixItTile -Run '' -Title '' -Sub '' -IconKey 'mon' -Style 'logo' -IconBg '#0F6CBD' -X $MX -Y 20 -W 44 -H 44
    $logo.TabStop = $false; $logo.Cursor = [System.Windows.Forms.Cursors]::Default
    $form.Controls.Add($logo)
    $h1 = New-Object System.Windows.Forms.Label
    $h1.Text = "Hi! What's going wrong?"
    $h1.Font = New-Object System.Drawing.Font('Segoe UI', [single](26 * $S), [System.Drawing.FontStyle]::Bold, $px)
    $h1.ForeColor = (Get-FixItColor $cText); $h1.AutoSize = $false
    $h1.Location = New-Object System.Drawing.Point([int](($MX + 58) * $S), [int](14 * $S)); $h1.Size = New-Object System.Drawing.Size([int](380 * $S), [int](36 * $S))
    $form.Controls.Add($h1)
    $h2 = New-Object System.Windows.Forms.Label
    $h2.Text = "Pick the closest match and I'll try to fix it for you."
    if ($script:DryRun) { $h2.Text = 'Practice mode: nothing will be changed.' }
    if ($script:TestMode) { $h2.Text = 'Test mode: steps are only checked.' }
    $h2.Font = New-Object System.Drawing.Font('Segoe UI', [single](13 * $S), [System.Drawing.FontStyle]::Regular, $px)
    $h2.ForeColor = (Get-FixItColor $cMuted); $h2.AutoSize = $false
    $h2.Location = New-Object System.Drawing.Point([int](($MX + 59) * $S), [int](50 * $S)); $h2.Size = New-Object System.Drawing.Size([int](450 * $S), [int](20 * $S))
    $form.Controls.Add($h2)
    $script:PillLabel = New-Object System.Windows.Forms.Label
    $script:PillLabel.Font = New-Object System.Drawing.Font('Segoe UI', [single](11.5 * $S), [System.Drawing.FontStyle]::Regular, $px)
    $script:PillLabel.AutoSize = $false; $script:PillLabel.TextAlign = 'MiddleCenter'
    $script:PillLabel.Location = New-Object System.Drawing.Point([int](($MX + 392) * $S), [int](20 * $S)); $script:PillLabel.Size = New-Object System.Drawing.Size([int](287 * $S), [int](26 * $S))
    $script:PillLabel.Visible = $false
    $form.Controls.Add($script:PillLabel)
    if ($script:TestMode) {
        $h2.Width = [int](330 * $S)
        $bnr = New-Object System.Windows.Forms.Label
        $bnr.Text = 'TEST MODE - nothing is changed'
        $bnr.Font = New-Object System.Drawing.Font('Segoe UI', [single](13 * $S), [System.Drawing.FontStyle]::Bold, $px)
        $bnr.BackColor = (Get-FixItColor '#F59E0B'); $bnr.ForeColor = (Get-FixItColor '#1A1A1A'); $bnr.AutoSize = $false; $bnr.TextAlign = 'MiddleCenter'
        $bnr.Location = New-Object System.Drawing.Point([int](($MX + 392) * $S), [int](14 * $S)); $bnr.Size = New-Object System.Drawing.Size([int](287 * $S), [int](30 * $S))
        $bnr.AccessibleName = 'Test mode is on. Nothing is changed.'
        $form.Controls.Add($bnr)
        $tab = New-Object System.Windows.Forms.Button
        $tab.Text = 'Test all buttons'
        $tab.Font = New-Object System.Drawing.Font('Segoe UI', [single](12 * $S), [System.Drawing.FontStyle]::Bold, $px)
        $tab.FlatStyle = 'Flat'; $tab.BackColor = (Get-FixItColor '#FFF4D6'); $tab.ForeColor = (Get-FixItColor '#1A1A1A')
        $tab.Location = New-Object System.Drawing.Point([int](($MX + 392) * $S), [int](48 * $S)); $tab.Size = New-Object System.Drawing.Size([int](287 * $S), [int](28 * $S))
        $tab.Add_Click({ Invoke-GuiButton -Which 'TestAll' })
        $form.Controls.Add($tab); [void]$script:FixButtons.Add($tab)
    }

    $groups = @($lay.Groups)
    foreach ($grp in $groups) {
        $gl = New-Object System.Windows.Forms.Label
        $gl.Text = $grp.Name
        $gl.Font = New-Object System.Drawing.Font('Segoe UI', [single](11.5 * $S), [System.Drawing.FontStyle]::Bold, $px)
        $gl.ForeColor = (Get-FixItColor $cMuted); $gl.AutoSize = $false
        $gl.Location = New-Object System.Drawing.Point([int](($MX + 2) * $S), [int]($grp.Y * $S)); $gl.Size = New-Object System.Drawing.Size([int](500 * $S), [int](18 * $S))
        $form.Controls.Add($gl)
        $i = 0
        foreach ($t in $grp.Tiles) {
            $tile = New-FixItTile -Run $t[0] -Title $t[1] -Sub $t[2] -IconKey $t[3] -Style 'card' -IconBg $grp.Bg -X ($MX + $i * 231) -Y ($grp.Y + 22) -W 217 -H 112
            $form.Controls.Add($tile); [void]$script:FixButtons.Add($tile); $i++
        }
    }
    $scam = New-FixItTile -Run 'Scam' -Title 'I see a scary pop-up' -Sub "A warning telling me to call a number? Don't call it. Click here." -IconKey 'warn' -Style 'scam' -IconBg '#D9473C' -X $MX -Y $lay.ScamY -W 679 -H 72 -Wide $true
    $form.Controls.Add($scam); [void]$script:FixButtons.Add($scam)
    $p1 = New-FixItTile -Run 'Screen' -Title 'Let Trey see my screen' -Sub 'Opens Zoho Assist. Trey gives you a code.' -IconKey 'mon' -Style 'primary' -IconBg '#3F8BCB' -X $MX -Y $lay.PrimaryY -W 332 -H 76 -Wide $true
    $p2 = New-FixItTile -Run 'Report' -Title 'Send Trey a report' -Sub 'Something else is wrong' -IconKey 'send' -Style 'outline' -IconBg '#E6F0FA' -X ($MX + 347) -Y $lay.PrimaryY -W 332 -H 76 -Wide $true
    $form.Controls.Add($p1); $form.Controls.Add($p2); [void]$script:FixButtons.Add($p1); [void]$script:FixButtons.Add($p2)

    $script:StatusLabel = New-Object System.Windows.Forms.Label
    $script:StatusLabel.Text = (Get-FixItIdleStatus)
    $script:StatusLabel.Font = New-Object System.Drawing.Font('Segoe UI', [single](13 * $S), [System.Drawing.FontStyle]::Regular, $px)
    $script:StatusLabel.ForeColor = (Get-FixItColor $cText); $script:StatusLabel.AutoSize = $false; $script:StatusLabel.TextAlign = 'MiddleCenter'
    $script:StatusLabel.Location = New-Object System.Drawing.Point([int]($MX * $S), [int]($lay.StatusY * $S)); $script:StatusLabel.Size = New-Object System.Drawing.Size([int](679 * $S), [int](24 * $S))
    $form.Controls.Add($script:StatusLabel)

    $lf = New-Object System.Drawing.Font('Segoe UI', [single](12 * $S), [System.Drawing.FontStyle]::Regular, $px)
    $upd = Add-FixItLink -Form $form -Text 'Check for a newer version of this tool' -Run 'Update' -X $MX -Y $lay.LinksY -Color $cLink -Font $lf
    $ver = New-Object System.Windows.Forms.Label
    $ver.Text = 'Version ' + $script:FixItVersion
    $ver.Font = $lf
    $ver.ForeColor = (Get-FixItColor $cFaint); $ver.AutoSize = $false; $ver.TextAlign = 'MiddleRight'
    $ver.Location = New-Object System.Drawing.Point([int](($MX + 479) * $S), [int]($lay.LinksY * $S)); $ver.Size = New-Object System.Drawing.Size([int](200 * $S), [int](20 * $S))
    $form.Controls.Add($ver)

    $form.Tag = $FirstTime
    $form.Add_HandleCreated({ param($hs, $he) Save-FixItGuiInstanceInfo -Instance $script:GuiInstance -Handle $hs.Handle })   # so a second start can find this window
    $showTimer = Start-FixItGuiShowWatcher -Form $form -Instance $script:GuiInstance
    $form.Add_Shown({ param($s, $e)
        $tm = New-Object System.Windows.Forms.Timer
        $tm.Interval = 300
        $tm.Add_Tick({ param($ts, $te)
            $ts.Stop(); $ts.Dispose()
            try {
                $pill = Get-FixItHealthPill
                $pl = $script:PillLabel
                $dot = [string][char]0x25CF
                $pl.Text = ($dot + '  ' + $pill.Text)
                if ($script:UiHighContrast) { $pl.BackColor = [System.Drawing.Color]::Black; $pl.ForeColor = (Get-FixItColor '#FFFF00') }
                elseif ($pill.Ok) { $pl.BackColor = (Get-FixItColor '#EAF6EE'); $pl.ForeColor = (Get-FixItColor '#2F5E42') }
                else { $pl.BackColor = (Get-FixItColor '#FFF1D6'); $pl.ForeColor = (Get-FixItColor '#7A4A00') }
                $rr = New-Object System.Drawing.RectangleF(0, 0, $pl.Width, $pl.Height)
                $pp = New-FixItRoundPath -R $rr -Radius ([single]($pl.Height / 2))
                $pl.Region = New-Object System.Drawing.Region($pp); $pp.Dispose()
                $pl.Visible = $true
            } catch { Write-FixItLog ('Health pill failed: {0}' -f $_.Exception.Message) 'WARN' }
        })
        if (-not $script:TestMode) { $tm.Start() }
        if (-not $NoUpdateCheck -and -not $script:DryRun) {
            try { if (Repair-FixItIcon) { Set-FixItFormIcon $s } } catch { Write-FixItLog ('Icon check failed: {0}' -f $_.Exception.Message) 'WARN' }
        }
        if ([bool]$s.Tag -and -not $NoUpdateCheck -and -not $script:DryRun) {
            try { Show-FixItResult (Invoke-FixItUpdate -Quiet) } catch { Write-FixItLog ('Update check failed: {0}' -f $_.Exception.Message) 'WARN' }
        }
    })
    # While a fix is running the window keeps responding (it is not frozen), so closing it must wait until the fix is done.
    $form.Add_FormClosing({ param($fs, $fe) if ($script:ActionBusy) { $fe.Cancel = $true; Write-FixItLog 'The window was asked to close while a fix is running: it stays open until the fix is done.' } })
    [void]$form.ShowDialog()
    if ($showTimer) { try { $showTimer.Stop(); $showTimer.Dispose() } catch { } }
    $form.Dispose()
}

# ---------------------------------------------------------------------------
# One window only (v2.3.3): double-clicking the shortcut again must bring the open window forward, not open a second one.
# Only the main window (-Action Gui, not elevated) takes part. The sign-in watcher, the weekly check-in, the health check
# and the administrator parts never touch this mutex, so they can always run.
#   - a named per-user mutex (Local\FamilyFixIt-GUI-<user SID>) says "a window is open"
#   - a named per-user event (Local\FamilyFixIt-GUI-Show-<user SID>) is how the second start asks the open window to come forward
#   - gui-instance.json (process id + window handle) lets the second start also bring the window forward itself
# ---------------------------------------------------------------------------
$script:GuiInstanceKeyOverride = $null   # tests only
$script:GuiInstance = $null
$script:GuiFocusCs = @'
using System;
using System.Runtime.InteropServices;
public static class FixItGuiFocus {
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(int pid);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    public static bool IsValid(IntPtr h) { if (h == IntPtr.Zero) return false; return IsWindow(h); }
    public static int OwnerPid(IntPtr h) {
        if (!IsValid(h)) return 0;
        uint pid; GetWindowThreadProcessId(h, out pid); return (int)pid;
    }
    public static bool Allow(int pid) { return AllowSetForegroundWindow(pid); }
    // Restore (only when minimized) and bring to the front. Uses the usual focus workaround: share input with the
    // window that has the focus now, and flip "always on top" on and off.
    public static bool Bring(IntPtr h) {
        if (!IsValid(h)) return false;
        if (IsIconic(h)) ShowWindow(h, 9);   // SW_RESTORE
        uint dummy;
        IntPtr fg = GetForegroundWindow();
        uint fgThread = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, out dummy);
        uint me = GetCurrentThreadId();
        bool attached = false;
        if (fgThread != 0) { if (fgThread != me) attached = AttachThreadInput(me, fgThread, true); }
        try {
            SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0043);   // TOPMOST, no move, no size, show
            SetWindowPos(h, new IntPtr(-2), 0, 0, 0, 0, 0x0043);   // back to not-topmost (stays in front)
            BringWindowToTop(h);
            SetForegroundWindow(h);
        } finally {
            if (attached) AttachThreadInput(me, fgThread, false);
        }
        return GetForegroundWindow() == h;
    }
}
'@

function Get-FixItGuiInstanceNames {
    $key = $script:GuiInstanceKeyOverride
    if (-not $key) {
        try { $key = [string][Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { $key = '' }
        if (-not $key) { $key = [string]$env:USERNAME }
        if (-not $key) { $key = 'user' }
    }
    $key = ($key -replace '[^A-Za-z0-9\-]', '_')
    $suffix = ''
    if ($script:TestMode) { $suffix = '-Test' }
    elseif ($script:DryRun) { $suffix = '-Practice' }   # practice mode (-WhatIf) is its own window, so it never hides a real one
    return [pscustomobject]@{ Mutex = ('Local\FamilyFixIt-GUI-' + $key + $suffix); Event = ('Local\FamilyFixIt-GUI-Show-' + $key + $suffix); Key = ($key + $suffix) }
}
function Get-FixItGuiInstanceFile {
    param([string]$Key)
    return (Join-Path (Split-Path -Parent (Get-FixItStateFile)) ('gui-instance-' + $Key + '.json'))
}

# Does the one-window rule apply to this start? Only the plain, visible, not-elevated window.
function Test-FixItGuiSingleInstanceApplies {
    if ($Action -ne 'Gui') { return $false }
    if ($script:Background) { return $false }
    $elevated = $false
    try { $elevated = [bool](Test-FixItAdmin) } catch { $elevated = $false }
    if ($elevated) { return $false }
    return $true
}

# Takes the "a window is open" mutex. Returns Acquired = $true (this process is the window) or $false (another one is).
# An abandoned mutex (the earlier window crashed) is taken over. Any other trouble: carry on without the rule (never block the window).
function Enter-FixItGuiInstance {
    $n = Get-FixItGuiInstanceNames
    $m = $null; $ev = $null
    try {
        $m = New-Object System.Threading.Mutex($false, $n.Mutex)
        $got = $false; $abandoned = $false
        try { $got = $m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true; $abandoned = $true }
        if (-not $got) { $m.Dispose(); return [pscustomobject]@{ Acquired = $false; Failed = $false; Abandoned = $false; Mutex = $null; Event = $null; Names = $n } }
        if ($abandoned) { Write-FixItLog 'The earlier Family Fix-It window ended without closing properly; taking over.' 'WARN' }
        # The event is the polite way to ask this window to come forward. If it cannot be made, the lock still works (the window handle file is the other way).
        try { $ev = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $n.Event) } catch { $ev = $null; Write-FixItLog ('Could not make the come-forward signal ({0}); the window handle will be used instead.' -f $_.Exception.Message) 'WARN' }
        $inst = [pscustomobject]@{ Acquired = $true; Failed = $false; Abandoned = $abandoned; Mutex = $m; Event = $ev; Names = $n }
        $script:GuiInstance = $inst
        return $inst
    } catch {
        Write-FixItLog ('Could not set up the one-window rule ({0}); opening the window anyway.' -f $_.Exception.Message) 'WARN'
        try { if ($m) { $m.Dispose() } } catch { }
        return [pscustomobject]@{ Acquired = $true; Failed = $true; Abandoned = $false; Mutex = $null; Event = $null; Names = $n }
    }
}

# Gives the mutex back when the window closes.
function Exit-FixItGuiInstance {
    param($Instance)
    if ($null -eq $Instance) { return }
    try {
        $f = Get-FixItGuiInstanceFile -Key $Instance.Names.Key
        if (Test-Path -LiteralPath $f) {
            $j = $null; try { $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { }
            if ($null -eq $j -or [int]$j.pid -eq $PID) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
    if ($Instance.Mutex) { try { $Instance.Mutex.ReleaseMutex() } catch { }; try { $Instance.Mutex.Dispose() } catch { } }
    if ($Instance.Event) { try { $Instance.Event.Dispose() } catch { } }
    if ($script:GuiInstance -and [object]::ReferenceEquals($script:GuiInstance, $Instance)) { $script:GuiInstance = $null }
    Write-FixItLog 'Window closed; one-window lock released.'
}

# The open window tells the world where it is (process id + window handle).
function Save-FixItGuiInstanceInfo {
    param($Instance, [IntPtr]$Handle)
    if ($null -eq $Instance -or $null -eq $Instance.Mutex) { return }
    try {
        $f = Get-FixItGuiInstanceFile -Key $Instance.Names.Key
        $d = Split-Path -Parent $f
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $json = [ordered]@{ pid = $PID; hwnd = $Handle.ToInt64(); version = $script:FixItVersion } | ConvertTo-Json
        [IO.File]::WriteAllText($f, $json, (New-Object Text.UTF8Encoding($false)))
    } catch { Write-FixItLog ('Could not save the window handle: {0}' -f $_.Exception.Message) 'WARN' }
}

# In the open window: which window should come forward? A question box that is open on top of it if there is one, else the main window.
function Get-FixItGuiFrontTarget {
    param($Main)
    $target = $Main
    try {
        foreach ($of in @([System.Windows.Forms.Application]::OpenForms)) {
            if ($of.Visible -and -not [object]::ReferenceEquals($of, $Main)) { $target = $of }
        }
    } catch { }
    return $target
}

function Initialize-FixItGuiFocus {
    if (-not ('FixItGuiFocus' -as [type])) { Add-Type -TypeDefinition $script:GuiFocusCs -ErrorAction Stop }
}

# In the open window, on the screen's own thread: check whether a second start asked for the window, and bring it forward.
function Start-FixItGuiShowWatcher {
    param($Form, $Instance)
    if ($null -eq $Instance -or $null -eq $Instance.Event) { return $null }
    $script:GuiShowEvent = $Instance.Event
    $script:GuiShowMain = $Form
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 400
    $t.Add_Tick({
        param($ts, $te)
        try {
            if ($script:GuiShowEvent -and $script:GuiShowEvent.WaitOne(0)) {
                Write-FixItLog 'Another start asked for this window: bringing it to the front.'
                Initialize-FixItGuiFocus
                $tg = Get-FixItGuiFrontTarget -Main $script:GuiShowMain
                [void][FixItGuiFocus]::Bring($tg.Handle)
            }
        } catch { Write-FixItLog ('Bring-to-front failed: {0}' -f $_.Exception.Message) 'WARN' }
    })
    $t.Start()
    return $t
}

# The second start: find the open window and bring it forward. Returns $true when the window was asked (event or direct).
function Invoke-FixItGuiShowExisting {
    param($Instance)
    $n = Get-FixItGuiInstanceNames
    $asked = $false; $pid2 = 0; $hwnd = [IntPtr]::Zero
    try {
        $f = Get-FixItGuiInstanceFile -Key $n.Key
        if (Test-Path -LiteralPath $f) {
            $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            $pid2 = [int]$j.pid; $hwnd = [IntPtr]([int64]$j.hwnd)
        }
    } catch { Write-FixItLog ('Could not read the window handle: {0}' -f $_.Exception.Message) 'WARN' }
    try { Initialize-FixItGuiFocus } catch { Write-FixItLog ('Could not prepare the focus helper: {0}' -f $_.Exception.Message) 'WARN' }
    # This start was just launched by a double-click, so it may hand the right to take the focus to the open window.
    if ($pid2 -gt 0) { try { [void][FixItGuiFocus]::Allow($pid2) } catch { } }
    $ev = $null
    try {
        if ([System.Threading.EventWaitHandle]::TryOpenExisting($n.Event, [ref]$ev)) { [void]$ev.Set(); $asked = $true; $ev.Dispose() }
    } catch { Write-FixItLog ('Could not signal the open window: {0}' -f $_.Exception.Message) 'WARN' }
    # Direct route as well, only for a window that really belongs to that process (a stale or reused handle is ignored).
    try {
        if ($pid2 -gt 0 -and $hwnd -ne [IntPtr]::Zero -and [FixItGuiFocus]::OwnerPid($hwnd) -eq $pid2) {
            [void][FixItGuiFocus]::Bring($hwnd); $asked = $true
        }
    } catch { Write-FixItLog ('Direct bring-to-front failed: {0}' -f $_.Exception.Message) 'WARN' }
    return $asked
}

function Show-FixItWindow {
    $instance = $null
    if (Test-FixItGuiSingleInstanceApplies) {
        $instance = Enter-FixItGuiInstance
        if (-not $instance.Acquired) {
            Write-FixItLog 'Family Fix-It is already open: bringing that window forward and closing this start.'
            $ok = $false
            try { $ok = Invoke-FixItGuiShowExisting -Instance $instance } catch { Write-FixItLog ('Could not reach the open window: {0}' -f $_.Exception.Message) 'WARN' }
            if (-not $ok) { Write-FixItLog 'The open window could not be reached; it may be busy. Nothing else was opened.' 'WARN' }
            return
        }
    }
    try {
        Show-FixItWindowMain -Instance $instance
    } finally {
        Exit-FixItGuiInstance $instance
    }
}

function Show-FixItWindowMain {
    param($Instance)
    try {
        Add-Type -Namespace FixIt -Name Dpi -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -ErrorAction Stop
        [void][FixIt.Dpi]::SetProcessDPIAware()
    } catch { Write-FixItLog ('Could not switch on sharp text: {0}' -f $_.Exception.Message) 'WARN' }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $script:GuiActive = $true
    $g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $dpi = [double]($g0.DpiX / 96.0)
    $g0.Dispose()
    if ($dpi -lt 1) { $dpi = 1.0 }
    $script:UiIcons = Get-FixItIconMap
    $first = $true
    try { Initialize-FixItGuardianDefault } catch { Write-FixItLog ('Pop-up watcher setup failed: {0}' -f $_.Exception.Message) 'WARN' }
    do {
        $script:RebuildUi = $false
        $script:UiBigText = ((Get-FixItSetting -Name 'BigText' -Default '0') -eq '1')
        $hcSaved = Get-FixItSetting -Name 'HighContrast' -Default ''
        if ($hcSaved -eq '') { $script:UiHighContrast = [bool][System.Windows.Forms.SystemInformation]::HighContrast } else { $script:UiHighContrast = ($hcSaved -eq '1') }
        $script:UiScale = $dpi
        if ($script:UiBigText) { $script:UiScale = $dpi * 1.25 }
        $script:UiBack = '#FAFAFA'; if ($script:UiHighContrast) { $script:UiBack = '#000000' }
        $script:UiSide = '#F0F3F8'; if ($script:UiHighContrast) { $script:UiSide = '#000000' }
        Show-FixItWindowOnce -FirstTime $first
        $first = $false
    } while ($script:RebuildUi)
    $script:GuiActive = $false
    Stop-FixItOffUiWorkers
}

# "Did that fix it?" - a friendly two-button question.
function Show-FixItFixedDialog {
    param([string]$Title, [string]$Detail)
    $S = $script:UiScale
    $hc = [bool]$script:UiHighContrast
    $px = [System.Drawing.GraphicsUnit]::Pixel
    $f = New-Object System.Windows.Forms.Form
    Set-FixItFormIcon $f
    $f.Text = 'Family Fix-It'
    $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false
    $f.BackColor = (Get-FixItColor $script:UiBack)
    $f.ClientSize = New-Object System.Drawing.Size([int](440 * $S), [int](320 * $S))
    $cText = '#1A1A1A'; $cMuted = '#555555'; if ($hc) { $cText = '#FFFFFF'; $cMuted = '#FFFFFF' }
    $circ = New-Object System.Windows.Forms.Panel
    $circ.Size = New-Object System.Drawing.Size([int](56 * $S), [int](56 * $S))
    $circ.Location = New-Object System.Drawing.Point([int](192 * $S), [int](24 * $S))
    $circ.BackColor = (Get-FixItColor $script:UiBack)
    $circ.Add_Paint({ param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $c = '#107C41'; if ($script:UiHighContrast) { $c = '#FFFF00' }
        $br = New-Object System.Drawing.SolidBrush((Get-FixItColor $c)); $g.FillEllipse($br, 0, 0, ($s.Width - 1), ($s.Height - 1)); $br.Dispose()
        $img = $script:UiIcons['checkW']; if ($script:UiHighContrast) { $img = $script:UiIcons['check'] }
        if ($img) { $g.InterpolationMode = 'HighQualityBicubic'; $sz = [int]($s.Width * 0.55); $g.DrawImage($img, [int](($s.Width - $sz) / 2), [int](($s.Height - $sz) / 2), $sz, $sz) }
    })
    $f.Controls.Add($circ)
    $mk = {
        param($text, $size, $bold, $color, $y, $hgt)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.AutoSize = $false; $l.TextAlign = 'MiddleCenter'
        $st = [System.Drawing.FontStyle]::Regular; if ($bold) { $st = [System.Drawing.FontStyle]::Bold }
        $l.Font = New-Object System.Drawing.Font('Segoe UI', [single]($size * $S), $st, $px)
        $l.ForeColor = (Get-FixItColor $color)
        $l.Location = New-Object System.Drawing.Point([int](20 * $S), [int]($y * $S)); $l.Size = New-Object System.Drawing.Size([int](400 * $S), [int]($hgt * $S))
        return $l
    }
    $f.Controls.Add((& $mk $Title 24 $true $cText 90 36))
    $f.Controls.Add((& $mk $Detail 14 $false $cMuted 130 60))
    $yes = New-FixItTile -Run '' -Title "Yes, it's fixed" -Sub '' -IconKey '' -Style 'yes' -IconBg '' -X 24 -Y 206 -W 184 -H 52
    $no = New-FixItTile -Run '' -Title 'No, still broken' -Sub '' -IconKey '' -Style 'no' -IconBg '' -X 224 -Y 206 -W 184 -H 52
    $yes.DialogResult = 'Yes'; $no.DialogResult = 'No'
    $f.Controls.Add($yes); $f.Controls.Add($no)
    $f.Controls.Add((& $mk "If it's still broken, I'll send Trey a report automatically." 12 $false $cMuted 272 24))
    $f.CancelButton = $no
    $r = $f.ShowDialog($script:Form)
    $f.Dispose()
    return ($r -eq 'Yes')
}

# ---- "Here is what I will do": Proceed or Go Back (shown before every main button)
function Show-FixItPlanDialog {
    param($Plan)
    $S = $script:UiScale
    $hc = [bool]$script:UiHighContrast
    $px = [System.Drawing.GraphicsUnit]::Pixel
    $cText = '#1A1A1A'; $cMuted = '#555555'; $cNum = '#0F6CBD'
    $warnBg = '#FFF4E0'; $warnLine = '#C77700'; $warnText = '#6B3F00'
    $okBg = '#E8F5EC'; $okLine = '#107C41'; $okText = '#0B5A2E'
    if ($hc) { $cText = '#FFFFFF'; $cMuted = '#FFFFFF'; $cNum = '#FFFF00'; $warnBg = '#000000'; $warnLine = '#FFFF00'; $warnText = '#FFFF00'; $okBg = '#000000'; $okLine = '#FFFFFF'; $okText = '#FFFFFF' }
    $f = New-Object System.Windows.Forms.Form
    Set-FixItFormIcon $f
    $f.Text = 'Family Fix-It - ' + [string]$Plan.Title
    $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false
    $f.BackColor = (Get-FixItColor $script:UiBack)
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $fontBody = New-Object System.Drawing.Font('Segoe UI', [single](17 * $S), [System.Drawing.FontStyle]::Regular, $px)
    $fontBold = New-Object System.Drawing.Font('Segoe UI', [single](17 * $S), [System.Drawing.FontStyle]::Bold, $px)
    $fontNum = New-Object System.Drawing.Font('Segoe UI', [single](19 * $S), [System.Drawing.FontStyle]::Bold, $px)
    $tflags = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::NoPadding
    $panelW = [int](612 * $S)
    $stepW = [int](540 * $S)
    $h = New-Object System.Windows.Forms.Label
    $h.Text = [string]$Plan.Title; $h.AutoSize = $false
    $h.Font = New-Object System.Drawing.Font('Segoe UI', [single](26 * $S), [System.Drawing.FontStyle]::Bold, $px)
    $h.ForeColor = (Get-FixItColor $cText)
    $h.Location = New-Object System.Drawing.Point([int](24 * $S), [int](14 * $S)); $h.Size = New-Object System.Drawing.Size($panelW, [int](40 * $S))
    $f.Controls.Add($h)
    $sub = New-Object System.Windows.Forms.Label
    $sub.Text = ('Here is what I will do. How long it takes: {0}.' -f ([string]$Plan.Time).ToLower()); $sub.AutoSize = $false
    $sub.Font = New-Object System.Drawing.Font('Segoe UI', [single](15 * $S), [System.Drawing.FontStyle]::Regular, $px)
    $sub.ForeColor = (Get-FixItColor $cMuted)
    $sub.Location = New-Object System.Drawing.Point([int](24 * $S), [int](56 * $S)); $sub.Size = New-Object System.Drawing.Size($panelW, [int](26 * $S))
    $f.Controls.Add($sub)

    $pn = New-Object System.Windows.Forms.Panel
    $pn.AutoScroll = $true; $pn.BackColor = (Get-FixItColor $script:UiBack)
    $pn.Location = New-Object System.Drawing.Point([int](24 * $S), [int](92 * $S))
    $y = 0; $n = 1
    foreach ($d in @($Plan.Does)) {
        $hh = [System.Windows.Forms.TextRenderer]::MeasureText([string]$d, $fontBody, (New-Object System.Drawing.Size($stepW, 0)), $tflags).Height
        $hh = [math]::Max($hh + [int](6 * $S), [int](34 * $S))
        $nl = New-Object System.Windows.Forms.Label
        $nl.Text = [string]$n; $nl.AutoSize = $false; $nl.Font = $fontNum; $nl.ForeColor = (Get-FixItColor $cNum); $nl.TextAlign = 'TopCenter'
        $nl.Location = New-Object System.Drawing.Point(0, $y); $nl.Size = New-Object System.Drawing.Size([int](44 * $S), $hh)
        $pn.Controls.Add($nl)
        $tl = New-Object System.Windows.Forms.Label
        $tl.Text = [string]$d; $tl.AutoSize = $false; $tl.Font = $fontBody; $tl.ForeColor = (Get-FixItColor $cText)
        $tl.Location = New-Object System.Drawing.Point([int](48 * $S), ($y + [int](2 * $S))); $tl.Size = New-Object System.Drawing.Size($stepW, $hh)
        $pn.Controls.Add($tl)
        $y += $hh + [int](8 * $S); $n++
    }
    $y += [int](6 * $S)
    # one coloured box: the things worth knowing, and whether a restart or signing in again may be needed
    $boxes = @()
    if (@($Plan.Heads).Count -gt 0) { $boxes += , @('Please know', @($Plan.Heads | ForEach-Object { '- ' + [string]$_ }), $warnBg, $warnLine, $warnText) }
    $rs = @($warnBg, $warnLine, $warnText); if (-not $Plan.NeedsRestart) { $rs = @($okBg, $okLine, $okText) }
    $sg = @($warnBg, $warnLine, $warnText); if (-not $Plan.NeedsSignIn) { $sg = @($okBg, $okLine, $okText) }
    $boxes += , @($null, @([string]$Plan.RestartLine), $rs[0], $rs[1], $rs[2])
    $boxes += , @($null, @([string]$Plan.SignInLine), $sg[0], $sg[1], $sg[2])
    $innerW = $panelW - [int](36 * $S)
    foreach ($bx in $boxes) {
        $bp = New-Object System.Windows.Forms.Panel
        $bp.BackColor = (Get-FixItColor $bx[2])
        $by = [int](8 * $S)
        $labels = @()
        if ($bx[0]) { $labels += , @([string]$bx[0], $fontBold) }
        foreach ($tx in @($bx[1])) { $labels += , @([string]$tx, $(if ($bx[0]) { $fontBody } else { $fontBold })) }
        foreach ($lb in $labels) {
            $lh = [System.Windows.Forms.TextRenderer]::MeasureText([string]$lb[0], $lb[1], (New-Object System.Drawing.Size($innerW, 0)), $tflags).Height + [int](4 * $S)
            $ll = New-Object System.Windows.Forms.Label
            $ll.Text = [string]$lb[0]; $ll.AutoSize = $false; $ll.Font = $lb[1]; $ll.ForeColor = (Get-FixItColor $bx[4]); $ll.BackColor = (Get-FixItColor $bx[2])
            $ll.Location = New-Object System.Drawing.Point([int](14 * $S), $by); $ll.Size = New-Object System.Drawing.Size($innerW, $lh)
            $bp.Controls.Add($ll); $by += $lh
        }
        $by += [int](6 * $S)
        $bar = New-Object System.Windows.Forms.Label
        $bar.BackColor = (Get-FixItColor $bx[3]); $bar.Location = New-Object System.Drawing.Point(0, 0); $bar.Size = New-Object System.Drawing.Size([int](5 * $S), $by)
        $bp.Controls.Add($bar)
        $bp.Location = New-Object System.Drawing.Point(0, $y); $bp.Size = New-Object System.Drawing.Size($panelW, $by)
        $pn.Controls.Add($bp)
        $y += $by + [int](10 * $S)
    }
    $maxPanel = $wa.Height - [int](260 * $S)
    $panelH = [math]::Min($y, $maxPanel)
    $extraW = 0; if ($y -gt $maxPanel) { $extraW = [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth }
    $pn.Size = New-Object System.Drawing.Size(($panelW + $extraW), $panelH)
    $f.Controls.Add($pn)
    $btnY = [int](92 * $S) + $panelH + [int](14 * $S)
    $go = New-FixItTile -Run '' -Title 'Proceed' -Sub '' -IconKey '' -Style 'yes' -IconBg '' -X 24 -Y ([int]($btnY / $S)) -W 290 -H 60
    $back = New-FixItTile -Run '' -Title 'Go Back' -Sub '' -IconKey '' -Style 'no' -IconBg '' -X 332 -Y ([int]($btnY / $S)) -W 290 -H 60
    $go.DialogResult = 'OK'; $back.DialogResult = 'Cancel'
    $go.AccessibleName = 'Proceed. Do these steps now.'; $back.AccessibleName = 'Go Back. Do nothing.'
    $f.Controls.Add($go); $f.Controls.Add($back)
    $f.CancelButton = $back
    $f.ClientSize = New-Object System.Drawing.Size(([int](24 * $S) * 2 + $panelW + $extraW), ($btnY + [int](60 * $S) + [int](22 * $S)))
    $r = $f.ShowDialog($script:Form)
    $f.Dispose()
    return ($r -eq 'OK')
}

# ---- Which printer? One big button per printer. Returns the name, or '' when the person goes back.
function Show-FixItPrinterPickDialog {
    param([string[]]$Names, [string]$Current = '')
    $S = $script:UiScale; $hc = [bool]$script:UiHighContrast
    $px = [System.Drawing.GraphicsUnit]::Pixel
    $cText = '#1A1A1A'; $cMuted = '#555555'; if ($hc) { $cText = '#FFFFFF'; $cMuted = '#FFFFFF' }
    $script:PickedPrinter = ''
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $f = New-Object System.Windows.Forms.Form
    Set-FixItFormIcon $f
    $f.Text = 'Family Fix-It - Which printer?'
    $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false
    $f.BackColor = (Get-FixItColor $script:UiBack)
    $script:PickDialog = $f
    $h = New-Object System.Windows.Forms.Label
    $h.Text = 'Which printer do you want to use?'; $h.AutoSize = $false
    $h.Font = New-Object System.Drawing.Font('Segoe UI', [single](24 * $S), [System.Drawing.FontStyle]::Bold, $px)
    $h.ForeColor = (Get-FixItColor $cText)
    $h.Location = New-Object System.Drawing.Point([int](24 * $S), [int](16 * $S)); $h.Size = New-Object System.Drawing.Size([int](572 * $S), [int](38 * $S))
    $f.Controls.Add($h)
    $sub = New-Object System.Windows.Forms.Label
    $sub.Text = 'Click it. I will make it your main printer, so Windows uses it first.'; $sub.AutoSize = $false
    $sub.Font = New-Object System.Drawing.Font('Segoe UI', [single](15 * $S), [System.Drawing.FontStyle]::Regular, $px)
    $sub.ForeColor = (Get-FixItColor $cMuted)
    $sub.Location = New-Object System.Drawing.Point([int](24 * $S), [int](56 * $S)); $sub.Size = New-Object System.Drawing.Size([int](572 * $S), [int](26 * $S))
    $f.Controls.Add($sub)
    $pn = New-Object System.Windows.Forms.Panel
    $pn.AutoScroll = $true; $pn.BackColor = (Get-FixItColor $script:UiBack)
    $pn.Location = New-Object System.Drawing.Point([int](24 * $S), [int](94 * $S))
    $y = 0
    foreach ($nm in @($Names)) {
        $title = [string]$nm
        if ($Current -and $title -eq $Current) { $title = $title + '  (your main printer now)' }
        $b = New-FixItTile -Run ('PrinterPick:' + [string]$nm) -Title $title -Sub '' -IconKey '' -Style 'btn' -IconBg '' -X 0 -Y $y -W 556 -H 54
        $b.AccessibleName = ('Printer: ' + [string]$nm)
        $pn.Controls.Add($b); $y += 62
    }
    $maxPanel = $wa.Height - [int](300 * $S)
    $panelH = [math]::Min([int]($y * $S), $maxPanel)
    $extraW = 0; if ([int]($y * $S) -gt $maxPanel) { $extraW = [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth }
    $pn.Size = New-Object System.Drawing.Size(([int](572 * $S) + $extraW), $panelH)
    $f.Controls.Add($pn)
    $btnY = [int](94 * $S) + $panelH + [int](14 * $S)
    $back = New-FixItTile -Run '' -Title 'Go Back' -Sub '' -IconKey '' -Style 'no' -IconBg '' -X 24 -Y ([int]($btnY / $S)) -W 230 -H 52
    $back.DialogResult = 'Cancel'
    $f.Controls.Add($back)
    $f.CancelButton = $back
    $f.ClientSize = New-Object System.Drawing.Size(([int](620 * $S) + $extraW), ($btnY + [int](52 * $S) + [int](22 * $S)))
    [void]$f.ShowDialog($script:Form)
    $f.Dispose()
    $script:PickDialog = $null
    return [string]$script:PickedPrinter
}

# ---- The waiting window with a friendly countdown (after the router is unplugged and plugged back in)
function Show-FixItCountdownDialog {
    param([int]$Seconds, [string]$Title, [string]$Message)
    $S = $script:UiScale; $hc = [bool]$script:UiHighContrast
    $px = [System.Drawing.GraphicsUnit]::Pixel
    $cText = '#1A1A1A'; $cMuted = '#555555'; $cBig = '#0F6CBD'; if ($hc) { $cText = '#FFFFFF'; $cMuted = '#FFFFFF'; $cBig = '#FFFF00' }
    $f = New-Object System.Windows.Forms.Form
    Set-FixItFormIcon $f
    $f.Text = 'Family Fix-It'
    $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ControlBox = $false; $f.ShowInTaskbar = $false
    $f.BackColor = (Get-FixItColor $script:UiBack)
    $f.ClientSize = New-Object System.Drawing.Size([int](600 * $S), [int](380 * $S))
    $mk = {
        param($text, $size, $bold, $color, $y, $hgt)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.AutoSize = $false; $l.TextAlign = 'MiddleCenter'
        $st = [System.Drawing.FontStyle]::Regular; if ($bold) { $st = [System.Drawing.FontStyle]::Bold }
        $l.Font = New-Object System.Drawing.Font('Segoe UI', [single]($size * $S), $st, $px)
        $l.ForeColor = (Get-FixItColor $color)
        $l.Location = New-Object System.Drawing.Point([int](24 * $S), [int]($y * $S)); $l.Size = New-Object System.Drawing.Size([int](552 * $S), [int]($hgt * $S))
        return $l
    }
    $f.Controls.Add((& $mk $Title 26 $true $cText 20 44))
    $f.Controls.Add((& $mk $Message 16 $false $cMuted 70 56))
    $script:CdTime = & $mk '' 64 $true $cBig 134 84
    $f.Controls.Add($script:CdTime)
    $script:CdMsg = & $mk '' 16 $false $cText 226 36
    $f.Controls.Add($script:CdMsg)
    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Minimum = 0; $bar.Maximum = [math]::Max(1, $Seconds); $bar.Value = 0
    $bar.Location = New-Object System.Drawing.Point([int](60 * $S), [int](286 * $S)); $bar.Size = New-Object System.Drawing.Size([int](480 * $S), [int](24 * $S))
    $f.Controls.Add($bar)
    $f.Controls.Add((& $mk 'Please do not turn off the computer.' 14 $false $cMuted 326 30))
    $script:CdBar = $bar; $script:CdForm = $f; $script:CdTotal = [math]::Max(1, $Seconds)
    $script:CdEnd = (Get-Date).AddSeconds($Seconds)
    $script:CdTime.Text = ('{0}:{1:00}' -f [int][math]::Floor($Seconds / 60), ($Seconds % 60))
    $script:CdMsg.Text = (Get-FixItCountdownText -Remaining $Seconds -Total $Seconds)
    $tm = New-Object System.Windows.Forms.Timer
    $tm.Interval = 250
    $script:CdTimer = $tm
    $tm.Add_Tick({
        $left = [int][math]::Ceiling(($script:CdEnd - (Get-Date)).TotalSeconds)
        if ($left -le 0) { $script:CdTimer.Stop(); $script:CdForm.Close(); return }
        $script:CdTime.Text = ('{0}:{1:00}' -f [int][math]::Floor($left / 60), ($left % 60))
        $script:CdMsg.Text = (Get-FixItCountdownText -Remaining $left -Total $script:CdTotal)
        $script:CdBar.Value = [int][math]::Min($script:CdBar.Maximum, [math]::Max(0, $script:CdTotal - $left))
    })
    $tm.Start()
    [void]$f.ShowDialog($script:Form)
    $tm.Stop(); $tm.Dispose()
    $f.Dispose()
}

# ---- My files window: search box + a list; every file gets exactly two buttons
function Set-FixItFilesBusy {
    param([bool]$Busy)
    if ($script:FilesGo) { $script:FilesGo.Visible = (-not $Busy) }
    if ($script:FilesCancel) { $script:FilesCancel.Visible = $Busy }
    if ($script:FilesTb) { $script:FilesTb.Enabled = (-not $Busy) }
    if ($script:FilesDialog) { if ($Busy) { $script:FilesDialog.Cursor = [System.Windows.Forms.Cursors]::AppStarting } else { $script:FilesDialog.Cursor = [System.Windows.Forms.Cursors]::Default } }
}
# Starts the search in the background and returns at once (the window never waits on the file system).
function Update-FixItFilesList {
    param([string]$Query)
    if ($script:FilesJob) { return }
    $script:FilesPanel.Controls.Clear()
    $script:FilesMsg.Text = 'Looking... you can click Cancel at any time.'
    Set-FixItFilesBusy $true
    $script:FilesQuery = $Query
    $script:FilesJob = Start-FixItFileSearch -Query $Query -Max 8
    if ($script:FilesTimer) { $script:FilesTimer.Start() }
}
# Timer tick: only reads a few numbers from the background search. Never waits.
function Invoke-FixItFilesPoll {
    if (-not $script:FilesJob) { if ($script:FilesTimer) { $script:FilesTimer.Stop() }; return }
    $job = $script:FilesJob
    $status = 'Running'
    try { $status = Get-FixItFileSearchStatus -Job $job } catch { Write-FixItLog ('My files: could not check the search: {0}' -f $_.Exception.Message) 'WARN'; $status = 'Done' }
    if ($status -eq 'Running') {
        $script:FilesMsg.Text = ('Looking... {0} files checked so far. You can click Cancel.' -f $job.State.Files)
        return
    }
    if ($script:FilesTimer) { $script:FilesTimer.Stop() }
    $script:FilesJob = $null
    $found = @()
    try { Write-FixItFileScanSummary -State $job.State -Query $script:FilesQuery; $found = @($job.State.Result) } catch { Write-FixItLog ('My files: could not read the result: {0}' -f $_.Exception.Message) 'ERROR' }
    $reason = [string]$job.State.Reason
    Close-FixItFileSearch -Job $job
    Set-FixItFilesBusy $false
    Show-FixItFilesResults -Found $found -Query $script:FilesQuery -Reason $reason
}
function Show-FixItFilesResults {
    param($Found, [string]$Query, [string]$Reason = '')
    $S = $script:UiScale; $hc = [bool]$script:UiHighContrast
    $cText = '#1A1A1A'; $cMuted = '#555555'; if ($hc) { $cText = '#FFFFFF'; $cMuted = '#FFFFFF' }
    $px = [System.Drawing.GraphicsUnit]::Pixel
    $pn = $script:FilesPanel
    $pn.Controls.Clear()
    $found = @($Found)
    $partial = ''
    if ($Reason -eq 'cancelled') { $partial = ' (You stopped the search, so this may not be everything.)' }
    elseif ($Reason) { $partial = ' (I looked in the nearest folders only, so this may not be everything.)' }
    if ($found.Count -eq 0) {
        if ($Query) { $script:FilesMsg.Text = ('No file with "{0}" in its name was found. Try fewer or different words.{1}' -f $Query, $partial) }
        else { $script:FilesMsg.Text = ('No files were found in your Desktop, Documents, Downloads, Pictures or OneDrive folders.{0}' -f $partial) }
        return
    }
    if ($Query) { $script:FilesMsg.Text = ('Files with "{0}" in the name (newest first):{1}' -f $Query, $partial) } else { $script:FilesMsg.Text = ('Saved most recently (newest first). Type a name above to search.{0}' -f $partial) }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $y = 0
    foreach ($x in $found) {
        $n = New-Object System.Windows.Forms.Label
        $n.Text = [string]$x.Name; $n.AutoSize = $false; $n.AutoEllipsis = $true
        $n.Font = New-Object System.Drawing.Font('Segoe UI', [single](15 * $S), [System.Drawing.FontStyle]::Bold, $px)
        $n.ForeColor = (Get-FixItColor $cText)
        $n.Location = New-Object System.Drawing.Point(0, [int](($y + 4) * $S)); $n.Size = New-Object System.Drawing.Size([int](540 * $S), [int](22 * $S))
        $pn.Controls.Add($n)
        $i = New-Object System.Windows.Forms.Label
        $i.Text = ('{0}   saved {1}' -f $x.Folder, ([datetime]$x.Modified).ToString('ddd MMM d, h:mm tt', $inv)); $i.AutoSize = $false; $i.AutoEllipsis = $true
        $i.Font = New-Object System.Drawing.Font('Segoe UI', [single](12 * $S), [System.Drawing.FontStyle]::Regular, $px)
        $i.ForeColor = (Get-FixItColor $cMuted)
        $i.Location = New-Object System.Drawing.Point(0, [int](($y + 28) * $S)); $i.Size = New-Object System.Drawing.Size([int](540 * $S), [int](18 * $S))
        $pn.Controls.Add($i)
        $b1 = New-FixItTile -Run ('OpenFile:' + $x.FullName) -Title 'Open the file' -Sub '' -IconKey '' -Style 'btn' -IconBg '' -X 0 -Y ($y + 52) -W 160 -H 32
        $b2 = New-FixItTile -Run ('ShowFile:' + $x.FullName) -Title 'Show me where it is' -Sub '' -IconKey '' -Style 'btn' -IconBg '' -X 172 -Y ($y + 52) -W 200 -H 32
        $pn.Controls.Add($b1); $pn.Controls.Add($b2)
        $y += 96
    }
}
function Show-FixItFilesDialog {
    $S = $script:UiScale; $hc = [bool]$script:UiHighContrast
    $px = [System.Drawing.GraphicsUnit]::Pixel
    $cText = '#1A1A1A'; $cMuted = '#555555'; if ($hc) { $cText = '#FFFFFF'; $cMuted = '#FFFFFF' }
    $f = New-Object System.Windows.Forms.Form
    Set-FixItFormIcon $f
    $f.Text = 'Family Fix-It - My files'
    $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false
    $f.BackColor = (Get-FixItColor $script:UiBack)
    $f.ClientSize = New-Object System.Drawing.Size([int](600 * $S), [int](620 * $S))
    $script:FilesDialog = $f
    $l = New-Object System.Windows.Forms.Label
    $l.Text = 'Type part of the file name, then click Search. Leave it empty to see what you saved lately.'
    $l.AutoSize = $false; $l.Font = New-Object System.Drawing.Font('Segoe UI', [single](13 * $S), [System.Drawing.FontStyle]::Regular, $px)
    $l.ForeColor = (Get-FixItColor $cText)
    $l.Location = New-Object System.Drawing.Point([int](24 * $S), [int](16 * $S)); $l.Size = New-Object System.Drawing.Size([int](552 * $S), [int](40 * $S))
    $f.Controls.Add($l)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Font = New-Object System.Drawing.Font('Segoe UI', [single](16 * $S), [System.Drawing.FontStyle]::Regular, $px)
    $tb.Location = New-Object System.Drawing.Point([int](24 * $S), [int](62 * $S)); $tb.Size = New-Object System.Drawing.Size([int](420 * $S), [int](32 * $S))
    $f.Controls.Add($tb); $script:FilesTb = $tb
    $go = New-FixItTile -Run '' -Title 'Search' -Sub '' -IconKey '' -Style 'yes' -IconBg '' -X 458 -Y 60 -W 118 -H 38
    $go.Add_Click({ param($s, $e) Update-FixItFilesList -Query $script:FilesTb.Text.Trim() })
    $f.Controls.Add($go); $script:FilesGo = $go
    $cn = New-FixItTile -Run '' -Title 'Cancel' -Sub '' -IconKey '' -Style 'btn' -IconBg '' -X 458 -Y 60 -W 118 -H 38
    $cn.Add_Click({ param($s, $e) Stop-FixItFileSearch -Job $script:FilesJob })
    $cn.Visible = $false
    $f.Controls.Add($cn); $script:FilesCancel = $cn
    $script:FilesJob = $null
    $tm = New-Object System.Windows.Forms.Timer
    $tm.Interval = 200
    $tm.Add_Tick({ Invoke-FixItFilesPoll })
    $script:FilesTimer = $tm
    $msg = New-Object System.Windows.Forms.Label
    $msg.AutoSize = $false; $msg.Font = New-Object System.Drawing.Font('Segoe UI', [single](12.5 * $S), [System.Drawing.FontStyle]::Bold, $px)
    $msg.ForeColor = (Get-FixItColor $cMuted)
    $msg.Location = New-Object System.Drawing.Point([int](24 * $S), [int](108 * $S)); $msg.Size = New-Object System.Drawing.Size([int](552 * $S), [int](22 * $S))
    $f.Controls.Add($msg); $script:FilesMsg = $msg
    $pn = New-Object System.Windows.Forms.Panel
    $pn.AutoScroll = $true; $pn.BackColor = (Get-FixItColor $script:UiBack)
    $pn.Location = New-Object System.Drawing.Point([int](24 * $S), [int](138 * $S)); $pn.Size = New-Object System.Drawing.Size([int](560 * $S), [int](466 * $S))
    $f.Controls.Add($pn); $script:FilesPanel = $pn
    $f.AcceptButton = $go
    $f.Add_Shown({ param($s, $e) $script:FilesTb.Focus(); Update-FixItFilesList -Query '' })
    $f.Add_FormClosing({ param($s, $e)
        if ($script:FilesJob) { Write-FixItLog 'My files: window closed while looking; stopping the search'; $script:FilesJob.State.Cancel = $true; Close-FixItFileSearch -Job $script:FilesJob; $script:FilesJob = $null }
        if ($script:FilesTimer) { $script:FilesTimer.Stop() }
    })
    Write-FixItLog 'My files: window opened'
    [void]$f.ShowDialog($script:Form)
    if ($script:FilesTimer) { $script:FilesTimer.Dispose(); $script:FilesTimer = $null }
    $f.Dispose()
}

# ---- Install an app safely window: only the approved apps, one Install button each
function Show-FixItAppsDialog {
    $S = $script:UiScale; $hc = [bool]$script:UiHighContrast
    $px = [System.Drawing.GraphicsUnit]::Pixel
    $cText = '#1A1A1A'; $cMuted = '#555555'; if ($hc) { $cText = '#FFFFFF'; $cMuted = '#FFFFFF' }
    $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $apps = @()
    try { $apps = @(Get-FixItApprovedApps) } catch { Write-FixItLog ('App list failed: {0}' -f $_.Exception.Message) 'ERROR' }
    $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default
    $f = New-Object System.Windows.Forms.Form
    Set-FixItFormIcon $f
    $f.Text = 'Family Fix-It - Install an app'
    $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false
    $f.BackColor = (Get-FixItColor $script:UiBack)
    $f.ClientSize = New-Object System.Drawing.Size([int](520 * $S), [int]((120 + 60 * $apps.Count) * $S))
    $l = New-Object System.Windows.Forms.Label
    $l.Text = 'These apps are safe to install. Trey picked them. I will not install anything else.'
    $l.AutoSize = $false; $l.Font = New-Object System.Drawing.Font('Segoe UI', [single](13 * $S), [System.Drawing.FontStyle]::Regular, $px)
    $l.ForeColor = (Get-FixItColor $cText)
    $l.Location = New-Object System.Drawing.Point([int](24 * $S), [int](16 * $S)); $l.Size = New-Object System.Drawing.Size([int](472 * $S), [int](40 * $S))
    $f.Controls.Add($l)
    $y = 70
    foreach ($a in $apps) {
        $n = New-Object System.Windows.Forms.Label
        $n.Text = [string]$a.Name; $n.AutoSize = $false
        $n.Font = New-Object System.Drawing.Font('Segoe UI', [single](16 * $S), [System.Drawing.FontStyle]::Bold, $px)
        $n.ForeColor = (Get-FixItColor $cText); $n.TextAlign = 'MiddleLeft'
        $n.Location = New-Object System.Drawing.Point([int](24 * $S), [int]($y * $S)); $n.Size = New-Object System.Drawing.Size([int](320 * $S), [int](40 * $S))
        $f.Controls.Add($n)
        $b = New-FixItTile -Run ('InstallApp:' + $a.Name) -Title 'Install' -Sub '' -IconKey '' -Style 'btn' -IconBg '' -X 366 -Y ($y + 2) -W 130 -H 36
        $f.Controls.Add($b)
        $y += 60
    }
    if ($apps.Count -eq 0) { $e0 = New-Object System.Windows.Forms.Label; $e0.Text = 'The list of apps is empty right now.'; $e0.AutoSize = $true; $e0.Location = New-Object System.Drawing.Point([int](24 * $S), [int](70 * $S)); $f.Controls.Add($e0) }
    [void]$f.ShowDialog($script:Form)
    $f.Dispose()
}

# ---- My PC info: big PC code, the facts, and a Copy button
function Show-FixItPcInfoForm {
    param($Result)
    $S = $script:UiScale; $hc = [bool]$script:UiHighContrast
    $px = [System.Drawing.GraphicsUnit]::Pixel
    $cText = '#1A1A1A'; $cMuted = '#555555'; $cCode = '#0F6CBD'
    if ($hc) { $cText = '#FFFFFF'; $cMuted = '#FFFFFF'; $cCode = '#FFFF00' }
    $f = New-Object System.Windows.Forms.Form
    Set-FixItFormIcon $f
    $f.Text = 'Family Fix-It - My PC info'
    $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false
    $f.BackColor = (Get-FixItColor $script:UiBack)
    $f.ClientSize = New-Object System.Drawing.Size([int](560 * $S), [int](440 * $S))
    $cap = New-Object System.Windows.Forms.Label
    $cap.Text = 'Your PC code. Read it out if Trey asks.'
    $cap.AutoSize = $false; $cap.Font = New-Object System.Drawing.Font('Segoe UI', [single](15 * $S), [System.Drawing.FontStyle]::Regular, $px)
    $cap.ForeColor = (Get-FixItColor $cMuted); $cap.TextAlign = 'MiddleCenter'
    $cap.Location = New-Object System.Drawing.Point([int](24 * $S), [int](20 * $S)); $cap.Size = New-Object System.Drawing.Size([int](512 * $S), [int](30 * $S))
    $f.Controls.Add($cap)
    $code = New-Object System.Windows.Forms.Label
    $code.Text = [string]$Result.PcCode
    $code.AutoSize = $false; $code.Font = New-Object System.Drawing.Font('Segoe UI', [single](60 * $S), [System.Drawing.FontStyle]::Bold, $px)
    $code.ForeColor = (Get-FixItColor $cCode); $code.TextAlign = 'MiddleCenter'
    $code.Location = New-Object System.Drawing.Point([int](24 * $S), [int](56 * $S)); $code.Size = New-Object System.Drawing.Size([int](512 * $S), [int](90 * $S))
    $code.AccessibleName = ('PC code: ' + (([string]$Result.PcCode).ToCharArray() -join ' '))
    $f.Controls.Add($code)
    $y = 168
    foreach ($ln in @($Result.Details)) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = [string]$ln; $l.AutoSize = $false
        $l.Font = New-Object System.Drawing.Font('Segoe UI', [single](16 * $S), [System.Drawing.FontStyle]::Regular, $px)
        $l.ForeColor = (Get-FixItColor $cText)
        $l.Location = New-Object System.Drawing.Point([int](40 * $S), [int]($y * $S)); $l.Size = New-Object System.Drawing.Size([int](490 * $S), [int](52 * $S))
        $f.Controls.Add($l); $y += 56
    }
    $script:PcInfoCopyText = [string]$Result.CopyText
    $cp = New-FixItTile -Run '' -Title 'Copy' -Sub '' -IconKey '' -Style 'yes' -IconBg '' -X 90 -Y 372 -W 170 -H 50
    $cp.Add_Click({ param($s, $e)
        $ok = $false
        try { $ok = [bool](Set-FixItClipboard -Text $script:PcInfoCopyText) } catch { }
        $s.Tag.Title = $(if ($ok) { 'Copied!' } else { 'Could not copy' })
        $s.Invalidate()
    })
    $f.Controls.Add($cp)
    $cl = New-FixItTile -Run '' -Title 'Close' -Sub '' -IconKey '' -Style 'no' -IconBg '' -X 300 -Y 372 -W 170 -H 50
    $cl.Add_Click({ param($s, $e) $s.FindForm().Close() })
    $f.Controls.Add($cl)
    $f.CancelButton = $null
    [void]$f.ShowDialog($script:Form)
    $f.Dispose()
}

# ---- Help me with...: a big search box, a list of guides that narrows as you type
function Update-FixItGuidesList {
    param([string]$Query)
    $S = $script:UiScale
    $pn = $script:GuidesPanel
    $pn.SuspendLayout()
    foreach ($c in @($pn.Controls)) { $pn.Controls.Remove($c); $c.Dispose() }
    $q = $Query.Trim()
    $hits = @(Search-FixItGuides -Guides $script:GuidesAll -Query $q)
    $script:GuidesHits = @($hits | ForEach-Object { $_.Guide })
    if ($hits.Count -eq 0) {
        $script:GuidesMsg.Text = 'No guide for that yet - Send Trey a report?'
        $b = New-FixItTile -Run ('GuideNone:' + $q) -Title 'Send Trey a report' -Sub 'Tell him what you wanted help with' -IconKey 'send' -Style 'outline' -IconBg '#E6F0FA' -X 0 -Y 6 -W 520 -H 72 -Wide $true
        $pn.Controls.Add($b)
    } else {
        if ($q) { $script:GuidesMsg.Text = ('{0} guide{1} found. Click one.' -f $hits.Count, $(if ($hits.Count -eq 1) { '' } else { 's' })) }
        else { $script:GuidesMsg.Text = 'Click a guide, or type above to search.' }
        $y = 0
        foreach ($h in $hits) {
            $g = $h.Guide
            $n = @($g.Steps).Count
            $b = New-FixItTile -Run ('Guide:' + $g.Id) -Title $g.Title -Sub ('{0} easy step{1}' -f $n, $(if ($n -eq 1) { '' } else { 's' })) -IconKey 'guides' -Style 'outline' -IconBg '#E6F0FA' -X 0 -Y $y -W 520 -H 64 -Wide $true
            $pn.Controls.Add($b); $y += 72
        }
    }
    $pn.ResumeLayout()
}

function Show-FixItGuidesDialog {
    $S = $script:UiScale; $hc = [bool]$script:UiHighContrast
    $px = [System.Drawing.GraphicsUnit]::Pixel
    $cText = '#1A1A1A'; $cMuted = '#555555'; if ($hc) { $cText = '#FFFFFF'; $cMuted = '#FFFFFF' }
    $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $script:GuidesAll = @()
    try { $script:GuidesAll = @(Get-FixItGuides) } catch { Write-FixItLog ('Guides failed: {0}' -f $_.Exception.Message) 'ERROR'; $script:GuidesAll = @(Get-FixItBuiltInGuides) }
    $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default
    $f = New-Object System.Windows.Forms.Form
    Set-FixItFormIcon $f
    $f.Text = 'Family Fix-It - Help me with...'
    $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false
    $f.BackColor = (Get-FixItColor $script:UiBack)
    $f.ClientSize = New-Object System.Drawing.Size([int](600 * $S), [int](640 * $S))
    $l = New-Object System.Windows.Forms.Label
    $l.Text = 'What do you need help with? Type a few words, like: scan, photo, wifi.'
    $l.AutoSize = $false; $l.Font = New-Object System.Drawing.Font('Segoe UI', [single](14 * $S), [System.Drawing.FontStyle]::Regular, $px)
    $l.ForeColor = (Get-FixItColor $cText)
    $l.Location = New-Object System.Drawing.Point([int](24 * $S), [int](16 * $S)); $l.Size = New-Object System.Drawing.Size([int](552 * $S), [int](44 * $S))
    $f.Controls.Add($l)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Font = New-Object System.Drawing.Font('Segoe UI', [single](24 * $S), [System.Drawing.FontStyle]::Regular, $px)
    $tb.Location = New-Object System.Drawing.Point([int](24 * $S), [int](66 * $S)); $tb.Size = New-Object System.Drawing.Size([int](552 * $S), [int](46 * $S))
    $tb.AccessibleName = 'Search the help guides'
    $f.Controls.Add($tb); $script:GuidesTb = $tb
    $msg = New-Object System.Windows.Forms.Label
    $msg.AutoSize = $false; $msg.Font = New-Object System.Drawing.Font('Segoe UI', [single](13 * $S), [System.Drawing.FontStyle]::Bold, $px)
    $msg.ForeColor = (Get-FixItColor $cMuted)
    $msg.Location = New-Object System.Drawing.Point([int](24 * $S), [int](124 * $S)); $msg.Size = New-Object System.Drawing.Size([int](552 * $S), [int](24 * $S))
    $f.Controls.Add($msg); $script:GuidesMsg = $msg
    $pn = New-Object System.Windows.Forms.Panel
    $pn.AutoScroll = $true; $pn.BackColor = (Get-FixItColor $script:UiBack)
    $pn.Location = New-Object System.Drawing.Point([int](24 * $S), [int](154 * $S)); $pn.Size = New-Object System.Drawing.Size([int](560 * $S), [int](470 * $S))
    $f.Controls.Add($pn); $script:GuidesPanel = $pn
    $tm = New-Object System.Windows.Forms.Timer
    $tm.Interval = 180
    $tm.Add_Tick({ param($ts, $te) $ts.Stop(); try { Update-FixItGuidesList -Query $script:GuidesTb.Text } catch { Write-FixItLog ('Guide search failed: {0}' -f $_.Exception.Message) 'WARN' } })
    $script:GuidesTimer = $tm
    $tb.Add_TextChanged({ param($s, $e) $script:GuidesTimer.Stop(); $script:GuidesTimer.Start() })
    $tb.Add_KeyDown({ param($s, $e)
        if ($e.KeyCode -eq 'Return') {
            $e.SuppressKeyPress = $true
            $script:GuidesTimer.Stop(); Update-FixItGuidesList -Query $script:GuidesTb.Text
            $first = @($script:GuidesHits)
            if ($first.Count -gt 0) { $g0 = $first[0]; Show-FixItGuideSteps -Guide $g0 }
        }
    })
    $f.Add_Shown({ param($s, $e) $script:GuidesTb.Focus(); Update-FixItGuidesList -Query '' })
    [void]$f.ShowDialog($script:Form)
    $tm.Dispose(); $f.Dispose()
}

# ---- One guide: big numbered steps, Back, and "this did not help - tell Trey"
function Show-FixItGuideSteps {
    param($Guide)
    $S = $script:UiScale; $hc = [bool]$script:UiHighContrast
    $px = [System.Drawing.GraphicsUnit]::Pixel
    $cText = '#1A1A1A'; $cNum = '#0F6CBD'; if ($hc) { $cText = '#FFFFFF'; $cNum = '#FFFF00' }
    $f = New-Object System.Windows.Forms.Form
    Set-FixItFormIcon $f
    $f.Text = 'Family Fix-It - ' + [string]$Guide.Title
    $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false
    $f.BackColor = (Get-FixItColor $script:UiBack)
    $f.ClientSize = New-Object System.Drawing.Size([int](660 * $S), [int](700 * $S))
    $h = New-Object System.Windows.Forms.Label
    $h.Text = [string]$Guide.Title; $h.AutoSize = $false
    $h.Font = New-Object System.Drawing.Font('Segoe UI', [single](24 * $S), [System.Drawing.FontStyle]::Bold, $px)
    $h.ForeColor = (Get-FixItColor $cText)
    $h.Location = New-Object System.Drawing.Point([int](24 * $S), [int](16 * $S)); $h.Size = New-Object System.Drawing.Size([int](612 * $S), [int](76 * $S))
    $f.Controls.Add($h)
    $pn = New-Object System.Windows.Forms.Panel
    $pn.AutoScroll = $true; $pn.BackColor = (Get-FixItColor $script:UiBack)
    $pn.Location = New-Object System.Drawing.Point([int](24 * $S), [int](100 * $S)); $pn.Size = New-Object System.Drawing.Size([int](620 * $S), [int](492 * $S))
    $f.Controls.Add($pn)
    $font = New-Object System.Drawing.Font('Segoe UI', [single](19 * $S), [System.Drawing.FontStyle]::Regular, $px)
    $nfont = New-Object System.Drawing.Font('Segoe UI', [single](22 * $S), [System.Drawing.FontStyle]::Bold, $px)
    $tw = [int](540 * $S)
    $tflags = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::NoPadding
    $y = 0; $n = 1
    foreach ($st in @($Guide.Steps)) {
        $sz = [System.Windows.Forms.TextRenderer]::MeasureText([string]$st, $font, (New-Object System.Drawing.Size($tw, 0)), $tflags)
        $hh = [math]::Max($sz.Height + [int](6 * $S), [int](44 * $S))
        $nl = New-Object System.Windows.Forms.Label
        $nl.Text = [string]$n; $nl.AutoSize = $false; $nl.Font = $nfont; $nl.ForeColor = (Get-FixItColor $cNum); $nl.TextAlign = 'TopCenter'
        $nl.Location = New-Object System.Drawing.Point(0, $y); $nl.Size = New-Object System.Drawing.Size([int](50 * $S), $hh)
        $pn.Controls.Add($nl)
        $tl = New-Object System.Windows.Forms.Label
        $tl.Text = [string]$st; $tl.AutoSize = $false; $tl.Font = $font; $tl.ForeColor = (Get-FixItColor $cText)
        $tl.Location = New-Object System.Drawing.Point([int](56 * $S), ($y + [int](3 * $S))); $tl.Size = New-Object System.Drawing.Size($tw, $hh)
        $pn.Controls.Add($tl)
        $y += $hh + [int](14 * $S); $n++
    }
    $back = New-FixItTile -Run '' -Title 'Back' -Sub '' -IconKey '' -Style 'yes' -IconBg '' -X 24 -Y 622 -W 170 -H 56
    $back.Add_Click({ param($s, $e) $s.FindForm().Close() })
    $f.Controls.Add($back)
    $no = New-FixItTile -Run ('GuideHelp:' + [string]$Guide.Id) -Title "This didn't help - tell Trey" -Sub '' -IconKey '' -Style 'btn' -IconBg '' -X 214 -Y 622 -W 422 -H 56
    $f.Controls.Add($no)
    $script:GuideShown = $Guide
    [void]$f.ShowDialog($script:Form)
    $f.Dispose()
}

function Send-FixItGuideNote {
    param([string]$Note)
    $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try { Show-FixItResult (Invoke-FixItReport -Note $Note) }
    catch { Write-FixItLog ('Report failed: {0}' -f $_.Exception.Message) 'ERROR'; Show-FixItResult (New-FixItResult $false 'Report not sent' 'Sorry, the report could not be sent. Please tell Trey.') }
    finally { $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default }
}

# ----- Test mode windows -----
# A plain read-only text window (used for the per-button checklist and the "Test all buttons" summary).
function Show-FixItTextDialog {
    param([string]$Title, [string[]]$Lines, [string]$Status = 'PASS', [string]$Heading = '')
    if (-not $script:GuiActive) { foreach ($l in $Lines) { Write-Host $l }; return }
    $S = $script:UiScale; if (-not $S) { $S = 1.0 }
    $px = [System.Drawing.GraphicsUnit]::Pixel
    $f = New-Object System.Windows.Forms.Form
    Set-FixItFormIcon $f
    $f.Text = $Title
    $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'Sizable'
    $f.MinimizeBox = $false
    $f.BackColor = [System.Drawing.Color]::White
    $f.ClientSize = New-Object System.Drawing.Size([int](760 * $S), [int](560 * $S))
    $f.Font = New-Object System.Drawing.Font('Segoe UI', [single](13 * $S), [System.Drawing.FontStyle]::Regular, $px)
    $bn = New-Object System.Windows.Forms.Label
    $bn.Text = $Heading
    $bn.Dock = 'Top'; $bn.Height = [int](40 * $S); $bn.TextAlign = 'MiddleCenter'
    $bn.Font = New-Object System.Drawing.Font('Segoe UI', [single](16 * $S), [System.Drawing.FontStyle]::Bold, $px)
    $bn.ForeColor = [System.Drawing.Color]::Black
    if ($Status -eq 'FAIL') { $bn.BackColor = (Get-FixItColor '#F4B6B0') } elseif ($Status -eq 'WARN') { $bn.BackColor = (Get-FixItColor '#FFE08A') } else { $bn.BackColor = (Get-FixItColor '#BFE6C8') }
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Vertical'; $tb.WordWrap = $true
    $tb.Font = New-Object System.Drawing.Font('Consolas', [single](13 * $S), [System.Drawing.FontStyle]::Regular, $px)
    $tb.Dock = 'Fill'
    $tb.Text = ($Lines -join "`r`n")
    $tb.Select(0, 0)
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Bottom'; $bar.Height = [int](52 * $S)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Close'; $ok.Size = New-Object System.Drawing.Size([int](120 * $S), [int](36 * $S))
    $ok.Location = New-Object System.Drawing.Point([int](620 * $S), [int](8 * $S)); $ok.Anchor = 'Top,Right'
    $ok.DialogResult = 'OK'
    $bar.Controls.Add($ok)
    $f.Controls.Add($tb); $f.Controls.Add($bar); $f.Controls.Add($bn)
    $f.AcceptButton = $ok
    [void]$f.ShowDialog()
    $f.Dispose()
}

# The checklist at the end of one button.
function Show-FixItTestChecklist {
    param([string]$Title, $Records, [string]$Said = '')
    $recs = @($Records)
    $lines = @(Format-FixItTestChecklist -Title $Title -Records $recs -Said $Said)
    $st = Get-FixItWorstStatus -Statuses @($recs | ForEach-Object { $_.Status })
    Write-FixItLog ('Test mode checklist - {0}: {1} ({2})' -f $Title, $st, (Get-FixItTestSummaryLine -Records $recs)) 'TEST'
    Show-FixItTextDialog -Title ('Family Fix-It (Test mode) - {0}' -f $Title) -Lines $lines -Status $st -Heading ('{0}: {1}' -f $st, $Title)
}

function Show-FixItTestOutcome {
    param([string]$Title, $Result = $null)
    if (@(Get-FixItTestRecords).Count -eq 0 -and $null -eq $Result) { return }
    Complete-FixItTestRecords -Result $Result
    $recs = @(Get-FixItTestRecords)
    $said = Get-FixItTestSaid -Result $Result
    Show-FixItTestChecklist -Title $Title -Records $recs -Said $said
}

function Invoke-GuiTestAll {
    $q = "Test all buttons?`r`n`r`nThis checks every fix one after the other, answering Yes to each question. Nothing is changed, closed, restarted or sent. The results are saved on your Desktop."
    $a = [System.Windows.Forms.MessageBox]::Show($q, 'Family Fix-It (Test mode)', 'YesNo', 'Question')
    if ($a -ne 'Yes') { return }
    foreach ($x in $script:FixButtons) { $x.Enabled = $false; $x.Invalidate() }
    $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $script:ActionBusy = $true
    try {
        $res = @(Invoke-FixItTestAll -Progress { param($i, $n, $t) $script:StatusLabel.Text = ('Testing {0} of {1}: {2}' -f $i, $n, $t); $script:Form.Refresh(); try { [System.Windows.Forms.Application]::DoEvents() } catch { } })
        $path = ''
        try { $path = Save-FixItTestResults -Results $res } catch { Write-FixItLog ('Could not save the test results: {0}' -f $_.Exception.Message) 'ERROR' }
        $lines = @()
        foreach ($r in $res) { $lines += ('[{0}] {1}' -f $r.Status, $r.Title) }
        $lines += ''
        if ($path) { $lines += ('The full results are saved here:'); $lines += $path } else { $lines += 'The results file could not be saved.' }
        $st = Get-FixItWorstStatus -Statuses @($res | ForEach-Object { $_.Status })
        $script:StatusLabel.Text = (Get-FixItIdleStatus)
        Show-FixItTextDialog -Title 'Family Fix-It (Test mode) - all buttons' -Lines $lines -Status $st -Heading ('{0}: all buttons tested' -f $st)
    } catch {
        Write-FixItLog ('Test all failed: {0}' -f $_.Exception.Message) 'ERROR'
        [void][System.Windows.Forms.MessageBox]::Show(('Test all stopped: {0}' -f $_.Exception.Message), 'Family Fix-It (Test mode)', 'OK', 'Warning')
    } finally {
        $script:ActionBusy = $false
        $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default
        foreach ($x in $script:FixButtons) { $x.Enabled = $true; $x.Invalidate() }
    }
}

function Invoke-GuiButton {
    param([string]$Which)
    if (-not $Which) { return }
    # Always say what was clicked (never the file or search text), so a freeze can be traced in the log.
    $clickName = $Which; $ci = $Which.IndexOf(':'); if ($ci -gt 0) { $clickName = $Which.Substring(0, $ci + 1) }
    Write-FixItLog ('Button clicked: {0}' -f $clickName)
    if ($script:ActionBusy) { Write-FixItLog ('Ignored a click on {0}: another action is still running' -f $clickName) 'INFO'; return }
    if ($Which -eq 'TestAll') { if ($script:TestMode) { Invoke-GuiTestAll }; return }
    if ($script:TestMode) { Start-FixItTestButton }
    if ($Which -like 'OpenFile:*' -or $Which -like 'ShowFile:*') {
        $p = $Which.Substring(9)
        $r = $null
        if ($Which -like 'OpenFile:*') { $r = Open-FixItFoundFile -Path $p } else { $r = Show-FixItFoundFile -Path $p }
        if ($script:TestMode) { Show-FixItTestOutcome -Title 'Open a file' -Result $r }
        elseif ($r -and -not $r.Ok) { Show-FixItResult $r }
        return
    }
    if ($Which -like 'InstallApp:*') {
        $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $ir = Invoke-InstallApp -AppName $Which.Substring(11)
            if ($script:TestMode) { Show-FixItTestOutcome -Title 'Install an app safely' -Result $ir } else { Show-FixItResult $ir }
        } catch { Write-FixItLog ('Install failed: {0}' -f $_.Exception.Message) 'ERROR'; Show-FixItResult (New-FixItResult $false 'Could not install it' 'Something went wrong. Please click "Send Trey a report".') }
        finally { $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default }
        return
    }
    if ($Which -eq 'Pin') { Show-FixItGuideSteps -Guide (Get-FixItPinGuide); return }
    if ($Which -like 'PrinterPick:*') {
        $script:PickedPrinter = $Which.Substring(12)
        if ($script:PickDialog) { $script:PickDialog.Close() }
        return
    }
    if ($Which -eq 'Files') { Show-FixItFilesDialog; return }
    if ($Which -eq 'PCInfo') { Show-FixItResult (Invoke-PcInfo); return }
    if ($Which -eq 'Guides') { Show-FixItGuidesDialog; return }
    if ($Which -like 'Guide:*') {
        $gid = $Which.Substring(6)
        $gg = @($script:GuidesAll | Where-Object { $_.Id -eq $gid } | Select-Object -First 1)
        if ($gg.Count -gt 0) { Show-FixItGuideSteps -Guide $gg[0] }
        return
    }
    if ($Which -like 'GuideHelp:*') {
        $gid = $Which.Substring(10)
        $gg = @($script:GuidesAll | Where-Object { $_.Id -eq $gid } | Select-Object -First 1)
        $gt = $gid; if ($gg.Count -gt 0) { $gt = [string]$gg[0].Title } elseif ($script:GuideShown -and [string]$script:GuideShown.Id -eq $gid) { $gt = [string]$script:GuideShown.Title }
        Send-FixItGuideNote -Note ('The person followed the help guide "{0}" and it did not help.' -f (Clear-FixItGuideText $gt 80))
        return
    }
    if ($Which -like 'GuideNone:*') { Send-FixItGuideNote -Note (Get-FixItNoGuideNote -Query $Which.Substring(10)); return }
    if ($Which -eq 'Simple') { [void](Invoke-SimpleToggle -Mode 'Toggle'); $script:RebuildUi = $true; $script:Form.Close(); return }
    if ($Which -eq 'Install') { Show-FixItAppsDialog; return }
    if ($Which -eq 'BigText' -or $Which -eq 'Contrast') {
        if ($Which -eq 'BigText') { Set-FixItSetting -Name 'BigText' -Value $(if ($script:UiBigText) { '0' } else { '1' }) }
        else { Set-FixItSetting -Name 'HighContrast' -Value $(if ($script:UiHighContrast) { '0' } else { '1' }) }
        $script:RebuildUi = $true
        $script:Form.Close()
        return
    }
    # Every main button first shows what it will do. Go Back does nothing.
    if (-not (Confirm-FixItPlan -Which $Which)) { return }
    foreach ($x in $script:FixButtons) { $x.Enabled = $false; $x.Invalidate() }
    $script:StatusLabel.Text = 'Working on it... please wait. Do not turn off the computer.'
    $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $script:Form.Refresh()
    try {
        $script:ActionBusy = $true
        try { $r = Invoke-FixItAction -Which $Which -SkipPlan } finally { $script:ActionBusy = $false }
        if ($r) { $script:StatusLabel.Text = $r.Title } else { $script:StatusLabel.Text = (Get-FixItIdleStatus) }
        if (-not $script:TestMode) { Show-FixItResult $r }
        $script:StatusLabel.Text = (Get-FixItIdleStatus)
        $f = Invoke-FixItFollowUp -Which $Which -Result $r
        if ($script:TestMode) { Show-FixItTestOutcome -Title ([string](Get-FixItActionTable)[$Which].Title) -Result $r }
        elseif ($f) { Show-FixItResult $f }
        if ($Which -eq 'CheckIn' -or $Which -eq 'Guardian') { $script:RebuildUi = $true; $script:Form.Close() }
    } catch {
        Write-FixItLog ('Unexpected problem: {0}' -f $_.Exception.Message) 'ERROR'
        $script:StatusLabel.Text = 'Something went wrong.'
        [void][System.Windows.Forms.MessageBox]::Show('Sorry, something unexpected went wrong. Please click "Send Trey a report".', 'Family Fix-It', 'OK', 'Warning')
    } finally {
        $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default
        foreach ($x in $script:FixButtons) { $x.Enabled = $true; $x.Invalidate() }
    }
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
function Write-AdminResult {
    param($Result)
    if ($script:TestMode) { return }
    if ($script:UndoCur) {
        $Result | Add-Member -NotePropertyName UndoSteps -NotePropertyValue @($script:UndoCur.Steps) -Force
        $Result | Add-Member -NotePropertyName UndoCannot -NotePropertyValue @($script:UndoCur.Cannot) -Force
    }
    if ($ResultFile) {
        try { [IO.File]::WriteAllText($ResultFile, ($Result | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false))) } catch { Write-FixItLog ('Could not write result file: {0}' -f $_.Exception.Message) 'ERROR' }
    }
}

function Start-FamilyFixIt {
    Initialize-FixItLog
    $script:GuiActive = $false
    $script:Background = ($script:BackgroundActions -contains $Action)
    $script:AssumeYes = [bool]$Yes
    $script:EchoLog = ($Action -ne 'Gui' -and $Action -ne 'Guardian' -and $Action -notlike '*Admin')
    Write-FixItLog ('--- Family Fix-It {0} started: action={1} dryRun={2} background={5} yes={6} user={3} admin={4}' -f $script:FixItVersion, $Action, $script:DryRun, $env:USERNAME, $(try { Test-FixItAdmin } catch { 'unknown' }), $script:Background, $script:AssumeYes)
    $exit = 0
    if ($script:TestMode) { Write-FixItLog 'TEST MODE is on: every change step is only checked. Nothing will be changed, closed, restarted or sent.' 'TEST' }
    if ($script:TestMode -and ($Action -eq 'Guardian' -or $Action -eq 'GuardianDemo' -or $Action -like '*Admin')) {
        # the watcher, its demo and the administrator parts are helpers that other buttons start; Test mode checks them through those buttons
        Write-Host ('Test mode does not run "{0}" on its own. It is checked through the buttons that start it (try -Action TestAll).' -f $Action)
        Write-FixItLog ('Test mode: "{0}" was not run on its own' -f $Action) 'TEST'
        return 0
    }
    if ($Action -like '*Admin' -and $Action -ne 'UndoAdmin') { Start-FixItUndoRecord -Fix $Action -Title $Action }
    try {
        switch ($Action) {
            'Gui'                { Show-FixItWindow }
            'TestAll'            {
                $res = @(Invoke-FixItTestAll)
                $path = ''
                try { $path = Save-FixItTestResults -Results $res } catch { Write-FixItLog ('Could not save the test results: {0}' -f $_.Exception.Message) 'ERROR' }
                Write-Host 'TEST MODE - every button was checked. Nothing was changed.'
                foreach ($r in $res) { Write-Host ('  [{0}] {1}' -f $r.Status, $r.Title) }
                if ($path) { Write-Host ('Results saved: {0}' -f $path) }
                if (@($res | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0) { $exit = 1 }
            }
            'Printer'           { [void](Invoke-FixItAndShow -Which 'Printer') }
            'Acrobat'           { [void](Invoke-FixItAndShow -Which 'Acrobat') }
            'AcrobatRepair'     { [void](Invoke-FixItAndShow -Which 'AcrobatRepair') }
            'Outlook'           { [void](Invoke-FixItAndShow -Which 'Outlook') }
            'Network'           { [void](Invoke-FixItAndShow -Which 'Network') }
            'Slow'              { [void](Invoke-FixItAndShow -Which 'Slow') }
            'Sound'             { [void](Invoke-FixItAndShow -Which 'Sound') }
            'Browser'           { [void](Invoke-FixItAndShow -Which 'Browser') }
            'WinUpdate'         { [void](Invoke-FixItAndShow -Which 'WinUpdate') }
            'OneDrive'          { [void](Invoke-FixItAndShow -Which 'OneDrive') }
            'Scam'              { [void](Invoke-FixItAndShow -Which 'Scam') }
            'Screen'            { [void](Invoke-FixItAndShow -Which 'Screen') }
            'Report'            { [void](Invoke-FixItAndShow -Which 'Report') }
            'Pin'               { [void](Invoke-FixItAndShow -Which 'Pin') }
            'Update'            { [void](Invoke-FixItAndShow -Which 'Update') }
            'Restart'           { [void](Invoke-FixItAndShow -Which 'Restart') }
            'Status'            { [void](Invoke-FixItAndShow -Which 'Status') }
            'Undo'              { [void](Invoke-FixItAndShow -Which 'Undo') }
            'CheckIn'            { Show-FixItResult (Invoke-CheckInToggle -Mode 'Toggle') }
            'CheckInOn'          { $r = (Invoke-CheckInToggle -Mode 'On'); Show-FixItResult $r; if ($null -ne $r -and -not $r.Ok) { $exit = 1 } }
            'CheckInOff'         { $r = (Invoke-CheckInToggle -Mode 'Off'); Show-FixItResult $r; if ($null -ne $r -and -not $r.Ok) { $exit = 1 } }
            'HealthCheck'        { Show-FixItResult (Invoke-HealthCheck) }
            'History'            { Show-FixItResult (Invoke-HistoryShow) }
            'Files'              { Show-FixItResult (Invoke-FilesHelper) }
            'Install'            { Show-FixItResult (Invoke-InstallApp) }
            'Guardian'           { Show-FixItResult (Invoke-GuardianRun) }
            'GuardianOn'         { $r = (Invoke-GuardianToggle -Mode 'On'); Show-FixItResult $r; if ($null -ne $r -and -not $r.Ok) { $exit = 1 } }
            'GuardianOff'        { $r = (Invoke-GuardianToggle -Mode 'Off'); Show-FixItResult $r; if ($null -ne $r -and -not $r.Ok) { $exit = 1 } }
            'GuardianDemo'       { Show-FixItResult (Invoke-GuardianDemo) }
            'PCInfo'             { Show-FixItResult (Invoke-PcInfo) }
            'Guides'             { Show-FixItResult (Invoke-GuidesHelper) }
            'Simple'             { Show-FixItResult (Invoke-SimpleToggle -Mode 'Toggle') }
            'UndoAdmin'          { $r = Invoke-UndoAdmin; Write-AdminResult $r; if (-not $r.Ok) { $exit = 1 } }
            'PrinterAdmin'       { $r = Invoke-PrinterAdmin; Write-AdminResult $r; if (-not $r.Ok) { $exit = 1 } }
            'AcrobatAdmin'       { $r = Invoke-AcrobatAdmin; Write-AdminResult $r; if (-not $r.Ok) { $exit = 1 } }
            'AcrobatRepairAdmin' { $r = Invoke-AcrobatRepairAdmin; Write-AdminResult $r; if (-not $r.Ok) { $exit = 1 } }
            'NetworkAdmin'       { $r = Invoke-NetworkAdmin; Write-AdminResult $r; if (-not $r.Ok) { $exit = 1 } }
            'SlowAdmin'          { $r = Invoke-SlowAdmin; Write-AdminResult $r; if (-not $r.Ok) { $exit = 1 } }
            'SoundAdmin'         { $r = Invoke-SoundAdmin; Write-AdminResult $r; if (-not $r.Ok) { $exit = 1 } }
            'OutlookAdmin'       { $r = Invoke-OutlookAdmin; Write-AdminResult $r; if (-not $r.Ok) { $exit = 1 } }
            'DefenderScanAdmin'  { $r = Invoke-DefenderScanAdmin; Write-AdminResult $r; if (-not $r.Ok) { $exit = 1 } }
            'WinUpdateAdmin'     { $r = Invoke-WinUpdateAdmin; Write-AdminResult $r; if (-not $r.Ok) { $exit = 1 } }
            'WinUpdateDeepAdmin' { $r = Invoke-WinUpdateDeepAdmin; Write-AdminResult $r; if (-not $r.Ok) { $exit = 1 } }
        }
    } catch {
        Write-FixItLog ('Unexpected problem: {0}' -f $_.Exception.Message) 'ERROR'
        if ($Action -like '*Admin') {
            Write-AdminResult (New-FixItResult $false 'Error' $_.Exception.Message)
            $exit = 1
        } else {
            Write-Host 'Sorry, something unexpected went wrong. Please make a report and send it to Trey.'
            $exit = 1
        }
    }
    Write-FixItLog ('--- Family Fix-It finished: action={0}' -f $Action)
    return $exit
}

if (-not $LibraryOnly) {
    $code = Start-FamilyFixIt
    exit $code
}
