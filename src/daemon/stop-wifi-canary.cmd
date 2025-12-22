@echo off
setlocal
REM Stops any running wifi-canary daemon processes (wifi-canary.ps1 -Daemon).

pwsh -NoProfile -ExecutionPolicy Bypass -Command ^
  "$procs = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'wifi-canary\.ps1' -and $_.CommandLine -match '\-Daemon' }; " ^
  "if(-not $procs){ Write-Host 'wifi-canary: no daemon found.'; exit 0 }; " ^
  "foreach($p in $procs){ Write-Host ('Stopping PID {0}' -f $p.ProcessId); try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }"

endlocal
