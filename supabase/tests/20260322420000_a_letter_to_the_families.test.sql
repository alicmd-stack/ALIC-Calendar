-- Assertions for 20260322420000, inside BEGIN/ROLLBACK.
--
-- The right parents, once each; only kids admins send; the test goes to the
-- writer alone; and a letter waits behind a check-in email in the queue.

CREATE TEMP TABLE t AS
SELECT 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::UUID AS md,
       '0c2dd974-ba40-4d99-8db5-63804c38ed65'::UUID AS admin_u,
       -- A teacher: kids_volunteer only.
       'a45508af-00dd-4e33-b5a0-e03611421e53'::UUID AS teacher_u;

CREATE TEMP TABLE fam (name TEXT PRIMARY KEY, household_id UUID);

-- Four households, each with one child who came last Sunday, plus one whose
-- only child is in 9th grade.
DO $setup$
DECLARE
  _md UUID; _h UUID; _c UUID; _a UUID; _sess UUID; _batch UUID; _room UUID;
  _member UUID; _visitor UUID; _g9 UUID; _tag INTEGER := 9800;
  _case RECORD;
BEGIN
  SELECT md INTO _md FROM t;
  PERFORM set_config('request.jwt.claim.sub', (SELECT admin_u::TEXT FROM t), true);
  SELECT id INTO _member  FROM church.membership_statuses WHERE organization_id = _md AND code = 'member';
  SELECT id INTO _visitor FROM church.membership_statuses WHERE organization_id = _md AND code = 'visitor';
  SELECT id INTO _g9 FROM church.school_grades WHERE organization_id = _md AND code = 'g9';
  -- A real session, batch and room to hang the test check-ins on.
  SELECT kids_session_id, batch_id, room_id INTO _sess, _batch, _room
    FROM church.kids_check_ins WHERE organization_id = _md AND room_id IS NOT NULL
   ORDER BY created_at DESC LIMIT 1;

  FOR _case IN
    SELECT * FROM (VALUES
      -- name, adults (status, email, notify), child grade
      ('ZZMemberFam',  ARRAY[_member, _member]::UUID[],
                       ARRAY['zz.mum@example.test', 'ZZ.Mum@Example.test ']::TEXT[],
                       ARRAY[true, true], NULL::UUID),
      ('ZZQuietFam',   ARRAY[_member, NULL]::UUID[],
                       ARRAY['zz.off@example.test', 'zz.quiet2@example.test']::TEXT[],
                       ARRAY[false, true], NULL::UUID),
      ('ZZVisitFam',   ARRAY[_visitor]::UUID[], ARRAY[NULL]::TEXT[], ARRAY[true], NULL::UUID),
      ('ZZNoneFam',    ARRAY[NULL]::UUID[], ARRAY['zz.none@example.test']::TEXT[], ARRAY[true], NULL::UUID),
      ('ZZNinthFam',   ARRAY[_member]::UUID[], ARRAY['zz.ninth@example.test']::TEXT[], ARRAY[true], _g9)
    ) v(name, statuses, emails, notify, grade)
  LOOP
    INSERT INTO church.households (organization_id, name)
      VALUES (_md, _case.name) RETURNING id INTO _h;
    INSERT INTO church.people (organization_id, first_name, last_name, is_child, school_grade_id)
      VALUES (_md, _case.name || 'Kid', 'Letter', true, _case.grade) RETURNING id INTO _c;
    INSERT INTO church.household_members (organization_id, household_id, person_id, household_role, is_primary_household)
      VALUES (_md, _h, _c, 'child', true);
    FOR i IN 1 .. array_length(_case.statuses, 1) LOOP
      INSERT INTO church.people (organization_id, first_name, last_name, is_child,
                                 membership_status_id, email, notify_by_email)
        VALUES (_md, _case.name || 'Parent' || i, 'Letter', false,
                _case.statuses[i], _case.emails[i], _case.notify[i])
        RETURNING id INTO _a;
      INSERT INTO church.household_members (organization_id, household_id, person_id, household_role, is_primary_household)
        VALUES (_md, _h, _a, 'adult', true);
    END LOOP;
    -- Came yesterday.
    _tag := _tag + 1;
    INSERT INTO church.kids_check_ins (organization_id, kids_session_id, batch_id,
      child_person_id, room_id, status, checked_in_by_name, tag_number,
      label_child_name, checked_in_at)
    VALUES (_md, _sess, _batch, _c, _room, 'checked_in', 'ZZ Desk', _tag,
            _case.name || 'Kid', now() - interval '1 day');
    INSERT INTO fam VALUES (_case.name, _h);
  END LOOP;
END;
$setup$;

-- 1. The parents a letter would reach, by family.
DO $a$
DECLARE _got TEXT;
BEGIN
  SELECT string_agg(lower(r.email), ',' ORDER BY lower(r.email)) INTO _got
  FROM church.kids_message_recipients((SELECT md FROM t), 'member', 7) r
  WHERE lower(r.email) LIKE 'zz.%';
  -- The two member parents share an address: once. The parent who turned
  -- email off: left out. The 9th grader's parent: left out.
  IF _got IS DISTINCT FROM 'zz.mum@example.test,zz.quiet2@example.test' THEN
    RAISE EXCEPTION 'FAIL 1: member letter goes to %', _got;
  END IF;

  SELECT string_agg(r.email, ',' ORDER BY r.email) INTO _got
  FROM church.kids_message_recipients((SELECT md FROM t), 'not_recorded', 7) r
  WHERE r.email LIKE 'zz.%';
  IF _got IS DISTINCT FROM 'zz.none@example.test' THEN
    RAISE EXCEPTION 'FAIL 1a: not-recorded letter goes to %', _got;
  END IF;

  IF EXISTS (SELECT 1 FROM church.kids_message_recipients((SELECT md FROM t), 'all', 7) r
             WHERE r.email = 'zz.ninth@example.test') THEN
    RAISE EXCEPTION 'FAIL 1b: a 9th grader''s family is written to';
  END IF;
  RAISE NOTICE 'PASS 1';
END;
$a$;

-- 2. The composer's counts: a visitor family with nobody to email is counted
--    but not reachable.
DO $a$
DECLARE _v RECORD; _all RECORD; _sum INTEGER;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', (SELECT admin_u::TEXT FROM t), true);
  SELECT * INTO _v FROM church.kids_family_message_audience((SELECT md FROM t), 7) WHERE family = 'visitor';
  IF _v.families < 1 OR _v.reachable > _v.families - 1 THEN
    RAISE EXCEPTION 'FAIL 2: visitors % families, % reachable', _v.families, _v.reachable;
  END IF;
  SELECT * INTO _all FROM church.kids_family_message_audience((SELECT md FROM t), 7) WHERE family = 'all';
  SELECT sum(families) INTO _sum FROM church.kids_family_message_audience((SELECT md FROM t), 7) WHERE family <> 'all';
  IF _all.families > _sum OR _all.emails <> (SELECT count(*) FROM church.kids_message_recipients((SELECT md FROM t), 'all', 7)) THEN
    RAISE EXCEPTION 'FAIL 2a: all = % families / % emails, the parts % families', _all.families, _all.emails, _sum;
  END IF;
  RAISE NOTICE 'PASS 2';
END;
$a$;

-- 3. Sending queues one email per address, recorded against the message.
DO $a$
DECLARE _r RECORD; _rows INTEGER; _rec RECORD;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', (SELECT admin_u::TEXT FROM t), true);
  SELECT * INTO _r FROM church.kids_send_family_message(
    (SELECT md FROM t), 'not_recorded', 7, '  ZZ Picnic  ', 'ZZ Bring a hat.');
  SELECT count(*) INTO _rows FROM church.notification_log
   WHERE family_message_id = _r.message_id AND kind = 'kids_family_message'
     AND status = 'queued' AND subject = 'ZZ Picnic' AND body = 'ZZ Bring a hat.';
  IF _rows <> _r.emails OR _rows = 0 THEN
    RAISE EXCEPTION 'FAIL 3: % queued, % reported', _rows, _r.emails;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM church.notification_log
                  WHERE family_message_id = _r.message_id AND recipient_email = 'zz.none@example.test') THEN
    RAISE EXCEPTION 'FAIL 3a: the not-recorded test parent was not written to';
  END IF;
  SELECT * INTO _rec FROM church.kids_family_messages_sent((SELECT md FROM t)) s WHERE s.id = _r.message_id;
  IF _rec.pending <> _r.emails OR _rec.family <> 'not_recorded' OR _rec.came_within_days <> 7 THEN
    RAISE EXCEPTION 'FAIL 3b: the sent list shows %', row_to_json(_rec);
  END IF;

  -- The same letter again at once: refused.
  BEGIN
    PERFORM church.kids_send_family_message((SELECT md FROM t), 'not_recorded', 7, 'ZZ Picnic', 'ZZ Bring a hat.');
    RAISE EXCEPTION 'FAIL 3c: sent twice';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'already_sent' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS 3 (% emails)', _r.emails;
END;
$a$;

-- 4. A test goes to the writer alone, and is not a sent message.
DO $a$
DECLARE _r RECORD; _me TEXT; _before INTEGER;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', (SELECT admin_u::TEXT FROM t), true);
  SELECT email INTO _me FROM public.profiles WHERE id = (SELECT admin_u FROM t);
  SELECT count(*) INTO _before FROM church.kids_family_messages WHERE organization_id = (SELECT md FROM t);
  SELECT * INTO _r FROM church.kids_send_family_message(
    (SELECT md FROM t), 'all', NULL, 'ZZ Test letter', 'ZZ body', true);
  IF _r.message_id IS NOT NULL OR _r.emails <> 1
     OR (SELECT count(*) FROM church.kids_family_messages WHERE organization_id = (SELECT md FROM t)) <> _before THEN
    RAISE EXCEPTION 'FAIL 4: a test was recorded as a message';
  END IF;
  IF (SELECT count(*) FROM church.notification_log
       WHERE subject = '[Test] ZZ Test letter' AND recipient_email = btrim(_me)
         AND family_message_id IS NULL) <> 1
     OR EXISTS (SELECT 1 FROM church.notification_log
                 WHERE subject = '[Test] ZZ Test letter' AND recipient_email <> btrim(_me)) THEN
    RAISE EXCEPTION 'FAIL 4a: the test did not go to the writer alone';
  END IF;
  RAISE NOTICE 'PASS 4';
END;
$a$;

-- 5. What is refused.
DO $a$
DECLARE _cases TEXT[][] := ARRAY[
  ['visitor-nobody',  'visitor', 'no_recipients'],
  ['placeholder',     'all',     'placeholder_left_in'],
  ['empty subject',   'all',     'invalid_subject'],
  ['bad family',      'elders',  'invalid_family']];
  i INT;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', (SELECT admin_u::TEXT FROM t), true);
  FOR i IN 1 .. array_length(_cases, 1) LOOP
    BEGIN
      PERFORM church.kids_send_family_message(
        (SELECT md FROM t), _cases[i][2],
        -- Visitors who came in the last 7 days: the test family, with no
        -- email address, and real visitors, who have none either.
        7,
        CASE WHEN _cases[i][1] = 'empty subject' THEN '   ' ELSE 'ZZ subject ' || i END,
        CASE WHEN _cases[i][1] = 'placeholder' THEN E'Hello\n\n[Write your message here.]' ELSE 'ZZ body ' || i END);
      RAISE EXCEPTION 'FAIL 5: % was sent', _cases[i][1];
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> _cases[i][3] THEN
        RAISE EXCEPTION 'FAIL 5: % refused with "%", expected %', _cases[i][1], SQLERRM, _cases[i][3];
      END IF;
    END;
  END LOOP;
  RAISE NOTICE 'PASS 5';
END;
$a$;

-- 6. Only kids admins send, count or read; nobody calls the helpers.
DO $a$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', (SELECT teacher_u::TEXT FROM t), true);
  BEGIN
    PERFORM church.kids_send_family_message((SELECT md FROM t), 'all', 56, 'ZZ teacher', 'ZZ hi');
    RAISE EXCEPTION 'FAIL 6: a teacher sent a letter';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM * FROM church.kids_family_message_audience((SELECT md FROM t), 56);
    RAISE EXCEPTION 'FAIL 6a: a teacher read the audience';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM * FROM church.kids_family_messages_sent((SELECT md FROM t));
    RAISE EXCEPTION 'FAIL 6b: a teacher read the sent letters';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  IF has_function_privilege('authenticated', 'church.kids_message_recipients(uuid,text,integer)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'church.kids_message_children(uuid,integer)', 'EXECUTE')
     OR has_function_privilege('anon', 'church.kids_send_family_message(uuid,text,integer,text,text,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL 6c: a helper or the sender is callable by the wrong role';
  END IF;
  IF has_table_privilege('authenticated', 'church.kids_family_messages', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL 6d: the messages table is readable directly';
  END IF;
  RAISE NOTICE 'PASS 6';
END;
$a$;

-- 7. The queue: a letter waits behind a check-in email queued after it.
DO $a$
DECLARE _first TEXT;
BEGIN
  -- Nothing else may be claimed in this transaction: hold every real queued
  -- row back, so only the two below compete.
  UPDATE church.notification_log
     SET not_before = now() + interval '1 day',
         claimed_at = CASE WHEN status = 'sending' THEN now() - interval '10 minutes' ELSE claimed_at END
   WHERE status IN ('queued', 'sending');
  INSERT INTO church.notification_log (organization_id, kind, channel, recipient_email, subject, body, created_at)
  VALUES ((SELECT md FROM t), 'kids_family_message', 'email', 'zz.a@example.test', 'ZZ letter', 'x', now() - interval '10 minutes'),
         ((SELECT md FROM t), 'check_in', 'email', 'zz.b@example.test', 'ZZ check-in', 'x', now());
  SELECT kind INTO _first FROM church.claim_queued_notifications(1);
  IF _first IS DISTINCT FROM 'check_in' THEN
    RAISE EXCEPTION 'FAIL 7: % was claimed before the check-in email', _first;
  END IF;
  RAISE NOTICE 'PASS 7';
END;
$a$;
