/**
 * Budget Metrics Grid - Animated KPI cards with real-time data
 */

import { Card, CardContent } from "@/shared/components/ui/card";
import {
  DollarSign,
  TrendingUp,
  TrendingDown,
  Clock,
  CheckCircle,
  AlertCircle,
  Wallet,
  Target,
  Activity,
  PieChart as PieChartIcon,
} from "lucide-react";
import type {
  OrganizationBudgetSummary,
  ExpenseRequestWithRelations,
} from "../types";
import { useEffect, useState } from "react";

interface BudgetMetricsGridProps {
  budgetSummary: OrganizationBudgetSummary;
  expenses: ExpenseRequestWithRelations[];
}

interface MetricCardProps {
  title: string;
  value: string | number;
  subtitle?: string;
  icon: React.ReactNode;
  trend?: "up" | "down" | "neutral";
  trendValue?: string;
  colorClass: string;
  delay?: number;
}

const MetricCard = ({
  title,
  value,
  subtitle,
  icon,
  trend,
  trendValue,
  colorClass,
  delay = 0,
}: MetricCardProps) => {
  const [isVisible, setIsVisible] = useState(false);

  useEffect(() => {
    const timer = setTimeout(() => setIsVisible(true), delay);
    return () => clearTimeout(timer);
  }, [delay]);

  return (
    <Card
      className={`overflow-hidden transition-all duration-500 transform ${
        isVisible ? "opacity-100 translate-y-0" : "opacity-0 translate-y-4"
      } hover:shadow-lg hover:-translate-y-1`}
    >
      <CardContent className="pt-6">
        <div className="flex items-start justify-between">
          <div className="flex-1">
            <p className="text-sm font-medium text-muted-foreground">{title}</p>
            <div className="mt-2 flex items-baseline gap-2">
              <h3 className="text-2xl font-bold">{value}</h3>
              {trend && trendValue && (
                <span
                  className={`flex items-center text-sm font-medium ${
                    trend === "up"
                      ? "text-green-600"
                      : trend === "down"
                      ? "text-red-600"
                      : "text-muted-foreground"
                  }`}
                >
                  {trend === "up" && <TrendingUp className="h-3 w-3 mr-1" />}
                  {trend === "down" && (
                    <TrendingDown className="h-3 w-3 mr-1" />
                  )}
                  {trendValue}
                </span>
              )}
            </div>
            {subtitle && (
              <p className="mt-1 text-xs text-muted-foreground">{subtitle}</p>
            )}
          </div>
          <div className={`${colorClass} p-3 rounded-lg`}>{icon}</div>
        </div>
      </CardContent>
    </Card>
  );
};

const BudgetMetricsGrid = ({
  budgetSummary,
  expenses,
}: BudgetMetricsGridProps) => {
  // Calculate metrics
  const totalBudget = budgetSummary.total_allocated;
  const totalSpent = budgetSummary.total_spent;
  const totalPending = budgetSummary.total_pending;
  const totalRemaining = budgetSummary.total_remaining;

  const utilizationRate =
    totalBudget > 0 ? ((totalSpent / totalBudget) * 100).toFixed(1) : "0";

  const pendingApprovals = expenses.filter(
    (e) =>
      e.status === "pending_leader" ||
      e.status === "pending_treasury" ||
      e.status === "pending_finance"
  ).length;

  const completedExpenses = expenses.filter(
    (e) => e.status === "treasury_approved" || e.status === "leader_approved"
  ).length;

  const totalExpenses = expenses.length;

  const completionRate =
    totalExpenses > 0
      ? ((completedExpenses / totalExpenses) * 100).toFixed(1)
      : "0";

  const averageExpense =
    totalExpenses > 0 ? Math.round(totalSpent / completedExpenses) || 0 : 0;

  const deniedExpenses = expenses.filter(
    (e) => e.status === "leader_denied" || e.status === "treasury_denied"
  ).length;

  const approvalRate =
    totalExpenses - deniedExpenses > 0
      ? (
          ((totalExpenses - deniedExpenses - pendingApprovals) /
            (totalExpenses - deniedExpenses)) *
          100
        ).toFixed(1)
      : "0";

  // Calculate budget health
  const budgetHealth =
    parseFloat(utilizationRate) > 100
      ? "over"
      : parseFloat(utilizationRate) > 90
      ? "warning"
      : parseFloat(utilizationRate) > 75
      ? "good"
      : "excellent";

  const metrics: MetricCardProps[] = [
    {
      title: "Total Budget",
      value: `$${totalBudget.toLocaleString()}`,
      subtitle: budgetSummary.fiscal_year_name,
      icon: <DollarSign className="h-5 w-5 text-white" />,
      colorClass: "bg-blue-500",
      delay: 0,
    },
    {
      title: "Total Spent",
      value: `$${totalSpent.toLocaleString()}`,
      subtitle: `${utilizationRate}% of budget`,
      icon: <TrendingUp className="h-5 w-5 text-white" />,
      trend:
        parseFloat(utilizationRate) > 75
          ? ("up" as const)
          : ("neutral" as const),
      trendValue: `${utilizationRate}%`,
      colorClass:
        parseFloat(utilizationRate) > 100
          ? "bg-red-500"
          : parseFloat(utilizationRate) > 90
          ? "bg-yellow-500"
          : "bg-green-500",
      delay: 50,
    },
    {
      title: "Available Balance",
      value: `$${totalRemaining.toLocaleString()}`,
      subtitle: totalRemaining < 0 ? "Over budget" : "Remaining funds",
      icon: <Wallet className="h-5 w-5 text-white" />,
      colorClass: totalRemaining < 0 ? "bg-red-500" : "bg-purple-500",
      delay: 100,
    },
    {
      title: "Pending Approvals",
      value: pendingApprovals,
      subtitle: `$${totalPending.toLocaleString()} total`,
      icon: <Clock className="h-5 w-5 text-white" />,
      colorClass: pendingApprovals > 10 ? "bg-yellow-500" : "bg-orange-500",
      delay: 150,
    },
    {
      title: "Budget Utilization",
      value: `${utilizationRate}%`,
      subtitle:
        budgetHealth === "over"
          ? "Over budget!"
          : budgetHealth === "warning"
          ? "Near limit"
          : budgetHealth === "good"
          ? "On track"
          : "Healthy",
      icon: <Target className="h-5 w-5 text-white" />,
      trend:
        parseFloat(utilizationRate) > 100
          ? ("up" as const)
          : ("neutral" as const),
      colorClass:
        budgetHealth === "over"
          ? "bg-red-500"
          : budgetHealth === "warning"
          ? "bg-yellow-500"
          : budgetHealth === "good"
          ? "bg-blue-500"
          : "bg-green-500",
      delay: 200,
    },
    {
      title: "Total Expenses",
      value: totalExpenses,
      subtitle: `${completedExpenses} completed`,
      icon: <Activity className="h-5 w-5 text-white" />,
      colorClass: "bg-indigo-500",
      delay: 250,
    },
    {
      title: "Average Expense",
      value: `$${averageExpense.toLocaleString()}`,
      subtitle:
        completedExpenses > 0
          ? `From ${completedExpenses} expenses`
          : "No completed expenses",
      icon: <PieChartIcon className="h-5 w-5 text-white" />,
      colorClass: "bg-teal-500",
      delay: 300,
    },
    {
      title: "Completion Rate",
      value: `${completionRate}%`,
      subtitle: `${completedExpenses} of ${totalExpenses} completed`,
      icon: <CheckCircle className="h-5 w-5 text-white" />,
      trend:
        parseFloat(completionRate) > 50 ? ("up" as const) : ("down" as const),
      trendValue: `${approvalRate}% approved`,
      colorClass:
        parseFloat(completionRate) > 75
          ? "bg-green-500"
          : parseFloat(completionRate) > 50
          ? "bg-yellow-500"
          : "bg-red-500",
      delay: 350,
    },
  ];

  return (
    <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
      {metrics.map((metric, index) => (
        <MetricCard key={index} {...metric} />
      ))}
    </div>
  );
};

export default BudgetMetricsGrid;
