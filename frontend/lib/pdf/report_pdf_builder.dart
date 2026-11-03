import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;

import '../models/report_contract.dart';
import '../utils/report_export.dart' show reportCell;
import 'pdf_text_utils.dart';

/// Any report on paper (REPORTS ت1, ADR-083): what the server's contract says,
/// laid out -- nothing reckoned here. The shop's name above, the report and
/// its period, its checks, the table (columns right to left, as the screen
/// shows them), its totals, and where its figures come from. Arabic drawn as
/// the statement's builder draws it (visual order, left to right), in Cairo;
/// wide reports on a landscape page. Black on white, no faint grays: a shop
/// printer loses them (PRINT-2).
Future<Uint8List> buildReportPdf(
  ReportData report, {
  String companyName = '',
  String period = '',
  ByteData? regularFont,
  ByteData? boldFont,
}) async {
  final regular = pw.Font.ttf(
    regularFont ?? await rootBundle.load('assets/fonts/Cairo-Regular.ttf'),
  );
  final bold = pw.Font.ttf(
    boldFont ?? await rootBundle.load('assets/fonts/Cairo-Bold.ttf'),
  );
  String ar(String text) => pdfVisualArabic(pdfSanitize(text));
  pw.TextStyle style({bool strong = false, double size = 8}) =>
      pw.TextStyle(font: strong ? bold : regular, fontSize: size);

  // Right to left: the first column at the right edge.
  final columns = report.columns.reversed.toList();
  pw.Widget cell(
    ReportColumn c,
    String text, {
    bool strong = false,
    bool header = false,
  }) => pw.Container(
    padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2),
    alignment: pw.Alignment.centerRight,
    child: pw.Text(
      c.isFigure && !header ? pdfSanitize(text) : ar(text),
      textDirection: pw.TextDirection.ltr,
      style: style(strong: strong),
    ),
  );
  final header = pw.TableRow(
    decoration: const pw.BoxDecoration(
      border: pw.Border(bottom: pw.BorderSide(width: 1.2)),
    ),
    children: [
      for (final c in columns) cell(c, c.label, strong: true, header: true),
    ],
  );
  final body = [
    // a statement's section heading and total, bold as the screen draws them
    for (final row in report.rows)
      pw.TableRow(
        children: [
          for (final c in columns)
            cell(
              c,
              reportCell(c, row[c.key]),
              strong:
                  row.style == ReportRowStyle.heading ||
                  row.style == ReportRowStyle.subtotal,
            ),
        ],
      ),
  ];
  final totals = report.totals.isEmpty
      ? null
      : pw.TableRow(
          decoration: const pw.BoxDecoration(
            border: pw.Border(top: pw.BorderSide(width: 0.8)),
          ),
          children: [
            for (final (i, c) in columns.indexed)
              cell(
                c,
                c.isFigure
                    ? reportCell(c, report.totals[c.key])
                    : (i == columns.length - 1 ? 'المجموع' : ''),
                strong: true,
              ),
          ],
        );

  final wide = report.columns.length > 8;
  final document = pw.Document();
  document.addPage(
    pw.MultiPage(
      pageFormat: wide ? pdf.PdfPageFormat.a4.landscape : pdf.PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(24),
      header: (_) => pw.Container(
        width: double.infinity,
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            if (companyName.trim().isNotEmpty)
              pw.Text(
                ar(companyName),
                textDirection: pw.TextDirection.ltr,
                style: style(strong: true, size: 12),
              ),
            pw.Text(
              ar(report.title),
              textDirection: pw.TextDirection.ltr,
              style: style(strong: true, size: 14),
            ),
            if (period.isNotEmpty)
              pw.Text(
                ar(period),
                textDirection: pw.TextDirection.ltr,
                style: style(size: 9),
              ),
            for (final check in report.checks)
              pw.Text(
                ar('${check.label}: ${check.ok ? 'نعم' : 'لا'}'),
                textDirection: pw.TextDirection.ltr,
                style: style(size: 8),
              ),
            pw.SizedBox(height: 8),
          ],
        ),
      ),
      footer: (context) => pw.Row(
        children: [
          pw.Text(
            '${context.pageNumber} / ${context.pagesCount}',
            style: style(size: 7),
          ),
          pw.Spacer(),
          pw.Text(
            ar(report.basisLabel),
            textDirection: pw.TextDirection.ltr,
            style: style(size: 7),
          ),
        ],
      ),
      build: (_) => [
        pw.Table(
          border: pw.TableBorder.all(width: 0.8),
          children: [header, ...body, ?totals],
        ),
      ],
    ),
  );
  return document.save();
}
