# P1.7b PR 2: monitoring stack on the app server (runbook)

Plan item: [DATABASE_SCALING_PLAN.md](../DATABASE_SCALING_PLAN.md), P1.7b PR 2. Design: [p1-7b-monitoring-design.md](p1-7b-monitoring-design.md).
Implementation plan: [p1-7b-2-plan.md](p1-7b-2-plan.md).

**Needs first:** [P1.7b PR 1](p1-7b-1-exporter-tls.md) done on the **storage** server of the same environment. You need its
`storage_ca.crt` and the scrape password.
**Where:** the **app** server. Stage first; prod only by someone with prod access.
**Effect on the app:** none. The stack is its own compose project with no host ports. App deploys never touch it, and it never
touches the app.

## What runs

| Container | Purpose | Reachable from |
|---|---|---|
| `falcon-prometheus` | Collects metrics every 30 s (database every 60 s) and keeps 30 days, capped at 10 GB | Inside the Docker network only |
| `falcon-alertmanager` | Alert routing. Telegram stays off until configured | Inside the Docker network only |
| `falcon-grafana` | Dashboards. Reached at `/grafana/` once PR 3 adds the gateway route and sign-in | Inside the Docker network only (until PR 3) |

Settings (`monitoring.env`), secrets and rendered configs all live in **`/etc/falcon-monitoring/`**, outside the bundle checkout,
so bundle updates, `git clean` and `git add` never touch them.

## Before you start (app server)

1. Get the files with the normal flow: a release to `main`, then the bundle published from `main`, then on this server:

   ```bash
   cd /opt/falconai-client && git pull --ff-only
   ```

2. Check the files arrived. Expect three paths:

   ```bash
   ls docker-compose.monitoring.yml scripts/deploy/deploy-monitoring.sh .env.monitoring.example
   ```

3. Check there's room. About 2.5 GB of free memory is needed (see the `available` column) and about 12 GB of free disk:

   ```bash
   free -h
   ```

   ```bash
   df -h /
   ```

4. The app network must exist. Expect one line ending in `falcon-app_falcon-net`:

   ```bash
   docker network ls | grep falcon-app_falcon-net
   ```

5. The app server must reach the storage exporters, which needs PR 1 done and the outbound rule in place. Expect `succeeded` or
   `open`:

   ```bash
   nc -vz -w 5 <storage-ip> 9187
   ```

## Step 1: Create the secret files

Run everything as root, **in one terminal session**. Start with this, so every file you create is private from the start:

```bash
umask 077
```

1. Create the folders:

   ```bash
   install -d -m 755 /etc/falcon-monitoring /etc/falcon-monitoring/config
   ```

   ```bash
   install -d -m 711 /etc/falcon-monitoring/secrets
   ```

2. **Metrics token.** falcon-core and search-service only serve metrics with this token. Check whether `.env.app` already has one:

   ```bash
   grep -cE '^METRICS_TOKEN=.+' /opt/falconai-client/.env.app
   ```

   - **`1` (it has one):** copy it into the secret file.

     ```bash
     grep -E '^METRICS_TOKEN=' /opt/falconai-client/.env.app | cut -d= -f2- | tr -d '\n' > /etc/falcon-monitoring/secrets/metrics_token
     ```

   - **`0` (empty or missing):** generate one into the secret file:

     ```bash
     openssl rand -hex 32 | tr -d '\n' > /etc/falcon-monitoring/secrets/metrics_token
     ```

     Then put the same value in `.env.app` as `METRICS_TOKEN=<value>`, using `nano /opt/falconai-client/.env.app`. Read the
     value with:

     ```bash
     cat /etc/falcon-monitoring/secrets/metrics_token
     ```

     The app picks it up at its **next normal app deploy**; no restart now. Until then, the `falcon-core` and `falcon-search`
     targets show as down. That's expected.

3. **Storage scrape password,** the one from PR 1 step 1. Paste it at the hidden prompt:

   ```bash
   read -rs P && printf '%s' "$P" > /etc/falcon-monitoring/secrets/storage_exporter_password && unset P
   ```

4. **Storage CA certificate** (from PR 1 step 1):
   1. Run the command below.
   2. Paste the whole block, from `-----BEGIN CERTIFICATE-----` to `-----END CERTIFICATE-----`.
   3. Press **Enter**, then **Ctrl+D**.

   ```bash
   cat > /etc/falcon-monitoring/secrets/storage_ca.crt
   ```

   Check it. Expect `subject=CN=falcon-exporters-ca`:

   ```bash
   openssl x509 -in /etc/falcon-monitoring/secrets/storage_ca.crt -noout -subject
   ```

5. **Grafana admin password.** Grafana needs one, but admins will sign in through FalconAI once PR 3 lands:

   ```bash
   openssl rand -base64 32 | tr -d '\n' > /etc/falcon-monitoring/secrets/grafana_admin_password
   ```

6. **Ownership and modes.** Each file must be owned by the container user that reads it:

   ```bash
   cd /etc/falcon-monitoring/secrets && chown 65534:65534 metrics_token storage_exporter_password storage_ca.crt && chown 472:472 grafana_admin_password && chmod 600 * && ls -ln
   ```

   Expect four files, mode `-rw-------`. Three are owned by `65534`, and `grafana_admin_password` by `472`.

## Step 2: Settings

```bash
cp -n /opt/falconai-client/.env.monitoring.example /etc/falcon-monitoring/monitoring.env && chmod 600 /etc/falcon-monitoring/monitoring.env
```

```bash
nano /etc/falcon-monitoring/monitoring.env
```

Set `STORAGE_SERVER_IP=<storage-ip>`, the same IP the exporters' certificate was made for in PR 1. Leave `TELEGRAM_CHAT_ID` empty
for now. This file is outside the bundle checkout, so bundle updates never touch it.

**Changing a setting later** (for example turning on Telegram): edit this file, then re-run step 4. The deploy restarts
Prometheus and Alertmanager so the change takes effect.

## Step 3: Check without starting anything

```bash
bash scripts/deploy/deploy-monitoring.sh --check-only
```

- **Expect:** `App network falcon-app_falcon-net found`, then `SUCCESS` from promtool and from amtool, then
  `Check only: nothing started`.
- The first run downloads the Prometheus and Alertmanager images. A wrong image tag fails here, before anything changes.
- Any `ERROR:` names the file or setting to fix.

## Step 4: Start

```bash
bash scripts/deploy/deploy-monitoring.sh
```

Then check all three are running. Expect three lines, each `Up …`:

```bash
docker ps --filter name=falcon-prometheus --filter name=falcon-alertmanager --filter name=falcon-grafana --format '{{.Names}} {{.Status}}'
```

## Step 5: Verify

1. **Targets.** Wait about 2 minutes, then:

   ```bash
   docker exec falcon-prometheus wget -qO- 'http://localhost:9090/api/v1/targets?state=active' | python3 -c 'import json,sys; [print(t["labels"]["job"], t["health"], t.get("lastError","")) for t in json.load(sys.stdin)["data"]["activeTargets"]]'
   ```

   Expect `up` for `prometheus`, `alertmanager`, `postgres` and `node-storage`. `falcon-core` and `falcon-search` show `up` once the
   app has `METRICS_TOKEN` (step 1.2); before that, `down` with a 404 is expected.
2. **A real number.** Expect a value around `17` (GB):

   ```bash
   docker exec falcon-prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=pg_database_size_bytes{datname="falcon_ai"}/1e9' | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["result"][0]["value"][1])'
   ```

3. **Resource use.** Expect well under the limits (Prometheus 1.5 GB, Grafana 512 MB, Alertmanager 128 MB):

   ```bash
   docker stats --no-stream falcon-prometheus falcon-alertmanager falcon-grafana
   ```

4. **No host ports.** Expect no output:

   ```bash
   docker ps --filter name=falcon-prometheus --filter name=falcon-alertmanager --filter name=falcon-grafana --format '{{.Ports}}' | grep -E '0\.0\.0\.0|::'
   ```

5. **The app is unaffected.** Use the app normally for 30 minutes.

Send me the outputs of 5.1–5.4, with IPs removed. Then I'll mark PR 2 `stage: done` in the plan.

## Rollback

Stop and remove the containers. The metric history is kept in Docker volumes:

```bash
cd /opt/falconai-client && docker compose --env-file /etc/falcon-monitoring/monitoring.env -f docker-compose.monitoring.yml down
```

To also delete the history:

```bash
docker compose --env-file /etc/falcon-monitoring/monitoring.env -f docker-compose.monitoring.yml down -v
```

The secret files stay in `/etc/falcon-monitoring/`. To remove them too:

```bash
rm -rf /etc/falcon-monitoring
```

## Tested before this PR, and not tested

**Tested in the Claude session:**
- Rendering and checks, 9 tests:
  - missing, empty, world-readable or wrongly-owned secrets are refused;
  - a bad `STORAGE_SERVER_IP` and half-configured Telegram are refused;
  - all six jobs render with file-based secrets, and custom ports work;
  - no secret value appears in any rendered file;
  - Telegram is on only when fully configured;
  - rendering is idempotent.
- The deploy script, 7 tests with a fake `docker`:
  - it refuses when the app network is missing;
  - `--check-only` validates without starting;
  - a full run starts the `falcon-monitoring` project;
  - broken secrets stop it before Compose runs.
- Compose: the project is `falcon-monitoring`, there are no ports, and the network is external. The config **directory** is mounted,
  so a re-render is picked up, and a re-deploy restarts Prometheus and Alertmanager. The app and storage Compose files are unchanged,
  and the bundle ships all files.
- Final review by a fresh reviewer: 2 Important findings fixed (stale config on re-deploy; settings file inside the checkout).
  The window where secret files were world-readable is closed with `umask 077`.

**Not tested here** (this session can't run the images): promtool and amtool against the real images, and the containers running.
Steps 3–5 on stage cover them before prod.
