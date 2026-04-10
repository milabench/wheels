#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "==> Building flash-attention-4 (${FLASH_ATTN_4_TAG})"

# FA4 is a pure Python package that JIT-compiles CuTe DSL kernels at runtime.
# Build process mirrors Dao-AILab/flash-attention publish-fa4.yml.

pip install build

FA4_VERSION="${FLASH_ATTN_4_TAG#fa4-v}"

git clone --depth 1 --branch "${FLASH_ATTN_4_TAG}" \
    https://github.com/Dao-AILab/flash-attention.git /tmp/flash-attention-4

SETUPTOOLS_SCM_PRETEND_VERSION="${FA4_VERSION}" \
    python -m build /tmp/flash-attention-4/flash_attn/cute --wheel --outdir "$WHEELS_DIR"

rm -rf /tmp/flash-attention-4

echo "Built wheel:"
ls "$WHEELS_DIR"/flash_attn_4-*.whl
