# Uneton on the shared maku host

Production Uneton runs on `maku-shared` (Hetzner CX23, hel1, `77.42.74.51` / `2a01:4f9:c012:5b0a::2`) beside Traceway. Ownership is split so each project deploys independently:

| Owner | What |
| --- | --- |
| maku `platform/infra/tenants/uneton/` | The tenant declaration: `tenant.yml` (site), `dns.tfvars`, `storage.tfvars` |
| maku Terraform `tenant-uneton-dns` | Bunny DNS zone for `uneton.app` and the `api` records |
| maku Terraform `tenant-uneton-storage` | Bunny S3 storage zone `uneton-litestream` (DE) for Litestream |
| maku Ansible `shared-services.yml` | Docker, the `shared-edge` network, and the only public Caddy (80/443), which renders the `api.uneton.app` site from `tenant.yml` |
| Uneton Ansible `platform/infra/vps/ansible/shared.yml` | `/srv/uneton`: the `uneton` Compose project (API, Litestream, data init) and its root-only `.env` |
| Uneton Fnox `production` profile | Every Uneton runtime secret, age-encrypted in `fnox.toml` |

Uneton is a tenant of that host under maku's tenant contract (`platform/infra/tenants/README.md` in maku): a separate Compose project, not services merged into maku's. maku's rollout runs `up --remove-orphans` on its own project, which never touches `uneton`, and a Uneton release needs no maku change. The API joins the external `shared-edge` network under the alias `uneton-api`; maku's Caddy joins the same network and proxies `api.uneton.app` to `uneton-api:8080`. No Uneton port is published on the host. If Uneton is down, that site returns 502 and Traceway is unaffected.

`platform/infra/vps/runtime/compose.yaml` is the single service definition. On the shared host, `.env` sets `COMPOSE_FILE=compose.yaml:compose.shared.yaml`, which adds the edge network, and leaves the `standalone` profile off, so Uneton's own Caddy never starts. OrbStack rehearsal sets `COMPOSE_PROFILES=standalone` and keeps its own Caddy and file replica.

## First deployment

Run maku steps from the maku checkout and Uneton steps from this one.

1. **Terraform (maku).** Run `mise run //platform/infra:terraform:bootstrap-hcp`; it creates `maku-tenant-uneton-dns` and `maku-tenant-uneton-storage` from the files in `tenants/uneton/` and gives them the Bunny credential. Then:

   ```sh
   mise run //platform/infra:terraform plan tenant-uneton-dns
   CONFIRM_TERRAFORM_APPLY=tenant-uneton-dns mise run //platform/infra:terraform apply tenant-uneton-dns
   export ALLOW_TERRAFORM_CREATE='bunnynet_storage_zone.this["litestream"]'
   mise run //platform/infra:terraform plan tenant-uneton-storage
   CONFIRM_TERRAFORM_APPLY=tenant-uneton-storage mise run //platform/infra:terraform apply tenant-uneton-storage
   unset ALLOW_TERRAFORM_CREATE
   ```

   The plan guard refuses to create storage zones unless the address is named, so a zone lost from state can never be recreated silently. Use `ALLOW_TERRAFORM_CREATE` only for this first creation. Note the `nameservers` output of the DNS scope.

2. **Porkbun.** Delegate `uneton.app` to Bunny; see [Porkbun delegation](#porkbun-delegation).

3. **Secrets (Uneton).** `mise run deploy:shared:secrets` generates the token secret and the Apple refresh-token keyring once and never replaces them. Read the backup values from the `storage_s3` output of `tenant-uneton-storage` (key `litestream`) and store each one with the commands the task prints. The replica URL is `s3://uneton-litestream/production`. Legal, Sign in with Apple and APNs values are inherited from the default Fnox secrets.

4. **Image (Uneton).** From a clean commit, `mise run release:ghcr -- --publish`, then record the printed index digest. Make the `uneton-backend` GHCR package public (the source is AGPL and public), or the host cannot pull it.

5. **Shared host (maku).** `mise run //platform/infra:vps:ansible:shared:apply` creates `shared-edge`, attaches Caddy, renders the `api.uneton.app` site from `tenant.yml` and reloads Caddy. Caddy requests the certificate once DNS resolves to the host.

6. **Uneton.** `mise run deploy:shared -- ghcr.io/villeheikkila/uneton-backend@sha256:<digest>`. It renders `.env` on the controller from the `production` profile, validates Compose, pulls, starts with `--wait`, checks readiness from inside maku's Caddy over `shared-edge`, and waits for the first Litestream snapshot.

7. **Verify publicly.** `curl https://api.uneton.app/health/ready`, open `/privacy` and `/terms`, sign in from a TestFlight build, and confirm new objects under `production/` in the `uneton-litestream` storage zone.

8. **Apple.** In the developer account, set the Sign in with Apple server-to-server notification endpoint for the App ID to `https://api.uneton.app/apple/server-notifications`.

Later releases repeat steps 4 and 6 only.

## Porkbun delegation

Porkbun currently serves only its parking defaults for `uneton.app` (apex and wildcard to `pixie.porkbun.com`), with no mail or verification records, so nothing needs copying.

1. Apply `tenant-uneton-dns` first and confirm Bunny answers: `dig +short A api.uneton.app @<first Bunny nameserver>` returns `77.42.74.51`.
2. In Porkbun, open **Domain Management**, then **Details** for `uneton.app`, then **Authoritative Nameservers**. Replace the four `*.ns.porkbun.com` entries with the two Bunny nameservers from the `nameservers` output, and save.
3. In the same domain's details, leave **DNSSEC** empty for now. A stale DS record would make the domain unresolvable after delegation.
4. Wait for `dig +short NS uneton.app` to return the Bunny nameservers and `dig +short A api.uneton.app` to return `77.42.74.51`. This is usually done within an hour but can take up to 48 hours. `.app` is HSTS-preloaded, so the API only works once Caddy has its certificate.
5. Optional, once delegation is stable: set `dnssec_enabled = true` in maku's `tenants/uneton/dns.tfvars`, apply, read the sensitive `dnssec` output, and add that DS record in Porkbun's **DNSSEC** section (key tag, algorithm, digest type, digest).

Keep URL forwarding and Porkbun's email forwarding off for the domain; Bunny now owns every record.

## Restore

Stop both services before replacing the database. Restore with the same pinned Litestream image and its mounted config, which supplies the replica URL, endpoint and credentials:

```sh
cd /srv/uneton
docker compose stop api litestream
docker compose run --rm --no-deps litestream \
  restore -config /etc/litestream.yml -integrity-check full -o /data/uneton.sqlite.restored /data/uneton.sqlite
```

Move the restored file over `uneton.sqlite` (keep the old file), delete `uneton.sqlite-wal`, `uneton.sqlite-shm` and `uneton.sqlite.sync-generation`, make sure the files are owned by UID 10001, then `docker compose up -d --wait`. Deleting the sync-generation sidecar is mandatory: it tells every client that a restored lineage needs a snapshot and acknowledged-command replay. Never restore a point older than the backend's seven-day `JournalRetention`. Rehearse this against the real storage zone before relying on it; the OrbStack rehearsal only covers a file replica.

## Capacity

The CX23 has 4 GB RAM and 2 GB swap. Uneton's budget (API 512 MB with `GOMEMLIMIT=400MiB`, Litestream 256 MB) is recorded in maku's tenant README beside Traceway 2 GB, OTel Collector 128 MB and Caddy 128 MB. Update both when limits change. The shared-services stack pins the server type, so upsizing is a deliberate Terraform change.
