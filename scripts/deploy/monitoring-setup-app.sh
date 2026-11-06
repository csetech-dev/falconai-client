#!/usr/bin/env bash
# One-command monitoring setup for the APP server (scaling plan P1.9).
# Does everything P1.7b PR 2 + PR 3 did by hand: secrets in /etc/falcon-monitoring (from the storage
# server's hand-off line), monitoring.env, the Prometheus/Alertmanager/Grafana stack, and checks.
# Safe to re-run: steps that are already right report "unchanged".
#
#   sudo bash scripts/deploy/monitoring-setup-app.sh --handoff - --public-url https://<site> --dry-run
#   sudo bash scripts/deploy/monitoring-setup-app.sh --handoff - --public-url https://<site>
#     --handoff -     paste the FALCONMON1:... line printed by monitoring-setup-storage.sh (hidden prompt)
#     --handoff FILE  or read it from a root-owned chmod-600 file
# Options: --yes  --monitoring-env-file PATH (default /etc/falcon-monitoring/monitoring.env)  --verify-timeout SECONDS (180)
# Exit codes: 0 done and verified · 2 preflight refused · 4 verify failed
# Runbook: docs/db/scaling/p1-9-monitoring-setup.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=monitoring-setup-lib.sh
source "${SCRIPT_DIR}/monitoring-setup-lib.sh"

HANDOFF="" PUBLIC_URL="" VERIFY_TIMEOUT=180
MON_ENV="/etc/falcon-monitoring/monitoring.env"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MSL_DRY_RUN=1; shift ;;
    --yes) MSL_ASSUME_YES=1; shift ;;
    --handoff) HANDOFF="${2:-}"; shift 2 ;;
    --public-url) PUBLIC_URL="${2:-}"; shift 2 ;;
    --monitoring-env-file) MON_ENV="${2:-}"; shift 2 ;;
    --verify-timeout) VERIFY_TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) msl_fail "$MSL_EXIT_PREFLIGHT" "unknown argument: $1" ;;
  esac
done

APP_NETWORK="falcon-app_falcon-net"
WORK="$(mktemp -d)"; chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

msl_require_root

# ---------------------------------------------------------------- preflight
echo "== Preflight"
for f in docker-compose.monitoring.yml scripts/deploy/deploy-monitoring.sh scripts/deploy/monitoring-render.sh .env.monitoring.example; do
  [[ -f "${ROOT_DIR}/$f" ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "bundle file missing: $f (git pull --ff-only in ${ROOT_DIR})"
done
docker network inspect "$APP_NETWORK" > /dev/null 2>&1 || \
  msl_fail "$MSL_EXIT_PREFLIGHT" "Docker network ${APP_NETWORK} not found; run this on the APP server (with the app stack running)"
[[ -f "${ROOT_DIR}/.env.app" ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "missing ${ROOT_DIR}/.env.app; this is not an app deploy folder"
command -v python3 > /dev/null || msl_fail "$MSL_EXIT_PREFLIGHT" "python3 is needed for the checks (apt install python3)"
PUBLIC_URL="${PUBLIC_URL%/}"
[[ "$PUBLIC_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || \
  msl_fail "$MSL_EXIT_PREFLIGHT" "--public-url must be the site's https:// address with no path, e.g. https://app1.example.com"
avail_mb="$(free -m 2>/dev/null | awk '/^Mem:/ {print $7}')"
[[ -n "$avail_mb" && "$avail_mb" -lt 2560 ]] && echo "   ⚠️  only ${avail_mb} MB memory available; the stack needs about 2.5 GB"

# --- hand-off: a pasted FALCONMON1 line, or a root-owned 600 file
HF="${WORK}/handoff.env"
[[ -n "$HANDOFF" ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "give the hand-off with --handoff - (paste) or --handoff FILE"
if [[ "$HANDOFF" == "-" ]]; then
  line=""
  if [[ -t 0 ]]; then IFS= read -rs -p "Paste the FALCONMON1 hand-off line from the storage server: " line || true; echo >&2
  else IFS= read -r line || true; fi
  line="${line//[[:space:]]/}"
  [[ "$line" =~ ^FALCONMON1:([A-Za-z0-9+/=]+):([0-9a-f]{12})$ ]] || \
    msl_fail "$MSL_EXIT_PREFLIGHT" "that is not a complete hand-off line (it starts with FALCONMON1: and ends with 12 hex characters); copy it again"
  sum="${BASH_REMATCH[2]}"
  ( umask 077; printf '%s' "${BASH_REMATCH[1]}" | base64 -d > "$HF" 2>/dev/null ) || \
    msl_fail "$MSL_EXIT_PREFLIGHT" "the hand-off line is damaged (not valid base64); copy it again"
  [[ "$(sha256sum < "$HF" | cut -c1-12)" == "$sum" ]] || \
    msl_fail "$MSL_EXIT_PREFLIGHT" "the hand-off line's checksum does not match (incomplete copy?); copy it again"
else
  [[ -f "$HANDOFF" ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "hand-off file not found: $HANDOFF"
  [[ "$(stat -c '%a %u' "$HANDOFF")" == "600 0" ]] || \
    msl_fail "$MSL_EXIT_PREFLIGHT" "hand-off file must be owned by root with mode 600: $HANDOFF"
  cp "$HANDOFF" "$HF"; chmod 600 "$HF"
fi
STORAGE_IP="$(msl_get_env_key "$HF" STORAGE_IP)"
SCRAPE_PASSWORD="$(msl_get_env_key "$HF" SCRAPE_PASSWORD)"
CA_B64="$(msl_get_env_key "$HF" CA_PEM_B64)"
msl_valid_ipv4 "$STORAGE_IP" || msl_fail "$MSL_EXIT_PREFLIGHT" "hand-off has no valid STORAGE_IP"
[[ ${#SCRAPE_PASSWORD} -ge 16 ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "hand-off has no SCRAPE_PASSWORD"
CA_FILE="${WORK}/ca.crt"
( umask 077; printf '%s' "$CA_B64" | base64 -d > "$CA_FILE" 2>/dev/null ) && openssl x509 -in "$CA_FILE" -noout 2>/dev/null || \
  msl_fail "$MSL_EXIT_PREFLIGHT" "hand-off has no valid CA certificate"
# (The CA itself has no IP; the real scrape below checks the chain AND that the server certificate is for STORAGE_IP.)
NETRC="${WORK}/netrc"; ( umask 077; printf 'machine %s login falcon_scrape password %s\n' "$STORAGE_IP" "$SCRAPE_PASSWORD" > "$NETRC" )
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --netrc-file "$NETRC" --cacert "$CA_FILE" "https://${STORAGE_IP}:9187/metrics" || true)"
[[ "$code" == 200 ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "cannot scrape https://${STORAGE_IP}:9187 with the hand-off (HTTP ${code:-none}). Check the storage setup finished, and that this server may connect out to ${STORAGE_IP}:9187 and :9100."

SECRETS_DIR="$(msl_get_env_key "$MON_ENV" MONITORING_SECRETS_DIR)"; SECRETS_DIR="${SECRETS_DIR:-/etc/falcon-monitoring/secrets}"
echo "   storage: ${STORAGE_IP} (reachable with the hand-off)   site: ${PUBLIC_URL}   settings: ${MON_ENV}"
[[ "$MSL_DRY_RUN" -eq 1 ]] && echo "   DRY RUN: nothing will be changed."
[[ "$MSL_DRY_RUN" -eq 0 ]] && msl_confirm "Set up monitoring on this app server with these values?"

# ---------------------------------------------------------------- 1. secrets
echo "== Steps"
put_secret() {  # put_secret <name> <owner-uid> <content>
  local name="$1" uid="$2" content="$3" f="${SECRETS_DIR}/$1"
  if [[ -f "$f" ]] && [[ "$(cat "$f")" == "$content" ]] && [[ "$(stat -c '%a %u' "$f")" == "600 ${uid}" ]]; then
    msl_step secrets unchanged "$name"; return 0
  fi
  if [[ "$MSL_DRY_RUN" -eq 1 ]]; then msl_step secrets planned "$name"; return 0; fi
  ( umask 077; printf '%s' "$content" > "${f}.tmp" ) && mv -f "${f}.tmp" "$f"
  chown "${uid}:${uid}" "$f"; chmod 600 "$f"
  msl_step secrets changed "$name"
}
put_secret_file() {  # put_secret_file <name> <owner-uid> <source-file>  (byte-exact copy)
  local name="$1" uid="$2" src="$3" f="${SECRETS_DIR}/$1"
  if [[ -f "$f" ]] && cmp -s "$src" "$f" && [[ "$(stat -c '%a %u' "$f")" == "600 ${uid}" ]]; then
    msl_step secrets unchanged "$name"; return 0
  fi
  if [[ "$MSL_DRY_RUN" -eq 1 ]]; then msl_step secrets planned "$name"; return 0; fi
  ( umask 077; cp "$src" "${f}.tmp" ) && mv -f "${f}.tmp" "$f"
  chown "${uid}:${uid}" "$f"; chmod 600 "$f"
  msl_step secrets changed "$name"
}
existing() { [[ -s "${SECRETS_DIR}/$1" ]] && cat "${SECRETS_DIR}/$1" || true; }

if [[ -d "$SECRETS_DIR" && "$(stat -c '%a' "$SECRETS_DIR")" == 711 ]]; then
  msl_step secrets unchanged "folder ${SECRETS_DIR}"
elif [[ "$MSL_DRY_RUN" -eq 1 ]]; then
  msl_step secrets planned "folder ${SECRETS_DIR} (mode 711)"
else
  install -d -m 755 "$(dirname "$SECRETS_DIR")"; install -d -m 711 "$SECRETS_DIR"; chmod 711 "$SECRETS_DIR"
  msl_step secrets changed "folder ${SECRETS_DIR}"
fi

put_secret storage_exporter_password 65534 "$SCRAPE_PASSWORD"
put_secret_file storage_ca.crt 65534 "$CA_FILE"

TOKEN_NOTE=""
# METRICS_TOKEN as docker compose reads it: optional `export `, quotes, an inline # comment, CRLF.
app_token="$(awk '
  { sub(/\r$/, "") }
  /^[[:space:]]*(export[[:space:]]+)?METRICS_TOKEN=/ {
    v=$0; sub(/^[[:space:]]*(export[[:space:]]+)?METRICS_TOKEN=/, "", v)
    if (v ~ /^"/) { sub(/^"/, "", v); sub(/".*$/, "", v) }
    else if (v ~ /^\x27/) { sub(/^\x27/, "", v); sub(/\x27.*$/, "", v) }
    else { sub(/[[:space:]]+#.*$/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v) }
    t=v }
  END { printf "%s", t }' "${ROOT_DIR}/.env.app")"
if [[ -n "$app_token" ]]; then
  token="$app_token"
else
  token="$(existing metrics_token)"
  [[ -n "$token" ]] || token="$(msl_random_password)"
  TOKEN_NOTE="The app has no METRICS_TOKEN yet. Add METRICS_TOKEN=<value of ${SECRETS_DIR}/metrics_token> to ${ROOT_DIR}/.env.app (read it with: cat ${SECRETS_DIR}/metrics_token); the app picks it up at its next normal deploy."
fi
put_secret metrics_token 65534 "$token"

gpw="$(existing grafana_admin_password)"
[[ -n "$gpw" ]] || gpw="$(msl_random_password)"
put_secret grafana_admin_password 472 "$gpw"

# ---------------------------------------------------------------- 2. settings
if [[ -f "$MON_ENV" ]]; then
  msl_step settings unchanged "$MON_ENV exists"
elif [[ "$MSL_DRY_RUN" -eq 1 ]]; then
  msl_step settings planned "create $MON_ENV from .env.monitoring.example"
else
  install -d -m 755 "$(dirname "$MON_ENV")"
  ( umask 077; cp "${ROOT_DIR}/.env.monitoring.example" "$MON_ENV" ); chmod 600 "$MON_ENV"
  msl_step settings changed "created $MON_ENV"
fi
for kv in "STORAGE_SERVER_IP=${STORAGE_IP}" "MONITORING_PUBLIC_URL=${PUBLIC_URL}"; do
  if [[ "$MSL_DRY_RUN" -eq 1 && ! -f "$MON_ENV" ]]; then msl_step settings planned "${kv%%=*}"; continue; fi
  msl_set_env_key "$MON_ENV" "${kv%%=*}" "${kv#*=}"
  msl_step settings "$MSL_RESULT" "${kv%%=*}"
done

# ---------------------------------------------------------------- 3. stack
running="$(docker ps --filter name=falcon-prometheus --filter name=falcon-alertmanager --filter name=falcon-grafana --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -c ' Up' || true)"
if [[ "$MSL_CHANGED" -eq 0 && "$MSL_PLANNED" -eq 0 && "$running" -ge 3 ]]; then
  msl_step stack unchanged "Prometheus, Alertmanager, Grafana running with the current settings"
elif [[ "$MSL_DRY_RUN" -eq 1 ]]; then
  msl_step stack planned "deploy-monitoring.sh --check-only, then deploy"
  echo "== Dry run finished: nothing was changed."
  exit 0
else
  out="$(MONITORING_ENV_FILE="$MON_ENV" bash "${ROOT_DIR}/scripts/deploy/deploy-monitoring.sh" --check-only 2>&1)" || {
    echo "$out" >&2; msl_fail "$MSL_EXIT_PREFLIGHT" "config check failed (above); nothing started"; }
  out="$(MONITORING_ENV_FILE="$MON_ENV" bash "${ROOT_DIR}/scripts/deploy/deploy-monitoring.sh" 2>&1)" || {
    echo "$out" >&2; msl_fail "$MSL_EXIT_VERIFY" "deploy failed (above)"; }
  msl_step stack changed "configs checked and stack (re)started"
fi
[[ "$MSL_DRY_RUN" -eq 1 ]] && { echo "== Dry run finished: nothing was changed."; exit 0; }

# ---------------------------------------------------------------- 4. verify
echo "== Verify"
ok=1
deadline=$(( $(date +%s) + VERIFY_TIMEOUT ))
target_report=""
while :; do
  target_report="$(docker exec falcon-prometheus wget -qO- 'http://localhost:9090/api/v1/targets?state=active' 2>/dev/null | python3 -c '
import json,sys
try: t=json.load(sys.stdin)["data"]["activeTargets"]
except Exception: print("ERR"); sys.exit()
for x in t: print(x["labels"]["job"], x["health"], (x.get("lastError") or "").replace(" ","_"))' 2>/dev/null || echo ERR)"
  down="$(awk '$2!="up"' <<<"$target_report")"
  hard="$(awk '$2!="up" && !($1 ~ /^falcon-(core|search)$/ && $3 ~ /404/)' <<<"$target_report")"
  [[ "$target_report" != ERR && -z "$hard" && "$(wc -l <<<"$target_report")" -ge 6 ]] && break
  [[ $(date +%s) -ge $deadline ]] && break
  sleep 10
done
if [[ "$target_report" != ERR && -z "$down" && "$(wc -l <<<"$target_report")" -ge 6 ]]; then
  echo "✅ all 6 Prometheus targets up"
elif [[ "$target_report" != ERR && -z "$hard" ]]; then
  echo "⚠️  falcon-core / falcon-search down with 404: the app needs METRICS_TOKEN (see note below); everything else up"
else
  echo "❌ Prometheus targets not all up:"; sed 's/^/     /' <<<"$target_report"; ok=0
fi
if [[ -z "$(docker ps --filter name=falcon-prometheus --filter name=falcon-alertmanager --filter name=falcon-grafana --format '{{.Ports}}' | grep -E '0\.0\.0\.0|::' || true)" ]]; then
  echo "✅ no ports opened on the server"
else echo "❌ a monitoring container publishes a port"; ok=0; fi
forged="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 15 -H 'X-WEBAUTH-USER: admin' -H 'X-WEBAUTH-ROLE: Admin' "${PUBLIC_URL}/grafana/api/user" || true)"
if [[ "$forged" == 302* && "$forged" == *"?monitoring=signin"* ]]; then
  echo "✅ forged sign-in header refused (${PUBLIC_URL}/grafana/ → FalconAI sign-in)"
elif [[ "$forged" == 000* || -z "$forged" ]]; then
  echo "⚠️  could not reach ${PUBLIC_URL} from this server (common without hairpin NAT). Check from a browser instead: opening ${PUBLIC_URL}/grafana/ signed out must send you to FalconAI."
else
  echo "❌ ${PUBLIC_URL}/grafana/ did not refuse a forged sign-in header (got: ${forged:-no answer}); is the app release with Grafana sign-in deployed?"; ok=0
fi

[[ -n "$TOKEN_NOTE" ]] && echo "NOTE: ${TOKEN_NOTE}"
if [[ "$ok" -ne 1 ]]; then
  echo "Verify failed. Nothing was rolled back. To stop the stack (history kept):"
  echo "  cd ${ROOT_DIR} && docker compose --env-file ${MON_ENV} -f docker-compose.monitoring.yml down"
  exit "$MSL_EXIT_VERIFY"
fi
echo "== Done. Admins open Grafana from FalconAI: Administration → Monitoring."
echo "Clear your screen if you pasted the hand-off line (clear)."
