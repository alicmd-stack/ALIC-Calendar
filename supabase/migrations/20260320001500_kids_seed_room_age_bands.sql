-- =====================================================
-- Provisional classroom / age-band assignments
-- =====================================================
--
-- PROVISIONAL — these are ASSUMPTIONS, not the church's decision.
--
-- The Kids Ministry director has been asked for the real age-per-room mapping
-- and it is expected to change. These exist so check-in can be exercised now
-- rather than blocked, and every one of them is editable from the Kids
-- Ministry admin screen without another migration.
--
-- The guesses are made from the room names:
--   Shine class      -> Nursery      (named "Children and youth education",
--                                     the smallest/most contained room)
--   Joy class A / B  -> Pre-K        (a paired set, so two age groups can run
--                                     side by side and self-balance)
--   Blossom class A/B-> Elementary   (also paired, "Teaching and ministry")
--   Youth/True Vine  -> Youth
--
-- Deliberately NOT marked as classrooms: Main Auditorium, Fasika room, Guest
-- Room, both Training Conference rooms, and "Other (if outside the church)".
-- A room that is not a children's space must never appear as a check-in
-- destination.

INSERT INTO church.room_kids_config (
  room_id, organization_id, is_checkin_location, kids_age_band_id,
  capacity, ratio_children_per_volunteer, label_room_name, sort_order
)
SELECT
  r.id,
  r.organization_id,
  true,
  (SELECT b.id FROM church.kids_age_bands b
    WHERE b.organization_id = r.organization_id AND b.code = v.band_code),
  v.capacity,
  v.ratio,
  v.label,
  v.sort_order
FROM public.rooms r
JOIN (VALUES
  ('Shine class',                  'nursery',    12, 4,  'Shine',     10),
  ('Joy class A',                  'preschool',  16, 6,  'Joy A',     20),
  ('Joy class B',                  'preschool',  16, 6,  'Joy B',     30),
  ('Blossom class A',              'elementary', 24, 8,  'Blossom A', 40),
  ('Blossom class B',              'elementary', 24, 8,  'Blossom B', 50),
  ('Youth/True Vine worship Room', 'youth',      30, 10, 'Youth',     60)
) AS v(room_name, band_code, capacity, ratio, label, sort_order)
  ON v.room_name = r.name
WHERE r.is_active
ON CONFLICT (room_id) DO NOTHING;

-- Both Joy rooms share the Pre-K band, and both Blossom rooms share
-- Elementary. That is intentional: check-in sends each child to the emptier of
-- the matching pair, so parallel classrooms stay balanced across a morning
-- without anyone managing it.

COMMENT ON TABLE church.room_kids_config IS
  'Kids configuration for a public.rooms row. Age bands seeded in '
  '20260320001500 are PROVISIONAL assumptions pending the Kids Ministry '
  'director''s real mapping, and are editable from the admin screen.';

NOTIFY pgrst, 'reload schema';
