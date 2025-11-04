import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Clock, MapPin, User } from "lucide-react";
import { format, parseISO } from "date-fns";
import { cn } from "@/lib/utils";

interface Event {
  id: string;
  title: string;
  starts_at: string;
  ends_at: string;
  status: string;
  created_by: string;
  room: { id: string; name: string; color: string };
  creator: { full_name: string; ministry_name?: string } | null;
}

interface EventSidebarProps {
  events: Event[];
  onEventClick: (eventId: string) => void;
  currentUserId?: string;
}

const EventSidebar = ({
  events,
  onEventClick,
  currentUserId,
}: EventSidebarProps) => {
  const pendingEvents = events.filter((e) => e.status === "pending_review");
  const publishedEvents = events.filter((e) => e.status === "published");
  const approvedEvents = events.filter((e) => e.status === "approved");
  const draftEvents = events.filter((e) => e.status === "draft");

  const getStatusColor = (status: string) => {
    const colors: Record<string, string> = {
      draft: "bg-gray-500",
      pending_review: "bg-amber-500",
      approved: "bg-green-500",
      rejected: "bg-red-500",
      published: "bg-blue-500",
    };
    return colors[status] || "bg-gray-500";
  };

  const getStatusLabel = (status: string) => {
    return status.replace("_", " ").replace(/\b\w/g, (l) => l.toUpperCase());
  };

  const EventItem = ({ event }: { event: Event }) => {
    const isOwnEvent = currentUserId && event.created_by === currentUserId;

    return (
      <div
        onClick={() => onEventClick(event.id)}
        className={cn(
          "p-3 rounded-lg border-l-4 cursor-pointer hover:bg-accent transition-colors group",
          "bg-background shadow-sm hover:shadow-md"
        )}
        style={{
          borderLeftColor: event.room?.color || "#888",
        }}
      >
        <div className="space-y-2">
          <div className="flex items-start justify-between gap-2">
            <h4 className="font-semibold text-sm line-clamp-2 group-hover:text-primary transition-colors">
              {event.title}
            </h4>
            <Badge
              className={cn(
                "text-[9px] h-auto py-0.5 px-1.5 text-white shrink-0",
                getStatusColor(event.status)
              )}
            >
              {getStatusLabel(event.status)}
            </Badge>
          </div>

          <div className="space-y-1 text-xs text-muted-foreground">
            <div className="flex items-center gap-1.5">
              <Clock className="h-3 w-3" />
              <span>
                {format(parseISO(event.starts_at), "MMM d, h:mm a")} -{" "}
                {format(parseISO(event.ends_at), "h:mm a")}
              </span>
            </div>

            <div className="flex items-center gap-1.5">
              <MapPin className="h-3 w-3" />
              <span
                className="font-medium"
                style={{ color: event.room?.color }}
              >
                {event.room?.name}
              </span>
            </div>

            {event.creator && (
              <div className="flex items-center gap-1.5">
                <User className="h-3 w-3" />
                <span className={cn(isOwnEvent && "font-medium text-foreground")}>
                  {isOwnEvent ? "You" : event.creator.full_name}
                  {event.creator.ministry_name &&
                    ` (${event.creator.ministry_name})`}
                </span>
              </div>
            )}
          </div>
        </div>
      </div>
    );
  };

  const EventList = ({
    events,
    emptyMessage,
  }: {
    events: Event[];
    emptyMessage: string;
  }) => (
    <ScrollArea className="h-[calc(100vh-280px)]">
      {events.length > 0 ? (
        <div className="space-y-2 pr-4">
          {events.map((event) => (
            <EventItem key={event.id} event={event} />
          ))}
        </div>
      ) : (
        <div className="flex items-center justify-center h-32 text-sm text-muted-foreground">
          {emptyMessage}
        </div>
      )}
    </ScrollArea>
  );

  return (
    <Card className="h-full">
      <CardHeader className="pb-3">
        <CardTitle className="text-lg">Events</CardTitle>
      </CardHeader>
      <CardContent>
        <Tabs defaultValue="pending" className="w-full">
          <TabsList className="grid w-full grid-cols-4">
            <TabsTrigger value="pending" className="text-xs relative">
              Pending
              {pendingEvents.length > 0 && (
                <Badge
                  variant="destructive"
                  className="ml-1 h-4 w-4 p-0 flex items-center justify-center text-[9px]"
                >
                  {pendingEvents.length}
                </Badge>
              )}
            </TabsTrigger>
            <TabsTrigger value="approved" className="text-xs">
              Approved
              {approvedEvents.length > 0 && (
                <Badge
                  variant="secondary"
                  className="ml-1 h-4 w-4 p-0 flex items-center justify-center text-[9px]"
                >
                  {approvedEvents.length}
                </Badge>
              )}
            </TabsTrigger>
            <TabsTrigger value="published" className="text-xs">
              Published
              {publishedEvents.length > 0 && (
                <Badge
                  variant="secondary"
                  className="ml-1 h-4 w-4 p-0 flex items-center justify-center text-[9px]"
                >
                  {publishedEvents.length}
                </Badge>
              )}
            </TabsTrigger>
            <TabsTrigger value="draft" className="text-xs">
              Draft
              {draftEvents.length > 0 && (
                <Badge
                  variant="secondary"
                  className="ml-1 h-4 w-4 p-0 flex items-center justify-center text-[9px]"
                >
                  {draftEvents.length}
                </Badge>
              )}
            </TabsTrigger>
          </TabsList>

          <div className="mt-4">
            <TabsContent value="pending" className="m-0">
              <EventList
                events={pendingEvents}
                emptyMessage="No pending events"
              />
            </TabsContent>

            <TabsContent value="approved" className="m-0">
              <EventList
                events={approvedEvents}
                emptyMessage="No approved events"
              />
            </TabsContent>

            <TabsContent value="published" className="m-0">
              <EventList
                events={publishedEvents}
                emptyMessage="No published events"
              />
            </TabsContent>

            <TabsContent value="draft" className="m-0">
              <EventList events={draftEvents} emptyMessage="No draft events" />
            </TabsContent>
          </div>
        </Tabs>
      </CardContent>
    </Card>
  );
};

export default EventSidebar;
