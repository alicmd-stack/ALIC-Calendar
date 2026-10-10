/**
 * Messages to families: the starting wording, who can be reached, and what a
 * refusal from church.kids_send_family_message means in words.
 *
 * The email a parent receives is built around the message by
 * send-kids-notification, as every parent email is: "Selam Meseret," above it,
 * the blessing, the ministry's name and Matthew 19:14 below. So the wording
 * here is only the middle, and a kids admin replaces the prompt in it with
 * what they want to say.
 */

import type { FamilyFilter } from "./attendanceFamilies";

/**
 * The prompt the admin replaces. The database refuses a message that still
 * holds it (placeholder_left_in), so both sides must use the same words.
 */
export const PLACEHOLDER = "[Write your message here.]";

export interface MessageTemplate {
  subject: string;
  body: string;
}

const CLOSING =
  "If you have any questions, please speak to any of the Children's Ministry team on Sunday.";

/** The wording a new message starts from, for the families it is going to. */
export function templateFor(family: FamilyFilter): MessageTemplate {
  if (family === "visitor") {
    return {
      subject: "Thank you for visiting with your family",
      body: [
        "Thank you for visiting Addis Lidet with your family. It was a joy to have your children with us, and we hope you all felt at home.",
        PLACEHOLDER,
        `We would love to see you again soon. ${CLOSING}`,
      ].join("\n\n"),
    };
  }
  return {
    subject: "News from the Children's Ministry",
    body: [
      "Thank you for being part of the Addis Lidet family, and for trusting us with your children each week. It is a joy to have them with us.",
      PLACEHOLDER,
      CLOSING,
    ].join("\n\n"),
  };
}

export const hasPlaceholder = (body: string) => body.includes("[Write your message here");

/** How far back "families who came" reaches. null is every family on record. */
export const REACHES: { days: number | null; label: string; short: string }[] = [
  { days: 28, label: "Came in the last 4 weeks", short: "last 4 weeks" },
  { days: 56, label: "Came in the last 8 weeks", short: "last 8 weeks" },
  { days: 182, label: "Came in the last 6 months", short: "last 6 months" },
  { days: null, label: "Every family on record", short: "everyone on record" },
];

export const DEFAULT_REACH = 56;

export function reachLabel(days: number | null): string {
  return (
    REACHES.find((r) => r.days === days)?.short ??
    (days === null ? "everyone on record" : `last ${days} days`)
  );
}

/** Subject and message limits, the same as the database's. */
export const SUBJECT_MAX = 150;
export const BODY_MAX = 10_000;

/** One row of church.kids_family_message_audience. */
export interface AudienceRow {
  family: FamilyFilter;
  /** Families with a child in the audience. */
  families: number;
  /** Of those, families with at least one parent to email. */
  reachable: number;
  /** Distinct email addresses. */
  emails: number;
}

/** One row of church.kids_family_messages_sent. */
export interface SentMessage {
  id: string;
  created_at: string;
  subject: string;
  body: string;
  family: FamilyFilter;
  came_within_days: number | null;
  families: number;
  emails: number;
  sent_by_name: string | null;
  /** Handed to the email service. */
  delivered: number;
  failed: number;
  /** Still waiting in the queue. */
  pending: number;
}

/** What the database's refusals mean, for a kids admin. */
const REFUSALS: Record<string, string> = {
  not_permitted: "Only kids admins can send messages to families.",
  no_recipients:
    "None of these families has an email address on record, so there is nobody to send it to.",
  already_sent:
    "This message went to these families a few minutes ago, so it was not sent again.",
  placeholder_left_in: `Replace "${PLACEHOLDER}" with your message first.`,
  invalid_subject: `Give the email a subject of up to ${SUBJECT_MAX} characters.`,
  invalid_body: `Write a message of up to ${BODY_MAX.toLocaleString("en-US")} characters.`,
  invalid_family: "Choose which families to send it to.",
  invalid_reach: "Choose which families to send it to.",
  no_email_for_test: "Your account has no email address to send a test to.",
};

export function refusalMessage(raw: string): string {
  return REFUSALS[raw.trim()] ?? raw;
}

export const plural = (n: number, one: string, many: string) =>
  `${n.toLocaleString("en-US")} ${n === 1 ? one : many}`;
