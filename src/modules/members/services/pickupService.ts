/**
 * Who may and may not collect a child.
 *
 * These two lists are what the entire checkout gate is built on, and until now
 * they could only be edited in Supabase Studio — which does not require the
 * restricted person's id, and that is exactly how name-only orders became the
 * norm. A name-only order is enforced far more bluntly (it switches off the
 * household route entirely), so recording the person properly matters.
 */

import { supabase } from "@/integrations/supabase/client";

const church = () => supabase.schema("church");

export interface PickupPermission {
  id: string;
  kind: "authorized" | "restricted";
  person_id: string | null;
  display_name: string;
  phone: string | null;
  note: string | null;
  effective_from: string;
  /** An order with no member record — weaker, and worth fixing. */
  is_name_only: boolean;
  created_by_name: string | null;
}

export const pickupService = {
  async list(childPersonId: string): Promise<PickupPermission[]> {
    const { data, error } = await church().rpc("child_pickup_permissions", {
      _child_person_id: childPersonId,
    });
    if (error) throw error;
    return (data ?? []) as unknown as PickupPermission[];
  },

  async authorize(childPersonId: string, personId: string, note?: string) {
    const { error } = await church().rpc("authorize_pickup", {
      _child_person_id: childPersonId,
      _person_id: personId,
      _note: note || null,
    });
    if (error) throw error;
  },

  /**
   * Pass a personId whenever the person has a member record. A name is
   * accepted for an estranged parent the church has never enrolled, but the
   * database then has to treat the whole household as suspect, because it
   * cannot tell which adult the name refers to.
   */
  async restrict(params: {
    childPersonId: string;
    personId?: string | null;
    personName?: string | null;
    reason?: string | null;
  }) {
    const { error } = await church().rpc("restrict_pickup", {
      _child_person_id: params.childPersonId,
      _person_id: params.personId ?? null,
      _person_name: params.personName ?? null,
      _reason: params.reason ?? null,
    });
    if (error) throw error;
  },

  /** Ends it; the row survives, because "who lifted this order" gets asked. */
  async end(id: string, kind: "authorized" | "restricted") {
    const { error } = await church().rpc("end_pickup_permission", {
      _id: id,
      _kind: kind,
    });
    if (error) throw error;
  },
};
