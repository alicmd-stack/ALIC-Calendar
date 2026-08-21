/**
 * Members Dashboard — the church directory.
 *
 * Replaces the "Coming Soon" placeholder. Layout follows BudgetDashboard:
 * DashboardLayout wrapper, icon-chip header, toolbar row, KPI grid, tabs.
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
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/shared/components/ui/tabs";
import { Button } from "@/shared/components/ui/button";
import { Input } from "@/shared/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/shared/components/ui/select";
import { Badge } from "@/shared/components/ui/badge";
import {
  UsersRound,
  Plus,
  Search,
  Baby,
  Home,
  HandHeart,
  Cake,
  Loader2,
  FileSpreadsheet,
} from "lucide-react";
import { useAuth } from "@/shared/contexts/AuthContext";
import { useOrganization } from "@/shared/contexts/OrganizationContext";
import { useCapabilities } from "@/shared/hooks/useCapabilities";
import { MyInformation } from "../components/MyInformation";
import { useMembers, useMemberStats, useBirthdays } from "../hooks/useMembers";
import { useServingTotals } from "../hooks/useServing";
import { MemberTable } from "../components/MemberTable";
import { ProfileBackfillCard } from "../components/ProfileBackfillCard";
import { ModuleGrantsPanel } from "../components/ModuleGrantsPanel";
import { MEMBER_PAGE_SIZE, MONTH_NAMES, type MemberFilters } from "../types";
import { displayName } from "../utils/normalize";
import { formatBirthday } from "../utils/age";

const ALL = "__all__";

export default function MembersDashboard() {
  const navigate = useNavigate();
  const { user, isAdmin } = useAuth();
  const { currentOrganization } = useOrganization();
  const { can } = useCapabilities();
  const orgId = currentOrganization?.id;

  // Same split as BudgetDashboard: one route, two very different views.
  // An admin (or someone explicitly granted members.read) gets the whole
  // directory; everyone else gets only their own record. RLS enforces the
  // same boundary server-side, so this is presentation, not protection.
  const hasFullAccess = isAdmin || can("members.read");

  const [search, setSearch] = useState("");
  const [scope, setScope] = useState<string>(ALL);
  const [page, setPage] = useState(0);
  const [birthdayMonth, setBirthdayMonth] = useState(new Date().getMonth() + 1);

  const filters = useMemo<MemberFilters>(() => {
    const f: MemberFilters = {};
    if (search.trim()) f.search = search.trim();
    if (scope === "children") f.is_child = true;
    if (scope === "adults") f.is_child = false;
    return f;
  }, [search, scope]);

  const membersQuery = useMembers(orgId, filters, page);
  const statsQuery = useMemberStats(orgId);
  const servingQuery = useServingTotals(orgId);
  const birthdaysQuery = useBirthdays(orgId, birthdayMonth);

  const stats = statsQuery.data;
  const serving = servingQuery.data;
  const canWrite = can("members.write");

  const resetPageThen = (fn: () => void) => {
    setPage(0);
    fn();
  };

  return (
    <DashboardLayout>
      <div className="space-y-4 sm:space-y-6">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div className="flex items-start gap-3">
            <div className="p-2 rounded-xl bg-primary/10">
              <UsersRound className="h-6 w-6 text-primary" />
            </div>
            <div>
              <h1 className="text-2xl sm:text-3xl font-bold">
                {hasFullAccess ? "Church Members" : "My Information"}
              </h1>
              <p className="text-sm text-muted-foreground mt-1">
                {hasFullAccess
                  ? (currentOrganization?.name ?? "Directory")
                  : "Your record in the church directory"}
              </p>
            </div>
          </div>
          {hasFullAccess && canWrite && (
            <div className="flex gap-2">
              <Button variant="outline" onClick={() => navigate("/members/import")}>
                <FileSpreadsheet className="h-4 w-4 mr-1" />
                Import
              </Button>
              <Button onClick={() => navigate("/members/new")}>
                <Plus className="h-4 w-4 mr-1" />
                Add member
              </Button>
            </div>
          )}
        </div>

        {!hasFullAccess ? (
          <MyInformation userId={user?.id} />
        ) : (
        <>
        {/* An empty directory is not an empty church — it means the people who
            already sign in have no member record yet. Offered first, because
            nothing else on this page can do anything until it is run. */}
        {/* Without a grant, only organization admins can reach the directory
            or the check-in station at all — so this sits beside the backfill,
            which is the other half of "the module has no users yet". */}
        <ModuleGrantsPanel organizationId={orgId} canGrant={isAdmin} />

        {canWrite && (
          <ProfileBackfillCard
            organizationId={orgId}
            memberCount={stats?.active ?? 0}
            onDone={() => {
              void statsQuery.refetch();
            }}
          />
        )}

        <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
          <StatCard
            icon={<UsersRound className="h-4 w-4" />}
            label="Active people"
            value={stats?.active}
            loading={statsQuery.isLoading}
          />
          <StatCard
            icon={<Baby className="h-4 w-4" />}
            label="Children"
            value={stats?.children}
            loading={statsQuery.isLoading}
          />
          <StatCard
            icon={<Home className="h-4 w-4" />}
            label="Households"
            value={stats?.households}
            loading={statsQuery.isLoading}
          />
          <StatCard
            icon={<HandHeart className="h-4 w-4" />}
            label="Serving"
            value={serving?.unique_serving_members}
            loading={servingQuery.isLoading}
            /* Distinct people, not assignment rows — a person serving in two
               ministries counts once here (spec 9.3). */
            hint={
              serving
                ? `${serving.assignment_count} assignments · ${serving.members_in_multiple_ministries} in 2+`
                : undefined
            }
          />
        </div>

        <Tabs defaultValue="directory">
          <TabsList className="grid grid-cols-2 w-full sm:w-auto sm:inline-flex">
            <TabsTrigger value="directory" className="data-[state=active]:bg-primary data-[state=active]:text-primary-foreground">
              Directory
            </TabsTrigger>
            <TabsTrigger value="birthdays" className="data-[state=active]:bg-primary data-[state=active]:text-primary-foreground">
              Birthdays
            </TabsTrigger>
          </TabsList>

          <TabsContent value="directory" className="mt-4 space-y-4">
            <div className="flex flex-col sm:flex-row gap-2">
              <div className="relative flex-1">
                <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
                <Input
                  className="pl-9"
                  placeholder="Search by name, email, or phone digits…"
                  value={search}
                  onChange={(e) => resetPageThen(() => setSearch(e.target.value))}
                />
              </div>
              <Select value={scope} onValueChange={(v) => resetPageThen(() => setScope(v))}>
                <SelectTrigger className="w-full sm:w-[160px]">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value={ALL}>Everyone</SelectItem>
                  <SelectItem value="adults">Adults</SelectItem>
                  <SelectItem value="children">Children</SelectItem>
                </SelectContent>
              </Select>
            </div>

            {membersQuery.isError ? (
              <ErrorCard error={membersQuery.error} />
            ) : (
              <MemberTable
                members={membersQuery.data?.rows ?? []}
                total={membersQuery.data?.total ?? 0}
                page={page}
                pageSize={MEMBER_PAGE_SIZE}
                isLoading={membersQuery.isLoading || membersQuery.isFetching}
                onPageChange={setPage}
              />
            )}
          </TabsContent>

          <TabsContent value="birthdays" className="mt-4 space-y-4">
            <Card>
              <CardHeader className="pb-3">
                <div className="flex items-center justify-between gap-3">
                  <div>
                    <CardTitle className="text-base flex items-center gap-2">
                      <Cake className="h-4 w-4" />
                      Birthdays in {MONTH_NAMES[birthdayMonth - 1]}
                    </CardTitle>
                    <CardDescription className="text-xs mt-1">
                      Grouped by month. ALIC records the year and month of birth but not
                      the day, so a day-level list is not possible.
                    </CardDescription>
                  </div>
                  <Select
                    value={String(birthdayMonth)}
                    onValueChange={(v) => setBirthdayMonth(Number(v))}
                  >
                    <SelectTrigger className="w-[140px]">
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {MONTH_NAMES.map((m, i) => (
                        <SelectItem key={m} value={String(i + 1)}>
                          {m}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              </CardHeader>
              <CardContent>
                {birthdaysQuery.isLoading ? (
                  <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
                ) : (birthdaysQuery.data?.length ?? 0) === 0 ? (
                  <p className="text-sm text-muted-foreground py-6 text-center">
                    Nobody on file with a birthday in {MONTH_NAMES[birthdayMonth - 1]}.
                  </p>
                ) : (
                  <ul className="divide-y">
                    {birthdaysQuery.data!.map((m) => (
                      <li key={m.id} className="flex items-center justify-between py-2">
                        <span className="text-sm font-medium">{displayName(m)}</span>
                        <Badge variant="secondary">{formatBirthday(m)}</Badge>
                      </li>
                    ))}
                  </ul>
                )}
              </CardContent>
            </Card>
          </TabsContent>
        </Tabs>
        </>
        )}
      </div>

    </DashboardLayout>
  );
}

function StatCard({
  icon,
  label,
  value,
  loading,
  hint,
}: {
  icon: React.ReactNode;
  label: string;
  value: number | undefined;
  loading: boolean;
  hint?: string;
}) {
  return (
    <Card>
      <CardContent className="p-4">
        <div className="flex items-center gap-2 text-muted-foreground text-xs">
          {icon}
          {label}
        </div>
        <div className="mt-1 text-2xl font-semibold">
          {loading ? <Loader2 className="h-5 w-5 animate-spin" /> : (value ?? "—")}
        </div>
        {hint && <p className="mt-1 text-[11px] text-muted-foreground">{hint}</p>}
      </CardContent>
    </Card>
  );
}

function ErrorCard({ error }: { error: unknown }) {
  const message = error instanceof Error ? error.message : "Unknown error";
  return (
    <Card className="border-red-200 bg-red-50/40">
      <CardContent className="p-4">
        <p className="text-sm font-medium text-red-700">Could not load members</p>
        <p className="text-xs text-red-600/80 mt-1">{message}</p>
      </CardContent>
    </Card>
  );
}
