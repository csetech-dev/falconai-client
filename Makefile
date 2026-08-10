.PHONY: init-storage init-app deploy-storage deploy-app deploy-ghcr deploy-status deploy-down fix-crlf fix-worker-entrypoints verify-scrapers clean-docker setup-auto-deploy logs-app logs-storage \
	db-push db-push-loss db-generate db-seed db-seed-prompts db-seed-news-prompts db-seed-news-sources db-seed-videos db-status db-psql db-backfill-news-origin \
	db-exec-push db-exec-push-loss db-exec-generate db-exec-seed db-exec-seed-prompts db-exec-seed-news-prompts db-exec-seed-news-sources db-exec-seed-videos db-exec-seed-twitter-profiles db-exec-seed-telegram-profiles db-copy-schema \
	dump-db help

help:
	@echo "FalconAI split deployment (any host — pick the stack you need)"
	@echo ""
	@echo "  Storage stack (Postgres + MinIO):"
	@echo "    make init-storage     Create .env.storage"
	@echo "    make deploy-storage   Start storage stack"
	@echo ""
	@echo "  Application stack:"
	@echo "    make init-app         Create .env.app"
	@echo "    make deploy-app       Start application stack (build from source)"
	@echo "    make deploy-ghcr      Pull app stack from GHCR (FlareSolverr = public ghcr.io/flaresolverr)"
	@echo "    make setup-auto-deploy  Install webhook + deploy-agent for CI auto-deploy"
	@echo "    make fix-crlf         Fix Windows CRLF in .env and shell scripts (Linux client)"
	@echo "    make fix-worker-entrypoints  Fix worker-fb/worker-x python api.py crash (GHCR)"
	@echo "    make verify-scrapers   Check all scraper containers are running"
	@echo ""
	@echo "  make deploy-status    Show running services"
	@echo "  make deploy-down      Stop stacks"
	@echo "  make clean-docker     Prune unused Docker images/build cache (reclaim disk)"
	@echo "  make logs-app         Follow application logs"
	@echo "  make logs-storage     Follow storage logs"
	@echo ""
	@echo "  Database — one-off container (.env.app, core not required):"
	@echo "    make db-push          schema update, keep data (db push --skip-generate)"
	@echo "    make db-push-loss     schema update, allow data loss (--accept-data-loss)"
	@echo "    make db-generate      prisma generate"
	@echo "    make db-seed          run full database seed flow"
	@echo "    make db-seed-prompts  seed Technical Panel prompts (system_conf)"
	@echo "    make db-seed-news-prompts seed News AI prompts (NEWS_AI_PROMPT_TEMPLATE & TRENDING)"
	@echo "    make db-seed-news-sources seed News sources data (npm run seed:news-sources)"
	@echo "    make db-seed-videos   seed demo video intelligence data"
	@echo "    make db-status        migration status"
	@echo "    make db-psql          psql client (args after ARGS=)"
	@echo "    make db-backfill-tsv  populate search_tsv columns + GIN indexes for FTS"
	@echo "    make db-backfill-news-origin  backfill news_articles.origin from legacy keyword category types"
	@echo ""
	@echo "  Backup:"
	@echo "    make dump-db          dump Postgres DB to ./db-backups (uses Docker pg_dump)"
	@echo ""
	@echo "  Database — running falcon-core (classic docker exec):"
	@echo "    make db-copy-schema   copy schema.prisma into container"
	@echo "    make db-exec-push     db push --skip-generate via docker exec"
	@echo "    make db-exec-push-loss  db push --accept-data-loss via docker exec"
	@echo "    make db-exec-generate prisma generate via docker exec"
	@echo "    make db-exec-seed     run full database seed flow via docker exec"
	@echo "    make db-exec-seed-prompts  seed Technical Panel prompts via docker exec (npm run seed:prompts)"
	@echo "    make db-exec-seed-news-prompts seed News AI prompts via docker exec (npm run seed:news-prompts)"
	@echo "    make db-exec-seed-news-sources seed News sources data via docker exec (npm run seed:news-sources)"
	@echo "    make db-exec-seed-videos  seed demo videos via docker exec"
	@echo "    make db-exec-seed-twitter-profiles  seed Twitter/X profiles (worker-x must be authorized)"
	@echo "    make db-exec-seed-telegram-profiles seed Telegram channels (technical-panel Telegram OTP session required)"

init-storage:
	bash scripts/deploy/deploy.sh init-storage

init-app:
	bash scripts/deploy/deploy.sh init-app

deploy-storage:
	bash scripts/deploy/deploy.sh storage

deploy-app:
	bash scripts/deploy/deploy.sh app

deploy-ghcr:
	bash scripts/deploy/deploy.sh ghcr

setup-auto-deploy:
	sudo bash scripts/deploy/setup-auto-deploy.sh

fix-crlf:
	bash scripts/deploy/fix-crlf.sh

fix-worker-entrypoints:
	bash scripts/deploy/fix-worker-entrypoints.sh

verify-scrapers:
	bash scripts/deploy/verify-scrapers.sh

deploy-status:
	bash scripts/deploy/deploy.sh status

deploy-down:
	bash scripts/deploy/deploy.sh down all

clean-docker:
	bash scripts/deploy/clean-docker.sh

logs-app:
	bash scripts/deploy/deploy.sh logs app $(SERVICE)

logs-storage:
	bash scripts/deploy/deploy.sh logs storage $(SERVICE)

db-push:
	bash scripts/deploy/db.sh push

db-push-loss:
	bash scripts/deploy/db.sh push-loss

db-generate:
	bash scripts/deploy/db.sh generate

db-seed:
	bash scripts/deploy/db.sh seed

db-seed-prompts:
	bash scripts/deploy/db.sh seed-prompts

db-seed-news-prompts:
	bash scripts/deploy/db.sh seed-news-prompts

db-seed-news-sources:
	bash scripts/deploy/db.sh seed-news-sources

db-seed-videos:
	bash scripts/deploy/db.sh seed-videos

db-status:
	bash scripts/deploy/db.sh status

db-psql:
	bash scripts/deploy/db.sh psql -- $(ARGS)

db-backfill-tsv:
	bash scripts/deploy/db.sh psql -- -f - < scripts/backfill/backfill-search-tsv.sql

db-backfill-news-origin:
	bash scripts/deploy/backfill-news-origin.sh

db-copy-schema:
	bash scripts/deploy/db.sh copy-schema

db-exec-push:
	bash scripts/deploy/db.sh exec push

db-exec-push-loss:
	bash scripts/deploy/db.sh exec push-loss

db-exec-generate:
	bash scripts/deploy/db.sh exec generate

db-exec-seed:
	bash scripts/deploy/db.sh exec seed

db-exec-seed-prompts:
	bash scripts/deploy/db.sh exec seed-prompts

db-exec-seed-news-prompts:
	bash scripts/deploy/db.sh exec seed-news-prompts

db-exec-seed-news-sources:
	bash scripts/deploy/db.sh exec seed-news-sources

db-exec-seed-videos:
	bash scripts/deploy/db.sh exec seed-videos

db-exec-seed-twitter-profiles:
	bash scripts/deploy/db.sh exec seed-twitter-profiles

db-exec-seed-telegram-profiles:
	bash scripts/deploy/db.sh exec seed-telegram-profiles

dump-db:
	bash scripts/dump-db.sh
