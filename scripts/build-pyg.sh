#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PACKAGE="${1:?Usage: $0 <pytorch_cluster|pytorch_sparse|pytorch_scatter>}"

case "$PACKAGE" in
    pytorch_cluster)
        VERSION="${PYTORCH_CLUSTER_VERSION}"
        REPO="https://github.com/rusty1s/pytorch_cluster.git"
        ;;
    pytorch_sparse)
        VERSION="${PYTORCH_SPARSE_VERSION}"
        REPO="https://github.com/rusty1s/pytorch_sparse.git"
        ;;
    pytorch_scatter)
        VERSION="${PYTORCH_SCATTER_VERSION}"
        REPO="https://github.com/rusty1s/pytorch_scatter.git"
        ;;
    *)
        echo "Unknown package: $PACKAGE" >&2
        exit 1
        ;;
esac

echo "==> Building ${PACKAGE} ${VERSION}"

export MAX_JOBS="${MAX_JOBS:-2}"

pip install wheel setuptools cmake ninja packaging

git clone --recurse-submodules --branch "$VERSION" --depth 1 "$REPO"
(
    cd "$PACKAGE"
    sed -i "s/__version__ = '${VERSION}'/__version__ = '${VERSION}+${PT_VER}${CUDA_SHORT}'/" setup.py
    FORCE_CUDA=1 pip wheel . -v --no-cache-dir --no-deps --no-build-isolation -w "$WHEELS_DIR/"
)
rm -rf "$PACKAGE"
