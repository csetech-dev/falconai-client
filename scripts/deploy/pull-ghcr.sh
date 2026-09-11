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
PRISMA_CONTAINER="${PRISMA_CONTAINER:-falcon-core}"
PRISMA_WORKDIR="${PRISMA_WORKDIR:-/app/libs/database}"

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

log "Starting stack (--no-build)..."
# shellcheck disable=SC2086
"${COMPOSE[@]}" "${ENV_ARGS[@]}" ${COMPOSE_FILES} -f "${ROOT_DIR}/docker-compose.ghcr.yml" up -d --no-build --remove-orphans

# Wait for container to be ready before running prisma db push
wait_for_container() {
  local container="$1"
  local max_attempts="${2:-30}"
  local wait_seconds="${3:-2}"
  local attempt=1

  log "Waiting for container ${container} to be ready..."
  while [ $attempt -le $max_attempts ]; do
    if docker exec "$container" echo "ready" >/dev/null 2>&1; then
      log "Container ${container} is ready (attempt ${attempt}/${max_attempts})"
      return 0
    fi
    log "Container ${container} not ready, waiting... (attempt ${attempt}/${max_attempts})"
    sleep "$wait_seconds"
    attempt=$((attempt + 1))
  done

  warn "Container ${container} did not become ready after ${max_attempts} attempts"
  return 1
}

if wait_for_container "${PRISMA_CONTAINER}" 30 2; then
  log "Applying database schema from image (prisma db push --accept-data-loss)..."
  if docker exec -w "${PRISMA_WORKDIR}" "${PRISMA_CONTAINER}" npx prisma db push --skip-generate --accept-data-loss; then
    ok "Prisma schema applied."
  else
    warn "prisma db push failed — check logs on ${PRISMA_CONTAINER}."
  fi
else
  warn "Container ${PRISMA_CONTAINER} not running — skipped Prisma step."
fi

ok "GHCR pull deploy complete."
