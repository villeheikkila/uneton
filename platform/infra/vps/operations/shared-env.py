#!/usr/bin/env python3
"""Render the shared host's root-only Compose `.env` from the `production` Fnox profile.

Prints the file to stdout for Ansible to install with `no_log`. Nothing is
written to disk here. Compose interpolates these names into each service's own
`environment:` block, so no service receives another's secrets.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[4]

REQUIRED = [
    "UNETON_AUTH_TOKEN_SECRET",
    "UNETON_LEGAL_OPERATOR_NAME",
    "UNETON_LEGAL_CONTACT_EMAIL",
    "UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_ACTIVE_KEY_ID",
    "UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_KEYRING_JSON",
    "UNETON_INTEGRATION_APPLE_TEAM_ID",
    "UNETON_INTEGRATION_APPLE_PRIVATE_KEY_ID",
    "UNETON_INTEGRATION_APPLE_PRIVATE_KEY_PEM",
    "UNETON_LITESTREAM_REPLICA_URL",
    "UNETON_BACKUP_ACCESS_KEY_ID",
    "UNETON_BACKUP_SECRET_ACCESS_KEY",
]
OPTIONAL = [
    "UNETON_LITESTREAM_S3_ENDPOINT",
    "UNETON_INTEGRATION_APNS_TEAM_ID",
    "UNETON_INTEGRATION_APNS_PRIVATE_KEY_ID",
    "UNETON_INTEGRATION_APNS_PRIVATE_KEY_PEM",
    "UNETON_INTEGRATION_APNS_TOPIC",
]
APNS = OPTIONAL[1:]
FIXED = {
    "COMPOSE_PROJECT_NAME": "uneton",
    "COMPOSE_FILE": "compose.yaml:compose.shared.yaml",
    "UNETON_RUNTIME_ENVIRONMENT": "production",
    "UNETON_AUTH_APPLE_CLIENT_ID": "solutions.bytesized.uneton",
    "UNETON_AUTH_APPLE_SERVER_NOTIFICATION_URL": "https://api.uneton.app/apple/server-notifications",
}
# Compose maps these .env names to the names Litestream reads.
RENAMED = {
    "UNETON_LITESTREAM_REPLICA_URL": "LITESTREAM_REPLICA_URL",
    "UNETON_LITESTREAM_S3_ENDPOINT": "LITESTREAM_S3_ENDPOINT",
}


def fail(message):
    print(f"shared-env: {message}", file=sys.stderr)
    sys.exit(2)


def production_secrets():
    command = ["fnox", "--config", str(REPO_ROOT / "fnox.toml"), "--no-daemon", "--profile", "production",
               "export", "--all", "--format", "json"]
    # Fnox lets the process environment override stored values; a deploy must not.
    environment = {key: value for key, value in os.environ.items() if not key.startswith("UNETON_")}
    result = subprocess.run(command, capture_output=True, text=True, env=environment, check=False)
    if result.returncode != 0:
        fail(f"fnox export failed: {result.stderr.strip()}")
    return json.loads(result.stdout)["secrets"]


def single_line(key, value):
    value = str(value)
    if key.endswith("_PEM"):
        # The backend expects PEM newlines as literal \n escapes on one line.
        value = value.strip().replace("\r\n", "\n").replace("\n", "\\n")
    if "\n" in value or "'" in value:
        fail(f"{key} must be a single line without single quotes")
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True, help="backend image pinned by digest")
    args = parser.parse_args()
    if not re.fullmatch(r"[^\s@]+@sha256:[0-9a-f]{64}", args.image):
        fail("--image must be pinned by digest (name@sha256:...)")

    secrets = production_secrets()
    missing = [key for key in REQUIRED if not str(secrets.get(key, "")).strip()]
    if missing:
        fail("missing from the production profile: " + ", ".join(missing))
    if len(str(secrets["UNETON_AUTH_TOKEN_SECRET"])) < 32:
        fail("UNETON_AUTH_TOKEN_SECRET must be at least 32 characters")
    apns_set = [key for key in APNS if str(secrets.get(key, "")).strip()]
    if apns_set and len(apns_set) != len(APNS):
        fail("set all four UNETON_INTEGRATION_APNS_* values or none")

    values = dict(FIXED, COMPOSE_BACKEND_IMAGE=args.image)
    for key in REQUIRED + OPTIONAL:
        value = str(secrets.get(key, "")).strip()
        if value:
            values[RENAMED.get(key, key)] = single_line(key, value)

    # Single quotes keep Compose from interpolating `$` or `#` inside values.
    for key, value in values.items():
        print(f"{key}='{value}'")


if __name__ == "__main__":
    main()
