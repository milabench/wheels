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

# Resolve compile parallelism for fat self-hosted builds.
# Workflow passes MAX_JOBS=0 to mean "use all cores".
if [ -z "${MAX_JOBS:-}" ] || [ "${MAX_JOBS}" = "0" ]; then
    MAX_JOBS="$(nproc)"
fi
export MAX_JOBS
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$MAX_JOBS}"
export NVCC_THREADS="${NVCC_THREADS:-$MAX_JOBS}"
echo "==> Using MAX_JOBS=${MAX_JOBS} (nproc=$(nproc))"
if [ -n "${GITHUB_ENV:-}" ]; then
    {
        echo "MAX_JOBS=${MAX_JOBS}"
        echo "CMAKE_BUILD_PARALLEL_LEVEL=${CMAKE_BUILD_PARALLEL_LEVEL}"
        echo "NVCC_THREADS=${NVCC_THREADS}"
    } >> "$GITHUB_ENV"
fi
