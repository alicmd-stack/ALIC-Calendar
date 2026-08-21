-- =====================================================
-- Simplify check-in: volunteers sign in as themselves
-- =====================================================
--
-- WHAT CHANGED AND WHY
-- --------------------
-- The original design assumed a shared tablet signed in as a long-lived
-- DEVICE account. Because auth.uid() then identified the tablet rather than a
-- person, attribution required a per-volunteer PIN and a shift token.
--
-- ALIC has chosen instead that every volunteer signs in with their own account
-- to use the site at all. That makes auth.uid() the volunteer directly, so the
-- PIN and shift-token layer is no longer buying anything and is removed from
-- the flow. The vault tables stay in place, unused, so the shared-device model
-- can be turned back on later without a migration.
--
-- WHAT THIS COSTS, stated plainly:
--   * A volunteer who walks away from a signed-in tablet leaves their session
--     open, and anything done on it is recorded as them.
--   * The two-person override rule can no longer be "a second volunteer's
--     PIN". An override now requires kids_admin, so an ordinary volunteer
--     still cannot authorise one alone — but an admin can self-authorise.
--   * Rotating volunteers each need a login.

-- ---------------------------------------------------------------------------
-- resolve_actor: a signed-in volunteer is now a first-class actor
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.resolve_actor(_shift_token TEXT DEFAULT NULL)
RETURNS church.resolved_actor
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  a church.resolved_actor;
  st church.kids_shift_tokens%ROWTYPE;
  v  church.kids_volunteers%ROWTYPE;
  p  church.people%ROWTYPE;
  _admin_orgs UUID[];
  _volunteer_orgs UUID[];
BEGIN
  -- Shift-token path retained so the shared-device model still works if ALIC
  -- turns it back on. Unused by the current UI.
  IF _shift_token IS NOT NULL AND length(_shift_token) > 0 THEN
    SELECT * INTO st FROM church.kids_shift_tokens
    WHERE token_hash = digest(_shift_token, 'sha256')
      AND ended_at IS NULL AND expires_at > now();
    IF NOT FOUND THEN
      RAISE EXCEPTION 'invalid_or_expired_shift' USING ERRCODE = '28000';
    END IF;
    IF st.issued_to_auth_user IS NOT NULL
       AND st.issued_to_auth_user IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'invalid_or_expired_shift' USING ERRCODE = '28000';
    END IF;

    SELECT * INTO v FROM church.kids_volunteers WHERE id = st.volunteer_id;
    IF NOT FOUND OR NOT v.is_active OR v.background_check_status = 'restricted' THEN
      RAISE EXCEPTION 'volunteer_not_eligible' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO p FROM church.people WHERE id = v.person_id;

    a.organization_id := st.organization_id;
    a.person_id       := v.person_id;
    a.volunteer_id    := v.id;
    a.station_id      := st.station_id;
    a.actor_name      := coalesce(p.preferred_name, p.first_name) || ' ' || p.last_name;
    a.source          := 'station';
    a.can_check_in    := true;
    a.can_check_out   := true;
    a.can_override    := v.can_override;
    RETURN a;
  END IF;

  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT array_agg(o) INTO _admin_orgs
  FROM church.my_orgs_with_any(ARRAY['kids_admin']::church.module_permission[]) AS o;

  SELECT array_agg(o) INTO _volunteer_orgs
  FROM church.my_orgs_with_any(
    ARRAY['kids_admin','kids_volunteer']::church.module_permission[]) AS o;

  IF _volunteer_orgs IS NULL OR array_length(_volunteer_orgs, 1) IS NULL THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  a.organization_id := _volunteer_orgs[1];
  -- Attribution comes from the signed-in user's own member record.
  a.person_id := (SELECT id FROM church.people
                   WHERE profile_id = auth.uid()
                     AND organization_id = a.organization_id LIMIT 1);
  a.volunteer_id := (SELECT vv.id FROM church.kids_volunteers vv
                      WHERE vv.person_id = a.person_id LIMIT 1);
  a.station_id := NULL;
  a.actor_name := coalesce(
    (SELECT full_name FROM public.profiles WHERE id = auth.uid()), 'Volunteer');
  a.source := 'user';
  a.can_check_in  := true;
  a.can_check_out := true;
  -- Only a kids_admin may authorise a checkout override. An ordinary
  -- volunteer still cannot do it alone.
  a.can_override := (_admin_orgs IS NOT NULL AND array_length(_admin_orgs, 1) > 0);
  RETURN a;
END;
$$;

-- ---------------------------------------------------------------------------
-- Open today's session in one call
-- ---------------------------------------------------------------------------
-- Replaces "an admin must pre-create an event, a session, and attach rooms".
-- Idempotent: calling it twice on the same day returns the session already
-- open rather than creating a second one.
CREATE OR REPLACE FUNCTION church.open_todays_session(
  _organization_id UUID,
  _service_label TEXT DEFAULT 'Sunday Service'
)
RETURNS TABLE (session_id UUID, service_label TEXT, was_created BOOLEAN)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _event UUID;
  _session UUID;
  _label TEXT := coalesce(NULLIF(btrim(_service_label), ''), 'Sunday Service');
  _rooms INTEGER;
BEGIN
  IF NOT church.has_permission_in_org(
       _organization_id,
       ARRAY['kids_admin','kids_volunteer']::church.module_permission[]) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  -- Already open today with this label: hand it back untouched.
  SELECT s.id INTO _session FROM church.kids_sessions s
   WHERE s.organization_id = _organization_id
     AND s.session_date = CURRENT_DATE
     AND s.service_label = _label
     AND s.status = 'open'
   LIMIT 1;
  IF _session IS NOT NULL THEN
    RETURN QUERY SELECT _session, _label, false; RETURN;
  END IF;

  SELECT e.id INTO _event FROM church.kids_events e
   WHERE e.organization_id = _organization_id AND e.is_active
   ORDER BY e.created_at LIMIT 1;

  IF _event IS NULL THEN
    INSERT INTO church.kids_events (organization_id, name, event_type, created_by_name)
    VALUES (_organization_id, 'Kids Ministry', 'weekly_service',
            coalesce((SELECT full_name FROM public.profiles WHERE id = auth.uid()), 'System'))
    RETURNING id INTO _event;
  END IF;

  INSERT INTO church.kids_sessions (
    organization_id, kids_event_id, session_date, starts_at, ends_at,
    service_label, status, opened_at)
  VALUES (
    _organization_id, _event, CURRENT_DATE,
    now() - interval '30 minutes', now() + interval '3 hours',
    _label, 'open', now())
  RETURNING id INTO _session;

  -- Attach every room marked as a check-in location. A session with no rooms
  -- has nowhere to put a child, so this is not optional.
  INSERT INTO church.kids_session_rooms (organization_id, kids_session_id, room_id)
  SELECT _organization_id, _session, rkc.room_id
  FROM church.room_kids_config rkc
  WHERE rkc.organization_id = _organization_id
    AND rkc.is_active AND rkc.is_checkin_location;
  GET DIAGNOSTICS _rooms = ROW_COUNT;

  IF _rooms = 0 THEN
    RAISE EXCEPTION 'no_classrooms_configured';
  END IF;

  RETURN QUERY SELECT _session, _label, true;
END;
$$;

CREATE OR REPLACE FUNCTION church.close_todays_sessions(_organization_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE _n INTEGER;
BEGIN
  IF NOT church.has_permission_in_org(
       _organization_id, ARRAY['kids_admin']::church.module_permission[]) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  UPDATE church.kids_sessions
     SET status = 'closed', closed_at = now()
   WHERE organization_id = _organization_id
     AND session_date = CURRENT_DATE
     AND status = 'open';
  GET DIAGNOSTICS _n = ROW_COUNT;

  PERFORM church.expire_stale_check_ins();
  RETURN _n;
END;
$$;

-- ---------------------------------------------------------------------------
-- Age bands become optional
-- ---------------------------------------------------------------------------
-- Previously a child whose age matched no configured band raised
-- 'no_matching_classroom', which made age bands a hard prerequisite. Now an
-- unmatched child falls back to the least-occupied open room and the volunteer
-- can still override. Auto-suggestion is an optimisation, not a gate.
CREATE OR REPLACE FUNCTION church.check_in_one_child(
  a church.resolved_actor,
  _kids_session_id UUID,
  _batch UUID,
  _child_person_id UUID,
  _room_id UUID,
  _dropped_off_by_person_id UUID,
  _override_capacity BOOLEAN,
  _assignment_reason TEXT
)
RETURNS UUID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  ch church.people%ROWTYPE;
  ksr church.kids_session_rooms%ROWTYPE;
  _band UUID; _band_code TEXT; _cap INTEGER; _count INTEGER;
  _room_name TEXT; _label_room TEXT; _tag INTEGER; _new UUID;
  _allergy_flag BOOLEAN := false; _allergy TEXT; _special BOOLEAN := false;
  _restricted BOOLEAN;
BEGIN
  SELECT * INTO ch FROM church.people
   WHERE id = _child_person_id AND organization_id = a.organization_id
     AND is_active AND merged_into_person_id IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'child_not_found'; END IF;

  _band := church.age_band_for(a.organization_id, ch.birth_year, ch.birth_month);
  SELECT code INTO _band_code FROM church.kids_age_bands WHERE id = _band;

  IF _room_id IS NULL THEN
    -- Prefer a room whose band matches, then the emptiest such room so
    -- parallel classrooms self-balance across a morning.
    SELECT ksr2.room_id INTO _room_id
    FROM church.kids_session_rooms ksr2
    JOIN church.room_kids_config rkc ON rkc.room_id = ksr2.room_id
    WHERE ksr2.kids_session_id = _kids_session_id
      AND ksr2.is_open AND rkc.is_active AND rkc.is_checkin_location
      AND _band IS NOT NULL AND rkc.kids_age_band_id = _band
    ORDER BY (SELECT count(*) FROM church.kids_check_ins ci
              WHERE ci.kids_session_id = _kids_session_id
                AND ci.room_id = ksr2.room_id AND ci.status = 'checked_in'),
             rkc.sort_order
    LIMIT 1;

    -- No band configured, or none matched: fall back to any open room.
    IF _room_id IS NULL THEN
      SELECT ksr3.room_id INTO _room_id
      FROM church.kids_session_rooms ksr3
      LEFT JOIN church.room_kids_config rkc3 ON rkc3.room_id = ksr3.room_id
      WHERE ksr3.kids_session_id = _kids_session_id AND ksr3.is_open
      ORDER BY (SELECT count(*) FROM church.kids_check_ins ci
                WHERE ci.kids_session_id = _kids_session_id
                  AND ci.room_id = ksr3.room_id AND ci.status = 'checked_in'),
               coalesce(rkc3.sort_order, 0)
      LIMIT 1;
    END IF;

    IF _room_id IS NULL THEN
      RAISE EXCEPTION 'no_open_classroom';
    END IF;
  END IF;

  SELECT * INTO ksr FROM church.kids_session_rooms
   WHERE kids_session_id = _kids_session_id AND room_id = _room_id FOR UPDATE;
  IF NOT FOUND OR NOT ksr.is_open THEN RAISE EXCEPTION 'room_not_open'; END IF;

  SELECT coalesce(ksr.capacity_override, rkc.capacity), r.name,
         coalesce(rkc.label_room_name, r.name)
    INTO _cap, _room_name, _label_room
  FROM public.rooms r
  LEFT JOIN church.room_kids_config rkc ON rkc.room_id = r.id
  WHERE r.id = _room_id;

  IF _cap IS NOT NULL AND NOT _override_capacity THEN
    SELECT count(*) INTO _count FROM church.kids_check_ins
     WHERE kids_session_id = _kids_session_id AND room_id = _room_id
       AND status = 'checked_in';
    IF _count >= _cap THEN RAISE EXCEPTION 'room_at_capacity'; END IF;
  END IF;

  SELECT coalesce(s.allergy_severity <> 'none', false),
         s.allergy_label_short,
         coalesce(s.special_needs_flag, false)
    INTO _allergy_flag, _allergy, _special
  FROM church.person_sensitive s WHERE s.person_id = _child_person_id;

  SELECT EXISTS (
    SELECT 1 FROM church.kids_pickup_restrictions pr
    WHERE pr.child_person_id = _child_person_id
      AND pr.effective_from <= CURRENT_DATE
      AND (pr.effective_to IS NULL OR pr.effective_to >= CURRENT_DATE)
  ) INTO _restricted;

  UPDATE church.kids_sessions
     SET next_tag_number = next_tag_number + 1
   WHERE id = _kids_session_id
  RETURNING next_tag_number - 1 INTO _tag;

  INSERT INTO church.kids_check_ins (
    organization_id, batch_id, kids_session_id, child_person_id, room_id,
    household_id, tag_number, label_child_name, label_room_name,
    label_age_band_code, label_allergy_flag, label_allergy_short,
    label_special_needs_flag, has_pickup_restriction,
    checked_in_by_station_id, checked_in_by_volunteer_id, checked_in_by_name,
    dropped_off_by_person_id, assignment_reason
  ) VALUES (
    a.organization_id, _batch, _kids_session_id, _child_person_id, _room_id,
    (SELECT household_id FROM church.kids_check_in_batches WHERE id = _batch),
    _tag,
    coalesce(ch.preferred_name, ch.first_name) || ' ' || ch.last_name,
    _label_room, _band_code, coalesce(_allergy_flag, false), _allergy,
    coalesce(_special, false), _restricted,
    a.station_id, a.volunteer_id, a.actor_name,
    _dropped_off_by_person_id, _assignment_reason
  ) RETURNING id INTO _new;

  INSERT INTO church.check_in_audit (
    organization_id, action, check_in_id, batch_id, kids_session_id,
    child_person_id, room_id, station_id, volunteer_id,
    actor_auth_user_id, actor_name, detail)
  VALUES (
    a.organization_id, 'check_in', _new, _batch, _kids_session_id,
    _child_person_id, _room_id, a.station_id, a.volunteer_id,
    auth.uid(), a.actor_name,
    jsonb_build_object('tag', _tag, 'source', a.source,
                       'capacity_overridden', _override_capacity,
                       'age_band', _band_code));
  RETURN _new;
END;
$$;

GRANT EXECUTE ON FUNCTION church.open_todays_session(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION church.close_todays_sessions(UUID) TO authenticated;

COMMENT ON FUNCTION church.resolve_actor(TEXT) IS
  'Resolves the acting person. With a shift token, from the shared-device '
  'model (retained but unused). Without one, from the signed-in user — which '
  'is the current model: volunteers sign in as themselves, so no PIN is '
  'needed. Only kids_admin gets can_override.';

NOTIFY pgrst, 'reload schema';
