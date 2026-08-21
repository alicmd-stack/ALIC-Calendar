-- =====================================================
-- Classroom teachers
-- =====================================================
--
-- Checkout happens at the CLASSROOM DOOR, not at one central desk — that is
-- what keeps 80 parents from forming a single queue at the end of a service.
-- So a classroom has to know who teaches it: the parent arriving at Joy C is
-- met by that room's teacher, and the roster they work from is the room's.
--
-- This is a STANDING assignment, deliberately separate from
-- church.kids_session_staffing:
--
--   kids_classroom_teachers  — who normally teaches this room. Survives from
--                              week to week; the ministry's teaching roster.
--   kids_session_staffing    — who is actually serving THIS Sunday, used for
--                              the live ratio and for attribution.
--
-- Conflating them would mean re-entering the whole teaching roster every week,
-- and would lose the answer to "who teaches 3rd grade?" the moment a service
-- ended.

CREATE TABLE IF NOT EXISTS church.kids_classroom_teachers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  room_id UUID NOT NULL REFERENCES public.rooms(id) ON DELETE CASCADE,
  person_id UUID NOT NULL,
  role TEXT NOT NULL DEFAULT 'teacher',
  is_lead BOOLEAN NOT NULL DEFAULT false,
  effective_from DATE NOT NULL DEFAULT CURRENT_DATE,
  effective_to DATE,
  notes TEXT,
  created_by UUID,
  created_by_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT fk_kids_classroom_teachers_person
    FOREIGN KEY (person_id, organization_id)
    REFERENCES church.people(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT chk_kids_classroom_teacher_role
    CHECK (role IN ('lead_teacher', 'teacher', 'assistant', 'helper')),
  CONSTRAINT chk_kids_classroom_teacher_dates
    CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

-- One current assignment per person per room. Ended assignments are kept, so
-- "who taught 3rd grade last spring" survives.
CREATE UNIQUE INDEX IF NOT EXISTS uq_kids_classroom_teacher_current
  ON church.kids_classroom_teachers (room_id, person_id)
  WHERE effective_to IS NULL;

CREATE INDEX IF NOT EXISTS idx_kids_classroom_teachers_room
  ON church.kids_classroom_teachers (room_id) WHERE effective_to IS NULL;

CREATE INDEX IF NOT EXISTS idx_kids_classroom_teachers_org
  ON church.kids_classroom_teachers (organization_id);

ALTER TABLE church.kids_classroom_teachers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Kids admins can manage classroom teachers"
  ON church.kids_classroom_teachers FOR ALL TO authenticated
  USING (organization_id IN (
    SELECT church.my_orgs_with_any(
      ARRAY['kids_admin']::church.module_permission[])))
  WITH CHECK (organization_id IN (
    SELECT church.my_orgs_with_any(
      ARRAY['kids_admin']::church.module_permission[])));

-- A volunteer at a classroom door needs to know who else teaches the room, so
-- the read is wider than the write.
CREATE POLICY "Kids team can view classroom teachers"
  ON church.kids_classroom_teachers FOR SELECT TO authenticated
  USING (organization_id IN (
    SELECT church.my_orgs_with_any(ARRAY[
      'kids_admin', 'kids_volunteer', 'leadership_viewer'
    ]::church.module_permission[])));

CREATE TRIGGER update_church_kids_classroom_teachers_updated_at
  BEFORE UPDATE ON church.kids_classroom_teachers
  FOR EACH ROW EXECUTE FUNCTION church.update_updated_at_column();

GRANT SELECT, INSERT, UPDATE, DELETE ON church.kids_classroom_teachers
  TO authenticated;
GRANT ALL ON church.kids_classroom_teachers TO service_role;

COMMENT ON TABLE church.kids_classroom_teachers IS
  'Who normally teaches a classroom, week to week. Distinct from '
  'kids_session_staffing, which is who is serving on one specific Sunday.';

-- ---------------------------------------------------------------------------
-- Reading the teaching roster
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.kids_classroom_teacher_list(_organization_id UUID)
RETURNS TABLE (
  id UUID,
  room_id UUID,
  room_name TEXT,
  person_id UUID,
  display_name TEXT,
  phone TEXT,
  role TEXT,
  is_lead BOOLEAN,
  background_check_status TEXT,
  is_eligible BOOLEAN
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
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
  WHERE t.organization_id = _organization_id
    AND t.effective_to IS NULL
  ORDER BY rk.sort_order NULLS LAST, r.name, t.is_lead DESC, p.first_name;
END;
$$;

GRANT EXECUTE ON FUNCTION church.kids_classroom_teacher_list(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Assigning and removing
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.assign_classroom_teacher(
  _organization_id UUID,
  _room_id UUID,
  _person_id UUID,
  _role TEXT DEFAULT 'teacher',
  _is_lead BOOLEAN DEFAULT false
)
RETURNS church.kids_classroom_teachers
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _row church.kids_classroom_teachers;
BEGIN
  IF NOT (_organization_id IN (SELECT church.my_admin_orgs())
          OR church.has_permission_in_org(
               _organization_id,
               ARRAY['kids_admin']::church.module_permission[])) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM church.people p
                 WHERE p.id = _person_id
                   AND p.organization_id = _organization_id
                   AND p.is_active AND NOT p.is_child) THEN
    RAISE EXCEPTION 'person_not_eligible_to_teach';
  END IF;

  -- A person barred from working with children is never placed in a classroom,
  -- on any path — the same rule assign_session_staff enforces for a Sunday.
  IF EXISTS (SELECT 1 FROM church.kids_volunteers v
             WHERE v.person_id = _person_id
               AND v.background_check_status = 'restricted') THEN
    RAISE EXCEPTION 'volunteer_is_restricted' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM church.room_kids_config rk
                 WHERE rk.room_id = _room_id
                   AND rk.organization_id = _organization_id
                   AND rk.is_checkin_location) THEN
    RAISE EXCEPTION 'room_is_not_a_configured_classroom';
  END IF;

  INSERT INTO church.kids_classroom_teachers (
    organization_id, room_id, person_id, role, is_lead,
    created_by, created_by_name)
  VALUES (
    _organization_id, _room_id, _person_id,
    coalesce(_role, 'teacher'), coalesce(_is_lead, false),
    auth.uid(),
    coalesce((SELECT full_name FROM public.profiles WHERE id = auth.uid()), 'System'))
  ON CONFLICT (room_id, person_id) WHERE effective_to IS NULL
  DO UPDATE SET role = EXCLUDED.role,
                is_lead = EXCLUDED.is_lead,
                updated_at = now()
  RETURNING * INTO _row;

  RETURN _row;
END;
$$;

GRANT EXECUTE ON FUNCTION church.assign_classroom_teacher(
  UUID, UUID, UUID, TEXT, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION church.remove_classroom_teacher(_id UUID)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _org UUID;
BEGIN
  SELECT t.organization_id INTO _org
  FROM church.kids_classroom_teachers t WHERE t.id = _id;
  IF _org IS NULL THEN RAISE EXCEPTION 'assignment_not_found'; END IF;

  IF NOT (_org IN (SELECT church.my_admin_orgs())
          OR church.has_permission_in_org(
               _org, ARRAY['kids_admin']::church.module_permission[])) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  -- Ended, not deleted: last term's roster is a record worth keeping.
  UPDATE church.kids_classroom_teachers
     SET effective_to = CURRENT_DATE, updated_at = now()
   WHERE id = _id AND effective_to IS NULL;
END;
$$;

GRANT EXECUTE ON FUNCTION church.remove_classroom_teacher(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- The classroom door needs the teachers' names
-- ---------------------------------------------------------------------------
--
-- Checkout is classroom-based, so the volunteer standing at Joy C — and the
-- parent looking at the screen — should see who teaches it.
DROP FUNCTION IF EXISTS church.station_session_rooms(UUID, TEXT);

CREATE OR REPLACE FUNCTION church.station_session_rooms(
  _kids_session_id UUID, _shift_token TEXT DEFAULT NULL)
RETURNS TABLE (
  room_id UUID,
  room_name TEXT,
  grade_name TEXT,
  age_band_name TEXT,
  capacity INTEGER,
  checked_in_count BIGINT,
  teachers TEXT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  a church.resolved_actor;
BEGIN
  a := church.resolve_actor(_shift_token);
  IF NOT a.can_check_in THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    r.id,
    coalesce(rk.label_room_name, r.name),
    g.display_name,
    b.display_name,
    coalesce(sr.capacity_override, rk.capacity),
    coalesce(live.n, 0),
    teach.names
  FROM church.kids_session_rooms sr
  JOIN public.rooms r ON r.id = sr.room_id
  LEFT JOIN church.room_kids_config rk ON rk.room_id = r.id
  LEFT JOIN church.school_grades g ON g.id = rk.school_grade_id
  LEFT JOIN church.kids_age_bands b ON b.id = rk.kids_age_band_id
  LEFT JOIN LATERAL (
    SELECT count(*) AS n FROM church.kids_check_ins c
    WHERE c.kids_session_id = sr.kids_session_id
      AND c.room_id = r.id AND c.status = 'checked_in'
  ) live ON true
  LEFT JOIN LATERAL (
    -- First names only on the station: enough for a parent to recognise the
    -- teacher, consistent with the rest of the tablet's minimal projection.
    SELECT string_agg(coalesce(p.preferred_name, p.first_name),
                      ', ' ORDER BY t.is_lead DESC, p.first_name) AS names
    FROM church.kids_classroom_teachers t
    JOIN church.people p ON p.id = t.person_id
    WHERE t.room_id = r.id AND t.effective_to IS NULL
  ) teach ON true
  WHERE sr.kids_session_id = _kids_session_id
    AND sr.organization_id = a.organization_id
    AND sr.is_open
  ORDER BY coalesce(rk.sort_order, 0), r.name;
END;
$$;

GRANT EXECUTE ON FUNCTION church.station_session_rooms(UUID, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
