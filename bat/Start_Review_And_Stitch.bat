@echo off
setlocal

REM ==========================================================
REM  Review & Stitch launcher (PowerShell edition)
REM  Zero-dependency tool:
REM    - Windows PowerShell 5.1 (built into Windows)
REM    - or PowerShell 7 (pwsh)
REM  Normally launched automatically by RegionScreenshot.ps1 when you stop
REM  auto-capture. Run this directly to review/stitch any folder by hand.
REM ==========================================================

set "PS1_DIR=%~dp0..\ps1\"
cd /d "%PS1_DIR%"

REM ----------------------------------------------------------
REM Verify required files exist
REM ----------------------------------------------------------

if not exist "ReviewAndStitchScreenshots.ps1" (
    echo ERROR: ReviewAndStitchScreenshots.ps1 not found in this folder:
    echo    %CD%
    pause
    exit /b 1
)

if not exist "PSImgStitcherEngine.ps1" (
    echo ERROR: PSImgStitcherEngine.ps1 not found in this folder:
    echo    %CD%
    pause
    exit /b 1
)

REM ----------------------------------------------------------
REM Find a usable PowerShell host
REM ----------------------------------------------------------

set "PS_CMD="

where pwsh >nul 2>nul && set "PS_CMD=pwsh"

if not defined PS_CMD (
    where powershell >nul 2>nul && set "PS_CMD=powershell"
)

if not defined PS_CMD (
    echo ERROR: PowerShell was not found on this system.
    echo Windows PowerShell ships with every supported version of Windows.
    echo Something is very wrong if you are seeing this.
    pause
    exit /b 1
)

REM ----------------------------------------------------------
REM Unblock all PowerShell scripts in the ps1 folder
REM ----------------------------------------------------------

powershell.exe ^
    -NoProfile ^
    -ExecutionPolicy Bypass ^
    -Command ^
    "Get-ChildItem -LiteralPath '%PS1_DIR%' -Filter *.ps1 | Unblock-File"

REM ----------------------------------------------------------
REM Run the tool
REM ----------------------------------------------------------

%PS_CMD% ^
    -NoProfile ^
    -STA ^
    -ExecutionPolicy Bypass ^
    -File "%PS1_DIR%ReviewAndStitchScreenshots.ps1" %*

if errorlevel 1 (
    echo.
    echo The script exited with an error (see above).
    pause
)

endlocal
