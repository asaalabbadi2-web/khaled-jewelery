import 'package:flutter/material.dart';

import '../../api_service.dart';
import '../../models/report_contract.dart';
import '../../widgets/report_shell.dart';
import '../account_statement_screen.dart';

/// The income statement on the reports' shell (REPORTS ت2-2ب, ADR-083): its
/// riyals by the chart tree -- revenue, the cost of sales, gross profit,
/// operating expenses, net profit and its margin; its grams the gram profit's
/// five layers (the owner, 4 Nov 2026), what was sold and bought and their
/// averages a gram, what still waits, the net gram profit and its worth at the
/// closing price. An account opens its statement.
///
/// It replaces the old screen of 1,532 lines, whose features are each kept --
/// or said gone: its trend chart, period table, grouping and «include
/// unposted» read a series the server never filled (`'series': []`).
class IncomeStatementReportScreen extends StatelessWidget {
  final ApiService api;
  final bool isArabic;

  /// The period to open on -- the manager's dashboard's own, so its gram
  /// profit card opens on the figures it said (the owner, 30 Oct 2026).
  final DateTimeRange? initialRange;

  /// Today, for tests.
  final DateTime Function()? now;

  /// Where a file goes, and the print dialog; tests pass fakes.
  final ReportSaver? saver;
  final Future<void> Function(Future<List<int>> Function() pdf)? printer;

  const IncomeStatementReportScreen({
    super.key,
    required this.api,
    this.isArabic = true,
    this.initialRange,
    this.now,
    this.saver,
    this.printer,
  });

  @override
  Widget build(BuildContext context) {
    final today = (now ?? DateTime.now)();
    // a statement is of a period: «all» is this year to today
    final thisYear = DateTimeRange(
      start: DateTime(today.year, 1, 1),
      end: DateTime(today.year, today.month, today.day),
    );
    return ReportShell(
      title: 'قائمة الدخل',
      subtitle:
          'الريال من شجرة الحسابات، والجرام طبقات ربح الجرام الخمس: '
          'ما عاد ذهبًا بما اشتراه فعلًا، وما ينتظر بسعر التسكير',
      now: now,
      saver: saver,
      printer: printer,
      initialRange: initialRange ?? thisYear,
      emptyTitle: 'لا قيود في هذه الفترة',
      load: (range, _, _) async {
        final period = range ?? thisYear;
        return ReportData.fromJson(
          await api.getIncomeStatementReport(
            startDate: period.start,
            endDate: period.end,
          ),
        );
      },
      onDrill: (context, drill, row, _) {
        if (drill.kind != 'account') return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AccountStatementScreen(
              accountId: drill.id,
              accountName: '${row['name'] ?? ''}',
              apiService: api,
            ),
          ),
        );
      },
    );
  }
}
