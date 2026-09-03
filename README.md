# BroadBase Media — Partner & Compliance CRM

This is a standalone, white-labeled fork of the CRM Admin Portal + Partner Portal from Apex Digital Consulting Group's compliance tool, rebranded for BroadBase Media. It is **not connected to any live backend** — every credential has been stripped and replaced with a placeholder. A developer needs to stand up a new Supabase project and Cloudflare Worker (or equivalent) before anything in here will actually run.

## What's in this package

```
admin/
  index.html      — the CRM Admin Portal (single-page app, no build step)
  worker.js        — the backend Worker this app talks to
  bbm-logo.png      — BroadBase Media's logo (already embedded in both apps as base64)
partner-client/
  index.html        — the partner-facing portal (org users log in here)
  allegations.html  — a standalone public form (no login) for submitting an allegation/audit request
  bbm-logo.png
supabase/
  migrations/        — 61 SQL files defining the full database schema, run in filename order
data-export/          — empty; see "Getting real data in" below
```

## What was intentionally removed, and why

The original Apex tool bundled several other features alongside the CRM: an AI-powered marketing-material compliance review engine (1:1 Comparison, Feedback Bot, Precedent Library, Ask Claude), Apex's own internal Finances tracker, and a "Direct Apex Client" system for giving some of Apex's *other* clients read-only access to a shared organization's data. None of that applies to BroadBase running this as its own standalone system, so all of it has been removed — both the UI and the backend routes/prompts behind it. Only the CRM Admin Portal (organizations, carriers, materials, video submissions, allegations, discussions) and the Partner Portal survive.

One pre-existing quirk carried over as-is: there's a "Compliance Workflow" board-sync feature (`renderWorkflowView`, `/monday/*` Worker routes) that's fully built but was already unreachable from the UI in Apex's live production app too — not something broken by this rework. Safe to ignore, or wire up / delete later if you want it.

## Setup steps

### 1. Create a new Supabase project

Create a fresh project at supabase.com. Note its **Project URL** and **anon/public key** (Settings → API) — you'll need both later.

### 2. Run the migrations

Run every file in `supabase/migrations/` **in filename order** against your new project (via the Supabase SQL Editor, one at a time, or `supabase db push` with the Supabase CLI if you link the project). The last file, `99999999999999_remove_direct_apex_client_feature.sql`, is deliberately named to sort last — **do not run it until after you've imported real data** (step 3). Read its header comment; it explains why the ordering matters (some earlier migrations create columns/tables that the data import needs to exist, and this file tears them back down once the data has landed).

If you're setting up with **no real data** (a fresh empty system), you can run all 49 files back-to-back immediately, including the last one — there's nothing for it to clean up.

### 3. Getting real data in (optional — skip if starting fresh)

BroadBase asked for their existing data (organizations, carriers, materials, portal logins, etc. currently in Apex's live system, minus everything specific to a different affiliate that was removed) to carry over. I can't perform this step myself — it requires Apex's live database password, which I don't have and wouldn't handle even if offered. **Amber needs to run this herself** (or hand the two connection strings to whoever's doing the technical setup):

```bash
# 1. Install the Supabase CLI if you don't have it:
npm install -g supabase

# 2. Dump data (not schema — the migrations already create the schema) from
#    the LIVE Apex project. Get this connection string from the Apex
#    Supabase project's Settings > Database > Connection string ("URI" tab,
#    use the non-pooled "Session" connection).
supabase db dump --db-url "postgresql://postgres:[APEX-DB-PASSWORD]@[APEX-HOST]:5432/postgres" --data-only -f data-export/apex-data.sql

# 3. Restore it into the NEW BroadBase project (get this connection string
#    from the new project's own Settings > Database).
psql "postgresql://postgres:[BROADBASE-DB-PASSWORD]@[BROADBASE-HOST]:5432/postgres" -f data-export/apex-data.sql
```

If `psql` isn't installed locally, the Supabase SQL Editor can run the same file's contents pasted in (it may need splitting into smaller chunks for large tables like file storage references).

**Then**, run the final migration (`99999999999999_remove_direct_apex_client_feature.sql`) against the new project — it deletes the removed affiliate's own data and any portal-login credentials that were tagged exclusively to it, then drops the Direct Apex Client schema entirely.

One thing that migration can't reach: Supabase Auth accounts. If the removed affiliate had its own partner-portal login, delete that user separately via the new project's Authentication panel — the migration only removes the `organizations` row and its regular data, not the linked `auth.users` account.

### 3b. Email notifications (allegations + tasks) — **OPEN ITEM, see `EMAIL-NOTIFICATIONS-TODO.md`**

Every new Allegation/Audit Request (public page or in-portal tab) emails `ALLEGATION_NOTIFY_EMAIL` (`compliance@broadbasemedia.com` only), and every new task emails its assignee, via Postgres trigger → Worker route → Resend. The Allegations tab also shows a live red badge with the count of allegations still `Open`/`Investigating`.

**This is the one part of the system that is not live.** The Worker has none of the email settings and the database triggers were created pointing at a placeholder URL. `EMAIL-NOTIFICATIONS-TODO.md` at the repo root has the exact migration to run, the six Worker variables with their values, the Resend domain-verification requirement, and how to verify. The Worker code itself needs no changes.

### 4. Deploy the Worker

Deploy `admin/worker.js` to Cloudflare Workers (or adapt it — it's a standard `export default { fetch() }` module, no framework dependency). Set these as Worker secrets/variables:

| Name | What it is |
|---|---|
| `SUPABASE_URL` | Your new Supabase project's URL |
| `SUPABASE_SERVICE_ROLE_KEY` | Settings → API → `service_role` key (bypasses RLS — keep this server-side only) |
| `STORAGE_SHARED_KEY` | Any random string you generate — this is the shared secret between the Worker and `admin/index.html` |
| `MONDAY_API_TOKEN` | Only needed if you want the Compliance Workflow board-sync feature working (see the note above — it's currently unreachable from the UI anyway) |
| `ANTHROPIC_API_KEY` | Needed for the Video Submission Builder's on-screen-text OCR (Claude's vision API) — get one at console.anthropic.com |
| `ALLEGATION_WEBHOOK_SECRET` | Must exactly match the secret in `20260903090000_notify_webhooks_point_at_bbm_worker.sql` (allegations trigger) |
| `TASK_WEBHOOK_SECRET` | Must exactly match the secret in the same migration (tasks trigger) |
| `RESEND_API_KEY` | Your Resend API key — powers both notification emails |
| `ALLEGATION_NOTIFY_EMAIL` | `compliance@broadbasemedia.com` — or a comma-separated list to notify more than one address |
| `ALLEGATION_NOTIFY_FROM` | The Resend "from" address for allegation emails — must be on a domain verified in Resend (the `onboarding@resend.dev` fallback only delivers to the Resend account owner) |
| `TASK_NOTIFY_FROM` | The Resend "from" address for task-assignment emails — same verified-domain requirement |

Read the docstring at the top of `worker.js` for the full list and where each one is used.

### 5. Configure and host `admin/index.html`

Near the top of the file, replace:
```js
var APEX_STORAGE_KEY='REPLACE_WITH_YOUR_OWN_WORKER_SHARED_KEY';
var AI_ENDPOINT = "REPLACE_WITH_YOUR_WORKER_URL";
```
with your `STORAGE_SHARED_KEY` (must match what you set on the Worker) and your deployed Worker's URL. Then host the file anywhere that serves static HTML (Cloudflare Pages, Netlify, S3+CloudFront, etc.) — it's a single self-contained file, no build step.

### 6. Configure and host `partner-client/index.html` and `allegations.html`

In **both** files, replace:
```js
var SUPABASE_URL = 'REPLACE_WITH_YOUR_SUPABASE_PROJECT_URL';
var SUPABASE_ANON_KEY = 'REPLACE_WITH_YOUR_SUPABASE_ANON_KEY';
```
with your new project's URL and anon/public key (safe for client-side use — it's RLS-protected). Host both files as static assets, same as above. These two pages don't need to be on the same domain/deploy as `admin/index.html` — the original Apex system runs them as two entirely separate deployments.

### 7. Also replace

- `compliance@REPLACE_WITH_BROADBASE_DOMAIN.com` in both partner-client files — a real support/compliance email address.
- `broadbasemedia.com` placeholder domain text in `admin/index.html`'s header, if you want a different display string.

## Quick placeholder checklist

- [ ] `admin/index.html`: `APEX_STORAGE_KEY`, `AI_ENDPOINT`
- [ ] `admin/worker.js`: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `STORAGE_SHARED_KEY`, `MONDAY_API_TOKEN` (optional), `ANTHROPIC_API_KEY`, `ALLEGATION_WEBHOOK_SECRET`, `TASK_WEBHOOK_SECRET`, `RESEND_API_KEY`, `ALLEGATION_NOTIFY_EMAIL`, `ALLEGATION_NOTIFY_FROM`, `TASK_NOTIFY_FROM`
- [ ] `supabase/migrations/20260903090000_notify_webhooks_point_at_bbm_worker.sql`: run it (already carries the real Worker URL + secrets; supersedes the placeholders in `20260827020000` and `20260901030000`)
- [ ] `partner-client/index.html`: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, compliance email
- [ ] `partner-client/allegations.html`: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, compliance email
