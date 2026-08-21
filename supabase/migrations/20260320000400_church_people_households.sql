-- =====================================================
-- People, households, relationships
-- =====================================================
--
-- This introduces the first person-entity in the database that is NOT an
-- auth user. Until now every person here has been a login (public.profiles is
-- 1:1 with auth.users). Church members, and especially children, must exist
-- without ever being able to sign in.
--
-- BIRTHDAY POLICY
-- ---------------
-- birth_year + birth_month only. No day-of-month, for anybody, children
-- included. This overrides the source spec (which stored month+day and
-- forbade the year) at the church's explicit direction. The consequence is
-- that age is exact to the month and no finer: "birthdays this month" works,
-- "birthdays this week" is impossible and always will be.

-- ---------------------------------------------------------------------------
-- Households
-- ---------------------------------------------------------------------------
CREATE TABLE church.households (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  name TEXT NOT NULL,
  address_line1 TEXT,
  address_line2 TEXT,
  city TEXT,
  state TEXT,
  postal_code TEXT,
  country TEXT DEFAULT 'USA',
  primary_phone TEXT,
  notes TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_by_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Lets child tables carry a composite FK and so make a cross-branch
  -- reference structurally impossible rather than merely unlikely.
  CONSTRAINT uq_households_id_org UNIQUE (id, organization_id)
);

-- ---------------------------------------------------------------------------
-- People
-- ---------------------------------------------------------------------------
CREATE TABLE church.people (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,

  -- Human-facing stable identifier (spec: "One Member, One Member ID").
  -- Nullable because visitors and children are people before they are members.
  member_number TEXT,

  -- Optional link to a login. Most members never have one; some app users are
  -- also members. The FK points person -> profile, never the reverse, so a
  -- person can exist with no auth user at all.
  profile_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,

  first_name TEXT NOT NULL,
  middle_name TEXT,
  last_name TEXT NOT NULL,
  preferred_name TEXT,
  -- The landing site is already bilingual and Ethiopian naming does not
  -- survive a first-space split. Cheap to add now, a migration later.
  amharic_name TEXT,

  birth_year SMALLINT,
  birth_month SMALLINT,

  gender TEXT,
  marital_status TEXT,
  email TEXT,
  phone TEXT,

  membership_status_id UUID REFERENCES church.membership_statuses(id) ON DELETE SET NULL,
  member_since DATE,

  -- BO-05 discipleship information. Year/month only, matching the birthday
  -- policy, plus a marker for "we know roughly when, not exactly".
  accepted_lord_year SMALLINT,
  accepted_lord_month SMALLINT,
  accepted_lord_is_approximate BOOLEAN NOT NULL DEFAULT false,

  -- Kids Ministry eligibility is explicit, not inferred from age. A
  -- child-safety system must not silently age a 17-year-old out of check-in
  -- part-way through a year; a human decides, the UI suggests.
  is_child BOOLEAN NOT NULL DEFAULT false,
  school_grade_id UUID REFERENCES church.school_grades(id) ON DELETE SET NULL,

  photo_path TEXT,
  notes TEXT,

  is_active BOOLEAN NOT NULL DEFAULT true,
  inactive_reason TEXT,
  deceased BOOLEAN NOT NULL DEFAULT false,

  -- Duplicate resolution: never delete, point the loser at the winner.
  merged_into_person_id UUID REFERENCES church.people(id) ON DELETE SET NULL,

  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_by_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Normalised search keys, generated so they can never drift from the source
  -- columns the way an application-maintained copy would.
  search_name TEXT GENERATED ALWAYS AS (
    lower(trim(coalesce(first_name,'') || ' ' || coalesce(last_name,'')))
  ) STORED,
  phone_digits TEXT GENERATED ALWAYS AS (
    regexp_replace(coalesce(phone,''), '[^0-9]', '', 'g')
  ) STORED,

  CONSTRAINT uq_people_id_org UNIQUE (id, organization_id),
  CONSTRAINT uq_people_member_number UNIQUE (organization_id, member_number),
  CONSTRAINT chk_people_birth_month CHECK (birth_month IS NULL OR birth_month BETWEEN 1 AND 12),
  CONSTRAINT chk_people_birth_year CHECK (birth_year IS NULL OR birth_year BETWEEN 1900 AND 2100),
  -- A month without a year cannot be turned into an age, so it is not a
  -- partial record, it is an unusable one.
  CONSTRAINT chk_people_month_needs_year CHECK (birth_month IS NULL OR birth_year IS NOT NULL),
  CONSTRAINT chk_people_accepted_month CHECK (accepted_lord_month IS NULL OR accepted_lord_month BETWEEN 1 AND 12),
  CONSTRAINT chk_people_accepted_year CHECK (accepted_lord_year IS NULL OR accepted_lord_year BETWEEN 1900 AND 2100),
  CONSTRAINT chk_people_accepted_month_needs_year CHECK (accepted_lord_month IS NULL OR accepted_lord_year IS NOT NULL),
  CONSTRAINT chk_people_not_self_merge CHECK (merged_into_person_id IS NULL OR merged_into_person_id <> id),
  -- Classroom placement is impossible without a birthday, so a child record
  -- must carry one. Adults may decline to give theirs.
  CONSTRAINT chk_people_child_needs_birth CHECK (NOT is_child OR birth_year IS NOT NULL)
);

-- ---------------------------------------------------------------------------
-- Household membership, over time
-- ---------------------------------------------------------------------------
CREATE TABLE church.household_members (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  household_id UUID NOT NULL,
  person_id UUID NOT NULL,
  -- 'adult' | 'child' | 'other' — how this person sits in THIS household,
  -- which is not the same question as whether they are a child.
  household_role TEXT NOT NULL DEFAULT 'adult',
  is_primary_contact BOOLEAN NOT NULL DEFAULT false,
  is_primary_household BOOLEAN NOT NULL DEFAULT true,
  start_date DATE NOT NULL DEFAULT CURRENT_DATE,
  end_date DATE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Composite FKs: a person can only join a household in the same branch.
  CONSTRAINT fk_household_members_household
    FOREIGN KEY (household_id, organization_id)
    REFERENCES church.households(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT fk_household_members_person
    FOREIGN KEY (person_id, organization_id)
    REFERENCES church.people(id, organization_id) ON DELETE CASCADE,

  CONSTRAINT chk_household_members_dates CHECK (end_date IS NULL OR end_date >= start_date),
  -- The same person cannot be in the same household twice over overlapping
  -- periods. Ended memberships are retained, so history survives a move.
  CONSTRAINT no_overlapping_household_membership EXCLUDE USING gist (
    household_id WITH =,
    person_id WITH =,
    daterange(start_date, end_date, '[]') WITH &&
  )
);

-- Exactly one primary household per person at a time. A child living between
-- two households is a real case, so a second non-primary household is allowed.
CREATE UNIQUE INDEX uq_household_members_one_primary
  ON church.household_members(person_id)
  WHERE is_primary_household AND end_date IS NULL;

-- ---------------------------------------------------------------------------
-- Person-to-person relationships
-- ---------------------------------------------------------------------------
CREATE TABLE church.person_relationships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  person_id UUID NOT NULL,
  related_person_id UUID NOT NULL,
  relationship_type_id UUID NOT NULL REFERENCES church.relationship_types(id) ON DELETE RESTRICT,
  -- Set on rows written automatically as the inverse of another row, so the
  -- mirror trigger can tell its own writes from a human's.
  is_mirrored BOOLEAN NOT NULL DEFAULT false,
  start_date DATE,
  end_date DATE,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT fk_person_relationships_person
    FOREIGN KEY (person_id, organization_id)
    REFERENCES church.people(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT fk_person_relationships_related
    FOREIGN KEY (related_person_id, organization_id)
    REFERENCES church.people(id, organization_id) ON DELETE CASCADE,

  CONSTRAINT chk_person_relationships_not_self CHECK (person_id <> related_person_id),
  CONSTRAINT chk_person_relationships_dates CHECK (end_date IS NULL OR end_date >= start_date),
  CONSTRAINT uq_person_relationships UNIQUE (person_id, related_person_id, relationship_type_id)
);

-- ---------------------------------------------------------------------------
-- Sensitive child/member data — deliberately a SEPARATE table
-- ---------------------------------------------------------------------------
-- KID-025 requires medical notes, allergies and emergency contacts be visible
-- only to authorized users. Postgres RLS is row-level, not column-level, so
-- this cannot be done with a policy on church.people. Splitting it into its
-- own table makes the grant boundary explicit and auditable: a role either has
-- access to this table or it does not.
CREATE TABLE church.person_sensitive (
  person_id UUID PRIMARY KEY,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  allergy_severity TEXT NOT NULL DEFAULT 'none',
  allergies TEXT,
  -- Short, pre-approved text safe to print on a child's label. Never the raw
  -- free-text medical note: KID-009 allows an allergy indicator on the label,
  -- KID-010 forbids medical detail on the parent's.
  allergy_label_short TEXT,
  medications TEXT,
  medical_notes TEXT,
  special_needs TEXT,
  special_needs_flag BOOLEAN NOT NULL DEFAULT false,
  photo_consent BOOLEAN NOT NULL DEFAULT false,
  updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT fk_person_sensitive_person
    FOREIGN KEY (person_id, organization_id)
    REFERENCES church.people(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT chk_person_sensitive_severity
    CHECK (allergy_severity IN ('none', 'mild', 'severe', 'life_threatening')),
  -- A label fragment long enough to wrap will not fit a 62mm thermal label.
  CONSTRAINT chk_person_sensitive_label_len
    CHECK (allergy_label_short IS NULL OR char_length(allergy_label_short) <= 24)
);

CREATE TABLE church.person_emergency_contacts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  person_id UUID NOT NULL,
  name TEXT NOT NULL,
  relationship TEXT,
  phone TEXT NOT NULL,
  alt_phone TEXT,
  priority INTEGER NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT fk_person_emergency_contacts_person
    FOREIGN KEY (person_id, organization_id)
    REFERENCES church.people(id, organization_id) ON DELETE CASCADE
);

-- ---------------------------------------------------------------------------
-- Change history (application-written, matching budget.expense_history)
-- ---------------------------------------------------------------------------
CREATE TABLE church.people_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  person_id UUID NOT NULL REFERENCES church.people(id) ON DELETE CASCADE,
  action TEXT NOT NULL,
  field_name TEXT,
  old_value TEXT,
  new_value TEXT,
  actor_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  actor_name TEXT NOT NULL,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
CREATE INDEX idx_people_org ON church.people(organization_id);
CREATE INDEX idx_people_last_first ON church.people(organization_id, last_name, first_name);
CREATE INDEX idx_people_profile ON church.people(profile_id) WHERE profile_id IS NOT NULL;
CREATE INDEX idx_people_email ON church.people(organization_id, lower(email)) WHERE email IS NOT NULL;
-- Station lookup is by trailing digits of a phone number, so the index has to
-- support a suffix match; trigram handles LIKE '%1234'.
CREATE INDEX idx_people_phone_digits_trgm ON church.people
  USING gin (phone_digits extensions.gin_trgm_ops) WHERE phone_digits <> '';
CREATE INDEX idx_people_search_name_trgm ON church.people
  USING gin (search_name extensions.gin_trgm_ops);
CREATE INDEX idx_people_birth_month ON church.people(organization_id, birth_month)
  WHERE birth_month IS NOT NULL;
CREATE INDEX idx_people_children ON church.people(organization_id)
  WHERE is_child AND is_active AND merged_into_person_id IS NULL;
CREATE INDEX idx_people_membership_status ON church.people(membership_status_id);

CREATE INDEX idx_households_org ON church.households(organization_id);
CREATE INDEX idx_households_name_trgm ON church.households
  USING gin (lower(name) extensions.gin_trgm_ops);

CREATE INDEX idx_household_members_household ON church.household_members(household_id)
  WHERE end_date IS NULL;
CREATE INDEX idx_household_members_person ON church.household_members(person_id)
  WHERE end_date IS NULL;

CREATE INDEX idx_person_relationships_person ON church.person_relationships(person_id);
CREATE INDEX idx_person_relationships_related ON church.person_relationships(related_person_id);
CREATE INDEX idx_person_emergency_contacts_person ON church.person_emergency_contacts(person_id);
CREATE INDEX idx_people_history_person ON church.people_history(person_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- updated_at triggers
-- ---------------------------------------------------------------------------
DO $t$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'households', 'people', 'household_members', 'person_relationships',
    'person_sensitive', 'person_emergency_contacts'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER update_church_%s_updated_at
         BEFORE UPDATE ON church.%I
         FOR EACH ROW EXECUTE FUNCTION church.update_updated_at_column()', t, t);
  END LOOP;
END
$t$;

-- ---------------------------------------------------------------------------
-- Relationship mirroring
-- ---------------------------------------------------------------------------
-- Writing "A is parent of B" must imply "B is child of A", or every screen
-- that reads relationships has to remember to check both directions and one
-- of them eventually will not.
CREATE OR REPLACE FUNCTION church.mirror_person_relationship()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = church, public
AS $$
DECLARE
  _inverse_type_id UUID;
BEGIN
  -- Only mirror human-authored rows, otherwise the mirror mirrors the mirror.
  IF NEW.is_mirrored THEN
    RETURN NEW;
  END IF;

  SELECT inv.id INTO _inverse_type_id
  FROM church.relationship_types rt
  JOIN church.relationship_types inv
    ON inv.code = rt.inverse_code
   AND inv.organization_id = rt.organization_id
  WHERE rt.id = NEW.relationship_type_id;

  IF _inverse_type_id IS NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO church.person_relationships (
    organization_id, person_id, related_person_id, relationship_type_id,
    is_mirrored, start_date, end_date, notes
  )
  VALUES (
    NEW.organization_id, NEW.related_person_id, NEW.person_id, _inverse_type_id,
    true, NEW.start_date, NEW.end_date, NEW.notes
  )
  ON CONFLICT (person_id, related_person_id, relationship_type_id) DO NOTHING;

  RETURN NEW;
END;
$$;

CREATE TRIGGER mirror_person_relationship_on_insert
  AFTER INSERT ON church.person_relationships
  FOR EACH ROW EXECUTE FUNCTION church.mirror_person_relationship();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
ALTER TABLE church.households ENABLE ROW LEVEL SECURITY;
ALTER TABLE church.people ENABLE ROW LEVEL SECURITY;
ALTER TABLE church.household_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE church.person_relationships ENABLE ROW LEVEL SECURITY;
ALTER TABLE church.person_sensitive ENABLE ROW LEVEL SECURITY;
ALTER TABLE church.person_emergency_contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE church.people_history ENABLE ROW LEVEL SECURITY;

-- Directory read: any of the member-reading permissions. Note kids_volunteer
-- is absent by design — a station account must reach child data only through
-- the narrow, audited RPCs added in a later migration, never by table read.
DO $rls$
DECLARE
  t TEXT;
  read_perms  TEXT := 'ARRAY[''members_admin'',''members_viewer'',''members_import'',''kids_admin'',''leadership_viewer'']::church.module_permission[]';
  write_perms TEXT := 'ARRAY[''members_admin'',''members_import'']::church.module_permission[]';
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'households', 'people', 'household_members',
    'person_relationships', 'person_emergency_contacts'
  ] LOOP
    EXECUTE format(
      'CREATE POLICY "Authorized users can view %s"
         ON church.%I FOR SELECT TO authenticated
         USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(%s)))',
      t, t, read_perms);

    EXECUTE format(
      'CREATE POLICY "Membership admins can insert %s"
         ON church.%I FOR INSERT TO authenticated
         WITH CHECK (organization_id IN (SELECT * FROM church.my_orgs_with_any(%s)))',
      t, t, write_perms);

    EXECUTE format(
      'CREATE POLICY "Membership admins can update %s"
         ON church.%I FOR UPDATE TO authenticated
         USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(%s)))
         WITH CHECK (organization_id IN (SELECT * FROM church.my_orgs_with_any(%s)))',
      t, t, write_perms, write_perms);

    -- Deletion is org-admin only. SEC-004: members are deactivated, not
    -- deleted, so this exists for genuine mistakes rather than routine use.
    EXECUTE format(
      'CREATE POLICY "Org admins can delete %s"
         ON church.%I FOR DELETE TO authenticated
         USING (organization_id IN (SELECT * FROM church.my_admin_orgs()))',
      t, t);

    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON church.%I TO authenticated', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON church.%I TO service_role', t);
  END LOOP;
END
$rls$;

-- Sensitive data: a strictly narrower set of permissions, and no
-- leadership_viewer. Reporting access to the directory does not imply access
-- to a child's medical record.
CREATE POLICY "Authorized users can view sensitive person data"
  ON church.person_sensitive FOR SELECT TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['members_admin','kids_admin']::church.module_permission[])));

CREATE POLICY "Authorized users can write sensitive person data"
  ON church.person_sensitive FOR ALL TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['members_admin','kids_admin']::church.module_permission[])))
  WITH CHECK (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['members_admin','kids_admin']::church.module_permission[])));

GRANT SELECT, INSERT, UPDATE, DELETE ON church.person_sensitive TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.person_sensitive TO service_role;

-- History is append-only from the application's point of view: readable by
-- anyone who can read the directory, insertable with your own identity, and
-- never updatable or deletable by any client.
CREATE POLICY "Authorized users can view people history"
  ON church.people_history FOR SELECT TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['members_admin','members_viewer','kids_admin','leadership_viewer']::church.module_permission[])));

CREATE POLICY "Authenticated users can insert people history"
  ON church.people_history FOR INSERT TO authenticated
  WITH CHECK (actor_id = auth.uid());

GRANT SELECT, INSERT ON church.people_history TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.people_history TO service_role;

COMMENT ON TABLE church.people IS
  'One row per person. Not an auth user: profile_id is an optional link to a '
  'login. birth_year + birth_month only, no day-of-month, for everyone '
  'including children.';
COMMENT ON TABLE church.person_sensitive IS
  'Medical, allergy and consent data, split from church.people because RLS is '
  'row-level and KID-025 requires this be restricted independently of the '
  'directory.';

NOTIFY pgrst, 'reload schema';
