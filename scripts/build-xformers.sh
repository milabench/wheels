#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

echo "==> Building xformers ${XFORMERS_VERSION}"

export MAX_JOBS="${MAX_JOBS:-2}"

pip install wheel setuptools cmake ninja packaging

git clone --recurse-submodules --branch "v${XFORMERS_VERSION}" --depth 1 \
    https://github.com/facebookresearch/xformers.git
(
    cd xformers

    python3 -c "
import re, pathlib

p = pathlib.Path('xformers/ops/fmha/cutlass.py')
t = p.read_text()
t = re.sub(r'CUDA_MAXIMUM_COMPUTE_CAPABILITY\s*=\s*\([0-9]+,\s*[0-9]+\)',
           'CUDA_MAXIMUM_COMPUTE_CAPABILITY = (10, 3)', t)
p.write_text(t)
print('  patched CUDA_MAXIMUM_COMPUTE_CAPABILITY -> (10, 3)')

p = pathlib.Path('xformers/ops/fmha/dispatch.py')
t = p.read_text()
_runtime_check = '''
def _fa3_supported():
    try:
        import torch
        if torch.cuda.is_available() and torch.cuda.get_device_capability()[0] >= 10:
            return False
    except Exception:
        pass
    return True

USE_FLASH_ATTENTION_3 = _fa3_supported()
'''.strip()
t = re.sub(r'USE_FLASH_ATTENTION_3\s*=\s*True', _runtime_check, t)
p.write_text(t)
print('  patched USE_FLASH_ATTENTION_3 -> runtime Blackwell detection')
"

    BUILD_VERSION="${XFORMERS_VERSION}" FORCE_CUDA=1 \
        pip wheel . -v --no-cache-dir --no-deps --no-build-isolation -w "$WHEELS_DIR/"
)
rm -rf xformers
