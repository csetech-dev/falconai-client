#!/usr/bin/env bash
# Fix lane workers crash: python api.py/app.py on bytecode-only GHCR images.
# Recreates workers with run-py entrypoints (same pattern as worker-fb).
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

# This script force-recreates the four heaviest scraper containers, so it must
# resolve the exact same env layering as deploy-app.sh — otherwise it would
# silently rebuild them at the compose-file (test-sized) defaults.
load_env_file "${ENV_FILE}"
resolve_deploy_env
write_deploy_runtime_env_file "${ENV_FILE}"
USE_GHCR=1
app_compose_args

WORKERS=(worker-fb worker-x worker-linkedin web-worker)

log "Recreating ${WORKERS[*]} with run-py entrypoints..."
"${COMPOSE[@]}" "${COMPOSE_ARGS[@]}" pull "${WORKERS[@]}"
"${COMPOSE[@]}" "${COMPOSE_ARGS[@]}" up -d --no-build --force-recreate "${WORKERS[@]}"

for w in "${WORKERS[@]}"; do
  log "${w} command:"
  docker inspect "${w}" --format '{{json .Config.Cmd}}' 2>/dev/null || true
done

log "worker-linkedin logs:"
docker logs worker-linkedin --tail 15 2>&1 || true

if docker exec worker-linkedin curl -fsS http://localhost:3011/ >/dev/null 2>&1; then
  ok "worker-linkedin health check passed"
else
  warn "worker-linkedin health check failed — run: docker logs worker-linkedin --tail 50"
fi

if docker exec worker-fb curl -fsS http://localhost:3010/health >/dev/null 2>&1; then
  ok "worker-fb health check passed"
else
  warn "worker-fb health check failed — run: docker logs worker-fb --tail 50"
fi
