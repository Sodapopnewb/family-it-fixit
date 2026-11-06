# Version 2.3.16 tests, from a fresh install where "Who helps you?" never showed:
#  (1) the settings file: one writer at a time, written whole then swapped in, and an unreadable file is never written over;
#  (2) the first normal window asks "Who helps you?" whenever it was never answered, even if the installer's note was lost.
# Usage:  pwsh ./tests/Test-FixIt-V2316.ps1       (Test-FixIt.ps1 runs this one too and adds its numbers)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fixit-v2316-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:Pass = 0; $script:Fail = 0
function Assert { param([bool]$Cond, [string]$Name) if ($Cond) { $script:Pass++ } else { $script:Fail++; Write-Host ('  FAIL: ' + $Name) -ForegroundColor Red } }
function Section { param([string]$T) Write-Host ('== ' + $T) }
$src = Join-Path $root 'FamilyFixIt.ps1'
$outDir = Join-Path $tmp 'out'; New-Item -ItemType Directory -Path $outDir | Out-Null
$env:LOCALAPPDATA = Join-Path $tmp 'local'; New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
$env:COMPUTERNAME = 'TESTPC'
$tLogFile = Join-Path $tmp 'v2316.log'
. $src -LibraryOnly -LogPath $tLogFile -OutputDir $outDir
Initialize-FixItLog
function Get-Log { if (Test-Path -LiteralPath $tLogFile) { return [IO.File]::ReadAllText($tLogFile) }; return '' }
function Reset-State { $f = Get-FixItStateFile; foreach ($x in @($f, ($f + '.new'), ($f + '.unreadable'))) { if (Test-Path -LiteralPath $x) { Remove-Item -LiteralPath $x -Force } } }
$srcText = [IO.File]::ReadAllText($src)
$bytes = [IO.File]::ReadAllBytes($src)
$tokens = $null; $perr = $null
[void][Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$perr)
Assert ([version]$script:FixItVersion -ge [version]'2.3.16') 'the program is version 2.3.16 or newer'
Assert ($perr.Count -eq 0) 'the program parses with no errors'
Assert (-not ($srcText -match '[^\x00-\x7F]') -and -not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF) -and $srcText -notmatch "`r") 'the program file is plain ASCII, no BOM, LF line ends'

Section 'Settings file: saving'
Reset-State; $f = Get-FixItStateFile
Set-FixItStateValue -Name 'A' -Value '1'; Set-FixItStateValue -Name 'B' -Value '2'; Set-FixItStateValue -Name 'A' -Value '3'
Assert ((Get-FixItSetting -Name 'A') -eq '3' -and (Get-FixItSetting -Name 'B') -eq '2') 'values are kept and updated'
Assert (-not (Test-Path -LiteralPath ($f + '.new'))) 'no temporary file is left behind'
$script:TestMode = $true; Set-FixItStateValue -Name 'A' -Value '9'; $script:TestMode = $false
Assert ((Get-FixItSetting -Name 'A') -eq '3') 'Test mode saves nothing'

Section 'Settings file: a file that cannot be read is never written over'
Reset-State; [IO.File]::WriteAllText($f, '{"PrivacyPending":"1","Helper')
Set-FixItStateValue -Name 'Guardian' -Value '1'
Assert ([IO.File]::ReadAllText($f) -eq '{"PrivacyPending":"1","Helper') 'the half-written file is left as it was (not wiped)'
Assert ((Test-Path -LiteralPath ($f + '.unreadable')) -and (Get-Log) -match 'could not be read, so it was not changed') 'a copy is kept and it is logged'
Reset-State; [IO.File]::WriteAllText($f, '')
Set-FixItStateValue -Name 'X' -Value '1'
Assert ([IO.File]::ReadAllText($f) -eq '') 'an empty file (caught mid-write) is not written over either'

Section 'Settings file: two programs saving at the same time'
Reset-State; Set-FixItStateValue -Name 'PrivacyPending' -Value '1'
$jobs = foreach ($w in 1..3) {
    Start-Job -ScriptBlock { param($src, $la, $w, $log)
        $env:LOCALAPPDATA = $la; . $src -LibraryOnly -LogPath $log -OutputDir $la
        for ($i = 0; $i -lt 40; $i++) { Set-FixItStateValue -Name ('W{0}' -f $w) -Value ([string]$i) }
    } -ArgumentList $src, $env:LOCALAPPDATA, $w, (Join-Path $tmp ('job' + $w + '.log'))
}
[void]($jobs | Wait-Job -Timeout 120); $jobs | Remove-Job -Force
Assert ((Get-FixItSetting -Name 'PrivacyPending') -eq '1') 'the fresh-install note survives other programs saving at the same time'
Assert ((Get-FixItSetting -Name 'W1') -eq '39' -and (Get-FixItSetting -Name 'W2') -eq '39' -and (Get-FixItSetting -Name 'W3') -eq '39') 'every program''s last save is kept'

Section 'First run: the helper question is never skipped'
$p = Get-FixItFirstRunPlan -Pending '' -PrivacyShown '' -NameAsked '' -Interactive $true -HelperAsked ''
Assert ($p.AskHelper -and -not $p.ShowPrivacy -and -not $p.AskName) 'note lost, never answered: only "Who helps you?" is asked'
$p = Get-FixItFirstRunPlan -Pending '' -Interactive $false -HelperAsked ''
Assert (-not $p.AskHelper) 'a silent start or practice run asks nothing'
$p = Get-FixItFirstRunPlan -Pending '' -Interactive $true -HelperAsked '2026-11-05'
Assert (-not $p.AskHelper) 'once answered it is not asked again'
$script:Drawn = New-Object System.Collections.ArrayList
function Show-FixItFirstRunWindows { param([bool]$ShowPrivacy, [bool]$AskName, [bool]$AskHelper = $false) [void]$script:Drawn.Add(('privacy={0} name={1} helper={2}' -f $ShowPrivacy, $AskName, $AskHelper)); if ($AskHelper) { Set-FixItSetting -Name 'HelperAsked' -Value '2026-11-05' } }
Reset-State; $script:GuiActive = $true; $script:AssumeYes = $false; $script:DryRun = $false
$shown = Invoke-FixItFirstRun
Assert ($shown -and $script:Drawn.Count -eq 1 -and $script:Drawn[0] -eq 'privacy=False name=False helper=True') 'first normal window with the note lost asks the helper question'
Assert ((Get-Log) -match 'First run: showing the helper question \(the helper question was never answered\)') 'and logs why'
$shown = Invoke-FixItFirstRun
Assert (-not $shown -and $script:Drawn.Count -eq 1) 'the next start asks nothing'
Reset-State; $script:Drawn.Clear(); $script:DryRun = $true
$shown = Invoke-FixItFirstRun; $script:DryRun = $false
Assert (-not $shown -and $script:Drawn.Count -eq 0) 'a practice run shows nothing'
Reset-State; $script:Drawn.Clear(); $script:TestMode = $true
$shown = Invoke-FixItFirstRun; $script:TestMode = $false
Assert (-not $shown -and $script:Drawn.Count -eq 0) 'Test mode shows nothing'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('Passed: {0}   Failed: {1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
