/**
 * Registering a visiting family at the desk.
 *
 * The plan's "New Family desk". A family who has never been here arrives at
 * 10:15 with two children; until now the desk could look them up, fail, and
 * stop. The only way in was the member registration screen, which is twenty
 * fields and not something you work through with a queue behind you.
 *
 * SO THIS FORM IS THE SHORTEST ONE THAT IS STILL SAFE:
 *
 *   Guardian name and phone — the phone is how the room reaches this adult
 *   during the service, and how the desk finds them again next week.
 *
 *   Per child: name, birth year, and ALLERGIES. The allergy question is asked
 *   here or it is never asked at all. A visiting child with a peanut allergy
 *   nobody wrote down is exactly the failure this system exists to prevent,
 *   and there is no second chance later in the morning.
 *
 * Everything else — address, birthday, marital status, membership — is left
 * out on purpose. A visitor is not a member record yet, and making the desk
 * collect one is how the express lane turns into a five-minute queue.
 */

import { useState } from "react";
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
import { Loader2, Plus, Trash2, AlertTriangle } from "lucide-react";
import { cn } from "@/lib/utils";
import { kidsStationService } from "../services";
import { errorMessage } from "../services/rpcError";
import type { VisitorFamilyRow } from "../types";

interface ChildDraft {
  firstName: string;
  lastName: string;
  birthYear: string;
  hasAllergy: boolean;
  allergies: string;
  severity: string;
}

const emptyChild = (): ChildDraft => ({
  firstName: "",
  lastName: "",
  birthYear: "",
  hasAllergy: false,
  allergies: "",
  severity: "severe",
});

interface VisitorFamilyDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** Prefills the phone box when the volunteer already typed a number to search. */
  initialQuery?: string;
  onRegistered: (rows: VisitorFamilyRow[]) => void;
}

export function VisitorFamilyDialog({
  open,
  onOpenChange,
  initialQuery,
  onRegistered,
}: VisitorFamilyDialogProps) {
  const looksLikePhone = /\d{3}/.test(initialQuery ?? "");
  const [firstName, setFirstName] = useState("");
  const [lastName, setLastName] = useState("");
  const [phone, setPhone] = useState(looksLikePhone ? (initialQuery ?? "") : "");
  const [children, setChildren] = useState<ChildDraft[]>([emptyChild()]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const setChild = (i: number, patch: Partial<ChildDraft>) =>
    setChildren((cs) => cs.map((c, n) => (n === i ? { ...c, ...patch } : c)));

  const reset = () => {
    setFirstName("");
    setLastName("");
    setPhone("");
    setChildren([emptyChild()]);
    setError(null);
  };

  const submit = async () => {
    setError(null);
    const named = children.filter((c) => c.firstName.trim());
    if (!firstName.trim() || !lastName.trim()) {
      setError("Enter the parent's name.");
      return;
    }
    if (named.length === 0) {
      setError("Add at least one child.");
      return;
    }
    const missingYear = named.find((c) => !/^\d{4}$/.test(c.birthYear.trim()));
    if (missingYear) {
      setError(`Enter a birth year for ${missingYear.firstName.trim()}.`);
      return;
    }

    setBusy(true);
    try {
      const rows = await kidsStationService.registerVisitorFamily(
        {
          first_name: firstName.trim(),
          last_name: lastName.trim(),
          phone: phone.trim(),
        },
        named.map((c) => ({
          first_name: c.firstName.trim(),
          // Blank means "same as the parent's given name" — the database
          // applies the patronymic default.
          last_name: c.lastName.trim() || null,
          birth_year: c.birthYear.trim(),
          allergies: c.hasAllergy ? c.allergies.trim() || null : null,
          allergy_severity: c.hasAllergy ? c.severity : null,
        }))
      );
      reset();
      onRegistered(rows);
    } catch (err) {
      const raw = errorMessage(err);
      // A family already on file must become a SEARCH, never a second record:
      // a duplicate splits their pickup whitelist, and the parent gets refused
      // at the classroom door for a child they just dropped off.
      const dup = /family_already_exists:(.*)$/.exec(raw);
      setError(
        dup
          ? `${dup[1].trim()} is already registered. Close this and search for them instead.`
          : raw.includes("guardian_phone_required")
            ? "Enter a full phone number for the parent."
            : raw.includes("guardian_name_required")
              ? "Enter the parent's first and last name."
              : /child_birth_year_required:(.*)$/.test(raw)
                ? `Enter a birth year for ${/child_birth_year_required:(.*)$/.exec(raw)![1]}.`
                : raw.includes("not_permitted")
                  ? "You do not have permission to register a family."
                  : raw
      );
    } finally {
      setBusy(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={(o) => { if (!o) reset(); onOpenChange(o); }}>
      <DialogContent className="max-w-2xl max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Visiting family</DialogTitle>
          <DialogDescription>
            Just enough to check the children in safely. The office can complete
            the record later.
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4">
          <div className="grid grid-cols-2 gap-3">
            <div>
              <Label htmlFor="vf-first">Parent first name</Label>
              <Input
                id="vf-first"
                className="h-12 text-lg"
                value={firstName}
                onChange={(e) => setFirstName(e.target.value)}
                autoFocus
              />
            </div>
            <div>
              <Label htmlFor="vf-last">Parent last name</Label>
              <Input
                id="vf-last"
                className="h-12 text-lg"
                value={lastName}
                onChange={(e) => setLastName(e.target.value)}
              />
            </div>
          </div>

          <div>
            <Label htmlFor="vf-phone">Mobile number</Label>
            <Input
              id="vf-phone"
              className="h-12 text-lg"
              inputMode="tel"
              placeholder="301-555-0100"
              value={phone}
              onChange={(e) => setPhone(e.target.value)}
            />
            <p className="text-xs text-muted-foreground mt-1">
              How the classroom reaches you during the service.
            </p>
          </div>

          <div className="space-y-3">
            {children.map((c, i) => (
              <div key={i} className="rounded-lg border p-3 space-y-3">
                <div className="flex items-center justify-between">
                  <span className="text-sm font-medium">Child {i + 1}</span>
                  {children.length > 1 && (
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() =>
                        setChildren((cs) => cs.filter((_, n) => n !== i))
                      }
                    >
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  )}
                </div>

                <div className="grid grid-cols-[1fr_1fr_auto] gap-2">
                  <Input
                    className="h-11"
                    placeholder="First name"
                    value={c.firstName}
                    onChange={(e) => setChild(i, { firstName: e.target.value })}
                  />
                  <Input
                    className="h-11"
                    placeholder={firstName.trim() || "Second name"}
                    value={c.lastName}
                    onChange={(e) => setChild(i, { lastName: e.target.value })}
                  />
                  <Input
                    className="h-11 w-24"
                    inputMode="numeric"
                    placeholder="Born"
                    maxLength={4}
                    value={c.birthYear}
                    onChange={(e) => setChild(i, { birthYear: e.target.value })}
                  />
                </div>

                {/* Asked here or never. There is no second chance at 11:30. */}
                <label className="flex items-center gap-2 text-sm cursor-pointer">
                  <input
                    type="checkbox"
                    className="h-4 w-4"
                    checked={c.hasAllergy}
                    onChange={(e) => setChild(i, { hasAllergy: e.target.checked })}
                  />
                  Any allergies or medical needs?
                </label>

                {c.hasAllergy && (
                  <div className="rounded-md border-2 border-amber-400 bg-amber-50 p-3 space-y-2">
                    <div className="flex items-center gap-2 text-sm font-medium">
                      <AlertTriangle className="h-4 w-4 text-amber-600" />
                      This prints on the child's tag
                    </div>
                    <Input
                      className="h-11 bg-background"
                      placeholder="Peanuts, dairy…"
                      value={c.allergies}
                      onChange={(e) => setChild(i, { allergies: e.target.value })}
                    />
                    <div className="flex gap-2">
                      {[
                        ["mild", "Mild"],
                        ["severe", "Severe"],
                        ["life_threatening", "Life-threatening"],
                      ].map(([value, label]) => (
                        <button
                          key={value}
                          type="button"
                          onClick={() => setChild(i, { severity: value })}
                          className={cn(
                            "flex-1 rounded-md border-2 px-2 py-2 text-sm",
                            c.severity === value
                              ? "border-primary bg-primary/10 font-medium"
                              : "border-muted bg-background"
                          )}
                        >
                          {label}
                        </button>
                      ))}
                    </div>
                  </div>
                )}
              </div>
            ))}

            <Button
              variant="outline"
              className="w-full"
              onClick={() => setChildren((cs) => [...cs, emptyChild()])}
            >
              <Plus className="h-4 w-4 mr-1" />
              Another child
            </Button>
          </div>

          {error && (
            <p className="text-sm text-destructive font-medium">{error}</p>
          )}
        </div>

        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)} disabled={busy}>
            Cancel
          </Button>
          <Button onClick={submit} disabled={busy}>
            {busy && <Loader2 className="h-4 w-4 mr-1 animate-spin" />}
            Register and check in
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
