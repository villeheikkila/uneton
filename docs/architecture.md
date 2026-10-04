# Uneton system architecture

## Backend-free UI demo (debug builds)

`UNETON_DEMO_MODE=1` selects a separate TCA26 composition root at launch. It boots the same SQLite schema in memory and injects `DemoRuntime` implementations of the authentication, family, family management, diary, sharing, and sync feature environments. Those adapters update only the ephemeral projection for interactive UI development. They create no pending commands, authoritative records, or cursor, and they do not attempt network, Apple credentials, Watch, push, or Live Activity work. The demo is a presentation sandbox; the production composition root continues to inject `SessionStore` adapters and uses `SyncCoordinator` as described below.

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
 │  TCA root + SessionStore runtime      │                        │          │                   │
 └──────────┬───────────────┬───────────┘                        └──────────┼───────────────────┘
            │               │                                               │
     WatchConnectivity  ActivityKit                                APNs alerts, silent
            │               │                                      invalidations, and
      ┌─────▼─────┐   ┌─────▼──────────┐                           Live Activity pushes
      │ Watch app │   │ widget / Live  │◄───────────────────────────────────┘
      │ controls  │   │ Activity UI    │
      └───────────┘   └────────────────┘
```

The production deployment runs one API writer behind Caddy with a durable SQLite volume and Litestream replication. The single-writer topology is intentional; the correctness model does not depend on in-memory stream delivery. The iPhone app's TCA26 root owns active-family and active-child selection and the foreground observation task. `SessionStore` remains the Apple-framework runtime adapter, and `SyncCoordinator` remains the only client path that applies authoritative events or changes the local cursor.

## Ownership and boundaries

| Area | Responsibility |
| --- | --- |
| `clients/ios/Uneton` | SwiftUI presentation and Apple-framework lifecycle orchestration |
| `clients/ios/UnetonPackage/Sources/UnetonCore` | local schema, projection, durable commands, API adapter, and `SyncCoordinator` |
| `clients/ios/UnetonWatch` | paired phone controls and transient child/diary presentation; it does not own authoritative diary state |
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
2. `PendingCommand` stores unresolved local intent in a durable sequence allocated in the same transaction as insertion.
3. `AcknowledgedCommand` retains accepted commands for the restorable window. It is not part of the visible projection; it exists solely to repair a server restored behind an acknowledged client. Each entry records the server time of its acknowledgement. Every non-reset `Sync` response carries `journal_retention_cutoff`, the server time minus `JournalRetention` (default seven days), and the client deletes entries acknowledged before it in the same transaction. A reset response carries no cutoff, because its journal is about to be replayed.
4. `Projection.rebuild` and `Projection.refresh` materialize the visible `Child`, `SleepSession`, `GrowthMeasurement`, and `TemperatureReading` diary tables, scoped by the locally stored family membership, by replaying pending intent over the authoritative base.
5. `SyncState` stores the committed family event cursor, server generation, and last synchronization time.
6. `SyncConflict` stores a rejected intent that needs an explicit user decision.

The visible child, sleep-session, growth-measurement, and temperature-reading projection is disposable and derived. Family membership, authentication state, pending commands, and the acknowledged journal have separate lifecycles; commands are user data and are never disposable before their recovery-retention policy permits it. A pull must never replace the database wholesale or discard unresolved commands.

### iPhone feature ownership

The app uses TCA26 for presentation and lifecycle orchestration. `AppRoot` owns authentication visibility, onboarding, family setup, active-family and active-child selection, and the selected family's `FamilySync` feature. `FamilyManagement` owns caregiver, invitation, profile, family, and baby settings forms. Its data is fetched from the authenticated management API; diary edits still enter the durable `SyncCoordinator` command path. `FamilySync` observes that family only while the scene is active; its task is cancelled when the app backgrounds, the selected family changes, or authentication ends. Manual refresh, sleep and growth entry, waking, conflict resolution, and baby settings enter the existing `SessionStore`/`SyncCoordinator` path through feature environment adapters. Caregiver membership, invitations, profile names, and family names use authenticated control-plane methods through their own feature environment adapter. Feature tests can control these effects without a server.

SQLiteData remains the durable read source. TCA feature state holds selection, presentation, loading, and form workflow state, not a second copy of authoritative diary records or a second command queue. The `SessionStore` runtime still handles Apple frameworks, the Watch bridge, background push registration, and existing sync effects. Moving further actions into features must preserve optimistic command insertion and the complete `SyncCoordinator` reconciliation path described below.

SwiftUI `Screen` and `Sheet` views own navigation, toolbars, presentation, and scene lifecycle. Their `Content` views read from TCA26 feature stores. Feature state owns SQLiteData readers with `@ObservationIgnored @FetchAll` or `@FetchOne`; readers for the active family or baby filter in SQLite. Selecting a different family or baby creates new scoped feature state, so data from the previous selection cannot appear under the new title. A `ForEach` row has one root view, with a stack inside it when the row needs several elements. The feature does not keep a second copy of the diary.

`FamilySync` also owns the selected tab and insights range. Sleep and growth charts derive their summaries from the current SQLite projection with pure `UnetonCore` calculations; they do not persist a separate chart cache. Feature effects read injected time, and preview fixtures compose a demo `SessionStore` with fake feature clients so rendering cannot start production observers or credential work.

## Family invitation links

The iPhone shares invitations as `https://api.uneton.app/invite/<token>` in both the share sheet and QR code. The Go backend serves a generic English/Finnish landing page and `/.well-known/apple-app-site-association`, scoped to `/invite/*` for `J9S7QG9SVR.solutions.bytesized.uneton`. The iPhone declares `applinks:api.uneton.app` and routes browsing activities, opened URLs, and scanned QR codes through the same `FamilyInvitationLink` validator. Legacy `uneton://invite/<token>` links remain supported and power the landing page's explicit app-open button.

The public page never looks up an invitation or exposes family records, and a browser or message preview never claims membership. It sends no-store, no-referrer, noindex, and a restrictive content security policy, loads no external resources, and redacts invitation paths from backend panic logs. Only the existing authenticated `AcceptInvite` RPC checks expiry, revocation, and single-use claims. A signed-out client holds the link in memory until sign-in, then uses that same acceptance flow and `Sync` to ingest the shared diary. Membership links do not transfer authoritative diary state or advance the cursor.

Deployment must serve the association file directly over HTTPS on `api.uneton.app` and enable Associated Domains for the iOS app's signing profile. Keep its app identifier aligned with the team and bundle identifier in `clients/ios/project.yml`. Verify a signed build on a physical iPhone by opening a shared link from Messages, including when signed out; verify the browser fallback without the app. There is no deferred-install token recovery: after installation the recipient reopens the original link.

## Mutation path: local intent to authoritative state

### 1. Accept intent locally

An iPhone action creates stable entity and command UUIDs, inserts a `PendingCommand`, and rebuilds the projection in one local SQLite transaction. The UI updates immediately. Network availability is irrelevant to accepting the action.

Projection replay, command batching, and acknowledged-journal restore all use the same local sequence. Timestamps and random UUIDs do not determine ordering, so equal timestamps or a clock rollback cannot reorder a start and its wake-up. The acknowledged journal retains each command’s sequence. Sequential offline edits reserve the expected revision produced by the preceding queued mutation for that entity. The reservation is read inside the enqueue transaction, so concurrent edits cannot reserve the same revision.

The Watch app sends selected-child sleep and temperature intent to the paired phone through a typed `UnetonCore` Watch diary contract. The phone validates family and child identity, creates the same durable command used by its own UI, and returns the local projection. Watch replies and application-context updates are presentation snapshots only: they contain no event cursor and never apply authoritative entity state. The phone assigns a persistent, increasing version to each presentation snapshot; the Watch ignores older snapshots so a delayed reply cannot replace newer displayed state. The Watch persists its single outstanding request before sending, restores it after restart, and retries when the phone becomes reachable. Start-sleep requests carry a stable session ID that also identifies their durable command, so the phone recognizes retries through its pending and acknowledged command journals even if the visible session was later removed. Wake requests name the exact displayed session and cannot end a later one. The phone checks repeated temperature intent against its projection so an ambiguous reply does not create a duplicate reading. The Watch has no independent diary database or general command queue, so the paired iPhone must be reachable to accept an action. When the iPhone is offline from the backend, it still accepts the command durably and retries `Sync` later.

### Growth measurements

The digital neuvola card stores dated caregiver-recorded weight in grams and height in millimetres as `GrowthMeasurement` entities. Each measurement must contain at least one value and is an ordinary optimistic, revision-checked upsert/delete command with its own event and conflict behavior. The child’s optional `growthReference` selection (`none`, `girl`, or `boy`) follows that same revision-checked child update path so every caregiver sees the same selected chart. The app presents kilograms and centimetres, but stores integer base units to avoid rounding ambiguity. Measurements and reference curves are visual observations only: Uneton does not infer percentiles, diagnoses, or medical advice from them.

Digitized reference points are private local development material. They are read from ignored `tmp/growth-reference.json` and imported with `mise run backend:growth-reference:seed` into `growth_reference_points`. The authoritative server includes this static bootstrap payload in `SyncResponse`; the app replaces its local reference cache transactionally before advancing the family cursor. Reference points are not family data, commands, or events, and the cache remains available when the app is offline.

### Huckleberry import

Baby settings accepts a UTF-8 Huckleberry CSV with `Type`, `Start`, and `End` columns and optional sleep context columns. Parsing occurs on-device, with a preview before confirmation; offset-free timestamps use the baby's configured time zone. Only completed sleep rows are retained. Exact duplicate intervals are skipped, while distinct raw intervals are preserved. The file is bounded to 10 MiB and 10,000 activity rows and is never uploaded or persisted.

Confirmation atomically queues ordinary `upsertSleep` commands and refreshes the optimistic projection. Family, child, and interval determine stable session and command UUIDs. Local records, authoritative tombstones, pending commands, and acknowledged commands prevent reimport from overwriting edits or recreating deleted records. The server's command-result journal makes concurrent-device imports and lost-response retries idempotent. These commands use the existing revisions, events, delivery outbox, pagination, snapshots, conflict UI, and restore replay. Offline acceptance succeeds independently of the immediate best-effort `Sync` attempt.

### Temperature readings

Caregivers can log an individual body-temperature observation with a time, centi-Celsius value, and optional note. Readings use revision-checked upsert and delete commands, the same idempotent event and invalidation transaction as other diary records, and the shared offline projection. They are included in snapshots and restore replay. The diary does not interpret readings as a diagnosis or change sleep prediction.

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
2. requires and checks `expected_revision` for every update or delete;
3. mutates the authoritative entity;
4. appends the corresponding family event;
5. queues any required background/APNs delivery;
6. records the command result under `(family_id, command_id)`.

The entity change, event, delivery intent, and stored command result commit together. Retrying the same command ID returns the stored result without applying the mutation or enqueueing delivery again. An ambiguous client timeout is therefore safe to retry.

Creation upserts omit `expected_revision`; an upsert naming a missing entity with an expected revision is rejected rather than recreating it. Deletes return the complete canonical entity with its new revision and deletion timestamp in both the result and event, using the same representation as snapshots.

A rejected command is also returned deterministically: a retry gets the same status and error, with the entity as it is now attached, so a client whose target was created since (for example by another device's replay into a restored database) rebases instead of waiting. Its savepoint rolls back partial entity, event, and delivery work without preventing later commands in the batch from progressing.

### 4. Reconcile locally in one transaction

Before writing anything, the client validates response structure: cursors cannot move backwards or advance past the final supplied event or snapshot, event cursors must be ordered and bounded, pagination must make progress, and command-result IDs and statuses must match the sent batch. Accepted command results must include a canonical entity payload. Event, snapshot, and canonical result payloads must agree with their declared entity identity, revision, and family. A malformed response leaves the cursor and pending commands untouched.

It then performs one local SQLite transaction:

1. ingest canonical command-result payloads into `AuthoritativeRecord` only when their revision is at least the cached revision;
2. remove accepted pending commands;
3. rebase a supported stale command once, accept the server version, or create `SyncConflict`;
4. fold newer events into `AuthoritativeRecord` by revision;
5. advance `SyncState.cursor` only after those writes succeed;
6. refresh the visible projection from authoritative records plus remaining commands. Local mutations and ordinary responses re-materialize only the entities they touch; a snapshot, a reset, or any child change rebuilds the family. Tests run with `Projection.verifiesIncrementalRefresh`, which compares every incremental refresh against a full rebuild.

Server timestamps, canonical entity IDs, and revisions win after acknowledgement. A stored result returned for a retry may describe an older revision than the current cache or a compaction snapshot; it settles the command without rolling the entity backwards. Results and events share the same revision guard. If this local transaction fails, the old cursor and pending commands remain available for a safe retry.

### Snapshots, compaction, and restore recovery

The event log is an incremental transport optimization, not the only representation of family state. The server can return a complete `FamilySnapshot` at a cursor, containing every child, sleep-session, growth-measurement, and temperature-reading entity, tombstones included. The client stores a tombstone as a delete record, so the revision guard still rejects an older stored result when a reset replays the journal entry that created the entity. A new device receives a snapshot instead of replaying years of diary events. Once a family crosses the configured event threshold, the server stores a snapshot in the same transaction and deletes events through its cursor; a device behind that point receives the snapshot plus any later events.

Every database lineage also has a durable `generation` sidecar. A restored database receives a new generation before it is reopened. If a client sees a generation mismatch—or defensively finds its cursor ahead of the server—it receives a reset snapshot before the server evaluates new commands. The client atomically replaces its authoritative cache, restores its accepted-command journal into the pending outbox, and replays it in original order. Commands already present in the restored database return their stored result; commands lost after the backup point apply once. This closes the otherwise irrecoverable gap between an acknowledged client and a restored older database.

Snapshots bound how much history a lagging client downloads; they cannot bound the journal, because the journal covers data the restored server no longer has. The journal is bounded by backup retention instead. A restore can only reach a point inside Litestream's retention (24 hours), so a command acknowledged more than `JournalRetention` before a successful same-generation `Sync` is present in every database the operator can restore. The client only prunes on such a response: if a restore happened while it was offline, its next response is a reset, which carries no cutoff, so the entries it still needs are replayed first. `JournalRetention` must stay longer than Litestream retention plus replication lag; raise it before raising backup retention.

## Conflict model

Updates and deletes carry the revision the user edited. A mismatched revision is a conflict, never an implicit last-write-wins update.

Some conflicts have a bounded automatic resolution, such as one rebase against the returned server revision. Automation runs at most once.

A rejection without a server entity, for a command that needs an existing one (a wake, an edit with an expected revision, or a delete), is deferred rather than shown as a conflict. After a restore every device replays its own journal, so one phone's wake can reach the server before another phone's replayed start recreates the session. The command stays pending and visible in its original position, is not resent until the family cursor moves past the response that rejected it, is resent under a new command ID (the server stored the rejection under the old one, and nothing was applied under it), and becomes an ordinary conflict if it is still unresolved a day (server time) after the first rejection. Anything ambiguous becomes a durable `SyncConflict`; the user can keep the local intent as a new command or accept the server version.

Duplicate active-sleep starts are a domain exception handled idempotently: a start within 15 minutes (either direction) of another session's start, when that session had not ended by the new start, is mapped to the session the diary presents for it rather than creating a second one. The session may have ended since: after a restore, its end can be replayed before the other phone's duplicate tap. A start after that session's end is a new sleep, however close. The client treats the local session ID as an alias: in the same reconciliation transaction it rewrites queued wake, edit, and delete commands for that session to the canonical ID and shifts their expected revisions by the canonical revision minus one. A command in the same batch that was rejected only because it named the local ID is re-queued under a new command ID. A stale wake for a session that is still active on the server retries once against the server revision.

### Recorded intervals and the presented diary

Overlap handling never edits caregiver intent. Every sleep row stores its recorded interval (`recorded_started_at`, `recorded_ended_at`), which only start, wake, and edit commands change. The presented interval and `superseded_by_id`, which events, snapshots, and clients see, are derived by `presentSleeps` from all of the child's recorded intervals after every sleep write:

- sessions that overlap (touching intervals are separate) or start within two minutes of the previous one form a run, presented as one entry from the run's earliest start to its latest end; an unfinished session in the run represents it (so a wake reaches a session that can take it), otherwise the earliest does, and the others are presented as superseded by it;
- an unfinished session is presented as ended where a session starting more than 15 minutes after it begins, because a new sleep implies the earlier one ended (a missed wake tap, or journals replayed per device after a restore, which loses the cross-device order);
- only rows whose presentation changes get a new revision and event.

Because the presentation is recomputed rather than stored as a merge, correcting an overlong sleep, deleting a session, or replaying commands in any order after a restore reshapes the diary instead of permanently hiding a sleep that an earlier merge absorbed. A wake applies to the recorded unfinished session even when the presentation already shows it ended or folded into another. Deleting removes only the named session; anything it was presenting reappears, so a mistaken entry that overlapped a running sleep can be removed without losing that sleep. Updates that name a deleted or superseded entity, or that move a sleep session or growth measurement to another child, are rejected as stale and return the current server entity.

## Freshness and app lifecycle

All freshness paths converge on `Sync`:

| Mechanism | When | Guarantee | Action |
| --- | --- | --- | --- |
| direct sync | launch, foreground entry, local action, pull to refresh | authoritative when successful | send commands and fetch events |
| `WatchFamily` Connect stream | while the scene is active; a `Sync` that commits new events announces the family's newest committed cursor | transient invalidation only, including generation/cursor rollback | close hint wait and call `Sync` |
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

Reconnects use bounded exponential backoff. The TCA26 family feature mounts observation for the active family and cancels it when the scene backgrounds or the selected family changes. `SessionStore.observeChanges` synchronizes before each stream wait. If a local command arrives after an in-flight sync's final outbox read, the joining caller performs another sync before reporting success. Heartbeats and finite stream lifetimes detect dead connections and refresh expiring access tokens; they do not carry durable events.

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

Disabling visible alerts does not disable silent sync invalidations. Disabling Live Activities ends local activities and prevents future remote starts for that device. Signing out deletes that device row and its tokens only after the phone has synchronized every family it still belongs to and has no pending commands or unresolved conflicts for those families. Retained commands for families the account was removed from cannot sync, so they do not block signing out or account deletion; signing out deletes them with the rest of the local data, including the acknowledged-command journal.

If the backend rejects the refresh token (expired after 30 days without use, signed out elsewhere, or erased), the app removes its tokens and shows sign-in but keeps the local database, pending commands, and journal. The app stores the signed-in user ID. Signing in again as the same account resumes with that local work; signing in as a different account clears local data first, so one account never sees or replays another's diary. A database error during refresh is reported as an internal error, not as unauthenticated, so a server fault does not force sign-in.

## Authentication and account lifecycle

Sign in with Apple is verified by the backend through code exchange and nonce-bound identity-token validation. Access tokens name both user and device; handlers derive device identity from the authenticated principal rather than trusting a body field. When a different account signs in with an existing client device identifier, the backend deletes that device row first, so push, Live Activity, and reminder state never carries across accounts. Apple signing keys are cached for an hour; an unknown key ID triggers at most one refetch per minute, and cached keys keep working while Apple's key endpoint is unreachable.

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

Remote sleep-window reminders use the same APNs presentation boundary. The backend derives per-baby/device schedules from acknowledged records; it stores only delivery identity and timing in `sleep_reminders`, never forecast state in the diary. The iPhone reserves a bounded remote ownership period before registration and suppresses local reminders within it, retaining that reservation after ambiguous responses. Sync renews ownership; local fallback covers fire times outside it. The worker revalidates membership, preferences, current wake episode and estimate before a durable single submission attempt. See [push notification ownership and expiry](patterns/push-notifications.md) for failure and timing limits.

Live Activity registration is a durable presentation control plane. The phone persists latest token work and monotonic registration revisions in device-only Keychain storage before upload, observes each activity independently, and retries after Sync/authentication and available background runtime. The backend rejects stale registration revisions; settings reconciliation and late-token end delivery enter the durable delivery outbox atomically with registration. A recovered worker retries interrupted starts, and exact-token cleanup preserves rotations. After Sync the phone ends obsolete or duplicate activities using its projection, including pending overlays. None of this work advances a cursor or replaces pending diary commands. APNs start delivery remains at least once and best effort; see [token registration recovery](patterns/push-notifications.md#token-registration-and-failure-recovery).

## Verification strategy

The highest-value tests exercise invariants rather than transport syntax:

- command replay after a lost response, including a stored result older than the cached entity;
- complete deletion tombstones in results and events;
- rejection of missing as well as stale expected revisions;
- identical enqueue timestamps and clock rollback preserving command order;
- incomplete acknowledgements preserving pending intent;
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

The executable checks live in `UnetonCoreTests/SyncCoordinatorTests.swift` (projection, response validation, ordering, pagination, batching, and journal recovery), backend `internal/app/server_test.go` (two caregivers, retries, reconnect, compaction, and restore), `internal/app/sync_boundaries_test.go` (required revisions, idempotent rejection, and deletion payloads), and `internal/app/apns_test.go` (delivery payloads). `mise run test` runs backend, load-client, and shared Swift tests; `mise run ios:build` checks the iPhone, Watch, and widget integration. These checks do not prove real-device background scheduling or APNs delivery, which remain best-effort channels and require device validation.

Two simulations compress years of family use into minutes against the real backend on a simulated clock. `mise run sim` (`platform/backend/cmd/simulate-family`) runs virtual devices that mirror `SyncCoordinator` with lost responses, restarts, restores inside the backup window, offline stretches, expired refresh tokens and a second child, and checks convergence, acknowledged intent, cursor monotonicity, stored-result stability and sleep overlap every simulated day; its short seeded runs are part of `mise run test`. `mise run sim:client` drives real `SyncCoordinator` instances, each with its own SQLite file, against `simulate-family serve`, checks that every phone and a fresh device converge, and that a restore brings back every acknowledged entity. Both print the seed of a failure.

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

## Family management and membership freshness

The authenticated `GetFamilyManagement` API provides a small control-plane view of caregiver names and roles and unclaimed invitations. Profile edits, family names, caregiver removal, ownership transfer, invitation revocation, leaving, and family deletion use dedicated ConnectRPC mutations with server-side role checks. Ownership transfer updates the family owner and both membership roles in one SQLite transaction. Deleting a family requires one active owner and no other active caregivers. A caregiver cannot leave while owning the family; they transfer ownership or remove the other caregivers and delete the family.

Membership and profile changes are not diary entities and do not advance the diary cursor. The client refreshes authentication on foreground observation and after its own membership changes, then shows only families in the refreshed membership list. If Sync or WatchFamily denies access, the client refreshes membership and stops observing that family. The Watch snapshot is filtered by the same membership list. A revoked caregiver's offline commands remain durable in the local database. A new invitation for the same family restores the sync route for those commands; the client never silently discards them during a membership refresh. When no families remain, setup explains that unsent changes are retained and offers invitation scanning. Control-plane screens can be refreshed independently because they do not apply diary state or advance a sync cursor.

Baby creation, settings edits, and deletion use durable child commands. Settings edits carry expected revisions; multiple offline edits reserve sequential expected revisions. Child deletion creates a tombstone and a delete event on the server. The local projection hides the child and its diary immediately while retaining the pending command. Snapshot recovery recognizes child tombstones and does not recreate deleted children. The server keeps child and diary records for event-log recovery until the family is deleted, consistent with the retention policy.

## Backend process lifecycle

Configuration separates the typed effective settings, environment decoding and contract, validation, and secret-safe diagnostics. The CLI and startup log share one redacted representation covering every supported environment setting. Environment names and development defaults remain stable.

The runner separates runtime construction, waiting, and shutdown, with the runtime owning the listener, HTTP server, worker and request contexts, and database. Startup failure releases acquired resources, and runtime failures are combined with cleanup errors. Bootstrap validates configuration and Apple and APNs provider keys before opening SQLite or accepting HTTP traffic. It rewraps stored Apple credentials, binds the listener, then starts the credential-audit and push-delivery workers under a process-owned cancellable context. A failed bind never starts either worker. Every exit path cancels and joins workers before closing SQLite.

On shutdown the server first withdraws readiness and signals `WatchFamily` streams to finish. Ordinary requests retain independent contexts so they can commit and respond within the configured grace period. If that period expires, shutdown closes request admission, cancels outstanding request contexts and force-closes HTTP connections. It waits for admitted handlers and workers to finish before releasing the database. Unexpected HTTP serve failure uses the same cleanup path. An interrupted mutation still recovers through command idempotency and the next Sync; shutdown never clears client pending commands or uses streams to apply diary state.
