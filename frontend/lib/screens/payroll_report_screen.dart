import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../api_service.dart';
import '../models/report_contract.dart';
import '../widgets/report_shell.dart';
import 'employee_page.dart';

/// The payroll report on the reports' shell (REPORTS ت6-2ب, ADR-083): the
/// period's salaries by month, employee or line -- what was earned, its
/// additions and bonuses, its absence and deductions, its net, and its salary
/// expense (the run's own reckoning), checked against the salary expense in
/// the books (the server says by how much when they differ). By month it
/// draws the expense. An employee opens his page.
class PayrollReportScreen extends StatelessWidget {
  const PayrollReportScreen({
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

  @override
  Widget build(BuildContext context) {
    final day = DateFormat('yyyy-MM-dd');
    final today = (now ?? DateTime.now)();
    final yearStart = DateTime(today.year, 1, 1);
    final end = DateTime(today.year, today.month, today.day);
    return ReportShell(
      title: 'تقرير الرواتب',
      subtitle: 'من مسير الرواتب، مطابقًا لمصروف الرواتب في الدفاتر',
      now: now,
      saver: saver,
      printer: printer,
      // the year so far: a payroll is read month by month
      initialRange: DateTimeRange(start: yearStart, end: end),
      choices: const [
        ReportChoice(by, 'حسب', [
          ('month', 'الشهر'),
          ('employee', 'الموظف'),
          ('line', 'كل راتب'),
        ]),
      ],
      emptyTitle: 'لا رواتب معتمدة في هذه الفترة',
      load: (range, _, chosen) async {
        final r = range ?? DateTimeRange(start: yearStart, end: end);
        return ReportData.fromJson(
          await api.getPayrollReport(
            startDate: day.format(r.start),
            endDate: day.format(r.end),
            by: chosen[by] ?? 'month',
          ),
        );
      },
      onDrill: (context, drill, row, _) {
        if (drill.kind != 'employee') return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => EmployeePage(api: api, employeeId: drill.id),
          ),
        );
      },
    );
  }
}
