@echo off
rem Launches Configure.ps1 in STA mode with execution policy bypassed, as
rem its own header comments require:
rem   powershell -STA -NoProfile -ExecutionPolicy Bypass -File Configure.ps1
rem
rem NOTE: this file was not present in the uploaded project (it was missing
rem from the original zip/export) and has been reconstructed from the exact
rem invocation documented inside Configure.ps1 itself. Please compare
rem against your original if you still have it.
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..\ps1") do set "PS1DIR=%%~fI"
set "REGION_SCREENSHOT_ROOT=%PS1DIR%"

powershell -STA -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%PS1DIR%\Configure.ps1"
