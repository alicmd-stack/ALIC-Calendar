import { Card } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { format, startOfWeek, addDays, isSameDay, parseISO } from "date-fns";

interface Event {
  id: string;
  title: string;
  starts_at: string;
  ends_at: string;
  status: string;
  room: { id: string; name: string; color: string };
  creator: { full_name: string } | null;
}

interface Room {
  id: string;
  name: string;
  color: string;
}

interface EventCalendarProps {
  events: Event[];
  rooms: Room[];
  onEventClick: (eventId: string) => void;
}

const statusColors = {
  draft: "bg-muted text-muted-foreground",
  pending_review: "bg-warning/20 text-warning-foreground",
  approved: "bg-success/20 text-success-foreground",
  rejected: "bg-destructive/20 text-destructive-foreground",
  published: "bg-primary/20 text-primary-foreground",
};

const EventCalendar = ({ events, rooms, onEventClick }: EventCalendarProps) => {
  const today = new Date();
  const weekStart = startOfWeek(today, { weekStartsOn: 0 });
  const weekDays = Array.from({ length: 7 }, (_, i) => addDays(weekStart, i));

  const getEventsForDayAndRoom = (day: Date, roomId: string) => {
    return events.filter(
      (event) =>
        event.room.id === roomId &&
        isSameDay(parseISO(event.starts_at), day)
    );
  };

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-8 gap-4">
        <div className="font-semibold text-sm text-muted-foreground">Room</div>
        {weekDays.map((day) => (
          <div key={day.toString()} className="text-center">
            <div className="font-semibold">{format(day, "EEE")}</div>
            <div className="text-sm text-muted-foreground">{format(day, "MMM d")}</div>
          </div>
        ))}
      </div>

      {rooms.map((room) => (
        <Card key={room.id} className="p-4">
          <div className="grid grid-cols-8 gap-4">
            <div className="flex items-center gap-2">
              <div
                className="w-3 h-3 rounded-full"
                style={{ backgroundColor: room.color }}
              />
              <span className="font-medium text-sm">{room.name}</span>
            </div>

            {weekDays.map((day) => {
              const dayEvents = getEventsForDayAndRoom(day, room.id);
              return (
                <div key={day.toString()} className="space-y-1 min-h-[100px]">
                  {dayEvents.map((event) => (
                    <div
                      key={event.id}
                      onClick={() => onEventClick(event.id)}
                      className="p-2 rounded-lg bg-card border cursor-pointer hover:shadow-md transition-all"
                    >
                      <div className="text-xs font-medium truncate">{event.title}</div>
                      <div className="text-xs text-muted-foreground">
                        {format(parseISO(event.starts_at), "HH:mm")} -{" "}
                        {format(parseISO(event.ends_at), "HH:mm")}
                      </div>
                      <Badge
                        className={`text-xs mt-1 ${
                          statusColors[event.status as keyof typeof statusColors]
                        }`}
                      >
                        {event.status.replace("_", " ")}
                      </Badge>
                    </div>
                  ))}
                </div>
              );
            })}
          </div>
        </Card>
      ))}
    </div>
  );
};

export default EventCalendar;
