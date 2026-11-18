import 'package:flutter/material.dart';

import '../../api_service.dart';
import '../../models/report_contract.dart';
import '../../widgets/report_shell.dart';

/// The models' movement on the reports' shell (ADR-093; the owner, 18 Nov
/// 2026: «هل ستتبع التقارير حركة الموديل؟»): each model -- and size -- what
/// was in the stock when the period began, what was received, came back,
/// was sold, returned to its supplier or went out otherwise, and what is
/// left. The server reads it from the books and checks that what was, plus
/// what came in, less what went out, is what is left.
class ModelMovementReportScreen extends StatelessWidget {
  const ModelMovementReportScreen({super.key, required this.api, this.now, this.saver, this.printer});

  final ApiService api;

  /// Today, for tests.
  final DateTime Function()? now;

  /// Where a file goes, and the print dialog; tests pass fakes.
  final ReportSaver? saver;
  final Future<void> Function(Future<List<int>> Function() pdf)? printer;

  static const by = 'by';

  @override
  Widget build(BuildContext context) {
    // the server's day, as it reads it: yyyy-MM-dd
    String day(DateTime d) => d.toIso8601String().substring(0, 10);
    final today = (now ?? DateTime.now)();
    return ReportShell(
      title: 'حركة الموديلات',
      subtitle: 'ما كان، وما دخل، وما خرج، وما بقي -- من الدفاتر',
      now: now,
      saver: saver,
      printer: printer,
      initialRange: DateTimeRange(
        start: DateTime(today.year, today.month, 1),
        end: DateTime(today.year, today.month, today.day),
      ),
      choices: const [
        ReportChoice(by, 'حسب', [
          ('model_size', 'الموديل والمقاس'),
          ('model', 'الموديل'),
        ]),
      ],
      emptyTitle: 'لا قطع تحرّكت في هذه الفترة',
      load: (range, on, chosen) async => ReportData.fromJson(
        await api.getModelMovement(
          startDate: day(range!.start),
          endDate: day(range.end),
          by: chosen[by] ?? 'model_size',
        ),
      ),
    );
  }
}
