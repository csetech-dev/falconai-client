-- ============================================================================
-- FalconAI search / feed diagnostics — STAGE DATABASES ONLY
-- ============================================================================
-- Run:   ./scripts/deploy/db.sh perf-diagnose-search
--        (psql runs in a throwaway container, so pass the file on stdin;
--         `db.sh psql -- -f <file>` cannot see host files.)
--
-- EXPLAIN (ANALYZE) EXECUTES each query. Everything here is read-only
-- (default_transaction_read_only), but it reads large parts of news_articles
-- and news_ai_analysis and can take minutes in total. Do NOT run it on the
-- production database during business hours.
--
-- The SQL below is taken from core-service at astra/perf-integration:
--   A. snapshot-v2/keyword-articles, mode=ai (news-dashboard.service.ts
--      getSnapshotV2KeywordArticles + buildAiTopicMatchCte +
--      buildKeywordArticleFilterSql), page 1, limit 16 (the news page panel)
--      -> poolTake 80, status filter GOOD (the default mode).
--      A / A2: the original shape (correlated EXISTS ranking, no window).
--      A-new*: the previous shape (tier id sets + the 90-day window;
--      stage: ঢাকা 57 s). Both kept for comparison.
--      A-v3-*: the CURRENT app SQL (keyword-article-ranking.sql.ts): one
--      statement per relevance tier, each walking the publishedAt index and
--      stopping at LIMIT; a tier only runs when the tiers above it returned
--      fewer than K = 80 rows, exactly as in the app (psql \if). Generated
--      from the app's own builders, parameters inlined.
--   B. news/timeline?search=<term>&aiKeyword=<term>&windowHours=24
--      (getNewsTimelineBuckets slow path). This is a PRISMA MODEL query: the
--      text below is a faithful reconstruction of what Prisma generates, not
--      byte-identical. To capture the exact SQL, set
--      PRISMA_SLOW_QUERY_LOG_MS=5000 on falcon-core and read its log
--      (parameterised text only, no values).
--   C. /news Latest feed (sentiment=positive, topNewsFilter=exclude_top,
--      sortBy=publishedAt desc, skipTotalCount): via getNewsRankedBySourcePriority
--      -> one findMany with take 101, ORDER BY "publishedAt" DESC NULLS LAST,
--      id DESC. Prisma model query, reconstructed as in B, plus the exact
--      COUNT variant a non-skipTotalCount caller would run.
--   D. news/search-panel-cache build (news-analytics.service.ts
--      buildSearchPanelCandidateSql): plain EXPLAIN only, never executed,
--      so this section is safe on stage at any time. D4 is the previous
--      (9e4b9b920) shape for comparison.
--   E. news/search-panel-cache build, EVERY statement in the order the app
--      runs them, EXPLAIN (ANALYZE, BUFFERS), with the parameters the /news
--      page sends by default. Self-contained (its own read-only session and
--      30 s statement_timeout), so it can be run on its own:
--        { echo "SET default_transaction_read_only = on;"; sed -n '/############ E\./,/############ F\./p' scripts/performance/diagnose-search.sql; } | bash ./scripts/deploy/db.sh psql -- -f -
--   G. walk vs fence, EXPLAIN (ANALYZE, BUFFERS): the search-panel candidate
--      query (24 h; the app fences short windows) and topic-search tier 1000
--      (ঢাকা 90 d / 24 h, election 90 d; the app walks), each with a check
--      that both shapes return identical rows. It sits between D and E so
--      the E and F ranges below do not include it. Alone:
--        { echo "SET default_transaction_read_only = on;"; sed -n '/############ G\./,/############ E\./p' scripts/performance/diagnose-search.sql; } | bash ./scripts/deploy/db.sh psql -- -f -
--   F. news/search-panel-cache: is an empty summary for a typed topic search
--      the ORIGINAL answer or a regression? Counts (plain SELECTs, no
--      EXPLAIN) for election / ঢাকা / নির্বাচন and the most frequent 24 h
--      trendingKeyword: candidates and exact-aiKeyword articles under the
--      original (pre-9e4b9b920) shape, the deployed dc26959b6 shape and the
--      fixed shape, over the same 24 h. Scans the window's article bodies and
--      raw pages on purpose (the original shape); 120 s per statement. Alone:
--        { echo "SET default_transaction_read_only = on;"; sed -n '/############ F\./,/############ P\./p' scripts/performance/diagnose-search.sql; } | bash ./scripts/deploy/db.sh psql -- -f -
--   P. progressive topic search (2026-09-29): the first read of slice S0
--      (last 7 days) and S1 (7–30 days) for ঢাকা and election, every tier
--      statement as the app runs it, EXPLAIN (ANALYZE, BUFFERS). Alone:
--        { echo "SET default_transaction_read_only = on;"; sed -n '/############ P\./,/############ done/p' scripts/performance/diagnose-search.sql; } | bash ./scripts/deploy/db.sh psql -- -f -
--   W. beta dashboards (2026-09-29): dashboard/social/hot-topics (current
--      bounded reads; the old hoursBack=0 all-time read for comparison) and
--      the neutral column of snapshot-v2/sentiment-articles (old OR of
--      NOT IN / IN sublinks vs the early-terminating walk, plus a same-rows
--      check). 60 s per statement. Alone:
--        { echo "SET default_transaction_read_only = on;"; sed -n '/############ W\./,/############ done/p' scripts/performance/diagnose-search.sql; } | bash ./scripts/deploy/db.sh psql -- -f -
--   N. /news?search= (2026-09-30, searchNewsArticleIdsWithFullText): the
--      search_tsv plumbing (functions, triggers, indexes), search_tsv
--      coverage of GOOD articles and their AI analyses by publishedAt
--      window, and the plan of a candidate 7-day slice query for election /
--      নির্বাচন (15 s cap each). Alone:
--        { echo "SET default_transaction_read_only = on;"; sed -n '/############ N\./,/############ done/p' scripts/performance/diagnose-search.sql; } | bash ./scripts/deploy/db.sh psql -- -f -
-- Replace nothing: the terms are ঢাকা (Bangla) and election (English).
-- ============================================================================
\set ON_ERROR_STOP off
SET statement_timeout = '120s';
SET lock_timeout = '2s';
SET default_transaction_read_only = on;
SET application_name = 'falcon-diagnose-search';
\timing on

\echo '############ 1. Locale, encoding and pg_trgm (hypothesis 1: C/POSIX ctype makes Bangla non-word) ############'
SELECT datname, pg_encoding_to_char(encoding) AS encoding, datcollate, datctype,
       datlocprovider, datlocale
FROM pg_database WHERE datname = current_database();
-- datlocale/datlocprovider exist on PG 17+; on older servers that line errors and the next ones still run.
SELECT datname, pg_encoding_to_char(encoding) AS encoding, datcollate, datctype
FROM pg_database WHERE datname = current_database();
SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_trgm', 'unaccent', 'vector') ORDER BY 1;
SELECT 'ঢাকা' AS term, show_trgm('ঢাকা') AS trigrams, cardinality(show_trgm('ঢাকা')) AS n
UNION ALL SELECT 'নির্বাচন', show_trgm('নির্বাচন'), cardinality(show_trgm('নির্বাচন'))
UNION ALL SELECT 'election', show_trgm('election'), cardinality(show_trgm('election'));
-- tsvector tokenisation of Bangla (search_tsv uses the 'simple' config)
SELECT to_tsvector('simple', 'ঢাকা শহরে নির্বাচন election') AS tsv,
       websearch_to_tsquery('simple', 'ঢাকা') AS q_bn,
       websearch_to_tsquery('simple', 'election') AS q_en;

\echo '############ 2. Every index on the two tables, with definition and size ############'
SELECT t.relname AS "table", c.relname AS index, i.indisvalid AS valid,
       pg_size_pretty(pg_relation_size(c.oid)) AS size, pg_get_indexdef(c.oid) AS definition
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_class t ON t.oid = i.indrelid
WHERE t.relname IN ('news_articles', 'news_ai_analysis')
ORDER BY t.relname, c.relname;

\echo '############ 3. Table statistics ############'
SELECT relname, n_live_tup, n_dead_tup, seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
       last_autoanalyze, last_analyze
FROM pg_stat_user_tables WHERE relname IN ('news_articles', 'news_ai_analysis');
SELECT pg_size_pretty(pg_total_relation_size('news_articles')) AS news_articles_total,
       pg_size_pretty(pg_total_relation_size('news_ai_analysis')) AS news_ai_analysis_total;
SHOW work_mem;
SHOW random_page_cost;

\echo '############ 4. Selectivity: planner estimates only (EXPLAIN, nothing executed) ############'
-- Exact counts timed out at 120 s on alpha, and the sampled version (2 %
-- TABLESAMPLE) still timed out at 10 s on stage, so this section only asks
-- the planner (instant). Compare each "rows=" with the stage facts in
-- backend-baseline.md §15: 'ঢাকা' is in 15,880 of ~111k analysis summaries
-- (14 %); ~24k articles by search_tsv (13 %); 57 % of GOOD articles are in
-- the last 90 days. A tier's plan (A-v3) is only as good as these estimates:
-- an estimate far too LOW for a common term can make the planner pick a
-- bitmap scan of every match instead of walking the publishedAt index.
EXPLAIN SELECT 1 FROM news_articles na WHERE na."search_tsv" @@ websearch_to_tsquery('simple','ঢাকা');
EXPLAIN SELECT 1 FROM news_articles na WHERE na."search_tsv" @@ websearch_to_tsquery('simple','election');
EXPLAIN SELECT 1 FROM news_articles na WHERE na."title" ILIKE '%ঢাকা%';
EXPLAIN SELECT 1 FROM news_articles na WHERE na."title" ILIKE '%election%';
EXPLAIN SELECT 1 FROM news_ai_analysis a WHERE COALESCE(a."summary",'') ILIKE '%ঢাকা%';
EXPLAIN SELECT 1 FROM news_ai_analysis a WHERE COALESCE(a."summary",'') ILIKE '%election%';
EXPLAIN SELECT 1 FROM news_ai_analysis a WHERE COALESCE(a."summary",'') ILIKE '%নির্বাচন%';
EXPLAIN SELECT 1 FROM news_ai_analysis a
  WHERE COALESCE(a."topTopics"::text, '') ILIKE '%ঢাকা%' OR COALESCE(a."trendingKeywords"::text, '') ILIKE '%ঢাকা%';
EXPLAIN SELECT 1 FROM news_ai_analysis a
  WHERE COALESCE(a."topTopics"::text, '') ILIKE '%election%' OR COALESCE(a."trendingKeywords"::text, '') ILIKE '%election%';
EXPLAIN SELECT 1 FROM news_articles na WHERE na."status" = 'GOOD'
  AND na."publishedAt" >= (now() AT TIME ZONE 'Asia/Dhaka') - interval '90 days';

\echo '############ A. keyword-articles, mode=ai, term ঢাকা — OLD shape, all time (alpha: timed out at 120 s) ############'
EXPLAIN (ANALYZE, BUFFERS, SETTINGS)
WITH matched_ai_articles AS (
    SELECT a."articleId" AS id
    FROM "news_ai_analysis" a
    WHERE a."articleId" IS NOT NULL
      AND (
        ((
            COALESCE(a."trendingKeywords"::text, '') ILIKE '%ঢাকা%'
            OR COALESCE(a."topTopics"::text, '') ILIKE '%ঢাকা%'
            OR COALESCE(a."summary", '') ILIKE '%ঢাকা%'
            OR COALESCE(a."what_happened", '') ILIKE '%ঢাকা%'
            OR COALESCE(a."where_happened", '') ILIKE '%ঢাকা%'
            OR COALESCE(a."who_involved", '') ILIKE '%ঢাকা%'
            OR COALESCE(a."between_whom", '') ILIKE '%ঢাকা%'
            OR COALESCE(a."why_happened", '') ILIKE '%ঢাকা%'
            OR COALESCE(a."root_cause", '') ILIKE '%ঢাকা%'
            OR COALESCE(a."what_impact", '') ILIKE '%ঢাকা%'
            OR COALESCE(a."future_implication", '') ILIKE '%ঢাকা%'
        ))
        OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা'))
      )
    UNION
    SELECT na.id FROM "news_articles" na WHERE na."title" ILIKE '%ঢাকা%'
    UNION
    SELECT na.id FROM "news_articles" na
    WHERE na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা')
)
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
JOIN matched_ai_articles m ON na.id = m.id
WHERE na."status" = 'GOOD'
ORDER BY (
    CASE
      WHEN EXISTS (
        SELECT 1 FROM news_ai_analysis a
        WHERE a."articleId" = na.id
          AND ((
              COALESCE(a."topTopics"::text, '') ILIKE '%ঢাকা%'
              OR COALESCE(a."trendingKeywords"::text, '') ILIKE '%ঢাকা%'
          ))
      ) THEN 1000
      WHEN na."title" ILIKE '%ঢাকা%' THEN 800
      WHEN EXISTS (
        SELECT 1 FROM news_ai_analysis a
        WHERE a."articleId" = na.id AND COALESCE(a."summary", '') ILIKE '%ঢাকা%'
      ) THEN 500
      ELSE 100
    END
) DESC, na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT 80;

\echo '############ A2. keyword-articles, mode=ai, term election — OLD shape, all time (alpha: 4.1 s) ############'
EXPLAIN (ANALYZE, BUFFERS)
WITH matched_ai_articles AS (
    SELECT a."articleId" AS id
    FROM "news_ai_analysis" a
    WHERE a."articleId" IS NOT NULL
      AND (
        ((
            COALESCE(a."trendingKeywords"::text, '') ILIKE '%election%'
            OR COALESCE(a."topTopics"::text, '') ILIKE '%election%'
            OR COALESCE(a."summary", '') ILIKE '%election%'
            OR COALESCE(a."what_happened", '') ILIKE '%election%'
            OR COALESCE(a."where_happened", '') ILIKE '%election%'
            OR COALESCE(a."who_involved", '') ILIKE '%election%'
            OR COALESCE(a."between_whom", '') ILIKE '%election%'
            OR COALESCE(a."why_happened", '') ILIKE '%election%'
            OR COALESCE(a."root_cause", '') ILIKE '%election%'
            OR COALESCE(a."what_impact", '') ILIKE '%election%'
            OR COALESCE(a."future_implication", '') ILIKE '%election%'
        ))
        OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'election'))
      )
    UNION
    SELECT na.id FROM "news_articles" na WHERE na."title" ILIKE '%election%'
    UNION
    SELECT na.id FROM "news_articles" na
    WHERE na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'election')
)
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
JOIN matched_ai_articles m ON na.id = m.id
WHERE na."status" = 'GOOD'
ORDER BY (
    CASE
      WHEN EXISTS (
        SELECT 1 FROM news_ai_analysis a
        WHERE a."articleId" = na.id
          AND ((
              COALESCE(a."topTopics"::text, '') ILIKE '%election%'
              OR COALESCE(a."trendingKeywords"::text, '') ILIKE '%election%'
          ))
      ) THEN 1000
      WHEN na."title" ILIKE '%election%' THEN 800
      WHEN EXISTS (
        SELECT 1 FROM news_ai_analysis a
        WHERE a."articleId" = na.id AND COALESCE(a."summary", '') ILIKE '%election%'
      ) THEN 500
      ELSE 100
    END
) DESC, na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT 80;

-- ---------------------------------------------------------------------------
-- A-new: the CURRENT app SQL (perf/topic-window): tier sets instead of
-- correlated EXISTS, and the default 90-day topic window inside every
-- candidate branch (TOPIC_SEARCH_DEFAULT_DAYS; the app passes the bound as a
-- parameter, computed on the Bangladesh wall clock exactly as below).
-- ---------------------------------------------------------------------------
SELECT ((now() AT TIME ZONE 'Asia/Dhaka') - interval '90 days')::timestamp(3) AS topic_from \gset
\echo 'topic window from:' :'topic_from'
\echo '############ A-new. keyword-articles, mode=ai, term ঢাকা — tier sets + 90-day window (target: well under 8 s) ############'
EXPLAIN (ANALYZE, BUFFERS)
WITH matched_ai_articles AS (
    SELECT a."articleId" AS id
    FROM "news_ai_analysis" a
    JOIN "news_articles" wa ON wa.id = a."articleId"
        AND wa."status" = 'GOOD' AND wa."publishedAt" >= :'topic_from'
    WHERE a."articleId" IS NOT NULL
      AND (
        ((
            COALESCE(a."trendingKeywords"::text, '') ILIKE '%ঢাকা%'
            OR COALESCE(a."topTopics"::text, '') ILIKE '%ঢাকা%'
            OR COALESCE(a."summary", '') ILIKE '%ঢাকা%'
            OR COALESCE(a."what_happened", '') ILIKE '%ঢাকা%'
            OR COALESCE(a."where_happened", '') ILIKE '%ঢাকা%'
            OR COALESCE(a."who_involved", '') ILIKE '%ঢাকা%'
            OR COALESCE(a."between_whom", '') ILIKE '%ঢাকা%'
            OR COALESCE(a."why_happened", '') ILIKE '%ঢাকা%'
            OR COALESCE(a."root_cause", '') ILIKE '%ঢাকা%'
            OR COALESCE(a."what_impact", '') ILIKE '%ঢাকা%'
            OR COALESCE(a."future_implication", '') ILIKE '%ঢাকা%'
        ))
        OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা'))
      )
    UNION
    SELECT na.id FROM "news_articles" na
    WHERE na."title" ILIKE '%ঢাকা%'
      AND na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from'
    UNION
    SELECT na.id FROM "news_articles" na
    WHERE na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা')
      AND na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from'
),
topic_hits AS (
    SELECT DISTINCT a."articleId" AS id
    FROM news_ai_analysis a
    JOIN "news_articles" wa ON wa.id = a."articleId"
        AND wa."status" = 'GOOD' AND wa."publishedAt" >= :'topic_from'
    WHERE a."articleId" IS NOT NULL
      AND ((
          COALESCE(a."topTopics"::text, '') ILIKE '%ঢাকা%'
          OR COALESCE(a."trendingKeywords"::text, '') ILIKE '%ঢাকা%'
      ))
),
summary_hits AS (
    SELECT DISTINCT a."articleId" AS id
    FROM news_ai_analysis a
    JOIN "news_articles" wa ON wa.id = a."articleId"
        AND wa."status" = 'GOOD' AND wa."publishedAt" >= :'topic_from'
    WHERE a."articleId" IS NOT NULL
      AND COALESCE(a."summary", '') ILIKE '%ঢাকা%'
)
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
JOIN matched_ai_articles m ON na.id = m.id
LEFT JOIN topic_hits th ON th.id = na.id
LEFT JOIN summary_hits sh ON sh.id = na.id
WHERE na."status" = 'GOOD'
  AND na."publishedAt" >= :'topic_from'
ORDER BY (
    CASE
      WHEN th.id IS NOT NULL THEN 1000
      WHEN na."title" ILIKE '%ঢাকা%' THEN 800
      WHEN sh.id IS NOT NULL THEN 500
      ELSE 100
    END
) DESC, na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT 80;

\echo '############ A-new-2. keyword-articles, mode=ai, term election — tier sets + 90-day window ############'
EXPLAIN (ANALYZE, BUFFERS)
WITH matched_ai_articles AS (
    SELECT a."articleId" AS id
    FROM "news_ai_analysis" a
    JOIN "news_articles" wa ON wa.id = a."articleId"
        AND wa."status" = 'GOOD' AND wa."publishedAt" >= :'topic_from'
    WHERE a."articleId" IS NOT NULL
      AND (
        ((
            COALESCE(a."trendingKeywords"::text, '') ILIKE '%election%'
            OR COALESCE(a."topTopics"::text, '') ILIKE '%election%'
            OR COALESCE(a."summary", '') ILIKE '%election%'
            OR COALESCE(a."what_happened", '') ILIKE '%election%'
            OR COALESCE(a."where_happened", '') ILIKE '%election%'
            OR COALESCE(a."who_involved", '') ILIKE '%election%'
            OR COALESCE(a."between_whom", '') ILIKE '%election%'
            OR COALESCE(a."why_happened", '') ILIKE '%election%'
            OR COALESCE(a."root_cause", '') ILIKE '%election%'
            OR COALESCE(a."what_impact", '') ILIKE '%election%'
            OR COALESCE(a."future_implication", '') ILIKE '%election%'
        ))
        OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'election'))
      )
    UNION
    SELECT na.id FROM "news_articles" na
    WHERE na."title" ILIKE '%election%'
      AND na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from'
    UNION
    SELECT na.id FROM "news_articles" na
    WHERE na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'election')
      AND na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from'
),
topic_hits AS (
    SELECT DISTINCT a."articleId" AS id
    FROM news_ai_analysis a
    JOIN "news_articles" wa ON wa.id = a."articleId"
        AND wa."status" = 'GOOD' AND wa."publishedAt" >= :'topic_from'
    WHERE a."articleId" IS NOT NULL
      AND ((
          COALESCE(a."topTopics"::text, '') ILIKE '%election%'
          OR COALESCE(a."trendingKeywords"::text, '') ILIKE '%election%'
      ))
),
summary_hits AS (
    SELECT DISTINCT a."articleId" AS id
    FROM news_ai_analysis a
    JOIN "news_articles" wa ON wa.id = a."articleId"
        AND wa."status" = 'GOOD' AND wa."publishedAt" >= :'topic_from'
    WHERE a."articleId" IS NOT NULL
      AND COALESCE(a."summary", '') ILIKE '%election%'
)
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
JOIN matched_ai_articles m ON na.id = m.id
LEFT JOIN topic_hits th ON th.id = na.id
LEFT JOIN summary_hits sh ON sh.id = na.id
WHERE na."status" = 'GOOD'
  AND na."publishedAt" >= :'topic_from'
ORDER BY (
    CASE
      WHEN th.id IS NOT NULL THEN 1000
      WHEN na."title" ILIKE '%election%' THEN 800
      WHEN sh.id IS NOT NULL THEN 500
      ELSE 100
    END
) DESC, na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT 80;

\echo '############ A-new-3. keyword-articles, mode=ai, term election — tier sets, window=all (correct but may be slow) ############'
EXPLAIN (ANALYZE, BUFFERS)
WITH matched_ai_articles AS (
    SELECT a."articleId" AS id
    FROM "news_ai_analysis" a
    WHERE a."articleId" IS NOT NULL
      AND (
        ((
            COALESCE(a."trendingKeywords"::text, '') ILIKE '%election%'
            OR COALESCE(a."topTopics"::text, '') ILIKE '%election%'
            OR COALESCE(a."summary", '') ILIKE '%election%'
            OR COALESCE(a."what_happened", '') ILIKE '%election%'
            OR COALESCE(a."where_happened", '') ILIKE '%election%'
            OR COALESCE(a."who_involved", '') ILIKE '%election%'
            OR COALESCE(a."between_whom", '') ILIKE '%election%'
            OR COALESCE(a."why_happened", '') ILIKE '%election%'
            OR COALESCE(a."root_cause", '') ILIKE '%election%'
            OR COALESCE(a."what_impact", '') ILIKE '%election%'
            OR COALESCE(a."future_implication", '') ILIKE '%election%'
        ))
        OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'election'))
      )
    UNION
    SELECT na.id FROM "news_articles" na
    WHERE na."title" ILIKE '%election%'
    UNION
    SELECT na.id FROM "news_articles" na
    WHERE na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'election')
),
topic_hits AS (
    SELECT DISTINCT a."articleId" AS id
    FROM news_ai_analysis a
    WHERE a."articleId" IS NOT NULL
      AND ((
          COALESCE(a."topTopics"::text, '') ILIKE '%election%'
          OR COALESCE(a."trendingKeywords"::text, '') ILIKE '%election%'
      ))
),
summary_hits AS (
    SELECT DISTINCT a."articleId" AS id
    FROM news_ai_analysis a
    WHERE a."articleId" IS NOT NULL
      AND COALESCE(a."summary", '') ILIKE '%election%'
)
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
JOIN matched_ai_articles m ON na.id = m.id
LEFT JOIN topic_hits th ON th.id = na.id
LEFT JOIN summary_hits sh ON sh.id = na.id
WHERE na."status" = 'GOOD'
ORDER BY (
    CASE
      WHEN th.id IS NOT NULL THEN 1000
      WHEN na."title" ILIKE '%election%' THEN 800
      WHEN sh.id IS NOT NULL THEN 500
      ELSE 100
    END
) DESC, na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT 80;

-- ---------------------------------------------------------------------------
-- A-v3: the CURRENT app SQL (keyword-article-ranking.sql.ts,
-- fetchKeywordArticleRankedPool). Tiers 1000 topic / 800 title / 500 summary /
-- 100 other, one statement each, in rank order. Each statement filters
-- news_articles (status, window), tests its tier with EXISTS / a semi-join,
-- skips the ids the tiers above already returned (:taken) and stops at
-- LIMIT :need = K minus the rows collected so far. A tier runs only while
-- rows are still missing (:more), exactly as the app does.
-- Expected for a COMMON term (ঢাকা, নির্বাচন): tier 1000 alone fills K with
-- Limit -> Nested Loop Semi Join -> Index Scan using
-- news_articles_status_published_desc_nl_idx (outer) + Index Scan on
-- news_ai_analysis("articleId") (inner), a few hundred to a few thousand
-- loops, no Sort. For a RARE term (election) the planner may instead pick a
-- Bitmap Heap Scan on the trigram indexes + top-N Sort, and lower tiers run.
-- Results are identical to A-new (keyword-article-ranking.equivalence.spec.ts).
-- ---------------------------------------------------------------------------
\echo '############ A-v3-1. keyword-articles, mode=ai, term ঢাকা, 90-day window: tiered pool, K = 80 (alpha old shape: 57 s) ############'
\set taken '{}'
\set need 80
\set more true
\if :more
\echo '--- A-v3-1 tier 1000'
EXPLAIN (ANALYZE, BUFFERS)
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND ((
  COALESCE(a."topTopics"::text, '') ILIKE '%ঢাকা%'
  OR COALESCE(a."trendingKeywords"::text, '') ILIKE '%ঢাকা%'
  ))
  )
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need;
SELECT (:'taken'::text[] || COALESCE(array_agg(t.id), '{}'::text[]))::text AS taken,
       :need - count(*) AS need, :need - count(*) > 0 AS more
FROM (
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND ((
  COALESCE(a."topTopics"::text, '') ILIKE '%ঢাকা%'
  OR COALESCE(a."trendingKeywords"::text, '') ILIKE '%ঢাকা%'
  ))
  )
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need
) t \gset
\endif
\if :more
\echo '--- A-v3-1 tier 800 (runs only because the tiers above returned fewer than K rows)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND na."title" ILIKE '%ঢাকা%'
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need;
SELECT (:'taken'::text[] || COALESCE(array_agg(t.id), '{}'::text[]))::text AS taken,
       :need - count(*) AS need, :need - count(*) > 0 AS more
FROM (
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND na."title" ILIKE '%ঢাকা%'
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need
) t \gset
\endif
\if :more
\echo '--- A-v3-1 tier 500 (runs only because the tiers above returned fewer than K rows)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT u.id, u."sourceId"
FROM ((SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND COALESCE(a."summary", '') ILIKE '%ঢাকা%'
  ) AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND (
  ((
  COALESCE(a."trendingKeywords"::text, '') ILIKE '%ঢাকা%'
  OR COALESCE(a."topTopics"::text, '') ILIKE '%ঢাকা%'
  OR COALESCE(a."summary", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."what_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."where_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."who_involved", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."between_whom", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."why_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."root_cause", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."what_impact", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."future_implication", '') ILIKE '%ঢাকা%'
  ))
  OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা'))
  )
  )
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need) UNION (SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND COALESCE(a."summary", '') ILIKE '%ঢাকা%'
  ) AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা'))
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u.id DESC
LIMIT :need;
SELECT (:'taken'::text[] || COALESCE(array_agg(t.id), '{}'::text[]))::text AS taken,
       :need - count(*) AS need, :need - count(*) > 0 AS more
FROM (
SELECT u.id, u."sourceId"
FROM ((SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND COALESCE(a."summary", '') ILIKE '%ঢাকা%'
  ) AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND (
  ((
  COALESCE(a."trendingKeywords"::text, '') ILIKE '%ঢাকা%'
  OR COALESCE(a."topTopics"::text, '') ILIKE '%ঢাকা%'
  OR COALESCE(a."summary", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."what_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."where_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."who_involved", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."between_whom", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."why_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."root_cause", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."what_impact", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."future_implication", '') ILIKE '%ঢাকা%'
  ))
  OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা'))
  )
  )
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need) UNION (SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND COALESCE(a."summary", '') ILIKE '%ঢাকা%'
  ) AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা'))
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u.id DESC
LIMIT :need
) t \gset
\endif
\if :more
\echo '--- A-v3-1 tier 100 (runs only because the tiers above returned fewer than K rows)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT u.id, u."sourceId"
FROM ((SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND (
  ((
  COALESCE(a."trendingKeywords"::text, '') ILIKE '%ঢাকা%'
  OR COALESCE(a."topTopics"::text, '') ILIKE '%ঢাকা%'
  OR COALESCE(a."summary", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."what_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."where_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."who_involved", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."between_whom", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."why_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."root_cause", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."what_impact", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."future_implication", '') ILIKE '%ঢাকা%'
  ))
  OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা'))
  )
  )
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need) UNION (SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা'))
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u.id DESC
LIMIT :need;
SELECT (:'taken'::text[] || COALESCE(array_agg(t.id), '{}'::text[]))::text AS taken,
       :need - count(*) AS need, :need - count(*) > 0 AS more
FROM (
SELECT u.id, u."sourceId"
FROM ((SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND (
  ((
  COALESCE(a."trendingKeywords"::text, '') ILIKE '%ঢাকা%'
  OR COALESCE(a."topTopics"::text, '') ILIKE '%ঢাকা%'
  OR COALESCE(a."summary", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."what_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."where_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."who_involved", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."between_whom", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."why_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."root_cause", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."what_impact", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."future_implication", '') ILIKE '%ঢাকা%'
  ))
  OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা'))
  )
  )
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need) UNION (SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা'))
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u.id DESC
LIMIT :need
) t \gset
\endif
\echo 'A-v3-1: rows still missing after all tiers (0 = pool full):' :need

\echo '############ A-v3-2. keyword-articles, mode=ai, term ঢাকা, window=all: tiered pool, K = 80 (window=all; alpha old shape: timed out at 120 s) ############'
\set taken '{}'
\set need 80
\set more true
\if :more
\echo '--- A-v3-2 tier 1000'
EXPLAIN (ANALYZE, BUFFERS)
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
WHERE (na."status" = 'GOOD')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND ((
  COALESCE(a."topTopics"::text, '') ILIKE '%ঢাকা%'
  OR COALESCE(a."trendingKeywords"::text, '') ILIKE '%ঢাকা%'
  ))
  )
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need;
SELECT (:'taken'::text[] || COALESCE(array_agg(t.id), '{}'::text[]))::text AS taken,
       :need - count(*) AS need, :need - count(*) > 0 AS more
FROM (
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
WHERE (na."status" = 'GOOD')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND ((
  COALESCE(a."topTopics"::text, '') ILIKE '%ঢাকা%'
  OR COALESCE(a."trendingKeywords"::text, '') ILIKE '%ঢাকা%'
  ))
  )
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need
) t \gset
\endif
\if :more
\echo '--- A-v3-2 tier 800 (runs only because the tiers above returned fewer than K rows)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
WHERE (na."status" = 'GOOD')
  AND na."title" ILIKE '%ঢাকা%'
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need;
SELECT (:'taken'::text[] || COALESCE(array_agg(t.id), '{}'::text[]))::text AS taken,
       :need - count(*) AS need, :need - count(*) > 0 AS more
FROM (
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
WHERE (na."status" = 'GOOD')
  AND na."title" ILIKE '%ঢাকা%'
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need
) t \gset
\endif
\if :more
\echo '--- A-v3-2 tier 500 (runs only because the tiers above returned fewer than K rows)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT u.id, u."sourceId"
FROM ((SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND COALESCE(a."summary", '') ILIKE '%ঢাকা%'
  ) AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND (
  ((
  COALESCE(a."trendingKeywords"::text, '') ILIKE '%ঢাকা%'
  OR COALESCE(a."topTopics"::text, '') ILIKE '%ঢাকা%'
  OR COALESCE(a."summary", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."what_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."where_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."who_involved", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."between_whom", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."why_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."root_cause", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."what_impact", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."future_implication", '') ILIKE '%ঢাকা%'
  ))
  OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা'))
  )
  )
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need) UNION (SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND COALESCE(a."summary", '') ILIKE '%ঢাকা%'
  ) AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা'))
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u.id DESC
LIMIT :need;
SELECT (:'taken'::text[] || COALESCE(array_agg(t.id), '{}'::text[]))::text AS taken,
       :need - count(*) AS need, :need - count(*) > 0 AS more
FROM (
SELECT u.id, u."sourceId"
FROM ((SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND COALESCE(a."summary", '') ILIKE '%ঢাকা%'
  ) AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND (
  ((
  COALESCE(a."trendingKeywords"::text, '') ILIKE '%ঢাকা%'
  OR COALESCE(a."topTopics"::text, '') ILIKE '%ঢাকা%'
  OR COALESCE(a."summary", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."what_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."where_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."who_involved", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."between_whom", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."why_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."root_cause", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."what_impact", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."future_implication", '') ILIKE '%ঢাকা%'
  ))
  OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা'))
  )
  )
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need) UNION (SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND COALESCE(a."summary", '') ILIKE '%ঢাকা%'
  ) AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা'))
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u.id DESC
LIMIT :need
) t \gset
\endif
\if :more
\echo '--- A-v3-2 tier 100 (runs only because the tiers above returned fewer than K rows)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT u.id, u."sourceId"
FROM ((SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND (
  ((
  COALESCE(a."trendingKeywords"::text, '') ILIKE '%ঢাকা%'
  OR COALESCE(a."topTopics"::text, '') ILIKE '%ঢাকা%'
  OR COALESCE(a."summary", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."what_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."where_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."who_involved", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."between_whom", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."why_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."root_cause", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."what_impact", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."future_implication", '') ILIKE '%ঢাকা%'
  ))
  OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা'))
  )
  )
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need) UNION (SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD')
  AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা'))
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u.id DESC
LIMIT :need;
SELECT (:'taken'::text[] || COALESCE(array_agg(t.id), '{}'::text[]))::text AS taken,
       :need - count(*) AS need, :need - count(*) > 0 AS more
FROM (
SELECT u.id, u."sourceId"
FROM ((SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND (
  ((
  COALESCE(a."trendingKeywords"::text, '') ILIKE '%ঢাকা%'
  OR COALESCE(a."topTopics"::text, '') ILIKE '%ঢাকা%'
  OR COALESCE(a."summary", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."what_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."where_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."who_involved", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."between_whom", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."why_happened", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."root_cause", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."what_impact", '') ILIKE '%ঢাকা%'
  OR COALESCE(a."future_implication", '') ILIKE '%ঢাকা%'
  ))
  OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা'))
  )
  )
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need) UNION (SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD')
  AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা'))
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u.id DESC
LIMIT :need
) t \gset
\endif
\echo 'A-v3-2: rows still missing after all tiers (0 = pool full):' :need

\echo '############ A-v3-3. keyword-articles, mode=ai, term election, 90-day window: tiered pool, K = 80 (alpha old shape: 1.4 s cold) ############'
\set taken '{}'
\set need 80
\set more true
\if :more
\echo '--- A-v3-3 tier 1000'
EXPLAIN (ANALYZE, BUFFERS)
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND ((
  COALESCE(a."topTopics"::text, '') ILIKE '%election%'
  OR COALESCE(a."trendingKeywords"::text, '') ILIKE '%election%'
  ))
  )
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need;
SELECT (:'taken'::text[] || COALESCE(array_agg(t.id), '{}'::text[]))::text AS taken,
       :need - count(*) AS need, :need - count(*) > 0 AS more
FROM (
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND ((
  COALESCE(a."topTopics"::text, '') ILIKE '%election%'
  OR COALESCE(a."trendingKeywords"::text, '') ILIKE '%election%'
  ))
  )
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need
) t \gset
\endif
\if :more
\echo '--- A-v3-3 tier 800 (runs only because the tiers above returned fewer than K rows)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND na."title" ILIKE '%election%'
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need;
SELECT (:'taken'::text[] || COALESCE(array_agg(t.id), '{}'::text[]))::text AS taken,
       :need - count(*) AS need, :need - count(*) > 0 AS more
FROM (
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND na."title" ILIKE '%election%'
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need
) t \gset
\endif
\if :more
\echo '--- A-v3-3 tier 500 (runs only because the tiers above returned fewer than K rows)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT u.id, u."sourceId"
FROM ((SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND COALESCE(a."summary", '') ILIKE '%election%'
  ) AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND (
  ((
  COALESCE(a."trendingKeywords"::text, '') ILIKE '%election%'
  OR COALESCE(a."topTopics"::text, '') ILIKE '%election%'
  OR COALESCE(a."summary", '') ILIKE '%election%'
  OR COALESCE(a."what_happened", '') ILIKE '%election%'
  OR COALESCE(a."where_happened", '') ILIKE '%election%'
  OR COALESCE(a."who_involved", '') ILIKE '%election%'
  OR COALESCE(a."between_whom", '') ILIKE '%election%'
  OR COALESCE(a."why_happened", '') ILIKE '%election%'
  OR COALESCE(a."root_cause", '') ILIKE '%election%'
  OR COALESCE(a."what_impact", '') ILIKE '%election%'
  OR COALESCE(a."future_implication", '') ILIKE '%election%'
  ))
  OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'election'))
  )
  )
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need) UNION (SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND COALESCE(a."summary", '') ILIKE '%election%'
  ) AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'election'))
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u.id DESC
LIMIT :need;
SELECT (:'taken'::text[] || COALESCE(array_agg(t.id), '{}'::text[]))::text AS taken,
       :need - count(*) AS need, :need - count(*) > 0 AS more
FROM (
SELECT u.id, u."sourceId"
FROM ((SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND COALESCE(a."summary", '') ILIKE '%election%'
  ) AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND (
  ((
  COALESCE(a."trendingKeywords"::text, '') ILIKE '%election%'
  OR COALESCE(a."topTopics"::text, '') ILIKE '%election%'
  OR COALESCE(a."summary", '') ILIKE '%election%'
  OR COALESCE(a."what_happened", '') ILIKE '%election%'
  OR COALESCE(a."where_happened", '') ILIKE '%election%'
  OR COALESCE(a."who_involved", '') ILIKE '%election%'
  OR COALESCE(a."between_whom", '') ILIKE '%election%'
  OR COALESCE(a."why_happened", '') ILIKE '%election%'
  OR COALESCE(a."root_cause", '') ILIKE '%election%'
  OR COALESCE(a."what_impact", '') ILIKE '%election%'
  OR COALESCE(a."future_implication", '') ILIKE '%election%'
  ))
  OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'election'))
  )
  )
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need) UNION (SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND COALESCE(a."summary", '') ILIKE '%election%'
  ) AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'election'))
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u.id DESC
LIMIT :need
) t \gset
\endif
\if :more
\echo '--- A-v3-3 tier 100 (runs only because the tiers above returned fewer than K rows)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT u.id, u."sourceId"
FROM ((SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND (
  ((
  COALESCE(a."trendingKeywords"::text, '') ILIKE '%election%'
  OR COALESCE(a."topTopics"::text, '') ILIKE '%election%'
  OR COALESCE(a."summary", '') ILIKE '%election%'
  OR COALESCE(a."what_happened", '') ILIKE '%election%'
  OR COALESCE(a."where_happened", '') ILIKE '%election%'
  OR COALESCE(a."who_involved", '') ILIKE '%election%'
  OR COALESCE(a."between_whom", '') ILIKE '%election%'
  OR COALESCE(a."why_happened", '') ILIKE '%election%'
  OR COALESCE(a."root_cause", '') ILIKE '%election%'
  OR COALESCE(a."what_impact", '') ILIKE '%election%'
  OR COALESCE(a."future_implication", '') ILIKE '%election%'
  ))
  OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'election'))
  )
  )
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need) UNION (SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'election'))
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u.id DESC
LIMIT :need;
SELECT (:'taken'::text[] || COALESCE(array_agg(t.id), '{}'::text[]))::text AS taken,
       :need - count(*) AS need, :need - count(*) > 0 AS more
FROM (
SELECT u.id, u."sourceId"
FROM ((SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND (
  ((
  COALESCE(a."trendingKeywords"::text, '') ILIKE '%election%'
  OR COALESCE(a."topTopics"::text, '') ILIKE '%election%'
  OR COALESCE(a."summary", '') ILIKE '%election%'
  OR COALESCE(a."what_happened", '') ILIKE '%election%'
  OR COALESCE(a."where_happened", '') ILIKE '%election%'
  OR COALESCE(a."who_involved", '') ILIKE '%election%'
  OR COALESCE(a."between_whom", '') ILIKE '%election%'
  OR COALESCE(a."why_happened", '') ILIKE '%election%'
  OR COALESCE(a."root_cause", '') ILIKE '%election%'
  OR COALESCE(a."what_impact", '') ILIKE '%election%'
  OR COALESCE(a."future_implication", '') ILIKE '%election%'
  ))
  OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'election'))
  )
  )
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need) UNION (SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'election'))
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u.id DESC
LIMIT :need
) t \gset
\endif
\echo 'A-v3-3: rows still missing after all tiers (0 = pool full):' :need

\echo '############ A-v3-4. keyword-articles, mode=ai, term নির্বাচন, 90-day window: tiered pool, K = 80 ############'
\set taken '{}'
\set need 80
\set more true
\if :more
\echo '--- A-v3-4 tier 1000'
EXPLAIN (ANALYZE, BUFFERS)
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND ((
  COALESCE(a."topTopics"::text, '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."trendingKeywords"::text, '') ILIKE '%নির্বাচন%'
  ))
  )
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need;
SELECT (:'taken'::text[] || COALESCE(array_agg(t.id), '{}'::text[]))::text AS taken,
       :need - count(*) AS need, :need - count(*) > 0 AS more
FROM (
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND ((
  COALESCE(a."topTopics"::text, '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."trendingKeywords"::text, '') ILIKE '%নির্বাচন%'
  ))
  )
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need
) t \gset
\endif
\if :more
\echo '--- A-v3-4 tier 800 (runs only because the tiers above returned fewer than K rows)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND na."title" ILIKE '%নির্বাচন%'
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need;
SELECT (:'taken'::text[] || COALESCE(array_agg(t.id), '{}'::text[]))::text AS taken,
       :need - count(*) AS need, :need - count(*) > 0 AS more
FROM (
SELECT na.id, na."sourceId" AS "sourceId"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND na."title" ILIKE '%নির্বাচন%'
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need
) t \gset
\endif
\if :more
\echo '--- A-v3-4 tier 500 (runs only because the tiers above returned fewer than K rows)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT u.id, u."sourceId"
FROM ((SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND COALESCE(a."summary", '') ILIKE '%নির্বাচন%'
  ) AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND (
  ((
  COALESCE(a."trendingKeywords"::text, '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."topTopics"::text, '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."summary", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."what_happened", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."where_happened", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."who_involved", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."between_whom", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."why_happened", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."root_cause", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."what_impact", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."future_implication", '') ILIKE '%নির্বাচন%'
  ))
  OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'নির্বাচন'))
  )
  )
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need) UNION (SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND COALESCE(a."summary", '') ILIKE '%নির্বাচন%'
  ) AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'নির্বাচন'))
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u.id DESC
LIMIT :need;
SELECT (:'taken'::text[] || COALESCE(array_agg(t.id), '{}'::text[]))::text AS taken,
       :need - count(*) AS need, :need - count(*) > 0 AS more
FROM (
SELECT u.id, u."sourceId"
FROM ((SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND COALESCE(a."summary", '') ILIKE '%নির্বাচন%'
  ) AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND (
  ((
  COALESCE(a."trendingKeywords"::text, '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."topTopics"::text, '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."summary", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."what_happened", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."where_happened", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."who_involved", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."between_whom", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."why_happened", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."root_cause", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."what_impact", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."future_implication", '') ILIKE '%নির্বাচন%'
  ))
  OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'নির্বাচন'))
  )
  )
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need) UNION (SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND COALESCE(a."summary", '') ILIKE '%নির্বাচন%'
  ) AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'নির্বাচন'))
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u.id DESC
LIMIT :need
) t \gset
\endif
\if :more
\echo '--- A-v3-4 tier 100 (runs only because the tiers above returned fewer than K rows)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT u.id, u."sourceId"
FROM ((SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND (
  ((
  COALESCE(a."trendingKeywords"::text, '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."topTopics"::text, '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."summary", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."what_happened", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."where_happened", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."who_involved", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."between_whom", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."why_happened", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."root_cause", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."what_impact", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."future_implication", '') ILIKE '%নির্বাচন%'
  ))
  OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'নির্বাচন'))
  )
  )
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need) UNION (SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'নির্বাচন'))
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u.id DESC
LIMIT :need;
SELECT (:'taken'::text[] || COALESCE(array_agg(t.id), '{}'::text[]))::text AS taken,
       :need - count(*) AS need, :need - count(*) > 0 AS more
FROM (
SELECT u.id, u."sourceId"
FROM ((SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND EXISTS (
SELECT 1 FROM "news_ai_analysis" a
WHERE a."articleId" = na.id AND (
  ((
  COALESCE(a."trendingKeywords"::text, '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."topTopics"::text, '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."summary", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."what_happened", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."where_happened", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."who_involved", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."between_whom", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."why_happened", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."root_cause", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."what_impact", '') ILIKE '%নির্বাচন%'
  OR COALESCE(a."future_implication", '') ILIKE '%নির্বাচন%'
  ))
  OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'নির্বাচন'))
  )
  )
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need) UNION (SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt" AS "publishedAt"
FROM "news_articles" na
WHERE (na."status" = 'GOOD' AND na."publishedAt" >= :'topic_from')
  AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'নির্বাচন'))
  AND NOT (na.id = ANY(:'taken'::text[]))
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT :need)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u.id DESC
LIMIT :need
) t \gset
\endif
\echo 'A-v3-4: rows still missing after all tiers (0 = pool full):' :need

\echo '############ B. timeline?search=ঢাকা&windowHours=24 (Prisma slow path, reconstructed) ############'
-- Window = the app default: Bangladesh wall clock, top of the next hour, minus 24 h.
SELECT (date_trunc('hour', now() AT TIME ZONE 'Asia/Dhaka') + interval '1 hour') AS win_end,
       (date_trunc('hour', now() AT TIME ZONE 'Asia/Dhaka') - interval '23 hours') AS win_start \gset
\echo 'window:' :'win_start' '->' :'win_end'
-- B1: current shape. Prisma turns newsAIAnalyses.some into an UNcorrelated IN (...) over ALL analyses.
EXPLAIN (ANALYZE, BUFFERS)
SELECT na."id", na."publishedAt", na."scrapedAt", na."sourceId", na."sourceWebsite"
FROM "news_articles" na
WHERE na."status" = 'GOOD'
  AND (na."publishedAt" >= :'win_start' AND na."publishedAt" <= :'win_end')
  AND (
       na."title" ILIKE '%ঢাকা%'
    OR na."content" ILIKE '%ঢাকা%'
    OR na."id" IN (SELECT t1."articleId" FROM "news_ai_analysis" t1
                   WHERE t1."summary" ILIKE '%ঢাকা%' AND t1."articleId" IS NOT NULL)
  )
ORDER BY na."publishedAt" ASC
LIMIT 2500;
-- B2: proposed shape (perf/search-query-fixes): window first, correlated EXISTS per windowed row.
EXPLAIN (ANALYZE, BUFFERS)
SELECT na."id"
FROM "news_articles" na
WHERE na."status" = 'GOOD'
  AND (na."publishedAt" >= :'win_start' AND na."publishedAt" <= :'win_end')
  AND (
       na."title" ILIKE '%ঢাকা%'
    OR na."content" ILIKE '%ঢাকা%'
    OR EXISTS (SELECT 1 FROM "news_ai_analysis" a
               WHERE a."articleId" = na.id AND COALESCE(a."summary", '') ILIKE '%ঢাকা%')
  )
LIMIT 30001;

\echo '############ C. Latest feed: sentiment=positive, exclude_top, take 101 (Prisma, reconstructed) ############'
-- C1: current shape. ORDER BY publishedAt DESC NULLS LAST cannot use the (status, publishedAt) btree order.
EXPLAIN (ANALYZE, BUFFERS)
SELECT na."id", na."publishedAt"
FROM "news_articles" na
WHERE na."status" = 'GOOD'
  AND na."id" IN (SELECT t1."articleId" FROM "news_ai_analysis" t1
                  WHERE (t1."overallSentimentLabel" ILIKE 'ইতিবাচক' OR t1."overallSentimentLabel" ILIKE 'POSITIVE'
                      OR t1."overallSentimentLabel" ILIKE 'positive' OR t1."overallSentimentLabel" ILIKE 'Positive')
                    AND t1."articleId" IS NOT NULL)
  AND (na."origin" IS NULL OR na."origin" <> '/news/top_news')
ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC
LIMIT 101;
-- C2: same, only_top (measured 3-9 s) for comparison.
EXPLAIN (ANALYZE, BUFFERS)
SELECT na."id", na."publishedAt"
FROM "news_articles" na
WHERE na."status" = 'GOOD'
  AND na."id" IN (SELECT t1."articleId" FROM "news_ai_analysis" t1
                  WHERE (t1."overallSentimentLabel" ILIKE 'ইতিবাচক' OR t1."overallSentimentLabel" ILIKE 'POSITIVE'
                      OR t1."overallSentimentLabel" ILIKE 'positive' OR t1."overallSentimentLabel" ILIKE 'Positive')
                    AND t1."articleId" IS NOT NULL)
  AND na."origin" = '/news/top_news'
ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC
LIMIT 101;
-- C3: index-order hypothesis. Same filter, ORDER BY the btree's native order.
EXPLAIN (ANALYZE, BUFFERS)
SELECT na."id", na."publishedAt"
FROM "news_articles" na
WHERE na."status" = 'GOOD'
  AND na."id" IN (SELECT t1."articleId" FROM "news_ai_analysis" t1
                  WHERE (t1."overallSentimentLabel" ILIKE 'ইতিবাচক' OR t1."overallSentimentLabel" ILIKE 'POSITIVE'
                      OR t1."overallSentimentLabel" ILIKE 'positive' OR t1."overallSentimentLabel" ILIKE 'Positive')
                    AND t1."articleId" IS NOT NULL)
  AND (na."origin" IS NULL OR na."origin" <> '/news/top_news')
ORDER BY na."publishedAt" DESC, na."id" DESC
LIMIT 101;
-- C4: the exact COUNT a caller without skipTotalCount pays (Latest does skip it).
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM "news_articles" na
WHERE na."status" = 'GOOD'
  AND na."id" IN (SELECT t1."articleId" FROM "news_ai_analysis" t1
                  WHERE (t1."overallSentimentLabel" ILIKE 'ইতিবাচক' OR t1."overallSentimentLabel" ILIKE 'POSITIVE'
                      OR t1."overallSentimentLabel" ILIKE 'positive' OR t1."overallSentimentLabel" ILIKE 'Positive')
                    AND t1."articleId" IS NOT NULL)
  AND (na."origin" IS NULL OR na."origin" <> '/news/top_news');

\echo '############ D. news/search-panel-cache build: candidate query (EXPLAIN only, nothing executes) ############'
-- ---------------------------------------------------------------------------
-- D: NewsAnalyticsService.buildSearchPanelCandidateSql, default request from
-- /news (no dates -> rolling 24 h, status GOOD, cap 500). Parameters inlined.
-- Plain EXPLAIN on purpose: it only plans, so it is safe on a busy database.
-- Expected (current SQL, D1/D2): three LIMITed streams, each either an Index
-- Scan (Backward or forward) on news_articles_status_published_desc_nl_idx /
-- (status, publishedAt) with a filter, or a Bitmap Heap Scan on
-- news_articles_title_trgm_idx / news_articles_search_tsv_gin_idx /
-- news_ai_analysis_*_trgm_idx + a small top-N sort. NO Seq Scan on
-- news_articles, and no scrape_results / "content" / "rawContent" anywhere.
-- D4 (the 9e4b9b920 shape, for comparison only) should show a Seq Scan on
-- news_articles (createdAt has no index) with content ILIKE and a SubPlan
-- over scrape_results — the build that hit its 8 s statement_timeout.
-- The follow-up reads use the candidate ids: news_ai_analysis by
-- ("articleId", "lastAnalyzedAt" DESC) and news_article_keywords by
-- "newsArticleId"; both are index lookups over <= 500 ids.
-- ---------------------------------------------------------------------------
-- D1: search = election (rare term)
EXPLAIN
SELECT u."id", u."publishedAt"
FROM ((
    SELECT na."id", na."publishedAt" FROM "news_articles" na
    WHERE (na."status" = 'GOOD'
           AND na."publishedAt" >= (now() - interval '24 hours')::timestamp AND na."publishedAt" <= now()::timestamp)
      AND na."title" ILIKE '%election%'
    ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC LIMIT 500
) UNION (
    SELECT na."id", na."publishedAt" FROM "news_articles" na
    WHERE (na."status" = 'GOOD'
           AND na."publishedAt" >= (now() - interval '24 hours')::timestamp AND na."publishedAt" <= now()::timestamp)
      AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'election'))
    ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC LIMIT 500
) UNION (
    SELECT na."id", na."publishedAt" FROM "news_articles" na
    WHERE (na."status" = 'GOOD'
           AND na."publishedAt" >= (now() - interval '24 hours')::timestamp AND na."publishedAt" <= now()::timestamp)
      AND EXISTS (SELECT 1 FROM "news_ai_analysis" a WHERE a."articleId" = na.id AND (
            (COALESCE(a."trendingKeywords"::text, '') ILIKE '%election%'
             OR COALESCE(a."topTopics"::text, '') ILIKE '%election%'
             OR COALESCE(a."summary", '') ILIKE '%election%'
             OR COALESCE(a."what_happened", '') ILIKE '%election%'
             OR COALESCE(a."where_happened", '') ILIKE '%election%'
             OR COALESCE(a."who_involved", '') ILIKE '%election%'
             OR COALESCE(a."between_whom", '') ILIKE '%election%'
             OR COALESCE(a."why_happened", '') ILIKE '%election%'
             OR COALESCE(a."root_cause", '') ILIKE '%election%'
             OR COALESCE(a."what_impact", '') ILIKE '%election%'
             OR COALESCE(a."future_implication", '') ILIKE '%election%')
            OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'election'))))
    ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC LIMIT 500
)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u."id" DESC
LIMIT 500;
-- D2: search = ঢাকা (common term), 90-day explicit window (startDate/endDate sent)
EXPLAIN
SELECT u."id", u."publishedAt"
FROM ((
    SELECT na."id", na."publishedAt" FROM "news_articles" na
    WHERE (na."status" = 'GOOD'
           AND na."publishedAt" >= (now() - interval '90 days')::timestamp AND na."publishedAt" <= now()::timestamp)
      AND na."title" ILIKE '%ঢাকা%'
    ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC LIMIT 500
) UNION (
    SELECT na."id", na."publishedAt" FROM "news_articles" na
    WHERE (na."status" = 'GOOD'
           AND na."publishedAt" >= (now() - interval '90 days')::timestamp AND na."publishedAt" <= now()::timestamp)
      AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা'))
    ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC LIMIT 500
) UNION (
    SELECT na."id", na."publishedAt" FROM "news_articles" na
    WHERE (na."status" = 'GOOD'
           AND na."publishedAt" >= (now() - interval '90 days')::timestamp AND na."publishedAt" <= now()::timestamp)
      AND EXISTS (SELECT 1 FROM "news_ai_analysis" a WHERE a."articleId" = na.id AND (
            (COALESCE(a."trendingKeywords"::text, '') ILIKE '%ঢাকা%'
             OR COALESCE(a."topTopics"::text, '') ILIKE '%ঢাকা%'
             OR COALESCE(a."summary", '') ILIKE '%ঢাকা%'
             OR COALESCE(a."what_happened", '') ILIKE '%ঢাকা%'
             OR COALESCE(a."where_happened", '') ILIKE '%ঢাকা%'
             OR COALESCE(a."who_involved", '') ILIKE '%ঢাকা%'
             OR COALESCE(a."between_whom", '') ILIKE '%ঢাকা%'
             OR COALESCE(a."why_happened", '') ILIKE '%ঢাকা%'
             OR COALESCE(a."root_cause", '') ILIKE '%ঢাকা%'
             OR COALESCE(a."what_impact", '') ILIKE '%ঢাকা%'
             OR COALESCE(a."future_implication", '') ILIKE '%ঢাকা%')
            OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', 'ঢাকা'))))
    ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC LIMIT 500
)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u."id" DESC
LIMIT 500;
-- D3: aiKeyword only (topic chip, no search text): one walk + trendingKeywords trigram pre-filter
EXPLAIN
SELECT na."id", na."publishedAt" FROM "news_articles" na
WHERE (na."status" = 'GOOD'
       AND na."publishedAt" >= (now() - interval '24 hours')::timestamp AND na."publishedAt" <= now()::timestamp
       AND EXISTS (SELECT 1 FROM "news_ai_analysis" a WHERE a."articleId" = na.id
                   AND COALESCE(a."trendingKeywords"::text, '') ILIKE '%election%'))
  AND TRUE
ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC LIMIT 500;
-- D4: the PREVIOUS shape (9e4b9b920), for comparison only. Do not ANALYZE it.
EXPLAIN
SELECT na."id", na."createdAt" FROM "news_articles" na
WHERE na."status" = 'GOOD'
  AND na."createdAt" >= (now() - interval '24 hours')::timestamp AND na."createdAt" <= now()::timestamp
  AND (na."title" ILIKE '%election%' OR na."content" ILIKE '%election%'
       OR EXISTS (SELECT 1 FROM "scrape_results" sr WHERE sr."id" = na."scrapeResultId"
                  AND (sr."title" ILIKE '%election%' OR sr."rawContent" ILIKE '%election%')))
ORDER BY na."createdAt" DESC
LIMIT 2000;

\echo '############ G. walk vs fence: search-panel streams (24 h) and topic-search tier 1000 (ঢাকা 90 d / 24 h, election) ############'
-- ---------------------------------------------------------------------------
-- G: STAGE ONLY. EXPLAIN (ANALYZE, BUFFERS) executes every statement
-- (read-only session, 60 s per statement). Run on its own with the sed
-- command in the header of this file (range "G." to the "E." header).
--
-- Two shapes of the same query, as PREPAREd statements (the way Prisma runs
-- them, custom plans):
--   walk   ... WHERE <filter> AND <match> ORDER BY publishedAt DESC, id DESC LIMIT n
--          The LIMIT lets the planner walk news_articles_status_published_desc_nl_idx
--          newest-first and test each row (heap filter / EXISTS probe) until n match.
--   fence  SELECT ... FROM (SELECT ... WHERE <filter> AND <match> OFFSET 0) m
--          ORDER BY ... LIMIT n. The planner costs the whole in-window match
--          set, so it can use the GIN / trigram bitmap and top-N sort it.
-- Same WHERE, same total order ((publishedAt, id); id unique), same LIMIT:
-- each case ends with identical_rows_in_order, which must be t.
--
-- G1 the search-panel candidate query (buildSearchPanelCandidateSql, typed
--    topic search: search = aiKeyword = term, 24 h, GOOD, cap 500). The app
--    fences since 4a1373cd3 for windows <= 7 days. Stage section E, ঢাকা,
--    walk: search_tsv stream 284 rows, 7.7 s cold, 9.8 s for the query.
--    G1t repeats the search_tsv stream alone.
-- G2 topic search, tier 1000 only (keyword-article-ranking.sql.ts; K = 80;
--    for a common term it fills K alone, so it is the whole pool). The app
--    WALKS (unchanged). Alpha: first ঢাকা loads 17-21 s; earlier diagnose:
--    ~7,200 analysis probes at ~0.87 ms cold = ~3.5 s in the database.
--    The alternative bitmap path reads every trigram match on
--    topTopics/trendingKeywords (~3.8k for ঢাকা, all time), recheck on the
--    analysis heap, then a probe of news_articles per match for the window.
--
-- Order matters for cold numbers: the FIRST statement of a case pays the
-- cold reads the second may reuse. Each case runs the alternative first
-- (so the current shape gets any warm advantage), then both again warm.
-- ---------------------------------------------------------------------------
\set ON_ERROR_STOP off
SET statement_timeout = '60s';
SET lock_timeout = '2s';
SET default_transaction_read_only = on;
SET application_name = 'falcon-diagnose-walk-vs-fence';
SET TIME ZONE 'UTC';
\timing on
DEALLOCATE ALL;
SELECT (SELECT string_agg(chr(c), '') FROM unnest(ARRAY[
    9, 10, 11, 12, 13, 32, 160, 5760, 8192, 8193, 8194, 8195, 8196, 8197, 8198,
    8199, 8200, 8201, 8202, 8232, 8233, 8239, 8287, 12288, 65279]) c) AS trim_chars \gset

PREPARE g_panel_walk(timestamptz, timestamptz, text, text, text, text, text, text, bigint) AS
SELECT COALESCE(array_agg(c."id" ORDER BY c."publishedAt" DESC NULLS LAST, c."id" DESC), '{}')::text AS ids, count(*) AS n
FROM (
SELECT u."id", u."publishedAt"
FROM ((
    SELECT na."id", na."publishedAt"
    FROM "news_articles" na
    WHERE (na."status" = 'GOOD' AND na."publishedAt" >= $1 AND na."publishedAt" <= $2 AND EXISTS (
                SELECT 1 FROM "news_ai_analysis" a
                CROSS JOIN LATERAL jsonb_array_elements(
                    CASE WHEN jsonb_typeof(a."trendingKeywords") = 'array'
                         THEN a."trendingKeywords" ELSE '[]'::jsonb END
                ) tk(e)
                WHERE a."articleId" = na.id
                  AND COALESCE(a."trendingKeywords"::text, '') ILIKE $3
                  AND jsonb_typeof(tk.e) = 'object'
                  AND lower(btrim(
                      COALESCE(NULLIF(tk.e->>'keyword', ''), NULLIF(tk.e->>'text', ''), tk.e->>'label', ''),
                      $4
                  )) = $5
            )) AND na."title" ILIKE $6
    ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC
    LIMIT $9
) UNION (
    SELECT na."id", na."publishedAt"
    FROM "news_articles" na
    WHERE (na."status" = 'GOOD' AND na."publishedAt" >= $1 AND na."publishedAt" <= $2 AND EXISTS (
                SELECT 1 FROM "news_ai_analysis" a
                CROSS JOIN LATERAL jsonb_array_elements(
                    CASE WHEN jsonb_typeof(a."trendingKeywords") = 'array'
                         THEN a."trendingKeywords" ELSE '[]'::jsonb END
                ) tk(e)
                WHERE a."articleId" = na.id
                  AND COALESCE(a."trendingKeywords"::text, '') ILIKE $3
                  AND jsonb_typeof(tk.e) = 'object'
                  AND lower(btrim(
                      COALESCE(NULLIF(tk.e->>'keyword', ''), NULLIF(tk.e->>'text', ''), tk.e->>'label', ''),
                      $4
                  )) = $5
            )) AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', $7))
    ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC
    LIMIT $9
) UNION (
    SELECT na."id", na."publishedAt"
    FROM "news_articles" na
    WHERE (na."status" = 'GOOD' AND na."publishedAt" >= $1 AND na."publishedAt" <= $2 AND EXISTS (
                SELECT 1 FROM "news_ai_analysis" a
                CROSS JOIN LATERAL jsonb_array_elements(
                    CASE WHEN jsonb_typeof(a."trendingKeywords") = 'array'
                         THEN a."trendingKeywords" ELSE '[]'::jsonb END
                ) tk(e)
                WHERE a."articleId" = na.id
                  AND COALESCE(a."trendingKeywords"::text, '') ILIKE $3
                  AND jsonb_typeof(tk.e) = 'object'
                  AND lower(btrim(
                      COALESCE(NULLIF(tk.e->>'keyword', ''), NULLIF(tk.e->>'text', ''), tk.e->>'label', ''),
                      $4
                  )) = $5
            )) AND EXISTS (
                SELECT 1 FROM "news_ai_analysis" a
                WHERE a."articleId" = na.id
                  AND (
                    ((COALESCE(a."trendingKeywords"::text, '') ILIKE $8
                 OR COALESCE(a."topTopics"::text, '') ILIKE $8
                 OR COALESCE(a."summary", '') ILIKE $8
                 OR COALESCE(a."what_happened", '') ILIKE $8
                 OR COALESCE(a."where_happened", '') ILIKE $8
                 OR COALESCE(a."who_involved", '') ILIKE $8
                 OR COALESCE(a."between_whom", '') ILIKE $8
                 OR COALESCE(a."why_happened", '') ILIKE $8
                 OR COALESCE(a."root_cause", '') ILIKE $8
                 OR COALESCE(a."what_impact", '') ILIKE $8
                 OR COALESCE(a."future_implication", '') ILIKE $8))
                    OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', $7))
                  )
            )
    ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC
    LIMIT $9
)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u."id" DESC
LIMIT $9
) c;

PREPARE g_panel_fence(timestamptz, timestamptz, text, text, text, text, text, text, bigint) AS
SELECT COALESCE(array_agg(c."id" ORDER BY c."publishedAt" DESC NULLS LAST, c."id" DESC), '{}')::text AS ids, count(*) AS n
FROM (
SELECT u."id", u."publishedAt"
FROM ((
    SELECT m."id", m."publishedAt"
    FROM (
        SELECT na."id", na."publishedAt"
        FROM "news_articles" na
        WHERE (na."status" = 'GOOD' AND na."publishedAt" >= $1 AND na."publishedAt" <= $2 AND EXISTS (
                SELECT 1 FROM "news_ai_analysis" a
                CROSS JOIN LATERAL jsonb_array_elements(
                    CASE WHEN jsonb_typeof(a."trendingKeywords") = 'array'
                         THEN a."trendingKeywords" ELSE '[]'::jsonb END
                ) tk(e)
                WHERE a."articleId" = na.id
                  AND COALESCE(a."trendingKeywords"::text, '') ILIKE $3
                  AND jsonb_typeof(tk.e) = 'object'
                  AND lower(btrim(
                      COALESCE(NULLIF(tk.e->>'keyword', ''), NULLIF(tk.e->>'text', ''), tk.e->>'label', ''),
                      $4
                  )) = $5
            )) AND na."title" ILIKE $6
        OFFSET 0
    ) m
    ORDER BY m."publishedAt" DESC NULLS LAST, m."id" DESC
    LIMIT $9
) UNION (
    SELECT m."id", m."publishedAt"
    FROM (
        SELECT na."id", na."publishedAt"
        FROM "news_articles" na
        WHERE (na."status" = 'GOOD' AND na."publishedAt" >= $1 AND na."publishedAt" <= $2 AND EXISTS (
                SELECT 1 FROM "news_ai_analysis" a
                CROSS JOIN LATERAL jsonb_array_elements(
                    CASE WHEN jsonb_typeof(a."trendingKeywords") = 'array'
                         THEN a."trendingKeywords" ELSE '[]'::jsonb END
                ) tk(e)
                WHERE a."articleId" = na.id
                  AND COALESCE(a."trendingKeywords"::text, '') ILIKE $3
                  AND jsonb_typeof(tk.e) = 'object'
                  AND lower(btrim(
                      COALESCE(NULLIF(tk.e->>'keyword', ''), NULLIF(tk.e->>'text', ''), tk.e->>'label', ''),
                      $4
                  )) = $5
            )) AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', $7))
        OFFSET 0
    ) m
    ORDER BY m."publishedAt" DESC NULLS LAST, m."id" DESC
    LIMIT $9
) UNION (
    SELECT m."id", m."publishedAt"
    FROM (
        SELECT na."id", na."publishedAt"
        FROM "news_articles" na
        WHERE (na."status" = 'GOOD' AND na."publishedAt" >= $1 AND na."publishedAt" <= $2 AND EXISTS (
                SELECT 1 FROM "news_ai_analysis" a
                CROSS JOIN LATERAL jsonb_array_elements(
                    CASE WHEN jsonb_typeof(a."trendingKeywords") = 'array'
                         THEN a."trendingKeywords" ELSE '[]'::jsonb END
                ) tk(e)
                WHERE a."articleId" = na.id
                  AND COALESCE(a."trendingKeywords"::text, '') ILIKE $3
                  AND jsonb_typeof(tk.e) = 'object'
                  AND lower(btrim(
                      COALESCE(NULLIF(tk.e->>'keyword', ''), NULLIF(tk.e->>'text', ''), tk.e->>'label', ''),
                      $4
                  )) = $5
            )) AND EXISTS (
                SELECT 1 FROM "news_ai_analysis" a
                WHERE a."articleId" = na.id
                  AND (
                    ((COALESCE(a."trendingKeywords"::text, '') ILIKE $8
                 OR COALESCE(a."topTopics"::text, '') ILIKE $8
                 OR COALESCE(a."summary", '') ILIKE $8
                 OR COALESCE(a."what_happened", '') ILIKE $8
                 OR COALESCE(a."where_happened", '') ILIKE $8
                 OR COALESCE(a."who_involved", '') ILIKE $8
                 OR COALESCE(a."between_whom", '') ILIKE $8
                 OR COALESCE(a."why_happened", '') ILIKE $8
                 OR COALESCE(a."root_cause", '') ILIKE $8
                 OR COALESCE(a."what_impact", '') ILIKE $8
                 OR COALESCE(a."future_implication", '') ILIKE $8))
                    OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', $7))
                  )
            )
        OFFSET 0
    ) m
    ORDER BY m."publishedAt" DESC NULLS LAST, m."id" DESC
    LIMIT $9
)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u."id" DESC
LIMIT $9
) c;

PREPARE g_tsv_walk(timestamptz, timestamptz, text, text, text, text, text, text, bigint) AS
SELECT COALESCE(array_agg(c."id" ORDER BY c."publishedAt" DESC NULLS LAST, c."id" DESC), '{}')::text AS ids, count(*) AS n
FROM (
    SELECT na."id", na."publishedAt"
    FROM "news_articles" na
    WHERE (na."status" = 'GOOD' AND na."publishedAt" >= $1 AND na."publishedAt" <= $2 AND EXISTS (
                SELECT 1 FROM "news_ai_analysis" a
                CROSS JOIN LATERAL jsonb_array_elements(
                    CASE WHEN jsonb_typeof(a."trendingKeywords") = 'array'
                         THEN a."trendingKeywords" ELSE '[]'::jsonb END
                ) tk(e)
                WHERE a."articleId" = na.id
                  AND COALESCE(a."trendingKeywords"::text, '') ILIKE $3
                  AND jsonb_typeof(tk.e) = 'object'
                  AND lower(btrim(
                      COALESCE(NULLIF(tk.e->>'keyword', ''), NULLIF(tk.e->>'text', ''), tk.e->>'label', ''),
                      $4
                  )) = $5
            )) AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', $7))
    ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC
    LIMIT $9
) c;

PREPARE g_tsv_fence(timestamptz, timestamptz, text, text, text, text, text, text, bigint) AS
SELECT COALESCE(array_agg(c."id" ORDER BY c."publishedAt" DESC NULLS LAST, c."id" DESC), '{}')::text AS ids, count(*) AS n
FROM (
    SELECT m."id", m."publishedAt"
    FROM (
        SELECT na."id", na."publishedAt"
        FROM "news_articles" na
        WHERE (na."status" = 'GOOD' AND na."publishedAt" >= $1 AND na."publishedAt" <= $2 AND EXISTS (
                SELECT 1 FROM "news_ai_analysis" a
                CROSS JOIN LATERAL jsonb_array_elements(
                    CASE WHEN jsonb_typeof(a."trendingKeywords") = 'array'
                         THEN a."trendingKeywords" ELSE '[]'::jsonb END
                ) tk(e)
                WHERE a."articleId" = na.id
                  AND COALESCE(a."trendingKeywords"::text, '') ILIKE $3
                  AND jsonb_typeof(tk.e) = 'object'
                  AND lower(btrim(
                      COALESCE(NULLIF(tk.e->>'keyword', ''), NULLIF(tk.e->>'text', ''), tk.e->>'label', ''),
                      $4
                  )) = $5
            )) AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', $7))
        OFFSET 0
    ) m
    ORDER BY m."publishedAt" DESC NULLS LAST, m."id" DESC
    LIMIT $9
) c;

PREPARE g_topic_walk(timestamp, text, bigint) AS
SELECT COALESCE(array_agg(c.id ORDER BY c."publishedAt" DESC NULLS LAST, c.id DESC), '{}')::text AS ids, count(*) AS n
FROM (
    SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt"
    FROM "news_articles" na
    WHERE (na."status" = 'GOOD' AND na."publishedAt" >= $1)
      AND EXISTS (
        SELECT 1 FROM "news_ai_analysis" a
        WHERE a."articleId" = na.id AND ((
            COALESCE(a."topTopics"::text, '') ILIKE $2
            OR COALESCE(a."trendingKeywords"::text, '') ILIKE $2
        ))
    )
    ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
    LIMIT $3
) c;

PREPARE g_topic_fence(timestamp, text, bigint) AS
SELECT COALESCE(array_agg(c.id ORDER BY c."publishedAt" DESC NULLS LAST, c.id DESC), '{}')::text AS ids, count(*) AS n
FROM (
    SELECT m.id, m."sourceId", m."publishedAt"
    FROM (
        SELECT na.id, na."sourceId" AS "sourceId", na."publishedAt"
        FROM "news_articles" na
        WHERE (na."status" = 'GOOD' AND na."publishedAt" >= $1)
          AND EXISTS (
        SELECT 1 FROM "news_ai_analysis" a
        WHERE a."articleId" = na.id AND ((
            COALESCE(a."topTopics"::text, '') ILIKE $2
            OR COALESCE(a."trendingKeywords"::text, '') ILIKE $2
        ))
    )
        OFFSET 0
    ) m
    ORDER BY m."publishedAt" DESC NULLS LAST, m.id DESC
    LIMIT $3
) c;

\echo '=== G1 search-panel candidates, ঢাকা 24 h: g_panel_fence first, then g_panel_walk, then both again (warm) ==='
\echo '--- G1 ঢাকা 24 h: g_panel_fence (run 1)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_panel_fence(now() - interval '24 hours', now(), '%ঢাকা%', :'trim_chars', 'ঢাকা', '%ঢাকা%', 'ঢাকা', '%ঢাকা%', 500);
\echo '--- G1 ঢাকা 24 h: g_panel_walk (run 1)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_panel_walk(now() - interval '24 hours', now(), '%ঢাকা%', :'trim_chars', 'ঢাকা', '%ঢাকা%', 'ঢাকা', '%ঢাকা%', 500);
\echo '--- G1 ঢাকা 24 h: g_panel_fence (run 2)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_panel_fence(now() - interval '24 hours', now(), '%ঢাকা%', :'trim_chars', 'ঢাকা', '%ঢাকা%', 'ঢাকা', '%ঢাকা%', 500);
\echo '--- G1 ঢাকা 24 h: g_panel_walk (run 2)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_panel_walk(now() - interval '24 hours', now(), '%ঢাকা%', :'trim_chars', 'ঢাকা', '%ঢাকা%', 'ঢাকা', '%ঢাকা%', 500);
\set a_ids 'not-run-a'
\set b_ids 'not-run-b'
\set a_n -1
\set b_n -1
EXECUTE g_panel_fence(now() - interval '24 hours', now(), '%ঢাকা%', :'trim_chars', 'ঢাকা', '%ঢাকা%', 'ঢাকা', '%ঢাকা%', 500) \gset a_
EXECUTE g_panel_walk(now() - interval '24 hours', now(), '%ঢাকা%', :'trim_chars', 'ঢাকা', '%ঢাকা%', 'ঢাকা', '%ঢাকা%', 500) \gset b_
SELECT 'ঢাকা 24 h' AS g1_case, :a_n AS g_panel_fence_rows, :b_n AS g_panel_walk_rows, (:'a_ids' = :'b_ids') AS identical_rows_in_order;

\echo '=== G1 search-panel candidates, election 24 h: g_panel_fence first, then g_panel_walk, then both again (warm) ==='
\echo '--- G1 election 24 h: g_panel_fence (run 1)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_panel_fence(now() - interval '24 hours', now(), '%election%', :'trim_chars', 'election', '%election%', 'election', '%election%', 500);
\echo '--- G1 election 24 h: g_panel_walk (run 1)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_panel_walk(now() - interval '24 hours', now(), '%election%', :'trim_chars', 'election', '%election%', 'election', '%election%', 500);
\echo '--- G1 election 24 h: g_panel_fence (run 2)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_panel_fence(now() - interval '24 hours', now(), '%election%', :'trim_chars', 'election', '%election%', 'election', '%election%', 500);
\echo '--- G1 election 24 h: g_panel_walk (run 2)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_panel_walk(now() - interval '24 hours', now(), '%election%', :'trim_chars', 'election', '%election%', 'election', '%election%', 500);
\set a_ids 'not-run-a'
\set b_ids 'not-run-b'
\set a_n -1
\set b_n -1
EXECUTE g_panel_fence(now() - interval '24 hours', now(), '%election%', :'trim_chars', 'election', '%election%', 'election', '%election%', 500) \gset a_
EXECUTE g_panel_walk(now() - interval '24 hours', now(), '%election%', :'trim_chars', 'election', '%election%', 'election', '%election%', 500) \gset b_
SELECT 'election 24 h' AS g1_case, :a_n AS g_panel_fence_rows, :b_n AS g_panel_walk_rows, (:'a_ids' = :'b_ids') AS identical_rows_in_order;

\echo '=== G1t search-panel search_tsv stream alone, ঢাকা 24 h ==='
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_tsv_fence(now() - interval '24 hours', now(), '%ঢাকা%', :'trim_chars', 'ঢাকা', '%ঢাকা%', 'ঢাকা', '%ঢাকা%', 500);
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_tsv_walk(now() - interval '24 hours', now(), '%ঢাকা%', :'trim_chars', 'ঢাকা', '%ঢাকা%', 'ঢাকা', '%ঢাকা%', 500);

\echo '=== G2 topic search tier 1000, ঢাকা 90 d, K = 80: g_topic_fence first, then g_topic_walk, then both again (warm) ==='
SELECT ((now() AT TIME ZONE 'Asia/Dhaka') - interval '90 days')::timestamp(3) AS g_from \gset
\echo '--- G2 ঢাকা 90 d: g_topic_fence (run 1)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_topic_fence(:'g_from', '%ঢাকা%', 80);
\echo '--- G2 ঢাকা 90 d: g_topic_walk (run 1)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_topic_walk(:'g_from', '%ঢাকা%', 80);
\echo '--- G2 ঢাকা 90 d: g_topic_fence (run 2)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_topic_fence(:'g_from', '%ঢাকা%', 80);
\echo '--- G2 ঢাকা 90 d: g_topic_walk (run 2)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_topic_walk(:'g_from', '%ঢাকা%', 80);
\set a_ids 'not-run-a'
\set b_ids 'not-run-b'
\set a_n -1
\set b_n -1
EXECUTE g_topic_fence(:'g_from', '%ঢাকা%', 80) \gset a_
EXECUTE g_topic_walk(:'g_from', '%ঢাকা%', 80) \gset b_
SELECT 'ঢাকা 90 d' AS g2_case, :a_n AS g_topic_fence_rows, :b_n AS g_topic_walk_rows, (:'a_ids' = :'b_ids') AS identical_rows_in_order;

\echo '=== G2 topic search tier 1000, ঢাকা 24 h, K = 80: g_topic_fence first, then g_topic_walk, then both again (warm) ==='
SELECT ((now() AT TIME ZONE 'Asia/Dhaka') - interval '24 hours')::timestamp(3) AS g_from \gset
\echo '--- G2 ঢাকা 24 h: g_topic_fence (run 1)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_topic_fence(:'g_from', '%ঢাকা%', 80);
\echo '--- G2 ঢাকা 24 h: g_topic_walk (run 1)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_topic_walk(:'g_from', '%ঢাকা%', 80);
\echo '--- G2 ঢাকা 24 h: g_topic_fence (run 2)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_topic_fence(:'g_from', '%ঢাকা%', 80);
\echo '--- G2 ঢাকা 24 h: g_topic_walk (run 2)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_topic_walk(:'g_from', '%ঢাকা%', 80);
\set a_ids 'not-run-a'
\set b_ids 'not-run-b'
\set a_n -1
\set b_n -1
EXECUTE g_topic_fence(:'g_from', '%ঢাকা%', 80) \gset a_
EXECUTE g_topic_walk(:'g_from', '%ঢাকা%', 80) \gset b_
SELECT 'ঢাকা 24 h' AS g2_case, :a_n AS g_topic_fence_rows, :b_n AS g_topic_walk_rows, (:'a_ids' = :'b_ids') AS identical_rows_in_order;

\echo '=== G2 topic search tier 1000, election 90 d, K = 80: g_topic_fence first, then g_topic_walk, then both again (warm) ==='
SELECT ((now() AT TIME ZONE 'Asia/Dhaka') - interval '90 days')::timestamp(3) AS g_from \gset
\echo '--- G2 election 90 d: g_topic_fence (run 1)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_topic_fence(:'g_from', '%election%', 80);
\echo '--- G2 election 90 d: g_topic_walk (run 1)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_topic_walk(:'g_from', '%election%', 80);
\echo '--- G2 election 90 d: g_topic_fence (run 2)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_topic_fence(:'g_from', '%election%', 80);
\echo '--- G2 election 90 d: g_topic_walk (run 2)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE g_topic_walk(:'g_from', '%election%', 80);
\set a_ids 'not-run-a'
\set b_ids 'not-run-b'
\set a_n -1
\set b_n -1
EXECUTE g_topic_fence(:'g_from', '%election%', 80) \gset a_
EXECUTE g_topic_walk(:'g_from', '%election%', 80) \gset b_
SELECT 'election 90 d' AS g2_case, :a_n AS g_topic_fence_rows, :b_n AS g_topic_walk_rows, (:'a_ids' = :'b_ids') AS identical_rows_in_order;

\echo '--- G3. how many tier-1000 matches the bitmap path must read (all time vs in the 90-day window)'
SELECT count(*) AS dhaka_topic_matches_all_time,
       count(*) FILTER (WHERE na."status" = 'GOOD' AND na."publishedAt" >= ((now() AT TIME ZONE 'Asia/Dhaka') - interval '90 days')::timestamp(3)) AS dhaka_topic_matches_90d
FROM "news_ai_analysis" a
LEFT JOIN "news_articles" na ON na.id = a."articleId"
WHERE COALESCE(a."topTopics"::text, '') ILIKE '%ঢাকা%'
   OR COALESCE(a."trendingKeywords"::text, '') ILIKE '%ঢাকা%';
DEALLOCATE ALL;
RESET TIME ZONE;
\timing off

\echo '############ E. news/search-panel-cache build: EVERY statement, EXPLAIN (ANALYZE, BUFFERS), default /news request ############'
-- ---------------------------------------------------------------------------
-- E: why GET /api/core/news/search-panel-cache answers 504 DEADLINE_EXCEEDED
-- at 8.0-8.9 s for every term (alpha, frontend-baseline §12). STAGE ONLY.
--
-- Run on its own (read-only session, 30 s per statement) with the sed
-- command in the header of this file. (It is not repeated here: this
-- section must not contain the sed range's end marker.)
--
-- The request. web/src/pages/news/Index.tsx (panelSearchCacheQuery) only
-- sends it when a category, a session or an AI topic keyword is selected. A
-- typed search is in "topic" mode by default (qMode), which clears the
-- category and sets the AI topic keyword to the typed term, so the default is
--   ?aiKeyword=<term>&search=<term>
-- with NO startDate/endDate (articleListStartDate is undefined unless the
-- analyst picks dates or scrubs the timeline) -> the service's rolling 24 h
-- window; no sources, no category; status GOOD (the default mode); cap 500.
--
-- The 8 s is ONE statement hitting its statement_timeout: runSearchPanelReads
-- sets statement_timeout = 8000 ms inside a transaction whose own timeout is
-- 9000 ms, so a P2028 transaction timeout would surface at >= 9 s and a pool
-- wait (maxWait) at ~2 s. 8.0-8.9 s = a statement that started within the
-- first 0.9 s of the request and ran 8 s.
--
-- The statements, in the app's order (news-analytics.service.ts):
--   E1  statusMode       system_conf lookup (cached 10 s in-process)
--   E2  cacheLookup      news_search_panel_cache by "cacheKey"
--       -- read-only transaction: SET TRANSACTION READ ONLY; set_config(statement_timeout, 8000)
--   E3  allKeywords      the WHOLE keywords table ORDER BY priority, keyword + its
--                        categories. REMOVED by the commit that adds this
--                        section: term-independent, unbounded (AI analysis adds
--                        a keyword row per new topic) and only used for a
--                        fallback category name. Measured here to confirm it.
--   E4  candidates       buildSearchPanelCandidateSql (3 LIMITed streams + the
--                        aiKeyword pre-filter on every stream; section D left
--                        the pre-filter out). Run as a PREPAREd statement, the
--                        way Prisma runs it: once with a custom plan (what
--                        EXPLAIN with literals shows) and once with the generic
--                        plan (what a connection may switch to after 5
--                        executions of the same statement text).
--   E5  latestAnalyses   news_ai_analysis for the candidate ids (Prisma sends
--                        IN ($1..$n); = ANY($1) plans the same way)
--       (the exact aiKeyword filter runs in JS; emulated here only to get the ids)
--   E6  keywordCounts    news_article_keywords GROUP BY "keywordId"
--   E7  keywordDetails   keywords by id + their categories (two statements)
--       -- COMMIT
--   E8  upsert           news_search_panel_cache: plain EXPLAIN only (a write)
-- The first EXPLAIN ANALYZE of a statement is the cold one; the EXECUTE
-- \gset that follows it re-runs it only to capture ids for the next step.
-- Timestamps: TimeZone is set to UTC so a timestamptz parameter and the
-- UTC-stored timestamp(3) columns compare the way Prisma's do.
-- ---------------------------------------------------------------------------
\set ON_ERROR_STOP off
SET statement_timeout = '30s';
SET lock_timeout = '2s';
SET default_transaction_read_only = on;
SET application_name = 'falcon-diagnose-search-panel';
SET TIME ZONE 'UTC';
\timing on

\echo '--- E0. sizes: rows the term-independent statements touch, and the 24 h window a rare term walks'
SELECT relname, n_live_tup, pg_size_pretty(pg_total_relation_size(relid)) AS total_size, last_autoanalyze
FROM pg_stat_user_tables
WHERE relname IN ('keywords', 'keyword_categories', 'news_article_keywords', 'news_search_panel_cache', 'news_articles', 'news_ai_analysis')
ORDER BY relname;
SELECT count(*) AS keywords_total,
       count(*) FILTER (WHERE "type"::text = 'AI_GENERATED') AS keywords_ai_generated
FROM "keywords";
SELECT count(*) AS good_articles_last_24h
FROM "news_articles" na
WHERE na."status" = 'GOOD' AND na."publishedAt" >= now() - interval '24 hours' AND na."publishedAt" <= now();

\echo '--- E1. statusMode (system_conf)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT "key", "value", "updatedAt" FROM "system_conf"
WHERE "key" = 'technical_panel.internal_ai.news_article_status_filter_mode' LIMIT 1 OFFSET 0;

\echo '--- E2. cacheLookup (news_search_panel_cache by cacheKey)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM "news_search_panel_cache" WHERE "cacheKey" = 'diagnose-search-nonexistent-key' LIMIT 1 OFFSET 0;

\echo '--- E3. allKeywords (REMOVED from the build; before/after evidence). EXPLAIN ANALYZE does not ship rows to a client: the plain SELECT after it shows the volume the app received.'
EXPLAIN (ANALYZE, BUFFERS)
SELECT "id", "keyword", "categoryId" FROM "keywords"
ORDER BY "priority" ASC, "keyword" ASC OFFSET 0;
EXPLAIN (ANALYZE, BUFFERS)
SELECT "id", "name" FROM "keyword_categories"
WHERE "id" IN (SELECT DISTINCT "categoryId" FROM "keywords") OFFSET 0;
SELECT count(*) AS rows_sent_to_app,
       pg_size_pretty(sum(pg_column_size(k.*))::bigint) AS approx_bytes
FROM (SELECT "id", "keyword", "categoryId" FROM "keywords" ORDER BY "priority" ASC, "keyword" ASC) k;

-- E4: the candidate statement, as Prisma sends it (parameters, not literals).
-- $1 window start, $2 window end, $3 aiKeyword pattern, $4 title pattern,
-- $5 search text (websearch_to_tsquery), $6 analysis pattern, $7 cap.
-- Wrapped in array_agg only to hand the ids to E5 (\gset); the LIMITed
-- subquery is not flattened, so its plan is the app's plan.
DEALLOCATE ALL;
PREPARE e_candidate_ids(timestamptz, timestamptz, text, text, text, text, bigint) AS
SELECT COALESCE(array_agg(c."id"), '{}')::text AS cand, count(*) AS cand_n
FROM (
SELECT u."id", u."publishedAt"
FROM ((
    SELECT na."id", na."publishedAt"
    FROM "news_articles" na
    WHERE (na."status" = 'GOOD' AND na."publishedAt" >= $1 AND na."publishedAt" <= $2 AND EXISTS (
                SELECT 1 FROM "news_ai_analysis" a
                WHERE a."articleId" = na.id
                  AND COALESCE(a."trendingKeywords"::text, '') ILIKE $3
            )) AND na."title" ILIKE $4
    ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC
    LIMIT $7
) UNION (
    SELECT na."id", na."publishedAt"
    FROM "news_articles" na
    WHERE (na."status" = 'GOOD' AND na."publishedAt" >= $1 AND na."publishedAt" <= $2 AND EXISTS (
                SELECT 1 FROM "news_ai_analysis" a
                WHERE a."articleId" = na.id
                  AND COALESCE(a."trendingKeywords"::text, '') ILIKE $3
            )) AND (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', $5))
    ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC
    LIMIT $7
) UNION (
    SELECT na."id", na."publishedAt"
    FROM "news_articles" na
    WHERE (na."status" = 'GOOD' AND na."publishedAt" >= $1 AND na."publishedAt" <= $2 AND EXISTS (
                SELECT 1 FROM "news_ai_analysis" a
                WHERE a."articleId" = na.id
                  AND COALESCE(a."trendingKeywords"::text, '') ILIKE $3
            )) AND EXISTS (
                SELECT 1 FROM "news_ai_analysis" a
                WHERE a."articleId" = na.id
                  AND (
                    ((
                COALESCE(a."trendingKeywords"::text, '') ILIKE $6
                OR COALESCE(a."topTopics"::text, '') ILIKE $6
                OR COALESCE(a."summary", '') ILIKE $6
                OR COALESCE(a."what_happened", '') ILIKE $6
                OR COALESCE(a."where_happened", '') ILIKE $6
                OR COALESCE(a."who_involved", '') ILIKE $6
                OR COALESCE(a."between_whom", '') ILIKE $6
                OR COALESCE(a."why_happened", '') ILIKE $6
                OR COALESCE(a."root_cause", '') ILIKE $6
                OR COALESCE(a."what_impact", '') ILIKE $6
                OR COALESCE(a."future_implication", '') ILIKE $6
            ))
                    OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', $5))
                  )
            )
    ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC
    LIMIT $7
)) u
ORDER BY u."publishedAt" DESC NULLS LAST, u."id" DESC
LIMIT $7
) c;

PREPARE e_latest(text[]) AS
SELECT "articleId", "lastAnalyzedAt", "trendingKeywords" FROM "news_ai_analysis"
WHERE "articleId" = ANY($1)
ORDER BY "articleId" ASC, "lastAnalyzedAt" DESC OFFSET 0;

-- Not an app statement: emulates the in-JS exact aiKeyword filter
-- (parseTrendingKeywords: keyword || text || label, trimmed, lower-cased).
PREPARE e_filtered_ids(text[], text) AS
SELECT COALESCE(array_agg(l."articleId"), '{}')::text AS filtered, count(*) AS filtered_n
FROM (
    SELECT DISTINCT ON (a."articleId") a."articleId", a."trendingKeywords"
    FROM "news_ai_analysis" a
    WHERE a."articleId" = ANY($1)
    ORDER BY a."articleId", a."lastAnalyzedAt" DESC
) l
WHERE $2 = '' OR (jsonb_typeof(l."trendingKeywords") = 'array' AND EXISTS (
    SELECT 1 FROM jsonb_array_elements(l."trendingKeywords") e
    WHERE jsonb_typeof(e) = 'object'
      AND lower(btrim(COALESCE(NULLIF(e->>'keyword', ''), NULLIF(e->>'text', ''), e->>'label', ''))) = $2
));

PREPARE e_keyword_counts(text[]) AS
SELECT COUNT("keywordId"), "keywordId" FROM "news_article_keywords"
WHERE "newsArticleId" = ANY($1)
GROUP BY "keywordId" OFFSET 0;

-- Not an app statement: hands the keyword ids to E7.
PREPARE e_keyword_ids(text[]) AS
SELECT COALESCE(array_agg(DISTINCT "keywordId"), '{}')::text AS kw, count(DISTINCT "keywordId") AS kw_n
FROM "news_article_keywords" WHERE "newsArticleId" = ANY($1);

PREPARE e_keyword_details(text[]) AS
SELECT "id", "keyword", "categoryId" FROM "keywords" WHERE "id" = ANY($1) OFFSET 0;

PREPARE e_keyword_categories(text[]) AS
SELECT "id", "name" FROM "keyword_categories"
WHERE "id" IN (SELECT "categoryId" FROM "keywords" WHERE "id" = ANY($1)) OFFSET 0;

\echo '=== E term: election (rare in 24 h) ==='
\set term 'election'
\set like '%election%'
\set cand '{}'
\set cand_n 0
\set filtered '{}'
\set filtered_n 0
\set kw '{}'
\set kw_n 0
\echo '--- E4 candidates, custom plan'
SET plan_cache_mode = force_custom_plan;
EXPLAIN (ANALYZE, BUFFERS) EXECUTE e_candidate_ids(now() - interval '24 hours', now(), :'like', :'like', :'term', :'like', 500);
\echo '--- E4g candidates, GENERIC plan (a reused Prisma prepared statement)'
SET plan_cache_mode = force_generic_plan;
EXPLAIN (ANALYZE, BUFFERS) EXECUTE e_candidate_ids(now() - interval '24 hours', now(), :'like', :'like', :'term', :'like', 500);
RESET plan_cache_mode;
EXECUTE e_candidate_ids(now() - interval '24 hours', now(), :'like', :'like', :'term', :'like', 500) \gset
\echo 'candidates:' :cand_n
\echo '--- E5 latestAnalyses'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE e_latest(:'cand'::text[]);
EXECUTE e_filtered_ids(:'cand'::text[], :'term') \gset
\echo 'after the exact aiKeyword filter:' :filtered_n
\echo '--- E6 keywordCounts'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE e_keyword_counts(:'filtered'::text[]);
EXECUTE e_keyword_ids(:'filtered'::text[]) \gset
\echo 'matched keywords:' :kw_n
\echo '--- E7 keywordDetails (keywords, then their categories)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE e_keyword_details(:'kw'::text[]);
EXPLAIN (ANALYZE, BUFFERS) EXECUTE e_keyword_categories(:'kw'::text[]);

\echo '=== E term: ঢাকা (common) ==='
\set term 'ঢাকা'
\set like '%ঢাকা%'
\set cand '{}'
\set cand_n 0
\set filtered '{}'
\set filtered_n 0
\set kw '{}'
\set kw_n 0
\echo '--- E4 candidates, custom plan'
SET plan_cache_mode = force_custom_plan;
EXPLAIN (ANALYZE, BUFFERS) EXECUTE e_candidate_ids(now() - interval '24 hours', now(), :'like', :'like', :'term', :'like', 500);
\echo '--- E4g candidates, GENERIC plan (a reused Prisma prepared statement)'
SET plan_cache_mode = force_generic_plan;
EXPLAIN (ANALYZE, BUFFERS) EXECUTE e_candidate_ids(now() - interval '24 hours', now(), :'like', :'like', :'term', :'like', 500);
RESET plan_cache_mode;
EXECUTE e_candidate_ids(now() - interval '24 hours', now(), :'like', :'like', :'term', :'like', 500) \gset
\echo 'candidates:' :cand_n
\echo '--- E5 latestAnalyses'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE e_latest(:'cand'::text[]);
EXECUTE e_filtered_ids(:'cand'::text[], :'term') \gset
\echo 'after the exact aiKeyword filter:' :filtered_n
\echo '--- E6 keywordCounts'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE e_keyword_counts(:'filtered'::text[]);
EXECUTE e_keyword_ids(:'filtered'::text[]) \gset
\echo 'matched keywords:' :kw_n
\echo '--- E7 keywordDetails (keywords, then their categories)'
EXPLAIN (ANALYZE, BUFFERS) EXECUTE e_keyword_details(:'kw'::text[]);
EXPLAIN (ANALYZE, BUFFERS) EXECUTE e_keyword_categories(:'kw'::text[]);

\echo '--- E8 upsert: plain EXPLAIN (plans only, writes nothing; runs outside the read-only transaction in the app)'
EXPLAIN
INSERT INTO "news_search_panel_cache"
    ("id", "cacheKey", "keywordCategoryId", "campaignId", "searchQuery", "sourcesKey", "startDate", "endDate",
     "articleCount", "dbKeywordRows", "aiKeywordRows", "lastBuiltAt", "expiresAt", "createdAt", "updatedAt")
VALUES ('diagnose', 'diagnose-search-nonexistent-key', '', NULL, NULL, NULL, '', '',
        0, '[]'::jsonb, '[]'::jsonb, now(), now(), now(), now())
ON CONFLICT ("cacheKey") DO UPDATE SET
    "articleCount" = EXCLUDED."articleCount", "dbKeywordRows" = EXCLUDED."dbKeywordRows",
    "aiKeywordRows" = EXCLUDED."aiKeywordRows", "lastBuiltAt" = EXCLUDED."lastBuiltAt",
    "expiresAt" = EXCLUDED."expiresAt", "updatedAt" = EXCLUDED."updatedAt";
DEALLOCATE ALL;
RESET TIME ZONE;

\timing off
\echo '############ F. news/search-panel-cache: ORIGINAL vs CURRENT semantics, counted on real data (typed topic search, 24 h) ############'
-- ---------------------------------------------------------------------------
-- F: alpha §12.3 found search-panel-cache EMPTY (articleCount 0, no keyword
-- rows) for election / ঢাকা / নির্বাচন. Is empty the original answer or a
-- regression? STAGE ONLY. Read-only; plain SELECTs, no EXPLAIN. The ORIGINAL
-- shape ILIKEs article bodies and raw pages of the window on purpose (that is
-- what is being compared), so this section takes a while; 120 s per statement.
--
-- Run on its own with the sed command in the header of this file (range
-- "F." to the end marker).
--
-- Request: ?aiKeyword=<term>&search=<term>, no dates -> rolling 24 h, GOOD.
-- The exact rule (unchanged since before the perf work): the article's
-- LATEST analysis (by lastAnalyzedAt) has a trendingKeywords element whose
-- keyword || text || label, trimmed (JS trim) and lower-cased, EQUALS the
-- term trimmed and lower-cased. articleCount = rows that pass it.
--
-- Columns of F2 (one row per term):
--   orig_*      ORIGINAL (pre-9e4b9b920) build: createdAt window; title /
--               content / scrape_results.title / rawContent ILIKE %term%; no
--               cap; then the exact rule. orig_exact = its articleCount.
--   deployed_*  dc26959b6 (alpha §12.3): publishedAt window; 3 streams (title
--               ILIKE, search_tsv, analysis fields), each ANDed with the
--               trendingKeywords::text ILIKE %NFKC(term)% pre-filter, each
--               LIMIT 500, union LIMIT 500; then the exact rule.
--   fixed_*     this commit: as deployed, but the pre-filter is the raw
--               lower-cased term AND the exact element test, so the cap is
--               applied after the exact rule (on any analysis); the code then
--               re-checks the latest analysis. fixed_exact = its articleCount.
--   exact_pub_window / exact_created_window: articles in each 24 h window
--               whose latest analysis passes the exact rule, whatever the text
--               match (the ceiling any search shape can reach).
--   contains_pub_window: latest analysis has a keyword that merely CONTAINS
--               the term ("Election Commission" for election).
--   orig_exact_not_in_fixed: rows the original counted that this commit does
--               not (window move createdAt -> publishedAt, or no stream match).
-- F1 checks the stored JSON shape; F3 lists, per term, the keywords that
-- contain it, which is what the AI actually tagged.
-- ---------------------------------------------------------------------------
\set ON_ERROR_STOP off
SET statement_timeout = '120s';
SET lock_timeout = '2s';
SET default_transaction_read_only = on;
SET application_name = 'falcon-diagnose-search-panel-semantics';
SET TIME ZONE 'UTC';
\timing on

\echo '--- F1. trendingKeywords shape: latest analyses of GOOD articles published in the last 24 h'
WITH latest AS (
    SELECT DISTINCT ON (a."articleId") a."trendingKeywords" AS tk
    FROM "news_ai_analysis" a
    JOIN "news_articles" na ON na.id = a."articleId"
    WHERE na."status" = 'GOOD'
      AND na."publishedAt" >= now() - interval '24 hours' AND na."publishedAt" <= now()
    ORDER BY a."articleId", a."lastAnalyzedAt" DESC
)
SELECT COALESCE(jsonb_typeof(l.tk), 'NULL') AS column_type,
       COALESCE(jsonb_typeof(e), '-') AS element_type,
       (e ? 'keyword') AS has_keyword, (e ? 'text') AS has_text, (e ? 'label') AS has_label,
       count(*) AS n
FROM latest l
LEFT JOIN LATERAL jsonb_array_elements(
    CASE WHEN jsonb_typeof(l.tk) = 'array' THEN l.tk ELSE '[]'::jsonb END
) e ON TRUE
GROUP BY 1, 2, 3, 4, 5
ORDER BY n DESC;

\echo '--- F2. per term: ORIGINAL vs DEPLOYED (dc26959b6) vs FIXED (this commit), same 24 h'
WITH
params AS MATERIALIZED (
    SELECT now() - interval '24 hours' AS ws, now() AS we,
           -- what String.prototype.trim() strips
           (SELECT string_agg(chr(c), '') FROM unnest(ARRAY[
               9, 10, 11, 12, 13, 32, 160, 5760, 8192, 8193, 8194, 8195, 8196, 8197, 8198,
               8199, 8200, 8201, 8202, 8232, 8233, 8239, 8287, 12288, 65279]) c) AS trim_chars
),
-- GOOD articles in EITHER 24 h window (createdAt for the original, publishedAt now).
-- createdAt has no index: this is one sequential scan of news_articles.
win AS MATERIALIZED (
    SELECT na.id, na.title, na.content, na."scrapeResultId", na."createdAt", na."publishedAt", na."search_tsv"
    FROM "news_articles" na, params p
    WHERE na."status" = 'GOOD'
      AND ((na."createdAt" >= p.ws AND na."createdAt" <= p.we)
        OR (na."publishedAt" >= p.ws AND na."publishedAt" <= p.we))
),
latest_kw AS MATERIALIZED (
    SELECT l."articleId",
           lower(btrim(COALESCE(NULLIF(e->>'keyword', ''), NULLIF(e->>'text', ''), e->>'label', ''), p.trim_chars)) AS key
    FROM (
        SELECT DISTINCT ON (a."articleId") a."articleId", a."trendingKeywords" AS tk
        FROM "news_ai_analysis" a
        WHERE a."articleId" IN (SELECT id FROM win)
        ORDER BY a."articleId", a."lastAnalyzedAt" DESC
    ) l
    CROSS JOIN params p
    CROSS JOIN LATERAL jsonb_array_elements(
        CASE WHEN jsonb_typeof(l.tk) = 'array' THEN l.tk ELSE '[]'::jsonb END
    ) e
    WHERE jsonb_typeof(e) = 'object'
),
top_kw AS (
    SELECT k.key
    FROM latest_kw k JOIN win w ON w.id = k."articleId", params p
    WHERE k.key <> '' AND w."publishedAt" >= p.ws AND w."publishedAt" <= p.we
    GROUP BY k.key
    ORDER BY count(DISTINCT k."articleId") DESC, k.key
    LIMIT 1
),
raw_terms AS (
    SELECT * FROM (VALUES (1, 'election', 'election'), (2, 'ঢাকা', 'ঢাকা'), (3, 'নির্বাচন', 'নির্বাচন')) v(ord, label, term)
    UNION ALL
    SELECT 4, 'top trendingKeyword (24 h)', key FROM top_kw
),
terms AS (
    SELECT r.ord, r.label, btrim(r.term) AS term,
           lower(btrim(r.term, p.trim_chars)) AS key,
           -- normalizeTopicKey(): NFKC, trimmed, single-spaced, lower-cased
           lower(regexp_replace(btrim(normalize(r.term, NFKC)), '\s+', ' ', 'g')) AS nkey
    FROM raw_terms r CROSS JOIN params p
),
t2 AS (
    SELECT t.*,
           '%' || replace(replace(replace(t.term, '\', '\\'), '%', '\%'), '_', '\_') || '%' AS like_term,
           '%' || replace(replace(replace(t.key, '\', '\\'), '%', '\%'), '_', '\_') || '%' AS like_key,
           '%' || replace(replace(replace(t.nkey, '\', '\\'), '%', '\%'), '_', '\_') || '%' AS like_nkey,
           (t.nkey !~ '["\\]') AS pre_d_on,
           (t.key !~ '["\\\x01-\x1f]') AS pre_f_on,
           (length(t.nkey) >= 2) AS an_like_on
    FROM terms t
),
-- the ORIGINAL candidates (each row once per term), flagged with the exact rule
orig_rows AS MATERIALIZED (
    SELECT t.ord, w.id,
           EXISTS (SELECT 1 FROM latest_kw k WHERE k."articleId" = w.id AND k.key = t.key) AS exact
    FROM t2 t
    CROSS JOIN params p
    JOIN win w ON w."createdAt" >= p.ws AND w."createdAt" <= p.we
    LEFT JOIN "scrape_results" sr ON sr.id = w."scrapeResultId"
    WHERE w.title ILIKE t.like_term
       OR w.content ILIKE t.like_term
       OR sr.title ILIKE t.like_term
       OR sr."rawContent" ILIKE t.like_term
),
orig AS (
    SELECT o.ord, count(*) AS orig_candidates, count(*) FILTER (WHERE o.exact) AS orig_exact
    FROM orig_rows o
    GROUP BY o.ord
),
-- publishedAt window rows with each stream / pre-filter as a flag
base AS MATERIALIZED (
    SELECT t.ord, w.id, w."publishedAt",
           (w.title ILIKE t.like_term) AS s1,
           (w."search_tsv" IS NOT NULL AND w."search_tsv" @@ websearch_to_tsquery('simple', t.term)) AS s2,
           EXISTS (
               SELECT 1 FROM "news_ai_analysis" a
               WHERE a."articleId" = w.id
                 AND ((t.an_like_on AND (
                        COALESCE(a."trendingKeywords"::text, '') ILIKE t.like_nkey
                     OR COALESCE(a."topTopics"::text, '') ILIKE t.like_nkey
                     OR COALESCE(a."summary", '') ILIKE t.like_nkey
                     OR COALESCE(a."what_happened", '') ILIKE t.like_nkey
                     OR COALESCE(a."where_happened", '') ILIKE t.like_nkey
                     OR COALESCE(a."who_involved", '') ILIKE t.like_nkey
                     OR COALESCE(a."between_whom", '') ILIKE t.like_nkey
                     OR COALESCE(a."why_happened", '') ILIKE t.like_nkey
                     OR COALESCE(a."root_cause", '') ILIKE t.like_nkey
                     OR COALESCE(a."what_impact", '') ILIKE t.like_nkey
                     OR COALESCE(a."future_implication", '') ILIKE t.like_nkey))
                   OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', t.term)))
           ) AS s3,
           (NOT t.pre_d_on OR EXISTS (
               SELECT 1 FROM "news_ai_analysis" a
               WHERE a."articleId" = w.id
                 AND COALESCE(a."trendingKeywords"::text, '') ILIKE t.like_nkey)) AS pre_d,
           (NOT t.pre_f_on OR EXISTS (
               SELECT 1 FROM "news_ai_analysis" a
               CROSS JOIN LATERAL jsonb_array_elements(
                   CASE WHEN jsonb_typeof(a."trendingKeywords") = 'array'
                        THEN a."trendingKeywords" ELSE '[]'::jsonb END) e
               WHERE a."articleId" = w.id
                 AND COALESCE(a."trendingKeywords"::text, '') ILIKE t.like_key
                 AND jsonb_typeof(e) = 'object'
                 AND lower(btrim(COALESCE(NULLIF(e->>'keyword', ''), NULLIF(e->>'text', ''), e->>'label', ''), p.trim_chars)) = t.key)) AS pre_f,
           EXISTS (SELECT 1 FROM latest_kw k WHERE k."articleId" = w.id AND k.key = t.key) AS exact,
           EXISTS (SELECT 1 FROM latest_kw k WHERE k."articleId" = w.id AND strpos(k.key, t.key) > 0) AS kw_contains
    FROM t2 t
    CROSS JOIN params p
    JOIN win w ON w."publishedAt" >= p.ws AND w."publishedAt" <= p.we
),
-- each stream keeps its newest 500 (ORDER BY publishedAt DESC, id DESC)
ranked AS (
    SELECT b.*,
           count(*) FILTER (WHERE b.pre_d AND b.s1) OVER o AS d1,
           count(*) FILTER (WHERE b.pre_d AND b.s2) OVER o AS d2,
           count(*) FILTER (WHERE b.pre_d AND b.s3) OVER o AS d3,
           count(*) FILTER (WHERE b.pre_f AND b.s1) OVER o AS f1,
           count(*) FILTER (WHERE b.pre_f AND b.s2) OVER o AS f2,
           count(*) FILTER (WHERE b.pre_f AND b.s3) OVER o AS f3
    FROM base b
    WINDOW o AS (PARTITION BY b.ord ORDER BY b."publishedAt" DESC NULLS LAST, b.id DESC
                 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
),
unioned AS (
    SELECT r.*,
           ((r.pre_d AND r.s1 AND r.d1 <= 500) OR (r.pre_d AND r.s2 AND r.d2 <= 500)
             OR (r.pre_d AND r.s3 AND r.d3 <= 500)) AS in_d,
           ((r.pre_f AND r.s1 AND r.f1 <= 500) OR (r.pre_f AND r.s2 AND r.f2 <= 500)
             OR (r.pre_f AND r.s3 AND r.f3 <= 500)) AS in_f
    FROM ranked r
),
-- then the union keeps its newest 500
capped AS (
    SELECT u.*,
           count(*) FILTER (WHERE u.in_d) OVER o AS dn,
           count(*) FILTER (WHERE u.in_f) OVER o AS fn
    FROM unioned u
    WINDOW o AS (PARTITION BY u.ord ORDER BY u."publishedAt" DESC NULLS LAST, u.id DESC
                 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
),
cur AS (
    SELECT c.ord,
           count(*) FILTER (WHERE c.in_d AND c.dn <= 500) AS deployed_candidates,
           count(*) FILTER (WHERE c.in_d AND c.dn <= 500 AND c.exact) AS deployed_exact,
           count(*) FILTER (WHERE c.in_f AND c.fn <= 500) AS fixed_candidates,
           count(*) FILTER (WHERE c.in_f AND c.fn <= 500 AND c.exact) AS fixed_exact,
           count(*) FILTER (WHERE c.exact) AS exact_pub_window,
           count(*) FILTER (WHERE c.kw_contains) AS contains_pub_window,
           array_agg(c.id) FILTER (WHERE c.in_f AND c.fn <= 500 AND c.exact) AS fixed_ids
    FROM capped c
    GROUP BY c.ord
),
created_exact AS (
    SELECT t.ord, count(*) AS exact_created_window
    FROM t2 t
    CROSS JOIN params p
    JOIN win w ON w."createdAt" >= p.ws AND w."createdAt" <= p.we
    WHERE EXISTS (SELECT 1 FROM latest_kw k WHERE k."articleId" = w.id AND k.key = t.key)
    GROUP BY t.ord
)
SELECT t.label, t.term,
       COALESCE(o.orig_candidates, 0) AS orig_candidates,
       COALESCE(o.orig_exact, 0) AS orig_exact,
       COALESCE(c.deployed_candidates, 0) AS deployed_candidates,
       COALESCE(c.deployed_exact, 0) AS deployed_exact,
       COALESCE(c.fixed_candidates, 0) AS fixed_candidates,
       COALESCE(c.fixed_exact, 0) AS fixed_exact,
       COALESCE(c.exact_pub_window, 0) AS exact_pub_window,
       COALESCE(ce.exact_created_window, 0) AS exact_created_window,
       COALESCE(c.contains_pub_window, 0) AS contains_pub_window,
       (SELECT count(*) FROM orig_rows oi
         WHERE oi.ord = t.ord AND oi.exact
           AND NOT (oi.id = ANY (COALESCE(c.fixed_ids, '{}')))) AS orig_exact_not_in_fixed,
       (t.nkey <> t.key) AS nfkc_changes_term
FROM t2 t
LEFT JOIN orig o ON o.ord = t.ord
LEFT JOIN cur c ON c.ord = t.ord
LEFT JOIN created_exact ce ON ce.ord = t.ord
ORDER BY t.ord;

\echo '--- F3. what the AI tagged: latest-analysis keywords CONTAINING each term (GOOD, published in the last 24 h), top 8 per term'
WITH latest_kw AS (
    SELECT l."articleId",
           lower(btrim(COALESCE(NULLIF(e->>'keyword', ''), NULLIF(e->>'text', ''), e->>'label', ''))) AS key
    FROM (
        SELECT DISTINCT ON (a."articleId") a."articleId", a."trendingKeywords" AS tk
        FROM "news_ai_analysis" a
        JOIN "news_articles" na ON na.id = a."articleId"
        WHERE na."status" = 'GOOD'
          AND na."publishedAt" >= now() - interval '24 hours' AND na."publishedAt" <= now()
        ORDER BY a."articleId", a."lastAnalyzedAt" DESC
    ) l
    CROSS JOIN LATERAL jsonb_array_elements(
        CASE WHEN jsonb_typeof(l.tk) = 'array' THEN l.tk ELSE '[]'::jsonb END
    ) e
    WHERE jsonb_typeof(e) = 'object'
),
terms AS (
    SELECT * FROM (VALUES (1, 'election'), (2, 'ঢাকা'), (3, 'নির্বাচন')) v(ord, key)
),
hits AS (
    SELECT t.ord, t.key AS term, k.key AS keyword, count(DISTINCT k."articleId") AS articles
    FROM terms t JOIN latest_kw k ON strpos(k.key, t.key) > 0
    GROUP BY t.ord, t.key, k.key
)
SELECT term, keyword, articles, (keyword = term) AS exact
FROM (
    SELECT h.*, row_number() OVER (PARTITION BY h.ord ORDER BY h.articles DESC, h.keyword) AS rn
    FROM hits h
) x
WHERE rn <= 8
ORDER BY ord, articles DESC, keyword;
RESET TIME ZONE;
\timing off

-- ---------------------------------------------------------------------------
-- P. Progressive topic search (2026-09-29, topic-search-progressive.ts):
-- the FIRST read of slice S0 (last 7 days) and slice S1 (7–30 days) for
-- ঢাকা and election, exactly as the app issues it: each relevance tier walks
-- news_articles bounded to the slice, LIMIT 25 (TOPIC_SLICE_CHUNK: a page of
-- 12 + 1 look-ahead, rounded up so the next page is served from cache); a
-- lower tier runs only while rows are still missing and skips the ids already
-- taken. Boundaries are on the Bangladesh wall clock and rounded down like
-- buildTopicSlices (S0/S1 to 30 min, S1/S2 to 2 h). Status filter GOOD.
-- Each statement is shown with EXPLAIN (ANALYZE, BUFFERS), then run once more
-- to collect its ids (so the second run is warm). STAGE ONLY. Alone:
--   { echo "SET default_transaction_read_only = on;"; sed -n '/############ P\./,/############ done/p' scripts/performance/diagnose-search.sql; } | bash ./scripts/deploy/db.sh psql -- -f -
-- Expected: ঢাকা S0 is tier 1000 alone (Limit -> Nested Loop Semi Join over
-- news_articles_status_published_desc_nl_idx, a few hundred loops), well
-- under 1 s warm. S1 is only read by the app when S0 cannot fill a page.
-- election is rarer: lower tiers run, and S1 shows the cost of widening.
-- ---------------------------------------------------------------------------
\echo '############ P. progressive topic search: S0 / S1 slice reads for ঢাকা and election (STAGE ONLY) ############'
-- One DO statement runs every read below: the timeout covers all of them.
SET statement_timeout = '600s';
SET client_min_messages = notice;
DO $p$
DECLARE
    now_bd timestamp := (now() AT TIME ZONE 'Asia/Dhaka')::timestamp(3);
    b7  timestamp := to_timestamp(floor(extract(epoch FROM (now_bd - interval '7 days'))  / 1800) * 1800) AT TIME ZONE 'UTC';
    b30 timestamp := to_timestamp(floor(extract(epoch FROM (now_bd - interval '30 days')) / 7200) * 7200) AT TIME ZONE 'UTC';
    term text;
    s int;
    range_sql text;
    like_pat text;
    topic_p text; title_p text; summary_p text; amatch_p text; atsv_p text;
    streams text[];
    score int;
    q text;
    parts text[];
    taken text[];
    got text[];
    need int;
    line text;
    started timestamptz;
BEGIN
    RAISE NOTICE 'slice bounds (wall clock): S0 >= %, S1 = [%, %)', b7, b30, b7;
    FOREACH term IN ARRAY ARRAY['ঢাকা', 'election'] LOOP
        like_pat := '%' || term || '%';
        topic_p := format($q$EXISTS (SELECT 1 FROM "news_ai_analysis" a WHERE a."articleId" = na.id AND (COALESCE(a."topTopics"::text, '') ILIKE %1$L OR COALESCE(a."trendingKeywords"::text, '') ILIKE %1$L))$q$, like_pat);
        title_p := format($q$na."title" ILIKE %L$q$, like_pat);
        summary_p := format($q$EXISTS (SELECT 1 FROM "news_ai_analysis" a WHERE a."articleId" = na.id AND COALESCE(a."summary", '') ILIKE %L)$q$, like_pat);
        amatch_p := format($q$EXISTS (SELECT 1 FROM "news_ai_analysis" a WHERE a."articleId" = na.id AND (((
              COALESCE(a."trendingKeywords"::text, '') ILIKE %1$L OR COALESCE(a."topTopics"::text, '') ILIKE %1$L
              OR COALESCE(a."summary", '') ILIKE %1$L OR COALESCE(a."what_happened", '') ILIKE %1$L
              OR COALESCE(a."where_happened", '') ILIKE %1$L OR COALESCE(a."who_involved", '') ILIKE %1$L
              OR COALESCE(a."between_whom", '') ILIKE %1$L OR COALESCE(a."why_happened", '') ILIKE %1$L
              OR COALESCE(a."root_cause", '') ILIKE %1$L OR COALESCE(a."what_impact", '') ILIKE %1$L
              OR COALESCE(a."future_implication", '') ILIKE %1$L))
            OR (a."search_tsv" IS NOT NULL AND a."search_tsv" @@ websearch_to_tsquery('simple', %2$L))))$q$, like_pat, term);
        atsv_p := format($q$(na."search_tsv" IS NOT NULL AND na."search_tsv" @@ websearch_to_tsquery('simple', %L))$q$, term);
        FOR s IN 0..1 LOOP
            range_sql := CASE s
                WHEN 0 THEN format('na."publishedAt" >= %L::timestamp', b7)
                ELSE format('(na."publishedAt" >= %L::timestamp AND na."publishedAt" < %L::timestamp)', b30, b7)
            END;
            taken := '{}';
            need := 25;
            started := clock_timestamp();
            FOREACH score IN ARRAY ARRAY[1000, 800, 500, 100] LOOP
                EXIT WHEN need <= 0;
                streams := CASE score
                    WHEN 1000 THEN ARRAY[topic_p]
                    WHEN 800 THEN ARRAY[title_p]
                    WHEN 500 THEN ARRAY[summary_p || ' AND ' || amatch_p, summary_p || ' AND ' || atsv_p]
                    ELSE ARRAY[amatch_p, atsv_p]
                END;
                parts := '{}';
                FOREACH q IN ARRAY streams LOOP
                    parts := parts || format(
                        'SELECT na.id, na."publishedAt" FROM "news_articles" na WHERE ((na."status" = ''GOOD'') AND %s) AND %s %s ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC LIMIT %s',
                        range_sql, q,
                        CASE WHEN cardinality(taken) > 0 THEN format('AND NOT (na.id = ANY(%L::text[]))', taken) ELSE '' END,
                        need);
                END LOOP;
                q := CASE WHEN cardinality(parts) = 1 THEN parts[1]
                     ELSE format('SELECT u.id, u."publishedAt" FROM ((%s) UNION (%s)) u ORDER BY u."publishedAt" DESC NULLS LAST, u.id DESC LIMIT %s', parts[1], parts[2], need) END;
                RAISE NOTICE '--- P % S% tier % (need %)', term, s, score, need;
                FOR line IN EXECUTE 'EXPLAIN (ANALYZE, BUFFERS) ' || q LOOP
                    RAISE NOTICE '%', line;
                END LOOP;
                EXECUTE format('SELECT COALESCE(array_agg(t.id), ''{}''::text[]) FROM (%s) t', q) INTO got;
                taken := taken || got;
                need := need - cardinality(got);
            END LOOP;
            RAISE NOTICE '=== P % S%: % rows (25 = slice chunk full), % ms incl. the EXPLAIN runs',
                term, s, cardinality(taken), round(extract(epoch FROM clock_timestamp() - started) * 1000);
        END LOOP;
    END LOOP;
END
$p$;
SET statement_timeout = '120s';

-- ---------------------------------------------------------------------------
-- W. Beta dashboard endpoints (2026-09-29, perf/beta-dashboard-and-warmup).
--    STAGE ONLY. EXPLAIN (ANALYZE, BUFFERS) executes every query below.
--
--  W1 GET /dashboard/social/hot-topics, the CURRENT shape (social-dashboard
--     .service.ts computeHotTopics, default 24 h, no filters). Prisma model
--     queries, reconstructed (not byte-identical; PRISMA_SLOW_QUERY_LOG_MS
--     gives the exact text): the capped count (HOT_TOPICS_COUNT_CAP 10000,
--     LIMIT cap+1), the candidates (newest HOT_TOPICS_MAX_POSTS = 1500
--     analysed posts: postedAt index walk + analysis semi-join), and the two
--     nested loads Prisma runs for those ids (latest analysis, snapshots).
--     Expected: Limit -> Nested Loop Semi Join over social_posts_postedAt_idx
--     (Index Scan Backward), no Sort, well under 1 s warm.
--  W2 the SAME candidate read for hoursBack=0 ("past topics"), capped at 30
--     days (HOT_TOPICS_MAX_WINDOW_HOURS 720), and, for comparison, the OLD
--     hoursBack=0 read: every post ever, no LIMIT (the beta 30 s cut).
--     The old one is bounded here by a 60 s statement_timeout.
--  W3 GET /dashboard/news/snapshot-v2/sentiment-articles?sentiment=neutral,
--     default 24 h window (Bangladesh wall clock), status GOOD, page 1,
--     limit 10 -> pool K = 50. OLD: the Prisma OR of NOT IN / IN sublinks
--     (reconstructed), expected SubPlans that read news_ai_analysis whole.
--     NEW: sentimentArticleWalkSql, the app's SQL with values inlined:
--     two LIMITed index-order streams (EXISTS neutral label / NOT EXISTS any
--     analysis) merged by UNION ALL. Expected: two Limit -> Nested Loop
--     (Anti/Semi) Join over news_articles_status_published_desc_nl_idx, no
--     SubPlan, no Sort on the article side. W3c checks the two return the
--     same ids in the same order (t); it runs the old shape too, so it can
--     hit the 60 s cap on a cold cache (then only W3b's rows count).
--  Alone:
--    { echo "SET default_transaction_read_only = on;"; sed -n '/############ W\./,/############ done/p' scripts/performance/diagnose-search.sql; } | bash ./scripts/deploy/db.sh psql -- -f -
-- ---------------------------------------------------------------------------
\echo '############ W. beta dashboards: hot-topics and neutral sentiment-articles (STAGE ONLY) ############'
SET statement_timeout = '60s';

\echo '--- W1a hot-topics 24 h: capped count (LIMIT 10001)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM (
    SELECT 1 FROM "social_posts" p
    WHERE p."postedAt" >= now() - interval '24 hours'
      AND NOT (p."postType" = 'VIDEO' AND p."postType" IS NOT NULL)
    LIMIT 10001
) c;

\echo '--- W1b hot-topics 24 h: candidates, newest 1500 analysed posts'
EXPLAIN (ANALYZE, BUFFERS)
SELECT p."id", p."campaignId", p."caption", p."totalReactions", p."commentCount", p."shareCount"
FROM "social_posts" p
WHERE p."postedAt" >= now() - interval '24 hours'
  AND NOT (p."postType" = 'VIDEO' AND p."postType" IS NOT NULL)
  AND p."id" IN (SELECT a."postId" FROM "post_ai_analysis" a WHERE a."postId" IS NOT NULL)
ORDER BY p."postedAt" DESC
LIMIT 1500;

\echo '--- W1c hot-topics 24 h: nested loads for the candidate ids (analysis, snapshots)'
EXPLAIN (ANALYZE, BUFFERS)
WITH c AS (
    SELECT p."id" FROM "social_posts" p
    WHERE p."postedAt" >= now() - interval '24 hours'
      AND NOT (p."postType" = 'VIDEO' AND p."postType" IS NOT NULL)
      AND p."id" IN (SELECT a."postId" FROM "post_ai_analysis" a WHERE a."postId" IS NOT NULL)
    ORDER BY p."postedAt" DESC
    LIMIT 1500
)
SELECT a."postId", a."summary", a."detectedEntities", a."mainThemes", a."viralPotentialScore", a."sentimentLabel"
FROM "post_ai_analysis" a WHERE a."postId" IN (SELECT id FROM c);
EXPLAIN (ANALYZE, BUFFERS)
WITH c AS (
    SELECT p."id" FROM "social_posts" p
    WHERE p."postedAt" >= now() - interval '24 hours'
      AND NOT (p."postType" = 'VIDEO' AND p."postType" IS NOT NULL)
      AND p."id" IN (SELECT a."postId" FROM "post_ai_analysis" a WHERE a."postId" IS NOT NULL)
    ORDER BY p."postedAt" DESC
    LIMIT 1500
)
SELECT s."socialPostId", s."reactionCount", s."commentCount", s."shareCount", s."rank"
FROM "social_post_snapshots" s WHERE s."socialPostId" IN (SELECT id FROM c)
ORDER BY s."rank" DESC, s."scrapedAt" DESC;

\echo '--- W2a hot-topics hoursBack=0, NEW: candidates capped at 30 days, newest 1500 analysed'
EXPLAIN (ANALYZE, BUFFERS)
SELECT p."id"
FROM "social_posts" p
WHERE p."postedAt" >= now() - interval '720 hours'
  AND NOT (p."postType" = 'VIDEO' AND p."postType" IS NOT NULL)
  AND p."id" IN (SELECT a."postId" FROM "post_ai_analysis" a WHERE a."postId" IS NOT NULL)
ORDER BY p."postedAt" DESC
LIMIT 1500;

\echo '--- W2b hot-topics hoursBack=0, OLD: every post ever, no LIMIT (60 s cap here)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT p."id", p."campaignId", p."caption"
FROM "social_posts" p
WHERE NOT (p."postType" = 'VIDEO' AND p."postType" IS NOT NULL);

\echo '--- W3a sentiment-articles neutral, OLD: OR of NOT IN / IN sublinks, K = 50'
EXPLAIN (ANALYZE, BUFFERS)
SELECT na."id"
FROM "news_articles" na
WHERE na."status" = 'GOOD'
  AND na."publishedAt" >= (now() AT TIME ZONE 'Asia/Dhaka') - interval '24 hours'
  AND na."publishedAt" <= (now() AT TIME ZONE 'Asia/Dhaka')
  AND (na."id" NOT IN (SELECT s0."articleId" FROM "news_ai_analysis" s0 WHERE s0."articleId" IS NOT NULL)
       OR na."id" IN (SELECT s."articleId" FROM "news_ai_analysis" s
                      WHERE s."overallSentimentLabel" IN ('নিরপেক্ষ', 'NEUTRAL', 'neutral', 'Neutral')
                        AND s."articleId" IS NOT NULL))
ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC
LIMIT 50;

\echo '--- W3b sentiment-articles neutral, NEW: two early-terminating streams, UNION ALL, K = 50'
EXPLAIN (ANALYZE, BUFFERS)
SELECT u."id"
FROM (
    (SELECT na."id", na."publishedAt"
     FROM "news_articles" na
     WHERE (na."status" = 'GOOD'
            AND (na."publishedAt" >= (now() AT TIME ZONE 'Asia/Dhaka') - interval '24 hours'
                 AND na."publishedAt" <= (now() AT TIME ZONE 'Asia/Dhaka')))
       AND EXISTS (SELECT 1 FROM "news_ai_analysis" s
                   WHERE s."articleId" = na."id"
                     AND s."overallSentimentLabel" IN ('নিরপেক্ষ', 'NEUTRAL', 'neutral', 'Neutral'))
     ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC
     LIMIT 50)
    UNION ALL
    (SELECT na."id", na."publishedAt"
     FROM "news_articles" na
     WHERE (na."status" = 'GOOD'
            AND (na."publishedAt" >= (now() AT TIME ZONE 'Asia/Dhaka') - interval '24 hours'
                 AND na."publishedAt" <= (now() AT TIME ZONE 'Asia/Dhaka')))
       AND NOT EXISTS (SELECT 1 FROM "news_ai_analysis" s0 WHERE s0."articleId" = na."id")
     ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC
     LIMIT 50)
) u
ORDER BY u."publishedAt" DESC NULLS LAST, u."id" DESC
LIMIT 50;

\echo '--- W3c same ids, same order (expect t; f only if an article was inserted between the two reads)'
WITH bounds AS (
    SELECT (now() AT TIME ZONE 'Asia/Dhaka') - interval '24 hours' AS lo, (now() AT TIME ZONE 'Asia/Dhaka') AS hi
),
old AS (
    SELECT array_agg(id) AS ids FROM (
        SELECT na."id" FROM "news_articles" na, bounds b
        WHERE na."status" = 'GOOD' AND na."publishedAt" >= b.lo AND na."publishedAt" <= b.hi
          AND (na."id" NOT IN (SELECT s0."articleId" FROM "news_ai_analysis" s0 WHERE s0."articleId" IS NOT NULL)
               OR na."id" IN (SELECT s."articleId" FROM "news_ai_analysis" s
                              WHERE s."overallSentimentLabel" IN ('নিরপেক্ষ', 'NEUTRAL', 'neutral', 'Neutral')
                                AND s."articleId" IS NOT NULL))
        ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC LIMIT 50) o
),
new AS (
    SELECT array_agg(id) AS ids FROM (
        SELECT u."id" FROM (
            (SELECT na."id", na."publishedAt" FROM "news_articles" na, bounds b
             WHERE na."status" = 'GOOD' AND na."publishedAt" >= b.lo AND na."publishedAt" <= b.hi
               AND EXISTS (SELECT 1 FROM "news_ai_analysis" s WHERE s."articleId" = na."id"
                           AND s."overallSentimentLabel" IN ('নিরপেক্ষ', 'NEUTRAL', 'neutral', 'Neutral'))
             ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC LIMIT 50)
            UNION ALL
            (SELECT na."id", na."publishedAt" FROM "news_articles" na, bounds b
             WHERE na."status" = 'GOOD' AND na."publishedAt" >= b.lo AND na."publishedAt" <= b.hi
               AND NOT EXISTS (SELECT 1 FROM "news_ai_analysis" s0 WHERE s0."articleId" = na."id")
             ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC LIMIT 50)
        ) u ORDER BY u."publishedAt" DESC NULLS LAST, u."id" DESC LIMIT 50) n
)
SELECT old.ids IS NOT DISTINCT FROM new.ids AS identical, cardinality(new.ids) AS rows FROM old, new;

SET statement_timeout = '120s';

-- ---------------------------------------------------------------------------
-- N. /api/core/news?search=<term> times out (2026-09-30). The predicate of
--    searchNewsArticleIdsWithFullText (news.service.ts) is to be replaced by a
--    progressive, date-sliced query; this section checks what that query can
--    rely on. Read-only: catalog reads, counts, and EXPLAIN ANALYZE inside
--    READ ONLY transactions that end in ROLLBACK. No DDL, no writes.
--
--    ALSO RUN ON THE APP HOST (shell, not SQL), from the repo root:
--      grep -E '^(CORE_DB_CONNECTION_LIMIT|FALCON_SIZING_PROFILE)=' .env.app
--
--  N1 plumbing: do safe_to_tsvector, news_articles_search_tsv_payload and
--     news_ai_analysis_search_tsv_update exist (present = f means missing);
--     the non-internal triggers on news_articles and news_ai_analysis
--     (tgenabled O = enabled, D = disabled); the indexes the slice query
--     needs, with valid/ready, size and idx_scan (present = f: missing;
--     valid = f: a failed CONCURRENTLY build the planner ignores).
--  N2 pg_get_functiondef of news_articles_search_tsv_payload,
--     safe_to_tsvector and every trigger function on news_articles. Missing
--     functions just return no row (the WHERE is the guard), nothing aborts.
--  N3 search_tsv coverage, status GOOD: pg_stats null_frac (instant, all
--     statuses), then exact counts for the last 7 / 30 / 90 / 365 days and
--     all time, one statement each (\gexec) so a slow window cannot hide the
--     others. publishedAt is the Dhaka wall clock stored as timestamp, so the
--     windows are measured from now() AT TIME ZONE 'Asia/Dhaka' like the app;
--     the (status, publishedAt) indexes serve the short windows. The same for
--     news_ai_analysis.search_tsv of those articles' analyses, plus the
--     whole-table analysis count. A high NULL share means the tsvector branch
--     cannot find those rows and the ILIKE branches must.
--  N4 EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) of the candidate 7-day slice for
--     election and নির্বাচন, SET LOCAL statement_timeout = 15s, ROLLBACK.
--     The term is prepared as the app prepares it: NFKC, zero-width chars
--     removed, whitespace collapsed, lower-cased, at most 10 words, the
--     tsquery characters stripped, words joined with ' | ' and passed to
--     to_tsquery('simple', ...) (for one word this equals plainto_tsquery).
--     Predicates are spelled the way their indexes are built
--     (news-search-indexes.spec.ts): bare na."title" for
--     news_articles_title_trgm_idx, COALESCE(a."summary", '') for
--     news_ai_analysis_summary_trgm_idx, and "search_tsv IS NOT NULL AND
--     search_tsv @@ ..." to match the partial search_tsv GIN indexes.
--     Expected good: Limit -> Index Scan (Backward) on a (status,
--     publishedAt) index with the OR as a Filter and a per-row probe of
--     news_ai_analysis("articleId"), or a BitmapOr over the GIN indexes plus
--     a small Sort; bad: a Seq Scan of news_articles, or hitting the 15 s cap.
--  Alone:
--    { echo "SET default_transaction_read_only = on;"; sed -n '/############ N\./,/############ done/p' scripts/performance/diagnose-search.sql; } | bash ./scripts/deploy/db.sh psql -- -f -
-- ---------------------------------------------------------------------------
\echo '############ N. news text search: search_tsv plumbing, coverage and a 7-day slice plan (election, নির্বাচন) ############'
SET statement_timeout = '60s';
SET lock_timeout = '2s';
SET application_name = 'falcon-diagnose-news-text-search';
\timing on

\echo '--- N1a tsvector functions (present = f: missing)'
SELECT f.name, p.oid IS NOT NULL AS present, n.nspname AS schema,
       p.oid::regprocedure AS signature, l.lanname AS language,
       p.provolatile AS volatility, pg_get_function_result(p.oid) AS returns
FROM (VALUES ('safe_to_tsvector'), ('news_articles_search_tsv_payload'),
             ('news_ai_analysis_search_tsv_update')) AS f(name)
LEFT JOIN pg_proc p ON p.proname = f.name
LEFT JOIN pg_namespace n ON n.oid = p.pronamespace
LEFT JOIN pg_language l ON l.oid = p.prolang
ORDER BY f.name, signature;

\echo '--- N1b triggers on news_articles and news_ai_analysis (internal ones excluded; tgenabled O = on, D = off)'
SELECT c.relname AS "table", t.tgname AS trigger, t.tgenabled AS enabled,
       t.tgfoid::regprocedure AS function, pg_get_triggerdef(t.oid) AS definition
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
WHERE c.relname IN ('news_articles', 'news_ai_analysis')
  AND NOT t.tgisinternal
ORDER BY c.relname, t.tgname;

\echo '--- N1c indexes the slice query needs (present = f: missing; valid = f: unusable)'
SELECT x.name, c.oid IS NOT NULL AS present, i.indisvalid AS valid, i.indisready AS ready,
       t.relname AS "table", pg_size_pretty(pg_relation_size(c.oid)) AS size,
       s.idx_scan, pg_get_indexdef(c.oid) AS definition
FROM (VALUES ('news_articles_search_tsv_gin_idx'), ('news_articles_title_trgm_idx'),
             ('news_ai_analysis_search_tsv_gin_idx'), ('news_ai_analysis_summary_trgm_idx'),
             ('news_articles_status_published_desc_nl_idx'), ('news_articles_status_publishedAt_idx'),
             ('news_ai_analysis_articleId_idx')) AS x(name)
LEFT JOIN pg_class c ON c.relname = x.name AND c.relkind = 'i'
LEFT JOIN pg_index i ON i.indexrelid = c.oid
LEFT JOIN pg_class t ON t.oid = i.indrelid
LEFT JOIN pg_stat_user_indexes s ON s.indexrelid = c.oid
ORDER BY x.name;

\echo '--- N2 function definitions: payload, safe_to_tsvector, news_articles trigger functions (no row = missing)'
SELECT p.oid::regprocedure AS function, pg_get_functiondef(p.oid) AS definition
FROM pg_proc p
WHERE p.prokind = 'f'
  AND (p.proname IN ('news_articles_search_tsv_payload', 'safe_to_tsvector')
       OR p.oid IN (SELECT t.tgfoid FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                    WHERE c.relname = 'news_articles' AND NOT t.tgisinternal))
ORDER BY p.proname;

\echo '--- N3a search_tsv null_frac from pg_stats (planner statistics, all statuses, instant)'
SELECT tablename, attname, null_frac, n_distinct
FROM pg_stats
WHERE tablename IN ('news_articles', 'news_ai_analysis') AND attname = 'search_tsv'
ORDER BY tablename;

\echo '--- N3b news_articles.search_tsv coverage, status GOOD, by publishedAt window (one statement each)'
SELECT format($g$SELECT %L AS "window", count(*) AS good_articles,
       count(*) FILTER (WHERE na."search_tsv" IS NULL) AS tsv_null,
       round(100.0 * count(*) FILTER (WHERE na."search_tsv" IS NULL) / NULLIF(count(*), 0), 2) AS pct_null
FROM "news_articles" na
WHERE na."status" = 'GOOD'%s$g$,
       COALESCE(w.span, 'all time'),
       CASE WHEN w.span IS NULL THEN ''
            ELSE format(E'\n  AND na."publishedAt" >= (now() AT TIME ZONE ''Asia/Dhaka'') - interval %L', w.span) END)
FROM unnest(ARRAY['7 days', '30 days', '90 days', '365 days', NULL]::text[]) WITH ORDINALITY AS w(span, ord)
ORDER BY w.ord
\gexec

\echo '--- N3c news_ai_analysis.search_tsv coverage for the analyses of those GOOD articles, same windows'
SELECT format($g$SELECT %L AS "window", count(DISTINCT a."articleId") AS articles_with_analysis,
       count(*) AS analyses,
       count(*) FILTER (WHERE a."search_tsv" IS NULL) AS ai_tsv_null,
       round(100.0 * count(*) FILTER (WHERE a."search_tsv" IS NULL) / NULLIF(count(*), 0), 2) AS pct_null,
       count(*) FILTER (WHERE COALESCE(a."summary", '') = '') AS empty_summary
FROM "news_articles" na
JOIN "news_ai_analysis" a ON a."articleId" = na.id
WHERE na."status" = 'GOOD'%s$g$,
       COALESCE(w.span, 'all time'),
       CASE WHEN w.span IS NULL THEN ''
            ELSE format(E'\n  AND na."publishedAt" >= (now() AT TIME ZONE ''Asia/Dhaka'') - interval %L', w.span) END)
FROM unnest(ARRAY['7 days', '30 days', '90 days', '365 days', NULL]::text[]) WITH ORDINALITY AS w(span, ord)
ORDER BY w.ord
\gexec

\echo '--- N3d news_ai_analysis.search_tsv, whole table (any article status, orphans included)'
SELECT count(*) AS analyses,
       count(*) FILTER (WHERE a."search_tsv" IS NULL) AS ai_tsv_null,
       round(100.0 * count(*) FILTER (WHERE a."search_tsv" IS NULL) / NULLIF(count(*), 0), 2) AS pct_null,
       count(*) FILTER (WHERE a."articleId" IS NULL) AS no_article
FROM "news_ai_analysis" a;

\echo '--- N4a candidate 7-day slice, term election (15 s cap, READ ONLY, ROLLBACK)'
\set term 'election'
SELECT btrim(regexp_replace(regexp_replace(normalize(:'term', NFKC), '[​-‍﻿]', '', 'g'), '\s+', ' ', 'g')) AS nterm \gset
SELECT lower(:'nterm') AS nterm \gset
SELECT '%' || :'nterm' || '%' AS likepat,
       array_to_string(ARRAY(
           SELECT tok FROM (
               SELECT regexp_replace(w.word, '["''\\()|&!*:<>]', '', 'g') AS tok, w.n
               FROM regexp_split_to_table(:'nterm', '\s+') WITH ORDINALITY AS w(word, n)
               WHERE w.word <> ''
               ORDER BY w.n LIMIT 10
           ) s WHERE s.tok <> '' ORDER BY s.n), ' | ') AS tsq \gset
\echo 'normalised term:' :'nterm' ' ILIKE pattern:' :'likepat' ' to_tsquery input:' :'tsq'
BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '15s';
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT na.id
FROM "news_articles" na
WHERE na."status" = 'GOOD'
  AND na."publishedAt" >= (now() AT TIME ZONE 'Asia/Dhaka') - interval '7 days'
  AND (
        (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ to_tsquery('simple', :'tsq'))
        OR na."title" ILIKE :'likepat'
        OR EXISTS (
            SELECT 1 FROM "news_ai_analysis" a
            WHERE a."articleId" = na.id
              AND ((a."search_tsv" IS NOT NULL AND a."search_tsv" @@ to_tsquery('simple', :'tsq'))
                   OR COALESCE(a."summary", '') ILIKE :'likepat')
        )
      )
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT 500;
ROLLBACK;

\echo '--- N4b candidate 7-day slice, term নির্বাচন (15 s cap, READ ONLY, ROLLBACK)'
\set term 'নির্বাচন'
SELECT btrim(regexp_replace(regexp_replace(normalize(:'term', NFKC), '[​-‍﻿]', '', 'g'), '\s+', ' ', 'g')) AS nterm \gset
SELECT lower(:'nterm') AS nterm \gset
SELECT '%' || :'nterm' || '%' AS likepat,
       array_to_string(ARRAY(
           SELECT tok FROM (
               SELECT regexp_replace(w.word, '["''\\()|&!*:<>]', '', 'g') AS tok, w.n
               FROM regexp_split_to_table(:'nterm', '\s+') WITH ORDINALITY AS w(word, n)
               WHERE w.word <> ''
               ORDER BY w.n LIMIT 10
           ) s WHERE s.tok <> '' ORDER BY s.n), ' | ') AS tsq \gset
\echo 'normalised term:' :'nterm' ' ILIKE pattern:' :'likepat' ' to_tsquery input:' :'tsq'
BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '15s';
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT na.id
FROM "news_articles" na
WHERE na."status" = 'GOOD'
  AND na."publishedAt" >= (now() AT TIME ZONE 'Asia/Dhaka') - interval '7 days'
  AND (
        (na."search_tsv" IS NOT NULL AND na."search_tsv" @@ to_tsquery('simple', :'tsq'))
        OR na."title" ILIKE :'likepat'
        OR EXISTS (
            SELECT 1 FROM "news_ai_analysis" a
            WHERE a."articleId" = na.id
              AND ((a."search_tsv" IS NOT NULL AND a."search_tsv" @@ to_tsquery('simple', :'tsq'))
                   OR COALESCE(a."summary", '') ILIKE :'likepat')
        )
      )
ORDER BY na."publishedAt" DESC NULLS LAST, na.id DESC
LIMIT 500;
ROLLBACK;

\timing off
SET statement_timeout = '120s';

-- ---------------------------------------------------------------------------
-- O. The shipped progressive news text search (perf/news-search-progressive,
--    news-search-progressive.ts buildNewsSearchSql), after the deploy. Read-
--    only: catalog reads, one count, EXPLAIN ANALYZE in READ ONLY ROLLBACK.
--  O1 news_articles_fts_expr_idx and news_ai_analysis_search_tsv_gin_idx:
--     present / valid / size / idx_scan (valid = f: drop it CONCURRENTLY and
--     rerun db.sh perf-schema), and the AI search_tsv NULL share (the
--     backfill, RUNBOOK §4, brings it to ~0).
--  O2 EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) of the 7-day slice for election
--     and নির্বাচন exactly as the app builds it (words as prefix terms, the
--     three UNION branches, 500 newest candidates, then scoring), 15 s cap.
--     Expect a Bitmap Index Scan on news_articles_fts_expr_idx in the first
--     branch and no per-row news_articles_fts_document filter; well under 4 s (the app's
--     per-slice budget). The scoring here keeps only the title-phrase and AI
--     rank terms; matching and the candidate cap are the app's, verbatim.
-- ---------------------------------------------------------------------------
\echo '############ O1 news text-search indexes and AI search_tsv coverage ############'
SELECT i.relname AS index, x.indisvalid AS valid, x.indisready AS ready,
       pg_size_pretty(pg_relation_size(i.oid)) AS size, s.idx_scan
FROM pg_class i
JOIN pg_index x ON x.indexrelid = i.oid
LEFT JOIN pg_stat_user_indexes s ON s.indexrelid = i.oid
WHERE i.relname IN ('news_articles_fts_expr_idx', 'news_ai_analysis_search_tsv_gin_idx', 'news_articles_title_trgm_idx',
                    'news_articles_status_published_desc_nl_idx')
ORDER BY 1;
SELECT count(*) FILTER (WHERE search_tsv IS NULL) AS ai_tsv_null, count(*) AS ai_rows FROM news_ai_analysis;

\timing on
\echo '--- O2a shipped 7-day slice, term election (15 s cap, READ ONLY, ROLLBACK)'
\set term 'election'
SELECT lower(btrim(regexp_replace(regexp_replace(normalize(:'term', NFKC), '[​-‍﻿]', '', 'g'), '\s+', ' ', 'g'))) AS nterm \gset
SELECT '%' || :'nterm' || '%' AS likepat,
       array_to_string(ARRAY(
           SELECT tok || ':*' FROM (
               SELECT regexp_replace(w.word, '["''\\()|&!*:<>]', '', 'g') AS tok, w.n
               FROM regexp_split_to_table(:'nterm', '\s+') WITH ORDINALITY AS w(word, n)
               WHERE w.word <> '' ORDER BY w.n LIMIT 10
           ) s WHERE s.tok <> '' ORDER BY s.n), ' | ') AS tsq \gset
\echo 'to_tsquery input:' :'tsq'
BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '15s';
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
WITH matched AS (
    SELECT na."id" FROM "news_articles" na WHERE na."status" = 'GOOD' AND na."publishedAt" >= (now() AT TIME ZONE 'Asia/Dhaka') - interval '7 days'
      AND news_articles_fts_document(na."title", na."content") @@ to_tsquery('simple', :'tsq')
    UNION
    SELECT na."id" FROM "news_articles" na WHERE na."status" = 'GOOD' AND na."publishedAt" >= (now() AT TIME ZONE 'Asia/Dhaka') - interval '7 days'
      AND na."title" ILIKE :'likepat'
    UNION
    SELECT na."id" FROM "news_articles" na WHERE na."status" = 'GOOD' AND na."publishedAt" >= (now() AT TIME ZONE 'Asia/Dhaka') - interval '7 days'
      AND EXISTS (SELECT 1 FROM "news_ai_analysis" a WHERE a."articleId" = na."id" AND a."search_tsv" IS NOT NULL
                  AND a."search_tsv" @@ to_tsquery('simple', :'tsq'))
),
cand AS (
    SELECT na."id", na."sourceId", na."publishedAt", na."title" FROM "news_articles" na
    WHERE na."id" IN (SELECT "id" FROM matched)
    ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC LIMIT 500
)
SELECT c."id", ROUND(((CASE WHEN c."title" ILIKE :'likepat' THEN 1000 ELSE 0 END) + COALESCE(ai.boost, 0))::numeric, 4)::float8 AS score
FROM cand c
LEFT JOIN LATERAL (
    SELECT MAX(ts_rank(a."search_tsv", to_tsquery('simple', :'tsq')) * 100) AS boost
    FROM "news_ai_analysis" a
    WHERE a."articleId" = c."id" AND a."search_tsv" IS NOT NULL AND a."search_tsv" @@ to_tsquery('simple', :'tsq')
) ai ON true
ORDER BY score DESC, c."publishedAt" DESC NULLS LAST, c."id" DESC;
ROLLBACK;

\echo '--- O2b shipped 7-day slice, term নির্বাচন (15 s cap, READ ONLY, ROLLBACK)'
\set term 'নির্বাচন'
SELECT lower(btrim(regexp_replace(regexp_replace(normalize(:'term', NFKC), '[​-‍﻿]', '', 'g'), '\s+', ' ', 'g'))) AS nterm \gset
SELECT '%' || :'nterm' || '%' AS likepat,
       array_to_string(ARRAY(
           SELECT tok || ':*' FROM (
               SELECT regexp_replace(w.word, '["''\\()|&!*:<>]', '', 'g') AS tok, w.n
               FROM regexp_split_to_table(:'nterm', '\s+') WITH ORDINALITY AS w(word, n)
               WHERE w.word <> '' ORDER BY w.n LIMIT 10
           ) s WHERE s.tok <> '' ORDER BY s.n), ' | ') AS tsq \gset
\echo 'to_tsquery input:' :'tsq'
BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '15s';
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
WITH matched AS (
    SELECT na."id" FROM "news_articles" na WHERE na."status" = 'GOOD' AND na."publishedAt" >= (now() AT TIME ZONE 'Asia/Dhaka') - interval '7 days'
      AND news_articles_fts_document(na."title", na."content") @@ to_tsquery('simple', :'tsq')
    UNION
    SELECT na."id" FROM "news_articles" na WHERE na."status" = 'GOOD' AND na."publishedAt" >= (now() AT TIME ZONE 'Asia/Dhaka') - interval '7 days'
      AND na."title" ILIKE :'likepat'
    UNION
    SELECT na."id" FROM "news_articles" na WHERE na."status" = 'GOOD' AND na."publishedAt" >= (now() AT TIME ZONE 'Asia/Dhaka') - interval '7 days'
      AND EXISTS (SELECT 1 FROM "news_ai_analysis" a WHERE a."articleId" = na."id" AND a."search_tsv" IS NOT NULL
                  AND a."search_tsv" @@ to_tsquery('simple', :'tsq'))
),
cand AS (
    SELECT na."id", na."sourceId", na."publishedAt", na."title" FROM "news_articles" na
    WHERE na."id" IN (SELECT "id" FROM matched)
    ORDER BY na."publishedAt" DESC NULLS LAST, na."id" DESC LIMIT 500
)
SELECT c."id", ROUND(((CASE WHEN c."title" ILIKE :'likepat' THEN 1000 ELSE 0 END) + COALESCE(ai.boost, 0))::numeric, 4)::float8 AS score
FROM cand c
LEFT JOIN LATERAL (
    SELECT MAX(ts_rank(a."search_tsv", to_tsquery('simple', :'tsq')) * 100) AS boost
    FROM "news_ai_analysis" a
    WHERE a."articleId" = c."id" AND a."search_tsv" IS NOT NULL AND a."search_tsv" @@ to_tsquery('simple', :'tsq')
) ai ON true
ORDER BY score DESC, c."publishedAt" DESC NULLS LAST, c."id" DESC;
ROLLBACK;
\timing off

\echo '############ done — paste the whole output into docs/performance/backend-baseline.md §15 ############'
