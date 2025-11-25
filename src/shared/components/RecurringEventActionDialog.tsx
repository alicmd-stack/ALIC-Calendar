import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/shared/components/ui/dialog";
import { Button } from "@/shared/components/ui/button";

export type RecurringActionScope = "single" | "all";

interface RecurringEventActionDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onConfirm: (scope: RecurringActionScope) => void;
  actionType: "delete" | "reject" | "update";
  eventTitle: string;
  loading?: boolean;
}

export function RecurringEventActionDialog({
  open,
  onOpenChange,
  onConfirm,
  actionType,
  eventTitle,
  loading = false,
}: RecurringEventActionDialogProps) {
  const actionVerb = actionType === "delete" ? "Delete" : actionType === "reject" ? "Reject" : "Update";
  const actionVerbLower = actionType === "delete" ? "delete" : actionType === "reject" ? "reject" : "update";

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-[425px]">
        <DialogHeader>
          <DialogTitle>{actionVerb} Recurring Event</DialogTitle>
          <DialogDescription>
            "{eventTitle}" is part of a recurring series. Would you like to {actionVerbLower} only this event or the entire series?
          </DialogDescription>
        </DialogHeader>
        <DialogFooter className="flex-col sm:flex-col gap-2">
          <Button
            type="button"
            variant="outline"
            onClick={() => onConfirm("single")}
            disabled={loading}
            className="w-full"
          >
            {actionVerb} Only This Event
          </Button>
          <Button
            type="button"
            variant={actionType === "update" ? "default" : "destructive"}
            onClick={() => onConfirm("all")}
            disabled={loading}
            className="w-full"
          >
            {actionVerb} All Events in Series
          </Button>
          <Button
            type="button"
            variant="ghost"
            onClick={() => onOpenChange(false)}
            disabled={loading}
            className="w-full"
          >
            Cancel
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
