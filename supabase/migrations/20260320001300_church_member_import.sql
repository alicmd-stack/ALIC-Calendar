-- =====================================================
-- Member CSV import: staged rows, duplicate matching, dry run, commit
-- =====================================================
--
-- Importing a church spreadsheet is the moment a directory either becomes
-- useful or becomes permanently polluted with duplicates. So the flow is
-- staged rather than direct:
--
--   1. rows are uploaded into import_rows and NOTHING touches church.people
--   2. import_dry_run classifies every row and computes a field-level diff
--   3. a human reviews, and only then import_commit applies the decisions
--
-- The database is authoritative for duplicate matching. The client has its own
-- matcher for instant feedback and for catching duplicates WITHIN one file,
-- but the tiers below are what actually decide.

CREATE TABLE church.import_batches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  filename TEXT NOT NULL,
  row_count INTEGER NOT NULL DEFAULT 0,
  -- Source-header -> target-column mapping, kept so the same spreadsheet
  -- shape can be re-imported next year without redoing the mapping.
  column_mapping JSONB NOT NULL DEFAULT '{}'::jsonb,
  status TEXT NOT NULL DEFAULT 'staged',
  summary JSONB,
  dry_run_at TIMESTAMPTZ,
  committed_at TIMESTAMPTZ,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_by_name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_import_batches_status
    CHECK (status IN ('staged', 'dry_run', 'committed', 'cancelled')),
  -- A batch cannot be committed without having been dry-run first. The point
  -- of the preview is that it is not optional.
  CONSTRAINT chk_dry_run_before_commit
    CHECK (committed_at IS NULL OR dry_run_at IS NOT NULL)
);

CREATE TABLE church.import_rows (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id UUID NOT NULL REFERENCES church.import_batches(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  row_number INTEGER NOT NULL,
  raw JSONB NOT NULL,
  parsed JSONB NOT NULL DEFAULT '{}'::jsonb,
  status TEXT NOT NULL DEFAULT 'pending',
  match_person_id UUID REFERENCES church.people(id) ON DELETE SET NULL,
  match_reason TEXT,
  -- Field-level current-vs-incoming, so the reviewer sees exactly what an
  -- update would change rather than a bare "will update".
  diff JSONB,
  errors JSONB NOT NULL DEFAULT '[]'::jsonb,
  -- Set by the reviewer: skip a row, or keep the existing value on update.
  include BOOLEAN NOT NULL DEFAULT true,
  created_person_id UUID REFERENCES church.people(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_import_rows UNIQUE (batch_id, row_number),
  CONSTRAINT chk_import_rows_status
    CHECK (status IN ('pending', 'create', 'update', 'duplicate', 'conflict', 'error', 'committed', 'skipped'))
);

CREATE INDEX idx_import_batches_org ON church.import_batches(organization_id, created_at DESC);
CREATE INDEX idx_import_rows_batch ON church.import_rows(batch_id, row_number);
CREATE INDEX idx_import_rows_status ON church.import_rows(batch_id, status);

CREATE TRIGGER update_church_import_batches_updated_at
  BEFORE UPDATE ON church.import_batches
  FOR EACH ROW EXECUTE FUNCTION church.update_updated_at_column();

-- ---------------------------------------------------------------------------
-- Duplicate matching
-- ---------------------------------------------------------------------------
-- Tiers, strongest first. The first three are confident enough to update an
-- existing person automatically. Tier 4 is NOT — a name-only or fuzzy match
-- is surfaced as a conflict for a human, because silently merging two people
-- who happen to share a name is unrecoverable.
CREATE OR REPLACE FUNCTION church.find_duplicate_person(
  _organization_id UUID,
  _first_name TEXT,
  _last_name TEXT,
  _email TEXT,
  _phone TEXT,
  _birth_year SMALLINT,
  _birth_month SMALLINT
)
RETURNS TABLE (person_id UUID, tier INTEGER, reason TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _digits TEXT := regexp_replace(coalesce(_phone, ''), '\D', '', 'g');
  _search TEXT := lower(btrim(coalesce(_first_name, '') || ' ' || coalesce(_last_name, '')));
  _found UUID;
BEGIN
  -- Tier 1: same email.
  IF coalesce(btrim(_email), '') <> '' THEN
    SELECT p.id INTO _found FROM church.people p
     WHERE p.organization_id = _organization_id
       AND p.merged_into_person_id IS NULL
       AND lower(p.email) = lower(btrim(_email))
     LIMIT 1;
    IF _found IS NOT NULL THEN
      RETURN QUERY SELECT _found, 1, 'Same email address'; RETURN;
    END IF;
  END IF;

  -- Tier 2: same trailing 10 phone digits AND same surname.
  IF length(_digits) >= 10 AND coalesce(btrim(_last_name), '') <> '' THEN
    SELECT p.id INTO _found FROM church.people p
     WHERE p.organization_id = _organization_id
       AND p.merged_into_person_id IS NULL
       AND p.phone_digits <> ''
       AND right(p.phone_digits, 10) = right(_digits, 10)
       AND lower(p.last_name) = lower(btrim(_last_name))
     LIMIT 1;
    IF _found IS NOT NULL THEN
      RETURN QUERY SELECT _found, 2, 'Same phone and surname'; RETURN;
    END IF;
  END IF;

  -- Tier 3: same name AND same birth year+month.
  IF _birth_year IS NOT NULL AND _birth_month IS NOT NULL THEN
    SELECT p.id INTO _found FROM church.people p
     WHERE p.organization_id = _organization_id
       AND p.merged_into_person_id IS NULL
       AND p.search_name = _search
       AND p.birth_year = _birth_year
       AND p.birth_month = _birth_month
     LIMIT 1;
    IF _found IS NOT NULL THEN
      RETURN QUERY SELECT _found, 3, 'Same name and birthday'; RETURN;
    END IF;
  END IF;

  -- Tier 4: name-only or close fuzzy match. Reported, never auto-applied.
  SELECT p.id INTO _found FROM church.people p
   WHERE p.organization_id = _organization_id
     AND p.merged_into_person_id IS NULL
     AND (p.search_name = _search OR similarity(p.search_name, _search) >= 0.85)
   ORDER BY similarity(p.search_name, _search) DESC
   LIMIT 1;
  IF _found IS NOT NULL THEN
    RETURN QUERY SELECT _found, 4, 'Similar name — needs review'; RETURN;
  END IF;

  RETURN;
END;
$$;

-- ---------------------------------------------------------------------------
-- Dry run — classify every row, write NOTHING to church.people
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.import_dry_run(_batch_id UUID)
RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  b church.import_batches%ROWTYPE;
  r church.import_rows%ROWTYPE;
  m RECORD;
  _p JSONB;
  _errs JSONB;
  _diff JSONB;
  _existing church.people%ROWTYPE;
  _summary JSONB;
  _by SMALLINT;
  _bm SMALLINT;
  _seen_email TEXT[] := ARRAY[]::TEXT[];
  _email TEXT;
BEGIN
  SELECT * INTO b FROM church.import_batches WHERE id = _batch_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'batch_not_found'; END IF;

  IF NOT church.has_permission_in_org(
       b.organization_id, ARRAY['members_admin','members_import']::church.module_permission[]) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  IF b.committed_at IS NOT NULL THEN
    RAISE EXCEPTION 'batch_already_committed';
  END IF;

  FOR r IN SELECT * FROM church.import_rows WHERE batch_id = _batch_id ORDER BY row_number
  LOOP
    _p := r.parsed;
    _errs := '[]'::jsonb;
    _diff := NULL;
    _existing := NULL;

    _by := NULLIF(_p->>'birth_year', '')::SMALLINT;
    _bm := NULLIF(_p->>'birth_month', '')::SMALLINT;

    -- Validation ---------------------------------------------------------
    IF coalesce(btrim(_p->>'first_name'), '') = '' THEN
      _errs := _errs || jsonb_build_array('First name is required');
    END IF;
    IF coalesce(btrim(_p->>'last_name'), '') = '' THEN
      _errs := _errs || jsonb_build_array('Last name is required');
    END IF;
    IF _bm IS NOT NULL AND (_bm < 1 OR _bm > 12) THEN
      _errs := _errs || jsonb_build_array('Birth month must be 1-12');
    END IF;
    IF _by IS NOT NULL AND (_by < 1900 OR _by > EXTRACT(YEAR FROM CURRENT_DATE)) THEN
      _errs := _errs || jsonb_build_array('Birth year is out of range');
    END IF;
    IF _bm IS NOT NULL AND _by IS NULL THEN
      _errs := _errs || jsonb_build_array('A birth month needs a birth year');
    END IF;
    IF coalesce((_p->>'is_child')::BOOLEAN, false) AND _by IS NULL THEN
      _errs := _errs || jsonb_build_array('A child needs a birth year');
    END IF;
    IF coalesce(btrim(_p->>'email'), '') <> ''
       AND btrim(_p->>'email') !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
      _errs := _errs || jsonb_build_array('Email address is not valid');
    END IF;

    -- Duplicates WITHIN the file. A spreadsheet listing the same person twice
    -- is common and would otherwise create two records in one import.
    _email := lower(btrim(coalesce(_p->>'email', '')));
    IF _email <> '' THEN
      IF _email = ANY(_seen_email) THEN
        _errs := _errs || jsonb_build_array('This email appears earlier in the same file');
      ELSE
        _seen_email := _seen_email || _email;
      END IF;
    END IF;

    IF jsonb_array_length(_errs) > 0 THEN
      UPDATE church.import_rows
         SET status = 'error', errors = _errs, match_person_id = NULL,
             match_reason = NULL, diff = NULL
       WHERE id = r.id;
      CONTINUE;
    END IF;

    -- Matching -----------------------------------------------------------
    SELECT * INTO m FROM church.find_duplicate_person(
      b.organization_id, _p->>'first_name', _p->>'last_name',
      _p->>'email', _p->>'phone', _by, _bm) LIMIT 1;

    IF m.person_id IS NULL THEN
      UPDATE church.import_rows
         SET status = 'create', errors = '[]'::jsonb, match_person_id = NULL,
             match_reason = NULL, diff = NULL
       WHERE id = r.id;
      CONTINUE;
    END IF;

    SELECT * INTO _existing FROM church.people WHERE id = m.person_id;

    -- Field-level diff, only for fields the row actually supplies.
    SELECT jsonb_agg(d) INTO _diff FROM (
      SELECT jsonb_build_object('field', f.field, 'current', f.cur, 'incoming', f.inc) AS d
      FROM (VALUES
        ('first_name', _existing.first_name, NULLIF(btrim(coalesce(_p->>'first_name','')),'')),
        ('last_name',  _existing.last_name,  NULLIF(btrim(coalesce(_p->>'last_name','')),'')),
        ('email',      _existing.email,      NULLIF(btrim(coalesce(_p->>'email','')),'')),
        ('phone',      _existing.phone,      NULLIF(btrim(coalesce(_p->>'phone','')),'')),
        ('birth_year', _existing.birth_year::TEXT, NULLIF(_p->>'birth_year','')),
        ('birth_month',_existing.birth_month::TEXT, NULLIF(_p->>'birth_month','')),
        ('gender',     _existing.gender,     NULLIF(_p->>'gender','')),
        ('marital_status', _existing.marital_status, NULLIF(_p->>'marital_status',''))
      ) AS f(field, cur, inc)
      WHERE f.inc IS NOT NULL AND f.inc IS DISTINCT FROM f.cur
    ) sub;

    UPDATE church.import_rows
       SET status = CASE WHEN m.tier <= 3 THEN 'update' ELSE 'conflict' END,
           match_person_id = m.person_id,
           match_reason = m.reason,
           diff = coalesce(_diff, '[]'::jsonb),
           errors = '[]'::jsonb
     WHERE id = r.id;
  END LOOP;

  SELECT jsonb_build_object(
    'create',    count(*) FILTER (WHERE status = 'create'),
    'update',    count(*) FILTER (WHERE status = 'update'),
    'conflict',  count(*) FILTER (WHERE status = 'conflict'),
    'error',     count(*) FILTER (WHERE status = 'error'),
    'total',     count(*))
    INTO _summary
  FROM church.import_rows WHERE batch_id = _batch_id;

  UPDATE church.import_batches
     SET status = 'dry_run', dry_run_at = now(), summary = _summary
   WHERE id = _batch_id;

  RETURN _summary;
END;
$$;

-- ---------------------------------------------------------------------------
-- Commit — apply the reviewed rows
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
  _created INTEGER := 0;
  _updated INTEGER := 0;
  _skipped INTEGER := 0;
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
    -- Conflicts and errors are never applied automatically. A reviewer can
    -- resolve a conflict by editing the row's status to 'create' or 'update'
    -- before committing.
    IF NOT r.include OR r.status IN ('error', 'conflict', 'committed', 'skipped') THEN
      _skipped := _skipped + 1;
      UPDATE church.import_rows SET status = 'skipped' WHERE id = r.id
        AND status NOT IN ('error', 'committed');
      CONTINUE;
    END IF;

    _p := r.parsed;

    IF r.status = 'create' THEN
      _new := church.insert_person_from_json(
        b.organization_id, _p,
        coalesce((_p->>'is_child')::BOOLEAN, false), _actor);
      _created := _created + 1;
      UPDATE church.import_rows
         SET status = 'committed', created_person_id = _new WHERE id = r.id;

    ELSIF r.status = 'update' AND r.match_person_id IS NOT NULL THEN
      -- Only non-empty incoming values overwrite; a blank column in the
      -- spreadsheet must not erase data already on file.
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
      UPDATE church.import_rows
         SET status = 'committed', created_person_id = r.match_person_id WHERE id = r.id;
    END IF;
  END LOOP;

  _summary := jsonb_build_object(
    'created', _created, 'updated', _updated, 'skipped', _skipped);

  UPDATE church.import_batches
     SET status = 'committed', committed_at = now(),
         summary = coalesce(summary, '{}'::jsonb) || _summary
   WHERE id = _batch_id;

  RETURN _summary;
END;
$$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
ALTER TABLE church.import_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE church.import_rows ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Import users can view batches"
  ON church.import_batches FOR SELECT TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['members_admin','members_import']::church.module_permission[])));

CREATE POLICY "Import users can manage batches"
  ON church.import_batches FOR ALL TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['members_admin','members_import']::church.module_permission[])))
  WITH CHECK (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['members_admin','members_import']::church.module_permission[])));

CREATE POLICY "Import users can view rows"
  ON church.import_rows FOR SELECT TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['members_admin','members_import']::church.module_permission[])));

CREATE POLICY "Import users can manage rows"
  ON church.import_rows FOR ALL TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['members_admin','members_import']::church.module_permission[])))
  WITH CHECK (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['members_admin','members_import']::church.module_permission[])));

GRANT SELECT, INSERT, UPDATE, DELETE ON church.import_batches TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.import_rows TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.import_batches TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.import_rows TO service_role;

GRANT EXECUTE ON FUNCTION church.find_duplicate_person(
  UUID, TEXT, TEXT, TEXT, TEXT, SMALLINT, SMALLINT) TO authenticated;
GRANT EXECUTE ON FUNCTION church.import_dry_run(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION church.import_commit(UUID) TO authenticated;

COMMENT ON FUNCTION church.import_dry_run(UUID) IS
  'Classifies every staged row as create/update/conflict/error and computes a '
  'field-level diff. Writes only to church.import_rows — church.people is not '
  'touched until import_commit.';

NOTIFY pgrst, 'reload schema';
