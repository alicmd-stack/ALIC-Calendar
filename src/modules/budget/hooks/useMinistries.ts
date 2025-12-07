/**
 * Hook for fetching and managing ministries
 */

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { ministryService } from "../services";
import type { MinistryInsert, MinistryUpdate } from "../types";

// Query keys
export const ministryKeys = {
  all: ["ministries"] as const,
  lists: () => [...ministryKeys.all, "list"] as const,
  list: (orgId: string) => [...ministryKeys.lists(), orgId] as const,
  details: () => [...ministryKeys.all, "detail"] as const,
  detail: (id: string) => [...ministryKeys.details(), id] as const,
  byLeader: (userId: string) => [...ministryKeys.all, "by-leader", userId] as const,
};

/**
 * Hook to fetch ministries for an organization
 */
export function useMinistries(organizationId: string | undefined) {
  return useQuery({
    queryKey: ministryKeys.list(organizationId || ""),
    queryFn: () => ministryService.list(organizationId!),
    enabled: !!organizationId,
  });
}

/**
 * Hook to fetch a single ministry
 */
export function useMinistry(ministryId: string | undefined) {
  return useQuery({
    queryKey: ministryKeys.detail(ministryId || ""),
    queryFn: () => ministryService.get(ministryId!),
    enabled: !!ministryId,
  });
}

/**
 * Hook to fetch ministries led by a user
 */
export function useMinistriesByLeader(userId: string | undefined) {
  return useQuery({
    queryKey: ministryKeys.byLeader(userId || ""),
    queryFn: () => ministryService.getByLeader(userId!),
    enabled: !!userId,
  });
}

/**
 * Hook to create a ministry
 */
export function useCreateMinistry() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (ministryData: MinistryInsert) => ministryService.create(ministryData),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: ministryKeys.list(data.organization_id) });
    },
  });
}

/**
 * Hook to update a ministry
 */
export function useUpdateMinistry() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      ministryId,
      data,
    }: {
      ministryId: string;
      data: MinistryUpdate;
    }) => ministryService.update(ministryId, data),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: ministryKeys.lists() });
      queryClient.invalidateQueries({ queryKey: ministryKeys.detail(data.id) });
    },
  });
}

/**
 * Hook to delete a ministry
 */
export function useDeleteMinistry() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (ministryId: string) => ministryService.delete(ministryId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ministryKeys.lists() });
    },
  });
}

/**
 * Hook to assign leader to a ministry
 */
export function useAssignMinistryLeader() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      ministryId,
      leaderId,
    }: {
      ministryId: string;
      leaderId: string;
    }) => ministryService.assignLeader(ministryId, leaderId),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: ministryKeys.lists() });
      queryClient.invalidateQueries({ queryKey: ministryKeys.detail(data.id) });
    },
  });
}

/**
 * Hook to remove leader from a ministry
 */
export function useRemoveMinistryLeader() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (ministryId: string) => ministryService.removeLeader(ministryId),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: ministryKeys.lists() });
      queryClient.invalidateQueries({ queryKey: ministryKeys.detail(data.id) });
    },
  });
}
