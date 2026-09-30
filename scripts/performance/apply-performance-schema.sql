-- Run with psql, without --single-transaction. Existing Prisma schema must be applied first.
\set ON_ERROR_STOP on
-- No lock_timeout: CREATE INDEX CONCURRENTLY waits for every older transaction
-- to finish (a lock wait), and a timeout there aborts the build and leaves an
-- INVALID index (alpha, 2026-09-26: desc_nl index left invalid under ingestion
-- with lock_timeout=5s). The build takes SHARE UPDATE EXCLUSIVE, which never
-- blocks reads or writes, so waiting is harmless.
SET lock_timeout = '0';
SET statement_timeout = '0';
SELECT pg_advisory_lock(hashtext('falcon-performance-schema'));
-- Refuse invalid indexes: IF NOT EXISTS would otherwise silently skip rebuilding them.
DO $$ BEGIN
 IF EXISTS (SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid
 JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname=current_schema() AND NOT i.indisvalid AND c.relname IN ('keywords_lower_keyword_trgm_idx', 'keywords_lower_keyword_idx', 'news_ai_analysis_trendingKeywords_coalesce_gin_idx', 'news_ai_analysis_topTopics_coalesce_gin_idx', 'news_ai_analysis_summary_trgm_idx', 'news_ai_analysis_what_happened_trgm_idx', 'news_ai_analysis_where_happened_trgm_idx', 'news_ai_analysis_who_involved_trgm_idx', 'news_ai_analysis_between_whom_trgm_idx', 'news_ai_analysis_why_happened_trgm_idx', 'news_ai_analysis_root_cause_trgm_idx', 'news_ai_analysis_what_impact_trgm_idx', 'news_ai_analysis_future_implication_trgm_idx', 'news_ai_analysis_search_tsv_gin_idx', 'news_articles_search_tsv_gin_idx', 'news_articles_category_trgm_idx', 'news_articles_status_published_desc_nl_idx', 'news_articles_fts_expr_idx'))
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
-- viable at any window. Body search matches this expression instead; the
-- query in apps/core-service/src/news/news-search-progressive.ts
-- (NEWS_ARTICLES_FTS_EXPRESSION) must spell it IDENTICALLY or the planner
-- cannot use the index (news-search-progressive.spec.ts checks this line).
-- Bodies are capped at 100k characters so one huge page cannot bloat the
-- index or hit the tsvector size limit. Heavy build (minutes, ~GB): kept
-- OFF the app boot path (libs/database/src/performance-schema.ts), built
-- CONCURRENTLY here, off-peak.
CREATE INDEX CONCURRENTLY IF NOT EXISTS "news_articles_fts_expr_idx" ON "news_articles" USING GIN (to_tsvector('simple'::regconfig, COALESCE("title", '') || ' ' || left(COALESCE("content", ''), 100000)));

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
SELECT pg_advisory_unlock(hashtext('falcon-performance-schema'));
