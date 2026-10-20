# 🧰 Tool Guide: Which Tool for Which Job

`servermaxxing.sh` installs a lot of tools on the agent box. This guide maps everyday jobs to the tool that does them best, for both you and your AI agents.

---

## 1. Quick Lookup: "I want to…"

| I want to… | Use | Example |
| :--- | :--- | :--- |
| Search code for a string or regex | `rg` (ripgrep) | `rg -n "TODO" src/` |
| Find files by name | `fd` | `fd -e ts config` |
| Pick a file, branch, or command interactively | `fzf` | `git switch $(git branch --format='%(refname:short)' \| fzf)` |
| See what is eating disk space | `ncdu` | `ncdu /` |
| See a project's folder layout | `tree` | `tree -L 2 -I node_modules` |
| Browse and manage files visually | `spf` (superfile) | `spf` |
| Read or reshape JSON | `jq` | `curl -s api.github.com/meta \| jq '.ssh_keys'` |
| Watch CPU, RAM, disk, and network live | `btop` (or `htop`) | `btop` |
| Get a one-glance system summary | `fastfetch` | `fastfetch` |
| Test the server's internet speed | `speedtest` | `speedtest` |
| Keep a session alive after disconnecting | `tmux` | `tmux new -As main` |
| Run and tile several agents at once | `tuios` / `herdr` | `tuios` |
| Run a Python script or tool without a venv | `uv` / `uvx` | `uvx ruff check .` |
| Manage Node.js / JS projects | `vp` (Vite+), `node`, `npm` | `vp --version` |
| Run databases or services in isolation | `docker`, `docker compose` | `docker compose up -d` |
| Reach the server from anywhere, no open ports | `tailscale` | `ssh user@<tailscale-name>` |
| Share a local dev server with your devices | `tailscale serve` | `tailscale serve 3000` |
| Expose a local port to the public internet | `tailscale funnel` | `tailscale funnel 3000` |
| Clone, open PRs, and check CI | `gh`, `git` | `gh pr create --fill` |
| Fix GitHub clone/push auth | `gh auth setup-git` | see the skill's Mode C |
| Hand a coding task to an agent | `claude`, `codex` | `claude "fix the failing tests"` |
---

## 2. Tools by Job

### Code Search & Navigation
| Tool | Best for | Why agents love it |
| :--- | :--- | :--- |
| `rg` (ripgrep) | Searching file contents | Respects `.gitignore` and is far faster than `grep -r`. That means fewer tokens spent waiting on slow searches. |
| `fd` | Finding files by name or extension | Simpler syntax than `find` and skips ignored files by default. |
| `fzf` | Interactive picking from any list | Pipes into anything, e.g. `fd \| fzf` or `history \| fzf`. |
| `tree` | Showing a directory structure | A quick map of a repo for you or an agent's context. |

### Files & Disk
| Tool | Best for |
| :--- | :--- |
| `spf` (superfile) | A visual TUI file manager for moving, copying, and previewing files. |
| `ncdu` | Finding what is filling the disk (`node_modules`, Docker images, logs). |

### Monitoring & Diagnostics
| Tool | Best for |
| :--- | :--- |
| `btop` | A live dashboard of CPU, memory, disks, network, and processes. Use it to spot runaway builds. |
| `htop` | A lighter process viewer. Use it to kill a stuck process quickly. |
| `fastfetch` / `neofetch` | A one-screen summary of the OS, kernel, CPU, RAM, and uptime. |
| `speedtest` | Checking bandwidth before blaming the network for slow pulls. |
| `jq` | Reading API responses and logs in JSON. |

### Sessions & Agent Multiplexing
| Tool | Best for |
| :--- | :--- |
| `tmux` | Keeping shells and agents running after SSH disconnects. Reattach with `tmux a`. |
| `tuios` | A terminal window manager with an agent inbox, for tiling several agents and approving their actions in one place. |
| `herdr` | An agent runtime orchestrator for running and supervising many agent sessions. |

### Language Runtimes
| Tool | Best for |
| :--- | :--- |
| `uv` | Python projects: `uv init`, `uv add`, `uv run`. It replaces pip, venv, and pip-tools. |
| `uvx` | One-off Python tools without installing them, e.g. `uvx ruff`, `uvx httpie`. |
| `vp` (Vite+), `node`, `npm` | JavaScript/TypeScript projects and Node-based CLIs (including Claude Code). |

### Containers
| Tool | Best for |
| :--- | :--- |
| `docker` | Running services (Postgres, Redis, etc.) without polluting the host. |
| `docker compose` | Multi-service stacks defined in `compose.yaml`. |

### Networking & Access
| Tool | Best for |
| :--- | :--- |
| `tailscale` | Private mesh access to the box from your laptop or phone, with zero open ports. |
| `tailscale ssh` | Keyless SSH over the mesh (enabled by default by the script). |
| `tailscale serve` / `funnel` | Sharing a dev server privately (`serve`) or publicly (`funnel`). |

### Git & GitHub
| Tool | Best for |
| :--- | :--- |
| `git` | Version control. The script configures HTTPS (via `gh`) or SSH automatically so it never prompts. |
| `gh` | PRs, issues, CI runs, releases, and GitHub login (`gh auth login`, `gh auth setup-git`). |

### AI Coding Agents
| Tool | Best for |
| :--- | :--- |
| `claude` (Claude Code) | Agentic coding in the terminal. Start it with `--agent claude` to have it audit the box. |
| `codex` | An alternative terminal coding agent. |

### System Tuning (runs in the background)
| Component | What it does for you |
| :--- | :--- |
| ZRAM (`zram-tools`) | Compressed swap in RAM. Heavy builds slow down instead of crashing or thrashing the SSD. |
| Sleep masking / lid ignore | Keeps laptop servers awake 24/7 with the lid closed. |
| 80% battery cap | Prevents battery swelling on always-plugged-in laptops. |

---

## 3. Common Workflows

| Workflow | Tool chain |
| :--- | :--- |
| Start a long agent task and walk away | `tmux new -As agent` → `claude "…"` → detach with `Ctrl-b d` → reattach later with `tmux a -t agent` |
| Explore an unfamiliar repo | `tree -L 2` → `rg -n "main\("` → `fd -e md` |
| Free up disk space | `ncdu /` → `docker system prune` → clear caches you find |
| Debug a slow machine | `btop` → find the heavy process → `htop` to kill it if needed |
| Spin up a dev database | `docker compose up -d postgres` |
| Share a preview with your phone | `vp dev` (or `npm run dev`) → `tailscale serve 5173` |
| Ship a change | `git switch -c fix/x` → commit → `gh pr create --fill` → `gh pr checks --watch` |
