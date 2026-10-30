# Version 2.3.10 tests: the pop-up watcher (Guardian) never stays on an old version after an update, and the "?" help window (and every
# other window with wrapped text) is sized to fit its text.
# Drawing and real processes need Windows, so these use the REAL program functions with pretend adapters and pretend measuring, plus checks of the program text.
# Usage:  pwsh ./tests/Test-FixIt-V2310.ps1       (Test-FixIt.ps1 runs this one too and adds its numbers)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fixit-v2310-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:Pass = 0; $script:Fail = 0
function Assert { param([bool]$Cond, [string]$Name) if ($Cond) { $script:Pass++ } else { $script:Fail++; Write-Host ('  FAIL: ' + $Name) -ForegroundColor Red } }
function Section { param([string]$T) Write-Host ('== ' + $T) }

$src = Join-Path $root 'FamilyFixIt.ps1'
$outDir = Join-Path $tmp 'out'; New-Item -ItemType Directory -Path $outDir | Out-Null
$env:LOCALAPPDATA = Join-Path $tmp 'local'; New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
$env:COMPUTERNAME = 'TESTPC'
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v2310.log') -OutputDir $outDir
Initialize-FixItLog
function Get-Log { $t = ''; foreach ($n in @('v2310', 'v2310b', 'v2310c', 'v2310d')) { $f = Join-Path $tmp ($n + '.log'); if (Test-Path -LiteralPath $f) { $t += [IO.File]::ReadAllText($f) } }; return $t }
$srcText = [IO.File]::ReadAllText($src)
$tokens = $null; $perr = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$perr)
function Get-Fn { param([string]$Name) $f = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1; if ($null -eq $f) { return '' }; return $f.Extent.Text }

Assert ([version]$script:FixItVersion -ge [version]'2.3.10') 'the program is version 2.3.10 or newer'

# ================================================================ 1. reading the installed version
Section 'Watcher: reading the installed version'
$vf = Join-Path $tmp 'ver.ps1'
[IO.File]::WriteAllText($vf, "# header`r`n`$script:Other = 1`r`n`$script:FixItVersion = '2.3.10'`r`n")
Assert ((Get-FixItScriptVersion -Path $vf) -eq '2.3.10') 'the version is read from the program file'
[IO.File]::WriteAllText($vf, "`$script:FixItVersion = `"2.3.10`"`r`n")
Assert ((Get-FixItScriptVersion -Path $vf) -eq '') 'a line that does not look right gives no version (never a guess)'
Assert ((Get-FixItScriptVersion -Path (Join-Path $tmp 'missing.ps1')) -eq '') 'a missing file gives no version and does not throw'
[IO.File]::WriteAllText($vf, '')
Assert ((Get-FixItScriptVersion -Path $vf) -eq '') 'an empty file (half written) gives no version'
Assert ((Get-FixItScriptVersion -Path $src) -eq $script:FixItVersion) 'the real program file reports its own version'
$big = Join-Path $tmp 'big.ps1'
[IO.File]::WriteAllText($big, ((1..400 | ForEach-Object { '# line ' + $_ }) -join "`r`n") + "`r`n`$script:FixItVersion = '9.9.9'`r`n")
Assert ((Get-FixItScriptVersion -Path $big) -eq '') 'only the top of the file is read (a version far down is not trusted)'

# ================================================================ 2. the decisions (pure)
Section 'Watcher: is it out of date?'
Assert (Test-FixItGuardianVersionStale -Running '2.3.9' -Installed '2.3.10') 'older than the installed program: start over'
Assert (Test-FixItGuardianVersionStale -Running '2.3.10' -Installed '2.3.9') 'newer than the installed program (rolled back): start over too'
Assert (-not (Test-FixItGuardianVersionStale -Running '2.3.10' -Installed '2.3.10')) 'the same version: nothing to do'
Assert (-not (Test-FixItGuardianVersionStale -Running '2.3.10' -Installed '')) 'the installed version cannot be read: do nothing'
Assert (-not (Test-FixItGuardianVersionStale -Running '' -Installed '2.3.10')) 'our own version is unknown: do nothing'
Assert (-not (Test-FixItGuardianVersionStale -Running '2.3.10' -Installed 'banana')) 'a damaged version text: do nothing'
Assert (Test-FixItGuardianVersionStale -Running '2.3.9' -Installed '2.3.10') '2.3.9 versus 2.3.10 is compared as numbers (10 is bigger than 9)'
$t0 = [datetime]'2026-10-30 10:00:00'
Assert (-not (Test-FixItGuardianVersionCheckDue -Last $t0 -Now $t0.AddMinutes(4.9) -Minutes 5)) 'not due before 5 minutes'
Assert (Test-FixItGuardianVersionCheckDue -Last $t0 -Now $t0.AddMinutes(5) -Minutes 5) 'due after 5 minutes'
Assert (Test-FixItGuardianVersionCheckDue -Last ([datetime]::MinValue) -Now $t0 -Minutes 5) 'never checked: due'
Assert ($script:GuardianVersionCheckMinutes -ge 1 -and $script:GuardianVersionCheckMinutes -le 10) 'the check runs every few minutes'
$fileT = [datetime]'2026-10-30 22:30:00'
Assert (Test-FixItGuardianOlderThanFile -Started @([datetime]'2026-10-29 22:06:00') -FileTime $fileT) 'a watcher that started the evening before the update is old (the real case: started 10:06 PM)'
Assert (-not (Test-FixItGuardianOlderThanFile -Started @([datetime]'2026-10-30 22:31:00') -FileTime $fileT)) 'a watcher that started after the file was written is current'
Assert (-not (Test-FixItGuardianOlderThanFile -Started @([datetime]'2026-10-30 22:29:59') -FileTime $fileT)) 'a start within 2 seconds of the file is current (slack)'
Assert (Test-FixItGuardianOlderThanFile -Started @([datetime]'2026-10-30 22:31:00', [datetime]'2026-10-29 22:06:00') -FileTime $fileT) 'if any watcher is old, that is enough'
Assert (-not (Test-FixItGuardianOlderThanFile -Started @() -FileTime $fileT)) 'no watcher running: nothing is old'
Assert (-not (Test-FixItGuardianOlderThanFile -Started @([datetime]'2026-10-29 22:06:00') -FileTime $null)) 'the file time is unknown: do nothing'
Assert (-not (Test-FixItGuardianOlderThanFile -Started @($null) -FileTime $fileT)) 'a start time that is unknown is ignored'
Assert (Test-FixItOwnSession ([pscustomobject]@{ ProcessId = 1 })) 'a process with no session information counts as ours'
$mySid = (Get-Process -Id $PID).SessionId
Assert (Test-FixItOwnSession ([pscustomobject]@{ SessionId = $mySid })) 'the same Windows session is ours'
Assert (-not (Test-FixItOwnSession ([pscustomobject]@{ SessionId = ($mySid + 7) }))) 'another Windows session (another signed-in person) is never touched'

# ================================================================ 3. the watcher checks itself
Section 'Watcher: checks itself every few minutes and starts over'
$script:InstalledVersionFake = '2.3.10'
function Get-FixItScriptVersion { param([string]$Path) return $script:InstalledVersionFake }
$script:FixItVersion = '2.3.10'; $script:GRelaunch = $false
$r = Invoke-GuardianVersionCheck -Now $t0
Assert (-not $r -and -not $script:GRelaunch -and $script:GLastVersionCheck -eq $t0) 'same version: no change, and the time of the check is remembered'
$script:InstalledVersionFake = '2.3.11'
$r = Invoke-GuardianVersionCheck -Now $t0.AddMinutes(5)
Assert ($r -and $script:GRelaunch -and $script:GLastVersionCheck -eq $t0.AddMinutes(5)) 'a different installed version: this watcher is told to hand over'
Assert ((Get-Log) -match 'running version 2\.3\.10 but the installed program is 2\.3\.11') 'the hand-over is logged with both versions'
$script:InstalledVersionFake = ''
$script:GRelaunch = $false
$r = Invoke-GuardianVersionCheck -Now $t0.AddMinutes(10)
Assert (-not $r -and -not $script:GRelaunch) 'an unreadable installed file never makes a watcher quit'
Remove-Item Function:\Get-FixItScriptVersion
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v2310b.log') -OutputDir $outDir; Initialize-FixItLog
$tk = Get-Fn 'Invoke-GuardianTick'
$iStop = $tk.IndexOf('Test-FixItGuardianStopRequested'); $iVer = $tk.IndexOf('Invoke-GuardianVersionCheck'); $iFg = $tk.IndexOf('Get-FixItForeground'); $iBusy = $tk.IndexOf('$script:GBusy')
Assert ($iBusy -ge 0 -and $iVer -gt $iBusy -and $iVer -gt $iStop -and $iVer -lt $iFg) 'each look: busy toast first (never interrupted), then the stop signal, then the version check, then the screen look'
Assert ($tk -match 'Test-FixItGuardianVersionCheckDue' -and $tk -match 'GuardianVersionCheckMinutes' -and $tk -match 'ExitThread' -and $tk -match 'Close-FixItGuardianToast') 'the check is rate limited and ends the loop cleanly'
$run = Get-Fn 'Invoke-GuardianRun'
Assert ($run.IndexOf('Release-FixItGuardianMutex') -lt $run.IndexOf('Start-FixItGuardianProcess -Path') -and $run -match 'GRelaunch') 'the fresh watcher is started only AFTER the lock is released (so it can take it)'
Assert ($run -match 'Get-FixItInstalledScriptPath') 'the fresh watcher starts from the installed program'

# the whole run with pretend adapters
$script:Order = New-Object System.Collections.ArrayList
function Enter-FixItGuardianMutex { [void]$script:Order.Add('mutex'); return $(if ($script:MutexBusy) { $null } else { [pscustomobject]@{ } }) }
function Release-FixItGuardianMutex { param($Mutex) [void]$script:Order.Add('release') }
function Initialize-FixItGuardianNative { [void]$script:Order.Add('native') }
function New-FixItGuardianStopEvent { $e = [pscustomobject]@{ D = 0 }; $e | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.D++ }; return $e }
function New-FixItGuardianHotkey { return $null }
function New-FixItGuardianTray { return $null }
function Remove-FixItGuardianTray { }
function Start-FixItGuardianLoop { [void]$script:Order.Add('loop'); if ($script:AskRelaunch) { $script:GRelaunch = $true } }
function Start-FixItGuardianProcess { param([string]$Path = '') [void]$script:Order.Add('start:' + $Path) }
$script:DryRun = $false; $script:TestMode = $false; $script:MutexBusy = $false; $script:AskRelaunch = $false
$script:InstallDir = Join-Path $tmp 'installed'
$r = Invoke-GuardianRun
Assert (($script:Order -join ',') -eq 'mutex,native,loop,release') 'a normal stop starts nothing new'
$script:Order.Clear(); $script:AskRelaunch = $true
$r = Invoke-GuardianRun
$want = 'mutex,native,loop,release,start:' + (Join-Path $script:InstallDir 'FamilyFixIt.ps1')
Assert (($script:Order -join ',') -eq $want) 'a hand-over: the old one releases the lock, then one fresh watcher is started from the installed path'
Assert (-not $script:GRelaunch) 'the hand-over flag is cleared (it cannot repeat)'
$script:Order.Clear(); $script:AskRelaunch = $false; $script:MutexBusy = $true; $script:GRelaunch = $true
$r = Invoke-GuardianRun
Assert (($script:Order -join ',') -eq 'mutex') 'a second copy that finds the lock taken stops at once and starts nothing (single instance)'
$script:MutexBusy = $false; $script:GRelaunch = $false
function Start-FixItGuardianProcess { param([string]$Path = '') throw 'cannot start' }
$script:AskRelaunch = $true; $script:Order.Clear()
$threw = $false; try { [void](Invoke-GuardianRun) } catch { $threw = $true }
Assert (-not $threw -and (Get-Log) -match 'could not start the fresh watcher') 'if the fresh watcher cannot be started, it is logged and nothing crashes (it comes back at the next sign-in or window)'
$script:AskRelaunch = $false
foreach ($fn in @('Enter-FixItGuardianMutex', 'Release-FixItGuardianMutex', 'Initialize-FixItGuardianNative', 'New-FixItGuardianStopEvent', 'New-FixItGuardianHotkey', 'New-FixItGuardianTray', 'Remove-FixItGuardianTray', 'Start-FixItGuardianLoop', 'Start-FixItGuardianProcess')) { Remove-Item "Function:\$fn" -ErrorAction SilentlyContinue }
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v2310c.log') -OutputDir $outDir; Initialize-FixItLog

# ================================================================ 4. restart after an update
Section 'Restart the watcher: stop, then one fresh one from the installed path'
$script:InstallDir = Join-Path $tmp 'inst2'; New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
$instPs1 = Join-Path $script:InstallDir 'FamilyFixIt.ps1'
$script:Calls = New-Object System.Collections.ArrayList
$script:Running = $true
function Stop-FixItGuardianProcess { [void]$script:Calls.Add('stop'); if (-not $script:CannotStop) { $script:Running = $false } }
function Test-FixItGuardianRunning { return $script:Running }
function Start-FixItGuardianProcess { param([string]$Path = '') [void]$script:Calls.Add('start:' + $Path); $script:Running = $true }
$script:CannotStop = $false; $script:DryRun = $false; $script:TestMode = $false
$r = Restart-FixItGuardian -Why 'update'
Assert (-not $r -and $script:Calls.Count -eq 0) 'the installed program is not there: nothing is stopped or started'
[IO.File]::WriteAllText($instPs1, "`$script:FixItVersion = '2.3.10'`r`n")
$script:Calls.Clear(); $script:Running = $true
$r = Restart-FixItGuardian -Why 'update'
Assert ($r -and ($script:Calls -join ',') -eq ('stop,start:' + $instPs1)) 'a running watcher is stopped, then exactly one is started from the installed path'
$script:Calls.Clear(); $script:Running = $false
$r = Restart-FixItGuardian
Assert (($script:Calls -join ',') -eq ('stop,start:' + $instPs1)) 'no watcher was running: still one fresh one (idempotent)'
$script:Calls.Clear(); $script:Running = $true; $script:CannotStop = $true
$r = Restart-FixItGuardian
Assert (($script:Calls -join ',') -eq 'stop') 'if the old one could not be stopped, a second one is not started (the lock allows only one)'
$script:CannotStop = $false
$script:Calls.Clear(); $script:Running = $true; $script:DryRun = $true
$r = Restart-FixItGuardian
Assert ($script:Calls.Count -eq 0) 'practice mode: nothing is stopped or started'
$script:DryRun = $false

Section 'Restart the watcher: only when it is old'
function Get-FixItInstalledFileTime { return $script:FakeFileTime }
function Get-FixItGuardianStarted { return @($script:FakeStarted) }
$script:FakeFileTime = [datetime]'2026-10-30 22:30:00'
$script:FakeStarted = @([datetime]'2026-10-29 22:06:00'); $script:Calls.Clear(); $script:Running = $true
Assert ((Update-FixItGuardianIfOld) -eq 'Restarted' -and ($script:Calls -join ',') -eq ('stop,start:' + $instPs1)) 'a watcher from before the update is replaced'
$script:FakeStarted = @([datetime]'2026-10-30 22:35:00'); $script:Calls.Clear(); $script:Running = $true
Assert ((Update-FixItGuardianIfOld) -eq 'Current' -and $script:Calls.Count -eq 0) 'a watcher that started after the update is left alone'
$script:FakeFileTime = $null; $script:FakeStarted = @([datetime]'2026-10-29 22:06:00'); $script:Calls.Clear()
Assert ((Update-FixItGuardianIfOld) -eq 'Current' -and $script:Calls.Count -eq 0) 'the file time is unknown: left alone'
$script:FakeFileTime = [datetime]'2026-10-30 22:30:00'

Section 'Window start and turning on: an old running watcher is replaced, a new one is not touched'
$script:State = @{}
function Get-FixItSetting { param([string]$Name, [string]$Default = '') if ($script:State.ContainsKey($Name)) { return [string]$script:State[$Name] }; return $Default }
function Set-FixItSetting { param([string]$Name, [string]$Value) $script:State[$Name] = $Value }
$script:Installed = $true
function Test-FixItGuardianInstalled { return $script:Installed }
$script:State = @{ Guardian = '1' }; $script:Running = $true; $script:Calls.Clear()
$script:FakeStarted = @([datetime]'2026-10-29 22:06:00')
Initialize-FixItGuardianDefault
Assert (($script:Calls -join ',') -eq ('stop,start:' + $instPs1)) 'opening the window with the old watcher still running (the real 2.3.9 case): it is replaced by a fresh one'
$script:Calls.Clear(); $script:FakeStarted = @([datetime]'2026-10-30 23:00:00')
Initialize-FixItGuardianDefault
Assert ($script:Calls.Count -eq 0) 'opening the window with a current watcher running: nothing happens (no duplicate)'
$script:Calls.Clear(); $script:Running = $false
Initialize-FixItGuardianDefault
Assert (($script:Calls -join ',') -eq 'start:') 'opening the window with no watcher: one is started (as before)'
$script:State = @{ Guardian = '0' }; $script:Running = $true; $script:Calls.Clear(); $script:FakeStarted = @([datetime]'2026-10-29 22:06:00')
Initialize-FixItGuardianDefault
Assert ($script:Calls.Count -eq 0) 'if the person turned the watcher off, an old one is not restarted by this'
$script:State = @{ Guardian = '1' }; $script:Running = $true; $script:Calls.Clear()
function Set-RegString { param($Path, $Name, $Value) }
$null = Invoke-GuardianToggle -Mode 'On'
Assert (($script:Calls -join ',') -eq ('stop,start:' + $instPs1)) 'GuardianOn (the installer uses it) also replaces an old running watcher'
$script:Calls.Clear(); $script:FakeStarted = @([datetime]'2026-10-30 23:00:00')
$null = Invoke-GuardianToggle -Mode 'On'
Assert ($script:Calls.Count -eq 0) 'GuardianOn with a current watcher running: no second one'
Remove-Item Function:\Set-RegString -ErrorAction SilentlyContinue

Section 'In-app update restarts the watcher'
$ud = Join-Path $tmp 'upd'; New-Item -ItemType Directory -Path $ud -Force | Out-Null
$script:InstallDir = Join-Path $ud 'installed'; New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $script:InstallDir 'FamilyFixIt.ps1'), "`$script:FixItVersion = '2.3.9'`r`n")
$fixture = Join-Path $ud 'new.ps1'
[IO.File]::WriteAllText($fixture, "`$script:FixItVersion = '9.9.9'`r`n")
$hash = Get-FileSha256 -Path $fixture
$man = [pscustomobject]@{ Version = [version]'9.9.9'; BaseUrl = 'https://example.test/'; Files = @([pscustomobject]@{ path = 'FamilyFixIt.ps1'; sha256 = $hash }) }
function Save-WebFile { param([string]$Url, [string]$Dest) New-Item -ItemType Directory -Path (Split-Path $Dest) -Force | Out-Null; Copy-Item -LiteralPath $fixture -Destination $Dest -Force }
function Close-FixItOtherGuiWindows { param($Why) return 0 }
function Update-FixItShortcutIcons { return 0 }
$script:Restarts = 0; $script:RestartThrows = $false
function Restart-FixItGuardian { param([string]$Why = 'update') $script:Restarts++; if ($script:RestartThrows) { throw 'boom' }; return $true }
$script:State = @{ Guardian = '1' }; $script:Running = $true; $script:Installed = $true; $script:DryRun = $false; $script:TestMode = $false
Install-FixItUpdate -Manifest $man
Assert ($script:Restarts -eq 1) 'the update restarts the running watcher once'
Assert ([IO.File]::ReadAllText((Join-Path $script:InstallDir 'FamilyFixIt.ps1')) -match '9\.9\.9') 'the new program file was installed (the fixture update really ran)'
$script:Restarts = 0; $script:Running = $false; $script:Installed = $true
Install-FixItUpdate -Manifest $man
Assert ($script:Restarts -eq 1) 'a watcher that is switched on but not running is started by the update'
$script:Restarts = 0; $script:Running = $false; $script:Installed = $false
Install-FixItUpdate -Manifest $man
Assert ($script:Restarts -eq 0) 'no watcher and no startup entry: the update starts nothing'
$script:Restarts = 0; $script:Running = $true; $script:Installed = $true; $script:State = @{ Guardian = '0' }
Install-FixItUpdate -Manifest $man
Assert ($script:Restarts -eq 0) 'the person turned the watcher off: the update leaves it off'
$script:Restarts = 0; $script:Running = $true; $script:State = @{ Guardian = '1' }; $script:RestartThrows = $true
$threw = $false; try { Install-FixItUpdate -Manifest $man } catch { $threw = $true }
Assert (-not $threw -and (Get-Log) -match 'Could not restart the pop-up watcher') 'if restarting the watcher fails, the update still finishes (logged)'
$script:RestartThrows = $false
$script:Restarts = 0
$man2 = [pscustomobject]@{ Version = [version]'9.9.9'; BaseUrl = 'https://example.test/'; Files = @() }
Install-FixItUpdate -Manifest $man2
Assert ($script:Restarts -eq 0) 'an update that does not replace the program file does not restart the watcher'
foreach ($fn in @('Save-WebFile', 'Close-FixItOtherGuiWindows', 'Update-FixItShortcutIcons', 'Restart-FixItGuardian', 'Stop-FixItGuardianProcess', 'Test-FixItGuardianRunning', 'Start-FixItGuardianProcess', 'Get-FixItInstalledFileTime', 'Get-FixItGuardianStarted', 'Get-FixItSetting', 'Set-FixItSetting', 'Test-FixItGuardianInstalled')) { Remove-Item "Function:\$fn" -ErrorAction SilentlyContinue }
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v2310d.log') -OutputDir $outDir; Initialize-FixItLog

Section 'Stopping the watcher: only this user'
$me = (Get-Process -Id $PID).SessionId
$script:Sig = New-Object System.Collections.ArrayList
$script:Procs = @(
    [pscustomobject]@{ ProcessId = 8001; SessionId = $me; CommandLine = 'powershell.exe -File "C:\x\FamilyFixIt.ps1" -Action Guardian' },
    [pscustomobject]@{ ProcessId = 8002; SessionId = ($me + 5); CommandLine = 'powershell.exe -File "C:\y\FamilyFixIt.ps1" -Action Guardian' },
    [pscustomobject]@{ ProcessId = 8003; SessionId = $me; CommandLine = 'powershell.exe -File "C:\x\FamilyFixIt.ps1"' })
function Get-CimInstance { param($ClassName, $Filter, $ErrorAction) return $script:Procs }
function Stop-Process { param($Id, [switch]$Force, $ErrorAction) [void]$script:Sig.Add('kill:' + $Id) }
function Send-FixItGuardianStopSignal { return $false }
function Wait-FixItGuardianGone { param([int]$Seconds = 6) return $false }
Stop-FixItGuardianProcess
Assert (($script:Sig -join ',') -eq 'kill:8001') 'only this person''s watcher is stopped (another signed-in person''s is not, nor the normal window)'
$script:Sig.Clear()
$script:Procs = @([pscustomobject]@{ ProcessId = 8101; CommandLine = 'powershell.exe -File "C:\x\FamilyFixIt.ps1" -Action Guardian'; CreationDate = [datetime]'2026-10-29 22:06:00' }, [pscustomobject]@{ ProcessId = 8102; SessionId = ($me + 5); CommandLine = 'powershell.exe -File "C:\x\FamilyFixIt.ps1" -Action Guardian'; CreationDate = [datetime]'2026-10-01 10:00:00' })
$st = @(Get-FixItGuardianStarted)
Assert ($st.Count -eq 1 -and $st[0] -eq [datetime]'2026-10-29 22:06:00') 'the start times come from this user''s watchers only'
function Get-CimInstance { throw 'no WMI here' }
Assert (@(Get-FixItGuardianStarted).Count -eq 0) 'if Windows cannot list the processes, there is nothing old to replace (no crash)'
foreach ($fn in @('Get-CimInstance', 'Stop-Process', 'Send-FixItGuardianStopSignal', 'Wait-FixItGuardianGone')) { Remove-Item "Function:\$fn" -ErrorAction SilentlyContinue }

Section 'Watcher: plain, no administrator, one copy'
$newNames = @('Get-FixItInstalledScriptPath', 'Get-FixItScriptVersion', 'Test-FixItGuardianVersionStale', 'Test-FixItGuardianVersionCheckDue', 'Invoke-GuardianVersionCheck', 'Get-FixItGuardianStarted', 'Get-FixItInstalledFileTime', 'Test-FixItGuardianOlderThanFile', 'Test-FixItOwnSession', 'Restart-FixItGuardian', 'Update-FixItGuardianIfOld')
$newText = ($newNames | ForEach-Object { Get-Fn $_ }) -join "`n"
Assert ($newNames.Count -eq 11 -and (@($newNames | Where-Object { (Get-Fn $_) -eq '' }).Count -eq 0)) 'all the new watcher functions exist'
Assert ($newText -notmatch 'Start-FixItElevated|Invoke-AdminPart|RunAs|-Verb|schtasks|HKLM|Set-Service|sc\.exe') 'none of the new watcher code asks for administrator rights'
Assert ($newText -notmatch '\?\?|\?\.|\sPSVersion\s' -and $newText -notmatch '(?m)\?\s+[^\s]+\s+:\s+') 'no PowerShell 7-only syntax in the new watcher code'
Assert ((Get-Fn 'Restart-FixItGuardian') -match 'Invoke-FixItStep' -and (Get-Fn 'Restart-FixItGuardian') -match 'Test-FixItGuardianRunning') 'restarting is a logged step, and never starts a second watcher while one is still running'
Assert ((Get-Fn 'Start-FixItGuardianProcess') -match '\[string\]\$Path' -and (Get-Fn 'Start-FixItGuardianProcess') -match '-WindowStyle.*Hidden' -and (Get-Fn 'Start-FixItGuardianProcess') -match '-Action.*Guardian' -and (Get-Fn 'Start-FixItGuardianProcess') -match 'TestMode') 'the watcher is started hidden from the path it is given (the installed file), and Test mode only probes'
Assert ((Get-Fn 'Enter-FixItGuardianMutex') -match 'Mutex' -and $srcText -match "GuardianMutexName = 'Local\\FamilyFixItGuardian'") 'the single-instance lock is still the same named lock'
Assert ((Get-Fn 'Stop-FixItGuardianProcess') -match 'Test-FixItOwnSession') 'stopping looks at this user only'
Assert ((Get-Fn 'Install-FixItUpdate') -match 'Restart-FixItGuardian' -and (Get-Fn 'Install-FixItUpdate').IndexOf('Restart-FixItGuardian') -gt (Get-Fn 'Install-FixItUpdate').IndexOf('Copy-Item -LiteralPath (Join-Path $stage') -and (Get-Fn 'Install-FixItUpdate') -match "Get-FixItSetting -Name 'Guardian'") 'the update restarts the watcher after the files are in place and respects an off switch'
Assert ((Get-Fn 'Initialize-FixItGuardianDefault') -match 'Update-FixItGuardianIfOld' -and (Get-Fn 'Invoke-GuardianToggle') -match 'Update-FixItGuardianIfOld') 'the window start and GuardianOn both replace an old watcher'
$inst = [IO.File]::ReadAllText((Join-Path $root 'Install-FixIt.ps1'))
Assert ($inst -match "'GuardianOff'" -and $inst -match "'GuardianOn'" -and $inst.IndexOf("'GuardianOff'") -lt $inst.IndexOf("'GuardianOn'")) 'the installer still turns the watcher off then on when the program file changed'
Assert ($inst -notmatch 'RunAs|-Verb') 'the installer asks for no administrator rights'
$bytes = [IO.File]::ReadAllBytes($src)
Assert (-not ($bytes | Where-Object { $_ -gt 127 } | Select-Object -First 1) -and -not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF)) 'the program file is plain ASCII with no byte-order mark'

# ================================================================ 5. the "?" help window and every wrapped label
Section 'Fitting wrapped text: one helper for every window'
# a pretend measurer: every character is 8.1 pixels wide at 16 px type, text wraps at word breaks, a line is 1.4 times the type size
function New-Measurer { param([double]$CharW, [int]$LineH, [double]$Shrink = 0.0)
    return { param($t, $w) $ww = [math]::Max(1, $w * (1.0 - $script:Shrink)); $lines = 1; $cur = 0.0
        foreach ($word in ([string]$t -split ' ')) { $len = ($word.Length + 1) * $script:CharW; if ($cur + $len -gt $ww -and $cur -gt 0) { $lines++; $cur = $len } else { $cur += $len } }
        return ($lines * $script:LineH) }
}
$script:CharW = 8.1; $script:LineH = 24; $script:Shrink = 0.0
$m = New-Measurer -CharW 8.1 -LineH 24
Assert ((Get-FixItWrappedTextHeight -Text 'abc' -Width 472 -Scale 1.0 -Measure { param($t, $w) $script:SeenW = $w; return 21.2 }) -eq 22 -and $script:SeenW -eq 464) 'text is measured 8 pixels narrower than the label, and the height is rounded up'
Assert ((Get-FixItWrappedTextHeight -Text 'abc' -Width 944 -Scale 2.0 -Measure { param($t, $w) $script:SeenW = $w; return 10 }) -eq 10 -and $script:SeenW -eq 928) 'the safety margin grows with the screen scale'
Assert ((Get-FixItWrappedTextHeight -Text 'abc' -Width 3 -Scale 1.0 -Measure { param($t, $w) $script:SeenW = $w; return 1 }) -eq 1 -and $script:SeenW -ge 1) 'a tiny width never measures at zero or less'
Assert ((Get-FixItGrowDelta -Needed 100 -Current 80) -eq 20 -and (Get-FixItGrowDelta -Needed 60 -Current 80) -eq 0 -and (Get-FixItGrowDelta -Needed 80 -Current 80) -eq 0) 'a label grows by what it is missing and never shrinks'
$gs = Get-Fn 'Get-FixItGuideStepLayout'
Assert ($gs -match 'Get-FixItWrappedTextHeight') 'the guide step layout uses the same helper as the help window'
$lay = Get-FixItGuideStepLayout -Steps @('one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty') -Scale 1.0 -TextWidth 300 -LineHeight 24 -Measure $m
Assert ($lay.Rows[0].Height -ge $lay.Rows[0].MeasuredHeight + 12) 'the guide step layout still adds its padding'

Section 'The ? help window: measured, sized to fit, scrolls only past the cap'
$table = Get-FixItHelpTable
Assert ($table.Count -eq 12) 'there are 12 descriptions'
$bad = 0; $checked = 0
foreach ($scale in @(1.0, 1.25, 1.5, 1.75, 2.0, 2.5)) {
    foreach ($shrink in @(0.0, 0.04)) {   # 0.04: windows that wrap about 4 percent earlier than the measure says
        $script:CharW = 8.1 * $scale; $script:LineH = [int](24 * $scale); $script:Shrink = 0.0
        $meas = New-Measurer -CharW $script:CharW -LineH $script:LineH
        $inner = [int](472 * $scale)
        foreach ($k in $table.Keys) {
            $text = [string](Get-FixItHelpText -Key $k).Text
            $allot = (Get-FixItWrappedTextHeight -Text $text -Width $inner -Scale $scale -Measure $meas) + [int][math]::Ceiling(12 * $scale)
            $script:Shrink = $shrink
            $drawn = & $meas $text $inner
            $script:Shrink = 0.0
            $checked++
            if ($allot -lt $drawn) { $bad++; Write-Host ("   short: $k at x$scale shrink $shrink allot $allot drawn $drawn") }
        }
    }
}
Assert ($bad -eq 0 -and $checked -eq 12 * 6 * 2) "the height given to the body covers every description at every screen scale, even if the real wrap is 4 percent tighter ($checked cases)"
# the exact case from the screenshot (Fix my printer, old long text): 8 lines drawn, 7 allowed. The old text is gone, but the rule must hold for it.
$oldPrinter = "I look at the printers on this computer and ask if you know which one you want. You pick it from a list, or I test them and choose one that is ready, and I make it your main printer. I restart the part of Windows that handles printing, clear out stuck print jobs (anything waiting has to be printed again) and reconnect shared printers. Nothing starts until you agree on the 'Here is what I will do' window, Windows asks your permission with a shield box, and your documents and files are never touched."
$script:CharW = 8.1; $script:LineH = 24; $script:Shrink = 0.0
$meas = New-Measurer -CharW 8.1 -LineH 24
$allot = (Get-FixItWrappedTextHeight -Text $oldPrinter -Width 472 -Scale 1.0 -Measure $meas) + 12
$script:Shrink = 0.03; $drawn = & $meas $oldPrinter 472; $script:Shrink = 0.0
Assert ($allot -ge $drawn -and $allot -ge (& $meas $oldPrinter 472) + 12) 'the long printer text from the screenshot would no longer lose its last line'
# the window plan
$p = Get-FixItTextWindowPlan -TitleHeight 40 -BodyHeight 300 -ChromeHeight 122 -WorkAreaHeight 1000
Assert (-not $p.Scroll -and $p.ViewHeight -eq 300 -and $p.ClientHeight -eq 462) 'room to spare: the window is exactly as tall as its text, no scroll bar'
$p = Get-FixItTextWindowPlan -TitleHeight 40 -BodyHeight 900 -ChromeHeight 122 -WorkAreaHeight 1000
Assert ($p.Scroll -and $p.ClientHeight -eq 850 -and $p.ViewHeight -eq (850 - 122 - 40) -and $p.Cap -eq 850) 'past 85 percent of the working height: the window stops at the cap and the body scrolls'
$p = Get-FixItTextWindowPlan -TitleHeight 40 -BodyHeight 688 -ChromeHeight 122 -WorkAreaHeight 1000
Assert (-not $p.Scroll -and $p.ClientHeight -eq 850) 'exactly at the cap: still no scroll bar'
$p = Get-FixItTextWindowPlan -TitleHeight 40 -BodyHeight 689 -ChromeHeight 122 -WorkAreaHeight 1000
Assert ($p.Scroll) 'one pixel past the cap: scroll'
$p = Get-FixItTextWindowPlan -TitleHeight 40 -BodyHeight 100000 -ChromeHeight 122 -WorkAreaHeight 0
Assert (-not $p.Scroll) 'screen size unknown: no cap is invented'
$p = Get-FixItTextWindowPlan -TitleHeight 40 -BodyHeight 500 -ChromeHeight 700 -WorkAreaHeight 600
Assert ($p.Scroll -and $p.ViewHeight -ge 60) 'a tiny screen still leaves a usable reading area'
$never = 0; $scrolls = 0
foreach ($wa in @(600, 720, 768, 900, 1080, 1440)) { foreach ($scale in @(1.0, 1.5, 2.0, 2.5)) { foreach ($k in $table.Keys) {
    $script:CharW = 8.1 * $scale; $script:LineH = [int](24 * $scale); $script:Shrink = 0.0
    $meas = New-Measurer -CharW $script:CharW -LineH $script:LineH
    $bh = (Get-FixItWrappedTextHeight -Text ([string](Get-FixItHelpText -Key $k).Text) -Width ([int](472 * $scale)) -Scale $scale -Measure $meas) + [int][math]::Ceiling(12 * $scale)
    $pl = Get-FixItTextWindowPlan -TitleHeight ([int](36 * $scale)) -BodyHeight $bh -ChromeHeight ([int](122 * $scale)) -WorkAreaHeight $wa
    if ($pl.ClientHeight -gt [math]::Floor($wa * 0.85)) { $never++ }
    if ($pl.Scroll) { $scrolls++ }
} } }
Assert ($never -eq 0) 'the window is never taller than 85 percent of the working area (all texts, scales and screens)'
$script:CharW = 8.1; $script:LineH = 24
$meas = New-Measurer -CharW 8.1 -LineH 24
$mx = 0; foreach ($k in $table.Keys) { $bh = (Get-FixItWrappedTextHeight -Text ([string](Get-FixItHelpText -Key $k).Text) -Width 472 -Scale 1.0 -Measure $meas) + 12; if ($bh -gt $mx) { $mx = $bh } }
$pl = Get-FixItTextWindowPlan -TitleHeight 36 -BodyHeight $mx -ChromeHeight 122 -WorkAreaHeight 720
Assert (-not $pl.Scroll) 'with the short descriptions, even the longest one fits a 720 pixel high screen without a scroll bar'
$hf = Get-Fn 'Show-FixItHelpForm'
Assert ($hf -match 'Get-FixItLabelHeight' -and $hf -match 'Get-FixItTextWindowPlan' -and $hf -match 'WorkingArea' -and $hf -match 'AutoScroll' -and $hf -match 'UseMnemonic') 'the help window measures its text, plans its size from the screen, scrolls only when told to, and does not eat ampersands'
Assert ($hf -notmatch 'MeasureText' -and $hf -notmatch '\$bh = 120 \* \$S;\s*\r?\n') 'the help window no longer uses a hand-made height'
Assert ($hf -match 'VerticalScrollBarWidth') 'when the body scrolls, the text is measured again at the narrower width (the scroll bar takes room)'
Assert ($hf -match 'DialogResult' -and $hf -match 'AcceptButton' -and $hf -match 'CancelButton') 'OK, got it still closes the window (Enter or Esc too)'

Section 'The ? descriptions: short, plain, true'
$rwText = [string]$script:ReportsWhere
$maxWords = 0
foreach ($k in $table.Keys) {
    $h = Get-FixItHelpText -Key $k
    $words = @(($h.Text.Trim() -split '\s+') | Where-Object { $_ })
    if ($words.Count -gt $maxWords) { $maxWords = $words.Count }
    $sent = @([regex]::Split($h.Text.Trim(), '(?<=[.!?])\s+') | Where-Object { $_ })
    Assert ($words.Count -le 45) "$k : 45 words at most (has $($words.Count))"
    Assert ($sent.Count -ge 2 -and $sent.Count -le 3) "$k : 2 to 3 sentences (has $($sent.Count))"
    $longest = ($sent | ForEach-Object { @($_ -split '\s+').Count } | Measure-Object -Maximum).Maximum
    Assert ($longest -le 26) "$k : no sentence is very long ($longest words)"
    Assert ($h.Text -notmatch 'registry|DNS|DHCP|DISM|\bSFC\b|proxy|LoadBehavior|PowerShell|script|winsock|TCP|cache|executable|add-in cache|service') "$k : no technical words"
    Assert ($h.Text -match '\b(never|not|nothing|no)\b') "$k : says what it leaves alone"
    Assert ($h.Text -notmatch '\$|\{|\}') "$k : no stray program text"
}
Assert ($maxWords -le 45) 'the longest description is 45 words or fewer'
$T = @{}; foreach ($k in $table.Keys) { $T[$k] = [string](Get-FixItHelpText -Key $k).Text }
Assert ($T.Printer -match 'main one' -and $T.Printer -match 'stuck print jobs' -and $T.Printer -match 'printed again' -and $T.Printer -match 'ask first' -and $T.Printer -match 'never touched') 'Printer: main printer, stuck jobs (printed again), asks first, files safe'
Assert ($T.Acrobat -match 'Acrobat buttons are missing in Outlook' -and $T.Acrobat -match 'close and reopen Outlook' -and $T.Acrobat -match 'add-in' -and $T.Acrobat -match 'ask before each step' -and $T.Acrobat -match 'passwords') 'Acrobat: when to use it, reopen Outlook, add-in, asks, accounts safe'
Assert ($T.Outlook -match 'freezes or will not open' -and $T.Outlook -match 'close it and open it again' -and $T.Outlook -match 'ask before each next step' -and $T.Outlook -match 'sign-ins') 'Outlook: when to use it, reopen, asks, accounts safe'
Assert ($T.Network -match 'router' -and $T.Network -match 'change nothing if they work' -and $T.Network -match 'unplug the router' -and $T.Network -match 'drops briefly' -and $T.Network -match 'files are never touched') 'Network: tests first, router unplug, a brief drop, files safe'
Assert ($T.Slow -match 'frozen program if you say yes' -and $T.Slow -match 'temporary files' -and $T.Slow -match 'Recycle Bin' -and $T.Slow -match 'sign you out' -and $T.Slow -match 'Documents, Desktop, Pictures and Downloads are never touched') 'Slow: asks, temp files and Recycle Bin, sign-out warning, personal folders safe'
Assert ($T.Sound -match 'speakers, microphone and camera' -and $T.Sound -match 'muted' -and $T.Sound -match 'ask before' -and $T.Sound -match 'pick your devices' -and $T.Sound -match 'nothing else') 'Sound: what it checks, muted, asks, device page, nothing else'
Assert ($T.Browser -match 'copy of your browser settings and bookmarks' -and $T.Browser -match 'ask before opening' -and $T.Browser -match 'never change your browser myself' -and $T.Browser -match 'passwords and bookmarks are not touched') 'Browser: backup first, asks, never changes it itself, data safe'
Assert ($T.WinUpdate -match 'pause Windows Update' -and $T.WinUpdate -match 'nothing is deleted' -and $T.WinUpdate -match '20 to 40 minutes' -and $T.WinUpdate -match 'after asking you' -and $T.WinUpdate -match 'only if you say yes' -and $T.WinUpdate -match 'files are not touched') 'WinUpdate: pause, nothing deleted, 20 to 40 minute repair after asking, restart only on yes'
Assert ($T.OneDrive -match 'signed in and running' -and $T.OneDrive -match 'Desktop, Documents and Pictures' -and $T.OneDrive -match 'say yes to a reset' -and $T.OneDrive -match 'none are deleted') 'OneDrive: checks, tells you, resets only on yes, nothing deleted'
Assert ($T.Scam -match 'fixes nothing' -and $T.Scam -match 'send Trey a report' -and $T.Scam.Contains($rwText) -and $T.Scam -match 'do not call the number' -and $T.Scam -match 'turn off your Wi-Fi and call Trey') 'Scam: changes nothing, report to Trey, copy saved, do not call the number, Wi-Fi off, call Trey'
Assert ($T.Screen -match 'Zoho Assist' -and $T.Screen -match 'code from Trey' -and $T.Screen -match 'click Join' -and $T.Screen -match 'Nothing is installed' -and $T.Screen -match 'called Trey') 'Screen: Zoho page, code, Join, nothing installed, only if you called'
Assert ($T.Report -match 'help Trey' -and $T.Report.Contains($rwText) -and $T.Report -match 'send it to Trey' -and $T.Report -match 'no files or passwords' -and $T.Report -match 'change nothing') 'Report: facts for Trey, copy saved, sent, no files or passwords, changes nothing'

Section 'Other windows with wrapped text: no fixed heights that clip'
$fits = @('Show-FixItHelpForm', 'Show-FixItPrivacyForm', 'Show-FixItPlanDialog', 'Show-FixItShareForm', 'Show-FixItNameForm', 'Show-FixItFixedDialog', 'Show-FixItChromeAskDialog', 'Show-FixItCountdownDialog', 'Show-FixItScamForm')
foreach ($fn in $fits) {
    $t = Get-Fn $fn
    Assert ($t -match 'Get-FixItLabelHeight|Expand-FixItLabelsToFit|Get-FixItTextWindowPlan') "$fn : sizes its text with the shared helper"
    Assert ($t -notmatch 'NoPadding' -and $t -notmatch 'TextRenderer\]::MeasureText') "$fn : no private measuring that differs from how the label draws"
}
Assert ((Get-Fn 'Show-FixItPrivacyForm') -match 'AutoScroll' -and (Get-Fn 'Show-FixItPlanDialog') -match 'AutoScroll') 'the long windows (what is shared, the plan) still scroll when the screen is too small'
foreach ($fn in @('Show-FixItShareForm', 'Show-FixItNameForm', 'Show-FixItFixedDialog', 'Show-FixItChromeAskDialog', 'Show-FixItCountdownDialog', 'Show-FixItScamForm')) {
    Assert ((Get-Fn $fn) -match 'Expand-FixItLabelsToFit -Form \$f') "$fn : grows to fit its text and moves the buttons down"
}
Assert ((Get-Fn 'Show-FixItPcInfoForm') -match 'Get-FixItLabelHeight') 'My PC info: a long value gets the height it really needs'
$allShow = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -like 'Show-*' }, $true))
$raw = @($allShow | Where-Object { $_.Name -ne 'Show-FixItGuideSteps' -and $_.Extent.Text -match 'TextRenderer\]::MeasureText' } | ForEach-Object { $_.Name })
Assert ((Get-Fn 'Show-FixItGuideSteps') -match "MeasureText\('Ag'" -and ([regex]::Matches((Get-Fn 'Show-FixItGuideSteps'), 'MeasureText')).Count -eq 1 -and (Get-Fn 'Show-FixItGuideSteps') -match 'Get-FixItGuideStepLayout') 'the guide window measures only one line height by itself (for counting lines); the step heights come from the shared layout'
Assert ($raw.Count -eq 0) ('no window measures text on its own any more (' + ($raw -join ',') + ')')

# the label expander with pretend controls
function New-FakeCtl { param([int]$Top, [int]$Height, [int]$Width = 300, [string]$Text = '')
    $o = [pscustomobject]@{ Top = $Top; Height = $Height; Width = $Width; Text = $Text; Font = 'f' }
    $o | Add-Member -MemberType ScriptProperty -Name Bottom -Value { $this.Top + $this.Height }
    return $o
}
function Measure-FixItText { param([string]$Text, $Font, [int]$Width = 0) return [pscustomobject]@{ Height = (& $script:ExMeasure $Text $Width) } }
$script:ExMeasure = { param($t, $w) return (([int][math]::Ceiling($t.Length * 8.0 / [math]::Max(1, $w))) * 24) }
$l1 = New-FakeCtl -Top 20 -Height 24 -Width 300 -Text ('x' * 200)     # 200 chars * 8 = 1600 px over 292 -> 6 lines -> 144 + 12 pad = 156
$b1 = New-FakeCtl -Top 60 -Height 50; $b2 = New-FakeCtl -Top 60 -Height 50; $above = New-FakeCtl -Top 0 -Height 10
$form = [pscustomobject]@{ Controls = @($above, $l1, $b1, $b2); ClientSize = (New-Object System.Drawing.Size(320, 200)) }
Expand-FixItLabelsToFit -Form $form -Labels @($l1) -Scale 1.0
Assert ($l1.Height -eq 156 -and $b1.Top -eq 192 -and $b2.Top -eq 192 -and $above.Top -eq 0 -and $form.ClientSize.Height -eq 332) 'a label that is too short grows; everything below moves down by the same amount; the window grows; things above stay'
$l2 = New-FakeCtl -Top 20 -Height 100 -Width 300 -Text 'short'; $b3 = New-FakeCtl -Top 130 -Height 50
$form = [pscustomobject]@{ Controls = @($l2, $b3); ClientSize = (New-Object System.Drawing.Size(320, 200)) }
Expand-FixItLabelsToFit -Form $form -Labels @($l2) -Scale 1.0
Assert ($l2.Height -eq 100 -and $b3.Top -eq 130 -and $form.ClientSize.Height -eq 200) 'a label that already fits is not touched'
$la = New-FakeCtl -Top 10 -Height 24 -Width 300 -Text ('y' * 100); $lb2 = New-FakeCtl -Top 60 -Height 24 -Width 300 -Text ('y' * 100); $bt = New-FakeCtl -Top 100 -Height 40
$form = [pscustomobject]@{ Controls = @($la, $lb2, $bt); ClientSize = (New-Object System.Drawing.Size(320, 200)) }
Expand-FixItLabelsToFit -Form $form -Labels @($lb2, $la) -Scale 1.0
Assert ($la.Height -eq 84 -and $lb2.Top -eq 60 + 60 -and $lb2.Height -eq 84 -and $bt.Top -eq 100 + 60 + 60 -and $form.ClientSize.Height -eq 200 + 120) 'two labels: the upper one is fitted first, the lower one moves with it and is fitted next'
$form = [pscustomobject]@{ Controls = @($l1); ClientSize = (New-Object System.Drawing.Size(320, 200)) }
$l1.Font = $null; $script:ExMeasure = { param($t, $w) throw 'no measuring here' }
Expand-FixItLabelsToFit -Form $form -Labels @($l1) -Scale 1.0
Assert ((Get-Log) -match 'Could not fit the text in the window') 'if measuring fails, the window is left as it was and the problem is logged'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('Passed: {0}   Failed: {1}' -f $script:Pass, $script:Fail)
