/**
 * Member registration.
 *
 * Goes through church.register_member_family, which writes the household,
 * the person, the spouse, every child, their parent relationships, their
 * Kids pickup authorisations, emergency contacts and service interests in a
 * SINGLE transaction.
 *
 * Doing this as a sequence of client calls would leave a half-built family
 * behind on any failure — a household with nobody in it, or children with no
 * parent link — and the browser has no way to roll that back.
 */

import { useMutation, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { memberKeys } from "./useMembers";
import { householdKeys } from "./useHouseholds";
import { servingKeys } from "./useServing";

const church = () => supabase.schema("church");

export interface PersonPayload {
  first_name: string;
  middle_name?: string;
  last_name: string;
  preferred_name?: string;
  amharic_name?: string;
  birth_year?: number | string;
  birth_month?: number | string;
  gender?: string;
  marital_status?: string;
  email?: string;
  phone?: string;
  membership_status_id?: string;
  member_since?: string;
  accepted_lord_year?: number | string;
  accepted_lord_month?: number | string;
  accepted_lord_is_approximate?: boolean;
  school_grade_id?: string;
  notes?: string;
  /**
   * Allergy and medical fields, on children only.
   *
   * Captured here because registration is the one moment a parent is actually
   * asked. Recorded only when something is said, so "no allergy" stays
   * distinguishable from "nobody asked" on the volunteer's safety card.
   */
  allergy_severity?: string;
  allergies?: string;
  medications?: string;
  special_needs?: string;
}

export interface HouseholdPayload {
  name: string;
  address_line1?: string;
  address_line2?: string;
  city?: string;
  state?: string;
  postal_code?: string;
  primary_phone?: string;
}

export interface SpousePayload {
  mode: "none" | "link" | "create";
  person_id?: string;
  person?: PersonPayload;
}

export interface EmergencyContactPayload {
  name: string;
  phone: string;
  relationship?: string;
  priority?: number;
}

export interface RegisterMemberInput {
  organizationId: string;
  person: PersonPayload;
  household?: HouseholdPayload | null;
  spouse?: SpousePayload | null;
  children?: PersonPayload[];
  emergencyContacts?: EmergencyContactPayload[];
  serviceInterestMinistryIds?: string[];
}

export interface RegisterMemberResult {
  out_person_id: string;
  out_household_id: string | null;
  out_spouse_person_id: string | null;
  out_child_count: number;
}

export function useRegisterMember() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (input: RegisterMemberInput): Promise<RegisterMemberResult> => {
      const { data, error } = await church().rpc("register_member_family", {
        _organization_id: input.organizationId,
        _person: input.person as never,
        _household: (input.household ?? null) as never,
        _spouse: (input.spouse ?? null) as never,
        _children: (input.children ?? []) as never,
        _emergency_contacts: (input.emergencyContacts ?? []) as never,
        _service_interest_ministry_ids: input.serviceInterestMinistryIds ?? null,
      });
      if (error) throw error;
      const rows = (data ?? []) as unknown as RegisterMemberResult[];
      if (rows.length === 0) throw new Error("Registration returned no result");
      return rows[0];
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: memberKeys.all });
      queryClient.invalidateQueries({ queryKey: householdKeys.all });
      queryClient.invalidateQueries({ queryKey: servingKeys.all });
    },
  });
}

/**
 * Human-readable messages for the errors the RPC raises deliberately.
 * Anything unrecognised falls through to the raw message rather than being
 * swallowed, so a genuine database error is still visible.
 */
export function registrationErrorMessage(error: unknown): string {
  const raw = error instanceof Error ? error.message : String(error);
  const known: Record<string, string> = {
    not_permitted: "You do not have permission to register members.",
    first_and_last_name_required: "First and last name are both required.",
    child_requires_birth_year:
      "Every child needs a birth year — it decides their Kids Ministry classroom.",
    cannot_be_own_spouse: "A person cannot be their own spouse.",
    spouse_not_found_in_organization:
      "That spouse record belongs to a different branch.",
  };
  for (const [code, message] of Object.entries(known)) {
    if (raw.includes(code)) return message;
  }
  return raw;
}
