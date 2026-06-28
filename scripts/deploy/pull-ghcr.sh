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
  ENV_ARGS=(--env-file "${ENV_FILE}")
  load_env_file "${ENV_FILE}"
fi

[[ -n "${GHCR_IMAGE_PREFIX:-}" ]] || die "GHCR_IMAGE_PREFIX is not set (e.g. ghcr.io/your-org/falconai)"

export FALCON_DEPLOY_DIR="${FALCON_DEPLOY_DIR:-${ROOT_DIR}}"
bash "${SCRIPT_DIR}/init-client-data.sh"

if ! docker info >/dev/null 2>&1; then
  die "Docker daemon is not reachable."
fi

log "Pulling images from ${GHCR_IMAGE_PREFIX} (tag: ${FALCON_IMAGE_TAG:-latest})..."
# shellcheck disable=SC2086
"${COMPOSE[@]}" "${ENV_ARGS[@]}" ${COMPOSE_FILES} -f "${ROOT_DIR}/docker-compose.ghcr.yml" pull

log "Starting stack (--no-build)..."
# shellcheck disable=SC2086
"${COMPOSE[@]}" "${ENV_ARGS[@]}" ${COMPOSE_FILES} -f "${ROOT_DIR}/docker-compose.ghcr.yml" up -d --no-build --remove-orphans

if docker ps --format '{{.Names}}' | grep -qx "${PRISMA_CONTAINER}"; then
  log "Applying database schema from image (prisma db push)..."
  if docker exec -w "${PRISMA_WORKDIR}" "${PRISMA_CONTAINER}" npx prisma db push --skip-generate; then
    ok "Prisma schema applied."
  else
    warn "prisma db push failed — check logs on ${PRISMA_CONTAINER}."
  fi
else
  warn "Container ${PRISMA_CONTAINER} not running — skipped Prisma step."
fi

ok "GHCR pull deploy complete."
