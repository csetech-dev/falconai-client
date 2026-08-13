#!/usr/bin/env bash
# Idempotent backfill: news_articles.origin from keyword_categories.type / campaign.notes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

SQL_FILE="${ROOT_DIR}/libs/database/prisma/sql/backfill-news-article-origin.sql"

if [[ ! -f "${SQL_FILE}" ]]; then
  warn "Missing ${SQL_FILE} — skipped news origin backfill"
  exit 0
fi

log "Backfilling news_articles.origin from legacy keyword category types..."
bash "${SCRIPT_DIR}/db.sh" psql -- -f - < "${SQL_FILE}"
ok "News origin backfill complete."
