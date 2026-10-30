<#
Set-ScreenSize.ps1  -  part of the pre-release screen check (see tools/ScreenCheck.ps1).
Changes the screen size of the machine it runs on (the Windows runner), so every check sees the same "reference" screen:
a normal 1920 x 1080 laptop screen. Only used on the CI runner; never run it on a family PC.
Usage:  powershell -File tools\Set-ScreenSize.ps1 -Width 1920 -Height 1080
It never fails the job: if the mode is not offered it keeps the current size and says so.
#>
param([int]$Width = 1920, [int]$Height = 1080)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ScreenSizeNative {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
        public int dmDisplayFlags; public int dmDisplayFrequency;
        public int dmICMMethod; public int dmICMIntent; public int dmMediaType; public int dmDitherType;
        public int dmReserved1; public int dmReserved2; public int dmPanningWidth; public int dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Ansi)] public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
    [DllImport("user32.dll", CharSet = CharSet.Ansi)] public static extern int ChangeDisplaySettings(ref DEVMODE devMode, int flags);
    public static string Describe() {
        DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettings(null, -1, ref dm)) return "unknown";
        return dm.dmPelsWidth + "x" + dm.dmPelsHeight;
    }
    public static string Set(int w, int h) {
        DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettings(null, -1, ref dm)) return "could not read the current mode";
        int i = 0; DEVMODE best = new DEVMODE(); bool found = false;
        DEVMODE cur = new DEVMODE(); cur.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        while (EnumDisplaySettings(null, i, ref cur)) {
            if (cur.dmPelsWidth == w && cur.dmPelsHeight == h && cur.dmBitsPerPel >= 24) { best = cur; found = true; }
            i++;
        }
        if (!found) return "the mode " + w + "x" + h + " is not offered here (" + i + " modes listed)";
        int r = ChangeDisplaySettings(ref best, 0);
        return (r == 0) ? "ok" : ("ChangeDisplaySettings returned " + r);
    }
}
'@
$before = [ScreenSizeNative]::Describe()
$res = 'skipped'
try { $res = [ScreenSizeNative]::Set($Width, $Height) } catch { $res = 'error: ' + $_.Exception.Message }
Start-Sleep -Seconds 3
$after = [ScreenSizeNative]::Describe()
Write-Host ('Screen size: before {0}, wanted {1}x{2}, result "{3}", now {4}' -f $before, $Width, $Height, $res, $after)
exit 0
