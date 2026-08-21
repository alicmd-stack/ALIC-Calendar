-- =====================================================
-- Lifting an order has to take effect now
-- =====================================================
--
-- end_pickup_permission set effective_to = CURRENT_DATE, and every active-check
-- reads `effective_to IS NULL OR effective_to >= CURRENT_DATE` — the date is
-- INCLUSIVE, meaning "in force through this day". So an order lifted this
-- morning stayed in force until midnight.
--
-- For a scheduled expiry that reading is right: an order that runs through the
-- 31st should be enforced on the 31st. For a lift it is wrong in the dangerous
-- direction for the family and the wrong direction for the church: a custody
-- arrangement that changes on Saturday leaves a parent unable to collect their
-- own child on Sunday, with no override at the desk that can help them.
--
-- Setting effective_to = CURRENT_DATE - 1 would collide with
-- chk_kids_pickup_restriction_dates for an order created and lifted the same
-- day, and would also misstate when it ended.
--
-- So the two concepts are separated: effective_to remains the SCHEDULED end,
-- and lifted_at records a deliberate revocation, effective immediately.

ALTER TABLE church.kids_pickup_restrictions
  ADD COLUMN IF NOT EXISTS lifted_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS lifted_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS lifted_by_name TEXT;

ALTER TABLE church.kids_pickup_authorizations
  ADD COLUMN IF NOT EXISTS lifted_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS lifted_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS lifted_by_name TEXT;

COMMENT ON COLUMN church.kids_pickup_restrictions.lifted_at IS
  'When this order was deliberately revoked. Takes effect immediately, unlike '
  'effective_to, which is an inclusive scheduled end date. Never deleted: '
  '"who lifted this, and when" is asked after something goes wrong.';

-- ---------------------------------------------------------------------------
-- One definition of "in force", now honouring a lift
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.child_has_active_restriction(_child_person_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = church, public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM church.kids_pickup_restrictions pr
    WHERE pr.child_person_id = _child_person_id
      AND pr.lifted_at IS NULL
      AND pr.effective_from <= CURRENT_DATE
      AND (pr.effective_to IS NULL OR pr.effective_to >= CURRENT_DATE)
  );
$$;

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
      AND pr.lifted_at IS NULL
      AND pr.effective_from <= CURRENT_DATE
      AND (pr.effective_to IS NULL OR pr.effective_to >= CURRENT_DATE)
      AND (
        (pr.restricted_person_id IS NOT NULL
         AND pr.restricted_person_id = _person_id)
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

-- The name-only clause inside is_approved_collector reads the table directly
-- and must honour a lift too, or a lifted name-only order would keep the whole
-- household switched off forever.
CREATE OR REPLACE FUNCTION church.is_approved_collector(
  _child_person_id UUID, _person_id UUID, _person_name TEXT DEFAULT NULL)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = church, public
AS $$
  SELECT _person_id IS NOT NULL
     AND NOT church.restriction_names_person(
                _child_person_id, _person_id, _person_name)
     AND (
       EXISTS (
         SELECT 1 FROM church.kids_pickup_authorizations pa
         WHERE pa.child_person_id = _child_person_id
           AND pa.authorized_person_id = _person_id
           AND pa.lifted_at IS NULL
           AND pa.effective_from <= CURRENT_DATE
           AND (pa.effective_to IS NULL OR pa.effective_to >= CURRENT_DATE))
       OR (
         NOT EXISTS (
           SELECT 1 FROM church.kids_pickup_restrictions pr
           WHERE pr.child_person_id = _child_person_id
             AND pr.restricted_person_id IS NULL
             AND pr.lifted_at IS NULL
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

REVOKE ALL ON FUNCTION church.child_has_active_restriction(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION church.restriction_names_person(UUID, UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION church.is_approved_collector(UUID, UUID, TEXT) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- Lifting
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.end_pickup_permission(_id UUID, _kind TEXT)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _org UUID;
  _actor TEXT;
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

  _actor := coalesce(
    (SELECT full_name FROM public.profiles WHERE id = auth.uid()), 'Administrator');

  IF _kind = 'authorized' THEN
    UPDATE church.kids_pickup_authorizations
       SET lifted_at = now(), lifted_by = auth.uid(), lifted_by_name = _actor,
           updated_at = now()
     WHERE id = _id AND lifted_at IS NULL;
  ELSE
    UPDATE church.kids_pickup_restrictions
       SET lifted_at = now(), lifted_by = auth.uid(), lifted_by_name = _actor,
           updated_at = now()
     WHERE id = _id AND lifted_at IS NULL;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION church.end_pickup_permission(UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- The reader, and the desk's candidate list
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.child_pickup_permissions(_child_person_id UUID)
RETURNS TABLE (
  id UUID, kind TEXT, person_id UUID, display_name TEXT, phone TEXT,
  note TEXT, effective_from DATE, is_name_only BOOLEAN, created_by_name TEXT)
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
         p.phone, pa.relationship_note, pa.effective_from, false,
         pa.created_by_name
  FROM church.kids_pickup_authorizations pa
  JOIN church.people p ON p.id = pa.authorized_person_id
  WHERE pa.child_person_id = _child_person_id
    AND pa.lifted_at IS NULL
    AND (pa.effective_to IS NULL OR pa.effective_to >= CURRENT_DATE)
    -- Never list somebody the gate is about to refuse.
    AND NOT church.restriction_names_person(_child_person_id, p.id, NULL)

  UNION ALL

  SELECT pr.id, 'restricted', pr.restricted_person_id,
         coalesce(
           coalesce(rp.preferred_name, rp.first_name) || ' ' || rp.last_name,
           pr.restricted_person_name, '(unnamed)'),
         rp.phone, pr.reason_restricted, pr.effective_from,
         pr.restricted_person_id IS NULL,
         pr.created_by_name
  FROM church.kids_pickup_restrictions pr
  LEFT JOIN church.people rp ON rp.id = pr.restricted_person_id
  WHERE pr.child_person_id = _child_person_id
    AND pr.lifted_at IS NULL
    AND (pr.effective_to IS NULL OR pr.effective_to >= CURRENT_DATE)

  ORDER BY 2 DESC, 4;
END;
$$;

GRANT EXECUTE ON FUNCTION church.child_pickup_permissions(UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';
