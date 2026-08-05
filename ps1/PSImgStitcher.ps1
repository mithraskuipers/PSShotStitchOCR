<#
PSImgStitcher.ps1

Double-click GUI for stitching a folder of scrolling screenshots into one or
more long images, with smart overlap detection and seam blending.
PowerShell/WinForms port of stitch_screenshots.py (original Python version).

Reads/writes psimgstitcher_config.json next to this script so settings and last
used folders are remembered between runs. Runs the actual stitching on a
background PowerShell runspace so the window stays responsive and the Stop
button works, mirroring the Python original's background thread.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnginePath = Join-Path $ScriptDir "PSImgStitcherEngine.ps1"
$ConfigPath = Join-Path $ScriptDir "psimgstitcher_config.json"

# One level up from ps1\ - see matching comment in RegionScreenshot.ps1.
$ProjectRoot = Split-Path -Path $ScriptDir -Parent
if (-not $ProjectRoot) { $ProjectRoot = $ScriptDir }

if (-not (Test-Path -LiteralPath $EnginePath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "PSImgStitcherEngine.ps1 was not found next to this script:`n$EnginePath",
        "PSImgStitcher", "OK", "Error") | Out-Null
    exit 1
}

. $EnginePath

$cfg = Import-StitchConfigFile -Path $ConfigPath

# ---------------------------------------------------------------- state ---
$logQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$syncHash = [hashtable]::Synchronized(@{ Stop = $false })
$psJob = $null
$asyncResult = $null

# ------------------------------------------------------------------ form ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "PSImgStitcher"
$form.ClientSize = New-Object System.Drawing.Size(780, 700)
$form.MinimumSize = New-Object System.Drawing.Size(700, 600)
$form.StartPosition = "CenterScreen"

# --- Folders group ---
$foldersGroup = New-Object System.Windows.Forms.GroupBox
$foldersGroup.Text = "Folders"
$foldersGroup.Location = New-Object System.Drawing.Point(10, 10)
$foldersGroup.Size = New-Object System.Drawing.Size(755, 95)
$foldersGroup.Anchor = "Top,Left,Right"
$form.Controls.Add($foldersGroup)

$sourceLabel = New-Object System.Windows.Forms.Label
$sourceLabel.Text = "Source folder:"
$sourceLabel.Location = New-Object System.Drawing.Point(10, 28)
$sourceLabel.Size = New-Object System.Drawing.Size(95, 20)
$foldersGroup.Controls.Add($sourceLabel)

$sourceTextBox = New-Object System.Windows.Forms.TextBox
$sourceTextBox.Text = [string]$cfg.LastSourceFolder
$sourceTextBox.Location = New-Object System.Drawing.Point(110, 25)
$sourceTextBox.Size = New-Object System.Drawing.Size(530, 22)
$sourceTextBox.Anchor = "Top,Left,Right"
$foldersGroup.Controls.Add($sourceTextBox)

$sourceBrowseBtn = New-Object System.Windows.Forms.Button
$sourceBrowseBtn.Text = "Browse..."
$sourceBrowseBtn.Location = New-Object System.Drawing.Point(650, 24)
$sourceBrowseBtn.Size = New-Object System.Drawing.Size(90, 24)
$sourceBrowseBtn.Anchor = "Top,Right"
$foldersGroup.Controls.Add($sourceBrowseBtn)

$outputLabel = New-Object System.Windows.Forms.Label
$outputLabel.Text = "Output folder:"
$outputLabel.Location = New-Object System.Drawing.Point(10, 60)
$outputLabel.Size = New-Object System.Drawing.Size(95, 20)
$foldersGroup.Controls.Add($outputLabel)

$outputTextBox = New-Object System.Windows.Forms.TextBox
$outputTextBox.Text = if ($cfg.LastOutputFolder) { [string]$cfg.LastOutputFolder } else { Join-Path -Path $ProjectRoot -ChildPath 'stitched' }
$outputTextBox.Location = New-Object System.Drawing.Point(110, 57)
$outputTextBox.Size = New-Object System.Drawing.Size(530, 22)
$outputTextBox.Anchor = "Top,Left,Right"
$foldersGroup.Controls.Add($outputTextBox)

$outputBrowseBtn = New-Object System.Windows.Forms.Button
$outputBrowseBtn.Text = "Browse..."
$outputBrowseBtn.Location = New-Object System.Drawing.Point(650, 56)
$outputBrowseBtn.Size = New-Object System.Drawing.Size(90, 24)
$outputBrowseBtn.Anchor = "Top,Right"
$foldersGroup.Controls.Add($outputBrowseBtn)

$sourceBrowseBtn.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Select source folder"
    if ($sourceTextBox.Text -and (Test-Path -LiteralPath $sourceTextBox.Text)) {
        $dlg.SelectedPath = $sourceTextBox.Text
    }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $sourceTextBox.Text = $dlg.SelectedPath
        if (-not $outputTextBox.Text) {
            $outputTextBox.Text = Join-Path $dlg.SelectedPath "Stitched"
        }
    }
})

$outputBrowseBtn.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Select output folder"
    if ($outputTextBox.Text -and (Test-Path -LiteralPath $outputTextBox.Text)) {
        $dlg.SelectedPath = $outputTextBox.Text
    }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $outputTextBox.Text = $dlg.SelectedPath
    }
})

# --- Settings group ---
$settingsGroup = New-Object System.Windows.Forms.GroupBox
$settingsGroup.Text = "Settings"
$settingsGroup.Location = New-Object System.Drawing.Point(10, 115)
$settingsGroup.Size = New-Object System.Drawing.Size(755, 400)
$settingsGroup.Anchor = "Top,Left,Right"
$form.Controls.Add($settingsGroup)

$settingsDefs = @(
    @{ Name = "RowSamples";             Label = "Row samples";                    Type = "int";    Tip = "How many rows of the next image are used as the matching template." }
    @{ Name = "MinOverlapPixels";       Label = "Min overlap (px)";               Type = "int";    Tip = "Overlaps smaller than this are ignored (treated as no overlap)." }
    @{ Name = "MaxAvgError";            Label = "Max avg error";                  Type = "double"; Tip = "Max allowed average pixel difference (0-255) in the overlap zone." }
    @{ Name = "MaxOverlapSearchPixels"; Label = "Max search (px, 0=full)";        Type = "int";    Tip = "How far up the previous image to search for a match. 0 = whole image." }
    @{ Name = "MaxOutputHeightPixels";  Label = "Max output height (px)";         Type = "int";    Tip = "Sheets are split into a new output file past this height." }
    @{ Name = "FeatherPixels";          Label = "Feather blend (px)";             Type = "int";    Tip = "Width of the seam cross-fade used to hide compression noise." }
    @{ Name = "MinConfidence";          Label = "Min confidence (0-1)";           Type = "double"; Tip = "Minimum match confidence required to accept an overlap." }
    @{ Name = "MaxOverlapFraction";     Label = "Max overlap fraction (0-1)";     Type = "double"; Tip = "Safety cap: an overlap can never consume more than this fraction of a screenshot's height. Prevents repetitive content (lists, tables, code) from wiping out a whole screenshot as a false 'duplicate'." }
    @{ Name = "AmbiguityMinRatio";      Label = "Ambiguity min ratio";            Type = "double"; Tip = "How much better the best match must be than any other distinct candidate to be trusted. Raise this if repetitive content still causes wrong merges; lower it if genuine overlaps get rejected." }
)

$settingControls = @{}
$rowY = 25
foreach ($def in $settingsDefs) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $def.Label
    $lbl.Location = New-Object System.Drawing.Point(10, $rowY)
    $lbl.Size = New-Object System.Drawing.Size(150, 20)
    $settingsGroup.Controls.Add($lbl)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Text = [string]$cfg.($def.Name)
    $tb.Location = New-Object System.Drawing.Point(165, ($rowY - 2))
    $tb.Size = New-Object System.Drawing.Size(80, 22)
    $settingsGroup.Controls.Add($tb)
    $settingControls[$def.Name] = @{ Control = $tb; Type = $def.Type }

    $tipLbl = New-Object System.Windows.Forms.Label
    $tipLbl.Text = $def.Tip
    $tipLbl.ForeColor = [System.Drawing.Color]::DimGray
    $tipLbl.Location = New-Object System.Drawing.Point(255, $rowY)
    $tipLbl.Size = New-Object System.Drawing.Size(480, 36)
    $tipLbl.Anchor = "Top,Left,Right"
    $settingsGroup.Controls.Add($tipLbl)

    $rowY += 40
}

$sortLabel = New-Object System.Windows.Forms.Label
$sortLabel.Text = "Sort mode"
$sortLabel.Location = New-Object System.Drawing.Point(10, $rowY)
$sortLabel.Size = New-Object System.Drawing.Size(150, 20)
$settingsGroup.Controls.Add($sortLabel)

$sortCombo = New-Object System.Windows.Forms.ComboBox
$sortCombo.DropDownStyle = "DropDownList"
$sortCombo.Items.AddRange(@("Name", "Date"))
$sortCombo.SelectedItem = [string]$cfg.SortMode
if (-not $sortCombo.SelectedItem) { $sortCombo.SelectedIndex = 0 }
$sortCombo.Location = New-Object System.Drawing.Point(165, ($rowY - 2))
$sortCombo.Size = New-Object System.Drawing.Size(100, 22)
$settingsGroup.Controls.Add($sortCombo)

# --- Buttons row ---
$runBtn = New-Object System.Windows.Forms.Button
$runBtn.Text = "Stitch Screenshots"
$runBtn.Location = New-Object System.Drawing.Point(10, 525)
$runBtn.Size = New-Object System.Drawing.Size(150, 30)
$form.Controls.Add($runBtn)

$stopBtn = New-Object System.Windows.Forms.Button
$stopBtn.Text = "Stop"
$stopBtn.Location = New-Object System.Drawing.Point(170, 525)
$stopBtn.Size = New-Object System.Drawing.Size(90, 30)
$stopBtn.Enabled = $false
$form.Controls.Add($stopBtn)

$openOutputBtn = New-Object System.Windows.Forms.Button
$openOutputBtn.Text = "Open Output Folder"
$openOutputBtn.Location = New-Object System.Drawing.Point(615, 525)
$openOutputBtn.Size = New-Object System.Drawing.Size(150, 30)
$openOutputBtn.Anchor = "Top,Right"
$form.Controls.Add($openOutputBtn)

# --- Progress bar ---
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(10, 565)
$progress.Size = New-Object System.Drawing.Size(755, 18)
$progress.Anchor = "Top,Left,Right"
$progress.Style = "Marquee"
$progress.MarqueeAnimationSpeed = 0
$form.Controls.Add($progress)

# --- Log group ---
$logGroup = New-Object System.Windows.Forms.GroupBox
$logGroup.Text = "Log"
$logGroup.Location = New-Object System.Drawing.Point(10, 593)
$logGroup.Size = New-Object System.Drawing.Size(755, 95)
$logGroup.Anchor = "Top,Left,Right,Bottom"
$form.Controls.Add($logGroup)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = "Vertical"
$logBox.Location = New-Object System.Drawing.Point(8, 18)
$logBox.Size = New-Object System.Drawing.Size(737, 68)
$logBox.Anchor = "Top,Left,Right,Bottom"
$logGroup.Controls.Add($logBox)

function Write-Log([string]$msg) {
    $logBox.AppendText($msg + [Environment]::NewLine)
}

function Open-OutputFolder {
    $folder = $outputTextBox.Text
    if ($folder -and (Test-Path -LiteralPath $folder -PathType Container)) {
        Start-Process -FilePath "explorer.exe" -ArgumentList "`"$folder`""
    }
    else {
        [System.Windows.Forms.MessageBox]::Show("Output folder does not exist yet.", "PSImgStitcher") | Out-Null
    }
}
$openOutputBtn.Add_Click({ Open-OutputFolder })

function Get-ConfigFromForm {
    $c = New-StitchConfig
    foreach ($name in $settingControls.Keys) {
        $entry = $settingControls[$name]
        $text = $entry.Control.Text.Trim()
        if ($entry.Type -eq "int") {
            $parsed = 0
            if (-not [int]::TryParse($text, [ref]$parsed)) {
                throw "Setting '$name' must be a whole number (got '$text')."
            }
            $c.$name = $parsed
        }
        else {
            $parsed = 0.0
            if (-not [double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
                throw "Setting '$name' must be a number (got '$text')."
            }
            $c.$name = $parsed
        }
    }
    $c.SortMode = [string]$sortCombo.SelectedItem
    $c.LastSourceFolder = $sourceTextBox.Text
    $c.LastOutputFolder = $outputTextBox.Text
    return $c
}

# --------------------------------------------------------------- timer ---
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150

$timer.Add_Tick({
    $msg = $null
    while ($logQueue.TryDequeue([ref]$msg)) {
        Write-Log $msg
    }

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
        foreach ($err in $psJob.Streams.Error) {
            Write-Log "ERROR: $err"
        }
        $psJob.Dispose()
        $psJob = $null
        $asyncResult = $null

        $runBtn.Enabled = $true
        $stopBtn.Enabled = $false

        if ($outputs -and $outputs.Count -gt 0) {
            Open-OutputFolder
        }
    }
})

# --------------------------------------------------------------- actions ---
$runBtn.Add_Click({
    $source = $sourceTextBox.Text.Trim()
    $output = $outputTextBox.Text.Trim()

    if (-not $source -or -not (Test-Path -LiteralPath $source -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show("Please choose a valid source folder.", "PSImgStitcher") | Out-Null
        return
    }
    if (-not $output) {
        [System.Windows.Forms.MessageBox]::Show("Please choose an output folder.", "PSImgStitcher") | Out-Null
        return
    }

    try {
        $newCfg = Get-ConfigFromForm
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "PSImgStitcher") | Out-Null
        return
    }
    Export-StitchConfigFile -Path $ConfigPath -Config $newCfg

    $runBtn.Enabled = $false
    $stopBtn.Enabled = $true
    $progress.MarqueeAnimationSpeed = 30
    $syncHash.Stop = $false

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
    [void]$psJob.AddArgument($source)
    [void]$psJob.AddArgument($output)
    [void]$psJob.AddArgument($newCfg)
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
    try {
        Export-StitchConfigFile -Path $ConfigPath -Config (Get-ConfigFromForm)
    }
    catch {
        # settings textboxes may hold invalid values on close - ignore, keep last saved config
    }
})

[System.Windows.Forms.Application]::Run($form)
