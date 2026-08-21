/**
 * Whether this user must replace their password before doing anything else.
 *
 * Set on `public.profiles` when a kids-leadership invitation is redeemed,
 * because everyone who arrives that way was handed a starter password by
 * somebody else — and in ALIC's case, the same starter password as five other
 * people, on accounts that can read a child's medical record.
 *
 * FAILS OPEN, deliberately. If the flag cannot be read — offline, RLS
 * surprise, a profile row that does not exist yet — the answer is "not
 * required". The alternative is a volunteer locked out of the check-in desk at
 * 10:15 on a Sunday by a failed lookup, which is a worse outcome than a
 * password change happening a week late.
 */

import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/shared/contexts/AuthContext";

export function usePasswordChangeRequired() {
  const { user } = useAuth();

  const { data, isLoading, refetch } = useQuery({
    queryKey: ["password-change-required", user?.id],
    enabled: !!user?.id,
    // The answer only changes when the user acts on it, and the mutation
    // refetches. No need to poll a flag.
    staleTime: Infinity,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("profiles")
        .select("must_change_password")
        .eq("id", user!.id)
        .maybeSingle();
      if (error) return false;
      return !!data?.must_change_password;
    },
  });

  return {
    required: data === true,
    loading: isLoading,
    recheck: refetch,
  };
}
