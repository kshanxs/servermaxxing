---
name: servermaxxing
description: Provision, optimize, or ruthlessly "toast" (audit/roast) any Linux server, VPS, laptop, or homelab box for autonomous AI coding agents. Use when the user asks to set up, tune, or audit a server, optimize a laptop server with the lid down, audit battery/power policies, or roast a machine's readiness for AI agent workloads.
---

# `servermaxxing` : Agent Workstation Provisioner & Server Toast Engine

This skill equips agents to either **provision & tune** an Ubuntu/Debian server for 24/7 AI coding agent workloads or **audit & "toast"** an existing server configuration for amateur setups, power traps, and performance bloat.

---

## 1. Core Philosophy: The Maxxed Agent Server

A true AI agent server (whether a $5/mo VPS, a refurbished ThinkPad laptop, or a Proxmox cluster node) must adhere to five non-negotiable rules:
1. **Never Sleep on AC**: `sleep.target`, `suspend.target`, `hibernate.target`, and `hybrid-sleep.target` must be completely masked.
2. **Never Cook the Battery**: On laptop servers, charge thresholds must be capped to 80% to avoid thermal battery swelling ("pillow battery").
3. **No Interactive Roadblocks**: Passwordless sudo must be configured for the agent user; Tailscale and Docker must not require interactive TTY prompts to function.
4. **Compressed In-Memory Swap**: ZRAM swap (zstd, 50% RAM) must be active to prevent heavy agent builds or Docker compilations from thrashing SSD disks.
5. **Modern Native Runtimes**: `uv` & `uvx` (Rust Python), `Vite+` (`vp`) & Node.js LTS, Docker Engine v2, and Tailscale mesh networking.

---

## 2. Workflows

### Mode A: Automated Server Provisioning

When asked to set up or tune a new server, execute the `servermaxxing` entrypoint:

```bash
# Clone and run
git clone https://github.com/kshanxs/servermaxxing.git
cd servermaxxing
sudo bash servermaxxing.sh
```

Or via direct one-liner:
```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/kshanxs/servermaxxing/main/scripts/servermaxxing.sh)
```

Direct agent auto-launch (e.g. Claude Code or Codex):
```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/kshanxs/servermaxxing/main/scripts/servermaxxing.sh) --agent claude
```

On a fresh root-only cloud VPS:
```bash
apt-get update -y && apt-get install -y curl && id -u dev &>/dev/null || (adduser --disabled-password --gecos "" dev && usermod -aG sudo dev) && su - dev -c "sudo bash <(curl -fsSL https://raw.githubusercontent.com/kshanxs/servermaxxing/main/scripts/servermaxxing.sh) --agent claude"
```

The script automatically detects:
* **Cloud VPS / VM / LXC**: Configures headless daemons, ZRAM, Docker, Tailscale, runtimes, and skips physical lid/battery policies.
* **Bare-Metal Laptop**: Applies 24/7 never-sleep masking, ignores lid close across all states, disables Wi-Fi power save, and enforces the 80% battery longevity threshold.
* **Bare-Metal Dedicated Server**: Masks sleep targets, disables ModemManager/multipathd bloat, and provisions the agent stack.

---

### Mode B: The "Server Toast" Audit Routine (Roast & Fix)

When a user asks you to "toast", audit, inspect, or critique their current machine or server setup, run these diagnostics and deliver a sharp, skeptical critique:

```bash
echo "=== SERVERMAXXING DIAGNOSTIC AUDIT ==="
echo "1. Host / Virt Type:" $(systemd-detect-virt 2>/dev/null || echo 'bare-metal')
echo "2. Sleep Targets:" $(systemctl is-enabled sleep.target 2>/dev/null || echo 'masked/disabled')
echo "3. Lid Policy:" $(grep -s "HandleLidSwitch=ignore" /etc/systemd/logind.conf.d/*.conf /etc/systemd/logind.conf || echo 'VULNERABLE: Will sleep on lid close')
echo "4. Wi-Fi Power Save:" $(grep -s "wifi.powersave" /etc/NetworkManager/conf.d/*.conf || echo 'VULNERABLE: Wi-Fi power-save may drop SSH')
echo "5. Battery Health Cap:" $(cat /sys/class/power_supply/BAT*/charge_control_end_threshold 2>/dev/null || echo 'No threshold set / Uncapped 100%')
echo "6. ZRAM In-Memory Swap:" $(cat /proc/swaps | grep zram || echo 'MISSING: Slow disk swap active')
echo "7. Docker:" $(docker --version 2>/dev/null || echo 'MISSING')
echo "8. Tailscale:" $(tailscale ip -4 2>/dev/null || echo 'OFFLINE / NOT RUNNING')
echo "9. uv / uvx:" $(uv --version 2>/dev/null || echo 'MISSING')
echo "10. Vite+ (vp):" $(vp --version 2>/dev/null || echo 'MISSING')
echo "11. Agent Multiplexers:" $(which herdr tuios tmux 2>/dev/null || echo 'MISSING')
```

#### How to Format the "Toast":
1. **The Roasts (Flaws & Sins)**:
   - Call out any missing ZRAM (SSD killer under agent builds).
   - Call out unmasked sleep targets (if someone closes the lid, the agent dies mid-task).
   - Call out uncapped battery charging (baking the battery at 100% 24/7).
   - Call out Wi-Fi power saving enabled (dropping SSH sessions).
   - Call out Tailscale missing or unauthenticated (requiring open public SSH ports).
2. **The Fixes**:
   - Provide the exact, hardened commands or recommend running `sudo bash servermaxxing.sh`.
