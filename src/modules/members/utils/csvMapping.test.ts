/**
 * CSV mapping tests.
 *
 * These cover the messy realities of church spreadsheets: inconsistent header
 * spellings, birthdays written six different ways, and single-letter codes for
 * gender and marital status. The day of birth must always be discarded,
 * because there is nowhere to put it.
 */

import { describe, it, expect } from "vitest";
import type { ColumnMapping } from "./csvMapping";
import {
  autoMapColumns,
  normalizeHeader,
  stripBOM,
  parseMonth,
  parseYear,
  parseYearMonth,
  parseGender,
  parseMaritalStatus,
  parseBoolean,
  applyMapping,
  IGNORE,
} from "./csvMapping";

describe("normalizeHeader", () => {
  it("collapses case and punctuation", () => {
    expect(normalizeHeader("First Name")).toBe("firstname");
    expect(normalizeHeader("first_name")).toBe("firstname");
    expect(normalizeHeader("FIRST-NAME")).toBe("firstname");
    expect(normalizeHeader("Phone #")).toBe("phone");
  });
});

describe("autoMapColumns", () => {
  it("maps common header spellings", () => {
    const m = autoMapColumns(["First Name", "Last Name", "Cell Phone", "Email Address"]);
    expect(m["First Name"]).toBe("first_name");
    expect(m["Last Name"]).toBe("last_name");
    expect(m["Cell Phone"]).toBe("phone");
    expect(m["Email Address"]).toBe("email");
  });

  it("ignores unrecognised headers rather than guessing", () => {
    // A wrong guess silently writes the wrong column, which is worse than
    // making someone pick.
    const m = autoMapColumns(["Ministry Team", "Giving Number"]);
    expect(m["Ministry Team"]).toBe(IGNORE);
    expect(m["Giving Number"]).toBe(IGNORE);
  });

  it("does not map two columns to the same target", () => {
    const m = autoMapColumns(["Phone", "Mobile"]);
    const targets = Object.values(m).filter((t) => t !== IGNORE);
    expect(new Set(targets).size).toBe(targets.length);
  });
});

describe("stripBOM", () => {
  it("removes the BOM Excel writes", () => {
    expect(stripBOM("﻿First Name")).toBe("First Name");
  });

  it("leaves ordinary text alone", () => {
    expect(stripBOM("First Name")).toBe("First Name");
  });
});

describe("parseMonth", () => {
  it("accepts numbers, names and abbreviations", () => {
    expect(parseMonth("3")).toBe(3);
    expect(parseMonth("03")).toBe(3);
    expect(parseMonth("March")).toBe(3);
    expect(parseMonth("Mar")).toBe(3);
    expect(parseMonth("december")).toBe(12);
  });

  it("rejects out-of-range and nonsense", () => {
    expect(parseMonth("13")).toBeNull();
    expect(parseMonth("0")).toBeNull();
    expect(parseMonth("Smarch")).toBeNull();
    expect(parseMonth("")).toBeNull();
    expect(parseMonth(null)).toBeNull();
  });
});

describe("parseYear", () => {
  it("extracts a plausible year", () => {
    expect(parseYear("1985")).toBe(1985);
    expect(parseYear("born 1985")).toBe(1985);
  });

  it("rejects impossible years", () => {
    expect(parseYear("1899")).toBeNull();
    expect(parseYear("3000")).toBeNull();
    expect(parseYear("abc")).toBeNull();
  });
});

describe("parseYearMonth", () => {
  it("handles ISO dates and DISCARDS the day", () => {
    // There is no day-of-birth column anywhere in this system.
    expect(parseYearMonth("1987-03-14")).toEqual({ year: 1987, month: 3 });
    expect(parseYearMonth("1987-03")).toEqual({ year: 1987, month: 3 });
  });

  it("handles US-style dates, taking the first part as the month", () => {
    expect(parseYearMonth("3/14/1987")).toEqual({ year: 1987, month: 3 });
  });

  it("handles a written month and year", () => {
    expect(parseYearMonth("March 1987")).toEqual({ year: 1987, month: 3 });
  });

  it("returns a year alone when there is no month", () => {
    expect(parseYearMonth("1987")).toEqual({ year: 1987, month: null });
  });

  it("returns nulls for unparseable input", () => {
    expect(parseYearMonth("sometime")).toEqual({ year: null, month: null });
    expect(parseYearMonth("")).toEqual({ year: null, month: null });
  });
});

describe("parseGender", () => {
  it("normalises the usual codes", () => {
    expect(parseGender("M")).toBe("male");
    expect(parseGender("male")).toBe("male");
    expect(parseGender("F")).toBe("female");
    expect(parseGender("Female")).toBe("female");
  });

  it("falls back to unspecified rather than dropping the value", () => {
    expect(parseGender("other")).toBe("unspecified");
  });

  it("returns null for blank", () => {
    expect(parseGender("")).toBeNull();
    expect(parseGender(null)).toBeNull();
  });
});

describe("parseMaritalStatus", () => {
  it("maps codes and full words to the CHECK-constrained values", () => {
    expect(parseMaritalStatus("S")).toBe("single");
    expect(parseMaritalStatus("Married")).toBe("married");
    expect(parseMaritalStatus("widow")).toBe("widowed");
    expect(parseMaritalStatus("D")).toBe("divorced");
    expect(parseMaritalStatus("Separated")).toBe("separated");
  });

  it("maps anything unrecognised to 'other', which the CHECK allows", () => {
    expect(parseMaritalStatus("its complicated")).toBe("other");
  });

  it("returns null for blank", () => {
    expect(parseMaritalStatus("")).toBeNull();
  });
});

describe("parseBoolean", () => {
  it("accepts the usual affirmatives", () => {
    for (const v of ["Y", "yes", "TRUE", "1", "x", "child"]) {
      expect(parseBoolean(v)).toBe(true);
    }
  });

  it("treats anything else as false", () => {
    expect(parseBoolean("N")).toBe(false);
    expect(parseBoolean("")).toBe(false);
    expect(parseBoolean(null)).toBe(false);
  });
});

describe("applyMapping", () => {
  const mapping: ColumnMapping = {
    "First Name": "first_name" as const,
    "Last Name": "last_name" as const,
    "Cell": "phone" as const,
    "Email": "email" as const,
    "Birthday": "birth_year" as const,
    "Sex": "gender" as const,
    "Marital": "marital_status" as const,
    "Team": IGNORE,
  };

  it("maps a clean row", () => {
    const out = applyMapping(
      {
        "First Name": "Daniel",
        "Last Name": "Bekele",
        Cell: "(301) 555-0101",
        Email: "daniel@example.test",
        Birthday: "1985-03-14",
        Sex: "M",
        Marital: "Married",
        Team: "Worship",
      },
      mapping
    );

    expect(out.first_name).toBe("Daniel");
    expect(out.last_name).toBe("Bekele");
    expect(out.phone).toBe("(301) 555-0101");
    expect(out.email).toBe("daniel@example.test");
    expect(out.gender).toBe("male");
    expect(out.marital_status).toBe("married");
    // A single birthday column yields BOTH year and month, and no day.
    expect(out.birth_year).toBe("1985");
    expect(out.birth_month).toBe("3");
    expect(out).not.toHaveProperty("birth_day");
  });

  it("drops ignored columns entirely", () => {
    const out = applyMapping({ Team: "Worship", "First Name": "X", "Last Name": "Y" }, mapping);
    expect(JSON.stringify(out)).not.toContain("Worship");
  });

  it("skips blank values rather than writing empty strings", () => {
    const out = applyMapping(
      { "First Name": "Daniel", "Last Name": "Bekele", Cell: "", Email: "  " },
      mapping
    );
    expect(out.phone).toBeUndefined();
    expect(out.email).toBeUndefined();
  });

  it("combines multiple note columns", () => {
    const m: ColumnMapping = { A: "notes", B: "notes" };
    const out = applyMapping({ A: "first", B: "second" }, m);
    expect(out.notes).toBe("first | second");
  });
});
