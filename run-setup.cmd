@echo off
setlocal
where pwsh >nul 2>nul
if errorlevel 1 goto use_windows_powershell

pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-codex-accounts.ps1"
goto after_run

:use_windows_powershell
where powershell >nul 2>nul
if errorlevel 1 (
  echo PowerShell was not found.
  pause
  exit /b 1
)
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-codex-accounts.ps1"

:after_run
set EXITCODE=%ERRORLEVEL%
echo.
if not "%EXITCODE%"=="0" echo The setup ended with an error.
pause
exit /b %EXITCODE%
