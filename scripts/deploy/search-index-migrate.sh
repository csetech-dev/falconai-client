#!/usr/bin/env bash
# Move search to the index schema of the deployed search-service release, WITHOUT downtime.
# Run on the APP server (where falcon-opensearch and falcon-search run), in /opt/falconai-client.
#
#   sudo bash scripts/deploy/search-index-migrate.sh status               # where search stands; read-only
#   sudo bash scripts/deploy/search-index-migrate.sh migrate --dry-run    # the plan; changes nothing
#   sudo bash scripts/deploy/search-index-migrate.sh migrate              # asks once, then migrates
#   sudo bash scripts/deploy/search-index-migrate.sh rollback [--to INDEX] # back to the previous index
#
# migrate: 1. create the new index (settings from the running search-service: one definition)
#          2. point WRITES at it (new/updated documents go there; searches still read the old index)
#          3. copy the old index into it with op_type=create (a newer document already written to the new
#             index is never overwritten by its older copy)
#          4. check the new index has at least as many documents as the old one
#          5. switch READS to it in one atomic alias update. The old index is kept.
# Stopped part-way? Run migrate again: it resumes. Searches stay on the old index until step 5.
# rollback (also from the middle of a migration): copy the new index back into the old one (op_type=index:
# its versions are the same or newer), move WRITES back, copy again what arrived meanwhile (op_type=create),
# then switch READS back. The new index is kept.
# Known limits (run in a quiet period): a document deleted during a copy comes back from the other copy;
# a document updated during rollback's first copy keeps its earlier version until its next update.
#
# Exit codes: 0 done · 2 refused before any change (or you answered no) · 4 failed part-way (what to do is printed)
# Runbook: docs/search/SEARCH_INDEX_MIGRATION.md
set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=monitoring-setup-lib.sh
source "${SCRIPT_DIR}/monitoring-setup-lib.sh"

# Until something changes, any unexpected failure means nothing changed.
trap 'echo "ERROR: unexpected failure (line ${LINENO}). Nothing changed." >&2; exit 2' ERR

READ_ALIAS="falcon-content-read" WRITE_ALIAS="falcon-content-write" OS_URL="http://localhost:9200"
APP_PROJECT="falcon-app"
ACTION="${1:-}"; shift || true
ROLLBACK_TO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MSL_DRY_RUN=1; shift ;;
    --yes) MSL_ASSUME_YES=1; shift ;;
    --to) [[ -n "${2:-}" ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "--to needs an index name"; ROLLBACK_TO="$2"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) msl_fail "$MSL_EXIT_PREFLIGHT" "unknown argument: $1" ;;
  esac
done
[[ "$ACTION" =~ ^(status|migrate|rollback)$ ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "usage: $0 status|migrate|rollback [--dry-run] [--yes] [--to INDEX]"
msl_require_root
command -v python3 > /dev/null || msl_fail "$MSL_EXIT_PREFLIGHT" "python3 is needed to read OpenSearch's JSON"
running="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
for c in falcon-opensearch falcon-search; do
  grep -qx "$c" <<<"$running" || msl_fail "$MSL_EXIT_PREFLIGHT" "${c} is not running here; run this on the APP server"
  project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$c" 2>/dev/null || true)"
  [[ "$project" == "$APP_PROJECT" ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "${c} belongs to compose project '${project:-none}', not '${APP_PROJECT}'. Run this on FalconAI's APP server"
done

# ---------------------------------------------------------------- helpers
os() {  # os METHOD PATH [stdin]: OpenSearch's answer on stdout; fails on HTTP >= 400
  local method="$1" path="$2"
  if [[ "$method" == HEAD ]]; then  # curl -X HEAD would wait for a body that never comes
    docker exec falcon-opensearch curl -sS --fail -m 30 -I "${OS_URL}${path}"
  elif [[ "${3:-}" == stdin ]]; then
    docker exec -i falcon-opensearch curl -sS --fail-with-body -m 600 -X "$method" "${OS_URL}${path}" -H 'content-type: application/json' --data-binary @-
  else
    docker exec falcon-opensearch curl -sS --fail-with-body -m 600 -X "$method" "${OS_URL}${path}" -H 'content-type: application/json'
  fi
}
js() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }  # js '<python using d>'
alias_targets() {  # every index an alias points at, one per line (nothing when it doesn't exist)
  local out; out="$(os GET "/_alias/$1" 2>/dev/null)" || return 0
  js 'print("\n".join(d))' <<<"$out"
}
alias_target() {  # the ONE index an alias points at; refuses if it points at several
  local t; t="$(alias_targets "$1")"
  [[ "$(grep -c . <<<"$t" || true)" -le 1 ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "the alias $1 points at more than one index ($(tr '\n' ' ' <<<"$t")); fix it by hand. Nothing changed"
  printf '%s' "$t"
}
doc_count() { os POST "/$1/_refresh" > /dev/null; os GET "/$1/_count" | js 'print(d["count"])'; }
store_bytes() { os GET "/_cat/indices/$1?format=json&bytes=b&h=store.size" | js 'print(d[0]["store.size"] or 0)'; }
disk_check() {  # disk_check NEED_BYTES: refuse if the copy would cross OpenSearch's high watermark (or free space)
  local alloc settings
  alloc="$(os GET "/_cat/allocation?format=json&bytes=b&h=disk.used,disk.total,disk.avail")"
  settings="$(os GET "/_cluster/settings?include_defaults=true&flat_settings=true")"
  python3 - "$1" "$alloc" "$settings" <<'PY' || exit "$MSL_EXIT_PREFLIGHT"
import json, sys
need, alloc, s = int(sys.argv[1]), json.loads(sys.argv[2]), json.loads(sys.argv[3])
get = lambda k, dflt: next((g[k] for g in (s.get("transient", {}), s.get("persistent", {}), s.get("defaults", {})) if k in g), dflt)
enabled = str(get("cluster.routing.allocation.disk.threshold_enabled", "true")).lower() == "true"
high = str(get("cluster.routing.allocation.disk.watermark.high", "90%"))
for n in alloc:
    if not n.get("disk.total"): continue
    used, total, avail = int(n["disk.used"]), int(n["disk.total"]), int(n["disk.avail"])
    if avail <= need:
        sys.exit(print(f"ERROR: not enough disk for the copy: need about {need//2**20} MB, {avail//2**20} MB free. Nothing changed", file=sys.stderr) or 1)
    if enabled and high.endswith("%"):
        after = 100 * (used + need) / total
        if after >= float(high[:-1]):
            sys.exit(print(f"ERROR: the copy would take the disk to {after:.0f}% used, past OpenSearch's high watermark ({high}); OpenSearch would stop it. Free disk first. Nothing changed", file=sys.stderr) or 1)
PY
}
copy_index() {  # copy_index FROM TO OP_TYPE : _reindex as a task, waited on; fails on any failure
  local from="$1" to="$2" op="$3" task out
  task="$(printf '{"conflicts":"proceed","source":{"index":"%s"},"dest":{"index":"%s","op_type":"%s"}}' "$from" "$to" "$op" \
    | os POST "/_reindex?wait_for_completion=false&slices=auto" stdin | js 'print(d["task"])')" || task=""
  [[ -n "$task" ]] || { echo "ERROR: OpenSearch refused the copy ${from} -> ${to}" >&2; return 1; }
  echo "   copying ${from} -> ${to} (task ${task})..."
  for _ in $(seq 1 1440); do
    out="$(os GET "/_tasks/${task}")" || { echo "ERROR: cannot read the copy task ${task}" >&2; return 1; }
    if [[ "$(js 'print(d.get("completed", False))' <<<"$out")" == True ]]; then
      OP="$op" js 'import os; r=d.get("response",{}); e=d.get("error"); f=r.get("failures",[])
if os.environ["OP"] == "create": print("   copied: %s new, %s skipped (already newer in the target)" % (r.get("created",0), r.get("version_conflicts",0)))
else: print("   copied: %s new, %s replaced with the newer version" % (r.get("created",0), r.get("updated",0)))
sys.exit(1 if e or f else 0)' <<<"$out" || { echo "ERROR: the copy reported failures: $(js 'print(json.dumps(d.get("error") or d.get("response",{}).get("failures"))[:500])' <<<"$out")" >&2; return 1; }
      return 0
    fi
    sleep 5
  done
  echo "ERROR: the copy did not finish within 2 hours (task ${task} may still be running)" >&2; return 1
}
move_alias() {  # move_alias ALIAS TO : one atomic update, from wherever it points now
  local alias="$1" to="$2" from actions=""
  from="$(alias_target "$alias")"
  [[ "$from" == "$to" ]] && return 0
  [[ -n "$from" ]] && actions="{\"remove\":{\"index\":\"${from}\",\"alias\":\"${alias}\"}},"
  printf '{"actions":[%s{"add":{"index":"%s","alias":"%s"}}]}' "$actions" "$to" "$alias" | os POST /_aliases stdin > /dev/null
}

# ---------------------------------------------------------------- what the release wants
definition="$(docker exec falcon-search node dist/index-admin/print-index-definition.js 2>/dev/null)" || \
  msl_fail "$MSL_EXIT_PREFLIGHT" "the running search-service has no migration helper. Deploy the app release that contains it first (falcon-search must be rebuilt). Nothing changed"
version="$(js 'print(d["version"])' <<<"$definition")"
prefix="$(js 'print(d["prefix"])' <<<"$definition")"
[[ "$prefix" =~ ^falcon-content-[a-z0-9]+-$ ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "unexpected index prefix from search-service: ${prefix}"

read_idx="$(alias_target "$READ_ALIAS")"
write_idx="$(alias_target "$WRITE_ALIAS")"
[[ -n "$read_idx" ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "the alias ${READ_ALIAS} does not exist; on a fresh cluster search-service creates the index itself at startup"

if [[ "$ACTION" == status ]]; then
  echo "Search reads:  ${read_idx} ($(doc_count "$read_idx") documents)"
  echo "Search writes: ${write_idx:-<none>}"
  echo "Release wants: index schema ${version} (${prefix}*)"
  if [[ "$read_idx" == "$prefix"* && "$write_idx" == "$read_idx" ]]; then echo "State: current"
  elif [[ -n "$write_idx" && "$write_idx" != "$read_idx" ]]; then echo "State: migration in progress (writes moved, reads not yet): run migrate to finish, or rollback"
  else echo "State: upgrade pending: run migrate"; fi
  echo "All indices:"; os GET "/_cat/indices/falcon-content-*?v&h=index,docs.count,store.size,creation.date.string&s=index"
  exit 0
fi

# ---------------------------------------------------------------- migrate
if [[ "$ACTION" == migrate ]]; then
  if [[ "$read_idx" == "$prefix"* && "$write_idx" == "$read_idx" ]]; then
    echo "Search is already on index schema ${version} (${read_idx}). Nothing to do."; exit 0
  fi
  [[ "$read_idx" != "$prefix"* ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "reads are on ${read_idx} but writes on ${write_idx:-none}; fix by hand. Nothing changed"
  old="$read_idx"
  if [[ "$write_idx" == "$prefix"* ]]; then
    new="$write_idx"; echo "Resuming: writes already go to ${new}."
  else
    new="${prefix}$(date -u +%Y%m%d)"
  fi
  if os HEAD "/${new}" > /dev/null 2>&1; then  # reuse only an index built with this release's analysis
    want="$(js 'print(json.dumps(d["body"]["settings"]["analysis"]["analyzer"], sort_keys=True))' <<<"$definition")"
    have="$(os GET "/${new}/_settings" | js 'a=next(iter(d.values()))["settings"]["index"].get("analysis",{}).get("analyzer",{}); print(json.dumps(a, sort_keys=True))')"
    [[ "$want" == "$have" ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "${new} already exists with different settings than this release builds. Delete it (if unused) or ask the team. Nothing changed"
  fi
  old_docs="$(doc_count "$old")"
  disk_check $(( $(store_bytes "$old") * 3 / 2 ))
  echo "Plan (searches keep working throughout):"
  echo "  1. create ${new} with index schema ${version} (if it does not exist)"
  echo "  2. send writes to ${new} (searches still read ${old})"
  echo "  3. copy ${old_docs} documents from ${old}; documents already newer in ${new} are kept"
  echo "  4. check ${new} has at least ${old_docs} documents"
  echo "  5. switch searches to ${new} in one step; ${old} is kept for rollback"
  echo "  Newly scraped items appear in search after step 5. Search ranking for Bangla text changes (that is the point)."
  [[ "$MSL_DRY_RUN" -eq 1 ]] && { echo "Dry run: nothing changed."; exit 0; }
  msl_confirm "Migrate search to ${new} now?"

  fail_mid() {
    trap - ERR
    echo "ERROR: $1" >&2
    echo "Searches still read ${old}; writes go to ${new}. Nothing is lost. Fix the cause and run migrate again (it resumes)," >&2
    echo "or go back: sudo bash scripts/deploy/search-index-migrate.sh rollback" >&2
    exit "$MSL_EXIT_VERIFY"
  }
  if ! os HEAD "/${new}" > /dev/null 2>&1; then
    js 'print(json.dumps(d["body"]))' <<<"$definition" | os PUT "/${new}" stdin > /dev/null
    echo "✅ 1. created ${new}"
  else echo "   1. ${new} already exists"; fi
  trap 'echo "ERROR: unexpected failure (line ${LINENO}) after creating ${new}; searches and writes still use ${old}. Run migrate again." >&2; exit 4' ERR
  move_alias "$WRITE_ALIAS" "$new"; echo "✅ 2. writes go to ${new}"
  trap 'fail_mid "unexpected failure (line ${LINENO})"' ERR

  copy_index "$old" "$new" create || fail_mid "copying documents failed"
  new_docs="$(doc_count "$new")"; old_now="$(doc_count "$old")"
  (( new_docs >= old_now )) || fail_mid "${new} has ${new_docs} documents, fewer than ${old}'s ${old_now}"
  echo "✅ 4. ${new} has ${new_docs} documents (${old}: ${old_now})"

  trap - ERR
  if ! move_alias "$READ_ALIAS" "$new" || [[ "$(alias_target "$READ_ALIAS")" != "$new" || "$(alias_target "$WRITE_ALIAS")" != "$new" ]]; then
    echo "ERROR: switching searches to ${new} did not complete. Check: sudo bash scripts/deploy/search-index-migrate.sh status" >&2
    echo "If searches read ${old}, run migrate again; to go back: sudo bash scripts/deploy/search-index-migrate.sh rollback --to ${old}" >&2
    exit "$MSL_EXIT_VERIFY"
  fi
  echo "✅ 5. searches now use ${new}"
  echo "Done. ${old} is kept. To go back: sudo bash scripts/deploy/search-index-migrate.sh rollback --to ${old}"
  exit 0
fi

# ---------------------------------------------------------------- rollback
from="${write_idx:-$read_idx}"   # where the newest documents are
if [[ -z "$ROLLBACK_TO" ]]; then
  if [[ -n "$write_idx" && "$write_idx" != "$read_idx" ]]; then
    ROLLBACK_TO="$read_idx"        # in the middle of a migration: searches never left the old index
  else
    candidates="$(os GET "/_cat/indices/falcon-content-*?format=json&h=index" | js "print('\n'.join(sorted(i['index'] for i in d if i['index'] != '${from}')))")"
    [[ "$(grep -c . <<<"$candidates" || true)" -eq 1 ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "say which index to go back to with --to (candidates: $(tr '\n' ' ' <<<"$candidates")). Nothing changed"
    ROLLBACK_TO="$candidates"
  fi
fi
[[ "$ROLLBACK_TO" != "$from" ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "search already reads and writes ${ROLLBACK_TO}. Nothing to do"
os HEAD "/${ROLLBACK_TO}" > /dev/null 2>&1 || msl_fail "$MSL_EXIT_PREFLIGHT" "index ${ROLLBACK_TO} does not exist. Nothing changed"
echo "Plan: 1. copy ${from} into ${ROLLBACK_TO} (its documents are the same or newer)"
echo "      2. send writes back to ${ROLLBACK_TO}"
echo "      3. copy again what reached ${from} meanwhile (nothing already in ${ROLLBACK_TO} is overwritten)"
echo "      4. point searches at ${ROLLBACK_TO}. ${from} is kept."
echo "  Known limits: documents deleted since the migration may come back; one updated during step 1 keeps its earlier version until its next update."
[[ "$MSL_DRY_RUN" -eq 1 ]] && { echo "Dry run: nothing changed."; exit 0; }
msl_confirm "Roll search back to ${ROLLBACK_TO} now?"
rollback_fail() {
  trap - ERR
  echo "ERROR: $1" >&2
  echo "Check: sudo bash scripts/deploy/search-index-migrate.sh status, fix the cause, and run this rollback again (it is safe to repeat)." >&2
  exit "$MSL_EXIT_VERIFY"
}
trap 'rollback_fail "unexpected failure (line ${LINENO})"' ERR
copy_index "$from" "$ROLLBACK_TO" index || rollback_fail "copying back failed; reads and writes are unchanged"
move_alias "$WRITE_ALIAS" "$ROLLBACK_TO"; echo "✅ writes go to ${ROLLBACK_TO}"
copy_index "$from" "$ROLLBACK_TO" create || rollback_fail "the catch-up copy failed; writes go to ${ROLLBACK_TO}, searches still read ${read_idx}"
move_alias "$READ_ALIAS" "$ROLLBACK_TO"
trap - ERR
echo "✅ Search reads and writes ${ROLLBACK_TO} again ($(doc_count "$ROLLBACK_TO") documents). ${from} is kept."
