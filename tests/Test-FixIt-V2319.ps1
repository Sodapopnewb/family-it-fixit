# Version 2.3.19 tests: the familyfixit: link (familyfixit://open).
#  (1) the installer registers HKCU\Software\Classes\familyfixit for this user only;
#  (2) running the installer again writes the same keys, and a dirty key is cleaned;
#  (3) the registered command does not pass the address to PowerShell;
#  (4) familyfixit://open?fix=all, a quote/calc address, and a very long address are ignored;
#  (5) the link cannot start a repair. It opens the normal window the way the Desktop shortcut does.
#      Test mode stays the separate Start menu shortcut.
# The registry is pretended here. The opener is really started, with a stand-in for powershell.exe.
# Usage:  pwsh ./tests/Test-FixIt-V2319.ps1       (Test-FixIt.ps1 runs this one too and adds its numbers)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fixit-v2319-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:Pass = 0; $script:Fail = 0
function Assert { param([bool]$Cond, [string]$Name) if ($Cond) { $script:Pass++ } else { $script:Fail++; Microsoft.PowerShell.Utility\Write-Host ('  FAIL: ' + $Name) -ForegroundColor Red } }
function Section { param([string]$T) Microsoft.PowerShell.Utility\Write-Host ('== ' + $T) }

$inst = Join-Path $root 'Install-FixIt.ps1'
$srcPath = Join-Path $root 'FamilyFixIt.ps1'
$srcText = [IO.File]::ReadAllText($srcPath)
$instText = [IO.File]::ReadAllText($inst)
$bytes = [IO.File]::ReadAllBytes($inst)
Assert (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'the installer is plain ASCII'
Assert (([regex]::Matches($instText, "`r`n")).Count -eq ([regex]::Matches($instText, "`n")).Count) 'the installer keeps Windows line endings'
Assert ($instText -notmatch '(?i)RunAs|HKLM|Register-ScheduledTask|schtasks|Set-ExecutionPolicy|&&|\|\|') 'the installer still makes no machine-wide change'
$ver = [regex]::Match($srcText, "FixItVersion = '(\d+\.\d+\.\d+)'").Groups[1].Value
Assert ([version]$ver -ge [version]'2.3.19') 'the program is version 2.3.19 or newer'
Assert ((Get-Content (Join-Path $root 'manifest.json') -Raw) -match ('"version": "' + $ver + '"')) 'manifest.json matches the program version'
Assert ($instText -match "InstallerFiles = @\('FamilyFixIt.ps1', 'Start-FixIt.cmd', 'README.md', 'guides.json', 'FamilyFixIt.ico'\)") 'the opener is not a downloaded file (older updates refuse unknown names)'
$readme = [IO.File]::ReadAllText((Join-Path $root 'README.md'))
Assert ($readme -match 'familyfixit://open' -and $readme -match 'HKCU\\Software\\Classes\\familyfixit' -and $readme -match 'https://github.com/Sodapopnewb/family-it-fixit/releases/latest/download/Install-FamilyFixIt.zip') 'README: the link, the per-user key, and the fallback install zip'

$perr = $null; $tok = $null
$null = [Management.Automation.Language.Parser]::ParseFile($inst, [ref]$tok, [ref]$perr)
Assert ($perr.Count -eq 0) 'the installer parses'

. $inst -LibraryOnly
$script:InstallLog = Join-Path $tmp 'install.log'
$env:LOCALAPPDATA = Join-Path $tmp 'local'
New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
$dir = Join-Path $tmp 'app'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$sys = Join-Path $tmp 'sys'
$fake = Join-Path $sys 'System32\WindowsPowerShell\v1.0\powershell.exe'
New-Item -ItemType Directory -Path (Split-Path -Parent $fake) -Force | Out-Null
$cap = Join-Path $tmp 'capture.txt'
[IO.File]::WriteAllText($fake, "#!/bin/sh`n: > `"`$FIXIT_LINK_CAPTURE`"`nfor a in `"`$@`"; do printf '%s\n' `"`$a`" >> `"`$FIXIT_LINK_CAPTURE`"; done`n")
try { & chmod a+x $fake } catch { }

$savedRoot = $env:SystemRoot
$env:SystemRoot = $sys
$env:FIXIT_LINK_CAPTURE = $cap
function Get-InstallPowerShell { return $fake }

$script:Snap = $null
$script:Sets = 0
function Test-InstallRegistryPresent { return $true }
function Get-InstallLaunchLinkSnapshot { return $script:Snap }
function Set-InstallLaunchLinkSnapshot {
    param([string]$Description, [string]$Protocol, [string]$Icon, [string]$Command)
    $script:Sets++
    $script:Snap = [pscustomobject]@{ Description = $Description; ProtocolPresent = $true; Protocol = $Protocol; Icon = $Icon; Command = $Command; Extra = @() }
}
function Remove-InstallLaunchLinkKey { $script:Sets++; $script:Snap = $null }

function Get-FixLog {
    $p = Join-Path $env:LOCALAPPDATA ('FamilyFixIt\logs\fixit-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
    if (Test-Path -LiteralPath $p) { return [IO.File]::ReadAllText($p) }
    return ''
}
function Get-InstLog { if (Test-Path -LiteralPath $script:InstallLog) { return [IO.File]::ReadAllText($script:InstallLog) }; return '' }

Section 'Registration'
$ok = Register-InstallLaunchLink -Dir $dir
$cmd = Get-InstallLaunchCommand -Dir $dir
$icon = Get-InstallIconLocation -Dir $dir
$gui = Get-InstallGuiArguments -Dir $dir
Assert ($ok -and $script:Sets -eq 1) 'the link is registered'
Assert ($script:Snap.Description -eq 'URL:Family Fix-It' -and $script:Snap.ProtocolPresent -and $script:Snap.Protocol -eq '' -and @($script:Snap.Extra).Count -eq 0) 'the key is a URL protocol with an empty URL Protocol value and nothing else'
Assert ($script:Snap.Icon -eq 'shell32.dll,22') 'with no icon file, the link uses the same built-in icon as the shortcut'
Assert ($cmd -eq $script:Snap.Command) 'the stored command is the command we meant to write'
Assert ($cmd -match [regex]::Escape($fake) -and $cmd -match [regex]::Escape((Join-Path $dir 'Start-FixItLink.ps1'))) 'the command starts the opener with Windows PowerShell'
Assert ($cmd -notmatch '%1' -and $cmd -notmatch ' -Test' -and $cmd -notmatch ' -Command' -and $cmd -notmatch ' -Action' -and $cmd -notmatch ' -EncodedCommand' -and $cmd -notmatch 'FamilyFixIt\.ps1') 'the registered command does not pass %1, Test mode, or any action, and does not start the program directly'
Assert ($cmd -notmatch 'cmd\.exe') 'the command is not handed to cmd.exe'
$opener = Join-Path $dir 'Start-FixItLink.ps1'
Assert (([IO.File]::ReadAllText($opener)) -eq (Get-InstallLaunchLinkScript)) 'the opener on disk is the installer''s copy'
$ilog = Get-InstLog; $flog = Get-FixLog
Assert ($ilog -match 'Launch link written: HKCU\\Software\\Classes\\familyfixit' -and $ilog -match 'Launch link command:' -and $flog -match 'Launch link written: HKCU\\Software\\Classes\\familyfixit' -and $flog -match [regex]::Escape($cmd)) 'the install log and the Fix-It log both record the key and the command'

Section 'Idempotent, and a dirty key is cleaned'
$beforeSets = $script:Sets
$ok = Register-InstallLaunchLink -Dir $dir
Assert ($ok -and $script:Sets -eq $beforeSets -and $script:Snap.Command -eq $cmd) 'a second run leaves the same command and does not write the key again'
Assert ((Get-InstLog) -match 'Launch link already correct: HKCU\\Software\\Classes\\familyfixit') 'the second run says the link was already correct'
$script:Snap = [pscustomobject]@{ Description = 'URL:Family Fix-It'; ProtocolPresent = $true; Protocol = ''; Icon = $script:Snap.Icon; Command = ($cmd + ' %1'); Extra = @('\shell\run\command||calc.exe') }
$ok = Register-InstallLaunchLink -Dir $dir
Assert ($ok -and $script:Sets -eq ($beforeSets + 1) -and $script:Snap.Command -eq $cmd -and $script:Snap.Command -notmatch '%1' -and @($script:Snap.Extra).Count -eq 0) 'a key that forwards %1 or has an extra verb is rewritten back to the safe command'
[IO.File]::WriteAllText($opener, "Write-Output 'changed'`r`n")
$ok = Register-InstallLaunchLink -Dir $dir
Assert ($ok -and ([IO.File]::ReadAllText($opener)) -eq (Get-InstallLaunchLinkScript)) 'a changed opener is put back'

Section 'What the registry lines mean'
$goodLines = @(
    '||URL:Family Fix-It',
    '|URL Protocol|',
    ('\DefaultIcon||' + $icon),
    ('\shell\open\command||' + $cmd)
)
$same = ConvertTo-InstallLaunchLinkSnapshot -Lines $goodLines
Assert (Test-InstallLaunchLinkSame -Have $same -Description 'URL:Family Fix-It' -Icon $icon -Command $cmd) 'the four expected values and nothing else count as the right key'
$evilLines = $goodLines + @('\shell\open\command|extra|familyfixit://x" & calc')
$evil = ConvertTo-InstallLaunchLinkSnapshot -Lines $evilLines
Assert (-not (Test-InstallLaunchLinkSame -Have $evil -Description 'URL:Family Fix-It' -Icon $icon -Command $cmd) -and @($evil.Extra).Count -eq 1) 'an extra value is not left in place'
$injected = ConvertTo-InstallLaunchLinkSnapshot -Lines @('\shell\open\command||powershell.exe -Command calc %1')
Assert ($injected.Command -match '%1' -and -not (Test-InstallLaunchLinkSame -Have $injected -Description 'URL:Family Fix-It' -Icon $icon -Command $cmd)) 'a command that contains %1 is not treated as ours'

Section 'Refused paths, practice run, and removal'
Assert ((Get-InstallLaunchCommand -Dir ($tmp + '/bad"dir')) -eq '' -and (Get-InstallLaunchCommand -Dir ($tmp + '/bad%dir')) -eq '') 'a quote or a percent sign in the folder is refused'
$badDir = $tmp + '/bad"dir'
$sets0 = $script:Sets
Assert (-not (Register-InstallLaunchLink -Dir $badDir) -and $script:Sets -eq $sets0) 'a refused folder does not write the key'
$script:InstallDry = $true
function Get-InstallText { param([string]$Url) return '{"name":"family-it-fixit","version":"2.3.19","files":[{"path":"FamilyFixIt.ps1","sha256":"' + ('a' * 64) + '","size":10},{"path":"Start-FixIt.cmd","sha256":"' + ('b' * 64) + '","size":10}]}' }
function Test-InstallWindows { return $true }
$dryDir = Join-Path $tmp 'dry'
$sets1 = $script:Sets
$dry = Install-FamilyFixIt -Base 'https://example.test/family-it-fixit' -Dir $dryDir -Launch $false
$script:InstallDry = $false
Assert ($dry.Title -eq 'Practice run' -and $script:Sets -eq $sets1 -and -not (Test-Path -LiteralPath (Join-Path $dryDir 'Start-FixItLink.ps1'))) 'a practice run does not register the link or write the opener'
Assert ((Get-InstLog) -match 'familyfixit://open') 'a practice run says it would register familyfixit://open'
$ok = Remove-InstallLaunchLink -Dir $dir
Assert ($ok -and $null -eq $script:Snap -and -not (Test-Path -LiteralPath $opener)) 'removal deletes the key and the opener'
Assert ((Get-InstLog) -match 'Launch link removed: HKCU\\Software\\Classes\\familyfixit' -and (Get-FixLog) -match 'Launch link removed: HKCU\\Software\\Classes\\familyfixit') 'removal is written to both logs'
$ok = Register-InstallLaunchLink -Dir $dir
Assert ($ok -and $script:Snap.Command -eq $cmd -and (Test-Path -LiteralPath $opener)) 'registering again after removal writes the same command'

Section 'Test mode stays the Start menu shortcut'
$desk = Join-Path $tmp 'desk'; $menu = Join-Path $tmp 'menu'
New-Item -ItemType Directory -Path $desk, $menu -Force | Out-Null
$script:Ln = @{}
function Get-InstallFolderPath { param([string]$Which) if ($Which -eq 'Desktop') { return $desk }; return $menu }
function Get-InstallShortcut { param([string]$Path) if ($script:Ln.Contains($Path)) { return $script:Ln[$Path] }; return $null }
function New-InstallShortcut { param([string]$Path, [string]$Target, [string]$Arguments, [string]$WorkDir, [string]$Icon, [string]$Description) $script:Ln[$Path] = [pscustomobject]@{ Target = $Target; Arguments = $Arguments; Icon = $Icon } }
$null = Set-InstallShortcuts -Dir $dir
$deskLnk = Join-Path $desk 'Family Fix-It.lnk'
$testLnk = Join-Path $menu 'Family Fix-It (Test mode).lnk'
Assert ($script:Ln[$deskLnk].Arguments -eq $gui -and $script:Ln[$deskLnk].Arguments -notmatch ' -Test') 'the Desktop shortcut arguments are the normal window, with no -Test'
Assert ($script:Ln[$testLnk].Arguments -eq ($gui + ' -Test')) 'the Test mode shortcut is the same command plus -Test, and it is not the link'
Assert ($script:Snap.Command -notmatch ' -Test') 'the link does not open Test mode'

Section 'The opener ignores the address'
$opText = Get-InstallLaunchLinkScript
Assert ($opText -notmatch '\$args' -and $opText -notmatch '(?i)invoke-expression|\biex\b' -and $opText -notmatch '%1' -and $opText -notmatch ' -Action' -and $opText -notmatch ' -Yes' -and $opText -notmatch ' -Test' -and $opText -notmatch ' -Command') 'the opener never reads arguments and never names an action'
$oerr = $null; $otok = $null
$oast = [Management.Automation.Language.Parser]::ParseInput($opText, [ref]$otok, [ref]$oerr)
Assert ($oerr.Count -eq 0 -and $null -eq $oast.ParamBlock) 'the opener parses and has no parameter block (nothing can bind)'
$names = @($oast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
$allowed = @('Set-StrictMode', 'Split-Path', 'Join-Path', 'Test-Path', 'New-Item', 'Get-Date', 'New-Object', 'Out-Null')
$badCmd = @($names | Where-Object { $allowed -notcontains $_ })
Assert ($badCmd.Count -eq 0 -and $names.Count -gt 0) ('the opener only calls small helpers, not a repair (' + ($badCmd -join ',') + ')')
Assert ($srcText -match "\[string\]\`$Action = 'Gui'" -and $srcText -match 'if \(\$Action -ne ''Gui''\) \{ return \$false \}') 'the normal start (no -Action) is the one-window Gui start'

function Clear-OpenLog {
    $p = Join-Path $env:LOCALAPPDATA ('FamilyFixIt\logs\fixit-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    if (Test-Path -LiteralPath $cap) { Remove-Item -LiteralPath $cap -Force }
}
function Invoke-Opener {
    param([string[]]$Extra)
    Clear-OpenLog
    & (Get-Command pwsh).Source -NoProfile -ExecutionPolicy Bypass -File $opener @Extra
    $script:OpenCode = $LASTEXITCODE
}
function Read-Cap {
    $deadline = (Get-Date).AddSeconds(5)
    do {
        if ((Test-Path -LiteralPath $cap) -and (Get-Item -LiteralPath $cap).Length -gt 0) { break }
        Start-Sleep -Milliseconds 50
    } while ((Get-Date) -lt $deadline)
    if (-not (Test-Path -LiteralPath $cap)) { return @() }
    return @(Get-Content -LiteralPath $cap)
}
$tool = Join-Path $dir 'FamilyFixIt.ps1'
$expect = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', $tool)

$cases = @(
    ,@('familyfixit://open')
    ,@('familyfixit://open?fix=all')
    ,@('familyfixit://x" & calc')
    ,@('familyfixit://open', '-Action', 'RepairWindows', '-Yes')
    ,@('familyfixit://open?x=' + ('A' * 8000))
)
foreach ($c in $cases) {
    Invoke-Opener -Extra $c
    $got = Read-Cap
    $blob = ($got -join "`n")
    $payload = ($c -join "`n")
    $okCase = ($script:OpenCode -eq 0 -and ($got -join '|') -eq ($expect -join '|') -and $blob.IndexOf($c[0]) -lt 0 -and $blob -notmatch 'RepairWindows' -and $blob -notmatch ' -Yes' -and $blob -notmatch 'calc')
    Assert $okCase ('opener ignores ' + $c[0].Substring(0, [Math]::Min(40, $c[0].Length)))
    $lg = Get-FixLog
    Assert ($lg -match 'Opened from a familyfixit: link\. The address was ignored\. Opening the normal window\.' -and $lg -match [regex]::Escape('Normal window command: ' + $fake + ' ' + $gui) -and $lg.IndexOf($c[0]) -lt 0) 'the Fix-It log says the address was ignored and records only the normal window command'
}

Section 'A very long address, in this process'
Clear-OpenLog
$huge = 'familyfixit://open?' + ('Z' * 100000)
& $opener @($huge, 'familyfixit://x" & calc', '-Action', 'RepairWindows', '-Yes')
$got = Read-Cap
$lg = Get-FixLog
Assert (($got -join '|') -eq ($expect -join '|') -and $lg.IndexOf($huge.Substring(0, 80)) -lt 0 -and $lg -notmatch 'RepairWindows' -and (Read-Cap) -notcontains '-Action') 'a very long address and a repair action are discarded, even in this process'

Section 'Forwarding the address would select a repair; the link does not'
$stub = Join-Path $tmp 'stub.ps1'
$stubOut = Join-Path $tmp 'stub-out.txt'
[IO.File]::WriteAllText($stub, @'
param(
    [ValidateSet('Gui','RepairWindows','Printer')]
    [string]$Action = 'Gui',
    [switch]$Yes,
    [switch]$Test,
    [Alias('DryRun')][switch]$WhatIf
)
'{0}|{1}|{2}|{3}|{4}' -f $Action, $(if ($Yes) { 1 } else { 0 }), $(if ($Test) { 1 } else { 0 }), $(if ($WhatIf) { 1 } else { 0 }), (@($args).Count) | Set-Content -LiteralPath $env:FIXIT_STUB_OUT
'@)
$env:FIXIT_STUB_OUT = $stubOut
& (Get-Command pwsh).Source -NoProfile -ExecutionPolicy Bypass -File $stub
$clean = ''
if (Test-Path -LiteralPath $stubOut) { $clean = [IO.File]::ReadAllText($stubOut).Trim() }
Assert ($LASTEXITCODE -eq 0 -and $clean -eq 'Gui|0|0|0|0') 'the Desktop-shortcut arguments open Gui and pass nothing else (the one-window start)'
Remove-Item -LiteralPath $stubOut -Force -ErrorAction SilentlyContinue
& (Get-Command pwsh).Source -NoProfile -File $stub -Action RepairWindows -Yes
$picked = ''
if (Test-Path -LiteralPath $stubOut) { $picked = [IO.File]::ReadAllText($stubOut).Trim() }
Assert ($picked -eq 'RepairWindows|1|0|0|0') 'if an address were forwarded as -Action RepairWindows -Yes, a repair would be selected'
Remove-Item -LiteralPath $stubOut -Force -ErrorAction SilentlyContinue
& (Get-Command pwsh).Source -NoProfile -File $stub 'familyfixit://open?fix=all' 2>$null
Assert ($LASTEXITCODE -ne 0) 'a bare address cannot bind to the program (it is not a valid action), so it must not be forwarded'
$childBlob = (Read-Cap) -join ' '
Assert ($childBlob -notmatch 'RepairWindows' -and $childBlob -notmatch 'fix=all' -and $childBlob -notmatch ' -Yes') 'the link''s child command is still only the normal window'

Section 'A folder with spaces is still one argument'
$spaced = Join-Path (Join-Path $tmp 'Mom (Work)') 'Family Fix It'
New-Item -ItemType Directory -Path $spaced -Force | Out-Null
$ok = Register-InstallLaunchLink -Dir $spaced
$spacedTool = Join-Path $spaced 'FamilyFixIt.ps1'
$spacedOpener = Join-Path $spaced 'Start-FixItLink.ps1'
$spacedCmd = Get-InstallLaunchCommand -Dir $spaced
Assert ($ok -and $spacedCmd -match [regex]::Escape($spacedOpener) -and $spacedCmd -notmatch '%1') 'a folder with spaces and parentheses is quoted in the registered command'
Clear-OpenLog
& (Get-Command pwsh).Source -NoProfile -File $spacedOpener 'familyfixit://open?fix=all'
$got = Read-Cap
Assert (($got -join '|') -eq (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', $spacedTool) -join '|')) 'the program path with spaces stays one argument, and the address is not added'

if ($null -eq $savedRoot) { Remove-Item Env:SystemRoot -ErrorAction SilentlyContinue } else { $env:SystemRoot = $savedRoot }
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Microsoft.PowerShell.Utility\Write-Host ''
Microsoft.PowerShell.Utility\Write-Host ('Passed: {0}   Failed: {1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
