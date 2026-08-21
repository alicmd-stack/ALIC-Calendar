/**
 * The Kids Ministry leader's view of a Sunday.
 *
 * Every call here goes through a SECURITY DEFINER RPC that checks for
 * kids_admin or leadership_viewer server-side. That is deliberate and is the
 * whole reason these are separate functions from the station's:
 *
 *   - The station (kidsStationService) sees last INITIAL only and a masked
 *     phone, so a photo of the lobby tablet leaks very little.
 *   - The leader sees full names and the guardian's phone, because the leader
 *     is the person who has to make the call.
 *
 * Keeping them apart means widening the leader's view can never widen the
 * tablet's. A kids_volunteer signed in at a desk gets `not_a_kids_leader`
 * from every function in this file.
 */

import { supabase } from "@/integrations/supabase/client";

const church = () => supabase.schema("church");

/** One classroom on the live board. */
export interface LiveBoardRoom {
  kids_session_id: string;
  session_label: string;
  session_date: string;
  room_id: string;
  room_name: string;
  label_room_name: string | null;
  age_band_code: string | null;
  age_band_name: string | null;
  capacity: number | null;
  ratio_children_per_volunteer: number | null;
  checked_in_count: number;
  checked_out_count: number;
  volunteer_count: number;
  allergy_count: number;
  restriction_count: number;
  over_capacity: boolean;
  over_ratio: boolean;
}

/** One child on a room roster, named. */
export interface RosterRow {
  check_in_id: string;
  child_person_id: string;
  child_name: string;
  tag_number: number;
  room_id: string | null;
  room_name: string | null;
  status: string;
  checked_in_at: string;
  checked_out_at: string | null;
  checked_in_by_name: string | null;
  checked_out_by_name: string | null;
  dropped_off_by_name: string | null;
  picked_up_by_name: string | null;
  guardian_phone: string | null;
  has_allergy: boolean;
  has_restriction: boolean;
  checkout_method: string | null;
  minutes_in_room: number;
}

export interface AttendanceRow {
  session_date: string;
  service_label: string | null;
  room_name: string;
  age_band_name: string | null;
  children: number;
  first_time_visitors: number;
  volunteers: number;
  overrides: number;
  not_checked_out: number;
  avg_minutes: number | null;
}

export interface ExceptionRow {
  occurred_at: string;
  session_date: string | null;
  action: string;
  outcome: string | null;
  child_name: string;
  room_name: string | null;
  actor_name: string | null;
  reason: string | null;
}

export interface EligibleVolunteer {
  person_id: string;
  volunteer_id: string | null;
  display_name: string;
  phone: string | null;
  background_check_status: string;
  background_check_expires_on: string | null;
  training_completed_on: string | null;
  is_active: boolean;
  can_override: boolean;
  is_eligible: boolean;
}

export interface StaffingRow {
  id: string;
  kids_session_id: string;
  room_id: string | null;
  person_id: string;
  role: string;
  started_at: string;
  ended_at: string | null;
  was_background_check_current: boolean | null;
}

export const kidsLeaderService = {
  /** Every open classroom, right now. Refetch this on a Realtime event. */
  async liveBoard(organizationId: string): Promise<LiveBoardRoom[]> {
    const { data, error } = await church().rpc("kids_live_board", {
      _organization_id: organizationId,
    });
    if (error) throw error;
    return (data ?? []) as unknown as LiveBoardRoom[];
  },

  /** Children in one room, or the whole session when roomId is null. */
  async roster(sessionId: string, roomId?: string | null): Promise<RosterRow[]> {
    const { data, error } = await church().rpc("kids_room_roster", {
      _kids_session_id: sessionId,
      _room_id: roomId ?? null,
    });
    if (error) throw error;
    return (data ?? []) as unknown as RosterRow[];
  },

  async attendance(
    organizationId: string,
    from: string,
    to: string
  ): Promise<AttendanceRow[]> {
    const { data, error } = await church().rpc("kids_attendance_report", {
      _organization_id: organizationId,
      _from: from,
      _to: to,
    });
    if (error) throw error;
    return (data ?? []) as unknown as AttendanceRow[];
  },

  async exceptions(
    organizationId: string,
    from: string,
    to: string
  ): Promise<ExceptionRow[]> {
    const { data, error } = await church().rpc("kids_exceptions_report", {
      _organization_id: organizationId,
      _from: from,
      _to: to,
    });
    if (error) throw error;
    return (data ?? []) as unknown as ExceptionRow[];
  },

  async eligibleVolunteers(organizationId: string): Promise<EligibleVolunteer[]> {
    const { data, error } = await church().rpc("kids_eligible_volunteers", {
      _organization_id: organizationId,
    });
    if (error) throw error;
    return (data ?? []) as unknown as EligibleVolunteer[];
  },

  /** Who is currently staffing a session, by room. */
  async sessionStaffing(sessionId: string): Promise<StaffingRow[]> {
    const { data, error } = await church()
      .from("kids_session_staffing")
      .select("*")
      .eq("kids_session_id", sessionId)
      .is("ended_at", null);
    if (error) throw error;
    return (data ?? []) as unknown as StaffingRow[];
  },

  async assignStaff(params: {
    sessionId: string;
    personId: string;
    roomId?: string | null;
    role?: string;
  }): Promise<StaffingRow> {
    const { data, error } = await church().rpc("assign_session_staff", {
      _kids_session_id: params.sessionId,
      _person_id: params.personId,
      _room_id: params.roomId ?? null,
      _role: params.role ?? "classroom_volunteer",
    });
    if (error) throw error;
    return data as unknown as StaffingRow;
  },

  async endStaff(staffingId: string): Promise<void> {
    const { error } = await church().rpc("end_session_staff", {
      _staffing_id: staffingId,
    });
    if (error) throw error;
  },

  /**
   * Replace migration 20260320001500's PROVISIONAL room/age guesses with the
   * ministry's real mapping, without another migration.
   */
  async setRoomConfig(params: {
    roomId: string;
    isCheckinLocation: boolean;
    ageBandId?: string | null;
    capacity?: number | null;
    ratio?: number | null;
    labelRoomName?: string | null;
    sortOrder?: number;
  }) {
    const { data, error } = await church().rpc("set_room_kids_config", {
      _room_id: params.roomId,
      _is_checkin_location: params.isCheckinLocation,
      _kids_age_band_id: params.ageBandId ?? null,
      _capacity: params.capacity ?? null,
      _ratio: params.ratio ?? null,
      _label_room_name: params.labelRoomName ?? null,
      _sort_order: params.sortOrder ?? 0,
    });
    if (error) throw error;
    return data;
  },

  /** Open a classroom mid-service (overflow), even if it opened after the session did. */
  async openRoom(
    sessionId: string,
    roomId: string,
    capacityOverride?: number | null
  ): Promise<void> {
    const { error } = await church().rpc("kids_open_room_in_session", {
      _kids_session_id: sessionId,
      _room_id: roomId,
      _capacity_override: capacityOverride ?? null,
    });
    if (error) throw error;
  },

  /** Refused server-side while children are still checked into the room. */
  async closeRoom(sessionId: string, roomId: string): Promise<void> {
    const { error } = await church().rpc("kids_close_room_in_session", {
      _kids_session_id: sessionId,
      _room_id: roomId,
    });
    if (error) throw error;
  },

  /** Classrooms configured for this branch, with their age band. */
  async listClassrooms(organizationId: string) {
    // church.room_kids_config and public.rooms are in different schemas, so
    // PostgREST cannot embed them in one query.
    const [cfgRes, roomsRes, bandsRes] = await Promise.all([
      church()
        .from("room_kids_config")
        .select("*")
        .eq("organization_id", organizationId)
        .order("sort_order"),
      supabase
        .from("rooms")
        .select("id, name, capacity, is_active")
        .eq("organization_id", organizationId)
        .eq("is_active", true)
        .order("name"),
      church()
        .from("kids_age_bands")
        .select("*")
        .eq("organization_id", organizationId)
        .eq("is_active", true)
        .order("min_age_months"),
    ]);
    if (cfgRes.error) throw cfgRes.error;
    if (roomsRes.error) throw roomsRes.error;
    if (bandsRes.error) throw bandsRes.error;

    const cfgByRoom = new Map((cfgRes.data ?? []).map((c) => [c.room_id, c]));

    // Every active room is listed, not only the configured ones: a room with
    // no config is exactly what the leader needs to find in order to add it.
    return {
      rooms: (roomsRes.data ?? []).map((room) => ({
        room_id: room.id,
        room_name: room.name,
        room_capacity: room.capacity,
        config: cfgByRoom.get(room.id) ?? null,
      })),
      ageBands: bandsRes.data ?? [],
    };
  },
};

export type ClassroomListing = Awaited<
  ReturnType<typeof kidsLeaderService.listClassrooms>
>;
export type ClassroomRow = ClassroomListing["rooms"][number];
export type AgeBand = ClassroomListing["ageBands"][number];
