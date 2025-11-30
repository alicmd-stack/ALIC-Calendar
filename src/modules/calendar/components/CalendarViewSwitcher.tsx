import { Button } from "@/shared/components/ui/button";
import { Calendar, CalendarDays, CalendarRange } from "lucide-react";
import { cn } from "@/shared/lib/utils";

export type CalendarView = "week" | "day" | "month";

interface CalendarViewSwitcherProps {
  currentView: CalendarView;
  onViewChange: (view: CalendarView) => void;
}

const CalendarViewSwitcher = ({
  currentView,
  onViewChange,
}: CalendarViewSwitcherProps) => {
  const views: { value: CalendarView; label: string; icon: React.ReactNode }[] = [
    { value: "day", label: "Day", icon: <Calendar className="h-4 w-4" /> },
    { value: "week", label: "Week", icon: <CalendarRange className="h-4 w-4" /> },
    { value: "month", label: "Month", icon: <CalendarDays className="h-4 w-4" /> },
  ];

  return (
    <div className="flex items-center gap-0.5 sm:gap-1 border rounded-lg p-0.5 sm:p-1 bg-muted/30">
      {views.map((view) => (
        <Button
          key={view.value}
          variant={currentView === view.value ? "default" : "ghost"}
          size="sm"
          onClick={() => onViewChange(view.value)}
          className={cn(
            "gap-1 sm:gap-2 h-8 px-2 sm:px-3 text-xs sm:text-sm",
            currentView === view.value && "shadow-sm"
          )}
        >
          {view.icon}
          <span className="hidden xs:inline">{view.label}</span>
        </Button>
      ))}
    </div>
  );
};

export default CalendarViewSwitcher;
