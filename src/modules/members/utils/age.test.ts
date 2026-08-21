/**
 * Age derivation tests.
 *
 * These pin the consequences of storing birth_year + birth_month with no day:
 * boundaries land on month edges, and anything finer than a month is not
 * representable. They also mirror the SQL functions church.age_in_months /
 * church.age_years — if you change one, change both.
 */

import { describe, it, expect } from "vitest";
import {
  ageInMonths,
  ageInYears,
  formatAge,
  suggestAgeBand,
  adultAgeGroup,
  formatBirthday,
  yearsSinceAccepted,
  isValidBirthMonth,
  isValidBirthYear,
} from "./age";

// August 2026, matching the SQL boundary tests run against the database.
const ASOF = new Date(2026, 7, 20); // month is 0-indexed: 7 = August

describe("ageInMonths", () => {
  it("matches the SQL result for a known case", () => {
    // Born March 2020 -> 77 months in August 2026. Verified against
    // church.age_in_months in the database.
    expect(ageInMonths({ birth_year: 2020, birth_month: 3 }, ASOF)).toBe(77);
  });

  it("is 0 in the month of birth", () => {
    expect(ageInMonths({ birth_year: 2026, birth_month: 8 }, ASOF)).toBe(0);
  });

  it("returns null when the year or month is missing", () => {
    expect(ageInMonths({ birth_year: null, birth_month: 3 }, ASOF)).toBeNull();
    expect(ageInMonths({ birth_year: 2020, birth_month: null }, ASOF)).toBeNull();
    expect(ageInMonths({ birth_year: null, birth_month: null }, ASOF)).toBeNull();
  });

  it("goes negative for a future birthday, which callers must treat as invalid", () => {
    expect(ageInMonths({ birth_year: 2027, birth_month: 1 }, ASOF)).toBeLessThan(0);
  });
});

describe("ageInYears", () => {
  it("floors to whole years", () => {
    expect(ageInYears({ birth_year: 2020, birth_month: 3 }, ASOF)).toBe(6);
    expect(ageInYears({ birth_year: 1985, birth_month: 3 }, ASOF)).toBe(41);
  });

  it("does not round up in the month before a birthday", () => {
    // Born September 2020: in August 2026 they are 5, not 6.
    expect(ageInYears({ birth_year: 2020, birth_month: 9 }, ASOF)).toBe(5);
  });
});

describe("suggestAgeBand", () => {
  it("uses half-open month boundaries, matching the DB seed", () => {
    // 35 months -> nursery, 36 months -> preschool. Verified against
    // church.age_band_for.
    expect(suggestAgeBand({ birth_year: 2023, birth_month: 9 }, ASOF)).toBe("nursery");
    expect(suggestAgeBand({ birth_year: 2023, birth_month: 8 }, ASOF)).toBe("preschool");
  });

  it("classifies each band", () => {
    expect(suggestAgeBand({ birth_year: 2026, birth_month: 8 }, ASOF)).toBe("nursery");
    expect(suggestAgeBand({ birth_year: 2021, birth_month: 8 }, ASOF)).toBe("elementary");
    expect(suggestAgeBand({ birth_year: 2014, birth_month: 8 }, ASOF)).toBe("preteen");
    expect(suggestAgeBand({ birth_year: 2011, birth_month: 8 }, ASOF)).toBe("youth");
    expect(suggestAgeBand({ birth_year: 2000, birth_month: 8 }, ASOF)).toBe("adult");
  });

  it("returns unknown rather than guessing when the birthday is missing", () => {
    expect(suggestAgeBand({ birth_year: null, birth_month: null }, ASOF)).toBe("unknown");
  });
});

describe("adultAgeGroup", () => {
  it("uses non-overlapping brackets", () => {
    expect(adultAgeGroup({ birth_year: 1997, birth_month: 8 }, ASOF)).toBe("20_29");
    expect(adultAgeGroup({ birth_year: 1996, birth_month: 8 }, ASOF)).toBe("30_39");
    expect(adultAgeGroup({ birth_year: 1986, birth_month: 8 }, ASOF)).toBe("40_49");
    expect(adultAgeGroup({ birth_year: 1956, birth_month: 8 }, ASOF)).toBe("70_plus");
  });

  it("returns unknown when the birthday is missing", () => {
    expect(adultAgeGroup({ birth_year: null, birth_month: null }, ASOF)).toBe("unknown");
  });
});

describe("formatAge", () => {
  it("shows months under two years and years after", () => {
    expect(formatAge({ birth_year: 2026, birth_month: 2 }, ASOF)).toBe("6 mo");
    expect(formatAge({ birth_year: 2020, birth_month: 3 }, ASOF)).toBe("6 yr");
  });

  it("shows an em dash rather than a fabricated age", () => {
    expect(formatAge({ birth_year: null, birth_month: null }, ASOF)).toBe("—");
  });
});

describe("formatBirthday", () => {
  it("renders month and year", () => {
    expect(formatBirthday({ birth_year: 1985, birth_month: 3 })).toBe("March 1985");
  });

  it("renders the month alone when the year is absent", () => {
    expect(formatBirthday({ birth_year: null, birth_month: 3 })).toBe("March");
  });

  it("renders an em dash when nothing is known", () => {
    expect(formatBirthday({ birth_year: null, birth_month: null })).toBe("—");
  });

  it("never renders a day, because no day is stored", () => {
    const out = formatBirthday({ birth_year: 1985, birth_month: 3 });
    expect(out).not.toMatch(/\d{1,2}(st|nd|rd|th)/);
    expect(out).toBe("March 1985");
  });
});

describe("yearsSinceAccepted", () => {
  it("calculates from the stored year rather than a stored count", () => {
    expect(yearsSinceAccepted(2010, 6, ASOF)).toBe(16);
  });

  it("assumes January when only a year is known", () => {
    expect(yearsSinceAccepted(2010, null, ASOF)).toBe(16);
  });

  it("returns null when unknown, and for a future date", () => {
    expect(yearsSinceAccepted(null, null, ASOF)).toBeNull();
    expect(yearsSinceAccepted(2030, 1, ASOF)).toBeNull();
  });
});

describe("validation", () => {
  it("accepts months 1-12 and null, rejects the rest", () => {
    expect(isValidBirthMonth(1)).toBe(true);
    expect(isValidBirthMonth(12)).toBe(true);
    expect(isValidBirthMonth(null)).toBe(true);
    expect(isValidBirthMonth(0)).toBe(false);
    expect(isValidBirthMonth(13)).toBe(false);
    expect(isValidBirthMonth(3.5)).toBe(false);
  });

  it("accepts plausible years and null, rejects future and ancient", () => {
    expect(isValidBirthYear(1985, ASOF)).toBe(true);
    expect(isValidBirthYear(null, ASOF)).toBe(true);
    expect(isValidBirthYear(2026, ASOF)).toBe(true);
    expect(isValidBirthYear(2027, ASOF)).toBe(false);
    expect(isValidBirthYear(1899, ASOF)).toBe(false);
  });
});
