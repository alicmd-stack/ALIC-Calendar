/**
 * Shared Export Primitives
 *
 * Low-level, dependency-free helpers for building CSV / Excel / printable
 * exports. Promoted out of `src/modules/budget/utils/exportUtils.ts` so that
 * every module serialises data the same (correct) way instead of re-deriving
 * it — there were four copies of CSV serialisation in this repo and two of
 * them did a bare `row.join(",")`, which silently corrupts any value
 * containing a comma.
 *
 * Everything here is pure except `downloadFile`, so it can be unit-tested in
 * the node test environment.
 */

/**
 * Quote a single CSV field per RFC 4180.
 *
 * Wraps in double quotes when the value contains a delimiter, a quote, a
 * newline (LF or CR), or has significant leading/trailing whitespace that a
 * spreadsheet would otherwise strip. Embedded quotes are doubled.
 */
export const escapeCSVValue = (value: string | number | null | undefined): string => {
  if (value === null || value === undefined) return "";
  const stringValue = String(value);
  const needsQuoting =
    stringValue.includes(",") ||
    stringValue.includes('"') ||
    stringValue.includes("\n") ||
    stringValue.includes("\r") ||
    stringValue !== stringValue.trim();

  if (needsQuoting) {
    return `"${stringValue.replace(/"/g, '""')}"`;
  }
  return stringValue;
};

/**
 * Neutralise a value that a spreadsheet would otherwise evaluate as a formula.
 *
 * Excel and Sheets treat a cell beginning with = + - @ (or a leading tab /
 * carriage return) as a formula, which makes an exported free-text field a
 * code-execution vector for whoever opens the file. Prefixing with a single
 * quote renders it as literal text.
 *
 * Apply to free-text columns (names, notes, addresses). Not applied
 * automatically by `toCSV`, because it would alter existing numeric columns.
 */
export const sanitizeSpreadsheetCell = (
  value: string | number | null | undefined
): string | number => {
  if (value === null || value === undefined) return "";
  if (typeof value === "number") return value;
  return /^[=+\-@\t\r]/.test(value) ? `'${value}` : value;
};

/**
 * Serialise a header row plus data rows into a CSV document.
 *
 * Uses CRLF line endings, which is what RFC 4180 specifies and what Excel
 * expects; LF-only files render as a single line in some Excel versions.
 */
export const toCSV = (
  headers: string[],
  rows: (string | number | null | undefined)[][]
): string => {
  const lines = [
    headers.map(escapeCSVValue).join(","),
    ...rows.map((row) => row.map(escapeCSVValue).join(",")),
  ];
  return lines.join("\r\n");
};

/**
 * Prepend a UTF-8 BOM so Excel detects the encoding.
 *
 * Without it, Excel on Windows opens UTF-8 CSVs as windows-1252 and Amharic
 * text (and any accented Latin name) arrives as mojibake.
 */
export const withUTF8BOM = (content: string): string => `﻿${content}`;

/**
 * Escape text for interpolation into HTML.
 *
 * Regex-based rather than the `document.createElement` trick used previously,
 * so it is pure, testable in node, and usable when building a standalone HTML
 * document as a string (e.g. a print label) rather than mutating the DOM.
 */
export const escapeHTML = (value: string | number | null | undefined): string => {
  if (value === null || value === undefined) return "";
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
};

/** `YYYYMMDD` stamp for export filenames, in the viewer's local timezone. */
export const getDateStamp = (date: Date = new Date()): string => {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}${month}${day}`;
};

/** Short human-readable date, or "" for null/invalid input. */
export const formatExportDate = (dateString: string | null | undefined): string => {
  if (!dateString) return "";
  const parsed = new Date(dateString);
  if (Number.isNaN(parsed.getTime())) return "";
  return parsed.toLocaleDateString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
};

/** Trigger a browser download of an in-memory string. Impure; browser only. */
export const downloadFile = (content: string, filename: string, mimeType: string): void => {
  const blob = new Blob([content], { type: `${mimeType};charset=utf-8;` });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.setAttribute("href", url);
  link.setAttribute("download", filename);
  link.style.visibility = "hidden";
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
  URL.revokeObjectURL(url);
};
