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

# Assemble compose args early — the tunnel sidecar must start before the preflight.
if [[ "${USE_GHCR}" == "1" ]]; then
  [[ -n "${GHCR_IMAGE_PREFIX:-}" ]] || die "GHCR mode requires GHCR_IMAGE_PREFIX in .env.app"
fi
app_compose_args

if wireguard_enabled; then
  # Storage is reached over the encrypted tunnel. Verify the config exists, then
  # bring up the falcon-wg-app sidecar (which republishes the storage ports on
  # this host, bound to STORAGE_SERVER_IP) BEFORE the preflight — or storage is
  # unreachable. STORAGE_SERVER_IP must be THIS app host's own LAN IP.
  require_wireguard_conf app
  add_compose_profile wireguard
  log "Starting WireGuard tunnel (falcon-wg-app)..."
  "${COMPOSE[@]}" "${COMPOSE_ARGS[@]}" up -d wireguard
  wait_for_wireguard_peer falcon-wg-app 20 || \
    warn "WireGuard handshake not confirmed yet — the preflight below will wait for the tunnel."
  log "Preflight: checking storage connectivity over the tunnel..."
else
  # Tunnel OFF: connect directly to the storage host (plaintext).
  # STORAGE_SERVER_IP must be the STORAGE host's IP in this mode.
  warn "WireGuard tunnel DISABLED (WIREGUARD_ENABLED=false) — connecting to storage in PLAINTEXT."
  warn "STORAGE_SERVER_IP must be the STORAGE host's IP (not this host) when the tunnel is off."
  log "Preflight: checking storage connectivity (direct)..."
fi

wait_for_tcp "${POSTGRES_HOST}" "${POSTGRES_PORT:-5432}" 60
wait_for_http "http://${MINIO_HOST}:${MINIO_PORT}/minio/health/live" 60

export FALCON_DEPLOY_DIR="${FALCON_DEPLOY_DIR:-${ROOT_DIR}}"
bash "${SCRIPT_DIR}/init-client-data.sh"

if [[ "${USE_GHCR}" == "1" ]]; then
  log "GHCR mode: pulling ${GHCR_IMAGE_PREFIX} (tag: ${FALCON_IMAGE_TAG:-latest})..."
  log "FlareSolverr uses public ghcr.io/flaresolverr/flaresolverr (not ${GHCR_IMAGE_PREFIX})."
  "${COMPOSE[@]}" "${COMPOSE_ARGS[@]}" pull

  # Schema preflight BEFORE anything restarts: diff the live database against
  # the schema in the image just pulled. A destructive change (exit 3) stops
  # the deploy here, with the old containers still running untouched. Other
  # failures (e.g. prisma could not connect) only warn: the real sync after
  # `up` reports them again and fails the step.
  PREFLIGHT_RC=0
  bash "${SCRIPT_DIR}/db.sh" push-check || PREFLIGHT_RC=$?
  if [[ "${PREFLIGHT_RC}" == "3" ]]; then
    die "Deploy STOPPED before restarting anything: the new schema has destructive changes (listed above). Review them, then apply deliberately or rerun with an override — docs/performance/PROD_UAT_DEPLOY.md, 'Schema sync stopped'."
  elif [[ "${PREFLIGHT_RC}" != "0" ]]; then
    warn "Schema preflight could not run (exit ${PREFLIGHT_RC}); continuing — the schema sync after start-up will retry."
  fi
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
  "${COMPOSE[@]}" "${COMPOSE_ARGS[@]}" up -d --no-build --remove-orphans --force-recreate "${GHCR_BYTECODE_WORKERS[@]}"
fi

DB_PUSH_FAILED=0
PERF_SCHEMA_FAILED=0
if [[ "${USE_GHCR}" == "1" ]]; then
  # Guarded schema sync (db.sh push -> scripts/deploy/schema-sync.sh): only
  # additive statements, keep-listed live indexes never dropped, destructive
  # changes stop with exit 3 and nothing applied.
  log "Applying Prisma schema (guarded sync, one-off container)..."
  DB_PUSH_RC=0
  bash "${SCRIPT_DIR}/db.sh" push || DB_PUSH_RC=$?
  if [[ "${DB_PUSH_RC}" != "0" ]]; then
    DB_PUSH_FAILED=1
    if [[ "${DB_PUSH_RC}" == "3" ]]; then
      warn "Schema sync STOPPED on destructive changes (listed above) — nothing was applied."
    else
      warn "Schema sync failed — check DATABASE_URL in .env.app and falcon-core logs."
    fi
  fi
  # Idempotent and additive: restores any performance / search-layer index or
  # trigger that is missing. Runs even when the sync stopped. See common.sh.
  reapply_performance_schema || PERF_SCHEMA_FAILED=1
fi

if [[ "${BUILD_FLAG}" == "1" ]]; then
  prune_docker_artifacts 1
fi

if [[ "${USE_GHCR}" == "1" ]]; then
  bash "${SCRIPT_DIR}/verify-scrapers.sh" || \
    warn "Scraper verification failed — run: bash scripts/deploy/verify-scrapers.sh"
fi

# Both failures are reported only now, so the rest of the deploy (prune,
# scraper verification, banner) still runs, but the step exits non-zero —
# the deploy agent / technical panel then shows the deploy as failed.
if [[ "${DB_PUSH_FAILED}" == "1" || "${PERF_SCHEMA_FAILED}" == "1" ]]; then
  print_app_banner
  [[ "${DB_PUSH_FAILED}" == "1" ]] && \
    warn "schema sync FAILED or STOPPED — fix/review (docs/performance/PROD_UAT_DEPLOY.md, 'Schema sync stopped'), then rerun: bash ./scripts/deploy/db.sh push, then ONCE: bash ./scripts/deploy/db.sh perf-schema"
  [[ "${PERF_SCHEMA_FAILED}" == "1" ]] && \
    warn "performance schema re-apply FAILED — fix the INVALID/missing index, then run ONCE: bash ./scripts/deploy/db.sh perf-schema"
  die "Application deployed, but the database step failed (see above)."
fi

ok "Application deployment complete."
print_app_banner
