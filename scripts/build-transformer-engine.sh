#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "==> Building transformer_engine_torch ${TRANSFORMER_ENGINE_VERSION} (${ACCEL_SHORT}, torch ${PYTORCH_VERSION})"

# What this builds: only the PyTorch extension (transformer_engine_torch), the part that
# must be rebuilt per torch version. This mirrors milabench's slime benchfile, where
# `pip install transformer-engine[pytorch]==X` compiles transformer_engine_torch from the
# PyPI sdist. The heavy core library (libtransformer_engine.so) is NOT built here: it is
# the prebuilt, torch-independent `transformer_engine_cu12/cu13` wheel on PyPI.

export MAX_JOBS="${MAX_JOBS:-2}"
# Without this the extension is compiled with -DNVTE_WITH_NCCL_EP and needs nccl_ep.h.
export NVTE_WITH_NCCL_EP=0
# The sdist first tries to download a prebuilt wheel from NVIDIA's GitHub release (it never
# exists for our torch); force the source build.
export NVTE_PYTORCH_FORCE_BUILD=TRUE

pip install wheel setuptools cmake ninja packaging pybind11

# Headers the extension includes that the CI toolkit install (nvcc + libraries-dev) lacks.
# cuDNN / NCCL / NVTX come with torch's nvidia-* wheel dependencies; CUDA 13 wheels share
# nvidia/cu13/include, CUDA 12 uses one dir per library. Add every nvidia/*/include to CPATH,
# like slime's add_nvidia_wheel_paths does.
PIP_NV_INCLUDES="$(python3 - <<'PY'
import glob, os, site
dirs = []
for r in site.getsitepackages() + [site.getusersitepackages()]:
    dirs += sorted(d for d in glob.glob(os.path.join(r, "nvidia", "*", "include")) if os.path.isdir(d))
print(os.pathsep.join(dirs))
PY
)"
if [ -n "$PIP_NV_INCLUDES" ]; then
    export CPATH="${PIP_NV_INCLUDES}${CPATH:+:$CPATH}"
fi
# TE locates cuDNN / NCCL through these (same as slime).
for d in ${PIP_NV_INCLUDES//:/ }; do
    [ -f "$d/cudnn.h" ] && export CUDNN_PATH="${CUDNN_PATH:-$(dirname "$d")}"
    [ -f "$d/nccl.h" ] && export NCCL_HOME="${NCCL_HOME:-$(dirname "$d")}"
done

# nvml.h / nvtx3 are not in the pip wheels' include dirs on every layout; get them from the
# CUDA apt repo (already configured by the toolkit step) when the toolkit lacks them.
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
CUDA_APT_VER="$(echo "${CUDA_VERSION}" | cut -d. -f1,2 | tr . -)"
if [ ! -f "${CUDA_HOME}/include/nvml.h" ] || [ ! -f "${CUDA_HOME}/include/nvtx3/nvToolsExt.h" ]; then
    if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
    $SUDO apt-get update
    $SUDO apt-get install -y --no-install-recommends \
        "cuda-nvml-dev-${CUDA_APT_VER}" "cuda-nvtx-${CUDA_APT_VER}" || \
        echo "::warning::apt install of nvml/nvtx dev packages failed"
fi

# Preflight: syntax-compile every extension source from the sdist with the include roots the
# real build uses (CUDA toolkit, torch, CPATH, bundled TE headers). A missing header fails
# here in minutes with the file and header named, not deep into the real build.
SRC_DIR="$(mktemp -d)"
python3 - "$SRC_DIR" "${TRANSFORMER_ENGINE_VERSION}" <<'PY'
import json, sys, tarfile, urllib.request
dest, ver = sys.argv[1], sys.argv[2]
meta = json.load(urllib.request.urlopen(f"https://pypi.org/pypi/transformer-engine-torch/{ver}/json"))
url = next(u["url"] for u in meta["urls"] if u["packagetype"] == "sdist")
path, _ = urllib.request.urlretrieve(url, f"{dest}/sdist.tar.gz")
tarfile.open(path).extractall(dest)
PY
SDIST="$(echo "$SRC_DIR"/transformer_engine_torch-*/)"
TORCH_INCLUDES="$(python3 -c 'from torch.utils.cpp_extension import include_paths; print(" ".join("-I"+p for p in include_paths()))')"
PY_INCLUDE="-I$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["include"])')"
NPROC="$(nproc)"
if ! find "$SDIST/csrc" -name '*.cpp' -print0 | xargs -0 -P "$NPROC" -I{} \
        ${CXX:-c++} -std=c++17 -fsyntax-only -DUSE_C10D_NCCL \
        -I"${CUDA_HOME}/include" -I"$SDIST/common_headers" -I"$SDIST/common_headers/common" \
        -I"$SDIST/common_headers/common/include" -I"$SDIST/csrc" \
        ${TORCH_INCLUDES} ${PY_INCLUDE} {} ; then
    echo "::error::extension preflight failed: a header is missing (see the first error above)"
    exit 1
fi
rm -rf "$SRC_DIR"
echo "==> Extension preflight passed"

pip wheel "transformer_engine_torch==${TRANSFORMER_ENGINE_VERSION}" -v --no-cache-dir \
    --no-deps --no-build-isolation -w "$WHEELS_DIR/"

echo "Built wheel:"
ls "$WHEELS_DIR"/transformer_engine_torch-*.whl
