/**
 * Controlled reference data hooks.
 *
 * These change rarely (a church renames a classroom, adds a membership
 * status), so they carry a long staleTime — the directory would otherwise
 * refetch six lookup tables on every page view.
 */

import { useQuery } from "@tanstack/react-query";
import { referenceService } from "../services";

const FIVE_MINUTES = 5 * 60 * 1000;

export const referenceKeys = {
  all: ["church", "reference"] as const,
  membershipStatuses: (orgId: string) => [...referenceKeys.all, "membership-statuses", orgId] as const,
  ministryRoles: (orgId: string) => [...referenceKeys.all, "ministry-roles", orgId] as const,
  relationshipTypes: (orgId: string) => [...referenceKeys.all, "relationship-types", orgId] as const,
  schoolGrades: (orgId: string) => [...referenceKeys.all, "school-grades", orgId] as const,
  kidsAgeBands: (orgId: string) => [...referenceKeys.all, "kids-age-bands", orgId] as const,
  groupTypes: (orgId: string) => [...referenceKeys.all, "group-types", orgId] as const,
  ministries: (orgId: string) => [...referenceKeys.all, "ministries", orgId] as const,
};

export function useMembershipStatuses(organizationId: string | undefined) {
  return useQuery({
    queryKey: referenceKeys.membershipStatuses(organizationId || ""),
    queryFn: () => referenceService.membershipStatuses(organizationId!),
    enabled: !!organizationId,
    staleTime: FIVE_MINUTES,
  });
}

export function useMinistryRoles(organizationId: string | undefined) {
  return useQuery({
    queryKey: referenceKeys.ministryRoles(organizationId || ""),
    queryFn: () => referenceService.ministryRoles(organizationId!),
    enabled: !!organizationId,
    staleTime: FIVE_MINUTES,
  });
}

export function useRelationshipTypes(organizationId: string | undefined) {
  return useQuery({
    queryKey: referenceKeys.relationshipTypes(organizationId || ""),
    queryFn: () => referenceService.relationshipTypes(organizationId!),
    enabled: !!organizationId,
    staleTime: FIVE_MINUTES,
  });
}

export function useSchoolGrades(organizationId: string | undefined) {
  return useQuery({
    queryKey: referenceKeys.schoolGrades(organizationId || ""),
    queryFn: () => referenceService.schoolGrades(organizationId!),
    enabled: !!organizationId,
    staleTime: FIVE_MINUTES,
  });
}

export function useKidsAgeBands(organizationId: string | undefined) {
  return useQuery({
    queryKey: referenceKeys.kidsAgeBands(organizationId || ""),
    queryFn: () => referenceService.kidsAgeBands(organizationId!),
    enabled: !!organizationId,
    staleTime: FIVE_MINUTES,
  });
}

export function useGroupTypes(organizationId: string | undefined) {
  return useQuery({
    queryKey: referenceKeys.groupTypes(organizationId || ""),
    queryFn: () => referenceService.groupTypes(organizationId!),
    enabled: !!organizationId,
    staleTime: FIVE_MINUTES,
  });
}

/** The shared ministry master list, from budget.ministries. */
export function useMinistries(organizationId: string | undefined) {
  return useQuery({
    queryKey: referenceKeys.ministries(organizationId || ""),
    queryFn: () => referenceService.ministries(organizationId!),
    enabled: !!organizationId,
    staleTime: FIVE_MINUTES,
  });
}
