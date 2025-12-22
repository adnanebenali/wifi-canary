@echo off
REM Double-click me. I just run the PowerShell reloader with your args.
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0reload-wifi-canary.ps1" %*
echo.
pause
