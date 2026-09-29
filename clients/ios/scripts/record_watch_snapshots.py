#!/usr/bin/env python3
"""Run the Watch screenshot suite and save its named attachments for visual review."""

import json
import os
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
SNAPSHOTS = ROOT / "clients/ios/UnetonWatchUITests/__Snapshots__/WatchScreenshots"
EXPECTED = {
    "watch-awake",
    "watch-sleeping",
    "watch-temperature-history",
    "watch-temperature-entry",
    "watch-temperature-edit",
    "watch-setup",
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result-bundle", type=Path, help="Export an existing xcresult without rerunning tests")
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="uneton-watch-snapshots-") as temporary:
        result = arguments.result_bundle or Path(temporary) / "WatchScreenshots.xcresult"
        exported = Path(temporary) / "attachments"
        if arguments.result_bundle is None:
            subprocess.run(
                [
                    "xcodebuild",
                    "-project", "clients/ios/Uneton.xcodeproj",
                    "-scheme", "UnetonWatch",
                    "-destination", "platform=watchOS Simulator,name=Apple Watch Series 12 (46mm),OS=27.0",
                    "-derivedDataPath", os.environ.get(
                        "UNETON_WATCH_DERIVED_DATA", "/tmp/uneton-watch-screenshot-derived-data"
                    ),
                    "-resultBundlePath", str(result),
                    "-only-testing:UnetonWatchUITests/WatchScreenshots",
                    "test", "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64",
                ],
                cwd=ROOT,
                check=True,
            )
        subprocess.run(
            ["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
             "--output-path", str(exported)],
            check=True,
        )
        attachments = json.loads((exported / "manifest.json").read_text())
        found: dict[str, Path] = {}
        for test in attachments:
            for attachment in test["attachments"]:
                name = attachment["suggestedHumanReadableName"].split("_0_", maxsplit=1)[0]
                if name in EXPECTED:
                    if name in found:
                        raise ValueError(f"Duplicate Watch screenshot: {name}")
                    found[name] = exported / attachment["exportedFileName"]
        if found.keys() != EXPECTED:
            raise ValueError(f"Expected {sorted(EXPECTED)}, found {sorted(found)}")
        SNAPSHOTS.mkdir(parents=True, exist_ok=True)
        for name, source in sorted(found.items()):
            destination = SNAPSHOTS / f"{name}.png"
            shutil.copyfile(source, destination)
            print(destination.relative_to(ROOT))


if __name__ == "__main__":
    main()
