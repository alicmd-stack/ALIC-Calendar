-- =====================================================
-- Kids Ministry: classrooms, events, sessions, staffing
-- =====================================================
--
-- Classrooms are existing public.rooms rows (Shine class, Joy class A/B,
-- Blossom class A/B ...) with Kids-specific configuration attached, rather
-- than a second parallel room list. The configuration lives in its OWN table
-- and not as columns on public.rooms, because rooms carries this policy:
--
--   CREATE POLICY "Public can view active rooms" ON public.rooms
--     FOR SELECT TO anon USING (is_active = true);
--
-- Anything added to public.rooms is therefore world-readable for the public
-- calendar. Capacity would be harmless; ratios, label text and which rooms
-- hold children are not things to publish.

-- Required for the composite FKs below, which make it structurally impossible
-- to open an MD classroom inside a VA session.
ALTER TABLE public.rooms
  ADD CONSTRAINT uq_rooms_id_org UNIQUE (id, organization_id);

-- ---------------------------------------------------------------------------
-- Kids configuration for a room
-- ---------------------------------------------------------------------------
CREATE TABLE church.room_kids_config (
  room_id UUID PRIMARY KEY REFERENCES public.rooms(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL,
  is_checkin_location BOOLEAN NOT NULL DEFAULT true,
  kids_age_band_id UUID REFERENCES church.kids_age_bands(id) ON DELETE SET NULL,
  school_grade_id UUID REFERENCES church.school_grades(id) ON DELETE SET NULL,
  capacity INTEGER,
  -- Advisory only. A ratio breach warns loudly; it never blocks a check-in,
  -- because a church cannot turn a child away at the door.
  ratio_children_per_volunteer INTEGER,
  -- Short room name for a 62mm thermal label, where "Youth/True Vine worship
  -- Room" will not fit.
  label_room_name TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT uq_room_kids_config_room_org UNIQUE (room_id, organization_id),
  CONSTRAINT fk_room_kids_config_room
    FOREIGN KEY (room_id, organization_id)
    REFERENCES public.rooms(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT chk_room_kids_capacity CHECK (capacity IS NULL OR capacity > 0),
  CONSTRAINT chk_room_kids_ratio
    CHECK (ratio_children_per_volunteer IS NULL OR ratio_children_per_volunteer > 0),
  CONSTRAINT chk_room_kids_label_len
    CHECK (label_room_name IS NULL OR char_length(label_room_name) <= 20)
);

-- ---------------------------------------------------------------------------
-- Events and sessions
-- ---------------------------------------------------------------------------
-- An event is a recurring programme (Sunday Kids Ministry, VBS, a conference);
-- a session is one dated service time under it.
CREATE TABLE church.kids_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  name TEXT NOT NULL,
  event_type TEXT NOT NULL DEFAULT 'weekly_service',
  description TEXT,
  -- How far either side of a session check-in is permitted. Enforced in the
  -- RPC rather than a CHECK, because it depends on now().
  check_in_opens_minutes_before INTEGER NOT NULL DEFAULT 45,
  check_in_closes_minutes_after INTEGER NOT NULL DEFAULT 30,
  -- Backstop for children never checked out because a volunteer forgot. These
  -- rows are marked 'expired', which is a data-hygiene action and explicitly
  -- NOT a claim that the child was collected.
  auto_expire_minutes_after_end INTEGER NOT NULL DEFAULT 240,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_by_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT uq_kids_events_id_org UNIQUE (id, organization_id),
  CONSTRAINT chk_kids_events_type
    CHECK (event_type IN ('weekly_service', 'vbs', 'conference', 'special_event')),
  CONSTRAINT chk_kids_events_windows CHECK (
    check_in_opens_minutes_before >= 0
    AND check_in_closes_minutes_after >= 0
    AND auto_expire_minutes_after_end > 0
  )
);

CREATE TABLE church.kids_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  kids_event_id UUID NOT NULL,
  session_date DATE NOT NULL,
  starts_at TIMESTAMPTZ NOT NULL,
  ends_at TIMESTAMPTZ NOT NULL,
  service_label TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'scheduled',
  -- Monotonic per-session counter for the short room tag printed on the child
  -- label. Allocated by UPDATE ... RETURNING inside the check-in RPC, so two
  -- stations cannot hand out the same tag.
  next_tag_number INTEGER NOT NULL DEFAULT 1000,
  opened_at TIMESTAMPTZ,
  closed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT uq_kids_sessions_id_org UNIQUE (id, organization_id),
  CONSTRAINT fk_kids_sessions_event
    FOREIGN KEY (kids_event_id, organization_id)
    REFERENCES church.kids_events(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT chk_kids_sessions_times CHECK (ends_at > starts_at),
  CONSTRAINT chk_kids_sessions_status
    CHECK (status IN ('scheduled', 'open', 'closed', 'cancelled')),
  CONSTRAINT uq_kids_sessions_event_label UNIQUE (kids_event_id, session_date, service_label)
);

-- Which classrooms are open for a given session.
CREATE TABLE church.kids_session_rooms (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  kids_session_id UUID NOT NULL,
  room_id UUID NOT NULL,
  capacity_override INTEGER,
  is_open BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT fk_kids_session_rooms_session
    FOREIGN KEY (kids_session_id, organization_id)
    REFERENCES church.kids_sessions(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT fk_kids_session_rooms_room
    FOREIGN KEY (room_id, organization_id)
    REFERENCES public.rooms(id, organization_id) ON DELETE RESTRICT,
  CONSTRAINT chk_kids_session_rooms_capacity
    CHECK (capacity_override IS NULL OR capacity_override > 0),
  -- Target of the composite FK on kids_check_ins, so a check-in can only name
  -- a room that was actually opened for that session.
  CONSTRAINT uq_kids_session_rooms UNIQUE (kids_session_id, room_id)
);

-- KID-023: volunteers check in too, and are associated with a classroom.
CREATE TABLE church.kids_session_staffing (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  kids_session_id UUID NOT NULL,
  room_id UUID,
  person_id UUID NOT NULL,
  role TEXT NOT NULL DEFAULT 'classroom_volunteer',
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at TIMESTAMPTZ,
  -- Snapshot of eligibility at the moment of check-in. Kept on the row so a
  -- later background-check renewal cannot retroactively rewrite whether the
  -- room was properly staffed that Sunday.
  was_background_check_current BOOLEAN,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT fk_kids_staffing_session
    FOREIGN KEY (kids_session_id, organization_id)
    REFERENCES church.kids_sessions(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT fk_kids_staffing_person
    FOREIGN KEY (person_id, organization_id)
    REFERENCES church.people(id, organization_id) ON DELETE RESTRICT,
  CONSTRAINT chk_kids_staffing_times CHECK (ended_at IS NULL OR ended_at >= started_at),
  CONSTRAINT chk_kids_staffing_role
    CHECK (role IN ('classroom_volunteer', 'room_lead', 'floater', 'check_in_desk'))
);

-- One active shift per volunteer per session.
CREATE UNIQUE INDEX uq_kids_staffing_one_active
  ON church.kids_session_staffing(kids_session_id, person_id)
  WHERE ended_at IS NULL;

CREATE INDEX idx_kids_events_org ON church.kids_events(organization_id);
CREATE INDEX idx_kids_sessions_org_date ON church.kids_sessions(organization_id, session_date DESC);
CREATE INDEX idx_kids_sessions_open ON church.kids_sessions(organization_id)
  WHERE status = 'open';
CREATE INDEX idx_kids_session_rooms_session ON church.kids_session_rooms(kids_session_id);
CREATE INDEX idx_kids_staffing_session_room
  ON church.kids_session_staffing(kids_session_id, room_id) WHERE ended_at IS NULL;

-- ---------------------------------------------------------------------------
-- Triggers, RLS, grants
-- ---------------------------------------------------------------------------
DO $t$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'room_kids_config', 'kids_events', 'kids_sessions',
    'kids_session_rooms', 'kids_session_staffing'
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
  read_perms  TEXT := 'ARRAY[''kids_admin'',''kids_volunteer'',''leadership_viewer'']::church.module_permission[]';
  write_perms TEXT := 'ARRAY[''kids_admin'']::church.module_permission[]';
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'room_kids_config', 'kids_events', 'kids_sessions',
    'kids_session_rooms', 'kids_session_staffing'
  ] LOOP
    EXECUTE format('ALTER TABLE church.%I ENABLE ROW LEVEL SECURITY', t);

    -- kids_volunteer CAN read this layer: a station needs to know which
    -- sessions are open and which rooms accept children. None of it is
    -- personal data. Reading about actual children is a different matter and
    -- goes through audited RPCs only.
    EXECUTE format(
      'CREATE POLICY "Kids team can view %s"
         ON church.%I FOR SELECT TO authenticated
         USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(%s)))',
      t, t, read_perms);

    EXECUTE format(
      'CREATE POLICY "Kids admins can manage %s"
         ON church.%I FOR ALL TO authenticated
         USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(%s)))
         WITH CHECK (organization_id IN (SELECT * FROM church.my_orgs_with_any(%s)))',
      t, t, write_perms, write_perms);

    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON church.%I TO authenticated', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON church.%I TO service_role', t);
  END LOOP;
END
$rls$;

COMMENT ON TABLE church.room_kids_config IS
  'Kids-specific configuration for a public.rooms row. Separate table because '
  'public.rooms is readable by anon for the public calendar.';
COMMENT ON COLUMN church.kids_sessions.next_tag_number IS
  'Per-session counter for the short room tag on the child label. Allocated '
  'via UPDATE ... RETURNING so concurrent stations cannot collide.';

NOTIFY pgrst, 'reload schema';
