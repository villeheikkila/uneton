#!/usr/bin/env bash
# Runs the Swift family simulation: real SyncCoordinator devices against
# `simulate-family serve` on a simulated clock.
# Environment: UNETON_SIM_YEARS (default 1), UNETON_SIM_SEED (default 1),
# UNETON_SIM_LOST_RESPONSES (default 0.02), UNETON_SIM_START (RFC3339).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'kill "${server_pid:-}" 2>/dev/null || true; rm -rf "$work"' EXIT

env -u GOROOT go build -o "$work/simulate-family" "$root/platform/backend/cmd/simulate-family"
start="${UNETON_SIM_START:-2026-01-05T08:00:00Z}"
"$work/simulate-family" serve -addr 127.0.0.1:0 -db "$work/server.sqlite" -start "$start" >"$work/server.out" 2>"$work/server.err" &
server_pid=$!
for _ in $(seq 1 100); do
  if grep -q '^READY ' "$work/server.out"; then break; fi
  if ! kill -0 "$server_pid" 2>/dev/null; then cat "$work/server.err" >&2; exit 1; fi
  sleep 0.1
done
url="$(grep '^READY ' "$work/server.out" | head -1 | cut -d' ' -f2)"
[ -n "$url" ] || { echo "simulator did not report READY" >&2; cat "$work/server.err" >&2; exit 1; }

set +e
UNETON_SIM_URL="$url" swift test --package-path "$root/clients/ios/UnetonPackage" \
  --filter UnetonSimulationTests "$@" 2>&1 | tee "$work/client.log"
status=${PIPESTATUS[0]}
set -e
if [ "$status" -ne 0 ]; then
  echo "--- simulator stderr (tail) ---" >&2
  tail -40 "$work/server.err" >&2
fi
exit "$status"
