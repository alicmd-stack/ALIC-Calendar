/**
 * The permission list an admin can actually tick must cover every permission
 * the system defines.
 *
 * This exists because it did not hold. church.module_permission gained
 * 'kids_leader' in 20260321001000 and MINISTRY_ROLES gained it too, but the
 * tickbox grid in ModuleGrantsPanel was never updated. The grid is built by
 * mapping over PERMISSIONS, so for as long as the value was missing there:
 *
 *   - no admin could appoint a new Kids team lead through the UI at all; the
 *     four who held it did so only because 20260321001300 wrote the rows, and
 *   - the badge on the people list fell through to its `?? p` default and
 *     showed the raw string "kids_leader".
 *
 * Nothing failed loudly. A permission simply became unreachable, which is the
 * kind of gap that survives until someone tries to appoint the fifth lead.
 */

import { describe, it, expect } from "vitest";
import { MINISTRY_ROLES } from "./capabilities";
import { PERMISSIONS } from "@/modules/members/components/ModuleGrantsPanel";

describe("module grant coverage", () => {
  const offered = PERMISSIONS.map((p) => p.value);

  it("offers every ministry role", () => {
    expect([...offered].sort()).toEqual([...MINISTRY_ROLES].sort());
  });

  it("offers no role the capability model does not know", () => {
    for (const value of offered) {
      expect(MINISTRY_ROLES).toContain(value);
    }
  });

  it("gives every offered role a human label and a description", () => {
    for (const p of PERMISSIONS) {
      expect(p.label.trim()).not.toBe("");
      expect(p.description.trim()).not.toBe("");
      // The label is what the badge renders; leaving it as the raw enum value
      // is the failure this file was written for.
      expect(p.label).not.toBe(p.value);
    }
  });

  it("lists each role exactly once", () => {
    expect(new Set(offered).size).toBe(offered.length);
  });
});
