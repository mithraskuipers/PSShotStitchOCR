@echo off
rem Standalone entry point into Review & Stitch: launches
rem Start-ReviewWebServer.ps1, which serves the webapp\ review/stitch UI
rem locally and opens it in your browser. If no -SourceFolder is passed,
rem the script itself prompts with a folder-browser dialog.
rem
rem Normally you never need this file directly - RegionScreenshot.ps1's
rem Stop hotkey hands off to Review & Stitch automatically (see its
rem Start-ReviewTool function). This launcher is for opening the
rem review/stitch UI on its own, against an older session folder.
rem
rem NOTE: this file was not present in the uploaded project (it was missing
rem from the original zip/export) and has been reconstructed to match the
rem invocation style of this project's other launchers. Please compare
rem against your original if you still have it.
setlocal
set "HERE=%~dp0"
for %%I in ("%HERE%..\ps1") do set "PS1DIR=%%~fI"

powershell -STA -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%PS1DIR%\Start-ReviewWebServer.ps1"
