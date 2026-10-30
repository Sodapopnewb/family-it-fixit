<#
ScreenCheck-Report.ps1  -  joins the findings.json files of all screen-check runs (one per scale and mode) into one readable report:
findings.md (for people) and findings.json (for machines). Exit code 1 when there is any finding or a run is missing.
Usage:  pwsh -File tools/ScreenCheck-Report.ps1 -InDir <folder with one sub-folder per run> -OutDir <folder> [-ExpectedRuns 9]
Works in Windows PowerShell 5.1 and PowerShell 7.
#>
param([Parameter(Mandatory = $true)][string]$InDir, [Parameter(Mandatory = $true)][string]$OutDir, [int]$ExpectedRuns = 9, [string]$Note = '')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$files = @(Get-ChildItem -Path $InDir -Recurse -Filter findings.json | Sort-Object FullName)
$runs = @()
foreach ($f in $files) { $r = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json; $r | Add-Member -NotePropertyName folder -NotePropertyValue (Split-Path -Leaf (Split-Path -Parent $f.FullName)) -Force; $runs += $r }
$runs = @($runs | Sort-Object @{ Expression = { [double]$_.scale } }, @{ Expression = { [string]$_.mode } })
$version = ''; if ($runs.Count -gt 0) { $version = [string]$runs[0].version }
$all = @(); foreach ($r in $runs) { foreach ($x in @($r.findings)) { $all += $x } }
$missing = ($runs.Count -lt $ExpectedRuns)
$sc = New-Object 'System.Collections.Generic.List[string]'
foreach ($r in $runs) { foreach ($w in @($r.windows)) { if (-not $sc.Contains([string]$w.scenario)) { $sc.Add([string]$w.scenario) } } }
foreach ($x in $all) { if (-not $sc.Contains([string]$x.scenario)) { $sc.Add([string]$x.scenario) } }
function Key { param($r) return ('{0}x {1}' -f ([double]$r.scale), [string]$r.mode) }
$md = New-Object 'System.Collections.Generic.List[string]'
$md.Add('# Family Fix-It screen check')
$md.Add('')
$verdict = 'PASS'; if ($all.Count -gt 0 -or $missing) { $verdict = 'FAIL' }
$md.Add(('**Version {0} - {1}** - {2} windows pictured across {3} runs, **{4} finding(s)**.' -f $version, $verdict, (@($runs | ForEach-Object { @($_.windows).Count } | Measure-Object -Sum).Sum), $runs.Count, $all.Count))
if ($missing) { $md.Add(''); $md.Add(('**Only {0} of {1} runs delivered a result** - a run crashed or hung. Open that job in the Actions tab.' -f $runs.Count, $ExpectedRuns)) }
if ($Note) { $md.Add(''); $md.Add($Note) }
$md.Add('')
$md.Add('## Runs')
$md.Add('')
$md.Add('| Scale | Mode | Effective UI scale | Screen | Windows pictured | Findings |')
$md.Add('|---|---|---|---|---|---|')
foreach ($r in $runs) { $md.Add(('| {0}x | {1} | {2} | {3} | {4} | {5} |' -f $r.scale, $r.mode, $r.effective_ui_scale, $r.screen, @($r.windows).Count, $r.finding_count)) }
$md.Add('')
$md.Add('## Window by run')
$md.Add('')
$hdr = '| Window |'; $sep = '|---|'
foreach ($r in $runs) { $hdr += (' ' + (Key $r) + ' |'); $sep += '---|' }
$md.Add($hdr); $md.Add($sep)
foreach ($s in $sc) {
    $line = ('| {0} |' -f $s)
    foreach ($r in $runs) {
        $has = @(@($r.windows) | Where-Object { [string]$_.scenario -eq $s }).Count -gt 0
        $n = @(@($r.findings) | Where-Object { [string]$_.scenario -eq $s }).Count
        if ($n -gt 0) { $line += (' FAIL ({0}) |' -f $n) } elseif ($has) { $line += ' ok |' } else { $line += ' - |' }
    }
    $md.Add($line)
}
$md.Add('')
$md.Add('"-" means that window is not drawn in that run (the pop-up watcher toast and tray icon are checked once, at 100% normal, because they use the real screen scale).')
$md.Add('')
if ($all.Count -gt 0) {
    $md.Add('## Findings')
    $md.Add('')
    foreach ($s in $sc) {
        $mine = @($all | Where-Object { [string]$_.scenario -eq $s })
        if ($mine.Count -eq 0) { continue }
        $md.Add(('### {0}' -f $s)); $md.Add('')
        foreach ($x in $mine) { $md.Add(('- **{0}x {1}** - {2} - {3}: {4}' -f $x.scale, $x.mode, $x.type, $x.control, $x.detail)) }
        $md.Add('')
    }
    $md.Add('Pictures with the problem circled in red are the `*_FINDINGS.png` files in each run''s `screenshots` folder.')
    $md.Add('')
}
$tray = @($runs | Where-Object { $null -ne $_.tray })
if ($tray.Count -gt 0) {
    $t = $tray[0].tray
    $md.Add('## Pop-up watcher tray icon')
    $md.Add('')
    $md.Add(('- Visible: {0}' -f $t.visible)); $md.Add(('- Hover text: {0}' -f $t.hover_text)); $md.Add(('- Right-click menu: {0}' -f ((@($t.menu_items)) -join ' / '))); $md.Add(('- Look in the taskbar (information only): {0}' -f $t.taskbar))
    $md.Add('')
}
$md.Add('## How this was measured, and what it cannot see')
$md.Add('')
foreach ($l in @(
    'The program is loaded as a library and each window is opened by a script, with no one clicking. Text is measured with Windows'' own text measuring (TextRenderer and the control''s own GetPreferredSize), tile buttons are re-measured using the same rectangles they are painted with, and a pixel check confirms something is really drawn where each label should be.',
    '**Scale is simulated:** the program draws everything as "base size x UiScale", so each run sets UiScale to 1.0 / 1.5 / 2.0 (x1.25 more for "Big text") in a fresh process. Real Windows display scaling was NOT changed (it needs a sign-out), so Windows-drawn parts (title bars, message-box frames, scroll bars, drop-down lists, the system tray) stay at 100% size.',
    'Message boxes (update messages, "Fix result" boxes) are drawn by Windows, not the program: they are pictured but their text cannot be measured.',
    'The runner has no touch screen, no second monitor, no real graphics card and no real tray with a person looking at it: tray visibility is confirmed from the program''s own icon object plus a best-effort look at the taskbar.',
    'Fonts: the runner has Segoe UI like a family PC, but a family PC with a different Windows language, extra-large Windows text size, or a custom font could differ.',
    '"High contrast" is the program''s own black-and-yellow setting, not the Windows high-contrast theme.')) { $md.Add('- ' + $l) }
[IO.File]::WriteAllText((Join-Path $OutDir 'findings.md'), ($md -join "`n"), (New-Object Text.UTF8Encoding($false)))
$out = [ordered]@{ version = $version; verdict = $verdict; runs_expected = $ExpectedRuns; runs_found = $runs.Count; finding_count = $all.Count
    runs = @($runs | ForEach-Object { [ordered]@{ scale = $_.scale; mode = $_.mode; screen = $_.screen; windows = @($_.windows).Count; findings = $_.finding_count } }); findings = $all }
[IO.File]::WriteAllText((Join-Path $OutDir 'findings.json'), ($out | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
Write-Host ($md -join "`n")
if ($verdict -eq 'FAIL') { exit 1 }
exit 0
