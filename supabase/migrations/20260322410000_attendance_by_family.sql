-- =====================================================
-- Attendance by family: members and visitors
-- =====================================================
--
-- The ministry asked to read the attendance reports for member families and
-- visitor families separately.
--
-- WHAT A CHILD COUNTS AS. Children almost never carry a membership status of
-- their own (1 child in Silver Spring does); their parents do. So a child
-- takes the strongest status in the family as recorded today: their own, or
-- that of any adult in a household they currently belong to.
--
--   member            someone in the family is a Member
--   regular_attendee  otherwise, someone is a Regular Attendee
--   visitor           otherwise, someone is a Visitor (the desk registers
--                     every new family as one)
--   not_recorded      nobody in the family has any of the three
--
-- Strongest wins because a family with one member parent is a member family,
-- and a visiting family whose parent later joins becomes one without anybody
-- editing the children.
--
-- AS RECORDED TODAY, NOT ON THE DAY. Statuses keep no history, so a family
-- that visited in September and joined in October counts as members across
-- the whole range. The screen says so.
--
-- NOT_RECORDED IS LARGE, AND SHOWN AS ITSELF. On 10 October 105 of the 339
-- children ever checked in had no status anywhere in the family: imported or
-- added without one. Counting them as visitors would make families who have
-- come for years look new, and quadruple the visitor numbers.
--
-- WHO MAY READ IT: whoever may read the attendance reports, through the same
-- assert_kids_leader. A family's membership status is directory data a
-- ministry leader may know; nothing medical is added.
--
-- kids_attendance_report is left exactly as it was, for screens loaded before
-- this deploy. The report now reads kids_attendance_by_family, which is the
-- same grouping split once more by family, and adds up the parts it wants.

-- ---------------------------------------------------------------------------
-- The rule, in one place.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.kids_family_status(_child_person_id UUID)
RETURNS TEXT
LANGUAGE sql STABLE
SET search_path = church, public, extensions
AS $$
  SELECT CASE
           WHEN 'member' = ANY (codes) THEN 'member'
           WHEN 'regular_attendee' = ANY (codes) THEN 'regular_attendee'
           WHEN 'visitor' = ANY (codes) THEN 'visitor'
           ELSE 'not_recorded'
         END
  FROM (
    SELECT coalesce(array_agg(ms.code), '{}') AS codes
    FROM (
      SELECT p.membership_status_id AS status_id
      FROM church.people p
      WHERE p.id = _child_person_id
      UNION ALL
      SELECT a.membership_status_id
      FROM church.household_members hc
      JOIN church.household_members ha
        ON ha.household_id = hc.household_id
       AND ha.person_id <> hc.person_id
       AND ha.end_date IS NULL
      JOIN church.people a ON a.id = ha.person_id AND NOT a.is_child
      WHERE hc.person_id = _child_person_id
        AND hc.end_date IS NULL
    ) s
    JOIN church.membership_statuses ms ON ms.id = s.status_id
  ) f;
$$;

-- Called only from the reports below, which run as their owner. Not a lookup
-- anyone should be able to run on an arbitrary person.
REVOKE ALL ON FUNCTION church.kids_family_status(UUID) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The room report, split by family.
-- ---------------------------------------------------------------------------
-- Exactly kids_attendance_report's grouping with family_status added, so the
-- parts of a room add back up to the room: each child has one status, so
-- children, first-time, overrides and not-collected sum across statuses.
-- `volunteers` belongs to the room, not to a family, and is repeated on each
-- of a room's rows; the screen takes it once.
CREATE OR REPLACE FUNCTION church.kids_attendance_by_family(
  _organization_id UUID, _from DATE, _to DATE)
RETURNS TABLE (
  session_date DATE,
  service_label TEXT,
  room_name TEXT,
  age_band_name TEXT,
  family_status TEXT,
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
  WITH families AS (
    SELECT k.child_id, church.kids_family_status(k.child_id) AS status
    FROM (
      SELECT DISTINCT kc.child_person_id AS child_id
      FROM church.kids_sessions ks
      JOIN church.kids_check_ins kc ON kc.kids_session_id = ks.id
      WHERE ks.organization_id = _organization_id
        AND ks.session_date BETWEEN _from AND _to
    ) k
  )
  SELECT
    s.session_date,
    s.service_label,
    coalesce(r.name, 'Unassigned'),
    b.display_name,
    f.status,
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
  JOIN families f ON f.child_id = c.child_person_id
  LEFT JOIN public.rooms r ON r.id = c.room_id
  LEFT JOIN church.room_kids_config rk ON rk.room_id = r.id
  LEFT JOIN church.kids_age_bands b ON b.id = rk.kids_age_band_id
  WHERE s.organization_id = _organization_id
    AND s.session_date BETWEEN _from AND _to
  GROUP BY s.id, s.session_date, s.service_label, r.id, r.name, b.display_name, f.status
  ORDER BY s.session_date DESC, coalesce(r.name, 'Unassigned'), f.status;
END;
$$;

REVOKE ALL ON FUNCTION church.kids_attendance_by_family(UUID, DATE, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION church.kids_attendance_by_family(UUID, DATE, DATE) TO authenticated;

-- ---------------------------------------------------------------------------
-- The by-child list carries each child's family.
-- ---------------------------------------------------------------------------
-- A new output column changes the return type, which CREATE OR REPLACE cannot
-- do; dropped and recreated in this one transaction, so no request sees it
-- missing. Screens loaded before this deploy ignore the extra column.
DROP FUNCTION church.kids_child_attendance(UUID, DATE, DATE);

CREATE FUNCTION church.kids_child_attendance(
  _organization_id UUID, _from DATE, _to DATE)
RETURNS TABLE (
  child_person_id UUID,
  child_name TEXT,
  session_date DATE,
  room_name TEXT,
  first_check_in DATE,
  family_status TEXT
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
  WITH visits AS (
    SELECT DISTINCT ON (c.child_person_id, s.session_date)
           c.child_person_id AS child_id,
           s.session_date AS on_date,
           coalesce(r.name, c.label_room_name, 'Unassigned') AS room
    FROM church.kids_sessions s
    JOIN church.kids_check_ins c ON c.kids_session_id = s.id
    LEFT JOIN public.rooms r ON r.id = c.room_id
    WHERE s.organization_id = _organization_id
      AND s.session_date BETWEEN _from AND _to
    ORDER BY c.child_person_id, s.session_date, c.checked_in_at DESC
  ),
  firsts AS (
    SELECT pc.child_person_id AS child_id, min(ps.session_date) AS first_date
    FROM church.kids_check_ins pc
    JOIN church.kids_sessions ps ON ps.id = pc.kids_session_id
    WHERE ps.organization_id = _organization_id
      AND pc.child_person_id IN (SELECT v.child_id FROM visits v)
    GROUP BY pc.child_person_id
  ),
  families AS (
    SELECT k.child_id, church.kids_family_status(k.child_id) AS status
    FROM (SELECT DISTINCT v.child_id FROM visits v) k
  )
  SELECT v.child_id,
         coalesce(p.preferred_name, p.first_name) || ' ' || p.last_name,
         v.on_date,
         v.room,
         f.first_date,
         fm.status
  FROM visits v
  JOIN church.people p ON p.id = v.child_id
  LEFT JOIN firsts f ON f.child_id = v.child_id
  JOIN families fm ON fm.child_id = v.child_id
  ORDER BY coalesce(p.preferred_name, p.first_name), p.last_name, v.on_date;
END;
$$;

REVOKE ALL ON FUNCTION church.kids_child_attendance(UUID, DATE, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION church.kids_child_attendance(UUID, DATE, DATE) TO authenticated;

NOTIFY pgrst, 'reload schema';
