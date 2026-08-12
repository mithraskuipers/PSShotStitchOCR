<#
.SYNOPSIS
    Configuration editor for the Region Screenshot Tool.

.DESCRIPTION
    A small form for setting the capture hotkey (a combo of up to 4 keys),
    save location, filename scheme, auto-capture interval and hotkey, and
    an optional automated key press (e.g. F8) sent to the focused app
    either right before or right after each auto-capture shot, used by
    RegionScreenshot.ps1. Writes settings to config.json next to this
    script. If RegionScreenshot.ps1 is already running, use its tray
    menu's "Reload Config" option to pick up changes without restarting it.

.NOTES
    Run via "Configure Screenshot Tool.bat" (handles STA + execution policy).
#>

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host ''
    Write-Host 'ERROR: This script must run in STA mode.' -ForegroundColor Red
    Write-Host 'Use the included "Configure Screenshot Tool.bat", or run manually with:' -ForegroundColor Yellow
    Write-Host '  powershell -STA -NoProfile -ExecutionPolicy Bypass -File Configure.ps1' -ForegroundColor Yellow
    Write-Host ''
    Read-Host 'Press Enter to exit'
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptRoot =
    if ($PSScriptRoot) { $PSScriptRoot }
    elseif ($env:REGION_SCREENSHOT_ROOT) { $env:REGION_SCREENSHOT_ROOT }
    else { (Get-Location).Path }

# See matching comment in RegionScreenshot.ps1: resolve to a real path
# before Split-Path arithmetic, since $env:REGION_SCREENSHOT_ROOT can be a
# literal, non-normalized path containing "..".
if (Test-Path -LiteralPath $ScriptRoot) {
    $ScriptRoot = (Resolve-Path -LiteralPath $ScriptRoot).ProviderPath
}

# One level up from ps1\ - see matching comment in RegionScreenshot.ps1.
$ProjectRoot = Split-Path -Path $ScriptRoot -Parent
if (-not $ProjectRoot) { $ProjectRoot = $ScriptRoot }

$ConfigPath = Join-Path -Path $ScriptRoot -ChildPath 'config.json'

# Same Logs\ folder every tool in the pipeline writes to, so a settings
# change can be traced alongside what RegionScreenshot/PSImgStitcher did.
$LogDir = Join-Path -Path $ProjectRoot -ChildPath 'Logs'
New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue | Out-Null
$script:LogPath = Join-Path -Path $LogDir -ChildPath ("Configure_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
}

trap {
    Write-Log "FATAL: $($_.Exception.Message)"
    Write-Log $_.ScriptStackTrace
    continue
}

Write-Log "Configure started. ConfigPath=$ConfigPath"

# VK codes: Ctrl=17, Shift=16, S=83, Q=81.
$Defaults = [ordered]@{
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
    FineStepPixels               = 1
    LastRegionX                  = 0
    LastRegionY                  = 0
    LastRegionWidth              = 0
    LastRegionHeight             = 0
    SaveLocation                = (Join-Path -Path $ProjectRoot -ChildPath 'screenshots')
    FileNameScheme              = 'screenshot_{timestamp}'
    AutoCaptureIntervalMs      = 1000   # minimum 500
    AutoCaptureAutoStart       = $false
    AutoActionKeyName          = 'F8'
    AutoActionVKCodes          = @(119)   # F8
    AutoActionTiming           = 'After'   # 'Before' or 'After' the screenshot
    AutoActionDelayMs          = 100
    AutoCaptureUseSessionFolders   = $true
    AutoCaptureSessionFolderScheme = 'Session_{date}_{time}'
    AutoLaunchReviewOnStop     = $true
    AutoCaptureDuplicateDetectionEnabled = $true
    AutoCaptureDuplicateThresholdPercent = 99.0
}

function Load-CurrentConfig {
    $cfg = [ordered]@{}
    foreach ($k in $Defaults.Keys) { $cfg[$k] = $Defaults[$k] }
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $loaded = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            foreach ($prop in $loaded.PSObject.Properties) {
                if ($cfg.Contains($prop.Name)) { $cfg[$prop.Name] = $prop.Value }
            }

            # Migrate configs saved by an older version of this tool, which
            # stored a single "HotkeyVKCode" instead of a "HotkeyVKCodes" array.
            if (-not ($loaded.PSObject.Properties.Name -contains 'HotkeyVKCodes') -and
                ($loaded.PSObject.Properties.Name -contains 'HotkeyVKCode')) {
                $cfg.HotkeyVKCodes = @([int]$loaded.HotkeyVKCode)
            }

            # Migrate a config saved by an older version of this tool, which
            # stored the auto-capture interval in whole seconds instead of
            # milliseconds.
            if (-not ($loaded.PSObject.Properties.Name -contains 'AutoCaptureIntervalMs') -and
                ($loaded.PSObject.Properties.Name -contains 'AutoCaptureIntervalSeconds')) {
                $oldSeconds = 0
                [void][int]::TryParse([string]$loaded.AutoCaptureIntervalSeconds, [ref]$oldSeconds)
                if ($oldSeconds -gt 0) { $cfg.AutoCaptureIntervalMs = $oldSeconds * 1000 }
            }
        } catch { }
    }

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

    $cfg.AutoCaptureUseSessionFolders = [bool]$cfg.AutoCaptureUseSessionFolders
    if ([string]::IsNullOrWhiteSpace([string]$cfg.AutoCaptureSessionFolderScheme)) {
        $cfg.AutoCaptureSessionFolderScheme = 'Session_{date}_{time}'
    }
    $cfg.AutoLaunchReviewOnStop = [bool]$cfg.AutoLaunchReviewOnStop

    $intervalMs = 0
    [void][int]::TryParse([string]$cfg.AutoCaptureIntervalMs, [ref]$intervalMs)
    if ($intervalMs -le 0) { $intervalMs = 1000 }
    if ($intervalMs -lt 500) { $intervalMs = 500 }
    $cfg.AutoCaptureIntervalMs = $intervalMs

    $cfg.AutoCaptureDuplicateDetectionEnabled = [bool]$cfg.AutoCaptureDuplicateDetectionEnabled
    $dupThreshold = 0.0
    [void][double]::TryParse([string]$cfg.AutoCaptureDuplicateThresholdPercent, [ref]$dupThreshold)
    if ($dupThreshold -le 0) { $dupThreshold = 99.0 }
    if ($dupThreshold -gt 100) { $dupThreshold = 100.0 }
    $cfg.AutoCaptureDuplicateThresholdPercent = $dupThreshold

    return $cfg
}

$current = Load-CurrentConfig

# ---------------------------------------------------------------------------
# Form layout
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Region Screenshot Tool - Configuration'
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false
$form.MinimizeBox     = $false
$form.ClientSize      = New-Object System.Drawing.Size(480, 1130)
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

$y = 15

# --- Hotkey (combo of up to 4 keys) ---
$lblHotkey = New-Object System.Windows.Forms.Label
$lblHotkey.Text = 'Capture hotkey (click the box, then hold up to 4 keys/mouse buttons):'
$lblHotkey.AutoSize = $true
$lblHotkey.Location = New-Object System.Drawing.Point(15, $y)
$form.Controls.Add($lblHotkey)
$y += 22

$txtHotkey = New-Object System.Windows.Forms.TextBox
$txtHotkey.ReadOnly = $true
$txtHotkey.Location = New-Object System.Drawing.Point(15, $y)
$txtHotkey.Size     = New-Object System.Drawing.Size(300, 24)
$txtHotkey.BackColor = [System.Drawing.Color]::White

# Build the initial combo display from the loaded config.
function Get-KeyNameFromVK([int]$vk) {
    # Map common modifier/control keys to short, friendly names so the
    # resulting "Ctrl + Shift + S" style string stays well under the
    # 63-character limit that Windows enforces on NotifyIcon.Text.
    # VK codes 1/2/4/5/6 are the standard Windows mouse-button virtual
    # keys (left/right/middle/X1/X2) - GetAsyncKeyState recognizes these
    # exactly like keyboard keys, so mouse buttons can be bound the same
    # way as any other key in a combo.
    switch ($vk) {
        16 { return 'Shift' }   # ShiftKey
        17 { return 'Ctrl' }    # ControlKey
        18 { return 'Alt' }     # Menu
        91 { return 'Win' }     # LWin
        92 { return 'Win' }     # RWin
        1  { return 'Mouse Left' }     # VK_LBUTTON
        2  { return 'Mouse Right' }    # VK_RBUTTON
        4  { return 'Mouse Middle' }   # VK_MBUTTON
        5  { return 'Mouse Back' }     # VK_XBUTTON1 (side button)
        6  { return 'Mouse Forward' }  # VK_XBUTTON2 (side button)
        default {
            try {
                $name = ([System.Windows.Forms.Keys]$vk).ToString()
                # Trim common long suffixes from .NET's enum names just in case
                # a less common key still comes back verbose.
                $name = $name -replace 'Key$', ''
                return $name
            }
            catch { return "VK$vk" }
        }
    }
}

# Maps a WinForms mouse button to the matching Windows virtual-key code, or
# 0 if it's not one we let people bind. Left is deliberately excluded -
# it's needed to click into the box in the first place, so it can never be
# captured as part of a combo. Mice with more than five buttons (extra
# buttons beyond Left/Right/Middle/Back/Forward, e.g. a DPI switch) don't
# have standard Windows virtual-key codes for those extra buttons; such
# buttons are usually remapped to a keyboard key by the mouse's own driver
# software, in which case they're captured here as that keyboard key instead.
function Get-MouseVKFromButton([System.Windows.Forms.MouseButtons]$Button) {
    switch ($Button) {
        ([System.Windows.Forms.MouseButtons]::Right)    { return 2 }
        ([System.Windows.Forms.MouseButtons]::Middle)   { return 4 }
        ([System.Windows.Forms.MouseButtons]::XButton1) { return 5 }
        ([System.Windows.Forms.MouseButtons]::XButton2) { return 6 }
        default { return 0 }
    }
}

$script:comboVKCodes = @($current.HotkeyVKCodes)
$script:downKeys     = New-Object 'System.Collections.Generic.List[int]'

function Update-HotkeyDisplay {
    $names = @($script:comboVKCodes | ForEach-Object { Get-KeyNameFromVK $_ })
    $txtHotkey.Text = [string]::Join(' + ', $names)
    $txtHotkey.Tag  = @($script:comboVKCodes)
}
Update-HotkeyDisplay

$txtHotkey.Add_KeyDown({
    param($s, $e)
    $e.SuppressKeyPress = $true
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::None) { return }
    $vk = [int]$e.KeyValue

    # If nothing is currently held, this key starts a brand new combo.
    if ($script:downKeys.Count -eq 0) {
        $script:comboVKCodes = @()
    }
    if (-not $script:downKeys.Contains($vk)) {
        $script:downKeys.Add($vk)
    }
    if (($script:comboVKCodes -notcontains $vk) -and ($script:comboVKCodes.Count -lt 4)) {
        $script:comboVKCodes += $vk
    }
    Update-HotkeyDisplay
})
$txtHotkey.Add_KeyUp({
    param($s, $e)
    $vk = [int]$e.KeyValue
    [void]$script:downKeys.Remove($vk)
})
$txtHotkey.Add_MouseDown({
    param($s, $e)
    $vk = Get-MouseVKFromButton -Button $e.Button
    if ($vk -eq 0) { return }
    if ($script:downKeys.Count -eq 0) {
        $script:comboVKCodes = @()
    }
    if (-not $script:downKeys.Contains($vk)) {
        $script:downKeys.Add($vk)
    }
    if (($script:comboVKCodes -notcontains $vk) -and ($script:comboVKCodes.Count -lt 4)) {
        $script:comboVKCodes += $vk
    }
    Update-HotkeyDisplay
})
$txtHotkey.Add_MouseUp({
    param($s, $e)
    $vk = Get-MouseVKFromButton -Button $e.Button
    if ($vk -ne 0) { [void]$script:downKeys.Remove($vk) }
})
$form.Controls.Add($txtHotkey)

$lblHotkeyHint = New-Object System.Windows.Forms.Label
$lblHotkeyHint.Text = "Hold keys together, e.g. Ctrl+Shift+F9. Side/middle mouse buttons work too."
$lblHotkeyHint.AutoSize = $true
$lblHotkeyHint.ForeColor = [System.Drawing.Color]::Gray
$lblHotkeyHint.Location = New-Object System.Drawing.Point(325, ($y + 4))
$form.Controls.Add($lblHotkeyHint)
$y += 40

# --- Clipboard hotkey (combo of up to 4 keys) ---
$lblClipboardHotkey = New-Object System.Windows.Forms.Label
$lblClipboardHotkey.Text = 'Copy-to-clipboard hotkey (captures without saving to disk):'
$lblClipboardHotkey.AutoSize = $true
$lblClipboardHotkey.Location = New-Object System.Drawing.Point(15, $y)
$form.Controls.Add($lblClipboardHotkey)
$y += 22

$txtClipboardHotkey = New-Object System.Windows.Forms.TextBox
$txtClipboardHotkey.ReadOnly = $true
$txtClipboardHotkey.Location = New-Object System.Drawing.Point(15, $y)
$txtClipboardHotkey.Size     = New-Object System.Drawing.Size(300, 24)
$txtClipboardHotkey.BackColor = [System.Drawing.Color]::White

$script:clipboardComboVKCodes = @($current.ClipboardHotkeyVKCodes)
$script:clipboardDownKeys     = New-Object 'System.Collections.Generic.List[int]'

function Update-ClipboardHotkeyDisplay {
    $names = @($script:clipboardComboVKCodes | ForEach-Object { Get-KeyNameFromVK $_ })
    $txtClipboardHotkey.Text = [string]::Join(' + ', $names)
    $txtClipboardHotkey.Tag  = @($script:clipboardComboVKCodes)
}
Update-ClipboardHotkeyDisplay

$txtClipboardHotkey.Add_KeyDown({
    param($s, $e)
    $e.SuppressKeyPress = $true
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::None) { return }
    $vk = [int]$e.KeyValue

    if ($script:clipboardDownKeys.Count -eq 0) {
        $script:clipboardComboVKCodes = @()
    }
    if (-not $script:clipboardDownKeys.Contains($vk)) {
        $script:clipboardDownKeys.Add($vk)
    }
    if (($script:clipboardComboVKCodes -notcontains $vk) -and ($script:clipboardComboVKCodes.Count -lt 4)) {
        $script:clipboardComboVKCodes += $vk
    }
    Update-ClipboardHotkeyDisplay
})
$txtClipboardHotkey.Add_KeyUp({
    param($s, $e)
    $vk = [int]$e.KeyValue
    [void]$script:clipboardDownKeys.Remove($vk)
})
$txtClipboardHotkey.Add_MouseDown({
    param($s, $e)
    $vk = Get-MouseVKFromButton -Button $e.Button
    if ($vk -eq 0) { return }
    if ($script:clipboardDownKeys.Count -eq 0) {
        $script:clipboardComboVKCodes = @()
    }
    if (-not $script:clipboardDownKeys.Contains($vk)) {
        $script:clipboardDownKeys.Add($vk)
    }
    if (($script:clipboardComboVKCodes -notcontains $vk) -and ($script:clipboardComboVKCodes.Count -lt 4)) {
        $script:clipboardComboVKCodes += $vk
    }
    Update-ClipboardHotkeyDisplay
})
$txtClipboardHotkey.Add_MouseUp({
    param($s, $e)
    $vk = Get-MouseVKFromButton -Button $e.Button
    if ($vk -ne 0) { [void]$script:clipboardDownKeys.Remove($vk) }
})
$form.Controls.Add($txtClipboardHotkey)

$lblClipboardHotkeyHint = New-Object System.Windows.Forms.Label
$lblClipboardHotkeyHint.Text = "e.g. Ctrl+Shift+Alt+S. No file is written to disk. Side/middle mouse buttons work too."
$lblClipboardHotkeyHint.AutoSize = $true
$lblClipboardHotkeyHint.ForeColor = [System.Drawing.Color]::Gray
$lblClipboardHotkeyHint.Location = New-Object System.Drawing.Point(325, ($y + 4))
$form.Controls.Add($lblClipboardHotkeyHint)
$y += 40

# --- Stop hotkey (combo of up to 4 keys) ---
$lblStopHotkey = New-Object System.Windows.Forms.Label
$lblStopHotkey.Text = 'Stop hotkey (click the box, then hold up to 4 keys/mouse buttons):'
$lblStopHotkey.AutoSize = $true
$lblStopHotkey.Location = New-Object System.Drawing.Point(15, $y)
$form.Controls.Add($lblStopHotkey)
$y += 22

$txtStopHotkey = New-Object System.Windows.Forms.TextBox
$txtStopHotkey.ReadOnly = $true
$txtStopHotkey.Location = New-Object System.Drawing.Point(15, $y)
$txtStopHotkey.Size     = New-Object System.Drawing.Size(300, 24)
$txtStopHotkey.BackColor = [System.Drawing.Color]::White

$script:stopComboVKCodes = @($current.StopHotkeyVKCodes)
$script:stopDownKeys     = New-Object 'System.Collections.Generic.List[int]'

function Update-StopHotkeyDisplay {
    $names = @($script:stopComboVKCodes | ForEach-Object { Get-KeyNameFromVK $_ })
    $txtStopHotkey.Text = [string]::Join(' + ', $names)
    $txtStopHotkey.Tag  = @($script:stopComboVKCodes)
}
Update-StopHotkeyDisplay

$txtStopHotkey.Add_KeyDown({
    param($s, $e)
    $e.SuppressKeyPress = $true
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::None) { return }
    $vk = [int]$e.KeyValue

    if ($script:stopDownKeys.Count -eq 0) {
        $script:stopComboVKCodes = @()
    }
    if (-not $script:stopDownKeys.Contains($vk)) {
        $script:stopDownKeys.Add($vk)
    }
    if (($script:stopComboVKCodes -notcontains $vk) -and ($script:stopComboVKCodes.Count -lt 4)) {
        $script:stopComboVKCodes += $vk
    }
    Update-StopHotkeyDisplay
})
$txtStopHotkey.Add_KeyUp({
    param($s, $e)
    $vk = [int]$e.KeyValue
    [void]$script:stopDownKeys.Remove($vk)
})
$txtStopHotkey.Add_MouseDown({
    param($s, $e)
    $vk = Get-MouseVKFromButton -Button $e.Button
    if ($vk -eq 0) { return }
    if ($script:stopDownKeys.Count -eq 0) {
        $script:stopComboVKCodes = @()
    }
    if (-not $script:stopDownKeys.Contains($vk)) {
        $script:stopDownKeys.Add($vk)
    }
    if (($script:stopComboVKCodes -notcontains $vk) -and ($script:stopComboVKCodes.Count -lt 4)) {
        $script:stopComboVKCodes += $vk
    }
    Update-StopHotkeyDisplay
})
$txtStopHotkey.Add_MouseUp({
    param($s, $e)
    $vk = Get-MouseVKFromButton -Button $e.Button
    if ($vk -ne 0) { [void]$script:stopDownKeys.Remove($vk) }
})
$form.Controls.Add($txtStopHotkey)

$lblStopHotkeyHint = New-Object System.Windows.Forms.Label
$lblStopHotkeyHint.Text = "Quits the tool entirely (finishes/hands off any running auto-capture session first) - use instead of closing the window. Side/middle mouse buttons work too."
$lblStopHotkeyHint.AutoSize = $true
$lblStopHotkeyHint.ForeColor = [System.Drawing.Color]::Gray
$lblStopHotkeyHint.Location = New-Object System.Drawing.Point(325, ($y + 4))
$form.Controls.Add($lblStopHotkeyHint)
$y += 40

# --- Toggle border hotkey (combo of up to 4 keys) ---
$lblToggleHotkey = New-Object System.Windows.Forms.Label
$lblToggleHotkey.Text = 'Show/hide region border hotkey (click the box, then hold up to 4 keys/mouse buttons):'
$lblToggleHotkey.AutoSize = $true
$lblToggleHotkey.Location = New-Object System.Drawing.Point(15, $y)
$form.Controls.Add($lblToggleHotkey)
$y += 22

$txtToggleHotkey = New-Object System.Windows.Forms.TextBox
$txtToggleHotkey.ReadOnly = $true
$txtToggleHotkey.Location = New-Object System.Drawing.Point(15, $y)
$txtToggleHotkey.Size     = New-Object System.Drawing.Size(300, 24)
$txtToggleHotkey.BackColor = [System.Drawing.Color]::White

$script:toggleComboVKCodes = @($current.ToggleBorderHotkeyVKCodes)
$script:toggleDownKeys     = New-Object 'System.Collections.Generic.List[int]'

function Update-ToggleHotkeyDisplay {
    $names = @($script:toggleComboVKCodes | ForEach-Object { Get-KeyNameFromVK $_ })
    $txtToggleHotkey.Text = [string]::Join(' + ', $names)
    $txtToggleHotkey.Tag  = @($script:toggleComboVKCodes)
}
Update-ToggleHotkeyDisplay

$txtToggleHotkey.Add_KeyDown({
    param($s, $e)
    $e.SuppressKeyPress = $true
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::None) { return }
    $vk = [int]$e.KeyValue

    if ($script:toggleDownKeys.Count -eq 0) {
        $script:toggleComboVKCodes = @()
    }
    if (-not $script:toggleDownKeys.Contains($vk)) {
        $script:toggleDownKeys.Add($vk)
    }
    if (($script:toggleComboVKCodes -notcontains $vk) -and ($script:toggleComboVKCodes.Count -lt 4)) {
        $script:toggleComboVKCodes += $vk
    }
    Update-ToggleHotkeyDisplay
})
$txtToggleHotkey.Add_KeyUp({
    param($s, $e)
    $vk = [int]$e.KeyValue
    [void]$script:toggleDownKeys.Remove($vk)
})
$txtToggleHotkey.Add_MouseDown({
    param($s, $e)
    $vk = Get-MouseVKFromButton -Button $e.Button
    if ($vk -eq 0) { return }
    if ($script:toggleDownKeys.Count -eq 0) {
        $script:toggleComboVKCodes = @()
    }
    if (-not $script:toggleDownKeys.Contains($vk)) {
        $script:toggleDownKeys.Add($vk)
    }
    if (($script:toggleComboVKCodes -notcontains $vk) -and ($script:toggleComboVKCodes.Count -lt 4)) {
        $script:toggleComboVKCodes += $vk
    }
    Update-ToggleHotkeyDisplay
})
$txtToggleHotkey.Add_MouseUp({
    param($s, $e)
    $vk = Get-MouseVKFromButton -Button $e.Button
    if ($vk -ne 0) { [void]$script:toggleDownKeys.Remove($vk) }
})
$form.Controls.Add($txtToggleHotkey)

$lblToggleHotkeyHint = New-Object System.Windows.Forms.Label
$lblToggleHotkeyHint.Text = "Shows or hides the red region outline. Default: Ctrl+Shift+H. Side/middle mouse buttons work too."
$lblToggleHotkeyHint.AutoSize = $true
$lblToggleHotkeyHint.ForeColor = [System.Drawing.Color]::Gray
$lblToggleHotkeyHint.Location = New-Object System.Drawing.Point(325, ($y + 4))
$form.Controls.Add($lblToggleHotkeyHint)
$y += 40

# --- Toggle auto-capture hotkey (combo of up to 4 keys) ---
$lblToggleAutoCaptureHotkey = New-Object System.Windows.Forms.Label
$lblToggleAutoCaptureHotkey.Text = 'Start/stop auto-capture hotkey (click the box, then hold up to 4 keys/mouse buttons):'
$lblToggleAutoCaptureHotkey.AutoSize = $true
$lblToggleAutoCaptureHotkey.Location = New-Object System.Drawing.Point(15, $y)
$form.Controls.Add($lblToggleAutoCaptureHotkey)
$y += 22

$txtToggleAutoCaptureHotkey = New-Object System.Windows.Forms.TextBox
$txtToggleAutoCaptureHotkey.ReadOnly = $true
$txtToggleAutoCaptureHotkey.Location = New-Object System.Drawing.Point(15, $y)
$txtToggleAutoCaptureHotkey.Size     = New-Object System.Drawing.Size(300, 24)
$txtToggleAutoCaptureHotkey.BackColor = [System.Drawing.Color]::White

$script:toggleAutoCaptureComboVKCodes = @($current.ToggleAutoCaptureHotkeyVKCodes)
$script:toggleAutoCaptureDownKeys     = New-Object 'System.Collections.Generic.List[int]'

function Update-ToggleAutoCaptureHotkeyDisplay {
    $names = @($script:toggleAutoCaptureComboVKCodes | ForEach-Object { Get-KeyNameFromVK $_ })
    $txtToggleAutoCaptureHotkey.Text = [string]::Join(' + ', $names)
    $txtToggleAutoCaptureHotkey.Tag  = @($script:toggleAutoCaptureComboVKCodes)
}
Update-ToggleAutoCaptureHotkeyDisplay

$txtToggleAutoCaptureHotkey.Add_KeyDown({
    param($s, $e)
    $e.SuppressKeyPress = $true
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::None) { return }
    $vk = [int]$e.KeyValue

    if ($script:toggleAutoCaptureDownKeys.Count -eq 0) {
        $script:toggleAutoCaptureComboVKCodes = @()
    }
    if (-not $script:toggleAutoCaptureDownKeys.Contains($vk)) {
        $script:toggleAutoCaptureDownKeys.Add($vk)
    }
    if (($script:toggleAutoCaptureComboVKCodes -notcontains $vk) -and ($script:toggleAutoCaptureComboVKCodes.Count -lt 4)) {
        $script:toggleAutoCaptureComboVKCodes += $vk
    }
    Update-ToggleAutoCaptureHotkeyDisplay
})
$txtToggleAutoCaptureHotkey.Add_KeyUp({
    param($s, $e)
    $vk = [int]$e.KeyValue
    [void]$script:toggleAutoCaptureDownKeys.Remove($vk)
})
$txtToggleAutoCaptureHotkey.Add_MouseDown({
    param($s, $e)
    $vk = Get-MouseVKFromButton -Button $e.Button
    if ($vk -eq 0) { return }
    if ($script:toggleAutoCaptureDownKeys.Count -eq 0) {
        $script:toggleAutoCaptureComboVKCodes = @()
    }
    if (-not $script:toggleAutoCaptureDownKeys.Contains($vk)) {
        $script:toggleAutoCaptureDownKeys.Add($vk)
    }
    if (($script:toggleAutoCaptureComboVKCodes -notcontains $vk) -and ($script:toggleAutoCaptureComboVKCodes.Count -lt 4)) {
        $script:toggleAutoCaptureComboVKCodes += $vk
    }
    Update-ToggleAutoCaptureHotkeyDisplay
})
$txtToggleAutoCaptureHotkey.Add_MouseUp({
    param($s, $e)
    $vk = Get-MouseVKFromButton -Button $e.Button
    if ($vk -ne 0) { [void]$script:toggleAutoCaptureDownKeys.Remove($vk) }
})
$form.Controls.Add($txtToggleAutoCaptureHotkey)

$lblToggleAutoCaptureHotkeyHint = New-Object System.Windows.Forms.Label
$lblToggleAutoCaptureHotkeyHint.Text = "Starts/stops timed auto-capture (see below). Default: Ctrl+Shift+A. Side/middle mouse buttons work too."
$lblToggleAutoCaptureHotkeyHint.AutoSize = $true
$lblToggleAutoCaptureHotkeyHint.ForeColor = [System.Drawing.Color]::Gray
$lblToggleAutoCaptureHotkeyHint.Location = New-Object System.Drawing.Point(325, ($y + 4))
$form.Controls.Add($lblToggleAutoCaptureHotkeyHint)
$y += 40

# --- Move-region modifier (combo of up to 4 keys, held + arrow keys) ---
$lblMoveModifier = New-Object System.Windows.Forms.Label
$lblMoveModifier.Text = 'Move region: hold this + an arrow key (click box, hold up to 4 keys/mouse buttons):'
$lblMoveModifier.AutoSize = $true
$lblMoveModifier.Location = New-Object System.Drawing.Point(15, $y)
$form.Controls.Add($lblMoveModifier)
$y += 22

$txtMoveModifier = New-Object System.Windows.Forms.TextBox
$txtMoveModifier.ReadOnly = $true
$txtMoveModifier.Location = New-Object System.Drawing.Point(15, $y)
$txtMoveModifier.Size     = New-Object System.Drawing.Size(300, 24)
$txtMoveModifier.BackColor = [System.Drawing.Color]::White

$script:moveComboVKCodes = @($current.MoveModifierVKCodes)
$script:moveDownKeys     = New-Object 'System.Collections.Generic.List[int]'

function Update-MoveModifierDisplay {
    $names = @($script:moveComboVKCodes | ForEach-Object { Get-KeyNameFromVK $_ })
    $txtMoveModifier.Text = [string]::Join(' + ', $names)
    $txtMoveModifier.Tag  = @($script:moveComboVKCodes)
}
Update-MoveModifierDisplay

$txtMoveModifier.Add_KeyDown({
    param($s, $e)
    $e.SuppressKeyPress = $true
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::None) { return }
    $vk = [int]$e.KeyValue

    if ($script:moveDownKeys.Count -eq 0) {
        $script:moveComboVKCodes = @()
    }
    if (-not $script:moveDownKeys.Contains($vk)) {
        $script:moveDownKeys.Add($vk)
    }
    if (($script:moveComboVKCodes -notcontains $vk) -and ($script:moveComboVKCodes.Count -lt 4)) {
        $script:moveComboVKCodes += $vk
    }
    Update-MoveModifierDisplay
})
$txtMoveModifier.Add_KeyUp({
    param($s, $e)
    $vk = [int]$e.KeyValue
    [void]$script:moveDownKeys.Remove($vk)
})
$txtMoveModifier.Add_MouseDown({
    param($s, $e)
    $vk = Get-MouseVKFromButton -Button $e.Button
    if ($vk -eq 0) { return }
    if ($script:moveDownKeys.Count -eq 0) {
        $script:moveComboVKCodes = @()
    }
    if (-not $script:moveDownKeys.Contains($vk)) {
        $script:moveDownKeys.Add($vk)
    }
    if (($script:moveComboVKCodes -notcontains $vk) -and ($script:moveComboVKCodes.Count -lt 4)) {
        $script:moveComboVKCodes += $vk
    }
    Update-MoveModifierDisplay
})
$txtMoveModifier.Add_MouseUp({
    param($s, $e)
    $vk = Get-MouseVKFromButton -Button $e.Button
    if ($vk -ne 0) { [void]$script:moveDownKeys.Remove($vk) }
})
$form.Controls.Add($txtMoveModifier)

$lblMoveModifierHint = New-Object System.Windows.Forms.Label
$lblMoveModifierHint.Text = "e.g. hold Ctrl+Alt, then tap an arrow key to nudge the region. Side/middle mouse buttons work too."
$lblMoveModifierHint.AutoSize = $true
$lblMoveModifierHint.ForeColor = [System.Drawing.Color]::Gray
$lblMoveModifierHint.Location = New-Object System.Drawing.Point(325, ($y + 4))
$form.Controls.Add($lblMoveModifierHint)
$y += 40

# --- Resize-region modifier (combo of up to 4 keys, held + arrow keys) ---
$lblResizeModifier = New-Object System.Windows.Forms.Label
$lblResizeModifier.Text = 'Resize region: hold this + an arrow key (click box, hold up to 4 keys/mouse buttons):'
$lblResizeModifier.AutoSize = $true
$lblResizeModifier.Location = New-Object System.Drawing.Point(15, $y)
$form.Controls.Add($lblResizeModifier)
$y += 22

$txtResizeModifier = New-Object System.Windows.Forms.TextBox
$txtResizeModifier.ReadOnly = $true
$txtResizeModifier.Location = New-Object System.Drawing.Point(15, $y)
$txtResizeModifier.Size     = New-Object System.Drawing.Size(300, 24)
$txtResizeModifier.BackColor = [System.Drawing.Color]::White

$script:resizeComboVKCodes = @($current.ResizeModifierVKCodes)
$script:resizeDownKeys     = New-Object 'System.Collections.Generic.List[int]'

function Update-ResizeModifierDisplay {
    $names = @($script:resizeComboVKCodes | ForEach-Object { Get-KeyNameFromVK $_ })
    $txtResizeModifier.Text = [string]::Join(' + ', $names)
    $txtResizeModifier.Tag  = @($script:resizeComboVKCodes)
}
Update-ResizeModifierDisplay

$txtResizeModifier.Add_KeyDown({
    param($s, $e)
    $e.SuppressKeyPress = $true
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::None) { return }
    $vk = [int]$e.KeyValue

    if ($script:resizeDownKeys.Count -eq 0) {
        $script:resizeComboVKCodes = @()
    }
    if (-not $script:resizeDownKeys.Contains($vk)) {
        $script:resizeDownKeys.Add($vk)
    }
    if (($script:resizeComboVKCodes -notcontains $vk) -and ($script:resizeComboVKCodes.Count -lt 4)) {
        $script:resizeComboVKCodes += $vk
    }
    Update-ResizeModifierDisplay
})
$txtResizeModifier.Add_KeyUp({
    param($s, $e)
    $vk = [int]$e.KeyValue
    [void]$script:resizeDownKeys.Remove($vk)
})
$txtResizeModifier.Add_MouseDown({
    param($s, $e)
    $vk = Get-MouseVKFromButton -Button $e.Button
    if ($vk -eq 0) { return }
    if ($script:resizeDownKeys.Count -eq 0) {
        $script:resizeComboVKCodes = @()
    }
    if (-not $script:resizeDownKeys.Contains($vk)) {
        $script:resizeDownKeys.Add($vk)
    }
    if (($script:resizeComboVKCodes -notcontains $vk) -and ($script:resizeComboVKCodes.Count -lt 4)) {
        $script:resizeComboVKCodes += $vk
    }
    Update-ResizeModifierDisplay
})
$txtResizeModifier.Add_MouseUp({
    param($s, $e)
    $vk = Get-MouseVKFromButton -Button $e.Button
    if ($vk -ne 0) { [void]$script:resizeDownKeys.Remove($vk) }
})
$form.Controls.Add($txtResizeModifier)

$lblResizeModifierHint = New-Object System.Windows.Forms.Label
$lblResizeModifierHint.Text = "e.g. hold Ctrl+Alt+Shift, then tap an arrow key to grow/shrink it. Side/middle mouse buttons work too."
$lblResizeModifierHint.AutoSize = $true
$lblResizeModifierHint.ForeColor = [System.Drawing.Color]::Gray
$lblResizeModifierHint.Location = New-Object System.Drawing.Point(325, ($y + 4))
$form.Controls.Add($lblResizeModifierHint)
$y += 40

# --- Move/resize step size ---
$lblMoveStep = New-Object System.Windows.Forms.Label
$lblMoveStep.Text = 'Hold-to-repeat step (pixels per tick once held):'
$lblMoveStep.AutoSize = $true
$lblMoveStep.Location = New-Object System.Drawing.Point(15, ($y + 3))
$form.Controls.Add($lblMoveStep)

$numMoveStep = New-Object System.Windows.Forms.NumericUpDown
$numMoveStep.Location = New-Object System.Drawing.Point(300, $y)
$numMoveStep.Size     = New-Object System.Drawing.Size(70, 24)
$numMoveStep.Minimum  = 1
$numMoveStep.Maximum  = 500
$numMoveStep.Value    = [Math]::Max(1, [int]$current.MoveResizeStepPixels)
$form.Controls.Add($numMoveStep)
$y += 32

# --- Fine (tap) step size ---
$lblFineStep = New-Object System.Windows.Forms.Label
$lblFineStep.Text = 'Tap step (pixels per quick press, for precise nudging):'
$lblFineStep.AutoSize = $true
$lblFineStep.Location = New-Object System.Drawing.Point(15, ($y + 3))
$form.Controls.Add($lblFineStep)

$numFineStep = New-Object System.Windows.Forms.NumericUpDown
$numFineStep.Location = New-Object System.Drawing.Point(300, $y)
$numFineStep.Size     = New-Object System.Drawing.Size(70, 24)
$numFineStep.Minimum  = 1
$numFineStep.Maximum  = 100
$numFineStep.Value    = [Math]::Max(1, [int]$current.FineStepPixels)
$form.Controls.Add($numFineStep)
$y += 40

# --- Save location ---
$lblSave = New-Object System.Windows.Forms.Label
$lblSave.Text = 'Save location:'
$lblSave.AutoSize = $true
$lblSave.Location = New-Object System.Drawing.Point(15, $y)
$form.Controls.Add($lblSave)
$y += 22

$txtSave = New-Object System.Windows.Forms.TextBox
$txtSave.Location = New-Object System.Drawing.Point(15, $y)
$txtSave.Size     = New-Object System.Drawing.Size(345, 24)
$txtSave.Text     = $current.SaveLocation
$form.Controls.Add($txtSave)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text     = 'Browse...'
$btnBrowse.Location = New-Object System.Drawing.Point(370, ($y - 1))
$btnBrowse.Size     = New-Object System.Drawing.Size(90, 26)
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose a folder for saved screenshots'
    if (-not [string]::IsNullOrWhiteSpace($txtSave.Text) -and (Test-Path -LiteralPath $txtSave.Text)) { $dlg.SelectedPath = $txtSave.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtSave.Text = $dlg.SelectedPath
    }
})
$form.Controls.Add($btnBrowse)
$y += 40

# --- Filename scheme ---
$lblScheme = New-Object System.Windows.Forms.Label
$lblScheme.Text = 'Filename scheme (.png is added automatically):'
$lblScheme.AutoSize = $true
$lblScheme.Location = New-Object System.Drawing.Point(15, $y)
$form.Controls.Add($lblScheme)
$y += 22

$txtScheme = New-Object System.Windows.Forms.TextBox
$txtScheme.Location = New-Object System.Drawing.Point(15, $y)
$txtScheme.Size     = New-Object System.Drawing.Size(445, 24)
$txtScheme.Text     = $current.FileNameScheme
$form.Controls.Add($txtScheme)
$y += 30

$lblTokens = New-Object System.Windows.Forms.Label
$lblTokens.Text = "Tokens: {timestamp}  {date}  {time}  {counter} or {counter:N} for N digits"
$lblTokens.AutoSize = $true
$lblTokens.ForeColor = [System.Drawing.Color]::Gray
$lblTokens.Location = New-Object System.Drawing.Point(15, $y)
$form.Controls.Add($lblTokens)
$y += 22

$lblPreview = New-Object System.Windows.Forms.Label
$lblPreview.AutoSize = $true
$lblPreview.ForeColor = [System.Drawing.Color]::DarkBlue
$lblPreview.Location = New-Object System.Drawing.Point(15, $y)
$form.Controls.Add($lblPreview)

function Update-Preview {
    $now = Get-Date
    $sample = $txtScheme.Text
    $sample = $sample -replace '\{timestamp\}', $now.ToString('yyyyMMdd_HHmmss_fff')
    $sample = $sample -replace '\{date\}',      $now.ToString('yyyyMMdd')
    $sample = $sample -replace '\{time\}',      $now.ToString('HHmmss')
    $sample = $sample -replace '\{counter:(\d+)\}', '0001'
    $sample = $sample -replace '\{counter\}', '0001'
    $sample = $sample -replace '(?i)\.png$', ''
    $lblPreview.Text = "Example: $sample.png"
}
$txtScheme.Add_TextChanged({ Update-Preview })
Update-Preview
$y += 35

# --- Automatic screenshots ---
$grpAuto = New-Object System.Windows.Forms.GroupBox
$grpAuto.Text     = 'Automatic screenshots'
$grpAuto.Location = New-Object System.Drawing.Point(15, $y)
$grpAuto.Size     = New-Object System.Drawing.Size(445, 400)
$form.Controls.Add($grpAuto)

# What key combination to auto-press.
$lblActionKey = New-Object System.Windows.Forms.Label
$lblActionKey.Text = 'Key combination to auto-press - keyboard only (optional - leave empty to disable):'
$lblActionKey.AutoSize = $true
$lblActionKey.Location = New-Object System.Drawing.Point(15, 25)
$grpAuto.Controls.Add($lblActionKey)

$txtActionKey = New-Object System.Windows.Forms.TextBox
$txtActionKey.ReadOnly = $true
$txtActionKey.Location = New-Object System.Drawing.Point(15, 45)
$txtActionKey.Size     = New-Object System.Drawing.Size(220, 24)
$txtActionKey.BackColor = [System.Drawing.Color]::White

$script:actionComboVKCodes = @($current.AutoActionVKCodes)
$script:actionDownKeys     = New-Object 'System.Collections.Generic.List[int]'

function Update-ActionKeyDisplay {
    $names = @($script:actionComboVKCodes | ForEach-Object { Get-KeyNameFromVK $_ })
    $txtActionKey.Text = [string]::Join(' + ', $names)
    $txtActionKey.Tag  = @($script:actionComboVKCodes)
}
Update-ActionKeyDisplay

$txtActionKey.Add_KeyDown({
    param($s, $e)
    $e.SuppressKeyPress = $true
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::None) { return }
    $vk = [int]$e.KeyValue

    if ($script:actionDownKeys.Count -eq 0) {
        $script:actionComboVKCodes = @()
    }
    if (-not $script:actionDownKeys.Contains($vk)) {
        $script:actionDownKeys.Add($vk)
    }
    if (($script:actionComboVKCodes -notcontains $vk) -and ($script:actionComboVKCodes.Count -lt 4)) {
        $script:actionComboVKCodes += $vk
    }
    Update-ActionKeyDisplay
})
$txtActionKey.Add_KeyUp({
    param($s, $e)
    $vk = [int]$e.KeyValue
    [void]$script:actionDownKeys.Remove($vk)
})
$grpAuto.Controls.Add($txtActionKey)

$btnActionClear = New-Object System.Windows.Forms.Button
$btnActionClear.Text     = 'Clear'
$btnActionClear.Location = New-Object System.Drawing.Point(245, 44)
$btnActionClear.Size     = New-Object System.Drawing.Size(60, 26)
$btnActionClear.Add_Click({
    $script:actionComboVKCodes = @()
    $script:actionDownKeys.Clear()
    Update-ActionKeyDisplay
})
$grpAuto.Controls.Add($btnActionClear)

$lblActionHint = New-Object System.Windows.Forms.Label
$lblActionHint.Text = "e.g. F8"
$lblActionHint.AutoSize = $true
$lblActionHint.ForeColor = [System.Drawing.Color]::Gray
$lblActionHint.Location = New-Object System.Drawing.Point(320, 49)
$grpAuto.Controls.Add($lblActionHint)

# Before or after each screenshot.
$lblTiming = New-Object System.Windows.Forms.Label
$lblTiming.Text = 'Press it:'
$lblTiming.AutoSize = $true
$lblTiming.Location = New-Object System.Drawing.Point(15, 82)
$grpAuto.Controls.Add($lblTiming)

$radioBefore = New-Object System.Windows.Forms.RadioButton
$radioBefore.Text     = 'Before the screenshot'
$radioBefore.AutoSize = $true
$radioBefore.Location = New-Object System.Drawing.Point(85, 80)
$radioBefore.Checked  = ($current.AutoActionTiming -ne 'After')
$grpAuto.Controls.Add($radioBefore)

$radioAfter = New-Object System.Windows.Forms.RadioButton
$radioAfter.Text     = 'After the screenshot'
$radioAfter.AutoSize = $true
$radioAfter.Location = New-Object System.Drawing.Point(255, 80)
$radioAfter.Checked  = ($current.AutoActionTiming -eq 'After')
$grpAuto.Controls.Add($radioAfter)

# Delay between the key press and the screenshot.
$lblActionDelay = New-Object System.Windows.Forms.Label
$lblActionDelay.Text = 'Delay between the key press and the screenshot (ms):'
$lblActionDelay.AutoSize = $true
$lblActionDelay.Location = New-Object System.Drawing.Point(15, 113)
$grpAuto.Controls.Add($lblActionDelay)

$numActionDelay = New-Object System.Windows.Forms.NumericUpDown
$numActionDelay.Location = New-Object System.Drawing.Point(15, 133)
$numActionDelay.Size     = New-Object System.Drawing.Size(80, 24)
$numActionDelay.Minimum  = 0
$numActionDelay.Maximum  = 60000
$numActionDelay.Increment = 50
$numActionDelay.Value    = [Math]::Max(0, [int]$current.AutoActionDelayMs)
$grpAuto.Controls.Add($numActionDelay)

$sep = New-Object System.Windows.Forms.Label
$sep.BorderStyle = 'Fixed3D'
$sep.Location    = New-Object System.Drawing.Point(15, 168)
$sep.Size        = New-Object System.Drawing.Size(415, 2)
$grpAuto.Controls.Add($sep)

# Delay between screenshots.
$lblInterval = New-Object System.Windows.Forms.Label
$lblInterval.Text = 'Time between screenshots (milliseconds, minimum 500):'
$lblInterval.AutoSize = $true
$lblInterval.Location = New-Object System.Drawing.Point(15, 180)
$grpAuto.Controls.Add($lblInterval)

$numInterval = New-Object System.Windows.Forms.NumericUpDown
$numInterval.Location  = New-Object System.Drawing.Point(15, 200)
$numInterval.Size      = New-Object System.Drawing.Size(90, 24)
$numInterval.Minimum   = 500
$numInterval.Maximum   = 86400000
$numInterval.Increment = 100
$numInterval.Value     = [Math]::Max(500, [int]$current.AutoCaptureIntervalMs)
$grpAuto.Controls.Add($numInterval)

$chkAutoStart = New-Object System.Windows.Forms.CheckBox
$chkAutoStart.Text     = 'Start automatically when the tool launches'
$chkAutoStart.AutoSize = $true
$chkAutoStart.Location = New-Object System.Drawing.Point(150, 203)
$chkAutoStart.Checked  = [bool]$current.AutoCaptureAutoStart
$grpAuto.Controls.Add($chkAutoStart)

$sep2 = New-Object System.Windows.Forms.Label
$sep2.BorderStyle = 'Fixed3D'
$sep2.Location    = New-Object System.Drawing.Point(15, 233)
$sep2.Size        = New-Object System.Drawing.Size(415, 2)
$grpAuto.Controls.Add($sep2)

# Session folders: each auto-capture run saves into its own timestamped
# subfolder, which is what gets handed off to Review & Stitch when
# auto-capture stops.
$chkSessionFolders = New-Object System.Windows.Forms.CheckBox
$chkSessionFolders.Text     = 'Save each auto-capture run to its own session folder'
$chkSessionFolders.AutoSize = $true
$chkSessionFolders.Location = New-Object System.Drawing.Point(15, 245)
$chkSessionFolders.Checked  = [bool]$current.AutoCaptureUseSessionFolders
$grpAuto.Controls.Add($chkSessionFolders)

$lblSessionScheme = New-Object System.Windows.Forms.Label
$lblSessionScheme.Text = 'Session folder name ({date}, {time}, {timestamp}):'
$lblSessionScheme.AutoSize = $true
$lblSessionScheme.Location = New-Object System.Drawing.Point(15, 271)
$grpAuto.Controls.Add($lblSessionScheme)

$txtSessionScheme = New-Object System.Windows.Forms.TextBox
$txtSessionScheme.Text     = [string]$current.AutoCaptureSessionFolderScheme
$txtSessionScheme.Location = New-Object System.Drawing.Point(15, 291)
$txtSessionScheme.Size     = New-Object System.Drawing.Size(300, 22)
$txtSessionScheme.Enabled  = $chkSessionFolders.Checked
$grpAuto.Controls.Add($txtSessionScheme)
$chkSessionFolders.Add_CheckedChanged({ $txtSessionScheme.Enabled = $chkSessionFolders.Checked })

$chkAutoLaunchReview = New-Object System.Windows.Forms.CheckBox
$chkAutoLaunchReview.Text     = 'Open Review & Stitch when auto-capture stops'
$chkAutoLaunchReview.AutoSize = $true
$chkAutoLaunchReview.Location = New-Object System.Drawing.Point(15, 317)
$chkAutoLaunchReview.Checked  = [bool]$current.AutoLaunchReviewOnStop
$grpAuto.Controls.Add($chkAutoLaunchReview)

$sep3 = New-Object System.Windows.Forms.Label
$sep3.BorderStyle = 'Fixed3D'
$sep3.Location    = New-Object System.Drawing.Point(15, 341)
$sep3.Size        = New-Object System.Drawing.Size(415, 2)
$grpAuto.Controls.Add($sep3)

# Duplicate-frame pause: compares each new auto-capture shot against the
# previous one and, if they're too similar, pauses and asks whether to
# stop or keep going - catches a stalled/idle capture instead of silently
# filling a session folder with near-identical shots.
$chkDuplicatePause = New-Object System.Windows.Forms.CheckBox
$chkDuplicatePause.Text     = 'Pause and ask if a shot looks like a duplicate of the last one'
$chkDuplicatePause.AutoSize = $true
$chkDuplicatePause.Location = New-Object System.Drawing.Point(15, 353)
$chkDuplicatePause.Checked  = [bool]$current.AutoCaptureDuplicateDetectionEnabled
$grpAuto.Controls.Add($chkDuplicatePause)

$lblDuplicateThreshold = New-Object System.Windows.Forms.Label
$lblDuplicateThreshold.Text = 'Similarity threshold (%):'
$lblDuplicateThreshold.AutoSize = $true
$lblDuplicateThreshold.Location = New-Object System.Drawing.Point(35, 378)
$grpAuto.Controls.Add($lblDuplicateThreshold)

$numDuplicateThreshold = New-Object System.Windows.Forms.NumericUpDown
$numDuplicateThreshold.Location      = New-Object System.Drawing.Point(175, 376)
$numDuplicateThreshold.Size          = New-Object System.Drawing.Size(70, 24)
$numDuplicateThreshold.DecimalPlaces = 1
$numDuplicateThreshold.Increment     = 0.5
$numDuplicateThreshold.Minimum       = 50
$numDuplicateThreshold.Maximum       = 100
$numDuplicateThreshold.Value         = [Math]::Min(100, [Math]::Max(50, [decimal][double]$current.AutoCaptureDuplicateThresholdPercent))
$numDuplicateThreshold.Enabled       = $chkDuplicatePause.Checked
$grpAuto.Controls.Add($numDuplicateThreshold)
$chkDuplicatePause.Add_CheckedChanged({ $numDuplicateThreshold.Enabled = $chkDuplicatePause.Checked })

$lblDuplicateHint = New-Object System.Windows.Forms.Label
$lblDuplicateHint.Text = '99 = only near-identical; lower it to catch smaller changes.'
$lblDuplicateHint.AutoSize = $true
$lblDuplicateHint.ForeColor = [System.Drawing.Color]::Gray
$lblDuplicateHint.Location = New-Object System.Drawing.Point(255, 379)
$grpAuto.Controls.Add($lblDuplicateHint)

$y += 410

# --- Buttons ---
$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text     = 'Save'
$btnSave.Location = New-Object System.Drawing.Point(215, $y)
$btnSave.Size     = New-Object System.Drawing.Size(110, 30)
$btnSave.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtSave.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Please choose a save location.', 'Region Screenshot Tool') | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($txtScheme.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Please enter a filename scheme.', 'Region Screenshot Tool') | Out-Null
        return
    }
    if ($chkSessionFolders.Checked -and [string]::IsNullOrWhiteSpace($txtSessionScheme.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Please enter a session folder name scheme.', 'Region Screenshot Tool') | Out-Null
        return
    }
    if (-not $txtHotkey.Tag -or @($txtHotkey.Tag).Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Please set a capture hotkey.', 'Region Screenshot Tool') | Out-Null
        return
    }
    if (-not $txtClipboardHotkey.Tag -or @($txtClipboardHotkey.Tag).Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Please set a copy-to-clipboard hotkey.', 'Region Screenshot Tool') | Out-Null
        return
    }
    if (-not $txtStopHotkey.Tag -or @($txtStopHotkey.Tag).Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Please set a stop hotkey.', 'Region Screenshot Tool') | Out-Null
        return
    }
    if (-not $txtToggleHotkey.Tag -or @($txtToggleHotkey.Tag).Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Please set a show/hide region border hotkey.', 'Region Screenshot Tool') | Out-Null
        return
    }
    if (-not $txtToggleAutoCaptureHotkey.Tag -or @($txtToggleAutoCaptureHotkey.Tag).Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Please set a start/stop auto-capture hotkey.', 'Region Screenshot Tool') | Out-Null
        return
    }
    if (-not $txtMoveModifier.Tag -or @($txtMoveModifier.Tag).Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Please set a move-region modifier.', 'Region Screenshot Tool') | Out-Null
        return
    }
    if (-not $txtResizeModifier.Tag -or @($txtResizeModifier.Tag).Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Please set a resize-region modifier.', 'Region Screenshot Tool') | Out-Null
        return
    }

    # Every hotkey/modifier combo must be distinct from every other one, or
    # pressing one would ambiguously trigger more than one action.
    $namedCombos = [ordered]@{
        'capture hotkey'            = @($txtHotkey.Tag) | Sort-Object
        'clipboard hotkey'          = @($txtClipboardHotkey.Tag) | Sort-Object
        'stop hotkey'                = @($txtStopHotkey.Tag) | Sort-Object
        'show/hide border hotkey'   = @($txtToggleHotkey.Tag) | Sort-Object
        'start/stop auto-capture hotkey' = @($txtToggleAutoCaptureHotkey.Tag) | Sort-Object
        'move-region modifier'      = @($txtMoveModifier.Tag) | Sort-Object
        'resize-region modifier'    = @($txtResizeModifier.Tag) | Sort-Object
    }
    $names = @($namedCombos.Keys)
    for ($i = 0; $i -lt $names.Count; $i++) {
        for ($j = $i + 1; $j -lt $names.Count; $j++) {
            $a = $namedCombos[$names[$i]] -join ','
            $b = $namedCombos[$names[$j]] -join ','
            if ($a -eq $b) {
                [System.Windows.Forms.MessageBox]::Show(
                    "The $($names[$i]) and the $($names[$j]) must be different.",
                    'Region Screenshot Tool'
                ) | Out-Null
                return
            }
        }
    }
    if (-not (Test-Path -LiteralPath $txtSave.Text)) {
        try { New-Item -ItemType Directory -Path $txtSave.Text -Force | Out-Null }
        catch {
            Write-Log "ERROR: couldn't create save folder '$($txtSave.Text)': $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("Couldn't create that folder:`n$($_.Exception.Message)", 'Region Screenshot Tool') | Out-Null
            return
        }
    }

    $toSave = [ordered]@{
        HotkeyName                 = $txtHotkey.Text
        HotkeyVKCodes              = @($txtHotkey.Tag)
        ClipboardHotkeyName         = $txtClipboardHotkey.Text
        ClipboardHotkeyVKCodes      = @($txtClipboardHotkey.Tag)
        StopHotkeyName              = $txtStopHotkey.Text
        StopHotkeyVKCodes           = @($txtStopHotkey.Tag)
        ToggleBorderHotkeyName      = $txtToggleHotkey.Text
        ToggleBorderHotkeyVKCodes   = @($txtToggleHotkey.Tag)
        ToggleAutoCaptureHotkeyName    = $txtToggleAutoCaptureHotkey.Text
        ToggleAutoCaptureHotkeyVKCodes = @($txtToggleAutoCaptureHotkey.Tag)
        MoveModifierName            = $txtMoveModifier.Text
        MoveModifierVKCodes         = @($txtMoveModifier.Tag)
        ResizeModifierName          = $txtResizeModifier.Text
        ResizeModifierVKCodes       = @($txtResizeModifier.Tag)
        MoveResizeStepPixels        = [int]$numMoveStep.Value
        FineStepPixels               = [int]$numFineStep.Value
        SaveLocation                = $txtSave.Text
        FileNameScheme              = $txtScheme.Text
        AutoCaptureIntervalMs      = [int]$numInterval.Value
        AutoCaptureAutoStart       = [bool]$chkAutoStart.Checked
        AutoActionKeyName          = $txtActionKey.Text
        AutoActionVKCodes          = @($txtActionKey.Tag)
        AutoActionTiming           = if ($radioAfter.Checked) { 'After' } else { 'Before' }
        AutoActionDelayMs          = [int]$numActionDelay.Value
        AutoCaptureUseSessionFolders   = [bool]$chkSessionFolders.Checked
        AutoCaptureSessionFolderScheme = $txtSessionScheme.Text
        AutoLaunchReviewOnStop     = [bool]$chkAutoLaunchReview.Checked
        AutoCaptureDuplicateDetectionEnabled = [bool]$chkDuplicatePause.Checked
        AutoCaptureDuplicateThresholdPercent = [double]$numDuplicateThreshold.Value
        LastRegionX                  = [int]$current.LastRegionX
        LastRegionY                  = [int]$current.LastRegionY
        LastRegionWidth              = [int]$current.LastRegionWidth
        LastRegionHeight             = [int]$current.LastRegionHeight
    }
    try {
        $toSave | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
        Write-Log "Settings saved to $ConfigPath"
    }
    catch {
        Write-Log "ERROR: couldn't save settings to '$ConfigPath': $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Couldn't save settings:`n$($_.Exception.Message)", 'Region Screenshot Tool') | Out-Null
        return
    }

    [System.Windows.Forms.MessageBox]::Show(
        "Settings saved.`n`nIf the screenshot tool is already running, use its tray icon's `"Reload Config`" option to apply these changes.",
        'Region Screenshot Tool'
    ) | Out-Null
    $form.Close()
})
$form.Controls.Add($btnSave)

$btnDefaults = New-Object System.Windows.Forms.Button
$btnDefaults.Text     = 'Reset to Defaults'
$btnDefaults.Location = New-Object System.Drawing.Point(15, $y)
$btnDefaults.Size     = New-Object System.Drawing.Size(140, 30)
$btnDefaults.Add_Click({
    $script:comboVKCodes = @($Defaults.HotkeyVKCodes)
    $script:downKeys.Clear()
    Update-HotkeyDisplay
    $script:clipboardComboVKCodes = @($Defaults.ClipboardHotkeyVKCodes)
    $script:clipboardDownKeys.Clear()
    Update-ClipboardHotkeyDisplay
    $script:stopComboVKCodes = @($Defaults.StopHotkeyVKCodes)
    $script:stopDownKeys.Clear()
    Update-StopHotkeyDisplay
    $script:toggleComboVKCodes = @($Defaults.ToggleBorderHotkeyVKCodes)
    $script:toggleDownKeys.Clear()
    Update-ToggleHotkeyDisplay
    $script:toggleAutoCaptureComboVKCodes = @($Defaults.ToggleAutoCaptureHotkeyVKCodes)
    $script:toggleAutoCaptureDownKeys.Clear()
    Update-ToggleAutoCaptureHotkeyDisplay
    $script:moveComboVKCodes = @($Defaults.MoveModifierVKCodes)
    $script:moveDownKeys.Clear()
    Update-MoveModifierDisplay
    $script:resizeComboVKCodes = @($Defaults.ResizeModifierVKCodes)
    $script:resizeDownKeys.Clear()
    Update-ResizeModifierDisplay
    $numMoveStep.Value = [int]$Defaults.MoveResizeStepPixels
    $numFineStep.Value = [int]$Defaults.FineStepPixels
    $txtSave.Text   = $Defaults.SaveLocation
    $txtScheme.Text = $Defaults.FileNameScheme
    $numInterval.Value = [int]$Defaults.AutoCaptureIntervalMs
    $chkAutoStart.Checked = [bool]$Defaults.AutoCaptureAutoStart
    $script:actionComboVKCodes = @($Defaults.AutoActionVKCodes)
    $script:actionDownKeys.Clear()
    Update-ActionKeyDisplay
    $radioBefore.Checked = ($Defaults.AutoActionTiming -ne 'After')
    $radioAfter.Checked  = ($Defaults.AutoActionTiming -eq 'After')
    $numActionDelay.Value = [int]$Defaults.AutoActionDelayMs
    $chkSessionFolders.Checked = [bool]$Defaults.AutoCaptureUseSessionFolders
    $txtSessionScheme.Text = [string]$Defaults.AutoCaptureSessionFolderScheme
    $chkAutoLaunchReview.Checked = [bool]$Defaults.AutoLaunchReviewOnStop
    $chkDuplicatePause.Checked = [bool]$Defaults.AutoCaptureDuplicateDetectionEnabled
    $numDuplicateThreshold.Value = [Math]::Min(100, [Math]::Max(50, [decimal][double]$Defaults.AutoCaptureDuplicateThresholdPercent))
})
$form.Controls.Add($btnDefaults)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text     = 'Cancel'
$btnCancel.Location = New-Object System.Drawing.Point(335, $y)
$btnCancel.Size     = New-Object System.Drawing.Size(110, 30)
$btnCancel.Add_Click({ $form.Close() })
$form.Controls.Add($btnCancel)

[void]$form.ShowDialog()
