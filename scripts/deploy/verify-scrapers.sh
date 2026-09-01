#!/usr/bin/env bash
# Report scraper containers expected vs running (GHCR / split deploy).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

SCRAPER_CONTAINERS=(
  scraper-viewer-proxy
  worker-bot-detection
  worker-fb
  worker-linkedin
  worker-news
  worker-x
  worker-telegram
  worker-video
  worker-image
  flaresolverr
)

CORE_WORKER_CONTAINERS=(
  internal-ai
  web-worker
)

missing_scrapers=()
missing_core=()

for name in "${SCRAPER_CONTAINERS[@]}"; do
  if ! docker ps --format '{{.Names}}' | grep -qx "${name}"; then
    missing_scrapers+=("${name}")
  fi
done

for name in "${CORE_WORKER_CONTAINERS[@]}"; do
  if ! docker ps --format '{{.Names}}' | grep -qx "${name}"; then
    missing_core+=("${name}")
  fi
done

# worker-news is "running" long before it can actually scrape: its healthcheck
# is liveness-only (gunicorn on 3012), so a dead Xvfb or an unbound CDP port
# leaves the container green while every VNC/VPN-gated scrape fails. /auth/readyz
# is the endpoint that knows the difference — report it, but don't fail the
# deploy on it: Chrome is launched asynchronously at boot and may still be
# coming up when this runs.
check_worker_news_ready() {
  docker ps --format '{{.Names}}' | grep -qx worker-news || return 0
  local body
  if body="$(docker exec worker-news curl -fsS --max-time 5 \
      http://localhost:3012/auth/readyz 2>/dev/null)"; then
    ok "worker-news VNC/CDP ready."
  else
    warn "worker-news is running but its VNC scrape path is NOT ready."
    [[ -n "${body:-}" ]] && printf '  %s\n' "${body}"
    warn "Check: docker exec worker-news curl -s localhost:3012/auth/readyz"
    warn "Fix:   curl -XPOST localhost:12080/auth/recovery/restart-browser"
  fi
}

if ((${#missing_scrapers[@]} == 0)) && ((${#missing_core[@]} == 0)); then
  ok "All ${#SCRAPER_CONTAINERS[@]} scraper + ${#CORE_WORKER_CONTAINERS[@]} core worker containers are running."
  check_worker_news_ready
  exit 0
fi

check_worker_news_ready

if ((${#missing_scrapers[@]} > 0)); then
  warn "Scraper profile containers NOT running (${#missing_scrapers[@]}):"
  printf '  - %s\n' "${missing_scrapers[@]}"
  warn "Fix: set COMPOSE_PROFILES=scrapers in .env.app, then: make deploy-ghcr"
fi

if ((${#missing_core[@]} > 0)); then
  warn "Core worker containers NOT running (${#missing_core[@]}):"
  printf '  - %s\n' "${missing_core[@]}"
  warn "Fix: make deploy-ghcr (these are not behind the scrapers profile)"
fi

exit 1
