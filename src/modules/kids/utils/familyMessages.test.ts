import { describe, it, expect } from "vitest";
import {
  PLACEHOLDER,
  hasPlaceholder,
  reachLabel,
  refusalMessage,
  templateFor,
} from "./familyMessages";

describe("templateFor", () => {
  it("starts every message with the prompt the admin replaces", () => {
    for (const family of ["all", "member", "regular_attendee", "visitor", "not_recorded"] as const) {
      expect(templateFor(family).body).toContain(PLACEHOLDER);
      expect(hasPlaceholder(templateFor(family).body)).toBe(true);
    }
  });

  it("thanks visitors for visiting, and everyone else for belonging", () => {
    expect(templateFor("visitor").body).toMatch(/^Thank you for visiting Addis Lidet/);
    expect(templateFor("member").body).toMatch(/^Thank you for being part of the Addis Lidet family/);
    expect(templateFor("all")).toEqual(templateFor("member"));
  });

  it("leaves the greeting and the blessing to the email itself", () => {
    const { body } = templateFor("all");
    expect(body).not.toMatch(/Selam|Be blessed/);
  });
});

describe("hasPlaceholder", () => {
  it("matches the prompt the database refuses, even with the full stop removed", () => {
    expect(hasPlaceholder("Hello\n\n[Write your message here]")).toBe(true);
    expect(hasPlaceholder("Hello, the picnic is on Saturday.")).toBe(false);
  });
});

describe("refusalMessage", () => {
  it("puts the database's refusals into words, and passes anything else through", () => {
    expect(refusalMessage("no_recipients")).toMatch(/no.*email address on record/i);
    expect(refusalMessage("already_sent")).toMatch(/not sent again/);
    expect(refusalMessage("not_permitted")).toMatch(/Only kids admins/);
    expect(refusalMessage("network down")).toBe("network down");
  });
});

describe("reachLabel", () => {
  it("names each reach", () => {
    expect(reachLabel(56)).toBe("last 8 weeks");
    expect(reachLabel(null)).toBe("everyone on record");
    expect(reachLabel(10)).toBe("last 10 days");
  });
});
