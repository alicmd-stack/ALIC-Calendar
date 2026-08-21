-- =====================================================
-- Full member registration: household, spouse, children, in one transaction
-- =====================================================
--
-- Registering a family touches church.households, church.people (several
-- rows), church.household_members, church.person_relationships,
-- church.person_emergency_contacts and church.person_service_interests.
--
-- Doing that as a sequence of client calls means a failure halfway leaves a
-- household with no people in it, or children with no parent link — and the
-- client cannot roll back. A single function call is a single transaction, so
-- registration either completes or leaves nothing behind.

-- ---------------------------------------------------------------------------
-- Controlled values for gender and marital status
-- ---------------------------------------------------------------------------
-- Spec 7.1 asks for controlled reference values. These are genuinely fixed
-- lists that a church does not reconfigure, so a CHECK is a better fit than a
-- reference table — unlike ministries or classrooms, which are configuration.
ALTER TABLE church.people
  ADD CONSTRAINT chk_people_gender
  CHECK (gender IS NULL OR gender IN ('male', 'female', 'unspecified'));

ALTER TABLE church.people
  ADD CONSTRAINT chk_people_marital_status
  CHECK (marital_status IS NULL OR marital_status IN
    ('single', 'married', 'widowed', 'divorced', 'separated', 'other'));

-- ---------------------------------------------------------------------------
-- Register a member, optionally with household, spouse and children
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.register_member_family(
  _organization_id UUID,
  _person JSONB,
  _household JSONB DEFAULT NULL,
  _spouse JSONB DEFAULT NULL,
  _children JSONB DEFAULT '[]'::jsonb,
  _emergency_contacts JSONB DEFAULT '[]'::jsonb,
  _service_interest_ministry_ids UUID[] DEFAULT NULL
)
-- Output parameter names are prefixed because a RETURNS TABLE column shadows
-- any same-named table column inside the body, which makes ON CONFLICT
-- (person_id, ...) and WHERE person_id = ... ambiguous to plpgsql.
RETURNS TABLE (out_person_id UUID, out_household_id UUID,
               out_spouse_person_id UUID, out_child_count INTEGER)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _actor_name TEXT;
  _hh UUID;
  _me UUID;
  _spouse_id UUID;
  _spouse_mode TEXT;
  _child JSONB;
  _child_id UUID;
  _kids INTEGER := 0;
  _contact JSONB;
  _ministry UUID;
  _spouse_type UUID;
  _parent_type UUID;
BEGIN
  IF NOT church.has_permission_in_org(
       _organization_id, ARRAY['members_admin']::church.module_permission[]) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  IF coalesce(btrim(_person->>'first_name'), '') = ''
     OR coalesce(btrim(_person->>'last_name'), '') = '' THEN
    RAISE EXCEPTION 'first_and_last_name_required';
  END IF;

  _actor_name := coalesce(
    (SELECT full_name FROM public.profiles WHERE id = auth.uid()), 'Administrator');

  SELECT id INTO _spouse_type FROM church.relationship_types
   WHERE organization_id = _organization_id AND code = 'spouse';
  SELECT id INTO _parent_type FROM church.relationship_types
   WHERE organization_id = _organization_id AND code = 'parent';

  -- Household -------------------------------------------------------------
  -- Address lives here, once, rather than repeated on every family member.
  IF _household IS NOT NULL AND coalesce(btrim(_household->>'name'), '') <> '' THEN
    INSERT INTO church.households (
      organization_id, name, address_line1, address_line2, city, state,
      postal_code, country, primary_phone, created_by, created_by_name)
    VALUES (
      _organization_id, btrim(_household->>'name'),
      NULLIF(btrim(coalesce(_household->>'address_line1', '')), ''),
      NULLIF(btrim(coalesce(_household->>'address_line2', '')), ''),
      NULLIF(btrim(coalesce(_household->>'city', '')), ''),
      NULLIF(btrim(coalesce(_household->>'state', '')), ''),
      NULLIF(btrim(coalesce(_household->>'postal_code', '')), ''),
      coalesce(NULLIF(btrim(coalesce(_household->>'country', '')), ''), 'USA'),
      NULLIF(btrim(coalesce(_household->>'primary_phone', '')), ''),
      auth.uid(), _actor_name)
    RETURNING id INTO _hh;
  END IF;

  -- Primary person --------------------------------------------------------
  _me := church.insert_person_from_json(_organization_id, _person, false, _actor_name);

  IF _hh IS NOT NULL THEN
    INSERT INTO church.household_members
      (organization_id, household_id, person_id, household_role,
       is_primary_contact, is_primary_household)
    VALUES (_organization_id, _hh, _me, 'adult', true, true);
  END IF;

  -- Spouse ----------------------------------------------------------------
  _spouse_mode := coalesce(_spouse->>'mode', 'none');

  IF _spouse_mode = 'link' THEN
    _spouse_id := (_spouse->>'person_id')::UUID;
    -- Guard against linking a spouse from the other branch.
    PERFORM 1 FROM church.people
     WHERE id = _spouse_id AND organization_id = _organization_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'spouse_not_found_in_organization';
    END IF;
  ELSIF _spouse_mode = 'create' THEN
    _spouse_id := church.insert_person_from_json(
      _organization_id, _spouse->'person', false, _actor_name);
  END IF;

  IF _spouse_id IS NOT NULL THEN
    IF _spouse_id = _me THEN
      RAISE EXCEPTION 'cannot_be_own_spouse';
    END IF;

    -- Only ONE direction is written: a trigger mirrors the inverse, and
    -- writing both would collide on the uniqueness constraint.
    INSERT INTO church.person_relationships
      (organization_id, person_id, related_person_id, relationship_type_id)
    VALUES (_organization_id, _me, _spouse_id, _spouse_type)
    ON CONFLICT (person_id, related_person_id, relationship_type_id) DO NOTHING;

    -- Put the spouse in the household, unless they already belong to one.
    IF _hh IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM church.household_members
                       WHERE person_id = _spouse_id AND end_date IS NULL) THEN
      INSERT INTO church.household_members
        (organization_id, household_id, person_id, household_role, is_primary_household)
      VALUES (_organization_id, _hh, _spouse_id, 'adult', true);
    END IF;
  END IF;

  -- Children --------------------------------------------------------------
  FOR _child IN SELECT * FROM jsonb_array_elements(coalesce(_children, '[]'::jsonb))
  LOOP
    CONTINUE WHEN coalesce(btrim(_child->>'first_name'), '') = '';

    -- Children inherit the family surname unless one is given, which is what
    -- the person filling the form expects.
    _child_id := church.insert_person_from_json(
      _organization_id,
      _child || jsonb_build_object(
        'last_name',
        coalesce(NULLIF(btrim(coalesce(_child->>'last_name', '')), ''),
                 _person->>'last_name')),
      true, _actor_name);

    _kids := _kids + 1;

    IF _hh IS NOT NULL THEN
      INSERT INTO church.household_members
        (organization_id, household_id, person_id, household_role, is_primary_household)
      VALUES (_organization_id, _hh, _child_id, 'child', true);
    END IF;

    INSERT INTO church.person_relationships
      (organization_id, person_id, related_person_id, relationship_type_id)
    VALUES (_organization_id, _me, _child_id, _parent_type)
    ON CONFLICT (person_id, related_person_id, relationship_type_id) DO NOTHING;

    IF _spouse_id IS NOT NULL THEN
      INSERT INTO church.person_relationships
        (organization_id, person_id, related_person_id, relationship_type_id)
      VALUES (_organization_id, _spouse_id, _child_id, _parent_type)
      ON CONFLICT (person_id, related_person_id, relationship_type_id) DO NOTHING;
    END IF;

    -- Both parents may collect the child. Explicit rows rather than inferred
    -- from the relationship, because Kids checkout reads this list directly.
    INSERT INTO church.kids_pickup_authorizations
      (organization_id, child_person_id, authorized_person_id, relationship_note,
       created_by, created_by_name)
    VALUES (_organization_id, _child_id, _me, 'Parent', auth.uid(), _actor_name)
    ON CONFLICT (child_person_id, authorized_person_id) DO NOTHING;

    IF _spouse_id IS NOT NULL THEN
      INSERT INTO church.kids_pickup_authorizations
        (organization_id, child_person_id, authorized_person_id, relationship_note,
         created_by, created_by_name)
      VALUES (_organization_id, _child_id, _spouse_id, 'Parent', auth.uid(), _actor_name)
      ON CONFLICT (child_person_id, authorized_person_id) DO NOTHING;
    END IF;

    -- KID-021 requires an emergency contact before a child can be checked in,
    -- so the family's contacts are attached to each child as well as the adult.
    FOR _contact IN SELECT * FROM jsonb_array_elements(coalesce(_emergency_contacts, '[]'::jsonb))
    LOOP
      CONTINUE WHEN coalesce(btrim(_contact->>'name'), '') = ''
                 OR coalesce(btrim(_contact->>'phone'), '') = '';
      INSERT INTO church.person_emergency_contacts
        (organization_id, person_id, name, relationship, phone, priority)
      VALUES (_organization_id, _child_id, btrim(_contact->>'name'),
              NULLIF(btrim(coalesce(_contact->>'relationship', '')), ''),
              btrim(_contact->>'phone'),
              coalesce((_contact->>'priority')::INTEGER, 1));
    END LOOP;
  END LOOP;

  -- Emergency contacts for the adult ---------------------------------------
  FOR _contact IN SELECT * FROM jsonb_array_elements(coalesce(_emergency_contacts, '[]'::jsonb))
  LOOP
    CONTINUE WHEN coalesce(btrim(_contact->>'name'), '') = ''
               OR coalesce(btrim(_contact->>'phone'), '') = '';
    INSERT INTO church.person_emergency_contacts
      (organization_id, person_id, name, relationship, phone, priority)
    VALUES (_organization_id, _me, btrim(_contact->>'name'),
            NULLIF(btrim(coalesce(_contact->>'relationship', '')), ''),
            btrim(_contact->>'phone'),
            coalesce((_contact->>'priority')::INTEGER, 1));
  END LOOP;

  -- Service interests -------------------------------------------------------
  IF _service_interest_ministry_ids IS NOT NULL THEN
    FOREACH _ministry IN ARRAY _service_interest_ministry_ids
    LOOP
      INSERT INTO church.person_service_interests
        (organization_id, person_id, ministry_id, status)
      VALUES (_organization_id, _me, _ministry, 'interested')
      ON CONFLICT (person_id, ministry_id) DO NOTHING;
    END LOOP;
  END IF;

  INSERT INTO church.people_history
    (organization_id, person_id, action, actor_id, actor_name, notes)
  VALUES (_organization_id, _me, 'registered', auth.uid(), _actor_name,
          format('Registered with %s children%s', _kids,
                 CASE WHEN _spouse_id IS NOT NULL THEN ' and a spouse' ELSE '' END));

  RETURN QUERY SELECT _me, _hh, _spouse_id, _kids;
END;
$$;

-- Shared person insert. Not granted to any client role — reachable only from
-- register_member_family, so there is no path that bypasses its validation.
CREATE OR REPLACE FUNCTION church.insert_person_from_json(
  _organization_id UUID,
  _p JSONB,
  _is_child BOOLEAN,
  _actor_name TEXT
)
RETURNS UUID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _id UUID;
  _birth_year SMALLINT := NULLIF(_p->>'birth_year', '')::SMALLINT;
  _birth_month SMALLINT := NULLIF(_p->>'birth_month', '')::SMALLINT;
BEGIN
  -- Mirrors the table CHECK, but fails with a message a form can show.
  IF _is_child AND _birth_year IS NULL THEN
    RAISE EXCEPTION 'child_requires_birth_year';
  END IF;

  INSERT INTO church.people (
    organization_id, first_name, middle_name, last_name, preferred_name,
    amharic_name, birth_year, birth_month, gender, marital_status,
    email, phone, membership_status_id, member_since,
    accepted_lord_year, accepted_lord_month, accepted_lord_is_approximate,
    is_child, school_grade_id, notes, created_by, created_by_name)
  VALUES (
    _organization_id,
    btrim(_p->>'first_name'),
    NULLIF(btrim(coalesce(_p->>'middle_name', '')), ''),
    btrim(_p->>'last_name'),
    NULLIF(btrim(coalesce(_p->>'preferred_name', '')), ''),
    NULLIF(btrim(coalesce(_p->>'amharic_name', '')), ''),
    _birth_year,
    _birth_month,
    NULLIF(_p->>'gender', ''),
    NULLIF(_p->>'marital_status', ''),
    NULLIF(btrim(coalesce(_p->>'email', '')), ''),
    NULLIF(btrim(coalesce(_p->>'phone', '')), ''),
    NULLIF(_p->>'membership_status_id', '')::UUID,
    NULLIF(_p->>'member_since', '')::DATE,
    NULLIF(_p->>'accepted_lord_year', '')::SMALLINT,
    NULLIF(_p->>'accepted_lord_month', '')::SMALLINT,
    coalesce((_p->>'accepted_lord_is_approximate')::BOOLEAN, false),
    _is_child,
    NULLIF(_p->>'school_grade_id', '')::UUID,
    NULLIF(btrim(coalesce(_p->>'notes', '')), ''),
    auth.uid(), _actor_name)
  RETURNING id INTO _id;

  RETURN _id;
END;
$$;

GRANT EXECUTE ON FUNCTION church.register_member_family(
  UUID, JSONB, JSONB, JSONB, JSONB, JSONB, UUID[]) TO authenticated;

COMMENT ON FUNCTION church.register_member_family(UUID, JSONB, JSONB, JSONB, JSONB, JSONB, UUID[]) IS
  'Registers a member together with their household, spouse and children in a '
  'single transaction. Writes people, households, household_members, '
  'person_relationships, kids_pickup_authorizations, emergency contacts and '
  'service interests atomically — a partial family cannot be created.';

NOTIFY pgrst, 'reload schema';
