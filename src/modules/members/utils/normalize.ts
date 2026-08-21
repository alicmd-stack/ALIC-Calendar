/**
 * Normalisation for search and duplicate detection.
 *
 * IMPORTANT: these are mirrored by generated columns in the database
 * (`church.people.search_name`, `church.people.phone_digits`). The database is
 * authoritative — it is what the indexes and the station lookup use. These
 * exist for instant client-side feedback and for within-file deduplication
 * during CSV import.
 *
 * The two implementations WILL drift if changed carelessly. `normalize.test.ts`
 * is the shared contract; if you change a rule here, change the SQL generated
 * column in the same commit.
 */

/**
 * Normalised name key: lowercased, collapsed whitespace.
 *
 * Deliberately does NOT strip diacritics or transliterate. ALIC's directory is
 * bilingual, and mangling Amharic or accented Latin names to make matching
 * easier would corrupt the thing being matched.
 */
export function normalizeName(value: string | null | undefined): string {
  if (!value) return "";
  return value.trim().toLowerCase().replace(/\s+/g, " ");
}

/** "first last", matching the SQL generated column `search_name`. */
export function normalizeFullName(
  first: string | null | undefined,
  last: string | null | undefined
): string {
  return normalizeName(`${first ?? ""} ${last ?? ""}`);
}

/**
 * Digits only, matching the SQL generated column `phone_digits`.
 *
 * No country-code handling on purpose: this is a US congregation, and the
 * station matches on trailing digits, so a leading 1 is harmless.
 */
export function normalizePhone(value: string | null | undefined): string {
  if (!value) return "";
  return value.replace(/\D/g, "");
}

/** Last N digits, for the station's "type the last 4" lookup. */
export function phoneSuffix(value: string | null | undefined, n = 4): string {
  const digits = normalizePhone(value);
  return digits.length <= n ? digits : digits.slice(-n);
}

/** Mask a phone for display next to a family name on a station screen. */
export function maskPhone(value: string | null | undefined): string | null {
  const digits = normalizePhone(value);
  if (!digits) return null;
  return `•••-${digits.slice(-4)}`;
}

/** Lowercased and trimmed. Emails are case-insensitive in practice. */
export function normalizeEmail(value: string | null | undefined): string {
  if (!value) return "";
  return value.trim().toLowerCase();
}

/** Display name honouring a preferred name. */
export function displayName(person: {
  first_name?: string | null;
  last_name?: string | null;
  preferred_name?: string | null;
}): string {
  const first = person.preferred_name?.trim() || person.first_name?.trim() || "";
  const last = person.last_name?.trim() || "";
  return [first, last].filter(Boolean).join(" ") || "Unnamed";
}

/** "Daniel B." — for screens a queue of parents can see. */
export function shortDisplayName(person: {
  first_name?: string | null;
  last_name?: string | null;
  preferred_name?: string | null;
}): string {
  const first = person.preferred_name?.trim() || person.first_name?.trim() || "";
  const last = person.last_name?.trim() || "";
  return last ? `${first} ${last.charAt(0).toUpperCase()}.` : first || "Unnamed";
}

/** Initials for an avatar fallback. */
export function initials(person: {
  first_name?: string | null;
  last_name?: string | null;
  preferred_name?: string | null;
}): string {
  const first = (person.preferred_name?.trim() || person.first_name?.trim() || "").charAt(0);
  const last = (person.last_name?.trim() || "").charAt(0);
  return `${first}${last}`.toUpperCase() || "?";
}
