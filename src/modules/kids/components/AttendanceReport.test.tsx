// @vitest-environment jsdom

/**
 * The attendance report's family filter, rendered with rows shaped like
 * church.kids_attendance_by_family's. The arithmetic is tested in
 * utils/attendanceFamilies; this checks the screen uses it: the filter's
 * counts, the tiles following the filter, and the export getting what is
 * on screen.
 */

import { describe, it, expect, vi, afterEach } from "vitest";
import "@testing-library/jest-dom/vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

vi.mock("../hooks/useKidsLeader", () => ({
  useKidsChildAttendance: () => ({ data: [], isLoading: false, isPlaceholderData: false, error: null }),
}));

import { AttendanceReport } from "./AttendanceReport";
import type { FamilyAttendanceRow } from "../utils/attendanceFamilies";

// jsdom has no layout; recharts' container only needs to exist.
globalThis.ResizeObserver ??= class {
  observe() {}
  unobserve() {}
  disconnect() {}
} as unknown as typeof ResizeObserver;

const row = (p: Partial<FamilyAttendanceRow>): FamilyAttendanceRow => ({
  session_date: "2026-10-04",
  service_label: "Sunday Service",
  room_name: "Joy",
  age_band_name: null,
  family_status: "member",
  children: 0,
  first_time_visitors: 0,
  volunteers: 0,
  overrides: 0,
  not_checked_out: 0,
  avg_minutes: 90,
  ...p,
});

// Two Sundays. Members 30, visitors 4 (all on 4 October), not recorded 6.
const ROWS = [
  row({ session_date: "2026-10-04", family_status: "member", children: 14 }),
  row({ session_date: "2026-10-04", family_status: "visitor", children: 4, first_time_visitors: 3 }),
  row({ session_date: "2026-10-04", family_status: "not_recorded", children: 2 }),
  row({ session_date: "2026-09-27", family_status: "member", children: 16 }),
  row({ session_date: "2026-09-27", family_status: "not_recorded", children: 4 }),
];

afterEach(cleanup);

function renderReport(onExport = vi.fn()) {
  render(
    <AttendanceReport
      organizationId="org"
      from="2026-09-01"
      to="2026-10-09"
      rows={ROWS}
      isLoading={false}
      isStale={false}
      onExport={onExport}
    />,
  );
  return onExport;
}

describe("AttendanceReport, by family", () => {
  it("counts each family's check-ins on the filter, and offers none it has no rows for", () => {
    renderReport();
    const filter = screen.getByRole("group", { name: "Family" });
    expect(filter).toHaveTextContent(/All\s*40/);
    expect(screen.getByRole("button", { name: /Members\s*30/ })).toBeEnabled();
    expect(screen.getByRole("button", { name: /Visitors\s*4/ })).toBeEnabled();
    expect(screen.getByRole("button", { name: /Regular attendees\s*0/ })).toBeDisabled();
    expect(screen.getByText("Check-ins").nextSibling).toHaveTextContent("40");
  });

  it("narrows the tiles to visitor families, averaged over every Sunday", async () => {
    const user = userEvent.setup();
    renderReport();
    await user.click(screen.getByRole("button", { name: /Visitors\s*4/ }));
    expect(screen.getByText("Check-ins · Visitors").nextSibling).toHaveTextContent("4");
    expect(screen.getByText("10% of all 40 check-ins")).toBeInTheDocument();
    // 4 visitors over 2 Sundays, not 4 over the 1 Sunday they came.
    expect(screen.getByText("Average per Sunday").nextSibling).toHaveTextContent("2");
    expect(screen.getByText(/Visitor families, by membership status as recorded today/)).toBeInTheDocument();
  });

  it("exports what is on screen, with the filter it was filtered by", async () => {
    const user = userEvent.setup();
    const onExport = renderReport();
    await user.click(screen.getByRole("button", { name: /Visitors\s*4/ }));
    await user.click(screen.getByRole("button", { name: "CSV" }));
    const [rows, family] = onExport.mock.calls[0];
    expect(family).toBe("visitor");
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ session_date: "2026-10-04", children: 4 });
  });
});
