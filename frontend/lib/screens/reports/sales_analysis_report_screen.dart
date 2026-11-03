import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../api_service.dart';
import '../../models/report_contract.dart';
import '../../widgets/report_shell.dart';
import '../account_statement_screen.dart';
import '../employee_page.dart';

/// Sales analysis on the reports' shell (REPORTS ت1-2, ADR-083): the period's
/// sales and returns by employee, customer, day or month, from the documents
/// and checked against the books (the server says whether they agree);
/// compared, each group beside its previous period. An employee's row opens
/// his page, a customer's his statement.
class SalesAnalysisReportScreen extends StatelessWidget {
  const SalesAnalysisReportScreen({
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
      title: 'تحليل المبيعات',
      subtitle: 'من فواتير البيع والمرتجع، مطابقة للدفاتر',
      now: now,
      saver: saver,
      printer: printer,
      // a month at a time: the question the shop asks of its sales
      initialRange: DateTimeRange(
        start: DateTime(today.year, today.month, 1),
        end: DateTime(today.year, today.month, today.day),
      ),
      choices: const [
        ReportChoice(by, 'حسب', [
          ('employee', 'الموظف'),
          ('customer', 'العميل'),
          ('day', 'اليوم'),
          ('month', 'الشهر'),
        ]),
      ],
      toggles: const [ReportToggle(compare, 'قارِن بالفترة السابقة')],
      emptyTitle: 'لا مبيعات في هذه الفترة',
      load: (range, on, chosen) async => ReportData.fromJson(
        await api.getSalesAnalysis(
          startDate: range == null ? null : day.format(range.start),
          endDate: range == null ? null : day.format(range.end),
          by: chosen[by] ?? 'employee',
          compare: on.contains(compare),
        ),
      ),
      onDrill: (context, drill, row) {
        final screen = switch (drill.kind) {
          'employee' => EmployeePage(api: api, employeeId: drill.id),
          'customer' => AccountStatementScreen(
            accountId: drill.id,
            accountName: '${row['group'] ?? ''}',
            entityType: 'customer',
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
