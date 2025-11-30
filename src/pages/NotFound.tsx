import { Link } from "react-router-dom";
import { Button } from "@/shared/components/ui/button";
import { Home } from "lucide-react";
import { CHURCH_BRANDING } from "@/shared/constants/branding";

const NotFound = () => {
  return (
    <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-slate-50 via-blue-50 to-indigo-50 dark:from-slate-950 dark:via-slate-900 dark:to-slate-950">
      <div className="text-center space-y-8 max-w-md px-4">
        {/* Church Logo */}
        <div className="flex justify-center mb-4">
          <div className="bg-white dark:bg-slate-800 p-4 rounded-2xl shadow-lg">
            <img 
              src={CHURCH_BRANDING.logo.main}
              alt={CHURCH_BRANDING.logo.alt}
              className="h-20 w-20 object-contain"
            />
          </div>
        </div>
        
        <h1 className="text-9xl font-bold text-primary">404</h1>
        <h2 className="text-3xl font-semibold">Page Not Found</h2>
        <p className="text-muted-foreground text-lg">
          The page you're looking for doesn't exist or may have been moved.
        </p>
        <p className="text-sm text-muted-foreground">
          {CHURCH_BRANDING.name}
        </p>
        <Button asChild size="lg">
          <Link to="/public">
            <Home className="mr-2 h-4 w-4" />
            Go Home
          </Link>
        </Button>
      </div>
    </div>
  );
};

export default NotFound;
