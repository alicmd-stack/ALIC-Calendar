/**
 * Attendance by family: members, regular attendees, visitors, and families
 * with no status on record.
 *
 * church.kids_attendance_by_family returns the room report split once more by
 * family, so a room on a Sunday may be up to four rows. The screen filters to
 * the families it is showing and adds each room back into one row here, with
 * the split kept alongside so the bars and the chart can show it.
 *
 * Adding the parts back up is exact for everything but two columns:
 *
 *   volunteers    belong to the room, not to a family; the server repeats them
 *                 on each of a room's rows, so they are taken once, not summed
 *   avg_minutes   an average, weighted by children as sumAttendance does
 *
 * A family's status is as recorded in the directory today, not on the day;
 * see 20260322410000_attendance_by_family.sql for the rule.
 */

import type { AttendanceRow } from "../services/kidsLeaderService";

export type FamilyStatus = "member" | "regular_attendee" | "visitor" | "not_recorded";
export type FamilyFilter = "all" | FamilyStatus;

export type FamilyCounts = Record<FamilyStatus, number>;

/** The membership ladder, in the order every legend, chip and column uses. */
export const FAMILIES: {
  key: FamilyStatus;
  label: string;
  /** One child's family, beside their name: "Visitor". */
  one: string;
  /** What a filtered report is showing: "Visitor families". */
  only: string;
  /** Swatches, bars and chart segments. Fill for SVG, bg for HTML. */
  fill: string;
  faded: string;
  bg: string;
  hint: string;
}[] = [
  {
    key: "member",
    label: "Members",
    one: "Member",
    only: "Member families",
    fill: "fill-primary",
    faded: "fill-primary/35",
    bg: "bg-primary",
    hint: "A parent, or the child, is a Member",
  },
  {
    key: "regular_attendee",
    label: "Regular attendees",
    one: "Regular attendee",
    only: "Regular attendee families",
    fill: "fill-teal-500",
    faded: "fill-teal-500/40",
    bg: "bg-teal-500",
    hint: "No Member in the family, but a Regular Attendee",
  },
  {
    key: "visitor",
    label: "Visitors",
    one: "Visitor",
    only: "Visitor families",
    fill: "fill-amber-500",
    faded: "fill-amber-500/40",
    bg: "bg-amber-500",
    hint: "Recorded as Visitors. The desk registers every new family as one",
  },
  {
    key: "not_recorded",
    label: "Not recorded",
    one: "No status",
    only: "Families with no status",
    fill: "fill-slate-400 dark:fill-slate-500",
    faded: "fill-slate-400/40 dark:fill-slate-500/40",
    bg: "bg-slate-400 dark:bg-slate-500",
    hint: "Nobody in the family has a membership status in the directory",
  },
];

export const FAMILY_BY_KEY = Object.fromEntries(FAMILIES.map((f) => [f.key, f])) as Record<
  FamilyStatus,
  (typeof FAMILIES)[number]
>;

const STATUSES = new Set<string>(FAMILIES.map((f) => f.key));

/**
 * A status this build does not know, or none at all (a server from before the
 * migration), is "not recorded" rather than dropped: a report that silently
 * loses children is worse than one that files them under the wrong heading.
 */
export function asFamily(status: string | null | undefined): FamilyStatus {
  return status && STATUSES.has(status) ? (status as FamilyStatus) : "not_recorded";
}

export const noFamilies = (): FamilyCounts => ({
  member: 0,
  regular_attendee: 0,
  visitor: 0,
  not_recorded: 0,
});

/** One row of church.kids_attendance_by_family. */
export interface FamilyAttendanceRow extends AttendanceRow {
  family_status: string | null;
}

/** A room on a date, its families added back together. */
export interface MergedAttendanceRow extends AttendanceRow {
  /** Children from each kind of family, among the families shown. */
  families: FamilyCounts;
}

/**
 * Keep the families shown and add each room on each date back into one row,
 * in the order the server sent them (newest date first, rooms by name).
 */
export function mergeFamilies(
  rows: readonly FamilyAttendanceRow[],
  filter: FamilyFilter,
): MergedAttendanceRow[] {
  const merged = new Map<string, MergedAttendanceRow & { minuteTotal: number; minuteWeight: number }>();
  for (const row of rows) {
    const family = asFamily(row.family_status);
    if (filter !== "all" && family !== filter) continue;
    const key = `${row.session_date}\u0000${row.service_label ?? ""}\u0000${row.room_name}`;
    let into = merged.get(key);
    if (!into) {
      into = {
        session_date: row.session_date,
        service_label: row.service_label,
        room_name: row.room_name,
        age_band_name: row.age_band_name,
        children: 0,
        first_time_visitors: 0,
        volunteers: 0,
        overrides: 0,
        not_checked_out: 0,
        avg_minutes: null,
        families: noFamilies(),
        minuteTotal: 0,
        minuteWeight: 0,
      };
      merged.set(key, into);
    }
    into.children += row.children;
    into.first_time_visitors += row.first_time_visitors;
    into.volunteers = Math.max(into.volunteers, row.volunteers);
    into.overrides += row.overrides;
    into.not_checked_out += row.not_checked_out;
    into.families[family] += row.children;
    into.age_band_name ??= row.age_band_name;
    if (row.avg_minutes !== null && row.children > 0) {
      into.minuteTotal += row.avg_minutes * row.children;
      into.minuteWeight += row.children;
    }
  }
  return [...merged.values()].map(({ minuteTotal, minuteWeight, ...row }) => ({
    ...row,
    avg_minutes: minuteWeight > 0 ? Math.round(minuteTotal / minuteWeight) : null,
  }));
}

/** Check-ins from each kind of family across these rows. */
export function countFamilies(rows: readonly { families: FamilyCounts }[]): FamilyCounts {
  const total = noFamilies();
  for (const row of rows) {
    for (const f of FAMILIES) total[f.key] += row.families[f.key];
  }
  return total;
}

/** Check-ins from each kind of family, straight off the server's rows. */
export function countFamilyRows(rows: readonly FamilyAttendanceRow[]): FamilyCounts {
  const total = noFamilies();
  for (const row of rows) total[asFamily(row.family_status)] += row.children;
  return total;
}
