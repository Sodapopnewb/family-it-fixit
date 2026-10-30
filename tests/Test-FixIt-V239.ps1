# Version 2.3.9 tests: Share with a friend, the 'Family Fix-It Reports' folder in Documents, My files layout, the "?" help dots on the main
# buttons, Install an app (12 apps, sections, scrolling window, Spotify not elevated) and the guide step layout (no clipped step text).
# Drawing needs Windows, so these use the REAL program functions with pretend measuring, plus checks of the program text.
# Usage:  pwsh ./tests/Test-FixIt-V239.ps1       (Test-FixIt.ps1 runs this one too and adds its numbers)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fixit-v239-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:Pass = 0; $script:Fail = 0
function Assert { param([bool]$Cond, [string]$Name) if ($Cond) { $script:Pass++ } else { $script:Fail++; Write-Host ('  FAIL: ' + $Name) -ForegroundColor Red } }
function Section { param([string]$T) Write-Host ('== ' + $T) }

$src = Join-Path $root 'FamilyFixIt.ps1'
$outDir = Join-Path $tmp 'out'; New-Item -ItemType Directory -Path $outDir | Out-Null
$env:LOCALAPPDATA = Join-Path $tmp 'local'; New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
$env:COMPUTERNAME = 'TESTPC'
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v239.log') -OutputDir $outDir
$srcText = [IO.File]::ReadAllText($src)
$tokens = $null; $perr = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$perr)
function Get-Fn { param([string]$Name) $f = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1; if ($null -eq $f) { return '' }; return $f.Extent.Text }
function Get-Layouts {
    foreach ($simple in @($false, $true)) { foreach ($g in @($false, $true)) { foreach ($bt in @($false, $true)) { foreach ($hcx in @($false, $true)) { foreach ($ci in @($false, $true)) {
        [pscustomobject]@{ Name = "simple=$simple guardian=$g big=$bt contrast=$hcx checkin=$ci"; Layout = (Get-FixItLayout -Simple $simple -GuardianOn $g -BigText $bt -HighContrast $hcx -CheckInOn $ci) }
    } } } } }
}
$scales = @(1.0, 1.25, 1.5, 1.75, 2.0, 2.5)

Assert ([version]$script:FixItVersion -ge [version]'2.3.9') 'the program is version 2.3.9 or newer'

# ================================================================ 1. Share with a friend
Section 'Share with a friend'
$combos = 0
foreach ($c in Get-Layouts) {
    $combos++
    $ft = @($c.Layout.Footer)
    $sh = @($ft | Where-Object { $_[0] -eq 'Share' })
    Assert ($sh.Count -eq 1 -and $sh[0][1] -eq 'Share with a friend') ("$($c.Name): the footer has the Share with a friend link")
    $xs = @($ft | ForEach-Object { [int]$_[2] })
    Assert ($xs.Count -eq 3 -and $xs[1] -gt $xs[0] + 80 -and $xs[2] -gt $xs[1] + 60 -and ($xs[2] + 130) -le 579) ("$($c.Name): the three footer links do not overlap each other or the version")
}
Assert ($combos -eq 32) 'checked all 32 layouts for the Share link'
Assert ($srcText.Contains("https://github.com/<OWNER>/family-it-fixit/releases/latest/download/Install-FamilyFixIt.zip")) 'the share address is the latest-download link of the release zip (owner is filled in on publish)'
$oldShare = $script:ShareUrl
$script:ShareUrl = 'https://github.com/<' + 'OWNER>/family-it-fixit/releases/latest/download/Install-FamilyFixIt.zip'
Assert ((Get-FixItShareUrl) -eq '') 'an unpublished copy (placeholder owner) shares nothing'
$script:ShareUrl = 'https://github.com/Sodapopnewb/family-it-fixit/releases/latest/download/Install-FamilyFixIt.zip'
Assert ((Get-FixItShareUrl) -eq 'https://github.com/Sodapopnewb/family-it-fixit/releases/latest/download/Install-FamilyFixIt.zip') 'a published address is handed out as is'
$script:ShareUrl = 'http://example.test/x.zip'
Assert ((Get-FixItShareUrl) -eq '') 'a link that is not https is never shared'
$script:ShareUrl = $oldShare
Assert ((Get-FixItShareButtonText) -eq 'Copy link' -and (Get-FixItShareButtonText -State 'Copied') -eq 'Copied!' -and (Get-FixItShareButtonText -State 'Failed') -eq 'Could not copy') 'button texts: Copy link, Copied!, Could not copy'
$form = Get-Fn 'Show-FixItShareForm'
Assert ($form -match 'ReadOnly' -and $form -match 'Get-FixItShareButtonText' -and $form -match 'Close' -and $form -match 'Timer') 'the window has a read-only box, a Copy link button that changes text for a moment, and Close'
Assert ($form -match 'UiHighContrast' -and $form -match 'UiScale') 'the share window follows Big text and High contrast'
Assert ($form -match 'Write-FixItLog') 'copying is logged'
Assert ((Get-Fn 'Invoke-FixItShare') -match 'Write-FixItLog' -and (Get-Fn 'Invoke-FixItShare') -match 'Add-FixItTestNote') 'a click is logged, and Test mode adds a note instead of opening anything'
Assert ($srcText -match "'Share'\s+\{ Show-FixItResult \(Invoke-FixItShare\)\}?" -or $srcText -match "'Share'\s+\{ Show-FixItResult \(Invoke-FixItShare\) \}") 'the command line action Share exists'
Assert ($script:TestAllKeys -contains 'Share') 'Test all checks the Share link too'
$oldTm = $script:TestMode; $oldGui = $script:GuiActive
$script:TestMode = $true; $script:GuiActive = $false
$r = Invoke-FixItShare
Assert ($r.Ok) 'Test mode: Share only checks, and passes'
$script:TestMode = $oldTm; $script:GuiActive = $oldGui

# ================================================================ 2. the Reports folder in Documents
Section 'Saved files go to Family Fix-It Reports in Documents'
$fakeDocs = Join-Path $tmp 'OneDrive\Documents'; $fakeDesk = Join-Path $tmp 'Desktop'
New-Item -ItemType Directory -Path $fakeDocs, $fakeDesk -Force | Out-Null
function Get-FixItDocumentsFolder { return $script:PretendDocs }
function Get-DesktopFolder { return $fakeDesk }
$script:PretendDocs = $fakeDocs
$want = Join-Path $fakeDocs 'Family Fix-It Reports'
Assert ((Get-FixItReportsFolderPath) -eq $want) 'the folder is named Family Fix-It Reports inside the real Documents (even when OneDrive moved it)'
Assert ((Get-FixItSaveFolder) -eq $want -and -not (Test-Path $want)) 'asking without -Create touches nothing'
$got = Get-FixItSaveFolder -Create
Assert ($got -eq $want -and (Test-Path $want -PathType Container)) 'the folder is made when it is missing'
Set-Content -LiteralPath (Join-Path $want 'old.txt') 'x'
$got2 = Get-FixItSaveFolder -Create
Assert ($got2 -eq $want -and (Test-Path (Join-Path $want 'old.txt')) -and @(Get-ChildItem $want -Force).Count -eq 1) 'running again changes nothing and leaves the earlier file (idempotent, no probe file left)'
Assert (@(Get-ChildItem $fakeDesk -Force).Count -eq 0) 'nothing was put on the Desktop'
$script:PretendDocs = ''
Assert ((Get-FixItSaveFolder -Create) -eq $fakeDesk) 'no Documents folder found: the Desktop is the fallback'
$script:PretendDocs = (Join-Path $tmp 'blocker.txt'); Set-Content -LiteralPath $script:PretendDocs 'a file, not a folder'
Assert ((Get-FixItSaveFolder -Create) -eq $fakeDesk) 'Documents cannot be written: the Desktop is the fallback'
$script:PretendDocs = $fakeDocs
Assert ((Get-FixItSavedWhere -Path (Join-Path $want 'a.txt')) -eq "in the 'Family Fix-It Reports' folder in your Documents") 'the message for a saved file names the reports folder'
Assert ((Get-FixItSavedWhere -Path (Join-Path $fakeDesk 'a.txt')) -eq 'on your Desktop') 'a file that really went to the Desktop says so'
$savedOut = $OutputDir
$OutputDir = ''
$res = Save-FixItReportFile -Text 'hello' -Prefix 'Test-V239'
Assert ($res.Ok -and (Split-Path -Parent $res.Path) -eq $want -and (Test-Path $res.Path)) 'a report is saved in the reports folder when there is no override'
$oldDry = $script:DryRun; $script:DryRun = $true
$fresh = Join-Path $tmp 'Fresh\Documents'; New-Item -ItemType Directory -Path $fresh -Force | Out-Null; $script:PretendDocs = $fresh
$res2 = Save-FixItReportFile -Text 'hello' -Prefix 'Test-V239'
Assert (-not (Test-Path (Join-Path $fresh 'Family Fix-It Reports'))) 'practice run (dry-run) creates no folder'
$script:DryRun = $oldDry; $script:PretendDocs = $fakeDocs
$OutputDir = $savedOut
$res3 = Save-FixItReportFile -Text 'hello' -Prefix 'Test-V239'
Assert ((Split-Path -Parent $res3.Path) -eq $outDir) 'the -OutputDir override still wins (tests and command line)'
Assert ($srcText -notmatch 'saved on (your|the) Desktop' -and $srcText -notmatch 'file on your Desktop') 'no message still says reports are saved on the Desktop'
Assert ($srcText.Contains('[Environment]::GetFolderPath(''MyDocuments'')')) 'Documents comes from Windows (so OneDrive-redirected Documents works)'

# ================================================================ 3. My files layout
Section 'My files: note height, wrapped names, row heights'
$m10 = { param($t) [int]($t.Length * 10) }
$one = Split-FixItNameLines -Name 'short.docx' -MaxWidth 400 -Measure $m10
Assert (@($one.Lines).Count -eq 1 -and $one.Lines[0] -eq 'short.docx' -and -not $one.Truncated) 'a short name stays on one line'
$long = 'Tax_Return_2025_Final_Version_signed_by_both_of_us.pdf'
$two = Split-FixItNameLines -Name $long -MaxWidth 300 -Measure $m10
Assert (@($two.Lines).Count -eq 2 -and -not $two.Truncated) 'a long name wraps to two lines'
Assert ($two.Lines[0].EndsWith('_') -or $two.Lines[0].EndsWith('-') -or $two.Lines[0].EndsWith('.')) 'the first line breaks after an underscore'
Assert (($two.Lines -join '') -eq $long) 'wrapping loses no characters'
$never = 'A' * 200 + '.pdf'
$three = Split-FixItNameLines -Name $never -MaxWidth 300 -Measure $m10
Assert (@($three.Lines).Count -eq 2 -and $three.Truncated -and $three.Lines[1].EndsWith('...') -and ([int](& $m10 $three.Lines[1])) -le 300) 'a name with no break points is cut anywhere, ends in ... only past two lines, and fits'
$noBreak = Split-FixItNameLines -Name ('B' * 45) -MaxWidth 300 -Measure $m10
Assert (@($noBreak.Lines).Count -eq 2 -and -not $noBreak.Truncated -and (($noBreak.Lines -join '') -eq ('B' * 45))) 'a name that fits in two lines gets no ellipsis'
$l1 = Get-FixItFileRowLayout -NameLines 1
Assert ($l1.NameY -eq 4 -and $l1.NameH -eq 22 -and $l1.InfoY -eq 28 -and $l1.BtnY -eq 52 -and $l1.RowH -eq 96) 'a one-line row is the old 96 unit row'
foreach ($lh in @(18, 20, 24, 30)) { foreach ($nl in 1, 2, 3) {
    $rl = Get-FixItFileRowLayout -NameLines $nl -LineH $lh
    Assert (($rl.NameY + $rl.NameH) -le $rl.InfoY -and ($rl.InfoY + $rl.InfoH) -le $rl.BtnY -and ($rl.BtnY + $rl.BtnH) -le $rl.RowH) "row with $nl name lines at line height ${lh}: name, info and button do not overlap"
    if ($nl -gt 1) { Assert ($rl.NameH -ge [math]::Ceiling($nl * $lh)) "row with $nl name lines at line height ${lh}: the name area holds every line" }
} }
foreach ($S in $scales) { foreach ($hpx in @(0, 16, 20, 40, 60, 100)) {
    $t = Get-FixItFilesTopLayout -NoteHeightPx $hpx -Scale $S
    Assert ($t.NoteH * $S -ge $hpx -and $t.PanelY -ge $t.NoteY + $t.NoteH -and ($t.PanelY + $t.PanelH) -le 604 -and $t.PanelH -ge 120) "note of $hpx px at scale ${S}: the note is tall enough, the list starts below it and ends inside the window"
} }
$t0 = Get-FixItFilesTopLayout -NoteHeightPx 20 -Scale 1.0
Assert ($t0.NoteH -eq 24 -or $t0.NoteH -eq 22) 'a one-line note keeps almost the old height'
$fnr = Get-Fn 'Show-FixItFilesResults'
Assert ($fnr -match 'Split-FixItNameLines' -and $fnr -match 'Get-FixItFileRowLayout' -and $fnr -match '\$y \+= \$rl\.RowH' -and $fnr -notmatch '\$y \+= 96') 'the result rows are stacked by their measured height'
Assert ($fnr -match 'UseMnemonic = \$false' -and $fnr -match 'SetToolTip') 'names show every character (no & loss) and the full name is in a tooltip'
Assert ((Get-Fn 'Measure-FixItText') -match 'WordBreak') 'text is measured with word wrap'
Assert (([regex]::Matches($srcText, 'FilesMsg\.Text =')).Count -eq 0) 'the note is only ever set through Set-FixItFilesMessage (which resizes it)'
Assert ($srcText.Contains("'Your newest files. Type a name above to search.{0}'")) 'the note is short and plain'

# ================================================================ 4. the "?" help on the main buttons
Section 'The ? description on every main button'
$jargon = 'registry|DNS|DHCP|DISM|\bSFC\b|proxy|LoadBehavior|PowerShell|script|winsock|TCP|cache|executable'
$keysSeen = @{}
foreach ($c in Get-Layouts) {
    $keys = @(Get-FixItMainTileKeys -Layout $c.Layout)
    Assert ($keys.Count -ge 6 -and ($keys -contains 'Scam') -and ($keys -contains 'Screen') -and ($keys -contains 'Report')) "$($c.Name): the main buttons include the scam button and the two bottom buttons"
    foreach ($k in $keys) { $keysSeen[$k] = $true; $h = Get-FixItHelpText -Key $k; Assert ($null -ne $h -and $h.Title -and $h.Text) "$($c.Name): $k has a description" }
}
Assert ($keysSeen.Count -eq 12) ('all 12 main buttons were found (' + $keysSeen.Count + ')')
foreach ($k in @($keysSeen.Keys)) {
    $h = Get-FixItHelpText -Key $k
    $sent = @([regex]::Split($h.Text.Trim(), '(?<=[.!?])\s+') | Where-Object { $_ })
    Assert ($sent.Count -ge 2 -and $sent.Count -le 4) "$k : 2 to 4 sentences (has $($sent.Count))"
    Assert ($h.Text -notmatch $jargon) "$k : no technical words"
    Assert ($h.Text -match "\b(never|not|nothing|no)\b" ) "$k : says what it leaves alone"
    if (@('Printer', 'Acrobat', 'Outlook', 'Network', 'Slow', 'Sound', 'Browser', 'WinUpdate', 'OneDrive') -contains $k) { Assert ($h.Text -match 'ask|say yes') "$k : says whether it asks first" }
    Assert ($h.Text.Length -le 700) "$k : short enough to read"
}
Assert ($null -eq (Get-FixItHelpText -Key 'Nope') -and $null -eq (Get-FixItHelpText -Key '')) 'an unknown key has no description'
foreach ($nav in @('History', 'Files', 'Install', 'Privacy', 'YourName', 'Share', 'Simple', 'BigText', 'Contrast', 'Guides')) { Assert ($null -eq (Get-FixItHelpText -Key $nav)) "$nav (nav, footer or toggle) has no ? description" }
# geometry
$tileKinds = @(@{ N = 'card'; W = 217; H = 112 }, @{ N = 'scam'; W = 679; H = 72 }, @{ N = 'wide'; W = 332; H = 76 })
foreach ($S in $scales) { foreach ($tk in $tileKinds) {
    $w = [int][math]::Round($tk.W * $S); $hh = [int][math]::Round($tk.H * $S)
    $g = Get-FixItHelpDotRect -TileW $w -TileH $hh -Scale $S
    Assert ($g.HitX -ge 0 -and $g.HitY -ge 0 -and ($g.HitX + $g.HitW) -le $w -and ($g.HitY + $g.HitH) -le $hh) "$($tk.N) at ${S}: the ? is inside the tile"
    Assert ((Test-FixItHelpHit -X ($g.X + [int]($g.D / 2)) -Y ($g.Y + [int]($g.D / 2)) -TileW $w -TileH $hh -Scale $S)) "$($tk.N) at ${S}: the middle of the circle is a ? click"
    Assert (-not (Test-FixItHelpHit -X ([int]($w / 2)) -Y ([int]($hh / 2)) -TileW $w -TileH $hh -Scale $S)) "$($tk.N) at ${S}: the middle of the tile is NOT a ? click (it runs the fix)"
    Assert (-not (Test-FixItHelpHit -X ($g.HitX - 1) -Y ($g.Y) -TileW $w -TileH $hh -Scale $S) -and -not (Test-FixItHelpHit -X ($g.X) -Y ($g.HitY + $g.HitH) -TileW $w -TileH $hh -Scale $S)) "$($tk.N) at ${S}: a click just outside the hit area is not a ? click"
    if ($tk.N -eq 'card') {
        Assert (($g.HitX) -ge [math]::Ceiling(50 * $S) -and ($g.HitY + $g.HitH) -le [math]::Floor(56 * $S)) 'card: the ? does not touch the icon (x 14-50, y 12-48) or the title (from y 56)'
    } else {
        $rsv = Get-FixItHelpTextReserve -Scale $S
        Assert (($w - $rsv) -le $g.HitX -and ($g.HitY + $g.HitH) -le [math]::Floor(37 * $S)) "$($tk.N) at ${S}: the title line stops before the ? and the subtitle starts below it"
    }
} }
$addFn = Get-Fn 'Add-FixItHelpDot'
Assert ($addFn -match 'New-Object System\.Windows\.Forms\.Button' -and $addFn -match '\$Tile\.Controls\.Add\(\$d\)') 'the ? is its own little button on top of the tile, so a click in it never reaches the tile''s click'
Assert ($addFn -match "AccessibleName = 'What does this button do\?'") 'the ? is named What does this button do? for screen readers'
Assert ($addFn -match 'Add_HelpRequested' -and $addFn -match 'Add_MouseEnter' -and $addFn -match 'Add_Paint') 'F1 opens it, and it has a hover state and its own drawing'
Assert ($addFn -match 'TabStop = \$false') 'the ? does not add a Tab stop of its own (F1 on the tile reaches it)'
$showFn = Get-Fn 'Show-FixItHelp'
Assert ($showFn -match 'Write-FixItLog \(''Help "\?" clicked') '? clicks are logged'
Assert ($showFn -notmatch 'Invoke-GuiButton' -and $showFn -notmatch 'Invoke-FixItAction' -and (Get-Fn 'Show-FixItHelpForm') -notmatch 'Invoke-GuiButton') 'opening the description never starts a fix'
$win = Get-Fn 'Show-FixItWindow'; if (-not $win) { $win = $srcText }
Assert ((([regex]::Matches($srcText, 'Add-FixItHelpDot -Tile')).Count) -eq 4) 'the ? is added in exactly the four main button places (grid, scam, two bottom) and nowhere else'
Assert ($srcText -match "Add-FixItHelpDot -Tile \`$scam -Key 'Scam'" -and $srcText -match "Add-FixItHelpDot -Tile \`$p1 -Key 'Screen'" -and $srcText -match "Add-FixItHelpDot -Tile \`$p2 -Key 'Report'") 'scam, screen and report buttons get one'
$paintFn = Get-Fn 'Invoke-FixItTilePaint'
Assert ($paintFn -match 'Get-FixItHelpTextReserve') 'wide tile titles leave room for the ?'
$dotPaint = Get-Fn 'Invoke-FixItHelpDotPaint'
Assert ($dotPaint -match 'HighContrast' -and $dotPaint -match 'Hover') 'the ? is drawn for High contrast and has a hover look'

# ================================================================ 5. Install an app
Section 'Install an app: 12 apps, sections, description, scrolling'
$ap = Get-Content (Join-Path $root 'apps.json') -Raw | ConvertFrom-Json
$wantIds = 'Google.Chrome', 'Zoom.Zoom', 'Discord.Discord', 'VideoLAN.VLC', 'Spotify.Spotify', 'Apple.iTunes', 'OBSProject.OBSStudio', 'Audacity.Audacity', 'Adobe.Acrobat.Reader.64-bit', '7zip.7zip', 'Google.GoogleDrive', 'Dropbox.Dropbox'
Assert (@($ap).Count -eq 12 -and (@($ap.id) -join ',') -eq ($wantIds -join ',')) 'apps.json has the 12 apps'
foreach ($a in $ap) {
    Assert ([string]$a.description -match $script:AppDescriptionPattern -and ([string]$a.description).Length -le 70) "$($a.name): has a plain one-line description"
    Assert ([string]$a.section -match $script:AppSectionPattern) "$($a.name): has a section"
}
Assert ((@($ap | Where-Object { $null -ne $_.PSObject.Properties['elevationProhibited'] -and $_.PSObject.Properties['elevationProhibited'].Value -eq $true }).id -join ',') -eq 'Spotify.Spotify') 'only Spotify is marked elevationProhibited'
$secNames = @{ 'Browsers and chat' = 'Google.Chrome,Zoom.Zoom,Discord.Discord'; 'Media and photos' = 'VideoLAN.VLC,Spotify.Spotify,Apple.iTunes,OBSProject.OBSStudio,Audacity.Audacity'; 'Files and office' = 'Adobe.Acrobat.Reader.64-bit,7zip.7zip,Google.GoogleDrive,Dropbox.Dropbox' }
foreach ($k in $secNames.Keys) { Assert ((@($ap | Where-Object { $_.section -eq $k }).id -join ',') -eq $secNames[$k]) "section $k has the right apps" }
$def = @($script:DefaultApps)
Assert ($def.Count -eq 12 -and (@($def | ForEach-Object { $_['id'] }) -join ',') -eq ($wantIds -join ',')) 'the built-in list has the same 12 apps in the same order'
$same = $true
for ($i = 0; $i -lt 12; $i++) { $d = $def[$i]; $j = $ap[$i]; if ($d['name'] -ne $j.name -or $d['section'] -ne $j.section -or $d['description'] -ne $j.description -or ([bool]($d.ContainsKey('elevationProhibited')) -ne [bool]($j.PSObject.Properties['elevationProhibited']))) { $same = $false } }
Assert $same 'the built-in list matches apps.json (names, sections, descriptions, Spotify flag)'
$conv = ConvertTo-FixItApp ([pscustomobject]@{ id = 'A.B'; name = 'App B'; section = 'Games'; description = 'Plays games.'; elevationProhibited = $true })
Assert ($conv.Id -eq 'A.B' -and $conv.Section -eq 'Games' -and $conv.Description -eq 'Plays games.' -and $conv.ElevationProhibited) 'an entry with every field is read'
$conv = ConvertTo-FixItApp ([pscustomobject]@{ id = 'A.B'; name = 'App B' })
Assert ($conv.Section -eq '' -and $conv.Description -eq '' -and -not $conv.ElevationProhibited) 'section, description and the flag are optional'
$conv = ConvertTo-FixItApp ([pscustomobject]@{ id = 'A.B'; name = 'App B'; section = '<b>x</b>'; description = '<script>'; elevationProhibited = 'yes' })
Assert ($null -ne $conv -and $conv.Section -eq '' -and $conv.Description -eq '' -and -not $conv.ElevationProhibited) 'a section or description that looks wrong is dropped; only a real true turns the flag on'
Assert ($null -eq (ConvertTo-FixItApp ([pscustomobject]@{ id = 'bad id; calc'; name = 'x' }))) 'an id that looks wrong is still refused'
$grp = @(Get-FixItAppSections -Apps @(
    [pscustomobject]@{ Id = 'a.a'; Name = 'A'; Section = '' }, [pscustomobject]@{ Id = 'b.b'; Name = 'B'; Section = 'Zeta' },
    [pscustomobject]@{ Id = 'c.c'; Name = 'C'; Section = 'Alpha' }, [pscustomobject]@{ Id = 'd.d'; Name = 'D'; Section = 'zeta' }, [pscustomobject]@{ Id = 'e.e'; Name = 'E' }))
Assert ($grp.Count -eq 3 -and $grp[0].Section -eq 'Zeta' -and @($grp[0].Apps).Count -eq 2 -and $grp[1].Section -eq 'Alpha' -and $grp[2].Section -eq 'Other' -and @($grp[2].Apps).Count -eq 2) 'sections keep their first-seen order and apps with no section go under Other at the end'
$sec12 = @(Get-FixItAppSections -Apps @(Get-FixItApprovedApps))
Assert ($sec12.Count -eq 3 -and ($sec12.Section -join '|') -eq 'Browsers and chat|Media and photos|Files and office' -and (@($sec12 | ForEach-Object { @($_.Apps).Count }) -join ',') -eq '3,5,4') 'the real list shows three sections: 3, 5 and 4 apps, none under Other'
Assert (@(Get-FixItAppSections -Apps @()).Count -eq 0) 'an empty list has no sections'
# window size: never taller than a 768 pixel screen; the list scrolls
foreach ($S in $scales) {
    $rows = 0; foreach ($sc in $sec12) { $rows += 40 + 6; foreach ($a in $sc.Apps) { $rows += (Get-FixItAppRowLayout -DescHeight 18).RowH } }
    foreach ($wa in @(728, 768, 1040)) {
        $z = Get-FixItAppsDialogSize -ContentUnits $rows -Scale $S -WorkingAreaHeightPx $wa
        Assert (($z.ClientH + 80) -le [math]::Max($wa, 380) -and $z.PanelH -ge 120 -and ($z.PanelY + $z.PanelH) -le $z.ClientH) "scale ${S}, screen ${wa}: the window fits the screen and the list panel fits the window"
    }
    $z768 = Get-FixItAppsDialogSize -ContentUnits $rows -Scale 1.0 -WorkingAreaHeightPx 728
    Assert ($z768.Scrolls -and $z768.ClientH -le 648) 'a 768 pixel screen: the 12 apps do not fit, so the list scrolls inside a window of at most 648 px'
}
$zs = Get-FixItAppsDialogSize -ContentUnits 100 -Scale 1.0 -WorkingAreaHeightPx 1040
Assert (-not $zs.Scrolls -and $zs.ClientH -eq 184) 'a short list needs no scrolling and the window is only as tall as it needs'
foreach ($dh in 0, 18, 36, 54) { $rl = Get-FixItAppRowLayout -DescHeight $dh; Assert (($rl.DescY + $rl.DescH) -le $rl.RowH -and $rl.RowH -ge 64 -and ($rl.BtnY + $rl.BtnH) -le $rl.RowH -and $rl.BtnY -ge 0) "app row with a description ${dh} units high: name, description and Install button fit without overlap" }
$dlg = Get-Fn 'Show-FixItAppsDialog'
Assert ($dlg -match 'AutoScroll = \$true' -and $dlg -match 'Get-FixItAppSections' -and $dlg -match 'Get-FixItAppsDialogSize' -and $dlg -match 'WorkingArea') 'the window puts the rows in a scrolling panel, grouped by section, and caps its height by the screen'
Assert ($dlg -match 'UiHighContrast' -and $dlg -match 'UiScale' -and $dlg -match 'Measure-FixItText') 'Big text and High contrast are handled and descriptions are measured'
Assert ($dlg -notmatch '120 \+ 60') 'the old fixed-height window is gone'
# Spotify is installed from a normal (not administrator) window and never through the admin helper
$inst = Get-Fn 'Invoke-InstallApp'
Assert ($inst -match 'ElevationProhibited' -and $inst -match 'Test-FixItAdmin') 'an app that refuses administrator rights is checked before installing'
Assert ((Get-Fn 'Install-FixItApp') -notmatch 'Invoke-AdminPart|RunAs|Start-Process') 'the install itself never starts an administrator helper'
Assert ($inst -notmatch 'Invoke-AdminPart|RunAs') 'Invoke-InstallApp never asks for administrator rights'
$origNative = ${function:Invoke-FixItNative}; $origWinget = ${function:Test-FixItWinget}; $origAdmin = ${function:Test-FixItAdmin}
$script:V = @{ Calls = (New-Object System.Collections.ArrayList); Admin = $false }
function Test-FixItWinget { return $true }
function Test-FixItAdmin { return $script:V.Admin }
function Invoke-FixItNative {
    param([string]$File, [string[]]$Arguments = @(), [switch]$Live)
    [void]$script:V.Calls.Add("$File $($Arguments -join ' ')")
    if ($Arguments[0] -eq 'list') { return [pscustomobject]@{ ExitCode = 1; Output = 'No installed package found' } }
    return [pscustomobject]@{ ExitCode = 0; Output = '' }
}
$oldManifest = $script:ManifestUrl; $script:ManifestUrl = ''
$oldConfirm = ${function:Confirm-FixItStep}
$script:Asked = New-Object System.Collections.ArrayList
function Confirm-FixItStep { param([string]$Question) [void]$script:Asked.Add($Question); return $true }
$script:V.Admin = $true
$r = Invoke-InstallApp -AppName 'Spotify'
Assert (-not $r.Ok -and $r.Title -eq 'Open me the usual way' -and @($script:V.Calls | Where-Object { $_ -like 'winget.exe install*' }).Count -eq 0 -and $script:Asked.Count -eq 0) 'Spotify from an administrator window: plain message, nothing installed, nothing asked'
$script:V.Admin = $false
$r = Invoke-InstallApp -AppName 'Spotify'
Assert ($r.Ok -and @($script:V.Calls | Where-Object { $_ -eq 'winget.exe install --id Spotify.Spotify --exact --source winget --silent --accept-package-agreements --accept-source-agreements' }).Count -eq 1) 'Spotify from a normal window: winget with the exact id'
Assert ($script:Asked.Count -eq 1 -and $script:Asked[0] -match 'just for you' -and $script:Asked[0] -notmatch 'ask for permission') 'the question for Spotify does not promise a permission box'
$script:V.Admin = $true; $script:V.Calls.Clear(); $script:Asked.Clear()
$r = Invoke-InstallApp -AppName 'Dropbox'
Assert ($r.Ok -and @($script:V.Calls | Where-Object { $_ -like 'winget.exe install --id Dropbox.Dropbox*' }).Count -eq 1) 'another app is still installed from an administrator window'
Set-Item function:Invoke-FixItNative $origNative; Set-Item function:Test-FixItWinget $origWinget; Set-Item function:Test-FixItAdmin $origAdmin; Set-Item function:Confirm-FixItStep $oldConfirm
$script:ManifestUrl = $oldManifest
# the published list carries the same fields
$pub = [IO.File]::ReadAllText((Join-Path $root 'tools\Publish-FixIt.ps1'))
Assert ($pub -match "section" -and $pub -match 'description' -and $pub -match 'elevationProhibited') 'the publish script validates and writes section, description and elevationProhibited'
Assert ($pub -match "\{0,39\}" -and $pub -match 'must list between 1 and 20') 'the publish script checks the section text and the 20 app limit'

# ================================================================ 6. guide steps are never clipped
Section 'Guide steps: every step gets the height of its wrapped text'
$gj = Get-Content (Join-Path $root 'guides.json') -Raw | ConvertFrom-Json
$allSteps = @(); foreach ($g in $gj.guides) { foreach ($st in @($g.steps)) { $allSteps += [pscustomobject]@{ Guide = [string]$g.id; Text = [string]$st } } }
Assert ($allSteps.Count -gt 40) ('read every step of every guide (' + $allSteps.Count + ')')
$scan = @($allSteps | Where-Object { $_.Text -like 'Click the Start button, type Scan, and open the app called Scan*' })
Assert ($scan.Count -ge 1 -and $scan[0].Text.EndsWith('(Or use the scan button on your printer.)')) 'the Scan a document step is complete in guides.json'
foreach ($st in $allSteps) {
    $o = ([regex]::Matches($st.Text, '\(')).Count; $c = ([regex]::Matches($st.Text, '\)')).Count
    Assert ($o -eq $c -and $st.Text -match '[.!?)]$') "guide $($st.Guide): a step is complete (balanced brackets, ends with punctuation): $($st.Text.Substring(0, [math]::Min(30, $st.Text.Length)))"
}
# pretend text measuring: greedy word wrap, character width = 0.50 or 0.60 of the font size (a narrow and a wide font), line height 1.4 x size
function New-WrapMeasure {
    param([double]$FontPx, [double]$CharW, [double]$LineH)
    $cw = $FontPx * $CharW; $lh = [math]::Ceiling($FontPx * $LineH)
    return { param($t, $w) $per = [math]::Max(1, [int][math]::Floor($w / $cw)); $lines = 1; $cur = 0
        foreach ($word in ($t -split ' ')) { $len = $word.Length; if ($cur -eq 0) { $cur = $len } elseif (($cur + 1 + $len) -le $per) { $cur += 1 + $len } else { $lines++; $cur = $len } }
        [int]($lines * $lh) }.GetNewClosure()
}
function Get-WrapLines { param([string]$Text, [double]$FontPx, [double]$CharW, [int]$Width) $cw = $FontPx * $CharW; $per = [math]::Max(1, [int][math]::Floor($Width / $cw)); $lines = 1; $cur = 0
    foreach ($word in ($Text -split ' ')) { $len = $word.Length; if ($cur -eq 0) { $cur = $len } elseif (($cur + 1 + $len) -le $per) { $cur += 1 + $len } else { $lines++; $cur = $len } }
    return $lines }
$worst = 0; $checked = 0
foreach ($S in $scales) { foreach ($cwid in @(0.50, 0.60)) {
    $fpx = 19 * $S; $lineH = [int][math]::Ceiling($fpx * 1.4); $tw = [int](540 * $S)
    foreach ($g in $gj.guides) {
        $meas = New-WrapMeasure -FontPx $fpx -CharW $cwid -LineH 1.4
        $lay = Get-FixItGuideStepLayout -Steps @($g.steps) -Scale $S -TextWidth $tw -LineHeight $lineH -Measure $meas
        $steps = @($g.steps)
        Assert ($lay.Rows.Count -eq $steps.Count) "guide $($g.id) at ${S}: one row per step"
        for ($k = 0; $k -lt $steps.Count; $k++) {
            $r = $lay.Rows[$k]
            $need = (Get-WrapLines -Text ([string]$steps[$k]) -FontPx $fpx -CharW $cwid -Width $tw) * $lineH   # lines at the label's REAL width
            $checked++
            if ($r.Height -lt $need) { Assert $false "guide $($g.id) step $($k + 1) at scale ${S}: height $($r.Height) covers $need" }
            if ($r.Height -lt $need + 4) { $worst++ }
            if ($k -gt 0) { $p = $lay.Rows[$k - 1]; if (($r.Y) -lt ($p.TextY + $p.Height)) { Assert $false "guide $($g.id) step $($k + 1) at scale ${S}: overlaps the step above" } }
        }
        $last = $lay.Rows[$lay.Rows.Count - 1]
        if ($lay.TotalHeight -lt ($last.TextY + $last.Height)) { Assert $false "guide $($g.id): total height covers the last step" }
    }
} }
Assert ($checked -gt 500) ("checked $checked steps across all guides, 6 scales (Big text and the normal sizes) and a narrow and a wide font")
Assert ($worst -eq 0) 'every step has at least a few pixels to spare below its last line'
# the longest steps, by name
$longest = @($allSteps | Sort-Object { $_.Text.Length } -Descending | Select-Object -First 5)
foreach ($ls in $longest) {
    $fpx = 19.0; $lineH = [int][math]::Ceiling($fpx * 1.4)
    $lay = Get-FixItGuideStepLayout -Steps @($ls.Text) -Scale 1.0 -TextWidth 540 -LineHeight $lineH -Measure (New-WrapMeasure -FontPx $fpx -CharW 0.55 -LineH 1.4)
    $lines = Get-WrapLines -Text $ls.Text -FontPx $fpx -CharW 0.55 -Width 540
    Assert ($lines -ge 2 -and $lay.Rows[0].Height -ge $lines * $lineH + 8 -and $lay.Rows[0].Lines -ge $lines) "longest step ($($ls.Guide), $($ls.Text.Length) characters): $lines lines, height $($lay.Rows[0].Height) covers them with padding"
}
$lay1 = Get-FixItGuideStepLayout -Steps @('Short.') -Scale 1.0 -TextWidth 540 -LineHeight 26 -Measure { param($t, $w) 26 }
Assert ($lay1.Rows[0].Height -eq 44) 'a one-line step keeps the old minimum height'
$guideFn = Get-Fn 'Show-FixItGuideSteps'
Assert ($guideFn -match 'Get-FixItGuideStepLayout' -and $guideFn -match 'Measure-FixItText') 'the guide window sizes every step from its measured wrapped text'
Assert ($guideFn -notmatch 'Size\(\$tw, 0\)' -and $guideFn -notmatch 'NoPadding') 'the old measuring (a zero-height box and no padding, which under-measured) is gone'
Assert ($guideFn -match 'UseMnemonic = \$false' -and $guideFn -match 'AutoScroll = \$true') 'step text is shown as written (no & loss) and long guides scroll'
Assert ((Get-Fn 'Measure-FixItText') -match 'WordBreak') 'steps are measured with word wrap'

# ================================================================ 7. program file
Section 'The program file'
$bytes = [IO.File]::ReadAllBytes($src)
Assert (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'no byte order mark'
Assert (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'plain ASCII only'
Assert ($perr.Count -eq 0) 'the program has no syntax errors'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('Passed: ' + $script:Pass + '  Failed: ' + $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
