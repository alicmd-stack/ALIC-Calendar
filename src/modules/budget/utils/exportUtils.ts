/**
 * Export Utilities for Budget Module
 * Provides CSV, Excel-compatible, and print-friendly export functionality
 */

import type { ExpenseRequestWithRelations, MinistryBudgetSummary } from "../types";
import { EXPENSE_STATUS_CONFIG, REIMBURSEMENT_TYPE_LABELS } from "../types";

// CSV Export Helper
const escapeCSVValue = (value: string | number | null | undefined): string => {
  if (value === null || value === undefined) return "";
  const stringValue = String(value);
  // Escape quotes and wrap in quotes if contains comma, quote, or newline
  if (stringValue.includes(",") || stringValue.includes('"') || stringValue.includes("\n")) {
    return `"${stringValue.replace(/"/g, '""')}"`;
  }
  return stringValue;
};

const formatCurrency = (amount: number): string => {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
  }).format(amount);
};

const formatDate = (dateString: string | null): string => {
  if (!dateString) return "";
  return new Date(dateString).toLocaleDateString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
};

// =====================================================
// Expense Reports Export
// =====================================================

export interface ExportOptions {
  includeAttachments?: boolean;
  dateRange?: { from: string; to: string };
}

export const exportExpensesToCSV = (
  expenses: ExpenseRequestWithRelations[],
  filename: string = "expense-report"
): void => {
  const headers = [
    "ID",
    "Title",
    "Description",
    "Amount",
    "Status",
    "Ministry",
    "Requester",
    "Reimbursement Type",
    "TIN",
    "Advance Payment",
    "Different Recipient",
    "Recipient Name",
    "Recipient Phone",
    "Recipient Email",
    "Created Date",
    "Submitted Date",
    "Leader Reviewed",
    "Treasury Reviewed",
    "Completed Date",
    "Payment Reference",
  ];

  const rows = expenses.map((expense) => [
    expense.id,
    expense.title,
    expense.description || "",
    expense.amount,
    EXPENSE_STATUS_CONFIG[expense.status]?.label || expense.status,
    expense.ministry?.name || "",
    expense.requester_name,
    REIMBURSEMENT_TYPE_LABELS[expense.reimbursement_type] || expense.reimbursement_type,
    expense.tin || "",
    expense.is_advance_payment ? "Yes" : "No",
    expense.is_different_recipient ? "Yes" : "No",
    expense.recipient_name || "",
    expense.recipient_phone || "",
    expense.recipient_email || "",
    formatDate(expense.created_at),
    formatDate(expense.submitted_at),
    formatDate(expense.leader_reviewed_at),
    formatDate(expense.treasury_reviewed_at),
    formatDate(expense.finance_processed_at),
    expense.payment_reference || "",
  ]);

  const csvContent = [
    headers.map(escapeCSVValue).join(","),
    ...rows.map((row) => row.map(escapeCSVValue).join(",")),
  ].join("\n");

  downloadFile(csvContent, `${filename}-${getDateStamp()}.csv`, "text/csv");
};

export const exportExpensesToExcel = (
  expenses: ExpenseRequestWithRelations[],
  filename: string = "expense-report"
): void => {
  // Create Excel-compatible XML format
  const headers = [
    "ID",
    "Title",
    "Description",
    "Amount",
    "Status",
    "Ministry",
    "Requester",
    "Reimbursement Type",
    "TIN",
    "Advance Payment",
    "Different Recipient",
    "Recipient Name",
    "Recipient Phone",
    "Recipient Email",
    "Created Date",
    "Submitted Date",
    "Leader Reviewed",
    "Treasury Reviewed",
    "Completed Date",
    "Payment Reference",
  ];

  const rows = expenses.map((expense) => [
    expense.id,
    expense.title,
    expense.description || "",
    expense.amount,
    EXPENSE_STATUS_CONFIG[expense.status]?.label || expense.status,
    expense.ministry?.name || "",
    expense.requester_name,
    REIMBURSEMENT_TYPE_LABELS[expense.reimbursement_type] || expense.reimbursement_type,
    expense.tin || "",
    expense.is_advance_payment ? "Yes" : "No",
    expense.is_different_recipient ? "Yes" : "No",
    expense.recipient_name || "",
    expense.recipient_phone || "",
    expense.recipient_email || "",
    formatDate(expense.created_at),
    formatDate(expense.submitted_at),
    formatDate(expense.leader_reviewed_at),
    formatDate(expense.treasury_reviewed_at),
    formatDate(expense.finance_processed_at),
    expense.payment_reference || "",
  ]);

  const xmlContent = generateExcelXML(headers, rows, "Expense Report");
  downloadFile(xmlContent, `${filename}-${getDateStamp()}.xls`, "application/vnd.ms-excel");
};

// =====================================================
// Budget Summary Export
// =====================================================

export const exportBudgetSummaryToCSV = (
  summaries: MinistryBudgetSummary[],
  fiscalYearName: string,
  filename: string = "budget-summary"
): void => {
  const headers = [
    "Ministry",
    "Fiscal Year",
    "Allocated Budget",
    "Pending",
    "Approved",
    "Spent",
    "Remaining",
    "Usage %",
  ];

  const rows = summaries.map((summary) => {
    const usagePercent = summary.allocated_amount > 0
      ? ((summary.total_spent / summary.allocated_amount) * 100).toFixed(1)
      : "0.0";
    return [
      summary.ministry_name,
      summary.fiscal_year_name,
      formatCurrency(summary.allocated_amount),
      formatCurrency(summary.total_pending),
      formatCurrency(summary.total_approved),
      formatCurrency(summary.total_spent),
      formatCurrency(summary.remaining),
      `${usagePercent}%`,
    ];
  });

  // Add totals row
  const totals = summaries.reduce(
    (acc, s) => ({
      allocated: acc.allocated + s.allocated_amount,
      pending: acc.pending + s.total_pending,
      approved: acc.approved + s.total_approved,
      spent: acc.spent + s.total_spent,
      remaining: acc.remaining + s.remaining,
    }),
    { allocated: 0, pending: 0, approved: 0, spent: 0, remaining: 0 }
  );

  const totalUsage = totals.allocated > 0
    ? ((totals.spent / totals.allocated) * 100).toFixed(1)
    : "0.0";

  rows.push([
    "TOTAL",
    fiscalYearName,
    formatCurrency(totals.allocated),
    formatCurrency(totals.pending),
    formatCurrency(totals.approved),
    formatCurrency(totals.spent),
    formatCurrency(totals.remaining),
    `${totalUsage}%`,
  ]);

  const csvContent = [
    headers.map(escapeCSVValue).join(","),
    ...rows.map((row) => row.map(escapeCSVValue).join(",")),
  ].join("\n");

  downloadFile(csvContent, `${filename}-${getDateStamp()}.csv`, "text/csv");
};

// =====================================================
// Print-Friendly Report Generation
// =====================================================

export const generatePrintableExpenseReport = (
  expenses: ExpenseRequestWithRelations[],
  title: string = "Expense Report"
): void => {
  const totalAmount = expenses.reduce((sum, e) => sum + e.amount, 0);
  const approvedCount = expenses.filter(e =>
    ["treasury_approved", "leader_approved", "completed"].includes(e.status)
  ).length;
  const pendingCount = expenses.filter(e =>
    ["pending_leader", "pending_treasury", "pending_finance"].includes(e.status)
  ).length;
  const approvalRate = expenses.length > 0 ? ((approvedCount / expenses.length) * 100).toFixed(0) : "0";

  const html = `
    <!DOCTYPE html>
    <html>
    <head>
      <title>${title}</title>
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
          max-width: 1100px;
          margin: 0 auto;
          background: white;
          color: #1e293b;
        }
        .header {
          background: linear-gradient(135deg, #1e40af 0%, #3b82f6 100%);
          color: white;
          padding: 28px 36px;
          position: relative;
        }
        .header h1 {
          font-size: 24px;
          font-weight: 700;
          margin-bottom: 6px;
        }
        .header p {
          font-size: 13px;
          opacity: 0.9;
        }
        .summary-grid {
          display: grid;
          grid-template-columns: repeat(4, 1fr);
          gap: 0;
        }
        .summary-card {
          color: white;
          padding: 20px 24px;
          text-align: center;
        }
        .summary-card.total { background: linear-gradient(135deg, #059669 0%, #10b981 100%); }
        .summary-card.approved { background: linear-gradient(135deg, #2563eb 0%, #3b82f6 100%); }
        .summary-card.pending { background: linear-gradient(135deg, #d97706 0%, #f59e0b 100%); }
        .summary-card.rate { background: linear-gradient(135deg, #7c3aed 0%, #8b5cf6 100%); }
        .summary-card .label {
          font-size: 10px;
          text-transform: uppercase;
          letter-spacing: 1px;
          opacity: 0.9;
          margin-bottom: 6px;
        }
        .summary-card .value {
          font-size: 26px;
          font-weight: 800;
        }
        .content { padding: 24px 36px; }
        table {
          width: 100%;
          border-collapse: separate;
          border-spacing: 0;
          border-radius: 8px;
          overflow: hidden;
          box-shadow: 0 1px 3px rgba(0,0,0,0.08);
          margin-top: 16px;
        }
        th {
          background: #1e40af;
          color: white;
          font-weight: 600;
          font-size: 10px;
          text-transform: uppercase;
          letter-spacing: 0.5px;
          padding: 12px 10px;
          text-align: left;
        }
        td {
          padding: 10px;
          font-size: 12px;
          border-bottom: 1px solid #e2e8f0;
        }
        tr:nth-child(even) { background-color: #f8fafc; }
        tr:last-child td { border-bottom: none; }
        .text-right { text-align: right; }
        .amount {
          font-weight: 600;
          font-family: 'SF Mono', Monaco, monospace;
        }
        .status-badge {
          display: inline-block;
          padding: 3px 8px;
          border-radius: 10px;
          font-size: 10px;
          font-weight: 600;
        }
        .status-approved { background: #dcfce7; color: #166534; }
        .status-pending { background: #fef3c7; color: #92400e; }
        .status-rejected { background: #fee2e2; color: #991b1b; }
        .status-draft { background: #f1f5f9; color: #475569; }
        .footer {
          padding: 16px 36px;
          background: #f8fafc;
          text-align: center;
          color: #64748b;
          font-size: 11px;
          border-top: 1px solid #e2e8f0;
        }
        @media print {
          body { padding: 0; }
          -webkit-print-color-adjust: exact;
          print-color-adjust: exact;
        }
      </style>
    </head>
    <body>
      <div class="header">
        <h1>${title}</h1>
        <p>Generated: ${new Date().toLocaleDateString("en-US", { weekday: "long", year: "numeric", month: "long", day: "numeric" })}</p>
      </div>
      <div class="summary-grid">
        <div class="summary-card total">
          <div class="label">Total Amount</div>
          <div class="value">${formatCurrency(totalAmount)}</div>
        </div>
        <div class="summary-card approved">
          <div class="label">Approved</div>
          <div class="value">${approvedCount}</div>
        </div>
        <div class="summary-card pending">
          <div class="label">Pending</div>
          <div class="value">${pendingCount}</div>
        </div>
        <div class="summary-card rate">
          <div class="label">Approval Rate</div>
          <div class="value">${approvalRate}%</div>
        </div>
      </div>
      <div class="content">
        <table>
          <thead>
            <tr>
              <th>Title</th>
              <th>Ministry</th>
              <th class="text-right">Amount</th>
              <th>Reimb.</th>
              <th>TIN</th>
              <th>Adv.</th>
              <th>Recipient</th>
              <th>Phone</th>
              <th>Email</th>
              <th>Status</th>
              <th>Date</th>
            </tr>
          </thead>
          <tbody>
            ${expenses.map((e) => {
              const statusClass = ["treasury_approved", "leader_approved", "completed"].includes(e.status)
                ? "approved"
                : ["leader_denied", "treasury_denied", "cancelled"].includes(e.status)
                ? "rejected"
                : e.status === "draft" ? "draft" : "pending";
              // Get recipient info - if different recipient, use recipient info, otherwise use requester info
              const isDifferent = e.is_different_recipient;
              const recipientName = isDifferent && e.recipient_name ? e.recipient_name : e.requester_name;
              const recipientPhone = isDifferent && e.recipient_phone ? e.recipient_phone : e.requester_phone;
              const recipientEmail = isDifferent && e.recipient_email ? e.recipient_email : e.requester_email;
              return `
              <tr>
                <td>${escapeHTML(e.title)}</td>
                <td>${escapeHTML(e.ministry?.name || "-")}</td>
                <td class="text-right amount">${formatCurrency(e.amount)}</td>
                <td>${REIMBURSEMENT_TYPE_LABELS[e.reimbursement_type] || e.reimbursement_type}</td>
                <td>${escapeHTML(e.tin || "-")}</td>
                <td>${e.is_advance_payment ? "Yes" : "No"}</td>
                <td>${escapeHTML(recipientName || "-")}</td>
                <td>${escapeHTML(recipientPhone || "-")}</td>
                <td>${escapeHTML(recipientEmail || "-")}</td>
                <td><span class="status-badge status-${statusClass}">${EXPENSE_STATUS_CONFIG[e.status]?.label || e.status}</span></td>
                <td>${formatDate(e.created_at)}</td>
              </tr>
            `;}).join("")}
          </tbody>
        </table>
      </div>
      <div class="footer">
        <strong>${expenses.length} expense requests</strong> — Generated by Approval Agenda Budget Module
      </div>
      <script>window.print();</script>
    </body>
    </html>
  `;

  const printWindow = window.open("", "_blank");
  if (printWindow) {
    printWindow.document.write(html);
    printWindow.document.close();
  }
};

// =====================================================
// Helper Functions
// =====================================================

const getDateStamp = (): string => {
  const now = new Date();
  return `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, "0")}${String(now.getDate()).padStart(2, "0")}`;
};

const downloadFile = (content: string, filename: string, mimeType: string): void => {
  const blob = new Blob([content], { type: `${mimeType};charset=utf-8;` });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.setAttribute("href", url);
  link.setAttribute("download", filename);
  link.style.visibility = "hidden";
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
  URL.revokeObjectURL(url);
};

const escapeHTML = (str: string): string => {
  const div = document.createElement("div");
  div.textContent = str;
  return div.innerHTML;
};

const generateExcelXML = (
  headers: string[],
  rows: (string | number)[][],
  sheetName: string
): string => {
  const headerCells = headers
    .map((h) => `<Cell><Data ss:Type="String">${escapeHTML(String(h))}</Data></Cell>`)
    .join("");

  const dataRows = rows
    .map((row) => {
      const cells = row
        .map((cell) => {
          const type = typeof cell === "number" ? "Number" : "String";
          return `<Cell><Data ss:Type="${type}">${escapeHTML(String(cell))}</Data></Cell>`;
        })
        .join("");
      return `<Row>${cells}</Row>`;
    })
    .join("");

  return `<?xml version="1.0"?>
<?mso-application progid="Excel.Sheet"?>
<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet"
  xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">
  <Styles>
    <Style ss:ID="Header">
      <Font ss:Bold="1" ss:Color="#FFFFFF"/>
      <Interior ss:Color="#1E40AF" ss:Pattern="Solid"/>
      <Alignment ss:Horizontal="Center"/>
    </Style>
    <Style ss:ID="Currency">
      <NumberFormat ss:Format="Currency"/>
    </Style>
  </Styles>
  <Worksheet ss:Name="${sheetName}">
    <Table>
      <Row ss:StyleID="Header">${headerCells}</Row>
      ${dataRows}
    </Table>
  </Worksheet>
</Workbook>`;
};
