-- =====================================================
-- Update Reimbursement Type Enum
-- Changes: cash, check, bank_transfer, zelle, other -> zelle, check, ach, admin_online_purchase
-- =====================================================

-- Step 1: Create new enum type
CREATE TYPE budget.reimbursement_type_new AS ENUM (
  'zelle',
  'check',
  'ach',
  'admin_online_purchase'
);

-- Step 2: Drop the default value first (it depends on the old enum)
ALTER TABLE budget.expense_requests
  ALTER COLUMN reimbursement_type DROP DEFAULT;

-- Step 3: Alter the column to use text temporarily
ALTER TABLE budget.expense_requests
  ALTER COLUMN reimbursement_type TYPE text
  USING reimbursement_type::text;

-- Step 4: Update the values
-- Mapping:
--   cash -> check (closest equivalent)
--   check -> check
--   bank_transfer -> ach
--   zelle -> zelle
--   other -> admin_online_purchase
UPDATE budget.expense_requests SET reimbursement_type = 'check' WHERE reimbursement_type = 'cash';
UPDATE budget.expense_requests SET reimbursement_type = 'ach' WHERE reimbursement_type = 'bank_transfer';
UPDATE budget.expense_requests SET reimbursement_type = 'admin_online_purchase' WHERE reimbursement_type = 'other';
-- zelle and check remain the same

-- Step 5: Drop the old enum and rename the new one
DROP TYPE budget.reimbursement_type;
ALTER TYPE budget.reimbursement_type_new RENAME TO reimbursement_type;

-- Step 6: Convert column back to enum
ALTER TABLE budget.expense_requests
  ALTER COLUMN reimbursement_type TYPE budget.reimbursement_type
  USING reimbursement_type::budget.reimbursement_type;

-- Step 7: Set default value
ALTER TABLE budget.expense_requests
  ALTER COLUMN reimbursement_type SET DEFAULT 'check'::budget.reimbursement_type;
