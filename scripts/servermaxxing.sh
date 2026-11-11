#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Read-only audit: `bash servermaxxing.sh --audit [--json]`
# Runs as any user, needs no root, changes nothing. One line (or JSON object) per check with a
# status of ok, warn, fail or n/a, so people, agents and fleet tools can all read it.
# ------------------------------------------------------------------
if [[ " $* " == *" --audit "* ]]; then
    AUDIT_JSON=false
    [[ " $* " == *" --json "* ]] && AUDIT_JSON=true
    AUDIT_ROWS=()
    check() { AUDIT_ROWS+=("$1"$'\t'"$2"$'\t'"$3"); }
    have() { command -v "$1" >/dev/null 2>&1; }

    VIRT="$(systemd-detect-virt 2>/dev/null || true)"; VIRT="${VIRT:-none}"
    LAPTOP=false
    CHASSIS="$(tr -d '[:space:]' < /sys/class/dmi/id/chassis_type 2>/dev/null || true)"
    if [ "$VIRT" = none ] && { compgen -G "/sys/class/power_supply/BAT*" >/dev/null || [[ "$CHASSIS" =~ ^(8|9|10|11|14|30|31|32)$ ]]; }; then
        LAPTOP=true
    fi
    KIND="$([ "$VIRT" != none ] && echo "vm:$VIRT" || ([ "$LAPTOP" = true ] && echo laptop || echo bare-metal))"
    check host ok "$KIND, $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown OS}"), $(uname -m)"

    if [ "$VIRT" != none ]; then
        check sleep n/a "virtual machine"
    else
        SLEEP="$(systemctl is-enabled sleep.target 2>/dev/null || true)"
        if [ "$SLEEP" = masked ]; then check sleep ok "sleep targets masked"
        elif [ "$LAPTOP" = true ]; then check sleep fail "sleep.target is ${SLEEP:-unknown}: the laptop can suspend mid-task"
        else check sleep warn "sleep.target is ${SLEEP:-unknown}, not masked: an idle or power-key suspend stops agents"; fi
    fi
    if [ "$LAPTOP" = true ]; then
        LID="$(systemd-analyze cat-config systemd/logind.conf 2>/dev/null | grep -E '^HandleLidSwitch=' | tail -1 || true)"
        if [ "$LID" = "HandleLidSwitch=ignore" ]; then check lid ok "lid close ignored"
        elif [ "$SLEEP" = masked ]; then check lid warn "lid close still asks to suspend (blocked only because sleep is masked)"
        else check lid fail "closing the lid suspends the machine"; fi
        if [ -d /etc/NetworkManager ]; then
            grep -qs "wifi.powersave *= *2" /etc/NetworkManager/conf.d/*.conf \
                && check wifi_powersave ok "disabled" || check wifi_powersave warn "Wi-Fi power save may drop SSH"
        fi
        CAP="$(cat /sys/class/power_supply/BAT*/charge_control_end_threshold 2>/dev/null | head -1 || true)"
        if [ -z "$CAP" ]; then check battery_cap warn "no charge threshold control"
        elif [ "$CAP" -le 85 ]; then check battery_cap ok "${CAP}%"
        else check battery_cap fail "charges to ${CAP}% on constant AC"; fi
    fi

    grep -q zram /proc/swaps 2>/dev/null && check zram ok "$(awk '/zram/{printf "%d MiB", $3/1024}' /proc/swaps)" \
        || check zram warn "no zram swap: heavy builds swap to disk"
    MEM_MB="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    check memory "$([ "$MEM_MB" -ge 3800 ] && echo ok || echo warn)" "${MEM_MB} MiB"
    DISK_PCT="$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}' || true)"
    DISK_PCT="${DISK_PCT:-0}"
    check disk "$([ "$DISK_PCT" -lt 85 ] && echo ok || ([ "$DISK_PCT" -lt 95 ] && echo warn || echo fail))" "/ is ${DISK_PCT}% full"

    sudo -n true 2>/dev/null && check sudo ok "passwordless" || check sudo warn "sudo asks for a password: agents cannot use it"
    if have docker; then
        docker info >/dev/null 2>&1 && check docker ok "$(docker --version 2>/dev/null | cut -d, -f1)" \
            || check docker warn "installed, but $(id -un) cannot reach the daemon (docker group?)"
    else check docker fail "missing"; fi
    TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    TS_IF="$(ip -4 -br addr show tailscale0 2>/dev/null | awk '{print $3}' | cut -d/ -f1 || true)"
    if [ -n "$TS_IP" ]; then check tailscale ok "$TS_IP"
    elif [ -n "$TS_IF" ]; then check tailscale ok "$TS_IF (tailscale0 up; CLI not on PATH, e.g. running in a container)"
    elif have tailscale; then check tailscale fail "installed, not connected"
    else check tailscale fail "missing"; fi
    for t in git uv node vp tmux rg jq; do
        have "$t" && check "$t" ok "$({ "$t" --version 2>/dev/null || "$t" -V 2>/dev/null; } | head -1 | cut -c1-60)" \
            || check "$t" "$([ "$t" = git ] && echo fail || echo warn)" "missing"
    done
    for t in claude codex; do
        have "$t" && check "$t" ok "installed" || check "$t" n/a "not installed"
    done

    if have gh && gh auth status --hostname github.com >/dev/null 2>&1; then check gh_login ok "logged in"
    else check gh_login warn "gh not logged in"; fi
    git config --get-regexp '^credential' 2>/dev/null | grep -q gh && HTTPS_OK=true || HTTPS_OK=false
    SSH_OUT="$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 git@github.com 2>&1 || true)"
    [[ "$SSH_OUT" == *"successfully authenticated"* ]] && SSH_OK=true || SSH_OK=false
    if [ "$HTTPS_OK" = true ] || [ "$SSH_OK" = true ]; then
        check github_git ok "$([ "$HTTPS_OK" = true ] && echo 'HTTPS via gh')$([ "$HTTPS_OK" = true ] && [ "$SSH_OK" = true ] && echo ', ')$([ "$SSH_OK" = true ] && echo 'SSH')"
    else
        check github_git fail "neither HTTPS (gh credential helper) nor SSH works: clone/push will prompt"
    fi
    GN="$(git config --global user.name 2>/dev/null || true)"; GE="$(git config --global user.email 2>/dev/null || true)"
    [ -n "$GN" ] && [ -n "$GE" ] && check git_identity ok "set" || check git_identity warn "user.name or user.email missing"

    if [ "$AUDIT_JSON" = true ]; then
        esc() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "${s//$'\t'/ }"; }
        printf '['
        sep=""
        for row in "${AUDIT_ROWS[@]}"; do
            IFS=$'\t' read -r k st d <<< "$row"
            printf '%s{"check":"%s","status":"%s","detail":"%s"}' "$sep" "$(esc "$k")" "$(esc "$st")" "$(esc "$d")"
            sep=","
        done
        printf ']\n'
    else
        echo "servermaxxing audit: $(hostname) as $(id -un)"
        for row in "${AUDIT_ROWS[@]}"; do
            IFS=$'\t' read -r k st d <<< "$row"
            printf '  %-15s %-5s %s\n' "$k" "$st" "$d"
        done
        echo "Fix: sudo bash servermaxxing.sh (idempotent), or follow the skill's modes."
    fi
    exit 0
fi

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
POST_HOOK="${SERVERMAXXING_POST_HOOK:-}"

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
        --post-hook)
            POST_HOOK="${2:-}"
            shift 2 2>/dev/null || shift 1
            ;;
        --post-hook=*)
            POST_HOOK="${1#*=}"
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
            echo "  --post-hook <command>                   Run a command as the target user after provisioning"
            echo "                                          (join a fleet, clone dotfiles...); also SERVERMAXXING_POST_HOOK"
            echo "  --audit [--json]                        Read-only check of this machine, no root needed; changes nothing"
            echo "  GH_TOKEN=<token> (env)                  Log target user into GitHub unattended (also reads GITHUB_TOKEN)"
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
    git \
    openssh-client \
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
    # Clean up broken packagecloud apt lists (which break on Ubuntu 24.04+ due to missing noble release)
    rm -f /etc/apt/sources.list.d/ookla_speedtest-cli.list 2>/dev/null || true

    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64)
            OOKLA_ARCH="x86_64"
            ;;
        aarch64|arm64)
            OOKLA_ARCH="aarch64"
            ;;
        armv7l|armhf)
            OOKLA_ARCH="armhf"
            ;;
        *)
            OOKLA_ARCH=""
            ;;
    esac

    if [ -n "$OOKLA_ARCH" ]; then
        TMP_SPEEDTEST="$(mktemp -d /tmp/ookla-speedtest.XXXXXX)"
        if curl -fsSL "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${OOKLA_ARCH}.tgz" -o "${TMP_SPEEDTEST}/speedtest.tgz"; then
            tar -xzf "${TMP_SPEEDTEST}/speedtest.tgz" -C "${TMP_SPEEDTEST}"
            install -m 755 "${TMP_SPEEDTEST}/speedtest" /usr/local/bin/speedtest
            rm -rf "${TMP_SPEEDTEST}"
            echo "Installed official Ookla speedtest binary to /usr/local/bin/speedtest."
        else
            echo "Warning: Failed to download Ookla speedtest binary. Continuing..."
            rm -rf "${TMP_SPEEDTEST}"
        fi
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

# GitHub git auth for target user: detect whichever of HTTPS (gh) / SSH works so clone/push never prompt
echo "Configuring GitHub git authentication for ${TARGET_USER}..."
GIT_AUTH_STATE="Not configured"
GH_LOGIN_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

as_target() { su - "$TARGET_USER" -c "$1"; }

if ! command -v gh >/dev/null 2>&1; then
    echo "Installing GitHub CLI (gh)..."
    if ! apt-get install -y gh; then
        # Fallback: official GitHub CLI apt repo (distros without gh in their archive)
        mkdir -p -m 755 /etc/apt/keyrings
        if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; then
            chmod 644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
            apt-get update -y && apt-get install -y gh || echo "Warning: gh installation failed. Continuing..."
        else
            echo "Warning: gh installation failed. Continuing..."
        fi
    fi
fi

if id "$TARGET_USER" &>/dev/null && command -v git >/dev/null 2>&1; then
    TARGET_GROUP="$(id -gn "$TARGET_USER")"
    SSH_DIR="${TARGET_HOME}/.ssh"
    install -d -m 700 -o "$TARGET_USER" -g "$TARGET_GROUP" "$SSH_DIR"

    # Pin github.com host keys from GitHub's API (fetched over TLS) so SSH never asks to trust the host
    if ! ssh-keygen -F github.com -f "${SSH_DIR}/known_hosts" >/dev/null 2>&1; then
        GH_HOST_KEYS="$(curl -fsSL https://api.github.com/meta 2>/dev/null | jq -r '.ssh_keys[]? | "github.com " + .' 2>/dev/null || true)"
        if [ -n "$GH_HOST_KEYS" ]; then
            printf '%s\n' "$GH_HOST_KEYS" >> "${SSH_DIR}/known_hosts"
            chown "${TARGET_USER}:${TARGET_GROUP}" "${SSH_DIR}/known_hosts"
            chmod 644 "${SSH_DIR}/known_hosts"
        fi
    fi

    GH_LOGGED_IN=false
    if command -v gh >/dev/null 2>&1; then
        # Optional unattended login: sudo GH_TOKEN=<token> bash servermaxxing.sh (token read from stdin, never echoed)
        if [ -n "$GH_LOGIN_TOKEN" ] && ! as_target 'gh auth status --hostname github.com' >/dev/null 2>&1; then
            echo "Logging ${TARGET_USER} into GitHub with provided token..."
            printf '%s' "$GH_LOGIN_TOKEN" | as_target 'gh auth login --hostname github.com --with-token' || echo "Warning: gh token login failed. Continuing..."
        fi
        if as_target 'gh auth status --hostname github.com' >/dev/null 2>&1; then
            GH_LOGGED_IN=true
        fi
    fi

    # GitHub answers a working key with "successfully authenticated" (exit code 1, no shell access)
    SSH_OUT="$(as_target 'ssh -T -o BatchMode=yes -o ConnectTimeout=10 git@github.com' 2>&1 || true)"
    SSH_OK=false
    if [[ "$SSH_OUT" == *"successfully authenticated"* ]]; then
        SSH_OK=true
    fi

    if [ "$GH_LOGGED_IN" = true ]; then
        # Preferred: HTTPS via gh credential helper; drop any SSH rewrite left by an earlier run
        as_target 'gh auth setup-git --hostname github.com' || true
        as_target 'git config --global --unset-all url.git@github.com:.insteadof "^https://github.com/$"' 2>/dev/null || true
        GIT_AUTH_STATE="HTTPS via gh credential helper$([ "$SSH_OK" = true ] && echo ', SSH also OK')"
    elif [ "$SSH_OK" = true ]; then
        # No gh login but SSH key works: transparently route https://github.com/ URLs over SSH
        as_target 'git config --global --replace-all url.git@github.com:.insteadof https://github.com/ "^https://github.com/$"'
        GIT_AUTH_STATE="SSH (https://github.com/ URLs rewritten to SSH)"
    else
        # Neither works yet: leave a key ready so the user only has to add it to GitHub
        if [ ! -f "${SSH_DIR}/id_ed25519" ]; then
            as_target 'ssh-keygen -q -t ed25519 -N "" -C "$(whoami)@$(hostname)" -f ~/.ssh/id_ed25519'
        fi
        GIT_AUTH_STATE="Not authenticated (run: gh auth login && gh auth setup-git, or add ~/.ssh/id_ed25519.pub at https://github.com/settings/keys)"
        echo "Notice: GitHub git auth is not set up for ${TARGET_USER}. Either:"
        echo "  1. Run as ${TARGET_USER}: gh auth login && gh auth setup-git   (or re-run with GH_TOKEN=<token>)"
        echo "  2. Add this SSH key at https://github.com/settings/keys, then re-run this script:"
        echo "     $(cat "${SSH_DIR}/id_ed25519.pub" 2>/dev/null)"
    fi

    # Fill in git identity from the GitHub account when unset (never overrides an existing identity)
    if [ "$GH_LOGGED_IN" = true ]; then
        if [ -z "$(as_target 'git config --global user.name' 2>/dev/null || true)" ]; then
            GH_NAME="$(as_target 'gh api user --jq ".name // .login"' 2>/dev/null || true)"
            if [ -n "$GH_NAME" ]; then
                as_target "git config --global user.name $(printf '%q' "$GH_NAME")"
            fi
        fi
        if [ -z "$(as_target 'git config --global user.email' 2>/dev/null || true)" ]; then
            GH_EMAIL="$(as_target "gh api user --jq '(.id|tostring) + \"+\" + .login + \"@users.noreply.github.com\"'" 2>/dev/null || true)"
            if [ -n "$GH_EMAIL" ]; then
                as_target "git config --global user.email $(printf '%q' "$GH_EMAIL")"
            fi
        fi
    fi
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
echo " GitHub git:  ${GIT_AUTH_STATE}"
echo " uv / uvx:    $(command -v uv >/dev/null && echo 'Ready' || echo 'Missing')"
echo " Vite+ (vp):  $(command -v vp >/dev/null && echo 'Ready' || echo 'Missing')"
echo " Claude Code: $(command -v claude >/dev/null && echo 'Ready' || echo 'Not installed')"
echo " Codex CLI:   $(command -v codex >/dev/null && echo 'Ready' || echo 'Not installed')"
echo " Herdr / TUI: $(command -v herdr >/dev/null && echo 'Ready' || echo 'Missing')"
echo "======================================================"

# Seed servermaxxing skill into target user's workspace (always, so any agent opened later can audit/fix the box)
mkdir -p "${TARGET_HOME}/.agents/skills/servermaxxing"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/../.agents/skills/servermaxxing/SKILL.md" ]; then
    cp -f "${SCRIPT_DIR}/../.agents/skills/servermaxxing/SKILL.md" "${TARGET_HOME}/.agents/skills/servermaxxing/SKILL.md" 2>/dev/null || true
elif [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/.agents/skills/servermaxxing/SKILL.md" ]; then
    cp -f "${SCRIPT_DIR}/.agents/skills/servermaxxing/SKILL.md" "${TARGET_HOME}/.agents/skills/servermaxxing/SKILL.md" 2>/dev/null || true
else
    curl -fsSL https://raw.githubusercontent.com/kshanxs/servermaxxing/main/.agents/skills/servermaxxing/SKILL.md -o "${TARGET_HOME}/.agents/skills/servermaxxing/SKILL.md" 2>/dev/null || true
fi
chown -R "${TARGET_USER}:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "${TARGET_HOME}/.agents" 2>/dev/null || true

# Post-provision hook: hand over to the caller's own setup (a fleet join, dotfiles, ...), as the target user
if [ -n "$POST_HOOK" ]; then
    echo ">>> Running post-provision hook as ${TARGET_USER}..."
    if su - "$TARGET_USER" -c "$POST_HOOK"; then
        echo "Post-provision hook finished."
    else
        echo "Warning: post-provision hook failed (exit $?). The machine is provisioned; re-run the hook by hand."
    fi
fi

# 8. Automated Agent Auto-Launch (if requested via --agent / AGENT)
if [ "$AGENT_CHOICE" != "none" ]; then
    if [ -t 0 ] || [ -c /dev/stdin ]; then
        echo ""
        echo ">>> Launching agent '${AGENT_CHOICE}' as user '${TARGET_USER}'..."
        case "$AGENT_CHOICE" in
            claude)
                exec su - "${TARGET_USER}" -c 'cd ~ && claude "Review and audit this machine against servermaxxing standards. Check sleep masking, battery caps, ZRAM swap, Docker, Tailscale, and GitHub git auth."'
                ;;
            codex)
                exec su - "${TARGET_USER}" -c 'cd ~ && codex "Review and audit this machine against servermaxxing standards. Check sleep masking, battery caps, ZRAM swap, Docker, Tailscale, and GitHub git auth."'
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

