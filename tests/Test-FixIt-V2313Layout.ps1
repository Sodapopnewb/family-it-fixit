# Version 2.3.13 layout tests: the screen check (tools/Run-ScreenCheck.sh) found text cut off, windows taller than the screen and a heading on top of
# the health pill. These tests check the shared text-fit rules and that every window uses them. The real drawing needs Windows (the screen check run
# on GitHub proves it); here the measuring is pretend, and the REAL program functions run.
# Usage:  pwsh ./tests/Test-FixIt-V2313Layout.ps1       (Test-FixIt.ps1 runs this one too and adds its numbers)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fixit-v2313l-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:Pass = 0; $script:Fail = 0
function Assert { param([bool]$Cond, [string]$Name) if ($Cond) { $script:Pass++ } else { $script:Fail++; Write-Host ('  FAIL: ' + $Name) -ForegroundColor Red } }
function Section { param([string]$T) Write-Host ('== ' + $T) }

$src = Join-Path $root 'FamilyFixIt.ps1'
$outDir = Join-Path $tmp 'out'; New-Item -ItemType Directory -Path $outDir | Out-Null
$env:LOCALAPPDATA = Join-Path $tmp 'local'; New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
$env:COMPUTERNAME = 'TESTPC'
$tLogFile = Join-Path $tmp 'v2313l.log'
. $src -LibraryOnly -LogPath $tLogFile -OutputDir $outDir
Initialize-FixItLog
$srcText = [IO.File]::ReadAllText($src)
$tokens = $null; $perr = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$perr)
function Get-Fn { param([string]$Name) $f = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1; if ($null -eq $f) { return '' }; return $f.Extent.Text }

# ================================================================ 1. the shared rules
Section 'Wrapped text is measured with a safety margin'
$seen = New-Object System.Collections.ArrayList
$m = { param($t, $w) [void]$seen.Add($w); return 40 }
[void](Get-FixItWrappedTextHeight -Text 'x' -Width 1000 -Scale 1.0 -Measure $m)
Assert ($seen[0] -eq (1000 - 8 - 30)) 'at 100% the text is measured 8px + 3% narrower than the label'
[void](Get-FixItWrappedTextHeight -Text 'x' -Width 1080 -Scale 2.0 -Measure $m)
Assert ($seen[1] -eq (1080 - 16 - 32)) 'at 200% the text is measured 16px + 3% narrower than the label'
Assert ((Get-FixItWrappedTextHeight -Text 'x' -Width 0 -Scale 1.0 -Measure $m) -eq 40 -and $seen[2] -ge 1) 'a zero width is still measured at 1px or more'

Section 'A window never gets taller than the screen'
$p = Get-FixItDialogHeightPlan -ClientHeight 700 -WorkAreaHeight 1032 -FrameHeight 39 -Scale 1.0
Assert (-not $p.TooTall -and $p.Delta -eq 0 -and $p.ClientHeight -eq 700) 'a window that fits is left alone'
$p = Get-FixItDialogHeightPlan -ClientHeight 1050 -WorkAreaHeight 1032 -FrameHeight 39 -Scale 1.5
Assert ($p.TooTall -and $p.ClientHeight -eq (1032 - 39 - 18) -and $p.Delta -eq (1050 - $p.ClientHeight)) 'a 1050px window on a 1032px screen is capped (frame and margin left free)'
$p = Get-FixItDialogHeightPlan -ClientHeight 1750 -WorkAreaHeight 1032 -FrameHeight 39 -Scale 2.5
Assert ($p.TooTall -and ($p.ClientHeight + 39) -lt 1032) 'at 250% the window plus its frame is under the screen height'
$p = Get-FixItDialogHeightPlan -ClientHeight 900 -WorkAreaHeight 0 -FrameHeight 39 -Scale 1.0
Assert (-not $p.TooTall) 'with an unknown screen height nothing is changed'
$p = Get-FixItDialogHeightPlan -ClientHeight 900 -WorkAreaHeight 300 -FrameHeight 39 -Scale 1.0
Assert ($p.TooTall -and $p.ClientHeight -ge 240) 'a tiny screen never makes a window smaller than 240px'
foreach ($wh in @(600, 768, 864, 1032, 1200, 1392)) {
    foreach ($sc in @(1.0, 1.25, 1.5, 1.875, 2.0, 2.5)) {
        $p = Get-FixItDialogHeightPlan -ClientHeight 2000 -WorkAreaHeight $wh -FrameHeight 39 -Scale $sc
        if (-not ($p.ClientHeight + 39 -le $wh -or $p.ClientHeight -eq 240)) { Assert $false ('capped height fits a {0}px screen at scale {1}' -f $wh, $sc) }
    }
}
Assert ($true) 'every screen height from 600 to 1392 and every scale up to 250% gets a window that fits (or the 240px floor)'
$lim = Get-Fn 'Limit-FixItDialogToScreen'
Assert ($lim -match 'Get-FixItDialogHeightPlan' -and $lim -match '\$Panel\.Height = \$Panel\.Height - \$d' -and $lim -match '\$c\.Top = \$c\.Top - \$d') 'Limit-FixItDialogToScreen shrinks the scrolling panel and lifts the buttons by the same amount'
Assert ($lim -match 'Ceiling\(100 \* \$Scale\)') 'the scrolling panel is never made shorter than 100 units'
Assert ($lim -match 'catch' -and $lim -match 'return \$false') 'if the fit fails the window is still shown as it was'

Section 'The main window fits across the screen'
Assert ((Get-FixItMainScaleCap -Scale 1.0 -WorkAreaWidth 1920) -eq 1.0) '100% is not touched on a 1920px screen'
Assert ((Get-FixItMainScaleCap -Scale 1.5 -WorkAreaWidth 1920) -eq 1.5) '150% is not touched on a 1920px screen'
$c2 = Get-FixItMainScaleCap -Scale 2.0 -WorkAreaWidth 1920
Assert ($c2 -lt 2.0 -and $c2 -gt 1.9 -and (940 * $c2 + 17 + 56) -le 1920) '200% on a 1920px screen is lowered a little, and then the window plus its frame fits'
$c25 = Get-FixItMainScaleCap -Scale 2.5 -WorkAreaWidth 1920
Assert ($c25 -eq $c2) '250% (200% with Big text) gets the same cap'
Assert ((Get-FixItMainScaleCap -Scale 2.0 -WorkAreaWidth 3840) -eq 2.0) 'a 4K screen keeps 200%'
Assert ((Get-FixItMainScaleCap -Scale 1.25 -WorkAreaWidth 800) -eq 1.0) 'a tiny screen is never made smaller than 100%'
Assert ((Get-FixItMainScaleCap -Scale 2.0 -WorkAreaWidth 0) -eq 2.0) 'an unknown screen width changes nothing'
$wo = Get-Fn 'Show-FixItWindowOnce'
Assert ($wo -match 'Get-FixItMainScaleCap' -and $wo -match '\$script:UiScale = \$scaleBefore') 'the main window uses the cap and puts the old scale back when it closes'
Assert ($wo -match "\`$scaleBefore = \`$script:UiScale" -and $wo.IndexOf('Get-FixItMainScaleCap') -lt $wo.IndexOf('$script:UiFonts')) 'the cap is applied before any font is made'

Section 'Fitting a font'
$meas = { param($sz) [int]($sz * 14) }
Assert ((Get-FixItFittingFontSize -StartSize 26 -MinSize 18 -MaxWidth 400 -Measure $meas) -eq 26) 'a heading that already fits keeps its size'
$fz = Get-FixItFittingFontSize -StartSize 26 -MinSize 18 -MaxWidth 300 -Measure $meas
Assert ($fz -lt 26 -and $fz -ge 18 -and (($fz * 14) -le 300)) 'a heading that is too wide gets the biggest smaller size that fits'
Assert ((Get-FixItFittingFontSize -StartSize 26 -MinSize 18 -MaxWidth 100 -Measure $meas) -eq 18) 'it never goes below the smallest size'
Assert ((Get-FixItFittingFontSize -StartSize 11.5 -MinSize 9 -MaxWidth 120 -Measure { param($sz) [int]($sz * 12) }) -le 10) 'a long health message gets a smaller font'

# ================================================================ 2. the main window
Section 'Main window: heading, pill and sidebar'
Assert ($wo -match '\[int\]\(326 \* \$S\)') 'the heading box stops 8 units before the health pill (it was 380 wide and covered the pill)'
Assert ($wo -match 'Get-FixItFittingFontSize -StartSize \(26 \* \$S\)') 'the heading font shrinks if its text would be wider than its box'
Assert ($wo -match 'AutoEllipsis = \$true' -and $wo -match 'Get-FixItFittingFontSize -StartSize \(11\.5 \* \$script:UiScale\)') 'the health pill shrinks a long message, and shows "..." as a last resort'
Assert ($wo -match '-W 184 -H \$nd\[5\]' -and $wo -match '-W 184 -H \$td\[5\] -On' -and $wo -match '-W 184 -H \$pd\[5\]' -and $wo -match '-W 184 -H \$dd\[5\]') 'all the sidebar buttons are 184 wide (176 before: "Pin me to the taskbar" was cut off at Big text)'
Assert ($wo -match '208 \* \$S' -and $wo -notmatch '-W 176') 'the sidebar is 208 wide and nothing is still 176'
$lay = Get-FixItLayout -Simple $false -GuardianOn $true -BigText $false -HighContrast $false -CheckInOn $true
$items = @($lay.Nav) + @($lay.Toggles) + @(, $lay.Pin) + @(, $lay.Donate)
$items = @($items | Sort-Object { [int]$_[4] })
$okGap = $true; for ($i = 0; $i -lt ($items.Count - 1); $i++) { if ([int]$items[$i][4] + [int]$items[$i][5] -gt [int]$items[$i + 1][4]) { $okGap = $false; Write-Host ('  overlap: ' + $items[$i][0] + ' and ' + $items[$i + 1][0]) } }
Assert $okGap 'no two sidebar buttons overlap'
$g = @($lay.Toggles | Where-Object { $_[0] -eq 'Guardian' })[0]
Assert ([int]$g[5] -ge 60) 'the "Watch for scary pop-ups" switch is at least 60 tall (its two lines need 56)'
$last = $items[$items.Count - 1]
Assert ([int]$last[4] + [int]$last[5] + 20 -le [int]$lay.FullH) 'the window is tall enough for the last sidebar button'
Assert ([int]$lay.SepY -lt [int](@($lay.Toggles)[0][4])) 'the divider line is above the switches'
$layS = Get-FixItLayout -Simple $true -GuardianOn $false -BigText $false -HighContrast $false -CheckInOn $false
Assert ([int]$layS.FullH -ge ([int]$layS.Donate[4] + [int]$layS.Donate[5])) 'Simple mode still fits its last button'

# ================================================================ 3. the plan window
Section 'Plan window: the "How long it takes" line'
$pd = Get-Fn 'Show-FixItPlanDialog'
Assert ($pd -match 'Get-FixItLabelHeight -Text \(\[string\]\$sub\.Text\)' -and $pd -match '\$listTop') 'the "How long it takes" line is as tall as its wrapped text, and the list starts under it'
Assert ($pd -notmatch '\[int\]\(92 \* \$S\)') 'nothing is still placed at the old fixed 92 units'
Assert ($pd -match 'Limit-FixItDialogToScreen -Form \$f -Panel \$pn -Pinned @\(\$go, \$back\)') 'the Proceed and Go Back buttons stay on the screen'
Assert ($pd -match "Get-FixItLabelHeight -Text \(\[string\]\`$lb\[0\]\)") 'the coloured boxes are still sized with the shared helper'

# ================================================================ 4. every tall window
Section 'Tall windows keep their buttons on the screen'
foreach ($n in @('Show-FixItGuideSteps', 'Show-FixItPcInfoForm', 'Show-FixItGuidesDialog', 'Show-FixItFilesDialog', 'Show-FixItScamForm', 'Show-FixItTextDialog', 'Show-FixItPlanDialog')) {
    Assert ((Get-Fn $n) -match 'Limit-FixItDialogToScreen') ($n + ' limits its height to the screen')
}
Assert ((Get-Fn 'Show-FixItGuideSteps') -match 'Pinned @\(\$back, \$no\)') 'a guide keeps Back and "This didn''t help" visible'
Assert ((Get-Fn 'Show-FixItPcInfoForm') -match 'Pinned @\(\$cp, \$cl\)') 'My PC info keeps Copy and Close visible'
Assert ((Get-Fn 'Show-FixItScamForm') -match 'Pinned @\(\$ok\)' -and (Get-Fn 'Show-FixItScamForm') -match 'AutoScroll = \$true') 'the scary pop-up window scrolls its text and keeps OK visible'
Assert ((Get-Fn 'Show-FixItScamForm') -notmatch 'Expand-FixItLabelsToFit') 'the scary pop-up window sizes its text itself'
$fl = Get-Fn 'Show-FixItFilesDialog'
Assert ($fl.IndexOf('Limit-FixItDialogToScreen') -gt $fl.IndexOf('$script:FilesPanel = $pn')) 'My files limits the window after its list exists'
Assert ((Get-Fn 'Set-FixItFilesMessage') -match 'ClientSize\.Height') 'the My files list always follows the window height'
$ft = Get-FixItFilesTopLayout -NoteHeightPx 20 -Scale 1.0 -ClientH 520
Assert ($ft.PanelY + $ft.PanelH + 16 -eq 520) 'the My files list ends 16 units above the bottom of a window that was made shorter'
Assert ((Get-Fn 'Set-FixItFilesMessage') -match 'Get-FixItFilesTopLayout -NoteHeightPx \$hpx -Scale \$S -ClientH \$clientUnits') 'the My files note passes the real window height on'
$td = Get-Fn 'Show-FixItTextDialog'
Assert ($td -match '\$bar\.Size = New-Object System\.Drawing\.Size\(\$f\.ClientSize\.Width' -and $td.IndexOf('$bar.Size') -lt $td.IndexOf('$bar.Controls.Add($ok)')) 'the results window makes its button bar full width BEFORE the Close button goes in (it was 200px wide, so the button jumped out of it)'
Assert ($td -match '\$f\.ClientSize\.Width - \[int\]\(140 \* \$S\)') 'the Close button sits 20 units from the right edge'
Assert ((Get-Fn 'Show-FixItAppsDialog') -match 'Get-FixItLabelHeight -Text \(\[string\]\$a\.Description\)') 'the app descriptions are sized with the shared helper (the Dropbox one was cut off)'

Section 'Everything else still follows the shared rules'
Assert ($srcText -notmatch '&&|\|\||\?\?') 'no && || or ?? anywhere in the program'
Assert (($srcText -split "`n" | Where-Object { $_ -match 'Limit-FixItDialogToScreen' }).Count -ge 8) 'the limit is used by at least 7 windows (and defined once)'
Assert ($perr.Count -eq 0) 'the program still parses'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('Passed: {0}   Failed: {1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
