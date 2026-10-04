-- ============================================================================
-- Backfill news_articles.ai_search_tsv (the combined AI-analysis vector)
-- ============================================================================
-- Run OFF-PEAK, AFTER `db push` (the column) and `db.sh perf-schema` (the
-- function, the triggers and the index), e.g. detached on the server:
--   nohup bash ./scripts/deploy/db.sh psql -- -f - < scripts/performance/backfill-news-ai-search-tsv.sql > backfill-news-ai-tsv-$(date +%F-%H%M).log 2>&1 &
-- (stdin, because psql runs in a throwaway container that cannot see host
-- files; NOT with --single-transaction: the loop commits per batch.)
-- Resume from an article id (the last "last id" in the log):
--   bash ./scripts/deploy/db.sh psql -- -v from_id=<id> -f - < scripts/performance/backfill-news-ai-search-tsv.sql
--
-- Why: /news?search= matches AI analyses through news_articles.ai_search_tsv
-- (news_articles_ai_search_tsv_gin_idx) instead of the wide news_ai_analysis
-- table. The triggers keep the column current from now on; this fills the
-- articles analysed before them. Until it has finished, the app keeps the old
-- path: it checks for the marker this script sets at the end (COMMENT ON
-- COLUMN news_articles.ai_search_tsv = 'falcon:backfilled …'), see
-- NEWS_AI_COLUMN_PROBE_SQL in news-search-progressive.ts.
--
-- How: keyset by news_articles.id (text cuid) in batches of 1000, COMMIT per
-- batch, pg_sleep(0.1) between batches. Each row gets
-- news_articles_ai_search_tsv_of(id), the SAME function the triggers use (one
-- definition, no drift), and is written only when the value differs, so a
-- rerun writes nothing that is already right. Articles without analyses stay
-- NULL and are not written. The function is evaluated inside the UPDATE, after
-- the row lock: if an analysis trigger updates the same article concurrently,
-- PostgreSQL re-evaluates the row and the function with a fresh snapshot, so
-- the backfill never overwrites a newer value with an older one.
--
-- Locks: row locks on at most 1000 articles per batch. lock_timeout 2 s per
-- batch; a batch that hits it is retried up to 5 times, then skipped (a rerun
-- picks it up; the marker is then NOT set). statement_timeout is 0: inside a
-- DO block it would time the whole loop.
--
-- Progress: RAISE NOTICE every 10 batches. From another session:
--   SELECT count(*) FROM news_articles WHERE ai_search_tsv IS NOT NULL;
-- Afterwards autovacuum cleans the old row versions; optionally
--   VACUUM (ANALYZE) news_articles;
-- ============================================================================
\set ON_ERROR_STOP on
SET lock_timeout = '2s';
SET statement_timeout = '0';
\if :{?from_id}
\else
\set from_id ''
\endif
SELECT set_config('falcon.backfill_from_id', :'from_id', false);

DO $$
BEGIN
  IF to_regprocedure('news_articles_ai_search_tsv_of(text)') IS NULL THEN
    RAISE EXCEPTION 'news_articles_ai_search_tsv_of(text) is missing: apply scripts/performance/apply-performance-schema.sql (db.sh perf-schema) first.';
  END IF;
  IF (SELECT count(*) FROM pg_trigger
       WHERE tgrelid = 'news_ai_analysis'::regclass AND tgenabled <> 'D'
         AND tgname IN ('trg_news_ai_analysis_article_tsv_ins', 'trg_news_ai_analysis_article_tsv_upd', 'trg_news_ai_analysis_article_tsv_del')) <> 3 THEN
    RAISE EXCEPTION 'trg_news_ai_analysis_article_tsv_{ins,upd,del} missing or disabled: apply scripts/performance/apply-performance-schema.sql (db.sh perf-schema) first. Backfilling without them would go stale at once.';
  END IF;
END $$;

DO $$
DECLARE
  batch_size constant int := 1000;
  max_retries constant int := 5;
  last_id text := current_setting('falcon.backfill_from_id');
  hi text;
  n int;
  retries int := 0;
  skipped int := 0;
  batches int := 0;
  written bigint := 0;
  started timestamptz := clock_timestamp();
BEGIN
  RAISE NOTICE 'ai_search_tsv backfill: starting after id %', CASE WHEN last_id = '' THEN '(start)' ELSE last_id END;
  LOOP
    -- Per-batch lock bound (transaction-local, so set again after every COMMIT).
    PERFORM set_config('lock_timeout', '2s', true);
    SELECT max(b.id) INTO hi
      FROM (SELECT id FROM news_articles WHERE id > last_id ORDER BY id LIMIT batch_size) b;
    EXIT WHEN hi IS NULL;
    BEGIN
      UPDATE news_articles na
         SET ai_search_tsv = news_articles_ai_search_tsv_of(na.id)
       WHERE na.id > last_id AND na.id <= hi
         AND na.ai_search_tsv IS DISTINCT FROM news_articles_ai_search_tsv_of(na.id);
      GET DIAGNOSTICS n = ROW_COUNT;
    EXCEPTION WHEN lock_not_available THEN
      n := -1;
    END;
    IF n < 0 THEN
      retries := retries + 1;
      IF retries > max_retries THEN
        RAISE NOTICE 'batch (%, %] still locked after % tries; skipped (rerun later picks it up)', last_id, hi, max_retries;
        skipped := skipped + 1;
        last_id := hi;
        retries := 0;
      ELSE
        RAISE NOTICE 'batch (%, %] hit lock_timeout; retry %', last_id, hi, retries;
      END IF;
    ELSE
      written := written + n;
      batches := batches + 1;
      last_id := hi;
      retries := 0;
      IF batches % 10 = 1 THEN
        RAISE NOTICE 'batch %: last id %, % rows written so far, % elapsed',
          batches, hi, written, date_trunc('second', clock_timestamp() - started);
      END IF;
    END IF;
    COMMIT;
    PERFORM pg_sleep(0.1);
  END LOOP;
  RAISE NOTICE 'ai_search_tsv backfill finished: % batches, % rows written, % batches skipped, % elapsed',
    batches, written, skipped, date_trunc('second', clock_timestamp() - started);
  -- The marker the app waits for: only after a COMPLETE pass from the start
  -- of the table with nothing skipped (a resumed run covers only the rest).
  IF skipped = 0 AND current_setting('falcon.backfill_from_id') = '' THEN
    -- COMMENT takes SHARE UPDATE EXCLUSIVE (never blocks reads or writes; an
    -- autovacuum in the way is cancelled after deadlock_timeout).
    PERFORM set_config('lock_timeout', '30s', true);
    BEGIN
      EXECUTE format('COMMENT ON COLUMN news_articles.ai_search_tsv IS %L',
                     'falcon:backfilled ' || to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
      RAISE NOTICE 'marker set: the app now matches AI analyses through news_articles.ai_search_tsv (within 5 min)';
    EXCEPTION WHEN lock_not_available THEN
      RAISE NOTICE 'marker NOT set (lock timeout): rerun this script; it writes nothing new and sets the marker';
    END;
  ELSE
    RAISE NOTICE 'marker NOT set (resumed run or skipped batches): rerun once from the start (no from_id) off-peak; it writes only what is still missing';
  END IF;
END $$;

SELECT count(*) FILTER (WHERE ai_search_tsv IS NOT NULL) AS articles_with_ai_tsv,
       col_description('news_articles'::regclass,
                       (SELECT attnum FROM pg_attribute WHERE attrelid = 'news_articles'::regclass AND attname = 'ai_search_tsv')) AS marker
  FROM news_articles;
