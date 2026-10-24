#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "==> Building torch_memory_saver ${TORCH_MEMORY_SAVER_VERSION} (${ACCEL_SHORT})"

export MAX_JOBS="${MAX_JOBS:-2}"

# setup.py suffixes the .so files with the CUDA major and refuses to build without it.
export TMS_CUDA_MAJOR="${TMS_CUDA_MAJOR:-${CUDA_VERSION%%.*}}"

pip install wheel setuptools packaging ninja

TAG="v${TORCH_MEMORY_SAVER_VERSION#v}"
git clone --branch "$TAG" --depth 1 \
    https://github.com/fzyzcjy/torch_memory_saver.git torch-memory-saver-src
(
    cd torch-memory-saver-src
    pip wheel . -v --no-cache-dir --no-deps --no-build-isolation -w "$WHEELS_DIR/"
)
rm -rf torch-memory-saver-src

echo "Built wheel:"
ls "$WHEELS_DIR"/torch_memory_saver-*.whl
