-- =====================================================
-- The desk needs the class list to put a visitor in the right room
-- =====================================================
--
-- ALIC's ten classrooms are keyed to SCHOOL GRADE — Joy A is Pre-K, Redeemed C
-- is Grade 8. None of them has an age band set, and the five bands that exist
-- are far too coarse to help anyway: "Elementary (5-10)" spans six grades and
-- five different rooms.
--
-- So pick_room_for_child's grade step is the one that actually places a child,
-- and a visiting family has no grade on file. Placement fell through to step 3,
-- "the emptiest open room, any grade", and a four-year-old could be sent to
-- Grade 8 — on the busiest lane of the first real Sunday, when every family is
-- a visitor.
--
-- This returns the classrooms with their grade, so the desk can offer the class
-- as a choice and store the child's grade when registering them. Storing the
-- grade rather than a one-off room assignment is the point: it places the child
-- correctly this week and every week after, through the normal routing, with no
-- special case for visitors anywhere.
--
-- NOT session-scoped, deliberately. Registering a family happens before anyone
-- has opened a session on a quiet weekday, and the class list is a property of
-- the branch, not of today's service.

CREATE OR REPLACE FUNCTION church.station_classroom_grades(_shift_token TEXT DEFAULT NULL)
RETURNS TABLE (
  room_id UUID,
  room_name TEXT,
  school_grade_id UUID,
  grade_name TEXT,
  sort_order INTEGER
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
  SELECT r.id,
         coalesce(k.label_room_name, r.name),
         g.id,
         g.display_name,
         -- Order by the GRADE where there is one, so the list reads Pre-K to
         -- Grade 8 rather than in whatever order the rooms were created. A room
         -- with no grade sorts last, where it cannot be picked by accident.
         coalesce(g.sort_order, 9999)
  FROM church.room_kids_config k
  JOIN public.rooms r ON r.id = k.room_id
  LEFT JOIN church.school_grades g ON g.id = k.school_grade_id
  WHERE k.organization_id = a.organization_id
    AND k.is_checkin_location
    AND k.is_active
  ORDER BY coalesce(g.sort_order, 9999), coalesce(k.label_room_name, r.name);
END;
$$;

REVOKE ALL ON FUNCTION church.station_classroom_grades(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION church.station_classroom_grades(TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
