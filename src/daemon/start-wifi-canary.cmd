@echo off
setlocal
REM Starts the wifi-canary daemon in a new window.

set "SCRIPT_DIR=%~dp0"
pushd "%SCRIPT_DIR%\..\.."
set "REPO_ROOT=%CD%"
set "LOGS=%REPO_ROOT%\logs"
if not exist "%LOGS%" mkdir "%LOGS%"

echo Starting wifi-canary daemon...
start "wifi-canary daemon" pwsh -NoProfile -ExecutionPolicy Bypass -File "%REPO_ROOT%\src\daemon\wifi-canary.ps1" -Daemon

popd
endlocal
