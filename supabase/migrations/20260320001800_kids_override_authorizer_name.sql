-- =====================================================
-- Record who authorised an override, by name
-- =====================================================
--
-- chk_kids_check_ins_override required override_authorized_by_volunteer_id,
-- which assumed the authoriser was a volunteer with a PIN. Under the
-- signed-in model an admin authorises overrides, and an admin frequently has
-- no kids_volunteers row at all — so the constraint made an override
-- impossible to complete rather than merely unattributed.
--
-- The constraint's INTENT is right and is kept: an override must always name
-- who authorised it. It just needs to accept a name as well as a volunteer id.

ALTER TABLE church.kids_check_ins
  ADD COLUMN IF NOT EXISTS override_authorized_by_name TEXT;

ALTER TABLE church.kids_check_ins
  DROP CONSTRAINT IF EXISTS chk_kids_check_ins_override;

ALTER TABLE church.kids_check_ins
  ADD CONSTRAINT chk_kids_check_ins_override CHECK (
    checkout_method <> 'operator_override'
    OR (
      override_reason IS NOT NULL
      AND (override_authorized_by_volunteer_id IS NOT NULL
           OR override_authorized_by_name IS NOT NULL)
    )
  );

COMMENT ON COLUMN church.kids_check_ins.override_authorized_by_name IS
  'Who authorised releasing this child without the pickup code. Recorded as a '
  'name because the authoriser is a signed-in kids_admin who may not have a '
  'kids_volunteers row. An override with neither an authoriser id nor a name '
  'is rejected by chk_kids_check_ins_override.';

-- Record the authoriser's name on every override.
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
  _authorizer_name TEXT;
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
    IF NOT a.can_override THEN
      RAISE EXCEPTION 'override_requires_admin' USING ERRCODE = '42501';
    END IF;

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
      SELECT coalesce(pp.preferred_name, pp.first_name) || ' ' || pp.last_name
        INTO _authorizer_name
      FROM church.kids_volunteers vv
      JOIN church.people pp ON pp.id = vv.person_id
      WHERE vv.id = _override_authorizer_volunteer_id;
    ELSE
      -- The signed-in admin is the authoriser, on the record by name.
      _authorizer := a.volunteer_id;
      _authorizer_name := a.actor_name;
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
      RETURN;
    END IF;
    _method := 'security_code';
  END IF;

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
           override_authorized_by_volunteer_id = _authorizer,
           override_authorized_by_name = _authorizer_name
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
                              'authorized_by', coalesce(_authorizer_name, 'unknown'))
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
