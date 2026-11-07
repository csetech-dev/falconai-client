# P1.9: set up monitoring on a server pair with one command each (runbook)

Plan item: [DATABASE_SCALING_PLAN.md](../DATABASE_SCALING_PLAN.md), P1.9. Implementation plan: [p1-9-plan.md](p1-9-plan.md).
These two scripts do everything that P1.7a and P1.7b did by hand on stage: exporters, TLS + password, firewall, the monitoring
stack and the checks. Run them on **production** (or on any new environment).

## Before you start (prod)

1. **The app release that contains Grafana sign-in is deployed.** That's P1.7b PR 3 plus the redirect fix in #93. Check:

   ```bash
   docker exec falcon-api-gateway grep -c 'location /grafana/' /etc/nginx/nginx.conf
   ```

   Expect `1`.

2. **The bundle is up to date on both servers.** On each, check the scripts arrived:

   ```bash
   cd /opt/falconai-client && git pull --ff-only && ls scripts/deploy/monitoring-setup-*.sh
   ```

   Expect `monitoring-setup-app.sh` and `monitoring-setup-storage.sh` listed.

3. **On the storage server, ufw must be active and deny incoming.** The script checks this and stops if not. It never turns ufw on
   for you, because doing that over SSH without an SSH rule can lock you out.

4. **Optional:** check for unused disk on the storage server, as we found on stage (P0.2):

   ```bash
   vgs
   ```

## Step 1: Storage server

1. See the plan first. It changes nothing:

   ```bash
   cd /opt/falconai-client && sudo bash scripts/deploy/monitoring-setup-storage.sh --dry-run
   ```

   It shows the storage IP and app server IP it detected. If either is wrong, add `--storage-ip <ip>` and/or `--app-ip <ip>` to
   both commands.

2. Apply. It shows the IPs and asks `Set up monitoring on this storage server with these values? [y/N]`. Type `y`:

   ```bash
   sudo bash scripts/deploy/monitoring-setup-storage.sh
   ```

   Expect every step as `changed` or `unchanged`, all `✅` under **Verify**, and at the end **one line starting with `FALCONMON1:`**.
   Copy that whole line. It contains the scrape password, so after copying it, clear the screen:

   ```bash
   clear
   ```

   To print the line again later:

   ```bash
   sudo bash scripts/deploy/monitoring-setup-storage.sh --print-handoff
   ```

## Step 2: App server

Use the site's public `https://` address, with no path.

1. See the plan first. Paste the `FALCONMON1:` line at the hidden prompt:

   ```bash
   cd /opt/falconai-client && sudo bash scripts/deploy/monitoring-setup-app.sh --handoff - --public-url https://<site> --dry-run
   ```

2. Apply, pasting the same line again:

   ```bash
   sudo bash scripts/deploy/monitoring-setup-app.sh --handoff - --public-url https://<site>
   ```

   Expect all `✅` under **Verify**. If it prints a `NOTE` about `METRICS_TOKEN`, add that token to `.env.app` as it says. The app picks
   it up at its next normal deploy; until then the falcon-core and search targets show ⚠️.

3. Open FalconAI as an admin and go to **Administration → Monitoring**. You land in Grafana with no second login.

## Dashboards and alerts (P1.7c): rollout on a server that already has monitoring

On the **app server**:

1. Get the files:

   ```bash
   cd /opt/falconai-client && git pull --ff-only
   ```

2. Run the checks. They include the alert-rule unit tests, run in the real Prometheus image. Nothing restarts:

   ```bash
   sudo bash scripts/deploy/deploy-monitoring.sh --check-only
   ```

   Expect `SUCCESS` from `check config`, from `check rules` (3 files, 14 rules) and from `test rules` (3 files), then
   `Check only: nothing started`. Stop on any `FAILED`.

3. Apply. Prometheus, Alertmanager and Grafana restart, which is a few seconds without graphs. Prometheus loads the rules, and
   Grafana loads the dashboards:

   ```bash
   sudo bash scripts/deploy/deploy-monitoring.sh
   ```

4. Verify the rules loaded. Expect `14 rules, health: {'ok'}` and `firing: []`.
   - If the app doesn't have `METRICS_TOKEN` yet (see the setup NOTE), `MonitoringTargetDown` fires for `falcon-core` /
     `falcon-search` until the next app deploy. That's expected.
   - A real alert is explained in `docs/db/scaling/p1-7c-alerts.md`.

   ```bash
   docker exec falcon-prometheus wget -qO- http://localhost:9090/api/v1/rules | python3 -c 'import json,sys; g=json.load(sys.stdin)["data"]["groups"]; r=[x for gg in g for x in gg["rules"]]; print(len(r), "rules, health:", {x["health"] for x in r}); print("firing:", [x["name"] for x in r if x.get("state")=="firing"])'
   ```

5. In FalconAI, open **Administration → Monitoring**, then Grafana → **Dashboards → FalconAI**. Expect 3 dashboards: Database,
   Storage host, Reliability.
   - These dashboards are read-only in Grafana; change them in the repo.
   - The **Reliability** dashboard has the fixed uid `falcon-reliability`, so it replaces any copy imported by hand earlier.

What each alert means and what to do: `docs/db/scaling/p1-7c-alerts.md`.

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| `0` | Done and verified | Nothing |
| `1` | An unexpected error from a helper (for example a missing sizing file) | Read the last lines; fix and re-run. Re-running is safe |
| `2` | Refused before changing anything: wrong server, ufw not ready, bad hand-off line, can't reach the storage server, or a missing bundle file | Read the `ERROR:` line; it says what to fix |
| `3` | (Storage) the compose dry run failed, or would have touched more than the two exporters. Nothing was started and the current setup is unchanged | Send the printed dry-run output to the team. Don't force it |
| `4` | Changes were applied, but a verify check failed. Nothing is rolled back automatically | The script prints the rollback commands |

## Re-running

Both scripts are **safe to re-run**. Steps that are already right show `unchanged`, and verify runs again. Use this to re-check a
server.

**After a bundle update** with monitoring changes (new templates or alert rules), apply them on the app server. That re-renders and
restarts Prometheus and Alertmanager:

```bash
cd /opt/falconai-client && sudo bash scripts/deploy/deploy-monitoring.sh
```

## Rotating the scrape password and certificate

On the storage server, then repeat Step 2 on the app server with the new line:

```bash
sudo bash scripts/deploy/monitoring-setup-storage.sh --rotate
```

Between the storage `--rotate` and the app re-run, Prometheus can't scrape the storage server, so there's a short gap in the
graphs. Run the two back to back. If the rotate fails part-way (for example exit 3), the old certificate, password and hand-off
stay in place, so nothing breaks.

You also need `--rotate` once on a server that was set up **by hand**. On stage the TLS files exist but the hand-off file doesn't,
and the script refuses rather than guessing.

## Rollback

- **Storage:** set `MONITORING_BIND_IP=127.0.0.1` and `EXPORTER_WEB_CONFIG=` in `.env.storage`, then recreate only the exporters.
  The command is printed by the script on a failed verify; it's also in `p1-7b-1-exporter-tls.md`. Remove the two ufw rules with
  `ufw status numbered`, then `ufw delete <n>`.
- **App:** stop the monitoring stack. Its history is kept:

  ```bash
  cd /opt/falconai-client && docker compose --env-file /etc/falcon-monitoring/monitoring.env -f docker-compose.monitoring.yml down
  ```

## What the scripts never do

- Restart or recreate Postgres, MinIO, WireGuard or any app container.
- Enable ufw, delete firewall rules, or edit `.env.app`.
- Show a secret, except inside the one `FALCONMON1:` line you asked for, or put a secret in a command line.

**Note:** if the app server can't reach its own public address (no hairpin NAT), the last app check shows ⚠️ instead of ✅. Check
from a browser instead: opening `https://<site>/grafana/` while signed out must send you to FalconAI.
