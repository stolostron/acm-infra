# Unified Code Agent Image
#
# This image provides a comprehensive development environment with multiple
# AI coding assistants pre-installed. It combines:
# - Universal base image with multi-language runtimes and cloud CLIs
# - Gemini CLI (Google)
# - Claude Code CLI (Anthropic)
# - OpenCode CLI (Multi-provider)
#
# Environment Variables (set at runtime):
# - GEMINI_API_KEY: Gemini API key
# - ANTHROPIC_API_KEY: Claude/Anthropic API key
# - OPENAI_API_KEY: OpenAI API key (optional, for OpenCode)
#
FROM debian:bookworm-slim

# === Core Utilities ===
# Essential tools for development and automation
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    jq \
    ca-certificates \
    curl \
    wget \
    gnupg \
    procps \
    make \
    gcc \
    g++ \
    libc6-dev \
    openssh-client \
    unzip \
    zip \
    bzip2 \
    xz-utils \
    tree \
    htop \
    vim \
    nano \
    less \
    && rm -rf /var/lib/apt/lists/*

# === GitHub CLI ===
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
       gpg --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# === yq (YAML processor) ===
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture)" \
    -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

# === kubectl ===
RUN ARCH=$(dpkg --print-architecture | sed 's/aarch64/arm64/' | sed 's/x86_64/amd64/') \
    && curl -fsSL "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl" \
    -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl

# === helm ===
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# === Go ===
ARG GO_VERSION=1.25.5
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"

# === golangci-lint ===
RUN curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b /usr/local/bin

# === Node.js (LTS) ===
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g npm@latest

# === Python 3 ===
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3 /usr/bin/python

# === Google Cloud CLI ===
RUN curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
    gpg --dearmor -o /etc/apt/keyrings/google-cloud.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/google-cloud.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
       > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update && apt-get install -y --no-install-recommends google-cloud-cli \
    && rm -rf /var/lib/apt/lists/*

# === AWS CLI v2 ===
RUN ARCH=$(dpkg --print-architecture | sed 's/amd64/x86_64/' | sed 's/arm64/aarch64/') \
    && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip

# === Docker CLI (for DinD scenarios) ===
RUN curl -fsSL https://download.docker.com/linux/debian/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# === Zsh + Oh My Zsh ===
RUN apt-get update && apt-get install -y --no-install-recommends zsh \
    && rm -rf /var/lib/apt/lists/*

# ============================================================
# === AI CLIs ===
# ============================================================

# --- 1. Gemini CLI (Google) ---
RUN npm install -g @google/gemini-cli

# --- 2. OpenCode CLI (Multi-provider) ---
RUN npm install -g opencode-ai@latest

# --- Utilities ---
# Copy utility scripts and ensure they are executable by all users
COPY --chmod=755 scripts/ /usr/local/bin/

# === Workspace Setup ===
ARG WORKSPACE_DIR=/workspace
ENV WORKSPACE_DIR=${WORKSPACE_DIR}

# Go environment - use /tmp for OpenShift compatibility
#
# Why /tmp instead of /workspace?
# 1. OpenShift runs containers with arbitrary UIDs (e.g., 1000570001)
#    These random UIDs may not have write permissions to /workspace subdirectories
# 2. /tmp is world-writable (chmod 777) by default, so any UID can write to it
# 3. Go downloads dependencies as read-only files to prevent accidental modification
#    When `make update` runs `gofmt -w` on all Go files (including .gomodcache),
#    it fails because dependencies are read-only. Using /tmp isolates these caches.
# 4. Argo Workflows clone git repos to /workspace, which may overwrite or conflict
#    with .go and .gomodcache directories
# 5. This is consistent with HOME="/tmp" set below for the same reason
#
ENV GOPATH="/tmp/.go"
ENV GOMODCACHE="/tmp/.gomodcache"
ENV GOCACHE="/tmp/.cache/go-build"
ENV PATH="/tmp/.go/bin:${PATH}"

# === Non-root User Setup (OpenShift Compatible) ===
# OpenShift runs containers with arbitrary UIDs from a project-specific range.
# Solution: Use /tmp as HOME since it's world-writable by default.
# This avoids all permission issues with arbitrary UIDs.

# Create workspace directory (will be writable via securityContext in K8s)
RUN mkdir -p ${WORKSPACE_DIR} && chmod 777 ${WORKSPACE_DIR}

# === Environment Variables ===
# Use /tmp as HOME to avoid permission issues with OpenShift arbitrary UIDs
# /tmp is world-writable, so any UID can create config files there
ENV HOME="/tmp"
ENV SHELL="/bin/zsh"
ENV XDG_CONFIG_HOME="/tmp/.config"
ENV XDG_CACHE_HOME="/tmp/.cache"
ENV XDG_DATA_HOME="/tmp/.local/share"

# --- 3. Claude Code CLI (Anthropic) ---
# Install globally since we can't rely on user home directory
RUN npm install -g @anthropic-ai/claude-code || true

# Add global npm bin to PATH (for claude if installed via npm)
ENV PATH="/usr/local/bin:${PATH}"

# --- AI CLI Configuration ---
# Pre-create config and cache directories in /tmp with proper permissions
# These directories are created at build time to ensure they exist with correct
# permissions when the container starts, regardless of which UID runs the container.
# Note: /tmp contents may be cleared, but mkdir at runtime is also fine since /tmp is writable.
RUN mkdir -p /tmp/.gemini /tmp/.config/opencode /tmp/.cache /tmp/.local/share \
    /tmp/.go /tmp/.gomodcache /tmp/.cache/go-build \
    && chmod -R 777 /tmp/.gemini /tmp/.config /tmp/.cache /tmp/.local /tmp/.go /tmp/.gomodcache

# Gemini CLI default settings (will be created at /tmp/.gemini/settings.json)
# Note: Gemini CLI will auto-create this on first run if not present

# Switch to non-root user (any UID works with /tmp as HOME)
USER 1000:0

WORKDIR ${WORKSPACE_DIR}

# Default shell
CMD ["/bin/zsh"]

# === Recommended Commands for Agent Execution ===
#
# All agents use context-aggregator.sh to fetch ConfigMap contexts.
# CONTEXTS.md is always created (with placeholder if no ConfigMaps configured).
#
# Gemini:
#   context-aggregator.sh -c "configmap1,configmap2" -o /workspace/CONTEXTS.md
#   cat /workspace/CONTEXTS.md | gemini --output-format stream-json --yolo -p "Your task" | gemini-stream-json-reader.sh
#
# Claude:
#   context-aggregator.sh -c "configmap1,configmap2" -o /workspace/CONTEXTS.md
#   claude --verbose --output-format stream-json --dangerously-skip-permissions -p "Your task" < /workspace/CONTEXTS.md | claude-stream-json-reader.sh
#
# OpenCode:
#   context-aggregator.sh -c "configmap1,configmap2" -o /workspace/CONTEXTS.md
#   opencode run --format json -f /workspace/CONTEXTS.md -- "Your task" | opencode-stream-json-reader.sh
