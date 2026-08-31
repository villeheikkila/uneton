# Uneton system architecture

This is the canonical overview of how Uneton keeps a shared family diary correct and fresh across iPhone, Apple Watch, widgets, background execution, and the backend. Detailed implementation policies are linked at the end.

## Architectural priority

Synchronization correctness is a product requirement, not an implementation detail. A caregiver must be able to act immediately while offline, retry safely after an ambiguous network failure, and converge on the same family history as every other caregiver without silent data loss.

The design follows one rule:

> The backend SQLite database is authoritative. Apple clients hold durable offline projections. Commands and events reconcile those projections; streams and push notifications only tell a client when to reconcile.

No foreground stream, push payload, Live Activity, widget, Watch message, or prediction result is durable family state. Losing any freshness signal may make a screen temporarily stale, but the next successful `Sync` must restore the same correct state.

## System map

```text
 Apple device                                                   Platform

 ┌──────────────────────────────────────┐        ConnectRPC      ┌──────────────────────────────┐
 │ SwiftUI app                          │◄──────────────────────►│ Go application               │
 │                                      │                        │                              │
 │  visible SQLite projection           │   Sync commands/events │  command processor           │
 │          ▲                           │                        │          │                   │
 │          │ Projection.rebuild        │   WatchFamily hint      │          ▼                   │
 │          │                           │◄───────────────────────│  authoritative SQLite       │
 │  authoritative-record cache          │                        │  ├─ entities + revisions      │
 │          +                           │                        │  ├─ idempotent command results│
 │  unresolved pending commands         │                        │  ├─ monotonic event log       │
 │                                      │                        │  └─ durable delivery outbox   │
 │  SessionStore lifecycle orchestration│                        │          │                   │
 └──────────┬───────────────┬───────────┘                        └──────────┼───────────────────┘
            │               │                                               │
     WatchConnectivity  ActivityKit                                APNs alerts, silent
            │               │                                      invalidations, and
      ┌─────▼─────┐   ┌─────▼──────────┐                           Live Activity pushes
      │ Watch app │   │ widget / Live  │◄───────────────────────────────────┘
      │ controls  │   │ Activity UI    │
      └───────────┘   └────────────────┘
```

The production deployment runs one API writer behind Caddy with a durable SQLite volume and Litestream replication. The single-writer topology is intentional; the correctness model does not depend on in-memory stream delivery.

## Ownership and boundaries

| Area | Responsibility |
| --- | --- |
| `clients/ios/Uneton` | SwiftUI presentation and Apple-framework lifecycle orchestration |
| `clients/ios/UnetonPackage/Sources/UnetonCore` | local schema, projection, durable commands, API adapter, and `SyncCoordinator` |
| `clients/ios/UnetonWatch` | reachable phone controls; it does not own authoritative diary state |
| `clients/ios/UnetonWidgets` and `UnetonActivity` | presentation of locally supplied or ActivityKit state |
| `platform/contracts` | canonical Protobuf wire contract |
| `platform/backend/internal/app` | authentication, authorization, command processing, sync, streams, APNs, and account lifecycle |
| `platform/backend/internal/store` | authoritative schema and sqlc queries |
| `platform/backend/internal/sweetspot` | stateless inference over acknowledged history |
| `platform/infra` | Caddy, containers, Litestream, VPS provisioning, and VM rehearsal |

Dependencies point inward. UI and Apple frameworks may call `UnetonCore`; domain persistence must not depend on SwiftUI. Backend handlers use generated Connect transport and sqlc persistence rather than parallel handwritten APIs.

## The two client layers

The local database deliberately separates server knowledge from what the user sees:

1. `AuthoritativeRecord` stores the latest acknowledged server representation of each entity.
2. `PendingCommand` stores unresolved local intent in creation order.
3. `AcknowledgedCommand` retains the complete accepted command journal. It is not part of the visible projection; it exists solely to repair a server restored behind an acknowledged client.
4. `Projection.rebuild` materializes the visible `Child` and `SleepSession` diary tables, scoped by the locally stored family membership, by replaying pending intent over the authoritative base.
5. `SyncState` stores the committed family event cursor, server generation, and last synchronization time.
6. `SyncConflict` stores a rejected intent that needs an explicit user decision.

The visible child and sleep-session projection is disposable and derived. Family membership, authentication state, pending commands, and the acknowledged journal have separate lifecycles; commands are user data and are never disposable before their recovery-retention policy permits it. A pull must never replace the database wholesale or discard unresolved commands.

## Mutation path: local intent to authoritative state

### 1. Accept intent locally

An iPhone action creates stable entity and command UUIDs, inserts a `PendingCommand`, and rebuilds the projection in one local SQLite transaction. The UI updates immediately. Network availability is irrelevant to accepting the action.

The Watch app sends start/end intent to the paired phone through WatchConnectivity. The phone creates the same durable command used by its own UI; Watch state is not an independent diary database.

### 2. Send a bounded sync request

`SyncCoordinator` serializes synchronization per family. A request contains:

- the last locally committed event cursor;
- the durable server generation associated with that cursor;
- up to 100 oldest pending commands;
- a page limit for returned events;
- authentication whose principal identifies both user and device.

The coordinator may need several pages and command passes. Pagination after the first response sends no duplicate command batch, while a later pass can drain commands created, rebased, or restored from the acknowledged journal during reconciliation.

### 3. Apply each command atomically on the server

The backend authorizes family membership, opens one SQLite transaction, and isolates each command with a savepoint. For a command not seen before it:

1. validates payload and domain rules;
2. checks `expected_revision` for an update or delete;
3. mutates the authoritative entity;
4. appends the corresponding family event;
5. queues any required background/APNs delivery;
6. records the command result under `(family_id, command_id)`.

The entity change, event, delivery intent, and stored command result commit together. Retrying the same command ID returns the stored result without applying the mutation or enqueueing delivery again. An ambiguous client timeout is therefore safe to retry.

A rejected command is also returned deterministically. Its savepoint rolls back partial entity, event, and delivery work without preventing later commands in the batch from progressing.

### 4. Reconcile locally in one transaction

Before writing anything, the client validates response structure: cursors cannot move backwards, event cursors must be ordered and bounded, pagination must make progress, and command-result IDs must match the sent batch.

It then performs one local SQLite transaction:

1. ingest canonical command-result payloads into `AuthoritativeRecord`;
2. remove accepted pending commands;
3. rebase a supported stale command once, accept the server version, or create `SyncConflict`;
4. fold newer events into `AuthoritativeRecord` by revision;
5. advance `SyncState.cursor` only after those writes succeed;
6. rebuild the visible projection from authoritative records plus remaining commands.

Server timestamps, canonical entity IDs, and revisions win after acknowledgement. If this local transaction fails, the old cursor and pending commands remain available for a safe retry.

### Snapshots, compaction, and restore recovery

The event log is an incremental transport optimization, not the only representation of family state. The server can return a complete `FamilySnapshot` at a cursor, containing every current child and sleep-session entity. A new device receives a snapshot instead of replaying years of diary events. Once a family crosses the configured event threshold, the server stores a snapshot in the same transaction and deletes events through its cursor; a device behind that point receives the snapshot plus any later events.

Every database lineage also has a durable `generation` sidecar. A restored database receives a new generation before it is reopened. If a client sees a generation mismatch—or defensively finds its cursor ahead of the server—it receives a reset snapshot before the server evaluates new commands. The client atomically replaces its authoritative cache, restores its accepted-command journal into the pending outbox, and replays it in original order. Commands already present in the restored database return their stored result; commands lost after the backup point apply once. This closes the otherwise irrecoverable gap between an acknowledged client and a restored older database.

## Conflict model

Updates and deletes carry the revision the user edited. A mismatched revision is a conflict, never an implicit last-write-wins update.

Some conflicts have a bounded automatic resolution, such as one rebase against the returned server revision. Automation runs at most once. Anything ambiguous becomes a durable `SyncConflict`; the user can keep the local intent as a new command or accept the server version.

Duplicate active-sleep starts are a domain exception handled idempotently: the server maps the new attempt to the existing canonical session rather than creating overlapping active sessions.

## Freshness and app lifecycle

All freshness paths converge on `Sync`:

| Mechanism | When | Guarantee | Action |
| --- | --- | --- | --- |
| direct sync | launch, foreground entry, local action, pull to refresh | authoritative when successful | send commands and fetch events |
| `WatchFamily` Connect stream | while the scene is active | transient invalidation only, including generation/cursor rollback | close hint wait and call `Sync` |
| silent APNs push | another device commits a family mutation | best effort; iOS may delay or drop it | sync the named family during the wake window |
| `BGAppRefreshTask` | scheduled by iOS | discretionary | sync all locally known families |
| visible APNs alert | enabled device, sleep start/end | user communication only | never apply its payload as state |
| Live Activity push | enabled device, active sleep lifecycle | presentation only | update ActivityKit; normal sync remains authoritative |

### Foreground loop

While the SwiftUI scene is active, the timeline runs:

```text
Sync until caught up → read committed cursor → open WatchFamily(cursor)
        ▲                                      │
        └──── hint, heartbeat expiry, auth expiry, transport failure ────┘
```

Reconnects use bounded exponential backoff. The stream closes when the scene backgrounds and is recreated only after a foreground sync. Heartbeats and finite stream lifetimes detect dead connections and refresh expiring access tokens; they do not carry durable events.

### Background convergence

Every newly accepted family mutation queues a silent invalidation for other registered devices in the same server transaction as its event. Sleep transitions additionally queue visible alerts and Live Activity work. A durable worker claims outbox rows, retries transient APNs failures with bounded backoff, and clears tokens APNs declares invalid.

Silent pushes contain only `content-available` and a family ID. The app uses its short background execution window to call `Sync`; it does not trust or materialize state from the push. `BGAppRefreshTask` is a fallback, not a schedule guarantee. If the user force-quits the app or iOS throttles background work, foreground entry still converges before reopening the stream.

## Devices, notifications, and Live Activities

A device is an authenticated session owned by a user. One user can have several devices, each with its own:

- ordinary APNs token and development/production environment;
- ActivityKit push-to-start token;
- visible-notification preference;
- Live Activity preference;
- reminder lead time.

The initiating phone starts its Live Activity locally. Other enabled caregiver devices receive push-to-start messages. Each activity uploads its rotating activity push token so the backend can end it later. Per-session/per-device start claims make retries idempotent. A device joining while sleep is already active is reconciled from authoritative active sessions.

Disabling visible alerts does not disable silent sync invalidations. Disabling Live Activities ends local activities and prevents future remote starts for that device. Signing out deletes that device row and its tokens only after the phone has synchronized every family and has no pending commands or unresolved conflicts.

## Authentication and account lifecycle

Sign in with Apple is verified by the backend through code exchange and nonce-bound identity-token validation. Access tokens name both user and device; handlers derive device identity from the authenticated principal rather than trusting a body field.

Apple refresh tokens are encrypted server credentials. User-requested deletion and verified Apple `consent-revoked` or `account-deleted` notifications call the same idempotent local-erasure transaction. Provider revocation is best effort and never blocks deleting local identity, devices, memberships, or owned data according to the transfer policy.

Removing a device or account cascades its notification and Live Activity tokens. Provider notifications and credential audits are recovery paths, not separate account state machines.

## Prediction and derived UI

Sweet-spot inference is stateless and recomputed only by the backend from acknowledged server history and child settings. It never rewrites diary records and has no independent synchronization domain. The client does not implement an offline prediction model: it displays a forecast only when received from `Sync`, while its diary projection and pending commands remain fully usable offline. Predictions are estimates, not medical advice.

Widgets and Live Activities display derived state. They must not originate authoritative mutations or advance sync cursors.

## Failure and recovery expectations

| Failure | Required behavior |
| --- | --- |
| offline local action | retain command durably and show optimistic projection |
| response lost after server commit | retry command ID and receive stored result |
| process dies during local apply | retain old cursor; retry whole response path safely |
| stale revision | reject, return server entity, then bounded rebase or user conflict |
| missed stream message | next heartbeat/reconnect/foreground sync reads event log |
| dropped or throttled silent push | scheduled or foreground sync catches up |
| APNs transient failure | durable outbox retries without replaying domain command |
| invalid APNs token | clear only the matching token; other devices continue |
| access token expires during stream | refresh credentials, sync, reopen stream |
| backend restart | SQLite state and outbox survive; in-memory stream subscribers reconnect |
| compacted event history | return the saved family snapshot and events after its cursor |
| database restored behind a client | rotate generation, return reset snapshot, then replay the retained acknowledged-command journal and pending commands |
| VPS loss | restore authoritative SQLite through Litestream, rotate the generation sidecar, then clients run reset recovery |

## Rules for extending synchronized state

A new synchronized entity or mutation is incomplete unless the change covers the whole path:

1. Protobuf command, result entity, and event representation.
2. Authoritative schema/query and revision rules.
3. Atomic command mutation, event append, idempotent stored result, and background invalidation.
4. Snapshot encoding, local authoritative-record replacement, and projection rebuild.
5. Durable pending and acknowledged-command encoding, optimistic replay, and restore replay.
6. Conflict behavior for stale revisions.
7. Pagination, retry, malformed-response, compacted-history, restore, and two-caregiver tests.
8. Behavioral load-test coverage when the Apple client command sequence changes.

Never add a second state-transfer channel to make a screen appear fresher. Improve invalidation and call `Sync`.

## Verification strategy

The highest-value tests exercise invariants rather than transport syntax:

- command replay after a lost response;
- command/event/delivery atomicity;
- two caregivers editing the same revision;
- pagination with pending commands retained;
- malformed cursor responses leaving local durability untouched;
- stream reconnects after server restart and token expiry;
- silent-push payload shape and transactional invalidation enqueueing;
- rotating and invalid APNs/ActivityKit tokens;
- projection rebuild with authoritative changes beneath optimistic overlays;
- compacted-history snapshot replacement;
- restore rehearsal with generation rotation and acknowledged-command replay.

`clients/loadtest` must remain behaviorally aligned with the real two-caregiver command sequence. Capacity results are meaningful only after the correctness scenario passes.

## Detailed references

- [Offline sync invariants](patterns/sync.md)
- [Push notifications and Live Activities](patterns/push-notifications.md)
- [Connect handler policy](patterns/connect-handlers.md)
- [Sign in with Apple](patterns/sign-in-with-apple.md)
- [Account erasure](patterns/account-erasure.md)
- [Sweet-spot inference](sweetspot.md)
- [Operations, restore, and constrained VM testing](operations.md)
- [ADR 0001: one module with explicit boundaries](decisions/0001-one-module-explicit-boundaries.md)
