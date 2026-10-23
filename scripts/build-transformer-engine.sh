#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "==> Building transformer-engine ${TRANSFORMER_ENGINE_VERSION} (${ACCEL_SHORT})"

export MAX_JOBS="${MAX_JOBS:-2}"
export NVTE_FRAMEWORK=pytorch
export NVTE_BUILD_THREADS_PER_JOB=1
# NCCL EP needs extra submodules/NCCL headers and is not used by milabench.
export NVTE_WITH_NCCL_EP=0

# NVTE_CUDA_ARCHS uses "80;90" style (no dots); derive it from TORCH_CUDA_ARCH_LIST.
if [ -z "${NVTE_CUDA_ARCHS:-}" ] && [ -n "${TORCH_CUDA_ARCH_LIST:-}" ]; then
    export NVTE_CUDA_ARCHS="${TORCH_CUDA_ARCH_LIST//./}"
fi

pip install wheel setuptools cmake ninja packaging pybind11 pydantic \
    einops onnx onnxscript nvdlfw-inspect "nvidia-cudnn-frontend>=1.29.0"

# cuDNN headers/libs come with the torch wheel's nvidia-cudnn-cu* dependency.
if [ -z "${CUDNN_PATH:-}" ]; then
    CUDNN_PATH="$(python3 -c 'import nvidia.cudnn, os; print(os.path.dirname(nvidia.cudnn.__file__))' 2>/dev/null || true)"
    export CUDNN_PATH
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
