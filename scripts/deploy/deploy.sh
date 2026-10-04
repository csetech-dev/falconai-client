#!/usr/bin/env bash
# FalconAI split Docker Compose deployment entrypoint.
#
# Usage:
#   ./scripts/deploy/deploy.sh storage
#   ./scripts/deploy/deploy.sh app
#   ./scripts/deploy/deploy.sh app --no-build   # skip image rebuild
#   ./scripts/deploy/deploy.sh status [storage|app]
#   ./scripts/deploy/deploy.sh down [storage|app]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'EOF'
FalconAI split deployment

Commands:
  init-storage     Create .env.storage from template
  init-app         Create .env.app from template
  storage          Deploy Postgres + MinIO (.env.storage)
  app              Deploy application stack (.env.app)
  status [target]  Show compose ps (default: both if env files exist)
  logs [target] [service]  Follow logs (app | storage, optional service name)
  down [target]    Stop stack (storage | app | all)

Options:
  app --no-build   Skip docker compose --build
  ghcr             git pull the bundle checkout, then pull from GHCR and start the app
                   stack (requires .env.app GHCR_* vars)
  ghcr --no-sync   Same, without the git pull (or FALCON_NO_SYNC=1)

Examples:
  make init-storage && $EDITOR .env.storage && make deploy-storage
  make init-app && $EDITOR .env.app && make deploy-app
EOF
}

# GHCR deploys run from the client bundle checkout (/opt/falconai-client, a clone
# of the falconai-client repo). The images come from GHCR, but the deploy scripts,
# compose files, sizing profiles and SQL come from the bundle, so pull it first.
# A stale bundle silently deploys old behaviour (e.g. dropping a perf index).
# Bypass: `make deploy-ghcr-nosync`, `deploy.sh ghcr --no-sync`, or FALCON_NO_SYNC=1.
sync_bundle_checkout() {
  if [[ "${FALCON_NO_SYNC:-0}" == "1" ]]; then
    warn "Bundle sync skipped (no-sync): deploying the bundle as it is on disk."
    return 0
  fi
  if [[ "${FALCON_BUNDLE_SYNCED:-0}" == "1" ]]; then
    return 0
  fi
  require_cmd git
  if [[ ! -e "${ROOT_DIR}/.git" ]]; then
    warn "${ROOT_DIR} is not a git checkout — bundle sync skipped (update the bundle by hand)."
    return 0
  fi

  local before after
  before="$(git -C "${ROOT_DIR}" rev-parse HEAD)" || \
    die "Cannot read git HEAD in ${ROOT_DIR} (owned by another user? run: git config --global --add safe.directory ${ROOT_DIR}). To deploy the bundle as it is: make deploy-ghcr-nosync"
  log "Syncing bundle: git pull --ff-only in ${ROOT_DIR} (bypass: make deploy-ghcr-nosync)..."
  if ! git -C "${ROOT_DIR}" pull --ff-only; then
    die "git pull --ff-only failed in ${ROOT_DIR}. Check: access to the falconai-client repo; the branch tracks origin (git status -sb); local edits to tracked bundle files (git status --short — discard with 'git checkout -- <file>', never .env.*). To deploy the bundle as it is: make deploy-ghcr-nosync"
  fi
  after="$(git -C "${ROOT_DIR}" rev-parse HEAD)"

  if [[ "${before}" == "${after}" ]]; then
    ok "Bundle already up to date (${after:0:9})."
    return 0
  fi
  ok "Bundle updated ${before:0:9} -> ${after:0:9}."
  # This script and common.sh may have changed: re-run the new version once.
  export FALCON_BUNDLE_SYNCED=1
  exec bash "${SCRIPT_DIR}/deploy.sh" "$@"
}

cmd_status() {
  local target="${1:-all}"
  detect_compose

  if [[ "${target}" == "storage" || "${target}" == "all" ]] && [[ -f "${ROOT_DIR}/.env.storage" ]]; then
    log "Storage stack:"
    resolve_sizing_file_quiet "${ROOT_DIR}/.env.storage"
    "${COMPOSE[@]}" --env-file "${SIZING_ENV_FILE}" --env-file "${ROOT_DIR}/.env.storage" -f "${STORAGE_COMPOSE}" ps
  fi

  if [[ "${target}" == "app" || "${target}" == "all" ]] && [[ -f "${ROOT_DIR}/.env.app" ]]; then
    log "Application stack:"
    resolve_sizing_file_quiet "${ROOT_DIR}/.env.app"
    "${COMPOSE[@]}" --env-file "${SIZING_ENV_FILE}" --env-file "${ROOT_DIR}/.env.app" -f "${APP_COMPOSE}" ps
  fi
}

cmd_logs() {
  local target="${1:-app}"
  local service="${2:-}"
  detect_compose

  local env_file compose_file
  case "${target}" in
    storage)
      env_file="${ROOT_DIR}/.env.storage"
      compose_file="${STORAGE_COMPOSE}"
      ;;
    app)
      env_file="${ROOT_DIR}/.env.app"
      compose_file="${APP_COMPOSE}"
      ;;
    *)
      die "Usage: deploy.sh logs [app|storage] [service]"
      ;;
  esac

  [[ -f "${env_file}" ]] || die "Missing ${env_file}. Run init-${target} first."

  resolve_sizing_file_quiet "${env_file}"
  local args=(--env-file "${SIZING_ENV_FILE}" --env-file "${env_file}" -f "${compose_file}" logs -f --tail=100)
  if [[ -n "${service}" ]]; then
    args+=("${service}")
  fi

  "${COMPOSE[@]}" "${args[@]}"
}

cmd_down() {
  local target="${1:-all}"
  detect_compose

  if [[ "${target}" == "app" || "${target}" == "all" ]] && [[ -f "${ROOT_DIR}/.env.app" ]]; then
    log "Stopping application stack..."
    resolve_sizing_file_quiet "${ROOT_DIR}/.env.app"
    local -a app_args=(--env-file "${SIZING_ENV_FILE}" --env-file "${ROOT_DIR}/.env.app" -f "${APP_COMPOSE}")
    set -a
    # shellcheck disable=SC1090
    source "${ROOT_DIR}/.env.app"
    set +a
    if [[ "${FALCON_DEPLOY_MODE:-}" == "ghcr" ]] || [[ -n "${GHCR_IMAGE_PREFIX:-}" ]]; then
      app_args+=(-f "${ROOT_DIR}/docker-compose.ghcr.yml")
    fi
    "${COMPOSE[@]}" "${app_args[@]}" down
  fi

  if [[ "${target}" == "storage" || "${target}" == "all" ]] && [[ -f "${ROOT_DIR}/.env.storage" ]]; then
    log "Stopping storage stack..."
    resolve_sizing_file_quiet "${ROOT_DIR}/.env.storage"
    "${COMPOSE[@]}" --env-file "${SIZING_ENV_FILE}" --env-file "${ROOT_DIR}/.env.storage" -f "${STORAGE_COMPOSE}" down
  fi

  ok "Down complete (${target})."
}

main() {
  local command="${1:-}"
  shift || true

  case "${command}" in
    init-storage)
      init_env_file "${ROOT_DIR}/.env.storage.example" "${ROOT_DIR}/.env.storage" "storage environment"
      ;;
    init-app)
      init_env_file "${ROOT_DIR}/.env.app.example" "${ROOT_DIR}/.env.app" "application environment"
      ;;
    storage)
      bash "${SCRIPT_DIR}/deploy-storage.sh"
      ;;
    app)
      if [[ "${1:-}" == "--no-build" ]]; then
        export BUILD_FLAG=0
      fi
      bash "${SCRIPT_DIR}/deploy-app.sh"
      ;;
    ghcr)
      if [[ "${1:-}" == "--no-sync" ]]; then
        export FALCON_NO_SYNC=1
      fi
      sync_bundle_checkout ghcr "$@"
      export FALCON_DEPLOY_MODE=ghcr
      export BUILD_FLAG=0
      bash "${SCRIPT_DIR}/deploy-app.sh"
      ;;
    status)
      cmd_status "${1:-all}"
      ;;
    logs)
      cmd_logs "${1:-app}" "${2:-}"
      ;;
    down)
      cmd_down "${1:-all}"
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      die "Unknown command: ${command}. Run with --help."
      ;;
  esac
}

main "$@"
