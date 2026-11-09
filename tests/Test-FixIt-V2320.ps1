# Version 2.3.20: the first-run "Who helps you?" window paints its buttons before the shared fonts exist.
# The Save and Skip buttons are tiles. Their paint reads $script:UiFonts, which Show-FixItWindowOnce
# creates only after the first-run dialogs have already been shown. Strict mode then throws
# "The variable '$script:UiFonts' cannot be retrieved because it has not been set."
# Usage:  pwsh ./tests/Test-FixIt-V2320.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fixit-v2320-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:Pass = 0; $script:Fail = 0
function Assert { param([bool]$Cond, [string]$Name) if ($Cond) { $script:Pass++ } else { $script:Fail++; Microsoft.PowerShell.Utility\Write-Host ('  FAIL: ' + $Name) -ForegroundColor Red } }
function Section { param([string]$T) Microsoft.PowerShell.Utility\Write-Host ('== ' + $T) }

$srcPath = Join-Path $root 'FamilyFixIt.ps1'
$env:LOCALAPPDATA = Join-Path $tmp 'local'
New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
. $srcPath -LibraryOnly -LogPath (Join-Path $tmp 'fixit.log') -OutputDir (Join-Path $tmp 'out')
Initialize-FixItLog

$perr = $null; $tok = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($srcPath, [ref]$tok, [ref]$perr)
function Get-FnText { param([string]$Name) $f = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1; if ($null -eq $f) { return '' }; return $f.Extent.Text }
Assert ($perr.Count -eq 0) 'the program parses'
Assert ([version]$script:FixItVersion -ge [version]'2.3.20') 'the program is version 2.3.20 or newer'

Section 'The unset font table is exactly the error on the screenshot'
if (Get-Variable -Name UiFonts -Scope Script -ErrorAction SilentlyContinue) { Remove-Variable -Name UiFonts -Scope Script }
$thrown = ''
try { $null = $script:UiFonts.Big } catch { $thrown = $_.Exception.Message }
Assert ($thrown -eq "The variable '`$script:UiFonts' cannot be retrieved because it has not been set.") ('unset fonts throw the screenshot error, got: ' + $thrown)

Section 'First-run dialogs are reached only after the shared fonts are created'
$main = Get-FnText 'Show-FixItWindowMain'
$once = Get-FnText 'Show-FixItWindowOnce'
$init = Get-FnText 'Initialize-FixItUiFonts'
$iCap = $once.IndexOf('Get-FixItMainScaleCap')
$iFontsInOnce = $once.IndexOf('Initialize-FixItUiFonts')
$iFontsInMain = $main.IndexOf('Initialize-FixItUiFonts')
$iFirst = $main.IndexOf('Invoke-FixItFirstRun')
$iOnce = $main.IndexOf('Show-FixItWindowOnce')
Assert ($init.Length -gt 0 -and $init -match 'Title' -and $init -match 'Big' -and $init -match 'SideSmall') 'one function builds the whole shared font table'
Assert ($iFontsInMain -ge 0 -and $iFirst -gt $iFontsInMain -and $iOnce -gt $iFirst) 'Show-FixItWindowMain creates the fonts, then shows first-run, then the main window'
Assert ($iCap -ge 0 -and $iFontsInOnce -gt $iCap) 'the main window still caps the scale before it rebuilds the fonts'
# The same tiles are used by the privacy "OK, got it" button, the name Save/Skip buttons, and the helper Save/Skip buttons.
$paint = Get-FnText 'Invoke-FixItTilePaint'
Assert ($paint -match '\$script:UiFonts\.Big') 'the centered Save and Skip buttons paint with the shared Big font'

Section 'Choosing Trey, someone else, or Skip keeps the helper and does not start a repair'
function Send-FixItReport { param([string]$Text = '', [string]$Kind = 'report') [void]$script:Sent.Add($Kind); return $true }
$script:Sent = New-Object System.Collections.ArrayList
$script:UiScale = 1.0
$script:UiHighContrast = $false
$script:GuiActive = $true

$trey = Save-FixItHelper -Other $false
Complete-FixItHelperChange -Save $trey -Quiet $true
$h = Get-FixItHelper
Assert ($trey.Saved -and $h.IsTrey -and $h.Name -eq 'Trey' -and $script:Sent.Count -eq 0) 'Save with Trey selected keeps Trey and sends nothing'
Assert ((Get-FixItSetting -Name 'HelperAsked' -Default '') -ne '') 'answering the question records that it was asked'

$script:Sent.Clear()
$bad = Save-FixItHelper -Other $true -Name 'Ada' -Email 'not-an-email'
Assert (-not $bad.Saved -and (Get-FixItHelper).IsTrey -and $script:Sent.Count -eq 0) 'a bad address is not saved and Trey stays the helper'

$at = '@'
$ada = Save-FixItHelper -Other $true -Name 'Ada' -Email ('ada' + $at + 'family.test')
Complete-FixItHelperChange -Save $ada -Quiet $true
$h2 = Get-FixItHelper
Assert ($ada.Saved -and $ada.EmailChanged -and -not $h2.IsTrey -and $h2.Name -eq 'Ada' -and @($script:Sent) -eq @('hello')) 'Save with someone else stores that helper and asks only for the hello email'
Assert ((Get-FnText 'Save-FixItHelper') -notmatch 'RepairWindows|Invoke-PrinterFix|Invoke-FixItAction') 'saving a helper does not reach a repair'

$script:Sent.Clear()
Register-FixItHelperDismiss -FirstRun $false
$h3 = Get-FixItHelper
Assert (-not $h3.IsTrey -and $h3.Name -eq 'Ada' -and $script:Sent.Count -eq 0) 'Cancel leaves the saved helper alone'

Register-FixItHelperDismiss -FirstRun $true
Assert ((Get-FixItHelper).Name -eq 'Ada') 'Skip on a later question does not wipe a helper who was already saved'
$asked = Get-FixItSetting -Name 'HelperAsked' -Default ''
Assert ($asked -ne '') 'Skip on the first run still records that the question was answered'

# A clean first run that is skipped stays with Trey.
Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'FamilyFixIt\state.json') -Force -ErrorAction SilentlyContinue
Register-FixItHelperDismiss -FirstRun $true
Assert ((Get-FixItHelper).IsTrey -and (Get-FixItSetting -Name 'HelperAsked' -Default '') -ne '') 'Skip on a clean first run keeps Trey and does not ask again'

Section 'When a font can be built, the table matches the scale the dialogs use'
$canDraw = $false
try {
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $probe = New-Object System.Drawing.Font('Segoe UI', ([single]12), ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel))
    $canDraw = $null -ne $probe
    $probe.Dispose()
} catch { $canDraw = $false }
if ($canDraw) {
    if (Get-Variable -Name UiFonts -Scope Script -ErrorAction SilentlyContinue) { Remove-Variable -Name UiFonts -Scope Script }
    $script:UiScale = 1.5
    Initialize-FixItUiFonts
    $big = $script:UiFonts.Big
    Assert ($null -ne $big -and [math]::Abs($big.Size - 24) -lt 0.01 -and $null -ne $script:UiFonts.Title -and $null -ne $script:UiFonts.SideSmall) 'fonts for a 1.5 scale dialog exist before any tile paints'
} else {
    Microsoft.PowerShell.Utility\Write-Host '  (System.Drawing cannot build a Font on this machine. The Windows screen check scenario helper-question-clean-first-run paints the dialog.)'
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Microsoft.PowerShell.Utility\Write-Host ''
Microsoft.PowerShell.Utility\Write-Host ('Passed: {0}   Failed: {1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
