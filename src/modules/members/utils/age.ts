/**
 * Age derivation from birth_year + birth_month.
 *
 * ALIC stores the year and month of birth but NOT the day. Every function here
 * is therefore exact to the month and no finer, and none of them should ever
 * pretend otherwise — there is no "turns 5 next Tuesday" available, and
 * "birthdays this week" is not computable.
 *
 * These mirror the SQL functions `church.age_in_months` / `church.age_years`.
 * The database is authoritative for classroom placement; this exists so the UI
 * can show and sort without a round trip. Keep the two in step.
 *
 * Pure — no React, no Supabase — so it runs in the node test environment.
 */

import type { AdultAgeGroup, AgeBandCode } from "../types";
import { MONTH_NAMES } from "../types";

export interface BirthInfo {
  birth_year: number | null;
  birth_month: number | null;
}

/**
 * Whole months elapsed, or null when the birthday is unknown.
 *
 * Mirrors the SQL: (year*12 + month) difference. A child born in the reference
 * month is 0 months old.
 */
export function ageInMonths(birth: BirthInfo, asOf: Date = new Date()): number | null {
  if (birth.birth_year == null || birth.birth_month == null) return null;
  const asOfMonths = asOf.getFullYear() * 12 + (asOf.getMonth() + 1);
  const birthMonths = birth.birth_year * 12 + birth.birth_month;
  return asOfMonths - birthMonths;
}

/** Whole years, or null when unknown. */
export function ageInYears(birth: BirthInfo, asOf: Date = new Date()): number | null {
  const months = ageInMonths(birth, asOf);
  if (months == null) return null;
  return Math.floor(months / 12);
}

/**
 * Display age. Under two years, months are more informative than "0".
 * Returns "—" rather than guessing when the birthday is not on file.
 */
export function formatAge(birth: BirthInfo, asOf: Date = new Date()): string {
  const months = ageInMonths(birth, asOf);
  if (months == null) return "—";
  if (months < 0) return "—";
  if (months < 24) return `${months} mo`;
  return `${Math.floor(months / 12)} yr`;
}

/**
 * Suggested age band. The DATABASE owns the real boundaries (they are
 * configurable per branch and guaranteed non-overlapping), so this is a
 * display hint only — never use it to decide a classroom.
 */
export function suggestAgeBand(birth: BirthInfo, asOf: Date = new Date()): AgeBandCode {
  const months = ageInMonths(birth, asOf);
  if (months == null || months < 0) return "unknown";
  if (months < 36) return "nursery";
  if (months < 60) return "preschool";
  if (months < 132) return "elementary";
  if (months < 156) return "preteen";
  if (months < 216) return "youth";
  return "adult";
}

/**
 * Adult age bracket for reporting.
 *
 * The source spec required this be maintained by hand, because it forbade
 * storing a birth year. ALIC chose to store the year instead, so it is derived
 * here and cannot drift out of date the way a hand-maintained field would.
 * Brackets are non-overlapping, as the spec asked.
 */
export function adultAgeGroup(birth: BirthInfo, asOf: Date = new Date()): AdultAgeGroup {
  const years = ageInYears(birth, asOf);
  if (years == null || years < 0) return "unknown";
  if (years < 20) return "under_20";
  if (years < 30) return "20_29";
  if (years < 40) return "30_39";
  if (years < 50) return "40_49";
  if (years < 60) return "50_59";
  if (years < 70) return "60_69";
  return "70_plus";
}

/** "March 1985", "March" when the year is missing, "—" when nothing is known. */
export function formatBirthday(birth: BirthInfo): string {
  if (birth.birth_month != null && birth.birth_month >= 1 && birth.birth_month <= 12) {
    const monthName = MONTH_NAMES[birth.birth_month - 1];
    return birth.birth_year != null ? `${monthName} ${birth.birth_year}` : monthName;
  }
  return birth.birth_year != null ? String(birth.birth_year) : "—";
}

/**
 * Years since accepting the Lord (spec BO-05 / MEM-005), calculated rather
 * than stored, so it is correct on the date the report runs.
 */
export function yearsSinceAccepted(
  acceptedYear: number | null,
  acceptedMonth: number | null,
  asOf: Date = new Date()
): number | null {
  if (acceptedYear == null) return null;
  const months = ageInMonths(
    { birth_year: acceptedYear, birth_month: acceptedMonth ?? 1 },
    asOf
  );
  if (months == null || months < 0) return null;
  return Math.floor(months / 12);
}

/** Validation shared by the member form and the CSV importer. */
export function isValidBirthMonth(month: number | null | undefined): boolean {
  if (month == null) return true;
  return Number.isInteger(month) && month >= 1 && month <= 12;
}

export function isValidBirthYear(
  year: number | null | undefined,
  asOf: Date = new Date()
): boolean {
  if (year == null) return true;
  return Number.isInteger(year) && year >= 1900 && year <= asOf.getFullYear();
}
