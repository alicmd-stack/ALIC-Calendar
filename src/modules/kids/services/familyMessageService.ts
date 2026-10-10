/**
 * Messages to families, by the family filter the attendance report uses.
 *
 * Nothing here sends an email. church.kids_send_family_message puts one row
 * per parent into notification_log, and the minute's dispatch sends them
 * through send-kids-notification, after any check-in or pickup email waiting.
 */

import { supabase } from "@/integrations/supabase/client";
import { throwRpc } from "./rpcError";
import type { FamilyFilter } from "../utils/attendanceFamilies";
import type { AudienceRow, SentMessage } from "../utils/familyMessages";

const church = () => supabase.schema("church");

export interface SendFamilyMessage {
  family: FamilyFilter;
  /** Families whose children came in this many days; null for everyone on record. */
  cameWithinDays: number | null;
  subject: string;
  body: string;
  /** To the sender alone, marked [Test], and not recorded as sent. */
  test?: boolean;
}

export const familyMessageService = {
  /** How many families and parents each choice of families would reach. */
  async audience(organizationId: string, cameWithinDays: number | null): Promise<AudienceRow[]> {
    const { data, error } = await church().rpc("kids_family_message_audience", {
      _organization_id: organizationId,
      // The generated type says number; null is "every family on record".
      _came_within_days: cameWithinDays as number,
    });
    throwRpc(error);
    return (data ?? []) as unknown as AudienceRow[];
  },

  async send(
    organizationId: string,
    message: SendFamilyMessage,
  ): Promise<{ message_id: string | null; families: number; emails: number }> {
    const { data, error } = await church().rpc("kids_send_family_message", {
      _organization_id: organizationId,
      _family: message.family,
      _came_within_days: message.cameWithinDays as number,
      _subject: message.subject,
      _body: message.body,
      _test: message.test ?? false,
    });
    throwRpc(error);
    const row = (data as unknown as { message_id: string | null; families: number; emails: number }[] | null)?.[0];
    return row ?? { message_id: null, families: 0, emails: 0 };
  },

  /** What has been sent, newest first, and how far each has got. */
  async sent(organizationId: string): Promise<SentMessage[]> {
    const { data, error } = await church().rpc("kids_family_messages_sent", {
      _organization_id: organizationId,
    });
    throwRpc(error);
    return (data ?? []) as unknown as SentMessage[];
  },
};
