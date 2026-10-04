#!/usr/bin/env bash
# Deploy a published backend digest to the shared maku host with the same
# Keychain-held deployment identity maku uses. The host allows few SSH auth
# attempts, so the agent is disabled and only this key is offered.
set -euo pipefail

image="${1:?usage: shared-deploy.sh ghcr.io/villeheikkila/uneton-backend@sha256:<digest> [ansible args...]}"
shift
vps_root="$(cd "$(dirname "$0")/.." && pwd)"
keychain_service="${UNETON_SHARED_SSH_KEYCHAIN_SERVICE:-maku-dev-codex-ssh-private-key-b64}"
temporary_identity=""
trap '[[ -z "$temporary_identity" ]] || rm -f "$temporary_identity"' EXIT

identity="${UNETON_SHARED_SSH_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  temporary_identity="$(mktemp "${TMPDIR:-/tmp}/uneton-shared-key.XXXXXX")"
  chmod 0600 "$temporary_identity"
  security find-generic-password -a default -s "$keychain_service" -w | base64 -d >"$temporary_identity" || {
    echo "SSH identity is unavailable in macOS Keychain ($keychain_service); set UNETON_SHARED_SSH_IDENTITY" >&2
    exit 2
  }
  identity="$temporary_identity"
fi

ANSIBLE_LOCAL_TEMP="${TMPDIR:-/tmp}/uneton-ansible-local" ansible-playbook \
  -i "$vps_root/ansible/inventory.shared.ini" \
  -e "ansible_ssh_private_key_file=$identity" \
  -e "uneton_backend_image=$image" \
  "$@" \
  "$vps_root/ansible/shared.yml"
