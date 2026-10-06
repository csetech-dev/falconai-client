-- ============================================================================
-- OPTIONAL, READ-ONLY: find search_tsv rows flattened by the old
-- safe_to_tsvector fallback (P0-B1). Never run by any deploy.
-- ============================================================================
-- Until 2026-10-06 safe_to_tsvector's exception branch replaced every
-- non-ASCII character with a space, so a Bangla text whose UTF-8 round trip
-- raised got a search_tsv with no Bangla lexeme at all. The fix
-- (apply-search-tsv-schema.sql) only affects rows written from now on: the
-- old rows are non-NULL, so backfill-search-tsv.sql (WHERE search_tsv IS NULL)
-- never revisits them.
--
-- "Likely flattened" = the trigger's source text contains Bangla
-- (U+0980..U+09FF) but search_tsv has no Bangla lexeme. A correctly indexed
-- Bangla text always yields Bangla lexemes, so false positives are rare
-- (news_articles: only Bangla beyond the first 4000 characters of content).
--
-- Cost: one sequential scan per table with a regex over the source text. Run
-- OFF-PEAK; statement_timeout caps the whole run at 30 min (a timeout cancels
-- the run; the tables already reported stand). From the app host:
--   bash ./scripts/deploy/db.sh psql -- -f - < scripts/performance/find-flattened-search-tsv.sql
--
-- Re-index (manual, only if the counts justify it): fire the table's trigger
-- for those rows with a no-op update of a column it watches, in batches, e.g.
-- for social_posts (repeat until 0 rows are updated):
--   UPDATE social_posts SET caption = caption
--    WHERE id IN (SELECT id FROM social_posts
--                  WHERE caption ~ '[ঀ-৿]' AND search_tsv::text !~ '[ঀ-৿]'
--                  LIMIT 1000);
-- The watched column per table is the "col" column of
-- backfill-search-tsv.sql's target list. Prisma's @updatedAt is client-side,
-- so "updatedAt" is not touched.
-- ============================================================================
\set ON_ERROR_STOP off
SET statement_timeout = '30min';
SET default_transaction_read_only = on;

DO $$
DECLARE
  -- table, source expression (the trigger's text, without truncation)
  defs text[][] := ARRAY[
    ['news_articles',                  $q$concat_ws(' ', title, author, "sourceWebsite", content)$q$],
    ['news_headlines',                 $q$concat_ws(' ', title, summary, source)$q$],
    ['social_posts',                   $q$caption$q$],
    ['campaigns',                      $q$concat_ws(' ', name, username, "displayName", bio, designation)$q$],
    ['post_comments',                  $q$concat_ws(' ', text, "authorUsername")$q$],
    ['videos',                         $q$concat_ws(' ', title, channel_title, summary)$q$],
    ['video_segments',                 $q$concat_ws(' ', text, red_flag_reason)$q$],
    ['profile_ai_analytics',           $q$concat_ws(' ', "profileSummary", topic, "nextPostLikelyTopic", "nextPostPredictedSample", array_to_string("mainThemes", ' '), array_to_string("engagementTriggers", ' '), array_to_string("suggestedTopics", ' '))$q$],
    ['post_ai_analysis',               $q$concat_ws(' ', summary, "viralityRationale", "toneAnalysis", array_to_string("mainThemes", ' '), array_to_string("engagementTriggers", ' '), array_to_string(keywords, ' '))$q$],
    ['social_post_fact_checks',        $q$concat_ws(' ', "claimText", summary, verdict, "claimType")$q$],
    ['trending_category_intelligence', $q$concat_ws(' ', "aiKeyword", "whatHappened", "whyTrending", array_to_string("keyDevelopments", ' '), "potentialImpact")$q$]
  ];
  k int;
  n bigint;
BEGIN
  FOR k IN 1 .. array_length(defs, 1) LOOP
    IF to_regclass(defs[k][1]) IS NULL THEN
      RAISE NOTICE '%: table missing, skipped', defs[k][1];
      CONTINUE;
    END IF;
    BEGIN
      EXECUTE format(
        'SELECT count(*) FROM %I WHERE search_tsv IS NOT NULL AND (%s) ~ ''[ঀ-৿]'' AND search_tsv::text !~ ''[ঀ-৿]''',
        defs[k][1], defs[k][2]) INTO n;
      RAISE NOTICE '%: % likely-flattened row(s)', defs[k][1], n;
    EXCEPTION WHEN others THEN
      RAISE NOTICE '%: not checked (%)', defs[k][1], SQLERRM;
    END;
  END LOOP;
END $$;
