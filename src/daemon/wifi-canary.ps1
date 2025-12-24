#requires -Version 7.0
<#  wifi-canary.ps1  (PowerShell 5 safe)
    - Keeps a simple CSV of samples
    - Builds a per-day ledger (minute buckets, worst-sample-wins)
    - Renders a clean heatmap (rows=hours, cols=minutes)
    - Auto-refreshes every 65 seconds
#>

param(
  [switch]$Daemon,
  [switch]$Sample,
  [switch]$Ledger,
  [switch]$Heatmap,
  [switch]$BackfillRssi,

  [int]$EverySeconds = 15, # daemon sampling period
  [int]$Days = 2, # how many days to include for ledger/heatmap regen
  [int]$BucketMinutes = 1, # minute bucket size (1 recommended)
  [string]$LogRoot = ''            # default computed below
)

# normalize EverySeconds once
if ($EverySeconds -eq '*') {
  $EverySeconds = 15   # treat '*' as “run as fast as the loop allows”; pick a sane value
}
$EverySeconds = [int]$EverySeconds

# --- bootstrap (PS5-safe) ---
$ErrorActionPreference = 'Stop'

# Resolve paths
$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
  $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
}

# Try to infer repo root (works whether script is in src\daemon or daemon\)
$RepoRoot = $null
$cand1 = $null
$cand2 = $null
try { $cand1 = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path } catch {}
try { $cand2 = (Resolve-Path (Join-Path $ScriptDir '..')).Path } catch {}

function Test-RepoRoot([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $false }
  if (Test-Path -LiteralPath (Join-Path $p '.git')) { return $true }
  if (Test-Path -LiteralPath (Join-Path $p 'README.md')) { return $true }
  return $false
}

if (Test-RepoRoot $cand1) { $RepoRoot = $cand1 }
elseif (Test-RepoRoot $cand2) { $RepoRoot = $cand2 }
else { $RepoRoot = (Get-Location).Path }

# Default logs live at repo-root\logs (unless caller provides -LogRoot)
if ([string]::IsNullOrWhiteSpace($LogRoot)) { $LogRoot = Join-Path $RepoRoot 'logs' }
if (-not (Test-Path -LiteralPath $LogRoot)) { New-Item -ItemType Directory -Path $LogRoot | Out-Null }

$ErrLog = Join-Path $LogRoot 'daemon-errors.log'
$Beat = Join-Path $LogRoot 'daemon-heartbeat.txt'
$BeatJson = Join-Path $LogRoot 'heartbeat.json'
Add-Content -LiteralPath $ErrLog -Value ("{0:o}  bootstrap OK (PS {1})  scriptFile={2}" -f (Get-Date), $PSVersionTable.PSVersion, $__scriptFile)

# Optional: avoid weird “â€¦” characters in console
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}



# ---------- basics ----------

function Ensure-Dir($p) { if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p | Out-Null } }
Ensure-Dir $LogRoot

# ---------- parsing helpers (PS5-safe) ----------
function Try-ParseDouble([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  $v = 0.0
  if ([double]::TryParse($s, [ref]$v)) { return $v }
  return $null
}

# Approximate Windows-style mapping from 0..100 "Signal quality" to RSSI (dBm)
function Convert-SignalPctToRssi {
  param(
    [int]$SignalPct
  )

  if ($SignalPct -le 0) { return -100 }  # very bad
  if ($SignalPct -ge 100) { return -50 }   # very good

  # Linear interpolation: 0 -> -100 dBm, 100 -> -50 dBm
  return [int][math]::Round(($SignalPct / 2.0) - 100)
}

function Write-DebugLog {
  param(
    [string]$Message
  )
  try {
    $path = Join-Path $LogRoot 'wlan-debug.log'
    Add-Content -LiteralPath $path -Value ("{0:o}  {1}" -f (Get-Date), $Message)
  }
  catch {
    # swallow any logging errors; we don't want to break the sampler
  }
}


# ---------- wifi info (tolerant if location is off) ----------
function Get-WlanInfo {
  # Call netsh and join lines into a single string for regex scanning
  $rawLines = & netsh wlan show interfaces 2>$null
  $raw = if ($rawLines) { $rawLines -join "`n" } else { '' }

  if (-not $raw -or $raw -notmatch '(?im)^\s*State\s*:\s*connected\s*$') {
    return [pscustomobject]@{
      Connected = $false; SSID = $null; BSSID = $null; Signal = $null; Rssi = $null
      RxMbps = $null; TxMbps = $null; Channel = $null; Band = $null; Radio = $null
    }
  }

  # Small helper: first capture group or $null
  function _m { param($p) if ($raw -match $p) { $matches[1].Trim() } else { $null } }

  $ssid = _m '(?im)^\s*SSID\s*:\s*(.+)$'
  # Win11 prints "AP BSSID :", others print "BSSID :"
  $bssid = _m '(?im)^\s*(?:AP\s+)?BSSID\s*:\s*([0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5})'
  $signalS = _m '(?im)^\s*Signal\s*:\s*(\d+)\s*%'
  $rssiS = _m '(?im)^\s*Rssi\s*:\s*(-?\d+)'
  $rxS = _m '(?im)^\s*Receive rate\s*\(Mbps\)\s*:\s*([0-9.]+)'
  $txS = _m '(?im)^\s*Transmit rate\s*\(Mbps\)\s*:\s*([0-9.]+)'
  $chanS = _m '(?im)^\s*Channel\s*:\s*(\d+)'
  $band = _m '(?im)^\s*Band\s*:\s*(.+)$'
  $radio = _m '(?im)^\s*Radio type\s*:\s*(.+)$'



  $signal = if ($signalS) { [int]$signalS } else { $null }
  $rssi = if ($rssiS) { [int]$rssiS }   else { $null }
  $rxMbps = if ($rxS) { [int][math]::Round([double]$rxS) } else { $null }
  $txMbps = if ($txS) { [int][math]::Round([double]$txS) } else { $null }
  $channel = if ($chanS) { [int]$chanS }   else { $null }
  if ($bssid) { $bssid = $bssid.ToLower().Replace('-', ':') }

  #Write-DebugLog ("Get-WlanInfo: final Signal={0} Rssi={1}" -f $signal, $rssi)

  [pscustomobject]@{
    Connected = $true
    SSID      = $ssid
    BSSID     = $bssid
    Signal    = $signal   # 0-100
    Rssi      = $rssi     # dBm (negative)
    RxMbps    = $rxMbps
    TxMbps    = $txMbps
    Channel   = $channel
    Band      = $band
    Radio     = $radio
  }
}






# ---------- ping once (ms + loss) ----------
function Ping-Once([string]$Target) {
  try {
    $r = Test-Connection -ComputerName $Target -Count 1 -Quiet:$false -ErrorAction Stop
    # Test-Connection (PS5) returns objects; average ResponseTime is fine for 1 packet
    $ms = ($r | Measure-Object -Property ResponseTime -Average).Average
    return [pscustomobject]@{ Ms = [int]([math]::Round($ms)); LossPct = 0 }
  }
  catch {
    return [pscustomobject]@{ Ms = $null; LossPct = 100 }
  }
}

# ---------- gateway (best effort) ----------
function Get-DefaultGateway {
  try {
    $gw = Get-NetIPConfiguration -ErrorAction Stop |
    Where-Object { $_.IPv4DefaultGateway -and $_.IPv4DefaultGateway.NextHop } |
    Select-Object -First 1 -ExpandProperty IPv4DefaultGateway
    if ($gw -and $gw.NextHop) { return $gw.NextHop }
  }
  catch {}

  try {
    $gw2 = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
    Sort-Object -Property RouteMetric, Metric |
    Select-Object -First 1 -ExpandProperty NextHop
    if ($gw2 -and $gw2 -ne '0.0.0.0') { return $gw2 }
  }
  catch {}

  try {
    $rp = route print 0.0.0.0 2>$null
    foreach ($line in $rp) {
      if ($line -match '^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\d{1,3}(?:\.\d{1,3}){3})\s+') {
        return $matches[1]
      }
    }
  }
  catch {}

  return $null
}

function Measure-IcmpMs {
  param([Parameter(Mandatory)][string]$Target, [int]$TimeoutMs = 1500)
  try {
    $res = Test-Connection -TargetName $Target -Count 1 -TimeoutMilliseconds $TimeoutMs -ErrorAction Stop
    if ($res) { return [int][math]::Round($res.Latency) }
  }
  catch {}
  return $null
}

function Measure-TcpMs {
  param([Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][int]$Port, [int]$TimeoutMs = 1500)
  try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $client = [System.Net.Sockets.TcpClient]::new()
    $iar = $client.BeginConnect($Target, $Port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { $client.Close(); return $null }
    $client.EndConnect($iar); $sw.Stop(); $client.Close()
    return [int]$sw.ElapsedMilliseconds
  }
  catch { return $null }
}

function Measure-HttpMs {
  param([Parameter(Mandatory)][string]$Url, [int]$TimeoutMs = 2000)
  try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Invoke-WebRequest -Method Head -Uri $Url -TimeoutSec ([int][math]::Ceiling($TimeoutMs / 1000.0)) -ErrorAction Stop
    $sw.Stop()
    return [int]$sw.ElapsedMilliseconds
  }
  catch { return $null }
}




function Get-LatencyTargets {
  $t = @()
  $gw = Get-DefaultGateway
  if ($gw) { $t += @{ Name = 'gateway'; Addr = $gw; IsIp = $true } }

  $t += @{ Name = 'cloud-cf'; Addr = '1.1.1.1'; IsIp = $true }   # Cloudflare anycast
  $t += @{ Name = 'cloud-gg'; Addr = '8.8.8.8'; IsIp = $true }   # Google anycast
  $t += @{ Name = 'cf-host'; Addr = 'one.one.one.one'; IsIp = $false } # DNS will be required
  $t += @{ Name = 'gg-host'; Addr = 'dns.google'; IsIp = $false }
  return $t
}

function Test-Latency {
  param([int]$Count = 3, [int]$TimeoutMs = 1500)

  $targets = Get-LatencyTargets
  if (-not $targets -or $targets.Count -eq 0) {
    return [pscustomobject]@{ MedianMs = $null; Loss = $Count }
  }

  $samples = @()
  $loss = 0

  for ($i = 0; $i -lt $Count; $i++) {
    $best = $null
    foreach ($t in $targets) {
      # 1) ICMP
      $ms = Measure-IcmpMs -Target $t.Addr -TimeoutMs $TimeoutMs
      if ($ms -eq $null) {
        # 2) TCP fallbacks
        $ms = Measure-TcpMs -Target $t.Addr -Port 53  -TimeoutMs $TimeoutMs
        if ($ms -eq $null) {
          $ms = Measure-TcpMs -Target $t.Addr -Port 443 -TimeoutMs $TimeoutMs
        }
      }
      if ($ms -eq $null -and -not $t.IsIp) {
        # 3) HTTP only for hostnames (avoid cert/redirect gotchas on raw IP)
        $ms = Measure-HttpMs -Url ("https://{0}/" -f $t.Addr) -TimeoutMs ([math]::Max($TimeoutMs, 2000))
      }
      if ($ms -ne $null) {
        if ($best -eq $null -or $ms -lt $best) { $best = $ms }
      }
    }
    if ($best -ne $null) { $samples += $best } else { $loss++ }
  }

  $median = $null
  if ($samples.Count -gt 0) {
    $sorted = $samples | Sort-Object
    $mid = [int][math]::Floor(($sorted.Count - 1) / 2)
    $median = $sorted[$mid]
  }

  [pscustomobject]@{ MedianMs = $median; Loss = $loss }
}

function Test-LatencySingle {
  param(
    [Parameter(Mandatory)][string]$Target,
    [int]$Count = 2,
    [int]$TimeoutMs = 1500
  )
  $samples = @()
  $loss = 0
  for ($i = 0; $i -lt $Count; $i++) {
    $ms = $null
    try {
      $r = Test-Connection -TargetName $Target -Count 1 -TimeoutMilliseconds $TimeoutMs -ErrorAction Stop
      if ($r) { $ms = [int][math]::Round($r.Latency) }
    }
    catch {}
    if ($ms -eq $null) { $ms = Measure-TcpMs -Target $Target -Port 53  -TimeoutMs $TimeoutMs }
    if ($ms -eq $null) { $ms = Measure-TcpMs -Target $Target -Port 443 -TimeoutMs $TimeoutMs }
    if ($ms -eq $null -and $Target -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
      $ms = Measure-HttpMs -Url ("https://{0}/" -f $Target) -TimeoutMs ([math]::Max($TimeoutMs, 2000))
    }
    if ($ms -ne $null) { $samples += $ms } else { $loss++ }
  }
  $median = $null
  if ($samples.Count -gt 0) {
    $sorted = $samples | Sort-Object
    $median = $sorted[[int][math]::Floor(($sorted.Count - 1) / 2)]
  }

  $lossCount = if ($null -eq $loss) { 0 } else { [int]$loss }
  $cnt = [int]$Count
  $lossPct = if ($cnt -gt 0) { [int][Math]::Round(100.0 * $lossCount / $cnt) } else { 0 }

  return [PSCustomObject]@{
    MedianMs  = $median
    LossCount = $lossCount
    LossPct   = $lossPct
  }
}




# ---------- CSV I/O ----------
function Get-CsvPath([datetime]$d) { return Join-Path $LogRoot ($d.ToString('yyyy-MM-dd') + '.csv') }

function Update-CsvRssi {
  param(
    # 0 = all CSVs in $LogRoot
    # >0 = only CSVs whose date (YYYY-MM-DD.csv) falls in last $Days days
    [int]$Days = 0
  )

  if ([string]::IsNullOrWhiteSpace($LogRoot)) {
    $LogRoot = Join-Path $PSScriptRoot 'logs'
  }

  $files = Get-ChildItem -LiteralPath $LogRoot -Filter '*.csv' -ErrorAction SilentlyContinue |
  Sort-Object Name

  if (-not $files) {
    Write-Host "Update-CsvRssi: no CSV files under $LogRoot"
    return
  }

  if ($Days -gt 0) {
    $cutoff = (Get-Date).Date.AddDays(-$Days + 1)

    $files = $files | Where-Object {
      # Expect filenames like 2025-11-17.csv
      if ($_.BaseName -match '^\d{4}-\d{2}-\d{2}$') {
        $d = Get-Date $_.BaseName
        return ($d -ge $cutoff)
      }
      return $false
    }
  }

  foreach ($f in $files) {
    Write-Host "Update-CsvRssi: processing $($f.Name)..."

    # Import as objects so commas/quotes in SSID etc are handled correctly
    $rows = Import-Csv -LiteralPath $f.FullName -ErrorAction SilentlyContinue
    if (-not $rows) {
      Write-Host "  (skipping: empty or unreadable)"
      continue
    }

    # Make sure every row *can* have an Rssi property
    $hasRssiInHeader = $rows[0].PSObject.Properties.Name -contains 'Rssi'
    if (-not $hasRssiInHeader) {
      # Add Rssi to the first row (this will cause Export-Csv to add the column)
      $rows[0] | Add-Member -NotePropertyName 'Rssi' -NotePropertyValue $null -Force
    }

    foreach ($row in $rows) {
      # Ensure Rssi property exists on each row
      if (-not ($row.PSObject.Properties.Name -contains 'Rssi')) {
        $row | Add-Member -NotePropertyName 'Rssi' -NotePropertyValue $null -Force
      }

      # If Rssi already has a value (from newer collection), don't touch it
      if (-not [string]::IsNullOrWhiteSpace($row.Rssi)) {
        continue
      }

      # Old data path: derive Rssi from SignalPct
      $sigStr = $row.SignalPct
      if ([string]::IsNullOrWhiteSpace($sigStr)) {
        continue
      }

      $sigStr = $sigStr.Trim()
      if ($sigStr.EndsWith('%')) {
        $sigStr = $sigStr.TrimEnd('%')
      }

      if (-not ($sigStr -match '^\d+$')) {
        continue
      }

      $sigVal = [int]$sigStr
      $rssiVal = Convert-SignalPctToRssi -SignalPct $sigVal
      $row.Rssi = $rssiVal
    }

    # Backup original CSV once
    $backup = $f.FullName + '.bak'
    if (-not (Test-Path -LiteralPath $backup)) {
      Copy-Item -LiteralPath $f.FullName -Destination $backup
    }

    # Rewrite CSV with Rssi column added/fixed up
    $rows | Export-Csv -LiteralPath $f.FullName -NoTypeInformation -Encoding UTF8
  }
}


function Write-SampleRow {
  $today = (Get-Date).Date
  $csvPath = Get-CsvPath $today
  $isNew = -not (Test-Path -LiteralPath $csvPath)
  if ($isNew) {
    'TimestampUtc,IfName,SSID,BSSID,Channel,SignalPct,LinkMbps,PingGW_Ms,PingGW_LossPct,Ping88_Ms,Ping88_LossPct,Ping11_Ms,Ping11_LossPct,Rssi' |
    Set-Content -LiteralPath $csvPath -Encoding UTF8
  }

  # --- Collect Wi-Fi ---
  $wlan = Get-WlanInfo
  $utc = (Get-Date).ToUniversalTime().ToString('o')

  $ifn = $null
  try {
    $ifn = (Get-NetAdapter -Physical |
      Where-Object { $_.Status -eq 'Up' -and $_.NdisPhysicalMedium -eq '802.11' } |
      Select-Object -First 1 -ExpandProperty Name)
  }
  catch {}

  # --- Collect latency (gateway + public internet) ---
  $gwIp = Get-DefaultGateway
  $gw = if ($gwIp) { Test-LatencySingle -Target $gwIp       -Count 2 -TimeoutMs 1500 } else { [pscustomobject]@{ MedianMs = $null; Loss = 2 } }
  $g88 = Test-LatencySingle -Target '8.8.8.8' -Count 2 -TimeoutMs 1500
  $c11 = Test-LatencySingle -Target '1.1.1.1' -Count 2 -TimeoutMs 1500

  # --- Build row ---
  $rowParts = @()
  $rowParts += '"' + $utc + '"'
  $rowParts += if ($ifn) { '"' + ($ifn -replace '"', '''') + '"' } else { '""' }
  $rowParts += if ($wlan.SSID) { '"' + ($wlan.SSID -replace '"', '''') + '"' } else { '""' }
  $rowParts += if ($wlan.BSSID) { '"' + ($wlan.BSSID -replace '"', '''') + '"' } else { '""' }
  $rowParts += if ($wlan.Channel -ne $null) { [string]$wlan.Channel } else { '' }
  $rowParts += if ($wlan.Signal -ne $null) { [string]$wlan.Signal } else { '' }
  $rowParts += if ($wlan.RxMbps -ne $null) { [string]$wlan.RxMbps } else { '' }

  # Gateway (median ms + loss count)
  $rowParts += if ($gw.MedianMs -ne $null) { [string]$gw.MedianMs } else { '' }
  $rowParts += [string]$gw.LossPct

  # 8.8.8.8
  $rowParts += if ($g88.MedianMs -ne $null) { [string]$g88.MedianMs } else { '' }
  $rowParts += [string]$g88.LossPct

  # 1.1.1.1
  $rowParts += if ($c11.MedianMs -ne $null) { [string]$c11.MedianMs } else { '' }
  $rowParts += [string]$c11.LossPct

  $rowParts += if ($wlan.Rssi -ne $null) { [string]$wlan.Rssi } else { '' }


  Add-Content -LiteralPath $csvPath -Value ($rowParts -join ',')
}





# ---------- ledger (group by local minute; worst-sample-wins) ----------

function Parse-IsoUtc {
  <#
    Accepts common ISO-8601 variants and normalizes to .NET "o" expectations:
      - Replace space between date/time with 'T'
      - Trim/pad fractional seconds to exactly 7 digits (ticks precision)
      - Parse as DateTimeOffset to honor timezone offsets, then return UTC DateTime
  #>
  param([string]$s)

  if ([string]::IsNullOrWhiteSpace($s)) { return $null }

  $t = $s.Trim()

  # Ensure 'T' separator (some CSV rows have a space)
  if ($t -match '^\d{4}-\d{2}-\d{2} ') { $t = $t -replace ' ', 'T', 1 }

  # Normalize fractional seconds to exactly 7 digits to satisfy "o"
  $m = [regex]::Match($t, '^(?<base>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(?<frac>\d+))?(?<rest>.*)$')
  if ($m.Success) {
    $base = $m.Groups['base'].Value
    $frac = $m.Groups['frac'].Value
    $rest = $m.Groups['rest'].Value
    if ([string]::IsNullOrEmpty($frac)) {
      $frac = '0000000'
    }
    else {
      if ($frac.Length -gt 7) { $frac = $frac.Substring(0, 7) }
      if ($frac.Length -lt 7) { $frac = $frac.PadRight(7, '0') }
    }
    $t = "$base.$frac$rest"
  }

  # Try strict parse as "o" via DateTimeOffset first
  $dto = [datetimeoffset]::MinValue
  $ok = [datetimeoffset]::TryParseExact(
    $t, 'o',
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal,
    [ref]$dto
  )
  if ($ok) { return $dto.UtcDateTime }

  # Fallback: generic parse
  if ([datetimeoffset]::TryParse($t, [ref]$dto)) { return $dto.UtcDateTime }

  return $null
}




function Update-LedgerDay {
  param([string]$Day) # 'yyyy-MM-dd'
  $csv = Join-Path $LogRoot ($Day + '.csv')
  $out = Join-Path $LogRoot ($Day + '.ledger.json')

  Write-Verbose "Update-LedgerDay: processing $($Day + '.ledger.json')..."

  if (-not (Test-Path -LiteralPath $csv)) { Set-Content -LiteralPath $out -Value '[]' -Encoding UTF8; return }

  $rows = Import-Csv -LiteralPath $csv
  if (-not $rows) { Set-Content -LiteralPath $out -Value '[]' -Encoding UTF8; return }

  $proj = @()
  foreach ($r in $rows) {
    $tsUtc = Parse-IsoUtc $r.TimestampUtc
    if (-not $tsUtc) { continue }

    $tsLoc = $tsUtc.ToLocalTime()
    $minute = $tsLoc.ToString('yyyy-MM-dd HH:mm')

    $sig = Try-ParseDouble $r.SignalPct
    $lnk = Try-ParseDouble $r.LinkMbps
    $rssi = Try-ParseDouble $r.Rssi

    $gwm = Try-ParseDouble $r.PingGW_Ms; $gwl = Try-ParseDouble $r.PingGW_LossPct
    $g8m = Try-ParseDouble $r.Ping88_Ms; $g8l = Try-ParseDouble $r.Ping88_LossPct
    $g1m = Try-ParseDouble $r.Ping11_Ms; $g1l = Try-ParseDouble $r.Ping11_LossPct

    $bssid = $null
    if ($r.BSSID -and -not [string]::IsNullOrWhiteSpace($r.BSSID)) {
      $bssid = ($r.BSSID.Trim().ToLower() -replace '-', ':')
    }

    $proj += [pscustomobject]@{
      Minute = $minute
      Signal = $sig
      Link   = $lnk
      Ms     = @($g8m, $g1m, $gwm) | Where-Object { $_ -ne $null }
      Losses = @($g8l, $g1l, $gwl) | Where-Object { $_ -ne $null }
      Bssid  = $bssid
      Rssi   = $rssi
    }
  }

  $byMin = $proj | Group-Object Minute
  $outRows = @()
  foreach ($g in $byMin) {
    $arr = $g.Group
    $samples = $arr.Count

    $allMs = @()
    $allLoss = @()
    $sigVals = @()
    $linkVals = @()
    $bssidVals = @()
    $rssiVals = @()

    foreach ($x in $arr) {
      if ($x.Ms) { $allMs += $x.Ms }
      if ($x.Losses) { $allLoss += $x.Losses }
      if ($x.Signal -ne $null) { $sigVals += $x.Signal }
      if ($x.Rssi -ne $null) { $rssiVals += $x.Rssi }
      if ($x.Link -ne $null) { $linkVals += $x.Link }
      if ($x.Bssid) { $bssidVals += $x.Bssid }
    }

    $medianMs = $null
    if ($allMs.Count) {
      $sorted = $allMs | Sort-Object
      $n = $sorted.Count
      if ($n -band 1) { $medianMs = [int]$sorted[($n - 1) / 2] }
      else { $medianMs = [int]([math]::Round( ($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2.0 )) }
    }

    $worstLoss = $null
    if ($allLoss.Count) { $worstLoss = [int]([math]::Round( ($allLoss | Measure-Object -Maximum).Maximum )) }

    $minSig = $null
    if ($sigVals.Count) { $minSig = [int](($sigVals | Measure-Object -Minimum).Minimum) }

    $worstRssi = $null
    if ($rssiVals.Count) { $worstRssi = [int](($rssiVals | Measure-Object -Minimum).Minimum) }

    $avgLink = $null
    if ($linkVals.Count) { $avgLink = [int]([math]::Round( ($linkVals | Measure-Object -Average).Average )) }

    $bssid = $null
    if ($bssidVals.Count) { $bssid = $bssidVals[-1] }

    $status = Get-MinuteStatus -MedianMs $medianMs -MinSignalPct $minSig -WorstLoss $worstLoss -AvgLinkMbps $avgLink

    $outRows += [pscustomobject]@{
      Minute    = $g.Name
      Samples   = $samples
      MedianMs  = $medianMs
      MinSig    = $minSig
      AvgLink   = $avgLink
      WorstLoss = $worstLoss
      Bssid     = $bssid
      Rssi      = $worstRssi
      Status    = $status
    }
  }


  # Persist roaming info: mark a minute when BSSID changes from the last non-null
  $sorted = $outRows | Sort-Object Minute
  $lastB = $null
  foreach ($r in $sorted) {
    # default
    $r | Add-Member -NotePropertyName Roaming -NotePropertyValue $false -Force

    # only consider minutes that have �real� data (non-grey conditions same as your UI)
    $hasSig = ($r.MinSig -ne $null -and $r.MinSig -gt 0)
    $hasSample = ($r.Samples -ne $null -and $r.Samples -gt 0)
    $b = $r.Bssid

    if ($hasSig -and $hasSample -and $b -and -not [string]::IsNullOrWhiteSpace($b)) {
      if ($lastB -and $b -ne $lastB) { $r.Roaming = $true }
      $lastB = $b  # advance only when valid so gaps don't �erase� context
    }
  }

  # if you later reassign $outRows, keep the sorted list:
  $outRows = $sorted



  $json = $outRows | Sort-Object Minute | ConvertTo-Json -Depth 3
  Set-Content -LiteralPath $out -Value $json -Encoding UTF8
}



function Update-Ledger {
  param([int]$Days = 2)
  $today = (Get-Date).Date
  for ($i = 0; $i -lt $Days; $i++) {
    $d = $today.AddDays(-$i).ToString('yyyy-MM-dd')
    Update-LedgerDay -Day $d
  }
}

# ---------- available days ----------
function Get-AvailableDays {
  $days = @()
  $csvs = Get-ChildItem -LiteralPath $LogRoot -Filter '*.csv' -ErrorAction SilentlyContinue
  foreach ($f in $csvs) {
    $n = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
    if ($n -match '^\d{4}-\d{2}-\d{2}$') { $days += $n }
  }
  $led = Get-ChildItem -LiteralPath $LogRoot -Filter '*.ledger.json' -ErrorAction SilentlyContinue
  foreach ($f in $led) {
    $n = [System.IO.Path]::GetFileNameWithoutExtension($f.Name) -replace '\.ledger$', ''
    if ($n -match '^\d{4}-\d{2}-\d{2}$') { $days += $n }
  }
  return ($days | Sort-Object -Unique)
}

# ---------- heatmap (from ledger) ----------

function Get-DaemonStatus {
  param([string]$Root = (Split-Path -Parent $PSCommandPath))

  $logs = Join-Path $Root 'logs'
  $hb = Join-Path $logs 'daemon-heartbeat.txt'

  $isRunning = $false
  $lastBeat = $null
  $ageSeconds = $null
  $reason = ''

  if (Test-Path -LiteralPath $hb) {
    try {
      $lastBeat = Get-Item -LiteralPath $hb | Select-Object -ExpandProperty LastWriteTime
      $ageSeconds = [int]([datetime]::Now - $lastBeat).TotalSeconds
    }
    catch {}
  }

  # Fallback: look for a powershell with -Daemon and our script name
  if (-not $isRunning) {
    try {
      $procs = Get-CimInstance Win32_Process |
      Where-Object { $_.CommandLine -match 'wifi-canary\.ps1' -and $_.CommandLine -match '\-Daemon' }
      if ($procs) {
        $isRunning = $true
        if (-not $pid) { $pid = ($procs | Select-Object -First 1).ProcessId }
      }
    }
    catch {}
  }

  if (-not $isRunning) {
    $reason = 'stopped'
  }
  elseif ($ageSeconds -ne $null -and $ageSeconds -gt 60) {
    $reason = "stale heartbeat (${ageSeconds}s)"
  }
  else {
    $reason = 'ok'
  }

  [pscustomobject]@{
    Running    = $isRunning
    Pid        = $pid
    LastBeat   = $lastBeat
    AgeSeconds = $ageSeconds
    Reason     = $reason
  }
}

function Get-CellColorHex {
  param([string]$Status)
  switch ($Status) {
    'greener' { '#2e7d32' }
    'green' { '#3CA341' }
    #'yellowish' { '#A2AD54' }
    'yellow' { '#fbc02d' }   # high latency / medium signal
    'orange' { '#fb8c00' }   # degraded
    'red' { '#e53935' }   # outage / very poor
    default { '#bdbdbd' }   # grey = no data / pending
  }
}

function Get-MinuteStatus {
  <#
    Unified policy:
      Inputs may be null (n/a). We decide using what we have.

      1) Outage rules (take precedence):
         - WorstLoss >= 100  -> red

      2) If ALL KPIs are n/a -> grey
         - KPIs here are: latency (MedianMs), signal (MinSignalPct), link (AvgLinkMbps)

      3) If latency is known:
           greener: ms < 60
           green  : 60–119
           yellow : 120–299
           orange : 300–799
           red    : >= 800

      4) If signal is known (used when latency is n/a, OR to worsen borderline cases):
           greener: > 85%
           green  : 70–85%
           yellow : 60–69%
           orange : 50–59%
           red    : < 50%

      5) If link is known (fallback KPI and can worsen borderline cases):
           greener: >= 50 Mbps
           green  : 24–49 Mbps
           yellow : 12–23 Mbps
           orange : 6–11 Mbps
           red    : < 6 Mbps

      6) If multiple KPIs exist, pick the WORSE bucket (red > orange > yellow > green > greener).
  #>
  param(
    [Nullable[int]]$MedianMs, # e.g., 10, 250, null
    [Nullable[int]]$MinSignalPct, # e.g., 52, null
    [Nullable[int]]$WorstLoss, # e.g., 0..100, null
    [Nullable[int]]$AvgLinkMbps       # e.g., 144, 6, null
  )

  # 2) If ALL KPIs are missing => grey (unknown)
  if ($WorstLoss -eq $null -and $MedianMs -eq $null -and $MinSignalPct -eq $null -and $AvgLinkMbps -eq $null) {
    return 'grey'
  }

  # 1) Outage takes precedence
  if ($WorstLoss -ne $null -and $WorstLoss -ge 100) { return 'red' }

  # Latency bucket
  $latBucket = $null
  if ($MedianMs -ne $null) {
    if ($MedianMs -lt 60) { $latBucket = 'greener' }
    elseif ($MedianMs -lt 120) { $latBucket = 'green' }
    elseif ($MedianMs -lt 300) { $latBucket = 'yellow' }
    elseif ($MedianMs -lt 800) { $latBucket = 'orange' }
    else { $latBucket = 'red' }
  }

  # Signal bucket
  $sigBucket = $null
  if ($MinSignalPct -ne $null) {
    if ($MinSignalPct -gt 85) { $sigBucket = 'greener' }
    elseif ($MinSignalPct -ge 70) { $sigBucket = 'green' }
    #elseif ($MinSignalPct -ge 65) { $sigBucket = 'yellowish' }
    elseif ($MinSignalPct -ge 60) { $sigBucket = 'yellow' }
    elseif ($MinSignalPct -ge 50) { $sigBucket = 'orange' }
    else { $sigBucket = 'red' }
  }

  # Link bucket
  $lnkBucket = $null
  if ($AvgLinkMbps -ne $null) {
    if ($AvgLinkMbps -ge 50) { $lnkBucket = 'greener' }
    elseif ($AvgLinkMbps -ge 24) { $lnkBucket = 'green' }
    elseif ($AvgLinkMbps -ge 12) { $lnkBucket = 'yellow' }
    elseif ($AvgLinkMbps -ge 6) { $lnkBucket = 'orange' }
    else { $lnkBucket = 'red' }
  }

  # 2) (original intent) If both latency & signal unknown, we used to grey out.
  # With link added as a KPI, we only grey when *all* are unknown (handled above).
  # If only one KPI is known, use it; if two/three are known, pick the worse.

  # 3) Only one known => use it
  if ($latBucket -ne $null -and $sigBucket -eq $null -and $lnkBucket -eq $null) { return $latBucket }
  if ($latBucket -eq $null -and $sigBucket -ne $null -and $lnkBucket -eq $null) { return $sigBucket }
  if ($latBucket -eq $null -and $sigBucket -eq $null -and $lnkBucket -ne $null) { return $lnkBucket }

  # 4/6) Multiple known => pick the WORST bucket
  $rank = @{ greener = 0; green = 1; yellow = 2; orange = 3; red = 4 }

  $candidates = @()
  if ($latBucket -ne $null) { $candidates += $latBucket }
  if ($sigBucket -ne $null) { $candidates += $sigBucket }
  if ($lnkBucket -ne $null) { $candidates += $lnkBucket }

  # Worst = max rank
  $worst = $candidates | Sort-Object { $rank[$_] } -Descending | Select-Object -First 1
  return $worst
}

function New-Heatmap {
  param([int]$Days = 1, [int]$BucketMinutes = 1)

  $availableDays = Get-AvailableDays
  if (-not $availableDays) { return }

  # last fully-completed minute at render time
  $nowLocal = Get-Date
  $floorNow = Get-Date -Year $nowLocal.Year -Month $nowLocal.Month -Day $nowLocal.Day -Hour $nowLocal.Hour -Minute $nowLocal.Minute -Second 0
  $lastComplete = $floorNow.AddMinutes(-1)
  $thisDay = $nowLocal.Date
  $nextMinuteNow = $floorNow                          # minute currently being filled

  # FIX: render the most recent N days (then display in chronological order)
  $targetDays = $availableDays | Sort-Object | Select-Object -Last $Days

  foreach ($day in ($targetDays | Sort-Object)) {
    $ledgerPath = Join-Path $LogRoot ($day + '.ledger.json')
    if (-not (Test-Path -LiteralPath $ledgerPath)) { continue }

    $entriesJson = Get-Content -LiteralPath $ledgerPath -Raw
    if ([string]::IsNullOrWhiteSpace($entriesJson)) { continue }
    $entries = $entriesJson | ConvertFrom-Json
    if (-not $entries) { continue }

    # Map minute key -> entry (yyyy-MM-dd HH:mm)
    $map = @{}
    foreach ($e in $entries) { $map[$e.Minute] = $e }

    # daemon badge
    $rootForStatus = Split-Path -Parent $PSCommandPath
    $ds = Get-DaemonStatus -Root $rootForStatus
    $badgeText = if ($ds.Running) { 'watching' } else { 'stopped' }
    if ($ds.Running -and $ds.AgeSeconds -ne $null -and $ds.AgeSeconds -gt 60) { $badgeText = 'watch (stale)' }
    $badgeClass = if ($ds.Running -and $badgeText -eq 'watching') { 'ok' } elseif ($badgeText -eq 'watch (stale)') { 'warn' } else { 'err' }
    $badgeTip = if ($ds.Running) { if ($ds.LastBeat) { "last beat $($ds.AgeSeconds)s ago" } else { 'no heartbeat yet' } } else { 'not running' }

    # which single pending minute should pulse (today only)
    $dayDate = [datetime]::ParseExact($day, 'yyyy-MM-dd', $null)
    $nextMinuteForDayKey = $null
    if ($dayDate.Date -eq $thisDay) { $nextMinuteForDayKey = $nextMinuteNow.ToString('yyyy-MM-dd HH:mm') }
    $markedNext = $false

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!doctype html><meta charset="utf-8">')
    [void]$sb.AppendLine('<meta http-equiv="refresh" content="65">')
    [void]$sb.AppendLine("<title>wifi-canary heatmap $day</title>")
    [void]$sb.AppendLine('<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:16px}
h1{font-size:18px;margin:0 0 8px}
controls{margin:8px 0 12px}
.btn{display:inline-block;padding:5px 10px;border-radius:6px;background:#eee;border:1px solid #ccc;color:#111;text-decoration:none}
.btn:hover{background:#e6e6e6}
.row{display:flex;align-items:center;margin-bottom:4px}
.hour{width:40px;font-size:12px;color:#555}
.cells{display:flex;gap:2px;flex-wrap:wrap}
.cell{width:12px;height:12px;border-radius:2px;font-size:11px;font-color:#fff}
.tip{position:relative}
.tip:hover::after{content:attr(data-tip);position:absolute;left:0;top:16px;background:#111;color:#fff;padding:4px 6px;border-radius:4px;font-size:11px;white-space:nowrap;z-index:10}
.legend{margin:6px 0 10px;font-size:12px}
.hrow{display:flex;align-items:center;margin:0 0 6px}
.hcells{display:flex;gap:2px}
.hcell{width:12px;height:12px;font-size:10px;line-height:12px;color:#444;text-align:center}

.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:11px;border:1px solid #ccc;margin-left:8px}
.badge.ok{background:#e8f5e9;border-color:#a5d6a7;color:#1b5e20}
.badge.warn{background:#fff8e1;border-color:#ffe082;color:#8d6e00}
.badge.err{background:#ffebee;border-color:#ef9a9a;color:#b71c1c}

.countdown{margin-left:8px;font-size:11px;color:#555}
.countdown.warn{color:#8d6e00}
.countdown.urgent{color:#b71c1c}

.footer{margin-top:12px;color:#666;font-size:12px}

/* more visible pending pulse for NEXT minute */
@keyframes pulseGray{
  0%   { background:#c2c2c2; box-shadow:0 0 0px rgba(0,0,0,0.0) }
  50%  { background:#f2f2f2; box-shadow:0 0 6px rgba(0,0,0,0.25) }
  100% { background:#c2c2c2; box-shadow:0 0 0px rgba(0,0,0,0.0) }
}
.cell.pending{ background:#bdbdbd; }
.cell.pending.nextup{
  animation: pulseGray 1.6s ease-in-out infinite;
  outline:1px #9e9e9e;
  outline-offset:0;
}
@media (prefers-reduced-motion: reduce){
  .cell.pending.nextup{ animation:none; }
}
</style>')

    [void]$sb.AppendLine("<h1>Connectivity heatmap for $day (bucket $BucketMinutes min)</h1>")

    # day picker + controls
    $picker = "<div class='controls'><select id='daypick' onchange=""location.href=this.value+'.html'"">"
    foreach ($d in $availableDays) {
      $sel = ''; if ($d -eq $day) { $sel = ' selected' }
      $picker += "<option value='$d'$sel>$d</option>"
    }
    $picker += "</select>"
    [void]$sb.AppendLine($picker)
    [void]$sb.AppendLine('<button onclick="location.reload()">refresh</button>')
    [void]$sb.AppendLine(('<span class="badge {0}" title="{1}">{2}</span>' -f $badgeClass, $badgeTip, $badgeText))
    [void]$sb.AppendLine('<span id="refreshcd" class="countdown" title="auto-refresh countdown">&#8635; 65s</span>')
    [void]$sb.AppendLine('</div>')

    [void]$sb.AppendLine('<div class="legend">Green=good | Yellow=high latency | Orange=degraded | Red=bad/outage | Grey=no-data/pending.</div>')

    # column labels
    $slots = [int](60 / $BucketMinutes)
    $labels = @(); for ($i = 1; $i -le $slots; $i++) { $labels += ($i * $BucketMinutes) }
    [void]$sb.AppendLine('<div class="hrow"><div class="hour"></div><div class="hcells">')
    foreach ($lab in $labels) { [void]$sb.AppendLine("<div class='hcell'>$lab</div>") }
    [void]$sb.AppendLine('</div></div>')

    # grid
    for ($h = 0; $h -lt 24; $h++) {
      $rowStart = [datetime]::ParseExact("$day $h`:00", "yyyy-MM-dd H\:mm", $null)
      [void]$sb.AppendLine('<div class="row">')
      [void]$sb.AppendLine(('<div class="hour">{0:00}:00</div><div class="cells">' -f $h))

      for ($i = 0; $i -lt $slots; $i++) {
        $t = $rowStart.AddMinutes($i * $BucketMinutes)
        $key = $t.ToString('yyyy-MM-dd HH:mm')

        $isPending = $t -gt $lastComplete
        if ($isPending) {
          $classes = @('cell', 'tip', 'pending')
          # compare as strings to avoid DateTime Kind mismatches
          if (-not $markedNext -and $nextMinuteForDayKey -ne $null -and $key -eq $nextMinuteForDayKey) {
            $classes += 'nextup'
            $markedNext = $true
          }
          $tip = ("{0:HH:mm}  (pending) samples=n/a latency=n/a signal=n/a" -f $t)
          $cls = ($classes -join ' ')
          [void]$sb.AppendLine("<div class='$cls' data-tip='$tip'></div>")
          continue
        }

        $x = $map[$key]
        if (-not $x) {
          $tip = ("{0:HH:mm}  samples=0 latency=n/a signal=n/a" -f $t)
          [void]$sb.AppendLine("<div class='cell tip' data-tip='$tip' style='background:#bdbdbd'></div>")
          continue
        }

        $color = Get-CellColorHex $x.Status
        $latTxt = if ($x.MedianMs -ne $null) { ([int]$x.MedianMs).ToString() } else { 'n/a' }
        $sigTxt = if ($x.MinSig -ne $null) { ([int]$x.MinSig).ToString() } else { 'n/a' }
        $statusTip = if ($x.MedianMs -eq $null -and $x.MinSig -eq $null) { '?' } else { $x.Status }
        $tip = ("{0:HH:mm}  status={1}  samples={2}  latency={3}ms  signal={4}%" -f $t, $statusTip, $x.Samples, $latTxt, $sigTxt)

        [void]$sb.AppendLine("<div class='cell tip' data-tip='$tip' style='background:$color'></div>")
      }

      [void]$sb.AppendLine('</div></div>')
    }

    [void]$sb.AppendLine("<div class='footer'>Generated at $(Get-Date)</div>")

    # countdown script (after #refreshcd exists)
    [void]$sb.AppendLine(@"
<script>
(function(){
  var meta = document.querySelector('meta[http-equiv="refresh"]');
  var secs = 65;
  if (meta && meta.content) {
    var m = meta.content.match(/^\s*(\d+)/);
    if (m) secs = parseInt(m[1], 10);
  }
  var el = document.getElementById('refreshcd');
  if (!el) return;
  var remaining = secs;
  function tick(){
    remaining--;
    if (remaining < 0) remaining = 0;
    el.textContent = '\u21BB ' + remaining + 's'; // ↻
    el.classList.toggle('warn', remaining <= 8 && remaining > 5);
    el.classList.toggle('urgent', remaining <= 5);
  }
  el.textContent = '\u21BB ' + secs + 's';
  el.classList.remove('warn','urgent');
  setInterval(tick, 1000);
})();
</script>
"@)

    $out = Join-Path $LogRoot ($day + '.html')
    Set-Content -LiteralPath $out -Value $sb.ToString() -Encoding UTF8
  }
}



function Update-LedgerIndex {
  try {
    $indexPath = Join-Path $LogRoot 'ledger-index.json'
    $tmpPath = "$indexPath.tmp"

    $items = Get-ChildItem -Path $LogRoot -Filter "*.ledger.json" -File -ErrorAction SilentlyContinue |
    Sort-Object Name |
    ForEach-Object {
      # Expect names like 2025-12-21.ledger.json
      if ($_.BaseName -match '^\d{4}-\d{2}-\d{2}\.ledger$') {
        $date = ($_.BaseName -replace '\.ledger$', '')
        [PSCustomObject]@{ date = $date; path = $_.Name }
      }
    } | Where-Object { $_ -ne $null }

    # Write atomically
    $items | ConvertTo-Json -Depth 3 | Set-Content -Encoding utf8 -Path $tmpPath
    Move-Item -Force $tmpPath $indexPath
  }
  catch {
    $msg = "{0:o}  Update-LedgerIndex: failed: {1}" -f (Get-Date), $_.Exception.Message
    Write-Warning $msg
    if ($LogRoot) { Add-Content -LiteralPath (Join-Path $LogRoot 'daemon-errors.log') -Value $msg }
  }
}



# ---------- Daemon loop ----------

function Run-Daemon {
  Add-Content -LiteralPath (Join-Path $LogRoot 'daemon-errors.log') -Value ("{0:o}  Run-Daemon enter (EverySeconds={1}, Days={2})" -f (Get-Date), $EverySeconds, $Days)
  Write-Host "[wifi-canary] daemon starting… (EverySeconds=$EverySeconds, Days=$Days)"

  while ($true) {
    try {
				
      # ensure today's CSV exists before first write (rollover-safe)
      Write-SampleRow
	  
      # keep ledgers and heatmaps fresh (today and previous N-1 days)
      Update-Ledger -Days $Days
      
      # update index (throttled + rollover-aware)
      Update-LedgerIndex
	  
      New-Heatmap -Days $Days -BucketMinutes $BucketMinutes
    
    }
    catch {
      $err = Join-Path $LogRoot 'daemon-errors.log'
      Add-Content -LiteralPath $err -Value ("{0:o}  {1}" -f (Get-Date), $_.Exception.Message)
    }
    $hbTs = (Get-Date).ToString('o')
    # Keep a small heartbeat signal for the dashboard (overwrite so it doesn't grow)
    Set-Content -LiteralPath $Beat -Value ("{0} alive" -f $hbTs) -Encoding UTF8
    # Also write JSON for robust parsing in the dashboard
    Set-Content -LiteralPath $BeatJson -Value (([pscustomobject]@{ ts = $hbTs }) | ConvertTo-Json -Compress) -Encoding UTF8
    Start-Sleep -Seconds $EverySeconds
  }
}

# ---------- command switchboard ----------
if ($Daemon) { Run-Daemon; exit }
if ($Sample) { Write-SampleRow; exit }
if ($Ledger) { Update-Ledger -Days $Days; exit }
if ($Heatmap) { New-Heatmap -Days $Days -BucketMinutes $BucketMinutes; exit }
if ($BackfillRssi) { Update-CsvRssi -Days $Days; exit }


Write-Host "wifi-canary: use one of -Daemon, -Sample, -Ledger, -Heatmap (plus optional -Days, -EverySeconds, -BucketMinutes, -LogRoot)."
