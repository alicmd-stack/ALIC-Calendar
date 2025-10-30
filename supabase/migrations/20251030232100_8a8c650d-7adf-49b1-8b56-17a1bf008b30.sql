-- Fix security warning: Move btree_gist extension to extensions schema
DROP EXTENSION IF EXISTS btree_gist CASCADE;
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;

-- Recreate the exclusion constraint after moving the extension
ALTER TABLE public.events DROP CONSTRAINT IF EXISTS no_overlap_per_room;
ALTER TABLE public.events
ADD CONSTRAINT no_overlap_per_room
EXCLUDE USING gist (
  room_id WITH =,
  tstzrange(starts_at, ends_at, '[)') WITH &&
)
WHERE (status IN ('approved', 'published'));

-- Ensure update_updated_at_column function has proper search_path
DROP FUNCTION IF EXISTS public.update_updated_at_column() CASCADE;
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- Recreate triggers
CREATE TRIGGER update_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_rooms_updated_at
  BEFORE UPDATE ON public.rooms
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_events_updated_at
  BEFORE UPDATE ON public.events
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();