-- =====================================================
-- The classroom volunteer's own room
-- =====================================================
--
-- send_parent_message already accepts any actor with can_check_in, so a
-- classroom volunteer is permitted to message a parent. They had no way to
-- REACH a child to do it: the station can look a family up by phone, but
-- nothing showed the volunteer who is actually in the room in front of them.
--
-- This is deliberately NOT church.kids_room_roster, which requires kids_admin
-- and returns full names and the guardian's phone number. The station keeps
-- its minimal-disclosure projection — first name and last initial, no phone,
-- no birthday — so a photograph of the tablet still leaks very little. The
-- volunteer messages the parent THROUGH the system rather than being handed a
-- phone number.

CREATE OR REPLACE FUNCTION church.station_room_roster(
  _kids_session_id UUID,
  _room_id UUID DEFAULT NULL,
  _shift_token TEXT DEFAULT NULL
)
RETURNS TABLE (
  check_in_id UUID,
  child_display_name TEXT,
  tag_number INTEGER,
  room_id UUID,
  room_name TEXT,
  checked_in_at TIMESTAMPTZ,
  minutes_in_room INTEGER,
  has_allergy BOOLEAN,
  has_restriction BOOLEAN
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
    c.id,
    -- Same projection as station_search_households: last initial only.
    coalesce(p.preferred_name, p.first_name) || ' ' || left(p.last_name, 1) || '.',
    c.tag_number,
    c.room_id,
    coalesce(rk.label_room_name, r.name),
    c.checked_in_at,
    (EXTRACT(EPOCH FROM (now() - c.checked_in_at)) / 60)::INTEGER,
    c.label_allergy_flag,
    c.has_pickup_restriction
  FROM church.kids_check_ins c
  JOIN church.people p ON p.id = c.child_person_id
  LEFT JOIN public.rooms r ON r.id = c.room_id
  LEFT JOIN church.room_kids_config rk ON rk.room_id = c.room_id
  WHERE c.kids_session_id = _kids_session_id
    AND c.organization_id = a.organization_id
    AND c.status = 'checked_in'
    AND (_room_id IS NULL OR c.room_id = _room_id)
  ORDER BY coalesce(rk.sort_order, 0), r.name, c.tag_number;
END;
$$;

GRANT EXECUTE ON FUNCTION church.station_room_roster(UUID, UUID, TEXT)
  TO authenticated;

-- Which rooms are open for this session, so the volunteer can pick theirs.
-- Occupancy only; nothing here identifies a person.
CREATE OR REPLACE FUNCTION church.station_session_rooms(
  _kids_session_id UUID, _shift_token TEXT DEFAULT NULL)
RETURNS TABLE (
  room_id UUID,
  room_name TEXT,
  age_band_name TEXT,
  capacity INTEGER,
  checked_in_count BIGINT
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
    b.display_name,
    coalesce(sr.capacity_override, rk.capacity),
    coalesce(live.n, 0)
  FROM church.kids_session_rooms sr
  JOIN public.rooms r ON r.id = sr.room_id
  LEFT JOIN church.room_kids_config rk ON rk.room_id = r.id
  LEFT JOIN church.kids_age_bands b ON b.id = rk.kids_age_band_id
  LEFT JOIN LATERAL (
    SELECT count(*) AS n FROM church.kids_check_ins c
    WHERE c.kids_session_id = sr.kids_session_id
      AND c.room_id = r.id AND c.status = 'checked_in'
  ) live ON true
  WHERE sr.kids_session_id = _kids_session_id
    AND sr.organization_id = a.organization_id
    AND sr.is_open
  ORDER BY coalesce(rk.sort_order, 0), r.name;
END;
$$;

GRANT EXECUTE ON FUNCTION church.station_session_rooms(UUID, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
