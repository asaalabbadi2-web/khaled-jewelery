#!/usr/bin/env python3
"""launchd plist guard — every plist under backend/ops must be loadable.

A literal `&&` inside a <string> once made both macOS backup agents invalid XML.
launchctl rejected the files outright, so the scheduled backup was not merely
disabled, it was uninstallable -- silently, for months. This guard exists to stop
that class of defect returning, and nothing else: it does not test backups.

Why plistlib and not `plutil -lint`:
    plutil is LENIENT. It accepts a `--` inside an XML comment, which is illegal
    XML and which Python's expat rejects. Measured 2026-09-27: a plist that
    plutil called "OK" failed plistlib at the offending line. The stricter
    parser is the binding one, and it is also the one that runs on Linux in CI.

Checks, per file:
    1. parses as a property list (strict XML)
    2. a non-empty string Label
    3. a non-empty ProgramArguments list of strings

Fail-closed: finding no plists at all is a failure, so a moved or deleted agent
cannot make this guard pass by vacuum.

Usage:
    python scripts/plist_guard.py
"""
from __future__ import annotations

import plistlib
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
SEARCH_DIR = REPO_ROOT / "backend" / "ops"


def _check(path: Path) -> list[str]:
    """Return a list of problems with one plist; empty means it is fine."""
    try:
        with path.open("rb") as handle:
            data = plistlib.load(handle)
    except Exception as exc:                      # noqa: BLE001 - report, never raise
        return [f"does not parse as a property list: {exc}"]

    if not isinstance(data, dict):
        return [f"top level is {type(data).__name__}, expected a dict"]

    problems: list[str] = []

    label = data.get("Label")
    if not isinstance(label, str) or not label.strip():
        problems.append("missing or empty Label")

    args = data.get("ProgramArguments")
    if not isinstance(args, list) or not args:
        problems.append("missing or empty ProgramArguments")
    elif not all(isinstance(a, str) for a in args):
        problems.append("ProgramArguments contains a non-string entry")

    return problems


def main() -> int:
    if not SEARCH_DIR.is_dir():
        print(f"❌ plist guard: {SEARCH_DIR.relative_to(REPO_ROOT)} does not exist")
        return 1

    paths = sorted(SEARCH_DIR.glob("**/*.plist"))
    if not paths:
        print(f"❌ plist guard: no .plist files under {SEARCH_DIR.relative_to(REPO_ROOT)}")
        print("   Fail-closed on purpose: a moved or deleted agent must not pass silently.")
        return 1

    failed = 0
    for path in paths:
        rel = path.relative_to(REPO_ROOT)
        problems = _check(path)
        if problems:
            failed += 1
            print(f"❌ {rel}")
            for problem in problems:
                print(f"     {problem}")
        else:
            print(f"✅ {rel}")

    if failed:
        print(f"\n❌ plist guard: {failed} of {len(paths)} plist(s) would not load.")
        return 1

    print(f"\n✅ plist guard: {len(paths)} plist(s) OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
