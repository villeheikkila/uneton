# Uneton on Maku's shared VPS

This is the deployment configuration to add to Maku's **shared services** VPS. The source of that host's runtime is `../maku/platform/infra/shared-services/runtime/`, and its Ansible role is `../maku/platform/infra/vps/ansible/roles/shared_traceway/`. It installs one Compose project, `maku-shared-observability`, under `/srv/maku/shared-observability`. Maku's separate application VPS Compose stack is not the target. This document changes no Maku files and does not deploy Uneton.

The shared Compose project already has the only public Caddy on ports 80 and 443. Add Uneton's API and Litestream to **that same Compose file and project**, on its default network. Do not start `platform/infra/vps/runtime/compose.yaml` on the shared host: that standalone Caddy would compete for the public ports. An override that adds services only to the shared project at rollout time would also be undone by the Ansible role's next `up -d --remove-orphans`. Keep the standalone stack for disposable OrbStack rehearsal.

## Shared Compose additions

Merge these services and volume into `../maku/platform/infra/shared-services/runtime/compose.yaml`. The existing `name`, Caddy, Traceway, and collector services remain in the same file. The backend image value must be a published, multi-platform **digest**, verified to include `linux/amd64` for this CX23 host. A commit tag identifies source, but a digest fixes the exact bytes deployed.

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

There are no `ports` or blanket `env_file` entries on these services. This keeps the API reachable only through the shared Compose network and avoids passing Traceway secrets to Uneton. The image's `/data` directory is owned by UID 10001; the init service also repairs ownership of a newly created named volume. Use a pinned Litestream image digest in the final host change, as Maku does for its existing images. The 512 MiB API limit is a starting allocation, not a capacity claim; measure it alongside Traceway's 2 GiB limit on the 4 GiB host.

Copy this file as `/srv/maku/shared-observability/uneton-litestream.yml` from the shared Ansible role:

```yaml
dbs:
  - path: /data/uneton.sqlite
    replicas:
      - url: ${LITESTREAM_REPLICA_URL}
        retention: 24h
```

Use an off-host object-store URL such as `s3://<bucket>/uneton/production`. The local rehearsal's `file:///backup` is on the same machine and does not protect against host loss. If the chosen store uses an S3-compatible endpoint, add the endpoint to the Litestream replica configuration and test restore with that provider before rollout. Grant the replica credentials access only to Uneton's backup prefix. Retention and recovery objectives should be agreed before treating this as production storage.

## Shared Caddy and DNS

Append a site to Maku's **existing** `Caddyfile`:

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

Point `api.uneton.app` A and AAAA records to the shared VPS public addresses in the DNS zone that owns `uneton.app`. Maku's Terraform currently owns only `traceway.getmaku.app` DNS, so adding Uneton DNS requires an explicit owner. Caddy obtains the certificate once DNS points to this host. The existing firewall already exposes TCP 80/443 and UDP 443; no new public port is needed. Preserve all API paths, including ConnectRPC, `/health/ready`, `/privacy`, `/terms`, `/support`, and Apple's `/apple/server-notifications` callback.

## Secrets and Ansible rollout

Extend the shared Ansible role to copy the Litestream file, render Uneton's values into its root-owned `0600` `/srv/maku/shared-observability/.env`, and validate the *merged* Compose configuration before `pull` and `up -d --remove-orphans`. Put the values in the host's existing secret source, not in Git. The Compose example consumes these `.env` names:

| Name | Source or purpose |
| --- | --- |
| `UNETON_BACKEND_IMAGE` | `ghcr.io/villeheikkila/uneton-backend@sha256:<multiarch digest>` |
| `UNETON_AUTH_TOKEN_SECRET` | At least 32 random bytes; preserve across restarts |
| `UNETON_LEGAL_OPERATOR_NAME`, `UNETON_LEGAL_CONTACT_EMAIL` | The same legal identity used for local privacy and ASC metadata |
| `UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_ACTIVE_KEY_ID`, `UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_KEYRING_JSON` | Preserve old keys while encrypted refresh tokens exist |
| `UNETON_INTEGRATION_APPLE_TEAM_ID`, `UNETON_INTEGRATION_APPLE_PRIVATE_KEY_ID`, `UNETON_INTEGRATION_APPLE_PRIVATE_KEY_PEM` | Sign in with Apple credentials; encode PEM newlines as literal `\n` |
| `UNETON_LITESTREAM_REPLICA_URL`, `UNETON_BACKUP_ACCESS_KEY_ID`, `UNETON_BACKUP_SECRET_ACCESS_KEY` | Dedicated off-host backup destination and scoped credentials |

If the Apple integration key cannot send APNs, add the four `UNETON_INTEGRATION_APNS_*` variables from `platform/backend/.env.example` to the API service and the secret template. The App Review phone is for local ASC submission, not a backend runtime variable. Keep personal contact values age-encrypted in Uneton's local `fnox.toml`; the server secret source must supply its own production copy. The `.env` file and `docker compose config` output contain secrets, so do not log or commit the rendered configuration.

The current Maku shared Ansible role is the deployment owner. It copies runtime files, writes `.env`, validates Compose, pulls images, starts the project, waits for service health, and checks the public listener allowlist. Extend its health verification to check `uneton-api` and backup freshness. Run the Maku Ansible command **locally** when the host change is ready; no remote CI/CD is needed. Services added only through a local override of that Compose project would be removed by Maku's next `--remove-orphans` run.

## Release and recovery sequence

1. From a clean Uneton commit, run local tests and rehearsal, then `mise run release:ghcr -- --publish`. Inspect the published manifest for both `linux/amd64` and `linux/arm64`, and record its digest. Publishing does not deploy.
2. Prepare an off-host backup bucket and credentials. Test a backup and a restore with disposable data using the chosen object store. Verify that the shared host has enough CPU, memory, and disk headroom for Traceway and Uneton together.
3. In a separate, reviewed Maku change, integrate the Compose services, Caddy site, Litestream file, secret template, and Ansible health checks above. Deploy that project from the local machine. Check internal API health and Litestream replication before changing DNS.
4. Point `api.uneton.app` at the shared host, then verify HTTPS `/health/ready`, legal pages, an authenticated app flow, and Apple server notification reachability. Verify backup freshness again after real traffic begins.

For a restore, stop **both** `uneton-api` and `uneton-litestream` before replacing the SQLite files from the off-host replica. Rotate `/data/uneton.sqlite.sync-generation` before starting the API so clients receive a snapshot after lineage changes. Ensure restored files are writable by UID 10001, start the API and then Litestream, and verify readiness, sync recovery, and a new backup. The existing `infra:orb:restore-test` script assumes `/srv/uneton` and a local file replica; it is not a shared-host restore procedure. Add and rehearse a host-specific restore operation as part of the Maku integration.
