#Requires -Version 5.1
<#
.SYNOPSIS
  OLED Guard: covers the TV (found by its EDID id) with a black window after a period of
  inactivity, so a static desktop never sits on the OLED panel. Any input brings it back.

.DESCRIPTION
  Activity is any of:
    - keyboard / mouse input (GetLastInputInfo)
    - an XInput game controller (Xbox pads; PlayStation pads only through Steam Input / DS4Windows)
    - sound on the default playback device (so a playing movie isn't blanked), unless -IgnoreAudio
  Only displays whose monitor id contains one of -Match are covered; the others stay untouched.
  While the TV is active the taskbar auto-hides, the desktop background is plain black and the
  desktop icons are hidden; when the TV goes away, or the guard exits, all three go back to what
  they were (also after a crash: the
  originals are saved in %LOCALAPPDATA%\OledGuard until restored).
  Black on OLED means the pixels are off, which is as good as the panel being off.

.EXAMPLE
  .\oled-guard.ps1                    # run with a tray icon
  .\oled-guard.ps1 -IdleMinutes 5
  .\oled-guard.ps1 -Status            # print what it detects and exit
  .\oled-guard.ps1 -Restore           # put taskbar, background and icons back and exit
#>
param(
    # Substrings of the monitor device id (EDID manufacturer + product code). S95F = SAM78B4.
    [string[]]$Match = @('SAM78B4'),
    [double]$IdleMinutes = 10,
    # Don't count sound as activity (then a quiet video or music will not keep the TV on either).
    [switch]$IgnoreAudio,
    # Peak level (0..1) on the default playback device that counts as "something is playing".
    [double]$AudioThreshold = 0.001,
    # Leave the taskbar alone (by default it auto-hides while the TV is active).
    [switch]$KeepTaskbar,
    # Leave the desktop background alone (by default it is plain black while the TV is active).
    [switch]$KeepWallpaper,
    # Leave the desktop icons alone (by default they are hidden while the TV is active).
    [switch]$KeepIcons,
    [switch]$Status,
    # Put taskbar, background and icons back (if a guard changed them and didn't get to) and exit.
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

if (-not ('OledGuard.Native' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace OledGuard {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    public class MMDeviceEnumeratorCo {}

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDevice {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams,
                                   [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioMeterInformation {
        [PreserveSig] int GetPeakValue(out float peak);
    }

    [ComImport, Guid("C2CF3110-460E-4fc1-B9D0-8A1C0C9CC4BD")]
    public class DesktopWallpaperCo {}

    // Method order matters (vtable); only Get/SetBackgroundColor, GetStatus and Enable are used.
    [ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDesktopWallpaper {
        void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitor, [MarshalAs(UnmanagedType.LPWStr)] string path);
        [return: MarshalAs(UnmanagedType.LPWStr)] string GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitor);
        [return: MarshalAs(UnmanagedType.LPWStr)] string GetMonitorDevicePathAt(uint i);
        uint GetMonitorDevicePathCount();
        void GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitor, out long a, out long b);
        void SetBackgroundColor(uint color);
        uint GetBackgroundColor();
        void SetPosition(int p);
        int GetPosition();
        void SetSlideshow(IntPtr items);
        IntPtr GetSlideshow();
        void SetSlideshowOptions(int options, uint ms);
        void GetSlideshowOptions(out int options, out uint ms);
        void AdvanceSlideshow([MarshalAs(UnmanagedType.LPWStr)] string monitor, int direction);
        int GetStatus();
        void Enable([MarshalAs(UnmanagedType.Bool)] bool enable);
    }

    // Turning the picture off (not replacing it) keeps a slideshow / Spotlight / picture setup intact:
    // turning it back on restores exactly what was there.
    public static class Wallpaper {
        static IDesktopWallpaper W() { return (IDesktopWallpaper)new DesktopWallpaperCo(); }
        public static bool PictureOn() { return (W().GetStatus() & 1) != 0; }      // DSS_ENABLED
        public static void SetPicture(bool on) { W().Enable(on); }
        public static uint Color() { return W().GetBackgroundColor(); }          // COLORREF 0x00BBGGRR
        public static void SetColor(uint c) { W().SetBackgroundColor(c); }
    }

    // A black, borderless, topmost window that never takes focus (so a game or player in the
    // foreground keeps it) and stays out of Alt+Tab and the taskbar.
    public class BlankForm : Form {
        public BlankForm(System.Drawing.Rectangle bounds) {
            FormBorderStyle = FormBorderStyle.None;
            BackColor = System.Drawing.Color.Black;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            TopMost = true;
            Bounds = bounds;
        }
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams {
            get {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000 | 0x00000080 | 0x00000008; // NOACTIVATE | TOOLWINDOW | TOPMOST
                return cp;
            }
        }
    }

    public static class Native {
        [StructLayout(LayoutKind.Sequential)]
        struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
        [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);

        public static uint InputIdleMs() {
            LASTINPUTINFO l = new LASTINPUTINFO();
            l.cbSize = 8;
            if (!GetLastInputInfo(ref l)) return 0;
            return unchecked((uint)Environment.TickCount - l.dwTime);
        }

        // --- taskbar auto-hide --------------------------------------------------------------
        [StructLayout(LayoutKind.Sequential)]
        struct RECT { public int left, top, right, bottom; }
        [StructLayout(LayoutKind.Sequential)]
        struct APPBARDATA {
            public int cbSize; public IntPtr hWnd; public uint uCallbackMessage; public uint uEdge;
            public RECT rc; public IntPtr lParam;
        }
        [DllImport("shell32.dll")] static extern UIntPtr SHAppBarMessage(uint msg, ref APPBARDATA data);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);

        public static bool GetTaskbarAutoHide() {
            APPBARDATA d = new APPBARDATA();
            d.cbSize = Marshal.SizeOf(typeof(APPBARDATA));
            return ((ulong)SHAppBarMessage(4, ref d) & 1) != 0;          // ABM_GETSTATE, ABS_AUTOHIDE
        }

        // The same setting as Settings > Personalization > Taskbar > "Automatically hide the taskbar":
        // it applies to every taskbar and Explorer saves it.
        public static void SetTaskbarAutoHide(bool on) {
            APPBARDATA d = new APPBARDATA();
            d.cbSize = Marshal.SizeOf(typeof(APPBARDATA));
            d.hWnd = FindWindow("Shell_TrayWnd", null);
            d.lParam = (IntPtr)(on ? 1 : 2);                                  // ABS_AUTOHIDE : ABS_ALWAYSONTOP
            SHAppBarMessage(10, ref d);                                       // ABM_SETSTATE
        }

        // --- desktop icons ------------------------------------------------------------------
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);

        // The desktop's folder view: under Progman, or under a WorkerW once a slideshow / wallpaper
        // animation has run.
        static IntPtr DesktopView() {
            IntPtr dv = FindWindowEx(FindWindow("Progman", null), IntPtr.Zero, "SHELLDLL_DefView", null);
            IntPtr w = IntPtr.Zero;
            while (dv == IntPtr.Zero && (w = FindWindowEx(IntPtr.Zero, w, "WorkerW", null)) != IntPtr.Zero)
                dv = FindWindowEx(w, IntPtr.Zero, "SHELLDLL_DefView", null);
            return dv;
        }

        // 1 = shown, 0 = hidden, -1 = no desktop (Explorer not running).
        public static int DesktopIconsShown() {
            IntPtr dv = DesktopView();
            if (dv == IntPtr.Zero) return -1;
            IntPtr lv = FindWindowEx(dv, IntPtr.Zero, "SysListView32", null);
            if (lv == IntPtr.Zero) return -1;
            return IsWindowVisible(lv) ? 1 : 0;
        }

        // Same as right-click desktop > View > Show desktop icons (a toggle; Explorer saves it).
        public static void SetDesktopIcons(bool show) {
            int now = DesktopIconsShown();
            if (now < 0 || (now == 1) == show) return;
            SendMessage(DesktopView(), 0x0111, (IntPtr)0x7402, IntPtr.Zero);   // WM_COMMAND
        }

        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        // --- displays ---------------------------------------------------------------------
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct DISPLAY_DEVICE {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
            public int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
        }
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplayDevices(string device, uint index, ref DISPLAY_DEVICE dd, uint flags);

        // Active monitor ids (e.g. \\?\DISPLAY#SAM78B4#...) shown on a desktop output like \\.\DISPLAY1.
        public static string[] ActiveMonitorIds(string outputName) {
            List<string> ids = new List<string>();
            for (uint i = 0; i < 16; i++) {
                DISPLAY_DEVICE m = new DISPLAY_DEVICE();
                m.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (!EnumDisplayDevices(outputName, i, ref m, 1)) break; // 1 = EDD_GET_DEVICE_INTERFACE_NAME
                if ((m.StateFlags & 1) != 0) ids.Add(m.DeviceID);         // 1 = DISPLAY_DEVICE_ACTIVE
            }
            return ids.ToArray();
        }

        // --- XInput controllers ---------------------------------------------------------------
        [StructLayout(LayoutKind.Sequential)]
        struct XINPUT_STATE {
            public uint packet; public ushort buttons; public byte lt, rt;
            public short lx, ly, rx, ry;
        }
        [DllImport("xinput1_4.dll")] static extern int XInputGetState(int user, out XINPUT_STATE state);

        static XINPUT_STATE[] lastPad = new XINPUT_STATE[4];
        static bool[] padSeen = new bool[4];
        static bool xinputMissing;

        static bool Moved(short a, short b) { return Math.Abs(a - b) > 6000; } // ignore stick drift

        // True when a connected pad changed meaningfully since the last call.
        public static bool ControllerActivity() {
            if (xinputMissing) return false;
            bool any = false;
            for (int i = 0; i < 4; i++) {
                XINPUT_STATE s;
                try {
                    if (XInputGetState(i, out s) != 0) { padSeen[i] = false; continue; }
                } catch (DllNotFoundException) { xinputMissing = true; return false; }
                if (padSeen[i]) {
                    XINPUT_STATE p = lastPad[i];
                    if (s.buttons != p.buttons || Math.Abs(s.lt - p.lt) > 40 || Math.Abs(s.rt - p.rt) > 40 ||
                        Moved(s.lx, p.lx) || Moved(s.ly, p.ly) || Moved(s.rx, p.rx) || Moved(s.ry, p.ry))
                        any = true;
                }
                if (!padSeen[i] || any) lastPad[i] = s;
                padSeen[i] = true;
            }
            return any;
        }

        public static int ConnectedPads() {
            int n = 0;
            for (int i = 0; i < 4; i++) {
                XINPUT_STATE s;
                try { if (XInputGetState(i, out s) == 0) n++; } catch (DllNotFoundException) { return 0; }
            }
            return n;
        }

        // --- audio --------------------------------------------------------------------------
        // Peak level of what the default playback device is playing right now (0..1).
        public static float AudioPeak() {
            object en = null, meter = null; IMMDevice dev = null;
            try {
                en = new MMDeviceEnumeratorCo();
                if (((IMMDeviceEnumerator)en).GetDefaultAudioEndpoint(0, 1, out dev) != 0 || dev == null) return 0;
                Guid iid = typeof(IAudioMeterInformation).GUID;
                if (dev.Activate(ref iid, 23, IntPtr.Zero, out meter) != 0 || meter == null) return 0;
                float peak;
                if (((IAudioMeterInformation)meter).GetPeakValue(out peak) != 0) return 0;
                return peak;
            } catch { return 0; }
            finally {
                if (meter != null) Marshal.ReleaseComObject(meter);
                if (dev != null) Marshal.ReleaseComObject(dev);
                if (en != null) Marshal.ReleaseComObject(en);
            }
        }
    }
}
'@
}

# Real pixel coordinates on scaled displays (must happen before any window is created).
try { [void][OledGuard.Native]::SetProcessDpiAwarenessContext([IntPtr]-4) } catch { [void][OledGuard.Native]::SetProcessDPIAware() }

# Written when the guard turns auto-hide on, holding the person's own setting ("True"/"False").
# It outlives a crash or a kill, so the next start still knows what to put back.
$TaskbarMarker = Join-Path $env:LOCALAPPDATA 'OledGuard\taskbar-original.txt'

function Set-TaskbarForTv([bool]$tvActive) {
    if ($tvActive -and -not $KeepTaskbar) {
        if (-not (Test-Path $TaskbarMarker)) {
            $original = [OledGuard.Native]::GetTaskbarAutoHide()
            New-Item -ItemType Directory -Force (Split-Path $TaskbarMarker) | Out-Null
            Set-Content -Path $TaskbarMarker -Value $original
        }
        if (-not [OledGuard.Native]::GetTaskbarAutoHide()) { [OledGuard.Native]::SetTaskbarAutoHide($true) }
    } elseif (Test-Path $TaskbarMarker) {
        # TV gone (or -KeepTaskbar): put back exactly what was there before.
        $original = (Get-Content $TaskbarMarker -ErrorAction SilentlyContinue) -eq 'True'
        if ([OledGuard.Native]::GetTaskbarAutoHide() -ne $original) { [OledGuard.Native]::SetTaskbarAutoHide($original) }
        Remove-Item $TaskbarMarker -Force
    }
}

# Same idea for the background: "<picture on: True/False> <color>".
$WallpaperMarker = Join-Path $env:LOCALAPPDATA 'OledGuard\wallpaper-original.txt'

function Set-WallpaperForTv([bool]$tvActive) {
    if ($tvActive -and -not $KeepWallpaper) {
        if (-not (Test-Path $WallpaperMarker)) {
            New-Item -ItemType Directory -Force (Split-Path $WallpaperMarker) | Out-Null
            Set-Content -Path $WallpaperMarker -Value ('{0} {1}' -f [OledGuard.Wallpaper]::PictureOn(), [OledGuard.Wallpaper]::Color())
        }
        if ([OledGuard.Wallpaper]::Color() -ne 0) { [OledGuard.Wallpaper]::SetColor(0) }
        if ([OledGuard.Wallpaper]::PictureOn()) { [OledGuard.Wallpaper]::SetPicture($false) }
    } elseif (Test-Path $WallpaperMarker) {
        $on, $color = (Get-Content $WallpaperMarker -ErrorAction SilentlyContinue) -split ' '
        if ($color -match '^\d+$' -and [OledGuard.Wallpaper]::Color() -ne [uint32]$color) { [OledGuard.Wallpaper]::SetColor([uint32]$color) }
        if (($on -eq 'True') -ne [OledGuard.Wallpaper]::PictureOn()) { [OledGuard.Wallpaper]::SetPicture($on -eq 'True') }
        Remove-Item $WallpaperMarker -Force
    }
}

# And the desktop icons: "True" when they were shown before the guard hid them.
$IconsMarker = Join-Path $env:LOCALAPPDATA 'OledGuard\icons-original.txt'

function Set-IconsForTv([bool]$tvActive) {
    $shown = [OledGuard.Native]::DesktopIconsShown()
    if ($shown -lt 0) { return }    # Explorer restarting: try again on the next check
    if ($tvActive -and -not $KeepIcons) {
        if (-not (Test-Path $IconsMarker)) {
            New-Item -ItemType Directory -Force (Split-Path $IconsMarker) | Out-Null
            Set-Content -Path $IconsMarker -Value ($shown -eq 1)
        }
        if ($shown -eq 1) { [OledGuard.Native]::SetDesktopIcons($false) }
    } elseif (Test-Path $IconsMarker) {
        [OledGuard.Native]::SetDesktopIcons((Get-Content $IconsMarker -ErrorAction SilentlyContinue) -eq 'True')
        Remove-Item $IconsMarker -Force
    }
}

function Set-TvDesktop([bool]$tvActive) {
    try { Set-TaskbarForTv $tvActive } catch {}
    try { Set-WallpaperForTv $tvActive } catch {}
    try { Set-IconsForTv $tvActive } catch {}
}

function Get-TvScreens {
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        $ids = [OledGuard.Native]::ActiveMonitorIds($s.DeviceName)
        foreach ($id in $ids) {
            foreach ($m in $Match) {
                if ($id -like "*$m*") { $s; break }
            }
        }
    }
}

if ($Restore) {
    Set-TvDesktop $false
    return
}

if ($Status) {
    "Displays:"
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        $ids = [OledGuard.Native]::ActiveMonitorIds($s.DeviceName) | ForEach-Object { ($_ -split '#')[1] }
        $tv = if (@(Get-TvScreens | Where-Object DeviceName -eq $s.DeviceName).Count) { '  <- TV, will be blanked' } else { '' }
        "  {0}  {1}  monitors: {2}{3}" -f $s.DeviceName, $s.Bounds, ($ids -join ', '), $tv
    }
    "Taskbar:          {0}" -f $(if ([OledGuard.Native]::GetTaskbarAutoHide()) { 'auto-hide' } else { 'always shown' })
    if (Test-Path $TaskbarMarker) { "                  (OLED Guard hid it; your own setting was: {0})" -f (Get-Content $TaskbarMarker) }
    "Background:       picture {0}, color 0x{1:X6}" -f $(if ([OledGuard.Wallpaper]::PictureOn()) { 'on' } else { 'off' }), [OledGuard.Wallpaper]::Color()
    if (Test-Path $WallpaperMarker) { "                  (OLED Guard blacked it; saved: {0})" -f (Get-Content $WallpaperMarker) }
    "Desktop icons:    {0}" -f @('hidden', 'shown', 'unknown (no desktop)')[[OledGuard.Native]::DesktopIconsShown() -replace '-1', '2']
    if (Test-Path $IconsMarker) { "                  (OLED Guard hid them; shown before: {0})" -f (Get-Content $IconsMarker) }
    "Input idle:       {0:N1} s" -f ([OledGuard.Native]::InputIdleMs() / 1000)
    "Controllers:      {0} connected (XInput)" -f [OledGuard.Native]::ConnectedPads()
    "Audio peak now:   {0:N4} (counts as activity above {1})" -f [OledGuard.Native]::AudioPeak(), $AudioThreshold
    return
}

# One instance per user session.
$mutex = New-Object System.Threading.Mutex($false, 'Local\OledGuard')
if (-not $mutex.WaitOne(0)) { return }

$idleLimitMs = [int]($IdleMinutes * 60000)
$state = @{
    Blankers    = @()
    BlankedAt   = [datetime]::MinValue
    LastPad     = [datetime]::Now
    LastAudio   = [datetime]::Now
    PausedUntil = [datetime]::MinValue
    NextScan    = [datetime]::MinValue
    TvScreens   = @()
    Force       = $false
}

function Show-Blank {
    if ($state.Blankers.Count) { return }
    if (-not $state.TvScreens.Count) { return }
    $state.Blankers = @(foreach ($s in $state.TvScreens) {
        $f = New-Object OledGuard.BlankForm($s.Bounds)
        $f.Show()
        $f
    })
    [System.Windows.Forms.Cursor]::Hide()
    $state.BlankedAt = [datetime]::Now
}

function Hide-Blank {
    if (-not $state.Blankers.Count) { return }
    foreach ($f in $state.Blankers) { $f.Close(); $f.Dispose() }
    $state.Blankers = @()
    [System.Windows.Forms.Cursor]::Show()
    $state.Force = $false
}

# --- tray icon --------------------------------------------------------------------------------
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Shield
$tray.Text = 'OLED Guard'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miBlank  = $menu.Items.Add('Blank TV now')
$miPause  = $menu.Items.Add('Pause for 1 hour')
$miResume = $menu.Items.Add('Resume')
[void]$menu.Items.Add('-')
$miExit   = $menu.Items.Add('Exit')
$tray.ContextMenuStrip = $menu
$tray.Visible = $true

$miBlank.Add_Click({ $state.Force = $true; $state.NextScan = [datetime]::MinValue })
$miPause.Add_Click({ $state.PausedUntil = [datetime]::Now.AddHours(1); Hide-Blank })
$miResume.Add_Click({ $state.PausedUntil = [datetime]::MinValue })
$miExit.Add_Click({ [System.Windows.Forms.Application]::Exit() })

# --- main loop --------------------------------------------------------------------------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    try {
        $now = [datetime]::Now

        if ($now -ge $state.NextScan) {
            $state.TvScreens = @(Get-TvScreens)
            # Every 2 s: plugging, unplugging or switching the TV off shows up within that.
            $state.NextScan = $now.AddSeconds(2)
            # The TV went away or moved: drop stale covers (re-blanked on the new bounds if still idle).
            if ($state.Blankers.Count) {
                $covered = @($state.Blankers | ForEach-Object { $_.Bounds.ToString() }) -join ';'
                $wanted = @($state.TvScreens | ForEach-Object { $_.Bounds.ToString() }) -join ';'
                if ($covered -ne $wanted) { $force = $state.Force; Hide-Blank; $state.Force = $force -and $state.TvScreens.Count }
            }
            Set-TvDesktop ($state.TvScreens.Count -gt 0)
        }

        if ([OledGuard.Native]::ControllerActivity()) { $state.LastPad = $now }
        $inputIdle = [OledGuard.Native]::InputIdleMs()

        if ($state.Blankers.Count) {
            # Only real input wakes it; ignore the click that chose "Blank TV now".
            $padRecent = ($now - $state.LastPad).TotalMilliseconds -lt 1000
            if (($now - $state.BlankedAt).TotalMilliseconds -gt 1500 -and ($inputIdle -lt 1000 -or $padRecent)) {
                Hide-Blank
            }
            return
        }

        $paused = $now -lt $state.PausedUntil
        $tray.Text = if ($paused) { 'OLED Guard (paused)' } elseif ($state.TvScreens.Count) { 'OLED Guard: watching TV' } else { 'OLED Guard: TV not active' }
        if ($paused) { return }

        if (-not $IgnoreAudio -and [OledGuard.Native]::AudioPeak() -gt $AudioThreshold) { $state.LastAudio = $now }

        $idle = [math]::Min($inputIdle, [math]::Min(($now - $state.LastPad).TotalMilliseconds, ($now - $state.LastAudio).TotalMilliseconds))
        if ($state.Force -or $idle -ge $idleLimitMs) { Show-Blank }
    } catch {
        # Never die on a transient error (display reconfiguration, audio device change).
    }
})
$timer.Start()

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    $timer.Stop()
    Hide-Blank
    Set-TvDesktop $false        # leave taskbar, background and icons as they were before the guard started
    $tray.Visible = $false
    $tray.Dispose()
    $mutex.ReleaseMutex()
}
