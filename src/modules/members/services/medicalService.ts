/**
 * Reading and writing church.person_sensitive.
 *
 * Restricted to members_admin and kids_admin by RLS on the read and by an
 * explicit check in the RPC on the write. Both are recorded in
 * church.check_in_audit — the audit trail is the whole basis on which admins
 * were given access to children's medical data.
 */

import { supabase } from "@/integrations/supabase/client";

const church = () => supabase.schema("church");

export interface MedicalRecord {
  allergy_severity: string | null;
  allergies: string | null;
  allergy_label_short: string | null;
  medications: string | null;
  medical_notes: string | null;
  special_needs: string | null;
  photo_consent: boolean | null;
  updated_by_name?: string | null;
  updated_at?: string | null;
}

export const medicalService = {
  /** Null when nothing is on file, which is a meaningful answer in itself. */
  async get(personId: string): Promise<MedicalRecord | null> {
    const { data, error } = await church()
      .from("person_sensitive")
      .select("*")
      .eq("person_id", personId)
      .maybeSingle();
    if (error) throw error;
    return (data as unknown as MedicalRecord) ?? null;
  },

  async save(personId: string, record: MedicalRecord): Promise<MedicalRecord> {
    const { data, error } = await church().rpc("upsert_person_sensitive", {
      _person_id: personId,
      _allergy_severity: record.allergy_severity ?? "none",
      _allergies: record.allergies || null,
      _allergy_label_short: record.allergy_label_short || null,
      _medications: record.medications || null,
      _medical_notes: record.medical_notes || null,
      _special_needs: record.special_needs || null,
      _photo_consent: record.photo_consent ?? false,
    });
    if (error) throw error;
    return data as unknown as MedicalRecord;
  },

  /**
   * A child already in a room is wearing a tag printed before this edit.
   * check_in_one_child snapshots the allergy flag deliberately, so a later
   * edit cannot rewrite the history of a past Sunday — but for a child still
   * in the room, the volunteers with them should see the new information.
   *
   * Returns how many live check-ins were updated.
   */
  async refreshLiveCheckIns(personId: string): Promise<number> {
    const { data, error } = await church().rpc("refresh_child_allergy_flags", {
      _person_id: personId,
    });
    if (error) throw error;
    return (data as unknown as number) ?? 0;
  },
};
