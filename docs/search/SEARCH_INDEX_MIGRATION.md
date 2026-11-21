# Moving search to a new index schema (no downtime)

Search (the keywords page, AI chat references, case filing's internal channel) reads the OpenSearch alias
`falcon-content-read` and writes through `falcon-content-write`. When a release changes the index settings or
mappings (`INDEX_SCHEMA_VERSION` in `apps/search-service/src/index-admin/index-admin.service.ts`), the new
schema needs a **new index**. search-service doesn't build it at startup on a server that already has one,
because that would leave search empty while it re-loads. It logs a warning instead:

```
Startup seed: Search uses falcon-content-v1-…; index schema v2 is not applied yet. Nothing changed. Apply it without downtime with scripts/deploy/search-index-migrate.sh.
```

`scripts/deploy/search-index-migrate.sh` applies it while search keeps working.

## Before you start

- The **app release** with the migration helper is deployed, so `falcon-search` has been rebuilt. If it isn't,
  the script says so and changes nothing.
- Expect **search ranking to change** for Bangla text when moving to v2 (stopwords, normalisation, stemming).
  Tell the team.
- Disk: the copy needs about 1.5 times the current index size free. The script checks this. On stage, v1 was
  508 MB with 120,223 documents.

Run everything on the **app server**, in `/opt/falconai-client`.

## 1. Where search stands (read-only)

```bash
sudo bash scripts/deploy/search-index-migrate.sh status
```

It shows which index search reads and writes, document counts, and the schema the release wants.

## 2. Dry run (changes nothing)

```bash
sudo bash scripts/deploy/search-index-migrate.sh migrate --dry-run
```

## 3. Migrate

```bash
sudo bash scripts/deploy/search-index-migrate.sh migrate
```

It asks once. Then it:
1. creates the new index, using the settings from the running search-service, so there's only one definition;
2. sends **writes** to the new index. Searches still read the old one;
3. copies the old index into it. A document already newer in the new index is kept;
4. checks the new index has at least as many documents as the old one;
5. switches **reads** to it in one atomic step.

The old index is kept. Expect `✅ 5. searches now use falcon-content-v2-…`. On stage-sized data this takes minutes.

- **Newly scraped items show up in search after step 5**, because during the copy they go to the new index only.
- **If it stops part-way** (exit 4), searches still use the old index and nothing is lost. Fix the cause and run
  `migrate` again; it resumes.
- **Run it in a quiet period.** A document deleted during the copy comes back from the old copy, and stays
  until it's deleted again.

Then check the keywords page with a few Bangla and English keywords.

## Rollback

```bash
sudo bash scripts/deploy/search-index-migrate.sh rollback
```

This also works from the middle of a failed migration, where reads are still on the old index and writes on the new
one. It finds the old index itself; pass `--to <index>` if it asks. It:
1. copies the new index back into the old one. The new index's versions are the same or newer;
2. sends writes back to the old index;
3. copies again whatever reached the new index meanwhile, overwriting nothing;
4. points searches at the old index.

The new index is kept. Known limits:
- documents deleted since the migration may come back;
- a document updated during step 1 keeps its earlier version until its next update.

## Cleaning up

Once the new index has run well for a while (for example a week), delete the old index to free disk. Ask the team
first:

```bash
docker exec falcon-opensearch curl -s -XDELETE 'localhost:9200/<old index name>'
```

## Exit codes

`0` done · `2` refused before any change, or you answered no · `4` failed part-way (the message says what to do; searches
are not affected before the final switch).
