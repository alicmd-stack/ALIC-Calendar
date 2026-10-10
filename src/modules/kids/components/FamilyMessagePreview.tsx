/**
 * The email as a parent will see it, drawn the way send-kids-notification's
 * renderEmail draws a parent email: the church's red band, the subject, a
 * greeting by first name, the message, the blessing and Matthew 19:14, and
 * the footer. Change one and the other must follow.
 *
 * In an email's own colours whatever the app's theme, because that is what
 * arrives in the inbox.
 */

const RED = "#b22222";
const VERSE =
  "“Let the little children come to me, and do not hinder them, for the kingdom of heaven belongs to such as these.” Matthew 19:14";
const NO_REPLY =
  "Replies to this email are not read. For anything about your children, please speak to the Children's Ministry team\u00a0on\u00a0Sunday.";

interface Props {
  subject: string;
  body: string;
  /** The first name the greeting uses in the preview. */
  firstName?: string;
}

export function FamilyMessagePreview({ subject, body, firstName = "Meseret" }: Props) {
  const paragraphs = body
    .split(/\n{2,}/)
    .map((p) => p.trim())
    .filter(Boolean);
  return (
    <div className="rounded-lg bg-[#f4f4f5] p-3 sm:p-4" aria-label="Email preview">
      <div className="mx-auto max-w-[520px] overflow-hidden rounded-xl border border-[#e4e4e7] bg-white text-[#18181b]">
        <div className="flex items-center gap-3 px-5 py-4" style={{ background: RED }}>
          <img src="/alic-logo.png" alt="" className="h-10 w-10 rounded-full bg-white" />
          <div className="text-white">
            <div className="text-[15px] font-semibold leading-tight">
              Addis Lidet International Church
            </div>
            <div className="text-[12.5px] opacity-90">Children&rsquo;s Ministry · የልጆች አገልግሎት</div>
          </div>
        </div>
        <div className="space-y-4 px-5 pb-5 pt-5 text-[15px] leading-relaxed">
          <p className="text-lg font-semibold leading-snug">
            {subject.trim() || "Children's Ministry"}
          </p>
          <p>Selam {firstName},</p>
          {paragraphs.length === 0 ? (
            <p className="text-[#a1a1aa]">Your message appears here.</p>
          ) : (
            paragraphs.map((p, i) => (
              <p key={i} className="whitespace-pre-line break-words">
                {p}
              </p>
            ))
          )}
          <p>
            Be blessed · <span style={{ color: RED }}>ተባረኩ</span>
            <br />
            Addis Lidet Children&rsquo;s Ministry
          </p>
          <p className="border-t border-[#f0e4e4] pt-3 text-[13px] italic leading-snug text-[#71717a]">
            {VERSE}
          </p>
        </div>
        <div className="border-t border-[#e4e4e7] bg-[#fafafa] px-5 pb-[18px] pt-4 text-center text-xs leading-relaxed text-[#71717a]">
          <p className="mb-2.5">{NO_REPLY}</p>
          <p>
            <span className="font-semibold text-[#52525b]">Addis Lidet International Church</span>
            <br />
            Silver Spring, MD · Alexandria, VA
            <br />
            <span style={{ color: RED }}>alic.org</span>
          </p>
        </div>
      </div>
    </div>
  );
}
