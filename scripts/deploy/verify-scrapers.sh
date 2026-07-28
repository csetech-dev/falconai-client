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

if ((${#missing_scrapers[@]} == 0)) && ((${#missing_core[@]} == 0)); then
  ok "All ${#SCRAPER_CONTAINERS[@]} scraper + ${#CORE_WORKER_CONTAINERS[@]} core worker containers are running."
  exit 0
fi

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
