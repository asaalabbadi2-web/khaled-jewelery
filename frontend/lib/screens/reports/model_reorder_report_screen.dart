import 'package:flutter/material.dart';

import '../../api_service.dart';
import '../../models/report_contract.dart';
import '../../widgets/report_shell.dart';

/// «ما يُطلب من المورد» on the reports' shell (ADR-093; the owner, 18 Nov
/// 2026): each model and size -- its pieces in the stock on a day, those sold
/// in the days before, and how many days its stock lasts at that pace: run
/// out, short (less than the days read), or enough. The server judges it.
class ModelReorderReportScreen extends StatelessWidget {
  const ModelReorderReportScreen({super.key, required this.api, this.now, this.saver, this.printer});

  final ApiService api;
  final DateTime Function()? now;
  final ReportSaver? saver;
  final Future<void> Function(Future<List<int>> Function() pdf)? printer;

  static const days = 'days';

  @override
  Widget build(BuildContext context) {
    return ReportShell(
      title: 'ما يُطلب من المورد',
      subtitle: 'كل موديل ومقاس: ما في المخزون، وما بيع، وكم يكفي',
      singleDay: true,
      now: now,
      saver: saver,
      printer: printer,
      choices: const [
        ReportChoice(days, 'سرعة البيع من آخر', [('30', '30 يومًا'), ('60', '60 يومًا'), ('90', '90 يومًا')]),
      ],
      emptyTitle: 'لا موديلات بعد',
      load: (range, _, chosen) async => ReportData.fromJson(
        await api.getModelReorder(
          asOf: range!.end.toIso8601String().substring(0, 10),
          days: int.parse(chosen[days] ?? '30'),
        ),
      ),
    );
  }
}
