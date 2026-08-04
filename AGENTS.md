# Wheels Build System

Builds GPU extension wheels for milabench. Each wheel is built from source against a specific PyTorch + CUDA or ROCm version.

## File Layout

- `.env` — Single source of truth for all versions. Edit this to update package or infrastructure versions.
- `scripts/common.sh` — Loads `.env`, detects `GPU_BACKEND` (cuda/rocm), computes derived vars (`ACCEL_SHORT`, `PT_VER`, etc.), creates `wheels/` dir.
- `scripts/build-*.sh` — One script per package. Standalone: `bash scripts/build-xformers.sh`. Set `GPU_BACKEND=rocm` for ROCm builds.
- `Makefile` — Runs scripts with `.env` exported. `make all` builds everything, `make GPU_BACKEND=rocm <target>` builds for ROCm.
- `.github/workflows/build-cuda.yml` — CUDA CI workflow. Builds all wheels in parallel (x86_64 + aarch64), uploads to a GitHub release.
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
4. Add a job to `.github/workflows/build-cuda.yml` (CUDA) and/or `.github/workflows/build-rocm.yml` (ROCm):
   - Copy an existing build job (e.g., `build-torchao`).
   - Update the job name, check pattern (grep for wheel filename prefix), and script path.
   - The job must have `needs: [create-release]`, `if: ${{ !cancelled() }}`, and `permissions: contents: write`.
   - CUDA jobs include an arch matrix (x86_64 + aarch64). ROCm jobs are x86_64 only.

## Existing Packages

| Package | .env variable | Git tag format | Wheel prefix | Notes |
|---|---|---|---|---|
| xformers | `XFORMERS_VERSION` | `v{VERSION}` | `xformers-` | Uses `BUILD_VERSION`. CUDA: `FORCE_CUDA=1` + Blackwell patches. ROCm: sets `HIP_ARCHITECTURES` from `PYTORCH_ROCM_ARCH`; do **not** set `FORCE_CUDA` (that forces the nvcc path). |
| pytorch_cluster | `PYTORCH_CLUSTER_VERSION` | `{VERSION}` (no v) | `torch_cluster-` | Version patched via sed in setup.py |
| pytorch_sparse | `PYTORCH_SPARSE_VERSION` | `{VERSION}` (no v) | `torch_sparse-` | Same as cluster. ROCm: `patches/pytorch_sparse/csrc/cuda/utils.cuh` avoids 32-bit `__shfl_*_sync` masks (ROCm 7.2+). |
| pytorch_scatter | `PYTORCH_SCATTER_VERSION` | `{VERSION}` (no v) | `torch_scatter-` | Same as cluster. ROCm: `patches/pytorch_scatter/csrc/cuda/utils.cuh` (same warp-mask fix as sparse). |
| torchao | `TORCHAO_VERSION` | `v{VERSION}` | `torchao-` | Uses `VERSION_SUFFIX` env var |
| flash-attn (FA2) | `FLASH_ATTN_VERSION` | `v{VERSION}` | `flash_attn-2` | FA2+FA3 combined |
| flash-attn-4 (FA4) | `FLASH_ATTN_4_TAG` | `fa4-v4.0.0.betaN` (full tag) | `flash_attn_4-` | Pure Python (py3-none-any), built from `flash_attn/cute/` via `python -m build`. CUDA workflow only (backend-agnostic). |
| aiter | `AITER_VERSION` | `v{VERSION}` (full tag) | `aiter-` | ROCm-only. GPU kernel library from ROCm/aiter. Built with `PREBUILD_KERNELS=1`. |
| amdsmi | (none, from ROCm toolkit) | N/A | `amdsmi-` | ROCm-only. Python wrapper built from `/opt/rocm/share/amd_smi`. |
| vllm | `VLLM_VERSION` | `v{VERSION}` | `vllm-` | CUDA + ROCm. Wheel version forced to `{VERSION}+{ACCEL_SHORT}` via `VLLM_VERSION_OVERRIDE` so the CUDA/ROCm tag is explicit (upstream omits `+cuXXX` when it matches `VLLM_MAIN_CUDA_VERSION`). ROCm builds also depend on flash-attn, aiter, amdsmi. |
| mslk | `MSLK_VERSION` | `v{VERSION}` | `mslk-` | CUDA + ROCm. Built from [meta-pytorch/MSLK](https://github.com/meta-pytorch/MSLK) with `BUILD_FROM_NOVA=0` so the wheel is named `mslk` with `+cuXXX` / `+rocmX.Y` local version. Needs recursive git submodules. Match version to PyTorch via milabench `[compat.mslk]`. |

## Key Env Vars in Build Scripts

- `GPU_BACKEND` — `cuda` (default) or `rocm`. Controls which derived vars are computed.
- `ACCEL_SHORT` — Unified accelerator suffix for version strings and PyTorch index URLs.
- `FORCE_CUDA=1` — Build CUDA extensions without a GPU present (CUDA builds). Do **not** set this for ROCm xformers — it selects the nvcc path.
- `HIP_ARCHITECTURES` — Space-separated AMD GPU architectures for xformers ROCm builds (derived from `PYTORCH_ROCM_ARCH`).
- `FLASH_ATTENTION_FORCE_BUILD=TRUE` — Skip prebuilt wheel download, build from source.
- `FLASH_ATTENTION_FORCE_CXX11_ABI=TRUE` — Use C++11 ABI (matches modern PyTorch).
- `MAX_JOBS=2` — Default parallel compilations on GitHub-hosted jobs (avoids OOM on ~7GB RAM). Long/self-hosted jobs set `max-jobs-long` (default `0` = `nproc`) via container bootstrap.
- `TORCH_CUDA_ARCH_LIST` — Semicolon-separated NVIDIA GPU architectures (CUDA builds).
- `PYTORCH_ROCM_ARCH` — Semicolon-separated AMD GPU architectures (ROCm builds, e.g., `gfx90a;gfx942`).

## CI Behavior

- Wheels are uploaded directly to a GitHub release.
  - CUDA tag: `torch{X.Y}-cu{MAJMIN}` (e.g., `torch2.10-cu130`)
  - ROCm tag: `torch{X.Y}-rocm{MAJ}.{MIN}` (e.g., `torch2.10-rocm7.0`)
- `override-previous: false` (default) skips builds if the wheel already exists in the release (matched by package prefix + CPU arch).
- CUDA: both x86_64 and aarch64 are built in parallel.
- ROCm: x86_64 only. Builds for multiple ROCm versions in parallel via `rocm-versions` JSON array input (default: `["7.2"]` with torch 2.12.0; 7.0 only has torch 2.10 wheels). Each version gets its own release. Toolkit install is centralized in `scripts/ci-install-rocm.sh` (AMD apt pin, `libxml2` for ROCm `lld`, HIP/ML SDKs, and a hipcc smoke compile).
- **Long vs short runners:** GitHub-hosted runners hard-cap at 6h, so packages that typically exceed that (`xformers`, `flash-attention`, `aiter`, `vllm`, `mslk`) use `runs-on-long` (default `self-hosted,linux,cpu`; arch label `X64`/`ARM64` is appended from the matrix) inside `container-image` (default `ubuntu:24.04`). Short jobs use GitHub-hosted `ubuntu-24.04` / `ubuntu-24.04-arm`. CUDA still builds x86_64 and aarch64 in parallel; aarch64 long jobs stay on `ubuntu-24.04-arm` until a self-hosted `ARM64` runner exists (then point that matrix leg at `runs-on-long` + `ARM64`). ROCm is x86_64-only. Bootstrap via `scripts/ci-bootstrap-container.sh`. Long jobs set `MAX_JOBS` from `max-jobs-long` (default `0` → `nproc`) plus matching `CMAKE_BUILD_PARALLEL_LEVEL` / `NVCC_THREADS`.
