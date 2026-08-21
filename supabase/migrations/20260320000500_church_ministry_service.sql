-- =====================================================
-- Ministry service assignments and service interests
-- =====================================================
--
-- Ministry service is many-to-many: one member serves in many ministries, one
-- ministry has many members, and a leader may lead several ministries. It is
-- therefore a junction table, never repeated columns on the person record.
--
-- The ministry master is budget.ministries — reused rather than duplicated, so
-- the church does not end up maintaining two divergent ministry lists. The FK
-- crosses schemas, which Postgres supports fine.

-- Needed so church.ministry_assignments can carry a composite FK and make a
-- cross-branch assignment structurally impossible. Redundant with the primary
-- key, but a composite FK requires a matching unique constraint.
ALTER TABLE budget.ministries
  ADD CONSTRAINT uq_ministries_id_org UNIQUE (id, organization_id);

-- ---------------------------------------------------------------------------
-- Member -> Ministry assignments
-- ---------------------------------------------------------------------------
CREATE TABLE church.ministry_assignments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  person_id UUID NOT NULL,
  ministry_id UUID NOT NULL,
  ministry_role_id UUID NOT NULL REFERENCES church.ministry_roles(id) ON DELETE RESTRICT,
  start_date DATE NOT NULL DEFAULT CURRENT_DATE,
  -- NULL while serving. Assignments are ended, never deleted (BR-11), so
  -- service history survives.
  end_date DATE,
  is_primary_role BOOLEAN NOT NULL DEFAULT false,
  notes TEXT,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_by_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT fk_ministry_assignments_person
    FOREIGN KEY (person_id, organization_id)
    REFERENCES church.people(id, organization_id) ON DELETE CASCADE,
  -- RESTRICT: deleting a ministry must not silently erase who served in it.
  CONSTRAINT fk_ministry_assignments_ministry
    FOREIGN KEY (ministry_id, organization_id)
    REFERENCES budget.ministries(id, organization_id) ON DELETE RESTRICT,

  CONSTRAINT chk_ministry_assignments_dates CHECK (end_date IS NULL OR end_date >= start_date),

  -- BR-08: no duplicate active Member + Ministry + Role. An EXCLUDE rather
  -- than a partial unique index, because it also forbids two overlapping
  -- historical spans for the same trio — re-adding someone to a role they
  -- already held during that period is a data-entry error, not a new fact.
  CONSTRAINT no_overlapping_ministry_assignment EXCLUDE USING gist (
    person_id WITH =,
    ministry_id WITH =,
    ministry_role_id WITH =,
    daterange(start_date, end_date, '[]') WITH &&
  )
);

-- One primary role per person per ministry.
CREATE UNIQUE INDEX uq_ministry_assignments_one_primary
  ON church.ministry_assignments(person_id, ministry_id)
  WHERE is_primary_role AND end_date IS NULL;

CREATE INDEX idx_ministry_assignments_ministry_active
  ON church.ministry_assignments(ministry_id, person_id) WHERE end_date IS NULL;
CREATE INDEX idx_ministry_assignments_person_active
  ON church.ministry_assignments(person_id) WHERE end_date IS NULL;
CREATE INDEX idx_ministry_assignments_org ON church.ministry_assignments(organization_id);

-- ---------------------------------------------------------------------------
-- Service interests ("where I would like to serve")
-- ---------------------------------------------------------------------------
-- Spec 7.5: stored as rows, never comma-separated text, so the pipeline report
-- ("interested in X but not yet serving") is a join rather than a string
-- search.
CREATE TABLE church.person_service_interests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  person_id UUID NOT NULL,
  ministry_id UUID NOT NULL,
  interest_level TEXT NOT NULL DEFAULT 'medium',
  status TEXT NOT NULL DEFAULT 'interested',
  interest_date DATE NOT NULL DEFAULT CURRENT_DATE,
  follow_up_owner_person_id UUID,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT fk_service_interests_person
    FOREIGN KEY (person_id, organization_id)
    REFERENCES church.people(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT fk_service_interests_ministry
    FOREIGN KEY (ministry_id, organization_id)
    REFERENCES budget.ministries(id, organization_id) ON DELETE RESTRICT,
  CONSTRAINT fk_service_interests_owner
    FOREIGN KEY (follow_up_owner_person_id, organization_id)
    REFERENCES church.people(id, organization_id) ON DELETE SET NULL,

  CONSTRAINT chk_service_interests_level
    CHECK (interest_level IN ('low', 'medium', 'high')),
  -- SRV-002: the lifecycle the spec requires.
  CONSTRAINT chk_service_interests_status
    CHECK (status IN ('interested', 'contacted', 'placed', 'declined', 'closed')),
  CONSTRAINT uq_service_interests UNIQUE (person_id, ministry_id)
);

CREATE INDEX idx_service_interests_ministry_open
  ON church.person_service_interests(ministry_id)
  WHERE status IN ('interested', 'contacted');
CREATE INDEX idx_service_interests_person ON church.person_service_interests(person_id);
CREATE INDEX idx_service_interests_org ON church.person_service_interests(organization_id);

-- ---------------------------------------------------------------------------
-- Ministry name hygiene
-- ---------------------------------------------------------------------------
-- budget.ministries is now the master list for member service, so it can no
-- longer be allowed to grow a new row every time somebody mistypes their
-- ministry name on their profile. Aliases map known spellings to the real
-- ministry; anything unrecognised goes to a review queue for a human.
CREATE TABLE church.ministry_aliases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  alias TEXT NOT NULL,
  ministry_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT fk_ministry_aliases_ministry
    FOREIGN KEY (ministry_id, organization_id)
    REFERENCES budget.ministries(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT uq_ministry_aliases UNIQUE (organization_id, alias)
);

CREATE TABLE church.ministry_name_review_queue (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  raw_name TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'profile_sync',
  source_profile_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  occurrences INTEGER NOT NULL DEFAULT 1,
  resolved_at TIMESTAMPTZ,
  resolved_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  resolution TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_ministry_review_queue UNIQUE (organization_id, raw_name)
);

CREATE INDEX idx_ministry_review_queue_open
  ON church.ministry_name_review_queue(organization_id)
  WHERE resolved_at IS NULL;

-- Replaces the version from 20251225120000, which did:
--   INSERT INTO budget.ministries ... ON CONFLICT DO NOTHING
-- on every profile insert/update, creating a permanent ministry row from any
-- typo. Existing-ministry leader claiming is kept unchanged so the budget
-- module behaves as before; only the silent creation is removed.
CREATE OR REPLACE FUNCTION public.sync_ministry_from_profile()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, budget, church
AS $$
DECLARE
  _name TEXT;
  _ministry_id UUID;
BEGIN
  IF NEW.ministry_name IS NULL
     OR btrim(NEW.ministry_name) = ''
     OR NEW.default_organization_id IS NULL THEN
    RETURN NEW;
  END IF;

  _name := btrim(NEW.ministry_name);

  -- Exact (case-insensitive) match against the real ministry list.
  SELECT m.id INTO _ministry_id
  FROM budget.ministries m
  WHERE m.organization_id = NEW.default_organization_id
    AND lower(m.name) = lower(_name)
  LIMIT 1;

  -- Otherwise a known alias for it.
  IF _ministry_id IS NULL THEN
    SELECT a.ministry_id INTO _ministry_id
    FROM church.ministry_aliases a
    WHERE a.organization_id = NEW.default_organization_id
      AND lower(a.alias) = lower(_name)
    LIMIT 1;
  END IF;

  -- Unrecognised: queue it for a human instead of inventing a ministry.
  IF _ministry_id IS NULL THEN
    INSERT INTO church.ministry_name_review_queue
      (organization_id, raw_name, source, source_profile_id)
    VALUES (NEW.default_organization_id, _name, 'profile_sync', NEW.id)
    ON CONFLICT (organization_id, raw_name)
    DO UPDATE SET occurrences = church.ministry_name_review_queue.occurrences + 1;
    RETURN NEW;
  END IF;

  -- Unchanged from the previous behaviour: claim leadership of a ministry
  -- that has no leader yet.
  UPDATE budget.ministries
  SET leader_id = NEW.id
  WHERE id = _ministry_id AND leader_id IS NULL;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.sync_ministry_from_profile() IS
  'Links profiles.ministry_name to an existing budget.ministries row or an '
  'alias. Unrecognised names go to church.ministry_name_review_queue. No '
  'longer creates ministries from free text — budget.ministries is now the '
  'master list for member service assignments. See 20260320000500.';

-- ---------------------------------------------------------------------------
-- Triggers, RLS, grants
-- ---------------------------------------------------------------------------
CREATE TRIGGER update_church_ministry_assignments_updated_at
  BEFORE UPDATE ON church.ministry_assignments
  FOR EACH ROW EXECUTE FUNCTION church.update_updated_at_column();

CREATE TRIGGER update_church_person_service_interests_updated_at
  BEFORE UPDATE ON church.person_service_interests
  FOR EACH ROW EXECUTE FUNCTION church.update_updated_at_column();

ALTER TABLE church.ministry_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE church.person_service_interests ENABLE ROW LEVEL SECURITY;
ALTER TABLE church.ministry_aliases ENABLE ROW LEVEL SECURITY;
ALTER TABLE church.ministry_name_review_queue ENABLE ROW LEVEL SECURITY;

DO $rls$
DECLARE
  t TEXT;
  read_perms  TEXT := 'ARRAY[''members_admin'',''members_viewer'',''members_import'',''kids_admin'',''leadership_viewer'']::church.module_permission[]';
  write_perms TEXT := 'ARRAY[''members_admin'']::church.module_permission[]';
BEGIN
  FOREACH t IN ARRAY ARRAY['ministry_assignments', 'person_service_interests'] LOOP
    EXECUTE format(
      'CREATE POLICY "Authorized users can view %s"
         ON church.%I FOR SELECT TO authenticated
         USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(%s)))',
      t, t, read_perms);
    EXECUTE format(
      'CREATE POLICY "Membership admins can manage %s"
         ON church.%I FOR ALL TO authenticated
         USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(%s)))
         WITH CHECK (organization_id IN (SELECT * FROM church.my_orgs_with_any(%s)))',
      t, t, write_perms, write_perms);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON church.%I TO authenticated', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON church.%I TO service_role', t);
  END LOOP;

  -- Ministry name hygiene is an admin concern only.
  FOREACH t IN ARRAY ARRAY['ministry_aliases', 'ministry_name_review_queue'] LOOP
    EXECUTE format(
      'CREATE POLICY "Org members can view %s"
         ON church.%I FOR SELECT TO authenticated
         USING (organization_id IN (SELECT * FROM church.my_orgs()))', t, t);
    EXECUTE format(
      'CREATE POLICY "Org admins can manage %s"
         ON church.%I FOR ALL TO authenticated
         USING (organization_id IN (SELECT * FROM church.my_admin_orgs()))
         WITH CHECK (organization_id IN (SELECT * FROM church.my_admin_orgs()))', t, t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON church.%I TO authenticated', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON church.%I TO service_role', t);
  END LOOP;
END
$rls$;

NOTIFY pgrst, 'reload schema';
