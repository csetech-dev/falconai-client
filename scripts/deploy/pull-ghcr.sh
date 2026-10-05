#!/usr/bin/env bash
# Pull pre-built images from GHCR and restart the stack (no git, no build).
#
# Required env (via .env.app or export):
#   GHCR_IMAGE_PREFIX=ghcr.io/<org>/falconai
# Optional:
#   FALCON_IMAGE_TAG=latest
#   COMPOSE_FILES="-f docker-compose.app.yml"   # default: app split stack
#
# Example:
#   export GHCR_IMAGE_PREFIX=ghcr.io/myorg/falconai
#   ./scripts/deploy/pull-ghcr.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

ENV_FILE="${ROOT_DIR}/.env.app"
COMPOSE_FILES="${COMPOSE_FILES:--f ${APP_COMPOSE}}"

require_cmd docker
detect_compose
cd "${ROOT_DIR}"

ENV_ARGS=()
if [[ -f "${ENV_FILE}" ]]; then
  write_deploy_runtime_env_file "${ENV_FILE}"
  load_env_file "${ENV_FILE}"
  resolve_deploy_env
  # Sizing profile first so .env.app can override any single knob.
  resolve_sizing_file
  ENV_ARGS=(--env-file "${SIZING_ENV_FILE}" --env-file "${ENV_FILE}" --env-file "${ROOT_DIR}/.env.app.runtime")
fi

[[ -n "${GHCR_IMAGE_PREFIX:-}" ]] || die "GHCR_IMAGE_PREFIX is not set (e.g. ghcr.io/your-org/falconai)"

export FALCON_DEPLOY_DIR="${FALCON_DEPLOY_DIR:-${ROOT_DIR}}"
bash "${SCRIPT_DIR}/init-client-data.sh"

if ! docker info >/dev/null 2>&1; then
  die "Docker daemon is not reachable."
fi

log "Pulling images from ${GHCR_IMAGE_PREFIX} (tag: ${FALCON_IMAGE_TAG:-latest})..."
log "(FlareSolverr stays on public ghcr.io/flaresolverr/flaresolverr — not remapped to Falcon prefix)"
# shellcheck disable=SC2086
"${COMPOSE[@]}" "${ENV_ARGS[@]}" ${COMPOSE_FILES} -f "${ROOT_DIR}/docker-compose.ghcr.yml" pull

# Schema preflight BEFORE anything restarts (same as deploy-app.sh): a
# destructive change in the pulled image's schema stops here, old containers
# untouched. The guarded sync needs .env.app (POSTGRES_* for psql).
if [[ -f "${ENV_FILE}" ]]; then
  PREFLIGHT_RC=0
  bash "${SCRIPT_DIR}/db.sh" push-check || PREFLIGHT_RC=$?
  if [[ "${PREFLIGHT_RC}" == "3" ]]; then
    die "Deploy STOPPED before restarting anything: the new schema has destructive changes (listed above). Review them, then apply deliberately or rerun with an override — docs/performance/PROD_UAT_DEPLOY.md, 'Schema sync stopped'."
  elif [[ "${PREFLIGHT_RC}" != "0" ]]; then
    warn "Schema preflight could not run (exit ${PREFLIGHT_RC}); continuing — the schema sync after start-up will retry."
  fi
fi

log "Starting stack (--no-build)..."
# shellcheck disable=SC2086
"${COMPOSE[@]}" "${ENV_ARGS[@]}" ${COMPOSE_FILES} -f "${ROOT_DIR}/docker-compose.ghcr.yml" up -d --no-build --remove-orphans

# Guarded schema sync from the image's schema (one-off falcon-core, same
# schema the old `docker exec … db push --accept-data-loss` used, but never
# with --accept-data-loss): additive statements only, keep-listed live indexes
# never dropped, destructive changes stop with exit 3 and nothing applied.
SCHEMA_RC=0
if [[ -f "${ENV_FILE}" ]]; then
  log "Applying database schema from image (guarded sync: bash ./scripts/deploy/db.sh push)..."
  bash "${SCRIPT_DIR}/db.sh" push || SCHEMA_RC=$?
  if [[ "${SCHEMA_RC}" == "0" ]]; then
    ok "Prisma schema applied."
  elif [[ "${SCHEMA_RC}" == "3" ]]; then
    warn "Schema sync STOPPED on destructive changes (listed above) — nothing was applied."
  else
    warn "Schema sync failed (exit ${SCHEMA_RC}) — check DATABASE_URL in .env.app and falcon-core logs."
  fi
else
  warn "No ${ENV_FILE} — skipped the schema sync (it needs POSTGRES_* for psql). Create .env.app, then run: bash ./scripts/deploy/db.sh push"
fi

# Restore any missing performance / search-layer index or trigger, serially.
# Runs even when the sync was skipped, failed or stopped: it is idempotent
# and only adds what is missing.
# db.sh perf-schema reads POSTGRES_* from .env.app.
if [[ -f "${ENV_FILE}" ]]; then
  if ! reapply_performance_schema; then
    die "GHCR pull deploy finished BUT the performance schema re-apply failed (see the ERROR above). Fix the INVALID/missing index, then run ONCE: bash ./scripts/deploy/db.sh perf-schema"
  fi
else
  warn "No ${ENV_FILE} — skipped performance schema re-apply. Run: bash ./scripts/deploy/db.sh perf-schema"
fi

if [[ "${SCHEMA_RC}" == "3" ]]; then
  die "GHCR pull deploy finished BUT the schema sync STOPPED on destructive changes (see above; saved to .deploy/schema-sync-blocked.sql). Review, then apply deliberately or rerun with an override: docs/performance/PROD_UAT_DEPLOY.md, 'Schema sync stopped'."
elif [[ "${SCHEMA_RC}" != "0" ]]; then
  die "GHCR pull deploy finished BUT the schema sync failed (see above). Fix it, then run: bash ./scripts/deploy/db.sh push"
fi

ok "GHCR pull deploy complete."
