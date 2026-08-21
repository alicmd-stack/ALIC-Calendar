-- =====================================================
-- Who the desk thinks you are
-- =====================================================
--
-- Two failures in resolve_actor, opposite in direction and identical in cause.
--
-- 1. THE BAR IS DEAD CODE. The volunteer lookup keys on
--    church.people.profile_id = auth.uid(), and NOTHING IN THE APPLICATION
--    EVER WRITES profile_id — not registration, not import, and there is no
--    admin screen to link a login to a member record. So a.person_id is NULL
--    for every real user, the lookup finds nothing, and a volunteer marked
--    `restricted` and de-activated keeps every capability at the desk.
--    Proven on the replica: a barred volunteer checked a child in.
--
--    The lookup is left keyed on profile_id — that IS the right key — and the
--    missing half is fixed separately by linking logins to member records.
--    Until then this check is inert, which is exactly why the bar must not
--    also be the thing that locks people out (below).
--
-- 2. WHERE IT IS NOT DEAD, IT LOCKS OUT THE LEAD. The check raised
--    volunteer_not_eligible on `NOT is_active OR restricted`. But is_active is
--    a ROSTER flag — "not serving this term" — not a safeguarding one. A
--    kids_admin whose volunteer row goes inactive could no longer check anyone
--    in or out, open a roster, or read a safety card, because resolve_actor is
--    the first statement of every kids RPC.
--
-- `restricted` bars. `is_active = false` simply means the action is attributed
-- to the person rather than to a roster entry.

CREATE OR REPLACE FUNCTION church.resolve_actor(_shift_token text DEFAULT NULL::text)
 RETURNS church.resolved_actor
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'church', 'public', 'extensions'
AS $$
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
    ARRAY['kids_admin','kids_volunteer']::church.module_permission[]) AS o;

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
  -- Only a kids_admin may authorise a checkout override. An ordinary
  -- volunteer still cannot do it alone.
  a.can_override := (_admin_orgs IS NOT NULL AND array_length(_admin_orgs, 1) > 0);
  RETURN a;
END;
$$;

GRANT EXECUTE ON FUNCTION church.resolve_actor(TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
