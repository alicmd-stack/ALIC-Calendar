-- =====================================================
-- Sending the queued parent notifications
-- =====================================================
--
-- Two triggers on the queue, deliberately:
--
--   1. A pg_cron tick every minute, which guarantees delivery eventually even
--      if an immediate attempt is lost.
--   2. An immediate nudge when a row is queued, because "your child has been
--      checked in" a minute late is a notification about the past, and
--      "please come to Room 4" a minute late is worse than that.
--
-- Credentials come from Vault, following the pattern already established by
-- 20260228000000 for the budget workflow notifications.

CREATE OR REPLACE FUNCTION church.dispatch_kids_notifications()
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _supabase_url TEXT;
  _service_role_key TEXT;
BEGIN
  SELECT decrypted_secret INTO _supabase_url
    FROM vault.decrypted_secrets WHERE name = 'supabase_url' LIMIT 1;
  SELECT decrypted_secret INTO _service_role_key
    FROM vault.decrypted_secrets WHERE name = 'service_role_key' LIMIT 1;

  IF _supabase_url IS NULL OR _service_role_key IS NULL THEN
    RAISE WARNING 'Vault secrets not configured; kids notifications not sent';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := _supabase_url || '/functions/v1/send-kids-notification',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || _service_role_key),
    body := '{}'::jsonb
  );
END;
$$;

REVOKE ALL ON FUNCTION church.dispatch_kids_notifications() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION church.dispatch_kids_notifications() TO service_role;

-- ---------------------------------------------------------------------------
-- Nudge the sender as soon as something is queued
-- ---------------------------------------------------------------------------
--
-- A STATEMENT-level trigger, not a row-level one: checking a family of three
-- children in queues six notifications in one statement, and six HTTP posts
-- would claim the same batch six times over. One post per statement is enough,
-- since the sender drains up to 50 rows per call.
--
-- net.http_post enqueues the request inside the current transaction, so a
-- check-in that rolls back sends nothing. If the ordering ever does race the
-- commit, the sender simply claims zero rows and the cron tick below picks the
-- notifications up within the minute — the nudge is an optimisation, and
-- correctness does not rest on it.
CREATE OR REPLACE FUNCTION church.nudge_kids_notification_sender()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
BEGIN
  -- Never let a delivery problem roll back the check-in that caused it. The
  -- child being in the room is the fact that matters; the email is a courtesy,
  -- and the cron tick will retry it.
  BEGIN
    PERFORM church.dispatch_kids_notifications();
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Could not nudge the kids notification sender: %', SQLERRM;
  END;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS kids_notification_queued ON church.notification_log;
CREATE TRIGGER kids_notification_queued
  AFTER INSERT ON church.notification_log
  FOR EACH STATEMENT
  EXECUTE FUNCTION church.nudge_kids_notification_sender();

-- ---------------------------------------------------------------------------
-- The backstop
-- ---------------------------------------------------------------------------
--
-- Every minute, all week. A tick with an empty queue costs one statement and
-- no HTTP call beyond the claim, and restricting it to Sunday mornings would
-- strand anything queued by a midweek programme or a retry.
SELECT cron.unschedule('send-kids-notifications')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'send-kids-notifications');

SELECT cron.schedule(
  'send-kids-notifications',
  '* * * * *',
  $$SELECT church.dispatch_kids_notifications();$$
);

COMMENT ON FUNCTION church.dispatch_kids_notifications() IS
  'Asks the send-kids-notification edge function to drain '
  'church.notification_log. Safe to call concurrently: the function claims '
  'rows with FOR UPDATE SKIP LOCKED, so overlapping runs take different rows.';
