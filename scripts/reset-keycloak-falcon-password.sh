#!/usr/bin/env bash
# Reset falcon realm user password and clear brute-force lockouts.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "${ROOT_DIR}/.env.app" ]]; then
  # shellcheck disable=SC1091
  set -a
  source <(grep -E '^(OIDC_CLIENT_ID|OIDC_CLIENT_SECRET|KEYCLOAK_ADMIN_USER|KEYCLOAK_ADMIN_PASSWORD|KEYCLOAK_HTTP_RELATIVE_PATH)=' "${ROOT_DIR}/.env.app" 2>/dev/null || true)
  set +a
fi

KC_CONTAINER="${KC_CONTAINER:-falcon-keycloak}"
KC_ADMIN="${KEYCLOAK_ADMIN_USER:-admin}"
KC_ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
FALCON_USER="${FALCON_USER:-}"
FALCON_PASS="${FALCON_PASS:-Admin123!}"
CLIENT_ID="${OIDC_CLIENT_ID:-falcon-web}"
CLIENT_SECRET="${OIDC_CLIENT_SECRET:-falcon-oidc-client-secret}"
KC_RELATIVE_PATH="${KEYCLOAK_HTTP_RELATIVE_PATH:-/}"

if [[ "${KC_RELATIVE_PATH}" != "/" ]]; then
  KC_BASE="http://localhost:8080${KC_RELATIVE_PATH}"
else
  KC_BASE="http://localhost:8080"
fi

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

verify_password_grant() {
  local username="$1"
  echo "  trying username: ${username}"
  if OIDC_CLIENT_SECRET="${CLIENT_SECRET}" OIDC_CLIENT_ID="${CLIENT_ID}" \
    bash "$(dirname "$0")/test-keycloak-password-grant.sh" "${username}" "${FALCON_PASS}"; then
    return 0
  fi
  return 1
}

echo "Configuring kcadm against ${KC_BASE} ..."
kcadm config credentials \
  --server "${KC_BASE}" \
  --realm master \
  --user "${KC_ADMIN}" \
  --password "${KC_ADMIN_PASS}"

echo "Users in realm falcon:"
kcadm get users -r falcon --fields id,username,email,enabled || true

client_id="$(kcadm get clients -r falcon -q "clientId=${CLIENT_ID}" --fields id --format csv --noquotes 2>/dev/null | tail -n1 | tr -d '\r')"
if [[ -n "${client_id}" ]]; then
  echo "Configuring ${CLIENT_ID} (${client_id}) ..."
  kcadm update "clients/${client_id}" -r falcon \
    -s directAccessGrantsEnabled=true \
    -s publicClient=false \
    -s 'clientAuthenticatorType=client-secret' \
    -s "secret=${CLIENT_SECRET}" || true

  stored_secret="$(kcadm get "clients/${client_id}/client-secret" -r falcon --fields value --format csv --noquotes 2>/dev/null | tail -n1 | tr -d '\r' || true)"
  echo "Client secret in Keycloak: ${stored_secret:-<unknown>}"
  echo "Client secret expected:   ${CLIENT_SECRET}"
else
  echo "WARNING: client ${CLIENT_ID} not found in realm falcon." >&2
fi

user_id=""
if [[ -n "${FALCON_USER}" ]]; then
  user_id="$(find_user_id username "${FALCON_USER}")"
  [[ -z "${user_id}" ]] && user_id="$(find_user_id email "${FALCON_USER}")"
fi
for candidate in admin admin@falconai.com admin@falconai.local; do
  [[ -n "${user_id}" ]] && break
  user_id="$(find_user_id username "${candidate}")"
  [[ -z "${user_id}" ]] && user_id="$(find_user_id email "${candidate}")"
done

if [[ -z "${user_id}" ]]; then
  echo "No falcon realm user found. Create one in Keycloak admin or re-import the realm." >&2
  exit 1
fi

echo "Clearing brute-force lock for user id ${user_id} ..."
kcadm delete "realms/falcon/attack-detection/brute-force/users/${user_id}" 2>/dev/null || true

echo "Ensuring user is enabled with no required actions ..."
kcadm update "users/${user_id}" -r falcon -s enabled=true -s 'requiredActions=[]' || true

echo "Setting password for user id ${user_id} ..."
kcadm set-password -r falcon --userid "${user_id}" --new-password "${FALCON_PASS}" --temporary=false 2>/dev/null \
  || kcadm set-password -r falcon --userid "${user_id}" --new-password "${FALCON_PASS}"

echo "Ensuring Falcon realm roles exist ..."
for role_name in ADMIN USER TECHNICAL MODERATOR; do
  kcadm create roles -r falcon -s "name=${role_name}" 2>/dev/null || true
done

echo "Assigning ADMIN + USER roles to ${user_id} ..."
kcadm add-roles -r falcon --uuserid "${user_id}" --rolename ADMIN --rolename USER 2>/dev/null || true

resolved="$(kcadm get "users/${user_id}" -r falcon --fields username,email --format csv --noquotes 2>/dev/null | tail -n1)"
username="$(echo "${resolved}" | cut -d',' -f1)"
email="$(echo "${resolved}" | cut -d',' -f2)"

echo "Password updated for user: ${resolved}"
echo ""
echo "Verifying password grant with Keycloak ..."

grant_ok=false
for candidate in "${username}" "${email}" admin; do
  [[ -z "${candidate}" ]] && continue
  if verify_password_grant "${candidate}"; then
    grant_ok=true
    break
  fi
done

if [[ "${grant_ok}" != "true" ]]; then
  echo "" >&2
  echo "WARNING: password grant test failed." >&2
  echo "Check:" >&2
  echo "  1. OIDC_CLIENT_SECRET in .env.app matches Keycloak client ${CLIENT_ID}" >&2
  echo "  2. directAccessGrantsEnabled=true on ${CLIENT_ID}" >&2
  echo "  3. Password is correct (FALCON_PASS=${FALCON_PASS})" >&2
  echo "  4. Try: bash scripts/test-keycloak-password-grant.sh admin '${FALCON_PASS}'" >&2
  exit 1
fi

echo ""
echo "Sign in on Falcon with:"
echo "  email/username: ${username} or admin or ${email}"
echo "  password: ${FALCON_PASS}"
