#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "==> Building torch_memory_saver ${TORCH_MEMORY_SAVER_VERSION} @ ${TORCH_MEMORY_SAVER_REF:0:8} (${ACCEL_SHORT})"

export MAX_JOBS="${MAX_JOBS:-2}"

# setup.py suffixes the .so files with the CUDA major and refuses to build without it.
export TMS_CUDA_MAJOR="${TMS_CUDA_MAJOR:-${CUDA_VERSION%%.*}}"

pip install wheel setuptools packaging ninja

# Pinned to a commit (the slime fork has no tags): shallow-fetch just that ref.
mkdir torch-memory-saver-src
git -C torch-memory-saver-src init -q
git -C torch-memory-saver-src remote add origin "${TORCH_MEMORY_SAVER_REPO}"
git -C torch-memory-saver-src fetch -q --depth 1 origin "${TORCH_MEMORY_SAVER_REF}"
git -C torch-memory-saver-src checkout -q FETCH_HEAD
(
    cd torch-memory-saver-src
    pip wheel . -v --no-cache-dir --no-deps --no-build-isolation -w "$WHEELS_DIR/"
)
rm -rf torch-memory-saver-src

echo "Built wheel:"
ls "$WHEELS_DIR"/torch_memory_saver-*.whl
