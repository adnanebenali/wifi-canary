@echo off
setlocal
REM Serves the repo root so /logs and /src/dashboard are accessible.

set "SCRIPT_DIR=%~dp0"
pushd "%SCRIPT_DIR%\..\.."
echo Starting local web server on port 8080 from: %CD%
start "" http://localhost:8080/src/dashboard/
pwsh -NoProfile -Command "python -m http.server 8080"
popd
endlocal
