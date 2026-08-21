/**
 * Members module utilities
 *
 * Pure helpers only — no React, no Supabase — so they stay unit-testable in
 * the node test environment.
 */

export {
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
export type { BirthInfo } from "./age";

export {
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

export {
  autoMapColumns,
  applyMapping,
  normalizeHeader,
  stripBOM,
  parseMonth,
  parseYear,
  parseYearMonth,
  parseGender,
  parseMaritalStatus,
  parseBoolean,
  IMPORT_TARGETS,
  TARGET_LABELS,
  IGNORE,
} from "./csvMapping";
export type { ColumnMapping, ImportTarget, MappingValue, ParsedRow } from "./csvMapping";
