#!/usr/bin/env bash
# Install deploy-agent + GHCR webhook on a client app server.
#
# After this script:
#   1. Open firewall port GHCR_WEBHOOK_PORT (default 9191) from the internet, or
#      put nginx in front with HTTPS.
#   2. Set GitHub repo secrets (printed at the end).
#
# Usage:
#   sudo bash scripts/deploy/setup-auto-deploy.sh
#   sudo FALCON_DEPLOY_DIR=/opt/falconai-client bash scripts/deploy/setup-auto-deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEPLOY_DIR="${FALCON_DEPLOY_DIR:-${ROOT_DIR}}"
WEBHOOK_PORT="${GHCR_WEBHOOK_PORT:-9191}"
ENV_DIR="/etc/falconai"
ENV_FILE="${ENV_DIR}/ghcr-webhook.env"
AGENT_UNIT="/etc/systemd/system/falcon-deploy-agent.service"
WEBHOOK_UNIT="/etc/systemd/system/falcon-ghcr-webhook.service"

log() { printf '[setup-auto-deploy] %s\n' "$*"; }
die() { printf '[setup-auto-deploy] ERROR: %s\n' "$*" >&2; exit 1; }

# install(1) fails when src and dest are the same path (common on client bundle hosts).
install_file() {
  local src="$1" dest="$2" mode="$3"
  [[ -f "${src}" ]] || die "Missing file: ${src}"
  mkdir -p "$(dirname "${dest}")"
  if [[ -f "${dest}" ]] && [[ "$(readlink -f "${src}")" == "$(readlink -f "${dest}")" ]]; then
    chmod "${mode}" "${dest}"
    log "Already in place: ${dest}"
    return 0
  fi
  install -m "${mode}" "${src}" "${dest}"
}

[[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo bash $0"

command -v python3 >/dev/null 2>&1 || die "python3 is required for the webhook receiver"
command -v docker >/dev/null 2>&1 || die "docker is required"

[[ -d "${DEPLOY_DIR}" ]] || die "Deploy dir not found: ${DEPLOY_DIR}"
[[ -f "${DEPLOY_DIR}/scripts/deploy/deploy.sh" ]] || die "Missing ${DEPLOY_DIR}/scripts/deploy/deploy.sh"
[[ -f "${DEPLOY_DIR}/.env.app" ]] || die "Missing ${DEPLOY_DIR}/.env.app — configure GHCR_IMAGE_PREFIX first"

mkdir -p "${ENV_DIR}" "${DEPLOY_DIR}/.deploy" "${DEPLOY_DIR}/scripts"

install_file "${ROOT_DIR}/scripts/deploy-agent.sh" "${DEPLOY_DIR}/scripts/deploy-agent.sh" 755
install_file "${ROOT_DIR}/scripts/deploy/ghcr-webhook-server.py" "${DEPLOY_DIR}/scripts/deploy/ghcr-webhook-server.py" 755
install_file "${SCRIPT_DIR}/falcon-deploy-agent.service" "${AGENT_UNIT}" 644
install_file "${SCRIPT_DIR}/ghcr-webhook.service" "${WEBHOOK_UNIT}" 644

if [[ ! -f "${ENV_FILE}" ]]; then
  secret="$(openssl rand -hex 32 2>/dev/null || python3 -c 'import secrets; print(secrets.token_hex(32))')"
  cat > "${ENV_FILE}" <<EOF
# FalconAI GHCR webhook — keep secret, match GitHub CLIENT_DEPLOY_WEBHOOK_SECRET
GHCR_WEBHOOK_SECRET=${secret}
GHCR_WEBHOOK_PORT=${WEBHOOK_PORT}
FALCON_DEPLOY_DIR=${DEPLOY_DIR}
EOF
  chmod 600 "${ENV_FILE}"
  log "Created ${ENV_FILE}"
else
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  secret="${GHCR_WEBHOOK_SECRET:-}"
  WEBHOOK_PORT="${GHCR_WEBHOOK_PORT:-${WEBHOOK_PORT}}"
  [[ -n "${secret}" ]] || die "GHCR_WEBHOOK_SECRET empty in ${ENV_FILE}"
  log "Using existing ${ENV_FILE}"
fi

# Patch paths in unit files if not default install location.
if [[ "${DEPLOY_DIR}" != "/opt/falconai-client" ]]; then
  sed -i "s|/opt/falconai-client|${DEPLOY_DIR}|g" "${AGENT_UNIT}" "${WEBHOOK_UNIT}"
fi

systemctl daemon-reload
systemctl enable --now falcon-deploy-agent.service
systemctl enable --now falcon-ghcr-webhook.service

# Ensure agent watches PROJECT/.deploy (not project root) — fix older broken units
if grep -q 'Environment=FALCON_DEPLOY_DIR=/opt/falconai-client$' "${AGENT_UNIT}" 2>/dev/null \
  || grep -q "Environment=FALCON_DEPLOY_DIR=${DEPLOY_DIR}$" "${AGENT_UNIT}" 2>/dev/null; then
  if ! grep -q 'FALCON_STATUS_DIR' "${AGENT_UNIT}"; then
    sed -i "s|Environment=FALCON_DEPLOY_DIR=.*|Environment=FALCON_STATUS_DIR=${DEPLOY_DIR}/.deploy|" "${AGENT_UNIT}"
    systemctl daemon-reload
    systemctl restart falcon-deploy-agent.service
    log "Fixed agent status dir → ${DEPLOY_DIR}/.deploy"
  fi
fi

if ! grep -q '^FALCON_DEPLOY_MODE=' "${DEPLOY_DIR}/.env.app" 2>/dev/null; then
  echo "FALCON_DEPLOY_MODE=ghcr" >> "${DEPLOY_DIR}/.env.app"
  log "Appended FALCON_DEPLOY_MODE=ghcr to ${DEPLOY_DIR}/.env.app"
fi

public_ip=""
if command -v curl >/dev/null 2>&1; then
  public_ip="$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
fi

cat <<EOF

Auto-deploy services installed.

  deploy-agent:  systemctl status falcon-deploy-agent
  webhook:       systemctl status falcon-ghcr-webhook
  webhook health:  curl -s http://127.0.0.1:${WEBHOOK_PORT}/health

GitHub repo → Settings → Secrets and variables → Actions:

  CLIENT_DEPLOY_WEBHOOK         = http://YOUR_PUBLIC_IP:12006/deploy
  CLIENT_DEPLOY_WEBHOOK_SECRET  = ${secret}

  (Prefer :12006 via api-gateway. Direct :${WEBHOOK_PORT} often hits nginx → 405.)

${public_ip:+Detected public IP: ${public_ip} → http://${public_ip}:12006/deploy}

Ensure gateway can reach host webhook (docker-compose extra_hosts host.docker.internal).
Optional direct port:
  sudo ufw allow ${WEBHOOK_PORT}/tcp

Test from another machine (recommended):
  curl -sS -X POST "http://YOUR_PUBLIC_IP:12006/deploy" \\
    -H "Authorization: Bearer ${secret}" \\
    -H "Content-Type: application/json" \\
    -d '{"sha":"test"}'

Or direct (may fail with 405 if :${WEBHOOK_PORT} is forwarded to nginx):
  curl -sS -X POST "http://YOUR_PUBLIC_IP:${WEBHOOK_PORT}/deploy" \\
    -H "Authorization: Bearer ${secret}" \\
    -H "Content-Type: application/json" \\
    -d '{"sha":"test"}'

Then watch deploy:
  tail -f ${DEPLOY_DIR}/.deploy/output
  cat ${DEPLOY_DIR}/.deploy/status

EOF
