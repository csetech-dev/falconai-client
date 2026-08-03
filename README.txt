FalconAI client bundle â€” no application source.

Extract:
  sudo mkdir -p /opt
  sudo tar -xzf falconai-client-bundle.tar.gz -C /opt
  cd /opt/falconai-client

If deploy fails with "set: pipefail: invalid option", fix line endings once:
  bash scripts/deploy/fix-crlf.sh

WireGuard tunnel (REQUIRED â€” encrypts app<->storage; storage ports are not public):
  One-time, on a machine with Docker (generates BOTH hosts' configs together):
    STORAGE_PUBLIC_IP=<storage-public-ip> bash scripts/gen-wireguard-keys.sh
  Save the "STORAGE host" block to  infra/wireguard/storage/wg0.conf  (storage host)
  Save the "APP host" block to      infra/wireguard/app/wg0.conf      (app host)
  Deploy aborts with instructions if these are missing.
  Details: docs/WIREGUARD_STORAGE_TUNNEL.md

Storage host:
  cp .env.storage.example .env.storage
  nano .env.storage
  # place infra/wireguard/storage/wg0.conf (see WireGuard step above)
  make deploy-storage

App host:
  cp .env.app.example .env.app
  nano .env.app          # set STORAGE_SERVER_IP to this host's LAN IP
  # place infra/wireguard/app/wg0.conf (see WireGuard step above)
  echo "$TOKEN" | docker login ghcr.io -u GITHUB_USER --password-stdin
  make deploy-ghcr

Full guide: docs/GHCR_DEPLOY.md (in vendor repo)
