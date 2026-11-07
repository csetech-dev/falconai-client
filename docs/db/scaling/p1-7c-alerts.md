# What to do when an alert fires (P1.7c)

Each alert in Grafana and Alertmanager links here. Rules: `infra/monitoring/prometheus/rules/`. Dashboards: Grafana → **FalconAI**.

**Before you act:**
- **Don't restart PostgreSQL to make an alert go away.** Most of these need a look, not a restart, and a restart drops every
  connection.
- Note what you did in the team channel.
- Unless a section says otherwise, run commands on the **storage server**, in `/opt/falconai-client`.
- Read-only database queries use:

  ```bash
  docker exec -it falcon-postgres psql -U postgres -d falcon_ai
  ```

## PostgresDown

PostgreSQL isn't answering the exporter for 2 minutes. The app is probably failing too.

1. Is the container running? Run `docker ps --filter name=falcon-postgres`. If it isn't, run `docker logs --tail 50 falcon-postgres`
   and send the output to the team.
2. Check the disk (`df -h /`). A full disk stops PostgreSQL, so see **StorageDiskFilling**.
3. If Postgres runs but the exporter fails, check `docker logs --tail 20 falcon-postgres-exporter`. A password error means the
   monitoring role's password changed: re-run `sudo bash scripts/deploy/monitoring-setup-storage.sh`.

## PostgresConnectionsHigh

More than 80% of `max_connections` has been in use for 10 minutes. New connections may soon be refused.

1. See which apps hold them (read-only):

   ```sql
   SELECT application_name, state, count(*) FROM pg_stat_activity GROUP BY 1,2 ORDER BY 3 DESC;
   ```

2. Many `idle` connections from one service means its pool is too large. Many `idle in transaction` means a code path that doesn't
   finish its transaction (see **PostgresLongTransaction**).
3. The long-term fix is PgBouncer (plan item P1.4). Don't raise `max_connections` without checking memory.

## PostgresLongTransaction

A transaction has been running, or idle inside a transaction, for more than 5 minutes. It blocks VACUUM and can hold locks.

Only application connections count (`backend_type="client backend"`); autovacuum and other background workers never trigger it. A
manual `pg_dump` / `scripts/dump-db.sh` is a client connection, so a long dump does trigger it, and that's harmless.

1. Find it (read-only):

   ```sql
   SELECT pid, application_name, state, now() - xact_start AS age, left(query, 120) FROM pg_stat_activity WHERE xact_start IS NOT NULL ORDER BY age DESC LIMIT 5;
   ```

2. If it's a known long job (an export, a migration, a backfill), let it finish.
3. **Never end an autovacuum worker** (its query starts with `autovacuum:`). It cleans up dead rows and restarts later anyway.
4. If it's `idle in transaction` (or `idle in transaction (aborted)`) and clearly stuck, ask the team before ending it. Ending it
   rolls back its work:

   ```sql
   SELECT pg_terminate_backend(<pid>);
   ```

## PostgresDeadTuplesHigh

A table has over 1 million dead rows, more than 20% of its live rows, for 30 minutes. Queries on it get slower and it takes more disk.

1. Check whether autovacuum is running on it (read-only):

   ```sql
   SELECT relname, n_dead_tup, last_autovacuum FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 5;
   ```

2. A long-running transaction stops cleanup, so check **PostgresLongTransaction** first.
3. If nothing blocks it, a manual VACUUM in a **quiet period** is safe; it doesn't lock reads or writes. A manual VACUUM isn't
   throttled, though, so on a big table slow it down first so it doesn't saturate the disk:

   ```sql
   SET vacuum_cost_delay = 2; VACUUM (VERBOSE) <table>;
   ```

4. If this keeps happening on the same table, it needs per-table autovacuum settings (plan item P2) or partitioning (P3).

## PostgresAutovacuumStale

A table with over 100,000 dead rows hasn't been autovacuumed for 7 days, **or ever**. A table cleaned only by manual VACUUM also
counts here, because only autovacuum is tracked.

1. As for **PostgresDeadTuplesHigh**: check for long transactions, then run a manual `VACUUM` in a quiet period.
2. Check autovacuum is enabled:

   ```sql
   SHOW autovacuum;
   ```

## PostgresDeadlocks

PostgreSQL detected a deadlock in the last 10 minutes and cancelled one of the transactions. The app saw an error for it.

1. The details are in the Postgres log:

   ```bash
   docker logs falcon-postgres 2>&1 | grep -A5 -i deadlock | tail -30
   ```

2. Send the two statements involved to the team. This is fixed in code (a consistent lock order), not on the server.

## PostgresCacheHitLow

Under 95% of reads have come from memory for 30 minutes, so reads are going to disk and queries are slower.

1. Look at the Database dashboard: did it drop during a big report or export? If so, it recovers on its own.
2. If it stays low, the working data no longer fits in memory. That's an input for tuning and capacity (plan items P1.5 and P0.6).

## MonitoringTargetDown

Prometheus can't scrape a target for 5 minutes. The `job` label says which one.

- `postgres` / `node-storage`, on the storage server:
  - `docker ps --filter name=exporter`;
  - then re-run `sudo bash scripts/deploy/monitoring-setup-storage.sh`, which checks and repairs.
  - A TLS error usually means the certificate expired or was rotated, so re-run with `--rotate` and then the app setup.
- `falcon-core` / `falcon-search`: is the app up? A 404 means the app has no `METRICS_TOKEN`.
- `prometheus` / `alertmanager`, on the app server: `docker ps --filter name=falcon-`.

## StorageDiskFilling

The storage server's `/` is over 70% (warning) or 85% (critical) full. **PostgreSQL stops when the disk is full.**

1. See what's growing:

   ```bash
   df -h /
   ```

   ```bash
   du -xh --max-depth=1 /var/lib/docker/volumes | sort -h | tail
   ```

2. On stage, the volume group had unallocated space, which you can check with `vgs`. Growing the disk online is in
   `p0-2-table-inventory.md`.
3. **Don't delete Docker volumes.** They hold the database and MinIO files. Old images can be removed with the team's agreement.

## StorageMemoryLow

Under 10% of memory has been available on the storage server for 10 minutes.

1. See which processes use it:

   ```bash
   docker stats --no-stream
   ```

   ```bash
   top -o %MEM
   ```

2. Other projects share the stage storage server, so check them too.

## AppDatabasePoolTimeouts

An app service waited too long for a free database connection. Users see slow or failed requests.

1. Check **PostgresConnectionsHigh** and **PostgresLongTransaction**: connections are either all in use, or held too long.
2. Send the service name and the time to the team.

## AppHttp5xxHigh

Over 5% of one service's requests returned 5xx for 5 minutes, with real traffic (over 1 request per second).

1. In Grafana → FalconAI Reliability, check which routes fail.
2. Check that service's logs on the app server. Use `falcon-core` for service `core`, and `falcon-search` for the search service:

   ```bash
   docker logs --since 10m falcon-core 2>&1 | grep -iE 'error|exception' | tail -30
   ```

3. Check the database alerts at the same time.

## SearchUnavailable

search-service has reported its search backend as unavailable for 5 minutes. Search pages fail or fall back.

1. On the app server:

   ```bash
   docker ps --filter name=opensearch
   ```

   ```bash
   docker logs --tail 30 falcon-search
   ```

2. Check the app server's disk and memory.
