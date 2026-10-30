# Version 2.3.15 tests, from the first real-PC "Test all buttons" run:
#  (1) Test mode: a 'Family Fix-It Reports' folder that is not made yet is fine when Documents exists and can be written to;
#  (2) the Chrome check reads the search setting safely (it is missing when the search was never changed);
#  (3) the display message: sudden stops are said calmly and apart from hardware errors, and the helper is named only when it matters;
#  (4) the display check asks only about the graphics makers this PC has, and a log source that is not there is not logged every run.
# Windows-only parts use pretend adapters here; the REAL program functions run.
# Usage:  pwsh ./tests/Test-FixIt-V2315.ps1       (Test-FixIt.ps1 runs this one too and adds its numbers)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fixit-v2315-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:Pass = 0; $script:Fail = 0
function Assert { param([bool]$Cond, [string]$Name) if ($Cond) { $script:Pass++ } else { $script:Fail++; Write-Host ('  FAIL: ' + $Name) -ForegroundColor Red } }
function Section { param([string]$T) Write-Host ('== ' + $T) }

$src = Join-Path $root 'FamilyFixIt.ps1'
$outDir = Join-Path $tmp 'out'; New-Item -ItemType Directory -Path $outDir | Out-Null
$env:LOCALAPPDATA = Join-Path $tmp 'local'; New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
$env:COMPUTERNAME = 'TESTPC'
$tLogFile = Join-Path $tmp 'v2315.log'
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
function Reset-State { $f = Get-FixItStateFile; if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }; $script:LastDelivery = $null; $script:HelperChanged = $false }

Assert ([version]$script:FixItVersion -ge [version]'2.3.15') 'the program is version 2.3.15 or newer'
Assert ($perr.Count -eq 0) 'the program parses with no errors'
Assert (-not ($srcText -match '[^\x00-\x7F]') -and -not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) -and $srcText -notmatch "`r") 'the program file is plain ASCII, with no BOM and LF line ends'

# ================================================================ 1. Test mode and the reports folder
Section 'Test mode: the Family Fix-It Reports folder does not exist yet'
$docs = Join-Path $tmp 'Documents'; New-Item -ItemType Directory -Path $docs | Out-Null
$reports = Join-Path $docs $script:ReportsFolderName
$file = Join-Path $reports 'Report-for-Trey-TESTPC-20261030-1600.txt'
function Get-TestSaveRecord {
    param([string]$Path)
    $script:TestMode = $true
    try {
        Start-FixItTestButton
        $ok = Invoke-FixItStep ('Save report to {0}' -f $Path) { Write-FixItTextFile -Path $Path -Text 'a report' }
        $recs = @(Get-FixItTestRecords)
        return [pscustomobject]@{ Ok = $ok; Rec = @($recs)[0]; Count = $recs.Count }
    } finally { $script:TestMode = $false }
}
$r = Get-TestSaveRecord -Path $file
$chk = (@($r.Rec.Checks) | ForEach-Object { [string]$_.Text }) -join ' | '
Assert ($r.Count -eq 1 -and $r.Rec.Status -eq 'PASS') 'Documents exists and is writable, the reports folder is not made yet: PASS'
Assert ($chk -match 'would create it' -and $chk -match [regex]::Escape($script:ReportsFolderName)) 'the check says the real run would create the folder'
Assert (-not (Test-Path -LiteralPath $reports) -and -not (Test-Path -LiteralPath $file)) 'Test mode still created nothing (no folder, no file)'
New-Item -ItemType Directory -Path $reports | Out-Null
$r = Get-TestSaveRecord -Path $file
Assert ($r.Rec.Status -eq 'PASS' -and ((@($r.Rec.Checks) | ForEach-Object { [string]$_.Text }) -join ' ') -match 'the folder exists') 'the folder is already there: PASS, "the folder exists"'
Remove-Item -LiteralPath $reports -Force
$r = Get-TestSaveRecord -Path (Join-Path (Join-Path $tmp 'NoDocuments') (Join-Path $script:ReportsFolderName 'x.txt'))
Assert ($r.Rec.Status -eq 'FAIL' -and ((@($r.Rec.Checks) | ForEach-Object { [string]$_.Text }) -join ' ') -match 'was not found') 'Documents itself is missing: FAIL'
$r = Get-TestSaveRecord -Path (Join-Path (Join-Path $docs 'Some other folder') 'x.txt')
Assert ($r.Rec.Status -eq 'FAIL') 'any other missing folder is still a FAIL (only the reports folder is made by a real run)'
function Test-FixItFolderWritable { param([string]$Path) return $false }
$r = Get-TestSaveRecord -Path $file
Assert ($r.Rec.Status -eq 'FAIL' -and ((@($r.Rec.Checks) | ForEach-Object { [string]$_.Text }) -join ' ') -match 'cannot be written to') 'Documents cannot be written to: FAIL, and it says why'
. $src -LibraryOnly -LogPath $tLogFile -OutputDir $outDir
Initialize-FixItLog

# the whole Save-FixItReportFile step, the way the report buttons run it
function Get-FixItDocumentsFolder { return $docs }
$OutputDir = ''
$script:TestMode = $true; Start-FixItTestButton
$sv = Save-FixItReportFile -Text 'x' -Prefix 'Report-for-Trey'
$script:TestMode = $false
$recs = @(Get-FixItTestRecords)
Assert ($sv.Ok -and $recs.Count -eq 1 -and $recs[0].Status -eq 'PASS' -and -not (Test-Path -LiteralPath $reports)) 'Save-FixItReportFile in Test mode: PASS and nothing created'
$script:TestMode = $false
$sv2 = Save-FixItReportFile -Text 'x' -Prefix 'Report-for-Trey'
Assert ($sv2.Ok -and (Test-Path -LiteralPath $sv2.Path) -and (Split-Path -Parent $sv2.Path) -eq $reports) 'a real run still makes the folder and saves the file there'
Remove-Item -LiteralPath $reports -Recurse -Force
. $src -LibraryOnly -LogPath $tLogFile -OutputDir $outDir
Initialize-FixItLog

# ================================================================ 2. Chrome search setting
Section 'Browser check: the search setting may be missing'
function New-Prefs { param([string]$Json) $d = Join-Path $tmp ('prof-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $d | Out-Null; [IO.File]::WriteAllText((Join-Path $d 'Preferences'), $Json); return $d }
$threw = $false; $s = $null
try { $s = Get-FixItBrowserSettings -Dir (New-Prefs '{"homepage":"https://start.example/"}') } catch { $threw = $true }
Assert (-not $threw -and $s.Homepage -eq 'https://start.example/' -and $s.SearchName -eq '' -and $s.SearchUrl -eq '') 'no search section at all: no error, search not changed'
$threw = $false
try { $s = Get-FixItBrowserSettings -Dir (New-Prefs '{"default_search_provider_data":{"something_else":1}}') } catch { $threw = $true }
Assert (-not $threw -and $s.SearchName -eq '' -and $s.SearchUrl -eq '') 'a search section without template_url_data (Chrome Default, unchanged search): no error, search not changed'
$threw = $false
try { $s = Get-FixItBrowserSettings -Dir (New-Prefs '{"default_search_provider_data":{"template_url_data":{"short_name":"Odd Search","url":"https://odd.example/?q={searchTerms}"}}}') } catch { $threw = $true }
Assert (-not $threw -and $s.SearchName -eq 'Odd Search' -and $s.SearchUrl -match 'odd\.example') 'a changed search is still read'
$threw = $false
try { $s = Get-FixItBrowserSettings -Dir (New-Prefs '{"default_search_provider_data":{"template_url_data":{"short_name":"Only A Name"}}}') } catch { $threw = $true }
Assert (-not $threw -and $s.SearchName -eq 'Only A Name' -and $s.SearchUrl -eq '') 'a search with a name but no address: no error'
$threw = $false
try { $s = Get-FixItBrowserSettings -Dir (New-Prefs '{"default_search_provider_data":{"template_url_data":null},"session":{},"profile":{"content_settings":{}}}') } catch { $threw = $true }
Assert (-not $threw -and $s.SearchName -eq '' -and @($s.StartupUrls).Count -eq 0 -and @($s.NotificationSites).Count -eq 0) 'empty or null pieces: no error'
$threw = $false
try { $s = Get-FixItBrowserSettings -Dir (New-Prefs '{}') } catch { $threw = $true }
Assert (-not $threw -and $s.Homepage -eq '') 'an empty Preferences file: no error'

# ================================================================ 3. the display message
Section 'Display message: sudden stops and hardware errors'
function New-Facts { param($Resets = 0, $Plug = 0, $Power = 0, $Whea = 0, $Live = 0) [pscustomobject]@{ Cards = @([pscustomobject]@{ Name = 'NVIDIA'; ErrorCode = 0; DriverVersion = '1.0'; DriverDate = [datetime]'2025-03-12' }); ScreenCount = 1; Connections = @('HDMI'); Current = $null; Recommended = $null; Resets = $Resets; PlugEvents = $Plug; PowerLoss = $Power; Whea = $Whea; LiveKernel = $Live; Notes = @() } }
Reset-State
$v = Get-FixItDisplayVerdict -Facts (New-Facts)
Assert ($v.Extra -eq '') 'nothing found: no extra line'
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Power 2)
Assert ($v.Extra -eq 'Your computer turned off without shutting down 2 times this week. This often happens when power is lost.') '2 sudden stops: the plain, calm sentence'
Assert ($v.Extra -notmatch '(?i)call|hardware|error|stopped suddenly|Windows') 'it does not tell them to call anyone and does not sound alarming'
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Power 1)
Assert ($v.Extra -match 'without shutting down once this week' -and $v.Extra -notmatch '(?i)call') 'one sudden stop is said as "once"'
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Power 4)
Assert ($v.Extra -match '4 times' -and $v.Extra -notmatch '(?i)call') '4 sudden stops: still no call'
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Power 5)
Assert ($v.Extra -match '5 times' -and $v.Extra -match 'often happens when power is lost' -and $v.Extra -match 'please call Trey\.$') '5 sudden stops (frequent): the helper is suggested'
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Whea 1)
Assert ($v.Extra -match 'reported 1 hardware error this week' -and $v.Extra -match 'please call Trey' -and $v.Extra -notmatch 'turned off') 'a hardware error (WHEA): said on its own, the helper is suggested'
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Live 2)
Assert ($v.Extra -match 'reported 2 hardware errors this week' -and $v.Extra -match 'please call Trey') 'graphics hardware errors (LiveKernelEvent): the helper is suggested'
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Power 2 -Whea 1)
Assert ($v.Extra -match 'turned off without shutting down 2 times' -and $v.Extra -match 'hardware error' -and ([regex]::Matches($v.Extra, 'please call').Count -eq 1)) 'both: two separate statements and one suggestion to call'
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Resets 1)
Assert ($v.Kind -eq 'driver' -and $v.Extra -eq '') 'only a graphics driver crash: the main verdict says it (and the helper); no extra line'
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Resets 2 -Power 1)
Assert ($v.Extra -match 'once' -and $v.Extra -match 'please call Trey') 'a graphics driver crash (4101) with a sudden stop: the helper is suggested'
$v = Get-FixItDisplayVerdict -Facts ([pscustomobject]@{ Cards = @([pscustomobject]@{ Name = 'NVIDIA'; ErrorCode = 0; DriverVersion = '1.0'; DriverDate = $null }); ScreenCount = 1; Connections = @(); Current = $null; Recommended = $null; Resets = 0; PlugEvents = 0; PowerLoss = $null; Whea = $null; LiveKernel = $null; Notes = @() })
Assert ($v.Extra -eq '') 'counts that could not be read (not available): no extra line'
$fn = Get-Fn 'Get-FixItDisplayVerdict'
Assert ($fn -notmatch "call Trey\.'" -and $fn -match 'Get-FixItHelperName') 'the program text does not hard-code "call Trey" for the extra line; it uses the helper name'

Section 'Display message: with another helper'
[void](Save-FixItHelper -Other $true -Name 'Mike' -Email $mikeMail)
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Whea 3)
Assert ($v.Extra -match 'please call Mike\.' -and $v.Extra -notmatch 'Trey') 'a hardware error names the chosen helper, not Trey'
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Power 7)
Assert ($v.Extra -match 'please call Mike\.' -and $v.Extra -notmatch 'Trey') 'frequent sudden stops name the chosen helper'
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Power 2)
Assert ($v.Extra -notmatch 'Mike|Trey') 'a couple of sudden stops name nobody'
$v = Get-FixItDisplayVerdict -Facts (New-Facts -Resets 5)
Assert ($v.Suggestion -match 'ask Mike' -and $v.Suggestion -notmatch 'Trey') 'the driver advice in the report lines names the chosen helper too'
$v = Get-FixItDisplayVerdict -Facts $null
Assert ($v.Suggestion -match 'Send Mike a report' -and $v.Suggestion -notmatch 'Trey|\bhe\b') 'the "cannot see enough" advice names the chosen helper'
$rl = (Get-FixItDisplayLines -Facts (New-Facts -Resets 5 -Whea 1) -Verdict (Get-FixItDisplayVerdict -Facts (New-Facts -Resets 5 -Whea 1))) -join "`n"
Assert ($rl -notmatch 'Trey' -and $rl -match 'call Mike') 'the report lines name only the chosen helper'
Assert ($rl -match 'Computer turned off without shutting down, last 7 days: 0' -and $rl -notmatch 'stopped suddenly') 'the count line is in plain words'
$script:TestMode = $false; $script:DryRun = $false
function Get-FixItDisplayFacts { return (New-Facts -Whea 1 -Power 2) }
function Send-FixItDisplayReset { }
Start-FixItUndoRecord -Fix 'Display' -Title 'Fix my display'
$res = Invoke-DisplayFix
Assert ((($res.Details -join "`n") + $res.Message) -notmatch 'Trey' -and ($res.Details -join "`n") -match 'call Mike') 'the finished window names only the chosen helper'
. $src -LibraryOnly -LogPath $tLogFile -OutputDir $outDir
Initialize-FixItLog

Section 'Other places that named Trey when the helper is someone else'
Reset-State; [void](Save-FixItHelper -Other $true -Name 'Mike' -Email $mikeMail)
$script:GuiActive = $false; $script:TestAll = $false; $script:Prompt = ''
function Test-FixItCanAsk { return $true }
function Read-Host { param($Prompt) $script:Prompt = [string]$Prompt; return 'y' }
[void](Confirm-FixIt -Question 'Did that fix it?' -Kind 'Fixed' -Detail 'I restarted printing.')
Assert ($script:Prompt -match 'send Mike a report' -and $script:Prompt -notmatch 'Trey') 'the command-line question ("If it is still broken...") names the chosen helper (it used to add Trey after the swap)'
Remove-Item Function:\Test-FixItCanAsk, Function:\Read-Host -ErrorAction SilentlyContinue
$item = [pscustomobject]@{ Time = [datetime]'2026-10-30T10:00:00'; Answer = 'no'; Ok = $true; Title = 'Fix my printer' }
Assert ((Format-FixItHistoryLine -Item $item) -match 'a report went to Trey$') 'history: before the helper has said yes, the report really went to Trey, and it says so'
Set-FixItSetting -Name 'HelperStatus' -Value 'confirmed'
Assert ((Format-FixItHistoryLine -Item $item) -match 'a report went to Mike$' -and (Format-FixItHistoryLine -Item $item) -notmatch 'Trey') 'history: once the helper has said yes, it names the helper'
Reset-State
Assert ((Format-FixItHistoryLine -Item $item) -match 'a report went to Trey$') 'history: with Trey as the helper nothing changes'
Reset-State

# ================================================================ 4. the display log
Section 'Display check: only the graphics makers this PC has; quiet when a log source is missing'
Assert ((@(Get-FixItDisplayVendorProviders -Cards @([pscustomobject]@{ Name = 'NVIDIA GeForce GTX 1650' })) -join ',') -eq 'nvlddmkm') 'an NVIDIA card: only nvlddmkm'
Assert ((@(Get-FixItDisplayVendorProviders -Cards @([pscustomobject]@{ Name = 'AMD Radeon(TM) Graphics' })) -join ',') -eq 'amdkmdag') 'an AMD card: only amdkmdag'
Assert ((@(Get-FixItDisplayVendorProviders -Cards @([pscustomobject]@{ Name = 'Intel(R) UHD Graphics 630' })) -join ',') -eq 'igfx') 'an Intel card: only igfx'
Assert (((@(Get-FixItDisplayVendorProviders -Cards @([pscustomobject]@{ Name = 'Intel(R) UHD Graphics 630' }, [pscustomobject]@{ Name = 'NVIDIA GeForce RTX 3060' })) | Sort-Object) -join ',') -eq 'igfx,nvlddmkm') 'Intel and NVIDIA: those two'
Assert (@(Get-FixItDisplayVendorProviders -Cards @([pscustomobject]@{ Name = 'Microsoft Basic Display Adapter' })).Count -eq 0) 'only the basic Windows driver: no maker to ask about'
Assert (((@(Get-FixItDisplayVendorProviders -Cards @()) | Sort-Object) -join ',') -eq 'amdkmdag,igfx,nvlddmkm') 'no card information: all three are asked (quietly)'

$script:CalledProviders = New-Object System.Collections.ArrayList
$script:WinMode = 'noprovider'
function Get-WinEvent {
    param($FilterHashtable, $MaxEvents, $ErrorAction)
    [void]$script:CalledProviders.Add([string]$FilterHashtable['ProviderName'])
    if ($script:WinMode -eq 'noprovider') {
        $er = New-Object Management.Automation.ErrorRecord((New-Object Exception ('There is not an event provider on the localhost computer that matches "{0}".' -f $FilterHashtable['ProviderName'])), 'NoMatchingProvidersFound,Microsoft.PowerShell.Commands.GetWinEventCommand', [Management.Automation.ErrorCategory]::ObjectNotFound, $null)
        throw $er
    }
    if ($script:WinMode -eq 'noevents') { throw (New-Object Management.Automation.ErrorRecord((New-Object Exception 'No events were found that match the specified selection criteria.'), 'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand', [Management.Automation.ErrorCategory]::ObjectNotFound, $null)) }
    if ($script:WinMode -eq 'broken') { throw (New-Object Exception 'The RPC server is unavailable') }
    return @()
}
Assert (Test-FixItNoProvider -Err (New-Object Management.Automation.ErrorRecord((New-Object Exception 'x'), 'NoMatchingProvidersFound,Cmd', [Management.Automation.ErrorCategory]::ObjectNotFound, $null))) 'a "no such log source" error is recognised by its id'
$e2 = $null; try { throw 'There is not an event provider on the localhost computer that matches "igfx".' } catch { $e2 = $_ }
Assert (Test-FixItNoProvider -Err $e2) 'and by its words'
$e3 = $null; try { throw 'The RPC server is unavailable' } catch { $e3 = $_ }
Assert (-not (Test-FixItNoProvider -Err $e3) -and -not (Test-FixItNoEvents -Err $e3)) 'a real failure is not mistaken for a missing log source'
Clear-Log
$c = Get-FixItHwEventCount -Provider 'nvlddmkm' -Days 7
Assert ($c -eq 0) 'a log source that is not on this PC counts as 0 entries'
$c = Get-FixItHwEventCount -Provider 'nvlddmkm' -Days 7; $c = Get-FixItHwEventCount -Provider 'nvlddmkm' -Days 7
Assert (([regex]::Matches((Get-Log), 'nvlddmkm is not on this PC')).Count -eq 1) 'it is noted once in the log, not every time'
Assert ((Get-Log) -match '\[DEBUG\] Windows log source nvlddmkm' -and (Get-Log) -notmatch '\[INFO\].*nvlddmkm') 'and only at the quiet DEBUG level, never as an INFO line'

$script:Cim = @{}
function Get-CimInstance { param($ClassName, $Namespace, $Filter, $ErrorAction)
    if ($ClassName -eq 'Win32_VideoController') { return @([pscustomobject]@{ Name = 'Intel(R) UHD Graphics 630'; Status = 'OK'; ConfigManagerErrorCode = 0; DriverVersion = '31.0'; DriverDate = '20250312000000.000000-000'; CurrentHorizontalResolution = 1920; CurrentVerticalResolution = 1080; CurrentRefreshRate = 60 }) }
    throw 'not supported'
}
$script:TestMode = $false; $script:GuiActive = $false
$script:CalledProviders.Clear(); $script:WinMode = 'noprovider'; Clear-Log; $script:ProvidersMissingLogged = @{}
$f = Get-FixItDisplayFacts
$called = ($script:CalledProviders | Select-Object -Unique) -join ','
Assert ($called -match 'igfx' -and $called -notmatch 'nvlddmkm|amdkmdag') 'the display check asks only about igfx on an Intel-only PC'
Assert ($f.Resets -eq 0 -and $f.PowerLoss -eq 0 -and $f.PlugEvents -eq 0) 'sources that are not there count as zero, so the facts are still complete'
Assert ((Get-Log) -notmatch 'could not count') 'no "could not count ... events" line in the log'
$script:WinMode = 'broken'; Clear-Log; $script:ProvidersMissingLogged = @{}
$f = Get-FixItDisplayFacts
Assert ((Get-Log) -match 'Display: could not count Display events' -and (Get-Log) -match 'could not count Microsoft-Windows-Kernel-Power events' -and (Get-Log) -notmatch 'could not count igfx' -and (Get-Log) -notmatch 'could not count Microsoft-Windows-DeviceSetupManager') 'a real failure is still logged for the sources that matter, but not for the optional ones (igfx, DeviceSetupManager)'
Assert ($null -eq $f.PowerLoss -and $null -eq $f.PlugEvents -or $null -ne $f.PlugEvents) 'a count that cannot be read is still "not available"'
$script:WinMode = 'noevents'; $f = Get-FixItDisplayFacts
Assert ($f.Resets -eq 0 -and $f.PowerLoss -eq 0) 'no entries found is still 0'
Remove-Item Function:\Get-WinEvent, Function:\Get-CimInstance -ErrorAction SilentlyContinue

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('Passed: {0}   Failed: {1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
