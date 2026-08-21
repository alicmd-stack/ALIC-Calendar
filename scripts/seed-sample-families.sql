-- =====================================================
-- Sample families for ALIC Silver Spring
-- =====================================================
--
-- Ten families: six with three children, two with one, two with none.
-- Twenty children in total, spread one or two per classroom across Pre-K to
-- 8th grade so the live board and the grade routing have something to show.
--
-- NAMING. Ethiopian names are patronymic, not family names:
--   * a man is his given name plus his father's given name — Abebe Kebede is
--     Abebe, son of Kebede;
--   * a woman keeps her own father's name on marriage, so Almaz Tesfaye stays
--     Almaz Tesfaye rather than becoming an Abebe;
--   * a child takes their FATHER'S GIVEN name — Abebe's daughter is Sara
--     Abebe, not Sara Kebede.
-- Each child's second name is therefore passed explicitly.
--
-- Every person created here is tagged in `notes` with SAMPLE_DATA so the whole
-- set can be found and removed:
--
--   DELETE FROM church.people WHERE notes LIKE '%SAMPLE_DATA%';
--
-- Run as an organization admin; register_member_family checks the caller's
-- permission. NOT a migration — this is demo data, and it must not replay
-- into a fresh environment.
--
-- The organization is passed in rather than looked up, because reading
-- public.organizations goes through user_organizations, whose policies are
-- recursive on the local migration tree. Set it before running:
--
--   \set org_id 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'

\if :{?org_id}
\else
\set org_id 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'
\endif

-- Through a setting rather than a psql variable: psql does not interpolate
-- into a dollar-quoted block, which is where it is needed.
SELECT set_config('seed.org_id', :'org_id', false);

DO $do$
DECLARE
  _org UUID;
  f RECORD;
  _kids JSONB;
BEGIN
  _org := current_setting('seed.org_id')::UUID;

  FOR f IN
    SELECT * FROM (VALUES
      -- husband,     his father,  wife,          her father,   phone,  children as (given, grade, birth year)
      ('Abebe',    'Kebede',   'Almaz',      'Tesfaye',  '3015550101',
        ARRAY[['Naod','prek','2021'],['Sara','g3','2017'],['Yosef','g6','2014']]),
      ('Dawit',    'Bekele',   'Hirut',      'Girma',    '3015550102',
        ARRAY[['Kidus','k','2020'],['Liya','g4','2016'],['Nahom','g7','2013']]),
      ('Getachew', 'Assefa',   'Meseret',    'Haile',    '3015550103',
        ARRAY[['Eyob','g1','2019'],['Hanna','g5','2015'],['Biruk','g8','2012']]),
      ('Tesfaye',  'Mulugeta', 'Genet',      'Yohannes', '3015550104',
        ARRAY[['Amanuel','g2','2018'],['Ruth','g5','2015'],['Feven','prek','2021']]),
      ('Solomon',  'Berhanu',  'Aster',      'Tadesse',  '3015550105',
        ARRAY[['Yonas','g3','2017'],['Bezawit','g6','2014'],['Dagmawi','k','2020']]),
      ('Yohannes', 'Girma',    'Senait',     'Abera',    '3015550106',
        ARRAY[['Abel','g1','2019'],['Mahlet','g4','2016'],['Saron','g7','2013']]),
      ('Mulugeta', 'Haile',    'Yodit',      'Desta',    '3015550107',
        ARRAY[['Eden','g2','2018']]),
      ('Girma',    'Tadesse',  'Meron',      'Alemu',    '3015550108',
        ARRAY[['Nati','g8','2012']]),
      ('Haile',    'Wolde',    'Zewditu',    'Kassa',    '3015550109',
        ARRAY[]::TEXT[][]),
      ('Tadesse',  'Negash',   'Bethlehem',  'Fikru',    '3015550110',
        ARRAY[]::TEXT[][])
    ) AS t(husband, his_father, wife, her_father, phone, kids)
  LOOP
    -- Skip a family already seeded, so this can be re-run safely.
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM church.people p
      WHERE p.organization_id = _org
        AND p.first_name = f.husband AND p.last_name = f.his_father);

    _kids := '[]'::jsonb;
    IF array_length(f.kids, 1) IS NOT NULL THEN
      FOR i IN 1..array_length(f.kids, 1) LOOP
        _kids := _kids || jsonb_build_array(jsonb_build_object(
          'first_name', f.kids[i][1],
          -- The father's GIVEN name, not his father's.
          'last_name', f.husband,
          'birth_year', f.kids[i][3],
          'birth_month', ((i * 3) % 12) + 1,
          'school_grade_id',
            (SELECT g.id FROM church.school_grades g
              WHERE g.organization_id = _org AND g.code = f.kids[i][2]),
          'notes', 'SAMPLE_DATA'
        ));
      END LOOP;
    END IF;

    PERFORM church.register_member_family(
      _organization_id := _org,
      _person := jsonb_build_object(
        'first_name', f.husband,
        'last_name', f.his_father,
        'phone', regexp_replace(f.phone, '(\d{3})(\d{3})(\d{4})', '\1-\2-\3'),
        'email', lower(f.husband) || '.' || lower(f.his_father) || '@example.test',
        'gender', 'male',
        'marital_status', 'married',
        'notes', 'SAMPLE_DATA'),
      _household := jsonb_build_object(
        'name', f.husband || ' ' || f.his_father,
        'city', 'Silver Spring',
        'state', 'MD'),
      _spouse := jsonb_build_object(
        'mode', 'create',
        'person', jsonb_build_object(
          'first_name', f.wife,
          -- Her own father's name. Ethiopian women do not take a husband's.
          'last_name', f.her_father,
          'gender', 'female',
          'marital_status', 'married',
          'notes', 'SAMPLE_DATA')),
      _children := _kids
    );
  END LOOP;
END $do$;

-- A few allergies, so the safety card and the printed tag have something real
-- to show rather than every child reading "nothing on file".
DO $do$
DECLARE
  _org UUID;
  c RECORD;
BEGIN
  _org := current_setting('seed.org_id')::UUID;

  FOR c IN
    SELECT * FROM (VALUES
      ('Sara',    'Abebe',    'life_threatening', 'Peanuts and tree nuts', 'EpiPen in her bag'),
      ('Kidus',   'Dawit',    'severe',           'Dairy',                  NULL),
      ('Amanuel', 'Tesfaye',  'mild',             'Pollen',                 NULL),
      ('Biruk',   'Getachew', 'severe',           'Shellfish',              'Antihistamine')
    ) AS t(given, father, severity, allergies, meds)
  LOOP
    PERFORM church.upsert_person_sensitive(
      p.id, c.severity, c.allergies, NULL, c.meds, NULL, NULL, false)
    FROM church.people p
    WHERE p.organization_id = _org
      AND p.first_name = c.given AND p.last_name = c.father;
  END LOOP;
END $do$;

SELECT
  (SELECT count(*) FROM church.people WHERE notes LIKE '%SAMPLE_DATA%') AS people,
  (SELECT count(*) FROM church.people
    WHERE notes LIKE '%SAMPLE_DATA%' AND is_child) AS children,
  (SELECT count(*) FROM church.households h
    WHERE EXISTS (SELECT 1 FROM church.household_members hm
                  JOIN church.people p ON p.id = hm.person_id
                  WHERE hm.household_id = h.id
                    AND p.notes LIKE '%SAMPLE_DATA%')) AS households;
