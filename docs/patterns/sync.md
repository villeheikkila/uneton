# Offline sync invariants

See [`../architecture.md`](../architecture.md) for the complete client/server lifecycle, ownership boundaries, freshness channels, and recovery model.

- A command ID returns the same stored result when retried.
- Applying a command and appending its event is atomic.
- Updates and deletes compare `expected_revision`.
- Local cursors advance only after returned events commit locally.
- Pulls never discard unresolved pending commands.
- Acknowledged server timestamps and revisions win.
- `WatchFamily` is an invalidation hint; only `Sync` transfers durable state.
- A generation mismatch or cursor rollback returns a full snapshot before any new command is evaluated.
- Clients retain accepted commands so an acknowledged mutation can be replayed after a restored older database.
- Events may be compacted only behind a durable family snapshot; a stale cursor receives that snapshot plus later events.

The authenticated device comes from the access token, not a duplicate Sync field. Keep behavior tests around retries, conflicts, pagination, reconnects, and two-caregiver ordering, and keep the load client aligned with the Apple client command sequence.
