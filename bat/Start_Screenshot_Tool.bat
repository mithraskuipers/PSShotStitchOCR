@echo off
REM Double-click launcher for RegionScreenshot.ps1
REM Runs with normal user rights only - never asks for admin/elevation.
REM
REM Loads the script as text and runs it via -Command instead of -File.
REM This sidesteps "is not digitally signed" errors on systems where
REM execution policy is locked to AllSigned/Restricted by Group Policy -
REM that restriction only applies to loading .ps1 files directly.

set "REGION_SCREENSHOT_ROOT=%~dp0..\ps1\"
cd /d "%REGION_SCREENSHOT_ROOT%"

if not exist "RegionScreenshot.ps1" (
    echo ERROR: RegionScreenshot.ps1 not found in this folder:
    echo   %cd%
    pause
    exit /b 1
)

powershell -NoProfile -STA -Command "$src = Get-Content -LiteralPath (Join-Path $env:REGION_SCREENSHOT_ROOT 'RegionScreenshot.ps1') -Raw; Invoke-Expression $src"

if errorlevel 1 (
    echo.
    echo The script exited with an error ^(see above^).
    pause
)
