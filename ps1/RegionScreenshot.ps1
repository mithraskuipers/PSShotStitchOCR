<#
.SYNOPSIS
    Region screenshot tool.

.DESCRIPTION
    On startup, lets you drag out a rectangle on your screen(s) to define a
    capture region. Once selected, the tool sits in the system tray and
    listens for a capture hotkey (which can be a combo of up to 4 keys
    and/or mouse buttons - side buttons, middle-click, etc. - e.g.
    Ctrl+Shift+S) and a separate stop hotkey (default Ctrl+Shift+Q)
    that shuts the tool down cleanly. Both are detected system-wide, so
    they work even when this tool's window isn't focused - you can be
    typing in another app and still trigger a capture or stop the tool.
    Use the stop hotkey (or the tray menu's "Exit") instead of closing the
    terminal window, which can otherwise produce an ugly ".NET has stopped
    working"-style crash warning.

    Every time the hotkey combo is pressed, a screenshot of the selected
    rectangle is saved to disk, and the captured area flashes briefly on
    screen so you know it was taken. A separate clipboard hotkey (default
    Ctrl+Shift+Alt+S) captures the same region straight to the clipboard
    instead, with no file written to disk.

    A red outline is drawn around the capture region at all times, so you
    can always see at a glance what will be captured. Press the toggle
    hotkey (default Ctrl+Shift+H) to hide or reshow it, or use the tray
    menu's "Hide/Show Region Border" option. It's automatically hidden for
    the instant a screenshot is taken, so it never ends up in the image.

    The region can also be nudged and resized without redrawing it from
    scratch: hold the move-region modifier (default Ctrl+Alt) together
    with an arrow key to shift the region in that direction, or hold the
    resize-region modifier (default Ctrl+Alt+Shift) together with an arrow
    key to grow/shrink its width or height. Both modifiers, and the number
    of pixels each key press moves/resizes by, are configurable.

    You can also turn on automatic capturing, which takes a screenshot of
    the region every few seconds (as low as every 1 second). It can be
    started and stopped any time from the tray menu or with its own
    dedicated hotkey (default Ctrl+Shift+A), and optionally set to start
    automatically when the tool launches.

    By default, each auto-capture run saves into its own timestamped
    subfolder under SaveLocation ("session folders" - configurable via
    AutoCaptureUseSessionFolders / AutoCaptureSessionFolderScheme). When
    auto-capture is stopped, that session's screenshots are automatically
    handed off to the Screenshot Stitcher web app (Start-ReviewWebServer.ps1
    / "Start Review & Stitch.bat" opens it in your browser), which shows a
    review grid so you can uncheck any bad frames and reorder before
    stitching them into one long image. This hand-off can be turned off
    (AutoLaunchReviewOnStop) if you'd rather trigger it manually from the
    tray menu's "Review Last Session..." or "Review & Stitch..." items.

    Auto-capture can optionally send a key or key combo (e.g. F8) to
    whichever application currently has focus, either right before or
    right after each shot - handy for e.g. advancing to the next
    slide/frame right before it's captured, or triggering the next step
    right after. The key combo, the before/after timing, and the delay
    between the key press and the screenshot are all configurable.

    Hotkeys, save location, filename scheme, move/resize step size, and
    auto-capture interval are all read from "config.json" next to this
    script, if present. Use the companion "Configure.ps1" (via "Configure
    Screenshot Tool.bat") to edit those settings through a small form
    instead of hand-editing JSON. If no config.json exists, sensible
    defaults are used.

    Tray icon menu options:
        - Reselect Region        : redraw the capture rectangle
        - Hide/Show Region Border: toggles the red region outline
        - Open Screenshots       : opens the output folder in Explorer
        - Start/Stop Auto-Capture: toggles automatic timed capturing
        - Review Last Session... : opens Review & Stitch on the most recent
                                    auto-capture session (enabled once one
                                    has run)
        - Review & Stitch...     : opens Review & Stitch on the main
                                    Screenshots folder
        - Reload Config          : re-reads config.json without restarting
        - Exit                   : quits the tool

    Region controls (hold modifier + arrow key):
        - Move-region modifier   : arrow keys shift the region
        - Resize-region modifier : arrow keys grow/shrink the region

    Auto-capture can also be started/stopped with its own hotkey (default
    Ctrl+Shift+A), independent of the capture/clipboard/stop/toggle-border
    hotkeys above.

.NOTES
    Run via "Start Screenshot Tool.bat" (handles STA + execution policy).
#>

param(
    # Forces the automatic hand-off to Review & Stitch on auto-capture stop
    # OFF for this run, regardless of AutoLaunchReviewOnStop in config.json.
    # Used by Start_All.bat's "screenshot tool only" menu option so it
    # never spawns the review web server; config.json itself is untouched,
    # so every other launcher (including this same .bat run without the
    # switch) keeps following the saved setting.
    [switch]$NoAutoReview
)

# ---------------------------------------------------------------------------
# WinForms requires an STA thread. Launch this script via the accompanying
# .bat file (which passes -STA), or manually with:
#   powershell -STA -NoProfile -ExecutionPolicy Bypass -File RegionScreenshot.ps1
# ---------------------------------------------------------------------------
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host ''
    Write-Host 'ERROR: This script must run in STA mode.' -ForegroundColor Red
    Write-Host 'Use the included "Start Screenshot Tool.bat", or run manually with:' -ForegroundColor Yellow
    Write-Host '  powershell -STA -NoProfile -ExecutionPolicy Bypass -File RegionScreenshot.ps1' -ForegroundColor Yellow
    Write-Host ''
    Read-Host 'Press Enter to exit'
    exit 1
}

# ---------------------------------------------------------------------------
# Single-instance guard
# ---------------------------------------------------------------------------
# If this tool is launched a second time (e.g. re-running "Start Screenshot
# Tool.bat" to try a config change without noticing the tray icon from the
# last run is still sitting there), the OLDER instance's auto-capture timer
# keeps running completely unaffected by anything you click in the NEWER
# one's window - including its duplicate-frame pause dialog. That looks
# exactly like "the pause dialog does nothing, capturing continues no
# matter what I click", because the captures you're seeing keep happening
# are coming from that orphaned older process, not the one you're looking
# at. A named Mutex is the standard way to detect that and refuse to start
# a second instance instead of letting two silently run side by side.
$script:singleInstanceMutex = New-Object System.Threading.Mutex($false, 'Local\RegionScreenshotTool_SingleInstance_Mutex')
if (-not $script:singleInstanceMutex.WaitOne(0, $false)) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "Region Screenshot Tool is already running (check your system tray - it may be hidden in the overflow area).`n`nOnly one instance can run at a time, since a second one would keep capturing in the background even while you're looking at this one, invisibly ignoring pauses and settings changes made here.`n`nIf you don't see a tray icon, open Task Manager > Details tab and look for a 'powershell.exe' (or 'pwsh.exe') process - that's the running instance. End it there if you want to start fresh, then run this tool again.",
        'Region Screenshot Tool - Already Running',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
    exit 1
}
Write-Host "Region Screenshot Tool starting. PID=$PID (check Task Manager > Details for this PID if you ever need to confirm which process is running)."

# ---------------------------------------------------------------------------
# DPI awareness
# ---------------------------------------------------------------------------
# Without this, Windows treats the process as DPI-unaware and silently
# virtualizes it on any monitor scale != 100%: mouse coordinates delivered
# to WinForms (used to drag out the capture region) and pixels read back by
# Graphics.CopyFromScreen (used to grab them) end up expressed in two
# different coordinate spaces, so the captured rectangle drifts or gets
# mis-cropped relative to what was dragged out on screen.
#
# This has to run before any window is created, which is why it's the very
# first thing after the STA check - before the Forms/Drawing assemblies are
# even used to build a window. Per-Monitor-v2 is requested first since it
# gives correct behavior when monitors have different scale factors or the
# tool is dragged between them; SetProcessDPIAware is a system-DPI-aware
# fallback for older Windows versions that don't support the v2 context.
Add-Type -Namespace RegionTool -Name DpiNative -MemberDefinition @"
    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetProcessDPIAware();
"@

try {
    # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, per WinUser.h.
    $perMonitorV2 = [IntPtr]::new(-4)
    $dpiOk = [RegionTool.DpiNative]::SetProcessDpiAwarenessContext($perMonitorV2)
    if (-not $dpiOk) {
        [void][RegionTool.DpiNative]::SetProcessDPIAware()
    }
}
catch {
    try { [void][RegionTool.DpiNative]::SetProcessDPIAware() } catch { }
}

# ---------------------------------------------------------------------------
# Assemblies + native interop
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -Namespace RegionTool -Name Native -MemberDefinition @"
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern uint MapVirtualKey(uint uCode, uint uMapType);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
"@

# A borderless flash window that never steals focus or shows in the
# taskbar/alt-tab, so triggering a capture doesn't yank focus away from
# whatever app you're currently working in.
Add-Type -Language CSharp -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Windows.Forms;

namespace RegionTool
{
    public class FlashForm : Form
    {
        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
                cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
                return cp;
            }
        }

        protected override bool ShowWithoutActivation
        {
            get { return true; }
        }
    }
}
"@

# A borderless, click-through, non-activating window that draws only a
# colored outline around its own edges (the interior is punched out via
# TransparencyKey, set from PowerShell after construction). Used to show a
# persistent rectangle around the current capture region so it stays
# visible without blocking mouse clicks or stealing keyboard focus from
# whatever app is underneath it.
Add-Type -Language CSharp -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Windows.Forms;

namespace RegionTool
{
    public class BorderForm : Form
    {
        public int BorderThickness = 3;
        public Color BorderLineColor = Color.Red;

        public BorderForm()
        {
            this.DoubleBuffered = true;
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
                cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
                cp.ExStyle |= 0x00000020; // WS_EX_TRANSPARENT (click-through)
                return cp;
            }
        }

        protected override bool ShowWithoutActivation
        {
            get { return true; }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            using (Pen pen = new Pen(BorderLineColor, BorderThickness))
            {
                float half = BorderThickness / 2f;
                e.Graphics.DrawRectangle(pen, half, half,
                    this.Width - BorderThickness, this.Height - BorderThickness);
            }
        }
    }
}
"@

# ---------------------------------------------------------------------------
# Duplicate-frame detection for auto-capture: compares two same-size
# screenshots pixel-by-pixel and returns the average absolute per-channel
# difference (0 = identical, 255 = maximum possible difference), the same
# scale PSImgStitcherEngine.ps1's AvgError uses. Both bitmaps are coerced to
# 24bpp RGB first (mirroring PicoImage.FromBitmap in that engine) since
# LockBits needs a known, matching pixel format to read raw bytes safely.
# ---------------------------------------------------------------------------
Add-Type -Language CSharp -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace RegionTool
{
    public static class ImageDiff
    {
        private static Bitmap EnsureFormat24bppRgb(Bitmap src, out bool owned)
        {
            if (src.PixelFormat == PixelFormat.Format24bppRgb)
            {
                owned = false;
                return src;
            }
            Bitmap converted = new Bitmap(src.Width, src.Height, PixelFormat.Format24bppRgb);
            using (Graphics g = Graphics.FromImage(converted))
            {
                g.DrawImage(src, 0, 0, src.Width, src.Height);
            }
            owned = true;
            return converted;
        }

        // Returns -1 if the two bitmaps aren't the same size (e.g. the
        // capture region was resized between shots) - a raw pixel compare
        // wouldn't mean anything in that case, so callers should treat -1
        // as "not comparable" rather than "very different".
        public static double AverageDiff(Bitmap a, Bitmap b)
        {
            if (a.Width != b.Width || a.Height != b.Height) return -1;
            int width = a.Width, height = a.Height;
            if (width == 0 || height == 0) return -1;

            bool ownedA, ownedB;
            Bitmap ca = EnsureFormat24bppRgb(a, out ownedA);
            Bitmap cb = EnsureFormat24bppRgb(b, out ownedB);
            try
            {
                Rectangle rect = new Rectangle(0, 0, width, height);
                BitmapData da = ca.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
                BitmapData db = cb.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
                try
                {
                    int rowBytes = width * 3;
                    byte[] rowA = new byte[Math.Abs(da.Stride)];
                    byte[] rowB = new byte[Math.Abs(db.Stride)];
                    long total = 0;
                    for (int y = 0; y < height; y++)
                    {
                        Marshal.Copy(IntPtr.Add(da.Scan0, y * da.Stride), rowA, 0, rowA.Length);
                        Marshal.Copy(IntPtr.Add(db.Scan0, y * db.Stride), rowB, 0, rowB.Length);
                        for (int i = 0; i < rowBytes; i++)
                        {
                            int diff = rowA[i] - rowB[i];
                            total += diff < 0 ? -diff : diff;
                        }
                    }
                    return (double)total / (width * height * 3);
                }
                finally
                {
                    ca.UnlockBits(da);
                    cb.UnlockBits(db);
                }
            }
            finally
            {
                if (ownedA) ca.Dispose();
                if (ownedB) cb.Dispose();
            }
        }
    }
}
"@

# ---------------------------------------------------------------------------
# Script root + config file
# ---------------------------------------------------------------------------
# $PSScriptRoot is empty when this script is fed in via Invoke-Expression
# (used as a workaround for locked-down execution policies), so fall back
# to an env var the launcher sets, then to cwd.
$ScriptRoot =
    if ($PSScriptRoot) { $PSScriptRoot }
    elseif ($env:REGION_SCREENSHOT_ROOT) { $env:REGION_SCREENSHOT_ROOT }
    else { (Get-Location).Path }

# $env:REGION_SCREENSHOT_ROOT may be a non-normalized literal path (e.g.
# "...\bat\..\ps1") rather than a clean absolute one - Split-Path is pure
# string parsing and won't collapse ".." segments the way the filesystem
# does, so resolve to a real path first or $ProjectRoot below ends up
# pointing at the wrong folder.
if (Test-Path -LiteralPath $ScriptRoot) {
    $ScriptRoot = (Resolve-Path -LiteralPath $ScriptRoot).ProviderPath
}

# The project root is one level up from the ps1\ folder (i.e. the folder
# that contains ps1\, bat\, and Start_All.bat). Screenshots and stitched
# output default to subfolders of this, not of ps1\, so they land next to
# the launchers instead of inside the scripts folder.
$ProjectRoot = Split-Path -Path $ScriptRoot -Parent
if (-not $ProjectRoot) { $ProjectRoot = $ScriptRoot }

$ConfigPath = Join-Path -Path $ScriptRoot -ChildPath 'config.json'

# ---------------------------------------------------------------------------
# Logging - every run always writes a timestamped log file to Logs\ next to
# ps1\, regardless of whether anything goes wrong, so past sessions can be
# reviewed after the fact. Same Logs\ folder every tool in the pipeline
# (Configure.ps1, PSImgStitcher.ps1, Start-ReviewWebServer.ps1) writes to.
# ---------------------------------------------------------------------------
$LogDir = Join-Path -Path $ProjectRoot -ChildPath 'Logs'
New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue | Out-Null
$script:LogPath = Join-Path -Path $LogDir -ChildPath ("RegionScreenshot_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
}

# Catches anything that would otherwise crash the tool silently (or with
# just an unhandled-exception dialog) without a record of what happened.
trap {
    Write-Log "FATAL: $($_.Exception.Message)"
    Write-Log $_.ScriptStackTrace
    continue
}

Write-Log "RegionScreenshot started. ProjectRoot=$ProjectRoot  ConfigPath=$ConfigPath"

# Built-in defaults, used for any setting missing from config.json.
# VK codes: Ctrl=17, Shift=16, S=83, Q=81.
$script:DefaultConfig = [ordered]@{
    HotkeyName                 = 'Ctrl + Shift + S'
    HotkeyVKCodes              = @(17, 16, 83)   # Ctrl+Shift+S
    ClipboardHotkeyName         = 'Ctrl + Shift + Alt + S'
    ClipboardHotkeyVKCodes      = @(17, 16, 18, 83) # Ctrl+Shift+Alt+S
    StopHotkeyName              = 'Ctrl + Shift + Q'
    StopHotkeyVKCodes           = @(17, 16, 81)   # Ctrl+Shift+Q
    ToggleBorderHotkeyName      = 'Ctrl + Shift + H'
    ToggleBorderHotkeyVKCodes   = @(17, 16, 72)   # Ctrl+Shift+H
    ToggleAutoCaptureHotkeyName    = 'Ctrl + Shift + A'
    ToggleAutoCaptureHotkeyVKCodes = @(17, 16, 65)   # Ctrl+Shift+A
    MoveModifierName            = 'Ctrl + Alt'
    MoveModifierVKCodes         = @(17, 18)       # Ctrl+Alt + arrow key
    ResizeModifierName          = 'Ctrl + Alt + Shift'
    ResizeModifierVKCodes       = @(17, 18, 16)   # Ctrl+Alt+Shift + arrow key
    MoveResizeStepPixels        = 10
    FineStepPixels               = 1     # applied on a quick tap; hold to repeat at MoveResizeStepPixels
    LastRegionX                  = 0
    LastRegionY                  = 0
    LastRegionWidth              = 0     # 0 = no remembered region yet
    LastRegionHeight             = 0
    SaveLocation                = (Join-Path -Path $ProjectRoot -ChildPath 'screenshots')
    FileNameScheme              = 'screenshot_{timestamp}'
    AutoCaptureIntervalMs      = 1000   # minimum 500
    AutoCaptureAutoStart       = $false
    AutoCaptureUseSessionFolders   = $true
    AutoCaptureSessionFolderScheme = 'Session_{date}_{time}'
    AutoActionKeyName          = 'F8'
    AutoActionVKCodes          = @(119)   # F8
    AutoActionTiming           = 'After'   # 'Before' or 'After' the screenshot
    AutoActionDelayMs          = 100
    AutoLaunchReviewOnStop      = $true
    AutoCaptureDuplicateDetectionEnabled = $true
    AutoCaptureDuplicateThresholdPercent = 99.0   # pause + prompt when a shot is at least this similar to the previous one
    AutoCaptureDuplicateCooldownMs = 5000   # after clicking Continue on the prompt, don't re-check for duplicates again until this much time has passed - prevents getting asked on every single tick while the captured content still hasn't changed
    AutoCaptureDuplicatePromptArmDelayMs = 700   # the prompt's Stop/Continue buttons stay disabled for this long after it appears, so a click or key release already in flight when it pops up can't land on either one
}

function Get-ToolConfig {
    <#
        Reads config.json (if present) and merges it over the defaults, so
        a partial/older config file still works. Returns a hashtable.
    #>
    $cfg = [ordered]@{}
    foreach ($key in $script:DefaultConfig.Keys) { $cfg[$key] = $script:DefaultConfig[$key] }

    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $loaded = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            foreach ($prop in $loaded.PSObject.Properties) {
                if ($cfg.Contains($prop.Name)) {
                    $cfg[$prop.Name] = $prop.Value
                }
            }

            # Migrate configs saved by an older version of this tool, which
            # stored a single "HotkeyVKCode" instead of a "HotkeyVKCodes" array.
            if (-not ($loaded.PSObject.Properties.Name -contains 'HotkeyVKCodes') -and
                ($loaded.PSObject.Properties.Name -contains 'HotkeyVKCode')) {
                $cfg.HotkeyVKCodes = @([int]$loaded.HotkeyVKCode)
            }
        }
        catch {
            Write-Log "ERROR: config.json could not be read, using defaults instead: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show(
                "config.json could not be read (using defaults instead):`n$($_.Exception.Message)",
                'Region Screenshot Tool', 'OK', 'Warning'
            ) | Out-Null
        }
    }

    # Normalize HotkeyVKCodes / StopHotkeyVKCodes to plain int arrays. JSON
    # numbers can come back as Int64/Double, and a single-element array can
    # collapse to a bare scalar when it round-trips through JSON/PSObject
    # conversion.
    $codes = @($cfg.HotkeyVKCodes) | ForEach-Object { [int]$_ }
    if (-not $codes -or $codes.Count -eq 0) { $codes = @(17, 16, 83) }
    $cfg.HotkeyVKCodes = $codes

    $clipboardCodes = @($cfg.ClipboardHotkeyVKCodes) | ForEach-Object { [int]$_ }
    if (-not $clipboardCodes -or $clipboardCodes.Count -eq 0) { $clipboardCodes = @(17, 16, 18, 83) }
    $cfg.ClipboardHotkeyVKCodes = $clipboardCodes
    if ([string]::IsNullOrWhiteSpace([string]$cfg.ClipboardHotkeyName)) { $cfg.ClipboardHotkeyName = 'Ctrl + Shift + Alt + S' }

    $stopCodes = @($cfg.StopHotkeyVKCodes) | ForEach-Object { [int]$_ }
    if (-not $stopCodes -or $stopCodes.Count -eq 0) { $stopCodes = @(17, 16, 81) }
    $cfg.StopHotkeyVKCodes = $stopCodes
    if ([string]::IsNullOrWhiteSpace([string]$cfg.StopHotkeyName)) { $cfg.StopHotkeyName = 'Ctrl + Shift + Q' }

    $toggleBorderCodes = @($cfg.ToggleBorderHotkeyVKCodes) | ForEach-Object { [int]$_ }
    if (-not $toggleBorderCodes -or $toggleBorderCodes.Count -eq 0) { $toggleBorderCodes = @(17, 16, 72) }
    $cfg.ToggleBorderHotkeyVKCodes = $toggleBorderCodes
    if ([string]::IsNullOrWhiteSpace([string]$cfg.ToggleBorderHotkeyName)) { $cfg.ToggleBorderHotkeyName = 'Ctrl + Shift + H' }

    $toggleAutoCaptureCodes = @($cfg.ToggleAutoCaptureHotkeyVKCodes) | ForEach-Object { [int]$_ }
    if (-not $toggleAutoCaptureCodes -or $toggleAutoCaptureCodes.Count -eq 0) { $toggleAutoCaptureCodes = @(17, 16, 65) }
    $cfg.ToggleAutoCaptureHotkeyVKCodes = $toggleAutoCaptureCodes
    if ([string]::IsNullOrWhiteSpace([string]$cfg.ToggleAutoCaptureHotkeyName)) { $cfg.ToggleAutoCaptureHotkeyName = 'Ctrl + Shift + A' }

    $moveModCodes = @($cfg.MoveModifierVKCodes) | ForEach-Object { [int]$_ }
    if (-not $moveModCodes -or $moveModCodes.Count -eq 0) { $moveModCodes = @(17, 18) }
    $cfg.MoveModifierVKCodes = $moveModCodes
    if ([string]::IsNullOrWhiteSpace([string]$cfg.MoveModifierName)) { $cfg.MoveModifierName = 'Ctrl + Alt' }

    $resizeModCodes = @($cfg.ResizeModifierVKCodes) | ForEach-Object { [int]$_ }
    if (-not $resizeModCodes -or $resizeModCodes.Count -eq 0) { $resizeModCodes = @(17, 18, 16) }
    $cfg.ResizeModifierVKCodes = $resizeModCodes
    if ([string]::IsNullOrWhiteSpace([string]$cfg.ResizeModifierName)) { $cfg.ResizeModifierName = 'Ctrl + Alt + Shift' }

    $moveResizeStep = 0
    [void][int]::TryParse([string]$cfg.MoveResizeStepPixels, [ref]$moveResizeStep)
    if ($moveResizeStep -lt 1) { $moveResizeStep = 10 }
    $cfg.MoveResizeStepPixels = $moveResizeStep

    $fineStep = 0
    [void][int]::TryParse([string]$cfg.FineStepPixels, [ref]$fineStep)
    if ($fineStep -lt 1) { $fineStep = 1 }
    $cfg.FineStepPixels = $fineStep

    foreach ($key in @('LastRegionX', 'LastRegionY', 'LastRegionWidth', 'LastRegionHeight')) {
        $v = 0
        [void][int]::TryParse([string]$cfg[$key], [ref]$v)
        $cfg[$key] = $v
    }

    # SaveLocation may be relative (e.g. "screenshots" or ".\MyShots") -
    # resolve it against the project root (one level up from ps1\) so it
    # works no matter where the tool is launched from, and lands next to
    # Start_All.bat rather than inside the ps1\ scripts folder.
    if (-not [System.IO.Path]::IsPathRooted($cfg.SaveLocation)) {
        $cfg.SaveLocation = Join-Path -Path $ProjectRoot -ChildPath $cfg.SaveLocation
    }

    $intervalMs = 0
    [void][int]::TryParse([string]$cfg.AutoCaptureIntervalMs, [ref]$intervalMs)
    if ($intervalMs -le 0 -and $loaded -and
        ($loaded.PSObject.Properties.Name -contains 'AutoCaptureIntervalSeconds') -and
        -not ($loaded.PSObject.Properties.Name -contains 'AutoCaptureIntervalMs')) {
        # Migrate a config saved by an older version of this tool, which
        # stored the interval in whole seconds instead of milliseconds.
        $oldSeconds = 0
        [void][int]::TryParse([string]$loaded.AutoCaptureIntervalSeconds, [ref]$oldSeconds)
        if ($oldSeconds -gt 0) { $intervalMs = $oldSeconds * 1000 }
    }
    if ($intervalMs -le 0) { $intervalMs = 1000 }
    if ($intervalMs -lt 500) { $intervalMs = 500 }
    $cfg.AutoCaptureIntervalMs = $intervalMs
    $cfg.AutoCaptureAutoStart = [bool]$cfg.AutoCaptureAutoStart
    $cfg.AutoCaptureUseSessionFolders = [bool]$cfg.AutoCaptureUseSessionFolders
    if ([string]::IsNullOrWhiteSpace([string]$cfg.AutoCaptureSessionFolderScheme)) {
        $cfg.AutoCaptureSessionFolderScheme = 'Session_{date}_{time}'
    }
    $cfg.AutoLaunchReviewOnStop = [bool]$cfg.AutoLaunchReviewOnStop

    $cfg.AutoActionVKCodes = @($cfg.AutoActionVKCodes) | ForEach-Object { [int]$_ }
    if ([string]::IsNullOrWhiteSpace([string]$cfg.AutoActionKeyName)) { $cfg.AutoActionKeyName = '' }

    # Migrate configs saved by an older version of this tool, which had a
    # separate enabled flag plus independent before/after delays instead of
    # a single timing choice + delay.
    if ($loaded -and ($loaded.PSObject.Properties.Name -contains 'AutoActionEnabled')) {
        if (-not [bool]$loaded.AutoActionEnabled) {
            $cfg.AutoActionVKCodes = @()
        }
        $oldBefore = 0; [void][int]::TryParse([string]$loaded.AutoActionDelayBeforeMs, [ref]$oldBefore)
        $oldAfter  = 0; [void][int]::TryParse([string]$loaded.AutoActionDelayAfterMs, [ref]$oldAfter)
        $cfg.AutoActionTiming  = 'Before'
        $cfg.AutoActionDelayMs = $oldBefore + $oldAfter
    }

    if ($cfg.AutoActionTiming -ne 'After') { $cfg.AutoActionTiming = 'Before' }
    $actionDelay = 0
    [void][int]::TryParse([string]$cfg.AutoActionDelayMs, [ref]$actionDelay)
    if ($actionDelay -lt 0) { $actionDelay = 0 }
    $cfg.AutoActionDelayMs = $actionDelay

    $cfg.AutoCaptureDuplicateDetectionEnabled = [bool]$cfg.AutoCaptureDuplicateDetectionEnabled
    $dupThreshold = 0.0
    [void][double]::TryParse([string]$cfg.AutoCaptureDuplicateThresholdPercent, [ref]$dupThreshold)
    if ($dupThreshold -le 0) { $dupThreshold = 99.0 }
    if ($dupThreshold -gt 100) { $dupThreshold = 100.0 }
    $cfg.AutoCaptureDuplicateThresholdPercent = $dupThreshold

    $dupCooldown = 0
    [void][int]::TryParse([string]$cfg.AutoCaptureDuplicateCooldownMs, [ref]$dupCooldown)
    if ($dupCooldown -lt 0) { $dupCooldown = 5000 }
    $cfg.AutoCaptureDuplicateCooldownMs = $dupCooldown

    $dupArmDelay = 0
    [void][int]::TryParse([string]$cfg.AutoCaptureDuplicatePromptArmDelayMs, [ref]$dupArmDelay)
    if ($dupArmDelay -lt 0) { $dupArmDelay = 700 }
    $cfg.AutoCaptureDuplicatePromptArmDelayMs = $dupArmDelay

    return $cfg
}

function Set-TrayText([string]$text) {
    # NotifyIcon.Text throws if the string is 64+ characters. Truncate
    # defensively so a long hotkey name (or anything else) can never
    # crash the tool.
    if ($text.Length -gt 63) {
        $text = $text.Substring(0, 60) + '...'
    }
    $trayIcon.Text = $text
}

function Apply-Config {
    $script:Config = Get-ToolConfig
    if ($NoAutoReview) {
        # -NoAutoReview overrides whatever config.json says, on every load
        # (including "Reload Config" from the tray menu) - not just at
        # startup - so it can't be silently undone by a reload.
        $script:Config.AutoLaunchReviewOnStop = $false
    }
    if (-not (Test-Path -LiteralPath $script:Config.SaveLocation)) {
        New-Item -ItemType Directory -Path $script:Config.SaveLocation -Force | Out-Null
    }
    if ($trayIcon) {
        Set-TrayText "Region Screenshot Tool ($($script:Config.HotkeyName) capture / $($script:Config.StopHotkeyName) stop)"
    }
}

# ---------------------------------------------------------------------------
# Region selection overlay
# ---------------------------------------------------------------------------
function Select-Region {
    <#
        Shows a semi-transparent full-virtual-screen overlay. Drag with the
        left mouse button to draw a rectangle. Release to confirm, or press
        Esc to cancel. Returns a System.Drawing.Rectangle, or $null if
        cancelled.
    #>

    $virtualScreen = [System.Windows.Forms.SystemInformation]::VirtualScreen

    $form = New-Object System.Windows.Forms.Form
    $form.StartPosition   = 'Manual'
    $form.Location        = New-Object System.Drawing.Point($virtualScreen.X, $virtualScreen.Y)
    $form.Size            = New-Object System.Drawing.Size($virtualScreen.Width, $virtualScreen.Height)
    $form.FormBorderStyle = 'None'
    $form.TopMost         = $true
    $form.BackColor       = [System.Drawing.Color]::Black
    $form.Opacity         = 0.35
    $form.Cursor          = [System.Windows.Forms.Cursors]::Cross
    $form.ShowInTaskbar   = $false
    $form.KeyPreview      = $true

    $script:dragging   = $false
    $script:startPoint = New-Object System.Drawing.Point 0, 0
    $script:currentRect = New-Object System.Drawing.Rectangle 0, 0, 0, 0
    $script:selectionResult = $null

    $form.Add_MouseDown({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $script:dragging   = $true
            $script:startPoint = $e.Location
        }
    })

    $form.Add_MouseMove({
        param($s, $e)
        if ($script:dragging) {
            $x = [Math]::Min($script:startPoint.X, $e.X)
            $y = [Math]::Min($script:startPoint.Y, $e.Y)
            $w = [Math]::Abs($e.X - $script:startPoint.X)
            $h = [Math]::Abs($e.Y - $script:startPoint.Y)
            $script:currentRect = New-Object System.Drawing.Rectangle $x, $y, $w, $h
            $form.Invalidate()
        }
    })

    $form.Add_MouseUp({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left -and $script:dragging) {
            $script:dragging = $false
            if ($script:currentRect.Width -gt 2 -and $script:currentRect.Height -gt 2) {
                # Convert from form-local coords to virtual-screen coords
                $script:selectionResult = New-Object System.Drawing.Rectangle (
                    $script:currentRect.X + $virtualScreen.X),
                    ($script:currentRect.Y + $virtualScreen.Y),
                    ($script:currentRect.Width),
                    ($script:currentRect.Height)
            }
            $form.Close()
        }
    })

    $form.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $script:selectionResult = $null
            $form.Close()
        }
    })

    $form.Add_Paint({
        param($s, $e)
        if ($script:currentRect.Width -gt 0 -and $script:currentRect.Height -gt 0) {
            $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Red), 2
            $e.Graphics.DrawRectangle($pen, $script:currentRect)
            $pen.Dispose()
        }
    })

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text      = 'Drag to select the capture region.  Esc to cancel.'
    $hint.ForeColor = [System.Drawing.Color]::White
    $hint.BackColor = [System.Drawing.Color]::Black
    $hint.AutoSize  = $true
    $hint.Location  = New-Object System.Drawing.Point 20, 20
    $form.Controls.Add($hint)

    [void]$form.ShowDialog()
    $form.Dispose()

    return $script:selectionResult
}

# ---------------------------------------------------------------------------
# Filename scheme expansion
# ---------------------------------------------------------------------------
# Persisted across runs so {counter} keeps incrementing instead of resetting.
function Get-NextCounter {
    $counterFile = Join-Path -Path $script:Config.SaveLocation -ChildPath '.counter'
    $n = 0
    if (Test-Path -LiteralPath $counterFile) {
        $raw = Get-Content -LiteralPath $counterFile -Raw -ErrorAction SilentlyContinue
        [void][int]::TryParse(($raw -replace '\D',''), [ref]$n)
    }
    $n++
    Set-Content -LiteralPath $counterFile -Value $n -NoNewline
    return $n
}

function Expand-FileNameScheme {
    param([string]$Scheme)

    $now = Get-Date
    $result = $Scheme
    $result = $result -replace '\{timestamp\}', $now.ToString('yyyyMMdd_HHmmss_fff')
    $result = $result -replace '\{date\}',      $now.ToString('yyyyMMdd')
    $result = $result -replace '\{time\}',      $now.ToString('HHmmss')

    if ($result -match '\{counter(:(\d+))?\}') {
        $pad = if ($Matches[2]) { [int]$Matches[2] } else { 4 }
        $counterValue = (Get-NextCounter).ToString().PadLeft($pad, '0')
        $result = $result -replace '\{counter(:(\d+))?\}', $counterValue
    }

    # Strip characters that are illegal in Windows filenames.
    $invalid = [Regex]::Escape([string][System.IO.Path]::GetInvalidFileNameChars())
    $result = $result -replace "[$invalid]", '_'

    # Always end in .png, regardless of what the user typed.
    $result = $result -replace '(?i)\.png$', ''
    return "$result.png"
}

function New-AutoCaptureSessionFolderName {
    <#
        Expands AutoCaptureSessionFolderScheme (e.g. "Session_{date}_{time}")
        into a folder name for a single auto-capture run. Unlike
        Expand-FileNameScheme this has no {counter} support and doesn't
        force a .png extension - it's a folder name, not a filename.
    #>
    $now = Get-Date
    $result = $script:Config.AutoCaptureSessionFolderScheme
    $result = $result -replace '\{timestamp\}', $now.ToString('yyyyMMdd_HHmmss')
    $result = $result -replace '\{date\}',      $now.ToString('yyyyMMdd')
    $result = $result -replace '\{time\}',      $now.ToString('HHmmss')

    $invalid = [Regex]::Escape([string][System.IO.Path]::GetInvalidFileNameChars())
    $result = $result -replace "[$invalid]", '_'

    if ([string]::IsNullOrWhiteSpace($result)) {
        $result = "Session_$($now.ToString('yyyyMMdd_HHmmss'))"
    }
    return $result
}

# ---------------------------------------------------------------------------
# Screenshot capture
# ---------------------------------------------------------------------------
function Save-RegionScreenshot {
    param(
        [Parameter(Mandatory)]
        [System.Drawing.Rectangle]$Rect,

        # Where to save this shot. Defaults to the configured save location;
        # auto-capture passes the current session subfolder instead (see
        # Start-AutoCapture) so each auto-capture run's screenshots land
        # together, ready to hand off to the Review & Stitch tool.
        [string]$Folder = $script:Config.SaveLocation
    )

    # THE VERY FIRST THING checked, independent of whatever called this:
    # if the stop flag is 1, NOTHING captures, full stop. This doesn't
    # rely on whichever caller (auto-capture tick, manual hotkey, clipboard
    # hotkey, anything else) remembering to check first - it's enforced
    # right here too, the one place every capture path funnels through, so
    # a file can never hit disk while acStopFlag is 1.
    if ($script:acStopFlag -eq 1) {
        Write-Log 'Capture blocked: stop flag is 1 (duplicate-frame prompt is open).'
        return $null
    }

    # Make sure any flash from a previous capture is fully gone before we
    # read pixels off the screen, or a rapid second/third capture would
    # end up with the white flash baked into the image.
    Hide-CaptureFlash

    # Also hide the region border for the duration of the capture (even
    # though it's drawn just outside the rectangle, not over it) so there's
    # no chance of it bleeding into the saved image, then restore whatever
    # visibility state the user had it in afterwards.
    $wasBorderShown = [bool]$script:borderForm
    Remove-RegionBorder

    if (-not (Test-Path -LiteralPath $Folder)) {
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    }

    $bmp = New-Object System.Drawing.Bitmap $Rect.Width, $Rect.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $graphics.CopyFromScreen($Rect.Location, [System.Drawing.Point]::Empty, $Rect.Size)
        $fileName = Expand-FileNameScheme -Scheme $script:Config.FileNameScheme
        $path = Join-Path -Path $Folder -ChildPath $fileName
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Log "Captured screenshot -> $path ($($Rect.Width)x$($Rect.Height))"
        return $path
    }
    catch {
        Write-Log "ERROR: capture failed: $($_.Exception.Message)"
        throw
    }
    finally {
        $graphics.Dispose()
        $bmp.Dispose()
        if ($wasBorderShown) { Sync-RegionBorder }
    }
}

function Copy-RegionScreenshotToClipboard {
    <#
        Same capture as Save-RegionScreenshot, but copies the image straight
        to the clipboard instead of writing anything to disk.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Drawing.Rectangle]$Rect
    )

    Hide-CaptureFlash

    $wasBorderShown = [bool]$script:borderForm
    Remove-RegionBorder

    $bmp = New-Object System.Drawing.Bitmap $Rect.Width, $Rect.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $graphics.CopyFromScreen($Rect.Location, [System.Drawing.Point]::Empty, $Rect.Size)
        [System.Windows.Forms.Clipboard]::SetImage($bmp)
        Write-Log "Captured screenshot -> clipboard ($($Rect.Width)x$($Rect.Height))"
    }
    catch {
        Write-Log "ERROR: clipboard capture failed: $($_.Exception.Message)"
        throw
    }
    finally {
        $graphics.Dispose()
        $bmp.Dispose()
        if ($wasBorderShown) { Sync-RegionBorder }
    }
}

# ---------------------------------------------------------------------------
# Region border - a persistent red outline drawn just outside the current
# capture region, so it's obvious at a glance where captures will come
# from. It's click-through and never takes keyboard focus, so it doesn't
# interfere with whatever you're doing in other apps. Toggle it on or off
# any time with the toggle-border hotkey (default Ctrl+Shift+H) or from the
# tray menu; it starts out visible.
# ---------------------------------------------------------------------------
$script:borderForm    = $null
$script:borderVisible = $true

function Remove-RegionBorder {
    <#
        Immediately removes the border overlay window, if one is showing.
        Safe to call even when there isn't one.
    #>
    if ($script:borderForm) {
        $script:borderForm.Hide()
        $script:borderForm.Dispose()
        $script:borderForm = $null
    }
}

function Sync-RegionBorder {
    <#
        (Re)draws the border overlay around the current capture rectangle,
        according to $script:borderVisible. Call this after selecting or
        reselecting a region, after toggling visibility, or any other time
        the on-screen border needs to catch up with current state.
    #>
    Remove-RegionBorder
    if (-not $script:borderVisible) { return }
    if (-not $script:captureRect) { return }

    $thickness = 3
    $script:borderForm                 = New-Object RegionTool.BorderForm
    $script:borderForm.BorderThickness = $thickness
    $script:borderForm.BorderLineColor = [System.Drawing.Color]::Red
    $script:borderForm.StartPosition   = 'Manual'
    $script:borderForm.FormBorderStyle = 'None'
    $script:borderForm.ShowInTaskbar   = $false
    $script:borderForm.TopMost         = $true
    # Fill color is only ever used as the transparency key, so any color
    # works here as long as nothing else in the border is drawn in it.
    $script:borderForm.BackColor       = [System.Drawing.Color]::FromArgb(1, 1, 1)
    $script:borderForm.TransparencyKey = $script:borderForm.BackColor
    $script:borderForm.Location = New-Object System.Drawing.Point(
        ($script:captureRect.X - $thickness), ($script:captureRect.Y - $thickness))
    $script:borderForm.Size = New-Object System.Drawing.Size(
        ($script:captureRect.Width + $thickness * 2), ($script:captureRect.Height + $thickness * 2))
    $script:borderForm.Show()
}

function Set-RegionBorderVisible([bool]$Visible) {
    $script:borderVisible = $Visible
    Sync-RegionBorder
}

function Toggle-RegionBorder {
    <#
        Flips border visibility and redraws it accordingly. Returns the new
        visibility state (so callers can update tray menu text etc.).
    #>
    Set-RegionBorderVisible (-not $script:borderVisible)
    return $script:borderVisible
}

# ---------------------------------------------------------------------------
# Move / resize the capture region from the keyboard - lets you nudge or
# resize the region without redrawing it from scratch. Triggered from the
# hotkey poller below: hold the move-region modifier (default Ctrl+Alt)
# plus an arrow key to shift the region, or the resize-region modifier
# (default Ctrl+Alt+Shift) plus an arrow key to grow/shrink it. Both
# modifiers and the pixel step are configurable in config.json.
# ---------------------------------------------------------------------------
function Move-CaptureRegion {
    param([int]$DeltaX = 0, [int]$DeltaY = 0)
    if (-not $script:captureRect) { return }
    $r = $script:captureRect
    $script:captureRect = New-Object System.Drawing.Rectangle(
        ($r.X + $DeltaX), ($r.Y + $DeltaY), $r.Width, $r.Height)
    Sync-RegionBorder
}

function Resize-CaptureRegion {
    param([int]$DeltaWidth = 0, [int]$DeltaHeight = 0)
    if (-not $script:captureRect) { return }
    $r = $script:captureRect
    # Keep a sane minimum size so the region can never collapse to nothing.
    $newWidth  = [Math]::Max(10, $r.Width + $DeltaWidth)
    $newHeight = [Math]::Max(10, $r.Height + $DeltaHeight)
    $script:captureRect = New-Object System.Drawing.Rectangle $r.X, $r.Y, $newWidth, $newHeight
    Sync-RegionBorder
}

function Save-LastRegion {
    <#
        Persists the current capture rectangle into config.json as
        LastRegionX/Y/Width/Height, so next launch can offer to reuse it
        instead of forcing a fresh drag-select every time. Reads the file
        fresh and only touches those four properties, so it never clobbers
        settings saved by Configure.ps1 (or hand-edited) in the meantime.
    #>
    param([System.Drawing.Rectangle]$Rect)
    if (-not $Rect -or $Rect.Width -lt 10 -or $Rect.Height -lt 10) { return }
    try {
        $existing = if (Test-Path -LiteralPath $ConfigPath) {
            Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        } else {
            [PSCustomObject]@{}
        }
        $existing | Add-Member -MemberType NoteProperty -Name 'LastRegionX'      -Value $Rect.X      -Force
        $existing | Add-Member -MemberType NoteProperty -Name 'LastRegionY'      -Value $Rect.Y      -Force
        $existing | Add-Member -MemberType NoteProperty -Name 'LastRegionWidth'  -Value $Rect.Width  -Force
        $existing | Add-Member -MemberType NoteProperty -Name 'LastRegionHeight' -Value $Rect.Height -Force
        $existing | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
        $script:Config.LastRegionX      = $Rect.X
        $script:Config.LastRegionY      = $Rect.Y
        $script:Config.LastRegionWidth  = $Rect.Width
        $script:Config.LastRegionHeight = $Rect.Height
    }
    catch {
        Write-Warning "Could not save last region to config.json: $_"
        Write-Log "ERROR: could not save last region to config.json: $_"
    }
}

function Get-ClampedLastRegion {
    <#
        Rebuilds a Rectangle from the saved LastRegion* config values, and
        clamps it to fit the current virtual screen - the saved region may
        have come from a since-changed monitor layout (a disconnected
        second monitor, a resolution change), so it's re-fit rather than
        trusted verbatim. Returns $null if nothing usable was saved yet.
    #>
    param($Config)
    $w = [int]$Config.LastRegionWidth
    $h = [int]$Config.LastRegionHeight
    if ($w -lt 10 -or $h -lt 10) { return $null }

    $x = [int]$Config.LastRegionX
    $y = [int]$Config.LastRegionY

    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $w = [Math]::Min($w, $vs.Width)
    $h = [Math]::Min($h, $vs.Height)
    $x = [Math]::Max($vs.X, [Math]::Min($x, $vs.X + $vs.Width  - $w))
    $y = [Math]::Max($vs.Y, [Math]::Min($y, $vs.Y + $vs.Height - $h))

    return New-Object System.Drawing.Rectangle $x, $y, $w, $h
}

# ---------------------------------------------------------------------------
# Capture flash - a brief white flash over the captured rectangle so it's
# obvious a screenshot was just taken. Uses a non-activating window so it
# never steals keyboard/mouse focus from whatever app you're using.
# ---------------------------------------------------------------------------
$script:flashForm  = $null
$script:flashTimer = $null

function Hide-CaptureFlash {
    <#
        Immediately removes any in-progress flash window from the screen.
        Must be called (and allowed to actually take effect) before taking
        a screenshot - otherwise a capture fired while the previous flash
        is still fading out ends up including the flash itself.
    #>
    if ($script:flashTimer) {
        $script:flashTimer.Stop()
        $script:flashTimer.Dispose()
        $script:flashTimer = $null
    }
    if ($script:flashForm) {
        $script:flashForm.Hide()
        $script:flashForm.Dispose()
        $script:flashForm = $null

        # Give Windows a chance to actually repaint the area the flash was
        # covering before we read pixels back with CopyFromScreen. Hiding a
        # layered/topmost window is not always reflected on screen within
        # the same tick, so pump the message loop and yield briefly.
        [System.Windows.Forms.Application]::DoEvents()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 15
    }
}

function Show-CaptureFlash {
    param([System.Drawing.Rectangle]$Rect)

    # Cancel any flash already in progress before starting a new one.
    Hide-CaptureFlash

    $script:flashForm = New-Object RegionTool.FlashForm
    $script:flashForm.StartPosition   = 'Manual'
    $script:flashForm.FormBorderStyle = 'None'
    $script:flashForm.ShowInTaskbar   = $false
    $script:flashForm.TopMost         = $true
    $script:flashForm.BackColor       = [System.Drawing.Color]::White
    $script:flashForm.Location        = New-Object System.Drawing.Point($Rect.X, $Rect.Y)
    $script:flashForm.Size            = New-Object System.Drawing.Size([Math]::Max($Rect.Width, 1), [Math]::Max($Rect.Height, 1))
    $script:flashForm.Opacity         = 0.65
    $script:flashForm.Show()

    $script:flashTimer = New-Object System.Windows.Forms.Timer
    $script:flashTimer.Interval = 20
    $script:flashTimer.Add_Tick({
        if (-not $script:flashForm) {
            $script:flashTimer.Stop()
            return
        }
        $script:flashForm.Opacity -= 0.2
        if ($script:flashForm.Opacity -le 0) {
            $script:flashTimer.Stop()
            $script:flashTimer.Dispose()
            $script:flashTimer = $null
            $script:flashForm.Close()
            $script:flashForm.Dispose()
            $script:flashForm = $null
        }
    })
    $script:flashTimer.Start()
}

# ---------------------------------------------------------------------------
# Load config, then do initial region selection
# ---------------------------------------------------------------------------
Apply-Config

$lastRegion = Get-ClampedLastRegion -Config $script:Config
if ($lastRegion) {
    $msg = "Use the last capture region?`n`n$($lastRegion.Width) x $($lastRegion.Height) at ($($lastRegion.X), $($lastRegion.Y))`n`nYes = keep it as the starting point`nNo = pick a new region"
    $keep = [System.Windows.Forms.MessageBox]::Show($msg, 'Region Screenshot Tool', 'YesNo', 'Question')
    $captureRect = if ($keep -eq [System.Windows.Forms.DialogResult]::Yes) { $lastRegion } else { Select-Region }
}
else {
    $captureRect = Select-Region
}

if (-not $captureRect) {
    [System.Windows.Forms.MessageBox]::Show(
        'No region selected. Exiting.', 'Region Screenshot Tool'
    ) | Out-Null
    exit
}
$script:captureRect = $captureRect
Sync-RegionBorder
Save-LastRegion -Rect $captureRect

# ---------------------------------------------------------------------------
# Tray icon + menu
# ---------------------------------------------------------------------------
$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Icon    = [System.Drawing.SystemIcons]::Camera
$trayIcon.Visible = $true
Set-TrayText "Region Screenshot Tool ($($Config.HotkeyName) capture / $($Config.StopHotkeyName) stop)"

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$itemReselect     = $menu.Items.Add('Reselect Region')
$itemToggleBorder = $menu.Items.Add('Hide Region Border')
$itemOpenDir      = $menu.Items.Add('Open Screenshots Folder')
[void]$menu.Items.Add('-')
$itemAutoCapture  = $menu.Items.Add('Start Auto-Capture')
$itemReviewLast   = $menu.Items.Add('Review Last Session...')
$itemReviewLast.Enabled = $false
$itemReviewOpen   = $menu.Items.Add('Review & Stitch...')
$itemReload       = $menu.Items.Add('Reload Config')
[void]$menu.Items.Add('-')
$itemExit         = $menu.Items.Add('Exit')

$trayIcon.ContextMenuStrip = $menu

$itemReselect.Add_Click({
    if ($script:acStopFlag -eq 1) { return }
    $newRect = Select-Region
    if ($newRect) {
        $script:captureRect = $newRect
        Sync-RegionBorder
        Save-LastRegion -Rect $newRect
        $trayIcon.ShowBalloonTip(1500, 'Region Screenshot Tool', 'Capture region updated.', [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

$itemToggleBorder.Add_Click({
    if ($script:acStopFlag -eq 1) { return }
    $visible = Toggle-RegionBorder
    $itemToggleBorder.Text = if ($visible) { 'Hide Region Border' } else { 'Show Region Border' }
})

$itemOpenDir.Add_Click({
    if ($script:acStopFlag -eq 1) { return }
    Start-Process explorer.exe $script:Config.SaveLocation
})

$itemReviewLast.Add_Click({
    if ($script:acStopFlag -eq 1) { return }
    if ($script:lastSessionFolder) { Start-ReviewTool -SourceFolder $script:lastSessionFolder }
})

$itemReviewOpen.Add_Click({
    if ($script:acStopFlag -eq 1) { return }
    Start-ReviewTool -SourceFolder $script:Config.SaveLocation
})

function Send-KeyCombo {
    <#
        Simulates pressing (and releasing) a combo of up to 4 keys, via
        keybd_event - a low-level input simulation that goes to whichever
        window currently has focus, exactly like a real key press would.
        Keys are pressed down in order and released in reverse order, so a
        combo like Ctrl+F8 holds Ctrl first and releases it last. Each key
        is sent with its real hardware scan code (via MapVirtualKey), not
        just a bare virtual-key code - some apps (browsers included)
        ignore synthetic key events that don't carry one.
    #>
    param([int[]]$Codes)
    if (-not $Codes -or $Codes.Count -eq 0) { return }
    if ($script:acStopFlag -eq 1) {
        Write-Log 'Auto-action key send blocked: stop flag is 1 (duplicate-frame prompt is open).'
        return
    }
    $MAPVK_VK_TO_VSC = 0
    $KEYEVENTF_KEYUP = 0x0002
    foreach ($vk in $Codes) {
        $scan = [RegionTool.Native]::MapVirtualKey([uint32]$vk, $MAPVK_VK_TO_VSC)
        [RegionTool.Native]::keybd_event([byte]$vk, [byte]$scan, 0, [UIntPtr]::Zero)
    }
    Start-Sleep -Milliseconds 20
    for ($i = $Codes.Count - 1; $i -ge 0; $i--) {
        $vk = $Codes[$i]
        $scan = [RegionTool.Native]::MapVirtualKey([uint32]$vk, $MAPVK_VK_TO_VSC)
        [RegionTool.Native]::keybd_event([byte]$vk, [byte]$scan, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
    }
}

# ---------------------------------------------------------------------------
# Duplicate-frame pause: when auto-capture is running, each new shot is
# compared against the previous one. If they're at least
# AutoCaptureDuplicateThresholdPercent similar, auto-capture (and any
# configured auto-keypress) pauses and the user is asked whether to stop or
# keep going - useful for noticing when whatever's being captured has
# stalled (e.g. a page finished loading, or a game froze) instead of
# quietly filling a session folder with near-identical shots. Choosing
# Continue starts a AutoCaptureDuplicateCooldownMs grace period during
# which further matches update the reference frame as normal but do NOT
# re-trigger the prompt, so it doesn't ask again on every single tick
# while the content genuinely hasn't changed yet.
#
# The prompt dialog itself (Show-DuplicateFramePrompt, below) is written
# so that a button click is the ONLY thing that can ever close it - see
# the comments on that function for why that's the actual fix for "the
# popup disappears and capturing just continues anyway".
# ---------------------------------------------------------------------------
$script:lastAutoCaptureBitmap = $null

# After the user clicks Continue on the duplicate-frame prompt, this is set
# to "now + AutoCaptureDuplicateCooldownMs". Until that time passes, new
# shots still get compared and lastAutoCaptureBitmap still gets updated
# normally each tick, but a match is NOT allowed to trigger the prompt
# again - otherwise clicking Continue while the captured content genuinely
# hasn't changed yet (a page still loading, a paused video, a static
# screen) would just compare the next shot against the one that was
# already flagged - which is every bit as similar - and pop the exact same
# prompt again on the very next tick, for as long as nothing changes.
$script:duplicateCheckCooldownUntil = [DateTime]::MinValue

# The stop flag. 0 = auto-capture is allowed to run normally. 1 = a
# duplicate frame was just spotted and auto-capture (plus manual/clipboard
# capture, region move/resize, and the toggle hotkeys) must NOT run at all
# until the user answers the prompt - it's the single source of truth for
# "are we allowed to capture right now", checked as the very first thing
# before any of those actions do anything else. It only ever goes 0 -> 1
# when Test-DuplicateFrameAndMaybePause spots a duplicate, and 1 -> 0 once
# the user has answered (either choice). The stop hotkey is the one
# exception and always still works regardless of this flag.
$script:acStopFlag = 0

function Clear-LastAutoCaptureBitmap {
    # [System.Drawing.Bitmap]::FromFile keeps the source file locked for as
    # long as the Bitmap is alive, so this must run before anything else
    # (Stop-AutoCapture's hand-off to Review & Stitch, a fresh session
    # starting, or the tool exiting) might need to read/move that file.
    if ($script:lastAutoCaptureBitmap) {
        $script:lastAutoCaptureBitmap.Dispose()
        $script:lastAutoCaptureBitmap = $null
    }
}

function Show-DuplicateFramePrompt {
    <#
        Modal dialog asking whether to stop or continue auto-capture after
        a near-duplicate frame was detected. Blocks (ShowDialog) until it
        closes; returns $true for Stop, $false for Continue. The
        auto-capture timer is always stopped by the caller before this is
        shown, so no new capture can fire while it's up.

        ROOT CAUSE, ROUND 2 - "buttons never enable, dialog just hangs
        until force-closed": every log line's elapsed time read back as
        -1ms, meaning $script:_dupPromptShownAt was still $null when read
        even though the "prompt shown" line right above it proves the
        write did happen. Writes made from *inside* the Add_Shown
        .GetNewClosure() scriptblock were not reaching the real script
        scope - contrary to what the closure was assumed to guarantee.

        That's also what silently broke the 700ms arm Timer: it was
        created and Start()-ed inside that same closure, so the only
        reference to it lived in the closure's own isolated scope. Once
        Add_Shown finished running, nothing kept that Timer object alive,
        so it was free to be garbage-collected before it ever ticked -
        no error, no "armed" log line, buttons stuck disabled forever.

        Fix: don't capture anything via closure at all. Everything
        Add_Shown needs is stashed in real $script: variables first, and
        Add_Shown itself is a plain scriptblock that only ever reads/
        writes $script: variables - nothing to isolate, nothing that can
        end up as the sole reference inside a scope that goes away.
    #>
    param([Parameter(Mandatory)][double]$SimilarityPercent)

    $armDelayMs = [Math]::Max(0, [int]$script:Config.AutoCaptureDuplicatePromptArmDelayMs)
    $simText    = $SimilarityPercent.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)

    try {

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'Region Screenshot Tool - Auto-Capture Paused'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.ControlBox      = $false
    $dlg.ShowInTaskbar   = $true
    $dlg.TopMost         = $true
    $dlg.StartPosition   = 'Manual'
    $dlg.ClientSize      = New-Object System.Drawing.Size(400, 150)

    # Bottom-right corner of the working area, deliberately not
    # CenterScreen - see the function comment above.
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $dlg.Location = New-Object System.Drawing.Point(
        ($wa.Right - $dlg.Width - 24), ($wa.Bottom - $dlg.Height - 24))

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = "Current screenshot very similar ($simText%) to last screenshot.`n`nStop auto-capture, or continue?"
    $lbl.Location = New-Object System.Drawing.Point(18, 16)
    $lbl.Size     = New-Object System.Drawing.Size(364, 62)
    $dlg.Controls.Add($lbl)

    $lblArming = New-Object System.Windows.Forms.Label
    $lblArming.Text      = 'One moment...'
    $lblArming.ForeColor = [System.Drawing.Color]::DimGray
    $lblArming.Location  = New-Object System.Drawing.Point(18, 80)
    $lblArming.Size      = New-Object System.Drawing.Size(200, 18)
    $lblArming.Visible   = ($armDelayMs -gt 0)
    $dlg.Controls.Add($lblArming)

    $btnStop = New-Object System.Windows.Forms.Button
    $btnStop.Text         = 'Stop'
    $btnStop.Size         = New-Object System.Drawing.Size(110, 30)
    $btnStop.Location     = New-Object System.Drawing.Point(160, 104)
    $btnStop.Enabled      = ($armDelayMs -le 0)
    $btnStop.TabStop      = $false
    $btnStop.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $dlg.Controls.Add($btnStop)

    $btnContinue = New-Object System.Windows.Forms.Button
    $btnContinue.Text         = 'Continue'
    $btnContinue.Size         = New-Object System.Drawing.Size(110, 30)
    $btnContinue.Location     = New-Object System.Drawing.Point(276, 104)
    $btnContinue.Enabled      = ($armDelayMs -le 0)
    $btnContinue.TabStop      = $false
    $btnContinue.DialogResult = [System.Windows.Forms.DialogResult]::No
    $dlg.Controls.Add($btnContinue)

    $script:_dupPromptShownAt = $null

    # All script-scoped (not closure-captured) - see the function comment
    # above. Add_Shown below is a plain scriptblock with no
    # .GetNewClosure(): it only ever touches these, so there's nothing for
    # a closure to isolate and nothing whose only live reference could end
    # up trapped inside one.
    $script:_dupDlg          = $dlg
    $script:_dupBtnStop      = $btnStop
    $script:_dupBtnContinue  = $btnContinue
    $script:_dupLblArming    = $lblArming
    $script:_dupArmTimer     = $null
    $script:_dupArmDelayMs   = $armDelayMs
    $script:_dupSimText      = $simText

    $dlg.KeyPreview = $true
    $dlg.Add_KeyDown({
        param($s, $e)
        $e.Handled          = $true
        $e.SuppressKeyPress = $true
    })
    $dlg.Add_KeyUp({
        param($s, $e)
        $e.Handled = $true
    })

    $dlg.Add_Shown({
        $script:_dupPromptShownAt = Get-Date
        Write-Log "Duplicate-frame prompt shown ($($script:_dupSimText)% similar)."

        try {
            [void][RegionTool.Native]::SetForegroundWindow($script:_dupDlg.Handle)
            $script:_dupDlg.Activate()
        } catch { }

        if ($script:_dupArmDelayMs -gt 0) {
            $script:_dupArmTimer = New-Object System.Windows.Forms.Timer
            $script:_dupArmTimer.Interval = $script:_dupArmDelayMs
            $script:_dupArmTimer.Add_Tick({
                try {
                    $script:_dupArmTimer.Stop()
                    $script:_dupArmTimer.Dispose()
                    $script:_dupArmTimer = $null
                    if ($script:_dupDlg -and -not $script:_dupDlg.IsDisposed) {
                        $script:_dupBtnStop.Enabled     = $true
                        $script:_dupBtnContinue.Enabled = $true
                        if ($script:_dupLblArming) { $script:_dupLblArming.Visible = $false }
                        Write-Log 'Duplicate-frame prompt armed - now accepting clicks.'
                    }
                }
                catch {
                    # Never let this bubble up as an unhandled WinForms
                    # exception dialog stacking on top of whatever prompt
                    # comes next - log it and fail safe (buttons simply
                    # stay disabled, which surfaces as "nothing happens
                    # when I click" rather than a confusing extra popup).
                    Write-Log "ERROR: duplicate-frame prompt arm-timer failed: $($_.Exception.Message)"
                }
            })
            $script:_dupArmTimer.Start()
        }
    })

    $result = $dlg.ShowDialog()

    $elapsedMs = if ($script:_dupPromptShownAt) {
        [int]((Get-Date) - $script:_dupPromptShownAt).TotalMilliseconds
    } else { -1 }
    $dlg.Dispose()

    Write-Log "Duplicate-frame prompt closed after ${elapsedMs}ms. Answer=$result"

    if ($result -ne [System.Windows.Forms.DialogResult]::Yes -and
        $result -ne [System.Windows.Forms.DialogResult]::No) {
        # ControlBox = $false removes the only two ways this could
        # normally happen (system Close button, Alt+F4) - if it somehow
        # still happens, fail safe by treating it as Stop rather than
        # silently letting capture continue.
        Write-Log "WARNING: duplicate-frame prompt closed with unexpected result '$result'. Stopping auto-capture as a safety fallback."
        return $true
    }
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)

    }
    catch {
        # Same reasoning as Show-ReviewHandoffPrompt's catch: without this,
        # a dialog-construction/handling failure here read as "the popup
        # flashed and auto-capture just stopped" with nothing in the log to
        # explain why. Fail safe (treated as Stop, same as the "unexpected
        # result" branch above) rather than silently letting capture continue
        # on a broken dialog.
        Write-Log "ERROR: duplicate-frame prompt failed: $($_.Exception.Message)"
        Write-Log $_.ScriptStackTrace
        $trayIcon.ShowBalloonTip(3000, 'Region Screenshot Tool',
            "Duplicate-frame prompt failed: $($_.Exception.Message)",
            [System.Windows.Forms.ToolTipIcon]::Warning)
        return $true
    }
}

function Test-DuplicateFrameAndMaybePause {
    <#
        Call right after an auto-capture shot is saved. Reloads it from
        disk, compares it against the previous auto-capture shot, and if
        they're similar enough, pauses the timer and prompts the user.
        Returns $true if the tick handler should stop immediately (either
        because auto-capture was paused-then-resumed, or stopped outright,
        both of which make finishing the rest of that tick's work, like a
        trailing auto-keypress, pointless or wrong).
    #>
    param([string]$Path)

    if (-not $script:Config.AutoCaptureDuplicateDetectionEnabled -or -not $Path) { return $false }

    $newBmp = $null
    try {
        $newBmp = [System.Drawing.Bitmap]::FromFile($Path)
    }
    catch {
        Write-Log "WARNING: couldn't reload '$Path' for duplicate-frame comparison: $($_.Exception.Message)"
        return $false
    }

    $isDuplicate = $false
    $similarity  = 0.0
    try {
        if ($script:lastAutoCaptureBitmap) {
            $avgDiff = [RegionTool.ImageDiff]::AverageDiff($script:lastAutoCaptureBitmap, $newBmp)
            if ($avgDiff -ge 0) {
                $similarity = 100.0 - [Math]::Min(100.0, ($avgDiff / 255.0) * 100.0)
                if ($similarity -ge [double]$script:Config.AutoCaptureDuplicateThresholdPercent) {
                    $isDuplicate = $true
                }
            }
        }
    }
    catch {
        # Don't let a comparison failure escape to the script-level trap -
        # that would abandon this tick with $newBmp never handed off to
        # $script:lastAutoCaptureBitmap (leaking its file handle) and the
        # timer's state unclear. Just skip the pause for this shot.
        Write-Log "WARNING: duplicate-frame comparison failed: $($_.Exception.Message)"
        $isDuplicate = $false
    }

    Clear-LastAutoCaptureBitmap
    $script:lastAutoCaptureBitmap = $newBmp

    if (-not $isDuplicate) { return $false }

    if ((Get-Date) -lt $script:duplicateCheckCooldownUntil) {
        # Still within the post-Continue cooldown: this shot is a match,
        # but we were just told to stop asking about matches for a while.
        # The reference bitmap above was still updated as normal, so once
        # the cooldown ends the next comparison is against this shot, not
        # a stale one from before the cooldown started.
        Write-Log ("Duplicate-frame prompt suppressed: shot is {0:N1}% similar, but still within the {1}ms cooldown after the last Continue." -f $similarity, $script:Config.AutoCaptureDuplicateCooldownMs)
        return $false
    }

    Write-Log ("Auto-capture paused: shot is {0:N1}% similar to the previous one (threshold {1}%)." -f $similarity, $script:Config.AutoCaptureDuplicateThresholdPercent)

    # Make sure the capture-flash overlay (and its own fade-out Timer) is
    # fully gone before the modal duplicate-frame dialog opens. ShowDialog()
    # pumps every Timer on this thread, not just the dialog's own - if the
    # flash's Timer is still ticking, it fires mid-dialog and closes its own
    # topmost window right as this topmost dialog is appearing, which is
    # exactly the kind of interaction that can make an unowned modal dialog
    # fold and close itself (DialogResult.Cancel) before it ever finishes
    # activating. The flash has already served its purpose by this point,
    # so there's nothing lost by cutting it short here.
    Hide-CaptureFlash

    $script:autoCaptureTimer.Stop()
    $script:acStopFlag = 1
    $itemAutoCapture.Text = 'Auto-Capture Paused (similar frame)'

    # Disable the tray's right-click menu for the duration of the prompt.
    # ShowDialog() with no Owner set does NOT disable sibling top-level
    # windows like a NotifyIcon's ContextMenuStrip - only the dialog
    # itself is modal. Without this, "Start/Stop Auto-Capture",
    # "Reselect Region", etc. on the tray menu stayed clickable the
    # entire time this prompt was on screen: clicking "Start Auto-
    # Capture" there while paused (autoCaptureRunning is still $true at
    # this point - it's only flipped by the choice made ON this prompt)
    # restarted the timer immediately, producing exactly the reported
    # "the popup shows up and capturing just continues anyway" behaviour
    # with no timer race or second process needed at all. pollTimer
    # itself is deliberately left running - its own tick handler already
    # checks $script:acStopFlag and skips everything except the stop
    # hotkey, which by design must keep working so the tool can always
    # be shut down cleanly even while this prompt is up.
    $menu.Enabled = $false

    try {
        $shouldStop = Show-DuplicateFramePrompt -SimilarityPercent $similarity

        if ($shouldStop) {
            Write-Log 'Auto-capture stopped by user from duplicate-frame prompt.'
            Stop-AutoCapture -ConfirmReviewHandoff
        }
        else {
            # Do NOT start autoCaptureTimer here. The outer tick handler
            # re-arms it (only if autoCaptureRunning is still true) after
            # this function returns. Starting here would race with any
            # already-queued WM_TIMER messages and could let a late tick
            # run while the prompt was still closing.
            $script:duplicateCheckCooldownUntil = (Get-Date).AddMilliseconds([double]$script:Config.AutoCaptureDuplicateCooldownMs)
            $itemAutoCapture.Text = "Stop Auto-Capture (every $(Format-IntervalMs $script:Config.AutoCaptureIntervalMs))"
            Write-Log ("Auto-capture resumed by user from duplicate-frame prompt. Duplicate prompt suppressed for the next {0}ms." -f $script:Config.AutoCaptureDuplicateCooldownMs)
        }
    }
    finally {
        $menu.Enabled = $true
        $script:acStopFlag = 0
    }
    return $true
}

# ---------------------------------------------------------------------------
# Auto-capture: takes a screenshot on a timer, independent of the hotkey.
# Started/stopped from the tray menu, and can optionally auto-start. Can
# also optionally send a key combo (e.g. F8) to the currently focused app
# either right before or right after each shot, with a configurable delay
# between the key press and the screenshot.
# ---------------------------------------------------------------------------
$script:autoCaptureTimer = New-Object System.Windows.Forms.Timer
$script:autoCaptureTickBusy = $false
# Desired-state flag for auto-capture. Timer.Enabled is temporarily false
# for the whole duration of every tick (we Stop up front so no further
# ticks are scheduled while we work), and a pending WM_TIMER that was
# already in the queue when Stop was called can still raise the Tick
# event afterward. Relying on Enabled alone therefore lets "zombie"
# ticks run after the user has chosen Stop on the duplicate-frame
# prompt - exactly the "popup flashes then capturing continues"
# behaviour. This flag is only flipped by Start-AutoCapture /
# Stop-AutoCapture and is what late/pending ticks consult.
$script:autoCaptureRunning = $false
$script:autoCaptureTimer.Add_Tick({
    # THE VERY FIRST THING every tick does, before anything else runs:
    # check the stop flag. 0 = allowed to capture, 1 = a duplicate frame
    # was already spotted and we are waiting on the user - in which case
    # this tick does nothing at all and returns immediately.
    if ($script:acStopFlag -eq 1) { return }

    # Everything below this line only ever runs when acStopFlag is 0.
    #
    # Reentrancy guard: Hide-CaptureFlash (called from Save-RegionScreenshot)
    # pumps the message queue with Application.DoEvents(), and the
    # duplicate-frame prompt pumps it too via ShowDialog() - both run while
    # this very Tick handler is still on the call stack. A WinForms Timer's
    # pending WM_TIMER is delivered by that same pump like any other
    # message, so without this guard a slow tick let autoCaptureTimer fire
    # again re-entrantly before the first tick finished. Each reentrant
    # call saved its own shot and opened its own duplicate-frame dialog,
    # which is what looked like the dialog flashing and immediately closing
    # as each newer, overlapping call tore down and replaced the one before
    # it. Stopping the timer up front (before anything that can pump
    # messages) and re-arming only once this tick is fully done - and the
    # busy flag as a belt-and-braces check - keeps ticks strictly
    # sequential.
    #
    # autoCaptureRunning is checked next so that any WM_TIMER messages
    # that were already queued when the user chose Stop on the duplicate
    # prompt (or when Stop-AutoCapture ran for any other reason) exit
    # immediately instead of capturing one more frame.
    if (-not $script:autoCaptureRunning) { return }
    if ($script:autoCaptureTickBusy) { return }
    $script:autoCaptureTickBusy = $true
    try {
        $script:autoCaptureTimer.Stop()

        $targetFolder = if ($script:currentSessionFolder) { $script:currentSessionFolder } else { $script:Config.SaveLocation }
        $hasAction = @($script:Config.AutoActionVKCodes).Count -gt 0
        $pausedByDuplicateCheck = $false
        if ($hasAction -and $script:Config.AutoActionTiming -eq 'After') {
            $path = Save-RegionScreenshot -Rect $script:captureRect -Folder $targetFolder
            Show-CaptureFlash -Rect $script:captureRect
            $pausedByDuplicateCheck = Test-DuplicateFrameAndMaybePause -Path $path
            if (-not $pausedByDuplicateCheck) {
                if ($script:Config.AutoActionDelayMs -gt 0) {
                    Start-Sleep -Milliseconds $script:Config.AutoActionDelayMs
                }
                Send-KeyCombo -Codes $script:Config.AutoActionVKCodes
            }
        }
        else {
            if ($hasAction) {
                Send-KeyCombo -Codes $script:Config.AutoActionVKCodes
                if ($script:Config.AutoActionDelayMs -gt 0) {
                    Start-Sleep -Milliseconds $script:Config.AutoActionDelayMs
                }
            }
            $path = Save-RegionScreenshot -Rect $script:captureRect -Folder $targetFolder
            Show-CaptureFlash -Rect $script:captureRect
            $pausedByDuplicateCheck = Test-DuplicateFrameAndMaybePause -Path $path
        }

        # Re-arm only if auto-capture is still supposed to be running AND
        # the stop flag didn't just get set to 1 by the call above. Both
        # are checked here (not just autoCaptureRunning) so this can never
        # restart the timer while acStopFlag is 1, no matter what order
        # Test-DuplicateFrameAndMaybePause's internals end up running in.
        if ($script:autoCaptureRunning -and $script:acStopFlag -eq 0) {
            $script:autoCaptureTimer.Start()
        }
    }
    finally {
        $script:autoCaptureTickBusy = $false
    }
})

# The session folder currently being written to by auto-capture (or $null
# if AutoCaptureUseSessionFolders is off), and the last one that was used -
# kept around so "Review Last Session" stays available after auto-capture
# stops.
$script:currentSessionFolder = $null
$script:lastSessionFolder    = $null

# Folder that plain Alt+S captures (i.e. no auto-capture session active)
# have been landing in during this run, if any. Manual captures don't get
# their own session folder, but the stop hotkey / Exit still need to know
# where to point Review & Stitch at, since Start_All.bat promises capture,
# review, and stitch all happen without running anything else by hand -
# that hand-off shouldn't only work when auto-capture was used.
$script:manualShotFolder = $null

function Start-ReviewTool {
    <#
        Launches Start-ReviewWebServer.ps1 as its own process, pointed at
        $SourceFolder. That script serves the Screenshot Stitcher web app
        (ps1/webapp/) plus this session's screenshots over a local HTTP
        server and opens the default browser to it - review/discard/reorder
        and stitching all happen there now instead of in a WinForms window,
        so this runs independently of this tool's own message loop exactly
        like the old review app did.

        IMPORTANT: this is launched via WMI (Win32_Process.Create), not
        Start-Process. Start-Process creates the child as a normal child
        process of this script's own console, and modern Windows consoles
        (Windows Terminal, and recent conhost builds too) run under a Job
        Object with "kill all processes when the job's last handle closes"
        - which is exactly what happens moments later when Invoke-CleanExit
        exits this tool. Whether the child survives that came down to a
        timing race (had it fully detached yet?), which is why the hand-off
        to Review & Stitch worked "most of the time" instead of reliably.
        A process created via WMI is owned by the WMI provider host, not
        this process's job, so it survives this tool exiting no matter the
        timing.

        Success is confirmed via a ready-marker file Start-ReviewWebServer
        writes once its HTTP listener is actually up (rather than guessing
        from a fixed timeout), and any startup crash is captured in the log
        file that script writes via -LogPath.

        IMPORTANT: the child is launched via -Command + [scriptblock]::Create(),
        NOT "-File Start-ReviewWebServer.ps1". On machines where script
        execution policy is locked down by Group Policy (AllSigned/
        Restricted), that lock applies to loading a .ps1 file directly and
        overrides even -ExecutionPolicy Bypass - so "-File ..." silently
        fails to launch while this tool's own capture loop keeps working
        fine (it's loaded the same safe way by Start_Screenshot_Tool.bat -
        see its comments). Turning the script's text into a scriptblock and
        invoking that with & keeps named-parameter binding (-ScriptRoot,
        -SourceFolder, -LogPath) working exactly like -File would, without
        ever "loading a .ps1 file" in the way the policy restricts.
    #>
    param([string]$SourceFolder)

    Write-Log "Launching Review & Stitch for folder: $SourceFolder"

    $reviewScript = Join-Path -Path $ScriptRoot -ChildPath 'Start-ReviewWebServer.ps1'
    if (-not (Test-Path -LiteralPath $reviewScript)) {
        Write-Log "ERROR: Start-ReviewWebServer.ps1 was not found next to this script."
        $trayIcon.ShowBalloonTip(2000, 'Region Screenshot Tool', 'Start-ReviewWebServer.ps1 was not found next to this script.', [System.Windows.Forms.ToolTipIcon]::Warning)
        return
    }

    # Written into the same Logs\ folder as everything else in the pipeline
    # so the whole capture->review->stitch handoff can be traced from one
    # place, even though this file is really Start-ReviewWebServer's own log
    # (see -LogPath below) plus the ready-marker used to confirm it started.
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $logPath = Join-Path $LogDir "ReviewWebServer_${stamp}.log"
    $readyPath = "$logPath.ready"

    # Single-quoted PS string literals embedded inside the -Command text
    # below - '' escapes a literal single quote, in case any path contains
    # one (rare, but cheap to guard against).
    $escape = { param($s) $s -replace "'", "''" }
    $reviewScriptEsc = & $escape $reviewScript
    $scriptRootEsc   = & $escape $ScriptRoot
    $logPathEsc      = & $escape $logPath

    $psCommand = "`$src = Get-Content -LiteralPath '$reviewScriptEsc' -Raw; " +
                 "`$sb = [scriptblock]::Create(`$src); " +
                 "& `$sb -ScriptRoot '$scriptRootEsc' -LogPath '$logPathEsc'"
    if ($SourceFolder) {
        $sourceFolderEsc = & $escape $SourceFolder
        $psCommand += " -SourceFolder '$sourceFolderEsc'"
    }

    # Win32_Process.Create takes one literal command line, not an argument
    # array - the whole -Command text is one double-quoted token; since it
    # only contains single-quoted literals internally, it never needs its
    # own embedded double-quote escaping.
    $cmdLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"$psCommand`""

    try {
        $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmdLine }
        if ($result.ReturnValue -ne 0) {
            Write-Log "ERROR: Review & Stitch failed to start (WMI error $($result.ReturnValue))."
            $trayIcon.ShowBalloonTip(3000, 'Region Screenshot Tool',
                "Review & Stitch failed to start (WMI error $($result.ReturnValue)).",
                [System.Windows.Forms.ToolTipIcon]::Warning)
            return
        }

        # Poll for the ready-marker instead of guessing from a fixed sleep -
        # the server can legitimately take a bit longer under load, and
        # that shouldn't be mistaken for a crash.
        $deadline = (Get-Date).AddSeconds(6)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            if (Test-Path -LiteralPath $readyPath) { $ready = $true; break }
            $stillRunning = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$($result.ProcessId)" -ErrorAction SilentlyContinue
            if (-not $stillRunning) { break }
            Start-Sleep -Milliseconds 150
        }

        if ($ready) {
            Write-Log "Review & Stitch started successfully. Log: $logPath"
        }
        else {
            $logTail = if (Test-Path -LiteralPath $logPath) { (Get-Content -LiteralPath $logPath -Raw) } else { '(no log written)' }
            Write-Log "ERROR: Review & Stitch didn't start. Log: $logPath"
            $trayIcon.ShowBalloonTip(4000, 'Region Screenshot Tool',
                "Review & Stitch didn't start. Log: $logPath",
                [System.Windows.Forms.ToolTipIcon]::Warning)
        }
    }
    catch {
        Write-Log "ERROR: Couldn't launch Review & Stitch: $($_.Exception.Message)"
        $trayIcon.ShowBalloonTip(2000, 'Region Screenshot Tool', "Couldn't launch Review & Stitch: $($_.Exception.Message)", [System.Windows.Forms.ToolTipIcon]::Warning)
    }
}

function Show-ReviewHandoffPrompt {
    <#
        Modal Yes/No dialog shown after auto-capture is stopped because of
        a duplicate-frame detection, asking whether to actually go ahead
        and open Review & Stitch. Only used for that path - a manual Stop
        (tray menu, stop hotkey, Exit) still hands off straight to
        Review & Stitch exactly as before, since the user has already
        explicitly chosen to stop there.

        Returns $true for "Yes, open Review & Stitch" and $false for "No,
        stay stopped without opening it". Same fix as Show-DuplicateFramePrompt
        above: Button.DialogResult + ShowDialog()'s own return value,
        instead of a hand-rolled $script:_reviewPromptAnswer variable that
        could (and did) end up 'None' even after a real click. ControlBox
        = $false is what actually keeps this a two-button-only exit; no
        FormClosing guard is needed on top of it.
    #>
    param([Parameter(Mandatory)][int]$ShotCount)

    try {
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text            = 'Region Screenshot Tool - Auto-Capture Stopped'
        $dlg.FormBorderStyle = 'FixedDialog'
        $dlg.MaximizeBox     = $false
        $dlg.MinimizeBox     = $false
        $dlg.ControlBox      = $false
        $dlg.ShowInTaskbar   = $true
        $dlg.TopMost         = $true
        $dlg.StartPosition   = 'Manual'
        $dlg.ClientSize      = New-Object System.Drawing.Size(400, 150)

        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $dlg.Location = New-Object System.Drawing.Point(
            ($wa.Right - $dlg.Width - 24), ($wa.Top + 24))

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text     = "Auto-capture stopped ($ShotCount screenshot(s) captured, due to a duplicate frame).`n`nOpen Review & Stitch now?"
        $lbl.Location = New-Object System.Drawing.Point(18, 16)
        $lbl.Size     = New-Object System.Drawing.Size(364, 68)
        $dlg.Controls.Add($lbl)

        $btnNo = New-Object System.Windows.Forms.Button
        $btnNo.Text         = 'No'
        $btnNo.Size         = New-Object System.Drawing.Size(110, 30)
        $btnNo.Location     = New-Object System.Drawing.Point(160, 104)
        $btnNo.TabStop      = $false
        $btnNo.DialogResult = [System.Windows.Forms.DialogResult]::No
        $dlg.Controls.Add($btnNo)

        $btnYes = New-Object System.Windows.Forms.Button
        $btnYes.Text         = 'Yes'
        $btnYes.Size         = New-Object System.Drawing.Size(110, 30)
        $btnYes.Location     = New-Object System.Drawing.Point(276, 104)
        $btnYes.TabStop      = $false
        $btnYes.DialogResult = [System.Windows.Forms.DialogResult]::Yes
        $dlg.Controls.Add($btnYes)

        $dlg.Add_Shown({
            Write-Log "Review-handoff prompt shown ($ShotCount screenshot(s))."
            # Best-effort only - never let a focus-grab failure affect
            # anything else, this dialog is fully usable without it.
            try {
                [void][RegionTool.Native]::SetForegroundWindow($dlg.Handle)
                $dlg.Activate()
            }
            catch { }
        }.GetNewClosure())

        $result = $dlg.ShowDialog()
        $dlg.Dispose()

        Write-Log "Review-handoff prompt closed. Answer=$result"

        if ($result -ne [System.Windows.Forms.DialogResult]::Yes -and
            $result -ne [System.Windows.Forms.DialogResult]::No) {
            # ControlBox = $false removes the only two normal ways this
            # could happen - fail safe by treating it as No rather than
            # silently opening Review & Stitch.
            Write-Log "WARNING: review-handoff prompt closed with unexpected result '$result'. Not opening Review & Stitch as a safety fallback."
            return $false
        }
        return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
    }
    catch {
        # This whole function used to run under the script's top-level
        # trap { continue } with no visible symptom beyond a FATAL log
        # line - from the user's side that reads exactly as "clicked
        # Yes, and nothing happened at all". Catching here instead means
        # any dialog-construction/handling failure is loud (a balloon
        # tip) and fails safe (treated as No, so a broken dialog can
        # never silently pretend the user said yes).
        Write-Log "ERROR: review-handoff prompt failed: $($_.Exception.Message)"
        Write-Log $_.ScriptStackTrace
        $trayIcon.ShowBalloonTip(3000, 'Region Screenshot Tool',
            "Review-handoff prompt failed: $($_.Exception.Message)",
            [System.Windows.Forms.ToolTipIcon]::Warning)
        return $false
    }
}

function Format-IntervalMs {
    param([int]$Milliseconds)
    if ($Milliseconds % 1000 -eq 0) { return "$($Milliseconds / 1000)s" }
    return "${Milliseconds}ms"
}

function Start-AutoCapture {
    if ($script:Config.AutoCaptureUseSessionFolders) {
        $script:currentSessionFolder = Join-Path -Path $script:Config.SaveLocation -ChildPath (New-AutoCaptureSessionFolderName)
        New-Item -ItemType Directory -Path $script:currentSessionFolder -Force | Out-Null
    }
    else {
        $script:currentSessionFolder = $null
    }
    # A new session's first shot shouldn't be compared against whatever the
    # last session's last shot was, and shouldn't inherit any cooldown left
    # over from a previous session's duplicate-frame prompt.
    Clear-LastAutoCaptureBitmap
    $script:duplicateCheckCooldownUntil = [DateTime]::MinValue
    $script:autoCaptureRunning = $true
    $script:autoCaptureTimer.Interval = [Math]::Max(500, [int]$script:Config.AutoCaptureIntervalMs)
    $script:autoCaptureTimer.Start()
    $itemAutoCapture.Text = "Stop Auto-Capture (every $(Format-IntervalMs $script:Config.AutoCaptureIntervalMs))"
    $trayIcon.ShowBalloonTip(1200, 'Auto-Capture Started', "Capturing every $(Format-IntervalMs $script:Config.AutoCaptureIntervalMs).", [System.Windows.Forms.ToolTipIcon]::Info)
    Write-Log "Auto-capture started. Interval=$($script:Config.AutoCaptureIntervalMs)ms  SessionFolder=$($script:currentSessionFolder)"
}

function Stop-AutoCapture {
    <#
        -ConfirmReviewHandoff: only passed by Test-DuplicateFrameAndMaybePause
        (see below). When set, and this stop would otherwise auto-launch
        Review & Stitch, Show-ReviewHandoffPrompt asks first - a duplicate
        frame stopping the session is not the same as the user deliberately
        choosing to stop (tray menu, stop hotkey, Exit), so the drastic
        jump straight into Review & Stitch shouldn't happen without a
        second explicit "yes" from the user. Answering No leaves auto-
        capture stopped (already done above) but skips the handoff -
        Review & Stitch can still be opened later from the tray's
        "Review Last Session" item.
    #>
    param([switch]$ConfirmReviewHandoff)

    $script:autoCaptureRunning = $false
    $script:autoCaptureTimer.Stop()
    $itemAutoCapture.Text = 'Start Auto-Capture'

    # Must happen before anything below might touch the most recent shot's
    # file (e.g. handing the session off to Review & Stitch) - the Bitmap
    # loaded for duplicate-frame comparison keeps that file locked until
    # disposed.
    Clear-LastAutoCaptureBitmap

    $finishedSession = $script:currentSessionFolder
    $script:currentSessionFolder = $null
    $script:manualShotFolder = $null

    if ($finishedSession) {
        $script:lastSessionFolder = $finishedSession
        $itemReviewLast.Enabled = $true
        $shotCount = @(Get-ChildItem -LiteralPath $finishedSession -File -ErrorAction SilentlyContinue |
            Where-Object { @('.png', '.bmp') -contains $_.Extension.ToLowerInvariant() }).Count
        $willReview = $shotCount -gt 0 -and $script:Config.AutoLaunchReviewOnStop

        try {
            if ($willReview -and $ConfirmReviewHandoff) {
                $confirmed = Show-ReviewHandoffPrompt -ShotCount $shotCount
                if (-not $confirmed) {
                    Write-Log "Auto-capture stopped. Session=$finishedSession  ShotCount=$shotCount  WillReview=false (user declined review-handoff prompt)"
                    $trayIcon.ShowBalloonTip(1200, 'Auto-Capture Stopped', "$shotCount screenshot(s) captured.", [System.Windows.Forms.ToolTipIcon]::Info)
                    return
                }
            }

            $statusMsg = if ($willReview) { "$shotCount screenshot(s) captured. Opening review..." } else { "$shotCount screenshot(s) captured." }
            $trayIcon.ShowBalloonTip(1200, 'Auto-Capture Stopped', $statusMsg, [System.Windows.Forms.ToolTipIcon]::Info)
            Write-Log "Auto-capture stopped. Session=$finishedSession  ShotCount=$shotCount  WillReview=$willReview"
            if ($willReview) {
                Start-ReviewTool -SourceFolder $finishedSession
            }
        }
        catch {
            # Same reasoning as the try/catch inside Show-ReviewHandoffPrompt:
            # without this, any failure here (confirming the prompt or
            # launching Start-ReviewTool) would be caught by the script's
            # top-level trap { continue } and only ever show up as a FATAL
            # line in the log - from the user's side, clicking Yes and
            # simply nothing happening, with no visible error at all.
            Write-Log "ERROR: review handoff failed after stopping auto-capture: $($_.Exception.Message)"
            Write-Log $_.ScriptStackTrace
            $trayIcon.ShowBalloonTip(3000, 'Region Screenshot Tool',
                "Couldn't open Review & Stitch: $($_.Exception.Message)",
                [System.Windows.Forms.ToolTipIcon]::Warning)
        }
    }
    else {
        $trayIcon.ShowBalloonTip(1200, 'Auto-Capture Stopped', 'Automatic capturing has been stopped.', [System.Windows.Forms.ToolTipIcon]::Info)
        Write-Log "Auto-capture stopped. No session folder was active."
    }
}

$itemAutoCapture.Add_Click({
    # This is the click handler that mattered most: while the
    # duplicate-frame prompt is open, $script:autoCaptureRunning is still
    # $true (it's only flipped by the user's choice on the prompt itself,
    # via Stop-AutoCapture), so without this guard, clicking this tray
    # menu item during the pause called Stop-AutoCapture (merely
    # confusing) - but on a SECOND click (or on a re-entrant handler in
    # older builds of this tool that toggled differently) could call
    # Start-AutoCapture and restart the timer while the prompt was still
    # up. $menu.Enabled being set to $false during the pause (see
    # Test-DuplicateFrameAndMaybePause) should already prevent this from
    # being reachable at all, but this check is kept as a second,
    # independent line of defense in case Windows delivers the click
    # anyway (e.g. because the menu was already open the instant Enabled
    # flipped).
    if ($script:acStopFlag -eq 1) { return }
    if ($script:autoCaptureRunning) { Stop-AutoCapture } else { Start-AutoCapture }
})

$itemReload.Add_Click({
    if ($script:acStopFlag -eq 1) { return }
    Apply-Config
    if ($script:autoCaptureRunning) {
        $script:autoCaptureTimer.Interval = [Math]::Max(500, [int]$script:Config.AutoCaptureIntervalMs)
        $itemAutoCapture.Text = "Stop Auto-Capture (every $(Format-IntervalMs $script:Config.AutoCaptureIntervalMs))"
    }
    $trayIcon.ShowBalloonTip(1500, 'Region Screenshot Tool', 'Config reloaded.', [System.Windows.Forms.ToolTipIcon]::Info)
})

function Invoke-CleanExit {
    <#
        Shuts the tool down in an orderly way: stops timers, hides the tray
        icon, and exits the WinForms message loop. Used by both the tray
        "Exit" menu item and the stop hotkey, so there's no need to kill
        the terminal window (which otherwise causes an ugly "has stopped
        working" / unhandled-exception style warning).

        If auto-capture is still running, this finalizes that session first
        (via Stop-AutoCapture) exactly like toggling auto-capture off would -
        so quitting mid-session still hands the captured screenshots off to
        Review & Stitch (when AutoLaunchReviewOnStop is enabled) instead of
        silently abandoning them.
    #>
    if ($script:autoCaptureRunning) {
        Stop-AutoCapture
    }
    elseif ($script:manualShotFolder -and $script:Config.AutoLaunchReviewOnStop) {
        # No auto-capture session was running, but Alt+S captures were
        # taken this run - Start_All.bat's whole pitch is that you don't
        # need to run anything else by hand, so those need the same
        # hand-off Stop-AutoCapture gives a real session.
        $shotCount = @(Get-ChildItem -LiteralPath $script:manualShotFolder -File -ErrorAction SilentlyContinue |
            Where-Object { @('.png', '.bmp') -contains $_.Extension.ToLowerInvariant() }).Count
        if ($shotCount -gt 0) {
            $trayIcon.ShowBalloonTip(1200, 'Region Screenshot Tool', "$shotCount screenshot(s) captured. Opening review...", [System.Windows.Forms.ToolTipIcon]::Info)
            Start-ReviewTool -SourceFolder $script:manualShotFolder
        }
    }
    if ($script:captureRect) { Save-LastRegion -Rect $script:captureRect }
    $pollTimer.Stop()
    $script:autoCaptureTimer.Stop()
    Clear-LastAutoCaptureBitmap
    Hide-CaptureFlash
    Remove-RegionBorder
    Write-Log 'RegionScreenshot exiting.'
    # Tray icon is hidden last, and only after the balloon calls above have
    # had a moment to actually render - hiding/destroying the NotifyIcon
    # immediately after ShowBalloonTip can dismiss the balloon before it's
    # ever drawn, which made review hand-off (or a launch failure) look
    # like it silently did nothing even when it had, in fact, fired.
    Start-Sleep -Milliseconds 200
    $trayIcon.Visible = $false
    if ($script:singleInstanceMutex) {
        $script:singleInstanceMutex.ReleaseMutex()
        $script:singleInstanceMutex.Dispose()
    }
    [System.Windows.Forms.Application]::Exit()
}

$itemExit.Add_Click({ Invoke-CleanExit })

# ---------------------------------------------------------------------------
# Hotkey polling
# ---------------------------------------------------------------------------
# Polls with a Forms timer so we stay on the UI thread. GetAsyncKeyState
# reads the physical key state system-wide, so this fires even when this
# tool's window isn't focused - it works while you're working in any other
# app. The hotkey can be a combo of up to 4 keys (e.g. Ctrl+Shift+F9); a
# capture fires only once all of them are held down together, and is
# debounced with $hotkeyWasDown so holding the combo doesn't repeat-fire.
# The stop hotkey works the same way, and triggers a clean shutdown -
# use it instead of closing the terminal window, which can otherwise
# produce an ugly ".NET has stopped working" style crash warning.
$script:hotkeyWasDown       = $false
$script:clipboardHotkeyWasDown = $false
$script:stopHotkeyWasDown   = $false
$script:toggleHotkeyWasDown = $false
$script:toggleAutoCaptureHotkeyWasDown = $false
$PollIntervalMs = 60

function Test-HotkeyCombo([int[]]$Codes) {
    if (-not $Codes -or $Codes.Count -eq 0) { return $false }
    foreach ($vk in $Codes) {
        $state = [RegionTool.Native]::GetAsyncKeyState([int]$vk)
        if (($state -band 0x8000) -eq 0) { return $false }
    }
    return $true
}

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = $PollIntervalMs
$pollTimer.Add_Tick({
    $stopDown = Test-HotkeyCombo -Codes $script:Config.StopHotkeyVKCodes
    if ($stopDown -and -not $script:stopHotkeyWasDown) {
        Invoke-CleanExit
        return
    }
    $script:stopHotkeyWasDown = $stopDown

    # THE VERY FIRST THING checked after the stop hotkey (which always
    # works regardless): the stop flag. If it's 1, a duplicate frame is
    # up for the user to answer and everything else pauses too
    # (manual/clipboard capture, region move/resize, the toggle hotkeys)
    # so nothing can sneak a new capture or action in while the question
    # is on screen, regardless of what's causing it (a held auto-advance
    # key, a queued hotkey, plain muscle memory). The "was down" debounce
    # trackers are still kept in sync while paused, so a key held across
    # the whole pause doesn't look like a brand-new press - and doesn't
    # fire anything - the instant the prompt closes.
    if ($script:acStopFlag -eq 1) {
        $script:toggleHotkeyWasDown            = Test-HotkeyCombo -Codes $script:Config.ToggleBorderHotkeyVKCodes
        $script:toggleAutoCaptureHotkeyWasDown = Test-HotkeyCombo -Codes $script:Config.ToggleAutoCaptureHotkeyVKCodes
        $script:clipboardHotkeyWasDown         = Test-HotkeyCombo -Codes $script:Config.ClipboardHotkeyVKCodes
        $script:hotkeyWasDown                  = Test-HotkeyCombo -Codes $script:Config.HotkeyVKCodes
        $script:moveResizeHoldState = @{}
        return
    }

    $toggleDown = Test-HotkeyCombo -Codes $script:Config.ToggleBorderHotkeyVKCodes
    if ($toggleDown -and -not $script:toggleHotkeyWasDown) {
        $visible = Toggle-RegionBorder
        $itemToggleBorder.Text = if ($visible) { 'Hide Region Border' } else { 'Show Region Border' }
    }
    $script:toggleHotkeyWasDown = $toggleDown

    $toggleAutoCaptureDown = Test-HotkeyCombo -Codes $script:Config.ToggleAutoCaptureHotkeyVKCodes
    if ($toggleAutoCaptureDown -and -not $script:toggleAutoCaptureHotkeyWasDown) {
        if ($script:autoCaptureRunning) { Stop-AutoCapture } else { Start-AutoCapture }
    }
    $script:toggleAutoCaptureHotkeyWasDown = $toggleAutoCaptureDown

    # Clipboard combo (Ctrl+Shift+Alt+S) is a superset of the plain save
    # combo (Ctrl+Shift+S), so it's checked first - if it fires, the plain
    # save combo is suppressed for this tick so a single key press doesn't
    # trigger both.
    $clipboardDown = Test-HotkeyCombo -Codes $script:Config.ClipboardHotkeyVKCodes
    if ($clipboardDown -and -not $script:clipboardHotkeyWasDown) {
        Copy-RegionScreenshotToClipboard -Rect $script:captureRect
        Show-CaptureFlash -Rect $script:captureRect
        $trayIcon.ShowBalloonTip(1200, 'Screenshot Copied', 'Region copied to clipboard.', [System.Windows.Forms.ToolTipIcon]::Info)
    }
    $script:clipboardHotkeyWasDown = $clipboardDown

    $allDown = Test-HotkeyCombo -Codes $script:Config.HotkeyVKCodes
    if ($allDown -and -not $clipboardDown -and -not $script:hotkeyWasDown) {
        $path = Save-RegionScreenshot -Rect $script:captureRect
        # Only tracked when there's no active auto-capture session - those
        # already have their own folder via $script:currentSessionFolder,
        # this is purely for the "just pressed Alt+S a few times" case.
        if (-not $script:currentSessionFolder) {
            $script:manualShotFolder = Split-Path -Path $path -Parent
        }
        Show-CaptureFlash -Rect $script:captureRect
        $trayIcon.ShowBalloonTip(1200, 'Screenshot Saved', (Split-Path $path -Leaf), [System.Windows.Forms.ToolTipIcon]::Info)
    }
    $script:hotkeyWasDown = $allDown

    # Move/resize the region with modifier + arrow keys. A quick tap moves
    # by FineStepPixels (1px by default) for precise nudging; holding the
    # combo down past a short delay switches to repeating at
    # MoveResizeStepPixels for fast bulk repositioning. Without this
    # distinction every poll tick (60ms) applied a full MoveResizeStepPixels
    # jump, so even a brief tap could move the region 10-20px at once -
    # too coarse for lining an edge up precisely.
    $fineStep   = [int]$script:Config.FineStepPixels
    $coarseStep = [int]$script:Config.MoveResizeStepPixels
    $repeatDelayMs    = 350
    $repeatIntervalMs = 40

    $activeMode = $null
    if (Test-HotkeyCombo -Codes $script:Config.ResizeModifierVKCodes) { $activeMode = 'resize' }
    elseif (Test-HotkeyCombo -Codes $script:Config.MoveModifierVKCodes) { $activeMode = 'move' }

    $directions = [ordered]@{
        Right = 39; Left = 37; Down = 40; Up = 38
    }
    if (-not $script:moveResizeHoldState) { $script:moveResizeHoldState = @{} }
    $nowTicks = [Environment]::TickCount

    foreach ($dirName in $directions.Keys) {
        $key = "$activeMode`:$dirName"
        $isDown = $activeMode -and (Test-HotkeyCombo -Codes @($directions[$dirName]))

        if (-not $isDown) {
            $script:moveResizeHoldState.Remove($key)
            continue
        }

        $applyStep = $false
        $stepSize = $fineStep

        if (-not $script:moveResizeHoldState.ContainsKey($key)) {
            # Fresh press (this direction/mode combo wasn't down last tick):
            # apply one fine step immediately, and start tracking hold time.
            $script:moveResizeHoldState[$key] = [PSCustomObject]@{ PressedAt = $nowTicks; LastStepAt = $nowTicks }
            $applyStep = $true
            $stepSize = $fineStep
        }
        else {
            $state = $script:moveResizeHoldState[$key]
            $heldMs = $nowTicks - $state.PressedAt
            if ($heldMs -ge $repeatDelayMs) {
                $sinceLastStepMs = $nowTicks - $state.LastStepAt
                if ($sinceLastStepMs -ge $repeatIntervalMs) {
                    $applyStep = $true
                    $stepSize = $coarseStep
                    $state.LastStepAt = $nowTicks
                }
            }
        }

        if ($applyStep) {
            switch ("$activeMode`:$dirName") {
                'resize:Right' { Resize-CaptureRegion -DeltaWidth  $stepSize -DeltaHeight 0 }
                'resize:Left'  { Resize-CaptureRegion -DeltaWidth (-$stepSize) -DeltaHeight 0 }
                'resize:Down'  { Resize-CaptureRegion -DeltaWidth 0 -DeltaHeight  $stepSize }
                'resize:Up'    { Resize-CaptureRegion -DeltaWidth 0 -DeltaHeight (-$stepSize) }
                'move:Right'   { Move-CaptureRegion -DeltaX  $stepSize -DeltaY 0 }
                'move:Left'    { Move-CaptureRegion -DeltaX (-$stepSize) -DeltaY 0 }
                'move:Down'    { Move-CaptureRegion -DeltaX 0 -DeltaY  $stepSize }
                'move:Up'      { Move-CaptureRegion -DeltaX 0 -DeltaY (-$stepSize) }
            }
        }
    }
})
$pollTimer.Start()

if ($script:Config.AutoCaptureAutoStart) {
    Start-AutoCapture
}

Write-Log "Region Screenshot Tool started. PID=$PID"
$trayIcon.Text = "Region Screenshot Tool (PID $PID)"
$trayIcon.ShowBalloonTip(2000, "Region Screenshot Tool (PID $PID)", "Ready. Press $($Config.HotkeyName) to capture, $($Config.ClipboardHotkeyName) to copy to clipboard, $($Config.ToggleBorderHotkeyName) to hide/show the border, $($Config.ToggleAutoCaptureHotkeyName) to start/stop auto-capture, or $($Config.StopHotkeyName) to stop. Hold $($Config.MoveModifierName) + arrows to move the region, or $($Config.ResizeModifierName) + arrows to resize it. Right-click the tray icon for options.", [System.Windows.Forms.ToolTipIcon]::Info)

[System.Windows.Forms.Application]::Run()
