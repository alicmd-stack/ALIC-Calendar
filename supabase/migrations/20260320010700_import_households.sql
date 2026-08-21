-- =====================================================
-- Imported people need to be in a family
-- =====================================================
--
-- import_commit creates church.people rows and nothing else. No household, no
-- household_members. That looks harmless until you try to use the result:
--
-- church.station_search_households INNER JOINs households -> household_members
-- -> people, so a person with no household row is INVISIBLE to the check-in
-- desk. Import a hundred families and every one of them returns "No family
-- found" at the desk, forever.
--
-- It is also what decides who may collect a child:
-- church.is_approved_collector approves an adult of the child's own household.
-- No household row means no approved collector, which for a child under a
-- protective order means nobody at all can take them home.
--
-- So one CSV column — the family name — is the difference between an import
-- that populates a directory and an import that populates a directory and a
-- Sunday.
--
-- Families are keyed on the household NAME within the branch, case- and
-- whitespace-insensitively, because that is what a church spreadsheet actually
-- contains. Rows with no household name are imported exactly as before.

-- ---------------------------------------------------------------------------
-- Find or create a family by name
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.upsert_household_by_name(
  _organization_id UUID, _name TEXT, _actor TEXT)
RETURNS UUID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _clean TEXT := NULLIF(btrim(coalesce(_name, '')), '');
  _id UUID;
BEGIN
  IF _clean IS NULL THEN RETURN NULL; END IF;

  SELECT h.id INTO _id
  FROM church.households h
  WHERE h.organization_id = _organization_id
    AND lower(btrim(h.name)) = lower(_clean)
  ORDER BY h.created_at
  LIMIT 1;

  IF _id IS NOT NULL THEN RETURN _id; END IF;

  INSERT INTO church.households (organization_id, name, created_by, created_by_name)
  VALUES (_organization_id, _clean, auth.uid(), _actor)
  RETURNING id INTO _id;

  RETURN _id;
END;
$$;

REVOKE ALL ON FUNCTION church.upsert_household_by_name(UUID, TEXT, TEXT) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- Put a person in a family, without disturbing one they are already in
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.add_person_to_household(
  _person_id UUID, _household_id UUID, _is_primary BOOLEAN DEFAULT false)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _org UUID;
BEGIN
  IF _person_id IS NULL OR _household_id IS NULL THEN RETURN; END IF;

  SELECT organization_id INTO _org FROM church.people WHERE id = _person_id;

  -- Already in this household and still current: nothing to do. Re-running an
  -- import must not stack duplicate memberships.
  IF EXISTS (
    SELECT 1 FROM church.household_members hm
    WHERE hm.person_id = _person_id
      AND hm.household_id = _household_id
      AND hm.end_date IS NULL
  ) THEN
    RETURN;
  END IF;

  -- A person belongs to one household at a time. An existing membership is
  -- ENDED rather than deleted, so the history of who lived with whom survives
  -- — which matters when a custody question is asked six months later.
  UPDATE church.household_members
     SET end_date = CURRENT_DATE, updated_at = now()
   WHERE person_id = _person_id AND end_date IS NULL;

  INSERT INTO church.household_members (
    organization_id, household_id, person_id, is_primary_contact, start_date)
  VALUES (_org, _household_id, _person_id, coalesce(_is_primary, false),
          CURRENT_DATE);
END;
$$;

REVOKE ALL ON FUNCTION church.add_person_to_household(UUID, UUID, BOOLEAN) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- import_commit, now family-aware
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.import_commit(_batch_id UUID)
RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  b church.import_batches%ROWTYPE;
  r church.import_rows%ROWTYPE;
  _p JSONB;
  _new UUID;
  _hh UUID;
  _person UUID;
  _created INTEGER := 0;
  _updated INTEGER := 0;
  _skipped INTEGER := 0;
  _households INTEGER := 0;
  _placed INTEGER := 0;
  _actor TEXT;
  _summary JSONB;
BEGIN
  SELECT * INTO b FROM church.import_batches WHERE id = _batch_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'batch_not_found'; END IF;

  IF NOT church.has_permission_in_org(
       b.organization_id, ARRAY['members_admin','members_import']::church.module_permission[]) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  IF b.dry_run_at IS NULL THEN
    RAISE EXCEPTION 'dry_run_required_before_commit';
  END IF;
  IF b.committed_at IS NOT NULL THEN
    RAISE EXCEPTION 'batch_already_committed';
  END IF;

  _actor := coalesce((SELECT full_name FROM public.profiles WHERE id = auth.uid()),
                     b.created_by_name, 'Import');

  FOR r IN SELECT * FROM church.import_rows
            WHERE batch_id = _batch_id ORDER BY row_number
  LOOP
    IF NOT r.include OR r.status IN ('error', 'conflict', 'committed', 'skipped') THEN
      _skipped := _skipped + 1;
      UPDATE church.import_rows SET status = 'skipped' WHERE id = r.id
        AND status NOT IN ('error', 'committed');
      CONTINUE;
    END IF;

    _p := r.parsed;
    _person := NULL;

    IF r.status = 'create' THEN
      _new := church.insert_person_from_json(
        b.organization_id, _p,
        coalesce((_p->>'is_child')::BOOLEAN, false), _actor);
      _created := _created + 1;
      _person := _new;
      UPDATE church.import_rows
         SET status = 'committed', created_person_id = _new WHERE id = r.id;

    ELSIF r.status = 'update' AND r.match_person_id IS NOT NULL THEN
      UPDATE church.people p
         SET first_name  = coalesce(NULLIF(btrim(coalesce(_p->>'first_name','')),''), p.first_name),
             last_name   = coalesce(NULLIF(btrim(coalesce(_p->>'last_name','')),''), p.last_name),
             middle_name = coalesce(NULLIF(btrim(coalesce(_p->>'middle_name','')),''), p.middle_name),
             email       = coalesce(NULLIF(btrim(coalesce(_p->>'email','')),''), p.email),
             phone       = coalesce(NULLIF(btrim(coalesce(_p->>'phone','')),''), p.phone),
             birth_year  = coalesce(NULLIF(_p->>'birth_year','')::SMALLINT, p.birth_year),
             birth_month = coalesce(NULLIF(_p->>'birth_month','')::SMALLINT, p.birth_month),
             gender      = coalesce(NULLIF(_p->>'gender',''), p.gender),
             marital_status = coalesce(NULLIF(_p->>'marital_status',''), p.marital_status),
             amharic_name   = coalesce(NULLIF(btrim(coalesce(_p->>'amharic_name','')),''), p.amharic_name),
             updated_at = now()
       WHERE p.id = r.match_person_id;
      _updated := _updated + 1;
      _person := r.match_person_id;
      UPDATE church.import_rows
         SET status = 'committed', created_person_id = r.match_person_id WHERE id = r.id;
    END IF;

    -- The family. Without this the person exists and the check-in desk cannot
    -- see them, because station_search_households reaches people only THROUGH
    -- households.
    IF _person IS NOT NULL
       AND coalesce(btrim(_p->>'household_name'), '') <> '' THEN
      _hh := church.upsert_household_by_name(
        b.organization_id, _p->>'household_name', _actor);

      IF _hh IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM church.household_members hm
                       WHERE hm.household_id = _hh AND hm.end_date IS NULL) THEN
          _households := _households + 1;
        END IF;

        PERFORM church.add_person_to_household(
          _person, _hh,
          -- The first adult into a family becomes the primary contact, which
          -- is whose number the desk shows and who the roster phones.
          NOT coalesce((_p->>'is_child')::BOOLEAN, false)
            AND NOT EXISTS (
              SELECT 1 FROM church.household_members hm
              WHERE hm.household_id = _hh
                AND hm.is_primary_contact
                AND hm.end_date IS NULL));
        _placed := _placed + 1;
      END IF;
    END IF;
  END LOOP;

  _summary := jsonb_build_object(
    'created', _created, 'updated', _updated, 'skipped', _skipped,
    'households_created', _households, 'placed_in_households', _placed);

  UPDATE church.import_batches
     SET status = 'committed', committed_at = now(),
         summary = coalesce(summary, '{}'::jsonb) || _summary
   WHERE id = _batch_id;

  RETURN _summary;
END;
$$;

GRANT EXECUTE ON FUNCTION church.import_commit(UUID) TO authenticated;

COMMENT ON FUNCTION church.import_commit(UUID) IS
  'Applies a reviewed import batch. A row carrying household_name is placed '
  'into that family, creating it if needed — without which the imported '
  'person is invisible to check-in and has no approved collector.';

NOTIFY pgrst, 'reload schema';
