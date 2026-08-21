/**
 * One classroom tile on the live board.
 *
 * Capacity and ratio breaches are shown as amber warnings, never as blocks:
 * a church cannot turn a child away at the door, so the leader's job is to
 * see the breach and move a volunteer, not to be stopped by the software.
 */

import { Card, CardContent } from "@/shared/components/ui/card";
import { Badge } from "@/shared/components/ui/badge";
import { Button } from "@/shared/components/ui/button";
import { AlertTriangle, ShieldAlert, Users, Baby } from "lucide-react";
import { cn } from "@/lib/utils";
import type { LiveBoardRoom } from "../services/kidsLeaderService";

interface LiveBoardCardProps {
  room: LiveBoardRoom;
  onOpenRoster: (room: LiveBoardRoom) => void;
}

export function LiveBoardCard({ room, onOpenRoster }: LiveBoardCardProps) {
  const breached = room.over_capacity || room.over_ratio;
  const fillPct =
    room.capacity && room.capacity > 0
      ? Math.min(100, Math.round((room.checked_in_count / room.capacity) * 100))
      : null;

  return (
    <Card
      className={cn(
        "transition-colors",
        breached && "border-amber-400 bg-amber-50/60 dark:bg-amber-950/20"
      )}
    >
      <CardContent className="p-4 space-y-3">
        <div className="flex items-start justify-between gap-2">
          <div className="min-w-0">
            <p className="font-semibold truncate">
              {room.label_room_name || room.room_name}
            </p>
            <p className="text-xs text-muted-foreground truncate">
              {room.grade_name ?? room.age_band_name ?? "No grade set"}
            </p>
          </div>
          {room.restriction_count > 0 && (
            <Badge variant="destructive" className="shrink-0 gap-1">
              <ShieldAlert className="h-3 w-3" />
              {room.restriction_count}
            </Badge>
          )}
        </div>

        <div className="flex items-baseline gap-1">
          <span className="text-3xl font-bold tabular-nums">
            {room.checked_in_count}
          </span>
          {room.capacity != null && (
            <span className="text-sm text-muted-foreground">/ {room.capacity}</span>
          )}
          <span className="ml-auto text-xs text-muted-foreground">
            {room.checked_out_count} out
          </span>
        </div>

        {fillPct != null && (
          <div className="h-1.5 w-full rounded-full bg-muted overflow-hidden">
            <div
              className={cn(
                "h-full rounded-full transition-all",
                room.over_capacity ? "bg-amber-500" : "bg-primary"
              )}
              style={{ width: `${fillPct}%` }}
            />
          </div>
        )}

        <div className="flex flex-wrap items-center gap-2 text-xs">
          <span className="inline-flex items-center gap-1 text-muted-foreground">
            <Users className="h-3.5 w-3.5" />
            {room.volunteer_count} volunteer{room.volunteer_count === 1 ? "" : "s"}
          </span>
          {room.misplaced_count > 0 && (
            <span className="inline-flex items-center gap-1 text-amber-700 dark:text-amber-500">
              <AlertTriangle className="h-3.5 w-3.5" />
              {room.misplaced_count} to check
            </span>
          )}
          {room.allergy_count > 0 && (
            <span className="inline-flex items-center gap-1 text-amber-700 dark:text-amber-500">
              <Baby className="h-3.5 w-3.5" />
              {room.allergy_count} allergy
            </span>
          )}
        </div>

        {breached && (
          <div className="flex items-start gap-1.5 text-xs text-amber-800 dark:text-amber-400">
            <AlertTriangle className="h-3.5 w-3.5 mt-px shrink-0" />
            <span>
              {room.over_capacity && "Over capacity. "}
              {room.over_ratio &&
                (room.volunteer_count === 0
                  ? "No volunteer assigned."
                  : `Over ratio (1 per ${room.ratio_children_per_volunteer}).`)}
            </span>
          </div>
        )}

        <Button
          variant="outline"
          size="sm"
          className="w-full"
          onClick={() => onOpenRoster(room)}
        >
          View roster
        </Button>
      </CardContent>
    </Card>
  );
}
