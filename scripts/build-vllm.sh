#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "==> Building vLLM ${VLLM_VERSION}"

export MAX_JOBS="${MAX_JOBS:-2}"

pip install wheel setuptools cmake ninja packaging setuptools-scm

git clone --branch "v${VLLM_VERSION}" --depth 1 \
    https://github.com/vllm-project/vllm.git
(
    cd vllm

    if [ "$GPU_BACKEND" = "rocm" ]; then
        export VLLM_TARGET_DEVICE=rocm

        pip install -r requirements/rocm.txt

        # Install pre-built dependency wheels from our wheels dir if available
        for dep in flash_attn aiter amdsmi; do
            whl=$(find "$WHEELS_DIR" -name "${dep}-*.whl" 2>/dev/null | head -1)
            if [ -n "$whl" ]; then
                echo "==> Installing dependency: $whl"
                pip install "$whl"
            fi
        done
    else
        pip install -r requirements/build/cuda.txt
    fi

    python3 setup.py bdist_wheel --dist-dir="$WHEELS_DIR/"
)
rm -rf vllm
