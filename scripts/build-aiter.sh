#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [ "$GPU_BACKEND" != "rocm" ]; then
    echo "==> Skipping AITER (ROCm-only package)"
    exit 0
fi

echo "==> Building AITER ${AITER_VERSION}"

export MAX_JOBS="${MAX_JOBS:-2}"

pip install wheel setuptools cmake ninja packaging pyyaml

git clone --recursive --branch "$AITER_VERSION" --depth 1 \
    https://github.com/ROCm/aiter.git
(
    cd aiter
    pip install -r requirements.txt
    PREBUILD_KERNELS=1 GPU_ARCHS="${PYTORCH_ROCM_ARCH}" \
        python3 setup.py bdist_wheel --dist-dir="$WHEELS_DIR/"
)
rm -rf aiter
