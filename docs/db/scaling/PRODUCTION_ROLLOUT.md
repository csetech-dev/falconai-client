# Production rollout: one command per server

This applies, in order, every database-scaling change that has been proven on stage. It's **two commands**: one on the storage
server, then one on the app server. Each command:
1. checks every step first (a dry run);
2. shows the plan;
3. asks **once**;
4. applies the steps in order and stops at the first failure.

Every step is **idempotent**. Re-running is safe; steps already done report `unchanged` or `already on`. If a run stops halfway,
fix what it says and run the same command again.

## What it applies

| Server | Step | Plan item | Downtime |
|---|---|---|---|
| Storage | Monitoring exporters, TLS, scrape password, firewall rule for the app server | P1.7a, P1.7b, P1.9 | none; the database isn't restarted |
| Storage | `pg_stat_statements` | P0.1 | **one PostgreSQL restart, about 10–30 s**; the app reconnects |
| App | Prometheus, Alertmanager, Grafana, 14 alert rules, 3 dashboards, Grafana sign-in | P1.7b, P1.7c, P1.9 | none for FalconAI |

## Before you start (about 5 minutes)

1. **Agree a quiet moment** for the one PostgreSQL restart. If you can't get one now, add `--skip-pg-restart` to the storage
   command. Everything else runs, and you run the command again later without that option.
2. **The app release with Grafana sign-in is deployed** on the app server. This should print `1`:

   ```bash
   docker exec falcon-api-gateway grep -c 'location /grafana/' /etc/nginx/nginx.conf
   ```

3. **The bundle is up to date on both servers:**

   ```bash
   cd /opt/falconai-client && git pull --ff-only
   ```

4. **On the storage server, ufw is active and denies incoming.** The script checks this and stops if not. It never turns ufw on
   for you, because over SSH that can lock you out.

## 1. Storage server

```bash
cd /opt/falconai-client && sudo bash scripts/deploy/rollout-storage.sh
```

1. It checks every step, then lists the plan and asks `Apply all 2 steps now, in this order? [y/N]`.
2. Read the storage IP and app-server IP it detected in the check output. If either is wrong, answer `N` and add
   `--storage-ip <ip>` and/or `--app-ip <ip>`.
3. Type `y`.

When it finishes, it prints `✅ Storage rollout complete` and, as the **last line**, a line starting with `FALCONMON1:`. Copy that
whole line; it contains the scrape password. Then clear the screen:

```bash
clear
```

To print the line again later:

```bash
sudo bash scripts/deploy/monitoring-setup-storage.sh --print-handoff
```

## 2. App server

Use the site's public `https://` address, with no path:

```bash
cd /opt/falconai-client && sudo bash scripts/deploy/rollout-app.sh --public-url https://<site>
```

Paste the `FALCONMON1:` line at the hidden prompt, **once**. The check and the apply both use it; it stays in memory and is never
written to disk or printed. It then asks once; type `y`.

Without pasting, you can pass `--handoff /root/falcon-monitoring-handoff.env`, a copy of that **decoded** file from the storage server,
owned by root, mode 600. That's not the `FALCONMON1:` line itself.

Expect `✅ App rollout complete`. If it prints a `NOTE` about `METRICS_TOKEN`, add that token to `.env.app` as it says. The app picks
it up at its next normal deploy.

## 3. Check (about 2 minutes)

1. In FalconAI, as an admin, open **Administration → Monitoring**. You land in Grafana with no second login. Under
   **Dashboards → FalconAI** there are 3 dashboards, all showing data.
2. On the storage server, this should print `pg_stat_statements: on`:

   ```bash
   sudo bash scripts/deploy/pg-stat-statements.sh status
   ```

3. After a day of traffic, run the read-only query report and send it to the team. It shows prod's heaviest queries. Use the
   exact command the storage rollout printed after `pg_stat_statements is on`; it has the right user and database. With the default
   settings it's:

   ```bash
   docker exec -i falcon-postgres psql -U postgres -d falcon_ai < scripts/performance/top-queries.sql
   ```

4. In `docs/db/DATABASE_SCALING_PLAN.md`, set `prod: done <date>` on each item in the table above.

## If something fails

| Exit code | Meaning | What to do |
|---|---|---|
| `0` | Done | Nothing |
| `2` | Refused **before any change**: a check failed, or you answered no | Read the `ERROR:` line, fix it, run again |
| `4` | A step applied but its verify failed. Earlier steps stay applied; later steps didn't run | That step printed its rollback or recovery commands. For the PostgreSQL restart, **first check `docker logs --tail 30 falcon-postgres`**: if it says `redo in progress`, wait |
| `5` | A step failed while applying, so it may be partly applied. Earlier steps stay applied; later steps didn't run | Read that step's `ERROR:` line above. If it's the monitoring compose guard, send the output to the team and don't force it. Otherwise fix it and run the same command again; finished steps report `unchanged` |

Each step's own runbook has the details: [p1-9-monitoring-setup.md](p1-9-monitoring-setup.md) and
[p0-1-pg-stat-statements.md](p0-1-pg-stat-statements.md).

## For the team: adding a new step

When a plan item needs work on a server and has passed on stage:
1. Add it as a step in `scripts/deploy/rollout-storage.sh` or `rollout-app.sh`, in the order it must run. The step script must
   support `--dry-run` (change nothing, exit 0 if it can go ahead) and `--yes`, and must be safe to re-run.
2. Add a row to the table in [What it applies](#what-it-applies).
3. Add the step script to both bundle scripts (`scripts/ci/package-client-bundle.sh` and `.ps1`).
4. Run the rollout on stage (it should report `unchanged` for the old steps) before calling the item done.
