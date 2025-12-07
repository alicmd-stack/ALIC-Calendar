/**
 * Members Dashboard - Placeholder
 */

import DashboardLayout from "@/shared/components/layout/DashboardLayout";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/shared/components/ui/card";
import { UserCheck, Construction } from "lucide-react";

const MembersDashboard = () => {
  return (
    <DashboardLayout>
      <div className="space-y-4 sm:space-y-6">
        <div>
          <h1 className="text-2xl sm:text-3xl font-bold flex items-center gap-2">
            <UserCheck className="h-6 w-6 sm:h-8 sm:w-8" />
            Church Members
          </h1>
          <p className="text-sm sm:text-base text-muted-foreground mt-1">
            Manage church membership and member information
          </p>
        </div>

        <Card className="border-dashed">
          <CardHeader className="text-center p-4 sm:p-6">
            <Construction className="h-12 w-12 sm:h-16 sm:w-16 mx-auto text-muted-foreground" />
            <CardTitle className="mt-3 sm:mt-4 text-lg sm:text-xl">Coming Soon</CardTitle>
            <CardDescription className="max-w-md mx-auto text-xs sm:text-sm">
              The Church Members module is currently under development.
              This will allow you to:
            </CardDescription>
          </CardHeader>
          <CardContent className="p-4 sm:p-6 pt-0">
            <ul className="list-disc list-inside space-y-1.5 sm:space-y-2 text-xs sm:text-sm text-muted-foreground max-w-md mx-auto">
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
