#!/usr/bin/env python3
"""Resolve torchao versions to build for a given PyTorch version.

Reads wheels/torchao-matrix.toml and emits a JSON matrix for GitHub Actions
or a plain version list for local use.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

try:
    import tomllib
except ImportError:  # Python < 3.11
    import tomli as tomllib  # type: ignore

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MATRIX = ROOT / "torchao-matrix.toml"


def torch_minor(version: str) -> str:
    parts = version.split(".")
    if len(parts) < 2:
        raise SystemExit(
            f"Need at least major.minor torch version, got {version!r}"
        )
    return f"{parts[0]}.{parts[1]}"


def load_torchao_table(path: Path) -> dict:
    with path.open("rb") as f:
        data = tomllib.load(f)
    table = data.get("torchao", data)
    if not isinstance(table, dict):
        raise SystemExit(f"Expected [torchao] table in {path}")
    return table


def resolve(torch_version: str, matrix_path: Path) -> list[dict]:
    key = torch_minor(torch_version)
    table = load_torchao_table(matrix_path)
    if key not in table:
        available = ", ".join(sorted(table)) or "(empty)"
        raise SystemExit(
            f"No torchao matrix entry for torch {key} (from {torch_version}). "
            f"Available: {available}. Add a row to {matrix_path.name}."
        )
    versions = table[key]
    if isinstance(versions, str):
        versions = [versions]
    if not isinstance(versions, list) or not versions:
        raise SystemExit(f"Empty torchao version list for torch {key}")
    return [
        {"version": str(v), "primary": i == 0}
        for i, v in enumerate(versions)
    ]


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
        help="PyTorch version (e.g. 2.12.0); only major.minor is used",
    )
    p.add_argument(
        "--matrix",
        type=Path,
        default=DEFAULT_MATRIX,
        help=f"Path to matrix TOML (default: {DEFAULT_MATRIX})",
    )
    p.add_argument(
        "--versions-only",
        action="store_true",
        help="Emit a JSON array of version strings instead of matrix objects",
    )
    p.add_argument(
        "--github-output",
        action="store_true",
        help="Also write 'matrix' (and 'versions') to $GITHUB_OUTPUT",
    )
    args = p.parse_args()

    entries = resolve(args.torch, args.matrix)
    versions = [e["version"] for e in entries]
    payload = versions if args.versions_only else entries
    text = json.dumps(payload)
    print(text)

    if args.github_output:
        write_github_output("matrix", json.dumps(entries))
        write_github_output("versions", json.dumps(versions))


if __name__ == "__main__":
    main()
