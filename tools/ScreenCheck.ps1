<#
ScreenCheck.ps1  -  the pre-release SCREEN CHECK for Family Fix-It. It needs Windows (it runs on a GitHub Actions windows-latest runner,
see .github/workflows/screencheck.yml). It never runs on a family PC and never changes anything on the computer it runs on.

What it does, in plain words
  It loads FamilyFixIt.ps1 as a library (-LibraryOnly: nothing starts), then opens every window the program can show - the main window
  (3 variants), every "?" help window, every "Here is what I will do" window, the name, share, privacy, files, install-an-app, guides,
  PC info, scary pop-up, countdown, printer-pick, chrome-question and "did that fix it" windows, every help guide, the plain
  message boxes used for update messages, and the pop-up watcher's toast - one at a time, WITHOUT anyone clicking. A timer inside the
  window loop waits for a window to settle, measures it, takes a picture of it, and closes it.
  Then it looks for the things Trey found by eye: clipped or cut-off text, text that ends in "..." because it did not fit, empty or
  invisible buttons and labels, controls that overlap, controls outside their window or hanging off the screen, sideways scroll bars.
  It also checks that the watcher's tray icon is created, visible, not blank, and has its menu text.

How the size (100%, 150%, 200%) is simulated
  Family Fix-It is drawn by its own layout code: every size and font is "base number x UiScale", where UiScale is the Windows display scale
  read once at start (Graphics DpiX / 96; the program makes itself "system DPI aware" first). It does not use WinForms AutoScale. So this
  check sets UiScale directly to 1.0 / 1.5 / 2.0 in a FRESH process per scale (one CI job each). "Big text" in the program multiplies the scale
  by 1.25 more; "High contrast" is the program's own black/yellow setting. This is exact for the program's own windows. It does NOT
  change the real Windows DPI (that only changes at sign-in, which a CI job cannot do), so Windows' own pieces (title bars, message-box
  frames, scroll-bar widths) stay at 100% size. See the README in the report for the full list of limits.

Usage (on the runner):  powershell -ExecutionPolicy Bypass -File tools\ScreenCheck.ps1 -Scale 1.5 -Mode Normal -OutDir out
Exit code 1 when anything was found (or a window could not be opened).
#>
param(
    [double]$Scale = 1.0,
    [ValidateSet('Normal', 'BigText', 'HighContrast')][string]$Mode = 'Normal',
    [string]$OutDir = '',
    [string]$Only = '',
    [string]$AppScript = ''
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
if (-not $AppScript) { $AppScript = Join-Path $repo 'FamilyFixIt.ps1' }
$runTag = ('{0}x-{1}' -f $Scale.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture), $Mode)
if (-not $OutDir) { $OutDir = Join-Path (Get-Location).Path ('screencheck-out-' + $runTag) }
$shotDir = Join-Path $OutDir 'screenshots'
New-Item -ItemType Directory -Path $shotDir -Force | Out-Null
$work = Join-Path ([IO.Path]::GetTempPath()) ('screencheck-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

# ---- a clean, private pretend user (nothing real is read or changed) ------------------------------------------------------------
$env:LOCALAPPDATA = Join-Path $work 'local'; New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
$sampleDocs = [Environment]::GetFolderPath('MyDocuments')
$sampleNames = @(
    'Quarterly tax return and the family reunion photographs 2026 FINAL version 3 (copy) (copy).docx',
    'Mom and Dad anniversary trip itinerary and hotel confirmations.pdf',
    'Receipt.pdf', 'Averyveryveryverylongfilenamewithoutanyspacesatalltoseehowthewindowwrapsitaroundtheedge2026.xlsx',
    'School newsletter October.docx', 'Insurance card front and back.jpg')
foreach ($n in $sampleNames) { try { $p = Join-Path $sampleDocs $n; if (-not (Test-Path -LiteralPath $p)) { [IO.File]::WriteAllText($p, 'sample') } } catch { } }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace FixIt -Name Dpi -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -ErrorAction SilentlyContinue
[void][FixIt.Dpi]::SetProcessDPIAware()    # the same first step the program takes
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type -ReferencedAssemblies 'System.Drawing' -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
public static class ScNative {
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumThreadWindows(uint tid, EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    // The system message box (class #32770) of this thread, or zero.
    public static IntPtr FindMessageBox() {
        IntPtr found = IntPtr.Zero;
        EnumThreadWindows(GetCurrentThreadId(), delegate(IntPtr h, IntPtr l) {
            if (IsWindowVisible(h)) {
                StringBuilder sb = new StringBuilder(64); GetClassName(h, sb, 64);
                if (sb.ToString() == "#32770") { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    // Press OK / Cancel / No (whichever this box has).
    public static void DismissMessageBox(IntPtr h) {
        SendMessage(h, 0x111, (IntPtr)1, IntPtr.Zero);
        SendMessage(h, 0x111, (IntPtr)2, IntPtr.Zero);
        SendMessage(h, 0x111, (IntPtr)7, IntPtr.Zero);
    }
    // A picture of a whole window (title bar and frame too). Null when Windows would not draw it.
    public static Bitmap CaptureWindow(IntPtr h) {
        RECT r; if (!GetWindowRect(h, out r)) return null;
        int w = r.Right - r.Left, ht = r.Bottom - r.Top;
        if (w <= 0 || ht <= 0) return null;
        Bitmap bmp = new Bitmap(w, ht, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(bmp)) {
            g.Clear(Color.White);
            IntPtr dc = g.GetHdc();
            bool ok = PrintWindow(h, dc, 2);
            g.ReleaseHdc(dc);
            if (!ok) { bmp.Dispose(); return null; }
        }
        return bmp;
    }
    public static int[] WindowRect(IntPtr h) { RECT r; if (!GetWindowRect(h, out r)) return new int[] { 0, 0, 0, 0 }; return new int[] { r.Left, r.Top, r.Right, r.Bottom }; }
    // How many pixels inside the rectangle differ from the background (the colour of the rectangle's top-left pixel) by more than tol.
    public static int CountInk(Bitmap bmp, int x, int y, int w, int h, int tol) {
        if (x < 0) { w += x; x = 0; }
        if (y < 0) { h += y; y = 0; }
        if (x + w > bmp.Width) w = bmp.Width - x;
        if (y + h > bmp.Height) h = bmp.Height - y;
        if (w <= 0 || h <= 0) return 0;
        BitmapData d = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            byte[] buf = new byte[Math.Abs(d.Stride) * bmp.Height];
            Marshal.Copy(d.Scan0, buf, 0, buf.Length);
            int stride = Math.Abs(d.Stride);
            int bi = y * stride + x * 4;
            int b0 = buf[bi], g0 = buf[bi + 1], r0 = buf[bi + 2], a0 = buf[bi + 3];
            int count = 0;
            for (int yy = y; yy < y + h; yy++) {
                int p = yy * stride + x * 4;
                for (int xx = 0; xx < w; xx++, p += 4) {
                    if (Math.Abs(buf[p] - b0) > tol || Math.Abs(buf[p + 1] - g0) > tol || Math.Abs(buf[p + 2] - r0) > tol || Math.Abs(buf[p + 3] - a0) > tol) count++;
                }
            }
            return count;
        } finally { bmp.UnlockBits(d); }
    }
}
'@

# ---- load the program as a library (nothing starts) ----------------------------------------------------------------------------
. $AppScript -LibraryOnly -NoUpdateCheck -LogPath (Join-Path $work 'app.log') -OutputDir (Join-Path $work 'reports')
Initialize-FixItLog
$script:GuiActive = $true
$script:GuiInstance = $null
$appVersion = [string]$script:FixItVersion

# Things the windows would read from the real PC: use fixed, offline answers (so the picture is the same every run).
$script:H_Simple = $false; $script:H_Guardian = $true; $script:H_CheckIn = $true
$script:H_Pill = [pscustomobject]@{ Ok = $true; Text = ('Your computer looks healthy ' + [string][char]0x00B7 + ' backup partly on') }
function Test-FixItSimpleMode { return [bool]$script:H_Simple }
function Test-FixItGuardianInstalled { return [bool]$script:H_Guardian }
function Test-FixItTask { param([string]$Name) return [bool]$script:H_CheckIn }
function Get-FixItHealthPill { return $script:H_Pill }
function Get-FixItGuides {
    $t = Get-FixItLocalGuidesText
    $g = @(); if ($t) { $g = @(ConvertTo-FixItGuides ($t | ConvertFrom-Json)) }
    if ($g.Count -eq 0) { $g = @(Get-FixItBuiltInGuides) }
    return $g
}
function Get-FixItApprovedApps {
    $apps = @(); $p = Join-Path $script:InstallDir 'apps.json'
    if (Test-Path -LiteralPath $p) { foreach ($a in @(([IO.File]::ReadAllText($p)) | ConvertFrom-Json)) { $ca = ConvertTo-FixItApp $a; if ($null -ne $ca) { $apps += $ca } } }
    if ($apps.Count -eq 0) { foreach ($a in $script:DefaultApps) { $ca = ConvertTo-FixItApp $a; if ($null -ne $ca) { $apps += $ca } } }
    return $apps
}

# ---- the look settings of this run (the same variables Show-FixItWindowMain sets) ----------------------------------------------
$script:UiBigText = ($Mode -eq 'BigText')
$script:UiHighContrast = ($Mode -eq 'HighContrast')
$script:UiScale = $Scale; if ($script:UiBigText) { $script:UiScale = $Scale * 1.25 }
$script:UiBack = '#FAFAFA'; if ($script:UiHighContrast) { $script:UiBack = '#000000' }
$script:UiSide = '#F0F3F8'; if ($script:UiHighContrast) { $script:UiSide = '#000000' }
$script:UiIcons = Get-FixItIconMap
function Initialize-HarnessFonts {
    $S = $script:UiScale; $px = [System.Drawing.GraphicsUnit]::Pixel
    # the same fonts Show-FixItWindowOnce makes (needed by tiles in windows other than the main one)
    $script:UiFonts = @{
        Title = New-Object System.Drawing.Font('Segoe UI', [single](14 * $S), [System.Drawing.FontStyle]::Bold, $px)
        Small = New-Object System.Drawing.Font('Segoe UI', [single](11.5 * $S), [System.Drawing.FontStyle]::Regular, $px)
        Big = New-Object System.Drawing.Font('Segoe UI', [single](16 * $S), [System.Drawing.FontStyle]::Bold, $px)
        BigScam = New-Object System.Drawing.Font('Segoe UI', [single](17 * $S), [System.Drawing.FontStyle]::Bold, $px)
        Side = New-Object System.Drawing.Font('Segoe UI', [single](13 * $S), [System.Drawing.FontStyle]::Regular, $px)
        SideSmall = New-Object System.Drawing.Font('Segoe UI', [single](10.5 * $S), [System.Drawing.FontStyle]::Regular, $px)
    }
}
Initialize-HarnessFonts

# a hidden full-screen "owner" for the dialogs (the program opens its dialogs on top of the main window, $script:Form)
$wa0 = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$script:Stub = New-Object System.Windows.Forms.Form
$script:Stub.FormBorderStyle = 'None'; $script:Stub.ShowInTaskbar = $false; $script:Stub.StartPosition = 'Manual'
$script:Stub.Bounds = $wa0; $script:Stub.Opacity = 0; $script:Stub.Text = 'screencheck-owner'
$script:Stub.Show()
$script:Form = $script:Stub

# ====================================================================================================================================
# Findings
# ====================================================================================================================================
$script:Findings = New-Object System.Collections.ArrayList
$script:Windows = New-Object System.Collections.ArrayList
$script:Cur = $null
$script:Seq = 0

function Get-CtlLabel {
    param($C)
    $t = ''
    try { $t = [string]$C.Text } catch { }
    if (-not $t) { try { $tg = $C.Tag; if ($tg -is [System.Collections.IDictionary] -and $tg.Contains('Title')) { $t = [string]$tg['Title'] } } catch { } }
    $t = ($t -replace '\s+', ' ').Trim(); if ($t.Length -gt 48) { $t = $t.Substring(0, 45) + '...' }
    return ('{0} "{1}"' -f $C.GetType().Name, $t)
}
function Add-Finding {
    param([string]$Type, $Ctl, [string]$Detail, $Form = $null, $Rect = $null)
    $x = $null
    if ($null -ne $Ctl -and $null -ne $Form) {
        try {
            $r = $Ctl.RectangleToScreen($Ctl.ClientRectangle)
            $x = @(($r.X - $Form.Bounds.X), ($r.Y - $Form.Bounds.Y), $r.Width, $r.Height)
        } catch { }
    }
    if ($null -ne $Rect) { $x = $Rect }
    $f = [ordered]@{
        scenario = $script:Cur.Name; window = $script:Cur.Title; scale = $Scale; mode = $Mode; type = $Type
        control = $(if ($null -ne $Ctl) { Get-CtlLabel $Ctl } else { '' }); detail = $Detail; rect = $x
    }
    [void]$script:Findings.Add($f)
    if ($null -ne $script:Cur.WinFindings) { [void]$script:Cur.WinFindings.Add($f) }
}

# ====================================================================================================================================
# The measuring
# ====================================================================================================================================
$TF = [System.Windows.Forms.TextFormatFlags]
function Get-AllControls {
    param($Parent, $List)
    foreach ($c in $Parent.Controls) { [void]$List.Add($c); Get-AllControls -Parent $c -List $List }
}
function Measure-Wrapped {
    param([string]$Text, $Font, [int]$Width, [bool]$Mnemonic = $false)
    $fl = $TF::WordBreak
    if (-not $Mnemonic) { $fl = $fl -bor $TF::NoPrefix }
    if ($Width -lt 1) { $Width = 1 }
    return [System.Windows.Forms.TextRenderer]::MeasureText($Text, $Font, (New-Object System.Drawing.Size($Width, 100000)), $fl)
}
function Test-ControlInk {
    # Does the control show anything inside (rect in the control's own pixels)? $null = could not tell.
    param($C, $Rect)
    $w = $C.Width; $h = $C.Height
    if ($w -lt 2 -or $h -lt 2 -or $w * $h -gt 4000000) { return $null }
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $C.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $w, $h)))
        return [ScNative]::CountInk($bmp, $Rect.X, $Rect.Y, $Rect.Width, $Rect.Height, 40)
    } catch { return $null } finally { $bmp.Dispose() }
}
function Get-AlignRect {
    # where a label's text sits inside it (the text size within the label's box), from its TextAlign
    param($C, [int]$TextW, [int]$TextH)
    $w = $C.ClientSize.Width; $h = $C.ClientSize.Height
    $tw = [math]::Min($TextW, $w); $th = [math]::Min($TextH, $h)
    $a = [string]$C.TextAlign
    $x = 0; $y = 0
    if ($a -like '*Center') { $x = [int](($w - $tw) / 2) } elseif ($a -like '*Right') { $x = $w - $tw }
    if ($a -like 'Middle*') { $y = [int](($h - $th) / 2) } elseif ($a -like 'Bottom*') { $y = $h - $th }
    return (New-Object System.Drawing.Rectangle($x, $y, $tw, $th))
}

function Test-TextControl {
    param($C, $Form)
    $text = [string]$C.Text
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $font = $C.Font
    $isLabel = ($C -is [System.Windows.Forms.Label])
    $mn = $false; try { $mn = [bool]$C.UseMnemonic } catch { }
    $padW = 0; $padH = 0; try { $padW = $C.Padding.Horizontal; $padH = $C.Padding.Vertical } catch { }
    if ($C.Width -le 0 -or $C.Height -le 0) { Add-Finding 'zero-size' $C ('The control has text but its size is {0}x{1}.' -f $C.Width, $C.Height) $Form; return }
    if ($isLabel) { $availW = $C.ClientSize.Width - $padW; $availH = $C.ClientSize.Height - $padH }
    else { $availW = $C.ClientSize.Width - 10; $availH = $C.ClientSize.Height - 2 }   # the frame of a button / check box takes a little room
    $m = Measure-Wrapped -Text $text -Font $font -Width $availW -Mnemonic $mn
    $needH = [int]$m.Height; $needW = [int]$m.Width
    $pref = $null
    try { $pref = $C.GetPreferredSize((New-Object System.Drawing.Size($C.Width, 0))) } catch { }
    $prefH = 0; if ($null -ne $pref) { $prefH = [int]$pref.Height }
    $clipTR = ($needH -gt ($availH + 1))
    $clipPref = $false
    if ($isLabel -and $null -ne $pref) { $clipPref = ($prefH -gt ($C.Height + 2)) }
    if ($clipTR -or $clipPref) {
        Add-Finding 'clipped-text' $C ('The text needs {0}px of height ({1}px wide) but the control is only {2}px tall and {3}px wide{4}. The last lines are cut off.' -f $needH, $needW, $C.Height, $C.Width, $(if ($clipPref) { (' (the control''s own measure says ' + $prefH + 'px)') } else { '' })) $Form
    } elseif ($needW -gt ($availW + 1) -and ($text.IndexOf(' ') -lt 0)) {
        Add-Finding 'clipped-text' $C ('One long word needs {0}px but only {1}px are free; it is cut off or broken in the middle.' -f $needW, $availW) $Form
    }
    # does the text sit inside the control, and is it visible (not the same colour as the background)?
    $ink = Test-ControlInk -C $C -Rect (New-Object System.Drawing.Rectangle(2, 2, [math]::Max(1, $C.Width - 4), [math]::Max(1, $C.Height - 4)))
    if ($null -ne $ink -and $ink -lt 3) { Add-Finding 'empty-control' $C 'The control has text but nothing can be seen: its text is the same colour as its background, or is drawn outside it.' $Form }
}

function Get-TileRects {
    # Mirrors Invoke-FixItTilePaint / Invoke-FixItSidePaint: where each line of a tile's text is drawn. Returns a list of @{ Name; Text; Font; Rect; Wrap }
    param($B)
    $t = $B.Tag; $S = $script:UiScale
    $w = $B.ClientSize.Width; $h = $B.ClientSize.Height
    $style = [string]$t['Style']; $title = [string]$t['Title']; $sub = [string]$t['Sub']
    $out = @()
    if ($style -eq 'logo') { return $out }
    if ($style -eq 'nav' -or $style -eq 'toggle') {
        $tx = [int](42 * $S)
        if ($style -eq 'toggle') {
            $sw = [int](34 * $S); $sx = $w - $sw - [int](12 * $S)
            return @(@{ Name = 'title'; Text = $title; Font = $script:UiFonts.Side; Rect = (New-Object System.Drawing.Rectangle($tx, 0, ($sx - $tx - [int](6 * $S)), $h)); Wrap = $true })
        }
        if ($sub) {
            return @(
                @{ Name = 'title'; Text = $title; Font = $script:UiFonts.Side; Rect = (New-Object System.Drawing.Rectangle($tx, [int]($h / 2 - 17 * $S), ($w - $tx - [int](8 * $S)), [int](18 * $S))); Wrap = $false },
                @{ Name = 'subtitle'; Text = $sub; Font = $script:UiFonts.SideSmall; Rect = (New-Object System.Drawing.Rectangle($tx, [int]($h / 2 + 1 * $S), ($w - $tx - [int](8 * $S)), [int](16 * $S))); Wrap = $false })
        }
        return @(@{ Name = 'title'; Text = $title; Font = $script:UiFonts.Side; Rect = (New-Object System.Drawing.Rectangle($tx, 0, ($w - $tx - [int](8 * $S)), $h)); Wrap = $false })
    }
    if (Test-FixItTileCenteredText -Style $style -HasIcon ([bool]$t['Icon']) -Wide ([bool]$t['Wide']) -Sub $sub) {
        $cfont = $script:UiFonts.Big; if ($style -eq 'btn') { $cfont = $script:UiFonts.Title }
        return @(@{ Name = 'title'; Text = $title; Font = $cfont; Rect = (New-Object System.Drawing.Rectangle(0, 0, $w, $h)); Wrap = $false })
    }
    if ($t['Wide']) {
        $isz = [int](($(if ($style -eq 'scam') { 44 } else { 40 })) * $S)
        $ix = [int](18 * $S); $tx = $ix + $isz + [int](14 * $S)
        $rsv = [int](12 * $S); if ($t['Help']) { $rsv = Get-FixItHelpTextReserve -Scale $S }
        $r1 = New-Object System.Drawing.Rectangle($tx, [int]($h / 2 - 24 * $S), ($w - $tx - $rsv), [int](24 * $S))
        $r2 = New-Object System.Drawing.Rectangle($tx, [int]($h / 2 + 1 * $S), ($w - $tx - [int](12 * $S)), [int](20 * $S))
        $f1 = $script:UiFonts.Big; if ($style -eq 'scam') { $f1 = $script:UiFonts.BigScam }
        $f2 = $script:UiFonts.Small
    } else {
        $isz = [int](36 * $S); $ix = [int](14 * $S)
        $r1 = New-Object System.Drawing.Rectangle($ix, [int](12 * $S + $isz + 8 * $S), ($w - 2 * $ix), [int](20 * $S))
        $r2 = New-Object System.Drawing.Rectangle($ix, ($r1.Bottom + [int](1 * $S)), ($w - 2 * $ix), [int](18 * $S))
        $f1 = $script:UiFonts.Title; $f2 = $script:UiFonts.Small
    }
    $out = @(@{ Name = 'title'; Text = $title; Font = $f1; Rect = $r1; Wrap = $false })
    if ($sub) { $out += @{ Name = 'subtitle'; Text = $sub; Font = $f2; Rect = $r2; Wrap = $false } }
    return $out
}

function Test-Tile {
    param($B, $Form)
    $t = $B.Tag
    $title = [string]$t['Title']
    if ([string]::IsNullOrWhiteSpace($title) -and [string]$t['Style'] -ne 'logo') { Add-Finding 'empty-control' $B 'This button has no label at all.' $Form; return }
    $rects = @(Get-TileRects -B $B)
    $w = $B.ClientSize.Width; $h = $B.ClientSize.Height
    foreach ($r in $rects) {
        if ([string]::IsNullOrEmpty([string]$r.Text)) { continue }
        $rc = $r.Rect
        $sz = [System.Windows.Forms.TextRenderer]::MeasureText([string]$r.Text, $r.Font, (New-Object System.Drawing.Size(100000, 100000)), ($TF::NoPadding -bor $TF::SingleLine))
        if ($rc.Bottom -gt ($h + 1) -or $rc.Top -lt -1) {
            Add-Finding 'text-outside' $B ('The {0} is drawn at {1}px..{2}px but the button is only {3}px tall, so it falls outside the button (the blank-button bug).' -f $r.Name, $rc.Top, $rc.Bottom, $h) $Form
            continue
        }
        if ($r.Wrap) {
            $wm = [System.Windows.Forms.TextRenderer]::MeasureText([string]$r.Text, $r.Font, (New-Object System.Drawing.Size([math]::Max(1, $rc.Width), 100000)), ($TF::WordBreak -bor $TF::NoPadding))
            if ($wm.Height -gt ($rc.Height + 1)) { Add-Finding 'clipped-text' $B ('The {0} "{1}" wraps to {2}px but only {3}px are free next to the switch.' -f $r.Name, $r.Text, $wm.Height, $rc.Height) $Form }
            continue
        }
        if ($sz.Width -gt ($rc.Width + 1)) {
            Add-Finding 'clipped-text' $B ('The {0} "{1}" needs {2}px of width but only {3}px are free, so it ends in "..." (cut off).' -f $r.Name, $r.Text, $sz.Width, $rc.Width) $Form
        }
        if ($sz.Height -gt ($rc.Height + 2)) {
            Add-Finding 'clipped-text' $B ('The {0} "{1}" is {2}px tall but its line is {3}px; letters are cut off at the top or bottom.' -f $r.Name, $r.Text, $sz.Height, $rc.Height) $Form
        }
    }
    # pixel check: is the title really visible? (catches a label drawn outside, or in the background colour)
    if ($rects.Count -gt 0 -and -not [string]::IsNullOrEmpty([string]$rects[0].Text)) {
        $tr = $rects[0].Rect
        $ink = Test-ControlInk -C $B -Rect (New-Object System.Drawing.Rectangle($tr.X, $tr.Y, [math]::Max(1, $tr.Width), [math]::Max(1, $tr.Height)))
        if ($null -ne $ink -and $ink -lt 3) { Add-Finding 'empty-control' $B ('The button looks empty: nothing is drawn where its label "{0}" should be.' -f $title) $Form }
    }
}

function Test-Form {
    param($F)
    $wa = [System.Windows.Forms.Screen]::FromControl($F).WorkingArea
    $b = $F.Bounds
    if ($b.Width -gt $wa.Width -or $b.Height -gt $wa.Height) {
        Add-Finding 'window-off-screen' $null ('The window is {0}x{1}px but the usable screen is only {2}x{3}px, so part of it can never be seen.' -f $b.Width, $b.Height, $wa.Width, $wa.Height) $F @(0, 0, $b.Width, $b.Height)
    } elseif ($b.Left -lt ($wa.Left - 1) -or $b.Top -lt ($wa.Top - 1) -or $b.Right -gt ($wa.Right + 1) -or $b.Bottom -gt ($wa.Bottom + 1)) {
        Add-Finding 'window-off-screen' $null ('The window sits at {0},{1} to {2},{3} and hangs over the edge of the usable screen ({4},{5} to {6},{7}).' -f $b.Left, $b.Top, $b.Right, $b.Bottom, $wa.Left, $wa.Top, $wa.Right, $wa.Bottom) $F @(0, 0, $b.Width, $b.Height)
    }
    $list = New-Object System.Collections.ArrayList
    Get-AllControls -Parent $F -List $list
    $script:Cur.Controls = $list.Count
    foreach ($c in $list) {
        if (-not $c.Visible) { continue }
        $p = $c.Parent
        $tagIsTile = ($c.Tag -is [System.Collections.IDictionary] -and $c.Tag.Contains('Style') -and $c.Tag.Contains('Title'))
        $isHelpDot = ($c.Tag -is [System.Collections.IDictionary] -and $c.Tag.Contains('Key') -and $c.Tag.Contains('Parent'))
        # 1. text
        try {
            if ($tagIsTile) { Test-Tile -B $c -Form $F }
            elseif ($c -is [System.Windows.Forms.Label] -or $c -is [System.Windows.Forms.ButtonBase]) {
                if (-not $isHelpDot) { Test-TextControl -C $c -Form $F }
                if ($c -is [System.Windows.Forms.Button] -and -not $isHelpDot -and [string]::IsNullOrWhiteSpace([string]$c.Text) -and $null -eq $c.Image -and $null -eq $c.BackgroundImage -and $c.Width -gt 8 -and $c.Height -gt 8) {
                    Add-Finding 'empty-control' $c 'A button with no text and no picture.' $F
                }
            } elseif ($c -is [System.Windows.Forms.TextBox] -and -not $c.Multiline) {
                $lh = [System.Windows.Forms.TextRenderer]::MeasureText('Ag', $c.Font).Height
                if ($lh -gt ($c.ClientSize.Height + 1)) { Add-Finding 'clipped-text' $c ('The box is {0}px tall but its text needs {1}px.' -f $c.ClientSize.Height, $lh) $F }
            }
        } catch { Add-Finding 'check-error' $c ('The check itself failed on this control: ' + $_.Exception.Message) $F }
        if ($isHelpDot -and $null -ne $p) {
            try {
                if ($c.Right -gt ($p.ClientSize.Width + 1) -or $c.Bottom -gt ($p.ClientSize.Height + 1) -or $c.Left -lt -1 -or $c.Top -lt -1) {
                    Add-Finding 'outside-parent' $c ('The "?" button spans {0},{1} to {2},{3} but its tile is only {4}x{5}px.' -f $c.Left, $c.Top, $c.Right, $c.Bottom, $p.ClientSize.Width, $p.ClientSize.Height) $F
                }
                $dink = Test-ControlInk -C $c -Rect (New-Object System.Drawing.Rectangle(0, 0, $c.Width, $c.Height))
                if ($null -ne $dink -and $dink -lt 3) { Add-Finding 'empty-control' $c 'The "?" help button is not drawn (nothing visible).' $F }
            } catch { Add-Finding 'check-error' $c ('The check itself failed on this control: ' + $_.Exception.Message) $F }
        }
        # 2. inside its parent / window (a scrolling parent may hold more than it shows, that is by design)
        if ($null -ne $p -and -not $isHelpDot) {
            $scrolls = $false; try { $scrolls = [bool]$p.AutoScroll } catch { }
            $docked = ([string]$c.Dock -ne 'None')
            if (-not $scrolls -and -not $docked -and $c.Width -gt 0 -and $c.Height -gt 0) {
                $pw = $p.ClientSize.Width; $ph = $p.ClientSize.Height
                if ($c.Right -gt ($pw + 1) -or $c.Bottom -gt ($ph + 1) -or $c.Left -lt -1 -or $c.Top -lt -1) {
                    $what = 'window'; if ($p -isnot [System.Windows.Forms.Form]) { $what = 'panel it sits in' }
                    Add-Finding 'outside-parent' $c ('The control spans {0},{1} to {2},{3} but its {4} is only {5}x{6}px, so part of it is cut off.' -f $c.Left, $c.Top, $c.Right, $c.Bottom, $what, $pw, $ph) $F
                }
            }
        }
        # 3. sideways scroll bar (a scrolling area wider than it is)
        $isScroller = $false; try { $isScroller = [bool]$c.AutoScroll } catch { }
        if ($isScroller) { try { if ($c.HorizontalScroll.Visible) { Add-Finding 'horizontal-scroll' $c 'A sideways scroll bar is showing: the content is wider than the window.' $F } } catch { } }
    }
    if ($F.AutoScroll) { try { if ($F.HorizontalScroll.Visible) { Add-Finding 'horizontal-scroll' $null 'The window has a sideways scroll bar: the content is wider than the window.' $F @(0, 0, $F.Width, $F.Height) } } catch { } }
    # 4. overlapping siblings (only controls that show something)
    $groups = @{}
    foreach ($c in $list) {
        if (-not $c.Visible -or $null -eq $c.Parent) { continue }
        $isHelpDot = ($c.Tag -is [System.Collections.IDictionary] -and $c.Tag.Contains('Key') -and $c.Tag.Contains('Parent'))
        if ($isHelpDot) { continue }
        $has = $false
        if ($c.Tag -is [System.Collections.IDictionary] -and $c.Tag.Contains('Title')) { $has = $true }
        elseif ($c -is [System.Windows.Forms.ButtonBase] -or $c -is [System.Windows.Forms.TextBoxBase] -or $c -is [System.Windows.Forms.ComboBox]) { $has = $true }
        elseif ($c -is [System.Windows.Forms.Label] -and -not [string]::IsNullOrWhiteSpace([string]$c.Text)) { $has = $true }
        if (-not $has -or $c.Width -le 0 -or $c.Height -le 0) { continue }
        if ([string]$c.Dock -ne 'None') { continue }
        $k = [string][System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($c.Parent)
        if (-not $groups.ContainsKey($k)) { $groups[$k] = New-Object System.Collections.ArrayList }
        [void]$groups[$k].Add($c)
    }
    foreach ($k in $groups.Keys) {
        $arr = @($groups[$k])
        for ($i = 0; $i -lt $arr.Count; $i++) {
            for ($j = $i + 1; $j -lt $arr.Count; $j++) {
                $a = $arr[$i]; $b2 = $arr[$j]
                $ra = Get-InkBounds $a; $rb = Get-InkBounds $b2
                $ix = [math]::Min($ra.Right, $rb.Right) - [math]::Max($ra.Left, $rb.Left)
                $iy = [math]::Min($ra.Bottom, $rb.Bottom) - [math]::Max($ra.Top, $rb.Top)
                if ($ix -gt 2 -and $iy -gt 2) {
                    Add-Finding 'overlap' $a ('Overlaps {0} by {1}x{2}px.' -f (Get-CtlLabel $b2), $ix, $iy) $F
                }
            }
        }
    }
}
function Get-InkBounds {
    # the part of a control that is really drawn on: a label's text area; everything else its full box
    param($C)
    $r = $C.Bounds
    if ($C -is [System.Windows.Forms.Label] -and -not ($C.Tag -is [System.Collections.IDictionary])) {
        try {
            $m = Measure-Wrapped -Text ([string]$C.Text) -Font $C.Font -Width ($C.ClientSize.Width) -Mnemonic ([bool]$C.UseMnemonic)
            $ar = Get-AlignRect -C $C -TextW ([int]$m.Width) -TextH ([int]$m.Height)
            return (New-Object System.Drawing.Rectangle(($C.Left + $ar.X), ($C.Top + $ar.Y), $ar.Width, $ar.Height))
        } catch { }
    }
    return $r
}

# ====================================================================================================================================
# Taking the pictures and closing windows (a timer inside the window loop)
# ====================================================================================================================================
function Save-Png {
    param($Bmp, [string]$Path)
    $Bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
}
function Get-SafeName { param([string]$s) return ($s -replace '[^A-Za-z0-9\-]+', '_') }

function Save-FindingsPicture {
    param($Bmp, $Items, [string]$Path)
    $g = [System.Drawing.Graphics]::FromImage($Bmp)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::Red, 3)
    try {
        foreach ($f in $Items) {
            if ($null -ne $f.rect -and @($f.rect).Count -eq 4) { $r = @($f.rect); $g.DrawRectangle($pen, [int]$r[0], [int]$r[1], [int]$r[2], [int]$r[3]) }
        }
    } finally { $pen.Dispose(); $g.Dispose() }
    Save-Png -Bmp $Bmp -Path $Path
}

function Register-Window {
    param([string]$Kind, [string]$Title, $Bmp, $Items, [int]$W, [int]$H, [int]$Controls)
    $script:Seq++
    $base = ('{0:000}_{1}' -f $script:Seq, (Get-SafeName $script:Cur.Name))
    $file = ''
    $fileFind = ''
    if ($null -ne $Bmp) {
        $file = ('screenshots/' + $base + '.png')
        Save-Png -Bmp $Bmp -Path (Join-Path $OutDir $file)
        if (@($Items).Count -gt 0) {
            $fileFind = ('screenshots/' + $base + '_FINDINGS.png')
            $copy = New-Object System.Drawing.Bitmap($Bmp)
            try { Save-FindingsPicture -Bmp $copy -Items $Items -Path (Join-Path $OutDir $fileFind) } finally { $copy.Dispose() }
        }
    }
    [void]$script:Windows.Add([ordered]@{
        scenario = $script:Cur.Name; kind = $Kind; title = $Title; width = $W; height = $H; controls = $Controls
        screenshot = $file; screenshot_with_findings = $fileFind; findings = @($Items).Count; scale = $Scale; mode = $Mode })
}

function Capture-Form {
    param($F)
    $script:Cur.Title = [string]$F.Text
    $script:Cur.WinFindings = New-Object System.Collections.ArrayList
    $script:Cur.Controls = 0
    try { Test-Form -F $F } catch { Add-Finding 'check-error' $null ('The check itself failed on this window: ' + $_.Exception.Message) $F }
    $bmp = $null
    try { $bmp = [ScNative]::CaptureWindow($F.Handle) } catch { }
    if ($null -eq $bmp) {
        try { $bmp = New-Object System.Drawing.Bitmap($F.Width, $F.Height); $F.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $F.Width, $F.Height))) } catch { $bmp = $null }
    }
    try { Register-Window -Kind 'window' -Title ([string]$F.Text) -Bmp $bmp -Items @($script:Cur.WinFindings) -W $F.Width -H $F.Height -Controls $script:Cur.Controls }
    finally { if ($null -ne $bmp) { $bmp.Dispose() } }
    $script:Cur.Captured++
    $script:Cur.WinFindings = $null
}

function Capture-MessageBox {
    param([IntPtr]$H)
    $script:Cur.Title = 'message box'
    $bmp = $null
    try { $bmp = [ScNative]::CaptureWindow($H) } catch { }
    $w = 0; $hh = 0; if ($null -ne $bmp) { $w = $bmp.Width; $hh = $bmp.Height }
    try { Register-Window -Kind 'message-box' -Title 'message box (drawn by Windows)' -Bmp $bmp -Items @() -W $w -H $hh -Controls 0 }
    finally { if ($null -ne $bmp) { $bmp.Dispose() } }
    $script:Cur.Captured++
}

function Invoke-Pump {
    $cur = $script:Cur
    if ($null -eq $cur) { return }
    $cur.Ticks++
    try {
        $mb = [ScNative]::FindMessageBox()
        if ($mb -ne [IntPtr]::Zero) {
            $k = 'mb' + $mb.ToInt64()
            if (-not $cur.Seen.ContainsKey($k)) { $cur.Seen[$k] = @{ First = $cur.Ticks; Done = $false } }
            $st = $cur.Seen[$k]
            if (-not $st.Done -and ($cur.Ticks - $st.First) -ge 2) {
                $st.Done = $true
                Capture-MessageBox -H $mb
                [ScNative]::DismissMessageBox($mb)
            }
        }
        foreach ($f in @([System.Windows.Forms.Application]::OpenForms)) {
            if ([object]::ReferenceEquals($f, $script:Stub)) { continue }
            if ($f.IsDisposed -or -not $f.Visible -or -not $f.IsHandleCreated) { continue }
            $k = 'f' + $f.Handle.ToInt64()
            if (-not $cur.Seen.ContainsKey($k)) { $cur.Seen[$k] = @{ First = $cur.Ticks; Done = $false; ClosedAt = 0 } }
            $st = $cur.Seen[$k]
            if ($st.Done) { if (($cur.Ticks - $st.ClosedAt) -ge 4) { try { $f.Close() } catch { } }; continue }
            $age = $cur.Ticks - $st.First
            if ($age -lt $cur.Settle) { continue }
            if ($null -ne $cur.Ready -and $age -lt $cur.MaxSettle) { $ready = $false; try { $ready = [bool](& $cur.Ready) } catch { $ready = $true }; if (-not $ready) { continue } }
            $st.Done = $true; $st.ClosedAt = $cur.Ticks
            try { Capture-Form -F $f } catch { $cur.Errors.Add('capture: ' + $_.Exception.Message) | Out-Null }
            try { $f.Close() } catch { }
        }
        if ($cur.Ticks -gt $cur.MaxTicks) {
            $cur.Errors.Add('the window did not finish in time; it was closed by force') | Out-Null
            foreach ($f in @([System.Windows.Forms.Application]::OpenForms)) { if (-not [object]::ReferenceEquals($f, $script:Stub)) { try { $f.Close() } catch { } } }
            $mb2 = [ScNative]::FindMessageBox(); if ($mb2 -ne [IntPtr]::Zero) { [ScNative]::DismissMessageBox($mb2) }
        }
    } catch { $cur.Errors.Add('pump: ' + $_.Exception.Message) | Out-Null }
}

$script:PumpTimer = New-Object System.Windows.Forms.Timer
$script:PumpTimer.Interval = 250
$script:PumpTimer.Add_Tick({ Invoke-Pump })

function Invoke-Scenario {
    param($Sc)
    $script:Cur = @{
        Name = $Sc.Name; Title = ''; Ticks = 0; Seen = @{}; Errors = (New-Object System.Collections.ArrayList); Captured = 0
        Settle = $(if ($Sc.ContainsKey('Settle')) { [int]$Sc.Settle } else { 2 }); Ready = $(if ($Sc.ContainsKey('Ready')) { $Sc.Ready } else { $null })
        MaxSettle = 24; MaxTicks = 120; WinFindings = $null; Controls = 0
    }
    $script:Form = $script:Stub
    $script:PumpTimer.Start()
    $thrown = $null
    try { & $Sc.Run } catch { $thrown = $_ }
    # a window shown without blocking (the toast) stays open after the function returns: keep pumping until it is done
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline) {
        $open = @([System.Windows.Forms.Application]::OpenForms | Where-Object { -not [object]::ReferenceEquals($_, $script:Stub) -and -not $_.IsDisposed -and $_.Visible })
        if ($open.Count -eq 0) { break }
        [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100
        if (($script:Cur.Ticks % 1) -eq 0) { }
    }
    $script:PumpTimer.Stop()
    foreach ($f in @([System.Windows.Forms.Application]::OpenForms)) { if (-not [object]::ReferenceEquals($f, $script:Stub) -and -not $f.IsDisposed) { try { $f.Close(); $f.Dispose() } catch { } } }
    $cur = $script:Cur
    if ($null -ne $thrown) {
        $script:Cur.Title = '(did not open)'
        Add-Finding 'window-error' $null ('Opening this window failed: ' + $thrown.Exception.Message) $null
    } elseif ($cur.Captured -eq 0) {
        Add-Finding 'window-error' $null 'No window appeared (the program returned without showing anything).' $null
    }
    foreach ($e in $cur.Errors) { Add-Finding 'window-error' $null ([string]$e) $null }
    $script:Form = $script:Stub
    $script:Cur = $null
}

# ====================================================================================================================================
# The tray icon (the pop-up watcher's notification-area icon)
# ====================================================================================================================================
function Test-TrayIcon {
    $script:Cur = @{ Name = 'tray-icon'; Title = 'pop-up watcher tray icon'; Ticks = 0; Seen = @{}; Errors = (New-Object System.Collections.ArrayList); Captured = 0; WinFindings = (New-Object System.Collections.ArrayList); Controls = 0 }
    $items = $script:Cur.WinFindings
    $shot = $null
    try {
        Initialize-FixItGuardianNative
        $tray = New-FixItGuardianTray
        $ni = $tray.Icon
        [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 800; [System.Windows.Forms.Application]::DoEvents()
        if (-not $ni.Visible) { Add-Finding 'tray-icon' $null 'The tray icon was created but is not visible (NotifyIcon.Visible is false).' }
        if ($null -eq $ni.Icon) { Add-Finding 'tray-icon' $null 'The tray icon has no picture (NotifyIcon.Icon is empty).' }
        else {
            $ico = $ni.Icon
            if ($ico.Width -lt 8 -or $ico.Height -lt 8) { Add-Finding 'tray-icon' $null ('The tray icon picture is only {0}x{1}px.' -f $ico.Width, $ico.Height) }
            $own = $null; try { $own = Get-FixItAppIcon } catch { }
            if ($null -eq $own) { Add-Finding 'tray-icon' $null 'The Family Fix-It icon file could not be loaded, so Windows would show a stock "i" icon instead.' }
            elseif ([object]::ReferenceEquals($ico, [System.Drawing.SystemIcons]::Information)) { Add-Finding 'tray-icon' $null 'The tray shows the stock Windows icon, not the Family Fix-It icon.' }
            # draw it at the sizes Windows uses and make sure it is not blank
            $sizes = @(16, 20, 24, 32)
            $sheet = New-Object System.Drawing.Bitmap(200, 60, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [System.Drawing.Graphics]::FromImage($sheet); $g.Clear([System.Drawing.Color]::FromArgb(32, 32, 32))
            $x = 8
            foreach ($sz in $sizes) {
                $one = $null
                try { $sm = New-Object System.Drawing.Icon($ico, $sz, $sz); $one = $sm.ToBitmap(); $sm.Dispose() } catch { $one = $null }
                if ($null -eq $one) { continue }
                $ink = [ScNative]::CountInk($one, 0, 0, $one.Width, $one.Height, 30)
                if ($ink -lt [math]::Max(8, [int]($sz * $sz * 0.05))) { Add-Finding 'tray-icon' $null ('The icon looks blank at {0}x{1}px (only {2} visible pixels).' -f $sz, $sz, $ink) }
                $g.DrawImage($one, $x, 8, $sz, $sz); $x += ($sz + 12); $one.Dispose()
            }
            $g.Dispose()
            $shot = $sheet
        }
        $tip = [string]$ni.Text
        if (-not $tip.Trim()) { Add-Finding 'tray-icon' $null 'The tray icon has no hover text.' }
        elseif ($tip.Length -gt 63) { Add-Finding 'tray-icon' $null ('The hover text is {0} characters; Windows allows 63.' -f $tip.Length) }
        $plan = Get-FixItTrayPlan
        $menu = $tray.Menu
        if ($menu.Items.Count -ne @($plan.Items).Count) { Add-Finding 'tray-icon' $null ('The right-click menu has {0} items but the plan says {1}.' -f $menu.Items.Count, @($plan.Items).Count) }
        foreach ($mi in $menu.Items) { if (-not ([string]$mi.Text).Trim()) { Add-Finding 'tray-icon' $null 'A right-click menu item has no text.' } }
        # the menu itself: open it, measure and picture it
        $menuBmp = $null
        try {
            $menu.Show((New-Object System.Drawing.Point(300, 300)))
            [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 500; [System.Windows.Forms.Application]::DoEvents()
            foreach ($mi in $menu.Items) {
                $need = [System.Windows.Forms.TextRenderer]::MeasureText([string]$mi.Text, $mi.Font).Width
                if ($need -gt ($mi.Width - 4)) { Add-Finding 'clipped-text' $null ('The menu item "{0}" needs {1}px but is {2}px wide.' -f $mi.Text, $need, $mi.Width) }
            }
            $menuBmp = New-Object System.Drawing.Bitmap($menu.Width, $menu.Height)
            $menu.DrawToBitmap($menuBmp, (New-Object System.Drawing.Rectangle(0, 0, $menu.Width, $menu.Height)))
            $menu.Close()
        } catch { $menuBmp = $null; try { $menu.Close() } catch { } }
        # best effort, information only: is the icon in the taskbar's notification area (it may sit in the hidden "^" overflow)?
        $where = 'not checked'
        try {
            Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
            $root = [System.Windows.Automation.AutomationElement]::RootElement
            $cond = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ClassNameProperty), 'Shell_TrayWnd'
            $tb = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
            $where = 'taskbar not found'
            if ($null -ne $tb) {
                $all = $tb.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
                $where = 'not seen in the taskbar (it may be in the hidden-icons overflow)'
                foreach ($e in $all) { if ([string]$e.Current.Name -like '*Family Fix-It*') { $where = 'seen in the taskbar notification area'; break } }
            }
        } catch { $where = 'could not look (' + $_.Exception.Message + ')' }
        $script:Cur.TrayWhere = $where
        $script:TrayInfo = [ordered]@{ visible = [bool]$ni.Visible; hover_text = $tip; menu_items = @($menu.Items | ForEach-Object { [string]$_.Text }); taskbar = $where }
        $script:Seq++
        $base = ('{0:000}_tray-icon' -f $script:Seq)
        $file = ''; $file2 = ''
        if ($null -ne $shot) { $file = 'screenshots/' + $base + '_icon-sizes.png'; Save-Png -Bmp $shot -Path (Join-Path $OutDir $file) }
        if ($null -ne $menuBmp) { $file2 = 'screenshots/' + $base + '_menu.png'; Save-Png -Bmp $menuBmp -Path (Join-Path $OutDir $file2) }
        [void]$script:Windows.Add([ordered]@{ scenario = 'tray-icon'; kind = 'tray'; title = ('tray icon (' + $where + ')'); width = 0; height = 0; controls = 0
            screenshot = $file; screenshot_with_findings = $file2; findings = @($items).Count; scale = $Scale; mode = $Mode })
    } catch {
        Add-Finding 'tray-icon' $null ('The tray icon could not be created: ' + $_.Exception.Message)
    } finally {
        try { Remove-FixItGuardianTray } catch { }
        if ($null -ne $shot) { $shot.Dispose() }
    }
    $script:Cur = $null
}

# ====================================================================================================================================
# The list of windows
# ====================================================================================================================================
$scen = New-Object System.Collections.ArrayList
function Add-Scenario { param([string]$Name, [scriptblock]$Run, [int]$Settle = 2, $Ready = $null) $h = @{ Name = $Name; Run = $Run; Settle = $Settle }; if ($null -ne $Ready) { $h['Ready'] = $Ready }; [void]$scen.Add($h) }

# the main window, three ways (buttons: all on / simple mode / a PC that needs attention)
$pillReady = { $script:PillLabel -ne $null -and $script:PillLabel.Visible }
$longOk = ('Your computer looks healthy ' + [string][char]0x00B7 + ' backup needs a look')
Add-Scenario 'main-window' { $script:H_Simple = $false; $script:H_Guardian = $true; $script:H_CheckIn = $true; $script:H_Pill = [pscustomobject]@{ Ok = $true; Text = 'Your computer looks healthy ' + [string][char]0x00B7 + ' backup partly on' }; Show-FixItWindowOnce -FirstTime $false } -Settle 3 -Ready $pillReady
Add-Scenario 'main-window-simple' { $script:H_Simple = $true; $script:H_Guardian = $false; $script:H_CheckIn = $false; $script:H_Pill = [pscustomobject]@{ Ok = $false; Text = 'Needs a look: backup needs a look, restart waiting' }; Show-FixItWindowOnce -FirstTime $false } -Settle 3 -Ready $pillReady
Add-Scenario 'main-window-attention' { $script:H_Simple = $false; $script:H_Guardian = $false; $script:H_CheckIn = $false; $script:H_Pill = [pscustomobject]@{ Ok = $false; Text = 'Needs a look: low disk space, restart waiting' }; Show-FixItWindowOnce -FirstTime $false } -Settle 3 -Ready $pillReady

# every "?" help window
foreach ($k in @((Get-FixItHelpTable).Keys | Sort-Object)) { $kk = [string]$k; Add-Scenario ('help-' + $kk) ({ Show-FixItHelp -Key $kk }.GetNewClosure()) }
# every "Here is what I will do" window
$table = Get-FixItActionTable
foreach ($k in @($table.Keys | Sort-Object)) {
    if ($table[$k].ContainsKey('Plan')) { $kk = [string]$k; Add-Scenario ('plan-' + $kk) ({ [void](Show-FixItPlanDialog -Plan (Get-FixItPlan -Which $kk)) }.GetNewClosure()) }
}
# the small questions
Add-Scenario 'name-question' { [void](Show-FixItNameForm) }
Add-Scenario 'share-with-a-friend' { Show-FixItShareForm }
Add-Scenario 'whats-shared-first-run' { Show-FixItPrivacyForm -FirstRun $true }
Add-Scenario 'whats-shared' { Show-FixItPrivacyForm -FirstRun $false }
Add-Scenario 'did-that-fix-it' { [void](Show-FixItFixedDialog -Title 'Did that fix it?' -Detail 'I just ran Fix sound, mic and camera. Try it now, then let me know.') }
Add-Scenario 'chrome-question' { [void](Show-FixItChromeAskDialog) }
Add-Scenario 'printer-pick' { [void](Show-FixItPrinterPickDialog -Names @('Microsoft Print to PDF', 'HP OfficeJet Pro 9015e Series (Network) on PRINT-SERVER-01 in the upstairs hallway', 'Brother HL-L2350DW series', 'Canon TR8620a', 'OneNote (Desktop)') -Current 'Brother HL-L2350DW series') }
Add-Scenario 'countdown' { Show-FixItCountdownDialog -Seconds 30 -Title 'Please wait' -Message 'Windows is restarting the printing service. This takes about half a minute. Please do not close this window or turn off the computer.' }
Add-Scenario 'scary-popup-sent' { Show-FixItScamForm -Result (New-FixItResult $true 'Do not call that number' ("STOP. Do NOT call any phone number on the screen.`r`n`r`n1. Turn off your Wi-Fi now (or unplug the network cable).`r`n2. Do not click anything else, and do not type any passwords.`r`n3. Call Trey.`r`n`r`nTrey never asks you for codes or to install remote-control programs unless YOU contacted him first.`r`n`r`nA report about this computer was sent to Trey.") @() @{ Scam = $true; Sent = $true; ReportPath = 'C:\x' }) }
Add-Scenario 'scary-popup-not-sent' { Show-FixItScamForm -Result (New-FixItResult $true 'Do not call that number' ("STOP. Do NOT call any phone number on the screen.`r`n`r`n1. Turn off your Wi-Fi now (or unplug the network cable).`r`n2. Do not click anything else, and do not type any passwords.`r`n3. Call Trey.`r`n`r`nTrey never asks you for codes or to install remote-control programs unless YOU contacted him first.`r`n`r`nThe report could not be sent, so tell Trey on the phone. A copy is saved in the 'Family Fix-It Reports' folder in your Documents.") @() @{ Scam = $true; Sent = $false; ReportPath = 'C:\x' }) }
# the bigger windows
Add-Scenario 'my-files' { Show-FixItFilesDialog } -Settle 4 -Ready { $script:FilesPanel -ne $null -and $script:FilesPanel.Controls.Count -gt 0 }
Add-Scenario 'install-an-app' { Show-FixItAppsDialog } -Settle 3
Add-Scenario 'my-pc-info' { $r = Invoke-PcInfo; Show-FixItPcInfoForm -Result $r } -Settle 3
Add-Scenario 'help-me-with-guides' { Show-FixItGuidesDialog } -Settle 3
foreach ($g in @(Get-FixItGuides)) { $gg = $g; Add-Scenario ('guide-' + [string]$gg.Id) ({ Show-FixItGuideSteps -Guide $gg }.GetNewClosure()) }
Add-Scenario 'guide-pin-taskbar' { Show-FixItGuideSteps -Guide (Get-FixItPinGuide) }
Add-Scenario 'test-mode-results' { Show-FixItTextDialog -Title 'Family Fix-It (Test mode) - all buttons' -Lines @('[PASS] Fix my printer', '[WARN] Fix Outlook: Outlook is not installed on this PC', '[PASS] Fix my internet', '[FAIL] Fix OneDrive: the sign-in check did not answer') -Status 'WARN' -Heading 'WARN: all buttons tested' }
# the plain message boxes (drawn by Windows itself): update messages and a fix result
Add-Scenario 'message-update-done' { Show-FixItResult (New-FixItResult $true 'Updated' ('Updated to version {0}. Please close this window and open Family Fix-It again.' -f $script:FixItVersion) @() @{ Updated = $true }) }
Add-Scenario 'message-update-failed' { Show-FixItResult (New-FixItResult $false 'Update did not work' 'The update did not work, so nothing was changed. You can keep using this version.') }
Add-Scenario 'message-update-question' { [void](Confirm-FixIt ('A newer version of this tool is available ({0}). Update now? It only takes a moment.' -f $script:FixItVersion)) }
Add-Scenario 'message-fix-result' { Show-FixItResult (New-FixItResult $true 'Printer fixed' 'The printing service was restarted and 2 stuck print jobs were cleared.' @('Restarted the print spooler.', 'Cleared 2 stuck print jobs (print them again if you still need them).', 'Your printers and documents were not changed.')) }
# the pop-up watcher's toast uses the real screen DPI (not the simulated scale), so it is only drawn once (at 100%)
if ($Scale -eq 1.0 -and $Mode -eq 'Normal') {
    Add-Scenario 'watcher-toast' { Show-FixItGuardianToast } -Settle 3
    Add-Scenario 'watcher-toast-calm' { Set-FixItGuardianToast -Mode 'Calm' -Text ("(Practice only - nothing was closed.) " + $script:GuardianCalm + "`r`n`r`n" + $script:GuardianRestoreAdvice) -Status 'Trey has been told.' -Done $true } -Settle 3
}

# ====================================================================================================================================
# Run
# ====================================================================================================================================
$started = Get-Date
$pickList = @($scen | Where-Object { (-not $Only) -or ($_.Name -like ('*' + $Only + '*')) })
Write-Host ('Family Fix-It screen check: version {0}, scale {1}x, mode {2}, {3} windows' -f $appVersion, $Scale, $Mode, $pickList.Count)
foreach ($sc in $pickList) {
    $before = $script:Findings.Count
    $t0 = Get-Date
    try { Invoke-Scenario -Sc $sc } catch { Write-Host ('  harness problem in {0}: {1}' -f $sc.Name, $_.Exception.Message); $script:Cur = $null; $script:Findings.Add([ordered]@{ scenario = $sc.Name; window = ''; scale = $Scale; mode = $Mode; type = 'harness-error'; control = ''; detail = $_.Exception.Message; rect = $null }) | Out-Null }
    $n = $script:Findings.Count - $before
    Write-Host ('  {0,-34} {1} ({2:0.0}s)' -f $sc.Name, $(if ($n -eq 0) { 'ok' } else { ('{0} finding(s)' -f $n) }), ((Get-Date) - $t0).TotalSeconds)
}
if ((-not $Only) -or ('tray-icon' -like ('*' + $Only + '*'))) {
    if ($Scale -eq 1.0 -and $Mode -eq 'Normal') {
        $before = $script:Findings.Count
        try { Test-TrayIcon } catch { $script:Cur = $null; Write-Host ('  harness problem in tray-icon: ' + $_.Exception.Message) }
        $n = $script:Findings.Count - $before
        Write-Host ('  {0,-34} {1}' -f 'tray-icon', $(if ($n -eq 0) { 'ok' } else { ('{0} finding(s)' -f $n) }))
    }
}
try { $script:Stub.Close() } catch { }

$scr = [System.Windows.Forms.Screen]::PrimaryScreen
$trayInfoOut = $null; if (Get-Variable -Name TrayInfo -Scope Script -ErrorAction SilentlyContinue) { $trayInfoOut = $script:TrayInfo }
$report = [ordered]@{
    version = $appVersion; scale = $Scale; mode = $Mode; effective_ui_scale = $script:UiScale
    method = 'UiScale set directly in a fresh process (the program lays out everything as base size x UiScale); real Windows DPI not changed'
    screen = ('{0}x{1}' -f $scr.Bounds.Width, $scr.Bounds.Height); working_area = ('{0}x{1}' -f $scr.WorkingArea.Width, $scr.WorkingArea.Height)
    real_dpi = [math]::Round(([System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)).DpiX, 0)
    os = [string][Environment]::OSVersion.VersionString; powershell = [string]$PSVersionTable.PSVersion
    started = $started.ToString('s'); seconds = [int]((Get-Date) - $started).TotalSeconds
    window_count = $script:Windows.Count; finding_count = $script:Findings.Count
    tray = $trayInfoOut
    windows = @($script:Windows); findings = @($script:Findings)
}
$json = $report | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText((Join-Path $OutDir 'findings.json'), $json, (New-Object Text.UTF8Encoding($false)))
Write-Host ('Done: {0} windows pictured, {1} finding(s). Results in {2}' -f $script:Windows.Count, $script:Findings.Count, $OutDir)
foreach ($f in $script:Findings) { Write-Host ('  FINDING [{0}] {1} / {2}: {3}' -f $f.type, $f.scenario, $f.control, $f.detail) }
try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
if ($script:Findings.Count -gt 0) { exit 1 }
exit 0
