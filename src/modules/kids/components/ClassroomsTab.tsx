/**
 * Classroom setup: which rooms take children, and which age group each holds.
 *
 * Migration 20260320001500 seeded these from the room NAMES as an explicit
 * placeholder while the Kids Ministry director was asked for the real mapping.
 * This screen is how that answer gets entered — no migration, no deploy.
 */

import { useState } from "react";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/shared/components/ui/card";
import { Button } from "@/shared/components/ui/button";
import { Input } from "@/shared/components/ui/input";
import { Label } from "@/shared/components/ui/label";
import { Badge } from "@/shared/components/ui/badge";
import { Switch } from "@/shared/components/ui/switch";
import { Alert, AlertDescription } from "@/shared/components/ui/alert";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/shared/components/ui/select";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/shared/components/ui/dialog";
import { Info, Loader2, Pencil } from "lucide-react";
import { toast } from "sonner";
import { useClassrooms, useSetRoomConfig } from "../hooks/useKidsLeader";
import type { ClassroomRow } from "../services/kidsLeaderService";

const NO_BAND = "__none__";

interface ClassroomsTabProps {
  organizationId: string | undefined;
  canManage: boolean;
}

export function ClassroomsTab({ organizationId, canManage }: ClassroomsTabProps) {
  const { data, isLoading } = useClassrooms(organizationId);
  const setConfig = useSetRoomConfig(organizationId);
  const [editing, setEditing] = useState<ClassroomRow | null>(null);

  if (isLoading) {
    return (
      <div className="flex justify-center py-16 text-muted-foreground">
        <Loader2 className="h-6 w-6 animate-spin" />
      </div>
    );
  }

  const rooms = data?.rooms ?? [];
  const ageBands = data?.ageBands ?? [];
  const classrooms = rooms.filter((r) => r.config?.is_checkin_location);
  const others = rooms.filter((r) => !r.config?.is_checkin_location);

  return (
    <div className="space-y-4">
      <Alert>
        <Info className="h-4 w-4" />
        <AlertDescription>
          Age groups were set from the room names as a starting point. Edit any
          room to record what the ministry actually decided — check-in uses these
          to suggest a classroom.
        </AlertDescription>
      </Alert>

      <Card>
        <CardHeader>
          <CardTitle>Children's classrooms</CardTitle>
          <CardDescription>
            {classrooms.length} room{classrooms.length === 1 ? "" : "s"} accept
            children at check-in.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          {classrooms.length === 0 && (
            <p className="text-sm text-muted-foreground">
              No classrooms yet. Turn on a room below to start.
            </p>
          )}
          {classrooms.map((room) => (
            <RoomRow
              key={room.room_id}
              room={room}
              ageBands={ageBands}
              canManage={canManage}
              onEdit={() => setEditing(room)}
            />
          ))}
        </CardContent>
      </Card>

      {others.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Other rooms</CardTitle>
            <CardDescription>
              Not offered as a check-in destination. A room that is not a
              children's space should stay off.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-2">
            {others.map((room) => (
              <RoomRow
                key={room.room_id}
                room={room}
                ageBands={ageBands}
                canManage={canManage}
                onEdit={() => setEditing(room)}
              />
            ))}
          </CardContent>
        </Card>
      )}

      <ClassroomDialog
        room={editing}
        ageBands={ageBands}
        open={!!editing}
        saving={setConfig.isPending}
        onOpenChange={(open) => !open && setEditing(null)}
        onSave={async (values) => {
          try {
            await setConfig.mutateAsync(values);
            toast.success("Classroom updated");
            setEditing(null);
          } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            toast.error("Could not save", {
              description: message.includes("label_room_name_too_long")
                ? "The printed label name must be 20 characters or fewer."
                : message,
            });
          }
        }}
      />
    </div>
  );
}

function RoomRow({
  room,
  ageBands,
  canManage,
  onEdit,
}: {
  room: ClassroomRow;
  ageBands: { id: string; display_name: string }[];
  canManage: boolean;
  onEdit: () => void;
}) {
  const band = ageBands.find((b) => b.id === room.config?.kids_age_band_id);
  return (
    <div className="flex items-center gap-3 rounded-md border p-3">
      <div className="min-w-0 flex-1">
        <p className="font-medium truncate">{room.room_name}</p>
        <p className="text-xs text-muted-foreground truncate">
          {band ? band.display_name : "No age group"}
          {room.config?.capacity ? ` · up to ${room.config.capacity}` : ""}
          {room.config?.ratio_children_per_volunteer
            ? ` · 1 volunteer per ${room.config.ratio_children_per_volunteer}`
            : ""}
        </p>
      </div>
      {room.config?.label_room_name && (
        <Badge variant="outline" className="shrink-0 font-mono text-xs">
          {room.config.label_room_name}
        </Badge>
      )}
      {canManage && (
        <Button variant="ghost" size="icon" className="h-8 w-8" onClick={onEdit}>
          <Pencil className="h-4 w-4" />
        </Button>
      )}
    </div>
  );
}

interface ClassroomFormValues {
  roomId: string;
  isCheckinLocation: boolean;
  ageBandId: string | null;
  capacity: number | null;
  ratio: number | null;
  labelRoomName: string | null;
  sortOrder: number;
}

function ClassroomDialog({
  room,
  ageBands,
  open,
  saving,
  onOpenChange,
  onSave,
}: {
  room: ClassroomRow | null;
  ageBands: { id: string; display_name: string }[];
  open: boolean;
  saving: boolean;
  onOpenChange: (open: boolean) => void;
  onSave: (values: ClassroomFormValues) => void;
}) {
  // Keyed by room id so switching rooms remounts with that room's values
  // rather than carrying the previous room's edits across.
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        {room && (
          <ClassroomForm
            key={room.room_id}
            room={room}
            ageBands={ageBands}
            saving={saving}
            onSave={onSave}
          />
        )}
      </DialogContent>
    </Dialog>
  );
}

function ClassroomForm({
  room,
  ageBands,
  saving,
  onSave,
}: {
  room: ClassroomRow;
  ageBands: { id: string; display_name: string }[];
  saving: boolean;
  onSave: (values: ClassroomFormValues) => void;
}) {
  const cfg = room.config;
  const [isCheckin, setIsCheckin] = useState(cfg?.is_checkin_location ?? false);
  const [bandId, setBandId] = useState(cfg?.kids_age_band_id ?? NO_BAND);
  const [capacity, setCapacity] = useState(
    cfg?.capacity != null ? String(cfg.capacity) : ""
  );
  const [ratio, setRatio] = useState(
    cfg?.ratio_children_per_volunteer != null
      ? String(cfg.ratio_children_per_volunteer)
      : ""
  );
  const [label, setLabel] = useState(cfg?.label_room_name ?? "");
  const [sortOrder, setSortOrder] = useState(String(cfg?.sort_order ?? 0));

  return (
    <>
      <DialogHeader>
        <DialogTitle>{room.room_name}</DialogTitle>
        <DialogDescription>
          How this room is used for children's ministry.
        </DialogDescription>
      </DialogHeader>

      <div className="space-y-4 py-2">
        <div className="flex items-center justify-between rounded-md border p-3">
          <div>
            <Label className="text-sm">Accepts children at check-in</Label>
            <p className="text-xs text-muted-foreground">
              Off for rooms that are not children's spaces.
            </p>
          </div>
          <Switch checked={isCheckin} onCheckedChange={setIsCheckin} />
        </div>

        <div className="space-y-2">
          <Label>Age group</Label>
          <Select value={bandId} onValueChange={setBandId}>
            <SelectTrigger>
              <SelectValue placeholder="Choose an age group" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value={NO_BAND}>No age group</SelectItem>
              {ageBands.map((band) => (
                <SelectItem key={band.id} value={band.id}>
                  {band.display_name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          <p className="text-xs text-muted-foreground">
            Check-in suggests this room for children in this age group. Two rooms
            may share a group — children are sent to whichever is emptier.
          </p>
        </div>

        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-2">
            <Label>Capacity</Label>
            <Input
              type="number"
              min={1}
              value={capacity}
              onChange={(e) => setCapacity(e.target.value)}
              placeholder="No limit"
            />
          </div>
          <div className="space-y-2">
            <Label>Children per volunteer</Label>
            <Input
              type="number"
              min={1}
              value={ratio}
              onChange={(e) => setRatio(e.target.value)}
              placeholder="No target"
            />
          </div>
        </div>
        <p className="text-xs text-muted-foreground -mt-2">
          Both are warnings only. Check-in never turns a child away.
        </p>

        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-2">
            <Label>Name on the label</Label>
            <Input
              value={label}
              maxLength={20}
              onChange={(e) => setLabel(e.target.value)}
              placeholder={room.room_name.slice(0, 20)}
            />
            <p className="text-xs text-muted-foreground">
              {label.length}/20 — fits the printed tag.
            </p>
          </div>
          <div className="space-y-2">
            <Label>Order</Label>
            <Input
              type="number"
              value={sortOrder}
              onChange={(e) => setSortOrder(e.target.value)}
            />
          </div>
        </div>
      </div>

      <DialogFooter>
        <Button
          disabled={saving}
          onClick={() =>
            onSave({
              roomId: room.room_id,
              isCheckinLocation: isCheckin,
              ageBandId: bandId === NO_BAND ? null : bandId,
              capacity: capacity.trim() ? Number(capacity) : null,
              ratio: ratio.trim() ? Number(ratio) : null,
              labelRoomName: label.trim() || null,
              sortOrder: Number(sortOrder) || 0,
            })
          }
        >
          {saving && <Loader2 className="h-4 w-4 animate-spin" />}
          Save
        </Button>
      </DialogFooter>
    </>
  );
}
