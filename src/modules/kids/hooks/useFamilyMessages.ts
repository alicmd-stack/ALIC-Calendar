/**
 * Messages to families: the audience counts, the sent list, and sending.
 */

import { useMutation, useQuery, useQueryClient, keepPreviousData } from "@tanstack/react-query";
import { familyMessageService, type SendFamilyMessage } from "../services/familyMessageService";

export const familyMessageKeys = {
  all: ["church", "kids", "family-messages"] as const,
  audience: (orgId: string, days: number | null) =>
    [...familyMessageKeys.all, "audience", orgId, days ?? "all"] as const,
  sent: (orgId: string) => [...familyMessageKeys.all, "sent", orgId] as const,
};

export function useMessageAudience(organizationId: string | undefined, cameWithinDays: number | null) {
  return useQuery({
    queryKey: familyMessageKeys.audience(organizationId ?? "none", cameWithinDays),
    queryFn: () => familyMessageService.audience(organizationId!, cameWithinDays),
    enabled: !!organizationId,
    staleTime: 60_000,
    // Changing the reach keeps the old counts, dimmed, until the new arrive.
    placeholderData: keepPreviousData,
  });
}

export function useSentMessages(organizationId: string | undefined) {
  return useQuery({
    queryKey: familyMessageKeys.sent(organizationId ?? "none"),
    queryFn: () => familyMessageService.sent(organizationId!),
    enabled: !!organizationId,
    // While a message is still going out, its progress is worth watching.
    refetchInterval: (query) =>
      (query.state.data ?? []).some((m) => m.pending > 0) ? 10_000 : false,
  });
}

export function useSendFamilyMessage(organizationId: string | undefined) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (message: SendFamilyMessage) => familyMessageService.send(organizationId!, message),
    onSuccess: (_result, message) => {
      if (!message.test) {
        qc.invalidateQueries({ queryKey: familyMessageKeys.sent(organizationId ?? "none") });
      }
    },
  });
}
