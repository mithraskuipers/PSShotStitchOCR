<#
Start-ReviewWebServer.ps1

Serves the Screenshot Stitcher web app (ps1/webapp/*) plus one session's
screenshots over a local HTTP server, then opens the default browser to it.
This replaces ReviewAndStitchScreenshots.ps1 / PSImgStitcherEngine.ps1 - the
review grid and the stitching math both now live in the web app; this
script's only job is "hand the browser the files it needs".

No file-system-access API, no writing back to disk from the browser -
the web app downloads the stitched result the same way any other browser
download works, matching the plain drag-and-drop / download model.

Usage:
    Start-ReviewWebServer.ps1 -SourceFolder "C:\path\to\Session_..."
    Start-ReviewWebServer.ps1                     # prompts for a folder
#>

param(
    [string]$SourceFolder,
    [int]$Port = 0,
    # Any startup/runtime output is always appended here too, in addition
    # to the console - used when this script is launched headlessly (no
    # console the user will see, e.g. via RegionScreenshot.ps1's hand-off)
    # so a failure has somewhere to go other than a Write-Host nobody
    # reads. If not passed explicitly (e.g. running this script by hand),
    # a default path under Logs\ is used instead, so a log is always
    # written either way.
    [string]$LogPath,
    # Folder this script lives in. Normally auto-detected via
    # $MyInvocation, but RegionScreenshot.ps1's hand-off runs this script's
    # text as a dynamically-created scriptblock rather than a real file (to
    # sidestep Group-Policy-locked execution policy - see the matching
    # comment in RegionScreenshot.ps1's Start-ReviewTool), and
    # $MyInvocation.MyCommand.Path is empty in that case, so it's passed
    # in explicitly instead.
    [string]$ScriptRoot
)

if (-not $ScriptRoot) { $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

if (-not $LogPath) {
    $DefaultLogProjectRoot = Split-Path -Path $ScriptRoot -Parent
    if (-not $DefaultLogProjectRoot) { $DefaultLogProjectRoot = $ScriptRoot }
    $DefaultLogDir = Join-Path -Path $DefaultLogProjectRoot -ChildPath 'Logs'
    New-Item -ItemType Directory -Path $DefaultLogDir -Force -ErrorAction SilentlyContinue | Out-Null
    $LogPath = Join-Path -Path $DefaultLogDir -ChildPath ("ReviewWebServer_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Write-Host $Message } catch { }
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
}

Write-Log "Start-ReviewWebServer started. ScriptRoot=$ScriptRoot  LogPath=$LogPath"

$ErrorActionPreference = 'Stop'
try {

$WebAppRoot = Join-Path $ScriptRoot 'webapp'

if (-not (Test-Path -LiteralPath $WebAppRoot)) {
    Write-Log "ERROR: webapp folder not found next to this script: $WebAppRoot"
    if (-not $LogPath -and $Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to exit' }
    exit 1
}

if (-not $SourceFolder) {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose the screenshot session folder to review'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Log 'No folder chosen - exiting.'
        exit 0
    }
    $SourceFolder = $dlg.SelectedPath
}

if (-not (Test-Path -LiteralPath $SourceFolder)) {
    Write-Log "ERROR: source folder not found: $SourceFolder"
    if (-not $LogPath -and $Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to exit' }
    exit 1
}

# ---------------------------------------------------------------- sorting

function Get-NaturalSortedScreenshots {
    param([string]$Folder)

    $exts = @('.png', '.bmp')
    $files = Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue |
        Where-Object { $exts -contains $_.Extension.ToLowerInvariant() }

    # Same numeric-aware ordering as the old PSImgStitcherEngine
    # NaturalFileComparer: split each filename on runs of digits and
    # compare digit-runs numerically, everything else as plain text.
    $withKey = foreach ($f in $files) {
        $parts = [regex]::Split($f.Name, '(\d+)')
        [PSCustomObject]@{ File = $f; Parts = $parts }
    }
    $sorted = $withKey | Sort-Object -Property @{
        Expression = {
            ($_.Parts | ForEach-Object {
                if ($_ -match '^\d+$') { $_.PadLeft(20, '0') } else { $_.ToLowerInvariant() }
            }) -join "`0"
        }
    }
    return @($sorted | ForEach-Object { $_.File })
}

# ------------------------------------------------------------------ mime

$MimeTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.png'  = 'image/png'
    '.bmp'  = 'image/bmp'
    '.json' = 'application/json; charset=utf-8'
}

function Get-Mime([string]$path) {
    $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    if ($MimeTypes.ContainsKey($ext)) { return $MimeTypes[$ext] }
    return 'application/octet-stream'
}

# --------------------------------------------------------------- listener

function Find-OpenPort([int]$preferred) {
    if ($preferred -gt 0) { return $preferred }
    for ($p = 8765; $p -lt 8865; $p++) {
        $listener = $null
        try {
            $listener = New-Object System.Net.HttpListener
            $listener.Prefixes.Add("http://localhost:$p/")
            $listener.Start()
            $listener.Stop()
            return $p
        }
        catch { continue }
        finally { if ($listener) { $listener.Close() } }
    }
    throw 'No open port found in range 8765-8864.'
}

$Port = Find-OpenPort -preferred $Port
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()

# Written only once the listener is genuinely up - the launcher polls for
# this instead of guessing from a fixed timeout, which is what made the
# old "wait 900ms and hope" check flaky under load.
if ($LogPath) {
    try { Set-Content -LiteralPath "$LogPath.ready" -Value $Port -Encoding ASCII } catch { }
}

$url = "http://localhost:$Port/"
Write-Log "Serving Screenshot Stitcher at $url"
Write-Log "Session folder: $SourceFolder"
Write-Log 'Press Ctrl+C here (or click Close in the browser) to stop.'

function Open-DefaultBrowser {
    <#
        Opening a URL is really "ask Windows to resolve the http:// protocol
        association and launch whatever's registered for it" - and that
        association is surprisingly easy to end up broken (a Windows update,
        a policy, a prior browser uninstall leaving a stale ProgID) even
        when a normal-looking default browser is installed. A failure here
        must never be allowed to take the server down with it, so every
        attempt is wrapped and logged rather than left to throw.
    #>
    param([string]$Url)

    $attempts = @(
        { Start-Process -FilePath $Url },
        { Start-Process -FilePath 'rundll32.exe' -ArgumentList 'url.dll,FileProtocolHandler', $Url },
        { Start-Process -FilePath 'explorer.exe' -ArgumentList $Url }
    )
    foreach ($attempt in $attempts) {
        try {
            & $attempt | Out-Null
            return $true
        }
        catch {
            Write-Warning "Browser launch attempt failed: $($_.Exception.Message)"
        }
    }

    # Last resort: find Edge directly via its registered App Path (Edge
    # ships with every supported Windows version, so this key is reliable
    # even when the http:// association itself is broken) and launch it
    # pointed straight at the URL, bypassing protocol resolution entirely.
    try {
        $edgePath = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -ErrorAction Stop).'(default)'
        if ($edgePath -and (Test-Path -LiteralPath $edgePath)) {
            Start-Process -FilePath $edgePath -ArgumentList $Url | Out-Null
            return $true
        }
    }
    catch {
        Write-Warning "Edge fallback failed: $($_.Exception.Message)"
    }

    return $false
}

try {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [System.Windows.Forms.Clipboard]::SetText($url)
}
catch { }

if (-not (Open-DefaultBrowser -Url $url)) {
    Write-Host "Couldn't open a browser automatically. The address has been copied to your clipboard - paste it into any browser:" -ForegroundColor Yellow
    Write-Host "  $url" -ForegroundColor Yellow
}

$running = $true
while ($running -and $listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response

    try {
        $path = $request.Url.AbsolutePath

        if ($path -eq '/api/list') {
            $files = Get-NaturalSortedScreenshots -Folder $SourceFolder
            $payload = [PSCustomObject]@{
                folder = $SourceFolder
                files  = @($files | ForEach-Object { $_.Name })
            }
            $json = $payload | ConvertTo-Json -Depth 3
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = 'application/json; charset=utf-8'
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        elseif ($path -eq '/api/shutdown' -and $request.HttpMethod -eq 'POST') {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
            $response.ContentType = 'application/json; charset=utf-8'
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            $running = $false
        }
        elseif ($path.StartsWith('/shots/')) {
            $name = [System.Uri]::UnescapeDataString($path.Substring('/shots/'.Length))
            # Reject path traversal - only serve plain filenames from SourceFolder itself.
            if ($name -match '[\\/]' -or $name -match '\.\.') {
                $response.StatusCode = 400
            }
            else {
                $filePath = Join-Path $SourceFolder $name
                if (Test-Path -LiteralPath $filePath -PathType Leaf) {
                    $bytes = [System.IO.File]::ReadAllBytes($filePath)
                    $response.ContentType = Get-Mime $filePath
                    $response.ContentLength64 = $bytes.Length
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                }
                else {
                    $response.StatusCode = 404
                }
            }
        }
        else {
            # Static webapp files. "/" -> index.html.
            $rel = if ($path -eq '/') { 'index.html' } else { $path.TrimStart('/') }
            $filePath = Join-Path $WebAppRoot $rel
            $fullWebAppRoot = (Resolve-Path -LiteralPath $WebAppRoot).Path
            $resolvedFile = try { (Resolve-Path -LiteralPath $filePath -ErrorAction Stop).Path } catch { $null }
            if ($resolvedFile -and $resolvedFile.StartsWith($fullWebAppRoot, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedFile -PathType Leaf)) {
                $bytes = [System.IO.File]::ReadAllBytes($resolvedFile)
                $response.ContentType = Get-Mime $resolvedFile
                $response.ContentLength64 = $bytes.Length
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            else {
                $response.StatusCode = 404
            }
        }
    }
    catch {
        try { $response.StatusCode = 500 } catch { }
        Write-Warning "Request error: $_"
    }
    finally {
        try { $response.OutputStream.Close() } catch { }
    }
}

$listener.Stop()
$listener.Close()
Write-Log 'Server stopped.'

}
catch {
    Write-Log "FATAL: $($_.Exception.Message)"
    Write-Log "$($_.ScriptStackTrace)"
    exit 1
}
