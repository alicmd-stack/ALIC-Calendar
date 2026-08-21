/**
 * Label template tests.
 *
 * The safety-relevant assertions here are about what must NOT appear on the
 * PARENT's label: no classroom, no medical detail. A slip dropped in a car park
 * should not tell a stranger where a named child is sitting.
 *
 * The child's tag now carries the same pickup code as the parent slip, by the
 * ministry lead's decision — see the note at the top of labelTemplate.ts. The
 * test below pins that deliberately, so a future reader does not restore the
 * old two-namespace rule by accident.
 */

import { describe, it, expect } from "vitest";
import {
  buildChildLabel,
  buildParentLabel,
  buildLabelDocument,
  LABEL_CSS,
  LABEL_PAGE_MM,
} from "./labelTemplate";

const CHILD = {
  childName: "Noah Bekele",
  roomName: "Blossom A",
  tagNumber: 1000,
  pickupCode: "3R6F4T",
  allergyLabel: "Peanut allergy",
  serviceLabel: "9:00 AM Service",
  sessionDate: "Aug 24",
};

const PARENT = {
  householdName: "Bekele Household",
  childCount: 2,
  pickupCode: "3R6F4T",
  qrSvg: "<svg></svg>",
  serviceLabel: "9:00 AM Service",
  sessionDate: "Aug 24",
};

describe("child label", () => {
  it("shows the name, classroom and tag", () => {
    const html = buildChildLabel(CHILD);
    expect(html).toContain("Noah Bekele");
    expect(html).toContain("Blossom A");
    // The tag number sits on the detail line now; the edge tab holds the code.
    expect(html).toContain("Tag 1000");
  });

  it("prints the guardian at the foot when one is known", () => {
    const html = buildChildLabel({
      ...CHILD,
      guardianName: "Almaz Tesfaye",
      guardianPhone: "\u2022\u2022\u2022-0101",
    });
    expect(html).toContain("Almaz Tesfaye");
    expect(html).toContain("\u2022\u2022\u2022-0101");
  });

  it("omits the guardian row entirely when nobody is named", () => {
    // An empty rule and a blank line read as missing data rather than as
    // data that was never collected.
    expect(buildChildLabel(CHILD)).not.toContain('class="guardian"');
    expect(
      buildChildLabel({ ...CHILD, guardianName: "  ", guardianPhone: null })
    ).not.toContain('class="guardian"');
  });

  it("renders an approved allergy as an uppercase knockout bar", () => {
    // Direct thermal is monochrome, so the warning cannot rely on colour.
    const html = buildChildLabel(CHILD);
    expect(html).toContain("PEANUT ALLERGY");
    expect(html).toContain('class="allergy"');
  });

  it("omits the allergy bar entirely when there is none", () => {
    const html = buildChildLabel({ ...CHILD, allergyLabel: null });
    expect(html).not.toContain('class="allergy"');
  });

  it("marks a first-time visitor", () => {
    expect(buildChildLabel({ ...CHILD, isFirstTime: true })).toContain("FIRST TIME");
    expect(buildChildLabel(CHILD)).not.toContain("FIRST TIME");
  });

  it("carries the pickup code in the edge tab", () => {
    // A REVERSAL, pinned on purpose. The tab used to hold the tag number so
    // that seeing a child told you nothing about how to release them. The
    // ministry lead chose the matching-key model instead: both halves show the
    // same code, and the control moved to the desk, which names and records
    // whoever collects.
    const html = buildChildLabel(CHILD);
    expect(html).toContain('class="tabword">CODE<');
    expect(html).toContain('class="tabcode">3R6F4T<');
    // The tag number survives as reference data — the live board lists by tag.
    expect(html).toContain("Tag 1000");
  });

  it("prints a dialable phone, not a masked one", () => {
    // A masked number is useless to the volunteer holding a crying child,
    // which is the situation the number is on the tag for.
    const html = buildChildLabel({ ...CHILD, guardianPhone: "301-555-0102" });
    expect(html).toContain("301-555-0102");
  });
});

describe("parent label", () => {
  it("shows the pickup code, hyphenated for readability", () => {
    const html = buildParentLabel(PARENT);
    expect(html).toContain("3R6-F4T");
  });

  it("does NOT reveal the classroom (KID-010)", () => {
    const html = buildParentLabel(PARENT);
    expect(html).not.toContain("Blossom");
  });

  it("does NOT reveal medical information", () => {
    const html = buildParentLabel(PARENT);
    expect(html.toLowerCase()).not.toContain("peanut");
    expect(html.toLowerCase()).not.toContain("allergy");
  });

  it("shows a child count rather than names by default", () => {
    const html = buildParentLabel(PARENT);
    expect(html).toContain("2 children");
    expect(html).not.toContain("Noah");
  });

  it("can show names when the church opts in", () => {
    const html = buildParentLabel({ ...PARENT, childNames: ["Noah", "Maya"] });
    expect(html).toContain("Noah, Maya");
  });

  it("handles a single child without saying '1 children'", () => {
    expect(buildParentLabel({ ...PARENT, childCount: 1 })).toContain("1 child");
  });

  it("omits the QR block when generation was unavailable", () => {
    const html = buildParentLabel({ ...PARENT, qrSvg: null });
    expect(html).not.toContain('class="qr"');
    // The human-readable code must still be there — it is the fallback.
    expect(html).toContain("3R6-F4T");
  });
});

describe("escaping", () => {
  it("escapes a name containing markup rather than emitting it", () => {
    const html = buildChildLabel({
      ...CHILD,
      childName: '<script>alert("x")</script>',
    });
    expect(html).not.toContain("<script>");
    expect(html).toContain("&lt;script&gt;");
  });

  it("escapes ampersands and apostrophes in names", () => {
    const html = buildChildLabel({ ...CHILD, childName: "O'Brien & Sons" });
    expect(html).toContain("O&#39;Brien &amp; Sons");
  });

  it("leaves Amharic names intact", () => {
    const html = buildChildLabel({ ...CHILD, childName: "አበበ በቀለ" });
    expect(html).toContain("አበበ በቀለ");
  });
});

describe("label document", () => {
  it("emits one child label per child plus one parent label", () => {
    const doc = buildLabelDocument([CHILD, { ...CHILD, childName: "Maya Bekele" }], PARENT);
    const labelCount = (doc.match(/class="label/g) || []).length;
    expect(labelCount).toBe(3);
    expect(doc).toContain("Noah Bekele");
    expect(doc).toContain("Maya Bekele");
    expect(doc).toContain("3R6-F4T");
  });

  it("sets the page the Brother QL driver expects for 62mm tape", () => {
    const doc = buildLabelDocument([CHILD], PARENT);
    expect(doc).toContain("@page { size: 62mm 90mm; margin: 0; }");
  });

  it("keeps the declared page and the CSS in step", () => {
    // The length is derived from the tallest label the template can build
    // (measured at 84.4mm), not guessed. If one moves, the other must.
    expect(LABEL_PAGE_MM).toEqual({ width: 62, length: 90 });
    expect(LABEL_CSS).toContain(
      `@page { size: ${LABEL_PAGE_MM.width}mm ${LABEL_PAGE_MM.length}mm; margin: 0; }`
    );
  });

  it("caps the allergy text so a label cannot grow without bound", () => {
    // allergy_label_short is unbounded free text in the database.
    const long = "Peanuts, ".repeat(40);
    const html = buildChildLabel({ ...CHILD, allergyLabel: long });
    const bar = /<div class="allergy[^"]*"><span class="word">Allergy<\/span>([^<]*)</.exec(html);
    expect(bar).toBeTruthy();
    expect(bar![1].length).toBeLessThanOrEqual(60);
    expect(bar![1].endsWith("\u2026")).toBe(true);
  });

  it("shrinks the allergy bar in tiers rather than truncating early", () => {
    expect(buildChildLabel({ ...CHILD, allergyLabel: "Dairy" })).toContain('class="allergy"');
    expect(
      buildChildLabel({ ...CHILD, allergyLabel: "Peanuts, tree nuts and shellfish" })
    ).toContain('class="allergy long"');
    expect(
      buildChildLabel({
        ...CHILD,
        allergyLabel: "Peanuts, tree nuts, shellfish, dairy, eggs and sesame seeds",
      })
    ).toContain('class="allergy verylong"');
  });

  it("is a complete standalone document", () => {
    const doc = buildLabelDocument([CHILD], PARENT);
    expect(doc.startsWith("<!doctype html>")).toBe(true);
    expect(doc).toContain("<meta charset=\"utf-8\">");
  });
});

describe("label CSS", () => {
  it("forces colour printing of the knockout allergy bar", () => {
    // Without this the black bar can print as an empty outline.
    expect(LABEL_CSS).toContain("print-color-adjust: exact");
  });
});
