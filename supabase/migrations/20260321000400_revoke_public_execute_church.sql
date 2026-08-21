-- =====================================================
-- Internal helpers must not be callable from a browser
-- =====================================================
--
-- 77 of the 98 functions in `church` were executable by PUBLIC, because that is
-- what Postgres does by default and a REVOKE was never written. 26 of them are
-- internal helpers the application never calls, and three of those are enough
-- to work real harm from any signed-in session:
--
--   queue_child_notification  SECURITY DEFINER, no permission check of ANY kind.
--                             It looks up a check-in by id and posts to the
--                             notification queue; a one-minute cron then mails
--                             it through Resend from the church's own domain.
--                             auth.uid() appears in it only as a value it
--                             stores, never as a guard. So any signed-in user
--                             holding a check_in_id could email a child's
--                             parents "come to the west door, we're bringing
--                             your child out." The wrapper above it,
--                             send_parent_message, checks resolve_actor and
--                             org scope properly. The raw function underneath
--                             it did not.
--
--   check_in_one_child        SECURITY DEFINER and takes the RESOLVED ACTOR as
--                             a parameter, so a direct caller supplies their
--                             own identity: a forged check-in row and a
--                             matching audit row attributed to any org,
--                             volunteer and name, bypassing capacity and
--                             restriction checks. KID-006 attribution is
--                             decorative while this is reachable.
--
--   insert_person_from_json   SECURITY DEFINER row-writer with no caller check.
--
-- WHY THIS IS SAFE TO DO WHOLESALE. Every one of the 53 functions the frontend
-- actually calls already carries an explicit GRANT to `authenticated`; none of
-- them depends on the PUBLIC grant. Verified by cross-referencing every
-- `.rpc("name")` in src/ against has_function_privilege. So revoking PUBLIC
-- removes exactly the 26 nobody was supposed to reach, and nothing else.
--
-- WHY service_role IS GRANTED BACK EXPLICITLY. 76 functions gave service_role
-- EXECUTE only by way of PUBLIC. Revoking PUBLIC alone would silently strip it,
-- which would break anything server-side that runs under the service key. The
-- three pg_cron jobs are unaffected either way — they run as `postgres`, which
-- owns these functions.
--
-- WHAT THIS IS NOT. anon has no USAGE on `church`, so none of this was ever
-- reachable from the internet; the exposure was to signed-in users. That is
-- also why this is worth doing now rather than treating it as an emergency:
-- the blast radius was the congregation's own logins, not the public.

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA church FROM PUBLIC;

-- Keep what PUBLIC was incidentally providing to the server-side role.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA church TO service_role;

-- Without this, the next function anyone writes arrives PUBLIC-executable again
-- and this whole migration silently rots.
ALTER DEFAULT PRIVILEGES IN SCHEMA church REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA church GRANT EXECUTE ON FUNCTIONS TO service_role;

NOTIFY pgrst, 'reload schema';
