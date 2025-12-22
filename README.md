# Wi-Fi Canary 🦜

Minute-level Wi-Fi health logger + HTML dashboard for diagnosing flaky home or office networks from the client-side perspective 
(RSSI/signal, BSSID, roaming events, latency buckets). Could complement enterprise network monitoring tools.
Run it on your laptop.

## What it does

- Runs a small PowerShell “daemon” that samples Wi-Fi metrics periodically
- Writes per-day ledgers (CSV/JSON) locally
- Generates a static HTML dashboard to visualize patterns over time
- Provides a HTML dashboard that dynamically reads from daily ledgers
- and more if you'd like to contribute to it!

![Alt text](/doc/image-2.png)

## Quick start (Windows)

### Requirements
- Windows 10/11
- PowerShell 7+ recommended

### **IMPORTANT ✋:**
- Enable Location services on your laptop 
- in order for the collector to pick up the BSSID (AP) you're roaming to and its RSSI.
  
    ![Alt text](/doc/image.png)

- When the tool runs later, you can verify that it is using location only when it runs:
    ![Alt text](/doc/image-1.png)

### Run the collector
- Double-click 'reload-wifi-canary.cmd'
  - Allow Windows to run it.
- Double-click 'start-web-server.cmd'
  - You can browse the dashboard locally at: http://localhost:8080/src/dashboard/
