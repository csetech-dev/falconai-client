-- ============================================================================
-- Live search layer: search_tsv helpers, triggers and indexes (2026-10-05)
-- ============================================================================
-- Until now these objects existed ONLY on the production database (CLAUDE.md;
-- docs/brain/FALCON_BRAIN_TASKS.md P0-B1: "lives only on the live database"),
-- so beta and every fresh database differed from prod. This file is a copy of
-- prod, taken from pg_get_functiondef / pg_get_triggerdef / pg_indexes on
-- 2026-10-05, so any database can be brought to the same state.
--
-- It must behave exactly like prod, with ONE deliberate exception: the
-- safe_to_tsvector fallback no longer blanks Bangla (P0-B1, 2026-10-06; the
-- next perf-schema run ships it to prod via CREATE OR REPLACE). Any other
-- change belongs in docs/performance/TODO.md first.
--
-- Run: `bash ./scripts/deploy/db.sh perf-schema` runs this file right after
-- apply-performance-schema.sql (which owns trg_news_ai_analysis_search_tsv and
-- the two partial *_search_tsv_gin_idx indexes on news_articles and
-- news_ai_analysis). Fed on stdin, never with --single-transaction:
-- CREATE INDEX CONCURRENTLY cannot run inside a transaction.
--
-- Idempotent, and on prod a no-op apart from the catalog checks:
--   * helper/trigger functions: CREATE OR REPLACE with prod's definitions
--     (no table lock);
--   * triggers: created only when missing (DO block). Prod has them all, so
--     prod never takes the SHARE ROW EXCLUSIVE lock that CREATE (OR REPLACE)
--     TRIGGER needs on a hot table. Where one is created (beta, fresh DB) the
--     lock is bounded by lock_timeout = 10s; a timeout fails the run, rerun;
--   * indexes: CREATE INDEX CONCURRENTLY IF NOT EXISTS (never blocks reads or
--     writes); the hnsw ones only where pgvector and the vector column exist;
--   * post-check: fails naming any missing/INVALID index or missing/disabled
--     trigger.
-- First run on beta / a fresh DB builds the indexes: the GIN ones over a
-- mostly-NULL column are quick; an hnsw build over populated embeddings can
-- take many minutes (run `db.sh perf-schema` by hand, off-peak, before the
-- deploy). Then fill old rows: scripts/performance/backfill-search-tsv.sql.
--
-- Every name created here is on scripts/performance/live-only-indexes.txt, the
-- keep-list that stops the guarded schema sync (db.sh push) from dropping it.
-- ============================================================================
\set ON_ERROR_STOP on
SET lock_timeout = '0';
SET statement_timeout = '0';
-- One run at a time (same reasoning as apply-performance-schema.sql: a TRY
-- lock that fails fast, never a blocking one).
DO $$ BEGIN
 IF NOT pg_try_advisory_lock(hashtext('falcon-search-tsv-schema')) THEN
  RAISE EXCEPTION 'Another search-tsv schema run holds the falcon-search-tsv-schema lock. Wait for it to finish, then rerun. Never run two at once.';
 END IF;
END $$;
-- Refuse to start while ANY index build is running (see apply-performance-schema.sql).
DO $$ DECLARE busy text; BEGIN
 SELECT string_agg(coalesce(p.index_relid::regclass::text, p.relid::regclass::text), ', ') INTO busy
   FROM pg_stat_progress_create_index p WHERE p.pid <> pg_backend_pid();
 IF busy IS NOT NULL THEN
  RAISE EXCEPTION 'An index build is still running (%). Wait until SELECT * FROM pg_stat_progress_create_index returns no rows, then rerun.', busy;
 END IF;
END $$;
-- Refuse invalid indexes: IF NOT EXISTS would otherwise silently skip rebuilding them.
DO $$ BEGIN
 IF EXISTS (SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
             JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = current_schema() AND NOT i.indisvalid AND c.relname IN (
              'campaigns_search_tsv_gin_idx', 'post_comments_search_tsv_gin_idx', 'videos_search_tsv_gin_idx',
              'news_headlines_search_tsv_gin_idx', 'trending_category_intelligence_search_tsv_gin_idx',
              'social_posts_search_tsv_gin_idx', 'social_post_fact_checks_search_tsv_gin_idx',
              'profile_ai_analytics_search_tsv_gin_idx', 'post_ai_analysis_search_tsv_gin_idx',
              'video_segments_search_tsv_gin_idx', 'news_articles_title_embedding_hnsw_idx',
              'news_ai_analysis_content_embedding_hnsw_idx', 'campaigns_profile_embedding_hnsw_idx'))
 THEN RAISE EXCEPTION 'Invalid search-tsv index found (list them: SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid). If no index build is running, drop ONLY that index CONCURRENTLY, then rerun.'; END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 1. Helpers
-- ----------------------------------------------------------------------------

-- Prod definition except the fallback (P0-B1 fix, 2026-10-06). Prod's fallback
-- was regexp_replace(input, '[^\x20-\x7E]', ' ', 'g'), an ASCII allow-list that
-- turned a whole Bangla text into spaces whenever the round trip raised. It now
-- strips only the C0 controls and DEL, keeping tab/LF/CR and every printable
-- codepoint (Bangla, ZWJ/ZWNJ). The pattern is an E'' literal with doubled
-- backslashes so the regex engine receives \x00..\x7F escapes whatever
-- standard_conforming_strings is (a plain '\x00' would become a raw NUL byte,
-- and fail, with the setting off). Rows the old fallback already flattened stay
-- flattened: docs/performance/TODO.md, "P0-B1 follow-up", and
-- scripts/performance/find-flattened-search-tsv.sql.
CREATE OR REPLACE FUNCTION safe_to_tsvector(input text) RETURNS tsvector
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  cleaned text;
BEGIN
  IF input IS NULL OR input = '' THEN
    RETURN to_tsvector('simple', '');
  END IF;
  BEGIN
    cleaned := convert_from(convert_to(input, 'UTF8'), 'UTF8');
  EXCEPTION WHEN others THEN
    cleaned := regexp_replace(input, E'[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F\\x7F]', ' ', 'g');
  END;
  RETURN to_tsvector('simple', cleaned);
END;
$$;

-- falcon_safe_left(input, max_chars): the first max_chars characters, counted
-- by walking the UTF-8 bytes itself. It never calls left()/substr() on text,
-- so news_articles_tsv_trigger is NOT exposed to the PostgreSQL 18 bug where
-- left() on large toasted Bangla text cut a character mid-sequence and raised
-- "invalid byte sequence for encoding UTF8" (the reason news_articles_fts_document
-- in apply-performance-schema.sql never truncates). Cost: get_byte walks the
-- bytes of up to max_chars characters, O(n) per call; prod's behaviour.
-- Prod definition, verbatim (pg_get_functiondef, 2026-10-05).
CREATE OR REPLACE FUNCTION public.falcon_safe_left(input text, max_chars integer)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    b bytea;
    blen int;
    i int;
    chars int;
    cut int;
    byte_val int;
BEGIN
    IF input IS NULL THEN
        RETURN '';
    END IF;
    -- Convert to bytea safely. text::bytea can fail on invalid UTF-8,
    -- so use convert_to with SQL_ASCII which maps every byte 1:1.
    b := convert_to(input, 'SQL_ASCII');
    blen := octet_length(b);
    IF blen = 0 THEN
        RETURN '';
    END IF;
    -- Walk byte-by-byte, counting characters (UTF-8 aware)
    i := 0;
    chars := 0;
    cut := blen;
    WHILE i < blen AND chars < max_chars LOOP
        byte_val := get_byte(b, i);
        IF byte_val < 128 THEN
            i := i + 1;
        ELSIF byte_val BETWEEN 192 AND 223 THEN
            i := i + 2;
        ELSIF byte_val BETWEEN 224 AND 239 THEN
            i := i + 3;
        ELSIF byte_val BETWEEN 240 AND 247 THEN
            i := i + 4;
        ELSE
            -- Invalid lead byte (continuation byte or 0xF8+), skip 1
            i := i + 1;
        END IF;
        chars := chars + 1;
        cut := least(i, blen);
    END LOOP;
    -- Trim to the cut point
    b := substring(b from 1 for cut);
    -- Try UTF-8 decode
    BEGIN
        RETURN convert_from(b, 'UTF8');
    EXCEPTION WHEN character_not_in_repertoire THEN
        -- Still has invalid bytes in the middle; fall back to Latin-1
        -- which maps every byte to a character (no decoding errors)
        RETURN convert_from(b, 'LATIN1');
    END;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 2. Trigger functions (prod definitions, verbatim, re-indented)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION news_articles_tsv_trigger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.search_tsv := safe_to_tsvector(concat_ws(' ',
    falcon_safe_left(NEW.title, 1000),
    falcon_safe_left(NEW.author, 500),
    falcon_safe_left(NEW."sourceWebsite", 500),
    falcon_safe_left(coalesce(NEW.content, ''), 4000)));
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION news_headlines_tsv_trigger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.search_tsv := safe_to_tsvector(concat_ws(' ', NEW.title, NEW.summary, NEW.source));
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION social_posts_tsv_trigger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.search_tsv := safe_to_tsvector(coalesce(NEW.caption, ''));
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION campaigns_tsv_trigger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.search_tsv := safe_to_tsvector(concat_ws(' ', NEW.name, NEW.username, NEW."displayName", NEW.bio, NEW.designation));
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION post_comments_tsv_trigger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.search_tsv := safe_to_tsvector(concat_ws(' ', NEW.text, NEW."authorUsername"));
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION videos_tsv_trigger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.search_tsv := safe_to_tsvector(concat_ws(' ', NEW.title, NEW."channel_title", coalesce(NEW.summary, '')));
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION video_segments_tsv_trigger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.search_tsv := safe_to_tsvector(concat_ws(' ', NEW.text, coalesce(NEW."red_flag_reason", '')));
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION profile_ai_analytics_tsv_trigger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.search_tsv := safe_to_tsvector(concat_ws(' ',
    NEW."profileSummary",
    coalesce(NEW.topic, ''),
    coalesce(NEW."nextPostLikelyTopic", ''),
    coalesce(NEW."nextPostPredictedSample", ''),
    array_to_string(NEW."mainThemes", ' '),
    array_to_string(NEW."engagementTriggers", ' '),
    array_to_string(NEW."suggestedTopics", ' ')));
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION post_ai_analysis_tsv_trigger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.search_tsv := safe_to_tsvector(concat_ws(' ',
    NEW.summary,
    coalesce(NEW."viralityRationale", ''),
    coalesce(NEW."toneAnalysis", ''),
    array_to_string(NEW."mainThemes", ' '),
    array_to_string(NEW."engagementTriggers", ' '),
    array_to_string(NEW.keywords, ' ')));
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION social_post_fact_checks_tsv_trigger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.search_tsv := safe_to_tsvector(concat_ws(' ', NEW."claimText", NEW.summary, NEW.verdict, NEW."claimType"));
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION trending_category_intelligence_tsv_trigger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.search_tsv := safe_to_tsvector(concat_ws(' ',
    coalesce(NEW."aiKeyword", ''),
    coalesce(NEW."whatHappened", ''),
    coalesce(NEW."whyTrending", ''),
    array_to_string(NEW."keyDevelopments", ' '),
    coalesce(NEW."potentialImpact", '')));
  RETURN NEW;
END;
$$;

-- ----------------------------------------------------------------------------
-- 3. Triggers (prod definitions; created only when missing)
-- ----------------------------------------------------------------------------
-- The search_tsv triggers prod once had on scrape_results, post_shares and
-- social_post_snapshots were removed and stay removed (docs/performance/TODO.md).
SET lock_timeout = '10s';
DO $$
DECLARE
  -- table, trigger, definition after "CREATE TRIGGER <name> "
  defs text[][] := ARRAY[
    ['news_articles', 'news_articles_tsv_update',
     'BEFORE INSERT OR UPDATE ON news_articles FOR EACH ROW EXECUTE FUNCTION news_articles_tsv_trigger()'],
    ['news_headlines', 'news_headlines_tsv_update',
     'BEFORE INSERT OR UPDATE ON news_headlines FOR EACH ROW EXECUTE FUNCTION news_headlines_tsv_trigger()'],
    ['social_posts', 'social_posts_tsv_update',
     'BEFORE INSERT OR UPDATE ON social_posts FOR EACH ROW EXECUTE FUNCTION social_posts_tsv_trigger()'],
    ['campaigns', 'campaigns_tsv_update',
     'BEFORE INSERT OR UPDATE ON campaigns FOR EACH ROW EXECUTE FUNCTION campaigns_tsv_trigger()'],
    ['post_comments', 'trg_post_comments_search_tsv',
     'BEFORE INSERT OR UPDATE OF text, "authorUsername" ON post_comments FOR EACH ROW EXECUTE FUNCTION post_comments_tsv_trigger()'],
    ['videos', 'trg_videos_search_tsv',
     'BEFORE INSERT OR UPDATE OF title, channel_title, summary ON videos FOR EACH ROW EXECUTE FUNCTION videos_tsv_trigger()'],
    ['video_segments', 'trg_video_segments_search_tsv',
     'BEFORE INSERT OR UPDATE OF text, red_flag_reason ON video_segments FOR EACH ROW EXECUTE FUNCTION video_segments_tsv_trigger()'],
    ['profile_ai_analytics', 'trg_profile_ai_analytics_search_tsv',
     'BEFORE INSERT OR UPDATE OF "profileSummary", topic, "nextPostLikelyTopic", "nextPostPredictedSample", "mainThemes", "engagementTriggers", "suggestedTopics" ON profile_ai_analytics FOR EACH ROW EXECUTE FUNCTION profile_ai_analytics_tsv_trigger()'],
    ['post_ai_analysis', 'trg_post_ai_analysis_search_tsv',
     'BEFORE INSERT OR UPDATE OF summary, "viralityRationale", "toneAnalysis", "mainThemes", "engagementTriggers", keywords ON post_ai_analysis FOR EACH ROW EXECUTE FUNCTION post_ai_analysis_tsv_trigger()'],
    ['social_post_fact_checks', 'trg_social_post_fact_checks_search_tsv',
     'BEFORE INSERT OR UPDATE OF "claimText", summary, verdict, "claimType" ON social_post_fact_checks FOR EACH ROW EXECUTE FUNCTION social_post_fact_checks_tsv_trigger()'],
    ['trending_category_intelligence', 'trg_trending_category_intelligence_search_tsv',
     'BEFORE INSERT OR UPDATE OF "aiKeyword", "whatHappened", "whyTrending", "keyDevelopments", "potentialImpact" ON trending_category_intelligence FOR EACH ROW EXECUTE FUNCTION trending_category_intelligence_tsv_trigger()']
  ];
  k int;
BEGIN
  FOR k IN 1 .. array_length(defs, 1) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                    WHERE tgname = defs[k][2] AND tgrelid = to_regclass(defs[k][1]) AND NOT tgisinternal) THEN
      EXECUTE format('CREATE TRIGGER %I %s', defs[k][2], defs[k][3]);
      RAISE NOTICE 'search-tsv: created trigger % on %', defs[k][2], defs[k][1];
    END IF;
  END LOOP;
END $$;
SET lock_timeout = '0';
-- Serial index builds. A parallel build passes maintenance_work_mem through a
-- dynamic shared memory segment in /dev/shm, and the Postgres container keeps
-- Docker's default 64 MB shm. On beta (2026-10-05) the hnsw build failed with
-- "could not resize shared memory segment ... No space left on device" and left
-- an INVALID index behind. A serial build uses process-local memory instead.
SET max_parallel_maintenance_workers = 0;

-- ----------------------------------------------------------------------------
-- 4. Indexes (CONCURRENTLY: never blocks reads or writes)
-- ----------------------------------------------------------------------------
-- news_articles_search_tsv_gin_idx and news_ai_analysis_search_tsv_gin_idx
-- (both partial, WHERE search_tsv IS NOT NULL) are built by
-- apply-performance-schema.sql.
CREATE INDEX CONCURRENTLY IF NOT EXISTS campaigns_search_tsv_gin_idx ON campaigns USING gin (search_tsv);

CREATE INDEX CONCURRENTLY IF NOT EXISTS post_comments_search_tsv_gin_idx ON post_comments USING gin (search_tsv);

CREATE INDEX CONCURRENTLY IF NOT EXISTS videos_search_tsv_gin_idx ON videos USING gin (search_tsv);

CREATE INDEX CONCURRENTLY IF NOT EXISTS news_headlines_search_tsv_gin_idx ON news_headlines USING gin (search_tsv);

CREATE INDEX CONCURRENTLY IF NOT EXISTS trending_category_intelligence_search_tsv_gin_idx ON trending_category_intelligence USING gin (search_tsv);

CREATE INDEX CONCURRENTLY IF NOT EXISTS social_posts_search_tsv_gin_idx ON social_posts USING gin (search_tsv);

CREATE INDEX CONCURRENTLY IF NOT EXISTS social_post_fact_checks_search_tsv_gin_idx ON social_post_fact_checks USING gin (search_tsv);

CREATE INDEX CONCURRENTLY IF NOT EXISTS profile_ai_analytics_search_tsv_gin_idx ON profile_ai_analytics USING gin (search_tsv);

CREATE INDEX CONCURRENTLY IF NOT EXISTS post_ai_analysis_search_tsv_gin_idx ON post_ai_analysis USING gin (search_tsv);

CREATE INDEX CONCURRENTLY IF NOT EXISTS video_segments_search_tsv_gin_idx ON video_segments USING gin (search_tsv);

-- hnsw (pgvector >= 0.5): only where the vector extension is installed AND the
-- column exists with type vector. psql \if, because CREATE INDEX CONCURRENTLY
-- cannot run inside a DO block. A database without pgvector skips them.
SELECT EXISTS (SELECT 1 FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
                WHERE a.attrelid = to_regclass('news_articles') AND a.attname = 'title_embedding'
                  AND NOT a.attisdropped AND t.typname = 'vector') AS falcon_has_vec_news_title \gset
\if :falcon_has_vec_news_title
CREATE INDEX CONCURRENTLY IF NOT EXISTS news_articles_title_embedding_hnsw_idx ON news_articles USING hnsw (title_embedding vector_cosine_ops);
\else
\echo 'search-tsv: skipped news_articles_title_embedding_hnsw_idx (no pgvector column news_articles.title_embedding)'
\endif

SELECT EXISTS (SELECT 1 FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
                WHERE a.attrelid = to_regclass('news_ai_analysis') AND a.attname = 'content_embedding'
                  AND NOT a.attisdropped AND t.typname = 'vector') AS falcon_has_vec_news_ai \gset
\if :falcon_has_vec_news_ai
CREATE INDEX CONCURRENTLY IF NOT EXISTS news_ai_analysis_content_embedding_hnsw_idx ON news_ai_analysis USING hnsw (content_embedding vector_cosine_ops);
\else
\echo 'search-tsv: skipped news_ai_analysis_content_embedding_hnsw_idx (no pgvector column news_ai_analysis.content_embedding)'
\endif

SELECT EXISTS (SELECT 1 FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
                WHERE a.attrelid = to_regclass('campaigns') AND a.attname = 'profile_embedding'
                  AND NOT a.attisdropped AND t.typname = 'vector') AS falcon_has_vec_campaigns \gset
\if :falcon_has_vec_campaigns
CREATE INDEX CONCURRENTLY IF NOT EXISTS campaigns_profile_embedding_hnsw_idx ON campaigns USING hnsw (profile_embedding vector_cosine_ops);
\else
\echo 'search-tsv: skipped campaigns_profile_embedding_hnsw_idx (no pgvector column campaigns.profile_embedding)'
\endif

-- ----------------------------------------------------------------------------
-- 5. Post-check
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  bad text;
  want_idx text[] := ARRAY[
    'campaigns_search_tsv_gin_idx', 'post_comments_search_tsv_gin_idx', 'videos_search_tsv_gin_idx',
    'news_headlines_search_tsv_gin_idx', 'trending_category_intelligence_search_tsv_gin_idx',
    'social_posts_search_tsv_gin_idx', 'social_post_fact_checks_search_tsv_gin_idx',
    'profile_ai_analytics_search_tsv_gin_idx', 'post_ai_analysis_search_tsv_gin_idx',
    'video_segments_search_tsv_gin_idx'];
  -- table, trigger, function
  want_trg text[][] := ARRAY[
    ['news_articles', 'news_articles_tsv_update', 'news_articles_tsv_trigger'],
    ['news_headlines', 'news_headlines_tsv_update', 'news_headlines_tsv_trigger'],
    ['social_posts', 'social_posts_tsv_update', 'social_posts_tsv_trigger'],
    ['campaigns', 'campaigns_tsv_update', 'campaigns_tsv_trigger'],
    ['post_comments', 'trg_post_comments_search_tsv', 'post_comments_tsv_trigger'],
    ['videos', 'trg_videos_search_tsv', 'videos_tsv_trigger'],
    ['video_segments', 'trg_video_segments_search_tsv', 'video_segments_tsv_trigger'],
    ['profile_ai_analytics', 'trg_profile_ai_analytics_search_tsv', 'profile_ai_analytics_tsv_trigger'],
    ['post_ai_analysis', 'trg_post_ai_analysis_search_tsv', 'post_ai_analysis_tsv_trigger'],
    ['social_post_fact_checks', 'trg_social_post_fact_checks_search_tsv', 'social_post_fact_checks_tsv_trigger'],
    ['trending_category_intelligence', 'trg_trending_category_intelligence_search_tsv', 'trending_category_intelligence_tsv_trigger']];
  k int;
BEGIN
  -- hnsw indexes are required only where their vector column exists.
  IF EXISTS (SELECT 1 FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
              WHERE a.attrelid = to_regclass('news_articles') AND a.attname = 'title_embedding' AND NOT a.attisdropped AND t.typname = 'vector') THEN
    want_idx := want_idx || 'news_articles_title_embedding_hnsw_idx'::text;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
              WHERE a.attrelid = to_regclass('news_ai_analysis') AND a.attname = 'content_embedding' AND NOT a.attisdropped AND t.typname = 'vector') THEN
    want_idx := want_idx || 'news_ai_analysis_content_embedding_hnsw_idx'::text;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
              WHERE a.attrelid = to_regclass('campaigns') AND a.attname = 'profile_embedding' AND NOT a.attisdropped AND t.typname = 'vector') THEN
    want_idx := want_idx || 'campaigns_profile_embedding_hnsw_idx'::text;
  END IF;

  SELECT string_agg(w.name || CASE WHEN c.oid IS NULL THEN ' (missing)' ELSE ' (INVALID)' END, ', ' ORDER BY w.name)
    INTO bad
    FROM unnest(want_idx) AS w(name)
    LEFT JOIN pg_namespace n ON n.nspname = current_schema()
    LEFT JOIN pg_class c ON c.relname = w.name AND c.relnamespace = n.oid
    LEFT JOIN pg_index i ON i.indexrelid = c.oid
   WHERE c.oid IS NULL OR NOT i.indisvalid OR NOT i.indisready;
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'Search-tsv schema incomplete: %. For an INVALID index: DROP INDEX CONCURRENTLY "<name>"; then rerun perf-schema ONCE.', bad;
  END IF;

  FOR k IN 1 .. array_length(want_trg, 1) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger tg JOIN pg_proc p ON p.oid = tg.tgfoid
                    WHERE tg.tgrelid = to_regclass(want_trg[k][1]) AND tg.tgname = want_trg[k][2]
                      AND p.proname = want_trg[k][3] AND tg.tgenabled <> 'D') THEN
      RAISE EXCEPTION 'Search-tsv schema incomplete: trigger % on % (function %) missing, disabled or bound to another function.',
        want_trg[k][2], want_trg[k][1], want_trg[k][3];
    END IF;
  END LOOP;
  RAISE NOTICE 'Search-tsv schema OK: % indexes valid, % triggers enabled.', array_length(want_idx, 1), array_length(want_trg, 1);
END $$;
SELECT pg_advisory_unlock(hashtext('falcon-search-tsv-schema'));
