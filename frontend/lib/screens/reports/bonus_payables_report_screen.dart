import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../api_service.dart';
import '../../models/report_contract.dart';
import '../../widgets/report_shell.dart';
import '../employee_page.dart';

/// The bonuses owed on the reports' shell (REPORTS ت6-3, ADR-083): on a day,
/// each employee's bonuses approved and not yet paid beside what the books owe
/// him -- the books being right (BONUS-BOOKS-1), a difference is said as a
/// finding; what the payables hold beside the employees' accounts is said
/// apart. An employee opens his page.
class BonusPayablesReportScreen extends StatelessWidget {
  const BonusPayablesReportScreen({
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
      title: 'المكافآت المستحقة',
      subtitle: 'المعتمدة غير المصروفة، بجانب ما تدين به الدفاتر لكل موظف',
      singleDay: true,
      now: now,
      saver: saver,
      printer: printer,
      emptyTitle: 'لا مكافآت مستحقة في هذا اليوم',
      load: (range, _, _) async => ReportData.fromJson(
        await api.getBonusesPayablesReport(asOf: day.format(range!.end)),
      ),
      onDrill: (context, drill, row, report) {
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
