/**
 * Utility to manually create budget allocations from approved allocation requests
 * This is a temporary solution until the automatic process is fixed
 */

import { supabase } from "@/integrations/supabase/client";

export const createBudgetAllocationFromRequest = async (requestId: string) => {
  try {
    // Get the allocation request details
    const { data: request, error: requestError } = await supabase
      .from("allocation_requests")
      .select(
        `
        id,
        organization_id,
        ministry_id,
        fiscal_year_id,
        approved_amount,
        status
      `
      )
      .eq("id", requestId)
      .single();

    if (requestError) {
      console.error("Error fetching allocation request:", requestError);
      return { success: false, error: requestError.message };
    }

    if (!request) {
      return { success: false, error: "Allocation request not found" };
    }

    if (
      request.status !== "approved" &&
      request.status !== "partially_approved"
    ) {
      return { success: false, error: "Request is not approved" };
    }

    if (!request.approved_amount || request.approved_amount <= 0) {
      return { success: false, error: "No approved amount found" };
    }

    // Create budget allocation
    const { data: allocation, error: allocationError } = await supabase
      .schema("budget")
      .from("budget_allocations")
      .upsert(
        {
          organization_id: request.organization_id,
          ministry_id: request.ministry_id,
          fiscal_year_id: request.fiscal_year_id,
          allocated_amount: request.approved_amount,
          created_by: request.organization_id, // Use org ID as fallback
          updated_at: new Date().toISOString(),
        },
        {
          onConflict: "organization_id,ministry_id,fiscal_year_id",
        }
      )
      .select()
      .single();

    if (allocationError) {
      console.error("Error creating budget allocation:", allocationError);
      return { success: false, error: allocationError.message };
    }

    return {
      success: true,
      allocation,
      message: `Budget allocation of $${request.approved_amount} created successfully`,
    };
  } catch (error) {
    console.error("Unexpected error:", error);
    return {
      success: false,
      error: error instanceof Error ? error.message : "Unexpected error",
    };
  }
};

/**
 * Convert all approved allocation requests to budget allocations
 */
export const createAllMissingBudgetAllocations = async (
  organizationId: string,
  fiscalYearId: string
) => {
  try {
    // Get all approved allocation requests for the org/fiscal year
    const { data: requests, error: requestsError } = await supabase
      .from("allocation_requests")
      .select(
        `
        id,
        organization_id,
        ministry_id,
        fiscal_year_id,
        approved_amount,
        status
      `
      )
      .eq("organization_id", organizationId)
      .eq("fiscal_year_id", fiscalYearId)
      .in("status", ["approved", "partially_approved"])
      .gt("approved_amount", 0);

    if (requestsError) {
      return { success: false, error: requestsError.message };
    }

    if (!requests || requests.length === 0) {
      return { success: true, message: "No approved requests to process" };
    }

    const results = [];
    for (const request of requests) {
      const result = await createBudgetAllocationFromRequest(request.id);
      results.push({ requestId: request.id, ...result });
    }

    const successful = results.filter((r) => r.success).length;
    const failed = results.filter((r) => !r.success).length;

    return {
      success: true,
      message: `Processed ${requests.length} requests: ${successful} successful, ${failed} failed`,
      results,
    };
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : "Unexpected error",
    };
  }
};
