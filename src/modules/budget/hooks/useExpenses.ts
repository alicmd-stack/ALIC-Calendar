/**
 * Hook for fetching and managing expense requests
 */

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { expenseService } from "../services";
import type { ExpenseRequestInsert, ExpenseRequestUpdate, ExpenseFilters } from "../types";
import { budgetAllocationKeys } from "./useBudgetAllocations";

// Query keys
export const expenseKeys = {
  all: ["expenses"] as const,
  lists: () => [...expenseKeys.all, "list"] as const,
  list: (orgId: string, filters?: ExpenseFilters) =>
    [...expenseKeys.lists(), orgId, filters] as const,
  details: () => [...expenseKeys.all, "detail"] as const,
  detail: (id: string) => [...expenseKeys.details(), id] as const,
  pendingLeader: (userId: string) =>
    [...expenseKeys.all, "pending-leader", userId] as const,
  pendingTreasury: (orgId: string) =>
    [...expenseKeys.all, "pending-treasury", orgId] as const,
  pendingFinance: (orgId: string) =>
    [...expenseKeys.all, "pending-finance", orgId] as const,
  history: (expenseId: string) => [...expenseKeys.all, "history", expenseId] as const,
  statistics: (orgId: string, fyId?: string) =>
    [...expenseKeys.all, "statistics", orgId, fyId] as const,
};

/**
 * Hook to fetch expenses for an organization
 */
export function useExpenses(
  organizationId: string | undefined,
  filters?: ExpenseFilters
) {
  return useQuery({
    queryKey: expenseKeys.list(organizationId || "", filters),
    queryFn: () => expenseService.list(organizationId!, filters),
    enabled: !!organizationId,
  });
}

/**
 * Hook to fetch a single expense request
 */
export function useExpense(expenseId: string | undefined) {
  return useQuery({
    queryKey: expenseKeys.detail(expenseId || ""),
    queryFn: () => expenseService.get(expenseId!),
    enabled: !!expenseId,
  });
}

/**
 * Hook to fetch expenses pending leader review
 */
export function useExpensesPendingLeader(userId: string | undefined) {
  return useQuery({
    queryKey: expenseKeys.pendingLeader(userId || ""),
    queryFn: () => expenseService.listPendingForLeader(userId!),
    enabled: !!userId,
  });
}

/**
 * Hook to fetch expenses pending treasury review
 */
export function useExpensesPendingTreasury(organizationId: string | undefined) {
  return useQuery({
    queryKey: expenseKeys.pendingTreasury(organizationId || ""),
    queryFn: () => expenseService.listPendingForTreasury(organizationId!),
    enabled: !!organizationId,
  });
}

/**
 * Hook to fetch expenses pending finance processing
 */
export function useExpensesPendingFinance(organizationId: string | undefined) {
  return useQuery({
    queryKey: expenseKeys.pendingFinance(organizationId || ""),
    queryFn: () => expenseService.listPendingForFinance(organizationId!),
    enabled: !!organizationId,
  });
}

/**
 * Hook to fetch expense history
 */
export function useExpenseHistory(expenseId: string | undefined) {
  return useQuery({
    queryKey: expenseKeys.history(expenseId || ""),
    queryFn: () => expenseService.getHistory(expenseId!),
    enabled: !!expenseId,
  });
}

/**
 * Hook to fetch expense statistics
 */
export function useExpenseStatistics(
  organizationId: string | undefined,
  fiscalYearId?: string
) {
  return useQuery({
    queryKey: expenseKeys.statistics(organizationId || "", fiscalYearId),
    queryFn: () => expenseService.getStatistics(organizationId!, fiscalYearId),
    enabled: !!organizationId,
  });
}

/**
 * Hook to create an expense request
 */
export function useCreateExpense() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      expenseData,
      actorId,
      actorName,
    }: {
      expenseData: ExpenseRequestInsert;
      actorId: string;
      actorName: string;
    }) => expenseService.create(expenseData, actorId, actorName),
    onSuccess: (data) => {
      queryClient.invalidateQueries({
        queryKey: expenseKeys.list(data.organization_id),
      });
      queryClient.invalidateQueries({
        queryKey: expenseKeys.statistics(data.organization_id),
      });
    },
  });
}

/**
 * Hook to update an expense request
 */
export function useUpdateExpense() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      expenseId,
      data,
    }: {
      expenseId: string;
      data: ExpenseRequestUpdate;
    }) => expenseService.update(expenseId, data),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: expenseKeys.lists() });
      queryClient.invalidateQueries({ queryKey: expenseKeys.detail(data.id) });
    },
  });
}

/**
 * Hook to delete an expense request
 */
export function useDeleteExpense() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (expenseId: string) => expenseService.delete(expenseId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: expenseKeys.lists() });
    },
  });
}

/**
 * Hook to submit expense for review
 */
export function useSubmitExpenseForReview() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      expenseId,
      actorId,
      actorName,
    }: {
      expenseId: string;
      actorId: string;
      actorName: string;
    }) => expenseService.submitForReview(expenseId, actorId, actorName),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: expenseKeys.lists() });
      queryClient.invalidateQueries({ queryKey: expenseKeys.detail(data.id) });
      queryClient.invalidateQueries({ queryKey: expenseKeys.history(data.id) });
    },
  });
}

/**
 * Hook for leader to approve expense
 */
export function useLeaderApproveExpense() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      expenseId,
      reviewerId,
      reviewerName,
      notes,
    }: {
      expenseId: string;
      reviewerId: string;
      reviewerName: string;
      notes?: string;
    }) => expenseService.leaderApprove(expenseId, reviewerId, reviewerName, notes),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: expenseKeys.lists() });
      queryClient.invalidateQueries({ queryKey: expenseKeys.detail(data.id) });
      queryClient.invalidateQueries({ queryKey: expenseKeys.history(data.id) });
      queryClient.invalidateQueries({
        queryKey: expenseKeys.pendingLeader(data.leader_reviewer_id || ""),
      });
    },
  });
}

/**
 * Hook for leader to deny expense
 */
export function useLeaderDenyExpense() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      expenseId,
      reviewerId,
      reviewerName,
      notes,
    }: {
      expenseId: string;
      reviewerId: string;
      reviewerName: string;
      notes: string;
    }) => expenseService.leaderDeny(expenseId, reviewerId, reviewerName, notes),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: expenseKeys.lists() });
      queryClient.invalidateQueries({ queryKey: expenseKeys.detail(data.id) });
      queryClient.invalidateQueries({ queryKey: expenseKeys.history(data.id) });
    },
  });
}

/**
 * Hook for treasury to approve payment
 */
export function useTreasuryApproveExpense() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      expenseId,
      reviewerId,
      reviewerName,
      notes,
    }: {
      expenseId: string;
      reviewerId: string;
      reviewerName: string;
      notes?: string;
    }) => expenseService.treasuryApprove(expenseId, reviewerId, reviewerName, notes),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: expenseKeys.lists() });
      queryClient.invalidateQueries({ queryKey: expenseKeys.detail(data.id) });
      queryClient.invalidateQueries({ queryKey: expenseKeys.history(data.id) });
      queryClient.invalidateQueries({
        queryKey: expenseKeys.pendingTreasury(data.organization_id),
      });
    },
  });
}

/**
 * Hook for treasury to deny payment
 */
export function useTreasuryDenyExpense() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      expenseId,
      reviewerId,
      reviewerName,
      notes,
    }: {
      expenseId: string;
      reviewerId: string;
      reviewerName: string;
      notes: string;
    }) => expenseService.treasuryDeny(expenseId, reviewerId, reviewerName, notes),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: expenseKeys.lists() });
      queryClient.invalidateQueries({ queryKey: expenseKeys.detail(data.id) });
      queryClient.invalidateQueries({ queryKey: expenseKeys.history(data.id) });
    },
  });
}

/**
 * Hook for finance to process payment
 */
export function useFinanceProcessExpense() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      expenseId,
      processorId,
      processorName,
      paymentReference,
      notes,
    }: {
      expenseId: string;
      processorId: string;
      processorName: string;
      paymentReference: string;
      notes?: string;
    }) =>
      expenseService.financeProcess(
        expenseId,
        processorId,
        processorName,
        paymentReference,
        notes
      ),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: expenseKeys.lists() });
      queryClient.invalidateQueries({ queryKey: expenseKeys.detail(data.id) });
      queryClient.invalidateQueries({ queryKey: expenseKeys.history(data.id) });
      queryClient.invalidateQueries({
        queryKey: expenseKeys.pendingFinance(data.organization_id),
      });
      queryClient.invalidateQueries({
        queryKey: expenseKeys.statistics(data.organization_id),
      });
      // Invalidate budget summaries since money was spent
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
 * Hook to cancel an expense request
 */
export function useCancelExpense() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      expenseId,
      actorId,
      actorName,
      reason,
    }: {
      expenseId: string;
      actorId: string;
      actorName: string;
      reason: string;
    }) => expenseService.cancel(expenseId, actorId, actorName, reason),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: expenseKeys.lists() });
      queryClient.invalidateQueries({ queryKey: expenseKeys.detail(data.id) });
      queryClient.invalidateQueries({ queryKey: expenseKeys.history(data.id) });
    },
  });
}
