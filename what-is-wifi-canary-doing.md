# Wi‑Fi Canary: how the collector + dashboard work

This document explains what **wifi-canary.ps1** measures, how it rolls data up into minute buckets,
and how the dashboard consumes the generated files.

> This was originally written for “wifibad”; it has been updated to match the current **Wi‑Fi Canary** code.

---

## 1) Sampling loop overview

When you run the daemon (`wifi-canary.ps1 -Daemon`) the loop does, in order:

1. **Write-SampleRow** – append one row to today’s CSV  
2. **Update-Ledger** – rebuild ledgers for today and the previous *N-1* days  
3. **Update-LedgerIndex** – regenerate `logs/ledger-index.json`  
4. **New-Heatmap** – regenerate static `logs/YYYY-MM-DD.html` heatmaps  
5. Write `logs/daemon-heartbeat.txt`

This repeats every `-EverySeconds` (default 15s).

---

## 2) What gets logged per sample (CSV)

Each sample appends to `logs/YYYY-MM-DD.csv` with header:

```
TimestampUtc,IfName,SSID,BSSID,Channel,SignalPct,LinkMbps,
PingGW_Ms,PingGW_LossPct,Ping88_Ms,Ping88_LossPct,Ping11_Ms,Ping11_LossPct,
Rssi
```

### Wi‑Fi metrics

Collected via:

- `netsh wlan show interfaces`

Fields captured:

- **SSID** – network name
- **BSSID** – AP MAC (normalized to lowercase `aa:bb:cc:dd:ee:ff`)
- **Channel**
- **SignalPct** – 0..100 quality
- **LinkMbps** – receive rate (Mbps)
- **Rssi** – if present in `netsh` output

**Note on Windows Location Services:** some Windows setups hide BSSID/RSSI unless Location Services are enabled.

### Latency probes

Latency is collected by:

- `Test-LatencySingle -Target <gateway|8.8.8.8|1.1.1.1> -Count 2`

`Test-LatencySingle` tries, per attempt:

1. ICMP (Test-Connection)
2. TCP connect fallback (port 53, then 443)
3. HTTP HEAD fallback for hostnames (not used by default targets)

It returns:
- **MedianMs** – median of the successful attempts
- **Loss** – number of failed attempts (0..Count)

**Important naming mismatch (current code):** the CSV columns are named `Ping*_LossPct` but the script writes **Loss count** (0..2), not a percent.
This document describes what the code *actually writes today*.

Targets used each cycle:
- **Gateway** (default route next hop) – isolates LAN/Wi‑Fi/router issues
- **8.8.8.8** (Google anycast) – stable public path indicator
- **1.1.1.1** (Cloudflare anycast) – independent public path indicator

---

## 3) Minute rollups (ledgers)

`Update-LedgerDay` groups rows into **local-time minute buckets** and writes:

- `logs/YYYY-MM-DD.ledger.json`

For each minute it computes:

- **Samples** – number of samples observed that minute
- **MedianMs** – median over *all available* ping medians in that minute, using the values in order:
  - `Ping88_Ms`, `Ping11_Ms`, `PingGW_Ms`
- **WorstLoss** – **maximum** of loss values among targets for that minute  
  (currently max loss **count**, 0..2)
- **MinSig** – minimum SignalPct within the minute
- **AvgLink** – average LinkMbps within the minute
- **Rssi** – “worst” (minimum / most negative) RSSI seen that minute
- **Bssid** – last non-empty BSSID seen that minute

### Roaming detection

After producing per-minute rows, the script marks:

- `Roaming = true` when the minute’s BSSID differs from the last valid (non-empty) BSSID.

It only advances “last known BSSID” on minutes with real data (signal > 0 and Samples > 0) so gaps don’t erase context.

---

## 4) Status / color policy

The script contains **two** `Get-MinuteStatus` definitions; the later one (further down in the file) is the effective policy.
It can return: `grey, greener, green, yellow, orange, red`.

Policy (as implemented):

1. If **all KPIs** are missing (loss, latency, signal, link) → `grey`
2. If `WorstLoss >= 100` → `red` (outage)
3. Otherwise it computes buckets for:
   - latency (MedianMs)
   - signal (MinSig)
   - link (AvgLink)
4. If multiple KPIs are available, it picks the **worst bucket**.

### Important note about loss → outage coloring

Because `WorstLoss` currently comes from “loss **count** out of 2” (0..2),
the rule `WorstLoss >= 100` **never triggers**.

So in the current build, “red because we lost all pings” will not happen unless you
change either:
- what is written to the CSV (write percent 0/50/100), or
- the threshold logic (treat `WorstLoss >= 2` as outage when Count=2)

---

## 5) ledger-index.json (dashboard discovery)

`Update-LedgerIndex` writes:

- `logs/ledger-index.json`

It’s an array like:

```json
[
  { "date": "2025-12-21", "path": "2025-12-21.ledger.json" }
]
```

The dashboard uses this index to populate day/month navigation and to fetch the ledger file.

---

## 6) Static heatmaps

`New-Heatmap` also writes a static HTML heatmap per day:

- `logs/YYYY-MM-DD.html`

This is useful for a quick share (no JS app) and also acts as a sanity check that data is being generated.

---

## 7) Suggested cleanups (optional but recommended)

If you want the repo to be easier to maintain:

1. **Fix the loss naming mismatch**
   - Rename CSV columns to `Ping*_LossCount` (and update ledger/dashboard), *or*
   - Write percent into the CSV (0/50/100 for Count=2) so `WorstLoss >= 100` makes sense.

2. **Remove the duplicate early `Get-MinuteStatus` + `Get-CellColorHex`**
   - Keep one policy function (the unified one) to avoid future confusion.

3. **Document the dashboard’s base paths**
   - Dashboard expects `logs/` at repo root when served from repo root.
