# Uneton in a shared VPS Compose stack

This is a host-neutral configuration for running Uneton inside an existing shared Docker Compose project. It assumes the host already has a public Caddy service and a local deployment process that owns the Compose file, Caddyfile, and private environment. Adapt the host paths and deployment commands to that project. This guide does not deploy Uneton.

Use the existing Caddy on ports 80 and 443. Add Uneton's API and Litestream to **that same Compose file and project**, on its default network. Do not start `platform/infra/vps/runtime/compose.yaml` on the shared host: that standalone Caddy would compete for the public ports. If the host rollout uses `up -d --remove-orphans`, commit the new services to its canonical Compose definition so the next rollout retains them. Keep Uneton's standalone stack for disposable OrbStack rehearsal.

## Shared Compose additions

Merge these services and volume into the host's canonical Compose file. Keep its existing project name and services. Set the backend image to a published, multi-platform **digest** that includes the host's architecture. A commit tag identifies source, but a digest fixes the exact bytes deployed.

```yaml
services:
  uneton-data-init:
    image: alpine:3.23@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0
    pull_policy: always
    restart: "no"
    user: "0:0"
    read_only: true
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    cap_add: [CHOWN]
    entrypoint: ["/bin/sh", "-ec"]
    command: ["chown 10001:10001 /data"]
    volumes:
      - uneton_data:/data

  uneton-api:
    image: ${UNETON_BACKEND_IMAGE:?set UNETON_BACKEND_IMAGE to a manifest digest}
    pull_policy: always
    restart: unless-stopped
    stop_grace_period: 40s
    user: "10001:10001"
    mem_limit: 512m
    pids_limit: 128
    read_only: true
    tmpfs:
      - /tmp:rw,noexec,nosuid,nodev,size=32m
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    environment:
      UNETON_RUNTIME_ENVIRONMENT: production
      UNETON_DATABASE_PATH: /data/uneton.sqlite
      UNETON_HTTP_LISTEN_ADDRESS: 0.0.0.0:8080
      UNETON_AUTH_TOKEN_SECRET: ${UNETON_AUTH_TOKEN_SECRET:?set UNETON_AUTH_TOKEN_SECRET}
      UNETON_LEGAL_OPERATOR_NAME: ${UNETON_LEGAL_OPERATOR_NAME:?set UNETON_LEGAL_OPERATOR_NAME}
      UNETON_LEGAL_CONTACT_EMAIL: ${UNETON_LEGAL_CONTACT_EMAIL:?set UNETON_LEGAL_CONTACT_EMAIL}
      UNETON_AUTH_APPLE_CLIENT_ID: solutions.bytesized.uneton
      UNETON_AUTH_APPLE_SERVER_NOTIFICATION_URL: https://api.uneton.app/apple/server-notifications
      UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_ACTIVE_KEY_ID: ${UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_ACTIVE_KEY_ID:?set active key ID}
      UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_KEYRING_JSON: ${UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_KEYRING_JSON:?set keyring}
      UNETON_INTEGRATION_APPLE_TEAM_ID: ${UNETON_INTEGRATION_APPLE_TEAM_ID:?set Apple team ID}
      UNETON_INTEGRATION_APPLE_PRIVATE_KEY_ID: ${UNETON_INTEGRATION_APPLE_PRIVATE_KEY_ID:?set Apple key ID}
      UNETON_INTEGRATION_APPLE_PRIVATE_KEY_PEM: ${UNETON_INTEGRATION_APPLE_PRIVATE_KEY_PEM:?set Apple private key}
    volumes:
      - uneton_data:/data
    depends_on:
      uneton-data-init:
        condition: service_completed_successfully
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1:8080/health/ready"]
      interval: 5s
      timeout: 3s
      start_period: 5s
      retries: 6

  uneton-litestream:
    image: litestream/litestream:0.3
    pull_policy: always
    restart: unless-stopped
    command: replicate
    read_only: true
    tmpfs:
      - /tmp:rw,noexec,nosuid,nodev,size=16m
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    environment:
      LITESTREAM_REPLICA_URL: ${UNETON_LITESTREAM_REPLICA_URL:?set off-host replica URL}
      LITESTREAM_ACCESS_KEY_ID: ${UNETON_BACKUP_ACCESS_KEY_ID:?set backup access key}
      LITESTREAM_SECRET_ACCESS_KEY: ${UNETON_BACKUP_SECRET_ACCESS_KEY:?set backup secret key}
    volumes:
      - uneton_data:/data
      - ./uneton-litestream.yml:/etc/litestream.yml:ro
    depends_on:
      uneton-api:
        condition: service_healthy

volumes:
  uneton_data:
```

There are no `ports` or blanket `env_file` entries on these services. This keeps the API reachable only through the shared Compose network and avoids passing other services' secrets to Uneton. The image's `/data` directory is owned by UID 10001; the init service also repairs ownership of a newly created named volume. Pin the Litestream image by digest in the final host configuration. The 512 MiB API limit is a starting allocation, not a capacity claim; measure it alongside the host's other services.

Place `uneton-litestream.yml` beside the host's Compose file:

```yaml
dbs:
  - path: /data/uneton.sqlite
    replicas:
      - url: ${LITESTREAM_REPLICA_URL}
        retention: 24h
```

Use an off-host object-store URL such as `s3://<bucket>/uneton/production`. The local rehearsal's `file:///backup` is on the same machine and does not protect against host loss. If the chosen store uses an S3-compatible endpoint, add the endpoint to the Litestream replica configuration and test restore with that provider before rollout. Grant the replica credentials access only to Uneton's backup prefix. Retention and recovery objectives should be agreed before treating this as production storage.

## Shared Caddy and DNS

Append a site to the host's **existing** `Caddyfile`:

```caddyfile
api.uneton.app {
	encode zstd gzip
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		X-Frame-Options DENY
		Referrer-Policy strict-origin-when-cross-origin
		-Server
	}
	reverse_proxy uneton-api:8080 {
		header_up X-Real-IP {remote_host}
		transport http {
			dial_timeout 5s
			response_header_timeout 35s
		}
	}
}
```

Point `api.uneton.app` A and AAAA records to the shared VPS public addresses in the DNS zone that owns `uneton.app`. Assign ownership of those records in the host's DNS configuration. Caddy obtains the certificate once DNS points to this host. Expose TCP 80/443 and, if HTTP/3 is enabled, UDP 443; no Uneton-specific public port is needed. Preserve all API paths, including ConnectRPC, `/health/ready`, `/privacy`, `/terms`, `/support`, and Apple's `/apple/server-notifications` callback.

## Secrets and host rollout

Extend the host's local deployment process to install the Litestream file, render Uneton's values into a root-owned `0600` `.env` next to the Compose file, and validate the merged Compose configuration before pulling images and starting services. Put the values in the host's secret source, not in Git. The Compose example consumes these `.env` names:

| Name | Source or purpose |
| --- | --- |
| `UNETON_BACKEND_IMAGE` | `ghcr.io/villeheikkila/uneton-backend@sha256:<multiarch digest>` |
| `UNETON_AUTH_TOKEN_SECRET` | At least 32 random bytes; preserve across restarts |
| `UNETON_LEGAL_OPERATOR_NAME`, `UNETON_LEGAL_CONTACT_EMAIL` | The same legal identity used for local privacy and ASC metadata |
| `UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_ACTIVE_KEY_ID`, `UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_KEYRING_JSON` | Preserve old keys while encrypted refresh tokens exist |
| `UNETON_INTEGRATION_APPLE_TEAM_ID`, `UNETON_INTEGRATION_APPLE_PRIVATE_KEY_ID`, `UNETON_INTEGRATION_APPLE_PRIVATE_KEY_PEM` | Sign in with Apple credentials; encode PEM newlines as literal `\n` |
| `UNETON_LITESTREAM_REPLICA_URL`, `UNETON_BACKUP_ACCESS_KEY_ID`, `UNETON_BACKUP_SECRET_ACCESS_KEY` | Dedicated off-host backup destination and scoped credentials |

If the Apple integration key cannot send APNs, add the four `UNETON_INTEGRATION_APNS_*` variables from `platform/backend/.env.example` to the API service and the secret template. The App Review phone is for local ASC submission, not a backend runtime variable. Keep personal contact values age-encrypted in Uneton's local `fnox.toml`; the server secret source must supply its own production copy. The `.env` file and `docker compose config` output contain secrets, so do not log or commit the rendered configuration.

Have the host's deployment process verify `uneton-api` health, backup freshness, and the public listener allowlist after rollout. Drive deployment from the local machine; no remote CI/CD is needed. If that process uses `--remove-orphans`, services added only through a temporary local Compose override will be removed on its next run.

## Release and recovery sequence

1. From a clean Uneton commit, run local tests and rehearsal, then `mise run release:ghcr -- --publish`. Inspect the published manifest for both `linux/amd64` and `linux/arm64`, and record its digest. Publishing does not deploy.
2. Prepare an off-host backup bucket and credentials. Test a backup and a restore with disposable data using the chosen object store. Verify that the shared host has enough CPU, memory, and disk headroom for Uneton and its existing services.
3. In the host configuration, integrate the Compose services, Caddy site, Litestream file, secret template, and health checks above. Deploy that project from the local machine. Check internal API health and Litestream replication before changing DNS.
4. Point `api.uneton.app` at the shared host, then verify HTTPS `/health/ready`, legal pages, an authenticated app flow, and Apple server notification reachability. Verify backup freshness again after real traffic begins.

For a restore, stop **both** `uneton-api` and `uneton-litestream` before replacing the SQLite files from the off-host replica. Rotate `/data/uneton.sqlite.sync-generation` before starting the API so clients receive a snapshot after lineage changes. Ensure restored files are writable by UID 10001, start the API and then Litestream, and verify readiness, sync recovery, and a new backup. The existing `infra:orb:restore-test` script assumes `/srv/uneton` and a local file replica; it is not a shared-host restore procedure. Add and rehearse a host-specific restore operation as part of the deployment integration.
