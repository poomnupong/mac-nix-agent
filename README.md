# mac-nix-agent

**One-command Apple-silicon dev box for running a local AI coding agent.**

This repo is a declarative, end-to-end recipe for turning a fresh M-series Mac into a self-contained AI workstation:

- **Nix + nix-darwin + Home Manager** — reproducible system + user environment (CLI tools, fonts, shell, launchd services)
- **Homebrew** — declarative casks (VS Code, Ollama, LM Studio, oMLX, etc.) managed by nix-darwin
- **[oMLX](https://github.com/jundot/omlx)** — multi-model MLX inference server, OpenAI-compatible API on `localhost:8000`
- **[Hermes Agent](https://github.com/NousResearch/hermes-agent)** in an Apple `container` microVM — chat-driven coding agent with built-in SearXNG, browser, and shell tools, talking to oMLX over the vmnet bridge

The goal: clone the repo, run `./bootstrap.sh`, and have a working `hermes` chat against a locally hosted MLX model on the same Mac. Everything is reproducible — wipe the machine, re-run the script, get the same setup. No cloud dependency by default; cloud LLMs are a one-line config swap.

> **Philosophy.** This repo is meant to **accelerate your learning** of the Apple-silicon AI toolchain, not hide it from you. Lifecycle plumbing (`hermes-up`, `darwin-rebuild switch`) is aliased because it's plumbing. Workflow commands you should understand — model downloads, format conversion, abliteration, quantization — are **deliberately not aliased**. See [`modelops/`](modelops/README.md) for the modelops tutorial.

## Quick start

Fresh Mac? One command:

```bash
mkdir -p ~/repo && git clone https://github.com/<your-github-username>/mac-nix-agent.git ~/repo/mac-nix-agent
cd ~/repo/mac-nix-agent && ./bootstrap.sh
```

`bootstrap.sh` is idempotent — safe to re-run. It installs Nix, Homebrew, the Apple `container` runtime, applies the nix-darwin flake, seeds oMLX (host + API key), and brings up the Hermes container.

> **Note:** `bootstrap.sh` rewrites `flake.nix`'s `username` and `hostname` in place. After first run you'll see `flake.nix` as modified in `git status` — that's expected. Don't commit those local values back upstream; if you forked, keep your fork's `flake.nix` on the placeholders and let `bootstrap.sh` personalize on each clone.

Already bootstrapped? Day-to-day commands:

```bash
cd ~/repo/mac-nix-agent
sudo darwin-rebuild switch --flake .   # apply config changes
sudo nix flake update                  # bump all inputs
hermes-up                              # start Hermes agent container
hermes                                 # interactive chat
```

## Table of Contents

- [Quick start](#quick-start)
- [What this manages](#what-this-manages)
- [Hermes Agent (containerized)](#hermes-agent-containerized)
  - [Architecture](#architecture)
  - [Features](#features)
  - [LLM providers](#llm-providers)
  - [Directory layout](#directory-layout)
- [Local services](#local-services)
- [First-time setup](#first-time-setup)
- [Day-to-day usage](#day-to-day-usage)
- [Troubleshooting](#troubleshooting)
- [Backup & restore](#backup--restore)
- [Pushing to GitHub](#pushing-to-github)

---

## What this manages

| Layer | Tool | What |
|-------|------|------|
| **System** | nix-darwin | launchd services, Homebrew casks, Nix settings |
| **User** | Home Manager | CLI packages, shell, starship, tmux, git, fonts |
| **Manual** | You | VS Code extensions (GitHub Sync), Terminal.app theme, macOS preferences |

---

## Hermes Agent (containerized)

A self-contained AI coding agent running in an [Apple Container](https://developer.apple.com/documentation/virtualization) microVM (macOS 26+). One container bundles Hermes, SearXNG web search, and Camofox browser — no external dependencies beyond an LLM.

### Architecture

```
┌─────────────────────── macOS Host ───────────────────────┐
│                                                          │
│  oMLX / Ollama / LM Studio        repo: mac-nix-agent/   │
│  (:8000, Metal GPU)                 ├─ hermes/           │
│        ▲                            │   ├─ config.yaml   │
│        │ OpenAI-compat API          │   ├─ .env          │
│        │                            │   ├─ Dockerfile    │
│        │                            │   ├─ entrypoint.sh │
│  ┌─────┼──── Apple Container VM ────┼──────────────┐     │
│  │     │    hermes-agent            │              │     │
│  │     │    4 CPU · 8 GB RAM        │   mounts ──▶ │     │
│  │     │                            │              │     │
│  │  ┌──┴──────────┐                 │              │     │
│  │  │ Hermes CLI  │◀── config.yaml  │              │     │
│  │  │ /opt/data   │◀── .env         │              │     │
│  │  └──┬──────────┘                 │              │     │
│  │     │ tool calls                 │              │     │
│  │     ├──▶ SearXNG    (:8080)      │              │     │
│  │     ├──▶ Camofox    (:9377)      │              │     │
│  │     ├──▶ Terminal   (local bash) │              │     │
│  │     └──▶ Dashboard ─────────────────▶ :9119     │     │
│  │                                                 │     │
│  │  /opt/data/memories ◀── hermes/data/memories/   │     │
│  │  /opt/data/workspace◀── hermes/workspace/       │     │
│  └─────────────────────────────────────────────────┘     │
│                                                          │
│  OR: Ollama Cloud / OpenAI / Together / Groq (no GPU)    │
└──────────────────────────────────────────────────────────┘
```

### Features

- **Single container** — SearXNG, Camofox browser, and terminal all run inside one VM alongside Hermes. No Docker Compose, no multi-container networking.
- **Flexible LLM backend** — works with local inference (oMLX, Ollama, LM Studio, vLLM) or cloud APIs (Ollama Cloud, OpenAI, Together, Groq). Just edit `config.yaml` and `.env`.
- **Private memory** — `hermes/data/memories/` is **gitignored**: the agent learns about you locally and that knowledge never leaks to a (potentially public) repo. Back it up out-of-band (see [Backup & restore](#backup--restore)).
- **Self-sufficient toolbox** — Node.js, npm, pip available inside the container. Hermes can install its own packages at runtime.
- **Host-mounted config** — `config.yaml`, `.env`, `Dockerfile`, and `entrypoint.sh` are bind-mounted, so changes apply without rebuilding the image.
- **Sandboxed execution** — terminal backend is `local` (bash inside the VM), so Hermes can run arbitrary commands without touching the host.
- **One-command lifecycle** — `hermes-up` / `hermes-down` / `hermes-rebuild` shell aliases manage everything.

### First-time setup

```bash
cd ~/repo/mac-nix-agent/hermes
cp .env.example .env
vim .env   # set API keys for your chosen provider
```

### LLM providers

| Provider | Setup | GPU required? |
|----------|-------|:---:|
| **oMLX** (default) | Install via Homebrew, runs on `:8000`. Set `base_url` in `config.yaml` | Yes (Metal) |
| **Ollama** (local) | `ollama serve` on host. Point `base_url` to `host.container.internal:11434` | Yes |
| **LM Studio / vLLM** | Start server on host, point `base_url` accordingly | Yes |
| **Ollama Cloud** | Set `provider: ollama-cloud` in `config.yaml`, add `OLLAMA_API_KEY` to `.env` | No |
| **OpenAI / Together / Groq** | Set `provider: custom`, `base_url` to the API endpoint, `OPENAI_API_KEY` (or your provider's key env var) in `.env` | No |

### Start / stop

```bash
hermes-up       # create & start the container
hermes-down     # stop & delete the container
hermes-rebuild  # rebuild image + restart
hermes-logs     # tail container logs
```

### Use Hermes

```bash
hermes          # interactive chat (exec into container)
```

### Directory layout

```
hermes/
├── config.yaml          # Hermes CLI config (model, tools, memory)
├── .env                 # API keys and service URLs (gitignored)
├── .env.example         # Template for .env
├── Dockerfile           # Builds hermes-toolbox image
├── entrypoint.sh        # Starts SearXNG + Camofox, then idles
├── run.sh               # Lifecycle script (up/down/rebuild/status)
├── searxng/
│   └── settings.yml     # SearXNG config
├── data/
│   └── memories/        # Persistent agent memory (git-tracked)
└── workspace/           # Agent scratch files (gitignored)
```

---

## Local services

Services are defined as launchd agents in `darwin.nix` and use negligible resources when idle — GPU (Metal) is only engaged during active inference. **Ollama, Open-WebUI, and ComfyUI are currently commented out.** Uncomment the relevant blocks in `darwin.nix` and run `sudo darwin-rebuild switch --flake .` to enable them.

| Service | URL | Port | Log | Status |
|---------|-----|------|-----|--------|
| oMLX admin | http://127.0.0.1:8000/admin | 8000 | `/opt/homebrew/var/log/omlx.log` | `brew services` |
| ComfyUI | http://127.0.0.1:8188 | 8188 | `~/Library/Logs/comfyui.log` | commented out |
| Ollama API | http://127.0.0.1:11434 | 11434 | `~/Library/Logs/ollama.log` | commented out |
| Open-WebUI | http://127.0.0.1:8080 | 8080 | `~/Library/Logs/open-webui.log` | commented out |

### oMLX — bind address & API key

oMLX is installed via Homebrew (`jundot/omlx/omlx`) and run by brew's stock launchd plist (no nix-darwin patching). Configuration lives entirely in `~/.omlx/settings.json`:

- `.server.host = "0.0.0.0"` — so the Apple Container VM can reach it at `192.168.64.1:8000`
- `.auth.api_key = "omlx-sk-…"` — required for Bearer auth (also editable from the admin UI → API Keys)

`bootstrap.sh` seeds both on first run and writes the same key into `hermes/.env` as `OMLX_API_KEY`.

Verify:

```bash
KEY=$(jq -r .auth.api_key ~/.omlx/settings.json)
curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:8000/v1/models    | head
curl -s -H "Authorization: Bearer $KEY" http://192.168.64.1:8000/v1/models | head
```

Rotate the key:

```bash
NEW="omlx-sk-$(openssl rand -hex 24)"
jq --arg k "$NEW" '.auth.api_key = $k' ~/.omlx/settings.json > /tmp/s && mv /tmp/s ~/.omlx/settings.json
brew services restart jundot/omlx/omlx
sed -i.bak "s|^OMLX_API_KEY=.*|OMLX_API_KEY=$NEW|" ~/repo/mac-nix-agent/hermes/.env && rm ~/repo/mac-nix-agent/hermes/.env.bak
hermes-down && hermes-up
```

Service control:

```bash
brew services start   jundot/omlx/omlx
brew services stop    jundot/omlx/omlx
brew services restart jundot/omlx/omlx
brew services list
```

### Controlling services

```bash
# Stop a service
launchctl stop gui/$(id -u)/org.nixos.ollama

# Start a service
launchctl start gui/$(id -u)/org.nixos.ollama

# Check status
launchctl print gui/$(id -u)/org.nixos.ollama
```

Replace `ollama` with `comfyui` or `open-webui` as needed.

### Ollama — pull and run models

```bash
ollama pull llama3.2          # 3B, fastest
ollama pull qwen2.5:32b       # 32B, best quality on M5 Pro
ollama pull qwen2.5-coder     # code-focused
ollama list                   # list downloaded models
ollama rm llama3.2            # remove a model
```

### ComfyUI — data directory

Models, outputs, custom nodes: `~/Library/Application Support/comfy-ui/`

---

## First-time setup

**TL;DR:** `./bootstrap.sh` does everything. Read on if you want to know what it does, or to do steps manually.

### Automated

```bash
mkdir -p ~/repo && git clone https://github.com/<your-github-username>/mac-nix-agent.git ~/repo/mac-nix-agent
cd ~/repo/mac-nix-agent
./bootstrap.sh
```

The script is idempotent. Each step is skipped if already satisfied:

1. Sanity checks (macOS 26+ Apple silicon)
2. Personalize `flake.nix` (username + hostname from your machine)
3. Prompt for git `user.name` / `user.email` if `~/.gitconfig` doesn't have them yet
4. Install Determinate Nix
5. Install Homebrew
6. `sudo darwin-rebuild switch --flake .`
7. Install or upgrade Apple `container` runtime (latest release from GitHub)
8. Seed `~/.omlx/settings.json` with `host=0.0.0.0` + generated API key
9. Create `hermes/.env` from `.env.example` and sync `OMLX_API_KEY`
10. `hermes/run.sh rebuild`

### Manual (if you prefer step-by-step)

#### 1. Install Nix

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```

Restart your terminal after installation.

#### 2. Clone this repo

```bash
mkdir -p ~/repo
git clone https://github.com/<your-github-username>/mac-nix-agent.git ~/repo/mac-nix-agent
cd ~/repo/mac-nix-agent
```

#### 3. Personalize `flake.nix` (auto-done by bootstrap.sh)

`flake.nix` declares your macOS user and hostname so nix-darwin knows which configuration to apply. `bootstrap.sh` sets these from `id -un` and `scutil --get LocalHostName` automatically. To do it manually, edit the `let` block at the top of `flake.nix`:

```nix
username = "your-username";   # e.g. "alice"
hostname = "your-hostname";   # e.g. "alice-mbp"
```

Then ensure your Mac's `LocalHostName` matches:

```bash
scutil --get LocalHostName
sudo scutil --set LocalHostName your-hostname   # only if different
```

#### 4. Install Homebrew

nix-darwin manages Homebrew declaratively but does not install it — do that once manually:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

#### 5. Build and activate

On a fresh Mac, `darwin-rebuild` isn't in your PATH yet. Bootstrap with:

```bash
sudo nix run nix-darwin#darwin-rebuild -- switch --flake .
```

After this first run, use:

```bash
sudo darwin-rebuild switch --flake .
```

#### 6. Generate Open-WebUI secret key

Open-WebUI needs a secret key file (not stored in git):

```bash
mkdir -p ~/.config/open-webui
openssl rand -hex 32 > ~/.config/open-webui/secret_key
chmod 600 ~/.config/open-webui/secret_key
```

#### 7. Manual steps (one-time)

**Terminal.app theme:**
1. Double-click `materialshell-dark.terminal` to import
2. Set as default in Terminal → Settings → Profiles
3. Set font to `FiraCode Nerd Font Mono` size 12

**VS Code:**
1. Sign in with GitHub → extensions sync automatically
2. `Cmd+Shift+P` → "Shell Command: Install 'code' command in PATH"

**Apple `container` (microVM runtime):**

Apple's `container` tool is not distributed via Homebrew — install the signed `.pkg` manually:

1. Download the latest installer from [github.com/apple/container/releases](https://github.com/apple/container/releases)
2. Double-click the `.pkg` and follow the prompts (requires macOS 26+ on Apple silicon)
3. Start the system service:
   ```bash
   container system start
   ```

To upgrade later:

```bash
/usr/local/bin/update-container.sh
```

To uninstall (keep user data with `-k`, remove with `-d`):

```bash
/usr/local/bin/uninstall-container.sh -k
```

---

## Day-to-day usage

### Adding a CLI tool

Edit `home.nix`, add to `home.packages`:

```nix
home.packages = with pkgs; [
  htop  # ← new
];
```

### Adding a GUI app (cask)

Enable Homebrew in `darwin.nix` and add to `homebrew.casks`:

```nix
homebrew.enable = true;
homebrew.casks = [ "firefox" ];
```

### Apply changes

```bash
sudo darwin-rebuild switch --flake ~/repo/mac-nix-agent
```

### Update all packages

```bash
cd ~/repo/mac-nix-agent
sudo nix flake update
sudo darwin-rebuild switch --flake .
```

---

## Troubleshooting

### `git config --global` fails with "Permission denied"

Home Manager (`programs.git.enable = true` in [home.nix](home.nix)) symlinks `~/.config/git/config` to the read-only nix store. Plain `git config --global …` tries to write that file and fails with `EACCES`.

Fix: write to `~/.gitconfig` instead (git reads both and merges them):

```bash
GIT_CONFIG_GLOBAL=~/.gitconfig git config --global user.name  "Your Name"
GIT_CONFIG_GLOBAL=~/.gitconfig git config --global user.email "you@example.com"
```

`bootstrap.sh` does this automatically. We deliberately don't put identity into `home.nix` itself, so personal info doesn't leak back into the public flake.

---

## Backup & restore

All Hermes state that can't be regenerated lives inside `hermes/`. Everything else is in this repo (git) or in Homebrew/Nix (re-installable). To survive a Mac reset:

**Back up:**

```bash
cd ~/repo/mac-nix-agent
tar czf ~/hermes-backup-$(date +%Y%m%d).tgz \
    hermes/.env \
    hermes/data \
    hermes/workspace \
    hermes/config.yaml.custom 2>/dev/null || true
```

Stash the tarball somewhere durable (iCloud Drive, external disk, encrypted USB — it contains your API key, so treat it like a secret).

**Restore on a fresh Mac:**

```bash
mkdir -p ~/repo
git clone https://github.com/<your-github-username>/mac-nix-agent.git ~/repo/mac-nix-agent
cd ~/repo/mac-nix-agent
tar xzf ~/hermes-backup-YYYYMMDD.tgz   # restores hermes/.env + data + workspace
./bootstrap.sh
```

`bootstrap.sh` will overwrite `OMLX_API_KEY` in the restored `.env` with the new machine's oMLX key (the old one is dead anyway), but your `hermes/data/memories/*` and `hermes/workspace/` files come through verbatim — they're in the tarball, not the public repo.

If you only care about the agent's "identity" (memories) and don't mind reconfiguring everything else, the minimum backup is just `hermes/data/memories/`.

---

## Pushing to GitHub

```bash
cd ~/repo/mac-nix-agent
git add .
git commit -m "initial: declarative macOS environment"
git remote add origin git@github.com:<your-username>/mac-nix-agent.git
git push -u origin main
```
