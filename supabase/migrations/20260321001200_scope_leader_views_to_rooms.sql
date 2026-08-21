-- =====================================================
-- A team lead sees their own grades
-- =====================================================
--
-- kids_leader_scope has existed since 20260321000700 but nothing read it: it
-- was a mechanism with no enforcement, so every leader still saw the whole
-- branch. These are the four views where a room is the unit of the answer.
--
-- The permissive default runs all the way through. kids_leader_room_ids
-- returns EVERY classroom for a leader with no scope rows, so the two
-- directors and every pre-existing kids_admin are unaffected, and the filter
-- can be applied unconditionally with no special case for them.
--
-- Two of the four are written as "sees all OR in scope" rather than a bare IN.
-- A child with no room_id matches no room, so a bare IN would drop them out of
-- the roster and the not-collected screen simultaneously — hiding exactly the
-- child who most needs to be found, from the person most able to find them.
--
-- Deliberately NOT scoped, and worth being explicit about:
--   kids_attendance_report, kids_exceptions_report  historical reporting; a
--     lead seeing branch-wide totals is an over-share, not a risk
--   kids_eligible_volunteers, kids_notification_log  no room dimension
--   the check-in desk itself  a lead helping at the desk on a busy Sunday
--     must be able to check in a child for any classroom

CREATE OR REPLACE FUNCTION church.kids_classroom_teacher_list(_organization_id uuid)
 RETURNS TABLE(id uuid, room_id uuid, room_name text, person_id uuid, display_name text, phone text, role text, is_lead boolean, background_check_status text, is_eligible boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'church', 'public', 'extensions'
AS $function$
BEGIN
  PERFORM church.assert_kids_leader(_organization_id);

  RETURN QUERY
  SELECT
    t.id,
    t.room_id,
    coalesce(rk.label_room_name, r.name),
    p.id,
    coalesce(p.preferred_name, p.first_name) || ' ' || p.last_name,
    p.phone,
    t.role,
    t.is_lead,
    coalesce(v.background_check_status, 'not_started'),
    -- Surfaced rather than enforced on read: a teacher whose check lapses must
    -- be visible on the roster, not silently vanish from it.
    coalesce(v.is_active, false)
      AND v.background_check_status = 'clear'
      AND (v.background_check_expires_on IS NULL
           OR v.background_check_expires_on >= CURRENT_DATE)
  FROM church.kids_classroom_teachers t
  JOIN church.people p ON p.id = t.person_id
  JOIN public.rooms r ON r.id = t.room_id
  LEFT JOIN church.room_kids_config rk ON rk.room_id = t.room_id
  LEFT JOIN church.kids_volunteers v ON v.person_id = t.person_id
    -- Scope. kids_leader_room_ids returns every classroom when the viewer is
    -- unscoped, so a director is unaffected; a team lead sees only their own
    -- grades.
  WHERE t.organization_id = _organization_id
    AND t.room_id IN (SELECT church.kids_leader_room_ids(_organization_id))
    AND t.effective_to IS NULL
  ORDER BY rk.sort_order NULLS LAST, r.name, t.is_lead DESC, p.first_name;
END;
$function$
;

CREATE OR REPLACE FUNCTION church.kids_live_board(_organization_id uuid)
 RETURNS TABLE(kids_session_id uuid, session_label text, session_date date, room_id uuid, room_name text, label_room_name text, grade_name text, age_band_code text, age_band_name text, capacity integer, ratio_children_per_volunteer integer, checked_in_count bigint, checked_out_count bigint, volunteer_count bigint, allergy_count bigint, restriction_count bigint, misplaced_count bigint, over_capacity boolean, over_ratio boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'church', 'public', 'extensions'
AS $function$
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
    -- Scope. kids_leader_room_ids returns every classroom when the viewer is
    -- unscoped, so a director is unaffected; a team lead sees only their own
    -- grades.
  WHERE s.organization_id = _organization_id
    AND r.id IN (SELECT church.kids_leader_room_ids(_organization_id))
    AND s.status = 'open'
  ORDER BY s.session_date, rk.sort_order NULLS LAST, r.name;
END;
$function$
;

CREATE OR REPLACE FUNCTION church.kids_room_roster(_kids_session_id uuid, _room_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(check_in_id uuid, child_person_id uuid, child_name text, tag_number integer, room_id uuid, room_name text, status text, checked_in_at timestamp with time zone, checked_out_at timestamp with time zone, checked_in_by_name text, checked_out_by_name text, dropped_off_by_name text, picked_up_by_name text, guardian_phone text, has_allergy boolean, has_restriction boolean, checkout_method text, minutes_in_room integer, assignment_reason text, grade_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'church', 'public', 'extensions'
AS $function$
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
    -- Scope. kids_leader_room_ids returns every classroom when the viewer is
    -- unscoped, so a director is unaffected; a team lead sees only their own
    -- grades.
    -- Written as "sees all OR in scope" rather than a bare IN, so a child who
    -- somehow has NO room still reaches a director instead of vanishing from
    -- every view at once.
  WHERE c.kids_session_id = _kids_session_id
    AND (church.kids_leader_sees_all_rooms(_org)
         OR c.room_id IN (SELECT church.kids_leader_room_ids(_org)))
    AND (_room_id IS NULL OR c.room_id = _room_id)
  ORDER BY c.status, c.tag_number;
END;
$function$
;

CREATE OR REPLACE FUNCTION church.kids_still_here(_organization_id uuid)
 RETURNS TABLE(check_in_id uuid, child_person_id uuid, child_name text, tag_number integer, room_name text, session_label text, session_date date, session_status text, checked_in_at timestamp with time zone, minutes_in_room integer, guardian_name text, guardian_phone text, has_allergy boolean, has_restriction boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'church', 'public', 'extensions'
AS $function$
BEGIN
  PERFORM church.assert_kids_leader(_organization_id);

  RETURN QUERY
  SELECT
    c.id, c.child_person_id, c.label_child_name, c.tag_number,
    coalesce(c.label_room_name, r.name),
    s.service_label, s.session_date, s.status,
    c.checked_in_at,
    (EXTRACT(EPOCH FROM (now() - c.checked_in_at)) / 60)::INTEGER,
    g.nm, g.phone,
    c.label_allergy_flag,
    church.child_has_active_restriction(c.child_person_id)
  FROM church.kids_check_ins c
  JOIN church.kids_sessions s ON s.id = c.kids_session_id
  LEFT JOIN public.rooms r ON r.id = c.room_id
  LEFT JOIN LATERAL (
    SELECT coalesce(p.preferred_name, p.first_name) || ' ' || p.last_name AS nm,
           p.phone
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
  ) g ON true
    -- Scope. kids_leader_room_ids returns every classroom when the viewer is
    -- unscoped, so a director is unaffected; a team lead sees only their own
    -- grades.
  WHERE c.organization_id = _organization_id
    AND (church.kids_leader_sees_all_rooms(_organization_id)
         OR c.room_id IN (SELECT church.kids_leader_room_ids(_organization_id)))
    AND c.status = 'checked_in'
  -- Longest in the room first: that is the child to worry about.
  ORDER BY c.checked_in_at;
END;
$function$
;
GRANT EXECUTE ON FUNCTION church.kids_live_board(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION church.kids_still_here(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION church.kids_room_roster(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION church.kids_classroom_teacher_list(UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';
