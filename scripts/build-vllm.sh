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

        for dep in flash_attn aiter amdsmi; do
            whl=$(find "$WHEELS_DIR" -name "${dep}-*.whl" 2>/dev/null | head -1)
            if [ -n "$whl" ]; then
                echo "==> Installing dependency: $whl"
                # --no-deps so flash_attn/etc. cannot pull a CUDA torch.
                pip install --no-deps "$whl"
            else
                echo "==> WARNING: no ${dep} wheel in ${WHEELS_DIR}"
            fi
        done
    else
        export VLLM_TARGET_DEVICE=cuda
        export FORCE_CUDA=1
    fi

    reinstall_torch

    pip wheel . -v --no-cache-dir --no-deps --no-build-isolation -w "$WHEELS_DIR/"
)
rm -rf vllm
