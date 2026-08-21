/**
 * Label template tests.
 *
 * The safety-relevant assertions here are about what must NOT appear on the
 * parent's label: no classroom, no medical detail. A dropped label should not
 * tell a stranger where a named child is sitting.
 */

import { describe, it, expect } from "vitest";
import {
  buildChildLabel,
  buildParentLabel,
  buildLabelDocument,
  LABEL_CSS,
} from "./labelTemplate";

const CHILD = {
  childName: "Noah Bekele",
  roomName: "Blossom A",
  tagNumber: 1000,
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
    // The tag number lives in the edge tab, stacked upright by CSS, so the
    // word and the number are separate elements.
    expect(html).toContain('class="tabword">TAG<');
    expect(html).toContain('class="tabnum">1000<');
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

  it("carries no pickup code — the child label authorises nothing", () => {
    const html = buildChildLabel(CHILD);
    expect(html).not.toContain("3R6F4T");
    expect(html).not.toContain("PICKUP");
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

  it("sets the 62mm page size the Brother QL driver expects", () => {
    const doc = buildLabelDocument([CHILD], PARENT);
    expect(doc).toContain("@page { size: 62mm 100mm; margin: 0; }");
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
