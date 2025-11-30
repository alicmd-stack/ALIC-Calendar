import { useState } from "react";
import DashboardLayout from "@/shared/components/layout/DashboardLayout";
import { Button } from "@/shared/components/ui/button";
import { Plus, ChevronLeft, ChevronRight, Download } from "lucide-react";
import { GoogleCalendarView, CalendarViewSwitcher, EventDialog, ExportDialog } from "../components";
import type { CalendarView } from "../components";
import { useEvents } from "../hooks";
import { useAuth } from "@/shared/contexts";
import { useOrganization } from "@/shared/contexts";
import { addWeeks, subWeeks, addDays, addMonths, subMonths, format, startOfWeek, endOfWeek, startOfMonth, endOfMonth } from "date-fns";

const Dashboard = () => {
  const { user, isAdmin } = useAuth();
  const { currentOrganization, isOrgAdmin } = useOrganization();
  const [isEventDialogOpen, setIsEventDialogOpen] = useState(false);
  const [isExportDialogOpen, setIsExportDialogOpen] = useState(false);
  const [selectedEventId, setSelectedEventId] = useState<string | null>(null);
  const [currentWeek, setCurrentWeek] = useState(new Date());
  const [selectedDate, setSelectedDate] = useState<Date | null>(null);
  const [calendarView, setCalendarView] = useState<CalendarView>("week");
  const [dayViewDate, setDayViewDate] = useState(new Date());

  const { data: events, refetch } = useEvents(currentOrganization?.id);

  const handleEventClick = (eventId: string) => {
    setSelectedEventId(eventId);
    setSelectedDate(null);
    setIsEventDialogOpen(true);
  };

  const handleCreateEvent = () => {
    setSelectedEventId(null);
    setSelectedDate(null);
    setIsEventDialogOpen(true);
  };

  const handleDateClick = (date: Date) => {
    // If in month view, switch to day view for the clicked date
    if (calendarView === "month") {
      setDayViewDate(date);
      setCurrentWeek(date);
      setCalendarView("day");
    } else {
      // For week and day views, open event dialog
      setSelectedEventId(null);
      setSelectedDate(date);
      setIsEventDialogOpen(true);
    }
  };

  return (
    <DashboardLayout>
      <div className="space-y-4 sm:space-y-6">
        {/* Header Section */}
        <div className="flex flex-col sm:flex-row sm:justify-between sm:items-center gap-4">
          <div>
            <h1 className="text-2xl sm:text-3xl font-bold">Event Calendar</h1>
            <p className="text-sm sm:text-base text-muted-foreground mt-1">
              Manage and schedule events
            </p>
          </div>
          <div className="flex items-center gap-2">
            <Button
              variant="outline"
              size="sm"
              onClick={() => setIsExportDialogOpen(true)}
              className="gap-1.5 sm:gap-2"
            >
              <Download className="h-4 w-4" />
              <span className="hidden xs:inline">Export</span>
            </Button>
            <Button onClick={handleCreateEvent} size="sm" className="gap-1.5 sm:gap-2 flex-1 sm:flex-none">
              <Plus className="h-4 w-4 sm:h-5 sm:w-5" />
              <span className="hidden xs:inline">Create </span>Event
            </Button>
          </div>
        </div>

        {/* Calendar Controls */}
        <div className="flex flex-col sm:flex-row sm:justify-between sm:items-center gap-3 sm:gap-4">
          <CalendarViewSwitcher
            currentView={calendarView}
            onViewChange={(view) => {
              setCalendarView(view);
              if (view === "day") {
                setDayViewDate(currentWeek);
              }
            }}
          />
          <div className="flex items-center gap-1 sm:gap-2">
            <Button
              variant="outline"
              size="icon"
              className="h-8 w-8 sm:h-9 sm:w-9"
              onClick={() => {
                if (calendarView === "day") {
                  setDayViewDate(addDays(dayViewDate, -1));
                } else if (calendarView === "month") {
                  setCurrentWeek(subMonths(currentWeek, 1));
                } else {
                  setCurrentWeek(subWeeks(currentWeek, 1));
                }
              }}
            >
              <ChevronLeft className="h-4 w-4" />
            </Button>
            <div className="px-2 sm:px-4 py-1.5 sm:py-2 bg-muted rounded-lg min-w-[120px] sm:min-w-[200px] text-center flex-1 sm:flex-none">
              <span className="font-medium text-xs sm:text-sm">
                {calendarView === "day"
                  ? format(dayViewDate, "EEE, MMM d")
                  : calendarView === "month"
                  ? format(currentWeek, "MMM yyyy")
                  : format(currentWeek, "MMM d")}
              </span>
              <span className="font-medium text-xs sm:text-sm hidden sm:inline">
                {calendarView === "day"
                  ? format(dayViewDate, ", yyyy")
                  : calendarView === "month"
                  ? ""
                  : format(currentWeek, ", yyyy")}
              </span>
            </div>
            <Button
              variant="outline"
              size="icon"
              className="h-8 w-8 sm:h-9 sm:w-9"
              onClick={() => {
                if (calendarView === "day") {
                  setDayViewDate(addDays(dayViewDate, 1));
                } else if (calendarView === "month") {
                  setCurrentWeek(addMonths(currentWeek, 1));
                } else {
                  setCurrentWeek(addWeeks(currentWeek, 1));
                }
              }}
            >
              <ChevronRight className="h-4 w-4" />
            </Button>
            <Button
              variant="outline"
              size="sm"
              className="text-xs sm:text-sm px-2 sm:px-3"
              onClick={() => {
                const today = new Date();
                setCurrentWeek(today);
                setDayViewDate(today);
              }}
            >
              Today
            </Button>
          </div>
        </div>

        <div>
          <GoogleCalendarView
            events={events || []}
            currentWeek={currentWeek}
            onEventClick={handleEventClick}
            onDateClick={handleDateClick}
            currentUserId={user?.id}
            view={calendarView}
            selectedDate={dayViewDate}
            startHour={0}
            endHour={23}
            scrollToHour={9}
            visibleHours={10}
          />
        </div>

        <EventDialog
          open={isEventDialogOpen}
          onOpenChange={setIsEventDialogOpen}
          eventId={selectedEventId}
          initialDate={selectedDate}
          onSuccess={() => {
            refetch();
            setIsEventDialogOpen(false);
          }}
          allEvents={events || []}
          onEventSelect={(eventId) => {
            setSelectedEventId(eventId);
            setSelectedDate(null);
          }}
        />

        <ExportDialog
          open={isExportDialogOpen}
          onOpenChange={setIsExportDialogOpen}
          events={events || []}
          organizationName={currentOrganization?.name || "Calendar"}
          organizationSlug={currentOrganization?.slug}
          timezone={currentOrganization?.timezone}
          userId={user?.id}
          isAdmin={isAdmin || isOrgAdmin}
          dateRange={
            calendarView === "month"
              ? {
                  start: startOfMonth(currentWeek),
                  end: endOfMonth(currentWeek),
                }
              : calendarView === "week"
              ? {
                  start: startOfWeek(currentWeek, { weekStartsOn: 0 }),
                  end: endOfWeek(currentWeek, { weekStartsOn: 0 }),
                }
              : undefined
          }
        />
      </div>
    </DashboardLayout>
  );
};

export default Dashboard;
