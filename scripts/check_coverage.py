#!/usr/bin/env python3
"""Fail CI when meaningful Dart line coverage drops below the project floor.

Generated code and platform/bootstrap glue are excluded deliberately: the gate
measures code whose branches we own, rather than rewarding tests for generated
serialization/localization output.
"""
from __future__ import annotations

import argparse
from pathlib import Path

EXCLUDED_PARTS = (
    "/generated/",
    "/l10n/",
)
EXCLUDED_SUFFIXES = (
    ".g.dart",
    ".freezed.dart",
    ".config.dart",
)

def included(path: str) -> bool:
    normalized = "/" + path.replace("\\", "/").lstrip("/")
    return not any(part in normalized for part in EXCLUDED_PARTS) and not path.endswith(EXCLUDED_SUFFIXES)

def read_lcov(path: Path) -> tuple[int, int]:
    found = hit = 0
    current_included = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        if raw.startswith("SF:"):
            current_included = included(raw[3:])
        elif current_included and raw.startswith("DA:"):
            _, payload = raw.split(":", 1)
            _, count, *_ = payload.split(",")
            found += 1
            hit += int(count) > 0
    return found, hit

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("lcov", type=Path)
    parser.add_argument("--minimum", type=float, required=True)
    args = parser.parse_args()
    found, hit = read_lcov(args.lcov)
    if found == 0:
        raise SystemExit("coverage gate: no executable Dart lines found")
    pct = hit * 100.0 / found
    print(f"Meaningful Dart line coverage: {hit}/{found} = {pct:.2f}% (minimum {args.minimum:.2f}%)")
    return 0 if pct + 1e-9 >= args.minimum else 1

if __name__ == "__main__":
    raise SystemExit(main())
