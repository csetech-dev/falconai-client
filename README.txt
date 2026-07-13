FalconAI client bundle — no application source.

Extract:
  sudo mkdir -p /opt
  sudo tar -xzf falconai-client-bundle.tar.gz -C /opt
  cd /opt/falconai-client

If deploy fails with "pipefail" or "$'\r': command not found", fix line endings once:
  bash scripts/deploy/fix-crlf.sh
  sed -i 's/\r$//' .env.app .env.storage 2>/dev/null || true

WireGuard tunnel (REQUIRED — encrypts app<->storage; storage ports are not public):
  One-time, on a machine with Docker (generates BOTH hosts' configs together):
    STORAGE_PUBLIC_IP=<storage-public-ip> bash scripts/gen-wireguard-keys.sh
  Save the printed "STORAGE host" block to  infra/wireguard/storage/wg0.conf  (storage host)
  Save the printed "APP host" block to      infra/wireguard/app/wg0.conf      (app host)
  Deploy will abort with instructions if these are missing.
  Details: docs/WIREGUARD_STORAGE_TUNNEL.md

Storage host:
  cp .env.storage.example .env.storage
  nano .env.storage
  # place infra/wireguard/storage/wg0.conf (see WireGuard step above)
  make deploy-storage

App host:
  cp .env.app.example .env.app
  nano .env.app          # set GHCR_IMAGE_PREFIX, STORAGE_SERVER_IP (this host's LAN IP), PUBLIC_GATEWAY_URL
  # place infra/wireguard/app/wg0.conf (see WireGuard step above)
  echo "$TOKEN" | docker login ghcr.io -u GITHUB_USER --password-stdin
  make deploy-ghcr

Upgrade later:
  cd /opt/falconai-client && make deploy-ghcr

Keycloak / Settings users (OIDC server mode):
  bash scripts/import-keycloak-falcon-realm.sh
  bash scripts/reset-keycloak-falcon-password.sh
  bash scripts/provision-keycloak-falcon-users.sh
  bash scripts/test-keycloak-password-grant.sh <email> '<password>'

Full guide: docs/GHCR_DEPLOY.md (in vendor repo)
Grant client GitHub user read:packages on GHCR packages.
