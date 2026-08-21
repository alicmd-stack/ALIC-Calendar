-- =====================================================
-- Registering a visiting family at the desk
-- =====================================================
--
-- A family who has never been here before arrives at 10:15 with two children.
-- Until now the desk could look them up, fail to find them, and stop. The only
-- route in was the full member registration form, which is an admin screen with
-- twenty fields — not something you work through with a queue behind you.
--
-- This is the plan's "New Family desk": everything needed to put a child safely
-- in a room, and nothing else. Roughly a minute of typing.
--
-- WHAT IT DELIBERATELY DOES NOT DO
--
--   * No address, no birthday, no marital status, no email requirement. A
--     visitor is not a member record yet; making the desk collect one is how
--     the express lane turns into a five-minute queue.
--   * No membership decisions. Everyone created here is a VISITOR. Turning a
--     visitor into a member is a pastoral act, not a check-in desk act.
--
-- WHAT IT MUST GET RIGHT, because these are the ways a shortcut hurts a child
--
--   * The guardian must land in the household AND hold a guardianship
--     relationship. is_approved_collector works off exactly those two things,
--     so a guardian who is merely "created" cannot collect the child they just
--     dropped off — they would be refused at the classroom door by the very
--     control that is supposed to protect them.
--   * Allergies are captured HERE or not at all. A visiting child with a peanut
--     allergy nobody wrote down is the precise failure this system exists to
--     prevent, and there is no second chance later in the morning.
--   * A returning visitor typed in again becomes a DUPLICATE child with a
--     separate history, which quietly breaks the first-visit report and splits
--     the pickup whitelist. So an existing phone number stops the write and
--     sends the desk back to search.
--
-- ETHIOPIAN NAMING. A child takes their father's GIVEN name, so the child's
-- second name defaults to the guardian's first name — not their surname. The
-- desk can override it, which matters when the adult standing there is the
-- mother: she keeps her own father's name, and the child does not take it.

-- The desk can now create people, so the audit log needs to be able to say so.
--
-- The live constraint is chk_check_in_audit_action. Dropping the name Postgres
-- would have generated (check_in_audit_action_check) silently dropped nothing
-- and added a SECOND constraint beside the real one, which still refused the
-- new action — so both names are cleared before the correct one is written.
ALTER TABLE church.check_in_audit DROP CONSTRAINT IF EXISTS check_in_audit_action_check;
ALTER TABLE church.check_in_audit DROP CONSTRAINT IF EXISTS chk_check_in_audit_action;
ALTER TABLE church.check_in_audit ADD CONSTRAINT chk_check_in_audit_action
  CHECK (action = ANY (ARRAY[
    'check_in', 'check_out', 'transfer', 'code_failed', 'override',
    'sensitive_viewed', 'restricted_pickup_attempt', 'restricted_pickup_override',
    'pin_failed', 'auto_expired', 'label_reprint', 'shift_opened', 'shift_closed',
    'visitor_registered']));

CREATE OR REPLACE FUNCTION church.station_register_visitor_family(
  _guardian JSONB,
  _children JSONB,
  _shift_token TEXT DEFAULT NULL
)
RETURNS TABLE (
  household_id UUID,
  household_name TEXT,
  guardian_person_id UUID,
  child_person_id UUID,
  child_display_name TEXT
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  a church.resolved_actor;
  _org UUID;
  _hh UUID;
  _hh_name TEXT;
  _guardian_id UUID;
  _g_first TEXT;
  _g_last TEXT;
  _g_phone TEXT;
  _digits TEXT;
  _visitor_status UUID;
  _parent_type UUID;
  _existing TEXT;
  _child JSONB;
  _child_id UUID;
  _c_first TEXT;
  _c_last TEXT;
  _sev TEXT;
  _allergies TEXT;
BEGIN
  a := church.resolve_actor(_shift_token);
  IF NOT a.can_check_in THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;
  _org := a.organization_id;

  _g_first := btrim(coalesce(_guardian->>'first_name', ''));
  _g_last  := btrim(coalesce(_guardian->>'last_name', ''));
  _g_phone := btrim(coalesce(_guardian->>'phone', ''));

  IF _g_first = '' OR _g_last = '' THEN
    RAISE EXCEPTION 'guardian_name_required';
  END IF;

  -- The phone is not bureaucracy: it is how the room reaches this adult during
  -- the service, and how the desk finds them again next week.
  _digits := regexp_replace(_g_phone, '\D', '', 'g');
  IF length(_digits) < 10 THEN
    RAISE EXCEPTION 'guardian_phone_required';
  END IF;

  IF _children IS NULL OR jsonb_typeof(_children) <> 'array'
     OR jsonb_array_length(_children) = 0 THEN
    RAISE EXCEPTION 'no_children_supplied';
  END IF;

  -- Stop before writing anything if this family is already on file. Creating a
  -- second record splits their history and their pickup whitelist.
  SELECT h.name INTO _existing
  FROM church.people p
  JOIN church.household_members hm
    ON hm.person_id = p.id AND hm.end_date IS NULL
  JOIN church.households h ON h.id = hm.household_id
  WHERE p.organization_id = _org
    AND p.is_active
    AND p.merged_into_person_id IS NULL
    AND p.phone_digits = _digits
  LIMIT 1;

  IF _existing IS NOT NULL THEN
    RAISE EXCEPTION 'family_already_exists:%', _existing;
  END IF;

  SELECT id INTO _visitor_status
  FROM church.membership_statuses
  WHERE organization_id = _org AND code = 'visitor' LIMIT 1;

  SELECT id INTO _parent_type
  FROM church.relationship_types
  WHERE organization_id = _org AND code = 'parent' AND is_active LIMIT 1;

  IF _parent_type IS NULL THEN
    -- Without this the guardian cannot be recorded as a guardian, and the
    -- pickup check would refuse to release the child to them. Refuse to write a
    -- family we could not later hand back.
    RAISE EXCEPTION 'no_parent_relationship_type';
  END IF;

  _hh_name := _g_first || ' ' || _g_last;

  INSERT INTO church.households
    (organization_id, name, primary_phone, created_by, created_by_name, notes)
  VALUES (_org, _hh_name, _g_phone, auth.uid(), a.actor_name,
          'Registered at check-in')
  RETURNING id INTO _hh;

  INSERT INTO church.people
    (organization_id, first_name, last_name, phone, email, is_child,
     membership_status_id, notes)
  VALUES (_org, _g_first, _g_last, _g_phone,
          NULLIF(btrim(coalesce(_guardian->>'email', '')), ''),
          false, _visitor_status, 'Registered at check-in')
  RETURNING id INTO _guardian_id;

  INSERT INTO church.household_members
    (organization_id, household_id, person_id, household_role,
     is_primary_contact, is_primary_household)
  VALUES (_org, _hh, _guardian_id, 'adult', true, true);

  FOR _child IN SELECT * FROM jsonb_array_elements(_children) LOOP
    _c_first := btrim(coalesce(_child->>'first_name', ''));
    CONTINUE WHEN _c_first = '';

    -- people has CHECK (NOT is_child OR birth_year IS NOT NULL), and the age
    -- band is the fallback when a visiting child has no school grade on file —
    -- which is every visiting child. Say so plainly here, rather than letting a
    -- constraint violation surface at the desk as a wall of Postgres.
    IF NULLIF(btrim(coalesce(_child->>'birth_year', '')), '') IS NULL THEN
      RAISE EXCEPTION 'child_birth_year_required:%', _c_first;
    END IF;

    -- Patronymic: the father's GIVEN name, not his surname.
    _c_last := NULLIF(btrim(coalesce(_child->>'last_name', '')), '');
    _c_last := coalesce(_c_last, _g_first);

    INSERT INTO church.people
      (organization_id, first_name, last_name, is_child,
       birth_year, birth_month, school_grade_id, membership_status_id, notes)
    VALUES (_org, _c_first, _c_last, true,
            NULLIF(_child->>'birth_year', '')::INT,
            NULLIF(_child->>'birth_month', '')::INT,
            NULLIF(_child->>'school_grade_id', '')::UUID,
            _visitor_status, 'Registered at check-in')
    RETURNING id INTO _child_id;

    INSERT INTO church.household_members
      (organization_id, household_id, person_id, household_role,
       is_primary_contact, is_primary_household)
    VALUES (_org, _hh, _child_id, 'child', false, true);

    -- Guardian -> child. The mirror trigger writes the inverse. This is what
    -- is_approved_collector reads, so without it the adult who just dropped the
    -- child off would be refused at the classroom door.
    INSERT INTO church.person_relationships
      (organization_id, person_id, related_person_id, relationship_type_id,
       start_date)
    VALUES (_org, _guardian_id, _child_id, _parent_type, CURRENT_DATE);

    _allergies := NULLIF(btrim(coalesce(_child->>'allergies', '')), '');
    IF _allergies IS NOT NULL THEN
      _sev := coalesce(NULLIF(btrim(coalesce(_child->>'allergy_severity', '')), ''),
                       'severe');
      INSERT INTO church.person_sensitive
        (person_id, organization_id, allergy_severity, allergies,
         allergy_label_short, updated_by, updated_by_name)
      VALUES (_child_id, _org, _sev, _allergies,
              -- What goes on the tag. left() rather than a wrapped paragraph:
              -- the label bar is a warning, not the medical record.
              left(_allergies, 60), auth.uid(), a.actor_name);
    END IF;

    RETURN QUERY SELECT _hh, _hh_name, _guardian_id, _child_id,
                        _c_first || ' ' || left(_c_last, 1) || '.';
  END LOOP;

  INSERT INTO church.check_in_audit
    (organization_id, action, outcome, station_id, volunteer_id,
     actor_auth_user_id, actor_name, detail)
  VALUES (_org, 'visitor_registered', 'success', a.station_id, a.volunteer_id,
          auth.uid(), a.actor_name,
          jsonb_build_object('household_id', _hh, 'household_name', _hh_name,
                             'children', jsonb_array_length(_children)));
END;
$$;

REVOKE ALL ON FUNCTION church.station_register_visitor_family(JSONB, JSONB, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION church.station_register_visitor_family(JSONB, JSONB, TEXT)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
