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

pip wheel "$AMDSMI_DIR" --no-cache-dir --no-deps --wheel-dir="$WHEELS_DIR/"
