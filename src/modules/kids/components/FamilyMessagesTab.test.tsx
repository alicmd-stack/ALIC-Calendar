// @vitest-environment jsdom

/**
 * The family message composer, with the database calls mocked. Checks what
 * a kids admin relies on: the counts before sending, a choice that reaches
 * nobody saying so, the prompt having to be replaced, the wording following
 * the families until it is edited, and the confirmation sending exactly what
 * was chosen.
 */

import { describe, it, expect, vi, afterEach, beforeEach } from "vitest";
import "@testing-library/jest-dom/vitest";
import { cleanup, render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

const mutateAsync = vi.fn();
const AUDIENCE = [
  { family: "all", families: 170, reachable: 146, emails: 184 },
  { family: "member", families: 92, reachable: 89, emails: 114 },
  { family: "regular_attendee", families: 4, reachable: 4, emails: 6 },
  { family: "visitor", families: 19, reachable: 0, emails: 0 },
  { family: "not_recorded", families: 55, reachable: 53, emails: 64 },
];

vi.mock("../hooks/useFamilyMessages", () => ({
  useMessageAudience: () => ({ data: AUDIENCE, isLoading: false, isError: false, isPlaceholderData: false }),
  useSentMessages: () => ({
    data: [
      {
        id: "m1",
        created_at: "2026-10-10T18:00:00Z",
        subject: "Harvest picnic",
        body: "Bring a hat.",
        family: "member",
        came_within_days: 56,
        families: 89,
        emails: 114,
        sent_by_name: "Hanna T",
        delivered: 40,
        failed: 0,
        pending: 74,
      },
    ],
    isLoading: false,
  }),
  useSendFamilyMessage: () => ({ mutateAsync, isPending: false }),
}));
vi.mock("@/shared/hooks/use-toast", () => ({ useToast: () => ({ toast: vi.fn() }) }));

import { FamilyMessagesTab } from "./FamilyMessagesTab";

beforeEach(() => {
  mutateAsync.mockReset();
  mutateAsync.mockResolvedValue({ message_id: "m2", families: 89, emails: 114 });
});
afterEach(cleanup);

const families = () => screen.getByRole("group", { name: "Families" });
const message = () => screen.getByLabelText("Message") as HTMLTextAreaElement;

async function writeMessage(user: ReturnType<typeof userEvent.setup>, text = "The picnic is on Saturday.") {
  const box = message();
  const withText = box.value.replace("[Write your message here.]", text);
  await user.clear(box);
  await user.type(box, withText.replace(/[{[]/g, (c) => c + c));
}

describe("FamilyMessagesTab", () => {
  it("counts the parents a message would reach before it is sent", async () => {
    const user = userEvent.setup();
    render(<FamilyMessagesTab organizationId="org" />);
    await user.click(within(families()).getByRole("button", { name: /Members\s*92/ }));
    expect(screen.getByText("114 parents")).toBeInTheDocument();
    expect(screen.getByText(/3 more families have no email address/)).toBeInTheDocument();
  });

  it("says why visitor families cannot be written to, and offers no send", async () => {
    const user = userEvent.setup();
    render(<FamilyMessagesTab organizationId="org" />);
    await user.click(within(families()).getByRole("button", { name: /Visitors\s*19/ }));
    expect(screen.getByText(/takes a phone number from visiting families/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /^Send$/ })).toBeDisabled();
  });

  it("will not send while the prompt is still in the message", () => {
    render(<FamilyMessagesTab organizationId="org" />);
    expect(screen.getByText(/Replace .*with what you want to say/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Send to 184 parents/ })).toBeDisabled();
    expect(screen.getByRole("button", { name: /Send me a test/ })).toBeDisabled();
  });

  it("changes the starting wording with the families, until it is edited", async () => {
    const user = userEvent.setup();
    render(<FamilyMessagesTab organizationId="org" />);
    await user.click(within(families()).getByRole("button", { name: /Visitors/ }));
    expect(message().value).toMatch(/^Thank you for visiting/);
    await writeMessage(user, "See you Sunday.");
    await user.click(within(families()).getByRole("button", { name: /Members/ }));
    expect(message().value).toMatch(/See you Sunday\./);
  });

  it("sends exactly what was chosen, after confirming", async () => {
    const user = userEvent.setup();
    render(<FamilyMessagesTab organizationId="org" />);
    await user.click(within(families()).getByRole("button", { name: /Members\s*92/ }));
    await writeMessage(user);
    await user.click(screen.getByRole("button", { name: /Send to 114 parents/ }));
    const dialog = screen.getByRole("alertdialog");
    expect(dialog).toHaveTextContent(/89 member families \(last 8 weeks\)/);
    await user.click(within(dialog).getByRole("button", { name: "Send" }));
    expect(mutateAsync).toHaveBeenCalledWith(
      expect.objectContaining({ family: "member", cameWithinDays: 56, test: false }),
    );
    expect(mutateAsync.mock.calls[0][0].body).toContain("The picnic is on Saturday.");
  });

  it("sends a test to the writer alone, without confirming", async () => {
    const user = userEvent.setup();
    render(<FamilyMessagesTab organizationId="org" />);
    await writeMessage(user);
    await user.click(screen.getByRole("button", { name: /Send me a test/ }));
    expect(mutateAsync).toHaveBeenCalledWith(expect.objectContaining({ test: true }));
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  });

  it("shows a message still going out with its progress", () => {
    render(<FamilyMessagesTab organizationId="org" />);
    expect(screen.getByText("Harvest picnic")).toBeInTheDocument();
    expect(screen.getByText("Sending · 40 of 114")).toBeInTheDocument();
  });
});
