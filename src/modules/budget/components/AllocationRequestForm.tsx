/**
 * AllocationRequestForm - Form for ministry leaders to request budget allocations
 * Supports annual (single amount), quarterly (Q1-Q4 amounts), or monthly (Jan-Dec amounts)
 */

import { useState, useEffect } from "react";
import { useForm, useFieldArray } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from "@/shared/components/ui/dialog";
import {
  Form,
  FormControl,
  FormDescription,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from "@/shared/components/ui/form";
import { Input } from "@/shared/components/ui/input";
import { Textarea } from "@/shared/components/ui/textarea";
import { Button } from "@/shared/components/ui/button";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/shared/components/ui/select";
import { Card, CardContent } from "@/shared/components/ui/card";
import {
  Loader2,
  DollarSign,
  Send,
  Save,
  Plus,
  Trash2,
} from "lucide-react";
import { useToast } from "@/shared/hooks/use-toast";
import { useAuth } from "@/shared/contexts/AuthContext";
import { useOrganization } from "@/shared/contexts/OrganizationContext";
import { useUserProfile } from "@/hooks/useUserProfile";
import {
  useMinistries,
  useActiveFiscalYear,
  useCreateAllocationRequest,
  useUpdateAllocationRequest,
  useSubmitAllocationRequest,
} from "../hooks";
import type {
  AllocationRequest,
  AllocationPeriodType,
  BudgetBreakdownItem,
} from "../types";
import {
  PERIOD_TYPE_LABELS,
  QUARTERLY_PERIODS,
  MONTHLY_PERIODS,
} from "../types";

// Form validation schema
const breakdownItemSchema = z.object({
  category: z.string().min(1, "Category is required"),
  description: z.string().min(1, "Description is required"),
  amount: z.coerce.number().positive("Amount must be greater than 0"),
});

// Period amount for quarterly/monthly breakdown
const periodAmountSchema = z.object({
  period: z.number(),
  label: z.string(),
  amount: z.coerce.number().min(0, "Amount must be 0 or greater"),
});

const allocationRequestFormSchema = z.object({
  period_type: z.enum(["annual", "quarterly", "monthly"]),
  annual_amount: z.coerce.number().min(0).optional(), // For annual only
  period_amounts: z.array(periodAmountSchema).optional(), // For quarterly/monthly
  justification: z.string().min(10, "Please provide a detailed justification (at least 10 characters)"),
  budget_breakdown: z.array(breakdownItemSchema).optional(),
});

type AllocationRequestFormValues = z.infer<typeof allocationRequestFormSchema>;

interface AllocationRequestFormProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  request?: AllocationRequest | null;
  onSuccess?: () => void;
}

// Helper to create initial period amounts
const createQuarterlyAmounts = () =>
  QUARTERLY_PERIODS.map((q) => ({ period: q.value, label: q.label, amount: 0 }));

const createMonthlyAmounts = () =>
  MONTHLY_PERIODS.map((m) => ({ period: m.value, label: m.label, amount: 0 }));

export function AllocationRequestForm({
  open,
  onOpenChange,
  request,
  onSuccess,
}: AllocationRequestFormProps) {
  const { toast } = useToast();
  const { user } = useAuth();
  const { profile } = useUserProfile();
  const { currentOrganization } = useOrganization();
  const [isSubmitting, setIsSubmitting] = useState(false);

  const { data: ministries, isLoading: ministriesLoading } = useMinistries(
    currentOrganization?.id
  );
  const { data: activeFiscalYear, isLoading: fiscalYearLoading } = useActiveFiscalYear(
    currentOrganization?.id
  );

  const createRequest = useCreateAllocationRequest();
  const updateRequest = useUpdateAllocationRequest();
  const submitForReview = useSubmitAllocationRequest();

  const isEditing = !!request;

  const form = useForm<AllocationRequestFormValues>({
    resolver: zodResolver(allocationRequestFormSchema),
    defaultValues: {
      period_type: "annual",
      annual_amount: 0,
      period_amounts: [],
      justification: "",
      budget_breakdown: [],
    },
  });

  const { fields: breakdownFields, append: appendBreakdown, remove: removeBreakdown } = useFieldArray({
    control: form.control,
    name: "budget_breakdown",
  });

  const periodType = form.watch("period_type");
  const periodAmounts = form.watch("period_amounts") || [];

  // Get the user's ministry from their profile
  const userMinistry = ministries?.find(
    (m) => m.name.toLowerCase() === profile?.ministry_name?.toLowerCase()
  );

  // Calculate total from period amounts
  const periodAmountsTotal = periodAmounts.reduce((sum, pa) => sum + Number(pa.amount || 0), 0);

  // Calculate total from breakdown
  const breakdownTotal = breakdownFields.reduce((sum, _, index) => {
    const amount = form.watch(`budget_breakdown.${index}.amount`) || 0;
    return sum + Number(amount);
  }, 0);

  // Update period amounts when period type changes
  useEffect(() => {
    if (periodType === "quarterly") {
      form.setValue("period_amounts", createQuarterlyAmounts());
    } else if (periodType === "monthly") {
      form.setValue("period_amounts", createMonthlyAmounts());
    } else {
      form.setValue("period_amounts", []);
    }
  }, [periodType, form]);

  // Update form values when request changes (for editing)
  useEffect(() => {
    if (request) {
      // Parse the budget_breakdown to extract period amounts if they exist
      const breakdown = request.budget_breakdown || [];
      const periodAmountsFromBreakdown = breakdown.filter(
        (item) => item.category === "__period_amount__"
      );

      if (request.period_type === "annual") {
        form.reset({
          period_type: request.period_type,
          annual_amount: request.requested_amount,
          period_amounts: [],
          justification: request.justification,
          budget_breakdown: breakdown.filter((item) => item.category !== "__period_amount__"),
        });
      } else if (request.period_type === "quarterly") {
        const quarterAmounts = createQuarterlyAmounts().map((q) => {
          const found = periodAmountsFromBreakdown.find(
            (p) => p.description === q.label
          );
          return { ...q, amount: found?.amount || 0 };
        });
        form.reset({
          period_type: request.period_type,
          annual_amount: 0,
          period_amounts: quarterAmounts,
          justification: request.justification,
          budget_breakdown: breakdown.filter((item) => item.category !== "__period_amount__"),
        });
      } else if (request.period_type === "monthly") {
        const monthAmounts = createMonthlyAmounts().map((m) => {
          const found = periodAmountsFromBreakdown.find(
            (p) => p.description === m.label
          );
          return { ...m, amount: found?.amount || 0 };
        });
        form.reset({
          period_type: request.period_type,
          annual_amount: 0,
          period_amounts: monthAmounts,
          justification: request.justification,
          budget_breakdown: breakdown.filter((item) => item.category !== "__period_amount__"),
        });
      }
    } else {
      form.reset({
        period_type: "annual",
        annual_amount: 0,
        period_amounts: [],
        justification: "",
        budget_breakdown: [],
      });
    }
  }, [request, form]);

  const handleSave = async (values: AllocationRequestFormValues, submit: boolean = false) => {
    if (!currentOrganization || !user || !activeFiscalYear) {
      toast({
        title: "Error",
        description: "Missing required data. Please try again.",
        variant: "destructive",
      });
      return;
    }

    if (!userMinistry) {
      toast({
        title: "Error",
        description: "You are not assigned to a ministry. Please contact an administrator.",
        variant: "destructive",
      });
      return;
    }

    // Calculate total requested amount based on period type
    let totalAmount = 0;
    if (values.period_type === "annual") {
      totalAmount = values.annual_amount || 0;
    } else {
      totalAmount = (values.period_amounts || []).reduce(
        (sum, pa) => sum + Number(pa.amount || 0),
        0
      );
    }

    if (totalAmount <= 0) {
      toast({
        title: "Error",
        description: "Total requested amount must be greater than 0.",
        variant: "destructive",
      });
      return;
    }

    // Store period amounts in budget_breakdown with special category
    const periodAmountsAsBreakdown: BudgetBreakdownItem[] = (values.period_amounts || [])
      .filter((pa) => pa.amount > 0)
      .map((pa) => ({
        category: "__period_amount__",
        description: pa.label,
        amount: pa.amount,
      }));

    const combinedBreakdown = [
      ...periodAmountsAsBreakdown,
      ...(values.budget_breakdown as BudgetBreakdownItem[] || []),
    ];

    setIsSubmitting(true);

    try {
      if (isEditing && request) {
        // Update existing request
        await updateRequest.mutateAsync({
          requestId: request.id,
          data: {
            period_type: values.period_type,
            period_number: null, // No longer using single period number
            requested_amount: totalAmount,
            justification: values.justification,
            budget_breakdown: combinedBreakdown,
          },
        });

        if (submit) {
          await submitForReview.mutateAsync({
            requestId: request.id,
            actorId: user.id,
            actorName: profile?.full_name || "Unknown",
          });
        }

        toast({
          title: submit ? "Request submitted" : "Request updated",
          description: submit
            ? "Your allocation request has been submitted for review."
            : "Your allocation request has been saved as a draft.",
        });
      } else {
        // Create new request
        const newRequest = await createRequest.mutateAsync({
          requestData: {
            organization_id: currentOrganization.id,
            fiscal_year_id: activeFiscalYear.id,
            ministry_id: userMinistry.id,
            requester_id: user.id,
            requester_name: profile?.full_name || "Unknown",
            period_type: values.period_type,
            period_number: null, // No longer using single period number
            requested_amount: totalAmount,
            justification: values.justification,
            budget_breakdown: combinedBreakdown,
            status: "draft",
          },
          actorId: user.id,
          actorName: profile?.full_name || "Unknown",
        });

        if (submit) {
          await submitForReview.mutateAsync({
            requestId: newRequest.id,
            actorId: user.id,
            actorName: profile?.full_name || "Unknown",
          });
        }

        toast({
          title: submit ? "Request submitted" : "Request created",
          description: submit
            ? "Your allocation request has been submitted for review."
            : "Your allocation request has been saved as a draft.",
        });
      }

      onOpenChange(false);
      onSuccess?.();
    } catch (error) {
      toast({
        title: "Error",
        description:
          error instanceof Error ? error.message : "Failed to save allocation request",
        variant: "destructive",
      });
    } finally {
      setIsSubmitting(false);
    }
  };

  const isLoading = ministriesLoading || fiscalYearLoading;

  if (!activeFiscalYear && !fiscalYearLoading) {
    return (
      <Dialog open={open} onOpenChange={onOpenChange}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>No Active Fiscal Year</DialogTitle>
            <DialogDescription>
              There is no active fiscal year configured. Please contact an administrator
              to set up a fiscal year before requesting budget allocations.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button onClick={() => onOpenChange(false)}>Close</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    );
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-[700px] max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <DollarSign className="h-5 w-5" />
            {isEditing ? "Edit Allocation Request" : "Request Budget Allocation"}
          </DialogTitle>
          <DialogDescription>
            {isEditing
              ? "Update your budget allocation request."
              : "Submit a request for budget allocation for your ministry."}
            <span className="block mt-1 text-xs">
              {activeFiscalYear && <>Fiscal Year: {activeFiscalYear.name}</>}
              {activeFiscalYear && userMinistry && <> • </>}
              {userMinistry && <>Ministry: {userMinistry.name}</>}
            </span>
          </DialogDescription>
        </DialogHeader>

        {isLoading ? (
          <div className="flex items-center justify-center py-8">
            <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" />
          </div>
        ) : !userMinistry ? (
          <div className="py-8 text-center">
            <p className="text-muted-foreground">
              You are not assigned to a ministry. Please contact an administrator to be
              assigned to a ministry before requesting budget allocations.
            </p>
            <Button className="mt-4" onClick={() => onOpenChange(false)}>
              Close
            </Button>
          </div>
        ) : (
          <Form {...form}>
            <form className="space-y-6">
              {/* Period Type Selection */}
              <FormField
                control={form.control}
                name="period_type"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Period Type *</FormLabel>
                    <Select
                      onValueChange={field.onChange}
                      value={field.value}
                    >
                      <FormControl>
                        <SelectTrigger>
                          <SelectValue placeholder="Select period type" />
                        </SelectTrigger>
                      </FormControl>
                      <SelectContent>
                        {(Object.entries(PERIOD_TYPE_LABELS) as [AllocationPeriodType, string][]).map(
                          ([value, label]) => (
                            <SelectItem key={value} value={value}>
                              {label}
                            </SelectItem>
                          )
                        )}
                      </SelectContent>
                    </Select>
                    <FormDescription>
                      {periodType === "annual" && "Request a single amount for the entire fiscal year."}
                      {periodType === "quarterly" && "Request amounts for each quarter (Q1, Q2, Q3, Q4)."}
                      {periodType === "monthly" && "Request amounts for each month (January - December)."}
                    </FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />

              {/* Annual Amount - Only shown for annual period type */}
              {periodType === "annual" && (
                <FormField
                  control={form.control}
                  name="annual_amount"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Annual Requested Amount (USD) *</FormLabel>
                      <FormControl>
                        <div className="relative">
                          <span className="absolute left-3 top-1/2 -translate-y-1/2 text-muted-foreground">
                            $
                          </span>
                          <Input
                            type="number"
                            step="0.01"
                            min="0"
                            placeholder="0.00"
                            className="pl-7"
                            {...field}
                          />
                        </div>
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />
              )}

              {/* Quarterly Amounts */}
              {periodType === "quarterly" && (
                <div className="space-y-3">
                  <FormLabel>Quarterly Amounts (USD) *</FormLabel>
                  <Card>
                    <CardContent className="pt-4">
                      <div className="grid grid-cols-2 gap-4">
                        {periodAmounts.map((pa, index) => (
                          <FormField
                            key={pa.period}
                            control={form.control}
                            name={`period_amounts.${index}.amount`}
                            render={({ field }) => (
                              <FormItem>
                                <FormLabel className="text-sm font-medium">
                                  {pa.label}
                                </FormLabel>
                                <FormControl>
                                  <div className="relative">
                                    <span className="absolute left-3 top-1/2 -translate-y-1/2 text-muted-foreground text-sm">
                                      $
                                    </span>
                                    <Input
                                      type="number"
                                      step="0.01"
                                      min="0"
                                      placeholder="0.00"
                                      className="pl-7"
                                      {...field}
                                    />
                                  </div>
                                </FormControl>
                                <FormMessage />
                              </FormItem>
                            )}
                          />
                        ))}
                      </div>
                      <div className="flex justify-end pt-4 mt-4 border-t">
                        <span className="text-sm font-medium">
                          Total: ${periodAmountsTotal.toLocaleString("en-US", { minimumFractionDigits: 2 })}
                        </span>
                      </div>
                    </CardContent>
                  </Card>
                </div>
              )}

              {/* Monthly Amounts */}
              {periodType === "monthly" && (
                <div className="space-y-3">
                  <FormLabel>Monthly Amounts (USD) *</FormLabel>
                  <Card>
                    <CardContent className="pt-4">
                      <div className="grid grid-cols-3 gap-3">
                        {periodAmounts.map((pa, index) => (
                          <FormField
                            key={pa.period}
                            control={form.control}
                            name={`period_amounts.${index}.amount`}
                            render={({ field }) => (
                              <FormItem>
                                <FormLabel className="text-xs font-medium">
                                  {pa.label}
                                </FormLabel>
                                <FormControl>
                                  <div className="relative">
                                    <span className="absolute left-2 top-1/2 -translate-y-1/2 text-muted-foreground text-xs">
                                      $
                                    </span>
                                    <Input
                                      type="number"
                                      step="0.01"
                                      min="0"
                                      placeholder="0.00"
                                      className="pl-5 text-sm"
                                      {...field}
                                    />
                                  </div>
                                </FormControl>
                                <FormMessage />
                              </FormItem>
                            )}
                          />
                        ))}
                      </div>
                      <div className="flex justify-end pt-4 mt-4 border-t">
                        <span className="text-sm font-medium">
                          Total: ${periodAmountsTotal.toLocaleString("en-US", { minimumFractionDigits: 2 })}
                        </span>
                      </div>
                    </CardContent>
                  </Card>
                </div>
              )}

              {/* Justification */}
              <FormField
                control={form.control}
                name="justification"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Justification *</FormLabel>
                    <FormControl>
                      <Textarea
                        placeholder="Explain why this budget allocation is needed, how it will be used, and the expected outcomes..."
                        className="resize-none"
                        rows={4}
                        {...field}
                      />
                    </FormControl>
                    <FormDescription>
                      Provide a clear explanation for this budget request.
                    </FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />

              {/* Budget Breakdown (Optional) */}
              <div className="space-y-3">
                <div className="flex items-center justify-between">
                  <FormLabel>Additional Budget Breakdown (Optional)</FormLabel>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    onClick={() =>
                      appendBreakdown({ category: "", description: "", amount: 0 })
                    }
                  >
                    <Plus className="h-4 w-4 mr-1" />
                    Add Item
                  </Button>
                </div>

                {breakdownFields.length > 0 && (
                  <Card>
                    <CardContent className="pt-4 space-y-4">
                      {breakdownFields.map((field, index) => (
                        <div
                          key={field.id}
                          className="grid grid-cols-12 gap-2 items-start"
                        >
                          <div className="col-span-3">
                            <Input
                              placeholder="Category"
                              {...form.register(`budget_breakdown.${index}.category`)}
                            />
                          </div>
                          <div className="col-span-5">
                            <Input
                              placeholder="Description"
                              {...form.register(`budget_breakdown.${index}.description`)}
                            />
                          </div>
                          <div className="col-span-3">
                            <div className="relative">
                              <span className="absolute left-2 top-1/2 -translate-y-1/2 text-muted-foreground text-sm">
                                $
                              </span>
                              <Input
                                type="number"
                                step="0.01"
                                min="0"
                                placeholder="0.00"
                                className="pl-5"
                                {...form.register(`budget_breakdown.${index}.amount`)}
                              />
                            </div>
                          </div>
                          <div className="col-span-1">
                            <Button
                              type="button"
                              variant="ghost"
                              size="icon"
                              onClick={() => removeBreakdown(index)}
                              className="text-red-500 hover:text-red-700"
                            >
                              <Trash2 className="h-4 w-4" />
                            </Button>
                          </div>
                        </div>
                      ))}

                      {breakdownFields.length > 0 && (
                        <div className="flex justify-end pt-2 border-t">
                          <span className="text-sm font-medium">
                            Breakdown Total: ${breakdownTotal.toFixed(2)}
                          </span>
                        </div>
                      )}
                    </CardContent>
                  </Card>
                )}

                <p className="text-xs text-muted-foreground">
                  Optionally add additional details about how the budget will be used.
                </p>
              </div>

              <DialogFooter className="flex-col sm:flex-row gap-2 pt-4">
                <Button
                  type="button"
                  variant="outline"
                  onClick={() => onOpenChange(false)}
                  disabled={isSubmitting}
                >
                  Cancel
                </Button>
                <Button
                  type="button"
                  variant="secondary"
                  onClick={form.handleSubmit((values) => handleSave(values, false))}
                  disabled={isSubmitting}
                >
                  {isSubmitting ? (
                    <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                  ) : (
                    <Save className="mr-2 h-4 w-4" />
                  )}
                  Save as Draft
                </Button>
                <Button
                  type="button"
                  onClick={form.handleSubmit((values) => handleSave(values, true))}
                  disabled={isSubmitting}
                >
                  {isSubmitting ? (
                    <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                  ) : (
                    <Send className="mr-2 h-4 w-4" />
                  )}
                  Submit for Review
                </Button>
              </DialogFooter>
            </form>
          </Form>
        )}
      </DialogContent>
    </Dialog>
  );
}
