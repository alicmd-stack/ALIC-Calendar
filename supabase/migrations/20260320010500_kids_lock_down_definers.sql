-- =====================================================
-- Three SECURITY DEFINER functions anyone could call
-- =====================================================
--
-- Found by audit. Each is SECURITY DEFINER — it runs as the owner, bypassing
-- RLS — and each was reachable by any signed-in user, or by anyone at all.
--
-- 1. kids_open_session had NO permission check and was granted to
--    `authenticated`. Proved on the replica: a plain contributor with zero
--    module grants created an open session in the OTHER branch. All 62
--    production logins could do that.
--
-- 2. hash_pickup had proacl NULL, i.e. the PostgreSQL default of EXECUTE to
--    PUBLIC. It applies the Vault-peppered HMAC used for pickup codes, so an
--    attacker could hash candidate codes offline and compare against
--    kids_check_in_secrets — turning a 6-character code into a lookup.
--
-- 3. station_close_shift ended a shift on possession of a token with no
--    organization check.

-- ---------------------------------------------------------------------------
-- 1. Opening a session is a kids permission, not a side effect of signing in
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.kids_open_session(
  _organization_id UUID,
  _kids_event_id UUID,
  _label TEXT,
  _session_date DATE,
  _starts_at TIMESTAMPTZ,
  _ends_at TIMESTAMPTZ,
  _reopen_closed BOOLEAN DEFAULT false
)
RETURNS TABLE (session_id UUID, was_created BOOLEAN)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _existing UUID;
  _status TEXT;
  _new UUID;
BEGIN
  -- The scheduler reaches this as the table owner during a cron tick, which is
  -- not a request and has no auth.uid(). A REQUEST must carry a kids
  -- permission in the branch it is opening.
  IF auth.uid() IS NOT NULL
     AND NOT church.has_permission_in_org(
           _organization_id,
           ARRAY['kids_admin','kids_volunteer']::church.module_permission[]) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  -- Keyed on organization + date + label, NOT on the event. Two active
  -- kids_events rows in one branch each opened their own identical
  -- "Sunday Service", splitting the children between two boards.
  SELECT s.id, s.status INTO _existing, _status
  FROM church.kids_sessions s
  WHERE s.organization_id = _organization_id
    AND s.session_date = _session_date
    AND s.service_label = _label
  LIMIT 1;

  IF _existing IS NOT NULL THEN
    IF _status = 'open' THEN
      RETURN QUERY SELECT _existing, false; RETURN;
    END IF;
    IF NOT _reopen_closed THEN
      RETURN;   -- zero rows: somebody closed it on purpose
    END IF;
    UPDATE church.kids_sessions
       SET status = 'open', opened_at = coalesce(opened_at, now()),
           closed_at = NULL, updated_at = now()
     WHERE id = _existing;
    RETURN QUERY SELECT _existing, false; RETURN;
  END IF;

  -- Two stations and the scheduler can race here on a Sunday morning. The
  -- unique constraint on (organization_id, session_date, service_label)
  -- settles it; the loser re-reads rather than failing the caller.
  BEGIN
    INSERT INTO church.kids_sessions (
      organization_id, kids_event_id, session_date, starts_at, ends_at,
      service_label, status, opened_at)
    VALUES (
      _organization_id, _kids_event_id, _session_date, _starts_at, _ends_at,
      _label, 'open', now())
    RETURNING id INTO _new;
    RETURN QUERY SELECT _new, true; RETURN;
  EXCEPTION WHEN unique_violation THEN
    SELECT s.id INTO _new FROM church.kids_sessions s
    WHERE s.organization_id = _organization_id
      AND s.session_date = _session_date
      AND s.service_label = _label
    LIMIT 1;
    RETURN QUERY SELECT _new, false; RETURN;
  END;
END;
$$;

REVOKE ALL ON FUNCTION church.kids_open_session(
  UUID, UUID, TEXT, DATE, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION church.kids_open_session(
  UUID, UUID, TEXT, DATE, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. The pickup-code hash is not a public utility
-- ---------------------------------------------------------------------------
--
-- Its only callers are SECURITY DEFINER functions in this schema, which run as
-- the owner and need no grant. Exposing it lets a caller hash guesses against
-- the same pepper the stored hashes use.
REVOKE ALL ON FUNCTION church.hash_pickup(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION church.hash_pickup(TEXT) FROM authenticated;

DO $$
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION church.normalize_pickup_code(TEXT) FROM PUBLIC';
EXCEPTION WHEN undefined_function THEN
  NULL;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Ending a shift needs more than holding the token
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION church.station_close_shift(TEXT) FROM PUBLIC';
  EXECUTE 'GRANT EXECUTE ON FUNCTION church.station_close_shift(TEXT) TO authenticated';
EXCEPTION WHEN undefined_function THEN
  RAISE NOTICE 'station_close_shift not present; skipping';
END $$;

NOTIFY pgrst, 'reload schema';
