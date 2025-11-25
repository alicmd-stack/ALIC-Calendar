/**
 * Hook for fetching and managing events
 */

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { eventService } from "../services";
import type { EventFilters, EventFormData, EventStatus } from "../types";

// Query keys
export const eventKeys = {
  all: ["events"] as const,
  lists: () => [...eventKeys.all, "list"] as const,
  list: (orgId: string, filters?: EventFilters) =>
    [...eventKeys.lists(), orgId, filters] as const,
  details: () => [...eventKeys.all, "detail"] as const,
  detail: (id: string) => [...eventKeys.details(), id] as const,
  public: (orgId: string, start: string, end: string) =>
    [...eventKeys.all, "public", orgId, start, end] as const,
};

/**
 * Hook to fetch events for an organization
 */
export function useEvents(organizationId: string | undefined, filters?: EventFilters) {
  return useQuery({
    queryKey: eventKeys.list(organizationId || "", filters),
    queryFn: () => eventService.list(organizationId!, filters),
    enabled: !!organizationId,
  });
}

/**
 * Hook to fetch a single event
 */
export function useEvent(eventId: string | undefined) {
  return useQuery({
    queryKey: eventKeys.detail(eventId || ""),
    queryFn: () => eventService.get(eventId!),
    enabled: !!eventId,
  });
}

/**
 * Hook to fetch public events
 */
export function usePublicEvents(
  organizationId: string | undefined,
  startDate: string,
  endDate: string
) {
  return useQuery({
    queryKey: eventKeys.public(organizationId || "", startDate, endDate),
    queryFn: () => eventService.listPublic(organizationId!, startDate, endDate),
    enabled: !!organizationId,
  });
}

/**
 * Hook to create an event
 */
export function useCreateEvent(organizationId: string, userId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (eventData: EventFormData) =>
      eventService.create(organizationId, userId, eventData),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: eventKeys.lists() });
    },
  });
}

/**
 * Hook to update an event
 */
export function useUpdateEvent() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({ eventId, data }: { eventId: string; data: Partial<EventFormData> }) =>
      eventService.update(eventId, data),
    onSuccess: (_, variables) => {
      queryClient.invalidateQueries({ queryKey: eventKeys.lists() });
      queryClient.invalidateQueries({ queryKey: eventKeys.detail(variables.eventId) });
    },
  });
}

/**
 * Hook to delete an event
 */
export function useDeleteEvent() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (eventId: string) => eventService.delete(eventId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: eventKeys.lists() });
    },
  });
}

/**
 * Hook to update event status
 */
export function useUpdateEventStatus() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      eventId,
      status,
      reviewerId,
      reviewerNotes,
    }: {
      eventId: string;
      status: EventStatus;
      reviewerId?: string;
      reviewerNotes?: string;
    }) => eventService.updateStatus(eventId, status, reviewerId, reviewerNotes),
    onSuccess: (_, variables) => {
      queryClient.invalidateQueries({ queryKey: eventKeys.lists() });
      queryClient.invalidateQueries({ queryKey: eventKeys.detail(variables.eventId) });
    },
  });
}

/**
 * Hook to submit event for review
 */
export function useSubmitForReview() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (eventId: string) => eventService.submitForReview(eventId),
    onSuccess: (_, eventId) => {
      queryClient.invalidateQueries({ queryKey: eventKeys.lists() });
      queryClient.invalidateQueries({ queryKey: eventKeys.detail(eventId) });
    },
  });
}

/**
 * Hook to approve an event
 */
export function useApproveEvent() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      eventId,
      reviewerId,
      notes,
    }: {
      eventId: string;
      reviewerId: string;
      notes?: string;
    }) => eventService.approve(eventId, reviewerId, notes),
    onSuccess: (_, variables) => {
      queryClient.invalidateQueries({ queryKey: eventKeys.lists() });
      queryClient.invalidateQueries({ queryKey: eventKeys.detail(variables.eventId) });
    },
  });
}

/**
 * Hook to reject an event
 */
export function useRejectEvent() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      eventId,
      reviewerId,
      notes,
    }: {
      eventId: string;
      reviewerId: string;
      notes: string;
    }) => eventService.reject(eventId, reviewerId, notes),
    onSuccess: (_, variables) => {
      queryClient.invalidateQueries({ queryKey: eventKeys.lists() });
      queryClient.invalidateQueries({ queryKey: eventKeys.detail(variables.eventId) });
    },
  });
}

/**
 * Hook to check for room conflicts
 */
export function useCheckConflicts() {
  return useMutation({
    mutationFn: ({
      roomId,
      startsAt,
      endsAt,
      excludeEventId,
    }: {
      roomId: string;
      startsAt: string;
      endsAt: string;
      excludeEventId?: string;
    }) => eventService.checkConflicts(roomId, startsAt, endsAt, excludeEventId),
  });
}
