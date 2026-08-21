/**
 * Kids check-in station.
 *
 * Full-screen kiosk, deliberately NOT wrapped in DashboardLayout: no sidebar,
 * no nav, nowhere to wander while a queue of parents waits.
 *
 * SIMPLE MODEL: the volunteer is whoever is signed in. There is no shared
 * device account, no PIN and no shift token — signing in already identifies
 * them, so every check-in is attributed without extra ceremony. The database
 * enforces the same thing: resolve_actor() reads auth.uid() directly.
 *
 * One route with an internal state machine rather than nested routes, so the
 * browser Back button cannot drop a parent into a half-finished check-in.
 */

import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { Button } from "@/shared/components/ui/button";
import { Input } from "@/shared/components/ui/input";
import { Badge } from "@/shared/components/ui/badge";
import {
  Loader2,
  Search,
  ArrowLeft,
  Printer,
  CheckCircle2,
  AlertTriangle,
  ShieldAlert,
  WifiOff,
  Baby,
  Play,
  DoorOpen,
} from "lucide-react";
import { useAuth } from "@/shared/contexts/AuthContext";
import { useOrganization } from "@/shared/contexts/OrganizationContext";
import { useUserProfile } from "@/hooks/useUserProfile";
import { kidsStationService, kidsSessionService, printLabels, renderQrSvg } from "../services";
import { StationRoomsPanel } from "../components/StationRoomsPanel";
import { reduce, initialContext, showsFamilyData, type HouseholdMatch } from "../utils/checkInMachine";
import type { HouseholdSearchRow, KidsSession } from "../types";

const AUTO_RESET_MS = 20_000;
/** Wipe a family's details from a shared screen after this long with no input. */
const FAMILY_IDLE_MS = 45_000;

export default function CheckInStationPage() {
  const navigate = useNavigate();
  const { user } = useAuth();
  const { profile } = useUserProfile();
  const { currentOrganization } = useOrganization();
  const orgId = currentOrganization?.id;

  const [ctx, dispatch] = useReducer(reduce, initialContext);
  const [session, setSession] = useState<KidsSession | null>(null);
  const [results, setResults] = useState<HouseholdSearchRow[]>([]);
  const [busy, setBusy] = useState(false);
  const [starting, setStarting] = useState(false);
  const [startError, setStartError] = useState<string | null>(null);
  const [printNote, setPrintNote] = useState<string | null>(null);
  const [online, setOnline] = useState(navigator.onLine);
  // The classroom-volunteer view. Not part of the check-in state machine:
  // it is a side panel a volunteer steps into and back out of, and it must
  // not disturb a half-finished check-in behind it.
  const [showRooms, setShowRooms] = useState(false);
  const searchInput = useRef<HTMLInputElement>(null);
  const idleTimer = useRef<number | null>(null);

  /* ----------------------------------------------------------- connection */
  useEffect(() => {
    const on = () => setOnline(true);
    const off = () => setOnline(false);
    window.addEventListener("online", on);
    window.addEventListener("offline", off);
    return () => {
      window.removeEventListener("online", on);
      window.removeEventListener("offline", off);
    };
  }, []);

  /* --------------------------------------------------------------- start */
  // The signed-in user IS the volunteer, so the machine goes straight to a
  // working state as soon as a session is open.
  useEffect(() => {
    if (!orgId || !user) return;
    kidsSessionService
      .listOpen(orgId)
      .then((open) => {
        const s = open[0] ?? null;
        setSession(s);
        if (s) {
          dispatch({
            type: "SHIFT_STARTED",
            volunteerName: profile?.full_name || "Volunteer",
            canOverride: false,
          });
        }
      })
      .catch(() => setSession(null));
  }, [orgId, user, profile?.full_name]);

  const startToday = async () => {
    if (!orgId) return;
    setStarting(true);
    setStartError(null);
    try {
      const opened = await kidsSessionService.openToday(orgId);
      const open = await kidsSessionService.listOpen(orgId);
      setSession(open.find((s) => s.id === opened.session_id) ?? open[0] ?? null);
      dispatch({
        type: "SHIFT_STARTED",
        volunteerName: profile?.full_name || "Volunteer",
        canOverride: false,
      });
    } catch (err) {
      const raw = err instanceof Error ? err.message : String(err);
      setStartError(
        raw.includes("no_classrooms_configured")
          ? "No classrooms are set up yet. An admin needs to mark which rooms take children."
          : raw.includes("not_permitted")
            ? "You do not have permission to run check-in."
            : raw
      );
    } finally {
      setStarting(false);
    }
  };

  /* ------------------------------------------------------------ idle wipe */
  const resetIdle = useCallback(() => {
    if (idleTimer.current) window.clearTimeout(idleTimer.current);
    if (!showsFamilyData(ctx.state)) return;
    idleTimer.current = window.setTimeout(() => {
      dispatch({ type: "RESET" });
      setResults([]);
    }, FAMILY_IDLE_MS);
  }, [ctx.state]);

  useEffect(() => {
    resetIdle();
    return () => {
      if (idleTimer.current) window.clearTimeout(idleTimer.current);
    };
  }, [resetIdle]);

  useEffect(() => {
    if (ctx.state !== "success" && ctx.state !== "checkout_done") return;
    const t = window.setTimeout(() => {
      dispatch({ type: "RESET" });
      setResults([]);
      setPrintNote(null);
    }, AUTO_RESET_MS);
    return () => window.clearTimeout(t);
  }, [ctx.state]);

  useEffect(() => {
    if (ctx.state === "idle") searchInput.current?.focus();
  }, [ctx.state]);

  /* ------------------------------------------------------------- handlers */
  const runSearch = async (query: string) => {
    dispatch({ type: "QUERY_CHANGED", query });
    if (query.trim().length < 3 || !session) {
      setResults([]);
      return;
    }
    try {
      setResults(await kidsStationService.searchHouseholds(query.trim(), session.id));
    } catch {
      setResults([]);
    }
  };

  /** Search returns one row per child; the screen needs one card per family. */
  const households = useMemo<HouseholdMatch[]>(() => {
    const byId = new Map<string, HouseholdMatch>();
    for (const row of results) {
      if (!byId.has(row.household_id)) {
        byId.set(row.household_id, {
          household_id: row.household_id,
          household_name: row.household_name,
          masked_phone: row.masked_phone,
          children: [],
        });
      }
      byId.get(row.household_id)!.children.push({
        child_person_id: row.child_person_id,
        child_display_name: row.child_display_name,
        age_band_code: row.age_band_code,
        already_checked_in: row.already_checked_in,
        needs_staff: row.needs_staff,
      });
    }
    return [...byId.values()];
  }, [results]);

  const doCheckIn = async () => {
    if (!session || ctx.selectedChildIds.length === 0) return;
    setBusy(true);
    try {
      // Idempotency key: if the response is lost and the tablet retries, the
      // RPC returns the ORIGINAL batch with a rotated code rather than
      // checking the same children in twice.
      const batchKey = `${session.id}:${ctx.household?.household_id}:${[...ctx.selectedChildIds].sort().join(",")}`;
      const rows = await kidsStationService.checkIn({
        sessionId: session.id,
        childIds: ctx.selectedChildIds,
        clientBatchKey: batchKey,
      });
      if (rows.length === 0) {
        dispatch({ type: "ERROR", message: "Check-in did not complete. Try again." });
        return;
      }
      dispatch({
        type: "CHECKED_IN",
        code: rows[0].pickup_code,
        token: rows[0].pickup_token,
        children: rows.map((r) => ({
          check_in_id: r.check_in_id,
          child_name: r.child_name,
          room_name: r.room_name,
          tag_number: r.tag_number,
          allergy_label: r.allergy_label,
          has_restriction: r.has_restriction,
        })),
      });
      // Print only AFTER the database has committed. A printed label with no
      // database row is the worst possible outcome.
      void doPrint(rows[0].pickup_code, rows[0].pickup_token, rows);
    } catch (err) {
      dispatch({
        type: "ERROR",
        message: err instanceof Error ? err.message : "Check-in failed",
      });
    } finally {
      setBusy(false);
    }
  };

  const doPrint = async (
    code: string,
    token: string,
    rows: { child_name: string; room_name: string | null; tag_number: number; allergy_label: string | null }[]
  ) => {
    const qr = await renderQrSvg(token);
    const dateLabel = session
      ? new Date(session.session_date).toLocaleDateString("en-US", {
          month: "short",
          day: "numeric",
        })
      : "";
    const result = await printLabels(
      rows.map((r) => ({
        childName: r.child_name,
        roomName: r.room_name,
        tagNumber: r.tag_number,
        allergyLabel: r.allergy_label,
        serviceLabel: session?.service_label ?? "",
        sessionDate: dateLabel,
      })),
      {
        householdName: ctx.household?.household_name ?? "",
        childCount: rows.length,
        pickupCode: code,
        qrSvg: qr,
        serviceLabel: session?.service_label ?? "",
        sessionDate: dateLabel,
      }
    );
    setPrintNote(
      result.submitted ? null : "Printer did not respond — write the code on a paper ticket."
    );
  };

  const doCheckoutLookup = async () => {
    if (!session || !ctx.checkoutInput.trim()) return;
    setBusy(true);
    try {
      const matches = await kidsStationService.resolvePickup(
        session.id,
        ctx.checkoutInput.trim()
      );
      dispatch({
        type: "CHECKOUT_RESOLVED",
        matches: matches
          .filter((m) => m.status === "checked_in")
          .map((m) => ({
            check_in_id: m.check_in_id,
            child_name: m.child_name,
            room_name: m.room_name,
            tag_number: m.tag_number,
            allergy_label: null,
            has_restriction: m.has_restriction,
          })),
      });
    } catch {
      dispatch({ type: "ERROR", message: "That code was not recognised." });
    } finally {
      setBusy(false);
    }
  };

  const doCheckout = async () => {
    if (ctx.checkoutMatches.length === 0) return;
    setBusy(true);
    try {
      const released = await kidsStationService.checkOut({
        checkInIds: ctx.checkoutMatches.map((m) => m.check_in_id),
        presented: ctx.checkoutInput.trim(),
      });
      if (released.length === 0) {
        dispatch({
          type: "ERROR",
          message: "Not released. Please get the Kids Ministry lead.",
        });
        return;
      }
      dispatch({ type: "CHECKOUT_DONE" });
    } catch {
      dispatch({ type: "ERROR", message: "Not released. Please get the Kids lead." });
    } finally {
      setBusy(false);
    }
  };

  /* ------------------------------------------------------------- rendering */
  return (
    <div
      className="fixed inset-0 bg-background flex flex-col overflow-hidden"
      onPointerDown={resetIdle}
      onKeyDown={resetIdle}
    >
      <header className="flex items-center justify-between px-6 py-3 border-b shrink-0">
        <div className="flex items-center gap-3">
          <Baby className="h-6 w-6 text-primary" />
          <div>
            <p className="font-semibold leading-tight">ALIC Kids Check-In</p>
            <p className="text-xs text-muted-foreground">
              {session ? session.service_label : "Not started"}
              {profile?.full_name ? ` · ${profile.full_name}` : ""}
            </p>
          </div>
        </div>
        <div className="flex items-center gap-3">
          {!online && (
            <Badge variant="destructive" className="gap-1">
              <WifiOff className="h-3 w-3" />
              OFFLINE
            </Badge>
          )}
          <Button variant="ghost" size="sm" onClick={() => navigate("/members")}>
            <ArrowLeft className="h-4 w-4 mr-1" />
            Exit
          </Button>
        </div>
      </header>

      {!online && (
        <div className="bg-destructive text-destructive-foreground px-6 py-2 text-sm font-medium shrink-0">
          No connection. Check-in is unavailable — use the paper backup sheet.
        </div>
      )}

      <main className="flex-1 overflow-y-auto p-6">
        {/* ------------------------------------------------- not started yet */}
        {!session && (
          <Centered title="Start check-in">
            <p className="text-muted-foreground max-w-md">
              Opens today’s session and makes every kids classroom available.
              You can start it again later without creating a duplicate.
            </p>
            {startError && (
              <p className="text-destructive text-sm mt-4 max-w-md">{startError}</p>
            )}
            <Button size="lg" className="h-16 px-10 text-lg mt-6" onClick={startToday} disabled={starting}>
              {starting ? (
                <Loader2 className="h-5 w-5 mr-2 animate-spin" />
              ) : (
                <Play className="h-5 w-5 mr-2" />
              )}
              Start check-in for today
            </Button>
          </Centered>
        )}

        {/* --------------------------------------------------------- lookup */}
        {session && !showRooms && (ctx.state === "idle" || ctx.state === "searching") && (
          <div className="max-w-3xl mx-auto">
            <div className="relative">
              <Search className="absolute left-4 top-1/2 -translate-y-1/2 h-6 w-6 text-muted-foreground" />
              <Input
                ref={searchInput}
                className="pl-14 h-16 text-xl"
                placeholder="Phone number or family name"
                value={ctx.query}
                disabled={!online}
                onChange={(e) => runSearch(e.target.value)}
              />
            </div>

            <div className="mt-4 space-y-2">
              {households.map((h) => (
                <button
                  key={h.household_id}
                  className="w-full text-left rounded-lg border p-4 hover:bg-muted/50"
                  onClick={() => dispatch({ type: "HOUSEHOLD_SELECTED", household: h })}
                >
                  <div className="flex items-center justify-between">
                    <span className="text-lg font-medium">{h.household_name}</span>
                    <span className="text-sm text-muted-foreground">{h.masked_phone}</span>
                  </div>
                  <p className="text-sm text-muted-foreground mt-1">
                    {h.children.length} {h.children.length === 1 ? "child" : "children"}
                  </p>
                </button>
              ))}
              {ctx.state === "searching" && households.length === 0 && (
                <p className="text-center text-muted-foreground py-8">
                  No family found. Check the number, or try their name.
                </p>
              )}
            </div>

            <div className="mt-8 flex justify-center gap-3">
              <Button
                variant="outline"
                size="lg"
                disabled={!online}
                onClick={() => dispatch({ type: "CHECKOUT_STARTED" })}
              >
                Check out a child
              </Button>
              <Button
                variant="outline"
                size="lg"
                disabled={!online}
                onClick={() => setShowRooms(true)}
              >
                <DoorOpen className="h-4 w-4 mr-1" />
                My room
              </Button>
            </div>
          </div>
        )}

        {/* ------------------------------------------- classroom volunteer */}
        {session && showRooms && (
          <StationRoomsPanel
            sessionId={session.id}
            online={online}
            onExit={() => setShowRooms(false)}
          />
        )}

        {/* ------------------------------------------------ select children */}
        {(ctx.state === "selecting" || ctx.state === "confirming") && ctx.household && (
          <div className="max-w-3xl mx-auto">
            <h2 className="text-2xl font-semibold">{ctx.household.household_name}</h2>
            <p className="text-muted-foreground text-sm mt-1">
              Tap a child to include or exclude them.
            </p>

            <div className="mt-5 grid gap-3 sm:grid-cols-2">
              {ctx.household.children.map((c) => {
                const selected = ctx.selectedChildIds.includes(c.child_person_id);
                const blocked = c.already_checked_in || c.needs_staff;
                return (
                  <button
                    key={c.child_person_id}
                    disabled={blocked}
                    onClick={() => dispatch({ type: "CHILD_TOGGLED", childId: c.child_person_id })}
                    className={`rounded-lg border p-4 text-left transition ${
                      blocked
                        ? "opacity-60 cursor-not-allowed"
                        : selected
                          ? "border-primary bg-primary/5"
                          : ""
                    }`}
                  >
                    <div className="flex items-center justify-between">
                      <span className="text-lg font-medium">{c.child_display_name}</span>
                      {selected && !blocked && <CheckCircle2 className="h-5 w-5 text-primary" />}
                    </div>
                    <div className="mt-1 flex flex-wrap gap-1.5">
                      {c.age_band_code && (
                        <Badge variant="outline" className="capitalize">
                          {c.age_band_code}
                        </Badge>
                      )}
                      {c.already_checked_in && <Badge variant="secondary">Already checked in</Badge>}
                      {/* Signalled, never explained — a queue of parents can
                          see this screen. */}
                      {c.needs_staff && (
                        <Badge variant="destructive" className="gap-1">
                          <ShieldAlert className="h-3 w-3" />
                          See a volunteer
                        </Badge>
                      )}
                    </div>
                  </button>
                );
              })}
            </div>

            {ctx.error && <p className="mt-4 text-sm text-destructive text-center">{ctx.error}</p>}

            <div className="mt-8 flex gap-3">
              <Button
                variant="outline"
                size="lg"
                className="flex-1"
                onClick={() => {
                  dispatch({ type: "RESET" });
                  setResults([]);
                }}
              >
                Cancel
              </Button>
              <Button
                size="lg"
                className="flex-[2] h-16 text-lg"
                disabled={ctx.selectedChildIds.length === 0 || busy || !online}
                onClick={() => {
                  if (ctx.state === "selecting") {
                    dispatch({ type: "CONFIRM_REQUESTED" });
                    void doCheckIn();
                  }
                }}
              >
                {busy && <Loader2 className="h-5 w-5 mr-2 animate-spin" />}
                Check in {ctx.selectedChildIds.length}{" "}
                {ctx.selectedChildIds.length === 1 ? "child" : "children"}
              </Button>
            </div>
          </div>
        )}

        {/* -------------------------------------------------------- success */}
        {ctx.state === "success" && (
          <Centered title="Checked in">
            <p className="text-sm text-muted-foreground">Pickup code</p>
            {/* Always on screen, large: if the printer is dead the volunteer
                writes it on a paper ticket and keeps moving. */}
            <div className="text-6xl font-mono font-black tracking-[0.3em] my-4">
              {ctx.pickupCode}
            </div>

            <ul className="space-y-1 text-center">
              {ctx.checkedIn.map((c) => (
                <li key={c.check_in_id} className="text-lg">
                  {c.child_name}
                  <span className="text-muted-foreground"> · {c.room_name}</span>
                  {c.allergy_label && (
                    <Badge variant="destructive" className="ml-2">
                      {c.allergy_label}
                    </Badge>
                  )}
                </li>
              ))}
            </ul>

            {printNote && (
              <p className="mt-4 text-amber-700 flex items-center gap-2 text-sm">
                <AlertTriangle className="h-4 w-4" />
                {printNote}
              </p>
            )}

            <div className="flex gap-3 mt-8">
              <Button
                variant="outline"
                size="lg"
                onClick={() => {
                  if (ctx.pickupCode && ctx.pickupToken) {
                    void doPrint(
                      ctx.pickupCode,
                      ctx.pickupToken,
                      ctx.checkedIn.map((c) => ({
                        child_name: c.child_name,
                        room_name: c.room_name,
                        tag_number: c.tag_number,
                        allergy_label: c.allergy_label,
                      }))
                    );
                  }
                }}
              >
                <Printer className="h-4 w-4 mr-1" />
                Print again
              </Button>
              <Button
                size="lg"
                onClick={() => {
                  dispatch({ type: "RESET" });
                  setResults([]);
                  setPrintNote(null);
                }}
              >
                Next family
              </Button>
            </div>
          </Centered>
        )}

        {/* ------------------------------------------------------- checkout */}
        {ctx.state === "checkout_find" && (
          <Centered title="Scan or enter the pickup code">
            <Input
              autoFocus
              className="h-16 text-2xl text-center font-mono tracking-widest max-w-sm"
              placeholder="ABC-123"
              value={ctx.checkoutInput}
              onChange={(e) => dispatch({ type: "CHECKOUT_INPUT", value: e.target.value })}
              onKeyDown={(e) => {
                // A barcode scanner types the code then presses Enter, so one
                // field serves both scanning and typing by hand.
                if (e.key === "Enter") void doCheckoutLookup();
              }}
            />
            {ctx.error && <p className="mt-3 text-destructive text-sm">{ctx.error}</p>}
            <div className="flex gap-3 mt-6">
              <Button variant="outline" size="lg" onClick={() => dispatch({ type: "RESET" })}>
                Cancel
              </Button>
              <Button size="lg" onClick={doCheckoutLookup} disabled={busy}>
                {busy && <Loader2 className="h-4 w-4 mr-1 animate-spin" />}
                Find
              </Button>
            </div>
          </Centered>
        )}

        {ctx.state === "checkout_confirm" && (
          <Centered title="Release these children?">
            <ul className="space-y-2 my-4">
              {ctx.checkoutMatches.map((m) => (
                <li key={m.check_in_id} className="text-xl">
                  {m.child_name}
                  <span className="text-muted-foreground"> · {m.room_name}</span>
                </li>
              ))}
            </ul>
            {ctx.error && <p className="text-destructive text-sm">{ctx.error}</p>}
            <div className="flex gap-3 mt-6">
              <Button variant="outline" size="lg" onClick={() => dispatch({ type: "RESET" })}>
                Cancel
              </Button>
              <Button size="lg" onClick={doCheckout} disabled={busy}>
                {busy && <Loader2 className="h-4 w-4 mr-1 animate-spin" />}
                Release
              </Button>
            </div>
          </Centered>
        )}

        {ctx.state === "checkout_done" && (
          <Centered title="Released">
            <CheckCircle2 className="h-16 w-16 text-green-600" />
            <Button size="lg" className="mt-6" onClick={() => dispatch({ type: "RESET" })}>
              Done
            </Button>
          </Centered>
        )}
      </main>
    </div>
  );
}

function Centered({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="h-full flex flex-col items-center justify-center text-center">
      <h2 className="text-2xl font-semibold mb-4">{title}</h2>
      {children}
    </div>
  );
}
