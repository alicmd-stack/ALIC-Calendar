import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const RESEND_API_KEY = Deno.env.get("RESEND_API");

interface EventNotificationRequest {
  to: string;
  eventTitle: string;
  eventStartTime: string;
  eventEndTime: string;
  roomName: string;
  status: "approved" | "rejected" | "published" | "unapproved";
  requesterName: string;
  reviewerNotes?: string;
}

serve(async (req) => {
  try {
    const {
      to,
      eventTitle,
      eventStartTime,
      eventEndTime,
      roomName,
      status,
      requesterName,
      reviewerNotes,
    }: EventNotificationRequest = await req.json();

    if (!to || !eventTitle || !status) {
      return new Response(
        JSON.stringify({ error: "Missing required fields" }),
        {
          status: 400,
          headers: { "Content-Type": "application/json" },
        }
      );
    }

    // Generate email content based on status
    let subject = "";
    let heading = "";
    let message = "";
    let statusColor = "";
    let statusBadge = "";
    let statusIcon = "";

    switch (status) {
      case "approved":
      case "published":
        subject = `✅ Event Approved: ${eventTitle}`;
        heading = "Your Event Has Been Approved!";
        message = `Congratulations! Your event request for "${eventTitle}" has been approved and is now published to the ALIC calendar. Attendees can now view and register for your event.`;
        statusColor = "#22c55e";
        statusBadge = "APPROVED & PUBLISHED";
        statusIcon = "✨";
        break;
      case "rejected":
        subject = `Event Status: ${eventTitle}`;
        heading = "Event Status Update";
        message = `Thank you for submitting your event request for "${eventTitle}". After careful review, we are unable to approve this event at this time. Please review any notes below from the administrator.`;
        statusColor = "#ef4444";
        statusBadge = "NOT APPROVED";
        statusIcon = "📋";
        break;
      case "unapproved":
        subject = `📌 Event Status Changed: ${eventTitle}`;
        heading = "Event Moved to Pending Review";
        message = `Your event "${eventTitle}" has been moved back to pending review status. Our team may need additional information or there may be requested changes. You will be notified once the review is complete.`;
        statusColor = "#f59e0b";
        statusBadge = "PENDING REVIEW";
        statusIcon = "⏳";
        break;
      default:
        subject = `Event Update: ${eventTitle}`;
        heading = "Event Status Update";
        message = `Your event "${eventTitle}" status has been updated.`;
        statusColor = "#3b82f6";
        statusBadge = "UPDATED";
        statusIcon = "🔔";
    }

    const htmlBody = `
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${subject}</title>
  <!--[if mso]>
  <style type="text/css">
    body, table, td {font-family: Arial, Helvetica, sans-serif !important;}
  </style>
  <![endif]-->
</head>
<body style="margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; background-color: #f0f4f8;">
  <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="background-color: #f0f4f8; padding: 40px 20px;">
    <tr>
      <td align="center">
        <!-- Main Container -->
        <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="600" style="max-width: 600px; background-color: #ffffff; border-radius: 16px; overflow: hidden; box-shadow: 0 10px 40px rgba(0, 0, 0, 0.12);">

          <!-- Decorative Top Bar -->
          <tr>
            <td style="background: linear-gradient(90deg, #1e40af 0%, #3b82f6 50%, #60a5fa 100%); height: 6px; line-height: 0; font-size: 0;">
              &nbsp;
            </td>
          </tr>

          <!-- ALIC Logo Header -->
          <tr>
            <td style="background: linear-gradient(135deg, #1e3a8a 0%, #1e40af 50%, #3b82f6 100%); padding: 50px 40px 40px; text-align: center; position: relative;">
              <!-- Logo/Brand -->
              <div style="margin-bottom: 20px;">
                <div style="display: inline-block; background-color: rgba(255, 255, 255, 0.15); backdrop-filter: blur(10px); padding: 16px 24px; border-radius: 12px; border: 2px solid rgba(255, 255, 255, 0.2);">
                  <h2 style="margin: 0; color: #ffffff; font-size: 32px; font-weight: 800; letter-spacing: 2px; text-transform: uppercase;">
                    ALIC
                  </h2>
                  <p style="margin: 4px 0 0; color: rgba(255, 255, 255, 0.9); font-size: 11px; font-weight: 600; letter-spacing: 1.5px; text-transform: uppercase;">
                    Event Management
                  </p>
                </div>
              </div>

              <!-- Main Heading with Icon -->
              <div style="margin-top: 24px;">
                <div style="font-size: 48px; margin-bottom: 12px; filter: drop-shadow(0 2px 4px rgba(0, 0, 0, 0.2));">
                  ${statusIcon}
                </div>
                <h1 style="margin: 0; color: #ffffff; font-size: 30px; font-weight: 700; letter-spacing: -0.5px; line-height: 1.3; text-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);">
                  ${heading}
                </h1>
              </div>

              <!-- Decorative Element -->
              <div style="margin-top: 20px; height: 2px; width: 60px; background: linear-gradient(90deg, transparent, rgba(255, 255, 255, 0.5), transparent); margin-left: auto; margin-right: auto;"></div>
            </td>
          </tr>

          <!-- Status Badge with Animation-style Design -->
          <tr>
            <td style="padding: 0; text-align: center; transform: translateY(-24px);">
              <div style="display: inline-block; background: linear-gradient(135deg, ${statusColor} 0%, ${status === 'approved' || status === 'published' ? '#16a34a' : status === 'rejected' ? '#dc2626' : '#d97706'} 100%); color: #ffffff; padding: 12px 32px; border-radius: 50px; font-size: 13px; font-weight: 700; letter-spacing: 1px; box-shadow: 0 8px 16px rgba(0, 0, 0, 0.15), 0 0 0 4px #ffffff, 0 0 0 6px ${statusColor}20;">
                ${statusBadge}
              </div>
            </td>
          </tr>

          <!-- Main Message -->
          <tr>
            <td style="padding: 0 40px 40px;">
              <p style="margin: 0 0 20px; color: #1f2937; font-size: 17px; line-height: 1.7; font-weight: 500;">
                Hello <span style="color: #2563eb; font-weight: 600;">${requesterName}</span>,
              </p>
              <p style="margin: 0; color: #4b5563; font-size: 16px; line-height: 1.7;">
                ${message}
              </p>
            </td>
          </tr>

          <!-- Event Details Card with Premium Design -->
          <tr>
            <td style="padding: 0 40px 40px;">
              <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="background: linear-gradient(135deg, #f8fafc 0%, #f1f5f9 100%); border-radius: 12px; border: 2px solid #e2e8f0; overflow: hidden; box-shadow: 0 4px 12px rgba(0, 0, 0, 0.05);">
                <!-- Card Header -->
                <tr>
                  <td style="background: linear-gradient(90deg, #1e40af 0%, #3b82f6 100%); padding: 16px 24px;">
                    <h3 style="margin: 0; color: #ffffff; font-size: 18px; font-weight: 700; letter-spacing: 0.5px;">
                      📅 Event Details
                    </h3>
                  </td>
                </tr>

                <!-- Card Body -->
                <tr>
                  <td style="padding: 24px;">
                    <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%">
                      <!-- Event Title -->
                      <tr>
                        <td colspan="2" style="padding: 0 0 20px 0;">
                          <div style="background-color: #ffffff; padding: 16px; border-radius: 8px; border-left: 4px solid #3b82f6;">
                            <p style="margin: 0 0 4px; color: #6b7280; font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px;">
                              Event Title
                            </p>
                            <p style="margin: 0; color: #1f2937; font-size: 18px; font-weight: 700; line-height: 1.4;">
                              ${eventTitle}
                            </p>
                          </div>
                        </td>
                      </tr>

                      <!-- Room & Times Grid -->
                      <tr>
                        <td style="padding: 0 8px 0 0; width: 50%; vertical-align: top;">
                          <div style="background-color: #ffffff; padding: 16px; border-radius: 8px; height: 100%;">
                            <p style="margin: 0 0 8px; color: #6b7280; font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px;">
                              📍 Location
                            </p>
                            <p style="margin: 0; color: #1f2937; font-size: 15px; font-weight: 600;">
                              ${roomName}
                            </p>
                          </div>
                        </td>
                        <td style="padding: 0 0 0 8px; width: 50%; vertical-align: top;">
                          <div style="background-color: #ffffff; padding: 16px; border-radius: 8px; height: 100%;">
                            <p style="margin: 0 0 8px; color: #6b7280; font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px;">
                              ⏰ Duration
                            </p>
                            <p style="margin: 0; color: #1f2937; font-size: 13px; font-weight: 600; line-height: 1.4;">
                              ${eventStartTime}
                            </p>
                            <p style="margin: 4px 0 0; color: #6b7280; font-size: 12px;">
                              to ${eventEndTime}
                            </p>
                          </div>
                        </td>
                      </tr>
                    </table>
                  </td>
                </tr>
              </table>
            </td>
          </tr>

          ${reviewerNotes ? `
          <!-- Reviewer Notes with Premium Design -->
          <tr>
            <td style="padding: 0 40px 40px;">
              <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="background: linear-gradient(135deg, #fef3c7 0%, #fde68a 100%); border-radius: 12px; border: 2px solid #fbbf24; box-shadow: 0 4px 12px rgba(251, 191, 36, 0.2);">
                <tr>
                  <td style="padding: 24px;">
                    <div style="margin-bottom: 12px;">
                      <span style="display: inline-block; background-color: #f59e0b; color: #ffffff; width: 32px; height: 32px; border-radius: 50%; text-align: center; line-height: 32px; font-size: 16px; margin-right: 12px; vertical-align: middle;">💬</span>
                      <span style="color: #92400e; font-size: 15px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px; vertical-align: middle;">Reviewer Notes</span>
                    </div>
                    <div style="background-color: rgba(255, 255, 255, 0.6); padding: 16px; border-radius: 8px; border-left: 4px solid #f59e0b;">
                      <p style="margin: 0; color: #78350f; font-size: 14px; line-height: 1.6; font-style: italic;">
                        "${reviewerNotes}"
                      </p>
                    </div>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
          ` : ''}

          <!-- Success Call to Action -->
          ${status === "approved" || status === "published" ? `
          <tr>
            <td style="padding: 0 40px 40px; text-align: center;">
              <div style="background: linear-gradient(135deg, #d1fae5 0%, #a7f3d0 100%); border: 2px solid #10b981; border-radius: 12px; padding: 20px; box-shadow: 0 4px 12px rgba(16, 185, 129, 0.15);">
                <div style="font-size: 36px; margin-bottom: 8px;">✅</div>
                <p style="margin: 0 0 8px; color: #065f46; font-size: 16px; font-weight: 700;">
                  Your event is now live!
                </p>
                <p style="margin: 0; color: #047857; font-size: 14px;">
                  It's now visible on the ALIC calendar and ready for attendees
                </p>
              </div>
            </td>
          </tr>
          ` : ''}

          <!-- Rejection Information -->
          ${status === "rejected" ? `
          <tr>
            <td style="padding: 0 40px 40px;">
              <div style="background: linear-gradient(135deg, #fee2e2 0%, #fecaca 100%); border: 2px solid #ef4444; border-radius: 12px; padding: 20px; box-shadow: 0 4px 12px rgba(239, 68, 68, 0.15);">
                <p style="margin: 0 0 12px; color: #991b1b; font-size: 14px; font-weight: 600;">
                  Need to make changes?
                </p>
                <p style="margin: 0; color: #7f1d1d; font-size: 13px; line-height: 1.6;">
                  If you have questions about this decision or would like to resubmit your event with modifications, please contact the calendar administrator.
                </p>
              </div>
            </td>
          </tr>
          ` : ''}

          <!-- Divider -->
          <tr>
            <td style="padding: 0 40px;">
              <div style="height: 1px; background: linear-gradient(90deg, transparent, #e5e7eb, transparent);"></div>
            </td>
          </tr>

          <!-- Premium Footer -->
          <tr>
            <td style="padding: 40px; background: linear-gradient(135deg, #f8fafc 0%, #f1f5f9 100%); text-align: center;">
              <!-- ALIC Branding -->
              <div style="margin-bottom: 16px;">
                <h3 style="margin: 0 0 4px; color: #1e40af; font-size: 18px; font-weight: 800; letter-spacing: 1.5px;">
                  ALIC
                </h3>
                <p style="margin: 0; color: #64748b; font-size: 11px; font-weight: 600; letter-spacing: 1px; text-transform: uppercase;">
                  Event Management System
                </p>
              </div>

              <!-- Divider -->
              <div style="height: 2px; width: 40px; background: linear-gradient(90deg, transparent, #cbd5e1, transparent); margin: 20px auto;"></div>

              <!-- Footer Text -->
              <p style="margin: 0 0 8px; color: #64748b; font-size: 12px; line-height: 1.5;">
                This is an automated notification from the ALIC Event Approval System
              </p>
              <p style="margin: 0; color: #94a3b8; font-size: 11px;">
                Please do not reply to this email
              </p>

              <!-- Copyright -->
              <p style="margin: 16px 0 0; color: #cbd5e1; font-size: 10px;">
                © ${new Date().getFullYear()} ALIC. All rights reserved.
              </p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>
    `;

    // Send email using Resend
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${RESEND_API_KEY}`,
      },
      body: JSON.stringify({
        from: "ALIC Event Management <onboarding@resend.dev>",
        to: [to],
        subject: subject,
        html: htmlBody,
      }),
    });

    const data = await res.json();

    if (res.ok) {
      return new Response(JSON.stringify({ success: true, data }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    } else {
      return new Response(
        JSON.stringify({ error: "Failed to send email", details: data }),
        {
          status: res.status,
          headers: { "Content-Type": "application/json" },
        }
      );
    }
  } catch (error) {
    return new Response(
      JSON.stringify({ error: error.message }),
      {
        status: 500,
        headers: { "Content-Type": "application/json" },
      }
    );
  }
});
