-- =====================================================
-- 'member' means no internal tools — enforced, not just hidden
-- =====================================================
--
-- 20260321001500 added the role. On its own it changes nothing, because the
-- policies that guard the internal tools never look at the role at all. Of the
-- 58 policies in this database that consult user_organizations, 26 grant on
-- MERE MEMBERSHIP:
--
--     organization_id IN (
--       SELECT organization_id FROM public.user_organizations
--       WHERE user_id = auth.uid()          -- <- no role filter
--     )
--
-- So "is this person in the branch at all" is the whole test. This migration
-- adds the missing half.
--
-- WHY RESTRICTIVE POLICIES RATHER THAN REWRITING THE 26. Two reasons.
--
--   1. This repo's migration tree is known not to describe production — three
--      migrations cannot ever have run, and 20251125000000 is not replayable.
--      Rewriting a policy means DROP + CREATE against text I cannot verify is
--      what is actually installed. A RESTRICTIVE policy is purely additive: it
--      ANDs with whatever permissive policies really exist, whatever they say.
--   2. It fails closed. A permissive policy I forget to rewrite keeps granting;
--      a restrictive policy I add denies until something explicitly permits.
--
-- The rule for reading what follows: PERMISSIVE policies OR together and decide
-- what you may reach; RESTRICTIVE policies AND over the top and can only ever
-- take away. Nothing below grants anyone anything they did not already have.

-- ---------------------------------------------------------------------------
-- 0. No NULL roles: the five that exist become 'member'
-- ---------------------------------------------------------------------------
--
-- user_organizations.role is nullable, and production holds five NULL rows.
-- They are all Children's Ministry leadership -- Tibarek (both branches), Hana,
-- Biruck and Salem -- who were enrolled by claim_kids_leader_invites without a
-- tier ever being chosen for them.
--
-- NULL currently behaves exactly like contributor, because the policies this
-- migration is fixing never looked at the role. So this IS a demotion, decided
-- deliberately rather than inherited: those five reach the calendar, the budget
-- and the inventory today, and after this they do not.
--
-- What it costs them is small, and that is the additive model working. Kids
-- access rides on church.module_grants, not on the tier, so the desk, the
-- rosters and the overrides are untouched; and kids_admin and kids_leader both
-- carry members.read, so they keep the directory and (via has_internal_access
-- below) budget.ministries. They lose the calendar and the budget, which is
-- what "Children's Ministry leader" was never meant to include.
--
-- The 60 contributors, 12 admins, 3 treasury and 2 finance rows are untouched.

UPDATE public.user_organizations SET role = 'member' WHERE role IS NULL;

ALTER TABLE public.user_organizations
  ALTER COLUMN role SET DEFAULT 'member',
  ALTER COLUMN role SET NOT NULL;

COMMENT ON COLUMN public.user_organizations.role IS
  $c$Exclusive access TIER for this branch - one per (user, organization).
'member' is the floor and reaches no internal tool. Anything a person should
hold ALONGSIDE their tier (kids volunteer, members admin) is additive and
belongs in church.module_grants instead.$c$;

-- ---------------------------------------------------------------------------
-- 1. What "staff" means
-- ---------------------------------------------------------------------------
--
-- An ALLOWLIST, not `role <> 'member'`. A deny-list would make every future
-- enum value staff by default, which is the wrong way for this to fail. Adding
-- a tier means coming back here, and that is the point.
--
-- SECURITY DEFINER so these can read user_organizations from inside policies
-- written in terms of them without recursing. STABLE so the planner caches
-- them within a statement.

CREATE OR REPLACE FUNCTION public.is_staff(_organization_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_organizations
    WHERE user_id = auth.uid()
      AND organization_id = _organization_id
      AND role IN ('admin', 'contributor', 'treasury', 'finance')
  )
$$;

-- For the child tables that carry no organization_id of their own. Their
-- parent's permissive policy still confines the caller to their own branch;
-- this only asks whether they are staff anywhere at all.
CREATE OR REPLACE FUNCTION public.is_staff_anywhere()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_organizations
    WHERE user_id = auth.uid()
      AND role IN ('admin', 'contributor', 'treasury', 'finance')
  )
$$;

-- Staff, OR anyone holding an additive module grant. budget.ministries is the
-- shared ministry master the Members module reads (useReference, servingService,
-- useMyInformation), so a members_viewer on the 'member' tier must still reach
-- it or the directory breaks.
CREATE OR REPLACE FUNCTION public.has_internal_access(_organization_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, church
AS $$
  SELECT public.is_staff(_organization_id)
      OR EXISTS (
        SELECT 1 FROM church.module_grants
        WHERE user_id = auth.uid()
          AND organization_id = _organization_id
      )
$$;

CREATE OR REPLACE FUNCTION public.has_internal_access_anywhere()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, church
AS $$
  SELECT public.is_staff_anywhere()
      OR EXISTS (
        SELECT 1 FROM church.module_grants WHERE user_id = auth.uid()
      )
$$;

REVOKE ALL ON FUNCTION public.is_staff(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_staff_anywhere() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.has_internal_access(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.has_internal_access_anywhere() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_staff(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_staff_anywhere() TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_internal_access(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_internal_access_anywhere() TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. New signups land on the floor, not in the budget
-- ---------------------------------------------------------------------------
--
-- Byte-for-byte 20260321000900 apart from the one literal marked below. The
-- station/kiosk early return, the profile upsert and the invite claim all stay
-- exactly as they were.

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

  INSERT INTO public.profiles (id, full_name, email, default_organization_id)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1)),
    NEW.email,
    va_org_id
  )
  ON CONFLICT (id) DO UPDATE SET
    default_organization_id = COALESCE(profiles.default_organization_id, va_org_id);

  -- THE CHANGE: 'contributor' -> 'member'.
  --
  -- An account nobody has deliberately given a job to now reaches nothing. The
  -- ON CONFLICT DO NOTHING matters as much as the literal: an existing member
  -- of this branch keeps whatever tier they already hold, so re-confirming an
  -- email cannot demote a director to 'member'.
  INSERT INTO public.user_organizations (user_id, organization_id, role, is_primary)
  VALUES (NEW.id, va_org_id, 'member', true)
  ON CONFLICT (user_id, organization_id) DO NOTHING;

  -- Redeem any kids-leadership invitation written for this address. This is
  -- what turns a list of emails from the Children's Ministry into working
  -- access, and it is also what puts an MD leader in MD.
  PERFORM church.claim_kids_leader_invites(NEW.id, NEW.email);

  RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. The internal tools, closed to the floor
-- ---------------------------------------------------------------------------
--
-- One RESTRICTIVE policy per table, FOR ALL, so it covers reads and writes
-- together. Postgres uses the USING expression as the WITH CHECK expression
-- when the latter is omitted; both are spelled out anyway so no one has to
-- remember that.
--
-- DELIBERATELY NOT LISTED, and why:
--
--   public.rooms            Already carries "Public can view active rooms" for
--                           anon, for the public calendar (see 20260320000700).
--                           Restricting it for authenticated users would fence
--                           off a table any stranger can already read straight
--                           out of PostgREST, while breaking the Kids module,
--                           which uses rooms as its classrooms and reads them
--                           from the client in kidsLeaderService and
--                           kidsSessionService. Pure cost, no benefit.
--   public.organizations    A member needs their own branch to resolve or the
--                           app renders "No Organization Found" instead of a
--                           sign-in. Names and addresses of the two branches
--                           are on the public site already.
--   public.user_organizations  Its SELECT policy is already `user_id = auth.uid()`.
--                           AuthContext cannot resolve a role without it.
--   church.*                Every church table is already gated on
--                           module_grants by 20260320000200. Nothing to add.

-- Dropped first so a re-run of this file is clean; Postgres has no
-- CREATE POLICY IF NOT EXISTS.
DROP POLICY IF EXISTS "Members cannot reach fiscal years" ON budget.fiscal_years;
DROP POLICY IF EXISTS "Members cannot reach budget allocations" ON budget.budget_allocations;
DROP POLICY IF EXISTS "Members cannot reach expense requests" ON budget.expense_requests;
DROP POLICY IF EXISTS "Members cannot reach allocation requests" ON budget.allocation_requests;
DROP POLICY IF EXISTS "Members cannot reach ministry flags" ON budget.ministry_flags;
DROP POLICY IF EXISTS "Members cannot reach expense history" ON budget.expense_history;
DROP POLICY IF EXISTS "Members cannot reach allocation request history" ON budget.allocation_request_history;
DROP POLICY IF EXISTS "Members cannot reach allocation period amounts" ON budget.allocation_period_amounts;
DROP POLICY IF EXISTS "Members cannot reach ministries without a grant" ON budget.ministries;
DROP POLICY IF EXISTS "Members read only published events" ON public.events;
DROP POLICY IF EXISTS "Members cannot create events" ON public.events;
DROP POLICY IF EXISTS "Members cannot change events" ON public.events;
DROP POLICY IF EXISTS "Members cannot delete events" ON public.events;
DROP POLICY IF EXISTS "Members see only their own profile" ON public.profiles;

-- Money. Strict staff only — a module grant does not buy a look at the budget.
CREATE POLICY "Members cannot reach fiscal years"
  ON budget.fiscal_years AS RESTRICTIVE FOR ALL TO authenticated
  USING (public.is_staff(organization_id))
  WITH CHECK (public.is_staff(organization_id));

CREATE POLICY "Members cannot reach budget allocations"
  ON budget.budget_allocations AS RESTRICTIVE FOR ALL TO authenticated
  USING (public.is_staff(organization_id))
  WITH CHECK (public.is_staff(organization_id));

CREATE POLICY "Members cannot reach expense requests"
  ON budget.expense_requests AS RESTRICTIVE FOR ALL TO authenticated
  USING (public.is_staff(organization_id))
  WITH CHECK (public.is_staff(organization_id));

CREATE POLICY "Members cannot reach allocation requests"
  ON budget.allocation_requests AS RESTRICTIVE FOR ALL TO authenticated
  USING (public.is_staff(organization_id))
  WITH CHECK (public.is_staff(organization_id));

CREATE POLICY "Members cannot reach ministry flags"
  ON budget.ministry_flags AS RESTRICTIVE FOR ALL TO authenticated
  USING (public.is_staff(organization_id))
  WITH CHECK (public.is_staff(organization_id));

-- Child tables with no organization_id of their own. The parent's permissive
-- policy still confines the caller to their branch.
CREATE POLICY "Members cannot reach expense history"
  ON budget.expense_history AS RESTRICTIVE FOR ALL TO authenticated
  USING (public.is_staff_anywhere())
  WITH CHECK (public.is_staff_anywhere());

CREATE POLICY "Members cannot reach allocation request history"
  ON budget.allocation_request_history AS RESTRICTIVE FOR ALL TO authenticated
  USING (public.is_staff_anywhere())
  WITH CHECK (public.is_staff_anywhere());

CREATE POLICY "Members cannot reach allocation period amounts"
  ON budget.allocation_period_amounts AS RESTRICTIVE FOR ALL TO authenticated
  USING (public.is_staff_anywhere())
  WITH CHECK (public.is_staff_anywhere());

-- The shared ministry master. Staff OR a module grant, because the Members
-- directory resolves ministry names out of this table.
CREATE POLICY "Members cannot reach ministries without a grant"
  ON budget.ministries AS RESTRICTIVE FOR ALL TO authenticated
  USING (public.has_internal_access(organization_id))
  WITH CHECK (public.has_internal_access(organization_id));

-- The approval agenda itself. Nothing in church/kids reads public.events.
--
-- SPLIT BY COMMAND, not FOR ALL, for two reasons.
--
--   Reads let published events through. "Public can view published events" is
--   TO anon (20251031060000), so a logged-OUT stranger sees the public calendar
--   at /public. A FOR ALL restrictive policy would have shown that same page
--   empty to a signed-in member — hiding from a member exactly what any
--   passer-by can already read, which protects nothing and looks broken.
--
--   Writes do not. Spelling INSERT/UPDATE/DELETE separately is what keeps
--   `status = 'published'` out of the DELETE path: DELETE consults USING only,
--   so folding this into one FOR ALL policy would have let a member delete a
--   published event if any permissive DELETE policy admitted them.
CREATE POLICY "Members read only published events"
  ON public.events AS RESTRICTIVE FOR SELECT TO authenticated
  USING (status = 'published' OR public.is_staff(organization_id));

CREATE POLICY "Members cannot create events"
  ON public.events AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (public.is_staff(organization_id));

CREATE POLICY "Members cannot change events"
  ON public.events AS RESTRICTIVE FOR UPDATE TO authenticated
  USING (public.is_staff(organization_id))
  WITH CHECK (public.is_staff(organization_id));

CREATE POLICY "Members cannot delete events"
  ON public.events AS RESTRICTIVE FOR DELETE TO authenticated
  USING (public.is_staff(organization_id));

-- Staff directory. A member sees themselves and nobody else; anyone with any
-- internal business keeps the behaviour they have today.
CREATE POLICY "Members see only their own profile"
  ON public.profiles AS RESTRICTIVE FOR ALL TO authenticated
  USING (id = auth.uid() OR public.has_internal_access_anywhere())
  WITH CHECK (id = auth.uid() OR public.has_internal_access_anywhere());

NOTIFY pgrst, 'reload schema';
