-- Fix RLS policy for allocation_requests updates
-- Allow users to update their own requests before approval/denial

-- Drop the existing policy
DROP POLICY IF EXISTS "Users can update allocation requests" ON budget.allocation_requests;

-- Create updated policy that allows users to update their own requests
-- when status is 'draft' or 'pending' (before approval/denial)
CREATE POLICY "Users can update allocation requests"
ON budget.allocation_requests FOR UPDATE
TO authenticated
USING (
  -- Users can update their own requests in draft or pending status
  (requester_id = auth.uid() AND status IN ('draft', 'pending')) OR
  -- Admins can update any request in their organization
  EXISTS (
    SELECT 1 FROM public.user_organizations
    WHERE user_id = auth.uid()
    AND organization_id = budget.allocation_requests.organization_id
    AND app_role IN ('admin', 'superadmin')
  )
)
WITH CHECK (
  -- Users can only update to draft or pending status (can't approve themselves)
  (requester_id = auth.uid() AND status IN ('draft', 'pending')) OR
  -- Admins can set any status
  EXISTS (
    SELECT 1 FROM public.user_organizations
    WHERE user_id = auth.uid()
    AND organization_id = budget.allocation_requests.organization_id
    AND app_role IN ('admin', 'superadmin')
  )
);
