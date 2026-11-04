import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../api_service.dart';
import '../../models/report_contract.dart';
import '../../widgets/report_shell.dart';
import '../account_statement_screen.dart';
import '../employee_page.dart';

/// Purchases analysis on the reports' shell (REPORTS ت4-4أ, ADR-083): the
/// period's purchases and their returns by kind, party, employee, day, month
/// or karat -- in the riyals the books keep (a customer's or an office's
/// price, a supplier's wage: its gold is a debt in grams) and in grams --
/// checked against the books (the server says whether they agree, and by how
/// much). Over time it draws its chart. A party opens its statement, an
/// employee his page.
class PurchasesAnalysisReportScreen extends StatelessWidget {
  const PurchasesAnalysisReportScreen({
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

  static const by = 'by';
  static const compare = 'compare';

  @override
  Widget build(BuildContext context) {
    final day = DateFormat('yyyy-MM-dd');
    final today = (now ?? DateTime.now)();
    return ReportShell(
      title: 'تحليل المشتريات',
      subtitle: 'بريال الدفاتر وبالجرام، مطابقة لحسابات المشتريات',
      now: now,
      saver: saver,
      printer: printer,
      // a month at a time, as the sales analysis
      initialRange: DateTimeRange(
        start: DateTime(today.year, today.month, 1),
        end: DateTime(today.year, today.month, today.day),
      ),
      choices: const [
        ReportChoice(by, 'حسب', [
          ('kind', 'النوع'),
          ('party', 'الطرف'),
          ('employee', 'الموظف'),
          ('day', 'اليوم'),
          ('month', 'الشهر'),
          ('karat', 'العيار'),
        ]),
      ],
      toggles: const [ReportToggle(compare, 'قارِن بالفترة السابقة')],
      emptyTitle: 'لا مشتريات في هذه الفترة',
      load: (range, on, chosen) async => ReportData.fromJson(
        await api.getPurchasesAnalysis(
          startDate: range == null ? null : day.format(range.start),
          endDate: range == null ? null : day.format(range.end),
          by: chosen[by] ?? 'kind',
          compare: on.contains(compare),
        ),
      ),
      onDrill: (context, drill, row, _) {
        final screen = switch (drill.kind) {
          'employee' => EmployeePage(api: api, employeeId: drill.id),
          'customer' || 'supplier' => AccountStatementScreen(
            accountId: drill.id,
            accountName: '${row['group'] ?? ''}',
            entityType: drill.kind,
            apiService: api,
          ),
          _ => null,
        };
        if (screen == null) return;
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
      },
    );
  }
}
