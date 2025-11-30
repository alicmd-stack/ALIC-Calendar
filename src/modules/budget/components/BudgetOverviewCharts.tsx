/**
 * Budget Overview Charts - World-class visualizations for budget data
 */

import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/shared/components/ui/card";
import {
  PieChart,
  Pie,
  BarChart,
  Bar,
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
  ResponsiveContainer,
  Cell,
  Area,
  AreaChart,
} from "recharts";
import {
  TrendingUp,
  TrendingDown,
  DollarSign,
  AlertCircle,
} from "lucide-react";
import type {
  OrganizationBudgetSummary,
  ExpenseRequestWithRelations,
} from "../types";

interface BudgetOverviewChartsProps {
  budgetSummary: OrganizationBudgetSummary;
  expenses: ExpenseRequestWithRelations[];
}

// Color palette - professional and accessible
const COLORS = {
  primary: "#3b82f6",
  success: "#10b981",
  warning: "#f59e0b",
  danger: "#ef4444",
  purple: "#8b5cf6",
  teal: "#14b8a6",
  pink: "#ec4899",
  indigo: "#6366f1",
};

const MINISTRY_COLORS = [
  COLORS.primary,
  COLORS.success,
  COLORS.purple,
  COLORS.warning,
  COLORS.teal,
  COLORS.pink,
  COLORS.indigo,
  COLORS.danger,
];

const BudgetOverviewCharts = ({
  budgetSummary,
  expenses,
}: BudgetOverviewChartsProps) => {
  // Prepare data for Ministry Budget Allocation Pie Chart
  const ministryAllocationData = budgetSummary.ministry_summaries
    .filter((m) => m.allocated_amount > 0)
    .map((ministry) => ({
      name: ministry.ministry_name,
      value: ministry.allocated_amount,
      spent: ministry.total_spent,
      remaining: ministry.remaining,
      utilization:
        ministry.allocated_amount > 0
          ? ((ministry.total_spent / ministry.allocated_amount) * 100).toFixed(
              1
            )
          : "0",
    }));

  // Prepare data for Budget vs Spending Bar Chart
  const budgetComparisonData = budgetSummary.ministry_summaries.map(
    (ministry) => ({
      name:
        ministry.ministry_name.length > 15
          ? ministry.ministry_name.substring(0, 15) + "..."
          : ministry.ministry_name,
      allocated: ministry.allocated_amount,
      spent: ministry.total_spent,
      pending: ministry.total_pending,
      remaining: ministry.remaining,
    })
  );

  // Prepare data for Expense Status Breakdown
  const statusBreakdown = expenses.reduce((acc, expense) => {
    const status = expense.status;
    if (!acc[status]) {
      acc[status] = { count: 0, amount: 0 };
    }
    acc[status].count += 1;
    acc[status].amount += expense.amount;
    return acc;
  }, {} as Record<string, { count: number; amount: number }>);

  const statusData = Object.entries(statusBreakdown).map(([status, data]) => ({
    status: status.replace(/_/g, " ").replace(/\b\w/g, (l) => l.toUpperCase()),
    count: data.count,
    amount: data.amount,
  }));

  // Prepare data for Monthly Spending Trend
  const monthlySpending = expenses
    .filter(
      (e) =>
        e.status === "leader_approved" ||
        e.status === "treasury_approved" ||
        e.status === "cancelled"
    )
    .reduce((acc, expense) => {
      const date = new Date(
        expense.finance_processed_at ||
          expense.treasury_reviewed_at ||
          expense.created_at
      );
      const monthKey = `${date.getFullYear()}-${String(
        date.getMonth() + 1
      ).padStart(2, "0")}`;
      const monthName = date.toLocaleDateString("en-US", {
        month: "short",
        year: "numeric",
      });

      if (!acc[monthKey]) {
        acc[monthKey] = { month: monthName, amount: 0, count: 0 };
      }
      acc[monthKey].amount += expense.amount;
      acc[monthKey].count += 1;
      return acc;
    }, {} as Record<string, { month: string; amount: number; count: number }>);

  const monthlyData = Object.values(monthlySpending).sort((a, b) =>
    a.month.localeCompare(b.month)
  );

  // Calculate utilization rate
  const utilizationRate =
    budgetSummary.total_allocated > 0
      ? (
          (budgetSummary.total_spent / budgetSummary.total_allocated) *
          100
        ).toFixed(1)
      : "0";

  const isOverBudget =
    budgetSummary.total_spent > budgetSummary.total_allocated;
  const isNearLimit = parseFloat(utilizationRate) > 90;

  // Custom tooltip for pie chart
  const CustomPieTooltip = ({
    active,
    payload,
  }: {
    active?: boolean;
    payload?: Array<{
      payload: {
        name: string;
        value: number;
        spent: number;
        utilization: string;
      };
    }>;
  }) => {
    if (active && payload && payload.length) {
      const data = payload[0].payload;
      return (
        <div className="bg-background border rounded-lg shadow-lg p-3">
          <p className="font-semibold">{data.name}</p>
          <p className="text-sm text-muted-foreground">
            Allocated:{" "}
            <span className="font-medium text-foreground">
              ${data.value.toLocaleString()}
            </span>
          </p>
          <p className="text-sm text-muted-foreground">
            Spent:{" "}
            <span className="font-medium text-green-600">
              ${data.spent.toLocaleString()}
            </span>
          </p>
          <p className="text-sm text-muted-foreground">
            Utilization:{" "}
            <span className="font-medium text-blue-600">
              {data.utilization}%
            </span>
          </p>
        </div>
      );
    }
    return null;
  };

  // Custom tooltip for bar chart
  const CustomBarTooltip = ({
    active,
    payload,
    label,
  }: {
    active?: boolean;
    payload?: Array<{ name: string; value: number; color: string }>;
    label?: string;
  }) => {
    if (active && payload && payload.length) {
      return (
        <div className="bg-background border rounded-lg shadow-lg p-3">
          <p className="font-semibold mb-2">{label}</p>
          {payload.map((entry, index: number) => (
            <p key={index} className="text-sm" style={{ color: entry.color }}>
              {entry.name}:{" "}
              <span className="font-medium">
                ${entry.value.toLocaleString()}
              </span>
            </p>
          ))}
        </div>
      );
    }
    return null;
  };

  return (
    <div className="space-y-6">
      {/* Budget Utilization Alert */}
      {(isOverBudget || isNearLimit) && (
        <Card
          className={
            isOverBudget
              ? "border-red-500 bg-red-50 dark:bg-red-950"
              : "border-yellow-500 bg-yellow-50 dark:bg-yellow-950"
          }
        >
          <CardContent className="pt-6">
            <div className="flex items-start gap-3">
              <AlertCircle
                className={
                  isOverBudget
                    ? "h-5 w-5 text-red-600 mt-0.5"
                    : "h-5 w-5 text-yellow-600 mt-0.5"
                }
              />
              <div>
                <h4
                  className={
                    isOverBudget
                      ? "font-semibold text-red-900 dark:text-red-100"
                      : "font-semibold text-yellow-900 dark:text-yellow-100"
                  }
                >
                  {isOverBudget
                    ? "Budget Exceeded"
                    : "Approaching Budget Limit"}
                </h4>
                <p
                  className={
                    isOverBudget
                      ? "text-sm text-red-700 dark:text-red-200 mt-1"
                      : "text-sm text-yellow-700 dark:text-yellow-200 mt-1"
                  }
                >
                  {isOverBudget
                    ? `You have exceeded your budget by $${(
                        budgetSummary.total_spent -
                        budgetSummary.total_allocated
                      ).toLocaleString()}.`
                    : `You have used ${utilizationRate}% of your allocated budget.`}
                </p>
              </div>
            </div>
          </CardContent>
        </Card>
      )}

      {/* Top Row - Main Charts */}
      <div className="grid gap-6 md:grid-cols-2">
        {/* Ministry Budget Allocation Pie Chart */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <DollarSign className="h-5 w-5" />
              Budget Allocation by Ministry
            </CardTitle>
            <CardDescription>
              Distribution of allocated budget across ministries
            </CardDescription>
          </CardHeader>
          <CardContent>
            <ResponsiveContainer width="100%" height={300}>
              <PieChart>
                <Pie
                  data={ministryAllocationData}
                  cx="50%"
                  cy="50%"
                  labelLine={false}
                  label={({ name, percent }) =>
                    `${name} ${(percent * 100).toFixed(0)}%`
                  }
                  outerRadius={100}
                  fill="#8884d8"
                  dataKey="value"
                >
                  {ministryAllocationData.map((entry, index) => (
                    <Cell
                      key={`cell-${index}`}
                      fill={MINISTRY_COLORS[index % MINISTRY_COLORS.length]}
                    />
                  ))}
                </Pie>
                <Tooltip content={<CustomPieTooltip />} />
              </PieChart>
            </ResponsiveContainer>
          </CardContent>
        </Card>

        {/* Budget vs Spending Comparison */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <TrendingUp className="h-5 w-5" />
              Budget vs Spending Analysis
            </CardTitle>
            <CardDescription>
              Compare allocated budget with actual spending by ministry
            </CardDescription>
          </CardHeader>
          <CardContent>
            <ResponsiveContainer width="100%" height={300}>
              <BarChart data={budgetComparisonData}>
                <CartesianGrid strokeDasharray="3 3" className="stroke-muted" />
                <XAxis
                  dataKey="name"
                  tick={{ fontSize: 12 }}
                  angle={-45}
                  textAnchor="end"
                  height={80}
                />
                <YAxis tick={{ fontSize: 12 }} />
                <Tooltip content={<CustomBarTooltip />} />
                <Legend />
                <Bar
                  dataKey="allocated"
                  fill={COLORS.primary}
                  name="Allocated"
                />
                <Bar dataKey="spent" fill={COLORS.success} name="Spent" />
                <Bar dataKey="pending" fill={COLORS.warning} name="Pending" />
              </BarChart>
            </ResponsiveContainer>
          </CardContent>
        </Card>
      </div>

      {/* Bottom Row - Trend and Status Charts */}
      <div className="grid gap-6 md:grid-cols-2">
        {/* Monthly Spending Trend */}
        {monthlyData.length > 0 && (
          <Card>
            <CardHeader>
              <CardTitle className="flex items-center gap-2">
                <TrendingUp className="h-5 w-5" />
                Monthly Spending Trend
              </CardTitle>
              <CardDescription>
                Track spending patterns over time
              </CardDescription>
            </CardHeader>
            <CardContent>
              <ResponsiveContainer width="100%" height={300}>
                <AreaChart data={monthlyData}>
                  <defs>
                    <linearGradient
                      id="colorAmount"
                      x1="0"
                      y1="0"
                      x2="0"
                      y2="1"
                    >
                      <stop
                        offset="5%"
                        stopColor={COLORS.primary}
                        stopOpacity={0.8}
                      />
                      <stop
                        offset="95%"
                        stopColor={COLORS.primary}
                        stopOpacity={0}
                      />
                    </linearGradient>
                  </defs>
                  <CartesianGrid
                    strokeDasharray="3 3"
                    className="stroke-muted"
                  />
                  <XAxis dataKey="month" tick={{ fontSize: 12 }} />
                  <YAxis tick={{ fontSize: 12 }} />
                  <Tooltip
                    content={({ active, payload }) => {
                      if (active && payload && payload.length) {
                        return (
                          <div className="bg-background border rounded-lg shadow-lg p-3">
                            <p className="font-semibold">
                              {payload[0].payload.month}
                            </p>
                            <p className="text-sm text-muted-foreground">
                              Amount:{" "}
                              <span className="font-medium text-foreground">
                                ${payload[0].value?.toLocaleString()}
                              </span>
                            </p>
                            <p className="text-sm text-muted-foreground">
                              Expenses:{" "}
                              <span className="font-medium text-foreground">
                                {payload[0].payload.count}
                              </span>
                            </p>
                          </div>
                        );
                      }
                      return null;
                    }}
                  />
                  <Area
                    type="monotone"
                    dataKey="amount"
                    stroke={COLORS.primary}
                    fillOpacity={1}
                    fill="url(#colorAmount)"
                  />
                </AreaChart>
              </ResponsiveContainer>
            </CardContent>
          </Card>
        )}

        {/* Expense Status Breakdown */}
        {statusData.length > 0 && (
          <Card>
            <CardHeader>
              <CardTitle className="flex items-center gap-2">
                <TrendingDown className="h-5 w-5" />
                Expense Request Status
              </CardTitle>
              <CardDescription>
                Current status of all expense requests
              </CardDescription>
            </CardHeader>
            <CardContent>
              <ResponsiveContainer width="100%" height={300}>
                <BarChart data={statusData} layout="vertical">
                  <CartesianGrid
                    strokeDasharray="3 3"
                    className="stroke-muted"
                  />
                  <XAxis type="number" tick={{ fontSize: 12 }} />
                  <YAxis
                    dataKey="status"
                    type="category"
                    width={120}
                    tick={{ fontSize: 12 }}
                  />
                  <Tooltip
                    content={({ active, payload }) => {
                      if (active && payload && payload.length) {
                        return (
                          <div className="bg-background border rounded-lg shadow-lg p-3">
                            <p className="font-semibold">
                              {payload[0].payload.status}
                            </p>
                            <p className="text-sm text-muted-foreground">
                              Count:{" "}
                              <span className="font-medium text-foreground">
                                {payload[0].payload.count}
                              </span>
                            </p>
                            <p className="text-sm text-muted-foreground">
                              Amount:{" "}
                              <span className="font-medium text-foreground">
                                ${payload[0].payload.amount.toLocaleString()}
                              </span>
                            </p>
                          </div>
                        );
                      }
                      return null;
                    }}
                  />
                  <Bar dataKey="count" fill={COLORS.purple} name="Count" />
                </BarChart>
              </ResponsiveContainer>
            </CardContent>
          </Card>
        )}
      </div>

      {/* Ministry Performance Table */}
      <Card>
        <CardHeader>
          <CardTitle>Ministry Performance Summary</CardTitle>
          <CardDescription>
            Detailed breakdown of budget utilization by ministry
          </CardDescription>
        </CardHeader>
        <CardContent>
          <div className="overflow-x-auto">
            <table className="w-full">
              <thead>
                <tr className="border-b">
                  <th className="text-left py-3 px-4 font-medium">Ministry</th>
                  <th className="text-right py-3 px-4 font-medium">
                    Allocated
                  </th>
                  <th className="text-right py-3 px-4 font-medium">Spent</th>
                  <th className="text-right py-3 px-4 font-medium">Pending</th>
                  <th className="text-right py-3 px-4 font-medium">
                    Remaining
                  </th>
                  <th className="text-right py-3 px-4 font-medium">
                    Utilization
                  </th>
                </tr>
              </thead>
              <tbody>
                {budgetSummary.ministry_summaries
                  .sort((a, b) => b.allocated_amount - a.allocated_amount)
                  .map((ministry, index) => {
                    const utilization =
                      ministry.allocated_amount > 0
                        ? (ministry.total_spent / ministry.allocated_amount) *
                          100
                        : 0;
                    return (
                      <tr
                        key={ministry.ministry_id}
                        className="border-b hover:bg-muted/50"
                      >
                        <td className="py-3 px-4 font-medium">
                          {ministry.ministry_name}
                        </td>
                        <td className="text-right py-3 px-4">
                          ${ministry.allocated_amount.toLocaleString()}
                        </td>
                        <td className="text-right py-3 px-4 text-green-600">
                          ${ministry.total_spent.toLocaleString()}
                        </td>
                        <td className="text-right py-3 px-4 text-yellow-600">
                          ${ministry.total_pending.toLocaleString()}
                        </td>
                        <td className="text-right py-3 px-4 text-blue-600">
                          ${ministry.remaining.toLocaleString()}
                        </td>
                        <td className="text-right py-3 px-4">
                          <span
                            className={`inline-flex items-center gap-1 ${
                              utilization > 100
                                ? "text-red-600"
                                : utilization > 90
                                ? "text-yellow-600"
                                : "text-green-600"
                            }`}
                          >
                            {utilization.toFixed(1)}%
                            {utilization > 90 && (
                              <AlertCircle className="h-3 w-3" />
                            )}
                          </span>
                        </td>
                      </tr>
                    );
                  })}
              </tbody>
              <tfoot>
                <tr className="border-t-2 font-bold">
                  <td className="py-3 px-4">Total</td>
                  <td className="text-right py-3 px-4">
                    ${budgetSummary.total_allocated.toLocaleString()}
                  </td>
                  <td className="text-right py-3 px-4 text-green-600">
                    ${budgetSummary.total_spent.toLocaleString()}
                  </td>
                  <td className="text-right py-3 px-4 text-yellow-600">
                    ${budgetSummary.total_pending.toLocaleString()}
                  </td>
                  <td className="text-right py-3 px-4 text-blue-600">
                    ${budgetSummary.total_remaining.toLocaleString()}
                  </td>
                  <td className="text-right py-3 px-4">{utilizationRate}%</td>
                </tr>
              </tfoot>
            </table>
          </div>
        </CardContent>
      </Card>
    </div>
  );
};

export default BudgetOverviewCharts;
