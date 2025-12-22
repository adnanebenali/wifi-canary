# wifi-canary 🐤

Minute-level Wi-Fi health logger + HTML dashboard for diagnosing flaky home or office networks from the client-side perspective 
(RSSI/signal, BSSID, roaming events, latency buckets). Could complement enterprise network monitoring tools.

## What it does

- Runs a small PowerShell “daemon” that samples Wi-Fi metrics periodically
- Writes per-day ledgers (CSV/JSON) locally
- Generates a static HTML dashboard to visualize patterns over time
- Provides a HTML dashboard that dynamically reads from daily ledgers

## Quick start (Windows)

### Requirements
- Windows 10/11
- PowerShell 7+ recommended

### Run the collector
