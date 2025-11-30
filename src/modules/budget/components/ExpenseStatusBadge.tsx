/**
 * ExpenseStatusBadge - Displays expense status with appropriate styling
 */

import { Badge } from "@/shared/components/ui/badge";
import {
  FileEdit,
  Clock,
  CheckCircle,
  XCircle,
  Loader,
  CheckCircle2,
  Ban,
} from "lucide-react";
import { cn } from "@/lib/utils";
import type { ExpenseStatus } from "../types";
import { EXPENSE_STATUS_CONFIG } from "../types";

interface ExpenseStatusBadgeProps {
  status: ExpenseStatus;
  showIcon?: boolean;
  size?: "sm" | "default" | "lg";
}

const iconMap = {
  FileEdit,
  Clock,
  CheckCircle,
  XCircle,
  Loader,
  CheckCircle2,
  Ban,
} as const;

export function ExpenseStatusBadge({
  status,
  showIcon = true,
  size = "default",
}: ExpenseStatusBadgeProps) {
  const config = EXPENSE_STATUS_CONFIG[status];
  const Icon = iconMap[config.icon as keyof typeof iconMap];

  const sizeClasses = {
    sm: "text-xs px-2 py-0.5",
    default: "text-xs px-2.5 py-0.5",
    lg: "text-sm px-3 py-1",
  };

  const iconSizes = {
    sm: "h-3 w-3",
    default: "h-3.5 w-3.5",
    lg: "h-4 w-4",
  };

  return (
    <Badge
      variant="outline"
      className={cn(
        "font-medium",
        config.bgColor,
        config.borderColor,
        config.color,
        sizeClasses[size]
      )}
    >
      {showIcon && Icon && (
        <Icon className={cn("mr-1", iconSizes[size], config.color)} />
      )}
      {config.label}
    </Badge>
  );
}

/**
 * ExpenseStatusIndicator - A simpler dot indicator for status
 */
interface ExpenseStatusIndicatorProps {
  status: ExpenseStatus;
  showLabel?: boolean;
}

export function ExpenseStatusIndicator({
  status,
  showLabel = false,
}: ExpenseStatusIndicatorProps) {
  const config = EXPENSE_STATUS_CONFIG[status];

  const dotColors: Record<ExpenseStatus, string> = {
    draft: "bg-gray-400",
    pending_leader: "bg-yellow-400",
    leader_approved: "bg-blue-400",
    leader_denied: "bg-red-400",
    pending_treasury: "bg-orange-400",
    treasury_approved: "bg-indigo-400",
    treasury_denied: "bg-red-400",
    pending_finance: "bg-purple-400",
    completed: "bg-green-400",
    cancelled: "bg-gray-400",
  };

  return (
    <div className="flex items-center gap-2">
      <span
        className={cn("h-2 w-2 rounded-full", dotColors[status])}
        aria-label={config.label}
      />
      {showLabel && (
        <span className={cn("text-sm", config.color)}>{config.label}</span>
      )}
    </div>
  );
}
