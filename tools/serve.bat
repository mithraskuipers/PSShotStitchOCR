@echo off
setlocal
set "HERE=%~dp0"
set "PORT=%~1"
if "%PORT%"=="" set "PORT=8000"
for %%I in ("%HERE%..\src") do set "SRCDIR=%%~fI"
for %%I in ("%HERE%..") do set "PROJDIR=%%~fI"

powershell -NoProfile -NoLogo -Command ^
  "$s = [ScriptBlock]::Create((Get-Content -Raw -LiteralPath '%HERE%serve.ps1'));" ^
  "& $s -Port %PORT% -WebRoot '%SRCDIR%' -ProjectRoot '%PROJDIR%'"
