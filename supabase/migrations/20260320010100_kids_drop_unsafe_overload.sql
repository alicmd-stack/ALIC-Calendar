-- =====================================================
-- Remove the overload that still had the hole
-- =====================================================
--
-- 20260320002800 added is_approved_collector(child, person, NAME) to close a
-- name-only protective order. It did not remove the earlier
-- is_approved_collector(child, person) — and Postgres kept both as overloads.
-- The 2-argument one is the version that compares ids only, so anything still
-- calling it (an old cached plan, a future caller writing the obvious two
-- arguments) silently gets the unsafe answer back.
--
-- An unsafe function that still resolves is worse than no fix at all, because
-- the call site looks correct.
DROP FUNCTION IF EXISTS church.is_approved_collector(UUID, UUID);

-- Postgres grants EXECUTE on new functions to PUBLIC by default, so revoking
-- from `authenticated` alone left these reachable by every signed-in user
-- through the PUBLIC grant. They answer "is there a protective order naming
-- this person" and "who may collect this child" with no permission check and
-- no audit row, which is a custody oracle. Their only legitimate callers are
-- SECURITY DEFINER functions, which do not need any grant at all.
REVOKE EXECUTE ON FUNCTION church.child_has_active_restriction(UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION church.is_approved_collector(UUID, UUID, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION church.restriction_names_person(UUID, UUID, TEXT) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION church.child_has_active_restriction(UUID) FROM authenticated;
REVOKE EXECUTE ON FUNCTION church.is_approved_collector(UUID, UUID, TEXT) FROM authenticated;
REVOKE EXECUTE ON FUNCTION church.restriction_names_person(UUID, UUID, TEXT) FROM authenticated;

NOTIFY pgrst, 'reload schema';
