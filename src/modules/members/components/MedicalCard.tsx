/**
 * Allergies, medication and special needs.
 *
 * church.person_sensitive was read in four places and written by nothing, so
 * the safety card a volunteer opens while a child is reacting was empty for
 * every child, and the printed tag carried no allergy warning. This is the
 * screen that fills it.
 *
 * Kept in its own table and its own component because it is grantable
 * separately: only members_admin and kids_admin can see or change it, and
 * every read AND write is written to church.check_in_audit. That audit trail
 * is the entire basis on which org admins were given access to children's
 * medical data in the first place.
 */

import { useEffect, useState } from "react";
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
import { Textarea } from "@/shared/components/ui/textarea";
import { Badge } from "@/shared/components/ui/badge";
import { Alert, AlertDescription } from "@/shared/components/ui/alert";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/shared/components/ui/select";
import { AlertTriangle, HeartPulse, Loader2, Pencil } from "lucide-react";
import { toast } from "sonner";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { medicalService, type MedicalRecord } from "../services/medicalService";

const SEVERITIES = [
  { value: "none", label: "No allergy" },
  { value: "mild", label: "Mild" },
  { value: "severe", label: "Severe" },
  { value: "life_threatening", label: "Life-threatening" },
];

export const medicalKeys = {
  all: ["church", "medical"] as const,
  forPerson: (personId: string) => [...medicalKeys.all, personId] as const,
};

interface MedicalCardProps {
  personId: string;
  personName: string;
  isChild: boolean;
  canEdit: boolean;
}

export function MedicalCard({
  personId,
  personName,
  isChild,
  canEdit,
}: MedicalCardProps) {
  const queryClient = useQueryClient();
  const [editing, setEditing] = useState(false);

  const { data, isLoading } = useQuery({
    queryKey: medicalKeys.forPerson(personId),
    queryFn: () => medicalService.get(personId),
    enabled: !!personId,
  });

  const [form, setForm] = useState<MedicalRecord>({
    allergy_severity: "none",
    allergies: "",
    allergy_label_short: "",
    medications: "",
    medical_notes: "",
    special_needs: "",
    photo_consent: false,
  });

  // Seed the form from whatever is on file, once it arrives.
  useEffect(() => {
    if (!data) return;
    setForm({
      allergy_severity: data.allergy_severity ?? "none",
      allergies: data.allergies ?? "",
      allergy_label_short: data.allergy_label_short ?? "",
      medications: data.medications ?? "",
      medical_notes: data.medical_notes ?? "",
      special_needs: data.special_needs ?? "",
      photo_consent: data.photo_consent ?? false,
    });
  }, [data]);

  const save = useMutation({
    mutationFn: () => medicalService.save(personId, form),
    onSuccess: async () => {
      queryClient.invalidateQueries({ queryKey: medicalKeys.forPerson(personId) });
      // A child already in a room is wearing a tag printed before this edit.
      // Refresh the live check-in so the volunteers with them see it now.
      if (isChild) {
        try {
          const updated = await medicalService.refreshLiveCheckIns(personId);
          if (updated > 0) {
            toast.info("Updated where they are checked in", {
              description:
                "The classroom's roster now shows this, even though the printed tag does not.",
            });
          }
        } catch {
          // Non-fatal: the record is saved either way.
        }
      }
    },
  });

  const severe =
    data?.allergy_severity === "severe" ||
    data?.allergy_severity === "life_threatening";
  const hasAnything =
    data &&
    (data.allergy_severity !== "none" ||
      data.medications ||
      data.special_needs ||
      data.medical_notes);

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
    <Card className={severe ? "border-amber-400" : undefined}>
      <CardHeader className="flex-row items-start justify-between space-y-0 gap-4 pb-3">
        <div>
          <CardTitle className="text-base flex items-center gap-2">
            <HeartPulse className="h-4 w-4" />
            Medical and allergies
          </CardTitle>
          <CardDescription>
            {isChild
              ? "Shown on the printed tag and on the safety card a volunteer opens in an emergency."
              : "Visible to Members and Kids Ministry admins only."}
          </CardDescription>
        </div>
        {canEdit && !editing && (
          <Button
            variant="outline"
            size="sm"
            className="shrink-0"
            onClick={() => setEditing(true)}
          >
            <Pencil className="h-4 w-4" />
            {hasAnything ? "Edit" : "Add"}
          </Button>
        )}
      </CardHeader>

      <CardContent className="space-y-4">
        {!editing && !hasAnything && (
          <p className="text-sm text-muted-foreground">
            {isChild
              ? "Nothing on file. A volunteer opening this child's safety card during an emergency will see nothing."
              : "Nothing on file."}
          </p>
        )}

        {!editing && hasAnything && (
          <dl className="space-y-2 text-sm">
            {data?.allergy_severity !== "none" && (
              <div className="flex gap-3">
                <dt className="w-36 shrink-0 text-muted-foreground">Allergy</dt>
                <dd className="font-medium">
                  {data?.allergies || "Recorded"}
                  <Badge
                    variant={severe ? "destructive" : "outline"}
                    className="ml-2"
                  >
                    {
                      SEVERITIES.find((s) => s.value === data?.allergy_severity)
                        ?.label
                    }
                  </Badge>
                </dd>
              </div>
            )}
            {data?.allergy_label_short && (
              <div className="flex gap-3">
                <dt className="w-36 shrink-0 text-muted-foreground">On the tag</dt>
                <dd className="font-mono text-xs">{data.allergy_label_short}</dd>
              </div>
            )}
            {data?.medications && (
              <div className="flex gap-3">
                <dt className="w-36 shrink-0 text-muted-foreground">Medication</dt>
                <dd>{data.medications}</dd>
              </div>
            )}
            {data?.special_needs && (
              <div className="flex gap-3">
                <dt className="w-36 shrink-0 text-muted-foreground">
                  Special needs
                </dt>
                <dd>{data.special_needs}</dd>
              </div>
            )}
            {data?.medical_notes && (
              <div className="flex gap-3">
                <dt className="w-36 shrink-0 text-muted-foreground">Notes</dt>
                <dd className="text-muted-foreground">{data.medical_notes}</dd>
              </div>
            )}
          </dl>
        )}

        {editing && (
          <div className="space-y-4">
            {isChild && (
              <Alert>
                <AlertTriangle className="h-4 w-4" />
                <AlertDescription>
                  Anything marked here prints on {personName}'s tag and appears
                  on the safety card. Keep the tag text short — it has to be
                  readable across a busy room.
                </AlertDescription>
              </Alert>
            )}

            <div className="grid gap-3 sm:grid-cols-2">
              <div className="space-y-2">
                <Label>Severity</Label>
                <Select
                  value={form.allergy_severity ?? "none"}
                  onValueChange={(v) =>
                    setForm((f) => ({ ...f, allergy_severity: v }))
                  }
                >
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {SEVERITIES.map((s) => (
                      <SelectItem key={s.value} value={s.value}>
                        {s.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              <div className="space-y-2">
                <Label>Short text for the tag</Label>
                <Input
                  maxLength={24}
                  value={form.allergy_label_short ?? ""}
                  onChange={(e) =>
                    setForm((f) => ({ ...f, allergy_label_short: e.target.value }))
                  }
                  placeholder="PEANUT"
                />
                <p className="text-xs text-muted-foreground">
                  {(form.allergy_label_short ?? "").length}/24 — left blank, the
                  allergy text is shortened automatically.
                </p>
              </div>
            </div>

            <div className="space-y-2">
              <Label>Allergies</Label>
              <Input
                value={form.allergies ?? ""}
                onChange={(e) =>
                  setForm((f) => ({ ...f, allergies: e.target.value }))
                }
                placeholder="Peanuts, tree nuts"
              />
            </div>

            <div className="space-y-2">
              <Label>Medication</Label>
              <Input
                value={form.medications ?? ""}
                onChange={(e) =>
                  setForm((f) => ({ ...f, medications: e.target.value }))
                }
                placeholder="EpiPen in their bag"
              />
            </div>

            <div className="space-y-2">
              <Label>Special needs</Label>
              <Input
                value={form.special_needs ?? ""}
                onChange={(e) =>
                  setForm((f) => ({ ...f, special_needs: e.target.value }))
                }
                placeholder="Needs a quiet space when overwhelmed"
              />
            </div>

            <div className="space-y-2">
              <Label>Notes for volunteers</Label>
              <Textarea
                rows={3}
                value={form.medical_notes ?? ""}
                onChange={(e) =>
                  setForm((f) => ({ ...f, medical_notes: e.target.value }))
                }
                placeholder="Anything the person caring for them should know"
              />
            </div>

            <div className="flex gap-2">
              <Button
                variant="outline"
                onClick={() => {
                  setEditing(false);
                  if (data) {
                    setForm({
                      allergy_severity: data.allergy_severity ?? "none",
                      allergies: data.allergies ?? "",
                      allergy_label_short: data.allergy_label_short ?? "",
                      medications: data.medications ?? "",
                      medical_notes: data.medical_notes ?? "",
                      special_needs: data.special_needs ?? "",
                      photo_consent: data.photo_consent ?? false,
                    });
                  }
                }}
              >
                Cancel
              </Button>
              <Button
                className="flex-1"
                disabled={save.isPending}
                onClick={async () => {
                  try {
                    await save.mutateAsync();
                    toast.success("Medical record saved");
                    setEditing(false);
                  } catch (err) {
                    toast.error("Could not save", {
                      description:
                        err instanceof Error ? err.message : String(err),
                    });
                  }
                }}
              >
                {save.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
                Save
              </Button>
            </div>
          </div>
        )}

        {!editing && data?.updated_by_name && (
          <p className="text-xs text-muted-foreground">
            Last changed by {data.updated_by_name}
            {data.updated_at &&
              ` on ${new Date(data.updated_at).toLocaleDateString()}`}
            .
          </p>
        )}
      </CardContent>
    </Card>
  );
}
