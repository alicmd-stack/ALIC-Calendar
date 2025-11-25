-- Fix infinite recursion in user_organizations RLS policy
-- Drop existing policies that may cause recursion
DROP POLICY IF EXISTS "Users can view their own memberships" ON user_organizations;
DROP POLICY IF EXISTS "Users can view own organization memberships" ON user_organizations;
DROP POLICY IF EXISTS "user_organizations_select_policy" ON user_organizations;
DROP POLICY IF EXISTS "Enable read access for users" ON user_organizations;

-- Create simple policy without recursion
CREATE POLICY "Users can view their own memberships" ON user_organizations
FOR SELECT USING (user_id = auth.uid());
