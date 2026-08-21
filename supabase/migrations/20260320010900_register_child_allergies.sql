-- =====================================================
-- Capture an allergy while the parent is standing there
-- =====================================================
--
-- 20260320010800 gave church.person_sensitive a writer, but only on the member
-- profile — so an allergy could be recorded only AFTER the family existed, by
-- finding each child and opening a separate tab.
--
-- That is the wrong moment. The person filling in the registration form is
-- sitting with the parent, who is the only person who knows, and who is asked
-- exactly once. Making them come back later means the answer is usually never
-- recorded at all, and the safety card stays empty for precisely the children
-- whose families did turn up and did tell someone.
--
-- register_member_family now accepts allergy fields on each child and writes
-- them in the same transaction. Everything stays atomic: a family is created
-- whole, or not at all.

CREATE OR REPLACE FUNCTION church.set_child_sensitive_from_json(
  _person_id UUID, _organization_id UUID, _child JSONB, _actor TEXT)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _severity TEXT := NULLIF(btrim(coalesce(_child->>'allergy_severity', '')), '');
  _allergies TEXT := NULLIF(btrim(coalesce(_child->>'allergies', '')), '');
  _meds TEXT := NULLIF(btrim(coalesce(_child->>'medications', '')), '');
  _needs TEXT := NULLIF(btrim(coalesce(_child->>'special_needs', '')), '');
  _notes TEXT := NULLIF(btrim(coalesce(_child->>'medical_notes', '')), '');
  _label TEXT := NULLIF(btrim(coalesce(_child->>'allergy_label_short', '')), '');
BEGIN
  -- Nothing said about this child: write no row at all, so "no record" and
  -- "no allergy" stay distinguishable. A volunteer reading the safety card
  -- should be able to tell "we asked and there is none" from "nobody asked".
  IF _severity IS NULL AND _allergies IS NULL AND _meds IS NULL
     AND _needs IS NULL AND _notes IS NULL THEN
    RETURN;
  END IF;

  _severity := coalesce(_severity, CASE WHEN _allergies IS NOT NULL
                                        THEN 'mild' ELSE 'none' END);

  IF _severity NOT IN ('none', 'mild', 'severe', 'life_threatening') THEN
    RAISE EXCEPTION 'invalid_allergy_severity'
      USING DETAIL = 'Expected none, mild, severe or life_threatening';
  END IF;

  -- The tag text, derived when nobody typed one. An allergy on file but absent
  -- from the printed label is one the volunteer in the room never sees.
  IF _label IS NULL AND _severity <> 'none' THEN
    _label := left(coalesce(_allergies, 'ALLERGY'), 24);
  END IF;

  INSERT INTO church.person_sensitive (
    person_id, organization_id, allergy_severity, allergies,
    allergy_label_short, medications, medical_notes, special_needs,
    special_needs_flag, updated_by, updated_by_name)
  VALUES (
    _person_id, _organization_id, _severity, _allergies, _label, _meds,
    _notes, _needs, _needs IS NOT NULL, auth.uid(), _actor)
  ON CONFLICT (person_id) DO UPDATE SET
    allergy_severity = EXCLUDED.allergy_severity,
    allergies = EXCLUDED.allergies,
    allergy_label_short = EXCLUDED.allergy_label_short,
    medications = EXCLUDED.medications,
    medical_notes = EXCLUDED.medical_notes,
    special_needs = EXCLUDED.special_needs,
    special_needs_flag = EXCLUDED.special_needs_flag,
    updated_by = EXCLUDED.updated_by,
    updated_by_name = EXCLUDED.updated_by_name,
    updated_at = now();
END;
$$;

REVOKE ALL ON FUNCTION church.set_child_sensitive_from_json(UUID, UUID, JSONB, TEXT)
  FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- Registration, now recording what the parent just told you
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.register_member_family(_organization_id uuid, _person jsonb, _household jsonb DEFAULT NULL::jsonb, _spouse jsonb DEFAULT NULL::jsonb, _children jsonb DEFAULT '[]'::jsonb, _emergency_contacts jsonb DEFAULT '[]'::jsonb, _service_interest_ministry_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS TABLE(out_person_id uuid, out_household_id uuid, out_spouse_person_id uuid, out_child_count integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'church', 'public', 'extensions'
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

    -- Allergies, medication and special needs, captured in the same breath as
    -- the child's name. Recorded only when something was actually said, so
    -- "no allergy" stays distinguishable from "nobody asked".
    PERFORM church.set_child_sensitive_from_json(
      _child_id, _organization_id, _child, _actor_name);

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

NOTIFY pgrst, 'reload schema';
