#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
vps_root="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$vps_root/../../.." && pwd)"

export UNETON_ORB_MACHINE_NAME="${UNETON_ORB_MACHINE_NAME:-uneton-loadtest-orb}"
export UNETON_ORB_ARCH="${UNETON_ORB_ARCH:-arm64}"
export UNETON_ORB_CPUS="${UNETON_ORB_CPUS:-2}"
export UNETON_ORB_MEMORY="${UNETON_ORB_MEMORY:-4G}"
export UNETON_ORB_DISK="${UNETON_ORB_DISK:-40G}"
export UNETON_ORB_ENABLE_DEVELOPMENT_AUTH=1

ssh_target="deploy@${UNETON_ORB_MACHINE_NAME}@localhost"
ssh_args=(-p 32222 -i "${HOME}/.orbstack/ssh/id_ed25519" -o StrictHostKeyChecking=accept-new)

prepare() {
  "$script_dir/orb-machine.sh" rehearse
}

run_load() {
  "$script_dir/orb-machine.sh" verify
  echo "OrbStack target limits:"
  orb info -f json "$UNETON_ORB_MACHINE_NAME" | grep -E '"(memory_limit_mib|cpu_limit|disk_limit_bytes)"'
  tunnel_port="${UNETON_LOADTEST_TUNNEL_PORT:-18080}"
  target_url="http://127.0.0.1:${tunnel_port}"
  ssh "${ssh_args[@]}" -o ExitOnForwardFailure=yes -N -L "127.0.0.1:${tunnel_port}:127.0.0.1:80" "$ssh_target" &
  tunnel_pid=$!
  cleanup() { kill "$tunnel_pid" 2>/dev/null || true; }
  trap cleanup EXIT
  for _ in {1..20}; do
    curl --fail --silent "$target_url/health/ready" >/dev/null 2>&1 && break
    sleep 0.25
  done
  readiness="$(curl --fail --show-error --silent "$target_url/health/ready")"
  [[ "$readiness" == *'"status":"ready"'* ]] || { echo "Unexpected tunneled readiness response: $readiness" >&2; exit 1; }

  echo "Running one-scenario API preflight against $target_url"
  (
    cd "$repo_root"
    env -u GOROOT GOCACHE="${GOCACHE:-/tmp/uneton-go-cache}" go run ./clients/loadtest \
      -base-url "$target_url" -families 1 -cycles 1 -concurrency 1 -timeout 30s
  )

  mkdir -p "$vps_root/.orb"
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  report="$vps_root/.orb/loadtest-${run_id}.tsv"
  result_log="$vps_root/.orb/loadtest-${run_id}.log"
  printf 'timestamp\tcontainer\tcpu\tmemory\tnetwork_io\tblock_io\n' > "$report"

  (
    set +e
    (
      cd "$repo_root"
      env -u GOROOT GOCACHE="${GOCACHE:-/tmp/uneton-go-cache}" go run ./clients/loadtest \
        -base-url "$target_url" \
        -ramp-concurrency "${UNETON_LOADTEST_RAMP:-1,2,4,8,16,32,64}" \
        -scenarios-per-worker "${UNETON_LOADTEST_SCENARIOS_PER_WORKER:-4}" \
        -cycles "${UNETON_LOADTEST_CYCLES:-3}" \
        -timeout "${UNETON_LOADTEST_STAGE_TIMEOUT:-3m}" \
        -max-p95 "${UNETON_LOADTEST_MAX_P95:-500ms}" \
        "$@"
    ) 2>&1 | tee "$result_log"
    pipeline_status="${PIPESTATUS[0]}"
    exit "$pipeline_status"
  ) &
  load_pid=$!

  while kill -0 "$load_pid" 2>/dev/null; do
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ssh "${ssh_args[@]}" "$ssh_target" "sudo docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.NetIO}}|{{.BlockIO}}'" 2>/dev/null \
      | while IFS='|' read -r container cpu memory network_io block_io; do
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$timestamp" "$container" "$cpu" "$memory" "$network_io" "$block_io" >> "$report"
        done
    sleep 1
  done

  if wait "$load_pid"; then
    status=0
  else
    status=$?
  fi
  echo "load-test results: $result_log"
  echo "container telemetry: $report"
  return "$status"
}

case "${1:-all}" in
  prepare) prepare ;;
  run) shift; run_load "$@" ;;
  all) shift || true; prepare; run_load "$@" ;;
  *) echo "usage: $0 {prepare|run|all} [load-test flags]" >&2; exit 2 ;;
esac
