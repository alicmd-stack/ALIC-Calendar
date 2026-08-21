-- =====================================================
-- Adding a child to a family that already exists
-- =====================================================
--
-- register_member_family does a great deal per child: creates the person,
-- puts them in the household, writes a parent relationship from each adult,
-- authorises both parents to collect them, and records any allergy. All of
-- that happens exactly once, when the family is first entered.
--
-- After that there is no way to add a child at all. A family who register and
-- then have a baby, or whose second child was missed on the day, can only be
-- fixed with SQL. householdService.addMember() attaches an EXISTING person to
-- a household — it cannot create one, and even if it could, a child added that
-- way would have no parent relationship and no pickup authorisation, so
-- station_pickup_candidates would offer nobody and their own mother could not
-- collect them.
--
-- This does what registration does for one child, against a family that is
-- already on file.

CREATE OR REPLACE FUNCTION church.add_child_to_household(
  _household_id UUID,
  _child JSONB
)
RETURNS UUID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _org UUID;
  _actor TEXT;
  _child_id UUID;
  _parent_type UUID;
  _adult RECORD;
  _surname TEXT;
BEGIN
  SELECT h.organization_id INTO _org
  FROM church.households h WHERE h.id = _household_id;
  IF _org IS NULL THEN RAISE EXCEPTION 'household_not_found'; END IF;

  IF NOT church.has_permission_in_org(
       _org, ARRAY['members_admin']::church.module_permission[]) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  IF coalesce(btrim(_child->>'first_name'), '') = '' THEN
    RAISE EXCEPTION 'first_name_required';
  END IF;

  -- Enforced here as well as in the form, because a child without one cannot
  -- be placed in a classroom.
  IF NULLIF(btrim(coalesce(_child->>'birth_year', '')), '') IS NULL THEN
    RAISE EXCEPTION 'child_requires_birth_year';
  END IF;

  _actor := coalesce(
    (SELECT full_name FROM public.profiles WHERE id = auth.uid()), 'Administrator');

  SELECT id INTO _parent_type FROM church.relationship_types
   WHERE organization_id = _org AND code = 'parent';

  -- Inherit the family surname, which is what the person adding them expects.
  -- Taken from an adult of this household rather than from the household name,
  -- which is often "The Smiths" or similar.
  SELECT p.last_name INTO _surname
  FROM church.household_members hm
  JOIN church.people p ON p.id = hm.person_id
  WHERE hm.household_id = _household_id AND hm.end_date IS NULL
    AND NOT p.is_child
  ORDER BY hm.is_primary_contact DESC
  LIMIT 1;

  _child_id := church.insert_person_from_json(
    _org,
    _child || jsonb_build_object(
      'last_name',
      coalesce(NULLIF(btrim(coalesce(_child->>'last_name', '')), ''),
               _surname, 'Unknown')),
    true, _actor);

  PERFORM church.set_child_sensitive_from_json(_child_id, _org, _child, _actor);

  INSERT INTO church.household_members
    (organization_id, household_id, person_id, household_role, is_primary_household)
  VALUES (_org, _household_id, _child_id, 'child', true);

  -- Every current adult of the family becomes a parent and an authorised
  -- collector. Without both, the check-in desk would offer nobody for this
  -- child and their own mother could not take them home.
  FOR _adult IN
    SELECT p.id
    FROM church.household_members hm
    JOIN church.people p ON p.id = hm.person_id
    WHERE hm.household_id = _household_id
      AND hm.end_date IS NULL
      AND NOT p.is_child
      AND p.is_active
  LOOP
    -- One direction only: a trigger mirrors the inverse, and writing both
    -- collides on the uniqueness constraint.
    INSERT INTO church.person_relationships
      (organization_id, person_id, related_person_id, relationship_type_id)
    VALUES (_org, _adult.id, _child_id, _parent_type)
    ON CONFLICT (person_id, related_person_id, relationship_type_id) DO NOTHING;

    INSERT INTO church.kids_pickup_authorizations
      (organization_id, child_person_id, authorized_person_id,
       relationship_note, created_by, created_by_name)
    VALUES (_org, _child_id, _adult.id, 'Parent', auth.uid(), _actor)
    ON CONFLICT (child_person_id, authorized_person_id) DO NOTHING;
  END LOOP;

  RETURN _child_id;
END;
$$;

GRANT EXECUTE ON FUNCTION church.add_child_to_household(UUID, JSONB) TO authenticated;

COMMENT ON FUNCTION church.add_child_to_household(UUID, JSONB) IS
  'Adds a NEW child to an existing family, doing everything registration does '
  'per child: person, household membership, a parent relationship from each '
  'adult, pickup authorisation for each, and any allergy record.';

-- ---------------------------------------------------------------------------
-- Families, with enough to be useful in a list
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.household_summaries(_organization_id UUID)
RETURNS TABLE (
  household_id UUID,
  name TEXT,
  city TEXT,
  primary_contact_name TEXT,
  primary_phone TEXT,
  adult_count BIGINT,
  child_count BIGINT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
BEGIN
  IF NOT church.has_permission_in_org(
       _organization_id,
       ARRAY['members_admin','members_viewer','leadership_viewer']::church.module_permission[])
     AND _organization_id NOT IN (SELECT church.my_admin_orgs()) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    h.id,
    h.name,
    h.city,
    pc.nm,
    coalesce(h.primary_phone, pc.phone),
    coalesce(counts.adults, 0),
    coalesce(counts.children, 0)
  FROM church.households h
  LEFT JOIN LATERAL (
    SELECT coalesce(p.preferred_name, p.first_name) || ' ' || p.last_name AS nm,
           p.phone
    FROM church.household_members hm
    JOIN church.people p ON p.id = hm.person_id
    WHERE hm.household_id = h.id AND hm.end_date IS NULL AND NOT p.is_child
    ORDER BY hm.is_primary_contact DESC, p.first_name
    LIMIT 1
  ) pc ON true
  LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE NOT p.is_child) AS adults,
           count(*) FILTER (WHERE p.is_child) AS children
    FROM church.household_members hm
    JOIN church.people p ON p.id = hm.person_id
    WHERE hm.household_id = h.id AND hm.end_date IS NULL
  ) counts ON true
  WHERE h.organization_id = _organization_id
    AND h.is_active
  ORDER BY h.name;
END;
$$;

GRANT EXECUTE ON FUNCTION church.household_summaries(UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';
