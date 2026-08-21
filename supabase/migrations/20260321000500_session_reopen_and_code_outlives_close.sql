-- =====================================================
-- Two safety valves that failed at the same second
-- =====================================================
--
-- At 12:40 on a Sunday, with children still in rooms, both of the things that
-- get a child back to their parent stopped working at once.
--
-- 1. A REOPENED SESSION LASTED TEN MINUTES.
--
--    kids_open_session's reopen branch flipped status to 'open' and cleared
--    closed_at, but never touched ends_at. kids_auto_close_sessions closes
--    anything past ends_at + auto_expire_minutes_after_end, and that moment had
--    already gone — so the next kids-session-tick, at most ten minutes later,
--    closed it again. In production this cycled five times in one afternoon.
--
--    It now pushes ends_at forward too. Reopening is a deliberate act by a
--    volunteer with a room full of children; it should hold.
--
-- 2. THE PICKUP CODE DIED AT THE SAME INSTANT.
--
--    check_in_children set expires_at = greatest(ends_at, now()) + 4 hours, and
--    auto-close fires at ends_at + auto_expire_minutes_after_end, which is 240
--    minutes — the same four hours. On a real MD Sunday both land at 17:30.
--
--    So fixing the session alone would not have helped: resolve_pickup denies
--    on expiry exactly as it denies a wrong code, the desk never reaches the
--    confirm step, and even the admin override button is off-screen.
--
--    The code now expires four hours after the session AUTO-CLOSES rather than
--    four hours after it was scheduled to end. The credential outlives the
--    board, which is the right way round: a child who is still in a room must
--    be collectable, and the parent holding the slip has done nothing wrong.
--
-- This is the second half of a bug I introduced myself in
-- 20260321000000_pickup_code_born_expired.sql. That migration anchored expiry
-- to greatest(ends_at, now()) so a code could never be born expired — correct,
-- and it fixed the reported symptom — but it left the expiry coincident with
-- auto-close, so the failure simply moved four hours later in the day.

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
              greatest(ks.ends_at
                        + make_interval(mins => coalesce(ke.auto_expire_minutes_after_end, 240)),
                       now()) + interval '4 hours');
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

CREATE OR REPLACE FUNCTION church.kids_open_session(_organization_id uuid, _kids_event_id uuid, _label text, _session_date date, _starts_at timestamp with time zone, _ends_at timestamp with time zone, _reopen_closed boolean DEFAULT false)
 RETURNS TABLE(session_id uuid, was_created boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'church', 'public', 'extensions'
AS $function$
DECLARE
  _existing UUID;
  _status TEXT;
  _new UUID;
BEGIN
  -- The scheduler reaches this as the table owner during a cron tick, which is
  -- not a request and has no auth.uid(). A REQUEST must carry a kids
  -- permission in the branch it is opening.
  IF auth.uid() IS NOT NULL
     AND NOT church.has_permission_in_org(
           _organization_id,
           ARRAY['kids_admin','kids_volunteer']::church.module_permission[]) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  -- Keyed on organization + date + label, NOT on the event. Two active
  -- kids_events rows in one branch each opened their own identical
  -- "Sunday Service", splitting the children between two boards.
  SELECT s.id, s.status INTO _existing, _status
  FROM church.kids_sessions s
  WHERE s.organization_id = _organization_id
    AND s.session_date = _session_date
    AND s.service_label = _label
  LIMIT 1;

  IF _existing IS NOT NULL THEN
    IF _status = 'open' THEN
      RETURN QUERY SELECT _existing, false; RETURN;
    END IF;
    IF NOT _reopen_closed THEN
      RETURN;   -- zero rows: somebody closed it on purpose
    END IF;
    -- Push the window out as well as flipping the flag. Without this the
    -- reopen survives until the next kids-session-tick — ten minutes at most —
    -- because kids_auto_close_sessions closes anything past
    -- ends_at + auto_expire_minutes_after_end, and that moment has already
    -- gone. Reopening five times in an afternoon is what that looked like.
    UPDATE church.kids_sessions s
       SET status = 'open', opened_at = coalesce(s.opened_at, now()),
           closed_at = NULL, updated_at = now(),
           ends_at = greatest(s.ends_at, now() + interval '2 hours')
     WHERE s.id = _existing;
    RETURN QUERY SELECT _existing, false; RETURN;
  END IF;

  -- Two stations and the scheduler can race here on a Sunday morning. The
  -- unique constraint on (organization_id, session_date, service_label)
  -- settles it; the loser re-reads rather than failing the caller.
  BEGIN
    INSERT INTO church.kids_sessions (
      organization_id, kids_event_id, session_date, starts_at, ends_at,
      service_label, status, opened_at)
    VALUES (
      _organization_id, _kids_event_id, _session_date, _starts_at, _ends_at,
      _label, 'open', now())
    RETURNING id INTO _new;
    RETURN QUERY SELECT _new, true; RETURN;
  EXCEPTION WHEN unique_violation THEN
    SELECT s.id INTO _new FROM church.kids_sessions s
    WHERE s.organization_id = _organization_id
      AND s.session_date = _session_date
      AND s.service_label = _label
    LIMIT 1;
    RETURN QUERY SELECT _new, false; RETURN;
  END;
END;
$function$
;

GRANT EXECUTE ON FUNCTION church.check_in_children(UUID, UUID[], UUID[], TEXT, TEXT, UUID, BOOLEAN, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION church.kids_open_session(UUID, UUID, TEXT, DATE, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN) TO authenticated;

-- Repair codes already stranded by the coincident expiry, for children who are
-- still in a room right now.
UPDATE church.kids_check_in_secrets s
   SET expires_at = now() + interval '4 hours'
 WHERE s.consumed_at IS NULL
   AND s.expires_at <= now() + interval '10 minutes'
   AND EXISTS (SELECT 1 FROM church.kids_check_ins ci
                WHERE ci.batch_id = s.batch_id AND ci.status = 'checked_in');

NOTIFY pgrst, 'reload schema';
