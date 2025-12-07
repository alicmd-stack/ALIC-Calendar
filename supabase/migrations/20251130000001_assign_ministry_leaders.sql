-- =====================================================
-- Assign Ministry Leaders from profiles.ministry_name
-- This matches users to ministries based on their ministry_name in profiles
-- =====================================================

-- Update budget.ministries with leader_id from profiles
-- For each ministry, find a user whose ministry_name matches and assign them as leader
-- Uses a subquery to get the first matching user (by created_at) for each ministry
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
