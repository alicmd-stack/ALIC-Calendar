-- =====================================================
-- Somewhere to actually grant a permission
-- =====================================================
--
-- church.module_grants has existed since 20260320000200, with an enum, RLS
-- policies and six helper functions built on it. Nothing in the application
-- has ever written a row: `grep -rn module_grants src` finds one comment, one
-- SELECT, and the generated type. Production holds ZERO grants against 62
-- logins.
--
-- The consequence is that resolveCapabilities() only ever returns a non-empty
-- set through its `if (isOrgAdmin)` branch. Every route gated on requireAny —
-- /members, /members/import, /kids, /checkin — admits org admins and nobody
-- else, and the four roles the permission model exists to serve
-- (kids_volunteer, members_viewer, members_import, leadership_viewer) are
-- unreachable without hand-written SQL.
--
-- So every non-admin feature shipped for the Kids and Members modules —
-- classroom teachers, the volunteers tab, the whole "a kids_admin who is not
-- an org admin" story — is code-complete with no possible user. At Silver
-- Spring that is 6 people who can staff a desk out of 37.

-- ---------------------------------------------------------------------------
-- Everyone in the branch, with what they currently hold
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.org_people_for_grants(_organization_id UUID)
RETURNS TABLE (
  user_id UUID,
  full_name TEXT,
  email TEXT,
  app_role TEXT,
  is_org_admin BOOLEAN,
  permissions church.module_permission[],
  person_id UUID
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
BEGIN
  -- Granting permissions is an organization-admin act, not a module one: a
  -- members_admin must not be able to promote themselves to kids_admin.
  IF _organization_id NOT IN (SELECT church.my_admin_orgs()) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    pr.id,
    pr.full_name,
    pr.email,
    uo.role::TEXT,
    uo.role::TEXT = 'admin',
    coalesce(g.perms, ARRAY[]::church.module_permission[]),
    p.id
  FROM public.user_organizations uo
  JOIN public.profiles pr ON pr.id = uo.user_id
  LEFT JOIN LATERAL (
    SELECT array_agg(mg.permission ORDER BY mg.permission) AS perms
    FROM church.module_grants mg
    WHERE mg.user_id = uo.user_id
      AND mg.organization_id = _organization_id
  ) g ON true
  -- Shown so an admin can see at a glance who has no member record yet, which
  -- is what keeps self-service and volunteer eligibility switched off for them.
  LEFT JOIN church.people p
    ON p.profile_id = pr.id AND p.organization_id = _organization_id
  WHERE uo.organization_id = _organization_id
  ORDER BY (uo.role::TEXT = 'admin') DESC, pr.full_name;
END;
$$;

GRANT EXECUTE ON FUNCTION church.org_people_for_grants(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Set someone's permissions to exactly this list
-- ---------------------------------------------------------------------------
--
-- Replace rather than add/remove one at a time: the screen shows a set of
-- tickboxes, and "what I see is what they have" is the only reading of that
-- which cannot drift.
CREATE OR REPLACE FUNCTION church.set_module_grants(
  _user_id UUID,
  _organization_id UUID,
  _permissions church.module_permission[]
)
RETURNS church.module_permission[]
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _actor TEXT;
  _result church.module_permission[];
BEGIN
  IF _organization_id NOT IN (SELECT church.my_admin_orgs()) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  -- Only somebody who belongs to this branch can hold permissions in it.
  IF NOT EXISTS (
    SELECT 1 FROM public.user_organizations uo
    WHERE uo.user_id = _user_id AND uo.organization_id = _organization_id
  ) THEN
    RAISE EXCEPTION 'not_a_member_of_this_branch';
  END IF;

  _actor := coalesce(
    (SELECT full_name FROM public.profiles WHERE id = auth.uid()), 'System');

  DELETE FROM church.module_grants mg
   WHERE mg.user_id = _user_id
     AND mg.organization_id = _organization_id
     AND (_permissions IS NULL OR NOT (mg.permission = ANY(_permissions)));

  INSERT INTO church.module_grants (
    user_id, organization_id, permission, granted_by, granted_by_name)
  SELECT _user_id, _organization_id, p, auth.uid(), _actor
  FROM unnest(coalesce(_permissions, ARRAY[]::church.module_permission[])) AS p
  ON CONFLICT (user_id, organization_id, permission) DO NOTHING;

  SELECT array_agg(mg.permission ORDER BY mg.permission) INTO _result
  FROM church.module_grants mg
  WHERE mg.user_id = _user_id AND mg.organization_id = _organization_id;

  RETURN coalesce(_result, ARRAY[]::church.module_permission[]);
END;
$$;

GRANT EXECUTE ON FUNCTION church.set_module_grants(
  UUID, UUID, church.module_permission[]) TO authenticated;

NOTIFY pgrst, 'reload schema';
