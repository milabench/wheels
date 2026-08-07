#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "==> Building vLLM ${VLLM_VERSION} (${ACCEL_SHORT})"

export MAX_JOBS="${MAX_JOBS:-2}"
# Force an explicit local version so CUDA/ROCm is not left implicit in the
# wheel tag (vLLM only appends +cuXXX when CUDA != VLLM_MAIN_CUDA_VERSION).
export VLLM_VERSION_OVERRIDE="${VLLM_VERSION}+${ACCEL_SHORT}"

# Build-system packages only. Do NOT install vLLM's requirements/*.txt here:
# those pull runtime deps (and often a CUDA torch from PyPI) which breaks
# ROCm detection (setup.py requires torch.version.hip for the HIP path).
pip install \
    "cmake>=3.26.1" \
    ninja \
    "packaging>=24.2" \
    "setuptools>=77.0.3,<81.0.0" \
    "setuptools-scm>=8" \
    "setuptools-rust>=1.9.0" \
    wheel \
    "jinja2>=3.1.6" \
    regex \
    build

# Re-assert the backend torch CI already installed (guards against any
# transitive upgrade to a wrong build).
reinstall_torch() {
    echo "==> Ensuring torch==${PYTORCH_VERSION} for ${ACCEL_SHORT}"
    pip install --no-cache-dir --force-reinstall --no-deps \
        "torch==${PYTORCH_VERSION}" \
        --index-url "https://download.pytorch.org/whl/${ACCEL_SHORT}"
    python3 - <<'PY'
import torch, sys
print(f"  torch {torch.__version__} cuda={torch.version.cuda} hip={torch.version.hip}")
backend = __import__("os").environ.get("GPU_BACKEND", "cuda")
if backend == "rocm" and torch.version.hip is None:
    sys.exit("ERROR: expected ROCm torch (torch.version.hip), got a non-HIP build")
if backend == "cuda" and torch.version.cuda is None:
    sys.exit("ERROR: expected CUDA torch (torch.version.cuda), got a non-CUDA build")
PY
}

git clone --branch "v${VLLM_VERSION}" --depth 1 \
    https://github.com/vllm-project/vllm.git
(
    cd vllm

    if [ "$GPU_BACKEND" = "rocm" ]; then
        export VLLM_TARGET_DEVICE=rocm
        # Do not set FORCE_CUDA on ROCm — it is a CUDA-extension escape hatch.

        # Prefer amd_* wheel names produced by current ROCm package builds;
        # keep unprefixed names as fallbacks for older releases.
        install_rocm_dep() {
            local label=$1
            shift
            local whl="" pattern
            for pattern in "$@"; do
                whl=$(find "$WHEELS_DIR" -name "$pattern" 2>/dev/null | head -1 || true)
                if [ -n "$whl" ]; then
                    break
                fi
            done
            if [ -n "$whl" ]; then
                echo "==> Installing dependency (${label}): $whl"
                # --no-deps so flash_attn/etc. cannot pull a CUDA torch.
                pip install --no-deps "$whl"
            else
                echo "==> WARNING: no ${label} wheel in ${WHEELS_DIR}"
            fi
        }

        install_rocm_dep flash_attn "flash_attn-*.whl"
        install_rocm_dep aiter "amd_aiter-*.whl" "aiter-*.whl"
        install_rocm_dep mori "amd_mori-*.whl" "mori-*.whl"
        install_rocm_dep amdsmi "amdsmi-*.whl"
    else
        export VLLM_TARGET_DEVICE=cuda
        export FORCE_CUDA=1
    fi

    reinstall_torch

    # vLLM 0.26+ ships a Rust frontend; prebuild before pip wheel (upstream Docker flow).
    if [ -f build_rust.sh ]; then
        if [ "$(id -u)" -eq 0 ]; then
            SUDO=""
        else
            SUDO="sudo"
        fi
        if ! command -v unzip >/dev/null 2>&1; then
            echo "==> Installing unzip for protoc install"
            $SUDO apt-get update
            $SUDO apt-get install -y --no-install-recommends unzip
        fi
        echo "==> Installing pinned protoc for vLLM Rust build"
        $SUDO bash tools/install_protoc.sh
        echo "==> Prebuilding vLLM Rust frontend"
        bash build_rust.sh
    fi

    pip wheel . -v --no-cache-dir --no-deps --no-build-isolation -w "$WHEELS_DIR/"
)
rm -rf vllm
