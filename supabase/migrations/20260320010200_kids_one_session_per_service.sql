-- =====================================================
-- One session per service, per branch, per day
-- =====================================================
--
-- The auto-open tick dedupes per kids_events row, and the only constraint is
-- uq_kids_sessions_event_label — unique per EVENT and label. So two active
-- events in one organization each open their own "Sunday Service" on the same
-- morning. Tested: three events produced three identical open sessions.
--
-- That is not hypothetical. open_todays_session() CREATES a kids_events row
-- whenever it finds no active one, so an event deactivated and re-created, or
-- a second event added for a VBS week, quietly doubles every Sunday after it.
--
-- The damage is not cosmetic. The live board groups by session, so the leader
-- sees the same service listed twice with the children split between them;
-- a family checked in against one session cannot be found by the desk looking
-- at the other; and the end-of-service "not collected" screen is right about
-- half the room.
--
-- Production currently has exactly one active event per branch and no
-- duplicate sessions, so this is a door being closed before anyone walks
-- through it.
--
-- Two labels on one day (a 9:00 and an 11:00 service) remain fine — that is a
-- different service, not a duplicate of the same one.

-- Any duplicates that already exist are RELABELLED and closed, never merged
-- and never deleted. Moving check-ins between sessions would fight the
-- one-child-one-room partial unique index and could strand a child mid-service;
-- the losing sessions keep their rows and their history, and simply stop being
-- called "Sunday Service". The survivor is the one opened first.
DO $$
DECLARE d RECORD; n INTEGER;
BEGIN
  FOR d IN
    SELECT organization_id, session_date, service_label
    FROM church.kids_sessions
    GROUP BY 1, 2, 3 HAVING count(*) > 1
  LOOP
    n := 0;
    FOR n IN
      SELECT row_number() OVER (ORDER BY opened_at NULLS LAST, created_at, id)
      FROM church.kids_sessions
      WHERE organization_id = d.organization_id
        AND session_date = d.session_date
        AND service_label = d.service_label
    LOOP NULL; END LOOP;

    WITH ranked AS (
      SELECT id, row_number() OVER (ORDER BY opened_at NULLS LAST, created_at, id) AS rn
      FROM church.kids_sessions
      WHERE organization_id = d.organization_id
        AND session_date = d.session_date
        AND service_label = d.service_label
    )
    UPDATE church.kids_sessions k
       SET service_label = k.service_label || ' (duplicate ' || r.rn || ')',
           status = 'closed',
           closed_at = coalesce(k.closed_at, now()),
           updated_at = now()
      FROM ranked r
     WHERE k.id = r.id AND r.rn > 1;
  END LOOP;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_kids_sessions_org_date_label
  ON church.kids_sessions (organization_id, session_date, service_label);

COMMENT ON INDEX church.uq_kids_sessions_org_date_label IS
  'One session per branch per day per service label, regardless of which '
  'kids_events row asked for it. uq_kids_sessions_event_label is per-event and '
  'therefore does not prevent two events opening the same service twice.';

-- ---------------------------------------------------------------------------
-- Make the opener honour it rather than raise
-- ---------------------------------------------------------------------------
--
-- kids_open_session looks for an existing session by event; with the index
-- above, a second event asking for the same service would now hit a unique
-- violation instead of quietly duplicating. Look it up by the same key the
-- index enforces, so the second asker joins the existing session.
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

GRANT EXECUTE ON FUNCTION church.kids_open_session(
  UUID, UUID, TEXT, DATE, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN) TO authenticated;

NOTIFY pgrst, 'reload schema';
