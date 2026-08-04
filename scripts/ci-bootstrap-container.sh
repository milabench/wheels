#!/bin/bash
# Bootstrap a minimal Ubuntu container for wheel builds.
# Safe to run as root (typical for job.container) or with sudo.
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

export DEBIAN_FRONTEND=noninteractive

$SUDO apt-get update
$SUDO apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    git \
    sudo \
    build-essential \
    python3 \
    python3-pip \
    python3-venv \
    xz-utils \
    wget

# GitHub CLI (release upload / skip checks)
if ! command -v gh >/dev/null 2>&1; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | $SUDO dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
    $SUDO chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    $SUDO apt-get update
    $SUDO apt-get install -y gh
fi

echo "==> Container bootstrap complete"
uname -m
gh --version
python3 --version
