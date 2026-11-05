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

if wireguard_enabled; then
  # Tunnel ON: require the config, keep storage ports off the public NIC
  # (bound to loopback), and start the WireGuard sidecar (profile).
  require_wireguard_conf storage
  export STORAGE_BIND_IP="127.0.0.1"
  add_compose_profile wireguard
  log "WireGuard tunnel ENABLED — Postgres/MinIO bound to 127.0.0.1 (tunnel-only)."
else
  # Tunnel OFF: publish storage ports publicly so the app host connects directly.
  export STORAGE_BIND_IP="0.0.0.0"
  warn "WireGuard tunnel DISABLED (WIREGUARD_ENABLED=false) — Postgres/MinIO published publicly in PLAINTEXT."
  warn "Set WIREGUARD_ENABLED=true (or remove it) to encrypt the app<->storage link."
fi

# Monitoring exporters (P1.7a): opt-in. Off unless MONITORING_ENABLED=true.
if monitoring_enabled; then
  if [[ -z "${MONITOR_DB_PASSWORD:-}" ]]; then
    die "MONITORING_ENABLED=true but MONITOR_DB_PASSWORD is empty in ${ENV_FILE}. Create the role first: docs/db/scaling/p1-7a-exporters.md"
  fi
  monitoring_exposure_check
  add_compose_profile monitoring
  log "Monitoring exporters ENABLED (postgres-exporter, node-exporter on ${MONITORING_BIND_IP:-127.0.0.1})."
fi

storage_compose_args

log "Pulling storage images..."
"${COMPOSE[@]}" "${COMPOSE_ARGS[@]}" pull

log "Starting storage stack..."
"${COMPOSE[@]}" "${COMPOSE_ARGS[@]}" up -d

wait_for_compose_healthy "postgres" 180
wait_for_compose_healthy "minio" 120

prune_docker_artifacts 0

STORAGE_IP="$(detect_host_ip || true)"
if [[ -z "${STORAGE_IP}" ]]; then
  STORAGE_IP="127.0.0.1"
  warn "Could not detect host IP. Set STORAGE_ADVERTISE_IP in .env.storage to this machine's LAN IP."
fi

ok "Storage deployment complete."
print_storage_banner "${STORAGE_IP}"
