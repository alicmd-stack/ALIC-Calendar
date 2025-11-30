/**
 * BudgetOverview - Enterprise-grade unified budget analytics dashboard
 * Combines expenses and allocations in a single, cohesive interface
 */

import { useState } from "react";
import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
} from "@/shared/components/ui/tabs";
import { Badge } from "@/shared/components/ui/badge";
import { DollarSign, Wallet, TrendingUp, BarChart3 } from "lucide-react";
import BudgetSection from "./BudgetSection";
import type {
  ExpenseRequestWithRelations,
  AllocationRequestWithRelations,
} from "../types";

interface BudgetOverviewProps {
  expenses: ExpenseRequestWithRelations[];
  allocations: AllocationRequestWithRelations[];
  title?: string;
  description?: string;
  defaultView?: "expenses" | "allocations" | "combined";
}

const BudgetOverview = ({
  expenses,
  allocations,
  title = "Budget Overview",
  description = "Comprehensive view of your financial requests and allocations",
  defaultView = "combined",
}: BudgetOverviewProps) => {
  const [activeView, setActiveView] = useState(defaultView);

  const hasExpenses = expenses.length > 0;
  const hasAllocations = allocations.length > 0;

  // Calculate quick stats
  const expenseTotal = expenses.reduce((sum, e) => sum + e.amount, 0);
  const allocationTotal = allocations.reduce(
    (sum, a) => sum + a.requested_amount,
    0
  );
  const totalBudgetActivity = expenseTotal + allocationTotal;

  // Determine default tab based on available data
  const getDefaultTab = () => {
    if (defaultView === "combined") {
      return hasExpenses
        ? "expenses"
        : hasAllocations
        ? "allocations"
        : "expenses";
    }
    return defaultView;
  };

  return (
    <div className="space-y-6">
      {/* Header with Summary Stats */}
      <div className="flex flex-col md:flex-row md:items-center md:justify-between gap-4 pb-6 border-b">
        <div>
          <h2 className="text-3xl font-bold flex items-center gap-3">
            <BarChart3 className="h-8 w-8 text-primary" />
            {title}
          </h2>
          <p className="text-muted-foreground mt-1">{description}</p>
        </div>

        {/* Quick Summary Cards */}
        <div className="flex gap-4">
          {hasExpenses && (
            <div className="bg-blue-50 dark:bg-blue-950 rounded-lg px-4 py-3 border border-blue-200 dark:border-blue-800">
              <div className="flex items-center gap-2">
                <DollarSign className="h-5 w-5 text-blue-600 dark:text-blue-400" />
                <div>
                  <p className="text-xs text-blue-600 dark:text-blue-400 font-medium">
                    Expenses
                  </p>
                  <p className="text-lg font-bold text-blue-900 dark:text-blue-100">
                    ${expenseTotal.toLocaleString()}
                  </p>
                </div>
              </div>
            </div>
          )}
          {hasAllocations && (
            <div className="bg-purple-50 dark:bg-purple-950 rounded-lg px-4 py-3 border border-purple-200 dark:border-purple-800">
              <div className="flex items-center gap-2">
                <Wallet className="h-5 w-5 text-purple-600 dark:text-purple-400" />
                <div>
                  <p className="text-xs text-purple-600 dark:text-purple-400 font-medium">
                    Allocations
                  </p>
                  <p className="text-lg font-bold text-purple-900 dark:text-purple-100">
                    ${allocationTotal.toLocaleString()}
                  </p>
                </div>
              </div>
            </div>
          )}
          {hasExpenses && hasAllocations && (
            <div className="bg-emerald-50 dark:bg-emerald-950 rounded-lg px-4 py-3 border border-emerald-200 dark:border-emerald-800">
              <div className="flex items-center gap-2">
                <TrendingUp className="h-5 w-5 text-emerald-600 dark:text-emerald-400" />
                <div>
                  <p className="text-xs text-emerald-600 dark:text-emerald-400 font-medium">
                    Total Activity
                  </p>
                  <p className="text-lg font-bold text-emerald-900 dark:text-emerald-100">
                    ${totalBudgetActivity.toLocaleString()}
                  </p>
                </div>
              </div>
            </div>
          )}
        </div>
      </div>

      {/* Tabbed Interface */}
      {hasExpenses || hasAllocations ? (
        <Tabs
          defaultValue={getDefaultTab()}
          value={activeView !== "combined" ? activeView : undefined}
          onValueChange={(value) => setActiveView(value as typeof activeView)}
          className="w-full"
        >
          <TabsList
            className="grid w-full max-w-md"
            style={{
              gridTemplateColumns: `repeat(${
                (hasExpenses ? 1 : 0) + (hasAllocations ? 1 : 0)
              }, 1fr)`,
            }}
          >
            {hasExpenses && (
              <TabsTrigger value="expenses" className="gap-2">
                <DollarSign className="h-4 w-4" />
                Expenses
                <Badge variant="secondary" className="ml-1">
                  {expenses.length}
                </Badge>
              </TabsTrigger>
            )}
            {hasAllocations && (
              <TabsTrigger value="allocations" className="gap-2">
                <Wallet className="h-4 w-4" />
                Allocations
                <Badge variant="secondary" className="ml-1">
                  {allocations.length}
                </Badge>
              </TabsTrigger>
            )}
          </TabsList>

          {/* Expense Tab */}
          {hasExpenses && (
            <TabsContent value="expenses" className="mt-6">
              <BudgetSection
                type="expenses"
                data={expenses}
                showHeader={false}
              />
            </TabsContent>
          )}

          {/* Allocation Tab */}
          {hasAllocations && (
            <TabsContent value="allocations" className="mt-6">
              <BudgetSection
                type="allocations"
                data={allocations}
                showHeader={false}
              />
            </TabsContent>
          )}
        </Tabs>
      ) : (
        // Empty state
        <div className="text-center py-12 bg-muted/30 rounded-lg border border-dashed">
          <BarChart3 className="h-12 w-12 text-muted-foreground mx-auto mb-4" />
          <h3 className="text-lg font-semibold mb-2">No Budget Activity</h3>
          <p className="text-muted-foreground">
            Start by creating an expense request or budget allocation
          </p>
        </div>
      )}
    </div>
  );
};

export default BudgetOverview;
