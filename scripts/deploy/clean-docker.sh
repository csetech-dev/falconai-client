#!/usr/bin/env bash
# Reclaim disk on app/storage hosts — old images, build cache, stopped containers.
#
# Safe default: removes unused Docker data only (not named volumes / running stacks).
#   ./scripts/deploy/clean-docker.sh
#
# Aggressive (also removes unused volumes — can delete DB/MinIO if stack is down):
#   ./scripts/deploy/clean-docker.sh --aggressive
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

aggressive=0
if [[ "${1:-}" == "--aggressive" ]]; then
  aggressive=1
fi

require_cmd docker

log "Disk before cleanup:"
df -h / /var/lib/docker 2>/dev/null || df -h /

log "Stopping unused containers, networks, dangling images..."
docker container prune -f
docker image prune -f
docker builder prune -af || true

if [[ "${aggressive}" == "1" ]]; then
  warn "Aggressive mode: pruning unused volumes (Postgres/MinIO data if stack is down)."
  docker volume prune -f
  docker system prune -af --volumes
else
  docker system prune -af
fi

log "Disk after cleanup:"
df -h / /var/lib/docker 2>/dev/null || df -h /

ok "Docker cleanup complete."
