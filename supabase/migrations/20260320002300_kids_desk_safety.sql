-- =====================================================
-- Desk safety: the controls that were built but inert
-- =====================================================
--
-- Three defects found by auditing the plan against the code:
--
-- 1. RESTRICTED PICKUP WAS NEVER ENFORCED IN PRACTICE. check_out_children
--    checks the restricted list only when the caller names who is collecting,
--    and the station never named anyone — it wrote 'unrecorded'. So the
--    control worked in tests and did nothing on a Sunday.
--
--    The station is fixed separately, but fixing only the station leaves the
--    guarantee resting on the client. A restricted child is now refused
--    server-side unless the collector is identified, so no client — old,
--    cached, or wrong — can release one anonymously.
--
-- 2. station_list_volunteers had no permission check at all.
--
-- 3. Nothing told the desk WHO is allowed to collect a given child, so there
--    was no way for the volunteer to name them even if the UI had asked.

-- ---------------------------------------------------------------------------
-- Who may collect this child
-- ---------------------------------------------------------------------------
--
-- Household adults plus anyone explicitly authorised. Restricted people are
-- omitted: a name absent from this list falls through to the override path,
-- which needs an admin — which is exactly the escalation wanted. Putting
-- "DO NOT RELEASE" next to a name on a screen facing a queue of parents would
-- announce a custody dispute to the room.
-- Dropped rather than replaced: CREATE OR REPLACE cannot change a function's
-- RETURNS TABLE shape. A no-op on any database that has not seen this yet.
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
LANGUAGE plpgsql STABLE SECURITY DEFINER
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
   WHERE k.id = _check_in_id AND k.organization_id = a.organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'check_in_not_found'; END IF;

  RETURN QUERY
  WITH restricted AS (
    SELECT pr.restricted_person_id AS pid
    FROM church.kids_pickup_restrictions pr
    WHERE pr.child_person_id = ci.child_person_id
      AND pr.effective_from <= CURRENT_DATE
      AND (pr.effective_to IS NULL OR pr.effective_to >= CURRENT_DATE)
  ),
  candidates AS (
    -- Adults sharing the child's household.
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
    -- Read from the ADULT's side: the type names person_id's role, so
    -- (person_id = adult, related_person_id = child) is "Parent", while the
    -- mirrored row is "Child" and would label every guardian "Child".
    LEFT JOIN church.person_relationships rel
      ON rel.person_id = p.id
     AND rel.related_person_id = ci.child_person_id
     AND rel.end_date IS NULL
    LEFT JOIN church.relationship_types rt ON rt.id = rel.relationship_type_id
    WHERE hm_child.person_id = ci.child_person_id
      AND hm_child.end_date IS NULL

    UNION ALL

    -- Anyone explicitly authorised, who may live elsewhere entirely.
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
  -- Grouped by person only: someone can be BOTH a household member and
  -- explicitly authorised, and must appear once, not twice. The strongest
  -- description wins, which is why max() is taken over the flags.
  SELECT c.id,
         c.nm,
         (array_agg(c.rel ORDER BY c.explicit DESC, c.guardian DESC))[1],
         bool_or(c.explicit),
         bool_or(c.guardian),
         EXISTS (SELECT 1 FROM restricted)
  FROM candidates c
  WHERE NOT EXISTS (SELECT 1 FROM restricted r WHERE r.pid = c.id)
  GROUP BY c.id, c.nm
  ORDER BY bool_or(c.explicit) DESC, bool_or(c.guardian) DESC, c.nm;
END;
$$;

GRANT EXECUTE ON FUNCTION church.station_pickup_candidates(UUID, TEXT)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- station_list_volunteers: add the missing permission check
-- ---------------------------------------------------------------------------
--
-- Was SECURITY DEFINER, granted to `authenticated`, and validated only that
-- the station id existed — so any signed-in user holding a station UUID could
-- read volunteer names and background-check status for that station's
-- organization, including a branch they have no membership in. The RLS policy
-- on kids_volunteers restricts exactly that data to kids_admin and
-- leadership_viewer; this function walked around it.
CREATE OR REPLACE FUNCTION church.station_list_volunteers(_station_id UUID)
RETURNS TABLE (volunteer_id UUID, display_name TEXT, is_eligible BOOLEAN,
               background_check_status TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE s church.check_in_stations%ROWTYPE;
BEGIN
  SELECT * INTO s FROM church.check_in_stations WHERE id = _station_id AND is_active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'station_not_found';
  END IF;

  -- The caller must belong to the station's own organization AND hold a kids
  -- permission there. Knowing a station UUID is not authorization.
  IF NOT church.has_permission_in_org(
       s.organization_id,
       ARRAY['kids_admin','kids_volunteer']::church.module_permission[]) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT v.id,
         coalesce(p.preferred_name, p.first_name) || ' ' || left(p.last_name, 1) || '.',
         (v.background_check_status = 'clear'
          AND (v.background_check_expires_on IS NULL
               OR v.background_check_expires_on > CURRENT_DATE)),
         v.background_check_status
  FROM church.kids_volunteers v
  JOIN church.people p ON p.id = v.person_id
  WHERE v.organization_id = s.organization_id
    AND v.is_active
    AND v.background_check_status <> 'restricted'
  ORDER BY p.first_name;
END;
$$;

-- ---------------------------------------------------------------------------
-- Checkout: a restricted child is never released anonymously
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
  _authorizer_name TEXT;
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

  SELECT * INTO ci FROM church.kids_check_ins k
   WHERE k.id = _check_in_ids[1] AND k.organization_id = a.organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'check_in_not_found'; END IF;

  -- KID-014, defence in depth. A child with a restriction on file may not
  -- leave without the collector being named, on ANY path including a valid
  -- code and including an override. Previously this check ran only when the
  -- caller volunteered a person id, so a client that named nobody — which is
  -- what the station actually did — skipped it entirely.
  IF _picked_up_by_person_id IS NULL
     AND EXISTS (SELECT 1 FROM church.kids_check_ins k
                 WHERE k.id = ANY(_check_in_ids)
                   AND k.organization_id = a.organization_id
                   AND k.has_pickup_restriction) THEN
    INSERT INTO church.check_in_audit
      (organization_id, action, outcome, check_in_id, child_person_id,
       station_id, volunteer_id, actor_auth_user_id, actor_name, detail)
    VALUES (a.organization_id, 'restricted_pickup_attempt', 'denied', ci.id,
            ci.child_person_id, a.station_id, a.volunteer_id, auth.uid(),
            a.actor_name,
            jsonb_build_object('reason', 'collector not identified'));
    RETURN;   -- zero rows: one generic denial, as every other failure path
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
        (organization_id, action, outcome, check_in_id, child_person_id,
         station_id, volunteer_id, actor_auth_user_id, actor_name)
      VALUES (a.organization_id, 'code_failed', 'denied', ci.id, ci.child_person_id,
              a.station_id, a.volunteer_id, auth.uid(), a.actor_name);
      RETURN;
    END IF;
    _method := 'security_code';
  END IF;

  -- A restricted person is never released to, on any path. There is
  -- deliberately no override that permits it.
  IF _picked_up_by_person_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM church.kids_pickup_restrictions pr
      JOIN church.kids_check_ins k ON k.child_person_id = pr.child_person_id
      WHERE k.id = ANY(_check_in_ids)
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
      RETURN;
    END IF;
  END IF;

  FOREACH _id IN ARRAY _check_in_ids LOOP
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
  WHERE c.id = ANY(_check_in_ids) AND c.status = 'checked_out';
END;
$$;

GRANT EXECUTE ON FUNCTION church.check_out_children(
  UUID[], TEXT, TEXT, UUID, TEXT, TEXT, TEXT, UUID, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
