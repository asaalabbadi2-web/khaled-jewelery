import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../api_service.dart';
import '../../models/report_contract.dart';
import '../../widgets/report_shell.dart';
import '../account_statement_screen.dart';

/// The trial balance on the reports' shell (REPORTS ت1-1, ADR-083): each
/// account's debits and credits in riyals and grams, karat by karat on a
/// switch, a period from the ready ones; the balances' checks; a row opens
/// its account's statement. It replaces trial_balance_screen_v2.dart, whose
/// features it keeps (its dates, its karat detail, its totals, its signed
/// balances, its refresh and states) and to which it adds the opening of
/// each account, Excel, PDF and print.
class TrialBalanceReportScreen extends StatelessWidget {
  const TrialBalanceReportScreen({
    super.key,
    this.api,
    this.now,
    this.saver,
    this.printer,
  });

  /// The server; tests pass a fake.
  final ApiService? api;

  /// Today, for tests.
  final DateTime Function()? now;

  /// Where a file goes, and the print dialog; tests pass fakes.
  final ReportSaver? saver;
  final Future<void> Function(Future<List<int>> Function() pdf)? printer;

  static const karatDetail = 'karat_detail';

  @override
  Widget build(BuildContext context) {
    final server = api ?? ApiService();
    final day = DateFormat('yyyy-MM-dd');
    return ReportShell(
      title: 'ميزان المراجعة',
      subtitle: 'أرصدة الحسابات نقدًا ووزنًا',
      now: now,
      saver: saver,
      printer: printer,
      toggles: const [ReportToggle(karatDetail, 'تفصيل العيارات')],
      emptyTitle: 'لا قيود مرحّلة في هذه الفترة',
      load: (range, on, _) async => ReportData.fromJson(
        await server.getTrialBalance(
          startDate: range == null ? null : day.format(range.start),
          endDate: range == null ? null : day.format(range.end),
          karatDetail: on.contains(karatDetail),
        ),
      ),
      onDrill: (context, drill, row) {
        if (drill.kind != 'account') return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AccountStatementScreen(
              accountId: drill.id,
              accountName: '${row['account_name'] ?? ''}',
              apiService: api,
            ),
          ),
        );
      },
    );
  }
}
