#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "==> Building transformer-engine ${TRANSFORMER_ENGINE_VERSION} (${ACCEL_SHORT})"

export MAX_JOBS="${MAX_JOBS:-2}"
export NVTE_FRAMEWORK=pytorch
export NVTE_BUILD_THREADS_PER_JOB=1
# NCCL EP needs extra submodules/NCCL headers and is not used by milabench.
export NVTE_WITH_NCCL_EP=0

# Arch list: leave NVTE_CUDA_ARCHS unset to use TE's own default for the toolkit
# (CUDA 13: 75;80;89;90;100;120). Deriving it from TORCH_CUDA_ARCH_LIST breaks:
# TE only understands bare family heads (100, 120) and splits them into generic
# + 100a/120f itself, so extras like 12.1 get built as plain archs and fail the
# family-specific PTX static_assert. Override explicitly via NVTE_CUDA_ARCHS if needed.

pip install wheel setuptools cmake ninja packaging pybind11 pydantic \
    einops onnx onnxscript nvdlfw-inspect "nvidia-cudnn-frontend>=1.29.0"

# cuDNN (and fallback NVTX) headers come with the torch wheel's nvidia-* dependencies.
# CUDA 13 wheels use a shared nvidia/cu13/include; CUDA 12 uses nvidia/cudnn/include.
find_pip_header() {
    python3 - "$1" <<'PY'
import glob, os, site, sys
for r in site.getsitepackages() + [site.getusersitepackages()]:
    for h in glob.glob(os.path.join(r, "nvidia", "**", sys.argv[1]), recursive=True):
        print(os.path.dirname(h)[: -len(os.path.dirname(sys.argv[1])) - 1] if os.path.dirname(sys.argv[1]) else os.path.dirname(h))
        sys.exit(0)
PY
}
if [ -z "${CUDNN_PATH:-}" ]; then
    CUDNN_INC_DIR="$(find_pip_header cudnn.h || true)"
    [ -n "$CUDNN_INC_DIR" ] && export CUDNN_PATH="$(dirname "$CUDNN_INC_DIR")"
fi
PIP_NVTX_INC="$(find_pip_header nvtx3/nvToolsExt.h || true)"
if [ -n "$PIP_NVTX_INC" ]; then
    export CPATH="${PIP_NVTX_INC}${CPATH:+:$CPATH}"
fi
# The PyTorch extension includes nccl.h (USE_C10D_NCCL); use the same NCCL torch ships.
PIP_NCCL_INC="$(find_pip_header nccl.h || true)"
if [ -n "$PIP_NCCL_INC" ]; then
    export CPATH="${PIP_NCCL_INC}${CPATH:+:$CPATH}"
fi

# The CI toolkit install only has nvcc + libraries-dev; TE also needs the NVML and
# NVTX headers (nvml.h, nvtx3/nvToolsExt.h). Install them from the CUDA apt repo
# (already configured by the toolkit step); local builds with a full toolkit skip this.
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
CUDA_APT_VER="$(echo "${CUDA_VERSION}" | cut -d. -f1,2 | tr . -)"
if [ ! -f "${CUDA_HOME}/include/nvml.h" ] || [ ! -f "${CUDA_HOME}/include/nvtx3/nvToolsExt.h" ]; then
    if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
    $SUDO apt-get update
    $SUDO apt-get install -y --no-install-recommends \
        "cuda-nvml-dev-${CUDA_APT_VER}" "cuda-nvtx-${CUDA_APT_VER}" || \
        echo "::warning::apt install of nvml/nvtx dev packages failed"
fi

# Fail in seconds, not after an hour of compiling, if a required header is missing.
CUDNN_INC=""
[ -n "${CUDNN_PATH:-}" ] && CUDNN_INC="${CUDNN_PATH}/include"
missing=0
for h in cuda_runtime.h cuda_fp8.h nvml.h nvtx3/nvToolsExt.h nvrtc.h cublasLt.h; do
    if [ ! -f "${CUDA_HOME}/include/${h}" ] && [ ! -f "${PIP_NVTX_INC:-/nonexistent}/${h}" ]; then
        echo "::error::missing ${h} under ${CUDA_HOME}/include"
        missing=1
    fi
done
if [ ! -f "${CUDNN_INC}/cudnn.h" ] && [ -z "$(find_pip_header cudnn.h || true)" ]; then
    echo "::error::missing cudnn.h (CUDNN_PATH=${CUDNN_PATH:-unset})"
    missing=1
fi
if [ ! -f "${CUDA_HOME}/include/nccl.h" ] && [ -z "$PIP_NCCL_INC" ]; then
    echo "::error::missing nccl.h (not in ${CUDA_HOME}/include or pip nvidia-nccl)"
    missing=1
fi
[ "$missing" -eq 0 ] || exit 1

TAG="v${TRANSFORMER_ENGINE_VERSION#v}"
git clone --branch "$TAG" --depth 1 \
    https://github.com/NVIDIA/TransformerEngine.git transformer-engine-src
(
    cd transformer-engine-src
    git submodule sync
    git submodule update --init --recursive --depth 1

    pip wheel . -v --no-cache-dir --no-deps --no-build-isolation -w "$WHEELS_DIR/"
)
rm -rf transformer-engine-src

echo "Built wheel:"
ls "$WHEELS_DIR"/transformer_engine-*.whl
