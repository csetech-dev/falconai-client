-- Top queries from pg_stat_statements (scaling plan P0.1 / P0.3). READ-ONLY.
-- Run on the storage server after pg_stat_statements has collected normal traffic (a day is ideal):
--   docker exec -i falcon-postgres psql -U postgres -d falcon_ai < scripts/performance/top-queries.sql
-- Use the -U/-d values the enable step printed if yours differ. The role column tells the app's queries from the exporter's.
-- Query text is normalised by PostgreSQL (values become $1, $2 ...). Still look it over before sharing.
\set QUIET on
\pset pager off
\pset footer off
\set QUIET off

\echo '== Collected since (statistics reset):'
SELECT stats_reset, dealloc AS entries_evicted FROM pg_stat_statements_info;
-- entries_evicted > 0 means pg_stat_statements.max was too small and some queries were dropped from the lists.

\echo
\echo '== Top 15 by TOTAL time (what costs the database most overall)'
SELECT round(total_exec_time::numeric / 1000, 1) AS total_s,
       calls,
       round(mean_exec_time::numeric, 1)          AS mean_ms,
       rows,
       shared_blks_read                           AS blks_read,
       round(100.0 * shared_blks_hit / nullif(shared_blks_hit + shared_blks_read, 0), 1) AS hit_pct,
       userid::regrole                            AS role,
       left(regexp_replace(query, '\s+', ' ', 'g'), 160) AS query
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  AND query NOT ILIKE '%pg_stat_statements%'
ORDER BY total_exec_time DESC
LIMIT 15;

\echo
\echo '== Top 15 by blocks read from outside shared_buffers (the cache misses behind PostgresCacheHitLow)'
SELECT shared_blks_read                           AS blks_read,
       pg_size_pretty(shared_blks_read * current_setting('block_size')::bigint) AS read_volume,
       calls,
       round(mean_exec_time::numeric, 1)          AS mean_ms,
       userid::regrole                            AS role,
       left(regexp_replace(query, '\s+', ' ', 'g'), 160) AS query
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  AND query NOT ILIKE '%pg_stat_statements%'
ORDER BY shared_blks_read DESC
LIMIT 15;

\echo
\echo '== Top 15 by number of calls'
SELECT calls,
       round(mean_exec_time::numeric, 2)          AS mean_ms,
       round(total_exec_time::numeric / 1000, 1)  AS total_s,
       userid::regrole                            AS role,
       left(regexp_replace(query, '\s+', ' ', 'g'), 160) AS query
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  AND query NOT ILIKE '%pg_stat_statements%'
ORDER BY calls DESC
LIMIT 15;
