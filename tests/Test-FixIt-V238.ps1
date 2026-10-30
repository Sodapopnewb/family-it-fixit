# Version 2.3.8 tests: text-only buttons (Skip in "What's your name?", "I don't know" in the Chrome question) must show their label.
# The label used to be drawn below the bottom edge of a 56 px button, so the button looked empty. Text-only tiles are now drawn centered.
# These use the REAL program functions (the drawing itself needs Windows, so the decision and the colors are tested here).
# Usage:  pwsh ./tests/Test-FixIt-V238.ps1       (Test-FixIt.ps1 runs this one too and adds its numbers)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fixit-v238-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:Pass = 0; $script:Fail = 0
function Assert { param([bool]$Cond, [string]$Name) if ($Cond) { $script:Pass++ } else { $script:Fail++; Write-Host ('  FAIL: ' + $Name) -ForegroundColor Red } }
function Section { param([string]$T) Write-Host ('== ' + $T) }

$src = Join-Path $root 'FamilyFixIt.ps1'
$outDir = Join-Path $tmp 'out'; New-Item -ItemType Directory -Path $outDir | Out-Null
$env:LOCALAPPDATA = Join-Path $tmp 'local'; New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
$env:COMPUTERNAME = 'TESTPC'
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v238.log') -OutputDir $outDir
$srcText = [IO.File]::ReadAllText($src)
$tokens = $null; $perr = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$perr)

Assert ([version]$script:FixItVersion -ge [version]'2.3.8') 'the program is version 2.3.8 or newer'

# ================================================================ 1. the decision
Section 'Text-only tiles are drawn centered'
Assert (Test-FixItTileCenteredText -Style 'outline' -HasIcon $false -Wide $false -Sub '') 'outline, no icon, no subtitle (Skip, I don''t know): centered'
Assert (Test-FixItTileCenteredText -Style 'yes') 'yes: centered'
Assert (Test-FixItTileCenteredText -Style 'no') 'no: centered'
Assert (Test-FixItTileCenteredText -Style 'btn' -HasIcon $true -Wide $true -Sub 'x') 'plain button: always centered'
Assert (-not (Test-FixItTileCenteredText -Style 'outline' -HasIcon $true -Wide $false -Sub '')) 'outline with an icon keeps the icon layout'
Assert (-not (Test-FixItTileCenteredText -Style 'outline' -HasIcon $false -Wide $false -Sub 'Something else is wrong')) 'outline with a subtitle keeps the two-line layout'
Assert (-not (Test-FixItTileCenteredText -Style 'outline' -HasIcon $false -Wide $true -Sub '')) 'a wide outline tile keeps the wide layout'
Assert (-not (Test-FixItTileCenteredText -Style 'card' -HasIcon $true -Wide $false -Sub 'Fix it')) 'a normal card keeps its layout'
Assert (-not (Test-FixItTileCenteredText -Style 'primary' -HasIcon $true -Wide $true -Sub 'Opens Zoho Assist')) 'the big blue tile keeps its layout'
Assert (-not (Test-FixItTileCenteredText -Style 'scam' -HasIcon $true -Wide $true -Sub 'Do not call')) 'the scam tile keeps its layout'

# the paint function really asks, before it lays out icon + two lines, and then draws only the title
$paint = ($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-FixItTilePaint' }, $true) | Select-Object -First 1).Extent.Text
$iAsk = $paint.IndexOf('Test-FixItTileCenteredText -Style $style')
$iTwo = $paint.IndexOf('$r1 = New-Object System.Drawing.Rectangle($ix')
$iDraw = $paint.IndexOf('VerticalCenter -bor $tf::SingleLine')
Assert ($iAsk -gt 0 -and $iDraw -gt $iAsk -and $iTwo -gt $iDraw) 'the paint code asks first, draws the centered title, and only then reaches the icon + subtitle layout'
$afterAsk = $paint.Substring($iAsk)
$centerBlock = $afterAsk.Substring($afterAsk.IndexOf('{'), $afterAsk.IndexOf('return') - $afterAsk.IndexOf('{') + 6)   # from the opening brace to the first return
Assert ($centerBlock -match '\$t\.Title' -and $centerBlock -notmatch '\$t\.Sub' -and $centerBlock.IndexOf('$r1 =') -lt 0) 'the centered path draws the title only (no subtitle) and returns before the icon + subtitle layout'
Assert ($centerBlock -match 'New-Object System\.Drawing\.Rectangle\(0, 0, \$w, \$h\)') 'the title is centered in the whole button, so it cannot fall below the bottom edge'
Assert ($centerBlock -match '\(Get-FixItColor \$ttl\)') 'the label color is the tile style''s title color'
Assert ($paint.IndexOf('$col = Get-FixItTileColors') -gt 0 -and $paint.IndexOf('$col = Get-FixItTileColors') -lt $iAsk -and $paint.IndexOf('$G.DrawPath($pen, $path)') -lt $iAsk) 'the fill and the border are drawn before the label, for every tile (the outline keeps its blue border)'

# ================================================================ 2. colors of the outline button
Section 'Outline button colors'
$n = Get-FixItTileColors -Style 'outline' -Hover $false -HighContrast $false
Assert ($n.Fill -eq '#FFFFFF' -and $n.Line -eq '#0F6CBD' -and $n.Title -eq '#0F6CBD' -and $n.LineW -eq 1.5) 'normal: white button, blue border, blue label'
$h = Get-FixItTileColors -Style 'outline' -Hover $true -HighContrast $false
Assert ($h.Fill -eq '#F3F8FD' -and $h.Line -eq '#0F6CBD' -and $h.Title -eq '#0F6CBD') 'mouse over: light blue button, same border and label'
Assert ((Get-FixItContrast $n.Title $n.Fill) -ge 4.5 -and (Get-FixItContrast $h.Title $h.Fill) -ge 4.5) 'the label is easy to read on the button (contrast at least 4.5)'
$hc = Get-FixItTileColors -Style 'outline' -Hover $false -HighContrast $true
Assert ($hc.Fill -eq '#000000' -and $hc.Line -eq '#FFFF00' -and $hc.Title -eq '#FFFF00') 'High contrast: black button, yellow border and label'
Assert ((Get-FixItContrast $hc.Title $hc.Fill) -ge 7) 'High contrast label is easy to read (contrast at least 7)'

# ================================================================ 3. every tile in the program
Section 'Every tile the program creates'
$calls = @($ast.FindAll({ param($c) $c -is [Management.Automation.Language.CommandAst] -and $c.GetCommandName() -eq 'New-FixItTile' }, $true))
Assert ($calls.Count -ge 30) ('found the tile calls (' + $calls.Count + ')')
function Get-Arg {
    param($Call, [string]$Name)
    $els = $Call.CommandElements
    for ($i = 0; $i -lt $els.Count - 1; $i++) {
        if ($els[$i] -is [Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq $Name) {
            $v = $els[$i + 1]
            if ($v -is [Management.Automation.Language.StringConstantExpressionAst]) { return [pscustomobject]@{ Known = $true; Value = $v.Value } }
            if ($v -is [Management.Automation.Language.VariableExpressionAst] -and $v.VariablePath.UserPath -in 'true', 'false') { return [pscustomobject]@{ Known = $true; Value = ($v.VariablePath.UserPath -eq 'true') } }
            return [pscustomobject]@{ Known = $false; Value = $null }
        }
    }
    return $null
}
$moved = New-Object System.Collections.ArrayList     # tiles that were NOT centered before 2.3.8 and are now
$bad = New-Object System.Collections.ArrayList
$centeredCount = 0; $layoutCount = 0
foreach ($c in $calls) {
    $style = Get-Arg $c 'Style'; $icon = Get-Arg $c 'IconKey'; $sub = Get-Arg $c 'Sub'; $wide = Get-Arg $c 'Wide'; $title = Get-Arg $c 'Title'
    if ($null -eq $style -or -not $style.Known) { continue }   # the function's own definition is not a call; nothing else leaves the style open
    $iconKnown = ($null -ne $icon -and $icon.Known); $subKnown = ($null -ne $sub -and $sub.Known)
    $hasIconMaybe = $true; if ($iconKnown -and [string]$icon.Value -eq '') { $hasIconMaybe = $false }
    $subEmptyKnown = ($subKnown -and [string]$sub.Value -eq '')
    $isWide = ($null -ne $wide -and $wide.Known -and $wide.Value -eq $true)
    $label = ('line ' + $c.Extent.StartLineNumber + ' ' + $style.Value + ' ' + $(if ($title -and $title.Known) { '"' + $title.Value + '"' } else { '(title from a variable)' }))
    if ($style.Value -in 'nav', 'toggle', 'logo') { continue }   # drawn by their own code, before this decision
    if ($style.Value -in 'yes', 'no', 'btn') { $centeredCount++; continue }   # always centered, before and after 2.3.8
    # the remaining styles: card, scam, primary, outline
    if ($iconKnown -and -not $hasIconMaybe -and -not $isWide -and $subEmptyKnown) {
        $centeredCount++; [void]$moved.Add($label)
    } else {
        $layoutCount++
        # these keep the icon layout: they must have a subtitle (or an icon key) so they never lose their label
        if ($subKnown -and [string]$sub.Value -eq '' -and -not $isWide -and $iconKnown -and [string]$icon.Value -ne '') { [void]$bad.Add($label) }   # an icon tile with no subtitle (the icon may fail to load)
    }
}
Assert ($moved.Count -eq 2) ('exactly two tiles change how they are drawn: ' + ($moved -join '; '))
Assert (@($moved | Where-Object { $_ -match 'outline "Skip"' }).Count -eq 1) 'one of them is Skip in the name window'
Assert (@($moved | Where-Object { $_ -match "outline `"I don't know`"" }).Count -eq 1) 'the other is "I don''t know" in the Chrome question'
Assert (@($moved | Where-Object { $_ -notmatch 'outline' }).Count -eq 0) 'every changed tile is an outline tile (the only other styles with no icon and no subtitle, yes/no/btn, were already centered)'
Assert ($bad.Count -eq 0) ('no icon tile is left without a subtitle: ' + ($bad -join '; '))
Assert ($centeredCount -ge 20 -and $layoutCount -ge 5) ('sanity: ' + $centeredCount + ' text-only tiles, ' + $layoutCount + ' icon tiles')
# the two tiles are 56 px tall, which is what made the old layout push the label out of sight
foreach ($nm in 'Skip', "I don't know") {
    $call = $calls | Where-Object { $t2 = Get-Arg $_ 'Title'; $t2 -and $t2.Known -and $t2.Value -eq $nm } | Select-Object -First 1
    Assert ($null -ne $call) ("found the $nm tile")
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
