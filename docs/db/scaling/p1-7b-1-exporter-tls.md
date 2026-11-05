# P1.7b PR 1: publish the storage exporters with TLS + password (runbook)

Plan item: [DATABASE_SCALING_PLAN.md](../DATABASE_SCALING_PLAN.md), P1.7b PR 1. Design: [p1-7b-monitoring-design.md](p1-7b-monitoring-design.md).
Implementation plan: [p1-7b-1-plan.md](p1-7b-1-plan.md).

**Needs first:** [P1.7a](p1-7a-exporters.md) done on the same environment. The exporters must be running on `127.0.0.1` with `pg_up 1`.
**Order:** stage first, then prod. On each environment, finish every step and its check before the next one.
**Who runs prod:** only someone with prod access. Until then, record `stage: done` in the plan and leave prod pending.

## What changes

- Both exporters run on the **host network**, so the storage server's **ufw** decides who can reach 9187 and 9100.
  - Docker-published ports bypass ufw. That's why `postgres-exporter` no longer uses one.
  - `postgres-exporter` now connects to Postgres through `127.0.0.1:12002`, the port Postgres already publishes on this host.
- Both exporters require **TLS** and the password for user `falcon_scrape`, once `EXPORTER_WEB_CONFIG` is set.
- They listen on `MONITORING_BIND_IP`. It stays `127.0.0.1` (today's behaviour) until step 4.
- `deploy-storage.sh` **refuses** a non-loopback `MONITORING_BIND_IP` unless TLS and the password are configured.
- Not touched: the `postgres`, `minio`, `minio-init` and `wireguard` services. They were checked byte-for-byte against `stage`.

## Values you need

| Name | Where to find it |
|---|---|
| `<storage-ip>` | The storage server's IP that the app server uses today (`STORAGE_SERVER_IP` in the app server's `.env.app`) |
| `<app-ip>` | The app server's IP **as the storage server sees it**. Check with `sudo ss -tnp | grep ':12002'` on the storage server: the remote addresses are the app server |
| Scrape password | You create it in step 1. It goes into the app server's monitoring config later (PR 2). Never paste it into chat or git |

**How the files reach the server.** Servers run from **`/opt/falconai-client`**, a clone of the falconai-client repo (GitHub).
Stage and prod pull the **same** branch, so a bundle always reaches both. Bundles are therefore built only from FalconAI **`main`**
after a normal release, never from `stage`. Monitoring stays off on any server until its own `.env.storage` turns it on; the
bundle sync never overwrites `.env.*`.

1. **Release (FalconAI):** this change must be merged `stage` → `main` in your normal release.
2. **Publish the bundle (your machine, Git Bash, in a FalconAI checkout on `main`).** The second command builds the bundle, mirrors
   it into your falconai-client checkout, commits and pushes:

   ```bash
   git checkout main && git pull origin main
   ```

   ```bash
   CLIENT_SYNC_DIR=/d/falconai-client CLIENT_SYNC_PUSH=1 CLIENT_SYNC_MESSAGE="bundle from main $(git rev-parse --short HEAD)" bash scripts/ci/package-client-bundle.sh
   ```

   Replace `/d/falconai-client` if your checkout is elsewhere. Expect `Created …falconai-client-bundle.tar.gz` and a push.
3. **Update the server's bundle checkout (storage server):**

   ```bash
   cd /opt/falconai-client && git pull --ff-only
   ```

   Expect `Fast-forward` or `Already up to date`. If it refuses because of local edits, send me `git status --short` (never
   discard `.env.*`).

Then run everything below **on the storage server**, from the bundle checkout:

```bash
cd /opt/falconai-client
```

Check that the new files arrived. Expect both paths printed:

```bash
ls scripts/deploy/monitoring-exporter-tls.sh docs/db/scaling/p1-7b-1-exporter-tls.md
```

Set the same shortcut as in P1.7a, replacing `test` with this host's `FALCON_SIZING_PROFILE`:

```bash
DC="docker compose --env-file .env.sizing.test --env-file .env.storage -f docker-compose.storage.yml"
```

## Step 0: Pre-checks (storage server)

1. ufw must be on and must deny incoming by default:

   ```bash
   sudo ufw status verbose
   ```

   Expect `Status: active` and `Default: deny (incoming)`. **Stop** if it says inactive or `allow (incoming)`, and send me the
   output. In that case the exporters would be reachable by anyone once published.

2. Only the P1.7a exporters may be on 9187 and 9100, and only on loopback:

   ```bash
   sudo ss -ltnp | grep -E ':(9187|9100)\b'
   ```

   Expect at most two lines, both `127.0.0.1:…`.

## Step 1: Generate the TLS material and the password (storage server)

1. Generate a password (32+ characters) and keep it for step 5 and for PR 2:

   ```bash
   openssl rand -base64 32
   ```

2. Run the script. It asks for the password twice; the input is hidden. Paste it at each prompt and press Enter:

   ```bash
   sudo scripts/deploy/monitoring-exporter-tls.sh --ip <storage-ip>
   ```

   - **Expect:** `Wrote …/infra/monitoring/exporter-tls (valid 825 days, until <date>)`, followed by a certificate block from
     `-----BEGIN CERTIFICATE-----` to `-----END CERTIFICATE-----`.
   - Save that block as `storage_ca.crt` for PR 2. It isn't secret.
   - Write the expiry date in the plan's decisions log.
   - If `htpasswd` isn't installed, the script uses the `httpd:2.4-alpine` image instead. The server has internet access, so that works.

3. Check the files and their permissions:

   ```bash
   sudo ls -l infra/monitoring/exporter-tls
   ```

   Expect `ca.key` as `-rw-------`, and the other four as `-rw-r-----` with group `nogroup` (or `65534`).

## Step 2: Allow only the app server through ufw (storage server)

```bash
sudo ufw allow from <app-ip> to any port 9187 proto tcp comment 'falcon prometheus postgres-exporter'
```

```bash
sudo ufw allow from <app-ip> to any port 9100 proto tcp comment 'falcon prometheus node-exporter'
```

```bash
sudo ufw status numbered
```

Expect the two new `ALLOW IN` rules, each from `<app-ip>` only. Note their numbers for the rollback.

## Step 3: Allow outbound traffic from the app server (app server)

1. Test first. Nothing listens publicly yet, so a *refused* connection is the good result:

   ```bash
   nc -vz -w 5 <storage-ip> 9187
   ```

   - `Connection refused`: outbound is already allowed. Go to step 4.
   - `timed out`: outbound is blocked. Continue below.

2. If the app server's outbound rules are in **ufw** (`sudo ufw status verbose` shows `deny (outgoing)`):

   ```bash
   sudo ufw allow out to <storage-ip> port 9187,9100 proto tcp comment 'falcon prometheus scrape'
   ```

   If outbound is restricted somewhere else (a provider firewall or iptables), allow TCP 9187 and 9100 to `<storage-ip>` there.
   Then repeat the `nc` test and expect `Connection refused`.

## Step 4: Publish the exporters with TLS (storage server)

1. Edit `.env.storage` and set:

   ```
   MONITORING_BIND_IP=<storage-ip>
   EXPORTER_WEB_CONFIG=/etc/exporter-tls/web-config.yml
   ```

2. Run the safety check. Expect no output; any `ERROR` means stop:

   ```bash
   bash -c 'source scripts/deploy/common.sh; load_env_file .env.storage; monitoring_exposure_check' && echo OK
   ```

   Expect `OK`.

3. Dry run. Only `falcon-postgres-exporter` and `falcon-node-exporter` may be listed. **Stop** if `falcon-postgres`, `falcon-minio`
   or a network or volume shows `Created`:

   ```bash
   $DC --profile monitoring up -d --no-deps --dry-run postgres-exporter node-exporter
   ```

4. Apply. This recreates only the two exporters (a few seconds without metrics, no effect on the database):

   ```bash
   $DC --profile monitoring up -d --no-deps postgres-exporter node-exporter
   ```

## Step 5: Verify

1. **Storage server:** both are running and listen only on `<storage-ip>`:

   ```bash
   docker ps --filter name=falcon-postgres-exporter --filter name=falcon-node-exporter --format '{{.Names}} {{.Status}}'
   ```

   ```bash
   sudo ss -ltnp | grep -E ':(9187|9100)\b'
   ```

   Expect two `Up` lines, then two listeners on `<storage-ip>:9187` and `<storage-ip>:9100`.

2. **Storage server:** without the password, the request is refused:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' --cacert infra/monitoring/exporter-tls/ca.crt https://<storage-ip>:9187/metrics
   ```

   Expect `401`.

3. **App server:** with the password, metrics come back. Copy `storage_ca.crt` from step 1 to the app server first, for example to
   `~/storage_ca.crt`. curl asks for the password:

   ```bash
   curl -s --cacert ~/storage_ca.crt -u falcon_scrape https://<storage-ip>:9187/metrics | grep -E '^pg_up |^pg_exporter_last_scrape_error '
   ```

   Expect `pg_up 1` and `pg_exporter_last_scrape_error 0`.

   ```bash
   curl -s --cacert ~/storage_ca.crt -u falcon_scrape https://<storage-ip>:9100/metrics | grep -cE '^node_'
   ```

   Expect a number above 100.

4. **A third machine** (your laptop, not the app server) can't reach either port:

   ```bash
   nc -vz -w 5 <storage-ip> 9187
   ```

   ```bash
   nc -vz -w 5 <storage-ip> 9100
   ```

   Expect `timed out` (or `refused`) for both. **If either says `succeeded`, roll back now** and send me the output.

5. **Logs:** no errors, and the app works normally for 15 minutes.

   ```bash
   docker logs --tail 20 falcon-postgres-exporter
   ```

   ```bash
   docker logs --tail 20 falcon-node-exporter
   ```

Send me the outputs of 5.1–5.4 with IPs removed. Then I'll tick PR 1 for this environment in the plan.

## Rollback (seconds, database untouched)

1. In `.env.storage`, set `MONITORING_BIND_IP=127.0.0.1` and `EXPORTER_WEB_CONFIG=` (empty), then:

   ```bash
   $DC --profile monitoring up -d --no-deps postgres-exporter node-exporter
   ```

2. Remove the two ufw rules, using the numbers from step 2 (the highest number first):

   ```bash
   sudo ufw status numbered
   ```

   ```bash
   sudo ufw delete <number>
   ```

## Renewing the certificate (before the expiry date from step 1)

```bash
sudo scripts/deploy/monitoring-exporter-tls.sh --ip <storage-ip> --force
```

```bash
$DC --profile monitoring up -d --no-deps --force-recreate postgres-exporter node-exporter
```

Then give the app server the new `ca.crt` (PR 2's runbook says where). You can keep the same password or choose a new one; if it's
new, update the app server too.

## Tested before this PR, and not tested

**Tested in the Claude session:**
- `monitoring-exporter-tls.sh`, 8 tests:
  - it refuses non-IPv4 input and short, mismatched or empty passwords, and writes nothing;
  - the certificate has the IP SAN, chains to the CA and lasts 825 days;
  - the web config has TLS and a bcrypt hash only;
  - the password goes only through stdin;
  - it doesn't overwrite without `--force`;
  - the file modes and group 65534 are correct.
- `monitoring_exposure_check`, 6 tests: loopback passes, and a public IP is refused without a config, with a missing file, or without
  auth. `0.0.0.0` counts as public.
- Compose: `postgres`, `minio`, `minio-init` and `wireguard` are byte-for-byte unchanged under all four profile combinations. The
  exporter commands resolve correctly with and without TLS.
- Existing tests: 12/12 and 13/13 pass.

**Not tested here** (this session can't run the exporter images): the exporters actually serving TLS and auth, and starting with
an empty `--web.config.file=` at defaults. Steps 4 and 5 on stage check both before prod.
