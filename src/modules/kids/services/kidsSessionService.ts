/**
 * Kids sessions, classrooms and the live roster.
 *
 * These are ordinary table reads: the station account has SELECT on the
 * session/classroom layer (it needs to know which rooms accept children), but
 * not on anything that identifies a person.
 */

import { supabase } from "@/integrations/supabase/client";
import { throwRpc } from "./rpcError";
import type { KidsSession, KidsCheckIn } from "../types";

const church = () => supabase.schema("church");

export interface OpenSessionResult {
  session_id: string;
  service_label: string;
  was_created: boolean;
  /** Classrooms this call added to the session, or brought back after a retire. */
  rooms_attached: number;
  /** Rooms dropped because they are no longer classrooms. Never one holding a child. */
  rooms_closed: number;
}

export interface OpenSessionRoom {
  room_id: string;
  room_name: string;
  label_room_name: string | null;
  capacity: number | null;
  age_band_code: string | null;
  current_count: number;
}

export const kidsSessionService = {
  /**
   * Open today's session, attaching every configured classroom.
   *
   * The scheduler already does this every Sunday morning, so in normal use this
   * is a manual override: a second service, a midweek programme, or a leader
   * who has just changed the classrooms and wants the board to catch up.
   *
   * Idempotent, and it reconciles either way. Calling it on a session that is
   * already open returns that session with was_created false, having brought
   * its room list back in line with the configured classrooms — which is the
   * point of pressing it twice.
   *
   * Omitting serviceLabel uses the label configured on the event, so the button
   * and the scheduler converge on one session rather than two.
   */
  async openToday(
    organizationId: string,
    serviceLabel?: string
  ): Promise<OpenSessionResult> {
    const { data, error } = await church().rpc("open_todays_session", {
      _organization_id: organizationId,
      _service_label: serviceLabel ?? null,
    });
    throwRpc(error);
    const rows = (data ?? []) as unknown as OpenSessionResult[];
    if (rows.length === 0) throw new Error("Could not open a session");
    return rows[0];
  },

  async closeToday(organizationId: string): Promise<number> {
    const { data, error } = await church().rpc("close_todays_sessions", {
      _organization_id: organizationId,
    });
    throwRpc(error);
    return (data as unknown as number) ?? 0;
  },

  /** Sessions currently accepting check-ins. */
  async listOpen(organizationId: string): Promise<KidsSession[]> {
    const { data, error } = await church()
      .from("kids_sessions")
      .select("*")
      .eq("organization_id", organizationId)
      .eq("status", "open")
      .order("starts_at");
    throwRpc(error);
    return data ?? [];
  },

  /**
   * The session the desk should be working with, open or not.
   *
   * listOpen filters on status='open', and the station gated every panel on the
   * result — so the moment kids_auto_close_sessions ran, the desk lost checkout,
   * the roster, the safety card and the parent-message button, with children
   * still in the rooms. That is precisely the end of the service, which is the
   * one moment all of those matter.
   *
   * The database was never the problem: kids_auto_close_sessions says so in its
   * own comment — "Only check-in requires an open session; checkout works on a
   * closed one." check_out_children never reads session status.
   *
   * Prefers an open session, falls back to the most recent one from today.
   */
  async currentForDesk(organizationId: string): Promise<KidsSession | null> {
    const open = await this.listOpen(organizationId);
    if (open.length > 0) return open[0];

    const today = new Date();
    const iso = [
      today.getFullYear(),
      String(today.getMonth() + 1).padStart(2, "0"),
      String(today.getDate()).padStart(2, "0"),
    ].join("-");

    const { data, error } = await church()
      .from("kids_sessions")
      .select("*")
      .eq("organization_id", organizationId)
      .eq("session_date", iso)
      .order("opened_at", { ascending: false })
      .limit(1);
    throwRpc(error);
    return data?.[0] ?? null;
  },

  async listRecent(organizationId: string, limit = 20): Promise<KidsSession[]> {
    const { data, error } = await church()
      .from("kids_sessions")
      .select("*")
      .eq("organization_id", organizationId)
      .order("session_date", { ascending: false })
      .limit(limit);
    throwRpc(error);
    return data ?? [];
  },

  /** Rooms open for a session, with live occupancy. */
  async listSessionRooms(sessionId: string): Promise<OpenSessionRoom[]> {
    const [roomsRes, countsRes] = await Promise.all([
      church()
        .from("kids_session_rooms")
        .select("room_id, capacity_override, is_open")
        .eq("kids_session_id", sessionId)
        .eq("is_open", true),
      church()
        .from("kids_check_ins")
        .select("room_id")
        .eq("kids_session_id", sessionId)
        .eq("status", "checked_in"),
    ]);
    throwRpc(roomsRes.error);
    throwRpc(countsRes.error);

    const roomIds = (roomsRes.data ?? []).map((r) => r.room_id);
    if (roomIds.length === 0) return [];

    // public.rooms and church.room_kids_config are in different schemas, so
    // they cannot be embedded in one PostgREST query.
    const [namesRes, configRes] = await Promise.all([
      supabase.from("rooms").select("id, name").in("id", roomIds),
      church()
        .from("room_kids_config")
        .select("room_id, label_room_name, capacity, kids_age_band_id")
        .in("room_id", roomIds),
    ]);
    throwRpc(namesRes.error);
    throwRpc(configRes.error);

    const nameById = new Map((namesRes.data ?? []).map((r) => [r.id, r.name]));
    const configById = new Map((configRes.data ?? []).map((c) => [c.room_id, c]));
    const counts = new Map<string, number>();
    for (const row of countsRes.data ?? []) {
      counts.set(row.room_id, (counts.get(row.room_id) ?? 0) + 1);
    }

    return (roomsRes.data ?? []).map((r) => {
      const cfg = configById.get(r.room_id);
      return {
        room_id: r.room_id,
        room_name: nameById.get(r.room_id) ?? "Room",
        label_room_name: cfg?.label_room_name ?? null,
        capacity: r.capacity_override ?? cfg?.capacity ?? null,
        age_band_code: null,
        current_count: counts.get(r.room_id) ?? 0,
      };
    });
  },

  /** Children currently in a room. Powers the live roster (KID-017). */
  async listActiveCheckIns(sessionId: string): Promise<KidsCheckIn[]> {
    const { data, error } = await church()
      .from("kids_check_ins")
      .select("*")
      .eq("kids_session_id", sessionId)
      .eq("status", "checked_in")
      .order("tag_number");
    throwRpc(error);
    return data ?? [];
  },

  /** The end-of-service screen: still checked in after the session ended. */
  async listNotCheckedOut(organizationId: string): Promise<KidsCheckIn[]> {
    const { data, error } = await church()
      .from("kids_check_ins")
      .select("*")
      .eq("organization_id", organizationId)
      .eq("status", "checked_in")
      .order("checked_in_at");
    throwRpc(error);
    return data ?? [];
  },
};
