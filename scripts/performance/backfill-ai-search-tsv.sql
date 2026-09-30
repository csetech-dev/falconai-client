-- ============================================================================
-- Backfill news_ai_analysis.search_tsv (rows where it IS NULL)
-- ============================================================================
-- Run OFF-PEAK (docs/performance/RUNBOOK.md, "AI search_tsv backfill"):
--   bash ./scripts/deploy/db.sh psql -- -f - < scripts/performance/backfill-ai-search-tsv.sql
-- (stdin, because psql runs in a throwaway container that cannot see host
-- files; NOT with --single-transaction: the loop commits per batch.)
--
-- Why: news text search matches news_ai_analysis.search_tsv through
-- news_ai_analysis_search_tsv_gin_idx. On beta (2026-09-30) the column is
-- filled for the last 30 days but 57–59 % of older rows are NULL (they
-- predate the trigger), so those analyses are invisible to search.
--
-- How: keyset by primary key (id, text cuid) in batches of 1000, COMMIT per
-- batch, pg_sleep(0.2) between batches.
--
-- Recompute path: a no-op UPDATE that FIRES THE EXISTING TRIGGER
-- (trg_news_ai_analysis_search_tsv → news_ai_analysis_search_tsv_update(),
-- BEFORE INSERT OR UPDATE, defined in apply-performance-schema.sql), rather
-- than repeating its to_tsvector(...) expression here. The trigger is the
-- single definition of the column: a second copy in this file could drift
-- from it (a field added to the trigger later would be missing from the
-- backfilled rows only, silently). The UPDATE sets search_tsv = NULL and
-- the BEFORE UPDATE trigger overwrites NEW.search_tsv with the recomputed
-- value. The script refuses to run when that trigger is missing or disabled
-- (it would then write NULL over NULL and report success). Prisma's
-- @updatedAt is client-side, so "updatedAt" is NOT touched.
--
-- Safe to stop (Ctrl-C) and rerun at any point: finished batches are
-- committed, and only rows still NULL are selected. A row whose fields are
-- all empty gets an EMPTY tsvector (not NULL), so it is not picked again.
--
-- Locks: each batch takes row locks on at most 1000 rows. lock_timeout is
-- 2 s per batch (a row being written by the AI pipeline is skipped for now:
-- the batch is retried up to 5 times, then left for the next run).
-- statement_timeout: inside a DO block it would time the WHOLE loop (one
-- top-level statement), not each batch, so it is 0 for the loop; each batch
-- is bounded by construction instead (1000 rows by primary key).
--
-- Progress: RAISE NOTICE per batch. From another session:
--   SELECT count(*) FILTER (WHERE search_tsv IS NULL) AS remaining, count(*) AS total
--     FROM news_ai_analysis;
-- Afterwards autovacuum cleans the old row versions; optionally run
--   VACUUM (ANALYZE) news_ai_analysis;
-- ============================================================================
\set ON_ERROR_STOP on
SET lock_timeout = '2s';
SET statement_timeout = '0';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
     WHERE c.relname = 'news_ai_analysis'
       AND t.tgname = 'trg_news_ai_analysis_search_tsv'
       AND t.tgenabled <> 'D'
  ) THEN
    RAISE EXCEPTION 'trg_news_ai_analysis_search_tsv is missing or disabled: apply scripts/performance/apply-performance-schema.sql (db.sh perf-schema) first.';
  END IF;
END $$;

DO $$
DECLARE
  batch_size constant int := 1000;
  max_retries constant int := 5;
  last_id text := '';
  hi text;
  n int;
  retries int := 0;
  batches int := 0;
  done bigint := 0;
  remaining bigint;
  started timestamptz := clock_timestamp();
BEGIN
  SELECT count(*) INTO remaining FROM news_ai_analysis WHERE search_tsv IS NULL;
  RAISE NOTICE 'search_tsv backfill: % rows are NULL', remaining;
  LOOP
    -- Per-batch lock bound (transaction-local, so set again after every COMMIT).
    PERFORM set_config('lock_timeout', '2s', true);
    SELECT max(b.id) INTO hi
      FROM (SELECT id FROM news_ai_analysis
             WHERE search_tsv IS NULL AND id > last_id
             ORDER BY id
             LIMIT batch_size) b;
    EXIT WHEN hi IS NULL;
    BEGIN
      -- search_tsv = NULL only makes the row an UPDATE target: the BEFORE
      -- UPDATE trigger replaces NEW.search_tsv with the recomputed vector.
      UPDATE news_ai_analysis
         SET search_tsv = NULL
       WHERE id > last_id AND id <= hi AND search_tsv IS NULL;
      GET DIAGNOSTICS n = ROW_COUNT;
    EXCEPTION WHEN lock_not_available THEN
      n := -1;
    END;
    IF n < 0 THEN
      retries := retries + 1;
      IF retries > max_retries THEN
        RAISE NOTICE 'batch (%, %] still locked after % tries; skipped (rerun later picks it up)', last_id, hi, max_retries;
        last_id := hi;
        retries := 0;
      ELSE
        RAISE NOTICE 'batch (%, %] hit lock_timeout; retry %', last_id, hi, retries;
      END IF;
    ELSE
      done := done + n;
      batches := batches + 1;
      last_id := hi;
      retries := 0;
      IF batches % 10 = 1 THEN
        RAISE NOTICE 'batch %: % rows (last id %), % of % done, % elapsed',
          batches, n, hi, done, remaining, date_trunc('second', clock_timestamp() - started);
      END IF;
    END IF;
    COMMIT;
    PERFORM pg_sleep(0.2);
  END LOOP;
  RAISE NOTICE 'search_tsv backfill finished: % rows in % batches, % elapsed',
    done, batches, date_trunc('second', clock_timestamp() - started);
END $$;

SELECT count(*) FILTER (WHERE search_tsv IS NULL) AS still_null,
       count(*) AS total
  FROM news_ai_analysis;
