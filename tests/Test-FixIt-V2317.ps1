# Version 2.3.17 tests: the new "Repair Windows" button (the two standard Windows file repairs, one after the other).
#  (1) the button, its "?" help, its "Here is what I will do" window, Test all and the command line;
#  (2) the steps: step 2 waits for step 1, what the second step found is told in plain words, and the restart is asked;
#  (3) practice run and Test mode run nothing.
# Windows-only parts use pretend adapters here; the REAL program functions run.
# Usage:  pwsh ./tests/Test-FixIt-V2317.ps1       (Test-FixIt.ps1 runs this one too and adds its numbers)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fixit-v2317-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:Pass = 0; $script:Fail = 0
function Assert { param([bool]$Cond, [string]$Name) if ($Cond) { $script:Pass++ } else { $script:Fail++; Microsoft.PowerShell.Utility\Write-Host ('  FAIL: ' + $Name) -ForegroundColor Red } }
function Section { param([string]$T) Microsoft.PowerShell.Utility\Write-Host ('== ' + $T) }

$src = Join-Path $root 'FamilyFixIt.ps1'
$outDir = Join-Path $tmp 'out'; New-Item -ItemType Directory -Path $outDir | Out-Null
$env:LOCALAPPDATA = Join-Path $tmp 'local'; New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
$env:COMPUTERNAME = 'TESTPC'
$tLogFile = Join-Path $tmp 'v2317.log'
. $src -LibraryOnly -LogPath $tLogFile -OutputDir $outDir
Initialize-FixItLog
function Get-Log { if (Test-Path -LiteralPath $tLogFile) { return [IO.File]::ReadAllText($tLogFile) }; return '' }
function Clear-Log { if (Test-Path -LiteralPath $tLogFile) { Remove-Item -LiteralPath $tLogFile -Force } }
$srcText = [IO.File]::ReadAllText($src)
$bytes = [IO.File]::ReadAllBytes($src)
$tokens = $null; $perr = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$perr)
function Get-Fn { param([string]$Name) $f = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1; if ($null -eq $f) { return '' }; return $f.Extent.Text }
$AT = '@'
$mikeMail = 'mike' + $AT + 'family.test'

Assert ([version]$script:FixItVersion -ge [version]'2.3.17') 'the program is version 2.3.17 or newer'
Assert ($perr.Count -eq 0) 'the program parses with no errors'
Assert (-not ($srcText -match '[^\x00-\x7F]') -and -not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF) -and $srcText -notmatch "`r") 'the program file is plain ASCII, no BOM, LF line ends'

Section 'Repair Windows: the button'
$lay = Get-FixItLayout -Simple $false
Assert (@($lay.TileIds) -contains 'RepairWindows' -and @($lay.TileIds).Count -eq 14) 'the full layout has the Repair Windows tile (14 main buttons)'
$g = @($lay.Groups | Where-Object { @($_.Tiles | Where-Object { $_[0] -eq 'RepairWindows' }).Count -gt 0 })[0]
$t = @($g.Tiles | Where-Object { $_[0] -eq 'RepairWindows' })[0]
Assert ($t[1] -eq 'Repair Windows' -and $t[2] -eq 'Find and fix damaged files' -and $srcText -match ("'" + $t[3] + "' = 'iVBOR")) 'its title, subtitle and an icon that exists'
Assert (@((Get-FixItLayout -Simple $true).TileIds) -notcontains 'RepairWindows') 'Simple mode is unchanged'
$help = Get-FixItHelpTable
Assert ($help.ContainsKey('RepairWindows') -and $help['RepairWindows'].Text -match 'damaged files' -and $help['RepairWindows'].Text -match '30 to 60 minutes') 'the "?" help says it checks for damaged files and repairs them, and how long it takes'
Assert (@(Get-FixItMainTileKeys -Layout $lay) -contains 'RepairWindows') 'the tile gets a "?" dot'
$a = (Get-FixItActionTable)['RepairWindows']
Assert ($a -and $a.Fn -eq 'Invoke-RepairWindowsFix' -and $a.Fix -and $a.Plan.Time -eq '30 to 60 minutes') 'the action table runs it, and the plan window says 30 to 60 minutes'
$heads = ($a.Plan.Heads -join ' ')
Assert ($heads -match 'do not turn off' -and $heads -match 'leave it open' -and $heads -match 'permission') 'the warning first: do not turn off, leave the window open, Windows asks permission'
Assert ($script:TestAllKeys -contains 'RepairWindows') 'Test all checks the new button'
Assert ($srcText -match "ValidateSet\('Gui', 'TestAll'[^\]]*'RepairWindows'" -and $srcText -match "'RepairWindows'\s+\{ \[void\]\(Invoke-FixItAndShow -Which 'RepairWindows'\) \}" -and $srcText -match "'RepairWindowsAdmin' \{ \`$r = Invoke-RepairWindowsAdmin") '-Action RepairWindows is accepted, and the permission part has its own action'
Assert ($script:BackgroundActions -contains 'RepairWindowsAdmin') 'the permission part is a helper action, not a button'
$plain = (($a.Plan.Does + $a.Plan.Heads + @($a.Plan.Restart, $help['RepairWindows'].Text, $t[1], $t[2])) -join ' ')
Assert ($plain -notmatch '(?i)\b(DISM|sfc|scannow|RestoreHealth|CBS|component store|PowerShell|script|admin|administrator)\b') 'no technical words in what the person reads'
$fnText = (Get-Fn 'Invoke-RepairWindowsAdmin') + (Get-Fn 'Invoke-RepairWindowsFix')
$shown = (([regex]::Matches($fnText, "New-FixItResult \S+ '[^']*' '([^']*)'") | ForEach-Object { $_.Groups[1].Value }) + ([regex]::Matches($fnText, "Write-Host '([^']*)'") | ForEach-Object { $_.Groups[1].Value })) -join ' '
Assert ($shown.Length -gt 200 -and $shown -notmatch '(?i)\b(DISM|sfc|scannow|RestoreHealth|CBS)\b') 'the messages and the progress window do not name the tools either'

Section 'Repair Windows: what the second step found'
$s0 = [datetime]'2026-11-05 19:00:00'
$old = '2026-11-05 18:00:00, Info CSI 00000001 [SR] Cannot repair member file [l:10]"old.dll"'
Assert ((Get-FixItSfcOutcome -Lines @($old, '2026-11-05 19:10:00, Info CSI 00000002 [SR] Verify complete', '2026-11-05 19:10:01, Info CSI 00000003 [SR] Repairing 0 components') -Since $s0) -eq 'Clean') 'nothing damaged (an older problem from before this run is ignored)'
Assert ((Get-FixItSfcOutcome -Lines @('2026-11-05 19:10:00, Info CSI 00000002 [SR] Repairing corrupted file \??\C:\Windows\x.dll', '2026-11-05 19:10:01, Info CSI 00000003 [SR] Repairing 1 components') -Since $s0) -eq 'Repaired') 'damaged files repaired'
Assert ((Get-FixItSfcOutcome -Lines @('2026-11-05 19:10:00, Info CSI 00000002 [SR] Cannot repair member file [l:10]"x.dll"') -Since $s0) -eq 'NotAll') 'some files could not be repaired'
Assert ((Get-FixItSfcOutcome -Lines @() -Since $s0) -eq 'Unknown') 'no log: unknown (not a false "all fine")'

Section 'Repair Windows: running it'
$script:Calls = New-Object System.Collections.ArrayList
$script:ToolFail = @{}; $script:Cbs = @(); $script:Answer = $false; $script:Restarted = 0
function Test-FixItAdmin { return $true }
function Invoke-FixItTool { param([string]$File, [string[]]$Arguments = @(), [int[]]$OkCodes = @(0), [switch]$Live) [void]$script:Calls.Add(($File + ' ' + ($Arguments -join ' '))); if ($script:ToolFail[$File]) { throw ('{0} ended with code 87' -f $File) } }
function Get-FixItCbsLogLines { return $script:Cbs }
function Confirm-FixItStep { param([string]$Question) return $script:Answer }
function Restart-FixItComputer { $script:Restarted++ }
function Write-Host { }
$now = (Get-Date).AddMinutes(5).ToString('yyyy-MM-dd HH:mm:ss')
$script:TestMode = $false; $script:DryRun = $false
$r = Invoke-RepairWindowsFix
Assert ($script:Calls.Count -eq 2 -and $script:Calls[0] -eq 'dism.exe /Online /Cleanup-Image /RestoreHealth' -and $script:Calls[1] -eq 'sfc.exe /scannow') 'the two steps run in order, the same as by hand'
Assert ($r.Ok -and $r.Title -eq 'Repair finished' -and $r.Message -match 'restart' -and $r.Message -match 'updates') 'when the result cannot be read, it still says to restart and check for updates'
$script:Calls.Clear(); $script:Cbs = @(($now + ', Info CSI 1 [SR] Repairing corrupted file x')); $script:Answer = $false
$r = Invoke-RepairWindowsFix
Assert ($r.Ok -and $r.Title -eq 'Windows repaired' -and $r.Message -match 'restart your computer, then check for Windows updates' -and $script:Restarted -eq 0) 'files repaired: says restart, then check for updates; no restart without a yes'
$script:Answer = $true
$r = Invoke-RepairWindowsFix
Assert ($script:Restarted -eq 1 -and $r.Title -eq 'Restarting' -and $r.Message -match 'Check for updates') 'with a yes it restarts and says to check for updates after'
$script:Answer = $false; $script:Cbs = @(($now + ', Info CSI 1 [SR] Cannot repair member file x'))
$r = Invoke-RepairWindowsFix
Assert (-not $r.Ok -and $r.Title -eq 'Some files not repaired' -and $r.Message -match 'could not be repaired' -and $r.Message -match 'report') 'some files not repaired: said clearly, and a report is suggested'
$script:Cbs = @(($now + ', Info CSI 1 [SR] Verify complete'))
$r = Invoke-RepairWindowsFix
Assert ($r.Ok -and $r.Title -eq 'Windows is OK') 'nothing damaged: Windows is OK'
$script:Calls.Clear(); $script:ToolFail = @{ 'dism.exe' = $true }; Clear-Log
$r = Invoke-RepairWindowsFix
Assert (-not $r.Ok -and $script:Calls.Count -eq 1 -and $r.Title -eq 'Repair stopped' -and $r.Message -match 'stopped before the second part' -and $r.Message -match 'internet') 'step 1 fails: step 2 is not started, and it says why in plain words'
$lg = Get-Log
Assert ($lg -match 'Started: Repair Windows' -and $lg -match 'FAILED: Repair Windows step 1 of 2 \(DISM' -and $lg -match 'step 2 was not started') 'every step is logged (with the tool names, for the helper)'
$script:Calls.Clear(); $script:ToolFail = @{ 'sfc.exe' = $true }
$r = Invoke-RepairWindowsFix
Assert (-not $r.Ok -and $script:Calls.Count -eq 2 -and $r.Title -eq 'Repair did not finish' -and $r.Message -match 'report') 'step 2 fails: said plainly, a report is suggested'
$script:ToolFail = @{}; $script:Calls.Clear()
$r1 = Invoke-RepairWindowsFix; $r2 = Invoke-RepairWindowsFix
Assert ($r1.Title -eq $r2.Title -and $script:Calls.Count -eq 4) 'running it again is fine (same steps, same answer)'

Section 'Repair Windows: practice run and Test mode run nothing'
$script:Calls.Clear(); $script:DryRun = $true; Clear-Log
$r = Invoke-RepairWindowsFix
Assert ($r.Ok -and $r.Title -eq 'Practice run' -and $script:Calls.Count -eq 0 -and (Get-Log) -match 'Would do: Repair Windows step 1' -and (Get-Log) -match 'Would do: Repair Windows step 2') 'a practice run only says what it would do'
$script:DryRun = $false
Remove-Item Function:\Invoke-FixItTool
function Invoke-FixItProbe { param([string]$Adapter, $Arguments) [void]$script:Calls.Add('probe ' + $Adapter + ' ' + [string]$Arguments['File']); return @() }
$script:Calls.Clear(); $script:TestMode = $true; $script:DryRun = $true; Clear-Log
$r = $null; $err = ''
try { $r = Invoke-RepairWindowsFix } catch { $err = $_.Exception.Message }
$script:TestMode = $false; $script:DryRun = $false
Assert (-not $err -and $null -ne $r) ('Test mode runs through without an error ' + $err)
Assert (@($script:Calls | Where-Object { $_ -notmatch '^probe ' }).Count -eq 0 -and (Get-Log) -match 'TEST MODE: Repair Windows would ask for permission') 'Test mode only checks; nothing is run, and it says what would happen'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Microsoft.PowerShell.Utility\Write-Host ''
Microsoft.PowerShell.Utility\Write-Host ('Passed: {0}   Failed: {1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
