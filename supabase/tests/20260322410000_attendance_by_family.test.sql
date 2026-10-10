-- Assertions for 20260322410000, inside BEGIN/ROLLBACK.
--
-- A child takes the strongest status in the family; the split report adds
-- back up to the room report; and only kids leaders read it.

CREATE TEMP TABLE t AS
SELECT 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::UUID AS md,
       '0c2dd974-ba40-4d99-8db5-63804c38ed65'::UUID AS admin_u;

-- One family per case. Each child is returned by name from the temp table.
CREATE TEMP TABLE kid (name TEXT PRIMARY KEY, id UUID);

DO $setup$
DECLARE
  _md UUID; _h UUID; _a UUID; _c UUID;
  _member UUID; _regular UUID; _visitor UUID; _inactive UUID;
  -- name, the adults' statuses, the child's own status, whether the adults have left
  _case RECORD;
BEGIN
  SELECT md INTO _md FROM t;
  PERFORM set_config('request.jwt.claim.sub', (SELECT admin_u::TEXT FROM t), true);
  SELECT id INTO _member   FROM church.membership_statuses WHERE organization_id = _md AND code = 'member';
  SELECT id INTO _regular  FROM church.membership_statuses WHERE organization_id = _md AND code = 'regular_attendee';
  SELECT id INTO _visitor  FROM church.membership_statuses WHERE organization_id = _md AND code = 'visitor';
  SELECT id INTO _inactive FROM church.membership_statuses WHERE organization_id = _md AND code = 'inactive';

  FOR _case IN
    SELECT * FROM (VALUES
      ('ZZMember',     ARRAY[_member]::UUID[],            NULL::UUID, false),
      ('ZZMixed',      ARRAY[_visitor, _member]::UUID[],  NULL::UUID, false),
      ('ZZRegular',    ARRAY[_regular, _visitor]::UUID[], NULL::UUID, false),
      ('ZZVisitor',    ARRAY[_visitor]::UUID[],           NULL::UUID, false),
      ('ZZOwnVisitor', ARRAY[NULL]::UUID[],               _visitor,   false),
      ('ZZJoined',     ARRAY[_member]::UUID[],            _visitor,   false),
      ('ZZNothing',    ARRAY[NULL]::UUID[],               NULL::UUID, false),
      ('ZZInactive',   ARRAY[_inactive]::UUID[],          NULL::UUID, false),
      ('ZZLeft',       ARRAY[_member]::UUID[],            NULL::UUID, true)
    ) v(name, adults, own, adults_left)
  LOOP
    INSERT INTO church.households (organization_id, name)
      VALUES (_md, _case.name || ' Family') RETURNING id INTO _h;
    INSERT INTO church.people (organization_id, first_name, last_name, is_child, membership_status_id)
      VALUES (_md, _case.name, 'Family', true, _case.own) RETURNING id INTO _c;
    INSERT INTO church.household_members (organization_id, household_id, person_id, household_role, is_primary_household)
      VALUES (_md, _h, _c, 'child', true);
    FOR i IN 1 .. array_length(_case.adults, 1) LOOP
      INSERT INTO church.people (organization_id, first_name, last_name, is_child, membership_status_id)
        VALUES (_md, _case.name || 'Parent' || i, 'Family', false, _case.adults[i]) RETURNING id INTO _a;
      INSERT INTO church.household_members
        (organization_id, household_id, person_id, household_role, is_primary_household, start_date, end_date)
        VALUES (_md, _h, _a, 'adult', true,
                current_date - 400,
                CASE WHEN _case.adults_left THEN current_date - 30 END);
    END LOOP;
    INSERT INTO kid VALUES (_case.name, _c);
  END LOOP;
END;
$setup$;

-- 1. The rule.
DO $a$
DECLARE _wrong TEXT;
BEGIN
  SELECT string_agg(k.name || '=' || church.kids_family_status(k.id) || ' (expected ' || e.want || ')', ', ')
    INTO _wrong
  FROM kid k
  JOIN (VALUES
    ('ZZMember', 'member'),
    ('ZZMixed', 'member'),               -- one member parent makes a member family
    ('ZZRegular', 'regular_attendee'),   -- regular attendee outranks visitor
    ('ZZVisitor', 'visitor'),
    ('ZZOwnVisitor', 'visitor'),         -- registered at the desk, parents without one
    ('ZZJoined', 'member'),              -- registered as a visitor, the parent since joined
    ('ZZNothing', 'not_recorded'),
    ('ZZInactive', 'not_recorded'),      -- recorded, but none of the three
    ('ZZLeft', 'not_recorded')           -- the member parent left the household
  ) e(name, want) ON e.name = k.name
  WHERE church.kids_family_status(k.id) IS DISTINCT FROM e.want;
  IF _wrong IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL 1: %', _wrong;
  END IF;
  RAISE NOTICE 'PASS 1';
END;
$a$;

-- 2. The parts add back up to the room report, room by room, date by date.
DO $a$
DECLARE
  _md UUID := 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11';
  _from DATE := current_date - 365;
  _to DATE := current_date;
  _rows INT;
  _bad RECORD;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '0c2dd974-ba40-4d99-8db5-63804c38ed65', true);
  SELECT count(*) INTO _rows FROM church.kids_attendance_by_family(_md, _from, _to);
  IF _rows = 0 THEN RAISE EXCEPTION 'SKIP: no check-ins in the last year'; END IF;

  SELECT o.session_date, o.room_name, o.children AS old_children, n.children AS new_children INTO _bad
  FROM church.kids_attendance_report(_md, _from, _to) o
  FULL JOIN (
    SELECT session_date, service_label, room_name,
           sum(children) children, sum(first_time_visitors) first_time_visitors,
           max(volunteers) volunteers, min(volunteers) min_volunteers,
           sum(overrides) overrides, sum(not_checked_out) not_checked_out
    FROM church.kids_attendance_by_family(_md, _from, _to)
    GROUP BY 1, 2, 3
  ) n ON n.session_date = o.session_date
     AND n.service_label IS NOT DISTINCT FROM o.service_label
     AND n.room_name = o.room_name
  WHERE o.children IS DISTINCT FROM n.children
     OR o.first_time_visitors IS DISTINCT FROM n.first_time_visitors
     OR o.volunteers IS DISTINCT FROM n.volunteers
     OR n.volunteers IS DISTINCT FROM n.min_volunteers
     OR o.overrides IS DISTINCT FROM n.overrides
     OR o.not_checked_out IS DISTINCT FROM n.not_checked_out
  LIMIT 1;
  IF _bad.session_date IS NOT NULL OR _bad.room_name IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL 2: % % has % children in the room report, % split by family',
      _bad.session_date, _bad.room_name, _bad.old_children, _bad.new_children;
  END IF;

  IF EXISTS (SELECT 1 FROM church.kids_attendance_by_family(_md, _from, _to)
             WHERE family_status NOT IN ('member', 'regular_attendee', 'visitor', 'not_recorded')) THEN
    RAISE EXCEPTION 'FAIL 2a: a status outside the four';
  END IF;
  -- Real data, not shapes: Silver Spring has member families and visitors.
  IF NOT EXISTS (SELECT 1 FROM church.kids_attendance_by_family(_md, _from, _to) WHERE family_status = 'member')
     OR NOT EXISTS (SELECT 1 FROM church.kids_attendance_by_family(_md, _from, _to) WHERE family_status = 'visitor') THEN
    RAISE EXCEPTION 'FAIL 2b: no member or no visitor check-ins in a year';
  END IF;
  RAISE NOTICE 'PASS 2 (% rows)', _rows;
END;
$a$;

-- 3. The by-child list: same rows as before, each child with one family.
DO $a$
DECLARE
  _md UUID := 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11';
  _from DATE := current_date - 84;
  _to DATE := current_date;
  _rows INT;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '0c2dd974-ba40-4d99-8db5-63804c38ed65', true);
  SELECT count(*) INTO _rows FROM church.kids_child_attendance(_md, _from, _to);
  IF _rows = 0 THEN RAISE EXCEPTION 'SKIP: no check-ins in the last 12 weeks'; END IF;

  IF EXISTS (SELECT 1 FROM church.kids_child_attendance(_md, _from, _to)
             WHERE family_status IS DISTINCT FROM church.kids_family_status(child_person_id)) THEN
    RAISE EXCEPTION 'FAIL 3: a child''s family differs from the rule';
  END IF;

  -- The same children per date as the split room report, family by family.
  IF EXISTS (
    SELECT 1
    FROM (SELECT session_date d, family_status fs, count(*) n
            FROM church.kids_child_attendance(_md, _from, _to) GROUP BY 1, 2) a
    FULL JOIN (SELECT s.session_date d, church.kids_family_status(c.child_person_id) fs,
                      count(DISTINCT c.child_person_id) n
                 FROM church.kids_sessions s
                 JOIN church.kids_check_ins c ON c.kids_session_id = s.id
                WHERE s.organization_id = _md AND s.session_date BETWEEN _from AND _to
                GROUP BY 1, 2) b ON b.d = a.d AND b.fs = a.fs
    WHERE a.n IS DISTINCT FROM b.n) THEN
    RAISE EXCEPTION 'FAIL 3a: the by-child list and the check-ins disagree by family';
  END IF;
  RAISE NOTICE 'PASS 3 (% rows)', _rows;
END;
$a$;

-- 4. Nobody outside the kids leaders reads it, and nobody calls the rule.
DO $a$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', gen_random_uuid()::TEXT, true);
  BEGIN
    PERFORM * FROM church.kids_attendance_by_family(
      'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', current_date - 84, current_date);
    RAISE EXCEPTION 'FAIL 4: a stranger read attendance by family';
  EXCEPTION WHEN insufficient_privilege OR raise_exception THEN
    IF SQLERRM LIKE 'FAIL 4%' THEN RAISE; END IF;
  END;
  IF has_function_privilege('anon', 'church.kids_attendance_by_family(uuid,date,date)', 'EXECUTE')
     OR has_function_privilege('anon', 'church.kids_child_attendance(uuid,date,date)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL 4a: anon can read a report';
  END IF;
  IF NOT has_function_privilege('authenticated', 'church.kids_child_attendance(uuid,date,date)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL 4b: the by-child list lost its grant when it was recreated';
  END IF;
  IF has_function_privilege('authenticated', 'church.kids_family_status(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'church.kids_family_status(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL 4c: anyone signed in can look up a person''s family status';
  END IF;
  RAISE NOTICE 'PASS 4';
END;
$a$;
