-- Read-only monitoring role for postgres-exporter (docs/db/DATABASE_SCALING_PLAN.md, P1.7a).
-- Runbook: docs/db/scaling/p1-7a-exporters.md
--
-- What it does (safe to run again; it only creates or updates this one role):
--   * creates the role if missing (LOGIN, not SUPERUSER, no CREATEDB / CREATEROLE)
--   * sets its password and CONNECTION LIMIT 3
--   * grants pg_monitor (read-only access to pg_stat_* / pg_settings / sizes)
--   * grants CONNECT on the current database
-- It runs no DDL on application tables and takes no table locks.
--
-- The password is read from the environment, never from this file or the
-- command line, and statement logging is turned off for this session so it
-- does not reach the server log. Run as the postgres superuser:
--
--   export MONITOR_DB_PASSWORD='...'          # same value as in .env.storage
--   docker exec -i -e MONITOR_DB_PASSWORD falcon-postgres \
--     psql -U postgres -d falcon_ai -v ON_ERROR_STOP=1 \
--     < scripts/performance/create-monitor-role.sql
--
-- Optional: -v monitor_user=<name> (default falcon_monitor; must match MONITOR_DB_USER).

\set ON_ERROR_STOP on
\set QUIET on
SET log_statement = 'none';
SET log_min_duration_statement = -1;

\if :{?monitor_user}
\else
  \set monitor_user falcon_monitor
\endif

\getenv monitor_password MONITOR_DB_PASSWORD
\if :{?monitor_password}
\else
  \echo 'ERROR: MONITOR_DB_PASSWORD is not set in the environment (pass it with docker exec -e MONITOR_DB_PASSWORD).'
  DO $$ BEGIN RAISE EXCEPTION 'create-monitor-role: stopped, nothing changed'; END $$;
\endif

SELECT length(:'monitor_password') >= 16 AS password_ok \gset
\if :password_ok
\else
  \echo 'ERROR: MONITOR_DB_PASSWORD must be at least 16 characters.'
  DO $$ BEGIN RAISE EXCEPTION 'create-monitor-role: stopped, nothing changed'; END $$;
\endif

-- Refuse to touch a role that already has elevated rights.
SELECT EXISTS (
  SELECT 1 FROM pg_roles
  WHERE rolname = :'monitor_user'
    AND (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls)
) AS role_is_privileged \gset
\if :role_is_privileged
  \echo 'ERROR: role' :'monitor_user' 'exists with elevated rights; refusing to change it.'
  DO $$ BEGIN RAISE EXCEPTION 'create-monitor-role: stopped, nothing changed'; END $$;
\endif

BEGIN;
SELECT format('CREATE ROLE %I LOGIN', :'monitor_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'monitor_user') \gexec

SELECT format(
  'ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 3 PASSWORD %L',
  :'monitor_user', :'monitor_password') \gexec

SELECT format('GRANT pg_monitor TO %I', :'monitor_user') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'monitor_user') \gexec
COMMIT;

\unset monitor_password
\set QUIET off

-- Show the result (no password).
SELECT r.rolname, r.rolcanlogin, r.rolsuper, r.rolconnlimit,
       pg_has_role(r.rolname, 'pg_monitor', 'member') AS has_pg_monitor
FROM pg_roles r WHERE r.rolname = :'monitor_user';
