-- ============================================================================
-- Backfill search_tsv on the live search layer tables (rows where it IS NULL)
-- ============================================================================
-- For beta and fresh databases that just received
-- scripts/performance/apply-search-tsv-schema.sql (db.sh perf-schema): rows
-- written before the triggers existed have search_tsv NULL. Prod does not
-- need it (its triggers have always been there).
--
-- Run OFF-PEAK, after perf-schema (docs/performance/RUNBOOK.md §4):
--   bash ./scripts/deploy/db.sh psql -- -f - < scripts/performance/backfill-search-tsv.sql
-- (stdin, because psql runs in a throwaway container that cannot see host
-- files; NOT with --single-transaction: the loop commits per batch.)
--
-- Tables: news_articles, news_headlines, social_posts, campaigns,
-- post_comments, videos, video_segments, profile_ai_analytics,
-- post_ai_analysis, social_post_fact_checks, trending_category_intelligence.
-- news_ai_analysis has its own script (backfill-ai-search-tsv.sql).
--
-- How: same as backfill-ai-search-tsv.sql. Keyset by primary key (text cuid)
-- in batches of 1000, COMMIT per batch, pg_sleep(0.2) between batches, and the
-- value is computed by FIRING THE EXISTING TRIGGER, never by a second copy of
-- its expression. The no-op UPDATE sets a column the trigger watches to
-- itself (SET col = col): several triggers are BEFORE UPDATE OF <columns>, and
-- `SET search_tsv = NULL` would not fire those (it would write NULL over NULL
-- and report success). Refuses to run when any of the triggers is missing or
-- disabled. Prisma's @updatedAt is client-side, so "updatedAt" is NOT touched.
-- Other BEFORE/AFTER UPDATE triggers on these tables (if any) also fire.
--
-- Cost note: news_articles' trigger walks up to 4000 characters of content per
-- row (falcon_safe_left), so that table is the slow one.
--
-- Safe to stop (Ctrl-C) and rerun at any point: finished batches are
-- committed, and only rows still NULL are selected. The trigger never yields
-- NULL (empty text gives an EMPTY tsvector), so no row is picked twice.
--
-- Locks: each batch takes row locks on at most 1000 rows. lock_timeout is
-- 2 s per batch (a row being written is skipped for now: the batch is retried
-- up to 5 times, then left for the next run).
--
-- Progress: RAISE NOTICE per table and every 10th batch. From another session:
--   SELECT count(*) FILTER (WHERE search_tsv IS NULL) AS remaining, count(*) FROM social_posts;
-- Afterwards autovacuum cleans the old row versions; optionally VACUUM (ANALYZE) <table>.
-- ============================================================================
\set ON_ERROR_STOP on
SET lock_timeout = '2s';
SET statement_timeout = '0';

-- table, trigger, a column the trigger watches (touched as SET col = col)
CREATE TEMP TABLE falcon_search_tsv_backfill_targets (ord int, tbl text, trg text, col text);
INSERT INTO falcon_search_tsv_backfill_targets VALUES
  (1,  'news_headlines',                 'news_headlines_tsv_update',                     'title'),
  (2,  'campaigns',                      'campaigns_tsv_update',                          'name'),
  (3,  'social_posts',                   'social_posts_tsv_update',                       'caption'),
  (4,  'post_comments',                  'trg_post_comments_search_tsv',                  'text'),
  (5,  'videos',                         'trg_videos_search_tsv',                         'title'),
  (6,  'video_segments',                 'trg_video_segments_search_tsv',                 'text'),
  (7,  'profile_ai_analytics',           'trg_profile_ai_analytics_search_tsv',           'profileSummary'),
  (8,  'post_ai_analysis',               'trg_post_ai_analysis_search_tsv',               'summary'),
  (9,  'social_post_fact_checks',        'trg_social_post_fact_checks_search_tsv',        'claimText'),
  (10, 'trending_category_intelligence', 'trg_trending_category_intelligence_search_tsv', 'aiKeyword'),
  (11, 'news_articles',                  'news_articles_tsv_update',                      'title');

DO $$
DECLARE
  missing text;
BEGIN
  SELECT string_agg(t.tbl || '.' || t.trg, ', ' ORDER BY t.ord) INTO missing
    FROM falcon_search_tsv_backfill_targets t
   WHERE NOT EXISTS (SELECT 1 FROM pg_trigger g
                      WHERE g.tgrelid = to_regclass(t.tbl) AND g.tgname = t.trg AND g.tgenabled <> 'D');
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'search_tsv trigger(s) missing or disabled: %. Apply scripts/performance/apply-search-tsv-schema.sql (db.sh perf-schema) first.', missing;
  END IF;
END $$;

DO $$
DECLARE
  batch_size constant int := 1000;
  max_retries constant int := 5;
  tbls text[];
  cols text[];
  k int;
  last_id text;
  hi text;
  n int;
  retries int;
  batches int;
  done bigint;
  remaining bigint;
  started timestamptz;
BEGIN
  -- Arrays, not a FOR-over-query loop: the loop below COMMITs.
  SELECT array_agg(tbl ORDER BY ord), array_agg(col ORDER BY ord) INTO tbls, cols
    FROM falcon_search_tsv_backfill_targets;
  FOR k IN 1 .. array_length(tbls, 1) LOOP
    last_id := '';
    retries := 0;
    batches := 0;
    done := 0;
    started := clock_timestamp();
    EXECUTE format('SELECT count(*) FROM %I WHERE search_tsv IS NULL', tbls[k]) INTO remaining;
    RAISE NOTICE '%: % rows with search_tsv NULL', tbls[k], remaining;
    CONTINUE WHEN remaining = 0;
    LOOP
      -- Per-batch lock bound (transaction-local, so set again after every COMMIT).
      PERFORM set_config('lock_timeout', '2s', true);
      EXECUTE format('SELECT max(b.id) FROM (SELECT id FROM %I WHERE search_tsv IS NULL AND id > $1 ORDER BY id LIMIT %s) b',
                     tbls[k], batch_size)
        INTO hi USING last_id;
      EXIT WHEN hi IS NULL;
      BEGIN
        EXECUTE format('UPDATE %I SET %I = %I WHERE id > $1 AND id <= $2 AND search_tsv IS NULL',
                       tbls[k], cols[k], cols[k])
          USING last_id, hi;
        GET DIAGNOSTICS n = ROW_COUNT;
      EXCEPTION WHEN lock_not_available THEN
        n := -1;
      END;
      IF n < 0 THEN
        retries := retries + 1;
        IF retries > max_retries THEN
          RAISE NOTICE '%: batch (%, %] still locked after % tries; skipped (rerun later picks it up)', tbls[k], last_id, hi, max_retries;
          last_id := hi;
          retries := 0;
        ELSE
          RAISE NOTICE '%: batch (%, %] hit lock_timeout; retry %', tbls[k], last_id, hi, retries;
        END IF;
      ELSE
        done := done + n;
        batches := batches + 1;
        last_id := hi;
        retries := 0;
        IF batches % 10 = 1 THEN
          RAISE NOTICE '%: batch %: % rows (last id %), % of % done, % elapsed',
            tbls[k], batches, n, hi, done, remaining, date_trunc('second', clock_timestamp() - started);
        END IF;
      END IF;
      COMMIT;
      PERFORM pg_sleep(0.2);
    END LOOP;
    RAISE NOTICE '%: finished, % rows in % batches, % elapsed',
      tbls[k], done, batches, date_trunc('second', clock_timestamp() - started);
  END LOOP;
END $$;

SELECT 'news_articles' AS tbl, count(*) FILTER (WHERE search_tsv IS NULL) AS still_null, count(*) AS total FROM news_articles
UNION ALL SELECT 'news_headlines', count(*) FILTER (WHERE search_tsv IS NULL), count(*) FROM news_headlines
UNION ALL SELECT 'social_posts', count(*) FILTER (WHERE search_tsv IS NULL), count(*) FROM social_posts
UNION ALL SELECT 'campaigns', count(*) FILTER (WHERE search_tsv IS NULL), count(*) FROM campaigns
UNION ALL SELECT 'post_comments', count(*) FILTER (WHERE search_tsv IS NULL), count(*) FROM post_comments
UNION ALL SELECT 'videos', count(*) FILTER (WHERE search_tsv IS NULL), count(*) FROM videos
UNION ALL SELECT 'video_segments', count(*) FILTER (WHERE search_tsv IS NULL), count(*) FROM video_segments
UNION ALL SELECT 'profile_ai_analytics', count(*) FILTER (WHERE search_tsv IS NULL), count(*) FROM profile_ai_analytics
UNION ALL SELECT 'post_ai_analysis', count(*) FILTER (WHERE search_tsv IS NULL), count(*) FROM post_ai_analysis
UNION ALL SELECT 'social_post_fact_checks', count(*) FILTER (WHERE search_tsv IS NULL), count(*) FROM social_post_fact_checks
UNION ALL SELECT 'trending_category_intelligence', count(*) FILTER (WHERE search_tsv IS NULL), count(*) FROM trending_category_intelligence;
