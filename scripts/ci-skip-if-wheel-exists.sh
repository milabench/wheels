#!/bin/bash
# Return skip=true (via GITHUB_OUTPUT) when the release already has the wheel
# we would build for PACKAGE at RELEASE_TAG.
#
# Matches the artifact naming conventions in scripts/build-*.sh and .env
# version pins — not just package prefix + CPU arch.
#
# Usage: ci-skip-if-wheel-exists.sh <package> <release-tag>
#
# Required env (set by workflow before calling):
#   GPU_BACKEND=rocm|cuda
#   PYTORCH_VERSION
#   ROCM_VERSION   (rocm builds)
#   CUDA_VERSION   (cuda builds)
#
# Optional env:
#   TORCHAO_VERSION — torchao matrix override (defaults to .env)
set -euo pipefail

PACKAGE="${1:?Usage: $0 <package> <release-tag>}"
RELEASE_TAG="${2:?Usage: $0 <package> <release-tag>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Skip OS assert here; this runs before heavy setup and only queries GitHub.
WHEELS_ASSERT_BUILD_OS=0 source "${SCRIPT_DIR}/common.sh"

ARCH=$(uname -m)
ASSETS=$(gh release view "$RELEASE_TAG" --json assets -q '.assets[].name' 2>/dev/null || echo "")

asset_has_arch() {
    echo "$ASSETS" | grep -F "$1" | grep -q "$ARCH"
}

asset_has() {
    echo "$ASSETS" | grep -Fq "$1"
}

emit_skip() {
    local label="$1"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        echo "skip=true" >> "$GITHUB_OUTPUT"
    fi
    echo "::notice::${label} wheel already exists in release ${RELEASE_TAG}, skipping build"
}

case "$PACKAGE" in
    xformers)
        needle="xformers-${XFORMERS_VERSION}-"
        if asset_has_arch "$needle"; then
            emit_skip "xformers ${XFORMERS_VERSION} (${ARCH})"
        fi
        ;;

    pytorch_cluster|pytorch_sparse|pytorch_scatter|pyg_lib)
        case "$PACKAGE" in
            pytorch_cluster) VER="${PYTORCH_CLUSTER_VERSION}"; PREFIX="torch_cluster" ;;
            pytorch_sparse)  VER="${PYTORCH_SPARSE_VERSION}";  PREFIX="torch_sparse" ;;
            pytorch_scatter) VER="${PYTORCH_SCATTER_VERSION}"; PREFIX="torch_scatter" ;;
            pyg_lib)         VER="${PYG_LIB_VERSION}";         PREFIX="pyg_lib" ;;
        esac
        needle="${PREFIX}-${VER}+${PT_VER}${ACCEL_SHORT}-"
        if asset_has_arch "$needle"; then
            emit_skip "${PREFIX} ${VER}+${PT_VER}${ACCEL_SHORT} (${ARCH})"
        fi
        ;;

    torchao)
        VER="${TORCHAO_VERSION:?TORCHAO_VERSION required for torchao skip check}"
        if echo "$ASSETS" | grep -E "^torchao-${VER}([+-]|$)" | grep -q "$ARCH"; then
            emit_skip "torchao ${VER} (${ARCH})"
        fi
        ;;

    flash-attention)
        VER="${FLASH_ATTN_VERSION}"
        # flash-attn lowercases the local tag (cxx11abitrue, not cxx11abiTRUE).
        if [ "$GPU_BACKEND" = "rocm" ]; then
            LOCAL="${ACCEL_SHORT}torch${TORCH_SHORT}cxx11abitrue"
        else
            LOCAL="cu${WHEEL_CUDA_VERSION}torch${TORCH_SHORT}cxx11abitrue"
        fi
        needle="flash_attn-${VER}+${LOCAL}-"
        if echo "$ASSETS" | grep -F "$needle" | grep -v "flash_attn_4" | grep -q "$ARCH"; then
            emit_skip "flash-attention ${VER}+${LOCAL} (${ARCH})"
        fi
        ;;

    flash-attention-4)
        VER="${FLASH_ATTN_4_TAG#fa4-v}"
        if asset_has "flash_attn_4-${VER}-"; then
            emit_skip "flash-attention-4 ${VER} (py3-none-any)"
        fi
        ;;

    torchtitan)
        # Version lives in the repo (assets/version.txt), not .env, and the pin
        # is a git ref -- so treat any torchtitan py3-none-any wheel as present.
        # Use --override-previous to force a rebuild when TORCHTITAN_REF moves.
        if echo "$ASSETS" | grep -qE '^torchtitan-.*-py3-none-any\.whl$'; then
            emit_skip "torchtitan (py3-none-any)"
        fi
        ;;

    aiter)
        VER="${AITER_VERSION#v}"
        if asset_has_arch "amd_aiter-${VER}-"; then
            emit_skip "aiter amd_aiter-${VER} (${ARCH})"
        elif asset_has_arch "aiter-${VER}-"; then
            emit_skip "aiter ${VER} (${ARCH})"
        fi
        ;;

    mori)
        VER="${MORI_VERSION#v}"
        if asset_has_arch "amd_mori-${VER}-"; then
            emit_skip "mori amd_mori-${VER} (${ARCH})"
        fi
        ;;

    amdsmi)
        # Version comes from the ROCm toolkit at build time; one wheel per release tag.
        if echo "$ASSETS" | grep -qE '^amdsmi-.*-py3-none-any\.whl$'; then
            emit_skip "amdsmi (py3-none-any)"
        fi
        ;;

    atom)
        VER="${ATOM_VERSION#v}"
        if asset_has "atom-${VER}-py3-none-any.whl"; then
            emit_skip "atom ${VER} (py3-none-any)"
        fi
        ;;

    vllm)
        # CUDA resolves the vLLM version from torch (highest compatible build);
        # ROCm and XPU keep their backend-specific pin from the environment/.env.
        VER="${VLLM_VERSION}"
        if [ "$GPU_BACKEND" = "cuda" ]; then
            VER="$(python3 "${SCRIPT_DIR}/resolve-vllm-version.py" \
                --torch "$PYTORCH_VERSION" --fallback "${VLLM_VERSION:-}")"
        fi
        needle="vllm-${VER}+${ACCEL_SHORT}-"
        if asset_has_arch "$needle"; then
            emit_skip "vllm ${VER}+${ACCEL_SHORT} (${ARCH})"
        fi
        ;;

    mslk)
        VER="${MSLK_VERSION#v}"
        # MSLK local version includes ROCm patch (e.g. +rocm7.2.26015), not +rocm7.2-
        if [ "$GPU_BACKEND" = "rocm" ]; then
            local_tag="rocm${ROCM_MAJOR}.${ROCM_MINOR}"
        else
            local_tag="${ACCEL_SHORT}"
        fi
        needle="mslk-${VER}+${local_tag}"
        if asset_has_arch "$needle"; then
            emit_skip "mslk ${VER}+${local_tag} (${ARCH})"
        fi
        ;;

    *)
        echo "::error::Unknown package for skip check: ${PACKAGE}" >&2
        exit 1
        ;;
esac
