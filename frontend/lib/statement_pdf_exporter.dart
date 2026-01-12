import 'dart:io';
import 'package:flutter/material.dart'; // For DateTimeRange
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';

import '../models/account_statement_model.dart';
import '../providers/settings_provider.dart';

class StatementPdfExporter {
  final AccountStatement statement;
  final List<StatementLine> lines;
  final String accountName;
  final DateTimeRange? dateRange;
  final SettingsProvider settingsProvider;
  late final pw.ThemeData _theme;
  late final pw.Font _boldFont;

  StatementPdfExporter({
    required this.statement,
    required this.lines,
    required this.accountName,
    required this.dateRange,
    required this.settingsProvider,
  });

  Future<void> generateAndOpenPdf() async {
    final pdf = pw.Document();

    // Load fonts
    final fontData = await rootBundle.load("assets/fonts/Cairo-Regular.ttf");
    final ttf = pw.Font.ttf(fontData);
    final boldFontData = await rootBundle.load("assets/fonts/Cairo-Bold.ttf");
    _boldFont = pw.Font.ttf(boldFontData);

    _theme = pw.ThemeData.withFont(base: ttf, bold: _boldFont);

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        theme: _theme,
        build: (pw.Context context) {
          return [
            _buildHeader(),
            pw.SizedBox(height: 20),
            _buildSummaryTable(),
            pw.SizedBox(height: 20),
            _buildTransactionsTable(),
          ];
        },
        footer: (pw.Context context) {
          return _buildFooter(context);
        },
      ),
    );

    await _saveAndOpenPdf(pdf);
  }

  pw.Widget _buildHeader() {
    String dateRangeText;
    if (dateRange == null) {
      dateRangeText = 'كل الأوقات';
    } else {
      final start = DateFormat('d/M/yyyy').format(dateRange!.start);
      final end = DateFormat('d/M/yyyy').format(dateRange!.end);
      dateRangeText = 'من $start إلى $end';
    }

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        pw.Text(
          'كشف حساب: $accountName',
          style: pw.TextStyle(font: _boldFont, fontSize: 20),
          textDirection: pw.TextDirection.rtl,
        ),
        pw.SizedBox(height: 5),
        pw.Text(
          'التاريخ: ${DateFormat('d/M/yyyy').format(DateTime.now())}',
          textDirection: pw.TextDirection.rtl,
        ),
        pw.SizedBox(height: 5),
        pw.Text(
          'نطاق التقرير: $dateRangeText',
          textDirection: pw.TextDirection.rtl,
        ),
        pw.Divider(height: 20),
      ],
    );
  }

  pw.Widget _buildSummaryTable() {
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey300),
      columnWidths: {
        0: pw.FlexColumnWidth(2),
        1: pw.FlexColumnWidth(2),
        2: pw.FlexColumnWidth(1),
      },
      children: [
        _buildSummaryRow(
          'البيان',
          'الرصيد (ذهب)',
          'الرصيد (نقد)',
          isHeader: true,
        ),
        _buildSummaryRow(
          'الرصيد الافتتاحي',
          '${statement.openingBalanceGold.toStringAsFixed(3)} جم',
          '${statement.openingBalanceCash.toStringAsFixed(2)} ${settingsProvider.currencySymbol}',
        ),
        _buildSummaryRow(
          'مجموع المدين',
          '${statement.totalDebitGold.toStringAsFixed(3)} جم',
          '${statement.totalDebitCash.toStringAsFixed(2)} ${settingsProvider.currencySymbol}',
        ),
        _buildSummaryRow(
          'مجموع الدائن',
          '${statement.totalCreditGold.toStringAsFixed(3)} جم',
          '${statement.totalCreditCash.toStringAsFixed(2)} ${settingsProvider.currencySymbol}',
        ),
        _buildSummaryRow(
          'الرصيد الختامي',
          '${statement.closingBalanceGoldNormalized.toStringAsFixed(3)} جم',
          '${statement.closingBalanceCash.toStringAsFixed(2)} ${settingsProvider.currencySymbol}',
          isFooter: true,
        ),
      ],
    );
  }

  pw.TableRow _buildSummaryRow(
    String title,
    String gold,
    String cash, {
    bool isHeader = false,
    bool isFooter = false,
  }) {
    final style = isHeader || isFooter
        ? pw.TextStyle(font: _boldFont)
        : pw.TextStyle();
    final color = isHeader
        ? PdfColors.grey200
        : (isFooter ? PdfColors.grey100 : PdfColors.white);
    return pw.TableRow(
      decoration: pw.BoxDecoration(color: color),
      children: [
        pw.Padding(
          padding: pw.EdgeInsets.all(5),
          child: pw.Text(
            cash,
            style: style,
            textDirection: pw.TextDirection.rtl,
          ),
        ),
        pw.Padding(
          padding: pw.EdgeInsets.all(5),
          child: pw.Text(
            gold,
            style: style,
            textDirection: pw.TextDirection.rtl,
          ),
        ),
        pw.Padding(
          padding: pw.EdgeInsets.all(5),
          child: pw.Text(
            title,
            style: style,
            textDirection: pw.TextDirection.rtl,
          ),
        ),
      ],
    );
  }

  pw.Widget _buildTransactionsTable() {
    final headers = [
      'الرصيد (نقد)',
      'الرصيد (ذهب)',
      'النقد',
      'الذهب',
      'البيان',
      'التاريخ',
    ].map((e) => pw.Text(e, textDirection: pw.TextDirection.rtl)).toList();

    final data = lines.map((line) {
      final cashAmount = line.cashDebit > 0
          ? '-${line.cashDebit.toStringAsFixed(2)}'
          : '+${line.cashCredit.toStringAsFixed(2)}';
      final goldAmount = line.goldDebit > 0
          ? '-${line.goldDebit.toStringAsFixed(3)}'
          : '+${line.goldCredit.toStringAsFixed(3)}';
      return [
        pw.Text(
          line.runningCashBalance?.toStringAsFixed(2) ?? '',
          textDirection: pw.TextDirection.rtl,
        ),
        pw.Text(
          line.runningGoldBalance?.toStringAsFixed(3) ?? '',
          textDirection: pw.TextDirection.rtl,
        ),
        pw.Text(cashAmount, textDirection: pw.TextDirection.rtl),
        pw.Text(goldAmount, textDirection: pw.TextDirection.rtl),
        pw.Text(line.description, textDirection: pw.TextDirection.rtl),
        pw.Text(
          DateFormat('d/M/yy').format(line.date),
          textDirection: pw.TextDirection.rtl,
        ),
      ];
    }).toList();

    return pw.TableHelper.fromTextArray(
      headers: headers,
      data: data,
      headerStyle: pw.TextStyle(font: _boldFont),
      cellAlignment: pw.Alignment.centerRight,
      headerDecoration: pw.BoxDecoration(color: PdfColors.grey200),
      cellStyle: const pw.TextStyle(fontSize: 10),
      border: pw.TableBorder.all(color: PdfColors.grey300),
      columnWidths: {
        0: pw.FlexColumnWidth(2),
        1: pw.FlexColumnWidth(2),
        2: pw.FlexColumnWidth(2),
        3: pw.FlexColumnWidth(2),
        4: pw.FlexColumnWidth(4),
        5: pw.FlexColumnWidth(1.5),
      },
      cellAlignments: {
        0: pw.Alignment.centerRight,
        1: pw.Alignment.centerRight,
        2: pw.Alignment.centerRight,
        3: pw.Alignment.centerRight,
        4: pw.Alignment.centerRight,
        5: pw.Alignment.centerRight,
      },
    );
  }

  pw.Widget _buildFooter(pw.Context context) {
    return pw.Container(
      alignment: pw.Alignment.center,
      child: pw.Text(
        'صفحة ${context.pageNumber} من ${context.pagesCount}',
        style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey),
      ),
    );
  }

  Future<void> _saveAndOpenPdf(pw.Document pdf) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final path =
          '${directory.path}/statement_${accountName.replaceAll(' ', '_')}_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final file = File(path);
      await file.writeAsBytes(await pdf.save());
      await OpenFile.open(path);
    } catch (e) {
      // Optionally, show a user-facing error message
    }
  }
}
