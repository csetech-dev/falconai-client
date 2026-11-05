#!/usr/bin/env bash
# Generate TLS + password material for the storage exporters (scaling plan P1.7b PR 1).
#
# Usage (on the STORAGE host, from the repo / bundle root, as root):
#   sudo scripts/deploy/monitoring-exporter-tls.sh --ip <storage-ip> [--out DIR] [--days 825] [--force]
# The scrape password is read from stdin: type it, then type it again.
#
# Writes into DIR (default infra/monitoring/exporter-tls, git-ignored):
#   ca.crt / ca.key           self-signed CA (ca.key: 600, root only)
#   server.crt / server.key   server certificate for IP:<storage-ip>, signed by the CA
#   web-config.yml            --web.config.file for both exporters: TLS + basic auth
#                             (user falcon_scrape, bcrypt hash only)
# Exporter-readable files are mode 640, group 65534 (the exporters' "nobody" user).
# Prints ca.crt on stdout: copy it to the app server for Prometheus (PR 2).
# The plaintext password is never written anywhere and never passed as an argument.
# Runbook: docs/db/scaling/p1-7b-1-exporter-tls.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUT="${ROOT_DIR}/infra/monitoring/exporter-tls"
DAYS=825
IP=""
FORCE=0
USER_NAME="falcon_scrape"
EXPORTER_GID=65534

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip) IP="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --days) DAYS="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

valid_ipv4() {
  local ip="$1" o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}
valid_ipv4 "$IP" || die "--ip must be the storage server's IPv4 address (got '${IP}'); the certificate needs an IP SAN."
[[ "$DAYS" =~ ^[0-9]+$ ]] || die "--days must be a number"
command -v openssl >/dev/null || die "openssl is required"

if [[ -e "${OUT}/ca.key" || -e "${OUT}/web-config.yml" ]] && [[ "$FORCE" -ne 1 ]]; then
  die "${OUT} already has TLS material. Re-run with --force to replace it (the app server then needs the new ca.crt)."
fi
if [[ -d "$OUT" && "$FORCE" -ne 1 ]] && [[ -n "$(ls -A "$OUT" 2>/dev/null)" ]]; then
  die "${OUT} is not empty. Re-run with --force to replace its contents."
fi

PW="" PW2=""
if [[ -t 0 ]]; then
  # Interactive: hide the input.
  IFS= read -rsp "Scrape password for ${USER_NAME} (16+ chars): " PW || true; echo >&2
  IFS= read -rsp "Same password again: " PW2 || true; echo >&2
else
  IFS= read -r PW || true
  IFS= read -r PW2 || true
fi
[[ -n "$PW" ]] || die "no password given on stdin"
(( ${#PW} >= 16 )) || die "password must be at least 16 characters"
[[ "$PW" == "$PW2" ]] || die "passwords do not match"

hash_password() {
  local line
  if command -v "${HTPASSWD_BIN:-htpasswd}" >/dev/null 2>&1; then
    line="$(printf '%s\n' "$PW" | "${HTPASSWD_BIN:-htpasswd}" -niBC 10 "$USER_NAME")"
  elif command -v docker >/dev/null 2>&1; then
    line="$(printf '%s\n' "$PW" | docker run --rm -i "${HTPASSWD_IMAGE:-httpd:2.4-alpine}" htpasswd -niBC 10 "$USER_NAME")"
  else
    die "need htpasswd (apt install apache2-utils) or docker to hash the password"
  fi
  line="${line%%$'\n'*}"
  [[ "$line" == "${USER_NAME}:\$2"* ]] || die "unexpected htpasswd output"
  printf '%s' "${line#"${USER_NAME}:"}"
}

mkdir -p "$(dirname "$OUT")"
TMP="$(mktemp -d "$(dirname "$OUT")/.exporter-tls.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

HASH="$(hash_password)"
unset PW PW2

(
  cd "$TMP"
  umask 077
  openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days "$DAYS" \
    -subj "/CN=falcon-exporters-ca" -keyout ca.key -out ca.crt 2>/dev/null
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -sha256 \
    -subj "/CN=${IP}" -keyout server.key -out server.csr 2>/dev/null
  printf 'subjectAltName=IP:%s\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' "$IP" > server.ext
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days "$DAYS" -sha256 -extfile server.ext -out server.crt 2>/dev/null
  rm -f server.csr server.ext ca.srl
  cat > web-config.yml <<EOF
tls_server_config:
  cert_file: /etc/exporter-tls/server.crt
  key_file: /etc/exporter-tls/server.key
basic_auth_users:
  ${USER_NAME}: '${HASH}'
EOF
)

chmod 600 "$TMP/ca.key"
chmod 640 "$TMP/ca.crt" "$TMP/server.crt" "$TMP/server.key" "$TMP/web-config.yml"
chmod 750 "$TMP"
if [[ "$(id -u)" -eq 0 ]]; then
  chgrp "$EXPORTER_GID" "$TMP" "$TMP/ca.crt" "$TMP/server.crt" "$TMP/server.key" "$TMP/web-config.yml"
fi

if [[ -d "$OUT" ]]; then
  if [[ "$FORCE" -eq 1 ]]; then
    rm -rf "$OUT"
  else
    # An empty folder is normal: compose creates the bind-mount source.
    rmdir "$OUT" 2>/dev/null || die "${OUT} is not empty. Re-run with --force to replace its contents."
  fi
fi
mv "$TMP" "$OUT"
trap - EXIT

echo "Wrote ${OUT} (valid ${DAYS} days, until $(openssl x509 -in "${OUT}/server.crt" -noout -enddate | cut -d= -f2))." >&2
echo "Copy this CA certificate to the app server (Prometheus, PR 2):" >&2
cat "${OUT}/ca.crt"
