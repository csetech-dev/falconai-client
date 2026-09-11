#!/usr/bin/env bash
#
# Dump the ENTIRE Falcon database to a file on THIS server.
#
# Meant to run from any Ubuntu box that has Docker (e.g. an app/prod node) and
# can reach the Postgres server over the network. The Postgres server lives in a
# container reachable at <DB_HOST>:<DB_PORT>, so this script does NOT need psql /
# pg_dump installed locally — it uses a postgres:18 Docker image (must match the
# storage server major version; see docker-compose.storage.yml pg18).
#
# On launch it ASKS for the database server IP (because that differs per host),
# then dumps falcon_ai into a timestamped file under ./db-backups (override with
# OUT_DIR=...). Everything else (port, user, password, db name) has the known
# defaults baked in and can be overridden by env var.
#
# Usage:
#   ./scripts/dump-db.sh                      # interactive — prompts for DB IP
#   DB_HOST=192.168.180.103 ./scripts/dump-db.sh   # non-interactive (CI/cron)
#   OUT_DIR=/opt/falcon-backups ./scripts/dump-db.sh
#   FORMAT=plain ./scripts/dump-db.sh         # .sql instead of custom .dump
#
# Env overrides (all optional):
#   DB_HOST       Postgres server IP/host   (prompted if unset)
#   DB_PORT       default 12002
#   DB_USER       default postgres
#   DB_PASSWORD   default pass998!
#   DB_NAME       default falcon_ai
#   OUT_DIR       default <repo>/db-backups
#   FORMAT        custom (default, -> .dump, restore w/ pg_restore) | plain (-> .sql)
#   PG_IMAGE      default postgres:18 (must be >= server major version)
#
set -euo pipefail

DB_HOST="${DB_HOST:-}"
DB_PORT="${DB_PORT:-12002}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-pass998!}"
DB_NAME="${DB_NAME:-falcon_ai}"
FORMAT="${FORMAT:-custom}"
PG_IMAGE="${PG_IMAGE:-postgres:18}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/db-backups}"

# Colours (auto-off when not a terminal).
if [ -t 1 ]; then C_BLUE='\033[1;34m'; C_GREEN='\033[1;32m'; C_RED='\033[1;31m'; C_DIM='\033[2m'; C_OFF='\033[0m'
else C_BLUE=''; C_GREEN=''; C_RED=''; C_DIM=''; C_OFF=''; fi
log() { printf "${C_DIM}[%s]${C_OFF} %b\n" "$(date '+%H:%M:%S')" "$1"; }
ok()  { printf "${C_GREEN}    ✓ %b${C_OFF}\n" "$1"; }
err() { printf "${C_RED}    ✗ %b${C_OFF}\n" "$1" >&2; }
human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"; }

# --- Prompt for the DB server IP if not provided ------------------------------
if [ -z "$DB_HOST" ]; then
    if [ ! -t 0 ]; then
        err "DB_HOST is not set and no terminal to prompt on. Pass DB_HOST=<ip> ./scripts/dump-db.sh"
        exit 1
    fi
    printf "${C_BLUE}Enter the database server IP${C_OFF} (e.g. 192.168.180.103): "
    read -r DB_HOST
    DB_HOST="$(printf '%s' "$DB_HOST" | tr -d '[:space:]')"
fi
[ -n "$DB_HOST" ] || { err "No database server IP given."; exit 1; }

command -v docker >/dev/null 2>&1 || { err "docker is required but not found on PATH."; exit 1; }

# --- Resolve output file ------------------------------------------------------
mkdir -p "$OUT_DIR"
STAMP="$(date '+%Y%m%d_%H%M%S')"
case "$FORMAT" in
    custom) DUMP_FLAG="-Fc"; EXT="dump" ;;
    plain)  DUMP_FLAG="-Fp"; EXT="sql"  ;;
    *) err "Unknown FORMAT='$FORMAT' (use 'custom' or 'plain')."; exit 1 ;;
esac
OUT_FILE="${DB_NAME}_${DB_HOST}_${STAMP}.${EXT}"
OUT_PATH="$OUT_DIR/$OUT_FILE"

log "Source DB    : ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
log "Format       : ${FORMAT} (${DUMP_FLAG})"
log "Output file  : ${OUT_PATH}"
log "pg image     : ${PG_IMAGE}"

# --- Reachability check -------------------------------------------------------
log "Checking connectivity to ${DB_HOST}:${DB_PORT} ..."
if ! docker run --rm -e "PGPASSWORD=${DB_PASSWORD}" "$PG_IMAGE" \
        pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t 10 >/dev/null 2>&1; then
    err "Cannot reach Postgres at ${DB_HOST}:${DB_PORT} (check IP, network, and that the DB container is up)."
    exit 1
fi
ok "Postgres is reachable"

# --- Dump ---------------------------------------------------------------------
# The dump is written INSIDE the container to /backup (bind-mounted to OUT_DIR on
# this host), so the file lands directly on this server. --no-owner/--no-acl keep
# the dump portable across restores.
START_TS=$(date +%s)
log "Dumping entire database (this can take a while for large DBs) ..."
if ! docker run --rm \
        -e "PGPASSWORD=${DB_PASSWORD}" \
        -v "$OUT_DIR:/backup" \
        "$PG_IMAGE" \
        pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
            $DUMP_FLAG --no-owner --no-acl --verbose \
            --file "/backup/$OUT_FILE"; then
    err "pg_dump failed — the (possibly partial) file has been left at $OUT_PATH for inspection."
    exit 1
fi

if [ ! -s "$OUT_PATH" ]; then
    err "Dump completed but the output file is empty."
    exit 1
fi

BYTES=$(wc -c < "$OUT_PATH")
ELAPSED=$(( $(date +%s) - START_TS ))
ok "Dump complete: $(human "$BYTES") in ${ELAPSED}s"
printf "\n${C_GREEN}✓ Database dumped to:${C_OFF} %s\n" "$OUT_PATH"

if [ "$FORMAT" = "custom" ]; then
    log "Restore later with:"
    log "  docker run --rm -e PGPASSWORD=<pw> -v \"$OUT_DIR:/backup\" $PG_IMAGE \\"
    log "    pg_restore -h <host> -p <port> -U <user> -d <db> --clean --if-exists \"/backup/$OUT_FILE\""
else
    log "Restore later with:  psql ... -f \"$OUT_PATH\""
fi
