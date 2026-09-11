#!/usr/bin/env bash
# Generate a WireGuard keypair for each side of the app<->storage tunnel plus a
# shared preshared key, and print ready-to-paste wg0.conf files for both hosts.
#
# No host-level WireGuard tooling required — keys are minted inside the
# linuxserver/wireguard image via Docker. See docs/WIREGUARD_STORAGE_TUNNEL.md.
#
# Usage:
#   bash scripts/gen-wireguard-keys.sh                     # prompts for storage public IP
#   STORAGE_PUBLIC_IP=203.0.113.10 bash scripts/gen-wireguard-keys.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WG_IMAGE="${WG_IMAGE:-linuxserver/wireguard:latest}"
WG_PORT="${WG_LISTEN_PORT:-51820}"

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { printf '%b==>%b %s\n' "${BLUE}" "${NC}" "$*"; }
ok()   { printf '%b ✓ %b%s\n' "${GREEN}" "${NC}" "$*"; }
warn() { printf '%b ! %b%s\n' "${YELLOW}" "${NC}" "$*"; }

command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 1; }

STORAGE_PUBLIC_IP="${STORAGE_PUBLIC_IP:-}"
if [[ -z "${STORAGE_PUBLIC_IP}" ]]; then
  read -r -p "Storage host PUBLIC IP or DNS (used as the app peer Endpoint): " STORAGE_PUBLIC_IP
fi
[[ -n "${STORAGE_PUBLIC_IP}" ]] || { echo "STORAGE_PUBLIC_IP is required" >&2; exit 1; }

log "Generating keys via ${WG_IMAGE} ..."
# One container run mints all three keys (keeps the image pull to once).
read -r STORAGE_PRIV STORAGE_PUB APP_PRIV APP_PUB PSK < <(
  docker run --rm --entrypoint sh "${WG_IMAGE}" -c '
    sp=$(wg genkey); spp=$(printf %s "$sp" | wg pubkey);
    ap=$(wg genkey); app=$(printf %s "$ap" | wg pubkey);
    psk=$(wg genpsk);
    printf "%s %s %s %s %s\n" "$sp" "$spp" "$ap" "$app" "$psk"
  '
)
ok "Keys generated."

STORAGE_CONF="$(cat <<EOF
# infra/wireguard/storage/wg0.conf  (STORAGE host, 10.9.0.1)
[Interface]
Address = 10.9.0.1/24
ListenPort = ${WG_PORT}
PrivateKey = ${STORAGE_PRIV}

PostUp   = iptables -t nat -A PREROUTING  -i wg0 -p tcp --dport 12002 -j DNAT --to-destination 172.29.0.10:5432
PostUp   = iptables -t nat -A PREROUTING  -i wg0 -p tcp --dport 12004 -j DNAT --to-destination 172.29.0.11:9000
PostUp   = iptables -t nat -A PREROUTING  -i wg0 -p tcp --dport 12015 -j DNAT --to-destination 172.29.0.11:9001
PostUp   = iptables -t nat -A POSTROUTING -d 172.29.0.0/16 -j MASQUERADE
PostDown = iptables -t nat -D PREROUTING  -i wg0 -p tcp --dport 12002 -j DNAT --to-destination 172.29.0.10:5432
PostDown = iptables -t nat -D PREROUTING  -i wg0 -p tcp --dport 12004 -j DNAT --to-destination 172.29.0.11:9000
PostDown = iptables -t nat -D PREROUTING  -i wg0 -p tcp --dport 12015 -j DNAT --to-destination 172.29.0.11:9001
PostDown = iptables -t nat -D POSTROUTING -d 172.29.0.0/16 -j MASQUERADE

[Peer]
# App host
PublicKey = ${APP_PUB}
PresharedKey = ${PSK}
AllowedIPs = 10.9.0.2/32
PersistentKeepalive = 25
EOF
)"

APP_CONF="$(cat <<EOF
# infra/wireguard/app/wg0.conf  (APP host, 10.9.0.2)
[Interface]
Address = 10.9.0.2/24
ListenPort = ${WG_PORT}
PrivateKey = ${APP_PRIV}

PostUp   = iptables -t nat -A PREROUTING  -p tcp --dport 12002 -j DNAT --to-destination 10.9.0.1:12002
PostUp   = iptables -t nat -A PREROUTING  -p tcp --dport 12004 -j DNAT --to-destination 10.9.0.1:12004
PostUp   = iptables -t nat -A PREROUTING  -p tcp --dport 12015 -j DNAT --to-destination 10.9.0.1:12015
PostUp   = iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
PostDown = iptables -t nat -D PREROUTING  -p tcp --dport 12002 -j DNAT --to-destination 10.9.0.1:12002
PostDown = iptables -t nat -D PREROUTING  -p tcp --dport 12004 -j DNAT --to-destination 10.9.0.1:12004
PostDown = iptables -t nat -D PREROUTING  -p tcp --dport 12015 -j DNAT --to-destination 10.9.0.1:12015
PostDown = iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE

[Peer]
# Storage host
PublicKey = ${STORAGE_PUB}
PresharedKey = ${PSK}
Endpoint = ${STORAGE_PUBLIC_IP}:${WG_PORT}
AllowedIPs = 10.9.0.1/32
PersistentKeepalive = 25
EOF
)"

printf '\n'
warn "Private keys below are SECRET. Save each config to the matching host and do NOT commit."
printf '\n%b----- STORAGE host -> infra/wireguard/storage/wg0.conf -----%b\n' "${GREEN}" "${NC}"
printf '%s\n' "${STORAGE_CONF}"
printf '\n%b----- APP host -> infra/wireguard/app/wg0.conf -----%b\n' "${GREEN}" "${NC}"
printf '%s\n' "${APP_CONF}"

# Offer to write the files locally when both target dirs exist (single-checkout convenience).
if [[ "${WG_WRITE:-}" == "1" ]]; then
  mkdir -p "${ROOT_DIR}/infra/wireguard/storage" "${ROOT_DIR}/infra/wireguard/app"
  printf '%s\n' "${STORAGE_CONF}" > "${ROOT_DIR}/infra/wireguard/storage/wg0.conf"
  printf '%s\n' "${APP_CONF}"     > "${ROOT_DIR}/infra/wireguard/app/wg0.conf"
  chmod 600 "${ROOT_DIR}/infra/wireguard/storage/wg0.conf" "${ROOT_DIR}/infra/wireguard/app/wg0.conf"
  ok "Wrote infra/wireguard/{storage,app}/wg0.conf (WG_WRITE=1)."
else
  printf '\n%bTip:%b re-run with WG_WRITE=1 to write both files to infra/wireguard/ automatically.\n' "${BLUE}" "${NC}"
fi
