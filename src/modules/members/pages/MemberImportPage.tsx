/**
 * Member CSV import wizard.
 *
 * Upload → map columns → preview → commit. Nothing reaches church.people
 * until the final step, and the preview is mandatory — the database refuses a
 * commit on a batch that has not been dry-run.
 */

import { useCallback, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import Papa from "papaparse";
import DashboardLayout from "@/shared/components/layout/DashboardLayout";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/shared/components/ui/card";
import { Button } from "@/shared/components/ui/button";
import { Badge } from "@/shared/components/ui/badge";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/shared/components/ui/table";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/shared/components/ui/select";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/shared/components/ui/tabs";
import { Checkbox } from "@/shared/components/ui/checkbox";
import {
  ArrowLeft,
  Upload,
  FileSpreadsheet,
  Loader2,
  CheckCircle2,
  AlertTriangle,
  XCircle,
  UserPlus,
  RefreshCw,
  Download,
} from "lucide-react";
import { useToast } from "@/shared/hooks/use-toast";
import { useOrganization } from "@/shared/contexts/OrganizationContext";
import { useUserProfile } from "@/hooks/useUserProfile";
import {
  useStageImport,
  useDryRunImport,
  useCommitImport,
  useImportRows,
  useSetRowInclude,
  importErrorMessage,
  type ImportSummary,
} from "../hooks/useMemberImport";
import {
  autoMapColumns,
  applyMapping,
  stripBOM,
  IMPORT_TARGETS,
  TARGET_LABELS,
  IGNORE,
  type ColumnMapping,
  type MappingValue,
} from "../utils/csvMapping";
import { toCSV, downloadFile, getDateStamp } from "@/shared/lib/exportPrimitives";

type Step = "upload" | "map" | "preview" | "done";

const MAX_ROWS = 20000;

export default function MemberImportPage() {
  const navigate = useNavigate();
  const { toast } = useToast();
  const { currentOrganization } = useOrganization();
  const { profile } = useUserProfile();
  const orgId = currentOrganization?.id;
  const fileInput = useRef<HTMLInputElement>(null);

  const [step, setStep] = useState<Step>("upload");
  const [filename, setFilename] = useState("");
  const [headers, setHeaders] = useState<string[]>([]);
  const [rawRows, setRawRows] = useState<Record<string, string>[]>([]);
  const [mapping, setMapping] = useState<ColumnMapping>({});
  const [batchId, setBatchId] = useState<string | null>(null);
  const [summary, setSummary] = useState<ImportSummary | null>(null);
  const [result, setResult] = useState<ImportSummary | null>(null);
  const [busy, setBusy] = useState(false);

  const stage = useStageImport();
  const dryRun = useDryRunImport();
  const commit = useCommitImport();
  const setInclude = useSetRowInclude();
  const rowsQuery = useImportRows(step === "preview" ? batchId ?? undefined : undefined);

  const mappedTargets = useMemo(
    () => new Set(Object.values(mapping).filter((v) => v !== IGNORE)),
    [mapping]
  );
  const hasRequired = mappedTargets.has("first_name") && mappedTargets.has("last_name");

  const handleFile = useCallback(
    (file: File) => {
      setFilename(file.name);
      const reader = new FileReader();

      reader.onload = () => {
        // Excel writes UTF-8 with a BOM; decode as UTF-8 and strip it. If the
        // result contains replacement characters the file is probably
        // windows-1252, which we surface rather than silently mangling names.
        const text = stripBOM(new TextDecoder("utf-8").decode(reader.result as ArrayBuffer));
        if (text.includes("�")) {
          toast({
            title: "Encoding problem",
            description:
              "Some characters could not be read. Re-save the file as “CSV UTF-8” from Excel and try again.",
            variant: "destructive",
          });
        }

        const parsed = Papa.parse<Record<string, string>>(text, {
          header: true,
          skipEmptyLines: "greedy",
          transformHeader: (h) => h.trim(),
        });

        const rows = (parsed.data ?? []).filter((r) =>
          Object.values(r).some((v) => (v ?? "").trim() !== "")
        );

        if (rows.length === 0) {
          toast({
            title: "Nothing to import",
            description: "That file has no data rows.",
            variant: "destructive",
          });
          return;
        }
        if (rows.length > MAX_ROWS) {
          toast({
            title: "File too large",
            description: `This file has ${rows.length} rows; the limit is ${MAX_ROWS}.`,
            variant: "destructive",
          });
          return;
        }

        const cols = (parsed.meta.fields ?? []).filter(Boolean);
        setHeaders(cols);
        setRawRows(rows);
        setMapping(autoMapColumns(cols));
        setStep("map");
      };

      reader.readAsArrayBuffer(file);
    },
    [toast]
  );

  const handleStageAndPreview = async () => {
    if (!orgId) return;
    setBusy(true);
    try {
      const batch = await stage.mutateAsync({
        organizationId: orgId,
        filename,
        columnMapping: mapping,
        rows: rawRows.map((raw) => ({ raw, parsed: applyMapping(raw, mapping) })),
        createdByName: profile?.full_name || "Import",
      });
      setBatchId(batch.id);
      const s = await dryRun.mutateAsync(batch.id);
      setSummary(s);
      setStep("preview");
    } catch (error) {
      toast({
        title: "Could not prepare the import",
        description: importErrorMessage(error),
        variant: "destructive",
      });
    } finally {
      setBusy(false);
    }
  };

  const handleCommit = async () => {
    if (!batchId) return;
    setBusy(true);
    try {
      const r = await commit.mutateAsync(batchId);
      setResult(r);
      setStep("done");
    } catch (error) {
      toast({
        title: "Import failed",
        description: importErrorMessage(error),
        variant: "destructive",
      });
    } finally {
      setBusy(false);
    }
  };

  /** Errors go back to the office as a CSV they can fix in Excel and re-upload. */
  const downloadErrors = () => {
    const errored = (rowsQuery.data ?? []).filter((r) => r.status === "error");
    if (errored.length === 0) return;
    const csv = toCSV(
      ["Row", "First name", "Last name", "Email", "Phone", "Problem"],
      errored.map((r) => [
        r.row_number,
        r.parsed.first_name ?? "",
        r.parsed.last_name ?? "",
        r.parsed.email ?? "",
        r.parsed.phone ?? "",
        (r.errors ?? []).join("; "),
      ])
    );
    downloadFile(csv, `import-errors-${getDateStamp()}.csv`, "text/csv");
  };

  const rows = rowsQuery.data ?? [];
  const byStatus = (s: string) => rows.filter((r) => r.status === s);

  return (
    <DashboardLayout>
      <div className="space-y-5 max-w-5xl">
        <div className="flex items-start gap-3">
          <Button
            variant="ghost"
            size="icon"
            onClick={() => navigate("/members")}
            aria-label="Back to members"
          >
            <ArrowLeft className="h-4 w-4" />
          </Button>
          <div className="p-2 rounded-xl bg-primary/10">
            <FileSpreadsheet className="h-6 w-6 text-primary" />
          </div>
          <div>
            <h1 className="text-2xl sm:text-3xl font-bold">Import members</h1>
            <p className="text-sm text-muted-foreground mt-1">
              Nothing is saved until you approve the preview.
            </p>
          </div>
        </div>

        <Steps current={step} />

        {step === "upload" && (
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Choose a CSV file</CardTitle>
              <CardDescription className="text-xs">
                In Excel, use <strong>File → Save As → CSV UTF-8 (Comma delimited)</strong>.
                That encoding matters for Amharic and accented names.
              </CardDescription>
            </CardHeader>
            <CardContent>
              <div
                className="rounded-lg border-2 border-dashed p-10 text-center cursor-pointer hover:bg-muted/40"
                onClick={() => fileInput.current?.click()}
                onDragOver={(e) => e.preventDefault()}
                onDrop={(e) => {
                  e.preventDefault();
                  const f = e.dataTransfer.files?.[0];
                  if (f) handleFile(f);
                }}
              >
                <Upload className="h-10 w-10 mx-auto text-muted-foreground" />
                <p className="mt-3 text-sm font-medium">
                  Drop a CSV here, or click to browse
                </p>
                <p className="text-xs text-muted-foreground mt-1">
                  Up to {MAX_ROWS.toLocaleString()} rows
                </p>
              </div>
              <input
                ref={fileInput}
                type="file"
                accept=".csv,text/csv"
                className="hidden"
                onChange={(e) => {
                  const f = e.target.files?.[0];
                  if (f) handleFile(f);
                  e.target.value = "";
                }}
              />
            </CardContent>
          </Card>
        )}

        {step === "map" && (
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Match your columns</CardTitle>
              <CardDescription className="text-xs">
                {filename} · {rawRows.length} rows. Anything left as “Don’t import” is
                ignored — unrecognised headers are never guessed at.
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-4">
              <div className="rounded-md border overflow-x-auto">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Column in your file</TableHead>
                      <TableHead>Example value</TableHead>
                      <TableHead className="w-[220px]">Import as</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {headers.map((h) => (
                      <TableRow key={h}>
                        <TableCell className="font-medium">{h}</TableCell>
                        <TableCell className="text-muted-foreground text-xs truncate max-w-[220px]">
                          {rawRows.find((r) => (r[h] ?? "").trim())?.[h] ?? "—"}
                        </TableCell>
                        <TableCell>
                          <Select
                            value={mapping[h] ?? IGNORE}
                            onValueChange={(v) =>
                              setMapping((m) => ({ ...m, [h]: v as MappingValue }))
                            }
                          >
                            <SelectTrigger>
                              <SelectValue />
                            </SelectTrigger>
                            <SelectContent>
                              <SelectItem value={IGNORE}>Don’t import</SelectItem>
                              {IMPORT_TARGETS.map((t) => (
                                <SelectItem
                                  key={t}
                                  value={t}
                                  disabled={mappedTargets.has(t) && mapping[h] !== t}
                                >
                                  {TARGET_LABELS[t]}
                                </SelectItem>
                              ))}
                            </SelectContent>
                          </Select>
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>

              {!hasRequired && (
                <p className="text-sm text-amber-700 flex items-center gap-2">
                  <AlertTriangle className="h-4 w-4" />
                  First name and last name must both be mapped.
                </p>
              )}

              <div className="flex justify-end gap-2">
                <Button variant="outline" onClick={() => setStep("upload")}>
                  Back
                </Button>
                <Button onClick={handleStageAndPreview} disabled={!hasRequired || busy}>
                  {busy && <Loader2 className="h-4 w-4 mr-1 animate-spin" />}
                  Preview import
                </Button>
              </div>
            </CardContent>
          </Card>
        )}

        {step === "preview" && summary && (
          <div className="space-y-4">
            <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
              <Stat icon={<UserPlus className="h-4 w-4" />} label="New" value={summary.create} tone="text-green-700" />
              <Stat icon={<RefreshCw className="h-4 w-4" />} label="Updates" value={summary.update} tone="text-blue-700" />
              <Stat icon={<AlertTriangle className="h-4 w-4" />} label="Needs review" value={summary.conflict} tone="text-amber-700" />
              <Stat icon={<XCircle className="h-4 w-4" />} label="Errors" value={summary.error} tone="text-red-700" />
            </div>

            <Card>
              <CardHeader className="pb-3">
                <CardTitle className="text-base">Preview</CardTitle>
                <CardDescription className="text-xs">
                  Nothing has been written yet. Rows marked “needs review” or “error”
                  are never applied automatically.
                </CardDescription>
              </CardHeader>
              <CardContent>
                <Tabs defaultValue="create">
                  <TabsList>
                    <TabsTrigger value="create">New ({summary.create ?? 0})</TabsTrigger>
                    <TabsTrigger value="update">Updates ({summary.update ?? 0})</TabsTrigger>
                    <TabsTrigger value="conflict">Review ({summary.conflict ?? 0})</TabsTrigger>
                    <TabsTrigger value="error">Errors ({summary.error ?? 0})</TabsTrigger>
                  </TabsList>

                  {(["create", "update", "conflict", "error"] as const).map((s) => (
                    <TabsContent key={s} value={s} className="mt-3">
                      {rowsQuery.isLoading ? (
                        <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
                      ) : byStatus(s).length === 0 ? (
                        <p className="text-sm text-muted-foreground py-6 text-center">
                          Nothing in this category.
                        </p>
                      ) : (
                        <div className="space-y-2">
                          {s === "error" && (
                            <Button variant="outline" size="sm" onClick={downloadErrors}>
                              <Download className="h-3.5 w-3.5 mr-1" />
                              Download errors as CSV
                            </Button>
                          )}
                          <ul className="divide-y">
                            {byStatus(s).map((r) => (
                              <li key={r.id} className="py-2 text-sm">
                                <div className="flex items-start justify-between gap-3">
                                  <div>
                                    <span className="font-medium">
                                      {r.parsed.first_name} {r.parsed.last_name}
                                    </span>
                                    <span className="text-muted-foreground text-xs ml-2">
                                      row {r.row_number}
                                    </span>
                                    {r.match_reason && (
                                      <p className="text-xs text-muted-foreground mt-0.5">
                                        {r.match_reason}
                                      </p>
                                    )}
                                    {r.errors?.length > 0 && (
                                      <p className="text-xs text-red-600 mt-0.5">
                                        {r.errors.join("; ")}
                                      </p>
                                    )}
                                    {r.diff && r.diff.length > 0 && (
                                      <ul className="mt-1 space-y-0.5">
                                        {r.diff.map((d) => (
                                          <li key={d.field} className="text-xs">
                                            <span className="text-muted-foreground">
                                              {d.field}:
                                            </span>{" "}
                                            <span className="line-through text-muted-foreground">
                                              {d.current || "—"}
                                            </span>{" "}
                                            → <span className="font-medium">{d.incoming}</span>
                                          </li>
                                        ))}
                                      </ul>
                                    )}
                                  </div>
                                  {(s === "create" || s === "update") && (
                                    <label className="flex items-center gap-1.5 text-xs shrink-0">
                                      <Checkbox
                                        checked={r.include}
                                        onCheckedChange={(v) =>
                                          setInclude.mutate({
                                            rowId: r.id,
                                            include: !!v,
                                          })
                                        }
                                      />
                                      Include
                                    </label>
                                  )}
                                </div>
                              </li>
                            ))}
                          </ul>
                        </div>
                      )}
                    </TabsContent>
                  ))}
                </Tabs>
              </CardContent>
            </Card>

            <div className="flex justify-end gap-2 pb-8">
              <Button variant="outline" onClick={() => setStep("map")} disabled={busy}>
                Back to mapping
              </Button>
              <Button
                onClick={handleCommit}
                disabled={busy || ((summary.create ?? 0) + (summary.update ?? 0) === 0)}
              >
                {busy && <Loader2 className="h-4 w-4 mr-1 animate-spin" />}
                Import {(summary.create ?? 0) + (summary.update ?? 0)} rows
              </Button>
            </div>
          </div>
        )}

        {step === "done" && result && (
          <Card>
            <CardHeader className="text-center p-6">
              <CheckCircle2 className="h-12 w-12 mx-auto text-green-600" />
              <CardTitle className="mt-3 text-lg">Import complete</CardTitle>
              <CardDescription>
                {result.created ?? 0} created · {result.updated ?? 0} updated ·{" "}
                {result.skipped ?? 0} skipped
              </CardDescription>
            </CardHeader>
            <CardContent className="flex justify-center gap-2">
              <Button variant="outline" onClick={() => window.location.reload()}>
                Import another file
              </Button>
              <Button onClick={() => navigate("/members")}>View directory</Button>
            </CardContent>
          </Card>
        )}
      </div>
    </DashboardLayout>
  );
}

function Steps({ current }: { current: Step }) {
  const steps: { key: Step; label: string }[] = [
    { key: "upload", label: "Upload" },
    { key: "map", label: "Match columns" },
    { key: "preview", label: "Preview" },
    { key: "done", label: "Done" },
  ];
  const idx = steps.findIndex((s) => s.key === current);
  return (
    <div className="flex items-center gap-2 text-xs">
      {steps.map((s, i) => (
        <div key={s.key} className="flex items-center gap-2">
          <Badge variant={i <= idx ? "default" : "outline"}>{i + 1}</Badge>
          <span className={i <= idx ? "font-medium" : "text-muted-foreground"}>
            {s.label}
          </span>
          {i < steps.length - 1 && <span className="text-muted-foreground">›</span>}
        </div>
      ))}
    </div>
  );
}

function Stat({
  icon,
  label,
  value,
  tone,
}: {
  icon: React.ReactNode;
  label: string;
  value: number | undefined;
  tone: string;
}) {
  return (
    <Card>
      <CardContent className="p-4">
        <div className="flex items-center gap-2 text-xs text-muted-foreground">
          {icon}
          {label}
        </div>
        <div className={`mt-1 text-2xl font-semibold ${tone}`}>{value ?? 0}</div>
      </CardContent>
    </Card>
  );
}
