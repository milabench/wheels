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

# ROCm ships amd_smi under /opt/rocm with root-owned / read-only files.
# Building in-place fails with "Operation not permitted" when setuptools
# copies LICENSE into build/lib. Work from a writable copy instead.
BUILD_SRC="$(mktemp -d)"
trap 'rm -rf "$BUILD_SRC"' EXIT
cp -a "$AMDSMI_DIR"/. "$BUILD_SRC/"
chmod -R u+rwX "$BUILD_SRC"

# ROCm embeds a toolkit git hash as a PEP 440 local version
# (e.g. 26.2.1+fc0010cf6a in amdsmi/_version.py). Keep one stable
# wheel name per release: strip the +local part everywhere.
python3 - <<'PY' "$BUILD_SRC"
import re, sys
from pathlib import Path

root = Path(sys.argv[1])
# Match quoted version strings that contain a local identifier.
pat = re.compile(r'(["\'])(\d+\.\d+\.\d+)\+[A-Za-z0-9._-]+\1')

patched = []
for path in root.rglob("*"):
    if not path.is_file():
        continue
    if path.suffix not in {".py", ".toml", ".cfg", ".txt", ".in"} and path.name not in {"PKG-INFO", "METADATA"}:
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, IsADirectoryError, PermissionError):
        continue
    new, n = pat.subn(r'\1\2\1', text)
    if n:
        path.write_text(new, encoding="utf-8")
        patched.append(f"{path.relative_to(root)} ({n})")

# Capture cleaned version for setuptools_scm pretend, if needed.
ver = None
for candidate in (root / "amdsmi" / "_version.py", root / "pyproject.toml", root / "setup.py"):
    if not candidate.exists():
        continue
    text = candidate.read_text(encoding="utf-8")
    m = re.search(r'__version__\s*=\s*["\']([^"\']+)["\']', text)
    if not m:
        m = re.search(r'(?m)^\s*version\s*=\s*["\']([^"\']+)["\']', text)
    if m:
        ver = m.group(1).split("+", 1)[0]
        break

if ver:
    print(f"  amdsmi version -> {ver}")
    Path("/tmp/amdsmi_version").write_text(ver)
print("  patched:", ", ".join(patched) if patched else "(none)")
PY

if [ -f /tmp/amdsmi_version ]; then
    export SETUPTOOLS_SCM_PRETEND_VERSION="$(cat /tmp/amdsmi_version)"
fi

pip wheel "$BUILD_SRC" --no-cache-dir --no-deps --no-build-isolation \
    --wheel-dir="$WHEELS_DIR/"

# Guardrail: refuse commit-hash local versions in the artifact name.
if compgen -G "$WHEELS_DIR"/amdsmi-*+*.whl > /dev/null; then
    echo "ERROR: amdsmi wheel still has a local version (+...):" >&2
    ls -1 "$WHEELS_DIR"/amdsmi-*.whl >&2
    exit 1
fi
