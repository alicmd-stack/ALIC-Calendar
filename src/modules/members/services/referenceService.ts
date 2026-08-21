/**
 * Controlled reference data.
 *
 * These are tables rather than enums because the spec requires ministries,
 * roles, group types, age brackets and statuses to be configuration rather
 * than hard-coded. They change rarely, so callers cache them aggressively.
 */

import { supabase } from "@/integrations/supabase/client";
import type {
  MembershipStatus,
  MinistryRole,
  RelationshipType,
  SchoolGrade,
  KidsAgeBand,
  GroupType,
} from "../types";

const church = () => supabase.schema("church");
const budget = () => supabase.schema("budget");

export interface MinistryOption {
  id: string;
  name: string;
}

export const referenceService = {
  async membershipStatuses(organizationId: string): Promise<MembershipStatus[]> {
    const { data, error } = await church()
      .from("membership_statuses")
      .select("*")
      .eq("organization_id", organizationId)
      .eq("is_active", true)
      .order("sort_order");
    if (error) throw error;
    return data || [];
  },

  async ministryRoles(organizationId: string): Promise<MinistryRole[]> {
    const { data, error } = await church()
      .from("ministry_roles")
      .select("*")
      .eq("organization_id", organizationId)
      .eq("is_active", true)
      .order("sort_order");
    if (error) throw error;
    return data || [];
  },

  async relationshipTypes(organizationId: string): Promise<RelationshipType[]> {
    const { data, error } = await church()
      .from("relationship_types")
      .select("*")
      .eq("organization_id", organizationId)
      .eq("is_active", true)
      .order("sort_order");
    if (error) throw error;
    return data || [];
  },

  async schoolGrades(organizationId: string): Promise<SchoolGrade[]> {
    const { data, error } = await church()
      .from("school_grades")
      .select("*")
      .eq("organization_id", organizationId)
      .eq("is_active", true)
      .order("sort_order");
    if (error) throw error;
    return data || [];
  },

  async kidsAgeBands(organizationId: string): Promise<KidsAgeBand[]> {
    const { data, error } = await church()
      .from("kids_age_bands")
      .select("*")
      .eq("organization_id", organizationId)
      .eq("is_active", true)
      .order("sort_order");
    if (error) throw error;
    return data || [];
  },

  async groupTypes(organizationId: string): Promise<GroupType[]> {
    const { data, error } = await church()
      .from("group_types")
      .select("*")
      .eq("organization_id", organizationId)
      .eq("is_active", true)
      .order("sort_order");
    if (error) throw error;
    return data || [];
  },

  /**
   * The ministry master list, reused from the budget module rather than
   * duplicated, so the church maintains one list of ministries.
   */
  async ministries(organizationId: string): Promise<MinistryOption[]> {
    const { data, error } = await budget()
      .from("ministries")
      .select("id, name")
      .eq("organization_id", organizationId)
      .eq("is_active", true)
      .order("name");
    if (error) throw error;
    return data || [];
  },
};
