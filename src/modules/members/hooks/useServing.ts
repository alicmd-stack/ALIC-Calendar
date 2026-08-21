/**
 * Ministry service and service-interest hooks.
 */

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { servingService, serviceInterestService } from "../services";
import type { MinistryAssignmentInsert, ServiceInterestInsert } from "../types";
import { memberKeys } from "./useMembers";

export const servingKeys = {
  all: ["church", "serving"] as const,
  byMember: (memberId: string) => [...servingKeys.all, "member", memberId] as const,
  byMinistry: (ministryId: string) => [...servingKeys.all, "ministry", ministryId] as const,
  totals: (orgId: string) => [...servingKeys.all, "totals", orgId] as const,
  summaries: (orgId: string) => [...servingKeys.all, "summaries", orgId] as const,
  unplaced: (orgId: string) => [...servingKeys.all, "unplaced", orgId] as const,
  interestsByMember: (memberId: string) =>
    [...servingKeys.all, "interests", memberId] as const,
};

export function useMemberServing(memberId: string | undefined) {
  return useQuery({
    queryKey: servingKeys.byMember(memberId || ""),
    queryFn: () => servingService.listByMember(memberId!),
    enabled: !!memberId,
  });
}

export function useMinistryRoster(ministryId: string | undefined) {
  return useQuery({
    queryKey: servingKeys.byMinistry(ministryId || ""),
    queryFn: () => servingService.listByMinistry(ministryId!),
    enabled: !!ministryId,
  });
}

/**
 * The three counting measures the spec requires be kept distinct:
 * assignment rows, unique serving people, and people in 2+ ministries.
 */
export function useServingTotals(organizationId: string | undefined) {
  return useQuery({
    queryKey: servingKeys.totals(organizationId || ""),
    queryFn: () => servingService.getTotals(organizationId!),
    enabled: !!organizationId,
  });
}

/** Per-ministry sizes, counted as DISTINCT people (MIN-007). */
export function useMinistrySummaries(organizationId: string | undefined) {
  return useQuery({
    queryKey: servingKeys.summaries(organizationId || ""),
    queryFn: () => servingService.getMinistrySummaries(organizationId!),
    enabled: !!organizationId,
  });
}

/** SRV-003: interested but not yet serving. */
export function useUnplacedInterests(organizationId: string | undefined) {
  return useQuery({
    queryKey: servingKeys.unplaced(organizationId || ""),
    queryFn: () => serviceInterestService.listUnplaced(organizationId!),
    enabled: !!organizationId,
  });
}

export function useMemberInterests(memberId: string | undefined) {
  return useQuery({
    queryKey: servingKeys.interestsByMember(memberId || ""),
    queryFn: () => serviceInterestService.listByMember(memberId!),
    enabled: !!memberId,
  });
}

export function useCreateAssignment() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (assignment: MinistryAssignmentInsert) => servingService.create(assignment),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: servingKeys.all });
      queryClient.invalidateQueries({ queryKey: memberKeys.profile(data.person_id) });
    },
  });
}

/** Ends an assignment, retaining the service history (MIN-008). */
export function useEndAssignment() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ assignmentId }: { assignmentId: string; memberId?: string }) =>
      servingService.end(assignmentId),
    onSuccess: (_r, vars) => {
      queryClient.invalidateQueries({ queryKey: servingKeys.all });
      if (vars.memberId) {
        queryClient.invalidateQueries({ queryKey: memberKeys.profile(vars.memberId) });
      }
    },
  });
}

export function useCreateServiceInterest() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (interest: ServiceInterestInsert) => serviceInterestService.create(interest),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: servingKeys.all });
      queryClient.invalidateQueries({ queryKey: memberKeys.profile(data.person_id) });
    },
  });
}

export function useUpdateInterestStatus() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ interestId, status }: { interestId: string; status: string }) =>
      serviceInterestService.updateStatus(interestId, status),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: servingKeys.all });
    },
  });
}
