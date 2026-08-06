<#
.SYNOPSIS
    Region screenshot tool.

.DESCRIPTION
    On startup, lets you drag out a rectangle on your screen(s) to define a
    capture region. Once selected, the tool sits in the system tray and
    listens for a capture hotkey (which can be a combo of up to 4 keys,
    e.g. Ctrl+Shift+S) and a separate stop hotkey (default Ctrl+Shift+Q)
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
# Script root + config file
# ---------------------------------------------------------------------------
# $PSScriptRoot is empty when this script is fed in via Invoke-Expression
# (used as a workaround for locked-down execution policies), so fall back
# to an env var the launcher sets, then to cwd.
$ScriptRoot =
    if ($PSScriptRoot) { $PSScriptRoot }
    elseif ($env:REGION_SCREENSHOT_ROOT) { $env:REGION_SCREENSHOT_ROOT }
    else { (Get-Location).Path }

# The project root is one level up from the ps1\ folder (i.e. the folder
# that contains ps1\, bat\, and Start_All.bat). Screenshots and stitched
# output default to subfolders of this, not of ps1\, so they land next to
# the launchers instead of inside the scripts folder.
$ProjectRoot = Split-Path -Path $ScriptRoot -Parent
if (-not $ProjectRoot) { $ProjectRoot = $ScriptRoot }

$ConfigPath = Join-Path -Path $ScriptRoot -ChildPath 'config.json'

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
    SaveLocation                = (Join-Path -Path $ProjectRoot -ChildPath 'screenshots')
    FileNameScheme              = 'screenshot_{timestamp}'
    AutoCaptureIntervalMs      = 5000   # minimum 500
    AutoCaptureAutoStart       = $false
    AutoCaptureUseSessionFolders   = $true
    AutoCaptureSessionFolderScheme = 'Session_{date}_{time}'
    AutoActionKeyName          = ''
    AutoActionVKCodes          = @()
    AutoActionTiming           = 'Before'   # 'Before' or 'After' the screenshot
    AutoActionDelayMs          = 150
    AutoLaunchReviewOnStop      = $true
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
    if ($intervalMs -le 0) { $intervalMs = 5000 }
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
        return $path
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
    $script:flashTimer.Interval = 40
    $script:flashTimer.Add_Tick({
        if (-not $script:flashForm) {
            $script:flashTimer.Stop()
            return
        }
        $script:flashForm.Opacity -= 0.12
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

$captureRect = Select-Region
if (-not $captureRect) {
    [System.Windows.Forms.MessageBox]::Show(
        'No region selected. Exiting.', 'Region Screenshot Tool'
    ) | Out-Null
    exit
}
$script:captureRect = $captureRect
Sync-RegionBorder

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
    $newRect = Select-Region
    if ($newRect) {
        $script:captureRect = $newRect
        Sync-RegionBorder
        $trayIcon.ShowBalloonTip(1500, 'Region Screenshot Tool', 'Capture region updated.', [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

$itemToggleBorder.Add_Click({
    $visible = Toggle-RegionBorder
    $itemToggleBorder.Text = if ($visible) { 'Hide Region Border' } else { 'Show Region Border' }
})

$itemOpenDir.Add_Click({
    Start-Process explorer.exe $script:Config.SaveLocation
})

$itemReviewLast.Add_Click({
    if ($script:lastSessionFolder) { Start-ReviewTool -SourceFolder $script:lastSessionFolder }
})

$itemReviewOpen.Add_Click({
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
# Auto-capture: takes a screenshot on a timer, independent of the hotkey.
# Started/stopped from the tray menu, and can optionally auto-start. Can
# also optionally send a key combo (e.g. F8) to the currently focused app
# either right before or right after each shot, with a configurable delay
# between the key press and the screenshot.
# ---------------------------------------------------------------------------
$script:autoCaptureTimer = New-Object System.Windows.Forms.Timer
$script:autoCaptureTimer.Add_Tick({
    $targetFolder = if ($script:currentSessionFolder) { $script:currentSessionFolder } else { $script:Config.SaveLocation }
    $hasAction = @($script:Config.AutoActionVKCodes).Count -gt 0
    if ($hasAction -and $script:Config.AutoActionTiming -eq 'After') {
        $path = Save-RegionScreenshot -Rect $script:captureRect -Folder $targetFolder
        Show-CaptureFlash -Rect $script:captureRect
        if ($script:Config.AutoActionDelayMs -gt 0) {
            Start-Sleep -Milliseconds $script:Config.AutoActionDelayMs
        }
        Send-KeyCombo -Codes $script:Config.AutoActionVKCodes
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
    }
})

# The session folder currently being written to by auto-capture (or $null
# if AutoCaptureUseSessionFolders is off), and the last one that was used -
# kept around so "Review Last Session" stays available after auto-capture
# stops.
$script:currentSessionFolder = $null
$script:lastSessionFolder    = $null

function Start-ReviewTool {
    <#
        Launches Start-ReviewWebServer.ps1 as its own process, pointed at
        $SourceFolder. That script serves the Screenshot Stitcher web app
        (ps1/webapp/) plus this session's screenshots over a local HTTP
        server and opens the default browser to it - review/discard/reorder
        and stitching all happen there now instead of in a WinForms window,
        so this runs independently of this tool's own message loop exactly
        like the old review app did.

        The child process's console output is redirected to a log file
        (not shown in a window) so a crash on launch leaves something to
        look at instead of just a Windows "Application Error" popup. If the
        process exits within moments of starting - the signature of a
        launch-time crash rather than the server actually running - this
        retries once before giving up.
    #>
    param([string]$SourceFolder)

    $reviewScript = Join-Path -Path $ScriptRoot -ChildPath 'Start-ReviewWebServer.ps1'
    if (-not (Test-Path -LiteralPath $reviewScript)) {
        $trayIcon.ShowBalloonTip(2000, 'Region Screenshot Tool', 'Start-ReviewWebServer.ps1 was not found next to this script.', [System.Windows.Forms.ToolTipIcon]::Warning)
        return
    }

    # Manually quote the path arguments - Windows PowerShell 5.1's
    # Start-Process -ArgumentList joins array elements with a plain space
    # and does not auto-quote ones that contain spaces (unlike .NET's
    # newer ArgumentList property), so a path like "C:\My Screenshots"
    # would otherwise be split into two arguments.
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$reviewScript`"")
    if ($SourceFolder) { $argList += @('-SourceFolder', "`"$SourceFolder`"") }

    $logDir = Join-Path $env:TEMP 'ShotStitcherReviewServer'
    New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null

    function _tryLaunch {
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
        $outLog = Join-Path $logDir "launch_${stamp}_out.log"
        $errLog = Join-Path $logDir "launch_${stamp}_err.log"
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList `
            -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru
        # A launch-time crash (e.g. the 0xc0000142 "unable to start correctly"
        # case) exits within milliseconds; the server itself runs
        # indefinitely once actually up, so a brief wait tells them apart.
        Start-Sleep -Milliseconds 900
        return @{ Process = $proc; OutLog = $outLog; ErrLog = $errLog }
    }

    try {
        $attempt = _tryLaunch
        if ($attempt.Process.HasExited) {
            Start-Sleep -Milliseconds 300
            $attempt = _tryLaunch
        }
        if ($attempt.Process.HasExited) {
            $trayIcon.ShowBalloonTip(3000, 'Region Screenshot Tool',
                "Review & Stitch failed to start twice (exit code $($attempt.Process.ExitCode)). Log: $($attempt.ErrLog)",
                [System.Windows.Forms.ToolTipIcon]::Warning)
        }
    }
    catch {
        $trayIcon.ShowBalloonTip(2000, 'Region Screenshot Tool', "Couldn't launch Review & Stitch: $($_.Exception.Message)", [System.Windows.Forms.ToolTipIcon]::Warning)
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
    $script:autoCaptureTimer.Interval = [Math]::Max(500, [int]$script:Config.AutoCaptureIntervalMs)
    $script:autoCaptureTimer.Start()
    $itemAutoCapture.Text = "Stop Auto-Capture (every $(Format-IntervalMs $script:Config.AutoCaptureIntervalMs))"
    $trayIcon.ShowBalloonTip(1200, 'Auto-Capture Started', "Capturing every $(Format-IntervalMs $script:Config.AutoCaptureIntervalMs).", [System.Windows.Forms.ToolTipIcon]::Info)
}

function Stop-AutoCapture {
    $script:autoCaptureTimer.Stop()
    $itemAutoCapture.Text = 'Start Auto-Capture'

    $finishedSession = $script:currentSessionFolder
    $script:currentSessionFolder = $null

    if ($finishedSession) {
        $script:lastSessionFolder = $finishedSession
        $itemReviewLast.Enabled = $true
        $shotCount = @(Get-ChildItem -LiteralPath $finishedSession -File -ErrorAction SilentlyContinue |
            Where-Object { @('.png', '.bmp') -contains $_.Extension.ToLowerInvariant() }).Count
        $willReview = $shotCount -gt 0 -and $script:Config.AutoLaunchReviewOnStop
        $statusMsg = if ($willReview) { "$shotCount screenshot(s) captured. Opening review..." } else { "$shotCount screenshot(s) captured." }
        $trayIcon.ShowBalloonTip(1200, 'Auto-Capture Stopped', $statusMsg, [System.Windows.Forms.ToolTipIcon]::Info)
        if ($willReview) {
            Start-ReviewTool -SourceFolder $finishedSession
        }
    }
    else {
        $trayIcon.ShowBalloonTip(1200, 'Auto-Capture Stopped', 'Automatic capturing has been stopped.', [System.Windows.Forms.ToolTipIcon]::Info)
    }
}

$itemAutoCapture.Add_Click({
    if ($script:autoCaptureTimer.Enabled) { Stop-AutoCapture } else { Start-AutoCapture }
})

$itemReload.Add_Click({
    Apply-Config
    if ($script:autoCaptureTimer.Enabled) {
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
    if ($script:autoCaptureTimer.Enabled) {
        Stop-AutoCapture
    }
    $trayIcon.Visible = $false
    $pollTimer.Stop()
    $script:autoCaptureTimer.Stop()
    Hide-CaptureFlash
    Remove-RegionBorder
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

    $toggleDown = Test-HotkeyCombo -Codes $script:Config.ToggleBorderHotkeyVKCodes
    if ($toggleDown -and -not $script:toggleHotkeyWasDown) {
        $visible = Toggle-RegionBorder
        $itemToggleBorder.Text = if ($visible) { 'Hide Region Border' } else { 'Show Region Border' }
    }
    $script:toggleHotkeyWasDown = $toggleDown

    $toggleAutoCaptureDown = Test-HotkeyCombo -Codes $script:Config.ToggleAutoCaptureHotkeyVKCodes
    if ($toggleAutoCaptureDown -and -not $script:toggleAutoCaptureHotkeyWasDown) {
        if ($script:autoCaptureTimer.Enabled) { Stop-AutoCapture } else { Start-AutoCapture }
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
        Show-CaptureFlash -Rect $script:captureRect
        $trayIcon.ShowBalloonTip(1200, 'Screenshot Saved', (Split-Path $path -Leaf), [System.Windows.Forms.ToolTipIcon]::Info)
    }
    $script:hotkeyWasDown = $allDown

    # Move/resize the region with modifier + arrow keys. Resize is checked
    # first because its modifier combo often contains the move modifier
    # plus an extra key (e.g. move = Ctrl+Alt, resize = Ctrl+Alt+Shift) -
    # checking resize first means holding the resize combo doesn't also
    # fire a move. Repeats every tick while held, so the region keeps
    # sliding/growing smoothly for as long as the keys are down.
    $step = [int]$script:Config.MoveResizeStepPixels
    if (Test-HotkeyCombo -Codes $script:Config.ResizeModifierVKCodes) {
        if (Test-HotkeyCombo -Codes @(39)) { Resize-CaptureRegion -DeltaWidth  $step -DeltaHeight 0 }      # Right
        if (Test-HotkeyCombo -Codes @(37)) { Resize-CaptureRegion -DeltaWidth (-$step) -DeltaHeight 0 }     # Left
        if (Test-HotkeyCombo -Codes @(40)) { Resize-CaptureRegion -DeltaWidth 0 -DeltaHeight  $step }       # Down
        if (Test-HotkeyCombo -Codes @(38)) { Resize-CaptureRegion -DeltaWidth 0 -DeltaHeight (-$step) }     # Up
    }
    elseif (Test-HotkeyCombo -Codes $script:Config.MoveModifierVKCodes) {
        if (Test-HotkeyCombo -Codes @(39)) { Move-CaptureRegion -DeltaX  $step -DeltaY 0 }   # Right
        if (Test-HotkeyCombo -Codes @(37)) { Move-CaptureRegion -DeltaX (-$step) -DeltaY 0 } # Left
        if (Test-HotkeyCombo -Codes @(40)) { Move-CaptureRegion -DeltaX 0 -DeltaY  $step }   # Down
        if (Test-HotkeyCombo -Codes @(38)) { Move-CaptureRegion -DeltaX 0 -DeltaY (-$step) } # Up
    }
})
$pollTimer.Start()

if ($script:Config.AutoCaptureAutoStart) {
    Start-AutoCapture
}

$trayIcon.ShowBalloonTip(2000, 'Region Screenshot Tool', "Ready. Press $($Config.HotkeyName) to capture, $($Config.ClipboardHotkeyName) to copy to clipboard, $($Config.ToggleBorderHotkeyName) to hide/show the border, $($Config.ToggleAutoCaptureHotkeyName) to start/stop auto-capture, or $($Config.StopHotkeyName) to stop. Hold $($Config.MoveModifierName) + arrows to move the region, or $($Config.ResizeModifierName) + arrows to resize it. Right-click the tray icon for options.", [System.Windows.Forms.ToolTipIcon]::Info)

[System.Windows.Forms.Application]::Run()
