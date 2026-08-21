-- =====================================================
-- Kids ministry leaders, and team leads scoped to their grades
-- =====================================================
--
-- The Children's Ministry has two directors who need everything, and four team
-- leads who each run a band of grades:
--
--   Azeb Asegedom   Pre-K, Kindergarten, Grade 1   (Joy A, Joy B, Joy C)
--   Hana            Grades 2-3                     (Blossom A, Blossom B)
--   Biruck Feysa    Grades 4-5                     (Shine A, Shine B)
--   Salem           Grades 6-8                     (Redeemed A, B, C)
--
-- TWO THINGS DID NOT EXIST, and this migration adds both.
--
-- 1. SCOPE. church.module_grants is keyed on (user_id, organization_id,
--    permission) and nothing else, so kids_admin has always meant the whole
--    branch. "Full access to their grades" is a new idea, not a setting.
--
--    kids_leader_scope narrows a grant to specific rooms. NO ROWS FOR A USER
--    MEANS THE WHOLE BRANCH — so the two directors need no scope rows, and
--    every existing kids_admin keeps working exactly as before. Absence is the
--    permissive case on purpose: a scope table that silently locked people out
--    when it shipped empty would take the board down on a Sunday morning.
--
-- 2. A WAY TO AUTHORISE SOMEBODY WHO HAS NEVER LOGGED IN. module_grants.user_id
--    is NOT NULL and references an auth user. None of these six has an account,
--    so their access cannot be written today at all.
--
--    kids_leader_invites holds the intent, keyed by email. handle_new_user
--    redeems it the moment they confirm their address: it adds the branch
--    membership, writes the grant, applies the scope, and links their login to
--    the person record. The leader hands over a list of emails and the access
--    switches itself on.
--
--    This also fixes a trap they would otherwise hit. handle_new_user enrols
--    every ordinary new user into ALIC **VA** — these six are MD, so without
--    redemption they would sign up into the wrong branch and see nothing.

-- ---------------------------------------------------------------- scope

CREATE TABLE IF NOT EXISTS church.kids_leader_scope (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  room_id UUID NOT NULL REFERENCES public.rooms(id) ON DELETE CASCADE,
  granted_by UUID,
  granted_by_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_kids_leader_scope UNIQUE (user_id, organization_id, room_id)
);

CREATE INDEX IF NOT EXISTS idx_kids_leader_scope_user
  ON church.kids_leader_scope (user_id, organization_id);

ALTER TABLE church.kids_leader_scope ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS kids_leader_scope_select ON church.kids_leader_scope;
CREATE POLICY kids_leader_scope_select ON church.kids_leader_scope
  FOR SELECT TO authenticated
  USING (organization_id IN (SELECT church.my_orgs()));

DROP POLICY IF EXISTS kids_leader_scope_write ON church.kids_leader_scope;
CREATE POLICY kids_leader_scope_write ON church.kids_leader_scope
  FOR ALL TO authenticated
  USING (organization_id IN (SELECT church.my_admin_orgs()))
  WITH CHECK (organization_id IN (SELECT church.my_admin_orgs()));

GRANT SELECT ON church.kids_leader_scope TO authenticated;
GRANT ALL ON church.kids_leader_scope TO service_role;

/**
 * True when this leader sees the whole branch.
 *
 * The permissive default. Every kids_admin who existed before this migration
 * has no scope rows and therefore keeps full access.
 */
CREATE OR REPLACE FUNCTION church.kids_leader_sees_all_rooms(_organization_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM church.kids_leader_scope s
    WHERE s.user_id = auth.uid()
      AND s.organization_id = _organization_id
  );
$$;

/**
 * The rooms this leader may work with, as a set of ids.
 *
 * Returns every check-in classroom when unscoped, so callers can filter on it
 * unconditionally without special-casing the directors.
 */
CREATE OR REPLACE FUNCTION church.kids_leader_room_ids(_organization_id UUID)
RETURNS SETOF UUID
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
  SELECT s.room_id
  FROM church.kids_leader_scope s
  WHERE s.user_id = auth.uid()
    AND s.organization_id = _organization_id
  UNION ALL
  SELECT k.room_id
  FROM church.room_kids_config k
  WHERE k.organization_id = _organization_id
    AND k.is_checkin_location
    AND church.kids_leader_sees_all_rooms(_organization_id);
$$;

REVOKE ALL ON FUNCTION church.kids_leader_sees_all_rooms(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION church.kids_leader_room_ids(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION church.kids_leader_sees_all_rooms(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION church.kids_leader_room_ids(UUID) TO authenticated;

-- ---------------------------------------------------------------- invites

CREATE TABLE IF NOT EXISTS church.kids_leader_invites (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  -- Lower-cased on write. Email is the only handle we have before they exist.
  email TEXT NOT NULL,
  display_name TEXT NOT NULL,
  permission church.module_permission NOT NULL DEFAULT 'kids_admin',
  /* Empty or NULL means the whole branch — the same permissive rule as
     kids_leader_scope, so a director and a team lead use one mechanism. */
  scope_room_ids UUID[],
  /** Optional existing person to link the new login to. */
  person_id UUID REFERENCES church.people(id) ON DELETE SET NULL,
  claimed_at TIMESTAMPTZ,
  claimed_user_id UUID,
  created_by UUID,
  created_by_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_kids_leader_invite UNIQUE (organization_id, email, permission)
);

CREATE INDEX IF NOT EXISTS idx_kids_leader_invites_email
  ON church.kids_leader_invites (lower(email)) WHERE claimed_at IS NULL;

ALTER TABLE church.kids_leader_invites ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS kids_leader_invites_admin ON church.kids_leader_invites;
CREATE POLICY kids_leader_invites_admin ON church.kids_leader_invites
  FOR ALL TO authenticated
  USING (organization_id IN (SELECT church.my_admin_orgs()))
  WITH CHECK (organization_id IN (SELECT church.my_admin_orgs()));

GRANT SELECT, INSERT, UPDATE, DELETE ON church.kids_leader_invites TO authenticated;
GRANT ALL ON church.kids_leader_invites TO service_role;

/**
 * Redeem every outstanding invitation for this address.
 *
 * Called from handle_new_user, which runs as the definer during signup, so
 * there is no auth.uid() to check against — the email having been confirmed IS
 * the authorisation, and the invitation was written by an org admin.
 *
 * Idempotent: claimed invitations are skipped, and every insert is ON CONFLICT
 * DO NOTHING, so a re-run cannot double-grant.
 */
CREATE OR REPLACE FUNCTION church.claim_kids_leader_invites(_user_id UUID, _email TEXT)
RETURNS INTEGER
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  inv RECORD;
  _n INTEGER := 0;
  _room UUID;
BEGIN
  IF _user_id IS NULL OR coalesce(btrim(_email), '') = '' THEN
    RETURN 0;
  END IF;

  FOR inv IN
    SELECT * FROM church.kids_leader_invites
    WHERE lower(email) = lower(btrim(_email))
      AND claimed_at IS NULL
  LOOP
    -- Branch membership first. Without it my_orgs() is empty and the grant
    -- below would be invisible — and handle_new_user has already put this user
    -- in ALIC VA, which is not where these leaders serve.
    INSERT INTO public.user_organizations (user_id, organization_id, role, is_primary)
    VALUES (_user_id, inv.organization_id, 'contributor', false)
    ON CONFLICT (user_id, organization_id) DO NOTHING;

    INSERT INTO church.module_grants
      (user_id, organization_id, permission, granted_by_name, notes)
    VALUES (_user_id, inv.organization_id, inv.permission,
            coalesce(inv.created_by_name, 'Invitation'),
            'Claimed from kids leader invitation')
    ON CONFLICT (user_id, organization_id, permission) DO NOTHING;

    IF inv.scope_room_ids IS NOT NULL AND array_length(inv.scope_room_ids, 1) > 0 THEN
      FOREACH _room IN ARRAY inv.scope_room_ids LOOP
        INSERT INTO church.kids_leader_scope
          (user_id, organization_id, room_id, granted_by_name)
        VALUES (_user_id, inv.organization_id, _room,
                coalesce(inv.created_by_name, 'Invitation'))
        ON CONFLICT (user_id, organization_id, room_id) DO NOTHING;
      END LOOP;
    END IF;

    -- Tie the login to the directory record, so the board can attribute their
    -- actions and start_my_shift stops raising no_member_record.
    IF inv.person_id IS NOT NULL THEN
      UPDATE church.people SET profile_id = _user_id, updated_at = now()
       WHERE id = inv.person_id AND profile_id IS NULL;
    END IF;

    UPDATE church.kids_leader_invites
       SET claimed_at = now(), claimed_user_id = _user_id, updated_at = now()
     WHERE id = inv.id;

    _n := _n + 1;
  END LOOP;

  RETURN _n;
END;
$$;

REVOKE ALL ON FUNCTION church.claim_kids_leader_invites(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION church.claim_kids_leader_invites(UUID, TEXT) TO service_role;

NOTIFY pgrst, 'reload schema';
