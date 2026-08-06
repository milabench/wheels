#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [ "$GPU_BACKEND" != "rocm" ]; then
    echo "==> Skipping MORI (ROCm-only package)"
    exit 0
fi

echo "==> Building MORI ${MORI_VERSION}"

export MAX_JOBS="${MAX_JOBS:-2}"
# Prefer explicit MORI_GPU_ARCHS; else the CI/shared ROCm arch list.
export MORI_GPU_ARCHS="${MORI_GPU_ARCHS:-${PYTORCH_ROCM_ARCH:-}}"
echo "  MORI_GPU_ARCHS=${MORI_GPU_ARCHS}"

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# Headers / libs required by MORI's CMake configure (not bundled in the wheel).
$SUDO apt-get update
$SUDO apt-get install -y --no-install-recommends \
    libpci-dev \
    libibverbs-dev \
    ibverbs-utils \
    libnuma-dev

pip install \
    wheel \
    "setuptools>=61" \
    "setuptools_scm[toml]>=6.2" \
    cmake \
    ninja \
    packaging \
    pybind11 \
    "Cython>=3.0"

TAG="${MORI_VERSION}"
git clone --branch "$TAG" --depth 1 https://github.com/ROCm/mori.git
(
    cd mori
    git submodule sync
    git submodule update --init --recursive

    # Shallow tag clones confuse setuptools_scm; pin from the tag name.
    export SETUPTOOLS_SCM_PRETEND_VERSION="${TAG#v}"

    python3 setup.py bdist_wheel --dist-dir="$WHEELS_DIR/"
)
rm -rf mori

echo "==> MORI wheel(s):"
ls -la "$WHEELS_DIR"/amd_mori-*.whl
