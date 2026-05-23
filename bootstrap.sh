#!/bin/bash
# mac-nix-agent — first-time bootstrap
#
# Idempotent. Safe to re-run. Each step skips itself when already done.
#
# Steps:
#   1. Sanity checks (macOS 26+ Apple silicon)
#   2. Personalize flake.nix (username + hostname)
#   3. Prompt for git identity            (skip if ~/.gitconfig has user.email)
#   4. Install Determinate Nix              (skip if `nix` present)
#   5. Install Homebrew                     (skip if `brew` present)
#   6. Apply nix-darwin flake               (always — picks up local changes)
#   7. Install/upgrade Apple `container`    (latest release from GitHub)
#   8. Configure oMLX (bind + key)          (skip if already configured)
#   9. Seed hermes/.env from .env.example   (skip if .env exists)
#  10. Start Hermes container               (via hermes-rebuild)
#
# Usage: ./bootstrap.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

# ── Pretty logging ───────────────────────────────────────
log()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!!\033[0m  %s\n" "$*" >&2; }
die()  { printf "\033[1;31mxx\033[0m  %s\n" "$*" >&2; exit 1; }

# ── 1. Sanity checks ─────────────────────────────────────
log "Checking host..."
[ "$(uname -s)" = "Darwin" ] || die "macOS required."
[ "$(uname -m)" = "arm64" ]  || die "Apple silicon required."
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$macos_major" -lt 26 ]; then
    warn "macOS $macos_major detected — Apple container needs macOS 26+. Continuing, but step 5 will fail."
fi

if [ "${SUDO_USER:-}" ] && [ "$EUID" -eq 0 ]; then
    die "Do NOT run this script with sudo. It prompts for sudo only when needed."
fi

# ── 2. Personalize flake.nix (username + hostname) ───────
current_user="$(id -un)"
current_host="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"

flake_user="$(awk -F\" '/^[[:space:]]*username[[:space:]]*=/ { print $2; exit }' flake.nix)"
flake_host="$(awk -F\" '/^[[:space:]]*hostname[[:space:]]*=/ { print $2; exit }' flake.nix)"

if [ "$flake_user" != "$current_user" ] || [ "$flake_host" != "$current_host" ]; then
    log "Personalizing flake.nix"
    [ "$flake_user" != "$current_user" ] && printf "    username: %s -> %s\n" "$flake_user" "$current_user"
    [ "$flake_host" != "$current_host" ] && printf "    hostname: %s -> %s\n" "$flake_host" "$current_host"
    # macOS BSD sed: -i requires backup suffix arg
    sed -i.bak \
        -e "s|^\([[:space:]]*username[[:space:]]*=[[:space:]]*\"\)[^\"]*\(\".*\)|\1$current_user\2|" \
        -e "s|^\([[:space:]]*hostname[[:space:]]*=[[:space:]]*\"\)[^\"]*\(\".*\)|\1$current_host\2|" \
        flake.nix
    rm -f flake.nix.bak
else
    log "flake.nix already personalized for $current_user @ $current_host — skipping."
fi

# ── 3. Git identity (prompt only if missing) ─────────────
# We deliberately do NOT manage git identity via home-manager: it would
# stomp ~/.gitconfig on every darwin-rebuild and leak PII back into the
# nix files we just scrubbed for public release. Use the standard global
# config instead.
#
# home-manager owns ~/.config/git/config (read-only symlink to the nix
# store), so plain `git config --global` fails with EACCES. Force writes
# to ~/.gitconfig via GIT_CONFIG_GLOBAL — git merges both files on read.
GIT_GLOBAL="$HOME/.gitconfig"
if ! GIT_CONFIG_GLOBAL="$GIT_GLOBAL" git config --global user.email >/dev/null 2>&1 \
        && ! git config --global user.email >/dev/null 2>&1; then
    log "No global git identity found — let's set it now (used for all commits)."
    printf "    git user.name  (e.g. Jane Doe)        : "
    read -r gname
    printf "    git user.email (e.g. jane@example.com): "
    read -r gemail
    [ -n "$gname" ]  && GIT_CONFIG_GLOBAL="$GIT_GLOBAL" git config --global user.name  "$gname"
    [ -n "$gemail" ] && GIT_CONFIG_GLOBAL="$GIT_GLOBAL" git config --global user.email "$gemail"
    if [ -z "$gname" ] && [ -z "$gemail" ]; then
        warn "Skipped git identity setup. Set later with: GIT_CONFIG_GLOBAL=~/.gitconfig git config --global user.{name,email} ..."
    fi
else
    log "Git identity present ($(git config --get user.email)) — skipping."
fi

# ── 4. Determinate Nix ───────────────────────────────────
if ! command -v nix >/dev/null 2>&1; then
    log "Installing Determinate Nix..."
    curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
        | sh -s -- install --determinate
    # shellcheck disable=SC1091
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true
    command -v nix >/dev/null 2>&1 || die "Nix not on PATH after install — open a new shell and re-run."
else
    log "Nix present — skipping."
fi

# ── 5. Homebrew ──────────────────────────────────────────
if ! command -v brew >/dev/null 2>&1; then
    log "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
else
    log "Homebrew present — skipping."
fi

# ── 6. nix-darwin flake activation ───────────────────────
log "Applying nix-darwin flake (sudo)..."
if command -v darwin-rebuild >/dev/null 2>&1; then
    sudo darwin-rebuild switch --flake "$REPO_DIR"
else
    sudo nix run nix-darwin#darwin-rebuild -- switch --flake "$REPO_DIR"
fi

# ── 7. Apple `container` runtime (install or upgrade) ────
# Apple's container .pkg ships /usr/local/bin/update-container.sh for
# in-place upgrades. We always check the latest release tag against the
# installed version and act accordingly.
log "Checking Apple container runtime..."
latest_tag="$(curl -fsSL https://api.github.com/repos/apple/container/releases/latest \
    | awk -F\" '/"tag_name":/ { print $4; exit }')"
latest_ver="${latest_tag#v}"

if command -v container >/dev/null 2>&1; then
    current_ver="$(container --version 2>/dev/null | awk '{print $NF}' | head -n1)"
    if [ -n "$latest_ver" ] && [ "$current_ver" != "$latest_ver" ]; then
        log "Upgrading Apple container: $current_ver -> $latest_ver"
        if [ -x /usr/local/bin/update-container.sh ]; then
            sudo /usr/local/bin/update-container.sh
        else
            warn "update-container.sh not found — falling back to .pkg reinstall."
            install_container=1
        fi
    else
        log "Apple container up to date ($current_ver) — skipping."
    fi
else
    install_container=1
fi

if [ "${install_container:-0}" = "1" ]; then
    log "Installing Apple container runtime ($latest_tag)..."
    pkg_url="$(curl -fsSL https://api.github.com/repos/apple/container/releases/latest \
        | grep -oE 'https://[^"]+\.pkg' \
        | head -n1)"
    [ -n "$pkg_url" ] || die "Could not resolve container .pkg URL from GitHub."
    tmp_pkg="$(mktemp -t container).pkg"
    log "Downloading $pkg_url"
    curl -fsSL -o "$tmp_pkg" "$pkg_url"
    log "Installing (sudo)..."
    sudo installer -pkg "$tmp_pkg" -target /
    rm -f "$tmp_pkg"
fi

log "Starting container system..."
container system start 2>/dev/null || true

# ── 8. oMLX (host + api key in ~/.omlx/settings.json) ────
# Stock brew plist runs `omlx serve` with no flags, so it reads
# everything from settings.json. We only need to ensure:
#   .server.host  = "0.0.0.0"        (so the VM at 192.168.64.x can reach it)
#   .auth.api_key = <generated key>  (used for Bearer auth)
omlx_settings="$HOME/.omlx/settings.json"
mkdir -p "$HOME/.omlx"

if [ ! -f "$omlx_settings" ]; then
    log "Bootstrapping oMLX once to generate settings.json..."
    /opt/homebrew/bin/brew services start jundot/omlx/omlx >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        [ -f "$omlx_settings" ] && break
        sleep 1
    done
    [ -f "$omlx_settings" ] || die "oMLX did not generate $omlx_settings — start it manually and re-run."
    /opt/homebrew/bin/brew services stop jundot/omlx/omlx >/dev/null 2>&1 || true
    sleep 2
fi

command -v jq >/dev/null 2>&1 || die "jq is required (installed by nix-darwin home.nix in step 4 — re-open shell?)."

needs_restart=0
host="$(jq -r '.server.host // empty' "$omlx_settings")"
key="$(jq -r '.auth.api_key // empty'  "$omlx_settings")"

if [ "$host" != "0.0.0.0" ]; then
    log "Setting oMLX bind host = 0.0.0.0"
    tmp="$(mktemp)"
    jq '.server.host = "0.0.0.0"' "$omlx_settings" > "$tmp" && mv "$tmp" "$omlx_settings"
    needs_restart=1
fi

if [ -z "$key" ] || [ "$key" = "null" ]; then
    key="omlx-sk-$(openssl rand -hex 24)"
    log "Generating oMLX API key (stored in .auth.api_key)"
    tmp="$(mktemp)"
    jq --arg k "$key" '.auth.api_key = $k | .auth.skip_api_key_verification = false' \
        "$omlx_settings" > "$tmp" && mv "$tmp" "$omlx_settings"
    chmod 600 "$omlx_settings"
    needs_restart=1
fi

if [ "$needs_restart" -eq 1 ] || ! /opt/homebrew/bin/brew services list 2>/dev/null | grep -qE '^omlx\s+started'; then
    log "Starting/restarting oMLX"
    /opt/homebrew/bin/brew services restart jundot/omlx/omlx >/dev/null
fi

omlx_key="$key"

# ── 9. hermes/.env ───────────────────────────────────────
if [ ! -f "$REPO_DIR/hermes/.env" ]; then
    log "Creating hermes/.env from .env.example"
    cp "$REPO_DIR/hermes/.env.example" "$REPO_DIR/hermes/.env"
    chmod 600 "$REPO_DIR/hermes/.env"
fi

# Migrate legacy OPENAI_API_KEY entry to OMLX_API_KEY if present
if grep -qE '^OPENAI_API_KEY=' "$REPO_DIR/hermes/.env" && ! grep -qE '^OMLX_API_KEY=' "$REPO_DIR/hermes/.env"; then
    log "Migrating OPENAI_API_KEY → OMLX_API_KEY in hermes/.env"
    sed -i.bak "s|^OPENAI_API_KEY=|OMLX_API_KEY=|" "$REPO_DIR/hermes/.env"
    rm -f "$REPO_DIR/hermes/.env.bak"
fi

current_key="$(grep -E '^OMLX_API_KEY=' "$REPO_DIR/hermes/.env" | cut -d= -f2-)"
if [ "$current_key" != "$omlx_key" ]; then
    log "Syncing OMLX_API_KEY in hermes/.env with oMLX key"
    sed -i.bak "s|^OMLX_API_KEY=.*|OMLX_API_KEY=$omlx_key|" "$REPO_DIR/hermes/.env"
    rm -f "$REPO_DIR/hermes/.env.bak"
fi

# ── 10. Hermes container ─────────────────────────────────
log "Building & starting Hermes container..."
"$REPO_DIR/hermes/run.sh" rebuild

cat <<EOF

$(printf "\033[1;32mBootstrap complete.\033[0m")

  oMLX admin:  http://127.0.0.1:8000/admin
  Hermes dash: http://localhost:9119
  Attach:      container exec -it hermes-agent bash
  Chat:        hermes

Next: pull a model from the oMLX admin UI (or place one under ~/.omlx/models/),
then edit hermes/config.yaml \`model.default\` and run \`hermes-rebuild\`.
EOF
