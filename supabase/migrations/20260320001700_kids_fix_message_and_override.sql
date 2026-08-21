-- =====================================================
-- Two fixes found by testing the notification flow
-- =====================================================
--
-- 1. send_parent_message referenced `status` unqualified while also declaring
--    it as a RETURNS TABLE output column, which plpgsql rejects as ambiguous.
--    This is the third time this class of bug has appeared in this schema; a
--    scan of every RETURNS TABLE function in `church` confirms the others all
--    qualify their references, so this is the last one.
--
-- 2. check_out_children still demanded a second volunteer's PIN to authorise
--    an override. PINs were removed when volunteers moved to signing in as
--    themselves, so that path had become impossible to satisfy — an override
--    could never be completed at all.
--
--    An override now requires an actor with can_override, which
--    resolve_actor() grants only to kids_admin. So an ordinary volunteer still
--    cannot release a child without a code on their own authority; they need
--    an admin. The PIN parameters are kept so existing callers still compile,
--    and are honoured when supplied.

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

  -- Qualified: `status` is also an output column of this function.
  SELECT * INTO ci FROM church.kids_check_ins k
   WHERE k.id = _check_in_id
     AND k.organization_id = a.organization_id
     AND k.status = 'checked_in';
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
-- Checkout: override authority without PINs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.check_out_children(
  _check_in_ids UUID[],
  _presented TEXT DEFAULT NULL,
  _shift_token TEXT DEFAULT NULL,
  _picked_up_by_person_id UUID DEFAULT NULL,
  _picked_up_by_name TEXT DEFAULT NULL,
  _override_reason TEXT DEFAULT NULL,
  _override_verification TEXT DEFAULT NULL,
  _override_authorizer_volunteer_id UUID DEFAULT NULL,
  _override_authorizer_pin TEXT DEFAULT NULL
)
RETURNS TABLE (check_in_id UUID, child_name TEXT, checked_out_at TIMESTAMPTZ)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  a church.resolved_actor;
  ci church.kids_check_ins%ROWTYPE;
  sec church.kids_check_in_secrets%ROWTYPE;
  _method TEXT;
  _authorizer UUID;
  _auth_hash TEXT;
  _restricted BOOLEAN;
  _id UUID;
BEGIN
  a := church.resolve_actor(_shift_token);
  IF NOT a.can_check_out THEN
    RAISE EXCEPTION 'not_permitted_to_check_out' USING ERRCODE = '42501';
  END IF;

  IF _check_in_ids IS NULL OR array_length(_check_in_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'no_check_ins_supplied';
  END IF;

  SELECT * INTO ci FROM church.kids_check_ins k
   WHERE k.id = _check_in_ids[1] AND k.organization_id = a.organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'check_in_not_found'; END IF;

  IF _override_reason IS NOT NULL THEN
    -- Releasing a child without the pickup code requires override authority,
    -- which only a kids_admin has. An ordinary volunteer cannot do this alone.
    IF NOT a.can_override THEN
      RAISE EXCEPTION 'override_requires_admin' USING ERRCODE = '42501';
    END IF;

    -- If a second volunteer's PIN IS supplied, verify it and record them as
    -- the authoriser. Optional now, but still honoured.
    IF _override_authorizer_volunteer_id IS NOT NULL
       AND _override_authorizer_pin IS NOT NULL THEN
      SELECT p.pin_hash INTO _auth_hash
      FROM church.kids_volunteer_pins p
      JOIN church.kids_volunteers v ON v.id = p.volunteer_id
      WHERE p.volunteer_id = _override_authorizer_volunteer_id
        AND v.organization_id = a.organization_id
        AND v.is_active AND v.can_override
        AND v.background_check_status <> 'restricted';

      IF _auth_hash IS NULL OR _auth_hash <> crypt(_override_authorizer_pin, _auth_hash) THEN
        RAISE EXCEPTION 'override_authorization_failed' USING ERRCODE = '28000';
      END IF;
      _authorizer := _override_authorizer_volunteer_id;
    ELSE
      -- Otherwise the signed-in admin is the authoriser, on the record.
      _authorizer := a.volunteer_id;
    END IF;

    _method := 'operator_override';
  ELSE
    SELECT * INTO sec FROM church.kids_check_in_secrets s
    WHERE s.batch_id = ci.batch_id
      AND s.consumed_at IS NULL
      AND s.expires_at > now()
      AND (s.locked_until IS NULL OR s.locked_until <= now())
      AND (s.code_hash = church.hash_pickup(church.normalize_pickup_code(_presented))
        OR s.token_hash = church.hash_pickup(btrim(coalesce(_presented, ''))));

    IF NOT FOUND THEN
      INSERT INTO church.check_in_audit
        (organization_id, action, outcome, check_in_id, child_person_id,
         station_id, volunteer_id, actor_auth_user_id, actor_name)
      VALUES (a.organization_id, 'code_failed', 'denied', ci.id, ci.child_person_id,
              a.station_id, a.volunteer_id, auth.uid(), a.actor_name);
      RETURN;   -- zero rows; see the note in 20260320001000
    END IF;
    _method := 'security_code';
  END IF;

  -- KID-014: a restricted person is never released to, on any path. There is
  -- deliberately no override that permits it.
  IF _picked_up_by_person_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM church.kids_pickup_restrictions pr
      WHERE pr.child_person_id = ci.child_person_id
        AND pr.restricted_person_id = _picked_up_by_person_id
        AND pr.effective_from <= CURRENT_DATE
        AND (pr.effective_to IS NULL OR pr.effective_to >= CURRENT_DATE)
    ) INTO _restricted;

    IF _restricted THEN
      INSERT INTO church.check_in_audit
        (organization_id, action, outcome, check_in_id, child_person_id,
         station_id, volunteer_id, actor_auth_user_id, actor_name, detail)
      VALUES (a.organization_id, 'restricted_pickup_attempt', 'denied', ci.id,
              ci.child_person_id, a.station_id, a.volunteer_id, auth.uid(),
              a.actor_name,
              jsonb_build_object('attempted_person_id', _picked_up_by_person_id));
      RETURN;
    END IF;
  END IF;

  FOREACH _id IN ARRAY _check_in_ids LOOP
    UPDATE church.kids_check_ins k
       SET status = 'checked_out',
           checked_out_at = now(),
           checked_out_by_station_id = a.station_id,
           checked_out_by_volunteer_id = a.volunteer_id,
           checked_out_by_name = a.actor_name,
           picked_up_by_person_id = _picked_up_by_person_id,
           picked_up_by_name = coalesce(_picked_up_by_name, 'unrecorded'),
           checkout_method = _method,
           override_reason = _override_reason,
           override_verification = _override_verification,
           override_authorized_by_volunteer_id = _authorizer
     WHERE k.id = _id
       AND k.organization_id = a.organization_id
       AND k.status = 'checked_in';

    INSERT INTO church.check_in_audit
      (organization_id, action, check_in_id, batch_id, kids_session_id,
       child_person_id, station_id, volunteer_id, actor_auth_user_id,
       actor_name, detail)
    SELECT a.organization_id,
           CASE WHEN _method = 'operator_override' THEN 'override' ELSE 'check_out' END,
           c.id, c.batch_id, c.kids_session_id, c.child_person_id,
           a.station_id, a.volunteer_id, auth.uid(), a.actor_name,
           jsonb_build_object('method', _method,
                              'picked_up_by', _picked_up_by_name,
                              'override_reason', _override_reason,
                              'verification', _override_verification,
                              'authorized_by', _authorizer)
    FROM church.kids_check_ins c WHERE c.id = _id;
  END LOOP;

  UPDATE church.kids_check_in_secrets s
     SET consumed_at = now()
   WHERE s.batch_id = ci.batch_id
     AND NOT EXISTS (SELECT 1 FROM church.kids_check_ins c
                     WHERE c.batch_id = ci.batch_id AND c.status = 'checked_in');

  RETURN QUERY
  SELECT c.id, c.label_child_name, c.checked_out_at
  FROM church.kids_check_ins c
  WHERE c.id = ANY(_check_in_ids) AND c.status = 'checked_out';
END;
$$;

GRANT EXECUTE ON FUNCTION church.check_out_children(
  UUID[], TEXT, TEXT, UUID, TEXT, TEXT, TEXT, UUID, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
