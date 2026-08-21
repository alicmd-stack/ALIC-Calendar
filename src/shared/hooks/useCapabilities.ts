/**
 * Resolves the current user's module capabilities for the organization in
 * context.
 *
 * Deliberately a standalone hook rather than an addition to AuthContext:
 *
 *  - AuthContext is a parent of OrganizationContext, so it cannot see the
 *    current organization, and capabilities are meaningless without one.
 *  - AuthContext.isAdmin is computed by OR-ing roles across ALL of the user's
 *    organizations with no organization filter, so an admin of Silver Spring
 *    reports isAdmin at Springfield too. We use OrganizationContext.isOrgAdmin
 *    instead, which is derived from the current membership and is correctly
 *    scoped.
 *  - Touching AuthContext risks the live budget module for no benefit.
 *
 * This gates the UI only. Every capability has a matching RLS policy or
 * SECURITY DEFINER check in the database, and that is the real boundary.
 */

import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/shared/contexts/AuthContext";
import { useOrganization } from "@/shared/contexts/OrganizationContext";
import {
  resolveCapabilities,
  type Capability,
  type MinistryRole,
  type ModuleGrant,
} from "@/shared/lib/capabilities";

export const moduleGrantKeys = {
  all: ["church", "module-grants"] as const,
  forUser: (userId: string) => [...moduleGrantKeys.all, userId] as const,
};

async function fetchModuleGrants(userId: string): Promise<ModuleGrant[]> {
  const { data, error } = await supabase
    .schema("church")
    .from("module_grants")
    .select("organization_id, permission")
    .eq("user_id", userId);

  if (error) throw error;

  return (data ?? []).map((row) => ({
    organization_id: row.organization_id,
    role: row.permission as MinistryRole,
  }));
}

export interface UseCapabilitiesResult {
  capabilities: Set<Capability>;
  /** True while grants are still loading; treat the UI as not-yet-authorized. */
  loading: boolean;
  can: (capability: Capability) => boolean;
  canAny: (required: readonly Capability[]) => boolean;
}

export function useCapabilities(): UseCapabilitiesResult {
  const { user } = useAuth();
  const { currentOrganization, isOrgAdmin, loading: orgLoading } = useOrganization();

  const {
    data: grants,
    isLoading: grantsLoading,
    isError,
  } = useQuery({
    queryKey: moduleGrantKeys.forUser(user?.id ?? ""),
    queryFn: () => fetchModuleGrants(user!.id),
    enabled: !!user?.id,
    // Permissions change rarely and a stale grant is a security-relevant
    // staleness, so refetch on mount rather than serving a long-lived cache.
    staleTime: 60_000,
    // Fail closed: a failed grants query must not be retried into looking like
    // a grant. One retry for transient network blips, then give up.
    retry: 1,
  });

  // On error we resolve with no grants, so a broken query removes access
  // rather than conferring it. An org admin still gets full capabilities,
  // which is what keeps the module usable before any grant rows exist.
  const capabilities = resolveCapabilities({
    isOrgAdmin,
    grants: isError ? [] : (grants ?? []),
    organizationId: currentOrganization?.id,
  });

  return {
    capabilities,
    loading: orgLoading || grantsLoading,
    can: (capability: Capability) => capabilities.has(capability),
    canAny: (required: readonly Capability[]) =>
      required.length === 0 || required.some((c) => capabilities.has(c)),
  };
}
