FROM docker.io/nousresearch/hermes-agent:latest

USER root

# ── System tools for Hermes to self-install packages at runtime ──
RUN apt-get update && \
    apt-get install -y --no-install-recommends nodejs npm libgtk-3-0 && \
    rm -rf /var/lib/apt/lists/*

# ── Camofox anti-detection browser ──────────────────────
RUN npm install -g camofox-browser

# ── Install SearXNG into the Hermes venv ─────────────────
RUN curl -sS https://bootstrap.pypa.io/get-pip.py | /opt/hermes/.venv/bin/python && \
    /opt/hermes/.venv/bin/pip install --no-cache-dir setuptools msgspec && \
    /opt/hermes/.venv/bin/pip install --no-cache-dir --no-build-isolation \
      git+https://github.com/searxng/searxng.git@master

# ── SearXNG settings (can be overridden via volume mount) ─
COPY searxng/settings.yml /etc/searxng/settings.yml

# ── Patch /model picker to show only configured providers ─
# Upstream includes ~30 canonical cloud providers (anthropic, openai, …) as
# "unconfigured" placeholders, forcing the user to scroll past them all to
# reach a single local provider. Flip include_unconfigured=False so the
# picker lists only providers the user actually has credentials for.
RUN sed -i 's/include_unconfigured=True,$/include_unconfigured=False,/' \
    /opt/hermes/tui_gateway/server.py && \
    grep -q 'include_unconfigured=False' /opt/hermes/tui_gateway/server.py

# ── Entrypoint ────────────────────────────────────────────
COPY entrypoint.sh /opt/hermes/entrypoint.sh
RUN chmod +x /opt/hermes/entrypoint.sh
