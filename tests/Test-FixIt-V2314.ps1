# "Who helps you?" tests: the helper setting (Trey, or a family member with a first name and an email address), every message naming the helper,
# the report with the helper in it, the words for "this went to Trey for now", Windows Quick Assist for other helpers, the first-run question and the
# "Your helper" item. The window needs Windows, so these use the REAL program functions with pretend settings, pretend sending and pretend windows.
# Usage:  pwsh ./tests/Test-FixIt-V2314.ps1       (Test-FixIt.ps1 runs this one too and adds its numbers)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fixit-v2314-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:Pass = 0; $script:Fail = 0
function Assert { param([bool]$Cond, [string]$Name) if ($Cond) { $script:Pass++ } else { $script:Fail++; Write-Host ('  FAIL: ' + $Name) -ForegroundColor Red } }
function Section { param([string]$T) Write-Host ('== ' + $T) }

$src = Join-Path $root 'FamilyFixIt.ps1'
$outDir = Join-Path $tmp 'out'; New-Item -ItemType Directory -Path $outDir | Out-Null
$env:LOCALAPPDATA = Join-Path $tmp 'local'; New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
$env:COMPUTERNAME = 'TESTPC'
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v2314.log') -OutputDir $outDir
Initialize-FixItLog
$srcText = [IO.File]::ReadAllText($src)
$tokens = $null; $perr = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$perr)
function Get-Fn { param([string]$Name) $f = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1; if ($null -eq $f) { return '' }; return $f.Extent.Text }
# made-up addresses are built from pieces so no address is written out in this file
$AT = '@'
$mikeMail = 'mike' + $AT + 'family.test'
function Reset-State {
    $f = Get-FixItStateFile
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
    $script:LastDelivery = $null; $script:HelperChanged = $false
}
function Set-TestHelper { param([string]$Name = 'Mike', [string]$Email = $mikeMail, [string]$Status = '') [void](Save-FixItHelper -Other $true -Name $Name -Email $Email); if ($Status) { Set-FixItSetting -Name 'HelperStatus' -Value $Status } }
$Mark = $script:TreyMark

# ================================================================ 1. the setting
Section 'The helper setting: Trey is the default'
Reset-State
$h = Get-FixItHelper
Assert ($h.IsTrey -and $h.Name -eq 'Trey' -and $h.Confirmed) 'with nothing saved the helper is Trey'
Assert ((ConvertTo-FixItHelperText 'Please call Trey and ask him.') -eq 'Please call Trey and ask him.') 'with Trey as the helper no words change'
Assert ((ConvertTo-FixItHelperText ('Sent to ' + $Mark + '.')) -ceq 'Sent to Trey.' -and -not [string]::Equals($Mark, 'Trey', [StringComparison]::Ordinal)) 'the Trey mark turns back into a plain Trey'
Assert ((Get-FixItHelperStatusLine) -eq 'Trey') 'the left-hand item says Trey'
$r = Save-FixItHelper -Other $false
Assert ($r.Saved -and -not $r.Changed -and (Get-FixItHelper).IsTrey) 'choosing Trey when it is already Trey changes nothing'

Section 'The helper setting: someone else'
$r = Save-FixItHelper -Other $true -Name '' -Email $mikeMail
Assert (-not $r.Saved -and $r.Message -match 'first name') 'no name: asks for it, saves nothing'
$r = Save-FixItHelper -Other $true -Name 'Mike' -Email 'mike.at.family.test'
Assert (-not $r.Saved -and $r.Message -match 'email address' -and (Get-FixItHelper).IsTrey) 'a bad email address: asks again, saves nothing'
Assert ((ConvertTo-FixItHelperEmail ('mike' + $AT + 'a..b.test')) -eq '' -and (ConvertTo-FixItHelperEmail ('a' + $AT + 'b')) -eq '' -and (ConvertTo-FixItHelperEmail ('two words' + $AT + 'b.test')) -eq '') 'odd addresses are refused'
Assert ((ConvertTo-FixItHelperEmail ('  Mike.Smith' + $AT + 'Family.Test ')) -eq ('mike.smith' + $AT + 'family.test')) 'an address is trimmed and made lower case'
Assert ((ConvertTo-FixItHelperName '  Mi<ke>  ') -eq 'Mike' -and (ConvertTo-FixItHelperName 'Maria Jose Fernandez-Lopez-Garcia').Length -le 14) 'a name is cleaned and capped at 14 characters'
$r = Save-FixItHelper -Other $true -Name 'Mike' -Email $mikeMail
$h = Get-FixItHelper
Assert ($r.Saved -and $r.Changed -and $r.EmailChanged -and -not $h.IsTrey -and $h.Name -eq 'Mike' -and $h.Email -eq $mikeMail) 'a name and a good address are saved'
Assert ($h.PcId -match '^[0-9a-f]{32}$' -and -not $h.Confirmed -and $h.Status -eq '') 'a random PC number is made, and the helper has not said yes yet'
$pc1 = $h.PcId
$r2 = Save-FixItHelper -Other $true -Name 'Mike' -Email $mikeMail
Assert ($r2.Saved -and -not $r2.Changed -and -not $r2.EmailChanged -and (Get-FixItHelper).PcId -eq $pc1) 'saving the same helper again changes nothing (idempotent), the PC number stays'
Set-FixItSetting -Name 'HelperStatus' -Value 'confirmed'
$r3 = Save-FixItHelper -Other $true -Name 'Mike' -Email $mikeMail
Assert ((Get-FixItHelper).Confirmed -and -not $r3.Changed) 'the yes already given is kept when the same helper is saved again'
$r4 = Save-FixItHelper -Other $true -Name 'Mike' -Email ('mike2' + $AT + 'family.test')
Assert ($r4.EmailChanged -and -not (Get-FixItHelper).Confirmed -and (Get-FixItHelper).PcId -eq $pc1) 'a new address starts again without a yes (same PC number)'
$r5 = Save-FixItHelper -Other $true -Name 'Mikey' -Email ('mike2' + $AT + 'family.test')
Assert ($r5.Changed -and -not $r5.EmailChanged) 'a new name alone is a change but does not ask the helper again'
$r6 = Save-FixItHelper -Other $false
Assert ($r6.Changed -and (Get-FixItHelper).IsTrey -and (Get-FixItHelperName) -eq 'Trey') 'choosing Trey again puts everything back'
Assert ((Get-FixItSetting -Name 'HelperAsked' -Default '') -match '^\d{4}-\d\d-\d\d$') 'the date the question was answered is saved'
Set-FixItSetting -Name 'HelperName' -Value 'Mike'; Set-FixItSetting -Name 'HelperEmail' -Value ''
Assert ((Get-FixItHelper).IsTrey) 'a name without an address is treated as Trey (never half a helper)'

# ================================================================ 2. words
Section 'Every message names the helper'
Reset-State; Set-TestHelper
Assert ((ConvertTo-FixItHelperText 'Send Trey a report') -eq 'Send Mike a report') 'Send Mike a report'
Assert ((ConvertTo-FixItHelperText "Trey's help; ask him; he can see; call him") -eq "Mike's help; ask Mike; Mike can see; call Mike") 'his name, and him/he become the name'
Assert ((ConvertTo-FixItHelperText ("Went to $Mark for now. Trey")) -eq 'Went to Trey for now. Mike') 'the Trey mark stays Trey, other Treys change'
Assert ((ConvertTo-FixItHelperText 'Treyvon is fine') -eq 'Treyvon is fine') 'only the whole word Trey changes'
$tbl = Get-FixItActionTable
Assert ($tbl['Report'].Title -eq 'Send Mike a report' -and $tbl['Screen'].Title -eq 'Share my screen' -and $tbl['Donate'].Title -eq 'Thank Mike') 'the button names say Mike'
Assert ($tbl.ContainsKey('YourHelper') -and $tbl['YourHelper'].Fn -eq 'Invoke-FixItYourHelper') 'there is a "Your helper" action'
Assert ((Get-FixItHelpText -Key 'Report').Text -notmatch 'Trey' -and (Get-FixItHelpText -Key 'Report').Text -match 'Mike') 'the ? help for the report names Mike'
Assert ((Get-FixItHelpText -Key 'Screen').Text -match 'Quick Assist' -and (Get-FixItHelpText -Key 'Screen').Text -notmatch 'Zoho|Trey') 'the ? help for the screen is about Quick Assist and Mike'
$plan = Get-FixItPlan -Which 'Report'
Assert ($plan.Title -eq 'Send Mike a report' -and (($plan.Does + $plan.Heads) -join ' ') -notmatch 'Trey.*Trey.*Trey') 'the plan window names Mike'
Assert (@($plan.Heads | Where-Object { $_ -match 'Mike has not said yes yet, so this report goes to Trey for now' }).Count -eq 1) 'until Mike says yes, the plan says the report goes to Trey for now'
$sp = Get-FixItPlan -Which 'Screen'
Assert (($sp.Does -join ' ') -match 'Quick Assist' -and ($sp.Does -join ' ') -match '6-digit code' -and ($sp.Does -join ' ') -match 'Allow' -and ($sp.Does + $sp.Heads -join ' ') -notmatch 'Zoho|Trey') 'the screen plan is the Quick Assist steps in plain words'
Assert (@($sp.Heads | Where-Object { $_ -match 'Only do this if YOU called Mike' }).Count -eq 1) 'the screen plan keeps the "only if YOU called" line'
Set-FixItSetting -Name 'HelperStatus' -Value 'confirmed'
$plan2 = Get-FixItPlan -Which 'Report'
Assert (@($plan2.Heads | Where-Object { $_ -match 'has not said yes' }).Count -eq 0) 'after the yes the plan has no "not said yes" line'
$res = New-FixItResult $true 'Done' "Please call Trey. He can help." @()
Assert ($res.Message -eq 'Please call Mike. Mike can help.') 'results name Mike'
$hm = Get-FixItHardwareMessage @([pscustomobject]@{ Message = 'Your computer is starting to fail. Please call Trey soon.' })
Assert ($hm -notmatch 'Trey' -and $hm -match 'call Mike soon') 'the pop-up warnings name Mike'
$pv = Get-FixItPrivacyContent
Assert (($pv.Groups[0].Heading) -match "Send Mike a report" -and $pv.Groups[0].Heading -notmatch 'Trey' -and $pv.Intro -match 'You picked Mike as your helper' -and $pv.Intro -match 'not kept for Trey') 'the "What''s shared" window names Mike and says reports for Mike are not kept for Trey'
Assert ($pv.Intro -match 'send one email to ask Mike to say yes') 'the "What''s shared" window says the one hello email is sent'
$g = @(Get-FixItBuiltInGuides)
Assert ($g[0].Title -eq 'Take a screenshot and send it to Mike' -and ($g[0].Steps -join ' ') -match 'email to Mike' -and ($g[0].Steps -join ' ') -notmatch 'Trey') 'the built-in guide names Mike'
$gj = ConvertTo-FixItGuides ('[{"id":"x","title":"Call Trey","steps":["Tell him what you see.","Ask Trey"],"keywords":["a"]}]' | ConvertFrom-Json)
Assert ($gj[0].Title -eq 'Call Mike' -and $gj[0].Steps[0] -eq 'Tell Mike what you see.' -and $gj[0].Steps[1] -eq 'Ask Mike') 'guides from guides.json name Mike too'
Reset-State
Assert ((ConvertTo-FixItGuides ('[{"id":"x","title":"Call Trey","steps":["Ask him"],"keywords":["a"]}]' | ConvertFrom-Json))[0].Steps[0] -eq 'Ask him') 'with Trey as the helper the guides are not touched'

Section 'Pronouns: every program sentence about Trey is turned into the helper''s name'
Reset-State; Set-TestHelper
$leftover = New-Object System.Collections.ArrayList
$strs = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst] }, $true)
$checked = 0
foreach ($s in $strs) {
    $v = [string]$s.Value
    if ($v -notmatch '\bTrey\b' -or $v.Length -lt 12 -or $v.Length -gt 600) { continue }
    if ($v -match 'github|Sodapopnewb|Invoke-|^\s*(Started|Finished)') { continue }
    $checked++
    $o = ConvertTo-FixItHelperText $v
    if ($o -match '\bTrey\b') { continue }   # on purpose, or not text for the window
    if ($v -match '(?i)\b(him|he|his)\b' -and $o -match '(?i)\b(him|he|his)\b') { [void]$leftover.Add(($s.Extent.StartLineNumber.ToString() + ': ' + $v.Substring(0, [Math]::Min(80, $v.Length)))) }
}
Assert ($checked -gt 40) ('the scan looked at the program sentences (' + $checked + ')')
Assert ($leftover.Count -eq 0) ('no "him / he / his" is left behind after Trey became Mike: ' + ($leftover -join ' | '))
Reset-State

# ================================================================ 3. the report
Section 'The report carries the helper'
$j = Get-FixItReportJson -Text 'hello text' -Kind 'report' | ConvertFrom-Json
Assert ($j.kind -eq 'report' -and $j.report -eq 'hello text' -and -not ($j.PSObject.Properties.Name -contains 'helper') -and -not ($j.PSObject.Properties.Name -contains 'owner')) 'with Trey the report is exactly as it always was (no helper part)'
Set-TestHelper
$j = Get-FixItReportJson -Text 'hello text' -Kind 'report' | ConvertFrom-Json
Assert ($j.helper.name -eq 'Mike' -and $j.helper.email -eq $mikeMail -and $j.helper.pcId -eq (Get-FixItHelper).PcId -and ($j.PSObject.Properties.Name -contains 'owner')) 'with Mike the report holds his name, address, PC number and the owner name'
$big = 'x' * (700 * 1024)
$jb = Get-FixItReportJson -Text $big -Kind 'report'
Assert ((New-Object Text.UTF8Encoding($false)).GetByteCount($jb) -lt 512000 -and ($jb | ConvertFrom-Json).helper.email -eq $mikeMail) 'a very long report is still cut to fit and keeps the helper part'

Section 'Where the report went'
$script:ReportUrl = 'https://example.invalid/report'
$script:WebAnswer = $null; $script:WebCalls = 0
function Send-WebReport { param($Url, $Json, $AppValue) $script:WebCalls++; return $script:WebAnswer }
function Body { param([string]$D, [string]$St, [bool]$Sent = $false, [string]$Why = '') return ('{"ok":true,"delivery":"' + $D + '","helperStatus":"' + $St + '","confirmSent":' + $Sent.ToString().ToLower() + ',"confirmReason":"' + $Why + '"}') }
Reset-State
$script:WebAnswer = [pscustomobject]@{ Code = 200; Body = (Body 'trey' 'none') }
Assert ((Send-FixItReport -Text 'a') -and (Get-FixItRecipient) -eq 'Trey' -and (Get-FixItDeliveryNote) -eq '') 'Trey as the helper: the report goes to Trey and there is no extra note'
$script:WebAnswer = 200
Assert ((Send-FixItReport -Text 'a') -and $script:LastDelivery.Delivery -eq 'trey') 'an older plain number answer still counts as sent'
Set-TestHelper
$script:WebAnswer = [pscustomobject]@{ Code = 200; Body = (Body 'trey' 'pending' $true 'sent') }
Assert (Send-FixItReport -Text 'a' -Kind 'report')  'a report is sent while the helper has not said yes'
Assert ((Get-FixItRecipient) -eq $Mark -and (Get-FixItHelper).Status -eq 'pending') 'it went to Trey for now, and "pending" is remembered'
$note = ConvertTo-FixItHelperText (Get-FixItDeliveryNote)
Assert ($note -match 'Mike has not said yes yet' -and $note -match 'went to Trey for now' -and $note -match 'I just emailed Mike to ask' -and $note -notmatch 'Mike for now') 'the note: Mike has not said yes yet, went to Trey, Mike was just asked'
Assert ((Get-FixItHelperStatusLine) -eq 'Mike (waiting)') 'the left-hand item says "Mike (waiting)"'
$script:WebAnswer = [pscustomobject]@{ Code = 200; Body = (Body 'trey' 'pending' $false 'recent') }
[void](Send-FixItReport -Text 'a')
Assert ((ConvertTo-FixItHelperText (Get-FixItDeliveryNote)) -match 'was already asked by email') 'asked recently: "already asked by email"'
$script:WebAnswer = [pscustomobject]@{ Code = 200; Body = (Body 'helper' 'confirmed') }
[void](Send-FixItReport -Text 'a')
Assert ((Get-FixItRecipient) -eq 'Mike' -and (Get-FixItDeliveryNote) -eq '' -and (Get-FixItHelper).Confirmed -and (Get-FixItHelperStatusLine) -eq 'Mike') 'after the yes the report goes to Mike, with no note'
$script:WebAnswer = [pscustomobject]@{ Code = 200; Body = (Body 'trey' 'confirmed' $false 'send-failed') }
[void](Send-FixItReport -Text 'a')
Assert ((ConvertTo-FixItHelperText (Get-FixItDeliveryNote)) -match 'could not email Mike just now' -and (Get-FixItRecipient) -eq $Mark) 'the helper said yes but the email failed: told so, report went to Trey'
$script:WebAnswer = [pscustomobject]@{ Code = 200; Body = (Body 'trey' 'stopped') }
[void](Send-FixItReport -Text 'a')
Assert ((ConvertTo-FixItHelperText (Get-FixItDeliveryNote)) -match 'turned these emails off' -and (ConvertTo-FixItHelperText (Get-FixItDeliveryNote)) -match 'Your helper') 'the helper turned the emails off: told so, with the way to pick someone else'
$script:WebAnswer = [pscustomobject]@{ Code = 200; Body = 'not json at all' }
Assert ((Send-FixItReport -Text 'a') -and $script:LastDelivery.Delivery -eq 'trey') 'an answer that is not understood is treated as "went to Trey"'
$script:WebAnswer = [pscustomobject]@{ Code = 429; Body = '' }
Assert (-not (Send-FixItReport -Text 'a')) 'a refusal is "not sent"'
$script:WebAnswer = $null
Assert (-not (Send-FixItReport -Text 'a')) 'no answer is "not sent"'
Set-FixItSetting -Name 'HelperStatus' -Value ''; $script:LastDelivery = $null
Assert ((Get-FixItHelperHelloText) -match 'could not email Mike') 'the hello text when nothing is known: says it could not email yet'

Section 'The report messages'
Reset-State; Set-TestHelper
$script:WebAnswer = [pscustomobject]@{ Code = 200; Body = (Body 'trey' 'pending' $true 'sent') }
$old = $script:ReportsWhere
$r = Invoke-FixItReport
Assert ($r.Ok -and $r.Message -match 'Report sent to Trey' -and $r.Message -notmatch 'Report sent to Mike' -and (($r.Message + ($r.Details -join ' ')) -match 'Mike has not said yes yet')) 'before the yes: "Report sent to Trey" and why'
$script:WebAnswer = [pscustomobject]@{ Code = 200; Body = (Body 'helper' 'confirmed') }
$r = Invoke-FixItReport
Assert ($r.Ok -and $r.Message -match 'Report sent to Mike' -and $r.Message -notmatch 'Trey') 'after the yes: "Report sent to Mike"'
$rt = Get-FixItReportText -Kind 'report' -Note ''
Assert ($rt -match 'sent to Mike by the tool' -and $rt -match 'to Trey until Mike has said yes') 'the saved report says who it is sent to'
$script:WebAnswer = [pscustomobject]@{ Code = 200; Body = (Body 'helper' 'confirmed') }
$sa = Invoke-ScamAlert
Assert ($sa.Message -notmatch 'Trey' -and $sa.Message -match 'Mike' -and $sa.Message -notmatch 'never asks you for codes') 'the scary pop-up message names Mike and does not promise Mike never asks for a code'
Reset-State
$script:WebAnswer = [pscustomobject]@{ Code = 200; Body = (Body 'trey' 'none') }
$r = Invoke-FixItReport
Assert ($r.Ok -and $r.Message -match 'Report sent to Trey') 'Trey as the helper: "Report sent to Trey", as before'
$rt = Get-FixItReportText -Kind 'report' -Note ''
Assert ($rt -match 'sent to Trey by the tool' -and $rt -notmatch 'until') 'Trey as the helper: the saved report line is as before'

# ================================================================ 4. the hello
Section 'Choosing a helper sends one hello'
Reset-State
$script:Sent = New-Object System.Collections.ArrayList; $script:Shown = New-Object System.Collections.ArrayList
$realSend = (Get-Command Send-FixItReport).ScriptBlock
function Send-FixItReport { param([string]$Text, [string]$Kind = 'report') [void]$script:Sent.Add($Kind); $script:LastDelivery = [pscustomobject]@{ Delivery = 'trey'; Status = 'pending'; ConfirmSent = $true; Reason = 'sent' }; return $true }
function Show-FixItHelperAnswer { param([string]$Text) [void]$script:Shown.Add($Text) }
$s = Save-FixItHelper -Other $true -Name 'Mike' -Email $mikeMail
Complete-FixItHelperChange -Save $s
Assert ($script:Sent.Count -eq 1 -and $script:Sent[0] -eq 'hello' -and $script:HelperChanged) 'one hello is sent, and the window is told to redraw'
Assert ($script:Shown.Count -eq 1 -and $script:Shown[0] -match 'I emailed Mike to ask' -and $script:Shown[0] -match 'spam' -and $script:Shown[0] -match [regex]::Escape("your reports go to $Mark")) 'the answer says Mike was emailed, mentions the spam folder and that reports go to Trey until the yes'
$s = Save-FixItHelper -Other $true -Name 'Mike' -Email $mikeMail
Complete-FixItHelperChange -Save $s
Assert ($script:Sent.Count -eq 1 -and $script:Shown.Count -eq 1) 'saving the same helper again sends nothing more'
Reset-State; $script:Sent.Clear(); $script:Shown.Clear()
Complete-FixItHelperChange -Save (Save-FixItHelper -Other $false)
Assert ($script:Sent.Count -eq 0 -and $script:Shown.Count -eq 0) 'choosing Trey sends nothing and shows nothing'
Complete-FixItHelperChange -Save (Save-FixItHelper -Other $true -Name '' -Email '')
Assert ($script:Sent.Count -eq 0) 'a refused choice sends nothing'
function Send-FixItReport { param([string]$Text, [string]$Kind = 'report') throw 'offline' }
$s = Save-FixItHelper -Other $true -Name 'Mike' -Email $mikeMail
Complete-FixItHelperChange -Save $s
Assert ($script:Shown.Count -eq 1 -and $script:Shown[0] -match 'could not email Mike just now') 'if the hello cannot be sent the answer says so (no error shown)'
Set-Item -Path function:Send-FixItReport -Value $realSend
Reset-State

# ================================================================ 5. Quick Assist
Section 'Screen sharing: Zoho for Trey, Quick Assist for others'
$script:Opened = New-Object System.Collections.ArrayList; $script:QaHow = 'App'
function Open-FixItUrl { param([string]$Url) [void]$script:Opened.Add($Url); return $true }
function Start-FixItQuickAssist { [void]$script:Opened.Add('quickassist'); return $script:QaHow }
Reset-State
$r = Invoke-ScreenShare
Assert ($r.Ok -and $script:Opened.Count -eq 1 -and $script:Opened[0] -match 'zoho') 'Trey: the Zoho Assist page opens, as before'
$script:Opened.Clear(); Set-TestHelper
$r = Invoke-ScreenShare
Assert ($r.Ok -and $script:Opened.Count -eq 1 -and $script:Opened[0] -eq 'quickassist') 'Mike: Quick Assist opens and the Zoho page does not'
Assert ($r.Message -match '6-digit code' -and $r.Message -match 'Submit' -and $r.Message -match 'Allow' -and $r.Message -match 'Only do this if YOU called Mike' -and $r.Message -notmatch 'Trey|Zoho') 'the answer: the code, Submit, Allow, and the "only if YOU called" line'
$script:QaHow = 'Store'; $script:Opened.Clear()
$r = Invoke-ScreenShare
Assert ($r.Ok -and $r.Message -match 'Microsoft Store' -and $r.Message -match 'Get' -and $r.Message -match 'again') 'no Quick Assist on this PC: the Store page opens and the answer says what to click'
$script:QaHow = 'Failed'
$r = Invoke-ScreenShare
Assert (-not $r.Ok -and $r.Message -match 'Windows key' -and $r.Message -match 'Ctrl' -and $r.Message -match 'Q') 'if nothing opens: the Windows + Ctrl + Q way is given'
$script:DryRun = $true; $script:Opened.Clear()
$r = Invoke-ScreenShare
Assert ($r.Ok -and $r.Title -eq 'Practice run' -and $script:Opened.Count -eq 0) 'a practice run opens nothing'
$script:DryRun = $false
Remove-Item function:Start-FixItQuickAssist; Remove-Item function:Open-FixItUrl
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v2314.log') -OutputDir $outDir
Reset-State

Section 'Quick Assist: the opening function'
$script:Procs = New-Object System.Collections.ArrayList
$script:HasCmd = $true; $script:HasUri = $true; $script:StartFails = @()
function Start-Process { param([string]$FilePath, $ArgumentList, [switch]$PassThru) if ($script:StartFails -contains $FilePath) { throw 'no' }; [void]$script:Procs.Add($FilePath); return $null }
function Test-FixItCommandPresent { param([string]$Name) return $script:HasCmd }
function Test-FixItUriHandler { param([string]$Scheme) return $script:HasUri }
Assert ((Start-FixItQuickAssist) -eq 'App' -and $script:Procs[0] -eq 'quickassist.exe') 'quickassist.exe is started when it is there'
$script:Procs.Clear(); $script:HasCmd = $false
Assert ((Start-FixItQuickAssist) -eq 'App' -and $script:Procs[0] -eq 'ms-quick-assist:') 'otherwise the ms-quick-assist: address is opened'
$script:Procs.Clear(); $script:HasUri = $false
Assert ((Start-FixItQuickAssist) -eq 'Store' -and $script:Procs[0] -eq 'ms-windows-store://pdp/?ProductId=9P7BP5VNWKX5') 'otherwise the Quick Assist page in the Microsoft Store is opened (nothing is installed)'
$script:Procs.Clear(); $script:StartFails = @('ms-windows-store://pdp/?ProductId=9P7BP5VNWKX5')
Assert ((Start-FixItQuickAssist) -eq 'Failed') 'if even the Store page will not open: Failed'
$script:StartFails = @(); $script:HasCmd = $true; $script:Procs.Clear()
$script:TestMode = $true
$script:QaR = ''
[void](Invoke-FixItStep 'Open Windows Quick Assist' { $script:QaR = [string](Start-FixItQuickAssist) })
Assert ($script:QaR -eq 'App' -and $script:Procs.Count -eq 0) 'in test mode (inside a checked step) nothing is started'
$script:TestMode = $false
Remove-Item function:Start-Process; Remove-Item function:Test-FixItCommandPresent; Remove-Item function:Test-FixItUriHandler
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v2314.log') -OutputDir $outDir
Reset-State

# ================================================================ 6. first run and the item
Section 'First run: the question is asked once, on a fresh install only'
$p = Get-FixItFirstRunPlan -Pending '1' -PrivacyShown '' -NameAsked '' -Interactive $true -HelperAsked ''
Assert ($p.AskHelper -and $p.ShowPrivacy -and $p.AskName) 'a fresh install asks the privacy page, the name and the helper'
$p = Get-FixItFirstRunPlan -Pending '1' -PrivacyShown '2026-01-01' -NameAsked '2026-01-01' -Interactive $true -HelperAsked '2026-01-01'
Assert (-not $p.AskHelper -and -not $p.ShowPrivacy) 'once answered it is never asked again'
$p = Get-FixItFirstRunPlan -Pending '1' -PrivacyShown '' -NameAsked '' -Interactive $false -HelperAsked ''
Assert (-not $p.AskHelper) 'a silent start or practice run asks nothing'
$p = Get-FixItFirstRunPlan -Pending '' -PrivacyShown '' -NameAsked '' -Interactive $true -HelperAsked ''
Assert (-not $p.AskHelper) 'an existing install (nothing pending) is not asked: it keeps Trey and can use "Your helper"'
$script:CalledFR = New-Object System.Collections.ArrayList
function Show-FixItPrivacyForm { param([bool]$FirstRun) [void]$script:CalledFR.Add('privacy') }
function Show-FixItNameForm { [void]$script:CalledFR.Add('name'); return $true }
function Show-FixItHelperForm { param([bool]$FirstRun = $false) [void]$script:CalledFR.Add('helper' + $FirstRun); return (Save-FixItHelper -Other $false) }
Show-FixItFirstRunWindows -ShowPrivacy $true -AskName $true -AskHelper $true
Assert (($script:CalledFR -join ',') -eq 'privacy,name,helperTrue') 'the windows come in order: what is shared, your name, who helps you'
$script:CalledFR.Clear()
Show-FixItFirstRunWindows -ShowPrivacy $false -AskName $false -AskHelper $false
Assert ($script:CalledFR.Count -eq 0) 'nothing is shown when nothing is asked'
Remove-Item function:Show-FixItPrivacyForm; Remove-Item function:Show-FixItNameForm; Remove-Item function:Show-FixItHelperForm
. $src -LibraryOnly -LogPath (Join-Path $tmp 'v2314.log') -OutputDir $outDir
Reset-State

Section 'The "Your helper" item and the window'
$lt = Get-FixItLayout -Simple $false
$ls = Get-FixItLayout -Simple $true
foreach ($pair in @(@('full', $lt), @('simple', $ls))) {
    $L = $pair[1]; $nm = $pair[0]
    Assert ($null -ne $L.Helper -and $L.Helper[0] -eq 'YourHelper' -and $L.Helper[1] -eq 'Your helper') ("the $nm window has the Your helper item")
    Assert ($null -ne $L.Donate -and $L.Helper[4] -ge ($L.Donate[4] + $L.Donate[5]) -and ($L.Helper[4] + $L.Helper[5]) -lt $L.FullH) ("$nm window: it sits under Thank Trey and inside the window")
    Assert (@($L.Footer).Count -eq 3) ("$nm window: the bottom row of links is unchanged (three links)")
}
Assert ($lt.FullH -gt $ls.FullH) 'the simple window is still shorter than the full one'
$lt2 = Get-FixItLayout -Simple $false -HelperIsTrey $false
$ls2 = Get-FixItLayout -Simple $true -HelperIsTrey $false
Assert ($null -eq $lt2.Donate -and $lt2.Helper[4] -eq 784 -and $lt2.FullH -eq 990 -and $null -eq $ls2.Donate -and $ls2.Helper[4] -eq 472 -and $ls2.FullH -eq 530) 'with another helper there is no Thank Trey item (it would send money to Trey) and the helper item takes its place, same window height'
$wf = Get-Fn 'Show-FixItWindowOnce'
Assert ($wf -match 'HelperIsTrey' -and $wf -match 'Get-FixItHelperStatusLine' -and $wf -match "lay\.Helper") 'the window draws the item with the helper''s name under it'
$gb = Get-Fn 'Invoke-GuiButton'
Assert ($gb -match "YourHelper" -and $gb -match 'RebuildUi' -and $gb -match 'HelperChanged') 'a change redraws the main window so every button names the new helper'
Assert ($srcText -match "'YourHelper'" -and $srcText -match "'PCInfo', 'Donate', 'Privacy', 'YourName', 'YourHelper'") 'Your helper is part of the all-buttons test list'
Assert ($srcText -match "(?s)\[ValidateSet\([^)]*'YourHelper'") 'it can be run from the command line: -Action YourHelper'
$script:TestMode = $true
$r = Invoke-FixItYourHelper
Assert ($r.Ok) 'test mode: only checks'
$script:TestMode = $false
$hf = Get-Fn 'Show-FixItHelperForm'
Assert ($hf -ne '' -and $hf -notmatch 'Start-Process|Invoke-WebRequest|Invoke-RestMethod|Send-FixItReport|-Method') 'the helper window itself sends and opens nothing'
Assert ($hf -match 'Who helps you with your computer\?' -or $srcText -match 'Who helps you with your computer\?') 'the window asks "Who helps you with your computer?"'
foreach ($t in @('Someone else', 'Their first name', 'Their email address', 'Skip', 'Cancel', 'Save')) { Assert ($hf.Contains($t)) ("the window has: $t") }
Assert ($hf -match 'Until they do, reports go to Trey') 'the window says reports go to Trey until the helper says yes'
# the 2.3.13 layout rules: sized text, a window that never gets taller than the screen, buttons that stay in view
Assert ($hf -match 'Limit-FixItDialogToScreen -Form \$f -Panel \$pn -Pinned @\(\$save, \$skip\)') 'the helper window is cut to the screen and keeps Save and Cancel in view'
Assert ($hf -match 'Get-FixItLabelHeight' -and $hf -match 'AutoScroll = \$true') 'the helper window measures its text with the shared helper and scrolls when the screen is small'
Assert ($hf -notmatch 'Expand-FixItLabelsToFit') 'the helper window sizes its own text (the labels are inside the scrolling panel)'
$ll = Get-FixItLayout -Simple $false -HelperIsTrey $true
Assert ($ll.Helper[4] -ge ($ll.Donate[4] + $ll.Donate[5]) -and ($ll.Helper[4] + $ll.Helper[5]) -lt $ll.FullH) 'the Your helper item sits under Thank Trey and fits in the 2.3.13 full-size window'

# ================================================================ 7. guards and files
Section 'Guards and files'
Assert ((Get-Fn 'Start-FixItQuickAssist') -match "(?s)^function Start-FixItQuickAssist \{\s+if \(\`$script:TestMode\) \{ Invoke-FixItProbe -Adapter 'Start-FixItQuickAssist' -Arguments \`$PSBoundParameters; return") 'the Quick Assist opener is a guarded adapter (test mode checks it and returns)'
Assert (([regex]::Matches($srcText, '-Method\s+Post')).Count -eq 1 -and (Get-Fn 'Send-WebReport') -match '-Method\s+Post') 'Send-WebReport is still the only place anything is posted'
$pre = Get-Fn 'Get-FixItPreflight'
Assert ($pre -match "'Start-FixItQuickAssist'") 'the test-mode preflight knows the Quick Assist opener'
Assert ($srcText -match "DefaultReportUrl = 'https://fixit-report\.hg-fixit\.workers\.dev/report'") 'the report address is still the one report service (no mail address is in the program)'
$bytes = [IO.File]::ReadAllBytes($src)
Assert (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'the program has no byte order mark'
Assert (-not ($bytes | Where-Object { $_ -gt 127 } | Select-Object -First 1)) 'the program is plain ASCII'
foreach ($f in @('tests/Test-FixIt-V2314.ps1', 'README.md', 'guides.json', 'worker/index.js', 'worker/test.mjs', 'worker/test-helper.mjs', 'worker/wrangler.jsonc', 'worker/README.md', 'worker/GMAIL-SETUP.md', 'worker/get-gmail-token', 'worker/mock-google.mjs', 'worker/test-gmail.mjs', 'worker/test-token-script.mjs')) {
    $fp = Join-Path $root $f
    if (-not (Test-Path -LiteralPath $fp)) { if ($f -notlike 'worker/*') { Assert $false "$f exists" }; continue }   # the service folder is only in the full repository, not in the family's download
    $b = [IO.File]::ReadAllBytes($fp)
    Assert (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB) -and -not ($b | Where-Object { $_ -gt 127 } | Select-Object -First 1)) "$f is ASCII with no byte order mark"
}
$pub = [IO.File]::ReadAllText((Join-Path $root 'tools/Publish-FixIt.ps1'))
Assert ($pub.Contains("'tests/Test-FixIt-V2314.ps1'")) 'the publish tool carries the new test file'
$rd = [IO.File]::ReadAllText((Join-Path $root 'README.md'))
Assert ($rd -match 'Who helps you' -and $rd -match 'Quick Assist' -and $rd -match 'Your helper') 'the README explains the helper, Quick Assist and the Your helper item'
Assert (($srcText -match "p2Title = 'Send my helper a report'") -and ($srcText -match "p1Title = 'Share my screen'")) 'the two big main buttons switch to short words when the helper name is long or not Trey'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('Passed: {0}   Failed: {1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
