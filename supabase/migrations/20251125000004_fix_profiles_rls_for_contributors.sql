-- Fix profiles RLS policy for contributors
-- The issue: profiles RLS policy queries user_organizations, but user_organizations RLS
-- only allows users to see their own memberships, creating a conflict where users can't
-- see other profiles in their organization.

-- Solution: Create a SECURITY DEFINER function to check organization membership
-- that bypasses RLS on user_organizations

-- Create helper function to get all user IDs in the same organizations as the current user
CREATE OR REPLACE FUNCTION public.get_users_in_same_organizations(_user_id UUID)
RETURNS SETOF UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT DISTINCT uo2.user_id
  FROM public.user_organizations uo1
  JOIN public.user_organizations uo2 ON uo1.organization_id = uo2.organization_id
  WHERE uo1.user_id = _user_id
$$;

-- Drop existing profile select policy
DROP POLICY IF EXISTS "Users can view profiles in their organizations" ON public.profiles;

-- Create new policy using the helper function
CREATE POLICY "Users can view profiles in their organizations"
  ON public.profiles FOR SELECT
  TO authenticated
  USING (
    id IN (SELECT public.get_users_in_same_organizations(auth.uid()))
    OR id = auth.uid()
  );
