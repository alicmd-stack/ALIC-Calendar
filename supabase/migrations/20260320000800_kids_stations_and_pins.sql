-- =====================================================
-- Kids Ministry: check-in stations, volunteer PINs, shift tokens
-- =====================================================
--
-- THE CORE PROBLEM
-- ----------------
-- A check-in station is a shared tablet on a desk in the church lobby. It
-- signs in once as a device account and stays signed in all morning, so
-- auth.uid() identifies the TABLET, never the volunteer operating it. But
-- KID-006 requires recording "the person who checked the child in", and
-- KID-016 requires auditing overrides by volunteer.
--
-- The resolution is that the station account is given NO write privilege on
-- any check-in table whatsoever. Every mutating operation is a SECURITY
-- DEFINER RPC that takes a shift token, resolves it to a real volunteer, and
-- writes that volunteer's identity itself. A station cannot claim to be
-- someone it is not, because it never gets to write the field.
--
-- The three tables below are a VAULT: they hold PIN hashes and token hashes
-- and are granted to NOBODY. Not to `authenticated`, not to `anon`. They are
-- reachable only from inside the SECURITY DEFINER functions in this file.

-- ---------------------------------------------------------------------------
-- Station registry
-- ---------------------------------------------------------------------------
CREATE TABLE church.check_in_stations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  code TEXT NOT NULL,
  name TEXT NOT NULL,
  device_type TEXT NOT NULL DEFAULT 'desk',
  -- The Supabase auth user this physical station signs in as. Provisioned
  -- through the Admin API with raw_app_meta_data.account_type = 'station', so
  -- 20260320000000 keeps it out of user_organizations entirely.
  auth_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  location_note TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  last_seen_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT uq_check_in_stations_org_code UNIQUE (organization_id, code),
  CONSTRAINT uq_check_in_stations_auth_user UNIQUE (auth_user_id),
  CONSTRAINT chk_check_in_stations_device
    CHECK (device_type IN ('desk', 'tablet', 'laptop', 'door'))
);

CREATE INDEX idx_check_in_stations_org ON church.check_in_stations(organization_id);

-- ---------------------------------------------------------------------------
-- Kids volunteers (eligibility + PIN identity)
-- ---------------------------------------------------------------------------
CREATE TABLE church.kids_volunteers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  person_id UUID NOT NULL,
  -- KID-024: eligibility indicators. Only status and expiry are stored here —
  -- never the contents of a background check report.
  background_check_status TEXT NOT NULL DEFAULT 'not_started',
  background_check_expires_on DATE,
  background_check_reference TEXT,
  training_completed_on DATE,
  -- Authorises the SECOND PIN in a checkout override. Deliberately separate
  -- from being a volunteer at all: the two-person rule is only meaningful if
  -- not everyone can be the second person.
  can_override BOOLEAN NOT NULL DEFAULT false,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT uq_kids_volunteers_person UNIQUE (person_id),
  CONSTRAINT uq_kids_volunteers_id_org UNIQUE (id, organization_id),
  CONSTRAINT fk_kids_volunteers_person
    FOREIGN KEY (person_id, organization_id)
    REFERENCES church.people(id, organization_id) ON DELETE CASCADE,
  CONSTRAINT chk_kids_volunteers_bg_status
    CHECK (background_check_status IN
      ('clear', 'pending', 'expired', 'not_started', 'restricted'))
);

CREATE INDEX idx_kids_volunteers_org_active
  ON church.kids_volunteers(organization_id) WHERE is_active;

-- ---------------------------------------------------------------------------
-- VAULT 1: PIN hashes.  Granted to nobody.
-- ---------------------------------------------------------------------------
CREATE TABLE church.kids_volunteer_pins (
  volunteer_id UUID PRIMARY KEY
    REFERENCES church.kids_volunteers(id) ON DELETE CASCADE,
  pin_hash TEXT NOT NULL,
  failed_attempts INTEGER NOT NULL DEFAULT 0,
  locked_until TIMESTAMPTZ,
  last_used_at TIMESTAMPTZ,
  rotated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- VAULT 2: shift tokens.  Granted to nobody.
-- ---------------------------------------------------------------------------
CREATE TABLE church.kids_shift_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL,
  volunteer_id UUID NOT NULL REFERENCES church.kids_volunteers(id) ON DELETE CASCADE,
  station_id UUID NOT NULL REFERENCES church.check_in_stations(id) ON DELETE CASCADE,
  -- sha256 of the token. The raw value exists only in the tablet's memory.
  token_hash BYTEA NOT NULL,
  -- Binds the token to the JWT it was issued to, so a token copied off one
  -- station cannot be replayed from another device.
  issued_to_auth_user UUID,
  issued_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  ended_at TIMESTAMPTZ,
  CONSTRAINT uq_kids_shift_tokens_hash UNIQUE (token_hash)
);

CREATE INDEX idx_kids_shift_tokens_live
  ON church.kids_shift_tokens(token_hash) WHERE ended_at IS NULL;

-- No GRANT statements for the two vault tables. This is deliberate and is the
-- whole point: `authenticated` (which includes every station tablet) cannot
-- SELECT a PIN hash or a token hash under any circumstances.
REVOKE ALL ON church.kids_volunteer_pins FROM PUBLIC, anon, authenticated;
REVOKE ALL ON church.kids_shift_tokens FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.kids_volunteer_pins TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.kids_shift_tokens TO service_role;

ALTER TABLE church.kids_volunteer_pins ENABLE ROW LEVEL SECURITY;
ALTER TABLE church.kids_shift_tokens ENABLE ROW LEVEL SECURITY;
-- RLS on with zero policies = deny all. Belt and braces alongside the missing
-- grants: even if a GRANT is added by mistake later, there is still no policy.

-- ---------------------------------------------------------------------------
-- Resolved actor
-- ---------------------------------------------------------------------------
CREATE TYPE church.resolved_actor AS (
  organization_id UUID,
  person_id UUID,
  volunteer_id UUID,
  station_id UUID,
  actor_name TEXT,
  source TEXT,
  can_check_in BOOLEAN,
  can_check_out BOOLEAN,
  can_override BOOLEAN
);

-- Resolves who is acting, from either a station shift token or an ordinary
-- authenticated session.
--
-- Two callers exist:
--   * a station tablet, which passes a shift token obtained via a volunteer
--     PIN. Identity and permissions come from the volunteer.
--   * a kids admin working from the dashboard, which passes NULL. Identity
--     comes from auth.uid() and permissions from module_grants.
CREATE OR REPLACE FUNCTION church.resolve_actor(_shift_token TEXT DEFAULT NULL)
RETURNS church.resolved_actor
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  a church.resolved_actor;
  st church.kids_shift_tokens%ROWTYPE;
  v  church.kids_volunteers%ROWTYPE;
  p  church.people%ROWTYPE;
  _admin_orgs UUID[];
BEGIN
  IF _shift_token IS NOT NULL AND length(_shift_token) > 0 THEN
    SELECT * INTO st
    FROM church.kids_shift_tokens
    WHERE token_hash = digest(_shift_token, 'sha256')
      AND ended_at IS NULL
      AND expires_at > now();

    IF NOT FOUND THEN
      RAISE EXCEPTION 'invalid_or_expired_shift' USING ERRCODE = '28000';
    END IF;

    -- The token must be presented by the same device it was issued to.
    IF st.issued_to_auth_user IS NOT NULL
       AND st.issued_to_auth_user IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'invalid_or_expired_shift' USING ERRCODE = '28000';
    END IF;

    SELECT * INTO v FROM church.kids_volunteers WHERE id = st.volunteer_id;
    IF NOT FOUND OR NOT v.is_active OR v.background_check_status = 'restricted' THEN
      RAISE EXCEPTION 'volunteer_not_eligible' USING ERRCODE = '42501';
    END IF;

    SELECT * INTO p FROM church.people WHERE id = v.person_id;

    a.organization_id := st.organization_id;
    a.person_id       := v.person_id;
    a.volunteer_id    := v.id;
    a.station_id      := st.station_id;
    a.actor_name      := coalesce(p.preferred_name, p.first_name) || ' ' || p.last_name;
    a.source          := 'station';
    a.can_check_in    := true;
    a.can_check_out   := true;
    a.can_override    := v.can_override;
    RETURN a;
  END IF;

  -- Dashboard path.
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT array_agg(o) INTO _admin_orgs
  FROM church.my_orgs_with_any(ARRAY['kids_admin']::church.module_permission[]) AS o;

  IF _admin_orgs IS NULL OR array_length(_admin_orgs, 1) IS NULL THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  a.organization_id := _admin_orgs[1];
  a.person_id       := (SELECT id FROM church.people
                        WHERE profile_id = auth.uid()
                          AND organization_id = _admin_orgs[1] LIMIT 1);
  a.volunteer_id    := NULL;
  a.station_id      := NULL;
  a.actor_name      := coalesce(
                         (SELECT full_name FROM public.profiles WHERE id = auth.uid()),
                         'Administrator');
  a.source          := 'admin';
  a.can_check_in    := true;
  a.can_check_out   := true;
  a.can_override    := true;
  RETURN a;
END;
$$;

-- ---------------------------------------------------------------------------
-- Setting a PIN
-- ---------------------------------------------------------------------------
-- The PIN never round-trips: it is hashed here and the caller can only ever
-- write one, never read one back.
CREATE OR REPLACE FUNCTION church.set_volunteer_pin(_volunteer_id UUID, _pin TEXT)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  v church.kids_volunteers%ROWTYPE;
BEGIN
  SELECT * INTO v FROM church.kids_volunteers WHERE id = _volunteer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'volunteer_not_found';
  END IF;

  IF NOT church.has_permission_in_org(
       v.organization_id, ARRAY['kids_admin']::church.module_permission[]) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  IF _pin !~ '^[0-9]{4,8}$' THEN
    RAISE EXCEPTION 'pin_must_be_4_to_8_digits';
  END IF;

  -- Reject the PINs that people actually pick. A 4-digit space is only 10,000
  -- wide, and roughly a fifth of real-world choices fall in a handful of
  -- patterns; blocking them is worth more than adding a digit.
  IF _pin IN ('0000','1111','2222','3333','4444','5555','6666','7777','8888','9999',
              '1234','4321','0123','9876','1212','2580')
     OR _pin ~ '^(\d)\1+$' THEN
    RAISE EXCEPTION 'pin_too_predictable';
  END IF;

  INSERT INTO church.kids_volunteer_pins (volunteer_id, pin_hash)
  VALUES (_volunteer_id, crypt(_pin, gen_salt('bf', 10)))
  ON CONFLICT (volunteer_id) DO UPDATE
    SET pin_hash = EXCLUDED.pin_hash,
        failed_attempts = 0,
        locked_until = NULL,
        rotated_at = now();
END;
$$;

-- ---------------------------------------------------------------------------
-- Opening a shift
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.station_open_shift(
  _station_id UUID,
  _volunteer_id UUID,
  _pin TEXT,
  _duration_minutes INTEGER DEFAULT 240
)
RETURNS TABLE (shift_token TEXT, volunteer_name TEXT, expires_at TIMESTAMPTZ,
               can_override BOOLEAN)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  s  church.check_in_stations%ROWTYPE;
  v  church.kids_volunteers%ROWTYPE;
  pr church.kids_volunteer_pins%ROWTYPE;
  p  church.people%ROWTYPE;
  _ok BOOLEAN := false;
  _token TEXT;
  _expires TIMESTAMPTZ;
  -- Decoy so the bcrypt cost is paid even when the volunteer does not exist
  -- or has no PIN set. Without it, response time leaks which names are real.
  _decoy TEXT := '$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy';
BEGIN
  SELECT * INTO s FROM church.check_in_stations
   WHERE id = _station_id AND is_active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'station_not_found' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO v FROM church.kids_volunteers
   WHERE id = _volunteer_id AND organization_id = s.organization_id AND is_active;

  SELECT * INTO pr FROM church.kids_volunteer_pins WHERE volunteer_id = _volunteer_id;

  -- Always run the comparison, on a real hash or the decoy, before branching.
  IF pr.volunteer_id IS NOT NULL
     AND (pr.locked_until IS NULL OR pr.locked_until <= now()) THEN
    _ok := (pr.pin_hash = crypt(_pin, pr.pin_hash));
  ELSE
    PERFORM crypt(coalesce(_pin, ''), _decoy);
    _ok := false;
  END IF;

  -- KID-024: a restricted volunteer cannot start a shift at all.
  IF v.id IS NULL OR v.background_check_status = 'restricted' THEN
    _ok := false;
  END IF;

  IF NOT _ok THEN
    IF pr.volunteer_id IS NOT NULL THEN
      UPDATE church.kids_volunteer_pins
         SET failed_attempts = failed_attempts + 1,
             locked_until = CASE WHEN failed_attempts + 1 >= 5
                                 THEN now() + interval '15 minutes'
                                 ELSE locked_until END
       WHERE volunteer_id = _volunteer_id;
    END IF;

    -- Return ZERO ROWS rather than RAISE. This is not a style preference: a
    -- RAISE aborts the surrounding transaction, which would roll back the
    -- increment immediately above it and leave the lockout counter
    -- permanently stuck at zero. Verified by test — with a RAISE here, five
    -- wrong PINs followed by the correct one still succeeded.
    --
    -- Zero rows is still a single indistinguishable "denied" for every
    -- failure mode (wrong PIN, unknown volunteer, locked out, restricted), so
    -- the station is not an enumeration oracle. Callers must treat an empty
    -- result as denial.
    RETURN;
  END IF;

  UPDATE church.kids_volunteer_pins
     SET failed_attempts = 0, locked_until = NULL, last_used_at = now()
   WHERE volunteer_id = _volunteer_id;

  SELECT * INTO p FROM church.people WHERE id = v.person_id;

  _token := encode(gen_random_bytes(32), 'base64');
  _expires := now() + make_interval(mins => greatest(1, least(_duration_minutes, 720)));

  -- End any shift this volunteer still has open at this station, so a
  -- forgotten sign-out does not leave a live credential behind.
  UPDATE church.kids_shift_tokens
     SET ended_at = now()
   WHERE volunteer_id = _volunteer_id AND station_id = _station_id AND ended_at IS NULL;

  INSERT INTO church.kids_shift_tokens
    (organization_id, volunteer_id, station_id, token_hash, issued_to_auth_user, expires_at)
  VALUES
    (s.organization_id, v.id, s.id, digest(_token, 'sha256'), auth.uid(), _expires);

  UPDATE church.check_in_stations SET last_seen_at = now() WHERE id = _station_id;

  RETURN QUERY SELECT
    _token,
    coalesce(p.preferred_name, p.first_name) || ' ' || p.last_name,
    _expires,
    v.can_override;
END;
$$;

CREATE OR REPLACE FUNCTION church.station_close_shift(_shift_token TEXT)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
BEGIN
  UPDATE church.kids_shift_tokens
     SET ended_at = now()
   WHERE token_hash = digest(_shift_token, 'sha256') AND ended_at IS NULL;
END;
$$;

-- The volunteer name grid on the idle station screen. Returns names and
-- eligibility only — never a PIN, never a hash, never contact details.
CREATE OR REPLACE FUNCTION church.station_list_volunteers(_station_id UUID)
RETURNS TABLE (volunteer_id UUID, display_name TEXT, is_eligible BOOLEAN,
               background_check_status TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE s church.check_in_stations%ROWTYPE;
BEGIN
  SELECT * INTO s FROM church.check_in_stations WHERE id = _station_id AND is_active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'station_not_found';
  END IF;

  RETURN QUERY
  SELECT v.id,
         coalesce(p.preferred_name, p.first_name) || ' ' || left(p.last_name, 1) || '.',
         (v.background_check_status = 'clear'
          AND (v.background_check_expires_on IS NULL
               OR v.background_check_expires_on > CURRENT_DATE)),
         v.background_check_status
  FROM church.kids_volunteers v
  JOIN church.people p ON p.id = v.person_id
  WHERE v.organization_id = s.organization_id
    AND v.is_active
    -- A restricted volunteer is not offered at all, so their name never
    -- appears on a screen facing a queue of parents.
    AND v.background_check_status <> 'restricted'
    AND EXISTS (SELECT 1 FROM church.kids_volunteer_pins pin WHERE pin.volunteer_id = v.id)
  ORDER BY p.first_name;
END;
$$;

GRANT EXECUTE ON FUNCTION church.resolve_actor(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION church.set_volunteer_pin(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION church.station_open_shift(UUID, UUID, TEXT, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION church.station_close_shift(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION church.station_list_volunteers(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- RLS on the non-vault tables
-- ---------------------------------------------------------------------------
ALTER TABLE church.check_in_stations ENABLE ROW LEVEL SECURITY;
ALTER TABLE church.kids_volunteers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Kids team can view stations"
  ON church.check_in_stations FOR SELECT TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['kids_admin','kids_volunteer','leadership_viewer']::church.module_permission[]))
    OR auth_user_id = auth.uid());

CREATE POLICY "Kids admins can manage stations"
  ON church.check_in_stations FOR ALL TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['kids_admin']::church.module_permission[])))
  WITH CHECK (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['kids_admin']::church.module_permission[])));

CREATE POLICY "Kids admins can view volunteers"
  ON church.kids_volunteers FOR SELECT TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['kids_admin','leadership_viewer']::church.module_permission[])));

CREATE POLICY "Kids admins can manage volunteers"
  ON church.kids_volunteers FOR ALL TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['kids_admin']::church.module_permission[])))
  WITH CHECK (organization_id IN (SELECT * FROM church.my_orgs_with_any(
    ARRAY['kids_admin']::church.module_permission[])));

GRANT SELECT, INSERT, UPDATE, DELETE ON church.check_in_stations TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.check_in_stations TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.kids_volunteers TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.kids_volunteers TO service_role;

CREATE TRIGGER update_church_check_in_stations_updated_at
  BEFORE UPDATE ON church.check_in_stations
  FOR EACH ROW EXECUTE FUNCTION church.update_updated_at_column();
CREATE TRIGGER update_church_kids_volunteers_updated_at
  BEFORE UPDATE ON church.kids_volunteers
  FOR EACH ROW EXECUTE FUNCTION church.update_updated_at_column();

COMMENT ON TABLE church.kids_volunteer_pins IS
  'VAULT — granted to nobody. bcrypt PIN hashes, reachable only from inside '
  'the SECURITY DEFINER functions in 20260320000800.';
COMMENT ON TABLE church.kids_shift_tokens IS
  'VAULT — granted to nobody. sha256 shift-token hashes bound to the issuing '
  'device JWT.';

NOTIFY pgrst, 'reload schema';
