#!/usr/bin/env bash
# Deploy the monitoring stack (Prometheus, Alertmanager, Grafana) on the APP host
# (scaling plan P1.7b PR 2). Off until you run this; app deploys never touch it.
#
#   bash scripts/deploy/deploy-monitoring.sh --check-only   # check, render, validate; start nothing
#   bash scripts/deploy/deploy-monitoring.sh                # ... then docker compose up -d
#
# Settings: /etc/falcon-monitoring/monitoring.env (copy .env.monitoring.example; override with MONITORING_ENV_FILE).
# Settings, secrets and rendered configs all live outside the bundle checkout, so bundle syncs, git clean
# and git add never touch them.
# Runbook: docs/db/scaling/p1-7b-2-monitoring-stack.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=monitoring-render.sh
source "${SCRIPT_DIR}/monitoring-render.sh"

CHECK_ONLY=0
case "${1:-}" in
  --check-only) CHECK_ONLY=1 ;;
  "") ;;
  *) die "unknown argument: $1 (use --check-only or nothing)" ;;
esac

ENV_FILE="${MONITORING_ENV_FILE:-/etc/falcon-monitoring/monitoring.env}"
MONITORING_COMPOSE="${ROOT_DIR}/docker-compose.monitoring.yml"
[[ -f "${ENV_FILE}" ]] || die "Missing ${ENV_FILE}. Copy .env.monitoring.example there and edit it (docs/db/scaling/p1-7b-2-monitoring-stack.md)."

require_cmd docker
detect_compose
load_env_file "${ENV_FILE}"
export MONITORING_SECRETS_DIR="${MONITORING_SECRETS_DIR:-/etc/falcon-monitoring/secrets}"
export MONITORING_CONFIG_DIR="${MONITORING_CONFIG_DIR:-/etc/falcon-monitoring/config}"
APP_NETWORK="${MONITORING_APP_NETWORK:-falcon-app_falcon-net}"
PROM_IMAGE="${PROMETHEUS_IMAGE:-prom/prometheus:v3.4.1}"
AM_IMAGE="${ALERTMANAGER_IMAGE:-prom/alertmanager:v0.28.1}"

log "Checking settings and secrets..."
monitoring_check_inputs
monitoring_check_secrets

if ! docker network inspect "${APP_NETWORK}" >/dev/null 2>&1; then
  die "Docker network '${APP_NETWORK}' not found. Start the app stack first (it creates the network), or set MONITORING_APP_NETWORK in ${ENV_FILE}."
fi
ok "App network ${APP_NETWORK} found."

log "Rendering configs into ${MONITORING_CONFIG_DIR}..."
monitoring_render

log "Validating configs (promtool, amtool)..."
docker run --rm --entrypoint promtool \
  -v "${MONITORING_CONFIG_DIR}:/etc/falcon-config:ro" -v "${MONITORING_SECRETS_DIR}:/run/falcon-secrets:ro" \
  "${PROM_IMAGE}" check config /etc/falcon-config/prometheus.yml
docker run --rm --entrypoint amtool \
  -v "${MONITORING_CONFIG_DIR}:/etc/falcon-config:ro" -v "${MONITORING_SECRETS_DIR}:/run/falcon-secrets:ro" \
  "${AM_IMAGE}" check-config /etc/falcon-config/alertmanager.yml
ok "Configs valid."

if [[ "${CHECK_ONLY}" -eq 1 ]]; then
  ok "Check only: nothing started."
  exit 0
fi

log "Starting the monitoring stack..."
"${COMPOSE[@]}" --env-file "${ENV_FILE}" -f "${MONITORING_COMPOSE}" up -d
# `up -d` leaves running containers alone when only the rendered files changed; restart the two that
# read them so new settings (e.g. Telegram, STORAGE_SERVER_IP) take effect. Grafana is not restarted.
"${COMPOSE[@]}" --env-file "${ENV_FILE}" -f "${MONITORING_COMPOSE}" restart prometheus alertmanager
ok "Monitoring stack started. Verify with docs/db/scaling/p1-7b-2-monitoring-stack.md step 5."
