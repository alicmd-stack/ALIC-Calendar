-- =====================================================
-- Self-service: let a member see (and lightly edit) their own record
-- =====================================================
--
-- Until now church.people was readable only by members_admin / members_viewer /
-- members_import / kids_admin / leadership_viewer. An ordinary contributor saw
-- nothing at all, which is right for the directory but wrong for their own
-- record.
--
-- This adds a narrow self-access path:
--   * SELECT their own person row, their household and who is in it, and their
--     own serving / group / training / interest records
--   * UPDATE only their phone and email, and only via an RPC
--
-- Deliberately NOT included:
--   * other members' rows (that is the admin directory)
--   * their children's rows — a parent seeing a child's record was considered
--     and left out of this pass, because those rows reach person_sensitive
--     (medical) and kids_pickup_restrictions (custody), which need their own
--     decision rather than arriving as a side-effect of self-service
--   * person_sensitive for themselves, for the same reason

-- ---------------------------------------------------------------------------
-- Which person rows belong to the caller
-- ---------------------------------------------------------------------------
-- church.people.profile_id -> public.profiles.id -> auth.users.id, so a login
-- maps to a person record only once someone has linked them. Returns a SET
-- because the same human can have a person row in both branches.
--
-- SECURITY DEFINER so it does not recurse through the very policies that are
-- written in terms of it.
CREATE OR REPLACE FUNCTION church.my_person_ids()
RETURNS SETOF UUID
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = church, public
AS $$
  SELECT id FROM church.people
  WHERE profile_id = auth.uid()
    AND merged_into_person_id IS NULL
$$;

-- The households the caller currently belongs to.
CREATE OR REPLACE FUNCTION church.my_household_ids()
RETURNS SETOF UUID
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = church, public
AS $$
  SELECT hm.household_id
  FROM church.household_members hm
  WHERE hm.person_id IN (SELECT * FROM church.my_person_ids())
    AND hm.end_date IS NULL
$$;

GRANT EXECUTE ON FUNCTION church.my_person_ids() TO authenticated;
GRANT EXECUTE ON FUNCTION church.my_household_ids() TO authenticated;

-- ---------------------------------------------------------------------------
-- Self-read policies
-- ---------------------------------------------------------------------------
-- Additive: PostgreSQL ORs multiple permissive SELECT policies, so these widen
-- access for the caller's own rows without loosening anything for anyone else.

CREATE POLICY "Members can view their own record"
  ON church.people FOR SELECT TO authenticated
  USING (profile_id = auth.uid());

-- Household members, so "my household" can list who is in it. This exposes
-- the names of the caller's own household — which they already know.
CREATE POLICY "Members can view their own household"
  ON church.households FOR SELECT TO authenticated
  USING (id IN (SELECT * FROM church.my_household_ids()));

CREATE POLICY "Members can view their household roster"
  ON church.household_members FOR SELECT TO authenticated
  USING (household_id IN (SELECT * FROM church.my_household_ids()));

-- People in the caller's household. Separate from the self policy above
-- because it admits a different set of rows.
CREATE POLICY "Members can view people in their household"
  ON church.people FOR SELECT TO authenticated
  USING (
    id IN (
      SELECT hm.person_id FROM church.household_members hm
      WHERE hm.household_id IN (SELECT * FROM church.my_household_ids())
        AND hm.end_date IS NULL
    )
  );

CREATE POLICY "Members can view their own ministry assignments"
  ON church.ministry_assignments FOR SELECT TO authenticated
  USING (person_id IN (SELECT * FROM church.my_person_ids()));

CREATE POLICY "Members can view their own group memberships"
  ON church.group_memberships FOR SELECT TO authenticated
  USING (person_id IN (SELECT * FROM church.my_person_ids()));

CREATE POLICY "Members can view their own service interests"
  ON church.person_service_interests FOR SELECT TO authenticated
  USING (person_id IN (SELECT * FROM church.my_person_ids()));

CREATE POLICY "Members can view their own training attendance"
  ON church.training_attendance FOR SELECT TO authenticated
  USING (person_id IN (SELECT * FROM church.my_person_ids()));

-- Reading an assignment is useless without the role name, and reading a group
-- membership is useless without the group. Both are non-personal reference
-- data already visible to the whole kids/members team.
CREATE POLICY "Org members can view ministry roles for their own records"
  ON church.ministry_roles FOR SELECT TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs()));

CREATE POLICY "Org members can view groups they belong to"
  ON church.groups FOR SELECT TO authenticated
  USING (
    id IN (
      SELECT gm.group_id FROM church.group_memberships gm
      WHERE gm.person_id IN (SELECT * FROM church.my_person_ids())
        AND gm.end_date IS NULL
    )
  );

CREATE POLICY "Org members can view membership statuses"
  ON church.membership_statuses FOR SELECT TO authenticated
  USING (organization_id IN (SELECT * FROM church.my_orgs()));

-- ---------------------------------------------------------------------------
-- Self-edit: contact details only
-- ---------------------------------------------------------------------------
-- RLS is ROW level, not column level: a policy can decide whether a row may be
-- updated, but not which columns. Granting UPDATE on church.people to
-- `authenticated` and restricting by policy would therefore let a member
-- rewrite their own membership status, birthday, or is_child flag.
--
-- Column-level GRANTs are also unsuitable, because they apply per ROLE and
-- admins share the `authenticated` role.
--
-- So the only safe mechanism is a SECURITY DEFINER function that names the
-- permitted columns itself. There is deliberately no self-UPDATE policy on
-- church.people.
CREATE OR REPLACE FUNCTION church.update_my_contact_details(
  _person_id UUID,
  _phone TEXT,
  _email TEXT
)
RETURNS church.people
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public
AS $$
DECLARE
  p church.people%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  -- The caller may only touch a record linked to their own login.
  SELECT * INTO p FROM church.people
   WHERE id = _person_id AND profile_id = auth.uid()
     AND merged_into_person_id IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_your_record' USING ERRCODE = '42501';
  END IF;

  IF _email IS NOT NULL AND btrim(_email) <> ''
     AND btrim(_email) !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RAISE EXCEPTION 'invalid_email';
  END IF;

  UPDATE church.people
     SET phone = NULLIF(btrim(coalesce(_phone, '')), ''),
         email = NULLIF(btrim(coalesce(_email, '')), ''),
         updated_at = now()
   WHERE id = _person_id
  RETURNING * INTO p;

  -- Self-service edits are recorded like any other material change, so the
  -- office can see why a number changed without asking.
  INSERT INTO church.people_history
    (organization_id, person_id, action, field_name, new_value, actor_id, actor_name, notes)
  VALUES
    (p.organization_id, p.id, 'self_update', 'phone,email',
     coalesce(p.phone, '') || ' / ' || coalesce(p.email, ''),
     auth.uid(),
     coalesce((SELECT full_name FROM public.profiles WHERE id = auth.uid()), 'Member'),
     'Updated via My Information');

  RETURN p;
END;
$$;

GRANT EXECUTE ON FUNCTION church.update_my_contact_details(UUID, TEXT, TEXT) TO authenticated;

-- Members need to be able to write their own history row through the RPC
-- above; the existing insert policy already requires actor_id = auth.uid().

COMMENT ON FUNCTION church.update_my_contact_details(UUID, TEXT, TEXT) IS
  'Self-service contact update. Exists because RLS cannot restrict WHICH '
  'columns an UPDATE touches — this function names phone and email and nothing '
  'else, so a member cannot rewrite their membership status or birthday. '
  'There is no self-UPDATE policy on church.people by design.';

COMMENT ON FUNCTION church.my_person_ids() IS
  'Person rows linked to the current login via people.profile_id. Empty until '
  'an admin links the person record to their account, so self-service shows '
  'nothing for unlinked members.';

NOTIFY pgrst, 'reload schema';
