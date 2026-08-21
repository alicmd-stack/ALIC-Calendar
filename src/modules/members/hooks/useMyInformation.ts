/**
 * Self-service hooks — a member's own record.
 *
 * These read through the narrow self-access RLS policies added in
 * 20260320001100, so a contributor sees exactly their own row, their
 * household, and their own serving / group / training records. Nothing here
 * can widen that: if the policies are wrong, the queries return nothing rather
 * than someone else's data.
 */

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import type { Member, HouseholdWithMembers, MinistryAssignmentWithMinistry } from "../types";

const church = () => supabase.schema("church");
const NO_ROWS = "PGRST116";

export const myInfoKeys = {
  all: ["church", "my-information"] as const,
  record: (userId: string) => [...myInfoKeys.all, "record", userId] as const,
  household: (personId: string) => [...myInfoKeys.all, "household", personId] as const,
  serving: (personId: string) => [...myInfoKeys.all, "serving", personId] as const,
};

/**
 * The caller's own person row, or null when their login has not been linked
 * to a member record yet (people.profile_id is null until an admin links it).
 */
async function fetchMyRecord(): Promise<Member | null> {
  const { data: auth } = await supabase.auth.getUser();
  const uid = auth.user?.id;
  if (!uid) return null;

  const { data, error } = await church()
    .from("people")
    .select("*")
    .eq("profile_id", uid)
    .limit(1)
    .maybeSingle();

  if (error && error.code !== NO_ROWS) throw error;
  return data ?? null;
}

export function useMyRecord(userId: string | undefined) {
  return useQuery({
    queryKey: myInfoKeys.record(userId || ""),
    queryFn: fetchMyRecord,
    enabled: !!userId,
  });
}

export function useMyHousehold(personId: string | undefined) {
  return useQuery({
    queryKey: myInfoKeys.household(personId || ""),
    queryFn: async (): Promise<HouseholdWithMembers | null> => {
      const { data: membership, error: mErr } = await church()
        .from("household_members")
        .select("household_id")
        .eq("person_id", personId!)
        .is("end_date", null)
        .limit(1)
        .maybeSingle();
      if (mErr && mErr.code !== NO_ROWS) throw mErr;
      if (!membership?.household_id) return null;

      const { data, error } = await church()
        .from("households")
        .select("*, household_members(household_role, is_primary_contact, person:people(*))")
        .eq("id", membership.household_id)
        .is("household_members.end_date", null)
        .maybeSingle();
      if (error && error.code !== NO_ROWS) throw error;
      if (!data) return null;

      const raw = data as unknown as HouseholdWithMembers & {
        household_members: {
          household_role: string;
          is_primary_contact: boolean;
          person: Member;
        }[];
      };
      return {
        ...raw,
        members: (raw.household_members || [])
          .filter((hm) => hm.person)
          .map((hm) => ({
            ...hm.person,
            household_role: hm.household_role,
            is_primary_contact: hm.is_primary_contact,
          })),
      };
    },
    enabled: !!personId,
  });
}

export function useMyServing(personId: string | undefined) {
  return useQuery({
    queryKey: myInfoKeys.serving(personId || ""),
    queryFn: async (): Promise<MinistryAssignmentWithMinistry[]> => {
      const { data, error } = await church()
        .from("ministry_assignments")
        .select("*, role:ministry_roles(code, display_name, is_leadership_role)")
        .eq("person_id", personId!)
        .is("end_date", null);
      if (error) throw error;

      const rows = (data || []) as unknown as MinistryAssignmentWithMinistry[];
      if (rows.length === 0) return rows;

      // budget.ministries is a different schema, so PostgREST cannot embed it.
      const ids = [...new Set(rows.map((r) => r.ministry_id))];
      const { data: ministries, error: mErr } = await supabase
        .schema("budget")
        .from("ministries")
        .select("id, name")
        .in("id", ids);
      if (mErr) throw mErr;
      const byId = new Map((ministries || []).map((m) => [m.id, m.name]));
      return rows.map((r) => ({
        ...r,
        ministry: { id: r.ministry_id, name: byId.get(r.ministry_id) ?? "Unknown ministry" },
      }));
    },
    enabled: !!personId,
  });
}

/**
 * Update the caller's own phone and email.
 *
 * Goes through church.update_my_contact_details rather than a table update,
 * because RLS cannot restrict WHICH columns an update touches — a self-UPDATE
 * policy on church.people would let a member rewrite their own membership
 * status or birthday. The function names the two permitted columns and
 * nothing else.
 */
export function useUpdateMyContactDetails() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (params: { personId: string; phone: string; email: string }) => {
      const { data, error } = await church().rpc("update_my_contact_details", {
        _person_id: params.personId,
        _phone: params.phone,
        _email: params.email,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: myInfoKeys.all });
    },
  });
}
