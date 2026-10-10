-- =====================================================
-- A letter to the families
-- =====================================================
--
-- The ministry asked to write to its families from the app: all of them, or
-- only member families, only visitors, and so on, by the same family rule the
-- attendance report filters by (church.kids_family_status). A kids admin
-- writes the message; the greeting ("Selam Meseret,"), the blessing, the
-- verse and the church's name are added around it by send-kids-notification,
-- exactly as on every other email a parent receives.
--
-- WHO RECEIVES IT. Every parent with an email address in the household of a
-- child the message is for, as the consent reminders do: both parents, not a
-- chosen one, because the directory does not say which one reads email. Once
-- per address, however many children or households it appears in. Parents
-- who have turned email off (people.notify_by_email) are left out.
--
-- WHICH CHILDREN. Children up to 8th grade (kids_is_past_eighth_grade, as at
-- the desk), active, and, unless the writer says "every family on record",
-- checked in within the last so many days: a family that came once two years
-- ago is not written to about next Sunday.
--
-- VISITORS ARE MOSTLY UNREACHABLE BY EMAIL. On 10 October none of the 21
-- visitor parents had an email address: the desk takes a phone number. The
-- audience counts below say how many families have nobody to write to, so the
-- screen can say so rather than report "sent" to nobody.
--
-- NOTHING IS SENT HERE. Rows go into notification_log, and the minute's
-- dispatch sends them, fifty a minute, through the same sender as everything
-- else. Those queued rows wait behind any check-in, pickup or classroom email
-- (claim_queued_notifications, below), so a letter to 300 parents written on
-- Saturday night cannot hold up "Hana is checked in" on Sunday morning.
--
-- WHO MAY SEND. kids_admin, and church admins, who hold every module
-- permission. Not kids_leader: one email to every family is the ministry's
-- voice, and the ministry asked for it to be the admins'.

-- ---------------------------------------------------------- 1. the record

CREATE TABLE IF NOT EXISTS church.kids_family_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  subject TEXT NOT NULL,
  body TEXT NOT NULL,
  family TEXT NOT NULL CHECK (family IN
    ('all', 'member', 'regular_attendee', 'visitor', 'not_recorded')),
  -- NULL: every family on record, not only those who came lately.
  came_within_days INTEGER CHECK (came_within_days IS NULL OR came_within_days > 0),
  families INTEGER NOT NULL DEFAULT 0,
  emails INTEGER NOT NULL DEFAULT 0,
  sent_by UUID,
  sent_by_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_kids_family_messages_org
  ON church.kids_family_messages (organization_id, created_at DESC);
ALTER TABLE church.kids_family_messages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON church.kids_family_messages FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.kids_family_messages TO service_role;

ALTER TABLE church.notification_log
  ADD COLUMN IF NOT EXISTS family_message_id UUID
    REFERENCES church.kids_family_messages(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_notification_log_family_message
  ON church.notification_log (family_message_id) WHERE family_message_id IS NOT NULL;

ALTER TABLE church.notification_log DROP CONSTRAINT IF EXISTS chk_notification_kind;
ALTER TABLE church.notification_log ADD CONSTRAINT chk_notification_kind CHECK (kind = ANY (ARRAY[
  'check_in', 'check_out', 'volunteer_message', 'kids_auto_expired',
  'kids_access_granted', 'kids_late_pickup', 'kids_check_in_held',
  'kids_hold_presented', 'kids_incident_raised', 'kids_incident_to_parent',
  'kids_medical_updated', 'kids_consent_resign_needed',
  'kids_consent_resign_reminder', 'kids_consent_resign_overdue',
  'kids_consent_signed', 'kids_consent_filed', 'kids_records_due',
  'kids_consent_requested', 'kids_family_message']::TEXT[]));

-- ---------------------------------------------------------- 2. the audience

/**
 * Each child a message could be for, with their household and family. A
 * child in two households appears once per household. Internal.
 */
CREATE OR REPLACE FUNCTION church.kids_message_children(
  _organization_id UUID, _came_within_days INTEGER)
RETURNS TABLE (household_id UUID, family TEXT, child_person_id UUID)
LANGUAGE sql STABLE
SET search_path = church, public, extensions
AS $$
  SELECT cm.household_id, church.kids_family_status(c.id), c.id
  FROM church.people c
  JOIN church.household_members cm
    ON cm.person_id = c.id AND cm.end_date IS NULL
  WHERE c.organization_id = _organization_id
    AND c.is_child AND c.is_active AND c.merged_into_person_id IS NULL
    AND NOT church.kids_is_past_eighth_grade(
              c.organization_id, c.school_grade_id, c.birth_year, c.birth_month)
    AND (_came_within_days IS NULL OR EXISTS (
          SELECT 1 FROM church.kids_check_ins ci
          WHERE ci.child_person_id = c.id
            AND ci.organization_id = _organization_id
            AND ci.checked_in_at > now() - make_interval(days => _came_within_days)));
$$;

/**
 * The parents a message goes to: one row per email address. Internal.
 */
CREATE OR REPLACE FUNCTION church.kids_message_recipients(
  _organization_id UUID, _family TEXT, _came_within_days INTEGER)
RETURNS TABLE (person_id UUID, name TEXT, email TEXT, household_id UUID)
LANGUAGE sql STABLE
SET search_path = church, public, extensions
AS $$
  SELECT DISTINCT ON (lower(btrim(a.email)))
         a.id,
         coalesce(a.preferred_name, a.first_name) || ' ' || a.last_name,
         btrim(a.email),
         h.household_id
  FROM (SELECT DISTINCT k.household_id
        FROM church.kids_message_children(_organization_id, _came_within_days) k
        WHERE _family = 'all' OR k.family = _family) h
  JOIN church.household_members am
    ON am.household_id = h.household_id AND am.end_date IS NULL
  JOIN church.people a ON a.id = am.person_id
  WHERE NOT a.is_child AND a.is_active AND a.merged_into_person_id IS NULL
    AND a.notify_by_email AND a.email IS NOT NULL AND btrim(a.email) <> ''
  ORDER BY lower(btrim(a.email)), a.id;
$$;

REVOKE ALL ON FUNCTION church.kids_message_children(UUID, INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION church.kids_message_recipients(UUID, TEXT, INTEGER) FROM PUBLIC, anon, authenticated;

/**
 * How many families and parents each choice would reach, for the composer:
 * every family together, then each kind. `families` is every family with a
 * child in the audience; `reachable` those with at least one parent to email.
 */
CREATE OR REPLACE FUNCTION church.kids_family_message_audience(
  _organization_id UUID, _came_within_days INTEGER)
RETURNS TABLE (family TEXT, families INTEGER, reachable INTEGER, emails INTEGER)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
BEGIN
  IF NOT church.has_permission_in_org(
           _organization_id, ARRAY['kids_admin']::church.module_permission[]) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH kids AS (
    SELECT DISTINCT k.household_id, k.family
    FROM church.kids_message_children(_organization_id, _came_within_days) k
  ),
  inbox AS (
    SELECT DISTINCT am.household_id, lower(btrim(a.email)) AS email
    FROM church.household_members am
    JOIN church.people a ON a.id = am.person_id
    WHERE am.household_id IN (SELECT kids.household_id FROM kids)
      AND am.end_date IS NULL
      AND NOT a.is_child AND a.is_active AND a.merged_into_person_id IS NULL
      AND a.notify_by_email AND a.email IS NOT NULL AND btrim(a.email) <> ''
  )
  SELECT f.code,
         (SELECT count(DISTINCT k.household_id) FROM kids k
           WHERE f.code = 'all' OR k.family = f.code)::INTEGER,
         (SELECT count(DISTINCT k.household_id) FROM kids k
           WHERE (f.code = 'all' OR k.family = f.code)
             AND EXISTS (SELECT 1 FROM inbox i WHERE i.household_id = k.household_id))::INTEGER,
         (SELECT count(DISTINCT i.email) FROM kids k
            JOIN inbox i ON i.household_id = k.household_id
           WHERE f.code = 'all' OR k.family = f.code)::INTEGER
  FROM unnest(ARRAY['all', 'member', 'regular_attendee', 'visitor', 'not_recorded'])
       WITH ORDINALITY AS f(code, n)
  ORDER BY f.n;
END;
$$;

REVOKE ALL ON FUNCTION church.kids_family_message_audience(UUID, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION church.kids_family_message_audience(UUID, INTEGER) TO authenticated;

-- ---------------------------------------------------------- 3. sending

/**
 * Queue the message to every parent in the audience, or, with _test, to the
 * writer alone, marked "[Test]" and not recorded as sent.
 */
CREATE OR REPLACE FUNCTION church.kids_send_family_message(
  _organization_id UUID, _family TEXT, _came_within_days INTEGER,
  _subject TEXT, _body TEXT, _test BOOLEAN DEFAULT false)
RETURNS TABLE (message_id UUID, families INTEGER, emails INTEGER)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _actor UUID := auth.uid();
  _actor_name TEXT;
  _actor_email TEXT;
  _subject_clean TEXT := btrim(coalesce(_subject, ''));
  _body_clean TEXT := btrim(coalesce(_body, ''));
  _id UUID;
  _emails INTEGER;
  _families INTEGER;
BEGIN
  IF NOT church.has_permission_in_org(
           _organization_id, ARRAY['kids_admin']::church.module_permission[]) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;
  IF _family IS NULL OR _family NOT IN
       ('all', 'member', 'regular_attendee', 'visitor', 'not_recorded') THEN
    RAISE EXCEPTION 'invalid_family';
  END IF;
  IF _came_within_days IS NOT NULL AND _came_within_days NOT BETWEEN 1 AND 3660 THEN
    RAISE EXCEPTION 'invalid_reach';
  END IF;
  IF length(_subject_clean) = 0 OR length(_subject_clean) > 150 THEN
    RAISE EXCEPTION 'invalid_subject';
  END IF;
  IF length(_body_clean) = 0 OR length(_body_clean) > 10000 THEN
    RAISE EXCEPTION 'invalid_body';
  END IF;
  -- The composer's prompt, left in. The screen stops this too; this is for a
  -- screen from before the check, or a hurried press.
  IF position('[Write your message here' IN _body_clean) > 0 THEN
    RAISE EXCEPTION 'placeholder_left_in';
  END IF;

  SELECT p.full_name, p.email INTO _actor_name, _actor_email
  FROM public.profiles p WHERE p.id = _actor;
  _actor_name := coalesce(nullif(btrim(_actor_name), ''), 'Kids Ministry');

  IF _test THEN
    IF _actor_email IS NULL OR btrim(_actor_email) = '' THEN
      RAISE EXCEPTION 'no_email_for_test';
    END IF;
    INSERT INTO church.notification_log (
      organization_id, kind, channel, recipient_name, recipient_email,
      subject, body, sent_by_name, sent_by_auth_user)
    VALUES (_organization_id, 'kids_family_message', 'email', _actor_name,
            btrim(_actor_email), '[Test] ' || _subject_clean, _body_clean,
            _actor_name, _actor);
    RETURN QUERY SELECT NULL::UUID, 0, 1;
    RETURN;
  END IF;

  -- A second press, or the same letter from a second tab, within ten
  -- minutes is refused rather than sent twice.
  IF EXISTS (
    SELECT 1 FROM church.kids_family_messages m
    WHERE m.organization_id = _organization_id
      AND m.family = _family
      AND m.subject = _subject_clean
      AND m.body = _body_clean
      AND m.created_at > now() - interval '10 minutes') THEN
    RAISE EXCEPTION 'already_sent';
  END IF;

  INSERT INTO church.kids_family_messages (
    organization_id, subject, body, family, came_within_days, sent_by, sent_by_name)
  VALUES (_organization_id, _subject_clean, _body_clean, _family, _came_within_days,
          _actor, _actor_name)
  RETURNING id INTO _id;

  WITH r AS (
    SELECT * FROM church.kids_message_recipients(_organization_id, _family, _came_within_days)
  ),
  queued AS (
    INSERT INTO church.notification_log (
      organization_id, kind, channel, recipient_person_id, recipient_name,
      recipient_email, subject, body, sent_by_name, sent_by_auth_user,
      family_message_id)
    SELECT _organization_id, 'kids_family_message', 'email', r.person_id, r.name,
           r.email, _subject_clean, _body_clean, _actor_name, _actor, _id
    FROM r
    RETURNING 1
  )
  SELECT (SELECT count(*) FROM queued), (SELECT count(DISTINCT r.household_id) FROM r)
  INTO _emails, _families;

  -- Nobody to write to: the whole call is undone, the record with it, rather
  -- than a "sent" message that reached no one.
  IF _emails = 0 THEN
    RAISE EXCEPTION 'no_recipients';
  END IF;

  UPDATE church.kids_family_messages m
     SET families = _families, emails = _emails
   WHERE m.id = _id;

  RETURN QUERY SELECT _id, _families, _emails;
END;
$$;

REVOKE ALL ON FUNCTION church.kids_send_family_message(UUID, TEXT, INTEGER, TEXT, TEXT, BOOLEAN)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION church.kids_send_family_message(UUID, TEXT, INTEGER, TEXT, TEXT, BOOLEAN)
  TO authenticated;

/** What has been sent, newest first, and how far each has got. */
CREATE OR REPLACE FUNCTION church.kids_family_messages_sent(
  _organization_id UUID, _limit INTEGER DEFAULT 50)
RETURNS TABLE (
  id UUID, created_at TIMESTAMPTZ, subject TEXT, body TEXT, family TEXT,
  came_within_days INTEGER, families INTEGER, emails INTEGER, sent_by_name TEXT,
  delivered INTEGER, failed INTEGER, pending INTEGER)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
BEGIN
  IF NOT church.has_permission_in_org(
           _organization_id, ARRAY['kids_admin']::church.module_permission[]) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT m.id, m.created_at, m.subject, m.body, m.family, m.came_within_days,
         m.families, m.emails, m.sent_by_name,
         count(n.id) FILTER (WHERE n.status = 'sent')::INTEGER,
         count(n.id) FILTER (WHERE n.status IN ('failed', 'skipped'))::INTEGER,
         count(n.id) FILTER (WHERE n.status IN ('queued', 'sending'))::INTEGER
  FROM church.kids_family_messages m
  LEFT JOIN church.notification_log n ON n.family_message_id = m.id
  WHERE m.organization_id = _organization_id
  GROUP BY m.id
  ORDER BY m.created_at DESC
  LIMIT greatest(1, least(coalesce(_limit, 50), 200));
END;
$$;

REVOKE ALL ON FUNCTION church.kids_family_messages_sent(UUID, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION church.kids_family_messages_sent(UUID, INTEGER) TO authenticated;

-- ---------------------------------------------------------- 4. the queue's order

-- Unchanged from the deployed definition except the ORDER BY: letters to
-- every family and consent reminders go after everything else waiting, so a
-- few hundred of them never stand in front of a check-in or pickup email.
-- Same signature, so CREATE OR REPLACE keeps its grants.
CREATE OR REPLACE FUNCTION church.claim_queued_notifications(_limit integer DEFAULT 50)
 RETURNS SETOF church.notification_log
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'church', 'public', 'extensions'
AS $function$
BEGIN
  -- One sender at a time. The lock makes the check below and the claim one
  -- step; a run that finds another mid-batch hands out nothing, and the next
  -- minute's run picks the rows up.
  PERFORM pg_advisory_xact_lock(hashtext('church.claim_queued_notifications'));
  IF EXISTS (SELECT 1 FROM church.notification_log n
              WHERE n.status = 'sending'
                AND n.claimed_at > now() - interval '2 minutes') THEN
    RETURN;
  END IF;

  -- A check-in, pickup or urgent classroom notice three hours late is worse
  -- than none: "Hana is checked in" on Monday morning helps nobody.
  UPDATE church.notification_log n
     SET status = 'skipped',
         error = 'not sent: more than 3 hours late, so no longer useful'
   WHERE n.status = 'queued'
     AND n.kind IN ('check_in', 'check_out', 'volunteer_message')
     AND n.created_at < now() - interval '3 hours';

  RETURN QUERY
  WITH claimable AS (
    SELECT n.id
    FROM church.notification_log n
    WHERE n.attempts < 5
      AND (n.not_before IS NULL OR n.not_before <= now())
      AND (
        n.status = 'queued'
        OR (n.status = 'sending' AND n.claimed_at < now() - interval '5 minutes')
      )
    -- Bulk last: false sorts before true.
    ORDER BY (n.kind IN ('kids_family_message', 'kids_consent_requested')), n.created_at
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
$function$;

NOTIFY pgrst, 'reload schema';
