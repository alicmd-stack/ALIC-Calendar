-- =====================================================
-- Expose budget schema to PostgREST API
-- This grants usage permissions to the budget schema
-- =====================================================

-- Grant usage on the budget schema to the roles used by PostgREST
GRANT USAGE ON SCHEMA budget TO anon, authenticated, service_role;

-- Grant all necessary permissions on tables in the budget schema
GRANT ALL ON ALL TABLES IN SCHEMA budget TO anon, authenticated, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA budget TO anon, authenticated, service_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA budget TO anon, authenticated, service_role;

-- Set default privileges for future objects in the budget schema
ALTER DEFAULT PRIVILEGES IN SCHEMA budget
GRANT ALL ON TABLES TO anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA budget
GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA budget
GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;

-- Notify PostgREST to reload its schema cache
NOTIFY pgrst, 'reload schema';
