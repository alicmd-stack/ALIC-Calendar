/**
 * Member profile — the complete picture of one person.
 *
 * Satisfies MEM-006: ministry service, group participation, service interests
 * and family relationships on one screen, joined by person id rather than by
 * name.
 */

import { useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import DashboardLayout from "@/shared/components/layout/DashboardLayout";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/shared/components/ui/card";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/shared/components/ui/tabs";
import { MedicalCard } from "../components/MedicalCard";
import { Badge } from "@/shared/components/ui/badge";
import { Button } from "@/shared/components/ui/button";
import { Avatar, AvatarFallback } from "@/shared/components/ui/avatar";
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
  ArrowLeft,
  Loader2,
  Baby,
  HandHeart,
  Users as UsersIcon,
  BookOpen,
  Archive,
  RotateCcw,
  Home,
} from "lucide-react";
import { useToast } from "@/shared/hooks/use-toast";
import { useAuth } from "@/shared/contexts/AuthContext";
import { useCapabilities } from "@/shared/hooks/useCapabilities";
import {
  useMemberProfile,
  useDeactivateMember,
  useReactivateMember,
} from "../hooks/useMembers";
import { useMemberServing } from "../hooks/useServing";
import { displayName, initials } from "../utils/normalize";
import {
  formatAge,
  formatBirthday,
  suggestAgeBand,
  adultAgeGroup,
  yearsSinceAccepted,
} from "../utils/age";
import {
  AGE_BAND_LABELS,
  ADULT_AGE_GROUP_LABELS,
  SERVICE_INTEREST_STATUS_CONFIG,
} from "../types";

export default function MemberProfilePage() {
  const { memberId } = useParams<{ memberId: string }>();
  const navigate = useNavigate();
  const { toast } = useToast();
  const { isAdmin } = useAuth();
  const { can } = useCapabilities();
  const canWrite = isAdmin || can("members.write");

  const profileQuery = useMemberProfile(memberId);
  const servingQuery = useMemberServing(memberId);
  const deactivate = useDeactivateMember();
  const reactivate = useReactivateMember();
  const [confirmArchive, setConfirmArchive] = useState(false);

  const member = profileQuery.data;

  if (profileQuery.isLoading) {
    return (
      <DashboardLayout>
        <div className="flex items-center justify-center py-20">
          <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" />
        </div>
      </DashboardLayout>
    );
  }

  if (profileQuery.isError || !member) {
    return (
      <DashboardLayout>
        <Card className="border-dashed">
          <CardHeader className="text-center p-6">
            <CardTitle className="text-lg">Member not found</CardTitle>
            <CardDescription>
              {profileQuery.error instanceof Error
                ? profileQuery.error.message
                : "This person is not in the directory, or you do not have access to them."}
            </CardDescription>
            <Button className="mt-4 mx-auto" onClick={() => navigate("/members")}>
              Back to members
            </Button>
          </CardHeader>
        </Card>
      </DashboardLayout>
    );
  }

  const acceptedYears = yearsSinceAccepted(
    member.accepted_lord_year,
    member.accepted_lord_month
  );
  const ageGroup = member.is_child
    ? AGE_BAND_LABELS[suggestAgeBand(member)]
    : ADULT_AGE_GROUP_LABELS[adultAgeGroup(member)];

  const handleArchive = async () => {
    try {
      if (member.is_active) {
        await deactivate.mutateAsync({
          memberId: member.id,
          reason: "Archived from member profile",
        });
        toast({ title: "Member archived", description: "Their history is preserved." });
      } else {
        await reactivate.mutateAsync(member.id);
        toast({ title: "Member reactivated" });
      }
      setConfirmArchive(false);
    } catch (error) {
      toast({
        title: "Could not update",
        description: error instanceof Error ? error.message : "Please try again",
        variant: "destructive",
      });
    }
  };

  return (
    <DashboardLayout>
      <div className="space-y-5 max-w-5xl">
        <div className="flex items-start gap-3">
          <Button
            variant="ghost"
            size="icon"
            onClick={() => navigate("/members")}
            aria-label="Back to members"
          >
            <ArrowLeft className="h-4 w-4" />
          </Button>
          <Avatar className="h-14 w-14">
            <AvatarFallback className="text-lg">{initials(member)}</AvatarFallback>
          </Avatar>
          <div className="flex-1">
            <h1 className="text-2xl sm:text-3xl font-bold flex items-center gap-2">
              {displayName(member)}
              {member.is_child && <Baby className="h-5 w-5 text-muted-foreground" />}
            </h1>
            <div className="flex flex-wrap items-center gap-2 mt-1.5">
              {member.is_active ? (
                <Badge variant="secondary">Active</Badge>
              ) : (
                <Badge variant="outline" className="text-muted-foreground">
                  Inactive
                </Badge>
              )}
              {member.membership_status && (
                <Badge variant="outline">{member.membership_status.display_name}</Badge>
              )}
              <Badge variant="outline">{ageGroup}</Badge>
              {member.amharic_name && (
                <span className="text-sm text-muted-foreground">{member.amharic_name}</span>
              )}
            </div>
          </div>
          {canWrite && (
            <Button variant="outline" size="sm" onClick={() => setConfirmArchive(true)}>
              {member.is_active ? (
                <>
                  <Archive className="h-3.5 w-3.5 mr-1" />
                  Archive
                </>
              ) : (
                <>
                  <RotateCcw className="h-3.5 w-3.5 mr-1" />
                  Reactivate
                </>
              )}
            </Button>
          )}
        </div>

        <Tabs defaultValue="overview">
          <TabsList className="grid grid-cols-5 w-full sm:w-auto sm:inline-flex">
            {["overview", "family", "medical", "serving", "groups"].map((t) => (
              <TabsTrigger
                key={t}
                value={t}
                className="capitalize data-[state=active]:bg-primary data-[state=active]:text-primary-foreground"
              >
                {t}
              </TabsTrigger>
            ))}
          </TabsList>

          <TabsContent value="overview" className="mt-4">
            <Card>
              <CardHeader className="pb-3">
                <CardTitle className="text-base">Details</CardTitle>
              </CardHeader>
              <CardContent className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
                <Detail label="Phone" value={member.phone} />
                <Detail label="Email" value={member.email} />
                {/* Month and year only — no day of birth is stored anywhere. */}
                <Detail label="Birthday" value={formatBirthday(member)} />
                <Detail label="Age" value={formatAge(member)} />
                <Detail label="Gender" value={member.gender} capitalize />
                <Detail label="Marital status" value={member.marital_status} capitalize />
                <Detail label="Member since" value={member.member_since} />
                <Detail
                  label="Accepted the Lord"
                  value={
                    member.accepted_lord_year
                      ? `${formatBirthday({
                          birth_year: member.accepted_lord_year,
                          birth_month: member.accepted_lord_month,
                        })}${member.accepted_lord_is_approximate ? " (approx.)" : ""}`
                      : null
                  }
                />
                <Detail
                  label="Years since accepting"
                  value={acceptedYears === null ? null : String(acceptedYears)}
                />
                {member.member_number && (
                  <Detail label="Member number" value={member.member_number} />
                )}
              </CardContent>
              {member.notes && (
                <CardContent className="pt-0">
                  <p className="text-xs text-muted-foreground">Notes</p>
                  <p className="text-sm mt-1 whitespace-pre-wrap">{member.notes}</p>
                </CardContent>
              )}
            </Card>
          </TabsContent>

          <TabsContent value="family" className="mt-4 space-y-4">
            <Card>
              <CardHeader className="pb-3">
                <CardTitle className="text-base flex items-center gap-2">
                  <Home className="h-4 w-4" />
                  Family relationships
                </CardTitle>
                <CardDescription className="text-xs">
                  Each relationship is stored once; the inverse is created
                  automatically, so both people always agree.
                </CardDescription>
              </CardHeader>
              <CardContent>
                {(member.relationships?.length ?? 0) === 0 ? (
                  <Empty text="No family relationships recorded." />
                ) : (
                  <ul className="divide-y">
                    {member.relationships!.map((r) => (
                      <li
                        key={r.id}
                        className="flex items-center justify-between py-2 cursor-pointer"
                        onClick={() => navigate(`/members/${r.related_person.id}`)}
                      >
                        <span className="text-sm font-medium flex items-center gap-2">
                          {r.related_person.is_child && (
                            <Baby className="h-3.5 w-3.5 text-muted-foreground" />
                          )}
                          {r.related_person.first_name} {r.related_person.last_name}
                        </span>
                        <Badge variant="outline">
                          {r.relationship_type?.display_name ?? "Related"}
                        </Badge>
                      </li>
                    ))}
                  </ul>
                )}
              </CardContent>
            </Card>
          </TabsContent>

          <TabsContent value="medical" className="mt-4 space-y-4">
            <MedicalCard
              personId={member.id}
              personName={member.first_name}
              isChild={member.is_child}
              canEdit={canWrite}
            />
          </TabsContent>

          <TabsContent value="serving" className="mt-4 space-y-4">
            <Card>
              <CardHeader className="pb-3">
                <CardTitle className="text-base flex items-center gap-2">
                  <HandHeart className="h-4 w-4" />
                  Ministry service
                </CardTitle>
              </CardHeader>
              <CardContent>
                {servingQuery.isLoading ? (
                  <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
                ) : (servingQuery.data?.length ?? 0) === 0 ? (
                  <Empty text="Not currently serving in any ministry." />
                ) : (
                  <ul className="divide-y">
                    {servingQuery.data!.map((a) => (
                      <li key={a.id} className="flex items-center justify-between py-2">
                        <div>
                          <p className="text-sm font-medium">{a.ministry.name}</p>
                          {a.start_date && (
                            <p className="text-xs text-muted-foreground">
                              Since {a.start_date}
                            </p>
                          )}
                        </div>
                        <Badge
                          variant={a.role?.is_leadership_role ? "default" : "secondary"}
                        >
                          {a.role?.display_name ?? "Member"}
                        </Badge>
                      </li>
                    ))}
                  </ul>
                )}
              </CardContent>
            </Card>

            <Card>
              <CardHeader className="pb-3">
                <CardTitle className="text-base">Wants to serve in</CardTitle>
                <CardDescription className="text-xs">
                  Interests that have not yet become an assignment.
                </CardDescription>
              </CardHeader>
              <CardContent>
                {(member.service_interests?.length ?? 0) === 0 ? (
                  <Empty text="No service interests recorded." />
                ) : (
                  <ul className="divide-y">
                    {member.service_interests!.map((i) => {
                      const cfg = SERVICE_INTEREST_STATUS_CONFIG[i.status];
                      return (
                        <li key={i.id} className="flex items-center justify-between py-2">
                          <span className="text-sm">{i.interest_level} interest</span>
                          <Badge className={cfg ? `${cfg.bgColor} ${cfg.color}` : ""} variant="outline">
                            {cfg?.label ?? i.status}
                          </Badge>
                        </li>
                      );
                    })}
                  </ul>
                )}
              </CardContent>
            </Card>
          </TabsContent>

          <TabsContent value="groups" className="mt-4">
            <Card>
              <CardHeader className="pb-3">
                <CardTitle className="text-base flex items-center gap-2">
                  <BookOpen className="h-4 w-4" />
                  Home cell / Bible study
                </CardTitle>
              </CardHeader>
              <CardContent>
                {(member.group_memberships?.length ?? 0) === 0 ? (
                  <Empty text="Not in a home cell or Bible study group." />
                ) : (
                  <ul className="divide-y">
                    {member.group_memberships!.map((g) => (
                      <li key={g.id} className="flex items-center justify-between py-2">
                        <div>
                          <p className="text-sm font-medium">{g.group?.name}</p>
                          {g.group?.meeting_day && (
                            <p className="text-xs text-muted-foreground capitalize">
                              Meets {g.group.meeting_day}
                            </p>
                          )}
                        </div>
                        <Badge
                          variant={g.role?.is_leadership_role ? "default" : "secondary"}
                        >
                          {g.role?.display_name ?? "Member"}
                        </Badge>
                      </li>
                    ))}
                  </ul>
                )}
              </CardContent>
            </Card>
          </TabsContent>
        </Tabs>
      </div>

      <AlertDialog open={confirmArchive} onOpenChange={setConfirmArchive}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>
              {member.is_active ? "Archive this member?" : "Reactivate this member?"}
            </AlertDialogTitle>
            <AlertDialogDescription>
              {member.is_active
                ? "They will be hidden from the directory, but nothing is deleted — their ministry service, group participation and check-in history are all preserved."
                : "They will appear in the directory again."}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={handleArchive}>
              {member.is_active ? "Archive" : "Reactivate"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </DashboardLayout>
  );
}

function Detail({
  label,
  value,
  capitalize,
}: {
  label: string;
  value: string | null | undefined;
  capitalize?: boolean;
}) {
  return (
    <div>
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className={`text-sm font-medium mt-0.5 ${capitalize ? "capitalize" : ""}`}>
        {value || "—"}
      </p>
    </div>
  );
}

function Empty({ text }: { text: string }) {
  return <p className="text-sm text-muted-foreground py-4 text-center">{text}</p>;
}
