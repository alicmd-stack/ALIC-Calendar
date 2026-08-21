/**
 * Full member registration — a page, not a dialog.
 *
 * Captures the whole family in one pass: the person, their household and
 * address, spouse (linked or created), children, emergency contacts and where
 * they would like to serve. Everything is submitted to a single RPC so a
 * failure cannot leave half a family behind.
 */

import { useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import DashboardLayout from "@/shared/components/layout/DashboardLayout";
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
import { Checkbox } from "@/shared/components/ui/checkbox";
import { Textarea } from "@/shared/components/ui/textarea";
import { Separator } from "@/shared/components/ui/separator";
import { Badge } from "@/shared/components/ui/badge";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/shared/components/ui/select";
import {
  UserPlus,
  Plus,
  Trash2,
  ArrowLeft,
  Loader2,
  Users,
  Home,
  Heart,
  Baby,
  Phone,
  HandHeart,
} from "lucide-react";
import { useToast } from "@/shared/hooks/use-toast";
import { useAuth } from "@/shared/contexts/AuthContext";
import { useOrganization } from "@/shared/contexts/OrganizationContext";
import { useCapabilities } from "@/shared/hooks/useCapabilities";
import { useMembershipStatuses, useMinistries, useSchoolGrades } from "../hooks/useReference";
import { useMembers } from "../hooks/useMembers";
import {
  useRegisterMember,
  registrationErrorMessage,
  type PersonPayload,
  type EmergencyContactPayload,
} from "../hooks/useRegisterMember";
import { MONTH_NAMES } from "../types";
import { displayName } from "../utils/normalize";

const NONE = "__none__";

const GENDERS = [
  { value: "male", label: "Male" },
  { value: "female", label: "Female" },
  { value: "unspecified", label: "Prefer not to say" },
];

/** Matches the CHECK constraint on church.people.marital_status. */
const MARITAL_STATUSES = [
  { value: "single", label: "Single" },
  { value: "married", label: "Married" },
  { value: "widowed", label: "Widowed" },
  { value: "divorced", label: "Divorced" },
  { value: "separated", label: "Separated" },
  { value: "other", label: "Other" },
];

interface ChildRow extends PersonPayload {
  key: string;
}

export default function MemberRegistrationPage() {
  const navigate = useNavigate();
  const { toast } = useToast();
  const { isAdmin } = useAuth();
  const { currentOrganization } = useOrganization();
  const { can } = useCapabilities();
  const orgId = currentOrganization?.id;

  const canRegister = isAdmin || can("members.write");

  const { data: statuses } = useMembershipStatuses(orgId);
  const { data: ministries } = useMinistries(orgId);
  const { data: grades } = useSchoolGrades(orgId);
  const register = useRegisterMember();

  const [saving, setSaving] = useState(false);

  // Primary person
  const [person, setPerson] = useState<PersonPayload>({
    first_name: "",
    last_name: "",
  });

  // Household + address
  const [captureHousehold, setCaptureHousehold] = useState(true);
  const [household, setHousehold] = useState({
    name: "",
    address_line1: "",
    address_line2: "",
    city: "",
    state: "",
    postal_code: "",
  });

  // Spouse
  const [spouseMode, setSpouseMode] = useState<"create" | "link">("create");
  const [spouse, setSpouse] = useState<PersonPayload>({ first_name: "", last_name: "" });
  const [spouseSearch, setSpouseSearch] = useState("");
  const [linkedSpouseId, setLinkedSpouseId] = useState<string | null>(null);
  const isMarried = person.marital_status === "married";

  // Children
  const [hasChildren, setHasChildren] = useState(false);
  const [children, setChildren] = useState<ChildRow[]>([]);

  // Emergency contacts
  const [contacts, setContacts] = useState<EmergencyContactPayload[]>([
    { name: "", phone: "", relationship: "" },
  ]);

  // Service interests
  const [interests, setInterests] = useState<string[]>([]);

  const spouseResults = useMembers(
    spouseMode === "link" && spouseSearch.trim().length >= 3 ? orgId : undefined,
    { search: spouseSearch.trim(), is_child: false },
    0,
    8
  );

  // Default the household name from the surname, which is what it almost
  // always is — still editable.
  const suggestedHouseholdName = useMemo(
    () => (person.last_name.trim() ? `${person.last_name.trim()} Household` : ""),
    [person.last_name]
  );

  const setP = (patch: Partial<PersonPayload>) => setPerson((p) => ({ ...p, ...patch }));

  const addChild = () =>
    setChildren((c) => [
      ...c,
      { key: crypto.randomUUID(), first_name: "", last_name: "" },
    ]);

  const updateChild = (key: string, patch: Partial<PersonPayload>) =>
    setChildren((c) => c.map((row) => (row.key === key ? { ...row, ...patch } : row)));

  const removeChild = (key: string) =>
    setChildren((c) => c.filter((row) => row.key !== key));

  const toggleInterest = (id: string) =>
    setInterests((v) => (v.includes(id) ? v.filter((x) => x !== id) : [...v, id]));

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!orgId) return;

    if (!person.first_name.trim() || !person.last_name.trim()) {
      toast({
        title: "Name required",
        description: "First and last name are both required.",
        variant: "destructive",
      });
      return;
    }

    // Caught here as well as in the database, so the person filling the form
    // gets told which child is missing a year rather than a generic failure.
    const childMissingYear = children.find(
      (c) => c.first_name.trim() && !String(c.birth_year ?? "").trim()
    );
    if (hasChildren && childMissingYear) {
      toast({
        title: "Birth year needed",
        description: `${childMissingYear.first_name || "A child"} needs a birth year — it decides their Kids Ministry classroom.`,
        variant: "destructive",
      });
      return;
    }

    setSaving(true);
    try {
      const result = await register.mutateAsync({
        organizationId: orgId,
        person,
        household: captureHousehold
          ? { ...household, name: household.name.trim() || suggestedHouseholdName }
          : null,
        spouse: !isMarried
          ? { mode: "none" }
          : spouseMode === "link" && linkedSpouseId
            ? { mode: "link", person_id: linkedSpouseId }
            : spouse.first_name.trim()
              ? {
                  mode: "create",
                  person: {
                    ...spouse,
                    last_name: spouse.last_name.trim() || person.last_name,
                    marital_status: "married",
                  },
                }
              : { mode: "none" },
        children: hasChildren
          ? children
              .filter((c) => c.first_name.trim())
              .map(({ key, ...rest }) => rest)
          : [],
        emergencyContacts: contacts.filter((c) => c.name.trim() && c.phone.trim()),
        serviceInterestMinistryIds: interests,
      });

      toast({
        title: "Member registered",
        description:
          result.out_child_count > 0
            ? `${person.first_name} added with ${result.out_child_count} ${result.out_child_count === 1 ? "child" : "children"}.`
            : `${person.first_name} added to the directory.`,
      });
      navigate("/members");
    } catch (error) {
      toast({
        title: "Could not register",
        description: registrationErrorMessage(error),
        variant: "destructive",
      });
    } finally {
      setSaving(false);
    }
  };

  if (!canRegister) {
    return (
      <DashboardLayout>
        <Card className="border-dashed">
          <CardHeader className="text-center p-6">
            <CardTitle className="text-lg">Not available</CardTitle>
            <CardDescription>
              You do not have permission to register members.
            </CardDescription>
          </CardHeader>
        </Card>
      </DashboardLayout>
    );
  }

  return (
    <DashboardLayout>
      <form onSubmit={handleSubmit} className="space-y-5 max-w-4xl">
        <div className="flex items-start gap-3">
          <Button
            type="button"
            variant="ghost"
            size="icon"
            onClick={() => navigate("/members")}
            aria-label="Back to members"
          >
            <ArrowLeft className="h-4 w-4" />
          </Button>
          <div className="p-2 rounded-xl bg-primary/10">
            <UserPlus className="h-6 w-6 text-primary" />
          </div>
          <div>
            <h1 className="text-2xl sm:text-3xl font-bold">Register a member</h1>
            <p className="text-sm text-muted-foreground mt-1">
              The whole family is saved together — if anything fails, nothing is created.
            </p>
          </div>
        </div>

        <Section icon={<Users className="h-4 w-4" />} title="Personal details">
          <Grid>
            <Field label="First name" required>
              <Input
                value={person.first_name}
                onChange={(e) => setP({ first_name: e.target.value })}
                required
              />
            </Field>
            <Field label="Middle name">
              <Input
                value={person.middle_name ?? ""}
                onChange={(e) => setP({ middle_name: e.target.value })}
              />
            </Field>
            <Field label="Last name" required>
              <Input
                value={person.last_name}
                onChange={(e) => setP({ last_name: e.target.value })}
                required
              />
            </Field>
            <Field label="Preferred name">
              <Input
                value={person.preferred_name ?? ""}
                onChange={(e) => setP({ preferred_name: e.target.value })}
                placeholder="What they go by"
              />
            </Field>
            <Field label="Amharic name">
              <Input
                value={person.amharic_name ?? ""}
                onChange={(e) => setP({ amharic_name: e.target.value })}
              />
            </Field>
            <Field label="Gender">
              <PickOne
                value={person.gender}
                onChange={(v) => setP({ gender: v })}
                options={GENDERS}
                placeholder="Not given"
              />
            </Field>
            <Field label="Birth month">
              <PickOne
                value={person.birth_month ? String(person.birth_month) : undefined}
                onChange={(v) => setP({ birth_month: v })}
                options={MONTH_NAMES.map((m, i) => ({ value: String(i + 1), label: m }))}
                placeholder="Not given"
              />
            </Field>
            <Field label="Birth year" hint="Day of birth is not recorded.">
              <Input
                inputMode="numeric"
                placeholder="e.g. 1985"
                value={person.birth_year ?? ""}
                onChange={(e) => setP({ birth_year: e.target.value })}
              />
            </Field>
            <Field label="Marital status">
              <PickOne
                value={person.marital_status}
                onChange={(v) => setP({ marital_status: v })}
                options={MARITAL_STATUSES}
                placeholder="Not given"
              />
            </Field>
          </Grid>
        </Section>

        <Section icon={<Phone className="h-4 w-4" />} title="Contact & membership">
          <Grid>
            <Field label="Phone">
              <Input
                value={person.phone ?? ""}
                onChange={(e) => setP({ phone: e.target.value })}
                placeholder="301-555-0101"
              />
            </Field>
            <Field label="Email">
              <Input
                type="email"
                value={person.email ?? ""}
                onChange={(e) => setP({ email: e.target.value })}
              />
            </Field>
            <Field label="Membership status">
              <PickOne
                value={person.membership_status_id}
                onChange={(v) => setP({ membership_status_id: v })}
                options={(statuses ?? []).map((s) => ({
                  value: s.id,
                  label: s.display_name,
                }))}
                placeholder="Not set"
              />
            </Field>
            <Field label="Member since">
              <Input
                type="date"
                value={person.member_since ?? ""}
                onChange={(e) => setP({ member_since: e.target.value })}
              />
            </Field>
          </Grid>
        </Section>

        <Section
          icon={<Heart className="h-4 w-4" />}
          title="Faith"
          description="Used for the Years Since Accepting the Lord report, which is calculated rather than stored."
        >
          <Grid>
            <Field label="Accepted the Lord — month">
              <PickOne
                value={
                  person.accepted_lord_month ? String(person.accepted_lord_month) : undefined
                }
                onChange={(v) => setP({ accepted_lord_month: v })}
                options={MONTH_NAMES.map((m, i) => ({ value: String(i + 1), label: m }))}
                placeholder="Not given"
              />
            </Field>
            <Field label="Accepted the Lord — year">
              <Input
                inputMode="numeric"
                placeholder="e.g. 2005"
                value={person.accepted_lord_year ?? ""}
                onChange={(e) => setP({ accepted_lord_year: e.target.value })}
              />
            </Field>
          </Grid>
          <label className="flex items-center gap-2 mt-3 text-sm">
            <Checkbox
              checked={!!person.accepted_lord_is_approximate}
              onCheckedChange={(v) => setP({ accepted_lord_is_approximate: !!v })}
            />
            This date is approximate
          </label>
        </Section>

        <Section
          icon={<Home className="h-4 w-4" />}
          title="Household & address"
          description="Stored once for the whole family rather than repeated on each person."
        >
          <label className="flex items-center gap-2 text-sm mb-3">
            <Checkbox
              checked={captureHousehold}
              onCheckedChange={(v) => setCaptureHousehold(!!v)}
            />
            Create a household for this family
          </label>
          {captureHousehold && (
            <Grid>
              <Field label="Household name">
                <Input
                  value={household.name}
                  onChange={(e) => setHousehold((h) => ({ ...h, name: e.target.value }))}
                  placeholder={suggestedHouseholdName || "e.g. Bekele Household"}
                />
              </Field>
              <Field label="Street address">
                <Input
                  value={household.address_line1}
                  onChange={(e) =>
                    setHousehold((h) => ({ ...h, address_line1: e.target.value }))
                  }
                />
              </Field>
              <Field label="Apt / unit">
                <Input
                  value={household.address_line2}
                  onChange={(e) =>
                    setHousehold((h) => ({ ...h, address_line2: e.target.value }))
                  }
                />
              </Field>
              <Field label="City">
                <Input
                  value={household.city}
                  onChange={(e) => setHousehold((h) => ({ ...h, city: e.target.value }))}
                />
              </Field>
              <Field label="State">
                <Input
                  value={household.state}
                  onChange={(e) => setHousehold((h) => ({ ...h, state: e.target.value }))}
                  placeholder="MD"
                />
              </Field>
              <Field label="ZIP">
                <Input
                  value={household.postal_code}
                  onChange={(e) =>
                    setHousehold((h) => ({ ...h, postal_code: e.target.value }))
                  }
                />
              </Field>
            </Grid>
          )}
        </Section>

        {isMarried && (
          <Section icon={<Heart className="h-4 w-4" />} title="Spouse">
            <div className="flex gap-2 mb-4">
              <Button
                type="button"
                variant={spouseMode === "create" ? "default" : "outline"}
                size="sm"
                onClick={() => setSpouseMode("create")}
              >
                New to the directory
              </Button>
              <Button
                type="button"
                variant={spouseMode === "link" ? "default" : "outline"}
                size="sm"
                onClick={() => setSpouseMode("link")}
              >
                Already a member
              </Button>
            </div>

            {spouseMode === "link" ? (
              <div className="space-y-2">
                <Field label="Search for the spouse">
                  <Input
                    value={spouseSearch}
                    onChange={(e) => {
                      setSpouseSearch(e.target.value);
                      setLinkedSpouseId(null);
                    }}
                    placeholder="Type at least 3 letters of their name"
                  />
                </Field>
                {spouseResults.data?.rows.map((m) => (
                  <button
                    type="button"
                    key={m.id}
                    onClick={() => setLinkedSpouseId(m.id)}
                    className={`w-full text-left rounded-md border px-3 py-2 text-sm ${
                      linkedSpouseId === m.id ? "border-primary bg-primary/5" : ""
                    }`}
                  >
                    {displayName(m)}
                    {linkedSpouseId === m.id && (
                      <Badge className="ml-2" variant="secondary">
                        Selected
                      </Badge>
                    )}
                  </button>
                ))}
                {spouseSearch.trim().length >= 3 &&
                  spouseResults.data?.rows.length === 0 && (
                    <p className="text-sm text-muted-foreground">
                      No match. Use “New to the directory” to create their record.
                    </p>
                  )}
              </div>
            ) : (
              <Grid>
                <Field label="First name">
                  <Input
                    value={spouse.first_name}
                    onChange={(e) =>
                      setSpouse((s) => ({ ...s, first_name: e.target.value }))
                    }
                  />
                </Field>
                <Field label="Last name" hint="Defaults to the family surname.">
                  <Input
                    value={spouse.last_name}
                    onChange={(e) =>
                      setSpouse((s) => ({ ...s, last_name: e.target.value }))
                    }
                    placeholder={person.last_name}
                  />
                </Field>
                <Field label="Gender">
                  <PickOne
                    value={spouse.gender}
                    onChange={(v) => setSpouse((s) => ({ ...s, gender: v }))}
                    options={GENDERS}
                    placeholder="Not given"
                  />
                </Field>
                <Field label="Phone">
                  <Input
                    value={spouse.phone ?? ""}
                    onChange={(e) => setSpouse((s) => ({ ...s, phone: e.target.value }))}
                  />
                </Field>
                <Field label="Birth month">
                  <PickOne
                    value={spouse.birth_month ? String(spouse.birth_month) : undefined}
                    onChange={(v) => setSpouse((s) => ({ ...s, birth_month: v }))}
                    options={MONTH_NAMES.map((m, i) => ({
                      value: String(i + 1),
                      label: m,
                    }))}
                    placeholder="Not given"
                  />
                </Field>
                <Field label="Birth year">
                  <Input
                    inputMode="numeric"
                    value={spouse.birth_year ?? ""}
                    onChange={(e) =>
                      setSpouse((s) => ({ ...s, birth_year: e.target.value }))
                    }
                  />
                </Field>
              </Grid>
            )}
          </Section>
        )}

        <Section icon={<Baby className="h-4 w-4" />} title="Children">
          <label className="flex items-center gap-2 text-sm">
            <Checkbox
              checked={hasChildren}
              onCheckedChange={(v) => {
                const on = !!v;
                setHasChildren(on);
                if (on && children.length === 0) addChild();
              }}
            />
            This family has children
          </label>

          {hasChildren && (
            <div className="mt-4 space-y-4">
              <p className="text-xs text-muted-foreground">
                Each child gets their own member record, so they can be checked in to
                Kids Ministry. Both parents are automatically authorised to collect them.
              </p>
              {children.map((child, idx) => (
                <div key={child.key} className="rounded-md border p-3 space-y-3">
                  <div className="flex items-center justify-between">
                    <span className="text-sm font-medium">Child {idx + 1}</span>
                    <Button
                      type="button"
                      variant="ghost"
                      size="icon"
                      onClick={() => removeChild(child.key)}
                      aria-label="Remove child"
                    >
                      <Trash2 className="h-4 w-4 text-muted-foreground" />
                    </Button>
                  </div>
                  <Grid>
                    <Field label="First name" required>
                      <Input
                        value={child.first_name}
                        onChange={(e) =>
                          updateChild(child.key, { first_name: e.target.value })
                        }
                      />
                    </Field>
                    <Field label="Last name" hint="Defaults to the family surname.">
                      <Input
                        value={child.last_name}
                        onChange={(e) =>
                          updateChild(child.key, { last_name: e.target.value })
                        }
                        placeholder={person.last_name}
                      />
                    </Field>
                    <Field label="Birth month">
                      <PickOne
                        value={child.birth_month ? String(child.birth_month) : undefined}
                        onChange={(v) => updateChild(child.key, { birth_month: v })}
                        options={MONTH_NAMES.map((m, i) => ({
                          value: String(i + 1),
                          label: m,
                        }))}
                        placeholder="Not given"
                      />
                    </Field>
                    <Field label="Birth year" required hint="Decides their classroom.">
                      <Input
                        inputMode="numeric"
                        value={child.birth_year ?? ""}
                        onChange={(e) =>
                          updateChild(child.key, { birth_year: e.target.value })
                        }
                      />
                    </Field>
                    <Field label="Gender">
                      <PickOne
                        value={child.gender}
                        onChange={(v) => updateChild(child.key, { gender: v })}
                        options={GENDERS}
                        placeholder="Not given"
                      />
                    </Field>
                    <Field label="School grade">
                      <PickOne
                        value={child.school_grade_id}
                        onChange={(v) => updateChild(child.key, { school_grade_id: v })}
                        options={(grades ?? []).map((g) => ({
                          value: g.id,
                          label: g.display_name,
                        }))}
                        placeholder="Not given"
                      />
                    </Field>
                  </Grid>
                </div>
              ))}
              <Button type="button" variant="outline" size="sm" onClick={addChild}>
                <Plus className="h-4 w-4 mr-1" />
                Add another child
              </Button>
            </div>
          )}
        </Section>

        <Section
          icon={<Phone className="h-4 w-4" />}
          title="Emergency contact"
          description="Required before a child can be checked in to Kids Ministry. Applied to every child in this family."
        >
          <div className="space-y-3">
            {contacts.map((c, idx) => (
              <Grid key={idx}>
                <Field label="Name">
                  <Input
                    value={c.name}
                    onChange={(e) =>
                      setContacts((all) =>
                        all.map((x, i) => (i === idx ? { ...x, name: e.target.value } : x))
                      )
                    }
                  />
                </Field>
                <Field label="Phone">
                  <Input
                    value={c.phone}
                    onChange={(e) =>
                      setContacts((all) =>
                        all.map((x, i) => (i === idx ? { ...x, phone: e.target.value } : x))
                      )
                    }
                  />
                </Field>
                <Field label="Relationship">
                  <Input
                    value={c.relationship ?? ""}
                    onChange={(e) =>
                      setContacts((all) =>
                        all.map((x, i) =>
                          i === idx ? { ...x, relationship: e.target.value } : x
                        )
                      )
                    }
                    placeholder="e.g. Aunt"
                  />
                </Field>
              </Grid>
            ))}
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={() =>
                setContacts((all) => [...all, { name: "", phone: "", relationship: "" }])
              }
            >
              <Plus className="h-4 w-4 mr-1" />
              Add contact
            </Button>
          </div>
        </Section>

        <Section
          icon={<HandHeart className="h-4 w-4" />}
          title="Where would they like to serve?"
          description="Feeds the service interest pipeline — people interested in a ministry who are not serving in it yet."
        >
          <div className="flex flex-wrap gap-2">
            {(ministries ?? []).map((m) => (
              <button
                type="button"
                key={m.id}
                onClick={() => toggleInterest(m.id)}
                className={`rounded-full border px-3 py-1 text-sm ${
                  interests.includes(m.id)
                    ? "border-primary bg-primary/10 text-primary"
                    : "text-muted-foreground"
                }`}
              >
                {m.name}
              </button>
            ))}
            {(ministries ?? []).length === 0 && (
              <p className="text-sm text-muted-foreground">
                No ministries configured for this branch yet.
              </p>
            )}
          </div>
        </Section>

        <Section icon={<Users className="h-4 w-4" />} title="Notes">
          <Textarea
            value={person.notes ?? ""}
            onChange={(e) => setP({ notes: e.target.value })}
            placeholder="Anything else the office should know"
            rows={3}
          />
        </Section>

        <Separator />

        <div className="flex items-center justify-end gap-2 pb-8">
          <Button
            type="button"
            variant="outline"
            onClick={() => navigate("/members")}
            disabled={saving}
          >
            Cancel
          </Button>
          <Button type="submit" disabled={saving}>
            {saving && <Loader2 className="h-4 w-4 mr-1 animate-spin" />}
            {saving ? "Registering…" : "Register member"}
          </Button>
        </div>
      </form>
    </DashboardLayout>
  );
}

/* ---------------------------------------------------------------- helpers */

function Section({
  icon,
  title,
  description,
  children,
}: {
  icon: React.ReactNode;
  title: string;
  description?: string;
  children: React.ReactNode;
}) {
  return (
    <Card>
      <CardHeader className="pb-3">
        <CardTitle className="text-base flex items-center gap-2">
          {icon}
          {title}
        </CardTitle>
        {description && (
          <CardDescription className="text-xs">{description}</CardDescription>
        )}
      </CardHeader>
      <CardContent>{children}</CardContent>
    </Card>
  );
}

function Grid({ children }: { children: React.ReactNode }) {
  return <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">{children}</div>;
}

function Field({
  label,
  required,
  hint,
  children,
}: {
  label: string;
  required?: boolean;
  hint?: string;
  children: React.ReactNode;
}) {
  return (
    <div className="space-y-1.5">
      <Label className="text-xs">
        {label}
        {required && <span className="text-destructive"> *</span>}
      </Label>
      {children}
      {hint && <p className="text-[11px] text-muted-foreground">{hint}</p>}
    </div>
  );
}

function PickOne({
  value,
  onChange,
  options,
  placeholder,
}: {
  value?: string;
  onChange: (v: string) => void;
  options: { value: string; label: string }[];
  placeholder: string;
}) {
  return (
    <Select
      value={value || NONE}
      onValueChange={(v) => onChange(v === NONE ? "" : v)}
    >
      <SelectTrigger>
        <SelectValue placeholder={placeholder} />
      </SelectTrigger>
      <SelectContent>
        <SelectItem value={NONE}>{placeholder}</SelectItem>
        {options.map((o) => (
          <SelectItem key={o.value} value={o.value}>
            {o.label}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
}
