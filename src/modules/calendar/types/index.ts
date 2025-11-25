/**
 * Calendar module types
 */

import type { Tables } from "@/shared/types";

// Base event type from database
export type Event = Tables<"events">;
export type Room = Tables<"rooms">;

// Extended event with relations
export interface EventWithRelations extends Event {
  room: Room | null;
  creator: {
    full_name: string;
    email: string;
    ministry_name?: string | null;
  } | null;
}

// Event status type
export type EventStatus = "draft" | "pending_review" | "approved" | "rejected" | "published";

// Calendar view types
export type CalendarView = "day" | "week" | "month";

// Event form data
export interface EventFormData {
  title: string;
  description?: string;
  room_id: string;
  starts_at: string;
  ends_at: string;
  is_recurring?: boolean;
  recurrence_rule?: string;
  recurrence_end_date?: string;
}

// Event filter options
export interface EventFilters {
  status?: EventStatus[];
  room_id?: string;
  created_by?: string;
  start_date?: string;
  end_date?: string;
}

// Time slot for calendar display
export interface TimeSlot {
  hour: number;
  minute: number;
  label: string;
}

// Calendar day with events
export interface CalendarDay {
  date: Date;
  isToday: boolean;
  isCurrentMonth: boolean;
  events: EventWithRelations[];
}
