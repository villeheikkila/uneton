# Operations and rehearsal

For deployment within an existing shared Compose project, see [the shared VPS guide](shared-vps.md). The Compose stack below remains the standalone local rehearsal topology; the shared host uses its existing Compose project and Caddy.

The production runtime is Compose with one Uneton API writer, Caddy ingress, a durable SQLite volume, and Litestream replication. Runtime secrets live outside Git in machine-specific `platform/infra/vps/.orb/runtime.<machine>.env` files for rehearsal and in the production secret store on the VPS.

Run `mise run infra:orb:rehearse` to create an Ubuntu OrbStack VM, build and load the checkout's backend image, provision Docker with Ansible, start the exact production-shaped runtime, probe readiness, and verify that Litestream has written a replica and the guest has the requested cgroup CPU and memory quotas. Use `mise run infra:orb:restore-test` only against that disposable VM; it stops the writer, preserves the current database as a timestamped `uneton.sqlite.before-restore.*` file, restores from Litestream, rotates the adjacent `uneton.sqlite.sync-generation` sidecar, restarts services, and probes readiness. A failed restore returns the preserved database and restarts the services. Rotating this sidecar is mandatory: it tells every client that a restored lineage requires a snapshot and acknowledged-command replay.

`mise run ci:workflow:release` is the stronger release rehearsal. It requires a clean checkout, then runs the actual manual GitHub Actions workflow locally through `act`, producing a commit-addressed ARM64 Docker image. It then makes OrbStack load and deploy that exact image (`infra:orb:rollout`), verifies readiness and backup replication, and performs the disposable restore rehearsal. This path has no registry push or production deployment capability. The ordinary `infra:orb:rehearse` task intentionally remains convenient for development and builds `uneton-backend:orb` from the checkout.

## Local publishing

Run the relevant checks and rehearsal on the Mac before publishing. The publication tasks require a clean checkout so the commit SHA identifies the source. They do not depend on a remote CI job.

For GHCR, authenticate Docker locally with a token allowed to write packages, then build the ARM64 image and inspect it before pushing a multi-architecture AMD64/ARM64 manifest:

```sh
mise run release:ghcr
mise run release:ghcr -- --publish
```

The image is `ghcr.io/villeheikkila/uneton-backend:<full commit SHA>`. The publish command prints the registry manifest and digest. Use the digest for a later server rollout; publishing alone does not deploy it.

The backend Dockerfile pins its Go builder and distroless static runtime by digest. Refresh those digests deliberately during local release maintenance, rebuild with `docker build --pull -f platform/backend/Dockerfile -t uneton-backend:check .`, and run the binary's `healthcheck` command against a started container before publishing. `.dockerignore` sends only Go module files, generated RPC code, and backend sources to the builder; private journals, local databases, and age-encrypted configuration stay outside the build context. The runtime contains the Go binary and distroless CA/timezone data, has no shell, runs as UID/GID 10001, and Compose mounts only `/data` and a small `/tmp` as writable paths.

For App Store Connect, configure local Xcode distribution signing for the iPhone, Watch, and widget targets, and configure `asc` authentication (`asc auth login` or `ASC_*` credentials). The Xcode project derives all three targets' bundle versions from `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`; the local build command overrides both for one archive without editing tracked files. Choose a build number that has not been uploaded for that app version:

```sh
mise run release:ios:build -- 1.0 2
export ASC_APP_ID=1234567890 # replace with the numeric App Store Connect app ID
ipa=".asc/artifacts/Uneton-1.0-2-$(git rev-parse HEAD).ipa"
mise run release:ios:upload -- "$ipa"
mise run release:ios:upload -- "$ipa" --publish
```

The first upload command previews the `asc publish appstore` plan. The second uploads the same IPA, waits for processing, creates or finds the App Store version, and attaches the build. It does not submit the version for App Review. Run `asc validate --app "$ASC_APP_ID" --version 1.0 --platform IOS` before a separate review submission. The signed IPA and archive are kept locally under ignored `.asc/artifacts/`.

Production changes should follow the same sequence: validate typed config with `uneton config`, verify the database with `uneton database-check`, deploy, wait for readiness, and confirm backup freshness. Never copy a live WAL database without SQLite/Litestream coordination.

## Constrained VM capacity test

Run `mise run loadtest:vm` for a one-command production-shaped capacity rehearsal. It creates a separate `uneton-loadtest-orb` Ubuntu VM with 2 vCPUs, 4 GB RAM, and 40 GB disk, deploys the API/Caddy/Litestream stack, verifies readiness and backup, then drives a stepped behavioral ConnectRPC workload from the macOS host. Keeping the generator outside the VM prevents it from consuming the resources under test. Repeat without rebuilding with `mise run loadtest:vm:run`.

The load-test VM explicitly sets the application environment to development so its virtual caregivers can use `DevelopmentAuth`; never expose this instance publicly or reuse its environment in production. The deployed binary, ingress, persistence, backup sidecar, and container topology remain the production definitions. The harness reaches Caddy through an SSH tunnel bound to loopback (port 18080 by default) and requires a complete one-family scenario to pass before starting the measured ramp. Override the local port with `UNETON_LOADTEST_TUNNEL_PORT` if it is occupied.

The default profile matches the resource envelope of Hetzner's current entry-level [CX23 and CAX11 plans](https://www.hetzner.com/cloud/): 2 vCPUs, 4 GB RAM, and 40 GB storage. It uses native ARM on Apple Silicon, so it is closest architecturally to CAX11. This is deliberately an envelope test, not a claim of hardware equivalence: Hetzner's [shared-resource plans](https://docs.hetzner.com/cloud/servers/faq/#what-are-the-shared-resource-server-plans) can burst and experience neighbor contention, while local CPU generation, storage, and networking differ.

Defaults ramp concurrency through `1,2,4,8,16,32,64`, run four two-caregiver scenarios per worker, and stop when a stage fails or aggregate RPC p95 exceeds 500 ms. Override these through `UNETON_LOADTEST_RAMP`, `UNETON_LOADTEST_SCENARIOS_PER_WORKER`, `UNETON_LOADTEST_CYCLES`, `UNETON_LOADTEST_STAGE_TIMEOUT`, and `UNETON_LOADTEST_MAX_P95`, or append ordinary load-client flags after `--`. The result reports the last passing concurrency and writes the console result and container telemetry to `platform/infra/vps/.orb/loadtest-*.log` and `.tsv`.

The database intentionally accumulates unique test families between runs. Delete and recreate only the disposable `uneton-loadtest-orb` machine when a clean-database comparison is required. Report the tested commit, host model, threshold, last passing stage, RPC/s, p95, and telemetry alongside any capacity conclusion.
