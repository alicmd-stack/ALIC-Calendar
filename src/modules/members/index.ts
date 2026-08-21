/**
 * Members Module
 *
 * The church directory and the people data everything else hangs off:
 * - People and households, with family relationships
 * - Ministry service assignments (against the shared budget.ministries list)
 * - Service interests, home cell / Bible study membership, training history
 *
 * Backed by the `church` schema. Birthdays are stored as year + month only;
 * no day of birth is collected anywhere in this module.
 */

export * from "./pages";
export * from "./components";
export * from "./hooks";
export * from "./services";
export * from "./types";
export * from "./utils";
