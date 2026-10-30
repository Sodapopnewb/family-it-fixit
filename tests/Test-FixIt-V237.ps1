# Version 2.3.7 tests: the watcher's tray icon, the bigger "My PC info" (and the hardware part of reports), and the weekly hardware monitor.
# These use the REAL program functions with pretend Windows facts, so they run in their own PowerShell.
# Usage:  pwsh ./tests/Test-FixIt-V237.ps1       (Test-FixIt.ps1 runs this one too and adds its numbers)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fixit-v237-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:Pass = 0; $script:Fail = 0
function Assert { param([bool]$Cond, [string]$Name) if ($Cond) { $script:Pass++ } else { $script:Fail++; Write-Host ('  FAIL: ' + $Name) -ForegroundColor Red } }
function Section { param([string]$T) Write-Host ('== ' + $T) }

$src = Join-Path $root 'FamilyFixIt.ps1'
$outDir = Join-Path $tmp 'out'; New-Item -ItemType Directory -Path $outDir | Out-Null
$env:LOCALAPPDATA = Join-Path $tmp 'local'; New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
$env:COMPUTERNAME = 'TESTPC'
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v237.log') -OutputDir $outDir
Initialize-FixItLog
$tokens = $null; $perr = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$perr)
$allFns = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
function Get-Fn { param([string]$Name) return ($allFns | Where-Object { $_.Name -eq $Name } | Select-Object -First 1) }
function Get-Log { return (Get-Content -LiteralPath $script:LogFile -Raw) }
function Set-TestModeOn { $script:TestMode = $true; $script:DryRun = $true; $script:GuiActive = $false }
function Restore-Modes { $script:TestMode = $false; $script:DryRun = $false; $script:GuiActive = $false; $script:TestAll = $false; $script:InProbe = $false }
$GB = 1GB
$srcText = [IO.File]::ReadAllText($src)

Assert ([version]$script:FixItVersion -ge [version]'2.3.7') 'the program is version 2.3.7 or newer'
Assert (-not ($srcText -match '[^\x00-\x7F]')) 'the program file is plain ASCII (safe for Windows PowerShell 5.1)'

# ================================================================ 1. tray icon: the plan
Section 'Tray icon: what it says and offers'
$plan = Get-FixItTrayPlan
Assert (@($plan.Items).Count -eq 3) 'the right-click menu has exactly three items (2.3.13 added the Exit item)'
Assert (@($plan.Items)[0].Text -eq 'Get me out of a scary page' -and @($plan.Items)[1].Text -eq 'Open Family Fix-It' -and @($plan.Items)[2].Text -eq 'Turn off the pop-up watcher') 'the items read "Get me out of a scary page", "Open Family Fix-It" and "Turn off the pop-up watcher"'
Assert (@($plan.Items | Where-Object { $_.Text -match '(?i)quit|close' }).Count -eq 0) 'there is no Quit or Close item'
Assert ($plan.ToolTip -eq 'Family Fix-It is watching for scary pop-ups' -and $plan.ToolTip.Length -le 63) 'the hover text is plain and fits the 63 character limit'
Assert ($plan.DoubleClick -eq 'Open' -and -not $plan.Balloons) 'double-click opens Family Fix-It; no pop-up bubbles'
Assert ($srcText -notmatch 'ShowBalloonTip|BalloonTip') 'the program never shows a balloon notification'
Assert ($srcText -match "FamilyFixIt\.ico|IconFileName") 'the program uses its own icon file'
$tf = (Get-Fn 'Get-FixItTrayIcon').Extent.Text
Assert ($tf -match 'Get-FixItAppIcon' -and $tf -match 'SystemIcons') 'the tray icon is the program icon, with a Windows icon as the fallback when the file is missing'

# ================================================================ 2. tray icon: which window "Get me out" uses
Section 'Tray icon: the window in front'
function Fg { param([string]$Name, [int]$ProcId = 100) return [pscustomobject]@{ ProcessName = $Name; ProcessId = $ProcId; Title = 't'; Handle = 5 } }
$now = Get-Date
$edge = Fg 'msedge' 200
Assert ((Test-FixItTrayUsableWindow -Fg $edge -OwnPid 50)) 'a browser is a usable window'
Assert (-not (Test-FixItTrayUsableWindow -Fg (Fg 'explorer' 300) -OwnPid 50)) 'the taskbar (explorer) is not'
Assert (-not (Test-FixItTrayUsableWindow -Fg (Fg 'ShellExperienceHost' 301) -OwnPid 50)) 'the Start menu is not'
Assert (-not (Test-FixItTrayUsableWindow -Fg (Fg 'powershell' 50) -OwnPid 50)) 'the watcher''s own menu or toast is not'
Assert (-not (Test-FixItTrayUsableWindow -Fg $null)) 'nothing in front is not usable'
Assert ((Select-FixItTrayWindow -Current $edge -Last (Fg 'chrome' 9) -LastAt $now -Now $now -OwnPid 50).ProcessName -eq 'msedge') 'a real front window is used as it is'
Assert ((Select-FixItTrayWindow -Current (Fg 'explorer' 300) -Last $edge -LastAt $now.AddSeconds(-20) -Now $now -OwnPid 50).ProcessName -eq 'msedge') 'the menu took the front: the last real window (20 seconds ago) is used'
Assert ($null -eq (Select-FixItTrayWindow -Current (Fg 'explorer' 300) -Last $edge -LastAt $now.AddSeconds(-500) -Now $now -OwnPid 50)) 'a window seen long ago is not used'
Assert ($null -eq (Select-FixItTrayWindow -Current (Fg 'explorer' 300) -Last $null -Now $now -OwnPid 50)) 'no real window ever seen: none is used (the page is still closed by name)'
$script:GLastFg = $null; $script:GLastFgAt = [datetime]::MinValue
Update-FixItGuardianLastWindow -Fg (Fg 'explorer' 300) -Now $now
Assert ($null -eq $script:GLastFg) 'the watcher''s look does not remember the taskbar'
Update-FixItGuardianLastWindow -Fg $edge -Now $now
Assert ($script:GLastFg.ProcessName -eq 'msedge' -and $script:GLastFgAt -eq $now) 'the watcher''s look remembers a real window and when'
$tickText = (Get-Fn 'Invoke-GuardianTick').Extent.Text
Assert ($tickText -match 'Update-FixItGuardianLastWindow') 'the 1.5 second look feeds the remembered window'

# ================================================================ 3. tray icon: clicks
Section 'Tray icon: clicks (logged)'
$script:Got = New-Object System.Collections.ArrayList
function Get-FixItForeground { return $script:FgNow }
function Start-GuardianGetOutUi { param($Fg = $null, [string]$Reason = 'button', [switch]$Demo) [void]$script:Got.Add(('getout:{0}:{1}' -f $(if ($Fg) { $Fg.ProcessName } else { 'none' }), $Reason)) }
function Open-FixItMainWindow { [void]$script:Got.Add('open') }
$script:FgNow = Fg 'explorer' 300
$script:GLastFg = $edge; $script:GLastFgAt = (Get-Date)
$script:GBusy = $false
Invoke-GuardianTrayAction -Id 'GetOut'
Assert ($script:Got[0] -eq 'getout:msedge:tray') '"Get me out" with the taskbar in front uses the browser seen a moment ago and the reason "tray"'
$script:FgNow = Fg 'chrome' 400
Invoke-GuardianTrayAction -Id 'GetOut'
Assert ($script:Got[1] -eq 'getout:chrome:tray') '"Get me out" uses the current front window when it is a real one'
$script:GBusy = $true
Invoke-GuardianTrayAction -Id 'GetOut'
Assert ($script:Got.Count -eq 2) '"Get me out" while it is already running does nothing twice'
$script:GBusy = $false
Invoke-GuardianTrayAction -Id 'Open'
Assert ($script:Got[2] -eq 'open') '"Open Family Fix-It" opens the window'
Invoke-GuardianTrayAction -Id 'DoubleClick'
Assert ($script:Got[3] -eq 'open') 'double-click opens the window'
$lg = Get-Log
Assert ($lg -match 'Guardian tray: menu click "Get me out of a scary page"' -and $lg -match 'Guardian tray: menu click "Open Family Fix-It"' -and $lg -match 'Guardian tray: double-click -> "Open Family Fix-It"') 'every click is logged'
Assert ((Get-FixItGuardianNote -Details ([pscustomobject]@{ Browser = 'msedge'; ProcessId = 1; Title = ''; Url = ''; Flags = @() }) -Reason 'tray' -Closed 1) -match 'tray icon') 'Trey''s report says it was the tray icon'
$of = (Get-Fn 'Open-FixItMainWindow').Extent.Text
Assert ($of -notmatch '-Action' -and $of -match '-File') 'opening Family Fix-It starts the normal window (no -Action), so the one-window rules apply'
Assert ((Get-FixItGuiWindowKind -CommandLine 'powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "C:\x\FamilyFixIt.ps1"') -eq 'Normal') 'that start counts as a normal window for the one-window logic'
Assert ((Get-FixItGuiWindowKind -CommandLine 'powershell.exe -File "C:\x\FamilyFixIt.ps1" -Action Guardian') -eq '') 'the watcher itself is still not a window'

# ================================================================ 4. tray icon: create / dispose (pretend icon objects)
Section 'Tray icon: created once, removed cleanly'
$script:Made = New-Object System.Collections.ArrayList
function New-FakeItem { $o = [pscustomobject]@{ Text = ''; Tag = $null; Handler = $null }; $o | Add-Member -MemberType ScriptMethod -Name add_Click -Value { param($h) $this.Handler = $h }; return $o }
function New-Object {
    param([string]$TypeName, $ArgumentList)
    if ($TypeName -eq 'System.Windows.Forms.NotifyIcon') {
        $o = [pscustomobject]@{ Text = ''; Icon = $null; Visible = $false; ContextMenuStrip = $null; DoubleClickHandler = $null; Disposed = 0; VisibleWhenDisposed = $null }
        $o | Add-Member -MemberType ScriptMethod -Name add_DoubleClick -Value { param($h) $this.DoubleClickHandler = $h }
        $o | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed++; $this.VisibleWhenDisposed = $this.Visible }
        [void]$script:Made.Add($o); return $o
    }
    if ($TypeName -eq 'System.Windows.Forms.ContextMenuStrip') {
        $items = [pscustomobject]@{ List = ([System.Collections.ArrayList]::new()) }
        $items | Add-Member -MemberType ScriptMethod -Name Add -Value { param($t) $i = New-FakeItem; $i.Text = $t; [void]$this.List.Add($i); return $i }
        $o = [pscustomobject]@{ Items = $items; Disposed = 0 }
        $o | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed++ }
        return $o
    }
    throw ('unexpected New-Object ' + $TypeName)
}
function New-Object2 { param([string]$T) return (Microsoft.PowerShell.Utility\New-Object $T) }
function Get-FixItTrayIcon { return 'THE-ICON' }
$script:GTray = $null
$t1 = New-FixItGuardianTray
$ni1 = $t1.Icon
Assert ($ni1.Visible -and $ni1.Text -eq 'Family Fix-It is watching for scary pop-ups' -and $ni1.Icon -eq 'THE-ICON') 'the icon is shown with its hover text and icon'
$menuItems = @($t1.Menu.Items.List)
Assert ($menuItems.Count -eq 3 -and $menuItems[0].Text -eq 'Get me out of a scary page' -and $menuItems[1].Text -eq 'Open Family Fix-It' -and $menuItems[2].Text -eq 'Turn off the pop-up watcher') 'the menu holds exactly the three items'
Assert ($ni1.ContextMenuStrip -eq $t1.Menu) 'the menu is attached to the icon'
$script:Got.Clear()
function Invoke-GuardianTrayAction { param([string]$Id) [void]$script:Got.Add('act:' + $Id) }
& $menuItems[0].Handler $menuItems[0] $null
& $menuItems[1].Handler $menuItems[1] $null
& $ni1.DoubleClickHandler $ni1 $null
Assert (($script:Got -join ',') -eq 'act:GetOut,act:Open,act:DoubleClick') 'clicking each item (and double-clicking the icon) reaches the right action'
$t2 = New-FixItGuardianTray
Assert ($ni1.Disposed -eq 1 -and -not $ni1.VisibleWhenDisposed) 'asking for a second icon first hides and frees the first (never two icons)'
Assert ($script:Made.Count -eq 2 -and $t2.Icon.Visible) 'exactly one icon is visible after that'
Remove-FixItGuardianTray
Assert ($t2.Icon.Disposed -eq 1 -and -not $t2.Icon.VisibleWhenDisposed -and $t2.Menu.Disposed -eq 1 -and $null -eq $script:GTray) 'removing hides the icon first (no ghost), frees it and its menu'
Remove-FixItGuardianTray; Remove-FixItGuardianTray
Assert ($t2.Icon.Disposed -eq 1 -and $t2.Menu.Disposed -eq 1) 'removing again is harmless (nothing is freed twice)'
Remove-Item Function:\New-Object, Function:\New-Object2, Function:\Get-FixItTrayIcon -ErrorAction SilentlyContinue
Remove-Item Function:\Invoke-GuardianTrayAction -ErrorAction SilentlyContinue

# ================================================================ 5. the watcher run: mutex, stop signal, cleanup
Section 'Watcher run: one copy, polite stop, clean exit'
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v237b.log') -OutputDir $outDir; Initialize-FixItLog   # fresh real functions
$script:Order = New-Object System.Collections.ArrayList
function Enter-FixItGuardianMutex { [void]$script:Order.Add('mutex'); return $(if ($script:MutexBusy) { $null } else { [pscustomobject]@{ } }) }
function Release-FixItGuardianMutex { param($Mutex) [void]$script:Order.Add('release') }
function Initialize-FixItGuardianNative { [void]$script:Order.Add('native') }
function New-FixItGuardianStopEvent { [void]$script:Order.Add('stopevent'); $e = [pscustomobject]@{ D = 0 }; $e | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.D++ }; return $e }
function New-FixItGuardianHotkey { [void]$script:Order.Add('hotkey'); $h = [pscustomobject]@{ }; $h | Add-Member -MemberType ScriptMethod -Name Dispose -Value { [void]$script:Order.Add('hotkey-dispose') }; return $h }
function New-FixItGuardianTray { [void]$script:Order.Add('tray'); $script:GTray = [pscustomobject]@{ Icon = 1 }; return $script:GTray }
function Remove-FixItGuardianTray { [void]$script:Order.Add('tray-remove'); $script:GTray = $null }
function Start-FixItGuardianLoop { [void]$script:Order.Add('loop'); if ($script:LoopThrows) { throw 'loop broke' } }
$script:MutexBusy = $false; $script:LoopThrows = $false
$r = Invoke-GuardianRun
Assert (($script:Order -join ',') -eq 'mutex,native,stopevent,hotkey,tray,loop,tray-remove,hotkey-dispose,release') 'start: mutex, stop signal, hotkey, tray, loop; end: tray removed first, then the hotkey, then the mutex is released'
Assert ((Get-Log) -match 'Guardian started \(version [\d.]+\); hotkey ready; tray icon shown') 'the start is logged with the tray icon state'
$script:Order.Clear(); $script:LoopThrows = $true
$threw = $false; try { [void](Invoke-GuardianRun) } catch { $threw = $true }
Assert ($threw -and (($script:Order -join ',') -match 'tray-remove,hotkey-dispose,release$')) 'even if the loop breaks, the icon is removed and the mutex released'
$script:Order.Clear(); $script:LoopThrows = $false; $script:MutexBusy = $true
$r = Invoke-GuardianRun
Assert (($script:Order -join ',') -eq 'mutex' -and $r.Title -eq 'Already running') 'a second watcher finds the mutex taken and stops at once: no second icon is made'
$script:MutexBusy = $false
function New-FixItGuardianTray { throw 'no notification area' }
$script:Order.Clear(); $r = Invoke-GuardianRun
Assert ((($script:Order -join ',') -match 'loop') -and (Get-Log) -match 'tray icon NOT available') 'if the icon cannot be made, the watcher and the panic key still run'
foreach ($fn in @('Enter-FixItGuardianMutex', 'Release-FixItGuardianMutex', 'Initialize-FixItGuardianNative', 'New-FixItGuardianStopEvent', 'New-FixItGuardianHotkey', 'New-FixItGuardianTray', 'Remove-FixItGuardianTray', 'Start-FixItGuardianLoop')) { Remove-Item "Function:\$fn" -ErrorAction SilentlyContinue }
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v237b.log') -OutputDir $outDir; Initialize-FixItLog
# the stop signal
$script:GStop = $null
Assert (-not (Test-FixItGuardianStopRequested)) 'no stop signal object: not asked to stop'
$sig = [pscustomobject]@{ On = $false }; $sig | Add-Member -MemberType ScriptMethod -Name WaitOne -Value { param($ms) return $this.On }
$script:GStop = $sig
Assert (-not (Test-FixItGuardianStopRequested)) 'not signalled: keeps watching'
$sig.On = $true
Assert (Test-FixItGuardianStopRequested) 'signalled: asked to stop'
$script:GStop = $null
$ta = (Get-Fn 'Invoke-GuardianTick').Extent.Text
Assert ($ta.IndexOf('Test-FixItGuardianStopRequested') -gt $ta.IndexOf('$script:GBusy') -and $ta.IndexOf('Test-FixItGuardianStopRequested') -lt $ta.IndexOf('Get-FixItForeground') -and $ta -match 'ExitThread') 'each look checks the stop signal (not in the middle of a get-out) and then ends the message loop'
# stopping from outside: polite first, force only what is left
$script:Sig = New-Object System.Collections.ArrayList
$script:Procs = @([pscustomobject]@{ ProcessId = 9001; CommandLine = 'powershell.exe -File "C:\x\FamilyFixIt.ps1" -Action Guardian' }, [pscustomobject]@{ ProcessId = 9002; CommandLine = 'powershell.exe -File "C:\x\FamilyFixIt.ps1"' })
function Get-CimInstance { param($ClassName, $Filter, $ErrorAction) return $script:Procs }
function Stop-Process { param($Id, [switch]$Force, $ErrorAction) [void]$script:Sig.Add('kill:' + $Id) }
function Send-FixItGuardianStopSignal { [void]$script:Sig.Add('signal'); return $script:CanSignal }
function Wait-FixItGuardianGone { param([int]$Seconds = 6) [void]$script:Sig.Add('wait'); if ($script:GoneAfterSignal) { $script:Procs = @($script:Procs | Where-Object { $_.CommandLine -notmatch 'Guardian' }) }; return $script:GoneAfterSignal }
$script:CanSignal = $true; $script:GoneAfterSignal = $true
Stop-FixItGuardianProcess
Assert (($script:Sig -join ',') -eq 'signal,wait') 'a 2.3.7 watcher is asked to stop and leaves by itself: nothing is force-stopped'
$script:Sig.Clear(); $script:CanSignal = $true; $script:GoneAfterSignal = $false
$script:Procs = @([pscustomobject]@{ ProcessId = 9001; CommandLine = 'powershell.exe -File "C:\x\FamilyFixIt.ps1" -Action Guardian' }, [pscustomobject]@{ ProcessId = 9002; CommandLine = 'powershell.exe -File "C:\x\FamilyFixIt.ps1"' })
Stop-FixItGuardianProcess
Assert (($script:Sig -join ',') -eq 'signal,wait,kill:9001') 'a watcher that does not leave in time is force-stopped (only the watcher, never the normal window)'
$script:Sig.Clear(); $script:CanSignal = $false
$script:Procs = @([pscustomobject]@{ ProcessId = 9001; CommandLine = 'powershell.exe -File "C:\x\FamilyFixIt.ps1" -Action Guardian' })
Stop-FixItGuardianProcess
Assert (($script:Sig -join ',') -eq 'signal,kill:9001') 'an older watcher (no stop signal) is stopped the old way'
foreach ($fn in @('Get-CimInstance', 'Stop-Process', 'Send-FixItGuardianStopSignal', 'Wait-FixItGuardianGone')) { Remove-Item "Function:\$fn" -ErrorAction SilentlyContinue }
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v237b.log') -OutputDir $outDir; Initialize-FixItLog
$stopFn = (Get-Fn 'Stop-FixItGuardianProcess').Extent.Text
Assert ($stopFn -match "^function Stop-FixItGuardianProcess \{\s*\r?\n\s*if \(\`$script:TestMode\) \{ Invoke-FixItProbe") 'stopping the watcher still starts with the Test mode guard'

# ================================================================ 6. tray icon in Test mode and practice runs
Section 'Tray icon: Test mode and practice run create nothing'
$script:Made2 = 0
function New-FixItGuardianTray { $script:Made2++ }
function Test-FixItIconFile { param([string]$Path) return $script:IconThere }
$script:IconThere = $true
Set-TestModeOn
Start-FixItTestButton
$r = Invoke-GuardianRun
$recs = @(Get-FixItTestRecords)
$note = @($recs | Where-Object { $_.Step -eq 'Watcher tray icon' })
Assert ($note.Count -eq 1 -and $note[0].Status -eq 'PASS') 'Test mode reports the tray icon check as PASS'
$nt = [string]$note[0].Checks[0].Text
Assert ($nt -match 'Get me out of a scary page' -and $nt -match 'Open Family Fix-It' -and $nt -match 'would be shown' -and $nt -match 'No pop-up bubbles') 'it says which menu items the icon would have'
Assert ($script:Made2 -eq 0) 'nothing is created in Test mode'
Assert ((Get-Log) -match 'Would do: show the tray icon') 'the practice log line says the icon would be shown'
$script:IconThere = $false
Start-FixItTestButton; [void](Invoke-GuardianRun)
$nt = [string](@(Get-FixItTestRecords | Where-Object { $_.Step -eq 'Watcher tray icon' })[0]).Checks[0].Text
Assert ($nt -match 'icon file is missing') 'a missing icon file is mentioned (a standard icon would be used)'
Restore-Modes
$script:DryRun = $true
$r = Invoke-GuardianRun
Assert ($r.Ok -and $r.Message -match 'notification area' -and $script:Made2 -eq 0) 'a practice run (not Test mode) also creates nothing'
Restore-Modes
Remove-Item Function:\New-FixItGuardianTray, Function:\Test-FixItIconFile
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v237b.log') -OutputDir $outDir; Initialize-FixItLog
Assert (@($script:TestAllKeys) -contains 'Guardian' -and @($script:TestAllKeys) -contains 'PCInfo' -and @($script:TestAllKeys) -contains 'HealthCheck') 'Test all buttons covers the watcher (tray icon), My PC info and the health check (hardware monitor)'

# ================================================================ 7. My PC info: readers and wording
Section 'My PC info: pieces, wording, partial failure'
function Set-Pretend {
    $script:Broken = @{}
    function script:Get-FixItHwComputer { if ($script:Broken['Computer']) { throw 'the computer details could not be read' }; return [pscustomobject]@{ Maker = 'Dell Inc.'; Model = 'XPS 13 9310'; Serial = 'ABC1234'; BiosDate = [datetime]'2024-03-05' } }
    function script:Get-FixItHwCpu { if ($script:Broken['Cpu']) { throw 'access is denied' }; return [pscustomobject]@{ Name = 'Intel(R) Core(TM) i7-1185G7'; Cores = 4; Threads = 8; LoadPercent = 12 } }
    function script:Get-FixItHwMemory { if ($script:Broken['Memory']) { throw 'no memory data' }; return [pscustomobject]@{ TotalBytes = 16 * $GB; FreeBytes = 6 * $GB; Sticks = 2; SpeedMHz = 3200; Slots = 4 } }
    function script:Get-FixItHwDisks { if ($script:Broken['Disks']) { throw 'no storage module' }; return @([pscustomobject]@{ Id = 'a|1'; Model = 'Samsung SSD 970 EVO'; MediaType = 'SSD'; BusType = 'NVMe'; Size = 500GB; Health = 'Healthy'; Status = 'OK' }, [pscustomobject]@{ Id = 'b|2'; Model = 'WDC WD10EZEX'; MediaType = 'HDD'; BusType = 'SATA'; Size = 1000GB; Health = $script:HddHealth; Status = 'OK' }) }
    function script:Get-FixItHwVolumes { if ($script:Broken['Volumes']) { throw 'no volumes' }; return @([pscustomobject]@{ Letter = 'C:'; Label = 'Windows'; Total = 500GB; Free = 100GB; Removable = $false }, [pscustomobject]@{ Letter = 'D:'; Label = ''; Total = 1000GB; Free = $script:DFree; Removable = $false }) }
    function script:Get-FixItHwGraphics { if ($script:Broken['Graphics']) { throw 'no video' }; return @([pscustomobject]@{ Name = 'Intel(R) Iris(R) Xe Graphics'; Width = 1920; Height = 1080; Hz = 60 }) }
    function script:Get-FixItHwBattery { if ($script:Broken['Battery']) { throw 'no battery data' }; return $script:BatteryObj }
    function script:Get-FixItHwWindows { if ($script:Broken['Windows']) { throw 'no os' }; return [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; Version = '10.0.22631'; Build = '22631'; Arch = '64-bit'; UptimeHours = 75.5 } }
    function script:Get-FixItHwNetwork { if ($script:Broken['Network']) { throw 'no adapter' }; return [pscustomobject]@{ Name = 'Wi-Fi'; Description = 'Intel(R) Wi-Fi 6 AX201'; Kind = 'Wi-Fi'; BitsPerSecond = [uint64]866700000 } }
    $script:HddHealth = 'Healthy'; $script:DFree = 400GB
    $script:BatteryObj = [pscustomobject]@{ Present = $true; ChargePercent = 83; State = 'plugged in'; HealthPercent = 71 }
}
Set-Pretend
$hw = Get-FixItHardwareInfo
$sec = @(Get-FixItHardwareSections -Hw $hw)
$byTitle = @{}; foreach ($x in $sec) { $byTitle[$x.Title] = $x }
Assert (($sec | ForEach-Object { $_.Title }) -join '|' -eq 'Computer|Processor|Memory (RAM)|Drives|Graphics and screen|Battery|Windows and network') 'the sections are Computer, Processor, Memory, Drives, Graphics, Battery, Windows and network'
function RowOf { param([string]$Sec, [string]$Label) return (@($byTitle[$Sec].Rows | Where-Object { $_.Label -eq $Label })[0]) }
Assert ((RowOf 'Computer' 'Maker').Value -eq 'Dell Inc.' -and (RowOf 'Computer' 'Model').Value -eq 'XPS 13 9310' -and (RowOf 'Computer' 'Serial number').Value -eq 'ABC1234' -and (RowOf 'Computer' 'BIOS date').Value -eq '2024-03-05') 'computer: maker, model, serial number, BIOS date'
Assert ((RowOf 'Processor' 'Cores').Value -eq '4 cores, 8 threads' -and (RowOf 'Processor' 'Busy right now').Value -eq '12%' -and (RowOf 'Processor' 'Busy right now').Percent -eq 12 -and (RowOf 'Processor' 'Name').Value -match 'i7-1185G7') 'processor: name, cores and threads, load'
$mm = RowOf 'Memory (RAM)' 'In use'
Assert ($mm.Value -eq '10.0 GB of 16.0 GB (63% used)' -and $mm.Percent -eq 63) 'memory: used of total with the percent (16 GB, 6 GB free -> 63% used)'
Assert ((RowOf 'Memory (RAM)' 'Free').Value -eq '6.0 GB' -and (RowOf 'Memory (RAM)' 'Memory sticks').Value -eq '2' -and (RowOf 'Memory (RAM)' 'Speed').Value -eq '3200 MHz' -and (RowOf 'Memory (RAM)' 'Free memory slots').Value -eq '2 of 4') 'memory: free GB, sticks, speed, free slots (2 of 4)'
Assert ((RowOf 'Drives' 'Disk 1').Value -eq 'Samsung SSD 970 EVO - NVMe SSD - 500.0 GB - health: Healthy' -and (RowOf 'Drives' 'Disk 2').Value -eq 'WDC WD10EZEX - HDD - 1,000.0 GB - health: Healthy') 'drives: each disk shows model, type, size and health'
Assert ((RowOf 'Drives' 'C: (Windows)').Value -eq '400.0 GB used of 500.0 GB - 100.0 GB free (80% used)' -and (RowOf 'Drives' 'C: (Windows)').Percent -eq 80) 'drive letter: used, total, free and percent'
Assert (@($byTitle['Drives'].Notes).Count -eq 0) 'nothing over 90% and every disk healthy: no notes at all'
Assert ((RowOf 'Graphics and screen' 'Screen size').Value -eq '1920 x 1080 at 60 Hz' -and (RowOf 'Graphics and screen' 'Graphics card').Value -match 'Iris') 'graphics card and screen size'
Assert ((RowOf 'Battery' 'Charge').Value -eq '83% (plugged in)' -and (RowOf 'Battery' 'Battery health').Value -eq 'holds 71% of its original charge') 'laptop: battery charge and health'
Assert ((RowOf 'Windows and network' 'Windows').Value -match 'Windows 11 Pro \(version 10\.0\.22631, build 22631, 64-bit\)' -and (RowOf 'Windows and network' 'Turned on for').Value -eq '3 days, 3 hours' -and (RowOf 'Windows and network' 'Network').Value -eq 'Wi-Fi - Intel(R) Wi-Fi 6 AX201, speed 866.7 Mbps') 'Windows version, uptime and the network adapter with its speed'
# notes
$script:DFree = 90GB; $script:HddHealth = 'Warning'
$sec2 = @(Get-FixItHardwareSections -Hw (Get-FixItHardwareInfo))
$notes = @($sec2 | Where-Object { $_.Title -eq 'Drives' })[0].Notes
Assert (@($notes).Count -eq 2 -and ($notes -join ' ') -match 'Drive D: is almost full \(91% used\)' -and ($notes -join ' ') -match 'Disk 2 \(WDC WD10EZEX\) says it is not healthy\. Please tell Trey\.') 'over 90% full gets one mild note; an unhealthy disk gets one mild note'
$script:DFree = 100GB
$d90 = @(Get-FixItHardwareSections -Hw (Get-FixItHardwareInfo) | Where-Object { $_.Title -eq 'Drives' })[0]
Assert (@($d90.Notes).Count -eq 1) 'exactly 90% full is not over 90% (only the unhealthy disk is noted)'
$script:HddHealth = 'Healthy'
foreach ($k in @('Computer', 'Cpu', 'Memory', 'Disks', 'Volumes', 'Graphics', 'Battery', 'Windows', 'Network')) {
    Set-Pretend; $script:Broken[$k] = $true
    $s3 = @(Get-FixItHardwareSections -Hw (Get-FixItHardwareInfo))
    $txt = (Format-FixItHardwareText -Sections $s3) -join "`n"
    $others = 0; foreach ($o in @('Dell Inc.', 'i7-1185G7', '3200 MHz', 'Samsung SSD', 'C: \(Windows\)', 'Iris', 'plugged in', 'Windows 11 Pro', 'Wi-Fi 6')) { if ($txt -match $o) { $others++ } }
    Assert ($txt -match 'not available' -and $others -ge 7) "if only the $k piece cannot be read, it says ""not available"" and every other piece still shows ($others of 9 others found)"
}
Set-Pretend; $script:BatteryObj = [pscustomobject]@{ Present = $false; ChargePercent = $null; State = ''; HealthPercent = $null }
$bs = @(Get-FixItHardwareSections -Hw (Get-FixItHardwareInfo) | Where-Object { $_.Title -eq 'Battery' })[0]
Assert ($bs.Rows[0].Value -eq 'this computer has no battery') 'a desktop says it has no battery'
Set-Pretend
function script:Get-FixItHwMemory { return [pscustomobject]@{ TotalBytes = 8 * $GB; FreeBytes = 2 * $GB; Sticks = $null; SpeedMHz = $null; Slots = $null } }
$ms = @(Get-FixItHardwareSections -Hw (Get-FixItHardwareInfo) | Where-Object { $_.Title -like 'Memory*' })[0]
Assert ((@($ms.Rows | Where-Object { $_.Label -eq 'Free memory slots' })[0]).Value -eq 'not available' -and (@($ms.Rows | Where-Object { $_.Label -eq 'In use' })[0]).Value -match '75% used') 'memory slots unreadable: only that row says "not available"'
Set-Pretend
Assert ((Get-FixItDriveKind -MediaType 'SSD' -BusType 'SATA') -eq 'SSD' -and (Get-FixItDriveKind -MediaType 'SSD' -BusType 'NVMe') -eq 'NVMe SSD' -and (Get-FixItDriveKind -MediaType 'Unspecified' -BusType 'NVMe') -eq 'NVMe SSD' -and (Get-FixItDriveKind -MediaType 'HDD' -BusType 'SATA') -eq 'HDD' -and (Get-FixItDriveKind -MediaType 'Unspecified' -BusType 'USB') -eq 'USB drive' -and (Get-FixItDriveKind -MediaType 'Unspecified' -BusType 'SATA') -eq 'type not known') 'drive type: SSD, NVMe SSD, HDD, USB drive, or "type not known"'
Assert ((Format-FixItLinkSpeed 1000000000) -eq '1 Gbps' -and (Format-FixItLinkSpeed 100000000) -eq '100 Mbps' -and (Format-FixItLinkSpeed 2400000000) -eq '2.4 Gbps' -and (Format-FixItLinkSpeed $null) -eq '' -and (Format-FixItLinkSpeed 0) -eq '') 'link speed in plain words'
Assert ((Format-FixItUptime 0.5) -eq 'less than an hour' -and (Format-FixItUptime 5) -eq '5 hours' -and (Format-FixItUptime 1) -eq '1 hour' -and (Format-FixItUptime 24.5) -eq '24 hours' -and (Format-FixItUptime 49) -eq '2 days, 1 hour' -and (Format-FixItUptime $null) -eq '') 'uptime in plain words'
Assert ((Get-FixItPercentUsed -Total 0 -Free 0) -eq $null -and (Get-FixItPercentUsed -Total 100 -Free 0) -eq 100 -and (Get-FixItPercentUsed -Total 100 -Free 100) -eq 0 -and (Get-FixItPercentUsed -Total 100 -Free 150) -eq 0) 'percent used never goes below 0 or above 100, and is blank for an empty drive'

Section 'My PC info: the result, Copy, the report'
$script:TestGuid = '1B2C3D4E-0000-4000-8000-ABCDEF012345'
function Get-FixItMachineGuid { return $script:TestGuid }
function Get-FixItOsInfo { return [pscustomobject]@{ ComputerName = 'TESTPC'; UserName = 'tester'; Caption = 'Windows 11 Pro'; Version = '10.0.22631'; Build = '22631'; Arch = '64-bit'; LastBoot = (Get-Date); FreeGB = 100 } }
function Get-FixItAppIcon { return $null }
$r = Invoke-PcInfo
Assert ($r.Ok -and $r.PcInfo -and @($r.Sections).Count -eq 7 -and $r.CopyText -match 'PC code: ' -and $r.CopyText -match 'Samsung SSD 970 EVO' -and $r.CopyText -match 'Serial number: ABC1234') 'My PC info: the result carries the sections and the copy text has the hardware'
Assert ($r.CopyText -match 'PC name: TESTPC' -and ($r.Details -join "`n") -match 'TESTPC') 'My PC info: the old name, Windows and code lines are still there'
$script:Clip = ''
function Set-FixItClipboard { param([string]$Text) $script:Clip = $Text; return $true }
Assert ((Copy-FixItPcInfo) -and $script:Clip -eq $r.CopyText) 'the Copy button puts the whole text (code and hardware) on the clipboard'
$script:DryRun = $true; $script:Clip = ''
Assert ((Copy-FixItPcInfo) -and $script:Clip -eq '') 'practice run: nothing is copied'
$script:DryRun = $false
foreach ($k in @('Computer', 'Cpu', 'Memory', 'Disks', 'Volumes', 'Graphics', 'Battery', 'Windows', 'Network')) { Set-Pretend; $script:Broken[$k] = $true }
Set-Pretend
foreach ($f in @('Computer', 'Cpu', 'Memory', 'Disks', 'Volumes', 'Graphics', 'Battery', 'Windows', 'Network')) { $script:Broken[$f] = $true }
$r2 = Invoke-PcInfo
Assert ($r2.Ok -and $r2.CopyText -match 'PC code' -and $r2.CopyText -match 'not available') 'every piece unreadable: My PC info still opens, with the PC code and "not available"'
Set-Pretend
$rep = Get-FixItReportText -Kind 'report'
Assert ($rep -match '=== Hardware ===' -and $rep -match 'Samsung SSD 970 EVO' -and $rep -match 'Free memory slots: 2 of 4') '"Send Trey a report" has the hardware section'
foreach ($f in @('Computer', 'Cpu', 'Memory', 'Disks', 'Volumes', 'Graphics', 'Battery', 'Windows', 'Network')) { $script:Broken[$f] = $true }
$script:Broken['Cpu'] = $true
function script:Get-FixItHwCpu { throw 'Access is denied. Unauthorized: the operation failed with an exception' }
$rep2 = Get-FixItReportText -Kind 'report'
$hwOnly = ($rep2 -split "`n"); $i0 = [array]::IndexOf(@($hwOnly | ForEach-Object { $_.TrimEnd() }), '=== Hardware ===')
$hwOnly = ($hwOnly | Select-Object -Skip $i0 -First 40) -join "`n"
$hwOnly = ($hwOnly -split '=== Printing ===')[0]
Assert ($hwOnly -match 'not available' -and $hwOnly -notmatch '(?i)denied|failed|unauthorized|exception|could not read') 'the hardware part of a report never prints error words (only "not available")'
Assert ((Get-Log) -notmatch '\[WARN\][^\r\n]*[Hh]ardware') 'an unreadable hardware piece is not logged as a warning'
Set-Pretend

Section 'My PC info: Test mode'
Set-TestModeOn
Start-FixItTestButton
$script:Broken['Disks'] = $true
$r = Invoke-PcInfo
$recs = @(Get-FixItTestRecords)
$pieceRecs = @($recs | Where-Object { $_.Step -like 'My PC info:*' })
Assert ($pieceRecs.Count -eq 9) 'Test mode checks each of the nine pieces separately'
Assert (@($pieceRecs | Where-Object { $_.Step -like '*the disks' })[0].Status -eq 'WARN' -and @($pieceRecs | Where-Object { $_.Status -eq 'PASS' }).Count -eq 8) 'a piece that cannot be read is a WARN note; the rest PASS'
Assert (@($recs | Where-Object { $_.Status -eq 'FAIL' }).Count -eq 0) 'nothing fails in Test mode'
Restore-Modes
Set-Pretend
$tk = @($script:TestAllKeys)
Assert ($tk -contains 'PCInfo') 'Test all buttons includes My PC info'
$t = (Get-FixItActionTable)['PCInfo']
Assert ($t.Fn -eq 'Invoke-PcInfo' -and -not $t.Fix) 'My PC info is a read-only action (not a fix)'
# the window code
Assert ($srcText -match 'function Show-FixItPcInfoForm' -and $srcText -match 'Copy' -and $srcText -match 'AutoScroll') 'the My PC info window scrolls and keeps its Copy button'
Assert ((Get-FixItBarColor -Percent 50) -eq '#0F6CBD' -and (Get-FixItBarColor -Percent 91) -eq '#C75B00' -and (Get-FixItBarColor -Percent 90) -eq '#0F6CBD' -and (Get-FixItBarColor -Percent 91 -HighContrast $true) -eq '#FF8000') 'bar colour: blue, amber over 90%, readable in high contrast'

# ================================================================ 8. hardware monitor: thresholds (pure)
Section 'Hardware monitor: every threshold'
function D { param([string]$Health = 'Healthy', [string]$Status = 'OK', [string]$Id = 'a|1', [string]$Model = 'Disk A') return [pscustomobject]@{ Id = $Id; Model = $Model; Health = $Health; Status = $Status } }
function Rel { param($Wear = $null, $Temp = $null, $TempMax = $null, $Errs = $null, [string]$Id = 'a|1') return [pscustomobject]@{ Id = $Id; Name = 'Disk A'; Wear = $Wear; Temperature = $Temp; TemperatureMax = $TempMax; ReadErrorsUncorrected = $Errs } }
function Ev { param($B = 0, $S = 0, $W = 0, $WM = 0, $MD = 0) return [pscustomobject]@{ BugChecks = $B; Shutdowns = $S; WheaErrors = $W; WheaMemory = $WM; MemoryDiagnosticErrors = $MD } }
function Vol { param([string]$L = 'C:', [double]$Total = 100GB, [double]$Free = 50GB, [bool]$Removable = $false) return [pscustomobject]@{ Letter = $L; Total = $Total; Free = $Free; Removable = $Removable } }
function Fnd { param($Disks = $null, $Rel = $null, $Prev = $null, $Events = $null, $Battery = $null, $Vols = $null) return (Get-FixItHardwareFindings -Disks $Disks -Reliability $Rel -Previous $Prev -Events $Events -Battery $Battery -Volumes $Vols) }
$storage = "Your computer's storage drive is starting to fail. Please call Trey soon."
$f = Fnd -Disks @(D 'Healthy')
Assert (@($f.Alerts).Count -eq 0) 'a healthy disk: no alert'
$f = Fnd -Disks @(D 'Unhealthy')
Assert (@($f.Alerts).Count -eq 1 -and $f.Alerts[0].Message -eq $storage -and $f.Alerts[0].Kind -eq 'Storage') 'disk Unhealthy: the exact message "Your computer''s storage drive is starting to fail. Please call Trey soon."'
$f = Fnd -Disks @(D 'Warning')
Assert (@($f.Alerts).Count -eq 1 -and $f.Alerts[0].Message -eq $storage) 'disk Warning: the same message'
$f = Fnd -Disks @(D 'Healthy' 'Predictive Failure')
Assert (@($f.Alerts).Count -eq 1) 'disk status "Predictive Failure": serious'
$f = Fnd -Disks @(D 'Healthy' 'Lost Communication')
Assert (@($f.Alerts).Count -eq 0 -and (($f.Info -join '|') -match 'Lost Communication')) 'an odd but not failing disk status is only noted in the report'
$f = Fnd -Disks @(D 'Unknown' '')
Assert (@($f.Alerts).Count -eq 0) 'health "Unknown" is not an alert'
$f = Fnd -Rel @(Rel -Wear 89)
Assert (@($f.Alerts).Count -eq 0) 'SSD wear 89%: no alert'
$f = Fnd -Rel @(Rel -Wear 90)
Assert (@($f.Alerts).Count -eq 1 -and $f.Alerts[0].Message -eq $storage -and $f.Alerts[0].Detail -match '90%') 'SSD wear 90%: alert (the storage message)'
$f = Fnd -Rel @(Rel -Wear 100)
Assert (@($f.Alerts).Count -eq 1) 'SSD wear 100%: alert'
$f = Fnd -Rel @(Rel -Errs 5) -Prev @{ 'a|1' = @{ ReadErrors = 5 } }
Assert (@($f.Alerts).Count -eq 0) 'uncorrected read errors unchanged: no alert'
$f = Fnd -Rel @(Rel -Errs 6) -Prev @{ 'a|1' = @{ ReadErrors = 5 } }
Assert (@($f.Alerts).Count -eq 1 -and $f.Alerts[0].Detail -match 'rose from 5 to 6') 'uncorrected read errors rose (5 to 6): alert'
$f = Fnd -Rel @(Rel -Errs 6) -Prev ('{"a|1":{"ReadErrors":5,"At":"2026-10-22T10:00:00"}}' | ConvertFrom-Json)
Assert (@($f.Alerts).Count -eq 1) 'the previous run read back from the state file (JSON) works the same'
$f = Fnd -Rel @(Rel -Errs 3) -Prev @{ }
Assert (@($f.Alerts).Count -eq 0 -and ($f.Info -join '|') -match 'uncorrected read errors 3') 'first run (nothing to compare with): errors are only reported, not raised'
$f = Fnd -Rel @(Rel -Errs 3) -Prev @{ 'other|9' = @{ ReadErrors = 0 } }
Assert (@($f.Alerts).Count -eq 0) 'a different disk in the saved list does not count'
$f = Fnd -Rel @(Rel -Errs 2) -Prev @{ 'a|1' = @{ ReadErrors = 5 } }
Assert (@($f.Alerts).Count -eq 0) 'errors that went down (a replaced disk, a reset): no alert'
$f = Fnd -Rel @(Rel -Temp 80 -TempMax 70)
Assert (@($f.Alerts).Count -eq 0 -and (($f.Info -join '|') -match 'temperature limit')) 'a disk at or above its temperature limit: report only, no message to the person'
$f = Fnd -Rel @(Rel -Temp 40 -TempMax 70)
Assert (-not (($f.Info -join '|') -match 'temperature limit')) 'a cool disk: no temperature note'
$f = Fnd -Rel @((Rel))
Assert (@($f.Alerts).Count -eq 0) 'a disk with no counters at all: nothing to say'
$crash = 'Your computer has crashed or turned itself off several times this week. Please call Trey soon.'
$f = Fnd -Events (Ev -B 2 -S 2)
Assert (@($f.Alerts).Count -eq 0) '2 blue screens and 2 unexpected shutdowns: no alert (it has to be MORE than 2)'
$f = Fnd -Events (Ev -B 3)
Assert (@($f.Alerts).Count -eq 1 -and $f.Alerts[0].Message -eq $crash) '3 blue screens in 7 days: alert'
$f = Fnd -Events (Ev -S 3)
Assert (@($f.Alerts).Count -eq 1 -and $f.Alerts[0].Message -eq $crash) '3 unexpected shutdowns in 7 days: alert'
$f = Fnd -Events (Ev -B 3 -S 9)
Assert (@($f.Alerts).Count -eq 1) 'blue screens and shutdowns together are one alert'
$f = Fnd -Events (Ev -B 1 -S 1 -W 4)
Assert (@($f.Alerts).Count -eq 0 -and ($f.Info -join '|') -match 'WHEA') 'a few hardware error events (WHEA) with no crash pattern: report only'
$f = Fnd -Events ([pscustomobject]@{ BugChecks = $null; Shutdowns = $null; WheaErrors = $null; WheaMemory = $null; MemoryDiagnosticErrors = $null })
Assert (@($f.Alerts).Count -eq 0 -and @($f.Info).Count -eq 0) 'event logs that could not be read: skipped quietly'
$memMsg = "Your computer's memory is reporting errors. Please call Trey soon."
$f = Fnd -Events (Ev -WM 1)
Assert (@($f.Alerts).Count -eq 1 -and $f.Alerts[0].Message -eq $memMsg) 'a hardware memory error event: alert'
$f = Fnd -Events (Ev -MD 1)
Assert (@($f.Alerts).Count -eq 1 -and $f.Alerts[0].Message -eq $memMsg) 'the Windows memory test reported errors: alert'
$f = Fnd -Events (Ev)
Assert (@($f.Alerts).Count -eq 0 -and ($f.Info -join '|') -match 'Memory errors: none') 'no memory errors: reported as none'
$f = Fnd -Battery ([pscustomobject]@{ Present = $true; HealthPercent = 49; ChargePercent = 80; State = '' })
Assert (@($f.Alerts).Count -eq 0 -and ($f.Info -join '|') -match 'Battery is worn') 'battery under 50% of its original charge: report only, no message'
$f = Fnd -Battery ([pscustomobject]@{ Present = $true; HealthPercent = 50; ChargePercent = 80; State = '' })
Assert (-not (($f.Info -join '|') -match 'Battery is worn')) 'battery at exactly 50%: not worn'
$f = Fnd -Battery ([pscustomobject]@{ Present = $false; HealthPercent = $null; ChargePercent = $null; State = '' })
Assert (@($f.Alerts).Count -eq 0 -and @($f.Info).Count -eq 0) 'a desktop (no battery): skipped'
$f = Fnd -Battery ([pscustomobject]@{ Present = $true; HealthPercent = $null; ChargePercent = 50; State = '' })
Assert (@($f.Alerts).Count -eq 0 -and @($f.Info).Count -eq 0) 'a battery whose capacity cannot be read: skipped quietly'
$full = 'A drive on your computer is almost full. Please call Trey soon.'
$f = Fnd -Vols @(Vol 'C:' 100GB 10GB)
Assert (@($f.Alerts).Count -eq 0) 'a drive exactly 90% full: no alert'
$f = Fnd -Vols @(Vol 'C:' 100GB 9GB)
Assert (@($f.Alerts).Count -eq 1 -and $f.Alerts[0].Message -eq $full -and $f.Alerts[0].Key -eq 'full:C:') 'a drive 91% full: alert'
$f = Fnd -Vols @(Vol 'E:' 100GB 1GB $true)
Assert (@($f.Alerts).Count -eq 0) 'a full USB stick is not raised'
$f = Fnd -Vols @(Vol 'C:' 100GB 5GB), (Vol 'D:' 100GB 4GB)
Assert (@($f.Alerts).Count -eq 2 -and (@($f.Alerts | ForEach-Object { $_.Key }) -join ',') -eq 'full:C:,full:D:') 'two full drives: two alerts with their own keys'
$f = Fnd -Vols @([pscustomobject]@{ Letter = 'Z:'; Total = 0; Free = 0; Removable = $false })
Assert (@($f.Alerts).Count -eq 0) 'an empty drive is ignored'
Assert (@(Fnd).Count -ge 0 -and @((Fnd).Alerts).Count -eq 0) 'nothing could be read at all: nothing to say'
$ff = Fnd -Disks @(D 'Unhealthy') -Rel @((Rel -Wear 95)) -Events (Ev -B 5 -WM 2) -Vols @(Vol 'C:' 100GB 2GB)
Assert (@($ff.Alerts).Count -eq 5) 'five different serious problems found together'
$m = Get-FixItHardwareMessage -Alerts $ff.Alerts
Assert (($m -split "`r`n`r`n").Count -eq 4 -and ([regex]::Matches($m, [regex]::Escape($storage))).Count -eq 1) 'they become ONE message; the same sentence is never repeated'
Assert ((Get-FixItHardwareMessage -Alerts @()) -eq '') 'no alerts: no message'
foreach ($mk in @('Storage', 'Crashes', 'Memory', 'Full')) { $mt = [string]$script:HwMessages[$mk]; Assert ($mt -match 'Please call Trey soon\.$' -and $mt -notmatch '(?i)SMART|WHEA|bugcheck|kernel|SSD wear|sector|firmware') "the $mk message is plain, with no jargon" }

# ================================================================ 9. hardware monitor: once a week
Section 'Hardware monitor: the same alert at most once a week'
$a1 = [pscustomobject]@{ Key = 'disk:a|1'; Kind = 'Storage'; Message = $storage; Detail = 'x' }
$a2 = [pscustomobject]@{ Key = 'crashes'; Kind = 'Crashes'; Message = $crash; Detail = 'y' }
$n = [datetime]'2026-11-01T10:00:00'
function Stamp { param([double]$DaysAgo) return $n.AddDays(-$DaysAgo).ToString('s') }
Assert (@(Select-FixItNewHardwareAlerts -Alerts @($a1, $a2) -Sent $null -Now $n).Count -eq 2) 'nothing sent before: both are new'
Assert (@(Select-FixItNewHardwareAlerts -Alerts @($a1, $a2) -Sent @{} -Now $n).Count -eq 2) 'empty history: both are new'
Assert (@(Select-FixItNewHardwareAlerts -Alerts @($a1) -Sent @{ 'disk:a|1' = (Stamp 0.01) } -Now $n).Count -eq 0) 'sent a moment ago: not again'
Assert (@(Select-FixItNewHardwareAlerts -Alerts @($a1) -Sent @{ 'disk:a|1' = (Stamp 6.9) } -Now $n).Count -eq 0) 'sent 6.9 days ago: not again'
Assert (@(Select-FixItNewHardwareAlerts -Alerts @($a1) -Sent @{ 'disk:a|1' = (Stamp 7) } -Now $n).Count -eq 1) 'sent exactly 7 days ago: new again'
Assert (@(Select-FixItNewHardwareAlerts -Alerts @($a1) -Sent @{ 'disk:a|1' = (Stamp 30) } -Now $n).Count -eq 1) 'sent a month ago: new again'
$mixed = @(Select-FixItNewHardwareAlerts -Alerts @($a1, $a2) -Sent @{ 'disk:a|1' = (Stamp 2) } -Now $n)
Assert ($mixed.Count -eq 1 -and $mixed[0].Key -eq 'crashes') 'each alert has its own timer (a drive alert 2 days ago does not hide a new crash alert)'
Assert (@(Select-FixItNewHardwareAlerts -Alerts @($a1) -Sent (('{"disk:a|1":"' + (Stamp 3) + '"}') | ConvertFrom-Json) -Now $n).Count -eq 0) 'the history read back from the state file (JSON) works the same'
Assert (@(Select-FixItNewHardwareAlerts -Alerts @($a1) -Sent @{ 'disk:a|1' = 'garbage' } -Now $n).Count -eq 1) 'an unreadable date counts as "never sent"'
Assert (@(Select-FixItNewHardwareAlerts -Alerts @($a1) -Sent @{ 'disk:a|1' = $n.AddDays(40).ToString('s') } -Now $n).Count -eq 1) 'a date far in the future (the clock was wrong) does not silence alerts for weeks'

# ================================================================ 10. hardware monitor: the whole run with pretend readers
Section 'Hardware monitor: the whole run, state file, message and report'
function Reset-Monitor {
    $sf = Get-FixItStateFile; if (Test-Path -LiteralPath $sf) { Remove-Item -LiteralPath $sf -Force }
    $script:Sent = New-Object System.Collections.ArrayList; $script:Shown = New-Object System.Collections.ArrayList
    $script:Pcs = @{ Disks = @(D 'Healthy'); Rel = @(Rel -Errs 0 -Wear 10 -Temp 35 -TempMax 70); Bat = $null; Vols = @(Vol 'C:' 100GB 60GB); B = 0; K = 0; E = 0; W = 0; WM = 0; MD = 0; RelThrows = $false; EvThrows = @() }
    $script:SendOk = $true; $script:ShowOk = $true
}
function script:Get-FixItHwDisks { if ($script:Pcs.Disks -eq 'throw') { throw 'x' }; return $script:Pcs.Disks }
function script:Get-FixItHwReliability { if ($script:Pcs.RelThrows) { throw 'Access is denied' }; return $script:Pcs.Rel }
function script:Get-FixItHwBattery { if ($null -eq $script:Pcs.Bat) { return [pscustomobject]@{ Present = $false; ChargePercent = $null; State = ''; HealthPercent = $null } }; return $script:Pcs.Bat }
function script:Get-FixItHwVolumes { return $script:Pcs.Vols }
function script:Get-FixItHwEventCount { param([string]$Provider, [int[]]$Ids = @(), [int]$Days = 7, [int[]]$Levels = @(), [string]$MessageLike = '')
    [void]$script:EvCalls.Add(('{0}|{1}|{2}|{3}|{4}' -f $Provider, ($Ids -join ','), $Days, ($Levels -join ','), $MessageLike))
    if (@($script:Pcs.EvThrows) -contains $Provider) { throw 'the log could not be read' }
    switch ($Provider) { 'Microsoft-Windows-WER-SystemErrorReporting' { return $script:Pcs.B } 'Microsoft-Windows-Kernel-Power' { return $script:Pcs.K } 'EventLog' { return $script:Pcs.E } 'Microsoft-Windows-WHEA-Logger' { if ($MessageLike) { return $script:Pcs.WM } else { return $script:Pcs.W } } 'Microsoft-Windows-MemoryDiagnostics-Results' { return $script:Pcs.MD } } }
function Send-FixItReport { param([string]$Text, [string]$Kind = 'report') [void]$script:Sent.Add([pscustomobject]@{ Text = $Text; Kind = $Kind }); return $script:SendOk }
function Show-FixItHardwareAlert { param([string]$Text) [void]$script:Shown.Add($Text); return $script:ShowOk }
$script:EvCalls = New-Object System.Collections.ArrayList
Reset-Monitor
$mon = Invoke-FixItHardwareMonitor
Assert (@($mon.Alerts).Count -eq 0 -and @($mon.NewAlerts).Count -eq 0 -and ($mon.Lines -join "`n") -match 'nothing - the drives, memory and crash history look fine') 'a healthy PC: no alert, a plain "nothing" line in the report'
$ec = @($script:EvCalls)
Assert (($ec -contains 'Microsoft-Windows-WER-SystemErrorReporting|1001|7||') -and ($ec -contains 'Microsoft-Windows-Kernel-Power|41|7||') -and ($ec -contains 'EventLog|6008|7||') -and ($ec -contains 'Microsoft-Windows-WHEA-Logger||7|1,2|') -and ($ec -contains 'Microsoft-Windows-WHEA-Logger||7||(?i)memory') -and ($ec -contains 'Microsoft-Windows-MemoryDiagnostics-Results|1102|30||')) 'it asks Windows for: bug check 1001, Kernel-Power 41, EventLog 6008, WHEA errors and WHEA memory (7 days), memory test results (1102)'
$st = Get-FixItHwSavedMap -Name 'HwPrev'
Assert ($st.ContainsKey('a|1') -and [int]$st['a|1'].ReadErrors -eq 0) 'this run''s uncorrected read error count is saved in the state file for next week'
# week 2: errors rose
$script:Pcs.Rel = @(Rel -Errs 4 -Wear 10)
$mon = Invoke-FixItHardwareMonitor
Assert (@($mon.Alerts).Count -eq 1 -and @($mon.NewAlerts).Count -eq 1 -and $mon.Alerts[0].Key -eq 'readerrors:a|1') 'a week later the errors rose from 0 to 4: one new alert'
$res = Invoke-FixItHardwareAlerts -Monitor $mon -HealthText ''
Assert ($res.Shown -and $res.Sent -and $script:Shown.Count -eq 1 -and $script:Shown[0] -eq $storage) 'the person sees exactly one plain message'
Assert ($script:Sent.Count -eq 1 -and $script:Sent[0].Kind -eq 'report' -and $script:Sent[0].Text -match 'HARDWARE ALERT' -and $script:Sent[0].Text -match 'rose from 0 to 4' -and $script:Sent[0].Text -match 'PC code:' -and $script:Sent[0].Text -match 'The family member was told:' -and $script:Sent[0].Text -match [regex]::Escape($storage)) 'Trey gets a full report right away (kind "report", the existing endpoint): what was found, what they were told, the PC code'
Assert ($script:Sent[0].Text -match 'Hardware monitor:') 'the report carries the monitor details'
Assert ($script:Sent[0].Text -match '(?m)^PC code: .*\r?\n^Name: not given\r?$' -or $script:Sent[0].Text -match '(?m)^Name: not given') 'the hardware alert report has the Name line near the top'
Assert ($script:Sent[0].Text.IndexOf('Name: ') -lt $script:Sent[0].Text.IndexOf('WHAT WAS FOUND')) 'and it comes before the findings'
$sentMap = Get-FixItHwSavedMap -Name 'HwAlertSent'
Assert ($sentMap.ContainsKey('readerrors:a|1')) 'the alert time is saved'
# immediately again (next check-in the same week)
$script:Pcs.Rel = @(Rel -Errs 9 -Wear 10)
$mon = Invoke-FixItHardwareMonitor
Assert (@($mon.Alerts).Count -eq 1 -and @($mon.NewAlerts).Count -eq 0) 'the problem is still there, but it was already reported this week: nothing new'
$script:Shown.Clear(); $script:Sent.Clear()
$res = Invoke-FixItHardwareAlerts -Monitor $mon -HealthText ''
Assert (-not $res.Shown -and -not $res.Sent -and $script:Shown.Count -eq 0 -and $script:Sent.Count -eq 0) 'so nothing is shown and nothing is sent'
# a different kind of problem is still reported at once
$script:Pcs.B = 5
$mon = Invoke-FixItHardwareMonitor
Assert (@($mon.NewAlerts).Count -eq 1 -and $mon.NewAlerts[0].Key -eq 'crashes') 'a different new problem (blue screens) is reported even though the drive alert is waiting out its week'
$res = Invoke-FixItHardwareAlerts -Monitor $mon
Assert ($script:Shown.Count -eq 1 -and $script:Shown[0] -eq $crash -and $script:Sent.Count -eq 1) 'one message with only the new problem'
# a week later it fires again
$old = @{ }; foreach ($k in (Get-FixItHwSavedMap -Name 'HwAlertSent').Keys) { $old[$k] = (Get-Date).AddDays(-8).ToString('s') }
Save-FixItHwSavedMap -Name 'HwAlertSent' -Map $old
$script:Pcs.Rel = @(Rel -Errs 30 -Wear 10)
$mon = Invoke-FixItHardwareMonitor
Assert (@($mon.NewAlerts).Count -eq 2) 'eight days later both problems are reported again'
# failure to tell anyone: try again next time
Reset-Monitor; $script:Pcs.Disks = @(D 'Unhealthy'); $script:SendOk = $false; $script:ShowOk = $false
$mon = Invoke-FixItHardwareMonitor
$res = Invoke-FixItHardwareAlerts -Monitor $mon
Assert (-not $res.Sent -and -not $res.Shown -and -not (Get-FixItHwSavedMap -Name 'HwAlertSent').ContainsKey('disk:a|1')) 'if neither the message nor the report got through, the alert is not marked as sent (it is tried again next time)'
$script:SendOk = $true; $script:ShowOk = $false
$mon = Invoke-FixItHardwareMonitor
$res = Invoke-FixItHardwareAlerts -Monitor $mon
Assert ($res.Sent -and (Get-FixItHwSavedMap -Name 'HwAlertSent').ContainsKey('disk:a|1')) 'if the report got through, the alert counts as sent'
# skipped quietly
Reset-Monitor; $script:Pcs.Rel = @(Rel -Errs 4 -Wear 10)
[void](Invoke-FixItHardwareMonitor)
$script:Pcs.RelThrows = $true
$threw = $false; try { $mon = Invoke-FixItHardwareMonitor } catch { $threw = $true }
Assert (-not $threw -and @($mon.Alerts).Count -eq 0 -and ($mon.Lines -join "`n") -match 'not checked on this PC: the disk counters') 'a check that needs administrator rights and cannot get them is skipped: no error, no alert, a quiet line in the report'
Assert ([int](Get-FixItHwSavedMap -Name 'HwPrev')['a|1'].ReadErrors -eq 4) 'and last week''s saved numbers are kept, not wiped'
$script:Pcs.RelThrows = $false
$script:Pcs.EvThrows = @('Microsoft-Windows-Kernel-Power', 'EventLog')
$mon = Invoke-FixItHardwareMonitor
Assert (@($mon.Alerts).Count -eq 0 -and $null -eq $mon.Facts.Events.Shutdowns -and $mon.Facts.Events.BugChecks -eq 0) 'unreadable shutdown logs: shutdowns are unknown, the other checks carry on'
$script:Pcs.EvThrows = @('EventLog'); $script:Pcs.K = 4; $script:Pcs.E = 3
$mon = Invoke-FixItHardwareMonitor
Assert ($mon.Facts.Events.Shutdowns -eq 4 -and @($mon.Alerts).Count -eq 1) 'with only one of the two shutdown logs readable it is used on its own (4 > 2: alert)'
$script:Pcs.EvThrows = @(); $script:Pcs.K = 3; $script:Pcs.E = 3
$mon = Invoke-FixItHardwareMonitor
Assert ($mon.Facts.Events.Shutdowns -eq 3) 'Kernel-Power 41 and EventLog 6008 are the same shutdown: counted once (the larger number), not added'
# practice run and Test mode never show or send
Reset-Monitor; $script:Pcs.Disks = @(D 'Unhealthy')
$mon = Invoke-FixItHardwareMonitor
$script:DryRun = $true
$res = Invoke-FixItHardwareAlerts -Monitor $mon
Assert (-not $res.Shown -and -not $res.Sent -and $script:Shown.Count -eq 0 -and $script:Sent.Count -eq 0 -and (Get-Log) -match 'Would do: show') 'a practice run only says what it would do'
$script:DryRun = $false
Remove-Item Function:\Show-FixItHardwareAlert -ErrorAction SilentlyContinue
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v237b.log') -OutputDir $outDir; Initialize-FixItLog

# ================================================================ 11. the weekly check-in itself
Section 'Weekly check-in: report text, one extra message, no new task'
Reset-Monitor
function script:Get-FixItHwDisks { return $script:Pcs.Disks }
function script:Get-FixItHwReliability { return $script:Pcs.Rel }
function script:Get-FixItHwBattery { return [pscustomobject]@{ Present = $false; ChargePercent = $null; State = ''; HealthPercent = $null } }
function script:Get-FixItHwVolumes { return $script:Pcs.Vols }
function script:Get-FixItHwEventCount { param([string]$Provider, [int[]]$Ids = @(), [int]$Days = 7, [int[]]$Levels = @(), [string]$MessageLike = '') switch ($Provider) { 'Microsoft-Windows-WER-SystemErrorReporting' { return $script:Pcs.B } default { return 0 } } }
function Send-FixItReport { param([string]$Text, [string]$Kind = 'report') [void]$script:Sent.Add([pscustomobject]@{ Text = $Text; Kind = $Kind }); return $true }
function Show-FixItHardwareAlert { param([string]$Text) [void]$script:Shown.Add($Text); return $true }
function Get-FixItHealthSummary { return [pscustomobject]@{ Lines = @('Computer: TESTPC'); Attention = @() } }
$script:Pcs.Disks = @(D 'Healthy'); $script:Pcs.Rel = @(Rel -Errs 0); $script:Pcs.Vols = @(Vol 'C:' 100GB 60GB)
Set-Pretend
$r = Invoke-HealthCheck
Assert ($r.Ok -and $script:Sent.Count -eq 1 -and $script:Sent[0].Kind -eq 'health' -and $script:Shown.Count -eq 0) 'a healthy PC: the normal weekly report only, nothing shown to the person'
$wk = $script:Sent[0].Text
Assert ($wk -match 'ATTENTION: nothing - all fine' -and $wk -match 'Hardware monitor:' -and $wk -match 'HARDWARE SUMMARY:' -and $wk -match 'Samsung SSD 970 EVO') 'the weekly report has the monitor and the hardware summary'
Assert ($wk -match '(?m)^Name: not given' -and $wk.IndexOf('Name: ') -lt $wk.IndexOf('ATTENTION:')) 'the weekly check-in has the Name line above the attention list'
Reset-Monitor; $script:Pcs.Disks = @(D 'Unhealthy'); $script:Pcs.Rel = @(Rel -Errs 0); $script:Pcs.Vols = @(Vol 'C:' 100GB 60GB)
function script:Get-FixItHwDisks { return $script:Pcs.Disks }
function script:Get-FixItHwReliability { return $script:Pcs.Rel }
function script:Get-FixItHwVolumes { return $script:Pcs.Vols }
$r = Invoke-HealthCheck
Assert ($script:Sent.Count -eq 2 -and $script:Sent[0].Text -match 'HARDWARE ALERT' -and $script:Sent[0].Kind -eq 'report' -and $script:Sent[1].Kind -eq 'health') 'a serious problem: Trey gets the full alert report and the weekly report'
Assert ($script:Shown.Count -eq 1 -and $script:Shown[0] -eq $storage) 'the person sees one plain message'
Assert ($script:Sent[1].Text -match 'ATTENTION:' -and $script:Sent[1].Text -match 'reports health Unhealthy') 'the weekly report lists it under ATTENTION'
$script:Sent.Clear(); $script:Shown.Clear()
$r = Invoke-HealthCheck
Assert ($script:Sent.Count -eq 1 -and $script:Sent[0].Kind -eq 'health' -and $script:Shown.Count -eq 0) 'the next check-in the same week: the weekly report only (no second message, no second alert report)'
# no new scheduled task
$regCalls = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Register-FixItTask' }, $true))
Assert ($regCalls.Count -eq 1) 'the program still creates only the one weekly check-in task (no new scheduled task)'
Assert (@([regex]::Matches($srcText, 'CheckInTaskName\s*=')).Count -eq 1 -and $srcText -notmatch 'Register-ScheduledTask') 'there is one task name and no other task code'
$cx = Get-FixItCheckInXml -ScriptPath 'C:\x\FamilyFixIt.ps1'
Assert ($cx -match '-Action HealthCheck' -and $cx -match 'LeastPrivilege' -and ([regex]::Matches($cx, '<Exec>')).Count -eq 1) 'the task is unchanged: one action, no administrator rights'
# read-only
$mutCmd = '^(Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|Remove-Item|Copy-Item|Move-Item|New-Item|Rename-Item|Set-Content|Add-Content|Out-File|Stop-Process|Stop-Service|Start-Service|Restart-Service|Set-Service|Start-Process|Restart-Computer|Stop-Computer|Clear-RecycleBin|Invoke-WebRequest|Invoke-RestMethod|Register-ScheduledTask|Unregister-ScheduledTask|Set-Clipboard|Set-PhysicalDisk|Repair-Volume|Optimize-Volume|Clear-Disk|Initialize-Disk|Format-Volume|Set-Disk|Reset-PhysicalDisk|Start-MpScan|schtasks(\.exe)?|reg(\.exe)?|netsh(\.exe)?|chkdsk(\.exe)?|sfc(\.exe)?|DISM(\.exe)?|wmic(\.exe)?)$'
$hwFns = @($allFns | Where-Object { $_.Name -match '^(Get-FixItHw|Get-FixItHardware|Format-FixItHardware|Invoke-FixItHardware|Select-FixItNewHardware|Get-FixItDriveKind|Format-FixItGb|Format-FixItLinkSpeed|Format-FixItUptime|Get-FixItPercentUsed)' })
Assert ($hwFns.Count -ge 25) ('found the hardware functions (' + $hwFns.Count + ')')
$bad = @(); foreach ($fn in $hwFns) { foreach ($c in $fn.FindAll({ param($x) $x -is [Management.Automation.Language.CommandAst] }, $true)) { $nm = $c.GetCommandName(); if ($nm -and $nm -match $mutCmd) { $bad += ($fn.Name + ':' + $nm) } } }
Assert ($bad.Count -eq 0) ('no hardware function runs a changing command (' + ($bad -join ', ') + ')')
$readerNames = @($hwFns | Where-Object { $_.Name -match '^Get-FixItHw(Computer|Cpu|Memory|Disks|Volumes|Graphics|Battery|Windows|Network|Reliability|EventCount)$' })
Assert ($readerNames.Count -eq 11) 'there are eleven readers'
$noOff = @($readerNames | Where-Object { $_.Extent.Text -notmatch 'Test-FixItOffUiWanted' -or $_.Extent.Text -notmatch '-TimeoutSeconds \$script:HwSeconds' }); 
Assert ($noOff.Count -eq 0) ('every reader runs off the window thread with a time limit (' + (($noOff | ForEach-Object { $_.Name }) -join ',') + ')')
Assert ($script:HwSeconds -le 30 -and $script:HwSeconds -ge 10) 'the time limit is short (so a stuck Windows question cannot freeze the window)'
$wmiFree = @($readerNames | Where-Object { $_.Extent.Text -match 'Win32_Product|Get-Content|Invoke-Expression' }); Assert ($wmiFree.Count -eq 0) 'no slow or risky query is used'
# monitor in Test mode
Remove-Item Function:\Send-FixItReport, Function:\Show-FixItHardwareAlert -ErrorAction SilentlyContinue
$script:Sent.Clear(); $script:Shown.Clear()
function Send-FixItReport { param([string]$Text, [string]$Kind = 'report') [void]$script:Sent.Add($Kind); return $true }
function Show-FixItHardwareAlert { param([string]$Text) [void]$script:Shown.Add($Text); return $true }
Reset-Monitor; $script:Pcs.Disks = @(D 'Unhealthy')
Set-TestModeOn
Start-FixItTestButton
$mon = Invoke-FixItHardwareMonitor
$res = Invoke-FixItHardwareAlerts -Monitor $mon
$recs = @(Get-FixItTestRecords)
Assert (@($recs | Where-Object { $_.Step -eq 'Hardware monitor' -and $_.Status -eq 'PASS' }).Count -eq 1) 'Test mode: the hardware monitor check is a PASS note (no change)'
$w = @($recs | Where-Object { $_.Step -eq 'Hardware monitor: serious problem' })
Assert ($w.Count -eq 1 -and $w[0].Status -eq 'WARN' -and $w[0].Checks[0].Text -match 'WOULD show this one message') 'Test mode: a real problem says what a real run WOULD show and send'
Assert ($script:Shown.Count -eq 0 -and $script:Sent.Count -eq 0) 'Test mode: nothing is shown and nothing is sent'
Assert (-not (Test-Path -LiteralPath (Get-FixItStateFile)) -or -not ((Get-Content -LiteralPath (Get-FixItStateFile) -Raw) -match 'HwAlertSent')) 'Test mode: nothing is written to the state file'
Restore-Modes
# the consent text tells the truth
$ci = (Get-Fn 'Invoke-CheckInToggle').Extent.Text
Assert ($ci -match 'drives, memory and battery' -and $ci -match 'never sends your files') 'the check-in question mentions the hardware check and still promises no files or passwords'

# ================================================================ 7. "Thank Trey" (always shown, opens one link)
Section 'Thank Trey: always shown, exact link'
Restore-Modes
$stateF = Get-FixItStateFile
if (Test-Path -LiteralPath $stateF) { Remove-Item -LiteralPath $stateF -Force }
Assert ($script:DonateUrl -ceq 'https://paypal.me/TreyBarton') 'the link is exactly https://paypal.me/TreyBarton'
$lf = Get-FixItLayout -Simple $false
$ls = Get-FixItLayout -Simple $true
foreach ($pair in @(@('full', $lf), @('Simple', $ls))) {
    $nm = $pair[0]; $l = $pair[1]; $d = $l.Donate; $pn = $l.Pin
    Assert ($null -ne $d -and $d[0] -eq 'Donate' -and $d[1] -ceq 'Thank Trey' -and $d[2] -ceq 'Kids are expensive!' -and $d[3] -eq 'heart') ('always shown (' + $nm + ' window): "Thank Trey", the second line "Kids are expensive!" and a heart, with no setting needed')
    Assert ([int]$d[4] -ge ([int]$pn[4] + [int]$pn[5])) ('(' + $nm + ') directly under Pin to taskbar')
    $others = @(@($l.Nav) + @($l.Toggles) + @(,$l.Pin) | ForEach-Object { [int]$_[4] })
    Assert (@($others | Where-Object { $_ -gt [int]$d[4] }).Count -eq 0) ('(' + $nm + ') it is the last sidebar item')
    Assert ([int]$l.FullH -ge ([int]$d[4] + [int]$d[5])) ('(' + $nm + ') the window is tall enough for it')
    Assert ($pn[0] -eq 'Pin') ('(' + $nm + ') Pin to taskbar is still there')
}
# fits the sidebar (same width at every text size: the fonts and the bar scale together) and no longer than the existing two-line rows
$navs = @((Get-FixItLayout -Simple $false).Nav | Where-Object { $_[2] })
$maxSub = ($navs | ForEach-Object { ([string]$_[2]).Length } | Measure-Object -Maximum).Maximum
$maxTitle = ((@((Get-FixItLayout -Simple $false).Nav) + @((Get-FixItLayout -Simple $false).Toggles)) | ForEach-Object { ([string]$_[1]).Length } | Measure-Object -Maximum).Maximum
Assert (([string]$lf.Donate[2]).Length -le $maxSub -and ([string]$lf.Donate[1]).Length -le $maxTitle) 'both lines are no longer than the longest existing sidebar lines, so they fit the bar'
Assert ([int]$lf.Donate[5] -ge 52 -and [int]$ls.Donate[5] -ge 52) 'the item is tall enough for two lines (as tall as the other two-line rows)'
$paint = (Get-Fn 'Invoke-FixItSidePaint').Extent.Text
Assert ($paint -match 'if \(\$t\.Sub\)' -and $paint -match 'UiFonts\.SideSmall' -and $paint -match "\`$cSub = '#566070'" -and $paint -match 'if \(\$hc\) \{ \$cText = ''#FFFFFF''; \$cSub = ''#FFFFFF'' \}') 'the second line is drawn smaller and lighter than the first, and in white with High contrast'
Assert ($paint -match 'EndEllipsis' -and $paint -match '\$img = \$t\.Icon; if \(\$hc -and \$t\.IconW\)') 'long text is cut with ... instead of overlapping; High contrast uses the white heart'
$fontsText = $srcText
Assert ($fontsText -match 'dpi \* 1\.25') 'Big text scales the whole bar and its fonts together'
$wf = (Get-Fn 'Show-FixItWindowOnce')
Assert ($null -ne $wf -and $wf.Extent.Text -match 'if \(\$null -ne \$lay\.Donate\)' -and $wf.Extent.Text -match "New-FixItTile -Run \`$dd\[0\]") 'the window draws the item from the layout'
$heartOk = $true
foreach ($hk in @('heart', 'heartW')) {
    $hm = [regex]::Match($srcText, "'" + $hk + "' = '([A-Za-z0-9+/=]+)'")
    if (-not $hm.Success) { $heartOk = $false; continue }
    $hb = [Convert]::FromBase64String($hm.Groups[1].Value)
    if ($hb.Length -lt 100 -or $hb[1] -ne 0x50 -or $hb[2] -ne 0x4E -or $hb[3] -ne 0x47) { $heartOk = $false }
}
Assert $heartOk 'the small heart icon exists (normal and high-contrast) and is a real PNG picture'
# nothing to toggle: no setting, no switch, no hidden actions
Assert ($srcText -notmatch 'ShowDonate|DonateOn|DonateOff|Invoke-DonateToggle|Test-FixItShowDonate') 'there is no ShowDonate setting, no DonateOn/DonateOff action and no toggle code'
Assert (@([regex]::Matches($ast.ParamBlock.Extent.Text, 'Donate\w*')).Count -eq 1 -and $ast.ParamBlock.Extent.Text -match "'Donate'") 'the only -Action value is plain Donate (like every other button): it opens the page, nothing to switch on or off'
Assert (-not (Get-FixItLayout -Simple $false).Donate[0].Contains('Off')) 'the layout takes no on/off input'
Assert (-not ((Get-Command Get-FixItLayout).Parameters.ContainsKey('ShowDonate'))) 'Get-FixItLayout has no ShowDonate switch'

Section 'Thank Trey: the click only opens the link'
$script:Opened = New-Object System.Collections.ArrayList
function Open-FixItUrl { param([string]$Url) [void]$script:Opened.Add($Url) }
$script:Msgs = New-Object System.Collections.ArrayList
function Send-FixItReport { param([string]$Text, [string]$Kind = 'report') [void]$script:Msgs.Add('send'); return $true }
Initialize-FixItLog
$res = Invoke-FixItDonate
Assert ($script:Opened.Count -eq 1 -and $script:Opened[0] -ceq 'https://paypal.me/TreyBarton') 'a click opens exactly https://paypal.me/TreyBarton, once'
Assert ($res.Ok -and (Get-FixItProp $res 'Silent' $false)) 'the result is silent (no pop-up)'
Assert ((Get-Log) -match 'Thank Trey clicked \(opens https://paypal\.me/TreyBarton\)') 'the click is logged'
$out = (Show-FixItResult $res | Out-String)
Assert ($out.Trim() -eq '') 'showing the silent result prints and pops up nothing'
Assert ($script:Msgs.Count -eq 0) 'nothing is sent to anyone'
Assert (-not (Test-Path -LiteralPath $stateF) -or -not ((Get-Content -LiteralPath $stateF -Raw) -match 'Donate')) 'nothing is saved'
$btn = (Get-Fn 'Invoke-GuiButton').Extent.Text
Assert ($btn -match "\`$Which -eq 'Donate'" -and $btn -match 'Invoke-FixItDonate') 'the button goes straight to the link (no plan question first)'
$dt = (Get-Fn 'Invoke-FixItDonate').Extent.Text
Assert ($dt -notmatch 'Start-Process|MessageBox|Send-FixItReport|Set-FixItSetting|Set-FixItStateValue|Invoke-WebRequest|Invoke-RestMethod|Set-Clipboard|Read-Host|Get-Credential') 'the click code does nothing but log and open the link: no pop-up, no settings, no sending, no payment handling'
Assert ($script:DonateUrl -notmatch '[?&=]') 'the link carries no amount or other data'
Restore-Modes; $script:DryRun = $true; $script:Opened.Clear()
$res = Invoke-FixItDonate
Assert ($script:Opened.Count -eq 0 -and (Get-Log) -match 'Would do[^\r\n]*paypal\.me/TreyBarton') 'practice run: logs what it would do and opens nothing'
Restore-Modes

Section 'Thank Trey: Test mode (link and https handler)'
Remove-Item Function:\Open-FixItUrl
$script:WebHandler = $true
function Test-FixItUriHandler { param([string]$Scheme) return $script:WebHandler }
function Open-FixItUrl { param([string]$Url) if ($script:TestMode) { Invoke-FixItProbe -Adapter 'Open-FixItUrl' -Arguments $PSBoundParameters; return }; [void]$script:Opened.Add($Url) }
$script:Opened.Clear()
Set-TestModeOn
Start-FixItTestButton
$res = Invoke-FixItDonate
Complete-FixItTestRecords -Result $res
$recs = @(Get-FixItTestRecords)
$note = @($recs | Where-Object { $_.Step -eq 'Thank Trey' })
Assert ($note.Count -eq 1 -and $note[0].Status -eq 'PASS' -and $note[0].Checks[0].Text -match 'only open https://paypal\.me/TreyBarton') 'Test mode says a real click would only open https://paypal.me/TreyBarton'
$st = @($recs | Where-Object { $_.Step -match 'Open https://paypal\.me/TreyBarton in your web browser' })
Assert ($st.Count -eq 1 -and $st[0].Status -eq 'PASS' -and (($st[0].Checks | ForEach-Object { $_.Text }) -join ' ') -match 'web browser for https') 'Test mode checks the https handler exists (PASS)'
Assert ($script:Opened.Count -eq 0) 'Test mode opens nothing'
Restore-Modes
$script:WebHandler = $false
Set-TestModeOn
Start-FixItTestButton
$res = Invoke-FixItDonate
Complete-FixItTestRecords -Result $res
$recs = @(Get-FixItTestRecords)
$st = @($recs | Where-Object { $_.Step -match 'Open https://paypal\.me/TreyBarton in your web browser' })
Assert ($st.Count -eq 1 -and $st[0].Status -eq 'FAIL' -and (($st[0].Checks | ForEach-Object { $_.Text }) -join ' ') -match 'no web browser') 'Test mode with no https handler: FAIL, in plain words'
Restore-Modes
$script:WebHandler = $true
Assert (($script:TestAllKeys -contains 'Donate') -and ((Get-FixItActionTable)['Donate'].Title -eq 'Thank Trey') -and -not (Get-FixItActionTable)['Donate'].Fix) 'Test all includes the Thank Trey button (not a fix)'
Set-TestModeOn
$all = @(Invoke-FixItTestAll)
Restore-Modes
$dr = @($all | Where-Object { $_.Key -eq 'Donate' })
Assert ($dr.Count -eq 1 -and $dr[0].Status -eq 'PASS') 'Test all runs it and it passes'
Remove-Item Function:\Open-FixItUrl, Function:\Test-FixItUriHandler, Function:\Send-FixItReport -ErrorAction SilentlyContinue

# ================================================================ 8. "What's shared" window, first run, and "Your name"
Section 'Privacy window, first run and owner name'
function Reset-State { $sf = Get-FixItStateFile; if (Test-Path -LiteralPath $sf) { Remove-Item -LiteralPath $sf -Force } }
Reset-State
# --- the name: kept safe
Assert ((ConvertTo-FixItOwnerName -Text '  Anna   Maria ') -eq 'Anna Maria') 'a name: extra spaces are trimmed and squeezed'
Assert ((ConvertTo-FixItOwnerName -Text ("An`r`nna`tMa" + [char]7 + "ria" + [char]0x200B)) -eq 'An na Maria') 'a name: line breaks and tabs become one space, control and hidden characters go'
Assert ((ConvertTo-FixItOwnerName -Text ('x' * 200)).Length -eq 60) 'a name: at most 60 characters'
Assert ((ConvertTo-FixItOwnerName -Text (('a' * 59) + '   b')) -eq ('a' * 59)) 'a name cut at 60 characters never ends in a space'
Assert ((ConvertTo-FixItOwnerName -Text $null) -eq '' -and (ConvertTo-FixItOwnerName -Text " `r`n ") -eq '') 'no name, or only spaces: empty'
Assert ((ConvertTo-FixItOwnerName -Text 'Zoe <b>O''Neil</b>') -eq 'Zoe <b>O''Neil</b>') 'ordinary punctuation is kept as typed (the reports are plain text)'
# --- the report line
Assert ((Get-FixItNameLine) -eq 'Name: not given') 'no name saved: the line reads "Name: not given"'
$saved = Save-FixItOwnerName -Text "  Grandma  Sue`r`n "
Assert ($saved -eq 'Grandma Sue' -and (Get-FixItSetting -Name 'OwnerName' -Default '') -eq 'Grandma Sue' -and (Get-FixItNameLine) -eq 'Name: Grandma Sue') 'a saved name reads "Name: Grandma Sue" and is kept in the settings as OwnerName'
Assert ((Get-FixItSetting -Name 'OwnerNameAsked' -Default '') -match '^\d{4}-\d{2}-\d{2}$') 'the day the question was answered is saved too'
Assert ((Get-Log) -match 'Name saved \(11 characters\)' -and (Get-Log) -notmatch 'Grandma') 'the log says a name was saved, but does not copy the name'
$null = Save-FixItOwnerName -Text ''
Assert ((Get-FixItNameLine) -eq 'Name: not given') 'saving an empty name clears it'
Reset-State; $script:DryRun = $true
$null = Save-FixItOwnerName -Text 'Anna'
$script:DryRun = $false
Assert ((Get-FixItNameLine) -eq 'Name: not given' -and (Get-Log) -match 'Would do: remember setting OwnerName=Anna') 'a practice run does not save the name'
Reset-State
# the name line sits near the top of every report builder
$rt = (Get-Fn 'Get-FixItReportText').Extent.Text; $hs = (Get-Fn 'Invoke-HealthCheck').Extent.Text; $ha = (Get-Fn 'Invoke-FixItHardwareAlerts').Extent.Text
Assert ($rt -match 'Get-FixItNameLine' -and $hs -match 'Get-FixItNameLine' -and $ha -match 'Get-FixItNameLine') 'the report, the scary pop-up alert, the weekly check-in and the hardware alert all carry the name line'
Assert ($rt.IndexOf('Get-FixItNameLine') -lt $rt.IndexOf("Add-ReportSection `$o 'Windows'")) 'in the report the name comes before the first section (near the top)'
# --- what the window says
$c = Get-FixItPrivacyContent
$allText = (Get-FixItPrivacyPlainText)
Assert ($c.Promise -eq "Trey has no access to your computer. He can only see your screen if you start a screen-share with the Let Trey see my screen button. The information is used only to keep an eye on your PC's health.") 'the promise is worded exactly as agreed'
Assert ($allText -match [regex]::Escape($c.Promise) -and $allText -match [regex]::Escape($c.WeeklyOff) -and $c.WeeklyOff -match 'turn the weekly check-in off at any time') 'the window shows the promise and says the weekly check-in can be turned off any time'
Assert ($c.Title -match 'shares' -and $c.Intro -match 'Send Trey a report' -and $c.Intro -match 'scary pop-up' -and $c.Intro -match 'every week') 'it says when information is sent: the report button, the scary pop-up help, and every week'
$sentText = (@($script:PrivacySent | ForEach-Object { $_.Text }) -join ' | ')
foreach ($want in @('name', 'computer', 'Windows user name', 'Windows version', 'free space', 'restart', 'update', 'antivirus', 'OneDrive', 'printers', 'Outlook', 'Acrobat', 'error messages', 'drives, memory and battery', 'serial number', 'internet test', 'activity list', 'remote-control', 'installed', 'downloaded')) {
    Assert ($sentText -match ('(?i)' + [regex]::Escape($want))) ("the sent list mentions: $want")
}
$neverText = (@($script:PrivacyNever | ForEach-Object { $_.Text }) -join ' | ')
foreach ($want in @('files', 'documents', 'photos', 'emails', 'passwords', 'browsing history')) { Assert ($neverText -match [regex]::Escape($want)) ("the never-sent list mentions: $want") }
Assert (@($c.Groups).Count -eq 3 -and $c.Groups[2].Kind -eq 'never') 'the window has the sent groups, then "Never sent"'
Assert (($allText -split "`r`n").Count -lt 60) 'the text is short enough to read (under 60 lines)'
Assert ($allText -notmatch '(?i)\b(registry|WMI|CIM|telemetry|payload|JSON|HTTP|endpoint|API)\b') 'no jargon in the window text'
Assert (@($script:PrivacySent | Where-Object { @($_.Markers).Count -eq 0 }).Count -eq 0) 'every listed item names the report words that prove it is sent'
Assert ($script:NameQuestion -eq "What's your name? This helps Trey know who's asking for help.") 'the name question is worded exactly as agreed'
Assert ($srcText -match "Let Trey see my screen" -and (Get-FixItActionTable)['Screen'].Title -match 'Let Trey see my screen|screen') 'the button the promise names exists'
# the hardware words, checked on the real hardware text with pretend readers (the whole-report check is in Test-FixIt.ps1)
Set-Pretend
$hwTxt = (Format-FixItHardwareText -Sections (Get-FixItHardwareSections -Hw (Get-FixItHardwareInfo))) -join "`n"
foreach ($item in @($script:PrivacySent)) { foreach ($mk in @($item.Markers)) { if ($mk -match '^(--- |Serial number)') { Assert ($hwTxt -match [regex]::Escape($mk)) ("the hardware part of the report really has: " + $mk) } } }
Assert ($rt -match 'status=\{3\}') 'each printer line carries its name and status'
# no listed "never sent" thing has a data source in the report builders
$builderNames = @('Get-FixItReportText', 'Get-FixItHealthSummary', 'Invoke-HealthCheck', 'Invoke-FixItHardwareAlerts', 'Get-FixItScamLines', 'Get-FixItRecentDownloads', 'Get-FixItRecentInstalls', 'Get-FixItHardwareReportLines')
$builderFns = @($builderNames | ForEach-Object { Get-Fn $_ } | Where-Object { $null -ne $_ })
Assert ($builderFns.Count -ge 5) ('found the report builders (' + $builderFns.Count + ')')
$bt = ($builderFns | ForEach-Object { $_.Extent.Text }) -join "`n"
Assert ($bt -notmatch '(?i)MyDocuments|MyPictures|\\Pictures|\\Documents\\|Login Data|Cookies|History\b.*sqlite|Chrome\\User Data|Edge\\User Data|Mozilla\\Firefox|\.pst|\.ost|ReadAllText|Get-Clipboard|Credential') 'the report builders never read documents, pictures, mail files, browser data, passwords or the clipboard'
Assert (@([regex]::Matches($bt, 'Get-Content')).Count -eq @([regex]::Matches($bt, 'Get-Content -LiteralPath \$script:LogFile')).Count) 'the only file the report builders read is the tool''s own activity log'
# --- when it shows: pure plan
$p = Get-FixItFirstRunPlan -Pending '1' -PrivacyShown '' -NameAsked '' -Interactive $true
Assert ($p.ShowPrivacy -and $p.AskName -and $p.Pending) 'fresh install, normal start: show the window, then ask the name'
$p = Get-FixItFirstRunPlan -Pending '' -PrivacyShown '' -NameAsked '' -Interactive $true
Assert (-not $p.ShowPrivacy -and -not $p.AskName) 'an update (no note left by the installer): nothing is shown'
$p = Get-FixItFirstRunPlan -Pending '1' -PrivacyShown '' -NameAsked '' -Interactive $false
Assert (-not $p.ShowPrivacy -and -not $p.AskName -and $p.Pending -and $p.Reason -match 'silent') 'silent or practice start: nothing is shown, it stays pending'
$p = Get-FixItFirstRunPlan -Pending '1' -PrivacyShown '2026-10-01' -NameAsked '' -Interactive $true
Assert (-not $p.ShowPrivacy -and $p.AskName) 'window already seen (for example from the link): only the name is asked'
$p = Get-FixItFirstRunPlan -Pending '1' -PrivacyShown '2026-10-01' -NameAsked '2026-10-01' -Interactive $true
Assert (-not $p.ShowPrivacy -and -not $p.AskName) 'both done: nothing'
# --- when it shows: the real first-run function with a pretend window
$script:Drawn = New-Object System.Collections.ArrayList
function Show-FixItFirstRunWindows { param([bool]$ShowPrivacy, [bool]$AskName) [void]$script:Drawn.Add(('privacy={0} name={1}' -f $ShowPrivacy, $AskName)) }
# fresh install: the installer's action leaves the note and shows nothing
Reset-State
$r = Invoke-FixItFirstRunPending
Assert ($r.Ok -and (Get-FixItSetting -Name 'PrivacyPending' -Default '') -eq '1' -and $script:Drawn.Count -eq 0) 'the installer''s note: PrivacyPending=1, and no window is shown by it'
$r = Invoke-FixItFirstRunPending
Assert ((Get-FixItSetting -Name 'PrivacyPending' -Default '') -eq '1') 'the note is safe to repeat'
# silent start (-Yes)
$script:GuiActive = $true; $script:AssumeYes = $true
$shown = Invoke-FixItFirstRun
Assert (-not $shown -and $script:Drawn.Count -eq 0 -and (Get-Log) -match 'First-run window skipped' -and (Get-FixItSetting -Name 'PrivacyPending' -Default '') -eq '1') 'with -Yes the window is skipped, logged, and stays pending'
# practice run
$script:AssumeYes = $false; $script:DryRun = $true
$shown = Invoke-FixItFirstRun
Assert (-not $shown -and $script:Drawn.Count -eq 0 -and (Get-FixItSetting -Name 'PrivacyPending' -Default '') -eq '1') 'a practice run does not show it either'
$script:DryRun = $false
# no window at all (command line)
$script:GuiActive = $false
$shown = Invoke-FixItFirstRun
Assert (-not $shown -and $script:Drawn.Count -eq 0) 'with no window (command line) it waits'
# first normal start
$script:GuiActive = $true
$shown = Invoke-FixItFirstRun
Assert ($shown -and $script:Drawn.Count -eq 1 -and $script:Drawn[0] -eq 'privacy=True name=True') 'the first normal window shows the privacy window and asks the name'
Assert ((Get-FixItSetting -Name 'PrivacyPending' -Default '') -eq '0') 'and then it is not pending any more'
$shown = Invoke-FixItFirstRun
Assert (-not $shown -and $script:Drawn.Count -eq 1) 'the next start shows nothing (once only)'
# an update never shows it, even if the settings never heard of it
Reset-State; $script:Drawn.Clear()
$shown = Invoke-FixItFirstRun
Assert (-not $shown -and $script:Drawn.Count -eq 0) 'an updated install (no note) never shows it'
# a re-install after the window was seen: no new note
Set-FixItSetting -Name 'PrivacyShown' -Value '2026-10-01'
$r = Invoke-FixItFirstRunPending
Assert ((Get-FixItSetting -Name 'PrivacyPending' -Default '') -eq '' -and $r.Message -match 'already shown') 'a fresh install on a PC that already saw it leaves no note'
Reset-State; $script:DryRun = $true
$r = Invoke-FixItFirstRunPending
$script:DryRun = $false
Assert ((Get-FixItSetting -Name 'PrivacyPending' -Default '') -eq '' -and $r.Message -match 'Practice run') 'a practice run of the note writes nothing'
# Test mode: reports only
Reset-State; Set-FixItSetting -Name 'PrivacyPending' -Value '1'
Set-TestModeOn; $script:GuiActive = $true
$shown = Invoke-FixItFirstRun
Restore-Modes
Assert (-not $shown -and $script:Drawn.Count -eq 0 -and (Get-Log) -match 'TEST MODE: after a fresh install') 'Test mode: says the window and the name question would show, shows nothing'
Remove-Item Function:\Show-FixItFirstRunWindows -ErrorAction SilentlyContinue
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v237c.log') -OutputDir $outDir; Initialize-FixItLog
# --- the actions (link click) in Test mode
Reset-State
Set-TestModeOn
Start-FixItTestButton
$r1 = Invoke-FixItPrivacy
Complete-FixItTestRecords -Result $r1
$recs = @(Get-FixItTestRecords)
$pn = @($recs | Where-Object { $_.Step -eq "What's shared window" })
Assert ($pn.Count -eq 1 -and $pn[0].Status -eq 'PASS' -and (($pn[0].Checks | ForEach-Object { $_.Text }) -join ' ') -match 'would show the window') 'Test mode: the What''s shared click reports the window would show'
Assert (@($recs | Where-Object { $_.Step -eq "What's shared window (first install)" -and $_.Status -eq 'PASS' }).Count -eq 1) 'Test mode: reports the first-install behaviour'
Start-FixItTestButton
$r2 = Invoke-FixItYourName
Complete-FixItTestRecords -Result $r2
$recs = @(Get-FixItTestRecords)
$nn = @($recs | Where-Object { $_.Step -eq 'Your name' })
Assert ($nn.Count -eq 1 -and $nn[0].Status -eq 'PASS' -and (($nn[0].Checks | ForEach-Object { $_.Text }) -join ' ') -match 'Save and Skip') 'Test mode: the Your name click reports the question would show with Save and Skip'
Assert ((Get-FixItSetting -Name 'OwnerName' -Default '') -eq '' -and (Get-FixItSetting -Name 'PrivacyShown' -Default '') -eq '') 'Test mode saves nothing'
Assert ((Get-FixItActionTable).Contains('Privacy') -and (Get-FixItActionTable).Contains('YourName') -and ($script:TestAllKeys -contains 'Privacy') -and ($script:TestAllKeys -contains 'YourName')) 'Test all includes both'
$all = @(Invoke-FixItTestAll)
Restore-Modes
Assert (@($all | Where-Object { ($_.Key -eq 'Privacy' -or $_.Key -eq 'YourName') -and $_.Status -eq 'PASS' }).Count -eq 2) 'Test all runs both and they pass'
# outside a window (command line) the text is printed
$r = Invoke-FixItPrivacy
Assert ($r.Ok -and $r.Message -match 'Trey has no access to your computer') 'from the command line the whole text is given back'
# --- the link: in every layout
Section 'The What''s shared link in every layout'
$combos = 0
foreach ($simple in @($false, $true)) { foreach ($g in @($false, $true)) { foreach ($bt in @($false, $true)) { foreach ($hcx in @($false, $true)) { foreach ($ci in @($false, $true)) {
    $lay = Get-FixItLayout -Simple $simple -GuardianOn $g -BigText $bt -HighContrast $hcx -CheckInOn $ci
    $combos++
    $ft = @($lay.Footer)
    $pl = @($ft | Where-Object { $_[0] -eq 'Privacy' })
    $nl = @($ft | Where-Object { $_[0] -eq 'YourName' })
    Assert ($pl.Count -eq 1 -and $pl[0][1] -eq "What's shared") ("layout simple=$simple guardian=$g big=$bt contrast=$hcx checkin=${ci}: has the link labelled exactly What's shared")
    Assert ($nl.Count -eq 1 -and $nl[0][1] -eq 'Your name') ("layout simple=$simple guardian=$g big=$bt contrast=$hcx checkin=${ci}: has the Your name link")
    Assert ($lay.LinksY -gt $lay.StatusY -and ($lay.LinksY + 24) -le $lay.FullH) ("layout simple=$simple guardian=$g big=$bt contrast=$hcx checkin=${ci}: the links row is at the bottom of the window and fits")
} } } } }
Assert ($combos -eq 32) 'checked all 32 layout combinations (normal and Simple, watcher, Big text, High contrast, check-in)'
foreach ($simple in @($false, $true)) {
    $lay = Get-FixItLayout -Simple $simple
    $xs = @($lay.Footer | ForEach-Object { [int]$_[2] })
    # "Check for a newer version of this tool" is about 250 px wide at 12 px; the version label starts at x=479 (its text is right-aligned)
    Assert ($xs[0] -ge 250 -and $xs[1] -gt $xs[0] + 80 -and $xs[1] + 70 -le 479) ("simple=${simple}: the small links sit between the update link and the version, without overlapping")
}
$wo = (Get-Fn 'Show-FixItWindowOnce').Extent.Text
Assert ($wo -match 'foreach \(\$fl in @\(\$lay\.Footer\)\)' -and $wo -match "Add-FixItLink -Form \`$form -Text \`$fl\[1\] -Run \`$fl\[0\] -X \(\`$MX \+ \`$fl\[2\]\) -Y \`$lay\.LinksY -Color \`$cLink -Font \`$lf") 'the window draws every footer link from the layout with the same colour and font as the update link'
Assert ($wo -match "if \(\`$hc\) \{[^\n]*\`$cLink = '#FFFF00'") 'in High contrast the links are yellow on black'
Assert ($wo -match "\`$lf = New-Object System.Drawing.Font\('Segoe UI', \[single\]\(12 \* \`$S\)") 'the links scale with Big text and the screen scale (12 pixel font times the scale)'
$gb = (Get-Fn 'Invoke-GuiButton').Extent.Text
Assert ($gb -match "\`$Which -eq 'Privacy' -or \`$Which -eq 'YourName'") 'clicking the link calls the same function as the action (and Test mode shows its checklist)'
Assert ($gb.IndexOf("`$Which -eq 'Privacy'") -lt $gb.IndexOf('Confirm-FixIt')) 'the link opens at once (no "Here is what I will do" question first)'
# --- the windows themselves (source checks: System.Drawing is not available here)
$pf = (Get-Fn 'Show-FixItPrivacyForm').Extent.Text; $nf = (Get-Fn 'Show-FixItNameForm').Extent.Text
Assert ($pf -match "-Title 'OK, got it'" -and $pf -match 'AcceptButton' -and $pf -match 'AutoScroll = \$true') 'the privacy window has one "OK, got it" button and scrolls if the text is large'
Assert ($pf -match '\$script:UiScale' -and $pf -match '\$script:UiHighContrast' -and $pf -match "'#FFFF00'" -and $pf -match 'Get-FixItLabelHeight') 'the privacy window follows Big text and High contrast and measures its text so nothing is cut off'
Assert ($pf -match "Set-FixItSetting -Name 'PrivacyShown'") 'it records that it was shown'
Assert ($nf -match 'NameQuestion' -and $nf -match "-Title 'Save'" -and $nf -match "-Title 'Skip'" -and $nf -match 'MaxLength = \$script:OwnerNameMax' -and $nf -match 'Save-FixItOwnerName') 'the name window has the question, a limited box, Save and Skip'
Assert ($nf -match '\$script:UiScale' -and $nf -match '\$script:UiHighContrast') 'the name window follows Big text and High contrast'
Assert ($pf -notmatch 'Start-Process|Invoke-WebRequest|Send-FixItReport' -and $nf -notmatch 'Start-Process|Invoke-WebRequest|Send-FixItReport') 'neither window sends anything or starts a program'
Assert ((Get-Fn 'Show-FixItWindowMain').Extent.Text -match 'Invoke-FixItFirstRun') 'the first normal window start checks for the first-run note'
Assert ($srcText -match "'FirstRunPending'" -and $script:BackgroundActions -contains 'FirstRunPending') 'the installer action is a background action (it can never wait for typing)'
$ip = [IO.File]::ReadAllText((Join-Path $root 'Install-FixIt.ps1'))
Assert ($ip -match "if \(-not \`$old\) \{[^}]*FirstRunPending") 'the installer leaves the note on a fresh install only (not on an update)'
$py = Get-Command python3 -ErrorAction SilentlyContinue
if ($null -ne $py -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'test_report_feed_owner.py')) -and (Test-Path -LiteralPath (Join-Path $root 'tools/report_feed.py'))) {
    $pyOut = & $py.Source (Join-Path $PSScriptRoot 'test_report_feed_owner.py') 2>&1 | ForEach-Object { [string]$_ }
    Assert ($LASTEXITCODE -eq 0 -and @($pyOut | Where-Object { $_ -match '^ok ' }).Count -eq 5) 'the dashboard feed reads the Name line into owner_name (named, not given, old reports, Windows line endings, only the header)'
} else { Write-Host '  (python3 or the dashboard tools not here: the dashboard feed check was skipped)' }


Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('Passed: {0}   Failed: {1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
