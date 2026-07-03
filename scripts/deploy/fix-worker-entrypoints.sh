#!/usr/bin/env bash
# Fix worker-fb / worker-x crash: python api.py on bytecode-only GHCR images.
# Safe to run on any GHCR client host.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

ENV_FILE="${ROOT_DIR}/.env.app"
[[ -f "${ENV_FILE}" ]] || die "Missing ${ENV_FILE}"

detect_compose
cd "${ROOT_DIR}"

bash "${SCRIPT_DIR}/init-client-data.sh"

COMPOSE_ARGS=(--env-file "${ENV_FILE}" -f "${APP_COMPOSE}" -f "${ROOT_DIR}/docker-compose.ghcr.yml")

log "Recreating worker-fb and worker-x with run-py entrypoints..."
"${COMPOSE[@]}" "${COMPOSE_ARGS[@]}" pull worker-fb worker-x
"${COMPOSE[@]}" "${COMPOSE_ARGS[@]}" up -d --no-build --force-recreate worker-fb worker-x

log "worker-fb command:"
docker inspect worker-fb --format '{{json .Config.Cmd}}' 2>/dev/null || true

log "worker-fb logs:"
docker logs worker-fb --tail 15 2>&1 || true

if docker exec worker-fb curl -fsS http://localhost:3010/health >/dev/null 2>&1; then
  ok "worker-fb health check passed"
else
  warn "worker-fb health check failed — run: docker logs worker-fb --tail 50"
fi
