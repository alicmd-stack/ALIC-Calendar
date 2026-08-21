/**
 * Station and shift operations.
 *
 * Everything goes through SECURITY DEFINER RPCs. The station account has no
 * write privilege on any kids table, so these functions are the only path —
 * which is what stops a shared tablet attributing an action to a volunteer
 * who did not perform it.
 */

import { supabase } from "@/integrations/supabase/client";
import type {
  CheckInStation,
  VolunteerOption,
  HouseholdSearchRow,
  CheckInResultRow,
  PickupMatchRow,
  StationRoom,
  StationRosterRow,
} from "../types";

const church = () => supabase.schema("church");

export const kidsStationService = {
  async listStations(organizationId: string): Promise<CheckInStation[]> {
    const { data, error } = await church()
      .from("check_in_stations")
      .select("*")
      .eq("organization_id", organizationId)
      .eq("is_active", true)
      .order("name");
    if (error) throw error;
    return data ?? [];
  },

  async listVolunteers(stationId: string): Promise<VolunteerOption[]> {
    const { data, error } = await church().rpc("station_list_volunteers", {
      _station_id: stationId,
    });
    if (error) throw error;
    return (data ?? []) as unknown as VolunteerOption[];
  },

  /**
   * Open a shift.
   *
   * Returns null when denied. The RPC returns ZERO ROWS rather than raising,
   * so that the failed-attempt counter it increments actually commits — a
   * RAISE would roll the counter back and the lockout would never engage.
   * Every failure mode looks identical from here on purpose.
   */
  async openShift(
    stationId: string,
    volunteerId: string,
    pin: string
  ): Promise<{ token: string; volunteerName: string; canOverride: boolean } | null> {
    const { data, error } = await church().rpc("station_open_shift", {
      _station_id: stationId,
      _volunteer_id: volunteerId,
      _pin: pin,
    });
    if (error) throw error;
    const rows = (data ?? []) as unknown as {
      shift_token: string;
      volunteer_name: string;
      can_override: boolean;
    }[];
    if (rows.length === 0) return null;
    return {
      token: rows[0].shift_token,
      volunteerName: rows[0].volunteer_name,
      canOverride: rows[0].can_override,
    };
  },

  async closeShift(token: string): Promise<void> {
    const { error } = await church().rpc("station_close_shift", {
      _shift_token: token,
    });
    if (error) throw error;
  },

  async searchHouseholds(
    query: string,
    sessionId: string,
    token?: string | null
  ): Promise<HouseholdSearchRow[]> {
    const { data, error } = await church().rpc("station_search_households", {
      _query: query,
      _kids_session_id: sessionId,
      _shift_token: token ?? null,
    });
    if (error) throw error;
    return (data ?? []) as unknown as HouseholdSearchRow[];
  },

  async checkIn(params: {
    sessionId: string;
    childIds: string[];
    roomIds?: (string | null)[];
    token?: string | null;
    clientBatchKey: string;
  }): Promise<CheckInResultRow[]> {
    const { data, error } = await church().rpc("check_in_children", {
      _kids_session_id: params.sessionId,
      _child_person_ids: params.childIds,
      _room_ids: params.roomIds ?? null,
      _shift_token: params.token ?? null,
      _client_batch_key: params.clientBatchKey,
    });
    if (error) throw error;
    return (data ?? []) as unknown as CheckInResultRow[];
  },

  /** Zero rows means denied — wrong, expired, locked or already used. */
  async resolvePickup(
    sessionId: string,
    presented: string,
    token?: string | null
  ): Promise<PickupMatchRow[]> {
    const { data, error } = await church().rpc("resolve_pickup", {
      _kids_session_id: sessionId,
      _presented: presented,
      _shift_token: token ?? null,
    });
    if (error) throw error;
    return (data ?? []) as unknown as PickupMatchRow[];
  },

  async checkOut(params: {
    checkInIds: string[];
    presented: string;
    token?: string | null;
    pickedUpByName?: string;
  }): Promise<{ check_in_id: string; child_name: string }[]> {
    const { data, error } = await church().rpc("check_out_children", {
      _check_in_ids: params.checkInIds,
      _presented: params.presented,
      _shift_token: params.token ?? null,
      _picked_up_by_name: params.pickedUpByName ?? null,
    });
    if (error) throw error;
    return (data ?? []) as unknown as { check_in_id: string; child_name: string }[];
  },

  /** Open classrooms with live occupancy. Nothing here identifies a person. */
  async sessionRooms(
    sessionId: string,
    token?: string | null
  ): Promise<StationRoom[]> {
    const { data, error } = await church().rpc("station_session_rooms", {
      _kids_session_id: sessionId,
      _shift_token: token ?? null,
    });
    if (error) throw error;
    return (data ?? []) as unknown as StationRoom[];
  },

  /**
   * Who is in the room in front of the volunteer.
   *
   * Names are first name + last initial, as everywhere else on the station.
   * The leader's kids_room_roster returns full names and the guardian's phone;
   * this one deliberately does not.
   */
  async roomRoster(
    sessionId: string,
    roomId: string | null,
    token?: string | null
  ): Promise<StationRosterRow[]> {
    const { data, error } = await church().rpc("station_room_roster", {
      _kids_session_id: sessionId,
      _room_id: roomId,
      _shift_token: token ?? null,
    });
    if (error) throw error;
    return (data ?? []) as unknown as StationRosterRow[];
  },

  /**
   * Message the parents of one checked-in child ("Please come to Room 4").
   *
   * Returns one row per recipient actually queued. An EMPTY array is a
   * meaningful result, not a success: it means nobody in the household has a
   * contactable address or everyone has opted out, so the volunteer must go
   * find the parent in person. The caller has to say so.
   */
  async sendParentMessage(params: {
    checkInId: string;
    message: string;
    token?: string | null;
  }): Promise<
    { recipient_name: string; channel: string; destination: string; status: string }[]
  > {
    const { data, error } = await church().rpc("send_parent_message", {
      _check_in_id: params.checkInId,
      _message: params.message,
      _shift_token: params.token ?? null,
    });
    if (error) throw error;
    return (data ?? []) as unknown as {
      recipient_name: string;
      channel: string;
      destination: string;
      status: string;
    }[];
  },
};
