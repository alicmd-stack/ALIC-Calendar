-- =====================================================
-- Controlled reference data for the church schema
-- =====================================================
--
-- These are TABLES rather than Postgres enums on purpose. The spec's
-- maintainability requirement is that "ministries, roles, group types, age
-- brackets and statuses should be configuration/data-driven rather than
-- hard-coded", and an enum change requires a migration whereas a church
-- administrator needs to be able to rename a class or add a membership status
-- without a deploy.
--
-- Every table is organization-scoped, so Silver Spring and Springfield can
-- diverge (they already have different classrooms and will have different
-- age bands).

-- ---------------------------------------------------------------------------
-- Membership status  (Visitor / Regular Attendee / Member / Inactive / ...)
-- ---------------------------------------------------------------------------
CREATE TABLE church.membership_statuses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  display_name TEXT NOT NULL,
  description TEXT,
  -- Drives the "Active Members" KPI. Which statuses count as active is an
  -- ALIC policy decision, so it is data, not a hard-coded list.
  counts_as_active BOOLEAN NOT NULL DEFAULT false,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_membership_statuses_org_code UNIQUE (organization_id, code)
);

-- ---------------------------------------------------------------------------
-- Kids age bands
-- ---------------------------------------------------------------------------
-- Age is derived from birth_year + birth_month, so bands are expressed in
-- WHOLE MONTHS. Ranges are half-open [min, max): a band 0..24 covers a child
-- from birth up to but not including their 24th month.
CREATE TABLE church.kids_age_bands (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  display_name TEXT NOT NULL,
  min_age_months INTEGER NOT NULL,
  max_age_months INTEGER NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_kids_age_bands_org_code UNIQUE (organization_id, code),
  CONSTRAINT chk_kids_age_bands_range CHECK (max_age_months > min_age_months),
  CONSTRAINT chk_kids_age_bands_nonneg CHECK (min_age_months >= 0),
  -- Two active bands must never claim the same month, or classroom
  -- auto-suggestion becomes non-deterministic and a child could be placed in
  -- a different room on different Sundays. Enforced in the database because
  -- it is exactly the kind of thing hand-editing reference data gets wrong.
  CONSTRAINT no_overlapping_active_age_bands EXCLUDE USING gist (
    organization_id WITH =,
    int4range(min_age_months, max_age_months) WITH &&
  ) WHERE (is_active)
);

-- ---------------------------------------------------------------------------
-- School grades (Pre-K .. 12) — used for classroom placement alongside bands
-- ---------------------------------------------------------------------------
CREATE TABLE church.school_grades (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  display_name TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_school_grades_org_code UNIQUE (organization_id, code)
);

-- ---------------------------------------------------------------------------
-- Relationship types (parent / guardian / spouse / sibling / ...)
-- ---------------------------------------------------------------------------
-- `inverse_code` lets a single stored edge be mirrored automatically: writing
-- "A is parent of B" implies "B is child of A". Without it, every UI would
-- have to remember to write both directions, and half of them would forget.
CREATE TABLE church.relationship_types (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  display_name TEXT NOT NULL,
  inverse_code TEXT NOT NULL,
  -- Whether this relationship, by itself, implies authority to collect a
  -- child from Kids Ministry. Guardianship still has to be granted explicitly
  -- in kids_pickup_authorizations; this only drives sensible defaults.
  implies_guardianship BOOLEAN NOT NULL DEFAULT false,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_relationship_types_org_code UNIQUE (organization_id, code)
);

-- ---------------------------------------------------------------------------
-- Ministry roles (Leader / Co-Leader / Coordinator / Minister / Volunteer)
-- ---------------------------------------------------------------------------
-- BR-09: leadership reports filter on is_leadership_role rather than assuming
-- every ministry member is a leader. The "who counts as a minister?" question
-- is explicitly listed in the spec as an ALIC decision, so is_serving_role is
-- data too — changing it changes the Unique Serving Members KPI.
CREATE TABLE church.ministry_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  display_name TEXT NOT NULL,
  is_leadership_role BOOLEAN NOT NULL DEFAULT false,
  is_serving_role BOOLEAN NOT NULL DEFAULT true,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_ministry_roles_org_code UNIQUE (organization_id, code)
);

-- ---------------------------------------------------------------------------
-- Group types (Bible Study / Home Cell / Discipleship Group)
-- ---------------------------------------------------------------------------
CREATE TABLE church.group_types (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  display_name TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_group_types_org_code UNIQUE (organization_id, code)
);

-- ---------------------------------------------------------------------------
-- Indexes, triggers, RLS
-- ---------------------------------------------------------------------------
CREATE INDEX idx_membership_statuses_org ON church.membership_statuses(organization_id);
CREATE INDEX idx_kids_age_bands_org ON church.kids_age_bands(organization_id);
CREATE INDEX idx_school_grades_org ON church.school_grades(organization_id);
CREATE INDEX idx_relationship_types_org ON church.relationship_types(organization_id);
CREATE INDEX idx_ministry_roles_org ON church.ministry_roles(organization_id);
CREATE INDEX idx_group_types_org ON church.group_types(organization_id);

-- Reference tables all share the same shape: readable by any member of the
-- organization, writable only by an org admin. Applied in a loop so the six
-- tables cannot drift apart.
DO $ref$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'membership_statuses', 'kids_age_bands', 'school_grades',
    'relationship_types', 'ministry_roles', 'group_types'
  ] LOOP
    EXECUTE format('ALTER TABLE church.%I ENABLE ROW LEVEL SECURITY', t);

    EXECUTE format(
      'CREATE TRIGGER update_church_%s_updated_at
         BEFORE UPDATE ON church.%I
         FOR EACH ROW EXECUTE FUNCTION church.update_updated_at_column()', t, t);

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
$ref$;

-- ---------------------------------------------------------------------------
-- Age helpers
-- ---------------------------------------------------------------------------
-- Age in whole months from birth_year + birth_month. Day-of-month is not
-- collected (product decision), so this is exact to the month and no finer.
-- IMMUTABLE so it can be used in indexes and generated columns.
CREATE OR REPLACE FUNCTION church.age_in_months(
  _birth_year SMALLINT,
  _birth_month SMALLINT,
  _as_of DATE
)
RETURNS INTEGER
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN _birth_year IS NULL OR _birth_month IS NULL THEN NULL
    ELSE (EXTRACT(YEAR FROM _as_of)::INTEGER * 12 + EXTRACT(MONTH FROM _as_of)::INTEGER)
       - (_birth_year::INTEGER * 12 + _birth_month::INTEGER)
  END
$$;

-- Whole years, for display and the adult age-group report.
CREATE OR REPLACE FUNCTION church.age_years(
  _birth_year SMALLINT,
  _birth_month SMALLINT,
  _as_of DATE DEFAULT CURRENT_DATE
)
RETURNS INTEGER
LANGUAGE sql IMMUTABLE
AS $$
  SELECT church.age_in_months(_birth_year, _birth_month, _as_of) / 12
$$;

-- The age band a child falls into for a given organization on a given date.
-- Returns NULL when the birthday is unknown or no band matches, and the
-- caller must then require a volunteer to place the child by hand rather than
-- guessing.
CREATE OR REPLACE FUNCTION church.age_band_for(
  _organization_id UUID,
  _birth_year SMALLINT,
  _birth_month SMALLINT,
  _as_of DATE DEFAULT CURRENT_DATE
)
RETURNS UUID
LANGUAGE sql STABLE
SET search_path = church, public
AS $$
  SELECT b.id
  FROM church.kids_age_bands b
  WHERE b.organization_id = _organization_id
    AND b.is_active
    AND church.age_in_months(_birth_year, _birth_month, _as_of)
        >= b.min_age_months
    AND church.age_in_months(_birth_year, _birth_month, _as_of)
        <  b.max_age_months
  ORDER BY b.sort_order
  LIMIT 1
$$;

GRANT EXECUTE ON FUNCTION church.age_in_months(SMALLINT, SMALLINT, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION church.age_years(SMALLINT, SMALLINT, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION church.age_band_for(UUID, SMALLINT, SMALLINT, DATE) TO authenticated;

-- ---------------------------------------------------------------------------
-- Seed both branches
-- ---------------------------------------------------------------------------
-- Age band boundaries are a STARTING POINT ONLY and must be reviewed with the
-- Kids Ministry director before go-live: they decide which classroom a child
-- is sent to. The room names they map to (Shine class, Joy class A/B, Blossom
-- class A/B) already exist in public.rooms for the MD branch.
INSERT INTO church.membership_statuses
  (organization_id, code, display_name, counts_as_active, sort_order)
SELECT o.id, v.code, v.display_name, v.counts_as_active, v.sort_order
FROM public.organizations o
CROSS JOIN (VALUES
  ('visitor',          'Visitor',          false, 10),
  ('regular_attendee', 'Regular Attendee', true,  20),
  ('member',           'Member',           true,  30),
  ('inactive',         'Inactive',         false, 40),
  ('moved',            'Moved',            false, 50),
  ('deceased',         'Deceased',         false, 60)
) AS v(code, display_name, counts_as_active, sort_order)
ON CONFLICT (organization_id, code) DO NOTHING;

INSERT INTO church.kids_age_bands
  (organization_id, code, display_name, min_age_months, max_age_months, sort_order)
SELECT o.id, v.code, v.display_name, v.min_age_months, v.max_age_months, v.sort_order
FROM public.organizations o
CROSS JOIN (VALUES
  ('nursery',     'Nursery (0-2)',        0,   36,  10),
  ('preschool',   'Pre-K (3-4)',          36,  60,  20),
  ('elementary',  'Elementary (5-10)',    60,  132, 30),
  ('preteen',     'Preteen (11-12)',      132, 156, 40),
  ('youth',       'Youth (13-17)',        156, 216, 50)
) AS v(code, display_name, min_age_months, max_age_months, sort_order)
ON CONFLICT (organization_id, code) DO NOTHING;

INSERT INTO church.school_grades (organization_id, code, display_name, sort_order)
SELECT o.id, v.code, v.display_name, v.sort_order
FROM public.organizations o
CROSS JOIN (VALUES
  ('prek', 'Pre-K',      10), ('k',  'Kindergarten', 20),
  ('g1',   'Grade 1',    30), ('g2', 'Grade 2',      40),
  ('g3',   'Grade 3',    50), ('g4', 'Grade 4',      60),
  ('g5',   'Grade 5',    70), ('g6', 'Grade 6',      80),
  ('g7',   'Grade 7',    90), ('g8', 'Grade 8',     100),
  ('g9',   'Grade 9',   110), ('g10','Grade 10',    120),
  ('g11',  'Grade 11',  130), ('g12','Grade 12',    140)
) AS v(code, display_name, sort_order)
ON CONFLICT (organization_id, code) DO NOTHING;

INSERT INTO church.relationship_types
  (organization_id, code, display_name, inverse_code, implies_guardianship, sort_order)
SELECT o.id, v.code, v.display_name, v.inverse_code, v.implies_guardianship, v.sort_order
FROM public.organizations o
CROSS JOIN (VALUES
  ('parent',      'Parent',      'child',       true,  10),
  ('child',       'Child',       'parent',      false, 20),
  ('guardian',    'Guardian',    'ward',        true,  30),
  ('ward',        'Ward',        'guardian',    false, 40),
  ('spouse',      'Spouse',      'spouse',      false, 50),
  ('sibling',     'Sibling',     'sibling',     false, 60),
  ('grandparent', 'Grandparent', 'grandchild',  false, 70),
  ('grandchild',  'Grandchild',  'grandparent', false, 80),
  ('other',       'Other',       'other',       false, 90)
) AS v(code, display_name, inverse_code, implies_guardianship, sort_order)
ON CONFLICT (organization_id, code) DO NOTHING;

INSERT INTO church.ministry_roles
  (organization_id, code, display_name, is_leadership_role, is_serving_role, sort_order)
SELECT o.id, v.code, v.display_name, v.is_leadership_role, v.is_serving_role, v.sort_order
FROM public.organizations o
CROSS JOIN (VALUES
  ('leader',      'Leader',      true,  true, 10),
  ('co_leader',   'Co-Leader',   true,  true, 20),
  ('coordinator', 'Coordinator', true,  true, 30),
  ('minister',    'Minister',    false, true, 40),
  ('volunteer',   'Volunteer',   false, true, 50),
  ('member',      'Member',      false, true, 60)
) AS v(code, display_name, is_leadership_role, is_serving_role, sort_order)
ON CONFLICT (organization_id, code) DO NOTHING;

INSERT INTO church.group_types (organization_id, code, display_name, sort_order)
SELECT o.id, v.code, v.display_name, v.sort_order
FROM public.organizations o
CROSS JOIN (VALUES
  ('home_cell',          'Home Cell',          10),
  ('bible_study',        'Bible Study',        20),
  ('discipleship_group', 'Discipleship Group', 30)
) AS v(code, display_name, sort_order)
ON CONFLICT (organization_id, code) DO NOTHING;

COMMENT ON TABLE church.kids_age_bands IS
  'Age bands in whole months, half-open [min, max). Seeded boundaries are a '
  'starting point and MUST be reviewed with the Kids Ministry director before '
  'go-live — they determine which classroom a child is sent to.';

NOTIFY pgrst, 'reload schema';
