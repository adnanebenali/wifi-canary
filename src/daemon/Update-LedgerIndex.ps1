<# Generate /logs/ledger-index.json atomically
    Looks for *.ledger.json files in the logs folder and emits:
    [ { "date":"YYYY-MM-DD", "path":"YYYY-MM-DD.ledger.json" }, ... ]
#>
param(
  [string]$LogRoot = (Join-Path $PSScriptRoot "..\logs")
)
$ErrorActionPreference = "Stop"
$indexPath = Join-Path $LogRoot "ledger-index.json"
$tmpPath   = "$indexPath.tmp"

$items = Get-ChildItem -Path $LogRoot -Filter "*.ledger.json" -File |
  Sort-Object Name |
  ForEach-Object {
    if ($_.BaseName -match '^\d{4}-\d{2}-\d{2}\.ledger$') {
      $date = ($_.BaseName -replace '\.ledger$','')
      [PSCustomObject]@{ date = $date; path = $_.Name }
    }
  } | Where-Object { $_ -ne $null }

$items | ConvertTo-Json -Depth 3 | Set-Content -Encoding utf8 -Path $tmpPath
Move-Item -Force $tmpPath $indexPath
Write-Host "Wrote $indexPath with $($items.Count) entries."
