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
 * Page CSS for a Brother QL series on 62mm continuous stock (DK-2205).
 * 2mm is left unprintable on each edge.
 */
export const LABEL_CSS = `
  @page { size: 62mm 100mm; margin: 0; }
  html, body { width: 62mm; margin: 0; padding: 0; background: #fff; }
  * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  .label {
    width: 58mm; height: 96mm; margin: 2mm;
    overflow: hidden; page-break-after: always; break-after: page;
    font-family: "Arial Black", Arial, Helvetica, sans-serif; color: #000;
    display: flex; flex-direction: column;
  }
  .label:last-child { page-break-after: auto; break-after: auto; }
  .name { font-size: 30pt; line-height: 1.05; font-weight: 900; }
  .room { font-size: 16pt; margin-top: 2mm; }
  .meta { font-size: 9pt; margin-top: auto; }
  .tag  { font-size: 12pt; font-weight: 900; }
  .allergy {
    background: #000; color: #fff; font-size: 12pt; font-weight: 900;
    padding: 1.5mm 2mm; margin-top: 3mm; text-align: center;
    letter-spacing: 0.4mm;
  }
  .firsttime { font-size: 11pt; margin-top: 2mm; }
  .code {
    font-family: "Courier New", monospace; font-size: 34pt; font-weight: 900;
    letter-spacing: 2mm; text-align: center; margin: 3mm 0;
  }
  .qr { text-align: center; }
  .qr svg { width: 25mm; height: 25mm; }
  .banner { font-size: 11pt; font-weight: 900; letter-spacing: 0.5mm; }
  .keep { font-size: 9pt; margin-top: 2mm; }
  .center { text-align: center; }
`;

export function buildChildLabel(data: ChildLabelData): string {
  return `
    <div class="label">
      <div class="name">${esc(data.childName)}</div>
      ${data.roomName ? `<div class="room">${esc(data.roomName)}</div>` : ""}
      ${
        data.allergyLabel
          ? `<div class="allergy">${esc(data.allergyLabel.toUpperCase())}</div>`
          : ""
      }
      ${data.isFirstTime ? `<div class="firsttime">★ FIRST TIME</div>` : ""}
      <div class="meta">
        <div>${esc(data.serviceLabel)} · ${esc(data.sessionDate)}</div>
        <div class="tag">Tag ${esc(data.tagNumber)}</div>
      </div>
    </div>`;
}

export function buildParentLabel(data: ParentLabelData): string {
  const code = data.pickupCode.length === 6
    ? `${data.pickupCode.slice(0, 3)}-${data.pickupCode.slice(3)}`
    : data.pickupCode;

  return `
    <div class="label center">
      <div class="banner">ALIC KIDS — PICKUP</div>
      <div class="code">${esc(code)}</div>
      ${data.qrSvg ? `<div class="qr">${data.qrSvg}</div>` : ""}
      <div class="meta">
        <div>${esc(data.householdName)}</div>
        <div>${esc(data.childCount)} ${data.childCount === 1 ? "child" : "children"}</div>
        ${
          data.childNames && data.childNames.length
            ? `<div>${esc(data.childNames.join(", "))}</div>`
            : ""
        }
        <div>${esc(data.serviceLabel)} · ${esc(data.sessionDate)}</div>
        <div class="keep">Keep this. Required for pickup.</div>
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
