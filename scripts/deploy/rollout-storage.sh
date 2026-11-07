#!/usr/bin/env bash
# ONE command for the STORAGE server: applies every database-scaling step proven on stage.
#
#   sudo bash scripts/deploy/rollout-storage.sh --dry-run    # check every step, change nothing
#   sudo bash scripts/deploy/rollout-storage.sh              # check, show the plan, ask ONCE, apply in order
#
# Steps (each is idempotent, so re-running is safe and reports "unchanged" / "already on"):
#   1. Monitoring exporters + TLS + firewall          monitoring-setup-storage.sh   (P1.7a, P1.7b, P1.9)  no DB restart
#   2. pg_stat_statements                              pg-stat-statements.sh enable  (P0.1)  ONE Postgres restart, ~10-30 s
# At the end it prints the FALCONMON1: hand-off line for rollout-app.sh on the app server.
#
# Options: --yes (skip the one question)  --skip-pg-restart (leave out step 2, e.g. outside a quiet window)
#          --storage-ip IP  --app-ip IP (passed to step 1 when auto-detection is wrong)
# Exit codes: 0 done · 2 refused before any change (a step's check failed, or you answered no)
#             4 a step applied but its verify failed · 5 a step failed while applying (it may be partly applied)
#             Either way earlier steps stay applied and later ones did not run; follow the step's message, then run
#             this again (finished steps report unchanged).
# Runbook: docs/db/scaling/PRODUCTION_ROLLOUT.md
#
# Adding a plan item that needs server work: add it as a step below (a dry-run line and an apply line), in the
# order it must run, and add a row to the runbook's step table.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=monitoring-setup-lib.sh
source "${SCRIPT_DIR}/monitoring-setup-lib.sh"

SKIP_PG=0
MON_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MSL_DRY_RUN=1; shift ;;
    --yes) MSL_ASSUME_YES=1; shift ;;
    --skip-pg-restart) SKIP_PG=1; shift ;;
    --storage-ip|--app-ip) [[ -n "${2:-}" ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "$1 needs a value"; MON_ARGS+=("$1" "$2"); shift 2 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) msl_fail "$MSL_EXIT_PREFLIGHT" "unknown argument: $1" ;;
  esac
done
msl_require_root

# name | script + args (run with --dry-run, then with --yes)
STEPS=("Monitoring exporters, TLS and firewall (P1.7a/b, P1.9)|monitoring-setup-storage.sh")
if [[ "$SKIP_PG" -eq 1 ]]; then
  echo "Step pg_stat_statements (P0.1): skipped (--skip-pg-restart). Run this rollout again later without it."
else
  STEPS+=("pg_stat_statements, ONE PostgreSQL restart ~10-30 s (P0.1)|pg-stat-statements.sh enable")
fi

step_cmd() {  # step_cmd <index> <mode: --dry-run|--yes>
  local spec="${STEPS[$1]#*|}"; local script="${spec%% *}" rest=""; local -a extra=()
  [[ "$spec" == *" "* ]] && rest="${spec#* }"
  local -a cmd=(bash "${SCRIPT_DIR}/${script}")
  [[ -n "$rest" ]] && read -r -a extra <<<"$rest" && cmd+=("${extra[@]}")
  cmd+=("$2")
  [[ "$script" == monitoring-setup-storage.sh ]] && cmd+=("${MON_ARGS[@]+"${MON_ARGS[@]}"}")
  # The secret hand-off line is printed once, at the very end, not by step 1 as well.
  MSL_NO_HANDOFF_PRINT=1 "${cmd[@]}"
}

echo "================ FalconAI storage rollout: checking every step (nothing changes yet) ================"
for i in "${!STEPS[@]}"; do
  echo; echo "---- Check $((i + 1))/${#STEPS[@]}: ${STEPS[$i]%%|*}"
  rc=0; step_cmd "$i" --dry-run || rc=$?
  [[ "$rc" -eq 0 ]] || { echo "ERROR: the check for step $((i + 1)) (${STEPS[$i]%%|*}) failed (exit ${rc}). Nothing changed. Fix what it says above and run again." >&2; exit "$rc"; }
done
echo
if [[ "$MSL_DRY_RUN" -eq 1 ]]; then echo "Dry run: nothing changed. All ${#STEPS[@]} checks passed."; exit 0; fi

echo "Plan:"; for i in "${!STEPS[@]}"; do echo "  $((i + 1)). ${STEPS[$i]%%|*}"; done
msl_confirm "Apply all ${#STEPS[@]} steps now, in this order?"

for i in "${!STEPS[@]}"; do
  echo; echo "================ Step $((i + 1))/${#STEPS[@]}: ${STEPS[$i]%%|*}"
  rc=0; step_cmd "$i" --yes || rc=$?
  [[ "$rc" -eq 0 ]] || { [[ "$rc" -eq 4 ]] || rc=5; echo "ERROR: step $((i + 1)) (${STEPS[$i]%%|*}) failed while applying (exit ${rc}). Steps before it stay applied; later steps did not run. Follow the step's message above, then run this rollout again: done steps report unchanged." >&2; exit "$rc"; }
done

echo; echo "✅ Storage rollout complete (${#STEPS[@]} steps)."
echo "Next, on the APP server:  sudo bash scripts/deploy/rollout-app.sh --public-url https://<site>"
echo "and paste this line when it asks (it contains the scrape password: copy it, then run 'clear'):"
echo
bash "${SCRIPT_DIR}/monitoring-setup-storage.sh" --print-handoff
