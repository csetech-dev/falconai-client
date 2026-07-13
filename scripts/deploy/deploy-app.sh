#!/usr/bin/env bash
# Deploy the application stack (connects to storage per .env.app).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

ENV_FILE="${ROOT_DIR}/.env.app"
ENV_EXAMPLE="${ROOT_DIR}/.env.app.example"
BUILD_FLAG="${BUILD_FLAG:-1}"

# GHCR bytecode Python workers — recreate after deploy so run-py entrypoints apply.
readonly GHCR_BYTECODE_WORKERS=(
  worker-fb
  worker-x
  worker-linkedin
  web-worker
  internal-ai
)

require_cmd docker
require_cmd curl
detect_compose

cd "${ROOT_DIR}"
ensure_env_file "${ENV_EXAMPLE}" "${ENV_FILE}" "application environment" "make init-app"

USE_GHCR=0
if [[ "${FALCON_DEPLOY_MODE:-}" == "ghcr" ]] || [[ -n "${GHCR_IMAGE_PREFIX:-}" ]]; then
  USE_GHCR=1
fi

if [[ "${USE_GHCR}" == "1" ]]; then
  bash "${SCRIPT_DIR}/ensure-scrapers-profile.sh"
fi

load_env_file "${ENV_FILE}"
resolve_deploy_env
write_deploy_runtime_env_file "${ENV_FILE}"

if [[ -z "${COMPOSE_PROFILES:-}" ]] || [[ "${COMPOSE_PROFILES}" != *scrapers* ]]; then
  warn "COMPOSE_PROFILES does not include 'scrapers' — worker-news, worker-fb, worker-linkedin, etc. will NOT start."
  warn "Run: bash scripts/deploy/ensure-scrapers-profile.sh && make deploy-ghcr"
fi

[[ -n "${POSTGRES_HOST:-}" ]] || die "POSTGRES_HOST or STORAGE_SERVER_IP must be set in .env.app"
[[ -n "${MINIO_ENDPOINT:-}" ]] || die "MINIO_ENDPOINT or STORAGE_SERVER_IP must be set in .env.app"
[[ -n "${PUBLIC_GATEWAY_URL:-}" ]] || die "PUBLIC_GATEWAY_URL or APP_HOST must be set in .env.app"

warn_if_default_secret "POSTGRES_PASSWORD" "${POSTGRES_PASSWORD:-}"
warn_if_default_secret "MINIO_SECRET_KEY" "${MINIO_SECRET_KEY:-}"

warn_opensearch_host_prereqs

MINIO_HOST="${MINIO_ENDPOINT%%:*}"
MINIO_PORT="${MINIO_ENDPOINT##*:}"
[[ "${MINIO_HOST}" != "${MINIO_PORT}" ]] || die "MINIO_ENDPOINT must be host:port (got: ${MINIO_ENDPOINT})"

# Storage is reached over the encrypted WireGuard tunnel (falcon-wg-app sidecar).
# Verify the tunnel config exists before the preflight, so a missing setup fails
# with clear guidance instead of a 60s connectivity timeout.
require_wireguard_conf app

log "Preflight: checking remote storage connectivity..."
wait_for_tcp "${POSTGRES_HOST}" "${POSTGRES_PORT:-5432}" 60
wait_for_http "http://${MINIO_HOST}:${MINIO_PORT}/minio/health/live" 60

if [[ "${USE_GHCR}" == "1" ]]; then
  [[ -n "${GHCR_IMAGE_PREFIX:-}" ]] || die "GHCR mode requires GHCR_IMAGE_PREFIX in .env.app"
fi

COMPOSE_ARGS=(--env-file "${ENV_FILE}" --env-file "${ROOT_DIR}/.env.app.runtime" -f "${APP_COMPOSE}")
if [[ "${USE_GHCR}" == "1" ]]; then
  COMPOSE_ARGS+=(-f "${ROOT_DIR}/docker-compose.ghcr.yml")
fi

export FALCON_DEPLOY_DIR="${FALCON_DEPLOY_DIR:-${ROOT_DIR}}"
bash "${SCRIPT_DIR}/init-client-data.sh"

if [[ "${USE_GHCR}" == "1" ]]; then
  log "GHCR mode: pulling ${GHCR_IMAGE_PREFIX} (tag: ${FALCON_IMAGE_TAG:-latest})..."
  "${COMPOSE[@]}" "${COMPOSE_ARGS[@]}" pull
fi

UP_ARGS=("${COMPOSE_ARGS[@]}" up -d)
if [[ "${USE_GHCR}" == "1" ]]; then
  UP_ARGS+=(--no-build --remove-orphans)
elif [[ "${BUILD_FLAG}" == "1" ]]; then
  UP_ARGS+=(--build)
fi

log "Starting application stack (COMPOSE_PROFILES=${COMPOSE_PROFILES:-<none>})..."
"${COMPOSE[@]}" "${UP_ARGS[@]}"

if [[ "${USE_GHCR}" == "1" ]]; then
  log "Recreating bytecode Python workers (run-py entrypoints)..."
  "${COMPOSE[@]}" "${COMPOSE_ARGS[@]}" up -d --no-build --force-recreate "${GHCR_BYTECODE_WORKERS[@]}"
fi

if [[ "${USE_GHCR}" == "1" ]]; then
  log "Applying Prisma schema (one-off container)..."
  bash "${SCRIPT_DIR}/db.sh" push || \
    warn "prisma db push failed — check DATABASE_URL in .env.app and falcon-core logs."
fi

if [[ "${BUILD_FLAG}" == "1" ]]; then
  prune_docker_artifacts 1
fi

if [[ "${USE_GHCR}" == "1" ]]; then
  bash "${SCRIPT_DIR}/verify-scrapers.sh" || \
    warn "Scraper verification failed — run: bash scripts/deploy/verify-scrapers.sh"
fi

ok "Application deployment complete."
print_app_banner
