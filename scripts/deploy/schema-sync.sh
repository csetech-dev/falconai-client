#!/usr/bin/env bash
# Guarded schema sync — the replacement for a raw `prisma db push`.
#
# Sourced by scripts/deploy/db.sh (needs common.sh's log/ok/warn and ROOT_DIR).
# Never run directly; use:
#   bash ./scripts/deploy/db.sh push          # diff, classify, apply what is safe
#   bash ./scripts/deploy/db.sh push-check    # diff + classify only (deploy preflight)
#   bash ./scripts/deploy/db.sh exec push     # same, in the running falcon-core
#
# Why: `prisma db push` makes the database match schema.prisma, and DROPS every
# index Prisma can read but the schema cannot declare (hnsw, DESC NULLS LAST,
# GIN on Unsupported("tsvector") columns ...). On prod that is the whole live
# search layer. With --accept-data-loss it also drops columns and tables.
#
# What it does:
#   1. `prisma migrate diff --from-schema-datasource S --to-schema-datamodel S
#      --script` inside falcon-core (same container, workdir and schema as the
#      old push) prints the SQL a push would run, without running it.
#   2. scripts/deploy/schema-sync-classify.awk sorts it (allow-list):
#        additive (CREATE TABLE/INDEX/TYPE/EXTENSION, ADD COLUMN/CONSTRAINT,
#        ALTER COLUMN DROP NOT NULL / SET DEFAULT, ALTER TYPE ADD VALUE) -> apply
#        DROP INDEX of names on scripts/performance/live-only-indexes.txt -> skip
#        anything else (DROP COLUMN/TABLE/TYPE/CONSTRAINT, other DROP INDEX,
#        ALTER COLUMN TYPE / SET NOT NULL, RENAME ...) -> STOP (exit 3)
#   3. A STOP applies NOTHING. It prints the statements, saves them to
#      .deploy/schema-sync-blocked.sql and explains the ways forward.
#   4. Otherwise: ALTER TYPE ... ADD VALUE first (autocommit; a new enum value
#      cannot be used in the transaction that adds it), then every other
#      statement in ONE psql transaction (--single-transaction, ON_ERROR_STOP):
#      all or nothing.
#
# Locks: Prisma's CREATE INDEX is NOT concurrent. It takes a SHARE lock (reads
# continue, writes to that table wait) for the whole build, and inside the one
# transaction every lock is held until COMMIT — an ADD COLUMN's ACCESS
# EXCLUSIVE lock included (that one blocks reads too). For a new index on a
# big table, build it by hand first with the same name
# (CREATE INDEX CONCURRENTLY "<name>" ...); the diff then no longer contains
# it. Each statement waits at most FALCON_SCHEMA_LOCK_TIMEOUT (default 30s)
# for its lock, so a long-running query cannot queue the whole app behind the
# DDL; a timeout rolls everything back and fails the step — rerun it.
#
# Overrides (one run, logged to .deploy/schema-sync.log):
#   FALCON_ALLOW_DESTRUCTIVE_SCHEMA=1        apply the blocked statements too, in
#                                            diff order (keep-listed index drops
#                                            are still skipped)
#   FALCON_SCHEMA_SYNC_DEFER_DESTRUCTIVE=1   apply only the safe part (incl. the
#                                            additive actions of a mixed ALTER
#                                            TABLE), leave the blocked ones for
#                                            later, and carry on
# Raw escape hatch (no guard; drops keep-listed indexes; run perf-schema after):
#   bash ./scripts/deploy/db.sh push-raw | push-loss

SCHEMA_SYNC_EXIT_BLOCKED=3
SCHEMA_SYNC_MARK_BEGIN="===FALCON-SCHEMA-DIFF-BEGIN==="
SCHEMA_SYNC_MARK_END="===FALCON-SCHEMA-DIFF-END==="

# Shell command run inside falcon-core (cwd = libs/database) that prints the
# diff between two markers, so container/npm chatter can never leak into it.
schema_sync_diff_shell_cmd() {
  local db_dir="$1"
  printf '%s' "cd ${db_dir} && echo ${SCHEMA_SYNC_MARK_BEGIN} && PRISMA_HIDE_UPDATE_MESSAGE=1 npx prisma migrate diff --from-schema-datasource prisma/schema.prisma --to-schema-datamodel prisma/schema.prisma --script && echo ${SCHEMA_SYNC_MARK_END}"
}

schema_sync_state_dir() {
  local dir="${ROOT_DIR}/.deploy"
  mkdir -p "${dir}" 2>/dev/null || dir="${TMPDIR:-/tmp}"
  printf '%s' "${dir}"
}

schema_sync_audit() {
  local state
  state="$(schema_sync_state_dir)"
  printf '%s %s user=%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(hostname 2>/dev/null || echo host)" \
    "$(id -un 2>/dev/null || echo "?")" "$*" >> "${state}/schema-sync.log" 2>/dev/null || true
}

schema_sync_print_file() {
  local file="$1"
  sed 's/^/    /' "${file}"
}

# schema_sync <apply|check> <diff_fn> <psql_fn>
#   diff_fn  prints the output of schema_sync_diff_shell_cmd run in falcon-core
#   psql_fn  psql against the app database; extra args are passed through and
#            the SQL comes on stdin
# Returns 0 (done / check passed), 3 (blocked: nothing applied), 1 (error).
schema_sync() {
  local mode="$1" diff_fn="$2" psql_fn="$3"
  local work rc=0 state main lock_timeout
  local keeplist="${ROOT_DIR}/scripts/performance/live-only-indexes.txt"
  local classifier="${ROOT_DIR}/scripts/deploy/schema-sync-classify.awk"

  [[ -f "${keeplist}" ]] || { warn "Keep-list missing: ${keeplist} (update the bundle)."; return 1; }
  [[ -f "${classifier}" ]] || { warn "Classifier missing: ${classifier} (update the bundle)."; return 1; }
  lock_timeout="${FALCON_SCHEMA_LOCK_TIMEOUT:-30s}"
  if [[ ! "${lock_timeout}" =~ ^[0-9]+(ms|s|min)?$ ]]; then
    warn "FALCON_SCHEMA_LOCK_TIMEOUT='${lock_timeout}' is not like 30s / 500ms / 2min / 0."
    return 1
  fi

  work="$(mktemp -d "${TMPDIR:-/tmp}/falcon-schema-sync.XXXXXX")" || return 1
  state="$(schema_sync_state_dir)"

  log "Schema sync (${mode}): prisma migrate diff, live database -> schema.prisma (nothing is changed by this step)..."
  "${diff_fn}" > "${work}/raw.out" || rc=$?
  if [[ "${rc}" != "0" ]]; then
    warn "prisma migrate diff failed (exit ${rc}) — see the output above. Nothing was applied."
    tail -n 20 "${work}/raw.out" | sed 's/^/    /' >&2
    rm -rf "${work}"
    return 1
  fi
  if ! tr -d '\r' < "${work}/raw.out" | awk -v b="${SCHEMA_SYNC_MARK_BEGIN}" -v e="${SCHEMA_SYNC_MARK_END}" \
      '$0 == b { on = 1; next } $0 == e { on = 0; seen = 1; next } on { print } END { exit seen ? 0 : 1 }' \
      > "${work}/diff.sql"; then
    warn "prisma migrate diff output had no end marker (prisma failed?). Nothing was applied."
    tail -n 20 "${work}/raw.out" | sed 's/^/    /' >&2
    rm -rf "${work}"
    return 1
  fi
  cp "${work}/diff.sql" "${state}/schema-sync-last-diff.sql" 2>/dev/null || true

  mkdir -p "${work}/plan"
  rc=0
  awk -v keeplist="${keeplist}" -v outdir="${work}/plan" -f "${classifier}" < "${work}/diff.sql" > "${work}/verdicts.txt" || rc=$?
  if [[ "${rc}" != "0" && "${rc}" != "${SCHEMA_SYNC_EXIT_BLOCKED}" ]]; then
    warn "Could not classify the diff (exit ${rc}). Nothing was applied. Diff kept at ${state}/schema-sync-last-diff.sql"
    rm -rf "${work}"
    return 1
  fi
  sed 's/^/    /' "${work}/verdicts.txt"

  main="${work}/plan/apply.sql"
  if [[ "${rc}" == "${SCHEMA_SYNC_EXIT_BLOCKED}" ]]; then
    cp "${work}/plan/blocked.sql" "${state}/schema-sync-blocked.sql" 2>/dev/null || true
    if [[ "${FALCON_ALLOW_DESTRUCTIVE_SCHEMA:-0}" == "1" ]]; then
      warn "FALCON_ALLOW_DESTRUCTIVE_SCHEMA=1: the BLOCKED statements below WILL be applied (diff order, one transaction):"
      schema_sync_print_file "${work}/plan/blocked.sql"
      main="${work}/plan/override.sql"
      [[ "${mode}" == "apply" ]] && schema_sync_audit "OVERRIDE FALCON_ALLOW_DESTRUCTIVE_SCHEMA=1 applying: $(tr '\n' ' ' < "${work}/plan/blocked.sql")"
    elif [[ "${FALCON_SCHEMA_SYNC_DEFER_DESTRUCTIVE:-0}" == "1" ]]; then
      warn "FALCON_SCHEMA_SYNC_DEFER_DESTRUCTIVE=1: applying only the safe part; these stay PENDING (saved to ${state}/schema-sync-blocked.sql):"
      schema_sync_print_file "${work}/plan/blocked.sql"
      main="${work}/plan/defer.sql"
      [[ "${mode}" == "apply" ]] && schema_sync_audit "DEFER FALCON_SCHEMA_SYNC_DEFER_DESTRUCTIVE=1 left pending: $(tr '\n' ' ' < "${work}/plan/blocked.sql")"
    else
      printf '%b[%s] ERROR: %s%b\n' "${RED:-}" "$(date '+%H:%M:%S')" \
        "Schema sync STOPPED: the schema change includes destructive statements. NOTHING was applied." "${NC:-}" >&2
      schema_sync_print_file "${work}/plan/blocked.sql" >&2
      cat >&2 <<EOF
    Saved to: ${state}/schema-sync-blocked.sql  (full diff: ${state}/schema-sync-last-diff.sql)
    Review them, then choose ONE:
      a) Apply them yourself, deliberately (backup first), then rerun the deploy:
           bash ./scripts/deploy/db.sh psql -- -v ON_ERROR_STOP=1 --single-transaction -f - < ${state}/schema-sync-blocked.sql
      b) Let the sync apply them (logged):
           FALCON_ALLOW_DESTRUCTIVE_SCHEMA=1 bash ./scripts/deploy/db.sh push
      c) Keep them for later and apply only the safe part (logged):
           FALCON_SCHEMA_SYNC_DEFER_DESTRUCTIVE=1 bash ./scripts/deploy/db.sh push
      d) A drift you want to keep (a live-only index): add its name to
           scripts/performance/live-only-indexes.txt in the repo and ship a new bundle.
    b) and c) also work for a whole deploy: put the variable in front of it, e.g.
           FALCON_SCHEMA_SYNC_DEFER_DESTRUCTIVE=1 bash ./scripts/deploy/deploy.sh ghcr
EOF
      schema_sync_audit "STOPPED (${mode}) blocked: $(tr '\n' ' ' < "${work}/plan/blocked.sql")"
      rm -rf "${work}"
      return "${SCHEMA_SYNC_EXIT_BLOCKED}"
    fi
  fi

  if [[ "${mode}" == "check" ]]; then
    ok "Schema sync check passed (nothing destructive will be applied)."
    rm -rf "${work}"
    return 0
  fi

  if [[ ! -s "${work}/plan/enum.sql" && ! -s "${main}" ]]; then
    ok "Schema already in sync (nothing to apply)."
    rm -rf "${work}"
    return 0
  fi

  if [[ -s "${work}/plan/enum.sql" ]]; then
    log "Adding enum values (autocommit, before the main transaction)..."
    rc=0
    { printf "SET lock_timeout = '%s';\n" "${lock_timeout}"; cat "${work}/plan/enum.sql"; } \
      | "${psql_fn}" -v ON_ERROR_STOP=1 -f - || rc=$?
    if [[ "${rc}" != "0" ]]; then
      warn "Adding enum values failed (exit ${rc}). Nothing else was applied; rerun: bash ./scripts/deploy/db.sh push"
      rm -rf "${work}"
      return 1
    fi
  fi

  if [[ -s "${main}" ]]; then
    log "Applying $(grep -c ';$' "${main}") statement(s) in ONE transaction (lock_timeout ${lock_timeout})..."
    rc=0
    { printf "SET LOCAL lock_timeout = '%s';\n" "${lock_timeout}"; cat "${main}"; } \
      | "${psql_fn}" -v ON_ERROR_STOP=1 --single-transaction -f - || rc=$?
    if [[ "${rc}" != "0" ]]; then
      warn "Schema transaction failed (exit ${rc}) and was rolled back — see the psql error above. Rerun: bash ./scripts/deploy/db.sh push"
      rm -rf "${work}"
      return 1
    fi
  fi
  schema_sync_audit "APPLIED (${mode}) $(grep -c ';$' "${main}") statement(s), skipped keep-listed: $(tr '\n' ' ' < "${work}/plan/skipped.txt")"
  ok "Schema sync applied."
  rm -rf "${work}"
  return 0
}
