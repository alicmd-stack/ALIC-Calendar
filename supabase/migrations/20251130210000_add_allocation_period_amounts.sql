-- =====================================================
-- Add Period Amounts Table for Budget Allocations
-- Stores individual period amounts for quarterly/monthly requests
-- =====================================================

-- Create table to store period-specific amounts
CREATE TABLE budget.allocation_period_amounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  allocation_request_id UUID NOT NULL REFERENCES budget.allocation_requests(id) ON DELETE CASCADE,
  
  -- Period identifier
  -- For quarterly: 1, 2, 3, 4 (Q1, Q2, Q3, Q4)
  -- For monthly: 1-12 (Jan=1, Feb=2, ..., Dec=12)
  period_number INTEGER NOT NULL CHECK (period_number BETWEEN 1 AND 12),
  
  -- Amount for this specific period
  amount DECIMAL(12, 2) NOT NULL CHECK (amount >= 0),
  
  -- Optional: notes specific to this period
  notes TEXT,
  
  -- Timestamps
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  
  -- Ensure one entry per period per request
  UNIQUE(allocation_request_id, period_number)
);

-- Create index for faster lookups
CREATE INDEX idx_allocation_period_amounts_request ON budget.allocation_period_amounts(allocation_request_id);

-- Add trigger to update timestamp
CREATE TRIGGER update_allocation_period_amounts_updated_at
  BEFORE UPDATE ON budget.allocation_period_amounts
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- Enable RLS
ALTER TABLE budget.allocation_period_amounts ENABLE ROW LEVEL SECURITY;

-- Policy: Users can view period amounts for allocation requests they can see
CREATE POLICY "Users can view allocation period amounts"
ON budget.allocation_period_amounts FOR SELECT
TO authenticated
USING (
  allocation_request_id IN (
    SELECT id FROM budget.allocation_requests
    WHERE organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid()
    )
  )
);

-- Policy: Users can insert period amounts for their own requests
CREATE POLICY "Users can insert allocation period amounts"
ON budget.allocation_period_amounts FOR INSERT
TO authenticated
WITH CHECK (
  allocation_request_id IN (
    SELECT id FROM budget.allocation_requests
    WHERE requester_id = auth.uid()
    AND organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid()
    )
  )
);

-- Policy: Users can update period amounts for their own draft/pending requests
CREATE POLICY "Users can update allocation period amounts"
ON budget.allocation_period_amounts FOR UPDATE
TO authenticated
USING (
  allocation_request_id IN (
    SELECT id FROM budget.allocation_requests
    WHERE (
      (requester_id = auth.uid() AND status IN ('draft', 'pending')) OR
      EXISTS (
        SELECT 1 FROM public.user_organizations
        WHERE user_id = auth.uid()
        AND organization_id = budget.allocation_requests.organization_id
        AND app_role IN ('admin', 'superadmin')
      )
    )
  )
);

-- Policy: Users can delete period amounts for their own draft requests
CREATE POLICY "Users can delete allocation period amounts"
ON budget.allocation_period_amounts FOR DELETE
TO authenticated
USING (
  allocation_request_id IN (
    SELECT id FROM budget.allocation_requests
    WHERE requester_id = auth.uid()
    AND status = 'draft'
  )
);

-- Update the allocation_requests table structure
-- Remove period_number since we now have a separate table
-- Add a computed total that matches the period amounts

COMMENT ON TABLE budget.allocation_period_amounts IS 'Stores individual period amounts for quarterly and monthly budget allocation requests';
COMMENT ON COLUMN budget.allocation_period_amounts.period_number IS 'Period number: 1-4 for quarterly, 1-12 for monthly';
COMMENT ON COLUMN budget.allocation_period_amounts.amount IS 'Requested amount for this specific period';
