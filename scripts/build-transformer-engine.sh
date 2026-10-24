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

# cuDNN headers/libs come with the torch wheel's nvidia-cudnn-cu* dependency.
if [ -z "${CUDNN_PATH:-}" ]; then
    CUDNN_PATH="$(python3 -c 'import nvidia.cudnn, os; print(os.path.dirname(nvidia.cudnn.__file__))' 2>/dev/null || true)"
    export CUDNN_PATH
fi

# NVTX headers (nvtx3/nvToolsExt.h) are not in the CI toolkit's nvcc/libraries-dev
# sub-packages; use the ones shipped by the torch wheel's nvidia-nvtx dependency.
NVTX_INCLUDE="$(python3 - <<'PY'
import glob, os, site, sys
roots = site.getsitepackages() + [site.getusersitepackages()]
for r in roots:
    for h in glob.glob(os.path.join(r, "nvidia", "**", "nvtx3", "nvToolsExt.h"), recursive=True):
        print(os.path.dirname(os.path.dirname(h)))
        sys.exit(0)
PY
)"
if [ -n "$NVTX_INCLUDE" ]; then
    echo "==> Using NVTX headers from $NVTX_INCLUDE"
    export CPATH="${NVTX_INCLUDE}${CPATH:+:$CPATH}"
fi

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
