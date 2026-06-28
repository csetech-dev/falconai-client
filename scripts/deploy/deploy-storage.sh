#!/usr/bin/env bash
# Deploy PostgreSQL + MinIO (storage stack).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

ENV_FILE="${ROOT_DIR}/.env.storage"
ENV_EXAMPLE="${ROOT_DIR}/.env.storage.example"

require_cmd docker
detect_compose

cd "${ROOT_DIR}"
ensure_env_file "${ENV_EXAMPLE}" "${ENV_FILE}" "storage environment" "make init-storage"
load_env_file "${ENV_FILE}"

warn_if_default_secret "POSTGRES_PASSWORD" "${POSTGRES_PASSWORD:-}"
warn_if_default_secret "MINIO_ROOT_PASSWORD" "${MINIO_ROOT_PASSWORD:-}"

log "Pulling storage images..."
"${COMPOSE[@]}" --env-file "${ENV_FILE}" -f "${STORAGE_COMPOSE}" pull

log "Starting storage stack..."
"${COMPOSE[@]}" --env-file "${ENV_FILE}" -f "${STORAGE_COMPOSE}" up -d

wait_for_compose_healthy "${ENV_FILE}" "${STORAGE_COMPOSE}" "postgres" 180
wait_for_compose_healthy "${ENV_FILE}" "${STORAGE_COMPOSE}" "minio" 120

prune_docker_artifacts 0

STORAGE_IP="$(detect_host_ip || true)"
if [[ -z "${STORAGE_IP}" ]]; then
  STORAGE_IP="127.0.0.1"
  warn "Could not detect host IP. Set STORAGE_ADVERTISE_IP in .env.storage to this machine's LAN IP."
fi

ok "Storage deployment complete."
print_storage_banner "${STORAGE_IP}"
