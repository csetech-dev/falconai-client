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
REALM_FALLBACK="${ROOT_DIR}/scripts/realm-falcon.json"
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

ensure_realm_file() {
  if [[ -d "${REALM_FILE}" ]]; then
    echo "WARNING: ${REALM_FILE} is a directory (Docker bind-mount bug when the file was missing)." >&2
    for nested in "${REALM_FILE}/realm-falcon.json" "${REALM_FILE}/realm.json"; do
      if [[ -f "${nested}" ]]; then
        local tmp="${REALM_FILE}.repair.$$"
        cp "${nested}" "${tmp}"
        rm -rf "${REALM_FILE}"
        mv "${tmp}" "${REALM_FILE}"
        echo "Repaired mount path: ${REALM_FILE} is now a regular file."
        return 0
      fi
    done
    rm -rf "${REALM_FILE}"
    echo "Removed mistaken directory ${REALM_FILE}." >&2
  fi

  if [[ -f "${REALM_FILE}" ]]; then
    return 0
  fi

  if [[ -f "${REALM_FALLBACK}" ]]; then
    mkdir -p "$(dirname "${REALM_FILE}")"
    cp "${REALM_FALLBACK}" "${REALM_FILE}"
    echo "Installed ${REALM_FILE} from scripts/realm-falcon.json"
    return 0
  fi

  echo "Missing realm file: ${REALM_FILE}" >&2
  echo "Re-pack the client bundle or copy infra/keycloak/realm-falcon.json from the vendor repo, then re-run." >&2
  exit 1
}

import_via_kcadm() {
  local import_err
  docker cp "${REALM_FILE}" "${KC_CONTAINER}:/tmp/realm-falcon.json"
  if import_err="$(kcadm create realms -f /tmp/realm-falcon.json 2>&1)"; then
    echo "Realm falcon imported via kcadm."
    return 0
  fi
  echo "kcadm create realms failed: ${import_err}" >&2
  return 1
}

recreate_keycloak() {
  ensure_realm_file
  if [[ ! -f "${REALM_FILE}" ]]; then
    echo "Cannot recreate Keycloak: ${REALM_FILE} must be a regular file." >&2
    exit 1
  fi

  echo "Recreating Keycloak so --import-realm loads ${REALM_FILE} ..."
  docker compose "${COMPOSE_ARGS[@]}" up -d --force-recreate keycloak

  echo "Waiting for Keycloak to start ..."
  local attempt
  for attempt in $(seq 1 30); do
    if docker exec "${KC_CONTAINER}" sh -c 'exec 3<>/dev/tcp/127.0.0.1/8080' 2>/dev/null; then
      break
    fi
    sleep 2
  done
}

echo "Checking Keycloak realm falcon ..."

if ! docker ps --format '{{.Names}}' | grep -qx "${KC_CONTAINER}"; then
  echo "Container ${KC_CONTAINER} is not running. Start the app stack first:" >&2
  echo "  cd ${ROOT_DIR} && make deploy-ghcr" >&2
  exit 1
fi

ensure_realm_file

kcadm config credentials \
  --server "${KC_BASE}" \
  --realm master \
  --user "${KC_ADMIN}" \
  --password "${KC_ADMIN_PASS}" >/dev/null

if realm_exists; then
  echo "Realm falcon already exists."
  exit 0
fi

echo "Realm falcon not found — importing from ${REALM_FILE} ..."

if import_via_kcadm && realm_exists; then
  exit 0
fi

recreate_keycloak

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
echo "Check file type: ls -la ${REALM_FILE}" >&2
echo "Check Keycloak logs: docker logs ${KC_CONTAINER} --tail 80" >&2
exit 1
