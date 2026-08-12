@echo off
setlocal enabledelayedexpansion
set "HERE=%~dp0"
set "LOCKFILE=%HERE%.serve.lock"

if not exist "%LOCKFILE%" (
    echo No .serve.lock found - server doesn't look like it's running.
    goto :end
)

set /p LOCKCONTENT=<"%LOCKFILE%"
for /f "tokens=1,2 delims=:" %%a in ("%LOCKCONTENT%") do (
    set "SERVEPID=%%a"
    set "SERVEPORT=%%b"
)

if "%SERVEPID%"=="" (
    echo Couldn't parse .serve.lock - removing it.
    del "%LOCKFILE%" >nul 2>&1
    goto :end
)

echo Stopping CodeOCR server (PID %SERVEPID%, port %SERVEPORT%)...
taskkill /PID %SERVEPID% /F >nul 2>&1
del "%LOCKFILE%" >nul 2>&1
echo Done.

:end
pause
