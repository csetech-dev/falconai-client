#!/usr/bin/env bash
# Prisma / database operations for split or monolithic deploy.
#
# One-off (no running falcon-core):  push | push-loss | generate | seed | migrate | status
# Running falcon-core (classic):     exec push | exec push-loss | exec generate | exec seed | ...
#
# Usage:
#   ./scripts/deploy/db.sh push
#   ./scripts/deploy/db.sh push-loss
#   ./scripts/deploy/db.sh exec push
#   ./scripts/deploy/db.sh copy-schema
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

ENV_FILE="${ROOT_DIR}/.env.app"
DB_DIR="/app/libs/database"
CORE_CONTAINER="${FALCON_CORE_CONTAINER:-falcon-core}"
HOST_SCHEMA="${ROOT_DIR}/libs/database/prisma/schema.prisma"

is_ghcr_deploy() {
  [[ "${FALCON_DEPLOY_MODE:-}" == "ghcr" ]] || [[ -n "${GHCR_IMAGE_PREFIX:-}" ]]
}

has_host_schema() {
  [[ -f "${HOST_SCHEMA}" ]]
}

usage() {
  cat <<'EOF'
Prisma / database commands

One-off container (falcon-core does NOT need to be running; uses .env.app):
  push              prisma db push --skip-generate              (prefer no data loss)
  push-loss         prisma db push --skip-generate --accept-data-loss
  generate          prisma generate
  seed              full seed flow (seed.ts + prompts + news sources + news status filter + news media groups + geo)
  seed-prompts      npm run seed:prompts
  seed-news-prompts npm run seed:news-prompts
  seed-news-sources npm run seed:news-sources
  seed-news-status  npm run seed:news-status-filter
  seed-news-media   npm run seed:news-media-groups
  seed-international-keywords  seed 10 international-news topic keyword categories
  seed-geo          tsx prisma/seed-geo.ts
  seed-videos       demo video intelligence data (1 talk show + 1 general)
  seed-twitter-profiles  Twitter/X profiles via auto-fill (exec only — needs running falcon-core + worker-x)
  seed-telegram-profiles Telegram channels via auto-fill (exec only — needs falcon-core + worker-telegram session)
  migrate           prisma migrate deploy
  status            prisma migrate status
  psql              psql client (args after --)

Running falcon-core container (classic docker exec approach):
  copy-schema       docker cp schema.prisma into running falcon-core
  exec push         docker exec … prisma db push --skip-generate
  exec push-loss    docker exec … prisma db push --skip-generate --accept-data-loss
  exec generate     docker exec … prisma generate
  exec seed         docker exec … full seed flow
  exec seed-prompts docker exec … npm run seed:prompts
  exec migrate      docker exec … prisma migrate deploy
  exec status       docker exec … prisma migrate status
  exec <cmd>        docker exec … sh -lc "<cmd>"  (advanced)

Examples:
  make db-push
  make db-push-loss
  make db-exec-push
  make db-exec-seed-prompts
  ./scripts/deploy/db.sh exec push-loss
  ./scripts/deploy/db.sh psql -- -c "SELECT count(*) FROM users;"
EOF
}

require_running_core() {
  require_cmd docker
  if ! docker ps --format '{{.Names}}' | grep -qx "${CORE_CONTAINER}"; then
    die "${CORE_CONTAINER} is not running. Start it first, or use: ./scripts/deploy/db.sh push"
  fi
}

compose_db_args() {
  [[ -f "${ENV_FILE}" ]] || die "Missing ${ENV_FILE}. Run: make init-app"
  write_deploy_runtime_env_file "${ENV_FILE}"

  resolve_sizing_file_quiet "${ENV_FILE}"
  COMPOSE_DB_ARGS=(--env-file "${SIZING_ENV_FILE}" --env-file "${ENV_FILE}" --env-file "${ROOT_DIR}/.env.app.runtime" -f "${APP_COMPOSE}")
  if [[ "${FALCON_DEPLOY_MODE:-}" == "ghcr" ]] || [[ -n "${GHCR_IMAGE_PREFIX:-}" ]]; then
    COMPOSE_DB_ARGS+=(-f "${ROOT_DIR}/docker-compose.ghcr.yml")
  fi
}

run_in_core() {
  local shell_cmd="$1"
  detect_compose
  compose_db_args

  if is_ghcr_deploy && ! has_host_schema; then
    log "GHCR client bundle: using schema baked into falcon-core image (no host schema.prisma)"
  fi
  log "One-off falcon-core container (DATABASE_URL from .env.app)..."
  "${COMPOSE[@]}" "${COMPOSE_DB_ARGS[@]}" run --rm --no-deps falcon-core \
    sh -lc "${shell_cmd}"
}

run_in_running_core() {
  local shell_cmd="$1"
  require_running_core
  log "docker exec ${CORE_CONTAINER} …"
  docker exec -w "${DB_DIR}" "${CORE_CONTAINER}" sh -lc "${shell_cmd}"
}

copy_schema_to_core() {
  require_running_core
  if ! has_host_schema; then
    if is_ghcr_deploy; then
      warn "No host schema at ${HOST_SCHEMA} — using schema baked into ${CORE_CONTAINER} image"
      return 0
    fi
    die "Schema not found: ${HOST_SCHEMA}"
  fi
  docker cp "${HOST_SCHEMA}" "${CORE_CONTAINER}:${DB_DIR}/prisma/schema.prisma"
  ok "Copied schema → ${CORE_CONTAINER}:${DB_DIR}/prisma/schema.prisma"
}

run_psql() {
  load_env_file "${ENV_FILE}"
  resolve_deploy_env
  [[ -n "${POSTGRES_HOST:-}" ]] || die "POSTGRES_HOST or STORAGE_SERVER_IP not set in .env.app"

  local args=("$@")
  if [[ ${#args[@]} -eq 0 ]]; then
    args=(-c '\dt')
  fi

  require_cmd docker
  log "psql → ${POSTGRES_HOST}:${POSTGRES_PORT:-5432}/falcon_ai"
  docker run --rm -i \
    -e "PGPASSWORD=${POSTGRES_PASSWORD:-postgres}" \
    postgres:18 \
    psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT:-5432}" -U "${POSTGRES_USER:-postgres}" -d falcon_ai \
    "${args[@]}"
}

prisma_push_cmd() {
  local accept_loss="${1:-0}"
  if [[ "${accept_loss}" == "1" ]]; then
    echo "npx prisma db push --skip-generate --accept-data-loss"
  else
    echo "npx prisma db push --skip-generate"
  fi
}

run_db_action() {
  local mode="$1"
  local action="$2"
  local accept_loss="${3:-0}"
  local prisma_cmd shell_cmd

  case "${action}" in
    push)
      prisma_cmd="$(prisma_push_cmd "${accept_loss}")"
      shell_cmd="cd ${DB_DIR} && ${prisma_cmd}"
      ;;
    generate)
      shell_cmd="cd ${DB_DIR} && npx prisma generate"
      ;;
    seed)
      shell_cmd="cd ${DB_DIR} && npm run seed:all"
      ;;
    seed-prompts)
      shell_cmd="cd ${DB_DIR} && npm run seed:prompts"
      ;;
    seed-news-prompts)
      shell_cmd="cd ${DB_DIR} && npm run seed:news-prompts"
      ;;
    seed-news-sources)
      shell_cmd="cd ${DB_DIR} && npm run seed:news-sources"
      ;;
    seed-news-status)
      shell_cmd="cd ${DB_DIR} && npm run seed:news-status-filter"
      ;;
    seed-news-media)
      shell_cmd="cd ${DB_DIR} && npm run seed:news-media-groups"
      ;;
    seed-keyword-categories-type)
      shell_cmd="cd ${DB_DIR} && npm run seed:keyword-categories-type"
      ;;
    seed-international-keywords)
      shell_cmd="cd ${DB_DIR} && node dist/prisma/seed-international-keywords.js"
      ;;
    seed-international-news-source)
      shell_cmd="cd ${DB_DIR} && npm run seed:international-news-source"
      ;;
    seed-geo)
      shell_cmd="cd ${DB_DIR} && node dist/prisma/seed-geo.js"
      ;;
    seed-videos)
      shell_cmd="cd ${DB_DIR} && node dist/prisma/seed-videos-only.js"
      ;;
    seed-twitter-profiles)
      if [[ "${mode}" == "oneoff" ]]; then
        die "seed-twitter-profiles must run in a running falcon-core container (use: db.sh exec seed-twitter-profiles). Requires worker-x authorized."
      fi
      shell_cmd="cd ${DB_DIR} && npm run seed:twitter-profiles"
      ;;
    seed-telegram-profiles)
      if [[ "${mode}" == "oneoff" ]]; then
        die "seed-telegram-profiles must run in a running falcon-core container (use: db.sh exec seed-telegram-profiles). Requires Telegram session authorized in technical panel."
      fi
      shell_cmd="cd ${DB_DIR} && npm run seed:telegram-profiles"
      ;;
    migrate)
      shell_cmd="cd ${DB_DIR} && npx prisma migrate deploy"
      ;;
    status)
      shell_cmd="cd ${DB_DIR} && npx prisma migrate status"
      ;;
    *)
      die "Unknown db action: ${action}"
      ;;
  esac

  if [[ "${mode}" == "oneoff" ]]; then
    run_in_core "${shell_cmd}"
  else
    if [[ "${action}" == "push" || "${action}" == "push-loss" ]]; then
      copy_schema_to_core
    fi
    run_in_running_core "${shell_cmd}"
  fi
}

main() {
  local command="${1:-}"
  shift || true

  case "${command}" in
    push)
      run_db_action oneoff push 0
      ;;
    push-loss)
      warn "push-loss may drop columns/tables — backup first if unsure."
      run_db_action oneoff push 1
      ;;
    generate)
      run_db_action oneoff generate
      ;;
    seed|seed-prompts|seed-news-prompts|seed-news-sources|seed-news-status|seed-news-media|seed-keyword-categories-type|seed-international-keywords|seed-international-news-source|seed-geo|seed-videos)
      run_db_action oneoff "${command}"
      ;;
    seed-twitter-profiles)
      run_db_action exec seed-twitter-profiles
      ;;
    seed-telegram-profiles)
      run_db_action exec seed-telegram-profiles
      ;;
    migrate)
      run_db_action oneoff migrate
      ;;
    status)
      run_db_action oneoff status
      ;;
    copy-schema)
      copy_schema_to_core
      ;;
    exec)
      local sub="${1:-}"
      shift || true
      case "${sub}" in
        push)
          run_db_action exec push 0
          ;;
        push-loss)
          warn "exec push-loss may drop columns/tables — backup first if unsure."
          run_db_action exec push 1
          ;;
        generate|seed|seed-prompts|seed-news-prompts|seed-news-sources|seed-news-status|seed-news-media|seed-keyword-categories-type|seed-international-keywords|seed-geo|seed-videos|seed-twitter-profiles|seed-telegram-profiles|migrate|status)
          run_db_action exec "${sub}"
          ;;
        "")
          die "Usage: db.sh exec <push|push-loss|generate|seed|seed-prompts|seed-news-sources|seed-news-status|seed-news-media|seed-international-keywords|seed-geo|seed-videos|seed-twitter-profiles|seed-telegram-profiles|migrate|status|...>"
          ;;
        *)
          run_in_running_core "$*"
          ;;
      esac
      ;;
    psql)
      if [[ "${1:-}" == "--" ]]; then
        shift
      fi
      run_psql "$@"
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
