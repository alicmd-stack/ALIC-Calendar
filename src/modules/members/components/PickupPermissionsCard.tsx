/**
 * Who may collect this child, and who must not.
 *
 * Until now these two lists could only be edited in Supabase Studio. That is
 * not a convenience gap: Studio does not require the restricted person's id,
 * so orders were recorded against a bare name — and a name-only order is the
 * shape that let a court-restricted child be released to the man the order
 * named. The database now treats a name-only order far more bluntly, switching
 * off household approval entirely, which is safe but blunt. Recording the
 * actual person is better for everyone, so this screen pushes towards it.
 */

import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
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
import { Alert, AlertDescription } from "@/shared/components/ui/alert";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/shared/components/ui/dialog";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/shared/components/ui/alert-dialog";
import {
  ShieldAlert,
  ShieldCheck,
  Loader2,
  Plus,
  Search,
  X,
  Info,
} from "lucide-react";
import { toast } from "sonner";
import { pickupService, type PickupPermission } from "../services/pickupService";
import { useMembers } from "../hooks/useMembers";
import { displayName } from "../utils/normalize";

const pickupKeys = {
  forChild: (id: string) => ["church", "pickup", id] as const,
};

interface PickupPermissionsCardProps {
  childPersonId: string;
  childName: string;
  organizationId: string | undefined;
  canEdit: boolean;
}

export function PickupPermissionsCard({
  childPersonId,
  childName,
  organizationId,
  canEdit,
}: PickupPermissionsCardProps) {
  const queryClient = useQueryClient();
  const [adding, setAdding] = useState<"authorized" | "restricted" | null>(null);
  const [ending, setEnding] = useState<PickupPermission | null>(null);

  const { data, isLoading } = useQuery({
    queryKey: pickupKeys.forChild(childPersonId),
    queryFn: () => pickupService.list(childPersonId),
    enabled: !!childPersonId,
  });

  const refresh = () =>
    queryClient.invalidateQueries({ queryKey: pickupKeys.forChild(childPersonId) });

  const authorized = (data ?? []).filter((p) => p.kind === "authorized");
  const restricted = (data ?? []).filter((p) => p.kind === "restricted");
  const nameOnly = restricted.filter((p) => p.is_name_only);

  if (isLoading) {
    return (
      <Card>
        <CardContent className="flex justify-center py-8">
          <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
        </CardContent>
      </Card>
    );
  }

  return (
    <>
      <Card className={restricted.length > 0 ? "border-destructive" : undefined}>
        <CardHeader className="pb-3">
          <CardTitle className="text-base flex items-center gap-2">
            <ShieldCheck className="h-4 w-4" />
            Pick-up
          </CardTitle>
          <CardDescription>
            Parents in this family can already collect {childName}. Add anyone
            else here, and record anyone who must not.
          </CardDescription>
        </CardHeader>

        <CardContent className="space-y-5">
          {nameOnly.length > 0 && (
            <Alert>
              <Info className="h-4 w-4" />
              <AlertDescription>
                {nameOnly.length === 1 ? "An order names" : "Orders name"}{" "}
                somebody who is not in the directory
                {" ("}
                {nameOnly.map((p) => p.display_name).join(", ")}
                {"). "}
                Because we cannot tell which person that is, check-in will not
                let <em>any</em> household adult collect {childName} without an
                explicit authorisation below. Adding them as a member and
                re-recording the order lifts that.
              </AlertDescription>
            </Alert>
          )}

          <section className="space-y-2">
            <div className="flex items-center justify-between">
              <p className="text-xs font-medium uppercase text-muted-foreground">
                May collect ({authorized.length})
              </p>
              {canEdit && (
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => setAdding("authorized")}
                >
                  <Plus className="h-4 w-4" />
                  Authorise someone
                </Button>
              )}
            </div>
            {authorized.length === 0 && (
              <p className="text-sm text-muted-foreground">
                Nobody beyond the family.
              </p>
            )}
            {authorized.map((p) => (
              <Row
                key={p.id}
                p={p}
                canEdit={canEdit}
                onEnd={() => setEnding(p)}
              />
            ))}
          </section>

          <section className="space-y-2">
            <div className="flex items-center justify-between">
              <p className="text-xs font-medium uppercase text-muted-foreground">
                Must not collect ({restricted.length})
              </p>
              {canEdit && (
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => setAdding("restricted")}
                >
                  <ShieldAlert className="h-4 w-4" />
                  Record an order
                </Button>
              )}
            </div>
            {restricted.length === 0 && (
              <p className="text-sm text-muted-foreground">
                No pick-up restrictions on file.
              </p>
            )}
            {restricted.map((p) => (
              <Row
                key={p.id}
                p={p}
                canEdit={canEdit}
                onEnd={() => setEnding(p)}
              />
            ))}
          </section>
        </CardContent>
      </Card>

      <AddDialog
        kind={adding}
        childPersonId={childPersonId}
        childName={childName}
        organizationId={organizationId}
        onClose={() => setAdding(null)}
        onDone={refresh}
      />

      <AlertDialog
        open={ending !== null}
        onOpenChange={(o) => !o && setEnding(null)}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>
              {ending?.kind === "restricted"
                ? `Lift the restriction on ${ending?.display_name}?`
                : `Remove ${ending?.display_name}?`}
            </AlertDialogTitle>
            <AlertDialogDescription>
              {ending?.kind === "restricted"
                ? `${ending?.display_name} will be able to collect ${childName} again if they are otherwise authorised. The record is kept, showing who lifted it and when.`
                : `${ending?.display_name} will no longer be able to collect ${childName}.`}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction
              onClick={async () => {
                if (!ending) return;
                try {
                  await pickupService.end(ending.id, ending.kind);
                  toast.success(
                    ending.kind === "restricted"
                      ? "Restriction lifted"
                      : "Authorisation removed"
                  );
                  setEnding(null);
                  refresh();
                } catch (err) {
                  toast.error(err instanceof Error ? err.message : String(err));
                }
              }}
            >
              {ending?.kind === "restricted" ? "Lift it" : "Remove"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}

function Row({
  p,
  canEdit,
  onEnd,
}: {
  p: PickupPermission;
  canEdit: boolean;
  onEnd: () => void;
}) {
  const restricted = p.kind === "restricted";
  return (
    <div
      className={
        "flex items-center gap-2 rounded-md border p-2.5 " +
        (restricted ? "border-destructive/40 bg-destructive/5" : "")
      }
    >
      {restricted ? (
        <ShieldAlert className="h-4 w-4 text-destructive shrink-0" />
      ) : (
        <ShieldCheck className="h-4 w-4 text-muted-foreground shrink-0" />
      )}
      <div className="min-w-0 flex-1">
        <p className="text-sm font-medium truncate">{p.display_name}</p>
        <p className="text-xs text-muted-foreground truncate">
          {p.note || (restricted ? "No reason recorded" : "No relationship noted")}
          {p.created_by_name && ` · added by ${p.created_by_name}`}
        </p>
      </div>
      {p.is_name_only && (
        <Badge variant="outline" className="shrink-0 border-amber-400">
          Name only
        </Badge>
      )}
      {canEdit && (
        <Button variant="ghost" size="icon" className="h-8 w-8" onClick={onEnd}>
          <X className="h-4 w-4" />
        </Button>
      )}
    </div>
  );
}

function AddDialog({
  kind,
  childPersonId,
  childName,
  organizationId,
  onClose,
  onDone,
}: {
  kind: "authorized" | "restricted" | null;
  childPersonId: string;
  childName: string;
  organizationId: string | undefined;
  onClose: () => void;
  onDone: () => void;
}) {
  const [search, setSearch] = useState("");
  const [picked, setPicked] = useState<{ id: string; name: string } | null>(null);
  const [freeName, setFreeName] = useState("");
  const [note, setNote] = useState("");
  const [saving, setSaving] = useState(false);

  const results = useMembers(
    search.trim().length >= 2 ? organizationId : undefined,
    { search: search.trim(), is_child: false },
    0,
    8
  );

  const restricted = kind === "restricted";

  const reset = () => {
    setSearch("");
    setPicked(null);
    setFreeName("");
    setNote("");
  };

  return (
    <Dialog
      open={kind !== null}
      onOpenChange={(o) => {
        if (!o) {
          reset();
          onClose();
        }
      }}
    >
      <DialogContent>
        <DialogHeader>
          <DialogTitle>
            {restricted
              ? `Record a pick-up restriction for ${childName}`
              : `Authorise someone to collect ${childName}`}
          </DialogTitle>
          <DialogDescription>
            {restricted
              ? "This person will never be released to, on any path. There is no override."
              : "Grandparents, a family friend, anyone outside the household."}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-3">
          <div className="space-y-2">
            <Label>Search the directory</Label>
            <div className="relative">
              <Search className="absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
              <Input
                className="pl-8"
                placeholder="Name"
                value={picked ? picked.name : search}
                onChange={(e) => {
                  setPicked(null);
                  setSearch(e.target.value);
                }}
              />
            </div>
          </div>

          {!picked && search.trim().length >= 2 && (
            <div className="max-h-48 space-y-1 overflow-y-auto">
              {(results.data?.rows ?? []).map((m) => (
                <button
                  key={m.id}
                  className="flex w-full items-center gap-2 rounded-md border p-2 text-left hover:bg-muted/50"
                  onClick={() => {
                    setPicked({ id: m.id, name: displayName(m) });
                    setFreeName("");
                  }}
                >
                  <span className="text-sm">{displayName(m)}</span>
                  {m.phone && (
                    <span className="ml-auto text-xs text-muted-foreground">
                      {m.phone}
                    </span>
                  )}
                </button>
              ))}
              {(results.data?.rows ?? []).length === 0 && !results.isLoading && (
                <p className="py-3 text-center text-xs text-muted-foreground">
                  Nobody in the directory matches.
                </p>
              )}
            </div>
          )}

          {restricted && !picked && (
            <div className="space-y-2 rounded-md border bg-muted/30 p-3">
              <Label>Or name someone not in the directory</Label>
              <Input
                value={freeName}
                onChange={(e) => setFreeName(e.target.value)}
                placeholder="Full name as it appears on the order"
              />
              <p className="text-xs text-muted-foreground">
                Use this only when the person has no member record. Because the
                system cannot tell which person the name refers to, it will stop
                treating <em>any</em> household adult as automatically approved
                for {childName} — so parents will need explicit authorisation.
                Choosing them from the directory above avoids that.
              </p>
            </div>
          )}

          <div className="space-y-2">
            <Label>{restricted ? "Reason" : "Relationship"}</Label>
            <Input
              value={note}
              onChange={(e) => setNote(e.target.value)}
              placeholder={
                restricted ? "Court order dated…" : "Grandmother, family friend"
              }
            />
          </div>
        </div>

        <DialogFooter>
          <Button
            variant="outline"
            onClick={() => {
              reset();
              onClose();
            }}
          >
            Cancel
          </Button>
          <Button
            variant={restricted ? "destructive" : "default"}
            disabled={saving || (!picked && !(restricted && freeName.trim()))}
            onClick={async () => {
              setSaving(true);
              try {
                if (restricted) {
                  await pickupService.restrict({
                    childPersonId,
                    personId: picked?.id ?? null,
                    personName: picked ? null : freeName.trim(),
                    reason: note.trim() || null,
                  });
                  toast.success("Restriction recorded");
                } else {
                  await pickupService.authorize(
                    childPersonId,
                    picked!.id,
                    note.trim() || undefined
                  );
                  toast.success("Authorised");
                }
                reset();
                onClose();
                onDone();
              } catch (err) {
                const raw = err instanceof Error ? err.message : String(err);
                toast.error("Could not save", {
                  description: raw.includes("person_is_restricted_for_this_child")
                    ? "There is already a restriction on file for this person. Lift it first."
                    : raw,
                });
              } finally {
                setSaving(false);
              }
            }}
          >
            {saving && <Loader2 className="h-4 w-4 animate-spin" />}
            {restricted ? "Record restriction" : "Authorise"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
