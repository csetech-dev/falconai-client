-- Run with psql, without --single-transaction. Existing Prisma schema must be applied first.
\set ON_ERROR_STOP on
-- No lock_timeout: CREATE INDEX CONCURRENTLY waits for every older transaction
-- to finish (a lock wait), and a timeout there aborts the build and leaves an
-- INVALID index (alpha, 2026-09-26: desc_nl index left invalid under ingestion
-- with lock_timeout=5s). The build takes SHARE UPDATE EXCLUSIVE, which never
-- blocks reads or writes, so waiting is harmless.
SET lock_timeout = '0';
SET statement_timeout = '0';
-- One run at a time, enforced with a TRY lock that fails fast. A blocking
-- pg_advisory_lock() is worse than no lock: the waiting second run sits in an
-- open transaction, the first run's CREATE INDEX CONCURRENTLY waits for every
-- older transaction (including that one), the second waits for the first's
-- lock -> deadlock, and the cancelled build is left INVALID (beta, 2026-10).
-- The lock is session-level, so it outlives the DO block and is released when
-- psql disconnects (or by the unlock at the end).
DO $$ BEGIN
 IF NOT pg_try_advisory_lock(hashtext('falcon-performance-schema')) THEN
  RAISE EXCEPTION 'Another perf-schema run holds the falcon-performance-schema lock. Wait for it to finish (SELECT pid, query FROM pg_stat_activity WHERE query ILIKE ''%%CONCURRENTLY%%''), then rerun. Never run two at once.';
 END IF;
END $$;
-- Refuse to start while ANY index build is running (e.g. a hand-run CREATE
-- INDEX CONCURRENTLY): the advisory lock only covers other perf-schema runs, and
-- overlapping builds deadlock and leave an INVALID index (beta, 2026-10-05).
DO $$ DECLARE busy text; BEGIN
 SELECT string_agg(coalesce(p.index_relid::regclass::text, p.relid::regclass::text), ', ') INTO busy
   FROM pg_stat_progress_create_index p WHERE p.pid <> pg_backend_pid();
 IF busy IS NOT NULL THEN
  RAISE EXCEPTION 'An index build is still running (%). Wait until SELECT * FROM pg_stat_progress_create_index returns no rows, then rerun.', busy;
 END IF;
END $$;
-- Refuse invalid indexes: IF NOT EXISTS would otherwise silently skip rebuilding them.
DO $$ BEGIN
 IF EXISTS (SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid
 JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname=current_schema() AND NOT i.indisvalid AND c.relname IN ('keywords_lower_keyword_trgm_idx', 'keywords_lower_keyword_idx', 'news_ai_analysis_trendingKeywords_coalesce_gin_idx', 'news_ai_analysis_topTopics_coalesce_gin_idx', 'news_ai_analysis_summary_trgm_idx', 'news_ai_analysis_what_happened_trgm_idx', 'news_ai_analysis_where_happened_trgm_idx', 'news_ai_analysis_who_involved_trgm_idx', 'news_ai_analysis_between_whom_trgm_idx', 'news_ai_analysis_why_happened_trgm_idx', 'news_ai_analysis_root_cause_trgm_idx', 'news_ai_analysis_what_impact_trgm_idx', 'news_ai_analysis_future_implication_trgm_idx', 'news_ai_analysis_search_tsv_gin_idx', 'news_articles_search_tsv_gin_idx', 'news_articles_category_trgm_idx', 'news_articles_status_published_desc_nl_idx', 'news_articles_fts_expr_idx', 'news_articles_ai_search_tsv_gin_idx'))
 THEN RAISE EXCEPTION 'Invalid performance index found. Drop ONLY the invalid named index CONCURRENTLY, then rerun.'; END IF;
END $$;
CREATE INDEX CONCURRENTLY IF NOT EXISTS "keywords_lower_keyword_trgm_idx" ON "keywords" USING GIN (LOWER("keyword") gin_trgm_ops);

CREATE INDEX CONCURRENTLY IF NOT EXISTS "keywords_lower_keyword_idx" ON "keywords" (LOWER("keyword"));

CREATE INDEX CONCURRENTLY IF NOT EXISTS "news_ai_analysis_trendingKeywords_coalesce_gin_idx" ON "news_ai_analysis" USING GIN (COALESCE(("trendingKeywords")::text, '') gin_trgm_ops);

CREATE INDEX CONCURRENTLY IF NOT EXISTS "news_ai_analysis_topTopics_coalesce_gin_idx" ON "news_ai_analysis" USING GIN (COALESCE(("topTopics")::text, '') gin_trgm_ops);

CREATE INDEX CONCURRENTLY IF NOT EXISTS "news_ai_analysis_summary_trgm_idx" ON "news_ai_analysis" USING GIN (COALESCE("summary", '') gin_trgm_ops);

CREATE INDEX CONCURRENTLY IF NOT EXISTS "news_ai_analysis_what_happened_trgm_idx" ON "news_ai_analysis" USING GIN (COALESCE("what_happened", '') gin_trgm_ops);

CREATE INDEX CONCURRENTLY IF NOT EXISTS "news_ai_analysis_where_happened_trgm_idx" ON "news_ai_analysis" USING GIN (COALESCE("where_happened", '') gin_trgm_ops);

CREATE INDEX CONCURRENTLY IF NOT EXISTS "news_ai_analysis_who_involved_trgm_idx" ON "news_ai_analysis" USING GIN (COALESCE("who_involved", '') gin_trgm_ops);

CREATE INDEX CONCURRENTLY IF NOT EXISTS "news_ai_analysis_between_whom_trgm_idx" ON "news_ai_analysis" USING GIN (COALESCE("between_whom", '') gin_trgm_ops);

CREATE INDEX CONCURRENTLY IF NOT EXISTS "news_ai_analysis_why_happened_trgm_idx" ON "news_ai_analysis" USING GIN (COALESCE("why_happened", '') gin_trgm_ops);

CREATE INDEX CONCURRENTLY IF NOT EXISTS "news_ai_analysis_root_cause_trgm_idx" ON "news_ai_analysis" USING GIN (COALESCE("root_cause", '') gin_trgm_ops);

CREATE INDEX CONCURRENTLY IF NOT EXISTS "news_ai_analysis_what_impact_trgm_idx" ON "news_ai_analysis" USING GIN (COALESCE("what_impact", '') gin_trgm_ops);

CREATE INDEX CONCURRENTLY IF NOT EXISTS "news_ai_analysis_future_implication_trgm_idx" ON "news_ai_analysis" USING GIN (COALESCE("future_implication", '') gin_trgm_ops);

CREATE INDEX CONCURRENTLY IF NOT EXISTS "news_ai_analysis_search_tsv_gin_idx" ON "news_ai_analysis" USING GIN ("search_tsv") WHERE "search_tsv" IS NOT NULL;


CREATE INDEX CONCURRENTLY IF NOT EXISTS "news_articles_search_tsv_gin_idx" ON "news_articles" USING GIN ("search_tsv") WHERE "search_tsv" IS NOT NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS "news_articles_category_trgm_idx" ON "news_articles" USING GIN ("category" gin_trgm_ops);

-- Feed ordering index (perf/search-query-fixes; PENDING diagnose-search C1 vs C3).
-- Every news feed orders by "publishedAt" DESC NULLS LAST, id DESC
-- (newsArticlePublishedAtOrder). A btree on (status, "publishedAt") can only be
-- read in ASC NULLS LAST / DESC NULLS FIRST order, so it cannot supply that
-- order: the Latest feed (sentiment + exclude_top, matching most of the table)
-- must collect and sort every match before LIMIT 101. With this index the
-- planner can walk rows newest-first and stop after 101 matches.
-- Cost: btree over (enum, timestamp, cuid) ≈ 60 B/row → ~11 MB at 180k
-- articles (check with pg_relation_size after the build); one more index to
-- maintain on insert. Additive: older app versions are unaffected.
CREATE INDEX CONCURRENTLY IF NOT EXISTS "news_articles_status_published_desc_nl_idx"
    ON "news_articles" ("status", "publishedAt" DESC NULLS LAST, "id" DESC);

-- News text search (perf/news-search-progressive, beta 2026-09-30).
-- news_articles.search_tsv is abandoned (100 % NULL on beta; its trigger and
-- helpers were never kept in the repo), and ILIKE over article bodies is not
-- viable at any window. Body search matches news_articles_fts_expr_idx, an
-- index on news_articles_fts_document(title, content); the query in
-- apps/core-service/src/news/news-search-progressive.ts
-- (NEWS_ARTICLES_FTS_EXPRESSION) must call it IDENTICALLY or the planner
-- cannot use the index (news-search-progressive.spec.ts checks this file).
--
-- Why a function and not an inline expression: on beta (PostgreSQL 18.2) an
-- index on to_tsvector(... left(content, 100000)) failed with "invalid byte
-- sequence for encoding UTF8: 0xe0 0xa7" on a few 150k-370k character
-- bodies, although the stored text is valid and to_tsvector of the FULL
-- content works: truncating large toasted multibyte text (left, substr,
-- substring) produced the broken bytes. So the function never truncates.
-- Any error on one row (that one, or "string is too long for tsvector" past
-- the 1 MB limit) falls back to the title alone instead of failing the build
-- or the insert. The EXCEPTION block starts a subtransaction, which a
-- parallel worker cannot do, hence PARALLEL UNSAFE: the index builds
-- serially. IMMUTABLE is required to index it; do not change the body
-- without rebuilding the index (REINDEX INDEX CONCURRENTLY).
-- Heavy build (minutes, ~GB): kept OFF the app boot path
-- (libs/database/src/performance-schema.ts), built CONCURRENTLY here, off-peak.
CREATE OR REPLACE FUNCTION news_articles_fts_document(title text, content text) RETURNS tsvector
LANGUAGE plpgsql IMMUTABLE PARALLEL UNSAFE AS $$
BEGIN
  RETURN to_tsvector('simple'::regconfig, COALESCE(title, '') || ' ' || COALESCE(content, ''));
EXCEPTION WHEN others THEN
  RETURN to_tsvector('simple'::regconfig, COALESCE(title, ''));
END;
$$;

CREATE INDEX CONCURRENTLY IF NOT EXISTS "news_articles_fts_expr_idx" ON "news_articles" USING GIN (news_articles_fts_document("title", "content"));

CREATE OR REPLACE FUNCTION news_ai_analysis_search_tsv_update() RETURNS trigger AS $$
BEGIN
  NEW.search_tsv := to_tsvector('simple',
    coalesce(NEW."summary", '') || ' ' ||
    coalesce(NEW."what_happened", '') || ' ' ||
    coalesce(NEW."where_happened", '') || ' ' ||
    coalesce(NEW."who_involved", '') || ' ' ||
    coalesce(NEW."between_whom", '') || ' ' ||
    coalesce(NEW."why_happened", '') || ' ' ||
    coalesce(NEW."root_cause", '') || ' ' ||
    coalesce(NEW."what_impact", '') || ' ' ||
    coalesce(NEW."future_implication", '') || ' ' ||
    coalesce(NEW."detailedInsights", '') || ' ' ||
    coalesce((NEW."trendingKeywords")::text, '') || ' ' ||
    coalesce((NEW."topTopics")::text, '')
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_news_ai_analysis_search_tsv') THEN
    CREATE TRIGGER trg_news_ai_analysis_search_tsv
    BEFORE INSERT OR UPDATE ON news_ai_analysis
    FOR EACH ROW EXECUTE FUNCTION news_ai_analysis_search_tsv_update();
  END IF;
END;
$$;

-- News text search, AI branch (perf/news-search-common-words, beta 2026-10-04).
-- Matching an article through news_ai_analysis.search_tsv meant a bitmap heap
-- scan of the wide AI table (~13 KB rows, 1.9 GB on beta) just to read
-- articleId: ঢাকা (41k matching analyses) took over 15 s cold. So every
-- article now carries the combined vector of ALL its analyses in
-- news_articles.ai_search_tsv (declared in schema.prisma, so `db push` keeps
-- it), kept up to date by the triggers below, backfilled by
-- scripts/performance/backfill-news-ai-search-tsv.sql, and GIN-indexed, so the
-- search reads only news_articles.
--
-- The combined value: the non-NULL analysis vectors in id order, joined with
-- a one-lexeme separator (' ', a single space) between them; NULL when the
-- article has no analysis with a vector. With exactly one such analysis it IS
-- that analysis's vector. Why the separator: the search's to_tsquery turns a
-- compound word (covid-19) into a phrase ('covid':* <-> '-19':*), and plain
-- concatenation would let a phrase match ACROSS two analyses, which the old
-- per-analysis EXISTS never did. No query lexeme can match the separator
-- (to_tsquery never yields a lexeme starting with a space), so a match of the
-- combined vector is exactly a match of some single analysis (argument in
-- news-search-progressive.ts). A combined vector that would come near the
-- 1 MB tsvector limit falls back to the union of the position-free (strip)
-- vectors: same lexemes, phrases then match leniently.
--
-- The column comes from `db push`. Without it, stop here (the indexes above
-- are built; rerun perf-schema after the push): no trigger may exist that
-- writes a column that is not there.
DO $$ BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_attribute
                 WHERE attrelid = 'news_articles'::regclass AND attname = 'ai_search_tsv' AND NOT attisdropped) THEN
  RAISE EXCEPTION 'news_articles.ai_search_tsv is missing: run prisma db push with the current schema.prisma first, then perf-schema again.';
 END IF;
END $$;

-- VOLATILE on purpose: in READ COMMITTED each query inside takes a fresh
-- snapshot, so a caller that has just locked the article row sees every
-- analysis committed before it got the lock (see the trigger below).
CREATE OR REPLACE FUNCTION news_articles_ai_search_tsv_of(p_article_id text) RETURNS tsvector
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
  acc tsvector;
  v tsvector;
  stripped boolean := false;
BEGIN
  -- No EXCEPTION block: it would open a subtransaction per call, and the
  -- backfill calls this ~1000 times per transaction (subxid overflow slows
  -- every other session). The size is checked before concatenating instead
  -- (pg_column_size of a computed tsvector is its uncompressed size).
  FOR v IN SELECT a.search_tsv FROM news_ai_analysis a
            WHERE a."articleId" = p_article_id AND a.search_tsv IS NOT NULL
            ORDER BY a.id LOOP
    IF acc IS NULL THEN
      acc := v;
    ELSIF NOT stripped AND pg_column_size(acc) + pg_column_size(v || ''::tsvector) < 900000 THEN
      acc := acc || $sep$' ':1$sep$::tsvector || v;
    ELSE
      stripped := true;
      acc := strip(acc) || strip(v);
    END IF;
  END LOOP;
  RETURN acc;
END;
$$;

-- Recompute the article(s) an analysis write touches. Locks the article row
-- first (FOR NO KEY UPDATE, compatible with the FK's KEY SHARE) so two
-- concurrent analysis writes for one article serialise and the second sees
-- the first. Writes only when the value changes. It updates news_articles,
-- never news_ai_analysis, so it cannot re-fire the analysis triggers.
CREATE OR REPLACE FUNCTION news_ai_analysis_sync_article_tsv() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  ids text[];
  aid text;
BEGIN
  -- A rollback to an image whose schema lacks the column drops it (its
  -- `db push --accept-data-loss`): then do nothing rather than fail every AI
  -- write. (One syscache lookup; the column comes back empty, without the
  -- backfill marker, so the app keeps the AI-table path until a rerun.)
  IF NOT EXISTS (SELECT 1 FROM pg_attribute
                  WHERE attrelid = 'news_articles'::regclass AND attname = 'ai_search_tsv' AND NOT attisdropped) THEN
    RETURN NULL;
  END IF;
  IF TG_OP = 'INSERT' THEN
    ids := ARRAY[NEW."articleId"];
  ELSIF TG_OP = 'DELETE' THEN
    ids := ARRAY[OLD."articleId"];
  ELSIF OLD."articleId" IS DISTINCT FROM NEW."articleId" THEN
    ids := ARRAY[OLD."articleId", NEW."articleId"];
  ELSE
    ids := ARRAY[NEW."articleId"];
  END IF;
  FOREACH aid IN ARRAY ids LOOP
    CONTINUE WHEN aid IS NULL;
    PERFORM 1 FROM news_articles WHERE id = aid FOR NO KEY UPDATE;
    UPDATE news_articles na
       SET ai_search_tsv = c.v
      FROM (SELECT news_articles_ai_search_tsv_of(aid) AS v) c
     WHERE na.id = aid AND na.ai_search_tsv IS DISTINCT FROM c.v;
  END LOOP;
  RETURN NULL;
END;
$$;

-- Three triggers so the WHEN clauses skip the call when nothing that feeds
-- the combined vector changed. AFTER UPDATE (not UPDATE OF search_tsv): the
-- AI pipeline updates other columns and the BEFORE trigger above rewrites
-- search_tsv, which UPDATE OF would not see.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_news_ai_analysis_article_tsv_ins' AND tgrelid = 'news_ai_analysis'::regclass) THEN
    CREATE TRIGGER trg_news_ai_analysis_article_tsv_ins
    AFTER INSERT ON news_ai_analysis
    FOR EACH ROW WHEN (NEW."articleId" IS NOT NULL AND NEW.search_tsv IS NOT NULL)
    EXECUTE FUNCTION news_ai_analysis_sync_article_tsv();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_news_ai_analysis_article_tsv_upd' AND tgrelid = 'news_ai_analysis'::regclass) THEN
    CREATE TRIGGER trg_news_ai_analysis_article_tsv_upd
    AFTER UPDATE ON news_ai_analysis
    FOR EACH ROW WHEN (OLD.search_tsv IS DISTINCT FROM NEW.search_tsv OR OLD."articleId" IS DISTINCT FROM NEW."articleId")
    EXECUTE FUNCTION news_ai_analysis_sync_article_tsv();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_news_ai_analysis_article_tsv_del' AND tgrelid = 'news_ai_analysis'::regclass) THEN
    CREATE TRIGGER trg_news_ai_analysis_article_tsv_del
    AFTER DELETE ON news_ai_analysis
    FOR EACH ROW WHEN (OLD."articleId" IS NOT NULL AND OLD.search_tsv IS NOT NULL)
    EXECUTE FUNCTION news_ai_analysis_sync_article_tsv();
  END IF;
END;
$$;

CREATE INDEX CONCURRENTLY IF NOT EXISTS "news_articles_ai_search_tsv_gin_idx" ON "news_articles" USING GIN ("ai_search_tsv") WHERE "ai_search_tsv" IS NOT NULL;

-- Post-check: every performance object must now exist and be usable. A build
-- that ended INVALID (or was never created) fails the run with a non-zero exit
-- naming it, so a deploy that re-applies this file after `prisma db push`
-- (scripts/deploy/common.sh: reapply_performance_schema) fails loudly.
DO $$
DECLARE
 bad text;
BEGIN
 SELECT string_agg(want.name || CASE WHEN c.oid IS NULL THEN ' (missing)' ELSE ' (INVALID)' END, ', ' ORDER BY want.name)
 INTO bad
 FROM unnest(ARRAY['keywords_lower_keyword_trgm_idx', 'keywords_lower_keyword_idx', 'news_ai_analysis_trendingKeywords_coalesce_gin_idx', 'news_ai_analysis_topTopics_coalesce_gin_idx', 'news_ai_analysis_summary_trgm_idx', 'news_ai_analysis_what_happened_trgm_idx', 'news_ai_analysis_where_happened_trgm_idx', 'news_ai_analysis_who_involved_trgm_idx', 'news_ai_analysis_between_whom_trgm_idx', 'news_ai_analysis_why_happened_trgm_idx', 'news_ai_analysis_root_cause_trgm_idx', 'news_ai_analysis_what_impact_trgm_idx', 'news_ai_analysis_future_implication_trgm_idx', 'news_ai_analysis_search_tsv_gin_idx', 'news_articles_search_tsv_gin_idx', 'news_articles_category_trgm_idx', 'news_articles_status_published_desc_nl_idx', 'news_articles_fts_expr_idx', 'news_articles_ai_search_tsv_gin_idx']) AS want(name)
 LEFT JOIN pg_namespace n ON n.nspname = current_schema()
 LEFT JOIN pg_class c ON c.relname = want.name AND c.relnamespace = n.oid
 LEFT JOIN pg_index i ON i.indexrelid = c.oid
 WHERE c.oid IS NULL OR NOT i.indisvalid OR NOT i.indisready;
 IF bad IS NOT NULL THEN
  RAISE EXCEPTION 'Performance schema incomplete: %. For an INVALID index: DROP INDEX CONCURRENTLY "<name>"; then rerun perf-schema ONCE.', bad;
 END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_news_ai_analysis_search_tsv' AND tgrelid = 'news_ai_analysis'::regclass AND tgenabled <> 'D') THEN
  RAISE EXCEPTION 'Performance schema incomplete: trigger trg_news_ai_analysis_search_tsv missing or disabled.';
 END IF;
 IF (SELECT count(*) FROM pg_trigger WHERE tgrelid = 'news_ai_analysis'::regclass AND tgenabled <> 'D'
      AND tgname IN ('trg_news_ai_analysis_article_tsv_ins', 'trg_news_ai_analysis_article_tsv_upd', 'trg_news_ai_analysis_article_tsv_del')) <> 3 THEN
  RAISE EXCEPTION 'Performance schema incomplete: a trg_news_ai_analysis_article_tsv_* trigger (ins/upd/del) is missing or disabled.';
 END IF;
 RAISE NOTICE 'Performance schema OK: 19 indexes valid, triggers trg_news_ai_analysis_search_tsv and trg_news_ai_analysis_article_tsv_{ins,upd,del} enabled.';
END $$;
SELECT pg_advisory_unlock(hashtext('falcon-performance-schema'));
