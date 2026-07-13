# WireGuard app↔storage tunnel

Encrypts **all** traffic between the app stack and the storage stack (Postgres +
MinIO) using a containerized WireGuard sidecar in each Compose project. After
setup, the storage host exposes **only** `51820/udp` publicly — Postgres and
MinIO are no longer reachable on the public network at all.

## Why

FalconAI's split deployment runs the app services on one host and Postgres +
MinIO on another. By default the app reaches storage over plaintext TCP
(Postgres wire protocol + MinIO HTTP, `MINIO_USE_SSL=false`). This tunnel wraps
that traffic in WireGuard so it is encrypted and authenticated in transit, and
removes the storage ports from the public NIC.

No application code, connection strings, or app containers change — everything
still flows through the single `STORAGE_SERVER_IP` value. Only two sidecar
services and their configs are added.

## Architecture

```
        APP HOST (falcon-app)                       STORAGE HOST (falcon-storage)
  ┌─────────────────────────────────┐        ┌─────────────────────────────────────┐
  │ falcon-core / workers / gateway │         │  falcon-postgres  172.29.0.10 (no    │
  │      │ connect to               │         │  falcon-minio     172.29.0.11  public │
  │      ▼  STORAGE_SERVER_IP:12002 │         │        ▲  DNAT 12002→5432,   ports)  │
  │        (= this host's LAN IP)   │         │        │       12004→9000,           │
  │ ┌───────────────────┐  publishes │  wg0    │  ┌───────────────────┐ 12015→9001    │
  │ │ falcon-wg-app      │ 12002/4/15 │◄═══════════►│ falcon-wg-storage │               │
  │ │ 10.9.0.2           │  DNAT→tunnel│ encrypted│  │ 10.9.0.1          │ 172.29.0.2   │
  │ └───────────────────┘  51820/udp  │ (51820) │  └───────────────────┘               │
  └─────────────────────────────────┘        └─────────────────────────────────────┘
```

- **Tunnel subnet** `10.9.0.0/24`: storage = `10.9.0.1`, app = `10.9.0.2`.
- The **storage sidecar** terminates the tunnel and DNATs the storage ports
  arriving on `wg0` to the Postgres/MinIO containers (static IPs
  `172.29.0.10` / `172.29.0.11` pinned in `docker-compose.storage.yml`).
- The **app sidecar** republishes the storage ports on the app host (bound to
  `STORAGE_SERVER_IP`) and DNATs them across the tunnel to `10.9.0.1`. Binding to
  `STORAGE_SERVER_IP` (the app host's own LAN IP) means both app containers and
  the host-level `deploy-app` preflight reach storage over the tunnel, with **no
  change to the deploy scripts**.

## Prerequisites

- Docker + Compose on both hosts (same as the rest of the split deploy).
- The app host must be able to reach the storage host's public IP on
  `51820/udp`. Open that port (only) in the storage host's firewall / security
  group. If the storage host is behind NAT, forward `51820/udp` to it.
- The WireGuard kernel module (built into modern Linux kernels; the
  `linuxserver/wireguard` image loads it via the `/lib/modules` mount if needed).

## Setup

### 1. Generate keys

On any machine with Docker (once — produces material for both hosts):

```bash
STORAGE_PUBLIC_IP=<storage-host-public-ip> bash scripts/gen-wireguard-keys.sh
```

It mints two keypairs + a preshared key and prints a complete `wg0.conf` for each
host. Copy each block to the matching host:

- Storage host → `infra/wireguard/storage/wg0.conf`
- App host → `infra/wireguard/app/wg0.conf`

(Or run with `WG_WRITE=1` to write both files into `infra/wireguard/` on the
current checkout.) These files are **gitignored** — they contain private keys.
Never commit them. If you prefer to fill them by hand, copy the `*.example`
templates and generate keys with `wg genkey` / `wg pubkey` / `wg genpsk`.

### 2. Set env values

`.env.storage` (storage host):
```env
WG_LISTEN_PORT=51820
# STORAGE_ADVERTISE_IP is no longer used — storage ports are tunnel-only.
```

`.env.app` (app host):
```env
# This app host's OWN LAN IP — the tunnel entry is the local sidecar.
STORAGE_SERVER_IP=<app-host-lan-ip>
WG_LISTEN_PORT=51820
MINIO_API_PORT=12004
MINIO_CONSOLE_PORT=12015
```

The storage host's **public** IP belongs only in `infra/wireguard/app/wg0.conf`
(`Endpoint`), not in `.env.app`.

### 3. Bring up — storage first, then app

```bash
# Storage host
make deploy-storage

# App host (preflight will connect to storage over the tunnel)
make deploy-app
```

The storage sidecar starts with the storage stack; the app sidecar starts with
the app stack. The tunnel establishes automatically once both `wg0.conf` files
have matching keys and the app can reach the storage `Endpoint`.

## Verification

```bash
# 1. Handshake up on both sides (recent handshake, nonzero transfer)
docker exec falcon-wg-storage wg show
docker exec falcon-wg-app wg show

# 2. Tunnel reachable app -> storage
docker exec falcon-wg-app ping -c3 10.9.0.1

# 3. Storage reachable from the app host over the tunnel
nc -vz "$STORAGE_SERVER_IP" 12002                                  # Postgres
curl -fsS "http://$STORAGE_SERVER_IP:12004/minio/health/live"      # MinIO

# 4. App works: make deploy-app preflight passes, falcon-core connects to DB/MinIO

# 5. Public storage ports are CLOSED (run from a third host):
nc -vz <storage-public-ip> 12002    # must FAIL
nc -vz <storage-public-ip> 12004    # must FAIL
nc -vz <storage-public-ip> 12015    # must FAIL
nc -vzu <storage-public-ip> 51820   # only this is open

# 6. Fail-fast check: stop the app sidecar, redeploy -> preflight aborts
docker stop falcon-wg-app && make deploy-app     # dies at wait_for_tcp (expected)
docker start falcon-wg-app                        # recover
```

## Operations

- **Restart tunnel:** `docker restart falcon-wg-app` / `falcon-wg-storage`.
- **Key rotation:** re-run `scripts/gen-wireguard-keys.sh`, replace both
  `wg0.conf` files, and restart both sidecars (do the storage side first).
- **Teardown:** to revert to plaintext, restore the `ports:` blocks on
  `postgres`/`minio` in `docker-compose.storage.yml`, point `STORAGE_SERVER_IP`
  back at the storage host's IP, and remove the `wireguard` services.

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `wg show` shows no handshake | App can't reach storage `Endpoint` on `51820/udp` — open the port / fix NAT forwarding. Confirm keys match between the two `wg0.conf` files. |
| Handshake OK but Postgres/MinIO unreachable | DNAT rules didn't apply. Check `docker exec falcon-wg-storage iptables -t nat -L PREROUTING -n`. Confirm Postgres/MinIO got the static IPs `172.29.0.10` / `172.29.0.11` (`docker inspect`). |
| Large MinIO uploads or `pg_dump` stall/hang | PMTU blackhole — set `MTU = 1380` in the `[Interface]` block of **both** `wg0.conf` files and restart both sidecars. |
| `deploy-app` preflight fails immediately | Tunnel is down (this is the intended fail-fast — there is no plaintext fallback). Bring the sidecars up and retry. |
| Ran both stacks on one host | The two sidecars share `51820/udp` — give one a different `WG_LISTEN_PORT`, or run them on separate hosts as intended. |

## Notes

- **Redis and OpenSearch** live in the app stack and never cross the tunnel — no
  change.
- **MinIO console / presigned URLs**: browser console traffic flows through the
  app-host `api-gateway` (`MINIO_CONSOLE_UPSTREAM` → local sidecar) and is
  unaffected. If you hand presigned MinIO URLs directly to end-user browsers,
  keep `MINIO_PUBLIC_ENDPOINT` on a public/proxied address explicitly.
- WireGuard is L3, so it transparently carries the existing Postgres/MinIO TCP
  ports; no port numbers change inside the tunnel.
