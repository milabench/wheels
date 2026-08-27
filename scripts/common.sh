#!/bin/bash
# Shared configuration loader for build scripts.
# Reads .env defaults and computes derived version strings.
# Supports GPU_BACKEND=cuda (default) or GPU_BACKEND=rocm.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

# Load .env line-by-line; skip vars already set in the environment
# so that CI / Makefile overrides take precedence.
if [ -f "$ENV_FILE" ]; then
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        if [ -z "${!key+x}" ]; then
            export "$key=$value"
        fi
    done < "$ENV_FILE"
fi

export GPU_BACKEND="${GPU_BACKEND:-cuda}"

# PyTorch version strings (backend-independent)
TORCH_MAJOR="${PYTORCH_VERSION%%.*}"
_rest="${PYTORCH_VERSION#*.}"
TORCH_MINOR="${_rest%%.*}"

export PT_VER="pt${TORCH_MAJOR}${TORCH_MINOR}"
export TORCH_SHORT="${TORCH_MAJOR}.${TORCH_MINOR}"

# Backend-specific derived strings
if [ "$GPU_BACKEND" = "rocm" ]; then
    ROCM_MAJOR="${ROCM_VERSION%%.*}"
    ROCM_MINOR="${ROCM_VERSION#*.}"
    ROCM_MINOR="${ROCM_MINOR%%.*}"
    export ROCM_SHORT="rocm${ROCM_MAJOR}.${ROCM_MINOR}"
    export ACCEL_SHORT="${ROCM_SHORT}"

    # Prefer the AMD toolkit over Ubuntu's stale hipcc (5.7.x) package.
    export ROCM_PATH="${ROCM_PATH:-/opt/rocm}"
    export ROCM_HOME="${ROCM_HOME:-$ROCM_PATH}"
    export HIP_PATH="${HIP_PATH:-$ROCM_PATH}"
    # Many CUDA-oriented build systems look for CUDA_HOME; on ROCm it should
    # point at the HIP toolkit so hipcc is used instead of nvcc.
    export CUDA_HOME="${CUDA_HOME:-$ROCM_PATH}"
    export PATH="${ROCM_PATH}/bin:${PATH}"
    # xformers (and similar) only take the HIP build path when a GPU is
    # present or HIP_ARCHITECTURES is set — CI runners are CPU-only.
    if [ -z "${HIP_ARCHITECTURES:-}" ] && [ -n "${PYTORCH_ROCM_ARCH:-}" ]; then
        # xformers splits HIP_ARCHITECTURES on whitespace; PYTORCH_ROCM_ARCH
        # uses semicolons.
        export HIP_ARCHITECTURES="${PYTORCH_ROCM_ARCH//; / }"
        export HIP_ARCHITECTURES="${HIP_ARCHITECTURES//;/ }"
    fi
    # flash-attn / aiter use GPU_ARCHS (semicolon-separated); "native" probes a GPU.
    if [ -z "${GPU_ARCHS:-}" ] && [ -n "${PYTORCH_ROCM_ARCH:-}" ]; then
        export GPU_ARCHS="${PYTORCH_ROCM_ARCH}"
    fi
    # CMake enable_language(HIP) probes the host for a default arch; CPU-only
    # CI has none, so pass CMAKE_HIP_ARCHITECTURES explicitly (semicolon list).
    if [ -z "${CMAKE_HIP_ARCHITECTURES:-}" ] && [ -n "${PYTORCH_ROCM_ARCH:-}" ]; then
        export CMAKE_HIP_ARCHITECTURES="${PYTORCH_ROCM_ARCH}"
    fi
elif [ "$GPU_BACKEND" = "xpu" ]; then
    export ACCEL_SHORT="xpu"
    # Source oneAPI environment only if not already initialized.
    # ci-install-oneapi.sh exports ONEAPI_SETVARS_COMPLETED=1 via GITHUB_ENV when done,
    # so CI build steps skip this. For local builds it runs once on first source.
    # set +eu guard: setvars.sh references vars that may be unset, and with set -u
    # active in the parent shell the unbound-variable error would propagate through
    # `source` and exit the parent before `|| true` has a chance to catch it.
    if [ -z "${ONEAPI_SETVARS_COMPLETED:-}" ]; then
        ONEAPI_SETVARS="${ONEAPI_ROOT:-/opt/intel/oneapi}/setvars.sh"
        if [ -f "$ONEAPI_SETVARS" ]; then
            set +eu
            source "$ONEAPI_SETVARS" --force 2>/dev/null || true
            set -eu
        fi
    fi
    # Optional AOT SYCL compilation targets (e.g. "pvc" for Data Center GPU Max,
    # "acm-g10" for Arc A770). Without this, SYCL JIT-compiles at first run on any Intel GPU.
    export XPU_AOT_DEVLIST="${XPU_AOT_DEVLIST:-}"
    export USE_AOT_DEVLIST="${XPU_AOT_DEVLIST}"
else
    CUDA_MAJOR="${CUDA_VERSION%%.*}"
    _rest="${CUDA_VERSION#*.}"
    CUDA_MINOR="${_rest%%.*}"
    export CUDA_SHORT="cu${CUDA_MAJOR}${CUDA_MINOR}"
    export WHEEL_CUDA_VERSION="${CUDA_MAJOR}"
    export ACCEL_SHORT="${CUDA_SHORT}"
fi

export WHEELS_DIR="${WHEELS_DIR:-${ROOT_DIR}/wheels}"
mkdir -p "$WHEELS_DIR"

# CI: enforce Ubuntu 22.04 + not past EOL (local builds skip unless forced).
if [ -n "${GITHUB_ACTIONS:-}" ] || [ "${WHEELS_ASSERT_BUILD_OS:-}" = "1" ]; then
    bash "${SCRIPT_DIR}/ci-assert-build-os.sh"
fi
