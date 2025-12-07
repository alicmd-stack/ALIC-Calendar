-- =====================================================
-- Add Fiscal Year 2026 and Auto-Create Future Years
-- =====================================================

-- =====================================================
-- 1. Add 2026 fiscal year for all organizations
-- =====================================================
INSERT INTO budget.fiscal_years (organization_id, year, name, is_active)
SELECT
  id as organization_id,
  2026 as year,
  '2026' as name,
  false as is_active
FROM public.organizations
ON CONFLICT (organization_id, year) DO NOTHING;

-- =====================================================
-- 2. Create function to auto-create next fiscal year
-- =====================================================
CREATE OR REPLACE FUNCTION budget.ensure_next_fiscal_year()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = budget, public
AS $$
DECLARE
  current_year INTEGER := EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER;
  next_year INTEGER := current_year + 1;
BEGIN
  -- Insert next year's fiscal year for all organizations that don't have it yet
  INSERT INTO budget.fiscal_years (organization_id, year, name, is_active)
  SELECT
    o.id as organization_id,
    next_year as year,
    next_year::TEXT as name,
    false as is_active
  FROM public.organizations o
  WHERE NOT EXISTS (
    SELECT 1
    FROM budget.fiscal_years fy
    WHERE fy.organization_id = o.id
      AND fy.year = next_year
  );

  -- Log how many were created (for debugging via pg_cron logs)
  RAISE NOTICE 'Ensured fiscal year % exists for all organizations', next_year;
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION budget.ensure_next_fiscal_year() TO service_role;

-- =====================================================
-- 3. Schedule cron job to run on January 1st each year
-- Note: pg_cron must be enabled in Supabase project settings
-- =====================================================

-- Enable pg_cron extension if not already enabled
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Schedule the job to run at midnight on January 1st each year
-- Cron format: minute hour day-of-month month day-of-week
SELECT cron.schedule(
  'ensure-next-fiscal-year',  -- job name
  '0 0 1 1 *',                -- At 00:00 on January 1st
  $$SELECT budget.ensure_next_fiscal_year()$$
);

-- =====================================================
-- 4. Run the function now to ensure next year exists
-- =====================================================
SELECT budget.ensure_next_fiscal_year();
