/**
 * Who has not been collected.
 *
 * The end-of-service question, and nothing answered it: a leader opened each
 * classroom sheet in turn, and once the session auto-closed the children
 * disappeared from the live board entirely — so the one moment this matters
 * most was the moment it stopped working.
 *
 * Deliberately org-wide rather than scoped to the open session, because a
 * child left in a session that has already ended is exactly the child a
 * session-scoped view cannot show you.
 *
 * The guardian's phone is right here and tappable. At 12:40 the next action is
 * always a phone call, and making someone navigate to a profile to find the
 * number is the difference between calling and waiting.
 */

import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/shared/components/ui/card";
import { Badge } from "@/shared/components/ui/badge";
import { Button } from "@/shared/components/ui/button";
import {
  AlertTriangle,
  Loader2,
  Phone,
  ShieldAlert,
  CheckCircle2,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { useStillHere } from "../hooks/useKidsLeader";

/** Past this, a child has been waiting long enough to chase. */
const LONG_STAY_MINUTES = 150;

interface StillHerePanelProps {
  organizationId: string | undefined;
  onOpenChild?: (checkInId: string) => void;
}

export function StillHerePanel({
  organizationId,
  onOpenChild,
}: StillHerePanelProps) {
  const { data, isLoading } = useStillHere(organizationId);

  const children = data ?? [];
  // A child whose service has ENDED is the real alarm — everyone else has gone
  // home and nobody is watching the board any more.
  const afterHours = children.filter((c) => c.session_status !== "open");

  if (isLoading) {
    return (
      <Card>
        <CardContent className="flex justify-center py-8">
          <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
        </CardContent>
      </Card>
    );
  }

  if (children.length === 0) {
    return (
      <Card>
        <CardContent className="flex items-center gap-3 py-6">
          <CheckCircle2 className="h-5 w-5 text-green-600 shrink-0" />
          <div>
            <p className="font-medium">Everyone has been collected</p>
            <p className="text-sm text-muted-foreground">
              No child is checked in anywhere.
            </p>
          </div>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card className={afterHours.length > 0 ? "border-destructive" : undefined}>
      <CardHeader className="pb-3">
        <CardTitle className="text-base flex items-center gap-2">
          {afterHours.length > 0 && (
            <AlertTriangle className="h-4 w-4 text-destructive" />
          )}
          Still here ({children.length})
        </CardTitle>
        <CardDescription>
          {afterHours.length > 0
            ? `${afterHours.length} of these ${
                afterHours.length === 1 ? "is" : "are"
              } in a service that has already ended.`
            : "Children currently in a classroom."}
        </CardDescription>
      </CardHeader>

      <CardContent className="space-y-2">
        {children.map((c) => {
          const stale = c.session_status !== "open";
          const long = c.minutes_in_room >= LONG_STAY_MINUTES;
          return (
            <div
              key={c.check_in_id}
              className={cn(
                "flex items-center gap-3 rounded-md border p-2.5",
                stale && "border-destructive/50 bg-destructive/5"
              )}
            >
              <span className="font-mono text-xs text-muted-foreground w-10 shrink-0">
                #{c.tag_number}
              </span>

              <button
                className="min-w-0 flex-1 text-left"
                onClick={() => onOpenChild?.(c.check_in_id)}
              >
                <p className="text-sm font-medium truncate">{c.child_name}</p>
                <p className="text-xs text-muted-foreground truncate">
                  {c.room_name ?? "No room"} · {c.minutes_in_room} min
                  {stale && ` · ${c.session_label ?? "service"} has ended`}
                </p>
              </button>

              {c.has_restriction && (
                <Badge variant="destructive" className="gap-1 shrink-0">
                  <ShieldAlert className="h-3 w-3" />
                </Badge>
              )}
              {c.has_allergy && (
                <Badge variant="outline" className="border-amber-400 shrink-0">
                  <AlertTriangle className="h-3 w-3" />
                </Badge>
              )}
              {(stale || long) && !c.has_restriction && (
                <Badge variant="outline" className="border-amber-400 shrink-0">
                  {stale ? "After hours" : "Long stay"}
                </Badge>
              )}

              {c.guardian_phone ? (
                <Button
                  variant="outline"
                  size="sm"
                  className="shrink-0"
                  asChild
                >
                  <a href={`tel:${c.guardian_phone}`}>
                    <Phone className="h-4 w-4" />
                    {c.guardian_name?.split(" ")[0] ?? "Call"}
                  </a>
                </Button>
              ) : (
                <span className="text-xs text-muted-foreground shrink-0">
                  No number
                </span>
              )}
            </div>
          );
        })}
      </CardContent>
    </Card>
  );
}
