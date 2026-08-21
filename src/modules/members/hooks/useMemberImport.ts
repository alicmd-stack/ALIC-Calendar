/**
 * Member CSV import.
 *
 * Rows are staged into church.import_rows first; church.people is not touched
 * until commit. The dry run classifies every row and computes a field-level
 * diff so the reviewer can see exactly what would change.
 */

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { memberKeys } from "./useMembers";
import type { ParsedRow } from "../utils/csvMapping";

const church = () => supabase.schema("church");

/** Rows per insert. Keeps a large spreadsheet under the request size limit. */
const STAGE_CHUNK = 200;

export const importKeys = {
  all: ["church", "import"] as const,
  batches: (orgId: string) => [...importKeys.all, "batches", orgId] as const,
  batch: (batchId: string) => [...importKeys.all, "batch", batchId] as const,
  rows: (batchId: string, status?: string) =>
    [...importKeys.all, "rows", batchId, status ?? "all"] as const,
};

export interface ImportSummary {
  create?: number;
  update?: number;
  conflict?: number;
  error?: number;
  total?: number;
  created?: number;
  updated?: number;
  skipped?: number;
}

export interface ImportRowRecord {
  id: string;
  row_number: number;
  status: string;
  match_person_id: string | null;
  match_reason: string | null;
  diff: { field: string; current: string | null; incoming: string | null }[] | null;
  errors: string[];
  parsed: ParsedRow;
  include: boolean;
}

export function useImportBatches(organizationId: string | undefined) {
  return useQuery({
    queryKey: importKeys.batches(organizationId || ""),
    queryFn: async () => {
      const { data, error } = await church()
        .from("import_batches")
        .select("*")
        .eq("organization_id", organizationId!)
        .order("created_at", { ascending: false })
        .limit(20);
      if (error) throw error;
      return data ?? [];
    },
    enabled: !!organizationId,
  });
}

export function useImportRows(batchId: string | undefined, status?: string) {
  return useQuery({
    queryKey: importKeys.rows(batchId || "", status),
    queryFn: async (): Promise<ImportRowRecord[]> => {
      let q = church()
        .from("import_rows")
        .select("*")
        .eq("batch_id", batchId!)
        .order("row_number");
      if (status) q = q.eq("status", status);
      const { data, error } = await q;
      if (error) throw error;
      return (data ?? []) as unknown as ImportRowRecord[];
    },
    enabled: !!batchId,
  });
}

/** Creates the batch and stages every row. Writes nothing to church.people. */
export function useStageImport() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (input: {
      organizationId: string;
      filename: string;
      columnMapping: Record<string, string>;
      rows: { raw: Record<string, string>; parsed: ParsedRow }[];
      createdByName: string;
    }) => {
      const { data: batch, error: batchError } = await church()
        .from("import_batches")
        .insert({
          organization_id: input.organizationId,
          filename: input.filename,
          row_count: input.rows.length,
          column_mapping: input.columnMapping as never,
          created_by_name: input.createdByName,
        })
        .select()
        .single();
      if (batchError) throw batchError;

      for (let i = 0; i < input.rows.length; i += STAGE_CHUNK) {
        const chunk = input.rows.slice(i, i + STAGE_CHUNK).map((r, j) => ({
          batch_id: batch.id,
          organization_id: input.organizationId,
          row_number: i + j + 1,
          raw: r.raw as never,
          parsed: r.parsed as never,
        }));
        const { error } = await church().from("import_rows").insert(chunk);
        if (error) throw error;
      }

      return batch;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: importKeys.all });
    },
  });
}

export function useDryRunImport() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (batchId: string): Promise<ImportSummary> => {
      const { data, error } = await church().rpc("import_dry_run", {
        _batch_id: batchId,
      });
      if (error) throw error;
      return (data ?? {}) as ImportSummary;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: importKeys.all });
    },
  });
}

export function useCommitImport() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (batchId: string): Promise<ImportSummary> => {
      const { data, error } = await church().rpc("import_commit", {
        _batch_id: batchId,
      });
      if (error) throw error;
      return (data ?? {}) as ImportSummary;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: importKeys.all });
      // The directory has genuinely changed now.
      queryClient.invalidateQueries({ queryKey: memberKeys.all });
    },
  });
}

/** Include / exclude a single staged row before committing. */
export function useSetRowInclude() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ rowId, include }: { rowId: string; include: boolean }) => {
      const { error } = await church()
        .from("import_rows")
        .update({ include })
        .eq("id", rowId);
      if (error) throw error;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: importKeys.all });
    },
  });
}

export function importErrorMessage(error: unknown): string {
  const raw = error instanceof Error ? error.message : String(error);
  const known: Record<string, string> = {
    not_permitted: "You do not have permission to import members.",
    batch_not_found: "That import batch no longer exists.",
    batch_already_committed: "This import has already been committed.",
    dry_run_required_before_commit:
      "Run the preview before committing — that check is not optional.",
  };
  for (const [code, message] of Object.entries(known)) {
    if (raw.includes(code)) return message;
  }
  return raw;
}
