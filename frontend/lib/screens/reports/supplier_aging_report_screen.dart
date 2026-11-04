import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../api_service.dart';
import '../../models/report_contract.dart';
import '../../widgets/report_shell.dart';
import '../account_statement_screen.dart';

/// The suppliers' aging on the reports' shell (REPORTS ت3-2ب, ADR-083): what
/// the shop owes each supplier on a day, by the age of each open item of its
/// running account (0-30, 31-60, 61-90, over 90 days), in riyals or in grams,
/// what is paid ahead apart; its check (each total is the supplier's ledger
/// balance). A supplier opens its statement.
class SupplierAgingReportScreen extends StatelessWidget {
  const SupplierAgingReportScreen({
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

  static const dimension = 'dimension';

  @override
  Widget build(BuildContext context) {
    final day = DateFormat('yyyy-MM-dd');
    return ReportShell(
      title: 'أعمار ديون الموردين',
      subtitle: 'من الحساب الجاري لكل مورد، مطابقًا لدفتره',
      singleDay: true,
      now: now,
      saver: saver,
      printer: printer,
      choices: const [
        ReportChoice(dimension, 'البُعد', [
          ('cash', 'بالريال'),
          ('gold', 'بالجرام'),
        ]),
      ],
      emptyTitle: 'لا شيء على المحل لمورد في هذا اليوم',
      load: (range, _, chosen) async => ReportData.fromJson(
        await api.getSupplierAging(
          asOf: day.format(range!.end),
          dimension: chosen[dimension] ?? 'cash',
        ),
      ),
      onDrill: (context, drill, row, report) {
        if (drill.kind != 'supplier') return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AccountStatementScreen(
              accountId: drill.id,
              accountName: '${row['name'] ?? ''}',
              entityType: 'supplier',
              apiService: api,
            ),
          ),
        );
      },
    );
  }
}
