#!/usr/bin/env bash
# Provision existing Falcon users (from Postgres) into Keycloak for OIDC server-mode login.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "${ROOT_DIR}/.env.app" ]]; then
  # shellcheck disable=SC1091
  set -a
  source <(grep -E '^(POSTGRES_HOST|POSTGRES_PORT|POSTGRES_USER|POSTGRES_PASSWORD|KEYCLOAK_ADMIN_USER|KEYCLOAK_ADMIN_PASSWORD|OIDC_CLIENT_ID|OIDC_CLIENT_SECRET|KEYCLOAK_HTTP_RELATIVE_PATH)=' "${ROOT_DIR}/.env.app" 2>/dev/null || true)
  set +a
fi

PG_CONTAINER="${PG_CONTAINER:-falcon-postgres}"
KC_CONTAINER="${KC_CONTAINER:-falcon-keycloak}"
KC_ADMIN="${KEYCLOAK_ADMIN_USER:-admin}"
KC_ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
KC_RELATIVE_PATH="${KEYCLOAK_HTTP_RELATIVE_PATH:-/}"
FALCON_USER="${FALCON_USER:-}"
FALCON_PASS="${FALCON_PASS:-}"
ALL_LOCAL_USERS="${ALL_LOCAL_USERS:-false}"

if [[ "${KC_RELATIVE_PATH}" != "/" ]]; then
  KC_BASE="http://localhost:8080${KC_RELATIVE_PATH}"
else
  KC_BASE="http://localhost:8080"
fi

usage() {
  cat <<'EOF'
Provision Falcon users into Keycloak so they can sign in with OIDC server mode.

Usage:
  FALCON_USER='user@example.com' FALCON_PASS='TheirPassword!' \
    bash scripts/provision-keycloak-falcon-users.sh

  ALL_LOCAL_USERS=true FALCON_PASS='TempPass123!' \
    bash scripts/provision-keycloak-falcon-users.sh

Environment:
  FALCON_USER         Email of one user to provision (required unless ALL_LOCAL_USERS=true)
  FALCON_PASS         Password to set in Keycloak (required)
  ALL_LOCAL_USERS     When true, provision every LOCAL authProvider user from Postgres
  PG_CONTAINER        Postgres container name (default: falcon-postgres)
  KC_CONTAINER        Keycloak container name (default: falcon-keycloak)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${FALCON_PASS}" ]]; then
  echo "FALCON_PASS is required." >&2
  usage >&2
  exit 1
fi

if [[ "${ALL_LOCAL_USERS}" != "true" && -z "${FALCON_USER}" ]]; then
  echo "Set FALCON_USER or ALL_LOCAL_USERS=true." >&2
  usage >&2
  exit 1
fi

PG_USER="${POSTGRES_USER:-postgres}"
PG_DB="${POSTGRES_DB:-falcon_ai}"

kcadm() {
  docker exec "${KC_CONTAINER}" /opt/keycloak/bin/kcadm.sh "$@"
}

find_user_id() {
  local query_key="$1"
  local query_val="$2"
  kcadm get users -r falcon -q "${query_key}=${query_val}" \
    --fields id,username,email,enabled \
    --format csv --noquotes 2>/dev/null | tail -n1 | cut -d',' -f1
}

ensure_keycloak_user() {
  local email="$1"
  local username="$2"
  local first_name="$3"
  local last_name="$4"
  local roles_csv="$5"

  local user_id
  user_id="$(find_user_id email "${email}")"
  [[ -z "${user_id}" ]] && user_id="$(find_user_id username "${username}")"

  if [[ -z "${user_id}" ]]; then
    echo "Creating Keycloak user ${email} ..."
    kcadm create users -r falcon \
      -s "username=${username}" \
      -s "email=${email}" \
      -s enabled=true \
      -s emailVerified=true \
      -s "firstName=${first_name}" \
      -s "lastName=${last_name}" || true
    user_id="$(find_user_id email "${email}")"
  fi

  if [[ -z "${user_id}" ]]; then
    echo "Failed to create or resolve Keycloak user for ${email}" >&2
    return 1
  fi

  for role_name in ADMIN USER TECHNICAL MODERATOR; do
    kcadm create roles -r falcon -s "name=${role_name}" 2>/dev/null || true
  done

  if [[ -n "${roles_csv}" ]]; then
    IFS=',' read -ra role_parts <<< "${roles_csv}"
    for role_name in "${role_parts[@]}"; do
      [[ -z "${role_name}" ]] && continue
      kcadm add-roles -r falcon --uuserid "${user_id}" --rolename "${role_name}" 2>/dev/null || true
    done
  else
    kcadm add-roles -r falcon --uuserid "${user_id}" --rolename USER 2>/dev/null || true
  fi

  FALCON_USER="${email}" FALCON_PASS="${FALCON_PASS}" KC_CONTAINER="${KC_CONTAINER}" \
    bash "$(dirname "$0")/reset-keycloak-falcon-password.sh"
}

query_users() {
  if [[ "${ALL_LOCAL_USERS}" == "true" ]]; then
    docker exec "${PG_CONTAINER}" psql -U "${PG_USER}" -d "${PG_DB}" -At -F '|' -c \
      "SELECT email, username, COALESCE(\"firstName\", ''), COALESCE(\"lastName\", ''), array_to_string(roles, ',') FROM users WHERE \"authProvider\" = 'LOCAL' ORDER BY email;"
  else
    docker exec "${PG_CONTAINER}" psql -U "${PG_USER}" -d "${PG_DB}" -At -F '|' -c \
      "SELECT email, username, COALESCE(\"firstName\", ''), COALESCE(\"lastName\", ''), array_to_string(roles, ',') FROM users WHERE lower(email) = lower('${FALCON_USER}') OR username = '${FALCON_USER}' LIMIT 1;"
  fi
}

echo "Configuring kcadm against ${KC_BASE} ..."
kcadm config credentials \
  --server "${KC_BASE}" \
  --realm master \
  --user "${KC_ADMIN}" \
  --password "${KC_ADMIN_PASS}"

if ! kcadm get "realms/falcon" >/dev/null 2>&1; then
  bash "$(dirname "$0")/import-keycloak-falcon-realm.sh"
  kcadm config credentials \
    --server "${KC_BASE}" \
    --realm master \
    --user "${KC_ADMIN}" \
    --password "${KC_ADMIN_PASS}"
fi

mapfile -t rows < <(query_users || true)

if [[ "${#rows[@]}" -eq 0 || -z "${rows[0]}" ]]; then
  echo "No matching users found in Postgres." >&2
  exit 1
fi

echo "Provisioning ${#rows[@]} user(s) into Keycloak ..."

for row in "${rows[@]}"; do
  IFS='|' read -r email username first_name last_name roles_csv <<< "${row}"
  [[ -z "${email}" ]] && continue

  echo ""
  echo "==> ${email} (${username}) roles=${roles_csv:-USER}"
  ensure_keycloak_user "${email}" "${username}" "${first_name}" "${last_name}" "${roles_csv}"
done

echo ""
echo "Done. Users can sign in at the Falcon login page with the provisioned password."
