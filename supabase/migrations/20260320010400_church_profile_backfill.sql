-- =====================================================
-- Turn the people who already have logins into members
-- =====================================================
--
-- Production holds 62 profiles and ZERO church.people rows. The members
-- module, the serving records, the kids teaching roster and every self-service
-- screen are all built and all empty, because the church's existing users were
-- never given member records.
--
-- It also leaves church.people.profile_id NULL everywhere, which is why:
--   - my_person_ids() returns nothing, so /members shows a signed-in member
--     their own record never, and update_my_contact_details is unreachable;
--   - resolve_actor cannot find a volunteer row, so the barred-volunteer check
--     is inert (20260320010300 documents this);
--   - nobody can be assigned as a classroom teacher or a Sunday volunteer,
--     because those pick from church.people.
--
-- ETHIOPIAN NAMING. full_name is split on the FIRST space only: first token is
-- the given name, the remainder is kept whole. For Ethiopian names the second
-- element is the father's name rather than a family surname, so keeping the
-- remainder intact preserves "Mulhat Tesfaye Bekele" as given "Mulhat" plus
-- "Tesfaye Bekele" instead of silently dropping the grandfather's name.
-- Amharic name fields are left NULL rather than transliterated — a guess there
-- is worse than a blank a person can fill in.
--
-- Nothing is ever overwritten. A person already linked to a profile, or an
-- existing member matching by email, is linked rather than duplicated.

-- ---------------------------------------------------------------------------
-- What would happen
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.preview_profile_backfill(_organization_id UUID)
RETURNS TABLE (
  profile_id UUID,
  full_name TEXT,
  email TEXT,
  action TEXT,
  matched_person_id UUID,
  matched_person_name TEXT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
BEGIN
  IF NOT (_organization_id IN (SELECT church.my_admin_orgs())
          OR church.has_permission_in_org(
               _organization_id,
               ARRAY['members_admin']::church.module_permission[])) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    pr.id,
    pr.full_name,
    pr.email,
    CASE
      WHEN linked.id IS NOT NULL THEN 'already linked'
      WHEN byemail.id IS NOT NULL THEN 'link to existing member'
      ELSE 'create member'
    END,
    coalesce(linked.id, byemail.id),
    coalesce(linked.nm, byemail.nm)
  FROM public.profiles pr
  JOIN public.user_organizations uo
    ON uo.user_id = pr.id AND uo.organization_id = _organization_id
  LEFT JOIN LATERAL (
    SELECT p.id, p.first_name || ' ' || p.last_name AS nm
    FROM church.people p
    WHERE p.profile_id = pr.id AND p.organization_id = _organization_id
    LIMIT 1
  ) linked ON true
  LEFT JOIN LATERAL (
    SELECT p.id, p.first_name || ' ' || p.last_name AS nm
    FROM church.people p
    WHERE p.organization_id = _organization_id
      AND p.profile_id IS NULL
      AND pr.email IS NOT NULL
      AND lower(btrim(p.email)) = lower(btrim(pr.email))
    LIMIT 1
  ) byemail ON true
  ORDER BY 4, 2;
END;
$$;

GRANT EXECUTE ON FUNCTION church.preview_profile_backfill(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Do it
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION church.backfill_people_from_profiles(
  _organization_id UUID)
RETURNS TABLE (created INTEGER, linked INTEGER, skipped INTEGER)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  pr RECORD;
  _first TEXT;
  _rest TEXT;
  _existing UUID;
  _created INTEGER := 0;
  _linked INTEGER := 0;
  _skipped INTEGER := 0;
  _actor TEXT;
BEGIN
  IF NOT (_organization_id IN (SELECT church.my_admin_orgs())
          OR church.has_permission_in_org(
               _organization_id,
               ARRAY['members_admin']::church.module_permission[])) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  _actor := coalesce(
    (SELECT full_name FROM public.profiles WHERE id = auth.uid()), 'System');

  FOR pr IN
    SELECT p.id, p.full_name, p.email, p.phone_number
    FROM public.profiles p
    JOIN public.user_organizations uo
      ON uo.user_id = p.id AND uo.organization_id = _organization_id
  LOOP
    -- Already a member of this branch: nothing to do.
    IF EXISTS (SELECT 1 FROM church.people x
               WHERE x.profile_id = pr.id
                 AND x.organization_id = _organization_id) THEN
      _skipped := _skipped + 1;
      CONTINUE;
    END IF;

    -- An unlinked member with the same email is the same human. Link rather
    -- than create a second record for them.
    SELECT x.id INTO _existing
    FROM church.people x
    WHERE x.organization_id = _organization_id
      AND x.profile_id IS NULL
      AND pr.email IS NOT NULL
      AND lower(btrim(x.email)) = lower(btrim(pr.email))
    LIMIT 1;

    IF _existing IS NOT NULL THEN
      UPDATE church.people
         SET profile_id = pr.id, updated_at = now()
       WHERE id = _existing;
      _linked := _linked + 1;
      CONTINUE;
    END IF;

    -- Split on the FIRST space only; see the note at the top of this file.
    _first := split_part(btrim(coalesce(pr.full_name, '')), ' ', 1);
    _rest := btrim(substr(btrim(coalesce(pr.full_name, '')),
                          length(_first) + 1));

    IF _first = '' THEN
      -- No name at all: fall back to the local part of the email rather than
      -- writing an empty member record, which first_name/last_name forbid.
      _first := coalesce(NULLIF(split_part(coalesce(pr.email, ''), '@', 1), ''),
                         'Member');
    END IF;
    IF _rest = '' THEN
      -- Marked so it is findable later. A single-word full_name is a data
      -- problem to correct, not something to invent a surname for.
      _rest := '(no surname on file)';
    END IF;

    INSERT INTO church.people (
      organization_id, profile_id, first_name, last_name, email, phone,
      is_child, is_active, created_by, created_by_name, notes)
    VALUES (
      _organization_id, pr.id, _first, _rest, pr.email, pr.phone_number,
      false, true, auth.uid(), _actor,
      'Created from an existing login. Name split from "'
        || coalesce(pr.full_name, '') || '" — please check.');

    _created := _created + 1;
  END LOOP;

  RETURN QUERY SELECT _created, _linked, _skipped;
END;
$$;

GRANT EXECUTE ON FUNCTION church.backfill_people_from_profiles(UUID)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Linking one login to one member, by hand
-- ---------------------------------------------------------------------------
--
-- The backfill only matches on email. Someone who signed up with a personal
-- address and is on the roll under another needs a human to say so.
CREATE OR REPLACE FUNCTION church.link_profile_to_person(
  _person_id UUID, _profile_id UUID)
RETURNS VOID
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _org UUID;
BEGIN
  SELECT p.organization_id INTO _org
  FROM church.people p WHERE p.id = _person_id;
  IF _org IS NULL THEN RAISE EXCEPTION 'person_not_found'; END IF;

  IF NOT (_org IN (SELECT church.my_admin_orgs())
          OR church.has_permission_in_org(
               _org, ARRAY['members_admin']::church.module_permission[])) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  IF _profile_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = _profile_id) THEN
      RAISE EXCEPTION 'login_not_found';
    END IF;

    -- uq_people_profile_per_org would raise a bare unique violation here.
    -- Say which member already holds the login instead.
    IF EXISTS (SELECT 1 FROM church.people x
               WHERE x.profile_id = _profile_id
                 AND x.organization_id = _org
                 AND x.id <> _person_id) THEN
      RAISE EXCEPTION 'login_already_linked'
        USING DETAIL = (SELECT x.first_name || ' ' || x.last_name
                        FROM church.people x
                        WHERE x.profile_id = _profile_id
                          AND x.organization_id = _org LIMIT 1);
    END IF;
  END IF;

  UPDATE church.people
     SET profile_id = _profile_id, updated_at = now()
   WHERE id = _person_id;
END;
$$;

GRANT EXECUTE ON FUNCTION church.link_profile_to_person(UUID, UUID)
  TO authenticated;

-- Logins in this branch with no member record yet, for the link picker.
CREATE OR REPLACE FUNCTION church.unlinked_logins(_organization_id UUID)
RETURNS TABLE (profile_id UUID, full_name TEXT, email TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
BEGIN
  IF NOT (_organization_id IN (SELECT church.my_admin_orgs())
          OR church.has_permission_in_org(
               _organization_id,
               ARRAY['members_admin']::church.module_permission[])) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT pr.id, pr.full_name, pr.email
  FROM public.profiles pr
  JOIN public.user_organizations uo
    ON uo.user_id = pr.id AND uo.organization_id = _organization_id
  WHERE NOT EXISTS (
    SELECT 1 FROM church.people p
    WHERE p.profile_id = pr.id AND p.organization_id = _organization_id)
  ORDER BY pr.full_name;
END;
$$;

GRANT EXECUTE ON FUNCTION church.unlinked_logins(UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';
