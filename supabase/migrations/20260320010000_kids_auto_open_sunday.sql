-- =====================================================
-- Sunday opens itself, and a session's rooms stay current
-- =====================================================
--
-- Three related problems, all of which show up on the same screen.
--
-- 1. NOBODY SHOULD HAVE TO PRESS A BUTTON AT 10:15 ON A SUNDAY.
--    church.open_todays_session() is only ever called from a leader's browser.
--    If the leader is late, parking, or on the worship team, the station shows
--    "Not started" and check-in cannot begin — the one moment in the week when
--    it must already be working. The service time is known in advance, so the
--    session can be too.
--
-- 2. AN OPEN SESSION NEVER PICKED UP A CLASSROOM CHANGE.
--    open_todays_session() attaches classrooms once, at the instant it creates
--    the session, and its "already open today" branch hands that session back
--    without looking at the room list at all. So a classroom added, retired or
--    re-graded afterwards stays invisible for the rest of the day, and pressing
--    the button again does nothing — the only escape was closing the session and
--    losing the morning. It matters right now: 20260320002500 replaced six
--    provisionally-banded rooms with ten graded ones, and any session already
--    open when it lands keeps showing the old six. Reconciling on every call,
--    and on every scheduler tick, fixes both.
--
-- 3. OPENING AUTOMATICALLY REQUIRES CLOSING AUTOMATICALLY.
--    Nothing closes a session. Today that is merely untidy; once sessions open
--    on their own it compounds every week, and the live board becomes a stack
--    of Sundays with the current one somewhere in the middle. The event already
--    carries auto_expire_minutes_after_end for exactly this kind of backstop.
--
-- Checkout deliberately does NOT require an open session (only check-in does),
-- so closing a session can never strand a child in a room. That is what makes
-- an automatic close safe.

-- ---------------------------------------------------------------------------
-- When the service actually happens
-- ---------------------------------------------------------------------------
--
-- On the event, not the session: the session is the thing being generated.
-- auto_open_dow is NULL for anything that is not on a weekly clock (VBS, a
-- conference), and a NULL there or in service_starts_local means "this event
-- is never opened automatically" rather than "open it at midnight".
ALTER TABLE church.kids_events
  ADD COLUMN IF NOT EXISTS auto_open_dow SMALLINT,
  ADD COLUMN IF NOT EXISTS service_starts_local TIME,
  ADD COLUMN IF NOT EXISTS service_minutes INTEGER NOT NULL DEFAULT 150,
  ADD COLUMN IF NOT EXISTS auto_open_service_label TEXT NOT NULL
    DEFAULT 'Sunday Service';

DO $$
BEGIN
  ALTER TABLE church.kids_events
    ADD CONSTRAINT chk_kids_events_auto_open_dow
    CHECK (auto_open_dow IS NULL OR auto_open_dow BETWEEN 0 AND 6);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  ALTER TABLE church.kids_events
    ADD CONSTRAINT chk_kids_events_service_minutes CHECK (service_minutes > 0);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

COMMENT ON COLUMN church.kids_events.auto_open_dow IS
  'Day of week this event opens itself on, 0 = Sunday to match EXTRACT(DOW). '
  'NULL disables automatic opening. Evaluated in the organization''s local '
  'timezone, never in UTC.';
COMMENT ON COLUMN church.kids_events.service_starts_local IS
  'Local wall-clock start of the service. Check-in opens '
  'check_in_opens_minutes_before earlier. NULL disables automatic opening.';

-- ---------------------------------------------------------------------------
-- Why a room is closed, which is not the same question as whether it is
-- ---------------------------------------------------------------------------
--
-- Reconciliation has to close rooms that are no longer classrooms, and it must
-- never reopen one a leader closed during the service. Both are is_open =
-- false, and without knowing which is which the safe choice is to reopen
-- nothing — but then a room retired by mistake and immediately restored stays
-- off the board for the rest of the day, because the session already has a row
-- for it and attaching is a no-op.
--
-- So record who closed it. Reconciliation may undo its own decisions and only
-- its own; a leader's close is permanent for the session, which is what a
-- person standing in the doorway means by closing a room.
ALTER TABLE church.kids_session_rooms
  ADD COLUMN IF NOT EXISTS closed_reason TEXT;

DO $$
BEGIN
  ALTER TABLE church.kids_session_rooms
    ADD CONSTRAINT chk_kids_session_rooms_closed_reason
    CHECK (closed_reason IS NULL OR closed_reason IN ('leader', 'config'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

COMMENT ON COLUMN church.kids_session_rooms.closed_reason IS
  '''config'' — closed by kids_sync_session_rooms() because the room is no '
  'longer a configured classroom, and reopened by it if that changes back. '
  '''leader'' — closed by a person during the service; reconciliation leaves it '
  'alone. NULL while the room is open.';

-- Existing rows: anything already closed was closed by a person, since nothing
-- else could close it before this migration.
UPDATE church.kids_session_rooms
   SET closed_reason = 'leader'
 WHERE NOT is_open AND closed_reason IS NULL;

-- ---------------------------------------------------------------------------
-- Reconciling a session's rooms with the configured classrooms
-- ---------------------------------------------------------------------------
--
-- Internal: no permission check, and no grant to authenticated. Every caller is
-- either a SECURITY DEFINER function that has already established who is
-- asking, or the scheduler, which is nobody — auth.uid() is NULL under cron, so
-- a permission check here would make the whole thing uncallable on a Sunday.
CREATE OR REPLACE FUNCTION church.kids_sync_session_rooms(_kids_session_id UUID)
RETURNS TABLE (rooms_attached INTEGER, rooms_closed INTEGER)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _org UUID;
  _attached INTEGER := 0;
  _closed INTEGER := 0;
BEGIN
  SELECT s.organization_id INTO _org
  FROM church.kids_sessions s WHERE s.id = _kids_session_id;
  IF _org IS NULL THEN RAISE EXCEPTION 'session_not_found'; END IF;

  -- Attach classrooms configured since the session opened.
  --
  -- Only rooms the session has never seen. A room the leader closed during the
  -- service with kids_close_room_in_session() carries closed_reason='leader'
  -- and is deliberately left out of the reopen below: this reconciles the
  -- session against the CONFIGURATION, and configuration does not get to
  -- overrule someone standing in the building.
  INSERT INTO church.kids_session_rooms (organization_id, kids_session_id, room_id)
  SELECT _org, _kids_session_id, rkc.room_id
  FROM church.room_kids_config rkc
  WHERE rkc.organization_id = _org
    AND rkc.is_active AND rkc.is_checkin_location
  ON CONFLICT (kids_session_id, room_id) DO NOTHING;
  GET DIAGNOSTICS _attached = ROW_COUNT;

  -- A room this function closed earlier, now configured as a classroom again.
  -- Its row already exists, so the INSERT above skipped it; without this it
  -- would stay off the board for the rest of the day.
  WITH reopened AS (
    UPDATE church.kids_session_rooms sr
       SET is_open = true, closed_reason = NULL, updated_at = now()
     WHERE sr.kids_session_id = _kids_session_id
       AND NOT sr.is_open
       AND sr.closed_reason = 'config'
       AND EXISTS (
         SELECT 1 FROM church.room_kids_config rkc
          WHERE rkc.room_id = sr.room_id
            AND rkc.organization_id = _org
            AND rkc.is_active AND rkc.is_checkin_location)
     RETURNING 1)
  SELECT _attached + count(*)::INTEGER INTO _attached FROM reopened;

  -- Drop rooms that are no longer classrooms — retired, or taken out of
  -- children's use, as 20260320002500 does to the Youth room — but only when
  -- empty. A room holding a child stays on the board whatever the config says,
  -- because the board is the register of where children physically are. Same
  -- rule kids_close_room_in_session() enforces for a human.
  WITH stale AS (
    UPDATE church.kids_session_rooms sr
       SET is_open = false, closed_reason = 'config', updated_at = now()
     WHERE sr.kids_session_id = _kids_session_id
       AND sr.is_open
       AND NOT EXISTS (
         SELECT 1 FROM church.room_kids_config rkc
          WHERE rkc.room_id = sr.room_id
            AND rkc.organization_id = _org
            AND rkc.is_active AND rkc.is_checkin_location)
       AND NOT EXISTS (
         SELECT 1 FROM church.kids_check_ins c
          WHERE c.kids_session_id = _kids_session_id
            AND c.room_id = sr.room_id
            AND c.status = 'checked_in')
     RETURNING 1)
  SELECT count(*)::INTEGER INTO _closed FROM stale;

  RETURN QUERY SELECT _attached, _closed;
END;
$$;

REVOKE ALL ON FUNCTION church.kids_sync_session_rooms(UUID) FROM PUBLIC;

COMMENT ON FUNCTION church.kids_sync_session_rooms(UUID) IS
  'Makes a session''s room list match church.room_kids_config: attaches newly '
  'configured classrooms, closes ones no longer in children''s use that hold no '
  'child. Never reopens a room a leader closed by hand.';



-- ---------------------------------------------------------------------------
-- The two functions a leader uses to open and close a room, taught to say why
-- ---------------------------------------------------------------------------
--
-- Bodies are otherwise unchanged from 20260320001900; only closed_reason moves.
CREATE OR REPLACE FUNCTION church.kids_open_room_in_session(
  _kids_session_id UUID, _room_id UUID, _capacity_override INTEGER DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _org UUID;
BEGIN
  SELECT s.organization_id INTO _org
  FROM church.kids_sessions s WHERE s.id = _kids_session_id;
  IF _org IS NULL THEN RAISE EXCEPTION 'session_not_found'; END IF;

  IF _org NOT IN (SELECT church.my_orgs_with_any(
       ARRAY['kids_admin']::church.module_permission[])) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM church.room_kids_config rk
                 WHERE rk.room_id = _room_id AND rk.organization_id = _org
                   AND rk.is_active AND rk.is_checkin_location) THEN
    RAISE EXCEPTION 'room_is_not_a_configured_classroom';
  END IF;

  INSERT INTO church.kids_session_rooms (
    organization_id, kids_session_id, room_id, capacity_override, is_open)
  VALUES (_org, _kids_session_id, _room_id, _capacity_override, true)
  ON CONFLICT (kids_session_id, room_id) DO UPDATE SET
    is_open = true,
    closed_reason = NULL,
    capacity_override = coalesce(EXCLUDED.capacity_override,
                                 kids_session_rooms.capacity_override),
    updated_at = now();
END;
$$;

GRANT EXECUTE ON FUNCTION church.kids_open_room_in_session(UUID, UUID, INTEGER)
  TO authenticated;

CREATE OR REPLACE FUNCTION church.kids_close_room_in_session(
  _kids_session_id UUID, _room_id UUID)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _org UUID;
  _still INTEGER;
BEGIN
  SELECT s.organization_id INTO _org
  FROM church.kids_sessions s WHERE s.id = _kids_session_id;
  IF _org IS NULL THEN RAISE EXCEPTION 'session_not_found'; END IF;

  IF _org NOT IN (SELECT church.my_orgs_with_any(
       ARRAY['kids_admin']::church.module_permission[])) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  SELECT count(*) INTO _still FROM church.kids_check_ins c
  WHERE c.kids_session_id = _kids_session_id AND c.room_id = _room_id
    AND c.status = 'checked_in';

  IF _still > 0 THEN
    RAISE EXCEPTION 'room_still_has_children'
      USING DETAIL = format('%s child(ren) still checked in', _still),
            HINT = 'Check them out or transfer them before closing the room.';
  END IF;

  -- 'leader', so reconciliation never reopens it behind their back.
  UPDATE church.kids_session_rooms
     SET is_open = false, closed_reason = 'leader', updated_at = now()
   WHERE kids_session_id = _kids_session_id AND room_id = _room_id;
END;
$$;

GRANT EXECUTE ON FUNCTION church.kids_close_room_in_session(UUID, UUID)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Creating the session row itself
-- ---------------------------------------------------------------------------
--
-- Shared by the leader's button and the scheduler so the two can never disagree
-- about which session is "today's" — they look it up by the same
-- (organization, local date, label) key and therefore converge on one row.
--
-- _reopen_closed is the whole difference between them. A leader who closed the
-- session at 1:45 and presses the button again at 1:50 means it; the scheduler
-- ticking at 1:50 does not, and must leave a deliberate close alone. It returns
-- ZERO ROWS in that case, which is the scheduler's signal to skip.
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
  SELECT s.id, s.status INTO _existing, _status
  FROM church.kids_sessions s
  WHERE s.organization_id = _organization_id
    AND s.kids_event_id = _kids_event_id
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
  -- unique constraint on (kids_event_id, session_date, service_label) settles
  -- it; the loser re-reads rather than failing the caller.
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
      AND s.kids_event_id = _kids_event_id
      AND s.session_date = _session_date
      AND s.service_label = _label
    LIMIT 1;
    RETURN QUERY SELECT _new, false; RETURN;
  END;
END;
$$;

REVOKE ALL ON FUNCTION church.kids_open_session(
  UUID, UUID, TEXT, DATE, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- The leader's button, rebuilt on top of those two
-- ---------------------------------------------------------------------------
--
-- Behaviour changes deliberately in three ways:
--
--   * "Today" is the organization's local date, not the database's UTC date.
--     CURRENT_DATE is UTC on Supabase, so an evening service in America/New_York
--     was already being filed under tomorrow.
--   * The session gets the event's real service times when it has them, instead
--     of now()-30min to now()+3h. Those times drive the automatic close.
--   * It reconciles the room list on EVERY call, including the "already open"
--     path, and reports what changed so the leader can be told.
DROP FUNCTION IF EXISTS church.open_todays_session(UUID, TEXT);

CREATE FUNCTION church.open_todays_session(
  _organization_id UUID,
  _service_label TEXT DEFAULT NULL
)
RETURNS TABLE (
  session_id UUID,
  service_label TEXT,
  was_created BOOLEAN,
  rooms_attached INTEGER,
  rooms_closed INTEGER
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  ev church.kids_events%ROWTYPE;
  _tz TEXT;
  _local_date DATE;
  _label TEXT;
  _starts TIMESTAMPTZ;
  _ends TIMESTAMPTZ;
  _session UUID;
  _created BOOLEAN;
  _attached INTEGER;
  _closed INTEGER;
  _rooms INTEGER;
BEGIN
  IF NOT church.has_permission_in_org(
       _organization_id,
       ARRAY['kids_admin','kids_volunteer']::church.module_permission[]) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(o.timezone, 'America/New_York') INTO _tz
  FROM public.organizations o WHERE o.id = _organization_id;
  IF _tz IS NULL THEN RAISE EXCEPTION 'organization_not_found'; END IF;
  _local_date := (now() AT TIME ZONE _tz)::DATE;

  SELECT * INTO ev FROM church.kids_events e
   WHERE e.organization_id = _organization_id AND e.is_active
   ORDER BY e.created_at LIMIT 1;

  IF ev.id IS NULL THEN
    INSERT INTO church.kids_events (
      organization_id, name, event_type, created_by_name)
    VALUES (_organization_id, 'Kids Ministry', 'weekly_service',
            coalesce((SELECT full_name FROM public.profiles WHERE id = auth.uid()),
                     'System'))
    RETURNING * INTO ev;
  END IF;

  _label := coalesce(NULLIF(btrim(coalesce(_service_label, '')), ''),
                     ev.auto_open_service_label, 'Sunday Service');

  -- A configured service time wins, because the automatic close reads ends_at.
  -- Without one, keep the old "opened by hand, so it starts about now" window.
  IF ev.service_starts_local IS NOT NULL THEN
    _starts := (_local_date + ev.service_starts_local) AT TIME ZONE _tz;
    _ends := _starts + make_interval(mins => ev.service_minutes);
  ELSE
    _starts := now() - interval '30 minutes';
    _ends := now() + interval '3 hours';
  END IF;

  SELECT o.session_id, o.was_created INTO _session, _created
  FROM church.kids_open_session(
    _organization_id, ev.id, _label, _local_date, _starts, _ends, true) o;

  IF _session IS NULL THEN RAISE EXCEPTION 'could_not_open_session'; END IF;

  SELECT s.rooms_attached, s.rooms_closed INTO _attached, _closed
  FROM church.kids_sync_session_rooms(_session) s;

  -- A session with nowhere to put a child is not a session. Checked after the
  -- sync rather than before, so a classroom configured a minute ago counts.
  SELECT count(*) INTO _rooms FROM church.kids_session_rooms sr
   WHERE sr.kids_session_id = _session AND sr.is_open;
  IF _rooms = 0 THEN RAISE EXCEPTION 'no_classrooms_configured'; END IF;

  RETURN QUERY SELECT _session, _label, _created, _attached, _closed;
END;
$$;

GRANT EXECUTE ON FUNCTION church.open_todays_session(UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- The scheduler
-- ---------------------------------------------------------------------------
--
-- Runs every ten minutes, every day, and decides for itself whether this is a
-- morning it should act on. The alternative — a cron expression that names
-- Sunday — would be wrong twice: cron fires in UTC, and each organization keeps
-- its own timezone, so "Sunday" is a question only the row can answer.
CREATE OR REPLACE FUNCTION church.kids_auto_open_sessions()
RETURNS INTEGER
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  ev RECORD;
  _local TIMESTAMP;
  _local_date DATE;
  _starts TIMESTAMPTZ;
  _ends TIMESTAMPTZ;
  _session UUID;
  _created BOOLEAN;
  _opened INTEGER := 0;
BEGIN
  FOR ev IN
    SELECT e.*, coalesce(o.timezone, 'America/New_York') AS tz
    FROM church.kids_events e
    JOIN public.organizations o
      ON o.id = e.organization_id AND o.is_active
    WHERE e.is_active
      AND e.auto_open_dow IS NOT NULL
      AND e.service_starts_local IS NOT NULL
  LOOP
    -- One organization's bad configuration must not stop the others opening.
    -- VA-Springfield has no classrooms at all and will raise here every week
    -- until somebody defines its rooms; MD must still open regardless.
    BEGIN
      _local := now() AT TIME ZONE ev.tz;
      _local_date := _local::DATE;

      CONTINUE WHEN EXTRACT(DOW FROM _local)::SMALLINT <> ev.auto_open_dow;

      _starts := (_local_date + ev.service_starts_local) AT TIME ZONE ev.tz;
      _ends := _starts + make_interval(mins => ev.service_minutes);

      -- Open exactly when the desk opens, and stop offering once check-in has
      -- closed for the day, so a tick at 9pm does not resurrect the morning.
      CONTINUE WHEN now() <
        _starts - make_interval(mins => ev.check_in_opens_minutes_before);
      CONTINUE WHEN now() >
        _ends + make_interval(mins => ev.check_in_closes_minutes_after);

      IF NOT EXISTS (
        SELECT 1 FROM church.room_kids_config rkc
         WHERE rkc.organization_id = ev.organization_id
           AND rkc.is_active AND rkc.is_checkin_location) THEN
        RAISE NOTICE 'kids auto-open skipped for %: no classrooms configured',
          ev.organization_id;
        CONTINUE;
      END IF;

      SELECT s.session_id, s.was_created INTO _session, _created
      FROM church.kids_open_session(
        ev.organization_id, ev.id, ev.auto_open_service_label,
        _local_date, _starts, _ends, false) s;

      CONTINUE WHEN _session IS NULL;   -- closed on purpose; leave it closed

      -- Every tick, not only the one that created it: a classroom edited at
      -- 10:40 is on the board by 10:50 without anyone reopening anything.
      PERFORM church.kids_sync_session_rooms(_session);

      IF _created THEN _opened := _opened + 1; END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'kids auto-open failed for organization %: %',
        ev.organization_id, SQLERRM;
    END;
  END LOOP;

  RETURN _opened;
END;
$$;

-- Without this, opening automatically would pile a session on the live board
-- every week and never take one off.
CREATE OR REPLACE FUNCTION church.kids_auto_close_sessions()
RETURNS INTEGER
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE _n INTEGER;
BEGIN
  UPDATE church.kids_sessions s
     SET status = 'closed', closed_at = now(), updated_at = now()
    FROM church.kids_events e
   WHERE e.id = s.kids_event_id
     AND s.status = 'open'
     AND now() > s.ends_at
                 + make_interval(mins => e.auto_expire_minutes_after_end);
  GET DIAGNOSTICS _n = ROW_COUNT;

  -- Closing does NOT check anybody out. A child still marked checked_in stays
  -- that way and keeps showing on the "not collected" screen, which is the
  -- point of that screen. Only check-in requires an open session; checkout
  -- works on a closed one.
  RETURN _n;
END;
$$;

CREATE OR REPLACE FUNCTION church.kids_session_tick()
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
BEGIN
  -- Close first: last Sunday's session is off the board before this Sunday's
  -- appears on it.
  PERFORM church.kids_auto_close_sessions();
  PERFORM church.kids_auto_open_sessions();
END;
$$;

REVOKE ALL ON FUNCTION church.kids_auto_open_sessions() FROM PUBLIC;
REVOKE ALL ON FUNCTION church.kids_auto_close_sessions() FROM PUBLIC;
REVOKE ALL ON FUNCTION church.kids_session_tick() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION church.kids_session_tick() TO service_role;

COMMENT ON FUNCTION church.kids_session_tick() IS
  'Scheduler entry point, every 10 minutes: closes sessions past their event''s '
  'auto_expire window, then opens any whose check-in window has arrived in the '
  'organization''s local timezone, reconciling classrooms on every tick.';

-- ---------------------------------------------------------------------------
-- ALIC's actual service times
-- ---------------------------------------------------------------------------
--
-- From the published schedule on the Locations page:
--   Silver Spring, MD   Sunday Worship 11:00a - 1:30p
--   Springfield, VA     Sunday Worship 10:30a - 1:00p
--
-- With the event's default 45-minute lead, check-in opens 10:15 in MD and 09:45
-- in VA. The event row is created here rather than waiting for someone to press
-- the button, because the whole point is that nobody has to.
DO $$
DECLARE
  v RECORD;
  _org UUID;
  _event UUID;
BEGIN
  FOR v IN
    SELECT * FROM (VALUES
      ('md-silver-spring', '11:00'::TIME, 150),
      ('va-springfield',   '10:30'::TIME, 150)
    ) AS t(slug, starts_local, minutes)
  LOOP
    SELECT id INTO _org FROM public.organizations WHERE slug = v.slug;
    IF _org IS NULL THEN
      RAISE NOTICE 'organization % not found; skipping kids schedule', v.slug;
      CONTINUE;
    END IF;

    SELECT e.id INTO _event FROM church.kids_events e
     WHERE e.organization_id = _org AND e.is_active
     ORDER BY e.created_at LIMIT 1;

    IF _event IS NULL THEN
      INSERT INTO church.kids_events (
        organization_id, name, event_type, created_by_name,
        auto_open_dow, service_starts_local, service_minutes)
      VALUES (_org, 'Kids Ministry', 'weekly_service', 'System',
              0, v.starts_local, v.minutes);
    ELSE
      UPDATE church.kids_events
         SET auto_open_dow = 0,
             service_starts_local = v.starts_local,
             service_minutes = v.minutes,
             updated_at = now()
       WHERE id = _event;
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- Capacities inherited from a room's previous life
-- ---------------------------------------------------------------------------
--
-- 20260320002500 renamed rooms in place, deliberately, so their bookings and
-- check-in history stayed attached. That also carried over the PROVISIONAL
-- capacities and ratios guessed in 20260320001500, when the rooms meant
-- something else entirely: "Shine class" was the nursery guess at 12 children,
-- and "Shine A" is 4th grade. A capacity inherited from a room's previous life
-- is worse than no capacity at all, because the live board warns confidently
-- and wrongly, and a leader learns to ignore the amber.
--
-- Cleared, so nothing warns until the director gives real numbers. An unset
-- limit never warns, and both are editable per room from the Classrooms tab.
UPDATE church.room_kids_config rk
   SET capacity = NULL,
       ratio_children_per_volunteer = NULL,
       updated_at = now()
 WHERE rk.school_grade_id IS NOT NULL
   AND (rk.capacity IS NOT NULL OR rk.ratio_children_per_volunteer IS NOT NULL);

-- ---------------------------------------------------------------------------
-- Fix the board for a session that is open right now
-- ---------------------------------------------------------------------------
--
-- Everything above only helps the NEXT time somebody opens a session. If a
-- session is open at the moment this migration runs — which is exactly the case
-- when the classroom rework is deployed on a Sunday — its rooms are still the
-- old list. Reconcile them here so the board is right without anyone pressing
-- anything.
DO $$
DECLARE
  s RECORD;
  _added INTEGER;
  _closed INTEGER;
BEGIN
  FOR s IN SELECT id FROM church.kids_sessions WHERE status = 'open' LOOP
    SELECT r.rooms_attached, r.rooms_closed INTO _added, _closed
    FROM church.kids_sync_session_rooms(s.id) r;
    IF _added > 0 OR _closed > 0 THEN
      RAISE NOTICE 'session %: % classroom(s) attached, % closed',
        s.id, _added, _closed;
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- Schedule it
-- ---------------------------------------------------------------------------
--
-- Ten minutes, not one: opening a session is not urgent to the minute the way
-- "please come to Room 4" is, and the desk opens 45 minutes before the service
-- anyway. Guarded because a clean local replay may not have pg_cron.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'cron') THEN
    RAISE NOTICE 'pg_cron not installed; kids sessions will not open automatically';
    RETURN;
  END IF;

  PERFORM cron.unschedule('kids-session-tick')
   WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'kids-session-tick');

  PERFORM cron.schedule(
    'kids-session-tick',
    '*/10 * * * *',
    $cron$SELECT church.kids_session_tick();$cron$
  );
END $$;

NOTIFY pgrst, 'reload schema';
