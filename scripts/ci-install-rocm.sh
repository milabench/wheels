#!/bin/bash
# Install ROCm toolkit packages for CI wheel builds.
# Usage: bash scripts/ci-install-rocm.sh <rocm-version> [--with-amdsmi]
#
# Prefers AMD's apt packages over Ubuntu's stale hipcc (5.7.x) and exports
# ROCM/HIP paths for subsequent steps when running under GitHub Actions.
set -euo pipefail

ROCM_VERSION="${1:?Usage: $0 <rocm-version> [--with-amdsmi]}"
shift || true

WITH_AMDSMI=0
for arg in "$@"; do
    case "$arg" in
        --with-amdsmi) WITH_AMDSMI=1 ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

sudo mkdir -p --mode=0755 /etc/apt/keyrings
curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key \
    | sudo gpg --dearmor -o /etc/apt/keyrings/rocm.gpg

CODENAME="$(lsb_release -cs)"
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION} ${CODENAME} main" \
    | sudo tee /etc/apt/sources.list.d/rocm.list

# Prefer AMD packages when Ubuntu ships overlapping names (hipcc, etc.).
sudo tee /etc/apt/preferences.d/rocm-pin-600 >/dev/null <<'EOF'
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF

sudo apt-get update

# Core HIP build stack + headers pulled in by torch ATen HIP and package
# extensions (torchao / PyG / xformers / aiter).
PKGS=(
    hipcc
    hip-dev
    rocm-hip-runtime-dev
    rocm-cmake
    hipblas-dev
    hipblaslt-dev
    hipsparse-dev
    hipsolver-dev
    hipfft-dev
    hiprand-dev
    rocblas-dev
    rocsolver-dev
    rocthrust-dev
    hipcub-dev
    rocprim-dev
    rocm-device-libs
)

if [ "$WITH_AMDSMI" -eq 1 ]; then
    PKGS+=(rocm-smi-lib amd-smi-lib)
fi

sudo apt-get install -y "${PKGS[@]}"

# Make the toolkit visible to later workflow steps.
if [ -n "${GITHUB_PATH:-}" ]; then
    echo "/opt/rocm/bin" >> "$GITHUB_PATH"
fi
if [ -n "${GITHUB_ENV:-}" ]; then
    {
        echo "ROCM_PATH=/opt/rocm"
        echo "HIP_PATH=/opt/rocm"
        echo "CUDA_HOME=/opt/rocm"
    } >> "$GITHUB_ENV"
fi

echo "==> ROCm ${ROCM_VERSION} installed"
command -v hipcc
hipcc --version || true
ls /opt/rocm/include/thrust/complex.h \
    /opt/rocm/include/hipblaslt/hipblaslt-ext.hpp \
    /opt/rocm/include/hipsparse/hipsparse.h \
    2>/dev/null || true
