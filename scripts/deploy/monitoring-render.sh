#!/usr/bin/env bash
# Checks and config rendering for the monitoring stack (scaling plan P1.7b PR 2).
# Sourced by scripts/deploy/deploy-monitoring.sh; also sourceable on its own (tests).
#
# Reads: MONITORING_SECRETS_DIR (default /etc/falcon-monitoring/secrets)
#        MONITORING_CONFIG_DIR  (default /etc/falcon-monitoring/config)
#        STORAGE_SERVER_IP, MONITORING_PUBLIC_URL, POSTGRES_EXPORTER_PORT (9187), NODE_EXPORTER_PORT (9100), TELEGRAM_CHAT_ID
# Secrets are files, each owned by the container user that reads it, never world-readable:
#   metrics_token, storage_exporter_password, storage_ca.crt, telegram_bot_token (optional) -> uid 65534
#   grafana_admin_password                                                                  -> uid 472
# Rendered configs reference secrets by path only.

_MON_RENDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MON_ROOT="$(cd "${_MON_RENDER_DIR}/../.." && pwd)"

_mon_die() { echo "ERROR: $*" >&2; exit 1; }

_mon_secret_owner() {
  case "$1" in
    grafana_admin_password) echo 472 ;;
    *) echo 65534 ;;
  esac
}

_mon_valid_ipv4() {
  local ip="$1" o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}

_mon_check_secret_file() {
  local name="$1" f="${MONITORING_SECRETS_DIR:-/etc/falcon-monitoring/secrets}/$1" mode owner want
  [[ -f "$f" ]] || _mon_die "missing secret ${f} (see docs/db/scaling/p1-7b-2-monitoring-stack.md)"
  [[ -s "$f" ]] || _mon_die "secret ${f} is empty"
  mode="$(stat -c '%a' "$f")"
  (( (8#$mode & 8#007) == 0 )) || _mon_die "secret ${f} is readable by everyone (mode ${mode}); chmod 600 it"
  if [[ "$(id -u)" -eq 0 ]]; then
    want="$(_mon_secret_owner "$name")"
    owner="$(stat -c '%u' "$f")"
    [[ "$owner" == "$want" ]] || _mon_die "secret ${f} is owned by uid ${owner}; the container reads it as uid ${want}: chown ${want}:${want} ${f}"
  fi
}

monitoring_check_secrets() {
  local name
  for name in metrics_token storage_exporter_password storage_ca.crt grafana_admin_password; do
    _mon_check_secret_file "$name"
  done
  if [[ -e "${MONITORING_SECRETS_DIR:-/etc/falcon-monitoring/secrets}/telegram_bot_token" ]]; then
    _mon_check_secret_file telegram_bot_token
  fi
}

monitoring_check_inputs() {
  _mon_valid_ipv4 "${STORAGE_SERVER_IP:-}" || \
    _mon_die "STORAGE_SERVER_IP must be the storage server's IPv4 address (got '${STORAGE_SERVER_IP:-}'); the exporters' certificate is issued for that IP"
  local url="${MONITORING_PUBLIC_URL:-}"
  url="${url%/}"
  [[ "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || \
    _mon_die "MONITORING_PUBLIC_URL must be the site's public https:// address with no path, e.g. https://app1.example.com (got '${MONITORING_PUBLIC_URL:-}'); Grafana is served at <it>/grafana/"
  local token="${MONITORING_SECRETS_DIR:-/etc/falcon-monitoring/secrets}/telegram_bot_token"
  if [[ -n "${TELEGRAM_CHAT_ID:-}" && ! -e "$token" ]]; then
    _mon_die "TELEGRAM_CHAT_ID is set but ${token} does not exist; create telegram_bot_token or clear TELEGRAM_CHAT_ID"
  fi
  if [[ -e "$token" && -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    _mon_die "telegram_bot_token exists but TELEGRAM_CHAT_ID is empty; set it in .env.monitoring or remove the token file"
  fi
  if [[ -n "${TELEGRAM_CHAT_ID:-}" && ! "${TELEGRAM_CHAT_ID}" =~ ^-?[0-9]+$ ]]; then
    _mon_die "TELEGRAM_CHAT_ID must be a number (e.g. -1001234567890), got '${TELEGRAM_CHAT_ID}'"
  fi
}

_mon_write() {  # _mon_write <dest> <content>
  local dest="$1" tmp
  tmp="$(mktemp "${dest}.XXXXXX")"
  printf '%s\n' "$2" > "$tmp"
  chmod 644 "$tmp"   # no secrets inside; containers read it as a non-root uid
  mv -f "$tmp" "$dest"
}

monitoring_render() {
  monitoring_check_inputs
  local out="${MONITORING_CONFIG_DIR:-/etc/falcon-monitoring/config}"
  local pg_port="${POSTGRES_EXPORTER_PORT:-9187}" node_port="${NODE_EXPORTER_PORT:-9100}"
  [[ "$pg_port" =~ ^[0-9]+$ && "$node_port" =~ ^[0-9]+$ ]] || _mon_die "exporter ports must be numbers"
  mkdir -p "$out"

  local prom am receiver telegram=""
  prom="$(<"${_MON_ROOT}/infra/monitoring/prometheus/prometheus.yml.tmpl")"
  prom="${prom//@@STORAGE_SERVER_IP@@/${STORAGE_SERVER_IP}}"
  prom="${prom//@@POSTGRES_EXPORTER_PORT@@/${pg_port}}"
  prom="${prom//@@NODE_EXPORTER_PORT@@/${node_port}}"

  receiver="null"
  if [[ -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    receiver="telegram"
    telegram="  - name: 'telegram'
    telegram_configs:
      - bot_token_file: /run/falcon-secrets/telegram_bot_token
        chat_id: ${TELEGRAM_CHAT_ID}
        send_resolved: true"
  fi
  am="$(<"${_MON_ROOT}/infra/monitoring/alertmanager/alertmanager.yml.tmpl")"
  am="${am//@@RECEIVER_NAME@@/${receiver}}"
  am="${am//@@TELEGRAM_RECEIVER@@/${telegram}}"

  _mon_write "${out}/prometheus.yml" "$prom"
  _mon_write "${out}/alertmanager.yml" "$am"
}
