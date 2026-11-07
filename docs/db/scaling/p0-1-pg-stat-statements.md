# P0.1 — Turn on pg_stat_statements

`pg_stat_statements` records, for every distinct query, how often it ran, how long it took and how much it read from disk.
We need it to name the queries behind the full scans of `news_articles` and `social_posts` and the low cache-hit ratio
(stage: 70.7%, about 147 MB/s read from outside shared_buffers).

**What it costs:** one PostgreSQL restart, usually 10–30 seconds when the database refuses connections. The script runs a
`CHECKPOINT` first so the shutdown is quick, and gives PostgreSQL up to 120 seconds to stop cleanly. Every app connection
drops and reconnects. After that, the overhead is small (a few percent of CPU at most).

**How it's stored:** the script uses `ALTER SYSTEM`. The setting goes into `postgresql.auto.conf` in **this server's** data
volume, not into `docker-compose.storage.yml`. Stage and prod share the same bundle, so this keeps prod unchanged until someone runs
the script on prod.

Run everything on the **storage server**, in `/opt/falconai-client`, after pulling the bundle that contains
`scripts/deploy/pg-stat-statements.sh`.

## 1. Check the current state (changes nothing)

```bash
sudo bash scripts/deploy/pg-stat-statements.sh status
```

Expect `pg_stat_statements: off`, and the current `shared_preload_libraries` value, which is usually empty.

## 2. Dry run (changes nothing)

```bash
sudo bash scripts/deploy/pg-stat-statements.sh enable --dry-run
```

It prints the plan: the new `shared_preload_libraries` value and that it will restart once.

## 3. Turn it on, at a quiet moment

```bash
sudo bash scripts/deploy/pg-stat-statements.sh enable
```

It runs its checks first, then asks **once** before changing anything. Answering anything but `y` leaves the server exactly as it
was. After `y` it saves the setting, restarts, waits for PostgreSQL to answer (up to 2 minutes), creates the extension and checks it
answers. Expect `✅ pg_stat_statements is on`.

Exit codes:
- `0` means done.
- `2` means it refused before changing anything. Causes include:
  - not root, or not the storage server. It checks that `falcon-postgres` belongs to the `falcon-storage` compose project, so
    an old single-host `falcon-postgres` on the app server is refused;
  - the library missing from the image;
  - `shared_preload_libraries` set on the Postgres command line;
  - errors in the config files, or changes waiting for a restart that someone else made. A restart would apply those too.
    Values overridden on the command line (`-c max_connections=…` in `docker-compose.storage.yml`) are expected and ignored;
  - you answering no.
- `4` means the restart or the check failed. It prints the exact recovery commands, the same as in [Rollback](#rollback-if-postgresql-does-not-come-back).

Then check the app: open FalconAI and load a news page. In Grafana, the **FalconAI Database** dashboard should show PostgreSQL up.

## 4. Report, after about a day of normal traffic

```bash
docker exec -i falcon-postgres psql -U postgres -d falcon_ai < scripts/performance/top-queries.sql
```

If the `enable` step printed a different user or database, use the command it printed. The report is read-only. It prints three lists of 15:
- by total time;
- by blocks read from outside shared_buffers (the cache misses);
- by number of calls.

Each row shows the `role` that ran the query, so the monitoring exporter's queries can be told apart from the app's. If
`entries_evicted` at the top isn't 0, some queries were dropped from the lists. PostgreSQL replaces values in the query text with `$1, $2 …`. Still look the text over before you paste it anywhere public. Send
the output to the team; it's the input for P0.3 and the Phase 2 fixes.

## Turn it off

```bash
sudo bash scripts/deploy/pg-stat-statements.sh disable
```

It drops the extension and removes only `pg_stat_statements` from `shared_preload_libraries`, keeping any other libraries. One restart.

## Rollback if PostgreSQL does not come back

1. **Look at the log first:**

   ```bash
   docker logs --tail 30 falcon-postgres
   ```

   If it says `database system was interrupted` or `redo in progress`, PostgreSQL is recovering normally. **Wait**, and change
   nothing. Check again with:

   ```bash
   docker exec falcon-postgres pg_isready
   ```

2. Only if the log shows it **failing** to start, remove the one line the script added, then start it. These commands use the
   container's own volume and image, so nothing needs downloading:

   ```bash
   docker run --rm --volumes-from falcon-postgres --entrypoint sed pgvector/pgvector:0.8.1-pg18 -i '/^shared_preload_libraries/d' /var/lib/postgresql/18/docker/postgresql.auto.conf
   ```

   ```bash
   docker start falcon-postgres
   ```

The script prints these commands with this server's real image and data directory, plus the value
`shared_preload_libraries` had before. Use the printed ones. If the old value wasn't empty, the printed text also shows how to put
it back.

## Production

Same steps on the prod storage server (192.168.180.105), by someone with prod access, at an agreed quiet time. Nothing changes on
prod until the script runs there.
