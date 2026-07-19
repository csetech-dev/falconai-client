#!/usr/bin/env bash
# Test Keycloak password grant directly (bypasses falcon-auth).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "${ROOT_DIR}/.env.app" ]]; then
  # shellcheck disable=SC1091
  set -a
  source <(grep -E '^(OIDC_CLIENT_ID|OIDC_CLIENT_SECRET|KEYCLOAK_HTTP_RELATIVE_PATH)=' "${ROOT_DIR}/.env.app" 2>/dev/null || true)
  set +a
fi

KC_CONTAINER="${KC_CONTAINER:-falcon-keycloak}"
USERNAME="${1:-admin}"
PASSWORD="${2:-Admin123!}"
CLIENT_ID="${OIDC_CLIENT_ID:-falcon-web}"
CLIENT_SECRET="${OIDC_CLIENT_SECRET:-falcon-oidc-client-secret}"
KC_RELATIVE_PATH="${KEYCLOAK_HTTP_RELATIVE_PATH:-/}"
SCOPE="${OIDC_SCOPES:-openid email profile roles}"

if [[ "${KC_RELATIVE_PATH}" != "/" ]]; then
  TOKEN_PATH="${KC_RELATIVE_PATH%/}/realms/falcon/protocol/openid-connect/token"
else
  TOKEN_PATH="/realms/falcon/protocol/openid-connect/token"
fi

echo "Token URL: http://localhost:8080${TOKEN_PATH}"
echo "Username: ${USERNAME}"
echo "Client: ${CLIENT_ID}"

if ! docker exec "${KC_CONTAINER}" sh -c 'command -v curl >/dev/null 2>&1'; then
  echo "ERROR: curl is not available inside ${KC_CONTAINER}" >&2
  exit 1
fi

response="$(docker exec "${KC_CONTAINER}" curl -s -w "\n%{http_code}" -X POST \
  "http://localhost:8080${TOKEN_PATH}" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=password" \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "client_secret=${CLIENT_SECRET}" \
  --data-urlencode "username=${USERNAME}" \
  --data-urlencode "password=${PASSWORD}" \
  --data-urlencode "scope=${SCOPE}")"

body="$(echo "${response}" | sed '$d')"
status="$(echo "${response}" | tail -n1)"

echo "HTTP ${status}"
echo "${body}"

if [[ "${status}" == "200" ]]; then
  echo "OK — Keycloak accepted these credentials."
  exit 0
fi

echo "FAILED — fix Keycloak user password or client settings before testing falcon-auth." >&2
exit 1
