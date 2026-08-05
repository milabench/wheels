#!/usr/bin/env python3
"""Discover PyTorch + CUDA wheels on the official index and trigger CI builds.

Scans https://download.pytorch.org/whl/cuXXX/torch/ for linux wheels, maps
index tags (cu130) to toolkit versions (13.0.0) for build-cuda.yml, and
optionally dispatches one workflow run per (torch, cuda) pair via `gh`.

Examples:
  # List combinations (default: dry-run)
  python3 scripts/trigger-cuda-ci.py

  # Recent stacks, latest patch per torch X.Y + CUDA
  python3 scripts/trigger-cuda-ci.py --min-torch 2.10 --min-cuda 12.6 --latest-patch

  # Dispatch builds for missing releases
  python3 scripts/trigger-cuda-ci.py --min-torch 2.10 --min-cuda 12.6 \\
      --latest-patch --skip-existing --trigger

  # One specific combo
  python3 scripts/trigger-cuda-ci.py --torch 2.12.0 --cuda 13.0 --trigger
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from collections import defaultdict
from dataclasses import dataclass
from html.parser import HTMLParser
from typing import Iterable

INDEX_ROOT = "https://download.pytorch.org/whl/"
USER_AGENT = "milabench-wheels-trigger-cuda-ci"
DEFAULT_REPO = "milabench/wheels"
DEFAULT_WORKFLOW = "build-cuda.yml"
DEFAULT_ARCH_LIST = "7.5;8.0;8.6;8.9;9.0;10.0;12.0;12.1"

WHEEL_RE = re.compile(
    r"^torch-(?P<ver>\d+\.\d+\.\d+(?:\.post\d+)?)\+cu(?P<cuda>\d+)"
    r"-(?P<py>cp\d+)(?:-cp\d+[tm]?)?-.*?"
    r"(?P<plat>linux_(?:x86_64|aarch64)|manylinux[^.\-]*_(?:x86_64|aarch64))\.whl$"
)


class _LinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.hrefs: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag != "a":
            return
        href = dict(attrs).get("href")
        if href:
            self.hrefs.append(urllib.parse.unquote(href.split("#", 1)[0]))


@dataclass(frozen=True, order=True)
class Version:
    parts: tuple[int, ...]
    raw: str

    @classmethod
    def parse(cls, text: str) -> "Version":
        nums = tuple(int(x) for x in re.findall(r"\d+", text))
        if not nums:
            raise ValueError(f"not a version: {text!r}")
        return cls(parts=nums, raw=text)

    def __str__(self) -> str:
        return self.raw


def cuda_short_from_toolkit(toolkit: str) -> str:
    """13.0.0 / 13.0 / cu130 -> cu130."""
    text = toolkit.strip().lower().removeprefix("cu")
    if text.isdigit():
        return f"cu{text}"
    ver = Version.parse(text)
    if len(ver.parts) < 2:
        raise ValueError(f"CUDA toolkit version needs major.minor: {toolkit!r}")
    return f"cu{ver.parts[0]}{ver.parts[1]}"


def toolkit_from_cuda_short(short: str) -> str:
    """cu130 -> 13.0.0 (patch 0; Jimver/cuda-toolkit accepts this form)."""
    digits = short.lower().removeprefix("cu")
    if not digits.isdigit():
        raise ValueError(f"bad CUDA short tag: {short!r}")
    if len(digits) >= 3:
        major, minor = int(digits[:-1]), int(digits[-1])
    elif len(digits) == 2:
        major, minor = int(digits[0]), int(digits[1])
    else:
        major, minor = int(digits), 0
    return f"{major}.{minor}.0"


@dataclass(frozen=True)
class Combo:
    torch: Version
    cuda_short: str  # cu130
    python_tags_x86: frozenset[str]
    python_tags_arm: frozenset[str]

    @property
    def cuda_toolkit(self) -> str:
        return toolkit_from_cuda_short(self.cuda_short)

    @property
    def release_tag(self) -> str:
        tmaj, tmin = self.torch.parts[0], self.torch.parts[1]
        return f"torch{tmaj}.{tmin}-{self.cuda_short}"


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read().decode("utf-8", "replace")


def list_cuda_indexes() -> list[str]:
    html = fetch(INDEX_ROOT)
    return sorted(set(re.findall(r'href="(cu\d+)/"', html)))


def discover_combos(
    *,
    cuda_filter: set[str] | None = None,
    min_cuda: Version | None = None,
) -> list[Combo]:
    """Return torch+cuda combos with linux wheels (x86_64 and/or aarch64)."""
    # torch -> cuda_short -> arch -> python tags
    table: dict[str, dict[str, dict[str, set[str]]]] = defaultdict(
        lambda: defaultdict(lambda: defaultdict(set))
    )

    for idx in list_cuda_indexes():
        short = idx  # cu130
        if cuda_filter is not None and short not in cuda_filter:
            continue
        toolkit_ver = Version.parse(toolkit_from_cuda_short(short))
        if min_cuda is not None and toolkit_ver.parts[:2] < min_cuda.parts[:2]:
            continue

        url = f"{INDEX_ROOT}{idx}/torch/"
        try:
            page = fetch(url)
        except Exception as exc:  # noqa: BLE001
            print(f"warning: skip {url}: {exc}", file=sys.stderr)
            continue

        parser = _LinkParser()
        parser.feed(page)
        cuda_digits = short.removeprefix("cu")
        for href in parser.hrefs:
            name = href.rsplit("/", 1)[-1]
            match = WHEEL_RE.search(name)
            if not match or match.group("cuda") != cuda_digits:
                continue
            arch = "aarch64" if "aarch64" in match.group("plat") else "x86_64"
            table[match.group("ver")][short][arch].add(match.group("py"))

    combos: list[Combo] = []
    for torch_s, cudas in table.items():
        torch_v = Version.parse(torch_s)
        for short, arches in cudas.items():
            combos.append(
                Combo(
                    torch=torch_v,
                    cuda_short=short,
                    python_tags_x86=frozenset(arches.get("x86_64", ())),
                    python_tags_arm=frozenset(arches.get("aarch64", ())),
                )
            )
    return sorted(combos, key=lambda c: (c.torch.parts, c.cuda_short))


def py_tag(python_version: str) -> str:
    major, minor, *_ = python_version.split(".")
    return f"cp{major}{minor}"


def filter_combos(
    combos: Iterable[Combo],
    *,
    python_version: str,
    min_torch: Version | None,
    max_torch: Version | None,
    torch_exact: set[str] | None,
    cuda_exact: set[str] | None,
    latest_patch: bool,
    require_aarch64: bool,
) -> list[Combo]:
    want_py = py_tag(python_version)
    out: list[Combo] = []
    for combo in combos:
        if want_py not in combo.python_tags_x86:
            continue
        if require_aarch64 and want_py not in combo.python_tags_arm:
            continue
        if torch_exact is not None and combo.torch.raw not in torch_exact:
            continue
        if cuda_exact is not None and combo.cuda_short not in cuda_exact:
            continue
        if min_torch is not None and combo.torch.parts < min_torch.parts:
            continue
        if max_torch is not None and combo.torch.parts > max_torch.parts:
            continue
        out.append(combo)

    if not latest_patch:
        return out

    best: dict[tuple[tuple[int, int], str], Combo] = {}
    for combo in out:
        key = ((combo.torch.parts[0], combo.torch.parts[1]), combo.cuda_short)
        prev = best.get(key)
        if prev is None or combo.torch.parts > prev.torch.parts:
            best[key] = combo
    return sorted(best.values(), key=lambda c: (c.torch.parts, c.cuda_short))


def release_has_assets(repo: str, tag: str) -> bool:
    proc = subprocess.run(
        [
            "gh",
            "release",
            "view",
            tag,
            "--repo",
            repo,
            "--json",
            "assets",
            "--jq",
            ".assets | length",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return False
    try:
        return int(proc.stdout.strip() or "0") > 0
    except ValueError:
        return False


def dispatch(
    *,
    repo: str,
    workflow: str,
    torch: Version,
    cuda_toolkit: str,
    python_version: str,
    torch_cuda_arch_list: str,
    upload_to_release: bool,
    override_previous: bool,
    dry_run: bool,
) -> None:
    args = [
        "gh",
        "workflow",
        "run",
        workflow,
        "--repo",
        repo,
        "-f",
        f"python-version={python_version}",
        "-f",
        f"torch-version={torch.raw}",
        "-f",
        f"cuda-version={cuda_toolkit}",
        "-f",
        f"torch-cuda-arch-list={torch_cuda_arch_list}",
        "-f",
        f"upload-to-release={'true' if upload_to_release else 'false'}",
        "-f",
        f"override-previous={'true' if override_previous else 'false'}",
    ]
    short = cuda_short_from_toolkit(cuda_toolkit)
    label = f"torch {torch.raw} + {short} ({cuda_toolkit})"
    if dry_run:
        print(f"dry-run: {label}")
        print("  " + " ".join(args))
        return

    print(f"trigger: {label}")
    subprocess.run(args, check=True)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--repo", default=DEFAULT_REPO, help=f"GitHub repo (default: {DEFAULT_REPO})")
    p.add_argument(
        "--workflow",
        default=DEFAULT_WORKFLOW,
        help=f"Workflow file name (default: {DEFAULT_WORKFLOW})",
    )
    p.add_argument("--python", default="3.12", help="Python version for wheels / CI (default: 3.12)")
    p.add_argument(
        "--torch-cuda-arch-list",
        default=DEFAULT_ARCH_LIST,
        help=f"TORCH_CUDA_ARCH_LIST for CI (default: {DEFAULT_ARCH_LIST})",
    )
    p.add_argument("--min-torch", default=None, help="Minimum torch version, e.g. 2.10")
    p.add_argument("--max-torch", default=None, help="Maximum torch version, e.g. 2.12.1")
    p.add_argument("--min-cuda", default="12.6", help="Minimum CUDA toolkit (default: 12.6)")
    p.add_argument(
        "--torch",
        action="append",
        default=[],
        help="Only this torch version (repeatable). Exact match, e.g. 2.12.0",
    )
    p.add_argument(
        "--cuda",
        action="append",
        default=[],
        help="Only this CUDA (repeatable). Accepts 13.0, 13.0.0, or cu130",
    )
    p.add_argument(
        "--latest-patch",
        action="store_true",
        help="Keep only the newest torch patch for each (torch X.Y, cuda) pair",
    )
    p.add_argument(
        "--require-aarch64",
        action="store_true",
        help="Require a cpXXX linux_aarch64 wheel as well as x86_64",
    )
    p.add_argument(
        "--skip-existing",
        action="store_true",
        help="Skip combos whose GitHub release already exists and has assets",
    )
    p.add_argument(
        "--upload-to-release",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Pass upload-to-release to the workflow (default: true)",
    )
    p.add_argument(
        "--override-previous",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="Pass override-previous to the workflow (default: false)",
    )
    p.add_argument(
        "--trigger",
        action="store_true",
        help="Actually dispatch workflow runs (default is dry-run listing)",
    )
    p.add_argument("--json", action="store_true", help="Print discovered plan as JSON")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    min_torch = Version.parse(args.min_torch) if args.min_torch else None
    max_torch = Version.parse(args.max_torch) if args.max_torch else None
    min_cuda = Version.parse(args.min_cuda) if args.min_cuda else None
    torch_exact = set(args.torch) or None
    cuda_exact = {cuda_short_from_toolkit(c) for c in args.cuda} or None

    print(
        f"scanning {INDEX_ROOT} for torch+cuda linux / {py_tag(args.python)} ...",
        file=sys.stderr,
    )
    combos = discover_combos(cuda_filter=cuda_exact, min_cuda=min_cuda)
    combos = filter_combos(
        combos,
        python_version=args.python,
        min_torch=min_torch,
        max_torch=max_torch,
        torch_exact=torch_exact,
        cuda_exact=cuda_exact,
        latest_patch=args.latest_patch,
        require_aarch64=args.require_aarch64,
    )

    if not combos:
        print("no matching torch+cuda combinations found", file=sys.stderr)
        return 1

    selected: list[Combo] = []
    for combo in combos:
        if args.skip_existing and release_has_assets(args.repo, combo.release_tag):
            print(f"skip existing release {combo.release_tag}", file=sys.stderr)
            continue
        selected.append(combo)

    if args.json:
        print(
            json.dumps(
                [
                    {
                        "torch": c.torch.raw,
                        "cuda_short": c.cuda_short,
                        "cuda_toolkit": c.cuda_toolkit,
                        "release_tag": c.release_tag,
                        "python_x86_64": sorted(c.python_tags_x86),
                        "python_aarch64": sorted(c.python_tags_arm),
                    }
                    for c in selected
                ],
                indent=2,
            )
        )
    else:
        print("plan:")
        for c in selected:
            arms = " + aarch64" if py_tag(args.python) in c.python_tags_arm else ""
            print(
                f"  torch {c.torch.raw} + {c.cuda_short} "
                f"({c.cuda_toolkit}){arms} -> {c.release_tag}"
            )
        if not selected:
            print("  (nothing to build)")

    if not selected:
        return 0

    dry_run = not args.trigger
    if dry_run:
        print("\ndry-run only; pass --trigger to dispatch", file=sys.stderr)

    for combo in selected:
        dispatch(
            repo=args.repo,
            workflow=args.workflow,
            torch=combo.torch,
            cuda_toolkit=combo.cuda_toolkit,
            python_version=args.python,
            torch_cuda_arch_list=args.torch_cuda_arch_list,
            upload_to_release=args.upload_to_release,
            override_previous=args.override_previous,
            dry_run=dry_run,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
