import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../api_service.dart';
import '../../models/report_contract.dart';
import '../../widgets/report_shell.dart';
import '../account_statement_screen.dart';

/// The gold safes' statements against the books on the reports' shell
/// (REPORTS ت5-3, ADR-083): on a day, each gold safe's totals in the main
/// karat, then each karat -- its statement, the books, the difference (a
/// difference beyond the nightly check's threshold said apart) -- from the
/// nightly check's one computation. A safe opens its account's statement.
class SafeGoldReconciliationReportScreen extends StatelessWidget {
  const SafeGoldReconciliationReportScreen({
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
      title: 'ميزان مراجعة الأوزان (خزنة ↔ حساب)',
      subtitle: 'دفتر كل خزينة ذهب مقابل حسابها، عيارًا عيارًا',
      singleDay: true,
      now: now,
      saver: saver,
      printer: printer,
      emptyTitle: 'لا ذهب في الخزائن في هذا اليوم',
      load: (range, _, _) async => ReportData.fromJson(
        await api.getSafeGoldReconciliation(asOf: day.format(range!.end)),
      ),
      onDrill: (context, drill, row, report) {
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
