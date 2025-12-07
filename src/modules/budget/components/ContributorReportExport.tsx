/**
 * Contributor Report Export - Export personal expense reports
 */

import { Button } from "@/shared/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  DropdownMenuSeparator,
} from "@/shared/components/ui/dropdown-menu";
import { Download, Printer, FileText } from "lucide-react";
import type { ExpenseRequestWithRelations } from "../types";
import jsPDF from "jspdf";
import autoTable from "jspdf-autotable";

interface ContributorReportExportProps {
  expenses: ExpenseRequestWithRelations[];
  userName: string;
  organizationName: string;
}

export const ContributorReportExport = ({
  expenses,
  userName,
  organizationName,
}: ContributorReportExportProps) => {
  const generatePDF = () => {
    const doc = new jsPDF();
    const margin = 14;

    // Calculate totals
    const totalAmount = expenses.reduce((sum, e) => sum + e.amount, 0);
    const approvedAmount = expenses
      .filter(
        (e) =>
          e.status === "treasury_approved" || e.status === "leader_approved"
      )
      .reduce((sum, e) => sum + e.amount, 0);
    const pendingAmount = expenses
      .filter((e) =>
        ["pending_leader", "pending_treasury", "pending_finance"].includes(
          e.status
        )
      )
      .reduce((sum, e) => sum + e.amount, 0);

    // Header
    doc.setFontSize(20);
    doc.setFont("helvetica", "bold");
    doc.text("My Expense Report", margin, 20);

    doc.setFontSize(12);
    doc.setFont("helvetica", "normal");
    doc.text(`Submitted by: ${userName}`, margin, 28);
    doc.text(`Organization: ${organizationName}`, margin, 35);
    doc.text(`Generated: ${new Date().toLocaleDateString()}`, margin, 42);

    // Summary Section
    doc.setFontSize(14);
    doc.setFont("helvetica", "bold");
    doc.text("Summary", margin, 55);

    const summaryData = [
      ["Total Requests", expenses.length.toString()],
      ["Total Amount", `$${totalAmount.toLocaleString()}`],
      ["Approved Amount", `$${approvedAmount.toLocaleString()}`],
      ["Pending Amount", `$${pendingAmount.toLocaleString()}`],
      [
        "Approval Rate",
        `${
          expenses.length > 0
            ? (
                (expenses.filter(
                  (e) =>
                    e.status === "treasury_approved" ||
                    e.status === "leader_approved"
                ).length /
                  expenses.length) *
                100
              ).toFixed(1)
            : "0"
        }%`,
      ],
    ];

    autoTable(doc, {
      startY: 60,
      head: [["Metric", "Value"]],
      body: summaryData,
      theme: "grid",
      headStyles: { fillColor: [59, 130, 246] },
      margin: { left: margin, right: margin },
    });

    // Status Breakdown
    const docWithTable = doc as jsPDF & { lastAutoTable?: { finalY: number } };
    const finalY = docWithTable.lastAutoTable?.finalY || 100;
    doc.setFontSize(14);
    doc.setFont("helvetica", "bold");
    doc.text("Expenses by Status", margin, finalY + 10);

    const statusBreakdown = expenses.reduce((acc, expense) => {
      const status = expense.status;
      if (!acc[status]) {
        acc[status] = { count: 0, amount: 0 };
      }
      acc[status].count += 1;
      acc[status].amount += expense.amount;
      return acc;
    }, {} as Record<string, { count: number; amount: number }>);

    const statusData = Object.entries(statusBreakdown).map(([status, data]) => [
      status.replace(/_/g, " ").replace(/\b\w/g, (l) => l.toUpperCase()),
      data.count.toString(),
      `$${data.amount.toLocaleString()}`,
    ]);

    autoTable(doc, {
      startY: finalY + 15,
      head: [["Status", "Count", "Total Amount"]],
      body: statusData,
      theme: "striped",
      headStyles: { fillColor: [59, 130, 246] },
      margin: { left: margin, right: margin },
    });

    // Add new page for expense details if needed
    if (expenses.length > 0) {
      if (
        docWithTable.lastAutoTable &&
        doc.internal.pageSize.height - docWithTable.lastAutoTable.finalY < 60
      ) {
        doc.addPage();
      }

      const expenseStartY = docWithTable.lastAutoTable?.finalY
        ? docWithTable.lastAutoTable.finalY + 15
        : 60;

      doc.setFontSize(14);
      doc.setFont("helvetica", "bold");
      doc.text("Recent Expense Requests", margin, expenseStartY);

      const expenseData = expenses
        .sort(
          (a, b) =>
            new Date(b.created_at).getTime() - new Date(a.created_at).getTime()
        )
        .slice(0, 10) // Last 10 expenses
        .map((expense) => [
          new Date(expense.created_at).toLocaleDateString(),
          expense.title.substring(0, 30) +
            (expense.title.length > 30 ? "..." : ""),
          `$${expense.amount.toLocaleString()}`,
          expense.status
            .replace(/_/g, " ")
            .replace(/\b\w/g, (l) => l.toUpperCase()),
        ]);

      autoTable(doc, {
        startY: expenseStartY + 5,
        head: [["Date", "Title", "Amount", "Status"]],
        body: expenseData,
        theme: "striped",
        headStyles: { fillColor: [59, 130, 246] },
        margin: { left: margin, right: margin },
      });
    }

    // Footer
    const pageCount = doc.internal.pages.length - 1;
    for (let i = 1; i <= pageCount; i++) {
      doc.setPage(i);
      doc.setFontSize(8);
      doc.setFont("helvetica", "normal");
      doc.text(
        `Page ${i} of ${pageCount}`,
        doc.internal.pageSize.width / 2,
        doc.internal.pageSize.height - 10,
        { align: "center" }
      );
    }

    // Save the PDF
    const fileName = `My_Expenses_${
      new Date().toISOString().split("T")[0]
    }.pdf`;
    doc.save(fileName);
  };

  const exportToCSV = () => {
    const rows = [
      ["My Expense Report"],
      ["Submitted by:", userName],
      ["Organization:", organizationName],
      ["Generated:", new Date().toLocaleDateString()],
      [],
      ["Summary"],
      ["Total Requests", expenses.length],
      ["Total Amount", expenses.reduce((sum, e) => sum + e.amount, 0)],
      [
        "Approved Amount",
        expenses
          .filter(
            (e) =>
              e.status === "treasury_approved" || e.status === "leader_approved"
          )
          .reduce((sum, e) => sum + e.amount, 0),
      ],
      [
        "Pending Amount",
        expenses
          .filter((e) =>
            ["pending_leader", "pending_treasury", "pending_finance"].includes(
              e.status
            )
          )
          .reduce((sum, e) => sum + e.amount, 0),
      ],
      [],
      ["Expense Details"],
      ["Date", "Title", "Ministry", "Amount", "Status", "Fiscal Year"],
      ...expenses.map((expense) => [
        new Date(expense.created_at).toLocaleDateString(),
        expense.title,
        expense.ministry?.name || "N/A",
        expense.amount,
        expense.status,
        expense.fiscal_year?.name || "N/A",
      ]),
    ];

    const csvContent = rows.map((row) => row.join(",")).join("\n");
    const blob = new Blob([csvContent], { type: "text/csv;charset=utf-8;" });
    const link = document.createElement("a");
    const url = URL.createObjectURL(blob);
    link.setAttribute("href", url);
    link.setAttribute(
      "download",
      `My_Expenses_${new Date().toISOString().split("T")[0]}.csv`
    );
    link.style.visibility = "hidden";
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
  };

  const printReport = () => {
    const printWindow = window.open("", "_blank");
    if (!printWindow) {
      alert("Please allow pop-ups to print the report");
      return;
    }

    const totalAmount = expenses.reduce((sum, e) => sum + e.amount, 0);
    const approvedAmount = expenses
      .filter(
        (e) =>
          e.status === "treasury_approved" || e.status === "leader_approved"
      )
      .reduce((sum, e) => sum + e.amount, 0);
    const pendingAmount = expenses
      .filter((e) =>
        ["pending_leader", "pending_treasury", "pending_finance"].includes(
          e.status
        )
      )
      .reduce((sum, e) => sum + e.amount, 0);
    const approvedCount = expenses.filter(
      (e) => e.status === "treasury_approved" || e.status === "leader_approved"
    ).length;
    const approvalRate =
      expenses.length > 0
        ? ((approvedCount / expenses.length) * 100).toFixed(1)
        : "0";

    const statusBreakdown = expenses.reduce((acc, expense) => {
      const status = expense.status;
      if (!acc[status]) {
        acc[status] = { count: 0, amount: 0 };
      }
      acc[status].count += 1;
      acc[status].amount += expense.amount;
      return acc;
    }, {} as Record<string, { count: number; amount: number }>);

    const htmlContent = `
      <!DOCTYPE html>
      <html>
        <head>
          <title>My Expense Report</title>
          <style>
            body {
              font-family: Arial, sans-serif;
              padding: 20px;
              max-width: 1200px;
              margin: 0 auto;
            }
            h1 {
              color: #1e3a8a;
              border-bottom: 3px solid #3b82f6;
              padding-bottom: 10px;
            }
            h2 {
              color: #1e40af;
              margin-top: 30px;
              margin-bottom: 15px;
            }
            .header-info {
              margin-bottom: 30px;
              color: #666;
            }
            table {
              width: 100%;
              border-collapse: collapse;
              margin-top: 15px;
              margin-bottom: 30px;
            }
            th, td {
              border: 1px solid #ddd;
              padding: 12px;
              text-align: left;
            }
            th {
              background-color: #3b82f6;
              color: white;
              font-weight: bold;
            }
            tr:nth-child(even) {
              background-color: #f8fafc;
            }
            .summary-box {
              background: #eff6ff;
              border: 1px solid #bfdbfe;
              border-radius: 8px;
              padding: 20px;
              margin: 20px 0;
            }
            .summary-item {
              display: flex;
              justify-content: space-between;
              padding: 8px 0;
              border-bottom: 1px solid #dbeafe;
            }
            .summary-item:last-child {
              border-bottom: none;
            }
            .text-right {
              text-align: right;
            }
            @media print {
              body {
                padding: 0;
              }
            }
          </style>
        </head>
        <body>
          <h1>My Expense Report</h1>
          <div class="header-info">
            <p><strong>Submitted by:</strong> ${userName}</p>
            <p><strong>Organization:</strong> ${organizationName}</p>
            <p><strong>Generated:</strong> ${new Date().toLocaleDateString()}</p>
          </div>

          <div class="summary-box">
            <h2 style="margin-top: 0;">Summary</h2>
            <div class="summary-item">
              <span><strong>Total Requests:</strong></span>
              <span>${expenses.length}</span>
            </div>
            <div class="summary-item">
              <span><strong>Total Amount:</strong></span>
              <span>$${totalAmount.toLocaleString()}</span>
            </div>
            <div class="summary-item">
              <span><strong>Approved Amount:</strong></span>
              <span>$${approvedAmount.toLocaleString()}</span>
            </div>
            <div class="summary-item">
              <span><strong>Pending Amount:</strong></span>
              <span>$${pendingAmount.toLocaleString()}</span>
            </div>
            <div class="summary-item">
              <span><strong>Approval Rate:</strong></span>
              <span>${approvalRate}%</span>
            </div>
          </div>

          <h2>Expenses by Status</h2>
          <table>
            <thead>
              <tr>
                <th>Status</th>
                <th class="text-right">Count</th>
                <th class="text-right">Total Amount</th>
              </tr>
            </thead>
            <tbody>
              ${Object.entries(statusBreakdown)
                .map(
                  ([status, data]) => `
                  <tr>
                    <td>${status
                      .replace(/_/g, " ")
                      .replace(/\b\w/g, (l) => l.toUpperCase())}</td>
                    <td class="text-right">${data.count}</td>
                    <td class="text-right">$${data.amount.toLocaleString()}</td>
                  </tr>
                `
                )
                .join("")}
            </tbody>
          </table>

          <h2>Recent Expense Requests</h2>
          <table>
            <thead>
              <tr>
                <th>Date</th>
                <th>Title</th>
                <th>Ministry</th>
                <th class="text-right">Amount</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              ${expenses
                .sort(
                  (a, b) =>
                    new Date(b.created_at).getTime() -
                    new Date(a.created_at).getTime()
                )
                .slice(0, 20)
                .map(
                  (expense) => `
                  <tr>
                    <td>${new Date(
                      expense.created_at
                    ).toLocaleDateString()}</td>
                    <td>${expense.title}</td>
                    <td>${expense.ministry?.name || "N/A"}</td>
                    <td class="text-right">$${expense.amount.toLocaleString()}</td>
                    <td>${expense.status
                      .replace(/_/g, " ")
                      .replace(/\b\w/g, (l) => l.toUpperCase())}</td>
                  </tr>
                `
                )
                .join("")}
            </tbody>
          </table>

          <script>
            window.onload = function() {
              window.print();
            };
          </script>
        </body>
      </html>
    `;

    printWindow.document.write(htmlContent);
    printWindow.document.close();
  };

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button variant="outline" size="sm">
          <Download className="mr-2 h-4 w-4" />
          Export My Report
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-48">
        <DropdownMenuItem onClick={generatePDF}>
          <FileText className="mr-2 h-4 w-4" />
          Export as PDF
        </DropdownMenuItem>
        <DropdownMenuItem onClick={exportToCSV}>
          <FileText className="mr-2 h-4 w-4" />
          Export as CSV
        </DropdownMenuItem>
        <DropdownMenuSeparator />
        <DropdownMenuItem onClick={printReport}>
          <Printer className="mr-2 h-4 w-4" />
          Print Report
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
};
