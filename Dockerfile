# =============================================================================
# Hermes Suite — All-in-One Container Image
# Combines: hermes-agent + hermes-webui + hermes-dashboard
#
# Solves Podman v3.4.4 UID/GID sharing limitation between multiple containers
# by running all three services in a single container under one user.
#
# Services:
#   hermes-gateway   — Agent gateway on port 8642 (CLI, Telegram, cron, tools)
#   hermes-dashboard — Built-in monitoring dashboard on port 9119
#   hermes-webui     — Browser chat interface on port 8787
#
# Build:  podman build -t hermes-suite:2026.9.24-0.52.458 .
# Run:    podman-compose up -d
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Use the official hermes-agent image as the base
# This already contains: Python 3.13, Node.js, npm, Playwright, agent code,
# the built-in web dashboard (hermes dashboard), the gateway, uv, and s6-overlay.
# ---------------------------------------------------------------------------
ARG AGENT_VERSION=v2026.9.24
ARG ENABLE_WHATSAPP_BRIDGE=false

FROM docker.io/nousresearch/hermes-agent:${AGENT_VERSION}

USER root

# ---------------------------------------------------------------------------
# Stage 2: Install system dependencies needed by all services
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo \
        git \
        curl \
        nano \
        net-tools \
        iputils-ping \
        iproute2 \
        openssh-client \
        procps \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

# Allow hermes user to use sudo without password
RUN echo "hermes ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# ---------------------------------------------------------------------------
# Stage 3: Install Browser tool dependencies for agent
# npm install + Playwright chromium (needed by browser toolset).
# Skipped entirely when INSTALL_BROWSER=false (ENABLE_BROWSER=false in
# versions.env, or ./build.sh --no-browser): the base image ships a
# preinstalled Chromium under /opt/hermes/.playwright — the skip branch
# removes it so `-slim` images genuinely exclude local browser binaries
# (measured on arm64: full 4.44GB -> slim 3.34GB). Edge devices can use a
# cloud browser backend instead of local Chromium. node_modules is kept —
# the TUI and dashboard need it.
# WhatsApp bridge is removed by default (ENABLE_WHATSAPP_BRIDGE=false).
# Set --build-arg ENABLE_WHATSAPP_BRIDGE=true or use --whatsapp flag in
# build.sh to include it.
# ---------------------------------------------------------------------------
# NOTE: both ARGs must be re-declared inside this build stage. ARGs declared
# before FROM are global-scope (FROM lines only); without an in-stage
# declaration they expand to an empty string in RUN commands, which silently
# disables the toggles (that is how the --whatsapp flag used to be a no-op).
ARG INSTALL_BROWSER=true
ARG ENABLE_WHATSAPP_BRIDGE=false
RUN if [ "$INSTALL_BROWSER" = "true" ]; then \
        cd /opt/hermes && \
        npm install --prefer-offline --no-audit && \
        npx playwright install --with-deps chromium --only-shell && \
        npm cache clean --force; \
    else \
        rm -rf /opt/hermes/.playwright; \
    fi && \
    if [ "$ENABLE_WHATSAPP_BRIDGE" != "true" ]; then rm -rf /opt/hermes/scripts/whatsapp-bridge; fi && \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Stage 4: Install supervisord via uv (not available in Debian Trixie apt)
# We install it into a dedicated venv at /opt/supervisor.
# --python /usr/bin/python3: the agent v2026.9.24 base ships
# /opt/hermes/.python-version ("3.11"), which makes uv use its own managed
# CPython under /root/.local (mode 700) — the runtime user cannot execute
# it ("bad interpreter: Permission denied"). Pin to the system interpreter,
# matching the base image's own prebuilt /opt/hermes/.venv (python3.13).
# ---------------------------------------------------------------------------
RUN uv venv --python /usr/bin/python3 /opt/supervisor && \
    uv pip install --python /opt/supervisor/bin/python3 supervisor && \
    ln -sf /opt/supervisor/bin/supervisord /usr/local/bin/supervisord && \
    ln -sf /opt/supervisor/bin/supervisorctl /usr/local/bin/supervisorctl

RUN mkdir -p /var/log/supervisor /var/run/supervisor && \
    chown -R hermes:hermes /var/log/supervisor /var/run/supervisor

# ---------------------------------------------------------------------------
# Stage 5: Install hermes-webui
# The webui is a Python web server (server.py). We clone it from GitHub
# and set up its own venv using uv (avoids python3-venv package requirement).
# The webui needs the agent's Python deps to import agent modules.
# We install with the same extras the base image bakes into /opt/hermes/.venv
# (all, messaging, otlp, anthropic, bedrock, azure-identity, matrix,
# google-chat) so the webui's in-process agent has working memory and
# provider backends (#16). hindsight is no longer an image extra upstream —
# it is a catalog plugin whose deps lazy-install at plugin-install time
# into the durable /opt/data volume (#38128).
#
# PIN to a specific tag for reproducible builds — never use 'master'.
# ---------------------------------------------------------------------------
ARG HERMES_WEBUI_VERSION=v0.52.458
RUN cd /opt && \
    git clone --depth 1 --branch ${HERMES_WEBUI_VERSION} \
        https://github.com/nesquena/hermes-webui.git hermes-webui && \
    uv venv --python /usr/bin/python3 /opt/hermes-webui/venv && \
    uv pip install --python /opt/hermes-webui/venv/bin/python3 --no-cache-dir -r /opt/hermes-webui/requirements.txt && \
    uv pip install --python /opt/hermes-webui/venv/bin/python3 --no-cache-dir -e "/opt/hermes[all,messaging,otlp,anthropic,bedrock,azure-identity,matrix,google-chat]" && \
    rm -rf /opt/hermes-webui/.git

# Bake version tag into the webui
RUN echo "__version__ = '${HERMES_WEBUI_VERSION}'" > /opt/hermes-webui/api/_version.py

# ---------------------------------------------------------------------------
# Patch (upstream webui #7048): named profiles don't inherit root .env vars.
# Mirrors the allowlist design from upstream PR #7060 (maintainer-reviewed
# revision): only non-secret operator/runtime settings may fall back to the
# root $HERMES_HOME/.env; profile-defined keys always win; secrets and
# HERMES_WEBUI_* server keys are never inherited. Default profile is
# unaffected (it reads the root .env as its own layer). DROP THIS PATCH when
# a stable webui tag ships _ROOT_ENV_SHARE_ALLOWLIST in api/profiles.py.
#
# NOTE: the patch is a COPY+RUN of patches/webui-root-env-7048.py, not a
# Dockerfile heredoc — podman 3.4.x (Jetson Nano / JetPack 4 era) predates
# heredoc support and would parse the patch body as Dockerfile instructions.
COPY patches/webui-root-env-7048.py /tmp/webui-root-env-7048.py
RUN python3 /tmp/webui-root-env-7048.py && rm /tmp/webui-root-env-7048.py

# ---------------------------------------------------------------------------
# Patch: suite-release update check. When HERMES_SUITE_RELEASE_TAG is baked
# (suite builds), the webui update banner reports hermes-suite releases
# (github.com/sunnysktsang/hermes-suite) and the matching
# ascensionoid/hermes-suite image tag instead of upstream webui releases and
# ghcr.io/nesquena/hermes-webui (which a suite deployment cannot use).
# Empty tag (non-suite builds of the webui alone) leaves upstream behavior
# unchanged. DROP THIS PATCH when upstream webui ships a deployment-aware
# release check natively.
# NOTE: ARGs are declared in-stage (after FROM) so they expand in RUN/ENV;
# global-scope ARGs before FROM do not (see the INSTALL_BROWSER note above).
ARG HERMES_SUITE_RELEASE_TAG=""
ARG HERMES_SUITE_IMAGE_REF=""
ENV HERMES_SUITE_RELEASE_TAG=${HERMES_SUITE_RELEASE_TAG}
ENV HERMES_SUITE_IMAGE_REF=${HERMES_SUITE_IMAGE_REF}
COPY patches/webui-suite-release-check.py /tmp/webui-suite-release-check.py
RUN python3 /tmp/webui-suite-release-check.py && rm /tmp/webui-suite-release-check.py

# Ensure venv is owned by hermes so runtime lazy-dep auto-install works (#6).
RUN chown -R hermes:hermes /opt/hermes-webui/venv

# ---------------------------------------------------------------------------
# Stage 6: Set up supervisord config and startup script
# ---------------------------------------------------------------------------
COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY start.sh /opt/hermes-suite/start.sh
RUN chmod +x /opt/hermes-suite/start.sh

# ---------------------------------------------------------------------------
# Patch: disable dashboard auto-sso — the upstream middleware auto-redirects
# to /auth/login (OAuth start) when a single provider is registered, but
# BasicAuthProvider is password-only and raises NotImplementedError there.
# Skip it so unauthenticated requests go directly to /login (password form).
# ---------------------------------------------------------------------------
RUN sed -i 's/auto = _auto_sso_response(request)/auto = None  # disabled: BasicAuthProvider has no OAuth start flow/'     /opt/hermes/hermes_cli/dashboard_auth/middleware.py

# ---------------------------------------------------------------------------
# Stage 7: Environment, labels, and runtime config
# ---------------------------------------------------------------------------
# Re-declare ARGs after FROM so they are available in LABEL
ARG AGENT_VERSION=v2026.9.24
ARG ENABLE_WHATSAPP_BRIDGE=false
ARG HERMES_WEBUI_VERSION=v0.52.458

LABEL org.opencontainers.image.title="Hermes Suite" \
      org.opencontainers.image.description="All-in-one: hermes-agent + hermes-webui + hermes-dashboard" \
      org.opencontainers.image.source="https://github.com/sunnysktsang/hermes-suite" \
      org.opencontainers.image.vendor="sunnysktsang" \
      hermes-suite.agent-version="${AGENT_VERSION}" \
      hermes-suite.webui-version="${HERMES_WEBUI_VERSION}"

ENV PATH="/opt/hermes/.venv/bin:/opt/hermes-webui/venv/bin:$PATH"
ENV HERMES_HOME=/opt/data
ENV HERMES_DATA_DIR=/opt/data
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright

# hermes-agent web dist (built into the base image)
ENV HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist

# hermes-webui settings
ENV HERMES_WEBUI_HOST=0.0.0.0
ENV HERMES_WEBUI_PORT=8787
ENV HERMES_WEBUI_STATE_DIR=/opt/data/webui
ENV HERMES_WEBUI_DEFAULT_WORKSPACE=/workspace
ENV HERMES_WEBUI_AGENT_DIR=/opt/hermes

# Expose all service ports
EXPOSE 8642 8787 9119

# Workspace directory
RUN mkdir -p /workspace

WORKDIR /opt/hermes

# Entrypoint: run start.sh which sets up config then launches supervisord
ENTRYPOINT ["/opt/hermes-suite/start.sh"]
CMD ["supervisord", "-c", "/etc/supervisor/supervisord.conf", "-n"]
