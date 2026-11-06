# P1.7b PR 3: Grafana at /grafana/ with FalconAI admin sign-in (runbook)

Plan item: [DATABASE_SCALING_PLAN.md](../DATABASE_SCALING_PLAN.md), P1.7b PR 3. Implementation plan: [p1-7b-3-plan.md](p1-7b-3-plan.md).

**Needs first:** [P1.7b PR 2](p1-7b-2-monitoring-stack.md) running on the same environment's app server.
**Where:** the app server. Stage first; prod only by someone with prod access.

## How it works

1. An admin clicks **Administration → Monitoring** in FalconAI.
2. falcon-auth sets a Grafana-only cookie, and the tab moves to `/grafana/`.
3. On **every** Grafana request, the gateway asks falcon-auth whether the cookie belongs to an **active ADMIN with a live session**.
4. If yes, Grafana sees that user as a Grafana **Admin**. If not, the browser is sent back to FalconAI.

Logging out of FalconAI, or the session ending, ends Grafana access immediately. Non-admins never see the menu item and can't
get in.

## Step 1: Ship the code (normal app release)

PR 3 changes three app images: **falcon-auth**, **api-gateway** and **web**. They go out with your normal release:
1. merge to `stage`, then release to `main`;
2. the images are built and published to GHCR;
3. deploy the app on the server as usual.

Until step 2 below is done, the only visible change is the new **Monitoring** menu item for admins. Clicking it ends on a 502 page,
because Grafana isn't reachable yet. Nothing else changes.

After the app deploy, check on the app server that the gateway config is valid. Expect `syntax is ok` and `test is successful`:

```bash
docker exec falcon-api-gateway nginx -t
```

## Step 2: Tell Grafana the public address (app server)

1. Open the settings file:

   ```bash
   nano /etc/falcon-monitoring/monitoring.env
   ```

2. Add or set the site's public address, `https://` and the host only, with no path. Stage:
   `MONITORING_PUBLIC_URL=https://app1.csetech.diu.edu.bd`

3. Pull the latest bundle and re-run the monitoring deploy. It checks the URL, re-renders the configs and restarts the stack:

   ```bash
   cd /opt/falconai-client && git pull --ff-only
   ```

   ```bash
   bash scripts/deploy/deploy-monitoring.sh --check-only && bash scripts/deploy/deploy-monitoring.sh
   ```

   Expect `Configs valid`, then `Monitoring stack started`. An `ERROR: MONITORING_PUBLIC_URL …` means the value is missing or
   isn't `https://host`.

4. Grafana is recreated with the new settings because its environment changed. Check it's up:

   ```bash
   docker ps --filter name=falcon-grafana --format '{{.Names}} {{.Status}}'
   ```

## Step 3: Verify

1. **As an admin, in a browser.** Sign in to FalconAI, then open **Administration → Monitoring**.
   - You land in Grafana with no second login.
   - Your name appears under the profile icon, and **Administration** shows in Grafana's own menu.
2. **As a non-admin, in a private window.** Sign in as a normal user: there is **no** Monitoring item. Open
   `https://<host>/grafana/` directly: you're sent to the FalconAI home page.
3. **Signed out.** Sign out of FalconAI, then reload the Grafana tab. You're sent back to FalconAI.
4. **No forged identity.** From any machine, expect `302` and a `location` pointing to `/?monitoring=signin`, never `200`:

   ```bash
   curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' -H 'X-WEBAUTH-USER: admin' -H 'X-WEBAUTH-ROLE: Admin' https://<host>/grafana/api/user
   ```

5. **The internal check isn't public.** Expect `404`:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' https://<host>/_monitoring_verify
   ```

Send me the results of 3.1–3.5.

## Good to know

- **Grafana accounts are keyed by the FalconAI user ID.** Renaming a FalconAI user only changes the name shown in Grafana; it
  can never take over another Grafana account or Grafana's built-in `admin`. Bangla usernames work too: Grafana shows the email
  instead.
- **Working only in Grafana doesn't keep the FalconAI session alive.** If the FalconAI session times out from inactivity, Grafana
  sends you back to FalconAI. Sign in and click Monitoring again.
- **Grafana shares the FalconAI web address**, so the browser treats them as one site. Grafana's strict Content-Security-Policy is
  on to limit injected scripts. Keep the Grafana image on its latest security patch (see the plan's decisions log).

## Rollback

- **Hide Grafana again, without touching the app:** stop only Grafana. `/grafana/` then returns 502 and nothing else changes.

  ```bash
  docker stop falcon-grafana
  ```

- **Undo the code:** deploy the previous app release. The monitoring stack can stay; without the gateway route Grafana isn't
  reachable from browsers.

## Tested before this PR, and not tested

**Tested in the Claude session:**
- **falcon-auth, 9 new Jest tests:**
  - only admins with a per-device session get a cookie, and the cookie flags are exact;
  - the token carries audience `falcon-monitoring`, has a 7-day cap, and is signed with a derived key, so it is never valid as an
    access token;
  - verify accepts an active admin with a live session;
  - verify refuses a normal access token, demotion, deactivation, deletion, logout, a tampered token or a missing token.
- **falcon-auth regressions:** the full suite is 57/58. The one failure is the stale `app.controller.spec.ts`, which already failed
  on `stage`.
- **Gateway:**
  - `nginx -t` passes on the old and new configs;
  - 6 contract tests;
  - 5 end-to-end tests run the real `/grafana/` blocks in nginx, covering redirect, no cookie, forged header, verified identity
    overriding a forged one, and the internal-only verify endpoint.
  - The forged-header test was proven by mutation: deleting the header overwrite makes it fail.
- **Monitoring stack:** the URL check (https only, no path, trailing slash dropped) and the Grafana auth-proxy settings. Total
  scripts suite: 72/72.
- **Web:** 5 new tests (admin-only visibility even with every permission; the order of the session request and navigation; no
  navigation on 403 or errors). The type-check is clean. The full suite is 195/195; 2 unrelated files can't load in this session's
  install (`@falcon-ai/shared-types` isn't linked).

**Not tested here:** the real Grafana image in auth-proxy mode, and the full browser flow. Step 3 on stage covers both.
