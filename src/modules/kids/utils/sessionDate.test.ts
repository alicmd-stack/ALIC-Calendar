import { describe, it, expect } from "vitest";
import { formatSessionDate, parseIsoDate } from "./sessionDate";

describe("formatSessionDate", () => {
  it("keeps the calendar day the database meant", () => {
    // The bug this exists to prevent: new Date("2026-08-21") is midnight UTC,
    // which is the evening of the 20th in every US zone.
    expect(formatSessionDate("2026-08-21")).toBe("Aug 21");
  });

  it("does not shift a date west of Greenwich", () => {
    // Jan 1 is the worst case — an off-by-one crosses the year as well.
    expect(formatSessionDate("2026-01-01")).toBe("Jan 1");
  });

  it("accepts a full timestamp and takes its date part", () => {
    expect(formatSessionDate("2026-08-21T14:30:00+00:00")).toBe("Aug 21");
  });

  it("renders nothing rather than 'Invalid Date'", () => {
    expect(formatSessionDate(null)).toBe("");
    expect(formatSessionDate(undefined)).toBe("");
    expect(formatSessionDate("")).toBe("");
    expect(formatSessionDate("not a date")).toBe("");
  });

  it("honours a caller's format options", () => {
    expect(
      formatSessionDate("2026-08-21", { weekday: "long", month: "long", day: "numeric" })
    ).toBe("Friday, August 21");
  });
});

describe("parseIsoDate", () => {
  it("builds a LOCAL midnight, not a UTC one", () => {
    const d = parseIsoDate("2026-08-21")!;
    expect(d.getFullYear()).toBe(2026);
    expect(d.getMonth()).toBe(7); // zero-based
    expect(d.getDate()).toBe(21);
    expect(d.getHours()).toBe(0);
  });

  it("returns null for anything that is not a date", () => {
    expect(parseIsoDate(null)).toBeNull();
    expect(parseIsoDate("21-08-2026")).toBeNull();
  });
});
