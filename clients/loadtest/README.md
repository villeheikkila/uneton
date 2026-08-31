# Load-test client

This Go client drives the same generated ConnectRPC API as the Apple client. Each scenario models a shared family with two independently authenticated caregivers and exercises family invitation, initial projection download, live stream invalidation, optimistic sleep start, idempotent command retry, cross-device pull, revision-checked wake-up, and final reconciliation.

Start the development server, then run a small scenario:

```sh
mise run dev
mise run loadtest -- -families 10 -cycles 3 -concurrency 4
```

Use `-think-time 250ms` for human-paced flows or omit it to generate load. The command exits non-zero if any scenario or RPC fails and prints per-operation call counts, failures, and p50/p95/p99 latency.

For a capacity search, pass increasing concurrency stages:

```sh
mise run loadtest -- \
  -ramp-concurrency 1,2,4,8,16,32,64 \
  -scenarios-per-worker 4 \
  -cycles 3 \
  -max-p95 500ms
```

Each stage creates fresh families and runs the requested scenarios per worker. The ramp stops at the first stage with an RPC/scenario failure, a timeout, or aggregate RPC p95 over the threshold. A stopped ramp is a measured capacity boundary and exits successfully; setup errors and interrupted runs still fail. The last passing stage is the useful result. Increase `scenarios-per-worker` for a longer, more stable observation window before treating a result as a capacity estimate.

`mise run loadtest:vm` creates and provisions the production-shaped constrained VM, then runs this ramp from the host. `mise run loadtest:vm:run` repeats it without rebuilding the VM. Per-container CPU, memory, network, and block-I/O samples are written beneath the ignored `platform/infra/vps/.orb/` directory.
