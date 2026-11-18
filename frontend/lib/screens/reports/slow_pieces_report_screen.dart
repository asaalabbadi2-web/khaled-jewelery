import 'package:flutter/material.dart';

import '../../api_service.dart';
import '../../models/report_contract.dart';
import '../../widgets/report_shell.dart';

/// «القطع الراكدة» on the reports' shell (ADR-093; the owner, 18 Nov 2026):
/// the pieces in the stock on a day and how long each has sat -- from the
/// last time it came in -- past the days chosen, by piece or by model.
class SlowPiecesReportScreen extends StatelessWidget {
  const SlowPiecesReportScreen({super.key, required this.api, this.now, this.saver, this.printer});

  final ApiService api;
  final DateTime Function()? now;
  final ReportSaver? saver;
  final Future<void> Function(Future<List<int>> Function() pdf)? printer;

  static const by = 'by';
  static const days = 'min_days';

  @override
  Widget build(BuildContext context) {
    return ReportShell(
      title: 'القطع الراكدة',
      subtitle: 'كم بقيت كل قطعة في المخزون منذ دخلته',
      singleDay: true,
      now: now,
      saver: saver,
      printer: printer,
      choices: const [
        ReportChoice(days, 'أكثر من', [('90', '90 يومًا'), ('30', '30 يومًا'), ('60', '60 يومًا'), ('180', '180 يومًا')]),
        ReportChoice(by, 'حسب', [('piece', 'القطعة'), ('model', 'الموديل')]),
      ],
      emptyTitle: 'لا قطع راكدة بهذا الحدّ',
      load: (range, _, chosen) async => ReportData.fromJson(
        await api.getSlowPieces(
          asOf: range!.end.toIso8601String().substring(0, 10),
          minDays: int.parse(chosen[days] ?? '90'),
          by: chosen[by] ?? 'piece',
        ),
      ),
    );
  }
}
