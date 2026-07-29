#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [ "$GPU_BACKEND" != "rocm" ]; then
    echo "==> Skipping amdsmi (ROCm-only package)"
    exit 0
fi

AMDSMI_DIR="/opt/rocm/share/amd_smi"
if [ ! -d "$AMDSMI_DIR" ]; then
    echo "ERROR: $AMDSMI_DIR not found. Is ROCm installed?" >&2
    exit 1
fi

echo "==> Building amdsmi from ${AMDSMI_DIR}"

pip install wheel setuptools

# ROCm ships amd_smi under /opt/rocm with root-owned / read-only files.
# Building in-place fails with "Operation not permitted" when setuptools
# copies LICENSE into build/lib. Work from a writable copy instead.
BUILD_SRC="$(mktemp -d)"
trap 'rm -rf "$BUILD_SRC"' EXIT
cp -a "$AMDSMI_DIR"/. "$BUILD_SRC/"
chmod -R u+rwX "$BUILD_SRC"

pip wheel "$BUILD_SRC" --no-cache-dir --no-deps --no-build-isolation \
    --wheel-dir="$WHEELS_DIR/"
