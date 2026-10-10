import { describe, it, expect } from "vitest";
import {
  asFamily,
  countFamilies,
  countFamilyRows,
  mergeFamilies,
  type FamilyAttendanceRow,
} from "./attendanceFamilies";
import { datesOpen, groupByDay, padDays, summarizeDays, summarizeRooms } from "./attendanceTotals";

function row(p: Partial<FamilyAttendanceRow> = {}): FamilyAttendanceRow {
  return {
    session_date: "2026-10-04",
    service_label: "Sunday Service",
    room_name: "Joy",
    age_band_name: "K-1",
    family_status: "member",
    children: 0,
    first_time_visitors: 0,
    volunteers: 0,
    overrides: 0,
    not_checked_out: 0,
    avg_minutes: null,
    ...p,
  };
}

// Joy on 4 October: 10 member children, 2 visitors, 3 with no status. The
// room had 3 volunteers, repeated on each of its rows by the server.
const joy = [
  row({ family_status: "member", children: 10, first_time_visitors: 1, volunteers: 3, avg_minutes: 100, overrides: 1 }),
  row({ family_status: "visitor", children: 2, first_time_visitors: 2, volunteers: 3, avg_minutes: 40, not_checked_out: 1 }),
  row({ family_status: "not_recorded", children: 3, volunteers: 3, avg_minutes: null }),
];

describe("mergeFamilies", () => {
  it("adds a room's families back into the room", () => {
    const [joyRoom] = mergeFamilies(joy, "all");
    expect(joyRoom.children).toBe(15);
    expect(joyRoom.first_time_visitors).toBe(3);
    expect(joyRoom.overrides).toBe(1);
    expect(joyRoom.not_checked_out).toBe(1);
    expect(joyRoom.families).toEqual({ member: 10, regular_attendee: 0, visitor: 2, not_recorded: 3 });
  });

  it("takes the room's volunteers once, not once per family", () => {
    expect(mergeFamilies(joy, "all")[0].volunteers).toBe(3);
  });

  it("weights the average stay by children, skipping families nobody collected", () => {
    // (10 × 100 + 2 × 40) / 12 = 90, not the mean of the means (70).
    expect(mergeFamilies(joy, "all")[0].avg_minutes).toBe(90);
  });

  it("keeps only the family filtered to", () => {
    const [visitors] = mergeFamilies(joy, "visitor");
    expect(visitors.children).toBe(2);
    expect(visitors.first_time_visitors).toBe(2);
    expect(visitors.avg_minutes).toBe(40);
    expect(visitors.families).toEqual({ member: 0, regular_attendee: 0, visitor: 2, not_recorded: 0 });
  });

  it("drops a room that had none of that family, and keeps the server's order", () => {
    const rows = [
      row({ session_date: "2026-10-04", room_name: "Joy", family_status: "visitor", children: 1 }),
      row({ session_date: "2026-10-04", room_name: "Shine", family_status: "member", children: 4 }),
      row({ session_date: "2026-09-27", room_name: "Joy", family_status: "visitor", children: 2 }),
    ];
    expect(mergeFamilies(rows, "visitor").map((r) => `${r.session_date} ${r.room_name}`)).toEqual([
      "2026-10-04 Joy",
      "2026-09-27 Joy",
    ]);
  });

  it("files an unknown or missing status as not recorded rather than losing the children", () => {
    const rows = [row({ family_status: null, children: 4 }), row({ family_status: "elder", children: 1 })];
    expect(mergeFamilies(rows, "not_recorded")[0].children).toBe(5);
    expect(countFamilyRows(rows).not_recorded).toBe(5);
    expect(asFamily("visitor")).toBe("visitor");
  });
});

describe("filtering by family across a range", () => {
  // Three Sundays; visitors came on two of them.
  const rows = [
    row({ session_date: "2026-10-04", room_name: "Joy", family_status: "member", children: 10 }),
    row({ session_date: "2026-10-04", room_name: "Joy", family_status: "visitor", children: 3 }),
    row({ session_date: "2026-09-27", room_name: "Joy", family_status: "member", children: 12 }),
    row({ session_date: "2026-09-20", room_name: "Joy", family_status: "member", children: 9 }),
    row({ session_date: "2026-09-20", room_name: "Joy", family_status: "visitor", children: 3 }),
  ];
  const every = mergeFamilies(rows, "all");
  const dates = groupByDay(every).map((d) => d.session_date);

  it("keeps a Sunday with no visitors as a zero, so the average is per Sunday", () => {
    const days = padDays(groupByDay(mergeFamilies(rows, "visitor")), dates);
    expect(days.map((d) => [d.session_date, d.totals.children])).toEqual([
      ["2026-10-04", 3],
      ["2026-09-27", 0],
      ["2026-09-20", 3],
    ]);
    const summary = summarizeDays(days);
    expect(summary.perDay).toBe(2);
    // The latest Sunday is still the latest Sunday, compared with the one before.
    expect(summary.latest).toEqual({ session_date: "2026-10-04", children: 3, previous: 0 });
  });

  it("averages a room's visitors over the Sundays the room was open", () => {
    const [room] = summarizeRooms(mergeFamilies(rows, "visitor"), datesOpen(every));
    expect(room.sessions).toBe(3);
    expect(room.total).toBe(6);
    expect(room.average).toBe(2);
  });

  it("counts each family's check-ins for the legend", () => {
    expect(countFamilies(every)).toEqual({ member: 31, regular_attendee: 0, visitor: 6, not_recorded: 0 });
    expect(countFamilyRows(rows)).toEqual(countFamilies(every));
  });
});
