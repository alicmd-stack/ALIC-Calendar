/**
 * Check-in state machine tests.
 *
 * The negative cases are the point: no path may reach a completed check-in
 * without a volunteer on shift, and a shared station must never carry one
 * family's data into the next family's screen.
 */

import { describe, it, expect } from "vitest";
import {
  reduce,
  initialContext,
  shouldAutoReset,
  showsFamilyData,
  type MachineContext,
  type HouseholdMatch,
} from "./checkInMachine";

const HOUSEHOLD: HouseholdMatch = {
  household_id: "hh-1",
  household_name: "Bekele Household",
  masked_phone: "•••-0101",
  children: [
    {
      child_person_id: "c1",
      child_display_name: "Noah B.",
      age_band_code: "elementary",
      already_checked_in: false,
      needs_staff: false,
    },
    {
      child_person_id: "c2",
      child_display_name: "Maya B.",
      age_band_code: "elementary",
      already_checked_in: true, // already in a room
      needs_staff: false,
    },
    {
      child_person_id: "c3",
      child_display_name: "Sara B.",
      age_band_code: "nursery",
      already_checked_in: false,
      needs_staff: true, // pickup restriction on file
    },
  ],
};

/** Drive the machine to a volunteer-on-shift idle state. */
function onShift(): MachineContext {
  let ctx = reduce(initialContext, {
    type: "STATION_SET",
    stationId: "st-1",
    stationName: "Kids Desk 1",
  });
  ctx = reduce(ctx, {
    type: "SHIFT_STARTED",
    volunteerName: "Marta Bekele",
    canOverride: false,
  });
  return ctx;
}

function toSelecting(): MachineContext {
  let ctx = onShift();
  ctx = reduce(ctx, { type: "QUERY_CHANGED", query: "0101" });
  ctx = reduce(ctx, { type: "HOUSEHOLD_SELECTED", household: HOUSEHOLD });
  return ctx;
}

describe("station setup and shift", () => {
  it("starts unconfigured", () => {
    expect(initialContext.state).toBe("unconfigured");
  });

  it("goes to locked once a station is chosen — not straight to idle", () => {
    const ctx = reduce(initialContext, {
      type: "STATION_SET",
      stationId: "st-1",
      stationName: "Kids Desk 1",
    });
    expect(ctx.state).toBe("locked");
    expect(ctx.volunteerName).toBeNull();
  });

  it("reaches idle only after a volunteer signs in", () => {
    const ctx = onShift();
    expect(ctx.state).toBe("idle");
    expect(ctx.volunteerName).toBe("Marta Bekele");
  });

  it("returns to locked when the shift ends, never to idle", () => {
    const ctx = reduce(onShift(), { type: "SHIFT_ENDED" });
    expect(ctx.state).toBe("locked");
    expect(ctx.volunteerName).toBeNull();
  });
});

describe("no check-in without a volunteer", () => {
  it("ignores a household selection while locked", () => {
    const locked = reduce(initialContext, {
      type: "STATION_SET",
      stationId: "st-1",
      stationName: "Desk",
    });
    const ctx = reduce(locked, { type: "HOUSEHOLD_SELECTED", household: HOUSEHOLD });
    expect(ctx.state).toBe("locked");
    expect(ctx.household).toBeNull();
  });

  it("ignores a search while locked", () => {
    const locked = reduce(initialContext, {
      type: "STATION_SET",
      stationId: "st-1",
      stationName: "Desk",
    });
    const ctx = reduce(locked, { type: "QUERY_CHANGED", query: "0101" });
    expect(ctx.state).toBe("locked");
  });

  it("cannot reach success directly from idle", () => {
    const ctx = reduce(onShift(), {
      type: "CHECKED_IN",
      code: "ABC123",
      token: "tok",
      children: [],
    });
    expect(ctx.state).toBe("idle");
    expect(ctx.pickupCode).toBeNull();
  });
});

describe("child selection", () => {
  it("pre-selects only children who can actually be checked in", () => {
    const ctx = toSelecting();
    expect(ctx.state).toBe("selecting");
    // c2 is already checked in, c3 needs staff — neither is pre-selected.
    expect(ctx.selectedChildIds).toEqual(["c1"]);
  });

  it("refuses to select a child who is already checked in", () => {
    const ctx = reduce(toSelecting(), { type: "CHILD_TOGGLED", childId: "c2" });
    expect(ctx.selectedChildIds).not.toContain("c2");
  });

  it("refuses to select a child flagged for staff attention", () => {
    const ctx = reduce(toSelecting(), { type: "CHILD_TOGGLED", childId: "c3" });
    expect(ctx.selectedChildIds).not.toContain("c3");
  });

  it("toggles a selectable child off and on", () => {
    let ctx = reduce(toSelecting(), { type: "CHILD_TOGGLED", childId: "c1" });
    expect(ctx.selectedChildIds).toEqual([]);
    ctx = reduce(ctx, { type: "CHILD_TOGGLED", childId: "c1" });
    expect(ctx.selectedChildIds).toEqual(["c1"]);
  });

  it("will not confirm with nothing selected", () => {
    let ctx = reduce(toSelecting(), { type: "CHILD_TOGGLED", childId: "c1" });
    ctx = reduce(ctx, { type: "CONFIRM_REQUESTED" });
    expect(ctx.state).toBe("selecting");
  });

  it("confirms when at least one child is selected", () => {
    const ctx = reduce(toSelecting(), { type: "CONFIRM_REQUESTED" });
    expect(ctx.state).toBe("confirming");
  });
});

describe("check-in completion", () => {
  it("reaches success only from confirming", () => {
    let ctx = reduce(toSelecting(), { type: "CONFIRM_REQUESTED" });
    ctx = reduce(ctx, {
      type: "CHECKED_IN",
      code: "3R6F4T",
      token: "tok",
      children: [
        {
          check_in_id: "ci1",
          child_name: "Noah Bekele",
          room_name: "Blossom A",
          tag_number: 1000,
          allergy_label: null,
          has_restriction: false,
        },
      ],
    });
    expect(ctx.state).toBe("success");
    expect(ctx.pickupCode).toBe("3R6F4T");
    expect(ctx.checkedIn).toHaveLength(1);
  });
});

describe("privacy between families", () => {
  it("clears the previous family completely on reset", () => {
    let ctx = reduce(toSelecting(), { type: "CONFIRM_REQUESTED" });
    ctx = reduce(ctx, {
      type: "CHECKED_IN",
      code: "3R6F4T",
      token: "tok",
      children: [
        {
          check_in_id: "ci1",
          child_name: "Noah Bekele",
          room_name: "Blossom A",
          tag_number: 1000,
          allergy_label: "PEANUT",
          has_restriction: false,
        },
      ],
    });
    ctx = reduce(ctx, { type: "RESET" });

    expect(ctx.state).toBe("idle");
    expect(ctx.household).toBeNull();
    expect(ctx.selectedChildIds).toEqual([]);
    expect(ctx.pickupCode).toBeNull();
    expect(ctx.pickupToken).toBeNull();
    expect(ctx.checkedIn).toEqual([]);
    expect(ctx.query).toBe("");
    // The volunteer stays on shift across families.
    expect(ctx.volunteerName).toBe("Marta Bekele");
  });

  it("clears family data when the shift ends", () => {
    const ctx = reduce(toSelecting(), { type: "SHIFT_ENDED" });
    expect(ctx.household).toBeNull();
    expect(ctx.selectedChildIds).toEqual([]);
  });

  it("reset while locked stays locked rather than becoming idle", () => {
    let ctx = reduce(onShift(), { type: "SHIFT_ENDED" });
    ctx = reduce(ctx, { type: "RESET" });
    expect(ctx.state).toBe("locked");
  });
});

describe("checkout", () => {
  it("treats an unrecognised code as a denial, not a state change", () => {
    let ctx = reduce(onShift(), { type: "CHECKOUT_STARTED" });
    ctx = reduce(ctx, { type: "CHECKOUT_INPUT", value: "ZZZZZZ" });
    ctx = reduce(ctx, { type: "CHECKOUT_RESOLVED", matches: [] });
    expect(ctx.state).toBe("checkout_find");
    expect(ctx.error).toBeTruthy();
  });

  it("advances when a code resolves", () => {
    let ctx = reduce(onShift(), { type: "CHECKOUT_STARTED" });
    ctx = reduce(ctx, { type: "CHECKOUT_INPUT", value: "3R6F4T" });
    ctx = reduce(ctx, {
      type: "CHECKOUT_RESOLVED",
      matches: [
        {
          check_in_id: "ci1",
          child_name: "Noah Bekele",
          room_name: "Blossom A",
          tag_number: 1000,
          allergy_label: null,
          has_restriction: false,
        },
      ],
    });
    expect(ctx.state).toBe("checkout_confirm");
    expect(ctx.checkoutMatches).toHaveLength(1);
  });

  it("cannot start checkout unless a volunteer is on shift", () => {
    const locked = reduce(initialContext, {
      type: "STATION_SET",
      stationId: "st-1",
      stationName: "Desk",
    });
    expect(reduce(locked, { type: "CHECKOUT_STARTED" }).state).toBe("locked");
  });
});

describe("screen helpers", () => {
  it("marks the screens that must auto-return to idle", () => {
    expect(shouldAutoReset("success")).toBe(true);
    expect(shouldAutoReset("checkout_done")).toBe(true);
    expect(shouldAutoReset("idle")).toBe(false);
    expect(shouldAutoReset("locked")).toBe(false);
  });

  it("marks the screens that display family data", () => {
    // Used to decide when the idle timeout must be aggressive.
    expect(showsFamilyData("selecting")).toBe(true);
    expect(showsFamilyData("success")).toBe(true);
    expect(showsFamilyData("idle")).toBe(false);
    expect(showsFamilyData("locked")).toBe(false);
  });
});
