-- =====================================================
-- Add Taxpayer Identification Number (TIN) to expense requests
-- =====================================================

-- Add TIN column to expense_requests table
ALTER TABLE budget.expense_requests
  ADD COLUMN tin TEXT;

-- Add comment for documentation
COMMENT ON COLUMN budget.expense_requests.tin IS 'Taxpayer Identification Number for reimbursement purposes';
