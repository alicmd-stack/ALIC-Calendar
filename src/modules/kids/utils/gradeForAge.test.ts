import { describe, it, expect } from "vitest";
import {
  schoolYearAge,
  suggestedGradeSortOrder,
  suggestGrade,
  type GradeOption,
} from "./gradeForAge";

/** ALIC's ten rooms, in the order church.school_grades sorts them. */
const ROOMS: GradeOption[] = [
  { school_grade_id: "prek", grade_name: "Pre-K", sort_order: 10 },
  { school_grade_id: "k", grade_name: "Kindergarten", sort_order: 20 },
  { school_grade_id: "g1", grade_name: "Grade 1", sort_order: 30 },
  { school_grade_id: "g2", grade_name: "Grade 2", sort_order: 40 },
  { school_grade_id: "g3", grade_name: "Grade 3", sort_order: 50 },
  { school_grade_id: "g4", grade_name: "Grade 4", sort_order: 60 },
  { school_grade_id: "g5", grade_name: "Grade 5", sort_order: 70 },
  { school_grade_id: "g6", grade_name: "Grade 6", sort_order: 80 },
  { school_grade_id: "g7", grade_name: "Grade 7", sort_order: 90 },
  { school_grade_id: "g8", grade_name: "Grade 8", sort_order: 100 },
];

const AUG = new Date(2026, 7, 21); // 21 Aug 2026 — new school year
const MAY = new Date(2026, 4, 10); // 10 May 2026 — old school year

describe("schoolYearAge", () => {
  it("counts the age a child turns during the school year", () => {
    expect(schoolYearAge(2021, AUG)).toBe(5);
  });

  it("does not roll over until August", () => {
    // Same child, three months earlier, is still in the previous school year.
    expect(schoolYearAge(2021, MAY)).toBe(4);
  });
});

describe("suggestedGradeSortOrder", () => {
  it("maps the US convention: 5 in Kindergarten, 13 in Grade 8", () => {
    expect(suggestedGradeSortOrder(2021, AUG)).toBe(20); // age 5  -> Kindergarten
    expect(suggestedGradeSortOrder(2013, AUG)).toBe(100); // age 13 -> Grade 8
  });

  it("puts a four-year-old in Pre-K", () => {
    expect(suggestedGradeSortOrder(2022, AUG)).toBe(10);
  });

  it("offers nothing for an age that wants a human", () => {
    expect(suggestedGradeSortOrder(2025, AUG)).toBeNull(); // toddler
    expect(suggestedGradeSortOrder(2000, AUG)).toBeNull(); // adult
    expect(suggestedGradeSortOrder(null, AUG)).toBeNull();
    expect(suggestedGradeSortOrder(undefined, AUG)).toBeNull();
    expect(suggestedGradeSortOrder(NaN, AUG)).toBeNull();
  });
});

describe("suggestGrade", () => {
  it("preselects the matching classroom", () => {
    expect(suggestGrade(2018, ROOMS, AUG)?.grade_name).toBe("Grade 3");
  });

  it("never silently drops an older child into the youngest room", () => {
    // A Grade 10 visitor at a church whose rooms stop at Grade 8. Falling back
    // to "nothing" sent them to the emptiest room in the building, which is how
    // a fifteen-year-old ends up sitting with the four-year-olds.
    expect(suggestGrade(2010, ROOMS, AUG)?.grade_name).toBe("Grade 8");
  });

  it("returns null rather than guessing for a toddler", () => {
    // Nursery is a different conversation; the volunteer must choose.
    expect(suggestGrade(2025, ROOMS, AUG)).toBeNull();
  });

  it("copes with a church that offers no classrooms", () => {
    expect(suggestGrade(2018, [], AUG)).toBeNull();
  });

  it("is stable across the whole Pre-K to Grade 8 range", () => {
    const expected = [
      [2022, "Pre-K"], [2021, "Kindergarten"], [2020, "Grade 1"],
      [2019, "Grade 2"], [2018, "Grade 3"], [2017, "Grade 4"],
      [2016, "Grade 5"], [2015, "Grade 6"], [2014, "Grade 7"],
      [2013, "Grade 8"],
    ] as const;
    for (const [year, grade] of expected) {
      expect(suggestGrade(year, ROOMS, AUG)?.grade_name, `born ${year}`).toBe(grade);
    }
  });
});
