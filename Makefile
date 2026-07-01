.PHONY: init-storage init-app deploy-storage deploy-app deploy-ghcr deploy-status deploy-down fix-crlf clean-docker logs-app logs-storage \
	db-push db-push-loss db-generate db-seed db-status db-psql \
	db-exec-push db-exec-push-loss db-exec-generate db-exec-seed db-copy-schema help

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
	@echo "    make deploy-ghcr      Pull application stack from GHCR (no source build)"
	@echo "    make fix-crlf         Fix Windows CRLF in .env and shell scripts (Linux client)"
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
	@echo "    make db-status        migration status"
	@echo "    make db-psql          list tables"
	@echo ""
	@echo "  Database — running falcon-core (classic docker exec):"
	@echo "    make db-copy-schema   copy schema.prisma into container"
	@echo "    make db-exec-push     db push --skip-generate via docker exec"
	@echo "    make db-exec-push-loss  db push --accept-data-loss via docker exec"
	@echo "    make db-exec-generate prisma generate via docker exec"
	@echo "    make db-exec-seed     run full database seed flow via docker exec"

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

fix-crlf:
	bash scripts/deploy/fix-crlf.sh

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

db-status:
	bash scripts/deploy/db.sh status

db-psql:
	bash scripts/deploy/db.sh psql -- $(ARGS)

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
