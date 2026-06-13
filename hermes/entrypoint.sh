#!/bin/bash
# Entrypoint: start tools in background, then keep container alive
set -euo pipefail

# Start SearXNG in background
echo "Starting SearXNG on :8080..."
SEARXNG_SETTINGS_PATH=/etc/searxng/settings.yml \
  /opt/hermes/.venv/bin/python -m searx.webapp &
# Start Camofox in background
echo "Starting Camofox on :9377..."
HOME=/opt/data/home camofox-browser serve --port 9377 >> /tmp/camofox.log 2>&1 &

# Start the Hermes web dashboard (browser GUI) in background.
# Binding to 0.0.0.0 (so the host reaches it across the VM bridge) engages
# Hermes' auth gate, so we source the mounted .env first to put the
# HERMES_DASHBOARD_BASIC_AUTH_* credentials in the dashboard's environment —
# without them the dashboard fails closed and refuses to bind. Backgrounded
# and logged so a dashboard hiccup never takes the container down.
if [ "${HERMES_DASHBOARD:-0}" = "1" ]; then
    echo "Starting Hermes dashboard on :9119..."
    (
        set -a
        [ -f /opt/data/.env ] && . /opt/data/.env
        set +a
        HERMES_HOME=/opt/data /opt/hermes/.venv/bin/hermes dashboard \
            --host "${HERMES_DASHBOARD_HOST:-0.0.0.0}" --port 9119 --no-open \
            >> /tmp/dashboard.log 2>&1
    ) &
fi

# Keep container alive for `container exec`
exec sleep infinity
