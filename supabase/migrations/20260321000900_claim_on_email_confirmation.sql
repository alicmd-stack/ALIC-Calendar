-- =====================================================
-- Signup setup must also fire when the email is confirmed later
-- =====================================================
--
-- handle_new_user returns early while email_confirmed_at IS NULL — correct,
-- because an unconfirmed address should not yet buy branch membership. But the
-- only trigger was AFTER INSERT, and confirmation almost never happens during
-- the insert:
--
--   * a normal signup inserts the row unconfirmed, then UPDATEs it when the
--     user clicks the link in their email;
--   * the Admin API's email_confirm flag likewise stamps email_confirmed_at in
--     a follow-up UPDATE.
--
-- Either way the INSERT-time check fails, the function returns, and the UPDATE
-- never re-fires it. Six kids-ministry accounts were created this way and
-- received NO profile row, no branch membership and no grant — the invitation
-- machinery was correct and simply never ran.
--
-- AND A SECOND FAULT THE FIRST ONE WAS HIDING. handle_new_user also did
--
--     INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'contributor')
--
-- but public.user_roles has no `role` column. It has role_id, a FK to
-- public.roles — which is the INVENTORY role table (ministry_leader,
-- asset_manager, system_admin) with no 'contributor' row to point at. That
-- statement could only ever have thrown. It never did, because the function
-- returned at the confirmation check first. Adding the UPDATE trigger without
-- also removing it would have turned a silent no-op into a hard failure on
-- every signup. Only 11 of 75 users have a user_roles row, which is what a
-- statement that has never run looks like.
--
-- Membership is carried by user_organizations.role, which does work and is
-- untouched.

CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- The user_roles INSERT that used to sit here named a column that does not
  -- exist. public.user_roles has role_id, a FK to public.roles, which is the
  -- INVENTORY role table — ministry_leader, asset_manager, system_admin. There
  -- is no 'contributor' row to point at, so the statement could only ever have
  -- thrown. It never did, because the trigger was INSERT-only and this function
  -- returned before reaching it; the two faults hid each other. Membership is
  -- carried by user_organizations.role below, which does work.

  INSERT INTO public.user_organizations (user_id, organization_id, role, is_primary)
  VALUES (NEW.id, va_org_id, 'contributor', true)
  ON CONFLICT (user_id, organization_id) DO NOTHING;

  -- Redeem any kids-leadership invitation written for this address. This is
  -- what turns a list of emails from the Children's Ministry into working
  -- access, and it is also what puts an MD leader in MD: the block above has
  -- just enrolled them in VA, which is not where they serve.
  PERFORM church.claim_kids_leader_invites(NEW.id, NEW.email);

  RETURN NEW;
END;
$function$
;

DROP TRIGGER IF EXISTS on_auth_user_confirmed ON auth.users;
CREATE TRIGGER on_auth_user_confirmed
  AFTER UPDATE OF email_confirmed_at ON auth.users
  FOR EACH ROW
  WHEN (OLD.email_confirmed_at IS NULL AND NEW.email_confirmed_at IS NOT NULL)
  EXECUTE FUNCTION public.handle_new_user();

-- Repair every confirmed account that never got its setup, then redeem any
-- invitation waiting on that address. Both halves are idempotent.
DO $do$
DECLARE
  u RECORD;
  va_org UUID := 'b1eebc99-9c0b-4ef8-bb6d-6bb9bd380a22';
BEGIN
  FOR u IN
    SELECT au.id, au.email, au.raw_user_meta_data, au.raw_app_meta_data
    FROM auth.users au
    LEFT JOIN public.profiles p ON p.id = au.id
    WHERE au.email_confirmed_at IS NOT NULL
      AND p.id IS NULL
  LOOP
    IF coalesce(u.raw_app_meta_data->>'account_type', 'user')
       IN ('station', 'kiosk', 'service') THEN
      INSERT INTO public.profiles (id, full_name, email, default_organization_id)
      VALUES (u.id,
              coalesce(u.raw_user_meta_data->>'full_name', split_part(u.email, '@', 1)),
              u.email, NULL)
      ON CONFLICT (id) DO NOTHING;
      CONTINUE;
    END IF;

    INSERT INTO public.profiles (id, full_name, email, default_organization_id)
    VALUES (u.id,
            coalesce(u.raw_user_meta_data->>'full_name', split_part(u.email, '@', 1)),
            u.email, va_org)
    ON CONFLICT (id) DO UPDATE
      SET default_organization_id = coalesce(profiles.default_organization_id, va_org);

    INSERT INTO public.user_organizations (user_id, organization_id, role, is_primary)
    VALUES (u.id, va_org, 'contributor', true)
    ON CONFLICT (user_id, organization_id) DO NOTHING;

    PERFORM church.claim_kids_leader_invites(u.id, u.email);
  END LOOP;
END $do$;

NOTIFY pgrst, 'reload schema';
