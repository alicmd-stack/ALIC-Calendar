/**
 * Inventory Dashboard - Placeholder
 */

import DashboardLayout from "@/shared/components/layout/DashboardLayout";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/shared/components/ui/card";
import { Package, Construction } from "lucide-react";

const InventoryDashboard = () => {
  return (
    <DashboardLayout>
      <div className="space-y-6">
        <div>
          <h1 className="text-3xl font-bold flex items-center gap-2">
            <Package className="h-8 w-8" />
            Inventory Management
          </h1>
          <p className="text-muted-foreground mt-1">
            Track and manage church inventory and assets
          </p>
        </div>

        <Card className="border-dashed">
          <CardHeader className="text-center">
            <Construction className="h-16 w-16 mx-auto text-muted-foreground" />
            <CardTitle className="mt-4">Coming Soon</CardTitle>
            <CardDescription className="max-w-md mx-auto">
              The Inventory Management module is currently under development.
              This will allow you to:
            </CardDescription>
          </CardHeader>
          <CardContent>
            <ul className="list-disc list-inside space-y-2 text-muted-foreground max-w-md mx-auto">
              <li>Track equipment and supplies</li>
              <li>Manage asset check-in/check-out</li>
              <li>Set reorder alerts for low stock items</li>
              <li>Generate inventory reports</li>
              <li>Assign items to ministries or departments</li>
            </ul>
          </CardContent>
        </Card>
      </div>
    </DashboardLayout>
  );
};

export default InventoryDashboard;
