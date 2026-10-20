#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "======================================================"
echo "          servermaxxing : agent box tuner             "
echo "======================================================"

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || eval echo ~"$TARGET_USER")"
echo "Target user: ${TARGET_USER} (Home: ${TARGET_HOME})"

AGENT_CHOICE="${AGENT:-none}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
TAILSCALE_SSH=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent|-a)
            AGENT_CHOICE="${2:-none}"
            shift 2 2>/dev/null || shift 1
            ;;
        --agent=*)
            AGENT_CHOICE="${1#*=}"
            shift
            ;;
        --tailscale-authkey|--tailscale-key|-k)
            TAILSCALE_AUTHKEY="${2:-}"
            shift 2 2>/dev/null || shift 1
            ;;
        --tailscale-authkey=*|--tailscale-key=*)
            TAILSCALE_AUTHKEY="${1#*=}"
            shift
            ;;
        --no-tailscale-ssh)
            TAILSCALE_SSH=false
            shift
            ;;
        --help|-h)
            echo "Usage: sudo bash servermaxxing.sh [options]"
            echo ""
            echo "Options:"
            echo "  -a, --agent <claude|codex|herdr|tuios>  Auto-install and drop into agent session"
            echo "  -k, --tailscale-key, --tailscale-authkey <key> Join Tailscale mesh network unattended"
            echo "  --no-tailscale-ssh                      Disable Tailscale SSH flag (--ssh is enabled by default)"
            echo "  -h, --help                              Show this help message"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

if [ "$AGENT_CHOICE" != "none" ]; then
    echo "Selected Agent Auto-Launch: ${AGENT_CHOICE}"
fi
if [ -n "$TAILSCALE_AUTHKEY" ]; then
    echo "Tailscale Auth Key provided via CLI/environment."
fi

# 0. Dynamic Hardware & Virtualization Environment Detection
echo "[0/7] Detecting Host Environment & Hardware..."
VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo 'none')"
IS_VM=false
IS_LAPTOP=false

if [ "$VIRT_TYPE" != "none" ]; then
    IS_VM=true
    echo ">>> Host Detected: Virtual Machine / VPS / Container (${VIRT_TYPE})"
else
    # Check if physical host is a laptop / portable machine
    CHASSIS_TYPE=""
    if [ -f /sys/class/dmi/id/chassis_type ]; then
        CHASSIS_TYPE="$(tr -d '[:space:]' < /sys/class/dmi/id/chassis_type 2>/dev/null || true)"
    fi

    if compgen -G "/sys/class/power_supply/BAT*" > /dev/null || [[ "$CHASSIS_TYPE" =~ ^(8|9|10|11|14|30|31|32)$ ]]; then
        IS_LAPTOP=true
        echo ">>> Host Detected: Physical Laptop / Portable Workstation (Chassis: ${CHASSIS_TYPE:-Battery})"
    else
        echo ">>> Host Detected: Physical Dedicated Server / Desktop / Tower"
    fi
fi

# 1. Stop and disable unneeded background services
echo "[1/7] Disabling unneeded background daemons..."
systemctl stop ModemManager.service 2>/dev/null || true
systemctl disable ModemManager.service 2>/dev/null || true
systemctl mask ModemManager.service 2>/dev/null || true

systemctl stop multipathd.service 2>/dev/null || true
systemctl disable multipathd.service 2>/dev/null || true
systemctl mask multipathd.service 2>/dev/null || true

systemctl stop fwupd.service 2>/dev/null || true
systemctl disable fwupd.service 2>/dev/null || true

# 2. Remove unwanted snaps
echo "[2/7] Removing unwanted snaps (hwctl, lxd)..."
if snap list hwctl &>/dev/null; then
    snap remove hwctl || true
fi
if snap list lxd &>/dev/null; then
    snap remove lxd || true
fi

# 3. Hardware-Aware Power & Sleep Management
echo "[3/7] Configuring Power, Lid & 24/7 Uptime Policies..."
if [ "$IS_LAPTOP" = true ]; then
    echo "Applying dedicated Laptop Server optimizations (Never Sleep / Continuous Operation)..."
    
    # Completely mask all systemd sleep & suspend targets
    systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
    
    # Permanent logind ignore rules across all lid & power states
    mkdir -p /etc/systemd/logind.conf.d
    cat << 'EOF' > /etc/systemd/logind.conf.d/ignore-lid.conf
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
LidSwitchIgnoreInhibited=no
EOF
    systemctl kill -s HUP systemd-logind 2>/dev/null || true

    # Disable Wi-Fi power saving (prevents high latency & SSH/Tailscale disconnects over Wi-Fi)
    if [ -d /etc/NetworkManager/conf.d ]; then
        cat << 'EOF' > /etc/NetworkManager/conf.d/default-wifi-powersave-on.conf
[connection]
wifi.powersave = 2
EOF
        systemctl reload NetworkManager 2>/dev/null || true
    fi

    # Battery Longevity Health Cap: set 80% charge threshold to avoid battery swelling under continuous AC power
    for bat_thresh in /sys/class/power_supply/BAT*/charge_control_end_threshold; do
        if [ -w "$bat_thresh" ]; then
            echo 80 > "$bat_thresh" 2>/dev/null || true
            echo "Set battery charging longevity threshold to 80% on $bat_thresh."
        fi
    done
elif [ "$IS_VM" = true ]; then
    echo "VPS/VM environment detected: skipping physical lid and battery configurations."
else
    # Dedicated desktop/server
    echo "Dedicated physical server detected: masking sleep and suspend targets..."
    systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
fi

# 4. Install essential CLI tools, system utilities & configure ZRAM
echo "[4/7] Installing CLI utilities (ripgrep, fd, fzf, ncdu, tree, tmux, jq, btop, htop, fastfetch, neofetch, superfile, herdr, tuios, speedtest) & zram-tools..."
apt-get update -y
apt-get install -y --no-install-recommends \
    ripgrep \
    fd-find \
    fzf \
    ncdu \
    tree \
    tmux \
    jq \
    btop \
    htop \
    fastfetch \
    zram-tools

# Symlink fdfind -> fd for standard usage
if command -v fdfind >/dev/null && ! command -v fd >/dev/null; then
    ln -sf "$(command -v fdfind)" /usr/local/bin/fd
fi

# Install neofetch standalone script if not present
if ! command -v neofetch >/dev/null; then
    curl -fsSL https://raw.githubusercontent.com/dylanaraps/neofetch/master/neofetch -o /usr/local/bin/neofetch
    chmod +x /usr/local/bin/neofetch
fi

# Install superfile terminal file manager if not present
if ! command -v spf >/dev/null; then
    echo "Installing superfile..."
    if ! bash -c "$(curl -sLo- https://superfile.dev/install.sh)"; then
        echo "Warning: superfile installation failed or hit GitHub API rate limits. Continuing..."
    fi
fi

# Install Herdr agent runtime orchestrator if not present
if ! command -v herdr >/dev/null; then
    echo "Installing Herdr agent runtime..."
    if ! curl -fsSL https://herdr.dev/install.sh | HERDR_INSTALL_DIR=/usr/local/bin sh; then
        echo "Warning: Herdr installation failed. Continuing..."
    fi
fi

# Install tuios terminal window manager with agent inbox if not present
if ! command -v tuios >/dev/null; then
    echo "Installing tuios..."
    if ! bash -c "$(curl -fsSL https://raw.githubusercontent.com/Gaurav-Gosain/tuios/main/install.sh)"; then
        echo "Warning: tuios installation failed or hit GitHub API rate limits. Continuing..."
    fi
fi

# Install official Ookla Speedtest CLI if not present
if ! command -v speedtest >/dev/null; then
    echo "Installing official Ookla speedtest CLI..."
    if curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash; then
        apt-get install -y speedtest || true
    else
        echo "Warning: Ookla speedtest repository setup failed. Continuing..."
    fi
fi

# Configure zram for in-memory compressed swap (50% RAM, zstd compression)
cat << 'EOF' > /etc/default/zramswap
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
systemctl restart zramswap.service 2>/dev/null || service zramswap restart 2>/dev/null || true

# 5. Install Modern Language Runtimes: uv (Python) & Vite+ (Node.js & Bun)
echo "[5/7] Installing Modern Language Runtimes (uv, Vite+, Node.js)..."

# Install uv & uvx globally
if ! command -v uv >/dev/null 2>&1; then
    echo "Installing uv & uvx (ultra-fast Rust Python)..."
    if curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh; then
        chmod +x /usr/local/bin/uv /usr/local/bin/uvx 2>/dev/null || true
        echo "Installed uv & uvx to /usr/local/bin."
    else
        echo "Warning: uv installation failed. Continuing..."
    fi
fi

# Install Node.js LTS
if ! command -v node >/dev/null 2>&1; then
    echo "Installing Node.js & npm..."
    apt-get install -y nodejs npm || true
fi

# Install Vite+ (vp) for target user and expose globally
if ! command -v vp >/dev/null 2>&1; then
    echo "Installing Vite+ (vp) runtime..."
    if id "$TARGET_USER" &>/dev/null; then
        su - "$TARGET_USER" -c 'curl -fsSL https://vite.plus | VP_NODE_MANAGER="yes" bash' 2>/dev/null || true
        TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || eval echo ~"$TARGET_USER")"
        VP_BIN_LOC=$(find "${TARGET_HOME}/.vite-plus" "${TARGET_HOME}/.local/share/vite-plus" -name "vp" -type f 2>/dev/null | head -n1 || true)
        if [ -n "$VP_BIN_LOC" ] && [ -x "$VP_BIN_LOC" ]; then
            ln -sf "$VP_BIN_LOC" /usr/local/bin/vp
            echo "Symlinked Vite+ (vp) to /usr/local/bin/vp."
        fi
    fi
fi

# Optional Agent CLI installations
if [ "$AGENT_CHOICE" = "claude" ] && ! command -v claude >/dev/null 2>&1; then
    echo "Installing Claude Code CLI (@anthropic-ai/claude-code)..."
    npm install -g @anthropic-ai/claude-code || true
fi

if [ "$AGENT_CHOICE" = "codex" ] && ! command -v codex >/dev/null 2>&1; then
    echo "Installing Codex CLI (@codex-ai/cli)..."
    npm install -g @codex-ai/cli || true
fi

# 6. Install Docker, Docker Compose & Tailscale Mesh VPN
echo "[6/7] Installing Docker Engine, Compose & Tailscale..."

# Docker Engine & Compose
if ! command -v docker >/dev/null; then
    apt-get install -y docker.io docker-compose-v2 docker-buildx || curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi

if id "$TARGET_USER" &>/dev/null; then
    usermod -aG docker "$TARGET_USER"
    echo "Added $TARGET_USER to docker group."
fi

# Tailscale Mesh VPN
echo "Configuring Tailscale kernel network optimizations..."
mkdir -p /etc/sysctl.d
cat << 'EOF' > /etc/sysctl.d/99-tailscale.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-tailscale.conf 2>/dev/null || true

if ! command -v tailscale >/dev/null 2>&1; then
    echo "Installing Tailscale Mesh VPN..."
    if curl -fsSL https://tailscale.com/install.sh | sh; then
        systemctl enable --now tailscaled
        echo "Tailscale installed and daemon active."
    else
        echo "Warning: Tailscale installation failed. Continuing..."
    fi
fi

TS_UP_FLAGS="--operator=${TARGET_USER}"
if [ "$TAILSCALE_SSH" = true ]; then
    TS_UP_FLAGS="${TS_UP_FLAGS} --ssh"
fi

if [ -n "${TAILSCALE_AUTHKEY:-}" ] && command -v tailscale >/dev/null 2>&1; then
    echo "Authenticating Tailscale with provided auth key (flags: ${TS_UP_FLAGS})..."
    tailscale up --authkey="${TAILSCALE_AUTHKEY}" ${TS_UP_FLAGS} || true
    echo "Tailscale connected. Node IP: $(tailscale ip -4 2>/dev/null || echo 'authenticating')"
else
    # Set operator permissions if tailscaled is active so target user can control Tailscale without sudo
    tailscale set --operator="${TARGET_USER}" 2>/dev/null || true
    echo "Tailscale is ready. To connect node with SSH & operator enabled:"
    echo "  sudo tailscale up ${TS_UP_FLAGS}"
fi

# 7. Ensure passwordless sudo is configured for non-interactive agent execution
echo "[7/7] Ensuring passwordless sudo is configured for $TARGET_USER..."
cat << EOF > "/etc/sudoers.d/${TARGET_USER}"
${TARGET_USER} ALL=(ALL) NOPASSWD:ALL
EOF
chmod 0440 "/etc/sudoers.d/${TARGET_USER}"

TS_IP="$(tailscale ip -4 2>/dev/null || echo 'Not connected')"
TS_SSH_STATE="$([ "$TAILSCALE_SSH" = true ] && echo 'Enabled (--ssh)' || echo 'Disabled')"

echo "======================================================"
echo " Server tuning complete! "
echo " Environment: $( [ "$IS_LAPTOP" = true ] && echo 'Laptop Server (24/7 Never-Sleep Enabled)' || ([ "$IS_VM" = true ] && echo "Virtual Machine / VPS (${VIRT_TYPE})" || echo 'Bare-Metal Dedicated Server') )"
echo " Target user: ${TARGET_USER}"
echo " Docker:      $(command -v docker >/dev/null && echo 'Ready' || echo 'Missing')"
echo " Tailscale:   $(command -v tailscale >/dev/null && echo "Ready (IP: ${TS_IP}, SSH: ${TS_SSH_STATE}, Operator: ${TARGET_USER})" || echo 'Missing')"
echo " uv / uvx:    $(command -v uv >/dev/null && echo 'Ready' || echo 'Missing')"
echo " Vite+ (vp):  $(command -v vp >/dev/null && echo 'Ready' || echo 'Missing')"
echo " Claude Code: $(command -v claude >/dev/null && echo 'Ready' || echo 'Not installed')"
echo " Codex CLI:   $(command -v codex >/dev/null && echo 'Ready' || echo 'Not installed')"
echo " Herdr / TUI: $(command -v herdr >/dev/null && echo 'Ready' || echo 'Missing')"
echo "======================================================"

# 8. Automated Agent Auto-Launch (if requested via --agent / AGENT)
if [ "$AGENT_CHOICE" != "none" ]; then
    # Seed servermaxxing skill context into target user's workspace
    mkdir -p "${TARGET_HOME}/.agents/skills/servermaxxing"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
    if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/../.agents/skills/servermaxxing/SKILL.md" ]; then
        cp -f "${SCRIPT_DIR}/../.agents/skills/servermaxxing/SKILL.md" "${TARGET_HOME}/.agents/skills/servermaxxing/SKILL.md" 2>/dev/null || true
    elif [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/.agents/skills/servermaxxing/SKILL.md" ]; then
        cp -f "${SCRIPT_DIR}/.agents/skills/servermaxxing/SKILL.md" "${TARGET_HOME}/.agents/skills/servermaxxing/SKILL.md" 2>/dev/null || true
    else
        curl -fsSL https://raw.githubusercontent.com/kshanxs/servermaxxing/main/.agents/skills/servermaxxing/SKILL.md -o "${TARGET_HOME}/.agents/skills/servermaxxing/SKILL.md" 2>/dev/null || true
    fi
    chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.agents" 2>/dev/null || true

    if [ -t 0 ] || [ -c /dev/stdin ]; then
        echo ""
        echo ">>> Launching agent '${AGENT_CHOICE}' as user '${TARGET_USER}'..."
        case "$AGENT_CHOICE" in
            claude)
                exec su - "${TARGET_USER}" -c 'cd ~ && claude "Review and audit this machine against servermaxxing standards. Check sleep masking, battery caps, ZRAM swap, Docker, and Tailscale."'
                ;;
            codex)
                exec su - "${TARGET_USER}" -c 'cd ~ && codex "Review and audit this machine against servermaxxing standards. Check sleep masking, battery caps, ZRAM swap, Docker, and Tailscale."'
                ;;
            herdr)
                exec su - "${TARGET_USER}" -c 'herdr'
                ;;
            tuios)
                exec su - "${TARGET_USER}" -c 'tuios'
                ;;
            *)
                echo "Unrecognized agent: ${AGENT_CHOICE}. Available: claude, codex, herdr, tuios."
                ;;
        esac
    else
        echo ""
        echo "Notice: Non-interactive terminal detected. Skipping agent auto-launch."
        echo "To open your agent now as ${TARGET_USER}, run:"
        echo "  su - ${TARGET_USER} -c '${AGENT_CHOICE}'"
    fi
fi

