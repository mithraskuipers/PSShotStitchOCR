@echo off
REM Double-click launcher for Configure.ps1
REM Runs with normal user rights only - never asks for admin/elevation.

set "REGION_SCREENSHOT_ROOT=%~dp0..\ps1\"
cd /d "%REGION_SCREENSHOT_ROOT%"

if not exist "Configure.ps1" (
    echo ERROR: Configure.ps1 not found in this folder:
    echo   %cd%
    pause
    exit /b 1
)

powershell -NoProfile -STA -Command "$src = Get-Content -LiteralPath (Join-Path $env:REGION_SCREENSHOT_ROOT 'Configure.ps1') -Raw; Invoke-Expression $src"

if errorlevel 1 (
    echo.
    echo The script exited with an error ^(see above^).
    pause
)
