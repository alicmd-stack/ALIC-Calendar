-- Fix budget_allocations RLS policy for INSERT operations
-- The existing policy uses FOR ALL with only USING clause,
-- which doesn't work correctly for INSERT (requires WITH CHECK)

-- Drop all existing policies first to avoid conflicts
DROP POLICY IF EXISTS "Admin/Treasury/Finance can manage budget allocations" ON budget.budget_allocations;
DROP POLICY IF EXISTS "Admin/Treasury/Finance can insert budget allocations" ON budget.budget_allocations;
DROP POLICY IF EXISTS "Admin/Treasury/Finance can update budget allocations" ON budget.budget_allocations;
DROP POLICY IF EXISTS "Admin/Treasury/Finance can delete budget allocations" ON budget.budget_allocations;

-- Note: "Users can view budget allocations in their organizations" SELECT policy already exists
-- from the original migration, so we don't recreate it

-- INSERT policy (for creating new allocations)
CREATE POLICY "Admin/Treasury/Finance can insert budget allocations"
  ON budget.budget_allocations FOR INSERT
  TO authenticated
  WITH CHECK (
    organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid() AND role IN ('admin', 'treasury', 'finance')
    )
  );

-- UPDATE policy (for updating allocations)
CREATE POLICY "Admin/Treasury/Finance can update budget allocations"
  ON budget.budget_allocations FOR UPDATE
  TO authenticated
  USING (
    organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid() AND role IN ('admin', 'treasury', 'finance')
    )
  )
  WITH CHECK (
    organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid() AND role IN ('admin', 'treasury', 'finance')
    )
  );

-- DELETE policy (for deleting allocations)
CREATE POLICY "Admin/Treasury/Finance can delete budget allocations"
  ON budget.budget_allocations FOR DELETE
  TO authenticated
  USING (
    organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid() AND role IN ('admin', 'treasury', 'finance')
    )
  );

-- =====================================================
-- Backfill: Create budget allocations for ALL approved allocation requests
-- This handles requests that were approved before the automatic creation was added
-- =====================================================
INSERT INTO budget.budget_allocations (
  organization_id,
  ministry_id,
  fiscal_year_id,
  allocated_amount
)
SELECT
  ar.organization_id,
  ar.ministry_id,
  ar.fiscal_year_id,
  SUM(ar.approved_amount) as allocated_amount
FROM budget.allocation_requests ar
LEFT JOIN budget.budget_allocations ba
  ON ar.ministry_id = ba.ministry_id
  AND ar.fiscal_year_id = ba.fiscal_year_id
WHERE ar.status IN ('approved', 'partially_approved')
  AND ar.approved_amount > 0
  AND ba.id IS NULL
GROUP BY ar.organization_id, ar.ministry_id, ar.fiscal_year_id;
