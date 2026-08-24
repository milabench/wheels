#!/usr/bin/env python3
"""Resolve the vLLM version to build for a given PyTorch version (CUDA).

Reads wheels/vllm-matrix.toml and prints the highest compatible vLLM version
for the torch minor. build-vllm.sh and the CI skip check both call this so they
agree on which vLLM a torch{X.Y}-cuXXX release should carry.

A newer vLLM cannot compile against an older torch (its stable-ABI C++ sources
target a specific torch), so the torch version drives the vLLM version rather
than a single static pin.

When the torch minor is not in the matrix, --fallback (typically VLLM_VERSION
from .env) is printed instead so unmapped dispatches keep their prior behavior.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

try:
    import tomllib
except ImportError:  # Python < 3.11
    import tomli as tomllib  # type: ignore

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MATRIX = ROOT / "vllm-matrix.toml"


def torch_minor(version: str) -> str:
    parts = version.split(".")
    if len(parts) < 2:
        raise SystemExit(f"Need at least major.minor torch version, got {version!r}")
    return f"{parts[0]}.{parts[1]}"


def load_vllm_table(path: Path) -> dict:
    with path.open("rb") as f:
        data = tomllib.load(f)
    table = data.get("vllm", data)
    if not isinstance(table, dict):
        raise SystemExit(f"Expected [vllm] table in {path}")
    return table


def resolve(torch_version: str, matrix_path: Path, fallback: str | None) -> str:
    key = torch_minor(torch_version)
    table = load_vllm_table(matrix_path)
    if key not in table:
        if fallback:
            print(
                f"warning: no vLLM matrix entry for torch {key} "
                f"(from {torch_version}); using fallback {fallback}",
                file=sys.stderr,
            )
            return fallback
        available = ", ".join(sorted(table)) or "(empty)"
        raise SystemExit(
            f"No vLLM matrix entry for torch {key} (from {torch_version}). "
            f"Available: {available}. Add a row to {matrix_path.name}."
        )
    value = table[key]
    # First entry wins if a list is given (highest / preferred).
    if isinstance(value, list):
        if not value:
            raise SystemExit(f"Empty vLLM version list for torch {key}")
        value = value[0]
    return str(value)


def write_github_output(name: str, value: str) -> None:
    out = os.environ.get("GITHUB_OUTPUT")
    if not out:
        raise SystemExit("GITHUB_OUTPUT is not set")
    with open(out, "a", encoding="utf-8") as f:
        f.write(f"{name}={value}\n")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--torch",
        required=True,
        help="PyTorch version (e.g. 2.10.0); only major.minor is used",
    )
    p.add_argument(
        "--matrix",
        type=Path,
        default=DEFAULT_MATRIX,
        help=f"Path to matrix TOML (default: {DEFAULT_MATRIX})",
    )
    p.add_argument(
        "--fallback",
        default=None,
        help="Version to print when the torch minor is not in the matrix",
    )
    p.add_argument(
        "--github-output",
        action="store_true",
        help="Also write 'version' to $GITHUB_OUTPUT",
    )
    args = p.parse_args()

    version = resolve(args.torch, args.matrix, args.fallback)
    print(version)
    if args.github_output:
        write_github_output("version", version)


if __name__ == "__main__":
    main()
