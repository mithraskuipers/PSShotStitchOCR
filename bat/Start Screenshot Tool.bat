@echo off
rem Launches RegionScreenshot.ps1 in STA mode with execution policy bypassed,
rem as its own header comments require:
rem   powershell -STA -NoProfile -ExecutionPolicy Bypass -File RegionScreenshot.ps1
rem
rem NOTE: this file was not present in the uploaded project (it was missing
rem from the original zip/export) and has been reconstructed from the exact
rem invocation documented inside RegionScreenshot.ps1 itself. Please compare
rem against your original if you still have it.
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..\ps1") do set "PS1DIR=%%~fI"

rem Fallback root env var, used when RegionScreenshot.ps1 is ever loaded via
rem Invoke-Expression instead of -File (see its own comments on $ScriptRoot).
set "REGION_SCREENSHOT_ROOT=%PS1DIR%"

powershell -STA -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%PS1DIR%\RegionScreenshot.ps1"
