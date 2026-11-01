import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;

import '../utils/currency_utils.dart';
import 'pdf_text_utils.dart';

/// A payslip on paper (HR-UX ر3): what the server's `/payroll/<id>/payslip`
/// says, laid out -- nothing reckoned here. Arabic drawn as the statement's
/// builder draws it (visual order, left to right), in Cairo.
Future<Uint8List> buildPayslipPdf(
  Map<String, dynamic> slip, {
  ByteData? regularFont,
  ByteData? boldFont,
}) async {
  final regular = pw.Font.ttf(
    regularFont ?? await rootBundle.load('assets/fonts/Cairo-Regular.ttf'),
  );
  final bold = pw.Font.ttf(
    boldFont ?? await rootBundle.load('assets/fonts/Cairo-Bold.ttf'),
  );
  final entry = slip['entry'] as Map<String, dynamic>? ?? const {};
  final employee = slip['employee'] as Map<String, dynamic>? ?? const {};
  final breakdown = slip['breakdown'] as Map<String, dynamic>?;
  final earned = breakdown?['earned'] as Map<String, dynamic>? ?? const {};
  List<Map<String, dynamic>> lines(String key) =>
      ((breakdown?[key] as List?) ?? const []).cast<Map<String, dynamic>>();

  String ar(String text) => pdfVisualArabic(pdfSanitize(text));
  final rows = <(String, num, bool)>[
    ('الأساسي', (earned['basic'] ?? entry['basic_salary'] ?? 0) as num, false),
    if (earned.isNotEmpty) ...[
      ('السكن', (earned['housing'] ?? 0) as num, false),
      ('النقل', (earned['transport'] ?? 0) as num, false),
      if (((earned['other_allowances'] as num?) ?? 0) > 0)
        ('بدلات أخرى', earned['other_allowances'] as num, false),
    ] else
      ('البدلات', (entry['allowances'] ?? 0) as num, false),
    for (final a in lines('additions'))
      ('+ ${a['label']}', a['amount'] as num, false),
    for (final b in lines('bonuses'))
      ('+ ${b['label']} (مكافأة)', b['amount'] as num, false),
    for (final d in lines('deductions'))
      ('- ${d['label']}', d['amount'] as num, false),
    ('الصافي', (entry['net_salary'] ?? 0) as num, true),
  ];
  pw.Widget line(String label, num amount, {bool strong = false}) =>
      pw.Container(
        padding: const pw.EdgeInsets.symmetric(vertical: 5),
        decoration: pw.BoxDecoration(
          border: pw.Border(
            top: strong
                ? const pw.BorderSide(width: 1.2)
                : const pw.BorderSide(width: 0.3),
          ),
        ),
        child: pw.Row(
          children: [
            pw.Text(
              formatAmount(amount),
              style: pw.TextStyle(
                font: strong ? bold : regular,
                fontSize: strong ? 13 : 11,
              ),
            ),
            pw.Spacer(),
            pw.Text(
              ar(label),
              textDirection: pw.TextDirection.ltr,
              style: pw.TextStyle(
                font: strong ? bold : regular,
                fontSize: strong ? 13 : 11,
              ),
            ),
          ],
        ),
      );
  final document = pw.Document();
  document.addPage(
    pw.Page(
      pageFormat: pdf.PdfPageFormat.a5,
      margin: const pw.EdgeInsets.all(28),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Text(
            ar('قسيمة راتب'),
            textDirection: pw.TextDirection.ltr,
            textAlign: pw.TextAlign.right,
            style: pw.TextStyle(font: bold, fontSize: 18),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            ar(
              '${employee['name'] ?? ''} - ${employee['employee_code'] ?? ''}',
            ),
            textDirection: pw.TextDirection.ltr,
            textAlign: pw.TextAlign.right,
            style: pw.TextStyle(font: regular, fontSize: 12),
          ),
          pw.Text(
            '${entry['month']}/${entry['year']}',
            textAlign: pw.TextAlign.right,
            style: pw.TextStyle(font: regular, fontSize: 12),
          ),
          if (breakdown != null && breakdown['whole_month'] == false)
            pw.Text(
              ar('${breakdown['days']} يومًا من ${breakdown['divisor']}'),
              textDirection: pw.TextDirection.ltr,
              textAlign: pw.TextAlign.right,
              style: pw.TextStyle(font: regular, fontSize: 10),
            ),
          pw.SizedBox(height: 12),
          for (final (label, amount, strong) in rows)
            line(label, amount, strong: strong),
          pw.SizedBox(height: 12),
          if (entry['voucher'] != null)
            pw.Text(
              ar('سند الصرف ${(entry['voucher'] as Map)['voucher_number']}'),
              textDirection: pw.TextDirection.ltr,
              textAlign: pw.TextAlign.right,
              style: pw.TextStyle(font: regular, fontSize: 10),
            ),
          if (employee['payment_method'] == 'bank' && employee['iban'] != null)
            pw.Text(
              '${employee['iban']}',
              textAlign: pw.TextAlign.right,
              style: pw.TextStyle(font: regular, fontSize: 10),
            ),
        ],
      ),
    ),
  );
  return document.save();
}
