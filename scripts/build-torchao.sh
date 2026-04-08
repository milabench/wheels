#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "==> Building torchao ${TORCHAO_VERSION}"

export MAX_JOBS="${MAX_JOBS:-2}"

pip install wheel setuptools cmake ninja packaging

git clone --recurse-submodules --branch "v${TORCHAO_VERSION}" --depth 1 \
    https://github.com/pytorch/ao.git
(
    cd ao
    FORCE_CUDA=1 VERSION_SUFFIX="+${CUDA_SHORT}" \
        pip wheel . -v --no-cache-dir --no-deps --no-build-isolation -w "$WHEELS_DIR/"
)
rm -rf ao
