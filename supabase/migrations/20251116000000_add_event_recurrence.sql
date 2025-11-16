-- Add recurrence fields to events table
-- Supports enterprise-grade recurring event functionality with RRULE standard

-- Add recurrence columns
ALTER TABLE public.events
  ADD COLUMN recurrence_rule TEXT,
  ADD COLUMN recurrence_end_date TIMESTAMPTZ,
  ADD COLUMN parent_event_id UUID REFERENCES public.events(id) ON DELETE CASCADE,
  ADD COLUMN is_recurring BOOLEAN DEFAULT FALSE;

-- Add index for better query performance on recurring events
CREATE INDEX idx_events_parent_event_id ON public.events(parent_event_id);
CREATE INDEX idx_events_is_recurring ON public.events(is_recurring) WHERE is_recurring = TRUE;

-- Add comment explaining the recurrence_rule format
COMMENT ON COLUMN public.events.recurrence_rule IS 'RRULE format string (e.g., FREQ=WEEKLY;BYDAY=MO,WE,FR;INTERVAL=1). NULL for non-recurring events.';
COMMENT ON COLUMN public.events.recurrence_end_date IS 'End date for recurring events. NULL means no end date (infinite recurrence).';
COMMENT ON COLUMN public.events.parent_event_id IS 'Reference to parent event for recurring instances. NULL for standalone or parent events.';
COMMENT ON COLUMN public.events.is_recurring IS 'TRUE if this is a recurring event or instance of a recurring series.';
