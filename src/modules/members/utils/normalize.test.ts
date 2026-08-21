/**
 * Normalisation tests.
 *
 * This file is the shared contract between the TypeScript helpers and the SQL
 * generated columns church.people.search_name / church.people.phone_digits.
 * If a rule changes here it must change in the migration too, or client-side
 * duplicate detection will silently disagree with the database.
 */

import { describe, it, expect } from "vitest";
import {
  normalizeName,
  normalizeFullName,
  normalizePhone,
  phoneSuffix,
  maskPhone,
  normalizeEmail,
  displayName,
  shortDisplayName,
  initials,
} from "./normalize";

describe("normalizePhone", () => {
  it("reduces every common written form to the same digits", () => {
    const expected = "3015550101";
    expect(normalizePhone("(301) 555-0101")).toBe(expected);
    expect(normalizePhone("301-555-0101")).toBe(expected);
    expect(normalizePhone("301.555.0101")).toBe(expected);
    expect(normalizePhone("301 555 0101")).toBe(expected);
  });

  it("keeps a leading country code rather than guessing it away", () => {
    // Station lookup matches on trailing digits, so a leading 1 is harmless
    // and stripping it would be a guess about which country this is.
    expect(normalizePhone("+1 301 555 0101")).toBe("13015550101");
  });

  it("returns empty for null, undefined and non-numeric text", () => {
    expect(normalizePhone(null)).toBe("");
    expect(normalizePhone(undefined)).toBe("");
    expect(normalizePhone("no phone")).toBe("");
  });
});

describe("phoneSuffix", () => {
  it("returns the trailing digits used by the station lookup", () => {
    expect(phoneSuffix("(301) 555-0101")).toBe("0101");
    expect(phoneSuffix("+1 301 555 0101")).toBe("0101");
  });

  it("returns everything when shorter than requested", () => {
    expect(phoneSuffix("12")).toBe("12");
  });
});

describe("maskPhone", () => {
  it("shows only the last four digits", () => {
    expect(maskPhone("(301) 555-0101")).toBe("•••-0101");
  });

  it("returns null when there is no phone", () => {
    expect(maskPhone(null)).toBeNull();
    expect(maskPhone("")).toBeNull();
  });

  it("never leaks the full number", () => {
    const masked = maskPhone("3015550101");
    expect(masked).not.toContain("301555");
  });
});

describe("normalizeName / normalizeFullName", () => {
  it("lowercases and collapses whitespace", () => {
    expect(normalizeName("  Daniel   Bekele ")).toBe("daniel bekele");
    expect(normalizeFullName("Daniel", "Bekele")).toBe("daniel bekele");
  });

  it("matches the SQL generated column shape", () => {
    // church.people.search_name is lower(trim(first || ' ' || last))
    expect(normalizeFullName("Daniel", "Bekele")).toBe("daniel bekele");
    expect(normalizeFullName("DANIEL", "BEKELE")).toBe("daniel bekele");
  });

  it("leaves Amharic text intact rather than transliterating it", () => {
    expect(normalizeName("አበበ በቀለ")).toBe("አበበ በቀለ");
  });

  it("preserves accented Latin characters", () => {
    // Stripping diacritics would corrupt the name to make matching easier.
    expect(normalizeName("José Álvarez")).toBe("josé álvarez");
  });

  it("handles missing halves", () => {
    expect(normalizeFullName("Daniel", null)).toBe("daniel");
    expect(normalizeFullName(null, "Bekele")).toBe("bekele");
    expect(normalizeFullName(null, null)).toBe("");
  });
});

describe("normalizeEmail", () => {
  it("lowercases and trims", () => {
    expect(normalizeEmail("  Daniel.Bekele@Example.TEST ")).toBe("daniel.bekele@example.test");
  });

  it("returns empty for null", () => {
    expect(normalizeEmail(null)).toBe("");
  });
});

describe("displayName", () => {
  it("prefers a preferred name", () => {
    expect(displayName({ first_name: "Daniel", last_name: "Bekele", preferred_name: "Danny" }))
      .toBe("Danny Bekele");
  });

  it("falls back to the legal first name", () => {
    expect(displayName({ first_name: "Daniel", last_name: "Bekele", preferred_name: null }))
      .toBe("Daniel Bekele");
  });

  it("never renders an empty string", () => {
    expect(displayName({ first_name: null, last_name: null })).toBe("Unnamed");
  });
});

describe("shortDisplayName", () => {
  it("reduces the surname to an initial for screens a queue can see", () => {
    expect(shortDisplayName({ first_name: "Noah", last_name: "Bekele" })).toBe("Noah B.");
  });

  it("omits the initial when there is no surname", () => {
    expect(shortDisplayName({ first_name: "Noah", last_name: null })).toBe("Noah");
  });
});

describe("initials", () => {
  it("builds two-letter initials", () => {
    expect(initials({ first_name: "Daniel", last_name: "Bekele" })).toBe("DB");
  });

  it("uses the preferred name when present", () => {
    expect(initials({ first_name: "Daniel", last_name: "Bekele", preferred_name: "Danny" }))
      .toBe("DB");
  });

  it("degrades to a question mark rather than empty", () => {
    expect(initials({ first_name: null, last_name: null })).toBe("?");
  });
});
