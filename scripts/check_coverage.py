#!/usr/bin/env python3
"""Fail CI when meaningful Dart line coverage drops below the project floor.

Only generated serialization and localization output is excluded. Platform,
bootstrap, and fallback code remains part of the measured application.
"""
from __future__ import annotations

import argparse
import fnmatch
import math
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

def coverage_by_file(path: Path, patterns: list[str] | None = None) -> dict[str, dict[int, bool]]:
    """Merge repeated LCOV records by source line, retaining any observed hit."""
    sources: dict[str, dict[int, bool]] = {}
    current: dict[int, bool] | None = None
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        if raw.startswith("SF:"):
            source = raw[3:].replace("\\", "/")
            selected = not patterns or any(fnmatch.fnmatchcase(source, p) for p in patterns)
            current = sources.setdefault(source, {}) if included(source) and selected else None
        elif raw == "end_of_record":
            current = None
        elif current is not None and raw.startswith("DA:"):
            line, count, *_ = raw[3:].split(",")
            line_number, execution_count = int(line), int(count)
            if line_number <= 0 or execution_count < 0:
                raise ValueError(f"invalid LCOV line/count: {raw}")
            current[line_number] = current.get(line_number, False) or execution_count > 0
    return sources


def read_lcov(path: Path, patterns: list[str] | None = None) -> tuple[int, int]:
    sources = coverage_by_file(path, patterns)
    return sum(map(len, sources.values())), sum(sum(lines.values()) for lines in sources.values())

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("lcov", type=Path)
    parser.add_argument("--minimum", type=float, required=True)
    parser.add_argument("--include", action="append", help="source-path glob; repeat to select critical modules")
    parser.add_argument("--show-files", action="store_true", help="report each measured file, lowest coverage first")
    args = parser.parse_args()
    if not math.isfinite(args.minimum) or not 0 <= args.minimum <= 100:
        parser.error("--minimum must be a finite percentage between 0 and 100")
    sources = coverage_by_file(args.lcov, args.include)
    found, hit = sum(map(len, sources.values())), sum(sum(lines.values()) for lines in sources.values())
    if found == 0:
        raise SystemExit("coverage gate: no executable Dart lines found")
    pct = hit * 100.0 / found
    print(f"Meaningful Dart line coverage: {hit}/{found} = {pct:.2f}% (minimum {args.minimum:.2f}%)")
    if args.show_files:
        measured = [(sum(lines.values()) * 100.0 / len(lines), source, sum(lines.values()), len(lines))
                    for source, lines in sources.items() if lines]
        for file_pct, source, file_hit, file_found in sorted(measured):
            print(f"  {file_pct:6.2f}% {file_hit:5d}/{file_found:<5d} {source}")
    return 0 if pct + 1e-9 >= args.minimum else 1

if __name__ == "__main__":
    raise SystemExit(main())
