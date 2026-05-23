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
# Keep container alive for `container exec`
exec sleep infinity
