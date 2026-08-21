/**
 * The self-service view of /members, shown to anyone who is not an admin.
 *
 * Mirrors how BudgetDashboard shows a contributor only their own expenses:
 * same route, different content. The server enforces the same split via RLS,
 * so this component cannot leak anything even if it tried.
 */

import { useState } from "react";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/shared/components/ui/card";
import { Badge } from "@/shared/components/ui/badge";
import { Button } from "@/shared/components/ui/button";
import { Input } from "@/shared/components/ui/input";
import { Label } from "@/shared/components/ui/label";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/shared/components/ui/dialog";
import {
  Loader2,
  Pencil,
  Home,
  HandHeart,
  UserRound,
  Info,
} from "lucide-react";
import { useToast } from "@/shared/hooks/use-toast";
import {
  useMyRecord,
  useMyHousehold,
  useMyServing,
  useUpdateMyContactDetails,
} from "../hooks/useMyInformation";
import { displayName } from "../utils/normalize";
import { formatBirthday, formatAge, yearsSinceAccepted } from "../utils/age";

export function MyInformation({ userId }: { userId: string | undefined }) {
  const { toast } = useToast();
  const recordQuery = useMyRecord(userId);
  const me = recordQuery.data;
  const householdQuery = useMyHousehold(me?.id);
  const servingQuery = useMyServing(me?.id);
  const updateContact = useUpdateMyContactDetails();

  const [isEditOpen, setIsEditOpen] = useState(false);
  const [phone, setPhone] = useState("");
  const [email, setEmail] = useState("");
  const [isSubmitting, setIsSubmitting] = useState(false);

  const openEdit = () => {
    setPhone(me?.phone ?? "");
    setEmail(me?.email ?? "");
    setIsEditOpen(true);
  };

  const handleSave = async () => {
    if (!me) return;
    setIsSubmitting(true);
    try {
      await updateContact.mutateAsync({ personId: me.id, phone, email });
      toast({ title: "Contact details updated" });
      setIsEditOpen(false);
    } catch (error) {
      toast({
        title: "Could not save",
        description: error instanceof Error ? error.message : "Please try again",
        variant: "destructive",
      });
    } finally {
      setIsSubmitting(false);
    }
  };

  if (recordQuery.isLoading) {
    return (
      <div className="flex items-center justify-center py-16">
        <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" />
      </div>
    );
  }

  // A login only maps to a member record once someone links it. Say so plainly
  // rather than showing an empty profile that looks broken.
  if (!me) {
    return (
      <Card className="border-dashed">
        <CardHeader className="text-center p-6">
          <Info className="h-10 w-10 mx-auto text-muted-foreground" />
          <CardTitle className="mt-3 text-lg">No member record linked</CardTitle>
          <CardDescription className="max-w-md mx-auto text-sm">
            Your sign-in is not yet connected to a member record in the church
            directory. Ask the church office to link your account, and your
            information will appear here.
          </CardDescription>
        </CardHeader>
      </Card>
    );
  }

  const acceptedYears = yearsSinceAccepted(me.accepted_lord_year, me.accepted_lord_month);

  return (
    <div className="space-y-4">
      <Card>
        <CardHeader className="pb-3">
          <div className="flex items-start justify-between gap-3">
            <div>
              <CardTitle className="text-lg flex items-center gap-2">
                <UserRound className="h-4 w-4" />
                {displayName(me)}
              </CardTitle>
              <CardDescription className="text-xs mt-1">
                Your record in the church directory
              </CardDescription>
            </div>
            <Button variant="outline" size="sm" onClick={openEdit}>
              <Pencil className="h-3.5 w-3.5 mr-1" />
              Edit contact
            </Button>
          </div>
        </CardHeader>
        <CardContent className="grid gap-3 sm:grid-cols-2">
          <Field label="Phone" value={me.phone ?? "—"} />
          <Field label="Email" value={me.email ?? "—"} />
          <Field label="Birthday" value={formatBirthday(me)} />
          <Field label="Age" value={formatAge(me)} />
          {me.member_since && <Field label="Member since" value={me.member_since} />}
          {acceptedYears !== null && (
            <Field label="Years since accepting the Lord" value={String(acceptedYears)} />
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-base flex items-center gap-2">
            <Home className="h-4 w-4" />
            My household
          </CardTitle>
        </CardHeader>
        <CardContent>
          {householdQuery.isLoading ? (
            <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
          ) : !householdQuery.data ? (
            <p className="text-sm text-muted-foreground">
              You are not currently linked to a household.
            </p>
          ) : (
            <div className="space-y-3">
              <p className="text-sm font-medium">{householdQuery.data.name}</p>
              <ul className="divide-y">
                {householdQuery.data.members.map((m) => (
                  <li key={m.id} className="flex items-center justify-between py-2">
                    <span className="text-sm">
                      {displayName(m)}
                      {m.id === me.id && (
                        <span className="text-muted-foreground text-xs"> (you)</span>
                      )}
                    </span>
                    <Badge variant="outline" className="capitalize">
                      {m.household_role}
                    </Badge>
                  </li>
                ))}
              </ul>
            </div>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-base flex items-center gap-2">
            <HandHeart className="h-4 w-4" />
            Where I serve
          </CardTitle>
        </CardHeader>
        <CardContent>
          {servingQuery.isLoading ? (
            <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
          ) : (servingQuery.data?.length ?? 0) === 0 ? (
            <p className="text-sm text-muted-foreground">
              You have no active ministry assignments on record.
            </p>
          ) : (
            <ul className="divide-y">
              {servingQuery.data!.map((a) => (
                <li key={a.id} className="flex items-center justify-between py-2">
                  <span className="text-sm font-medium">{a.ministry.name}</span>
                  <Badge variant={a.role?.is_leadership_role ? "default" : "secondary"}>
                    {a.role?.display_name ?? "Member"}
                  </Badge>
                </li>
              ))}
            </ul>
          )}
        </CardContent>
      </Card>

      <Dialog open={isEditOpen} onOpenChange={setIsEditOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>Edit contact details</DialogTitle>
            <DialogDescription>
              You can update your phone and email. Everything else — your name,
              birthday and membership status — is maintained by the church office.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-3">
            <div className="space-y-1.5">
              <Label htmlFor="my-phone">Phone</Label>
              <Input
                id="my-phone"
                value={phone}
                onChange={(e) => setPhone(e.target.value)}
                placeholder="301-555-0101"
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="my-email">Email</Label>
              <Input
                id="my-email"
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="you@example.com"
              />
            </div>
          </div>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setIsEditOpen(false)}
              disabled={isSubmitting}
            >
              Cancel
            </Button>
            <Button onClick={handleSave} disabled={isSubmitting}>
              {isSubmitting ? "Saving…" : "Save"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className="text-sm font-medium mt-0.5">{value}</p>
    </div>
  );
}
