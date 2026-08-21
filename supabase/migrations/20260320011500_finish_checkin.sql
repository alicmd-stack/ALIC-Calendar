-- =====================================================
-- Finishing the check-in desk
-- =====================================================
--
-- Three gaps that all show up on the same Sunday:
--
--   1. Nothing answers "who is still here" at the end of a service. A leader
--      opened each classroom in turn, and once the session auto-closed the
--      children disappeared from the board entirely.
--   2. A volunteer could not put themselves on a shift. Only a kids_admin
--      could assign staff, so every staffed room read "no volunteer assigned"
--      and the ratio warnings were wrong all morning — which trains people to
--      ignore them.
--   3. check_in_children replays a finished batch: the client_batch_key
--      short-circuit never checked whether the batch was still active, so a
--      family returning later got a rotated code for children who are already
--      checked OUT. The printed label then resolves to nothing.

-- ---------------------------------------------------------------------------
-- 1. Who is still here
-- ---------------------------------------------------------------------------
--
-- Deliberately org-wide and not session-scoped: the children who matter most
-- are the ones in a session that has already ended, which a session-scoped
-- query is exactly the wrong shape to find.
CREATE OR REPLACE FUNCTION church.kids_still_here(_organization_id UUID)
RETURNS TABLE (
  check_in_id UUID,
  child_person_id UUID,
  child_name TEXT,
  tag_number INTEGER,
  room_name TEXT,
  session_label TEXT,
  session_date DATE,
  session_status TEXT,
  checked_in_at TIMESTAMPTZ,
  minutes_in_room INTEGER,
  guardian_name TEXT,
  guardian_phone TEXT,
  has_allergy BOOLEAN,
  has_restriction BOOLEAN
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
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
  WHERE c.organization_id = _organization_id
    AND c.status = 'checked_in'
  -- Longest in the room first: that is the child to worry about.
  ORDER BY c.checked_in_at;
END;
$$;

GRANT EXECUTE ON FUNCTION church.kids_still_here(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. A volunteer putting themselves on a shift
-- ---------------------------------------------------------------------------
--
-- assign_session_staff requires kids_admin, which is right for rostering
-- somebody else and wrong for saying "I am in this room now". This one only
-- ever acts on the CALLER, so it needs no elevated permission.
CREATE OR REPLACE FUNCTION church.start_my_shift(
  _kids_session_id UUID,
  _room_id UUID DEFAULT NULL,
  _role TEXT DEFAULT 'classroom_volunteer')
RETURNS church.kids_session_staffing
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  a church.resolved_actor;
  _bg BOOLEAN;
  _row church.kids_session_staffing;
BEGIN
  a := church.resolve_actor(NULL);
  IF NOT a.can_check_in THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  -- A volunteer with no member record cannot be attributed, and attribution
  -- is the entire point of a staffing row.
  IF a.person_id IS NULL THEN
    RAISE EXCEPTION 'no_member_record'
      USING HINT = 'An admin needs to link this login to a member record.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM church.kids_sessions s
                 WHERE s.id = _kids_session_id
                   AND s.organization_id = a.organization_id) THEN
    RAISE EXCEPTION 'session_not_found';
  END IF;

  -- resolve_actor already refuses anyone marked restricted, so reaching here
  -- means they are not barred. This records whether their check was CURRENT
  -- at the time, which is a different question and worth keeping.
  SELECT v.background_check_status = 'clear'
     AND (v.background_check_expires_on IS NULL
          OR v.background_check_expires_on >= CURRENT_DATE)
    INTO _bg
  FROM church.kids_volunteers v WHERE v.person_id = a.person_id;

  INSERT INTO church.kids_session_staffing (
    organization_id, kids_session_id, room_id, person_id, role,
    was_background_check_current)
  VALUES (a.organization_id, _kids_session_id, _room_id, a.person_id,
          coalesce(_role, 'classroom_volunteer'), coalesce(_bg, false))
  ON CONFLICT (kids_session_id, person_id) WHERE ended_at IS NULL
  DO UPDATE SET room_id = EXCLUDED.room_id,
                role = EXCLUDED.role,
                updated_at = now()
  RETURNING * INTO _row;

  RETURN _row;
END;
$$;

GRANT EXECUTE ON FUNCTION church.start_my_shift(UUID, UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION church.end_my_shift(_kids_session_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  a church.resolved_actor;
  _n INTEGER;
BEGIN
  a := church.resolve_actor(NULL);
  IF a.person_id IS NULL THEN RETURN 0; END IF;

  UPDATE church.kids_session_staffing
     SET ended_at = now(), updated_at = now()
   WHERE kids_session_id = _kids_session_id
     AND person_id = a.person_id
     AND ended_at IS NULL;

  GET DIAGNOSTICS _n = ROW_COUNT;
  RETURN _n;
END;
$$;

GRANT EXECUTE ON FUNCTION church.end_my_shift(UUID) TO authenticated;

-- Where am I serving right now?
CREATE OR REPLACE FUNCTION church.my_current_shift(_kids_session_id UUID)
RETURNS TABLE (staffing_id UUID, room_id UUID, room_name TEXT, role TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  a church.resolved_actor;
BEGIN
  a := church.resolve_actor(NULL);
  IF a.person_id IS NULL THEN RETURN; END IF;

  RETURN QUERY
  SELECT st.id, st.room_id, coalesce(rk.label_room_name, r.name), st.role
  FROM church.kids_session_staffing st
  LEFT JOIN public.rooms r ON r.id = st.room_id
  LEFT JOIN church.room_kids_config rk ON rk.room_id = st.room_id
  WHERE st.kids_session_id = _kids_session_id
    AND st.person_id = a.person_id
    AND st.ended_at IS NULL
  LIMIT 1;
END;
$$;

GRANT EXECUTE ON FUNCTION church.my_current_shift(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Never replay a finished batch
-- ---------------------------------------------------------------------------
--
-- The idempotency key exists so that a LOST RESPONSE cannot check the same
-- children in twice. It was matching on the key alone, so a family returning
-- for a later service — or checked out by mistake and brought back — hit the
-- replay branch instead of being checked in: the screen said success, a label
-- printed, and the code on it resolved to nothing because the batch's secret
-- was already consumed.
--
-- Replay now requires the batch to still have a child in a room. Otherwise it
-- falls through and a genuine new check-in happens.
CREATE OR REPLACE FUNCTION church.kids_batch_is_replayable(_batch_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = church, public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM church.kids_check_ins c
    WHERE c.batch_id = _batch_id AND c.status = 'checked_in');
$$;

REVOKE ALL ON FUNCTION church.kids_batch_is_replayable(UUID) FROM PUBLIC;

CREATE OR REPLACE FUNCTION church.check_in_children(_kids_session_id uuid, _child_person_ids uuid[], _room_ids uuid[] DEFAULT NULL::uuid[], _shift_token text DEFAULT NULL::text, _client_batch_key text DEFAULT NULL::text, _dropped_off_by_person_id uuid DEFAULT NULL::uuid, _override_capacity boolean DEFAULT false, _assignment_reason text DEFAULT NULL::text)
 RETURNS TABLE(batch_id uuid, pickup_code text, pickup_token text, check_in_id uuid, child_person_id uuid, child_name text, room_id uuid, room_name text, tag_number integer, allergy_label text, has_restriction boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'church', 'public', 'extensions'
AS $$
DECLARE
  a  church.resolved_actor;
  ks church.kids_sessions%ROWTYPE;
  ke church.kids_events%ROWTYPE;
  _batch UUID;
  _code TEXT;
  _token TEXT;
  _existing church.kids_check_in_batches%ROWTYPE;
  _child UUID;
  _idx INTEGER := 0;
  _room UUID;
  _tries INTEGER := 0;
  _household UUID;
BEGIN
  a := church.resolve_actor(_shift_token);
  IF NOT a.can_check_in THEN
    RAISE EXCEPTION 'not_permitted_to_check_in' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO ks FROM church.kids_sessions
   WHERE id = _kids_session_id AND organization_id = a.organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'session_not_found'; END IF;
  IF ks.status <> 'open' THEN RAISE EXCEPTION 'session_not_open'; END IF;

  SELECT * INTO ke FROM church.kids_events WHERE id = ks.kids_event_id;
  IF now() < ks.starts_at - make_interval(mins => ke.check_in_opens_minutes_before)
     OR now() > ks.ends_at + make_interval(mins => ke.check_in_closes_minutes_after) THEN
    RAISE EXCEPTION 'outside_check_in_window';
  END IF;

  IF _child_person_ids IS NULL OR array_length(_child_person_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'no_children_supplied';
  END IF;

  -- Idempotent retry after a lost response. The children are already checked
  -- in, so do NOT check them in again; rotate the credential (invalidating
  -- whatever may have been printed) and hand back a fresh, valid one.
  IF _client_batch_key IS NOT NULL THEN
    SELECT * INTO _existing FROM church.kids_check_in_batches
     WHERE kids_session_id = _kids_session_id AND client_batch_key = _client_batch_key;

    -- Replay ONLY while the batch still has a child in a room. The key exists
    -- so a lost response cannot check the same children in twice; it is not a
    -- claim that this family can never check in again. Matching on the key
    -- alone meant a family returning later got a rotated code for children who
    -- were already checked OUT — the screen said success, a label printed, and
    -- the code on it resolved to nothing.
    IF FOUND AND NOT church.kids_batch_is_replayable(_existing.id) THEN
      -- The key is unique per session, so simply declining to replay would
      -- collide on the insert below and the family could not check in at all.
      -- Retire the spent batch's key instead: it only needs to be reserved
      -- while that batch is live, and the old value is kept, suffixed, so the
      -- morning's history is still readable.
      UPDATE church.kids_check_in_batches
         SET client_batch_key = client_batch_key || ':done:' || _existing.id
       WHERE id = _existing.id;
      _existing := NULL;
    END IF;

    IF _existing.id IS NOT NULL THEN
      _code := church.generate_pickup_code();
      _token := encode(gen_random_bytes(16), 'base64');
      UPDATE church.kids_check_in_secrets
         SET code_hash = church.hash_pickup(_code),
             token_hash = church.hash_pickup(_token),
             attempts = 0, locked_until = NULL, rotated_at = now(),
             -- Rotating a code that was already consumed leaves the parent
             -- holding a label that resolves to nothing.
             consumed_at = NULL
       -- Qualified: batch_id is also a RETURNS TABLE output parameter, and an
       -- unqualified reference here is ambiguous to plpgsql.
       WHERE kids_check_in_secrets.batch_id = _existing.id;

      RETURN QUERY
      SELECT _existing.id, _code, _token, ci.id, ci.child_person_id,
             ci.label_child_name, ci.room_id, ci.label_room_name, ci.tag_number,
             ci.label_allergy_short, ci.has_pickup_restriction
      FROM church.kids_check_ins ci
      WHERE ci.batch_id = _existing.id
      ORDER BY ci.tag_number;
      RETURN;
    END IF;
  END IF;

  SELECT hm.household_id INTO _household
  FROM church.household_members hm
  WHERE hm.person_id = _child_person_ids[1]
    AND hm.end_date IS NULL AND hm.is_primary_household
  LIMIT 1;

  INSERT INTO church.kids_check_in_batches
    (organization_id, kids_session_id, household_id, client_batch_key,
     created_by_station_id, created_by_volunteer_id, created_by_name)
  VALUES (a.organization_id, _kids_session_id, _household, _client_batch_key,
          a.station_id, a.volunteer_id, a.actor_name)
  RETURNING id INTO _batch;

  -- Generate a code unique among the live codes for this session. Collision
  -- odds are ~1e-4 across a whole morning, but retry rather than trust that.
  _token := encode(gen_random_bytes(16), 'base64');
  LOOP
    _tries := _tries + 1;
    _code := church.generate_pickup_code();
    BEGIN
      INSERT INTO church.kids_check_in_secrets
        (batch_id, kids_session_id, code_hash, token_hash, expires_at)
      VALUES (_batch, _kids_session_id,
              church.hash_pickup(_code), church.hash_pickup(_token),
              ks.ends_at + interval '4 hours');
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      IF _tries >= 10 THEN RAISE EXCEPTION 'could_not_allocate_pickup_code'; END IF;
    END;
  END LOOP;

  FOREACH _child IN ARRAY _child_person_ids LOOP
    _idx := _idx + 1;
    _room := CASE WHEN _room_ids IS NULL THEN NULL ELSE _room_ids[_idx] END;
    PERFORM church.check_in_one_child(
      a, _kids_session_id, _batch, _child, _room,
      _dropped_off_by_person_id, _override_capacity, _assignment_reason);
  END LOOP;

  RETURN QUERY
  SELECT _batch, _code, _token, ci.id, ci.child_person_id,
         ci.label_child_name, ci.room_id, ci.label_room_name, ci.tag_number,
         ci.label_allergy_short, ci.has_pickup_restriction
  FROM church.kids_check_ins ci
  WHERE ci.batch_id = _batch
  ORDER BY ci.tag_number;
END;
$$;

GRANT EXECUTE ON FUNCTION church.check_in_children(
  UUID, UUID[], UUID[], TEXT, TEXT, UUID, BOOLEAN, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
