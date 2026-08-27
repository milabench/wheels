#!/bin/bash
# Install Intel oneAPI toolkit packages for XPU wheel builds.
# Usage: bash scripts/ci-install-oneapi.sh [oneapi-version]
#
# Installs the DPC++ compiler (icx/icpx/sycl) and oneMKL dev headers from
# Intel's apt repository and exports oneAPI paths for subsequent workflow steps.
set -euo pipefail

ONEAPI_VERSION="${1:-${ONEAPI_VERSION:-2026.1}}"

# Job containers usually run as root — sudo is unnecessary / may be missing.
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# ── Intel apt repository ─────────────────────────────────────────────────────
$SUDO mkdir -p --mode=0755 /etc/apt/keyrings
wget -qO- https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB \
    | $SUDO gpg --dearmor -o /etc/apt/keyrings/oneapi.gpg

echo "deb [signed-by=/etc/apt/keyrings/oneapi.gpg] https://apt.repos.intel.com/oneapi all main" \
    | $SUDO tee /etc/apt/sources.list.d/oneapi.list

# Prefer Intel's packages when there are Ubuntu naming conflicts.
$SUDO tee /etc/apt/preferences.d/oneapi-pin-600 >/dev/null <<'EOF'
Package: intel-oneapi-*
Pin: release o=apt.repos.intel.com
Pin-Priority: 600
EOF

$SUDO apt-get update

# ── Component selection ──────────────────────────────────────────────────────
# Minimal set required to build vLLM XPU and vllm-xpu-kernels from source.
# DPC++ (icx/icpx) compiles SYCL kernels; oneMKL provides BLAS/LAPACK on GPU.
# oneTBB is pulled in transitively by both.
PKGS=(
    "intel-oneapi-dpcpp-cpp-${ONEAPI_VERSION}"
    "intel-oneapi-mkl-devel-${ONEAPI_VERSION}"
)

$SUDO apt-get install -y --no-install-recommends "${PKGS[@]}"

# ── Environment setup ────────────────────────────────────────────────────────
SETVARS="/opt/intel/oneapi/setvars.sh"
if [ ! -f "$SETVARS" ]; then
    echo "ERROR: oneAPI setvars.sh not found at $SETVARS" >&2
    exit 1
fi
# Activate for the remainder of this script.
set +u
source "$SETVARS" --force
set -u

# Export paths so later workflow steps (in the same shell or via GITHUB_ENV) see the toolkit.
if [ -n "${GITHUB_PATH:-}" ]; then
    # icpx/icx live inside the versioned compiler directory; setvars exports $PATH so use it.
    echo "$PATH" | tr ':' '\n' | grep -E 'intel/oneapi/(compiler|mkl)' \
        >> "$GITHUB_PATH" || true
fi
if [ -n "${GITHUB_ENV:-}" ]; then
    {
        echo "ONEAPI_ROOT=/opt/intel/oneapi"
        echo "DPCPPROOT=${DPCPPROOT:-}"
        echo "MKLROOT=${MKLROOT:-}"
        echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}"
    } >> "$GITHUB_ENV"
fi

# ── Smoke test ───────────────────────────────────────────────────────────────
echo "==> oneAPI ${ONEAPI_VERSION} installed"
icpx --version
python3 -c "import sys; print('python', sys.version)"

df -h / | tail -1
