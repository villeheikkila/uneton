#!/usr/bin/env bash
# Generate the production secrets Uneton creates itself, once, into the
# age-encrypted `production` Fnox profile. Existing values are never replaced:
# rotating the token secret signs everyone out, and the keyring must keep old
# keys while encrypted Apple refresh tokens exist.
set -euo pipefail

repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
fnox_args=(--config "$repo_root/fnox.toml" --no-daemon --profile production)

has_secret() {
  fnox "${fnox_args[@]}" list 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -qx "$1"
}

store() {
  local key="$1"
  if has_secret "$key"; then
    cat >/dev/null
    echo "$key already set; leaving it unchanged"
    return
  fi
  fnox "${fnox_args[@]}" set --provider age "$key" >/dev/null
  echo "$key generated"
}

openssl rand -base64 48 | tr -d '\n' | store UNETON_AUTH_TOKEN_SECRET

if ! has_secret UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_ACTIVE_KEY_ID; then
  key_id="$(date -u +%Y-%m)"
  printf '{"%s":"%s"}' "$key_id" "$(openssl rand -base64 32 | tr -d '\n')" | store UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_KEYRING_JSON
  printf '%s' "$key_id" | store UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_ACTIVE_KEY_ID
fi

cat <<'NEXT'
Backup values come from maku's tenant-uneton-storage output `storage_s3`, key
`litestream`. The replica URL is s3://uneton-litestream/production.
  fnox --profile production set --provider age UNETON_LITESTREAM_REPLICA_URL
  fnox --profile production set --provider age UNETON_LITESTREAM_S3_ENDPOINT
  fnox --profile production set --provider age UNETON_BACKUP_ACCESS_KEY_ID
  fnox --profile production set --provider age UNETON_BACKUP_SECRET_ACCESS_KEY
Each command reads the value from a hidden prompt.
NEXT
