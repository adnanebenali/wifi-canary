# Wi-FiBad: Latency and Signal Measurement Overview

This document explains how **wifi-canary.ps1** measures network latency and Wi-Fi signal strength, what targets are used, and why.

---

## 1. Latency Measurement

### How It Works
Latency is measured using the helper function:

```powershell
Ping-Once($Target)
```

This wraps PowerShell’s `Test-Connection` (1 packet) and returns:

```powershell
{ Ms, LossPct }
```

### Targets Used per Sample
Every sampling cycle (`Write-SampleRow`):

| Purpose | Target | Alias | CSV Columns |
|----------|---------|--------|--------------|
| Local connectivity | Default Gateway (via `Get-DefaultGateway`) | `$pGW` | `PingGW_Ms`, `PingGW_LossPct` |
| Internet path #1 | `8.8.8.8` (Google Public DNS) | `$p88` | `Ping88_Ms`, `Ping88_LossPct` |
| Internet path #2 | `1.1.1.1` (Cloudflare DNS) | `$p11` | `Ping11_Ms`, `Ping11_LossPct` |

### Why These Targets
- **Gateway** → Detects purely local/Wi-Fi/router problems before traffic leaves your LAN.
- **8.8.8.8 / 1.1.1.1** → Globally reachable, stable, and geographically close; excellent indicators of end-to-end Internet latency.
- Two independent public DNS hosts minimize false positives caused by one provider’s blip.

During analysis (`Update-LedgerDay`), latency values from the public targets are **preferred** when computing medians, giving a more realistic “Internet experience” view.

---

## 2. Per-Minute Rollup and Color Logic

Each minute, `Update-LedgerDay` groups all samples and calculates:

| Metric | Description | Source |
|---------|--------------|--------|
| **MedianMs** | Median latency (prefers 8.8.8.8 / 1.1.1.1 / then gateway) | `Ping*_Ms` |
| **WorstLoss** | Highest packet loss % among all targets | `Ping*_LossPct` |
| **MinSig** | Minimum Wi-Fi signal strength % | `SignalPct` |
| **AvgLink** | Average link speed (Mbps) | `LinkMbps` |

### Color Policy (`Get-MinuteStatus`)
| Condition | Status | Color |
|------------|---------|--------|
| `WorstLoss ≥ 100` | Hard outage | Red |
| `MedianMs > 400` | Severe latency | Orange |
| `MedianMs > 200` | Mild latency | Yellow |
| `MinSig < 35` or `AvgLink < 6` | Poor Wi-Fi or link | Orange |
| `MinSig < 50` or `AvgLink < 12` | Weak Wi-Fi or link | Yellow |
| Otherwise | Normal | Green |

This layered approach lets the app show whether issues stem from **Internet latency**, **packet loss**, or **Wi-Fi quality**.

---

## 3. Wi-Fi Signal and Access Point Identity

### How It’s Read
`Get-WlanInfo` executes:

```powershell
netsh wlan show interfaces
```

and parses:

| Field | Meaning |
|--------|----------|
| **IfName** | Wireless interface name |
| **SSID** | Network name |
| **BSSID** | Access point MAC address |
| **Channel** | Frequency channel number |
| **SignalPct** | Signal strength (0-100%) |
| **LinkMbps** | Link speed reported by adapter |

These fields are recorded in every CSV line:

```
IfName, SSID, BSSID, Channel, SignalPct, LinkMbps
```

### Why It Matters
- `SignalPct` is reported by your Wi-Fi adapter and reflects the connection quality to the current access point.  
- `BSSID` uniquely identifies the AP (great for IT troubleshooting).  
- Combined with `PingGW_Ms` (gateway latency), it helps differentiate **RF issues** from **upstream network problems**.

If deeper diagnostics are needed, the same information can identify which AP or router you were connected to at any timestamp.

---

## 4. Summary

- The script pings **gateway**, **8.8.8.8**, and **1.1.1.1** per sample.
- Each minute’s rollup computes **MedianMs**, **WorstLoss**, **MinSig**, and **AvgLink**.
- **Color status** reflects combined latency and signal health.
- Wi-Fi data comes from `netsh wlan show interfaces`, including **BSSID** for AP identity.

This structure enables the heatmap to show **where** and **why** connectivity quality changes — from local Wi-Fi issues to broader Internet latency.


## Organize this better

Your laptop may be roaming to a different Access Point (AP) because of a weak or fluctuating signal from the current AP, which triggers the client's roaming aggressiveness to find a better one. Other causes include interference, an out-of-date Wi-Fi driver, or settings on your laptop that are causing it to be overly sensitive to signal changes.
Common reasons for roaming
Signal strength variation: Even if you haven't moved, the signal from the current AP might fluctuate due to interference from other devices or the environment, causing your laptop to believe a different AP has a stronger connection.
Interference: Radio frequency (RF) interference from other electronics, neighboring Wi-Fi networks, or even a high density of devices can cause the signal to become unstable and trigger roaming.
Driver or client-side settings: Roaming behavior is determined by your laptop's Wi-Fi driver and chipset. A driver's roaming aggressiveness, signal-to-noise ratio (SNR) settings, or driver version can cause it to make the switch more frequently.
Load balancing: If your network has load balancing enabled on the AP, it may direct your device to a less-loaded access point, even if the signal isn't significantly better.
How to fix it
Update Wi-Fi drivers: Ensure your Wi-Fi adapter has the latest drivers installed, as this can fix bugs related to roaming behavior. You can do this through Device Manager.
Adjust roaming aggressiveness: On Windows, you can often find and adjust the roaming aggressiveness setting in your Wi-Fi adapter's advanced properties in Device Manager.
Lower the aggressiveness: Setting this to a lower value can make the device less likely to roam unless the current signal is very weak.
Increase the aggressiveness: This can encourage the device to roam sooner when the current signal is still strong.
Adjust signal strength settings: Sometimes, a lower signal strength setting can prevent the device from seeing a distant AP as a viable option, forcing it to stay connected to the closer one.
Check AP settings: If you have control over your network, check for settings like "force roaming" or "traffic balancing" on your access points.
Scan for other issues: Restart your router and modem, and ensure that no other devices are causing significant interference. You may also want to disable or remove other network software that could be interfering with the connection.

## Does Roaming cause Dropouts?
When a laptop roams to another BSSID (Access Point), the goal is to maintain connectivity with minimal to no interruption (dropouts). In a properly configured network, this transition should be seamless for the user. 
However, experiencing brief dropouts is possible and depends on several factors:
Network Configuration:
Same SSID and Password: For roaming to work correctly, all APs must share the same network name (SSID) and password.
Managed Networks: In a managed network (e.g., business or mesh systems), the APs can coordinate the handoff, making it very smooth.
Unmanaged Networks/Different Brands: If you are using standalone APs of different brands or models, even with the same SSID, the handoff may not be as smooth, and you might experience a brief drop in connection while the laptop re-authenticates.
802.1X Authentication: If using 802.1X authentication, features like "Enable Fast Reconnect" are needed to prevent connection drops during roaming.
Client Device (Laptop) Behavior:
Client-Initiated Roaming: The decision to roam is primarily made by the client device's Wi-Fi adapter and its internal logic.
Roaming Aggressiveness: Some laptop Wi-Fi drivers have settings, such as "roaming aggressiveness" (found in advanced settings on some Windows laptops with Intel NICs), that can be adjusted to influence how quickly the device decides to switch APs.
Driver/OS Issues: Sometimes, specific driver or operating system bugs can cause issues with roaming, leading to disconnections or the device sticking to a distant AP with a weak signal.
Physical Environment and Signal Strength:
Optimal AP Placement: APs should be placed and their power adjusted to have a proper overlap in coverage. If a device moves into a "dead zone" before connecting to the next AP, a dropout will occur.
Interference: Too many APs in close proximity using overlapping channels can cause interference, which can also contribute to connectivity issues during roaming. 
In summary, while roaming is designed to be a seamless experience that maintains active sessions (like video calls or streaming), dropouts can happen if the network is not optimally configured or if there are issues with the client device's implementation of the roaming protocols
