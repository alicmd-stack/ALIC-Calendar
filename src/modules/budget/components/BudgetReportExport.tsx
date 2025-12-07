/**
 * Budget Report Export - Export and print budget reports
 */

import { Button } from "@/shared/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  DropdownMenuSeparator,
} from "@/shared/components/ui/dropdown-menu";
import { Download, Printer, FileText, Image } from "lucide-react";
import type {
  OrganizationBudgetSummary,
  ExpenseRequestWithRelations,
} from "../types";
import jsPDF from "jspdf";
import autoTable from "jspdf-autotable";

interface BudgetReportExportProps {
  budgetSummary: OrganizationBudgetSummary;
  expenses: ExpenseRequestWithRelations[];
  organizationName: string;
}

export const BudgetReportExport = ({
  budgetSummary,
  expenses,
  organizationName,
}: BudgetReportExportProps) => {
  const generatePDF = () => {
    const doc = new jsPDF();
    const pageWidth = doc.internal.pageSize.width;
    const margin = 14;

    // Header
    doc.setFontSize(20);
    doc.setFont("helvetica", "bold");
    doc.text("Budget Report", margin, 20);

    doc.setFontSize(12);
    doc.setFont("helvetica", "normal");
    doc.text(organizationName, margin, 28);
    doc.text(`Fiscal Year: ${budgetSummary.fiscal_year_name}`, margin, 35);
    doc.text(`Generated: ${new Date().toLocaleDateString()}`, margin, 42);

    // Summary Section
    doc.setFontSize(14);
    doc.setFont("helvetica", "bold");
    doc.text("Budget Summary", margin, 55);

    const summaryData = [
      ["Total Allocated", `$${budgetSummary.total_allocated.toLocaleString()}`],
      ["Total Spent", `$${budgetSummary.total_spent.toLocaleString()}`],
      ["Total Pending", `$${budgetSummary.total_pending.toLocaleString()}`],
      ["Total Remaining", `$${budgetSummary.total_remaining.toLocaleString()}`],
      [
        "Utilization Rate",
        `${(
          (budgetSummary.total_spent / budgetSummary.total_allocated) *
          100
        ).toFixed(1)}%`,
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

    // Ministry Breakdown
    const docWithTable = doc as jsPDF & { lastAutoTable?: { finalY: number } };
    const finalY = docWithTable.lastAutoTable?.finalY || 100;
    doc.setFontSize(14);
    doc.setFont("helvetica", "bold");
    doc.text("Ministry Budget Breakdown", margin, finalY + 10);

    const ministryData = budgetSummary.ministry_summaries.map((ministry) => [
      ministry.ministry_name,
      `$${ministry.allocated_amount.toLocaleString()}`,
      `$${ministry.total_spent.toLocaleString()}`,
      `$${ministry.total_pending.toLocaleString()}`,
      `$${ministry.remaining.toLocaleString()}`,
      `${
        ministry.allocated_amount > 0
          ? ((ministry.total_spent / ministry.allocated_amount) * 100).toFixed(
              1
            )
          : "0"
      }%`,
    ]);

    autoTable(doc, {
      startY: finalY + 15,
      head: [
        [
          "Ministry",
          "Allocated",
          "Spent",
          "Pending",
          "Remaining",
          "Utilization",
        ],
      ],
      body: ministryData,
      theme: "striped",
      headStyles: { fillColor: [59, 130, 246] },
      margin: { left: margin, right: margin },
    });

    // Expense Summary by Status
    if (
      docWithTable.lastAutoTable &&
      doc.internal.pageSize.height - docWithTable.lastAutoTable.finalY < 60
    ) {
      doc.addPage();
    }

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

    const expenseStartY = docWithTable.lastAutoTable?.finalY
      ? docWithTable.lastAutoTable.finalY + 15
      : 60;

    doc.setFontSize(14);
    doc.setFont("helvetica", "bold");
    doc.text("Expense Status Breakdown", margin, expenseStartY);

    autoTable(doc, {
      startY: expenseStartY + 5,
      head: [["Status", "Count", "Total Amount"]],
      body: statusData,
      theme: "striped",
      headStyles: { fillColor: [59, 130, 246] },
      margin: { left: margin, right: margin },
    });

    // Footer on all pages
    const pageCount = doc.internal.pages.length - 1;
    for (let i = 1; i <= pageCount; i++) {
      doc.setPage(i);
      doc.setFontSize(8);
      doc.setFont("helvetica", "normal");
      doc.text(
        `Page ${i} of ${pageCount}`,
        pageWidth / 2,
        doc.internal.pageSize.height - 10,
        { align: "center" }
      );
    }

    // Save the PDF
    const fileName = `Budget_Report_${budgetSummary.fiscal_year_name.replace(
      /\s+/g,
      "_"
    )}_${new Date().toISOString().split("T")[0]}.pdf`;
    doc.save(fileName);
  };

  const exportToCSV = () => {
    const rows = [
      ["Budget Summary Report"],
      ["Organization:", organizationName],
      ["Fiscal Year:", budgetSummary.fiscal_year_name],
      ["Generated:", new Date().toLocaleDateString()],
      [],
      ["Overall Summary"],
      ["Metric", "Value"],
      ["Total Allocated", budgetSummary.total_allocated],
      ["Total Spent", budgetSummary.total_spent],
      ["Total Pending", budgetSummary.total_pending],
      ["Total Remaining", budgetSummary.total_remaining],
      [
        "Utilization Rate",
        `${(
          (budgetSummary.total_spent / budgetSummary.total_allocated) *
          100
        ).toFixed(1)}%`,
      ],
      [],
      ["Ministry Breakdown"],
      [
        "Ministry",
        "Allocated",
        "Spent",
        "Pending",
        "Remaining",
        "Utilization %",
      ],
      ...budgetSummary.ministry_summaries.map((ministry) => [
        ministry.ministry_name,
        ministry.allocated_amount,
        ministry.total_spent,
        ministry.total_pending,
        ministry.remaining,
        ministry.allocated_amount > 0
          ? ((ministry.total_spent / ministry.allocated_amount) * 100).toFixed(
              1
            )
          : "0",
      ]),
    ];

    const csvContent = rows.map((row) => row.join(",")).join("\n");
    const blob = new Blob([csvContent], { type: "text/csv;charset=utf-8;" });
    const link = document.createElement("a");
    const url = URL.createObjectURL(blob);
    link.setAttribute("href", url);
    link.setAttribute(
      "download",
      `Budget_Report_${budgetSummary.fiscal_year_name.replace(/\s+/g, "_")}_${
        new Date().toISOString().split("T")[0]
      }.csv`
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

    const utilizationRate = (
      (budgetSummary.total_spent / budgetSummary.total_allocated) *
      100
    ).toFixed(1);

    const htmlContent = `
      <!DOCTYPE html>
      <html>
        <head>
          <title>Budget Report - ${budgetSummary.fiscal_year_name}</title>
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
            .summary-label {
              font-weight: bold;
              color: #1e40af;
            }
            .summary-value {
              color: #1e3a8a;
              font-weight: 600;
            }
            .text-right {
              text-align: right;
            }
            @media print {
              body {
                padding: 0;
              }
              h1 {
                font-size: 24px;
              }
              h2 {
                font-size: 18px;
                page-break-after: avoid;
              }
              table {
                page-break-inside: avoid;
              }
            }
          </style>
        </head>
        <body>
          <h1>Budget Report</h1>
          <div class="header-info">
            <p><strong>Organization:</strong> ${organizationName}</p>
            <p><strong>Fiscal Year:</strong> ${
              budgetSummary.fiscal_year_name
            }</p>
            <p><strong>Generated:</strong> ${new Date().toLocaleDateString()}</p>
          </div>

          <div class="summary-box">
            <h2 style="margin-top: 0;">Overall Budget Summary</h2>
            <div class="summary-item">
              <span class="summary-label">Total Allocated:</span>
              <span class="summary-value">$${budgetSummary.total_allocated.toLocaleString()}</span>
            </div>
            <div class="summary-item">
              <span class="summary-label">Total Spent:</span>
              <span class="summary-value">$${budgetSummary.total_spent.toLocaleString()}</span>
            </div>
            <div class="summary-item">
              <span class="summary-label">Total Pending:</span>
              <span class="summary-value">$${budgetSummary.total_pending.toLocaleString()}</span>
            </div>
            <div class="summary-item">
              <span class="summary-label">Total Remaining:</span>
              <span class="summary-value">$${budgetSummary.total_remaining.toLocaleString()}</span>
            </div>
            <div class="summary-item">
              <span class="summary-label">Utilization Rate:</span>
              <span class="summary-value">${utilizationRate}%</span>
            </div>
          </div>

          <h2>Ministry Budget Breakdown</h2>
          <table>
            <thead>
              <tr>
                <th>Ministry</th>
                <th class="text-right">Allocated</th>
                <th class="text-right">Spent</th>
                <th class="text-right">Pending</th>
                <th class="text-right">Remaining</th>
                <th class="text-right">Utilization</th>
              </tr>
            </thead>
            <tbody>
              ${budgetSummary.ministry_summaries
                .map(
                  (ministry) => `
                <tr>
                  <td>${ministry.ministry_name}</td>
                  <td class="text-right">$${ministry.allocated_amount.toLocaleString()}</td>
                  <td class="text-right">$${ministry.total_spent.toLocaleString()}</td>
                  <td class="text-right">$${ministry.total_pending.toLocaleString()}</td>
                  <td class="text-right">$${ministry.remaining.toLocaleString()}</td>
                  <td class="text-right">${
                    ministry.allocated_amount > 0
                      ? (
                          (ministry.total_spent / ministry.allocated_amount) *
                          100
                        ).toFixed(1)
                      : "0"
                  }%</td>
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
          Export Report
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
