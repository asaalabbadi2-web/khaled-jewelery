import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../api_service.dart';
import '../../models/report_contract.dart';
import '../../widgets/report_shell.dart';
import '../account_statement_screen.dart';

/// The shop's gold by its place on the reports' shell (REPORTS ت5-2, ADR-083;
/// the owner, 4 Nov 2026): where the gold is on a day -- each safe, stock,
/// custody and office deposit under its balance-sheet group, its grams of each
/// karat and in the main karat -- its total the balance sheet's assets in
/// grams (checked), valued at today's price in a note that says the price. A
/// place opens its account's statement.
class GoldByPlaceReportScreen extends StatelessWidget {
  const GoldByPlaceReportScreen({
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
      title: 'الذهب حسب مكانه',
      subtitle: 'أصول الميزانية بالوزن، مكانًا مكانًا',
      singleDay: true,
      now: now,
      saver: saver,
      printer: printer,
      emptyTitle: 'لا ذهب في الدفاتر في هذا اليوم',
      load: (range, _, _) async => ReportData.fromJson(
        await api.getGoldByPlace(asOf: day.format(range!.end)),
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
