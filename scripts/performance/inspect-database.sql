-- Read-only operational baseline. No credentials, raw query text, or user data.
-- Run: ./scripts/deploy/db.sh perf-inspect
--
-- Every query here reads catalog/statistics views only (no table scans), so it
-- is cheap. It used to run inside one transaction with SET LOCAL
-- statement_timeout = '5s' and ON_ERROR_STOP: on a busy database (alpha,
-- 2026-09-26) one slow catalog read hit the 5 s limit and aborted the whole
-- report. Now: a generous per-session timeout, a short lock wait, read-only
-- session, and each section runs independently so one failure does not hide
-- the rest.
\set ON_ERROR_STOP off
SET statement_timeout = '60s';
SET lock_timeout = '2s';
SET default_transaction_read_only = on;
SET application_name = 'falcon-perf-inspect';

\echo '== server'
SELECT version();
SELECT name, setting, unit FROM pg_settings WHERE name IN
 ('max_connections','shared_buffers','work_mem','effective_cache_size','statement_timeout',
  'lock_timeout','idle_in_transaction_session_timeout','max_parallel_workers_per_gather',
  'random_page_cost','shared_preload_libraries')
ORDER BY name;

\echo '== connections by application (current database)'
SELECT application_name, state, wait_event_type, count(*) AS connections,
       max(now() - query_start) FILTER (WHERE state = 'active') AS longest_active
FROM pg_stat_activity WHERE datname = current_database()
GROUP BY application_name, state, wait_event_type
ORDER BY application_name, state;

\echo '== largest tables (statistics, not counts)'
SELECT relname, n_live_tup, n_dead_tup, seq_scan, idx_scan, last_autovacuum, last_autoanalyze
FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 25;

\echo '== invalid or not-ready indexes (should be empty)'
SELECT c.relname AS index, t.relname AS "table", i.indisvalid, i.indisready
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_class t ON t.oid = i.indrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = current_schema() AND (NOT i.indisvalid OR NOT i.indisready);

\echo '== performance indexes (search_tsv / trigram) with size'
SELECT c.relname AS index, t.relname AS "table", i.indisvalid,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_class t ON t.oid = i.indrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = current_schema()
  AND (c.relname LIKE '%trgm%' OR c.relname LIKE '%search_tsv%' OR c.relname LIKE '%coalesce%')
ORDER BY t.relname, c.relname;

\echo '== extensions'
SELECT extname, extversion FROM pg_extension ORDER BY extname;

-- If pg_stat_statements is enabled, use queryid to correlate plans privately.
SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') AS has_stats \gset
\if :has_stats
\echo '== top statements by total time (query text omitted)'
SELECT queryid, calls, round(total_exec_time) AS total_ms, round(mean_exec_time) AS mean_ms, rows,
       shared_blks_read, shared_blks_hit
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 25;
\endif
