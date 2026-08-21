/**
 * Thermal label markup.
 *
 * Pure: builds an HTML document as a string. Printing it is a separate,
 * impure concern (see labelPrintService), so the layout can be unit-tested.
 *
 * TWO SEPARATE LABELS, and the distinction is a safety property:
 *
 *   CHILD label  — name, classroom, guardian, a short room TAG. Authorises nothing.
 *   PARENT label — the pickup CODE and QR. Authorises release.
 *
 * They carry different values on purpose. If they shared one code, anyone who
 * could see a child could read the code that releases them. Per KID-010 the
 * parent label also carries no classroom and no medical information: a dropped
 * label must not tell a stranger where a named child is sitting.
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
  allergyLabel: string | null;
  isFirstTime?: boolean;
  serviceLabel: string;
  sessionDate: string;
  /** Who dropped the child off, printed at the foot of the tag. */
  guardianName?: string | null;
  /** Masked at the station by design — useful to cross-check, not to dial. */
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
    /* The reference's outlined card. A border also gives the volunteer a
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

  /* The classroom. Read by a volunteer walking a child down a corridor, so it
     is the largest thing after the name. */
  .room { font-size: 15pt; font-weight: 800; line-height: 1.1; }
  .when { font-size: 9pt; margin-top: 0.6mm; }

  /* Guardian, at the foot where a nurse or a volunteer looks for it. */
  .guardian { display: flex; justify-content: space-between; gap: 2mm; font-size: 8.5pt; }
  .guardian .gname { font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .guardian .gphone { white-space: nowrap; }

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
  /* Stacked upright, so it reads without turning the label sideways. */
  .tab .tabnum {
    writing-mode: vertical-rl; text-orientation: upright;
    font-size: 17pt; font-weight: 800; letter-spacing: -0.4mm;
    margin: 1mm 0;
  }
  .tab .tabmark { font-size: 11pt; line-height: 1; }

  /* Reads as an alarm with no colour available. Full width, below the tab row,
     so it cannot be mistaken for a caption on the details block. */
  .allergy {
    background: #000; color: #fff;
    font-size: 13pt; font-weight: 800; line-height: 1.2;
    letter-spacing: 0.3mm;
    padding: 1.8mm 2mm;
    margin-top: 2.5mm;
    border-radius: 1.5mm;
    text-align: center;
    text-transform: uppercase;
  }
  .allergy .word { display: block; font-size: 9pt; letter-spacing: 0.6mm; }

  .firsttime {
    font-size: 11pt; font-weight: 700; margin-top: 2mm;
    border: 0.5mm solid #000; padding: 1.2mm 2mm; text-align: center;
  }

  /* ---- parent label ---- */

  .service { font-size: 16pt; font-weight: 800; text-align: center; line-height: 1.15; }
  /* The whole reason the parent label exists, in the strongest treatment on
     either label: knockout on solid black, monospaced so 8 and B cannot be
     confused when the code is read aloud across a busy corridor. */
  .codebar {
    background: #000; color: #fff;
    font-family: "Courier New", Courier, monospace;
    font-size: 34pt; font-weight: 700; letter-spacing: 1.5mm;
    text-align: center; line-height: 1.2;
    border-radius: 1.5mm;
    padding: 2mm 1mm; margin-top: 2.5mm;
  }
  .qr { text-align: center; margin-top: 2.5mm; }
  .qr svg { width: 26mm; height: 26mm; display: inline-block; }
  .retain {
    text-align: center; font-size: 9pt; font-weight: 700;
    margin-top: 1.5mm;
  }
  .who { text-align: center; font-size: 9pt; margin-top: 2mm; }
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
          <div class="when">${esc(data.serviceLabel)} · ${esc(data.sessionDate)}</div>
          ${
            guardian || phone
              ? `<div class="rule"></div>
          <div class="guardian">
            <span class="gname">${esc(guardian)}</span>
            <span class="gphone">${esc(phone)}</span>
          </div>`
              : ""
          }
        </div>
        <div class="tab">
          <span class="tabword">TAG</span>
          <span class="tabnum">${esc(data.tagNumber)}</span>
          <span class="tabmark">✓</span>
        </div>
      </div>
      ${
        data.allergyLabel
          ? `<div class="allergy"><span class="word">Allergy</span>${esc(
              data.allergyLabel.toUpperCase()
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
    <div class="label">
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
