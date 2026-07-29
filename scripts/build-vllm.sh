#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "==> Building vLLM ${VLLM_VERSION} (${ACCEL_SHORT})"

export MAX_JOBS="${MAX_JOBS:-2}"
export FORCE_CUDA=1
# Force an explicit local version so CUDA/ROCm is not left implicit in the
# wheel tag (vLLM only appends +cuXXX when CUDA != VLLM_MAIN_CUDA_VERSION).
export VLLM_VERSION_OVERRIDE="${VLLM_VERSION}+${ACCEL_SHORT}"

pip install wheel setuptools cmake ninja packaging setuptools-scm jinja2 regex build

git clone --branch "v${VLLM_VERSION}" --depth 1 \
    https://github.com/vllm-project/vllm.git
(
    cd vllm

    if [ "$GPU_BACKEND" = "rocm" ]; then
        export VLLM_TARGET_DEVICE=rocm

        # Install pre-built dependency wheels from our wheels dir if available
        for dep in flash_attn aiter amdsmi; do
            whl=$(find "$WHEELS_DIR" -name "${dep}-*.whl" 2>/dev/null | head -1)
            if [ -n "$whl" ]; then
                echo "==> Installing dependency: $whl"
                pip install "$whl"
            fi
        done

        # Build-system deps only — do not reinstall torch from requirements.
        if [ -f requirements/build/rocm.txt ]; then
            grep -viE '^(torch|torchaudio|torchvision)([=<>~!]|$)' \
                requirements/build/rocm.txt | pip install -r /dev/stdin || true
        elif [ -f requirements/rocm-build.txt ]; then
            grep -viE '^(torch|torchaudio|torchvision)([=<>~!]|$)' \
                requirements/rocm-build.txt | pip install -r /dev/stdin || true
        fi
    else
        export VLLM_TARGET_DEVICE=cuda

        # Build-system deps only — do not reinstall torch from requirements.
        if [ -f requirements/build/cuda.txt ]; then
            grep -viE '^(torch|torchaudio|torchvision)([=<>~!]|$)' \
                requirements/build/cuda.txt | pip install -r /dev/stdin || true
        elif [ -f requirements/build.txt ]; then
            grep -viE '^(torch|torchaudio|torchvision)([=<>~!]|$)' \
                requirements/build.txt | pip install -r /dev/stdin || true
        fi
    fi

    pip wheel . -v --no-cache-dir --no-deps --no-build-isolation -w "$WHEELS_DIR/"
)
rm -rf vllm
