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

# Job containers usually run as root — sudo is unnecessary / may be missing.
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

$SUDO mkdir -p --mode=0755 /etc/apt/keyrings
curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key \
    | $SUDO gpg --dearmor -o /etc/apt/keyrings/rocm.gpg

CODENAME="$(lsb_release -cs)"
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION} ${CODENAME} main" \
    | $SUDO tee /etc/apt/sources.list.d/rocm.list

# Prefer AMD packages when Ubuntu ships overlapping names (hipcc, etc.).
$SUDO tee /etc/apt/preferences.d/rocm-pin-600 >/dev/null <<'EOF'
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF

$SUDO apt-get update

# Free more space — rocm-hip-sdk is large on GitHub-hosted runners.
$SUDO rm -rf \
    /usr/share/dotnet \
    /usr/local/lib/android \
    /opt/ghc \
    /opt/hostedtoolcache/CodeQL \
    /usr/local/.ghcup \
    /usr/share/swift \
    /usr/local/share/powershell \
    || true

# Full HIP + ML development stacks. rocm-hip-sdk alone omits MIOpen, which
# torch's LoadHIP.cmake and packages like vllm/mslk require at configure time.
PKGS=(rocm-hip-sdk rocm-ml-sdk rocm-cmake)

if [ "$WITH_AMDSMI" -eq 1 ]; then
    PKGS+=(rocm-smi-lib amd-smi-lib)
fi

$SUDO apt-get install -y "${PKGS[@]}"

# Make the toolkit visible to later workflow steps.
if [ -n "${GITHUB_PATH:-}" ]; then
    echo "/opt/rocm/bin" >> "$GITHUB_PATH"
fi
if [ -n "${GITHUB_ENV:-}" ]; then
    {
        echo "ROCM_PATH=/opt/rocm"
        echo "ROCM_HOME=/opt/rocm"
        echo "HIP_PATH=/opt/rocm"
        echo "CUDA_HOME=/opt/rocm"
    } >> "$GITHUB_ENV"
fi

echo "==> ROCm ${ROCM_VERSION} installed (rocm-hip-sdk + rocm-ml-sdk)"
command -v hipcc
hipcc --version || true
df -h / | tail -1
ls /opt/rocm/include/hipsolver/hipsolver.h \
    /opt/rocm/include/hipsparse/hipsparse.h \
    /opt/rocm/include/hipblaslt/hipblaslt-ext.hpp \
    /opt/rocm/include/thrust/complex.h \
    /opt/rocm/include/miopen/miopen.h \
    2>/dev/null || true
