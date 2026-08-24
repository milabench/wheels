#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [ "$GPU_BACKEND" != "rocm" ]; then
    echo "==> Skipping ATOM (ROCm-only package)"
    exit 0
fi

echo "==> Building ATOM ${ATOM_VERSION} (${ACCEL_SHORT})"

export MAX_JOBS="${MAX_JOBS:-2}"

pip install \
    wheel \
    "setuptools>=61" \
    "setuptools_scm[toml]>=6.2" \
    packaging

install_rocm_dep() {
    local label=$1
    shift
    local whl="" pattern
    for pattern in "$@"; do
        whl=$(find "$WHEELS_DIR" -name "$pattern" 2>/dev/null | head -1 || true)
        if [ -n "$whl" ]; then
            break
        fi
    done
    if [ -n "$whl" ]; then
        echo "==> Installing dependency (${label}): $whl"
        pip install --no-deps "$whl"
    else
        echo "==> WARNING: no ${label} wheel in ${WHEELS_DIR}"
    fi
}

# ATOM kernels come from AITER; install the prebuilt wheel when available.
install_rocm_dep aiter "amd_aiter-*.whl" "aiter-*.whl"

TAG="v${ATOM_VERSION#v}"
VER="${ATOM_VERSION#v}"

git clone --branch "$TAG" --depth 1 https://github.com/ROCm/ATOM.git
(
    cd ATOM
    export SETUPTOOLS_SCM_PRETEND_VERSION="$VER"
    # Default is off; mesh needs Rust/cargo and is optional for serving.
    export ATOM_MESH_BUILD="${ATOM_MESH_BUILD:-0}"

    pip wheel . -v --no-cache-dir --no-deps --no-build-isolation -w "$WHEELS_DIR/"
)
rm -rf ATOM

echo "==> ATOM wheel(s):"
ls -la "$WHEELS_DIR"/atom-*.whl
