/**
 * Household and family-relationship data access.
 */

import { supabase } from "@/integrations/supabase/client";
import type {
  Household,
  HouseholdInsert,
  HouseholdUpdate,
  HouseholdWithMembers,
  Member,
  PersonRelationshipInsert,
  RelationshipWithPerson,
} from "../types";

const church = () => supabase.schema("church");
const NO_ROWS = "PGRST116";

export const householdService = {
  async list(organizationId: string): Promise<Household[]> {
    const { data, error } = await church()
      .from("households")
      .select("*")
      .eq("organization_id", organizationId)
      .eq("is_active", true)
      .order("name");
    if (error) throw error;
    return data || [];
  },

  async get(householdId: string): Promise<Household | null> {
    const { data, error } = await church()
      .from("households")
      .select("*")
      .eq("id", householdId)
      .single();
    if (error && error.code !== NO_ROWS) throw error;
    return data;
  },

  async getWithMembers(householdId: string): Promise<HouseholdWithMembers | null> {
    const { data, error } = await church()
      .from("households")
      .select("*, household_members(household_role, is_primary_contact, person:people(*))")
      .eq("id", householdId)
      .is("household_members.end_date", null)
      .single();
    if (error && error.code !== NO_ROWS) throw error;
    if (!data) return null;

    const raw = data as unknown as Household & {
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

  async create(household: HouseholdInsert): Promise<Household> {
    const { data, error } = await church()
      .from("households")
      .insert(household)
      .select()
      .single();
    if (error) throw error;
    return data;
  },

  async update(householdId: string, patch: HouseholdUpdate): Promise<Household> {
    const { data, error } = await church()
      .from("households")
      .update({ ...patch, updated_at: new Date().toISOString() })
      .eq("id", householdId)
      .select()
      .single();
    if (error) throw error;
    return data;
  },

  /**
   * Add a person to a household.
   *
   * The database enforces at most one PRIMARY household per person and no
   * overlapping membership spans, so a bad call fails loudly rather than
   * producing a person who lives in two places at once.
   */
  async addMember(params: {
    organizationId: string;
    householdId: string;
    personId: string;
    householdRole: string;
    isPrimaryHousehold?: boolean;
  }): Promise<void> {
    const { error } = await church().from("household_members").insert({
      organization_id: params.organizationId,
      household_id: params.householdId,
      person_id: params.personId,
      household_role: params.householdRole,
      is_primary_household: params.isPrimaryHousehold ?? true,
    });
    if (error) throw error;
  },

  /**
   * Remove a person from a household by ENDING the membership, so the history
   * of who lived where survives (BR-11).
   */
  async endMembership(householdMemberId: string): Promise<void> {
    const { error } = await church()
      .from("household_members")
      .update({
        end_date: new Date().toISOString().slice(0, 10),
        updated_at: new Date().toISOString(),
      })
      .eq("id", householdMemberId);
    if (error) throw error;
  },

  async setPrimaryContact(householdId: string, personId: string): Promise<void> {
    const clear = await church()
      .from("household_members")
      .update({ is_primary_contact: false, updated_at: new Date().toISOString() })
      .eq("household_id", householdId)
      .is("end_date", null);
    if (clear.error) throw clear.error;

    const { error } = await church()
      .from("household_members")
      .update({ is_primary_contact: true, updated_at: new Date().toISOString() })
      .eq("household_id", householdId)
      .eq("person_id", personId)
      .is("end_date", null);
    if (error) throw error;
  },
};

export const relationshipService = {
  async listForMember(memberId: string): Promise<RelationshipWithPerson[]> {
    const { data, error } = await church()
      .from("person_relationships")
      .select(
        `*,
         related_person:people!person_relationships_related_person_id_fkey(
           id, first_name, last_name, is_child
         ),
         relationship_type:relationship_types(code, display_name)`
      )
      .eq("person_id", memberId)
      .is("end_date", null);
    if (error) throw error;
    return (data || []) as unknown as RelationshipWithPerson[];
  },

  /**
   * Create one edge. The database mirrors the inverse automatically
   * (parent -> child implies child -> parent), so callers must NOT write both
   * directions or they will collide on the uniqueness constraint.
   */
  async create(relationship: PersonRelationshipInsert): Promise<void> {
    const { error } = await church().from("person_relationships").insert(relationship);
    if (error) throw error;
  },

  async delete(relationshipId: string): Promise<void> {
    const { error } = await church()
      .from("person_relationships")
      .delete()
      .eq("id", relationshipId);
    if (error) throw error;
  },
};
