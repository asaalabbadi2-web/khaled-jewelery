import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../api_service.dart';
import '../../models/report_contract.dart';
import '../../widgets/report_shell.dart';
import '../account_statement_screen.dart';

/// Customers' balances on the reports' shell (REPORTS ت5-1, ADR-083; the
/// owner, 4 Nov 2026: «يقرأ الدفتر الصحيح»): what each customer owes or is
/// owed on a day, in riyals and grams, from the ledger's one reader -- never
/// the weight memo twins, which hold the dual system's weights (CUSTGOLD-001).
/// What no customer holds is said apart, and checked. A customer opens its
/// statement.
class CustomerBalancesReportScreen extends StatelessWidget {
  const CustomerBalancesReportScreen({
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
      title: 'أرصدة العملاء',
      subtitle: 'بالريال والجرام، من دفتر كل عميل',
      singleDay: true,
      now: now,
      saver: saver,
      printer: printer,
      emptyTitle: 'لا رصيد لعميل في هذا اليوم',
      load: (range, _, _) async => ReportData.fromJson(
        await api.getCustomerBalances(asOf: day.format(range!.end)),
      ),
      onDrill: (context, drill, row, report) {
        if (drill.kind != 'customer') return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AccountStatementScreen(
              accountId: drill.id,
              accountName: '${row['name'] ?? ''}',
              entityType: 'customer',
              apiService: api,
            ),
          ),
        );
      },
    );
  }
}
