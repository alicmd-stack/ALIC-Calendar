/**
 * Members Dashboard - Placeholder
 */

import DashboardLayout from "@/shared/components/layout/DashboardLayout";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/shared/components/ui/card";
import { UserCheck, Construction } from "lucide-react";

const MembersDashboard = () => {
  return (
    <DashboardLayout>
      <div className="space-y-6">
        <div>
          <h1 className="text-3xl font-bold flex items-center gap-2">
            <UserCheck className="h-8 w-8" />
            Church Members
          </h1>
          <p className="text-muted-foreground mt-1">
            Manage church membership and member information
          </p>
        </div>

        <Card className="border-dashed">
          <CardHeader className="text-center">
            <Construction className="h-16 w-16 mx-auto text-muted-foreground" />
            <CardTitle className="mt-4">Coming Soon</CardTitle>
            <CardDescription className="max-w-md mx-auto">
              The Church Members module is currently under development.
              This will allow you to:
            </CardDescription>
          </CardHeader>
          <CardContent>
            <ul className="list-disc list-inside space-y-2 text-muted-foreground max-w-md mx-auto">
              <li>Manage member profiles and contact info</li>
              <li>Track membership status and history</li>
              <li>Organize members into groups/ministries</li>
              <li>Record attendance and participation</li>
              <li>Manage family relationships</li>
              <li>Send communications to members</li>
            </ul>
          </CardContent>
        </Card>
      </div>
    </DashboardLayout>
  );
};

export default MembersDashboard;
