-- falcon-gateway — idempotent schema bootstrap for its OWN tables.
--
-- Safe to run repeatedly against the shared FalconAI Postgres. It only creates
-- the gateway-owned enums/tables and NEVER touches core-owned tables such as
-- `campaigns`. Run automatically on startup when GATEWAY_DB_AUTO_INIT=true, or
-- manually: psql "$DATABASE_URL" -f prisma/init.sql

DO $$ BEGIN
  CREATE TYPE "IntegrationClientStatus" AS ENUM ('ACTIVE', 'SUSPENDED', 'REVOKED');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE "WebhookDeliveryStatus" AS ENUM ('PENDING', 'SUCCESS', 'FAILED', 'DEAD');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS "integration_clients" (
  "id"             TEXT PRIMARY KEY,
  "name"           TEXT NOT NULL,
  "description"    TEXT,
  "key_id"         TEXT NOT NULL UNIQUE,
  "secret_enc"     TEXT NOT NULL,
  "scopes"         TEXT[] NOT NULL DEFAULT '{}',
  "ip_allowlist"   TEXT[] NOT NULL DEFAULT '{}',
  "status"         "IntegrationClientStatus" NOT NULL DEFAULT 'ACTIVE',
  "rate_limit_rpm" INTEGER NOT NULL DEFAULT 120,
  "search_enabled" BOOLEAN NOT NULL DEFAULT false,
  "ip_enforced"    BOOLEAN NOT NULL DEFAULT true,
  "last_used_at"   TIMESTAMP(3),
  "created_by"     TEXT,
  "created_at"     TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updated_at"     TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS "integration_client_status_idx" ON "integration_clients" ("status");
-- Backfills for DBs created before these columns existed.
ALTER TABLE "integration_clients" ADD COLUMN IF NOT EXISTS "search_enabled" BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE "integration_clients" ADD COLUMN IF NOT EXISTS "ip_enforced" BOOLEAN NOT NULL DEFAULT true;

CREATE TABLE IF NOT EXISTS "webhook_endpoints" (
  "id"             TEXT PRIMARY KEY,
  "client_id"      TEXT NOT NULL REFERENCES "integration_clients" ("id") ON DELETE CASCADE,
  "url"            TEXT NOT NULL,
  "signing_secret" TEXT NOT NULL,
  "events"         TEXT[] NOT NULL DEFAULT '{}',
  "enabled"        BOOLEAN NOT NULL DEFAULT true,
  "created_at"     TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updated_at"     TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS "webhook_endpoint_client_idx" ON "webhook_endpoints" ("client_id");

CREATE TABLE IF NOT EXISTS "webhook_deliveries" (
  "id"            TEXT PRIMARY KEY,
  "endpoint_id"   TEXT NOT NULL REFERENCES "webhook_endpoints" ("id") ON DELETE CASCADE,
  "client_id"     TEXT NOT NULL REFERENCES "integration_clients" ("id") ON DELETE CASCADE,
  "event"         TEXT NOT NULL,
  "payload"       JSONB NOT NULL,
  "status"        "WebhookDeliveryStatus" NOT NULL DEFAULT 'PENDING',
  "attempts"      INTEGER NOT NULL DEFAULT 0,
  "response_code" INTEGER,
  "error_message" TEXT,
  "next_retry_at" TIMESTAMP(3),
  "delivered_at"  TIMESTAMP(3),
  "created_at"    TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updated_at"    TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS "webhook_delivery_status_retry_idx" ON "webhook_deliveries" ("status", "next_retry_at");
CREATE INDEX IF NOT EXISTS "webhook_delivery_endpoint_idx" ON "webhook_deliveries" ("endpoint_id");

CREATE TABLE IF NOT EXISTS "request_logs" (
  "id"          TEXT PRIMARY KEY,
  "client_id"   TEXT NOT NULL REFERENCES "integration_clients" ("id") ON DELETE CASCADE,
  "method"      TEXT NOT NULL,
  "path"        TEXT NOT NULL,
  "status_code" INTEGER NOT NULL,
  "duration_ms" INTEGER,
  "response_bytes" INTEGER,
  "ip"          TEXT,
  "user_agent"  TEXT,
  "created_at"  TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);
ALTER TABLE "request_logs" ADD COLUMN IF NOT EXISTS "duration_ms" INTEGER;
ALTER TABLE "request_logs" ADD COLUMN IF NOT EXISTS "response_bytes" INTEGER;
CREATE INDEX IF NOT EXISTS "request_log_client_created_idx" ON "request_logs" ("client_id", "created_at");
CREATE INDEX IF NOT EXISTS "request_log_created_idx" ON "request_logs" ("created_at");
