#!/usr/bin/env bash
# Ensure the falcon Keycloak realm exists (GHCR clients ship realm-falcon.json in the bundle).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "${ROOT_DIR}/.env.app" ]]; then
  # shellcheck disable=SC1091
  set -a
  source <(grep -E '^(KEYCLOAK_ADMIN_USER|KEYCLOAK_ADMIN_PASSWORD|KEYCLOAK_HTTP_RELATIVE_PATH)=' "${ROOT_DIR}/.env.app" 2>/dev/null || true)
  set +a
fi

KC_CONTAINER="${KC_CONTAINER:-falcon-keycloak}"
KC_ADMIN="${KEYCLOAK_ADMIN_USER:-admin}"
KC_ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
KC_RELATIVE_PATH="${KEYCLOAK_HTTP_RELATIVE_PATH:-/}"
REALM_FILE="${ROOT_DIR}/infra/keycloak/realm-falcon.json"
COMPOSE_ARGS=(--env-file "${ROOT_DIR}/.env.app" -f "${ROOT_DIR}/docker-compose.app.yml")
if [[ -f "${ROOT_DIR}/docker-compose.ghcr.yml" ]]; then
  COMPOSE_ARGS+=(-f "${ROOT_DIR}/docker-compose.ghcr.yml")
fi

if [[ "${KC_RELATIVE_PATH}" != "/" ]]; then
  KC_BASE="http://localhost:8080${KC_RELATIVE_PATH}"
else
  KC_BASE="http://localhost:8080"
fi

kcadm() {
  docker exec "${KC_CONTAINER}" /opt/keycloak/bin/kcadm.sh "$@"
}

realm_exists() {
  kcadm get "realms/falcon" >/dev/null 2>&1
}

echo "Checking Keycloak realm falcon ..."

if ! docker ps --format '{{.Names}}' | grep -qx "${KC_CONTAINER}"; then
  echo "Container ${KC_CONTAINER} is not running. Start the app stack first:" >&2
  echo "  cd ${ROOT_DIR} && make deploy-ghcr" >&2
  exit 1
fi

kcadm config credentials \
  --server "${KC_BASE}" \
  --realm master \
  --user "${KC_ADMIN}" \
  --password "${KC_ADMIN_PASS}" >/dev/null

if realm_exists; then
  echo "Realm falcon already exists."
  exit 0
fi

if [[ ! -f "${REALM_FILE}" ]]; then
  echo "Missing ${REALM_FILE}" >&2
  echo "Re-pack the client bundle from the vendor repo (includes infra/keycloak/realm-falcon.json) or copy that file manually." >&2
  exit 1
fi

echo "Realm falcon not found — importing from ${REALM_FILE} ..."

docker cp "${REALM_FILE}" "${KC_CONTAINER}:/tmp/realm-falcon.json"

if kcadm create realms -f /tmp/realm-falcon.json 2>/dev/null; then
  echo "Realm falcon imported via kcadm."
  exit 0
fi

echo "kcadm import failed — recreating Keycloak with realm mount ..."
docker compose "${COMPOSE_ARGS[@]}" up -d --force-recreate keycloak

echo "Waiting for Keycloak to start ..."
sleep 15

kcadm config credentials \
  --server "${KC_BASE}" \
  --realm master \
  --user "${KC_ADMIN}" \
  --password "${KC_ADMIN_PASS}" >/dev/null

if realm_exists; then
  echo "Realm falcon is now available."
  exit 0
fi

echo "Realm falcon still missing after recreate." >&2
echo "Check: ls -la ${REALM_FILE}" >&2
echo "Check Keycloak logs: docker logs ${KC_CONTAINER} --tail 80" >&2
exit 1
