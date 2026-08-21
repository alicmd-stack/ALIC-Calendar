-- =====================================================
-- Kids Ministry: check-in / checkout RPCs
-- =====================================================
--
-- These functions are the ONLY way any client writes a check-in. The tables
-- have no insert/update policy for any role, so a shared station account
-- cannot fabricate who performed an action.
--
-- A RULE LEARNED THE HARD WAY, APPLIED THROUGHOUT:
-- a RAISE aborts the transaction, which rolls back anything written earlier in
-- the same call. So any path that must PERSIST a side effect — incrementing a
-- failed-attempt counter, writing a denial to the audit log — returns zero
-- rows instead of raising. Raising is reserved for failures with nothing to
-- persist, where a distinguishable error actually helps the UI.

-- ---------------------------------------------------------------------------
-- Credential helpers
-- ---------------------------------------------------------------------------
-- 22-character alphabet. Excludes 0/O, 1/I/L, and S/Z/B/G, which are the
-- glyphs that get misread across a noisy hallway or mis-written on a paper
-- ticket during an outage. 22^6 ~= 113 million.
CREATE OR REPLACE FUNCTION church.generate_pickup_code()
RETURNS TEXT
LANGUAGE plpgsql VOLATILE
SET search_path = church, public, extensions
AS $$
DECLARE
  _alphabet TEXT := '23456789ACDEFHJKMNPRTY';
  _out TEXT := '';
  _i INTEGER;
BEGIN
  FOR _i IN 1..6 LOOP
    -- gen_random_bytes, not random(): random() is seeded and predictable, and
    -- this value releases a child.
    _out := _out || substr(_alphabet, 1 + (get_byte(gen_random_bytes(1), 0) % 22), 1);
  END LOOP;
  RETURN _out;
END;
$$;

-- Normalises what a human typed before comparing: uppercase, strip anything
-- outside the alphabet, and fold the glyph confusions the alphabet avoids so
-- that someone writing "S" for "5" is still understood.
CREATE OR REPLACE FUNCTION church.normalize_pickup_code(_raw TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE
AS $$
  SELECT regexp_replace(
           translate(upper(coalesce(_raw, '')),
                     'OILSZBG',
                     '0115287'),
           '[^23456789ACDEFHJKMNPRTY]', '', 'g')
$$;

CREATE OR REPLACE FUNCTION church.hash_pickup(_value TEXT)
RETURNS BYTEA
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE _pepper BYTEA;
BEGIN
  SELECT pickup_pepper INTO _pepper FROM church.crypto_config WHERE id;
  IF _pepper IS NULL THEN
    RAISE EXCEPTION 'crypto_config_missing';
  END IF;
  -- convert_to(): pgcrypto exposes hmac(text,text,text) and
  -- hmac(bytea,bytea,text), but not a mixed (text,bytea,text) overload.
  RETURN hmac(convert_to(coalesce(_value, ''), 'UTF8'), _pepper, 'sha256');
END;
$$;

-- ---------------------------------------------------------------------------
-- Check in a family
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.check_in_children(
  _kids_session_id UUID,
  _child_person_ids UUID[],
  _room_ids UUID[] DEFAULT NULL,
  _shift_token TEXT DEFAULT NULL,
  _client_batch_key TEXT DEFAULT NULL,
  _dropped_off_by_person_id UUID DEFAULT NULL,
  _override_capacity BOOLEAN DEFAULT false,
  _assignment_reason TEXT DEFAULT NULL
)
RETURNS TABLE (
  batch_id UUID, pickup_code TEXT, pickup_token TEXT,
  check_in_id UUID, child_person_id UUID, child_name TEXT,
  room_id UUID, room_name TEXT, tag_number INTEGER,
  allergy_label TEXT, has_restriction BOOLEAN
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
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
    IF FOUND THEN
      _code := church.generate_pickup_code();
      _token := encode(gen_random_bytes(16), 'base64');
      UPDATE church.kids_check_in_secrets
         SET code_hash = church.hash_pickup(_code),
             token_hash = church.hash_pickup(_token),
             attempts = 0, locked_until = NULL, rotated_at = now()
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

-- One child. Split out so the batch function stays readable; not granted to
-- any client role, so it can only be reached via check_in_children.
CREATE OR REPLACE FUNCTION church.check_in_one_child(
  a church.resolved_actor,
  _kids_session_id UUID,
  _batch UUID,
  _child_person_id UUID,
  _room_id UUID,
  _dropped_off_by_person_id UUID,
  _override_capacity BOOLEAN,
  _assignment_reason TEXT
)
RETURNS UUID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  ch church.people%ROWTYPE;
  ksr church.kids_session_rooms%ROWTYPE;
  _band UUID; _band_code TEXT; _cap INTEGER; _count INTEGER;
  _room_name TEXT; _label_room TEXT; _tag INTEGER; _new UUID;
  _allergy_flag BOOLEAN := false; _allergy TEXT; _special BOOLEAN := false;
  _restricted BOOLEAN;
BEGIN
  SELECT * INTO ch FROM church.people
   WHERE id = _child_person_id AND organization_id = a.organization_id
     AND is_active AND merged_into_person_id IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'child_not_found'; END IF;

  _band := church.age_band_for(a.organization_id, ch.birth_year, ch.birth_month);
  SELECT code INTO _band_code FROM church.kids_age_bands WHERE id = _band;

  -- No room given: pick by age band, then by the emptiest matching room so
  -- parallel classrooms self-balance over a morning.
  IF _room_id IS NULL THEN
    SELECT ksr2.room_id INTO _room_id
    FROM church.kids_session_rooms ksr2
    JOIN church.room_kids_config rkc ON rkc.room_id = ksr2.room_id
    WHERE ksr2.kids_session_id = _kids_session_id
      AND ksr2.is_open AND rkc.is_active AND rkc.is_checkin_location
      AND rkc.kids_age_band_id = _band
    ORDER BY (SELECT count(*) FROM church.kids_check_ins ci
              WHERE ci.kids_session_id = _kids_session_id
                AND ci.room_id = ksr2.room_id AND ci.status = 'checked_in'),
             rkc.sort_order
    LIMIT 1;

    IF _room_id IS NULL THEN
      RAISE EXCEPTION 'no_matching_classroom';
    END IF;
  END IF;

  -- Lock the session-room row so two stations cannot both squeeze the last
  -- place in a full classroom.
  SELECT * INTO ksr FROM church.kids_session_rooms
   WHERE kids_session_id = _kids_session_id AND room_id = _room_id FOR UPDATE;
  IF NOT FOUND OR NOT ksr.is_open THEN RAISE EXCEPTION 'room_not_open'; END IF;

  SELECT coalesce(ksr.capacity_override, rkc.capacity), r.name,
         coalesce(rkc.label_room_name, r.name)
    INTO _cap, _room_name, _label_room
  FROM public.rooms r
  LEFT JOIN church.room_kids_config rkc ON rkc.room_id = r.id
  WHERE r.id = _room_id;

  IF _cap IS NOT NULL AND NOT _override_capacity THEN
    SELECT count(*) INTO _count FROM church.kids_check_ins
     WHERE kids_session_id = _kids_session_id AND room_id = _room_id
       AND status = 'checked_in';
    IF _count >= _cap THEN RAISE EXCEPTION 'room_at_capacity'; END IF;
  END IF;

  -- Sensitive data is read HERE, inside the definer, and only the
  -- label-approved fragment is copied out onto the check-in row.
  SELECT coalesce(s.allergy_severity <> 'none', false),
         s.allergy_label_short,
         coalesce(s.special_needs_flag, false)
    INTO _allergy_flag, _allergy, _special
  FROM church.person_sensitive s WHERE s.person_id = _child_person_id;

  SELECT EXISTS (
    SELECT 1 FROM church.kids_pickup_restrictions pr
    WHERE pr.child_person_id = _child_person_id
      AND pr.effective_from <= CURRENT_DATE
      AND (pr.effective_to IS NULL OR pr.effective_to >= CURRENT_DATE)
  ) INTO _restricted;

  UPDATE church.kids_sessions
     SET next_tag_number = next_tag_number + 1
   WHERE id = _kids_session_id
  RETURNING next_tag_number - 1 INTO _tag;

  INSERT INTO church.kids_check_ins (
    organization_id, batch_id, kids_session_id, child_person_id, room_id,
    household_id, tag_number, label_child_name, label_room_name,
    label_age_band_code, label_allergy_flag, label_allergy_short,
    label_special_needs_flag, has_pickup_restriction,
    checked_in_by_station_id, checked_in_by_volunteer_id, checked_in_by_name,
    dropped_off_by_person_id, assignment_reason
  ) VALUES (
    a.organization_id, _batch, _kids_session_id, _child_person_id, _room_id,
    (SELECT household_id FROM church.kids_check_in_batches WHERE id = _batch),
    _tag,
    coalesce(ch.preferred_name, ch.first_name) || ' ' || ch.last_name,
    _label_room, _band_code, coalesce(_allergy_flag, false), _allergy,
    coalesce(_special, false), _restricted,
    a.station_id, a.volunteer_id, a.actor_name,
    _dropped_off_by_person_id, _assignment_reason
  ) RETURNING id INTO _new;

  INSERT INTO church.check_in_audit (
    organization_id, action, check_in_id, batch_id, kids_session_id,
    child_person_id, room_id, station_id, volunteer_id,
    actor_auth_user_id, actor_name, detail)
  VALUES (
    a.organization_id, 'check_in', _new, _batch, _kids_session_id,
    _child_person_id, _room_id, a.station_id, a.volunteer_id,
    auth.uid(), a.actor_name,
    jsonb_build_object('tag', _tag, 'source', a.source,
                       'capacity_overridden', _override_capacity,
                       'age_band', _band_code));
  RETURN _new;
END;
$$;

-- ---------------------------------------------------------------------------
-- Resolve a presented credential
-- ---------------------------------------------------------------------------
-- Returns zero rows for every failure — wrong code, expired, locked, already
-- consumed, unknown — so the checkout desk is not an oracle. Increments the
-- attempt counter, which is why it returns rather than raising.
CREATE OR REPLACE FUNCTION church.resolve_pickup(
  _kids_session_id UUID,
  _presented TEXT,
  _shift_token TEXT DEFAULT NULL
)
RETURNS TABLE (
  batch_id UUID, check_in_id UUID, child_person_id UUID, child_name TEXT,
  room_name TEXT, tag_number INTEGER, status TEXT, has_restriction BOOLEAN
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  a church.resolved_actor;
  sec church.kids_check_in_secrets%ROWTYPE;
  _norm TEXT;
  _code_hash BYTEA;
  _token_hash BYTEA;
BEGIN
  a := church.resolve_actor(_shift_token);
  IF NOT a.can_check_out THEN
    RAISE EXCEPTION 'not_permitted_to_check_out' USING ERRCODE = '42501';
  END IF;

  -- Hash both interpretations unconditionally and before any branch, so the
  -- work done is the same whether or not anything matches.
  _norm := church.normalize_pickup_code(_presented);
  _code_hash := church.hash_pickup(_norm);
  _token_hash := church.hash_pickup(btrim(coalesce(_presented, '')));

  SELECT * INTO sec FROM church.kids_check_in_secrets s
  WHERE s.kids_session_id = _kids_session_id
    AND s.consumed_at IS NULL
    AND (s.code_hash = _code_hash OR s.token_hash = _token_hash)
  LIMIT 1;

  IF NOT FOUND
     OR sec.expires_at <= now()
     OR (sec.locked_until IS NOT NULL AND sec.locked_until > now()) THEN
    IF sec.batch_id IS NOT NULL THEN
      UPDATE church.kids_check_in_secrets
         SET attempts = attempts + 1,
             locked_until = CASE WHEN attempts + 1 >= 5
                                 THEN now() + interval '10 minutes'
                                 ELSE locked_until END
       WHERE kids_check_in_secrets.batch_id = sec.batch_id;
    END IF;

    INSERT INTO church.check_in_audit
      (organization_id, action, outcome, kids_session_id, station_id,
       volunteer_id, actor_auth_user_id, actor_name)
    VALUES (a.organization_id, 'code_failed', 'denied', _kids_session_id,
            a.station_id, a.volunteer_id, auth.uid(), a.actor_name);
    RETURN;   -- zero rows: see the note at the top of this file
  END IF;

  UPDATE church.kids_check_in_secrets
     SET attempts = 0, locked_until = NULL
   WHERE kids_check_in_secrets.batch_id = sec.batch_id;

  RETURN QUERY
  SELECT ci.batch_id, ci.id, ci.child_person_id, ci.label_child_name,
         ci.label_room_name, ci.tag_number, ci.status, ci.has_pickup_restriction
  FROM church.kids_check_ins ci
  WHERE ci.batch_id = sec.batch_id
  ORDER BY ci.tag_number;
END;
$$;

-- ---------------------------------------------------------------------------
-- Check out
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.check_out_children(
  _check_in_ids UUID[],
  _presented TEXT DEFAULT NULL,
  _shift_token TEXT DEFAULT NULL,
  _picked_up_by_person_id UUID DEFAULT NULL,
  _picked_up_by_name TEXT DEFAULT NULL,
  _override_reason TEXT DEFAULT NULL,
  _override_verification TEXT DEFAULT NULL,
  _override_authorizer_volunteer_id UUID DEFAULT NULL,
  _override_authorizer_pin TEXT DEFAULT NULL
)
RETURNS TABLE (check_in_id UUID, child_name TEXT, checked_out_at TIMESTAMPTZ)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  a church.resolved_actor;
  ci church.kids_check_ins%ROWTYPE;
  sec church.kids_check_in_secrets%ROWTYPE;
  _method TEXT;
  _authorizer UUID;
  _auth_hash TEXT;
  _restricted BOOLEAN;
  _id UUID;
BEGIN
  a := church.resolve_actor(_shift_token);
  IF NOT a.can_check_out THEN
    RAISE EXCEPTION 'not_permitted_to_check_out' USING ERRCODE = '42501';
  END IF;

  IF _check_in_ids IS NULL OR array_length(_check_in_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'no_check_ins_supplied';
  END IF;

  SELECT * INTO ci FROM church.kids_check_ins
   WHERE id = _check_in_ids[1] AND organization_id = a.organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'check_in_not_found'; END IF;

  IF _override_reason IS NOT NULL THEN
    -- KID-012: an override needs a SECOND authorised volunteer, who must be a
    -- different person from the one operating the desk. This two-person rule
    -- is what makes every other control here meaningful, so it is enforced in
    -- the database rather than the UI.
    IF _override_authorizer_volunteer_id IS NULL OR _override_authorizer_pin IS NULL THEN
      RAISE EXCEPTION 'override_requires_second_volunteer';
    END IF;
    IF a.volunteer_id IS NOT NULL
       AND _override_authorizer_volunteer_id = a.volunteer_id THEN
      RAISE EXCEPTION 'override_requires_different_volunteer';
    END IF;

    SELECT p.pin_hash INTO _auth_hash
    FROM church.kids_volunteer_pins p
    JOIN church.kids_volunteers v ON v.id = p.volunteer_id
    WHERE p.volunteer_id = _override_authorizer_volunteer_id
      AND v.organization_id = a.organization_id
      AND v.is_active AND v.can_override
      AND v.background_check_status <> 'restricted';

    IF _auth_hash IS NULL OR _auth_hash <> crypt(_override_authorizer_pin, _auth_hash) THEN
      RAISE EXCEPTION 'override_authorization_failed' USING ERRCODE = '28000';
    END IF;

    _authorizer := _override_authorizer_volunteer_id;
    _method := 'operator_override';
  ELSE
    -- Normal path: a valid, unexpired, unlocked credential for this batch.
    SELECT * INTO sec FROM church.kids_check_in_secrets s
    WHERE s.batch_id = ci.batch_id
      AND s.consumed_at IS NULL
      AND s.expires_at > now()
      AND (s.locked_until IS NULL OR s.locked_until <= now())
      AND (s.code_hash = church.hash_pickup(church.normalize_pickup_code(_presented))
        OR s.token_hash = church.hash_pickup(btrim(coalesce(_presented, ''))));

    IF NOT FOUND THEN
      INSERT INTO church.check_in_audit
        (organization_id, action, outcome, check_in_id, child_person_id,
         station_id, volunteer_id, actor_auth_user_id, actor_name)
      VALUES (a.organization_id, 'code_failed', 'denied', ci.id, ci.child_person_id,
              a.station_id, a.volunteer_id, auth.uid(), a.actor_name);
      RETURN;   -- zero rows
    END IF;
    _method := 'security_code';
  END IF;

  -- KID-014: a restricted person is never released to, on any path. There is
  -- deliberately no override that permits it.
  IF _picked_up_by_person_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM church.kids_pickup_restrictions pr
      WHERE pr.child_person_id = ci.child_person_id
        AND pr.restricted_person_id = _picked_up_by_person_id
        AND pr.effective_from <= CURRENT_DATE
        AND (pr.effective_to IS NULL OR pr.effective_to >= CURRENT_DATE)
    ) INTO _restricted;

    IF _restricted THEN
      INSERT INTO church.check_in_audit
        (organization_id, action, outcome, check_in_id, child_person_id,
         station_id, volunteer_id, actor_auth_user_id, actor_name, detail)
      VALUES (a.organization_id, 'restricted_pickup_attempt', 'denied', ci.id,
              ci.child_person_id, a.station_id, a.volunteer_id, auth.uid(),
              a.actor_name,
              jsonb_build_object('attempted_person_id', _picked_up_by_person_id));
      RETURN;   -- zero rows; the caller shows "see the Kids Ministry lead"
    END IF;
  END IF;

  FOREACH _id IN ARRAY _check_in_ids LOOP
    UPDATE church.kids_check_ins
       SET status = 'checked_out',
           checked_out_at = now(),
           checked_out_by_station_id = a.station_id,
           checked_out_by_volunteer_id = a.volunteer_id,
           checked_out_by_name = a.actor_name,
           picked_up_by_person_id = _picked_up_by_person_id,
           picked_up_by_name = coalesce(_picked_up_by_name, 'unrecorded'),
           checkout_method = _method,
           override_reason = _override_reason,
           override_verification = _override_verification,
           override_authorized_by_volunteer_id = _authorizer
     WHERE id = _id
       AND organization_id = a.organization_id
       AND status = 'checked_in';

    INSERT INTO church.check_in_audit
      (organization_id, action, check_in_id, batch_id, kids_session_id,
       child_person_id, station_id, volunteer_id, actor_auth_user_id,
       actor_name, detail)
    SELECT a.organization_id,
           CASE WHEN _method = 'operator_override' THEN 'override' ELSE 'check_out' END,
           c.id, c.batch_id, c.kids_session_id, c.child_person_id,
           a.station_id, a.volunteer_id, auth.uid(), a.actor_name,
           jsonb_build_object('method', _method,
                              'picked_up_by', _picked_up_by_name,
                              'override_reason', _override_reason,
                              'verification', _override_verification,
                              'authorized_by', _authorizer)
    FROM church.kids_check_ins c WHERE c.id = _id;
  END LOOP;

  -- Burn the credential once every child on it has gone home.
  UPDATE church.kids_check_in_secrets s
     SET consumed_at = now()
   WHERE s.batch_id = ci.batch_id
     AND NOT EXISTS (SELECT 1 FROM church.kids_check_ins c
                     WHERE c.batch_id = ci.batch_id AND c.status = 'checked_in');

  RETURN QUERY
  SELECT c.id, c.label_child_name, c.checked_out_at
  FROM church.kids_check_ins c
  WHERE c.id = ANY(_check_in_ids) AND c.status = 'checked_out';
END;
$$;

-- ---------------------------------------------------------------------------
-- Transfer between classrooms (KID-020)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.transfer_child(
  _check_in_id UUID, _to_room_id UUID,
  _shift_token TEXT DEFAULT NULL, _reason TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  a church.resolved_actor;
  ci church.kids_check_ins%ROWTYPE;
  _label TEXT;
BEGIN
  a := church.resolve_actor(_shift_token);
  IF NOT a.can_check_in THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO ci FROM church.kids_check_ins
   WHERE id = _check_in_id AND organization_id = a.organization_id
     AND status = 'checked_in';
  IF NOT FOUND THEN RAISE EXCEPTION 'check_in_not_active'; END IF;
  IF ci.room_id = _to_room_id THEN RAISE EXCEPTION 'already_in_that_room'; END IF;

  PERFORM 1 FROM church.kids_session_rooms
   WHERE kids_session_id = ci.kids_session_id AND room_id = _to_room_id AND is_open;
  IF NOT FOUND THEN RAISE EXCEPTION 'room_not_open'; END IF;

  SELECT coalesce(rkc.label_room_name, r.name) INTO _label
  FROM public.rooms r LEFT JOIN church.room_kids_config rkc ON rkc.room_id = r.id
  WHERE r.id = _to_room_id;

  INSERT INTO church.kids_check_in_location_history
    (organization_id, check_in_id, from_room_id, to_room_id,
     changed_by_volunteer_id, changed_by_name, reason)
  VALUES (a.organization_id, _check_in_id, ci.room_id, _to_room_id,
          a.volunteer_id, a.actor_name, _reason);

  -- The check-in row moves; the original room survives in the history table,
  -- so "where has this child been today" is answerable.
  UPDATE church.kids_check_ins
     SET room_id = _to_room_id, label_room_name = _label
   WHERE id = _check_in_id;

  INSERT INTO church.check_in_audit
    (organization_id, action, check_in_id, kids_session_id, child_person_id,
     room_id, station_id, volunteer_id, actor_auth_user_id, actor_name, detail)
  VALUES (a.organization_id, 'transfer', _check_in_id, ci.kids_session_id,
          ci.child_person_id, _to_room_id, a.station_id, a.volunteer_id,
          auth.uid(), a.actor_name,
          jsonb_build_object('from_room', ci.room_id, 'reason', _reason));
END;
$$;

-- ---------------------------------------------------------------------------
-- Station lookup and the audited safety card
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.station_search_households(
  _query TEXT, _kids_session_id UUID, _shift_token TEXT DEFAULT NULL)
RETURNS TABLE (
  household_id UUID, household_name TEXT, masked_phone TEXT,
  child_person_id UUID, child_display_name TEXT, age_band_code TEXT,
  already_checked_in BOOLEAN, needs_staff BOOLEAN
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

  -- Note the projection: last INITIAL only, phone masked to the last four,
  -- no address, no email, no birthday. A photograph of the tablet screen
  -- leaks very little.
  --
  -- The adult match is an EXISTS rather than a JOIN: joining would multiply
  -- one child row by the number of adults in the household, and the SELECT
  -- DISTINCT needed to collapse that cannot ORDER BY a computed column.
  RETURN QUERY
  SELECT
    h.id, h.name,
    ph.masked,
    c.id,
    coalesce(c.preferred_name, c.first_name) || ' ' || left(c.last_name, 1) || '.',
    b.code,
    EXISTS (SELECT 1 FROM church.kids_check_ins ci
            WHERE ci.child_person_id = c.id
              AND ci.kids_session_id = _kids_session_id
              AND ci.status = 'checked_in'),
    EXISTS (SELECT 1 FROM church.kids_pickup_restrictions pr
            WHERE pr.child_person_id = c.id AND pr.effective_to IS NULL)
  FROM church.households h
  JOIN church.household_members chm
    ON chm.household_id = h.id AND chm.end_date IS NULL
  JOIN church.people c
    ON c.id = chm.person_id AND c.is_child AND c.is_active
   AND c.merged_into_person_id IS NULL
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

-- KID-018 / KID-025: the minimum a classroom volunteer needs in an emergency,
-- and EVERY access is recorded with their name.
CREATE OR REPLACE FUNCTION church.station_child_safety_card(
  _check_in_id UUID, _shift_token TEXT DEFAULT NULL)
RETURNS TABLE (
  child_name TEXT, allergy_severity TEXT, allergies TEXT, medications TEXT,
  special_needs TEXT, emergency_name TEXT, emergency_phone TEXT)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  a church.resolved_actor;
  ci church.kids_check_ins%ROWTYPE;
BEGIN
  a := church.resolve_actor(_shift_token);
  SELECT * INTO ci FROM church.kids_check_ins
   WHERE id = _check_in_id AND organization_id = a.organization_id
     AND status = 'checked_in';
  IF NOT FOUND THEN RAISE EXCEPTION 'check_in_not_active'; END IF;

  INSERT INTO church.check_in_audit
    (organization_id, action, check_in_id, child_person_id, station_id,
     volunteer_id, actor_auth_user_id, actor_name)
  VALUES (a.organization_id, 'sensitive_viewed', _check_in_id,
          ci.child_person_id, a.station_id, a.volunteer_id, auth.uid(), a.actor_name);

  RETURN QUERY
  SELECT ci.label_child_name, s.allergy_severity, s.allergies, s.medications,
         s.special_needs, ec.name, ec.phone
  FROM (SELECT 1) dummy
  LEFT JOIN church.person_sensitive s ON s.person_id = ci.child_person_id
  LEFT JOIN LATERAL (
    SELECT e.name, e.phone FROM church.person_emergency_contacts e
    WHERE e.person_id = ci.child_person_id ORDER BY e.priority LIMIT 1
  ) ec ON true;
END;
$$;

-- ---------------------------------------------------------------------------
-- Stale check-in expiry
-- ---------------------------------------------------------------------------
-- 'expired' is a data-hygiene state. It records that nobody checked the child
-- out, NOT a claim that the child was collected, and it is reported separately.
CREATE OR REPLACE FUNCTION church.expire_stale_check_ins()
RETURNS INTEGER
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE _n INTEGER;
BEGIN
  WITH stale AS (
    UPDATE church.kids_check_ins ci
       SET status = 'expired', checked_out_at = now(),
           checkout_method = 'system_auto',
           checked_out_by_name = 'system (auto-expire)'
      FROM church.kids_sessions ks, church.kids_events ke
     WHERE ks.id = ci.kids_session_id AND ke.id = ks.kids_event_id
       AND ci.status = 'checked_in'
       AND now() > ks.ends_at + make_interval(mins => ke.auto_expire_minutes_after_end)
    RETURNING ci.id, ci.organization_id, ci.child_person_id, ci.kids_session_id
  )
  INSERT INTO church.check_in_audit
    (organization_id, action, outcome, check_in_id, kids_session_id,
     child_person_id, actor_name)
  SELECT organization_id, 'auto_expired', 'success', id, kids_session_id,
         child_person_id, 'system'
  FROM stale;
  GET DIAGNOSTICS _n = ROW_COUNT;
  RETURN _n;
END;
$$;

-- Grants. check_in_one_child is deliberately absent: it is reachable only
-- from check_in_children.
GRANT EXECUTE ON FUNCTION church.check_in_children(UUID, UUID[], UUID[], TEXT, TEXT, UUID, BOOLEAN, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION church.resolve_pickup(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION church.check_out_children(UUID[], TEXT, TEXT, UUID, TEXT, TEXT, TEXT, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION church.transfer_child(UUID, UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION church.station_search_households(TEXT, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION church.station_child_safety_card(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION church.expire_stale_check_ins() TO service_role;

-- Realtime for the live classroom roster. REPLICA IDENTITY FULL broadcasts
-- every column of every change, which is only acceptable because the pickup
-- credentials live in a separate table that is not published.
ALTER TABLE church.kids_check_ins REPLICA IDENTITY FULL;
DO $rt$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE church.kids_check_ins;
EXCEPTION
  WHEN undefined_object THEN
    RAISE NOTICE 'supabase_realtime publication not present (local test db)';
  WHEN duplicate_object THEN
    RAISE NOTICE 'church.kids_check_ins already in supabase_realtime';
END
$rt$;

NOTIFY pgrst, 'reload schema';
