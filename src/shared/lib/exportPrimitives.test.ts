/**
 * Tests for shared export primitives.
 *
 * These exist because two components in the budget module shipped a bare
 * `row.join(",")`, which corrupts any exported value containing a comma —
 * and member data (names, addresses, notes) is full of commas.
 */

import { describe, it, expect } from "vitest";
import {
  escapeCSVValue,
  sanitizeSpreadsheetCell,
  toCSV,
  withUTF8BOM,
  escapeHTML,
  getDateStamp,
  formatExportDate,
} from "./exportPrimitives";

describe("escapeCSVValue", () => {
  it("passes through plain values untouched", () => {
    expect(escapeCSVValue("Abebe")).toBe("Abebe");
    expect(escapeCSVValue(42)).toBe("42");
    expect(escapeCSVValue(0)).toBe("0");
  });

  it("returns empty string for null and undefined", () => {
    expect(escapeCSVValue(null)).toBe("");
    expect(escapeCSVValue(undefined)).toBe("");
  });

  it("quotes values containing a comma", () => {
    expect(escapeCSVValue("Bekele, Abebe")).toBe('"Bekele, Abebe"');
    expect(escapeCSVValue("11961 Tech Rd, Silver Spring, MD")).toBe(
      '"11961 Tech Rd, Silver Spring, MD"'
    );
  });

  it("doubles embedded quotes and wraps", () => {
    expect(escapeCSVValue('Sara "Sari" A.')).toBe('"Sara ""Sari"" A."');
    expect(escapeCSVValue('"')).toBe('""""');
  });

  it("quotes values containing newlines, including bare CR", () => {
    expect(escapeCSVValue("line one\nline two")).toBe('"line one\nline two"');
    expect(escapeCSVValue("line one\r\nline two")).toBe('"line one\r\nline two"');
    expect(escapeCSVValue("line one\rline two")).toBe('"line one\rline two"');
  });

  it("preserves significant leading and trailing whitespace by quoting", () => {
    expect(escapeCSVValue("  padded  ")).toBe('"  padded  "');
  });

  it("handles a value that is both quoted and comma-bearing", () => {
    expect(escapeCSVValue('Ministry "Youth", VA')).toBe('"Ministry ""Youth"", VA"');
  });
});

describe("sanitizeSpreadsheetCell", () => {
  it("neutralises formula-leading characters", () => {
    expect(sanitizeSpreadsheetCell("=HYPERLINK(\"http://evil\")")).toBe(
      "'=HYPERLINK(\"http://evil\")"
    );
    expect(sanitizeSpreadsheetCell("+1234")).toBe("'+1234");
    expect(sanitizeSpreadsheetCell("-Abebe")).toBe("'-Abebe");
    expect(sanitizeSpreadsheetCell("@handle")).toBe("'@handle");
  });

  it("leaves ordinary text and numbers alone", () => {
    expect(sanitizeSpreadsheetCell("Abebe")).toBe("Abebe");
    expect(sanitizeSpreadsheetCell(42)).toBe(42);
    expect(sanitizeSpreadsheetCell("301-555-0101")).toBe("301-555-0101");
  });

  it("returns empty string for null and undefined", () => {
    expect(sanitizeSpreadsheetCell(null)).toBe("");
    expect(sanitizeSpreadsheetCell(undefined)).toBe("");
  });
});

describe("toCSV", () => {
  it("serialises headers and rows with CRLF endings", () => {
    const csv = toCSV(["Name", "Ministry"], [["Abebe", "Worship"]]);
    expect(csv).toBe("Name,Ministry\r\nAbebe,Worship");
  });

  it("escapes every field, not just some", () => {
    const csv = toCSV(
      ["Name", "Address"],
      [["Bekele, Abebe", "11961 Tech Rd, Silver Spring"]]
    );
    expect(csv).toBe(
      'Name,Address\r\n"Bekele, Abebe","11961 Tech Rd, Silver Spring"'
    );
  });

  it("renders null and undefined cells as empty", () => {
    const csv = toCSV(["A", "B", "C"], [["x", null, undefined]]);
    expect(csv).toBe("A,B,C\r\nx,,");
  });

  it("handles an empty row set", () => {
    expect(toCSV(["A", "B"], [])).toBe("A,B");
  });

  it("round-trips a value containing a comma as one field", () => {
    const csv = toCSV(["Name"], [["Bekele, Abebe"]]);
    const dataLine = csv.split("\r\n")[1];
    // Naive split would yield 2 fields; correct quoting keeps it as one.
    expect(dataLine).toBe('"Bekele, Abebe"');
  });
});

describe("withUTF8BOM", () => {
  it("prepends the BOM so Excel detects UTF-8", () => {
    const result = withUTF8BOM("Name\r\nአበበ");
    expect(result.charCodeAt(0)).toBe(0xfeff);
    expect(result.slice(1)).toBe("Name\r\nአበበ");
  });
});

describe("escapeHTML", () => {
  it("escapes the five significant characters", () => {
    expect(escapeHTML('<script>alert("x")</script>')).toBe(
      "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;"
    );
    expect(escapeHTML("Tom & Jerry")).toBe("Tom &amp; Jerry");
    expect(escapeHTML("O'Brien")).toBe("O&#39;Brien");
  });

  it("escapes ampersands before other entities so they are not double-encoded", () => {
    expect(escapeHTML("&lt;")).toBe("&amp;lt;");
  });

  it("leaves Amharic and other non-ASCII text intact", () => {
    expect(escapeHTML("የልጆች አገልግሎት")).toBe("የልጆች አገልግሎት");
  });

  it("returns empty string for null and undefined", () => {
    expect(escapeHTML(null)).toBe("");
    expect(escapeHTML(undefined)).toBe("");
  });
});

describe("getDateStamp", () => {
  it("zero-pads month and day", () => {
    expect(getDateStamp(new Date(2026, 0, 5))).toBe("20260105");
    expect(getDateStamp(new Date(2026, 11, 31))).toBe("20261231");
  });
});

describe("formatExportDate", () => {
  it("formats an ISO date", () => {
    expect(formatExportDate("2026-08-16T09:00:00.000Z")).toMatch(/2026/);
  });

  it("returns empty string for null, undefined and unparseable input", () => {
    expect(formatExportDate(null)).toBe("");
    expect(formatExportDate(undefined)).toBe("");
    expect(formatExportDate("not-a-date")).toBe("");
  });
});
