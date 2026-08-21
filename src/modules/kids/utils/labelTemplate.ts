/**
 * Thermal label markup.
 *
 * Pure: builds an HTML document as a string. Printing it is a separate,
 * impure concern (see labelPrintService), so the layout can be unit-tested.
 *
 * TWO SEPARATE LABELS, and the distinction is a safety property:
 *
 *   CHILD label  — name, classroom, a short room TAG. Authorises nothing.
 *   PARENT label — the pickup CODE and QR. Authorises release.
 *
 * They carry different values on purpose. If they shared one code, anyone who
 * could see a child could read the code that releases them. Per KID-010 the
 * parent label also carries no classroom and no medical information: a dropped
 * label must not tell a stranger where a named child is sitting.
 *
 * Direct thermal printing is monochrome, so nothing may depend on colour —
 * the allergy warning is a solid black bar with knockout white text.
 */

export interface ChildLabelData {
  childName: string;
  roomName: string | null;
  tagNumber: number;
  allergyLabel: string | null;
  isFirstTime?: boolean;
  serviceLabel: string;
  sessionDate: string;
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
 *   * Hairlines below about 0.3mm drop out unevenly at 300dpi. Rules are 0.6mm.
 *   * The cutter has roughly a millimetre of play, so nothing important sits
 *     within 3mm of an edge.
 *
 * WIDTH. DK-2205 tape is 62mm wide with about 2mm unprintable on each side, so
 * the printable strip is ~58mm. The page is 62 x 100mm because that is the
 * page the QL driver presents for DK-2205; content is top-aligned, so a short
 * label simply leaves the tail of the page blank rather than stretching.
 *
 * WHAT IS BIG IS DELIBERATE. The two things read most often, from furthest
 * away, are the ROOM (by a volunteer walking a child down a corridor) and the
 * child's NAME (by everyone else). Those get the size; service, date and tag
 * are reference data that only ever get read close up.
 *
 * If the printer is set to A4 or Letter instead of the tape — which is what a
 * misconfigured desk looks like — the labels still print, one per page, at the
 * correct physical size, rather than collapsing into an unreadable corner.
 */
export const LABEL_CSS = `
  @page { size: 62mm 100mm; margin: 0; }

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
    width: 58mm;
    margin: 0 auto;
    padding: 3mm 0;
    page-break-after: always;
    break-after: page;
    box-sizing: border-box;
  }
  .label:last-child { page-break-after: auto; break-after: auto; }

  /* ---- child label ---- */

  /* The room, in the strongest possible treatment: this is what a volunteer
     reads from across a corridor while holding the child's hand. */
  .roombar {
    background: #000; color: #fff;
    font-size: 15pt; font-weight: 800; line-height: 1.15;
    letter-spacing: 0.2mm;
    padding: 1.6mm 2mm;
    text-align: center;
    text-transform: uppercase;
  }

  .name {
    font-size: 32pt; font-weight: 800; line-height: 1.02;
    margin: 3mm 0 0; word-break: break-word; hyphens: none;
  }
  /* Long names shrink rather than wrapping into four cramped lines. */
  .name.long { font-size: 24pt; }
  .name.verylong { font-size: 18pt; }

  /* Reads as an alarm with no colour available. Full bleed to the label edge
     so it cannot be mistaken for a caption. */
  .allergy {
    background: #000; color: #fff;
    font-size: 13pt; font-weight: 800; line-height: 1.2;
    letter-spacing: 0.3mm;
    padding: 1.8mm 2mm;
    margin-top: 3mm;
    text-align: center;
    text-transform: uppercase;
  }
  .allergy .word { display: block; font-size: 9pt; letter-spacing: 0.6mm; }

  .firsttime {
    font-size: 11pt; font-weight: 700; margin-top: 2.5mm;
    border: 0.6mm solid #000; padding: 1.2mm 2mm; text-align: center;
  }

  .footrule { border-top: 0.6mm solid #000; margin-top: 3mm; padding-top: 1.5mm; }
  .foot { display: flex; justify-content: space-between; align-items: baseline; }
  .foot .when { font-size: 8pt; line-height: 1.25; }
  .tag { font-size: 15pt; font-weight: 800; white-space: nowrap; }

  /* ---- parent label ---- */

  .banner {
    font-size: 9pt; font-weight: 800; letter-spacing: 0.8mm;
    text-align: center; text-transform: uppercase;
  }
  .codelabel {
    font-size: 8pt; letter-spacing: 0.5mm; text-align: center;
    text-transform: uppercase; margin-top: 2.5mm;
  }
  /* The whole reason the parent label exists. Monospaced so 8 and B cannot be
     confused when it is read aloud across a busy corridor. */
  .code {
    font-family: "Courier New", Courier, monospace;
    font-size: 33pt; font-weight: 700; letter-spacing: 1.2mm;
    text-align: center; line-height: 1.1; margin-top: 0.5mm;
  }
  .qr { text-align: center; margin-top: 2.5mm; }
  .qr svg { width: 26mm; height: 26mm; display: inline-block; }
  .who { text-align: center; font-size: 10pt; font-weight: 700; margin-top: 2.5mm; }
  .when-c { text-align: center; font-size: 8pt; margin-top: 0.8mm; }
  .keep {
    text-align: center; font-size: 9pt; font-weight: 700;
    border-top: 0.6mm solid #000; margin-top: 2.5mm; padding-top: 1.5mm;
  }
`;

/**
 * Long names shrink instead of running off the edge.
 *
 * The binding constraint is the longest single WORD, not the total: a name
 * wraps between words but not within one, so "Bethlehem Gebremariam" is set by
 * whether "Gebremariam" fits the 58mm strip. Ethiopian names run long enough
 * that this is the common case, not the exception.
 */
function nameClass(name: string): string {
  const words = name.trim().split(/\s+/);
  const longest = words.reduce((n, w) => Math.max(n, w.length), 0);
  const total = name.trim().length;
  if (longest <= 8 && total <= 14) return "name";
  if (longest <= 11 && total <= 24) return "name long";
  return "name verylong";
}

export function buildChildLabel(data: ChildLabelData): string {
  return `
    <div class="label">
      <div class="roombar">${esc(data.roomName ?? "Check-in")}</div>
      <div class="${nameClass(data.childName)}">${esc(data.childName)}</div>
      ${
        data.allergyLabel
          ? `<div class="allergy"><span class="word">Allergy</span>${esc(
              data.allergyLabel.toUpperCase()
            )}</div>`
          : ""
      }
      ${data.isFirstTime ? `<div class="firsttime">★ FIRST TIME ★</div>` : ""}
      <div class="footrule">
        <div class="foot">
          <div class="when">${esc(data.serviceLabel)}<br>${esc(data.sessionDate)}</div>
          <div class="tag">Tag ${esc(data.tagNumber)}</div>
        </div>
      </div>
    </div>`;
}

export function buildParentLabel(data: ParentLabelData): string {
  const code = data.pickupCode.length === 6
    ? `${data.pickupCode.slice(0, 3)}-${data.pickupCode.slice(3)}`
    : data.pickupCode;

  return `
    <div class="label">
      <div class="banner">ALIC Kids — Pickup</div>
      <div class="codelabel">Show this code to collect</div>
      <div class="code">${esc(code)}</div>
      ${data.qrSvg ? `<div class="qr">${data.qrSvg}</div>` : ""}
      <div class="who">${esc(data.householdName)} · ${esc(data.childCount)} ${
        data.childCount === 1 ? "child" : "children"
      }</div>
      ${
        data.childNames && data.childNames.length
          ? `<div class="when-c">${esc(data.childNames.join(", "))}</div>`
          : ""
      }
      <div class="when-c">${esc(data.serviceLabel)} · ${esc(data.sessionDate)}</div>
      <div class="keep">Keep this — required for pickup</div>
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
