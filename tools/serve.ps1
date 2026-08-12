param(
    [int]$Port = 8000,
    # Folder to SERVE (contains index.html/app.js). Passed in explicitly
    # rather than relying on $PSScriptRoot, for two independent reasons:
    #   1. serve.bat runs this script's text as a dynamically-created
    #      scriptblock (to dodge Group-Policy-locked execution policy -
    #      see serve.bat), and $PSScriptRoot comes back EMPTY when there's
    #      no real script file behind the call.
    #   2. Even if it didn't, $PSScriptRoot would resolve to tools\ (where
    #      this file lives), not the src\ folder that holds the content.
    [string]$WebRoot,
    # Folder to write .serve.lock into - the project root, so stop.bat
    # (which lives there) can find it. Kept separate from $WebRoot so the
    # lock file doesn't end up sitting inside src\.
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'
$root = if ($WebRoot) { $WebRoot } elseif ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$lockRoot = if ($ProjectRoot) { $ProjectRoot } else { $root }

function Wait-BeforeClose {
    Write-Host ""
    Read-Host "Press Enter to close this window"
}

try {
    # Try the requested port first; if it's already in use, try the next
    # ones up automatically instead of just failing, so the common case
    # (leftover server still running from last time, or something else on
    # 8000) doesn't need the user to pick a port by hand.
    $maxAttempts = 20
    $originalPort = $Port
    $listener = $null

    for ($attempt = 0; $attempt -lt $maxAttempts; $attempt++) {
        $candidate = New-Object System.Net.HttpListener
        $candidate.Prefixes.Add("http://localhost:$Port/")

        try {
            $candidate.Start()
            $listener = $candidate
            break
        }
        catch [System.Net.HttpListenerException] {
            if ($_.Exception.ErrorCode -eq 5) {
                Write-Host "ERROR: Could not start the server on port $Port." -ForegroundColor Red
                Write-Host $_.Exception.Message -ForegroundColor Red
                Write-Host ""
                Write-Host "This is a permissions problem, common on managed/corporate PCs." -ForegroundColor Yellow
                Write-Host "Fix (one-time, needs admin): open PowerShell as Administrator and run:" -ForegroundColor Yellow
                Write-Host "  netsh http add urlacl url=http://localhost:$Port/ user=$env:USERDOMAIN\$env:USERNAME" -ForegroundColor White
                Write-Host "After that you can run serve.bat normally, no admin needed." -ForegroundColor Yellow
                Wait-BeforeClose
                exit 1
            }
            elseif ($_.Exception.ErrorCode -eq 183 -or $_.Exception.Message -match "already in use|address already|conflicts with an existing registration") {
                Write-Host "Port $Port is already in use - trying $($Port + 1)..." -ForegroundColor Yellow
                $Port++
                continue
            }
            else {
                Write-Host "ERROR: Could not start the server on port $Port." -ForegroundColor Red
                Write-Host $_.Exception.Message -ForegroundColor Red
                Wait-BeforeClose
                exit 1
            }
        }
    }

    if (-not $listener) {
        Write-Host "ERROR: Could not find a free port after trying $originalPort through $Port." -ForegroundColor Red
        Write-Host "Free one of those up, or run serve.bat with a different starting port, e.g.:" -ForegroundColor Yellow
        Write-Host "  serve.bat 9000" -ForegroundColor White
        Wait-BeforeClose
        exit 1
    }

    if ($Port -ne $originalPort) {
        Write-Host "Port $originalPort was already in use - using $Port instead." -ForegroundColor Yellow
    }

    Write-Host "Serving '$root' at http://localhost:$Port/ (Ctrl+C to stop)" -ForegroundColor Green

    # Record our PID and the actual port we ended up on, so stop.bat can find
    # and kill this exact process even if we hopped past a busy port above.
    # Written to $lockRoot (the project root), not $root (the served src\
    # folder), so it sits right next to stop.bat.
    $lockFile = Join-Path $lockRoot '.serve.lock'
    "$PID`:$Port" | Set-Content -LiteralPath $lockFile -Encoding ASCII

    $mimeTypes = @{
        ".html" = "text/html"
        ".htm"  = "text/html"
        ".js"   = "application/javascript"
        ".mjs"  = "application/javascript"
        ".wasm" = "application/wasm"
        ".css"  = "text/css"
        ".json" = "application/json"
        ".png"  = "image/png"
        ".jpg"  = "image/jpeg"
        ".jpeg" = "image/jpeg"
        ".gif"  = "image/gif"
        ".svg"  = "image/svg+xml"
        ".ico"  = "image/x-icon"
        ".txt"  = "text/plain"
        ".data" = "application/octet-stream"
    }

    try {
        while ($listener.IsListening) {
            $context = $listener.GetContext()
            $request = $context.Request
            $response = $context.Response

            $localPath = $request.Url.LocalPath
            if ($localPath -eq "/") { $localPath = "/index.html" }

            # Single-slot hand-off from the Screenshot Stitcher's
            # /api/send-to-ocr: written to $lockRoot\handoff\pending.png
            # (the project root, not $root/WebRoot - so it's never
            # reachable as an ordinary static file). Served once, then
            # deleted, so a page refresh after the fact doesn't re-load a
            # stale image and a second hand-off can't accidentally combine
            # with a leftover one.
            if ($localPath -eq "/api/pending-image") {
                $handoffFile = Join-Path $lockRoot 'handoff\pending.png'
                $nameFile = Join-Path $lockRoot 'handoff\pending.name.txt'
                if (Test-Path -LiteralPath $handoffFile -PathType Leaf) {
                    $bytes = [IO.File]::ReadAllBytes($handoffFile)
                    if (Test-Path -LiteralPath $nameFile -PathType Leaf) {
                        $origName = (Get-Content -LiteralPath $nameFile -Raw).Trim()
                        # Header values must be ASCII-safe - percent-encode so any
                        # unicode/space in the filename survives the round trip.
                        $response.Headers.Add('X-Original-Name', [Uri]::EscapeDataString($origName))
                        Remove-Item -LiteralPath $nameFile -Force -ErrorAction SilentlyContinue
                    }
                    Remove-Item -LiteralPath $handoffFile -Force -ErrorAction SilentlyContinue
                    $response.ContentType = 'image/png'
                    $response.ContentLength64 = $bytes.Length
                    $response.StatusCode = 200
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                } else {
                    $response.StatusCode = 404
                    $notFoundBytes = [Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"no pending image"}')
                    $response.ContentType = 'application/json'
                    $response.ContentLength64 = $notFoundBytes.Length
                    $response.OutputStream.Write($notFoundBytes, 0, $notFoundBytes.Length)
                }
            }
            else {

            $filePath = Join-Path $root ($localPath.TrimStart("/") -replace "/", [IO.Path]::DirectorySeparatorChar)

            if (Test-Path $filePath -PathType Leaf) {
                $ext = [IO.Path]::GetExtension($filePath).ToLower()
                $contentType = $mimeTypes[$ext]
                if (-not $contentType) { $contentType = "application/octet-stream" }

                $bytes = [IO.File]::ReadAllBytes($filePath)
                $response.ContentType = $contentType
                $response.ContentLength64 = $bytes.Length
                $response.StatusCode = 200
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            } else {
                $response.StatusCode = 404
                $notFoundBytes = [Text.Encoding]::UTF8.GetBytes("404 Not Found: $localPath")
                $response.ContentLength64 = $notFoundBytes.Length
                $response.OutputStream.Write($notFoundBytes, 0, $notFoundBytes.Length)
            }

            }

            $response.OutputStream.Close()
            Write-Host "$($request.HttpMethod) $localPath -> $($response.StatusCode)"
        }
    }
    finally {
        if ($listener.IsListening) { $listener.Stop() }
        $listener.Close()
        if (Test-Path $lockFile) { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }
    }
}
catch {
    Write-Host ""
    Write-Host "The server stopped because of an unexpected error:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
    Wait-BeforeClose
    exit 1
}
