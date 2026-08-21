/**
 * Reading and writing church.module_grants.
 *
 * Both RPCs check that the caller is an ORGANIZATION admin, not merely a
 * members_admin — otherwise a members_admin could grant themselves kids_admin
 * and with it access to children's medical data.
 */

import { supabase } from "@/integrations/supabase/client";
import type { MinistryRole } from "@/shared/lib/capabilities";

const church = () => supabase.schema("church");

export interface OrgPerson {
  user_id: string;
  full_name: string;
  email: string | null;
  app_role: string;
  is_org_admin: boolean;
  permissions: MinistryRole[];
  /**
   * Null when this login has no member record. Surfaced because that is what
   * keeps self-service and volunteer eligibility switched off for them.
   */
  person_id: string | null;
}

export const grantService = {
  async listOrgPeople(organizationId: string): Promise<OrgPerson[]> {
    const { data, error } = await church().rpc("org_people_for_grants", {
      _organization_id: organizationId,
    });
    if (error) throw error;
    return (data ?? []) as unknown as OrgPerson[];
  },

  /**
   * Replaces the person's permissions with exactly this list — the screen is a
   * set of tickboxes, and "what I see is what they have" is the only reading
   * of that which cannot drift.
   */
  async setGrants(
    organizationId: string,
    userId: string,
    permissions: MinistryRole[]
  ): Promise<MinistryRole[]> {
    const { data, error } = await church().rpc("set_module_grants", {
      _user_id: userId,
      _organization_id: organizationId,
      _permissions: permissions,
    });
    if (error) throw error;
    return (data ?? []) as unknown as MinistryRole[];
  },
};
