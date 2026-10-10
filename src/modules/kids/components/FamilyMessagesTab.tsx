/**
 * Messages to families: a kids admin writes to every family, or to member,
 * regular attendee or visitor families only, or those with no status, by the
 * same family rule the attendance report filters by.
 *
 * One way. The email comes from the church's no-reply address and says so;
 * nothing here reads replies. The greeting, the blessing and the church's
 * details are added around the message by send-kids-notification, and the
 * preview beside the form draws them the same way.
 *
 * The counts come from the database before anything is sent, so the button
 * says how many parents it will write to, and a choice that reaches nobody
 * (visitor families, on 10 October: the desk takes a phone number, not an
 * email) says why instead of "sent".
 */

import { useMemo, useState } from "react";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/shared/components/ui/card";
import { Button } from "@/shared/components/ui/button";
import { Input } from "@/shared/components/ui/input";
import { Label } from "@/shared/components/ui/label";
import { Textarea } from "@/shared/components/ui/textarea";
import { Progress } from "@/shared/components/ui/progress";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/shared/components/ui/select";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/shared/components/ui/alert-dialog";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/shared/components/ui/table";
import {
  AlertTriangle,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  Loader2,
  MailCheck,
  Send,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { useToast } from "@/shared/hooks/use-toast";
import { errorMessage } from "../services/rpcError";
import { FAMILIES, FAMILY_BY_KEY, type FamilyFilter } from "../utils/attendanceFamilies";
import {
  BODY_MAX,
  DEFAULT_REACH,
  PLACEHOLDER,
  REACHES,
  SUBJECT_MAX,
  hasPlaceholder,
  plural,
  reachLabel,
  refusalMessage,
  templateFor,
  type SentMessage,
} from "../utils/familyMessages";
import { useMessageAudience, useSendFamilyMessage, useSentMessages } from "../hooks/useFamilyMessages";
import { FamilyMessagePreview } from "./FamilyMessagePreview";

/** The families a message can go to, in the order the report uses. */
const CHOICES: { key: FamilyFilter; label: string; bg: string; hint: string }[] = [
  { key: "all", label: "All families", bg: "bg-foreground/50", hint: "Every family, whatever their status" },
  ...FAMILIES.map((f) => ({ key: f.key, label: f.label, bg: f.bg, hint: f.hint })),
];

/** "member families", "families with no status": what the summary calls them. */
function familiesNoun(family: FamilyFilter, n: number): string {
  if (family === "all") return n === 1 ? "family" : "families";
  const only = FAMILY_BY_KEY[family].only.toLowerCase();
  return n === 1 ? only.replace("families", "family") : only;
}

/** Select values are strings; "all" is every family on record. */
const reachValue = (days: number | null) => (days === null ? "all" : String(days));

const when = (iso: string) =>
  new Date(iso).toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });

export function FamilyMessagesTab({ organizationId }: { organizationId: string | undefined }) {
  const { toast } = useToast();
  const [family, setFamily] = useState<FamilyFilter>("all");
  const [reach, setReach] = useState<number | null>(DEFAULT_REACH);
  const [subject, setSubject] = useState(() => templateFor("all").subject);
  const [body, setBody] = useState(() => templateFor("all").body);
  const [confirming, setConfirming] = useState(false);

  const audience = useMessageAudience(organizationId, reach);
  const sent = useSentMessages(organizationId);
  const send = useSendFamilyMessage(organizationId);

  const counts = useMemo(
    () => new Map((audience.data ?? []).map((row) => [row.family, row])),
    [audience.data],
  );
  const chosen = counts.get(family);
  const emails = chosen?.emails ?? 0;
  const unreachable = chosen ? chosen.families - chosen.reachable : 0;

  // The starting wording follows the families chosen until the admin edits it.
  function chooseFamily(next: FamilyFilter) {
    const before = templateFor(family);
    const after = templateFor(next);
    if (subject === before.subject) setSubject(after.subject);
    if (body === before.body) setBody(after.body);
    setFamily(next);
  }

  const placeholderLeft = hasPlaceholder(body);
  const subjectOk = subject.trim().length > 0 && subject.trim().length <= SUBJECT_MAX;
  const bodyOk = body.trim().length > 0 && body.trim().length <= BODY_MAX && !placeholderLeft;
  const ready = subjectOk && bodyOk && !send.isPending;

  async function deliver(test: boolean) {
    try {
      const result = await send.mutateAsync({
        family,
        cameWithinDays: reach,
        subject,
        body,
        test,
      });
      if (test) {
        toast({
          title: "Test on its way",
          description: "Sent to your own email address only. It arrives within a minute or two.",
        });
      } else {
        toast({
          title: `Sending to ${plural(result.emails, "parent", "parents")}`,
          description: `${plural(result.families, "family", "families")}. It goes out over the next few minutes; follow it under Sent messages.`,
        });
        const fresh = templateFor(family);
        setSubject(fresh.subject);
        setBody(fresh.body);
      }
    } catch (err) {
      toast({
        variant: "destructive",
        title: test ? "Could not send the test" : "Could not send",
        description: refusalMessage(errorMessage(err)),
      });
    } finally {
      setConfirming(false);
    }
  }

  return (
    <div className="space-y-4">
      <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(0,30rem)]">
        {/* The message ------------------------------------------------- */}
        <Card>
          <CardHeader>
            <CardTitle className="text-base">New message to families</CardTitle>
            <CardDescription>
              Sent by email to every parent with an address on record, from the church&rsquo;s
              no-reply address. Parents cannot reply to it.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-5">
            {/* To */}
            <section className="space-y-2.5" aria-labelledby="message-to">
              <h3 id="message-to" className="text-sm font-medium">
                To
              </h3>
              <div className="flex flex-wrap gap-1.5" role="group" aria-label="Families">
                {CHOICES.map((c) => {
                  const row = counts.get(c.key);
                  return (
                    <Button
                      key={c.key}
                      type="button"
                      size="sm"
                      variant={family === c.key ? "secondary" : "outline"}
                      aria-pressed={family === c.key}
                      title={c.hint}
                      onClick={() => chooseFamily(c.key)}
                      className={cn(family === c.key && "ring-1 ring-primary/40")}
                    >
                      <span className={cn("mr-1.5 h-2 w-2 rounded-full", c.bg)} aria-hidden />
                      {c.label}
                      <span className="ml-1.5 tabular-nums text-muted-foreground">
                        {row ? row.families.toLocaleString("en-US") : "–"}
                      </span>
                    </Button>
                  );
                })}
              </div>
              <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
                <Select
                  value={reachValue(reach)}
                  onValueChange={(v) => setReach(v === "all" ? null : Number(v))}
                >
                  <SelectTrigger className="h-9 w-full sm:w-64" aria-label="Which families">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {REACHES.map((r) => (
                      <SelectItem key={reachValue(r.days)} value={reachValue(r.days)}>
                        {r.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <p className="text-xs text-muted-foreground">
                  Families with a child up to 8th grade. The numbers are families.
                </p>
              </div>

              {/* Who it reaches, before anything is sent. */}
              <div
                className={cn(
                  "rounded-md border px-3 py-2.5 text-sm transition-opacity",
                  audience.isPlaceholderData && "opacity-60",
                  chosen && emails === 0
                    ? "border-amber-300 bg-amber-50 text-amber-900 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200"
                    : "bg-muted/40",
                )}
                aria-live="polite"
              >
                {audience.isLoading ? (
                  <span className="inline-flex items-center gap-2 text-muted-foreground">
                    <Loader2 className="h-4 w-4 animate-spin" /> Counting families…
                  </span>
                ) : audience.isError ? (
                  <span className="text-muted-foreground">
                    The families could not be counted. {refusalMessage(errorMessage(audience.error))}
                  </span>
                ) : !chosen || chosen.families === 0 ? (
                  <span className="text-muted-foreground">
                    No families match. Try a longer time range.
                  </span>
                ) : emails === 0 ? (
                  <span className="flex gap-2">
                    <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />
                    <span>
                      None of these {plural(chosen.families, "family", "families")} has an email
                      address on record, so there is nobody to send it to.
                      {family === "visitor" &&
                        " The check-in desk takes a phone number from visiting families, not an email address. Once a parent's email is added in Members, they are included."}
                    </span>
                  </span>
                ) : (
                  <span>
                    <span className="font-semibold">{plural(emails, "parent", "parents")}</span> in{" "}
                    {chosen.reachable.toLocaleString("en-US")} {familiesNoun(family, chosen.reachable)}
                    <span className="text-muted-foreground"> · {reachLabel(reach)}</span>
                    {unreachable > 0 && (
                      <span className="mt-1 block text-xs text-muted-foreground">
                        {plural(unreachable, "more family has", "more families have")} no email
                        address on record and won&rsquo;t receive it.
                      </span>
                    )}
                  </span>
                )}
              </div>
            </section>

            {/* Subject */}
            <div className="space-y-1.5">
              <div className="flex items-baseline justify-between">
                <Label htmlFor="message-subject">Subject</Label>
                <span
                  className={cn(
                    "text-xs tabular-nums text-muted-foreground",
                    subject.trim().length > SUBJECT_MAX && "text-destructive",
                  )}
                >
                  {subject.trim().length}/{SUBJECT_MAX}
                </span>
              </div>
              <Input
                id="message-subject"
                value={subject}
                onChange={(e) => setSubject(e.target.value)}
                maxLength={SUBJECT_MAX + 20}
              />
            </div>

            {/* Message */}
            <div className="space-y-1.5">
              <Label htmlFor="message-body">Message</Label>
              <Textarea
                id="message-body"
                value={body}
                onChange={(e) => setBody(e.target.value)}
                rows={12}
                maxLength={BODY_MAX + 100}
                className="leading-relaxed"
              />
              <p className="text-xs text-muted-foreground">
                &ldquo;Selam&rdquo; and each parent&rsquo;s first name, the blessing and the
                church&rsquo;s details are added around your message. Leave a blank line between
                paragraphs.
              </p>
              {placeholderLeft && (
                <p className="text-xs font-medium text-amber-700 dark:text-amber-400">
                  Replace &ldquo;{PLACEHOLDER}&rdquo; with what you want to say.
                </p>
              )}
            </div>

            <div className="flex flex-col-reverse gap-2 border-t pt-4 sm:flex-row sm:items-center sm:justify-end">
              <Button
                type="button"
                variant="outline"
                disabled={!ready}
                onClick={() => deliver(true)}
              >
                <MailCheck className="h-4 w-4" />
                Send me a test
              </Button>
              <Button
                type="button"
                disabled={!ready || emails === 0 || audience.isPlaceholderData}
                onClick={() => setConfirming(true)}
              >
                {send.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : <Send className="h-4 w-4" />}
                {emails > 0 ? `Send to ${plural(emails, "parent", "parents")}` : "Send"}
              </Button>
            </div>
          </CardContent>
        </Card>

        {/* The preview -------------------------------------------------- */}
        <Card className="self-start xl:sticky xl:top-4">
          <CardHeader className="pb-3">
            <CardTitle className="text-base">Preview</CardTitle>
            <CardDescription>What a parent receives. Each sees their own first name.</CardDescription>
          </CardHeader>
          <CardContent>
            <FamilyMessagePreview subject={subject} body={body} />
          </CardContent>
        </Card>
      </div>

      <SentMessages messages={sent.data} isLoading={sent.isLoading} />

      <AlertDialog open={confirming} onOpenChange={(open) => !send.isPending && setConfirming(open)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Send to {plural(emails, "parent", "parents")}?</AlertDialogTitle>
            <AlertDialogDescription>
              &ldquo;{subject.trim()}&rdquo; goes to every parent with an email address in{" "}
              {chosen?.reachable.toLocaleString("en-US")}{" "}
              {familiesNoun(family, chosen?.reachable ?? 0)} ({reachLabel(reach)}). It goes out
              within a few minutes and cannot be taken back.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={send.isPending}>Cancel</AlertDialogCancel>
            <AlertDialogAction
              disabled={send.isPending}
              onClick={(e) => {
                // Keep the dialog open until the send settles.
                e.preventDefault();
                deliver(false);
              }}
            >
              {send.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
              Send
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

/** What has been sent, newest first, with each message's progress. */
function SentMessages({
  messages,
  isLoading,
}: {
  messages: SentMessage[] | undefined;
  isLoading: boolean;
}) {
  const [open, setOpen] = useState<string | null>(null);
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Sent messages</CardTitle>
        <CardDescription>
          Newest first. &ldquo;Sent&rdquo; means handed to the email service; a few may still be
          turned away by a parent&rsquo;s mailbox.
        </CardDescription>
      </CardHeader>
      <CardContent>
        {isLoading ? (
          <div className="flex justify-center py-8">
            <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
          </div>
        ) : !messages?.length ? (
          <p className="py-8 text-center text-sm text-muted-foreground">No messages sent yet.</p>
        ) : (
          <div className="overflow-x-auto rounded-md border">
            <Table>
              <TableHeader className="bg-muted/50">
                <TableRow>
                  <TableHead className="min-w-[16rem]">Message</TableHead>
                  <TableHead className="min-w-[10rem]">To</TableHead>
                  <TableHead className="min-w-[11rem]">Progress</TableHead>
                  <TableHead className="whitespace-nowrap">Sent</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {messages.map((m) => {
                  const isOpen = open === m.id;
                  const done = m.delivered + m.failed;
                  return (
                    <TableRow key={m.id} className="align-top">
                      <TableCell>
                        <button
                          type="button"
                          className="flex items-start gap-1.5 text-left"
                          aria-expanded={isOpen}
                          onClick={() => setOpen(isOpen ? null : m.id)}
                        >
                          {isOpen ? (
                            <ChevronDown className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />
                          ) : (
                            <ChevronRight className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />
                          )}
                          <span className="font-medium">{m.subject}</span>
                        </button>
                        {isOpen && (
                          <p className="ml-5 mt-2 whitespace-pre-line rounded-md bg-muted/50 p-3 text-sm text-muted-foreground">
                            {m.body}
                          </p>
                        )}
                      </TableCell>
                      <TableCell>
                        <span className="inline-flex items-center gap-1.5">
                          <span
                            className={cn(
                              "h-2 w-2 rounded-full",
                              m.family === "all" ? "bg-foreground/50" : FAMILY_BY_KEY[m.family]?.bg,
                            )}
                            aria-hidden
                          />
                          {m.family === "all" ? "All families" : FAMILY_BY_KEY[m.family]?.label ?? m.family}
                        </span>
                        <span className="block text-xs text-muted-foreground">
                          {plural(m.emails, "parent", "parents")} · {reachLabel(m.came_within_days)}
                        </span>
                      </TableCell>
                      <TableCell>
                        {m.pending > 0 ? (
                          <div className="space-y-1">
                            <span className="text-sm">
                              Sending · {done} of {m.emails}
                            </span>
                            <Progress value={m.emails ? (done / m.emails) * 100 : 0} className="h-1.5" />
                          </div>
                        ) : m.failed > 0 ? (
                          <span className="text-sm">
                            {m.delivered} sent ·{" "}
                            <span className="text-rose-700 dark:text-rose-400">{m.failed} failed</span>
                          </span>
                        ) : (
                          <span className="inline-flex items-center gap-1.5 text-sm">
                            <CheckCircle2 className="h-4 w-4 text-emerald-600" aria-hidden />
                            All {m.delivered} sent
                          </span>
                        )}
                      </TableCell>
                      <TableCell className="whitespace-nowrap text-sm">
                        {when(m.created_at)}
                        {m.sent_by_name && (
                          <span className="block text-xs text-muted-foreground">{m.sent_by_name}</span>
                        )}
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
