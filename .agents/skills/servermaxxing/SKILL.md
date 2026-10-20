---
name: servermaxxing
description: Provision, optimize, or ruthlessly "toast" (audit/roast) any Linux server, VPS, laptop, or homelab box for autonomous AI coding agents. Use when the user asks to set up, tune, or audit a server, optimize a laptop server with the lid down, audit battery/power policies, fix git clone/push to GitHub failing on a server (e.g. "could not read Username for 'https://github.com'"), or roast a machine's readiness for AI agent workloads.
---

# `servermaxxing` : Agent Workstation Provisioner & Server Toast Engine

This skill equips agents to either **provision & tune** an Ubuntu/Debian server for 24/7 AI coding agent workloads or **audit & "toast"** an existing server configuration for amateur setups, power traps, and performance bloat.

Always detect before acting: check what the machine is (VM, laptop, bare metal), who the agent user is, and what already works. Then change only what is missing.

---

## 1. Core Philosophy: The Maxxed Agent Server

A true AI agent server (whether a $5/mo VPS, a refurbished ThinkPad laptop, or a Proxmox cluster node) must adhere to six non-negotiable rules:
1. **Never Sleep on AC**: `sleep.target`, `suspend.target`, `hibernate.target`, and `hybrid-sleep.target` must be completely masked.
2. **Never Cook the Battery**: On laptop servers, charge thresholds must be capped to 80% to avoid thermal battery swelling ("pillow battery").
3. **No Interactive Roadblocks**: Passwordless sudo must be configured for the agent user; Tailscale and Docker must not require interactive TTY prompts to function.
4. **Compressed In-Memory Swap**: ZRAM swap (zstd, 50% RAM) must be active to prevent heavy agent builds or Docker compilations from thrashing SSD disks.
5. **Modern Native Runtimes**: `uv` & `uvx` (Rust Python), `Vite+` (`vp`) & Node.js LTS, Docker Engine v2, and Tailscale mesh networking.
6. **Git Just Works**: `git clone`/`git push` to GitHub must succeed without prompts, over HTTPS (via the `gh` credential helper) or SSH, for the agent user.

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
curl -fsSL https://raw.githubusercontent.com/kshanxs/servermaxxing/main/scripts/servermaxxing.sh -o /tmp/servermaxxing.sh && sudo bash /tmp/servermaxxing.sh
```

Direct agent auto-launch (e.g. Claude Code or Codex):
```bash
curl -fsSL https://raw.githubusercontent.com/kshanxs/servermaxxing/main/scripts/servermaxxing.sh -o /tmp/servermaxxing.sh && sudo bash /tmp/servermaxxing.sh --agent claude
```

Fully unattended (Tailscale + GitHub login, no prompts). Get the values from the user and never echo them back:
```bash
sudo TAILSCALE_AUTHKEY="tskey-auth-..." GH_TOKEN="<github token>" bash /tmp/servermaxxing.sh
```

On a fresh root-only cloud VPS:
```bash
apt-get update -y && apt-get install -y curl && id -u dev &>/dev/null || (adduser --disabled-password --gecos "" dev && usermod -aG sudo dev) && su - dev -c "curl -fsSL https://raw.githubusercontent.com/kshanxs/servermaxxing/main/scripts/servermaxxing.sh -o /tmp/servermaxxing.sh && sudo bash /tmp/servermaxxing.sh --agent claude"
```

The script is idempotent (safe to re-run) and automatically detects:
* **Cloud VPS / VM / LXC**: Configures headless daemons, ZRAM, Docker, Tailscale, runtimes, and skips physical lid/battery policies.
* **Bare-Metal Laptop**: Applies 24/7 never-sleep masking, ignores lid close across all states, disables Wi-Fi power save, and enforces the 80% battery longevity threshold.
* **Bare-Metal Dedicated Server**: Masks sleep targets, disables ModemManager/multipathd bloat, and provisions the agent stack.
* **Target user**: The invoking `sudo` user (not root) receives docker group, passwordless sudo, Tailscale operator rights, GitHub git auth, and this skill.
* **GitHub git auth**: Pins github.com SSH host keys, then picks whichever method works:
  - `gh` is logged in (or `GH_TOKEN`/`GITHUB_TOKEN` was given): runs `gh auth setup-git`, so HTTPS works.
  - Otherwise, if an SSH key works: rewrites `https://github.com/` URLs to SSH.
  - Otherwise: generates `~/.ssh/id_ed25519` and prints the public key to add to GitHub.

  When `gh` is logged in, it also fills in a missing git `user.name`/`user.email` from the GitHub account, using the noreply email.

---

### Mode B: The "Server Toast" Audit Routine (Roast & Fix)

When a user asks you to "toast", audit, inspect, or critique their current machine or server setup, run these diagnostics **as the agent user** (not root) and deliver a sharp, skeptical critique:

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
echo "12. GitHub CLI login:" $(gh auth status --hostname github.com >/dev/null 2>&1 && echo 'logged in' || echo 'NOT LOGGED IN')
echo "13. Git credential helper:" $(git config --get-regexp '^credential' 2>/dev/null | grep -q gh && echo 'gh' || echo 'MISSING: HTTPS will prompt/fail')
echo "14. GitHub SSH:" $(ssh -T -o BatchMode=yes -o ConnectTimeout=10 git@github.com 2>&1 | grep -q 'successfully authenticated' && echo 'OK' || echo 'FAILING')
echo "15. Git identity:" "$(git config --global user.name 2>/dev/null || echo 'MISSING name')" "<$(git config --global user.email 2>/dev/null || echo 'MISSING email')>"
```

#### How to Format the "Toast":
1. **The Roasts (Flaws & Sins)**:
   - Call out any missing ZRAM (SSD killer under agent builds).
   - Call out unmasked sleep targets (if someone closes the lid, the agent dies mid-task).
   - Call out uncapped battery charging (baking the battery at 100% 24/7).
   - Call out Wi-Fi power saving enabled (dropping SSH sessions).
   - Call out Tailscale missing or unauthenticated (requiring open public SSH ports).
   - Call out GitHub auth where both items 13 and 14 fail (the agent's first `git push` dies on a username prompt).
2. **The Fixes**:
   - Provide the exact, hardened commands or recommend re-running `sudo bash servermaxxing.sh` (idempotent).
   - For git auth, follow Mode C.

---

### Tool Picking

When a user asks which tool to use for a job, or you need one yourself, use the [Tool Guide](https://github.com/kshanxs/servermaxxing/blob/main/docs/tools.md). Prefer the fast tools: `rg` over `grep -r`, `fd` over `find`, `uv run`/`uvx` over `pip install`, and `tmux` for long-running agent sessions.

---

### Mode C: Fix GitHub Git Auth

Use this when clone/push to github.com fails, e.g. `fatal: could not read Username for 'https://github.com': terminal prompts disabled`. Run everything as the agent user. Never print tokens or passwords.

1. Inspect: `gh auth status` and `git config --show-origin --get-regexp '^credential'`.
2. Test HTTPS without prompting, using a repo that requires auth when you have one (public repos succeed anonymously):
   `GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/<owner>/<repo>.git HEAD`
3. Test SSH: `ssh -T -o BatchMode=yes git@github.com`. A "successfully authenticated" reply means SSH works, even though the exit code is 1.
4. If HTTPS fails and `gh` is logged in, run `gh auth setup-git` and re-run step 2.
5. If `gh` is not logged in, run `gh auth login`, then `gh auth setup-git`. The user can also re-run the script with `GH_TOKEN`.
6. If SSH fails, check that `~/.ssh/id_ed25519.pub` is added at https://github.com/settings/keys. If no key exists, create one with `ssh-keygen -t ed25519`.
7. If only SSH works, either clone with `git@github.com:<owner>/<repo>.git`, or make HTTPS URLs use SSH:
   `git config --global url.git@github.com:.insteadOf https://github.com/`
8. If it still fails, check `echo $HOME`. A different `HOME` (sandbox, service, or `sudo` without `-H`) does not see `~/.gitconfig` or `~/.config/gh`.
9. Report which method works and give the exact clone command.
