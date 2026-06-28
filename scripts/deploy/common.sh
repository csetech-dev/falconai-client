#!/usr/bin/env bash
# Shared helpers for FalconAI Docker Compose split deployment.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STORAGE_COMPOSE="${ROOT_DIR}/docker-compose.storage.yml"
APP_COMPOSE="${ROOT_DIR}/docker-compose.app.yml"

# shellcheck disable=SC2034
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { printf '%b[%s] %s%b\n' "${BLUE}" "$(date '+%H:%M:%S')" "$*" "${NC}"; }
ok()    { printf '%b[%s] ✓ %s%b\n' "${GREEN}" "$(date '+%H:%M:%S')" "$*" "${NC}"; }
warn()  { printf '%b[%s] ! %s%b\n' "${YELLOW}" "$(date '+%H:%M:%S')" "$*" "${NC}"; }
die()   { printf '%b[%s] ERROR: %s%b\n' "${RED}" "$(date '+%H:%M:%S')" "$*" "${NC}" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
  else
    die "Docker Compose is not installed. Install Docker Engine with the compose plugin."
  fi
}

normalize_env_file() {
  local env_file="$1"
  [[ -f "${env_file}" ]] || return 0
  if grep -q $'\r' "${env_file}" 2>/dev/null; then
    warn "Stripping Windows CRLF from ${env_file}"
    tr -d '\r' < "${env_file}" > "${env_file}.tmp"
    mv "${env_file}.tmp" "${env_file}"
  fi
}

ensure_env_file() {
  local example="$1"
  local target="$2"
  local label="$3"
  local init_cmd="$4"

  if [[ -f "${target}" ]]; then
    normalize_env_file "${target}"
    ok "Using ${label}: ${target}"
    return 0
  fi

  if [[ ! -f "${example}" ]]; then
    die "Missing ${label} template: ${example}"
  fi

  die "Missing ${target}. Run '${init_cmd}' first, edit secrets, then deploy again."
}

init_env_file() {
  local example="$1"
  local target="$2"
  local label="$3"

  if [[ -f "${target}" ]]; then
    warn "${label} already exists: ${target}"
    return 0
  fi

  if [[ ! -f "${example}" ]]; then
    die "Missing ${label} template: ${example}"
  fi

  tr -d '\r' < "${example}" > "${target}"
  ok "Created ${target}"
  warn "Edit passwords in ${target}, then run the deploy command again."
}

is_docker_interface() {
  local iface="$1"
  case "${iface}" in
    docker*|br-*|veth*|lo|virbr*|podman*)
      return 0
      ;;
  esac
  return 1
}

# Routable host IP for other machines to connect (not docker0 / compose bridge IPs).
detect_host_ip() {
  local ip iface

  if [[ -n "${STORAGE_ADVERTISE_IP:-}" ]]; then
    echo "${STORAGE_ADVERTISE_IP}"
    return 0
  fi

  if command -v ip >/dev/null 2>&1; then
    # IP chosen for outbound traffic on the default route.
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
    if [[ -n "${ip}" && "${ip}" != "127.0.0.1" ]]; then
      echo "${ip}"
      return 0
    fi

    # First IPv4 on a non-Docker interface.
    while read -r iface _ addr _; do
      is_docker_interface "${iface}" && continue
      ip="${addr%%/*}"
      if [[ -n "${ip}" && "${ip}" != "127.0.0.1" ]]; then
        echo "${ip}"
        return 0
      fi
    done < <(ip -4 -o addr show scope global 2>/dev/null)
  fi

  # Last resort: hostname -I, skipping typical Docker bridge ranges.
  if read -r -a addrs _ <<<"$(hostname -I 2>/dev/null)"; then
    for ip in "${addrs[@]}"; do
      [[ "${ip}" == 127.0.0.1 ]] && continue
      if [[ "${ip}" =~ ^172\.(1[7-9]|2[0-9]|3[0-1])\. ]]; then
        continue
      fi
      echo "${ip}"
      return 0
    done
  fi

  return 1
}

load_env_file() {
  local env_file="$1"
  normalize_env_file "${env_file}"
  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  set +a
}

warn_if_default_secret() {
  local name="$1"
  local value="$2"
  local defaults=("postgres" "minioadmin" "change-me" "change-me-strong-password")

  for d in "${defaults[@]}"; do
    if [[ "${value}" == "${d}" ]] || [[ "${value}" == *"change-me"* ]]; then
      warn "${name} is still a template/default value — change it for production."
      return
    fi
  done
}

# Remove stopped containers (and optionally dangling images) after compose build/up.
prune_docker_artifacts() {
  local prune_images="${1:-1}"

  if [[ "${PRUNE_AFTER_BUILD:-1}" != "1" ]]; then
    log "Skipping Docker prune (PRUNE_AFTER_BUILD=${PRUNE_AFTER_BUILD})"
    return 0
  fi

  log "Pruning stopped containers..."
  docker container prune -f

  if [[ "${prune_images}" == "1" ]]; then
    log "Pruning dangling images from build..."
    docker image prune -f
  fi

  ok "Docker prune complete."
}

warn_opensearch_host_prereqs() {
  if [[ ! -r /proc/sys/vm/max_map_count ]]; then
    return 0
  fi
  local max_map
  max_map="$(cat /proc/sys/vm/max_map_count)"
  if (( max_map < 262144 )); then
    warn "vm.max_map_count=${max_map} (OpenSearch needs >= 262144)."
    warn "Run: sudo sysctl -w vm.max_map_count=262144"
    warn "Persist: echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-opensearch.conf && sudo sysctl --system"
  fi
}

wait_for_tcp() {
  local host="$1"
  local port="$2"
  local timeout="${3:-120}"
  local elapsed=0

  log "Waiting for ${host}:${port} (timeout ${timeout}s)..."
  while (( elapsed < timeout )); do
    if (echo >/dev/tcp/"${host}"/"${port}") >/dev/null 2>&1; then
      ok "Reachable: ${host}:${port}"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  die "Timed out waiting for ${host}:${port}"
}

wait_for_http() {
  local url="$1"
  local timeout="${2:-120}"
  local elapsed=0

  log "Waiting for ${url} (timeout ${timeout}s)..."
  while (( elapsed < timeout )); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      ok "Healthy: ${url}"
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done

  die "Timed out waiting for ${url}"
}

wait_for_compose_healthy() {
  local env_file="$1"
  local compose_file="$2"
  local service="$3"
  local timeout="${4:-180}"
  local elapsed=0

  log "Waiting for service '${service}' to become healthy..."
  while (( elapsed < timeout )); do
    local cid
    cid="$("${COMPOSE[@]}" --env-file "${env_file}" -f "${compose_file}" ps -q "${service}" 2>/dev/null || true)"
    if [[ -n "${cid}" ]]; then
      local status
      status="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${cid}" 2>/dev/null || echo "unknown")"
      if [[ "${status}" == "healthy" || "${status}" == "running" ]]; then
        ok "Service '${service}' is ${status}"
        return 0
      fi
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done

  die "Service '${service}' did not become healthy within ${timeout}s"
}

resolve_storage_host() {
  if [[ -z "${POSTGRES_HOST:-}" && -n "${STORAGE_SERVER_IP:-}" ]]; then
    export POSTGRES_HOST="${STORAGE_SERVER_IP}"
  fi
  if [[ -z "${MINIO_ENDPOINT:-}" && -n "${STORAGE_SERVER_IP:-}" ]]; then
    export MINIO_ENDPOINT="${STORAGE_SERVER_IP}:${MINIO_API_PORT:-12004}"
  fi
  if [[ -z "${MINIO_PUBLIC_ENDPOINT:-}" && -n "${MINIO_ENDPOINT:-}" ]]; then
    export MINIO_PUBLIC_ENDPOINT="${MINIO_ENDPOINT}"
  fi
  if [[ -z "${MINIO_CONSOLE_ENDPOINT:-}" && -n "${STORAGE_SERVER_IP:-}" ]]; then
    export MINIO_CONSOLE_ENDPOINT="${STORAGE_SERVER_IP}:${MINIO_CONSOLE_PORT:-12015}"
  fi
}

print_storage_banner() {
  local ip="${1}"
  cat <<EOF

┌──────────────────────────────────────────────────────────────────┐
│  Storage stack is up. Use these values in .env.app on the app host │
├──────────────────────────────────────────────────────────────────┤
│  STORAGE_SERVER_IP=${ip}
│  POSTGRES_HOST=${ip}
│  POSTGRES_PORT=${POSTGRES_PORT:-12002}
│  MINIO_ENDPOINT=${ip}:${MINIO_API_PORT:-12004}
│  MINIO_PUBLIC_ENDPOINT=${ip}:${MINIO_API_PORT:-12004}
├──────────────────────────────────────────────────────────────────┤
│  PostgreSQL:  ${ip}:${POSTGRES_PORT:-12002}
│  MinIO API:    http://${ip}:${MINIO_API_PORT:-12004}
│  MinIO UI:     http://${ip}:${MINIO_CONSOLE_PORT:-12015}
└──────────────────────────────────────────────────────────────────┘

On the host running deploy-app:
  cp .env.app.example .env.app
  # set STORAGE_SERVER_IP=${ip} and matching passwords
  ./scripts/deploy/deploy.sh app

EOF
}

print_app_banner() {
  cat <<EOF

┌──────────────────────────────────────────────────────────────────┐
│  Application stack is up                                         │
├──────────────────────────────────────────────────────────────────┤
│  Gateway:    ${PUBLIC_GATEWAY_URL:-http://localhost:12006}
│  Frontend:   http://localhost:12001
│  Adminer:    ${PUBLIC_GATEWAY_URL:-http://localhost:12006}/databaselookup
│  MinIO UI:   ${PUBLIC_GATEWAY_URL:-http://localhost:12006}/storage-console/
│  Storage DB: ${POSTGRES_HOST}:${POSTGRES_PORT:-5432}
└──────────────────────────────────────────────────────────────────┘

EOF
}
