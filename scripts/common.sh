#!/bin/bash
# Shared configuration loader for build scripts.
# Reads .env defaults and computes derived version strings.

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

# Derived version strings
CUDA_MAJOR="${CUDA_VERSION%%.*}"
_rest="${CUDA_VERSION#*.}"
CUDA_MINOR="${_rest%%.*}"
TORCH_MAJOR="${PYTORCH_VERSION%%.*}"
_rest="${PYTORCH_VERSION#*.}"
TORCH_MINOR="${_rest%%.*}"

export CUDA_SHORT="cu${CUDA_MAJOR}${CUDA_MINOR}"
export PT_VER="pt${TORCH_MAJOR}${TORCH_MINOR}"
export TORCH_SHORT="${TORCH_MAJOR}.${TORCH_MINOR}"
export WHEEL_CUDA_VERSION="${CUDA_MAJOR}"

export WHEELS_DIR="${WHEELS_DIR:-${ROOT_DIR}/wheels}"
mkdir -p "$WHEELS_DIR"
