-- =====================================================
-- Kids Ministry leader view
-- =====================================================
--
-- The check-in station shows a volunteer only what they need at the desk:
-- last initial, masked phone, no birthday. The ministry LEADER needs the
-- opposite — full names, who is in which room, who is staffing it, which
-- children never got collected, and what happened over past Sundays.
--
-- These are separate functions rather than widened station functions,
-- precisely so that widening the leader's view can never widen the tablet's.
-- Every one of them requires kids_admin or leadership_viewer; a
-- kids_volunteer signed in at a desk gets nothing from any of them.

-- ---------------------------------------------------------------------------
-- Who is allowed to see the leader view
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.kids_leader_orgs()
RETURNS SETOF UUID
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = church, public
AS $$
  SELECT church.my_orgs_with_any(
    ARRAY['kids_admin', 'leadership_viewer']::church.module_permission[]);
$$;

GRANT EXECUTE ON FUNCTION church.kids_leader_orgs() TO authenticated;

CREATE OR REPLACE FUNCTION church.assert_kids_leader(_organization_id UUID)
RETURNS VOID
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public
AS $$
BEGIN
  IF _organization_id IS NULL
     OR _organization_id NOT IN (SELECT church.kids_leader_orgs()) THEN
    RAISE EXCEPTION 'not_a_kids_leader' USING ERRCODE = '42501';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION church.assert_kids_leader(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- The live board: one row per open classroom, right now
-- ---------------------------------------------------------------------------
--
-- This is the screen the leader keeps open during a service. Ratio and
-- capacity are reported, never enforced — check-in deliberately does not turn
-- a child away, so the leader's job is to see the breach and move a volunteer.
CREATE OR REPLACE FUNCTION church.kids_live_board(_organization_id UUID)
RETURNS TABLE (
  kids_session_id UUID,
  session_label TEXT,
  session_date DATE,
  room_id UUID,
  room_name TEXT,
  label_room_name TEXT,
  age_band_code TEXT,
  age_band_name TEXT,
  capacity INTEGER,
  ratio_children_per_volunteer INTEGER,
  checked_in_count BIGINT,
  checked_out_count BIGINT,
  volunteer_count BIGINT,
  allergy_count BIGINT,
  restriction_count BIGINT,
  over_capacity BOOLEAN,
  over_ratio BOOLEAN
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
BEGIN
  PERFORM church.assert_kids_leader(_organization_id);

  RETURN QUERY
  SELECT
    s.id,
    s.service_label,
    s.session_date,
    r.id,
    r.name,
    rk.label_room_name,
    b.code,
    b.display_name,
    coalesce(sr.capacity_override, rk.capacity),
    rk.ratio_children_per_volunteer,
    coalesce(live.n, 0),
    coalesce(gone.n, 0),
    coalesce(staff.n, 0),
    coalesce(live.allergies, 0),
    coalesce(live.restrictions, 0),
    -- A capacity or ratio of NULL means "not configured", which is not a
    -- breach. Only a configured limit can be exceeded.
    coalesce(sr.capacity_override, rk.capacity) IS NOT NULL
      AND coalesce(live.n, 0) > coalesce(sr.capacity_override, rk.capacity),
    rk.ratio_children_per_volunteer IS NOT NULL
      AND coalesce(live.n, 0) >
          coalesce(staff.n, 0) * rk.ratio_children_per_volunteer
  FROM church.kids_sessions s
  JOIN church.kids_session_rooms sr
    ON sr.kids_session_id = s.id AND sr.is_open
  JOIN public.rooms r ON r.id = sr.room_id
  LEFT JOIN church.room_kids_config rk ON rk.room_id = r.id
  LEFT JOIN church.kids_age_bands b ON b.id = rk.kids_age_band_id
  LEFT JOIN LATERAL (
    SELECT count(*) AS n,
           count(*) FILTER (WHERE c.label_allergy_flag) AS allergies,
           count(*) FILTER (WHERE c.has_pickup_restriction) AS restrictions
    FROM church.kids_check_ins c
    WHERE c.kids_session_id = s.id AND c.room_id = r.id
      AND c.status = 'checked_in'
  ) live ON true
  LEFT JOIN LATERAL (
    SELECT count(*) AS n FROM church.kids_check_ins c
    WHERE c.kids_session_id = s.id AND c.room_id = r.id
      AND c.status = 'checked_out'
  ) gone ON true
  LEFT JOIN LATERAL (
    SELECT count(*) AS n FROM church.kids_session_staffing st
    WHERE st.kids_session_id = s.id AND st.room_id = r.id
      AND st.ended_at IS NULL
  ) staff ON true
  WHERE s.organization_id = _organization_id
    AND s.status = 'open'
  ORDER BY s.session_date, rk.sort_order NULLS LAST, r.name;
END;
$$;

GRANT EXECUTE ON FUNCTION church.kids_live_board(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Room roster: every child in one room, named
-- ---------------------------------------------------------------------------
--
-- Unlike station_search_households this returns the child's FULL name and the
-- guardian who dropped them off, because the leader is the person who has to
-- phone that guardian. It reports whether medical detail EXISTS but never the
-- detail itself — reading that still goes through station_child_safety_card,
-- which writes an audit row (KID-025).
CREATE OR REPLACE FUNCTION church.kids_room_roster(
  _kids_session_id UUID, _room_id UUID DEFAULT NULL)
RETURNS TABLE (
  check_in_id UUID,
  child_person_id UUID,
  child_name TEXT,
  tag_number INTEGER,
  room_id UUID,
  room_name TEXT,
  status TEXT,
  checked_in_at TIMESTAMPTZ,
  checked_out_at TIMESTAMPTZ,
  checked_in_by_name TEXT,
  checked_out_by_name TEXT,
  dropped_off_by_name TEXT,
  picked_up_by_name TEXT,
  guardian_phone TEXT,
  has_allergy BOOLEAN,
  has_restriction BOOLEAN,
  checkout_method TEXT,
  minutes_in_room INTEGER
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _org UUID;
BEGIN
  SELECT s.organization_id INTO _org
  FROM church.kids_sessions s WHERE s.id = _kids_session_id;
  PERFORM church.assert_kids_leader(_org);

  RETURN QUERY
  SELECT
    c.id,
    c.child_person_id,
    c.label_child_name,
    c.tag_number,
    c.room_id,
    r.name,
    c.status,
    c.checked_in_at,
    c.checked_out_at,
    c.checked_in_by_name,
    c.checked_out_by_name,
    dropper.name,
    c.picked_up_by_name,
    guardian.phone,
    c.label_allergy_flag,
    c.has_pickup_restriction,
    c.checkout_method,
    (EXTRACT(EPOCH FROM (coalesce(c.checked_out_at, now()) - c.checked_in_at))
       / 60)::INTEGER
  FROM church.kids_check_ins c
  LEFT JOIN public.rooms r ON r.id = c.room_id
  LEFT JOIN LATERAL (
    SELECT coalesce(d.preferred_name, d.first_name) || ' ' || d.last_name AS name
    FROM church.people d WHERE d.id = c.dropped_off_by_person_id
  ) dropper ON true
  LEFT JOIN LATERAL (
    SELECT p.phone
    FROM church.household_members hm_child
    JOIN church.household_members hm_adult
      ON hm_adult.household_id = hm_child.household_id
     AND hm_adult.end_date IS NULL
    JOIN church.people p
      ON p.id = hm_adult.person_id AND NOT p.is_child AND p.phone IS NOT NULL
    WHERE hm_child.person_id = c.child_person_id
      AND hm_child.end_date IS NULL
    ORDER BY hm_adult.is_primary_contact DESC
    LIMIT 1
  ) guardian ON true
  WHERE c.kids_session_id = _kids_session_id
    AND (_room_id IS NULL OR c.room_id = _room_id)
  ORDER BY c.status, c.tag_number;
END;
$$;

GRANT EXECUTE ON FUNCTION church.kids_room_roster(UUID, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Attendance history
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.kids_attendance_report(
  _organization_id UUID, _from DATE, _to DATE)
RETURNS TABLE (
  session_date DATE,
  service_label TEXT,
  room_name TEXT,
  age_band_name TEXT,
  children BIGINT,
  first_time_visitors BIGINT,
  volunteers BIGINT,
  overrides BIGINT,
  not_checked_out BIGINT,
  avg_minutes INTEGER
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
  SELECT
    s.session_date,
    s.service_label,
    coalesce(r.name, 'Unassigned'),
    b.display_name,
    count(DISTINCT c.child_person_id),
    -- First visit = this child has no earlier check-in anywhere in the org.
    count(DISTINCT c.child_person_id) FILTER (
      WHERE NOT EXISTS (
        SELECT 1 FROM church.kids_check_ins prior
        JOIN church.kids_sessions ps ON ps.id = prior.kids_session_id
        WHERE prior.child_person_id = c.child_person_id
          AND ps.organization_id = _organization_id
          AND ps.session_date < s.session_date)),
    (SELECT count(DISTINCT st.person_id) FROM church.kids_session_staffing st
      WHERE st.kids_session_id = s.id
        AND (st.room_id = r.id OR (st.room_id IS NULL AND r.id IS NULL))),
    count(*) FILTER (WHERE c.checkout_method = 'operator_override'),
    count(*) FILTER (WHERE c.status = 'checked_in'),
    (avg(EXTRACT(EPOCH FROM (c.checked_out_at - c.checked_in_at)) / 60)
      FILTER (WHERE c.checked_out_at IS NOT NULL))::INTEGER
  FROM church.kids_sessions s
  JOIN church.kids_check_ins c ON c.kids_session_id = s.id
  LEFT JOIN public.rooms r ON r.id = c.room_id
  LEFT JOIN church.room_kids_config rk ON rk.room_id = r.id
  LEFT JOIN church.kids_age_bands b ON b.id = rk.kids_age_band_id
  WHERE s.organization_id = _organization_id
    AND s.session_date BETWEEN _from AND _to
  GROUP BY s.id, s.session_date, s.service_label, r.id, r.name, b.display_name
  ORDER BY s.session_date DESC, r.name;
END;
$$;

GRANT EXECUTE ON FUNCTION church.kids_attendance_report(UUID, DATE, DATE)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Exceptions: the report the leader actually has to act on
-- ---------------------------------------------------------------------------
--
-- Overrides, blocked restricted-pickup attempts, failed codes and children who
-- were never checked out. Sourced from check_in_audit rather than from
-- kids_check_ins, because a denied attempt leaves no check-in row at all — a
-- report built only from check-ins would show a clean sheet on the very
-- Sundays that most need review.
CREATE OR REPLACE FUNCTION church.kids_exceptions_report(
  _organization_id UUID, _from DATE, _to DATE)
RETURNS TABLE (
  occurred_at TIMESTAMPTZ,
  session_date DATE,
  action TEXT,
  outcome TEXT,
  child_name TEXT,
  room_name TEXT,
  actor_name TEXT,
  reason TEXT
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
  SELECT
    au.created_at,
    s.session_date,
    au.action,
    au.outcome,
    coalesce(p.first_name || ' ' || p.last_name, '(unknown child)'),
    r.name,
    au.actor_name,
    coalesce(
      au.detail->>'override_reason',
      au.detail->>'reason',
      CASE au.action
        WHEN 'restricted_pickup_attempt'
          THEN 'Blocked: person is on the restricted list'
        WHEN 'code_failed' THEN 'Pickup code did not match'
        ELSE NULL
      END)
  FROM church.check_in_audit au
  LEFT JOIN church.kids_sessions s ON s.id = au.kids_session_id
  LEFT JOIN church.people p ON p.id = au.child_person_id
  LEFT JOIN church.kids_check_ins c ON c.id = au.check_in_id
  LEFT JOIN public.rooms r ON r.id = c.room_id
  WHERE au.organization_id = _organization_id
    AND au.created_at::DATE BETWEEN _from AND _to
    AND (au.action IN ('override', 'restricted_pickup_attempt', 'code_failed',
                       'pin_failed', 'transfer')
         OR au.outcome = 'denied')
  ORDER BY au.created_at DESC
  LIMIT 500;
END;
$$;

GRANT EXECUTE ON FUNCTION church.kids_exceptions_report(UUID, DATE, DATE)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Classroom configuration, edited by the leader instead of by migration
-- ---------------------------------------------------------------------------
--
-- Migration 20260320001500 seeded PROVISIONAL room/age assignments as an
-- explicit placeholder. This is how the ministry replaces them without one.
CREATE OR REPLACE FUNCTION church.set_room_kids_config(
  _room_id UUID,
  _is_checkin_location BOOLEAN,
  _kids_age_band_id UUID DEFAULT NULL,
  _capacity INTEGER DEFAULT NULL,
  _ratio INTEGER DEFAULT NULL,
  _label_room_name TEXT DEFAULT NULL,
  _sort_order INTEGER DEFAULT 0
)
RETURNS church.room_kids_config
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _org UUID;
  _row church.room_kids_config;
BEGIN
  SELECT r.organization_id INTO _org FROM public.rooms r WHERE r.id = _room_id;
  IF _org IS NULL THEN RAISE EXCEPTION 'room_not_found'; END IF;

  -- Editing configuration is admin-only; leadership_viewer is read-only.
  IF _org NOT IN (SELECT church.my_orgs_with_any(
       ARRAY['kids_admin']::church.module_permission[])) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  IF _kids_age_band_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM church.kids_age_bands b
                     WHERE b.id = _kids_age_band_id
                       AND b.organization_id = _org) THEN
    RAISE EXCEPTION 'age_band_belongs_to_another_branch';
  END IF;

  -- Validate up front so the leader gets a sentence rather than a raw check
  -- constraint violation. The 20-character cap is not arbitrary: this name is
  -- what prints on a 62mm label, and a longer one wraps or truncates.
  IF _label_room_name IS NOT NULL AND char_length(_label_room_name) > 20 THEN
    RAISE EXCEPTION 'label_room_name_too_long'
      USING DETAIL = format('%s characters; the printed label fits 20',
                            char_length(_label_room_name));
  END IF;

  IF _capacity IS NOT NULL AND _capacity <= 0 THEN
    RAISE EXCEPTION 'capacity_must_be_positive';
  END IF;

  IF _ratio IS NOT NULL AND _ratio <= 0 THEN
    RAISE EXCEPTION 'ratio_must_be_positive';
  END IF;

  INSERT INTO church.room_kids_config (
    room_id, organization_id, is_checkin_location, kids_age_band_id,
    capacity, ratio_children_per_volunteer, label_room_name, sort_order)
  VALUES (_room_id, _org, _is_checkin_location, _kids_age_band_id,
          _capacity, _ratio, _label_room_name, coalesce(_sort_order, 0))
  ON CONFLICT (room_id) DO UPDATE SET
    is_checkin_location = EXCLUDED.is_checkin_location,
    kids_age_band_id = EXCLUDED.kids_age_band_id,
    capacity = EXCLUDED.capacity,
    ratio_children_per_volunteer = EXCLUDED.ratio_children_per_volunteer,
    label_room_name = EXCLUDED.label_room_name,
    sort_order = EXCLUDED.sort_order,
    updated_at = now()
  RETURNING * INTO _row;

  RETURN _row;
END;
$$;

GRANT EXECUTE ON FUNCTION church.set_room_kids_config(
  UUID, BOOLEAN, UUID, INTEGER, INTEGER, TEXT, INTEGER) TO authenticated;

-- ---------------------------------------------------------------------------
-- Volunteer assignment
-- ---------------------------------------------------------------------------
--
-- was_background_check_current is snapshotted at assignment time rather than
-- joined at read time: it records what was known on the day, so a check that
-- lapses later cannot silently rewrite the history of a past Sunday.
CREATE OR REPLACE FUNCTION church.assign_session_staff(
  _kids_session_id UUID,
  _person_id UUID,
  _room_id UUID DEFAULT NULL,
  _role TEXT DEFAULT 'classroom_volunteer'
)
RETURNS church.kids_session_staffing
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _org UUID;
  _bg_current BOOLEAN;
  _row church.kids_session_staffing;
BEGIN
  SELECT s.organization_id INTO _org
  FROM church.kids_sessions s WHERE s.id = _kids_session_id;
  IF _org IS NULL THEN RAISE EXCEPTION 'session_not_found'; END IF;

  IF _org NOT IN (SELECT church.my_orgs_with_any(
       ARRAY['kids_admin']::church.module_permission[])) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM church.people p
                 WHERE p.id = _person_id AND p.organization_id = _org) THEN
    RAISE EXCEPTION 'person_not_in_this_branch';
  END IF;

  SELECT v.background_check_status = 'clear'
     AND (v.background_check_expires_on IS NULL
          OR v.background_check_expires_on >= CURRENT_DATE)
    INTO _bg_current
  FROM church.kids_volunteers v WHERE v.person_id = _person_id;

  -- A restricted volunteer is never placed with children, by any route.
  IF EXISTS (SELECT 1 FROM church.kids_volunteers v
             WHERE v.person_id = _person_id
               AND v.background_check_status = 'restricted') THEN
    RAISE EXCEPTION 'volunteer_is_restricted' USING ERRCODE = '42501';
  END IF;

  INSERT INTO church.kids_session_staffing (
    organization_id, kids_session_id, room_id, person_id, role,
    was_background_check_current)
  VALUES (_org, _kids_session_id, _room_id, _person_id,
          coalesce(_role, 'classroom_volunteer'), coalesce(_bg_current, false))
  ON CONFLICT (kids_session_id, person_id) WHERE ended_at IS NULL
  DO UPDATE SET room_id = EXCLUDED.room_id,
                role = EXCLUDED.role,
                updated_at = now()
  RETURNING * INTO _row;

  RETURN _row;
END;
$$;

GRANT EXECUTE ON FUNCTION church.assign_session_staff(UUID, UUID, UUID, TEXT)
  TO authenticated;

CREATE OR REPLACE FUNCTION church.end_session_staff(_staffing_id UUID)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _org UUID;
BEGIN
  SELECT st.organization_id INTO _org
  FROM church.kids_session_staffing st WHERE st.id = _staffing_id;
  IF _org IS NULL THEN RAISE EXCEPTION 'staffing_not_found'; END IF;

  IF _org NOT IN (SELECT church.my_orgs_with_any(
       ARRAY['kids_admin']::church.module_permission[])) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  UPDATE church.kids_session_staffing
     SET ended_at = now() WHERE id = _staffing_id AND ended_at IS NULL;
END;
$$;

GRANT EXECUTE ON FUNCTION church.end_session_staff(UUID) TO authenticated;

-- Staff assignment shows the leader every adult member, with their volunteer
-- record if they have one. Someone helping for the first time has no
-- kids_volunteers row yet, so an inner join here would hide exactly the person
-- the leader is trying to add.
CREATE OR REPLACE FUNCTION church.kids_eligible_volunteers(_organization_id UUID)
RETURNS TABLE (
  person_id UUID,
  volunteer_id UUID,
  display_name TEXT,
  phone TEXT,
  background_check_status TEXT,
  background_check_expires_on DATE,
  training_completed_on DATE,
  is_active BOOLEAN,
  can_override BOOLEAN,
  is_eligible BOOLEAN
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
BEGIN
  PERFORM church.assert_kids_leader(_organization_id);

  RETURN QUERY
  SELECT
    p.id,
    v.id,
    coalesce(p.preferred_name, p.first_name) || ' ' || p.last_name,
    p.phone,
    coalesce(v.background_check_status, 'not_started'),
    v.background_check_expires_on,
    v.training_completed_on,
    coalesce(v.is_active, false),
    coalesce(v.can_override, false),
    coalesce(v.is_active, false)
      AND v.background_check_status = 'clear'
      AND (v.background_check_expires_on IS NULL
           OR v.background_check_expires_on >= CURRENT_DATE)
  FROM church.people p
  LEFT JOIN church.kids_volunteers v ON v.person_id = p.id
  WHERE p.organization_id = _organization_id
    AND NOT p.is_child
    AND p.is_active
    AND p.merged_into_person_id IS NULL
  ORDER BY coalesce(v.is_active, false) DESC, p.last_name, p.first_name;
END;
$$;

GRANT EXECUTE ON FUNCTION church.kids_eligible_volunteers(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Opening and closing a classroom during a service
-- ---------------------------------------------------------------------------
--
-- open_todays_session() attaches every configured classroom at the moment the
-- session opens. A classroom configured AFTER that never joins the running
-- session — so "Joy B is overflowing, open Joy A" would otherwise mean closing
-- and reopening the whole morning. These let the leader do it live.
CREATE OR REPLACE FUNCTION church.kids_open_room_in_session(
  _kids_session_id UUID, _room_id UUID, _capacity_override INTEGER DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _org UUID;
BEGIN
  SELECT s.organization_id INTO _org
  FROM church.kids_sessions s WHERE s.id = _kids_session_id;
  IF _org IS NULL THEN RAISE EXCEPTION 'session_not_found'; END IF;

  IF _org NOT IN (SELECT church.my_orgs_with_any(
       ARRAY['kids_admin']::church.module_permission[])) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM church.room_kids_config rk
                 WHERE rk.room_id = _room_id AND rk.organization_id = _org
                   AND rk.is_active AND rk.is_checkin_location) THEN
    RAISE EXCEPTION 'room_is_not_a_configured_classroom';
  END IF;

  INSERT INTO church.kids_session_rooms (
    organization_id, kids_session_id, room_id, capacity_override, is_open)
  VALUES (_org, _kids_session_id, _room_id, _capacity_override, true)
  ON CONFLICT (kids_session_id, room_id) DO UPDATE SET
    is_open = true,
    capacity_override = coalesce(EXCLUDED.capacity_override,
                                 kids_session_rooms.capacity_override),
    updated_at = now();
END;
$$;

GRANT EXECUTE ON FUNCTION church.kids_open_room_in_session(UUID, UUID, INTEGER)
  TO authenticated;

-- Closing a room that still holds children would drop them off the live board
-- while they are physically still in it. Refuse, and say how many.
CREATE OR REPLACE FUNCTION church.kids_close_room_in_session(
  _kids_session_id UUID, _room_id UUID)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _org UUID;
  _still INTEGER;
BEGIN
  SELECT s.organization_id INTO _org
  FROM church.kids_sessions s WHERE s.id = _kids_session_id;
  IF _org IS NULL THEN RAISE EXCEPTION 'session_not_found'; END IF;

  IF _org NOT IN (SELECT church.my_orgs_with_any(
       ARRAY['kids_admin']::church.module_permission[])) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  SELECT count(*) INTO _still FROM church.kids_check_ins c
  WHERE c.kids_session_id = _kids_session_id AND c.room_id = _room_id
    AND c.status = 'checked_in';

  IF _still > 0 THEN
    -- A stable code the UI can map, with the count as detail rather than
    -- interpolated into the code itself.
    RAISE EXCEPTION 'room_still_has_children'
      USING DETAIL = format('%s child(ren) still checked in', _still),
            HINT = 'Check them out or transfer them before closing the room.';
  END IF;

  UPDATE church.kids_session_rooms
     SET is_open = false, updated_at = now()
   WHERE kids_session_id = _kids_session_id AND room_id = _room_id;
END;
$$;

GRANT EXECUTE ON FUNCTION church.kids_close_room_in_session(UUID, UUID)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Hardening: default the station lookup to today's open session
-- ---------------------------------------------------------------------------
--
-- already_checked_in was computed as `ci.kids_session_id = _kids_session_id`,
-- so a NULL session id made the comparison NULL for every child and the flag
-- came back false — reporting "nobody is checked in" rather than "I don't
-- know". The app always passes a real session id, but the safe default for
-- a flag that prevents double check-in is to resolve today's open session.
CREATE OR REPLACE FUNCTION church.station_search_households(
  _query TEXT, _kids_session_id UUID, _shift_token TEXT DEFAULT NULL)
RETURNS TABLE (
  household_id UUID, household_name TEXT, masked_phone TEXT,
  child_person_id UUID, child_display_name TEXT, age_band_code TEXT,
  already_checked_in BOOLEAN, needs_staff BOOLEAN
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  a church.resolved_actor;
  _digits TEXT;
  _session UUID;
BEGIN
  a := church.resolve_actor(_shift_token);
  IF NOT a.can_check_in THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;
  IF length(btrim(coalesce(_query, ''))) < 3 THEN
    RAISE EXCEPTION 'query_too_short';
  END IF;

  _session := _kids_session_id;
  IF _session IS NULL THEN
    SELECT s.id INTO _session
    FROM church.kids_sessions s
    WHERE s.organization_id = a.organization_id
      AND s.status = 'open'
      AND s.session_date = CURRENT_DATE
    ORDER BY s.opened_at DESC
    LIMIT 1;
  END IF;

  _digits := regexp_replace(_query, '\D', '', 'g');

  RETURN QUERY
  SELECT
    h.id, h.name,
    ph.masked,
    c.id,
    coalesce(c.preferred_name, c.first_name) || ' ' || left(c.last_name, 1) || '.',
    b.code,
    EXISTS (SELECT 1 FROM church.kids_check_ins ci
            WHERE ci.child_person_id = c.id
              AND ci.kids_session_id = _session
              AND ci.status = 'checked_in'),
    EXISTS (SELECT 1 FROM church.kids_pickup_restrictions pr
            WHERE pr.child_person_id = c.id AND pr.effective_to IS NULL)
  FROM church.households h
  JOIN church.household_members chm
    ON chm.household_id = h.id AND chm.end_date IS NULL
  JOIN church.people c
    ON c.id = chm.person_id AND c.is_child AND c.is_active
   AND c.merged_into_person_id IS NULL
  LEFT JOIN church.kids_age_bands b
         ON b.id = church.age_band_for(a.organization_id, c.birth_year, c.birth_month)
  LEFT JOIN LATERAL (
    SELECT CASE WHEN adult.phone_digits <> ''
                THEN '•••-' || right(adult.phone_digits, 4) END AS masked
    FROM church.household_members ahm
    JOIN church.people adult ON adult.id = ahm.person_id
    WHERE ahm.household_id = h.id AND ahm.end_date IS NULL
      AND NOT adult.is_child AND adult.phone_digits <> ''
    ORDER BY ahm.is_primary_contact DESC
    LIMIT 1
  ) ph ON true
  WHERE h.organization_id = a.organization_id
    AND h.is_active
    AND (
      EXISTS (
        SELECT 1 FROM church.household_members ahm2
        JOIN church.people adult2 ON adult2.id = ahm2.person_id
        WHERE ahm2.household_id = h.id AND ahm2.end_date IS NULL
          AND NOT adult2.is_child
          AND ((length(_digits) >= 4 AND adult2.phone_digits LIKE '%' || _digits)
            OR adult2.search_name % lower(_query))
      )
      OR c.search_name % lower(_query)
      OR h.name ILIKE '%' || _query || '%'
    )
  ORDER BY h.name, c.first_name
  LIMIT 40;
END;
$$;

NOTIFY pgrst, 'reload schema';
