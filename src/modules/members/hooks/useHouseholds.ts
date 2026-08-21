/**
 * Household and family-relationship hooks.
 */

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { householdService, relationshipService } from "../services";
import type {
  HouseholdInsert,
  HouseholdUpdate,
  PersonRelationshipInsert,
} from "../types";
import { memberKeys } from "./useMembers";

export const householdKeys = {
  all: ["church", "households"] as const,
  lists: () => [...householdKeys.all, "list"] as const,
  list: (orgId: string) => [...householdKeys.lists(), orgId] as const,
  details: () => [...householdKeys.all, "detail"] as const,
  detail: (id: string) => [...householdKeys.details(), id] as const,
  withMembers: (id: string) => [...householdKeys.details(), id, "members"] as const,
};

export const relationshipKeys = {
  all: ["church", "relationships"] as const,
  forMember: (memberId: string) => [...relationshipKeys.all, memberId] as const,
};

export function useHouseholds(organizationId: string | undefined) {
  return useQuery({
    queryKey: householdKeys.list(organizationId || ""),
    queryFn: () => householdService.list(organizationId!),
    enabled: !!organizationId,
  });
}

export function useHousehold(householdId: string | undefined) {
  return useQuery({
    queryKey: householdKeys.detail(householdId || ""),
    queryFn: () => householdService.get(householdId!),
    enabled: !!householdId,
  });
}

export function useHouseholdWithMembers(householdId: string | undefined) {
  return useQuery({
    queryKey: householdKeys.withMembers(householdId || ""),
    queryFn: () => householdService.getWithMembers(householdId!),
    enabled: !!householdId,
  });
}

export function useCreateHousehold() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (household: HouseholdInsert) => householdService.create(household),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: householdKeys.list(data.organization_id) });
    },
  });
}

export function useUpdateHousehold() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ householdId, data }: { householdId: string; data: HouseholdUpdate }) =>
      householdService.update(householdId, data),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: householdKeys.lists() });
      queryClient.invalidateQueries({ queryKey: householdKeys.detail(data.id) });
      queryClient.invalidateQueries({ queryKey: householdKeys.withMembers(data.id) });
    },
  });
}

export function useAddHouseholdMember() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (params: {
      organizationId: string;
      householdId: string;
      personId: string;
      householdRole: string;
      isPrimaryHousehold?: boolean;
    }) => householdService.addMember(params),
    onSuccess: (_result, vars) => {
      queryClient.invalidateQueries({ queryKey: householdKeys.withMembers(vars.householdId) });
      queryClient.invalidateQueries({ queryKey: memberKeys.byHousehold(vars.householdId) });
      queryClient.invalidateQueries({ queryKey: memberKeys.profile(vars.personId) });
    },
  });
}

/** Ends the membership rather than deleting it, so history survives a move. */
export function useEndHouseholdMembership() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ householdMemberId }: { householdMemberId: string; householdId: string }) =>
      householdService.endMembership(householdMemberId),
    onSuccess: (_result, vars) => {
      queryClient.invalidateQueries({ queryKey: householdKeys.withMembers(vars.householdId) });
      queryClient.invalidateQueries({ queryKey: memberKeys.byHousehold(vars.householdId) });
    },
  });
}

export function useSetPrimaryContact() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ householdId, personId }: { householdId: string; personId: string }) =>
      householdService.setPrimaryContact(householdId, personId),
    onSuccess: (_result, vars) => {
      queryClient.invalidateQueries({ queryKey: householdKeys.withMembers(vars.householdId) });
    },
  });
}

export function useMemberRelationships(memberId: string | undefined) {
  return useQuery({
    queryKey: relationshipKeys.forMember(memberId || ""),
    queryFn: () => relationshipService.listForMember(memberId!),
    enabled: !!memberId,
  });
}

/**
 * Creates ONE edge. The database writes the inverse automatically, so both
 * sides are invalidated even though only one row was inserted.
 */
export function useCreateRelationship() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (relationship: PersonRelationshipInsert) =>
      relationshipService.create(relationship),
    onSuccess: (_result, vars) => {
      queryClient.invalidateQueries({ queryKey: relationshipKeys.forMember(vars.person_id) });
      queryClient.invalidateQueries({
        queryKey: relationshipKeys.forMember(vars.related_person_id),
      });
      queryClient.invalidateQueries({ queryKey: memberKeys.profile(vars.person_id) });
      queryClient.invalidateQueries({ queryKey: memberKeys.profile(vars.related_person_id) });
    },
  });
}

export function useDeleteRelationship() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ relationshipId }: { relationshipId: string; memberId: string }) =>
      relationshipService.delete(relationshipId),
    onSuccess: (_result, vars) => {
      queryClient.invalidateQueries({ queryKey: relationshipKeys.forMember(vars.memberId) });
      queryClient.invalidateQueries({ queryKey: memberKeys.profile(vars.memberId) });
    },
  });
}
