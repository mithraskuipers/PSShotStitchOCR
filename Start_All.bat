@echo off
rem Entry point for the whole toolkit. Asks what you want to run, then
rem hands off to the matching launcher (same ones under bat\ / tools\ that
rem you can also run directly).
setlocal
set "HERE=%~dp0"

:menu
cls
echo ================================================
echo   PSShotStitchOCR
echo ================================================
echo.
echo   1. Screenshot tool only        (no hand-off to Review ^& Stitch)
echo   2. Review ^& Stitch only        (open the review/stitch web app)
echo   3. OCR app only                (open CodeOCR)
echo   4. Full pipeline                (default: screenshot -^> auto hand-off
echo                                    to Review ^& Stitch on stop)
echo   5. Exit
echo.
set "CHOICE="
set /p "CHOICE=Choose an option (1-5): "

if "%CHOICE%"=="1" goto :screenshot_only
if "%CHOICE%"=="2" goto :review_only
if "%CHOICE%"=="3" goto :ocr_only
if "%CHOICE%"=="4" goto :pipeline
if "%CHOICE%"=="5" goto :eof

echo.
echo Invalid choice - please enter a number from 1 to 5.
echo.
pause
goto :menu

:screenshot_only
rem Same launch as "Start Screenshot Tool.bat", but with -NoAutoReview so
rem this run never hands off to Review & Stitch when auto-capture stops,
rem no matter what AutoLaunchReviewOnStop is set to in config.json.
set "PS1DIR=%HERE%ps1"
set "REGION_SCREENSHOT_ROOT=%PS1DIR%"
powershell -STA -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%PS1DIR%\RegionScreenshot.ps1" -NoAutoReview
goto :eof

:review_only
call "%HERE%bat\Start Review & Stitch.bat"
goto :eof

:ocr_only
call "%HERE%tools\serve.bat"
goto :eof

:pipeline
rem Current default behavior: screenshot tool with its normal
rem AutoLaunchReviewOnStop-driven hand-off to Review & Stitch (and, from
rem there, "Send to OCR" hands off into the OCR app).
call "%HERE%bat\Start Screenshot Tool.bat"
goto :eof
