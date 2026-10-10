// @vitest-environment jsdom

/**
 * The by-child grid, rendered with the rows church.kids_child_attendance
 * returns. The pivot itself is tested in utils/childAttendance; this checks
 * that the screen shows it: a row per child, a tick per date they came, and
 * the follow-up filter narrowing the list to the right child.
 */

import { describe, it, expect, vi, afterEach } from "vitest";
import "@testing-library/jest-dom/vitest";
import { cleanup, render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

const rows = [
  ...["2026-10-04", "2026-09-27", "2026-09-20"].map((d) => ({
    child_person_id: "hana",
    child_name: "Hana Bekele",
    session_date: d,
    room_name: "Joy",
    first_check_in: "2026-01-04",
    family_status: "member",
  })),
  ...["2026-09-13", "2026-09-06"].map((d) => ({
    child_person_id: "abel",
    child_name: "Abel Tesfaye",
    session_date: d,
    room_name: "Shine",
    first_check_in: "2026-01-04",
    family_status: "visitor",
  })),
];

vi.mock("../hooks/useKidsLeader", () => ({
  useKidsChildAttendance: () => ({ data: rows, isLoading: false, isPlaceholderData: false, error: null }),
}));

import { ChildAttendanceTable } from "./ChildAttendanceTable";

const DATES = ["2026-10-04", "2026-09-27", "2026-09-20", "2026-09-13", "2026-09-06"];

afterEach(cleanup);

describe("ChildAttendanceTable", () => {
  it("shows each child with their count and a tick for each date they came", () => {
    render(<ChildAttendanceTable organizationId="org" from="2026-09-01" to="2026-10-09" dates={DATES} />);
    const hana = screen.getByText("Hana Bekele").closest("tr")!;
    expect(within(hana).getByText("3 of 5")).toBeInTheDocument();
    expect(within(hana).getAllByLabelText(/^Came on/)).toHaveLength(3);
    expect(within(hana).getAllByLabelText(/^Not on/)).toHaveLength(2);
  });

  it("narrows to the children who have stopped coming", async () => {
    const user = userEvent.setup();
    render(<ChildAttendanceTable organizationId="org" from="2026-09-01" to="2026-10-09" dates={DATES} />);
    await user.click(screen.getByRole("button", { name: /missing 3\+ weeks/i }));
    expect(screen.getByText("Abel Tesfaye")).toBeInTheDocument();
    expect(screen.queryByText("Hana Bekele")).not.toBeInTheDocument();
  });

  it("shows only the report's family, and counts within it", () => {
    render(
      <ChildAttendanceTable organizationId="org" from="2026-09-01" to="2026-10-09" dates={DATES} family="visitor" />,
    );
    expect(screen.getByText("Abel Tesfaye")).toBeInTheDocument();
    expect(screen.queryByText("Hana Bekele")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /all children/i })).toHaveTextContent("1");
  });

  it("names each child's family when showing them all", () => {
    render(<ChildAttendanceTable organizationId="org" from="2026-09-01" to="2026-10-09" dates={DATES} />);
    expect(within(screen.getByText("Abel Tesfaye").closest("tr")!).getByText("Visitor")).toBeInTheDocument();
    expect(within(screen.getByText("Hana Bekele").closest("tr")!).getByText("Member")).toBeInTheDocument();
  });

  it("finds a child by name", async () => {
    const user = userEvent.setup();
    render(<ChildAttendanceTable organizationId="org" from="2026-09-01" to="2026-10-09" dates={DATES} />);
    await user.type(screen.getByLabelText("Search children"), "abel");
    expect(screen.queryByText("Hana Bekele")).not.toBeInTheDocument();
    expect(screen.getByText("Abel Tesfaye")).toBeInTheDocument();
  });
});
