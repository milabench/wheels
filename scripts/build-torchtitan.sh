#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# torchtitan is a pure-Python package (py3-none-any). Its version comes from a
# static assets/version.txt, so a shallow fetch of any commit/tag is enough --
# no setuptools_scm history and no torch/CUDA toolkit required. Backend-agnostic,
# so it is only built in the CUDA workflow (mirrors flash-attention-4).
echo "==> Building torchtitan (${TORCHTITAN_REF})"

pip install build

SRC=/tmp/torchtitan-src
rm -rf "$SRC"
# Fetch the exact ref shallowly (works for both a full SHA and a tag/branch).
git init -q "$SRC"
(
    cd "$SRC"
    git remote add origin https://github.com/pytorch/torchtitan.git
    git fetch --depth 1 origin "$TORCHTITAN_REF"
    git checkout -q FETCH_HEAD

    python -m build --wheel --outdir "$WHEELS_DIR"
)
rm -rf "$SRC"

echo "Built wheel:"
ls "$WHEELS_DIR"/torchtitan-*.whl
