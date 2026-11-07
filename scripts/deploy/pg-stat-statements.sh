#!/usr/bin/env bash
# Turn PostgreSQL's pg_stat_statements on/off on THIS storage server (scaling plan P0.1).
# It records every query's calls, time and rows read, so slow and heavy queries can be named.
#
#   sudo bash scripts/deploy/pg-stat-statements.sh status
#   sudo bash scripts/deploy/pg-stat-statements.sh enable --dry-run
#   sudo bash scripts/deploy/pg-stat-statements.sh enable          # ONE Postgres restart (~10-30 s downtime)
#   sudo bash scripts/deploy/pg-stat-statements.sh disable         # one restart
#
# Uses ALTER SYSTEM (stored in this server's postgresql.auto.conf), NOT docker-compose.storage.yml:
# the bundle is shared by stage and prod, and changing the postgres service would restart prod's
# database on its next routine deploy. Nothing changes on a server until this script runs there.
# Exit codes: 0 done · 2 refused before any change · 4 restart or verify failed (recovery steps printed)
# Runbook: docs/db/scaling/p0-1-pg-stat-statements.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=monitoring-setup-lib.sh
source "${SCRIPT_DIR}/monitoring-setup-lib.sh"

ACTION="${1:-}"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MSL_DRY_RUN=1; shift ;;
    --yes) MSL_ASSUME_YES=1; shift ;;
    *) msl_fail "$MSL_EXIT_PREFLIGHT" "unknown argument: $1" ;;
  esac
done
[[ "$ACTION" =~ ^(status|enable|disable)$ ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "usage: $0 status|enable|disable [--dry-run] [--yes]"

msl_require_root
[[ -n "$(docker ps --filter name='^falcon-postgres$' --format '{{.Names}}' 2>/dev/null)" ]] || \
  msl_fail "$MSL_EXIT_PREFLIGHT" "falcon-postgres is not running here; run this on the STORAGE server"

ENV_FILE="${ROOT_DIR}/.env.storage"
PG_USER="$(msl_get_env_key "$ENV_FILE" POSTGRES_USER)"; PG_USER="${PG_USER:-postgres}"
PG_DB="$(msl_get_env_key "$ENV_FILE" POSTGRES_DB)"; PG_DB="${PG_DB:-falcon_ai}"
sql() { docker exec falcon-postgres psql -U "$PG_USER" -d "$PG_DB" -XtAc "$1"; }
q() { sql "$1" || msl_fail "$MSL_EXIT_PREFLIGHT" "cannot query PostgreSQL as ${PG_USER} on ${PG_DB}; nothing changed"; }

# Trim spaces around commas only (a quoted entry could hold spaces).
current="$(q "SHOW shared_preload_libraries")"
current="$(sed 's/[[:space:]]*,[[:space:]]*/,/g; s/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$current")"
ext="$(q "SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_statements'")"; ext="${ext// /}"
datadir="$(q "SHOW data_directory")"; datadir="${datadir// /}"
preloaded=0; [[ ",${current}," == *",pg_stat_statements,"* ]] && preloaded=1

if [[ "$ACTION" == status ]]; then
  if [[ "$preloaded" -eq 1 && -n "$ext" ]]; then echo "pg_stat_statements: on (extension ${ext})"
  elif [[ "$preloaded" -eq 1 ]]; then echo "pg_stat_statements: loaded, extension not created (run enable)"
  else echo "pg_stat_statements: off"; fi
  echo "shared_preload_libraries: ${current:-<empty>}"
  exit 0
fi

# Checks before any change that needs a restart.
preflight_restart() {
  [[ "$current" =~ ^[A-Za-z0-9_.,/\$-]*$ ]] || msl_fail "$MSL_EXIT_PREFLIGHT" \
    "shared_preload_libraries is '${current}', which this script won't rewrite; change it by hand. Nothing changed"
  local src; src="$(q "SELECT source FROM pg_settings WHERE name = 'shared_preload_libraries'")"
  [[ "$src" == default || "$src" == "configuration file" ]] || msl_fail "$MSL_EXIT_PREFLIGHT" \
    "shared_preload_libraries is set from the ${src} (e.g. -c in docker-compose), so ALTER SYSTEM would be ignored. Nothing changed"
  local errs; errs="$(q "SELECT name || ': ' || error FROM pg_file_settings WHERE error IS NOT NULL")"
  [[ -z "$errs" ]] || msl_fail "$MSL_EXIT_PREFLIGHT" \
    "the config files already have errors, so a restart could fail; fix these first: ${errs}. Nothing changed"
}

wait_ready() {
  for _ in $(seq 1 60); do
    docker exec falcon-postgres pg_isready -U "$PG_USER" -q > /dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
recovery_help() {
  local image; image="$(docker inspect -f '{{.Config.Image}}' falcon-postgres 2>/dev/null || true)"
  image="${image:-pgvector/pgvector:0.8.1-pg18}"
  cat >&2 <<EOF
ERROR: PostgreSQL did not come back after the restart.
1. First look at the log:  docker logs --tail 30 falcon-postgres
   If it says "database system was interrupted" or "redo in progress", it is recovering normally: WAIT, and check again
   with  docker exec falcon-postgres pg_isready  . Change nothing while it recovers.
2. Only if the log shows it failing to start: remove the shared_preload_libraries line this script added, then start it:
  docker run --rm --volumes-from falcon-postgres --entrypoint sed ${image} \\
    -i '/^shared_preload_libraries/d' ${datadir}/postgresql.auto.conf
  docker start falcon-postgres
   The value before this script ran was: '${current}' (empty means default). If it was not empty, set it back afterwards:
  docker exec falcon-postgres psql -U ${PG_USER} -d ${PG_DB} -c "ALTER SYSTEM SET shared_preload_libraries = '${current}'"
   and restart once more.
EOF
}
restart_postgres() {
  # A checkpoint now keeps the shutdown checkpoint short; -t 120 stops Docker killing a slow clean shutdown.
  sql "CHECKPOINT" > /dev/null || true
  echo "Restarting falcon-postgres..."
  docker restart -t 120 falcon-postgres > /dev/null || { recovery_help; exit "$MSL_EXIT_VERIFY"; }
  wait_ready || { recovery_help; exit "$MSL_EXIT_VERIFY"; }
  echo "✅ PostgreSQL is back"
}
CONFIRM_RESTART="This restarts PostgreSQL now (usually 10-30 seconds of downtime; every app connection drops and reconnects). Continue?"

if [[ "$ACTION" == enable ]]; then
  if [[ "$preloaded" -eq 1 && -n "$ext" ]]; then echo "pg_stat_statements is already on (extension ${ext}). Nothing to do."; exit 0; fi
  docker exec falcon-postgres sh -c 'test -f "$(pg_config --pkglibdir)/pg_stat_statements.so"' > /dev/null 2>&1 || \
    msl_fail "$MSL_EXIT_PREFLIGHT" "pg_stat_statements.so is not in this Postgres image; nothing changed"
  if [[ "$preloaded" -eq 1 ]]; then
    plan="create the extension (no restart needed)"
  else
    preflight_restart
    sql "LOAD 'pg_stat_statements'" > /dev/null 2>&1 || \
      msl_fail "$MSL_EXIT_PREFLIGHT" "the pg_stat_statements library does not load in this Postgres; nothing changed"
    new="${current:+${current},}pg_stat_statements"
    plan="set shared_preload_libraries = '${new}', restart PostgreSQL once (~10-30 s downtime), create the extension"
  fi
  echo "Plan: ${plan}"
  [[ "$MSL_DRY_RUN" -eq 1 ]] && { echo "Dry run: nothing changed."; exit 0; }
  if [[ "$preloaded" -eq 0 ]]; then
    msl_confirm "$CONFIRM_RESTART"   # before ALTER SYSTEM: "no" must leave nothing waiting for a later restart
    q "ALTER SYSTEM SET shared_preload_libraries = '${new}'" > /dev/null
    restart_postgres
  fi
  sql "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" > /dev/null || \
    { echo "ERROR: CREATE EXTENSION pg_stat_statements failed (see above)" >&2; exit "$MSL_EXIT_VERIFY"; }
  n="$(sql "SELECT count(*) FROM pg_stat_statements" 2>/dev/null)" || n=""; n="${n// /}"
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "ERROR: pg_stat_statements is not answering after the restart" >&2; exit "$MSL_EXIT_VERIFY"; }
  echo "✅ pg_stat_statements is on (${n} statements recorded so far)"
  echo "Report after a day of normal traffic: docker exec -i falcon-postgres psql -U ${PG_USER} -d ${PG_DB} < scripts/performance/top-queries.sql"
  exit 0
fi

# disable
if [[ "$preloaded" -eq 0 ]]; then echo "pg_stat_statements is already off. Nothing to do."; exit 0; fi
preflight_restart
rest="$(tr ',' '\n' <<<"$current" | grep -vx 'pg_stat_statements' | paste -sd, - || true)"
echo "Plan: drop the extension, set shared_preload_libraries = '${rest}', restart PostgreSQL once (~10-30 s downtime)"
[[ "$MSL_DRY_RUN" -eq 1 ]] && { echo "Dry run: nothing changed."; exit 0; }
msl_confirm "$CONFIRM_RESTART"   # before DROP / ALTER SYSTEM
q "DROP EXTENSION IF EXISTS pg_stat_statements" > /dev/null
if [[ -z "$rest" ]]; then q "ALTER SYSTEM RESET shared_preload_libraries" > /dev/null
else q "ALTER SYSTEM SET shared_preload_libraries = '${rest}'" > /dev/null; fi
restart_postgres
echo "✅ pg_stat_statements is off"
