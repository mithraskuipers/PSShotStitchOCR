@echo off
REM ==========================================================
REM  Start_All.bat - single entry point for the whole pipeline
REM
REM  This just launches the region-capture tool (ps1\RegionScreenshot.ps1).
REM  When you stop capturing, it automatically hands off to Review & Stitch
REM  on its own (AutoLaunchReviewOnStop is enabled in ps1\config.json),
REM  which in turn calls the stitching engine. You don't need to run
REM  anything else by hand - capture, review, and stitch all happen from
REM  this one launcher.
REM
REM  To tune settings first, run bat\Configure_Screenshot_Tool.bat instead.
REM ==========================================================

set "REGION_SCREENSHOT_ROOT=%~dp0ps1\"
cd /d "%REGION_SCREENSHOT_ROOT%"

if not exist "RegionScreenshot.ps1" (
    echo ERROR: RegionScreenshot.ps1 not found in the expected folder:
    echo   %REGION_SCREENSHOT_ROOT%
    pause
    exit /b 1
)

powershell -NoProfile -STA -Command "$src = Get-Content -LiteralPath (Join-Path $env:REGION_SCREENSHOT_ROOT 'RegionScreenshot.ps1') -Raw; Invoke-Expression $src"

if errorlevel 1 (
    echo.
    echo The script exited with an error ^(see above^).
    pause
)
