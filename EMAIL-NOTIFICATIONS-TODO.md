# Developer TODO: turn on email notifications for the BBM portal

**Status as of 2026-09-03: NOT working.** The code is fully built and deployed, but the
email delivery layer was never configured, so no notification email has ever been sent
for BroadBase Media. Everything else in the portal (admin app, partner portal, database,
file storage) is live and working.

Two things send email:

| Event | Trigger | Worker route | Recipient |
|---|---|---|---|
| New allegation / audit request submitted (public form or in-portal tab) | `allegations_notify_after_insert` on `allegations` | `POST /allegations/notify` | `ALLEGATION_NOTIFY_EMAIL` = **compliance@broadbasemedia.com only** |
| New task created in the admin portal | `tasks_notify_after_insert` on `tasks` | `POST /tasks/notify` | the task's `assigned_to` address (any admin in the `admin_users` table) |

Both use the same chain: Postgres trigger → `pg_net` HTTP POST to the Cloudflare Worker →
Worker sends via Resend (resend.com). Tasks can be assigned to any of the six BBM admins
already in `admin_users` (aaron, amber, joy, katayoun, michelle, ralph @broadbasemedia.com);
add more with an `insert into admin_users (email) values (...)` if the list changes.

## Why it is broken today

1. **The Worker has no email settings.** The live Worker
   `bbm-admin-workerkeepambermormanworkersdev` has only `STORAGE_SHARED_KEY`,
   `SUPABASE_SERVICE_ROLE_KEY` and `SUPABASE_URL`. With `ALLEGATION_WEBHOOK_SECRET` /
   `TASK_WEBHOOK_SECRET` unset the routes return 401 to every call, and with
   `RESEND_API_KEY` unset they would return 500.
2. **The database triggers point at a placeholder URL.** The original migrations
   (`20260827020000_allegation_notify_webhook.sql`, `20260901030000_tasks_and_more_admins.sql`)
   shipped with `REPLACE_WITH_YOUR_WORKER_URL`, and were run as-is. Migration
   `20260903090000_notify_webhooks_point_at_bbm_worker.sql` fixes this (see step 2).

## Steps

### 1. Resend account and sending domain

Resend only delivers mail from a **verified domain**. Its default test sender
(`onboarding@resend.dev`) delivers only to the Resend account owner's own signup address,
so it cannot be used for compliance@broadbasemedia.com or the admin team.

- **Create a new Resend account for BroadBase Media** at resend.com (the free tier is
  enough). This mirrors how the Apex portal was set up — Apex has its own Resend account
  with its own verified domain and key — and keeps BBM's sending reputation, domain and
  API key fully separate from Apex's. Do not reuse Apex's account or key.
- In that account, Resend → **Domains → Add Domain**, add `broadbasemedia.com` and publish
  the DNS records it gives you (DKIM, SPF, and the bounce-subdomain MX) at BroadBase's DNS
  host. Wait until it shows **Verified**.
- Resend → **API Keys**, create a key (suggest naming it "BBM portal", Sending access).
  Keep it for step 3. Never commit it to this repo.

### 2. Point the database triggers at the Worker

In the BBM Supabase project (`wabkzlxqofepjczwjizz`) → SQL Editor, run
`supabase/migrations/20260903090000_notify_webhooks_point_at_bbm_worker.sql` once. It is
`create or replace`, so it is safe to re-run. It sets:

- allegations trigger → `https://bbm-admin-workerkeepambermormanworkersdev.ambermorman.workers.dev/allegations/notify`
  with `x-webhook-secret: 1b623f5163fdbf8a1ea6b87086e6ab333a8b8ec8f854896c`
- tasks trigger → `.../tasks/notify`
  with `x-webhook-secret: 516c74895002471b8304d44c67fa9fc76906a3e22e434e28`

If you rotate either secret, change it in that migration AND in the matching Worker
secret below. They must match exactly.

### 3. Add the Worker variables and secrets

Cloudflare dashboard → Workers & Pages → `bbm-admin-workerkeepambermormanworkersdev` →
**Settings → Variables and secrets → Add**. Add all six, then click **Deploy** (variable
changes do not take effect until deployed).

| Name | Type | Value |
|---|---|---|
| `RESEND_API_KEY` | Secret | the API key from the new BroadBase Resend account (step 1) |
| `ALLEGATION_WEBHOOK_SECRET` | Secret | `1b623f5163fdbf8a1ea6b87086e6ab333a8b8ec8f854896c` |
| `TASK_WEBHOOK_SECRET` | Secret | `516c74895002471b8304d44c67fa9fc76906a3e22e434e28` |
| `ALLEGATION_NOTIFY_EMAIL` | Text | `compliance@broadbasemedia.com` (comma-separate to add more recipients; BBM has asked for this address only) |
| `ALLEGATION_NOTIFY_FROM` | Text | an address on the verified domain, e.g. `compliance@broadbasemedia.com` or `no-reply@broadbasemedia.com` |
| `TASK_NOTIFY_FROM` | Text | same as above |

The Worker code needs **no changes** for this; it already reads all six.

### 4. Verify

1. Submit a test allegation from the public form (`partner-client/allegations.html`) or the
   admin portal's Allegations tab. compliance@broadbasemedia.com should receive
   "New Allegation / Audit Request" within about a minute.
2. Create a test task in the admin portal assigned to yourself. The assignee should receive
   the task email.
3. If nothing arrives:
   - Supabase → SQL Editor: `select id, status_code, content from net._http_response order by id desc limit 5;`
     shows the trigger's last calls to the Worker. `401` = secret mismatch, `500` = Resend
     key / recipient missing (the response body says which), no rows = the migration in
     step 2 was not run.
   - Cloudflare → the Worker → **Logs** (Real-time logs) shows the same errors from the
     Worker's side.
   - Resend → **Emails** shows whether Resend accepted the message and any delivery error
     (an unverified domain shows up here).

### 5. Clean up

Delete this file once notifications are confirmed working, and remove the matching
"DEVELOPER TODO" block from the top-of-file comment in `admin/worker.js`.
