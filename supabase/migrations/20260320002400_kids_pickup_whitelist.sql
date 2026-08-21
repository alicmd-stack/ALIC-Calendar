-- =====================================================
-- Pickup: approve, don't merely un-blacklist
-- =====================================================
--
-- 20260320002300 tried to enforce restricted pickup by asking two questions:
-- was a collector supplied, and is that collector on the restricted list.
-- Adversarial testing released a court-ordered child four different ways, so
-- both questions were the wrong shape:
--
-- C1. "Was a collector supplied" accepted ANY non-null uuid. A value with no
--     row in church.people at all released the child and was written into
--     picked_up_by_person_id, which had no foreign key. The override path
--     applied no identity check whatsoever.
--
-- C2. The guard read kids_check_ins.has_pickup_restriction — a boolean frozen
--     at check-in time. A protective order filed DURING a service was invisible
--     to it, so the child was releasable anonymously. The second gate read the
--     live table, so the two disagreed precisely when it mattered.
--
-- C3. The pickup code was matched against _check_in_ids[1], then every id in
--     the array was released. One family's code released another family's
--     child, across batches and across sessions.
--
-- The rule is now stated once, positively: a child with a live restriction
-- leaves only with someone on their approved list. Everything else is denied.

-- ---------------------------------------------------------------------------
-- One definition of "restricted", read live
-- ---------------------------------------------------------------------------
--
-- The rule was previously spelled out in six places and only two of them read
-- the live table. It exists once now so it cannot drift again.
CREATE OR REPLACE FUNCTION church.child_has_active_restriction(_child_person_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = church, public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM church.kids_pickup_restrictions pr
    WHERE pr.child_person_id = _child_person_id
      AND pr.effective_from <= CURRENT_DATE
      AND (pr.effective_to IS NULL OR pr.effective_to >= CURRENT_DATE)
  );
$$;

GRANT EXECUTE ON FUNCTION church.child_has_active_restriction(UUID) TO authenticated;

COMMENT ON COLUMN church.kids_check_ins.has_pickup_restriction IS
  'Whether a restriction existed WHEN THIS CHILD WAS CHECKED IN. A historical '
  'artifact for the audit trail — never an authorization input, because an '
  'order filed mid-service does not update it. Enforcement must call '
  'church.child_has_active_restriction(), which reads the live table.';

-- ---------------------------------------------------------------------------
-- The approved list, stated positively
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.is_approved_collector(
  _child_person_id UUID, _person_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = church, public
AS $$
  SELECT _person_id IS NOT NULL
     AND NOT EXISTS (
       -- Restriction always wins, on every path, with no override.
       SELECT 1 FROM church.kids_pickup_restrictions pr
       WHERE pr.child_person_id = _child_person_id
         AND pr.restricted_person_id = _person_id
         AND pr.effective_from <= CURRENT_DATE
         AND (pr.effective_to IS NULL OR pr.effective_to >= CURRENT_DATE))
     AND (
       -- An adult of the child's own household...
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
       -- ...or someone explicitly authorised for this child.
       OR EXISTS (
         SELECT 1 FROM church.kids_pickup_authorizations pa
         WHERE pa.child_person_id = _child_person_id
           AND pa.authorized_person_id = _person_id
           AND pa.effective_from <= CURRENT_DATE
           AND (pa.effective_to IS NULL OR pa.effective_to >= CURRENT_DATE))
     );
$$;

GRANT EXECUTE ON FUNCTION church.is_approved_collector(UUID, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- A recorded collector must be a real person
-- ---------------------------------------------------------------------------
--
-- Without this, 'deadbeef-...' was accepted and stored, so the audit trail
-- could not say who was named at the desk. Junk written during testing is
-- cleared first; production has no check-in rows at all.
UPDATE church.kids_check_ins k
   SET picked_up_by_person_id = NULL
 WHERE k.picked_up_by_person_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM church.people p WHERE p.id = k.picked_up_by_person_id);

ALTER TABLE church.kids_check_ins
  DROP CONSTRAINT IF EXISTS fk_kids_check_ins_picked_up_by;

ALTER TABLE church.kids_check_ins
  ADD CONSTRAINT fk_kids_check_ins_picked_up_by
  FOREIGN KEY (picked_up_by_person_id)
  REFERENCES church.people(id) ON DELETE SET NULL;

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
  _method TEXT;
  _authorizer UUID;
  _authorizer_name TEXT;
  _auth_hash TEXT;
  _id UUID;
BEGIN
  a := church.resolve_actor(_shift_token);
  IF NOT a.can_check_out THEN
    RAISE EXCEPTION 'not_permitted_to_check_out' USING ERRCODE = '42501';
  END IF;

  IF _check_in_ids IS NULL OR array_length(_check_in_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'no_check_ins_supplied';
  END IF;

  -- Duplicates in the array would break the coherence count below and are
  -- meaningless anyway.
  SELECT array_agg(DISTINCT x) INTO _ids FROM unnest(_check_in_ids) AS x;

  SELECT * INTO ci FROM church.kids_check_ins k
   WHERE k.id = _ids[1] AND k.organization_id = a.organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'check_in_not_found'; END IF;

  -- C3: the presented code is matched against ONE check-in, so every id in the
  -- array must belong to that same batch and session. Without this, appending
  -- another family's check_in_id released their child on this family's code.
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

  -- C1: a named collector must be a real, active person in this branch.
  IF _picked_up_by_person_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM church.people p
                     WHERE p.id = _picked_up_by_person_id
                       AND p.organization_id = a.organization_id
                       AND p.is_active) THEN
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

  -- C1 + C2, the core rule. Every child in the batch is checked against the
  -- LIVE restriction table, and a restricted child leaves only with someone on
  -- their approved list. This runs BEFORE the code/override branch, so an
  -- admin override cannot skip it — a restriction has no override by design.
  IF EXISTS (
       SELECT 1 FROM church.kids_check_ins k
       WHERE k.id = ANY(_ids)
         AND church.child_has_active_restriction(k.child_person_id)
         AND NOT church.is_approved_collector(k.child_person_id,
                                              _picked_up_by_person_id))
  THEN
    -- One row per protected child, not one row about whichever child happened
    -- to sort first: the previous version filed the denial against an
    -- unrestricted sibling and left the protected child's history clean.
    INSERT INTO church.check_in_audit
      (organization_id, action, outcome, check_in_id, batch_id, kids_session_id,
       child_person_id, station_id, volunteer_id, actor_auth_user_id,
       actor_name, detail)
    SELECT a.organization_id, 'restricted_pickup_attempt', 'denied', k.id,
           k.batch_id, k.kids_session_id, k.child_person_id, a.station_id,
           a.volunteer_id, auth.uid(), a.actor_name,
           jsonb_build_object(
             'reason', CASE WHEN _picked_up_by_person_id IS NULL
                            THEN 'collector not identified'
                            ELSE 'collector is not on the approved list' END,
             'attempted_person_id', _picked_up_by_person_id,
             'attempted_name', _picked_up_by_name)
    FROM church.kids_check_ins k
    WHERE k.id = ANY(_ids)
      AND church.child_has_active_restriction(k.child_person_id)
      AND NOT church.is_approved_collector(k.child_person_id,
                                           _picked_up_by_person_id);
    RETURN;
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

  FOREACH _id IN ARRAY _ids LOOP
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

  RETURN QUERY
  SELECT c.id, c.label_child_name, c.checked_out_at
  FROM church.kids_check_ins c
  WHERE c.id = ANY(_ids) AND c.status = 'checked_out';
END;
$$;

GRANT EXECUTE ON FUNCTION church.check_out_children(
  UUID[], TEXT, TEXT, UUID, TEXT, TEXT, TEXT, UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- H1: a barred volunteer must not keep the desk
-- ---------------------------------------------------------------------------
--
-- The signed-in branch resolved a volunteer row with no predicate and then set
-- can_check_in/can_check_out unconditionally, so a volunteer marked
-- `restricted` and `is_active = false` could still check children in and out
-- and read medical data. The shift-token branch enforced KID-024 correctly,
-- but nothing calls it any more.
CREATE OR REPLACE FUNCTION church.resolve_actor(_shift_token TEXT DEFAULT NULL)
RETURNS church.resolved_actor
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  a church.resolved_actor;
  st church.kids_shift_tokens%ROWTYPE;
  v  church.kids_volunteers%ROWTYPE;
  p  church.people%ROWTYPE;
  _admin_orgs UUID[];
  _volunteer_orgs UUID[];
BEGIN
  -- Shift-token path retained so the shared-device model still works if ALIC
  -- turns it back on. Unused by the current UI.
  IF _shift_token IS NOT NULL AND length(_shift_token) > 0 THEN
    SELECT * INTO st FROM church.kids_shift_tokens
    WHERE token_hash = digest(_shift_token, 'sha256')
      AND ended_at IS NULL AND expires_at > now();
    IF NOT FOUND THEN
      RAISE EXCEPTION 'invalid_or_expired_shift' USING ERRCODE = '28000';
    END IF;
    IF st.issued_to_auth_user IS NOT NULL
       AND st.issued_to_auth_user IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'invalid_or_expired_shift' USING ERRCODE = '28000';
    END IF;

    SELECT * INTO v FROM church.kids_volunteers WHERE id = st.volunteer_id;
    IF NOT FOUND OR NOT v.is_active OR v.background_check_status = 'restricted' THEN
      RAISE EXCEPTION 'volunteer_not_eligible' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO p FROM church.people WHERE id = v.person_id;

    a.organization_id := st.organization_id;
    a.person_id       := v.person_id;
    a.volunteer_id    := v.id;
    a.station_id      := st.station_id;
    a.actor_name      := coalesce(p.preferred_name, p.first_name) || ' ' || p.last_name;
    a.source          := 'station';
    a.can_check_in    := true;
    a.can_check_out   := true;
    a.can_override    := v.can_override;
    RETURN a;
  END IF;

  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT array_agg(o) INTO _admin_orgs
  FROM church.my_orgs_with_any(ARRAY['kids_admin']::church.module_permission[]) AS o;

  SELECT array_agg(o) INTO _volunteer_orgs
  FROM church.my_orgs_with_any(
    ARRAY['kids_admin','kids_volunteer']::church.module_permission[]) AS o;

  IF _volunteer_orgs IS NULL OR array_length(_volunteer_orgs, 1) IS NULL THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  a.organization_id := _volunteer_orgs[1];
  -- Attribution comes from the signed-in user's own member record.
  a.person_id := (SELECT id FROM church.people
                   WHERE profile_id = auth.uid()
                     AND organization_id = a.organization_id LIMIT 1);

  -- KID-024, previously enforced only on the shift-token path. The signed-in
  -- branch resolved a volunteer row with no predicate and then granted every
  -- capability, so a volunteer marked `restricted` and de-activated could
  -- still check children in and out and open safety cards. Scoped to the
  -- organization too: the old lookup matched on person_id alone.
  SELECT * INTO v FROM church.kids_volunteers vv
   WHERE vv.person_id = a.person_id
     AND vv.organization_id = a.organization_id
   LIMIT 1;

  IF FOUND AND (NOT v.is_active OR v.background_check_status = 'restricted') THEN
    RAISE EXCEPTION 'volunteer_not_eligible' USING ERRCODE = '42501';
  END IF;

  -- No volunteer row at all is fine: that is an admin acting directly, which
  -- is how the ministry lead works. A row that says "barred" is not.
  a.volunteer_id := v.id;

  a.station_id := NULL;
  a.actor_name := coalesce(
    (SELECT full_name FROM public.profiles WHERE id = auth.uid()), 'Volunteer');
  a.source := 'user';
  a.can_check_in  := true;
  a.can_check_out := true;
  -- Only a kids_admin may authorise a checkout override. An ordinary
  -- volunteer still cannot do it alone.
  a.can_override := (_admin_orgs IS NOT NULL AND array_length(_admin_orgs, 1) > 0);
  RETURN a;
END;
$$;

GRANT EXECUTE ON FUNCTION church.resolve_actor(TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- One login maps to at most one member record per branch
-- ---------------------------------------------------------------------------
--
-- church.people.profile_id had only a plain index. With several rows sharing a
-- profile_id, `WHERE profile_id = auth.uid() ... LIMIT 1` returns an arbitrary
-- one, which:
--   - makes check-in attribution non-deterministic,
--   - lets a volunteer barred on one member record act through another, and
--   - would let my_person_ids() expose a stranger's record to a self-service
--     user.
--
-- Scoped per organization rather than globally, because the same person
-- legitimately has one member record per branch they belong to.
--
-- Existing duplicates are UNLINKED, never deleted: the member records are real
-- data, only the login mapping is ambiguous. The oldest row keeps the link and
-- an admin can re-link the rest deliberately.
UPDATE church.people p
   SET profile_id = NULL
 WHERE p.profile_id IS NOT NULL
   AND EXISTS (
     SELECT 1 FROM church.people q
     WHERE q.profile_id = p.profile_id
       AND q.organization_id = p.organization_id
       AND (q.created_at, q.id) < (p.created_at, p.id));

CREATE UNIQUE INDEX IF NOT EXISTS uq_people_profile_per_org
  ON church.people (profile_id, organization_id)
  WHERE profile_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- M6: the candidate list is not a people directory
-- ---------------------------------------------------------------------------
--
-- It answered for closed check-ins, so enumerating ids returned guardians'
-- full legal names and a live custody flag for unrelated households. The
-- safety card, which discloses less identity, is both status-bounded and
-- audited; this now matches.
DROP FUNCTION IF EXISTS church.station_pickup_candidates(UUID, TEXT);

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
    -- The type names person_id's role, so read from the ADULT's side.
    LEFT JOIN church.person_relationships rel
      ON rel.person_id = p.id
     AND rel.related_person_id = ci.child_person_id
     AND rel.end_date IS NULL
    LEFT JOIN church.relationship_types rt ON rt.id = rel.relationship_type_id
    WHERE hm_child.person_id = ci.child_person_id
      AND hm_child.end_date IS NULL

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
  -- Offered only if they would actually be accepted, so the desk cannot
  -- present someone the database is about to refuse.
  WHERE church.is_approved_collector(ci.child_person_id, c.id)
  GROUP BY c.id, c.nm
  ORDER BY bool_or(c.explicit) DESC, bool_or(c.guardian) DESC, c.nm;
END;
$$;

GRANT EXECUTE ON FUNCTION church.station_pickup_candidates(UUID, TEXT)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
