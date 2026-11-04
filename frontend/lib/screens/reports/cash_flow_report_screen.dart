import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../api_service.dart';
import '../../models/report_contract.dart';
import '../../widgets/report_shell.dart';
import 'trial_balance_report_screen.dart';

/// The cash flow on the reports' shell (REPORTS ت2-3, ADR-083): where the
/// riyals of «النقدية والبنوك» came from and where they went in a period, by
/// the direct method -- operating, investing, financing, each line a group of
/// the tree; the cash before and after, and its check that they close. A line
/// opens the trial balance of its group's accounts for the period.
class CashFlowReportScreen extends StatelessWidget {
  const CashFlowReportScreen({
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
    final today = (now ?? DateTime.now)();
    final thisMonth = DateTimeRange(
      start: DateTime(today.year, today.month, 1),
      end: DateTime(today.year, today.month, today.day),
    );
    // a flow is of a period: «all» is this year to today
    final thisYear = DateTimeRange(
      start: DateTime(today.year, 1, 1),
      end: thisMonth.end,
    );
    return ReportShell(
      title: 'التدفقات النقدية',
      subtitle: 'من أين جاءت الريالات وأين ذهبت، بالطريقة المباشرة',
      now: now,
      saver: saver,
      printer: printer,
      initialRange: thisMonth,
      emptyTitle: 'لا حركة نقدية في هذه الفترة',
      load: (range, _, _) async {
        final period = range ?? thisYear;
        return ReportData.fromJson(
          await api.getCashFlow(
            startDate: day.format(period.start),
            endDate: day.format(period.end),
          ),
        );
      },
      onDrill: (context, drill, row, report) {
        if (drill.kind != 'account') return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TrialBalanceReportScreen(
              api: api,
              under: drill.id,
              title: '${row['name'] ?? ''}',
              range: report.start != null && report.end != null
                  ? DateTimeRange(start: report.start!, end: report.end!)
                  : null,
            ),
          ),
        );
      },
    );
  }
}
