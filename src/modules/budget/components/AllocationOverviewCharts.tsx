/**
 * Allocation Overview Charts - World-class visualizations for budget allocation data
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
import { TrendingUp, DollarSign, AlertCircle, Wallet } from "lucide-react";
import type { AllocationRequestWithRelations } from "../types";

interface AllocationOverviewChartsProps {
  allocations: AllocationRequestWithRelations[];
  title?: string;
  description?: string;
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

const STATUS_COLORS: Record<string, string> = {
  draft: COLORS.primary,
  pending: COLORS.warning,
  approved: COLORS.success,
  partially_approved: COLORS.teal,
  denied: COLORS.danger,
  cancelled: COLORS.danger,
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

const AllocationOverviewCharts = ({
  allocations,
  title = "Budget Allocation Requests",
  description = "Overview of budget allocation requests and their status",
}: AllocationOverviewChartsProps) => {
  // Calculate totals
  const totalRequested = allocations.reduce(
    (sum, a) => sum + a.requested_amount,
    0
  );
  const approvedAmount = allocations
    .filter((a) => a.status === "approved" || a.status === "partially_approved")
    .reduce((sum, a) => sum + (a.approved_amount || a.requested_amount), 0);
  const pendingAmount = allocations
    .filter((a) => a.status === "pending")
    .reduce((sum, a) => sum + a.requested_amount, 0);
  const deniedAmount = allocations
    .filter((a) => a.status === "denied")
    .reduce((sum, a) => sum + a.requested_amount, 0);

  // Status breakdown for pie chart
  const statusBreakdown = allocations.reduce((acc, allocation) => {
    const status = allocation.status;
    if (!acc[status]) {
      acc[status] = { count: 0, amount: 0 };
    }
    acc[status].count += 1;
    acc[status].amount += allocation.requested_amount;
    return acc;
  }, {} as Record<string, { count: number; amount: number }>);

  const statusData = Object.entries(statusBreakdown).map(([status, data]) => ({
    name: status.replace(/_/g, " ").replace(/\b\w/g, (l) => l.toUpperCase()),
    value: data.amount,
    count: data.count,
    status: status,
  }));

  // Amount breakdown for bar chart
  const amountData = [
    { name: "Approved", amount: approvedAmount, color: COLORS.success },
    { name: "Pending", amount: pendingAmount, color: COLORS.warning },
    { name: "Denied", amount: deniedAmount, color: COLORS.danger },
  ].filter((item) => item.amount > 0);

  // Monthly trend
  const monthlyAllocations = allocations.reduce((acc, allocation) => {
    const date = new Date(allocation.created_at);
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
    acc[monthKey].amount += allocation.requested_amount;
    acc[monthKey].count += 1;
    return acc;
  }, {} as Record<string, { month: string; amount: number; count: number }>);

  const monthlyData = Object.values(monthlyAllocations).sort((a, b) =>
    a.month.localeCompare(b.month)
  );

  // Ministry breakdown
  const ministryBreakdown = allocations.reduce((acc, allocation) => {
    const ministryName = allocation.ministry?.name || "Unknown";
    if (!acc[ministryName]) {
      acc[ministryName] = { count: 0, amount: 0 };
    }
    acc[ministryName].count += 1;
    acc[ministryName].amount += allocation.requested_amount;
    return acc;
  }, {} as Record<string, { count: number; amount: number }>);

  const ministryData = Object.entries(ministryBreakdown)
    .map(([name, data]) => ({
      name: name.length > 20 ? name.substring(0, 20) + "..." : name,
      fullName: name,
      amount: data.amount,
      count: data.count,
    }))
    .sort((a, b) => b.amount - a.amount);

  // Approval rate
  const totalRequests = allocations.length;
  const approvedCount = allocations.filter(
    (a) => a.status === "approved" || a.status === "partially_approved"
  ).length;
  const approvalRate =
    totalRequests > 0
      ? ((approvedCount / totalRequests) * 100).toFixed(1)
      : "0";

  if (allocations.length === 0) {
    return (
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <Wallet className="h-5 w-5" />
            {title}
          </CardTitle>
          <CardDescription>{description}</CardDescription>
        </CardHeader>
        <CardContent>
          <div className="text-center py-12 text-muted-foreground">
            No allocation requests found
          </div>
        </CardContent>
      </Card>
    );
  }

  return (
    <div className="space-y-6">
      {/* Summary Stats */}
      <div className="grid gap-4 md:grid-cols-4">
        <Card>
          <CardContent className="pt-6">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-sm font-medium text-muted-foreground">
                  Total Requested
                </p>
                <h3 className="text-2xl font-bold mt-2">
                  ${totalRequested.toLocaleString()}
                </h3>
              </div>
              <DollarSign className="h-8 w-8 text-blue-500" />
            </div>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-6">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-sm font-medium text-muted-foreground">
                  Approved
                </p>
                <h3 className="text-2xl font-bold mt-2 text-green-600">
                  ${approvedAmount.toLocaleString()}
                </h3>
              </div>
              <TrendingUp className="h-8 w-8 text-green-500" />
            </div>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-6">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-sm font-medium text-muted-foreground">
                  Pending Review
                </p>
                <h3 className="text-2xl font-bold mt-2 text-yellow-600">
                  ${pendingAmount.toLocaleString()}
                </h3>
              </div>
              <AlertCircle className="h-8 w-8 text-yellow-500" />
            </div>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-6">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-sm font-medium text-muted-foreground">
                  Approval Rate
                </p>
                <h3 className="text-2xl font-bold mt-2 text-blue-600">
                  {approvalRate}%
                </h3>
              </div>
              <Wallet className="h-8 w-8 text-blue-500" />
            </div>
          </CardContent>
        </Card>
      </div>

      {/* Charts Row */}
      <div className="grid gap-6 md:grid-cols-2">
        {/* Status Breakdown Pie Chart */}
        {statusData.length > 0 && (
          <Card>
            <CardHeader>
              <CardTitle className="flex items-center gap-2">
                <DollarSign className="h-5 w-5" />
                Allocation Requests by Status
              </CardTitle>
              <CardDescription>
                Distribution of allocation requests
              </CardDescription>
            </CardHeader>
            <CardContent>
              <ResponsiveContainer width="100%" height={300}>
                <PieChart>
                  <Pie
                    data={statusData}
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
                    {statusData.map((entry, index) => (
                      <Cell
                        key={`cell-${index}`}
                        fill={STATUS_COLORS[entry.status] || COLORS.primary}
                      />
                    ))}
                  </Pie>
                  <Tooltip
                    content={({ active, payload }) => {
                      if (active && payload && payload.length) {
                        const data = payload[0].payload;
                        return (
                          <div className="bg-background border rounded-lg shadow-lg p-3">
                            <p className="font-semibold">{data.name}</p>
                            <p className="text-sm text-muted-foreground">
                              Amount:{" "}
                              <span className="font-medium text-foreground">
                                ${data.value.toLocaleString()}
                              </span>
                            </p>
                            <p className="text-sm text-muted-foreground">
                              Count:{" "}
                              <span className="font-medium text-foreground">
                                {data.count}
                              </span>
                            </p>
                          </div>
                        );
                      }
                      return null;
                    }}
                  />
                </PieChart>
              </ResponsiveContainer>
            </CardContent>
          </Card>
        )}

        {/* Amount Breakdown Bar Chart */}
        {amountData.length > 0 && (
          <Card>
            <CardHeader>
              <CardTitle className="flex items-center gap-2">
                <TrendingUp className="h-5 w-5" />
                Amount by Status
              </CardTitle>
              <CardDescription>
                Total amounts in each status category
              </CardDescription>
            </CardHeader>
            <CardContent>
              <ResponsiveContainer width="100%" height={300}>
                <BarChart data={amountData}>
                  <CartesianGrid
                    strokeDasharray="3 3"
                    className="stroke-muted"
                  />
                  <XAxis dataKey="name" tick={{ fontSize: 12 }} />
                  <YAxis tick={{ fontSize: 12 }} />
                  <Tooltip
                    content={({ active, payload }) => {
                      if (active && payload && payload.length) {
                        return (
                          <div className="bg-background border rounded-lg shadow-lg p-3">
                            <p className="font-semibold">
                              {payload[0].payload.name}
                            </p>
                            <p className="text-sm text-muted-foreground">
                              Amount:{" "}
                              <span className="font-medium text-foreground">
                                ${payload[0].value?.toLocaleString()}
                              </span>
                            </p>
                          </div>
                        );
                      }
                      return null;
                    }}
                  />
                  <Bar dataKey="amount" radius={[8, 8, 0, 0]}>
                    {amountData.map((entry, index) => (
                      <Cell key={`cell-${index}`} fill={entry.color} />
                    ))}
                  </Bar>
                </BarChart>
              </ResponsiveContainer>
            </CardContent>
          </Card>
        )}
      </div>

      {/* Second Row */}
      <div className="grid gap-6 md:grid-cols-2">
        {/* Monthly Trend */}
        {monthlyData.length > 0 && (
          <Card>
            <CardHeader>
              <CardTitle className="flex items-center gap-2">
                <TrendingUp className="h-5 w-5" />
                Monthly Allocation Trend
              </CardTitle>
              <CardDescription>Allocation requests over time</CardDescription>
            </CardHeader>
            <CardContent>
              <ResponsiveContainer width="100%" height={300}>
                <AreaChart data={monthlyData}>
                  <defs>
                    <linearGradient
                      id="colorAllocationAmount"
                      x1="0"
                      y1="0"
                      x2="0"
                      y2="1"
                    >
                      <stop
                        offset="5%"
                        stopColor={COLORS.purple}
                        stopOpacity={0.8}
                      />
                      <stop
                        offset="95%"
                        stopColor={COLORS.purple}
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
                              Requests:{" "}
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
                    stroke={COLORS.purple}
                    fillOpacity={1}
                    fill="url(#colorAllocationAmount)"
                  />
                </AreaChart>
              </ResponsiveContainer>
            </CardContent>
          </Card>
        )}

        {/* Ministry Breakdown */}
        {ministryData.length > 0 && (
          <Card>
            <CardHeader>
              <CardTitle className="flex items-center gap-2">
                <Wallet className="h-5 w-5" />
                Allocations by Ministry
              </CardTitle>
              <CardDescription>
                Allocation requests across ministries
              </CardDescription>
            </CardHeader>
            <CardContent>
              <ResponsiveContainer width="100%" height={300}>
                <BarChart data={ministryData} layout="vertical">
                  <CartesianGrid
                    strokeDasharray="3 3"
                    className="stroke-muted"
                  />
                  <XAxis type="number" tick={{ fontSize: 12 }} />
                  <YAxis
                    dataKey="name"
                    type="category"
                    width={100}
                    tick={{ fontSize: 12 }}
                  />
                  <Tooltip
                    content={({ active, payload }) => {
                      if (active && payload && payload.length) {
                        return (
                          <div className="bg-background border rounded-lg shadow-lg p-3">
                            <p className="font-semibold">
                              {payload[0].payload.fullName}
                            </p>
                            <p className="text-sm text-muted-foreground">
                              Amount:{" "}
                              <span className="font-medium text-foreground">
                                ${payload[0].value?.toLocaleString()}
                              </span>
                            </p>
                            <p className="text-sm text-muted-foreground">
                              Count:{" "}
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
                  <Bar
                    dataKey="amount"
                    fill={COLORS.indigo}
                    radius={[0, 8, 8, 0]}
                  />
                </BarChart>
              </ResponsiveContainer>
            </CardContent>
          </Card>
        )}
      </div>

      {/* Detailed Table */}
      <Card>
        <CardHeader>
          <CardTitle>Allocation Request Summary</CardTitle>
          <CardDescription>
            Detailed breakdown of all allocation requests by ministry
          </CardDescription>
        </CardHeader>
        <CardContent>
          <div className="overflow-x-auto">
            <table className="w-full">
              <thead>
                <tr className="border-b">
                  <th className="text-left py-3 px-4 font-medium">Ministry</th>
                  <th className="text-right py-3 px-4 font-medium">Requests</th>
                  <th className="text-right py-3 px-4 font-medium">
                    Total Amount
                  </th>
                  <th className="text-right py-3 px-4 font-medium">
                    Avg. Amount
                  </th>
                </tr>
              </thead>
              <tbody>
                {ministryData.map((ministry, index) => {
                  const avgAmount = ministry.amount / ministry.count;
                  return (
                    <tr
                      key={ministry.fullName}
                      className="border-b hover:bg-muted/50"
                    >
                      <td className="py-3 px-4 font-medium">
                        {ministry.fullName}
                      </td>
                      <td className="text-right py-3 px-4">{ministry.count}</td>
                      <td className="text-right py-3 px-4 font-medium text-blue-600">
                        ${ministry.amount.toLocaleString()}
                      </td>
                      <td className="text-right py-3 px-4 text-muted-foreground">
                        ${avgAmount.toLocaleString()}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
              <tfoot>
                <tr className="border-t-2 font-bold">
                  <td className="py-3 px-4">Total</td>
                  <td className="text-right py-3 px-4">{totalRequests}</td>
                  <td className="text-right py-3 px-4">
                    ${totalRequested.toLocaleString()}
                  </td>
                  <td className="text-right py-3 px-4">
                    ${(totalRequested / totalRequests).toLocaleString()}
                  </td>
                </tr>
              </tfoot>
            </table>
          </div>
        </CardContent>
      </Card>
    </div>
  );
};

export default AllocationOverviewCharts;
