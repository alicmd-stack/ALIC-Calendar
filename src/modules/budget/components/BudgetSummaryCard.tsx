/**
 * BudgetSummaryCard - Displays budget summary with visual indicators
 */

import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/shared/components/ui/card";
import { Progress } from "@/shared/components/ui/progress";
import { cn } from "@/lib/utils";
import { DollarSign, TrendingUp, Clock, CheckCircle, AlertTriangle } from "lucide-react";
import type { MinistryBudgetSummary, OrganizationBudgetSummary } from "../types";

interface BudgetSummaryCardProps {
  summary: MinistryBudgetSummary | OrganizationBudgetSummary;
  type?: "ministry" | "organization";
}

export function BudgetSummaryCard({ summary, type = "ministry" }: BudgetSummaryCardProps) {
  const isOrgSummary = "total_allocated" in summary;

  const allocated = isOrgSummary ? summary.total_allocated : summary.allocated_amount;
  const pending = isOrgSummary ? summary.total_pending : summary.total_pending;
  const approved = isOrgSummary ? summary.total_approved : summary.total_approved;
  const spent = isOrgSummary ? summary.total_spent : summary.total_spent;
  const remaining = isOrgSummary ? summary.total_remaining : summary.remaining;

  const usedPercentage = allocated > 0 ? ((allocated - remaining) / allocated) * 100 : 0;
  const spentPercentage = allocated > 0 ? (spent / allocated) * 100 : 0;

  const getProgressColor = () => {
    if (usedPercentage >= 90) return "bg-red-500";
    if (usedPercentage >= 75) return "bg-yellow-500";
    return "bg-green-500";
  };

  return (
    <Card>
      <CardHeader className="pb-2">
        <CardTitle className="flex items-center gap-2 text-lg">
          <DollarSign className="h-5 w-5 text-primary" />
          Budget Overview
        </CardTitle>
        <CardDescription>
          {isOrgSummary
            ? `${summary.fiscal_year_name} - All Ministries`
            : `${(summary as MinistryBudgetSummary).ministry_name} - ${summary.fiscal_year_name}`}
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        {/* Main Budget Stats */}
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          <div className="text-center p-3 bg-muted/50 rounded-lg">
            <p className="text-xs text-muted-foreground mb-1">Allocated</p>
            <p className="text-xl font-bold">${allocated.toLocaleString()}</p>
          </div>
          <div className="text-center p-3 bg-yellow-50 dark:bg-yellow-950/20 rounded-lg">
            <p className="text-xs text-muted-foreground mb-1">Pending</p>
            <p className="text-xl font-bold text-yellow-600">${pending.toLocaleString()}</p>
          </div>
          <div className="text-center p-3 bg-blue-50 dark:bg-blue-950/20 rounded-lg">
            <p className="text-xs text-muted-foreground mb-1">Approved</p>
            <p className="text-xl font-bold text-blue-600">${approved.toLocaleString()}</p>
          </div>
          <div className="text-center p-3 bg-green-50 dark:bg-green-950/20 rounded-lg">
            <p className="text-xs text-muted-foreground mb-1">Spent</p>
            <p className="text-xl font-bold text-green-600">${spent.toLocaleString()}</p>
          </div>
        </div>

        {/* Progress Bar */}
        <div className="space-y-2">
          <div className="flex justify-between text-sm">
            <span className="text-muted-foreground">Budget Usage</span>
            <span className={cn(
              "font-medium",
              usedPercentage >= 90 ? "text-red-600" : usedPercentage >= 75 ? "text-yellow-600" : "text-green-600"
            )}>
              {usedPercentage.toFixed(1)}%
            </span>
          </div>
          <div className="relative h-3 bg-muted rounded-full overflow-hidden">
            <div
              className={cn("absolute h-full transition-all", getProgressColor())}
              style={{ width: `${Math.min(spentPercentage, 100)}%` }}
            />
            <div
              className="absolute h-full bg-blue-400/60"
              style={{
                left: `${Math.min(spentPercentage, 100)}%`,
                width: `${Math.min(approved / allocated * 100, 100 - spentPercentage)}%`
              }}
            />
            <div
              className="absolute h-full bg-yellow-400/60"
              style={{
                left: `${Math.min((spent + approved) / allocated * 100, 100)}%`,
                width: `${Math.min(pending / allocated * 100, 100 - (spent + approved) / allocated * 100)}%`
              }}
            />
          </div>
          <div className="flex gap-4 text-xs text-muted-foreground">
            <span className="flex items-center gap-1">
              <span className="w-2 h-2 rounded bg-green-500"></span> Spent
            </span>
            <span className="flex items-center gap-1">
              <span className="w-2 h-2 rounded bg-blue-400"></span> Approved
            </span>
            <span className="flex items-center gap-1">
              <span className="w-2 h-2 rounded bg-yellow-400"></span> Pending
            </span>
          </div>
        </div>

        {/* Remaining Budget */}
        <div className={cn(
          "flex items-center justify-between p-3 rounded-lg border",
          remaining <= 0 ? "border-red-200 bg-red-50 dark:bg-red-950/20" :
          remaining < allocated * 0.2 ? "border-yellow-200 bg-yellow-50 dark:bg-yellow-950/20" :
          "border-green-200 bg-green-50 dark:bg-green-950/20"
        )}>
          <div className="flex items-center gap-2">
            {remaining <= 0 ? (
              <AlertTriangle className="h-5 w-5 text-red-500" />
            ) : remaining < allocated * 0.2 ? (
              <Clock className="h-5 w-5 text-yellow-500" />
            ) : (
              <CheckCircle className="h-5 w-5 text-green-500" />
            )}
            <span className="text-sm font-medium">Remaining Budget</span>
          </div>
          <span className={cn(
            "text-lg font-bold",
            remaining <= 0 ? "text-red-600" :
            remaining < allocated * 0.2 ? "text-yellow-600" : "text-green-600"
          )}>
            ${remaining.toLocaleString()}
          </span>
        </div>
      </CardContent>
    </Card>
  );
}

/**
 * Quick Stats Cards for Dashboard
 */
interface QuickStatsProps {
  totalAllocated: number;
  totalSpent: number;
  totalRemaining: number;
  pendingCount: number;
}

export function BudgetQuickStats({
  totalAllocated,
  totalSpent,
  totalRemaining,
  pendingCount,
}: QuickStatsProps) {
  return (
    <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
      <Card>
        <CardContent className="pt-6">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-primary/10 rounded-lg">
              <DollarSign className="h-5 w-5 text-primary" />
            </div>
            <div>
              <p className="text-xs text-muted-foreground">Total Allocated</p>
              <p className="text-xl font-bold">${totalAllocated.toLocaleString()}</p>
            </div>
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardContent className="pt-6">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-green-100 dark:bg-green-900/20 rounded-lg">
              <TrendingUp className="h-5 w-5 text-green-600" />
            </div>
            <div>
              <p className="text-xs text-muted-foreground">Total Spent</p>
              <p className="text-xl font-bold text-green-600">${totalSpent.toLocaleString()}</p>
            </div>
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardContent className="pt-6">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-blue-100 dark:bg-blue-900/20 rounded-lg">
              <CheckCircle className="h-5 w-5 text-blue-600" />
            </div>
            <div>
              <p className="text-xs text-muted-foreground">Remaining</p>
              <p className="text-xl font-bold text-blue-600">${totalRemaining.toLocaleString()}</p>
            </div>
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardContent className="pt-6">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-yellow-100 dark:bg-yellow-900/20 rounded-lg">
              <Clock className="h-5 w-5 text-yellow-600" />
            </div>
            <div>
              <p className="text-xs text-muted-foreground">Pending Requests</p>
              <p className="text-xl font-bold text-yellow-600">{pendingCount}</p>
            </div>
          </div>
        </CardContent>
      </Card>
    </div>
  );
}
