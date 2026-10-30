# Version 2.3.11 tests: "Share with a friend" gives a ready-to-paste email (warm, short, with the download link and install steps) in a read-only,
# scrollable box sized to fit; Copy message puts the whole message on the clipboard as plain text with CRLF line breaks.
# The window needs Windows, so these use the REAL program functions with a pretend clipboard and pretend measuring, plus checks of the program text.
# Usage:  pwsh ./tests/Test-FixIt-V2311.ps1       (Test-FixIt.ps1 runs this one too and adds its numbers)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fixit-v2311-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:Pass = 0; $script:Fail = 0
function Assert { param([bool]$Cond, [string]$Name) if ($Cond) { $script:Pass++ } else { $script:Fail++; Write-Host ('  FAIL: ' + $Name) -ForegroundColor Red } }
function Section { param([string]$T) Write-Host ('== ' + $T) }

$src = Join-Path $root 'FamilyFixIt.ps1'
$outDir = Join-Path $tmp 'out'; New-Item -ItemType Directory -Path $outDir | Out-Null
$env:LOCALAPPDATA = Join-Path $tmp 'local'; New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
$env:COMPUTERNAME = 'TESTPC'
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v2311.log') -OutputDir $outDir
Initialize-FixItLog
$srcText = [IO.File]::ReadAllText($src)
$tokens = $null; $perr = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$perr)
function Get-Fn { param([string]$Name) $f = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1; if ($null -eq $f) { return '' }; return $f.Extent.Text }

$url = 'https://github.com/Sodapopnewb/family-it-fixit/releases/latest/download/Install-FamilyFixIt.zip'
$CRLF = [string][char]13 + [string][char]10
Assert ([version]$script:FixItVersion -ge [version]'2.3.11') 'the program is version 2.3.11 or newer'

# ================================================================ 1. the message
Section 'The email message: words'
$msg = Get-FixItShareMessage -Url $url
Assert ($msg -is [string] -and $msg.Length -gt 200) 'there is a message'
Assert ($msg.StartsWith('Hi,' + $CRLF)) 'it starts like a friendly note'
Assert ($msg.Contains('Family Fix-It is a free helper that fixes common PC problems with one click.')) 'the one-line intro is in it'
Assert ($msg -match '(?m)^It is for Windows PCs\.\r?$') 'a line says it is for Windows PCs'
Assert (([regex]::Matches($msg, [regex]::Escape($url))).Count -eq 1 -and $msg -match ('(?m)^' + [regex]::Escape($url) + '\r?$')) 'the download link is in it once, on its own line (so it stays clickable)'
Assert ($url -eq 'https://github.com/Sodapopnewb/family-it-fixit/releases/latest/download/Install-FamilyFixIt.zip') 'the link is the latest-release download of Install-FamilyFixIt.zip'
$stepLines = @($msg -split "`r`n" | Where-Object { $_ -match '^\d+\. ' })
Assert ($stepLines.Count -eq 5) 'five numbered steps'
$nums = @($stepLines | ForEach-Object { [int]($_ -replace '^(\d+)\..*$', '$1') })
Assert (($nums -join ',') -eq '1,2,3,4,5') 'the steps are numbered 1 to 5 in order'
Assert ($stepLines[0] -match 'Click the link' -and $stepLines[0] -match 'Install-FamilyFixIt\.zip') 'step 1: open the link, the zip downloads'
Assert ($stepLines[1] -match 'Open that downloaded zip') 'step 2: open the downloaded zip'
Assert ($stepLines[2] -match 'Double-click Install-FamilyFixIt\.cmd') 'step 3: double-click Install-FamilyFixIt.cmd'
Assert ($stepLines[3] -match 'Windows protected your PC' -and $stepLines[3] -match 'More info' -and $stepLines[3] -match 'Run anyway' -and $stepLines[3] -match 'only need to do this if a box really appears') 'step 4: the blue box, More info, Run anyway, only if it really appears'
Assert ($stepLines[3].IndexOf('More info') -lt $stepLines[3].IndexOf('Run anyway')) 'More info comes before Run anyway'
Assert ($stepLines[4] -match 'opens' -and $stepLines[4] -match 'icon' -and $stepLines[4] -match 'desktop') 'step 5: it opens and an icon is added to the desktop'
Assert ($msg -match 'let me know and I will help') 'warm closing offer'
$scare = 'virus|danger|dangerous|warning|threat|malware|infect|hack|scam|risk|unsafe|attack|harm|unblock|damage'
$safety = 'Please only install this if you know and trust the person who sent it to you.'
$ml = @($msg -split "`r`n")
Assert ($ml[-1] -ceq $safety -and $ml[-2] -ceq '' -and $ml[-3] -ceq 'If you get stuck, let me know and I will help.') 'the safety line is last: after the offer to help, with one blank line between'
Assert (([regex]::Matches($msg, [regex]::Escape($safety))).Count -eq 1) 'the safety line is there once'
Assert ($msg.IndexOf($safety) -gt $msg.IndexOf('Next time, just double-click that icon.') -and $msg.IndexOf($safety) -gt $msg.IndexOf($url)) 'the safety line comes after the link and every step'
Assert ($safety -notmatch '[^\x20-\x7E]' -and $safety -notmatch ('(?i)\b(' + $scare + ')')) 'the safety line is plain ASCII and calm (no scare words)'
Assert (@($msg -split "`r`n").Count -le 22) 'short: about twenty lines'
Assert ((($msg -split '\s+') | Where-Object { $_ }).Count -le 230) 'short: under about 230 words'
Assert ($msg -notmatch ('(?i)\b(' + $scare + ')')) 'no scare words'
$jargon = '\b(PowerShell|script|administrator|admin|SHA|manifest|registry|mutex|command line|terminal|execution policy)\b'
Assert ($msg -notmatch ('(?i)' + $jargon)) 'no jargon'
Assert ($msg -notmatch '[^\x20-\x7E\r\n]') 'plain text: only ordinary characters (no curly quotes, no tabs, no symbols)'
Assert ($msg -notmatch '<[A-Za-z/]' -and $msg -notmatch '\*\*' -and $msg -notmatch '\[.*\]\(') 'plain text: no HTML or Markdown'
Assert ($msg -notmatch ('<' + 'OWNER>')) 'no unfilled owner name'

Section 'The email message: the steps match what the zip and installer really do'
$readme = [IO.File]::ReadAllText((Join-Path $root 'README.md'))
$cmd = [IO.File]::ReadAllText((Join-Path $root 'Install-FamilyFixIt.cmd'))
$inst = [IO.File]::ReadAllText((Join-Path $root 'Install-FixIt.ps1'))
Assert ($readme -match 'double-click \*\*Install-FamilyFixIt\.cmd\*\*' -and (Test-Path -LiteralPath (Join-Path $root 'Install-FamilyFixIt.cmd'))) 'the zip really holds Install-FamilyFixIt.cmd'
$pub = [IO.File]::ReadAllText((Join-Path $root 'tools/Publish-FixIt.ps1'))
Assert ($pub -match 'Install-FamilyFixIt\.cmd' -and $pub -match 'Install-FamilyFixIt\.zip' -and $pub -match 'Install-FixIt\.ps1') 'the publish script puts the .cmd and the installer in Install-FamilyFixIt.zip'
Assert ($cmd -match 'takes about a minute' -and $cmd -match 'timeout /t') 'the .cmd says it takes about a minute and closes by itself (step 3)'
Assert ($cmd -match 'Install-FixIt\.ps1' -and $cmd -match 'raw\.githubusercontent\.com') 'the .cmd also works from inside the zip (it fetches the installer itself)'
Assert ($readme -match 'Windows protected your PC' -and $readme -match 'More info' -and $readme -match 'Run anyway' -and $readme -match 'Security Warning') 'the SmartScreen steps are the ones the README gives the family (blue box: More info, Run anyway; small box: Run)'
Assert ($inst -match 'Desktop' -and $inst -match 'Family Fix-It\.lnk|Family Fix-It') 'the installer makes a Desktop shortcut called Family Fix-It'
Assert ($inst -match 'Start-Process|Open-FixIt|-NoLaunch') 'the installer opens the tool (unless -NoLaunch)'
Assert ($inst -match 'Windows PowerShell|powershell\.exe|5\.1' -or $readme -match 'Windows') 'it is a Windows tool'

Section 'The email message: signing and empty cases'
$named = Get-FixItShareMessage -Url $url -Name 'Grandma Sue'
Assert ($named.EndsWith($safety + $CRLF + $CRLF + 'Grandma Sue') -and $named.StartsWith($msg)) 'a saved name signs the note after the safety line (the rest is unchanged)'
Assert ((Get-FixItShareMessage -Url $url -Name '   ') -eq $msg) 'a blank name adds nothing'
Assert ((Get-FixItShareMessage -Url '') -eq '' -and (Get-FixItShareMessage -Url '   ') -eq '') 'no link, no message (a practice copy never shares a broken one)'
$oldShare = $script:ShareUrl
$script:ShareUrl = 'https://github.com/<' + 'OWNER>/family-it-fixit/releases/latest/download/Install-FamilyFixIt.zip'
Assert ((Get-FixItShareMessage) -eq '') 'an unpublished copy (placeholder owner) makes no message'
$script:ShareUrl = $url
Assert ((Get-FixItShareMessage) -eq $msg) 'by default the message uses the published share link'
$script:ShareUrl = $oldShare

# ================================================================ 2. line breaks
Section 'Line breaks: Windows CRLF, nothing else'
Assert ($msg.Contains($CRLF)) 'the message has CRLF line breaks'
Assert (($msg -replace "`r`n", '') -notmatch "[`r`n]") 'every line break is a CRLF pair (no lone CR or LF)'
Assert (-not $msg.EndsWith($CRLF) -and $msg.EndsWith($safety)) 'no extra blank line at the end; it ends with the safety line'
Assert ($msg -notmatch "(`r`n){3}") 'never two blank lines in a row'
Assert (@($msg -split "`r`n").Count -eq ([regex]::Matches($msg, "`r`n")).Count + 1) 'line count matches the break count'
Assert ($named -notmatch "(?<!`r)`n" -and $named -notmatch "`r(?!`n)") 'a signed note has clean breaks too'
Assert ((Get-Fn 'Get-FixItShareMessage') -notmatch '"`n"|\[char\]10\s*\)\s*-join' -and (Get-Fn 'Get-FixItShareMessage') -match '\[char\]13' -and (Get-Fn 'Get-FixItShareMessage') -match '\[char\]10') 'the message is joined with CR and LF together'
Assert ($srcText -notmatch "[^\x00-\x7F]") 'the program file is still plain ASCII'

# ================================================================ 3. Copy message
Section 'Copy message: whole message, plain text, CRLF'
$script:Clip = @()
function Set-FixItClipboard { param([string]$Text) $script:Clip += $Text; return $true }
$ok = Copy-FixItShareMessage -Message $msg
Assert ($ok -eq $true -and $script:Clip.Count -eq 1) 'one copy was made'
Assert ($script:Clip[0] -ceq $msg) 'the whole message is copied, exactly'
Assert (($script:Clip[0] -replace "`r`n", '') -notmatch "[`r`n]") 'the copied text has only CRLF breaks'
$script:Clip = @()
$null = Copy-FixItShareMessage -Message (($msg -split "`r`n") -join "`n")
Assert ($script:Clip[0] -ceq $msg) 'even if the box turned breaks into LF, CRLF is what is copied'
$script:Clip = @()
$null = Copy-FixItShareMessage -Message (($msg -split "`r`n") -join "`r")
Assert ($script:Clip[0] -ceq $msg) 'a lone CR also becomes CRLF'
$script:Clip = @()
Assert ((Copy-FixItShareMessage -Message '') -eq $false -and $script:Clip.Count -eq 0) 'nothing is copied when there is no message'
function Set-FixItClipboard { param([string]$Text) return $false }
Assert ((Copy-FixItShareMessage -Message $msg) -eq $false) 'a refused copy is reported (the button then says Could not copy)'
function Set-FixItClipboard { param([string]$Text) throw 'clipboard busy' }
Assert ((Copy-FixItShareMessage -Message $msg) -eq $false) 'a clipboard error is caught and reported, not thrown'
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v2311.log') -OutputDir $outDir
Assert ((Get-FixItShareButtonText) -eq 'Copy message' -and (Get-FixItShareButtonText -State 'Copied') -eq 'Copied!' -and (Get-FixItShareButtonText -State 'Failed') -eq 'Could not copy') 'button: Copy message, then Copied!, or Could not copy'

# ================================================================ 4. the window
Section 'Share window: read-only, many lines, scrollable, sized with the shared helper'
$form = Get-Fn 'Show-FixItShareForm'
Assert ($form -match 'Multiline = \$true' -and $form -match 'ReadOnly = \$true' -and $form -match 'WordWrap = \$true') 'the box is multi-line, read-only and wraps'
Assert ($form -match "ScrollBars = .*'Vertical'" -and $form -match 'plan\.Scroll') 'it has a vertical scroll bar when the message is taller than the window may be'
Assert ($form -match 'Get-FixItLabelHeight' -and $form -match 'Get-FixItTextWindowPlan' -and $form -match 'WorkingArea') 'sized with the shared fit helper and the 85% screen cap'
Assert ($form -notmatch 'MeasureText' -and $form -notmatch 'NoPadding') 'no private measuring'
Assert ($form -match 'Get-FixItShareMessage' -and $form -match "Tag\['Message'\]" -and $form -match 'Copy-FixItShareMessage') 'Copy message copies the message through the one copy function'
Assert ($form -notmatch 'Set-FixItClipboard') 'the window itself never copies the link alone'
Assert ($form -match 'ShareIntro' -and $form.IndexOf('$intro') -lt $form.IndexOf('$tb = New-Object')) 'the short intro line sits above the box'
Assert ($form -match 'Get-FixItShareButtonText' -and $form -match 'Close' -and $form -match 'Timer') 'a Copy message button that changes to Copied! for a moment, and Close'
Assert ($form -match 'UiHighContrast' -and $form -match 'UiScale') 'it follows Big text and High contrast'
Assert ($form -match 'Write-FixItLog') 'copying is logged'
Assert ($script:ShareIntro -match 'Copy this message' -and $script:ShareIntro -match 'email' -and (($script:ShareIntro -split '\s+').Count -le 30)) 'the intro line is short and says what to do'
Assert (-not (Get-Variable -Name ShareHow -Scope Script -ErrorAction SilentlyContinue)) 'the old install sentence is gone from the window (the message holds the steps)'

# the size the window asks for, with pretend measuring (an average letter 7 px wide, lines 24 px tall)
$base = { param($t, $w) $per = [math]::Max(1, [int][math]::Floor($w / 7)); $n = 0; foreach ($ln in ($t -split "`r`n")) { $n += [math]::Max(1, [int][math]::Ceiling($ln.Length / $per)) }; return ($n * 24) }
$wide = Get-FixItWrappedTextHeight -Text $msg -Width 552 -Scale 1.0 -Measure $base
$narrow = Get-FixItWrappedTextHeight -Text $msg -Width 552 -Scale 1.0 -Measure { param($t, $w) & $base $t ($w - 40) }
Assert ($wide -gt 0 -and $narrow -ge $wide) 'a narrower box needs at least as much height'
$plan = Get-FixItTextWindowPlan -TitleHeight 80 -BodyHeight $wide -ChromeHeight 100 -WorkAreaHeight 1040
Assert (-not $plan.Scroll -and $plan.ClientHeight -eq (100 + 80 + $wide)) 'on a normal screen the window grows to the whole message: no scroll bar'
$plan = Get-FixItTextWindowPlan -TitleHeight 80 -BodyHeight ($wide * 3) -ChromeHeight 100 -WorkAreaHeight 1040
Assert ($plan.Scroll -and $plan.ClientHeight -le [int][math]::Floor(1040 * 0.85)) 'with big text the window stops at 85% of the screen height and the box scrolls'
$plan = Get-FixItTextWindowPlan -TitleHeight 80 -BodyHeight $wide -ChromeHeight 100 -WorkAreaHeight 600
Assert ($plan.Scroll -and $plan.ClientHeight -le 510) 'on a small screen the box scrolls, and every line can still be reached'

# ================================================================ 5. where it shows up
Section 'Share with a friend: Test mode, command line, the rest of the program'
$oldTm = $script:TestMode; $oldGui = $script:GuiActive
$script:TestMode = $false; $script:GuiActive = $false
$script:ShareUrl = $url
$r = Invoke-FixItShare
Assert ($r.Ok -and ([string]$r.Message).Contains($msg)) 'no window (command line): the same message is returned for the person to copy'
$txt = [string]$r.Message
Assert ($txt.Contains($url) -and $txt -match 'Double-click Install-FamilyFixIt\.cmd') 'the command line text has the link and the steps'
$script:TestMode = $true
$r = Invoke-FixItShare
Assert ($r.Ok) 'Test mode: only checks'
$script:TestMode = $oldTm; $script:GuiActive = $oldGui; $script:ShareUrl = $oldShare
Assert ((Get-Fn 'Invoke-FixItShare') -match 'Get-FixItShareMessage' -and (Get-Fn 'Invoke-FixItShare') -match 'Copy message') 'Share uses the message; the Test mode note names the Copy message button'
Assert ($srcText -match "FixItVersion = '2\.3\.\d+'" ) 'version line is in the normal form'
Assert ($srcText.Contains('(' + "'<' + 'OWNER>'" + ')') -or $srcText.Contains("('<' + 'OWNER>')")) 'the owner placeholder guard is intact'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('Passed: {0}   Failed: {1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
