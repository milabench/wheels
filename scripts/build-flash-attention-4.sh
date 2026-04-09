#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "==> Building flash-attention 4 (${FLASH_ATTN_4_TAG})"

export MAX_JOBS="${MAX_JOBS:-2}"

pip install wheel setuptools ninja packaging

git clone --recurse-submodules --branch "${FLASH_ATTN_4_TAG}" --depth 1 \
    https://github.com/Dao-AILab/flash-attention.git
(
    cd flash-attention
    export FLASH_ATTENTION_FORCE_CXX11_ABI="TRUE"
    export NVCC_THREADS=2
    export FLASH_ATTENTION_FORCE_BUILD="TRUE"
    export FLASH_ATTN_LOCAL_VERSION="cu${WHEEL_CUDA_VERSION}torch${TORCH_SHORT}cxx11abiTRUE"

    pip wheel . -v --no-cache-dir --no-deps --no-build-isolation -w "$WHEELS_DIR/"
)
rm -rf flash-attention
