#!/bin/bash
# Bootstrap a minimal Ubuntu container for wheel builds.
# Safe to run as root (typical for job.container) or with sudo.
#
# Installs uv and a glibc-compatible CPython matching PYTHON_VERSION
# (default 3.12). Do not use actions/setup-python inside ubuntu:22.04
# containers — those builds often require a newer glibc.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${SCRIPT_DIR}/ci-assert-build-os.sh"

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

export DEBIAN_FRONTEND=noninteractive
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
UV_INSTALL_DIR="${UV_INSTALL_DIR:-/usr/local/bin}"
WHEELS_PYTHON_ROOT="${WHEELS_PYTHON_ROOT:-/opt/wheels-python}"

$SUDO apt-get update
$SUDO apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    git \
    sudo \
    build-essential \
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

# gh release upload needs an explicit repo in job containers (no reliable git remote).
if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_ENV:-}" ]; then
    echo "GH_REPO=${GITHUB_REPOSITORY}" >> "$GITHUB_ENV"
fi

# ── uv + CPython (glibc-matched to this container) ──────────────────────────
echo "==> Installing uv into ${UV_INSTALL_DIR}"
curl -LsSf https://astral.sh/uv/install.sh | $SUDO env UV_INSTALL_DIR="${UV_INSTALL_DIR}" sh
export PATH="${UV_INSTALL_DIR}:${PATH}"
uv --version

echo "==> Installing Python ${PYTHON_VERSION} via uv"
# System-wide install so all steps see the same interpreter.
$SUDO mkdir -p /opt/uv-python
export UV_PYTHON_INSTALL_DIR=/opt/uv-python
# only-managed so an unrelated venv or the distro python is never picked up.
export UV_PYTHON_PREFERENCE=only-managed
$SUDO env UV_PYTHON_INSTALL_DIR=/opt/uv-python UV_PYTHON_PREFERENCE=only-managed PATH="${PATH}" \
    uv python install "${PYTHON_VERSION}"
PY_PATH="$(uv python find "${PYTHON_VERSION}")"
if [ -z "${PY_PATH}" ] || [ ! -x "${PY_PATH}" ]; then
    echo "::error::uv python find ${PYTHON_VERSION} failed"
    exit 1
fi

echo "==> Python at ${PY_PATH}"
"${PY_PATH}" --version

# uv-managed interpreters are marked externally managed, so build steps must
# install into a venv rather than the interpreter itself.
echo "==> Creating build environment at ${WHEELS_PYTHON_ROOT}"
$SUDO mkdir -p "${WHEELS_PYTHON_ROOT}"
$SUDO chown -R "$(id -u):$(id -g)" "${WHEELS_PYTHON_ROOT}"
uv venv --seed --python "${PY_PATH}" "${WHEELS_PYTHON_ROOT}"

uv pip install --python "${WHEELS_PYTHON_ROOT}/bin/python" --upgrade pip setuptools wheel
"${WHEELS_PYTHON_ROOT}/bin/python" -c "import sys; print(sys.version); print(sys.executable)"
"${WHEELS_PYTHON_ROOT}/bin/pip" --version

export VIRTUAL_ENV="${WHEELS_PYTHON_ROOT}"
export PATH="${WHEELS_PYTHON_ROOT}/bin:${UV_INSTALL_DIR}:${PATH}"
if [ -n "${GITHUB_PATH:-}" ]; then
    {
        echo "${WHEELS_PYTHON_ROOT}/bin"
        echo "${UV_INSTALL_DIR}"
    } >> "$GITHUB_PATH"
fi
if [ -n "${GITHUB_ENV:-}" ]; then
    {
        echo "UV_PYTHON_INSTALL_DIR=/opt/uv-python"
        echo "UV=${UV_INSTALL_DIR}/uv"
        echo "VIRTUAL_ENV=${WHEELS_PYTHON_ROOT}"
        echo "WHEELS_PYTHON=${WHEELS_PYTHON_ROOT}/bin/python"
    } >> "$GITHUB_ENV"
fi

echo "==> Container bootstrap complete"
uname -m
gh --version
python --version
pip --version

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
