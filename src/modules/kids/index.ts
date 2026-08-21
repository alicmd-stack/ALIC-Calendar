/**
 * Kids Ministry Module
 *
 * Secure Sunday check-in and check-out for children.
 *
 * The station runs as a full-screen kiosk on a shared tablet signed in as a
 * device account, so auth.uid() identifies the TABLET, never the volunteer.
 * Every mutating operation therefore goes through a SECURITY DEFINER RPC
 * carrying a PIN-verified shift token — the station account has no write
 * privilege on any kids table at all.
 */

export * from "./pages";
export * from "./hooks";
export * from "./services";
export * from "./types";
export * from "./utils";
