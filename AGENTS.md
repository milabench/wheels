# Wheels Build System

Builds GPU extension wheels for milabench. Each wheel is built from source against a specific PyTorch + CUDA or ROCm version.

## File Layout

- `.env` — Single source of truth for all versions. Edit this to update package or infrastructure versions.
- `scripts/common.sh` — Loads `.env`, detects `GPU_BACKEND` (cuda/rocm), computes derived vars (`ACCEL_SHORT`, `PT_VER`, etc.), creates `wheels/` dir.
- `scripts/build-*.sh` — One script per package. Standalone: `bash scripts/build-xformers.sh`. Set `GPU_BACKEND=rocm` for ROCm builds.
- `Makefile` — Runs scripts with `.env` exported. `make all` builds everything, `make GPU_BACKEND=rocm <target>` builds for ROCm.
- `.github/workflows/build.yml` — CUDA CI workflow. Builds all wheels in parallel (x86_64 + aarch64), uploads to a GitHub release.
- `.github/workflows/build-rocm.yml` — ROCm CI workflow. Builds GPU wheels for ROCm (x86_64 only), uploads to a separate release.

## GPU Backend

Set `GPU_BACKEND` to switch between CUDA and ROCm:

| Variable | CUDA (default) | ROCm |
|---|---|---|
| `GPU_BACKEND` | `cuda` | `rocm` |
| `ACCEL_SHORT` | `cu130` | `rocm7.0` |
| PyTorch index | `whl/cu130` | `whl/rocm7.0` |
| Release tag | `torch2.10-cu130` | `torch2.10-rocm7.0` |
| Arch list env | `TORCH_CUDA_ARCH_LIST` | `PYTORCH_ROCM_ARCH` |

Build scripts use `ACCEL_SHORT` for version suffixes, making them backend-agnostic. `FORCE_CUDA=1` works for both backends (ROCm's HIP layer emulates CUDA APIs).

## How to Update a Version

1. Edit `.env` — change the version variable.
2. Done. Scripts, Makefile, and CI all read from `.env`.

CI infrastructure versions (Python, CUDA/ROCm, PyTorch) come from workflow inputs with defaults matching `.env`.

## How to Add a New Package

1. Add `NEW_PACKAGE_VERSION=X.Y.Z` to `.env`.
2. Create `scripts/build-new-package.sh`:
   - Start with `set -euo pipefail` and `source common.sh`.
   - Clone the repo, build with `pip wheel . -v --no-cache-dir --no-deps --no-build-isolation -w "$WHEELS_DIR/"`, clean up.
   - Set `MAX_JOBS="${MAX_JOBS:-2}"` to avoid OOM on CI runners.
   - Use `ACCEL_SHORT` (not `CUDA_SHORT`) for version suffixes to support both backends.
3. Add a target to `Makefile` and include it in `all`.
4. Add a job to `.github/workflows/build.yml` (CUDA) and/or `.github/workflows/build-rocm.yml` (ROCm):
   - Copy an existing build job (e.g., `build-torchao`).
   - Update the job name, check pattern (grep for wheel filename prefix), and script path.
   - The job must have `needs: [create-release]`, `if: ${{ !cancelled() }}`, and `permissions: contents: write`.
   - CUDA jobs include an arch matrix (x86_64 + aarch64). ROCm jobs are x86_64 only.

## Existing Packages

| Package | .env variable | Git tag format | Wheel prefix | Notes |
|---|---|---|---|---|
| xformers | `XFORMERS_VERSION` | `v{VERSION}` | `xformers-` | Uses `BUILD_VERSION` env var |
| pytorch_cluster | `PYTORCH_CLUSTER_VERSION` | `{VERSION}` (no v) | `torch_cluster-` | Version patched via sed in setup.py |
| pytorch_sparse | `PYTORCH_SPARSE_VERSION` | `{VERSION}` (no v) | `torch_sparse-` | Same as cluster |
| pytorch_scatter | `PYTORCH_SCATTER_VERSION` | `{VERSION}` (no v) | `torch_scatter-` | Same as cluster |
| torchao | `TORCHAO_VERSION` | `v{VERSION}` | `torchao-` | Uses `VERSION_SUFFIX` env var |
| flash-attn (FA2) | `FLASH_ATTN_VERSION` | `v{VERSION}` | `flash_attn-2` | FA2+FA3 combined |
| flash-attn-4 (FA4) | `FLASH_ATTN_4_TAG` | `fa4-v4.0.0.betaN` (full tag) | `flash_attn_4-` | Pure Python (py3-none-any), built from `flash_attn/cute/` via `python -m build`. CUDA workflow only (backend-agnostic). |

## Key Env Vars in Build Scripts

- `GPU_BACKEND` — `cuda` (default) or `rocm`. Controls which derived vars are computed.
- `ACCEL_SHORT` — Unified accelerator suffix for version strings and PyTorch index URLs.
- `FORCE_CUDA=1` — Build CUDA/HIP extensions without a GPU present. Works for both backends.
- `FLASH_ATTENTION_FORCE_BUILD=TRUE` — Skip prebuilt wheel download, build from source.
- `FLASH_ATTENTION_FORCE_CXX11_ABI=TRUE` — Use C++11 ABI (matches modern PyTorch).
- `MAX_JOBS=2` — Limit parallel compilations to avoid OOM on CI runners (7GB RAM).
- `TORCH_CUDA_ARCH_LIST` — Semicolon-separated NVIDIA GPU architectures (CUDA builds).
- `PYTORCH_ROCM_ARCH` — Semicolon-separated AMD GPU architectures (ROCm builds, e.g., `gfx90a;gfx942`).

## CI Behavior

- Wheels are uploaded directly to a GitHub release.
  - CUDA tag: `torch{X.Y}-cu{MAJMIN}` (e.g., `torch2.10-cu130`)
  - ROCm tag: `torch{X.Y}-rocm{MAJ}.{MIN}` (e.g., `torch2.10-rocm7.0`)
- `override-previous: false` (default) skips builds if the wheel already exists in the release (matched by package prefix + CPU arch).
- CUDA: both x86_64 and aarch64 are built in parallel.
- ROCm: x86_64 only. Builds for multiple ROCm versions in parallel (default: 7.0, 7.1, 7.2) via `rocm-versions` JSON array input. Each version gets its own release. ROCm toolkit is installed from AMD's APT repository.
