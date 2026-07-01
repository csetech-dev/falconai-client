#!/usr/bin/env bash
# Create host paths required by docker-compose.app.yml on GHCR clients (no full repo).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

log() { printf '[init-client-data] %s\n' "$*"; }
warn() { printf '[init-client-data] ! %s\n' "$*" >&2; }

# GHCR Python images ship .pyc only; older client bundles still start `python api.py`.
patch_compose_python_entrypoints() {
  local compose="${ROOT_DIR}/docker-compose.app.yml"
  [[ -f "${compose}" ]] || return 0
  if grep -qE 'python (api|app)\.py' "${compose}"; then
    warn "Patching ${compose}: python *.py -> run-py (bytecode-only GHCR images)"
    sed -i 's/python api\.py/run-py api/g; s/python app\.py/run-py app/g' "${compose}"
    log "Compose entrypoints updated for worker-fb / worker-x"
  fi
}

ensure_file() {
  local path="$1"
  if [[ -d "${path}" ]]; then
    warn "Removing directory that should be a file: ${path}"
    rm -rf "${path}"
  fi
  if [[ ! -f "${path}" ]]; then
    mkdir -p "$(dirname "${path}")"
    : > "${path}"
    log "Created empty file: ${path}"
  fi
}

ensure_dir() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    warn "Removing file that should be a directory: ${path}"
    rm -f "${path}"
  fi
  mkdir -p "${path}"
}

NGINX_CONF="${ROOT_DIR}/infra/nginx/scraper-viewer-proxy.conf"
if [[ -d "${NGINX_CONF}" ]]; then
  warn "Removing mistaken directory: ${NGINX_CONF}"
  rm -rf "${NGINX_CONF}"
fi
if [[ ! -f "${NGINX_CONF}" ]]; then
  echo "Missing ${NGINX_CONF}. Copy infra/nginx/scraper-viewer-proxy.conf from the vendor repo or re-pack the client bundle." >&2
  exit 1
fi

mkdir -p "${ROOT_DIR}/.deploy"

ensure_file "${ROOT_DIR}/apps/scrapers/worker-fb/cookies.json"
ensure_dir  "${ROOT_DIR}/apps/scrapers/worker-fb/facebook_vnc_profile"
ensure_dir  "${ROOT_DIR}/apps/scrapers/worker-fb/lanes"
ensure_file "${ROOT_DIR}/apps/scrapers/worker-linkedin/cookies.json"
ensure_dir  "${ROOT_DIR}/apps/scrapers/worker-linkedin/linkedin_chrome_profile"
ensure_dir  "${ROOT_DIR}/apps/scrapers/worker-news/outputs"
ensure_dir  "${ROOT_DIR}/apps/scrapers/worker-x/x_chrome_profile"
ensure_file "${ROOT_DIR}/apps/scrapers/worker-video/cookies.txt"
ensure_dir  "${ROOT_DIR}/apps/web-worker/.chrome-profile"
ensure_dir  "${ROOT_DIR}/apps/web-worker/outputs"
ensure_dir  "${ROOT_DIR}/apps/scrapers/worker-image/image_chrome_profile"
ensure_dir  "${ROOT_DIR}/apps/internal-ai/internal-ai-profile"

patch_compose_python_entrypoints

log "Client data paths ready under ${ROOT_DIR}"
