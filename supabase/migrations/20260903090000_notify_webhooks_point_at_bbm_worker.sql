-- Points both notification triggers at the deployed BBM Worker.
--
-- The original migrations (20260827020000_allegation_notify_webhook.sql and
-- 20260901030000_tasks_and_more_admins.sql) shipped with a
-- REPLACE_WITH_YOUR_WORKER_URL placeholder, so if they were run as-is the
-- triggers have been posting to a URL that does not exist and no
-- notification email has ever gone out for BBM. This re-creates both
-- functions with the real Worker URL and the secrets the Worker checks.
--
-- The two x-webhook-secret values below MUST match the Worker secrets
-- ALLEGATION_WEBHOOK_SECRET and TASK_WEBHOOK_SECRET on
-- bbm-admin-workerkeepambermormanworkersdev (Settings -> Variables and
-- secrets). The Worker also needs RESEND_API_KEY and
-- ALLEGATION_NOTIFY_EMAIL = compliance@broadbasemedia.com set before any
-- email can be delivered.
create extension if not exists pg_net with schema extensions;

-- New allegation -> email to ALLEGATION_NOTIFY_EMAIL (compliance@broadbasemedia.com)
create or replace function notify_new_allegation() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform net.http_post(
    url := 'https://bbm-admin-workerkeepambermormanworkersdev.ambermorman.workers.dev/allegations/notify',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-webhook-secret', '1b623f5163fdbf8a1ea6b87086e6ab333a8b8ec8f854896c'
    ),
    body := to_jsonb(NEW)
  );
  return NEW;
end;
$$;

drop trigger if exists allegations_notify_after_insert on allegations;
create trigger allegations_notify_after_insert
  after insert on allegations
  for each row execute function notify_new_allegation();

-- New task -> email to the task's assigned_to admin (any admin_users entry)
create or replace function notify_new_task() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform net.http_post(
    url := 'https://bbm-admin-workerkeepambermormanworkersdev.ambermorman.workers.dev/tasks/notify',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-webhook-secret', '516c74895002471b8304d44c67fa9fc76906a3e22e434e28'
    ),
    body := to_jsonb(NEW)
  );
  return NEW;
end;
$$;

drop trigger if exists tasks_notify_after_insert on tasks;
create trigger tasks_notify_after_insert
  after insert on tasks
  for each row execute function notify_new_task();
