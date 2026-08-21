-- =====================================================
-- The child's tag carries the pickup code and a real phone number
-- =====================================================
--
-- Both of these are a deliberate reversal, made by the ministry lead after the
-- trade-off was put to them. Recording what changed, so nobody later reads the
-- old rationale in the code and "fixes" it back.
--
-- 1. THE EDGE TAB NOW CARRIES THE PICKUP CODE, not the tag number.
--
--    The original design used two separate namespaces on purpose: the child
--    wore a tag number, the parent held a code, and seeing a child therefore
--    told you nothing about how to release them. That property is now gone.
--    Anyone who can read a child's tag can read the code that releases them.
--
--    What still stands between a stranger and a child: check_out_children
--    refuses to release a child with a restriction on file unless the collector
--    is NAMED, the desk asks who is collecting and records it, and every
--    resolve attempt is audited. The code is no longer a secret from anyone in
--    the room; it is a matching key.
--
-- 2. THE TAG NOW CARRIES A DIALABLE PHONE NUMBER.
--
--    The station deliberately only ever received a MASKED number, so that a
--    photograph of the tablet screen leaked very little. A masked number on a
--    printed tag is useless to the volunteer holding a crying child, which is
--    the case the tag exists for.
--
--    The number is returned by check_in_children only — the RPC that prints the
--    label — and NOT added to station_search_households, which renders on
--    screen for every hit of every search. So the full number reaches paper and
--    not the lobby display.
--
--    It does mean a dropped tag now names a child, their classroom and a
--    parent's phone number. That is the shape of every church check-in tag in
--    common use, and it is the lead's call.

-- Primary contact first, then any adult with a number: the same order
-- station_search_households uses to pick the number it masks, so the last four
-- digits printed here match the last four shown at the desk.
CREATE OR REPLACE FUNCTION church.household_contact_phone(_household_id UUID)
RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
  SELECT p.phone
  FROM church.household_members hm
  JOIN church.people p ON p.id = hm.person_id
  WHERE hm.household_id = _household_id
    AND hm.end_date IS NULL
    AND NOT p.is_child
    AND p.is_active
    AND p.phone IS NOT NULL
    AND btrim(p.phone) <> ''
  ORDER BY hm.is_primary_contact DESC, p.first_name
  LIMIT 1;
$$;

-- Postgres grants EXECUTE to PUBLIC by default, and this returns a phone
-- number for any household id you can guess.
REVOKE ALL ON FUNCTION church.household_contact_phone(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION church.household_contact_phone(UUID) TO authenticated;

-- Adding an output column changes the signature, so the old one must go first.
DROP FUNCTION IF EXISTS church.check_in_children(UUID, UUID[], UUID[], TEXT, TEXT, UUID, BOOLEAN, TEXT);

CREATE OR REPLACE FUNCTION church.check_in_children(_kids_session_id uuid, _child_person_ids uuid[], _room_ids uuid[] DEFAULT NULL::uuid[], _shift_token text DEFAULT NULL::text, _client_batch_key text DEFAULT NULL::text, _dropped_off_by_person_id uuid DEFAULT NULL::uuid, _override_capacity boolean DEFAULT false, _assignment_reason text DEFAULT NULL::text)
 RETURNS TABLE(batch_id uuid, pickup_code text, pickup_token text, check_in_id uuid, child_person_id uuid, child_name text, room_id uuid, room_name text, tag_number integer, allergy_label text, has_restriction boolean, guardian_phone text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'church', 'public', 'extensions'
AS $function$
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

  -- No clock gate here. `status = 'open'`, checked immediately above, IS the
  -- gate: a session is open because the scheduler opened it or a leader did,
  -- and either way somebody has decided children may be checked in.
  --
  -- The window on kids_events governs when a session opens and closes by
  -- itself. Enforcing it a second time here meant a leader who opened a
  -- session deliberately — for a midweek programme, a delayed start, or simply
  -- to try the desk before Sunday — got `outside_check_in_window` and could
  -- check nobody in, with an open session on screen telling them they could.
  -- A session left open too long is handled by auto-close, not by refusing the
  -- volunteer standing in front of a parent.
  SELECT * INTO ke FROM church.kids_events WHERE id = ks.kids_event_id;

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
             ci.label_allergy_short, ci.has_pickup_restriction,
             church.household_contact_phone(ci.household_id)
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
              greatest(ks.ends_at, now()) + interval '4 hours');
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
         ci.label_allergy_short, ci.has_pickup_restriction,
         church.household_contact_phone(ci.household_id)
  FROM church.kids_check_ins ci
  WHERE ci.batch_id = _batch
  ORDER BY ci.tag_number;
END;
$function$
;

GRANT EXECUTE ON FUNCTION church.check_in_children(UUID, UUID[], UUID[], TEXT, TEXT, UUID, BOOLEAN, TEXT)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
