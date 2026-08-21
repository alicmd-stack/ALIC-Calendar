-- =====================================================
-- Parent notifications: check-in, pick-up, and volunteer messages
-- =====================================================
--
-- Three things a parent should hear about:
--   1. their child was checked in, and to which room
--   2. their child was picked up, and when
--   3. a volunteer needs them NOW ("please come to Blossom A")
--
-- CHANNEL
-- -------
-- Email is wired today (Resend, as used by the event and budget notifications).
-- SMS is not, and the honest position is that #3 barely works over email — a
-- parent sitting in a service will not see it. So the whole thing is built
-- channel-agnostic: notification_log carries a `channel`, the send worker
-- picks an adapter, and adding SMS later means an adapter plus a consent
-- check, not a redesign.
--
-- CONSENT
-- -------
-- The consent columns exist now even though only email is live, because
-- retro-fitting consent to an existing recipient list is how churches end up
-- texting people who never agreed. In the US, SMS to congregants is governed
-- by the TCPA: opt-in must be recorded and STOP must work.

CREATE TABLE church.notification_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,

  kind TEXT NOT NULL,
  channel TEXT NOT NULL DEFAULT 'email',

  -- Who it went to. person_id may be null for a free-text recipient.
  recipient_person_id UUID REFERENCES church.people(id) ON DELETE SET NULL,
  recipient_name TEXT,
  recipient_email TEXT,
  recipient_phone TEXT,

  -- What it was about.
  child_person_id UUID REFERENCES church.people(id) ON DELETE SET NULL,
  check_in_id UUID REFERENCES church.kids_check_ins(id) ON DELETE SET NULL,
  kids_session_id UUID REFERENCES church.kids_sessions(id) ON DELETE SET NULL,

  subject TEXT,
  body TEXT NOT NULL,

  status TEXT NOT NULL DEFAULT 'queued',
  provider_message_id TEXT,
  error TEXT,
  attempts INTEGER NOT NULL DEFAULT 0,

  -- Who caused it. Null for the automatic ones.
  sent_by_person_id UUID REFERENCES church.people(id) ON DELETE SET NULL,
  sent_by_name TEXT,
  sent_by_auth_user UUID,

  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at TIMESTAMPTZ,

  CONSTRAINT chk_notification_kind CHECK (kind IN
    ('check_in', 'check_out', 'volunteer_message')),
  CONSTRAINT chk_notification_channel CHECK (channel IN ('email', 'sms')),
  CONSTRAINT chk_notification_status CHECK (status IN
    ('queued', 'sent', 'failed', 'skipped')),
  -- A message with no destination is a bug, not a row.
  CONSTRAINT chk_notification_destination
    CHECK (recipient_email IS NOT NULL OR recipient_phone IS NOT NULL)
);

CREATE INDEX idx_notification_log_org_time
  ON church.notification_log(organization_id, created_at DESC);
CREATE INDEX idx_notification_log_checkin
  ON church.notification_log(check_in_id);
CREATE INDEX idx_notification_log_queued
  ON church.notification_log(created_at) WHERE status = 'queued';

-- ---------------------------------------------------------------------------
-- Consent
-- ---------------------------------------------------------------------------
ALTER TABLE church.people
  ADD COLUMN IF NOT EXISTS notify_by_email BOOLEAN NOT NULL DEFAULT true,
  -- SMS defaults to FALSE. Texting requires opt-in; email to a member of your
  -- own church about their own child does not carry the same exposure.
  ADD COLUMN IF NOT EXISTS notify_by_sms BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS sms_consent_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS sms_opted_out_at TIMESTAMPTZ;

COMMENT ON COLUMN church.people.notify_by_sms IS
  'Opt-in, default false. Do not send SMS without sms_consent_at set and '
  'sms_opted_out_at null — US TCPA requires recorded consent and working STOP.';

-- ---------------------------------------------------------------------------
-- Who to notify about a child
-- ---------------------------------------------------------------------------
-- The people who should hear about this child: whoever dropped them off, any
-- authorised pickup adult, the household's primary contact, and — as a
-- fallback — ANY adult in their household.
--
-- That last clause matters more than it looks. Requiring a pickup
-- authorisation or an explicit primary-contact flag means a child imported
-- from a spreadsheet has neither, and nobody would be notified at all, with no
-- error to notice. Over-notifying a parent is a far better failure than
-- silently notifying no one.
--
-- Children are never notification targets, whatever the relationship says.
CREATE OR REPLACE FUNCTION church.notify_targets_for_child(
  _child_person_id UUID,
  _dropped_off_by UUID DEFAULT NULL,
  _channel TEXT DEFAULT 'email'
)
RETURNS TABLE (person_id UUID, name TEXT, email TEXT, phone TEXT)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = church, public
AS $fn$
  SELECT DISTINCT ON (p.id)
         p.id,
         coalesce(p.preferred_name, p.first_name) || ' ' || p.last_name,
         CASE WHEN _channel = 'email' AND p.notify_by_email THEN p.email END,
         CASE WHEN _channel = 'sms'
                   AND p.notify_by_sms
                   AND p.sms_consent_at IS NOT NULL
                   AND p.sms_opted_out_at IS NULL
              THEN p.phone END
  FROM church.people p
  WHERE p.is_active
    AND p.merged_into_person_id IS NULL
    AND NOT p.is_child
    AND p.id <> _child_person_id
    AND (
      p.id = _dropped_off_by
      OR p.id IN (
        SELECT a.authorized_person_id FROM church.kids_pickup_authorizations a
        WHERE a.child_person_id = _child_person_id
          AND a.effective_from <= CURRENT_DATE
          AND (a.effective_to IS NULL OR a.effective_to >= CURRENT_DATE)
      )
      OR p.id IN (
        -- Any adult sharing the child's household.
        SELECT hm2.person_id
        FROM church.household_members hm1
        JOIN church.household_members hm2 ON hm2.household_id = hm1.household_id
        WHERE hm1.person_id = _child_person_id
          AND hm1.end_date IS NULL AND hm2.end_date IS NULL
          AND hm2.person_id <> _child_person_id
      )
      OR p.id IN (
        -- Or a recorded parent/guardian, even across households.
        SELECT r.related_person_id
        FROM church.person_relationships r
        JOIN church.relationship_types rt ON rt.id = r.relationship_type_id
        WHERE r.person_id = _child_person_id
          AND rt.code IN ('parent', 'guardian')
          AND r.end_date IS NULL
      )
      OR p.id IN (
        SELECT r.person_id
        FROM church.person_relationships r
        JOIN church.relationship_types rt ON rt.id = r.relationship_type_id
        WHERE r.related_person_id = _child_person_id
          AND rt.code IN ('parent', 'guardian')
          AND r.end_date IS NULL
      )
    )
$fn$;

-- ---------------------------------------------------------------------------
-- Queue a notification
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.queue_child_notification(
  _kind TEXT,
  _check_in_id UUID,
  _body TEXT,
  _subject TEXT DEFAULT NULL,
  _channel TEXT DEFAULT 'email',
  _sent_by_person_id UUID DEFAULT NULL,
  _sent_by_name TEXT DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public
AS $$
DECLARE
  ci church.kids_check_ins%ROWTYPE;
  t RECORD;
  _n INTEGER := 0;
BEGIN
  SELECT * INTO ci FROM church.kids_check_ins WHERE id = _check_in_id;
  IF NOT FOUND THEN RETURN 0; END IF;

  FOR t IN
    SELECT * FROM church.notify_targets_for_child(
      ci.child_person_id, ci.dropped_off_by_person_id, _channel)
  LOOP
    -- No usable address for this channel: record nothing rather than a row
    -- that can never be delivered.
    CONTINUE WHEN coalesce(t.email, t.phone) IS NULL;

    INSERT INTO church.notification_log (
      organization_id, kind, channel,
      recipient_person_id, recipient_name, recipient_email, recipient_phone,
      child_person_id, check_in_id, kids_session_id,
      subject, body, sent_by_person_id, sent_by_name, sent_by_auth_user)
    VALUES (
      ci.organization_id, _kind, _channel,
      t.person_id, t.name, t.email, t.phone,
      ci.child_person_id, ci.id, ci.kids_session_id,
      _subject, _body, _sent_by_person_id, _sent_by_name, auth.uid());
    _n := _n + 1;
  END LOOP;

  RETURN _n;
END;
$$;

-- ---------------------------------------------------------------------------
-- Automatic check-in / check-out notifications
-- ---------------------------------------------------------------------------
-- Triggers rather than inline calls, so a notification cannot be forgotten by
-- a future code path that checks a child in some other way.
--
-- Deliberately does NOT name the room in the checkout message: by then the
-- child is gone, and the room is not the parent's business once they leave.
CREATE OR REPLACE FUNCTION church.notify_on_check_in()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = church, public
AS $$
BEGIN
  PERFORM church.queue_child_notification(
    'check_in', NEW.id,
    format('%s has been checked in to %s at %s.',
           NEW.label_child_name,
           coalesce(NEW.label_room_name, 'Kids Ministry'),
           to_char(NEW.checked_in_at AT TIME ZONE 'America/New_York', 'HH12:MI AM')),
    format('%s is checked in', NEW.label_child_name));
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION church.notify_on_check_out()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = church, public
AS $$
BEGIN
  -- Only a real pickup. An auto-expired row is a data-hygiene action, NOT a
  -- record that the child was collected, so it must never tell a parent their
  -- child was picked up.
  IF NEW.status <> 'checked_out' OR NEW.checkout_method = 'system_auto' THEN
    RETURN NEW;
  END IF;

  PERFORM church.queue_child_notification(
    'check_out', NEW.id,
    format('%s was picked up at %s%s.',
           NEW.label_child_name,
           to_char(NEW.checked_out_at AT TIME ZONE 'America/New_York', 'HH12:MI AM'),
           CASE WHEN NEW.picked_up_by_name IS NOT NULL
                     AND NEW.picked_up_by_name <> 'unrecorded'
                THEN ' by ' || NEW.picked_up_by_name ELSE '' END),
    format('%s has been picked up', NEW.label_child_name));
  RETURN NEW;
END;
$$;

CREATE TRIGGER kids_notify_check_in
  AFTER INSERT ON church.kids_check_ins
  FOR EACH ROW EXECUTE FUNCTION church.notify_on_check_in();

CREATE TRIGGER kids_notify_check_out
  AFTER UPDATE ON church.kids_check_ins
  FOR EACH ROW
  WHEN (OLD.status = 'checked_in' AND NEW.status = 'checked_out')
  EXECUTE FUNCTION church.notify_on_check_out();

-- ---------------------------------------------------------------------------
-- Volunteer -> parent message
-- ---------------------------------------------------------------------------
-- Returns the queued rows so the station can show the volunteer WHO was
-- contacted and how. A volunteer who believes a parent is coming when no
-- message was deliverable is worse off than one who knows to go and find them.
CREATE OR REPLACE FUNCTION church.send_parent_message(
  _check_in_id UUID,
  _message TEXT,
  _shift_token TEXT DEFAULT NULL
)
RETURNS TABLE (recipient_name TEXT, channel TEXT, destination TEXT, status TEXT)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  a church.resolved_actor;
  ci church.kids_check_ins%ROWTYPE;
  _queued INTEGER;
BEGIN
  a := church.resolve_actor(_shift_token);
  IF NOT a.can_check_in THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  IF coalesce(btrim(_message), '') = '' THEN
    RAISE EXCEPTION 'message_required';
  END IF;

  SELECT * INTO ci FROM church.kids_check_ins
   WHERE id = _check_in_id AND organization_id = a.organization_id
     AND status = 'checked_in';
  IF NOT FOUND THEN RAISE EXCEPTION 'check_in_not_active'; END IF;

  _queued := church.queue_child_notification(
    'volunteer_message', _check_in_id,
    btrim(_message),
    format('Message about %s', ci.label_child_name),
    'email', a.person_id, a.actor_name);

  INSERT INTO church.check_in_audit (
    organization_id, action, outcome, check_in_id, child_person_id,
    station_id, volunteer_id, actor_auth_user_id, actor_name, detail)
  VALUES (
    a.organization_id, 'sensitive_viewed',
    CASE WHEN _queued > 0 THEN 'success' ELSE 'error' END,
    _check_in_id, ci.child_person_id, a.station_id, a.volunteer_id,
    auth.uid(), a.actor_name,
    jsonb_build_object('action', 'volunteer_message', 'recipients', _queued));

  RETURN QUERY
  SELECT n.recipient_name, n.channel,
         coalesce(n.recipient_email, n.recipient_phone), n.status
  FROM church.notification_log n
  WHERE n.check_in_id = _check_in_id
    AND n.kind = 'volunteer_message'
    AND n.created_at > now() - interval '10 seconds'
  ORDER BY n.recipient_name;
END;
$$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
ALTER TABLE church.notification_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Kids team can view notification log"
  ON church.notification_log FOR SELECT TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['kids_admin','kids_volunteer','leadership_viewer']::church.module_permission[])));

-- No INSERT/UPDATE/DELETE policy: rows are written only by the SECURITY
-- DEFINER functions above, so a client cannot forge a message record.
GRANT SELECT ON church.notification_log TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.notification_log TO service_role;

GRANT EXECUTE ON FUNCTION church.send_parent_message(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION church.notify_targets_for_child(UUID, UUID, TEXT) TO authenticated;

COMMENT ON TABLE church.notification_log IS
  'Every parent notification, queued then sent by the send-kids-notification '
  'edge function. Channel-agnostic so SMS can be added as an adapter. Written '
  'only by SECURITY DEFINER functions — no client insert policy exists.';

NOTIFY pgrst, 'reload schema';
