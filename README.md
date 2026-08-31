# Uneton

Uneton is a focused iPhone and Apple Watch sleep tracker for families. The phone app keeps an offline SQLite projection, applies changes optimistically, and reconciles them with a small Go/SQLite server. The server is authoritative and publishes invalidations through a ConnectRPC server stream.

## Fast local loop

Requirements: Xcode 26+ and [mise](https://mise.jdx.dev). Run `mise install` once to install the pinned Go, Buf, sqlc, Protobuf, Connect, and XcodeGen tools.

1. Run `mise run dev`.
2. Open `clients/ios/UnetonWorkspace.xcworkspace`.
3. Run the **Uneton** scheme on an iPhone simulator.
4. Use **Local development sign-in** on the onboarding screen.

The debug app connects to `http://localhost:8080`. Data lives in `platform/backend/var/uneton.sqlite`; deleting that single development file resets the server. Local development sign-in creates its own isolated family on first use.

Run all deterministic tests with `mise run test`. After editing SQL or `platform/contracts/proto/uneton/v1/uneton.proto`, run `mise run generate`; generated Go and Swift sources are checked in so ordinary builds need no generator tools. Regenerate the checked-in Xcode project with `mise run project`. A production-shaped local stack is available through `mise run docker:up`; the complete VM rehearsal is `mise run infra:orb:rehearse`.

## CI and release rehearsal

GitHub Actions and local CI share the canonical Linux gate: `mise run ci:server:check`. It tests the backend and behavioral load client, regenerates and checks generated sources, validates the Ansible playbook syntax, and lints the workflows and CI scripts. Run the Linux GitHub job itself with `mise run ci:workflow:check`; this uses `act` and the checked-in workflow rather than a look-alike shell command. The Swift package remains a native macOS GitHub job and is covered locally by `mise run ios:test`.

Run `mise run ci:workflow:release` from a clean checkout before a release candidate. It invokes the manual release-rehearsal workflow through `act`, builds a commit-addressed Linux/ARM64 backend image into the local Docker engine, deploys that exact image to the disposable OrbStack VM, verifies it, and rehearses a Litestream restore. It never publishes an image or contacts a production server.

Backtest the server sweet-spot model against an explicitly supplied, local CSV export without future-data leakage:

```sh
go run ./platform/backend/cmd/evaluate-sweetspot -csv /path/to/sleep-history.csv -timezone Europe/Helsinki -birth-date YYYY-MM-DD
```

The model design, evidence, and limitations are documented in [`docs/sweetspot.md`](docs/sweetspot.md).

To exercise realistic shared-family traffic, keep the development server running and use `mise run loadtest -- -families 10 -cycles 3 -concurrency 4`. The load client simulates two caregivers syncing, retrying durable commands, and ending sleep across devices; see `clients/loadtest/README.md` for details.

## Production configuration

Copy `platform/backend/.env.example` to the VPS secret store, use a random token secret, provide the Sign in with Apple values, mount the SQLite volume on durable storage, and terminate TLS with the included Caddy configuration. Back up the SQLite database with Litestream or a volume snapshot; WAL mode and a busy timeout are configured automatically.

Production startup fails unless Sign in with Apple, its HTTPS server-notification URL, and the refresh-token encryption keyring are complete. `UNETON_AUTH_APPLE_CLIENT_ID` is the native app bundle identifier; the team, key ID, and `.p8` values come from the Apple Developer account. Preserve literal `\n` escapes when the private key is stored on one line. The backend validates nonce-bound exchanged identity tokens, rotates encrypted refresh-token keys at startup, audits Apple credentials daily, and treats revocation as best effort before immediate local erasure.

Push notifications and remote Live Activities use APNs provider credentials. The backend reuses the Apple integration key when no `UNETON_INTEGRATION_APNS_*` values are set; configure the four APNs variables in `platform/backend/.env.example` when using a dedicated APNs-enabled key. Device-scoped behavior and token lifecycles are documented in `docs/patterns/push-notifications.md`.

The main iOS target declares the Sign in with Apple entitlement. Enable Sign in with Apple for `solutions.bytesized.uneton` in the Apple Developer portal so automatic signing can create a matching provisioning profile. The Xcode targets also need the App Group, Push Notifications, and Live Activities capabilities provisioned for the bundle identifiers in `clients/ios/project.yml`.

This project is still pre-production. Because the clean baseline migration changes when the account schema changes, delete and recreate existing development or test SQLite databases after pulling this revision rather than carrying an old `001_initial.sql` schema forward.

## Historical CSV imports

The importer accepts compatible sleep-history CSV exports, ignores every activity type except `Sleep`, converts offset-free timestamps using an explicit IANA timezone, and writes sleep rows plus sync events in one transaction. Overlapping and near-duplicate records are merged like ordinary Uneton sleep commands, and session identifiers are deterministic, so importing the same export again does not duplicate data.

For an existing production family, child, and caregiver:

```sh
go run ./platform/backend/cmd/import-history \
  -csv /path/to/sleep-history.csv \
  -database /path/to/uneton.sqlite \
  -timezone Europe/Helsinki \
  -family-id FAMILY_UUID \
  -child-id CHILD_UUID \
  -author-id CAREGIVER_UUID
```

Run imports against a backup or maintenance copy of the authoritative database. The family, child, and author must already exist, and the author must be an active member of that family.

## Architecture

The canonical end-to-end design—including offline commands, authoritative events, foreground streaming, background invalidations, APNs and Live Activities, authentication, failure recovery, and rules for adding synchronized state—is documented in [`docs/architecture.md`](docs/architecture.md).

- `clients/ios/`: the SwiftUI iPhone app, Watch app, widgets, local Swift package, workspace, and XcodeGen spec.
- `clients/loadtest/`: a Go behavioral load generator using the same generated Connect client as production code.
- `platform/backend/`: ConnectRPC application, `sqlc` queries, embedded migrations, and authoritative SQLite store.
- `platform/contracts/`: canonical protobuf contract and reproducible Go/Swift generation.
- `platform/infra/`: production runtime, Ansible provisioning, Litestream backup, and OrbStack rehearsal.
- `tooling/local-dev/`: local production-shaped Compose environment.
- `internal/gen/`: shared generated Go Protobuf messages and Connect client/server bindings.

The RPC schema is the API contract. Buf generates the shared Go messages and Connect bindings into `internal/gen`, plus the Swift SDK into `clients/ios/UnetonPackage/Sources/UnetonAPI`. Static application SQL lives in `platform/backend/internal/store/queries` and `sqlc` generates its backend access layer. Only migrations, SQLite pragmas, and dynamic command savepoints remain handwritten.

The prediction is deliberately described as an estimate rather than medical advice. It uses an age-banded wake-window prior, then adapts toward the child's recent intervals when enough clean observations exist. Manual reminder intervals remain available.
