# Multi-Node LAN & Remote Deployment Architecture

A dynamic, production-grade guide for distributing your homelab and development workloads across multiple nodes on the same **Local Area Network (LAN)** or **Tailscale private mesh**.

This setup allows an **Agent / Development Node** (where you and your AI coding agents build and test code) to seamlessly deploy containers, databases, and websites to a **Production / Deployment Node** with **zero password prompts** and **no interactive `sudo` requirements**.

---

## 1. Architecture Overview

```mermaid
flowchart LR
    subgraph DEV["Dev / Agent Node ($DEV_HOST)"]
        direction TB
        AGENTS["AI Coding Agents (T3 Code, Claude, Codex)"]
        WORKSPACE["Workspaces, AST Parsers & Test Runners"]
        SSH_KEY["Deployment Keypair (~/.ssh/agent_deploy)"]
        AGENTS --> WORKSPACE
        WORKSPACE --> SSH_KEY
    end

    subgraph NET["Sub-Millisecond Interconnect"]
        direction TB
        SWITCH["Local Gigabit Switch / Ethernet"]
        TS_MESH["Tailscale Encrypted WireGuard Mesh"]
    end

    subgraph PROD["Production / Target Node ($PROD_HOST)"]
        direction TB
        DOCKER["Docker Engine (User in 'docker' group)"]
        PROXY["Reverse Proxy (Caddy / Traefik / Nginx)"]
        DB["Database Services (Supabase / PostgreSQL)"]
        APPS["Live Web Apps & Containerized Services"]
        DOCKER --> APPS
        DOCKER --> DB
        PROXY --> APPS
    end

    DEV --> NET
    NET --> PROD

    classDef devBox fill:#2b6cb0,stroke:#3182ce,color:#fff,stroke-width:2px;
    classDef netBox fill:#2d3748,stroke:#4a5568,color:#fff,stroke-width:2px;
    classDef prodBox fill:#285e61,stroke:#319795,color:#fff,stroke-width:2px;
    class DEV devBox;
    class NET netBox;
    class PROD prodBox;
```

### Why Decouple Development from Production?
1. **Zero Blast Radius**: Memory spikes or CPU pegging from agent builds, linters, or test suites never affect your live websites or databases.
2. **Resource Optimization**: Lightweight development nodes run only agent runtimes, while memory-heavy production nodes host your database and services.
3. **Sub-Millisecond LAN Latency**: Over a standard gigabit switch or Wi-Fi 6, latency between nodes is `< 1 ms`, making remote deployments feel instant.

---

## 2. Prerequisites & One-Time Authentication Setup

To allow autonomous agents to deploy without hanging on interactive password prompts:

### Step 1: Generate an Agent Deployment Keypair (On Dev Node)
On your **Dev / Agent Node**, create a dedicated deployment key without a passphrase:

```bash
# Generate dedicated Ed25519 keypair
ssh-keygen -t ed25519 -N "" -f ~/.ssh/agent_deploy -C "agent-deploy-key"
```

### Step 2: Authorize Key on Production Node
Export the public key to your **Production Node**:

```bash
PROD_USER="deploy"        # Replace with target username on production node
PROD_HOST="192.168.1.50"   # Replace with production LAN IP or Tailscale hostname

ssh-copy-id -i ~/.ssh/agent_deploy.pub "${PROD_USER}@${PROD_HOST}"
```

Test passwordless connection:
```bash
ssh -i ~/.ssh/agent_deploy "${PROD_USER}@${PROD_HOST}" "echo 'SSH authentication successful!'"
```

### Step 3: Eliminate `sudo` Requirement for Containers (On Production Node)
Add your target user to the `docker` group on the **Production Node** so container deployments never prompt for `sudo`:

```bash
# Run once on the Production Node:
sudo usermod -aG docker $USER
```

Verify non-root Docker access on the production host:
```bash
docker ps
```

---

## 3. Dynamic Deployment Strategies

```mermaid
sequenceDiagram
    autonumber
    actor Developer as Developer / Agent
    participant DevNode as Dev Node ($DEV_HOST)
    participant Auth as SSH Key (~/.ssh/agent_deploy)
    participant RemoteHost as Production Node ($PROD_HOST)
    participant Containers as Docker Containers

    Developer->>DevNode: Trigger project deployment
    DevNode->>Auth: Sign request using Ed25519
    Auth->>RemoteHost: Cryptographic SSH handshake (No password prompt)
    Note over RemoteHost: User belongs to docker group (No sudo prompt)
    DevNode->>RemoteHost: docker --context prod-node compose up -d --build
    RemoteHost->>Containers: Build images & perform rolling restart
    Containers-->>RemoteHost: Containers Healthy (Port 80/443 active)
    RemoteHost-->>DevNode: Exit code 0 + Stream build logs
    DevNode-->>Developer: Deployment verified successfully
```

Choose the deployment method that fits your workflow:

### Strategy A: Direct Agent Script Execution (Over SSH)
The agent executes a deployment command remotely and streams logs directly back into your editor session:

```bash
# Example agent deployment command:
ssh -i ~/.ssh/agent_deploy "${PROD_USER}@${PROD_HOST}" \
  "cd /opt/apps/my-project && git pull && docker compose up -d --build --remove-orphans"
```

#### Reusable Dynamic Deployment Script (`deploy.sh`)
Place this script in your project root so any agent can trigger it dynamically:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Read from environment variables or defaults
DEPLOY_HOST="${DEPLOY_HOST:-192.168.1.50}"
DEPLOY_USER="${DEPLOY_USER:-$USER}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/apps/$(basename "$PWD")}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/agent_deploy}"

echo "==> Deploying $(basename "$PWD") to ${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_DIR}..."

ssh -i "$SSH_KEY" "${DEPLOY_USER}@${DEPLOY_HOST}" << EOF
  set -e
  mkdir -p "${DEPLOY_DIR}"
  cd "${DEPLOY_DIR}"
  if [ -d .git ]; then
    git pull
  fi
  docker compose pull 2>/dev/null || true
  docker compose up -d --remove-orphans
  docker compose ps
EOF

echo "==> Deployment completed successfully!"
```

---

### Strategy B: Native Remote Docker Context (`docker context`)
Docker allows you to route your local Docker CLI directly to the remote daemon over SSH. Your agent runs commands locally, but containers spin up on the remote host:

```bash
# 1. Register the remote host as a Docker context (run once on Dev Node):
docker context create prod-node \
  --docker "host=ssh://${PROD_USER}@${PROD_HOST}" \
  --description "Production Host on LAN"

# 2. Deploy directly to the remote node:
docker --context prod-node compose up -d --build

# 3. Check running containers on the remote host:
docker --context prod-node ps
```

* **No SSH shell needed**: The local Docker client communicates directly with the remote Docker socket.
* **Instant Rollbacks**: `docker --context prod-node compose down` cleanly cleans up the remote stack.

---

### Strategy C: GitOps / Webhook Auto-Deployment (Dokploy or Coolify)
If you prefer continuous deployment triggered by git commits without maintaining SSH connections:

1. Install a self-hosted PaaS on your **Production Node** (e.g., [Dokploy](https://dokploy.com) or [Coolify](https://coolify.io)):
   ```bash
   # On Production Node:
   curl -fsSL https://dokploy.com/install.sh | sh
   ```
2. Connect your Git repository.
3. Every time your agent pushes a commit to `main`, the production node automatically pulls, builds, and swaps containers with zero downtime.

---

## 4. Environment Variables Configuration

Keep target IPs and configurations dynamic by defining environment variables in your project or `~/.bashrc`:

```bash
# In ~/.bashrc or project .env:
export PROD_NODE_HOST="prod-server.internal" # or Tailscale MagicDNS name
export PROD_NODE_USER="deploy"
export PROD_DEPLOY_KEY="$HOME/.ssh/agent_deploy"
```

---

## 5. Security & Network Hardening

1. **Firewall Isolation**: Configure `ufw` on the production node to only accept SSH (port 22) from your local subnet or Tailscale interface:
   ```bash
   sudo ufw default deny incoming
   sudo ufw allow in on tailscale0 to any port 22
   sudo ufw allow in from 192.168.1.0/24 to any port 22
   sudo ufw enable
   ```
2. **Dedicated Deployment Key**: Restrict the deployment key (`~/.ssh/agent_deploy`) exclusively to deployment operations.
3. **No Sudo in Production CI/CD**: By keeping your deploy user inside the `docker` group, you eliminate the need to grant passwordless sudo for container management.
