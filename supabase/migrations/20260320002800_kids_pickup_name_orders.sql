-- =====================================================
-- Restrictions that name a person we have no id for
-- =====================================================
--
-- 20260320002400 made a restricted child releasable only to an approved
-- collector. Adversarial testing then released a court-restricted child to the
-- man named in the order. Four defects, all of them in the same seam:
--
-- C-1. kids_pickup_restrictions.restricted_person_id is NULLABLE — the table
--      deliberately allows an order against a NAME when the church has no
--      member record for that person, which is the common case for an
--      estranged parent. is_approved_collector compared ids only, so a
--      name-only order made child_has_active_restriction TRUE (blocking the
--      anonymous path) while the household branch cheerfully approved the very
--      person named. The desk then OFFERED him, under the red banner.
--
--      There is also no UI anywhere for kids_pickup_restrictions, so orders get
--      typed into Supabase Studio by hand, where nothing forces the id.
--      Name-only is the likely shape, not the edge case.
--
-- C-3. The mirror failure: a restricted child with no household_members row
--      had NO approved collector at all, and the gate deliberately runs before
--      the override branch — so their own mother, with the code and photo ID,
--      could not collect them by any path. Every CSV-imported family is in
--      exactly that state: 20260320001300 never writes a household row.
--
-- C-7. The gate tested every id in the array regardless of status, so a
--      sibling already collected blocked a sibling still in the room.
--
-- C-8. Naming a lapsed member as the collector denied an UNRESTRICTED child.
--
-- The rule that must not bend: a child never leaves with a person the order
-- names. Everything else is about not stranding children whose paperwork is
-- merely incomplete.

-- ---------------------------------------------------------------------------
-- Two audit actions the log could not record
-- ---------------------------------------------------------------------------
--
-- `restricted_pickup_override` is new below: a release the ministry must be
-- able to find later, kept distinct from a routine `check_out` precisely so it
-- cannot hide among them.
--
-- `pin_failed` was already being FILTERED FOR by kids_exceptions_report
-- (20260320001900) while the constraint rejected it, so "who was locked out at
-- the desk" could only ever return nothing.
ALTER TABLE church.check_in_audit
  DROP CONSTRAINT IF EXISTS chk_check_in_audit_action;

ALTER TABLE church.check_in_audit
  ADD CONSTRAINT chk_check_in_audit_action CHECK (action = ANY (ARRAY[
    'check_in', 'check_out', 'transfer', 'code_failed', 'override',
    'sensitive_viewed', 'restricted_pickup_attempt', 'restricted_pickup_override',
    'pin_failed', 'auto_expired', 'label_reprint', 'shift_opened', 'shift_closed'
  ]));

-- ---------------------------------------------------------------------------
-- Does this order name this person, by id OR by name?
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.restriction_names_person(
  _child_person_id UUID, _person_id UUID, _person_name TEXT DEFAULT NULL)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = church, public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM church.kids_pickup_restrictions pr
    LEFT JOIN church.people p ON p.id = _person_id
    WHERE pr.child_person_id = _child_person_id
      AND pr.effective_from <= CURRENT_DATE
      AND (pr.effective_to IS NULL OR pr.effective_to >= CURRENT_DATE)
      AND (
        -- Named by id.
        (pr.restricted_person_id IS NOT NULL
         AND pr.restricted_person_id = _person_id)
        -- Or named by name, matched against whoever is being presented —
        -- either the person record chosen at the desk, or the free-text name
        -- typed into "Someone else".
        OR (pr.restricted_person_name IS NOT NULL
            AND btrim(pr.restricted_person_name) <> ''
            AND (
              lower(btrim(pr.restricted_person_name))
                = lower(btrim(coalesce(_person_name, '')))
              OR (p.id IS NOT NULL
                  AND lower(btrim(pr.restricted_person_name)) = lower(btrim(
                       coalesce(p.preferred_name, p.first_name) || ' ' || p.last_name)))
              OR (p.id IS NOT NULL
                  AND lower(btrim(pr.restricted_person_name)) = lower(btrim(
                       p.first_name || ' ' || p.last_name)))
            ))
      )
  );
$$;

-- Deliberately NOT granted to `authenticated`: it answers "is there a
-- protective order naming this person", which is nobody's business but the
-- desk's, and the desk reaches it through a SECURITY DEFINER RPC.
REVOKE ALL ON FUNCTION church.restriction_names_person(UUID, UUID, TEXT) FROM PUBLIC;

-- Same reasoning, retrofitted: these two were granted to `authenticated` and
-- are org-unscoped and unaudited, so any signed-in user could iterate person
-- ids and enumerate which children are under a protective order and who may
-- collect each one. Their only real callers are SECURITY DEFINER functions,
-- which do not need the grant.
REVOKE EXECUTE ON FUNCTION church.child_has_active_restriction(UUID) FROM authenticated;
REVOKE EXECUTE ON FUNCTION church.is_approved_collector(UUID, UUID) FROM authenticated;

-- ---------------------------------------------------------------------------
-- Who may collect, widened for real data and narrowed for name orders
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.is_approved_collector(
  _child_person_id UUID, _person_id UUID, _person_name TEXT DEFAULT NULL)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = church, public
AS $$
  SELECT _person_id IS NOT NULL
     -- An order naming this person, by id or by name, always wins.
     AND NOT church.restriction_names_person(
                _child_person_id, _person_id, _person_name)
     AND (
       -- Explicitly authorised for this child. This is the only route that
       -- survives a name-only order, because it is the only one where a human
       -- has positively vetted this individual for this child.
       EXISTS (
         SELECT 1 FROM church.kids_pickup_authorizations pa
         WHERE pa.child_person_id = _child_person_id
           AND pa.authorized_person_id = _person_id
           AND pa.effective_from <= CURRENT_DATE
           AND (pa.effective_to IS NULL OR pa.effective_to >= CURRENT_DATE))
       OR (
         -- Household adult, or a recorded guardian relationship. The
         -- relationship branch matters because CSV import creates people and
         -- relationships but no households, so household-only approval left
         -- every imported family with nobody able to collect.
         --
         -- Both are switched OFF when a live order names someone we cannot
         -- identify: if the church holds an order against "JEx2 Test" and no
         -- id for him, then "an adult of the household" is exactly the set he
         -- might be hiding in.
         NOT EXISTS (
           SELECT 1 FROM church.kids_pickup_restrictions pr
           WHERE pr.child_person_id = _child_person_id
             AND pr.restricted_person_id IS NULL
             AND pr.effective_from <= CURRENT_DATE
             AND (pr.effective_to IS NULL OR pr.effective_to >= CURRENT_DATE))
         AND (
           EXISTS (
             SELECT 1
             FROM church.household_members hm_child
             JOIN church.household_members hm_adult
               ON hm_adult.household_id = hm_child.household_id
              AND hm_adult.end_date IS NULL
             JOIN church.people p
               ON p.id = hm_adult.person_id AND NOT p.is_child AND p.is_active
             WHERE hm_child.person_id = _child_person_id
               AND hm_child.end_date IS NULL
               AND p.id = _person_id)
           OR EXISTS (
             SELECT 1
             FROM church.person_relationships rel
             JOIN church.relationship_types rt
               ON rt.id = rel.relationship_type_id AND rt.implies_guardianship
             JOIN church.people p
               ON p.id = rel.person_id AND p.is_active AND NOT p.is_child
             WHERE rel.person_id = _person_id
               AND rel.related_person_id = _child_person_id
               AND rel.end_date IS NULL)
         )
       )
     );
$$;

REVOKE ALL ON FUNCTION church.is_approved_collector(UUID, UUID, TEXT) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- Checkout
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
  _ids UUID[];
  _live UUID[];
  _method TEXT;
  _authorizer UUID;
  _authorizer_name TEXT;
  _auth_hash TEXT;
  _names_restricted BOOLEAN;
  _blocked INTEGER;
  _id UUID;
  _updated INTEGER;
  _released UUID[] := '{}';
BEGIN
  a := church.resolve_actor(_shift_token);
  IF NOT a.can_check_out THEN
    RAISE EXCEPTION 'not_permitted_to_check_out' USING ERRCODE = '42501';
  END IF;

  IF _check_in_ids IS NULL OR array_length(_check_in_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'no_check_ins_supplied';
  END IF;

  SELECT array_agg(DISTINCT x) INTO _ids FROM unnest(_check_in_ids) AS x
   WHERE x IS NOT NULL;
  IF _ids IS NULL THEN RAISE EXCEPTION 'no_check_ins_supplied'; END IF;

  -- Anchor on the batch, not on _ids[1]. array_agg(DISTINCT) sorts, so the
  -- first element was the lowest uuid — which meant an unknown id sorting
  -- first RAISED (aborting the transaction and losing the audit row) while the
  -- same probe sorting last got the silent audited denial. Different responses
  -- for the same mistake is an oracle.
  SELECT * INTO ci FROM church.kids_check_ins k
   WHERE k.id = ANY(_ids) AND k.organization_id = a.organization_id
   ORDER BY k.checked_in_at LIMIT 1;
  IF NOT FOUND THEN
    RETURN;   -- zero rows, like every other denial
  END IF;

  IF (SELECT count(*) FROM church.kids_check_ins k
       WHERE k.id = ANY(_ids)
         AND k.organization_id = a.organization_id
         AND k.batch_id = ci.batch_id
         AND k.kids_session_id = ci.kids_session_id)
     <> array_length(_ids, 1) THEN
    INSERT INTO church.check_in_audit
      (organization_id, action, outcome, check_in_id, batch_id, kids_session_id,
       child_person_id, station_id, volunteer_id, actor_auth_user_id,
       actor_name, detail)
    VALUES (a.organization_id, 'check_out', 'denied', ci.id, ci.batch_id,
            ci.kids_session_id, ci.child_person_id, a.station_id, a.volunteer_id,
            auth.uid(), a.actor_name,
            jsonb_build_object('reason', 'check-ins span more than one batch'));
    RETURN;
  END IF;

  -- C-7: only children still in a room are being released, so only they are
  -- checked. A sibling collected an hour ago must not block the one still here.
  SELECT array_agg(k.id) INTO _live
  FROM church.kids_check_ins k
  WHERE k.id = ANY(_ids) AND k.organization_id = a.organization_id
    AND k.status = 'checked_in';

  IF _live IS NULL THEN
    RETURN;   -- nothing left to release
  END IF;

  -- C-1: does the collector appear in any live order for any of these
  -- children, by id or by name? This is the absolute bar, and it is checked
  -- before the code/override branch so nothing can step around it.
  SELECT EXISTS (
    SELECT 1 FROM church.kids_check_ins k
    WHERE k.id = ANY(_live)
      AND church.restriction_names_person(
            k.child_person_id, _picked_up_by_person_id, _picked_up_by_name)
  ) INTO _names_restricted;

  IF _names_restricted THEN
    INSERT INTO church.check_in_audit
      (organization_id, action, outcome, check_in_id, batch_id, kids_session_id,
       child_person_id, station_id, volunteer_id, actor_auth_user_id,
       actor_name, detail)
    SELECT a.organization_id, 'restricted_pickup_attempt', 'denied', k.id,
           k.batch_id, k.kids_session_id, k.child_person_id, a.station_id,
           a.volunteer_id, auth.uid(), a.actor_name,
           jsonb_build_object(
             'reason', 'collector is named in a protective order',
             'attempted_person_id', _picked_up_by_person_id,
             'attempted_name', _picked_up_by_name)
    FROM church.kids_check_ins k
    WHERE k.id = ANY(_live)
      AND church.restriction_names_person(
            k.child_person_id, _picked_up_by_person_id, _picked_up_by_name);
    RETURN;
  END IF;

  -- C-8: identity is required only where it buys something. For a child with
  -- no order, the code is the credential and a lapsed member record is not a
  -- reason to refuse their own parent.
  IF _picked_up_by_person_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM church.people p
                     WHERE p.id = _picked_up_by_person_id
                       AND p.organization_id = a.organization_id) THEN
    INSERT INTO church.check_in_audit
      (organization_id, action, outcome, check_in_id, batch_id, kids_session_id,
       child_person_id, station_id, volunteer_id, actor_auth_user_id,
       actor_name, detail)
    VALUES (a.organization_id, 'check_out', 'denied', ci.id, ci.batch_id,
            ci.kids_session_id, ci.child_person_id, a.station_id, a.volunteer_id,
            auth.uid(), a.actor_name,
            jsonb_build_object('reason', 'collector is not a person on file',
                               'attempted_person_id', _picked_up_by_person_id));
    RETURN;
  END IF;

  -- A child under an order leaves only with an approved collector — unless an
  -- admin takes responsibility. C-3: without this, a restricted child whose
  -- family was CSV-imported (people and relationships, no household row) could
  -- not be collected by anyone at all, including their own mother with the
  -- code and photo ID, and no override existed because the gate ran first.
  --
  -- The break-glass never reaches the person the order names — that was ruled
  -- out above and has no override. It only answers "the paperwork does not
  -- list anyone", which is a records problem, not a custody one.
  SELECT count(*) INTO _blocked
  FROM church.kids_check_ins k
  WHERE k.id = ANY(_live)
    AND church.child_has_active_restriction(k.child_person_id)
    AND NOT church.is_approved_collector(
              k.child_person_id, _picked_up_by_person_id, _picked_up_by_name);

  IF _blocked > 0 THEN
    IF _override_reason IS NULL OR NOT a.can_override THEN
      INSERT INTO church.check_in_audit
        (organization_id, action, outcome, check_in_id, batch_id,
         kids_session_id, child_person_id, station_id, volunteer_id,
         actor_auth_user_id, actor_name, detail)
      SELECT a.organization_id, 'restricted_pickup_attempt', 'denied', k.id,
             k.batch_id, k.kids_session_id, k.child_person_id, a.station_id,
             a.volunteer_id, auth.uid(), a.actor_name,
             jsonb_build_object(
               'reason', CASE WHEN _picked_up_by_person_id IS NULL
                              THEN 'collector not identified'
                              ELSE 'collector is not on the approved list' END,
               'attempted_person_id', _picked_up_by_person_id,
               'attempted_name', _picked_up_by_name,
               'override_available', a.can_override)
      FROM church.kids_check_ins k
      WHERE k.id = ANY(_live)
        AND church.child_has_active_restriction(k.child_person_id)
        AND NOT church.is_approved_collector(
                  k.child_person_id, _picked_up_by_person_id, _picked_up_by_name);
      RETURN;
    END IF;

    -- Recorded as its own action so it is never mistaken for a routine
    -- release when the ministry reviews the week.
    INSERT INTO church.check_in_audit
      (organization_id, action, outcome, check_in_id, batch_id, kids_session_id,
       child_person_id, station_id, volunteer_id, actor_auth_user_id,
       actor_name, detail)
    SELECT a.organization_id, 'restricted_pickup_override', 'success', k.id,
           k.batch_id, k.kids_session_id, k.child_person_id, a.station_id,
           a.volunteer_id, auth.uid(), a.actor_name,
           jsonb_build_object('reason', _override_reason,
                              'verification', _override_verification,
                              'released_to', _picked_up_by_name,
                              'released_to_person_id', _picked_up_by_person_id)
    FROM church.kids_check_ins k
    WHERE k.id = ANY(_live)
      AND church.child_has_active_restriction(k.child_person_id)
      AND NOT church.is_approved_collector(
                k.child_person_id, _picked_up_by_person_id, _picked_up_by_name);
  END IF;

  IF _override_reason IS NOT NULL THEN
    IF NOT a.can_override THEN
      RAISE EXCEPTION 'override_requires_admin' USING ERRCODE = '42501';
    END IF;

    IF _override_authorizer_volunteer_id IS NOT NULL
       AND _override_authorizer_pin IS NOT NULL THEN
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
      SELECT coalesce(pp.preferred_name, pp.first_name) || ' ' || pp.last_name
        INTO _authorizer_name
      FROM church.kids_volunteers vv
      JOIN church.people pp ON pp.id = vv.person_id
      WHERE vv.id = _override_authorizer_volunteer_id;
    ELSE
      _authorizer := a.volunteer_id;
      _authorizer_name := a.actor_name;
    END IF;

    _method := 'operator_override';
  ELSE
    SELECT * INTO sec FROM church.kids_check_in_secrets s
    WHERE s.batch_id = ci.batch_id
      AND s.consumed_at IS NULL
      AND s.expires_at > now()
      AND (s.locked_until IS NULL OR s.locked_until <= now())
      AND (s.code_hash = church.hash_pickup(church.normalize_pickup_code(_presented))
        OR s.token_hash = church.hash_pickup(btrim(coalesce(_presented, ''))));

    IF NOT FOUND THEN
      INSERT INTO church.check_in_audit
        (organization_id, action, outcome, check_in_id, batch_id, kids_session_id,
         child_person_id, station_id, volunteer_id, actor_auth_user_id, actor_name)
      VALUES (a.organization_id, 'code_failed', 'denied', ci.id, ci.batch_id,
              ci.kids_session_id, ci.child_person_id, a.station_id, a.volunteer_id,
              auth.uid(), a.actor_name);
      RETURN;
    END IF;
    _method := 'security_code';
  END IF;

  FOREACH _id IN ARRAY _live LOOP
    UPDATE church.kids_check_ins k
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
           override_authorized_by_volunteer_id = _authorizer,
           override_authorized_by_name = _authorizer_name
     WHERE k.id = _id
       AND k.organization_id = a.organization_id
       AND k.batch_id = ci.batch_id
       AND k.kids_session_id = ci.kids_session_id
       AND k.status = 'checked_in';

    -- Only audit what actually changed. The loop used to write a success row
    -- unconditionally, so re-sending an already-collected child produced a
    -- second check_out — indistinguishable from a duplicate collection, which
    -- is precisely the incident this log exists to detect.
    GET DIAGNOSTICS _updated = ROW_COUNT;
    IF _updated = 0 THEN CONTINUE; END IF;
    _released := _released || _id;

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
                              'picked_up_by_person_id', _picked_up_by_person_id,
                              'override_reason', _override_reason,
                              'verification', _override_verification,
                              'authorized_by', coalesce(_authorizer_name, 'unknown'))
    FROM church.kids_check_ins c WHERE c.id = _id;
  END LOOP;

  UPDATE church.kids_check_in_secrets s
     SET consumed_at = now()
   WHERE s.batch_id = ci.batch_id
     AND NOT EXISTS (SELECT 1 FROM church.kids_check_ins c
                     WHERE c.batch_id = ci.batch_id AND c.status = 'checked_in');

  -- Only children released by THIS call, so the caller cannot be told it
  -- collected someone who went home an hour ago.
  RETURN QUERY
  SELECT c.id, c.label_child_name, c.checked_out_at
  FROM church.kids_check_ins c
  WHERE c.id = ANY(_released);
END;
$$;

GRANT EXECUTE ON FUNCTION church.check_out_children(
  UUID[], TEXT, TEXT, UUID, TEXT, TEXT, TEXT, UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- The desk must not offer someone the database is about to refuse
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.station_pickup_candidates(
  _check_in_id UUID, _shift_token TEXT DEFAULT NULL)
RETURNS TABLE (
  person_id UUID,
  display_name TEXT,
  relationship TEXT,
  is_authorized BOOLEAN,
  is_guardian BOOLEAN,
  child_has_restriction BOOLEAN
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  a church.resolved_actor;
  ci church.kids_check_ins%ROWTYPE;
BEGIN
  a := church.resolve_actor(_shift_token);
  IF NOT a.can_check_out THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO ci FROM church.kids_check_ins k
   WHERE k.id = _check_in_id
     AND k.organization_id = a.organization_id
     AND k.status = 'checked_in';

  IF NOT FOUND THEN
    INSERT INTO church.check_in_audit
      (organization_id, action, outcome, check_in_id, station_id, volunteer_id,
       actor_auth_user_id, actor_name, detail)
    VALUES (a.organization_id, 'sensitive_viewed', 'denied', _check_in_id,
            a.station_id, a.volunteer_id, auth.uid(), a.actor_name,
            jsonb_build_object('action', 'pickup_candidates'));
    RETURN;
  END IF;

  INSERT INTO church.check_in_audit
    (organization_id, action, outcome, check_in_id, batch_id, kids_session_id,
     child_person_id, station_id, volunteer_id, actor_auth_user_id, actor_name,
     detail)
  VALUES (a.organization_id, 'sensitive_viewed', 'success', ci.id, ci.batch_id,
          ci.kids_session_id, ci.child_person_id, a.station_id, a.volunteer_id,
          auth.uid(), a.actor_name,
          jsonb_build_object('action', 'pickup_candidates'));

  RETURN QUERY
  WITH candidates AS (
    SELECT p.id,
           coalesce(p.preferred_name, p.first_name) || ' ' || p.last_name AS nm,
           coalesce(rt.display_name, 'Household member') AS rel,
           false AS explicit,
           coalesce(rt.implies_guardianship, false) AS guardian
    FROM church.household_members hm_child
    JOIN church.household_members hm_adult
      ON hm_adult.household_id = hm_child.household_id
     AND hm_adult.end_date IS NULL
    JOIN church.people p
      ON p.id = hm_adult.person_id AND NOT p.is_child AND p.is_active
    LEFT JOIN church.person_relationships rel
      ON rel.person_id = p.id
     AND rel.related_person_id = ci.child_person_id
     AND rel.end_date IS NULL
    LEFT JOIN church.relationship_types rt ON rt.id = rel.relationship_type_id
    WHERE hm_child.person_id = ci.child_person_id
      AND hm_child.end_date IS NULL

    UNION ALL

    -- Recorded guardians, who may have no household row at all — the state
    -- every CSV-imported family is in.
    SELECT p.id,
           coalesce(p.preferred_name, p.first_name) || ' ' || p.last_name,
           rt.display_name,
           false,
           true
    FROM church.person_relationships rel
    JOIN church.relationship_types rt
      ON rt.id = rel.relationship_type_id AND rt.implies_guardianship
    JOIN church.people p
      ON p.id = rel.person_id AND p.is_active AND NOT p.is_child
    WHERE rel.related_person_id = ci.child_person_id
      AND rel.end_date IS NULL

    UNION ALL

    SELECT p.id,
           coalesce(p.preferred_name, p.first_name) || ' ' || p.last_name,
           coalesce(pa.relationship_note, 'Authorised for pickup'),
           true,
           false
    FROM church.kids_pickup_authorizations pa
    JOIN church.people p ON p.id = pa.authorized_person_id AND p.is_active
    WHERE pa.child_person_id = ci.child_person_id
      AND pa.effective_from <= CURRENT_DATE
      AND (pa.effective_to IS NULL OR pa.effective_to >= CURRENT_DATE)
  )
  SELECT c.id,
         c.nm,
         (array_agg(c.rel ORDER BY c.explicit DESC, c.guardian DESC))[1],
         bool_or(c.explicit),
         bool_or(c.guardian),
         church.child_has_active_restriction(ci.child_person_id)
  FROM candidates c
  -- Offered only if checkout would actually accept them. Passing the NAME as
  -- well is what keeps a name-only order from putting the restricted person on
  -- the screen as a tappable button.
  WHERE church.is_approved_collector(ci.child_person_id, c.id, c.nm)
  GROUP BY c.id, c.nm
  ORDER BY bool_or(c.explicit) DESC, bool_or(c.guardian) DESC, c.nm;
END;
$$;

GRANT EXECUTE ON FUNCTION church.station_pickup_candidates(UUID, TEXT)
  TO authenticated;

-- The pickup screen's warning read a snapshot frozen at check-in, so an order
-- filed mid-service left the banner dark while enforcement (correctly) refused.
-- A volunteer seeing no warning and an unexplained refusal learns to distrust
-- the refusal.
CREATE OR REPLACE FUNCTION church.resolve_pickup(_kids_session_id uuid, _presented text, _shift_token text DEFAULT NULL::text)
 RETURNS TABLE(batch_id uuid, check_in_id uuid, child_person_id uuid, child_name text, room_name text, tag_number integer, status text, has_restriction boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'church', 'public', 'extensions'
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
         ci.label_room_name, ci.tag_number, ci.status,
         -- Live, not the snapshot frozen at check-in: an order filed during
         -- the service must light the desk's warning, or the volunteer sees
         -- an unexplained refusal and learns to distrust refusals.
         church.child_has_active_restriction(ci.child_person_id)
  FROM church.kids_check_ins ci
  WHERE ci.batch_id = sec.batch_id
  ORDER BY ci.tag_number;
END;
$$;

GRANT EXECUTE ON FUNCTION church.resolve_pickup(UUID, TEXT, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- The break-glass release must appear in the Monday review.
CREATE OR REPLACE FUNCTION church.kids_exceptions_report(
  _organization_id UUID, _from DATE, _to DATE)
RETURNS TABLE (
  occurred_at TIMESTAMPTZ, session_date DATE, action TEXT, outcome TEXT,
  child_name TEXT, room_name TEXT, actor_name TEXT, reason TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
BEGIN
  PERFORM church.assert_kids_leader(_organization_id);
  IF _from IS NULL OR _to IS NULL OR _to < _from THEN
    RAISE EXCEPTION 'invalid_date_range';
  END IF;

  RETURN QUERY
  SELECT
    au.created_at,
    s.session_date,
    CASE WHEN au.action = 'check_in'
              AND (au.detail->>'capacity_overridden')::BOOLEAN IS TRUE
         THEN 'capacity_override' ELSE au.action END,
    au.outcome,
    coalesce(p.first_name || ' ' || p.last_name, '(unknown child)'),
    r.name,
    au.actor_name,
    coalesce(au.detail->>'override_reason', au.detail->>'reason',
             c.assignment_reason,
             CASE au.action
               WHEN 'restricted_pickup_attempt'
                 THEN 'Blocked: person is on the restricted list'
               WHEN 'code_failed' THEN 'Pickup code did not match'
               ELSE NULL END)
  FROM church.check_in_audit au
  LEFT JOIN church.kids_sessions s ON s.id = au.kids_session_id
  LEFT JOIN church.people p ON p.id = au.child_person_id
  LEFT JOIN church.kids_check_ins c ON c.id = au.check_in_id
  LEFT JOIN public.rooms r ON r.id = c.room_id
  WHERE au.organization_id = _organization_id
    AND au.created_at::DATE BETWEEN _from AND _to
    AND (au.action IN ('override', 'restricted_pickup_attempt',
                       'restricted_pickup_override', 'code_failed',
                       'pin_failed', 'transfer')
         OR au.outcome = 'denied'
         OR (au.action = 'check_in'
             AND (au.detail->>'capacity_overridden')::BOOLEAN IS TRUE)
         OR (au.action = 'check_in' AND c.assignment_reason IS NOT NULL))
  ORDER BY au.created_at DESC
  LIMIT 500;
END;
$$;

GRANT EXECUTE ON FUNCTION church.kids_exceptions_report(UUID, DATE, DATE)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
