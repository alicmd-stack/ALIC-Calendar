-- =====================================================
-- Kids Ministry: check-in batches, check-ins, pickup credentials, audit
-- =====================================================
--
-- TWO SEPARATE CREDENTIAL NAMESPACES
-- ----------------------------------
-- The child's label carries a short per-session TAG (room identification, on
-- the roster, at the classroom door). It authorises nothing.
--
-- The parent's label carries the PICKUP CODE and a QR token. Those authorise
-- release. They are deliberately different values, so that seeing a child —
-- or a dropped child label — tells you nothing about how to collect them.
--
-- Both pickup credentials are stored only as keyed hashes. The raw values
-- exist on paper and in the tablet's memory, never in the database.

-- ---------------------------------------------------------------------------
-- Crypto configuration.  VAULT — granted to nobody.
-- ---------------------------------------------------------------------------
-- The pickup code has to be *found* by the value a parent presents at
-- checkout, which rules out a per-row salt (you cannot look up a bcrypt hash).
-- Instead it is HMAC'd with a server-side pepper: deterministic, therefore
-- indexable, while a database dump on its own still yields no usable code.
CREATE TABLE church.crypto_config (
  id BOOLEAN PRIMARY KEY DEFAULT true,
  pickup_pepper BYTEA NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_crypto_config_singleton CHECK (id)
);

INSERT INTO church.crypto_config (id, pickup_pepper)
VALUES (true, extensions.gen_random_bytes(32))
ON CONFLICT (id) DO NOTHING;

REVOKE ALL ON church.crypto_config FROM PUBLIC, anon, authenticated;
ALTER TABLE church.crypto_config ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- Check-in batches (one per family transaction)
-- ---------------------------------------------------------------------------
-- KID-007 allows the security code to cover a family batch. One code per
-- family, not per child: a parent collecting three children should not have
-- to present three different codes.
CREATE TABLE church.kids_check_in_batches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  kids_session_id UUID NOT NULL,
  household_id UUID,
  -- Idempotency key from the station. If the response to a check-in is lost
  -- and the tablet retries, the retry must return the ORIGINAL batch and code
  -- rather than checking the children in a second time under a second code.
  client_batch_key TEXT,
  status TEXT NOT NULL DEFAULT 'active',
  created_by_station_id UUID REFERENCES church.check_in_stations(id) ON DELETE SET NULL,
  created_by_volunteer_id UUID REFERENCES church.kids_volunteers(id) ON DELETE SET NULL,
  created_by_name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT uq_kids_batches_id_org UNIQUE (id, organization_id),
  CONSTRAINT fk_kids_batches_session
    FOREIGN KEY (kids_session_id, organization_id)
    REFERENCES church.kids_sessions(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT fk_kids_batches_household
    FOREIGN KEY (household_id, organization_id)
    REFERENCES church.households(id, organization_id) ON DELETE SET NULL,
  CONSTRAINT chk_kids_batches_status CHECK (status IN ('active', 'closed', 'expired')),
  CONSTRAINT uq_kids_batches_client_key UNIQUE (kids_session_id, client_batch_key)
);

-- ---------------------------------------------------------------------------
-- VAULT: pickup credentials.  Granted to nobody.
-- ---------------------------------------------------------------------------
CREATE TABLE church.kids_check_in_secrets (
  batch_id UUID PRIMARY KEY
    REFERENCES church.kids_check_in_batches(id) ON DELETE CASCADE,
  kids_session_id UUID NOT NULL,
  -- HMAC-SHA256(code, pepper). Short human-readable code, read aloud and
  -- hand-written, so the alphabet excludes ambiguous glyphs.
  code_hash BYTEA NOT NULL,
  -- HMAC-SHA256(token, pepper). Long random value encoded in the QR.
  token_hash BYTEA NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  locked_until TIMESTAMPTZ,
  consumed_at TIMESTAMPTZ,
  rotated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- A live code must be unique within a session, or one family's code could
-- release another family's children.
CREATE UNIQUE INDEX uq_kids_secrets_code_live
  ON church.kids_check_in_secrets(kids_session_id, code_hash)
  WHERE consumed_at IS NULL;
CREATE UNIQUE INDEX uq_kids_secrets_token_live
  ON church.kids_check_in_secrets(kids_session_id, token_hash)
  WHERE consumed_at IS NULL;

REVOKE ALL ON church.kids_check_in_secrets FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.kids_check_in_secrets TO service_role;
ALTER TABLE church.kids_check_in_secrets ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- Check-ins
-- ---------------------------------------------------------------------------
CREATE TABLE church.kids_check_ins (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  batch_id UUID NOT NULL REFERENCES church.kids_check_in_batches(id) ON DELETE CASCADE,
  kids_session_id UUID NOT NULL,
  child_person_id UUID NOT NULL,
  room_id UUID NOT NULL,
  household_id UUID,

  status TEXT NOT NULL DEFAULT 'checked_in',
  tag_number INTEGER NOT NULL,

  -- Snapshot of what was printed. Kept on the row so the roster never has to
  -- join to person_sensitive, and so a later edit to a child's record cannot
  -- rewrite what the label said that morning.
  label_child_name TEXT NOT NULL,
  label_room_name TEXT,
  label_age_band_code TEXT,
  label_allergy_flag BOOLEAN NOT NULL DEFAULT false,
  -- Pre-approved short text only. Never the raw medical note.
  label_allergy_short TEXT,
  label_special_needs_flag BOOLEAN NOT NULL DEFAULT false,
  -- Denormalised so the classroom roster can show a discreet marker without
  -- reading the restriction table.
  has_pickup_restriction BOOLEAN NOT NULL DEFAULT false,

  checked_in_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  checked_in_by_station_id UUID REFERENCES church.check_in_stations(id) ON DELETE SET NULL,
  checked_in_by_volunteer_id UUID REFERENCES church.kids_volunteers(id) ON DELETE SET NULL,
  checked_in_by_name TEXT NOT NULL,
  dropped_off_by_person_id UUID,

  checked_out_at TIMESTAMPTZ,
  checked_out_by_station_id UUID REFERENCES church.check_in_stations(id) ON DELETE SET NULL,
  checked_out_by_volunteer_id UUID REFERENCES church.kids_volunteers(id) ON DELETE SET NULL,
  checked_out_by_name TEXT,
  picked_up_by_person_id UUID,
  picked_up_by_name TEXT,
  checkout_method TEXT,
  override_reason TEXT,
  override_verification TEXT,
  override_authorized_by_volunteer_id UUID
    REFERENCES church.kids_volunteers(id) ON DELETE SET NULL,

  assignment_reason TEXT,
  today_note TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT fk_kids_check_ins_session
    FOREIGN KEY (kids_session_id, organization_id)
    REFERENCES church.kids_sessions(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT fk_kids_check_ins_child
    FOREIGN KEY (child_person_id, organization_id)
    REFERENCES church.people(id, organization_id) ON DELETE RESTRICT,
  -- A check-in can only name a room that was actually OPENED for this
  -- session. Structural, so no code path can put a child in a closed room.
  CONSTRAINT fk_kids_check_ins_session_room
    FOREIGN KEY (kids_session_id, room_id)
    REFERENCES church.kids_session_rooms(kids_session_id, room_id) ON DELETE RESTRICT,

  CONSTRAINT chk_kids_check_ins_status
    CHECK (status IN ('checked_in', 'checked_out', 'expired')),
  CONSTRAINT chk_kids_check_ins_times
    CHECK (checked_out_at IS NULL OR checked_out_at >= checked_in_at),
  CONSTRAINT chk_kids_check_ins_method
    CHECK (checkout_method IS NULL OR checkout_method IN
      ('qr', 'security_code', 'operator_override', 'system_auto')),
  -- A checked-out row must say when and how.
  CONSTRAINT chk_kids_check_ins_checkout_complete CHECK (
    status <> 'checked_out'
    OR (checked_out_at IS NOT NULL AND checkout_method IS NOT NULL)
  ),
  -- KID-016: an override must carry a reason and the second volunteer.
  CONSTRAINT chk_kids_check_ins_override CHECK (
    checkout_method <> 'operator_override'
    OR (override_reason IS NOT NULL AND override_authorized_by_volunteer_id IS NOT NULL)
  ),
  CONSTRAINT uq_kids_check_ins_tag UNIQUE (kids_session_id, tag_number)
);

-- KID-019: a child cannot be checked into two classrooms in the same session.
CREATE UNIQUE INDEX uq_kids_check_ins_one_active_per_session
  ON church.kids_check_ins(kids_session_id, child_person_id)
  WHERE status = 'checked_in';

-- Live classroom roster — the hot path during a service.
CREATE INDEX idx_kids_check_ins_live_roster
  ON church.kids_check_ins(kids_session_id, room_id)
  WHERE status = 'checked_in';
-- "Children not checked out" — the end-of-service panic screen.
CREATE INDEX idx_kids_check_ins_open_org
  ON church.kids_check_ins(organization_id, checked_in_at)
  WHERE status = 'checked_in';
CREATE INDEX idx_kids_check_ins_child ON church.kids_check_ins(child_person_id, checked_in_at DESC);
CREATE INDEX idx_kids_check_ins_batch ON church.kids_check_ins(batch_id);

-- KID-020: classroom transfers, preserving the original check-in.
CREATE TABLE church.kids_check_in_location_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  check_in_id UUID NOT NULL REFERENCES church.kids_check_ins(id) ON DELETE CASCADE,
  from_room_id UUID REFERENCES public.rooms(id) ON DELETE SET NULL,
  to_room_id UUID NOT NULL REFERENCES public.rooms(id) ON DELETE RESTRICT,
  changed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  changed_by_volunteer_id UUID REFERENCES church.kids_volunteers(id) ON DELETE SET NULL,
  changed_by_name TEXT NOT NULL,
  reason TEXT
);

CREATE INDEX idx_kids_location_history_checkin
  ON church.kids_check_in_location_history(check_in_id, changed_at);

-- ---------------------------------------------------------------------------
-- Pickup authorization and restriction
-- ---------------------------------------------------------------------------
CREATE TABLE church.kids_pickup_authorizations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  child_person_id UUID NOT NULL,
  authorized_person_id UUID NOT NULL,
  relationship_note TEXT,
  effective_from DATE NOT NULL DEFAULT CURRENT_DATE,
  effective_to DATE,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_by_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT fk_kids_pickup_auth_child
    FOREIGN KEY (child_person_id, organization_id)
    REFERENCES church.people(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT fk_kids_pickup_auth_person
    FOREIGN KEY (authorized_person_id, organization_id)
    REFERENCES church.people(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT chk_kids_pickup_auth_dates
    CHECK (effective_to IS NULL OR effective_to >= effective_from),
  CONSTRAINT chk_kids_pickup_auth_not_self
    CHECK (child_person_id <> authorized_person_id),
  CONSTRAINT uq_kids_pickup_auth UNIQUE (child_person_id, authorized_person_id)
);

CREATE INDEX idx_kids_pickup_auth_child
  ON church.kids_pickup_authorizations(child_person_id, authorized_person_id)
  WHERE effective_to IS NULL;

-- KID-014. These rows are the most sensitive in the system: a custody
-- restriction. Read access is deliberately narrower than the directory.
CREATE TABLE church.kids_pickup_restrictions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  child_person_id UUID NOT NULL,
  -- Either a person on file, or a name for someone who is not.
  restricted_person_id UUID,
  restricted_person_name TEXT,
  reason_restricted TEXT,
  effective_from DATE NOT NULL DEFAULT CURRENT_DATE,
  effective_to DATE,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_by_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT fk_kids_restriction_child
    FOREIGN KEY (child_person_id, organization_id)
    REFERENCES church.people(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT fk_kids_restriction_person
    FOREIGN KEY (restricted_person_id, organization_id)
    REFERENCES church.people(id, organization_id) ON DELETE SET NULL,
  CONSTRAINT chk_kids_restriction_identity
    CHECK (restricted_person_id IS NOT NULL OR restricted_person_name IS NOT NULL),
  CONSTRAINT chk_kids_restriction_dates
    CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

CREATE INDEX idx_kids_restrictions_child
  ON church.kids_pickup_restrictions(child_person_id)
  WHERE effective_to IS NULL;

-- ---------------------------------------------------------------------------
-- Audit trail (KID-026)
-- ---------------------------------------------------------------------------
CREATE TABLE church.check_in_audit (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  action TEXT NOT NULL,
  outcome TEXT NOT NULL DEFAULT 'success',
  check_in_id UUID,
  batch_id UUID,
  kids_session_id UUID,
  child_person_id UUID,
  room_id UUID,
  station_id UUID,
  volunteer_id UUID,
  actor_auth_user_id UUID,
  actor_name TEXT,
  detail JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_check_in_audit_action CHECK (action IN (
    'check_in', 'check_out', 'transfer', 'code_failed', 'override',
    'sensitive_viewed', 'restricted_pickup_attempt', 'auto_expired',
    'label_reprint', 'shift_opened', 'shift_closed'
  )),
  CONSTRAINT chk_check_in_audit_outcome CHECK (outcome IN ('success', 'denied', 'error'))
);

CREATE INDEX idx_check_in_audit_org_time ON church.check_in_audit(organization_id, created_at DESC);
CREATE INDEX idx_check_in_audit_child ON church.check_in_audit(child_person_id, created_at DESC);
CREATE INDEX idx_check_in_audit_exceptions
  ON church.check_in_audit(organization_id, created_at DESC)
  WHERE outcome <> 'success' OR action IN ('override', 'restricted_pickup_attempt');

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------
DO $t$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'kids_check_in_batches', 'kids_check_ins',
    'kids_pickup_authorizations', 'kids_pickup_restrictions'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER update_church_%s_updated_at
         BEFORE UPDATE ON church.%I
         FOR EACH ROW EXECUTE FUNCTION church.update_updated_at_column()', t, t);
  END LOOP;
END
$t$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
ALTER TABLE church.kids_check_in_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE church.kids_check_ins ENABLE ROW LEVEL SECURITY;
ALTER TABLE church.kids_check_in_location_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE church.kids_pickup_authorizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE church.kids_pickup_restrictions ENABLE ROW LEVEL SECURITY;
ALTER TABLE church.check_in_audit ENABLE ROW LEVEL SECURITY;

-- READ: the kids team, including a station, so the live classroom roster and
-- Realtime work. Note there is deliberately NO insert/update/delete policy on
-- kids_check_ins for anyone. Writes happen exclusively through the SECURITY
-- DEFINER RPCs in the next migration, which is what guarantees a station
-- cannot attribute an action to a volunteer who did not perform it.
CREATE POLICY "Kids team can view check-in batches"
  ON church.kids_check_in_batches FOR SELECT TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['kids_admin','kids_volunteer','leadership_viewer']::church.module_permission[])));

CREATE POLICY "Kids team can view check-ins"
  ON church.kids_check_ins FOR SELECT TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['kids_admin','kids_volunteer','leadership_viewer']::church.module_permission[])));

CREATE POLICY "Kids team can view location history"
  ON church.kids_check_in_location_history FOR SELECT TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['kids_admin','kids_volunteer','leadership_viewer']::church.module_permission[])));

-- Pickup authorizations: visible to the kids team so a volunteer can see who
-- may collect a child. Editable only by kids/membership admins.
CREATE POLICY "Kids team can view pickup authorizations"
  ON church.kids_pickup_authorizations FOR SELECT TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['kids_admin','kids_volunteer','members_admin']::church.module_permission[])));

CREATE POLICY "Admins can manage pickup authorizations"
  ON church.kids_pickup_authorizations FOR ALL TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['kids_admin','members_admin']::church.module_permission[])))
  WITH CHECK (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['kids_admin','members_admin']::church.module_permission[])));

-- Restrictions carry the reason a parent is barred from collecting their own
-- child. Narrower than authorizations on purpose: kids_volunteer is NOT here.
-- A volunteer learns "this pickup is blocked" from the check-in row's
-- has_pickup_restriction flag and from the RPC refusing, never by reading why.
CREATE POLICY "Admins can view pickup restrictions"
  ON church.kids_pickup_restrictions FOR SELECT TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['kids_admin','members_admin']::church.module_permission[])));

CREATE POLICY "Admins can manage pickup restrictions"
  ON church.kids_pickup_restrictions FOR ALL TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['kids_admin','members_admin']::church.module_permission[])))
  WITH CHECK (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['kids_admin','members_admin']::church.module_permission[])));

-- Audit is readable by admins and append-only from the app's perspective:
-- no UPDATE or DELETE policy exists for anyone.
CREATE POLICY "Admins can view check-in audit"
  ON church.check_in_audit FOR SELECT TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['kids_admin','leadership_viewer']::church.module_permission[])));

GRANT SELECT ON church.kids_check_in_batches TO authenticated;
GRANT SELECT ON church.kids_check_ins TO authenticated;
GRANT SELECT ON church.kids_check_in_location_history TO authenticated;
GRANT SELECT ON church.check_in_audit TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.kids_pickup_authorizations TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.kids_pickup_restrictions TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON church.kids_check_in_batches TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.kids_check_ins TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.kids_check_in_location_history TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.kids_pickup_authorizations TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.kids_pickup_restrictions TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.check_in_audit TO service_role;

COMMENT ON TABLE church.kids_check_ins IS
  'Child check-in records. There is NO insert/update/delete policy for any '
  'client role: all writes go through the SECURITY DEFINER RPCs, which is how '
  'a shared station account is prevented from attributing an action to a '
  'volunteer who did not perform it (KID-006, KID-016).';
COMMENT ON TABLE church.kids_check_in_secrets IS
  'VAULT — granted to nobody. HMAC-keyed pickup code and QR token hashes.';

NOTIFY pgrst, 'reload schema';
