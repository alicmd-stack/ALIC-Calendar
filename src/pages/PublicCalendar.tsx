import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import EventCalendar from "@/components/calendar/EventCalendar";
import { Calendar } from "lucide-react";

const PublicCalendar = () => {
  const { data: events } = useQuery({
    queryKey: ["public-events"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("events")
        .select(`
          *,
          rooms(id, name, color)
        `)
        .eq("status", "published")
        .order("starts_at", { ascending: true });

      if (error) throw error;
      return data?.map(event => ({
        ...event,
        room: event.rooms,
        creator: { full_name: "User" }
      })) || [];
    },
  });

  const { data: rooms } = useQuery({
    queryKey: ["public-rooms"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("rooms")
        .select("*")
        .eq("is_active", true)
        .order("name");

      if (error) throw error;
      return data;
    },
  });

  return (
    <div className="min-h-screen bg-background">
      <header className="border-b bg-card">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
          <div className="flex items-center justify-between h-16">
            <div className="flex items-center gap-2">
              <div className="bg-gradient-primary p-2 rounded-lg">
                <Calendar className="h-5 w-5 text-primary-foreground" />
              </div>
              <span className="font-semibold text-lg">Public Event Calendar</span>
            </div>
          </div>
        </div>
      </header>
      <main className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div className="space-y-6">
          <div>
            <h1 className="text-3xl font-bold">Published Events</h1>
            <p className="text-muted-foreground mt-1">
              View all published events across rooms
            </p>
          </div>

          <EventCalendar
            events={events || []}
            rooms={rooms || []}
            onEventClick={() => {}}
          />
        </div>
      </main>
    </div>
  );
};

export default PublicCalendar;
