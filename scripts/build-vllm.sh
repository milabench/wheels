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

# Install a filtered requirements file without reinstalling torch.
# Keep the filtered file next to the original so relative `-r other.txt`
# includes still resolve (pip install -r /dev/stdin breaks that → /dev/...).
install_build_reqs() {
    local src="$1"
    local dst="${src}.filtered"
    # Drop torch stack pins and extra-index lines that would pull a different
    # torch build over the one CI already installed.
    grep -viE '^(torch|torchaudio|torchvision|triton)([=<>~!]|$)' "$src" \
        | grep -viE '^--extra-index-url' \
        > "$dst"
    echo "==> Installing build deps from ${dst}"
    pip install -r "$dst" || true
}

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

        if [ -f requirements/build/rocm.txt ]; then
            install_build_reqs requirements/build/rocm.txt
        elif [ -f requirements/rocm-build.txt ]; then
            install_build_reqs requirements/rocm-build.txt
        fi
    else
        export VLLM_TARGET_DEVICE=cuda

        if [ -f requirements/build/cuda.txt ]; then
            install_build_reqs requirements/build/cuda.txt
        elif [ -f requirements/build.txt ]; then
            install_build_reqs requirements/build.txt
        fi
    fi

    pip wheel . -v --no-cache-dir --no-deps --no-build-isolation -w "$WHEELS_DIR/"
)
rm -rf vllm
