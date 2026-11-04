// REPORTS ت5-4 (ADR-083): the gold price's history on the reports' shell.
// The journey: it opens on the last ninety days by day; «حسب» reads again;
// the chart drawn; the source said as the recorded prices.

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/reports/gold_price_history_report_screen.dart';
import 'package:frontend/theme/app_theme.dart';

class _Server extends ApiService {
  final asked = <(String, String, String)>[];

  @override
  Future<Map<String, dynamic>> getGoldPriceHistoryReport({
    required String startDate,
    required String endDate,
    String by = 'day',
  }) async {
    asked.add((startDate, endDate, by));
    return {
      'id': 'gold_price_history',
      'title': 'تاريخ أسعار الذهب',
      'basis': 'prices',
      'period': {'start': startDate, 'end': endDate},
      'columns': [
        {'key': 'group', 'label': 'اليوم', 'kind': 'text'},
        {'key': 'average', 'label': 'المتوسط (عيار 21)', 'kind': 'money'},
        {
          'key': 'change',
          'label': 'التغيّر',
          'kind': 'percent',
          'signed': true,
        },
      ],
      'rows': [
        {'group': '2026-10-30', 'average': 415.1, 'change': -0.4},
        {'group': '2026-10-31', 'average': 416.27, 'change': 0.28},
        {
          'group': 'من 415.10 إلى 416.27 ريال لجرام عيار 21: +0.28%',
          'style': 'note',
        },
      ],
      'totals': <String, dynamic>{},
      'checks': [],
      'chart': {'x': 'group', 'y': 'average', 'kind': 'line'},
      'read_at': '2026-11-04T10:32:00',
    };
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('the last ninety days by day; by month on asking; its chart', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = _Server();
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: GoldPriceHistoryReportScreen(
            api: server,
            now: () => DateTime(2026, 10, 31),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(server.asked.single, ('2026-08-02', '2026-10-31', 'day'));
    expect(find.byKey(const ValueKey('report-chart')), findsOneWidget);
    expect(find.byType(LineChart), findsOneWidget, reason: 'a price over time');
    expect(find.textContaining('من أسعار الذهب المسجّلة'), findsOneWidget);
    await tester.tap(find.text('الشهر').first);
    await _settle(tester);
    expect(server.asked.last.$3, 'month');
  });
}
