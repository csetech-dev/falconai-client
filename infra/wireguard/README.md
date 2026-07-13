# WireGuard app↔storage tunnel

Encrypts all cross-host traffic between the **app** stack and the **storage**
stack (Postgres + MinIO) — see [`docs/WIREGUARD_STORAGE_TUNNEL.md`](../../docs/WIREGUARD_STORAGE_TUNNEL.md)
for the full runbook.

```
storage host  10.9.0.1  ⇦══ wg0 (encrypted, 51820/udp) ══⇨  10.9.0.2  app host
```

## Files

| Path | Committed? | Purpose |
|------|-----------|---------|
| `storage/wg0.conf.example` | yes | Template for the storage endpoint |
| `app/wg0.conf.example`     | yes | Template for the app endpoint |
| `storage/wg0.conf`         | **no (gitignored)** | Real config — holds the private key |
| `app/wg0.conf`             | **no (gitignored)** | Real config — holds the private key |

These directories are mounted into the `wireguard` sidecar of each stack at
`/config/wg_confs`.

## Setup

1. Generate both keypairs + a preshared key:
   ```bash
   bash scripts/gen-wireguard-keys.sh
   ```
   It prints ready-to-paste `wg0.conf` files for both hosts.
2. Copy `wg0.conf.example` → `wg0.conf` on each host and fill in the keys. On the
   **app** host also set `Endpoint` to the storage host's public IP.
3. Bring up storage first (`make deploy-storage`), then the app
   (`make deploy-app`). Verify with `docker exec falcon-wg-storage wg show` /
   `docker exec falcon-wg-app wg show`.

**Never commit `wg0.conf`** — it contains the private key.
