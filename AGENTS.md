# Uneton architecture

Uneton is an iOS/watchOS family sleep tracker. The Apple client is offline-first: it writes changes optimistically to a local SQLite projection, queues commands, and reconciles them against an authoritative Go/SQLite backend over ConnectRPC.

## Repository map

- `clients/ios/Uneton/` — single-screen SwiftUI iPhone app and app-level integrations.
- `clients/ios/UnetonWatch/` — paired Watch controls for starting and ending sleep.
- `clients/ios/UnetonWidgets/` — Live Activity, Lock Screen, and Dynamic Island UI.
- `clients/ios/UnetonPackage/Sources/UnetonCore/` — local schema, projection, sync coordinator, API adapter, and prediction engine.
- `clients/ios/UnetonPackage/Sources/UnetonAPI/` — generated Protobuf and Connect Swift SDK.
- `clients/loadtest/` — Go client that simulates realistic two-caregiver flows against a running API.
- `platform/backend/` — Go ConnectRPC service, authentication, sync command processing, invitations, and authoritative SQLite database.
- `platform/backend/internal/sweetspot/` — authoritative, testable next-sleep inference over a derived (never destructive) view of diary history.
- `platform/contracts/proto/uneton/v1/uneton.proto` — canonical network contract.
- `platform/backend/internal/store/migrations/` — embedded SQLite migrations.
- `platform/backend/internal/store/queries/` — application SQL consumed by sqlc.
- `platform/backend/internal/store/storedb/` — generated sqlc code.
- `internal/gen/` — generated Go Protobuf and Connect code shared by the backend and load-test client.

## Data and sync model

The server database is authoritative. The Apple app maintains a local projection so reads and user actions remain immediate without a network connection.

Client mutations become durable, uniquely identified commands. `SyncCoordinator` sends pending commands with the client's event cursor, applies per-command results, then folds returned events into the projection. Accepted command IDs are idempotent. Updates carry an expected entity revision; a stale revision is rejected as a conflict rather than silently overwriting another caregiver's edit. The conflict UI lets the user retry or accept the server version.

The event cursor is monotonic per family. `WatchFamily` is a lightweight server stream that announces a newer cursor; it is only an invalidation signal, so clients always call `Sync` to fetch and apply authoritative events. Do not treat stream delivery as durable state.

Keep these invariants when changing sync code:

- A command ID must produce the same stored result when retried.
- Apply a command and append its event atomically.
- Compare `expected_revision` for updates and deletes.
- Advance the local cursor only after events are committed locally.
- Never discard unresolved pending commands during a pull.
- Server timestamps and revisions win after acknowledgement.

## Synchronization-first engineering

Keeping every caregiver and device convergent is the highest architectural priority. Read `docs/architecture.md` before changing mutations, persistence, app lifecycle, background work, Watch behavior, widgets, notifications, or Live Activities.

Treat every mechanism other than `Sync` as an invalidation or presentation channel:

- `WatchFamily`, silent APNs, and `BGAppRefreshTask` may trigger `Sync`; they must never transfer or apply authoritative entity state.
- Visible pushes, widgets, Watch replies, and Live Activities must never advance a cursor or become a competing diary store.
- Foreground activation must synchronize before waiting on a new stream.
- Missing a stream message or background push must only delay freshness; the durable event log and next `Sync` must recover completely.
- Pending commands are user data. Never clear, replace, or strand them during pull, pagination, sign-in refresh, background execution, or projection rebuild.
- The server generation and cursor form one position. A generation mismatch or cursor rollback must return a snapshot before evaluating new commands.
- Snapshots replace only the authoritative cache. Rebuild the projection from that cache plus pending commands, and retain accepted-command history for rollback replay.
- Compact events only behind a durable snapshot. The restore procedure must rotate the generation sidecar before the API starts.

Every new synchronized mutation must implement the complete path: durable optimistic command, idempotent server result, revision check where applicable, atomic entity/event/delivery transaction, event decoding, authoritative-record ingestion, projection replay, background invalidation, and conflict behavior. If any part is absent, the mutation is not finished.

Review synchronization changes against failure boundaries, not only the happy path. At minimum test lost responses, command retries, stale revisions, pagination, malformed cursors, concurrent caregivers, foreground reconnect, compacted-history snapshots, database restore behind an acknowledged client, and preservation of pending overlays. Update the behavioral load client whenever the Apple command sequence changes.

Update `docs/architecture.md` in the same change whenever the source of truth, command lifecycle, event model, freshness channels, or failure recovery changes. Architecture and implementation must describe the same synchronization system.

Prefer one obvious synchronization path over special-case freshness fixes. If a view is stale, repair the invalidation-to-`Sync` path; do not introduce a parallel fetch, push-payload state application, or independent cache.

Sweet-spot inference is deliberately stateless: it is recomputed from acknowledged sleep sessions and child settings, so it composes with idempotent commands and reconnect pagination without its own conflict domain. Keep modelling heuristics inside `platform/backend/internal/sweetspot`; do not silently rewrite raw sleep records to make them fit the model. See `docs/sweetspot.md` for evidence, fields, and evaluation.

## API and persistence conventions

Use Protobuf messages for the wire contract and generated Connect clients/handlers for transport. Do not add parallel handwritten JSON endpoints or edit generated files directly.

Put static backend SQL in `platform/backend/internal/store/queries/` and access it through generated sqlc methods. Handwritten SQL is reserved for migrations, SQLite pragmas, and genuinely dynamic transaction/savepoint statements.

This project is pre-production and has no schema compatibility promise yet. When the authoritative schema changes, rewrite `001_initial.sql` into the desired clean baseline instead of adding incremental migrations, then delete and recreate local/test databases. Do not preserve obsolete tables, columns, data backfills, or compatibility shims. Start versioned forward migrations only after the project explicitly enters production.

After changing the `.proto` contract or SQL queries, run `mise run generate` and commit the generated Go and Swift output. Ordinary app/backend builds must not require generator tools.

## Local workflow

- `mise install` — install all pinned development tools.
- `mise run dev` — run the backend at `127.0.0.1:8080` with local development sign-in.
- `mise run test` — run backend, load-test client, and shared Swift tests.
- `mise run generate` — run sqlc generation/vetting and Buf lint/generation.
- `mise run project` — regenerate the iOS Xcode project after changing `clients/ios/project.yml`.
- `mise run loadtest -- -families 10 -cycles 3 -concurrency 4` — run behavioral load against the development API.
- `mise run docker:up` — run the production-shaped backend locally.

The debug client uses `http://localhost:8080`; local server data is stored at `platform/backend/var/uneton.sqlite`. Prefer tests around `SyncCoordinator`, projection behavior, command idempotency, stale revisions, pagination, and retry paths whenever sync behavior changes. Keep the load-test scenarios behaviorally aligned with the Apple client's command sequence.

## Platform boundaries

`UnetonCore` should contain testable domain and persistence logic. Keep SwiftUI and Apple-framework orchestration in the app, Watch, or widget targets. Shared Live Activity attributes belong in `UnetonActivity`. The prediction engine is an estimate, not medical advice; retain manual reminder intervals and cautious user-facing language.
