/**
 * Hook for fetching and managing budget allocations
 */

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { budgetAllocationService } from "../services";
import type { BudgetAllocationInsert, BudgetAllocationUpdate } from "../types";

// Query keys
export const budgetAllocationKeys = {
  all: ["budget-allocations"] as const,
  lists: () => [...budgetAllocationKeys.all, "list"] as const,
  byFiscalYear: (fyId: string) =>
    [...budgetAllocationKeys.lists(), "fiscal-year", fyId] as const,
  byMinistryAndFiscalYear: (ministryId: string, fyId: string) =>
    [...budgetAllocationKeys.all, "ministry", ministryId, fyId] as const,
  summary: (ministryId: string, fyId: string) =>
    [...budgetAllocationKeys.all, "summary", ministryId, fyId] as const,
  orgSummary: (orgId: string, fyId: string) =>
    [...budgetAllocationKeys.all, "org-summary", orgId, fyId] as const,
};

/**
 * Hook to fetch budget allocations for a fiscal year
 */
export function useBudgetAllocations(fiscalYearId: string | undefined) {
  return useQuery({
    queryKey: budgetAllocationKeys.byFiscalYear(fiscalYearId || ""),
    queryFn: () => budgetAllocationService.listByFiscalYear(fiscalYearId!),
    enabled: !!fiscalYearId,
  });
}

/**
 * Hook to fetch budget allocation for a specific ministry and fiscal year
 */
export function useBudgetAllocation(
  ministryId: string | undefined,
  fiscalYearId: string | undefined
) {
  return useQuery({
    queryKey: budgetAllocationKeys.byMinistryAndFiscalYear(
      ministryId || "",
      fiscalYearId || ""
    ),
    queryFn: () =>
      budgetAllocationService.getByMinistryAndFiscalYear(ministryId!, fiscalYearId!),
    enabled: !!ministryId && !!fiscalYearId,
  });
}

/**
 * Hook to fetch ministry budget summary
 */
export function useMinistryBudgetSummary(
  ministryId: string | undefined,
  fiscalYearId: string | undefined
) {
  return useQuery({
    queryKey: budgetAllocationKeys.summary(ministryId || "", fiscalYearId || ""),
    queryFn: () =>
      budgetAllocationService.getMinistryBudgetSummary(ministryId!, fiscalYearId!),
    enabled: !!ministryId && !!fiscalYearId,
  });
}

/**
 * Hook to fetch organization-wide budget summary
 */
export function useOrganizationBudgetSummary(
  organizationId: string | undefined,
  fiscalYearId: string | undefined
) {
  return useQuery({
    queryKey: budgetAllocationKeys.orgSummary(
      organizationId || "",
      fiscalYearId || ""
    ),
    queryFn: () =>
      budgetAllocationService.getOrganizationBudgetSummary(
        organizationId!,
        fiscalYearId!
      ),
    enabled: !!organizationId && !!fiscalYearId,
  });
}

/**
 * Hook to create or update a budget allocation
 */
export function useUpsertBudgetAllocation() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (allocationData: BudgetAllocationInsert) =>
      budgetAllocationService.upsert(allocationData),
    onSuccess: (data) => {
      queryClient.invalidateQueries({
        queryKey: budgetAllocationKeys.byFiscalYear(data.fiscal_year_id),
      });
      queryClient.invalidateQueries({
        queryKey: budgetAllocationKeys.byMinistryAndFiscalYear(
          data.ministry_id,
          data.fiscal_year_id
        ),
      });
      queryClient.invalidateQueries({
        queryKey: budgetAllocationKeys.summary(data.ministry_id, data.fiscal_year_id),
      });
      queryClient.invalidateQueries({
        queryKey: budgetAllocationKeys.orgSummary(
          data.organization_id,
          data.fiscal_year_id
        ),
      });
    },
  });
}

/**
 * Hook to create a budget allocation
 */
export function useCreateBudgetAllocation() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (allocationData: BudgetAllocationInsert) =>
      budgetAllocationService.create(allocationData),
    onSuccess: (data) => {
      queryClient.invalidateQueries({
        queryKey: budgetAllocationKeys.byFiscalYear(data.fiscal_year_id),
      });
    },
  });
}

/**
 * Hook to update a budget allocation
 */
export function useUpdateBudgetAllocation() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      allocationId,
      data,
    }: {
      allocationId: string;
      data: BudgetAllocationUpdate;
    }) => budgetAllocationService.update(allocationId, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: budgetAllocationKeys.lists() });
    },
  });
}

/**
 * Hook to delete a budget allocation
 */
export function useDeleteBudgetAllocation() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (allocationId: string) =>
      budgetAllocationService.delete(allocationId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: budgetAllocationKeys.lists() });
    },
  });
}
