# Version 2.3.18 tests: the normal shortcut and Start-FixIt.cmd ask Windows for permission once.
#  The fix buttons then do not ask again, because the window is already an administrator.
#  Test mode, practice runs and the pop-up watcher do not ask, and Spotify still will not install from an administrator window.
# Windows-only parts use pretend adapters here; the REAL program functions run.
# Usage:  pwsh ./tests/Test-FixIt-V2318.ps1       (Test-FixIt.ps1 runs this one too and adds its numbers)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fixit-v2318-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:Pass = 0; $script:Fail = 0
function Assert { param([bool]$Cond, [string]$Name) if ($Cond) { $script:Pass++ } else { $script:Fail++; Microsoft.PowerShell.Utility\Write-Host ('  FAIL: ' + $Name) -ForegroundColor Red } }
function Section { param([string]$T) Microsoft.PowerShell.Utility\Write-Host ('== ' + $T) }

$src = Join-Path $root 'FamilyFixIt.ps1'
$outDir = Join-Path $tmp 'out'; New-Item -ItemType Directory -Path $outDir | Out-Null
$env:LOCALAPPDATA = Join-Path $tmp 'local'; New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
$tLogFile = Join-Path $tmp 'v2318.log'
. $src -LibraryOnly -LogPath $tLogFile -OutputDir $outDir
Initialize-FixItLog
$srcText = [IO.File]::ReadAllText($src)
$bytes = [IO.File]::ReadAllBytes($src)
$tokens = $null; $perr = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$perr)
function Get-Fn { param([string]$Name) $f = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1; if ($null -eq $f) { return '' }; return $f.Extent.Text }

Assert ([version]$script:FixItVersion -eq [version]'2.3.18') 'the program is version 2.3.18'
Assert ($perr.Count -eq 0) 'the program parses with no errors'
Assert (-not ($srcText -match '[^\x00-\x7F]') -and -not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF) -and $srcText -notmatch "`r") 'the program file is plain ASCII, no BOM, LF line ends'

function New-FakeLnk {
    param([string]$Path, [bool]$Ask = $false)
    $b = New-Object byte[] 76
    $hs = [BitConverter]::GetBytes([uint32]76)
    $b[0] = $hs[0]; $b[1] = $hs[1]; $b[2] = $hs[2]; $b[3] = $hs[3]
    if ($Ask) { $b[21] = 32 }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllBytes($Path, $b)
}

Section 'The permission mark on a shortcut file'
$one = Join-Path $tmp 'one.lnk'
New-FakeLnk $one
Assert (-not (Test-FixItShortcutAsks -Path $one)) 'a new shortcut does not ask yet'
Assert ((Set-FixItShortcutRunFlag -Path $one) -eq $true -and (Test-FixItShortcutAsks -Path $one)) 'marking it makes Windows ask for permission when it is opened'
$before = [IO.File]::ReadAllBytes($one)
Assert ((Set-FixItShortcutRunFlag -Path $one) -eq $false) 'doing it again changes nothing'
$after = [IO.File]::ReadAllBytes($one)
$sameBytes = ($before.Length -eq $after.Length)
for ($i = 0; $i -lt $before.Length -and $sameBytes; $i++) { if ($before[$i] -ne $after[$i]) { $sameBytes = $false } }
Assert $sameBytes 'a second mark does not rewrite the file'
$junk = Join-Path $tmp 'junk.lnk'; [IO.File]::WriteAllText($junk, 'not a shortcut')
Assert ((Set-FixItShortcutRunFlag -Path $junk) -eq $false -and (Test-FixItShortcutAsks -Path $junk) -eq $false) 'a file that is not a shortcut is left alone'
Assert ((Set-FixItShortcutRunFlag -Path (Join-Path $tmp 'missing.lnk')) -eq $false) 'a missing shortcut is not created'
Assert (Test-FixItShortcutWantsAsk -Path (Join-Path $tmp 'Family Fix-It.lnk') -Arguments '-NoProfile -File "C:\FamilyFixIt\FamilyFixIt.ps1"') 'the normal shortcut is one that should ask'
Assert (-not (Test-FixItShortcutWantsAsk -Path (Join-Path $tmp 'Family Fix-It (Test mode).lnk') -Arguments '-File "C:\x\FamilyFixIt.ps1" -Test')) 'the Test mode shortcut is not one that should ask'
Assert (-not (Test-FixItShortcutWantsAsk -Path (Join-Path $tmp 'Family Fix-It.lnk') -Arguments '-File "C:\other\Something.ps1"')) 'a shortcut with the right name that does not start Family Fix-It is left alone'
Assert (-not (Test-FixItShortcutWantsAsk -Path (Join-Path $tmp 'Family Fix-It.lnk') -Arguments '-File "C:\x\FamilyFixIt.ps1" -Test')) 'a normal name that was given -Test does not ask'

Section 'Official shortcuts are marked; Test mode is not'
$desk = Join-Path $tmp 'desk\Family Fix-It.lnk'
$start = Join-Path $tmp 'start\Family Fix-It.lnk'
$testLnk = Join-Path $tmp 'start\Family Fix-It (Test mode).lnk'
New-FakeLnk $desk; New-FakeLnk $start; New-FakeLnk $testLnk $false
function Get-FixItShortcutPaths { return @($desk, $start, $testLnk) }
function Read-FixItShortcut {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $a = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "C:\FamilyFixIt\FamilyFixIt.ps1"'
    if (([IO.Path]::GetFileName($Path)) -eq 'Family Fix-It (Test mode).lnk') { $a = $a + ' -Test' }
    return [pscustomobject]@{ Arguments = $a; Icon = 'shell32.dll,22' }
}
$script:TestMode = $false; $script:DryRun = $false
$n = Update-FixItOfficialShortcuts
Assert ($n -eq 2 -and (Test-FixItShortcutAsks $desk) -and (Test-FixItShortcutAsks $start) -and -not (Test-FixItShortcutAsks $testLnk)) 'Desktop and Start menu shortcuts are marked; Test mode is not'
$n = Update-FixItOfficialShortcuts
Assert ($n -eq 0 -and (Test-FixItShortcutAsks $desk) -and -not (Test-FixItShortcutAsks $testLnk)) 'a second run changes nothing, and Test mode stays unmarked'
$script:TestMode = $true; $script:DryRun = $true
New-FakeLnk $desk $false
Assert ((Update-FixItOfficialShortcuts) -eq 0 -and -not (Test-FixItShortcutAsks $desk)) 'Test mode does not mark any shortcut'
Assert ((Set-FixItShortcutRunFlag -Path $desk) -eq $false -and -not (Test-FixItShortcutAsks $desk)) 'the mark itself refuses to write in Test mode'
$script:TestMode = $false; $script:DryRun = $true
Assert ((Set-FixItShortcutRunFlag -Path $desk) -eq $false -and -not (Test-FixItShortcutAsks $desk)) 'a practice run does not mark any shortcut'
$script:DryRun = $false
Assert ((Set-FixItShortcutRunFlag -Path $desk) -eq $true -and (Test-FixItShortcutAsks $desk)) 'after practice mode, a real run can still mark it'

Section 'An update keeps the mark, and an icon save puts it back'
Assert ((Get-Fn 'Install-FixItUpdate') -match 'Update-FixItOfficialShortcuts') 'the in-app update marks the normal shortcuts after the files are in place'
Assert ((Get-Fn 'Show-FixItWindowOnce') -match 'Update-FixItOfficialShortcuts' -and (Get-Fn 'Show-FixItWindowOnce') -match 'TestMode') 'opening the real window marks them too, and Test mode is checked first'
Assert ((Get-Fn 'Write-FixItShortcutIcon') -match 'Set-FixItShortcutRunFlag' -and (Get-Fn 'Write-FixItShortcutIcon') -match 'ShortcutFileName') 'saving a shortcut icon puts the mark back (a save would otherwise drop it)'
$callers = @()
foreach ($f in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
    if ($f.Name -ne 'Update-FixItOfficialShortcuts' -and $f.Extent.Text -match 'Update-FixItOfficialShortcuts') { $callers += $f.Name }
}
$callers = @($callers | Sort-Object)
Assert (($callers -join ',') -eq 'Install-FixItUpdate,Show-FixItWindowOnce') ('only the update and the window mark shortcuts (found: ' + ($callers -join ',') + ')')
$flagFn = (Get-Fn 'Set-FixItShortcutRunFlag') + (Get-Fn 'Update-FixItOfficialShortcuts') + (Get-Fn 'Open-FixItMainWindow')
Assert ($flagFn -notmatch 'schtasks|Register-ScheduledTask|ScheduledTask') 'no scheduled task is used to skip the permission box'
Assert ((Get-Fn 'Start-FixItGuardianProcess') -notmatch 'RunAs|-Verb' -and (Get-Fn 'Get-FixItGuardianCommand') -notmatch 'RunAs|-Verb' -and (Get-Fn 'Invoke-GuardianRun') -notmatch 'Update-FixItOfficialShortcuts|Set-FixItShortcutRunFlag') 'the pop-up watcher is not given administrator rights, and it does not mark shortcuts'

Section 'Already an administrator: a fix does not ask again'
$script:Elev = 0
$realElev = ${function:Start-FixItElevated}
function Start-FixItElevated { param($Part, $ResultPath, [switch]$Visible, $InputPath) $script:Elev++; return 0 }
function Test-FixItAdmin { return $true }
$script:TestMode = $false; $script:DryRun = $false
$r = Invoke-AdminPart -Part 'SoundAdmin' -InProcess { 'direct' }
Assert ($r -eq 'direct' -and $script:Elev -eq 0) 'when the window is already an administrator, the fix runs directly and does not ask again'
function Test-FixItAdmin { return $false }
$r = Invoke-AdminPart -Part 'SoundAdmin' -InProcess { 'direct' }
Assert ($script:Elev -eq 1 -and -not $r.Ok) 'a window that is not an administrator still asks for the fix that needs it'
Assert ((Get-Fn 'Start-FixItElevated') -match 'Test mode never asks Windows for administrator') 'Test mode still refuses to start an administrator helper'
Set-Item -Path function:Start-FixItElevated -Value $realElev
$script:TestMode = $true
$threw = $false
try { Start-FixItElevated -Part 'SoundAdmin' -ResultPath (Join-Path $tmp 'r.json') } catch { $threw = $true }
$script:TestMode = $false
Assert $threw 'Test mode throws instead of asking Windows'

Section 'Spotify still will not install from an administrator window'
$script:V = @{ Calls = (New-Object System.Collections.ArrayList); Admin = $true }
function Test-FixItWinget { return $true }
function Test-FixItAdmin { return $script:V.Admin }
function Invoke-FixItNative {
    param([string]$File, [string[]]$Arguments = @(), [switch]$Live)
    [void]$script:V.Calls.Add("$File $($Arguments -join ' ')")
    if ($Arguments.Count -gt 0 -and $Arguments[0] -eq 'list') { return [pscustomobject]@{ ExitCode = 1; Output = 'No installed package found' } }
    return [pscustomobject]@{ ExitCode = 0; Output = '' }
}
$oldManifest = $script:ManifestUrl; $script:ManifestUrl = ''
$script:Asked = 0
function Confirm-FixItStep { param([string]$Question) $script:Asked++; return $true }
$script:TestMode = $false; $script:DryRun = $false
$r = Invoke-InstallApp -AppName 'Spotify'
Assert (-not $r.Ok -and $r.Title -eq 'Open me the usual way' -and $script:Asked -eq 0 -and @($script:V.Calls | Where-Object { $_ -like 'winget.exe install*' }).Count -eq 0) 'Spotify from an administrator window: plain message, nothing installed, nothing asked'
$script:V.Admin = $false; $script:V.Calls.Clear()
$r = Invoke-InstallApp -AppName 'Spotify'
Assert ($r.Ok -and @($script:V.Calls | Where-Object { $_ -like 'winget.exe install --id Spotify.Spotify*' }).Count -eq 1) 'Spotify from a normal window still installs without an administrator helper'
Assert ((Get-Fn 'Install-FixItApp') -notmatch 'Invoke-AdminPart|RunAs|Start-Process' -and (Get-Fn 'Invoke-InstallApp') -notmatch 'Invoke-AdminPart|RunAs') 'the app install never starts an administrator helper'
$script:ManifestUrl = $oldManifest

Section 'One window still applies when the window is an administrator'
$script:Background = $false
$Action = 'Gui'
function Test-FixItAdmin { return $true }
Assert (Test-FixItGuiSingleInstanceApplies) 'the main window takes the one-window lock even when it is an administrator'
$Action = 'Guardian'; $script:Background = $true
Assert (-not (Test-FixItGuiSingleInstanceApplies)) 'the pop-up watcher still does not take that lock'
$Action = 'PrinterAdmin'
Assert (-not (Test-FixItGuiSingleInstanceApplies)) 'an administrator helper still does not take that lock'
$Action = 'Gui'; $script:Background = $false
Assert ((Get-Fn 'Open-FixItMainWindow') -match '-File' -and (Get-Fn 'Open-FixItMainWindow') -notmatch '-Action' -and (Get-Fn 'Open-FixItMainWindow') -match 'Test-FixItShortcutWantsAsk') 'the tray opens the normal window through the official shortcut, with no extra action'

Section 'Start-FixIt.cmd asks, and the installer keeps the mark'
$cmdPath = Join-Path $root 'Start-FixIt.cmd'
$cmdBytes = [IO.File]::ReadAllBytes($cmdPath)
$cmd = [Text.Encoding]::ASCII.GetString($cmdBytes)
Assert (@($cmdBytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'Start-FixIt.cmd is plain ASCII'
Assert ($cmd -match 'FamilyFixIt\.ps1' -and $cmd -match 'RunAs' -and $cmd -notmatch 'Action') 'the launcher starts Family Fix-It and asks Windows for permission, and it is still the plain window'
Assert ($cmd -notmatch 'schtasks|Register-ScheduledTask') 'the launcher does not use a scheduled task'
Assert ($cmd -match 'FIXIT_SCRIPT') 'the launcher keeps a path that contains spaces'
$instPath = Join-Path $root 'Install-FixIt.ps1'
$instBytes = [IO.File]::ReadAllBytes($instPath)
$instText = [Text.Encoding]::ASCII.GetString($instBytes)
Assert (@($instBytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'the installer is plain ASCII'
Assert (([regex]::Matches($instText, "`r`n")).Count -eq ([regex]::Matches($instText, "`n")).Count) 'the installer keeps Windows line endings'
Assert ($instText -notmatch '(?i)RunAs|-Verb|schtasks|Register-ScheduledTask') 'the installer itself still does not ask for administrator rights or register a task'
Assert ($instText -match 'Set-InstallShortcutAsk' -and $instText -match '0x2000') 'the installer writes the permission mark onto the shortcut file'
$ierr = $null; $itok = $null
[void][Management.Automation.Language.Parser]::ParseFile($instPath, [ref]$itok, [ref]$ierr)
Assert ($ierr.Count -eq 0) 'the installer parses with no errors'

. $instPath -LibraryOnly
$desk2 = Join-Path $tmp 'idesk'; $prog2 = Join-Path $tmp 'istart'
New-Item -ItemType Directory -Path $desk2, $prog2 -Force | Out-Null
$script:LnkMeta = @{}
$script:LnkWrites = 0
$script:AskPaths = New-Object System.Collections.ArrayList
$realAsk = ${function:Set-InstallShortcutAsk}
function Get-InstallFolderPath { param([string]$Which) if ($Which -eq 'Desktop') { return $desk2 }; return $prog2 }
function Get-InstallPowerShell { return 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
function Get-InstallShortcut {
    param([string]$Path)
    if (-not $script:LnkMeta.ContainsKey($Path)) { return $null }
    $o = $script:LnkMeta[$Path]
    $ask = $false
    if (Test-Path -LiteralPath $Path) { $ask = Get-InstallShortcutAsk -Path $Path }
    return [pscustomobject]@{ Target = $o.Target; Arguments = $o.Arguments; Icon = $o.Icon; Ask = $ask }
}
function New-InstallShortcut {
    param([string]$Path, [string]$Target, [string]$Arguments, [string]$WorkDir, [string]$Icon, [string]$Description)
    $script:LnkWrites++
    $script:LnkMeta[$Path] = [pscustomobject]@{ Target = $Target; Arguments = $Arguments; Icon = $Icon }
    New-FakeLnk $Path $false
}
function Set-InstallShortcutAsk { param([string]$Path) [void]$script:AskPaths.Add($Path); & $realAsk -Path $Path }
$dir = Join-Path $tmp 'install-dir'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
# a real icon so the shortcut uses it
Copy-Item -LiteralPath (Join-Path $root 'FamilyFixIt.ico') -Destination (Join-Path $dir 'FamilyFixIt.ico') -Force
$made = Set-InstallShortcuts -Dir $dir
$dl = Join-Path $desk2 'Family Fix-It.lnk'
$sm = Join-Path $prog2 'Family Fix-It.lnk'
$tl = Join-Path $prog2 'Family Fix-It (Test mode).lnk'
Assert ($made -eq 2 -and (Test-Path -LiteralPath $dl) -and (Test-Path -LiteralPath $sm) -and (Test-Path -LiteralPath $tl)) 'the installer makes the Desktop, Start menu and Test mode shortcuts'
Assert ((Test-FixItShortcutAsks $dl) -and (Test-FixItShortcutAsks $sm) -and -not (Test-FixItShortcutAsks $tl)) 'only the normal shortcuts are marked; Test mode is not'
Assert (@($script:AskPaths | Where-Object { $_ -eq $tl }).Count -eq 0 -and @($script:AskPaths).Count -eq 2) 'the mark is written for the two normal shortcuts only'
$writes = $script:LnkWrites
$script:AskPaths.Clear()
$made2 = Set-InstallShortcuts -Dir $dir
Assert ($made2 -eq 2 -and $script:LnkWrites -eq $writes -and $script:AskPaths.Count -eq 0) 'a second run leaves a shortcut that already asks alone'
# an older shortcut: right target, right icon, no mark. The installer must put the mark back.
$b = [IO.File]::ReadAllBytes($dl); $b[21] = 0; [IO.File]::WriteAllBytes($dl, $b)
Assert (-not (Test-FixItShortcutAsks $dl)) 'setup: the Desktop shortcut no longer asks'
$made3 = Set-InstallShortcuts -Dir $dir
Assert ($script:LnkWrites -gt $writes -and (Test-FixItShortcutAsks $dl)) 'an update puts the mark back on a shortcut that lost it'
Assert (-not (Test-FixItShortcutAsks $tl)) 'that update still does not mark Test mode'
Assert ((Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw) -match 'What is new in 2\.3\.18' -and (Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw) -match 'asks Windows for permission once') 'the README says what is new'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('Passed: {0}   Failed: {1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
