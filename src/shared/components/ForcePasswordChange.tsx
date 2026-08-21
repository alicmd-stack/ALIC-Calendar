/**
 * The screen a leader sees instead of the app until they replace the password
 * somebody else chose for them.
 *
 * Rendered by ProtectedRoute in place of the route's children, so there is no
 * URL to skip past and no navigation around it. Signing out is the only other
 * way forward, and that is offered rather than hidden — a volunteer who thinks
 * they are on the wrong account should be able to leave.
 *
 * The honest limit, stated in the migration too: this is an application gate,
 * not a cryptographic one. clear_password_change_required only ever acts on
 * auth.uid(), so nobody can clear it for anyone else, but a determined person
 * could call it against their own account without changing anything. It stops
 * the realistic failure, which is six volunteers all still sharing one
 * six-digit password months later because nothing ever asked.
 */

import { useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/shared/contexts/AuthContext";
import { Button } from "@/shared/components/ui/button";
import { Input } from "@/shared/components/ui/input";
import { Label } from "@/shared/components/ui/label";
import { Loader2, KeyRound, AlertTriangle } from "lucide-react";

/**
 * Longer than the project's configured minimum of 6.
 *
 * Six is what let "123456" be issued in the first place. These accounts can
 * read a child's medical record and authorise a pick-up, so the replacement
 * should not be able to be the same shape as the thing it replaces.
 */
const MIN_LENGTH = 8;

/** Starter passwords and the usual suspects, refused outright. */
const REFUSED = ["123456", "12345678", "password", "alic1234", "changeme"];

interface ForcePasswordChangeProps {
  /** Re-read the flag once the change succeeds, so the app renders. */
  onChanged: () => void;
}

export function ForcePasswordChange({ onChanged }: ForcePasswordChangeProps) {
  const { user } = useAuth();
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async () => {
    setError(null);
    const next = password.trim();

    if (next.length < MIN_LENGTH) {
      setError(`Use at least ${MIN_LENGTH} characters.`);
      return;
    }
    if (REFUSED.includes(next.toLowerCase())) {
      setError("That password is too easy to guess. Please choose another.");
      return;
    }
    if (next !== confirm.trim()) {
      setError("The two passwords do not match.");
      return;
    }

    setBusy(true);
    try {
      const { error: updateError } = await supabase.auth.updateUser({
        password: next,
      });
      if (updateError) {
        // Supabase refuses a password identical to the current one, which is
        // exactly the case this screen exists to prevent — say so plainly
        // rather than showing the raw message.
        setError(
          /same|different from the old/i.test(updateError.message)
            ? "That is the password you already have. Please choose a new one."
            : updateError.message
        );
        return;
      }

      // Only clear the flag once the password actually changed. If this call
      // fails the user simply sees this screen again, which is the safe way
      // round: the password is already updated, so nothing is lost.
      const { error: clearError } = await supabase.rpc(
        "clear_password_change_required"
      );
      if (clearError) {
        setError(
          "Your password was changed, but the confirmation did not save. Sign in again."
        );
        return;
      }

      onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not change the password.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="flex min-h-screen items-center justify-center bg-muted/30 p-4">
      <div className="w-full max-w-md rounded-lg border bg-background p-6 shadow-sm">
        <div className="flex items-center gap-3">
          <div className="rounded-full bg-primary/10 p-2">
            <KeyRound className="h-5 w-5 text-primary" />
          </div>
          <div>
            <h1 className="text-lg font-semibold">Choose a new password</h1>
            <p className="text-sm text-muted-foreground">
              {user?.email}
            </p>
          </div>
        </div>

        <div className="mt-4 flex gap-2 rounded-md border-2 border-amber-400 bg-amber-50 p-3">
          <AlertTriangle className="h-4 w-4 shrink-0 text-amber-600 mt-0.5" />
          <p className="text-sm">
            Your account was set up with a temporary password that other people
            know. Please replace it before you continue — this account can see
            children's medical information.
          </p>
        </div>

        <div className="mt-4 space-y-3">
          <div>
            <Label htmlFor="fpc-new">New password</Label>
            <Input
              id="fpc-new"
              type="password"
              autoComplete="new-password"
              className="h-11"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoFocus
            />
            <p className="mt-1 text-xs text-muted-foreground">
              At least {MIN_LENGTH} characters.
            </p>
          </div>

          <div>
            <Label htmlFor="fpc-confirm">Type it again</Label>
            <Input
              id="fpc-confirm"
              type="password"
              autoComplete="new-password"
              className="h-11"
              value={confirm}
              onChange={(e) => setConfirm(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !busy) submit();
              }}
            />
          </div>

          {error && <p className="text-sm font-medium text-destructive">{error}</p>}

          <Button className="w-full" onClick={submit} disabled={busy}>
            {busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
            Save and continue
          </Button>

          {/* Offered, not hidden: somebody who thinks they are signed in as the
              wrong person needs a way out that is not the browser Back button. */}
          <Button
            variant="ghost"
            className="w-full"
            disabled={busy}
            onClick={() => supabase.auth.signOut()}
          >
            Sign out instead
          </Button>
        </div>
      </div>
    </div>
  );
}
