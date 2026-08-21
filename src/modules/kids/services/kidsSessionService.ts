/**
 * Kids sessions, classrooms and the live roster.
 *
 * These are ordinary table reads: the station account has SELECT on the
 * session/classroom layer (it needs to know which rooms accept children), but
 * not on anything that identifies a person.
 */

import { supabase } from "@/integrations/supabase/client";
import type { KidsSession, KidsCheckIn } from "../types";

const church = () => supabase.schema("church");

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
   * Idempotent: calling it twice returns the session already open rather than
   * creating a duplicate.
   */
  async openToday(
    organizationId: string,
    serviceLabel = "Sunday Service"
  ): Promise<{ session_id: string; service_label: string; was_created: boolean }> {
    const { data, error } = await church().rpc("open_todays_session", {
      _organization_id: organizationId,
      _service_label: serviceLabel,
    });
    if (error) throw error;
    const rows = (data ?? []) as unknown as {
      session_id: string;
      service_label: string;
      was_created: boolean;
    }[];
    if (rows.length === 0) throw new Error("Could not open a session");
    return rows[0];
  },

  async closeToday(organizationId: string): Promise<number> {
    const { data, error } = await church().rpc("close_todays_sessions", {
      _organization_id: organizationId,
    });
    if (error) throw error;
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
    if (error) throw error;
    return data ?? [];
  },

  async listRecent(organizationId: string, limit = 20): Promise<KidsSession[]> {
    const { data, error } = await church()
      .from("kids_sessions")
      .select("*")
      .eq("organization_id", organizationId)
      .order("session_date", { ascending: false })
      .limit(limit);
    if (error) throw error;
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
    if (roomsRes.error) throw roomsRes.error;
    if (countsRes.error) throw countsRes.error;

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
    if (namesRes.error) throw namesRes.error;
    if (configRes.error) throw configRes.error;

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
    if (error) throw error;
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
    if (error) throw error;
    return data ?? [];
  },
};
