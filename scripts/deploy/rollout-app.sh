#!/usr/bin/env bash
# ONE command for the APP server: applies every database-scaling step proven on stage.
# Run it after rollout-storage.sh, which prints the FALCONMON1: hand-off line.
#
#   sudo bash scripts/deploy/rollout-app.sh --public-url https://<site> --dry-run   # check, change nothing
#   sudo bash scripts/deploy/rollout-app.sh --public-url https://<site>             # check, ask ONCE, apply
#
# You paste the hand-off line ONCE (hidden prompt). It stays in memory and is fed to the check and the apply on stdin;
# it is never written to disk or printed. Or pass --handoff FILE: the DECODED hand-off env file (STORAGE_IP=,
# SCRAPE_PASSWORD=, CA_PEM_B64=; e.g. a copy of the storage server's /root/falcon-monitoring-handoff.env), root-owned, chmod 600.
#
# Steps (idempotent; re-running is safe):
#   1. Monitoring stack: Prometheus, Alertmanager, Grafana, alert rules, dashboards   monitoring-setup-app.sh  (P1.7b/c, P1.9)
#
# Options: --yes (skip the one question)  --handoff -|FILE
# Exit codes: 0 done · 2 refused before any change (a check failed, or you answered no)
#             4 a step applied but its verify failed · 5 a step failed while applying (it may be partly applied)
#             Either way: follow the step's message, then run this again (finished steps report unchanged).
# Runbook: docs/db/scaling/PRODUCTION_ROLLOUT.md
#
# Adding a plan item that needs app-server work: add it as a step below, and a row to the runbook's step table.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=monitoring-setup-lib.sh
source "${SCRIPT_DIR}/monitoring-setup-lib.sh"

PUBLIC_URL="" HANDOFF="-"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MSL_DRY_RUN=1; shift ;;
    --yes) MSL_ASSUME_YES=1; shift ;;
    --public-url|--handoff)
      [[ -n "${2:-}" ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "$1 needs a value"
      if [[ "$1" == --public-url ]]; then PUBLIC_URL="$2"; else HANDOFF="$2"; fi; shift 2 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) msl_fail "$MSL_EXIT_PREFLIGHT" "unknown argument: $1" ;;
  esac
done
msl_require_root
[[ -n "$PUBLIC_URL" ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "--public-url https://<site> is required (the site's public address, no path)"

HANDOFF_LINE=""
if [[ "$HANDOFF" == - ]]; then
  if [[ -t 0 ]]; then IFS= read -r -s -p "Paste the FALCONMON1: line from rollout-storage.sh (hidden), then Enter: " HANDOFF_LINE || true; echo
  else IFS= read -r HANDOFF_LINE || true; fi
  HANDOFF_LINE="${HANDOFF_LINE//[[:space:]]/}"
  [[ "$HANDOFF_LINE" == FALCONMON1:* ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "that is not a FALCONMON1: line; copy it again from the storage server"
fi

STEPS=("Monitoring stack, alert rules and dashboards (P1.7b/c, P1.9)|monitoring-setup-app.sh")

step_cmd() {  # step_cmd <index> <mode: --dry-run|--yes>
  local script="${STEPS[$1]#*|}"
  if [[ "$HANDOFF" == - ]]; then
    # The step parses and checksums the line itself (its --handoff - mode); stdin is a pipe, never a file.
    printf '%s\n' "$HANDOFF_LINE" | bash "${SCRIPT_DIR}/${script}" --handoff - --public-url "$PUBLIC_URL" "$2"
  else
    bash "${SCRIPT_DIR}/${script}" --handoff "$HANDOFF" --public-url "$PUBLIC_URL" "$2" < /dev/null
  fi
}

echo "================ FalconAI app rollout: checking every step (nothing changes yet) ================"
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
  [[ "$rc" -eq 0 ]] || { [[ "$rc" -eq 4 ]] || rc=5; echo "ERROR: step $((i + 1)) (${STEPS[$i]%%|*}) failed while applying (exit ${rc}). Steps before it stay applied; later steps did not run. Follow the step's message above, then run this rollout again." >&2; exit "$rc"; }
done

echo; echo "✅ App rollout complete (${#STEPS[@]} steps). In FalconAI, open Administration → Monitoring: Grafana → Dashboards → FalconAI shows 3 dashboards."
