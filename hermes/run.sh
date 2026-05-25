#!/bin/bash
# Hermes Agent — Apple Container lifecycle management
# Usage: run.sh {up|down|rebuild|status}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_IMAGE="docker.io/nousresearch/hermes-agent:latest"
HERMES_IMAGE="hermes-toolbox:latest"

# ── Resource allocation ──────────────────────────────────
HERMES_CPUS=4
HERMES_MEMORY="8G"

# ── Helpers ──────────────────────────────────────────────
ensure_system() {
    if ! container system status 2>/dev/null | grep -q 'running'; then
        echo "Container system not running — starting..."
        container system start
        # Wait for system to be ready
        local tries=0
        while ! container system status 2>/dev/null | grep -q 'running'; do
            sleep 1
            tries=$((tries + 1))
            if [ "$tries" -ge 15 ]; then
                echo "Error: container system failed to start after 15s" >&2
                exit 1
            fi
        done
        echo "Container system started."
    fi
}

is_running() {
    container list --format json 2>/dev/null | jq -e ".[] | select(.configuration.id == \"$1\" and .status == \"running\")" >/dev/null 2>&1
}

exists() {
    container list --all --format json 2>/dev/null | jq -e ".[] | select(.configuration.id == \"$1\")" >/dev/null 2>&1
}

ensure_volume() {
    if ! container volume list --quiet 2>/dev/null | grep -q "^${1}$"; then
        echo "Creating volume: $1"
        container volume create "$1"
    fi
}

ensure_image() {
    if ! container image list --format json 2>/dev/null | jq -e ".[] | select(.reference == \"$HERMES_IMAGE\")" >/dev/null 2>&1; then
        echo "Building hermes-toolbox image (first time)..."
        container image pull "$BASE_IMAGE"
        container build -t "$HERMES_IMAGE" "${SCRIPT_DIR}"
    fi
}

# Reconcile OMLX_API_KEY in hermes/.env with the live key oMLX is enforcing
# in ~/.omlx/settings.json. oMLX is the auth server, so its key wins.
#
# This closes the drift gap left by bootstrap.sh being a one-shot: brew
# upgrades, admin-UI "regenerate key", or a recreated settings.json on
# reboot can all change settings.json without touching .env, leaving the
# container authenticating with a stale key.
sync_omlx_key() {
    local settings="$HOME/.omlx/settings.json"
    local envfile="${SCRIPT_DIR}/.env"
    [ -f "$settings" ] || return 0
    [ -f "$envfile" ]  || return 0
    command -v jq >/dev/null 2>&1 || return 0

    local srv_key env_key
    srv_key="$(jq -r '.auth.api_key // empty' "$settings" 2>/dev/null)"
    [ -n "$srv_key" ] || return 0

    env_key="$(awk -F= '/^OMLX_API_KEY=/ { sub(/^OMLX_API_KEY=/, ""); print; exit }' "$envfile")"
    if [ "$srv_key" != "$env_key" ]; then
        echo "Syncing OMLX_API_KEY from ~/.omlx/settings.json -> hermes/.env"
        sed -i.bak "s|^OMLX_API_KEY=.*|OMLX_API_KEY=${srv_key}|" "$envfile"
        rm -f "${envfile}.bak"
    fi
}

# ── Commands ─────────────────────────────────────────────
cmd_up() {
    echo "Starting Hermes workspace..."

    # Ensure container system is running (needed after reboot)
    ensure_system

    # Reconcile OMLX_API_KEY with the live oMLX server before launch
    sync_omlx_key

    # Build custom image if needed
    ensure_image

    # Ensure persistent volume exists
    ensure_volume "hermes-data"

    # Ensure workspace and data directories exist on host
    mkdir -p "${SCRIPT_DIR}/data/memories"
    mkdir -p "${SCRIPT_DIR}/workspace"

    # ── Hermes Agent (includes SearXNG) ──────────────────
    if ! is_running "hermes-agent"; then
        if exists "hermes-agent"; then
            echo "Starting existing Hermes container..."
            container start hermes-agent 2>/dev/null || true
        else
            echo "Creating Hermes container..."
            container run -d \
                --name hermes-agent \
                --cpus "$HERMES_CPUS" --memory "$HERMES_MEMORY" \
                -v "hermes-data:/opt/data" \
                -v "${SCRIPT_DIR}/config.yaml:/opt/data/config.yaml" \
                -v "${SCRIPT_DIR}/.env:/opt/data/.env" \
                -v "${SCRIPT_DIR}/Dockerfile:/opt/data/Dockerfile" \
                -v "${SCRIPT_DIR}/entrypoint.sh:/opt/data/entrypoint.sh" \
                -v "${SCRIPT_DIR}/searxng/settings.yml:/etc/searxng/settings.yml" \
                -v "${SCRIPT_DIR}/workspace:/opt/data/workspace" \
                -v "${SCRIPT_DIR}/data/memories:/opt/data/memories" \
                -e "HERMES_UID=$(id -u)" \
                -e "HERMES_GID=$(id -g)" \
                -e "HERMES_DASHBOARD=1" \
                -e "HERMES_DASHBOARD_HOST=0.0.0.0" \
                -e "HERMES_DASHBOARD_TUI=1" \
                -e "HERMES_TUI_DIR=/opt/hermes/ui-tui" \
                -e "SEARXNG_URL=http://localhost:8080" \
                -p "127.0.0.1:9119:9119" \
                "$HERMES_IMAGE" \
                bash /opt/data/entrypoint.sh
        fi
    else
        echo "Hermes already running."
    fi

    echo ""
    cmd_status
    echo ""
    echo "Dashboard: http://localhost:9119"
    echo "Attach:    container exec -it hermes-agent bash"
}

cmd_down() {
    echo "Stopping Hermes workspace..."
    if is_running "hermes-agent"; then
        container stop hermes-agent
    fi
    echo "Stopped."
}

cmd_rebuild() {
    echo "Rebuilding Hermes toolbox image..."

    # Stop and remove existing containers
    cmd_down 2>/dev/null || true

    if exists "hermes-agent"; then
        container delete hermes-agent
    fi

    # Pull latest base image
    echo "Pulling base hermes-agent image..."
    container image pull "$BASE_IMAGE"

    # Rebuild custom image
    echo "Building hermes-toolbox image..."
    container build -t "$HERMES_IMAGE" "${SCRIPT_DIR}"

    # Start fresh
    cmd_up
}

cmd_status() {
    echo "=== Hermes Workspace Status ==="
    container list --all 2>/dev/null | grep -E "hermes-agent|ID" || echo "No containers found."
}

# ── Main ─────────────────────────────────────────────────
case "${1:-help}" in
    up)      cmd_up ;;
    down)    cmd_down ;;
    rebuild) cmd_rebuild ;;
    status)  cmd_status ;;
    *)
        echo "Usage: $(basename "$0") {up|down|rebuild|status}"
        echo ""
        echo "  up       Start Hermes agent (with SearXNG built in)"
        echo "  down     Stop the container"
        echo "  rebuild  Rebuild image and restart"
        echo "  status   Show container status"
        exit 1
        ;;
esac
