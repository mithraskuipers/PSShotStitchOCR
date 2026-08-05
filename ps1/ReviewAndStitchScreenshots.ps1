<#
.SYNOPSIS
    Review & Stitch tool - the hand-off step between RegionScreenshot.ps1's
    auto-capture and PSImgStitcher's stitching engine.

.DESCRIPTION
    Shows every screenshot in a folder (typically one auto-capture
    "session" folder produced by RegionScreenshot.ps1) as a thumbnail
    grid, plus a larger side-by-side preview of the first and last shot so
    you can tell at a glance where the run started and ended. Check any
    bad/duplicate frames and click "Discard Selected" to move them into a
    "Discarded" subfolder - they're moved, not deleted, so it's undoable
    with "Restore All from Discarded" or just by dragging them back in
    Explorer. Once the set looks right, "Stitch Now" hands the remaining
    (non-discarded) screenshots to PSImgStitcherEngine.ps1 - the same
    stitching engine PSImgStitcher.ps1 uses - and writes the result to the
    chosen output folder.

    Advanced stitching settings (row samples, overlap thresholds, feather
    blend, etc.) are shared with PSImgStitcher.ps1 via
    psimgstitcher_config.json next to this script - tune them there (via
    "Start PSImgStitcher.bat") if the default matching behaves oddly on
    your screenshots; this tool intentionally only surfaces the folders,
    since its job is reviewing frames, not tuning the matcher.

    Usage:
        ReviewAndStitchScreenshots.ps1 [-SourceFolder <path>]

    Normally launched automatically by RegionScreenshot.ps1 when
    auto-capture is stopped (pointed at that session's folder), or from
    its tray menu ("Review Last Session..." / "Review & Stitch..."). Can
    also be run standalone via "Start Review & Stitch.bat" and pointed at
    any folder of screenshots with the Browse button.

.NOTES
    Run via "Start Review & Stitch.bat" (handles STA + execution policy),
    or let RegionScreenshot.ps1 launch it for you.
#>

param(
    [string]$SourceFolder = ''
)

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host ''
    Write-Host 'ERROR: This script must run in STA mode.' -ForegroundColor Red
    Write-Host 'Use the included "Start Review & Stitch.bat", or run manually with:' -ForegroundColor Yellow
    Write-Host '  powershell -STA -NoProfile -ExecutionPolicy Bypass -File ReviewAndStitchScreenshots.ps1' -ForegroundColor Yellow
    Write-Host ''
    Read-Host 'Press Enter to exit'
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$EnginePath = Join-Path $ScriptDir 'PSImgStitcherEngine.ps1'
$StitchConfigPath = Join-Path $ScriptDir 'psimgstitcher_config.json'

# One level up from ps1\ - see matching comment in RegionScreenshot.ps1.
# Stitched output defaults to a subfolder here, named after the session
# being stitched, so everything lands in <project>\stitched\ instead of
# inside the screenshot session folder itself.
$ProjectRoot = Split-Path -Path $ScriptDir -Parent
if (-not $ProjectRoot) { $ProjectRoot = $ScriptDir }

# Screenshots moved here (not deleted) when discarded during review. Never
# picked up as stitch input, since folder listing below is non-recursive.
$DiscardedFolderName = 'Discarded'

if (-not (Test-Path -LiteralPath $EnginePath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "PSImgStitcherEngine.ps1 was not found next to this script:`n$EnginePath",
        'Review & Stitch', 'OK', 'Error') | Out-Null
    exit 1
}
. $EnginePath

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
$script:cards = @()      # one entry per visible thumbnail: @{ Path; Panel; CheckBox; Thumb }
$logQueue     = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$syncHash     = [hashtable]::Synchronized(@{ Stop = $false })
$psJob        = $null
$asyncResult  = $null

# ---------------------------------------------------------------------------
# Form
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Review & Stitch'
$form.ClientSize = New-Object System.Drawing.Size(900, 780)
$form.MinimumSize = New-Object System.Drawing.Size(700, 550)
$form.StartPosition = 'CenterScreen'

# --- Source folder row ---
$srcGroup = New-Object System.Windows.Forms.GroupBox
$srcGroup.Text = 'Screenshots to review'
$srcGroup.Location = New-Object System.Drawing.Point(10, 10)
$srcGroup.Size = New-Object System.Drawing.Size(880, 60)
$srcGroup.Anchor = 'Top,Left,Right'
$form.Controls.Add($srcGroup)

$sourceTextBox = New-Object System.Windows.Forms.TextBox
$sourceTextBox.Text = $SourceFolder
$sourceTextBox.Location = New-Object System.Drawing.Point(10, 25)
$sourceTextBox.Size = New-Object System.Drawing.Size(650, 22)
$sourceTextBox.Anchor = 'Top,Left,Right'
$srcGroup.Controls.Add($sourceTextBox)

$sourceBrowseBtn = New-Object System.Windows.Forms.Button
$sourceBrowseBtn.Text = 'Browse...'
$sourceBrowseBtn.Location = New-Object System.Drawing.Point(670, 23)
$sourceBrowseBtn.Size = New-Object System.Drawing.Size(90, 24)
$sourceBrowseBtn.Anchor = 'Top,Right'
$srcGroup.Controls.Add($sourceBrowseBtn)

$refreshBtn = New-Object System.Windows.Forms.Button
$refreshBtn.Text = 'Refresh'
$refreshBtn.Location = New-Object System.Drawing.Point(770, 23)
$refreshBtn.Size = New-Object System.Drawing.Size(100, 24)
$refreshBtn.Anchor = 'Top,Right'
$srcGroup.Controls.Add($refreshBtn)

# --- Start / end preview ---
$previewGroup = New-Object System.Windows.Forms.GroupBox
$previewGroup.Text = 'Session preview'
$previewGroup.Location = New-Object System.Drawing.Point(10, 75)
$previewGroup.Size = New-Object System.Drawing.Size(880, 195)
$previewGroup.Anchor = 'Top,Left,Right'
$form.Controls.Add($previewGroup)

$firstLabel = New-Object System.Windows.Forms.Label
$firstLabel.Text = 'First'
$firstLabel.Location = New-Object System.Drawing.Point(10, 20)
$firstLabel.AutoSize = $true
$previewGroup.Controls.Add($firstLabel)

$firstPictureBox = New-Object System.Windows.Forms.PictureBox
$firstPictureBox.Location = New-Object System.Drawing.Point(10, 40)
$firstPictureBox.Size = New-Object System.Drawing.Size(415, 145)
$firstPictureBox.SizeMode = 'Zoom'
$firstPictureBox.BorderStyle = 'FixedSingle'
$firstPictureBox.Anchor = 'Top,Left,Right'
$previewGroup.Controls.Add($firstPictureBox)

$lastLabel = New-Object System.Windows.Forms.Label
$lastLabel.Text = 'Last'
$lastLabel.Location = New-Object System.Drawing.Point(450, 20)
$lastLabel.AutoSize = $true
$lastLabel.Anchor = 'Top,Right'
$previewGroup.Controls.Add($lastLabel)

$lastPictureBox = New-Object System.Windows.Forms.PictureBox
$lastPictureBox.Location = New-Object System.Drawing.Point(450, 40)
$lastPictureBox.Size = New-Object System.Drawing.Size(415, 145)
$lastPictureBox.SizeMode = 'Zoom'
$lastPictureBox.BorderStyle = 'FixedSingle'
$lastPictureBox.Anchor = 'Top,Left,Right'
$previewGroup.Controls.Add($lastPictureBox)

# --- Thumbnail grid toolbar ---
$gridToolbar = New-Object System.Windows.Forms.FlowLayoutPanel
$gridToolbar.Location = New-Object System.Drawing.Point(10, 278)
$gridToolbar.Size = New-Object System.Drawing.Size(880, 30)
$gridToolbar.Anchor = 'Top,Left,Right'
$gridToolbar.WrapContents = $false
$form.Controls.Add($gridToolbar)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'No screenshots loaded.'
$statusLabel.AutoSize = $true
$statusLabel.Margin = New-Object System.Windows.Forms.Padding(0, 8, 20, 0)
$gridToolbar.Controls.Add($statusLabel)

$selectAllBtn = New-Object System.Windows.Forms.Button
$selectAllBtn.Text = 'Select All'
$selectAllBtn.Size = New-Object System.Drawing.Size(90, 24)
$gridToolbar.Controls.Add($selectAllBtn)

$selectNoneBtn = New-Object System.Windows.Forms.Button
$selectNoneBtn.Text = 'Select None'
$selectNoneBtn.Size = New-Object System.Drawing.Size(90, 24)
$gridToolbar.Controls.Add($selectNoneBtn)

$discardBtn = New-Object System.Windows.Forms.Button
$discardBtn.Text = 'Discard Selected'
$discardBtn.Size = New-Object System.Drawing.Size(120, 24)
$gridToolbar.Controls.Add($discardBtn)

$restoreBtn = New-Object System.Windows.Forms.Button
$restoreBtn.Text = 'Restore All from Discarded'
$restoreBtn.Size = New-Object System.Drawing.Size(170, 24)
$gridToolbar.Controls.Add($restoreBtn)

$openDiscardedBtn = New-Object System.Windows.Forms.Button
$openDiscardedBtn.Text = 'Open Discarded Folder'
$openDiscardedBtn.Size = New-Object System.Drawing.Size(150, 24)
$gridToolbar.Controls.Add($openDiscardedBtn)

# --- Thumbnail grid ---
$gridPanel = New-Object System.Windows.Forms.Panel
$gridPanel.Location = New-Object System.Drawing.Point(10, 312)
$gridPanel.Size = New-Object System.Drawing.Size(880, 260)
$gridPanel.Anchor = 'Top,Left,Right,Bottom'
$gridPanel.AutoScroll = $true
$gridPanel.BorderStyle = 'FixedSingle'
$gridPanel.BackColor = [System.Drawing.Color]::WhiteSmoke
$form.Controls.Add($gridPanel)

$gridFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$gridFlow.Location = New-Object System.Drawing.Point(0, 0)
$gridFlow.AutoSize = $true
$gridFlow.WrapContents = $true
$gridFlow.FlowDirection = 'LeftToRight'
$gridPanel.Controls.Add($gridFlow)

# --- Output / Stitch row ---
$stitchGroup = New-Object System.Windows.Forms.GroupBox
$stitchGroup.Text = 'Stitch'
$stitchGroup.Location = New-Object System.Drawing.Point(10, 580)
$stitchGroup.Size = New-Object System.Drawing.Size(880, 60)
$stitchGroup.Anchor = 'Left,Right,Bottom'
$form.Controls.Add($stitchGroup)

$outputLabel = New-Object System.Windows.Forms.Label
$outputLabel.Text = 'Output folder:'
$outputLabel.Location = New-Object System.Drawing.Point(10, 27)
$outputLabel.AutoSize = $true
$stitchGroup.Controls.Add($outputLabel)

$outputTextBox = New-Object System.Windows.Forms.TextBox
$outputTextBox.Location = New-Object System.Drawing.Point(105, 24)
$outputTextBox.Size = New-Object System.Drawing.Size(500, 22)
$outputTextBox.Anchor = 'Top,Left,Right'
$stitchGroup.Controls.Add($outputTextBox)

$outputBrowseBtn = New-Object System.Windows.Forms.Button
$outputBrowseBtn.Text = 'Browse...'
$outputBrowseBtn.Location = New-Object System.Drawing.Point(615, 23)
$outputBrowseBtn.Size = New-Object System.Drawing.Size(90, 24)
$outputBrowseBtn.Anchor = 'Top,Right'
$stitchGroup.Controls.Add($outputBrowseBtn)

$stitchBtn = New-Object System.Windows.Forms.Button
$stitchBtn.Text = 'Stitch Now'
$stitchBtn.Location = New-Object System.Drawing.Point(715, 23)
$stitchBtn.Size = New-Object System.Drawing.Size(80, 24)
$stitchBtn.Anchor = 'Top,Right'
$stitchGroup.Controls.Add($stitchBtn)

$stopBtn = New-Object System.Windows.Forms.Button
$stopBtn.Text = 'Stop'
$stopBtn.Location = New-Object System.Drawing.Point(800, 23)
$stopBtn.Size = New-Object System.Drawing.Size(70, 24)
$stopBtn.Anchor = 'Top,Right'
$stopBtn.Enabled = $false
$stitchGroup.Controls.Add($stopBtn)

# --- Progress + log ---
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(10, 645)
$progress.Size = New-Object System.Drawing.Size(880, 16)
$progress.Anchor = 'Left,Right,Bottom'
$progress.Style = 'Marquee'
$progress.MarqueeAnimationSpeed = 0
$form.Controls.Add($progress)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.Location = New-Object System.Drawing.Point(10, 665)
$logBox.Size = New-Object System.Drawing.Size(880, 100)
$logBox.Anchor = 'Left,Right,Bottom'
$form.Controls.Add($logBox)

function Write-Log([string]$msg) {
    $logBox.AppendText($msg + [Environment]::NewLine)
}

# ---------------------------------------------------------------------------
# Thumbnail helpers
# ---------------------------------------------------------------------------
function New-ThumbnailBitmap {
    <#
        Decodes Path into a new, independent Bitmap scaled to fit within
        MaxWidth x MaxHeight, then releases the source file handle. Reading
        the bytes into memory first (rather than Image.FromFile) means the
        original file is never left locked, so it can be moved to/from the
        Discarded folder right after being previewed.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxWidth = 150,
        [int]$MaxHeight = 110
    )
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $ms = New-Object System.IO.MemoryStream(, $bytes)
    try {
        $src = [System.Drawing.Image]::FromStream($ms)
        try {
            $scale = [Math]::Min([double]$MaxWidth / $src.Width, [double]$MaxHeight / $src.Height)
            $scale = [Math]::Min(1.0, $scale)
            $w = [Math]::Max(1, [int]($src.Width * $scale))
            $h = [Math]::Max(1, [int]($src.Height * $scale))
            $thumb = New-Object System.Drawing.Bitmap $w, $h
            $g = [System.Drawing.Graphics]::FromImage($thumb)
            try {
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.DrawImage($src, 0, 0, $w, $h)
            }
            finally { $g.Dispose() }
            return $thumb
        }
        finally { $src.Dispose() }
    }
    finally { $ms.Dispose() }
}

function Clear-ThumbnailGrid {
    foreach ($card in $script:cards) {
        if ($card.Thumb) { $card.Thumb.Dispose() }
    }
    $script:cards = @()
    $gridFlow.Controls.Clear()
    if ($firstPictureBox.Image) { $firstPictureBox.Image.Dispose(); $firstPictureBox.Image = $null }
    if ($lastPictureBox.Image)  { $lastPictureBox.Image.Dispose();  $lastPictureBox.Image  = $null }
}

function New-ThumbnailCard {
    param([Parameter(Mandatory)][string]$Path)

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Size = New-Object System.Drawing.Size(170, 150)
    $panel.Margin = New-Object System.Windows.Forms.Padding(5)
    $panel.BorderStyle = 'FixedSingle'
    $panel.BackColor = [System.Drawing.Color]::White

    $pic = New-Object System.Windows.Forms.PictureBox
    $pic.Location = New-Object System.Drawing.Point(5, 5)
    $pic.Size = New-Object System.Drawing.Size(158, 112)
    $pic.SizeMode = 'Zoom'
    $panel.Controls.Add($pic)

    $thumb = New-ThumbnailBitmap -Path $Path -MaxWidth 158 -MaxHeight 112
    $pic.Image = $thumb

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Location = New-Object System.Drawing.Point(5, 122)
    $chk.Size = New-Object System.Drawing.Size(160, 20)
    $chk.Text = [System.IO.Path]::GetFileName($Path)
    $chk.AutoEllipsis = $true
    $panel.Controls.Add($chk)

    # Clicking the thumbnail itself is a faster way to mark a frame for
    # discard than hitting the small checkbox text.
    $pic.Add_Click({ $chk.Checked = -not $chk.Checked }.GetNewClosure())

    $gridFlow.Controls.Add($panel)
    $script:cards += , @{ Path = $Path; Panel = $panel; CheckBox = $chk; Thumb = $thumb }
}

function Update-Preview {
    param([string[]]$Files)

    if ($Files.Count -eq 0) {
        $statusLabel.Text = 'No screenshots found in this folder.'
        return
    }

    $statusLabel.Text = "$($Files.Count) screenshot(s)."

    $firstThumb = New-ThumbnailBitmap -Path $Files[0] -MaxWidth 413 -MaxHeight 143
    $firstPictureBox.Image = $firstThumb

    $lastThumb = New-ThumbnailBitmap -Path $Files[-1] -MaxWidth 413 -MaxHeight 143
    $lastPictureBox.Image = $lastThumb

    $firstLabel.Text = "First - $([System.IO.Path]::GetFileName($Files[0]))"
    $lastLabel.Text  = "Last - $([System.IO.Path]::GetFileName($Files[-1]))"
}

function Get-DiscardedFolderPath {
    param([Parameter(Mandatory)][string]$Folder)
    return (Join-Path -Path $Folder -ChildPath $DiscardedFolderName)
}

function Update-ReviewGrid {
    <#
        Reloads the thumbnail grid + start/end preview from whatever
        folder is currently in the source textbox. Only lists files
        directly in that folder - the Discarded subfolder is never
        recursed into, so discarded frames simply disappear from view.
    #>
    $folder = $sourceTextBox.Text.Trim()
    Clear-ThumbnailGrid
    $firstLabel.Text = 'First'
    $lastLabel.Text = 'Last'

    if (-not $folder -or -not (Test-Path -LiteralPath $folder -PathType Container)) {
        $statusLabel.Text = 'Choose a folder to review.'
        return
    }

    $sortMode = 'Name'
    if (Test-Path -LiteralPath $StitchConfigPath) {
        try { $sortMode = [string](Import-StitchConfigFile -Path $StitchConfigPath).SortMode } catch { }
    }
    if ($sortMode -ne 'Date') { $sortMode = 'Name' }

    $files = Get-StitchImageList -Folder $folder -SortMode $sortMode
    if ($files.Count -eq 0) {
        $statusLabel.Text = 'No screenshots found in this folder.'
        return
    }

    Update-Preview -Files $files

    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $i = 0
        foreach ($f in $files) {
            New-ThumbnailCard -Path $f
            $i++
            if ($i % 8 -eq 0) {
                $statusLabel.Text = "Loading thumbnails... ($i / $($files.Count))"
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
    }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
    $statusLabel.Text = "$($files.Count) screenshot(s)."

    if (-not $outputTextBox.Text.Trim()) {
        # Default to <project>\stitched\<session folder name>, so stitched
        # output collects in one shared "stitched" folder at the project
        # root, with a per-session subfolder to avoid different sessions'
        # Stitched_001.png etc. overwriting each other.
        $sessionName = Split-Path -Path $folder -Leaf
        $outputTextBox.Text = Join-Path -Path (Join-Path -Path $ProjectRoot -ChildPath 'stitched') -ChildPath $sessionName
    }
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
$sourceBrowseBtn.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select the folder of screenshots to review'
    if ($sourceTextBox.Text -and (Test-Path -LiteralPath $sourceTextBox.Text)) {
        $dlg.SelectedPath = $sourceTextBox.Text
    }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $sourceTextBox.Text = $dlg.SelectedPath
        Update-ReviewGrid
    }
})

$refreshBtn.Add_Click({ Update-ReviewGrid })

$selectAllBtn.Add_Click({
    foreach ($card in $script:cards) { $card.CheckBox.Checked = $true }
})

$selectNoneBtn.Add_Click({
    foreach ($card in $script:cards) { $card.CheckBox.Checked = $false }
})

$discardBtn.Add_Click({
    $folder = $sourceTextBox.Text.Trim()
    if (-not $folder -or -not (Test-Path -LiteralPath $folder -PathType Container)) { return }

    $toDiscard = @($script:cards | Where-Object { $_.CheckBox.Checked })
    if ($toDiscard.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('No screenshots are checked.', 'Review & Stitch') | Out-Null
        return
    }

    $discardedFolder = Get-DiscardedFolderPath -Folder $folder
    if (-not (Test-Path -LiteralPath $discardedFolder)) {
        New-Item -ItemType Directory -Path $discardedFolder -Force | Out-Null
    }

    $moved = 0
    foreach ($card in $toDiscard) {
        try {
            $destName = [System.IO.Path]::GetFileName($card.Path)
            $dest = Join-Path -Path $discardedFolder -ChildPath $destName
            # If a file with this name was already discarded before (e.g. it
            # was restored and re-captured), don't clobber it.
            if (Test-Path -LiteralPath $dest) {
                $stamp = (Get-Date).ToString('HHmmss_fff')
                $dest = Join-Path -Path $discardedFolder -ChildPath ("{0}_{1}{2}" -f
                    [System.IO.Path]::GetFileNameWithoutExtension($destName), $stamp,
                    [System.IO.Path]::GetExtension($destName))
            }
            Move-Item -LiteralPath $card.Path -Destination $dest -Force
            $moved++
        }
        catch {
            Write-Log "Could not discard $($card.Path): $($_.Exception.Message)"
        }
    }
    Write-Log "Discarded $moved screenshot(s) to '$DiscardedFolderName'."
    Update-ReviewGrid
})

$restoreBtn.Add_Click({
    $folder = $sourceTextBox.Text.Trim()
    if (-not $folder -or -not (Test-Path -LiteralPath $folder -PathType Container)) { return }

    $discardedFolder = Get-DiscardedFolderPath -Folder $folder
    if (-not (Test-Path -LiteralPath $discardedFolder)) {
        [System.Windows.Forms.MessageBox]::Show('Nothing has been discarded yet.', 'Review & Stitch') | Out-Null
        return
    }

    $items = Get-ChildItem -LiteralPath $discardedFolder -File -ErrorAction SilentlyContinue
    if (-not $items -or $items.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Nothing has been discarded yet.', 'Review & Stitch') | Out-Null
        return
    }

    $restored = 0
    foreach ($item in $items) {
        try {
            $dest = Join-Path -Path $folder -ChildPath $item.Name
            if (Test-Path -LiteralPath $dest) {
                $stamp = (Get-Date).ToString('HHmmss_fff')
                $dest = Join-Path -Path $folder -ChildPath ("{0}_{1}{2}" -f
                    [System.IO.Path]::GetFileNameWithoutExtension($item.Name), $stamp, $item.Extension)
            }
            Move-Item -LiteralPath $item.FullName -Destination $dest -Force
            $restored++
        }
        catch {
            Write-Log "Could not restore $($item.Name): $($_.Exception.Message)"
        }
    }
    Write-Log "Restored $restored screenshot(s) from '$DiscardedFolderName'."
    Update-ReviewGrid
})

$openDiscardedBtn.Add_Click({
    $folder = $sourceTextBox.Text.Trim()
    $discardedFolder = Get-DiscardedFolderPath -Folder $folder
    if ($folder -and (Test-Path -LiteralPath $discardedFolder)) {
        Start-Process explorer.exe $discardedFolder
    }
    else {
        [System.Windows.Forms.MessageBox]::Show('Nothing has been discarded yet.', 'Review & Stitch') | Out-Null
    }
})

$outputBrowseBtn.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select output folder for the stitched image(s)'
    if ($outputTextBox.Text -and (Test-Path -LiteralPath $outputTextBox.Text)) {
        $dlg.SelectedPath = $outputTextBox.Text
    }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $outputTextBox.Text = $dlg.SelectedPath
    }
})

function Open-OutputFolder {
    $folder = $outputTextBox.Text
    if ($folder -and (Test-Path -LiteralPath $folder -PathType Container)) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$folder`""
    }
}

# --------------------------------------------------------------- timer ---
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
    $msg = $null
    while ($logQueue.TryDequeue([ref]$msg)) { Write-Log $msg }

    if ($null -ne $asyncResult -and $asyncResult.IsCompleted) {
        $timer.Stop()
        $progress.MarqueeAnimationSpeed = 0

        try {
            $outputs = $psJob.EndInvoke($asyncResult)
        }
        catch {
            Write-Log "ERROR: $($_.Exception.Message)"
            $outputs = @()
        }
        foreach ($err in $psJob.Streams.Error) { Write-Log "ERROR: $err" }
        $psJob.Dispose()
        $psJob = $null
        $asyncResult = $null

        $stitchBtn.Enabled = $true
        $stopBtn.Enabled = $false

        if ($outputs -and $outputs.Count -gt 0) {
            Write-Log 'Done.'
            Open-OutputFolder
        }
    }
})

$stitchBtn.Add_Click({
    $folder = $sourceTextBox.Text.Trim()
    $output = $outputTextBox.Text.Trim()

    if (-not $folder -or -not (Test-Path -LiteralPath $folder -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show('Please choose a valid folder to review first.', 'Review & Stitch') | Out-Null
        return
    }
    if (-not $output) {
        [System.Windows.Forms.MessageBox]::Show('Please choose an output folder.', 'Review & Stitch') | Out-Null
        return
    }
    $remaining = @(Get-StitchImageList -Folder $folder -SortMode 'Name')
    if ($remaining.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('No screenshots left to stitch (everything may have been discarded).', 'Review & Stitch') | Out-Null
        return
    }

    # Reuse the same stitch-tuning settings PSImgStitcher.ps1 uses, and
    # keep both tools' "last used folder" fields in sync.
    $stitchCfg = Import-StitchConfigFile -Path $StitchConfigPath
    $stitchCfg.LastSourceFolder = $folder
    $stitchCfg.LastOutputFolder = $output
    Export-StitchConfigFile -Path $StitchConfigPath -Config $stitchCfg

    $stitchBtn.Enabled = $false
    $stopBtn.Enabled = $true
    $progress.MarqueeAnimationSpeed = 30
    $syncHash.Stop = $false
    Write-Log "Stitching $($remaining.Count) screenshot(s) from '$folder'..."

    $workScript = @'
param($SourceFolder, $OutputFolder, $Config, $LogQueue, $SyncHash, $EnginePath)
try {
    . $EnginePath
    $logCb = { param($msg) $LogQueue.Enqueue($msg) }
    $stopCb = { $SyncHash.Stop }
    Invoke-StitchFolder -SourceFolder $SourceFolder -OutputFolder $OutputFolder -Config $Config -Log $logCb -StopFlag $stopCb
}
catch {
    $LogQueue.Enqueue("ERROR: $($_.Exception.Message)")
    @()
}
'@

    $psJob = [System.Management.Automation.PowerShell]::Create()
    [void]$psJob.AddScript($workScript)
    [void]$psJob.AddArgument($folder)
    [void]$psJob.AddArgument($output)
    [void]$psJob.AddArgument($stitchCfg)
    [void]$psJob.AddArgument($logQueue)
    [void]$psJob.AddArgument($syncHash)
    [void]$psJob.AddArgument($EnginePath)

    $asyncResult = $psJob.BeginInvoke()
    $timer.Start()
})

$stopBtn.Add_Click({
    $syncHash.Stop = $true
    $stopBtn.Enabled = $false
})

$form.Add_FormClosing({
    $syncHash.Stop = $true
    Clear-ThumbnailGrid
})

# ---------------------------------------------------------------------------
# Initial load
# ---------------------------------------------------------------------------
if (-not $sourceTextBox.Text.Trim() -and (Test-Path -LiteralPath $StitchConfigPath)) {
    # Nothing passed via -SourceFolder - prefill Output from the shared
    # stitcher config so the field isn't blank, but leave Source empty so
    # Update-ReviewGrid shows the "choose a folder" hint instead of loading
    # a stale folder from a previous run.
    try {
        $seedCfg = Import-StitchConfigFile -Path $StitchConfigPath
        if ($seedCfg.LastOutputFolder) { $outputTextBox.Text = [string]$seedCfg.LastOutputFolder }
    }
    catch { }
}

Update-ReviewGrid

[System.Windows.Forms.Application]::Run($form)
