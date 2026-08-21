-- =====================================================
-- Additive module permissions for the church schema
-- =====================================================
--
-- WHY NOT JUST ADD VALUES TO public.app_role
-- ------------------------------------------
-- public.user_organizations has UNIQUE(user_id, organization_id), so a user
-- holds exactly ONE app_role per branch. Adding 'kids_volunteer' to app_role
-- would mean making someone a kids volunteer takes away their 'contributor' or
-- 'treasury' role. Module permissions must therefore be additive rows in a
-- separate table, leaving app_role and every existing policy untouched.

CREATE TYPE church.module_permission AS ENUM (
  'members_admin',      -- create/edit people, households, relationships
  'members_viewer',     -- read the directory
  'members_import',     -- bulk CSV import
  'kids_admin',         -- classrooms, sessions, volunteers, overrides, reports
  'kids_volunteer',     -- operate a check-in station (nothing else)
  'leadership_viewer'   -- read-only reporting across both modules
);

CREATE TABLE church.module_grants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  permission church.module_permission NOT NULL,
  granted_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  granted_by_name TEXT,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Additive: many permissions per user per org, but each at most once.
  CONSTRAINT uq_module_grants_user_org_permission
    UNIQUE (user_id, organization_id, permission)
);

CREATE INDEX idx_module_grants_user_id ON church.module_grants(user_id);
CREATE INDEX idx_module_grants_organization_id ON church.module_grants(organization_id);
CREATE INDEX idx_module_grants_lookup ON church.module_grants(user_id, organization_id);

CREATE TRIGGER update_church_module_grants_updated_at
  BEFORE UPDATE ON church.module_grants
  FOR EACH ROW EXECUTE FUNCTION church.update_updated_at_column();

-- Helper functions ---------------------------------------------------------
--
-- All SECURITY DEFINER so they can read user_organizations and module_grants
-- without tripping the RLS policies that will be written in terms of them
-- (which would otherwise recurse). All STABLE so the planner can cache them
-- within a statement.

-- Organizations where the caller is an admin, per user_organizations.
-- Note this is org-scoped, unlike the frontend's useAuth().isAdmin, which
-- currently ORs roles across every organization the user belongs to.
CREATE OR REPLACE FUNCTION church.my_admin_orgs()
RETURNS SETOF UUID
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = church, public
AS $$
  SELECT organization_id
  FROM public.user_organizations
  WHERE user_id = auth.uid() AND role = 'admin'
$$;

-- Every organization the caller belongs to at all.
CREATE OR REPLACE FUNCTION church.my_orgs()
RETURNS SETOF UUID
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = church, public
AS $$
  SELECT organization_id
  FROM public.user_organizations
  WHERE user_id = auth.uid()
$$;

-- Organizations where the caller holds ANY of the given module permissions,
-- OR is an org admin. Org admin implying every module permission is a product
-- decision: admins can see children's sensitive data, and every such access is
-- still recorded in church.check_in_audit so it remains traceable.
CREATE OR REPLACE FUNCTION church.my_orgs_with_any(
  _permissions church.module_permission[]
)
RETURNS SETOF UUID
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = church, public
AS $$
  SELECT * FROM church.my_admin_orgs()
  UNION
  SELECT organization_id
  FROM church.module_grants
  WHERE user_id = auth.uid()
    AND permission = ANY(_permissions)
$$;

-- Convenience predicate for a single organization.
CREATE OR REPLACE FUNCTION church.has_permission_in_org(
  _organization_id UUID,
  _permissions church.module_permission[]
)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = church, public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM church.my_orgs_with_any(_permissions) AS o
    WHERE o = _organization_id
  )
$$;

-- RLS ----------------------------------------------------------------------

ALTER TABLE church.module_grants ENABLE ROW LEVEL SECURITY;

-- A user can always see their own grants (the app needs this to build the
-- capability set), and an org admin can see all grants in their org.
CREATE POLICY "Users can view their own module grants"
  ON church.module_grants FOR SELECT
  TO authenticated
  USING (
    user_id = auth.uid()
    OR organization_id IN (SELECT * FROM church.my_admin_orgs())
  );

-- Only org admins may hand out permissions. Deliberately not delegated to
-- members_admin or kids_admin: privilege granting stays with the org admin.
CREATE POLICY "Org admins can create module grants"
  ON church.module_grants FOR INSERT
  TO authenticated
  WITH CHECK (
    organization_id IN (SELECT * FROM church.my_admin_orgs())
  );

CREATE POLICY "Org admins can update module grants"
  ON church.module_grants FOR UPDATE
  TO authenticated
  USING (
    organization_id IN (SELECT * FROM church.my_admin_orgs())
  )
  WITH CHECK (
    organization_id IN (SELECT * FROM church.my_admin_orgs())
  );

CREATE POLICY "Org admins can revoke module grants"
  ON church.module_grants FOR DELETE
  TO authenticated
  USING (
    organization_id IN (SELECT * FROM church.my_admin_orgs())
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON church.module_grants TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON church.module_grants TO service_role;

GRANT EXECUTE ON FUNCTION church.my_orgs() TO authenticated;
GRANT EXECUTE ON FUNCTION church.my_admin_orgs() TO authenticated;
GRANT EXECUTE ON FUNCTION church.my_orgs_with_any(church.module_permission[]) TO authenticated;
GRANT EXECUTE ON FUNCTION church.has_permission_in_org(UUID, church.module_permission[]) TO authenticated;

COMMENT ON TABLE church.module_grants IS
  'Additive per-organization module permissions. Works around '
  'user_organizations UNIQUE(user_id, organization_id), which allows only one '
  'app_role per user per branch. A station device account has NO row here and '
  'no user_organizations row; it reaches check-in only via granted RPCs.';

NOTIFY pgrst, 'reload schema';
