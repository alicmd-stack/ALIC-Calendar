/**
 * Thermal label markup.
 *
 * Pure: builds an HTML document as a string. Printing it is a separate,
 * impure concern (see labelPrintService), so the layout can be unit-tested.
 *
 * TWO LABELS PER FAMILY:
 *
 *   CHILD label  — name, classroom, guardian and phone, and the pickup code.
 *   PARENT label — the pickup code and its QR.
 *
 * BOTH NOW CARRY THE SAME CODE. That is a deliberate reversal by the ministry
 * lead, and it removes a property the original design had: the child used to
 * wear a tag NUMBER while the parent held a separate code, so seeing a child
 * told you nothing about how to release them. It now does.
 *
 * What still stands in the way is at the desk, not on the label: check_out
 * refuses to release a child with a restriction on file unless the collector is
 * named, the volunteer records who is collecting, and every attempt is audited.
 * The code is a matching key now, not a secret from anyone in the room.
 *
 * The parent label still carries no classroom and no medical information, per
 * KID-010 — a slip dropped in a car park must not say where a named child is
 * sitting. The child's own tag necessarily does, because it is worn in that
 * classroom by that child.
 *
 * The layout follows the standard church check-in tag: name dominant, details
 * beneath a rule, guardian at the foot, and a black tab down the right edge
 * carrying the tag number. The tab is there because a worn tag gets folded and
 * curled — the flat face stops being readable, and the edge does not.
 *
 * Direct thermal printing is monochrome, so nothing may depend on colour —
 * the allergy warning is a solid black bar with knockout white text.
 */

export interface ChildLabelData {
  childName: string;
  roomName: string | null;
  tagNumber: number;
  /** Printed down the edge tab. Same code as the parent slip — see the note above. */
  pickupCode: string;
  allergyLabel: string | null;
  isFirstTime?: boolean;
  serviceLabel: string;
  sessionDate: string;
  /** Who dropped the child off, printed at the foot of the tag. */
  guardianName?: string | null;
  /** A dialable number: the volunteer holding a crying child has to call it. */
  guardianPhone?: string | null;
}

export interface ParentLabelData {
  householdName: string;
  childCount: number;
  pickupCode: string;
  /** Inline SVG for the QR, or null when QR generation is unavailable. */
  qrSvg: string | null;
  serviceLabel: string;
  sessionDate: string;
  /** Off by default: a dropped label should not name the children. */
  childNames?: string[];
}

/** Escape for HTML interpolation. A name containing & or < must not break the label. */
function esc(value: string | number | null | undefined): string {
  if (value === null || value === undefined) return "";
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/**
 * Page and label CSS for a Brother QL-820NWB on DK-2205 (62mm continuous).
 *
 * DIRECT THERMAL, which constrains the design more than anything else:
 *
 *   * There is no grey. The head either burns a dot or it does not, so a grey
 *     is dithered into a muddy stipple that looks like a printing fault at arm's
 *     length. Everything here is pure #000 on #fff.
 *   * There is no colour, so nothing may DEPEND on colour. The allergy warning
 *     is a solid black bar with knocked-out white text — it reads as an alarm
 *     even to someone glancing across a room.
 *   * Hairlines below about 0.3mm drop out unevenly at 300dpi. Rules are 0.5mm.
 *   * The cutter has roughly a millimetre of play, so nothing important sits
 *     within 3mm of an edge.
 *
 * WIDTH. DK-2205 tape is 62mm wide with about 2mm unprintable on each side, so
 * the printable strip is ~58mm. The page is 62 x 100mm because that is the
 * page the QL driver presents for DK-2205; content is top-aligned, so a short
 * label simply leaves the tail of the page blank rather than stretching.
 *
 * If the printer is set to A4 or Letter instead of the tape — which is what a
 * misconfigured desk looks like — the labels still print, one per page, at the
 * correct physical size, rather than collapsing into an unreadable corner.
 */
/**
 * The printed page, in millimetres.
 *
 * 62mm is the tape. 90mm is the LABEL LENGTH, and it is derived rather than
 * guessed: the tallest label the template can produce, with every field at its
 * limit at once, measures 84.4mm. Everything is bounded — the name shrinks in
 * tiers, the allergy string is capped, the classroom is the only thing allowed
 * to wrap freely — so that bound is real and not a hope.
 *
 * It used to be 100mm, which meant 20 to 43mm of blank tape on every label.
 * On a continuous roll that is not cosmetic: a busy Sunday is several hundred
 * labels.
 */
export const LABEL_PAGE_MM = { width: 62, length: 90 } as const;

export const LABEL_CSS = `
  @page { size: 62mm 90mm; margin: 0; }

  html, body {
    margin: 0; padding: 0; background: #fff;
    -webkit-print-color-adjust: exact; print-color-adjust: exact;
  }
  body {
    font-family: "Helvetica Neue", Helvetica, Arial, sans-serif;
    color: #000;
    /* Kerning and ligatures cost legibility at 300dpi on thermal stock. */
    font-kerning: none; font-variant-ligatures: none;
    -webkit-font-smoothing: none;
  }

  .label {
    /* 58 + 2 + 2 = the full 62mm tape, stated explicitly rather than left to
       "margin: 0 auto". Centring rounded to whole device pixels and landed
       1.75mm from one edge and 2.31mm from the other — harmless on tape with a
       millimetre of feed play, but there is no reason to be lopsided. */
    width: 58mm;
    margin: 2mm;
    /* A FIXED height, so every label is the same physical size and the card
       matches the piece of tape it is printed on. */
    height: 86mm;
    /* The backstop. Content is bounded, but a machine that substitutes a font
       with different metrics could still overflow — and overflow here means the
       label paginates, so the desk hands out one label cut in half and one
       nearly blank. Clipping a millimetre is the lesser failure. */
    overflow: hidden;
    /* The reference's outlined card. The border also gives the volunteer a
       cutting guide when the roll is fed through a manual cutter. */
    border: 0.5mm solid #000; border-radius: 2mm;
    padding: 2.5mm;
    page-break-after: always;
    break-after: page;
    box-sizing: border-box;
  }
  .label:last-child { page-break-after: auto; break-after: auto; }

  /* ---- child label ---- */

  /* Face and edge tab side by side. The tab is fixed width; the face takes
     whatever is left, and min-width:0 lets a long name wrap inside it rather
     than pushing the tab off the tape. */
  .tagrow { display: flex; align-items: stretch; gap: 2mm; }
  .face { flex: 1; min-width: 0; }

  .name {
    font-size: 30pt; font-weight: 800; line-height: 1.02;
    word-break: break-word; hyphens: none;
  }
  /* Long names shrink rather than running off the edge. */
  .name.long { font-size: 23pt; }
  .name.verylong { font-size: 17pt; }

  .rule { border-top: 0.5mm solid #000; margin: 2mm 0 1.5mm; }

  /* Classroom and tag share a line: both are routing information, and the tag
     is what the live board lists by. */
  .roomrow { display: flex; align-items: baseline; justify-content: space-between; gap: 2mm; }
  /* The classroom, read by a volunteer walking a child down a corridor, so it
     is the largest thing after the name. */
  /* Wraps rather than truncates. "Redeemed A" ellipsised to "Redee…", and the
     classroom is the one field on this label that must never be cut — it is
     the whole reason a volunteer picks the tag up. */
  .room { font-size: 15pt; font-weight: 800; line-height: 1.1; min-width: 0; }
  .tagno { font-size: 8.5pt; white-space: nowrap; flex: 0 0 auto; }
  .when { font-size: 8.5pt; margin-top: 0.6mm; }

  /* Guardian at the foot, name over number.
     Stacked rather than side by side because they were fighting for one line:
     "Dawit Bekele" next to "301-555-0102" truncated the name to "Dawit Bek…",
     and the name is how a volunteer knows who to ask for. The number is the
     larger of the two — someone reads it while holding a crying child. */
  .guardian { font-size: 8.5pt; line-height: 1.25; }
  .guardian .gname { font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .guardian .gphone { font-size: 11pt; font-weight: 700; white-space: nowrap; }

  /* The edge tab: solid black, knockout, running down the right-hand side.
     A worn tag curls and the flat face stops being readable; the edge does not. */
  .tab {
    width: 11mm; flex: 0 0 11mm;
    background: #000; color: #fff; border-radius: 1.5mm;
    display: flex; flex-direction: column;
    align-items: center; justify-content: space-between;
    padding: 1.5mm 0; box-sizing: border-box;
  }
  .tab .tabword { font-size: 7pt; font-weight: 800; letter-spacing: 0.3mm; }
  /* Stacked upright, so it reads without turning the label sideways.
     Monospaced to match the parent slip: the two get held side by side at the
     door, and a code has to be comparable at a glance. */
  .tab .tabcode {
    writing-mode: vertical-rl; text-orientation: upright;
    font-family: "Courier New", Courier, monospace;
    font-size: 17pt; font-weight: 700; letter-spacing: -0.2mm;
    margin: 1mm 0;
  }
  .tab .tabmark { font-size: 11pt; line-height: 1; }

  /* Reads as an alarm with no colour available. Full width, below the tab row,
     so it cannot be mistaken for a caption on the details block. */
  .allergy {
    background: #000; color: #fff;
    font-size: 13pt; font-weight: 800; line-height: 1.2;
    /* size drops in tiers below — see allergyClass() */
    letter-spacing: 0.3mm;
    padding: 1.8mm 2mm;
    margin-top: 2.5mm;
    border-radius: 1.5mm;
    text-align: center;
    text-transform: uppercase;
  }
  .allergy.long { font-size: 11pt; letter-spacing: 0.2mm; }
  .allergy.verylong { font-size: 9pt; letter-spacing: 0; }
  .allergy .word { display: block; font-size: 9pt; letter-spacing: 0.6mm; }
  .allergy.long .word, .allergy.verylong .word { font-size: 8pt; }

  .firsttime {
    font-size: 11pt; font-weight: 700; margin-top: 2mm;
    border: 0.5mm solid #000; padding: 1.2mm 2mm; text-align: center;
  }

  /* ---- parent label ---- */

  /* Only the parent slip centres in its card, and it uses flex with every
     child at flex:0 0 auto. A fixed-height flex COLUMN shrinks its children to
     fit by default, which would silently squash the allergy bar rather than
     letting the overflow guard catch it — so the child tag stays a plain block
     with its content top-aligned, name first. */
  .label.parent { display: flex; flex-direction: column; justify-content: center; }
  .label.parent > * { flex: 0 0 auto; }

  .service { font-size: 14pt; font-weight: 800; text-align: center; line-height: 1.15; }
  /* The whole reason the parent label exists, in the strongest treatment on
     either label: knockout on solid black, monospaced so 8 and B cannot be
     confused when the code is read aloud across a busy corridor. */
  .codebar {
    background: #000; color: #fff;
    font-family: "Courier New", Courier, monospace;
    font-size: 30pt; font-weight: 700; letter-spacing: 1.5mm;
    text-align: center; line-height: 1.15;
    border-radius: 1.5mm;
    padding: 1.5mm 1mm; margin-top: 2mm;
  }
  .qr { text-align: center; margin-top: 2mm; }
  /* 22mm carries a 4-character payload with room to spare at 300dpi, and the
     printed code below it is the fallback if a scanner ever struggles. */
  .qr svg { width: 22mm; height: 22mm; display: inline-block; }
  .retain {
    text-align: center; font-size: 9pt; font-weight: 700;
    margin-top: 1.5mm;
  }
  .who { text-align: center; font-size: 9pt; margin-top: 1.5mm; }
  .who .hh { font-weight: 700; }
`;

/**
 * Long names shrink instead of running off the edge.
 *
 * The binding constraint is the longest single WORD, not the total: a name
 * wraps between words but not within one, so "Bethlehem Gebremariam" is set by
 * whether "Gebremariam" fits. Ethiopian names run long enough that this is the
 * common case, not the exception. The thresholds are tighter than they look
 * because the edge tab takes 13mm off the usable width.
 */
function nameClass(name: string): string {
  const words = name.trim().split(/\s+/);
  const longest = words.reduce((n, w) => Math.max(n, w.length), 0);
  const total = name.trim().length;
  if (longest <= 7 && total <= 13) return "name";
  if (longest <= 10 && total <= 22) return "name long";
  return "name verylong";
}

/**
 * Keeps the allergy bar inside the label.
 *
 * allergy_label_short is unbounded free text — nothing stops a volunteer typing
 * a paragraph into it — so the bar has to be bounded here, where the space is
 * finite. Size drops in tiers first, because shrinking loses nothing.
 *
 * The CAP is a last resort. 60 characters holds a real allergen list with room
 * to spare — the longest on file at ALIC is 21 ("Peanuts and tree nuts"), and
 * "Peanuts, tree nuts, shellfish, dairy and eggs" is 44. Past that the tag
 * stops being the record and the black bar does its actual job, which is to say
 * STOP AND ASK — the full detail is on the safety card at the desk, where
 * reading it is audited.
 *
 * The cap is what makes the label's height BOUNDED, which is what lets the page
 * be sized to the tape instead of guessing. See LABEL_PAGE_MM below.
 */
const ALLERGY_CAP = 60;

function allergyClass(text: string): string {
  if (text.length > 44) return "allergy verylong";
  if (text.length > 22) return "allergy long";
  return "allergy";
}

function allergyText(raw: string): string {
  const t = raw.toUpperCase().trim();
  return t.length <= ALLERGY_CAP ? t : t.slice(0, ALLERGY_CAP - 1).trimEnd() + "\u2026";
}

export function buildChildLabel(data: ChildLabelData): string {
  const guardian = (data.guardianName ?? "").trim();
  const phone = (data.guardianPhone ?? "").trim();

  return `
    <div class="label">
      <div class="tagrow">
        <div class="face">
          <div class="${nameClass(data.childName)}">${esc(data.childName)}</div>
          <div class="rule"></div>
          <div class="room">${esc(data.roomName ?? "Check-in")}</div>
          <div class="when">
            ${esc(data.serviceLabel)} · ${esc(data.sessionDate)}<br>Tag ${esc(
              data.tagNumber
            )}
          </div>
          ${
            guardian || phone
              ? `<div class="rule"></div>
          <div class="guardian">
            ${guardian ? `<div class="gname">${esc(guardian)}</div>` : ""}
            ${phone ? `<div class="gphone">${esc(phone)}</div>` : ""}
          </div>`
              : ""
          }
        </div>
        <div class="tab">
          <span class="tabword">CODE</span>
          <span class="tabcode">${esc(data.pickupCode)}</span>
          <span class="tabmark">✓</span>
        </div>
      </div>
      ${
        data.allergyLabel
          ? `<div class="${allergyClass(data.allergyLabel.trim())}"><span class="word">Allergy</span>${esc(
              allergyText(data.allergyLabel)
            )}</div>`
          : ""
      }
      ${data.isFirstTime ? `<div class="firsttime">★ FIRST TIME ★</div>` : ""}
    </div>`;
}

export function buildParentLabel(data: ParentLabelData): string {
  // Four characters read as one unit — the reference prints R2D2, not R2-D2.
  // A six-character legacy code still gets the grouping that made it readable.
  const code = data.pickupCode.length === 6
    ? `${data.pickupCode.slice(0, 3)}-${data.pickupCode.slice(3)}`
    : data.pickupCode;

  return `
    <div class="label parent">
      <div class="service">${esc(data.serviceLabel)}<br>${esc(data.sessionDate)}</div>
      <div class="codebar">${esc(code)}</div>
      ${data.qrSvg ? `<div class="qr">${data.qrSvg}</div>` : ""}
      <div class="retain">Retain for child pickup</div>
      <div class="who">
        <span class="hh">${esc(data.householdName)}</span> · ${esc(data.childCount)} ${
          data.childCount === 1 ? "child" : "children"
        }
        ${
          data.childNames && data.childNames.length
            ? `<br>${esc(data.childNames.join(", "))}`
            : ""
        }
      </div>
    </div>`;
}

/** Complete printable document: one child label each, then the parent label. */
export function buildLabelDocument(
  children: ChildLabelData[],
  parent: ParentLabelData
): string {
  const body = [...children.map(buildChildLabel), buildParentLabel(parent)].join("\n");
  return `<!doctype html><html><head><meta charset="utf-8">
<title>Kids labels</title><style>${LABEL_CSS}</style></head>
<body>${body}</body></html>`;
}
