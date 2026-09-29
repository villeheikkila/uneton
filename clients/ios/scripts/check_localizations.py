#!/usr/bin/env python3
"""Check catalog coverage for Apple client localization keys."""

import json
import re
from pathlib import Path


IOS = Path(__file__).resolve().parents[1]
TARGETS = [
    IOS / "Uneton",
    IOS / "UnetonWatch",
    IOS / "UnetonWidgets",
    IOS / "UnetonPackage/Sources/UnetonActivity",
]


def check_catalog(path: Path) -> tuple[set[str], list[str]]:
    strings = json.loads(path.read_text())["strings"]
    issues = []
    for key, entry in strings.items():
        translations = {}
        for language in ("en", "fi"):
            unit = entry.get("localizations", {}).get(language, {}).get("stringUnit", {})
            if unit.get("state") != "translated" or not unit.get("value"):
                issues.append(f"{path}: {key} needs a {language} translation")
            translations[language] = unit.get("value", "")
        if translations["en"].count("%@") != translations["fi"].count("%@"):
            issues.append(f"{path}: {key} has mismatched placeholders")
        if not entry.get("comment"):
            issues.append(f"{path}: {key} needs translator context")
    return set(strings), issues


def main() -> int:
    issues = []
    for target in TARGETS:
        catalog = target / "Localizable.xcstrings"
        keys, catalog_issues = check_catalog(catalog)
        issues.extend(catalog_issues)
        used = set()
        for source in target.rglob("*.swift"):
            if source.name.startswith("GeneratedStringSymbols_"):
                continue
            content = source.read_text()
            used.update(re.findall(r"\.(loc[A-Z0-9][A-Za-z0-9]*)", content))
            used.update(re.findall(r'LocalizedStringResource\("(loc[A-Z0-9][A-Za-z0-9]*)"', content))
            used.update(re.findall(r'Text\("(loc[A-Z0-9][A-Za-z0-9]*)"', content))
            for line_number, line in enumerate(content.splitlines(), 1):
                if 'LocalizedStringResource("loc' in line and 'comment: "' not in line:
                    issues.append(f"{source}:{line_number}: localization resource needs an API comment")
                if 'Text("loc' in line and 'comment: "' not in line:
                    issues.append(f"{source}:{line_number}: localized text needs a SwiftUI comment")
                if "// L10n:" in line:
                    issues.append(f"{source}:{line_number}: use the localization API comment parameter")
        for key in sorted(used - keys):
            issues.append(f"{target}: localization key {key} has no catalog entry")
    _, info_issues = check_catalog(IOS / "Uneton/InfoPlist.xcstrings")
    issues.extend(info_issues)
    for issue in issues:
        print(issue)
    if not issues:
        print("English and Finnish catalogs cover all localization keys.")
    return bool(issues)


if __name__ == "__main__":
    raise SystemExit(main())
