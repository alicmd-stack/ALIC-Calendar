/**
 * Turn the people who already have logins into member records.
 *
 * The church has 62 logins and, until this is run, no members at all — so the
 * directory is empty, nobody can be assigned to a ministry or a classroom, and
 * every self-service screen has nothing to show. Linking a login to a member
 * record is also what switches on "see my own information", "my household",
 * and the volunteer eligibility check at the check-in desk, all of which are
 * keyed to church.people.profile_id.
 *
 * Shown with a preview first. It creates real people in the directory, so the
 * admin should see the name split before it happens rather than after.
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
import { Info, Loader2, UserPlus } from "lucide-react";
import { toast } from "sonner";
import { memberService } from "../services/memberService";
import type { ProfileBackfillRow } from "../types";

interface ProfileBackfillCardProps {
  organizationId: string | undefined;
  /** Shown prominently while the directory is empty. */
  memberCount: number;
  onDone: () => void;
}

export function ProfileBackfillCard({
  organizationId,
  memberCount,
  onDone,
}: ProfileBackfillCardProps) {
  const [preview, setPreview] = useState<ProfileBackfillRow[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [running, setRunning] = useState(false);

  async function loadPreview() {
    if (!organizationId) return;
    setLoading(true);
    try {
      setPreview(await memberService.previewProfileBackfill(organizationId));
    } catch (err) {
      toast.error("Could not read the logins", {
        description: err instanceof Error ? err.message : String(err),
      });
    } finally {
      setLoading(false);
    }
  }

  async function run() {
    if (!organizationId) return;
    setRunning(true);
    try {
      const result = await memberService.runProfileBackfill(organizationId);
      const parts = [
        result.created > 0 && `${result.created} created`,
        result.linked > 0 && `${result.linked} linked to existing members`,
        result.skipped > 0 && `${result.skipped} already done`,
      ].filter(Boolean) as string[];
      toast.success("Members set up from logins", {
        description: parts.join(", ") || "Nothing to do.",
      });
      setPreview(null);
      onDone();
    } catch (err) {
      toast.error("Could not set up members", {
        description: err instanceof Error ? err.message : String(err),
      });
    } finally {
      setRunning(false);
    }
  }

  const toCreate = (preview ?? []).filter((r) => r.action === "create member");
  const toLink = (preview ?? []).filter(
    (r) => r.action === "link to existing member"
  );
  const done = (preview ?? []).filter((r) => r.action === "already linked");
  // A single-word full_name has no surname to split out, so it is marked for
  // correction rather than guessed at.
  const noSurname = toCreate.filter((r) => !r.full_name.trim().includes(" "));

  return (
    <>
      <Card className={memberCount === 0 ? "border-primary" : undefined}>
        <CardHeader className="flex-row items-start justify-between space-y-0 gap-4">
          <div>
            <CardTitle className="text-base">
              {memberCount === 0
                ? "Start your directory from existing logins"
                : "Set up members from logins"}
            </CardTitle>
            <CardDescription>
              {memberCount === 0
                ? "People can already sign in, but none of them has a member record yet. This creates one for each, so they appear in the directory and can be added to ministries and classrooms."
                : "Create member records for anyone who can sign in but is not yet in the directory."}
            </CardDescription>
          </div>
          <Button
            variant={memberCount === 0 ? "default" : "outline"}
            size="sm"
            className="shrink-0"
            onClick={loadPreview}
            disabled={loading || !organizationId}
          >
            {loading ? (
              <Loader2 className="h-4 w-4 animate-spin" />
            ) : (
              <UserPlus className="h-4 w-4" />
            )}
            Review
          </Button>
        </CardHeader>
      </Card>

      <Dialog
        open={preview !== null}
        onOpenChange={(open) => !open && setPreview(null)}
      >
        <DialogContent className="max-w-2xl">
          <DialogHeader>
            <DialogTitle>Set up members from logins</DialogTitle>
            <DialogDescription>
              {toCreate.length} new member{toCreate.length === 1 ? "" : "s"} would
              be created
              {toLink.length > 0 &&
                `, ${toLink.length} matched to someone already in the directory by email`}
              {done.length > 0 && `, ${done.length} already done`}.
            </DialogDescription>
          </DialogHeader>

          {toCreate.length > 0 && (
            <Alert>
              <Info className="h-4 w-4" />
              <AlertDescription>
                Names are split at the first space, so "Mulhat Tesfaye Bekele"
                becomes Mulhat / Tesfaye Bekele — the father's and grandfather's
                names are kept together rather than one being dropped. Correct
                any of these afterwards on the member's page.
              </AlertDescription>
            </Alert>
          )}

          {noSurname.length > 0 && (
            <Alert>
              <Info className="h-4 w-4" />
              <AlertDescription>
                {noSurname.length} login
                {noSurname.length === 1 ? " has" : "s have"} only one word as a
                name ({noSurname.map((r) => r.full_name).join(", ")}). They will
                be marked "(no surname on file)" so you can find and fix them.
              </AlertDescription>
            </Alert>
          )}

          <div className="max-h-80 space-y-1.5 overflow-y-auto">
            {(preview ?? []).map((row) => (
              <div
                key={row.profile_id}
                className="flex items-center gap-3 rounded-md border p-2.5"
              >
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-medium truncate">{row.full_name}</p>
                  <p className="text-xs text-muted-foreground truncate">
                    {row.email ?? "no email"}
                    {row.matched_person_name && ` → ${row.matched_person_name}`}
                  </p>
                </div>
                <Badge
                  variant={
                    row.action === "create member"
                      ? "default"
                      : row.action === "link to existing member"
                        ? "secondary"
                        : "outline"
                  }
                  className="shrink-0"
                >
                  {row.action}
                </Badge>
              </div>
            ))}
            {(preview ?? []).length === 0 && (
              <p className="py-6 text-center text-sm text-muted-foreground">
                Every login already has a member record.
              </p>
            )}
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setPreview(null)}>
              Cancel
            </Button>
            <Button
              onClick={run}
              disabled={running || toCreate.length + toLink.length === 0}
            >
              {running && <Loader2 className="h-4 w-4 animate-spin" />}
              Create {toCreate.length + toLink.length} member
              {toCreate.length + toLink.length === 1 ? "" : "s"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
