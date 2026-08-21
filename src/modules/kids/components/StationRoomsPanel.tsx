/**
 * "Who is in my room" for a classroom volunteer, and the parent message.
 *
 * This is the third parent-notification feature. Check-in and pick-up
 * notifications are automatic — database triggers fire them with no one
 * involved. This one is a deliberate act by the volunteer standing with the
 * child, so it needs a person, a child, and a button.
 *
 * Touch targets are sized for the same tablet the rest of the station runs on.
 */

import { useCallback, useEffect, useState } from "react";
import { Button } from "@/shared/components/ui/button";
import { Badge } from "@/shared/components/ui/badge";
import { Textarea } from "@/shared/components/ui/textarea";
import {
  AlertTriangle,
  ArrowLeft,
  Loader2,
  MessageSquare,
  RefreshCw,
  Send,
  ShieldAlert,
} from "lucide-react";
import { kidsStationService } from "../services/kidsStationService";
import type { StationRoom, StationRosterRow } from "../types";

interface StationRoomsPanelProps {
  sessionId: string;
  online: boolean;
  onExit: () => void;
}

export function StationRoomsPanel({
  sessionId,
  online,
  onExit,
}: StationRoomsPanelProps) {
  const [rooms, setRooms] = useState<StationRoom[]>([]);
  const [room, setRoom] = useState<StationRoom | null>(null);
  const [roster, setRoster] = useState<StationRosterRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [messaging, setMessaging] = useState<StationRosterRow | null>(null);
  const [messageText, setMessageText] = useState("");
  const [sending, setSending] = useState(false);
  const [sendResult, setSendResult] = useState<string | null>(null);

  const loadRooms = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      setRooms(await kidsStationService.sessionRooms(sessionId));
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }, [sessionId]);

  const loadRoster = useCallback(
    async (target: StationRoom) => {
      setLoading(true);
      setError(null);
      try {
        setRoster(await kidsStationService.roomRoster(sessionId, target.room_id));
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err));
      } finally {
        setLoading(false);
      }
    },
    [sessionId]
  );

  useEffect(() => {
    void loadRooms();
  }, [loadRooms]);

  // A roster on a wall-mounted tablet goes stale silently, so refresh it while
  // the room is open rather than trusting whatever was true on first load.
  useEffect(() => {
    if (!room || !online) return;
    const timer = window.setInterval(() => void loadRoster(room), 20_000);
    return () => window.clearInterval(timer);
  }, [room, online, loadRoster]);

  async function send() {
    if (!messaging || !messageText.trim()) return;
    setSending(true);
    setSendResult(null);
    try {
      const recipients = await kidsStationService.sendParentMessage({
        checkInId: messaging.check_in_id,
        message: messageText.trim(),
      });
      // No recipients is not success — the volunteer has to go find the parent.
      setSendResult(
        recipients.length === 0
          ? `No contactable parent on file for ${messaging.child_display_name}. Find them in the service.`
          : `Sent to ${recipients.map((r) => r.recipient_name).join(", ")}.`
      );
      if (recipients.length > 0) {
        setMessaging(null);
        setMessageText("");
      }
    } catch (err) {
      setSendResult(
        `Could not send: ${err instanceof Error ? err.message : String(err)}`
      );
    } finally {
      setSending(false);
    }
  }

  /* ------------------------------------------------------------ room list */
  if (!room) {
    return (
      <div className="max-w-3xl mx-auto">
        <div className="flex items-center justify-between">
          <h2 className="text-2xl font-semibold">Choose your room</h2>
          <Button variant="ghost" onClick={onExit}>
            <ArrowLeft className="h-4 w-4 mr-1" />
            Back
          </Button>
        </div>

        {error && <p className="mt-4 text-destructive text-sm">{error}</p>}

        {loading && rooms.length === 0 ? (
          <div className="flex justify-center py-16">
            <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
          </div>
        ) : (
          <div className="mt-5 grid gap-3 sm:grid-cols-2">
            {rooms.map((option) => (
              <button
                key={option.room_id}
                className="rounded-lg border p-5 text-left hover:bg-muted/50"
                onClick={() => {
                  setRoom(option);
                  void loadRoster(option);
                }}
              >
                <p className="text-lg font-medium">{option.room_name}</p>
                <p className="text-sm text-muted-foreground">
                  {option.age_band_name ?? "No age group"}
                </p>
                <p className="mt-2 text-2xl font-bold tabular-nums">
                  {option.checked_in_count}
                  {option.capacity != null && (
                    <span className="text-base font-normal text-muted-foreground">
                      {" "}
                      / {option.capacity}
                    </span>
                  )}
                </p>
              </button>
            ))}
            {rooms.length === 0 && !loading && (
              <p className="text-muted-foreground py-8">
                No classrooms are open for this service.
              </p>
            )}
          </div>
        )}
      </div>
    );
  }

  /* --------------------------------------------------------------- roster */
  return (
    <div className="max-w-3xl mx-auto">
      <div className="flex items-center justify-between gap-2">
        <div>
          <h2 className="text-2xl font-semibold">{room.room_name}</h2>
          <p className="text-sm text-muted-foreground">
            {roster.length} in the room
          </p>
        </div>
        <div className="flex gap-2">
          <Button
            variant="outline"
            onClick={() => void loadRoster(room)}
            disabled={loading}
          >
            <RefreshCw className={loading ? "h-4 w-4 animate-spin" : "h-4 w-4"} />
          </Button>
          <Button
            variant="ghost"
            onClick={() => {
              setRoom(null);
              setRoster([]);
              setMessaging(null);
              setSendResult(null);
            }}
          >
            <ArrowLeft className="h-4 w-4 mr-1" />
            Rooms
          </Button>
        </div>
      </div>

      {error && <p className="mt-4 text-destructive text-sm">{error}</p>}

      {sendResult && (
        <div className="mt-4 rounded-md border bg-muted/40 p-3 text-sm">
          {sendResult}
        </div>
      )}

      {messaging && (
        <div className="mt-4 rounded-lg border p-4 space-y-3">
          <p className="font-medium">
            Message {messaging.child_display_name}'s parents
          </p>
          <div className="flex flex-wrap gap-2">
            {[
              `Please report to Children's Ministry room ${room.room_name} immediately.`,
              "Your child is asking for you — please come to the classroom.",
              "Your child is not feeling well. Please come to the classroom.",
            ].map((quick) => (
              <Button
                key={quick}
                variant="outline"
                className="h-auto whitespace-normal py-2 text-left text-sm"
                onClick={() => setMessageText(quick)}
              >
                {quick}
              </Button>
            ))}
          </div>
          <Textarea
            value={messageText}
            onChange={(e) => setMessageText(e.target.value)}
            rows={3}
            className="text-base"
            placeholder="What should the parents be told?"
          />
          <div className="flex gap-2">
            <Button
              variant="outline"
              size="lg"
              onClick={() => {
                setMessaging(null);
                setMessageText("");
              }}
            >
              Cancel
            </Button>
            <Button
              size="lg"
              className="flex-1"
              disabled={sending || !messageText.trim() || !online}
              onClick={send}
            >
              {sending ? (
                <Loader2 className="h-5 w-5 mr-1 animate-spin" />
              ) : (
                <Send className="h-5 w-5 mr-1" />
              )}
              Send to parents
            </Button>
          </div>
        </div>
      )}

      <div className="mt-5 space-y-2">
        {roster.map((child) => (
          <div
            key={child.check_in_id}
            className="flex items-center gap-3 rounded-lg border p-4"
          >
            <span className="font-mono text-sm text-muted-foreground w-14 shrink-0">
              #{child.tag_number}
            </span>
            <div className="min-w-0 flex-1">
              <p className="text-lg font-medium truncate">
                {child.child_display_name}
              </p>
              <p className="text-sm text-muted-foreground">
                {child.minutes_in_room} min
              </p>
            </div>
            {child.has_allergy && (
              <Badge variant="outline" className="border-amber-400 gap-1 shrink-0">
                <AlertTriangle className="h-3.5 w-3.5" />
                Allergy
              </Badge>
            )}
            {child.has_restriction && (
              <Badge variant="destructive" className="gap-1 shrink-0">
                <ShieldAlert className="h-3.5 w-3.5" />
              </Badge>
            )}
            <Button
              variant="outline"
              size="lg"
              className="shrink-0"
              disabled={!online}
              onClick={() => {
                setSendResult(null);
                setMessaging(child);
                setMessageText(
                  `Please report to Children's Ministry room ${room.room_name} immediately.`
                );
              }}
            >
              <MessageSquare className="h-5 w-5" />
            </Button>
          </div>
        ))}
        {roster.length === 0 && !loading && (
          <p className="py-10 text-center text-muted-foreground">
            No children are checked into this room.
          </p>
        )}
      </div>
    </div>
  );
}
