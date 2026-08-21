-- =====================================================
-- Who dropped the child off, a reprint that rotates, and the code by text
-- =====================================================
--
-- Three gaps that all show up at the same moment on a Sunday.
--
-- 1. NOBODY RECORDS WHO DROPPED THE CHILD OFF.
--    kids_check_ins.dropped_off_by_person_id has existed since the first kids
--    migration and is populated on ZERO check-ins, because the desk never sends
--    it. So the most natural question at pickup — "is this the person who
--    brought them?" — cannot be answered, and the answer is already standing at
--    the desk when the children are selected.
--
-- 2. A LOST SLIP HAS ONLY ONE ROUTE: AN OVERRIDE.
--    There is no reprint anywhere, and the code is a peppered HMAC, so it
--    cannot be read back to reprint the same label. A parent who leaves the
--    slip in the car therefore triggers the override path — which is meant to
--    be the exceptional, two-person, audited act. Making it the routine remedy
--    for a mislaid piece of paper is how a control stops meaning anything.
--
--    Reprinting ROTATES the code, exactly as the plan requires. The old slip
--    stops working the moment the new one prints, so a slip dropped in the car
--    park is worthless rather than live for the rest of the morning.
--
-- 3. THE SLIP IS THE ONLY COPY.
--    Half of ALIC's adults have no email on file and no SMS has ever been sent.
--    Texting the code at check-in makes paper the backup rather than the
--    original. The plumbing already supports it: notification_log.channel
--    accepts 'sms', and the edge function fails a non-email row cleanly with
--    "no provider configured" — so this queues real rows today and starts
--    delivering the moment Twilio credentials exist, with no further change
--    here.

-- ---------------------------------------------------------------- drop-off

/**
 * The adults at this household, for "who is dropping off?".
 *
 * Deliberately household-scoped rather than check-in-scoped, unlike
 * station_pickup_candidates: this is asked BEFORE the children are checked in,
 * when no check_in_id exists yet.
 *
 * Returns a masked phone only. It renders on a screen a queue of parents can
 * see, and the desk does not need to dial anyone to answer this question.
 */
CREATE OR REPLACE FUNCTION church.station_household_adults(
  _household_id UUID, _shift_token TEXT DEFAULT NULL)
RETURNS TABLE (
  person_id UUID,
  display_name TEXT,
  relationship TEXT,
  masked_phone TEXT,
  is_primary_contact BOOLEAN
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
  SELECT p.id,
         coalesce(p.preferred_name, p.first_name) || ' ' || p.last_name,
         CASE WHEN hm.is_primary_contact THEN 'Primary contact' ELSE 'Household' END,
         CASE WHEN p.phone_digits <> '' THEN '•••-' || right(p.phone_digits, 4) END,
         hm.is_primary_contact
  FROM church.household_members hm
  JOIN church.people p ON p.id = hm.person_id
  WHERE hm.household_id = _household_id
    AND hm.end_date IS NULL
    AND p.organization_id = a.organization_id
    AND NOT p.is_child
    AND p.is_active
    AND p.merged_into_person_id IS NULL
  ORDER BY hm.is_primary_contact DESC, p.first_name;
END;
$$;

REVOKE ALL ON FUNCTION church.station_household_adults(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION church.station_household_adults(UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------- code by SMS

/**
 * Queue the pickup code to every adult on the household who has a phone.
 *
 * Internal only — it takes the PLAINTEXT code, which exists for a few
 * milliseconds inside check_in_children and is never stored. Exposing this
 * would hand out a way to have any code texted anywhere, so it is revoked from
 * everyone and called only from inside the definer functions that already hold
 * the code.
 *
 * Never raises. A notification problem must not roll back a check-in that has
 * already succeeded — the child is in the room either way, and the printed slip
 * remains the primary credential.
 */
CREATE OR REPLACE FUNCTION church.queue_pickup_code_sms(_batch_id UUID, _code TEXT)
RETURNS INTEGER
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  b church.kids_check_in_batches%ROWTYPE;
  t RECORD;
  _n INTEGER := 0;
  _children TEXT;
  _formatted TEXT;
BEGIN
  SELECT * INTO b FROM church.kids_check_in_batches WHERE id = _batch_id;
  IF NOT FOUND OR b.household_id IS NULL THEN RETURN 0; END IF;

  SELECT string_agg(ci.label_child_name, ', ' ORDER BY ci.tag_number)
    INTO _children
  FROM church.kids_check_ins ci WHERE ci.batch_id = _batch_id;

  -- Grouped the way it is printed, so the text and the slip read alike.
  _formatted := CASE WHEN length(_code) = 6
                     THEN left(_code, 3) || '-' || right(_code, 3)
                     ELSE _code END;

  FOR t IN
    SELECT p.id, coalesce(p.preferred_name, p.first_name) AS nm, p.phone
    FROM church.household_members hm
    JOIN church.people p ON p.id = hm.person_id
    WHERE hm.household_id = b.household_id
      AND hm.end_date IS NULL
      AND NOT p.is_child
      AND p.is_active
      AND p.phone IS NOT NULL
      AND btrim(p.phone) <> ''
  LOOP
    BEGIN
      INSERT INTO church.notification_log
        (organization_id, kind, channel, recipient_person_id, recipient_name,
         recipient_phone, kids_session_id, body)
      VALUES (b.organization_id, 'check_in', 'sms', t.id, t.nm, t.phone,
              b.kids_session_id,
              'ALIC Kids pickup code: ' || _formatted ||
              coalesce(' for ' || _children, '') ||
              '. Keep this — you will need it to collect.');
      _n := _n + 1;
    EXCEPTION WHEN OTHERS THEN
      -- Swallowed on purpose. See the note above: a failed text must never
      -- undo a completed check-in.
      NULL;
    END;
  END LOOP;

  RETURN _n;
END;
$$;

REVOKE ALL ON FUNCTION church.queue_pickup_code_sms(UUID, TEXT) FROM PUBLIC;

-- ---------------------------------------------------------------- reprint

/**
 * Reissue a family's pickup slip with a NEW code.
 *
 * Rotation is the point, not a side effect. The previous slip stops resolving
 * the instant this returns, so a slip left in a car — or handed to the wrong
 * person — is dead rather than live for the rest of the morning.
 *
 * Refuses once every child on the batch has gone home: there is nothing left to
 * collect, and minting a fresh live credential for a finished batch would be
 * creating a key to an empty room.
 */
CREATE OR REPLACE FUNCTION church.reprint_pickup_label(
  _batch_id UUID, _reason TEXT DEFAULT NULL, _shift_token TEXT DEFAULT NULL)
RETURNS TABLE (
  batch_id UUID,
  pickup_code TEXT,
  pickup_token TEXT,
  household_name TEXT,
  check_in_id UUID,
  child_name TEXT,
  room_name TEXT,
  tag_number INTEGER,
  allergy_label TEXT,
  guardian_phone TEXT
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  a church.resolved_actor;
  b church.kids_check_in_batches%ROWTYPE;
  _code TEXT;
  _token TEXT;
  _tries INTEGER := 0;
  _still_in INTEGER;
BEGIN
  a := church.resolve_actor(_shift_token);
  IF NOT a.can_check_in THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO b FROM church.kids_check_in_batches
   WHERE id = _batch_id AND organization_id = a.organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'batch_not_found'; END IF;

  SELECT count(*) INTO _still_in
  FROM church.kids_check_ins ci
  WHERE ci.batch_id = _batch_id AND ci.status = 'checked_in';

  IF _still_in = 0 THEN
    RAISE EXCEPTION 'nobody_left_to_collect';
  END IF;

  _token := encode(gen_random_bytes(16), 'base64');
  LOOP
    _tries := _tries + 1;
    _code := church.generate_pickup_code();
    BEGIN
      UPDATE church.kids_check_in_secrets s
         SET code_hash = church.hash_pickup(_code),
             token_hash = church.hash_pickup(_token),
             attempts = 0,
             locked_until = NULL,
             rotated_at = now(),
             -- A batch can be reprinted after a partial collection, so the
             -- secret may have been consumed and re-opened. Clear it: children
             -- are still in rooms and the new slip must work for them.
             consumed_at = NULL,
             expires_at = greatest(s.expires_at, now() + interval '4 hours')
       WHERE s.batch_id = _batch_id;
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      IF _tries >= 10 THEN RAISE EXCEPTION 'could_not_allocate_pickup_code'; END IF;
    END;
  END LOOP;

  INSERT INTO church.check_in_audit
    (organization_id, action, outcome, batch_id, kids_session_id, station_id,
     volunteer_id, actor_auth_user_id, actor_name, detail)
  VALUES (a.organization_id, 'label_reprint', 'success', _batch_id,
          b.kids_session_id, a.station_id, a.volunteer_id, auth.uid(),
          a.actor_name,
          jsonb_build_object('reason', coalesce(_reason, 'not given'),
                             'children_still_in', _still_in));

  PERFORM church.queue_pickup_code_sms(_batch_id, _code);

  RETURN QUERY
  SELECT _batch_id, _code, _token,
         coalesce(h.name, 'This family'),
         ci.id, ci.label_child_name, ci.label_room_name, ci.tag_number,
         ci.label_allergy_short,
         church.household_contact_phone(ci.household_id)
  FROM church.kids_check_ins ci
  LEFT JOIN church.households h ON h.id = b.household_id
  WHERE ci.batch_id = _batch_id
    AND ci.status = 'checked_in'
  ORDER BY ci.tag_number;
END;
$$;

REVOKE ALL ON FUNCTION church.reprint_pickup_label(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION church.reprint_pickup_label(UUID, TEXT, TEXT) TO authenticated;

/**
 * Find a family's live batch so the desk can reprint it.
 *
 * The parent has lost the slip, so the code cannot be the way in. Name or phone
 * is, exactly as at check-in.
 */
CREATE OR REPLACE FUNCTION church.station_find_batch_for_reprint(
  _query TEXT, _kids_session_id UUID DEFAULT NULL, _shift_token TEXT DEFAULT NULL)
RETURNS TABLE (
  batch_id UUID,
  household_name TEXT,
  masked_phone TEXT,
  children TEXT,
  checked_in_at TIMESTAMPTZ
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  a church.resolved_actor;
  _digits TEXT;
BEGIN
  a := church.resolve_actor(_shift_token);
  IF NOT a.can_check_in THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;
  IF length(btrim(coalesce(_query, ''))) < 3 THEN
    RAISE EXCEPTION 'query_too_short';
  END IF;

  _digits := regexp_replace(_query, '\D', '', 'g');

  RETURN QUERY
  SELECT b.id,
         coalesce(h.name, 'Unknown household'),
         (SELECT CASE WHEN adult.phone_digits <> ''
                      THEN '•••-' || right(adult.phone_digits, 4) END
            FROM church.household_members ahm
            JOIN church.people adult ON adult.id = ahm.person_id
           WHERE ahm.household_id = h.id AND ahm.end_date IS NULL
             AND NOT adult.is_child AND adult.phone_digits <> ''
           ORDER BY ahm.is_primary_contact DESC LIMIT 1),
         (SELECT string_agg(ci2.label_child_name, ', ' ORDER BY ci2.tag_number)
            FROM church.kids_check_ins ci2
           WHERE ci2.batch_id = b.id AND ci2.status = 'checked_in'),
         b.created_at
  FROM church.kids_check_in_batches b
  LEFT JOIN church.households h ON h.id = b.household_id
  WHERE b.organization_id = a.organization_id
    AND (_kids_session_id IS NULL OR b.kids_session_id = _kids_session_id)
    -- Only batches with a child still in a room can be reprinted.
    AND EXISTS (SELECT 1 FROM church.kids_check_ins ci
                 WHERE ci.batch_id = b.id AND ci.status = 'checked_in')
    AND (
      h.name ILIKE '%' || _query || '%'
      OR EXISTS (
        SELECT 1 FROM church.household_members hm3
        JOIN church.people p3 ON p3.id = hm3.person_id
        WHERE hm3.household_id = h.id AND hm3.end_date IS NULL
          AND ((length(_digits) >= 4 AND p3.phone_digits LIKE '%' || _digits)
            OR p3.search_name % lower(_query)))
    )
  ORDER BY b.created_at DESC
  LIMIT 20;
END;
$$;

REVOKE ALL ON FUNCTION church.station_find_batch_for_reprint(TEXT, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION church.station_find_batch_for_reprint(TEXT, UUID, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
