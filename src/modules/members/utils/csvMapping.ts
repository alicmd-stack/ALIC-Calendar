/**
 * CSV column mapping and row parsing for the member import.
 *
 * Pure — no papaparse, no React, no Supabase — so it runs in the node test
 * environment. The actual file parsing lives in the upload step; this module
 * decides what each column MEANS and turns a raw row into the shape the
 * import RPC expects.
 */

/** Columns the importer can populate. */
export const IMPORT_TARGETS = [
  "first_name",
  "middle_name",
  "last_name",
  "preferred_name",
  "amharic_name",
  "email",
  "phone",
  "gender",
  "marital_status",
  "birth_year",
  "birth_month",
  "member_since",
  "accepted_lord_year",
  "is_child",
  "household_name",
  "notes",
] as const;

export type ImportTarget = (typeof IMPORT_TARGETS)[number];
export const IGNORE = "__ignore__";
export type MappingValue = ImportTarget | typeof IGNORE;
export type ColumnMapping = Record<string, MappingValue>;

export const TARGET_LABELS: Record<ImportTarget, string> = {
  first_name: "First name",
  middle_name: "Middle name",
  last_name: "Last name",
  preferred_name: "Preferred name",
  amharic_name: "Amharic name",
  email: "Email",
  phone: "Phone",
  gender: "Gender",
  marital_status: "Marital status",
  birth_year: "Birth year",
  birth_month: "Birth month",
  member_since: "Member since",
  accepted_lord_year: "Accepted the Lord (year)",
  is_child: "Is a child",
  household_name: "Family / household",
  notes: "Notes",
};

/**
 * Header spellings seen in real church spreadsheets.
 *
 * Matching is on a normalised form (lowercase, non-alphanumerics collapsed),
 * so "First Name", "first_name" and "FIRST-NAME" all land on the same entry.
 */
const HEADER_ALIASES: Record<string, ImportTarget> = {
  firstname: "first_name",
  fname: "first_name",
  givenname: "first_name",
  first: "first_name",
  middlename: "middle_name",
  middle: "middle_name",
  lastname: "last_name",
  lname: "last_name",
  surname: "last_name",
  familyname: "last_name",
  last: "last_name",
  fathersname: "last_name",
  preferredname: "preferred_name",
  nickname: "preferred_name",
  goesby: "preferred_name",
  amharicname: "amharic_name",
  amharic: "amharic_name",
  email: "email",
  emailaddress: "email",
  mail: "email",
  phone: "phone",
  phonenumber: "phone",
  mobile: "phone",
  cell: "phone",
  cellphone: "phone",
  telephone: "phone",
  tel: "phone",
  contactnumber: "phone",
  gender: "gender",
  sex: "gender",
  maritalstatus: "marital_status",
  marital: "marital_status",
  birthyear: "birth_year",
  yearofbirth: "birth_year",
  yob: "birth_year",
  birthmonth: "birth_month",
  monthofbirth: "birth_month",
  membersince: "member_since",
  joindate: "member_since",
  datejoined: "member_since",
  acceptedtheLord: "accepted_lord_year",
  acceptedlord: "accepted_lord_year",
  salvationyear: "accepted_lord_year",
  ischild: "is_child",
  child: "is_child",
  // The family column is what makes an imported person visible to check-in:
  // station_search_households reaches people only THROUGH a household.
  household: "household_name",
  householdname: "household_name",
  family: "household_name",
  familyname: "household_name",
  familyid: "household_name",
  householdid: "household_name",
  homename: "household_name",
  notes: "notes",
  comment: "notes",
  comments: "notes",
  remarks: "notes",
};

export function normalizeHeader(header: string): string {
  return header.toLowerCase().replace(/[^a-z0-9]/g, "");
}

/**
 * Best-guess mapping for a set of headers. Anything unrecognised maps to
 * IGNORE rather than being guessed at — a wrong guess silently writes the
 * wrong column, which is worse than asking.
 */
export function autoMapColumns(headers: string[]): ColumnMapping {
  const mapping: ColumnMapping = {};
  const used = new Set<ImportTarget>();

  for (const header of headers) {
    const key = normalizeHeader(header);
    const target = HEADER_ALIASES[key] ?? (IMPORT_TARGETS as readonly string[]).includes(key)
      ? (HEADER_ALIASES[key] ?? (key as ImportTarget))
      : undefined;

    if (target && IMPORT_TARGETS.includes(target) && !used.has(target)) {
      mapping[header] = target;
      used.add(target);
    } else {
      mapping[header] = IGNORE;
    }
  }
  return mapping;
}

/** Strip a UTF-8 BOM, which Excel writes at the start of every CSV it saves. */
export function stripBOM(text: string): string {
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

const MONTHS = [
  "january", "february", "march", "april", "may", "june",
  "july", "august", "september", "october", "november", "december",
];

/** Accepts "3", "03", "March", "Mar". Returns null when unrecognised. */
export function parseMonth(value: string | undefined | null): number | null {
  if (!value) return null;
  const raw = String(value).trim().toLowerCase();
  if (!raw) return null;

  if (/^\d{1,2}$/.test(raw)) {
    const n = Number(raw);
    return n >= 1 && n <= 12 ? n : null;
  }
  const idx = MONTHS.findIndex((m) => m === raw || m.slice(0, 3) === raw.slice(0, 3));
  return idx >= 0 ? idx + 1 : null;
}

/** Accepts a bare year, or pulls one out of "1987-03" / "3/1987". */
export function parseYear(value: string | undefined | null): number | null {
  if (!value) return null;
  const raw = String(value).trim();
  if (!raw) return null;
  const match = raw.match(/(18|19|20)\d{2}/);
  if (!match) return null;
  const year = Number(match[0]);
  return year >= 1900 && year <= new Date().getFullYear() ? year : null;
}

/**
 * Pulls a year and month out of a single "birthday" column, which is how many
 * spreadsheets store it. The DAY is deliberately discarded — ALIC does not
 * record it and there is no column for it.
 */
export function parseYearMonth(value: string | undefined | null): {
  year: number | null;
  month: number | null;
} {
  if (!value) return { year: null, month: null };
  const raw = String(value).trim();
  const year = parseYear(raw);

  // ISO-ish: 1987-03 or 1987-03-14
  const iso = raw.match(/^(\d{4})[-/](\d{1,2})/);
  if (iso) return { year: Number(iso[1]), month: parseMonth(iso[2]) };

  // US-ish: 3/14/1987 -> month is the FIRST part
  const us = raw.match(/^(\d{1,2})[/-]\d{1,2}[/-](\d{4})$/);
  if (us) return { year: Number(us[2]), month: parseMonth(us[1]) };

  // "March 1987"
  const named = raw.match(/^([A-Za-z]+)\s+(\d{4})$/);
  if (named) return { year: Number(named[2]), month: parseMonth(named[1]) };

  return { year, month: null };
}

export function parseGender(value: string | undefined | null): string | null {
  if (!value) return null;
  const raw = String(value).trim().toLowerCase();
  if (["m", "male", "man", "boy"].includes(raw)) return "male";
  if (["f", "female", "woman", "girl"].includes(raw)) return "female";
  if (raw) return "unspecified";
  return null;
}

export function parseMaritalStatus(value: string | undefined | null): string | null {
  if (!value) return null;
  const raw = String(value).trim().toLowerCase();
  const map: Record<string, string> = {
    s: "single", single: "single", unmarried: "single",
    m: "married", married: "married",
    w: "widowed", widowed: "widowed", widow: "widowed", widower: "widowed",
    d: "divorced", divorced: "divorced",
    separated: "separated",
  };
  return map[raw] ?? (raw ? "other" : null);
}

export function parseBoolean(value: string | undefined | null): boolean {
  if (!value) return false;
  return ["y", "yes", "true", "1", "child", "x"].includes(
    String(value).trim().toLowerCase()
  );
}

export interface ParsedRow {
  first_name?: string;
  middle_name?: string;
  last_name?: string;
  preferred_name?: string;
  amharic_name?: string;
  email?: string;
  phone?: string;
  gender?: string;
  marital_status?: string;
  birth_year?: string;
  birth_month?: string;
  member_since?: string;
  accepted_lord_year?: string;
  is_child?: boolean;
  /** Groups rows into one family. Matched by name within the branch. */
  household_name?: string;
  notes?: string;
}

/**
 * Turn one raw CSV row into the payload shape the import RPC consumes.
 *
 * Values are emitted as strings because the RPC parses and validates them
 * itself — the database is the authority on what is acceptable, and doing the
 * coercion twice invites the two from disagreeing.
 */
export function applyMapping(
  row: Record<string, string>,
  mapping: ColumnMapping
): ParsedRow {
  const out: ParsedRow = {};
  const notes: string[] = [];

  for (const [header, target] of Object.entries(mapping)) {
    const value = (row[header] ?? "").trim();
    if (target === IGNORE || !value) continue;

    switch (target) {
      case "birth_year": {
        const { year, month } = parseYearMonth(value);
        if (year) out.birth_year = String(year);
        // A single "birthday" column often carries the month too.
        if (month && !out.birth_month) out.birth_month = String(month);
        break;
      }
      case "birth_month": {
        const month = parseMonth(value);
        if (month) out.birth_month = String(month);
        break;
      }
      case "accepted_lord_year": {
        const year = parseYear(value);
        if (year) out.accepted_lord_year = String(year);
        break;
      }
      case "gender":
        out.gender = parseGender(value) ?? undefined;
        break;
      case "marital_status":
        out.marital_status = parseMaritalStatus(value) ?? undefined;
        break;
      case "is_child":
        out.is_child = parseBoolean(value);
        break;
      case "notes":
        notes.push(value);
        break;
      default:
        out[target] = value;
    }
  }

  if (notes.length) out.notes = notes.join(" | ");
  return out;
}
