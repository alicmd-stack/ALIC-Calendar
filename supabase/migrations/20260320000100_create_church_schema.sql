-- =====================================================
-- Create the `church` schema
-- =====================================================
--
-- Holds the member directory, households, ministry service, groups, training
-- and Kids Ministry check-in.
--
-- ONE schema rather than separate `members` / `kids` schemas: PostgREST cannot
-- embed related resources across schemas, so a split would turn every roster
-- read (check-in -> child -> household) into a hand-written RPC. The frontend
-- is still split into two modules; that boundary does not need a DB boundary.
--
-- NOTE ON GRANTS
-- --------------
-- This deliberately does NOT copy 20251130000002_expose_budget_schema.sql,
-- which does `GRANT ALL ON ALL TABLES IN SCHEMA budget TO anon, ...` plus an
-- ALTER DEFAULT PRIVILEGES for anon. That leaves every current and future
-- budget table reachable by anonymous requests with only RLS in the way.
--
-- Here, `anon` gets USAGE on nothing and privileges on nothing. This schema
-- contains children's names, medical notes and home addresses; it must never
-- be reachable without a session. Table privileges are granted explicitly,
-- per table, in the migration that creates each table.

CREATE SCHEMA IF NOT EXISTS church;

-- Extensions ---------------------------------------------------------------
-- pgcrypto: bcrypt (crypt/gen_salt) for volunteer PIN hashing, and hmac() for
--   the pickup security code. Not previously enabled in this project.
-- pg_trgm:  fuzzy name matching for duplicate detection and station lookup.
-- btree_gist: already enabled; required for the EXCLUDE constraints that stop
--   overlapping household membership and duplicate active ministry roles.
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;

-- Schema usage -------------------------------------------------------------
-- authenticated  : real people using the app, and station device accounts.
--                  Row visibility is decided by RLS on each table.
-- service_role   : edge functions and admin tooling; bypasses RLS by design.
-- anon           : intentionally omitted.
GRANT USAGE ON SCHEMA church TO authenticated, service_role;

-- Functions in this schema are the security boundary for check-in, so they
-- must not be executable by default. Each SECURITY DEFINER function is granted
-- explicitly to `authenticated` where intended.
ALTER DEFAULT PRIVILEGES IN SCHEMA church REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- Shared updated_at trigger function ---------------------------------------
-- Mirrors public.update_updated_at_column(). Defined locally so the church
-- schema does not depend on search_path resolution into public.
CREATE OR REPLACE FUNCTION church.update_updated_at_column()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = church, public
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

COMMENT ON SCHEMA church IS
  'Member directory, households, ministry service, groups, training and Kids '
  'Ministry check-in. Contains personal and child-safety data: never granted '
  'to anon.';

NOTIFY pgrst, 'reload schema';
