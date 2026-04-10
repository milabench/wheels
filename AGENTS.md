# Wheels Build System

Builds CUDA extension wheels for milabench. Each wheel is built from source against a specific PyTorch + CUDA version.

## File Layout

- `.env` — Single source of truth for all versions. Edit this to update package or infrastructure versions.
- `scripts/common.sh` — Loads `.env`, computes derived vars (`CUDA_SHORT`, `PT_VER`, etc.), creates `wheels/` dir.
- `scripts/build-*.sh` — One script per package. Standalone: `bash scripts/build-xformers.sh`.
- `Makefile` — Runs scripts with `.env` exported. `make all` builds everything, `make <target>` builds one.
- `.github/workflows/build.yml` — CI workflow. Builds all wheels in parallel (x86_64 + aarch64), uploads to a GitHub release.

## How to Update a Version

1. Edit `.env` — change the version variable.
2. Done. Scripts, Makefile, and CI all read from `.env`.

CI infrastructure versions (Python, CUDA, PyTorch) come from workflow inputs with defaults matching `.env`.

## How to Add a New Package

1. Add `NEW_PACKAGE_VERSION=X.Y.Z` to `.env`.
2. Create `scripts/build-new-package.sh`:
   - Start with `set -euo pipefail` and `source common.sh`.
   - Clone the repo, build with `pip wheel . -v --no-cache-dir --no-deps --no-build-isolation -w "$WHEELS_DIR/"`, clean up.
   - Set `MAX_JOBS="${MAX_JOBS:-2}"` to avoid OOM on CI runners.
3. Add a target to `Makefile` and include it in `all`.
4. Add a job to `.github/workflows/build.yml`:
   - Copy an existing build job (e.g., `build-torchao`).
   - Update the job name, check pattern (grep for wheel filename prefix), and script path.
   - The job must have `needs: [create-release]`, `if: ${{ !cancelled() }}`, arch matrix, and `permissions: contents: write`.

## Existing Packages

| Package | .env variable | Git tag format | Wheel prefix | Notes |
|---|---|---|---|---|
| xformers | `XFORMERS_VERSION` | `v{VERSION}` | `xformers-` | Uses `BUILD_VERSION` env var |
| pytorch_cluster | `PYTORCH_CLUSTER_VERSION` | `{VERSION}` (no v) | `torch_cluster-` | Version patched via sed in setup.py |
| pytorch_sparse | `PYTORCH_SPARSE_VERSION` | `{VERSION}` (no v) | `torch_sparse-` | Same as cluster |
| pytorch_scatter | `PYTORCH_SCATTER_VERSION` | `{VERSION}` (no v) | `torch_scatter-` | Same as cluster |
| torchao | `TORCHAO_VERSION` | `v{VERSION}` | `torchao-` | Uses `VERSION_SUFFIX` env var |
| flash-attn (FA2) | `FLASH_ATTN_VERSION` | `v{VERSION}` | `flash_attn-2` | FA2+FA3 combined |
| flash-attn-4 (FA4) | `FLASH_ATTN_4_TAG` | `fa4-v4.0.0.betaN` (full tag) | `flash_attn_4-` | Pure Python (py3-none-any), built from `flash_attn/cute/` via `python -m build` |

## Key Env Vars in Build Scripts

- `FORCE_CUDA=1` — Build CUDA extensions without a GPU present.
- `FLASH_ATTENTION_FORCE_BUILD=TRUE` — Skip prebuilt wheel download, build from source.
- `FLASH_ATTENTION_FORCE_CXX11_ABI=TRUE` — Use C++11 ABI (matches modern PyTorch).
- `MAX_JOBS=2` — Limit parallel nvcc compilations to avoid OOM on CI runners (7GB RAM).
- `TORCH_CUDA_ARCH_LIST` — Semicolon-separated GPU architectures to compile for.

## CI Behavior

- Wheels are uploaded directly to a GitHub release (tag: `torch{X.Y}-cu{MAJMIN}`).
- `override-previous: false` (default) skips builds if the wheel already exists in the release (matched by package prefix + CPU arch).
- Both x86_64 and aarch64 are built in parallel.
