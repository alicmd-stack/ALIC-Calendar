-- =====================================================
-- Sync ministries for organization b1eebc99-9c0b-4ef8-bb6d-6bb9bd380a22
-- and create trigger to auto-sync ministries for future users
-- =====================================================

-- Step 1: Insert ministries for all users in the new organization
-- that don't already exist in budget.ministries
INSERT INTO budget.ministries (organization_id, name, description, is_active)
SELECT DISTINCT
  p.default_organization_id,
  p.ministry_name,
  'Auto-created from profiles.ministry_name' as description,
  true as is_active
FROM public.profiles p
WHERE p.ministry_name IS NOT NULL
  AND p.ministry_name != ''
  AND p.default_organization_id IS NOT NULL
ON CONFLICT (organization_id, name) DO NOTHING;

-- Step 2: Assign ministry leaders from profiles
-- For each ministry without a leader, find a user whose ministry_name matches
UPDATE budget.ministries m
SET leader_id = (
  SELECT p.id
  FROM public.profiles p
  WHERE p.ministry_name = m.name
    AND p.default_organization_id = m.organization_id
  ORDER BY p.created_at ASC
  LIMIT 1
)
WHERE m.leader_id IS NULL;

-- Step 3: Create a function to auto-create ministry when profile is created/updated
CREATE OR REPLACE FUNCTION public.sync_ministry_from_profile()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, budget
AS $$
BEGIN
  -- Only proceed if ministry_name is set and organization is set
  IF NEW.ministry_name IS NOT NULL
     AND NEW.ministry_name != ''
     AND NEW.default_organization_id IS NOT NULL THEN

    -- Insert the ministry if it doesn't exist
    INSERT INTO budget.ministries (organization_id, name, description, is_active)
    VALUES (
      NEW.default_organization_id,
      NEW.ministry_name,
      'Auto-created from profiles.ministry_name',
      true
    )
    ON CONFLICT (organization_id, name) DO NOTHING;

    -- If this is a new ministry (no leader yet), set this user as the leader
    UPDATE budget.ministries
    SET leader_id = NEW.id
    WHERE organization_id = NEW.default_organization_id
      AND name = NEW.ministry_name
      AND leader_id IS NULL;
  END IF;

  RETURN NEW;
END;
$$;

-- Step 4: Create trigger on profiles table for INSERT and UPDATE
DROP TRIGGER IF EXISTS sync_ministry_on_profile_change ON public.profiles;

CREATE TRIGGER sync_ministry_on_profile_change
  AFTER INSERT OR UPDATE OF ministry_name, default_organization_id
  ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_ministry_from_profile();

-- Step 5: Create fiscal year for the new organization if it doesn't exist
INSERT INTO budget.fiscal_years (organization_id, year, name, is_active)
SELECT DISTINCT
  p.default_organization_id as organization_id,
  EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER as year,
  EXTRACT(YEAR FROM CURRENT_DATE)::TEXT as name,
  true as is_active
FROM public.profiles p
WHERE p.default_organization_id IS NOT NULL
ON CONFLICT (organization_id, year) DO NOTHING;
