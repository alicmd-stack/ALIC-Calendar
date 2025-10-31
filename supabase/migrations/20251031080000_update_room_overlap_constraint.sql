-- Update the room overlap constraint to allow multiple bookings for "Other" room
-- but prevent overlapping bookings for all other rooms (applies to all statuses)

-- Drop the existing constraint
ALTER TABLE public.events
DROP CONSTRAINT IF EXISTS no_overlap_per_room;

-- Add a column to rooms table to mark if overlapping is allowed
ALTER TABLE public.rooms
ADD COLUMN IF NOT EXISTS allow_overlap BOOLEAN NOT NULL DEFAULT false;

-- Mark the "Other" room as allowing overlaps
UPDATE public.rooms
SET allow_overlap = true
WHERE name = 'Other (if outside the church)';

-- Add a helper column to events that denormalizes the allow_overlap flag from rooms
-- This is needed because exclusion constraints can't use joins or functions in WHERE clause
ALTER TABLE public.events
ADD COLUMN IF NOT EXISTS room_allows_overlap BOOLEAN NOT NULL DEFAULT false;

-- Create a function to sync room_allows_overlap with the room's allow_overlap setting
CREATE OR REPLACE FUNCTION public.sync_room_allows_overlap()
RETURNS TRIGGER AS $$
BEGIN
  SELECT allow_overlap INTO NEW.room_allows_overlap
  FROM public.rooms
  WHERE id = NEW.room_id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger to auto-update room_allows_overlap when event is inserted or room_id changes
DROP TRIGGER IF EXISTS sync_room_allows_overlap_trigger ON public.events;
CREATE TRIGGER sync_room_allows_overlap_trigger
  BEFORE INSERT OR UPDATE OF room_id ON public.events
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_room_allows_overlap();

-- Update existing events to have the correct room_allows_overlap value
UPDATE public.events e
SET room_allows_overlap = r.allow_overlap
FROM public.rooms r
WHERE e.room_id = r.id;

-- Add exclusion constraint that only applies when room doesn't allow overlap
-- This allows multiple events in rooms where allow_overlap = true
ALTER TABLE public.events
ADD CONSTRAINT no_overlap_per_room
EXCLUDE USING gist (
  room_id WITH =,
  tstzrange(starts_at, ends_at, '[)') WITH &&
)
WHERE (room_allows_overlap = false);
