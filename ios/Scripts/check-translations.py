#!/usr/bin/env python3
"""Fail when a user-facing string has no translation.

Xcode extracts every `String(localized:)` and every literal in a `Text` into the
string catalogs at build time, and it does so silently: a new screen ships with
its English strings intact and its Dutch simply absent, which is invisible in
review and invisible on an English test device. This is the check that makes
that loud instead.

Run it after a build — extraction happens *during* the build, so a catalog
checked before one is a catalog that has not seen the new strings yet.

    python3 ios/Scripts/check-translations.py

Exit status is 1 when anything is missing, and the missing keys are printed so
they can be pasted straight into a translation pass.
"""

from __future__ import annotations

import json
import pathlib
import sys

# Every catalog in the app, so a new one cannot be added without being checked.
CATALOGS = [
    "ios/CribWire/Resources/Localizable.xcstrings",
    "ios/CribWire/Resources/InfoPlist.xcstrings",
]

# States Xcode uses for a string that has a value but is not finished with it.
# `needs_review` is what a machine translation lands as, and shipping one
# unreviewed is the thing this catches that a plain presence check would not.
UNFINISHED_STATES = {"new", "needs_review", "stale"}


def repository_root() -> pathlib.Path:
    """The repo root, whichever directory this was invoked from."""
    return pathlib.Path(__file__).resolve().parent.parent.parent


def check(path: pathlib.Path) -> list[str]:
    """Returns a human-readable problem per string that is not ready to ship."""
    catalog = json.loads(path.read_text())
    source = catalog.get("sourceLanguage", "en")
    problems: list[str] = []

    # Every language the catalog already knows about. Taken from the file rather
    # than hard-coded, so adding a language to the project makes this stricter
    # on its own instead of quietly not covering it.
    languages = {
        language
        for entry in catalog.get("strings", {}).values()
        for language in entry.get("localizations", {})
    } - {source}

    for key, entry in sorted(catalog.get("strings", {}).items()):
        # A string the project has deliberately marked as not for translation —
        # a trademark, a format placeholder — is not a gap.
        if entry.get("shouldTranslate") is False:
            continue

        localizations = entry.get("localizations", {})
        for language in sorted(languages):
            unit = localizations.get(language, {}).get("stringUnit")
            # A plural or device variation carries its values further down, and
            # its presence is enough: the shape differs per string and this
            # check has no business knowing every one of them.
            if unit is None and "variations" in localizations.get(language, {}):
                continue
            if unit is None:
                problems.append(f"[{language}] missing: {key!r}")
            elif unit.get("state") in UNFINISHED_STATES:
                problems.append(f"[{language}] {unit.get('state')}: {key!r}")

    return problems


def main() -> int:
    root = repository_root()
    problems: list[str] = []

    for relative in CATALOGS:
        path = root / relative
        if not path.exists():
            print(f"error: no catalog at {relative}", file=sys.stderr)
            return 1
        found = check(path)
        if found:
            problems.append(f"\n{relative}:")
            problems.extend(f"  {problem}" for problem in found)

    if problems:
        print("Untranslated user-facing strings:", file=sys.stderr)
        print("\n".join(problems), file=sys.stderr)
        print(
            "\nAdd the missing values to the catalog. Xcode extracts new strings "
            "during a build, so build first, then translate what appears.",
            file=sys.stderr,
        )
        return 1

    print("All catalog strings are translated.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
