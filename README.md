# mac-nix-agent

**One-command Apple-silicon dev box for running a local AI coding agent.**

This repo is a declarative, end-to-end recipe for turning a fresh M-series Mac into a self-contained AI workstation:

- **Nix + nix-darwin + Home Manager** — reproducible system + user environment (CLI tools, fonts, shell, launchd services)
- **Homebrew** — declarative casks (VS Code, Ollama, LM Studio, oMLX, etc.) managed by nix-darwin
- **[oMLX](https://github.com/jundot/omlx)** — multi-model MLX inference server, OpenAI-compatible API on `localhost:8000`
- **[Hermes Agent](https://github.com/NousResearch/hermes-agent)** in an Apple `container` microVM — chat-driven coding agent with built-in SearXNG, browser, and shell tools, talking to oMLX over the vmnet bridge

The goal: clone the repo, run `./bin/mna-bootstrap`, and have a working `mna-hermes` chat against a locally hosted MLX model on the same Mac. Everything is reproducible — wipe the machine, re-run the script, get the same setup. No cloud dependency by default; cloud LLMs are a one-line config swap.

> **Philosophy.** This repo is meant to **accelerate your learning** of the Apple-silicon AI toolchain, not hide it from you. Lifecycle plumbing (`mna-hermes up`, `darwin-rebuild switch`) is wrapped because it's plumbing. Workflow commands you should understand — model downloads, format conversion, abliteration, quantization — are **deliberately not wrapped**. See [`modelops/`](modelops/README.md) for the modelops tutorial.

## Quick start

Fresh Mac? One command:

```bash
mkdir -p ~/repo && git clone https://github.com/<your-github-username>/mac-nix-agent.git ~/repo/mac-nix-agent
cd ~/repo/mac-nix-agent && ./bin/mna-bootstrap
```

`mna-bootstrap` is idempotent — safe to re-run. It installs Nix, Homebrew, the Apple `container` runtime, applies the nix-darwin flake, seeds oMLX (host + API key), and brings up the Hermes container.

> **Clone it to `~/repo/mac-nix-agent`.** [home.nix](home.nix) hard-codes `~/repo/mac-nix-agent/bin` onto your PATH — deliberately, with no path-detection wrapper, so the code stays easy to read. The first run always works from anywhere (you invoke it by path: `./bin/mna-bootstrap`). But for the bare `mna-*` commands to resolve afterward, keep the repo here — or change that single PATH line in `home.nix` if you clone elsewhere.
>
> **After the first bootstrap, open a new terminal** (or run `exec zsh`). `mna-bootstrap` runs as a child process, so it can't add `bin/` to the PATH of the shell you launched it from — that only takes effect in shells started after the rebuild. In the same terminal, keep using `./bin/mna-*` until you open a fresh one.

> **Repo commands.** Operations live in [`bin/`](bin/) as `mna-*` commands — the `mna-` prefix keeps them distinct from system tools and tab-completable as a group (`mna-<TAB>`). `home.nix` puts `bin/` on your PATH, so after the first rebuild — in any newly-opened shell — they're callable from anywhere:
>
> | Command | What |
> |---------|------|
> | `mna-bootstrap` | First-time setup (idempotent). On a fresh Mac run `./bin/mna-bootstrap` (PATH isn't wired yet). |
> | `mna-update` | Bump flake inputs + upgrade Homebrew **verbosely** + `darwin-rebuild` + restart oMLX. |
> | `mna-doctor [--fix]` | Diagnose the oMLX stack (stale launchd agent, port 8000 conflict, service/API health). `--fix` repairs. |
> | `mna-omlx <cmd>` | oMLX service control: `status`/`start`/`stop`/`restart`/`logs`/`models`/`upgrade`/`key`. |
> | `mna-hermes [cmd]` | Hermes control: bare = `chat`; also `up`/`down`/`rebuild`/`status`/`logs`. |
> | `mna-uninstall <c>` | Factory-reset one imperative component (`omlx`/`hermes`/`container`). Data-safe by default; `--purge` removes data, `--keep-models`/`--keep-config` spare parts of it. Never edits the Nix files. |

> **Note:** `mna-bootstrap` writes a gitignored `local.nix` with your `username` and `hostname` (read by `flake.nix`). The tracked `flake.nix` stays on placeholders, so upstream pulls don't conflict. `mna-bootstrap` also `git add --intent-to-add`s `local.nix` (so it shows as `A` in `git status`, never committed unless you explicitly `git commit local.nix`) — this is required because `darwin-rebuild --flake <repo>` evaluates the flake from the **git tree**, which excludes gitignored files. Without staging it, the flake would expose only the placeholder host and fail with `does not provide attribute '…darwinConfigurations.<host>.system'`. Delete `local.nix` and run `git reset local.nix` to revert to defaults.

Already bootstrapped? Day-to-day commands:

```bash
cd ~/repo/mac-nix-agent
mna-update                             # flake update + verbose brew upgrade + rebuild + restart oMLX
mna-doctor                             # health-check the oMLX stack (add --fix to repair)
mna-hermes up                          # start Hermes agent container
mna-hermes                             # interactive chat (bare = chat)
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
│        │                            │   └─ entrypoint.sh │
│        │                            └─ modelops/         │
│  ┌─────┼──── Apple Container VM ────────────────────┐    │
│  │     │     hermes-agent                           │    │
│  │     │     4 CPU · 8 GB RAM    ◀── mounts         │    │
│  │  ┌──┴──────────┐                                 │    │
│  │  │ Hermes CLI  │ ◀── config.yaml                 │    │
│  │  │             │ ◀── .env                        │    │
│  │  └──┬──────────┘                                 │    │
│  │     │ tool calls                                 │    │
│  │     ├──▶ SearXNG    (:8080)                      │    │
│  │     ├──▶ Camofox    (:9377)                      │    │
│  │     ├──▶ Terminal   (local bash)                 │    │
│  │     └──▶ Dashboard  (:9119)                      │    │
│  │                                                  │    │
│  │  /opt/data/memories  ◀── hermes/data/memories/   │    │
│  │  /opt/data/workspace ◀── hermes/workspace/       │    │
│  └──────────────────────────────────────────────────┘    │
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
- **One-command lifecycle** — `mna-hermes up` / `down` / `rebuild` manage everything; bare `mna-hermes` opens a chat.

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
mna-hermes up        # create & start the container (with SearXNG built in)
mna-hermes down      # stop the container
mna-hermes rebuild   # rebuild image + restart
mna-hermes logs      # tail container logs
```

### Use Hermes

```bash
mna-hermes           # interactive chat (bare = chat; same as `mna-hermes chat`)
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

`mna-bootstrap` seeds both on first run and writes the same key into `hermes/.env` as `OMLX_API_KEY`.

#### Untrusted tap

Homebrew 5.x refuses to load formulae from third-party taps until you explicitly **trust** them. Because nix-darwin runs `brew bundle` non-interactively during activation, an untrusted `jundot/omlx` tap aborts `darwin-rebuild` with:

```
Error: Refusing to load formula jundot/omlx/omlx from untrusted tap jundot/omlx.
```

`mna-bootstrap` taps and trusts it automatically (before the `darwin-rebuild` step). If you hit this on an existing machine, trust it once and re-run:

```bash
eval "$(/opt/homebrew/bin/brew shellenv)"   # if `brew` isn't on PATH yet
brew trust jundot/omlx
sudo darwin-rebuild switch --flake .
```

> nix-darwin's `homebrew` module has no declarative `trust` option yet, so this lives in `mna-bootstrap` rather than `darwin.nix`. A future nix-darwin release exposing Homebrew's `trusted: true` Brewfile attribute would let us drop the manual step.

### Download your first model

`mna-bootstrap` leaves oMLX running but **with no model loaded** — the repo doesn't ship weights. Pull one from the admin UI:

1. Open <http://127.0.0.1:8000/admin> and log in with the key from `~/.omlx/settings.json` (`jq -r .auth.api_key ~/.omlx/settings.json`).
2. Go to **Models → Download** and paste a Hugging Face repo ID. Pick a Gemma 4 MLX `mxfp8` build that fits your Mac's unified memory — leave at least ~8 GB headroom for the OS, KV cache at 32k, and any other apps:

   | Hugging Face repo | Type | ~Disk | Min RAM | Comfortable on |
   |---|---|---:|---:|---:|
   | [`mlx-community/gemma-4-e2b-it-mxfp8`](https://huggingface.co/mlx-community/gemma-4-e2b-it-mxfp8) | dense (2B-effective) | ~5 GB | 8 GB | 16 GB |
   | [`mlx-community/gemma-4-e4b-it-mxfp8`](https://huggingface.co/mlx-community/gemma-4-e4b-it-mxfp8) | dense (4B-effective) | ~7 GB | 16 GB | 24 GB+ |
   | [`mlx-community/gemma-4-26b-a4b-it-mxfp8`](https://huggingface.co/mlx-community/gemma-4-26b-a4b-it-mxfp8) | MoE (26B total / 4B active) | ~28 GB | 36 GB | 48 GB+ |
   | [`mlx-community/gemma-4-31b-it-mxfp8`](https://huggingface.co/mlx-community/gemma-4-31b-it-mxfp8) | dense | ~33 GB | 48 GB | 64 GB+ |

   **Picking by Mac RAM** (assumes the model is the only large workload — close LM Studio, ComfyUI, large IDE projects, etc.):

   - **8 GB:** `gemma-4-e2b-it-mxfp8` only. Drop `context_length` to 8192–16384 in `hermes/config.yaml` and the matching `max_context_window` in oMLX (see below) if you hit OOM.
   - **16 GB:** `gemma-4-e4b-it-mxfp8` is the sweet spot; `e2b` for snappier responses.
   - **24–32 GB:** `gemma-4-e4b-it-mxfp8` reliably; `gemma-4-26b-a4b-it-mxfp8` works but expect swapping under long contexts — keep the window at 32k or lower and close other heavy apps.
   - **36–48 GB:** `gemma-4-26b-a4b-it-mxfp8` is the default pick. MoE keeps active compute small while quality stays near 31B-dense.
   - **64 GB+:** Any of them. `gemma-4-31b-it-mxfp8` for strongest single-pass quality; `gemma-4-26b-a4b-it-mxfp8` for faster throughput.

   The pre-configured default in [`hermes/config.yaml`](hermes/config.yaml) is `mlx-community/gemma-4-26b-a4b-it-mxfp8`. Edit it if you pick a different variant.

3. Hit **Download** and wait. Progress is visible in the UI; files land under `~/.omlx/models/`.
4. Click **Load** on the new model. Verify it's serving:

   ```bash
   KEY=$(jq -r .auth.api_key ~/.omlx/settings.json)
   curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:8000/v1/models | jq '.data[].id'
   ```

5. If the returned ID doesn't match `model.default` in [`hermes/config.yaml`](hermes/config.yaml), update it, then `mna-hermes rebuild`.
6. Optionally tweak that model's `max_context_window` — see [oMLX — context window](#omlx--context-window) below. Smaller-RAM Macs should also lower `model.context_length` to match.

Once a model is loaded and `hermes/config.yaml` points at it, `mna-hermes` chats work end-to-end.

### oMLX — context window

`hermes/config.yaml`'s `model.context_length` (32768) caps what Hermes sends to oMLX. On the oMLX side, the effective ceiling is the **per-model** `max_context_window` in `~/.omlx/model_settings.json`, falling back to the **global** `.sampling.max_context_window` in `~/.omlx/settings.json`. `mna-bootstrap` pins the global fallback to 32768 so any freshly downloaded model works out of the box at 32k.

Per-model overrides are **your call** — there's no `omlx` CLI for this, and the repo deliberately doesn't pre-pin settings for models it doesn't ship. To override:

- **Recommended:** Admin UI → Models → `<model>` → Settings → set `max_context_window` (and `max_tokens`).
- **Programmatic** (admin endpoints use a session cookie, not Bearer auth):

  ```bash
  KEY=$(jq -r .auth.api_key ~/.omlx/settings.json)
  JAR=$(mktemp)
  curl -s -c "$JAR" -X POST "http://127.0.0.1:8000/admin/api/login" \
    -H "Content-Type: application/json" -d "{\"api_key\":\"$KEY\"}" >/dev/null
  curl -sX PUT -b "$JAR" "http://127.0.0.1:8000/admin/api/models/<model-id>/settings" \
    -H "Content-Type: application/json" \
    -d '{"max_context_window": 32768, "max_tokens": 8192}' | jq
  rm -f "$JAR"
  ```

When raising the window above 32k, also bump `model.context_length` in [`hermes/config.yaml`](hermes/config.yaml) to match (it must stay ≤ the oMLX value).

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
mna-hermes down && mna-hermes up
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

**TL;DR:** `./bin/mna-bootstrap` does everything. Read on if you want to know what it does, or to do steps manually.

### Automated

```bash
mkdir -p ~/repo && git clone https://github.com/<your-github-username>/mac-nix-agent.git ~/repo/mac-nix-agent
cd ~/repo/mac-nix-agent
./bin/mna-bootstrap
```

The script is idempotent. Each step is skipped if already satisfied:

1. Sanity checks (macOS 26+ Apple silicon)
2. Write `local.nix` (username + hostname from your machine)
3. Prompt for git `user.name` / `user.email` if `~/.gitconfig` doesn't have them yet
4. Install Determinate Nix
5. Install Homebrew
6. Tap and trust `jundot/omlx` (so `brew bundle` can load the oMLX formula)
7. `sudo darwin-rebuild switch --flake .`
8. Install or upgrade Apple `container` runtime (latest release from GitHub)
9. Seed `~/.omlx/settings.json` with `host=0.0.0.0`, generated API key, and `sampling.max_context_window=32768`
10. Create `hermes/.env` from `.env.example` and sync `OMLX_API_KEY`
11. `hermes/run.sh rebuild`

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

#### 3. Write `local.nix` (auto-done by mna-bootstrap)

`flake.nix` reads per-machine identity from a gitignored `./local.nix`. `mna-bootstrap` generates it from `id -un` and `scutil --get LocalHostName`. To do it manually, create `local.nix` at the repo root:

```nix
{
  username = "your-username";   # e.g. "alice"
  hostname = "your-hostname";   # e.g. "alice-mbp"
}
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

Then trust the third-party oMLX tap, or the `brew bundle` run inside `darwin-rebuild` (next step) will abort with `Refusing to load formula … from untrusted tap`:

```bash
eval "$(/opt/homebrew/bin/brew shellenv)"   # if `brew` isn't on PATH yet
brew tap jundot/omlx https://github.com/jundot/omlx
brew trust jundot/omlx
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

> Or, from the repo: `mna-uninstall container` (wraps the script above with `-k`; `--purge` passes `-d`).

---

## Starting over (uninstall / reinstall a component)

`mna-uninstall <component>` factory-resets one **imperative** piece of the stack without touching the Nix files — so the declarative layer stays idempotent and re-running `mna-bootstrap` (or `darwin-rebuild`) cleanly reinstalls. Use it to "start over" on a single component:

```bash
mna-uninstall omlx        # remove oMLX, keep ~/.omlx (models + settings) intact
mna-bootstrap             # Nix reinstalls the formula; step 8 reseeds settings.json
```

| Component | Default (data-safe) | `--purge` adds | Reinstall |
|-----------|---------------------|----------------|-----------|
| `omlx` | stop + `brew uninstall`; keep `~/.omlx/` | `rm -rf ~/.omlx` | `mna-bootstrap` |
| `hermes` | stop + delete container + remove image; keep `hermes-data` volume & host files | delete `hermes-data` volume | `mna-hermes rebuild` |
| `container` | `uninstall-container.sh -k` (keep data) | `… -d` (delete data) | `mna-bootstrap` |

**Sparing data on `--purge` (oMLX only):**

```bash
mna-uninstall omlx --purge                          # wipe ~/.omlx entirely
mna-uninstall omlx --purge --keep-models            # spare ~/.omlx/models/ (the weights)
mna-uninstall omlx --purge --keep-config            # spare settings.json + model_settings.json
mna-uninstall omlx --purge --keep-models --keep-config   # spare both
```

Other flags: `--yes` (skip the confirmation prompt), `--dry-run` (print what would happen, change nothing).

> **Hermes host files are never deleted** — `hermes/.env`, `hermes/data/memories/`, and `hermes/workspace/` survive every `mna-uninstall hermes`, even with `--purge` (only the container's named volume is removed). Those are your backed-up state (see [Backup & restore](#backup--restore)).
>
> **Nix-managed things** (CLI packages, casks, fonts) are not handled by `mna-uninstall` — remove those by editing `home.nix` / `darwin.nix` and running `mna-update`.

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
mna-update                 # flake update + verbose brew upgrade + darwin-rebuild + restart oMLX
```

`mna-update` runs `brew upgrade` with `--verbose` **before** `darwin-rebuild`, so the long, silent Homebrew step inside activation (which can look like a hang on a big bottle such as oMLX) has nothing left to do quietly. To do it by hand instead:

```bash
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

`mna-bootstrap` does this automatically. We deliberately don't put identity into `home.nix` itself, so personal info doesn't leak back into the public flake.

---

### oMLX won't start / `darwin-rebuild` seems to hang

Two distinct symptoms, both handled by the repo commands:

- **`darwin-rebuild` looks frozen with no output.** It isn't — `homebrew.onActivation.upgrade = true` runs `brew upgrade` silently during activation, and a big bottle (oMLX is a ~1.6 GB / 35k-file Python venv) can take several minutes with zero progress. Use `mna-update` instead; it upgrades Homebrew **verbosely first** so you see progress.
- **oMLX service stuck in `error`, log shows `[Errno 48] Address already in use`.** Usually a stale `org.nixos.omlx` launchd agent (from an older `darwin.nix` that ran oMLX as a Nix service) is squatting port 8000 with `KeepAlive`, so the Homebrew service can never bind. Diagnose and repair:

  ```bash
  mna-doctor          # report what's wrong
  mna-doctor --fix    # boot out the stale agent, kill orphans, restart the service
  mna-omlx status     # confirm: version, service started, port bound, HTTP 200
  ```

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
./bin/mna-bootstrap
```

`mna-bootstrap` will overwrite `OMLX_API_KEY` in the restored `.env` with the new machine's oMLX key (the old one is dead anyway), but your `hermes/data/memories/*` and `hermes/workspace/` files come through verbatim — they're in the tarball, not the public repo.

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
