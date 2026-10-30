<#
Publish-FixIt.ps1  -  for Trey only (not used by the family).
Builds a folder that is ready to commit to the public GitHub repo:
  - copies the tool files (and the program icon FamilyFixIt.ico, listed under "assets" in manifest.json with its SHA-256)
  - fills in your GitHub name on the address lines (and in the README) that say <OWNER> (use -Owner); the checks inside the scripts never contain that literal text
  - writes manifest.json (version + SHA-256 of each file the family's copy downloads, plus the approved
    app list from apps.json for the 'Install an app' button, and the help guides from guides.json for 'Help me with...')
  - refuses to continue if it finds something that looks like a secret or personal info
  - builds Install-FamilyFixIt.zip (Install-FamilyFixIt.cmd + Install-FixIt.ps1) for a GitHub Release
Nothing is uploaded. You commit and push the output folder yourself.

Example:  pwsh ./tools/Publish-FixIt.ps1 -Owner your-github-name
#>
param(
    [string]$Owner,
    [string]$OutDir,
    [string]$SourceDir,
    [string]$ReleaseDir
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $SourceDir) { $SourceDir = Split-Path -Parent $PSScriptRoot }
if (-not $OutDir) { $OutDir = Join-Path $SourceDir 'dist' }
if (-not $ReleaseDir) { $ReleaseDir = Join-Path (Split-Path -Parent $OutDir) 'release' }

$runtimeFiles = @('FamilyFixIt.ps1', 'Start-FixIt.cmd', 'README.md', 'guides.json')   # what the family's copy downloads
$assetFiles = @('FamilyFixIt.ico')   # pictures: listed under "assets" in manifest.json (not "files"; older versions refuse unknown names in "files")
$installerFiles = @('Install-FixIt.ps1', 'Install-FamilyFixIt.cmd')   # the bootstrap installer (also zipped for the release)
$extraFiles = @('.gitattributes', '.gitignore', 'apps.json', 'tools/Publish-FixIt.ps1', 'tests/Test-FixIt.ps1', 'tests/Test-FixIt-V234.ps1', 'tests/Test-FixIt-V235.ps1', 'tests/Test-FixIt-V236.ps1', 'tests/Test-FixIt-V237.ps1', 'tests/Test-FixIt-V238.ps1', 'tests/Test-FixIt-V239.ps1', 'tests/Test-FixIt-V2310.ps1', 'tests/Test-FixIt-V2311.ps1') + $installerFiles

$main = Join-Path $SourceDir 'FamilyFixIt.ps1'
$m = [regex]::Match([IO.File]::ReadAllText($main), "FixItVersion = '(\d+\.\d+\.\d+)'")
if (-not $m.Success) { throw 'Could not find the version number in FamilyFixIt.ps1' }
$version = $m.Groups[1].Value

if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir | Out-Null
foreach ($f in ($runtimeFiles + $assetFiles + $extraFiles)) {
    $src = Join-Path $SourceDir $f
    if (-not (Test-Path -LiteralPath $src)) { throw ('Missing file: ' + $f) }
    $dest = Join-Path $OutDir $f
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dest
}

$placeholder = '<OWNER>'
if ($Owner) {
    if ($Owner -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$') { throw 'That does not look like a GitHub user or organization name.' }
    # Only the address lines change (https://raw.githubusercontent.com/<OWNER>/... and https://github.com/<OWNER>/...).
    # The checks inside the scripts build the placeholder from two pieces, so they are never rewritten and keep working.
    $urlPattern = '(https://(?:raw\.githubusercontent\.com|github\.com)/)' + [regex]::Escape($placeholder) + '/'
    foreach ($f in (@('FamilyFixIt.ps1', 'README.md') + $installerFiles)) {
        $dest = Join-Path $OutDir $f
        $bytes = [IO.File]::ReadAllBytes($dest)
        $text = [regex]::Replace([Text.Encoding]::UTF8.GetString($bytes), $urlPattern, ('${1}' + $Owner + '/'))
        if ($f -eq 'README.md') { $text = $text.Replace($placeholder, $Owner) }   # the docs text: fill the name in everywhere
        [IO.File]::WriteAllBytes($dest, [Text.Encoding]::UTF8.GetBytes($text))
    }
    foreach ($f in @('FamilyFixIt.ps1', 'Install-FixIt.ps1', 'Install-FamilyFixIt.cmd', 'README.md')) {
        if ([IO.File]::ReadAllText((Join-Path $OutDir $f)).Contains($placeholder)) { throw ('A <OWNER> placeholder is still in ' + $f + ' after filling in the name.') }
    }
    Write-Host ('Set the update and installer addresses to use GitHub name: ' + $Owner)
} else {
    Write-Warning 'No -Owner given: the update and installer addresses still say <OWNER>, so updates and the installer stay switched off until you publish with -Owner.'
}

# Safety scan: nothing secret or personal in a public repo
$bad = @()
$patterns = @(
    '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
    'ghp_[A-Za-z0-9]{20,}', 'github_pat_[A-Za-z0-9_]{20,}', 'AKIA[0-9A-Z]{12,}', '-----BEGIN [A-Z ]*PRIVATE KEY',
    '(?i)(password|secret|api[_-]?key|token)\s*[:=]\s*[''"][^''"\s]{6,}',
    '(?i)C:\\Users\\[A-Za-z0-9._-]+'
)
# The test file uses made-up addresses and C:\Users\tester paths, so it only gets the secret checks.
$secretOnly = $patterns[1..5]
foreach ($f in (Get-ChildItem -LiteralPath $OutDir -Recurse -File -Force)) {
    if ($f.Name -eq 'Publish-FixIt.ps1') { continue }   # this file holds the patterns themselves
    if ($f.Extension -eq '.ico') {   # a picture: check that it really is an icon instead of scanning it as text
        $ib = [IO.File]::ReadAllBytes($f.FullName)
        if ($ib.Length -lt 22 -or $ib.Length -gt 1MB -or $ib[0] -ne 0 -or $ib[1] -ne 0 -or $ib[2] -ne 1 -or $ib[3] -ne 0) { $bad += ($f.Name + ': is not a valid .ico file') }
        continue
    }
    $t = [IO.File]::ReadAllText($f.FullName)
    $scan = $patterns; if ($f.Name -eq 'Test-FixIt.ps1') { $scan = $secretOnly }
    foreach ($p in $scan) {
        $mm = [regex]::Match($t, $p)
        if ($mm.Success) { $bad += ('{0}: matches "{1}"' -f $f.FullName.Substring($OutDir.Length), $mm.Value) }
    }
}
if ($bad.Count -gt 0) {
    Remove-Item -LiteralPath $OutDir -Recurse -Force
    throw ("Stopped. Possible secret or personal info found:`n" + ($bad -join "`n"))
}

$entries = @()
foreach ($f in $runtimeFiles) {
    $p = Join-Path $OutDir $f
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($p))) -replace '-', '').ToLowerInvariant()
    $entries += [ordered]@{ path = $f; sha256 = $hash; size = (Get-Item -LiteralPath $p).Length }
}
$assetEntries = @()
foreach ($f in $assetFiles) {
    $p = Join-Path $OutDir $f
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($p))) -replace '-', '').ToLowerInvariant()
    $assetEntries += [ordered]@{ path = $f; sha256 = $hash; size = (Get-Item -LiteralPath $p).Length }
}
# Approved apps for 'Install an app': exact winget ids, checked here and again by the tool before it installs anything.
$appsRaw = [IO.File]::ReadAllText((Join-Path $SourceDir 'apps.json')) | ConvertFrom-Json
$apps = @()
foreach ($a in @($appsRaw)) {
    if ([string]$a.id -notmatch '^[A-Za-z0-9][A-Za-z0-9+_\-]*(\.[A-Za-z0-9+_\-]+)+$' -or [string]$a.name -notmatch '^[A-Za-z0-9][A-Za-z0-9 .,+&()\-]{0,59}$') { throw ('apps.json has an entry that is not allowed: ' + $a.id) }
    $entry = [ordered]@{ id = [string]$a.id; name = [string]$a.name }
    # section (optional): a short plain label the list is grouped under; apps without one are shown under "Other"
    $secProp = $a.PSObject.Properties['section']
    if ($null -ne $secProp -and [string]$secProp.Value -ne '') {
        if ([string]$secProp.Value -notmatch '^[A-Za-z0-9][A-Za-z0-9 &,.\-]{0,39}$') { throw ('apps.json has a section that is not allowed: ' + $a.id) }
        $entry['section'] = [string]$secProp.Value
    }
    # description (required): one plain line shown under the app's name
    $descProp = $a.PSObject.Properties['description']
    if ($null -eq $descProp -or [string]$descProp.Value -notmatch "^[A-Za-z0-9][A-Za-z0-9 .,'!&()\-]{0,89}$") { throw ('apps.json needs a plain one-line description for: ' + $a.id) }
    $entry['description'] = [string]$descProp.Value
    # elevationProhibited (optional, true or false): the installer refuses administrator rights, so it must be installed from a normal window
    $evProp = $a.PSObject.Properties['elevationProhibited']
    if ($null -ne $evProp) {
        if ($evProp.Value -isnot [bool]) { throw ('apps.json elevationProhibited must be true or false: ' + $a.id) }
        if ($evProp.Value) { $entry['elevationProhibited'] = $true }
    }
    $apps += $entry
}
if ($apps.Count -eq 0 -or $apps.Count -gt 20) { throw 'apps.json must list between 1 and 20 apps.' }
# Help guides ('Help me with...'): checked here, then also put in the manifest so a fix to a guide shows up without a program update.
$guidesRaw = [IO.File]::ReadAllText((Join-Path $SourceDir 'guides.json')) | ConvertFrom-Json
$guides = @()
$seenIds = @{}
foreach ($g in @($guidesRaw.guides)) {
    $gid = [string]$g.id; $gt = [string]$g.title
    $gs = @($g.steps | ForEach-Object { [string]$_ })
    $gk = @(); if ($g.PSObject.Properties.Name -contains 'keywords') { $gk = @($g.keywords | ForEach-Object { [string]$_ }) }
    if ($gid -notmatch '^[a-z0-9][a-z0-9-]{0,39}$' -or $seenIds.ContainsKey($gid)) { throw ('guides.json: bad or repeated id: ' + $gid) }
    if ($gt.Length -lt 1 -or $gt.Length -gt 60) { throw ('guides.json: the title must be 1 to 60 characters: ' + $gid) }
    if ($gs.Count -lt 1 -or $gs.Count -gt 15) { throw ('guides.json: a guide needs 1 to 15 steps: ' + $gid) }
    foreach ($x in $gs) { if ($x.Length -lt 1 -or $x.Length -gt 300) { throw ('guides.json: each step must be 1 to 300 characters: ' + $gid) } }
    if ($gk.Count -gt 40) { throw ('guides.json: at most 40 keywords: ' + $gid) }
    foreach ($x in $gk) { if ($x.Length -lt 1 -or $x.Length -gt 40) { throw ('guides.json: each keyword must be 1 to 40 characters: ' + $gid) } }
    foreach ($x in (@($gt) + $gs + $gk)) { if ($x -match '[\x00-\x1F\x7F]') { throw ('guides.json: control characters are not allowed: ' + $gid) } }
    $seenIds[$gid] = $true
    $guides += [ordered]@{ id = $gid; title = $gt; keywords = $gk; steps = $gs }
}
if ($guides.Count -lt 1 -or $guides.Count -gt 20) { throw 'guides.json must hold between 1 and 20 guides.' }
$manifest = [ordered]@{ name = 'family-it-fixit'; version = $version; files = $entries; assets = $assetEntries; apps = $apps; guides = $guides }
[IO.File]::WriteAllText((Join-Path $OutDir 'manifest.json'), ($manifest | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))

# The release zip: just the double-click wrapper and the installer script (the installer downloads and checks the rest).
Add-Type -AssemblyName System.IO.Compression
if (-not (Test-Path -LiteralPath $ReleaseDir)) { New-Item -ItemType Directory -Path $ReleaseDir -Force | Out-Null }
$zipPath = Join-Path $ReleaseDir 'Install-FamilyFixIt.zip'
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
$fs = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
try {
    $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in @('Install-FamilyFixIt.cmd', 'Install-FixIt.ps1')) {
            $entry = $za.CreateEntry($f, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new(2026, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $es = $entry.Open()
            try { $b = [IO.File]::ReadAllBytes((Join-Path $OutDir $f)); $es.Write($b, 0, $b.Length) } finally { $es.Dispose() }
        }
    } finally { $za.Dispose() }
} finally { $fs.Dispose() }

Write-Host ('Version {0} is ready in: {1}' -f $version, $OutDir)
Write-Host 'Next: copy that folder''s contents into your repo, commit, and push.'
Write-Host ('Installer zip for the GitHub Release: ' + $zipPath)
Write-Host 'Release asset name must stay Install-FamilyFixIt.zip so the /releases/latest/download/ link keeps working.'
