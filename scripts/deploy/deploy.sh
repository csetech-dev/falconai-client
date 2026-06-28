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
  ghcr             Pull from GHCR and start app stack (requires .env.app GHCR_* vars)

Examples:
  make init-storage && $EDITOR .env.storage && make deploy-storage
  make init-app && $EDITOR .env.app && make deploy-app
EOF
}

cmd_status() {
  local target="${1:-all}"
  detect_compose

  if [[ "${target}" == "storage" || "${target}" == "all" ]] && [[ -f "${ROOT_DIR}/.env.storage" ]]; then
    log "Storage stack:"
    "${COMPOSE[@]}" --env-file "${ROOT_DIR}/.env.storage" -f "${STORAGE_COMPOSE}" ps
  fi

  if [[ "${target}" == "app" || "${target}" == "all" ]] && [[ -f "${ROOT_DIR}/.env.app" ]]; then
    log "Application stack:"
    "${COMPOSE[@]}" --env-file "${ROOT_DIR}/.env.app" -f "${APP_COMPOSE}" ps
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

  local args=(--env-file "${env_file}" -f "${compose_file}" logs -f --tail=100)
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
    "${COMPOSE[@]}" --env-file "${ROOT_DIR}/.env.app" -f "${APP_COMPOSE}" down
  fi

  if [[ "${target}" == "storage" || "${target}" == "all" ]] && [[ -f "${ROOT_DIR}/.env.storage" ]]; then
    log "Stopping storage stack..."
    "${COMPOSE[@]}" --env-file "${ROOT_DIR}/.env.storage" -f "${STORAGE_COMPOSE}" down
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
