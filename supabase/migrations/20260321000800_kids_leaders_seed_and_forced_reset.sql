-- =====================================================
-- The Children's Ministry leadership, and a password they must replace
-- =====================================================
--
-- Six people named by the Children's Ministry:
--
--   Tibarek        Kuyemeku@gmail.com        director, whole branch
--   Edilawit       edyared9@gmail.com        director, whole branch
--   Azeb Asegedom  asegedomazeb@gmail.com    Pre-K, K, Grade 1
--   Hana           Hana13.alic@gmail.com     Grades 2-3
--   Biruck Feysa   biruckfeysa@gmail.com     Grades 4-5
--   Salem          TSTSALEM@gmail.com        Grades 6-8
--
-- All six accounts are created with the same starter password, at the ministry
-- lead's instruction, and every one of them is FORCED TO REPLACE IT at first
-- sign-in. That matters more than usual here: a kids_admin can read a child's
-- medical record, authorise a pick-up and override a refusal, so a shared
-- six-digit password on these accounts is not a small thing. It is acceptable
-- only for as long as the database holds nothing but sample families.
--
-- HOW THE FORCING WORKS, and its honest limit. profiles.must_change_password is
-- set when an invitation is redeemed; the app refuses to render anything else
-- until the user sets a new password, then calls clear_password_change_required.
-- This is an application-level gate, not a cryptographic one — someone
-- determined could call the RPC against their own account without changing
-- anything. It stops the realistic failure, which is six volunteers all still
-- sharing 123456 in November because nobody was ever prompted.
--
-- NAMES. Two were given as "NA" for the surname, which is a placeholder rather
-- than a name, so those records carry the given name only and are flagged in
-- notes for the office to complete. Guessing a surname into a directory is
-- worse than leaving it visibly absent.

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS must_change_password BOOLEAN NOT NULL DEFAULT false;

/**
 * Clear the forced-reset flag for the caller.
 *
 * Deliberately only ever acts on auth.uid(): nobody can clear this for anyone
 * else, and there is no argument to get wrong.
 */
CREATE OR REPLACE FUNCTION public.clear_password_change_required()
RETURNS VOID
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.profiles
     SET must_change_password = false, updated_at = now()
   WHERE id = auth.uid();
$$;

REVOKE ALL ON FUNCTION public.clear_password_change_required() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.clear_password_change_required() TO authenticated;

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

  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, 'contributor')
  ON CONFLICT (user_id, role) DO NOTHING;

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

-- Redeeming an invitation now also demands a new password.
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

    IF inv.person_id IS NOT NULL THEN
      UPDATE church.people SET profile_id = _user_id, updated_at = now()
       WHERE id = inv.person_id AND profile_id IS NULL;
    END IF;

    -- Anyone arriving through an invitation was handed a starter password by
    -- somebody else. They replace it before they see anything.
    UPDATE public.profiles
       SET must_change_password = true, updated_at = now()
     WHERE id = _user_id;

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

-- ------------------------------------------------------- the six people

DO $do$
DECLARE
  _org UUID := 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11';
  L RECORD;
  _person UUID;
  _rooms UUID[];
BEGIN
  FOR L IN
    SELECT * FROM (VALUES
      -- given,      surname, email,                     grade codes ('' = whole branch)
      ('Tibarek',    NULL,    'kuyemeku@gmail.com',      ARRAY[]::TEXT[]),
      ('Edilawit',   NULL,    'edyared9@gmail.com',      ARRAY[]::TEXT[]),
      ('Azeb',       'Asegedom', 'asegedomazeb@gmail.com', ARRAY['prek','k','g1']),
      ('Hana',       NULL,    'hana13.alic@gmail.com',   ARRAY['g2','g3']),
      ('Biruck',     'Feysa', 'biruckfeysa@gmail.com',   ARRAY['g4','g5']),
      ('Salem',      NULL,    'tstsalem@gmail.com',      ARRAY['g6','g7','g8'])
    ) AS t(given, surname, email, grades)
  LOOP
    SELECT id INTO _person FROM church.people
     WHERE organization_id = _org AND lower(email) = L.email LIMIT 1;

    IF _person IS NULL THEN
      INSERT INTO church.people
        (organization_id, first_name, last_name, email, is_child, notes)
      VALUES (_org, L.given,
              -- "NA" was given as a placeholder, not a surname. The record
              -- carries the given name and says so, rather than inventing one.
              coalesce(L.surname, L.given),
              L.email, false,
              CASE WHEN L.surname IS NULL
                   THEN 'Kids ministry leader. Surname not supplied — please complete.'
                   ELSE 'Kids ministry leader.' END)
      RETURNING id INTO _person;
    END IF;

    SELECT array_agg(k.room_id) INTO _rooms
    FROM church.room_kids_config k
    JOIN church.school_grades g ON g.id = k.school_grade_id
    WHERE k.organization_id = _org
      AND k.is_checkin_location
      AND g.code = ANY(L.grades);

    INSERT INTO church.kids_leader_invites
      (organization_id, email, display_name, permission, scope_room_ids,
       person_id, created_by_name)
    VALUES (_org, L.email,
            L.given || coalesce(' ' || L.surname, ''),
            'kids_admin', _rooms, _person,
            'Children''s Ministry setup')
    ON CONFLICT (organization_id, email, permission) DO UPDATE
      SET scope_room_ids = EXCLUDED.scope_room_ids,
          display_name = EXCLUDED.display_name,
          person_id = EXCLUDED.person_id,
          updated_at = now();
  END LOOP;
END $do$;

NOTIFY pgrst, 'reload schema';
