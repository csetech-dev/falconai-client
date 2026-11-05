# P1.7a: Postgres and host exporters on the storage server (runbook)

Plan item: [DATABASE_SCALING_PLAN.md](../DATABASE_SCALING_PLAN.md), P1.7a.

## What this adds

| Piece | What it is | Where |
|---|---|---|
| `postgres-exporter` | Prometheus metrics for Postgres: connections, database sizes, locks, table stats, replication | `docker-compose.storage.yml`, profile `monitoring`, `127.0.0.1:9187` |
| `node-exporter` | Host metrics for the storage server: disk free space, disk I/O, CPU, memory | same file, host network, `127.0.0.1:9100` |
| `falcon_monitor` role | Read-only login with `pg_monitor`, `CONNECTION LIMIT 3` | created with `scripts/performance/create-monitor-role.sql` |
| `MONITORING_ENABLED` | Opt-in switch for `deploy-storage.sh` (default `false`) | `.env.storage` |

## Safety

- **Postgres is not restarted or recreated.** The `postgres`, `minio` and `minio-init` service definitions are unchanged. The
  resolved configs were checked byte-for-byte against `stage`, with and without the `wireguard` profile.
- **Off by default.** Nothing starts until you opt in. A normal `deploy-storage.sh` run with `MONITORING_ENABLED=false` (or unset)
  deploys exactly what it deploys today.
- **Not exposed.** Both exporters listen on `127.0.0.1` only, even when `WIREGUARD_ENABLED=false` publishes Postgres on `0.0.0.0`.
  How Prometheus reaches them is decided in P1.7b.
- **Read-only database access.** `falcon_monitor` can read statistics views, but it can't read application tables, write anything or
  create objects (tested). The script refuses to change a role that already has superuser or similar rights.
- **Password hygiene.** The password is read from an environment variable. It never appears on the command line, in shell history, in
  the SQL file or in the server log: the session turns statement logging off, and this was tested with `log_statement=all`.
- **Load.** The exporter only queries when it is scraped; for now that means only when you run `curl`. It uses at most 3 connections.

## Before you start (every environment)

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
ls scripts/performance/create-monitor-role.sql docs/db/scaling/p1-7a-exporters.md
```

2. Check the sizing profile this host uses. You need it for the compose command below.

   ```bash
   grep -E '^(FALCON_SIZING_PROFILE|COMPOSE_PROJECT_NAME)=' .env.storage
   ```

3. Set a shortcut for the exact compose command `deploy-storage.sh` uses. Replace `prod` with the profile from step 2.

   ```bash
   DC="docker compose --env-file .env.sizing.prod --env-file .env.storage -f docker-compose.storage.yml"
   ```

4. Check that the host can pull the images. If it can't, set `POSTGRES_EXPORTER_IMAGE` / `NODE_EXPORTER_IMAGE` in `.env.storage`
   to a mirror you use, and pull again.

   ```bash
   docker pull prometheuscommunity/postgres-exporter:v0.17.1 && docker pull prom/node-exporter:v1.9.1
   ```

5. Check that nothing already listens on 9187 or 9100. Expect no output.

   ```bash
   ss -ltnp | grep -E ':(9187|9100)\b'
   ```

## Steps (stage first, then prod)

1. **Create the role.** Generate a password, then type it in when asked (the input is hidden):

   ```bash
   openssl rand -base64 24
   ```

   ```bash
   read -rs MONITOR_DB_PASSWORD && export MONITOR_DB_PASSWORD
   ```

   ```bash
   docker exec -i -e MONITOR_DB_PASSWORD falcon-postgres psql -U postgres -d falcon_ai -v ON_ERROR_STOP=1 < scripts/performance/create-monitor-role.sql
   ```

   Expect one row: `falcon_monitor | t | f | 3 | t`. On a re-run you'll also see a harmless
   `NOTICE: role "falcon_monitor" has already been granted membership in role "pg_monitor"`.

2. **Put the same password in `.env.storage`.** Edit the file with your editor and set:

   ```
   MONITORING_ENABLED=true
   MONITOR_DB_USER=falcon_monitor
   MONITOR_DB_PASSWORD=<the password from step 1>
   ```

   Then clear it from your shell:

   ```bash
   unset MONITOR_DB_PASSWORD
   ```

3. **Dry run.** Check that only the two exporters would be created and nothing else would be touched:

   ```bash
   $DC --profile monitoring up -d --no-deps --dry-run postgres-exporter node-exporter
   ```

   Go on only if the only containers listed are `falcon-postgres-exporter` and `falcon-node-exporter`. **Stop** if it lists the
   `falcon-postgres` or `falcon-minio` container, or shows the `falcon-storage_falcon-net` network or `falcon-storage_postgres_data`
   volume as `Created`. On a host where the storage stack is running these already exist, so `Created` means compose is pointed at
   a different project. A new network means the project name doesn't match the running stack;
   check `COMPOSE_PROJECT_NAME` against `docker inspect falcon-postgres --format '{{index .Config.Labels "com.docker.compose.project"}}'`.

4. **Start only the exporters.** `--no-deps` makes sure Postgres is not touched:

   ```bash
   $DC --profile monitoring up -d --no-deps postgres-exporter node-exporter
   ```

5. **Verify.** All of these should print something:

   ```bash
   docker ps --filter name=falcon-postgres-exporter --filter name=falcon-node-exporter --format '{{.Names}} {{.Status}}'
   ```

   Expect `pg_up 1` and `pg_exporter_last_scrape_error 0`:

   ```bash
   curl -s 127.0.0.1:9187/metrics | grep -E '^pg_up |^pg_exporter_last_scrape_error '
   ```

   Every collector should report `1`. If one reports `0`, record which; it may be a PG18 compatibility gap, handled in P1.7c.

   ```bash
   curl -s 127.0.0.1:9187/metrics | grep -E '^pg_scrape_collector_success'
   ```

   Host disk, memory and CPU:

   ```bash
   curl -s 127.0.0.1:9100/metrics | grep -E '^node_filesystem_avail_bytes|^node_memory_MemAvailable_bytes|^node_load1 '
   ```

   And from another machine, check that the ports are **not** reachable on the server's public IP (expect a connection failure):

   ```bash
   curl -m 5 http://<storage-server-ip>:9187/metrics
   ```

6. **Record the first Phase 0 numbers** in `docs/db/scaling/p0-2-table-inventory.md` / `p0-4-connections.md`. These are snapshots
   until Prometheus exists (P1.7b):

   ```bash
   curl -s 127.0.0.1:9187/metrics | grep -E '^pg_database_size_bytes|^pg_stat_activity_count|^pg_settings_max_connections '
   ```

   ```bash
   curl -s 127.0.0.1:9100/metrics | grep -E '^node_filesystem_(size|avail)_bytes' | grep -vE 'tmpfs|overlay'
   ```

7. **Watch for 15 minutes:** the exporter containers stay `Up`, their logs show no errors, and app latency doesn't change.

   ```bash
   docker logs --tail 50 falcon-postgres-exporter
   ```

8. **Update the checklist** (P1.7a) with the results, following the rules at the top of the plan. Paste output here only after
   removing hostnames and IPs.

## Rollback (any time, takes seconds)

Stop and remove the two containers. Postgres is not touched:

```bash
$DC --profile monitoring rm -sf postgres-exporter node-exporter
```

Then set `MONITORING_ENABLED=false` in `.env.storage`. Optionally drop the role:

```bash
docker exec -i falcon-postgres psql -U postgres -d falcon_ai -c 'DROP ROLE IF EXISTS falcon_monitor;'
```

## What was tested before this PR, and what wasn't

Tested in the Claude session:
- Compose with monitoring off: the service list is unchanged, and `postgres` / `minio` / `minio-init` resolve byte-for-byte the same
  as on `stage`, with and without `wireguard`.
- Compose with monitoring on: both exporters appear, bound to `127.0.0.1`, even when `STORAGE_BIND_IP=0.0.0.0`.
- `deploy-storage.sh` opt-in logic: off when unset or `false`; on for `true` / `yes` / `TRUE`; stops with a clear error when enabled
  without a password.
- `create-monitor-role.sql` on a throwaway PostgreSQL **16**:
  - it stops without a password, or with a short one, and changes nothing;
  - it creates the role, and re-running it is safe and rotates the password;
  - the old and wrong passwords are rejected;
  - the role can read `pg_stat_activity`, database sizes and `pg_settings`;
  - the role is denied reading app tables and creating objects;
  - it refuses to modify a superuser role;
  - the password appears 0 times in a `log_statement=all` server log.

**Not tested. Do this on stage (steps 3–7):**
- The exporters themselves: the session couldn't pull or run their images.
- PostgreSQL **18**, which is what prod runs.
