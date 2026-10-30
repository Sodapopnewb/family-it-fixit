# Version 2.3.5 tests: the Test mode checks that gave false FAILs on a real PC (administrator check, finding Edge and Chrome, backup folder),
# and the "Is Google Chrome on this computer?" flow. These use the REAL program functions with pretend Windows facts, so they run in their own PowerShell.
# Usage:  pwsh ./tests/Test-FixIt-V235.ps1       (Test-FixIt.ps1 runs this one too and adds its numbers)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fixit-v235-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:Pass = 0; $script:Fail = 0
function Assert { param([bool]$Cond, [string]$Name) if ($Cond) { $script:Pass++ } else { $script:Fail++; Write-Host ('  FAIL: ' + $Name) -ForegroundColor Red } }
function Section { param([string]$T) Write-Host ('== ' + $T) }

$src = Join-Path $root 'FamilyFixIt.ps1'
$outDir = Join-Path $tmp 'out'
New-Item -ItemType Directory -Path $outDir | Out-Null
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v235.log') -OutputDir $outDir
Initialize-FixItLog
$tokens = $null; $perr = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$perr)
$allFns = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
function Get-Fn { param([string]$Name) return ($allFns | Where-Object { $_.Name -eq $Name } | Select-Object -First 1) }
function Get-Texts { param($Results) return (@($Results | ForEach-Object { $_.Status + ': ' + $_.Text }) -join ' | ') }

Assert ($script:FixItVersion -eq '2.3.5') 'the program is version 2.3.5'

# ================================================================ 1. administrator check
Section 'Administrator check: deny-only admin, standard user'
# what "whoami /groups /fo csv /nh" prints for Trey's everyday (UAC split) sign-in
$whoamiDenyOnly = @(
    '"Everyone","Well-known group","S-1-1-0","Mandatory group, Enabled by default, Enabled group"',
    '"BUILTIN\Administrators","Alias","S-1-5-32-544","Group used for deny only"',
    '"BUILTIN\Users","Alias","S-1-5-32-545","Mandatory group, Enabled by default, Enabled group"',
    '"NT AUTHORITY\INTERACTIVE","Well-known group","S-1-5-4","Mandatory group, Enabled by default, Enabled group"',
    '"Mandatory Label\Medium Mandatory Level","Label","S-1-16-8192","Mandatory group, Enabled by default, Enabled group"'
)
$whoamiStandard = @($whoamiDenyOnly | Where-Object { $_ -notmatch 'S-1-5-32-544' })
$whoamiSpanish = @('"Todos","Grupo conocido","S-1-1-0","Grupo obligatorio, Habilitado de forma predeterminada, Grupo habilitado"', '"BUILTIN\Administradores","Alias","S-1-5-32-544","Grupo usado solo para denegar"')
$g = @(Convert-FixItWhoamiGroups -Lines $whoamiDenyOnly)
Assert ($g.Count -eq 5) ('the groups list is read (' + $g.Count + ')')
$adm = @($g | Where-Object { $_.Sid -eq 'S-1-5-32-544' })
Assert ($adm.Count -eq 1 -and $adm[0].Attributes -match 'deny only') 'the Administrators group is found, marked "deny only"'
Assert (@(Convert-FixItWhoamiGroups -Lines $whoamiSpanish | Where-Object { $_.Sid -eq 'S-1-5-32-544' }).Count -eq 1) 'it is found by its SID, so another language does not matter'
Assert (@(Convert-FixItWhoamiGroups -Lines @('garbage', '', 'INFO: nothing')).Count -eq 0) 'rubbish output gives an empty list'
$script:Adm = $false; $script:Tok = $null
function Test-FixItAdmin { return $script:Adm }
function Get-FixItTokenGroups { return $script:Tok }
$script:Tok = @(Convert-FixItWhoamiGroups -Lines $whoamiDenyOnly)
Assert (Test-FixItCanElevate) 'a deny-only Administrators group counts as able to approve'
$r = Get-FixItAdminCheck -What 'restarting a service'
Assert ($r.Status -eq 'PASS' -and $r.Text -match 'will ask for permission \(a Yes box\)') ('deny-only admin: PASS with the Yes box note (' + $r.Status + ': ' + $r.Text + ')')
$script:Tok = @([pscustomobject]@{ Sid = 'S-1-5-32-544'; Attributes = 'Mandatory group, Enabled by default, Enabled group, Group owner' })
Assert ((Get-FixItAdminCheck -What 'x').Status -eq 'PASS') 'an enabled Administrators group also passes'
$script:Tok = @([pscustomobject]@{ Sid = 'S-1-5-32-544'; Attributes = '' })
Assert ((Get-FixItAdminCheck -What 'x').Status -eq 'PASS') 'the Administrators group with no attribute text passes (any attribute counts)'
$script:Tok = @(Convert-FixItWhoamiGroups -Lines $whoamiStandard)
Assert (-not (Test-FixItCanElevate)) 'a standard user cannot approve'
$r = Get-FixItAdminCheck -What 'restarting a service'
Assert ($r.Status -eq 'WARN' -and $r.Text -match "needs an administrator's password") ('standard user: a plain WARN about the administrator password (' + $r.Status + ': ' + $r.Text + ')')
Assert ($r.Text -notmatch '(?i)not allowed|fail') 'the standard user wording has no scary words'
$script:Tok = $null
$r = Get-FixItAdminCheck -What 'x'
Assert ($r.Status -eq 'WARN') 'when the groups cannot be read it is a WARN, never a FAIL'
$script:Adm = $true; $script:Tok = @()
Assert ((Get-FixItAdminCheck -What 'x').Status -eq 'PASS') 'already running as administrator: PASS'
$script:Adm = $false
# end to end through a real check list
$script:Tok = @(Convert-FixItWhoamiGroups -Lines $whoamiDenyOnly)
function Get-FixItServiceStatus { param([string]$Name) return 'Running' }
$res = @(Get-FixItPreflight -Adapter 'Stop-FixItService' -Arguments @{ Name = 'Spooler' })
Assert (@($res | Where-Object { $_.Status -eq 'FAIL' }).Count -eq 0) ('stopping a service on a deny-only admin has no FAIL (' + (Get-Texts $res) + ')')
$res = @(Get-FixItPreflight -Adapter 'Invoke-Msi' -Arguments @{ ProductCode = 'x' })
Assert (@($res | Where-Object { $_.Text -match 'not allowed to give' }).Count -eq 0) 'the old "not allowed to give it" text is gone'
Assert ((Get-Content -LiteralPath $src -Raw) -notmatch 'not allowed to give it') 'the old wording is not in the program'
$script:Tok = $null

# ================================================================ 2. finding Edge
Section 'Finding Edge (and Chrome): not on the PATH'
$edgeX86 = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
$edgeX64 = 'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
$chromeX64 = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$chromeX86 = 'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
$localRoot = Join-Path $tmp 'local'
$chromeLocal = $localRoot + '\Google\Chrome\Application\chrome.exe'
$env:ProgramFiles = 'C:\Program Files'; [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', 'C:\Program Files (x86)'); $env:ProgramW6432 = 'C:\Program Files'; $env:LOCALAPPDATA = $localRoot
$script:Existing = @(); $script:PathHit = ''; $script:AppPaths = @{}; $script:Saved = @{}
function Test-FixItFileExists { param([string]$Path) return ($script:Existing -contains $Path) }
function Get-FixItCommandPath { param([string]$Name) return $script:PathHit }
function Get-FixItAppPathsExe { param([string]$Exe) if ($script:AppPaths.ContainsKey($Exe)) { return $script:AppPaths[$Exe] } return '' }
function Get-FixItSetting { param([string]$Name, [string]$Default = '') if ($script:Saved.ContainsKey($Name)) { return [string]$script:Saved[$Name] } return $Default }
function Test-FixItCommandPresent { param([string]$Name) return $false }

$script:Existing = @($edgeX86)
Assert ((Resolve-FixItBrowserExe -Exe 'msedge.exe') -eq $edgeX86) 'Edge at the Program Files (x86) path is found even though it is not on the PATH'
$res = @(Get-FixItPreflight -Adapter 'Open-FixItBrowserPage' -Arguments @{ Exe = 'msedge.exe'; Url = 'edge://extensions' })
Assert ($res.Count -eq 1 -and $res[0].Status -eq 'PASS' -and $res[0].Text -match 'Program Files \(x86\)') ('Test mode check for "Open edge://extensions": PASS (' + (Get-Texts $res) + ')')
$script:Existing = @($edgeX64)
Assert ((Resolve-FixItBrowserExe -Exe 'msedge.exe') -eq $edgeX64) 'Edge in Program Files (64-bit) is found'
$script:Existing = @(); $script:AppPaths = @{ 'msedge.exe' = 'D:\Apps\Edge\msedge.exe' }
$script:Existing = @('D:\Apps\Edge\msedge.exe')
Assert ((Resolve-FixItBrowserExe -Exe 'msedge.exe') -eq 'D:\Apps\Edge\msedge.exe') 'Edge listed in the App Paths registry key is found'
$script:AppPaths = @{ 'msedge.exe' = 'D:\Gone\msedge.exe' }; $script:Existing = @()
Assert ((Resolve-FixItBrowserExe -Exe 'msedge.exe') -eq '') 'an App Paths entry that points at a missing file is not trusted'
$script:AppPaths = @{}
$edgeLocal = $localRoot + '\Microsoft\Edge\Application\msedge.exe'
$script:Existing = @($edgeLocal)
Assert ((Resolve-FixItBrowserExe -Exe 'msedge.exe') -eq $edgeLocal) 'Edge under LOCALAPPDATA is found'
$script:Existing = @(); $script:PathHit = 'C:\Somewhere\msedge.exe'
Assert ((Resolve-FixItBrowserExe -Exe 'msedge.exe') -eq 'C:\Somewhere\msedge.exe') 'Edge on the PATH is still found'
$script:PathHit = ''
Assert ((Resolve-FixItBrowserExe -Exe 'msedge.exe') -eq '') 'no Edge anywhere: nothing is found'
$res = @(Get-FixItPreflight -Adapter 'Open-FixItBrowserPage' -Arguments @{ Exe = 'msedge.exe'; Url = 'x' })
Assert ($res.Count -eq 1 -and $res[0].Status -eq 'FAIL' -and $res[0].Text -match 'not found') 'Edge truly missing is still reported as a FAIL'
$script:Existing = @($edgeX86)
Assert ((Resolve-FixItBrowserExe -Exe $edgeX86) -eq $edgeX86) 'a full path that exists is used as it is'
Assert ((Resolve-FixItBrowserExe -Exe 'notepad.exe') -eq '') 'other programs are not guessed'
# Chrome the same way
foreach ($case in @(@('Program Files', $chromeX64), @('Program Files (x86)', $chromeX86), @('LOCALAPPDATA', $chromeLocal))) {
    $script:Existing = @($case[1])
    Assert ((Resolve-FixItBrowserExe -Exe 'chrome.exe') -eq $case[1]) ('Chrome in ' + $case[0] + ' is found')
}
$script:Existing = @(); $script:AppPaths = @{ 'chrome.exe' = 'E:\Chrome\chrome.exe' }; $script:Existing = @('E:\Chrome\chrome.exe')
Assert ((Resolve-FixItBrowserExe -Exe 'chrome.exe') -eq 'E:\Chrome\chrome.exe') 'Chrome listed in the App Paths registry key is found'
$script:AppPaths = @{}; $script:Existing = @()
$script:Saved = @{ ChromePath = 'F:\Mine\chrome.exe' }
Assert ((Resolve-FixItBrowserExe -Exe 'chrome.exe') -eq '') 'a saved Chrome path to a missing file is ignored'
$script:Existing = @('F:\Mine\chrome.exe')
Assert ((Resolve-FixItBrowserExe -Exe 'chrome.exe') -eq 'F:\Mine\chrome.exe') 'a saved Chrome path (from the deeper search) is used'
Assert ((Resolve-FixItBrowserExe -Exe 'msedge.exe') -eq '') 'the saved Chrome path is never used for Edge'
$script:Saved = @{}; $script:Existing = @()

# the real action resolves the same way
$script:Started = @()
function Start-Process { param([string]$FilePath, $ArgumentList, [switch]$PassThru, [switch]$Wait) $script:Started += , @($FilePath, [string]$ArgumentList) }
$script:TestMode = $false; $script:DryRun = $false
$script:Existing = @($edgeX86)
Open-FixItBrowserPage -Exe 'msedge.exe' -Url 'edge://extensions'
Assert ($script:Started.Count -eq 1 -and $script:Started[0][0] -eq $edgeX86 -and $script:Started[0][1] -eq 'edge://extensions') 'the real action starts Edge by its full path'
$script:Existing = @(); $script:Started = @()
Open-FixItBrowserPage -Exe 'msedge.exe' -Url 'edge://extensions'
Assert ($script:Started.Count -eq 1 -and $script:Started[0][0] -eq 'msedge.exe') 'when nothing is found the real action still tries the plain name (Windows may know it)'
$script:Started = @(); $script:TestMode = $true; $script:InProbe = $true; $script:ProbeResults = New-Object System.Collections.ArrayList
Open-FixItBrowserPage -Exe 'msedge.exe' -Url 'x'
Assert ($script:Started.Count -eq 0 -and $script:ProbeResults.Count -eq 1) 'in Test mode nothing is started (it is only checked)'
$script:TestMode = $false; $script:InProbe = $false
Microsoft.PowerShell.Management\Remove-Item -Path Function:\Start-Process

# ================================================================ 3. the backup folder
Section 'Backup folder check'
$bk = Join-Path $tmp 'LocalAppData-empty'
New-Item -ItemType Directory -Path $bk | Out-Null
$dest = Join-Path $bk 'FamilyFixIt\backups\20261029-1200\Edge-Default'
Assert ((Get-FixItNearestExistingFolder -Path $dest) -eq $bk) 'the nearest existing parent folder is found by walking up'
Assert ((Get-FixItNearestExistingFolder -Path $bk) -eq $bk) 'an existing folder is its own nearest folder'
Assert ((Get-FixItNearestExistingFolder -Path '') -eq '') 'an empty path finds nothing'
Assert (Test-FixItFolderWritable -Path $bk) 'a folder you can write to reports writable'
Assert (@(Get-ChildItem -LiteralPath $bk -Force).Count -eq 0) 'the writable check leaves nothing behind'
Assert (-not (Test-FixItFolderWritable -Path (Join-Path $tmp 'not-a-folder'))) 'a folder that is not there is not writable'
$srcFile = Join-Path $tmp 'Preferences'; Set-Content -LiteralPath $srcFile 'x'
$res = @(Get-FixItPreflight -Adapter 'Copy-FixItBackup' -Arguments @{ Source = $srcFile; DestDir = $dest })
Assert (@($res | Where-Object { $_.Status -eq 'FAIL' }).Count -eq 0) ('backups folder missing but its parent is writable: no FAIL (' + (Get-Texts $res) + ')')
Assert (@($res | Where-Object { $_.Text -match 'can be made' }).Count -eq 1) 'it says the folder can be made'
Assert (-not (Test-Path -LiteralPath (Join-Path $bk 'FamilyFixIt'))) 'the check did not make the folder'
$res = @(Get-FixItPreflight -Adapter 'Copy-FixItBackup' -Arguments @{ Source = $srcFile; DestDir = $bk })
Assert (@($res | Where-Object { $_.Status -eq 'FAIL' }).Count -eq 0 -and @($res | Where-Object { $_.Text -match 'exists and can be written' }).Count -eq 1) 'an existing writable backup folder passes'
function Test-FixItFolderWritable { param([string]$Path) return $false }
$res = @(Get-FixItPreflight -Adapter 'Copy-FixItBackup' -Arguments @{ Source = $srcFile; DestDir = $dest })
Assert (@($res | Where-Object { $_.Status -eq 'FAIL' -and $_.Text -match 'cannot be written' }).Count -eq 1) 'a parent that cannot be written to is a FAIL'
function Get-FixItNearestExistingFolder { param([string]$Path) return '' }
$res = @(Get-FixItPreflight -Adapter 'Copy-FixItBackup' -Arguments @{ Source = $srcFile; DestDir = $dest })
Assert (@($res | Where-Object { $_.Status -eq 'FAIL' }).Count -eq 1) 'no existing parent at all is a FAIL'
$real = $allFns | Where-Object { $_.Name -in @('Test-FixItFolderWritable', 'Get-FixItNearestExistingFolder') }
foreach ($fn in $real) { Set-Item -Path ('Function:\' + $fn.Name) -Value ([scriptblock]::Create($fn.Body.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))) }
Assert ((Get-FixItNearestExistingFolder -Path $dest) -eq $bk) 'the real helpers were put back'

# ================================================================ 4. Chrome: ask, search, remember
Section 'Chrome: quick lookup, the question, the deeper search'
$script:Existing = @(); $script:Saved = @{}; $script:PathHit = ''; $script:AppPaths = @{}
$script:Asked = 0; $script:Answer = 'No'; $script:DeepCalls = 0; $script:DeepResult = ''; $script:Notes = @(); $script:SetCalls = @(); $script:CanAsk = $true
function Read-FixItChromeAnswer { $script:Asked++; return $script:Answer }
function Find-FixItChromeDeep { param([int]$MaxSeconds = 30, [string[]]$Roots = @(), [string[]]$ShortcutFolders = @()) $script:DeepCalls++; $script:DeepMax = $MaxSeconds; return $script:DeepResult }
function Set-FixItNote { param([string]$Text) $script:Notes += $Text }
function Set-FixItSetting { param([string]$Name, [string]$Value) $script:SetCalls += , @($Name, $Value); $script:Saved[$Name] = $Value }
function Test-FixItCanAsk { return $script:CanAsk }
function Reset-Chrome { $script:ChromeLookup = $null; $script:Asked = 0; $script:DeepCalls = 0; $script:Notes = @(); $script:SetCalls = @(); $script:Saved = @{}; $script:CanAsk = $true; $script:TestMode = $false; $script:TestAll = $false; $script:DryRun = $false; $script:TestRecords = New-Object System.Collections.ArrayList }

# found by the quick lookup: no question
Reset-Chrome; $script:Existing = @($chromeX86)
$p = Get-FixItChromeForPages
Assert ($p -eq $chromeX86 -and $script:Asked -eq 0 -and $script:DeepCalls -eq 0) 'Chrome found quickly (x86 path): used, never asked'
Reset-Chrome; $script:Existing = @($chromeLocal)
Assert ((Get-FixItChromeForPages) -eq $chromeLocal -and $script:Asked -eq 0) 'Chrome found quickly (LOCALAPPDATA): used, never asked'
# answer No
Reset-Chrome; $script:Existing = @(); $script:Answer = 'No'; $script:DeepResult = $chromeLocal
$p = Get-FixItChromeForPages
Assert ($p -eq '' -and $script:Asked -eq 1 -and $script:DeepCalls -eq 0) 'No: Chrome is skipped and no search is done'
Assert (@($script:Notes).Count -eq 0) 'No: no "Looking" note is shown'
$null = Get-FixItChromeForPages
Assert ($script:Asked -eq 1) 'asked only once in one clean-up (the second page does not ask again)'
# answer Yes, found
Reset-Chrome; $script:Answer = 'Yes'; $script:DeepResult = $chromeLocal
$p = Get-FixItChromeForPages
Assert ($p -eq $chromeLocal -and $script:Asked -eq 1 -and $script:DeepCalls -eq 1) 'Yes + found: the deeper search ran once and its result is used'
Assert ($script:DeepMax -eq 30) 'the deeper search is capped at 30 seconds'
Assert ($script:Notes -contains 'Looking for Chrome...') 'a short "Looking for Chrome..." note is shown'
Assert ($script:Saved['ChromePath'] -eq $chromeLocal) 'the found path is saved in the settings'
Assert (-not $script:Saved.ContainsKey('ChromeSkipUntil')) 'a found Chrome does not set a "skip" memory'
# ... and next time it is not asked
$script:ChromeLookup = $null; $script:Asked = 0; $script:DeepCalls = 0; $script:Existing = @($chromeLocal)
Assert ((Get-FixItChromeForPages) -eq $chromeLocal -and $script:Asked -eq 0 -and $script:DeepCalls -eq 0) 'next time the saved path is used without asking'
# answer "I don't know", found
Reset-Chrome; $script:Existing = @(); $script:Answer = 'Unsure'; $script:DeepResult = $chromeX64
$p = Get-FixItChromeForPages
Assert ($p -eq $chromeX64 -and $script:DeepCalls -eq 1 -and $script:Saved['ChromePath'] -eq $chromeX64) "I don't know + found: searched, used and saved"
# Yes / don't know, not found
foreach ($ans in @('Yes', 'Unsure')) {
    Reset-Chrome; $script:Existing = @(); $script:Answer = $ans; $script:DeepResult = ''
    $p = Get-FixItChromeForPages
    Assert ($p -eq '' -and $script:DeepCalls -eq 1) ("$ans + not found: searched once, then Chrome is skipped")
    Assert (-not $script:Saved.ContainsKey('ChromePath') -and $script:Saved.ContainsKey('ChromeSkipUntil')) ("$ans + not found: nothing saved as a path; not asked again for a while")
}
$logText = Get-Content -Raw -LiteralPath (Join-Path $tmp 'v235.log')
Assert ($logText -notmatch '\[(WARN|ERROR)\][^\r\n]*Chrome was not found; skipping') 'not found is skipped quietly (nothing logged as a warning)'
# remembered "not found"
Reset-Chrome; $script:Existing = @(); $script:Saved = @{ ChromeSkipUntil = (Get-Date).AddDays(10).ToString('s') }
Assert ((Get-FixItChromeForPages) -eq '' -and $script:Asked -eq 0) 'a recent "no / not found" is not asked again'
Reset-Chrome; $script:Saved = @{ ChromeSkipUntil = (Get-Date).AddDays(-1).ToString('s') }; $script:Answer = 'No'
$null = Get-FixItChromeForPages
Assert ($script:Asked -eq 1) 'an old "no" is asked again'
# nobody to ask
Reset-Chrome; $script:CanAsk = $false
Assert ((Get-FixItChromeForPages) -eq '' -and $script:Asked -eq 0) 'a background run (nobody there) never asks'
# Test mode: never asks, reports
Reset-Chrome; $script:TestMode = $true; $script:Existing = @(); $script:Answer = 'Yes'; $script:DeepResult = $chromeLocal
$p = Get-FixItChromeForPages
Assert ($p -eq '' -and $script:Asked -eq 0 -and $script:DeepCalls -eq 0) 'Test mode: the question is never asked and nothing is searched'
$rec = @(Get-FixItTestRecords)
Assert ($rec.Count -eq 1 -and $rec[0].Status -eq 'PASS' -and $rec[0].Checks[0].Text -match 'WOULD ask "Is Google Chrome on this computer\?"') 'Test mode reports the lookup result and that the question WOULD be asked'
Assert (@($script:SetCalls).Count -eq 0) 'Test mode saves nothing'
Reset-Chrome; $script:TestMode = $true; $script:Existing = @($chromeX64)
$p = Get-FixItChromeForPages
$rec = @(Get-FixItTestRecords)
Assert ($p -eq $chromeX64 -and $rec.Count -eq 1 -and $rec[0].Checks[0].Text -match 'Chrome was found') 'Test mode with Chrome present reports where it was found'
Reset-Chrome; $script:TestAll = $true; $script:Existing = @()
$null = Get-FixItChromeForPages
Assert ($script:Asked -eq 0) '"Test all buttons" never asks either'
Reset-Chrome; $script:DryRun = $true
$null = Get-FixItChromeForPages
Assert ($script:Asked -eq 0) 'a practice run never asks'
Reset-Chrome

# which pages open
Section 'Chrome: which pages open'
$edgeProf = [pscustomobject]@{ Browser = 'Edge'; Name = 'Default'; Dir = 'x' }; $chromeProf = [pscustomobject]@{ Browser = 'Chrome'; Name = 'Default'; Dir = 'y' }
Reset-Chrome; $script:Existing = @($chromeX64)
$t = @(Get-FixItBrowserPageTargets -Profiles @($edgeProf) -EdgePage 'edge://extensions' -ChromePage 'chrome://extensions')
Assert ($t.Count -eq 2 -and $t[0].Exe -eq 'msedge.exe' -and $t[0].Page -eq 'edge://extensions' -and $t[1].Exe -eq $chromeX64 -and $t[1].Page -eq 'chrome://extensions') 'Edge profile + Chrome installed: both extensions pages open'
Reset-Chrome; $script:Existing = @(); $script:Answer = 'No'
$t = @(Get-FixItBrowserPageTargets -Profiles @($edgeProf) -EdgePage 'edge://extensions' -ChromePage 'chrome://extensions')
Assert ($t.Count -eq 1 -and $t[0].Exe -eq 'msedge.exe') 'Chrome missing (answer No): only the Edge page opens'
Reset-Chrome; $script:Existing = @($chromeX64)
$t = @(Get-FixItBrowserPageTargets -Profiles @($chromeProf) -EdgePage 'edge://extensions' -ChromePage 'chrome://extensions')
Assert ($t.Count -eq 1 -and $t[0].Exe -eq $chromeX64) 'only a Chrome profile: only Chrome opens'
Reset-Chrome; $script:Existing = @(); $script:Answer = 'No'
$t = @(Get-FixItBrowserPageTargets -Profiles @() -EdgePage 'edge://extensions' -ChromePage 'chrome://extensions')
Assert ($t.Count -eq 1 -and $t[0].Exe -eq 'msedge.exe') 'nothing known: falls back to the Edge page'
Reset-Chrome

# Test mode through the real browser clean-up
Section 'Chrome: through the browser clean-up in Test mode'
$bad = 'abcdefabcdefabcdefabcdefabcdefab'
function Get-FixItBrowserProfiles { return @($edgeProf) }
function Get-FixItBrowserSettings { param([string]$Dir) return [pscustomobject]@{ Homepage = ''; StartupUrls = @(); SearchName = ''; SearchUrl = ''; NotificationSites = @() } }
function Get-FixItBrowserExtensions { param([string]$Dir) return @([pscustomobject]@{ Id = $bad; Name = 'Shopping Helper' }) }
function Confirm-FixItStep { param([string]$Question) return $true }
function Invoke-AdminPart { param($Part, [scriptblock]$InProcess, [switch]$Visible, [string]$InputPath) return [pscustomobject]@{ Ok = $true } }
function Copy-FixItBackup { param([string]$Source, [string]$DestDir) }
$script:OpenCalls = @()
function Open-FixItBrowserPage { param([string]$Exe, [string]$Url) $script:OpenCalls += , @($Exe, $Url) }
Reset-Chrome; $script:Existing = @($chromeX64); $script:Answer = 'Yes'
$r = Invoke-BrowserFix
Assert (@($script:OpenCalls | Where-Object { $_[1] -eq 'edge://extensions' -and $_[0] -eq 'msedge.exe' }).Count -eq 1 -and @($script:OpenCalls | Where-Object { $_[1] -eq 'chrome://extensions' -and $_[0] -eq $chromeX64 }).Count -eq 1) 'the clean-up opens edge://extensions AND chrome://extensions when Chrome is installed'
Assert ($script:Asked -eq 0) '... without asking anything'
$script:OpenCalls = @(); Reset-Chrome; $script:Existing = @(); $script:Answer = 'Yes'; $script:DeepResult = $chromeLocal
$r = Invoke-BrowserFix
Assert (@($script:OpenCalls | Where-Object { $_[1] -eq 'chrome://extensions' -and $_[0] -eq $chromeLocal }).Count -eq 1 -and $script:Asked -eq 1) 'Chrome not found quickly, answer Yes, found deeper: its page opens (one question)'
$script:OpenCalls = @(); Reset-Chrome; $script:Existing = @(); $script:Answer = 'No'
$r = Invoke-BrowserFix
Assert (@($script:OpenCalls | Where-Object { $_[1] -match '^chrome:' }).Count -eq 0 -and @($script:OpenCalls | Where-Object { $_[1] -eq 'edge://extensions' }).Count -eq 1 -and $r.Ok) 'answer No: the Edge page still opens and the clean-up goes on without a warning'
Assert (($r.Details -join ' ') -notmatch '(?i)chrome was not found|could not find chrome') 'nothing about Chrome is shown to the person when it is skipped'
# Test mode: the real checks with the real adapter
Remove-Item -Path Function:\Open-FixItBrowserPage
Set-Item -Path Function:\Open-FixItBrowserPage -Value ([scriptblock]::Create((Get-Fn 'Open-FixItBrowserPage').Body.Extent.Text.Trim().TrimStart('{').TrimEnd('}')))
Reset-Chrome; $script:TestMode = $true; $script:DryRun = $true; $script:Existing = @($edgeX86); $script:Answer = 'Yes'
$script:Tok = @(Convert-FixItWhoamiGroups -Lines $whoamiDenyOnly)
Start-FixItTestButton
$r = Invoke-BrowserFix
$recs = @(Get-FixItTestRecords)
$fails = @($recs | Where-Object { $_.Status -eq 'FAIL' })
Assert ($fails.Count -eq 0) ('the browser button in Test mode, Edge at the x86 path and Chrome missing: no FAIL (' + (($fails | ForEach-Object { $_.Step + ' -> ' + (Get-Texts $_.Checks) }) -join ' ;; ') + ')')
Assert (@($recs | Where-Object { $_.Step -match 'edge://extensions' -and $_.Status -eq 'PASS' }).Count -eq 1) 'Test mode: "Open edge://extensions" is a PASS'
Assert (@($recs | Where-Object { $_.Step -eq 'Find Google Chrome' -and $_.Checks[0].Text -match 'WOULD ask' }).Count -eq 1 -and $script:Asked -eq 0) 'Test mode: Chrome lookup reported, question never shown'
Reset-Chrome

# ================================================================ 5. the deeper search (real files)
Section 'Chrome: the deeper search'
function Test-FixItFileExists { param([string]$Path) return (Test-Path -LiteralPath $Path -PathType Leaf) }
function Get-FixItChromeUninstallHints { return @($script:Hints) }
$script:Hints = @()
foreach ($n in @('Find-FixItChromeDeep')) { Set-Item -Path ('Function:\' + $n) -Value ([scriptblock]::Create((Get-Fn $n).Body.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))) }
# Find-FixItChromeDeep has a param block, so rebuild it as a real function from its source
Invoke-Expression ((Get-Fn 'Find-FixItChromeDeep').Extent.Text)
$script:GuiActive = $false
$u = Join-Path $tmp 'user'; New-Item -ItemType Directory -Path $u | Out-Null
$emptyShort = Join-Path $tmp 'short-empty'; New-Item -ItemType Directory -Path $emptyShort | Out-Null
Assert ((Find-FixItChromeDeep -MaxSeconds 5 -Roots @($u) -ShortcutFolders @($emptyShort)) -eq '') 'nothing there: not found (and no error)'
$appDir = Join-Path $u 'AppData/Local/Google/Chrome/Application'; New-Item -ItemType Directory -Path $appDir -Force | Out-Null
Set-Content -LiteralPath (Join-Path $appDir 'chrome.exe') 'MZ'
Set-Content -LiteralPath (Join-Path $appDir 'chrome_proxy.exe') 'MZ'
$found = Find-FixItChromeDeep -MaxSeconds 5 -Roots @($u) -ShortcutFolders @($emptyShort)
Assert ($found -eq (Join-Path $appDir 'chrome.exe')) ('chrome.exe in a user folder is found (' + $found + ')')
Remove-Item -LiteralPath (Join-Path $appDir 'chrome.exe')
Assert ((Find-FixItChromeDeep -MaxSeconds 5 -Roots @($u) -ShortcutFolders @($emptyShort)) -eq '') 'a file with another name (chrome_proxy.exe) is not taken for Chrome'
Set-Content -LiteralPath (Join-Path $appDir 'chrome.exe') 'MZ'
Assert ((Find-FixItChromeDeep -MaxSeconds 0 -Roots @($u) -ShortcutFolders @($emptyShort)) -eq '') 'with no time left it stops at once (the cap works)'
# links are skipped
$real = Join-Path $tmp 'real-place/Application'; New-Item -ItemType Directory -Path $real -Force | Out-Null; Set-Content -LiteralPath (Join-Path $real 'chrome.exe') 'MZ'
$u2 = Join-Path $tmp 'user2'; New-Item -ItemType Directory -Path $u2 | Out-Null
try { New-Item -ItemType SymbolicLink -Path (Join-Path $u2 'link') -Target $real | Out-Null; $linked = $true } catch { $linked = $false }
if ($linked) { Assert ((Find-FixItChromeDeep -MaxSeconds 5 -Roots @($u2) -ShortcutFolders @($emptyShort)) -eq '') 'a folder that is only a link is not followed' } else { Assert $true 'symbolic links not available here (skipped)' }
# cloud-only items are skipped
Assert ((Test-FixItCloudOrLink -Item ([pscustomobject]@{ Attributes = 0x400000 })) -and (Test-FixItCloudOrLink -Item ([pscustomobject]@{ Attributes = 0x40000 })) -and (Test-FixItCloudOrLink -Item ([pscustomobject]@{ Attributes = 0x1000 })) -and (Test-FixItCloudOrLink -Item ([pscustomobject]@{ Attributes = 0x400 }))) 'links, offline files and "download on open" placeholders count as cloud-only/links'
Assert (-not (Test-FixItCloudOrLink -Item ([pscustomobject]@{ Attributes = 0x20 })) -and -not (Test-FixItCloudOrLink -Item ([pscustomobject]@{ Attributes = 0x10 }))) 'normal files and folders do not'
$u3 = Join-Path $tmp 'user3'; New-Item -ItemType Directory -Path (Join-Path $u3 'OneDriveCloud/Google/Application') -Force | Out-Null; Set-Content -LiteralPath (Join-Path $u3 'OneDriveCloud/Google/Application/chrome.exe') 'MZ'
$realCloud = (Get-Command Test-FixItCloudOrLink).ScriptBlock
function Test-FixItCloudOrLink { param($Item) return ($Item.Name -eq 'OneDriveCloud') }
Assert ((Find-FixItChromeDeep -MaxSeconds 5 -Roots @($u3) -ShortcutFolders @($emptyShort)) -eq '') 'a cloud-only folder is not opened (so nothing would be downloaded)'
Set-Item -Path Function:\Test-FixItCloudOrLink -Value $realCloud
Assert ((Find-FixItChromeDeep -MaxSeconds 5 -Roots @($u3) -ShortcutFolders @($emptyShort)) -ne '') 'the same folder is searched when it is a normal one'
# shortcuts
$sc = Join-Path $tmp 'startmenu'; New-Item -ItemType Directory -Path (Join-Path $sc 'Programs') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $sc 'Programs/Google Chrome.lnk') 'lnk'
$elsewhere = Join-Path $tmp 'elsewhere/chrome.exe'; New-Item -ItemType Directory -Path (Split-Path $elsewhere) -Force | Out-Null; Set-Content -LiteralPath $elsewhere 'MZ'
function Get-FixItShortcutTarget { param([string]$Path) return $script:LnkTarget }
$script:LnkTarget = $elsewhere
$empty2 = Join-Path $tmp 'empty-root'; New-Item -ItemType Directory -Path $empty2 | Out-Null
Assert ((Find-FixItChromeDeep -MaxSeconds 5 -Roots @($empty2) -ShortcutFolders @($sc)) -eq $elsewhere) 'a Start menu / Desktop shortcut that points at chrome.exe is followed'
$script:LnkTarget = (Join-Path $tmp 'elsewhere/notchrome.exe')
Assert ((Find-FixItChromeDeep -MaxSeconds 5 -Roots @($empty2) -ShortcutFolders @($sc)) -eq '') 'a shortcut to something else is ignored'
# uninstall list
$script:Hints = @($elsewhere)
Assert ((Find-FixItChromeDeep -MaxSeconds 5 -Roots @($empty2) -ShortcutFolders @($emptyShort)) -eq $elsewhere) 'the installed-programs list (HKCU/HKLM uninstall keys) is used'
$script:Hints = @((Join-Path $tmp 'gone/chrome.exe'))
Assert ((Find-FixItChromeDeep -MaxSeconds 5 -Roots @($empty2) -ShortcutFolders @($emptyShort)) -eq '') 'an uninstall entry for a missing file is ignored'
# read-only
$bannedCmds = @('Remove-Item', 'Set-Content', 'Out-File', 'Add-Content', 'New-Item', 'Copy-Item', 'Move-Item', 'Rename-Item', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Start-Process', 'Invoke-Item')
foreach ($fnName in @('Find-FixItChromeDeep', 'Test-FixItIsChromeFile', 'Get-FixItChromeUninstallHints', 'Test-FixItCloudOrLink', 'Resolve-FixItBrowserExe', 'Get-FixItAppPathsExe')) {
    $names = @((Get-Fn $fnName).Body.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
    Assert (@($names | Where-Object { $bannedCmds -contains $_ }).Count -eq 0) ("$fnName only reads (changes nothing)")
}
$sh = (Get-Fn 'Get-FixItShortcutTarget').Extent.Text
Assert ($sh -match 'CreateShortcut' -and $sh -notmatch '\.Save\(') 'reading a shortcut never saves it'
$deepText = (Get-Fn 'Find-FixItChromeDeep').Extent.Text
Assert ($deepText -match "Test-FixItOffUiWanted\) \{ return \(Invoke-FixItOffUi -Command 'Find-FixItChromeDeep'") 'the deeper search runs in the background when the window is open (it cannot freeze the window)'
foreach ($rootVar in @('LOCALAPPDATA', 'APPDATA', 'USERPROFILE', 'Start Menu', 'GetFolderPath')) { Assert ($deepText -match $rootVar) ("the deeper search covers $rootVar") }
Assert ((Get-Fn 'Get-FixItChromeUninstallHints').Extent.Text -match 'HKCU:' -and (Get-Fn 'Get-FixItChromeUninstallHints').Extent.Text -match 'HKLM:') 'the uninstall lookup covers HKCU and HKLM'

# ================================================================ 6. the question itself
Section 'Chrome: the question window and the console'
$dlg = (Get-Fn 'Show-FixItChromeAskDialog').Extent.Text
Assert ($dlg -match 'Is Google Chrome on this computer\?') 'the question is in plain words'
Assert ($dlg -match "-Title 'Yes'" -and $dlg -match "-Title 'No'" -and $dlg -match "-Title ""I don't know""") 'three buttons: Yes / No / I don''t know'
Assert ($dlg -match "DialogResult = 'Yes'" -and $dlg -match "DialogResult = 'No'" -and $dlg -match "DialogResult = 'Ignore'") 'each button gives its own answer'
$callers = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Show-FixItChromeAskDialog' }, $true) | ForEach-Object { $f = $_.Parent; while ($f -and $f -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $f = $f.Parent }; $f.Name })
Assert (($callers -join ',') -eq 'Read-FixItChromeAnswer') 'only the question function shows the window'
$callers2 = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Read-FixItChromeAnswer' }, $true) | ForEach-Object { $f = $_.Parent; while ($f -and $f -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $f = $f.Parent }; $f.Name })
Assert (($callers2 -join ',') -eq 'Get-FixItChromeForPages') 'and only the lookup asks it (so Test mode, which skips the lookup question, cannot)'
$lk = (Get-Fn 'Get-FixItChromeForPages').Extent.Text
Assert ($lk.IndexOf('$script:TestMode') -lt $lk.IndexOf('Read-FixItChromeAnswer')) 'Test mode is decided before the question could be asked'
# the console version
$realRead = $allFns | Where-Object { $_.Name -eq 'Read-FixItChromeAnswer' }
Invoke-Expression $realRead.Extent.Text
$script:CanAsk = $true; $script:GuiActive = $false
$script:Typed = ''
function Read-Host { param($Prompt) return $script:Typed }
foreach ($row in @(@('y', 'Yes'), @('Yes', 'Yes'), @('n', 'No'), @('', 'No'), @('d', 'Unsure'), @("I don't know", 'Unsure'), @('idk', 'Unsure'), @('?', 'Unsure'))) {
    $script:Typed = $row[0]
    Assert ((Read-FixItChromeAnswer) -eq $row[1]) ("typing '" + $row[0] + "' means " + $row[1])
}
$script:CanAsk = $false
Assert ((Read-FixItChromeAnswer) -eq 'No') 'with nobody there the answer is No'
Microsoft.PowerShell.Management\Remove-Item -Path Function:\Read-Host
$script:CanAsk = $true

# ================================================================ 7. other checks reviewed for the same kind of false FAIL
Section 'Other Test mode checks: false negatives reviewed'
# a service, a registry value, a folder to clear and a file restore, all with a deny-only admin
$script:Tok = @(Convert-FixItWhoamiGroups -Lines $whoamiDenyOnly); $script:Adm = $false
foreach ($row in @(
    @('Start-FixItService', @{ Name = 'Spooler' }), @('Stop-SpoolerService', @{ }), @('Remove-SpoolFile', @{ FullName = (Join-Path $tmp 'nothing.spl') }),
    @('Restart-FixItAdapter', @{ Name = 'Wi-Fi' }), @('Rename-FixItFolderAside', @{ Path = (Join-Path $tmp 'nothing-folder'); Tag = 't' }),
    @('Invoke-FixItNative', @{ File = 'dism.exe'; Arguments = @('/online') }), @('Invoke-Msi', @{ ProductCode = '{x}' }))) {
    function Test-FixItCommandPresent { param([string]$Name) return $true }
    function Get-FixItAdapters { return @('Wi-Fi') }
    $res = @(Get-FixItPreflight -Adapter $row[0] -Arguments $row[1])
    Assert (@($res | Where-Object { $_.Status -eq 'FAIL' }).Count -eq 0) ($row[0] + ': a deny-only admin gets no FAIL (' + (Get-Texts $res) + ')')
}
$script:Tok = @(Convert-FixItWhoamiGroups -Lines $whoamiStandard)
$res = @(Get-FixItPreflight -Adapter 'Stop-FixItService' -Arguments @{ Name = 'Spooler' })
Assert (@($res | Where-Object { $_.Status -eq 'FAIL' }).Count -eq 0 -and @($res | Where-Object { $_.Status -eq 'WARN' }).Count -eq 1) 'a standard user: the service step is a WARN, not a FAIL'
# an existing file that is open elsewhere is still writable-checked without writing
$locked = Join-Path $tmp 'program.ps1'; Set-Content -LiteralPath $locked 'x'
Assert (Test-FixItFileWritable -Path $locked) 'the update check can open the program file for writing (and writes nothing)'
Assert ((Get-Content -LiteralPath $locked -Raw).Trim() -eq 'x') '... and the file is unchanged'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('Passed: {0}   Failed: {1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
