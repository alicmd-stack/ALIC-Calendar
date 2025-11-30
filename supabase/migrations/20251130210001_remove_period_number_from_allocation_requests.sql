-- =====================================================
-- Remove period_number from allocation_requests
-- Now using allocation_period_amounts table for period breakdowns
-- =====================================================

-- Drop the period_number constraint first
ALTER TABLE budget.allocation_requests 
DROP CONSTRAINT IF EXISTS check_period_number_range;

-- Drop the period_number column
ALTER TABLE budget.allocation_requests 
DROP COLUMN IF EXISTS period_number;

-- Add comment to clarify
COMMENT ON COLUMN budget.allocation_requests.period_type IS 'Type of budget period: annual (1 year), quarterly (4 periods), or monthly (12 periods). See allocation_period_amounts table for individual period breakdowns.';
