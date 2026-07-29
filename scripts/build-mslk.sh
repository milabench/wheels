#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "==> Building MSLK ${MSLK_VERSION} (${ACCEL_SHORT})"

export MAX_JOBS="${MAX_JOBS:-2}"
# BUILD_FROM_NOVA=0: build package name "mslk" with +cuXXX / +rocmX.Y local version.
# (Unset → mslk-cuda / mslk-rocm; =1 → Nova wheel step no-op.)
export BUILD_FROM_NOVA=0
export FORCE_CUDA=1

pip install wheel setuptools cmake ninja packaging scikit-build \
    "setuptools_git_versioning>=3.0.0" tabulate pyyaml jinja2 numpy

TAG="v${MSLK_VERSION#v}"
git clone --branch "$TAG" --depth 1 \
    https://github.com/meta-pytorch/MSLK.git mslk-src
(
    cd mslk-src
    git submodule sync
    git submodule update --init --recursive --depth 1

    BUILD_ARGS=(
        --build-variant="$GPU_BACKEND"
        --package_channel=release
        --dist-dir="$WHEELS_DIR/"
    )

    if [ "$GPU_BACKEND" = "rocm" ]; then
        export BUILD_ROCM_VERSION="${ROCM_VERSION}"
        # setup.py accepts -D* cmake flags after its own args
        AMDGPU_TARGETS="${PYTORCH_ROCM_ARCH//;/,}"
        BUILD_ARGS+=(
            "-DAMDGPU_TARGETS=${AMDGPU_TARGETS}"
            "-DHIP_ROOT_DIR=${HIP_ROOT_DIR:-/opt/rocm}"
        )
    fi

    python3 setup.py bdist_wheel "${BUILD_ARGS[@]}"
)
rm -rf mslk-src
