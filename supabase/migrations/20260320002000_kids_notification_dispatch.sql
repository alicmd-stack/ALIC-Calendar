-- =====================================================
-- Draining the notification queue
-- =====================================================
--
-- Triggers write rows into church.notification_log with status 'queued'.
-- Nothing sent them. This adds the claim/complete protocol the sender uses.
--
-- The queue is claimed rather than merely read. Two overlapping invocations
-- (a cron tick that runs long, plus a manual retry) reading the same 'queued'
-- rows would each send them — and sending a parent two "your child has been
-- collected" emails is worse than sending none, because the second one reads
-- as a second collection. FOR UPDATE SKIP LOCKED plus a 'sending' status makes
-- a row claimable exactly once.

ALTER TABLE church.notification_log
  DROP CONSTRAINT IF EXISTS chk_notification_status;

ALTER TABLE church.notification_log
  ADD CONSTRAINT chk_notification_status CHECK (
    status IN ('queued', 'sending', 'sent', 'failed', 'skipped'));

ALTER TABLE church.notification_log
  ADD COLUMN IF NOT EXISTS claimed_at TIMESTAMPTZ;

COMMENT ON COLUMN church.notification_log.claimed_at IS
  'When a sender took ownership of this row. A row stuck in ''sending'' past '
  'the reclaim window is treated as abandoned and retried — a sender that '
  'crashes mid-send must not strand a parent notification forever.';

-- Give up after this many tries rather than retrying a permanently bad
-- address every minute until the end of time.
CREATE OR REPLACE FUNCTION church.claim_queued_notifications(_limit INTEGER DEFAULT 50)
RETURNS SETOF church.notification_log
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
BEGIN
  RETURN QUERY
  WITH claimable AS (
    SELECT n.id
    FROM church.notification_log n
    WHERE n.attempts < 5
      AND (
        n.status = 'queued'
        -- Reclaim anything a crashed sender left behind.
        OR (n.status = 'sending' AND n.claimed_at < now() - interval '5 minutes')
      )
    ORDER BY n.created_at
    LIMIT greatest(1, least(coalesce(_limit, 50), 200))
    FOR UPDATE SKIP LOCKED
  )
  UPDATE church.notification_log n
     SET status = 'sending',
         claimed_at = now(),
         attempts = n.attempts + 1
    FROM claimable c
   WHERE n.id = c.id
  RETURNING n.*;
END;
$$;

REVOKE ALL ON FUNCTION church.claim_queued_notifications(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION church.claim_queued_notifications(INTEGER) TO service_role;

CREATE OR REPLACE FUNCTION church.complete_notification(
  _id UUID, _ok BOOLEAN, _provider_message_id TEXT DEFAULT NULL,
  _error TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
BEGIN
  UPDATE church.notification_log n
     SET status = CASE
                    WHEN _ok THEN 'sent'
                    -- Back to 'queued' so the next tick retries, until the
                    -- attempt cap turns it into a permanent failure.
                    WHEN n.attempts >= 5 THEN 'failed'
                    ELSE 'queued'
                  END,
         provider_message_id = coalesce(_provider_message_id, n.provider_message_id),
         error = CASE WHEN _ok THEN NULL ELSE left(_error, 500) END,
         sent_at = CASE WHEN _ok THEN now() ELSE n.sent_at END,
         claimed_at = NULL
   WHERE n.id = _id;
END;
$$;

REVOKE ALL ON FUNCTION church.complete_notification(UUID, BOOLEAN, TEXT, TEXT)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION church.complete_notification(UUID, BOOLEAN, TEXT, TEXT)
  TO service_role;

-- ---------------------------------------------------------------------------
-- What the leader sees when a parent says "I never got a message"
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.kids_notification_log(
  _organization_id UUID, _from DATE, _to DATE)
RETURNS TABLE (
  created_at TIMESTAMPTZ,
  kind TEXT,
  recipient_name TEXT,
  destination TEXT,
  channel TEXT,
  status TEXT,
  attempts INTEGER,
  error TEXT,
  subject TEXT,
  sent_by_name TEXT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
BEGIN
  PERFORM church.assert_kids_leader(_organization_id);
  IF _from IS NULL OR _to IS NULL OR _to < _from THEN
    RAISE EXCEPTION 'invalid_date_range';
  END IF;

  RETURN QUERY
  SELECT n.created_at, n.kind, n.recipient_name,
         coalesce(n.recipient_email, n.recipient_phone),
         n.channel, n.status, n.attempts, n.error, n.subject, n.sent_by_name
  FROM church.notification_log n
  WHERE n.organization_id = _organization_id
    AND n.created_at::DATE BETWEEN _from AND _to
  ORDER BY n.created_at DESC
  LIMIT 500;
END;
$$;

GRANT EXECUTE ON FUNCTION church.kids_notification_log(UUID, DATE, DATE)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
