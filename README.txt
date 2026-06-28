FalconAI client bundle — no application source.

Extract:
  sudo mkdir -p /opt
  sudo tar -xzf falconai-client-bundle.tar.gz -C /opt
  cd /opt/falconai-client

If deploy fails with "pipefail" or "$'\r': command not found", fix line endings once:
  bash scripts/deploy/fix-crlf.sh
  sed -i 's/\r$//' .env.app .env.storage 2>/dev/null || true

Storage host:
  cp .env.storage.example .env.storage
  nano .env.storage
  make deploy-storage

App host:
  cp .env.app.example .env.app
  nano .env.app          # set GHCR_IMAGE_PREFIX, POSTGRES_HOST, PUBLIC_GATEWAY_URL
  echo "$TOKEN" | docker login ghcr.io -u GITHUB_USER --password-stdin
  make deploy-ghcr

Upgrade later:
  cd /opt/falconai-client && make deploy-ghcr

Full guide: docs/GHCR_DEPLOY.md (in vendor repo)
Grant client GitHub user read:packages on GHCR packages.
