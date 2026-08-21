-- =====================================================
-- The desk should show the grade it places children by
-- =====================================================
--
-- station_search_households returns age_band_code, and the station renders it
-- on each child's tile. Since 20260320002500 placement is decided by SCHOOL
-- GRADE, not by age band — so a Pre-K child born five years ago shows
-- "Elementary" on the tile and is then correctly placed in Joy A.
--
-- The volunteer reads that mismatch as the system being wrong about the child.
-- Worse, it is the exact field they would use to sanity-check a placement, so
-- it teaches them to distrust a placement that is right.
--
-- The grade is shown when it is on file, and the age band remains as the
-- fallback label for a child who has no grade — which is also precisely the
-- child whose placement WILL fall back to the age band.

DROP FUNCTION IF EXISTS church.station_search_households(TEXT, UUID, TEXT);

CREATE OR REPLACE FUNCTION church.station_search_households(
  _query TEXT, _kids_session_id UUID, _shift_token TEXT DEFAULT NULL)
RETURNS TABLE (
  household_id UUID, household_name TEXT, masked_phone TEXT,
  child_person_id UUID, child_display_name TEXT, age_band_code TEXT,
  grade_name TEXT,
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
    g.display_name,
    EXISTS (SELECT 1 FROM church.kids_check_ins ci
            WHERE ci.child_person_id = c.id
              AND ci.kids_session_id = _session
              AND ci.status = 'checked_in'),
    EXISTS (SELECT 1 FROM church.kids_pickup_restrictions pr
            WHERE pr.child_person_id = c.id
              AND pr.lifted_at IS NULL
              AND (pr.effective_to IS NULL OR pr.effective_to >= CURRENT_DATE))
  FROM church.households h
  JOIN church.household_members chm
    ON chm.household_id = h.id AND chm.end_date IS NULL
  JOIN church.people c
    ON c.id = chm.person_id AND c.is_child AND c.is_active
   AND c.merged_into_person_id IS NULL
  LEFT JOIN church.school_grades g ON g.id = c.school_grade_id
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

GRANT EXECUTE ON FUNCTION church.station_search_households(TEXT, UUID, TEXT)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
