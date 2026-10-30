# Version 2.3.6 tests: an update closes the Family Fix-It windows that are still open on the old version, and a start that finds an
# open window of a different version (or the other kind: normal <-> Test mode) replaces it instead of bringing it forward.
# These use the REAL program functions with pretend Windows facts (and, on Linux, a few real child processes), so they run in their own PowerShell.
# Usage:  pwsh ./tests/Test-FixIt-V236.ps1       (Test-FixIt.ps1 runs this one too and adds its numbers)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fixit-v236-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:Pass = 0; $script:Fail = 0
function Assert { param([bool]$Cond, [string]$Name) if ($Cond) { $script:Pass++ } else { $script:Fail++; Write-Host ('  FAIL: ' + $Name) -ForegroundColor Red } }
function Section { param([string]$T) Write-Host ('== ' + $T) }

$src = Join-Path $root 'FamilyFixIt.ps1'
$outDir = Join-Path $tmp 'out'
New-Item -ItemType Directory -Path $outDir | Out-Null
$env:LOCALAPPDATA = Join-Path $tmp 'local'; New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v236.log') -OutputDir $outDir
Initialize-FixItLog
$script:GuiInstanceKeyOverride = 'v236-' + [guid]::NewGuid().ToString('N')
$tokens = $null; $perr = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$perr)
$allFns = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
function Get-Fn { param([string]$Name) return ($allFns | Where-Object { $_.Name -eq $Name } | Select-Object -First 1) }
function Get-Log { return (Get-Content -LiteralPath $script:LogFile -Raw) }

Assert ([version]$script:FixItVersion -ge [version]'2.3.6') 'the program is version 2.3.6 or newer'

# ================================================================ 1. which processes are Family Fix-It windows
Section 'Which command lines are Family Fix-It windows'
$P = ('C:\' + 'Users\tester\AppData\Local\FamilyFixIt\FamilyFixIt.ps1')
$base = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $P + '"'
$kinds = [ordered]@{
    ($base) = 'Normal'
    ($base + ' -Test') = 'Test'
    ($base + ' -WhatIf') = 'Practice'
    ($base + ' -DryRun') = 'Practice'
    ($base + ' -Action Gui') = 'Normal'
    ($base + ' -Action Gui -Test') = 'Test'
    ($base + ' -Action:Gui') = 'Normal'
    ('"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File ' + $P) = 'Normal'
    ('pwsh -File /home/u/FamilyFixIt.ps1') = 'Normal'
    ($base + ' -Action Guardian') = ''
    ($base + ' -Action Guardian -Yes') = ''
    ($base + ' -Action:Guardian') = ''
    ($base + ' -Action "Guardian"') = ''
    ($base + ' -Ac Guardian') = ''
    ($base + ' -Action GuardianOn -Yes') = ''
    ($base + ' -Action GuardianOff -Yes') = ''
    ($base + ' -Action GuardianDemo') = ''
    ($base + ' -Action CheckIn') = ''
    ($base + ' -Action HealthCheck') = ''
    ($base + ' -Action PrinterAdmin') = ''
    ($base + ' -Action OutlookAdmin -InputFile x.json') = ''
    ($base + ' -Action TestAll') = ''
    ($base + ' -Action Report') = ''
    ($base + ' -LibraryOnly') = ''
    ('powershell.exe -NoProfile -Command "Get-Process"') = ''
    ('powershell.exe -File C:\tools\Other.ps1') = ''
    ('powershell.exe -File C:\tools\NotFamilyFixIt.ps1') = ''
    ('powershell.exe -File C:\tools\FamilyFixIt.ps1.bak') = ''
    ('powershell.exe -File C:\tools\FamilyFixIt.ps1x') = ''
    ('') = ''
}
foreach ($k in $kinds.Keys) {
    $want = $kinds[$k]; $got = Get-FixItGuiWindowKind -CommandLine $k
    Assert ($got -eq $want) ('"' + ($k -replace [regex]::Escape($P), '<P>') + '" is [' + $want + '] (got [' + $got + '])')
}
Assert ((Get-FixItGuiWindowKind -CommandLine $null) -eq '') 'no command line at all is not a window'

Section 'Which running processes are this user''s windows'
$script:Table = @()
function Get-FixItProcessTable { return @($script:Table) }
function Get-FixItOwnSession { return 1 }
function Get-FixItOwnUserName { return 'PC\trey' }
function Get-FixItProcessOwner { param([int]$Id) if ($script:OwnerOf.ContainsKey($Id)) { return $script:OwnerOf[$Id] } return '' }
$script:OwnerOf = @{}
function Row { param([int]$Id, [string]$Cmd, [int]$Session = 1) return [pscustomobject]@{ Id = $Id; Name = 'powershell.exe'; CommandLine = $Cmd; SessionId = $Session; Owner = '' } }
$script:Table = @(
    (Row 100 $base), (Row 101 ($base + ' -Test')), (Row 102 ($base + ' -Action Guardian')), (Row 103 ($base + ' -Action CheckIn')),
    (Row 104 'powershell.exe -File C:\x\other.ps1'), (Row 105 $base 2), (Row 106 ($base + ' -Action PrinterAdmin')), (Row $PID $base), (Row 107 ($base + ' -WhatIf'))
)
$script:OwnerOf = @{ 101 = 'PC\TREY' }
$g = @(Get-FixItGuiProcesses)
Assert ((@($g | ForEach-Object { $_.Id } | Sort-Object) -join ',') -eq '100,101,107') ('only this user''s windows are found (normal, Test and practice): ' + (@($g | ForEach-Object { $_.Id }) -join ','))
Assert (@($g | Where-Object { $_.Id -eq 101 })[0].Kind -eq 'Test') 'a Test mode window is known as one'
$script:OwnerOf = @{ 100 = 'PC\someone-else' }
Assert ((@(Get-FixItGuiProcesses | ForEach-Object { $_.Id } | Sort-Object) -join ',') -eq '101,107') 'a window that belongs to another person on this PC is left out'
$script:OwnerOf = @{}

# ================================================================ 2. closing windows
Section 'Closing windows: politely first, then force only those'
$script:Alive = @{}; $script:Asked = New-Object System.Collections.ArrayList; $script:Forced = New-Object System.Collections.ArrayList
$script:PoliteWorks = @{}   # pid -> true when the window closes by itself on request
function Test-FixItProcessAlive { param([int]$Id) return ($script:Alive.ContainsKey($Id) -and $script:Alive[$Id]) }
function Request-FixItWindowClose { param([int]$Id) [void]$script:Asked.Add($Id); if ($script:PoliteWorks.ContainsKey($Id) -and $script:PoliteWorks[$Id]) { $script:Alive[$Id] = $false } }
function Stop-FixItWindowProcess { param([int]$Id) [void]$script:Forced.Add($Id); $script:Alive[$Id] = $false }
function Reset-Close { $script:Alive = @{}; $script:Asked.Clear(); $script:Forced.Clear(); $script:PoliteWorks = @{} }
$script:GuiCloseWaitSeconds = 1
$script:TestMode = $false; $script:DryRun = $false

Reset-Close
$script:Alive = @{ 100 = $true; 101 = $true; 102 = $true; 103 = $true }; $script:PoliteWorks = @{ 100 = $true }
$script:Table = @((Row 100 $base), (Row 101 ($base + ' -Test')), (Row 102 ($base + ' -Action Guardian')), (Row 103 'powershell.exe -File C:\x\other.ps1'))
$sw = [Diagnostics.Stopwatch]::StartNew()
$closed = @(Close-FixItOtherGuiWindows -Why 'update')
$sw.Stop()
Assert ((@($script:Asked | Sort-Object) -join ',') -eq '100,101') 'both windows (normal and Test mode) were asked to close, politely'
Assert ((@($script:Forced) -join ',') -eq '101') 'only the window that did not close by itself was forced'
Assert ($script:Alive[102] -and $script:Alive[103]) 'the pop-up watcher and an unrelated PowerShell were not touched'
Assert ($script:Asked -notcontains 102 -and $script:Asked -notcontains 103 -and $script:Forced -notcontains 102 -and $script:Forced -notcontains 103) 'they were not even asked'
Assert ((@($closed | Sort-Object) -join ',') -eq '100,101') 'the closed windows are reported'
Assert ($sw.Elapsed.TotalSeconds -ge 0.9 -and $sw.Elapsed.TotalSeconds -lt 8) ('it waited about the set time before forcing (' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + ' s)')
$lg = Get-Log
Assert ($lg -match 'Closing 2 open Family Fix-It window\(s\) \(update\); asking politely first' -and $lg -match 'Window 101 did not close on its own; it was closed by force' -and $lg -match 'Closed 2 of 2 Family Fix-It window\(s\): 100, 101') 'what was closed is logged'

# everyone closes politely: nobody is forced and there is no waiting
Reset-Close
$script:Alive = @{ 100 = $true }; $script:PoliteWorks = @{ 100 = $true }; $script:Table = @((Row 100 $base))
$sw = [Diagnostics.Stopwatch]::StartNew(); [void](Close-FixItOtherGuiWindows); $sw.Stop()
Assert ($script:Forced.Count -eq 0 -and $sw.Elapsed.TotalSeconds -lt 0.9) 'a window that closes on request is not forced and the update does not wait the full time'

# idempotent: nothing open -> nothing happens
Reset-Close; $script:Table = @((Row 102 ($base + ' -Action Guardian')))
$r = @(Close-FixItOtherGuiWindows)
Assert ($r.Count -eq 0 -and $script:Asked.Count -eq 0 -and $script:Forced.Count -eq 0) 'nothing open: nothing is asked and nothing is forced'
$r = @(Close-FixItOtherGuiWindows)
Assert ($r.Count -eq 0 -and $script:Asked.Count -eq 0) 'running it again changes nothing'

# a process id that was reused by something else while we waited is not forced
Reset-Close
$script:Alive = @{ 100 = $true }; $script:PoliteWorks = @{}
$script:Table = @((Row 100 $base))
$script:Phase = 0
function Test-FixItProcessAlive { param([int]$Id) if ($script:Phase -eq 0 -and $script:Asked.Count -gt 0) { $script:Phase = 1; $script:Table = @((Row 100 'notepad.exe')) }; return ($script:Alive.ContainsKey($Id) -and $script:Alive[$Id]) }
[void](Close-FixItGuiProcesses -Ids @(100) -Why 'test' -WaitSeconds 0)
Assert ($script:Forced.Count -eq 0 -and (Get-Log) -match 'Process 100 is no longer a Family Fix-It window; leaving it alone') 'an id that now belongs to another program is left alone'
function Test-FixItProcessAlive { param([int]$Id) return ($script:Alive.ContainsKey($Id) -and $script:Alive[$Id]) }

# this very process is never closed
Reset-Close; $script:Alive = @{ $PID = $true }; $script:Table = @((Row $PID $base))
$r = @(Close-FixItOtherGuiWindows); [void](Close-FixItGuiProcesses -Ids @($PID) -Why 'test')
Assert ($script:Asked.Count -eq 0 -and $script:Forced.Count -eq 0) 'it never closes itself'

# Test mode and practice mode: an update step closes nothing (they only check)
Reset-Close; $script:Alive = @{ 100 = $true }; $script:Table = @((Row 100 $base))
$script:TestMode = $true; [void](Close-FixItOtherGuiWindows); $script:TestMode = $false
Assert ($script:Asked.Count -eq 0 -and $script:Forced.Count -eq 0 -and $script:Alive[100]) 'Test mode: the update step closes nothing'
$script:DryRun = $true; [void](Close-FixItOtherGuiWindows); $script:DryRun = $false
Assert ($script:Asked.Count -eq 0 -and $script:Forced.Count -eq 0) 'practice mode: the update step closes nothing'
Assert ((Get-Log) -match 'Would close 1 open Family Fix-It window\(s\) first \(update\)') '... and says what it would do'

# the process-asking and forcing adapters are tiny and only do that
Assert ((Get-Fn 'Stop-FixItWindowProcess').Extent.Text -match 'Stop-Process -Id \$Id -Force' -and (Get-Fn 'Request-FixItWindowClose').Extent.Text -match 'CloseMainWindow') 'the adapters ask (close the window) or force by process id only'

# ================================================================ 3. the update replaces files only after closing
Section 'The in-app update closes other windows before replacing the program'
$installDir = Join-Path $tmp 'install'; New-Item -ItemType Directory -Path $installDir | Out-Null
$script:InstallDir = $installDir
$newDir = Join-Path $tmp 'newfiles'; New-Item -ItemType Directory -Path $newDir | Out-Null
$oldText = [IO.File]::ReadAllText($src).Replace("FixItVersion = '$($script:FixItVersion)'", "FixItVersion = '0.0.1'")
[IO.File]::WriteAllText((Join-Path $installDir 'FamilyFixIt.ps1'), $oldText)
Copy-Item -LiteralPath $src -Destination (Join-Path $newDir 'FamilyFixIt.ps1')
function Save-WebFile { param([string]$Url, [string]$Dest) $d = Split-Path -Parent $Dest; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }; Copy-Item -LiteralPath (Join-Path $newDir (Split-Path -Leaf $Url)) -Destination $Dest }
function Update-FixItShortcutIcons { return $false }
$man = [pscustomobject]@{ Version = [version]$script:FixItVersion; BaseUrl = 'https://example.test/'; Files = @([pscustomobject]@{ path = 'FamilyFixIt.ps1'; sha256 = (Get-FileSha256 -Path $src) }); Assets = @() }
Reset-Close; $script:Alive = @{ 100 = $true; 101 = $true }; $script:Table = @((Row 100 $base), (Row 101 ($base + ' -Test')))
$script:ProgramWasOldWhenClosed = $null
function Request-FixItWindowClose { param([int]$Id) [void]$script:Asked.Add($Id); if ($null -eq $script:ProgramWasOldWhenClosed) { $script:ProgramWasOldWhenClosed = ([IO.File]::ReadAllText((Join-Path $installDir 'FamilyFixIt.ps1')) -match "FixItVersion = '0\.0\.1'") } }
Install-FixItUpdate -Manifest $man
Assert ($script:ProgramWasOldWhenClosed -eq $true) 'the windows were asked to close while the old program file was still in place'
Assert ((@($script:Forced | Sort-Object) -join ',') -eq '100,101') 'windows that stay open are closed by force before the files are replaced'
Assert ([IO.File]::ReadAllText((Join-Path $installDir 'FamilyFixIt.ps1')) -match ("FixItVersion = '" + [regex]::Escape($script:FixItVersion) + "'")) 'the program was replaced after that'
Assert (Test-Path -LiteralPath (Join-Path $installDir 'previous/FamilyFixIt.ps1')) 'the old program is still kept in previous/'
# idempotent: again, nothing open
Reset-Close; $script:Table = @(); Install-FixItUpdate -Manifest $man
Assert ($script:Asked.Count -eq 0 -and $script:Forced.Count -eq 0) 'updating again with no window open closes nothing'
# trouble while closing never stops the update
[IO.File]::WriteAllText((Join-Path $installDir 'FamilyFixIt.ps1'), $oldText)
function Get-FixItProcessTable { throw 'cannot list' }
Install-FixItUpdate -Manifest $man
Assert ([IO.File]::ReadAllText((Join-Path $installDir 'FamilyFixIt.ps1')) -notmatch "FixItVersion = '0\.0\.1'") 'if the windows cannot be looked up the update still goes ahead'
function Get-FixItProcessTable { return @($script:Table) }
# Test mode: the update step stays a read-only check and now also says how many windows would be closed
$script:TestMode = $true
$script:Table = @((Row 100 $base), (Row 101 ($base + ' -Test')))
$res = @(Get-FixItPreflight -Adapter 'Install-FixItUpdate' -Arguments @{ Manifest = $man })
$script:TestMode = $false
Assert (@($res | Where-Object { $_.Text -match '2 other Family Fix-It window\(s\) would be closed first \(politely\); none is closed in Test mode' }).Count -eq 1 -and @($res | Where-Object { $_.Status -eq 'FAIL' }).Count -eq 0) ('Test mode says how many windows an update would close, and closes none (' + (@($res | ForEach-Object { $_.Status + ': ' + $_.Text }) -join ' | ') + ')')

# ================================================================ 4. what a second start does
Section 'A second start: replace an older window, bring forward a current one'
$dk = Get-FixItDiskVersion
Assert ($dk -eq $script:FixItVersion) 'the version on disk is read from the program file'
$tf = Join-Path $tmp 'ver.ps1'; [IO.File]::WriteAllText($tf, "x`n`$script:FixItVersion = '9.8.7'`n")
Assert ((Get-FixItDiskVersion -Path $tf) -eq '9.8.7') 'the version on disk is read from the file itself'
Assert ((Get-FixItDiskVersion -Path (Join-Path $tmp 'nope.ps1')) -eq $script:FixItVersion) 'a missing file falls back to this program''s own version'
function Info { param([int]$Pid2, [string]$Ver) return [pscustomobject]@{ pid = $Pid2; hwnd = 1; version = $Ver } }
Assert ((Get-FixItGuiExistingDecision -Info (Info 5 '2.3.4') -DiskVersion '2.3.5' -OwnVersion '2.3.5') -eq 'Replace') 'older window: replace'
Assert ((Get-FixItGuiExistingDecision -Info (Info 5 '2.3.5') -DiskVersion '2.3.5' -OwnVersion '2.3.5') -eq 'Forward') 'same version: bring forward'
Assert ((Get-FixItGuiExistingDecision -Info (Info 5 '') -DiskVersion '2.3.5' -OwnVersion '2.3.5') -eq 'Replace') 'a window that never said its version is treated as old'
Assert ((Get-FixItGuiExistingDecision -Info $null -DiskVersion '2.3.5' -OwnVersion '2.3.5') -eq 'Forward') 'no details about the window: bring forward as before'
Assert ((Get-FixItGuiExistingDecision -Info (Info 0 '2.3.4') -DiskVersion '2.3.5' -OwnVersion '2.3.5') -eq 'Forward') 'no process id: bring forward'
Assert ((Get-FixItGuiExistingDecision -Info (Info 5 '2.3.5') -DiskVersion '2.3.6' -OwnVersion '2.3.5') -eq 'Forward') 'this start is itself old (the file moved on after it started): it must not replace a window'
Assert ((Get-FixItGuiExistingDecision -Info (Info 5 '2.3.9') -DiskVersion '2.3.5' -OwnVersion '2.3.5') -eq 'Replace') 'any different version is replaced, newer too (the file on disk is the truth)'

# Show-FixItWindow with pretend locks
$script:Calls = New-Object System.Collections.ArrayList
$Action = 'Gui'; $script:Background = $false; $script:Admin = $false; $script:TestMode = $false; $script:DryRun = $false
function Test-FixItAdmin { return $false }
function Show-FixItWindowMain { param($Instance) [void]$script:Calls.Add('MAIN WINDOW') }
function Exit-FixItGuiInstance { param($Instance) [void]$script:Calls.Add('exit') }
function Invoke-FixItGuiShowExisting { param($Instance) [void]$script:Calls.Add('FORWARD'); return $true }
function Close-FixItOtherModeWindow { return @() }
$script:EnterResults = New-Object System.Collections.Queue
function Enter-FixItGuiInstance { $n = Get-FixItGuiInstanceNames; $r = $(if ($script:EnterResults.Count -gt 0) { $script:EnterResults.Dequeue() } else { $true }); [void]$script:Calls.Add('enter=' + $r); return [pscustomobject]@{ Acquired = $r; Failed = $false; Abandoned = $false; Mutex = $null; Event = $null; Names = $n } }
function Wait-FixIt { param([double]$Seconds = 0, [int]$Milliseconds = 0) }
function Calls { return (@($script:Calls) -join ' > ') }
function Set-OpenWindow { param([int]$Pid2, [string]$Ver)
    $k = (Get-FixItGuiInstanceNames).Key
    $f = Get-FixItGuiInstanceFile -Key $k; New-Item -ItemType Directory -Path (Split-Path -Parent $f) -Force | Out-Null
    if ($Ver -eq '<none>') { [IO.File]::WriteAllText($f, ('{"pid": ' + $Pid2 + ', "hwnd": 7}')) } else { [IO.File]::WriteAllText($f, ('{"pid": ' + $Pid2 + ', "hwnd": 7, "version": "' + $Ver + '"}')) }
}
function Clear-OpenWindow { $f = Get-FixItGuiInstanceFile -Key (Get-FixItGuiInstanceNames).Key; Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
$own = $script:FixItVersion

# (a) free lock: the normal case, nothing is closed
Reset-Close; $script:Calls.Clear(); $script:EnterResults.Clear(); $script:Table = @()
Show-FixItWindow
Assert ((Calls) -eq 'enter=True > MAIN WINDOW > exit' -and $script:Asked.Count -eq 0) ('no window open: it just opens (' + (Calls) + ')')

# (b) the bug from Trey's PC: an older Test mode window is open; a Test mode start must replace it
$script:TestMode = $true
Reset-Close; $script:Calls.Clear(); $script:EnterResults.Clear(); $script:EnterResults.Enqueue($false)
Set-OpenWindow -Pid2 300 -Ver '2.3.4'
$script:Table = @((Row 300 ($base + ' -Test'))); $script:Alive = @{ 300 = $true }
Show-FixItWindow
Assert ($script:Asked -contains 300 -and $script:Forced -contains 300) 'an older Test mode window is asked to close, then forced'
Assert ((Calls) -eq 'enter=False > enter=True > MAIN WINDOW > exit') ('and the new Test mode window opens instead of the old one coming forward (' + (Calls) + ')')
Assert ((Get-Log) -match 'is an older version \(2\.3\.4; the program on disk is ' + [regex]::Escape($own)) 'the replacement is logged with both versions'
$script:TestMode = $false

# (c) the same version is brought forward, nothing is closed
Reset-Close; $script:Calls.Clear(); $script:EnterResults.Clear(); $script:EnterResults.Enqueue($false)
Set-OpenWindow -Pid2 301 -Ver $own
$script:Table = @((Row 301 $base)); $script:Alive = @{ 301 = $true }
Show-FixItWindow
Assert ((Calls) -eq 'enter=False > FORWARD' -and $script:Asked.Count -eq 0 -and $script:Forced.Count -eq 0) ('the same version: the open window comes forward and nothing is closed (' + (Calls) + ')')

# (d) an old window that never recorded its version is replaced
Reset-Close; $script:Calls.Clear(); $script:EnterResults.Clear(); $script:EnterResults.Enqueue($false)
Set-OpenWindow -Pid2 302 -Ver '<none>'
$script:Table = @((Row 302 $base)); $script:Alive = @{ 302 = $true }
Show-FixItWindow
Assert ((Calls) -eq 'enter=False > enter=True > MAIN WINDOW > exit' -and $script:Forced -contains 302) 'a window with no version on record is replaced'

# (e) the recorded process is not a Family Fix-It window (stale file, reused id): nothing is closed, the old behaviour stays
Reset-Close; $script:Calls.Clear(); $script:EnterResults.Clear(); $script:EnterResults.Enqueue($false)
Set-OpenWindow -Pid2 303 -Ver '2.3.4'
$script:Table = @((Row 303 'powershell.exe -File C:\x\other.ps1'), (Row 304 ($base + ' -Action Guardian'))); $script:Alive = @{ 303 = $true; 304 = $true }
Show-FixItWindow
Assert ($script:Asked.Count -eq 0 -and $script:Forced.Count -eq 0 -and (Calls) -eq 'enter=False > FORWARD') ('an id that is not a Family Fix-It window is never closed (' + (Calls) + ')')
# the recorded process is the pop-up watcher: never closed
Reset-Close; $script:Calls.Clear(); $script:EnterResults.Clear(); $script:EnterResults.Enqueue($false)
Set-OpenWindow -Pid2 304 -Ver '2.3.4'
Show-FixItWindow
Assert ($script:Asked.Count -eq 0 -and $script:Forced.Count -eq 0) 'the pop-up watcher is never closed, even if its id is in the window file'

# (f) the old window closes but the lock never comes free: the old behaviour (bring forward), no endless wait
Reset-Close; $script:Calls.Clear(); $script:EnterResults.Clear(); 1..25 | ForEach-Object { $script:EnterResults.Enqueue($false) }
Set-OpenWindow -Pid2 305 -Ver '2.3.4'
$script:Table = @((Row 305 $base)); $script:Alive = @{ 305 = $true }
Show-FixItWindow
Assert ((Calls) -match 'FORWARD' -and (Calls) -notmatch 'MAIN WINDOW' -and ((Calls) -split '>' | Where-Object { $_ -match 'enter=False' }).Count -le 22) ('a lock that does not come free is given up on (' + ((Calls) -split '>').Count + ' steps)')
Clear-OpenWindow

# (g) the window holding the lock closes politely and quickly
function Request-FixItWindowClose { param([int]$Id) [void]$script:Asked.Add($Id); if ($script:PoliteWorks.ContainsKey($Id) -and $script:PoliteWorks[$Id]) { $script:Alive[$Id] = $false } }
Reset-Close; $script:Calls.Clear(); $script:EnterResults.Clear(); $script:EnterResults.Enqueue($false)
Set-OpenWindow -Pid2 306 -Ver '2.3.4'
$script:Table = @((Row 306 $base)); $script:Alive = @{ 306 = $true }; $script:PoliteWorks = @{ 306 = $true }
Show-FixItWindow
Assert ($script:Forced.Count -eq 0 -and (Calls) -eq 'enter=False > enter=True > MAIN WINDOW > exit') 'an older window that closes on request is not forced'
Clear-OpenWindow

# (h) elevated and background runs still never touch any of this
$script:Admin = $true
function Test-FixItAdmin { return $true }
Reset-Close; $script:Calls.Clear(); $script:Table = @((Row 307 $base)); $script:Alive = @{ 307 = $true }
Show-FixItWindow
Assert ((Calls) -eq 'MAIN WINDOW > exit' -or (Calls) -eq 'MAIN WINDOW') ('an administrator run does not look at other windows (' + (Calls) + ')')
Assert ($script:Asked.Count -eq 0) '... and closes none'
function Test-FixItAdmin { return $false }; $script:Admin = $false

# ================================================================ 5. normal <-> Test mode
Section 'A normal start and a Test mode start replace each other'
Remove-Item Function:\Close-FixItOtherModeWindow
. ([scriptblock]::Create((((Get-Fn 'Close-FixItOtherModeWindow').Extent.Text))))
function Write-InfoFor { param([string]$Mode, [int]$Pid2, [string]$Ver = '2.3.5')
    $k = (Get-FixItGuiInstanceNames -Mode $Mode).Key
    $f = Get-FixItGuiInstanceFile -Key $k; New-Item -ItemType Directory -Path (Split-Path -Parent $f) -Force | Out-Null
    [IO.File]::WriteAllText($f, ('{"pid": ' + $Pid2 + ', "hwnd": 7, "version": "' + $Ver + '"}'))
}
function Remove-InfoFor { param([string]$Mode) Remove-Item -LiteralPath (Get-FixItGuiInstanceFile -Key (Get-FixItGuiInstanceNames -Mode $Mode).Key) -Force -ErrorAction SilentlyContinue }
Assert ((Get-FixItGuiInstanceNames -Mode 'Test').Mutex -like '*-Test' -and (Get-FixItGuiInstanceNames -Mode 'Normal').Mutex -notlike '*-Test' -and (Get-FixItGuiInstanceNames -Mode 'Practice').Mutex -like '*-Practice') 'each kind of window has its own lock name'
Assert ((Get-FixItGuiInstanceNames).Mutex -eq (Get-FixItGuiInstanceNames -Mode (Get-FixItGuiMode)).Mutex) 'with no mode given the names are this run''s own'

# a normal start while a Test mode window is open
Reset-Close; $script:TestMode = $false
Write-InfoFor -Mode 'Test' -Pid2 400
$script:Table = @((Row 400 ($base + ' -Test')), (Row 401 $base)); $script:Alive = @{ 400 = $true; 401 = $true }
$r = @(Close-FixItOtherModeWindow)
Assert ($script:Asked -contains 400 -and $script:Forced -contains 400 -and $script:Asked -notcontains 401) 'a normal start closes the open Test mode window (and only that one)'
Assert ((Get-Log) -match 'A Test mode window is open; closing it so the normal window can open instead') 'and says so in the log'
# a Test mode start while a normal window is open
Reset-Close; $script:TestMode = $true; Remove-InfoFor 'Test'
Write-InfoFor -Mode 'Normal' -Pid2 401
$script:Table = @((Row 400 ($base + ' -Test')), (Row 401 $base)); $script:Alive = @{ 400 = $true; 401 = $true }
$r = @(Close-FixItOtherModeWindow)
Assert ($script:Asked -contains 401 -and $script:Forced -contains 401 -and $script:Asked -notcontains 400) 'a Test mode start closes the open normal window, so the TEST MODE banner is always true'
# the recorded id is the wrong kind of window (a normal window recorded under the Test name): left alone
Reset-Close; $script:TestMode = $false; Write-InfoFor -Mode 'Test' -Pid2 401
$script:Alive = @{ 401 = $true }; $script:Table = @((Row 401 $base))
[void](Close-FixItOtherModeWindow)
Assert ($script:Asked.Count -eq 0) 'a window of the wrong kind in the Test file is left alone'
# a stale file with nobody there: nothing to do, no error
Reset-Close; Write-InfoFor -Mode 'Test' -Pid2 499; $script:Table = @(); $script:Alive = @{}
$r = @(Close-FixItOtherModeWindow)
Assert ($r.Count -eq 0 -and $script:Asked.Count -eq 0) 'a leftover file for a window that is gone does nothing'
# no file at all
Remove-InfoFor 'Test'; Remove-InfoFor 'Normal'
Assert (@(Close-FixItOtherModeWindow).Count -eq 0) 'no other window: nothing happens (idempotent)'
# practice mode is its own thing
Reset-Close; $script:TestMode = $false; $script:DryRun = $true; Write-InfoFor -Mode 'Test' -Pid2 400; Write-InfoFor -Mode 'Normal' -Pid2 401
$script:Table = @((Row 400 ($base + ' -Test')), (Row 401 $base)); $script:Alive = @{ 400 = $true; 401 = $true }
[void](Close-FixItOtherModeWindow)
Assert ($script:Asked.Count -eq 0) 'a practice-mode (-WhatIf) window never closes a real or Test window'
$script:DryRun = $false; Remove-InfoFor 'Test'; Remove-InfoFor 'Normal'
# Show-FixItWindow calls it before taking the lock
$showText = (Get-Fn 'Show-FixItWindow').Extent.Text
Assert ($showText.IndexOf('Close-FixItOtherModeWindow') -ge 0 -and $showText.IndexOf('Close-FixItOtherModeWindow') -lt $showText.IndexOf('Enter-FixItGuiInstance')) 'the other kind of window is dealt with before the lock is taken'

# ================================================================ 6. real processes (Linux): nothing but the right ones is stopped
Section 'Real processes: only the old window goes'
if ($IsLinux) {
    $pwx = (Get-Command pwsh).Source
    $dirW = Join-Path $tmp 'w'; New-Item -ItemType Directory -Path $dirW | Out-Null
    $fake = Join-Path $dirW 'FamilyFixIt.ps1'
    $other = Join-Path $dirW 'Other.ps1'
    # the pretend window: takes the real lock, writes its window file (old version) and waits
    @"
param([string]`$Key, [string]`$Action = 'Gui', [switch]`$Test, [string]`$Ver = '2.3.4')
`$myAction = `$Action
`$env:LOCALAPPDATA = '$($env:LOCALAPPDATA)'
. '$src' -LibraryOnly -LogPath '$(Join-Path $tmp 'w.log')'
`$script:GuiInstanceKeyOverride = `$Key
if (`$Test) { `$script:TestMode = `$true }
Initialize-FixItLog
if (`$myAction -eq 'Gui') { `$i = Enter-FixItGuiInstance; `$script:FixItVersion = `$Ver; Save-FixItGuiInstanceInfo -Instance `$i -Handle ([IntPtr]5) }
'READY'
Start-Sleep -Seconds 120
"@ | Set-Content -LiteralPath $fake
    'Start-Sleep -Seconds 120' | Set-Content -LiteralPath $other
    $procs = @()
    function Start-Pretend { param([string[]]$More) $p = Start-Process -FilePath $pwx -ArgumentList (@('-NoProfile', '-File', $fake) + $More) -PassThru -RedirectStandardOutput (Join-Path $dirW ([guid]::NewGuid().ToString('N') + '.out')); $script:procs += $p; return $p }
    function Wait-Ready { param($P, [string]$OutFile) for ($i = 0; $i -lt 100; $i++) { Start-Sleep -Milliseconds 200; if ($P.HasExited) { return $false }; $f = (Get-ChildItem $dirW -Filter '*.out' | Where-Object { $_.Name -like ('*') } | ForEach-Object { Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue }); if ($f -match 'READY') { return $true } }; return $false }
    $key = $script:GuiInstanceKeyOverride
    $oldWin = Start-Process -FilePath $pwx -ArgumentList @('-NoProfile', '-File', $fake, '-Key', $key, '-Ver', '2.3.4') -PassThru -RedirectStandardOutput (Join-Path $dirW 'old.out')
    $watcher = Start-Process -FilePath $pwx -ArgumentList @('-NoProfile', '-File', $fake, '-Key', $key, '-Action', 'Guardian') -PassThru -RedirectStandardOutput (Join-Path $dirW 'g.out')
    $unrel = Start-Process -FilePath $pwx -ArgumentList @('-NoProfile', '-File', $other) -PassThru
    $ready = $false; for ($i = 0; $i -lt 150; $i++) { Start-Sleep -Milliseconds 200; if ((Test-Path (Join-Path $dirW 'old.out')) -and ((Get-Content (Join-Path $dirW 'old.out') -Raw) -match 'READY') -and (Test-Path (Join-Path $dirW 'g.out')) -and ((Get-Content (Join-Path $dirW 'g.out') -Raw) -match 'READY')) { $ready = $true; break } }
    Assert $ready 'three real child processes started (an old window, a pop-up watcher look-alike, an unrelated script)'
    # the real process list, read from /proc for our own children only
    function Get-FixItProcessTable {
        $o = @(); foreach ($p in @($oldWin, $watcher, $unrel)) { try { $c = (Get-Content -LiteralPath ('/proc/' + $p.Id + '/cmdline') -Raw) -replace "`0", ' '; $o += [pscustomobject]@{ Id = [int]$p.Id; Name = 'pwsh'; CommandLine = $c.Trim(); SessionId = 1; Owner = '' } } catch { } }
        return @($o)
    }
    function Test-FixItProcessAlive { param([int]$Id) $pr = Get-Process -Id $Id -ErrorAction SilentlyContinue; return ($null -ne $pr -and -not $pr.HasExited) }
    function Request-FixItWindowClose { param([int]$Id) $pr = Get-Process -Id $Id -ErrorAction SilentlyContinue; if ($pr) { [void]$pr.CloseMainWindow() } }
    function Stop-FixItWindowProcess { param([int]$Id) Stop-Process -Id $Id -Force -ErrorAction Stop }
    function Get-FixItProcessOwner { param([int]$Id) return '' }
    $script:TestMode = $false; $script:DryRun = $false; $script:Admin = $false; $Action = 'Gui'
    Remove-Item Function:\Test-FixItAdmin -ErrorAction SilentlyContinue
    $got = @(Get-FixItGuiProcesses | ForEach-Object { $_.Id })
    Assert ($got.Count -eq 1 -and $got[0] -eq $oldWin.Id) ('the real process list finds only the window (' + ($got -join ',') + ' vs ' + $oldWin.Id + ')')
    $infoFile = Get-FixItGuiInstanceFile -Key (Get-FixItGuiInstanceNames).Key
    Assert ((Test-Path $infoFile) -and (Get-Content $infoFile -Raw) -match '2\.3\.4') 'the old window wrote its version (2.3.4) into its window file'
    # now the real second start: Enter really fails, the old window is replaced, the new one takes the real lock
    function Enter-FixItGuiInstance { $n = Get-FixItGuiInstanceNames; $m = New-Object System.Threading.Mutex($false, $n.Mutex); $got = $false; try { $got = $m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }; if (-not $got) { $m.Dispose() }; return [pscustomobject]@{ Acquired = $got; Failed = $false; Abandoned = $false; Mutex = $(if ($got) { $m } else { $null }); Event = $null; Names = $n } }
    function Close-FixItOtherModeWindow { return @() }
    $script:Calls.Clear(); $script:GuiCloseWaitSeconds = 1
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Show-FixItWindow
    $sw.Stop()
    Start-Sleep -Milliseconds 500
    Assert (-not (Test-FixItProcessAlive -Id $oldWin.Id)) 'the real old window process is gone'
    Assert ((Test-FixItProcessAlive -Id $watcher.Id) -and (Test-FixItProcessAlive -Id $unrel.Id)) 'the pop-up watcher look-alike and the unrelated script are still running'
    Assert (((Calls) -split ' > ') -contains 'MAIN WINDOW' -and (Calls) -notmatch 'FORWARD') ('the new window opened and nothing was brought forward (' + (Calls) + ', ' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + ' s)')
    # and the update path closes a real window too
    $oldWin2 = Start-Process -FilePath $pwx -ArgumentList @('-NoProfile', '-File', $fake, '-Key', ($key + '2'), '-Ver', '2.3.4') -PassThru -RedirectStandardOutput (Join-Path $dirW 'old2.out')
    for ($i = 0; $i -lt 150; $i++) { Start-Sleep -Milliseconds 200; if ((Test-Path (Join-Path $dirW 'old2.out')) -and ((Get-Content (Join-Path $dirW 'old2.out') -Raw) -match 'READY')) { break } }
    function Get-FixItProcessTable {
        $o = @(); foreach ($p in @($oldWin2, $watcher, $unrel)) { try { $c = (Get-Content -LiteralPath ('/proc/' + $p.Id + '/cmdline') -Raw) -replace "`0", ' '; $o += [pscustomobject]@{ Id = [int]$p.Id; Name = 'pwsh'; CommandLine = $c.Trim(); SessionId = 1; Owner = '' } } catch { } }
        return @($o)
    }
    $closed = @(Close-FixItOtherGuiWindows -Why 'update')
    Assert ($closed.Count -eq 1 -and -not (Test-FixItProcessAlive -Id $oldWin2.Id) -and (Test-FixItProcessAlive -Id $watcher.Id) -and (Test-FixItProcessAlive -Id $unrel.Id)) 'a real update step closes the real window and leaves the watcher look-alike and the other script alone'
    foreach ($p in @($oldWin, $oldWin2, $watcher, $unrel)) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
} else {
    Write-Host '  (real-process checks run on Linux only)'
}

# ================================================================ 7. wording and the shape of the code
Section 'Plain wording, no new questions, the pop-up watcher is safe'
$newFns = @('Get-FixItGuiWindowKind', 'Get-FixItProcessTable', 'Get-FixItGuiProcesses', 'Close-FixItGuiProcesses', 'Close-FixItOtherGuiWindows', 'Get-FixItDiskVersion', 'Read-FixItGuiInstanceInfo', 'Get-FixItGuiExistingDecision', 'Invoke-FixItGuiReplaceExisting', 'Close-FixItOtherModeWindow', 'Show-FixItWindow')
$newText = ($newFns | ForEach-Object { (Get-Fn $_).Extent.Text }) -join "`n"
Assert ($newText -notmatch 'MessageBox|Confirm-FixIt|Show-FixItQuestion|Read-Host|ShowDialog|Show-FixItResult') 'none of it shows a box or asks the person anything'
$uiStrings = @([regex]::Matches($newText, "Write-FixItLog \('([^']*)'") | ForEach-Object { $_.Groups[1].Value })
Assert ($uiStrings.Count -ge 8) ('the new log lines were found (' + $uiStrings.Count + ')')
Assert (@([regex]::Matches($newText, "Write-FixItLog [^\r\n]*'(ERROR|FATAL)'")).Count -eq 0) 'nothing here logs an ERROR for a normal close'
Assert ((Get-Fn 'Close-FixItGuiProcesses').Extent.Text -notmatch "Name\s*=\s*'powershell" -and (Get-Fn 'Stop-FixItWindowProcess').Extent.Text -match 'Id \$Id') 'processes are only ever stopped by id, never by name'
$src2 = [IO.File]::ReadAllText($src)
Assert (([regex]::Matches($src2, 'Stop-FixItWindowProcess')).Count -eq 2 -and (Get-Fn 'Close-FixItGuiProcesses').Extent.Text -match 'still -notcontains \$id') 'forcing happens in one place, and only after the command line is checked again'
Assert ((Get-Fn 'Stop-FixItGuardianProcess').Extent.Text -match "Action\\s\+Guardian") 'the pop-up watcher still has its own, separate stop path'
Assert ($newText -notmatch 'Stop-FixItGuardianProcess|Start-FixItGuardianProcess') 'the new code never stops or starts the pop-up watcher'
Assert ($src2 -match "'<' \+ 'OWNER>'" -and $src2 -notmatch '[Rr]aw\.githubusercontent\.com/<OWNER>/family-it-fixit/main/\$') 'the placeholder guard is unchanged'
$bad = @($src2 -split "`n" | Select-String -Pattern '[^\x00-\x7F]' | Where-Object { $_.Line -match 'Close-FixIt|GuiExisting|OtherMode' })
Assert ($bad.Count -eq 0) 'the new code is plain ASCII (safe in Windows PowerShell 5.1)'

# ================================================================ 8. the installer
Section 'The installer closes old windows before it replaces the program'
. (Join-Path $root 'Install-FixIt.ps1') -LibraryOnly
$script:InstallLog = Join-Path $tmp 'install.log'
Assert ($script:InstallerVersion -eq '1.1.0') 'the installer is version 1.1.0'
foreach ($k in $kinds.Keys) {
    $want = $(if ($kinds[$k]) { 'Window' } else { '' })
    Assert ((Get-InstallGuiWindowKind -CommandLine $k) -eq $want) ('installer: "' + ($k -replace [regex]::Escape($P), '<P>') + '" is [' + $want + ']')
}
$script:ITable = @(); $script:IAlive = @{}; $script:IAsked = New-Object System.Collections.ArrayList; $script:IForced = New-Object System.Collections.ArrayList; $script:IPolite = @{}; $script:ISaid = New-Object System.Collections.ArrayList
function Get-InstallProcessTable { return @($script:ITable) }
function Get-InstallOwnSession { return 1 }
function Get-InstallOwnUserName { return 'PC\trey' }
function Get-InstallProcessOwner { param([int]$Id) return '' }
function Test-InstallProcessAlive { param([int]$Id) return ($script:IAlive.ContainsKey($Id) -and $script:IAlive[$Id]) }
function Request-InstallWindowClose { param([int]$Id) [void]$script:IAsked.Add($Id); if ($script:IPolite.ContainsKey($Id) -and $script:IPolite[$Id]) { $script:IAlive[$Id] = $false } }
function Stop-InstallWindowProcess { param([int]$Id) [void]$script:IForced.Add($Id); $script:IAlive[$Id] = $false }
function Say { param([string]$Text, [string]$Color = '') [void]$script:ISaid.Add($Text) }
function Reset-I { $script:IAlive = @{}; $script:IAsked.Clear(); $script:IForced.Clear(); $script:IPolite = @{}; $script:ISaid.Clear() }
function IRow { param([int]$Id, [string]$Cmd, [int]$Session = 1) return [pscustomobject]@{ Id = $Id; CommandLine = $Cmd; SessionId = $Session; Owner = '' } }
Reset-I
$script:IAlive = @{ 100 = $true; 101 = $true; 102 = $true; 103 = $true; 104 = $true }; $script:IPolite = @{ 100 = $true }
$script:ITable = @((IRow 100 $base), (IRow 101 ($base + ' -Test')), (IRow 102 ($base + ' -Action Guardian')), (IRow 103 'powershell.exe -File C:\x\other.ps1'), (IRow 104 $base 2))
$n = Stop-InstallGuiWindows -WaitSeconds 1
Assert ($n -eq 2 -and (@($script:IAsked | Sort-Object) -join ',') -eq '100,101' -and (@($script:IForced) -join ',') -eq '101') 'the installer asks both windows politely and forces only the one that stays open'
Assert ($script:IAlive[102] -and $script:IAlive[103] -and $script:IAlive[104]) 'the watcher, an unrelated script and another person''s window are untouched'
Assert (@($script:ISaid).Count -eq 1 -and $script:ISaid[0] -match '^\s*Closing the Family Fix-It window that is open, so it can be updated') 'one plain sentence tells the person what is happening'
Assert ((Get-Content $script:InstallLog -Raw) -match 'Closed 2 of 2 Family Fix-It window\(s\)') 'what was closed is logged'
Reset-I; $script:ITable = @((IRow 102 ($base + ' -Action Guardian')))
$n = Stop-InstallGuiWindows -WaitSeconds 1
Assert ($n -eq 0 -and $script:IAsked.Count -eq 0 -and $script:ISaid.Count -eq 0) 'nothing open: nothing asked, nothing said (idempotent)'
Reset-I; $script:IAlive = @{ 100 = $true }; $script:IPolite = @{}; $script:ITable = @((IRow 100 $base))
$script:Phase2 = 0
function Test-InstallProcessAlive { param([int]$Id) if ($script:Phase2 -eq 0 -and $script:IAsked.Count -gt 0) { $script:Phase2 = 1; $script:ITable = @((IRow 100 'notepad.exe')) }; return ($script:IAlive.ContainsKey($Id) -and $script:IAlive[$Id]) }
[void](Stop-InstallGuiWindows -WaitSeconds 0)
Assert ($script:IForced.Count -eq 0) 'the installer also leaves alone an id that now belongs to another program'
function Test-InstallProcessAlive { param([int]$Id) return ($script:IAlive.ContainsKey($Id) -and $script:IAlive[$Id]) }
function Get-InstallProcessTable { throw 'cannot list' }
Assert ((Stop-InstallGuiWindows -WaitSeconds 1) -eq 0) 'if the list cannot be read, the installer carries on without it'
function Get-InstallProcessTable { return @($script:ITable) }

# in the real install step: closed after the download is checked, before the program file is replaced
$bd = Join-Path $tmp 'inst-base'; New-Item -ItemType Directory -Path $bd | Out-Null
$sd = Join-Path $tmp 'inst-src'; New-Item -ItemType Directory -Path $sd | Out-Null
'new program' | Set-Content -LiteralPath (Join-Path $sd 'FamilyFixIt.ps1'); 'new cmd' | Set-Content -LiteralPath (Join-Path $sd 'Start-FixIt.cmd'); 'guides new' | Set-Content -LiteralPath (Join-Path $sd 'guides.json')
'old program' | Set-Content -LiteralPath (Join-Path $bd 'FamilyFixIt.ps1'); 'new cmd' | Set-Content -LiteralPath (Join-Path $bd 'Start-FixIt.cmd'); 'guides old' | Set-Content -LiteralPath (Join-Path $bd 'guides.json')
function Save-InstallFile { param([string]$Url, [string]$Dest) Copy-Item -LiteralPath (Join-Path $sd (Split-Path -Leaf $Url)) -Destination $Dest }
function Mf { param([string[]]$Names) return [pscustomobject]@{ Version = '9.9.9'; Files = @($Names | ForEach-Object { $p = Join-Path $sd $_; [pscustomobject]@{ Path = $_; Sha256 = (Get-InstallHash $p); Size = (Get-Item $p).Length } }) } }
Reset-I; $script:IAlive = @{ 100 = $true }; $script:IPolite = @{}; $script:ITable = @((IRow 100 $base))
$script:ProgramAtClose = $null
function Request-InstallWindowClose { param([int]$Id) [void]$script:IAsked.Add($Id); if ($null -eq $script:ProgramAtClose) { $script:ProgramAtClose = (Get-Content (Join-Path $bd 'FamilyFixIt.ps1') -Raw).Trim() } }
$ch = @(Install-FixItFiles -Manifest (Mf @('FamilyFixIt.ps1', 'Start-FixIt.cmd', 'guides.json')) -Base 'https://example.test' -Dir $bd)
Assert ($ch -contains 'FamilyFixIt.ps1' -and $script:ProgramAtClose -eq 'old program') 'the installer asked the window to close while the old program was still in place'
Assert ($script:IForced.Count -eq 1 -and (Get-Content (Join-Path $bd 'FamilyFixIt.ps1') -Raw).Trim() -eq 'new program') 'then forced it, and only then replaced the program'
# run again: everything is current, so no window is touched
Reset-I; $script:IAlive = @{ 100 = $true }; $script:ITable = @((IRow 100 $base))
$ch = @(Install-FixItFiles -Manifest (Mf @('FamilyFixIt.ps1', 'Start-FixIt.cmd', 'guides.json')) -Base 'https://example.test' -Dir $bd)
Assert ($ch.Count -eq 0 -and $script:IAsked.Count -eq 0 -and $script:IAlive[100]) 'running the installer again with nothing to change leaves the open window alone'
# only the help guides changed: the open window is not disturbed
'guides newer' | Set-Content -LiteralPath (Join-Path $sd 'guides.json')
$ch = @(Install-FixItFiles -Manifest (Mf @('FamilyFixIt.ps1', 'Start-FixIt.cmd', 'guides.json')) -Base 'https://example.test' -Dir $bd)
Assert ($ch -contains 'guides.json' -and $ch -notcontains 'FamilyFixIt.ps1' -and $script:IAsked.Count -eq 0) 'a change to the help guides alone does not close the window'
# a bad download still changes nothing and closes nothing
Reset-I; $script:IAlive = @{ 100 = $true }; $script:ITable = @((IRow 100 $base))
'program v3' | Set-Content -LiteralPath (Join-Path $sd 'FamilyFixIt.ps1'); $m3 = Mf @('FamilyFixIt.ps1', 'Start-FixIt.cmd', 'guides.json'); 'tampered' | Set-Content -LiteralPath (Join-Path $sd 'FamilyFixIt.ps1')
$threw = $false; try { [void](Install-FixItFiles -Manifest $m3 -Base 'https://example.test' -Dir $bd) } catch { $threw = $true }
Assert ($threw -and $script:IAsked.Count -eq 0 -and (Get-Content (Join-Path $bd 'FamilyFixIt.ps1') -Raw).Trim() -eq 'new program') 'a download that fails its check closes no window and replaces nothing'
$inst = [IO.File]::ReadAllText((Join-Path $root 'Install-FixIt.ps1'))
Assert ($inst -match "InstallerPlaceholder = \('<' \+ 'OWNER>'\)") 'the installer''s placeholder guard is unchanged'
Assert (([regex]::Matches($inst, 'Stop-Process')).Count -eq 1 -and $inst -notmatch 'Stop-Process\s+-Name|taskkill|Get-Process\s+(-Name\s+)?powershell') 'the installer stops processes only by id, in one place'
Assert ($inst -notmatch 'Guardian(?!Off|On)\b[^\r\n]*Stop-InstallWindowProcess') 'the installer''s closing code never targets the watcher'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('Passed: {0}   Failed: {1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
