/**
 * ExpenseDetailDialog - View expense request details including attachments
 */

import { useState, useEffect } from "react";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/shared/components/ui/dialog";
import { Button } from "@/shared/components/ui/button";
import { Separator } from "@/shared/components/ui/separator";
import {
  DollarSign,
  Calendar,
  User,
  Building2,
  CreditCard,
  FileText,
  Image as ImageIcon,
  Paperclip,
  ExternalLink,
  Download,
  Loader2,
  AlertCircle,
} from "lucide-react";
import { format } from "date-fns";
import { supabase } from "@/integrations/supabase/client";
import { ExpenseStatusBadge } from "./ExpenseStatusBadge";
import type { ExpenseRequestWithRelations, AttachmentData } from "../types";
import { REIMBURSEMENT_TYPE_LABELS } from "../types";

interface ExpenseDetailDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  expense: ExpenseRequestWithRelations | null;
}

interface AttachmentWithSignedUrl extends AttachmentData {
  signedUrl?: string;
  urlError?: boolean;
}

export function ExpenseDetailDialog({
  open,
  onOpenChange,
  expense,
}: ExpenseDetailDialogProps) {
  const [attachmentsWithUrls, setAttachmentsWithUrls] = useState<AttachmentWithSignedUrl[]>([]);
  const [loadingUrls, setLoadingUrls] = useState(false);

  // Generate signed URLs when dialog opens
  useEffect(() => {
    if (!open || !expense) {
      setAttachmentsWithUrls([]);
      return;
    }

    const rawAttachments = (expense.attachments as AttachmentData[]) || [];
    if (rawAttachments.length === 0) {
      setAttachmentsWithUrls([]);
      return;
    }

    const generateSignedUrls = async () => {
      setLoadingUrls(true);
      const updatedAttachments: AttachmentWithSignedUrl[] = [];

      for (const attachment of rawAttachments) {
        try {
          // Extract the file path - handle both old (full URL) and new (path only) formats
          let filePath = attachment.url || attachment.id;

          // If it's a full Supabase URL, extract just the path
          if (filePath.includes("supabase.co/storage")) {
            // Extract path after /expense-attachments/
            const match = filePath.match(/expense-attachments\/(.+)$/);
            if (match) {
              filePath = match[1];
            }
          }

          const { data, error } = await supabase.storage
            .from("expense-attachments")
            .createSignedUrl(filePath, 3600); // 1 hour expiry

          if (error) {
            console.error("Error creating signed URL:", error);
            updatedAttachments.push({ ...attachment, urlError: true });
          } else {
            updatedAttachments.push({ ...attachment, signedUrl: data.signedUrl });
          }
        } catch (error) {
          console.error("Error generating signed URL:", error);
          updatedAttachments.push({ ...attachment, urlError: true });
        }
      }

      setAttachmentsWithUrls(updatedAttachments);
      setLoadingUrls(false);
    };

    generateSignedUrls();
  }, [open, expense]);

  if (!expense) return null;

  // Format file size
  const formatFileSize = (bytes: number) => {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  };

  // Check if file is an image
  const isImageFile = (type: string) => type.startsWith("image/");

  const rawAttachments = (expense.attachments as AttachmentData[]) || [];

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-[600px] max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <DollarSign className="h-5 w-5" />
            Expense Details
          </DialogTitle>
          <DialogDescription>
            View the complete details of this expense request.
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-6">
          {/* Status and Amount Header */}
          <div className="flex items-center justify-between">
            <ExpenseStatusBadge status={expense.status} />
            <div className="text-right">
              <p className="text-2xl font-bold text-primary">
                ${Number(expense.amount).toLocaleString("en-US", {
                  minimumFractionDigits: 2,
                  maximumFractionDigits: 2,
                })}
              </p>
              <p className="text-sm text-muted-foreground">
                {REIMBURSEMENT_TYPE_LABELS[expense.reimbursement_type]}
              </p>
            </div>
          </div>

          <Separator />

          {/* Title and Description */}
          <div>
            <h3 className="font-semibold text-lg mb-2">{expense.title}</h3>
            {expense.description && (
              <p className="text-muted-foreground">{expense.description}</p>
            )}
          </div>

          <Separator />

          {/* Details Grid */}
          <div className="grid grid-cols-2 gap-4">
            <div className="flex items-start gap-3">
              <Building2 className="h-4 w-4 mt-0.5 text-muted-foreground" />
              <div>
                <p className="text-sm text-muted-foreground">Ministry</p>
                <p className="font-medium">{expense.ministry?.name || "-"}</p>
              </div>
            </div>

            <div className="flex items-start gap-3">
              <Calendar className="h-4 w-4 mt-0.5 text-muted-foreground" />
              <div>
                <p className="text-sm text-muted-foreground">Fiscal Year</p>
                <p className="font-medium">{expense.fiscal_year?.name || "-"}</p>
              </div>
            </div>

            <div className="flex items-start gap-3">
              <User className="h-4 w-4 mt-0.5 text-muted-foreground" />
              <div>
                <p className="text-sm text-muted-foreground">Requester</p>
                <p className="font-medium">{expense.requester_name}</p>
                {expense.requester_email && (
                  <p className="text-xs text-muted-foreground">{expense.requester_email}</p>
                )}
              </div>
            </div>

            <div className="flex items-start gap-3">
              <CreditCard className="h-4 w-4 mt-0.5 text-muted-foreground" />
              <div>
                <p className="text-sm text-muted-foreground">Payment Method</p>
                <p className="font-medium">
                  {REIMBURSEMENT_TYPE_LABELS[expense.reimbursement_type]}
                </p>
              </div>
            </div>

            <div className="flex items-start gap-3">
              <Calendar className="h-4 w-4 mt-0.5 text-muted-foreground" />
              <div>
                <p className="text-sm text-muted-foreground">Submitted</p>
                <p className="font-medium">
                  {format(new Date(expense.created_at), "MMM d, yyyy 'at' h:mm a")}
                </p>
              </div>
            </div>

            {expense.payment_reference && (
              <div className="flex items-start gap-3">
                <FileText className="h-4 w-4 mt-0.5 text-muted-foreground" />
                <div>
                  <p className="text-sm text-muted-foreground">Payment Reference</p>
                  <p className="font-medium">{expense.payment_reference}</p>
                </div>
              </div>
            )}
          </div>

          {/* Workflow Notes */}
          {(expense.leader_notes || expense.treasury_notes || expense.finance_notes) && (
            <>
              <Separator />
              <div className="space-y-3">
                <h4 className="font-medium flex items-center gap-2">
                  <FileText className="h-4 w-4" />
                  Workflow Notes
                </h4>

                {expense.leader_notes && (
                  <div className="bg-muted p-3 rounded-md">
                    <p className="text-xs text-muted-foreground mb-1">Leader Review</p>
                    <p className="text-sm">{expense.leader_notes}</p>
                  </div>
                )}

                {expense.treasury_notes && (
                  <div className="bg-muted p-3 rounded-md">
                    <p className="text-xs text-muted-foreground mb-1">Treasury Review</p>
                    <p className="text-sm">{expense.treasury_notes}</p>
                  </div>
                )}

                {expense.finance_notes && (
                  <div className="bg-muted p-3 rounded-md">
                    <p className="text-xs text-muted-foreground mb-1">Finance Processing</p>
                    <p className="text-sm">{expense.finance_notes}</p>
                  </div>
                )}
              </div>
            </>
          )}

          {/* Attachments */}
          {rawAttachments.length > 0 && (
            <>
              <Separator />
              <div className="space-y-3">
                <h4 className="font-medium flex items-center gap-2">
                  <Paperclip className="h-4 w-4" />
                  Attachments ({rawAttachments.length})
                </h4>

                {loadingUrls ? (
                  <div className="flex items-center justify-center py-4">
                    <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
                    <span className="ml-2 text-sm text-muted-foreground">Loading attachments...</span>
                  </div>
                ) : (
                  <div className="space-y-2">
                    {attachmentsWithUrls.map((attachment) => (
                      <div
                        key={attachment.id}
                        className="flex items-center justify-between p-3 bg-muted rounded-md"
                      >
                        <div className="flex items-center gap-3 min-w-0">
                          {isImageFile(attachment.type) ? (
                            <ImageIcon className="h-5 w-5 text-blue-500 flex-shrink-0" />
                          ) : (
                            <FileText className="h-5 w-5 text-orange-500 flex-shrink-0" />
                          )}
                          <div className="min-w-0">
                            <p className="text-sm font-medium truncate">
                              {attachment.name}
                            </p>
                            <p className="text-xs text-muted-foreground">
                              {formatFileSize(attachment.size)} • {format(new Date(attachment.uploaded_at), "MMM d, yyyy")}
                            </p>
                          </div>
                        </div>
                        <div className="flex gap-2 flex-shrink-0">
                          {attachment.urlError ? (
                            <div className="flex items-center text-red-500 text-xs">
                              <AlertCircle className="h-4 w-4 mr-1" />
                              Error
                            </div>
                          ) : attachment.signedUrl ? (
                            <>
                              <Button
                                variant="ghost"
                                size="sm"
                                onClick={() => window.open(attachment.signedUrl, "_blank")}
                              >
                                <ExternalLink className="h-4 w-4" />
                              </Button>
                              <Button
                                variant="ghost"
                                size="sm"
                                asChild
                              >
                                <a href={attachment.signedUrl} download={attachment.name}>
                                  <Download className="h-4 w-4" />
                                </a>
                              </Button>
                            </>
                          ) : (
                            <Loader2 className="h-4 w-4 animate-spin" />
                          )}
                        </div>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            </>
          )}
        </div>
      </DialogContent>
    </Dialog>
  );
}
