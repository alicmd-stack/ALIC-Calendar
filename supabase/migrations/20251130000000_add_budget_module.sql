-- =====================================================
-- Budget Management Module Migration
-- Schema: budget
-- Multi-step approval workflow: Requester → Leader → Treasury → Finance
-- =====================================================

-- Create the budget schema
CREATE SCHEMA IF NOT EXISTS budget;

-- Grant usage to authenticated users
GRANT USAGE ON SCHEMA budget TO authenticated;
GRANT USAGE ON SCHEMA budget TO service_role;

-- =====================================================
-- Add treasury and finance roles to app_role enum
-- =====================================================
ALTER TYPE public.app_role ADD VALUE IF NOT EXISTS 'treasury';
ALTER TYPE public.app_role ADD VALUE IF NOT EXISTS 'finance';

-- =====================================================
-- Create Enums in budget schema
-- =====================================================

-- Expense status enum for the multi-step approval workflow
CREATE TYPE budget.expense_status AS ENUM (
  'draft',              -- Initial state, not yet submitted
  'pending_leader',     -- Submitted, awaiting leader/approver review
  'leader_approved',    -- Leader approved, awaiting treasury review
  'leader_denied',      -- Leader denied the request
  'pending_treasury',   -- Treasury is reviewing
  'treasury_approved',  -- Treasury approved payment
  'treasury_denied',    -- Treasury denied payment
  'pending_finance',    -- Finance processing payment
  'completed',          -- Payment processed, all done
  'cancelled'           -- Request was cancelled
);

-- Reimbursement type enum
CREATE TYPE budget.reimbursement_type AS ENUM (
  'cash',
  'check',
  'bank_transfer',
  'zelle',
  'other'
);

-- =====================================================
-- Create Tables
-- =====================================================

-- Ministries table for budget allocation tracking
CREATE TABLE budget.ministries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID REFERENCES public.organizations(id) ON DELETE CASCADE NOT NULL,
  name TEXT NOT NULL,
  description TEXT,
  leader_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(organization_id, name)
);

-- Fiscal years table - simplified to just year (2024, 2025, etc.)
CREATE TABLE budget.fiscal_years (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID REFERENCES public.organizations(id) ON DELETE CASCADE NOT NULL,
  year INTEGER NOT NULL,
  name TEXT NOT NULL, -- Display name, typically same as year (e.g., "2025")
  is_active BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(organization_id, year)
);

-- Budget allocations table for ministry budgets
CREATE TABLE budget.budget_allocations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID REFERENCES public.organizations(id) ON DELETE CASCADE NOT NULL,
  fiscal_year_id UUID REFERENCES budget.fiscal_years(id) ON DELETE CASCADE NOT NULL,
  ministry_id UUID REFERENCES budget.ministries(id) ON DELETE CASCADE NOT NULL,
  allocated_amount DECIMAL(12, 2) NOT NULL DEFAULT 0,
  notes TEXT,
  approved_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  approved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(fiscal_year_id, ministry_id),
  CONSTRAINT positive_budget CHECK (allocated_amount >= 0)
);

-- Expense requests table (main table for expense tracking)
CREATE TABLE budget.expense_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID REFERENCES public.organizations(id) ON DELETE CASCADE NOT NULL,
  fiscal_year_id UUID REFERENCES budget.fiscal_years(id) ON DELETE RESTRICT NOT NULL,
  ministry_id UUID REFERENCES budget.ministries(id) ON DELETE RESTRICT NOT NULL,

  -- Request details
  title TEXT NOT NULL,
  description TEXT,
  amount DECIMAL(12, 2) NOT NULL,
  reimbursement_type budget.reimbursement_type NOT NULL DEFAULT 'check',

  -- Requester info
  requester_id UUID REFERENCES auth.users(id) ON DELETE SET NULL NOT NULL,
  requester_name TEXT NOT NULL,
  requester_phone TEXT,
  requester_email TEXT,

  -- Status and workflow
  status budget.expense_status NOT NULL DEFAULT 'draft',

  -- Leader/Approver review
  leader_reviewer_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  leader_reviewed_at TIMESTAMPTZ,
  leader_notes TEXT,

  -- Treasury review
  treasury_reviewer_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  treasury_reviewed_at TIMESTAMPTZ,
  treasury_notes TEXT,

  -- Finance processing
  finance_processor_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  finance_processed_at TIMESTAMPTZ,
  finance_notes TEXT,
  payment_reference TEXT, -- Check number, transaction ID, etc.

  -- Attachments stored as JSON array of file references
  attachments JSONB DEFAULT '[]',

  -- Timestamps
  submitted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT positive_amount CHECK (amount > 0)
);

-- Expense history table for audit trail
CREATE TABLE budget.expense_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  expense_request_id UUID REFERENCES budget.expense_requests(id) ON DELETE CASCADE NOT NULL,
  action TEXT NOT NULL, -- 'created', 'submitted', 'leader_approved', 'leader_denied', etc.
  previous_status budget.expense_status,
  new_status budget.expense_status NOT NULL,
  actor_id UUID REFERENCES auth.users(id) ON DELETE SET NULL NOT NULL,
  actor_name TEXT NOT NULL,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================
-- Enable RLS on all tables
-- =====================================================
ALTER TABLE budget.ministries ENABLE ROW LEVEL SECURITY;
ALTER TABLE budget.fiscal_years ENABLE ROW LEVEL SECURITY;
ALTER TABLE budget.budget_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE budget.expense_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE budget.expense_history ENABLE ROW LEVEL SECURITY;

-- =====================================================
-- Create Indexes for better query performance
-- =====================================================
CREATE INDEX idx_budget_ministries_organization_id ON budget.ministries(organization_id);
CREATE INDEX idx_budget_ministries_leader_id ON budget.ministries(leader_id);
CREATE INDEX idx_budget_fiscal_years_organization_id ON budget.fiscal_years(organization_id);
CREATE INDEX idx_budget_fiscal_years_year ON budget.fiscal_years(year);
CREATE INDEX idx_budget_fiscal_years_is_active ON budget.fiscal_years(is_active);
CREATE INDEX idx_budget_allocations_fiscal_year_id ON budget.budget_allocations(fiscal_year_id);
CREATE INDEX idx_budget_allocations_ministry_id ON budget.budget_allocations(ministry_id);
CREATE INDEX idx_budget_expense_requests_organization_id ON budget.expense_requests(organization_id);
CREATE INDEX idx_budget_expense_requests_ministry_id ON budget.expense_requests(ministry_id);
CREATE INDEX idx_budget_expense_requests_requester_id ON budget.expense_requests(requester_id);
CREATE INDEX idx_budget_expense_requests_status ON budget.expense_requests(status);
CREATE INDEX idx_budget_expense_requests_fiscal_year_id ON budget.expense_requests(fiscal_year_id);
CREATE INDEX idx_budget_expense_history_expense_request_id ON budget.expense_history(expense_request_id);

-- =====================================================
-- Create updated_at trigger function if not exists
-- =====================================================
CREATE OR REPLACE FUNCTION budget.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- Create Triggers for updated_at
-- =====================================================
CREATE TRIGGER update_budget_ministries_updated_at
  BEFORE UPDATE ON budget.ministries
  FOR EACH ROW
  EXECUTE FUNCTION budget.update_updated_at_column();

CREATE TRIGGER update_budget_fiscal_years_updated_at
  BEFORE UPDATE ON budget.fiscal_years
  FOR EACH ROW
  EXECUTE FUNCTION budget.update_updated_at_column();

CREATE TRIGGER update_budget_allocations_updated_at
  BEFORE UPDATE ON budget.budget_allocations
  FOR EACH ROW
  EXECUTE FUNCTION budget.update_updated_at_column();

CREATE TRIGGER update_budget_expense_requests_updated_at
  BEFORE UPDATE ON budget.expense_requests
  FOR EACH ROW
  EXECUTE FUNCTION budget.update_updated_at_column();

-- =====================================================
-- RLS Policies for Ministries
-- =====================================================

-- Users can view ministries in their organizations
CREATE POLICY "Users can view ministries in their organizations"
  ON budget.ministries FOR SELECT
  TO authenticated
  USING (
    organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid()
    )
  );

-- Admin/Treasury/Finance can manage ministries
CREATE POLICY "Admin/Treasury/Finance can manage ministries"
  ON budget.ministries FOR ALL
  TO authenticated
  USING (
    organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid() AND role IN ('admin', 'treasury', 'finance')
    )
  );

-- =====================================================
-- RLS Policies for Fiscal Years
-- =====================================================

-- Users can view fiscal years in their organizations
CREATE POLICY "Users can view fiscal years in their organizations"
  ON budget.fiscal_years FOR SELECT
  TO authenticated
  USING (
    organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid()
    )
  );

-- Admin/Treasury/Finance can manage fiscal years
CREATE POLICY "Admin/Treasury/Finance can manage fiscal years"
  ON budget.fiscal_years FOR ALL
  TO authenticated
  USING (
    organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid() AND role IN ('admin', 'treasury', 'finance')
    )
  );

-- =====================================================
-- RLS Policies for Budget Allocations
-- =====================================================

-- Users can view budget allocations in their organizations
CREATE POLICY "Users can view budget allocations in their organizations"
  ON budget.budget_allocations FOR SELECT
  TO authenticated
  USING (
    organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid()
    )
  );

-- Admin/Treasury/Finance can manage budget allocations
CREATE POLICY "Admin/Treasury/Finance can manage budget allocations"
  ON budget.budget_allocations FOR ALL
  TO authenticated
  USING (
    organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid() AND role IN ('admin', 'treasury', 'finance')
    )
  );

-- =====================================================
-- RLS Policies for Expense Requests
-- =====================================================

-- Users can view their own expense requests
CREATE POLICY "Users can view own expense requests"
  ON budget.expense_requests FOR SELECT
  TO authenticated
  USING (
    requester_id = auth.uid()
    AND organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid()
    )
  );

-- Ministry leaders can view expense requests for their ministry
CREATE POLICY "Ministry leaders can view ministry expense requests"
  ON budget.expense_requests FOR SELECT
  TO authenticated
  USING (
    ministry_id IN (
      SELECT id FROM budget.ministries
      WHERE leader_id = auth.uid()
    )
    AND organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid()
    )
  );

-- Admin/Treasury/Finance can view all expense requests
CREATE POLICY "Admin/Treasury/Finance can view all expense requests"
  ON budget.expense_requests FOR SELECT
  TO authenticated
  USING (
    organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid() AND role IN ('admin', 'treasury', 'finance')
    )
  );

-- Users can create expense requests
CREATE POLICY "Users can create expense requests"
  ON budget.expense_requests FOR INSERT
  TO authenticated
  WITH CHECK (
    requester_id = auth.uid()
    AND organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid()
    )
  );

-- Users can update their own draft expense requests
CREATE POLICY "Users can update own draft expense requests"
  ON budget.expense_requests FOR UPDATE
  TO authenticated
  USING (
    requester_id = auth.uid()
    AND status = 'draft'
    AND organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid()
    )
  );

-- Ministry leaders can update expense requests pending their review
CREATE POLICY "Ministry leaders can update pending expense requests"
  ON budget.expense_requests FOR UPDATE
  TO authenticated
  USING (
    status = 'pending_leader'
    AND ministry_id IN (
      SELECT id FROM budget.ministries
      WHERE leader_id = auth.uid()
    )
    AND organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid()
    )
  );

-- Treasury can update treasury-stage expense requests
CREATE POLICY "Treasury can update treasury-stage expense requests"
  ON budget.expense_requests FOR UPDATE
  TO authenticated
  USING (
    status IN ('leader_approved', 'pending_treasury')
    AND organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid() AND role = 'treasury'
    )
  );

-- Finance can update finance-stage expense requests
CREATE POLICY "Finance can update finance-stage expense requests"
  ON budget.expense_requests FOR UPDATE
  TO authenticated
  USING (
    status IN ('treasury_approved', 'pending_finance')
    AND organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid() AND role = 'finance'
    )
  );

-- Admin can update all expense requests
CREATE POLICY "Admin can update all expense requests"
  ON budget.expense_requests FOR UPDATE
  TO authenticated
  USING (
    organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid() AND role = 'admin'
    )
  );

-- Users can delete their own draft expense requests
CREATE POLICY "Users can delete own draft expense requests"
  ON budget.expense_requests FOR DELETE
  TO authenticated
  USING (
    requester_id = auth.uid()
    AND status = 'draft'
    AND organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid()
    )
  );

-- Admin can delete expense requests
CREATE POLICY "Admin can delete expense requests"
  ON budget.expense_requests FOR DELETE
  TO authenticated
  USING (
    organization_id IN (
      SELECT organization_id FROM public.user_organizations
      WHERE user_id = auth.uid() AND role = 'admin'
    )
  );

-- =====================================================
-- RLS Policies for Expense History
-- =====================================================

-- Users can view history for their own expense requests
CREATE POLICY "Users can view own expense history"
  ON budget.expense_history FOR SELECT
  TO authenticated
  USING (
    expense_request_id IN (
      SELECT id FROM budget.expense_requests
      WHERE requester_id = auth.uid()
    )
  );

-- Ministry leaders can view history for their ministry's expense requests
CREATE POLICY "Ministry leaders can view ministry expense history"
  ON budget.expense_history FOR SELECT
  TO authenticated
  USING (
    expense_request_id IN (
      SELECT id FROM budget.expense_requests
      WHERE ministry_id IN (
        SELECT id FROM budget.ministries
        WHERE leader_id = auth.uid()
      )
    )
  );

-- Admin/Treasury/Finance can view all expense history
CREATE POLICY "Admin/Treasury/Finance can view all expense history"
  ON budget.expense_history FOR SELECT
  TO authenticated
  USING (
    expense_request_id IN (
      SELECT id FROM budget.expense_requests er
      WHERE er.organization_id IN (
        SELECT organization_id FROM public.user_organizations
        WHERE user_id = auth.uid() AND role IN ('admin', 'treasury', 'finance')
      )
    )
  );

-- Authenticated users can insert history (for audit trail)
CREATE POLICY "Authenticated users can insert expense history"
  ON budget.expense_history FOR INSERT
  TO authenticated
  WITH CHECK (actor_id = auth.uid());

-- =====================================================
-- Helper Functions for Budget Management
-- =====================================================

-- Function to get remaining budget for a ministry in a fiscal year
CREATE OR REPLACE FUNCTION budget.get_ministry_remaining_budget(
  _ministry_id UUID,
  _fiscal_year_id UUID
)
RETURNS DECIMAL(12, 2)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = budget, public
AS $$
  SELECT COALESCE(
    (
      SELECT ba.allocated_amount - COALESCE(
        (
          SELECT SUM(er.amount)
          FROM budget.expense_requests er
          WHERE er.ministry_id = _ministry_id
            AND er.fiscal_year_id = _fiscal_year_id
            AND er.status IN ('leader_approved', 'pending_treasury', 'treasury_approved', 'pending_finance', 'completed')
        ),
        0
      )
      FROM budget.budget_allocations ba
      WHERE ba.ministry_id = _ministry_id
        AND ba.fiscal_year_id = _fiscal_year_id
    ),
    0
  )
$$;

-- Function to get total spent by a ministry in a fiscal year
CREATE OR REPLACE FUNCTION budget.get_ministry_total_spent(
  _ministry_id UUID,
  _fiscal_year_id UUID
)
RETURNS DECIMAL(12, 2)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = budget, public
AS $$
  SELECT COALESCE(
    SUM(amount),
    0
  )
  FROM budget.expense_requests
  WHERE ministry_id = _ministry_id
    AND fiscal_year_id = _fiscal_year_id
    AND status = 'completed'
$$;

-- Function to check if user is a ministry leader
CREATE OR REPLACE FUNCTION budget.is_ministry_leader(_user_id UUID, _ministry_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = budget, public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM budget.ministries
    WHERE id = _ministry_id
      AND leader_id = _user_id
  )
$$;

-- Function to get current active fiscal year for an organization
CREATE OR REPLACE FUNCTION budget.get_active_fiscal_year(_organization_id UUID)
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = budget, public
AS $$
  SELECT id
  FROM budget.fiscal_years
  WHERE organization_id = _organization_id
    AND is_active = true
  LIMIT 1
$$;

-- Function to check if user has treasury role
CREATE OR REPLACE FUNCTION budget.is_treasury_user(_user_id UUID, _organization_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_organizations
    WHERE user_id = _user_id
      AND organization_id = _organization_id
      AND role = 'treasury'
  )
$$;

-- Function to check if user has finance role
CREATE OR REPLACE FUNCTION budget.is_finance_user(_user_id UUID, _organization_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_organizations
    WHERE user_id = _user_id
      AND organization_id = _organization_id
      AND role = 'finance'
  )
$$;

-- Function to check if user has admin, treasury, or finance role
CREATE OR REPLACE FUNCTION budget.is_budget_manager(_user_id UUID, _organization_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_organizations
    WHERE user_id = _user_id
      AND organization_id = _organization_id
      AND role IN ('admin', 'treasury', 'finance')
  )
$$;

-- =====================================================
-- Grant permissions on tables to authenticated users
-- =====================================================
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA budget TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA budget TO service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA budget TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA budget TO service_role;

-- =====================================================
-- Data Migration: Populate ministries from existing profiles.ministry_name
-- =====================================================

-- Insert distinct ministry names from profiles table into budget.ministries
-- This migrates existing ministry data to the new budget schema
INSERT INTO budget.ministries (organization_id, name, description, is_active)
SELECT DISTINCT
  p.default_organization_id,
  p.ministry_name,
  'Migrated from profiles.ministry_name' as description,
  true as is_active
FROM public.profiles p
WHERE p.ministry_name IS NOT NULL
  AND p.ministry_name != ''
  AND p.default_organization_id IS NOT NULL
ON CONFLICT (organization_id, name) DO NOTHING;

-- Create initial fiscal year for current year for each organization
INSERT INTO budget.fiscal_years (organization_id, year, name, is_active)
SELECT DISTINCT
  id as organization_id,
  EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER as year,
  EXTRACT(YEAR FROM CURRENT_DATE)::TEXT as name,
  true as is_active
FROM public.organizations
ON CONFLICT (organization_id, year) DO NOTHING;
