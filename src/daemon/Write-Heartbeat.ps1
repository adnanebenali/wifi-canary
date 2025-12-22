<# Write /logs/heartbeat.json atomically
    Emits: { "ts": "2025-11-08T15:04:05.123-05:00" }
#>
param(
  [string]$LogRoot = (Join-Path $PSScriptRoot "..\logs")
)
$ErrorActionPreference = "Stop"
$hbPath = Join-Path $LogRoot "heartbeat.json"
$tmp    = "$hbPath.tmp"

@{ ts = (Get-Date).ToString("o") } | ConvertTo-Json | Set-Content -Encoding utf8 -Path $tmp
Move-Item -Force $tmp $hbPath
Write-Host "Updated heartbeat.json"
