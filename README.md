# mac-nix-agent

**One-command Apple-silicon dev box for running a local AI coding agent.**

This repo is a declarative, end-to-end recipe for turning a fresh M-series Mac into a self-contained AI workstation:

- **Nix + nix-darwin + Home Manager** — reproducible system + user environment (CLI tools, fonts, shell, launchd services)
- **Homebrew** — declarative casks (VS Code, Ollama, LM Studio, etc.) managed by nix-darwin
- **[oMLX](https://github.com/jundot/omlx)** — official prebuilt macOS app, with a multi-model MLX inference server and OpenAI-compatible API on `localhost:8000`
- **[Hermes Agent](https://github.com/NousResearch/hermes-agent)** in an Apple `container` microVM — chat-driven coding agent with built-in SearXNG, browser, and shell tools, talking to oMLX over the vmnet bridge

The goal: clone the repo, run `./bin/mna-bootstrap`, and have a working `mna-hermes` chat against a locally hosted MLX model on the same Mac. Everything is reproducible — wipe the machine, re-run the script, get the same setup. No cloud dependency by default; cloud LLMs are a one-line config swap.

> **Philosophy.** This repo is meant to **accelerate your learning** of the Apple-silicon AI toolchain, not hide it from you. Lifecycle plumbing (`mna-hermes up`, `darwin-rebuild switch`) is wrapped because it's plumbing. Workflow commands you should understand — model downloads, format conversion, abliteration, quantization — are **deliberately not wrapped**. See [`modelops/`](modelops/README.md) for the modelops tutorial.

> **⚠️ Read first — what this is, and what it isn't.** This repo runs Hermes — an autonomous, web-connected, self-modifying agent — **inside an Apple `container` microVM on purpose**. The sandbox *is* the product: the agent gets a few explicit bind mounts and **cannot** see your real `~`, your SSH/cloud keys, your OneDrive/iCloud, or your authenticated browser — so you can let it off the leash and reset it with `mna-hermes rebuild`. The trade-off: it can't touch your real projects or drive your desktop. If you instead want an assistant that operates your actual machine and corporate apps, that's **host-native Hermes** — a deliberately different, higher-trust tool, not this repo. The new **Hermes Desktop app is just a GUI front-end and changes neither posture** (attach it to the container and the jail stays intact). Before adopting — especially the limits (open network egress, `.env` is readable by the agent, young VM runtime) and the "don't drift into host-native by accident" discipline — read **[docs/security-model.md](docs/security-model.md)**.

## Quick start

Fresh Mac? One bootstrap command after cloning:

```bash
mkdir -p ~/repo && git clone https://github.com/poomnupong/mac-nix-agent.git ~/repo/mac-nix-agent
cd ~/repo/mac-nix-agent && ./bin/mna-bootstrap
```

`mna-bootstrap` is idempotent — safe to re-run. It installs Nix, Homebrew, the Apple `container` runtime, and the latest stable official oMLX app, applies the nix-darwin flake, seeds oMLX (host + API key), and brings up the Hermes container.

> **Clone it to `~/repo/mac-nix-agent`.** [home.nix](home.nix) hard-codes `~/repo/mac-nix-agent/bin` onto your PATH — deliberately, with no path-detection wrapper, so the code stays easy to read. The first run always works from anywhere (you invoke it by path: `./bin/mna-bootstrap`). But for the bare `mna-*` commands to resolve afterward, keep the repo here — or change that single PATH line in `home.nix` if you clone elsewhere.
>
> **After the first bootstrap, open a new terminal** (or run `exec zsh`). `mna-bootstrap` runs as a child process, so it can't add `bin/` to the PATH of the shell you launched it from — that only takes effect in shells started after the rebuild. In the same terminal, keep using `./bin/mna-*` until you open a fresh one.

> **Repo commands.** Operations live in [`bin/`](bin/) as `mna-*` commands — the `mna-` prefix keeps them distinct from system tools and tab-completable as a group (`mna-<TAB>`). `home.nix` puts `bin/` on your PATH, so after the first rebuild — in any newly-opened shell — they're callable from anywhere:
>
> | Command | What |
> |---------|------|
> | `mna [help]` | Show all available commands. Use `mna help <command>` for detailed help, or `mna <command> ...` as a shorter form of `mna-<command> ...`. |
> | `mna-bootstrap` | First-time setup (idempotent). On a fresh Mac run `./bin/mna-bootstrap` (PATH isn't wired yet). |
> | `mna-rebuild` | Apply local Nix configuration changes without updating dependencies. |
> | `mna-update` | Bump flake inputs + upgrade Homebrew **verbosely** + `darwin-rebuild` + update/restart the stable oMLX app. |
> | `mna-doctor [--fix]` | Diagnose the oMLX stack (stale launchd agent, port 8000 conflict, service/API health). `--fix` repairs. |
> | `mna-omlx <cmd>` | oMLX app install/control: `status`/`install`/`upgrade`/`start`/`stop`/`restart`/`logs`/`models`/`key`. |
> | `mna-hermes [cmd]` | Hermes control: bare = `chat`; also `up`/`down`/`rebuild`/`status`/`dashboard`/`logs`. |
> | `mna-uninstall <c>` | Factory-reset one imperative component (`omlx`/`hermes`/`container`). Data-safe by default; `--purge` removes data, `--keep-models`/`--keep-config` spare parts of it. Never edits the Nix files. |

> **Note:** `mna-bootstrap` writes a gitignored `local.nix` with your `username` and `hostname`. Lifecycle commands build a temporary Nix source from tracked files plus `local.nix`, so normal `git status` stays clean and ignored secrets/runtime data stay out of the Nix store.

Bootstrap creates local state without staging it:

| Local artifact | Purpose | Recreated when missing? | Preserved by updates/rebuilds? |
|---|---|:---:|:---:|
| `local.nix` | This Mac's username and hostname | By `mna-bootstrap` | Yes |
| `hermes/.env` | API keys and dashboard credentials (`0600`) | By `mna-bootstrap` | Yes |
| `hermes/config.yaml` | Live Hermes settings, seeded from the tracked example | By `mna-hermes up` | Yes |
| `hermes/data/` | Memories and host-backed agent state | By `mna-hermes up` | Yes |
| `hermes/workspace/` | Files exchanged with the agent | By `mna-hermes up` | Yes |
| `hermes-data` volume | Sessions, plugins, cron state, caches, and container-side state | By `mna-hermes up` | Yes; deleted only by `mna-uninstall hermes --purge` |
| `~/.omlx/settings.json` | oMLX server settings and API key (`0600`) | By `mna-bootstrap`/oMLX | Yes |
| `~/.omlx/models/` | Downloaded model weights | By the user/oMLX | Yes |

The repository does not ship model weights. Bootstrap starts the oMLX admin UI and Hermes dashboard; on a new Mac, the remaining user action is choosing a model that fits the machine and downloading it from <http://127.0.0.1:8000/admin>.

Already bootstrapped? Day-to-day commands:

```bash
cd ~/repo/mac-nix-agent
mna help                               # discover commands and detailed help
mna-rebuild                            # apply edits to tracked Nix files
mna-update                             # flake/brew update + rebuild + stable oMLX app update
mna-doctor                             # health-check the oMLX stack (add --fix to repair)
mna-hermes up                          # start Hermes agent container
mna-hermes                             # interactive chat (bare = chat)
```

## Table of Contents

- [Read first — what this is, and what it isn't](docs/security-model.md)
- [Quick start](#quick-start)
- [What this manages](#what-this-manages)
- [Hermes Agent (containerized)](#hermes-agent-containerized)
  - [Architecture](#architecture)
  - [Features](#features)
  - [LLM providers](#llm-providers)
  - [Browser GUI (built-in dashboard)](#browser-gui-built-in-dashboard)
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
- **Flexible LLM backend** — works with local inference (oMLX, Ollama, LM Studio, vLLM) or cloud APIs (Ollama Cloud, OpenAI, Together, Groq). Edit the gitignored live `config.yaml` and `.env`; defaults live in `config.yaml.example` and `.env.example`.
- **Private memory** — `hermes/data/memories/` is **gitignored**: the agent learns about you locally and that knowledge never leaks to a (potentially public) repo. Back it up out-of-band (see [Backup & restore](#backup--restore)).
- **Self-sufficient toolbox** — Node.js, npm, pip available inside the container. Hermes can install its own packages at runtime.
- **Host-mounted config** — the live `config.yaml`, `.env`, `Dockerfile`, and `entrypoint.sh` are bind-mounted, so changes apply without rebuilding the image. Hermes may rewrite `config.yaml`, so it is local runtime state rather than tracked source.
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
| **oMLX** (default) | `mna-bootstrap` installs the official app; it runs on `:8000`. Set `base_url` in `config.yaml` | Yes (Metal) |
| **Ollama** (local) | `ollama serve` on host. Point `base_url` to `host.container.internal:11434` | Yes |
| **LM Studio / vLLM** | Start server on host, point `base_url` accordingly | Yes |
| **Ollama Cloud** | Set `provider: ollama-cloud` in `config.yaml`, add `OLLAMA_API_KEY` to `.env` | No |
| **OpenAI / Together / Groq** | Set `provider: custom`, `base_url` to the API endpoint, `OPENAI_API_KEY` (or your provider's key env var) in `.env` | No |

### Start / stop

```bash
mna-hermes up         # create & start the container (with SearXNG built in)
mna-hermes down       # stop the container
mna-hermes rebuild    # rebuild image + restart
mna-hermes dashboard  # open the browser GUI (http://localhost:9119)
mna-hermes logs       # tail container logs
```

### Use Hermes

```bash
mna-hermes           # interactive chat (bare = chat; same as `mna-hermes chat`)
```

### Browser GUI (built-in dashboard)

Prefer a visual interface to the terminal? The container also runs Hermes' **web dashboard** — open it with:

```bash
mna-hermes dashboard            # ensures the container is up, then opens the browser
```

It serves the **same containerized agent** as `mna-hermes` chat ([docs](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard)), so sessions, memory, and skills are shared. Over the terminal it adds:

- **Embedded chat tab** — the full Hermes TUI in the browser (slash commands, model picker, tool-call cards, streaming).
- **Form editors** for `config.yaml` (150+ fields) and `.env` API keys — no hand-editing YAML.
- **Sessions browser** with full-text search and export; **Skills**, **MCP**, **Analytics**, **Cron**, and **Logs** panes.

It runs **entirely inside the microVM** (published only to `127.0.0.1:9119`) and **installs nothing on your Mac** — the agent stays jailed; your browser just talks to the loopback port. Binding inside the VM engages Hermes' auth gate, so `mna-bootstrap` seeds a readable username/password into `hermes/.env`:

- `mna-hermes dashboard` prints the current login each time.
- **Change it:** edit `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` in `hermes/.env`, then `mna-hermes rebuild`. Keep `HERMES_DASHBOARD_BASIC_AUTH_SECRET` stable so logins survive restarts.

> **Native Hermes Desktop app?** This repo deliberately **doesn't install it** — the native app lays down a host-side `~/.hermes` agent runtime, which is exactly the host-native footprint the container model avoids ([why](docs/security-model.md#hermes-desktop-app-released-2026--does-it-change-any-of-this)). The built-in browser dashboard above already covers the GUI use case with zero host install. If you still want the native app, install it yourself ([Hermes Desktop](https://hermes-agent.nousresearch.com/desktop)) and point it at **this container's backend** instead of its own: **Settings → Gateway → Remote gateway**, Remote URL `http://127.0.0.1:9119`, then sign in with the username/password from `hermes/.env`. That keeps the agent jailed in the VM and the desktop app a pure front-end.

### Directory layout

```
hermes/
├── config.yaml          # Live Hermes config (gitignored)
├── config.yaml.example  # Tracked defaults; seeds config.yaml on first start
├── .env                 # API keys, dashboard login, service URLs (gitignored)
├── .env.example         # Template for .env
├── Dockerfile           # Builds hermes-toolbox image
├── entrypoint.sh        # Starts SearXNG + Camofox + dashboard, then idles
├── run.sh               # Lifecycle script (up/down/rebuild/status)
├── searxng/
│   └── settings.yml     # SearXNG config
├── data/
│   └── memories/        # Persistent agent memory (gitignored)
└── workspace/           # Agent scratch files (gitignored)
```

---

## Local services

Local inference services use negligible resources when idle — GPU (Metal) is only engaged during active inference. oMLX is owned by its official macOS app; optional Nix launchd services remain defined in `darwin.nix`. **Ollama, Open-WebUI, and ComfyUI are currently commented out.** Uncomment the relevant blocks in `darwin.nix` and run `mna-rebuild` to enable them.

| Service | URL | Port | Log | Status |
|---------|-----|------|-----|--------|
| oMLX admin | http://127.0.0.1:8000/admin | 8000 | `~/Library/Application Support/oMLX/logs/server.log` | `mna-omlx status` |
| ComfyUI | http://127.0.0.1:8188 | 8188 | `~/Library/Logs/comfyui.log` | commented out |
| Ollama API | http://127.0.0.1:11434 | 11434 | `~/Library/Logs/ollama.log` | commented out |
| Open-WebUI | http://127.0.0.1:8080 | 8080 | `~/Library/Logs/open-webui.log` | commented out |

### oMLX — bind address & API key

oMLX is installed from the upstream stable, notarized DMG. The app embeds Python, MLX, and the native kernels, so installation and updates do not build from source or download dependencies from PyPI. The app owns the server lifecycle and installs a CLI shim at `~/.omlx/bin/omlx`. Configuration lives entirely in `~/.omlx/settings.json`:

- `.server.host = "0.0.0.0"` — so the Apple Container VM can reach it at `192.168.64.1:8000`
- `.auth.api_key = "omlx-sk-…"` — required for Bearer auth (also editable from the admin UI → API Keys)

`mna-bootstrap` seeds both on first run and writes the same key into `hermes/.env` as `OMLX_API_KEY`.

#### Binary installation and stable updates

`mna-omlx install` and `mna-omlx upgrade` use the same idempotent flow:

1. Query the upstream GitHub releases API and reject drafts, prereleases, and version tags containing `rc`, `dev`, `alpha`, or `beta`. If the API is unavailable or rate-limited, use the public releases feed as the stable-version fallback.
2. Select the official DMG whose filename supports the current macOS major version. No Python package, compiler, Homebrew formula, or PyPI download is involved.
3. Read the installed version from `/Applications/oMLX.app/Contents/Info.plist`. If it matches the newest stable version, skip the download and installation.
4. Otherwise download the DMG to a temporary directory, mount it read-only, stage `oMLX.app`, verify the full code signature with `codesign`, and require a successful Gatekeeper assessment from `spctl` before replacing anything.
5. Stop the old app-managed server, replace `/Applications/oMLX.app` through a staging path, and remove the superseded Homebrew formula if it is still present.
6. Leave `~/.omlx` untouched, preserving downloaded models, server settings, model settings, and the API key. Bootstrap then reconciles the bind address and shared Hermes API key and restarts the app-managed server.

Run `mna-omlx upgrade` to check only oMLX. Run `mna-update` to update Homebrew and Nix first, activate nix-darwin, check the same stable oMLX channel, and restart the server. The app's built-in stable updater remains available as a one-click alternative.

If `/Applications` requires administrator access, the command displays `Administrator Password:` and waits for you to type your macOS password directly into the terminal. Input is intentionally hidden by macOS; the script never reads, stores, pipes, or supplies the password. If the installed version already matches the stable release, no password is needed.

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

   - **8 GB:** `gemma-4-e2b-it-mxfp8` only, and this model is impractical here — Hermes Agent refuses to start below a 64K context window, whose KV cache won't fit in 8 GB. Treat 16 GB as the realistic floor.
   - **16 GB:** `gemma-4-e4b-it-mxfp8` is the sweet spot; `e2b` for snappier responses.
   - **24–32 GB:** `gemma-4-e4b-it-mxfp8` reliably; `gemma-4-26b-a4b-it-mxfp8` works but expect swapping under long contexts — keep the window at the 64k floor and close other heavy apps.
   - **36–48 GB:** `gemma-4-26b-a4b-it-mxfp8` is the default pick. MoE keeps active compute small while quality stays near 31B-dense.
   - **64 GB+:** Any of them. `gemma-4-31b-it-mxfp8` for strongest single-pass quality; `gemma-4-26b-a4b-it-mxfp8` for faster throughput.

  The pre-configured default in [`hermes/config.yaml.example`](hermes/config.yaml.example) is `gemma-4-31b-it-mxfp8`. After bootstrap, edit the generated `hermes/config.yaml` if you pick a different variant.

3. Hit **Download** and wait. Progress is visible in the UI; files land under `~/.omlx/models/`.
4. Click **Load** on the new model. Verify it's serving:

   ```bash
   KEY=$(jq -r .auth.api_key ~/.omlx/settings.json)
   curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:8000/v1/models | jq '.data[].id'
   ```

5. If the returned ID doesn't match `model.default` in the generated `hermes/config.yaml`, update it, then `mna-hermes rebuild`.
6. Optionally tweak that model's `max_context_window` — see [oMLX — context window](#omlx--context-window) below. Smaller-RAM Macs should also lower `model.context_length` to match.

Once a model is loaded and `hermes/config.yaml` points at it, `mna-hermes` chats work end-to-end.

### oMLX — context window

`hermes/config.yaml`'s `model.context_length` (65536) caps what Hermes sends to oMLX. On the oMLX side, the effective ceiling is the **per-model** `max_context_window` in `~/.omlx/model_settings.json`, falling back to the **global** `.sampling.max_context_window` in `~/.omlx/settings.json`. `mna-bootstrap` pins the global fallback to 65536 so any freshly downloaded model works out of the box at 64k.

> **Why 64k and not 32k?** Hermes Agent enforces a **hard 64,000-token minimum** and refuses to initialize below it (`Model … has a context window of 32,768 tokens, which is below the minimum 64,000 required`). Its system prompt, tool schemas, and memory consume a large slice of the window, so a smaller one isn't permitted regardless of task size. Both the config value and the oMLX cap must therefore stay ≥ 64k.

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
    -d '{"max_context_window": 65536, "max_tokens": 8192}' | jq
  rm -f "$JAR"
  ```

When raising the window above 64k, also bump `model.context_length` in the generated `hermes/config.yaml` to match (it must stay ≤ the oMLX value, and ≥ the 64k Hermes floor).

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
mna-omlx restart
sed -i.bak "s|^OMLX_API_KEY=.*|OMLX_API_KEY=$NEW|" ~/repo/mac-nix-agent/hermes/.env && rm ~/repo/mac-nix-agent/hermes/.env.bak
mna-hermes down && mna-hermes up
```

App and server control:

```bash
mna-omlx status
mna-omlx start
mna-omlx stop
mna-omlx restart
mna-omlx upgrade       # latest stable official DMG
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
mkdir -p ~/repo && git clone https://github.com/poomnupong/mac-nix-agent.git ~/repo/mac-nix-agent
cd ~/repo/mac-nix-agent
./bin/mna-bootstrap
```

The script is idempotent. Each step is skipped if already satisfied:

1. Sanity checks (macOS 26+ Apple silicon)
2. Write `local.nix` (username + hostname from your machine)
3. Prompt for git `user.name` / `user.email` if `~/.gitconfig` doesn't have them yet
4. Install Determinate Nix
5. Install Homebrew
6. Apply the nix-darwin flake through a temporary clean source
7. Install or upgrade Apple `container` runtime (latest release from GitHub)
8. Install the latest stable official oMLX app and seed `~/.omlx/settings.json` with `host=0.0.0.0`, generated API key, and `sampling.max_context_window=65536`
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
git clone https://github.com/poomnupong/mac-nix-agent.git ~/repo/mac-nix-agent
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

Use `mna-rebuild` for activation; it makes `local.nix` visible to Nix without staging it.

#### 4. Install Homebrew

nix-darwin manages Homebrew declaratively but does not install it — do that once manually:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

#### 5. Build and activate

On a fresh Mac, run the complete bootstrap (it also installs Nix when needed):

```bash
./bin/mna-bootstrap
```

After this first run, use:

```bash
mna-rebuild
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
mna-bootstrap             # reinstalls the stable app; step 8 reseeds settings.json
```

| Component | Default (data-safe) | `--purge` adds | Reinstall |
|-----------|---------------------|----------------|-----------|
| `omlx` | stop + remove `/Applications/oMLX.app`; keep `~/.omlx/` | `rm -rf ~/.omlx` | `mna-bootstrap` |
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

> **Hermes host files are never deleted** — `hermes/.env`, `hermes/config.yaml`, `hermes/data/memories/`, and `hermes/workspace/` survive every `mna-uninstall hermes`, even with `--purge`. The `hermes-data` named volume also survives by default, but `--purge` deletes it, including sessions and plugin/cron state.
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
mna-rebuild
```

### Update all packages

```bash
cd ~/repo/mac-nix-agent
mna-update                 # flake/brew update + darwin-rebuild + stable oMLX app update
```

`mna-update` runs `brew upgrade` with `--verbose` **before** `darwin-rebuild`, then checks the stable oMLX app channel separately.

Before Homebrew operations, bootstrap, rebuild, and update remove root-owned Python bytecode caches left by legacy root-run services. Only generated `__pycache__` directories inside Homebrew's Python locations are touched; this prevents stale permissions from blocking `brew cleanup`.

At startup, `mna-update` deliberately clears any cached sudo authorization and displays `Administrator Password:`. Type the macOS administrator password directly into that terminal (no characters will appear); the command waits for the response and then reuses sudo's credential ticket for the rebuild. `mna-bootstrap` uses the same interaction before its first system activation.

To update the Nix layer by hand instead:

```bash
nix flake update
mna-rebuild
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

### oMLX won't start / old formula cannot download dependencies

- **Old Homebrew install fails on `files.pythonhosted.org`.** Managed networks may block the PyPI CDN used by the source formula. Run `mna-omlx install`; it installs the self-contained official DMG and removes the superseded formula without touching `~/.omlx`.
- **Port 8000 is already in use or lifecycle control fails.** A stale Nix/Brew launch agent or orphaned server may be holding the port. Diagnose and repair:

  ```bash
  mna-doctor          # report what's wrong
  mna-doctor --fix    # remove stale ownership and restart the app-managed server
  mna-omlx status     # confirm: app version, port bound, HTTP 200
  ```

---

## Backup & restore

Hermes has two persistence layers: portable host files under `hermes/`, and the Apple Container `hermes-data` volume containing sessions, plugins, cron state, and caches. Back up the host files for configuration, credentials, memories, and workspace:

**Back up:**

```bash
cd ~/repo/mac-nix-agent
tar czf ~/hermes-backup-$(date +%Y%m%d).tgz \
    hermes/.env \
    hermes/config.yaml \
    hermes/data \
  hermes/workspace
```

Stash the tarball somewhere durable (iCloud Drive, external disk, encrypted USB — it contains your API key, so treat it like a secret).

To preserve dashboard/chat sessions and other container-side state too, export the named volume while Hermes is running:

```bash
container exec hermes-agent tar czf - \
  --exclude=.env --exclude=config.yaml \
  --exclude=Dockerfile --exclude=entrypoint.sh \
  --exclude=memories --exclude=workspace --exclude=lost+found \
  -C /opt/data . > ~/hermes-volume-$(date +%Y%m%d).tgz
```

The exclusions are host bind mounts already covered by the first archive.

**Restore on a fresh Mac:**

```bash
mkdir -p ~/repo
git clone https://github.com/poomnupong/mac-nix-agent.git ~/repo/mac-nix-agent
cd ~/repo/mac-nix-agent
tar xzf ~/hermes-backup-YYYYMMDD.tgz   # restores .env + config + memories + workspace
./bin/mna-bootstrap
```

`mna-bootstrap` will reconcile `OMLX_API_KEY` in the restored `.env` with the new machine's oMLX key, while your live Hermes config, memories, and workspace come through verbatim — they're in the tarball, not the public repo.

If you also exported `hermes-data`, restore it after bootstrap, then restart Hermes:

```bash
./bin/mna-hermes down
container delete hermes-agent
cat ~/hermes-volume-YYYYMMDD.tgz | container run --rm -i \
  --user root --entrypoint /bin/tar \
  -v hermes-data:/opt/data hermes-toolbox:latest \
  xzf - -C /opt/data
./bin/mna-hermes up
```

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
