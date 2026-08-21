-- =====================================================
-- Recording who may and may not collect a child
-- =====================================================
--
-- kids_pickup_restrictions and kids_pickup_authorizations are the two tables
-- the entire checkout gate is built on, and neither has ever had a screen.
-- `grep -rn kids_pickup_restrictions src` matches only the generated types.
--
-- So a protective order can be recorded only by typing into Supabase Studio —
-- and Studio does not require restricted_person_id, which is precisely how
-- name-only orders became the norm and how a court-restricted child was
-- released to the man named in the order. The fix for that (20260320002800)
-- treats a name-only order as strictly stronger than an id-based one, because
-- it cannot tell who is who; the real remedy is to make it easy to record the
-- id in the first place.
--
-- Both are kept per child, because that is how custody works: an order names a
-- person for a child, not for a family.

-- ---------------------------------------------------------------------------
-- Reading both lists for one child
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.child_pickup_permissions(_child_person_id UUID)
RETURNS TABLE (
  id UUID,
  kind TEXT,                  -- 'authorized' | 'restricted'
  person_id UUID,
  display_name TEXT,
  phone TEXT,
  note TEXT,
  effective_from DATE,
  is_name_only BOOLEAN,
  created_by_name TEXT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _org UUID;
BEGIN
  SELECT p.organization_id INTO _org
  FROM church.people p WHERE p.id = _child_person_id;
  IF _org IS NULL THEN RAISE EXCEPTION 'person_not_found'; END IF;

  IF NOT church.has_permission_in_org(
       _org, ARRAY['members_admin','kids_admin']::church.module_permission[]) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT pa.id, 'authorized', p.id,
         coalesce(p.preferred_name, p.first_name) || ' ' || p.last_name,
         p.phone,
         pa.relationship_note,
         pa.effective_from,
         false,
         pa.created_by_name
  FROM church.kids_pickup_authorizations pa
  JOIN church.people p ON p.id = pa.authorized_person_id
  WHERE pa.child_person_id = _child_person_id
    AND (pa.effective_to IS NULL OR pa.effective_to >= CURRENT_DATE)
    -- An order beats an authorisation, so somebody under one must never be
    -- LISTED as able to collect. Superseding sets effective_to to today, which
    -- still reads as current for the rest of the day — and a screen showing
    -- the same person as both authorised and restricted is worse than useless
    -- to whoever has to make the call at the door.
    AND NOT church.restriction_names_person(_child_person_id, p.id, NULL)

  UNION ALL

  SELECT pr.id, 'restricted', pr.restricted_person_id,
         coalesce(
           coalesce(rp.preferred_name, rp.first_name) || ' ' || rp.last_name,
           pr.restricted_person_name,
           '(unnamed)'),
         rp.phone,
         pr.reason_restricted,
         pr.effective_from,
         -- Surfaced so the person entering it can see that an order without a
         -- member record is the weaker kind, and fix it while they are here.
         pr.restricted_person_id IS NULL,
         pr.created_by_name
  FROM church.kids_pickup_restrictions pr
  LEFT JOIN church.people rp ON rp.id = pr.restricted_person_id
  WHERE pr.child_person_id = _child_person_id
    AND (pr.effective_to IS NULL OR pr.effective_to >= CURRENT_DATE)

  ORDER BY 2 DESC, 4;
END;
$$;

GRANT EXECUTE ON FUNCTION church.child_pickup_permissions(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Authorising somebody
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.authorize_pickup(
  _child_person_id UUID, _person_id UUID, _note TEXT DEFAULT NULL)
RETURNS UUID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _org UUID;
  _actor TEXT;
  _id UUID;
BEGIN
  SELECT p.organization_id INTO _org
  FROM church.people p WHERE p.id = _child_person_id;
  IF _org IS NULL THEN RAISE EXCEPTION 'person_not_found'; END IF;

  IF NOT church.has_permission_in_org(
       _org, ARRAY['members_admin','kids_admin']::church.module_permission[]) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM church.people p
                 WHERE p.id = _person_id AND p.organization_id = _org
                   AND NOT p.is_child) THEN
    RAISE EXCEPTION 'person_not_eligible_to_collect';
  END IF;

  -- An order beats an authorisation, always. Allowing both to exist would put
  -- the two halves of the gate in direct contradiction.
  IF church.restriction_names_person(_child_person_id, _person_id, NULL) THEN
    RAISE EXCEPTION 'person_is_restricted_for_this_child' USING ERRCODE = '42501';
  END IF;

  _actor := coalesce(
    (SELECT full_name FROM public.profiles WHERE id = auth.uid()), 'Administrator');

  INSERT INTO church.kids_pickup_authorizations (
    organization_id, child_person_id, authorized_person_id,
    relationship_note, created_by, created_by_name)
  VALUES (_org, _child_person_id, _person_id,
          NULLIF(btrim(coalesce(_note, '')), ''), auth.uid(), _actor)
  ON CONFLICT (child_person_id, authorized_person_id) DO UPDATE SET
    relationship_note = coalesce(EXCLUDED.relationship_note,
                                 kids_pickup_authorizations.relationship_note),
    effective_to = NULL,
    updated_at = now()
  RETURNING id INTO _id;

  RETURN _id;
END;
$$;

GRANT EXECUTE ON FUNCTION church.authorize_pickup(UUID, UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- Recording an order
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.restrict_pickup(
  _child_person_id UUID,
  _person_id UUID DEFAULT NULL,
  _person_name TEXT DEFAULT NULL,
  _reason TEXT DEFAULT NULL)
RETURNS UUID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _org UUID;
  _actor TEXT;
  _id UUID;
  _clean_name TEXT := NULLIF(btrim(coalesce(_person_name, '')), '');
BEGIN
  SELECT p.organization_id INTO _org
  FROM church.people p WHERE p.id = _child_person_id;
  IF _org IS NULL THEN RAISE EXCEPTION 'person_not_found'; END IF;

  -- Deliberately kids_admin or members_admin only. Recording who may not
  -- collect a child is a safeguarding act, not a desk one.
  IF NOT church.has_permission_in_org(
       _org, ARRAY['members_admin','kids_admin']::church.module_permission[]) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  IF _person_id IS NULL AND _clean_name IS NULL THEN
    RAISE EXCEPTION 'name_or_person_required';
  END IF;

  IF _person_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM church.people p
                     WHERE p.id = _person_id AND p.organization_id = _org) THEN
    RAISE EXCEPTION 'person_not_in_this_branch';
  END IF;

  _actor := coalesce(
    (SELECT full_name FROM public.profiles WHERE id = auth.uid()), 'Administrator');

  INSERT INTO church.kids_pickup_restrictions (
    organization_id, child_person_id, restricted_person_id,
    restricted_person_name, reason_restricted, created_by, created_by_name)
  VALUES (_org, _child_person_id, _person_id,
          coalesce(_clean_name,
                   (SELECT coalesce(p.preferred_name, p.first_name) || ' ' || p.last_name
                    FROM church.people p WHERE p.id = _person_id)),
          NULLIF(btrim(coalesce(_reason, '')), ''), auth.uid(), _actor)
  RETURNING id INTO _id;

  -- An order supersedes any standing authorisation for the same person, so the
  -- desk is never offered somebody the gate is about to refuse.
  IF _person_id IS NOT NULL THEN
    UPDATE church.kids_pickup_authorizations
       SET effective_to = CURRENT_DATE, updated_at = now()
     WHERE child_person_id = _child_person_id
       AND authorized_person_id = _person_id
       AND effective_to IS NULL;
  END IF;

  RETURN _id;
END;
$$;

GRANT EXECUTE ON FUNCTION church.restrict_pickup(UUID, UUID, TEXT, TEXT)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Lifting either one
-- ---------------------------------------------------------------------------
--
-- Ended, never deleted. "Was there an order on this child last spring, and who
-- lifted it" is exactly the question asked after something goes wrong.
CREATE OR REPLACE FUNCTION church.end_pickup_permission(_id UUID, _kind TEXT)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _org UUID;
BEGIN
  IF _kind = 'authorized' THEN
    SELECT organization_id INTO _org
    FROM church.kids_pickup_authorizations WHERE id = _id;
  ELSIF _kind = 'restricted' THEN
    SELECT organization_id INTO _org
    FROM church.kids_pickup_restrictions WHERE id = _id;
  ELSE
    RAISE EXCEPTION 'unknown_permission_kind';
  END IF;

  IF _org IS NULL THEN RAISE EXCEPTION 'permission_not_found'; END IF;

  IF NOT church.has_permission_in_org(
       _org, ARRAY['members_admin','kids_admin']::church.module_permission[]) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  IF _kind = 'authorized' THEN
    UPDATE church.kids_pickup_authorizations
       SET effective_to = CURRENT_DATE, updated_at = now()
     WHERE id = _id AND effective_to IS NULL;
  ELSE
    UPDATE church.kids_pickup_restrictions
       SET effective_to = CURRENT_DATE, updated_at = now()
     WHERE id = _id AND effective_to IS NULL;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION church.end_pickup_permission(UUID, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
