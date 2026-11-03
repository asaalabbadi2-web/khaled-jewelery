import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../api_service.dart';
import '../../models/report_contract.dart';
import '../../widgets/report_shell.dart';
import 'trial_balance_report_screen.dart';

/// The balance sheet on the reports' shell (REPORTS ت2-1, ADR-083): what the
/// shop owns and owes on a day, in riyals and grams, its sections and their
/// totals, the result not yet closed; its checks (it balances in riyals and in
/// grams; no riyals on a weight account). A group opens the trial balance of
/// its accounts to that day, and an account there its statement.
class BalanceSheetReportScreen extends StatelessWidget {
  const BalanceSheetReportScreen({
    super.key,
    required this.api,
    this.now,
    this.saver,
    this.printer,
  });

  final ApiService api;

  /// Today, for tests.
  final DateTime Function()? now;

  /// Where a file goes, and the print dialog; tests pass fakes.
  final ReportSaver? saver;
  final Future<void> Function(Future<List<int>> Function() pdf)? printer;

  @override
  Widget build(BuildContext context) {
    final day = DateFormat('yyyy-MM-dd');
    return ReportShell(
      title: 'الميزانية العمومية',
      subtitle: 'ما للمحل وما عليه، بالريال وبالجرام',
      singleDay: true,
      now: now,
      saver: saver,
      printer: printer,
      emptyTitle: 'لا قيود مرحّلة حتى هذا اليوم',
      load: (range, _, _) async => ReportData.fromJson(
        await api.getBalanceSheet(asOf: day.format(range!.end)),
      ),
      onDrill: (context, drill, row, report) {
        if (drill.kind != 'account') return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TrialBalanceReportScreen(
              api: api,
              under: drill.id,
              asOf: report.end,
              title: '${row['name'] ?? ''}',
            ),
          ),
        );
      },
    );
  }
}
