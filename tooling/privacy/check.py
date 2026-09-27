#!/usr/bin/env python3
"""Fail closed when the authoritative schema or privacy declarations drift."""

import hashlib
import json
import plistlib
import sqlite3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCHEMA = ROOT / "platform/backend/internal/store/migrations/001_initial.sql"
INVENTORY = ROOT / "docs/privacy-data-inventory.json"
DECLARATION = ROOT / "clients/ios/asc/privacy.json"
MANIFEST = ROOT / "clients/ios/Uneton/PrivacyInfo.xcprivacy"
LEGAL = ROOT / "platform/backend/internal/legal"

CATEGORY_TO_MANIFEST = {
    "CONTACTS": "NSPrivacyCollectedDataTypeContacts",
    "DEVICE_ID": "NSPrivacyCollectedDataTypeDeviceID",
    "HEALTH": "NSPrivacyCollectedDataTypeHealth",
    "NAME": "NSPrivacyCollectedDataTypeName",
    "OTHER_DIAGNOSTIC_DATA": "NSPrivacyCollectedDataTypeOtherDiagnosticData",
    "OTHER_USAGE_DATA": "NSPrivacyCollectedDataTypeOtherUsageData",
    "OTHER_USER_CONTENT": "NSPrivacyCollectedDataTypeOtherUserContent",
    "USER_ID": "NSPrivacyCollectedDataTypeUserID",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    schema = SCHEMA.read_bytes()
    inventory = json.loads(INVENTORY.read_text())
    declaration = json.loads(DECLARATION.read_text())
    manifest = plistlib.loads(MANIFEST.read_bytes())

    require(inventory["schemaVersion"] == 1, "Unsupported privacy inventory version")
    require(
        inventory["authoritativeSchemaSha256"] == hashlib.sha256(schema).hexdigest(),
        "Authoritative SQLite schema changed; reconcile the privacy inventory and declarations",
    )

    database = sqlite3.connect(":memory:")
    database.executescript(schema.decode())
    tables = {
        row[0]
        for row in database.execute(
            "select name from sqlite_master where type = 'table' and name not like 'sqlite_%'"
        )
    }
    require(tables == set(inventory["tables"]), "Privacy inventory table coverage differs from SQLite")
    for table, table_categories in inventory["tables"].items():
        require(isinstance(table_categories, list), f"Privacy categories for {table} must be a list")
        require(len(table_categories) == len(set(table_categories)), f"Duplicate privacy category for {table}")
    for sources in inventory["additionalCollection"].values():
        require(isinstance(sources, list) and sources, "Additional collection must name its source files")
        for source in sources:
            require((ROOT / source).is_file(), f"Missing privacy collection source: {source}")

    categories = set(inventory["additionalCollection"])
    for table_categories in inventory["tables"].values():
        categories.update(table_categories)
    require(categories <= CATEGORY_TO_MANIFEST.keys(), "Unknown Apple privacy category in inventory")

    usages = declaration["dataUsages"]
    require(declaration["schemaVersion"] == 1, "Unsupported App Store privacy declaration version")
    require(len(usages) == len(categories), "App Store privacy declaration has duplicate or missing categories")
    require({usage["category"] for usage in usages} == categories, "App Store privacy categories differ from inventory")
    for usage in usages:
        require(usage["purposes"] == ["APP_FUNCTIONALITY"], "Unexpected App Store privacy purpose")
        require(usage["dataProtections"] == ["DATA_LINKED_TO_YOU"], "Unexpected App Store privacy protection")

    require(manifest.get("NSPrivacyTracking") is False, "App privacy manifest must explicitly disable tracking")
    require(
        manifest.get("NSPrivacyAccessedAPITypes") == [
            {
                "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
                "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
            }
        ],
        "App privacy manifest must declare app-only UserDefaults access",
    )
    collected = manifest.get("NSPrivacyCollectedDataTypes", [])
    require(len(collected) == len(categories), "App privacy manifest has duplicate or missing categories")
    expected = {CATEGORY_TO_MANIFEST[category] for category in categories}
    require({item["NSPrivacyCollectedDataType"] for item in collected} == expected, "App privacy manifest differs from inventory")
    for item in collected:
        require(item["NSPrivacyCollectedDataTypeLinked"] is True, "App privacy data must be marked linked")
        require(item["NSPrivacyCollectedDataTypeTracking"] is False, "App privacy data must not be marked for tracking")
        require(
            item["NSPrivacyCollectedDataTypePurposes"] == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"],
            "Unexpected app privacy manifest purpose",
        )

    for name in ("privacy", "terms", "support"):
        for suffix in ("", ".fi"):
            page = (LEGAL / f"{name}{suffix}.html").read_text()
            require("{{.Email}}" in page, f"{name}{suffix} is missing its configured contact")
            if name != "support":
                require("{{.Operator}}" in page, f"{name}{suffix} is missing its configured operator")

    print(f"Privacy inventory covers {len(tables)} SQLite tables and {len(categories)} Apple data categories")


if __name__ == "__main__":
    main()
