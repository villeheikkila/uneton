# simulate-family

Deterministic simulation of a family using Uneton for years, against the real backend on a simulated clock. Every simulated day it checks synchronization invariants. A failure prints the seed and simulated day, and the same seed and flags reproduce it exactly.

## Run mode

```sh
mise run sim                                   # 3 years, seed 1
mise run sim -- -seed 7 -years 1 -verbose      # print the event log
mise run sim -- -families 8 -years 1           # 8 seeds in parallel
mise run sim -- -keep-going                    # report every failure, not just the first
```

The run uses `app.NewServer` over a temporary SQLite file, with `Config.Now` wired to the simulated clock. Clients call it in-process through the real Connect handlers. Token expiry, refresh windows, journal cutoffs, and compaction therefore all follow simulated time. For speed the simulator runs SQLite without fsync and with an in-memory rollback journal. Restarts and restores are explicit simulated events, so this changes no SQL semantics.

### The family

- **Baby sleep model** (`model.go`): driven by age. Newborns have 4-5 naps, 50-minute wake windows, and 3-4 night wakings. Around 18 months it settles to one nap with 5.5-hour windows. Jitter, sick weeks (shorter naps, more wakings, temperature readings), and Europe/Helsinki DST transitions are included. Growth is measured weekly until two months, then monthly. With `-second-child-months N`, a sibling arrives N months in.
- **Devices**: two parents' phones and a grandparent's phone. The grandparent joins at 4 months, visits about one day in eight, and is removed for two weeks at one year, then re-invited. Parent B stops opening the app for 38 days starting at day 210, leaving unsent work on the phone. This expires the 30-day refresh token, and Parent B signs in again with local data kept.
- **Caregiver behaviour**:
  - Live start and wake taps.
  - Simultaneous starts on two phones.
  - Forgotten wakes, fixed later.
  - Sleeps logged from memory hours later.
  - Mistaken entries that are then deleted.
  - Start-time corrections.
  - Growth and temperature edits and deletes.
  - Baby-settings edits.
  - Conflict resolution: 80% accept the server version, 20% keep mine.

### Virtual devices

`device.go` mirrors `SyncCoordinator.swift`:

- the pending queue and its shared sequence
- revision reservation for queued edits
- the authoritative cache folded from results, snapshots, and events
- response validation
- one automatic rebase
- durable conflicts
- duplicate-start aliasing and redirects
- journal replay after a reset
- journal pruning by `journal_retention_cutoff`
- snapshot tombstones stored as deletes
- deferral of commands rejected because their target does not exist yet: they keep their sequence position under a new command ID (the server keeps the stored rejection for the old one), wait until the family cursor passes the response's cursor, and become conflicts after 24 hours of server time

Sign-in mirrors `SessionStore`. It retries once after an access-token refresh. If the refresh token is rejected, it signs in again and keeps local data, or wipes local data if a different account comes back.

### Faults

`-fault-rate` scales all faults:

- lost responses: the server commits, and the device drops the reply
- offline stretches lasting hours or days
- server restarts that reopen the same file
- database restores

For a restore, the simulator first takes a `VACUUM INTO` checkpoint between one hour and `-restore-horizon` (default 24 h, mirroring Litestream retention) earlier. It then restores that checkpoint and rotates the `.sync-generation` sidecar.

### Invariants

The invariants are checked daily after reachable devices drain with faults off. They run again at the end after every device is forced online.

- **Convergence**: every reachable device's visible projection equals the server's.
- **Fresh device**: every `-fresh-every` days, a new device syncs from nothing in 50-event pages and must also equal the server.
- **Recorded sleep coverage** (checks effects): every real sleep a caregiver recorded at least two days ago is covered by a visible server session. A sleep is excused only when a caregiver resolved a conflict about it by accepting the server version, or when its record cannot have reached the server yet: the recording device is unreachable, or still holds pending commands or conflicts. The final report counts excused sleeps separately.
- **Acknowledged intent**: every command any device saw accepted still has a stored result on the server. This includes commands accepted after a restored backup, which only the devices' journals can return. A device that is offline is checked once it is back.
- **Idempotent results**: within one generation, a command ID never yields two different results.
- **Monotonic cursors**: device and server cursors never move backwards within a generation.
- **Sleep integrity**: per child, no overlapping visible sleeps, and at most one active sleep.
- **Pending durability**: a pending command only leaves the queue through a result for it.
- **Sync availability**: no sync fails for any reason other than offline, lost response, or revoked membership.

## Serve mode

```sh
mise run sim:serve -- -addr 127.0.0.1:0 -db /tmp/sim.sqlite -start 2026-01-05T00:00:00Z
```

Serve mode prints exactly one line, `READY http://127.0.0.1:<port>`, then serves the real ConnectRPC API on a simulated clock. Control endpoints on the same listener:

| Endpoint | Body | Effect |
| --- | --- | --- |
| `GET /_sim/clock` | | `{"now": RFC3339Nano}` |
| `POST /_sim/clock` | `{"now": ...}` or `{"advanceSeconds": n}` | moves time forward; 400 if it would go backwards |
| `POST /_sim/restart` | | reopens the store and server on the same listener |
| `POST /_sim/checkpoint` | | `{"id": ...}` for a consistent copy |
| `POST /_sim/restore` | `{"id": ...}` | restores that copy, rotates the generation, restarts |

These endpoints exist only in this binary, never in `cmd/server`.
