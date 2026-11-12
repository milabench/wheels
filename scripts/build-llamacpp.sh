#!/bin/bash
# llama.cpp binaries (llama-server, llama-bench, llama-cli) for one ggml backend, packed as a tarball.
#
#   bash scripts/build-llamacpp.sh cuda      # GGML_CUDA, CMAKE_CUDA_ARCHITECTURES=$LLAMACPP_CUDA_ARCHS
#   bash scripts/build-llamacpp.sh vulkan    # GGML_VULKAN (needs Vulkan headers + glslc)
#   bash scripts/build-llamacpp.sh cpu
#
# Not a wheel and not tied to a torch version: it goes to its own release (llamacpp-<ref>), not to the
# torch{X.Y}-cu{NNN} ones. Output: $LLAMACPP_DIST/llama.cpp-<ref>-<backend>-ubuntu22.04-<arch>.tar.gz,
# one flat folder (binaries + libggml-*.so backends, RPATH $ORIGIN), the layout of upstream's releases.
#
# Why not upstream's release binaries: they are built on Ubuntu 24.04 (glibc 2.39) against CUDA 13.5
# (needs a newer driver than 580), with the default arch set. Here: Ubuntu 22.04 glibc like the
# wheels, the CUDA of the torch wheels (13.0), SASS for the GPUs milabench runs (incl. GB10, sm_121a).
#
# The CUDA runtime is not bundled (libcublasLt alone is ~0.5 GB): the binaries need libcudart.so.13 /
# libcublas.so.13 on the loader path, from a CUDA toolkit or from a torch cu13x venv
# (site-packages/nvidia/cu13/lib), which is what milabench uses.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

BACKEND="${1:-cuda}"
REF="${LLAMACPP_REF:?LLAMACPP_REF is not set (.env)}"
ARCH="$(uname -m)"
DIST="${LLAMACPP_DIST:-${ROOT_DIR}/llamacpp-dist}"
SRC="${LLAMACPP_SRC:-/tmp/llama.cpp-src}"
JOBS="${MAX_JOBS:-2}"
[ "$JOBS" = "0" ] && JOBS="$(nproc)"

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
export DEBIAN_FRONTEND=noninteractive

install_deps() {
    $SUDO apt-get update -y
    # cmake: llama.cpp needs >= 3.18 (CUDA archs) and 3.24+ for the 'a' arch suffixes; 22.04 ships 3.22
    $SUDO apt-get install -y --no-install-recommends build-essential git ninja-build libssl-dev ca-certificates
    pip install "cmake>=3.28,<4"
    case "$BACKEND" in
        vulkan)
            if [ "$ARCH" = "x86_64" ]; then
                # LunarG SDK, as upstream's ubuntu-22.04 Vulkan build (jammy's headers are too old)
                curl -fsSL https://packages.lunarg.com/lunarg-signing-key-pub.asc | $SUDO gpg --dearmor -o /usr/share/keyrings/lunarg.gpg
                echo "deb [signed-by=/usr/share/keyrings/lunarg.gpg] https://packages.lunarg.com/vulkan jammy main" \
                    | $SUDO tee /etc/apt/sources.list.d/lunarg-vulkan-jammy.list > /dev/null
                $SUDO apt-get update -y
                $SUDO apt-get install -y --no-install-recommends vulkan-sdk
            else
                # no LunarG SDK for arm64: jammy's packages (may be too old for this llama.cpp; the CI leg is allowed to fail)
                $SUDO apt-get install -y --no-install-recommends libvulkan-dev glslc spirv-headers
            fi
            ;;
    esac
}

cmake_args() {
    local args=(
        -G Ninja
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_RPATH='$ORIGIN'
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
        # backends as loadable modules next to the binaries (libggml-cuda.so, libggml-cpu-*.so)
        -DGGML_BACKEND_DL=ON
        -DGGML_NATIVE=OFF
        -DLLAMA_BUILD_TESTS=OFF
        -DLLAMA_BUILD_EXAMPLES=OFF
        -DLLAMA_BUILD_UI=OFF
        # no download at build time (the server's web UI is not needed for benchmarking)
        -DLLAMA_USE_PREBUILT_UI=OFF
    )
    if [ "$ARCH" = "x86_64" ]; then
        # one CPU module per x86 level, picked at runtime: the binaries run on any x86_64 host
        args+=(-DGGML_CPU_ALL_VARIANTS=ON)
    else
        # GCC 11 (22.04) can't build every ARM variant (sme); baseline of Graviton2+, Grace / GB10, Ampere
        args+=(-DGGML_CPU_ARM_ARCH=armv8.2-a+fp16+dotprod)
    fi
    case "$BACKEND" in
        cuda) args+=(-DGGML_CUDA=ON "-DCMAKE_CUDA_ARCHITECTURES=${LLAMACPP_CUDA_ARCHS}") ;;
        vulkan) args+=(-DGGML_VULKAN=ON) ;;
        cpu) ;;
        *) echo "unknown backend: $BACKEND (cuda, vulkan, cpu)" >&2; exit 2 ;;
    esac
    printf '%s\n' "${args[@]}"
}

echo "==> llama.cpp ${REF} (${BACKEND}, ${ARCH}), ${JOBS} jobs"
[ "${LLAMACPP_SKIP_DEPS:-0}" = "1" ] || install_deps
if [ "$BACKEND" = "cuda" ]; then
    export PATH="${CUDA_HOME:-/usr/local/cuda}/bin:${PATH}"
    nvcc --version | tail -2
fi

rm -rf "$SRC"
git init -q "$SRC"
git -C "$SRC" remote add origin https://github.com/ggml-org/llama.cpp.git
git -C "$SRC" fetch --depth 1 origin "refs/tags/${REF}"
git -C "$SRC" checkout -q FETCH_HEAD

mapfile -t ARGS < <(cmake_args)
cmake -S "$SRC" -B "$SRC/build" "${ARGS[@]}"
# every target: with GGML_BACKEND_DL the backend modules (libggml-cuda.so, libggml-cpu-*.so) are loaded
# at runtime, so they are not dependencies of llama-server and --target would leave them out
cmake --build "$SRC/build" --config Release -j "$JOBS"
for b in llama-server llama-bench llama-cli; do [ -x "$SRC/build/bin/$b" ] || { echo "missing $b" >&2; exit 1; }; done

NAME="llama.cpp-${REF}-${BACKEND}"
[ "$BACKEND" = "cuda" ] && NAME+="${CUDA_VERSION%.*}"
NAME+="-ubuntu22.04-${ARCH}"
STAGE="$(mktemp -d)/${NAME}"
mkdir -p "$STAGE" "$DIST"
cp -a "$SRC/build/bin/." "$STAGE/"
cp "$SRC/LICENSE" "$STAGE/"
cat > "$STAGE/BUILD-INFO" <<EOF
llama.cpp ${REF} ($(git -C "$SRC" rev-parse HEAD))
backend: ${BACKEND}
arch: ${ARCH}, built on $(. /etc/os-release && echo "$PRETTY_NAME"), glibc $(ldd --version | head -1 | awk '{print $NF}')
cuda: ${CUDA_VERSION:-} archs: ${LLAMACPP_CUDA_ARCHS:-}
cmake: ${ARGS[*]}
EOF
[ "$BACKEND" = "cuda" ] && echo "runtime: needs libcudart.so.13 + libcublas.so.13 on the loader path (CUDA toolkit, or a torch cu13x venv: site-packages/nvidia/cu13/lib)" >> "$STAGE/BUILD-INFO"
tar -C "$(dirname "$STAGE")" -czf "$DIST/${NAME}.tar.gz" "$NAME"

echo "==> ${DIST}/${NAME}.tar.gz ($(du -h "$DIST/${NAME}.tar.gz" | cut -f1))"
cat "$STAGE/BUILD-INFO"
# shared libraries the binaries still need from the host
ldd "$STAGE/llama-server" "$STAGE"/libggml-*.so 2>/dev/null | awk '/=>/ {print $1}' | sort -u | grep -v -e '^libggml' -e '^libllama' -e '^libmtmd' || true
rm -rf "$SRC" "$(dirname "$STAGE")"
