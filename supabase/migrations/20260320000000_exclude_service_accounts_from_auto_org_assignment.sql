-- =====================================================
-- Exclude station / service accounts from automatic organization assignment
-- =====================================================
--
-- WHY
-- ---
-- 20251225000002 made handle_new_user() enrol EVERY newly confirmed auth user
-- into ALIC VA - Springfield as a 'contributor'. That is correct for a person
-- signing up, but it is a serious problem for the Kids Ministry check-in
-- stations, which sign in as long-lived shared device accounts on a tablet
-- sitting in the church lobby.
--
-- Without this change, creating a station account would silently grant that
-- tablet contributor-level read access to VA profiles, events, rooms and the
-- entire budget schema, because almost every RLS policy in this database is
-- written as:
--
--   organization_id IN (SELECT organization_id FROM public.user_organizations
--                       WHERE user_id = auth.uid())
--
-- A station must therefore have NO row in user_organizations at all. That is
-- what makes it inherit nothing, and forces every check-in operation to go
-- through an explicitly granted SECURITY DEFINER RPC instead.
--
-- HOW
-- ---
-- The marker lives in raw_app_meta_data, NOT raw_user_meta_data. This matters:
-- raw_user_meta_data is writable by the user themselves via
-- supabase.auth.updateUser(), so a normal user could set account_type and opt
-- out of org assignment. raw_app_meta_data is writable only through the
-- service-role Admin API, which is how station accounts are provisioned.
--
-- Behaviour for ordinary users is unchanged.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  va_org_id UUID := 'b1eebc99-9c0b-4ef8-bb6d-6bb9bd380a22';
  _account_type TEXT := COALESCE(NEW.raw_app_meta_data->>'account_type', 'user');
BEGIN
  -- Only act once the user has confirmed their email (completed invite signup)
  IF NEW.email_confirmed_at IS NULL THEN
    RETURN NEW;
  END IF;

  -- Station / kiosk / service accounts: profile row only.
  -- No user_organizations row, no user_roles row, therefore no inherited
  -- access to any existing org-scoped policy anywhere in the database.
  IF _account_type IN ('station', 'kiosk', 'service') THEN
    INSERT INTO public.profiles (id, full_name, email, default_organization_id)
    VALUES (
      NEW.id,
      COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1)),
      NEW.email,
      NULL
    )
    ON CONFLICT (id) DO NOTHING;

    RETURN NEW;
  END IF;

  -- Ordinary users: unchanged from 20251225000002.
  INSERT INTO public.profiles (id, full_name, email, default_organization_id)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1)),
    NEW.email,
    va_org_id
  )
  ON CONFLICT (id) DO UPDATE SET
    default_organization_id = COALESCE(profiles.default_organization_id, va_org_id);

  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, 'contributor')
  ON CONFLICT (user_id, role) DO NOTHING;

  INSERT INTO public.user_organizations (user_id, organization_id, role, is_primary)
  VALUES (NEW.id, va_org_id, 'contributor', true)
  ON CONFLICT (user_id, organization_id) DO NOTHING;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.handle_new_user() IS
  'Provisions a profile for a newly confirmed auth user. Accounts marked '
  '{"account_type":"station"|"kiosk"|"service"} in raw_app_meta_data get a '
  'profile only, with no organization membership, so shared-device accounts '
  'inherit no org-scoped access. See 20260320000000.';

-- The on_auth_user_created trigger already exists and is unchanged.
