/**
 * Attendance, laid out as a report a leader can read at a glance.
 *
 * Three layers, each answering the next question down:
 *
 *   the headline numbers   how many, how many usually, how did last Sunday go
 *   the trend              children per Sunday across the range
 *   the detail             each Sunday's classrooms, or each classroom across
 *                          the range, which is also the chart's table view
 *
 * Everything is computed from the one church.kids_attendance_by_family result
 * by the pure helpers in utils/attendanceTotals and utils/attendanceFamilies,
 * so the tiles, the chart and the table always agree, and the CSV is the same
 * numbers again.
 *
 * FAMILIES. One filter at the top narrows every layer, the by-child list
 * included, to member, regular attendee or visitor families, or those with no
 * status on record. Showing all of them, the chart and the bars are split by
 * family instead, so the share of visitors is visible without filtering.
 *
 * VOLUNTEERS. The column only appears once a volunteer has been signed in to a
 * classroom somewhere in the range. Until the desk records staffing, a column
 * of zeros reads as "nobody served", which is not true; a sentence under the
 * table says so instead.
 */

import { Fragment, useMemo, useState } from "react";
import {
  Bar,
  BarChart,
  CartesianGrid,
  Cell,
  LabelList,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/shared/components/ui/card";
import { Button } from "@/shared/components/ui/button";
import { Tabs, TabsList, TabsTrigger } from "@/shared/components/ui/tabs";
import {
  Table,
  TableBody,
  TableCell,
  TableFooter,
  TableHead,
  TableHeader,
  TableRow,
} from "@/shared/components/ui/table";
import {
  AlertTriangle,
  ArrowDownRight,
  ArrowUpRight,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  Download,
  Loader2,
  Minus,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { ChildAttendanceTable } from "./ChildAttendanceTable";
import {
  datesOpen,
  formatStay,
  groupByDay,
  padDays,
  summarizeDays,
  summarizeRooms,
  type AttendanceTotals,
} from "../utils/attendanceTotals";
import {
  FAMILIES,
  FAMILY_BY_KEY,
  countFamilies,
  countFamilyRows,
  mergeFamilies,
  noFamilies,
  type FamilyAttendanceRow,
  type FamilyCounts,
  type FamilyFilter,
  type MergedAttendanceRow,
} from "../utils/attendanceFamilies";

interface Props {
  organizationId: string | undefined;
  from: string;
  to: string;
  rows: FamilyAttendanceRow[] | undefined;
  isLoading: boolean;
  /** Showing the previous range while the new one loads. */
  isStale: boolean;
  /** Given exactly the rows on screen, so the spreadsheet and the report agree. */
  onExport: (rows: MergedAttendanceRow[], family: FamilyFilter) => void;
}

/** A report date is a calendar date, not an instant: read it as local midnight. */
function asDate(iso: string): Date {
  return new Date(`${iso}T00:00:00`);
}

const fmt = {
  short: (iso: string) =>
    asDate(iso).toLocaleDateString("en-US", { month: "short", day: "numeric" }),
  medium: (iso: string) =>
    asDate(iso).toLocaleDateString("en-US", {
      weekday: "short",
      month: "short",
      day: "numeric",
      year: "numeric",
    }),
  long: (iso: string) =>
    asDate(iso).toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric" }),
};

const number = (n: number) => n.toLocaleString("en-US");

/** A zero is real data, and quiet. */
function Count({ value, tone }: { value: number; tone?: "warn" | "bad" }) {
  if (value === 0) return <span className="text-muted-foreground/60">0</span>;
  if (!tone) return <>{number(value)}</>;
  return (
    <span
      className={cn(
        "inline-flex min-w-[1.75rem] justify-center rounded-full px-2 py-0.5 text-xs font-semibold",
        tone === "warn"
          ? "bg-amber-100 text-amber-900 dark:bg-amber-950 dark:text-amber-200"
          : "bg-rose-100 text-rose-900 dark:bg-rose-950 dark:text-rose-200",
      )}
    >
      {number(value)}
    </span>
  );
}

/** "Members 20 · Visitors 3", for a bar's tooltip. */
function familyBreakdown(families: FamilyCounts): string {
  return FAMILIES.filter((f) => families[f.key] > 0)
    .map((f) => `${f.label} ${families[f.key]}`)
    .join(" · ");
}

/**
 * A number with a thin bar beside it, so a column of counts reads as a shape.
 * Showing every family, the bar is split by family in the chart's colours;
 * filtered to one, it is that family's colour.
 */
function BarCount({
  value,
  max,
  strong,
  families,
  family = "all",
}: {
  value: number;
  max: number;
  strong?: boolean;
  families?: FamilyCounts;
  family?: FamilyFilter;
}) {
  const pct = max > 0 && value > 0 ? Math.max(2, Math.round((value / max) * 100)) : 0;
  const split = family === "all" && families;
  return (
    <div className="flex items-center justify-end gap-3">
      <div
        className="hidden h-1.5 w-20 overflow-hidden rounded-full bg-muted sm:block"
        title={families ? familyBreakdown(families) : undefined}
      >
        {split ? (
          <div className="flex h-full overflow-hidden rounded-full" style={{ width: `${pct}%` }}>
            {FAMILIES.map((f) =>
              families[f.key] > 0 ? (
                <div key={f.key} className={cn("h-full", f.bg)} style={{ flexGrow: families[f.key] }} />
              ) : null,
            )}
          </div>
        ) : (
          <div
            className={cn(
              "h-full rounded-full",
              family === "all" ? "bg-primary/70" : FAMILY_BY_KEY[family].bg,
            )}
            style={{ width: `${pct}%` }}
          />
        )}
      </div>
      <span className={cn("w-10 text-right tabular-nums", strong && "font-semibold")}>
        {number(value)}
      </span>
    </div>
  );
}

function StatTile({
  label,
  value,
  detail,
  status,
}: {
  label: string;
  value: string;
  detail: React.ReactNode;
  status?: "ok" | "warn";
}) {
  return (
    <Card className={cn(status === "warn" && "border-amber-300 dark:border-amber-800")}>
      <CardContent className="p-4">
        <p className="text-sm text-muted-foreground">{label}</p>
        <p className="mt-1 text-3xl font-semibold tracking-tight">{value}</p>
        <div className="mt-1 text-xs text-muted-foreground">{detail}</div>
      </CardContent>
    </Card>
  );
}

function Change({ now, before, beforeDate }: { now: number; before: number | null; beforeDate?: string }) {
  if (before === null) return <span>The first date in this range</span>;
  const diff = now - before;
  const Icon = diff > 0 ? ArrowUpRight : diff < 0 ? ArrowDownRight : Minus;
  return (
    <span className="inline-flex items-center gap-1">
      <span
        className={cn(
          "inline-flex items-center gap-0.5 font-medium",
          diff > 0 && "text-emerald-700 dark:text-emerald-400",
          diff < 0 && "text-rose-700 dark:text-rose-400",
        )}
      >
        <Icon className="h-3.5 w-3.5" aria-hidden />
        {diff > 0 ? `+${diff}` : diff}
      </span>
      {beforeDate ? `vs ${fmt.short(beforeDate)}` : "vs the date before"}
    </span>
  );
}

interface ChartPoint extends FamilyCounts {
  date: string;
  label: string;
  children: number;
  first_time_visitors: number;
  rooms: number;
  latest: boolean;
  peak: boolean;
}

function ChartTip({
  active,
  payload,
  split,
}: {
  active?: boolean;
  payload?: { payload: ChartPoint }[];
  split?: boolean;
}) {
  if (!active || !payload?.length) return null;
  const p = payload[0].payload;
  return (
    <div className="rounded-md border bg-popover px-3 py-2 text-popover-foreground shadow-md">
      <p className="text-sm font-semibold">{number(p.children)} children</p>
      <p className="text-xs text-muted-foreground">{fmt.medium(p.date)}</p>
      {split && p.children > 0 && (
        <ul className="mt-1.5 space-y-0.5">
          {FAMILIES.map((f) => (
            <li key={f.key} className="flex items-center gap-1.5 text-xs">
              <span className={cn("h-2 w-2 rounded-sm", f.bg)} aria-hidden />
              <span className="text-muted-foreground">{f.label}</span>
              <span className="ml-auto pl-3 tabular-nums">{p[f.key]}</span>
            </li>
          ))}
        </ul>
      )}
      <p className="mt-1 text-xs text-muted-foreground">
        {p.first_time_visitors} new · {p.rooms} {p.rooms === 1 ? "room" : "rooms"}
      </p>
    </div>
  );
}

function TotalsCells({
  totals,
  showVolunteers,
  strong,
  max,
  families,
  family,
}: {
  totals: AttendanceTotals;
  showVolunteers: boolean;
  strong?: boolean;
  max?: number;
  families?: FamilyCounts;
  family?: FamilyFilter;
}) {
  return (
    <>
      <TableCell className="text-right">
        {max !== undefined ? (
          <BarCount
            value={totals.children}
            max={max}
            strong={strong}
            families={families}
            family={family}
          />
        ) : (
          <span className={cn("tabular-nums", strong && "font-semibold")}>{number(totals.children)}</span>
        )}
      </TableCell>
      <TableCell className="text-right tabular-nums">
        <Count value={totals.first_time_visitors} />
      </TableCell>
      {showVolunteers && (
        <TableCell className="text-right tabular-nums">
          <Count value={totals.volunteers} />
        </TableCell>
      )}
      <TableCell className="text-right tabular-nums whitespace-nowrap">
        {formatStay(totals.avg_minutes)}
      </TableCell>
      <TableCell className="text-right tabular-nums">
        <Count value={totals.overrides} tone="warn" />
      </TableCell>
      <TableCell className="text-right tabular-nums">
        <Count value={totals.not_checked_out} tone="bad" />
      </TableCell>
    </>
  );
}

/** Sunday is day 0. A service date is a calendar date, read as local. */
const isSunday = (iso: string) => asDate(iso).getDay() === 0;

/**
 * Twelve hours. A longer "stay" is a check-in nobody closed until days later,
 * not time a child spent in a room, and one of them turns a three-hour
 * average into ten. Left out of the averages and said so under the table.
 */
const LONGEST_REAL_STAY = 12 * 60;

export function AttendanceReport({ organizationId, from, to, rows, isLoading, isStale, onExport }: Props) {
  /*
   * SUNDAYS ONLY, BY DEFAULT. Sessions are opened midweek too, for a
   * programme, a rehearsal or simply to try the desk, and one of those with
   * a single child would otherwise be "the latest Sunday" and halve the
   * average. The switch brings them back.
   */
  const [allDates, setAllDates] = useState(false);
  const [family, setFamily] = useState<FamilyFilter>("all");
  const otherDates = useMemo(
    () => new Set((rows ?? []).map((r) => r.session_date).filter((d) => !isSunday(d))).size,
    [rows],
  );
  const dated = useMemo(
    () => (allDates ? rows ?? [] : (rows ?? []).filter((r) => isSunday(r.session_date))),
    [rows, allDates],
  );
  const staleStays = useMemo(
    () => dated.some((r) => r.avg_minutes !== null && r.avg_minutes > LONGEST_REAL_STAY),
    [dated],
  );
  // Check-ins from each kind of family, for the filter's counts and the legend.
  const familyCounts = useMemo(() => countFamilyRows(dated), [dated]);
  const allCheckIns = FAMILIES.reduce((n, f) => n + familyCounts[f.key], 0);
  const merged = useMemo(() => {
    const cleaned = dated.map((r) =>
      r.avg_minutes !== null && r.avg_minutes > LONGEST_REAL_STAY ? { ...r, avg_minutes: null } : r,
    );
    const everyone = mergeFamilies(cleaned, "all");
    return {
      shown: family === "all" ? everyone : mergeFamilies(cleaned, family),
      // From every family, so a filter keeps the Sundays and the rooms' open
      // dates of the whole report.
      dates: groupByDay(everyone).map((d) => d.session_date),
      open: datesOpen(everyone),
    };
  }, [dated, family]);
  const shown = merged.shown;
  const days = useMemo(() => padDays(groupByDay(shown), merged.dates), [shown, merged.dates]);
  const summary = useMemo(() => summarizeDays(days), [days]);
  const rooms = useMemo(() => summarizeRooms(shown, merged.open), [shown, merged.open]);
  const roomFamilies = useMemo(() => {
    const byRoom = new Map<string, MergedAttendanceRow[]>();
    for (const row of shown) byRoom.set(row.room_name, [...(byRoom.get(row.room_name) ?? []), row]);
    return new Map([...byRoom].map(([room, roomRows]) => [room, countFamilies(roomRows)]));
  }, [shown]);
  const per = allDates ? "date" : "Sunday";
  const perPlural = allDates ? "dates" : "Sundays";
  const [view, setView] = useState<"days" | "rooms" | "children">("days");
  // The newest date starts open; the rest are one click away.
  const [open, setOpen] = useState<Set<string> | null>(null);
  const expanded = open ?? new Set(days.slice(0, 1).map((d) => d.session_date));

  // Volunteers staff a room, not a family: beside one family's children the
  // column would read as though they had been looking after only them.
  const showVolunteers = summary.volunteersRecorded && family === "all";
  const split = family === "all";
  const chart: ChartPoint[] = useMemo(
    () =>
      [...days].reverse().map((d, i, all) => ({
        date: d.session_date,
        label: fmt.short(d.session_date),
        children: d.totals.children,
        first_time_visitors: d.totals.first_time_visitors,
        rooms: d.rows.length,
        latest: i === all.length - 1,
        peak: summary.peak?.session_date === d.session_date,
        ...(d.rows.length ? countFamilies(d.rows) : noFamilies()),
      })),
    [days, summary.peak],
  );
  const busiestRoomOnAnyDay = Math.max(0, ...days.flatMap((d) => d.rows.map((r) => r.children)));
  const busiestDay = Math.max(0, ...days.map((d) => d.totals.children));
  const busiestRoomAverage = Math.max(0, ...rooms.map((r) => r.average));

  function toggle(date: string) {
    const next = new Set(expanded);
    if (next.has(date)) next.delete(date);
    else next.add(date);
    setOpen(next);
  }
  const allOpen = days.length > 0 && days.every((d) => expanded.has(d.session_date));

  if (isLoading) {
    return (
      <div className="flex justify-center py-16">
        <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
      </div>
    );
  }

  const pctOf = (n: number, of: number) => (of > 0 ? Math.round((n / of) * 100) : 0);
  const scope = (
    <div className="space-y-2">
      <div className="flex flex-col gap-2 lg:flex-row lg:items-center lg:justify-between">
        {/* One filter for every layer below, the by-child list included. The
            counts are check-ins, the same number the first tile shows. */}
        <div className="flex flex-wrap items-center gap-1.5" role="group" aria-label="Family">
          <span className="mr-1 text-xs font-medium text-muted-foreground">Family</span>
          <Button
            type="button"
            size="sm"
            variant={family === "all" ? "secondary" : "ghost"}
            aria-pressed={family === "all"}
            onClick={() => setFamily("all")}
          >
            All
            <span className="ml-1.5 tabular-nums text-muted-foreground">{number(allCheckIns)}</span>
          </Button>
          {FAMILIES.map((f) => (
            <Button
              key={f.key}
              type="button"
              size="sm"
              variant={family === f.key ? "secondary" : "ghost"}
              aria-pressed={family === f.key}
              title={f.hint}
              disabled={familyCounts[f.key] === 0 && family !== f.key}
              onClick={() => setFamily(f.key)}
            >
              <span className={cn("mr-1.5 h-2 w-2 rounded-full", f.bg)} aria-hidden />
              {f.label}
              <span className="ml-1.5 tabular-nums text-muted-foreground">
                {number(familyCounts[f.key])}
              </span>
            </Button>
          ))}
        </div>
        {otherDates > 0 && (
          <Tabs value={allDates ? "all" : "sundays"} onValueChange={(v) => setAllDates(v === "all")}>
            <TabsList>
              <TabsTrigger value="sundays">Sundays</TabsTrigger>
              <TabsTrigger value="all">All dates</TabsTrigger>
            </TabsList>
          </Tabs>
        )}
      </div>
      <p className="text-sm text-muted-foreground">
        {summary.days} {summary.days === 1 ? per : perPlural}
        {!allDates && otherDates > 0 &&
          ` · ${otherDates} midweek or test ${otherDates === 1 ? "date" : "dates"} not counted`}
        {" · "}
        {family === "all" ? "Every family" : FAMILY_BY_KEY[family].only}, by membership status as
        recorded today
      </p>
      {family === "visitor" && (
        <p className="text-xs text-muted-foreground">
          The check-in desk registers every new family as Visitors. A family stays here until a
          parent&rsquo;s status is changed in Members.
        </p>
      )}
      {family === "not_recorded" && (
        <p className="text-xs text-muted-foreground">
          Nobody in these families has a membership status in the directory. Giving a parent one
          in Members moves their children to the right group.
        </p>
      )}
    </div>
  );

  if (days.length === 0 || (family !== "all" && summary.totals.children === 0)) {
    return (
      <div className="space-y-3">
        {scope}
        <Card>
          <CardContent className="py-16 text-center text-sm text-muted-foreground">
            {days.length === 0
              ? "No check-ins in this period. Choose a wider range above."
              : `No children from ${FAMILY_BY_KEY[family as Exclude<FamilyFilter, "all">].only.toLowerCase()} in this period.`}
          </CardContent>
        </Card>
      </div>
    );
  }

  const exceptions = summary.totals.overrides + summary.totals.not_checked_out;

  return (
    <div className={cn("space-y-4 transition-opacity", isStale && "opacity-60")}>
      {scope}
      {/* The headline numbers ------------------------------------------- */}
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-5">
        <StatTile
          label={family === "all" ? "Check-ins" : `Check-ins · ${FAMILY_BY_KEY[family].label}`}
          value={number(summary.totals.children)}
          detail={
            family === "all"
              ? `Across ${summary.days} ${summary.days === 1 ? per : perPlural}`
              : `${pctOf(summary.totals.children, allCheckIns)}% of all ${number(allCheckIns)} check-ins`
          }
        />
        <StatTile
          label={`Average per ${per}`}
          value={number(summary.perDay ?? 0)}
          detail={
            summary.peak ? `Highest ${number(summary.peak.children)} on ${fmt.short(summary.peak.session_date)}` : ""
          }
        />
        <StatTile
          label={summary.latest ? `Latest · ${fmt.short(summary.latest.session_date)}` : "Latest"}
          value={number(summary.latest?.children ?? 0)}
          detail={
            summary.latest ? (
              <Change
                now={summary.latest.children}
                before={summary.latest.previous}
                beforeDate={days[1]?.session_date}
              />
            ) : (
              ""
            )
          }
        />
        {/* "New", not "first-time visitors": a member's toddler at their
            first Sunday is new too, and the Visitors filter means something
            else. */}
        <StatTile
          label="New children"
          value={number(summary.totals.first_time_visitors)}
          detail={
            summary.totals.children > 0
              ? `First check-in ever · ${pctOf(summary.totals.first_time_visitors, summary.totals.children)}% of check-ins`
              : ""
          }
        />
        <StatTile
          label={exceptions > 0 ? "Exceptions" : "Average time in a room"}
          value={exceptions > 0 ? number(exceptions) : formatStay(summary.totals.avg_minutes)}
          status={exceptions > 0 ? "warn" : undefined}
          detail={
            exceptions > 0 ? (
              <span className="inline-flex items-center gap-1 text-amber-800 dark:text-amber-300">
                <AlertTriangle className="h-3.5 w-3.5" aria-hidden />
                {summary.totals.overrides} overrides · {summary.totals.not_checked_out} not collected
              </span>
            ) : (
              <span className="inline-flex items-center gap-1">
                <CheckCircle2 className="h-3.5 w-3.5 text-emerald-600" aria-hidden />
                No overrides or uncollected children
              </span>
            )
          }
        />
      </div>

      {/* The trend -------------------------------------------------------- */}
      <Card>
        <CardHeader className="pb-2">
          <CardTitle className="text-base">Children per {per}</CardTitle>
          <CardDescription>
            {split
              ? "Every classroom together, split by family. Hover a column for its details."
              : `${FAMILY_BY_KEY[family].only}, every classroom together. The latest date is in full colour; hover a column for its details.`}
          </CardDescription>
          {/* The legend carries each family's share of the range, so the
              question "how many of our children are visitors" is answered
              without touching the filter. */}
          {split && (
            <div className="flex flex-wrap gap-x-4 gap-y-1 pt-2">
              {FAMILIES.map((f) => (
                <span key={f.key} className="inline-flex items-center gap-1.5 text-xs">
                  <span className={cn("h-2.5 w-2.5 rounded-sm", f.bg)} aria-hidden />
                  <span className="text-muted-foreground">{f.label}</span>
                  <span className="font-medium tabular-nums">
                    {pctOf(familyCounts[f.key], allCheckIns)}%
                  </span>
                </span>
              ))}
            </div>
          )}
        </CardHeader>
        <CardContent>
          <div className="h-64 w-full">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={chart} margin={{ top: 22, right: 8, bottom: 0, left: 0 }}>
                <CartesianGrid vertical={false} className="stroke-border" />
                <XAxis
                  dataKey="label"
                  tickLine={false}
                  axisLine={false}
                  tick={{ fontSize: 12, className: "fill-muted-foreground" }}
                  interval="preserveStartEnd"
                  minTickGap={12}
                />
                <YAxis
                  width={36}
                  allowDecimals={false}
                  tickLine={false}
                  axisLine={false}
                  tick={{ fontSize: 12, className: "fill-muted-foreground" }}
                />
                <Tooltip
                  cursor={{ className: "fill-muted", opacity: 0.6 }}
                  content={<ChartTip split={split} />}
                />
                {/* No grow-in animation: a report is read, not watched, and an
                    animation that never runs (a background tab) leaves no bars.
                    Every family: one stack per date, members at the bottom.
                    One family: a single bar in its colour. The total goes on
                    top of the last segment either way. */}
                {(split ? FAMILIES : [FAMILY_BY_KEY[family]]).map((f, i, all) => {
                  const top = i === all.length - 1;
                  return (
                    <Bar
                      key={f.key}
                      dataKey={split ? f.key : "children"}
                      stackId="families"
                      maxBarSize={24}
                      radius={top ? [4, 4, 0, 0] : 0}
                      isAnimationActive={false}
                    >
                      {/* Split, every date in full colour: a faded amber on a
                          faded blue is unreadable, and the split is the point.
                          The latest is still labelled. */}
                      {chart.map((p) => (
                        <Cell key={p.date} className={split || p.latest ? f.fill : f.faded} />
                      ))}
                      {/* Labelled sparingly: the latest and the highest. */}
                      {top && (
                        <LabelList
                          dataKey="children"
                          content={({ x, y, width, index }) => {
                            const p = typeof index === "number" ? chart[index] : undefined;
                            if (!p || (!p.latest && !p.peak)) return null;
                            return (
                              <text
                                x={Number(x) + Number(width) / 2}
                                y={Number(y) - 6}
                                textAnchor="middle"
                                fontSize={12}
                                fontWeight={600}
                                className="fill-foreground"
                              >
                                {p.children}
                              </text>
                            );
                          }}
                        />
                      )}
                    </Bar>
                  );
                })}
              </BarChart>
            </ResponsiveContainer>
          </div>
        </CardContent>
      </Card>

      {/* The detail -------------------------------------------------------- */}
      <Card>
        <CardHeader className="gap-3 space-y-0 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <CardTitle className="text-base">Detail</CardTitle>
            <CardDescription>
              {view === "days"
                ? "Each date, and its classrooms underneath."
                : view === "rooms"
                  ? "Each classroom across the whole range, busiest first."
                  : `Each child across these ${perPlural}, newest first.`}
            </CardDescription>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <Tabs value={view} onValueChange={(v) => setView(v as "days" | "rooms" | "children")}>
              <TabsList>
                <TabsTrigger value="days">By {per}</TabsTrigger>
                <TabsTrigger value="rooms">By room</TabsTrigger>
                <TabsTrigger value="children">By child</TabsTrigger>
              </TabsList>
            </Tabs>
            {view === "days" && (
              <Button
                variant="ghost"
                size="sm"
                onClick={() =>
                  setOpen(allOpen ? new Set() : new Set(days.map((d) => d.session_date)))
                }
              >
                {allOpen ? "Collapse all" : "Expand all"}
              </Button>
            )}
            {/* The by-child view has its own export, in its own shape. */}
            {view !== "children" && (
              <Button variant="outline" size="sm" onClick={() => onExport(shown, family)}>
                <Download className="h-4 w-4" />
                CSV
              </Button>
            )}
          </div>
        </CardHeader>
        <CardContent>
          {view === "children" ? (
            <ChildAttendanceTable
              organizationId={organizationId}
              from={from}
              to={to}
              dates={days.map((d) => d.session_date)}
              family={family}
            />
          ) : (
          <div className="overflow-x-auto rounded-md border">
            {view === "days" ? (
              <Table>
                <TableHeader className="bg-muted/50">
                  <TableRow>
                    <TableHead className="min-w-[16rem]">Date / classroom</TableHead>
                    <TableHead className="text-right">Children</TableHead>
                    <TableHead className="text-right">New</TableHead>
                    {showVolunteers && <TableHead className="text-right">Volunteers</TableHead>}
                    <TableHead className="text-right">Avg stay</TableHead>
                    <TableHead className="text-right">Overrides</TableHead>
                    <TableHead className="text-right">Not collected</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {days.map((day) => {
                    const isOpen = expanded.has(day.session_date);
                    const services = [...new Set(day.rows.map((r) => r.service_label).filter(Boolean))];
                    return (
                      <Fragment key={day.session_date}>
                        <TableRow
                          className="cursor-pointer bg-muted/20 hover:bg-muted/40"
                          onClick={() => toggle(day.session_date)}
                        >
                          <TableCell>
                            <button
                              type="button"
                              className="flex items-start gap-2 text-left"
                              aria-expanded={isOpen}
                              onClick={(e) => {
                                e.stopPropagation();
                                toggle(day.session_date);
                              }}
                            >
                              {isOpen ? (
                                <ChevronDown className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />
                              ) : (
                                <ChevronRight className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />
                              )}
                              <span>
                                <span className="font-semibold">{fmt.long(day.session_date)}</span>
                                <span className="block text-xs text-muted-foreground">
                                  {day.rows.length === 0
                                    ? `No children from ${FAMILY_BY_KEY[family === "all" ? "not_recorded" : family].only.toLowerCase()}`
                                    : `${services.join(" · ") || "Service"} · ${day.rows.length} ${
                                        day.rows.length === 1 ? "classroom" : "classrooms"
                                      }`}
                                  {day.serviceCount > 1 &&
                                    " · a child at more than one service counts once per service"}
                                </span>
                              </span>
                            </button>
                          </TableCell>
                          <TotalsCells
                            totals={day.totals}
                            showVolunteers={showVolunteers}
                            strong
                            max={busiestDay}
                            families={countFamilies(day.rows)}
                            family={family}
                          />
                        </TableRow>
                        {isOpen &&
                          day.rows.map((row, i) => (
                            <TableRow key={`${day.session_date}-${row.room_name}-${i}`}>
                              <TableCell className="pl-10">
                                <span>{row.room_name}</span>
                                {row.age_band_name && (
                                  <span className="ml-2 rounded bg-muted px-1.5 py-0.5 text-xs text-muted-foreground">
                                    {row.age_band_name}
                                  </span>
                                )}
                              </TableCell>
                              <TotalsCells
                                totals={{
                                  children: row.children,
                                  first_time_visitors: row.first_time_visitors,
                                  volunteers: row.volunteers,
                                  overrides: row.overrides,
                                  not_checked_out: row.not_checked_out,
                                  avg_minutes: row.avg_minutes,
                                }}
                                showVolunteers={showVolunteers}
                                max={busiestRoomOnAnyDay}
                                families={row.families}
                                family={family}
                              />
                            </TableRow>
                          ))}
                      </Fragment>
                    );
                  })}
                </TableBody>
                {days.length > 1 && (
                  <TableFooter>
                    <TableRow className="hover:bg-transparent">
                      <TableCell className="font-semibold">
                        All {days.length} {perPlural}
                      </TableCell>
                      <TotalsCells totals={summary.totals} showVolunteers={showVolunteers} strong />
                    </TableRow>
                  </TableFooter>
                )}
              </Table>
            ) : (
              <Table>
                <TableHeader className="bg-muted/50">
                  <TableRow>
                    <TableHead className="min-w-[14rem]">Classroom</TableHead>
                    <TableHead className="text-right">Average</TableHead>
                    <TableHead className="text-right">Highest</TableHead>
                    <TableHead className="text-right">Total</TableHead>
                    <TableHead className="text-right">New</TableHead>
                    <TableHead className="text-right">Avg stay</TableHead>
                    <TableHead className="text-right">Dates open</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {rooms.map((room) => (
                    <TableRow key={room.room_name}>
                      <TableCell>
                        <span className="font-medium">{room.room_name}</span>
                        {room.age_band_name && (
                          <span className="ml-2 rounded bg-muted px-1.5 py-0.5 text-xs text-muted-foreground">
                            {room.age_band_name}
                          </span>
                        )}
                      </TableCell>
                      <TableCell className="text-right">
                        <BarCount
                          value={room.average}
                          max={busiestRoomAverage}
                          strong
                          families={roomFamilies.get(room.room_name)}
                          family={family}
                        />
                      </TableCell>
                      <TableCell className="text-right tabular-nums">{number(room.peak)}</TableCell>
                      <TableCell className="text-right tabular-nums">{number(room.total)}</TableCell>
                      <TableCell className="text-right tabular-nums">
                        <Count value={room.first_time_visitors} />
                      </TableCell>
                      <TableCell className="text-right tabular-nums whitespace-nowrap">
                        {formatStay(room.avg_minutes)}
                      </TableCell>
                      <TableCell className="text-right tabular-nums">{room.sessions}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </div>
          )}
          {view !== "children" && !summary.volunteersRecorded && (
            <p className="mt-3 text-xs text-muted-foreground">
              Volunteers are not being signed in to classrooms yet, so staffing is not shown. The
              column appears here once they are.
            </p>
          )}
          {view !== "children" && staleStays && (
            <p className="mt-2 text-xs text-muted-foreground">
              Stays over twelve hours are left out of the averages and shown as —. They are
              check-ins closed off days later, not time in a room.
            </p>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
