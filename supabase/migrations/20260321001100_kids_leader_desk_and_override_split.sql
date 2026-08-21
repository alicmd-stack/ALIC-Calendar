-- =====================================================
-- Team leads reach their board; only directors may override
-- =====================================================
--
-- kids_leader now counts as a kids leader for the board and as an operator at
-- the desk, while override rights stay with kids_admin alone.
--
-- The bug this closes: resolve_actor derived can_override from
-- my_orgs_with_any(ARRAY['kids_admin']) and never consulted kids_leader_scope,
-- so scoping a team lead to two classrooms narrowed what she could SEE and not
-- what she could AUTHORISE. Every one of the four team leads could release any
-- child in the branch.

CREATE OR REPLACE FUNCTION church.kids_leader_orgs()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'church', 'public'
AS $function$
  SELECT church.my_orgs_with_any(
    ARRAY['kids_admin', 'kids_leader',
          'leadership_viewer']::church.module_permission[]);
$function$
;

CREATE OR REPLACE FUNCTION church.resolve_actor(_shift_token text DEFAULT NULL::text)
 RETURNS church.resolved_actor
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'church', 'public', 'extensions'
AS $function$
DECLARE
  a church.resolved_actor;
  st church.kids_shift_tokens%ROWTYPE;
  v  church.kids_volunteers%ROWTYPE;
  p  church.people%ROWTYPE;
  _admin_orgs UUID[];
  _volunteer_orgs UUID[];
BEGIN
  -- Shift-token path retained so the shared-device model still works if ALIC
  -- turns it back on. Unused by the current UI.
  IF _shift_token IS NOT NULL AND length(_shift_token) > 0 THEN
    SELECT * INTO st FROM church.kids_shift_tokens
    WHERE token_hash = digest(_shift_token, 'sha256')
      AND ended_at IS NULL AND expires_at > now();
    IF NOT FOUND THEN
      RAISE EXCEPTION 'invalid_or_expired_shift' USING ERRCODE = '28000';
    END IF;
    IF st.issued_to_auth_user IS NOT NULL
       AND st.issued_to_auth_user IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'invalid_or_expired_shift' USING ERRCODE = '28000';
    END IF;

    SELECT * INTO v FROM church.kids_volunteers WHERE id = st.volunteer_id;
    IF NOT FOUND OR NOT v.is_active OR v.background_check_status = 'restricted' THEN
      RAISE EXCEPTION 'volunteer_not_eligible' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO p FROM church.people WHERE id = v.person_id;

    a.organization_id := st.organization_id;
    a.person_id       := v.person_id;
    a.volunteer_id    := v.id;
    a.station_id      := st.station_id;
    a.actor_name      := coalesce(p.preferred_name, p.first_name) || ' ' || p.last_name;
    a.source          := 'station';
    a.can_check_in    := true;
    a.can_check_out   := true;
    a.can_override    := v.can_override;
    RETURN a;
  END IF;

  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT array_agg(o) INTO _admin_orgs
  FROM church.my_orgs_with_any(ARRAY['kids_admin']::church.module_permission[]) AS o;

  SELECT array_agg(o) INTO _volunteer_orgs
  FROM church.my_orgs_with_any(
    ARRAY['kids_admin','kids_leader',
          'kids_volunteer']::church.module_permission[]) AS o;

  IF _volunteer_orgs IS NULL OR array_length(_volunteer_orgs, 1) IS NULL THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  a.organization_id := _volunteer_orgs[1];
  -- Attribution comes from the signed-in user's own member record.
  a.person_id := (SELECT id FROM church.people
                   WHERE profile_id = auth.uid()
                     AND organization_id = a.organization_id LIMIT 1);

  -- KID-024, previously enforced only on the shift-token path. The signed-in
  -- branch resolved a volunteer row with no predicate and then granted every
  -- capability, so a volunteer marked `restricted` and de-activated could
  -- still check children in and out and open safety cards. Scoped to the
  -- organization too: the old lookup matched on person_id alone.
  SELECT * INTO v FROM church.kids_volunteers vv
   WHERE vv.person_id = a.person_id
     AND vv.organization_id = a.organization_id
   LIMIT 1;

  -- `restricted` is the only status that bars a person from the desk, and it
  -- bars them absolutely. `is_active = false` means "not on the roster this
  -- term", which is a scheduling fact, not a safeguarding one — treating it as
  -- a bar locked the ministry lead out of their own module the moment their
  -- volunteer row went stale, and resolve_actor is the first statement of
  -- every kids RPC, so that is a total lockout.
  IF FOUND AND v.background_check_status = 'restricted' THEN
    RAISE EXCEPTION 'volunteer_not_eligible' USING ERRCODE = '42501';
  END IF;

  -- Attributed to the volunteer record only while it is current. An inactive
  -- row still identifies the person, but the action is recorded against their
  -- name rather than a roster entry that says they were not serving.
  IF FOUND AND v.is_active THEN
    a.volunteer_id := v.id;
  END IF;

  a.station_id := NULL;
  a.actor_name := coalesce(
    (SELECT full_name FROM public.profiles WHERE id = auth.uid()), 'Volunteer');
  a.source := 'user';
  a.can_check_in  := true;
  a.can_check_out := true;
  -- Only a kids_admin may authorise a checkout override — a DIRECTOR, not a
  -- team lead. _admin_orgs is deliberately kids_admin alone and does not
  -- include kids_leader.
  --
  -- This is the whole reason kids_leader exists. Team leads were made
  -- kids_admin and narrowed with kids_leader_scope, but this line never
  -- consulted the scope table, so a lead scoped to two classrooms could
  -- authorise the release of any child in the branch — including one she could
  -- not see on her own board. An override that four of six leaders can
  -- self-authorise is not the two-person rule the plan asked for.
  a.can_override := (_admin_orgs IS NOT NULL AND array_length(_admin_orgs, 1) > 0);
  RETURN a;
END;
$function$
;

GRANT EXECUTE ON FUNCTION church.kids_leader_orgs() TO authenticated;
GRANT EXECUTE ON FUNCTION church.resolve_actor(TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
