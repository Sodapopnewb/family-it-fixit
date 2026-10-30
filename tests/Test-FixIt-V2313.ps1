# Version 2.3.13 tests: (1) the pop-up watcher's tray menu has "Turn off the pop-up watcher"; (2) the updater asks the running watcher to stop, stages each
# file and swaps it with retries, keeps the old file when it cannot, and starts the watcher again; (3) the new "Fix my display" button.
# Windows-only parts (the real key presses, the real screen change, the real event log) use pretend adapters here; the REAL program functions run.
# Usage:  pwsh ./tests/Test-FixIt-V2313.ps1       (Test-FixIt.ps1 runs this one too and adds its numbers)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fixit-v2313-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:Pass = 0; $script:Fail = 0
function Assert { param([bool]$Cond, [string]$Name) if ($Cond) { $script:Pass++ } else { $script:Fail++; Write-Host ('  FAIL: ' + $Name) -ForegroundColor Red } }
function Section { param([string]$T) Write-Host ('== ' + $T) }

$src = Join-Path $root 'FamilyFixIt.ps1'
$outDir = Join-Path $tmp 'out'; New-Item -ItemType Directory -Path $outDir | Out-Null
$env:LOCALAPPDATA = Join-Path $tmp 'local'; New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
$env:COMPUTERNAME = 'TESTPC'
$tLogFile = Join-Path $tmp 'v2313.log'
. $src -LibraryOnly -LogPath $tLogFile -OutputDir $outDir
Initialize-FixItLog
Initialize-FixItLog
function Get-Log { if (Test-Path -LiteralPath $tLogFile) { return [IO.File]::ReadAllText($tLogFile) }; return '' }
$srcText = [IO.File]::ReadAllText($src)
$bytes = [IO.File]::ReadAllBytes($src)
$tokens = $null; $perr = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$perr)
function Get-Fn { param([string]$Name) $f = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1; if ($null -eq $f) { return '' }; return $f.Extent.Text }

Assert ([version]$script:FixItVersion -ge [version]'2.3.13') 'the program is version 2.3.13 or newer'
Assert ($perr.Count -eq 0) 'the program parses with no errors'
Assert (-not ($srcText -match '[^\x00-\x7F]') -and -not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) -and $srcText -notmatch "`r") 'the program file is plain ASCII, with no BOM and LF line ends'

# ================================================================ 1. the tray Exit item
Section 'Tray menu: Turn off the pop-up watcher'
$plan = Get-FixItTrayPlan
Assert (@($plan.Items).Count -eq 3 -and @($plan.Items)[2].Id -eq 'Exit' -and @($plan.Items)[2].Text -eq 'Turn off the pop-up watcher') 'the third item is "Turn off the pop-up watcher" (Id Exit)'
Assert (@($plan.Items)[0].Id -eq 'GetOut' -and @($plan.Items)[1].Id -eq 'Open') 'the first two items are unchanged'
Assert ($plan.DoubleClick -eq 'Open') 'double-click still opens the window'
$preview = Get-FixItTrayPreviewText
Assert ($preview -match 'Turn off the pop-up watcher') 'the Test-mode preview of the menu names the new item'
Assert ($srcText -match "\[ValidateSet\('Exit'\)\]|'Exit'" -and (Get-Fn 'Invoke-GuardianTrayAction') -match "'Exit'" -and (Get-Fn 'Invoke-GuardianTrayAction') -match 'Invoke-GuardianExit') 'clicking the item runs Invoke-GuardianExit'
$ex = Get-Fn 'Invoke-GuardianExit'
Assert ($ex -ne '' -and $ex -match 'Remove-FixItGuardianTray' -and $ex -match 'ExitThread' -and $ex -match 'Write-FixItLog') 'it frees the tray icon, leaves the loop and logs'
Assert ($ex -notmatch 'Set-RegString|Remove-RegValue|Set-FixItSetting|Invoke-GuardianToggle|Unregister|Remove-ItemProperty|GuardianRunKey') 'it does not touch the startup entry or the Guardian setting (the watcher returns at the next sign-in)'
Assert ((Get-Fn 'Invoke-GuardianRun') -match 'Remove-FixItGuardianTray' -and (Get-Fn 'Invoke-GuardianRun') -match 'Release-FixItGuardianMutex \$mutex' -and (Get-Fn 'Invoke-GuardianRun') -match "Guardian stopped") 'when the loop ends, the tray icon is removed, the single-instance lock (Local\FamilyFixItGuardian) is released and "Guardian stopped" is logged'
$script:GCalls = New-Object System.Collections.ArrayList
function Close-FixItGuardianToast { [void]$script:GCalls.Add('toast') }
function Remove-FixItGuardianTray { [void]$script:GCalls.Add('tray') }
$script:GExiting = $false; $script:GRelaunch = $true
Invoke-GuardianExit
Assert ($script:GExiting -and -not $script:GRelaunch -and ($script:GCalls -join ',') -eq 'toast,tray') 'Exit: closes any open question, removes the tray icon, and does not relaunch'
Assert ((Get-Log) -match 'Guardian: turned off from the tray menu') 'the exit is logged'
$script:GCalls.Clear(); Invoke-GuardianExit
Assert ($script:GCalls.Count -eq 0) 'clicking it twice does nothing the second time'
Assert ($srcText -match '\$script:GExiting = \$false') 'a new watcher run starts with the exit flag cleared'
Remove-Item Function:\Close-FixItGuardianToast, Function:\Remove-FixItGuardianTray -ErrorAction SilentlyContinue
. $src -LibraryOnly -LogPath $tLogFile -OutputDir $outDir
Initialize-FixItLog

# ================================================================ 2. the updater
Section 'Updater: retry waits'
$waits = @(Get-FixItUpdateRetryWaits)
Assert ($waits.Count -eq 9 -and $waits[0] -eq 200 -and $waits[8] -eq 1800) '10 tries means 9 waits, growing from 0.2 s to 1.8 s'
Assert ((($waits | Measure-Object -Sum).Sum) -ge 8000 -and (($waits | Measure-Object -Sum).Sum) -le 10000) 'the waits add up to about 9 seconds'
$grow = $true; for ($i = 1; $i -lt $waits.Count; $i++) { if ($waits[$i] -le $waits[$i - 1]) { $grow = $false } }
Assert $grow 'every wait is longer than the one before'

Section 'Updater: one file at a time'
$ud = Join-Path $tmp 'upd'; New-Item -ItemType Directory -Path $ud -Force | Out-Null
$script:Waited = New-Object System.Collections.ArrayList
function Wait-FixIt { param([double]$Seconds = 0, [int]$Milliseconds = 0) [void]$script:Waited.Add([int]([math]::Round($Seconds * 1000)) + $Milliseconds) }
$realMove = ${function:Move-FixItStagedFile}
$new = Join-Path $ud 'new.txt'; [IO.File]::WriteAllText($new, 'NEW')
$tgt = Join-Path $ud 'target.txt'; [IO.File]::WriteAllText($tgt, 'OLD')
Install-FixItFileSafely -Source $new -Target $tgt
Assert ([IO.File]::ReadAllText($tgt) -eq 'NEW' -and -not (Test-Path -LiteralPath ($tgt + '.fixit-new')) -and -not (Test-Path -LiteralPath ($tgt + '.fixit-old'))) 'a normal swap puts the new file in and leaves no temporary files behind'
Assert ($script:Waited.Count -eq 0) 'a swap that works the first time does not wait'
[IO.File]::WriteAllText($tgt, 'OLD')
Install-FixItFileSafely -Source $new -Target $tgt
Install-FixItFileSafely -Source $new -Target $tgt
Assert ([IO.File]::ReadAllText($tgt) -eq 'NEW') 'doing it again is harmless'
$missing = Join-Path $ud 'fresh.txt'
Install-FixItFileSafely -Source $new -Target $missing
Assert ([IO.File]::ReadAllText($missing) -eq 'NEW') 'a file that is not there yet is simply put in place'

$script:MoveTries = 0; $script:FailFirst = 3
function Move-FixItStagedFile { param([string]$Temp, [string]$Target) $script:MoveTries++; if ($script:MoveTries -le $script:FailFirst) { throw 'The process cannot access the file because it is being used by another process.' }; & $realMove -Temp $Temp -Target $Target }
[IO.File]::WriteAllText($tgt, 'OLD'); $script:Waited.Clear()
Install-FixItFileSafely -Source $new -Target $tgt
Assert ([IO.File]::ReadAllText($tgt) -eq 'NEW' -and $script:MoveTries -eq 4) 'a file that is locked for 3 tries is replaced on the 4th'
Assert (($script:Waited -join ',') -eq '200,400,600') 'it waited 0.2, 0.4 and 0.6 seconds in between'
Assert ((Get-Log) -match 'could not replace target\.txt yet \(try 1 of 10\)' -and (Get-Log) -match 'replaced target\.txt on try 4') 'each failed try and the success are logged'
$script:MoveTries = 0; $script:FailFirst = 99; $script:Waited.Clear(); [IO.File]::WriteAllText($tgt, 'OLD')
$threw = ''; try { Install-FixItFileSafely -Source $new -Target $tgt } catch { $threw = $_.Exception.Message }
Assert ($script:MoveTries -eq 10 -and $script:Waited.Count -eq 9) 'a file that stays locked is tried 10 times, with 9 waits'
Assert ($threw -match 'still in use by another program' -and [IO.File]::ReadAllText($tgt) -eq 'OLD') 'then it gives up with a plain message and the old file is exactly as it was'
Assert (-not (Test-Path -LiteralPath ($tgt + '.fixit-new'))) 'the temporary file is removed after giving up'
Set-Item -Path Function:\Move-FixItStagedFile -Value $realMove

Section 'Updater: asks the watcher to stop, swaps, starts it again'
$script:InstallDir = Join-Path $ud 'installed'; New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
$f1 = Join-Path $ud 'src-main.ps1'; [IO.File]::WriteAllText($f1, "`$script:FixItVersion = '9.9.9'`r`n")
$f2 = Join-Path $ud 'src-other.txt'; [IO.File]::WriteAllText($f2, 'OTHER-NEW')
$man = [pscustomobject]@{ Version = [version]'9.9.9'; BaseUrl = 'https://example.test/'; Files = @([pscustomobject]@{ path = 'FamilyFixIt.ps1'; sha256 = (Get-FileSha256 -Path $f1) }, [pscustomobject]@{ path = 'other.txt'; sha256 = (Get-FileSha256 -Path $f2) }) }
$script:Seq = New-Object System.Collections.ArrayList
function Save-WebFile { param([string]$Url, [string]$Dest) New-Item -ItemType Directory -Path (Split-Path $Dest) -Force | Out-Null; if ($Url -like '*other.txt') { Copy-Item -LiteralPath $f2 -Destination $Dest -Force } else { Copy-Item -LiteralPath $f1 -Destination $Dest -Force } }
function Close-FixItOtherGuiWindows { param($Why) return 0 }
function Update-FixItShortcutIcons { return 0 }
$script:Running = $true; $script:Stopped = $false
function Test-FixItGuardianRunning { return $script:Running }
function Test-FixItGuardianInstalled { return $true }
function Get-FixItSetting { param([string]$Name, [string]$Default = '') return '1' }
function Stop-FixItGuardianProcess { [void]$script:Seq.Add('stop'); $script:Running = $false }
function Wait-FixItGuardianGone { param([int]$Seconds = 6) return (-not $script:Running) }
function Restart-FixItGuardian { param([string]$Why = 'update') [void]$script:Seq.Add('restart:' + $Why); return $true }
function Move-FixItStagedFile { param([string]$Temp, [string]$Target) [void]$script:Seq.Add('swap:' + (Split-Path -Leaf $Target)); & $realMove -Temp $Temp -Target $Target }
[IO.File]::WriteAllText((Join-Path $script:InstallDir 'FamilyFixIt.ps1'), "`$script:FixItVersion = '2.3.10'`r`n")
[IO.File]::WriteAllText((Join-Path $script:InstallDir 'other.txt'), 'OTHER-OLD')
$script:TestMode = $false; $script:DryRun = $false
Install-FixItUpdate -Manifest $man
Assert (($script:Seq -join ',') -eq 'stop,swap:FamilyFixIt.ps1,swap:other.txt,restart:update') 'the update stops the running watcher first, swaps each file, then starts the watcher again'
Assert ([IO.File]::ReadAllText((Join-Path $script:InstallDir 'FamilyFixIt.ps1')) -match '9\.9\.9' -and [IO.File]::ReadAllText((Join-Path $script:InstallDir 'other.txt')) -eq 'OTHER-NEW') 'both files are the new ones'
Assert ((Get-Log) -match 'Update: asking the pop-up watcher to stop' -and (Get-Log) -match 'Update: the pop-up watcher has stopped') 'the stop is logged'
Assert ([IO.File]::ReadAllText((Join-Path (Join-Path $script:InstallDir 'previous') 'FamilyFixIt.ps1')) -match '2\.3\.10') 'the old program file is saved in the previous folder'
# idempotent: run it again with no watcher running
$script:Seq.Clear(); $script:Running = $false
Install-FixItUpdate -Manifest $man
Assert (($script:Seq -join ',') -eq 'swap:FamilyFixIt.ps1,swap:other.txt,restart:update') 'with no watcher running nothing is stopped; the update still works a second time and starts the watcher'

Section 'Updater: a file that cannot be replaced keeps every original'
[IO.File]::WriteAllText((Join-Path $script:InstallDir 'FamilyFixIt.ps1'), "`$script:FixItVersion = '2.3.10'`r`n")
[IO.File]::WriteAllText((Join-Path $script:InstallDir 'other.txt'), 'OTHER-OLD')
$script:Seq.Clear(); $script:Running = $true; $script:Waited.Clear()
function Move-FixItStagedFile { param([string]$Temp, [string]$Target) [void]$script:Seq.Add('swap:' + (Split-Path -Leaf $Target)); if ((Split-Path -Leaf $Target) -eq 'other.txt' -and -not $script:AllowOther) { throw 'locked' }; & $realMove -Temp $Temp -Target $Target }
$script:AllowOther = $false
$threw = $false; try { Install-FixItUpdate -Manifest $man } catch { $threw = $true }
Assert $threw 'when the second file stays locked the update reports failure'
Assert ([IO.File]::ReadAllText((Join-Path $script:InstallDir 'FamilyFixIt.ps1')) -match '2\.3\.10' -and [IO.File]::ReadAllText((Join-Path $script:InstallDir 'other.txt')) -eq 'OTHER-OLD') 'the first file that had already been replaced is put back: both originals are as they were'
Assert (@($script:Seq | Where-Object { $_ -eq 'swap:other.txt' }).Count -eq 10) 'the locked file was tried 10 times'
Assert ($script:Seq[0] -eq 'stop' -and $script:Seq[-1] -eq 'restart:the update did not finish') 'the watcher was stopped first, and is started again from the old program after the failure'
Assert (@(Get-ChildItem -LiteralPath $script:InstallDir -Filter '*.fixit-*' -Force -ErrorAction SilentlyContinue).Count -eq 0) 'no temporary files are left in the install folder'
Assert ((Get-Log) -match 'putting back the ones already replaced') 'the roll-back is logged'
Set-Item -Path Function:\Move-FixItStagedFile -Value $realMove
$ins = Get-Fn 'Install-FixItUpdate'
Assert ($ins -match 'Install-FixItFileSafely' -and $ins -match 'Stop-FixItGuardianForUpdate' -and $ins.IndexOf('Stop-FixItGuardianForUpdate') -lt $ins.IndexOf('Install-FixItFileSafely') -and $ins.LastIndexOf('Restart-FixItGuardian') -gt $ins.IndexOf('Install-FixItFileSafely')) 'the order in the program text is stop, swap, restart'
Assert ((Get-Fn 'Stop-FixItGuardianForUpdate') -match 'Stop-FixItGuardianProcess' -and (Get-Fn 'Stop-FixItGuardianForUpdate') -notmatch 'Stop-Process') 'stopping uses the existing stop mechanism (the polite signal first)'
foreach ($fn in @('Save-WebFile', 'Close-FixItOtherGuiWindows', 'Update-FixItShortcutIcons', 'Test-FixItGuardianRunning', 'Test-FixItGuardianInstalled', 'Get-FixItSetting', 'Stop-FixItGuardianProcess', 'Wait-FixItGuardianGone', 'Restart-FixItGuardian', 'Wait-FixIt')) { Remove-Item "Function:\$fn" -ErrorAction SilentlyContinue }
. $src -LibraryOnly -LogPath $tLogFile -OutputDir $outDir
Initialize-FixItLog

# ================================================================ 3. Fix my display
Section 'Fix my display: the button'
$lay = Get-FixItLayout -Simple $false
$tileIds = @($lay.TileIds)
Assert ($tileIds -contains 'Display' -and $tileIds.Count -eq 13) 'the full layout has the Display tile (13 main buttons)'
$g4 = @($lay.Groups | Where-Object { @($_.Tiles | Where-Object { $_[0] -eq 'Display' }).Count -gt 0 })[0]
$dt = @($g4.Tiles | Where-Object { $_[0] -eq 'Display' })[0]
Assert ($dt[1] -eq 'Fix my display' -and $dt[2] -eq 'Flickers or goes black' -and $dt[3] -eq 'display') 'its title is "Fix my display", subtitle "Flickers or goes black"'
$tops = @($lay.Groups | ForEach-Object { $_.Y }); $ordered = $true; for ($i = 1; $i -lt $tops.Count; $i++) { if (($tops[$i] - $tops[$i - 1]) -ne 150) { $ordered = $false } }
Assert ($ordered -and $lay.ScamY -gt ($tops[-1] + 134) -and $lay.FullH -gt ($lay.LinksY + 20)) 'the new row sits below the others (150 apart) and everything under it moved down with room to spare'
$simple = Get-FixItLayout -Simple $true
Assert (@($simple.TileIds) -notcontains 'Display') 'Simple mode is unchanged (no Display tile)'
$icoM = [regex]::Match($srcText, "'display' = '([A-Za-z0-9+/=]+)'")
Assert ($icoM.Success) 'the tile has an icon'
$png = [Convert]::FromBase64String($icoM.Groups[1].Value)
Assert ($png[0] -eq 0x89 -and $png[1] -eq 0x50 -and [BitConverter]::ToInt32($png[19..16], 0) -eq 64 -and [BitConverter]::ToInt32($png[23..20], 0) -eq 64) 'the icon is a 64 x 64 picture'
$help = Get-FixItHelpTable
Assert ($help.ContainsKey('Display') -and $help['Display'].Title -eq 'Fix my display') 'the "?" help bubble exists'
Assert (@(Get-FixItMainTileKeys -Layout $lay) -contains 'Display') 'the tile gets a "?" dot'
$act = Get-FixItActionTable
$a = $act['Display']
Assert ($null -ne $a -and $a.Fn -eq 'Invoke-DisplayFix' -and $a.Fix) 'the action table runs Invoke-DisplayFix'
Assert ($a.Plan.Time -and @($a.Plan.Does).Count -ge 3 -and @($a.Plan.Heads).Count -ge 1) 'the "Here is what I will do" window has text'
Assert (($a.Plan.Does -join ' ') -match 'Windows key' -and ($a.Plan.Heads -join ' ') -match 'black or flicker') 'it says in plain words that the screen may go black for a second'
Assert (-not [string]$a.Plan.SignIn -and -not [string]$a.Plan.Restart) 'no sign-in or restart warnings'
Assert ((Get-Fn 'Invoke-DisplayFix') -notmatch 'Invoke-AdminPart|Start-FixItElevated|RunAs' -and (Get-Fn 'Get-FixItDisplayFacts') -notmatch 'Invoke-AdminPart|Start-FixItElevated|RunAs') 'no administrator rights are used'
Assert ($script:TestAllKeys -contains 'Display') 'Test-all checks the new button'
Assert ($srcText -match "ValidateSet\('Gui', 'TestAll'[^\]]*'Display'" -and $srcText -match "'Display'\s+\{ \[void\]\(Invoke-FixItAndShow -Which 'Display'\) \}") '-Action Display is accepted and runs it'
$plainText = (($a.Plan.Does + $a.Plan.Heads + @($help['Display'].Text, $dt[1], $dt[2])) -join ' ')
Assert ($plainText -notmatch '(?i)\b(WMI|CIM|registry|TDR|WHEA|kernel|PowerShell|script|DLL|admin|administrator)\b') 'no technical words in what the person reads on the button'

Section 'Fix my display: reading the screen'
$script:Cim = @{}
function Get-CimInstance { param($ClassName, $Namespace, $Filter, $ErrorAction) $k = $ClassName; if ($script:Cim.ContainsKey($k)) { $v = $script:Cim[$k]; if ($v -is [scriptblock]) { return (& $v) }; return $v }; throw ('no ' + $ClassName) }
$script:Ev = @{}; $script:EvCalls = New-Object System.Collections.ArrayList
function Get-FixItHwEventCount { param([string]$Provider, [int[]]$Ids = @(), [int]$Days = 7, [int[]]$Levels = @(), [string]$MessageLike = '', [string]$LogName = 'System') [void]$script:EvCalls.Add(('{0}|{1}|{2}|{3}' -f $Provider, ($Ids -join ','), $LogName, $Days)); if ($script:Ev.ContainsKey($Provider)) { $v = $script:Ev[$Provider]; if ($v -eq 'throw') { throw 'access denied' }; return [int]$v }; return 0 }
function New-Card { param($Name = 'NVIDIA GeForce GTX 1650', $Err = 0, $Ver = '31.0.15.5222', $Date = '20250312000000.000000-000') [pscustomobject]@{ Name = $Name; Status = 'OK'; ConfigManagerErrorCode = $Err; DriverVersion = $Ver; DriverDate = [datetime]'2025-03-12'; CurrentHorizontalResolution = 1366; CurrentVerticalResolution = 768; CurrentRefreshRate = 60 } }
$script:Cim['Win32_VideoController'] = @(New-Card)
$script:Cim['WmiMonitorConnectionParams'] = @([pscustomobject]@{ Active = $true; VideoOutputTechnology = 5 })
$modes = @([pscustomobject]@{ HorizontalActivePixels = 1366; VerticalActivePixels = 768; VerticalRefreshRateNumerator = 60; VerticalRefreshRateDenominator = 1 }, [pscustomobject]@{ HorizontalActivePixels = 1920; VerticalActivePixels = 1080; VerticalRefreshRateNumerator = 60000; VerticalRefreshRateDenominator = 1001 })
$script:Cim['WmiMonitorListedSupportedSourceModes'] = @([pscustomobject]@{ Active = $true; PreferredMonitorSourceModeIndex = 1; MonitorSourceModes = $modes })
$f = Get-FixItDisplayFacts
Assert (@($f.Cards).Count -eq 1 -and $f.Cards[0].Name -eq 'NVIDIA GeForce GTX 1650' -and $f.Cards[0].DriverVersion -eq '31.0.15.5222' -and $f.Cards[0].DriverDate -eq [datetime]'2025-03-12' -and $f.Cards[0].ErrorCode -eq 0) 'the card, its driver version and driver date are read'
Assert ($f.ScreenCount -eq 1 -and ($f.Connections -join ',') -eq 'HDMI') 'one screen on HDMI'
Assert ($f.Current.Width -eq 1366 -and $f.Current.Height -eq 768 -and $f.Recommended.Width -eq 1920 -and $f.Recommended.Height -eq 1080 -and $f.Recommended.Hz -eq 60) 'the current size and the screen''s preferred size (from its own preferred mode)'
Assert ($f.Resets -eq 0 -and $f.PowerLoss -eq 0 -and $f.Whea -eq 0 -and $f.LiveKernel -eq 0 -and $f.PlugEvents -eq 0) 'all counts are 0 on a quiet PC'
$calls = $script:EvCalls -join ' ; '
Assert ($calls -match 'Display\|4101\|System\|7' -and $calls -match 'nvlddmkm' -and $calls -match 'amdkmdag' -and $calls -match 'igfx') 'it counts Display 4101 and the nvlddmkm, amdkmdag and igfx entries for 7 days'
Assert ($calls -match 'Microsoft-Windows-Kernel-Power\|41\|' -and $calls -match 'WHEA-Logger' -and $calls -match 'Windows Error Reporting\|1001\|Application' -and $calls -match 'Kernel-PnP' -and $calls -match 'DeviceSetupManager') 'it also counts Kernel-Power 41, WHEA, LiveKernelEvent reports and screen plug/unplug entries'
$script:Ev = @{ 'Display' = 3; 'nvlddmkm' = 2; 'Microsoft-Windows-Kernel-Power' = 1; 'Microsoft-Windows-Kernel-PnP' = 4; 'Microsoft-Windows-DeviceSetupManager' = 3 }
$f = Get-FixItDisplayFacts
Assert ($f.Resets -eq 5 -and $f.PowerLoss -eq 1 -and $f.PlugEvents -eq 7) 'the counts add up across providers'
$script:Ev = @{ 'Display' = 'throw'; 'nvlddmkm' = 'throw'; 'amdkmdag' = 'throw'; 'igfx' = 'throw'; 'Microsoft-Windows-Kernel-Power' = 'throw' }
$f = Get-FixItDisplayFacts
Assert ($null -eq $f.Resets -and $null -eq $f.PowerLoss -and $f.Whea -eq 0) 'a count that cannot be read is "not available" (null), never an error'
$script:Ev = @{}
$script:Cim['WmiMonitorListedSupportedSourceModes'] = { throw 'not supported' }
$script:Cim['WmiMonitorConnectionParams'] = { throw 'not supported' }
$f = Get-FixItDisplayFacts
Assert ($null -eq $f.Recommended -and $null -eq $f.ScreenCount -and @($f.Notes).Count -eq 2 -and @($f.Cards).Count -eq 1) 'if the screen details are unavailable the rest still works'
$script:Cim['WmiMonitorConnectionParams'] = @([pscustomobject]@{ Active = $true; VideoOutputTechnology = 10 }, [pscustomobject]@{ Active = $true; VideoOutputTechnology = 2147483648 }, [pscustomobject]@{ Active = $false; VideoOutputTechnology = 0 })
$script:Cim['WmiMonitorListedSupportedSourceModes'] = @([pscustomobject]@{ Active = $true; PreferredMonitorSourceModeIndex = 1; MonitorSourceModes = $modes }, [pscustomobject]@{ Active = $true; PreferredMonitorSourceModeIndex = 0; MonitorSourceModes = $modes })
$f = Get-FixItDisplayFacts
Assert ($f.ScreenCount -eq 2 -and ($f.Connections -join ',') -eq 'DisplayPort,the laptop screen') 'two screens: a switched-off one is not counted, connection types are named in plain words'
Assert ($null -eq $f.Recommended) 'with more than one screen on, no size change is proposed (the main one cannot be told apart)'
Assert ((Get-FixItDisplayConnectionName -Code 0) -eq 'VGA' -and (Get-FixItDisplayConnectionName -Code 4) -eq 'DVI' -and (Get-FixItDisplayConnectionName -Code 5) -eq 'HDMI' -and (Get-FixItDisplayConnectionName -Code 11) -match 'DisplayPort' -and (Get-FixItDisplayConnectionName -Code 99) -eq '' -and (Get-FixItDisplayConnectionName -Code $null) -eq '') 'connection codes map to names; unknown ones to nothing'
$script:Cim['Win32_VideoController'] = @((New-Card -Name 'Microsoft Basic Display Adapter' -Err 0), (New-Card -Name 'Intel(R) UHD Graphics' -Err 43))
$f = Get-FixItDisplayFacts
Assert (@($f.Cards).Count -eq 2 -and $f.Cards[1].ErrorCode -eq 43 -and (Test-FixItBasicDisplay -Card $f.Cards[0]) -and -not (Test-FixItBasicDisplay -Card $f.Cards[1])) 'a card with an error code, and the basic Windows driver, are recognised'
$script:Cim['Win32_VideoController'] = { throw 'no WMI' }
$f = Get-FixItDisplayFacts
Assert (@($f.Cards).Count -eq 0 -and (@($f.Notes) -contains 'the graphics card')) 'no graphics card information: noted, no error'

Section 'Fix my display: what it looks like (plain words)'
function New-Facts { param($Cards = @([pscustomobject]@{ Name = 'NVIDIA'; ErrorCode = 0; DriverVersion = '1.0'; DriverDate = [datetime]'2025-03-12' }), $Screens = 1, $Resets = 0, $Plug = 0, $Power = 0, $Whea = 0, $Live = 0) [pscustomobject]@{ Cards = @($Cards); ScreenCount = $Screens; Connections = @('HDMI'); Current = $null; Recommended = $null; Resets = $Resets; PlugEvents = $Plug; PowerLoss = $Power; Whea = $Whea; LiveKernel = $Live; Notes = @() } }
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Resets 5)
Assert ($v.Kind -eq 'driver' -and $v.Text -eq 'The graphics driver keeps crashing and restarting.' -and $v.Suggestion -match 'update') 'driver resets: "the graphics driver keeps crashing and restarting", suggests a driver update'
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Resets 1)
Assert ($v.Kind -eq 'driver' -and $v.Text -match 'once') 'one reset is said as "once"'
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Plug 9)
Assert ($v.Kind -eq 'connection' -and $v.Text -eq 'The screen keeps losing its connection.' -and $v.Suggestion -match 'cable') 'many plug/unplug entries: "the screen keeps losing its connection", suggests the cable'
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Plug 2)
Assert ($v.Kind -eq 'none') 'a few plug entries (normal start-ups) are not a problem'
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Screens 0)
Assert ($v.Kind -eq 'connection') 'a graphics card but no screen found: connection'
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Cards @([pscustomobject]@{ Name = 'Microsoft Basic Display Adapter'; ErrorCode = 0; DriverVersion = '10'; DriverDate = $null }))
Assert ($v.Kind -eq 'driver') 'the basic Windows driver: driver'
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Cards @([pscustomobject]@{ Name = 'Intel'; ErrorCode = 43; DriverVersion = '10'; DriverDate = $null }))
Assert ($v.Kind -eq 'driver') 'a card with a Windows error code: driver'
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Resets 3 -Plug 9)
Assert ($v.Kind -eq 'both' -and $v.Text -match 'driver' -and $v.Suggestion -match 'cable') 'both: the driver first, and the cable as well'
$v = Get-FixItDisplayVerdict -Facts (New-Facts)
Assert ($v.Kind -eq 'none' -and $v.Text -match 'did not find' -and $v.Suggestion -match 'click this again') 'nothing found: says so and says what to do if it comes back'
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Power 2 -Whea 1)
Assert ($v.Extra -match '3 time' -and $v.Extra -match 'call Trey') 'sudden stops and hardware errors are added up in one short line'
$v = Get-FixItDisplayVerdict -Facts $null
Assert ($v.Kind -eq 'unknown') 'nothing could be read: says so'
$v = Get-FixItDisplayVerdict -Facts ([pscustomobject]@{ Cards = @(); ScreenCount = $null; Resets = $null; PlugEvents = $null })
Assert ($v.Kind -eq 'unknown') 'nothing could be read at all: unknown'
$all = @(@('keeps crashing', 'keeps losing', 'did not find', 'could not read') | ForEach-Object { $_ })
$words = ((Get-FixItDisplayVerdict -Facts (New-Facts -Resets 5)), (Get-FixItDisplayVerdict -Facts (New-Facts -Plug 9)), (Get-FixItDisplayVerdict -Facts (New-Facts)) | ForEach-Object { $_.Text + ' ' + $_.Suggestion }) -join ' '
Assert ($words -notmatch '(?i)\b(WHEA|TDR|WMI|event|kernel|nvlddmkm|registry|error code)\b') 'the verdicts use no technical words'

Section 'Fix my display: the lines'
$fx = New-Facts -Resets 4 -Plug 1 -Power 2; $fx.Current = [pscustomobject]@{ Width = 1366; Height = 768; Hz = 60 }; $fx.Recommended = [pscustomobject]@{ Width = 1920; Height = 1080; Hz = 60 }; $fx.LiveKernel = $null
$lines = @(Get-FixItDisplayLines -Facts $fx -Verdict (Get-FixItDisplayVerdict -Facts $fx))
$txt = $lines -join "`n"
Assert ($txt -match 'Graphics card: NVIDIA - working, driver 1\.0 from 12 Mar 2025') 'the card line has the driver version and date'
Assert ($txt -match 'Screens connected: 1 \(HDMI\)' -and $txt -match 'Screen size now: 1366 x 768 at 60 Hz' -and $txt -match 'Best size for this screen: 1920 x 1080') 'the screens, the connection type and the sizes are listed'
Assert ($txt -match 'crashes and restarts, last 7 days: 4' -and $txt -match 'Windows stopped suddenly \(power\), last 7 days: 2' -and $txt -match 'LiveKernelEvent\), last 7 days: not available') 'the counts are listed; an unreadable one says "not available"'
Assert ($lines[-2] -match '^It looks like: The graphics driver keeps crashing and restarting\.' -and $lines[-1] -match 'Windows also stopped suddenly') 'the plain verdict is near the end'
$lt = Get-FixItDisplayLines -Facts $null -Verdict $null
Assert (@($lt).Count -eq 1 -and @($lt)[0] -match 'could not be read') 'no facts: one short line'

Section 'Fix my display: the fix'
$script:Calls = New-Object System.Collections.ArrayList; $script:Answer = $true; $script:Asked = New-Object System.Collections.ArrayList
$script:CurFacts = $null
function Get-FixItDisplayFacts { return $script:CurFacts }
function Confirm-FixItStep { param([string]$Question) [void]$script:Asked.Add($Question); return $script:Answer }
function Send-FixItDisplayReset { [void]$script:Calls.Add('reset') }
function Set-FixItResolution { param([int]$Width, [int]$Height) [void]$script:Calls.Add(('size:{0}x{1}' -f $Width, $Height)) }
$script:TestMode = $false; $script:DryRun = $false
Start-FixItUndoRecord -Fix 'Display' -Title 'Fix my display'
$script:CurFacts = New-Facts -Resets 4; $script:CurFacts.Current = [pscustomobject]@{ Width = 1366; Height = 768; Hz = 60 }; $script:CurFacts.Recommended = [pscustomobject]@{ Width = 1920; Height = 1080; Hz = 60 }
$r = Invoke-DisplayFix
Assert ($r.Ok -and ($script:Calls -join ',') -eq 'size:1920x1080,reset') 'a screen that is not at its best size: asked, set to the best size, then the driver is restarted'
Assert ($script:Asked.Count -eq 1 -and $script:Asked[0] -match '1366 x 768' -and $script:Asked[0] -match '1920 x 1080') 'exactly one question, in plain words'
Assert ($r.Message -match 'keeps crashing and restarting' -and $r.Message -match 'update') 'the result says which it looks like and what to do'
Assert (($r.Details -join "`n") -match 'now set to its best size \(1920 x 1080\)' -and ($r.Details -join "`n") -match 'I restarted the graphics driver') 'the details say what was done'
$steps = @($script:UndoCur.Steps)
Assert ($steps.Count -eq 1 -and $steps[0].Kind -eq 'resolution' -and $steps[0].Width -eq 1366 -and $steps[0].Height -eq 768) 'the old size is saved as an undo step'
$script:Calls.Clear(); $script:Asked.Clear(); $script:Answer = $false
$r = Invoke-DisplayFix
Assert (($script:Calls -join ',') -eq 'reset' -and ($r.Details -join "`n") -match 'left as it is') 'saying No leaves the size alone; the driver is still restarted'
$script:Answer = $true; $script:Calls.Clear(); $script:Asked.Clear()
$script:CurFacts.Current = [pscustomobject]@{ Width = 1920; Height = 1080; Hz = 60 }
$r = Invoke-DisplayFix
Assert (($script:Calls -join ',') -eq 'reset' -and $script:Asked.Count -eq 0) 'already at the best size: no question, no change, only the driver restart'
$script:CurFacts = New-Facts
$script:Calls.Clear()
$r = Invoke-DisplayFix
Assert ($r.Ok -and $r.Message -match 'did not find' -and ($script:Calls -join ',') -eq 'reset') 'nothing wrong found: it still restarts the driver and says nothing was found'
$script:CurFacts = $null; $script:Calls.Clear()
$r = Invoke-DisplayFix
Assert ($r.Ok -and ($script:Calls -join ',') -eq 'reset' -and $r.Message -match 'cannot see enough') 'the details could not be read: the restart is still done'
$script:CurFacts = New-Facts -Plug 9; $script:Calls.Clear()
$r = Invoke-DisplayFix
Assert ($r.Message -match 'keeps losing its connection' -and $r.Message -match 'cable') 'a connection problem is described as that'
function Send-FixItDisplayReset { throw 'Windows did not accept the key presses' }
$r = Invoke-DisplayFix
Assert ($r.Ok -and ($r.Details -join "`n") -match 'could not restart the graphics driver' -and (Get-Log) -match 'Windows did not accept') 'if the key presses fail: said plainly and logged, no crash'
function Send-FixItDisplayReset { [void]$script:Calls.Add('reset') }
$script:CurFacts = New-Facts -Resets 2; $script:CurFacts.Current = [pscustomobject]@{ Width = 1366; Height = 768; Hz = 60 }; $script:CurFacts.Recommended = [pscustomobject]@{ Width = 1920; Height = 1080; Hz = 60 }
$script:Calls.Clear(); $script:Asked.Clear(); $script:DryRun = $true
$r = Invoke-DisplayFix
Assert ($r.Title -eq 'Practice run' -and $script:Calls.Count -eq 0) 'practice mode: nothing is changed'
$script:DryRun = $false
function Set-FixItResolution { param([int]$Width, [int]$Height) throw 'Windows would not use it' }
$script:Calls.Clear(); $script:Answer = $true
$r = Invoke-DisplayFix
Assert (($r.Details -join "`n") -match 'could not change the screen size' -and ($script:Calls -join ',') -eq 'reset') 'if Windows refuses the size, it says so and still restarts the driver'
function Set-FixItResolution { param([int]$Width, [int]$Height) [void]$script:Calls.Add(('size:{0}x{1}' -f $Width, $Height)) }

Section 'Fix my display: undo'
$script:Calls.Clear()
$ok = Invoke-FixItUndoSteps -Steps @([pscustomobject]@{ Kind = 'resolution'; Width = 1366; Height = 768 })
Assert ($ok -and ($script:Calls -join ',') -eq 'size:1366x768') 'undo puts the old screen size back'
Assert ((Get-Fn 'Invoke-FixItUndoSteps') -match "'resolution'") 'undo knows the resolution step'

Section 'Fix my display: Test mode (nothing changes; each step is checked)'
Remove-Item Function:\Send-FixItDisplayReset, Function:\Set-FixItResolution, Function:\Confirm-FixItStep, Function:\Get-FixItDisplayFacts -ErrorAction SilentlyContinue
. $src -LibraryOnly -LogPath $tLogFile -OutputDir $outDir
Initialize-FixItLog
$script:CurFacts = New-Facts -Resets 2; $script:CurFacts.Current = [pscustomobject]@{ Width = 1366; Height = 768; Hz = 60 }; $script:CurFacts.Recommended = [pscustomobject]@{ Width = 1920; Height = 1080; Hz = 60 }
function Get-FixItDisplayFacts { return $script:CurFacts }
function Get-FixItDisplayModes { return @('1024,768,60', '1366,768,60', '1920,1080,60') }
function Confirm-FixItStep { param([string]$Question) return $true }
$script:RawKeys = 0
$script:TestMode = $true; $script:DryRun = $true; $script:InProbe = $false
Start-FixItTestButton
$r = Invoke-DisplayFix
$steps2 = @(Get-FixItTestRecords)
$recs = @($steps2 | ForEach-Object { $_.Checks } | Where-Object { $null -ne $_ })
Assert ($steps2.Count -eq 2 -and @($steps2 | Where-Object { $_.Status -eq 'FAIL' }).Count -eq 0) 'Test mode checks both steps (the size and the restart) and neither fails'
Assert (@($recs | Where-Object { $_.Text -match 'no check is written' }).Count -eq 0) 'both adapters have their own check'
Assert ((($recs | ForEach-Object { $_.Text }) -join ' ') -match '1920 x 1080 as a size it can show' -and (($recs | ForEach-Object { $_.Text }) -join ' ') -match 'no administrator needed') 'the checks say what was looked at'
function Get-FixItDisplayModes { return @('1024,768,60') }
Start-FixItTestButton
$r = Invoke-DisplayFix
$recs = @(@(Get-FixItTestRecords) | ForEach-Object { $_.Checks } | Where-Object { $null -ne $_ })
Assert (@($recs | Where-Object { $_.Status -eq 'FAIL' -and $_.Text -match 'does not list 1920 x 1080' }).Count -eq 1) 'a size the screen does not list fails the check, before anything is changed'
$script:TestMode = $false; $script:DryRun = $false
Assert ((Get-Fn 'Send-FixItDisplayReset') -match '^function Send-FixItDisplayReset \{\s+if \(\$script:TestMode\)' -and (Get-Fn 'Set-FixItResolution') -match 'if \(\$script:TestMode\) \{ Invoke-FixItProbe') 'both changing adapters end first in Test mode'
foreach ($fn in @('Get-FixItDisplayFacts', 'Get-FixItDisplayModes', 'Confirm-FixItStep', 'Get-CimInstance', 'Get-FixItHwEventCount')) { Remove-Item "Function:\$fn" -ErrorAction SilentlyContinue }
. $src -LibraryOnly -LogPath $tLogFile -OutputDir $outDir
Initialize-FixItLog

Section 'Fix my display: the real key presses and screen change (program text; the real run needs Windows)'
$cs = (Get-Fn 'Initialize-FixItDisplay')
Assert ($cs -match 'SendInput' -and $cs -match 'ChangeDisplaySettings' -and $cs -match 'EnumDisplaySettings') 'it uses the Windows calls for key presses and screen sizes'
Assert ($cs -match '0x5B, 0x11, 0x10, 0x42') 'the keys are Windows, Ctrl, Shift and B'
Assert ($cs -match 'finally' -and $cs -match 'Key\(keys\[j\], true\)') 'every key that was pressed is let go again, even if something fails'
Assert ($cs -match 'ChangeDisplaySettings\(ref best, 2\)' -and $cs.IndexOf('ChangeDisplaySettings(ref best, 2)') -lt $cs.IndexOf('ChangeDisplaySettings(ref best, 1)')) 'a new size is tested with Windows before it is applied'
Assert ($cs -match 'found' -and $cs -match 'return -101') 'only a size the screen lists is ever tried'
$typeOk = $true; try { Initialize-FixItDisplay; $typeOk = [bool]('FixItDisplay' -as [type]) } catch { $typeOk = $false; Write-Host ('    ' + $_.Exception.Message) }
Assert $typeOk 'the small helper program compiles'
if ($typeOk) { Assert ([FixItDisplay].GetMethod('Reset') -and [FixItDisplay].GetMethod('SetMode') -and [FixItDisplay].GetMethod('Modes')) 'it offers Reset, SetMode and Modes' }
Assert ((Get-Fn 'Send-FixItDisplayReset') -match 'Wait-FixIt' -and (Get-Fn 'Send-FixItDisplayReset') -notmatch 'Start-Sleep') 'waiting after the restart uses the program''s own wait'

Section 'Fix my display: in the report'
$script:Cim = @{}
function Get-CimInstance { param($ClassName, $Namespace, $Filter, $ErrorAction) throw 'no WMI here' }
function Get-FixItDisplayFacts { return (New-Facts -Resets 4) }
$rl = @(Get-FixItDisplayReportLines)
Assert (($rl -join "`n") -match 'Graphics card: NVIDIA' -and ($rl -join "`n") -match 'It looks like: The graphics driver keeps crashing') 'the report lines have the card, the counts and what it looks like'
$rt = [string](Get-Fn 'Get-FixItReportText')
Assert ($rt -match "Add-ReportSection \`$o 'Display \(screen flicker or going black\)'" -and $rt.IndexOf("'Display (screen flicker") -gt $rt.IndexOf("'Hardware'") -and $rt.IndexOf("'Display (screen flicker") -lt $rt.IndexOf("'Recent errors - System log")) 'the report has a Display section'
function Get-FixItDisplayFacts { throw 'boom' }
$rl = @(Get-FixItDisplayReportLines)
Assert ($rl.Count -eq 1 -and $rl[0] -match 'not available') 'if the display cannot be read, the report says "not available" and carries on'
Remove-Item Function:\Get-FixItDisplayFacts, Function:\Get-CimInstance -ErrorAction SilentlyContinue

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('Passed: {0}   Failed: {1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
