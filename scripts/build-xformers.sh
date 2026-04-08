#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "==> Building xformers ${XFORMERS_VERSION}"

export MAX_JOBS="${MAX_JOBS:-2}"

pip install wheel setuptools cmake ninja packaging

git clone --recurse-submodules --branch "v${XFORMERS_VERSION}" --depth 1 \
    https://github.com/facebookresearch/xformers.git
(
    cd xformers
    BUILD_VERSION="${XFORMERS_VERSION}" FORCE_CUDA=1 \
        pip wheel . -v --no-cache-dir --no-deps --no-build-isolation -w "$WHEELS_DIR/"
)
rm -rf xformers
