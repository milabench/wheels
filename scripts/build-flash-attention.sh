#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "==> Building flash-attention ${FLASH_ATTN_VERSION}"

pip install wheel setuptools ninja packaging

git clone --recurse-submodules --branch "v${FLASH_ATTN_VERSION}" --depth 1 \
    https://github.com/Dao-AILab/flash-attention.git
(
    cd flash-attention
    export FLASH_ATTENTION_FORCE_CXX11_ABI="TRUE"
    export MAX_JOBS=2
    export NVCC_THREADS=2
    export FLASH_ATTENTION_FORCE_BUILD="TRUE"
    export FLASH_ATTN_LOCAL_VERSION="cu${WHEEL_CUDA_VERSION}torch${TORCH_SHORT}cxx11abiTRUE"

    pip wheel . -v --no-cache-dir --no-deps --no-build-isolation -w "$WHEELS_DIR/"
)
rm -rf flash-attention
