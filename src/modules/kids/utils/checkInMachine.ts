/**
 * Check-in station state machine.
 *
 * A pure reducer, deliberately kept out of React so the whole Sunday-morning
 * flow can be tested without rendering anything. This is the part that must
 * not have holes: no path may reach "checked in" without a confirmed
 * volunteer, a session, a household and at least one child.
 *
 * The station is ONE route with an internal machine rather than nested routes,
 * because a kiosk must not have a working browser Back button — a parent
 * hitting Back mid-flow would otherwise land on a half-completed check-in.
 */

export type StationState =
  | "unconfigured"   // no station chosen on this device yet
  | "locked"         // station chosen, no volunteer signed in
  | "idle"           // volunteer on shift, waiting for the next family
  | "searching"      // looking up a household
  | "selecting"      // household found, choosing children
  | "confirming"     // reviewing classroom assignment before committing
  | "success"        // checked in, code on screen
  | "checkout_find"  // entering a pickup code
  | "checkout_confirm"
  | "checkout_done";

export interface HouseholdMatch {
  household_id: string;
  household_name: string;
  masked_phone: string | null;
  children: {
    child_person_id: string;
    child_display_name: string;
    age_band_code: string | null;
    already_checked_in: boolean;
    needs_staff: boolean;
  }[];
}

export interface CheckedInChild {
  check_in_id: string;
  child_name: string;
  room_name: string | null;
  tag_number: number;
  allergy_label: string | null;
  has_restriction: boolean;
}

export interface MachineContext {
  state: StationState;
  stationId: string | null;
  stationName: string | null;
  volunteerName: string | null;
  canOverride: boolean;
  query: string;
  household: HouseholdMatch | null;
  selectedChildIds: string[];
  /** Per-child room override, keyed by child person id. */
  roomOverrides: Record<string, string>;
  pickupCode: string | null;
  pickupToken: string | null;
  checkedIn: CheckedInChild[];
  checkoutInput: string;
  checkoutMatches: CheckedInChild[];
  error: string | null;
}

export const initialContext: MachineContext = {
  state: "unconfigured",
  stationId: null,
  stationName: null,
  volunteerName: null,
  canOverride: false,
  query: "",
  household: null,
  selectedChildIds: [],
  roomOverrides: {},
  pickupCode: null,
  pickupToken: null,
  checkedIn: [],
  checkoutInput: "",
  checkoutMatches: [],
  error: null,
};

export type MachineEvent =
  | { type: "STATION_SET"; stationId: string; stationName: string }
  | { type: "STATION_CLEARED" }
  | { type: "SHIFT_STARTED"; volunteerName: string; canOverride: boolean }
  | { type: "SHIFT_ENDED" }
  | { type: "QUERY_CHANGED"; query: string }
  | { type: "HOUSEHOLD_SELECTED"; household: HouseholdMatch }
  | { type: "CHILD_TOGGLED"; childId: string }
  | { type: "ROOM_OVERRIDDEN"; childId: string; roomId: string }
  | { type: "CONFIRM_REQUESTED" }
  | { type: "CHECKED_IN"; code: string; token: string; children: CheckedInChild[] }
  | { type: "CHECKOUT_STARTED" }
  | { type: "CHECKOUT_INPUT"; value: string }
  | { type: "CHECKOUT_RESOLVED"; matches: CheckedInChild[] }
  | { type: "CHECKOUT_DONE" }
  | { type: "ERROR"; message: string }
  | { type: "RESET" };

/**
 * Everything a family-specific screen holds is cleared on reset. This matters
 * on a shared station: the next parent must never see the previous family's
 * children or pickup code.
 */
function clearFamily(ctx: MachineContext): MachineContext {
  return {
    ...ctx,
    query: "",
    household: null,
    selectedChildIds: [],
    roomOverrides: {},
    pickupCode: null,
    pickupToken: null,
    checkedIn: [],
    checkoutInput: "",
    checkoutMatches: [],
    error: null,
  };
}

export function reduce(ctx: MachineContext, event: MachineEvent): MachineContext {
  switch (event.type) {
    case "STATION_SET":
      return {
        ...clearFamily(ctx),
        state: "locked",
        stationId: event.stationId,
        stationName: event.stationName,
        volunteerName: null,
        canOverride: false,
      };

    case "STATION_CLEARED":
      return { ...initialContext };

    case "SHIFT_STARTED":
      return {
        ...clearFamily(ctx),
        state: "idle",
        volunteerName: event.volunteerName,
        canOverride: event.canOverride,
      };

    case "SHIFT_ENDED":
      // Back to locked, never to idle: no volunteer means no check-ins.
      return {
        ...clearFamily(ctx),
        state: ctx.stationId ? "locked" : "unconfigured",
        volunteerName: null,
        canOverride: false,
      };

    case "QUERY_CHANGED":
      if (ctx.state !== "idle" && ctx.state !== "searching") return ctx;
      return {
        ...ctx,
        query: event.query,
        state: event.query.trim().length >= 3 ? "searching" : "idle",
        household: null,
        error: null,
      };

    case "HOUSEHOLD_SELECTED": {
      if (ctx.state !== "searching") return ctx;
      // Children already checked in are pre-excluded rather than merely
      // greyed out, so a double tap cannot resubmit them.
      const selectable = event.household.children
        .filter((c) => !c.already_checked_in && !c.needs_staff)
        .map((c) => c.child_person_id);
      return {
        ...ctx,
        state: "selecting",
        household: event.household,
        selectedChildIds: selectable,
        error: null,
      };
    }

    case "CHILD_TOGGLED": {
      if (ctx.state !== "selecting") return ctx;
      const child = ctx.household?.children.find(
        (c) => c.child_person_id === event.childId
      );
      // A child already checked in, or flagged for staff attention, is never
      // selectable from the ordinary flow.
      if (!child || child.already_checked_in || child.needs_staff) return ctx;
      const has = ctx.selectedChildIds.includes(event.childId);
      return {
        ...ctx,
        selectedChildIds: has
          ? ctx.selectedChildIds.filter((id) => id !== event.childId)
          : [...ctx.selectedChildIds, event.childId],
      };
    }

    case "ROOM_OVERRIDDEN":
      if (ctx.state !== "selecting" && ctx.state !== "confirming") return ctx;
      return {
        ...ctx,
        roomOverrides: { ...ctx.roomOverrides, [event.childId]: event.roomId },
      };

    case "CONFIRM_REQUESTED":
      if (ctx.state !== "selecting" || ctx.selectedChildIds.length === 0) return ctx;
      return { ...ctx, state: "confirming", error: null };

    case "CHECKED_IN":
      if (ctx.state !== "confirming") return ctx;
      return {
        ...ctx,
        state: "success",
        pickupCode: event.code,
        pickupToken: event.token,
        checkedIn: event.children,
        error: null,
      };

    case "CHECKOUT_STARTED":
      if (ctx.state !== "idle") return ctx;
      return { ...clearFamily(ctx), state: "checkout_find" };

    case "CHECKOUT_INPUT":
      if (ctx.state !== "checkout_find") return ctx;
      return { ...ctx, checkoutInput: event.value, error: null };

    case "CHECKOUT_RESOLVED":
      if (ctx.state !== "checkout_find") return ctx;
      // Zero matches is a denial, not a state change — the caller shows the
      // generic "not recognised" message and stays put.
      if (event.matches.length === 0) {
        return { ...ctx, error: "That code was not recognised." };
      }
      return { ...ctx, state: "checkout_confirm", checkoutMatches: event.matches };

    case "CHECKOUT_DONE":
      if (ctx.state !== "checkout_confirm") return ctx;
      return { ...ctx, state: "checkout_done" };

    case "ERROR":
      return { ...ctx, error: event.message };

    case "RESET":
      // Returns to idle only when a volunteer is still on shift.
      return {
        ...clearFamily(ctx),
        state: ctx.volunteerName ? "idle" : ctx.stationId ? "locked" : "unconfigured",
      };

    default:
      return ctx;
  }
}

/** Screens that must auto-return to idle after a period of no input. */
export function shouldAutoReset(state: StationState): boolean {
  return state === "success" || state === "checkout_done" || state === "selecting";
}

/** True when the current screen shows a family's details to the room. */
export function showsFamilyData(state: StationState): boolean {
  return (
    state === "selecting" ||
    state === "confirming" ||
    state === "success" ||
    state === "checkout_confirm"
  );
}
