#!/usr/bin/env python3
"""Discover PyTorch + ROCm wheels on the official index and trigger CI builds.

Scans https://download.pytorch.org/whl/rocmX.Y/torch/ for linux x86_64 wheels,
groups compatible ROCm versions per torch version, and optionally dispatches
`.github/workflows/build-rocm.yml` via `gh`.

Examples:
  # List combinations (default: dry-run)
  python3 scripts/trigger-rocm-ci.py

  # Only recent stacks, latest patch per torch X.Y
  python3 scripts/trigger-rocm-ci.py --min-torch 2.10 --min-rocm 7.0 --latest-patch

  # Dispatch builds for missing releases
  python3 scripts/trigger-rocm-ci.py --min-torch 2.10 --min-rocm 7.0 \\
      --latest-patch --skip-existing --trigger

  # One specific combo
  python3 scripts/trigger-rocm-ci.py --torch 2.12.0 --rocm 7.2 --trigger
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
USER_AGENT = "milabench-wheels-trigger-rocm-ci"
DEFAULT_REPO = "milabench/wheels"
DEFAULT_WORKFLOW = "build-rocm.yml"

WHEEL_RE = re.compile(
    r"^torch-(?P<ver>\d+\.\d+\.\d+(?:\.post\d+)?)\+rocm(?P<rocm>\d+\.\d+)"
    r"-(?P<py>cp\d+)(?:-cp\d+[tm]?)?-.*?"
    r"(?:linux_x86_64|manylinux[^.\-]*_x86_64)\.whl$"
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


@dataclass(frozen=True)
class Combo:
    torch: Version
    rocm: Version
    python_tags: frozenset[str]

    @property
    def release_tag(self) -> str:
        tmaj, tmin = self.torch.parts[0], self.torch.parts[1]
        rmaj, rmin = self.rocm.parts[0], self.rocm.parts[1]
        return f"torch{tmaj}.{tmin}-rocm{rmaj}.{rmin}"


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read().decode("utf-8", "replace")


def list_rocm_indexes() -> list[str]:
    html = fetch(INDEX_ROOT)
    found = sorted(set(re.findall(r'href="(rocm\d+\.\d+)/"', html)))
    return found


def discover_combos(
    *,
    rocm_filter: set[str] | None = None,
    min_rocm: Version | None = None,
) -> list[Combo]:
    """Return torch+rocm combos that have at least one linux x86_64 wheel."""
    # torch -> rocm -> python tags
    table: dict[str, dict[str, set[str]]] = defaultdict(lambda: defaultdict(set))

    for idx in list_rocm_indexes():
        rocm_s = idx.removeprefix("rocm")
        if rocm_filter is not None and rocm_s not in rocm_filter:
            continue
        rocm_v = Version.parse(rocm_s)
        if min_rocm is not None and rocm_v.parts < min_rocm.parts:
            continue

        url = f"{INDEX_ROOT}{idx}/torch/"
        try:
            page = fetch(url)
        except Exception as exc:  # noqa: BLE001 - surface per-index and continue
            print(f"warning: skip {url}: {exc}", file=sys.stderr)
            continue

        parser = _LinkParser()
        parser.feed(page)
        for href in parser.hrefs:
            name = href.rsplit("/", 1)[-1]
            match = WHEEL_RE.search(name)
            if not match or match.group("rocm") != rocm_s:
                continue
            table[match.group("ver")][rocm_s].add(match.group("py"))

    combos: list[Combo] = []
    for torch_s, rocms in table.items():
        torch_v = Version.parse(torch_s)
        for rocm_s, pys in rocms.items():
            combos.append(
                Combo(
                    torch=torch_v,
                    rocm=Version.parse(rocm_s),
                    python_tags=frozenset(pys),
                )
            )
    return sorted(combos, key=lambda c: (c.torch.parts, c.rocm.parts))


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
    rocm_exact: set[str] | None,
    latest_patch: bool,
) -> list[Combo]:
    want_py = py_tag(python_version)
    out: list[Combo] = []
    for combo in combos:
        if want_py not in combo.python_tags:
            continue
        if torch_exact is not None and combo.torch.raw not in torch_exact:
            continue
        if rocm_exact is not None and combo.rocm.raw not in rocm_exact:
            continue
        if min_torch is not None and combo.torch.parts < min_torch.parts:
            continue
        if max_torch is not None and combo.torch.parts > max_torch.parts:
            continue
        out.append(combo)

    if not latest_patch:
        return out

    # Keep the newest patch for each (torch_major.minor, rocm).
    best: dict[tuple[tuple[int, int], str], Combo] = {}
    for combo in out:
        key = ((combo.torch.parts[0], combo.torch.parts[1]), combo.rocm.raw)
        prev = best.get(key)
        if prev is None or combo.torch.parts > prev.torch.parts:
            best[key] = combo
    return sorted(best.values(), key=lambda c: (c.torch.parts, c.rocm.parts))


def group_by_torch(combos: list[Combo]) -> list[tuple[Version, list[Version]]]:
    grouped: dict[str, list[Version]] = defaultdict(list)
    torch_by_raw: dict[str, Version] = {}
    for combo in combos:
        torch_by_raw[combo.torch.raw] = combo.torch
        if combo.rocm not in grouped[combo.torch.raw]:
            grouped[combo.torch.raw].append(combo.rocm)
    result: list[tuple[Version, list[Version]]] = []
    for torch_s in sorted(grouped, key=lambda s: Version.parse(s).parts):
        rocms = sorted(grouped[torch_s], key=lambda v: v.parts)
        result.append((torch_by_raw[torch_s], rocms))
    return result


def release_exists(repo: str, tag: str) -> bool:
    proc = subprocess.run(
        ["gh", "release", "view", tag, "--repo", repo],
        check=False,
        capture_output=True,
        text=True,
    )
    return proc.returncode == 0


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
    rocms: list[Version],
    python_version: str,
    pytorch_rocm_arch: str,
    upload_to_release: bool,
    override_previous: bool,
    dry_run: bool,
) -> None:
    rocm_json = json.dumps([r.raw for r in rocms])
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
        f"rocm-versions={rocm_json}",
        "-f",
        f"pytorch-rocm-arch={pytorch_rocm_arch}",
        "-f",
        f"upload-to-release={'true' if upload_to_release else 'false'}",
        "-f",
        f"override-previous={'true' if override_previous else 'false'}",
    ]
    label = f"torch {torch.raw} + rocm {', '.join(r.raw for r in rocms)}"
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
        "--pytorch-rocm-arch",
        default="gfx950",
        help="PYTORCH_ROCM_ARCH passed to CI (default: gfx950)",
    )
    p.add_argument("--min-torch", default="2.10", help="Minimum torch version, e.g. 2.10")
    p.add_argument("--max-torch", default=None, help="Maximum torch version, e.g. 2.12.1")
    p.add_argument("--min-rocm", default="7.0", help="Minimum ROCm index version (default: 7.0)")
    p.add_argument(
        "--torch",
        action="append",
        default=[],
        help="Only this torch version (repeatable). Exact match, e.g. 2.12.0",
    )
    p.add_argument(
        "--rocm",
        action="append",
        default=[],
        help="Only this ROCm version (repeatable). Exact match, e.g. 7.2",
    )
    p.add_argument(
        "--latest-patch",
        action="store_true",
        help="Keep only the newest torch patch for each (torch X.Y, rocm) pair",
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
    p.add_argument(
        "--json",
        action="store_true",
        help="Print discovered plan as JSON",
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    min_torch = Version.parse(args.min_torch) if args.min_torch else None
    max_torch = Version.parse(args.max_torch) if args.max_torch else None
    min_rocm = Version.parse(args.min_rocm) if args.min_rocm else None
    torch_exact = set(args.torch) or None
    rocm_exact = set(args.rocm) or None

    print(
        f"scanning {INDEX_ROOT} for torch+rocm linux_x86_64 / {py_tag(args.python)} ...",
        file=sys.stderr,
    )
    combos = discover_combos(rocm_filter=rocm_exact, min_rocm=min_rocm)
    combos = filter_combos(
        combos,
        python_version=args.python,
        min_torch=min_torch,
        max_torch=max_torch,
        torch_exact=torch_exact,
        rocm_exact=rocm_exact,
        latest_patch=args.latest_patch,
    )

    if not combos:
        print("no matching torch+rocm combinations found", file=sys.stderr)
        return 1

    plan = group_by_torch(combos)
    selected: list[tuple[Version, list[Version], list[str]]] = []

    for torch_v, rocms in plan:
        kept: list[Version] = []
        skipped_tags: list[str] = []
        for rocm_v in rocms:
            tag = Combo(torch_v, rocm_v, frozenset()).release_tag
            if args.skip_existing and release_has_assets(args.repo, tag):
                skipped_tags.append(tag)
                continue
            kept.append(rocm_v)
        if kept:
            selected.append((torch_v, kept, skipped_tags))
        elif skipped_tags:
            print(
                f"skip torch {torch_v.raw}: releases already present ({', '.join(skipped_tags)})",
                file=sys.stderr,
            )

    if args.json:
        payload = [
            {
                "torch": torch_v.raw,
                "rocm": [r.raw for r in rocms],
                "skipped_releases": skipped,
                "release_tags": [
                    Combo(torch_v, r, frozenset()).release_tag for r in rocms
                ],
            }
            for torch_v, rocms, skipped in selected
        ]
        print(json.dumps(payload, indent=2))
    else:
        print("plan:")
        for torch_v, rocms, skipped in selected:
            tags = ", ".join(Combo(torch_v, r, frozenset()).release_tag for r in rocms)
            print(f"  torch {torch_v.raw} + rocm [{', '.join(r.raw for r in rocms)}] -> {tags}")
            if skipped:
                print(f"    (skipped existing: {', '.join(skipped)})")
        if not selected:
            print("  (nothing to build)")

    if not selected:
        return 0

    dry_run = not args.trigger
    if dry_run:
        print("\ndry-run only; pass --trigger to dispatch", file=sys.stderr)

    for torch_v, rocms, _skipped in selected:
        dispatch(
            repo=args.repo,
            workflow=args.workflow,
            torch=torch_v,
            rocms=rocms,
            python_version=args.python,
            pytorch_rocm_arch=args.pytorch_rocm_arch,
            upload_to_release=args.upload_to_release,
            override_previous=args.override_previous,
            dry_run=dry_run,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())


# python scripts/trigger-rocm-ci.py --override-previous --min-rocm 7.2 --trigger
# python scripts/trigger-rocm-ci.py --override-previous --torch 2.10.0 --rocm 7.1