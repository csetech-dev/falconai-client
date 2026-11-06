#!/usr/bin/env bash
# One-command monitoring setup for the STORAGE server (scaling plan P1.9).
# Does everything P1.7a + P1.7b PR 1 did by hand: read-only Postgres role, exporter TLS + password,
# .env.storage settings, ufw rules for the app server, the two exporters, and a hand-off line for
# the app server. Safe to re-run: steps that are already right report "unchanged".
#
#   sudo bash scripts/deploy/monitoring-setup-storage.sh --dry-run      # show the plan, change nothing
#   sudo bash scripts/deploy/monitoring-setup-storage.sh                # apply (asks to confirm)
#   sudo bash scripts/deploy/monitoring-setup-storage.sh --print-handoff  # print the hand-off line again
#
# Options: --storage-ip IP  --app-ip IP  --yes  --rotate (new scrape password + certificate)
#          --handoff-file PATH (default /root/falcon-monitoring-handoff.env)
# Exit codes: 0 done and verified · 2 preflight refused · 3 compose guard tripped · 4 verify failed
# Runbook: docs/db/scaling/p1-9-monitoring-setup.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=monitoring-setup-lib.sh
source "${SCRIPT_DIR}/monitoring-setup-lib.sh"

STORAGE_IP_ARG="" APP_IP_ARG="" ROTATE=0 PRINT_ONLY=0
HANDOFF_FILE="/root/falcon-monitoring-handoff.env"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MSL_DRY_RUN=1; shift ;;
    --yes) MSL_ASSUME_YES=1; shift ;;
    --rotate) ROTATE=1; shift ;;
    --print-handoff) PRINT_ONLY=1; shift ;;
    --storage-ip) STORAGE_IP_ARG="${2:-}"; shift 2 ;;
    --app-ip) APP_IP_ARG="${2:-}"; shift 2 ;;
    --handoff-file) HANDOFF_FILE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) msl_fail "$MSL_EXIT_PREFLIGHT" "unknown argument: $1" ;;
  esac
done

ENV_FILE="${ROOT_DIR}/.env.storage"
TLS_DIR="${ROOT_DIR}/infra/monitoring/exporter-tls"

msl_require_root

if [[ "$PRINT_ONLY" -eq 1 ]]; then
  [[ -f "$HANDOFF_FILE" ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "no hand-off file at ${HANDOFF_FILE}; run the setup first"
  echo "Paste this line into the app server's setup (--handoff -). Then clear your screen (clear)."
  msl_handoff_line "$HANDOFF_FILE"
  exit 0
fi

# ---------------------------------------------------------------- preflight
echo "== Preflight"
for f in scripts/performance/create-monitor-role.sql scripts/deploy/monitoring-exporter-tls.sh docker-compose.storage.yml; do
  [[ -f "${ROOT_DIR}/$f" ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "bundle file missing: $f (git pull --ff-only in ${ROOT_DIR})"
done
grep -q 'MONITORING_BIND_IP' "${ROOT_DIR}/docker-compose.storage.yml" || \
  msl_fail "$MSL_EXIT_PREFLIGHT" "docker-compose.storage.yml has no TLS support yet; update the bundle"
[[ -n "$(docker ps --filter name='^falcon-postgres$' --format '{{.Names}}' 2>/dev/null)" ]] || \
  msl_fail "$MSL_EXIT_PREFLIGHT" "falcon-postgres is not running here; run this on the STORAGE server"
[[ -f "$ENV_FILE" ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "missing ${ENV_FILE}; this is not a storage deploy folder"

UFW_STATUS="$(ufw status verbose 2>/dev/null || true)"
grep -q '^Status: active' <<<"$UFW_STATUS" || \
  msl_fail "$MSL_EXIT_PREFLIGHT" "ufw is not active; publishing the exporters needs it (enable it yourself first, with an SSH allow rule)"
grep -q 'deny (incoming)' <<<"$UFW_STATUS" || \
  msl_fail "$MSL_EXIT_PREFLIGHT" "ufw does not deny incoming by default; the exporters would be reachable by anyone"

APP_IP="$APP_IP_ARG"
if [[ -z "$APP_IP" ]]; then
  APP_IP="$(ufw status verbose 2>/dev/null | awk '!f && $1=="12002/tcp" && $2=="ALLOW" && $3=="IN" && $4 ~ /^[0-9.]+$/ {print $4; f=1}')"
fi
msl_valid_ipv4 "$APP_IP" || msl_fail "$MSL_EXIT_PREFLIGHT" "give the app server's IP with --app-ip (could not detect it)"

STORAGE_IP="$STORAGE_IP_ARG"
if [[ -z "$STORAGE_IP" ]]; then
  STORAGE_IP="$(ip route get "$APP_IP" 2>/dev/null | awk '!f {for(i=1;i<NF;i++) if($i=="src" && !f){print $(i+1); f=1}}')"
fi
msl_valid_ipv4 "$STORAGE_IP" || msl_fail "$MSL_EXIT_PREFLIGHT" "give this server's IP (as the app server reaches it) with --storage-ip"
ip -4 -o addr show 2>/dev/null | grep -c "inet ${STORAGE_IP}/" > /dev/null || \
  msl_fail "$MSL_EXIT_PREFLIGHT" "${STORAGE_IP} is not an address of this server"

HAVE_TLS=0 HAVE_HANDOFF=0
[[ -f "${TLS_DIR}/web-config.yml" ]] && HAVE_TLS=1
[[ -f "$HANDOFF_FILE" ]] && HAVE_HANDOFF=1
if [[ "$ROTATE" -eq 0 && "$HAVE_TLS" -ne "$HAVE_HANDOFF" ]]; then
  msl_fail "$MSL_EXIT_PREFLIGHT" "TLS material and hand-off file are out of step (one exists without the other; e.g. a manual setup). Re-run with --rotate to issue a new scrape password + certificate (then re-run the app-server setup)."
fi

echo "   storage IP: ${STORAGE_IP}   app server IP: ${APP_IP}   hand-off: ${HANDOFF_FILE}"
[[ "$MSL_DRY_RUN" -eq 1 ]] && echo "   DRY RUN: nothing will be changed."
[[ "$MSL_DRY_RUN" -eq 0 ]] && msl_confirm "Set up monitoring on this storage server with these values?"

# ---------------------------------------------------------------- 1. role
echo "== Steps"
DB_PASSWORD="$(msl_get_env_key "$ENV_FILE" MONITOR_DB_PASSWORD)"
HAD_DB_PASSWORD=0; [[ -n "$DB_PASSWORD" ]] && HAD_DB_PASSWORD=1
if [[ "$MSL_DRY_RUN" -eq 1 ]]; then
  if [[ "$HAD_DB_PASSWORD" -eq 1 ]]; then msl_step role unchanged "falcon_monitor (password in .env.storage; re-checked on apply)"
  else msl_step role planned "create read-only role falcon_monitor with a generated password"; fi
else
  [[ "$HAD_DB_PASSWORD" -eq 1 ]] || DB_PASSWORD="$(msl_random_password)"
  PG_USER="$(msl_get_env_key "$ENV_FILE" POSTGRES_USER)"; PG_DB="$(msl_get_env_key "$ENV_FILE" POSTGRES_DB)"
  # The SQL is idempotent: it (re)creates the role and sets this password, so a role that is missing or
  # has a different password is repaired here rather than failing later in verify.
  role_out="$(MONITOR_DB_PASSWORD="$DB_PASSWORD" docker exec -i -e MONITOR_DB_PASSWORD falcon-postgres \
    psql -U "${PG_USER:-postgres}" -d "${PG_DB:-falcon_ai}" -v ON_ERROR_STOP=1 \
    < "${ROOT_DIR}/scripts/performance/create-monitor-role.sql" 2>&1)" || {
    echo "$role_out" >&2; msl_fail "$MSL_EXIT_PREFLIGHT" "creating/updating the read-only monitor role failed (above)"; }
  if [[ "$HAD_DB_PASSWORD" -eq 1 ]]; then msl_step role unchanged "falcon_monitor (checked)"
  else msl_step role changed "created falcon_monitor (pg_monitor, CONNECTION LIMIT 3)"; fi
fi

# ---------------------------------------------------------------- 2. TLS + scrape password
SCRAPE_PASSWORD=""
TLS_CHANGED=0
TLS_NEW="${TLS_DIR}.new"; HANDOFF_NEW="${HANDOFF_FILE}.new"
if [[ "$HAVE_TLS" -eq 1 && "$HAVE_HANDOFF" -eq 1 && "$ROTATE" -eq 0 ]]; then
  SCRAPE_PASSWORD="$(msl_get_env_key "$HANDOFF_FILE" SCRAPE_PASSWORD)"
  msl_step tls unchanged "certificate for ${STORAGE_IP} and scrape password exist"
elif [[ "$MSL_DRY_RUN" -eq 1 ]]; then
  msl_step tls planned "generate scrape password + certificate for ${STORAGE_IP}"
else
  # Generate into a staging folder and record the new password in a hand-off .new file straight away.
  # The working folder and hand-off are only swapped in after the compose guard passes, so a failure
  # in between leaves the running exporters and the current hand-off exactly as they were.
  SCRAPE_PASSWORD="$(msl_random_password)"
  rm -rf "$TLS_NEW"
  tls_err="$(printf '%s\n%s\n' "$SCRAPE_PASSWORD" "$SCRAPE_PASSWORD" | \
    bash "${ROOT_DIR}/scripts/deploy/monitoring-exporter-tls.sh" --ip "$STORAGE_IP" --out "$TLS_NEW" 2>&1 >/dev/null)" || {
    echo "$tls_err" >&2; msl_fail "$MSL_EXIT_PREFLIGHT" "generating the certificate failed (above)"; }
  ( umask 077; printf 'STORAGE_IP=%s\nSCRAPE_PASSWORD=%s\nCA_PEM_B64=%s\n' "$STORAGE_IP" "$SCRAPE_PASSWORD" \
      "$(base64 -w0 < "${TLS_NEW}/ca.crt")" > "$HANDOFF_NEW" )
  chmod 600 "$HANDOFF_NEW"
  TLS_CHANGED=1
  msl_step tls changed "new scrape password + certificate for ${STORAGE_IP} (staged)"
fi

# ---------------------------------------------------------------- 3. .env.storage
ENV_CHANGED=0
if [[ "$MSL_DRY_RUN" -eq 1 && -z "$DB_PASSWORD" ]]; then DB_VALUE="<generated>"; else DB_VALUE="$DB_PASSWORD"; fi
for kv in "MONITORING_ENABLED=true" "MONITOR_DB_USER=falcon_monitor" "MONITOR_DB_PASSWORD=${DB_VALUE}" \
          "MONITORING_BIND_IP=${STORAGE_IP}" "EXPORTER_WEB_CONFIG=/etc/exporter-tls/web-config.yml"; do
  key="${kv%%=*}"
  [[ "$MSL_DRY_RUN" -eq 1 && "$DB_VALUE" == "<generated>" && "$key" == MONITOR_DB_PASSWORD ]] && { msl_step env planned "$key"; continue; }
  msl_set_env_key "$ENV_FILE" "$key" "${kv#*=}"
  [[ "$MSL_RESULT" == changed ]] && ENV_CHANGED=1
  msl_step env "$MSL_RESULT" "$key"
done
if [[ "$MSL_DRY_RUN" -eq 0 ]]; then
  check_dir="$TLS_DIR"; [[ "$TLS_CHANGED" -eq 1 ]] && check_dir="$TLS_NEW"
  ( set -a; source <(tr -d '\r' < "$ENV_FILE"); set +a; EXPORTER_TLS_DIR="$check_dir" monitoring_exposure_check ) || \
    msl_fail "$MSL_EXIT_PREFLIGHT" "exposure check failed (see above); nothing published"
fi

# ---------------------------------------------------------------- 4. ufw
for port in 9187 9100; do
  if ufw status verbose 2>/dev/null | grep -cE "^${port}/tcp +ALLOW IN +${APP_IP//./\\.}( |$)" > /dev/null; then
    msl_step ufw unchanged "${APP_IP} -> ${port}/tcp allowed"
  elif [[ "$MSL_DRY_RUN" -eq 1 ]]; then
    msl_step ufw planned "allow ${APP_IP} -> ${port}/tcp"
  else
    ufw allow from "$APP_IP" to any port "$port" proto tcp comment "falcon prometheus ${port}" > /dev/null
    msl_step ufw changed "allowed ${APP_IP} -> ${port}/tcp"
  fi
done

# ---------------------------------------------------------------- 5. exporters (compose)
running="$(docker ps --filter name=falcon-postgres-exporter --filter name=falcon-node-exporter --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -c ' Up' || true)"
scrape_ok() {  # the running exporters really serve the current certificate + password
  [[ -n "$SCRAPE_PASSWORD" && -f "${TLS_DIR}/ca.crt" ]] || return 1
  local nrc; nrc="$(mktemp)"; chmod 600 "$nrc"
  printf 'machine %s login falcon_scrape password %s\n' "$STORAGE_IP" "$SCRAPE_PASSWORD" > "$nrc"
  curl -s --max-time 10 --netrc-file "$nrc" --cacert "${TLS_DIR}/ca.crt" "https://${STORAGE_IP}:9187/metrics" 2>/dev/null | grep -c '^pg_up 1' > /dev/null
  local rc=$?; rm -f "$nrc"; return $rc
}
if [[ "$ENV_CHANGED" -eq 0 && "$TLS_CHANGED" -eq 0 && "$MSL_PLANNED" -eq 0 && "$running" -ge 2 ]] && scrape_ok; then
  msl_step exporters unchanged "both running with the current settings"
elif [[ "$MSL_DRY_RUN" -eq 1 ]]; then
  msl_step exporters planned "(re)create only postgres-exporter + node-exporter (guarded dry run first)"
else
  detect_compose
  resolve_sizing_file_quiet "$ENV_FILE"
  # Same bind as deploy-storage.sh, read from .env.storage (not the shell).
  WIREGUARD_ENABLED="$(msl_get_env_key "$ENV_FILE" WIREGUARD_ENABLED)"; WIREGUARD_ENABLED="${WIREGUARD_ENABLED:-true}"
  if wireguard_enabled; then export STORAGE_BIND_IP="127.0.0.1"; else export STORAGE_BIND_IP="0.0.0.0"; fi
  DC=("${COMPOSE[@]}" --env-file "$SIZING_ENV_FILE" --env-file "$ENV_FILE" -f "${ROOT_DIR}/docker-compose.storage.yml" --profile monitoring)
  [[ "$TLS_CHANGED" -eq 1 ]] && export EXPORTER_TLS_DIR="$TLS_NEW"   # dry-run against the staged material
  # --force-recreate: the TLS folder is mounted by PATH. After a swap the path is the same, so a plain
  # `up -d` sees no change and leaves the exporters on the old (deleted) folder (found on stage).
  plan_rc=0; plan_out="$("${DC[@]}" up -d --no-deps --force-recreate --dry-run postgres-exporter node-exporter 2>&1)" || plan_rc=$?
  unset EXPORTER_TLS_DIR
  # Fail closed: the dry run must succeed and must show the exporters; anything else that would be
  # created/recreated/started/stopped/removed (a container other than the two exporters, a network,
  # a volume) trips the guard. Status-only lines (Running/Waiting/Healthy) for dependencies are fine.
  bad="$(awk '
    function act(s) { return s ~ /(Creat|Recreat|Start|Stop|Restart|Remov|Kill)/ }
    (/ Network / || / Volume /) && act($0) { print; next }
    / Container / { for (i=1;i<=NF;i++) if ($i=="Container") { n=$(i+1);
                    if (n ~ /^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]_/) n=substr(n,14);
                    if (n!="falcon-postgres-exporter" && n!="falcon-node-exporter" && act($0)) print } }' <<<"$plan_out")"
  if [[ "$plan_rc" -ne 0 || -n "$bad" ]] || ! grep -q 'falcon-postgres-exporter' <<<"$plan_out"; then
    echo "$plan_out" >&2
    msl_fail "$MSL_EXIT_GUARD" "the compose dry run failed or would touch more than the two exporters (above); nothing started, current setup unchanged"
  fi
  if [[ "$TLS_CHANGED" -eq 1 ]]; then   # guard passed: swap the staged material + hand-off in
    rm -rf "${TLS_DIR}.old"; [[ -d "$TLS_DIR" ]] && mv "$TLS_DIR" "${TLS_DIR}.old"
    mv "$TLS_NEW" "$TLS_DIR"; mv -f "$HANDOFF_NEW" "$HANDOFF_FILE"; rm -rf "${TLS_DIR}.old"
  fi
  up_out="$("${DC[@]}" up -d --no-deps --force-recreate postgres-exporter node-exporter 2>&1)" || {
    echo "$up_out" >&2; msl_fail "$MSL_EXIT_VERIFY" "starting the exporters failed (above); re-run this script after fixing it"; }
  msl_step exporters changed "postgres-exporter + node-exporter (re)created"
fi

# ---------------------------------------------------------------- 6. hand-off
if [[ "$MSL_DRY_RUN" -eq 1 ]]; then
  if [[ "$HAVE_HANDOFF" -eq 1 && "$ROTATE" -eq 0 ]]; then msl_step handoff unchanged "$HANDOFF_FILE"
  else msl_step handoff planned "write $HANDOFF_FILE and print the line for the app server"; fi
  echo "== Dry run finished: nothing was changed."
  exit 0
fi
if [[ "$TLS_CHANGED" -eq 1 && -f "$HANDOFF_NEW" ]]; then   # exporters were unchanged but TLS staged: swap now
  rm -rf "${TLS_DIR}.old"; [[ -d "$TLS_DIR" ]] && mv "$TLS_DIR" "${TLS_DIR}.old"
  mv "$TLS_NEW" "$TLS_DIR"; mv -f "$HANDOFF_NEW" "$HANDOFF_FILE"; rm -rf "${TLS_DIR}.old"
fi
new_handoff="$(printf 'STORAGE_IP=%s\nSCRAPE_PASSWORD=%s\nCA_PEM_B64=%s\n' "$STORAGE_IP" "$SCRAPE_PASSWORD" "$(base64 -w0 < "${TLS_DIR}/ca.crt")")"
HANDOFF_CHANGED=0
if [[ -f "$HANDOFF_FILE" ]] && [[ "$(cat "$HANDOFF_FILE")" == "$new_handoff" ]]; then
  if [[ "$TLS_CHANGED" -eq 1 ]]; then HANDOFF_CHANGED=1; msl_step handoff changed "$HANDOFF_FILE"
  else msl_step handoff unchanged "$HANDOFF_FILE"; fi
else
  ( umask 077; printf '%s\n' "$new_handoff" > "${HANDOFF_FILE}.tmp" ) && mv -f "${HANDOFF_FILE}.tmp" "$HANDOFF_FILE"
  chmod 600 "$HANDOFF_FILE"
  HANDOFF_CHANGED=1
  msl_step handoff changed "$HANDOFF_FILE"
fi

# ---------------------------------------------------------------- 7. verify
echo "== Verify"
ok=1
# Freshly (re)created exporters need a few seconds before they answer HTTPS: wait up to 30 s.
for _ in $(seq 1 30); do
  c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --cacert "${TLS_DIR}/ca.crt" "https://${STORAGE_IP}:9187/metrics" 2>/dev/null || true)"
  [[ -n "$c" && "$c" != 000 ]] && break
  sleep 1
done
check() { if eval "$2"; then echo "✅ $1"; else echo "❌ $1"; ok=0; fi; }
CA="${TLS_DIR}/ca.crt"
NETRC="$(mktemp)"; chmod 600 "$NETRC"
trap 'rm -f "$NETRC"' EXIT
printf 'machine %s login falcon_scrape password %s\n' "$STORAGE_IP" "$SCRAPE_PASSWORD" > "$NETRC"
check "both exporters running" '[[ "$(docker ps --filter name=falcon-postgres-exporter --filter name=falcon-node-exporter --format "{{.Names}} {{.Status}}" | grep -c " Up")" -ge 2 ]]'
check "listening only on ${STORAGE_IP}" '[[ "$(ss -ltnH 2>/dev/null | grep -E ":(9187|9100)\b" | grep -vc "${STORAGE_IP}:")" -eq 0 && "$(ss -ltnH 2>/dev/null | grep -cE "${STORAGE_IP//./\\.}:(9187|9100)\b")" -ge 2 ]]'
check "request without password refused (401)" '[[ "$(curl -s -o /dev/null -w "%{http_code}" --cacert "$CA" "https://${STORAGE_IP}:9187/metrics")" == 401 ]]'
check "request with password: pg_up 1" 'curl -s --netrc-file "$NETRC" --cacert "$CA" "https://${STORAGE_IP}:9187/metrics" | grep -c "^pg_up 1" > /dev/null'
check "node exporter answers with password" '[[ "$(curl -s -o /dev/null -w "%{http_code}" --netrc-file "$NETRC" --cacert "$CA" "https://${STORAGE_IP}:9100/metrics")" == 200 ]]'

if [[ "$ok" -ne 1 ]]; then
  echo "Verify failed. Nothing was rolled back. To undo: set MONITORING_BIND_IP=127.0.0.1 and EXPORTER_WEB_CONFIG= in .env.storage, then"
  echo "  docker compose --env-file ${SIZING_ENV_FILE:-.env.sizing.<profile>} --env-file .env.storage -f docker-compose.storage.yml --profile monitoring up -d --no-deps --force-recreate postgres-exporter node-exporter"
  exit "$MSL_EXIT_VERIFY"
fi

echo "== Done."
if [[ "$HANDOFF_CHANGED" -eq 1 ]]; then
  echo "Next, on the APP server run monitoring-setup-app.sh --handoff - and paste this line when asked."
  echo "Then clear this screen (clear). Print it again any time with --print-handoff."
  msl_handoff_line "$HANDOFF_FILE"
fi
