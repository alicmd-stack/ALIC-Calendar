-- =====================================================
-- Bible study / home cell groups, and the training catalog
-- =====================================================
--
-- SCOPE NOTE
-- ----------
-- Group participation is membership over time — role plus start/end dates —
-- exactly as spec 7.4 defines it ("Stored in GroupMembership with role, start
-- date, end date and status"). There is deliberately NO per-meeting attendance
-- table for home cells: the spec's two group reports (Bible Study / Home Cell
-- Roster, and Members Not in Bible Study) are both answerable from membership
-- alone, and meeting-level tracking would require cell leaders to have logins
-- and to record every week.
--
-- Training is different. TRN-004 explicitly requires recording attendance,
-- completion and credited hours per session, so training does get a real
-- attendance table.

-- ---------------------------------------------------------------------------
-- Groups
-- ---------------------------------------------------------------------------
CREATE TABLE church.groups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  code TEXT,
  name TEXT NOT NULL,
  group_type_id UUID NOT NULL REFERENCES church.group_types(id) ON DELETE RESTRICT,
  description TEXT,
  -- Optional owning ministry, e.g. a young-adults cell under Youth.
  ministry_id UUID,
  -- No leader_person_id column: spec 7.4 requires leaders be derived from
  -- membership roles, so that one person can lead several groups and a group
  -- can have co-leaders.
  meeting_day TEXT,
  meeting_time TIME,
  location TEXT,
  room_id UUID REFERENCES public.rooms(id) ON DELETE SET NULL,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_by_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT uq_groups_id_org UNIQUE (id, organization_id),
  CONSTRAINT uq_groups_org_name UNIQUE (organization_id, name),
  CONSTRAINT fk_groups_ministry
    FOREIGN KEY (ministry_id, organization_id)
    REFERENCES budget.ministries(id, organization_id) ON DELETE SET NULL,
  CONSTRAINT chk_groups_meeting_day CHECK (
    meeting_day IS NULL OR meeting_day IN
    ('monday','tuesday','wednesday','thursday','friday','saturday','sunday')
  )
);

CREATE TABLE church.group_memberships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  group_id UUID NOT NULL,
  person_id UUID NOT NULL,
  -- Reuses ministry_roles so "who leads this group" is the same query shape as
  -- "who leads this ministry", and GRP-004 (leaders as role assignments) falls
  -- out for free.
  role_id UUID NOT NULL REFERENCES church.ministry_roles(id) ON DELETE RESTRICT,
  start_date DATE NOT NULL DEFAULT CURRENT_DATE,
  end_date DATE,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT fk_group_memberships_group
    FOREIGN KEY (group_id, organization_id)
    REFERENCES church.groups(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT fk_group_memberships_person
    FOREIGN KEY (person_id, organization_id)
    REFERENCES church.people(id, organization_id) ON DELETE CASCADE,

  CONSTRAINT chk_group_memberships_dates CHECK (end_date IS NULL OR end_date >= start_date),
  -- One membership per person per group per period. Whether a member may
  -- belong to two groups at once is left open on purpose — the spec lists it
  -- as an undecided ALIC policy question, and nothing here forbids it.
  CONSTRAINT no_overlapping_group_membership EXCLUDE USING gist (
    group_id WITH =,
    person_id WITH =,
    daterange(start_date, end_date, '[]') WITH &&
  )
);

CREATE INDEX idx_groups_org ON church.groups(organization_id);
CREATE INDEX idx_group_memberships_group_active
  ON church.group_memberships(group_id, person_id) WHERE end_date IS NULL;
CREATE INDEX idx_group_memberships_person_active
  ON church.group_memberships(person_id) WHERE end_date IS NULL;

-- ---------------------------------------------------------------------------
-- Training catalog
-- ---------------------------------------------------------------------------
CREATE TABLE church.training_courses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  code TEXT,
  name TEXT NOT NULL,
  objective TEXT,
  category TEXT,
  default_duration_minutes INTEGER,
  ministry_id UUID,
  target_audience TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_by_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT uq_training_courses_id_org UNIQUE (id, organization_id),
  CONSTRAINT uq_training_courses_org_name UNIQUE (organization_id, name),
  CONSTRAINT fk_training_courses_ministry
    FOREIGN KEY (ministry_id, organization_id)
    REFERENCES budget.ministries(id, organization_id) ON DELETE SET NULL,
  CONSTRAINT chk_training_duration
    CHECK (default_duration_minutes IS NULL OR default_duration_minutes > 0)
);

CREATE TABLE church.training_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  training_course_id UUID NOT NULL,
  starts_at TIMESTAMPTZ NOT NULL,
  ends_at TIMESTAMPTZ,
  location TEXT,
  room_id UUID REFERENCES public.rooms(id) ON DELETE SET NULL,
  duration_minutes INTEGER,
  status TEXT NOT NULL DEFAULT 'scheduled',
  notes TEXT,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_by_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT uq_training_sessions_id_org UNIQUE (id, organization_id),
  CONSTRAINT fk_training_sessions_course
    FOREIGN KEY (training_course_id, organization_id)
    REFERENCES church.training_courses(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT chk_training_sessions_times CHECK (ends_at IS NULL OR ends_at > starts_at),
  CONSTRAINT chk_training_sessions_status
    CHECK (status IN ('scheduled', 'in_progress', 'completed', 'cancelled'))
);

-- Multiple instructors per session, including people who are not members.
CREATE TABLE church.training_instructors (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  training_session_id UUID NOT NULL,
  person_id UUID,
  external_instructor_name TEXT,
  instructor_role TEXT NOT NULL DEFAULT 'instructor',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT fk_training_instructors_session
    FOREIGN KEY (training_session_id, organization_id)
    REFERENCES church.training_sessions(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT fk_training_instructors_person
    FOREIGN KEY (person_id, organization_id)
    REFERENCES church.people(id, organization_id) ON DELETE SET NULL,
  -- An instructor is either one of our people or a named outsider, not neither.
  CONSTRAINT chk_training_instructor_identity
    CHECK (person_id IS NOT NULL OR external_instructor_name IS NOT NULL)
);

-- TRN-003: attendance links by person id, never by copied name.
CREATE TABLE church.training_attendance (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  training_session_id UUID NOT NULL,
  person_id UUID NOT NULL,
  attendance_status TEXT NOT NULL DEFAULT 'registered',
  completion_status TEXT,
  credited_minutes INTEGER,
  attended_on DATE,
  recorded_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  recorded_by_name TEXT,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT fk_training_attendance_session
    FOREIGN KEY (training_session_id, organization_id)
    REFERENCES church.training_sessions(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT fk_training_attendance_person
    FOREIGN KEY (person_id, organization_id)
    REFERENCES church.people(id, organization_id) ON DELETE CASCADE,

  -- Spec: UQ(TrainingSessionId, PersonId). TC-007 expects the second
  -- duplicate to be rejected by exactly this constraint.
  CONSTRAINT uq_training_attendance UNIQUE (training_session_id, person_id),
  CONSTRAINT chk_training_attendance_status
    CHECK (attendance_status IN ('registered', 'present', 'partial', 'absent', 'excused')),
  CONSTRAINT chk_training_completion_status
    CHECK (completion_status IS NULL OR completion_status IN ('completed', 'not_completed', 'in_progress')),
  CONSTRAINT chk_training_credited_minutes
    CHECK (credited_minutes IS NULL OR credited_minutes >= 0)
);

CREATE INDEX idx_training_courses_org ON church.training_courses(organization_id);
CREATE INDEX idx_training_sessions_course ON church.training_sessions(training_course_id, starts_at DESC);
CREATE INDEX idx_training_sessions_org_date ON church.training_sessions(organization_id, starts_at DESC);
CREATE INDEX idx_training_attendance_session ON church.training_attendance(training_session_id);
CREATE INDEX idx_training_attendance_person ON church.training_attendance(person_id);
CREATE INDEX idx_training_instructors_session ON church.training_instructors(training_session_id);

-- ---------------------------------------------------------------------------
-- Triggers, RLS, grants
-- ---------------------------------------------------------------------------
DO $t$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'groups', 'group_memberships', 'training_courses',
    'training_sessions', 'training_attendance'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER update_church_%s_updated_at
         BEFORE UPDATE ON church.%I
         FOR EACH ROW EXECUTE FUNCTION church.update_updated_at_column()', t, t);
  END LOOP;
END
$t$;

DO $rls$
DECLARE
  t TEXT;
  read_perms  TEXT := 'ARRAY[''members_admin'',''members_viewer'',''members_import'',''kids_admin'',''leadership_viewer'']::church.module_permission[]';
  write_perms TEXT := 'ARRAY[''members_admin'']::church.module_permission[]';
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'groups', 'group_memberships', 'training_courses', 'training_sessions',
    'training_instructors', 'training_attendance'
  ] LOOP
    EXECUTE format('ALTER TABLE church.%I ENABLE ROW LEVEL SECURITY', t);

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
END
$rls$;

COMMENT ON TABLE church.group_memberships IS
  'Home cell / Bible study participation as dated membership with a role. '
  'There is no per-meeting attendance table by design — see the scope note at '
  'the top of migration 20260320000600.';

NOTIFY pgrst, 'reload schema';
