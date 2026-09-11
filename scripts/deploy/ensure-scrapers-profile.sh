#!/usr/bin/env bash
# Ensure .env.app enables the scrapers Compose profile (required for worker-news, worker-fb, etc.).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env.app"

[[ -f "${ENV_FILE}" ]] || exit 0

if grep -qE '^COMPOSE_PROFILES=.*scrapers' "${ENV_FILE}"; then
  exit 0
fi

printf '[ensure-scrapers-profile] Setting COMPOSE_PROFILES=scrapers in %s\n' "${ENV_FILE}" >&2
if grep -q '^COMPOSE_PROFILES=' "${ENV_FILE}"; then
  sed -i 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=scrapers/' "${ENV_FILE}"
else
  printf '\nCOMPOSE_PROFILES=scrapers\n' >> "${ENV_FILE}"
fi
