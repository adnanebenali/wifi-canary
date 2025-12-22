#requires -Version 7.0
param(
  [int]$Days = 2,
  [int]$BucketMinutes = 1,
  [int]$EverySeconds = 15, # default 15s
  [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$RepoRoot = (Resolve-Path (Join-Path $root '..\..')).Path
$ps1 = Join-Path $root 'wifi-canary.ps1'
$logs = Join-Path $RepoRoot 'logs\'
New-Item -ItemType Directory -Force -Path $logs | Out-Null

# Per-step logs (distinct out/err files)
$ledgerOut = Join-Path $logs 'reload-ledger.out.log'
$ledgerErr = Join-Path $logs 'reload-ledger.err.log'
$heatmapOut = Join-Path $logs 'reload-heatmap.out.log'
$heatmapErr = Join-Path $logs 'reload-heatmap.err.log'
$startOut = Join-Path $logs 'start-trace.out.log'
$startErr = Join-Path $logs 'start-trace.err.log'

Write-Host "[env] Using pwsh at: $((Get-Command pwsh).Source)" -ForegroundColor DarkGray
Write-Host "[stop] Stopping any running daemon..."
Get-CimInstance Win32_Process |
Where-Object { $_.CommandLine -match 'wifi-canary\.ps1.*-Daemon' } |
ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }

function Run-Step {
  param(
    [string]$Title,
    [string[]]$Args,
    [string]$OutLog,
    [string]$ErrLog
  )

  Write-Host "[$Title] pwsh -File wifi-canary.ps1 $($Args -join ' ')" -ForegroundColor Cyan
  $base = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ps1)
  $argList = $base + $Args

  $p = Start-Process -FilePath 'pwsh' `
    -ArgumentList $argList `
    -NoNewWindow -PassThru `
    -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog

  $p.WaitForExit()
  if ($p.ExitCode -ne 0) {
    Write-Host "[ERROR] $Title failed (exit $($p.ExitCode)). Last 80 lines (out/err):" -ForegroundColor Red
    if (Test-Path $OutLog) { Write-Host "--- OUT ---"; Get-Content -Path $OutLog -Tail 80 | Write-Host }
    if (Test-Path $ErrLog) { Write-Host "--- ERR ---"; Get-Content -Path $ErrLog -Tail 80 | Write-Host }
    if (-not $NoPause) { Read-Host "Press Enter to close" }
    exit $p.ExitCode
  }
}

# 1) Ledger then 2) Heatmap
Run-Step -Title 'ledger'  -Args @('-Ledger', '-Days', "$Days", '-BucketMinutes', "$BucketMinutes", '-EverySeconds', "$EverySeconds") -OutLog $ledgerOut  -ErrLog $ledgerErr
Run-Step -Title 'heatmap' -Args @('-Heatmap', '-Days', "$Days", '-BucketMinutes', "$BucketMinutes", '-EverySeconds', "$EverySeconds") -OutLog $heatmapOut -ErrLog $heatmapErr

# 3) Start daemon (distinct out/err logs already)
Write-Host "[daemon] Starting daemon (EverySeconds=$EverySeconds)..."
$daemonArgs = @(
  '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ps1,
  '-Daemon', '-EverySeconds', "$EverySeconds"
)
Start-Process -WindowStyle Hidden -FilePath 'pwsh' -ArgumentList $daemonArgs `
  -RedirectStandardOutput $startOut -RedirectStandardError $startErr

Write-Host "`n[ok] Reload complete."
Write-Host "[logs] Ledger OUT : $ledgerOut"
Write-Host "[logs] Ledger ERR : $ledgerErr"
Write-Host "[logs] Heatmap OUT: $heatmapOut"
Write-Host "[logs] Heatmap ERR: $heatmapErr"
Write-Host "[logs] Daemon OUT : $startOut"
Write-Host "[logs] Daemon ERR : $startErr"
if (-not $NoPause) { Read-Host "Press Enter to close" }
