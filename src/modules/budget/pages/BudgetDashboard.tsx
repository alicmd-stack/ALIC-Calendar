/**
 * Budget Dashboard - Placeholder
 */

import DashboardLayout from "@/shared/components/layout/DashboardLayout";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/shared/components/ui/card";
import { DollarSign, Construction } from "lucide-react";

const BudgetDashboard = () => {
  return (
    <DashboardLayout>
      <div className="space-y-6">
        <div>
          <h1 className="text-3xl font-bold flex items-center gap-2">
            <DollarSign className="h-8 w-8" />
            Budget Management
          </h1>
          <p className="text-muted-foreground mt-1">
            Manage church budgets, expenses, and financial workflows
          </p>
        </div>

        <Card className="border-dashed">
          <CardHeader className="text-center">
            <Construction className="h-16 w-16 mx-auto text-muted-foreground" />
            <CardTitle className="mt-4">Coming Soon</CardTitle>
            <CardDescription className="max-w-md mx-auto">
              The Budget Management module is currently under development.
              This will allow you to:
            </CardDescription>
          </CardHeader>
          <CardContent>
            <ul className="list-disc list-inside space-y-2 text-muted-foreground max-w-md mx-auto">
              <li>Create and manage ministry budgets</li>
              <li>Submit and approve expense requests</li>
              <li>Track spending against budgets</li>
              <li>Generate financial reports</li>
              <li>Set up approval workflows for purchases</li>
            </ul>
          </CardContent>
        </Card>
      </div>
    </DashboardLayout>
  );
};

export default BudgetDashboard;
