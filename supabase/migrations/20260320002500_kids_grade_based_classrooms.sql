-- =====================================================
-- Classrooms by school grade, as the ministry actually runs them
-- =====================================================
--
-- The Children's Ministry director has given the real mapping, replacing the
-- PROVISIONAL age-band guesses seeded in 20260320001500. It is organised by
-- SCHOOL GRADE, not by age:
--
--   Joy A       Pre-K          Shine A      4th grade
--   Joy B       Kindergarten   Shine B      5th grade
--   Joy C       1st grade      Redeemed A   6th grade
--   Blossom A   2nd grade      Redeemed B   7th grade
--   Blossom B   3rd grade      Redeemed C   8th grade
--
-- Silver Spring only. Springfield still has no rooms of any kind and cannot
-- run check-in until someone there defines its room list.
--
-- Grade is a better key than age for this church: two children born a month
-- apart can be a school year apart, and the ministry teaches to the grade.
-- church.people.school_grade_id and church.room_kids_config.school_grade_id
-- both already existed; nothing read them. Now assignment does.
--
-- Age bands are kept as the fallback for a child whose grade is not on file,
-- which is common for a first-time visitor at the desk.

-- ---------------------------------------------------------------------------
-- Assignment: grade first, age band second, never turn a child away
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.pick_room_for_child(
  _kids_session_id UUID,
  _organization_id UUID,
  _child_person_id UUID
)
RETURNS TABLE (room_id UUID, reason TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  ch church.people%ROWTYPE;
  _band UUID;
  _room UUID;
BEGIN
  SELECT * INTO ch FROM church.people
   WHERE id = _child_person_id AND organization_id = _organization_id;
  IF NOT FOUND THEN RETURN; END IF;

  -- 1. The child's grade, which is how the ministry organises its classrooms.
  IF ch.school_grade_id IS NOT NULL THEN
    SELECT ksr.room_id INTO _room
    FROM church.kids_session_rooms ksr
    JOIN church.room_kids_config rkc ON rkc.room_id = ksr.room_id
    WHERE ksr.kids_session_id = _kids_session_id
      AND ksr.is_open AND rkc.is_active AND rkc.is_checkin_location
      AND rkc.school_grade_id = ch.school_grade_id
    -- Emptiest first, so two rooms sharing a grade self-balance over a morning.
    ORDER BY (SELECT count(*) FROM church.kids_check_ins ci
               WHERE ci.kids_session_id = _kids_session_id
                 AND ci.room_id = ksr.room_id AND ci.status = 'checked_in'),
             rkc.sort_order
    LIMIT 1;

    IF _room IS NOT NULL THEN
      RETURN QUERY SELECT _room, NULL::TEXT;
      RETURN;
    END IF;
  END IF;

  -- 2. No grade on file, or no room teaches it: fall back to the age band.
  _band := church.age_band_for(_organization_id, ch.birth_year, ch.birth_month);
  IF _band IS NOT NULL THEN
    SELECT ksr.room_id INTO _room
    FROM church.kids_session_rooms ksr
    JOIN church.room_kids_config rkc ON rkc.room_id = ksr.room_id
    WHERE ksr.kids_session_id = _kids_session_id
      AND ksr.is_open AND rkc.is_active AND rkc.is_checkin_location
      AND rkc.kids_age_band_id = _band
    ORDER BY (SELECT count(*) FROM church.kids_check_ins ci
               WHERE ci.kids_session_id = _kids_session_id
                 AND ci.room_id = ksr.room_id AND ci.status = 'checked_in'),
             rkc.sort_order
    LIMIT 1;

    IF _room IS NOT NULL THEN
      RETURN QUERY SELECT _room,
        CASE WHEN ch.school_grade_id IS NULL
             THEN 'No school grade on file — placed by age'
             ELSE 'No classroom teaches this grade — placed by age' END;
      RETURN;
    END IF;
  END IF;

  -- 3. Nothing matched. The child is still placed, because a church does not
  -- turn a child away at the door — but the reason is recorded so the live
  -- board shows it and a leader can move them. ALIC runs no nursery, so a
  -- child below Pre-K lands here, and that must be visible rather than silent.
  SELECT ksr.room_id INTO _room
  FROM church.kids_session_rooms ksr
  LEFT JOIN church.room_kids_config rkc ON rkc.room_id = ksr.room_id
  WHERE ksr.kids_session_id = _kids_session_id AND ksr.is_open
  ORDER BY (SELECT count(*) FROM church.kids_check_ins ci
             WHERE ci.kids_session_id = _kids_session_id
               AND ci.room_id = ksr.room_id AND ci.status = 'checked_in'),
           coalesce(rkc.sort_order, 0)
  LIMIT 1;

  IF _room IS NOT NULL THEN
    RETURN QUERY SELECT _room, 'No matching classroom — please check placement';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION church.pick_room_for_child(UUID, UUID, UUID)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Classroom editing, for the ministry leader as well as an org admin
-- ---------------------------------------------------------------------------
--
-- public.rooms is shared with the events and booking module, and its RLS grants
-- write access only to app_role = 'admin'. The Children's Ministry leader is a
-- kids_admin, which is not the same thing, so they could configure a classroom
-- but never rename or create one.
--
-- This lets them do both, bounded to children's spaces: a kids_admin may create
-- a classroom and edit one that is already a check-in location. They may not
-- rename the Main Auditorium or a Training Conference room. An org admin is
-- unrestricted, as they already are through RLS.
CREATE OR REPLACE FUNCTION church.upsert_kids_classroom(
  _organization_id UUID,
  _room_id UUID DEFAULT NULL,
  _name TEXT DEFAULT NULL,
  _school_grade_id UUID DEFAULT NULL,
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
  _is_admin BOOLEAN;
  _is_kids_admin BOOLEAN;
  _room UUID := _room_id;
  _row church.room_kids_config;
  _clean_name TEXT := NULLIF(btrim(coalesce(_name, '')), '');
BEGIN
  _is_admin := _organization_id IN (SELECT church.my_admin_orgs());
  _is_kids_admin := church.has_permission_in_org(
    _organization_id, ARRAY['kids_admin']::church.module_permission[]);

  IF NOT (_is_admin OR _is_kids_admin) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

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

  IF _school_grade_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM church.school_grades g
                     WHERE g.id = _school_grade_id
                       AND g.organization_id = _organization_id) THEN
    RAISE EXCEPTION 'grade_belongs_to_another_branch';
  END IF;

  IF _kids_age_band_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM church.kids_age_bands b
                     WHERE b.id = _kids_age_band_id
                       AND b.organization_id = _organization_id) THEN
    RAISE EXCEPTION 'age_band_belongs_to_another_branch';
  END IF;

  IF _room IS NULL THEN
    -- New classroom.
    IF _clean_name IS NULL THEN
      RAISE EXCEPTION 'room_name_required';
    END IF;
    IF EXISTS (SELECT 1 FROM public.rooms r
               WHERE r.organization_id = _organization_id
                 AND lower(r.name) = lower(_clean_name)) THEN
      RAISE EXCEPTION 'room_name_already_used';
    END IF;

    INSERT INTO public.rooms (name, organization_id, is_active)
    VALUES (_clean_name, _organization_id, true)
    RETURNING id INTO _room;
  ELSE
    -- Existing room. A kids_admin who is not an org admin may only touch a
    -- room that is already a children's space.
    IF NOT _is_admin
       AND NOT EXISTS (SELECT 1 FROM church.room_kids_config rk
                       WHERE rk.room_id = _room
                         AND rk.organization_id = _organization_id
                         AND rk.is_checkin_location) THEN
      RAISE EXCEPTION 'not_a_kids_classroom' USING ERRCODE = '42501';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.rooms r
                   WHERE r.id = _room AND r.organization_id = _organization_id) THEN
      RAISE EXCEPTION 'room_not_found';
    END IF;

    IF _clean_name IS NOT NULL THEN
      IF EXISTS (SELECT 1 FROM public.rooms r
                 WHERE r.organization_id = _organization_id
                   AND lower(r.name) = lower(_clean_name)
                   AND r.id <> _room) THEN
        RAISE EXCEPTION 'room_name_already_used';
      END IF;
      UPDATE public.rooms SET name = _clean_name, updated_at = now()
       WHERE id = _room;
    END IF;
  END IF;

  INSERT INTO church.room_kids_config (
    room_id, organization_id, is_checkin_location, school_grade_id,
    kids_age_band_id, capacity, ratio_children_per_volunteer,
    label_room_name, sort_order)
  VALUES (_room, _organization_id, true, _school_grade_id, _kids_age_band_id,
          _capacity, _ratio, _label_room_name, coalesce(_sort_order, 0))
  ON CONFLICT (room_id) DO UPDATE SET
    is_checkin_location = true,
    is_active = true,
    school_grade_id = EXCLUDED.school_grade_id,
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

GRANT EXECUTE ON FUNCTION church.upsert_kids_classroom(
  UUID, UUID, TEXT, UUID, UUID, INTEGER, INTEGER, TEXT, INTEGER) TO authenticated;

-- Take a room out of children's use. The room itself survives, because the
-- events module may still book it.
CREATE OR REPLACE FUNCTION church.retire_kids_classroom(
  _organization_id UUID, _room_id UUID)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _still INTEGER;
BEGIN
  IF NOT (_organization_id IN (SELECT church.my_admin_orgs())
          OR church.has_permission_in_org(
               _organization_id,
               ARRAY['kids_admin']::church.module_permission[])) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  -- Retiring a room that still holds children would drop them off every
  -- roster while they are physically still in it.
  SELECT count(*) INTO _still
  FROM church.kids_check_ins c
  JOIN church.kids_sessions s ON s.id = c.kids_session_id AND s.status = 'open'
  WHERE c.room_id = _room_id AND c.status = 'checked_in';

  IF _still > 0 THEN
    RAISE EXCEPTION 'room_still_has_children'
      USING DETAIL = format('%s child(ren) still checked in', _still),
            HINT = 'Check them out or transfer them before retiring the room.';
  END IF;

  UPDATE church.room_kids_config
     SET is_checkin_location = false, updated_at = now()
   WHERE room_id = _room_id AND organization_id = _organization_id;
END;
$$;

GRANT EXECUTE ON FUNCTION church.retire_kids_classroom(UUID, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Wire the new placement into check-in
-- ---------------------------------------------------------------------------
--
-- pick_room_for_child() would be dead code without this. check_in_one_child
-- previously inlined an age-band-only lookup.
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
  _pick_reason TEXT;
BEGIN
  SELECT * INTO ch FROM church.people
   WHERE id = _child_person_id AND organization_id = a.organization_id
     AND is_active AND merged_into_person_id IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'child_not_found'; END IF;

  -- Placement is grade-first now: church.pick_room_for_child() prefers a room
  -- that teaches the child's school grade, falls back to the age band when no
  -- grade is on file, and as a last resort places them anywhere open with the
  -- reason recorded — a church does not turn a child away at the door, but a
  -- misplacement must be visible rather than silent.
  IF _room_id IS NULL THEN
    SELECT p.room_id, p.reason INTO _room_id, _pick_reason
    FROM church.pick_room_for_child(
      _kids_session_id, a.organization_id, _child_person_id) p;

    IF _room_id IS NULL THEN
      RAISE EXCEPTION 'no_open_classroom';
    END IF;

    -- The volunteer's own reason wins if they supplied one.
    _assignment_reason := coalesce(_assignment_reason, _pick_reason);
  END IF;

  -- Kept for the label, which prints an age-band code.
  _band := church.age_band_for(a.organization_id, ch.birth_year, ch.birth_month);
  SELECT code INTO _band_code FROM church.kids_age_bands WHERE id = _band;

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

-- ---------------------------------------------------------------------------
-- The ministry's actual rooms, Silver Spring
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  _org UUID;
  _room UUID;
  v RECORD;
BEGIN
  SELECT id INTO _org FROM public.organizations
   WHERE name ILIKE '%Silver Spring%' OR name ILIKE '%ALIC MD%'
   ORDER BY created_at LIMIT 1;

  IF _org IS NULL THEN
    RAISE NOTICE 'Silver Spring organization not found; skipping classroom seed';
    RETURN;
  END IF;

  FOR v IN
    SELECT * FROM (VALUES
      -- old name (NULL if new),  new name,      grade, label,        order
      ('Joy class A',      'Joy A',      'prek', 'Joy A',      10),
      ('Joy class B',      'Joy B',      'k',    'Joy B',      20),
      (NULL,               'Joy C',      'g1',   'Joy C',      30),
      ('Blossom class A',  'Blossom A',  'g2',   'Blossom A',  40),
      ('Blossom class B',  'Blossom B',  'g3',   'Blossom B',  50),
      ('Shine class',      'Shine A',    'g4',   'Shine A',    60),
      (NULL,               'Shine B',    'g5',   'Shine B',    70),
      (NULL,               'Redeemed A', 'g6',   'Redeemed A', 80),
      (NULL,               'Redeemed B', 'g7',   'Redeemed B', 90),
      (NULL,               'Redeemed C', 'g8',   'Redeemed C', 100)
    ) AS t(old_name, new_name, grade_code, label, sort_order)
  LOOP
    -- Rename in place where the room already exists, so any calendar booking
    -- and any check-in history stays attached to it.
    _room := NULL;
    IF v.old_name IS NOT NULL THEN
      SELECT id INTO _room FROM public.rooms
       WHERE organization_id = _org AND name = v.old_name;
    END IF;
    IF _room IS NULL THEN
      SELECT id INTO _room FROM public.rooms
       WHERE organization_id = _org AND name = v.new_name;
    END IF;

    IF _room IS NULL THEN
      INSERT INTO public.rooms (name, organization_id, is_active)
      VALUES (v.new_name, _org, true) RETURNING id INTO _room;
    ELSE
      UPDATE public.rooms SET name = v.new_name, is_active = true,
                              updated_at = now()
       WHERE id = _room;
    END IF;

    INSERT INTO church.room_kids_config (
      room_id, organization_id, is_checkin_location, school_grade_id,
      kids_age_band_id, label_room_name, sort_order)
    VALUES (
      _room, _org, true,
      (SELECT id FROM church.school_grades g
        WHERE g.organization_id = _org AND g.code = v.grade_code),
      NULL, v.label, v.sort_order)
    ON CONFLICT (room_id) DO UPDATE SET
      is_checkin_location = true,
      is_active = true,
      school_grade_id = EXCLUDED.school_grade_id,
      -- Cleared deliberately: the age bands seeded in 20260320001500 were
      -- guesses, and grade now decides placement.
      kids_age_band_id = NULL,
      label_room_name = EXCLUDED.label_room_name,
      sort_order = EXCLUDED.sort_order,
      updated_at = now();
  END LOOP;

  -- The ministry's list ends at 8th grade, so the youth room is no longer a
  -- check-in destination. The room itself stays for youth worship and events.
  UPDATE church.room_kids_config rk
     SET is_checkin_location = false, updated_at = now()
    FROM public.rooms r
   WHERE r.id = rk.room_id
     AND rk.organization_id = _org
     AND r.name ILIKE '%True Vine%';
END $$;

-- Capacity and children-per-volunteer are deliberately left unset: the
-- director gave rooms and grades, not numbers, and a guessed capacity produces
-- false over-capacity warnings on the live board. Both are editable per room
-- from the Classrooms tab, and an unset limit simply never warns.

COMMENT ON TABLE church.room_kids_config IS
  'Kids configuration for a public.rooms row. school_grade_id is the ministry''s '
  'real mapping (Joy/Blossom/Shine/Redeemed by grade, set in 20260320002500); '
  'kids_age_band_id remains only as the fallback for a child with no grade on '
  'file. Editable by a kids_admin through church.upsert_kids_classroom().';

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Surface the placement reason where somebody will see it
-- ---------------------------------------------------------------------------
--
-- assignment_reason was written by check-in and read by nothing — the same
-- trap as capacity_overridden. With no nursery at ALIC, a child below Pre-K
-- falls to the "no matching classroom" branch, and that must reach a human.
DROP FUNCTION IF EXISTS church.kids_room_roster(UUID, UUID);

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
  minutes_in_room INTEGER,
  assignment_reason TEXT,
  grade_name TEXT
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
    -- Read live, not from the check-in-time snapshot: an order filed during
    -- the service must show on the roster the volunteers are looking at.
    church.child_has_active_restriction(c.child_person_id),
    c.checkout_method,
    (EXTRACT(EPOCH FROM (coalesce(c.checked_out_at, now()) - c.checked_in_at))
       / 60)::INTEGER,
    c.assignment_reason,
    g.display_name
  FROM church.kids_check_ins c
  LEFT JOIN public.rooms r ON r.id = c.room_id
  LEFT JOIN church.people cp ON cp.id = c.child_person_id
  LEFT JOIN church.school_grades g ON g.id = cp.school_grade_id
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

-- The exceptions report ignored capacity overrides and odd placements
-- entirely, because both are written as action='check_in', outcome='success'.
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
    CASE WHEN au.action = 'check_in'
              AND (au.detail->>'capacity_overridden')::BOOLEAN IS TRUE
         THEN 'capacity_override' ELSE au.action END,
    au.outcome,
    coalesce(p.first_name || ' ' || p.last_name, '(unknown child)'),
    r.name,
    au.actor_name,
    coalesce(
      au.detail->>'override_reason',
      au.detail->>'reason',
      c.assignment_reason,
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
         OR au.outcome = 'denied'
         -- A room pushed past capacity, and a child placed somewhere their
         -- grade is not taught, are both things to review on Monday.
         OR (au.action = 'check_in'
             AND (au.detail->>'capacity_overridden')::BOOLEAN IS TRUE)
         OR (au.action = 'check_in' AND c.assignment_reason IS NOT NULL))
  ORDER BY au.created_at DESC
  LIMIT 500;
END;
$$;

GRANT EXECUTE ON FUNCTION church.kids_exceptions_report(UUID, DATE, DATE)
  TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- The live board names the grade the room teaches
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS church.kids_live_board(UUID);

CREATE OR REPLACE FUNCTION church.kids_live_board(_organization_id UUID)
RETURNS TABLE (
  kids_session_id UUID,
  session_label TEXT,
  session_date DATE,
  room_id UUID,
  room_name TEXT,
  label_room_name TEXT,
  grade_name TEXT,
  age_band_code TEXT,
  age_band_name TEXT,
  capacity INTEGER,
  ratio_children_per_volunteer INTEGER,
  checked_in_count BIGINT,
  checked_out_count BIGINT,
  volunteer_count BIGINT,
  allergy_count BIGINT,
  restriction_count BIGINT,
  misplaced_count BIGINT,
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
    g.display_name,
    b.code,
    b.display_name,
    coalesce(sr.capacity_override, rk.capacity),
    rk.ratio_children_per_volunteer,
    coalesce(live.n, 0),
    coalesce(gone.n, 0),
    coalesce(staff.n, 0),
    coalesce(live.allergies, 0),
    coalesce(live.restrictions, 0),
    coalesce(live.misplaced, 0),
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
  LEFT JOIN church.school_grades g ON g.id = rk.school_grade_id
  LEFT JOIN church.kids_age_bands b ON b.id = rk.kids_age_band_id
  LEFT JOIN LATERAL (
    SELECT count(*) AS n,
           count(*) FILTER (WHERE c.label_allergy_flag) AS allergies,
           -- Live, so an order filed mid-service lights the board up.
           count(*) FILTER (
             WHERE church.child_has_active_restriction(c.child_person_id)
           ) AS restrictions,
           count(*) FILTER (WHERE c.assignment_reason IS NOT NULL) AS misplaced
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

NOTIFY pgrst, 'reload schema';
