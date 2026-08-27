# Wheels Build System

Builds GPU extension wheels for milabench. Each wheel is built from source against a specific PyTorch + CUDA, ROCm, or XPU (Intel oneAPI) version.

## File Layout

- `.env` — Single source of truth for package/infrastructure versions (except torchao CI matrix). Edit this to update versions.
- `torchao-matrix.toml` — Maps PyTorch minor → list of torchao versions to build in CI. First entry is preferred; extras are optional older builds.
- `vllm-matrix.toml` — Maps PyTorch minor → highest compatible vLLM version (CUDA). A newer vLLM will not compile against an older torch. Unmapped minors fall back to `VLLM_VERSION` from `.env`.
- `scripts/resolve-vllm-version.py` — Reads `vllm-matrix.toml` for a torch version; used by `build-vllm.sh` and the CUDA skip check.
- `scripts/common.sh` — Loads `.env`, detects `GPU_BACKEND` (cuda/rocm/xpu), computes derived vars (`ACCEL_SHORT`, `PT_VER`, etc.), creates `wheels/` dir.
- `scripts/build-*.sh` — One script per package. Standalone: `bash scripts/build-xformers.sh`. Set `GPU_BACKEND=rocm` for ROCm or `GPU_BACKEND=xpu` for Intel XPU builds.
- `scripts/resolve-torchao-versions.py` — Reads `torchao-matrix.toml` for a torch version; used by CI and `make torchao-matrix`.
- `Makefile` — Runs scripts with `.env` exported. `make all` builds everything, `make GPU_BACKEND=rocm <target>` builds for ROCm, `make GPU_BACKEND=xpu vllm` builds for XPU.
- `.github/workflows/build-cuda.yml` — CUDA CI workflow. Builds all wheels in parallel (x86_64 + aarch64), uploads to a GitHub release.
- `.github/workflows/build-rocm.yml` — ROCm CI workflow. Builds GPU wheels for ROCm (x86_64 only), uploads to a separate release.
- `.github/workflows/build-xpu.yml` — XPU (Intel GPU) CI workflow. Builds vLLM for XPU (x86_64 only), uploads to a separate release.
- `scripts/ci-install-oneapi.sh` — Install Intel oneAPI toolkit (DPC++ compiler + oneMKL) from Intel's apt repo. Used by `build-xpu.yml`.
- `scripts/trigger-rocm-ci.py` — Discover torch+ROCm combos on the official PyTorch index and dispatch `build-rocm.yml` (dry-run by default; `--trigger` to run).
- `scripts/trigger-cuda-ci.py` — Same for CUDA / `build-cuda.yml` (`cu130` ↔ toolkit `13.0.0`).
- `scripts/ci-assert-build-os.sh` — Fail CI if not Ubuntu 22.04, or after 22.04 standard-support EOL (2027-05-31).

## GPU Backend

Set `GPU_BACKEND` to switch between CUDA, ROCm, and XPU:

| Variable | CUDA (default) | ROCm | XPU (Intel) |
|---|---|---|---|
| `GPU_BACKEND` | `cuda` | `rocm` | `xpu` |
| `ACCEL_SHORT` | `cu130` | `rocm7.0` | `xpu` |
| PyTorch index | `whl/cu130` | `whl/rocm7.0` | `whl/xpu` |
| Release tag | `torch2.10-cu130` | `torch2.10-rocm7.0` | `torch2.12-xpu` |
| Arch list env | `TORCH_CUDA_ARCH_LIST` | `PYTORCH_ROCM_ARCH` | `XPU_AOT_DEVLIST` |
| Toolkit installer | (bundled with runner) | `ci-install-rocm.sh` | `ci-install-oneapi.sh` |

Build scripts use `ACCEL_SHORT` for version suffixes, making them backend-agnostic. `FORCE_CUDA=1` works for both CUDA and ROCm backends (ROCm's HIP layer emulates CUDA APIs). **Do not set `FORCE_CUDA` for XPU** — the Intel DPC++ path is selected via `VLLM_TARGET_DEVICE=xpu` and oneAPI environment variables.

## How to Update a Version

1. Edit `.env` — change the version variable.
2. Done. Scripts, Makefile, and CI all read from `.env`.

**torchao (CI):** edit `torchao-matrix.toml` instead — add/remove versions under the torch minor key. First entry is preferred (hard fail); extras are optional (`continue-on-error`). Local `make torchao` still uses `TORCHAO_VERSION` from `.env`; `make torchao-matrix` builds the full list for `PYTORCH_VERSION`.

**vllm (CUDA):** edit `vllm-matrix.toml` — set the torch minor → highest compatible vLLM version. `build-vllm.sh` and the CUDA skip check resolve `VLLM_VERSION` from `PYTORCH_VERSION`; unmapped minors fall back to `VLLM_VERSION` in `.env`. ROCm still uses the `(torch, rocm)` pin from the environment/`.env`.

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
| torchao | `TORCHAO_VERSION` (local) / `torchao-matrix.toml` (CI) | `v{VERSION}` | `torchao-` | Uses `VERSION_SUFFIX`. CI builds every version listed for the torch minor; non-primary rows are `continue-on-error`. Skip-existing matches the exact version. From 0.17+, CUDA kernels are ABI-stable on torch 2.11+ (only 0.16 stays locked to 2.10). Install pins stay in milabench `[compat.torchao]`. |
| flash-attn (FA2) | `FLASH_ATTN_VERSION` | `v{VERSION}` | `flash_attn-2` | FA2+FA3 combined |
| flash-attn-4 (FA4) | `FLASH_ATTN_4_TAG` | `fa4-v4.0.0.betaN` (full tag) | `flash_attn_4-` | Pure Python (py3-none-any), built from `flash_attn/cute/` via `python -m build`. CUDA workflow only (backend-agnostic). |
| torchtitan | `TORCHTITAN_REF` (git ref) | `{SHA}` or `v{VERSION}` | `torchtitan-` | Pure Python (py3-none-any) from [pytorch/torchtitan](https://github.com/pytorch/torchtitan) via `python -m build`. Version comes from the repo's `assets/version.txt` (not `.env`), so the wheel is `torchtitan-{VERSION}-py3-none-any`. Ref pin matches milabench `benchmarks/torchtitan/requirements.toml`. CUDA workflow only (backend-agnostic); skip-existing matches any `torchtitan-*` wheel, so bump via `--override-previous` when `TORCHTITAN_REF` moves. |
| aiter | `AITER_VERSION` | `v{VERSION}` (full tag) | `aiter-` / `amd_aiter-` | ROCm-only. GPU kernel library from ROCm/aiter. Built with `PREBUILD_KERNELS=1`. |
| mori | `MORI_VERSION` | `v{VERSION}` (full tag) | `amd_mori-` | ROCm-only. Modular RDMA Interface from [ROCm/mori](https://github.com/ROCm/mori). Needs recursive submodules + `libpci-dev` / `libibverbs-dev`. Archs via `MORI_GPU_ARCHS` (default `gfx942;gfx950`, else `PYTORCH_ROCM_ARCH`). |
| amdsmi | (none, from ROCm toolkit) | N/A | `amdsmi-` | ROCm-only. Python wrapper built from `/opt/rocm/share/amd_smi`. |
| atom | `ATOM_VERSION` | `v{VERSION}` | `atom-` | ROCm-only. [ROCm/ATOM](https://github.com/ROCm/ATOM) inference server for milabench `serving-*` benchmarks. Pure Python wheel (`py3-none-any`); runtime needs `amd_aiter` (and often `amd_mori` for MoE EP). Build after `aiter`. `ATOM_MESH_BUILD=0` by default (optional Rust mesh). |
| vllm | `VLLM_VERSION` (rocm/xpu/fallback) / `vllm-matrix.toml` (cuda) | `v{VERSION}` | `vllm-` | CUDA + ROCm + XPU. **CUDA version is resolved from the torch version** via `vllm-matrix.toml` (highest compatible build; unmapped minors fall back to `.env`) because a newer vLLM won't compile against an older torch (e.g. 0.26 targets the torch 2.11 stable ABI and fails on 2.10). ROCm and XPU keep their backend-specific pin from the environment/`.env`. Wheel version forced to `{VERSION}+{ACCEL_SHORT}` via `VLLM_VERSION_OVERRIDE` so the CUDA/ROCm/XPU tag is explicit. ROCm builds depend on flash-attn, aiter, mori, amdsmi. **XPU builds** use `VLLM_TARGET_DEVICE=xpu`, require Intel oneAPI toolkit (DPC++ + oneMKL), and install `triton-xpu` in place of NVIDIA triton. Optional AOT compilation via `XPU_AOT_DEVLIST` (e.g. `pvc` for Data Center GPU Max). vLLM 0.26+ needs `setuptools-rust` and a prebuilt Rust frontend via upstream `build_rust.sh`. |
| mslk | `MSLK_VERSION` | `v{VERSION}` | `mslk-` | CUDA + ROCm. Built from [meta-pytorch/MSLK](https://github.com/meta-pytorch/MSLK) with `BUILD_FROM_NOVA=0` so the wheel is named `mslk` with `+cuXXX` / `+rocmM.m.PATCH` local version (ROCm patch comes from the toolkit, e.g. `+rocm7.2.26015`). Needs recursive git submodules. Match version to PyTorch via milabench `[compat.mslk]`. |

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
- `MORI_GPU_ARCHS` — Semicolon-separated AMD GPU architectures for MORI (defaults to `PYTORCH_ROCM_ARCH` if unset).
- `ONEAPI_ROOT` — Intel oneAPI install root (default `/opt/intel/oneapi`). `common.sh` sources `$ONEAPI_ROOT/setvars.sh` when `GPU_BACKEND=xpu`.
- `ONEAPI_VERSION` — Intel oneAPI Toolkit version used by `ci-install-oneapi.sh` (e.g., `2026.1`). XPU builds only.
- `XPU_AOT_DEVLIST` / `USE_AOT_DEVLIST` — Comma-separated SYCL AOT compilation targets (e.g., `pvc` for Data Center GPU Max, `acm-g10` for Arc A770). Empty = SPIR-V JIT at runtime on any Intel GPU. XPU builds only.

## CI Behavior

- Wheels are uploaded directly to a GitHub release.
  - CUDA tag: `torch{X.Y}-cu{MAJMIN}` (e.g., `torch2.10-cu130`)
  - ROCm tag: `torch{X.Y}-rocm{MAJ}.{MIN}` (e.g., `torch2.10-rocm7.0`)
- `scripts/ci-skip-if-wheel-exists.sh` — Central skip-existing check: matches the exact wheel name each build would produce (version from `.env`, local tags from `ACCEL_SHORT` / `PT_VER` / flash-attn local version). Used by both workflows when `override-previous: false`. **amdsmi** is the exception (toolkit version not pinned in `.env`): any `amdsmi-*-py3-none-any` on the release counts as present.
- CUDA: both x86_64 and aarch64 are built in parallel.
- ROCm: x86_64 only. Builds for multiple ROCm versions in parallel via `rocm-versions` JSON array input (default: `["7.2"]` with torch 2.12.0; 7.0 only has torch 2.10 wheels). Each version gets its own release. Toolkit install is centralized in `scripts/ci-install-rocm.sh` (AMD apt pin, `libxml2` for ROCm `lld`, HIP/ML SDKs, and a hipcc smoke compile).
- **Long vs short runners:** GitHub-hosted runners hard-cap at 6h, so packages that typically exceed that (`xformers`, `flash-attention`, `aiter`, `mori`, `atom`, `vllm`, `mslk`) use `runs-on-long` (default `self-hosted,linux,cpu`; arch label `X64`/`ARM64` is appended from the matrix) inside `container-image` (default `ubuntu:22.04`). Short jobs use GitHub-hosted `ubuntu-22.04` / `ubuntu-22.04-arm`. CUDA long jobs (x86_64 + aarch64) and ROCm (x86_64-only) all run on self-hosted. Bootstrap via `scripts/ci-bootstrap-container.sh`. Long jobs set `MAX_JOBS` from `max-jobs-long` (default `0` → `nproc`) plus matching `CMAKE_BUILD_PARALLEL_LEVEL` / `NVCC_THREADS`.
- **Build OS:** Ubuntu **22.04** (glibc compatibility). `scripts/ci-assert-build-os.sh` fails CI if the runner/container is not 22.04, or after Ubuntu 22.04 standard-support EOL (**2027-05-31**). Wired from container bootstrap and `common.sh` under `GITHUB_ACTIONS`.
- **Container Python:** Long jobs install **uv** + CPython via `scripts/ci-bootstrap-container.sh` (`uv python install`, version from `PYTHON_VERSION` / workflow `python-version`). `actions/setup-python` is skipped in containers (`WHEELS_IN_CONTAINER=1`) because toolcache Pythons often need a newer glibc than 22.04 provides.

## Triggering CI from the PyTorch index

```bash
# ROCm: list torch+ROCm combos with cp312 linux wheels (dry-run)
python3 scripts/trigger-rocm-ci.py --min-torch 2.10 --min-rocm 7.0 --latest-patch

# ROCm: dispatch; skip releases that already have assets
python3 scripts/trigger-rocm-ci.py --min-torch 2.10 --min-rocm 7.0 \
  --latest-patch --skip-existing --trigger

# CUDA: list torch+CUDA combos (maps cu130 -> cuda-version 13.0.0)
python3 scripts/trigger-cuda-ci.py --min-torch 2.10 --min-cuda 12.6 --latest-patch

# CUDA: dispatch missing releases
python3 scripts/trigger-cuda-ci.py --min-torch 2.10 --min-cuda 12.6 \
  --latest-patch --skip-existing --trigger
```

ROCm dispatches one workflow run per torch version (all matching ROCm versions in `rocm-versions`). CUDA dispatches one run per `(torch, cuda)` pair (`cuda-version` is a single toolkit string).
