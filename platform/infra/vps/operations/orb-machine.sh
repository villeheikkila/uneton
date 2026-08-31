#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
vps_root="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$vps_root/../../.." && pwd)"
machine_name="${UNETON_ORB_MACHINE_NAME:-uneton-vps-orb}"
machine_arch="${UNETON_ORB_ARCH:-arm64}"
machine_cpus="${UNETON_ORB_CPUS:-2}"
machine_memory="${UNETON_ORB_MEMORY:-4G}"
machine_disk="${UNETON_ORB_DISK:-30G}"
backend_image="${UNETON_ORB_BACKEND_IMAGE:-uneton-backend:orb}"
ssh_target="deploy@${machine_name}@localhost"
ssh_args=(-p 32222 -i "${HOME}/.orbstack/ssh/id_ed25519" -o StrictHostKeyChecking=accept-new)

require() { command -v "$1" >/dev/null || { echo "$1 is required" >&2; exit 127; }; }
machine_exists() { orb info "$machine_name" >/dev/null 2>&1; }
machine_ipv4() { orb info "$machine_name" | awk '/^IPv4:/ { print $2; exit }'; }

generate_rehearsal_secrets() {
  local environment_file="$1" token_secret token_key private_key
  token_secret="$(openssl rand -hex 32)"
  token_key="$(openssl rand -base64 32)"
  private_key="$(openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt | awk 'NF { printf "%s\\n", $0 }')"
  sed -i.bak "s|^UNETON_AUTH_TOKEN_SECRET=.*|UNETON_AUTH_TOKEN_SECRET=${token_secret}|" "$environment_file"
  sed -i.bak "s|^UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_KEYRING_JSON=.*|UNETON_AUTH_APPLE_TOKEN_ENCRYPTION_KEYRING_JSON={\"orb-rehearsal\":\"${token_key}\"}|" "$environment_file"
  sed -i.bak "s|^UNETON_INTEGRATION_APPLE_PRIVATE_KEY_PEM=.*|UNETON_INTEGRATION_APPLE_PRIVATE_KEY_PEM=${private_key}|" "$environment_file"
  rm "$environment_file.bak"
}

memory_bytes() {
  case "$1" in
    *G|*g) echo $(( ${1%[Gg]} * 1024 * 1024 * 1024 )) ;;
    *M|*m) echo $(( ${1%[Mm]} * 1024 * 1024 )) ;;
    *) echo "$1" ;;
  esac
}

create() {
  require orb
  if machine_exists; then
    echo "OrbStack machine '$machine_name' already exists"
    return
  fi
  orb create --arch "$machine_arch" --cpus "$machine_cpus" --memory "$machine_memory" --disk "$machine_disk" --user deploy ubuntu:noble "$machine_name"
}

prepare_machine_files() {
  require openssl
  mkdir -p "$vps_root/.orb"
  inventory_file="$vps_root/.orb/inventory.${machine_name}.ini"
  runtime_env_file="$vps_root/.orb/runtime.${machine_name}.env"
  if [[ ! -f "$runtime_env_file" ]]; then
    cp "$vps_root/runtime/env.orb.example" "$runtime_env_file"
    sed -i.bak "s/uneton-vps-orb/${machine_name}/g" "$runtime_env_file"
    rm "$runtime_env_file.bak"
    generate_rehearsal_secrets "$runtime_env_file"
  fi
  sed -i.bak "s|^COMPOSE_BACKEND_IMAGE=.*|COMPOSE_BACKEND_IMAGE=${backend_image}|" "$runtime_env_file"
  rm "$runtime_env_file.bak"
  if [[ "${UNETON_ORB_ENABLE_DEVELOPMENT_AUTH:-0}" == "1" ]]; then
    sed -i.bak 's/^UNETON_RUNTIME_ENVIRONMENT=.*/UNETON_RUNTIME_ENVIRONMENT=development/' "$runtime_env_file"
    rm "$runtime_env_file.bak"
  fi
  sed -i.bak 's|^CADDY_PUBLIC_HOST=.*|CADDY_PUBLIC_HOST=:80|' "$runtime_env_file"
  rm "$runtime_env_file.bak"
  printf '[orb]\n%s ansible_host=127.0.0.1 ansible_port=32222 ansible_user=deploy@%s ansible_ssh_private_key_file=~/.orbstack/ssh/id_ed25519 ansible_python_interpreter=/usr/bin/python3 ansible_ssh_common_args='"'"'-o StrictHostKeyChecking=accept-new'"'"'\n' "$machine_name" "$machine_name" > "$inventory_file"
}

provision() {
  require orb; require docker; require ssh; require ansible-playbook
  machine_exists || { echo "Run the create task first" >&2; exit 2; }
  prepare_machine_files
  ansible_temp="${TMPDIR:-/tmp}/uneton-ansible"
  mkdir -p "$ansible_temp"
  ANSIBLE_LOCAL_TEMP="$ansible_temp" ansible-playbook \
    -i "$inventory_file" \
    "$vps_root/ansible/playbook.yml" \
    --extra-vars "runtime_env_file=$runtime_env_file" \
    --tags bootstrap
  if [[ "${UNETON_ORB_USE_EXISTING_BACKEND_IMAGE:-0}" == "1" ]]; then
    docker image inspect "$backend_image" >/dev/null
  else
    docker build -f "$repo_root/platform/backend/Dockerfile" -t "$backend_image" "$repo_root"
  fi
  docker save "$backend_image" | ssh "${ssh_args[@]}" "$ssh_target" sudo docker load
  ANSIBLE_LOCAL_TEMP="$ansible_temp" ansible-playbook -i "$inventory_file" "$vps_root/ansible/playbook.yml" --extra-vars "runtime_env_file=$runtime_env_file"
}

verify() {
  require orb; require curl; require ssh
  target_ip="$(machine_ipv4)"
  [[ -n "$target_ip" ]] || { echo "Could not determine IPv4 address for '$machine_name'" >&2; exit 1; }
  expected_memory_bytes="$(memory_bytes "$machine_memory")"
  expected_cpu_quota=$((machine_cpus * 100000))
  read -r actual_memory_bytes actual_cpu_quota < <(
    ssh "${ssh_args[@]}" "$ssh_target" \
      "printf '%s %s\\n' \"\$(cat /sys/fs/cgroup/memory.max)\" \"\$(cut -d' ' -f1 /sys/fs/cgroup/cpu.max)\""
  )
  [[ "$actual_memory_bytes" == "$expected_memory_bytes" ]] || {
    echo "Expected ${expected_memory_bytes} bytes of VM memory, got ${actual_memory_bytes}" >&2
    exit 1
  }
  [[ "$actual_cpu_quota" == "$expected_cpu_quota" ]] || {
    echo "Expected CPU quota ${expected_cpu_quota}, got ${actual_cpu_quota}" >&2
    exit 1
  }
  readiness="$(curl --fail --show-error --silent --retry 20 --retry-delay 1 "http://${target_ip}/health/ready")"
  [[ "$readiness" == *'"status":"ready"'* ]] || { echo "Unexpected readiness response: $readiness" >&2; exit 1; }
  ssh "${ssh_args[@]}" "$ssh_target" sudo docker compose -f /srv/uneton/compose.yaml ps
  for service in api caddy litestream; do
    running_service="$(ssh "${ssh_args[@]}" "$ssh_target" sudo docker compose -f /srv/uneton/compose.yaml ps --status running --services "$service")"
    [[ "$running_service" == "$service" ]] || { echo "$service is not running" >&2; exit 1; }
  done
  backup_file=""
  for _ in {1..30}; do
    backup_file="$(ssh "${ssh_args[@]}" "$ssh_target" sudo find /var/lib/docker/volumes/uneton_uneton-backups/_data -type f -print -quit)"
    [[ -n "$backup_file" ]] && break
    sleep 1
  done
  [[ -n "$backup_file" ]] || { echo "Litestream did not create a replica within 30 seconds" >&2; exit 1; }
  echo "API, persistent volume, Litestream replica, and VM resource limits are healthy"
}

restore_test() {
  require ssh
  ssh "${ssh_args[@]}" "$ssh_target" sudo /srv/uneton/restore-test.sh
  verify
}

rollout() {
  UNETON_ORB_USE_EXISTING_BACKEND_IMAGE=1 provision
  verify
}

case "${1:-}" in
  create) create ;;
  provision) provision ;;
  verify) verify ;;
  restore-test) restore_test ;;
  rehearse) create; provision; verify ;;
  rollout) rollout ;;
  *) echo "usage: $0 {create|provision|verify|restore-test|rehearse|rollout}" >&2; exit 2 ;;
esac
