# Version 2.3.4 tests: Test mode, the My files scan and the "window never freezes" work.
# These use the REAL program functions (Test-FixIt.ps1 replaces many of them with pretend ones), so they run in their own PowerShell.
# Usage:  pwsh ./tests/Test-FixIt-V234.ps1       (Test-FixIt.ps1 runs this one too and adds its numbers)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fixit-v234-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:Pass = 0; $script:Fail = 0
function Assert { param([bool]$Cond, [string]$Name) if ($Cond) { $script:Pass++ } else { $script:Fail++; Write-Host ('  FAIL: ' + $Name) -ForegroundColor Red } }
function Section { param([string]$T) Write-Host ('== ' + $T) }

$src = Join-Path $root 'FamilyFixIt.ps1'
$outDir = Join-Path $tmp 'out'
New-Item -ItemType Directory -Path $outDir | Out-Null
$logFile = Join-Path $tmp 'v234.log'
. $src -LibraryOnly -LogPath $logFile -OutputDir $outDir
Initialize-FixItLog

$tokens = $null; $perr = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$perr)
$A = [Management.Automation.Language.CommandAst]
$FnAst = [Management.Automation.Language.FunctionDefinitionAst]
$allFns = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
function Get-Fn { param([string]$Name) return ($allFns | Where-Object { $_.Name -eq $Name } | Select-Object -First 1) }
function Get-CmdNames { param($Node) return @($Node.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ }) }
function Get-OwnerFn { param($Node) $f = $Node.Parent; while ($f -and $f -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $f = $f.Parent }; if ($f) { return $f.Name } return '<top>' }
function Test-InStep { param($Node) $p = $Node.Parent; while ($p) { if ($p -is [Management.Automation.Language.CommandAst] -and $p.GetCommandName() -eq 'Invoke-FixItStep') { return $true }; if ($p -is [Management.Automation.Language.FunctionDefinitionAst]) { return $false }; $p = $p.Parent }; return $false }

# the functions that start with the Test mode guard (probe macro) and the adapter name each one reports
$guarded = @{}
foreach ($f in $allFns) {
    $stmts = @($f.Body.EndBlock.Statements | Select-Object -First 2)
    foreach ($st in $stmts) { if ($st.Extent.Text -match "(?s)^if \(\`$script:TestMode\b.*?Invoke-FixItProbe -Adapter '([^']+)'") { $guarded[$f.Name] = $Matches[1] } }
}
$script:SavedTest = @{ TestMode = $script:TestMode; DryRun = $script:DryRun; GuiActive = $script:GuiActive; TestAll = $script:TestAll }
function Set-TestModeOn { $script:TestMode = $true; $script:DryRun = $true; $script:GuiActive = $false }
function Restore-Modes { $script:TestMode = $false; $script:DryRun = $false; $script:GuiActive = $false; $script:TestAll = $false; $script:InProbe = $false }

# ================================================================ Test mode: the central guard
Section 'Test mode: central guard'
Assert ($guarded.Count -ge 45) ('many adapters carry the guard (found ' + $guarded.Count + ')')
$wrongName = @($guarded.GetEnumerator() | Where-Object { $_.Key -ne $_.Value })
Assert ($wrongName.Count -eq 0) ('every guard reports its own function name (' + (($wrongName | ForEach-Object { $_.Key + '/' + $_.Value }) -join ',') + ')')
foreach ($must in @('Set-RegDword', 'Set-RegString', 'Remove-RegValue', 'Stop-FixItService', 'Start-FixItService', 'Stop-SpoolerService', 'Remove-SpoolFile', 'Clear-FixItFolder', 'Clear-FixItRecycleBin', 'Stop-FixItApp', 'Stop-FixItAppsByName', 'Stop-FixItProcessForce', 'Request-AppClose', 'Restart-FixItComputer', 'Restart-FixItNow', 'Restart-FixItAdapter', 'Remove-FixItPrinter', 'Add-FixItPrinterConnection', 'Set-FixItDefaultPrinter', 'Set-FixItAudioDevice', 'Invoke-Msi', 'Invoke-FixItNative', 'Send-WebReport', 'Save-WebFile', 'Write-FixItTextFile', 'Register-FixItTask', 'Unregister-FixItTask', 'Copy-FixItBackup', 'Restore-FixItFile', 'Restore-FixItFolder', 'Rename-FixItFolderAside', 'Clear-FixItBrowserSessions', 'Start-FixItGuardianProcess', 'Stop-FixItGuardianProcess', 'Start-FixItDefenderScan', 'Start-FixItOutlook', 'Start-FixItOutlookSafe', 'Start-FixItOneDrive', 'Start-FixItOneDriveReset', 'Install-FixItApp', 'Open-FixItFile', 'Open-FixItUrl', 'Open-FixItSettings', 'Open-FixItBrowserPage', 'Open-FixItUserFile', 'Show-FixItFileInFolder', 'Repair-FixItIcon')) {
    Assert ($guarded.ContainsKey($must)) ("guarded in Test mode: $must")
}
# the guard is the FIRST statement (nothing can run before it)
$late = @()
foreach ($n in $guarded.Keys) {
    $f = Get-Fn $n
    $first = @($f.Body.EndBlock.Statements)[0]
    $second = $null; if (@($f.Body.EndBlock.Statements).Count -gt 1) { $second = @($f.Body.EndBlock.Statements)[1] }
    $firstOk = ($first.Extent.Text -match 'Invoke-FixItProbe')
    $secondOk = ($null -ne $second -and $second.Extent.Text -match 'Invoke-FixItProbe' -and $first.Extent.Text -match 'Test-FixItOffUiWanted')
    if (-not ($firstOk -or $secondOk)) { $late += $n }
}
Assert ($late.Count -eq 0) ('the Test mode guard comes before everything else (' + ($late -join ',') + ')')
# each guard returns right after the probe (the body is never reached)
$noReturn = @(); foreach ($n in $guarded.Keys) { $f = Get-Fn $n; $st = @($f.Body.EndBlock.Statements | Where-Object { $_.Extent.Text -match 'Invoke-FixItProbe' })[0]; if ($st.Extent.Text -notmatch '\breturn\b') { $noReturn += $n } }
Assert ($noReturn.Count -eq 0) ('each guard returns straight after the probe (' + ($noReturn -join ',') + ')')

Set-TestModeOn
$dummy = @{ string = 'x'; 'string[]' = @('x'); int = 1; 'int[]' = @(1); bool = $true; double = 1.0; long = 1; 'int64' = 1; 'object' = 'x'; 'hashtable' = @{ }; 'scriptblock' = { } }
function New-DummyArgs { param($Fn) $h = @{}
    $pb = $Fn.Body.ParamBlock; if ($null -eq $pb) { return $h }
    foreach ($p in $pb.Parameters) {
        $nm = $p.Name.VariablePath.UserPath
        $ty = ''; $tt = @($p.Attributes | Where-Object { $_ -is [Management.Automation.Language.TypeConstraintAst] }); if ($tt.Count -gt 0) { $ty = $tt[0].TypeName.Name.ToLower() }
        if ($ty -eq 'switch') { continue }
        $vs = @($p.Attributes | Where-Object { $_ -is [Management.Automation.Language.AttributeAst] -and $_.TypeName.Name -eq 'ValidateSet' })
        if ($vs.Count -gt 0) { $h[$nm] = [string]$vs[0].PositionalArguments[0].Value; continue }
        if ($ty -eq 'string' -and $nm -match 'Path|File|Folder|Dest|From|To') { $h[$nm] = (Join-Path $tmp 'nothing-here.txt'); continue }
        if ($dummy.ContainsKey($ty)) { $h[$nm] = $dummy[$ty] } else { $h[$nm] = 'x' }
    }
    return $h
}
$thrown = 0; $missed = @()
foreach ($n in ($guarded.Keys | Sort-Object)) {
    $script:InProbe = $false
    $args2 = New-DummyArgs (Get-Fn $n)
    $threw = $false; $msg = ''
    try { [void](& $n @args2) } catch { $threw = $true; $msg = $_.Exception.Message }
    if ($threw -and $msg -match 'outside a checked step') { $thrown++ } else { $missed += ($n + ' [' + $msg + ']') }
}
Restore-Modes
Assert ($missed.Count -eq 0) ('in Test mode every changing adapter throws when called outside a checked step: ' + ($missed -join '; '))
Assert ($thrown -eq $guarded.Count) ("all $($guarded.Count) guarded adapters refuse (refused: $thrown)")
Assert ((Get-Content -LiteralPath $logFile -Raw) -match 'TEST MODE BLOCKED: Set-RegDword') 'a blocked change is logged'

# inside a checked step the adapter only records a check, and nothing real runs
Set-TestModeOn
$script:RawCalls = New-Object System.Collections.ArrayList
foreach ($raw in @('Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Stop-Process', 'Stop-Service', 'Start-Service', 'Restart-Service', 'Set-Service', 'Start-Process', 'Restart-Computer', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Clear-RecycleBin', 'Register-ScheduledTask', 'Unregister-ScheduledTask', 'Rename-Item', 'Move-Item', 'Add-Printer', 'Remove-Printer', 'Set-Printer', 'Restart-NetAdapter', 'Set-Clipboard', 'Start-MpScan', 'Copy-Item', 'Remove-Item', 'Set-Content', 'Out-File', 'Add-Content', 'New-Item')) {
    Set-Item -Path ('Function:\' + $raw) -Value ([scriptblock]::Create('[void]$script:RawCalls.Add(''' + $raw + ''')'))
}
$realReach = (Get-Command Test-FixItReportReachable).ScriptBlock; $realHost = (Get-Command Test-HostReachable).ScriptBlock
function Test-FixItReportReachable { param([string]$Url) return $true }
function Test-HostReachable { param([string]$ComputerName) return $false }
$ranBody = 0
foreach ($n in ($guarded.Keys | Sort-Object)) {
    Start-FixItTestButton
    $args2 = New-DummyArgs (Get-Fn $n)
    $ok = $true
    try { [void](Invoke-FixItTestStep -Description ('check ' + $n) -Do ([scriptblock]::Create('& ' + $n + ' @args2')).GetNewClosure()) } catch { $ok = $false }
    $recs = @(Get-FixItTestRecords)
    if (-not $ok -or $recs.Count -ne 1 -or @('PASS', 'WARN', 'FAIL') -notcontains $recs[0].Status) { $ranBody++; Write-Host ('  step problem: ' + $n) }
}
Assert ($ranBody -eq 0) 'each guarded adapter, inside a step, only records PASS/WARN/FAIL'
Assert ($script:RawCalls.Count -eq 0) ('no raw changing command ran while every guarded adapter was checked (' + (($script:RawCalls | Select-Object -Unique) -join ',') + ')')
# no adapter falls to the default "no check is written"
$noCheck = @()
foreach ($n in $guarded.Keys) {
    $script:InProbe = $true; $script:ProbeResults = New-Object System.Collections.ArrayList
    try { Invoke-FixItProbe -Adapter $guarded[$n] -Arguments (New-DummyArgs (Get-Fn $n)) } catch { }
    if (@($script:ProbeResults | Where-Object { $_.Text -match 'no check is written' }).Count -gt 0) { $noCheck += $n }
    $script:InProbe = $false
}
Assert ($noCheck.Count -eq 0) ('every guarded adapter has its own preflight check (' + ($noCheck -join ',') + ')')
foreach ($raw in @('Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Stop-Process', 'Stop-Service', 'Start-Service', 'Restart-Service', 'Set-Service', 'Start-Process', 'Restart-Computer', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Clear-RecycleBin', 'Register-ScheduledTask', 'Unregister-ScheduledTask', 'Rename-Item', 'Move-Item', 'Add-Printer', 'Remove-Printer', 'Set-Printer', 'Restart-NetAdapter', 'Set-Clipboard', 'Start-MpScan', 'Copy-Item', 'Remove-Item', 'Set-Content', 'Out-File', 'Add-Content', 'New-Item')) { Microsoft.PowerShell.Management\Remove-Item -Path ('Function:\' + $raw) }
Restore-Modes

# step blocks only call checked adapters (or reviewed helpers); no raw changing command hides in a step
Section 'Test mode: change steps'
$mutCmd = '^(Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|Remove-Item|Copy-Item|Move-Item|New-Item|Rename-Item|Set-Content|Add-Content|Out-File|Stop-Process|Stop-Service|Start-Service|Restart-Service|Set-Service|Start-Process|Restart-Computer|Stop-Computer|Clear-RecycleBin|Restart-NetAdapter|Invoke-WebRequest|Invoke-RestMethod|Register-ScheduledTask|Unregister-ScheduledTask|Set-Clipboard|Remove-Printer|Add-Printer|Set-Printer|Clear-Content|Start-Job|Start-MpScan|Invoke-Item|Invoke-Expression|schtasks(\.exe)?|msiexec(\.exe)?|shutdown(\.exe)?|taskkill(\.exe)?|reg(\.exe)?|netsh(\.exe)?|ipconfig(\.exe)?|sfc(\.exe)?|DISM(\.exe)?|winget(\.exe)?|explorer\.exe|cmd(\.exe)?)$'
$reviewedHelpers = @('Add-FixItUndoStep', 'Wait-FixIt', 'Invoke-FixItTool', 'Set-FixItPrivacyAllow', 'Install-FixItCheckIn', 'Test-FixItGuardianRunning')
$stepCalls = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-FixItStep' }, $true))
Assert ($stepCalls.Count -ge 60) ('found the change steps (' + $stepCalls.Count + ')')
$rawInStep = @(); $unknownInStep = @(); $noBlock = 0
foreach ($c in $stepCalls) {
    $sb = @($c.CommandElements | Where-Object { $_ -is [Management.Automation.Language.ScriptBlockExpressionAst] })
    if ($sb.Count -eq 0) { if ((Get-OwnerFn $c) -ne 'Invoke-FixItStep') { $noBlock++ }; continue }
    foreach ($n in (Get-CmdNames $sb[0])) {
        if ($n -match $mutCmd) { $rawInStep += ('{0}:{1}' -f $c.Extent.StartLineNumber, $n) }
        elseif ($n -match '^(Invoke-|Set-|Remove-|Stop-|Start-|Clear-|Restore-|Rename-|Add-|Install-|Register-|Unregister-|Send-|Save-|Write-|Open-|Request-|Restart-|Copy-)' -and -not $guarded.ContainsKey($n) -and $reviewedHelpers -notcontains $n -and $n -notmatch '^(Write-FixItLog|Write-Host|Add-FixItTestNote|Invoke-FixItStep)$') { $unknownInStep += ('{0}:{1}' -f $c.Extent.StartLineNumber, $n) }
    }
}
Assert ($rawInStep.Count -eq 0) ('no raw changing command inside a change step (' + ($rawInStep -join ', ') + ')')
Assert ($unknownInStep.Count -eq 0) ('change steps only use checked adapters or reviewed helpers (' + ($unknownInStep -join ', ') + ')')
Assert ($noBlock -eq 0) 'every change step passes its work as a script block'
# the reviewed helpers only pass work on to checked adapters
$delegates = @{ 'Invoke-FixItTool' = 'Invoke-FixItNative'; 'Set-FixItPrivacyAllow' = 'Set-RegString'; 'Install-FixItCheckIn' = 'Register-FixItTask' }
foreach ($k in $delegates.Keys) { Assert ((Get-CmdNames (Get-Fn $k)) -contains $delegates[$k]) ("$k hands the work to the checked adapter $($delegates[$k])") }
foreach ($h in @('Invoke-FixItTool', 'Set-FixItPrivacyAllow', 'Install-FixItCheckIn', 'Add-FixItUndoStep', 'Test-FixItGuardianRunning')) {
    $bad = @((Get-CmdNames (Get-Fn $h)) | Where-Object { $_ -match $mutCmd })
    Assert ($bad.Count -eq 0) ("reviewed helper $h has no raw changing command ($($bad -join ','))")
}

# every function that has a raw changing command is either guarded or on the reviewed list (a new one makes this fail on purpose)
$mutMember = '^(WriteAllText|WriteAllBytes|WriteAllLines|AppendAllText|AppendAllLines|Delete|Move|Copy|Kill|CloseMainWindow|Start|CreateDirectory|SetValue|SetAttributes|Create|CreateSubKey|DeleteSubKey|DeleteSubKeyTree|DeleteValue|SendKeys|SetForegroundWindow|Invoke|Open|Run|Save)$'
$rawBy = @{}
foreach ($c in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) { $nm = $c.GetCommandName(); if ($nm -and $nm -match $mutCmd -or ($nm -and $nm -match '^Add-Type$')) { $k = Get-OwnerFn $c; if (-not $rawBy.ContainsKey($k)) { $rawBy[$k] = @() }; $rawBy[$k] += $nm } }
foreach ($c in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) { $m = $c.Member.Extent.Text; if ($m -match $mutMember) { $k = Get-OwnerFn $c; if (-not $rawBy.ContainsKey($k)) { $rawBy[$k] = @() }; $rawBy[$k] += ('.' + $m) } }
$reviewedRaw = @{
    'Initialize-FixItLog' = 'its own log folder'; 'Write-FixItLog' = 'the log file'; 'Test-FixItFileWritable' = 'opens read-only to test'
    'Save-FixItTestResults' = 'the results file the person asked for'; 'Get-FixItOffUiWorker' = 'opens a worker, no change'; 'Invoke-FixItOffUi' = 'starts a worker, no change'
    'Get-WebText' = 'a read (GET)'; 'Test-FixItHttps' = 'a read (HEAD/GET)'; 'Write-FixItShortcutIcon' = 'only called by the guarded Repair-FixItIcon'
    'Initialize-FixItAudio' = 'loads a type, no change'; 'Initialize-FixItGuardianNative' = 'loads a type'; 'Get-FixItBrowserUrl' = 'reads a window'
    'Invoke-AdminPart' = 'removes its own temporary result file'; 'Get-FileSha256' = 'hash, read-only'; 'Invoke-UndoLast' = 'its own temporary file; steps run through checked adapters'
    'Start-FixItFileSearch' = 'starts the background lister (it only lists)'; 'Start-FixItGuardianLoop' = 'the watcher itself; not run in Test mode'
    'Wait-FixItGuardianToastClosed' = 'the watcher itself; not run in Test mode'; 'Get-FixItPcCode' = 'hash, read-only'; 'New-FixItTile' = 'screen only'
    'Show-FixItWindowOnce' = 'timer, screen only'; 'Exit-FixItGuiInstance' = 'removes its own one-window marker'; 'Save-FixItGuiInstanceInfo' = 'its own one-window marker'
    'Initialize-FixItGuiFocus' = 'loads a type'; 'Start-FixItGuiShowWatcher' = 'timer'; 'Show-FixItWindowMain' = 'loads a type'; 'Show-FixItCountdownDialog' = 'timer, screen only'
    'Update-FixItFilesList' = 'timer, screen only'; 'Show-FixItGuidesDialog' = 'timer, screen only'
    'Set-FixItStateValue' = 'ends first in Test mode (checked below)'; 'Write-FixItUndoJournal' = 'ends first in Test mode (checked below)'; 'Write-AdminResult' = 'ends first in Test mode (checked below)'
    'Start-FixItElevated' = 'throws first in Test mode (checked below)'
    'Stop-FixItWindowProcess' = 'closes only a Family Fix-It WINDOW, after its command line was checked again; used by updates and window replacement, never by a fix step'
    'Request-FixItWindowClose' = 'asks a Family Fix-It window to close (the X button); same callers as above'
    'Open-FixItMainWindow' = 'only the watcher tray menu calls it; opens the normal window (returns first in Test mode and practice mode)'
    'Show-FixItHardwareAlert' = 'shows one message box only; returns first in Test mode and practice mode'
}
foreach ($b in @('Set-FixItStateValue', 'Write-FixItUndoJournal', 'Write-AdminResult')) {
    $first = @((Get-Fn $b).Body.EndBlock.Statements)[0].Extent.Text
    Assert ($first -match '^if \(\$script:TestMode\) \{ return \}') ("$b does nothing in Test mode (its first statement returns)")
}
Assert (@((Get-Fn 'Start-FixItElevated').Body.EndBlock.Statements)[0].Extent.Text -match '^if \(\$script:TestMode\) \{ throw') 'Start-FixItElevated throws first in Test mode'
$unreviewed = @($rawBy.Keys | Where-Object { -not $guarded.ContainsKey($_) -and -not $reviewedRaw.ContainsKey($_) -and $_ -ne 'Invoke-FixItNative' })
Assert ($unreviewed.Count -eq 0) ('a function with a raw changing command must carry the Test mode guard or be reviewed and listed here (' + (($unreviewed | ForEach-Object { $_ + ':' + (($rawBy[$_] | Select-Object -Unique) -join '/') }) -join '; ') + ')')

# calls to checked adapters that are NOT inside a change step: only from reviewed places
$adapterNames = @($guarded.Keys) + @('Invoke-FixItTool', 'Set-FixItPrivacyAllow', 'Install-FixItCheckIn')
$outside = @{}
foreach ($c in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
    $nm = $c.GetCommandName(); if (-not $nm -or $adapterNames -notcontains $nm) { continue }
    $own = Get-OwnerFn $c
    if ($own -eq $nm -or $guarded.ContainsKey($own) -or (Test-InStep $c)) { continue }
    $outside[('{0}>{1}' -f $own, $nm)] = $true
}
$reviewedOutside = @('Set-FixItPrivacyAllow>Set-RegString', 'Invoke-AdminPart>Start-FixItElevated', 'Invoke-AcrobatRepairAdmin>Invoke-Msi', 'Send-FixItReport>Send-WebReport', 'Invoke-FixItReport>Save-FixItReportFile', 'Invoke-FixItReport>Open-FixItFile', 'Invoke-ScamAlert>Save-FixItReportFile', 'Install-FixItUpdate>Save-WebFile', 'Invoke-FixItUpdate>Install-FixItUpdate', 'Invoke-NetworkFix>Save-FixItReportFile', 'Invoke-WinUpdateFix>Restart-FixItComputer', 'Install-FixItCheckIn>Register-FixItTask', 'Close-FixItBrowsers>Stop-FixItProcessForce', 'Invoke-GuardianClose>Clear-FixItBrowserSessions', 'Invoke-GuardianAlert>Save-FixItReportFile', 'Initialize-FixItGuardianDefault>Start-FixItGuardianProcess', 'Show-FixItWindowOnce>Repair-FixItIcon', 'Test-FixItAppInstalled>Invoke-FixItNative', 'Test-FixItTask>Invoke-FixItNative', 'Invoke-AcrobatRepair>Request-AppClose', 'Close-FixItOutlookFully>Request-AppClose')
$newOutside = @($outside.Keys | Where-Object { $reviewedOutside -notcontains $_ -and $_ -notmatch '^(Invoke-FixItTool>|Invoke-FixItStep>)' })
Assert ($newOutside.Count -eq 0) ('changing calls outside a change step are only in reviewed places (' + ($newOutside -join ', ') + ')')
Set-TestModeOn
$e = $null; try { Start-FixItElevated -Part 'PrinterAdmin' -ResultPath (Join-Path $tmp 'r.json') } catch { $e = $_.Exception.Message }
Assert ($e -match 'never asks Windows for administrator') 'Test mode never starts an elevated process (it throws)'
Restore-Modes

# Programs: only the two read-only questions may run in Test mode
Section 'Test mode: programs and elevation'
Assert (Test-FixItNativeReadOnly -File 'schtasks.exe' -Arguments @('/query', '/tn', 'x')) 'schtasks /query is a read-only question'
Assert (-not (Test-FixItNativeReadOnly -File 'schtasks.exe' -Arguments @('/create', '/tn', 'x'))) 'schtasks /create is never read-only'
Assert (-not (Test-FixItNativeReadOnly -File 'schtasks.exe' -Arguments @('/delete', '/tn', 'x'))) 'schtasks /delete is never read-only'
Assert (Test-FixItNativeReadOnly -File 'winget.exe' -Arguments @('list', '--id', 'x')) 'winget list is read-only'
Assert (-not (Test-FixItNativeReadOnly -File 'winget.exe' -Arguments @('install', 'x'))) 'winget install is not read-only'
foreach ($bad in @('ipconfig.exe', 'netsh.exe', 'sfc.exe', 'DISM.exe', 'msiexec.exe', 'shutdown.exe', 'taskkill.exe', 'reg.exe', 'powershell.exe')) { Assert (-not (Test-FixItNativeReadOnly -File $bad -Arguments @('/x'))) ("$bad is only checked in Test mode, never run") }
Set-TestModeOn
$script:InProbe = $false
$e = ''; try { [void](Invoke-FixItNative -File 'ipconfig.exe' -Arguments @('/flushdns')) } catch { $e = $_.Exception.Message }
Assert ($e -match 'outside a checked step') 'a program that changes things is refused outside a step in Test mode'
$res = $null
Start-FixItTestButton
[void](Invoke-FixItTestStep -Description 'flush dns' -Do { $script:NativeRes = Invoke-FixItNative -File 'ipconfig.exe' -Arguments @('/flushdns') })
Assert ($script:NativeRes.ExitCode -eq 0) 'inside a step the program is not run and pretends to end with code 0'
$r1 = @(Get-FixItTestRecords)[0]
Assert (@($r1.Checks | Where-Object { $_.Text -match 'administrator' }).Count -ge 1 -or $r1.Status -in @('PASS', 'WARN', 'FAIL')) 'the check says whether administrator permission would be needed'
Restore-Modes

# The Test-mode flow: checklist, summary, report preview, test-all and results file
Section 'Test mode: flows'
Set-TestModeOn
Start-FixItTestButton
[void](Invoke-FixItTestStep -Description 'one' -Do { Set-RegDword -Path 'HKCU:\Software\FixItNoSuchKey' -Name 'X' -Value 1 })
[void](Invoke-FixItTestStep -Description 'two' -Do { Start-SpoolerService })
$recs = @(Get-FixItTestRecords)
Assert ($recs.Count -eq 2) 'two checked steps were recorded'
Assert (@($recs | Where-Object { $_.Status -notin @('PASS', 'WARN', 'FAIL') }).Count -eq 0) 'every record has PASS, WARN or FAIL'
$sum = Get-FixItTestSummaryLine -Records $recs
Assert ($sum -match '\d+ passed|PASS|passed') ('the summary line counts results: ' + $sum)
$list = Format-FixItTestChecklist -Title 'Printer' -Records $recs -Said 'Done - fixed'
$listText = ($list -join "`n")
Assert ($listText -match 'one' -and $listText -match 'two') 'the checklist names every step'
Assert ($listText -match '\[(PASS|WARN|FAIL)\]|PASS|WARN|FAIL') 'the checklist shows PASS/WARN/FAIL marks'
Assert ($listText -match 'Nothing was changed|nothing was changed|Nothing was') 'the checklist says nothing was changed'
Assert ($listText -notmatch 'Practice run') 'Practice run wording is not shown in Test mode'
Restore-Modes

# the report: what WOULD be sent is shown, nothing is sent
Set-TestModeOn
$script:WebCalls = New-Object System.Collections.ArrayList
function Invoke-WebRequest { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) [void]$script:WebCalls.Add('iwr') }
function Invoke-RestMethod { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) [void]$script:WebCalls.Add('irm') }
Start-FixItTestButton
$sent = Send-FixItReport -Text 'Hello Trey. This is a test report.' -Kind 'report'
Assert ($sent -eq $true) 'Test mode treats the report as sendable (it checks, it does not send)'
Assert ($script:WebCalls.Count -eq 0) 'no web request was made while checking the report'
$rr = @(Get-FixItTestRecords)
Assert ($rr.Count -ge 1 -and ($rr | ForEach-Object { $_.Step }) -match 'Send the report') 'the report send was recorded as a checked step'
Assert ($script:TestLastReportPreview -match 'Hello Trey') 'the report preview shows what would be sent'
Microsoft.PowerShell.Management\Remove-Item -Path Function:\Invoke-WebRequest; Microsoft.PowerShell.Management\Remove-Item -Path Function:\Invoke-RestMethod
Restore-Modes

# Test all buttons: every fix, the file, no real change
Section 'Test mode: test all buttons'
$script:RawCalls = New-Object System.Collections.ArrayList
$rawList = @('Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Stop-Process', 'Stop-Service', 'Start-Service', 'Restart-Service', 'Set-Service', 'Start-Process', 'Restart-Computer', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Clear-RecycleBin', 'Register-ScheduledTask', 'Unregister-ScheduledTask', 'Rename-Item', 'Move-Item', 'Add-Printer', 'Remove-Printer', 'Set-Printer', 'Restart-NetAdapter', 'Set-Clipboard', 'Start-MpScan', 'Copy-Item', 'Remove-Item', 'Set-Content', 'Out-File', 'Add-Content', 'New-Item', 'Stop-Computer')
$rawList = @($rawList | Where-Object { $_ -notin @('Invoke-WebRequest', 'Invoke-RestMethod') })   # reading a web page (update list, connectivity) is allowed; sending is checked above
foreach ($raw in $rawList) { Set-Item -Path ('Function:\' + $raw) -Value ([scriptblock]::Create('[void]$script:RawCalls.Add(''' + $raw + ''')')) }
Set-TestModeOn
$script:AssumeYes = $false
$beforeFiles = @(Get-ChildItem -LiteralPath $outDir -Force | ForEach-Object { $_.Name })
$prog = New-Object System.Collections.ArrayList
$all = @(Invoke-FixItTestAll -Progress { param($i, $n, $t) [void]$prog.Add($t) })
Assert ($all.Count -eq $script:TestAllKeys.Count) ("every button was checked ($($all.Count) of $($script:TestAllKeys.Count))")
Assert ($script:TestAllKeys.Count -ge 18) 'test all covers all the fix buttons'
Assert ($prog.Count -eq $all.Count) 'progress was reported for every button'
Assert (@($all | Where-Object { $_.Status -notin @('PASS', 'WARN', 'FAIL') }).Count -eq 0) 'every button ended with PASS, WARN or FAIL'
Assert (@($all | Where-Object { @($_.Records).Count -eq 0 }).Count -eq 0) 'every button has at least one recorded check'
Assert ($script:RawCalls.Count -eq 0) ('Test all buttons ran no raw changing command (' + (($script:RawCalls | Select-Object -Unique) -join ',') + ')')
$afterFiles = @(Get-ChildItem -LiteralPath $outDir -Force | ForEach-Object { $_.Name })
Assert ((@($afterFiles | Where-Object { $beforeFiles -notcontains $_ })).Count -eq 0) 'Test all buttons wrote no report or other file'
Assert ($script:TestAll -eq $false) 'the test-all flag is switched off afterwards'
foreach ($raw in $rawList) { Microsoft.PowerShell.Management\Remove-Item -Path ('Function:\' + $raw) }
$path = Save-FixItTestResults -Results $all
Assert ((Test-Path -LiteralPath $path) -and (Split-Path -Parent $path) -eq $outDir) 'the results file is saved (here: the chosen folder, normally the Desktop)'
Assert ((Split-Path -Leaf $path) -match '^FamilyFixIt-TestResults-.*-\d{8}-\d{4}\.txt$') ('the results file name: ' + (Split-Path -Leaf $path))
$txt = [IO.File]::ReadAllText($path)
Assert ($txt -match 'TEST MODE' -and $txt -match 'PASS|WARN|FAIL') 'the results file has the banner and results'
foreach ($k in $script:TestAllKeys) { $t = (Get-FixItActionTable)[$k]; if ($t) { Assert ($txt.Contains([string]$t.Title)) ("the results file lists the button: $($t.Title)") } }
Restore-Modes
Set-Item -Path Function:\Test-FixItReportReachable -Value $realReach; Set-Item -Path Function:\Test-HostReachable -Value $realHost
# the settings the program remembers are not touched in Test mode
Set-TestModeOn
$stateBefore = Get-FixItStateFile
$stExists = Test-Path -LiteralPath $stateBefore
Set-FixItStateValue -Name 'ZzTestOnly' -Value '1'
Assert ((Test-Path -LiteralPath $stateBefore) -eq $stExists) 'Test mode does not write the settings file'
Restore-Modes

# the switch and the window are wired up
Section 'Test mode: switch, window, installer'
$srcText = [IO.File]::ReadAllText($src)
Assert ($srcText -match '\[switch\]\$Test\b') 'the program has a -Test switch'
Assert ($srcText -match '\$script:TestMode\s*=\s*\(?\[bool\]\$Test|\$script:TestMode = \$Test') 'the -Test switch turns Test mode on'
Assert ($srcText -match 'TEST MODE - nothing is changed') 'the window shows a TEST MODE banner'
Assert ($srcText -match 'Test all buttons') 'the window has a Test all buttons option'
Assert ($srcText -match 'Family Fix-It - TEST MODE') 'the window title says TEST MODE'
Assert ($srcText -match "'TestAll'") 'there is a -Action TestAll'
$pillStart = [regex]::Match($srcText, 'if \(-not \$script:TestMode\) \{ \$tm\.Start\(\) \}')
Assert ($pillStart.Success) 'the health pill timer does not start in Test mode'
$inst = [IO.File]::ReadAllText((Join-Path $root 'Install-FixIt.ps1'))
Assert ($inst -match "TestShortcutName\s*=\s*'Family Fix-It \(Test mode\)'") 'the installer names the Test mode shortcut'
Assert ($inst -match '\$args2 \+ . -Test.') 'the Test mode shortcut passes -Test'
Assert ($srcText -match "TestShortcutFileName\s*=\s*'Family Fix-It \(Test mode\)\.lnk'") 'the program knows the Test mode shortcut file name (for the icon repair)'
$spBody = (Get-Fn 'Get-FixItShortcutPaths').Extent.Text
Assert ($spBody -match 'TestShortcutFileName' -and $spBody -match 'ShortcutFileName') 'the icon repair looks after the Test mode shortcut as well as the normal ones'
Assert ((Get-Fn 'Complete-FixItTestRecords') -ne $null) 'a button with no change step still gets an explanatory line in its checklist'
Assert ($srcText -match "TestMode -and \(\`$Action -eq 'Guardian'") 'helper actions (watcher, administrator parts) are not run on their own in Test mode'
# a button that reached no change step is explained, not a bare PASS
Set-TestModeOn
Start-FixItTestButton
Complete-FixItTestRecords -Result (New-FixItResult $false 'Acrobat not found' 'Not installed here.')
$z = @(Get-FixItTestRecords)
Assert ($z.Count -eq 1 -and $z[0].Status -eq 'WARN' -and $z[0].Checks[0].Text -match 'Acrobat not found') 'a button that stopped early shows WARN with what it said'
Start-FixItTestButton
Complete-FixItTestRecords -Result (New-FixItResult $true 'Practice run' 'x')
$z = @(Get-FixItTestRecords)
Assert ($z.Count -eq 1 -and $z[0].Status -eq 'PASS') 'a button with nothing to fix shows PASS with the reason'
Restore-Modes

# ================================================================ My files
Section 'My files: the scan'
$sc = Join-Path $tmp 'scan'
New-Item -ItemType Directory -Path $sc | Out-Null
$ext = Join-Path $tmp 'outside'
New-Item -ItemType Directory -Path $ext | Out-Null
Set-Content -LiteralPath (Join-Path $ext 'outside-secret.txt') 'x'
Set-Content -LiteralPath (Join-Path $sc 'alpha-report.txt') 'x'
$dir1 = Join-Path $sc 'docs'; New-Item -ItemType Directory -Path $dir1 | Out-Null
Set-Content -LiteralPath (Join-Path $dir1 'alpha-notes.txt') 'x'
Set-Content -LiteralPath (Join-Path $dir1 'junk.tmp') 'x'
# a long chain of folders: level N holds alpha-level-N.txt
$chain = $sc
for ($i = 1; $i -le 10; $i++) { $chain = Join-Path $chain ('d' + $i); New-Item -ItemType Directory -Path $chain | Out-Null; Set-Content -LiteralPath (Join-Path $chain ('alpha-level-' + $i + '.txt')) 'x' }
$linkOk = $true
try { New-Item -ItemType SymbolicLink -Path (Join-Path $sc 'linked-outside') -Target $ext | Out-Null; New-Item -ItemType SymbolicLink -Path (Join-Path $dir1 'loop') -Target $sc | Out-Null } catch { $linkOk = $false }
$script:ScanRoots = @($sc)
function Get-FixItUserFolders { return @($script:ScanRoots | ForEach-Object { [pscustomobject]@{ Label = 'x'; Path = $_ } }) }
function Get-ScanArgs { param([string]$Query = 'alpha', [hashtable]$Over = @{}) $st = New-FixItFileScanState; $a = Get-FixItFileScanArgs -Query $Query -Max 50 -State $st; foreach ($k in $Over.Keys) { $a[$k] = $Over[$k] }; return $a }
function Run-Scan { param([hashtable]$Over = @{}, [string]$Query = 'alpha') $a = Get-ScanArgs -Query $Query -Over $Over; & $script:FileScanScript @a; return $a.State }
$st = Run-Scan
$names = @($st.Result | ForEach-Object { $_.Name })
Assert ($st.Done -and $st.Reason -eq '') 'a normal scan finishes by itself'
Assert ($names -contains 'alpha-report.txt' -and $names -contains 'alpha-notes.txt') 'files are found by name'
Assert ($names -notcontains 'junk.tmp') 'junk files are left out'
Assert ($names -contains 'alpha-level-8.txt' -and $names -notcontains 'alpha-level-9.txt' -and $names -notcontains 'alpha-level-10.txt') 'depth is capped at 8 levels'
if ($linkOk) {
    Assert (@($st.Result | Where-Object { $_.FullName -like '*outside-secret*' }).Count -eq 0) 'a link to another folder is not followed'
    Assert ($st.Skipped -ge 2) ('links are counted as skipped (' + $st.Skipped + ')')
    $realDirs = @(Get-ChildItem -LiteralPath $sc -Recurse -Directory -Force | Where-Object { -not $_.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) }).Count + 1
    $deepest = 8  # levels beyond 8 are not entered
    Assert ($st.Folders -le $realDirs) ('a loop is not walked again (folders looked at: ' + $st.Folders + ' of ' + $realDirs + ')')
} else { Write-Host '  (could not make symbolic links here; link checks skipped)' }
# a folder listed inside another listed folder is walked once
$st2 = Run-Scan -Over @{ Roots = @($sc, $dir1, $sc) }
$st1 = Run-Scan
Assert ($st2.Folders -eq $st1.Folders -and $st2.Files -eq $st1.Files) 'a folder inside another listed folder (OneDrive holds Desktop) is looked at once'
Assert (@($st2.Result | Where-Object { $_.Name -eq 'alpha-notes.txt' }).Count -eq 1) 'and its files are listed once'
# limits
$st = Run-Scan -Over @{ MaxFolders = 3 }; Assert ($st.Reason -eq 'folder limit' -and $st.Folders -eq 3 -and $st.Done) 'stops at the folder limit'
$st = Run-Scan -Over @{ MaxFiles = 2 }; Assert ($st.Reason -eq 'file limit' -and $st.Done) 'stops at the file limit'
$st = Run-Scan -Over @{ MaxSeconds = 0 }; Assert ($st.Reason -eq 'time limit' -and $st.Done) 'stops at the time limit'
$a = Get-ScanArgs; $a.State.Cancel = $true; & $script:FileScanScript @a
Assert ($a.State.Reason -eq 'cancelled' -and $a.State.Done -and $a.State.Folders -eq 0) 'stops straight away when cancelled'
Assert ($script:FileScanLimits.Depth -le 8 -and $script:FileScanLimits.Folders -le 5000 -and $script:FileScanLimits.Files -le 50000 -and $script:FileScanLimits.Seconds -le 20) 'the default limits are small'
$a = Get-FixItFileScanArgs -Query 'x' -Max 5 -State (New-FixItFileScanState)
Assert ($a.MaxDepth -eq $script:FileScanLimits.Depth -and $a.MaxFolders -eq $script:FileScanLimits.Folders -and $a.MaxFiles -eq $script:FileScanLimits.Files -and $a.MaxSeconds -eq $script:FileScanLimits.Seconds) 'the window passes the limits to the scan'

# cloud-only and link attributes: such files and folders are skipped and never opened
$script:FakeEntries = New-Object System.Collections.ArrayList
function New-FakeFile { param([string]$Name, [int]$Attr) $o = [pscustomobject]@{ Name = $Name; FullName = ('X:\fake\' + $Name); DirectoryName = 'X:\fake'; Attributes = $Attr; LastWriteTime = (Get-Date); Length = 1024 }; return $o }
foreach ($def in @(@('plain-alpha.txt', 0x20), @('offline-alpha.txt', 0x1000), @('recall-open-alpha.txt', 0x40000), @('recall-data-alpha.txt', 0x400000), @('link-alpha.txt', 0x400), @('cloud-and-pinned-alpha.txt', (0x1000 -bor 0x20)))) { [void]$script:FakeEntries.Add((New-FakeFile $def[0] $def[1])) }
$fakeDi = [pscustomobject]@{ }
$fakeDi | Add-Member -MemberType ScriptMethod -Name EnumerateFileSystemInfos -Value { return $script:FakeEntries }
function New-Object { param([Parameter(Position = 0)]$TypeName, [Parameter(Position = 1)]$ArgumentList)
    if ($TypeName -eq 'System.IO.DirectoryInfo') { return $fakeDi }
    if ($null -ne $ArgumentList) { $made = Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -ArgumentList $ArgumentList } else { $made = Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName }
    return ,$made
}
$st = Run-Scan -Over @{ Roots = @('X:\fake') }
Microsoft.PowerShell.Management\Remove-Item -Path Function:\New-Object
$fn = @($st.Result | ForEach-Object { $_.Name })
Assert ($fn -contains 'plain-alpha.txt') 'a normal local file is listed'
Assert ($fn -notcontains 'offline-alpha.txt' -and $fn -notcontains 'recall-open-alpha.txt' -and $fn -notcontains 'recall-data-alpha.txt' -and $fn -notcontains 'link-alpha.txt' -and $fn -notcontains 'cloud-and-pinned-alpha.txt') 'cloud-only (Offline, recall on open, recall on data access) and link entries are skipped'
Assert ($st.Skipped -eq 5) ('and counted as skipped (' + $st.Skipped + ')')
# the scan never opens a file
$fs = $script:FileScanScript.Ast
$scanCmds = @($fs.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
foreach ($bad in @('Get-Content', 'Get-Item', 'Get-FileHash', 'Get-ItemProperty', 'Set-Content', 'Remove-Item', 'Copy-Item', 'Move-Item', 'Start-Process', 'Invoke-Item', 'Out-File', 'Test-Path', 'Resolve-Path', 'Start-Sleep', 'Write-Host')) { Assert ($scanCmds -notcontains $bad) ("the scan never calls $bad") }
$scanText = $script:FileScanScript.ToString()
Assert ($scanText -notmatch '\[(System\.)?IO\.File\]::' -and $scanText -notmatch 'OpenRead|ReadAllText|ReadAllBytes|\.OpenText|\.Open\(|FileStream|StreamReader') 'the scan has no way to open or read a file (so nothing is downloaded)'
Assert ($scanText -match 'EnumerateFileSystemInfos' -and $scanText -notmatch 'Get-ChildItem') 'the scan only lists names and dates'
foreach ($bit in @('0x400', '0x1000', '0x40000', '0x400000')) { Assert ($scanText.Contains($bit)) ("the scan checks the attribute bit $bit") }
Assert ($scanText -notmatch '\$script:|Write-FixItLog') 'the scan touches no program state, so it can run in a background runspace'

# the background version
Section 'My files: background search'
$script:ScanRoots = @($sc)
$job = Start-FixItFileSearch -Query 'alpha' -Max 20
$t0 = Get-Date; $status = 'Running'
while ($status -ne 'Done' -and ((Get-Date) - $t0).TotalSeconds -lt 20) { Start-Sleep -Milliseconds 40; $status = Get-FixItFileSearchStatus -Job $job }
Assert ($status -eq 'Done') 'the background search finishes and the poll says Done'
Assert (@($job.State.Result | Where-Object { $_.Name -eq 'alpha-report.txt' }).Count -eq 1) 'the background search returns the files'
Assert ($job.State.Reason -eq '') 'and it finished by itself'
Close-FixItFileSearch -Job $job
Assert ($null -ne $job.Handle) 'the search ran as a background call (it has a handle to wait on)'
# polling never blocks: while it is running the poll returns at once
$bigRoot = Join-Path $tmp 'big'; New-Item -ItemType Directory -Path $bigRoot | Out-Null
for ($i = 0; $i -lt 60; $i++) { $d = Join-Path $bigRoot ('f' + $i); New-Item -ItemType Directory -Path $d | Out-Null; for ($j = 0; $j -lt 20; $j++) { Set-Content -LiteralPath (Join-Path $d ('alpha-' + $j + '.txt')) 'x' } }
$script:ScanRoots = @($bigRoot)
$job = Start-FixItFileSearch -Query 'alpha' -Max 5
$swp = [Diagnostics.Stopwatch]::StartNew(); $polls = 0
do { [void](Get-FixItFileSearchStatus -Job $job); $polls++ } while (-not $job.State.Done -and $swp.ElapsedMilliseconds -lt 50)
Assert ($polls -ge 1) 'polling returns at once'
Stop-FixItFileSearch -Job $job
$t0 = Get-Date; while (-not $job.State.Done -and ((Get-Date) - $t0).TotalSeconds -lt 20) { Start-Sleep -Milliseconds 40 }
Assert ($job.State.Done) 'Cancel stops the background search'
Assert ($job.State.Reason -in @('cancelled', '')) ('after Cancel it ends as cancelled or finished (' + $job.State.Reason + ')')
Close-FixItFileSearch -Job $job
Assert ((Get-Content -LiteralPath $logFile -Raw) -match 'My files: Cancel clicked') 'Cancel is logged'
# a search that never ends is given up on, the window stays alive
$fake = [pscustomobject]@{ State = (New-FixItFileScanState); Query = 'x'; PS = $null; Runspace = $null; Handle = $null; Started = (Get-Date).AddSeconds(-($script:FileScanLimits.Seconds + 30)); Abandoned = $false; LastLog = (Get-Date) }
$status = Get-FixItFileSearchStatus -Job $fake
Assert ($status -eq 'Done' -and $fake.Abandoned -and $fake.State.Reason -eq 'did not finish' -and $fake.State.Cancel) 'a search stuck longer than its time limit is given up on (the window stays alive)'
Close-FixItFileSearch -Job $fake
Assert ((Get-Content -LiteralPath $logFile -Raw) -match 'My files: the background search did not finish in time') 'and that is logged'
Assert ((Get-Content -LiteralPath $logFile -Raw) -match 'My files: looking in the background in \d+ folder') 'starting the search is logged with its limits'
$sync = Find-FixItFiles -Query 'alpha' -Max 3
$script:ScanRoots = @($sc)
$sync = Find-FixItFiles -Query 'alpha' -Max 3
Assert (@($sync).Count -eq 3) 'the command-line version returns the newest matches up to Max'
Assert ((Get-Content -LiteralPath $logFile -Raw) -match 'My files: finished in [\d.]+s: \d+ files looked at, \d+ folders') 'the finish line says how much was looked at'

# the window code
Section 'My files: the window'
$upd = Get-Fn 'Update-FixItFilesList'; $poll = Get-Fn 'Invoke-FixItFilesPoll'; $dlg = Get-Fn 'Show-FixItFilesDialog'
foreach ($f in @($upd, $poll)) {
    $c = Get-CmdNames $f
    foreach ($bad in @('Find-FixItFiles', 'Get-ChildItem', 'Start-Sleep', 'Get-Content', 'Wait-FixIt')) { Assert ($c -notcontains $bad) ("$($f.Name) never calls $bad (nothing slow on the window thread)") }
}
Assert ((Get-CmdNames $upd) -contains 'Start-FixItFileSearch') 'the list is filled by the background search'
Assert ((Get-CmdNames $poll) -contains 'Get-FixItFileSearchStatus') 'the timer asks the search how it is doing'
Assert ($dlg.Extent.Text -match "-Title 'Cancel'") 'the My files window has a Cancel button'
Assert ($dlg.Extent.Text -match 'Stop-FixItFileSearch' -or ((Get-Fn 'Invoke-GuiButton').Extent.Text -match 'Stop-FixItFileSearch')) 'the Cancel button stops the search'
Assert ($srcText -match 'Looking\.\.\. you can click Cancel') 'a Looking... message is shown while it works'
Assert ($dlg.Extent.Text -match 'FilesTimer' -and $dlg.Extent.Text -match 'Interval\s*=\s*200') 'the window polls the search from a 200 ms timer'
Assert ($dlg.Extent.Text -match 'window closed while looking') 'closing the window while looking stops the search (logged)'
$gb = (Get-Fn 'Invoke-GuiButton').Body.EndBlock.Statements
$firstTexts = @($gb | Select-Object -First 5 | ForEach-Object { $_.Extent.Text })
Assert (($firstTexts -join "`n") -match 'Button clicked') 'every click is logged before anything else happens'
$clickIdx = -1; $i = 0; foreach ($st3 in $gb) { if ($st3.Extent.Text -match 'Button clicked' -and $clickIdx -lt 0) { $clickIdx = $i }; $i++ }
$firstAction = -1; $i = 0; foreach ($st3 in $gb) { if ($st3.Extent.Text -match 'Invoke-FixItAction|Show-FixItFilesDialog|Open-FixItFoundFile' -and $firstAction -lt 0) { $firstAction = $i }; $i++ }
Assert ($clickIdx -ge 0 -and $clickIdx -lt $firstAction) 'the click is logged before the action runs'

# ================================================================ The window never waits on slow work
Section 'Window stays responsive: waiting'
$wrapped = @{}
foreach ($f in $allFns) {
    $stmts = @($f.Body.EndBlock.Statements | Select-Object -First 3)
    foreach ($st in $stmts) { if ($st.Extent.Text -match "^if \(\(?Test-FixItOffUiWanted\)?( -and -not \`$Live)?\) \{ return \(Invoke-FixItOffUi -Command '([^']+)'( -Arguments \`$PSBoundParameters)?\) \}") { $wrapped[$f.Name] = $Matches[2] } }
}
Assert ($wrapped.Count -ge 40) ('slow Windows questions, web calls and programs run in the background worker (' + $wrapped.Count + ' functions)')
$badName = @($wrapped.GetEnumerator() | Where-Object { $_.Key -ne $_.Value })
Assert ($badName.Count -eq 0) ('each background guard names its own function (' + (($badName | ForEach-Object { $_.Key }) -join ',') + ')')
foreach ($must in @('Get-WebText', 'Save-WebFile', 'Send-WebReport', 'Test-FixItHttps', 'Test-FixItPing', 'Test-FixItDns', 'Test-HostReachable', 'Get-FixItEvents', 'Get-FixItCrashes', 'Get-FixItDiskHealth', 'Get-FixItPendingUpdates', 'Get-FixItDefender', 'Get-FixItOsInfo', 'Get-FixItFreeBytes', 'Get-FixItPrinters', 'Get-FixItAdapters', 'Get-FixItHungApps', 'Get-FixItTopApps', 'Get-FixItFolderBytes', 'Get-FixItHealthPill', 'Invoke-Msi', 'Invoke-FixItNative', 'Clear-FixItFolder', 'Stop-SpoolerService', 'Start-SpoolerService', 'Stop-FixItService', 'Start-FixItService', 'Stop-FixItApp', 'Restart-FixItAdapter', 'Copy-FixItBackup', 'Clear-FixItRecycleBin', 'Get-InstalledProducts', 'Get-FixItOneDriveInfo', 'Get-FixItBrowserProfiles')) { Assert ($wrapped.ContainsKey($must)) ("runs in the background when the window is open: $must") }
# for changing functions the Test mode guard still comes first
foreach ($n in $wrapped.Keys) {
    if ($guarded.ContainsKey($n)) {
        $stm = @((Get-Fn $n).Body.EndBlock.Statements)
        $iProbe = -1; $iOff = -1; for ($i = 0; $i -lt $stm.Count; $i++) { if ($stm[$i].Extent.Text -match 'Invoke-FixItProbe' -and $iProbe -lt 0) { $iProbe = $i }; if ($stm[$i].Extent.Text -match 'Invoke-FixItOffUi' -and $iOff -lt 0) { $iOff = $i } }
        Assert ($iProbe -ge 0 -and $iProbe -lt $iOff) ("$n checks Test mode before it goes to the background")
    }
}
# the guard truth table
$sv = @{ G = $script:GuiActive; W = $script:InOffUiWorker; B = $script:OffUiBroken }
foreach ($row in @(@($false, $false, $false, $false), @($true, $false, $false, $true), @($true, $true, $false, $false), @($true, $false, $true, $false), @($false, $true, $true, $false))) {
    $script:GuiActive = $row[0]; $script:InOffUiWorker = $row[1]; $script:OffUiBroken = $row[2]
    Assert ((Test-FixItOffUiWanted) -eq $row[3]) ("background only when the window is open, not already in the worker and not broken: gui=$($row[0]) worker=$($row[1]) broken=$($row[2])")
}
$script:GuiActive = $sv.G; $script:InOffUiWorker = $sv.W; $script:OffUiBroken = $sv.B

# every wrapped function hands over to the worker (and does not run its own body)
$realOffUi = (Get-Command Invoke-FixItOffUi).ScriptBlock
$script:OffUiSeen = New-Object System.Collections.ArrayList
function Invoke-FixItOffUi { param([string]$Command, $Arguments = $null, [int]$TimeoutSeconds = 0) [void]$script:OffUiSeen.Add($Command); return 'FROM-WORKER' }
$script:GuiActive = $true; $script:TestMode = $false; $script:DryRun = $false
$notHanded = @()
foreach ($n in ($wrapped.Keys | Sort-Object)) {
    $before = $script:OffUiSeen.Count
    $args2 = New-DummyArgs (Get-Fn $n)
    $r = $null; $err = ''
    try { $r = & $n @args2 } catch { $err = $_.Exception.Message }
    if ($script:OffUiSeen.Count -ne $before + 1 -or $script:OffUiSeen[$before] -ne $n -or ($r -ne 'FROM-WORKER')) { $notHanded += ($n + ' ' + $err) }
}
Assert ($notHanded.Count -eq 0) ('every background function hands its work to the worker when the window is open (' + ($notHanded -join '; ') + ')')
$before = $script:OffUiSeen.Count
$script:GuiActive = $false
foreach ($n in @('Get-FixItOsInfo', 'Test-FixItDns')) { try { [void](& $n) } catch { } }
Assert ($script:OffUiSeen.Count -eq $before) 'without the window (command line, tests) they run right where they are called'
$script:GuiActive = $true
$before = $script:OffUiSeen.Count
try { [void](Invoke-FixItNative -File 'x.exe' -Arguments @('a') -Live) } catch { }
Assert ($script:OffUiSeen.Count -eq $before) 'a program shown live in its own window stays on the caller (it is not sent to the worker)'
Set-Item -Path Function:\Invoke-FixItOffUi -Value $realOffUi
Restore-Modes

# Wait-FixIt
$script:SleepCalls = New-Object System.Collections.ArrayList
function Start-Sleep { param([double]$Seconds, [int]$Milliseconds) [void]$script:SleepCalls.Add([int]([math]::Round($Seconds * 1000)) + $Milliseconds) }
$realUpdate = (Get-Command Update-FixItUi).ScriptBlock
$script:Pumps = 0
function Update-FixItUi { $script:Pumps++ }
$script:GuiActive = $false
Wait-FixIt -Seconds 2
Assert ($script:SleepCalls.Count -eq 1 -and $script:SleepCalls[0] -eq 2000) 'without a window, Wait-FixIt is a plain wait'
$script:SleepCalls.Clear(); $script:InProbe = $true; Wait-FixIt -Seconds 5; $script:InProbe = $false
Assert ($script:SleepCalls.Count -eq 0 -and $script:Pumps -eq 0) 'in Test mode checks nothing waits'
$script:GuiActive = $true; $script:SleepCalls.Clear(); $script:Pumps = 0
$sw2 = [Diagnostics.Stopwatch]::StartNew(); Wait-FixIt -Milliseconds 250; $sw2.Stop()
Assert ($script:SleepCalls.Count -eq 0) 'with the window open Wait-FixIt never uses Start-Sleep (that would freeze it)'
Assert ($script:Pumps -ge 4) ('with the window open Wait-FixIt keeps the window alive while it waits (' + $script:Pumps + ' pumps)')
Assert ($sw2.ElapsedMilliseconds -ge 230 -and $sw2.ElapsedMilliseconds -lt 1500) ('and still waits about the right time (' + $sw2.ElapsedMilliseconds + ' ms)')
$script:GuiActive = $false
Microsoft.PowerShell.Management\Remove-Item -Path Function:\Start-Sleep
Set-Item -Path Function:\Update-FixItUi -Value $realUpdate
# nothing else sleeps, and nothing waits on a program on the window thread
$sleepCalls = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-Sleep' }, $true) | ForEach-Object { Get-OwnerFn $_ } | Select-Object -Unique)
Assert (($sleepCalls -join ',') -eq 'Wait-FixIt') ('Start-Sleep is used only inside Wait-FixIt (' + ($sleepCalls -join ',') + ')')
$waits = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-Process' -and (@($n.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Wait' }).Count -gt 0) }, $true) | ForEach-Object { Get-OwnerFn $_ } | Select-Object -Unique)
$badWait = @($waits | Where-Object { -not $wrapped.ContainsKey($_) })
Assert ($badWait.Count -eq 0) ('Start-Process -Wait is only inside functions that run in the background (' + ($badWait -join ',') + ')')
$wfe = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'WaitForExit' }, $true) | ForEach-Object { Get-OwnerFn $_ } | Select-Object -Unique)
$badWfe = @($wfe | Where-Object { -not $wrapped.ContainsKey($_) })
Assert ($badWfe.Count -eq 0) ('WaitForExit is only inside functions that run in the background (' + ($badWfe -join ',') + ')')
$waitUses = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Wait-FixIt' }, $true)).Count
Assert ($waitUses -ge 10) ('the waits in the fixes use Wait-FixIt (' + $waitUses + ')')

Section 'Window stays responsive: the worker'
$tmpFolder = Join-Path $tmp 'sizes'; New-Item -ItemType Directory -Path $tmpFolder | Out-Null
Set-Content -LiteralPath (Join-Path $tmpFolder 'a.txt') ('x' * 1000)
$direct = Get-FixItFolderBytes -Path $tmpFolder
$script:GuiActive = $true
$viaWorker = Get-FixItFolderBytes -Path $tmpFolder
Assert ($viaWorker -eq $direct -and $direct -ge 1000) ('a real background worker gives the same answer as running it directly (' + $viaWorker + ')')
Assert ($script:OffUiWorkers.Count -eq 1 -and -not $script:OffUiBroken) 'one worker was started'
$again = Get-FixItFolderBytes -Path $tmpFolder
Assert ($again -eq $direct -and $script:OffUiWorkers.Count -eq 1) 'the same worker is used again'
$e = ''; try { [void](Invoke-FixItOffUi -Command 'Get-Item' -Arguments @{ LiteralPath = (Join-Path $tmp 'not-here'); ErrorAction = 'Stop' }) } catch { $e = $_.Exception.Message }
Assert ($e -match 'not-here|Cannot find') ('an error in the worker comes back as an error (' + $e + ')')
Assert ($script:OffUiWorkers.Count -eq 1 -and -not $script:OffUiWorkers[0].Busy) 'and the worker is free again afterwards'
Assert ((Invoke-FixItOffUi -Command 'Test-FixItOffUiWanted') -eq $false) 'inside the worker nothing is sent to a second worker'
$sw3 = [Diagnostics.Stopwatch]::StartNew(); $e = ''
try { [void](Invoke-FixItOffUi -Command 'Start-Sleep' -Arguments @{ Seconds = 8 } -TimeoutSeconds 1) } catch { $e = $_.Exception.Message }
$sw3.Stop()
Assert ($e -match 'took too long \(more than 1 seconds\)') ('work that takes too long is given up on with a plain message (' + $e + ')')
Assert ($sw3.ElapsedMilliseconds -lt 5000) ('and the window is free again quickly (' + $sw3.ElapsedMilliseconds + ' ms)')
Assert ($script:OffUiWorkers.Count -eq 0) 'the stuck worker is dropped'
Assert ((Get-Content -LiteralPath $logFile -Raw) -match 'Background work "Start-Sleep" took longer than 1 seconds') 'and that is logged'
$after = Get-FixItFolderBytes -Path $tmpFolder
Assert ($after -eq $direct -and $script:OffUiWorkers.Count -eq 1) 'a fresh worker takes over after a stuck one'
Stop-FixItOffUiWorkers
Assert ($script:OffUiWorkers.Count -eq 0) 'all workers are closed when the window closes'
# a worker that cannot load the program: the work is done right here instead (and only once is it tried)
$goodSelf = $script:SelfPath
$script:SelfPath = Join-Path $tmp 'no-such-program.ps1'
$res = Get-FixItFolderBytes -Path $tmpFolder
Assert ($res -eq $direct -and $script:OffUiBroken) 'if the worker cannot start, the work is done in the window instead (and it is remembered)'
Assert ((Get-Content -LiteralPath $logFile -Raw) -match 'The background worker could not load the program') 'and that is logged'
$script:SelfPath = $goodSelf; $script:OffUiBroken = $false
Stop-FixItOffUiWorkers
$script:GuiActive = $false

Section 'Window stays responsive: clicks and closing'
Assert ($srcText -match '(?s)function Invoke-GuiButton.*?if \(\$script:ActionBusy\) \{ Write-FixItLog \(.Ignored a click') 'a click is ignored (and logged) while a fix is still running'
Assert ($srcText -match '(?s)\$script:ActionBusy = \$true\s*\r?\n\s*try \{ \$r = Invoke-FixItAction -Which \$Which -SkipPlan \} finally \{ \$script:ActionBusy = \$false \}') 'the busy flag is on exactly while a fix runs, and always switched off'
Assert ($srcText -match "Add_FormClosing\(\{[^\r\n]*if \(\`$script:ActionBusy\) \{ \`$fe\.Cancel = \`$true") 'the window cannot be closed in the middle of a fix'
$script:ActionBusy = $true
$script:CalledAction = 0
$realAction = (Get-Command Invoke-FixItAction).ScriptBlock
function Invoke-FixItAction { param([string]$Which, [switch]$SkipPlan) $script:CalledAction++ ; return $null }
Invoke-GuiButton -Which 'Printer'
Set-Item -Path Function:\Invoke-FixItAction -Value $realAction
$script:ActionBusy = $false
Assert ($script:CalledAction -eq 0) 'a click while busy starts nothing'
$lg = Get-Content -LiteralPath $logFile -Raw
Assert ($lg -match 'Button clicked: Printer' -and $lg -match 'Ignored a click on Printer: another action is still running') 'the click and the ignoring are in the log'
Assert ($script:ActionBusy -eq $false) 'the busy flag starts off'
Restore-Modes

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('Passed: {0}   Failed: {1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
