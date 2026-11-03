import 'dart:io' show File;

import 'package:excel/excel.dart' as excel;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/report_contract.dart';
import '../web_file_io.dart' as web_io;
import 'currency_utils.dart';

/// A report's figures written out and saved (REPORTS ت1, ADR-083): the same
/// words the shell shows, in a file. On the web -- production -- the browser
/// downloads it (a temporary directory does not exist there: the statement's
/// export did nothing in production, 10 Oct 2026); elsewhere it is shared.

/// A cell as the shell writes it: a figure by its kind, a text as it is.
String reportCell(ReportColumn column, Object? value) {
  if (value == null) return '';
  final number = value is num ? value : num.tryParse('$value');
  return switch (column.kind) {
    ReportColumnKind.money when number != null => formatAmount(number),
    ReportColumnKind.grams when number != null => formatGrams(number),
    ReportColumnKind.count when number != null => '${number.round()}',
    ReportColumnKind.percent when number != null => '${formatAmount(number)}%',
    _ => '$value',
  };
}

/// The workbook: one sheet, right to left -- the columns' titles, the rows,
/// then the totals; figures as numbers, so the sheet sums them.
List<int> reportXlsx(ReportData report) {
  final book = excel.Excel.createExcel();
  final name = book.getDefaultSheet() ?? 'Sheet1';
  final sheet = book[name]..isRTL = true;
  sheet.appendRow([for (final c in report.columns) c.label]);
  Object? cell(ReportColumn c, Object? v) =>
      c.isFigure && v is num ? v : (v == null ? '' : '$v');
  for (final row in report.rows) {
    sheet.appendRow([for (final c in report.columns) cell(c, row[c.key])]);
  }
  if (report.totals.isNotEmpty) {
    sheet.appendRow([
      for (final (i, c) in report.columns.indexed)
        c.isFigure ? cell(c, report.totals[c.key]) : (i == 0 ? 'المجموع' : ''),
    ]);
  }
  return book.encode() ?? const [];
}

/// The file name: the report's id and the period it covers.
String reportFileName(ReportData report, String extension) {
  String day(DateTime? d) => d == null
      ? ''
      : '${d.year}${'${d.month}'.padLeft(2, '0')}${'${d.day}'.padLeft(2, '0')}';
  final period = [
    day(report.start),
    day(report.end),
  ].where((s) => s.isNotEmpty).join('-');
  return '${report.id}${period.isEmpty ? '' : '_$period'}.$extension';
}

/// Saved where the platform keeps a file: downloaded on the web, shared
/// elsewhere.
Future<void> saveReportFile(
  String fileName,
  List<int> bytes,
  String mimeType,
) async {
  if (kIsWeb) {
    web_io.downloadBytes(fileName, bytes, mimeType);
    return;
  }
  final directory = await getTemporaryDirectory();
  final file = File('${directory.path}/$fileName');
  await file.writeAsBytes(bytes, flush: true);
  await SharePlus.instance.share(
    ShareParams(files: [XFile(file.path, mimeType: mimeType)]),
  );
}

const xlsxMime =
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
const pdfMime = 'application/pdf';
