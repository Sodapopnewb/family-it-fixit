# Tests for Family Fix-It. Runs anywhere PowerShell 7 runs (Windows-only calls are replaced with pretend ones).
# Usage:  pwsh ./tests/Test-FixIt.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fixit-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:Pass = 0; $script:Fail = 0
function Assert { param([bool]$Cond, [string]$Name) if ($Cond) { $script:Pass++ } else { $script:Fail++; Write-Host ('  FAIL: ' + $Name) -ForegroundColor Red } }
function Section { param([string]$T) Write-Host ('== ' + $T) }

$logFile = Join-Path $tmp 'test.log'
. (Join-Path $root 'FamilyFixIt.ps1') -LibraryOnly -LogPath $logFile
Initialize-FixItLog

# ---------------------------------------------------------------- pretend Windows
$script:Calls = New-Object System.Collections.ArrayList
function Rec { param([string]$S) [void]$script:Calls.Add($S) }
function CallsLike { param([string]$P) return @($script:Calls | Where-Object { $_ -like $P }).Count }

$script:Reg = @{}
function Reset-Reg { $script:Reg = @{} }
function Add-RegPretend { param([string]$P, [hashtable]$V = @{}) $script:Reg[$P] = $V }
function Test-RegKey { param([string]$Path) return $script:Reg.ContainsKey($Path) }
function Get-RegValueNames { param([string]$Path) if (-not $script:Reg.ContainsKey($Path)) { return @() } return @($script:Reg[$Path].Keys) }
function Get-RegValue { param([string]$Path, [string]$Name) if ($script:Reg.ContainsKey($Path) -and $script:Reg[$Path].ContainsKey($Name)) { $v = $script:Reg[$Path][$Name]; if ($v -is [byte[]]) { return , $v }; return $v } return $null }
function Set-RegDword { param([string]$Path, [string]$Name, [int]$Value) Rec "regset $Path $Name=$Value"; if (-not $script:Reg.ContainsKey($Path)) { $script:Reg[$Path] = @{} }; $script:Reg[$Path][$Name] = $Value }
function Remove-RegValue { param([string]$Path, [string]$Name) Rec "regdel $Path $Name"; $script:Reg[$Path].Remove($Name) }
function RegSnapshot { return ($script:Reg.Keys | Sort-Object | ForEach-Object { $k = $_; ($script:Reg[$k].Keys | Sort-Object | ForEach-Object { '{0}|{1}|{2}' -f $k, $_, ($script:Reg[$k][$_] -join ',') }) }) -join ';' }

$script:Admin = $true
function Test-FixItAdmin { return $script:Admin }
$script:Spooler = [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' }
function Get-SpoolerState { return [pscustomobject]@{ Status = $script:Spooler.Status; StartType = $script:Spooler.StartType } }
function Stop-SpoolerService { Rec 'spooler stop'; $script:Spooler.Status = 'Stopped' }
function Start-SpoolerService { Rec 'spooler start'; $script:Spooler.Status = 'Running' }
$script:Printers = @()
$script:Reachable = @{}
$script:AddFails = @{}
function Get-FixItPrinters { return $script:Printers }
function Test-HostReachable { param([string]$ComputerName) Rec "ping $ComputerName"; return [bool]$script:Reachable[$ComputerName] }
function Remove-FixItPrinter { param([string]$Name) Rec "printer remove $Name" }
function Add-FixItPrinterConnection { param([string]$Name) Rec "printer add $Name"; if ($script:AddFails[$Name]) { throw 'pretend add failure' } }
function Set-FixItDefaultPrinter { param([string]$Name) Rec "printer default $Name"; foreach ($pp in @($script:Printers)) { $pp.IsDefault = ([string]$pp.Name -eq $Name) } }
$script:Running = @()
function Get-RunningApp { param([string[]]$ProcessNames) return @($script:Running | Where-Object { $ProcessNames -contains $_ }) }
$script:CloseWorks = $true
function Request-AppClose { param([string[]]$ProcessNames) Rec "close $($ProcessNames -join ',')"; if ($script:CloseWorks) { $script:Running = @($script:Running | Where-Object { $ProcessNames -notcontains $_ }) } }
$script:Products = @()
function Get-InstalledProducts { return $script:Products }
$script:MsiCode = 0
function Invoke-Msi { param([string]$ProductCode) Rec "msi /fa $ProductCode"; return $script:MsiCode }
$script:Answers = New-Object System.Collections.Queue
$script:Asked = New-Object System.Collections.ArrayList
function Confirm-FixIt { param([string]$Question, [string]$Title = '') [void]$script:Asked.Add($Question); if ($script:Answers.Count -gt 0) { return [bool]$script:Answers.Dequeue() } return $true }
function Open-FixItFile { param([string]$Path) Rec "open $Path" }
function Get-OutlookInfo { return [pscustomobject]@{ Installed = $true; Version = '16.0.17000.20000'; Bitness = 'x64'; Path = 'C:\x' } }
function Get-FixItFileVersion { param([string]$ExeName) return '24.002.20000' }
function Get-FixItEvents { param([string]$LogName, [int]$Max = 25) return @([pscustomobject]@{ TimeCreated = (Get-Date); ProviderName = 'Spooler'; Id = 7031; Message = ("The Print Spooler service terminated unexpectedly`r`nsecond line " + ('x' * 400)) }) }
function Get-FixItOsInfo { return [pscustomobject]@{ Caption = 'Windows 11 Pro'; Version = '10.0.22631'; Build = '22631'; Arch = '64-bit'; LastBoot = 'yesterday'; ComputerName = 'TESTPC'; UserName = 'tester'; FreeGB = 42.5 } }
$script:WebFail = $false
function Get-WebText { param([string]$Url) Rec "web $Url"; if ($script:WebFail) { throw 'offline' }; return [IO.File]::ReadAllText($script:WebMap[$Url]) }
function Save-WebFile { param([string]$Url, [string]$Dest) Rec "download $Url"; Copy-Item -LiteralPath $script:WebMap[$Url] -Destination $Dest }
$script:WebMap = @{}

function Reset-All {
    $script:Calls.Clear(); Reset-Reg; $script:Admin = $true; $script:DryRun = $false
    $script:Spooler = [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' }
    $script:Printers = @(); $script:Reachable = @{}; $script:AddFails = @{}; $script:Running = @(); $script:CloseWorks = $true
    $script:Products = @(); $script:MsiCode = 0; $script:Answers.Clear(); $script:Asked.Clear()
}
# ---- version 2 pretends
$env:SystemRoot = 'C:\Windows'
$env:TEMP = 'C:\Users\tester\AppData\Local\Temp'
function Start-Sleep { param([double]$Seconds, [int]$Milliseconds) }
function Start-Process { param($FilePath, $ArgumentList, $Verb, $WindowStyle, [switch]$PassThru) Rec "start $FilePath $($ArgumentList -join ' ')" }
function Get-FixItUndoFile { return (Join-Path $tmp 'undo.json') }
$script:State = @{}
function Get-FixItState { return [pscustomobject]$script:State }
function Set-FixItStateValue { param([string]$Name, [string]$Value) $script:State[$Name] = $Value }
function Set-RegDword { param([string]$Path, [string]$Name, [int]$Value) Register-FixItRegUndo -Path $Path -Name $Name; Rec "regset $Path $Name=$Value"; if (-not $script:Reg.ContainsKey($Path)) { $script:Reg[$Path] = @{} }; $script:Reg[$Path][$Name] = $Value }
function Set-RegString { param([string]$Path, [string]$Name, [string]$Value) Register-FixItRegUndo -Path $Path -Name $Name; Rec "regsets $Path $Name=$Value"; if (-not $script:Reg.ContainsKey($Path)) { $script:Reg[$Path] = @{} }; $script:Reg[$Path][$Name] = $Value }
function Remove-RegValue { param([string]$Path, [string]$Name) Register-FixItRegUndo -Path $Path -Name $Name; Rec "regdel $Path $Name"; $script:Reg[$Path].Remove($Name) }
function Restore-FixItRegValue {
    param([string]$Path, [string]$Name, [bool]$Existed, [string]$Type, [string]$Value)
    Rec "regrestore $Path $Name"
    if (-not $Existed) { if ($script:Reg.ContainsKey($Path) -and $script:Reg[$Path].ContainsKey($Name)) { $script:Reg[$Path].Remove($Name) }; return }
    if (-not $script:Reg.ContainsKey($Path)) { $script:Reg[$Path] = @{} }
    if ($Type -eq 'dword') { $script:Reg[$Path][$Name] = [int]$Value }
    elseif ($Type -eq 'binary') { $script:Reg[$Path][$Name] = [byte[]][Convert]::FromBase64String($Value) }
    else { $script:Reg[$Path][$Name] = $Value }
}
function Restore-FixItFile { param([string]$Backup, [string]$Original) Rec "filerestore $Backup -> $Original" }
function Restore-FixItFolder { param([string]$Path, [string]$Aside) Rec "folderrestore $Path <- $Aside" }
function Rename-FixItFolderAside { param([string]$Path, [string]$Tag) Rec "aside $Path"; return ($Path + '.fixit-old-' + $Tag) }
$script:Svc = @{}; $script:SvcFail = @()
function Get-FixItServiceStatus { param([string]$Name) if ($script:Svc.ContainsKey($Name)) { return $script:Svc[$Name] } return 'Running' }
function Stop-FixItService { param([string]$Name) Rec "svc stop $Name"; if ($script:SvcFail -contains $Name) { throw 'pretend service failure' }; $script:Svc[$Name] = 'Stopped' }
function Start-FixItService { param([string]$Name) Rec "svc start $Name"; $script:Svc[$Name] = 'Running' }
$script:ToolFail = @(); $script:ConnHeal = ''
function Invoke-FixItNative { param([string]$File, [string[]]$Arguments = @(), [switch]$Live) $k = "$File $($Arguments -join ' ')"; Rec "tool $k"; $code = 0; foreach ($f in $script:ToolFail) { if ($k -like $f) { $code = 1 } }; if ($script:ConnHeal -and $k -like $script:ConnHeal) { $script:Conn = @{ Gateway = '192.168.1.1'; Router = $true; Net = $true; Dns = $true; Web = $true } }; return [pscustomobject]@{ ExitCode = $code; Output = '' } }
$script:Free = [int64]50GB; $script:Uptime = 2.0; $script:Pending = $false
function Get-FixItFreeBytes { return [int64]$script:Free }
function Get-FixItUptimeDays { return $script:Uptime }
function Test-PendingReboot { return $script:Pending }
function Get-FixItLastUpdate { return 'KB5000000 on 2026-10-01' }
$script:Conn = @{}; $script:Https = @{}
function Get-FixItGateway { return [string]$script:Conn.Gateway }
function Test-FixItPing { param([string]$Target) if ($Target -eq '8.8.8.8') { return [bool]$script:Conn.Net }; return [bool]$script:Conn.Router }
function Test-FixItDns { param([string]$Name) return [bool]$script:Conn.Dns }
function Test-FixItWeb { return [bool]$script:Conn.Web }
function Test-FixItHttps { param([string]$Url) if ($script:Https.ContainsKey($Url)) { return [bool]$script:Https[$Url] } return $true }
function Get-FixItAdapters { return @('Wi-Fi') }
function Restart-FixItAdapter { param([string]$Name) Rec "adapter restart $Name" }
$script:Hung = @(); $script:Top = @()
function Get-FixItTopApps { param([int]$Count = 5) return @($script:Top) }
function Get-FixItHungApps { return @($script:Hung) }
function Stop-FixItApp { param([int]$Id) Rec "killapp $Id" }
function Clear-FixItFolder { param([string]$Path) if (-not (Test-SafeCleanPath -Path $Path)) { throw ('Refusing to clean this folder: {0}' -f $Path) }; Rec "clear $Path"; $script:Free += 1GB; return [int64]1GB }
function Clear-FixItRecycleBin { Rec 'recyclebin' }
function Get-FixItBrowserCacheFolders { return @([pscustomobject]@{ Browser = 'Edge'; Path = 'C:\Users\tester\AppData\Local\Microsoft\Edge\User Data\Default\Cache' }) }
$script:Spk = $null; $script:Mic = $null; $script:Cams = @()
function Get-FixItAudioDevice { param([string]$Kind) if ($Kind -eq 'Speakers') { return $script:Spk } return $script:Mic }
function Set-FixItAudioDevice { param([string]$Kind, [int]$Volume, [bool]$Muted = $false) Rec "audio $Kind $Volume muted=$Muted"; $d = $script:Mic; if ($Kind -eq 'Speakers') { $d = $script:Spk }; $d.Volume = $Volume; $d.Muted = $Muted }
function Get-FixItCameras { return @($script:Cams) }
function Open-FixItSettings { param([string]$Uri) Rec "settings $Uri" }
function Open-FixItUrl { param([string]$Url) Rec "url $Url" }
$script:Addins = @()
function Get-FixItOutlookAddins { return @($script:Addins) }
function Start-FixItOutlookSafe { Rec 'outlook safe' }
function Start-FixItOutlook { Rec 'outlook open' }
function Stop-FixItAppsByName { param([string[]]$ProcessNames) Rec "force end $($ProcessNames -join ',')"; if ($script:ForceWorks) { $script:Running = @($script:Running | Where-Object { $ProcessNames -notcontains $_ }) } }
function Test-FixItPortOpen { param([string]$Address, [int[]]$Ports) Rec "port $Address"; return [bool]$script:OpenPorts[$Address] }
function Select-FixItPrinter { param([string[]]$Names, [string]$Current = '') Rec "printer pick-list $($Names -join '|')"; if ($script:PickPrinter -eq '<none>') { return '' }; if ($script:PickPrinter) { return $script:PickPrinter }; return [string]$Names[0] }
function Show-FixItCountdown { param([int]$Seconds, [string]$Title = '', [string]$Message = '') Rec "countdown $Seconds"; if ($script:Heal) { $script:Conn.Router = $true; $script:Conn.Net = $true; $script:Conn.Dns = $true; $script:Conn.Web = $true } }
$script:ConsoleOk = $true
function Test-FixItConsoleInteractive { return [bool]$script:ConsoleOk }
function Read-FixItPlanChoice { param($Plan) $script:PlanSeen += , $Plan; return [bool]$script:PlanAnswer }
$script:BProfiles = @(); $script:BSettings = $null; $script:BExts = @()
function Get-FixItBrowserProfiles { return @($script:BProfiles) }
function Read-FixItChromeAnswer { return 'No' }   # the Chrome question is tested in Test-FixIt-V235.ps1
function Find-FixItChromeDeep { param([int]$MaxSeconds = 30, [string[]]$Roots = @(), [string[]]$ShortcutFolders = @()) return '' }
function Resolve-FixItBrowserExe { param([string]$Exe) return '' }
function Get-FixItBrowserSettings { param([string]$Dir) return $script:BSettings }
function Get-FixItBrowserExtensions { param([string]$Dir) return @($script:BExts) }
function Copy-FixItBackup { param([string]$Source, [string]$DestDir) Rec "backup $Source -> $DestDir" }
function Start-FixItDefenderScan { Rec 'defender scan' }
$script:OD = $null; $script:ODState = 'UpToDate'; $script:ODLast = $null; $script:KF = $null
function Get-FixItOneDriveInfo { return $script:OD }
function Get-FixItOneDriveSyncState { param([string]$Kind) return $script:ODState }
function Get-FixItOneDriveLastSync { return $script:ODLast }
function Get-FixItKnownFolders { return $script:KF }
function Start-FixItOneDriveReset { param([string]$Exe) Rec 'onedrive reset' }
function Start-FixItOneDrive { param([string]$Exe) Rec 'onedrive start' }
$script:Def = $null; $script:PendUp = 0
function Get-FixItDefender { return $script:Def }
function Get-FixItPendingUpdates { return $script:PendUp }
function Get-FixItCrashes { return @($script:Crashes) }
function Get-FixItUnexpectedShutdowns { return 0 }
function Get-FixItDiskHealth { return [pscustomobject]@{ Disks = @([pscustomobject]@{ Name = 'Test SSD'; Type = 'SSD'; Health = 'Healthy'; Status = 'OK' }); SmartPrediction = 'OK' } }
$script:Remote = @(); $script:Installs = @(); $script:Downloads = @(); $script:Crashes = @()
function Get-FixItRemoteToolProcesses { return @($script:Remote) }
function Get-FixItRecentInstalls { param([int]$Days = 14) return @($script:Installs) }
function Get-FixItRecentDownloads { param([int]$Days = 7, [int]$Max = 30) return @($script:Downloads) }
$script:Posts = New-Object System.Collections.ArrayList; $script:PostFail = $false; $script:PostCode = 202
function Send-WebReport { param([string]$Url, [string]$Json, [string]$AppValue) [void]$script:Posts.Add([pscustomobject]@{ Url = $Url; Json = $Json; App = $AppValue }); if ($script:PostFail) { throw 'pretend: no internet' }; return $script:PostCode }
$script:Tasks = @{}
function Test-FixItTask { param([string]$Name) return $script:Tasks.ContainsKey($Name) }
function Register-FixItTask { param([string]$Name, [string]$Xml) Rec "task create $Name"; $script:Tasks[$Name] = $Xml }
function Unregister-FixItTask { param([string]$Name) Rec "task delete $Name"; $script:Tasks.Remove($Name) }
function Restart-FixItNow { Rec 'restart now' }
function Restart-FixItComputer { Rec 'restart in 30' }
function New-V2Defaults {
    $script:Conn = @{ Gateway = '192.168.1.1'; Router = $true; Net = $true; Dns = $true; Web = $true }
    $script:Https = @{}; $script:ToolFail = @(); $script:ConnHeal = ''; $script:Svc = @{}; $script:SvcFail = @()
    $script:Free = [int64]50GB; $script:Uptime = 2.0; $script:Pending = $false; $script:Hung = @(); $script:Top = @()
    $script:Spk = [pscustomobject]@{ Name = 'Speakers (Realtek)'; Volume = 50; Muted = $false }
    $script:Mic = [pscustomobject]@{ Name = 'Microphone (USB)'; Volume = 60; Muted = $false }
    $script:Cams = @([pscustomobject]@{ Name = 'Integrated Camera'; Status = 'OK' })
    $script:Addins = @(); $script:ForceWorks = $true; $script:OpenPorts = @{}; $script:PickPrinter = ''; $script:PlanAnswer = $true; $script:PlanSeen = @(); $script:Heal = $false
    $script:BProfiles = @(); $script:BSettings = $null; $script:BExts = @()
    $script:OD = [pscustomobject]@{ Exe = 'C:\OneDrive\OneDrive.exe'; Installed = $true; Running = $true; Accounts = @([pscustomobject]@{ Kind = 'Personal'; Email = 'a@b.test'; Folder = 'C:\Users\tester\OneDrive' }) }
    $script:ODState = 'UpToDate'; $script:ODLast = (Get-Date).AddHours(-3)
    $script:KF = [pscustomobject]@{ Desktop = 'C:\Users\tester\OneDrive\Desktop'; Documents = 'C:\Users\tester\OneDrive\Documents'; Pictures = 'C:\Users\tester\OneDrive\Pictures' }
    $script:Def = [pscustomobject]@{ Enabled = $true; RealTime = $true; SignatureAgeDays = 1; LastQuickScan = (Get-Date).AddDays(-3) }
    $script:PendUp = 0; $script:Remote = @(); $script:Installs = @(); $script:Downloads = @(); $script:Crashes = @()
    $script:Posts.Clear(); $script:PostFail = $false; $script:PostCode = 202; $script:Tasks = @{}; $script:State = @{}
    if (Test-Path -LiteralPath (Get-FixItUndoFile)) { Remove-Item -LiteralPath (Get-FixItUndoFile) -Force }
    $script:UndoCur = $null
}
New-V2Defaults

$script:ResetAllBase = ${function:Reset-All}
$script:UacDeny = $false
function Reset-All { & $script:ResetAllBase; $script:UacDeny = $false; $script:WebFail = $false; New-V2Defaults }

function New-Spool {
    $d = Join-Path $tmp ('spool-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $d | Out-Null
    foreach ($n in @('00001.SPL', '00001.SHD', '00002.SPL', '00002.SHD', '00003.SHD')) { Set-Content -LiteralPath (Join-Path $d $n) 'x' }
    Set-Content -LiteralPath (Join-Path $d 'keepme.txt') 'x'
    $script:SpoolFolder = $d; return $d
}
$acro = [pscustomobject]@{ DisplayName = 'Adobe Acrobat (64-bit)'; DisplayVersion = '24.002.20000'; ProductCode = '{AC76BA86-1033-FFFF-BA7E-000000000001}'; WindowsInstaller = $true }
$hkcuAddin = 'HKCU:\Software\Microsoft\Office\Outlook\Addins\PDFMaker.OfficeAddin'
$hklmAddin = 'HKLM:\SOFTWARE\Microsoft\Office\Outlook\Addins\PDFMaker.OfficeAddin'
$resil = 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Resiliency'
function Seed-BrokenAcrobat {
    Add-RegPretend $hkcuAddin @{ LoadBehavior = 2; FriendlyName = 'Acrobat PDFMaker' }
    Add-RegPretend $hklmAddin @{ LoadBehavior = 0 }
    Add-RegPretend 'HKCU:\Software\Microsoft\Office\16.0\Outlook' @{}
    Add-RegPretend "$resil\DisabledItems" @{
        '1' = [byte[]][Text.Encoding]::Unicode.GetBytes('Acrobat PDFMaker Office COM Addin|PDFMaker.OfficeAddin')
        '2' = [byte[]][Text.Encoding]::Unicode.GetBytes('SomeOtherVendor.Addin')
    }
    Add-RegPretend "$resil\CrashingAddinList" @{ 'PDFMaker.OfficeAddin' = [byte[]](1, 2, 3); 'Other.Addin' = [byte[]](4, 5) }
    $script:Products = @($acro)
}

# ---------------------------------------------------------------- static checks
Section 'Static checks'
foreach ($f in @('FamilyFixIt.ps1', 'tools/Publish-FixIt.ps1', 'tests/Test-FixIt.ps1')) {
    $e = $null; $t = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root $f), [ref]$t, [ref]$e)
    Assert ($e.Count -eq 0) ("parses cleanly: $f")
}
foreach ($f in @('FamilyFixIt.ps1', 'Start-FixIt.cmd', 'README.md', 'tools/Publish-FixIt.ps1')) {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $root $f))
    Assert (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) ("plain ASCII only (safe for Windows PowerShell 5.1 without BOM): $f")
}
$src = [IO.File]::ReadAllText((Join-Path $root 'FamilyFixIt.ps1'))
Assert ($src -notmatch '(?i)Send-MailMessage|SmtpClient|MailMessage|Outlook\.Application|mailto:|Invoke-RestMethod|\.Post\(') 'script has no email code'
Assert (-not ($src -match '\s\?\?\s|&&|\|\|')) 'no PowerShell 7-only operators (??, &&, ||)'
Assert ((Get-Content (Join-Path $root 'Start-FixIt.cmd') -Raw) -match 'FamilyFixIt\.ps1') 'launcher points at the script'

# Windows PowerShell 5.1 cannot parse some things that PowerShell 7 accepts (a real PC hit this). Check every script's syntax tree.
Section 'Static checks: Windows PowerShell 5.1 compatible syntax'
$ast51 = [Management.Automation.Language.Ast]
foreach ($f in @('FamilyFixIt.ps1', 'Install-FixIt.ps1', 'tools/Publish-FixIt.ps1', 'tests/Test-FixIt.ps1')) {
    $e = $null; $t = $null
    $tree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $f), [ref]$t, [ref]$e)
    Assert ($e.Count -eq 0) "parses cleanly: $f"
    $bad = New-Object System.Collections.ArrayList
    foreach ($n in $tree.FindAll({ param($x) $true }, $true)) {
        $kind = $n.GetType().Name
        if ($kind -in @('TernaryExpressionAst', 'PipelineChainAst', 'UsingStatementAst')) {
            if ($kind -eq 'UsingStatementAst' -and $n.UsingStatementKind -eq 'Namespace') { [void]$bad.Add("using namespace at line $($n.Extent.StartLineNumber)") }
            elseif ($kind -ne 'UsingStatementAst') { [void]$bad.Add("$kind at line $($n.Extent.StartLineNumber)") }
        }
        if ($kind -eq 'IndexExpressionAst' -and $n.Index -is [Management.Automation.Language.ArrayLiteralAst]) {
            [void]$bad.Add("comma (multi) index at line $($n.Extent.StartLineNumber): $($n.Extent.Text)")
        }
        if ($kind -eq 'MemberExpressionAst' -and $n.NullConditional) { [void]$bad.Add("?. at line $($n.Extent.StartLineNumber)") }
        if ($kind -eq 'IndexExpressionAst' -and $n.NullConditional) { [void]$bad.Add("?[] at line $($n.Extent.StartLineNumber)") }
        if ($kind -eq 'ForEachStatementAst' -and ($n.Flags.ToString() -match 'Parallel')) { [void]$bad.Add("foreach -Parallel at line $($n.Extent.StartLineNumber)") }
        if ($kind -eq 'AssignmentStatementAst' -and $n.Operator.ToString() -match 'NullCoalescing') { [void]$bad.Add("??= at line $($n.Extent.StartLineNumber)") }
        if ($kind -eq 'BinaryExpressionAst' -and $n.Operator.ToString() -match 'NullCoalesc') { [void]$bad.Add("?? at line $($n.Extent.StartLineNumber)") }
        if ($kind -eq 'InvokeMemberExpressionAst' -and $n.Static -and $n.Member.Extent.Text -eq 'new' -and $n.Expression.Extent.Text -match '\[[^\]]*\[') { [void]$bad.Add("::new on a generic type at line $($n.Extent.StartLineNumber)") }
        if ($kind -eq 'CommandAst') {
            foreach ($el in $n.CommandElements) { if ($el -is [Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -eq 'Parallel') { [void]$bad.Add("-Parallel at line $($el.Extent.StartLineNumber)") } }
        }
    }
    Assert ($bad.Count -eq 0) ("no PowerShell-7-only or 5.1-unsafe syntax in $f" + $(if ($bad.Count) { ': ' + ($bad -join '; ') } else { '' }))
}
# the same check, but on the text of every script, for the easy-to-miss spellings
foreach ($f in @('FamilyFixIt.ps1', 'Install-FixIt.ps1', 'tools/Publish-FixIt.ps1')) {
    $lines = [IO.File]::ReadAllLines((Join-Path $root $f))
    $hits = @(); $ln = 0
    foreach ($line in $lines) {
        $ln++
        if ($line -match '^\s*#') { continue }
        if ($line -match '\$\w+\[[^\]\r\n]*\)\s*,|\$\w+\[[^\]\r\n]*,\s*\(' -and $line -match '\[math\]::|\.Substring\(|\(\$\w+\[') { $hits += "line ${ln}: comma index near a method call" }
        if ($line -match '\?\.\w|\?\[|\s\?\?=?\s') { $hits += "line ${ln}: null-conditional / null-coalescing" }
    }
    Assert ($hits.Count -eq 0) ("no multi-index or null operators in text of $f" + $(if ($hits.Count) { ': ' + ($hits -join '; ') } else { '' }))
}
# PSScriptAnalyzer's compatibility rule for 5.1, when it is installed on the machine running the tests
if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
    Import-Module PSScriptAnalyzer
    $psaSettings = @{ Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') } } }
    foreach ($f in @('FamilyFixIt.ps1', 'Install-FixIt.ps1', 'tools/Publish-FixIt.ps1')) {
        $r = @(Invoke-ScriptAnalyzer -Path (Join-Path $root $f) -Settings $psaSettings -IncludeRule PSUseCompatibleSyntax)
        Assert ($r.Count -eq 0) ("PSScriptAnalyzer PSUseCompatibleSyntax (5.1): $f" + $(if ($r.Count) { ': ' + (($r | ForEach-Object { "line $($_.Line) $($_.Message)" }) -join '; ') } else { '' }))
    }
} else { Write-Host '  (PSScriptAnalyzer not installed here: using the built-in syntax-tree checks only)' }
# edit distance gives the right answers
Assert ((Get-FixItEditDistance -A 'printer' -B 'printer') -eq 0) 'edit distance: same word is 0'
Assert ((Get-FixItEditDistance -A 'printer' -B 'pritner') -eq 1) 'edit distance: swapped letters are 1'
Assert ((Get-FixItEditDistance -A 'printer' -B 'printr') -eq 1) 'edit distance: one letter missing is 1'
Assert ((Get-FixItEditDistance -A 'wifi' -B 'wiffi') -eq 1) 'edit distance: one extra letter is 1'
Assert ((Get-FixItEditDistance -A 'cat' -B 'dog' -Max 3) -eq 3) 'edit distance: three different letters is 3'
Assert ((Get-FixItEditDistance -A 'cat' -B 'elephant' -Max 2) -eq 3) 'edit distance: gives up on very different lengths'

# ---------------------------------------------------------------- printer
Section 'Printer: spooler + spool folder'
Reset-All; $d = New-Spool
$r = Invoke-PrinterAdmin
Assert ($r.Ok) 'admin part succeeds'
Assert ($r.Cleared -eq 3) 'counts 3 stuck jobs'
Assert (@(Get-ChildItem $d -File).Name -join ',' -eq 'keepme.txt') 'only .SPL/.SHD removed, other file kept'
Assert ((CallsLike 'spooler stop') -eq 1 -and (CallsLike 'spooler start') -eq 1) 'spooler stopped then started once'
Assert (($script:Calls[0] -eq 'spooler stop') -and ($script:Calls[1] -eq 'spooler start')) 'stop happens before start'
$script:Calls.Clear()
$r2 = Invoke-PrinterAdmin
Assert ($r2.Ok -and $r2.Cleared -eq 0) 'idempotent: second run ok, nothing left to clear'
Reset-All; $d = New-Spool; $script:DryRun = $true
$r = Invoke-PrinterAdmin
Assert ($r.Ok) 'dry-run ok'
Assert (@(Get-ChildItem $d -File).Count -eq 6) 'dry-run: no files deleted'
Assert ($script:Calls.Count -eq 0) 'dry-run: spooler untouched'
Assert ((Get-Content $logFile -Raw) -match '\[DRYRUN\] Would do: Delete stuck print file') 'dry-run logged "Would do"'

Section 'Printer: network printers'
function NetPrinter { param($Name, $Offline = $false, $Default = $false) [pscustomobject]@{ Name = $Name; IsNetwork = $Name.StartsWith('\\'); Server = $(if ($Name.StartsWith('\\')) { ($Name.TrimStart('\') -split '\\')[0] } else { '' }); PortName = 'x'; StatusText = $(if ($Offline) { 'Offline' } else { 'Normal' }); WorkOffline = $Offline; IsDefault = $Default } }
Reset-All
$script:Printers = @((NetPrinter '\\HOMEPC\Laser' $true $true), (NetPrinter '\\HOMEPC\Good' $false), (NetPrinter '\\GONE\Inkjet' $true), (NetPrinter 'USB Printer' $true))
$script:Reachable = @{ 'HOMEPC' = $true; 'GONE' = $false }
$u = Invoke-PrinterRefreshUser
Assert ($u.Fixed -eq 1) 'one offline reachable network printer reconnected'
Assert ((CallsLike 'printer remove \\HOMEPC\Laser') -eq 1 -and (CallsLike 'printer add \\HOMEPC\Laser') -eq 1) 'removed and re-added the offline one'
Assert ((CallsLike '*Good*') -eq 0) 'healthy printer untouched'
Assert ((CallsLike 'printer remove \\GONE*') -eq 0) 'unreachable server: printer NOT removed (no data loss)'
Assert ((CallsLike 'printer default \\HOMEPC\Laser') -eq 1) 'default printer restored'
Assert ($u.Problems -eq 2 -and @($u.Notes).Count -eq 2) 'two problems explained in plain words (unreachable + local offline)'
Reset-All
$script:Printers = @((NetPrinter '\\HOMEPC\Laser' $true)); $script:Reachable = @{ 'HOMEPC' = $true }; $script:AddFails = @{ '\\HOMEPC\Laser' = $true }
$u = Invoke-PrinterRefreshUser
Assert ($u.Fixed -eq 0 -and $u.Problems -eq 1) 'failed re-add is reported, not hidden'
Assert ((CallsLike 'printer add *') -eq 2) 're-add retried once'
Reset-All; $script:DryRun = $true
$script:Printers = @((NetPrinter '\\HOMEPC\Laser' $true $true)); $script:Reachable = @{ 'HOMEPC' = $true }
$u = Invoke-PrinterRefreshUser
Assert ((CallsLike 'printer *') -eq 0) 'dry-run: no printer changes'

Section 'Printer: whole flow'
Reset-All; $d = New-Spool
$script:Printers = @((NetPrinter 'Office Printer' $false $true))
$res = Invoke-PrinterFix
Assert ($res.Ok -and $res.Title -eq 'Printer fixed') 'full printer fix: success message'
Assert ($res.Message -notmatch '(?i)spooler|exception|registry') 'success message is jargon free'
Reset-All; $d = New-Spool; $script:Admin = $false
function Start-FixItElevated { param([string]$Part, [string]$ResultPath) Rec "elevate $Part"; $r = Invoke-PrinterAdmin; [IO.File]::WriteAllText($ResultPath, ($r | ConvertTo-Json -Depth 4)); return 0 }
$script:Printers = @()
$res = Invoke-PrinterFix
Assert ($res.Ok -and (CallsLike 'elevate PrinterAdmin') -eq 1) 'non-admin: only the admin step is elevated, result comes back through the file'
Assert ($res.Details -join ' ' -match 'Cleared 3') 'elevated result details carried back (cleared 3)'
function Start-FixItElevated { param([string]$Part, [string]$ResultPath) Rec "elevate $Part"; throw 'The operation was canceled by the user' }
Reset-All; $d = New-Spool; $script:Admin = $false
$res = Invoke-PrinterFix
Assert (-not $res.Ok -and $res.Message -match 'permission') 'UAC declined: friendly message'
Assert (@(Get-ChildItem $d -File).Count -eq 6) 'UAC declined: nothing deleted'
Reset-All; $d = New-Spool; $script:DryRun = $true; $script:Admin = $false
$res = Invoke-PrinterFix
Assert ($res.Ok -and $res.Title -eq 'Practice run' -and $script:Calls.Count -eq 0) 'dry-run flow: no elevation, no changes'

Section 'Acrobat in Outlook'
# Acrobat now starts gently: close Outlook completely, reopen, ask. Only "no" goes on to the settings fix.
# AcroNo = "Is Acrobat showing?" -> No, "Continue?" -> Yes
function AcroNo { $script:Answers.Enqueue($false); $script:Answers.Enqueue($true) }
Reset-All; Seed-BrokenAcrobat
$snap0 = RegSnapshot
$res = Invoke-AcrobatFix
Assert ($res.Ok -and $res.Title -eq 'Acrobat fixed' -and (RegSnapshot) -eq $snap0) 'Acrobat showing after a plain close and reopen: stops, changes no settings'
Assert ((CallsLike 'outlook open') -eq 1 -and $res.SkipFollowUp) 'stopped after step 1: Outlook reopened once, no extra question'
Reset-All; Seed-BrokenAcrobat; $script:Answers.Enqueue($false); $script:Answers.Enqueue($false); $snap0 = RegSnapshot
$res = Invoke-AcrobatFix
Assert (-not $res.Ok -and (RegSnapshot) -eq $snap0 -and $res.Message -match 'call Trey') 'still missing and does not want the next step: stops, nothing changed'
Reset-All; Seed-BrokenAcrobat; AcroNo
$res = Invoke-AcrobatFix
Assert ($res.Ok) 'fix succeeds'
Assert ((Get-RegValue $hkcuAddin 'LoadBehavior') -eq 3 -and (Get-RegValue $hklmAddin 'LoadBehavior') -eq 3) 'LoadBehavior=3 in HKCU and HKLM'
Assert (-not (Test-RegKey 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\Outlook\Addins\PDFMaker.OfficeAddin')) 'does not invent a registry key that was not there'
Assert (@(Get-RegValueNames "$resil\DisabledItems") -join ',' -eq '2') 'Acrobat entry removed from DisabledItems, other add-in kept'
Assert (@(Get-RegValueNames "$resil\CrashingAddinList") -join ',' -eq 'Other.Addin') 'Acrobat entry removed from CrashingAddinList, other kept'
Assert ((Get-RegValue "$resil\DoNotDisableAddinList" 'PDFMaker.OfficeAddin') -eq 1) 'added to DoNotDisableAddinList'
Assert ($res.Message -match 'Acrobat') 'plain success message'
$snap = RegSnapshot; $script:Calls.Clear(); $script:Answers.Clear(); AcroNo
$res = Invoke-AcrobatFix
Assert ($res.Ok -and (RegSnapshot) -eq $snap -and (CallsLike 'reg*') -eq 0) 'idempotent: second run changes nothing'
Assert ((@($script:Asked) -join ' ') -match 'already') 'second run says it was already on'

Reset-All; Seed-BrokenAcrobat; $script:DryRun = $true; $snap = RegSnapshot
$res = Invoke-AcrobatFix
Assert ((RegSnapshot) -eq $snap -and $script:Calls.Count -eq 0) 'dry-run: registry untouched'
Assert ($res.Title -eq 'Practice run') 'dry-run says it was practice'
Assert ((Get-Content $logFile -Raw) -match 'Would do: Set LoadBehavior=3 at HKLM:') 'dry-run logs the HKLM change it would make'

Reset-All; Seed-BrokenAcrobat; $script:Admin = $false; AcroNo
function Start-FixItElevated { param([string]$Part, [string]$ResultPath) Rec "elevate $Part"; $r = Invoke-AcrobatAdmin; [IO.File]::WriteAllText($ResultPath, ($r | ConvertTo-Json -Depth 4)); return 0 }
$res = Invoke-AcrobatFix
Assert ($res.Ok -and (CallsLike 'elevate AcrobatAdmin') -eq 1 -and (Get-RegValue $hklmAddin 'LoadBehavior') -eq 3) 'HKLM change goes through the elevated step'
Assert ((CallsLike 'regset HKCU*') -ge 1) 'HKCU changes done without elevation'
Reset-All; Seed-BrokenAcrobat; $script:Admin = $false; AcroNo
Add-RegPretend $hklmAddin @{ LoadBehavior = 3 }
$res = Invoke-AcrobatFix
Assert ($res.Ok -and (CallsLike 'elevate*') -eq 0) 'no admin needed (and none asked) when only HKCU needs fixing'

Reset-All; Seed-BrokenAcrobat; $script:Running = @('OUTLOOK', 'olk'); $script:Answers.Enqueue($true); AcroNo
$res = Invoke-AcrobatFix
Assert ((CallsLike 'close OUTLOOK*') -ge 1 -and (CallsLike 'force end*') -eq 0 -and $res.Ok) 'Outlook open: asked, closed politely (classic and new Outlook), then fixed'
Assert ((@($script:Asked) -join ' ') -match 'close Outlook completely') 'asked in plain words before closing Outlook'
Reset-All; Seed-BrokenAcrobat; $script:Running = @('OUTLOOK'); $script:CloseWorks = $false; $script:ForceWorks = $false; $snap = RegSnapshot
$res = Invoke-AcrobatFix
Assert (-not $res.Ok -and (RegSnapshot) -eq $snap -and $res.Title -eq 'Outlook would not close' -and $res.Message -match 'call Trey') 'Outlook will not close even by force: stops with plain message, nothing changed'
Reset-All; Seed-BrokenAcrobat; $script:Running = @('OUTLOOK'); $script:CloseWorks = $false; $snap = RegSnapshot
$script:Answers.Enqueue($true); $script:Answers.Enqueue($false)
$res = Invoke-AcrobatFix
Assert ($res.Ok -and $res.Title -eq 'Nothing changed' -and (CallsLike 'force end*') -eq 0 -and (RegSnapshot) -eq $snap) 'will not close by itself and force is refused: Outlook is left alone'

Reset-All; Seed-BrokenAcrobat
AcroNo; $script:Answers.Enqueue($false); $script:Answers.Enqueue($true)
$res = Invoke-AcrobatFix
Assert ((CallsLike 'msi /fa {AC76BA86-1033-FFFF-BA7E-000000000001}') -eq 1) 'still broken -> offers and runs msiexec /fa repair'
Assert ($res.Ok -and $res.Title -eq 'Acrobat repaired') 'repair success message'
Reset-All; Seed-BrokenAcrobat
AcroNo; $script:Answers.Enqueue($false); $script:Answers.Enqueue($false)
$res = Invoke-AcrobatFix
Assert ((CallsLike 'msi*') -eq 0 -and -not $res.Ok) 'repair declined: not run'
Reset-All; Seed-BrokenAcrobat; $script:MsiCode = 1603; AcroNo; $script:Answers.Enqueue($false); $script:Answers.Enqueue($true)
$res = Invoke-AcrobatFix
Assert (-not $res.Ok -and $res.Message -match 'Repair Installation') 'repair fails: tells the person the manual step'
Reset-All; $script:Products = @($acro); Add-RegPretend 'HKCU:\Software\Microsoft\Office\16.0\Outlook' @{}; AcroNo
$res = Invoke-AcrobatFix
Assert ((@($script:Asked) -join ' ') -match 'not set up correctly') 'add-in missing entirely: goes straight to offering repair'
Reset-All; $script:Products = @([pscustomobject]@{ DisplayName = 'Adobe Acrobat Reader (64-bit)'; DisplayVersion = '1'; ProductCode = ''; WindowsInstaller = $false })
$res = Invoke-AcrobatFix
Assert (-not $res.Ok -and $res.Message -match 'Reader') 'Reader only: explained'
Reset-All
$res = Invoke-AcrobatFix
Assert (-not $res.Ok -and $res.Message -match 'not seem to be installed') 'no Acrobat: explained'

Section 'Report'
Reset-All; $d = New-Spool; Seed-BrokenAcrobat
$script:Printers = @((NetPrinter 'Office Printer' $false $true))
$out = Join-Path $tmp 'desktop'; New-Item -ItemType Directory $out | Out-Null
$OutputDir = $out
$res = Invoke-FixItReport
$files = @(Get-ChildItem $out -File)
Assert ($res.Ok -and $files.Count -eq 1) 'report file written'
$txt = [IO.File]::ReadAllText($files[0].FullName)
foreach ($h in @('=== Windows ===', '=== Printing ===', '=== Outlook ===', '=== Acrobat ===', '=== Acrobat add-in in Outlook ===', 'System log', 'Application log', 'Print Spooler service: Running', 'Windows 11 Pro', '16.0.17000.20000', 'Adobe Acrobat (64-bit)', 'LoadBehavior=2', 'sent to Trey')) {
    Assert ($txt.Contains($h)) ("report contains: $h")
}
Assert ($txt -notmatch 'second line x{350}') 'long event messages are trimmed'
Assert ($res.Message -match 'Report sent to Trey') 'tells the person it was sent'
Assert ((CallsLike 'web*') -eq 0) 'report makes no network calls'
$script:DryRun = $true; Remove-Item (Join-Path $out '*')
$res = Invoke-FixItReport
Assert (@(Get-ChildItem $out -File).Count -eq 0) 'dry-run: no report file written'
$script:DryRun = $false
function Get-SpoolerState { throw 'pretend failure' }
$res = Invoke-FixItReport
Assert ($res.Ok -and ([IO.File]::ReadAllText($res.ReportPath)) -match 'Print Spooler service: not available on this PC') 'one broken item does not stop the report (a short plain note instead)'
Assert (([IO.File]::ReadAllText($res.ReportPath)) -match 'Printers found: 1') 'the rest of the Printing section still shows when the spooler status fails'
function Get-SpoolerState { return [pscustomobject]@{ Status = $script:Spooler.Status; StartType = $script:Spooler.StartType } }

Section 'Report: a normal user (no administrator rights) - access denied everywhere'
$savedFns = @{}; foreach ($fn in @('Get-SpoolFiles', 'Get-FixItPrintJobs', 'Get-FixItDiskHealth', 'Get-FixItBackupSummary', 'Get-FixItCrashes', 'Get-FixItUnexpectedShutdowns', 'Get-FixItOsInfo', 'Get-FixItPcCodeLine', 'Get-FixItEvents')) { $savedFns[$fn] = (Get-Command $fn).ScriptBlock }
$adminLogFile = $script:LogFile; $script:LogFile = Join-Path $tmp 'report-denied.log'; Set-Content $script:LogFile @()
Reset-All; $script:Admin = $false
$script:Printers = @((NetPrinter 'Office Printer' $false $true), (NetPrinter 'Hall Printer' $false $false))
$denied = { throw (New-Object System.UnauthorizedAccessException("Access to the path 'C:\Windows\System32\spool\PRINTERS' is denied.")) }
function Get-SpoolFiles { throw (New-Object System.UnauthorizedAccessException("Access to the path 'C:\Windows\System32\spool\PRINTERS' is denied.")) }
$script:JobCalls = @()
function Get-FixItPrintJobs { param([string]$PrinterName) $script:JobCalls += $PrinterName; if ($PrinterName -eq 'Hall Printer') { throw (New-Object System.UnauthorizedAccessException('Access is denied')) }; return @([pscustomobject]@{ Id = 3; Status = 'Error'; Submitted = [datetime]'2026-10-26 09:15' }) }
function Get-FixItEvents { param([string]$LogName, [int]$Max = 25) if ($LogName -eq 'Application') { throw (New-Object System.UnauthorizedAccessException('Attempted to perform an unauthorized operation.')) }; return @([pscustomobject]@{ TimeCreated = (Get-Date); ProviderName = 'Spooler'; Id = 7031; Message = 'The Print Spooler service terminated unexpectedly' }) }
function Get-FixItDiskHealth { throw 'Access denied' }
function Get-FixItBackupSummary { throw (New-Object System.UnauthorizedAccessException('denied')) }
function Get-FixItCrashes { throw (New-Object System.UnauthorizedAccessException('denied')) }
function Get-FixItUnexpectedShutdowns { throw (New-Object System.UnauthorizedAccessException('denied')) }
function Get-FixItOsInfo { throw (New-Object System.UnauthorizedAccessException('Access denied')) }
function Get-FixItPcCodeLine { throw (New-Object System.UnauthorizedAccessException('Access denied')) }
$res = Invoke-FixItReport
$rt = ''; if ($res.ReportPath) { $rt = [IO.File]::ReadAllText($res.ReportPath) }
Assert ($res.Ok -and $res.Message -match 'Report sent to Trey') 'normal user: the report is still made and sent'
Assert ($rt -match '=== Printing ===' -and $rt -match 'Printers found: 2' -and $rt -match 'Office Printer') 'normal user: the Printing section is still in the report'
Assert ($rt -match 'Print Spooler service: Running') 'normal user: spooler status still shown'
Assert ($rt -match 'Print queue folder: not checked \(it needs administrator rights\)') 'normal user: the spool folder is skipped with a plain note'
Assert ($rt -match 'Waiting print jobs: 1, oldest submitted 2026-10-26 09:15 \(status: Error\)') 'normal user: stuck jobs come from the per-printer job list'
Assert ($rt -match 'Waiting print jobs: not shown \(needs administrator rights\)') 'a printer whose job list is denied gets a plain note; the other printer still shows its jobs'
Assert ($script:JobCalls -contains 'Office Printer' -and $script:JobCalls -contains 'Hall Printer') 'job lists are asked for each printer'
Assert ($rt -match 'Application log: not shown' -and $rt -match 'The Print Spooler service terminated unexpectedly') 'the System log still shows when the Application log is denied'
Assert ($rt -match 'Disk health: not shown' -and $rt -match 'Blue-screen crashes in the last 30 days: not shown' -and $rt -match 'OneDrive backup: not shown') 'each health item degrades on its own'
Assert ($rt -match 'Free space on C:' -and $rt -match 'Days since last restart' -and $rt -match 'Connection test:') 'other health items still show'
Assert ($rt -match '=== Outlook ===' -and $rt -match '=== Acrobat ===' -and $rt -match 'Computer name: ') 'Outlook, Acrobat and Windows sections are all still there'
$rtBody = ($rt -split '=== What this tool did recently')[0]   # the last part is a copy of the log's own lines (for Trey)
Assert ($rtBody -notmatch '(?i)denied|failed|unauthorized|exception|UnauthorizedAccess|Could not read') 'nothing scary in the report text: no "denied", "failed" or "exception"'
Assert ($res.Message -notmatch '(?i)denied|failed|unauthorized|exception|warn') 'nothing scary in the message the person sees'
$lg = Get-Content $script:LogFile -Raw
Assert ($lg -match 'needs administrator rights, so it was left out' -and $lg -match 'PRINTERS' -or $lg -match 'Access is denied') 'the technical reason is kept in the log'
Assert ($lg -notmatch '\[WARN\] Report (section|item)') 'access denied is not logged as a WARN (it is expected for a normal user)'
# a real (non-permission) failure is still logged as a WARN, but the section stays
function Get-FixItPrintJobs { param([string]$PrinterName) throw 'pretend: spooler RPC unavailable' }
$res = Invoke-FixItReport
$rt = [IO.File]::ReadAllText($res.ReportPath)
Assert ($rt -match 'Waiting print jobs: not available on this PC' -and $rt -match 'Printers found: 2') 'other failures also degrade one line only'
Assert ((Get-Content $script:LogFile -Raw) -match '\[WARN\] Report item "      Waiting print jobs" could not be read: pretend: spooler RPC unavailable') 'other failures are a WARN in the log'
# an administrator does read the spool folder
$script:Admin = $true
function Get-SpoolFiles { return @(1, 2, 3) }
function Get-FixItPrintJobs { param([string]$PrinterName) return @() }
$res = Invoke-FixItReport
$rt = [IO.File]::ReadAllText($res.ReportPath)
Assert ($rt -match 'Files waiting in the print queue folder: 3' -and $rt -notmatch 'not checked') 'administrator: the spool folder is read and counted'
$script:Admin = $false; $script:SpoolReads = 0
function Get-SpoolFiles { $script:SpoolReads++; return @() }
$null = Invoke-FixItReport
Assert ($script:SpoolReads -eq 0) 'normal user: the spool folder is never even touched'
$rtKeep = $rt
foreach ($fn in $savedFns.Keys) { Set-Item -Path "Function:\$fn" -Value $savedFns[$fn] }
$script:LogFile = $adminLogFile

Section 'Report: access-denied detection and the print job reader'
Assert (Test-FixItAccessDenied (New-Object System.UnauthorizedAccessException('x'))) 'UnauthorizedAccessException is access denied'
Assert (Test-FixItAccessDenied (New-Object System.Security.SecurityException('x'))) 'SecurityException is access denied'
Assert (Test-FixItAccessDenied ([Exception]'Access to the path ''C:\x'' is denied.')) 'the English "is denied" message counts'
Assert (Test-FixItAccessDenied (New-Object System.InvalidOperationException('outer', (New-Object System.UnauthorizedAccessException('inner'))))) 'an inner access-denied counts'
$er = $null; try { Get-Item -LiteralPath (Join-Path $tmp 'no-such-file.txt') -ErrorAction Stop } catch { $er = $_ }
Assert (-not (Test-FixItAccessDenied $er)) 'a plain not-found error is not access denied'
Assert (-not (Test-FixItAccessDenied $null) -and -not (Test-FixItAccessDenied (New-Object System.IO.IOException('disk busy')))) 'null and unrelated errors are not access denied'
# real Get-FixItPrintJobs: Get-PrintJob first, then Win32_PrintJob when it is not allowed
function Get-PrintJob { param([string]$PrinterName, $ErrorAction) throw (New-Object System.UnauthorizedAccessException('denied')) }
function Get-CimInstance { param([string]$ClassName, $ErrorAction) return @([pscustomobject]@{ Name = 'Office Printer, 12'; JobId = 12; JobStatus = 'Paused'; TimeSubmitted = [datetime]'2026-10-20' }, [pscustomobject]@{ Name = 'Other Printer, 4'; JobId = 4; JobStatus = ''; TimeSubmitted = [datetime]'2026-10-21' }) }
$jb = @(Get-FixItPrintJobs -PrinterName 'Office Printer')
Assert ($jb.Count -eq 1 -and $jb[0].Id -eq 12 -and $jb[0].Status -eq 'Paused') 'print jobs fall back to Win32_PrintJob and only list this printer'
function Get-CimInstance { param([string]$ClassName, $ErrorAction) throw (New-Object System.UnauthorizedAccessException('denied again')) }
$threw = $false; try { [void](Get-FixItPrintJobs -PrinterName 'Office Printer') } catch { $threw = $true }
Assert $threw 'if both ways fail the error is passed up (the report turns it into one plain line)'
function Get-PrintJob { param([string]$PrinterName, $ErrorAction) return @([pscustomobject]@{ ID = 9; JobStatus = 'Printing'; SubmittedTime = [datetime]'2026-10-27 08:00'; DocumentName = 'secret.docx' }) }
$jb = @(Get-FixItPrintJobs -PrinterName 'Office Printer')
Assert ($jb.Count -eq 1 -and $jb[0].Id -eq 9 -and ($jb[0].PSObject.Properties.Name -notcontains 'DocumentName')) 'Get-PrintJob is used first and document names are never kept'
foreach ($fn in @('Get-PrintJob', 'Get-CimInstance')) { Remove-Item "Function:\$fn" -ErrorAction SilentlyContinue }
$srcAll = [IO.File]::ReadAllText((Join-Path $root 'FamilyFixIt.ps1'))
Assert ($srcAll -notmatch '(?m)^\s*\$[a-z]+\s*=\s*@\(Get-SpoolFiles\)' -or $srcAll -match 'if \(Test-FixItAdmin\) \{\s*\r?\n\s*Invoke-ReportItem ''Files waiting') 'the report reads the spool folder only behind an administrator check'

Section 'Empty results (a clean PC with nothing to show)'
Reset-All
function Get-FixItEvents { param([string]$LogName, [int]$Max = 25) return @() }
$res = Invoke-FixItReport
Assert ($res.Ok -and ([IO.File]::ReadAllText($res.ReportPath)) -match 'No errors in the last 7 days') 'report with no events and no products works'
Assert (-not ([IO.File]::ReadAllText($res.ReportPath) -match 'Could not read this')) 'no section failed on empty data'
$res = Invoke-AcrobatRepair
Assert (-not $res.Ok -and $res.Message -match 'does not seem to be installed') 'repair with no Acrobat: explained, no crash'
$script:Printers = @()
$u = Invoke-PrinterRefreshUser
Assert ($u.Count -eq 0 -and $u.Problems -eq 0) 'no printers at all: no crash'

# ================================================================ version 2 modules
function Start-FixItElevated {
    param([string]$Part, [string]$ResultPath, [switch]$Visible, [string]$InputPath)
    Rec "elevate $Part"
    if ($script:UacDeny) { throw 'The operation was canceled by the user' }
    Set-Variable -Name InputFile -Scope Script -Value $InputPath
    $saved = $script:UndoCur
    Start-FixItUndoRecord -Fix $Part -Title $Part
    $r = & ('Invoke-' + $Part)
    $r | Add-Member -NotePropertyName UndoSteps -NotePropertyValue @($script:UndoCur.Steps) -Force
    $r | Add-Member -NotePropertyName UndoCannot -NotePropertyValue @($script:UndoCur.Cannot) -Force
    $script:UndoCur = $saved
    [IO.File]::WriteAllText($ResultPath, ($r | ConvertTo-Json -Depth 5))
    return 0
}

Section 'Safe-to-clean folder guard'
foreach ($p in @('C:\Users\t\Documents', 'C:\Users\t\Desktop', 'C:\Users\t\Downloads', 'C:\Users\t\OneDrive\Desktop', 'C:\Users\t\Pictures', 'C:\Users\t\AppData\Local\Microsoft\Outlook', 'C:\Users\t\x\mail.pst', 'C:\Users\t\x\mail.ost', 'C:\Users\t\Documents\Outlook Files\a.pst', 'C:\Windows', 'C:\', 'C:\Users\t\AppData\Local\Temp\Documents')) {
    Assert (-not (Test-SafeCleanPath -Path $p)) ("refuses to clean: $p")
}
foreach ($p in @('C:\Users\t\AppData\Local\Temp', 'C:\Windows\Temp', 'C:\Windows\SoftwareDistribution\Download', 'C:\Users\t\AppData\Local\Microsoft\Edge\User Data\Default\Cache', 'C:\Users\t\AppData\Local\Google\Chrome\User Data\Profile 2\Code Cache')) {
    Assert (Test-SafeCleanPath -Path $p) ("allows cleaning: $p")
}
Assert (-not (Test-SafeCleanPath -Path '')) 'empty path refused'

Section 'Internet and Wi-Fi'
Reset-All
$r = Invoke-NetworkFix
Assert ($r.Ok -and $r.Title -eq 'Internet looks fine' -and (CallsLike 'tool*') -eq 0) 'internet already fine: reported, nothing changed'
Reset-All; $script:Conn.Router = $false; $script:Conn.Net = $false; $script:Conn.Dns = $false; $script:Conn.Web = $false
$r = Invoke-NetworkFix
Assert (-not $r.Ok -and $r.Title -eq 'Please call Trey' -and $r.Message -match 'call Trey') 'router down and still down after the router restart: tells them to call Trey'
Assert ((CallsLike 'tool ipconfig.exe /flushdns') -eq 1 -and (CallsLike 'tool ipconfig.exe /release') -eq 1 -and (CallsLike 'tool ipconfig.exe /renew') -ge 1) 'flush DNS and renew the address'
Assert ((CallsLike 'tool netsh.exe winsock reset') -eq 1 -and (CallsLike 'adapter restart Wi-Fi') -eq 1) 'deeper reset + adapter restart when still broken'
Assert ($r.Message -notmatch '(?i)winsock|dns|exception|ipconfig') 'router message is jargon free'
# --- router step: exact words, "Is that done?", countdown, retest, report
$routerWords = 'Unplug the router, wait 30 seconds, then plug it back in.'
Assert ($script:RouterRestartText -ceq $routerWords) 'the router instruction is exactly: Unplug the router, wait 30 seconds, then plug it back in.'
$q = @($script:Asked | Where-Object { $_ -like '*Is that done?*' })
Assert ($q.Count -eq 1 -and $q[0].Contains($routerWords)) 'asks "Is that done?" together with the exact router instruction'
Assert ((CallsLike 'countdown 120') -eq 1) 'answered Yes: waits about 2 minutes (120 s) with the countdown'
Assert ((CallsLike 'countdown 30') -eq 1) 'only one short extra wait when the router is still starting up'
Assert ($script:Posts.Count -eq 1 -and $r.ReportSent -and ($r.Message -match 'sent Trey a report')) 'still failing: the report is sent to Trey automatically, and the person is told'
Assert ($script:Posts.Count -eq 1 -and $script:Posts[0].Json -match 'did NOT work, even after the router was unplugged') 'the report explains the router was already restarted'
Reset-All; $script:Conn.Router = $false; $script:Conn.Net = $false; $script:Conn.Dns = $false; $script:Conn.Web = $false; $script:Heal = $true
$r = Invoke-NetworkFix
Assert ($r.Ok -and $r.Title -eq 'Internet fixed' -and $r.Message -match 'Restarting the router did it') 'router restart worked: clear "fixed" message'
Assert ((CallsLike 'countdown 120') -eq 1 -and (CallsLike 'countdown 30') -eq 0 -and $script:Posts.Count -eq 0) 'worked after 2 minutes: no extra wait, no report sent'
Assert ($r.SkipFollowUp) 'worked: no second "Did that fix it?" question'
Reset-All; $script:Conn.Router = $false; $script:Conn.Net = $false; $script:Conn.Dns = $false; $script:Conn.Web = $false; $script:Answers.Enqueue($false)
$r = Invoke-NetworkFix
Assert (-not $r.Ok -and $r.Title -eq 'Router not restarted' -and (CallsLike 'countdown*') -eq 0 -and $script:Posts.Count -eq 0) 'answered No to "Is that done?": no waiting, no report'
Assert ($r.Message.Contains($routerWords)) 'No: the instruction is repeated for when they are ready'
Reset-All; $script:Conn.Router = $false; $script:Conn.Net = $false; $script:Conn.Dns = $false; $script:Conn.Web = $false; $script:PostFail = $true
$r = Invoke-NetworkFix
Assert (-not $r.Ok -and -not $r.ReportSent -and $r.Message -match "saved in the 'Family Fix-It Reports' folder in your Documents" -and $r.Message -match 'call Trey') 'report cannot be sent (no internet): says so and points to the saved copy'
Reset-All; $script:Conn.Dns = $false; $script:Conn.Web = $false; $script:ConnHeal = 'ipconfig.exe /flushdns'
$r = Invoke-NetworkFix
Assert ($r.Ok -and $r.Title -eq 'Internet fixed' -and (CallsLike 'tool netsh*') -eq 0) 'fixed by the simple steps: the deeper (admin) reset is NOT run'
$proxyKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Reset-All; Add-RegPretend $proxyKey @{ ProxyEnable = 1; ProxyServer = 'bad.example:8080' }; $script:Conn.Web = $false; $script:ConnHeal = 'ipconfig.exe /renew'
$r = Invoke-NetworkFix
Assert ((Get-RegValue $proxyKey 'ProxyEnable') -eq 0 -and (Get-RegValue $proxyKey 'ProxyServer') -eq 'bad.example:8080') 'stuck proxy switched off (address kept so it can be undone)'
Assert (($r.Details -join ' ') -match 'proxy') 'proxy change explained'
Reset-All; $script:Admin = $false; $script:Conn.Net = $false; $script:Conn.Dns = $false; $script:Conn.Web = $false
$r = Invoke-NetworkFix
Assert ((CallsLike 'elevate NetworkAdmin') -eq 1 -and (CallsLike 'tool ipconfig*') -ge 3) 'non-admin: only the reset part is elevated'
Reset-All; $script:Admin = $false; $script:UacDeny = $true; $script:Conn.Net = $false; $script:Conn.Dns = $false; $script:Conn.Web = $false
$r = Invoke-NetworkFix
Assert (-not $r.Ok -and $r.Message -match 'permission') 'UAC declined: friendly message'
Reset-All; $script:DryRun = $true; $script:Conn.Net = $false; $script:Conn.Dns = $false
$r = Invoke-NetworkFix
Assert ($r.Title -eq 'Practice run' -and (CallsLike 'tool*') -eq 0 -and (CallsLike 'adapter*') -eq 0 -and (CallsLike 'reg*') -eq 0) 'dry-run: nothing run'
Reset-All; $script:Conn.Net = $false; $script:Conn.Dns = $false; $script:Conn.Web = $false
$a = Invoke-NetworkAdmin; $b = Invoke-NetworkAdmin
Assert ($a.Ok -and $b.Ok) 'network reset is repeatable (idempotent)'

Section 'Slow computer / full disk'
Reset-All; $script:Uptime = 12; $script:Top = @([pscustomobject]@{ Name = 'chrome'; MemMB = 900 })
$script:Calls.Clear()
$r = Invoke-SlowFix
Assert ($r.Ok -and $r.Title -eq 'Cleanup done') 'cleanup succeeds'
Assert ((CallsLike 'clear C:\Users\tester\AppData\Local\Temp') -eq 1 -and (CallsLike 'recyclebin') -eq 1 -and (CallsLike 'clear *Edge*Cache') -eq 1) 'user temp, Recycle Bin and browser cache emptied'
Assert ((CallsLike 'clear C:\Windows\Temp') -eq 1 -and (CallsLike 'clear C:\Windows\SoftwareDistribution\Download') -eq 1) 'system temp and Windows Update cache emptied (admin part)'
Assert (((CallsLike 'clear *Documents*') + (CallsLike 'clear *Desktop*') + (CallsLike 'clear *Downloads*')) -eq 0) 'never touches Documents, Desktop or Downloads'
Assert (($r.Details -join ' ') -match 'freed' -and ($r.Details -join ' ') -match 'chrome' -and ($r.Details -join ' ') -match '12 day') 'shows free space, uptime and top memory apps'
Assert ($r.Message -match 'restart') 'uptime over 7 days: suggests a restart'
Assert ((CallsLike 'svc stop wuauserv') -eq 1 -and (CallsLike 'svc start wuauserv') -eq 1) 'Windows Update service stopped for its cache and started again'
Reset-All; $script:Answers.Enqueue($true)
$r = Invoke-SlowFix
$cq = @($script:Asked | Where-Object { $_ -like '*cache*' })
Assert ($cq.Count -eq 1 -and $cq[0] -match 'sign back in to websites' -and $cq[0] -match 'Warning') 'browser cache: asks first, with a warning about signing back in to websites'
Assert ((CallsLike 'clear *Edge*Cache') -eq 1 -and ($r.Details -join ' ') -match 'sign back in') 'cache answer Yes: browser cache cleared and the sign-in note is shown'
Reset-All; $script:Answers.Enqueue($false)
$r = Invoke-SlowFix
Assert ((CallsLike 'clear *Edge*Cache') -eq 0 -and $r.Ok) 'cache answer No: browser cache left alone'
Assert ((CallsLike 'clear C:\Users\tester\AppData\Local\Temp') -eq 1 -and (CallsLike 'recyclebin') -eq 1 -and (CallsLike 'clear C:\Windows\Temp') -eq 1 -and (CallsLike 'clear C:\Windows\SoftwareDistribution\Download') -eq 1) 'cache answer No: ONLY the cache step is skipped, every other clean-up still runs'
Assert (($r.Details -join ' ') -match 'will not need to sign in') 'cache answer No: says nothing to sign in to'
Reset-All; $script:Hung = @([pscustomobject]@{ Name = 'WINWORD'; Id = 77; Title = 'Report.docx' })
$r = Invoke-SlowFix
Assert ((CallsLike 'killapp 77') -eq 1 -and ($script:Asked -join ' ') -match 'frozen') 'frozen app: asked first, then closed'
Reset-All; $script:Hung = @([pscustomobject]@{ Name = 'WINWORD'; Id = 77; Title = 'x' }); $script:Answers.Enqueue($false)
$r = Invoke-SlowFix
Assert ((CallsLike 'killapp*') -eq 0) 'frozen app: answer no -> left alone'
Reset-All; $script:Admin = $false; $script:UacDeny = $true
$r = Invoke-SlowFix
Assert ($r.Ok -and ($r.Details -join ' ') -match 'permission was not given' -and (CallsLike 'clear C:\Windows*') -eq 0) 'UAC declined: user-level cleanup still done, system part skipped and explained'
Reset-All; $script:DryRun = $true
$r = Invoke-SlowFix
Assert ($r.Title -eq 'Practice run' -and (CallsLike 'clear*') -eq 0 -and (CallsLike 'recyclebin') -eq 0 -and (CallsLike 'svc*') -eq 0) 'dry-run: nothing deleted'
Reset-All; $r = Invoke-SlowFix; $r2 = Invoke-SlowFix
Assert ($r2.Ok) 'second run is fine (idempotent)'

Section 'Sound, microphone and camera'
Reset-All; $script:Spk.Muted = $true; $script:Spk.Volume = 0; $script:Mic.Muted = $true
$r = Invoke-SoundFix
Assert ((CallsLike 'audio Speakers 25 muted=False') -eq 1 -and (CallsLike 'audio Microphone 70 muted=False') -eq 1) 'muted speakers switched on at 25% (not 40) and microphone at 70%'
Assert ($script:SpeakerRestoreVolume -eq 25 -and $script:MicRestoreVolume -eq 70) 'restore volumes: speakers 25, microphone 70'
Assert ((CallsLike 'audio Speakers 40*') -eq 0) 'speakers are never set to 40 any more'
Assert ((CallsLike 'settings ms-settings:sound') -eq 1 -and $r.Ok) 'opens the right Settings page'
Reset-All
$r = Invoke-SoundFix
Assert ((CallsLike 'audio*') -eq 0) 'sound already fine: volumes not touched'
$micKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
$micKeyM = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
Reset-All; Add-RegPretend $micKey @{ Value = 'Deny' }; Add-RegPretend $micKeyM @{ Value = 'Allow' }
$r = Invoke-SoundFix
Assert ((Get-RegValue $micKey 'Value') -eq 'Allow' -and ($script:Asked -join ' ') -match 'blocking apps') 'privacy toggle changed only after asking'
Reset-All; Add-RegPretend $micKey @{ Value = 'Deny' }; $script:Answers.Enqueue($false)
$r = Invoke-SoundFix
Assert ((Get-RegValue $micKey 'Value') -eq 'Deny' -and (CallsLike 'regset*') -eq 0 -and (CallsLike 'settings ms-settings:privacy-microphone') -eq 1) 'privacy: answer no -> unchanged, privacy page opened'
Reset-All; Add-RegPretend $micKey @{ Value = 'Deny' }; Add-RegPretend $micKeyM @{ Value = 'Deny' }
$r = Invoke-SoundFix
Assert (($r.Details -join ' ') -match 'everyone on this computer' -and (CallsLike 'regset*') -eq 0) 'machine-wide block: explained, not changed'
Reset-All; $script:Mic = $null; $script:Admin = $false
$r = Invoke-SoundFix
Assert ((CallsLike 'elevate SoundAdmin') -eq 1 -and (CallsLike 'svc stop Audiosrv') -eq 1 -and (CallsLike 'svc start Audiosrv') -eq 1) 'no microphone: sound service restarted through the admin step'
Reset-All; $script:Cams = @()
$r = Invoke-SoundFix
Assert (($r.Details -join ' ') -match 'No camera') 'no camera: said so'
Reset-All; $script:DryRun = $true; $script:Spk.Muted = $true
$r = Invoke-SoundFix
Assert ($r.Title -eq 'Practice run' -and (CallsLike 'audio*') -eq 0 -and (CallsLike 'svc*') -eq 0 -and (CallsLike 'settings*') -eq 0) 'dry-run: nothing changed'

Section 'Let Trey see my screen (Zoho Assist)'
Reset-All
$r = Invoke-ScreenShare
Assert ((CallsLike 'url https://join.zoho.com/') -eq 1 -and $r.Ok) 'opens the Zoho join page'
Assert ($r.Message -match [regex]::Escape('Trey will give you a code. Type it in and click Join.')) 'shows the plain instruction'
Assert ($r.Message -match 'Only do this if YOU called Trey') 'keeps the scam warning'
Assert ($r.Message -match 'Nothing is installed in advance') 'says nothing is preinstalled'
$ssFn = @([Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null).FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-ScreenShare' }, $true))[0]
Assert ($script:ScreenShareUrl -eq 'https://join.zoho.com/' -and ($ssFn.Extent.Text -replace '(?m)^.*Test-FixItHelperIsTrey.*$', '') -notmatch '(?i)quick ?assist|msra') 'Zoho, not Quick Assist (the one line that hands another helper to Quick Assist is left out)'
Reset-All; $script:DryRun = $true
$r = Invoke-ScreenShare
Assert ((CallsLike 'url*') -eq 0 -and $r.Title -eq 'Practice run') 'dry-run: page not opened'

Section 'Outlook'
$bad = [pscustomobject]@{ ProgId = 'Ask.Toolbar'; Description = 'Ask Toolbar'; LoadBehavior = 3; Path = 'HKCU:\Software\Microsoft\Office\Outlook\Addins\Ask.Toolbar'; IsMachineWide = $false }
$badM = [pscustomobject]@{ ProgId = 'Conduit.Addin'; Description = 'Conduit'; LoadBehavior = 3; Path = 'HKLM:\SOFTWARE\Microsoft\Office\Outlook\Addins\Conduit.Addin'; IsMachineWide = $true }
$pdf = [pscustomobject]@{ ProgId = 'PDFMaker.OfficeAddin'; Description = 'Acrobat PDFMaker'; LoadBehavior = 3; Path = 'HKCU:\x\PDFMaker'; IsMachineWide = $false }
$good = [pscustomobject]@{ ProgId = 'Zoom.Addin'; Description = 'Zoom'; LoadBehavior = 3; Path = 'HKCU:\x\Zoom'; IsMachineWide = $false }
function Seed-Outlook {
    $script:Addins = @($bad, $badM, $pdf, $good)
    Add-RegPretend $bad.Path @{ LoadBehavior = 3 }
    # Things that hold the person's accounts and sign-ins. The fix must never change any of them.
    Add-RegPretend 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity\Identities' @{ x = 1 }
    Add-RegPretend 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity' @{ Signed = 'in' }
    Add-RegPretend 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles\Outlook' @{ a = 1 }
    Add-RegPretend 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles\Outlook\9375CFF0413111d3B88A00104B2A6676' @{ 'Account Name' = 'trey@example.test' }
}
# OlNo = "Is Outlook working properly now?" -> No, "Continue with the next steps?" -> Yes
function OlNo { $script:Answers.Enqueue($false); $script:Answers.Enqueue($true) }
$protectedKeys = @('HKCU:\Software\Microsoft\Office\16.0\Common\Identity\Identities', 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity', 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles\Outlook', 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles\Outlook\9375CFF0413111d3B88A00104B2A6676')
function ProtectedSnapshot { return (($protectedKeys | ForEach-Object { $k = $_; if (Test-RegKey $k) { ($script:Reg[$k].Keys | Sort-Object | ForEach-Object { '{0}|{1}|{2}' -f $k, $_, $script:Reg[$k][$_] }) -join ';' } else { 'MISSING ' + $k } }) -join "`n") }

# --- Step 1: a full shutdown of every Outlook program, then open it again. Often that is all.
Reset-All; Seed-Outlook; $script:Running = @('OUTLOOK', 'olk'); $script:Answers.Enqueue($true); $script:Answers.Enqueue($true); $snap = RegSnapshot
$r = Invoke-OutlookFix
Assert ($r.Ok -and $r.Title -eq 'Outlook fixed' -and $r.SkipFollowUp) 'Outlook working after a close and reopen: done, "Outlook fixed"'
Assert ((CallsLike 'close OUTLOOK,olk') -eq 1 -and (CallsLike 'outlook open') -eq 1) 'closes the classic AND the new Outlook (OUTLOOK and olk), then opens Outlook once'
Assert ((RegSnapshot) -eq $snap -and (CallsLike 'reg*') -eq 0 -and (CallsLike 'svc*') -eq 0 -and (CallsLike 'outlook safe') -eq 0) 'stopped after step 1: no further fixes were applied'
Assert (($r.Message + ' ' + ($r.Details -join ' ')) -match 'passwords, sign-ins') 'tells them their accounts and sign-ins were not touched'
Reset-All; Seed-Outlook; $script:Running = @('OUTLOOK'); $script:Answers.Enqueue($false); $snap = RegSnapshot
$r = Invoke-OutlookFix
Assert ($r.Ok -and $r.Title -eq 'Nothing changed' -and (CallsLike 'close*') -eq 0 -and (CallsLike 'force end*') -eq 0 -and (RegSnapshot) -eq $snap) 'does not want Outlook closed: left alone, nothing changed'
Reset-All; Seed-Outlook; $script:Running = @('OUTLOOK'); $script:CloseWorks = $false; $script:Answers.Enqueue($true); $script:Answers.Enqueue($true)
$r = Invoke-OutlookFix
Assert ((CallsLike 'force end OUTLOOK,olk') -eq 1 -and $r.Title -eq 'Outlook fixed') 'will not close politely: asks again, then ends every Outlook program, reopens, and it works'
Assert (@($script:Asked | Where-Object { $_ -like '*close it by force*' -or $_ -like '*Close it by force*' }).Count -eq 1) 'a second, plain question comes before closing Outlook by force'
Reset-All; Seed-Outlook; $script:Running = @('OUTLOOK'); $script:CloseWorks = $false; $script:Answers.Enqueue($true); $script:Answers.Enqueue($false)
$r = Invoke-OutlookFix
Assert ($r.Title -eq 'Nothing changed' -and (CallsLike 'force end*') -eq 0 -and (CallsLike 'outlook open') -eq 0) 'force-close refused: Outlook is left running, nothing changed'
Reset-All; Seed-Outlook; $script:Running = @('OUTLOOK'); $script:CloseWorks = $false; $script:ForceWorks = $false
$r = Invoke-OutlookFix
Assert (-not $r.Ok -and $r.Title -eq 'Outlook would not close' -and $r.Message -match 'restart your computer' -and (CallsLike 'reg*') -eq 0) 'Outlook cannot be closed at all: plain message, no further fixes'
Reset-All; Seed-Outlook; $script:Answers.Enqueue($false); $script:Answers.Enqueue($false); $snap = RegSnapshot
$r = Invoke-OutlookFix
Assert (-not $r.Ok -and $r.Title -eq 'Outlook still needs help' -and $r.Message -match 'call Trey' -and (RegSnapshot) -eq $snap -and (CallsLike 'outlook open') -eq 1) 'not working but does not want the next steps: stops, says call Trey, nothing changed'

# --- Step 2: only because Outlook is still not working
Reset-All; Seed-Outlook; OlNo
$r = Invoke-OutlookFix
Assert ((Get-RegValue $bad.Path 'LoadBehavior') -eq 0) 'unwanted per-user add-in turned off (after asking)'
Assert ((CallsLike 'regset HKCU:\x*') -eq 0 -and (CallsLike 'regset HKLM:\SOFTWARE\Microsoft\Office*') -eq 0) 'PDFMaker, good add-ins and machine-wide add-ins left alone'
Assert (($r.Details -join ' ') -match 'Conduit.Addin' -and ($r.Details -join ' ') -match 'Trey needs to turn it off') 'machine-wide bad add-in explained'
Assert ((CallsLike 'regset HKLM:\SOFTWARE\Microsoft\Windows Search SetupCompletedSuccessfully=0') -eq 1 -and (CallsLike 'svc stop WSearch') -eq 1 -and (CallsLike 'svc start WSearch') -eq 1) 'search index rebuilt (admin part)'
Assert ((CallsLike 'outlook safe') -eq 1) 'safe mode start offered and done'
Assert ((CallsLike 'outlook open') -eq 1) 'step 1 reopened Outlook; safe mode replaced the second reopen'
Assert ($r.Title -eq 'Outlook check done') 'ends with a plain message'
Assert ((CallsLike '*.pst*') + (CallsLike '*.ost*') + (CallsLike '*Profiles*') -eq 0) 'never touches PST/OST files or Outlook profiles'
Reset-All; Seed-Outlook; OlNo; foreach ($i in 1..3) { $script:Answers.Enqueue($false) }
$r = Invoke-OutlookFix
Assert ((Get-RegValue $bad.Path 'LoadBehavior') -eq 3 -and (CallsLike 'regset*') -eq 0 -and (CallsLike 'outlook safe') -eq 0 -and (CallsLike 'svc*') -eq 0) 'every step-2 question answered no: nothing changed'
Assert ((CallsLike 'outlook open') -eq 2) 'Outlook is opened normally again at the end'
Reset-All; Seed-Outlook; $script:Running = @('OUTLOOK', 'olk'); $script:Answers.Enqueue($true); $script:Answers.Enqueue($false); $script:Answers.Enqueue($true)
$r = Invoke-OutlookFix
Assert ((CallsLike 'close OUTLOOK,olk') -eq 1 -or (CallsLike 'close OUTLOOK,olk') -eq 2) 'Outlook is closed again before the extra steps (and nothing is running to be closed twice)'
Reset-All; Seed-Outlook; $script:DryRun = $true
$r = Invoke-OutlookFix
Assert ($r.Title -eq 'Practice run' -and (CallsLike 'reg*') -eq 0 -and (CallsLike 'outlook*') -eq 0 -and (CallsLike 'close*') -eq 0 -and (Get-RegValue $bad.Path 'LoadBehavior') -eq 3) 'dry-run: nothing changed'
Reset-All; Seed-Outlook; $script:Admin = $false; $script:UacDeny = $true; OlNo
$r = Invoke-OutlookFix
Assert (($r.Details -join ' ') -match 'permission was not given') 'UAC declined for the index rebuild: explained'
Reset-All; OlNo
$r = Invoke-OutlookFix
Assert (($r.Details -join ' ') -match 'No troublesome add-ins') 'no add-ins: no crash'

# ---------------------------------------------------------------- accounts and sign-ins are never touched
Section 'Outlook and Acrobat: never touch accounts, sign-ins or profiles'
$astAll = [Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
$fnAsts = @{}
foreach ($fa in $astAll.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $fnAsts[$fa.Name] = $fa }
$entry = @('Invoke-OutlookFix', 'Invoke-AcrobatFix', 'Invoke-AcrobatRepair', 'Invoke-OutlookAdmin', 'Invoke-AcrobatAdmin', 'Invoke-AcrobatUser')
$seen = @{}; $queue = New-Object System.Collections.Queue
foreach ($e in $entry) { $queue.Enqueue($e) }
while ($queue.Count -gt 0) {
    $fnName = [string]$queue.Dequeue()
    if ($seen.ContainsKey($fnName) -or -not $fnAsts.ContainsKey($fnName)) { continue }
    # Test mode only reads (it checks that a step could work); the Test-mode tests below prove it changes nothing
    if ($fnName -in @('Get-FixItPreflight', 'Invoke-FixItProbe', 'Invoke-FixItTestStep')) { continue }
    $seen[$fnName] = $true
    foreach ($ca in $fnAsts[$fnName].FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) { $cn = $ca.GetCommandName(); if ($cn) { $queue.Enqueue($cn) } }
    # a script block that is run later (Invoke-AdminPart -Part 'OutlookAdmin') names its function by text
    foreach ($sa in $fnAsts[$fnName].FindAll({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] }, $true)) { if ($sa.Value -match '^(\w+)Admin$') { $queue.Enqueue('Invoke-' + $Matches[1] + 'Admin') } }
}
Assert ($seen.Count -ge 12 -and $seen.ContainsKey('Close-FixItOutlookFully') -and $seen.ContainsKey('Invoke-OutlookAdmin') -and $seen.ContainsKey('Find-FixItBadAddins')) 'the Outlook/Acrobat call graph was found (so the checks below really cover the code)'
$bannedCmd = '(?i)^(cmdkey(\.exe)?|Remove-FixItCredential|Remove-RegKeyTree|Get-FixItOffice\w+|Get-StoredCredential|Clear-FixItFolder|Remove-FixItPrinter)$'
$bannedText = '(?i)\\Common\\Identity|OneAuth|IdentityCache|\\Profiles\b|\.pst\b|\.ost\b|\.nst\b|cmdkey|CredDelete|CredEnumerate|MicrosoftOffice\d+_Data|Credential|\\Office\\16\.0\\Common\\ServicesManagerCache|AAD\.Broker|TokenBroker|WebAccountManager'
$badHits = @()
foreach ($fnName in $seen.Keys) {
    foreach ($ca in $fnAsts[$fnName].FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
        $cn = $ca.GetCommandName()
        if ($cn -and $cn -match $bannedCmd) { $badHits += ('{0} calls {1}' -f $fnName, $cn) }
    }
    foreach ($sa in $fnAsts[$fnName].FindAll({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst] }, $true)) {
        $tv = if ($sa -is [Management.Automation.Language.StringConstantExpressionAst]) { $sa.Value } else { $sa.Value }
        if ($tv -match $bannedText) { $badHits += ('{0} mentions "{1}"' -f $fnName, $tv.Substring(0, [math]::Min(60, $tv.Length))) }
    }
}
if ($badHits.Count -gt 0) { $badHits | ForEach-Object { Write-Host ('    ' + $_) } }
Assert ($badHits.Count -eq 0) 'no Outlook or Acrobat action (nor anything it calls) can clear credentials, accounts, sign-in caches, profiles or mail files'
Assert ($src -notmatch '(?i)Remove-FixItCredential|Remove-RegKeyTree|Get-FixItOfficeCredentialTargets|Get-FixItOfficeIdentityKeys|Get-FixItOfficeCacheFolders|CredDelete|CredEnumerate|cmdkey') 'the old credential-clearing code is gone from the whole program'
# the allow-list: the only registry places those actions are ever allowed to change
$allowReg = '(?i)\\Outlook\\Addins\\|\\Outlook\\Resiliency\\|\\Windows Search'
function Test-OnlyAllowedChanges {
    $changes = @($script:Calls | Where-Object { $_ -match '^(regset|regsets|regdel|regrestore|regtree-remove|cred )' })
    $outside = @($changes | Where-Object { $_ -notmatch $allowReg })
    return @{ Changes = $changes.Count; Outside = $outside }
}
foreach ($mode in @('Outlook step 2 with every yes', 'Acrobat step 2 with every yes')) {
    Reset-All; Seed-Outlook; Seed-BrokenAcrobat; $script:Running = @('OUTLOOK', 'olk'); $before = ProtectedSnapshot
    if ($mode -like 'Outlook*') { $script:Answers.Enqueue($true); OlNo; $r = Invoke-OutlookFix } else { $script:Answers.Enqueue($true); AcroNo; $r = Invoke-AcrobatFix }
    $chk = Test-OnlyAllowedChanges
    Assert ($chk.Changes -ge 1) ('{0}: some real changes were made, so the check below is meaningful' -f $mode)
    Assert ($chk.Outside.Count -eq 0) ('{0}: every registry change is in an add-in / resiliency / search setting' -f $mode)
    Assert ((ProtectedSnapshot) -eq $before) ('{0}: account, sign-in and profile settings are exactly as they were' -f $mode)
    Assert ((CallsLike 'cred*') -eq 0 -and (CallsLike 'clear *Office*') -eq 0 -and (CallsLike 'clear *Outlook*') -eq 0 -and (CallsLike 'clear *OneAuth*') -eq 0 -and (CallsLike '*.pst*') -eq 0 -and (CallsLike '*.ost*') -eq 0) ('{0}: no sign-in cache or mail file was cleared' -f $mode)
}
Reset-All; Seed-Outlook; Seed-BrokenAcrobat; $before = ProtectedSnapshot; $script:Running = @('OUTLOOK'); $script:CloseWorks = $false; $script:Answers.Enqueue($true); $script:Answers.Enqueue($true)
$r = Invoke-AcrobatRepair
Assert ((ProtectedSnapshot) -eq $before -and (CallsLike 'cred*') -eq 0 -and (CallsLike 'msi /fa*') -eq 1) 'Acrobat repair (Outlook closed first, even by force): sign-ins untouched'
Assert ($script:Posts.Count -eq 0) 'nothing was sent anywhere by those fixes'

Section 'Browser clean-up'
$edgeDir = Join-Path $tmp 'Edge-User-Data-Default'
function Seed-Browser {
    $script:BProfiles = @([pscustomobject]@{ Browser = 'Edge'; Name = 'Default'; Dir = $edgeDir })
    $script:BSettings = [pscustomobject]@{ Homepage = 'http://search.evil.test'; StartupUrls = @(); SearchName = 'EvilSearch'; SearchUrl = 'http://evil.test/?q='; NotificationSites = @('https://spam.test') }
    $script:BExts = @([pscustomobject]@{ Id = 'abcdefabcdefabcdefabcdefabcdefab'; Name = 'Shopping Helper' }, [pscustomobject]@{ Id = 'efaidnbmnnnibpcajpcglclefindmkaj'; Name = 'Adobe Acrobat' })
}
Reset-All; Seed-Browser
$r = Invoke-BrowserFix
$dl = $r.Details -join ' '
Assert ((CallsLike 'backup *[/\]Preferences -> *') -eq 1 -and (CallsLike 'backup *[/\]Secure Preferences -> *') -eq 1 -and (CallsLike 'backup *[/\]Bookmarks -> *') -eq 1) 'settings, bookmarks backed up first'
Assert ($dl -match 'search.evil.test' -and $dl -match 'EvilSearch') 'changed homepage and search engine found'
Assert ((CallsLike 'start msedge.exe edge://settings/resetProfileSettings') -eq 1) 'opens the browser own reset page (does not edit settings itself)'
Assert ($dl -match 'Shopping Helper' -and $dl -notmatch 'Adobe Acrobat') 'unknown extension listed, known-good one not'
Assert ((CallsLike 'start msedge.exe edge://extensions') -eq 1 -and (CallsLike 'start msedge.exe edge://settings/content/notifications') -eq 1) 'extensions and notifications pages opened after asking'
Assert ($dl -match 'spam.test') 'notification permissions flagged'
Assert ((CallsLike 'defender scan') -eq 1) 'Defender quick scan run after asking'
Assert ((CallsLike 'reg*') -eq 0 -and $r.Message -match 'Passwords, bookmarks and history were not touched') 'no registry or password changes'
Reset-All; Seed-Browser; foreach ($i in 1..5) { $script:Answers.Enqueue($false) }
$r = Invoke-BrowserFix
Assert ((CallsLike 'start*') -eq 0 -and (CallsLike 'defender*') -eq 0) 'every question answered no: nothing opened or scanned'
Reset-All; Seed-Browser; $script:DryRun = $true
$r = Invoke-BrowserFix
Assert ((CallsLike 'backup*') -eq 0 -and (CallsLike 'start*') -eq 0 -and $r.Title -eq 'Practice run') 'dry-run: no backups, nothing opened'
Reset-All
$r = Invoke-BrowserFix
Assert (($r.Details -join ' ') -match 'was not found') 'no browser: explained'

Section 'Windows Update'
Reset-All
$r = Invoke-WinUpdateFix
Assert ($r.Ok -and $r.Title -eq 'Updates reset') 'quick reset works'
$order = ($script:Calls | Where-Object { $_ -like 'svc*' -or $_ -like 'aside*' }) -join '|'
Assert ($order -match '^svc stop wuauserv\|svc stop bits\|svc stop cryptsvc\|svc stop msiserver\|aside C:\\Windows\\SoftwareDistribution\|aside C:\\Windows\\System32\\catroot2\|svc start cryptsvc') 'services stopped, folders set aside (not deleted), services started'
Assert ((CallsLike 'tool dism*') -eq 0 -and (CallsLike 'settings ms-settings:windowsupdate') -eq 1) 'deep repair NOT offered when quick reset worked'
Assert ($script:State.ContainsKey('LastQuickReset')) 'quick reset remembered'
Reset-All; $script:SvcFail = @('bits')
$r = Invoke-WinUpdateFix
Assert (@($script:Calls | Where-Object { $_ -eq 'svc start wuauserv' }).Count -eq 1 -and (CallsLike 'aside*') -eq 0) 'a service that will not stop: nothing renamed, services still restarted'
Assert ((CallsLike 'tool dism*') -eq 1 -and (CallsLike 'tool sfc.exe /scannow') -eq 1) 'quick reset failed: deep repair offered and run'
Assert ((CallsLike 'restart in 30') -eq 1) 'after the deep repair: asks, then restarts'
Reset-All; $script:SvcFail = @('bits'); $script:Answers.Enqueue($false)
$r = Invoke-WinUpdateFix
Assert ((CallsLike 'tool*') -eq 0 -and -not $r.Ok) 'deep repair declined: not run'
Reset-All; $script:State['LastQuickReset'] = (Get-Date).ToString('s')
$r = Invoke-WinUpdateFix
Assert ((CallsLike 'svc stop*') -eq 0 -and (CallsLike 'tool dism*') -eq 1) 'quick reset done recently: goes straight to the deep repair offer'
Reset-All; $script:Admin = $false; $script:UacDeny = $true
$r = Invoke-WinUpdateFix
Assert (-not $r.Ok -and $r.Message -match 'permission' -and (CallsLike 'aside*') -eq 0) 'UAC declined: friendly message, nothing renamed'
Reset-All; $script:DryRun = $true
$r = Invoke-WinUpdateFix
Assert ($r.Title -eq 'Practice run' -and (CallsLike 'svc*') -eq 0 -and (CallsLike 'aside*') -eq 0 -and $script:State.Count -eq 0) 'dry-run: nothing changed'

Section 'OneDrive'
Reset-All; $script:Answers.Enqueue($false)
$r = Invoke-OneDriveFix
Assert ($r.Title -eq 'OneDrive checked' -and (CallsLike 'onedrive*') -eq 0) 'check only: reset declined, nothing changed'
Assert (($r.Details -join ' ') -match 'up to date' -and ($r.Details -join ' ') -match 'Your Documents folder is here' -and ($r.Details -join ' ') -match 'kept in OneDrive') 'status and folder locations shown'
Reset-All
$r = Invoke-OneDriveFix
Assert ((CallsLike 'onedrive reset') -eq 1 -and $r.Title -eq 'OneDrive reset' -and $r.Message -match 'not deleted') 'reset after asking; says files are not deleted'
Reset-All; $script:ODState = 'Paused'; $script:Answers.Enqueue($false)
$r = Invoke-OneDriveFix
Assert (($r.Details -join ' ') -match 'PAUSED') 'paused sync noticed'
Reset-All; $script:OD = [pscustomobject]@{ Exe = ''; Installed = $false; Running = $false; Accounts = @() }
$r = Invoke-OneDriveFix
Assert (-not $r.Ok -and $r.Title -eq 'OneDrive not found') 'no OneDrive: explained'
Reset-All; $script:Answers.Enqueue($false); $script:KF = [pscustomobject]@{ Desktop = 'C:\Users\tester\Desktop'; Documents = 'C:\Users\tester\Documents'; Pictures = 'C:\Users\tester\Pictures' }
$r = Invoke-OneDriveFix
Assert (($r.Details -join ' ') -match 'BACKUP WARNING' -and ($r.Details -join ' ') -match 'on this computer only') 'folders not in OneDrive: warned'
Reset-All; $script:DryRun = $true
$r = Invoke-OneDriveFix
Assert ($r.Title -eq 'Practice run' -and (CallsLike 'onedrive*') -eq 0) 'dry-run: not reset'

Section 'Backup check'
Reset-All
$b = Get-FixItBackupSummary
Assert ($b.Ok -and $b.Warnings.Count -eq 0) 'all three folders in OneDrive and synced: no warning'
Reset-All; $script:KF = [pscustomobject]@{ Desktop = 'C:\Users\tester\Desktop'; Documents = 'C:\Users\tester\OneDrive\Documents'; Pictures = 'C:\Users\tester\OneDrive\Pictures' }
$b = Get-FixItBackupSummary
Assert (-not $b.Ok -and ($b.Warnings -join ' ') -match 'Not backed up to OneDrive: Desktop') 'Desktop not backed up: warned'
Reset-All; $script:ODLast = (Get-Date).AddDays(-10)
$b = Get-FixItBackupSummary
Assert (($b.Warnings -join ' ') -match 'not synced for 10 days') 'stale sync (over 7 days): warned'
Reset-All; $script:OD = [pscustomobject]@{ Exe = ''; Installed = $false; Running = $false; Accounts = @() }
$b = Get-FixItBackupSummary
Assert (($b.Warnings -join ' ') -match 'not installed') 'OneDrive missing: warned'
Reset-All; $script:OD.Running = $false
$b = Get-FixItBackupSummary
Assert (($b.Warnings -join ' ') -match 'not running') 'OneDrive not running: warned'
Reset-All; $script:ODState = 'Paused'
$b = Get-FixItBackupSummary
Assert (($b.Warnings -join ' ') -match 'paused') 'paused: warned'
Reset-All; $script:OD.Accounts = @()
$b = Get-FixItBackupSummary
Assert (($b.Warnings -join ' ') -match 'not signed in') 'not signed in: warned'

Section 'Sending the report to Trey'
Reset-All; $o2 = Join-Path $tmp 'send1'; New-Item -ItemType Directory $o2 -Force | Out-Null; $OutputDir = $o2
$res = Invoke-FixItReport
Assert ($res.Ok -and $res.Title -eq 'Report sent' -and $res.Message -eq 'Report sent to Trey') 'success: "Report sent to Trey"'
Assert ($script:Posts.Count -eq 1 -and @(Get-ChildItem $o2 -File).Count -eq 1) 'saved to the reports folder AND sent once'
$p = $script:Posts[0]
Assert ($p.App -eq 'family-it-fixit' -and $p.Url -eq 'https://fixit-report.hg-fixit.workers.dev/report') 'app header and Worker URL from the setting'
$j = $p.Json | ConvertFrom-Json
Assert ($j.version -eq $script:FixItVersion -and $j.kind -eq 'report' -and $j.pcName -and $j.report -match '=== Windows ===') 'JSON has pcName, version, kind, report text'
Assert ([Text.Encoding]::UTF8.GetByteCount($p.Json) -lt 512KB) 'body well under 512KB'
Reset-All; $script:PostFail = $true; $OutputDir = $o2
$res = Invoke-FixItReport
$cant = "Couldn't send$([char]0x2014)please send the file in the 'Family Fix-It Reports' folder in your Documents to Trey"
Assert (-not $res.Ok -and $res.Message -match [regex]::Escape($cant) -and (Test-Path $res.ReportPath)) 'failure: exact fallback message, file kept'
Reset-All; $script:DryRun = $true; $OutputDir = $o2
$res = Invoke-FixItReport
Assert ($script:Posts.Count -eq 0) 'dry-run: nothing sent'
Reset-All; $OutputDir = $o2; $oldUrl = $script:ReportUrl; $script:ReportUrl = 'http://insecure.example/report'
$res = Invoke-FixItReport
Assert ($script:Posts.Count -eq 0 -and -not $res.Ok -and $res.Message -match 'Couldn') 'plain http report URL refused'
$script:ReportUrl = ''
$res = Invoke-FixItReport
Assert ($script:Posts.Count -eq 0 -and -not $res.Ok) 'no report URL: file saved, message to send it by hand'
$script:ReportUrl = $oldUrl
Reset-All; $OutputDir = $o2; $res = Invoke-FixItReport -Note 'I tried it and it still fails'
Assert (($script:Posts[0].Json | ConvertFrom-Json).report -match 'NOTE: I tried it and it still fails') 'a note travels with the report'
$sw = [Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
$fns = $sw.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)
$sendFn = @($fns | Where-Object { $_.Name -eq 'Send-WebReport' })[0]
Assert (([regex]::Matches($src, '-Method\s+Post')).Count -eq 1 -and $sendFn.Extent.Text -match '-Method\s+Post') 'the only network POST in the whole script is inside Send-WebReport'
Assert ($src -notmatch '(?i)Send-MailMessage|SmtpClient|MailMessage|Outlook\.Application|mailto:|Invoke-RestMethod|\.Post\(') 'script has no email code'
Assert ($src -notmatch '(?i)api[_-]?key\s*[=:]|secret\s*[=:]|bearer\s+[A-Za-z0-9]|password\s*=\s*[''"]') 'no secrets in the script'
Assert ($sendFn.Extent.Text -match 'TLS|Tls12') 'TLS 1.2 forced for old Windows'

Section 'Red scam button'
Reset-All; $o3 = Join-Path $tmp 'scam'; New-Item -ItemType Directory $o3 -Force | Out-Null; $OutputDir = $o3
$script:Remote = @([pscustomobject]@{ Name = 'AnyDesk'; Id = 12 }); $script:Installs = @([pscustomobject]@{ Name = 'SupportTool 1.0'; Date = (Get-Date).AddDays(-1) }); $script:Downloads = @([pscustomobject]@{ Name = 'invoice.exe'; Date = (Get-Date); KB = 900 })
$script:Calls.Clear()
$r = Invoke-ScamAlert
Assert ($r.Scam -and -not $r.Ok -or $r.Scam) 'scam result flagged'
Assert ($r.Message -match 'Do NOT call any phone number' -and $r.Message -match 'Turn off your Wi-Fi' -and $r.Message -match 'Do not click anything' -and $r.Message -match 'Call Trey') 'big plain message: dont call, Wi-Fi off, dont click, call Trey'
Assert ($r.Message -match 'never asks') 'states Trey never asks for codes or remote tools unless they called him'
Assert ($script:Posts.Count -eq 1 -and ($script:Posts[0].Json | ConvertFrom-Json).kind -eq 'scam') 'report auto-sent, tagged scam'
$sj = ($script:Posts[0].Json | ConvertFrom-Json).report
Assert ($sj -match 'AnyDesk' -and $sj -match 'SupportTool' -and $sj -match 'invoice.exe') 'includes remote tools, recent installs, recent downloads'
Assert ($script:Calls.Count -eq 0) 'no fixing: no registry, service or tool calls'
Reset-All; $script:PostFail = $true; $OutputDir = $o3
$r = Invoke-ScamAlert
Assert ($r.Message -match 'Call Trey' -and $r.Message -match 'could not be sent') 'offline: still tells them to call Trey; report kept'
Reset-All; $script:DryRun = $true; $OutputDir = $o3
$r = Invoke-ScamAlert
Assert ($script:Posts.Count -eq 0) 'dry-run: not sent'

Section 'Undo last fix'
function Journal { $f = Get-FixItUndoFile; if (Test-Path $f) { return @(Get-Content $f -Raw | ConvertFrom-Json) } return @() }
$ad = 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Addins\PDFMaker.OfficeAddin'
Reset-All; Seed-BrokenAcrobat
$before = RegSnapshot; AcroNo
$r = Invoke-FixItAction -Which 'Acrobat'
$j = @(Journal)
Assert ($j.Count -ge 1 -and @($j[-1].Steps).Count -ge 1 -and -not $j[-1].Undone) 'a fix leaves an undo record with steps'
Assert ((RegSnapshot) -ne $before) 'the fix changed the registry'
$u = Invoke-UndoLast
Assert ($u.Ok -and (RegSnapshot) -eq $before) 'undo puts every registry value back exactly as it was'
Assert (@(Journal)[-1].Undone) 'record marked undone'
$u2 = Invoke-UndoLast
Assert ($u2.Ok -and $u2.Title -match 'Nothing to undo') 'second undo: nothing left to undo'
Reset-All; $script:Spk.Muted = $true; $script:Spk.Volume = 0
[void](Invoke-FixItAction -Which 'Sound'); $script:Calls.Clear()
$u = Invoke-UndoLast
Assert ((CallsLike 'audio Speakers 0 muted=True') -eq 1 -and $u.Ok) 'sound fix undone: old volume and mute restored'
Reset-All
[void](Invoke-FixItAction -Which 'Slow'); $script:Calls.Clear()
$u = Invoke-UndoLast
Assert (-not $u.Ok -and $u.Message -match 'cannot be undone' -and ($u.Details -join ' ') -match 'temporary files') 'temp-file clean-up: clearly says it cannot be undone'
Assert (@(Journal)[-1].Undone) 'such a record is then closed so older fixes can be undone'
Reset-All; $script:Admin = $false
[void](Invoke-FixItAction -Which 'WinUpdate'); $script:Calls.Clear()
$jr = @(Journal)[-1]
Assert (@($jr.Steps | Where-Object { $_.Kind -eq 'rename' }).Count -eq 2) 'update reset run through the admin part: its rename steps reach the journal'
$u = Invoke-UndoLast
Assert ((CallsLike 'elevate UndoAdmin') -eq 1 -and (CallsLike 'folderrestore*SoftwareDistribution*') -eq 1 -and (CallsLike 'folderrestore*catroot2*') -eq 1) 'renamed update folders restored through the admin part'
Reset-All; Seed-Browser
[void](Invoke-FixItAction -Which 'Browser'); $script:Calls.Clear()
$u = Invoke-UndoLast
Assert ((CallsLike 'filerestore*') -eq 4 -and $u.Ok) 'browser backups copied back'
Reset-All; $script:Admin = $false; Seed-BrokenAcrobat; AcroNo
[void](Invoke-FixItAction -Which 'Acrobat'); $script:UacDeny = $true; $script:Calls.Clear()
$u = Invoke-UndoLast
Assert (-not $u.Ok -and $u.Message -match 'permission') 'undo needing admin, UAC declined: friendly message'
Reset-All; $script:Answers.Enqueue($false)
$script:Spk.Muted = $true; [void](Invoke-FixItAction -Which 'Sound'); $script:Answers.Clear(); $script:Answers.Enqueue($false); $script:Calls.Clear()
$u = Invoke-UndoLast
Assert ((CallsLike 'audio*') -eq 0 -and -not (@(Journal)[-1].Undone)) 'undo declined: nothing changed, record kept'
Reset-All; $script:DryRun = $true
[void](Invoke-FixItAction -Which 'Sound')
Assert (-not (Test-Path (Get-FixItUndoFile))) 'dry-run: no undo record written'
Reset-All
Set-Content (Get-FixItUndoFile) 'this is not json {{{'
$u = Invoke-UndoLast
Assert ($u.Ok -and $u.Title -match 'Nothing to undo') 'damaged journal: treated as empty, no crash'
Reset-All
foreach ($i in 1..35) { [void](Invoke-FixItAction -Which 'Slow') }
Assert (@(Journal).Count -le 30) 'journal keeps only the last 30 records'

Section 'Did that fix it?'
Reset-All; $script:Answers.Enqueue($true)
$null = Invoke-FixItAndShow -Which 'Slow'
Assert ($script:Posts.Count -eq 0 -and ($script:Asked -join '|') -match 'Did that fix it') 'Yes: nothing sent'
Reset-All; $script:Answers.Enqueue($true); $script:Answers.Enqueue($false); $OutputDir = Join-Path $tmp 'fu1'; New-Item -ItemType Directory $OutputDir -Force | Out-Null
$script:Answers.Clear()
$script:Answers.Enqueue($false)
$sr = Invoke-FixItFollowUp -Which 'Slow' -Result (New-FixItResult $true 'Cleanup done' 'x' @() @{})
Assert ($script:Posts.Count -eq 1 -and ($script:Posts[0].Json | ConvertFrom-Json).report -match 'did NOT fix') 'No: report sent automatically with a note'
Assert ($sr -and $sr.Title -eq 'Report sent') 'No: user told the report went to Trey'
Reset-All
$sr = Invoke-FixItFollowUp -Which 'Report' -Result (New-FixItResult $true 'x' 'x' @() @{})
Assert ($null -eq $sr -and $script:Asked.Count -eq 0) 'not asked after non-fix buttons'
Reset-All; $script:DryRun = $true
$sr = Invoke-FixItFollowUp -Which 'Slow' -Result (New-FixItResult $true 'x' 'x' @() @{})
Assert ($null -eq $sr -and $script:Asked.Count -eq 0) 'not asked in dry-run'
Reset-All
$sr = Invoke-FixItFollowUp -Which 'Slow' -Result (New-FixItResult $false 'x' 'x' @() @{ Declined = $true })
Assert ($null -eq $sr -and $script:Asked.Count -eq 0) 'not asked when the user declined admin permission'
Assert (@((Get-FixItActionTable).GetEnumerator() | Where-Object { $_.Value.Fix }).Count -eq 11) 'eleven fix actions ask the follow-up (2.3.13 added Fix my display)'

Section 'Restart the right way'
Reset-All
$r = Invoke-RestartRight
Assert ((CallsLike 'restart now') -eq 1 -and ($script:Asked -join ' ') -match 'Save your work') 'asks first, then full restart'
Reset-All; $script:Answers.Enqueue($false)
$r = Invoke-RestartRight
Assert ((CallsLike 'restart*') -eq 0) 'answer no: no restart'
Reset-All; $script:DryRun = $true
$r = Invoke-RestartRight
Assert ((CallsLike 'restart*') -eq 0) 'dry-run: no restart'
Assert ($src -match 'shutdown\.exe' -and $src -match "'/r', '/t', '0'" -and $src -notmatch '/hybrid') 'uses shutdown /r /t 0 (full restart, not Fast Startup)'

Section 'Is it just me?'
$feedDir = Join-Path $tmp 'feed'; New-Item -ItemType Directory $feedDir -Force | Out-Null
function Set-Feed { param([string]$Xml) $f = Join-Path $feedDir 'f.xml'; [IO.File]::WriteAllText($f, $Xml); $script:WebMap = @{ $script:StatusFeedUrl = $f } }
$okFeed = '<?xml version="1.0"?><rss><channel><item><title>Exchange Online</title><status>Available</status></item><item><title>Microsoft Teams</title><status>Available</status></item></channel></rss>'
Reset-All; Set-Feed $okFeed
$r = Invoke-StatusCheck
Assert ($r.Ok -and $r.Title -match 'just you') 'all fine: "It is just you" with next steps'
Reset-All; Set-Feed ($okFeed -replace '<status>Available</status></item><item><title>Microsoft Teams', '<status>Investigating</status></item><item><title>Microsoft Teams')
$r = Invoke-StatusCheck
Assert ($r.Title -match 'Microsoft has a problem' -and ($r.Details -join ' ') -match 'Exchange Online') 'Microsoft problem: named, tells them to wait'
Reset-All; Set-Feed $okFeed; $script:Conn.Net = $false; $script:Conn.Dns = $false
$r = Invoke-StatusCheck
Assert ($r.Title -match 'internet is not working') 'internet down: said first'
Reset-All; Set-Feed $okFeed; $script:Https['https://outlook.office365.com/'] = $false; $script:Https['https://login.microsoftonline.com/'] = $false; $script:Https['https://www.office.com/'] = $false
$r = Invoke-StatusCheck
Assert ($r.Title -match 'cannot reach Microsoft') 'Microsoft unreachable from here but internet ok: said so'
Reset-All; $script:WebFail = $true
$r = Invoke-StatusCheck
Assert ($r.Title -match 'No problem found' -and $r.Message -match 'could not read') 'status page unreadable: honest message'
Assert ((CallsLike 'reg*') -eq 0 -and $script:Posts.Count -eq 0 -and $script:StatusFeedUrl -match '^https://') 'no credentials, nothing changed or sent, https only'

Section 'Health badge: restart and backup signals'
$hbT = $null; $hbE = $null
$astHb = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'FamilyFixIt.ps1'), [ref]$hbT, [ref]$hbE)
$realPending = ($astHb.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-PendingReboot' }, $true)).Body.GetScriptBlock()
Reset-All
Add-RegPretend 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' @{ PendingFileRenameOperations = 'x' }
Assert (-not (& $realPending)) 'PendingFileRenameOperations alone is NOT a pending restart'
Reset-All; Add-RegPretend 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
Assert ((& $realPending)) 'Windows Update RebootRequired is a pending restart'
Reset-All; Add-RegPretend 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
Assert ((& $realPending)) 'CBS RebootPending is a pending restart'
Reset-All; $script:Uptime = 3; $script:Pending = $false
Assert ((Get-FixItHealthPill).Ok) 'badge: 3 days up, nothing pending: healthy'
$script:Uptime = 7.0
Assert ((Get-FixItHealthPill).Ok) 'badge: exactly 7 days is still fine'
$script:Uptime = 8
$pill = Get-FixItHealthPill
Assert (-not $pill.Ok -and $pill.Text -match 'restart waiting') 'badge: up more than 7 days: restart waiting'
$script:Uptime = 1; $script:Pending = $true
$pill = Get-FixItHealthPill
Assert (-not $pill.Ok -and $pill.Text -match 'restart waiting') 'badge: Windows says a restart is pending: restart waiting'
Reset-All
$pill = Get-FixItHealthPill
Assert ($pill.Ok) 'badge: a clean PC is healthy'
# no OneDrive at all, or a folder outside OneDrive: not a badge problem (still in Trey's report and the weekly lines)
$realBkFn = (Get-Command Get-FixItBackupSummary).ScriptBlock
$bk0 = [pscustomobject]@{ Ok = $false; Installed = $false; Warnings = @('OneDrive is not installed, so your Desktop, Documents and Pictures are not backed up online.'); Important = @() }
function Get-FixItBackupSummary { return $bk0 }
$pill = Get-FixItHealthPill
Assert ($pill.Ok -and $pill.Text -match 'no backup') 'badge: no OneDrive installed is quiet (not "Needs a look")'
$bk0 = [pscustomobject]@{ Ok = $false; Installed = $true; Warnings = @('Not backed up to OneDrive: Pictures.'); Important = @() }
$pill = Get-FixItHealthPill
Assert ($pill.Ok) 'badge: one folder outside OneDrive is quiet'
$bk0 = [pscustomobject]@{ Ok = $false; Installed = $true; Warnings = @('OneDrive syncing is paused for a@b.c.'); Important = @('OneDrive syncing is paused for a@b.c.') }
$pill = Get-FixItHealthPill
Assert (-not $pill.Ok -and $pill.Text -match 'backup needs a look') 'badge: paused OneDrive sync does need a look'
Set-Item -Path Function:\Get-FixItBackupSummary -Value $realBkFn
$astHb = $null

Section 'Health check and weekly check-in'
Reset-All
$r = Invoke-HealthCheck
Assert ($r.Ok -and $script:Posts.Count -eq 1) 'health summary sent once'
$h = $script:Posts[0].Json | ConvertFrom-Json
Assert ($h.kind -eq 'health' -and $h.version -eq $script:FixItVersion) 'tagged health, with tool version'
foreach ($want in @('Free disk', 'updates waiting to install', 'waiting for a restart', 'Defender', 'OneDrive', 'Days since last restart', 'Family Fix-It version', 'ATTENTION: nothing')) { Assert ($h.report -match $want) "health text has: $want" }
Assert ($h.report -notmatch '(?i)\.docx|Documents\\|password') 'health text has no file names or secrets'
Assert (@(Get-ChildItem $o3 -File | Where-Object { $_.Name -like 'Health*' }).Count -eq 0) 'health check saves no file on the Desktop'
Reset-All; $script:Free = [int64]5GB; $script:Uptime = 20; $script:Pending = $true; $script:PendUp = 25; $script:Def = [pscustomobject]@{ Enabled = $false; RealTime = $false; SignatureAgeDays = 20; LastQuickScan = (Get-Date).AddDays(-60) }; $script:ODLast = (Get-Date).AddDays(-20)
$null = Invoke-HealthCheck
$h = $script:Posts[0].Json | ConvertFrom-Json
foreach ($want in @('ATTENTION:', 'Low disk', 'not been restarted', 'updates are waiting', 'protection is turned off', 'definitions are 20 days', 'OneDrive has not synced')) { Assert ($h.report -match $want) "attention list mentions: $want" }
Assert ($h.report -notmatch 'No virus scan in over') 'an old last-scan date alone is not raised (Defender scans on its own; the date stays in the lines)'
# moderate values are quiet in the "ATTENTION" list but still shown in the lines
Reset-All; $script:Free = [int64]50GB; $script:Uptime = 10; $script:Pending = $false; $script:PendUp = 15; $script:Def = [pscustomobject]@{ Enabled = $true; RealTime = $true; SignatureAgeDays = 10; LastQuickScan = (Get-Date).AddDays(-60) }; $script:ODLast = (Get-Date).AddDays(-9)
$null = Invoke-HealthCheck
$h = $script:Posts[0].Json | ConvertFrom-Json
Assert ($h.report -match 'ATTENTION: nothing' -and $h.report -match 'definitions 10 day' -and $h.report -match 'waiting to install: 15' -and $h.report -match 'Last Defender scan: ') 'moderate values (10-day-old definitions, 15 updates, 9 days since OneDrive sync, scan 60 days ago) are quiet in ATTENTION but still listed'
Reset-All; $script:PostFail = $true
$r = Invoke-HealthCheck
Assert (-not $r.Ok) 'offline: reported quietly as not sent'
Reset-All; $script:DryRun = $true
$null = Invoke-HealthCheck
Assert ($script:Posts.Count -eq 0) 'dry-run: not sent'
$tn = 'Family Fix-It Weekly Check'
Reset-All
$r = Invoke-CheckInToggle -Mode On
Assert ($r.Ok -and (CallsLike "task create $tn") -eq 1 -and $script:Tasks.ContainsKey($tn)) 'weekly check-in installed'
$xml = $script:Tasks[$tn]
$x = [xml]$xml
Assert ($xml -match 'LeastPrivilege' -and $xml -match 'InteractiveToken' -and $xml -notmatch 'HighestAvailable') 'task runs as the user, no admin'
Assert ($xml -match '-Action HealthCheck' -and $xml -match 'StartWhenAvailable' -and $xml -match 'WindowStyle Hidden') 'runs the health check, catches up when PC was off, hidden window'
$null = Invoke-CheckInToggle -Mode On
Assert ($script:Tasks.Count -eq 1) 'installing twice: still one task (idempotent)'
Assert ((Invoke-CheckInToggle -Mode Toggle).Message -match 'off' -and -not $script:Tasks.ContainsKey($tn)) 'toggle when installed turns it off'
$c0 = CallsLike 'task delete*'
$null = Invoke-CheckInToggle -Mode Off
Assert ((CallsLike 'task delete*') -eq $c0) 'removing when absent: nothing to do (idempotent)'
Reset-All; $script:Answers.Enqueue($false)
$null = Invoke-CheckInToggle -Mode Toggle
Assert ($script:Tasks.Count -eq 0 -and ($script:Asked -join ' ') -match 'quietly sends Trey') 'asks before turning on; no = not installed'
Reset-All; $script:DryRun = $true
$null = Invoke-CheckInToggle -Mode On
Assert ($script:Tasks.Count -eq 0) 'dry-run: no task created'
Reset-All; $oldSp = $script:SelfPath; $script:SelfPath = Join-Path $tmp 'nonexistent.ps1'
$r = Invoke-CheckInToggle -Mode On
Assert (-not $r.Ok -and $script:Tasks.Count -eq 0) 'script path unknown: fails cleanly'
$script:SelfPath = $oldSp

Section 'Big text / high contrast'
Reset-All
Assert ((Get-FixItSetting -Name 'BigText') -ne $true) 'default: normal text'
Set-FixItSetting -Name 'BigText' -Value $true
Assert ((Get-FixItSetting -Name 'BigText') -eq $true) 'big text remembered'
Set-FixItSetting -Name 'HighContrast' -Value $true
Assert ((Get-FixItSetting -Name 'HighContrast') -eq $true) 'high contrast remembered'
Set-FixItSetting -Name 'BigText' -Value $false
Assert ((Get-FixItSetting -Name 'BigText') -eq $false -and (Get-FixItSetting -Name 'HighContrast') -eq $true) 'settings independent'
Reset-All; $script:DryRun = $true
Set-FixItSetting -Name 'BigText' -Value $true
Assert ($script:State.Count -eq 0) 'dry-run: setting not written'
$styles = 'card', 'scam', 'primary', 'outline', 'yes', 'no', 'btn'
foreach ($s in $styles) {
    foreach ($hov in @($false, $true)) {
        $n = Get-FixItTileColors -Style $s -Hover:$hov
        $hc = Get-FixItTileColors -Style $s -Hover $hov -HighContrast $true
        Assert ((Get-FixItContrast $n.Title $n.Fill) -ge 4.5) "normal $s hover=$hov title contrast >= 4.5 ($([math]::Round((Get-FixItContrast $n.Title $n.Fill),1)))"
        Assert ((Get-FixItContrast $n.Sub $n.Fill) -ge 4.5) "normal $s hover=$hov subtitle contrast >= 4.5 ($([math]::Round((Get-FixItContrast $n.Sub $n.Fill),1)))"
        Assert ((Get-FixItContrast $hc.Title $hc.Fill) -ge 7) "high contrast $s hover=$hov title >= 7"
        Assert ((Get-FixItContrast $hc.Sub $hc.Fill) -ge 7) "high contrast $s hover=$hov subtitle >= 7"
    }
}
Assert ($src -match '1\.25' -and $src -match 'SetProcessDPIAware' -and $src -match 'AutoScroll') 'GUI: larger text scale, DPI awareness, scrolling present'

Section 'Action table'
$tbl = Get-FixItActionTable
foreach ($k in @($tbl.Keys)) { Assert ($null -ne (Get-Command $tbl[$k].Fn -ErrorAction SilentlyContinue)) "action $k -> function $($tbl[$k].Fn) exists" }
$vs = [regex]::Match($src, 'ValidateSet\(([^)]*)\)').Groups[1].Value
foreach ($k in @($tbl.Keys) + @('CheckIn', 'CheckInOn', 'CheckInOff', 'HealthCheck', 'UndoAdmin', 'NetworkAdmin', 'WinUpdateDeepAdmin')) { Assert ($vs -match "'$k'") "-Action accepts $k" }
$threw = $false; try { Invoke-FixItAction -Which 'Nope' | Out-Null } catch { $threw = $true }
Assert $threw 'unknown action name rejected'

Section 'What did I fix?'
$origLog = $script:LogFile
$hd = Join-Path $tmp 'hist'; New-Item -ItemType Directory $hd -Force | Out-Null
$script:LogFile = Join-Path $hd 'fixit-2026-10-27.log'
Set-Content $script:LogFile @(
    '2026-10-27 09:00:00 [INFO] Started: fix the printer',
    '2026-10-27 09:00:09 [INFO] Fix result: Printer|Fix my printer|ok',
    '2026-10-27 09:00:20 [INFO] Did that fix it? (Fix my printer) -> yes',
    '2026-10-27 09:30:00 [INFO] Fix result: Network|Fix my internet|problem') -Encoding UTF8
$script:LogFile = Join-Path $hd 'fixit-2026-10-28.log'
Set-Content $script:LogFile @(
    '2026-10-28 08:15:00 [INFO] Fix result: Slow|My computer is slow|ok',
    '2026-10-28 08:15:30 [INFO] Did that fix it? (My computer is slow) -> NO',
    '2026-10-28 08:20:00 [INFO] Fix result: Sound|Fix sound, mic and camera|ok',
    '2026-10-28 08:21:00 [WARN] something unrelated') -Encoding UTF8
$h = @(Get-FixItHistory)
Assert ($h.Count -eq 4 -and $h[0].Fix -eq 'Sound' -and $h[3].Fix -eq 'Printer') 'history reads all days, newest first'
Assert ($h[3].Answer -eq 'yes' -and $h[1].Answer -eq 'no' -and $h[0].Answer -eq '' -and -not $h[2].Ok) 'each fix is paired with its yes / no answer'
Assert ((Format-FixItHistoryLine $h[3]) -match 'Tue Oct 27, 9:00 AM  -  Fix my printer  -  WORKED') 'friendly line: date, fix, worked'
Assert ((Format-FixItHistoryLine $h[1]) -match 'did NOT work.*report went to Trey') 'friendly line: did not work'
Assert ((Format-FixItHistoryLine $h[2]) -match 'could not be finished' -and (Format-FixItHistoryLine $h[0]) -match 'did not say') 'friendly line: problem / no answer'
Assert (@(Get-FixItHistory -Max 2).Count -eq 2) 'history respects the maximum'
$r = Invoke-HistoryShow
Assert ($r.Ok -and $r.Details.Count -eq 4 -and $r.Title -eq 'What I fixed') 'result lists every fix'
# pairs with Undo
Reset-All; Seed-BrokenAcrobat; $script:LogFile = Join-Path $hd 'fixit-2026-10-29.log'; AcroNo
[void](Invoke-FixItAction -Which 'Acrobat')
$r = Invoke-HistoryShow
Assert ($r.Message -match "Undo last fix.*Fix Acrobat in Outlook") 'history points at Undo for the newest fix'
Assert ((Get-Content $script:LogFile -Raw) -match 'Fix result: Acrobat\|Fix Acrobat in Outlook\|ok') 'a real fix writes its result line to the log'
Reset-All; $script:DryRun = $true; $n0 = (Get-Content $script:LogFile).Count
[void](Invoke-FixItAction -Which 'Slow')
Assert (-not ((Get-Content $script:LogFile -Raw) -match 'Fix result: Slow')) 'dry-run does not write a fix result'
Remove-Item (Join-Path $hd '*') -Force; $script:LogFile = Join-Path $hd 'fixit-2026-10-30.log'
Reset-All
Assert ((Invoke-HistoryShow).Title -eq 'Nothing yet') 'empty history: friendly message'
$script:LogFile = $origLog
Assert ((Get-FixItActionTable).History.Fix -eq $false) 'history is not a fix (no follow-up question)'

Section 'My files'
$fr = Join-Path $tmp 'files'; New-Item -ItemType Directory $fr -Force | Out-Null
foreach ($d in 'Desktop', 'Documents', 'Documents/sub', 'Downloads', 'Pictures', 'OneDrive/Work', 'Elsewhere') { New-Item -ItemType Directory (Join-Path $fr $d) -Force | Out-Null }
function Mk { param($Rel, $DaysAgo) $p = Join-Path $fr $Rel; Set-Content $p 'x'; (Get-Item $p).LastWriteTime = (Get-Date).AddDays(-$DaysAgo); return $p }
$fTax = Mk 'Desktop/Taxes 2025.pdf' 3
$fNote = Mk 'Documents/sub/tax notes.docx' 1
$fBud = Mk 'Documents/Budget.xlsx' 10
$fExe = Mk 'Downloads/setup.exe' 2
$null = Mk 'Downloads/~$lock.docx' 0; $null = Mk 'Desktop/desktop.ini' 0; $null = Mk 'Documents/x.tmp' 0
$fOD = Mk 'OneDrive/Work/Plan.txt' 5
$fOut = Mk 'Elsewhere/secret.txt' 1
function Get-FixItUserFolders { return @(foreach ($n in 'Desktop', 'Documents', 'Downloads', 'Pictures', 'OneDrive') { [pscustomobject]@{ Name = $n; Path = (Join-Path $fr $n) } }) }
function Open-FixItUserFile { param([string]$Path) Rec "ouf $Path" }
function Show-FixItFileInFolder { param([string]$Path) Rec "sif $Path" }
function SnapFiles { (Get-ChildItem $fr -Recurse -File | Sort-Object FullName | ForEach-Object { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTime.Ticks }) -join ';' }
$snap = SnapFiles
Reset-All
$f = @(Find-FixItFiles -Query 'tax')
Assert ($f.Count -eq 2 -and $f[0].Name -eq 'tax notes.docx' -and $f[1].Name -eq 'Taxes 2025.pdf') 'search by part of the name, subfolders too, newest first'
Assert (@(Find-FixItFiles -Query 'TAX 2025').Count -eq 1) 'every typed word must match; case does not matter'
Assert (@(Find-FixItFiles -Query 'secret').Count -eq 0) 'files outside the user folders are not searched'
$rec = @(Find-FixItFiles)
Assert ($rec.Count -eq 5 -and $rec[0].Name -eq 'tax notes.docx' -and -not ($rec.Name -match '^~|desktop.ini|\.tmp$')) 'no search = recently saved files, junk hidden'
foreach ($i in 1..12) { $null = Mk "Pictures/pic$i.jpg" 0 }
Assert (@(Find-FixItFiles -Query 'pic').Count -eq 8) 'at most 8 results'
$snap = SnapFiles
$r = Invoke-FilesHelper -Search 'budget'
Assert ($r.Ok -and $r.Details.Count -eq 1 -and $r.Details[0] -match 'Budget.xlsx' -and $r.Files[0] -eq $fBud) 'command-line listing shows name, date, folder'
Assert ((Invoke-FilesHelper -Search 'zzzz').Message -match 'did not find') 'nothing found: plain message'
$r = Open-FixItFoundFile -Path $fTax
Assert ($r.Ok -and (CallsLike "ouf $fTax") -eq 1) 'Open the file: opens it with the default app'
$r = Show-FixItFoundFile -Path $fTax
Assert ($r.Ok -and (CallsLike "sif $fTax") -eq 1) 'Show me where it is: Explorer with the file selected'
$script:Calls.Clear()
$r1 = Open-FixItFoundFile -Path $fOut; $r2 = Show-FixItFoundFile -Path $fOut
Assert (-not $r1.Ok -and -not $r2.Ok -and $script:Calls.Count -eq 0) 'a file outside the user folders is refused'
$r1 = Open-FixItFoundFile -Path ($fr + '/Documents/../Elsewhere/secret.txt')
Assert (-not $r1.Ok -and $script:Calls.Count -eq 0) 'a path with .. is refused'
$r1 = Open-FixItFoundFile -Path $fExe
Assert (-not $r1.Ok -and $r1.Message -match 'program, not a document' -and $script:Calls.Count -eq 0) 'programs are never run from here'
$r2 = Show-FixItFoundFile -Path $fExe
Assert ($r2.Ok -and (CallsLike "sif $fExe") -eq 1) '...but can be shown in the folder'
$r = Open-FixItFoundFile -Path (Join-Path $fr 'Desktop/gone.pdf')
Assert (-not $r.Ok -and $r.Title -eq 'File not found') 'deleted file: plain message'
$script:DryRun = $true; $script:Calls.Clear()
$r = Open-FixItFoundFile -Path $fTax; $r2 = Show-FixItFoundFile -Path $fTax
Assert ($r.Ok -and $r2.Ok -and (CallsLike 'ouf*') -eq 0 -and (CallsLike 'sif*') -eq 0) 'dry-run: nothing opened'
Assert ((SnapFiles) -eq $snap) 'read-only: no file was changed, created or deleted'
$gui = [IO.File]::ReadAllText((Join-Path $root 'FamilyFixIt.ps1'))
Assert ($gui -match [regex]::Escape("'/select,`"{0}`"'") -and $gui -match "FilePath 'explorer.exe'") 'the real adapter uses explorer.exe /select,'
Assert (([regex]::Matches($gui, "-Title 'Open the file'")).Count -eq 1 -and ([regex]::Matches($gui, "-Title 'Show me where it is'")).Count -eq 1) 'each result row has exactly two buttons: Open the file / Show me where it is'
Assert (([regex]::Matches($gui, "New-FixItTile -Run \('(OpenFile|ShowFile):'")).Count -eq 2) 'the result list creates no other buttons'
$real = [IO.Path]::Combine($fr, 'Documents')
Assert ($gui -notmatch 'Remove-Item[^\r\n]*FilesList|Set-Content[^\r\n]*FoundFile') 'no delete/write code in the files helper'

Section 'Install an app safely'
$origNative = ${function:Invoke-FixItNative}
$script:Wg = @{ Installed = @{}; InstallCode = 0; Present = $true }
function Test-FixItWinget { return $script:Wg.Present }
function Invoke-FixItNative {
    param([string]$File, [string[]]$Arguments = @(), [switch]$Live)
    $k = "$File $($Arguments -join ' ')"; Rec "native $k"
    if ($File -eq 'winget.exe' -and $Arguments[0] -eq 'list') { $id = $Arguments[2]; if ($script:Wg.Installed[$id]) { return [pscustomobject]@{ ExitCode = 0; Output = "Name  Id  Version`r`n$id 1.0" } } return [pscustomobject]@{ ExitCode = 1; Output = 'No installed package found matching input criteria.' } }
    if ($File -eq 'winget.exe' -and $Arguments[0] -eq 'install') { if ($script:Wg.InstallCode -eq 0) { $script:Wg.Installed[$Arguments[2]] = $true }; return [pscustomobject]@{ ExitCode = $script:Wg.InstallCode; Output = '' } }
    return [pscustomobject]@{ ExitCode = 0; Output = '' }
}
Reset-All; $script:ManifestUrl = ''
$apps = @(Get-FixItApprovedApps)
Assert ($apps.Count -eq 12 -and ($apps.Id -join ',') -eq 'Google.Chrome,Zoom.Zoom,Discord.Discord,VideoLAN.VLC,Spotify.Spotify,Apple.iTunes,OBSProject.OBSStudio,Audacity.Audacity,Adobe.Acrobat.Reader.64-bit,7zip.7zip,Google.GoogleDrive,Dropbox.Dropbox' -and ($apps.Name -join ',') -match 'Google Chrome,Zoom,Discord,VLC media player,Spotify,iTunes') 'default list: the 12 approved apps with exact ids'
$placeholder = 'https://raw.githubusercontent.com/<' + 'OWNER>/family-it-fixit/main/manifest.json'
$script:ManifestUrl = $placeholder; $script:Calls.Clear()
Assert (@(Get-FixItApprovedApps).Count -eq 12 -and (CallsLike 'web*') -eq 0) 'update address not set up yet: built-in list, no download'
$mm = Join-Path $tmp 'apps-manifest.json'
Set-Content $mm '{"version":"2.0.0","files":[],"apps":[{"id":"Mozilla.Firefox","name":"Firefox"},{"id":"Evil Pkg; calc","name":"Bad"},{"id":"x","name":"No dot"},{"id":"A.B","name":"<script>"},{"id":"Foo.Bar","name":"Foo Bar"}]}'
$mu = 'https://example.test/manifest.json'; $script:ManifestUrl = $mu; $script:WebMap = @{ $mu = $mm }
$apps = @(Get-FixItApprovedApps)
Assert ($apps.Count -eq 2 -and $apps[0].Id -eq 'Mozilla.Firefox' -and $apps[1].Id -eq 'Foo.Bar') 'list comes from the manifest; entries that look wrong are dropped'
Set-Content $mm '{"apps":[{"id":"bad id","name":"x"}]}'
Assert (@(Get-FixItApprovedApps).Count -eq 12) 'manifest list with no valid entries: built-in list'
$script:WebFail = $true
Assert (@(Get-FixItApprovedApps).Count -eq 12) 'offline: built-in list'
$script:WebFail = $false
Set-Content $mm '{"apps":[{"id":"Mozilla.Firefox","name":"Firefox"}]}'
Reset-All; $script:Wg.Installed = @{}; $script:Wg.InstallCode = 0; $script:Wg.Present = $true
$r = Invoke-InstallApp -AppName 'Notepad++'
Assert (-not $r.Ok -and $r.Title -eq 'Not on the safe list' -and (CallsLike 'native winget.exe install*') -eq 0) 'an app that is not on the list is never installed'
$r = Invoke-InstallApp -AppName 'Evil.Thing'
Assert (-not $r.Ok -and (CallsLike 'native*') -eq 0) 'an id that is not on the list is never installed'
$r = Invoke-InstallApp -AppName 'Firefox'
Assert ($r.Ok -and $r.Title -eq 'Installed' -and (CallsLike 'native winget.exe install --id Mozilla.Firefox --exact --source winget --silent --accept-package-agreements --accept-source-agreements') -eq 1) 'approved app: winget with the exact id and --source winget'
Assert ((CallsLike 'native winget.exe list --id Mozilla.Firefox --exact --source winget*') -eq 1) 'checks for it first, also with exact id and source'
$script:Calls.Clear(); $script:Asked.Clear()
$r = Invoke-InstallApp -AppName 'Firefox'
Assert ($r.Ok -and $r.Title -eq 'Already installed' -and (CallsLike 'native winget.exe install*') -eq 0 -and $script:Asked.Count -eq 0) 'second run: already installed, nothing changed (idempotent)'
Reset-All; $script:Wg.Installed = @{}; $script:Answers.Enqueue($false)
$r = Invoke-InstallApp -AppName 'Firefox'
Assert ($r.Ok -and $r.Title -eq 'Not installed' -and (CallsLike 'native winget.exe install*') -eq 0) 'asks first; No installs nothing'
Reset-All; $script:Wg.Installed = @{}; $script:Wg.InstallCode = 1
$r = Invoke-InstallApp -AppName 'Firefox'
Assert (-not $r.Ok -and $r.Message -match 'could not be installed' -and $r.Message -notmatch 'winget finished|exit') 'install failure: plain message'
Reset-All; $script:Wg.Installed = @{}; $script:Wg.InstallCode = -1978335135
Assert ((Invoke-InstallApp -AppName 'Firefox').Ok) 'winget "already installed" code counts as success'
Reset-All; $script:Wg.Installed = @{}; $script:Wg.InstallCode = 0; $script:Wg.Present = $false
$r = Invoke-InstallApp -AppName 'Firefox'
Assert (-not $r.Ok -and $r.Title -eq 'Cannot install apps here' -and (CallsLike 'native*') -eq 0) 'no winget on this PC: plain message, nothing run'
Reset-All; $script:Wg.Present = $true; $script:DryRun = $true
$r = Invoke-InstallApp -AppName 'Firefox'
Assert ($r.Ok -and (CallsLike 'native winget.exe install*') -eq 0 -and $script:Wg.Installed.Count -eq 0) 'dry-run: nothing installed'
Reset-All; $script:ManifestUrl = ''
$r = Invoke-InstallApp
Assert ($r.Ok -and $r.Details.Count -eq 12 -and (CallsLike 'native*') -eq 0) 'no app named: just lists the approved apps'
$gui = [IO.File]::ReadAllText((Join-Path $root 'FamilyFixIt.ps1'))
Assert ($gui -match "'--source', 'winget'" -and $gui -match "'--exact'") 'real adapter source: --exact and --source winget'
Assert ($gui.Contains('@(''install'', ''--id'', $Id, ')) 'install is only ever called with the validated id'
Set-Item function:Invoke-FixItNative $origNative
Remove-Item function:Test-FixItWinget

Section 'Sidebar items and published app list'
$acts = (Get-FixItActionTable).Keys
Assert (($acts -contains 'History') -and ($acts -contains 'Files') -and ($acts -contains 'Install')) 'action table has History, Files, Install'
$sb = [IO.File]::ReadAllText((Join-Path $root 'FamilyFixIt.ps1'))
foreach ($t in @("'What did I fix?'", "'My files'", "'Install an app'")) { Assert ($sb.Contains("@('") -and $sb.Contains($t)) "sidebar has $t" }
Assert ($sb -match "'History', 'Files', 'Install'") 'command-line actions History, Files, Install exist'
$ap = Get-Content (Join-Path $root 'apps.json') -Raw | ConvertFrom-Json
Assert (@($ap).Count -eq 12 -and (@($ap.id) -join ',') -eq 'Google.Chrome,Zoom.Zoom,Discord.Discord,VideoLAN.VLC,Spotify.Spotify,Apple.iTunes,OBSProject.OBSStudio,Audacity.Audacity,Adobe.Acrobat.Reader.64-bit,7zip.7zip,Google.GoogleDrive,Dropbox.Dropbox') 'apps.json: the 12 approved apps'

Section 'Printer: asks which printer, then sets the default'
function Pr { param($Name, $Default = $false, $Status = 'Normal', $Port = 'USB001') [pscustomobject]@{ Name = $Name; IsNetwork = $false; Server = ''; PortName = $Port; StatusText = $Status; WorkOffline = ($Status -eq 'Offline'); IsDefault = $Default } }
$ask = "Do you know which printer you're trying to use?"
$ntKey = $script:WindowsNtKey
# Yes: pick from a list, that printer becomes the default
Reset-All; $d = New-Spool
$script:Printers = @((Pr 'Office Printer' $true), (Pr 'Kitchen Printer'), (Pr 'Microsoft Print to PDF'))
$script:PickPrinter = 'Kitchen Printer'
$res = Invoke-PrinterFix
Assert (@($script:Asked)[0] -eq $ask) 'the first thing asked is: Do you know which printer you are trying to use?'
Assert ((CallsLike 'printer pick-list Office Printer|Kitchen Printer') -eq 1) 'Yes: the list shows the real printers (the PDF one is left out)'
Assert ((CallsLike 'printer default Kitchen Printer') -eq 1 -and ($script:Printers | Where-Object { $_.IsDefault }).Name -eq 'Kitchen Printer') 'Yes: the printer they picked becomes the default'
Assert ((CallsLike "regset $ntKey LegacyDefaultPrinterMode=1") -eq 1) 'Yes: Windows is told to keep the default (it will not switch by itself)'
Assert ($res.Ok -and $res.Title -eq 'Printer fixed' -and $res.DefaultPrinter -eq 'Kitchen Printer' -and $res.Message -match 'Kitchen Printer.*default') 'Yes: the message names the new default printer'
Assert ($script:Calls.IndexOf('printer pick-list Office Printer|Kitchen Printer') -lt $script:Calls.IndexOf('spooler stop')) 'the question comes before anything is changed'
Assert ((CallsLike 'port *') -eq 0) 'Yes: no tests are run (the person already knows)'
Assert (($res.Message + ($res.Details -join ' ')) -notmatch '(?i)spooler|registry|exception|LegacyDefault|tcp|port ') 'printer messages are jargon free'
# undo puts the old default back
Reset-All; $d = New-Spool; Remove-Item (Get-FixItUndoFile) -ErrorAction SilentlyContinue
$script:Printers = @((Pr 'Office Printer' $true), (Pr 'Kitchen Printer')); $script:PickPrinter = 'Kitchen Printer'
[void](Invoke-FixItAction -Which 'Printer')
$script:Calls.Clear()
$u = Invoke-UndoLast
Assert ((CallsLike 'printer default Office Printer') -eq 1 -and ($script:Printers | Where-Object { $_.IsDefault }).Name -eq 'Office Printer') 'Undo: the old default printer is put back'
Assert ((CallsLike "regrestore $ntKey LegacyDefaultPrinterMode") -eq 1) 'Undo: the "keep my default" setting is put back too'
# No: test all, choose one that works
Reset-All; $d = New-Spool
$script:Answers.Enqueue($false)
$script:Printers = @((Pr 'Office Printer' $true 'Offline'), (Pr 'Hallway Laser' $false 'Normal' 'IP_192.168.1.30'), (Pr 'Den Printer' $false 'Normal' 'USB002'), (Pr 'Microsoft Print to PDF'))
$script:OpenPorts = @{ '192.168.1.30' = $false }
$res = Invoke-PrinterFix
Assert (@($script:Asked)[0] -eq $ask) 'No: the same first question is asked'
Assert ((CallsLike 'printer pick-list*') -eq 0) 'No: no list is shown'
Assert ((CallsLike 'port 192.168.1.30') -eq 1) 'No: a network printer is really tested'
Assert ((CallsLike 'printer default Den Printer') -eq 1 -and ($script:Printers | Where-Object { $_.IsDefault }).Name -eq 'Den Printer') 'No: the first printer that works becomes the default'
Assert ($res.Ok -and $res.Message -match 'Den Printer.*working.*default printer') 'No: the message says which printer was picked'
$det = $res.Details -join ' | '
Assert ($det -match 'Tested "Office Printer": not available \(Windows says it is offline\)' -and $det -match 'Tested "Hallway Laser": not available \(it does not answer on the network\)' -and $det -match 'Tested "Den Printer": ready') 'No: each printer tested is listed with a plain reason'
Assert ($det -notmatch 'PDF') 'No: the PDF printer is never tested or chosen'
# No: the current default already works -> keep it
Reset-All; $d = New-Spool; $script:Answers.Enqueue($false)
$script:Printers = @((Pr 'Office Printer' $true), (Pr 'Den Printer'))
$res = Invoke-PrinterFix
Assert ((CallsLike 'printer default*') -eq 0 -and $res.Ok -and $res.Message -match 'Office Printer.*already your default') 'No: a default that already works is kept and the person is told'
# No: nothing is available
Reset-All; $d = New-Spool; $script:Answers.Enqueue($false)
$script:Printers = @((Pr 'Office Printer' $true 'Offline'), (Pr 'Den Printer' $false 'Offline'))
$res = Invoke-PrinterFix
Assert (-not $res.Ok -and $res.Message -match 'none of them is available' -and $res.Message -match 'call Trey' -and (CallsLike 'printer default*') -eq 0) 'No: none available is said plainly, nothing is changed, and the person is told to call Trey'
# Yes but the printer is not answering
Reset-All; $d = New-Spool; $script:PickPrinter = 'Den Printer'
$script:Printers = @((Pr 'Office Printer' $true), (Pr 'Den Printer' $false 'Offline'))
$res = Invoke-PrinterFix
Assert (-not $res.Ok -and $res.Message -match 'Den Printer.*not answering' -and (CallsLike 'printer default Den Printer') -eq 1) 'Yes + printer not answering: it is still made the default, and the problem is explained'
# Yes then go back from the list
Reset-All; $d = New-Spool; $script:PickPrinter = '<none>'
$script:Printers = @((Pr 'Office Printer' $true), (Pr 'Den Printer'))
$res = Invoke-PrinterFix
Assert ($res.Title -eq 'Nothing changed' -and $script:Calls.Contains('printer pick-list Office Printer|Den Printer') -and (CallsLike 'spooler*') -eq 0 -and (CallsLike 'printer default*') -eq 0 -and (Test-FixItSkipFollowUp $res)) 'closing the list changes nothing and skips "Did that fix it?"'
# no printers at all
Reset-All; $d = New-Spool; $script:Printers = @()
$res = Invoke-PrinterFix
Assert (@($script:Asked) -notcontains $ask -and $res.Ok) 'no printers on the computer: the question is not asked'
# practice run
Reset-All; $d = New-Spool; $script:DryRun = $true
$script:Printers = @((Pr 'Office Printer' $true), (Pr 'Den Printer'))
$res = Invoke-PrinterFix
Assert ((CallsLike 'printer *') -eq 0 -and (CallsLike 'regset*') -eq 0 -and $res.Title -eq 'Practice run') 'practice run: no list, no default change, no registry change'
Assert ((Get-Content $logFile -Raw) -match 'Would do: show the list of printers and make the one you pick your default printer') 'practice run: says what it would do'

Section 'Confirm window: what the fix will do, Proceed or Go Back'
$fullL = Get-FixItLayout -Simple $false
$mains = @($fullL.TileIds) + @('AcrobatRepair')
$tbl = Get-FixItActionTable
foreach ($k in $mains) {
    $pl = Get-FixItPlan -Which $k
    Assert ($null -ne $pl -and @($pl.Does).Count -ge 2 -and $pl.Time -and $pl.Title -eq $tbl[$k].Title) "main button $k has a plan with steps, a time and the button's own title"
}
foreach ($k in @('Pin', 'Restart', 'Undo', 'Status', 'History', 'Files', 'Install', 'PCInfo', 'Guides')) { Assert ($null -eq (Get-FixItPlan -Which $k)) "side-list item $k has no confirm window" }
# Go Back does nothing at all
foreach ($k in $mains) {
    Reset-All; $d = New-Spool; Seed-BrokenAcrobat; Remove-Item (Get-FixItUndoFile) -ErrorAction SilentlyContinue
    $script:PlanAnswer = $false; $script:PlanSeen = @(); $script:Posts.Clear()
    $regBefore = RegSnapshot
    $r = Invoke-FixItAction -Which $k
    Assert ($null -eq $r -and $script:Calls.Count -eq 0 -and @($script:Asked).Count -eq 0 -and $script:PlanSeen.Count -eq 1 -and $script:PlanSeen[0].Which -eq $k) "Go Back on ${k}: window shown once, nothing done, nothing asked"
    Assert ((RegSnapshot) -eq $regBefore -and -not (Test-Path (Get-FixItUndoFile)) -and $script:Posts.Count -eq 0 -and @(Get-ChildItem $d -File).Count -eq 6) "Go Back on ${k}: no settings, files, undo record or report"
}
$script:PlanAnswer = $true
# Proceed runs the fix, and the window comes first
Reset-All; $d = New-Spool; $script:PlanSeen = @(); $script:PlanAnswer = $true
$script:Spk = [pscustomobject]@{ Name = 'Test device'; Volume = 0; Muted = $true }; $script:Mic = [pscustomobject]@{ Name = 'Test device'; Volume = 0; Muted = $true }
$r = Invoke-FixItAction -Which 'Sound'
Assert ($script:PlanSeen.Count -eq 1 -and $r -and (CallsLike 'audio Speakers 25*') -eq 1) 'Proceed: the window is shown once, then the fix runs'
Reset-All; $script:PlanSeen = @(); $script:Spk = [pscustomobject]@{ Name = 'Test device'; Volume = 0; Muted = $true }; $script:Mic = [pscustomobject]@{ Name = 'Test device'; Volume = 0; Muted = $true }
[void](Invoke-FixItAction -Which 'Sound' -SkipPlan)
Assert ($script:PlanSeen.Count -eq 0) '-SkipPlan does not show the window a second time'
# practice run logs the plan and does not ask
Reset-All; $script:DryRun = $true; $script:PlanSeen = @()
[void](Invoke-FixItAction -Which 'Slow')
$lg = Get-Content $logFile -Raw
Assert ($script:PlanSeen.Count -eq 0 -and $lg -match 'Would show the "what I will do" window for: My computer is slow' -and $lg -match 'You may need to sign in again') 'practice run: the plan is written to the log, nobody is asked'
# text: restart and sign-in lines
$p = Get-FixItPlan -Which 'Printer'
Assert ($p.RestartLine -eq 'You will not need to restart your computer.' -and $p.SignInLine -eq 'You will not need to sign in again anywhere.' -and -not $p.NeedsRestart -and -not $p.NeedsSignIn) 'no restart and no sign-in: the window says so plainly'
$p = Get-FixItPlan -Which 'Slow'
Assert ($p.NeedsSignIn -and $p.SignInLine -match 'sign back in to websites' -and $p.SignInLine -match 'I ask you first') 'Slow: the window warns about signing back in to websites'
$txt = (Format-FixItPlanText -Plan (Get-FixItPlan -Which 'Network')) -join "`n"
Assert ($txt -match 'Here is what I will do:' -and $txt -match '(?m)^  1\. ' -and $txt -match 'Please know:' -and $txt -match 'How long it takes:' -and $txt -match 'restart your computer' -and $txt -match 'sign in') 'the plan text has steps, notes, time, restart and sign-in lines'
# one table drives everything: the claims match the code
$needRestart = @($mains | Where-Object { (Get-FixItPlan -Which $_).NeedsRestart } | Sort-Object)
Assert (($needRestart -join ',') -eq 'Acrobat,AcrobatRepair,Network,Slow,WinUpdate') 'restart warning is on exactly: Acrobat, Acrobat repair, internet, slow, Windows Update'
$needSign = @($mains | Where-Object { (Get-FixItPlan -Which $_).NeedsSignIn } | Sort-Object)
Assert (($needSign -join ',') -eq 'Browser,OneDrive,Slow') 'sign-in warning is on exactly: browser, OneDrive, slow'
$srcT = $null; $srcE = $null
$srcTree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'FamilyFixIt.ps1'), [ref]$srcT, [ref]$srcE)
$fnAsts = $srcTree.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
function FnText { param($Name) return (@($fnAsts | Where-Object { $_.Name -eq $Name } | ForEach-Object { $_.Extent.Text }) -join "`n") }
foreach ($k in $mains) {
    $t = FnText $tbl[$k].Fn
    if ($t -match 'Invoke-AcrobatRepair') { $t = $t + (FnText 'Invoke-AcrobatRepair') }
    $restartsPc = ($t -match 'Restart-Computer|Restart-FixItComputer|Restart-FixItNow|shutdown')
    if (-not (Get-FixItPlan -Which $k).NeedsRestart) { Assert (-not $restartsPc) "$k says no restart is needed, and its code never restarts the computer" }
    else { Assert ($t -match '(?i)restart|reboot|3010') "$k warns about a restart, and its code does mention one" }
}
$cacheUsers = @($fnAsts | Where-Object { $_.Extent.Text -match 'Get-FixItBrowserCacheFolders' -and $_.Name -ne 'Get-FixItBrowserCacheFolders' } | ForEach-Object { $_.Name })
Assert (($cacheUsers -join ',') -eq 'Invoke-SlowFix') 'only the slow fix clears browser cache (so only it carries that sign-in warning)'
$ol = (Get-FixItPlan -Which 'Outlook'); $ac = (Get-FixItPlan -Which 'Acrobat')
Assert (($ol.Heads -join ' ') -match 'never cleared or changed' -and ($ac.Heads -join ' ') -match 'not touched' -and -not $ol.NeedsSignIn -and -not $ac.NeedsSignIn) 'Outlook and Acrobat windows promise accounts and sign-ins are untouched'
$sp = (Get-FixItPlan -Which 'Sound').Does -join ' '
Assert ($sp -match "$($script:SpeakerRestoreVolume)%" -and $sp -match "$($script:MicRestoreVolume)%" -and $script:SpeakerRestoreVolume -eq 25) 'Sound window quotes the real volumes (speakers 25%, mic 70%)'
$np = (Get-FixItPlan -Which 'Network').Does -join ' '
Assert ($np.Contains($script:RouterRestartText) -and $np -match ('about {0} minutes' -f ($script:RouterWaitSeconds / 60))) 'Internet window quotes the real router text and wait time'
$pp = (Get-FixItPlan -Which 'Printer').Does -join ' '
Assert ($pp.Contains($ask.Replace("I will ask you: ", ''))) 'Printer window quotes the real question'
# plain words
$bad = '(?i)\b(DNS|DHCP|registry|winsock|spooler|LoadBehavior|cache file|proxy|IP address|msiexec|PowerShell|admin|administrator|UAC|HKLM|HKCU|TCP|adapter|ipconfig|netsh|process|processes|service|services|sfc|DISM|SoftwareDistribution|catroot|credential|credentials|token|registry|cmdlet|script|firewall|driver)\b'
foreach ($k in $mains) {
    $pl = Get-FixItPlan -Which $k
    $all = (@($pl.Does) + @($pl.Heads) + @($pl.Time, $pl.RestartLine, $pl.SignInLine)) -join "`n"
    Assert ($all -notmatch $bad) "$k window uses plain words (no technical terms)"
    Assert ($all -match '^[\x09\x0A\x20-\x7E]+$') "$k window text is plain ASCII"
}
# the real command-line reader: P proceeds, G / anything else goes back
$readAst = $fnAsts | Where-Object { $_.Name -eq 'Read-FixItPlanChoice' }
Invoke-Expression ($readAst.Extent.Text -replace 'function Read-FixItPlanChoice', 'function Read-PlanReal')
function Read-Host { param($Prompt) return $script:HostAnswer }
$script:GuiActive = $false
$okAns = @(); foreach ($a in @('P', 'p', 'proceed', 'G', 'g', '', 'no', 'x')) { $script:HostAnswer = $a; $okAns += [string][bool](Read-PlanReal -Plan (Get-FixItPlan -Which 'Printer')) }
Assert (($okAns -join ',') -eq 'True,True,True,False,False,False,False,False') 'command line: P proceeds; G, Enter or anything else goes back'
Remove-Item function:Read-Host
# the window itself and the GUI wiring
$dlg = FnText 'Show-FixItPlanDialog'
Assert ($dlg -match "'Proceed'" -and $dlg -match "'Go Back'" -and $dlg -match 'RestartLine' -and $dlg -match 'SignInLine' -and $dlg -match 'CancelButton') 'the window has Proceed and Go Back, shows both warnings, and Esc / closing means Go Back'
$gb = FnText 'Invoke-GuiButton'
$iPlan = $gb.IndexOf('Confirm-FixItPlan -Which $Which'); $iBusy = $gb.IndexOf('Working on it'); $iRun = $gb.IndexOf('Invoke-FixItAction -Which $Which -SkipPlan')
Assert ($iPlan -gt 0 -and $iPlan -lt $iBusy -and $iBusy -lt $iRun) 'a button asks first, then shows "working", then runs the fix'
$callers = @($fnAsts | Where-Object { $_.Extent.Text -match 'Invoke-FixItAction ' -and $_.Name -notin @('Invoke-FixItAction') } | ForEach-Object { $_.Name })
Assert (($callers | Sort-Object) -join ',' -eq 'Invoke-FixItAndShow,Invoke-FixItTestAll,Invoke-GuiButton') 'only three places run a main action: the button handler (after the window), the command line (which asks too) and the Test mode check-everything run (which changes nothing)'
Assert ((FnText 'Invoke-FixItAndShow') -notmatch '-SkipPlan') 'the command line never skips the window'
foreach ($k in @($fullL.TileIds)) { Assert ($src -match "'$k'\s+\{ \[void\]\(Invoke-FixItAndShow -Which '$k'\)") "command line action $k exists" }

Section 'Pin me to the taskbar'
$simpL = Get-FixItLayout -Simple $true
foreach ($L in @($fullL, $simpL)) {
    $pin = @($L.Pin)
    $lastY = (@($L.Nav) + @($L.Toggles) | ForEach-Object { [int]$_[4] } | Measure-Object -Maximum).Maximum
    Assert ($pin[0] -eq 'Pin' -and $pin[1] -eq 'Pin me to the taskbar' -and $pin[3] -eq 'pin') ('the Pin item has the right name and icon (' + $L.SideTitle + ')')
    Assert ([int]$pin[4] -gt $lastY -and ([int]$pin[4] + [int]$pin[5]) -lt $L.FullH) ('the Pin item is the last one in the left list, inside the window (' + $L.SideTitle + ')')
}
Assert ($tbl.Contains('Pin') -and -not $tbl['Pin'].Fix -and $null -ne (Get-Command $tbl['Pin'].Fn -ErrorAction SilentlyContinue)) 'Pin is an action that changes nothing'
$script:Calls.Clear(); $regB = RegSnapshot; $script:PlanSeen = @(); $script:PlanAnswer = $false
$r = Invoke-FixItAction -Which 'Pin'
$script:PlanAnswer = $true
Assert ($r.Ok -and $r.Title -eq 'Pin Family Fix-It to the taskbar' -and $r.GuideId -eq 'pin-taskbar' -and $script:Calls.Count -eq 0 -and (RegSnapshot) -eq $regB -and $script:PlanSeen.Count -eq 0) 'Pin shows a guide only: no window, no changes'
$g = Get-FixItPinGuide
Assert (@($g.Steps).Count -eq 5 -and ($g.Steps -join ' ') -match 'Start' -and ($g.Steps -join ' ') -match 'Pin to taskbar' -and ($g.Steps -join ' ') -match 'Right-click' -and $r.Message -match 'does not allow a program to pin itself') 'the guide explains Start, right-click, Pin to taskbar and why Windows blocks self-pinning'
Assert (@($r.Details).Count -eq 5 -and $r.Details[0] -match '^1\. ') 'the result lists the numbered steps'
Assert (($g.Steps + $r.Message) -join ' ' -notmatch $bad -and ($g.Steps -join ' ') -match '^[\x09\x0A\x20-\x7E]+$') 'the pin guide is plain words and plain ASCII'
Assert ($src -match "'pin'\s*=\s*'iVBOR" -and $src -match "'pinW'\s*=\s*'iVBOR") 'both Pin icons (dark and white) are built into the program'
$gbPin = FnText 'Invoke-GuiButton'
Assert ($gbPin -match "if \(\`$Which -eq 'Pin'\) \{ Show-FixItGuideSteps -Guide \(Get-FixItPinGuide\)") 'the Pin button opens the step-by-step guide window'
$outPin = & (Get-Command pwsh).Source -NoProfile -File (Join-Path $root 'FamilyFixIt.ps1') -Action Pin -LogPath (Join-Path $tmp 'cli-pin.log') 2>&1 | Out-String
Assert ($LASTEXITCODE -eq 0 -and $outPin -match 'Pin to taskbar') 'command line: -Action Pin prints the steps'

Section 'Version'
Assert ($script:FixItVersion -eq '2.3.15') 'the program is version 2.3.15'

Section 'Publish + update'
$pub = Join-Path $root 'tools/Publish-FixIt.ps1'
$dist = Join-Path $tmp 'dist1'
& $pub -Owner 'octo-test' -OutDir $dist -WarningAction SilentlyContinue | Out-Null
$man = Get-Content (Join-Path $dist 'manifest.json') -Raw | ConvertFrom-Json
Assert ($man.version -eq '2.3.15' -and @($man.files).Count -eq 4) 'manifest has version and 4 runtime files'
Assert (@($man.apps).Count -eq 12 -and $man.apps[0].id -eq 'Google.Chrome' -and $man.apps[0].section -eq 'Browsers and chat' -and [string]$man.apps[0].description -and $man.apps[4].id -eq 'Spotify.Spotify' -and $man.apps[4].elevationProhibited -eq $true -and -not ($man.apps[0].PSObject.Properties['elevationProhibited'])) 'manifest carries the approved app list with sections, descriptions and the Spotify flag'
Assert (@($man.assets).Count -eq 1 -and $man.assets[0].path -eq 'FamilyFixIt.ico' -and $man.assets[0].sha256 -match '^[0-9a-f]{64}$' -and [int]$man.assets[0].size -gt 1000) 'manifest lists the program icon under assets, with its SHA-256 and size'
Assert (@($man.files | Where-Object { $_.path -like '*.ico' }).Count -eq 0) 'the icon is NOT in "files" (versions up to 2.3.1 refuse unknown names there, which would break their update)'
Assert ((Get-FileSha256 (Join-Path $dist 'FamilyFixIt.ico')) -eq $man.assets[0].sha256 -and (Get-FileSha256 (Join-Path $dist 'FamilyFixIt.ico')) -eq (Get-FileSha256 (Join-Path $root 'FamilyFixIt.ico'))) 'published icon is byte-for-byte the source icon and matches the manifest'
$badApps = Join-Path $tmp 'badapps'; Copy-Item -LiteralPath $root -Destination $badApps -Recurse
Set-Content (Join-Path $badApps 'apps.json') '[{"id":"calc; evil","name":"x"}]'
$threw = $false; try { & $pub -SourceDir $badApps -OutDir (Join-Path $tmp 'badout') -WarningAction SilentlyContinue | Out-Null } catch { $threw = $true }
Assert $threw 'publish refuses an app id that is not allowed'
$okHash = $true; foreach ($f in $man.files) { if ((Get-FileSha256 (Join-Path $dist $f.path)) -ne $f.sha256) { $okHash = $false } }
Assert $okHash 'manifest SHA-256 values match files'
Assert ([IO.File]::ReadAllText((Join-Path $dist 'FamilyFixIt.ps1')) -match 'raw\.githubusercontent\.com/octo-test/family-it-fixit/main/manifest\.json') 'owner filled into the default manifest URL'
Assert (-not ([IO.File]::ReadAllText((Join-Path $dist 'FamilyFixIt.ps1')) -match '<OWNER>')) 'no placeholder left when owner given'
foreach ($f in @('tools/Publish-FixIt.ps1', 'tests/Test-FixIt.ps1', '.gitattributes', '.gitignore', 'README.md', 'Start-FixIt.cmd')) { Assert (Test-Path (Join-Path $dist $f)) "dist contains $f" }
$dist0 = Join-Path $tmp 'dist0'
& $pub -OutDir $dist0 -WarningAction SilentlyContinue | Out-Null
Assert ([IO.File]::ReadAllText((Join-Path $dist0 'FamilyFixIt.ps1')) -match '<OWNER>') 'no owner: placeholder stays (updates stay off)'
# leak scan
$leakSrc = Join-Path $tmp 'leaksrc'; Copy-Item -LiteralPath $root -Destination $leakSrc -Recurse
Add-Content (Join-Path $leakSrc 'README.md') ('contact: ' + 'someone' + '@' + 'example.com')
$threw = $false; try { & $pub -SourceDir $leakSrc -OutDir (Join-Path $tmp 'leakout') -WarningAction SilentlyContinue | Out-Null } catch { $threw = $true }
Assert ($threw -and -not (Test-Path (Join-Path $tmp 'leakout'))) 'publish refuses when an email address is in the files'
$threw = $false; try { & $pub -Owner 'bad owner/..' -OutDir (Join-Path $tmp 'x2') | Out-Null } catch { $threw = $true }
Assert $threw 'publish rejects a malformed owner name'
Assert (-not (Select-String -Path (Join-Path $dist '*') -Pattern '(?i)treyb|@gmail|@outlook|highgrove' -ErrorAction SilentlyContinue | Where-Object { $_.Line -notmatch 'paypal\.me/TreyBarton' })) 'no personal identifiers in published files'

# a newer version 1.0.1 to update to
$newSrc = Join-Path $tmp 'newsrc'; Copy-Item -LiteralPath $root -Destination $newSrc -Recurse
$ps = Join-Path $newSrc 'FamilyFixIt.ps1'
[IO.File]::WriteAllText($ps, ([IO.File]::ReadAllText($ps).Replace("FixItVersion = '2.3.15'", "FixItVersion = '2.3.16'")))
$dist2 = Join-Path $tmp 'dist2'
& (Join-Path $newSrc 'tools/Publish-FixIt.ps1') -SourceDir $newSrc -Owner 'octo-test' -OutDir $dist2 | Out-Null
$base = 'https://raw.githubusercontent.com/octo-test/family-it-fixit/main/'
function Set-Web { param($Dir) $script:WebMap = @{}; $script:WebMap[$base + 'manifest.json'] = (Join-Path $Dir 'manifest.json'); foreach ($f in ($script:AllowedUpdateFiles + $script:AllowedAssetFiles)) { $script:WebMap[$base + $f] = (Join-Path $Dir $f) } }
function New-Install { $i = Join-Path $tmp ('inst-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $i | Out-Null; foreach ($f in $script:AllowedUpdateFiles) { Copy-Item (Join-Path $dist $f) $i }; return $i }
$script:ManifestUrl = $base + 'manifest.json'

Reset-All; Set-Web $dist2; $script:InstallDir = New-Install
$res = Invoke-FixItUpdate
Assert ($res.Ok -and $res.Title -eq 'Updated') 'newer version installs after asking'
Assert ([IO.File]::ReadAllText((Join-Path $script:InstallDir 'FamilyFixIt.ps1')) -match "FixItVersion = '2.3.16'") 'installed script is the new one'
Assert (Test-Path (Join-Path $script:InstallDir 'previous/FamilyFixIt.ps1')) 'old version kept in previous/'
Assert (@($script:Asked).Count -eq 1) 'asked before updating'

Reset-All; Set-Web $dist2; $script:InstallDir = New-Install; $script:Answers.Enqueue($false)
$res = Invoke-FixItUpdate
Assert ($null -eq $res -and (CallsLike 'download*') -eq 0) 'update declined: nothing downloaded'

Reset-All; Set-Web $dist2; $script:InstallDir = New-Install; $script:DryRun = $true
$res = Invoke-FixItUpdate
Assert ($res.Title -eq 'Practice run' -and (CallsLike 'download*') -eq 0) 'dry-run update: nothing downloaded'

# tampered file: checksum mismatch => nothing changes
$dist3 = Join-Path $tmp 'dist3'; Copy-Item $dist2 $dist3 -Recurse
Add-Content (Join-Path $dist3 'README.md') 'tampered'
Reset-All; Set-Web $dist3; $script:InstallDir = New-Install; $before = Get-FileSha256 (Join-Path $script:InstallDir 'FamilyFixIt.ps1')
$res = Invoke-FixItUpdate
Assert (-not $res.Ok -and (Get-FileSha256 (Join-Path $script:InstallDir 'FamilyFixIt.ps1')) -eq $before) 'checksum mismatch: update refused, nothing replaced'
Assert ($res.Message -notmatch '(?i)checksum|exception') 'failure message is plain'

# bad manifests
$dist4 = Join-Path $tmp 'dist4'; Copy-Item $dist2 $dist4 -Recurse
$j = Get-Content (Join-Path $dist4 'manifest.json') -Raw | ConvertFrom-Json; $j.files[0].path = '..\evil.ps1'
[IO.File]::WriteAllText((Join-Path $dist4 'manifest.json'), ($j | ConvertTo-Json -Depth 4))
Reset-All; Set-Web $dist4; $script:InstallDir = New-Install
$res = Invoke-FixItUpdate
Assert (-not $res.Ok -and (CallsLike 'download*') -eq 0) 'path-traversal file name in manifest rejected'
Reset-All; Set-Web $dist; $script:InstallDir = New-Install
$res = Invoke-FixItUpdate
Assert ($res.Ok -and $res.Title -eq 'Up to date' -and (CallsLike 'download*') -eq 0) 'same version: up to date, nothing downloaded'
Reset-All; $script:WebFail = $true
$res = Invoke-FixItUpdate
Assert (-not $res.Ok -and $res.Message -match 'internet') 'offline: friendly message'
Assert ($null -eq (Invoke-FixItUpdate -Quiet)) 'offline + quiet: says nothing'
$script:WebFail = $false
Reset-All
$script:ManifestUrl = 'http://example.invalid/manifest.json'
$res = Invoke-FixItUpdate
Assert (-not $res.Ok -and (CallsLike 'web*') -eq 0) 'plain http refused'
$script:ManifestUrl = $script:DefaultManifestUrl
Reset-All
$res = Invoke-FixItUpdate
Assert ($res.Ok -and $res.Message -match 'not set up' -and (CallsLike 'web*') -eq 0) 'placeholder URL: updates off, no network call'
Assert ($null -eq (Invoke-FixItUpdate -Quiet)) 'placeholder + quiet: silent'

Section 'Guardian: is it a full-screen browser?'
Assert ((Test-FixItBrowserName 'msedge') -and (Test-FixItBrowserName 'Chrome.exe') -and (Test-FixItBrowserName 'firefox') -and (Test-FixItBrowserName 'brave') -and (Test-FixItBrowserName 'opera') -and (Test-FixItBrowserName 'iexplore')) 'the six browsers are recognised'
Assert (-not (Test-FixItBrowserName 'notepad') -and -not (Test-FixItBrowserName '') -and -not (Test-FixItBrowserName 'chromedriver')) 'other programs are not browsers'
function MkFg {
    param([string]$Proc = 'msedge', [int64]$H = 1001, [int[]]$R = @(0, 0, 1920, 1080), [int[]]$M = @(0, 0, 1920, 1080), [bool]$Zoomed = $false, [bool]$Caption = $false, [string]$Title = 'Warning! - Microsoft Edge')
    return [pscustomobject]@{ Handle = $H; ProcessId = 4242; ProcessName = $Proc; Title = $Title; Left = $R[0]; Top = $R[1]; Right = $R[2]; Bottom = $R[3]; MonLeft = $M[0]; MonTop = $M[1]; MonRight = $M[2]; MonBottom = $M[3]; IsZoomed = $Zoomed; HasCaption = $Caption }
}
Assert (Test-FixItWindowFullscreen (MkFg)) 'a window exactly covering the monitor is full screen'
Assert (Test-FixItWindowFullscreen (MkFg -R @(-2, -1, 1922, 1081))) 'a window slightly bigger than the monitor (kiosk) is full screen'
Assert (-not (Test-FixItWindowFullscreen (MkFg -R @(-8, -8, 1928, 1032) -Zoomed $true -Caption $true))) 'an ordinary maximized window (taskbar showing) is not full screen'
Assert (-not (Test-FixItWindowFullscreen (MkFg -R @(-8, -8, 1928, 1088) -Zoomed $true -Caption $true))) 'a maximized window with an auto-hidden taskbar (spills over the edge, has a title bar) is not full screen'
Assert (Test-FixItWindowFullscreen (MkFg -R @(0, 0, 1920, 1080) -Zoomed $true -Caption $true)) 'zoomed exactly to the monitor edge still counts as full screen'
Assert (-not (Test-FixItWindowFullscreen (MkFg -R @(100, 100, 1300, 900)))) 'a normal window is not full screen'
Assert (-not (Test-FixItWindowFullscreen (MkFg -R @(0, 0, 1920, 1040)))) 'covering all but the taskbar is not full screen'
Assert (Test-FixItWindowFullscreen (MkFg -R @(1920, 0, 3840, 1080) -M @(1920, 0, 3840, 1080))) 'works on a second monitor'
Assert (-not (Test-FixItWindowFullscreen (MkFg -R @(0, 0, 1920, 1080) -M @(0, 0, 0, 0)))) 'a bad monitor size never counts'
Assert (-not (Test-FixItWindowFullscreen $null)) 'nothing in front: not full screen'

Section 'Guardian: when to ask'
$t0 = Get-Date
Assert ($script:GuardianLooksNeeded -eq 4 -and $script:GuardianQuietMinutes -eq 120) 'the Guardian waits for 4 looks in a row and stays quiet 2 hours after "I am fine"'
$st = New-FixItGuardianState
$res = @(); foreach ($i in 0..3) { $res += (Get-FixItGuardianDecision -Fg (MkFg) -State $st -Now $t0.AddSeconds(1.5 * $i)) }
Assert (($res -join ',') -eq 'None,None,None,Show') 'a page that is full screen for only 3 looks (a few seconds) does not raise the question; the 4th does'
$st = New-FixItGuardianState
Set-FixItGuardianFine -Fg (MkFg -H 5) -State $st -Now $t0
Assert ($st.ProcQuiet['msedge'] -ge $t0.AddMinutes(119)) '"I am fine" keeps the same browser quiet for about 2 hours'
$script:GuardianLooksNeeded = 2; $script:GuardianQuietMinutes = 30   # the older checks below use the short settings
$st = New-FixItGuardianState
Assert ((Get-FixItGuardianDecision -Fg (MkFg) -State $st -Now $t0) -eq 'None') 'first look: wait (needs two in a row)'
Assert ((Get-FixItGuardianDecision -Fg (MkFg) -State $st -Now $t0.AddSeconds(1.5)) -eq 'Show') 'second look in a row: ask'
Assert ((Get-FixItGuardianDecision -Fg (MkFg) -State $st -Now $t0.AddSeconds(3)) -eq 'None') 'already asking: do not ask again'
Assert ((Get-FixItGuardianDecision -Fg (MkFg -R @(100, 100, 900, 700)) -State $st -Now $t0.AddSeconds(4.5)) -eq 'Hide') 'page left full screen: the question goes away'
$st = New-FixItGuardianState
[void](Get-FixItGuardianDecision -Fg (MkFg) -State $st -Now $t0)
[void](Get-FixItGuardianDecision -Fg (MkFg -R @(10, 10, 500, 500)) -State $st -Now $t0.AddSeconds(1.5))
Assert ((Get-FixItGuardianDecision -Fg (MkFg) -State $st -Now $t0.AddSeconds(3)) -eq 'None') 'a quick flicker out of full screen restarts the count'
$st = New-FixItGuardianState
foreach ($i in 0..4) { Assert ((Get-FixItGuardianDecision -Fg (MkFg -Proc 'notepad') -State $st -Now $t0.AddSeconds($i)) -eq 'None') 'a full-screen program that is not a browser is ignored' }
$st = New-FixItGuardianState
[void](Get-FixItGuardianDecision -Fg (MkFg) -State $st -Now $t0); [void](Get-FixItGuardianDecision -Fg (MkFg) -State $st -Now $t0.AddSeconds(1.5))
Set-FixItGuardianFine -Fg (MkFg) -State $st -Now $t0.AddSeconds(5)
$ok1 = $true; foreach ($i in 0..5) { if ((Get-FixItGuardianDecision -Fg (MkFg) -State $st -Now $t0.AddSeconds(6 + $i)) -ne 'None') { $ok1 = $false } }
Assert $ok1 "after I'm fine: never asks again about the same window"
$ok2 = $true; foreach ($i in 0..5) { if ((Get-FixItGuardianDecision -Fg (MkFg -H 2002) -State $st -Now $t0.AddMinutes(10).AddSeconds($i * 2)) -ne 'None') { $ok2 = $false } }
Assert $ok2 "after I'm fine: a video in a new window of the same browser stays quiet for 30 minutes"
$a1 = Get-FixItGuardianDecision -Fg (MkFg -H 3003) -State $st -Now $t0.AddMinutes(36)
$a2 = Get-FixItGuardianDecision -Fg (MkFg -H 3003) -State $st -Now $t0.AddMinutes(36).AddSeconds(2)
Assert ($a1 -eq 'None' -and $a2 -eq 'Show') 'after the quiet time it asks again for a new full-screen page'
$st = New-FixItGuardianState
[void](Get-FixItGuardianDecision -Fg (MkFg -Proc 'firefox' -H 77) -State $st -Now $t0); [void](Get-FixItGuardianDecision -Fg (MkFg -Proc 'firefox' -H 77) -State $st -Now $t0.AddSeconds(1.5))
Set-FixItGuardianFine -Fg (MkFg -Proc 'firefox' -H 77) -State $st -Now $t0.AddSeconds(2)
[void](Get-FixItGuardianDecision -Fg (MkFg -Proc 'chrome' -H 88) -State $st -Now $t0.AddSeconds(3)); 
Assert ((Get-FixItGuardianDecision -Fg (MkFg -Proc 'chrome' -H 88) -State $st -Now $t0.AddSeconds(4.5)) -eq 'Show') "I'm fine for Firefox does not silence Chrome"
$st = New-FixItGuardianState
$st.ToastOpen = $true; $st.ToastMode = 'Calm'; $st.CalmSince = $t0
Assert ((Get-FixItGuardianDecision -Fg $null -State $st -Now $t0.AddSeconds(30)) -eq 'None' -and $st.ToastOpen) 'the calm message stays after the page is gone'
Assert ((Get-FixItGuardianDecision -Fg $null -State $st -Now $t0.AddSeconds(130)) -eq 'Hide') 'the calm message goes away by itself after 2 minutes'
$st = New-FixItGuardianState
foreach ($i in 0..250) { Set-FixItGuardianFine -Fg (MkFg -H (5000 + $i)) -State $st -Now $t0 }
Assert ($st.Dismissed.Count -le 201) 'the list of dismissed windows cannot grow forever'

$script:GuardianLooksNeeded = 4; $script:GuardianQuietMinutes = 120
Section 'Guardian: facts for the report'
$fl = @(Get-FixItBrowserFlags -CommandLine '"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" --kiosk "https://evil.example/virus-alert" --no-first-run --user-data-dir="C:\Users\x\AppData\Local\Temp\p" --app=https://evil.example/a')
Assert ($fl -contains 'https://evil.example/virus-alert' -and $fl -contains '--kiosk' -and ($fl | Where-Object { $_ -like '--app=https://evil.example/a' }) -and -not ($fl -match 'Users')) 'kiosk / app flags and web addresses are picked out of a command line, paths are not'
Assert (@(Get-FixItBrowserFlags -CommandLine '').Count -eq 0) 'empty command line: nothing'

Section 'Guardian: Get me out of here'
$script:Browsers = @([pscustomobject]@{ Name = 'msedge'; Id = 4242 }, [pscustomobject]@{ Name = 'msedge'; Id = 4243 }, [pscustomobject]@{ Name = 'chrome'; Id = 5000 })
$script:Killed = New-Object System.Collections.ArrayList; $script:PostsAtKill = -1; $script:KillFail = @()
function Get-FixItBrowserProcesses { return @($script:Browsers) }
function Stop-FixItProcessForce { param([int]$Id) if ($script:PostsAtKill -lt 0) { $script:PostsAtKill = $script:Posts.Count }; if ($script:KillFail -contains $Id) { throw 'pretend: access denied' }; [void]$script:Killed.Add($Id) }
function Wait-FixItProcessesGone { param([int[]]$Ids, [int]$Seconds = 4) Rec "wait $($Ids.Count)" }
function Get-FixItProcessCommandLine { param([int]$Id) return '"msedge.exe" --kiosk https://scam.example/alert' }
$script:UrlFn = 'https://scam.example/alert?id=7'
function Get-FixItBrowserUrl { param([int64]$Handle) if ($script:UrlFn -eq 'THROW') { throw 'pretend: UIA failed' }; return $script:UrlFn }
$script:SessTargets = @()
function Get-FixItSessionTargets { return @($script:SessTargets) }
function Get-FixItStateFile { return (Join-Path $tmp 'state-gd.json') }
function Reset-Guardian { Reset-All; $script:Killed.Clear(); $script:PostsAtKill = -1; $script:KillFail = @(); $script:UrlFn = 'https://scam.example/alert?id=7'; $script:SessTargets = @(); $script:Browsers = @([pscustomobject]@{ Name = 'msedge'; Id = 4242 }, [pscustomobject]@{ Name = 'msedge'; Id = 4243 }, [pscustomobject]@{ Name = 'chrome'; Id = 5000 }) }

Reset-Guardian; $og = Join-Path $tmp 'gd1'; New-Item -ItemType Directory $og -Force | Out-Null; $OutputDir = $og
$script:Downloads = @([pscustomobject]@{ Name = 'fix-your-pc.exe'; Date = (Get-Date); KB = 700 })
$r = Invoke-GuardianGetOut -Fg (MkFg) -Reason 'button'
Assert (@($script:Killed).Count -eq 3 -and ($script:Killed -contains 4242) -and ($script:Killed -contains 5000)) 'every browser process is force-closed'
Assert ($script:PostsAtKill -eq 0) 'the browsers are closed BEFORE the (slower) report is built and sent'
Assert ($r.Message -eq "You're safe. Don't call any number that page showed. Trey has been told.") 'the calm message is exactly as agreed'
Assert ($script:Posts.Count -eq 1 -and ($script:Posts[0].Json | ConvertFrom-Json).kind -eq 'scam') 'a SCAM alert report is sent automatically'
$gj = ($script:Posts[0].Json | ConvertFrom-Json).report
Assert ($gj -match 'GUARDIAN' -and $gj -match 'Get me out of here' -and $gj -match 'Warning! - Microsoft Edge' -and $gj -match 'https://scam.example/alert\?id=7') 'report has the reason, the window title and the page address'
Assert ($gj -match '--kiosk' -and $gj -match 'Browser programs closed: 3' -and $gj -match 'fix-your-pc.exe' -and $gj -match 'SCAM ALERT') 'report has the browser flags, the number closed, recent downloads and the SCAM header'
Assert ($r.Sent -and -not (Get-ChildItem $og -Filter 'SCAM-*' -ErrorAction SilentlyContinue)) 'sent: no extra file left behind'
Reset-Guardian; $OutputDir = $og; $script:UrlFn = 'THROW'
$r = Invoke-GuardianGetOut -Fg (MkFg) -Reason 'button'
$gj = ($script:Posts[0].Json | ConvertFrom-Json).report
Assert ($r.Sent -and $gj -match 'Page address: not available') 'no page address available: still works, says so'
Reset-Guardian; $OutputDir = $og
$r = Invoke-GuardianGetOut -Fg (MkFg -Proc 'notepad' -H 9) -Reason 'hotkey'
$gj = ($script:Posts[0].Json | ConvertFrom-Json).report
Assert ($gj -match 'Ctrl\+Shift\+F' -and $gj -match 'none was in front' -and @($script:Killed).Count -eq 3) 'hotkey: closes all browsers and says it was the panic key'
Reset-Guardian; $OutputDir = $og; $script:Browsers = @()
$r = Invoke-GuardianGetOut -Fg $null -Reason 'hotkey'
Assert ($script:Posts.Count -eq 1 -and @($script:Killed).Count -eq 0 -and $r.Message -match "You're safe") 'hotkey with no browser open: still tells Trey, nothing to close'
Reset-Guardian; $OutputDir = $og; $script:KillFail = @(4243)
$r = Invoke-GuardianGetOut -Fg (MkFg)
$gj = ($script:Posts[0].Json | ConvertFrom-Json).report
Assert (@($script:Killed).Count -eq 2 -and $gj -match 'Browser programs closed: 2') 'one process that will not close does not stop the others'
Reset-Guardian; $script:PostFail = $true; $og2 = Join-Path $tmp 'gd2'; New-Item -ItemType Directory $og2 -Force | Out-Null; $OutputDir = $og2
$r = Invoke-GuardianGetOut -Fg (MkFg)
Assert (-not $r.Sent -and $r.Message -match "You're safe" -and $r.Message -match 'could not reach Trey' -and $r.Message -match 'call him') 'offline: stays calm and says to call Trey'
Assert (@(Get-ChildItem $og2 -Filter 'SCAM-Report-for-Trey-*.txt').Count -eq 1) 'offline: a copy of the report is saved'
Reset-Guardian; $OutputDir = $og
$r = Invoke-GuardianGetOut -Fg (MkFg) -Demo
Assert (@($script:Killed).Count -eq 0 -and $script:Posts.Count -eq 0 -and $r.Message -match 'Practice only') 'demo: nothing closed, nothing sent'
Reset-Guardian; $script:DryRun = $true; $OutputDir = $og
$r = Invoke-GuardianGetOut -Fg (MkFg)
Assert (@($script:Killed).Count -eq 0 -and $script:Posts.Count -eq 0) 'practice mode (-WhatIf): nothing closed, nothing sent'

Section 'Guardian: session restore'
$sr = Join-Path $tmp 'sessions'; New-Item -ItemType Directory $sr -Force | Out-Null
$prof = Join-Path $sr 'Edge\Default'; New-Item -ItemType Directory (Join-Path $prof 'Sessions') -Force | Out-Null
$prefs = Join-Path $prof 'Preferences'
[IO.File]::WriteAllText($prefs, '{"profile":{"exit_type":"Crashed","exited_cleanly":false,"name":"Person 1"},"homepage":"https://x"}')
$s1 = Join-Path $prof 'Sessions\Session_13300000001'; $s2 = Join-Path $prof 'Sessions\Tabs_13300000002'; $s3 = Join-Path $prof 'Last Session'
'tabs1' | Set-Content $s1; 'tabs2' | Set-Content $s2; 'last' | Set-Content $s3
$script:SessTargets = @(
    [pscustomobject]@{ Browser = 'Edge'; Profile = 'Default'; Path = $prefs; Action = 'prefs' },
    [pscustomobject]@{ Browser = 'Edge'; Profile = 'Default'; Path = $s1; Action = 'move' },
    [pscustomobject]@{ Browser = 'Edge'; Profile = 'Default'; Path = $s2; Action = 'move' },
    [pscustomobject]@{ Browser = 'Edge'; Profile = 'Default'; Path = $s3; Action = 'move' })
$bk = Join-Path $tmp 'gbk'
Reset-All; $script:SessTargets = $script:SessTargets
$script:DryRun = $true
$res = Clear-FixItBrowserSessions -BackupRoot $bk
Assert ((Test-Path $s1) -and -not (Test-Path $bk) -and ([IO.File]::ReadAllText($prefs) -match 'Crashed')) 'practice mode: session files untouched, no backup made'
$script:DryRun = $false
$res = Clear-FixItBrowserSessions -BackupRoot $bk
Assert ($res.Moved -eq 3 -and $res.Patched -eq 1 -and $res.Failed -eq 0) 'three session files moved, preferences marked closed normally'
Assert (-not (Test-Path $s1) -and -not (Test-Path $s2) -and -not (Test-Path $s3)) 'the old session files are gone from the profile'
$pt = [IO.File]::ReadAllText($prefs)
Assert ($pt -match '"exit_type":"Normal"' -and $pt -match '"exited_cleanly":true' -and $pt -match '"name":"Person 1"' -and $pt -match '"homepage":"https://x"') 'preferences: only the crash flags changed'
$bd = @(Get-ChildItem $bk -Directory)[0]
$edgeBk = Join-Path $bd.FullName 'Edge-Default'
Assert ((Test-Path (Join-Path $edgeBk 'Session_13300000001')) -and (Test-Path (Join-Path $edgeBk 'Last Session')) -and ([IO.File]::ReadAllText((Join-Path $edgeBk 'Preferences')) -match 'Crashed')) 'everything was backed up first (original preferences included)'
Assert ($bd.FullName -like (Join-Path $bk '*')) 'backups live in the tool folder'
foreach ($i in 1..7) { $d = Join-Path $bk ('2026010{0}-000000' -f $i); New-Item -ItemType Directory $d -Force | Out-Null }
$script:SessTargets = @()
$res = Clear-FixItBrowserSessions -BackupRoot $bk
$res2 = Clear-FixItBrowserSessions -BackupRoot $bk
Assert (@(Get-ChildItem $bk -Directory).Count -le 8) 'no targets: nothing new; old backups are not piling up unboundedly'
$script:SessTargets = @([pscustomobject]@{ Browser = 'Edge'; Profile = 'Default'; Path = (Join-Path $prof 'Last Session'); Action = 'move' })
$res3 = Clear-FixItBrowserSessions -BackupRoot $bk
Assert ($res3.Failed -eq 1 -and $res3.Moved -eq 0) 'a missing file is counted as a problem and does not throw'
Assert (@(Get-ChildItem $bk -Directory).Count -le 5) 'only the newest 5 backups are kept'
Assert ($src -match 'sessionstore-backups' -and $src -match 'Current Session' -and $src -match 'Session_') 'Firefox and Chromium session locations are covered'

Section 'Guardian: the toast flow'
$script:ToastLog = New-Object System.Collections.ArrayList
function Set-FixItGuardianToast { param($Fg = $null, [string]$Mode = 'Calm', [string]$Text = '', [string]$Status = '', [bool]$Done = $false) [void]$script:ToastLog.Add([pscustomobject]@{ Text = $Text; Status = $Status; Done = $Done; Killed = @($script:Killed).Count; Posts = $script:Posts.Count }) }
function Show-FixItGuardianToast { param($Fg = $null) Rec 'toast show' }
function Close-FixItGuardianToast { Rec 'toast close'; if ($null -ne $script:GState) { $script:GState.ToastOpen = $false } }
function Update-FixItGuardianTopMost { Rec 'topmost' }
Reset-Guardian; $OutputDir = $og; $script:ToastLog.Clear(); $script:GState = New-FixItGuardianState; $script:GDemo = $false
Start-GuardianGetOutUi -Fg (MkFg) -Reason 'button'
$tl = @($script:ToastLog)
Assert ($tl.Count -eq 3 -and $tl[0].Text -eq 'Closing the page...' -and $tl[0].Killed -eq 0) 'toast step 1: "Closing the page..." before anything is closed'
Assert ($tl[1].Killed -eq 3 -and $tl[1].Posts -eq 0 -and $tl[1].Text -match "You're safe. Don't call any number that page showed." -and $tl[1].Status -eq 'Telling Trey...') 'toast step 2: calm message as soon as the browsers are closed'
Assert ($tl[2].Done -and $tl[2].Status -eq 'Trey has been told.' -and $tl[2].Text -match "do not click 'Restore'") 'toast step 3: "Trey has been told." and the do-not-click-Restore advice'
Assert (-not $script:GBusy -and $script:GState.ToastMode -eq 'Calm') 'busy flag cleared; the toast is in calm mode'
Reset-Guardian; $script:PostFail = $true; $OutputDir = $og2; $script:ToastLog.Clear(); $script:GState = New-FixItGuardianState
Start-GuardianGetOutUi -Fg (MkFg) -Reason 'button'
Assert (@($script:ToastLog)[2].Status -match 'could not reach Trey' -and @($script:ToastLog)[2].Done) 'offline: the toast says it could not reach Trey'
Reset-Guardian; $script:ToastLog.Clear(); $script:GState = New-FixItGuardianState
Start-GuardianGetOutUi -Fg (MkFg) -Reason 'button' -Demo
Assert (@($script:Killed).Count -eq 0 -and $script:Posts.Count -eq 0 -and @($script:ToastLog)[2].Status -match 'Practice') 'demo toast: nothing closed or sent'
Reset-Guardian; $script:GBusy = $true; $script:ToastLog.Clear()
Start-GuardianGetOutUi -Fg (MkFg) -Reason 'button'
Assert ($script:ToastLog.Count -eq 0 -and @($script:Killed).Count -eq 0) 'pressed twice: the second press is ignored while working'
$script:GBusy = $false
Reset-Guardian; $script:GState = New-FixItGuardianState; $script:ToastLog.Clear(); $OutputDir = $og
function Get-FixItForeground { return $null }
Invoke-GuardianHotkey
Assert (@($script:Killed).Count -eq 3 -and $script:Posts.Count -eq 1) 'hotkey Ctrl+Shift+F does the same as the button'
$script:GState = New-FixItGuardianState; $script:GToastFg = MkFg
Invoke-GuardianFineClick
Assert ($script:GState.Dismissed.ContainsKey('1001') -and (CallsLike 'toast close') -ge 1) "I'm fine: remembers the window and closes the toast"

Section 'Guardian: the watcher loop'
$script:GuardianLooksNeeded = 2   # the loop checks below use the short setting
Reset-Guardian
$script:FgNow = $null; $script:FgThrow = $false
function Get-FixItForeground { if ($script:FgThrow) { throw 'pretend: user32 failed' }; return $script:FgNow }
$script:GState = New-FixItGuardianState; $script:GBusy = $false; $script:GLastDay = ''
$script:FgNow = MkFg
Invoke-GuardianTick
Assert ((CallsLike 'toast show') -eq 0) 'tick 1: no question yet'
Invoke-GuardianTick
Assert ((CallsLike 'toast show') -eq 1 -and $script:GState.ToastOpen) 'tick 2: the question appears once'
Invoke-GuardianTick; Invoke-GuardianTick
Assert ((CallsLike 'toast show') -eq 1 -and (CallsLike 'topmost') -ge 2) 'still full screen: not asked again, but always-on-top is re-asserted every tick'
$script:FgNow = MkFg -Proc 'notepad' -R @(50, 50, 700, 500)
Invoke-GuardianTick
Assert ((CallsLike 'toast close') -eq 1 -and -not $script:GState.ToastOpen) 'the person escaped (full screen ended): the question closes'
$script:FgThrow = $true
$threw = $false; try { Invoke-GuardianTick } catch { $threw = $true }
Assert (-not $threw) 'a failed look at the window never crashes the watcher'
$script:FgThrow = $false
$script:GBusy = $true; $script:Calls.Clear(); $script:FgNow = MkFg
Invoke-GuardianTick
Assert ((CallsLike 'toast show') -eq 0 -and (CallsLike 'topmost') -eq 1) 'while working on a get-out, the watcher does not start a second question'
$script:GBusy = $false
Reset-Guardian; $script:DryRun = $true
$r = Invoke-GuardianRun
Assert ($r.Ok -and $r.Message -match 'Practice run' -and $r.Message -match 'Ctrl \+ Shift \+ F') 'Guardian -WhatIf: only describes what it would do'
$script:DryRun = $false
$script:MutexObj = $null
function Enter-FixItGuardianMutex { return $script:MutexObj }
$r = Invoke-GuardianRun
Assert ($r.Ok -and $r.Title -eq 'Already running') 'a second copy exits quietly when one is already watching'
$script:GNativeReady = $true
$script:LoopRan = 0; $script:HkMade = 0; $script:MutexObj = [pscustomobject]@{ X = 1 }; $script:MutexReleased = 0
function Initialize-FixItGuardianNative { }
function New-FixItGuardianHotkey { $script:HkMade++; return [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $global:HkDisposed = $true } -PassThru }
function Start-FixItGuardianLoop { $script:LoopRan++ }
function Release-FixItGuardianMutex { param($Mutex) $script:MutexReleased++ }
$global:HkDisposed = $false
$r = Invoke-GuardianRun
Assert ($script:LoopRan -eq 1 -and $script:HkMade -eq 1 -and $script:MutexReleased -eq 1 -and $global:HkDisposed -and $null -ne $script:GState) 'run: hotkey registered, loop started, everything cleaned up afterwards'
Assert ((Get-Content $script:LogFile -Raw) -match 'Guardian started' -and (Get-Content $script:LogFile -Raw) -match 'Guardian stopped') 'start and stop are logged'

$script:GuardianLooksNeeded = 4
Section 'Guardian: turn on / off'
$runKey = $script:GuardianRunKey; $runName = $script:GuardianRunName
$script:GRunning = $false
function Test-FixItGuardianRunning { return $script:GRunning }
function Start-FixItGuardianProcess { Rec 'guardian start'; $script:GRunning = $true }
function Stop-FixItGuardianProcess { Rec 'guardian stop'; $script:GRunning = $false }
$script:SelfPath = 'C:\Users\tester\AppData\Local\FamilyFixIt\FamilyFixIt.ps1'
Reset-All; $script:GRunning = $false; $script:State = @{}
Add-RegPretend $runKey @{}
Assert (-not (Test-FixItGuardianInstalled)) 'starts off'
$r = Invoke-GuardianToggle -Mode 'On'
$rv = Get-RegValue $runKey $runName
Assert ($r.Ok -and $rv -match 'powershell.exe' -and $rv -match '-WindowStyle Hidden' -and $rv -match '-Action Guardian' -and $rv -match [regex]::Escape($script:SelfPath)) 'turning on writes a per-user Run entry (no admin) that starts the watcher hidden'
Assert ((CallsLike 'guardian start') -eq 1 -and $script:State['Guardian'] -eq '1') 'it also starts now, and remembers the choice'
Assert ($r.Message -match 'bottom right' -and $r.Message -match 'Ctrl \+ Shift \+ F') 'the on-message explains the box and the hotkey'
$before = RegSnapshot
$r = Invoke-GuardianToggle -Mode 'On'
Assert ((RegSnapshot) -eq $before -and (CallsLike 'guardian start') -eq 1) 'turning on again changes nothing and does not start a second watcher (safe to repeat)'
Assert ($script:Reg[$runKey].Keys.Count -eq 1) 'only one Run entry'
$script:Answers.Clear(); $script:Answers.Enqueue($false)
$r = Invoke-GuardianToggle -Mode 'Toggle'
Assert ($r.Ok -and $r.Title -eq 'Still on' -and (Test-FixItGuardianInstalled) -and $script:GRunning) 'turning off asks first; saying no keeps it on'
$script:Answers.Clear(); $script:Answers.Enqueue($true)
$r = Invoke-GuardianToggle -Mode 'Toggle'
Assert ($r.Ok -and -not (Test-FixItGuardianInstalled) -and -not $script:GRunning -and $script:State['Guardian'] -eq '0') 'turning off removes the Run entry, stops the watcher and remembers'
$r = Invoke-GuardianToggle -Mode 'Off'
Assert ($r.Ok -and $r.Title -eq 'Pop-up watcher is off') 'turning off again is fine (safe to repeat)'
Reset-All; Add-RegPretend $runKey @{}; $script:State = @{}; $script:GRunning = $false; $script:DryRun = $true
$r = Invoke-GuardianToggle -Mode 'On'
Assert ($r.Ok -and (CallsLike 'regsets*') -eq 0 -and (CallsLike 'guardian*') -eq 0 -and $script:State.Count -eq 0) 'practice mode: nothing written or started'
$script:DryRun = $false
Section 'Guardian: on by default'
Reset-All; Add-RegPretend $runKey @{}; $script:State = @{}; $script:GRunning = $false
Initialize-FixItGuardianDefault
Assert ((Test-FixItGuardianInstalled) -and $script:State['Guardian'] -eq '1' -and $script:GRunning) 'first run: switched on automatically'
$script:State = @{ Guardian = '0' }; $script:Calls.Clear(); Reset-Reg; Add-RegPretend $runKey @{}; $script:GRunning = $false
Initialize-FixItGuardianDefault
Assert (-not (Test-FixItGuardianInstalled) -and -not $script:GRunning) 'if the person turned it off, it stays off'
$script:State = @{ Guardian = '1' }
Initialize-FixItGuardianDefault
Assert ((Test-FixItGuardianInstalled) -and $script:GRunning) 'chosen on but the startup entry is missing: put back'
$script:GRunning = $false; $script:Calls.Clear()
Initialize-FixItGuardianDefault
Assert ((CallsLike 'guardian start') -eq 1 -and (CallsLike 'regsets*') -eq 0) 'chosen on and installed but not running: just started'
$script:DryRun = $true; Reset-Reg; Add-RegPretend $runKey @{}; $script:State = @{}
Initialize-FixItGuardianDefault
Assert (-not (Test-FixItGuardianInstalled)) 'practice mode: default is not applied'
$script:DryRun = $false

Section 'Guardian: window text and static checks'
Reset-Reg; Add-RegPretend $runKey @{}
Assert ((Get-FixItIdleStatus) -eq 'Click a button above.') 'status line: plain when the watcher is off'
Add-RegPretend $runKey @{ FamilyFixItGuardian = 'x' }
Assert ((Get-FixItIdleStatus) -match 'Press Ctrl \+ Shift \+ F') 'status line reminds about the hotkey when the watcher is on'
Assert ($tbl.ContainsKey('Guardian') -and $tbl['Guardian'].Fn -eq 'Invoke-GuardianToggle') 'sidebar: Watch for scary pop-ups is in the action table'
Assert ($src -match 'Watch for scary pop-ups') 'sidebar: toggle label present'
foreach ($needle in @('GetForegroundWindow', 'GetWindowRect', 'MonitorFromWindow', 'RegisterHotKey', '0x08000000', 'Are you OK\?', 'Is a website scaring you\?', 'Get me out of here', "I'm fine", 'TopMost')) { Assert ($src -match $needle) "source mentions $needle" }
Assert ($src -match 'Register\(0x4006, 0x46\)') 'hotkey is Ctrl + Shift + F'
Assert (([regex]::Matches($src, 'Stop-Process')).Count -le 4) 'Stop-Process only appears in the small adapter functions'
$probeOk = $true; try { Add-Type -TypeDefinition $script:GuardianProbeCs -ErrorAction Stop } catch { $probeOk = $false; Write-Host $_.Exception.Message }
Assert $probeOk 'the window-probe C# code compiles'
Assert ($script:GuardianProbeCs -notmatch '\?\.' -and $script:GuardianUiCs -notmatch '\$"') 'C# kept to the old C# 5 style that Windows PowerShell 5.1 accepts'

Section 'Background actions never ask a question (a real PC hung at "4 of 5" because of this)'
# Hostile setup: the console looks fully usable, and ANY typed question is counted and fails. Only the Background flag may stop a question.
$script:Prompts = 0
$stubFns = @{}
foreach ($n in @('Confirm-FixIt', 'Read-FixItPlanChoice', 'Select-FixItPrinter')) {
    $stubFns[$n] = (Get-Item ('function:' + $n)).ScriptBlock
    $realAst = $fnAsts | Where-Object { $_.Name -eq $n } | Select-Object -First 1
    Invoke-Expression $realAst.Extent.Text
}
function Read-Host { param($Prompt) $script:Prompts++; throw ('PROMPTED: ' + $Prompt) }
$script:ConsoleOk = $true; $script:GuiActive = $false
$runKey = $script:GuardianRunKey
$script:SelfPath = Join-Path $root 'FamilyFixIt.ps1'
# every action the installer runs
$instText = [IO.File]::ReadAllText((Join-Path $root 'Install-FixIt.ps1'))
$instActions = @([regex]::Matches($instText, "'(GuardianOn|GuardianOff|CheckInOn|CheckInOff|Guardian|HealthCheck|Update|Install)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
Assert ($instActions -contains 'GuardianOn' -and $instActions -contains 'CheckInOn' -and $instActions -contains 'GuardianOff') 'found the actions the installer runs (GuardianOn, GuardianOff, CheckInOn)'
foreach ($a in $instActions) { Assert ($script:BackgroundActions -contains $a) "installer action $a is a background action" }
# the scheduled task and the sign-in entry
Assert ((Get-FixItCheckInXml -ScriptPath 'C:\x\FamilyFixIt.ps1') -match '-Action (\w+)' -and $script:BackgroundActions -contains $Matches[1]) 'the weekly scheduled task runs a background action'
Assert ((Get-FixItGuardianCommand) -match '-Action (\w+)' -and $script:BackgroundActions -contains $Matches[1]) 'the sign-in watcher entry runs a background action'
# every administrator part
$partNames = @([regex]::Matches($src, "Invoke-AdminPart -Part '(\w+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
Assert ($partNames.Count -ge 10) 'found the administrator parts'
foreach ($a in $partNames) { Assert ($script:BackgroundActions -contains $a) "administrator part $a is a background action" }
# the user-facing fixes are NOT background (they keep their Proceed / Go Back window)
foreach ($k in @('Printer', 'Acrobat', 'AcrobatRepair', 'Outlook', 'Network', 'Slow', 'Sound', 'Browser', 'WinUpdate', 'OneDrive', 'Scam', 'Screen', 'Report')) { Assert ($script:BackgroundActions -notcontains $k) "$k is not a background action" }
$validSet = (($src -split "`r?`n")[14..19]) -join ' '
foreach ($a in $script:BackgroundActions) { Assert ($validSet -match "'$a'") "background action $a is a real -Action value" }
# nothing a background action runs can reach a question (checked in the code, not just by running it)
$cgFns = @{}; foreach ($f in $fnAsts) { $cgFns[$f.Name] = $f }
function Get-CallReach { param([string]$Start) $seen = @{}; $q = New-Object System.Collections.Queue; $q.Enqueue($Start); while ($q.Count -gt 0) { $n = $q.Dequeue(); if ($seen.ContainsKey($n)) { continue }; $seen[$n] = 1; if ($cgFns.ContainsKey($n)) { foreach ($c in $cgFns[$n].Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true)) { $nm = $c.GetCommandName(); if ($nm) { $q.Enqueue($nm) } } } }; return @($seen.Keys) }
$askers = @('Read-Host', 'Confirm-FixIt', 'Confirm-FixItStep', 'Confirm-FixItPlan', 'Select-FixItPrinter', 'Read-FixItPlanChoice')
foreach ($fn in @('Invoke-GuardianRun', 'Invoke-HealthCheck', 'Invoke-PrinterAdmin', 'Invoke-AcrobatAdmin', 'Invoke-AcrobatRepairAdmin', 'Invoke-NetworkAdmin', 'Invoke-SlowAdmin', 'Invoke-SoundAdmin', 'Invoke-OutlookAdmin', 'Invoke-DefenderScanAdmin', 'Invoke-WinUpdateAdmin', 'Invoke-WinUpdateDeepAdmin', 'Invoke-UndoAdmin')) {
    $hit = @(Get-CallReach $fn | Where-Object { $askers -contains $_ })
    Assert ($hit.Count -eq 0) ("$fn can never reach a question" + $(if ($hit.Count) { ': ' + ($hit -join ',') } else { '' }))
}
# the dispatcher sets the flag from the action, and passes -Yes through
Assert ((FnText 'Start-FamilyFixIt') -match '\$script:Background = \(\$script:BackgroundActions -contains \$Action\)' -and (FnText 'Start-FamilyFixIt') -match '\$script:AssumeYes = \[bool\]\$Yes') 'Start-FamilyFixIt sets Background from the action and AssumeYes from -Yes'
# run each installer/scheduled action for real through the dispatcher (the same path the hidden window takes)
$origAction = $Action
foreach ($act in @('GuardianOn', 'GuardianOn', 'GuardianOff', 'GuardianOff', 'CheckInOn', 'CheckInOn', 'CheckInOff', 'CheckInOff')) {
    Reset-All; $script:Prompts = 0; $script:State = @{}; $script:GRunning = $false
    Add-RegPretend $runKey @{}
    if ($act -eq 'GuardianOff') { [void](Invoke-GuardianToggle -Mode 'On') }
    if ($act -eq 'CheckInOff') { [void](Invoke-CheckInToggle -Mode 'On') }
    $script:Calls.Clear()
    $script:Action = $act
    $out = @(Start-FamilyFixIt 6>&1)
    $code = $out[-1]
    Assert ($script:Prompts -eq 0 -and $script:Asked.Count -eq 0) "-Action $act never asks anything"
    Assert ($code -eq 0) "-Action $act finishes with exit code 0"
    Assert ($script:Background) "-Action $act runs as background"
}
Reset-All; Add-RegPretend $runKey @{}; $script:Action = 'GuardianOn'; $null = Start-FamilyFixIt 6>&1
Assert ((Test-FixItGuardianInstalled) -and (CallsLike 'guardian start') -eq 1) 'GuardianOn through the dispatcher turns the watcher on and starts it'
Reset-All; $script:Action = 'CheckInOn'; $null = Start-FamilyFixIt 6>&1
Assert ($script:Tasks.ContainsKey('Family Fix-It Weekly Check')) 'CheckInOn through the dispatcher installs the weekly task'
# the real "Toggle" questions stay quiet in the background (even if a caller asked for Toggle)
$script:Background = $true; $script:Prompts = 0
Reset-All; Add-RegPretend $runKey @{}; [void](Invoke-GuardianToggle -Mode 'On')
$r = Invoke-GuardianToggle -Mode 'Toggle'
Assert ($script:Prompts -eq 0 -and $r.Title -eq 'Still on') 'background: a turn-off question is answered "no" without typing'
Reset-All; $r = Invoke-CheckInToggle -Mode 'Toggle'
Assert ($script:Prompts -eq 0 -and $r.Title -eq 'Not turned on') 'background: a turn-on question is answered "no" without typing'
$cf = Confirm-FixIt -Question 'x'
Assert ($script:Prompts -eq 0 -and -not $cf) 'background: Confirm-FixIt answers no and never calls Read-Host'
Assert ((Select-FixItPrinter -Names @('A', 'B')) -eq '' -and $script:Prompts -eq 0) 'background: the printer pick list never asks'
$script:Background = $false
# nobody can type (piped input or no user session): the question is skipped, not waited for
foreach ($mode in @('piped console')) {
    $script:ConsoleOk = $false; $script:Prompts = 0; $script:PlanSeen = @()
    Assert ((Confirm-FixItPlan -Which 'Printer') -eq $false -and $script:Prompts -eq 0) 'no usable console: the Proceed question is skipped and counts as Go Back (nothing is done)'
    Assert ((Confirm-FixIt -Question 'Did that fix it?') -eq $false -and $script:Prompts -eq 0) 'no usable console: a yes/no question answers no without waiting'
    $script:Calls.Clear(); $script:Action = 'Printer'; $script:Yes = $false
    $out = @(Start-FamilyFixIt 6>&1)
    Assert ($script:Prompts -eq 0 -and $script:Calls.Count -eq 0 -and (($out | Out-String) -match 'add -Yes')) '-Action Printer with no usable console and no -Yes: no question, nothing changed, says how to continue'
    $fu = Invoke-FixItFollowUp -Which 'Printer' -Result (New-FixItResult $true 'Done' 'x')
    Assert ($null -eq $fu -and $script:Posts.Count -eq 0) 'no usable console: "Did that fix it?" is not treated as a No (no report is sent)'
}
# -Yes skips only the Proceed window; it never answers other questions for the person
$script:ConsoleOk = $false; $script:AssumeYes = $true; $script:Prompts = 0
Assert ((Confirm-FixItPlan -Which 'Printer') -eq $true -and $script:Prompts -eq 0) '-Yes: the Proceed window is skipped (counts as Proceed)'
Assert ((Confirm-FixIt -Question 'Force close Outlook?') -eq $false) '-Yes does not answer other questions with yes'
$script:AssumeYes = $false
# a console someone can type at still gets the question
$script:ConsoleOk = $true; $script:Prompts = 0; $script:PlanSeen = @(); $script:HostAnswer = 'P'
function Read-Host { param($Prompt) $script:Prompts++; return $script:HostAnswer }
Assert ((Confirm-FixItPlan -Which 'Printer') -eq $true -and $script:Prompts -eq 1) 'a usable console: the person is asked, and P proceeds'
$script:HostAnswer = 'G'
Assert ((Confirm-FixItPlan -Which 'Printer') -eq $false -and $script:Prompts -eq 2) 'a usable console: G goes back'
# a real child program with its input piped (no one can type): it must not wait
$childLog = Join-Path $tmp 'noprompt.log'
$sw1 = [Diagnostics.Stopwatch]::StartNew()
$outNp = ('' | & (Get-Command pwsh).Source -NoProfile -File (Join-Path $root 'FamilyFixIt.ps1') -Action Printer -LogPath $childLog 2>&1 | Out-String)
$sw1.Stop()
Assert ($LASTEXITCODE -eq 0 -and $sw1.Elapsed.TotalSeconds -lt 30 -and $outNp -match 'add -Yes') 'a real run of -Action Printer with piped input returns at once and changes nothing'
Remove-Item function:Read-Host
foreach ($n in $stubFns.Keys) { Set-Item -Path ('function:' + $n) -Value $stubFns[$n] }
$script:Action = $origAction; $script:ConsoleOk = $true; $script:Yes = $false; $script:Background = $false

Section 'Installer: never waits for the programs an action starts'
$instAst = [Management.Automation.Language.Parser]::ParseInput($instText, [ref]$null, [ref]$null)
$iaText = @($instAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-InstalledAction' }, $true))[0].Extent.Text
$spLines = @($iaText -split "`n" | Where-Object { $_ -match 'Start-Process' })
Assert ($spLines.Count -eq 1 -and ($spLines -join '') -notmatch '-Wait' -and ($spLines -join '') -match '-PassThru') 'the installer starts the action without Start-Process -Wait (which also waits for the watcher it starts)'
Assert ($iaText -match "'-Yes'" -and $iaText -match 'WaitForExit\(' -and $iaText -match 'Kill\(\)') 'the installer passes -Yes, waits for that one program only, and stops it if it takes too long'
Assert (@([regex]::Matches($instText, '(?m)^[^#\r\n]*Start-Process[^\r\n]*-Wait')).Count -eq 0) 'no Start-Process -Wait anywhere in the installer'
# run the real function against small stand-in programs (pwsh instead of powershell.exe)
# (the -WindowStyle switches exist only on Windows, so they are dropped for this run on Linux; everything else is the real code.)
$iaRun = ($iaText -replace 'function Invoke-InstalledAction', 'function Invoke-InstalledActionReal') -replace '-WindowStyle Hidden -PassThru', '-PassThru' -replace "'-WindowStyle', 'Hidden', ", ''
Assert ($iaRun -ne $iaText -and $iaRun -match 'WaitForExit') 'prepared the real installer function for the stand-in run'
$stubStartProcess = (Get-Item function:Start-Process).ScriptBlock; Remove-Item function:Start-Process   # the real Start-Process for this part
Invoke-Expression $iaRun
function Get-InstallPowerShell { return (Get-Command pwsh).Source }
function Write-InstallLog { param([string]$Text, [string]$Level = 'INFO') $script:InstLogged += $Text }
$script:InstLogged = @()
$fakeDir = Join-Path $tmp 'fake-install'; New-Item -ItemType Directory $fakeDir | Out-Null
$argFile = Join-Path $tmp 'fake-args.txt'
$sleepPs = (Get-Command pwsh).Source
Set-Content -LiteralPath (Join-Path $fakeDir 'FamilyFixIt.ps1') -Value @"
param([string]`$Action, [switch]`$Yes)
Set-Content -LiteralPath '$($argFile.Replace("'", "''"))' -Value ('{0}|{1}' -f `$Action, [bool]`$Yes)
Start-Process -FilePath '$($sleepPs.Replace("'", "''"))' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 25') | Out-Null
exit 7
"@
$sw2 = [Diagnostics.Stopwatch]::StartNew()
$code = Invoke-InstalledActionReal -Dir $fakeDir -Action 'GuardianOn'
$sw2.Stop()
Assert ($code -eq 7) 'the real installer function returns the program''s own exit code'
Assert ($sw2.Elapsed.TotalSeconds -lt 20) 'it returns as soon as the action ends, even though the action left a long-running program behind (the watcher)'
Assert ((Get-Content -LiteralPath $argFile -Raw).Trim() -eq 'GuardianOn|True') 'the action was run with its name and -Yes'
Set-Content -LiteralPath (Join-Path $fakeDir 'FamilyFixIt.ps1') -Value "param([string]`$Action, [switch]`$Yes)`nStart-Sleep -Seconds 60"
$sw3 = [Diagnostics.Stopwatch]::StartNew()
$code = Invoke-InstalledActionReal -Dir $fakeDir -Action 'CheckInOn' -TimeoutSeconds 3
$sw3.Stop()
Assert ($code -eq 1 -and $sw3.Elapsed.TotalSeconds -lt 30 -and ($script:InstLogged -join ' ') -match 'did not finish in 3 seconds') 'an action that never ends is stopped after the time limit and counts as a failure (the installer carries on)'
Remove-Item function:Get-InstallPowerShell, function:Write-InstallLog
Set-Item -Path function:Start-Process -Value $stubStartProcess
Get-Process -Name pwsh -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'Start-Sleep -Seconds 25' } | ForEach-Object { try { $_.Kill() } catch { } }

Section 'Installer'
$instPs1 = Join-Path $root 'Install-FixIt.ps1'
$instCmd = Join-Path $root 'Install-FamilyFixIt.cmd'
$relDir = Join-Path $tmp 'release1'
& $pub -Owner 'octo-test' -OutDir (Join-Path $tmp 'dist-i1') -ReleaseDir $relDir -WarningAction SilentlyContinue | Out-Null
$distI = Join-Path $tmp 'dist-i1'
$newSrcI = Join-Path $tmp 'newsrc-i'; Copy-Item -LiteralPath $root -Destination $newSrcI -Recurse
$psI = Join-Path $newSrcI 'FamilyFixIt.ps1'
[IO.File]::WriteAllText($psI, ([IO.File]::ReadAllText($psI).Replace("FixItVersion = '2.3.15'", "FixItVersion = '2.3.16'")))
$distI2 = Join-Path $tmp 'dist-i2'
& (Join-Path $newSrcI 'tools/Publish-FixIt.ps1') -SourceDir $newSrcI -Owner 'octo-test' -OutDir $distI2 -ReleaseDir (Join-Path $tmp 'release2') -WarningAction SilentlyContinue | Out-Null

# static checks on the release and the files
$zipDir = Join-Path $tmp 'zipcheck'; New-Item -ItemType Directory $zipDir | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $relDir 'Install-FamilyFixIt.zip'), $zipDir)
$zn = @(Get-ChildItem $zipDir -File | ForEach-Object { $_.Name } | Sort-Object)
Assert (($zn -join ',') -eq 'Install-FamilyFixIt.cmd,Install-FixIt.ps1') 'release zip holds exactly the .cmd and the .ps1'
Assert ((Get-FileSha256 (Join-Path $zipDir 'Install-FixIt.ps1')) -eq (Get-FileSha256 (Join-Path $distI 'Install-FixIt.ps1'))) 'the zip carries the same installer script that is published'
Assert (([IO.File]::ReadAllText((Join-Path $zipDir 'Install-FamilyFixIt.cmd'))) -match 'raw\.githubusercontent\.com/octo-test/family-it-fixit/main/Install-FixIt\.ps1' -and -not ([IO.File]::ReadAllText((Join-Path $zipDir 'Install-FixIt.ps1')) -match '<OWNER>')) 'owner name filled into the installer and the wrapper'
foreach ($f in @($instPs1, $instCmd)) {
    $bytes = [IO.File]::ReadAllBytes($f)
    Assert (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) ("plain ASCII only: $(Split-Path -Leaf $f)")
    $txt = [IO.File]::ReadAllText($f)
    Assert (([regex]::Matches($txt, "`r`n")).Count -eq ([regex]::Matches($txt, "`n")).Count) ("Windows line endings: $(Split-Path -Leaf $f)")
}
$it = [IO.File]::ReadAllText($instPs1)
Assert ($it -notmatch '(?i)RunAs|HKLM|Register-ScheduledTask|schtasks|Set-ExecutionPolicy|Add-MpPreference|\s\?\?\s|&&|\|\|') 'installer: no admin, no machine-wide changes, no PowerShell 7-only operators'
Assert ($it -match 'Set-StrictMode -Version 2\.0' -and $it -match 'Tls12') 'installer: strict mode and TLS 1.2'
$ct = [IO.File]::ReadAllText($instCmd)
Assert ($ct -match '-ExecutionPolicy Bypass' -and $ct -match 'goto web' -and $ct -notmatch '(?m)^\s*\(' -and $ct -notmatch '(?im)runas') 'wrapper: no bracket blocks (safe in folders like "Mom (Work)"), no admin'
$rd = [IO.File]::ReadAllText((Join-Path $root 'README.md'))
Assert ($rd -match 'releases/latest/download/Install-FamilyFixIt\.zip' -and $rd -match 'irm https://raw\.githubusercontent\.com/(<OWNER>|[A-Za-z0-9-]+)/family-it-fixit/main/Install-FixIt\.ps1 \| iex' -and $rd -match 'More info' -and $rd -match 'Run anyway') 'README: latest-download link, the one-line install, and the SmartScreen steps'

# run the installer functions with pretend Windows and network
& {
    . $instPs1 -LibraryOnly
    $script:I = @{ Web = @{}; WebFail = $false; Saves = New-Object System.Collections.ArrayList; Lnk = @{}; LnkWrites = 0; Actions = New-Object System.Collections.ArrayList; Launched = 0; Code = @{}; Win = $true; Elev = $false; Tamper = @{}; Texts = 0 }
    $script:InstallLog = Join-Path $tmp 'install-test.log'
    $iroot = Join-Path $tmp 'inst-root'
    $desk = Join-Path $tmp 'inst-desk'; $prog = Join-Path $tmp 'inst-start'
    New-Item -ItemType Directory $desk, $prog -Force | Out-Null
    function Test-InstallWindows { return $script:I.Win }
    function Test-InstallElevated { return $script:I.Elev }
    function Get-InstallDefaultDir { return (Join-Path $iroot 'FamilyFixIt') }
    function Get-InstallFolderPath { param([string]$Which) if ($Which -eq 'Desktop') { return $desk }; return $prog }
    function Get-InstallPowerShell { return 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
    function Get-InstallText { param([string]$Url) $script:I.Texts++; if ($script:I.WebFail) { throw 'pretend: offline' }; if (-not $script:I.Web.ContainsKey($Url)) { throw 'pretend: 404' }; return [IO.File]::ReadAllText($script:I.Web[$Url]) }
    function Save-InstallFile { param([string]$Url, [string]$Dest) [void]$script:I.Saves.Add($Url); if ($script:I.WebFail) { throw 'pretend: offline' }; if (-not $script:I.Web.ContainsKey($Url)) { throw 'pretend: 404' }; Copy-Item -LiteralPath $script:I.Web[$Url] -Destination $Dest; foreach ($k in @($script:I.Tamper.Keys)) { if ($Url -like "*$k") { Add-Content -LiteralPath $Dest -Value 'evil' } } }
    function Get-InstallShortcut { param([string]$Path) if ($script:I.Lnk.ContainsKey($Path)) { return $script:I.Lnk[$Path] } return $null }
    function New-InstallShortcut { param([string]$Path, [string]$Target, [string]$Arguments, [string]$WorkDir, [string]$Icon, [string]$Description) $script:I.LnkWrites++; $script:I.Lnk[$Path] = [pscustomobject]@{ Target = $Target; Arguments = $Arguments; WorkDir = $WorkDir; Icon = $Icon } }
    function Invoke-InstalledAction { param([string]$Dir, [string]$Action) [void]$script:I.Actions.Add($Action); if ($script:I.Code.ContainsKey($Action)) { return [int]$script:I.Code[$Action] }; return 0 }
    function Start-InstalledTool { param([string]$Dir) $script:I.Launched++ }
    $base = 'https://raw.githubusercontent.com/octo-test/family-it-fixit/main'
    function Serve { param([string]$D) $script:I.Web = @{}; $script:I.Web[$base + '/manifest.json'] = (Join-Path $D 'manifest.json'); foreach ($f in @('FamilyFixIt.ps1', 'Start-FixIt.cmd', 'README.md', 'guides.json', 'FamilyFixIt.ico')) { $script:I.Web[$base + '/' + $f] = (Join-Path $D $f) } }
    function Clear-I { $script:I.Saves.Clear(); $script:I.Actions.Clear(); $script:I.Launched = 0; $script:I.LnkWrites = 0; $script:I.Texts = 0; $script:I.Code = @{}; $script:I.Tamper = @{}; $script:I.WebFail = $false; $script:I.Win = $true; $script:I.Elev = $false; $script:InstallDry = $false }
    function Reset-Inst { if (Test-Path $iroot) { Remove-Item $iroot -Recurse -Force }; Get-ChildItem $desk, $prog -File | Remove-Item -Force; $script:I.Lnk = @{}; Clear-I }
    $dir = Join-Path $iroot 'FamilyFixIt'
    function Say { param([string]$Text, [string]$Color = '') [void]$script:Said.Add($Text) }
    $script:Said = New-Object System.Collections.ArrayList

    Reset-Inst; Serve $distI
    $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert ($r.Ok -and $r.Title -eq 'Installed' -and $r.Version -eq '2.3.15' -and $r.Changed) 'fresh install works'
    $same = $true; foreach ($f in @('FamilyFixIt.ps1', 'Start-FixIt.cmd', 'README.md')) { if ((Get-FileSha256 (Join-Path $dir $f)) -ne (Get-FileSha256 (Join-Path $distI $f))) { $same = $false } }
    Assert $same 'the three files are installed and match the published fingerprints'
    Assert (-not (Test-Path (Join-Path $dir '.staging')) -and -not (Test-Path (Join-Path $dir 'previous'))) 'no leftover staging folder; nothing to keep from a previous version'
    $dl = Join-Path $desk 'Family Fix-It.lnk'; $sm = Join-Path $prog 'Family Fix-It.lnk'
    Assert ($script:I.Lnk.ContainsKey($dl) -and $script:I.Lnk.ContainsKey($sm)) 'shortcut "Family Fix-It" on the Desktop and in the Start menu'
    Assert ($script:I.Lnk[$dl].Target -match 'powershell\.exe$' -and $script:I.Lnk[$dl].Arguments -match '-WindowStyle Hidden' -and $script:I.Lnk[$dl].Arguments -match [regex]::Escape((Join-Path $dir 'FamilyFixIt.ps1')) -and $script:I.Lnk[$dl].WorkDir -eq $dir) 'shortcut opens the installed tool with no console window'
    Assert (($script:I.Actions -join ',') -eq 'GuardianOn,CheckInOn,FirstRunPending') 'turns on the Guardian and the weekly check-in (and does not restart anything on a fresh install), then leaves the first-run note (the "What''s shared" window shows on the first normal start)'
    Assert ($script:I.Launched -eq 1) 'launches the tool once'
    Assert ($r.Message -match 'Ctrl \+ Shift \+ F' -and $r.Message -match 'All done') 'friendly finish message mentions the panic key'
    Assert ((Get-Content $script:InstallLog -Raw) -match 'Installed FamilyFixIt\.ps1') 'install is logged'
    $icoPath = Join-Path $dir 'FamilyFixIt.ico'
    Assert ((Test-Path $icoPath) -and (Get-FileSha256 $icoPath) -eq (Get-FileSha256 (Join-Path $distI 'FamilyFixIt.ico'))) 'the program icon is installed and matches its published SHA-256'
    Assert ($script:I.Lnk[$dl].Icon -eq ($icoPath + ',0') -and $script:I.Lnk[$sm].Icon -eq ($icoPath + ',0')) 'Desktop and Start menu shortcuts use the program icon (not the old built-in one)'

    $tl = Join-Path $prog 'Family Fix-It (Test mode).lnk'
    Assert ($script:I.Lnk.ContainsKey($tl)) 'a separate "Family Fix-It (Test mode)" shortcut is made in the Start menu'
    Assert ($script:I.Lnk[$tl].Arguments -match '-File "[^"]*FamilyFixIt\.ps1" -Test$' -and $script:I.Lnk[$tl].Target -eq $script:I.Lnk[$sm].Target) 'the Test mode shortcut runs the same program with -Test'
    Assert ($script:I.Lnk[$tl].Icon -eq ($icoPath + ',0')) 'the Test mode shortcut has the program icon'
    Assert (-not $script:I.Lnk.ContainsKey((Join-Path $desk 'Family Fix-It (Test mode).lnk'))) 'the Test mode shortcut is not put on the Desktop'
    Assert ($script:I.Lnk[$sm].Arguments -notmatch ' -Test$' -and $script:I.Lnk[$dl].Arguments -notmatch ' -Test$') 'the normal shortcuts do not start Test mode'

    Clear-I; $before = (Get-FileSha256 (Join-Path $dir 'FamilyFixIt.ps1'))
    $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert ($r.Ok -and -not $r.Changed -and $script:I.Saves.Count -eq 0) 're-run with nothing wrong: nothing downloaded, nothing changed'
    Assert ($script:I.LnkWrites -eq 0 -and ($script:I.Actions -join ',') -eq 'GuardianOn,CheckInOn') 're-run: shortcuts left alone; the switches are checked / turned on again'

    # "Thank Trey" is always shown: the installer has nothing to switch for it
    $instText = [IO.File]::ReadAllText($instPs1)
    Assert ($instText -notmatch 'ShowDonate|DonateOn|DonateOff|Donate') 'the installer has no switch or action for the Thank Trey item (it is always shown)'

    # existing shortcuts that still carry the old built-in icon are refreshed (and only those); the same icon in another letter case is already right
    Clear-I; $script:I.Lnk[$dl].Icon = 'shell32.dll,22'; $script:I.Lnk[$sm].Icon = ($icoPath.ToUpperInvariant() + ',0')
    $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert ($r.Ok -and $script:I.Saves.Count -eq 0 -and $script:I.LnkWrites -eq 1 -and $script:I.Lnk[$dl].Icon -eq ($icoPath + ',0')) 'old shortcut icon is replaced on re-run; a shortcut that already has it is not rewritten'
    Clear-I; $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert ($script:I.LnkWrites -eq 0) 'icon refresh is idempotent: a third run writes no shortcut'
    # a damaged or missing icon file is repaired like any other file
    Clear-I; Set-Content $icoPath 'not an icon'
    $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert ($r.Ok -and @($script:I.Saves | Where-Object { $_ -like '*FamilyFixIt.ico' }).Count -eq 1 -and (Get-FileSha256 $icoPath) -eq (Get-FileSha256 (Join-Path $distI 'FamilyFixIt.ico'))) 'a damaged icon file is re-downloaded'
    Clear-I; Remove-Item $icoPath
    $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert ($r.Ok -and (Test-Path $icoPath)) 'a missing icon file is put back'
    # without a usable icon file the shortcut falls back to the old built-in icon instead of a blank one
    Assert ((Get-InstallIconLocation -Dir (Join-Path $iroot 'nowhere')) -eq 'shell32.dll,22') 'no icon file: the old built-in icon is used'
    $junkDir = Join-Path $tmp 'junk-ico'; New-Item -ItemType Directory $junkDir -Force | Out-Null; Set-Content (Join-Path $junkDir 'FamilyFixIt.ico') ('x' * 100)
    Assert ((Get-InstallIconLocation -Dir $junkDir) -eq 'shell32.dll,22') 'a file that is not an icon is never used for the shortcut'
    Assert ((Get-InstallIconLocation -Dir $dir) -eq ($icoPath + ',0')) 'a real icon file is used (picture 0)'

    Clear-I; Set-Content (Join-Path $dir 'Start-FixIt.cmd') 'broken'; Remove-Item (Join-Path $dir 'README.md')
    $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert ($r.Ok -and $r.Changed -and $script:I.Saves.Count -eq 2 -and (Get-FileSha256 (Join-Path $dir 'Start-FixIt.cmd')) -eq (Get-FileSha256 (Join-Path $distI 'Start-FixIt.cmd')) -and (Test-Path (Join-Path $dir 'README.md'))) 're-run repairs only the damaged or missing files'
    Assert ((Get-Content (Join-Path $dir 'previous/Start-FixIt.cmd') -Raw) -match 'broken') 'the replaced copy is kept in previous/'
    Assert ($script:I.Actions -notcontains 'GuardianOff') 'repairing a non-program file does not restart the watcher'

    Clear-I; Serve $distI2; $script:I.Lnk.Remove($dl)
    $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert ($r.Ok -and $r.Version -eq '2.3.16' -and (Get-InstalledVersion $dir) -eq '2.3.16') 'a newer version in the list updates the install'
    Assert (($script:I.Actions -join ',') -eq 'GuardianOff,GuardianOn,CheckInOn') 'update restarts the watcher so it runs the new program'
    Assert ($script:I.LnkWrites -eq 1 -and $script:I.Lnk.ContainsKey($dl)) 'a missing shortcut is put back'
    Assert ((Get-InstalledVersion (Join-Path $dir 'previous')) -eq '2.3.15') 'the old program is kept in previous/'

    # a download that does not match the fingerprint
    Reset-Inst; Serve $distI; $script:I.Tamper['/FamilyFixIt.ps1'] = $true
    $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert (-not $r.Ok -and $r.Message -match 'safety check' -and $r.Message -match 'NOTHING was installed') 'tampered download: refused with a plain message'
    Assert (-not (Test-Path (Join-Path $dir 'FamilyFixIt.ps1')) -and -not (Test-Path (Join-Path $dir '.staging')) -and $script:I.Lnk.Count -eq 0 -and $script:I.Actions.Count -eq 0 -and $script:I.Launched -eq 0) 'tampered download: no file, no shortcut, nothing run'
    Assert ((Get-Content $script:InstallLog -Raw) -match 'CHECKSUM MISMATCH') 'tampered download: logged'
    Reset-Inst; Serve $distI; $null = Install-FamilyFixIt -Base $base -Dir $dir; Clear-I; Serve $distI2; $script:I.Tamper['/FamilyFixIt.ps1'] = $true
    $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert (-not $r.Ok -and (Get-InstalledVersion $dir) -eq '2.3.15') 'tampered update: the working old copy is left exactly as it was'

    # network problems
    Reset-Inst; Serve $distI; $script:I.WebFail = $true
    $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert (-not $r.Ok -and $r.Message -match 'internet' -and -not (Test-Path $dir)) 'offline: friendly message, nothing created'
    Reset-Inst; $script:I.Web = @{}
    $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert (-not $r.Ok -and $r.Message -match 'internet') 'download page not found: friendly message'
    Reset-Inst; Serve $distI; $script:I.Web[$base + '/FamilyFixIt.ps1'] = (Join-Path $tmp 'does-not-exist.ps1')
    $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert (-not $r.Ok -and $r.Message -match 'could not be downloaded' -and -not (Test-Path (Join-Path $dir 'FamilyFixIt.ps1'))) 'one file missing on the server: nothing installed'

    # a bad or hostile list
    function Test-BadList { param([scriptblock]$Edit, [string]$Why, [string]$Pattern = 'download list')
        Reset-Inst; $m = Get-Content (Join-Path $distI 'manifest.json') -Raw | ConvertFrom-Json; & $Edit $m
        $f = Join-Path $tmp ('bad-manifest-' + [guid]::NewGuid().ToString('N') + '.json'); ($m | ConvertTo-Json -Depth 5) | Set-Content $f
        Serve $distI; $script:I.Web[$base + '/manifest.json'] = $f
        $r = Install-FamilyFixIt -Base $base -Dir $dir
        Assert (-not $r.Ok -and $r.Message -match $Pattern -and -not (Test-Path (Join-Path $dir 'FamilyFixIt.ps1'))) "bad list refused: $Why" }
    Test-BadList { param($m) $m.name = 'something-else' } 'wrong product name'
    Test-BadList { param($m) $m.version = 'latest' } 'no real version number'
    Test-BadList { param($m) $m.files[0].sha256 = 'abc' } 'bad fingerprint'
    Test-BadList { param($m) $m.files = @($m.files | Where-Object { $_.path -ne 'Start-FixIt.cmd' }) } 'required file missing'
    Test-BadList { param($m) $m.files[0].size = 999999999 } 'absurd size'
    Test-BadList { param($m) $m.assets[0].sha256 = 'abc' } 'bad icon fingerprint'
    Test-BadList { param($m) $m.assets[0].size = 999999999 } 'absurd icon size'
    # a list without the icon (an older list) still installs, with the old built-in icon
    Reset-Inst; $m = Get-Content (Join-Path $distI 'manifest.json') -Raw | ConvertFrom-Json; $m.PSObject.Properties.Remove('assets')
    $f = Join-Path $tmp 'noassets-manifest.json'; ($m | ConvertTo-Json -Depth 5) | Set-Content $f; Serve $distI; $script:I.Web[$base + '/manifest.json'] = $f
    $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert ($r.Ok -and -not (Test-Path (Join-Path $dir 'FamilyFixIt.ico')) -and $script:I.Lnk[$dl].Icon -eq 'shell32.dll,22') 'a download list without the icon still installs (old built-in icon)'
    # a tampered icon download is refused and nothing is installed
    Reset-Inst; Serve $distI; $script:I.Tamper['/FamilyFixIt.ico'] = $true
    $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert (-not $r.Ok -and $r.Message -match 'safety check' -and -not (Test-Path (Join-Path $dir 'FamilyFixIt.ps1')) -and $script:I.Lnk.Count -eq 0) 'a tampered icon download: refused, nothing installed, no shortcut'
    Reset-Inst; $m = Get-Content (Join-Path $distI 'manifest.json') -Raw | ConvertFrom-Json
    $m.files = @($m.files) + [pscustomobject]@{ path = '..\evil.ps1'; sha256 = ('a' * 64); size = 10 } + [pscustomobject]@{ path = 'sub/other.txt'; sha256 = ('b' * 64); size = 10 }
    $f = Join-Path $tmp 'evil-manifest.json'; ($m | ConvertTo-Json -Depth 5) | Set-Content $f; Serve $distI; $script:I.Web[$base + '/manifest.json'] = $f
    $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert ($r.Ok -and @($script:I.Saves | Where-Object { $_ -match 'evil|sub/' }).Count -eq 0 -and -not (Test-Path (Join-Path $iroot 'evil.ps1'))) 'a path outside the allowed files is ignored, never downloaded'
    Reset-Inst; $m = Get-Content (Join-Path $distI 'manifest.json') -Raw | ConvertFrom-Json
    $m.assets = @($m.assets) + [pscustomobject]@{ path = '..\evil.ico'; sha256 = ('a' * 64); size = 10 } + [pscustomobject]@{ path = 'evil.exe'; sha256 = ('b' * 64); size = 10 }
    $f = Join-Path $tmp 'evil-assets-manifest.json'; ($m | ConvertTo-Json -Depth 5) | Set-Content $f; Serve $distI; $script:I.Web[$base + '/manifest.json'] = $f
    $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert ($r.Ok -and @($script:I.Saves | Where-Object { $_ -match 'evil' }).Count -eq 0) 'a bad name under assets is ignored, never downloaded'

    # other refusals
    Reset-Inst; Serve $distI
    $r = Install-FamilyFixIt -Base 'https://raw.githubusercontent.com/<OWNER>/family-it-fixit/main' -Dir $dir
    Assert (-not $r.Ok -and $r.Title -eq 'Not set up yet' -and $script:I.Texts -eq 0) 'placeholder address: refuses before any network call'
    $r = Install-FamilyFixIt -Base 'http://example.test/x' -Dir $dir
    Assert (-not $r.Ok -and $script:I.Texts -eq 0) 'plain http address refused'
    $script:I.Win = $false
    $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert (-not $r.Ok -and $r.Message -match 'Windows' -and $script:I.Texts -eq 0) 'not Windows: refuses'
    Clear-I

    # practice run
    $script:InstallDry = $true
    $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert ($r.Ok -and $r.Title -eq 'Practice run' -and -not (Test-Path $dir) -and $script:I.Saves.Count -eq 0 -and $script:I.Lnk.Count -eq 0 -and $script:I.Actions.Count -eq 0 -and $script:I.Launched -eq 0) '-WhatIf: only reads the list; nothing downloaded, written, made or run'
    Clear-I

    # switches that fail do not undo the install
    Reset-Inst; Serve $distI; $script:I.Code['GuardianOn'] = 1
    $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert ($r.Ok -and (Test-Path (Join-Path $dir 'FamilyFixIt.ps1')) -and $script:I.Launched -eq 1 -and (@($script:Said | Where-Object { $_ -match 'could not turn on the pop-up watcher' }).Count -eq 1)) 'if the watcher cannot be switched on, the install still finishes and says how to fix it'
    Reset-Inst; Serve $distI
    $r = Install-FamilyFixIt -Base $base -Dir $dir -Launch $false
    Assert ($r.Ok -and $script:I.Launched -eq 0) '-NoLaunch: does not open the tool'
    Reset-Inst; Serve $distI; $script:I.Elev = $true; $script:Said.Clear()
    $r = Install-FamilyFixIt -Base $base -Dir $dir
    Assert ($r.Ok -and (@($script:Said | Where-Object { $_ -match 'administrator' }).Count -eq 1)) 'running as administrator: works, with a gentle note'
}

# the real script as a separate process (and the one-line version)
if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
    $pw = (Get-Process -Id $PID).Path
    $out = & $pw -NoProfile -File $instPs1 -BaseUrl 'https://raw.githubusercontent.com/octo-test/family-it-fixit/main' -LogPath (Join-Path $tmp 'real-run.log') 2>&1 | Out-String
    Assert ($LASTEXITCODE -eq 1 -and $out -match 'only works on Windows' -and $out -match 'Sorry') 'run as a file: friendly message and exit code 1 when it cannot install'
    $out2 = & $pw -NoProfile -Command "`$env:LOCALAPPDATA = '$tmp'; Get-Content -LiteralPath '$instPs1' -Raw | Invoke-Expression; exit `$global:FixItInstallExitCode" 2>&1 | Out-String
    Assert ($LASTEXITCODE -eq 1 -and $out2 -match 'only works on Windows') 'run as "irm | iex" text: works (no param/exit problems) and reports failure the same way'
}

Assert ($src -match '''GuardianOn''\s+\{ \$r = .*-not \$r\.Ok\) \{ \$exit = 1 \}' -and $src -match '''CheckInOn''\s+\{ \$r = .*-not \$r\.Ok\) \{ \$exit = 1 \}') 'command-line switch actions exit with code 1 when they fail (the installer relies on this)'

Section 'My PC info and the PC code'
$script:TestGuid = '1B2C3D4E-0000-4000-8000-ABCDEF012345'
function Get-FixItMachineGuid { return $script:TestGuid }
$script:Clip = ''
$script:ClipOk = $true
function Set-FixItClipboard { param([string]$Text) $script:Clip = $Text; return $script:ClipOk }
$env:COMPUTERNAME = 'TESTPC'
$c1 = Get-FixItPcCode -ComputerName 'TESTPC' -MachineGuid $script:TestGuid
Assert ($c1 -match '^[ACDEFGHJKMNPRTWXY34679]{6}$') 'PC code is 6 characters from the read-aloud alphabet'
Assert ($c1 -eq (Get-FixItPcCode -ComputerName 'TESTPC' -MachineGuid $script:TestGuid)) 'PC code is the same every time'
Assert ($c1 -eq (Get-FixItPcCode -ComputerName ' testpc ' -MachineGuid $script:TestGuid.ToLowerInvariant())) 'PC code ignores capital letters and stray spaces'
Assert ($c1 -ne (Get-FixItPcCode -ComputerName 'OTHERPC' -MachineGuid $script:TestGuid)) 'a different PC name gives a different code'
Assert ($c1 -ne (Get-FixItPcCode -ComputerName 'TESTPC' -MachineGuid '9F8E7D6C-0000-4000-8000-ABCDEF012345')) 'a different MachineGuid gives a different code'
foreach ($bad in @('B', '8', 'S', '5', 'O', '0', 'I', '1', 'L', 'Z', '2', 'Q', 'V', 'U')) { Assert ($script:PcCodeAlphabet -notmatch $bad) "alphabet has no look-alike letter $bad" }
$seenCodes = @{}; 1..200 | ForEach-Object { $seenCodes[(Get-FixItPcCode -ComputerName ('PC' + $_) -MachineGuid ([guid]::NewGuid().ToString()))] = 1 }
Assert ($seenCodes.Count -ge 195) 'codes are well spread (200 PCs, almost no clashes)'
Assert ((Format-FixItPcCode 'ACDEFG') -eq 'ACD-EFG') 'code is shown as ABC-DEF'
# the documented recipe, worked out by hand with .NET
$sha = [Security.Cryptography.SHA256]::Create(); $hb = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('TESTPC|1b2c3d4e-0000-4000-8000-abcdef012345')); $sha.Dispose()
$hand = ''; 0..5 | ForEach-Object { $hand += 'ACDEFGHJKMNPRTWXY34679'[$hb[$_] % 22] }
Assert ($hand -eq $c1) 'code matches the recipe in the README (SHA-256, first 6 bytes, mod 22)'
Assert ((Get-FixItMyPcCode) -eq (Format-FixItPcCode $c1)) 'my code uses this PC name and MachineGuid'
$script:TestGuid = ''
Assert ((Get-FixItMyPcCode) -match '^[A-Z0-9]{3}-[A-Z0-9]{3}$') 'no MachineGuid readable: still gives a code (name only)'
$script:TestGuid = '1B2C3D4E-0000-4000-8000-ABCDEF012345'
Assert ((Get-FixItPcCodeLine) -eq ('PC code: ' + (Format-FixItPcCode $c1))) 'report line reads "PC code: ABC-DEF"'

Reset-All
$r = Invoke-PcInfo
Assert ($r.Ok -and $r.PcInfo -and $r.PcCode -eq (Format-FixItPcCode $c1)) 'My PC info: result carries the code and the card flag'
$txt = $r.CopyText
Assert ($txt -match 'PC name: TESTPC' -and $txt -match 'Windows 11 Pro' -and $txt -match ('Family Fix-It version: ' + [regex]::Escape($script:FixItVersion)) -and $txt -match ('PC code: ' + $r.PcCode)) 'My PC info: copy text has name, Windows, tool version and code'
Assert (($r.Details -join "`n") -match 'TESTPC' -and ($r.Details -join "`n") -match 'Windows 11') 'My PC info: detail lines show name and Windows'
Assert ($r.Message -match [regex]::Escape($r.PcCode)) 'My PC info: message shows the code'
Assert ((Copy-FixItPcInfo -Text $txt) -and $script:Clip -eq $txt) 'copy button puts the text on the clipboard'
$script:ClipOk = $false; Assert (-not (Copy-FixItPcInfo -Text $txt)) 'copy button: clipboard trouble is reported, not a crash'; $script:ClipOk = $true
$rep = Get-FixItReportText -Kind 'report' -Note 'hi'
Assert ($rep -match ('PC code: ' + [regex]::Escape((Format-FixItPcCode $c1)))) 'every report carries the PC code'
$rep2 = Get-FixItReportText -Kind 'scam'
Assert ($rep2 -match ('PC code: ' + [regex]::Escape((Format-FixItPcCode $c1)))) 'the scam report carries the PC code'

Section 'What''s shared: every listed item is really in the report, and the name line'
Assert ($rep -match '(?m)^PC code: [^\r\n]+\r?\nName: not given\r?$' -and $rep2 -match '(?m)^Name: not given\r?$') 'no name given: reports read "Name: not given" right under the PC code'
Set-FixItSetting -Name 'OwnerName' -Value 'Grandma Sue'
$repN = Get-FixItReportText -Kind 'report'; $scamN = Get-FixItReportText -Kind 'scam'
Assert ($repN -match '(?m)^Name: Grandma Sue\r?$' -and $scamN -match '(?m)^Name: Grandma Sue\r?$') 'a saved name shows as "Name: Grandma Sue" in the help report and the scary pop-up alert'
Assert ($repN.IndexOf('Name: Grandma Sue') -lt $repN.IndexOf('Computer name:')) 'the name is above the computer details'
Reset-All; Set-FixItSetting -Name 'OwnerName' -Value 'Grandma Sue'
$null = Invoke-HealthCheck
$hN = $script:Posts[0].Json | ConvertFrom-Json
Assert ($hN.report -match '(?m)^Name: Grandma Sue\r?$' -and $hN.report.IndexOf('Name: ') -lt $hN.report.IndexOf('ATTENTION:')) 'the weekly check-in shows the name above the attention list'
$built = @{ report = $repN; scam = $scamN; weekly = [string]$hN.report }
foreach ($item in @($script:PrivacySent)) {
    if ($item.Builder -eq 'alert') { continue }
    foreach ($mk in @($item.Markers)) {
        if ($mk -match '^(--- |Serial number|HARDWARE SUMMARY)') { continue }   # need the hardware readers: checked in Test-FixIt-V237.ps1
        Assert ($built[$item.Builder] -match $mk) ("the window says '" + $item.Text.Substring(0, [Math]::Min(48, $item.Text.Length)) + "...' and the " + $item.Builder + " really has: " + $mk)
    }
}
foreach ($nv in @($script:PrivacyNever)) {
    foreach ($fb in @($nv.Forbidden)) { foreach ($k in @('report', 'scam', 'weekly')) { Assert ($built[$k] -notmatch $fb) ("never sent: '" + $nv.Text.Substring(0, [Math]::Min(30, $nv.Text.Length)) + "' - the " + $k + " has nothing matching " + $fb) } }
}
Assert ($built['report'] -notmatch 'Remote-control programs running' -and $built['scam'] -match 'Remote-control programs running') 'the scary pop-up extras are in the scam alert only (and the window says so)'
Set-FixItSetting -Name 'OwnerName' -Value ''
Reset-All
Assert ((Get-FixItActionTable).Contains('PCInfo') -and -not (Get-FixItActionTable)['PCInfo'].Fix) 'PCInfo is a read-only action'
$script:DryRun = $true; $dr = Invoke-PcInfo; $script:DryRun = $false
Assert ($dr.Ok) 'My PC info works in a practice run'

Section 'Help guides: loading and checking'
$gj = [IO.File]::ReadAllText((Join-Path $root 'guides.json'))
$gBytes = [IO.File]::ReadAllBytes((Join-Path $root 'guides.json'))
Assert (@($gBytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'guides.json is plain ASCII'
$starter = @(ConvertTo-FixItGuides ($gj | ConvertFrom-Json))
Assert ($starter.Count -eq 11) 'guides.json: 11 starter guides, all valid'
foreach ($id in @('print', 'scan', 'attach-photo', 'screenshot', 'wifi', 'video-call', 'teams-call', 'save-photo', 'bigger-text', 'find-download', 'spot-scam')) { Assert (@($starter | Where-Object { $_.Id -eq $id }).Count -eq 1) "starter guide: $id" }
foreach ($g in $starter) { Assert (@($g.Keywords).Count -ge 5) ("guide has search words: " + $g.Id); Assert (@($g.Steps).Count -ge 3 -and @($g.Steps).Count -le 15) ("guide has a sensible number of steps: " + $g.Id) }
Assert (-not ($gj -match '(?i)@[a-z0-9-]+\.(com|net|org)|https?://')) 'guides.json holds no email addresses or web links'
$bad = @(
    @{ id = 'Bad Id'; title = 'x'; steps = @('a') },
    @{ id = 'ok1'; title = ''; steps = @('a') },
    @{ id = 'ok2'; title = 'No steps'; steps = @() },
    @{ id = 'ok3'; title = 'Good'; steps = @('one'); keywords = 'alpha, beta ,, gamma' },
    @{ id = 'ok3'; title = 'Repeated id'; steps = @('one') },
    @{ id = 'ok4'; title = ('T' * 200); steps = @(('S' * 900), "line`r`none") },
    @{ id = '../etc'; title = 'path'; steps = @('a') })
$vg = @(ConvertTo-FixItGuides ([pscustomobject]@{ guides = ($bad | ForEach-Object { [pscustomobject]$_ }) }))
Assert (($vg | ForEach-Object { $_.Id }) -join ',' -eq 'ok3,ok4') 'bad ids, empty titles, no steps and repeated ids are skipped'
Assert (($vg[0].Keywords -join '|') -eq 'alpha|beta|gamma') 'keywords given as one comma-separated string are split and tidied'
Assert ($vg[1].Title.Length -le 60 -and $vg[1].Steps[0].Length -le 300 -and ($vg[1].Steps -join '') -notmatch "[\r\n]") 'long titles and steps are cut; line breaks are removed'
$many = 1..30 | ForEach-Object { [pscustomobject]@{ id = "g$_"; title = "Guide $_"; steps = @('a') } }
Assert (@(ConvertTo-FixItGuides ([pscustomobject]@{ guides = $many })).Count -eq 20) 'at most 20 guides are used'
$kw = [pscustomobject]@{ id = 'kk'; title = 'K'; steps = @('a'); keywords = @(1..60 | ForEach-Object { 'w' + $_ }) }
Assert (@((ConvertTo-FixItGuides @($kw))[0].Keywords).Count -eq 40) 'at most 40 search words per guide'
Assert (@(ConvertTo-FixItGuides $null).Count -eq 0 -and @(ConvertTo-FixItGuides ([pscustomobject]@{ guides = @() })).Count -eq 0) 'nothing or an empty list gives no guides (the loader then falls back)'

# where the guides come from: live manifest, then local guides.json, then built-in
$script:ManifestUrl = 'https://raw.githubusercontent.com/octo-test/family-it-fixit/main/manifest.json'
$mf = Join-Path $tmp 'g-manifest.json'
$script:WebMap = @{}; $script:WebMap[$script:ManifestUrl] = $mf
([pscustomobject]@{ version = '9.9.9'; guides = @([pscustomobject]@{ id = 'live-one'; title = 'From the web'; keywords = @('web'); steps = @('Step one.') }) } | ConvertTo-Json -Depth 6) | Set-Content $mf -Encoding ASCII
$localDir = Join-Path $tmp 'g-install'; New-Item -ItemType Directory $localDir -Force | Out-Null
$script:InstallDir = $localDir
Copy-Item (Join-Path $root 'guides.json') (Join-Path $localDir 'guides.json')
Reset-All; $script:WebFail = $false
$g = @(Get-FixItGuides)
Assert ($g.Count -eq 1 -and $g[0].Id -eq 'live-one') 'guides: the live list wins when it can be read'
$script:WebFail = $true
$g = @(Get-FixItGuides)
Assert ($g.Count -eq 11) 'guides: offline, the saved guides.json is used'
Remove-Item (Join-Path $localDir 'guides.json')
$g = @(Get-FixItGuides)
Assert ($g.Count -ge 1 -and $g[0].Id -eq 'screenshot') 'guides: offline and no file, the small built-in guide is used'
Set-Content (Join-Path $localDir 'guides.json') '{ this is not json' -Encoding ASCII
$g = @(Get-FixItGuides)
Assert ($g.Count -ge 1 -and $g[0].Id -eq 'screenshot') 'guides: a damaged guides.json falls back to the built-in guide'
$script:WebFail = $false
([pscustomobject]@{ version = '9.9.9'; guides = @() } | ConvertTo-Json -Depth 6) | Set-Content $mf -Encoding ASCII
Copy-Item (Join-Path $root 'guides.json') (Join-Path $localDir 'guides.json') -Force
Assert (@(Get-FixItGuides).Count -eq 11) 'guides: an empty live list is ignored in favour of guides.json'
'{ "version": "9.9.9" }' | Set-Content $mf -Encoding ASCII
Assert (@(Get-FixItGuides).Count -eq 11) 'guides: a manifest with no guides at all is fine'
$script:ManifestUrl = 'https://raw.githubusercontent.com/<OWNER>/family-it-fixit/main/manifest.json'
$script:Calls.Clear(); $null = Get-FixItGuides
Assert ((CallsLike 'web*') -eq 0) 'guides: with the <OWNER> placeholder nothing is fetched'

Section 'Help guides: search'
$G = $starter
function Hits { param([string]$Q) return ,@(Search-FixItGuides -Guides $G -Query $Q | ForEach-Object { $_.Guide.Id }) }
function FirstHit { param([string]$Q) $h = Hits $Q; if ($h.Count) { return $h[0] }; return '' }
Assert ((Hits 'scan') -contains 'scan') '"scan" finds the scanning guide'
Assert ((FirstHit 'scanner') -eq 'scan') '"scanner" finds the scanning guide (word family)'
Assert ((FirstHit 'scanning') -eq 'scan') '"scanning" finds the scanning guide'
Assert ((Hits 'copy paper') -contains 'scan') '"copy paper" finds the scanning guide (search words)'
Assert ((FirstHit 'photocopy') -eq 'scan') '"photocopy" finds the scanning guide'
Assert ((Hits 'picture') -contains 'attach-photo' -and (Hits 'picture') -contains 'save-photo') '"picture" finds the photo guides'
Assert ((Hits 'pictures') -contains 'save-photo') '"pictures" finds the photo guides'
Assert ((FirstHit 'photos') -in @('attach-photo', 'save-photo')) '"photos" finds a photo guide first'
Assert ((FirstHit 'wifi') -eq 'wifi' -and (FirstHit 'wi-fi') -eq 'wifi' -and (FirstHit 'wireless') -eq 'wifi') '"wifi", "wi-fi" and "wireless" find the Wi-Fi guide'
Assert ((FirstHit 'internet') -eq 'wifi') '"internet" finds the Wi-Fi guide'
Assert ((FirstHit 'zoom') -eq 'video-call') '"zoom" finds the video call guide'
Assert ((FirstHit 'teams') -eq 'teams-call' -and (FirstHit 'microsoft teams') -eq 'teams-call' -and (FirstHit 'join teams meeting') -eq 'teams-call') '"teams", "microsoft teams" and "join teams meeting" find the Teams guide first'
Assert ((FirstHit 'teams call') -eq 'teams-call' -and (FirstHit 'join meeting') -in @('teams-call', 'video-call') -and (Hits 'video call') -contains 'teams-call' -and (Hits 'lobby') -contains 'teams-call' -and (Hits 'waiting room') -contains 'teams-call') 'Teams guide: call, meeting, video call, lobby and waiting room words find it'
Assert ((FirstHit 'temas') -eq 'teams-call' -and (FirstHit 'tems meeting') -eq 'teams-call') 'Teams guide: typos like "temas" and "tems" still find it'
$tg = @($starter | Where-Object { $_.Id -eq 'teams-call' })[0]; $tgText = ($tg.Steps -join ' ')
Assert ($tgText -match 'Continue on this browser' -and $tgText -match 'Open your Teams app' -and $tgText -match 'Join now' -and $tgText -match '(?i)lobby' -and $tgText -match 'Leave' -and $tgText -match 'Fix sound/mic/camera') 'Teams guide covers the browser/app choice, Join now, the lobby, Leave and points to the sound/mic/camera fix'
Assert ((FirstHit 'make text bigger') -eq 'bigger-text') '"make text bigger" finds the text size guide'
Assert ((FirstHit 'cant read it') -eq 'bigger-text' -or (Hits 'cant read it').Count -eq 0 -or (Hits 'hard to read') -contains 'bigger-text') 'reading trouble words lead to the text size guide'
Assert ((FirstHit 'lost file') -eq 'find-download' -and (FirstHit 'where is my download') -eq 'find-download') 'file-hunting phrases find the downloads guide'
Assert ((FirstHit 'is this a scam') -eq 'spot-scam' -and (FirstHit 'phishing') -eq 'spot-scam') 'scam words find the scam guide'
Assert ((FirstHit 'screenshot') -eq 'screenshot' -and (FirstHit 'screen shot') -eq 'screenshot') '"screenshot" and "screen shot" find the screenshot guide'
Assert ((FirstHit 'print') -eq 'print' -and (FirstHit 'printing a pdf') -eq 'print') '"print" and "printing a pdf" find the print guide'
# typos
Assert ((FirstHit 'scaner') -eq 'scan') 'typo: "scaner"'
Assert ((FirstHit 'pritn') -eq 'print') 'typo: "pritn" (two letters swapped)'
Assert ((FirstHit 'screnshot') -eq 'screenshot') 'typo: "screnshot"'
Assert ((FirstHit 'wifii') -eq 'wifi') 'typo: "wifii"'
Assert ((FirstHit 'attatch') -eq 'attach-photo') 'typo: "attatch"'
Assert ((Hits 'pictre') -contains 'attach-photo') 'typo: "pictre"'
# fillers, capitals, symbols
Assert ((FirstHit 'How do I print?') -eq 'print' -and (FirstHit 'PRINT') -eq 'print' -and (FirstHit '  print!!  ') -eq 'print') 'capitals, punctuation and spaces do not matter'
Assert ((FirstHit 'help me with wifi') -eq 'wifi') 'filler words like "help me with" are ignored'
Assert ((Hits '').Count -eq 11 -and (Hits '   ').Count -eq 11 -and (Hits 'help me with').Count -eq 11) 'an empty search (or only filler words) shows every guide'
Assert ((Hits '') -join ',' -eq (($starter | ForEach-Object { $_.Id }) -join ',')) 'an empty search keeps the order of guides.json'
# nothing found
Assert ((Hits 'xyzzy').Count -eq 0 -and (Hits 'qqqqqq').Count -eq 0 -and (Hits 'refrigerator warranty').Count -eq 0) 'nonsense gives no hits'
Assert ((Hits 'a').Count -eq 11) 'one letter is too short to search on (shows everything)'
# ranking: title beats a passing mention in the steps
$rank = @([pscustomobject]@{ Id = 'a-mention'; Title = 'Something else'; Keywords = @(); Steps = @('Then you can print it.') }, [pscustomobject]@{ Id = 'b-title'; Title = 'How to print'; Keywords = @(); Steps = @('Do it.') })
Assert ((@(Search-FixItGuides -Guides $rank -Query 'print' | ForEach-Object { $_.Guide.Id })[0]) -eq 'b-title') 'a title match ranks above a mention in the steps'
# words in the steps are searched too
$stepOnly = @([pscustomobject]@{ Id = 's1'; Title = 'Alpha'; Keywords = @(); Steps = @('Open the control panel and find the gadget.') })
Assert (@(Search-FixItGuides -Guides $stepOnly -Query 'gadget').Count -eq 1) 'words that are only in the steps are found'
# two-word searches need most words
Assert ((Hits 'print zebra').Count -ge 1 -and (Hits 'print zebra')[0] -eq 'print') 'two words: one match out of two still finds the best guide'
Assert ((Hits 'zebra giraffe lion').Count -eq 0) 'three unknown words find nothing'
# does not fall over on odd input
Assert ((Hits ('x' * 500)).Count -eq 0 -and (Hits '!@#$%^&*()').Count -eq 11) 'very long or symbol-only searches do not crash'
$t0 = Get-Date; 1..3 | ForEach-Object { $null = Hits 'how do i print a picture' }; $ms = ((Get-Date) - $t0).TotalMilliseconds / 3
Assert ($ms -lt 1500) ('a search is fast enough to run as you type (' + [int]$ms + ' ms)')
Assert ((Get-FixItEditDistance 'print' 'pritn') -eq 1 -and (Get-FixItEditDistance 'scan' 'scam') -eq 1 -and (Get-FixItEditDistance 'abc' 'xyz') -eq 3) 'edit distance counts a swap as one slip'
Assert ((Get-FixItWordMatch 'scan' 'scan') -eq 3 -and (Get-FixItWordMatch 'scanner' 'scanning') -ge 2 -and (Get-FixItWordMatch 'cat' 'dog') -eq 0) 'word match levels'

Section 'Help guides: the helper and the "no guide" path'
Reset-All; $script:ManifestUrl = ''; Copy-Item (Join-Path $root 'guides.json') (Join-Path $localDir 'guides.json') -Force
$r = Invoke-GuidesHelper -Search 'scanner'
Assert ($r.Ok -and $r.Title -match '(?i)scan' -and $r.Message -match '(?m)^1\. ' -and $r.Message -match '(?m)^2\. ') 'helper: a search returns the best guide as numbered steps'
$r = Invoke-GuidesHelper -Search 'zebra giraffe lion'
Assert ($r.Ok -and $r.NoMatch -and $r.Message -eq 'No guide for that yet - Send Trey a report?') 'helper: no match gives the friendly "Send Trey a report?" message'
$r = Invoke-GuidesHelper
Assert ($r.Ok -and @($r.Guides).Count -eq 11) 'helper: no search lists every guide'
$n = Get-FixItNoGuideNote 'my   cat' 
Assert ($n -match 'my cat' -and $n -match 'no guide') 'the "no guide" note for the report says what was searched'
Assert ((Get-FixItNoGuideNote ('z' * 500)).Length -lt 300) 'the "no guide" note keeps a long search short'
$gcode = [IO.File]::ReadAllText((Join-Path $root 'FamilyFixIt.ps1'))
Assert ($gcode -match "GuideNone:" -and $gcode -match "GuideHelp:" -and $gcode -match 'Send Trey a report') 'the window has the no-match and "this did not help" report buttons'
Assert ((Get-FixItActionTable).Contains('Guides') -and -not (Get-FixItActionTable)['Guides'].Fix) 'Guides is a read-only action'

Section 'Simple mode'
Reset-All; $script:State = @{}
Assert (-not (Test-FixItSimpleMode)) 'simple mode starts off'
$full = Get-FixItLayout -Simple $false
$simp = Get-FixItLayout -Simple $true
Assert ((($simp.TileIds) -join ',') -eq 'Printer,Network,Slow,Scam,Screen,Report') 'simple mode shows exactly: printer, internet, slow, scam, screen share, report'
Assert (@($simp.Nav).Count -eq 0) 'simple mode hides the tools list (restart, undo, files, install, PC info, guides...)'
Assert (@($simp.Toggles | ForEach-Object { $_[0] }) -join ',' -eq 'Simple,BigText,Contrast') 'simple mode keeps only Simple mode, Big text and High contrast switches'
Assert ($simp.SideTitle -eq 'SETTINGS' -and $full.SideTitle -eq 'TOOLS') 'the left list is titled to match the mode'
Assert (@($full.TileIds).Count -eq 13 -and @($full.TileIds) -contains 'Scam' -and @($full.TileIds) -contains 'Screen' -and @($full.TileIds) -contains 'Report') 'the full layout keeps every tile'
Assert (@($full.Nav | ForEach-Object { $_[0] }) -contains 'PCInfo' -and @($full.Nav | ForEach-Object { $_[0] }) -contains 'Guides') 'the full layout lists My PC info and Help me with...'
Assert (@($full.Toggles | ForEach-Object { $_[0] })[0] -eq 'Simple') 'the full layout has the Simple mode switch'
Assert ($simp.FullH -lt $full.FullH) 'the simple window is shorter'
foreach ($L in @($full, $simp)) {
    $ys = @($L.Groups | ForEach-Object { $_.Y }) + @($L.ScamY, $L.PrimaryY, $L.StatusY, $L.LinksY)
    Assert (($ys -join ',') -eq ((@($ys) | Sort-Object { [int]$_ }) -join ',') -and $L.LinksY -lt $L.FullH) ('layout rows run top to bottom inside the window (' + $L.SideTitle + ')')
}
Assert ((Get-FixItLayout -Simple $false -BigText $true).Toggles | Where-Object { $_[0] -eq 'BigText' } | ForEach-Object { $_[3] }) 'the big text switch shows as on'
$r = Invoke-SimpleToggle
Assert ($r.Ok -and (Test-FixItSimpleMode) -and $script:State['SimpleMode'] -eq '1' -and $r.Title -eq 'Simple mode is on') 'toggle turns simple mode on and remembers it'
$r = Invoke-SimpleToggle
Assert ($r.Ok -and -not (Test-FixItSimpleMode) -and $script:State['SimpleMode'] -eq '0' -and $r.Title -eq 'Simple mode is off') 'toggle again turns it off'
$null = Invoke-SimpleToggle -Mode On; $null = Invoke-SimpleToggle -Mode On
Assert (Test-FixItSimpleMode) 'On twice stays on'
$null = Invoke-SimpleToggle -Mode Off
Assert (-not (Test-FixItSimpleMode)) 'Off turns it off'
$script:State = @{}; $script:DryRun = $true
$r = Invoke-SimpleToggle -Mode On
$script:DryRun = $false
Assert ($r.Title -eq 'Practice run' -and -not (Test-FixItSimpleMode) -and $script:State.Count -eq 0) 'practice run: nothing is remembered'
Assert ((Get-FixItActionTable).Contains('Simple') -and -not (Get-FixItActionTable)['Simple'].Fix) 'Simple is a read-only action (no admin)'
Assert ($script:State.Count -eq 0) 'simple mode leaves no other settings behind'

Section 'Guides and PC info: command line and files'
Reset-All
$src = [IO.File]::ReadAllText((Join-Path $root 'FamilyFixIt.ps1'))
Assert ($src -match "ValidateSet\([^)]*'PCInfo'[^)]*'Guides'[^)]*'Simple'") 'the command line accepts PCInfo, Guides and Simple'
Assert ($src -match "'PCInfo'\s+\{ Show-FixItResult" -and $src -match "'Guides'\s+\{ Show-FixItResult" -and $src -match "'Simple'\s+\{ Show-FixItResult") 'the command line runs the new actions'
$pw = (Get-Command pwsh).Source
foreach ($a in @('PCInfo', 'Guides', 'Simple')) {
    $out = & $pw -NoProfile -File (Join-Path $root 'FamilyFixIt.ps1') -Action $a -WhatIf -LogPath (Join-Path $tmp "cli-$a.log") 2>&1 | Out-String
    Assert ($LASTEXITCODE -eq 0) "command line: -Action $a -WhatIf runs and exits 0"
}
$out = & $pw -NoProfile -File (Join-Path $root 'FamilyFixIt.ps1') -Action Guides -Query 'scanner' -LogPath (Join-Path $tmp 'cli-g2.log') 2>&1 | Out-String
Assert ($out -match '(?i)scan') 'command line: -Action Guides -Query scanner prints the scanning guide'
$out = & $pw -NoProfile -File (Join-Path $root 'FamilyFixIt.ps1') -Action Guides -Query 'zebra giraffe lion' -LogPath (Join-Path $tmp 'cli-g3.log') 2>&1 | Out-String
Assert ($out -match 'No guide for that yet') 'command line: a search with no match says so'
$mfx = Get-Content (Join-Path $dist 'manifest.json') -Raw | ConvertFrom-Json
Assert (@($mfx.guides).Count -eq 11 -and @($mfx.guides | Where-Object { @($_.keywords).Count -ge 5 -and @($_.steps).Count -ge 3 }).Count -eq 11) 'the published list carries all 11 guides with their search words'
Assert (@($mfx.files | Where-Object { $_.path -eq 'guides.json' }).Count -eq 1) 'guides.json is in the published list with a fingerprint'
$gi = @($mfx.files | Where-Object { $_.path -eq 'guides.json' })[0]
Assert ($gi.sha256 -eq (Get-FileSha256 (Join-Path $dist 'guides.json'))) 'the guides.json fingerprint matches the file'
foreach ($p in @($mfx.guides)) { Assert ($p.id -match '^[a-z0-9][a-z0-9-]{0,39}$') ('published guide id ok: ' + $p.id) }
# publish refuses a broken guides.json
$badSrc = Join-Path $tmp 'badguides'; Copy-Item -LiteralPath $root -Destination $badSrc -Recurse
$bj = [IO.File]::ReadAllText((Join-Path $badSrc 'guides.json')).Replace('"id": "print"', '"id": "Bad Id!"')
[IO.File]::WriteAllText((Join-Path $badSrc 'guides.json'), $bj)
$threw = $false; try { & $pub -SourceDir $badSrc -OutDir (Join-Path $tmp 'badout') -WarningAction SilentlyContinue | Out-Null } catch { $threw = $true }
Assert $threw 'publish refuses a guides.json with a bad id'
$bj2 = [IO.File]::ReadAllText((Join-Path $root 'guides.json')).Replace('"id": "scan"', '"id": "print"')
[IO.File]::WriteAllText((Join-Path $badSrc 'guides.json'), $bj2)
$threw = $false; try { & $pub -SourceDir $badSrc -OutDir (Join-Path $tmp 'badout2') -WarningAction SilentlyContinue | Out-Null } catch { $threw = $true }
Assert $threw 'publish refuses a guides.json with a repeated id'
Assert ($script:AllowedUpdateFiles -contains 'guides.json') 'the updater is allowed to write guides.json'

Section 'Published files: the "not set up yet" guards survive publishing'
$pw2 = (Get-Command pwsh).Source
$ph = '<' + 'OWNER>'
foreach ($f in @('FamilyFixIt.ps1', 'Install-FixIt.ps1', 'Install-FamilyFixIt.cmd', 'README.md')) {
    Assert (-not ([IO.File]::ReadAllText((Join-Path $dist $f)).Contains($ph))) "published $f has no placeholder text left"
    Assert ([IO.File]::ReadAllText((Join-Path $dist $f)).Contains('octo-test')) "published $f has the owner name"
}
$pi = [IO.File]::ReadAllText((Join-Path $dist 'Install-FixIt.ps1'))
Assert ($pi -match "InstallerPlaceholder = \('<' \+ 'OWNER>'\)" -and $pi -match 'Base\.Contains\(\$script:InstallerPlaceholder\)' -and $pi -notmatch "-match 'octo-test'") 'published installer: the guard compares with the split placeholder, not with the owner name'
$pf = [IO.File]::ReadAllText((Join-Path $dist 'FamilyFixIt.ps1'))
Assert ($pf -match "OwnerPlaceholder = \('<' \+ 'OWNER>'\)" -and $pf -notmatch "match 'octo-test'" -and $pf -notmatch "(?i)contains\('octo-test'\)") 'published program: the update guards compare with the split placeholder, not with the owner name'
Assert ($pf -match "raw\.githubusercontent\.com/octo-test/family-it-fixit/main/manifest\.json") 'published program: the default update address has the owner name'
# run the PUBLISHED installer's guard, in its own PowerShell so nothing leaks into these tests
$tI = Join-Path $tmp 'guard-installer.ps1'
@"
. '$((Join-Path $dist 'Install-FixIt.ps1').Replace("'", "''"))' -LibraryOnly
function Test-InstallWindows { return `$true }
function Get-InstallText { param([string]`$Url) throw 'pretend: offline' }
`$real = Install-FamilyFixIt -Base 'https://raw.githubusercontent.com/octo-test/family-it-fixit/main' -Dir (Join-Path ([IO.Path]::GetTempPath()) 'fixit-guard-x') -Launch `$false
`$ph = Install-FamilyFixIt -Base ('https://raw.githubusercontent.com/<' + 'OWNER>/family-it-fixit/main') -Dir (Join-Path ([IO.Path]::GetTempPath()) 'fixit-guard-y') -Launch `$false
'REAL=' + `$real.Title
'PLACEHOLDER=' + `$ph.Title
"@ | Set-Content -Path $tI -Encoding ASCII
$o = & $pw2 -NoProfile -File $tI 2>&1 | Out-String
Assert ($o -match 'REAL=(?!Not set up yet)\S' -and $o -notmatch 'REAL=Not set up yet') 'published installer WITH the real owner gets past the guard (it goes on to try the download)'
Assert ($o -match 'PLACEHOLDER=Not set up yet') 'published installer with the placeholder address still stops with "Not set up yet"'
# the published program's update check
$tF = Join-Path $tmp 'guard-program.ps1'
@"
. '$((Join-Path $dist 'FamilyFixIt.ps1').Replace("'", "''"))' -LibraryOnly -LogPath '$((Join-Path $tmp 'guard-program.log').Replace("'", "''"))'
function Get-WebText { param([string]`$Url) throw 'pretend: offline' }
'REAL=' + (Get-RemoteManifest -Url `$script:DefaultManifestUrl).State
'PLACEHOLDER=' + (Get-RemoteManifest -Url ('https://raw.githubusercontent.com/<' + 'OWNER>/family-it-fixit/main/manifest.json')).State
'DEFAULT=' + `$script:DefaultManifestUrl
"@ | Set-Content -Path $tF -Encoding ASCII
$o = & $pw2 -NoProfile -File $tF 2>&1 | Out-String
Assert ($o -match 'REAL=Offline') 'published program WITH the real owner checks for updates (reaches the network step)'
Assert ($o -match 'PLACEHOLDER=NotSetUp') 'published program with the placeholder keeps updates switched off'
Assert ($o -match 'DEFAULT=https://raw\.githubusercontent\.com/octo-test/') 'published program starts with the real owner address'
# an unpublished (placeholder) copy still blocks
$tF2 = Join-Path $tmp 'guard-program2.ps1'
(Get-Content $tF -Raw).Replace((Join-Path $dist 'FamilyFixIt.ps1'), (Join-Path $root 'FamilyFixIt.ps1')).Replace('REAL=', 'SRC=') | Set-Content -Path $tF2 -Encoding ASCII
$o = & $pw2 -NoProfile -File $tF2 2>&1 | Out-String
Assert ($o -match 'SRC=NotSetUp') 'the unpublished source copy keeps updates off until it is published with an owner'

Section 'Program icon (file, update, shortcuts, window)'
$icoSrc = Join-Path $root 'FamilyFixIt.ico'
$ib = [IO.File]::ReadAllBytes($icoSrc)
Assert ($ib[0] -eq 0 -and $ib[1] -eq 0 -and $ib[2] -eq 1 -and $ib[3] -eq 0 -and $ib[4] -eq 6) 'the .ico is a real icon file with 6 pictures'
$icoSizes = @(); for ($k = 0; $k -lt 6; $k++) { $w = $ib[6 + 16 * $k]; if ($w -eq 0) { $w = 256 }; $icoSizes += $w }
Assert (($icoSizes -join ',') -eq '16,24,32,48,64,256') 'the .ico holds 16, 24, 32, 48, 64 and 256 pixel pictures'
$off256 = [BitConverter]::ToUInt32($ib, 6 + 16 * 5 + 12)
Assert ($ib[$off256] -eq 0x89 -and $ib[$off256 + 1] -eq 0x50 -and $ib[$off256 + 2] -eq 0x4E -and $ib[$off256 + 3] -eq 0x47) 'the 256 picture is stored as PNG (Windows Vista and later)'
Assert (Test-FixItIconFile -Path $icoSrc) 'Test-FixItIconFile accepts the real icon'
$junk = Join-Path $tmp 'junk.ico'; Set-Content $junk ('hello' * 20)
Assert (-not (Test-FixItIconFile -Path $junk) -and -not (Test-FixItIconFile -Path (Join-Path $tmp 'nope.ico'))) 'Test-FixItIconFile rejects a text file and a missing file'
Set-Content -Path (Join-Path $tmp 'empty.ico') -Value ''
Assert (-not (Test-FixItIconFile -Path (Join-Path $tmp 'empty.ico'))) 'Test-FixItIconFile rejects an empty file'
Assert ($script:AllowedAssetFiles -contains 'FamilyFixIt.ico' -and $script:AllowedUpdateFiles -notcontains 'FamilyFixIt.ico') 'the icon is an allowed asset, not an allowed "files" entry'

# an older program (2.3.1 and before) must still accept the new list: nothing unknown under "files"
$oldAllowed = @('FamilyFixIt.ps1', 'Start-FixIt.cmd', 'README.md', 'guides.json')
Assert (@($man.files | Where-Object { $oldAllowed -notcontains [string]$_.path }).Count -eq 0) 'every "files" entry is one that version 2.3.1 already accepts, so its update still works'

# shortcuts (pretend Windows)
$script:Lnks = @{}; $script:LnkWrites = New-Object System.Collections.ArrayList
$lnkDesk = Join-Path $tmp 'p-desk/Family Fix-It.lnk'; $lnkStart = Join-Path $tmp 'p-start/Family Fix-It.lnk'
function Get-FixItShortcutPaths { return @($lnkDesk, $lnkStart) }
function Read-FixItShortcut { param([string]$Path) if ($script:Lnks.ContainsKey($Path)) { return $script:Lnks[$Path] } return $null }
function Write-FixItShortcutIcon { param([string]$Path, [string]$Icon) [void]$script:LnkWrites.Add($Path); $script:Lnks[$Path].Icon = $Icon }
function Reset-Lnks { $script:Lnks = @{}; $script:LnkWrites.Clear(); $script:Lnks[$lnkDesk] = [pscustomobject]@{ Arguments = '-NoProfile -File "C:\x\FamilyFixIt.ps1"'; Icon = 'C:\Windows\System32\shell32.dll,22' }; $script:Lnks[$lnkStart] = [pscustomobject]@{ Arguments = '-NoProfile -File "C:\x\FamilyFixIt.ps1"'; Icon = 'C:\Windows\System32\shell32.dll,22' } }
$pdir = Join-Path $tmp 'icon-install'; New-Item -ItemType Directory $pdir | Out-Null
Reset-All; $script:InstallDir = $pdir; Reset-Lnks
Assert ((Update-FixItShortcutIcons) -eq 0 -and $script:LnkWrites.Count -eq 0) 'no icon file yet: shortcuts are left alone'
Copy-Item $icoSrc (Join-Path $pdir 'FamilyFixIt.ico')
$want = (Join-Path $pdir 'FamilyFixIt.ico') + ',0'
Assert ((Update-FixItShortcutIcons) -eq 2 -and $script:Lnks[$lnkDesk].Icon -eq $want -and $script:Lnks[$lnkStart].Icon -eq $want) 'Desktop and Start menu shortcuts are pointed at the icon file'
Assert ((Update-FixItShortcutIcons) -eq 0 -and $script:LnkWrites.Count -eq 2) 'doing it again changes nothing (idempotent)'
Reset-Lnks; $script:Lnks[$lnkDesk].Icon = $want.ToUpperInvariant()
Assert ((Update-FixItShortcutIcons) -eq 1 -and $script:LnkWrites.Count -eq 1 -and $script:LnkWrites[0] -eq $lnkStart) 'a shortcut that already has the icon (any letter case) is not touched'
Reset-Lnks; $script:Lnks[$lnkDesk].Arguments = '-File "C:\other\Something.ps1"'
Assert ((Update-FixItShortcutIcons) -eq 1 -and $script:Lnks[$lnkDesk].Icon -like '*shell32*') 'a shortcut with the same name that does not start Family Fix-It is never touched'
Reset-Lnks; $script:Lnks.Remove($lnkStart)
Assert ((Update-FixItShortcutIcons) -eq 1 -and -not $script:Lnks.ContainsKey($lnkStart)) 'a missing shortcut is not created by the updater'
Reset-Lnks; $script:DryRun = $true
Assert ((Update-FixItShortcutIcons) -eq 0 -and $script:LnkWrites.Count -eq 0) 'practice run (-WhatIf): shortcuts are not changed'
$script:DryRun = $false
function Write-FixItShortcutIcon { param([string]$Path, [string]$Icon) throw 'pretend: locked' }
Reset-Lnks
Assert ((Update-FixItShortcutIcons) -eq 0) 'a shortcut that cannot be written is skipped without crashing'
function Write-FixItShortcutIcon { param([string]$Path, [string]$Icon) [void]$script:LnkWrites.Add($Path); $script:Lnks[$Path].Icon = $Icon }

# update from a version that has no icon yet: the icon arrives with the update and the shortcuts follow
$distI3 = Join-Path $tmp 'dist-icon3'
& (Join-Path $newSrc 'tools/Publish-FixIt.ps1') -SourceDir $newSrc -Owner 'octo-test' -OutDir $distI3 | Out-Null
Reset-All; Set-Web $distI3; $script:ManifestUrl = $base + 'manifest.json'; $script:InstallDir = New-Install; Reset-Lnks
Assert (-not (Test-Path (Join-Path $script:InstallDir 'FamilyFixIt.ico'))) 'test setup: the old install has no icon'
$res = Invoke-FixItUpdate
$newIco = Join-Path $script:InstallDir 'FamilyFixIt.ico'
Assert ($res.Ok -and $res.Title -eq 'Updated' -and (Test-Path $newIco) -and (Get-FileSha256 $newIco) -eq (Get-FileSha256 $icoSrc)) 'update downloads the icon, checks its SHA-256 and installs it'
Assert ($script:Lnks[$lnkDesk].Icon -eq ($newIco + ',0') -and $script:Lnks[$lnkStart].Icon -eq ($newIco + ',0')) 'update refreshes the existing Desktop and Start menu shortcuts'
Assert ((CallsLike 'download*FamilyFixIt.ico') -eq 1) 'the icon is downloaded once'
# tampered icon: the whole update is refused and nothing changes
$distTamper = Join-Path $tmp 'dist-icon-tamper'; Copy-Item $distI3 $distTamper -Recurse
Add-Content (Join-Path $distTamper 'FamilyFixIt.ico') 'evil'
Reset-All; Set-Web $distTamper; $script:InstallDir = New-Install; Reset-Lnks
$verBefore = Get-FileSha256 (Join-Path $script:InstallDir 'FamilyFixIt.ps1')
$res = Invoke-FixItUpdate
Assert (-not $res.Ok -and $res.Title -eq 'Update did not work' -and -not (Test-Path (Join-Path $script:InstallDir 'FamilyFixIt.ico')) -and (Get-FileSha256 (Join-Path $script:InstallDir 'FamilyFixIt.ps1')) -eq $verBefore -and $script:LnkWrites.Count -eq 0) 'a tampered icon refuses the update; nothing is changed'
# valid fingerprint but not an icon: refused
$distNotIco = Join-Path $tmp 'dist-icon-notico'; Copy-Item $distI3 $distNotIco -Recurse
Set-Content (Join-Path $distNotIco 'FamilyFixIt.ico') ('not an icon ' * 10)
$m5 = Get-Content (Join-Path $distNotIco 'manifest.json') -Raw | ConvertFrom-Json
$m5.assets[0].sha256 = Get-FileSha256 (Join-Path $distNotIco 'FamilyFixIt.ico'); $m5.assets[0].size = (Get-Item (Join-Path $distNotIco 'FamilyFixIt.ico')).Length
($m5 | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $distNotIco 'manifest.json')
Reset-All; Set-Web $distNotIco; $script:InstallDir = New-Install; Reset-Lnks
$res = Invoke-FixItUpdate
Assert (-not $res.Ok -and -not (Test-Path (Join-Path $script:InstallDir 'FamilyFixIt.ico'))) 'a file that has the right fingerprint but is not an icon is refused'
# hostile or odd "assets" never break the update list
$mj = Get-Content (Join-Path $distI3 'manifest.json') -Raw | ConvertFrom-Json
$mj.assets = @($mj.assets) + [pscustomobject]@{ path = '..\evil.ico'; sha256 = ('a' * 64); size = 10 } + [pscustomobject]@{ path = 'FamilyFixIt.ico'; sha256 = 'zzz'; size = 10 } + [pscustomobject]@{ path = 'run.exe'; sha256 = ('c' * 64); size = 10 }
$mjf = Join-Path $tmp 'assets-hostile.json'; ($mj | ConvertTo-Json -Depth 6) | Set-Content $mjf
$script:WebMap = @{ ($base + 'manifest.json') = $mjf }; Reset-All
$rm = Get-RemoteManifest -Url ($base + 'manifest.json')
Assert ($rm.State -eq 'Ok' -and @($rm.Assets).Count -eq 1 -and $rm.Assets[0].path -eq 'FamilyFixIt.ico' -and $rm.Assets[0].sha256 -match '^[0-9a-f]{64}$') 'odd assets are ignored; the good one is kept; the list is still accepted'
$mj.PSObject.Properties.Remove('assets'); ($mj | ConvertTo-Json -Depth 6) | Set-Content $mjf
$rm = Get-RemoteManifest -Url ($base + 'manifest.json')
Assert ($rm.State -eq 'Ok' -and @($rm.Assets).Count -eq 0) 'a list with no assets at all is fine'

# an install that came through an older program's update (no icon yet): the new program fetches it by itself
Reset-All; Set-Web $distI3; $script:ManifestUrl = $base + 'manifest.json'
$script:InstallDir = New-Install; Reset-Lnks
Copy-Item (Join-Path $distI3 'FamilyFixIt.ps1') $script:InstallDir -Force
$script:FixItVersion = '2.3.16'   # pretend we are the newest program, so only the icon is missing
$fixed = Repair-FixItIcon
$ico2 = Join-Path $script:InstallDir 'FamilyFixIt.ico'
Assert ($fixed -and (Test-Path $ico2) -and (Get-FileSha256 $ico2) -eq (Get-FileSha256 $icoSrc) -and $script:Lnks[$lnkDesk].Icon -eq ($ico2 + ',0')) 'missing icon: fetched from the update list, verified, shortcuts pointed at it'
Assert (-not (Test-Path ($ico2 + '.download'))) 'no leftover download file'
$script:Calls.Clear(); $script:LnkWrites.Clear()
Assert ((Repair-FixItIcon) -eq $false -and (CallsLike 'web*') -eq 0 -and (CallsLike 'download*') -eq 0 -and $script:LnkWrites.Count -eq 0) 'icon already there: no network, nothing changed'
Remove-Item $ico2; $script:WebFail = $true
Assert ((Repair-FixItIcon) -eq $false -and -not (Test-Path $ico2)) 'offline: quietly does nothing'
$script:WebFail = $false; Set-Web $distTamper
Assert ((Repair-FixItIcon) -eq $false -and -not (Test-Path $ico2) -and -not (Test-Path ($ico2 + '.download'))) 'wrong fingerprint: nothing is kept'
$script:DryRun = $true; Set-Web $distI3
Assert ((Repair-FixItIcon) -eq $false -and -not (Test-Path $ico2)) 'practice run: nothing downloaded'
$script:DryRun = $false
$script:ManifestUrl = 'https://raw.githubusercontent.com/<' + 'OWNER>/family-it-fixit/main/manifest.json'
Assert ((Repair-FixItIcon) -eq $false) 'update address not set up: does nothing'
$script:FixItVersion = '2.3.15'

# window / taskbar icon
Assert (@([regex]::Matches($src, 'New-Object System\.Windows\.Forms\.Form')).Count -eq @([regex]::Matches($src, '(?m)^\s*(\$\w+) = New-Object System\.Windows\.Forms\.Form\r?\n\s*Set-FixItFormIcon \1')).Count) 'every window (main, confirm, pickers, guides ...) gets the program icon right after it is created'
$script:UiAppIcon = $null; $script:InstallDir = Join-Path $tmp 'no-such-dir'
Assert ($null -eq (Get-FixItAppIcon)) 'no icon file: the window keeps the default icon (no crash)'
$fake = [pscustomobject]@{ Icon = 'default' }; Set-FixItFormIcon $fake
Assert ($fake.Icon -eq 'default') 'no icon file: the form is left alone'
$script:UiAppIcon = 'sentinel-icon'; Set-FixItFormIcon $fake
Assert ($fake.Icon -eq 'sentinel-icon') 'with an icon: the form gets it (Windows uses it for the title bar and the taskbar)'
$script:UiAppIcon = $null
Assert (($src -match 'Repair-FixItIcon' ) -and ($src -match 'Set-FixItFormIcon \$s')) 'the window checks for the icon when it opens and applies it'

# the publish step also refuses a file named .ico that is not an icon
$badIco = Join-Path $tmp 'badico'; Copy-Item -LiteralPath $root -Destination $badIco -Recurse
Set-Content (Join-Path $badIco 'FamilyFixIt.ico') ('x' * 100)
$threw = $false; try { & $pub -SourceDir $badIco -OutDir (Join-Path $tmp 'badico-out') -WarningAction SilentlyContinue | Out-Null } catch { $threw = $true }
Assert ($threw -and -not (Test-Path (Join-Path $tmp 'badico-out'))) 'publish refuses an icon file that is not a real icon'
$noIco = Join-Path $tmp 'noico'; Copy-Item -LiteralPath $root -Destination $noIco -Recurse; Remove-Item (Join-Path $noIco 'FamilyFixIt.ico')
$threw = $false; try { & $pub -SourceDir $noIco -OutDir (Join-Path $tmp 'noico-out') -WarningAction SilentlyContinue | Out-Null } catch { $threw = $true }
Assert $threw 'publish stops when the icon file is missing'
$pi2 = [IO.File]::ReadAllText((Join-Path $dist 'Install-FixIt.ps1'))
Assert ($pi2 -match "FamilyFixIt\.ico" -and $pi2 -match 'Get-InstallIconLocation') 'the published installer knows the icon'

Section 'One window only (single instance)'
$pwx = (Get-Command pwsh).Source
$origAction = $Action; $origAdmin = $script:Admin; $origBg = $script:Background; $origDry = $script:DryRun; $origLocal = $env:LOCALAPPDATA
$env:LOCALAPPDATA = Join-Path $tmp 'si-local'; New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
$script:GuiInstanceKeyOverride = 'S-1-5-21-test-' + [guid]::NewGuid().ToString('N')
$script:Admin = $false; $script:Background = $false; $script:DryRun = $false

# names: per user, never the same as the Guardian's
$gn = Get-FixItGuiInstanceNames
Assert ($gn.Mutex -like 'Local\FamilyFixIt-GUI-S-1-5-21-test-*' -and $gn.Event -like 'Local\FamilyFixIt-GUI-Show-S-1-5-21-test-*') 'mutex and event are named Local\FamilyFixIt-GUI-... with the user key'
Assert ($gn.Mutex -ne $script:GuardianMutexName -and $gn.Mutex -notlike '*Guardian*') 'the window mutex is not the Guardian mutex'
$script:GuiInstanceKeyOverride = 'S-1-5-21-other'
Assert ((Get-FixItGuiInstanceNames).Mutex -ne $gn.Mutex) 'a different user gets a different mutex'
$script:GuiInstanceKeyOverride = $gn.Key
$script:DryRun = $true
Assert ((Get-FixItGuiInstanceNames).Mutex -like '*-Practice') 'practice mode (-WhatIf) has its own mutex, so it never hides a real window'
$script:DryRun = $false
$script:GuiInstanceKeyOverride = $null
$realNames = Get-FixItGuiInstanceNames
Assert ($realNames.Mutex -match '^Local\\FamilyFixIt-GUI-[A-Za-z0-9\-_]+$') 'without an override the name is built from the real user (SID or user name)'
$script:GuiInstanceKeyOverride = $gn.Key

# which starts take part: only the plain, visible, not-elevated window
$tree51 = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'FamilyFixIt.ps1'), [ref]$null, [ref]$null)
$actionParam = @($tree51.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Action' })[0]
$allActions = @($actionParam.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' })[0].PositionalArguments | ForEach-Object { [string]$_.Value }
Assert (@($allActions).Count -gt 40 -and $allActions -contains 'Gui') 'read the list of actions from the script itself'
$takePart = @(); foreach ($a in $allActions) { $script:Background = ($script:BackgroundActions -contains $a); Set-Variable -Name Action -Value $a -Scope 0 -ErrorAction SilentlyContinue; $Action = $a; if (Test-FixItGuiSingleInstanceApplies) { $takePart += $a } }
Assert ($takePart.Count -eq 1 -and $takePart[0] -eq 'Gui') ('only -Action Gui takes part (Guardian, CheckIn, HealthCheck, *Admin, Printer ... never do); took part: ' + ($takePart -join ','))
foreach ($a in @('Guardian', 'GuardianOn', 'GuardianOff', 'GuardianDemo', 'CheckIn', 'CheckInOn', 'CheckInOff', 'HealthCheck', 'PrinterAdmin', 'OutlookAdmin', 'UndoAdmin', 'WinUpdateDeepAdmin')) {
    $Action = $a; $script:Background = ($script:BackgroundActions -contains $a)
    Assert (-not (Test-FixItGuiSingleInstanceApplies)) "$a never uses the one-window rule"
}
$Action = 'Gui'; $script:Background = $false; $script:Admin = $false
Assert (Test-FixItGuiSingleInstanceApplies) 'the plain window takes part'
$script:Admin = $true
Assert (-not (Test-FixItGuiSingleInstanceApplies)) 'an elevated (administrator) run does not take part'
$script:Admin = $false; $script:Background = $true
Assert (-not (Test-FixItGuiSingleInstanceApplies)) 'a background run does not take part'
$script:Background = $false

# the real mutex, between real processes
$childLib = Join-Path $tmp 'si-child.ps1'
@"
param([string]`$Mode, [string]`$Key)
`$ErrorActionPreference = 'Stop'
`$env:LOCALAPPDATA = '$($env:LOCALAPPDATA)'
. '$((Join-Path $root 'FamilyFixIt.ps1'))' -LibraryOnly -LogPath '$((Join-Path $tmp 'si-child.log'))'
`$script:GuiInstanceKeyOverride = `$Key
Initialize-FixItLog
if (`$Mode -eq 'try') { `$i = Enter-FixItGuiInstance; Write-Output ('ACQUIRED=' + `$i.Acquired + ' FAILED=' + `$i.Failed); if (`$i.Acquired) { Exit-FixItGuiInstance `$i } }
if (`$mode -eq 'hold-and-die') { `$i = Enter-FixItGuiInstance; Write-Output ('ACQUIRED=' + `$i.Acquired); [Environment]::Exit(0) }
if (`$mode -eq 'second') { `$r = Invoke-FixItGuiShowExisting -Instance `$null; Write-Output ('ASKED=' + `$r) }
"@ | Set-Content -LiteralPath $childLib
function ChildRun { param([string]$Mode) return (& $pwx -NoProfile -File $childLib -Mode $Mode -Key $script:GuiInstanceKeyOverride 2>&1 | Out-String) }

$first = Enter-FixItGuiInstance
Assert ($first.Acquired -and -not $first.Failed -and $first.Mutex) 'the first window takes the lock'
$hasEvents = ($IsWindows -eq $true)   # named events only exist on Windows; the lock itself works everywhere
Assert (($null -ne $first.Event) -eq $hasEvents) 'the come-forward event is made on Windows; elsewhere the lock still works without it'
$o = ChildRun 'try'
Assert ($o -match 'ACQUIRED=False') 'a second start (another process) sees the window is already open and does not get the lock'
# the second start asks the open window to come forward (event) and the open window sees the request
if ($hasEvents) {
    Assert (-not $first.Event.WaitOne(0)) 'no request is waiting yet'
    $o = ChildRun 'second'
    Assert ($o -match 'ASKED=True') 'the second start finds the open window and asks it to come forward'
    Assert ($first.Event.WaitOne(0)) 'the open window receives the request (the event is signalled)'
    Assert (-not $first.Event.WaitOne(0)) 'one request is one wake-up (the event resets itself)'
} else {
    $o = ChildRun 'second'
    Assert ($o -match 'ASKED=False') 'no event and no saved window: the second start reports it could not reach the window, and ends quietly'
}
Initialize-FixItGuiFocus
Assert (([FixItGuiFocus]::IsValid([IntPtr]::Zero)) -eq $false -and ([FixItGuiFocus]::Bring([IntPtr]::Zero)) -eq $false -and ([FixItGuiFocus]::OwnerPid([IntPtr]::Zero)) -eq 0) 'focus helper compiles and refuses an empty window handle (no Windows call is made)'
# the open window writes where it is; the second start reads it
Save-FixItGuiInstanceInfo -Instance $first -Handle ([IntPtr]12345)
$infoFile = Get-FixItGuiInstanceFile -Key $first.Names.Key
$info = Get-Content -LiteralPath $infoFile -Raw | ConvertFrom-Json
Assert ([int]$info.pid -eq $PID -and [int64]$info.hwnd -eq 12345) 'the window handle and process id are saved for the second start'
Assert ((Split-Path -Parent $infoFile) -eq (Split-Path -Parent (Get-FixItStateFile)) -and ((Get-Content -LiteralPath $infoFile -Raw) -notmatch 'S-1-5-21')) 'the info file sits next to state.json in the FamilyFixIt folder and holds no account identifiers'
# a second Enter on the same thread must not be confused with another window (the second start is always another process)
Exit-FixItGuiInstance $first
Assert (-not (Test-Path -LiteralPath $infoFile)) 'closing the window removes the handle file'
$o = ChildRun 'try'
Assert ($o -match 'ACQUIRED=True') 'after the window closes the lock is free again'
Assert ($null -eq $script:GuiInstance) 'the open-window record is cleared on close'

# a stale file from another process is left alone on close
$other = Enter-FixItGuiInstance
[IO.File]::WriteAllText($infoFile, '{"pid": 1, "hwnd": 5}')
Exit-FixItGuiInstance $other
Assert (Test-Path -LiteralPath $infoFile) 'a handle file that belongs to another process is not deleted'
Remove-Item -LiteralPath $infoFile -Force

# crash: a process that dies while holding the lock must not lock everybody out
$o = ChildRun 'hold-and-die'
Assert ($o -match 'ACQUIRED=True') 'a window process took the lock and then died without releasing it'
$afterCrash = Enter-FixItGuiInstance
Assert ($afterCrash.Acquired -and -not $afterCrash.Failed) ('after a crash the next start gets the lock (abandoned: ' + $afterCrash.Abandoned + ')')
Exit-FixItGuiInstance $afterCrash

# an abandoned mutex (owner thread ended without releasing, handle still open) is taken over
$abName = 'Local\FamilyFixIt-GUI-' + $script:GuiInstanceKeyOverride
$absrc = 'public static class FixItAbandonTest { public static System.Threading.Mutex Hold(string n) { System.Threading.Mutex m = null; System.Threading.Thread t = new System.Threading.Thread(delegate() { m = new System.Threading.Mutex(false, n); m.WaitOne(); }); t.Start(); t.Join(); return m; } }'
if (-not ('FixItAbandonTest' -as [type])) { Add-Type -TypeDefinition $absrc }
$script:GuiInstanceKeyOverride = 'abandon-' + [guid]::NewGuid().ToString('N')
$abHandle = [FixItAbandonTest]::Hold((Get-FixItGuiInstanceNames).Mutex)
$taken = Enter-FixItGuiInstance
Assert ($taken.Acquired -and $taken.Abandoned -and -not $taken.Failed) 'an abandoned mutex (owner ended without releasing) is taken over'
Assert ((Get-Content -LiteralPath $script:LogFile -Raw) -match 'ended without closing properly') 'taking over an abandoned lock is logged'
Exit-FixItGuiInstance $taken
$abHandle.Dispose()
$script:GuiInstanceKeyOverride = $gn.Key

# if the lock cannot be made at all, the window still opens (never block the family)
$script:GuiInstanceKeyOverride = ('x' * 400)
$failOpen = Enter-FixItGuiInstance
Assert ($failOpen.Acquired -and $failOpen.Failed) 'if the lock cannot be created, the window opens anyway'
Exit-FixItGuiInstance $failOpen
$script:GuiInstanceKeyOverride = $gn.Key

# the flow in Show-FixItWindow, with the window itself pretended
$origMain = ${function:Show-FixItWindowMain}; $origEnter = ${function:Enter-FixItGuiInstance}; $origExit = ${function:Exit-FixItGuiInstance}; $origShowEx = ${function:Invoke-FixItGuiShowExisting}
function Show-FixItWindowMain { param($Instance) Rec 'MAIN WINDOW'; if ($script:MainThrows) { throw 'pretend crash' } }
function Exit-FixItGuiInstance { param($Instance) Rec 'release' }
function Invoke-FixItGuiShowExisting { param($Instance) Rec 'bring existing forward'; return $script:ShowExResult }
$script:ShowExResult = $true; $script:MainThrows = $false
$Action = 'Gui'; $script:Admin = $false; $script:Background = $false
function Enter-FixItGuiInstance { Rec 'enter'; return [pscustomobject]@{ Acquired = $false; Failed = $false; Abandoned = $false; Mutex = $null; Event = $null; Names = (Get-FixItGuiInstanceNames) } }
$script:Calls.Clear(); Show-FixItWindow
Assert ((CallsLike 'MAIN WINDOW') -eq 0 -and (CallsLike 'bring existing forward') -eq 1 -and (CallsLike 'release') -eq 0) 'already open: no second window; the open one is brought forward; this start just ends'
$script:ShowExResult = $false; $script:Calls.Clear(); Show-FixItWindow
Assert ((CallsLike 'MAIN WINDOW') -eq 0) 'already open but unreachable: still no second window, no error'
function Enter-FixItGuiInstance { Rec 'enter'; return [pscustomobject]@{ Acquired = $true; Failed = $false; Abandoned = $false; Mutex = $null; Event = $null; Names = (Get-FixItGuiInstanceNames) } }
$script:Calls.Clear(); Show-FixItWindow
Assert ((CallsLike 'MAIN WINDOW') -eq 1 -and (CallsLike 'release') -eq 1 -and (CallsLike 'bring*') -eq 0) 'nothing open: the window opens once and the lock is released when it closes'
$script:MainThrows = $true; $script:Calls.Clear(); $threwMain = $false
try { Show-FixItWindow } catch { $threwMain = $true }
Assert ($threwMain -and (CallsLike 'release') -eq 1) 'if the window crashes, the lock is still released'
$script:MainThrows = $false
foreach ($a in @('Guardian', 'CheckInOn', 'HealthCheck', 'PrinterAdmin')) {
    $Action = $a; $script:Background = ($script:BackgroundActions -contains $a); $script:Calls.Clear(); Show-FixItWindow
    Assert ((CallsLike 'enter') -eq 0 -and (CallsLike 'MAIN WINDOW') -eq 1 -and (CallsLike 'bring*') -eq 0) "$a never takes or checks the window lock"
}
$Action = 'Gui'; $script:Background = $false; $script:Admin = $true; $script:Calls.Clear(); Show-FixItWindow
Assert ((CallsLike 'enter') -eq 0 -and (CallsLike 'MAIN WINDOW') -eq 1) 'an elevated run never takes or checks the window lock'
${function:Show-FixItWindowMain} = $origMain; ${function:Enter-FixItGuiInstance} = $origEnter; ${function:Exit-FixItGuiInstance} = $origExit; ${function:Invoke-FixItGuiShowExisting} = $origShowEx

# the code itself: only the window uses the lock, and the pieces are in place
$siSrc = [IO.File]::ReadAllText((Join-Path $root 'FamilyFixIt.ps1'))
$siTree = [Management.Automation.Language.Parser]::ParseInput($siSrc, [ref]$null, [ref]$null)
$siFns = @($siTree.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
function SiFn { param($Name) return (@($siFns | Where-Object { $_.Name -eq $Name } | ForEach-Object { $_.Extent.Text }) -join "`n") }
$users = @($siFns | Where-Object { $_.Name -ne 'Show-FixItWindow' -and $_.Extent.Text -match 'Enter-FixItGuiInstance' } | ForEach-Object { $_.Name })
Assert ($users.Count -eq 1 -and $users[0] -eq 'Enter-FixItGuiInstance' -or $users.Count -eq 0) ('Enter-FixItGuiInstance is called from Show-FixItWindow only (found in: ' + ($users -join ',') + ')')
Assert ((SiFn 'Show-FixItWindow') -match 'Test-FixItGuiSingleInstanceApplies' -and (SiFn 'Show-FixItWindow') -match 'finally' -and (SiFn 'Show-FixItWindow') -match 'Exit-FixItGuiInstance') 'the window checks the rule first and always releases in a finally block'
$mainStarts = @([regex]::Matches($siSrc, "(?m)^\s*'Gui'\s*\{ Show-FixItWindow \}")).Count
Assert ($mainStarts -eq 1) 'only the Gui action opens the main window'
foreach ($fn in @('Invoke-GuardianRun', 'Enter-FixItGuardianMutex', 'Invoke-HealthCheck', 'Invoke-CheckInToggle', 'Invoke-AdminPart', 'Start-FixItGuardianProcess')) {
    Assert ((SiFn $fn) -notmatch 'GuiInstance|FamilyFixIt-GUI') "$fn does not touch the window lock"
}
$onceT = SiFn 'Show-FixItWindowOnce'
Assert ($onceT -match 'Start-FixItGuiShowWatcher' -and $onceT -match 'Add_HandleCreated' -and $onceT -match 'Save-FixItGuiInstanceInfo' -and $onceT -match '\$showTimer\.Dispose') 'the window listens for "come forward" requests, saves its handle, and stops listening when it closes'
$watchT = SiFn 'Start-FixItGuiShowWatcher'
Assert ($watchT -match 'WaitOne\(0\)' -and $watchT -match 'FixItGuiFocus\]::Bring' -and $watchT -match 'Get-FixItGuiFrontTarget') 'the watcher brings the window (or a question box on top of it) forward'
$showT = SiFn 'Invoke-FixItGuiShowExisting'
Assert ($showT -match 'AllowSetForegroundWindow|\]::Allow\(' -and $showT -match 'TryOpenExisting' -and $showT -match 'OwnerPid') 'the second start allows the focus change, signals the event, and only uses a handle that belongs to that process'
Assert ($script:GuiFocusCs -match 'SW_RESTORE|ShowWindow\(h, 9\)' -and $script:GuiFocusCs -match 'IsIconic' -and $script:GuiFocusCs -match 'SetForegroundWindow' -and $script:GuiFocusCs -match 'AllowSetForegroundWindow' -and $script:GuiFocusCs -match 'AttachThreadInput') 'the focus helper restores a minimized window and brings it to the front with the usual workaround'
Assert ($script:GuiFocusCs -notmatch '\?\.' -and $script:GuiFocusCs -notmatch '\$"' -and $script:GuiFocusCs -notmatch 'out var|=>') 'focus helper C# kept to the old C# 5 style that Windows PowerShell 5.1 accepts'
Assert ((SiFn 'Enter-FixItGuiInstance') -match 'AbandonedMutexException' -and (SiFn 'Exit-FixItGuiInstance') -match 'ReleaseMutex') 'abandoned locks are handled and the lock is released on close'
Assert ((Get-Content -LiteralPath (Join-Path $root 'Start-FixIt.cmd') -Raw) -notmatch 'Action') 'the shortcut launcher opens the plain window (no action), which is the one that is single-instance'

$Action = $origAction; $script:Admin = $origAdmin; $script:Background = $origBg; $script:DryRun = $origDry; $env:LOCALAPPDATA = $origLocal
if ($null -eq $origLocal) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue }
$script:GuiInstanceKeyOverride = $null

Section 'Logging'
$log = Get-Content $logFile -Raw
Assert ($log -match '(?m)^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \[INFO\] Doing: Stop the Print Spooler service') 'actions logged with timestamps'
Assert ($log -match '\[ERROR\] FAILED:') 'failures logged'

# ---- version 2.3.4 tests (Test mode, My files, window never freezes): they need the REAL functions, so they run in their own PowerShell
Section 'Version 2.3.4 tests (own process)'
$pwshExe = (Get-Process -Id $PID).Path
$v234 = & $pwshExe -NoProfile -File (Join-Path $PSScriptRoot 'Test-FixIt-V234.ps1') 2>&1 | ForEach-Object { [string]$_ }
foreach ($ln in $v234) { if ($ln -match 'FAIL:|^==') { Write-Host $ln } }
$sumLine = @($v234 | Where-Object { $_ -match '^Passed: \d+\s+Failed: \d+' }) | Select-Object -Last 1
if ($sumLine -match 'Passed: (\d+)\s+Failed: (\d+)') { $script:Pass += [int]$Matches[1]; $script:Fail += [int]$Matches[2] }
else { $script:Fail++; Write-Host '  FAIL: the 2.3.4 test file did not finish'; $v234 | Select-Object -Last 15 | ForEach-Object { Write-Host ('    ' + $_) } }

# ---- version 2.3.5 tests (Test mode false FAILs, Edge/Chrome lookup, the Chrome question): REAL functions, own PowerShell
Section 'Version 2.3.5 tests (own process)'
$v235 = & $pwshExe -NoProfile -File (Join-Path $PSScriptRoot 'Test-FixIt-V235.ps1') 2>&1 | ForEach-Object { [string]$_ }
foreach ($ln in $v235) { if ($ln -match 'FAIL:|^==') { Write-Host $ln } }
$sumLine = @($v235 | Where-Object { $_ -match '^Passed: \d+\s+Failed: \d+' }) | Select-Object -Last 1
if ($sumLine -match 'Passed: (\d+)\s+Failed: (\d+)') { $script:Pass += [int]$Matches[1]; $script:Fail += [int]$Matches[2] }
else { $script:Fail++; Write-Host '  FAIL: the 2.3.5 test file did not finish'; $v235 | Select-Object -Last 15 | ForEach-Object { Write-Host ('    ' + $_) } }

# ---- version 2.3.6 tests (old windows are closed before an update; an older open window never hides the new one): REAL functions, own PowerShell
Section 'Version 2.3.6 tests (own process)'
$v236 = & $pwshExe -NoProfile -File (Join-Path $PSScriptRoot 'Test-FixIt-V236.ps1') 2>&1 | ForEach-Object { [string]$_ }
foreach ($ln in $v236) { if ($ln -match 'FAIL:|^==') { Write-Host $ln } }
$sumLine = @($v236 | Where-Object { $_ -match '^Passed: \d+\s+Failed: \d+' }) | Select-Object -Last 1
if ($sumLine -match 'Passed: (\d+)\s+Failed: (\d+)') { $script:Pass += [int]$Matches[1]; $script:Fail += [int]$Matches[2] }
else { $script:Fail++; Write-Host '  FAIL: the 2.3.6 test file did not finish'; $v236 | Select-Object -Last 15 | ForEach-Object { Write-Host ('    ' + $_) } }

# ---- version 2.3.7 tests (the watcher's tray icon, the bigger My PC info, the weekly hardware monitor): REAL functions, own PowerShell
Section 'Version 2.3.7 tests (own process)'
$v237 = & $pwshExe -NoProfile -File (Join-Path $PSScriptRoot 'Test-FixIt-V237.ps1') 2>&1 | ForEach-Object { [string]$_ }
foreach ($ln in $v237) { if ($ln -match 'FAIL:|^==') { Write-Host $ln } }
$sumLine = @($v237 | Where-Object { $_ -match '^Passed: \d+\s+Failed: \d+' }) | Select-Object -Last 1
if ($sumLine -match 'Passed: (\d+)\s+Failed: (\d+)') { $script:Pass += [int]$Matches[1]; $script:Fail += [int]$Matches[2] }
else { $script:Fail++; Write-Host '  FAIL: the 2.3.7 test file did not finish'; $v237 | Select-Object -Last 15 | ForEach-Object { Write-Host ('    ' + $_) } }

# ---- version 2.3.8 tests (text-only buttons such as Skip and "I don't know" show their label)
Section 'Version 2.3.8 tests (own process)'
$v238 = & $pwshExe -NoProfile -File (Join-Path $PSScriptRoot 'Test-FixIt-V238.ps1') 2>&1 | ForEach-Object { [string]$_ }
foreach ($ln in $v238) { if ($ln -match 'FAIL:|^==') { Write-Host $ln } }
$sumLine = @($v238 | Where-Object { $_ -match '^Passed: \d+\s+Failed: \d+' }) | Select-Object -Last 1
if ($sumLine -match 'Passed: (\d+)\s+Failed: (\d+)') { $script:Pass += [int]$Matches[1]; $script:Fail += [int]$Matches[2] }
else { $script:Fail++; Write-Host '  FAIL: the 2.3.8 test file did not finish'; $v238 | Select-Object -Last 15 | ForEach-Object { Write-Host ('    ' + $_) } }

# ---- version 2.3.9 tests (Share with a friend, the Family Fix-It Reports folder, My files wrapping)
Section 'Version 2.3.9 tests (own process)'
$v239 = & $pwshExe -NoProfile -File (Join-Path $PSScriptRoot 'Test-FixIt-V239.ps1') 2>&1 | ForEach-Object { [string]$_ }
foreach ($ln in $v239) { if ($ln -match 'FAIL:|^==') { Write-Host $ln } }
$sumLine = @($v239 | Where-Object { $_ -match '^Passed: \d+\s+Failed: \d+' }) | Select-Object -Last 1
if ($sumLine -match 'Passed: (\d+)\s+Failed: (\d+)') { $script:Pass += [int]$Matches[1]; $script:Fail += [int]$Matches[2] }
else { $script:Fail++; Write-Host '  FAIL: the 2.3.9 test file did not finish'; $v239 | Select-Object -Last 15 | ForEach-Object { Write-Host ('    ' + $_) } }

# ---- version 2.3.10 tests (the pop-up watcher follows updates; the ? help window and other windows fit their text)
Section 'Version 2.3.10 tests (own process)'
$v2310 = & $pwshExe -NoProfile -File (Join-Path $PSScriptRoot 'Test-FixIt-V2310.ps1') 2>&1 | ForEach-Object { [string]$_ }
foreach ($ln in $v2310) { if ($ln -match 'FAIL:|^==') { Write-Host $ln } }
$sumLine = @($v2310 | Where-Object { $_ -match '^Passed: \d+\s+Failed: \d+' }) | Select-Object -Last 1
if ($sumLine -match 'Passed: (\d+)\s+Failed: (\d+)') { $script:Pass += [int]$Matches[1]; $script:Fail += [int]$Matches[2] }
else { $script:Fail++; Write-Host '  FAIL: the 2.3.10 test file did not finish'; $v2310 | Select-Object -Last 15 | ForEach-Object { Write-Host ('    ' + $_) } }

# ---- version 2.3.11 tests (Share with a friend gives a ready-to-paste email message)
Section 'Version 2.3.11 tests (own process)'
$v2311 = & $pwshExe -NoProfile -File (Join-Path $PSScriptRoot 'Test-FixIt-V2311.ps1') 2>&1 | ForEach-Object { [string]$_ }
foreach ($ln in $v2311) { if ($ln -match 'FAIL:|^==') { Write-Host $ln } }
$sumLine = @($v2311 | Where-Object { $_ -match '^Passed: \d+\s+Failed: \d+' }) | Select-Object -Last 1
if ($sumLine -match 'Passed: (\d+)\s+Failed: (\d+)') { $script:Pass += [int]$Matches[1]; $script:Fail += [int]$Matches[2] }
else { $script:Fail++; Write-Host '  FAIL: the 2.3.11 test file did not finish'; $v2311 | Select-Object -Last 15 | ForEach-Object { Write-Host ('    ' + $_) } }

# ---- version 2.3.13 tests (pop-up watcher Exit item, safer updater, Fix my display)
Section 'Version 2.3.13 tests (own process)'
$v2313 = & $pwshExe -NoProfile -File (Join-Path $PSScriptRoot 'Test-FixIt-V2313.ps1') 2>&1 | ForEach-Object { [string]$_ }
foreach ($ln in $v2313) { if ($ln -match 'FAIL:|^==') { Write-Host $ln } }
$sumLine = @($v2313 | Where-Object { $_ -match '^Passed: \d+\s+Failed: \d+' }) | Select-Object -Last 1
if ($sumLine -match 'Passed: (\d+)\s+Failed: (\d+)') { $script:Pass += [int]$Matches[1]; $script:Fail += [int]$Matches[2] }
else { $script:Fail++; Write-Host '  FAIL: the 2.3.13 test file did not finish'; $v2313 | Select-Object -Last 15 | ForEach-Object { Write-Host ('    ' + $_) } }

# ---- version 2.3.13 layout tests (text fits, windows fit the screen)
Section 'Version 2.3.13 layout tests (own process)'
$v2313l = & $pwshExe -NoProfile -File (Join-Path $PSScriptRoot 'Test-FixIt-V2313Layout.ps1') 2>&1 | ForEach-Object { [string]$_ }
foreach ($ln in $v2313l) { if ($ln -match 'FAIL:|^==') { Write-Host $ln } }
$sumLine = @($v2313l | Where-Object { $_ -match '^Passed: \d+\s+Failed: \d+' }) | Select-Object -Last 1
if ($sumLine -match 'Passed: (\d+)\s+Failed: (\d+)') { $script:Pass += [int]$Matches[1]; $script:Fail += [int]$Matches[2] }
else { $script:Fail++; Write-Host '  FAIL: the 2.3.13 layout test file did not finish'; $v2313l | Select-Object -Last 15 | ForEach-Object { Write-Host ('    ' + $_) } }

# ---- "Who helps you?" tests (the helper setting, the report with the helper in it, Quick Assist for other helpers)
Section 'Who helps you? tests (own process)'
$v2314 = & $pwshExe -NoProfile -File (Join-Path $PSScriptRoot 'Test-FixIt-V2314.ps1') 2>&1 | ForEach-Object { [string]$_ }
foreach ($ln in $v2314) { if ($ln -match 'FAIL:|^==') { Write-Host $ln } }
$sumLine = @($v2314 | Where-Object { $_ -match '^Passed: \d+\s+Failed: \d+' }) | Select-Object -Last 1
if ($sumLine -match 'Passed: (\d+)\s+Failed: (\d+)') { $script:Pass += [int]$Matches[1]; $script:Fail += [int]$Matches[2] }
else { $script:Fail++; Write-Host '  FAIL: the Who helps you? test file did not finish'; $v2314 | Select-Object -Last 15 | ForEach-Object { Write-Host ('    ' + $_) } }

# ---- version 2.3.15 tests (test mode and the missing reports folder, the Chrome search setting, the display wording, quieter display log)
Section 'Version 2.3.15 tests (own process)'
$v2315 = & $pwshExe -NoProfile -File (Join-Path $PSScriptRoot 'Test-FixIt-V2315.ps1') 2>&1 | ForEach-Object { [string]$_ }
foreach ($ln in $v2315) { if ($ln -match 'FAIL:|^==') { Write-Host $ln } }
$sumLine = @($v2315 | Where-Object { $_ -match '^Passed: \d+\s+Failed: \d+' }) | Select-Object -Last 1
if ($sumLine -match 'Passed: (\d+)\s+Failed: (\d+)') { $script:Pass += [int]$Matches[1]; $script:Fail += [int]$Matches[2] }
else { $script:Fail++; Write-Host '  FAIL: the 2.3.15 test file did not finish'; $v2315 | Select-Object -Last 15 | ForEach-Object { Write-Host ('    ' + $_) } }

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('Passed: {0}   Failed: {1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
